--!strict

-- The package's one source of randomness, so a headless run can be made
-- reproducible.
--
-- Three places jitter deliberately: per-goal personality (Planner, GOAL_JITTER),
-- a bot's step phase (Brain, STEP_JITTER), and a sensor's phase (Blackboard,
-- PHASE_JITTER). All of it is there to stop a fleet acting in lockstep, and all
-- of it is exactly what a test needs to pin down -- the suite's whole testing
-- story is "inject `now` and a run replays identically", which was untrue for
-- anything touching scheduling while these read the global RNG.
--
--   Bots.setRandom(function() return myRandom:NextNumber() end)  -- seeded
--   Bots.setRandom(nil)                                          -- back to math.random
--
-- Pair a seeded generator with GOAL_JITTER / STEP_JITTER / PHASE_JITTER at 0 and
-- scheduling becomes exactly assertable; leave the defaults alone in production,
-- where spreading the fleet is the entire point.
--
-- This module exists rather than a Brain function because Blackboard needs the
-- same seam and Brain already requires Blackboard.

local Rng = {}

local generator: () -> number = math.random

-- Set the generator (nil restores math.random). Must return a float in [0, 1),
-- like math.random() with no arguments.
function Rng.set(fn: (() -> number)?)
	assert(fn == nil or type(fn) == "function", "Bots.setRandom: expected a function returning [0, 1), or nil")
	generator = fn or math.random
end

function Rng.next(): number
	return generator()
end

-- A symmetric jitter multiplier: 1 ± spread. Used for every reschedule in the
-- package, so `spread = 0` is a hard guarantee of "no jitter anywhere".
function Rng.jitter(spread: number): number
	if spread == 0 then
		return 1
	end
	return 1 + (generator() * 2 - 1) * spread
end

return Rng
