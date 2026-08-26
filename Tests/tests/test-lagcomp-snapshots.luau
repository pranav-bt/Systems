-- LagCompensation's pose history: the ring buffer, what it answers about a past instant, and
-- the movement-sanity checks that ride along with it.
--
-- This is the foundation the whole library stands on -- "where was this character at time t" is
-- the question every hit claim resolves into -- so the clock here is driven by hand rather than
-- sampled. Every interpolation below is an equality, not a tolerance.
local rbx = require("./shim/roblox")
local Snapshots = require("./shim/library")("LagCompensation", "Snapshots")
local Config = require("./shim/library")("LagCompensation", "LagCompConfig")
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

local V = rbx.Vector3.new
local warnings = {}

--[[
	A recorder whose tick is OURS.

	`scheduleSnapshots` is the seam the library provides for exactly this: the returned
	`record` is the function the Heartbeat loop would otherwise call, so a test can place a
	sample at an exact server time instead of racing a real clock.
]]
--[[
	An NPC folder, so a rig can be registered without a Player behind it.

	`Dummies` is one of the config's `npcFolderNames`, and the recorder scans workspace for
	those at start. NPC rigs get pose history but skip the movement checks -- they make no
	claims -- which makes them the right subject for the pure geometry tests below.

	Recreated per recorder so one block's rigs cannot leak into another's history.
]]
local function newNpcFolder()
	local existing = rbx.workspace:FindFirstChild("Dummies")
	if existing then
		existing.Parent = nil
	end
	local folder = rbx.Instance.new("Folder")
	folder.Name = "Dummies"
	folder.Parent = rbx.workspace
	return folder
end

local function newRecorder(overrides)
	local config = table.clone(Config.defaults or Config)
	for key, value in overrides or {} do
		config[key] = value
	end

	local recordFn
	local api = Snapshots.new({
		config = config,
		logger = {
			Warn = function(_, message)
				table.insert(warnings, message)
			end,
			Info = function() end,
			Error = function() end,
		},
		scheduleSnapshots = function(_, record)
			recordFn = record
			return function() end
		end,
	})
	api.start()
	return api, function()
		recordFn()
	end
end

-- A rig registered through the NPC path: history without a Player.
local function newRig(folder, name, at)
	local rig = rbx.Instance.new("Model")
	rig.Name = name or "Dummy"
	local root = rbx.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.CFrame = rbx.CFrame.new(at or V(0, 0, 0))
	root.Parent = rig
	local humanoid = rbx.Instance.new("Humanoid")
	humanoid.Health = 100
	humanoid.Parent = rig
	rig.Parent = folder
	return rig, root, humanoid
end

-- A character the recorder will accept: a root part and a living humanoid.
local function newCharacter(name, at)
	local character = rbx.Instance.new("Model")
	character.Name = name or "Rig"
	local root = rbx.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.CFrame = rbx.CFrame.new(at or V(0, 0, 0))
	root.Parent = character
	local humanoid = rbx.Instance.new("Humanoid")
	humanoid.Health = 100
	humanoid.Parent = character
	character.Parent = rbx.workspace
	return character, root, humanoid
end

print("a sample is taken at the clock it was recorded on")
do
	rbx.setServerTime(1000)
	local api, tick = newRecorder()
	local player = rbx.addPlayer("Ana")
	task.wait()
	local character, root = newCharacter("Ana", V(0, 0, 0))
	player.Character = character
	player._fireCharacterAdded(character)
	task.wait()

	tick()
	local pose = api.SampleAt(character, 1000)
	check("the recorded pose is readable", pose ~= nil, "nothing recorded")
	check("at the position it held", pose and pose.Position.X == 0, pose and pose.Position)

	-- A time before the character existed is not a time it can be hit at.
	check("a time before any sample reads nil", api.SampleAt(character, 999) == nil, "it answered")

	rbx.removePlayer(player)
end

print("SampleAt interpolates between two samples")
do
	rbx.setServerTime(1000)
	local folder = newNpcFolder()
	local api, tick = newRecorder()
	local character, root = newRig(folder, "Rig", V(0, 0, 0))

	tick() -- t=1000 at x=0
	rbx.setServerTime(1001)
	root.CFrame = rbx.CFrame.new(V(10, 0, 0))
	tick() -- t=1001 at x=10

	--[[
		THE WHOLE POINT OF THE LIBRARY. A claim arrives stamped at some instant between two
		snapshots, and the target was somewhere between them. Snapping to the nearest sample
		would make every hit resolve against a position the target never held.
	]]
	local half = api.SampleAt(character, 1000.5)
	check("halfway between reads halfway along", half and half.Position.X == 5, half and half.Position)

	local quarter = api.SampleAt(character, 1000.25)
	check("a quarter of the way reads a quarter along", quarter and quarter.Position.X == 2.5, quarter and quarter.Position)

	check("exactly on the older sample reads it", api.SampleAt(character, 1000).Position.X == 0)
	check("exactly on the newer sample reads it", api.SampleAt(character, 1001).Position.X == 10)

	-- A future time clamps to the newest rather than extrapolating: guessing where a target
	-- WILL be is not evidence of anything.
	check("a future time clamps to the newest", api.SampleAt(character, 1005).Position.X == 10, api.SampleAt(character, 1005).Position)
end

print("the ring buffer wraps without losing its ordering")
do
	rbx.setServerTime(1000)
	-- A tiny capacity, so wrapping is reached in a handful of ticks rather than forty.
	local folder = newNpcFolder()
	local api, tick = newRecorder({ SNAPSHOT_CAPACITY = 4 })
	local character, root = newRig(folder, "Rig", V(0, 0, 0))

	-- Six samples into a four-slot buffer: the first two are overwritten.
	for step = 0, 5 do
		rbx.setServerTime(1000 + step)
		root.CFrame = rbx.CFrame.new(V(step * 10, 0, 0))
		tick()
	end

	check("the newest is readable", api.SampleAt(character, 1005).Position.X == 50, api.SampleAt(character, 1005).Position)
	check("and the oldest surviving one is", api.SampleAt(character, 1002).Position.X == 20, api.SampleAt(character, 1002).Position)

	--[[
		The overwritten samples must read as GONE, not as stale data at the wrong index. A ring
		buffer whose wrap arithmetic is off answers this with whatever happens to be in the
		slot -- a position the character held six seconds ago, presented as where it was two
		seconds ago.
	]]
	check("an overwritten time reads nil", api.SampleAt(character, 1000) == nil, api.SampleAt(character, 1000))

	-- Interpolation still works across the wrap point.
	local mid = api.SampleAt(character, 1003.5)
	check("interpolation survives the wrap", mid and mid.Position.X == 35, mid and mid.Position)

	--[[
		A WINDOW ACROSS THE WRAP, which is where a buffer that has lost count shows it.

		Surviving samples are t=1002..1005 at x=20,30,40,50. A window of (1002.5, 1004.5) is
		the interpolated ends plus exactly the two raw samples strictly inside it: 25, 30, 40,
		45. If `count` were allowed past the capacity the scan would revisit slots it had
		already read -- returning the same pose twice, out of order, as though the target had
		doubled back. Every one of those duplicate poses is another chance for a hit claim to
		find a position the target never held.
	]]
	local window = api.SamplesInWindow(character, 1002.5, 1004.5)
	check("a window across the wrap returns each pose once", #window == 4, #window)

	local xs = {}
	for _, pose in window do
		table.insert(xs, pose.Position.X)
	end
	check("with the interpolated start", xs[1] == 25, xs[1])
	check("the raw samples inside it", xs[2] == 30 and xs[3] == 40, `{tostring(xs[2])}, {tostring(xs[3])}`)
	check("and the interpolated end", xs[4] == 45, xs[4])

	local ascending = true
	for index = 2, #xs do
		if xs[index] <= xs[index - 1] then
			ascending = false
		end
	end
	check("strictly in time order, with no repeats", ascending, table.concat(xs, ", "))
end

print("SamplesInWindow covers a whole shot window")
do
	rbx.setServerTime(1000)
	local folder = newNpcFolder()
	local api, tick = newRecorder()
	local character, root = newRig(folder, "Rig", V(0, 0, 0))

	for step = 0, 4 do
		rbx.setServerTime(1000 + step * 0.1)
		root.CFrame = rbx.CFrame.new(V(step * 5, 0, 0))
		tick()
	end

	--[[
		Every pose the target plausibly held across the window, not just its endpoints -- a
		fast strafe would otherwise slip between two samples and a real hit would be refused.
	]]
	local poses = api.SamplesInWindow(character, 1000.05, 1000.35)
	check("more than the two endpoints are returned", #poses > 2, #poses)

	-- Chronological, and spanning the window: the first is at or after the window start and
	-- the last at or before its end.
	check("the first pose is the interpolated start", poses[1] and math.abs(poses[1].Position.X - 2.5) < 1e-9, poses[1] and poses[1].Position)
	check("the last is the interpolated end", poses[#poses] and math.abs(poses[#poses].Position.X - 17.5) < 1e-9, poses[#poses] and poses[#poses].Position)

	local ordered = true
	for index = 2, #poses do
		if poses[index].Position.X < poses[index - 1].Position.X then
			ordered = false
		end
	end
	check("and they come back in order", ordered, "out of order")

	check("a window before the history is empty", #api.SamplesInWindow(character, 1, 2) == 0)
end

print("a dead character stops recording but keeps its history")
do
	rbx.setServerTime(1000)
	local folder = newNpcFolder()
	local api, tick = newRecorder()
	local character, root, humanoid = newRig(folder, "Rig", V(0, 0, 0))
	tick()

	rbx.setServerTime(1001)
	root.CFrame = rbx.CFrame.new(V(10, 0, 0))
	humanoid.Health = 0
	tick()

	--[[
		A claim already in flight when the target died still has to resolve geometrically --
		the shot was fired while they were alive. So the history survives; only new samples
		stop.
	]]
	check("history from before death survives", api.SampleAt(character, 1000).Position.X == 0)
	check("and no sample was taken after it", api.SampleAt(character, 1001).Position.X == 0, api.SampleAt(character, 1001).Position)
end

print("extents are cached, and refreshed on request")
do
	rbx.setServerTime(1000)
	local folder = newNpcFolder()
	local api, tick = newRecorder()
	local character = newRig(folder, "Rig", V(0, 0, 0))
	character._extents = V(4, 5.2, 4)
	tick()
	check("the first read is cached", api.GetExtents(character).Y == 5.2, api.GetExtents(character))

	--[[
		STILL CACHED, and deliberately: GetExtentsSize walks the whole model, and doing that
		twenty times a second per character to answer a question that almost never changes is
		pure waste. Ticking must not re-read it.
	]]
	character._extents = V(8, 10, 8)
	tick()
	rbx.setServerTime(1001)
	tick()
	check("ticking does NOT re-read it", api.GetExtents(character).Y == 5.2, api.GetExtents(character))

	--[[
		The escape hatch, for the case the cache gets wrong: a character that really did change
		shape -- an R6/R15 swap, a size powerup, a vehicle seat -- otherwise keeps the hitbox it
		had when first recorded, and every later hit is validated against the wrong volume.

		Explicit rather than automatic because there is no reliable signal to watch: extents
		can move from a scale, a limb swap, an accessory or a humanoid description, and which
		of those counts as "a different size now" is a game's judgement, not this module's.
	]]
	check("RefreshExtents reports it was tracked", api.RefreshExtents(character) == true)
	check("and picks up the new size", api.GetExtents(character).Y == 10, api.GetExtents(character))

	-- Once refreshed it stays cached again rather than re-reading every tick.
	character._extents = V(2, 3, 2)
	tick()
	check("and goes back to being cached", api.GetExtents(character).Y == 10, api.GetExtents(character))

	--[[
		An explicit size skips the walk entirely, for a host that already knows the answer --
		scaling a rig by a known factor, say.
	]]
	check("an explicit size is taken as given", api.RefreshExtents(character, V(20, 30, 20)) == true)
	check("without consulting the model", api.GetExtents(character).Y == 30, api.GetExtents(character))
	check("even though the model says otherwise", character._extents.Y == 3, character._extents)

	-- An untracked character is a no-op that says so, rather than an error or a silent lie.
	local stranger = rbx.Instance.new("Model")
	check("an untracked model reports false", api.RefreshExtents(stranger) == false)
	check("and still reads the default extents", api.GetExtents(stranger).Y > 0, api.GetExtents(stranger))
end

print("a teleport flags the player's claims")
do
	rbx.setServerTime(1000)
	table.clear(warnings)
	local api, tick = newRecorder()
	local player = rbx.addPlayer("Jumpy")
	task.wait()
	local character, root = newCharacter("Jumpy", V(0, 0, 0))
	player.Character = character
	player._fireCharacterAdded(character)
	task.wait()

	tick()
	check("claims are accepted to begin with", not api.IsClaimRejected(player))

	-- One impossible step.
	rbx.setServerTime(1000.05)
	root.CFrame = rbx.CFrame.new(V(500, 0, 0))
	tick()
	check("an impossible step flags them", api.IsClaimRejected(player), "not flagged")
	check("and says why", #warnings > 0 and tostring(warnings[1]):find("Teleport") ~= nil, warnings[1])

	-- Flag, log and bound -- never kick. A false positive costs one swing, not the session.
	rbx.setServerTime(1000.05 + 10)
	check("the flag expires on its own", not api.IsClaimRejected(player), "still flagged")

	rbx.removePlayer(player)
end

print("an authorized burst is excused")
do
	rbx.setServerTime(2000)
	table.clear(warnings)
	local api, tick = newRecorder()
	local player = rbx.addPlayer("Dasher")
	task.wait()
	local character, root = newCharacter("Dasher", V(0, 0, 0))
	player.Character = character
	player._fireCharacterAdded(character)
	task.wait()
	tick()

	--[[
		Knockback, a dash, a rally snap: motion the SERVER caused. Without this seam the system
		flags its own game's mechanics, which is the failure mode that makes people switch
		movement checks off entirely.
	]]
	api.NoteAuthorizedBurst(character, 1)
	rbx.setServerTime(2000.05)
	root.CFrame = rbx.CFrame.new(V(500, 0, 0))
	tick()
	check("a burst-excused jump does not flag", not api.IsClaimRejected(player), "flagged anyway")

	-- Once the grace expires, the same motion is suspicious again.
	rbx.setServerTime(2002)
	root.CFrame = rbx.CFrame.new(V(0, 0, 0))
	tick()
	rbx.setServerTime(2002.05)
	root.CFrame = rbx.CFrame.new(V(500, 0, 0))
	tick()
	check("and after it expires the check is back", api.IsClaimRejected(player), "not flagged")

	rbx.removePlayer(player)
end

print("Reset wipes history across an authorized discontinuity")
do
	rbx.setServerTime(3000)
	local api, tick = newRecorder()
	local player = rbx.addPlayer("Spawner")
	task.wait()
	local character, root = newCharacter("Spawner", V(0, 0, 0))
	player.Character = character
	player._fireCharacterAdded(character)
	task.wait()
	tick()
	check("there is history", api.SampleAt(character, 3000) ~= nil)

	--[[
		A spawn-point teleport. After a reset the next sample has no predecessor, so the jump
		can neither flag the player nor be rewound through -- there is no "where were you"
		answer that spans a teleport the server itself performed.
	]]
	api.Reset(character)
	check("and after a Reset there is none", api.SampleAt(character, 3000) == nil, "history survived")

	rbx.setServerTime(3000.05)
	root.CFrame = rbx.CFrame.new(V(500, 0, 0))
	tick()
	check("the jump across the reset does not flag", not api.IsClaimRejected(player), "flagged")
	check("and recording resumes", api.SampleAt(character, 3000.05) ~= nil, "nothing recorded")

	rbx.removePlayer(player)
end

print("an NPC is recorded but never flagged")
do
	rbx.setServerTime(4000)
	local folder = newNpcFolder()
	local api, tick = newRecorder()
	-- NPC rigs are tracked with player = nil: they get pose history so hits on them can be
	-- validated, and skip the movement checks because they make no claims.
	local rig = newRig(folder, "Dummy", V(0, 0, 0))
	tick()
	check("an NPC rig has history", api.SampleAt(rig, 4000) ~= nil)

	rbx.setServerTime(4000.05)
	local root = rig:FindFirstChild("HumanoidRootPart")
	root.CFrame = rbx.CFrame.new(V(500, 0, 0))
	check("and teleporting it raises nothing", pcall(tick), "it threw")
end

print(("%d passed, %d failed"):format(passed, failed))
process.exit(if failed > 0 then 1 else 0)
