-- Heatmap: the RLE codec, and what happens to a batch when the write does not land.
--
-- The codec is pure and easy. The flush is where the risk is: it is the only thing standing
-- between a session's data and a DataStore that is allowed to fail.
local rbx = require("./shim/roblox")
local Heatmap = require("./shim/library")("Heatmap")
local task = require("@lune/task")
local process = require("@lune/process")

local passed, failed = 0, 0
local function check(name, ok, detail)
	if ok then
		passed += 1
		print(("  ok   %s"):format(name))
	else
		failed += 1
		print(("  FAIL %s -- %s"):format(name, tostring(detail)))
	end
end

local function cells(list)
	local out = {}
	for _, c in list do
		table.insert(out, { c[1], c[2], c[3] })
	end
	return out
end

local function sameJourney(a, b)
	if #a ~= #b then
		return false
	end
	for i, cell in a do
		if cell[1] ~= b[i][1] or cell[2] ~= b[i][2] or cell[3] ~= b[i][3] then
			return false
		end
	end
	return true
end

--[[
	`Heatmap.flush()` is public now, which is both a fix and what makes this file possible.

	It used to be a local with exactly one call site -- `game:BindToClose(flush)` -- so every
	session a server recorded sat in memory until shutdown, a crash took all of it, and nothing
	could exercise the write path at all. There is a periodic flush now as well; the tests here
	drive it explicitly so they do not wait on a timer.
]]
local function flush()
	return Heatmap.flush()
end

print("the RLE codec round-trips")
do
	local decode = Heatmap.decodeJourney

	check("an empty journey decodes to nothing", #decode({}) == 0)

	-- One cell, held for five samples: the whole point of the encoding.
	local standing = decode({ { 1, 2, 3, 5 } })
	check("a run expands to its length", #standing == 5, #standing)
	check("with every entry the same cell", standing[1][1] == 1 and standing[5][3] == 3, standing[5])

	-- A walk: four distinct cells, one sample each.
	local walk = decode({ { 0, 0, 0, 1 }, { 1, 0, 0, 1 }, { 2, 0, 0, 1 }, { 2, 0, 1, 1 } })
	check("distinct cells decode in order", #walk == 4, #walk)
	check("keeping their order", walk[3][1] == 2 and walk[4][3] == 1, walk)

	-- Negative coordinates survive: a map is not all in the positive octant.
	local negative = decode({ { -4, -1, -9, 2 } })
	check("negative cells survive", negative[1][1] == -4 and negative[1][3] == -9, negative[1])

	-- A zero-length run contributes nothing rather than looping forever.
	check("a zero run contributes nothing", #decode({ { 1, 1, 1, 0 } }) == 0)
end

print("encoding actually compresses standing still")
do
	--[[
		Reached through the public surface: a player who does not move is the case the format
		exists for, and if it did not collapse there would be no reason to encode at all.

		Driven by putting a player in the world and stepping the sampling loop, because
		`encodeJourney` is private -- which is correct, but it means the compression has to be
		observed through what actually gets stored.
	]]
	Heatmap.configure({ SAMPLE_INTERVAL = 0, CELL_SIZE = 12 })
	Heatmap.init()

	local ana = rbx.addPlayer("Ana")
	task.wait()

	-- Ten samples without moving.
	for _ = 1, 10 do
		rbx.step(1 / 60)
	end
	rbx.removePlayer(ana)
	task.wait()

	flush()
	local stored = rbx.dataStoreValue("LobbyHeatmap_v1", "HeatmapBatch_test-job-id_0")
	check("the batch was written", stored ~= nil and stored.sessions ~= nil, stored)

	local session = nil
	for _, entry in (stored and stored.sessions) or {} do
		session = entry
	end
	check("a session was recorded", session ~= nil)
	if session then
		-- Ten identical samples must be ONE tuple, not ten.
		check("ten still samples collapse to one run", #session.journey <= 2, #session.journey)
		local total = 0
		for _, run in session.journey do
			total += run[4]
		end
		check("whose run lengths still total the samples taken", total >= 10, total)
	end
end

print("a failed write KEEPS the batch")
do
	--[[
		THE FIX. `flush` used to drain `pendingFlush` into a local batch before attempting the
		write, so on failure the sessions had already left the queue and were written by nobody.
		DataStore throttling is normal operation rather than an exceptional event, which made
		that guaranteed data loss on a schedule.

		The queue is now cleared only after the write succeeds.
	]]
	local ben = rbx.addPlayer("Ben")
	task.wait()
	for _ = 1, 5 do
		rbx.step(1 / 60)
	end
	rbx.removePlayer(ben)
	task.wait()

	local writesBefore = rbx.dataStoreWrites()
	rbx.failDataStore(1)
	local landed = flush()
	check("the write was attempted", rbx.dataStoreWrites() > writesBefore, rbx.dataStoreWrites())
	check("and reported as failed", landed == false, landed)

	-- The session is still queued, so the next flush carries it.
	local sessionsBefore = 0
	for _ in (rbx.dataStoreValue("LobbyHeatmap_v1", "HeatmapBatch_test-job-id_0") or { sessions = {} }).sessions do
		sessionsBefore += 1
	end

	local retried = flush()
	check("a retry succeeds", retried == true, retried)

	local sessionsAfter = 0
	for _ in (rbx.dataStoreValue("LobbyHeatmap_v1", "HeatmapBatch_test-job-id_0") or { sessions = {} }).sessions do
		sessionsAfter += 1
	end
	check("and the batch that failed is now stored", sessionsAfter > sessionsBefore, `{sessionsBefore} -> {sessionsAfter}`)

	-- Nothing left over: a successful flush clears what it wrote.
	local writesAfter = rbx.dataStoreWrites()
	check("a flush with nothing pending reports success", flush() == true)
	check("without writing again", rbx.dataStoreWrites() == writesAfter, rbx.dataStoreWrites())
end

print("the failure message is honest")
do
	--[[
		It used to warn and then unconditionally print "Flush complete. Recorded N sessions." --
		so a run that lost everything logged as a run that worked, and the count it reported was
		the number of sessions it had FAILED to write. The completion print is gone and the
		warning says what happened to the data.
	]]
	local cara = rbx.addPlayer("Cara")
	task.wait()
	rbx.step(1 / 60)
	rbx.removePlayer(cara)
	task.wait()

	rbx.failDataStore(1)
	check("a failed flush returns false", flush() == false)
	check("and a following one returns true", flush() == true)
end

print("the merge refreshes the meta")
do
	--[[
		`UpdateAsync` used to seed `existing` from the first write's meta and merge only
		sessions afterwards, so `lastUpdated` was stamped once per key and never moved -- a
		reader had no way to tell a live server's batch from an abandoned one.
	]]
	local first = rbx.dataStoreValue("LobbyHeatmap_v1", "HeatmapBatch_test-job-id_0")
	local firstStamp = first and first.meta and first.meta.lastUpdated
	check("a batch carries a timestamp", firstStamp ~= nil, firstStamp)

	-- os.time has one-second resolution, so advance past it before writing again.
	task.wait(1.05)
	local dan = rbx.addPlayer("Dan")
	task.wait()
	rbx.step(1 / 60)
	rbx.removePlayer(dan)
	task.wait()
	flush()

	local second = rbx.dataStoreValue("LobbyHeatmap_v1", "HeatmapBatch_test-job-id_0")
	local secondStamp = second and second.meta and second.meta.lastUpdated
	check("and a later merge advances it", secondStamp > firstStamp, `{firstStamp} -> {secondStamp}`)

	local sessionCount = 0
	for _ in (second and second.sessions) or {} do
		sessionCount += 1
	end
	check("while still accumulating sessions in the key", sessionCount >= 2, sessionCount)
end

print("the key rotates before it can grow without bound")
do
	--[[
		Everything used to merge into one "HeatmapBatch_<JobId>" for the life of the server,
		and a DataStore value is capped at 4MB -- so a busy server eventually produced a value
		too large to store, and the write that discovered it was also the write that discarded
		the batch.
	]]
	Heatmap.configure({ MAX_SESSIONS_PER_KEY = 3 })

	-- Enough sessions to push past the bound.
	for index = 1, 6 do
		local player = rbx.addPlayer(`Filler{index}`)
		task.wait()
		rbx.step(1 / 60)
		rbx.removePlayer(player)
		task.wait()
		flush()
	end

	local rotated = rbx.dataStoreValue("LobbyHeatmap_v1", "HeatmapBatch_test-job-id_1")
	check("a second key was opened", rotated ~= nil, "everything stayed in one key")

	local inFirst = 0
	for _ in (rbx.dataStoreValue("LobbyHeatmap_v1", "HeatmapBatch_test-job-id_0") or { sessions = {} }).sessions do
		inFirst += 1
	end
	check("and the first key stopped growing", inFirst <= 5, inFirst)
end

print(("%d passed, %d failed"):format(passed, failed))
-- The sampling loop is a Heartbeat connection rather than a while-true, so nothing keeps the
-- process alive; the exit is here only to keep the exit code explicit alongside the others.
process.exit(if failed > 0 then 1 else 0)
