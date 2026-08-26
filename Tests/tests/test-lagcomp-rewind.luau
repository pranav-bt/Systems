-- LagCompensation's claim validation: what a client is allowed to assert, and what the server
-- refuses before any geometry is considered.
--
-- These are the gates. Everything downstream trusts that a claim reaching it named real
-- targets, at a time inside the rewind horizon, at a rate a human could produce -- so a hole
-- here is a hole in the whole pipeline, geometry or not.
local rbx = require("./shim/roblox")
local Rewind = require("./shim/library")("LagCompensation", "Rewind")
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

-- A rewind whose world we control: no snapshots, a fixed latency, and a damageable predicate
-- the test decides.
local function newRewind(overrides)
	local config = table.clone(Config)
	for key, value in overrides or {} do
		config[key] = value
	end
	return Rewind.new({
		config = config,
		logger = { Warn = function() end, Info = function() end, Error = function() end, Debug = function() end },
		snapshots = {
			SampleAt = function()
				return nil
			end,
			SamplesInWindow = function()
				return {}
			end,
			GetExtents = function()
				return V(4, 5.2, 4)
			end,
		},
		getLatency = function()
			return 0.1
		end,
		isDamageable = function(instance)
			return instance:GetAttribute("Damageable") == true
		end,
	})
end

local function newModel(name, damageable, withHumanoid)
	local model = rbx.Instance.new("Model")
	model.Name = name
	if damageable then
		model:SetAttribute("Damageable", true)
	end
	if withHumanoid then
		local humanoid = rbx.Instance.new("Humanoid")
		humanoid.Health = 100
		humanoid.Parent = model
	end
	model.Parent = rbx.workspace
	return model
end

print("SanitizeTargets refuses everything it should")
do
	local api = newRewind()
	local attacker = newModel("Attacker", false, true)
	local victim = newModel("Victim", false, true)

	check("a real target survives", #api.SanitizeTargets({ victim }, attacker) == 1)

	-- The payload is client-supplied, so its SHAPE is not to be trusted either.
	check("a non-table payload is empty", #api.SanitizeTargets("everyone" :: any, attacker) == 0)
	check("nil is empty", #api.SanitizeTargets(nil :: any, attacker) == 0)
	check("a table of junk is empty", #api.SanitizeTargets({ 1, "two", true } :: any, attacker) == 0)

	-- Naming yourself is the cheapest self-damage exploit there is.
	check("the attacker cannot name itself", #api.SanitizeTargets({ attacker }, attacker) == 0, "it was accepted")

	-- A BasePart is an Instance but not a Model.
	local part = rbx.Instance.new("Part")
	part.Parent = rbx.workspace
	check("a non-Model instance is dropped", #api.SanitizeTargets({ part :: any }, attacker) == 0)

	-- Neither a Humanoid nor the host's damageable predicate: not a thing that takes damage.
	local scenery = newModel("Scenery", false, false)
	check("a non-damageable model is dropped", #api.SanitizeTargets({ scenery }, attacker) == 0)

	-- The host's predicate is the second route in, for things with no Humanoid.
	local crate = newModel("Crate", true, false)
	check("the host's damageable predicate admits one", #api.SanitizeTargets({ crate }, attacker) == 1)

	-- A mixed payload keeps only the real ones.
	local mixed = api.SanitizeTargets({ victim, part :: any, attacker, scenery, crate }, attacker)
	check("a mixed payload keeps only the valid targets", #mixed == 2, #mixed)
end

print("the reported-target cap is enforced by COUNTING, not by length")
do
	--[[
		The cap has to be enforced on what the loop actually VISITS, because `#` on a
		client-supplied table is not a bound: a crafted table can report a length of 1 and
		still yield hundreds of entries to generalized iteration. That exact mismatch was a
		live duplication exploit in this repo's Trading library.

		Here the counter increments per visited entry and breaks on the cap, so the shape of
		the table cannot get more work done than the cap allows.
	]]
	local api = newRewind({ MAX_REPORTED_TARGETS = 3 })
	local attacker = newModel("Attacker", false, true)

	local many = {}
	for index = 1, 50 do
		many[index] = newModel(`Victim{index}`, false, true)
	end
	check("a flood is cut to the cap", #api.SanitizeTargets(many, attacker) == 3, #api.SanitizeTargets(many, attacker))

	--[[
		The same flood behind a table whose `#` reports 1. If the cap were read off the length
		this would process all fifty; the counter means it still stops at three.
	]]
	local lying = setmetatable({}, {
		__len = function()
			return 1
		end,
		__iter = function()
			local index = 0
			return function()
				index += 1
				return many[index] and index, many[index]
			end
		end,
	})
	local sanitized = api.SanitizeTargets(lying :: any, attacker)
	check("and so is one lying about its length", #sanitized <= 3, #sanitized)
end

print("ClampClaimTime bounds the rewind horizon")
do
	local api = newRewind()
	local player = rbx.addPlayer("Ana")
	task.wait()
	rbx.setServerTime(5000)

	check("a claim at the present is accepted", api.ClampClaimTime(5000, player) == 5000)
	check("a recent claim is accepted", api.ClampClaimTime(4999.5, player) == 4999.5, api.ClampClaimTime(4999.5, player))

	-- Nothing that is not a usable number gets past.
	check("a non-number is refused", api.ClampClaimTime("5000" :: any, player) == nil)
	check("nil is refused", api.ClampClaimTime(nil, player) == nil)
	check("NaN is refused", api.ClampClaimTime(0 / 0, player) == nil)
	check("infinity is refused", api.ClampClaimTime(math.huge, player) == nil)
	check("negative infinity is refused", api.ClampClaimTime(-math.huge, player) == nil)

	--[[
		THE HORIZON, IN BOTH DIRECTIONS.

		Too far in the past is the lag-comp exploit proper: rewind far enough and you are
		shooting at where people used to be. MAX_REWIND is 1 second.

		Too far in the future is the mirror of it -- claiming a time the server has not reached
		lets a client shoot where a target is about to be. FUTURE_SLACK allows only the small
		amount clock jitter can produce.
	]]
	check("a stale claim is refused", api.ClampClaimTime(5000 - Config.MAX_REWIND - 0.1, player) == nil, "accepted")
	check("one just inside the horizon is accepted", api.ClampClaimTime(5000 - Config.MAX_REWIND + 0.01, player) ~= nil)

	check("a far-future claim is refused", api.ClampClaimTime(5000 + 1, player) == nil, "accepted")
	-- Within slack it is accepted but CLAMPED to now: the server never validates against a
	-- future it has not recorded.
	local slightlyAhead = api.ClampClaimTime(5000 + Config.FUTURE_SLACK / 2, player)
	check("a slightly-ahead claim is clamped to now", slightlyAhead == 5000, slightlyAhead)

	-- Every refusal is counted, which is what makes an attack visible in aggregate rather
	-- than only in a log line nobody reads.
	local counters = api.GetCounters()
	check("refusals are counted by reason", (counters.BadPayload or 0) > 0, counters)
	check("including stale timestamps", (counters.StaleTimestamp or 0) > 0, counters)
	check("and future ones", (counters.FutureTimestamp or 0) > 0, counters)

	rbx.removePlayer(player)
end

print("AllowRate is a per-key, per-player, per-second bucket")
do
	local api = newRewind()
	local ana = rbx.addPlayer("Ana")
	local ben = rbx.addPlayer("Ben")
	task.wait()

	local allowed = 0
	for _ = 1, 5 do
		if api.AllowRate(ana, "swing", 3) then
			allowed += 1
		end
	end
	check("the bucket caps the burst", allowed == 3, allowed)

	-- Per key: a different action has its own budget.
	check("a different key is unaffected", api.AllowRate(ana, "dash", 3))

	-- Per player: one player's spam cannot rate-limit another.
	check("another player is unaffected", api.AllowRate(ben, "swing", 3))

	-- The window is a second of wall clock, so it genuinely refills.
	task.wait(1.05)
	check("the window refills", api.AllowRate(ana, "swing", 3))

	--[[
		A player who leaves takes their buckets with them.

		The bucket is EXHAUSTED first, deliberately. Cleaning up a bucket that still had room
		proves nothing -- the next call would be allowed whether or not anything was dropped,
		which is exactly what this check used to assert.
	]]
	for _ = 1, 5 do
		api.AllowRate(ana, "swing", 3)
	end
	check("the bucket is spent", not api.AllowRate(ana, "swing", 3), "it still had room")

	api.CleanupPlayer(ana)
	check("cleanup drops their buckets", api.AllowRate(ana, "swing", 3), "the spent bucket survived")

	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("AttackerPoseAt looks half a round trip further back")
do
	--[[
		The server's snapshot stream of a client-owned character lags that client's own view by
		about one-way latency, so the sample matching "where the attacker's client was at its
		own time t" arrives about one-way LATER on the server clock.

		Verified by watching which time the sampler is asked for, since the arithmetic is the
		whole content of the function.
	]]
	local askedFor = nil
	local api = Rewind.new({
		config = table.clone(Config),
		logger = { Warn = function() end, Info = function() end, Error = function() end, Debug = function() end },
		snapshots = {
			SampleAt = function(_, t)
				askedFor = t
				return nil
			end,
			SamplesInWindow = function()
				return {}
			end,
			GetExtents = function()
				return V(4, 5.2, 4)
			end,
		},
		getLatency = function()
			return 0.2
		end,
		isDamageable = function()
			return false
		end,
	})

	local player = rbx.addPlayer("Ana")
	task.wait()
	rbx.setServerTime(6000)
	local character = rbx.Instance.new("Model")
	local root = rbx.Instance.new("Part")
	root.CFrame = rbx.CFrame.new(V(1, 2, 3))
	root.Parent = character

	api.AttackerPoseAt(player, character, root, 5999.5)
	check("it asks half the round trip later than the claim", askedFor == 5999.6, askedFor)

	-- Never past the present: there is no history of a time that has not happened.
	api.AttackerPoseAt(player, character, root, 6000)
	check("and never later than now", askedFor == 6000, askedFor)

	-- With no sample it falls back to the live root rather than refusing outright.
	local pose = api.AttackerPoseAt(player, character, root, 5999.5)
	check("with no snapshot it falls back to the live pose", pose.Position.X == 1, pose.Position)

	rbx.removePlayer(player)
end

print("HasLineOfSight reuses its filter instead of rebuilding it")
do
	--[[
		THE FIX. This is the hottest path the module has -- one call per target per claim -- and
		it used to iterate every player, build a fresh exclude table and allocate a new
		RaycastParams on every one of them. Across a full lobby that is a steady stream of
		garbage produced to describe a world that had not changed.

		The params object is reused (RaycastParams is mutable) and the exclude list is rebuilt
		only when it can actually have changed: a player joining, leaving, or respawning.
	]]
	local api = newRewind()
	for index = 1, 8 do
		rbx.addPlayer(`Filler{index}`)
	end
	task.wait()

	--[[
		Two separate things are cached, and both need watching. The params OBJECT is counted by
		allocations; the exclude LIST is counted by how often the roster is re-read, since a
		rebuild reuses the same object and would otherwise be invisible.
	]]
	rbx.resetRaycastParamsCount()
	rbx.resetPlayerListReads()
	for _ = 1, 20 do
		api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))
	end
	local made = rbx.raycastParamsMade()
	check("twenty checks allocate ONE params object", made == 1, made)
	check("and read the player roster once", rbx.playerListReads() == 1, rbx.playerListReads())

	--[[
		THE FILTER MUST ACTUALLY CONTAIN THE CHARACTERS. A cache that never populates the list
		is cheap and wrong: nothing is excluded, so every player blocks their own line of sight
		and every honest shot is refused as occluded.
	]]
	local seenFilter = nil
	rbx.setRaycastResult(function(_, _, params)
		seenFilter = params and params.FilterDescendantsInstances
		return nil
	end)
	api.InvalidateLineOfSightFilter()
	api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))
	check("the filter excludes something", seenFilter ~= nil and #seenFilter > 0, seenFilter and #seenFilter)

	local excludesACharacter = false
	for _, entry in seenFilter or {} do
		if entry and entry.Name and string.find(entry.Name, "Filler") then
			excludesACharacter = true
		end
	end
	check("including the players' own characters", excludesACharacter, "no character in the filter")
	rbx.setRaycastResult(nil)

	-- Still correct, not merely cheap: the unobstructed case is line of sight.
	check("an unobstructed ray has line of sight", api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0)))

	local blocker = rbx.Instance.new("Part")
	rbx.setRaycastResult(function()
		return { Instance = blocker, Position = V(5, 0, 0) }
	end)
	check("a ray blocked well short of the target does not", not api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0)))

	--[[
		A ray blocked ON the target is still line of sight: LOS_IMPACT_SLACK exists because the
		surface the shot actually hit IS the target's own geometry. Without it every hit on a
		solid target would be refused as occluded by itself.
	]]
	rbx.setRaycastResult(function()
		return { Instance = blocker, Position = V(9.5, 0, 0) }
	end)
	check("but one blocked at the target is", api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0)))
	rbx.setRaycastResult(nil)

	--[[
		THE STALENESS THE CACHE HAS TO AVOID. A respawn swaps the Character out, so a filter
		built before it holds a destroyed instance -- and the new character is not excluded,
		which would make every player block their own line of sight.
	]]
	local ana = rbx.addPlayer("Ana")
	task.wait()
	rbx.resetRaycastParamsCount()
	api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))

	local reborn = rbx.newCharacter("Ana")
	ana.Character = reborn
	ana._fireCharacterAdded(reborn)
	task.wait()
	rbx.resetPlayerListReads()
	api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))
	-- The params object itself is still reused; what a respawn invalidates is its CONTENTS,
	-- so the roster is re-read exactly once more.
	check("a respawn does not force a new params object", rbx.raycastParamsMade() == 0, rbx.raycastParamsMade())
	check("but it does rebuild the exclude list", rbx.playerListReads() == 1, rbx.playerListReads())

	-- And the host can say so itself for anything the module cannot observe.
	check("the filter can be invalidated by hand", pcall(api.InvalidateLineOfSightFilter))
	check("and still answers afterwards", api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0)))

	rbx.removePlayer(ana)
end

print("the filter is built on the first call, and rebuilt when the roster changes")
do
	--[[
		Isolated from the block above on purpose. There, players join AFTER the rewind exists,
		so the join events mark the filter dirty and mask whether it would have built one
		anyway. Here the players are already present before the rewind is constructed, so
		nothing marks it dirty and the FIRST CALL has to build the filter on its own.

		A cache that starts clean is a filter that excludes nothing until something happens to
		invalidate it -- and until then every player blocks their own line of sight.
	]]
	local resident = rbx.addPlayer("Resident")
	task.wait()
	local api = newRewind()

	rbx.resetPlayerListReads()
	api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))
	check("the very first call builds the filter", rbx.playerListReads() == 1, rbx.playerListReads())

	rbx.resetPlayerListReads()
	api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))
	check("and the second reuses it", rbx.playerListReads() == 0, rbx.playerListReads())

	--[[
		A LEAVER MATTERS AS MUCH AS A JOINER. The cached list holds their Character, which is
		about to be destroyed -- an excluded instance that no longer exists, and one fewer real
		exclusion than the world now needs.
	]]
	rbx.removePlayer(resident)
	task.wait()
	rbx.resetPlayerListReads()
	api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))
	check("a player leaving rebuilds it", rbx.playerListReads() == 1, rbx.playerListReads())

	rbx.resetPlayerListReads()
	api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))
	check("and then it settles again", rbx.playerListReads() == 0, rbx.playerListReads())
end

print(("%d passed, %d failed"):format(passed, failed))
process.exit(if failed > 0 then 1 else 0)
