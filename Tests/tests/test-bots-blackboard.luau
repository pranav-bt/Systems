-- Blackboard sensors, and `invalidate` in particular.
--
-- Loaded from Bots' REAL source, as the whole suite now is. The archetype suites used to run
-- against copies under `vendor/`, whose hazard was drift: a test passing against a copy proves
-- nothing about the file that ships. Writing this file is what surfaced it -- a mutant that
-- reverted the copy survived every archetype suite -- so the copies are gone.
local Bots = require("./shim/library")("Bots")

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

print("a sensor with an interval polls; invalidate makes it due once")
do
	local reads = 0
	local board = Bots.Blackboard.new("test")
	-- A long interval, so nothing here can be explained by the timer coming round.
	board:addSensor("stations", function()
		reads += 1
		return reads
	end, 60)

	board:update(1000)
	check("the first update always reads", reads == 1, reads)
	check("and writes the value", board:get("stations") == 1, board:get("stations"))

	--[[
		1050, not 1059. Reschedules carry +/-10% PHASE_JITTER, so a 60s sensor primed at 1000 is
		next due anywhere in [1054, 1066] -- and probing at 1059 passes or fails depending on
		the seed. Every time bound in this file stays strictly inside the jitter's range for
		that reason; do not tighten them.
	]]
	board:update(1001)
	board:update(1010)
	board:update(1050)
	check("later updates inside the interval do not", reads == 1, reads)

	check("invalidate reports it found the sensor", board:invalidate("stations") == true)
	check("but does not read on its own", reads == 1, reads)

	--[[
		THE RECOMPUTE HAPPENS INSIDE THE UPDATE, which is the whole point: sensor reads
		belong there, so a shared list cannot be rebuilt while a bot is mid-read of it.
	]]
	board:update(1060)
	check("the next update recomputes", reads == 2, reads)
	check("and the new value is written", board:get("stations") == 2, board:get("stations"))

	board:update(1061)
	check("exactly once, not on every update after", reads == 2, reads)
end

print("bursts coalesce")
do
	local reads = 0
	local board = Bots.Blackboard.new("test")
	board:addSensor("stations", function()
		reads += 1
		return reads
	end, 60)
	board:update(1000)
	check("primed", reads == 1, reads)

	-- Fifty things tagged in one frame. This is the reason invalidation beats pushing with
	-- `set`: the caller does not have to debounce its own bursts.
	for _ = 1, 50 do
		board:invalidate("stations")
	end
	board:update(1001)
	check("fifty invalidations are ONE rebuild", reads == 2, reads)
end

print("an un-invalidated sensor is left alone")
do
	local hot, cold = 0, 0
	local board = Bots.Blackboard.new("test")
	board:addSensor("hot", function()
		hot += 1
		return hot
	end, 60)
	board:addSensor("cold", function()
		cold += 1
		return cold
	end, 60)

	board:update(1000)
	check("both primed", hot == 1 and cold == 1, `{hot}/{cold}`)

	board:invalidate("hot")
	board:update(1001)
	check("the invalidated one recomputes", hot == 2, hot)
	-- The assertion that makes the first one mean anything: invalidating a key must not
	-- refresh the whole board.
	check("its neighbour does not", cold == 1, cold)
end

print("it resets the timer rather than inserting an extra read")
do
	local reads = 0
	local board = Bots.Blackboard.new("test")
	board:addSensor("stations", function()
		reads += 1
		return reads
	end, 10)

	board:update(1000)
	board:invalidate("stations")
	board:update(1001) -- recomputes here, and reschedules FROM 1001
	check("recomputed on demand", reads == 2, reads)

	--[[
		Rescheduled from the moment it ran, not from when it was originally due. The jitter in
		Config.PHASE_JITTER means the next due time is 1001 + 10*jitter, so 1005 is inside the
		interval for any jitter above 0.4 -- and 1002 is inside it for anything above 0.1.
	]]
	board:update(1002)
	check("and is not due again immediately", reads == 2, reads)
end

print("a key with no sensor is a no-op, and says so")
do
	local board = Bots.Blackboard.new("test")
	-- Silent would hide a typo AND a removed sensor, and nothing can tell those apart from
	-- in here. Returning false at least makes the distinction available to the caller.
	check("invalidating an unknown key returns false", board:invalidate("nothing") == false)
	check("and does not create one", board:get("nothing") == nil)

	board:addSensor("gone", function()
		return 1
	end, 60)
	board:removeSensor("gone")
	check("a removed sensor also returns false", board:invalidate("gone") == false)
end

print("the key is type-checked, like every other sensor call")
do
	local board = Bots.Blackboard.new("test")
	check("a non-string key errors", not pcall(board.invalidate, board, 42 :: any))
	check("an empty key errors", not pcall(board.invalidate, board, ""))
	check("and nil errors", not pcall(board.invalidate, board, nil :: any))
end

print("it works on a clock that does not start at zero")
do
	--[[
		The clock only promises to be MONOTONIC. A game running on its own epoch -- a negative
		offset, a countdown -- would break an implementation that spelled "due" as `nextAt = 0`,
		because `now >= 0` is false there. That is a sensor which can never be invalidated, on
		the one timeline nobody tests with.
	]]
	local reads = 0
	local board = Bots.Blackboard.new("test")
	board:addSensor("stations", function()
		reads += 1
		return reads
	end, 60)

	board:update(-5000)
	check("primed on a negative clock", reads == 1, reads)

	board:update(-4999)
	check("and throttled there too", reads == 1, reads)

	board:invalidate("stations")
	board:update(-4998)
	check("invalidate still works below zero", reads == 2, reads)
end

print("a sensor that reads every tick is unaffected")
do
	local reads = 0
	local board = Bots.Blackboard.new("test")
	board:addSensor("always", function()
		reads += 1
		return reads
	end) -- no interval: every update

	board:update(1000)
	board:update(1001)
	check("it reads every update", reads == 2, reads)
	check("invalidate finds it", board:invalidate("always") == true)
	board:update(1002)
	-- Nothing to accelerate, and nothing broken by asking.
	check("and changes nothing", reads == 3, reads)
end

print("the fact store is untouched by it")
do
	local board = Bots.Blackboard.new("test")
	board:addSensor("stations", function(_, bb)
		bb:setFact("seen", "here", 8)
		return 1
	end, 60)
	board:update(1000)
	check("the sensor wrote a fact", (board:getFact("seen")) == "here")

	board:invalidate("stations")
	-- Invalidation is about sensor scheduling. A fact's own ttl is a separate clock and must
	-- not be reset by it.
	local value, confidence = board:getFact("seen", 1004)
	check("the fact keeps decaying on its own timeline", value == "here" and confidence ~= nil, confidence)
	check("and is half gone at half its ttl", confidence and math.abs(confidence - 0.5) < 1e-9, confidence)
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("bots blackboard tests failed", 0)
end
