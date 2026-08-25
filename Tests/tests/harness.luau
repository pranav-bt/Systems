-- Shared test harness: the Bots facade plus check/clock helpers. Run any test file
-- with `lune run Tests/tests/test-<archetype>.luau` from the Libraries directory.
--
-- LOADED FROM BOTS' REAL SOURCE. This used to assemble the facade from copies under
-- `vendor/`, because the loader could not resolve `require(script.Parent.X)` and
-- multi-file packages therefore had to be duplicated. It can now, so the copies are
-- gone -- and with them the hazard the repo README warned about: nothing enforced
-- that they matched `Bots/src`, so a library fix left the copies stale and these
-- tests kept passing against code that no longer shipped.
--
-- That was not theoretical. A `nextAt` fix in Blackboard landed in both places and
-- only the real one was reachable by any test; the mutant that reverted the COPY
-- survived, which is exactly what a silently-stale duplicate looks like.

local Bots = require("./shim/library")("Bots")

local Harness = {}
Harness.Bots = Bots

local passed, failed = 0, 0

function Harness.check(name: string, cond: boolean)
	if cond then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. name)
	end
end

function Harness.finish()
	print(("\n%d passed, %d failed"):format(passed, failed))
	if failed > 0 then
		error("test failures")
	end
end

-- A controllable clock shared by Brain ticks and bodies.
function Harness.newClock(start: number?)
	local clock = { t = start or 1000 }
	function clock.now()
		return clock.t
	end
	function clock.advance(dt: number)
		clock.t += dt
	end
	function clock.tick(dt: number?) -- advance + Brain tick at the new time
		clock.t += dt or 0.2
		Bots.Brain.tick(clock.t)
	end
	return clock
end

-- A recording fake Mover (the contract: SetGoal/GetStatus/Stop). `status`
-- is settable by the test to simulate Stuck/Unreachable.
function Harness.fakeMover()
	local mover = { goals = {}, stopped = 0, status = "Moving" }
	function mover.SetGoal(_, goal)
		table.insert(mover.goals, goal)
		mover.lastGoal = goal
	end
	function mover.GetStatus(_)
		return mover.status
	end
	function mover.Stop(_)
		mover.stopped += 1
		mover.lastGoal = nil
	end
	return mover
end

-- A call recorder: body capabilities that just log invocations.
function Harness.recorder()
	local calls = {}
	local function record(name)
		return function(...)
			table.insert(calls, { name = name, ... })
		end
	end
	local function count(name)
		local total = 0
		for _, call in calls do
			if call.name == name then
				total += 1
			end
		end
		return total
	end
	local function last(name)
		for index = #calls, 1, -1 do
			if calls[index].name == name then
				return calls[index]
			end
		end
		return nil
	end
	return { calls = calls, record = record, count = count, last = last }
end

Harness.deterministicRng = function()
	return 0.5
end

return Harness
