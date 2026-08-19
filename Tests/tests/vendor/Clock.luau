--!strict

-- The package's one source of TIME, for the same reason Rng.luau is its one
-- source of randomness.
--
-- The suite's testing story is "inject `now` and a headless run replays
-- identically" -- but several APIs took `now` as OPTIONAL and defaulted to
-- os.clock() when it was omitted. Under an injected clock those two timelines
-- are unrelated numbers, so a fact written without `now` and swept with one
-- produced a confidence of 542238 where the contract promises [0, 1]. A goal
-- scoring on that confidence then beat every other goal, permanently.
--
--   Bots.setClock(function() return simulatedNow end)
--   Bots.setClock(nil)   -- back to os.clock
--
-- Blackboards additionally prefer the clock they were last UPDATED with, which
-- makes the common case correct with no configuration at all: a sensor writing
-- a fact during an update stamps that update's time, whatever drove it.

local Clock = {}

local source: () -> number = os.clock

-- Set the package clock (nil restores os.clock). Must return seconds as a
-- monotonically increasing number, on the same timeline you pass to
-- Brain.tick / Brain.step.
function Clock.set(fn: (() -> number)?)
	assert(fn == nil or type(fn) == "function", "Bots.setClock: expected a function returning seconds, or nil")
	source = fn or os.clock
end

function Clock.now(): number
	return source()
end

return Clock
