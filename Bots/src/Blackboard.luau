--!strict

-- A blackboard is a named bag of values plus the SENSORS that keep those values
-- fresh. The same class serves all three scopes:
--   * Brain.master    -- one global board every bot can read (round state, alarm level, ...)
--   * group boards    -- consumer-created via Blackboard.new, shared by whichever
--                        bots are given them (squad knowledge: "last seen player pos")
--   * bot.blackboard  -- one personal board per bot (my target, my post, my fear)
--
-- The consumer defines WHAT is sensed and HOW: addSensor(key, read, interval?)
-- registers a function whose return value is written to `key` each update. The
-- Brain updates master once per tick, each distinct group board once per tick,
-- and each bot's personal board right before that bot plans. `interval`
-- throttles expensive perception (raycasts, scans) to every N seconds instead
-- of every tick.
--
-- Reads: bb:get / bb.values for one board, or bot:get(key) for the fallthrough
-- view (personal -> group -> master), so goals and actions ask for "the current
-- state of the world" with one call.
--
-- WORKING MEMORY. Beside the plain values sits a fact store: setFact writes a
-- value with a timestamp, a confidence, and an optional ttl; getFact returns
-- the value plus its confidence DECAYED linearly toward 0 across the ttl, and
-- an expired fact reads as nil -- forgotten, exactly like one never written.
-- Plain values are for current state ("alarmLevel"); facts are for beliefs
-- that go stale ("last seen player position, forget after 8s"). Sensors can
-- write facts too: their second argument is the board, so
-- `bb:setFact("lastSeenPos", pos, 8)` inside a read function is the idiomatic
-- perception-memory pattern.

local Clock = require(script.Parent.Clock)
local Config = require(script.Parent.Config)
local Rng = require(script.Parent.Rng)
local Types = require(script.Parent.Types)

-- Seconds between fact sweeps. Expiry is enforced on read regardless; this is
-- purely how often forgotten facts are reclaimed.
local FACT_SWEEP_INTERVAL = 5

type Sensor = {
	read: (owner: any, bb: Types.Blackboard) -> any,
	interval: number,
	nextAt: number,
}

-- Sensor phase jitter lives in Config (PHASE_JITTER) and goes through Rng, so a
-- seeded run is reproducible. Same-interval sensors across a fleet spawned
-- together would otherwise stay phase-aligned forever and fire as one
-- synchronized spike; the jitter makes their phases drift apart over a few cycles
-- instead. (The FIRST read still runs on the first update, so a new bot always
-- plans against fresh data.)

local Blackboard = {}

-- `owner` is handed to every sensor as its first argument: pass the bot for a
-- personal board (Bot.new does), your squad object for a group board, or
-- nothing. `initialValues` seeds `values` ("what values the board should have").
function Blackboard.new(name: string, initialValues: { [string]: any }?, owner: any): Types.Blackboard
	assert(type(name) == "string" and name ~= "", "Bots.Blackboard.new: a non-empty name is required")
	assert(
		initialValues == nil or type(initialValues) == "table",
		"Bots.Blackboard.new: initialValues must be a table when set"
	)

	local sensors: { [string]: Sensor } = {}
	local facts: { [string]: Types.Fact } = {}
	-- The clock this board was last updated with. Fact timestamps default to it,
	-- so a sensor writing a fact during an update stamps THAT update's time --
	-- the board cannot drift onto a different timeline than the one driving it.
	-- Falls back to the package clock before the first update. See Clock.luau.
	local updatedAt: number? = nil

	local function boardNow(now: number?): number
		return now or updatedAt or Clock.now()
	end

	-- The fact sweep only reclaims memory: getFact already expires a fact on READ,
	-- so correctness never depends on it running. Walking every fact on every
	-- board update was therefore per-step work for a housekeeping job, and this
	-- throttles it to something appropriate to housekeeping.
	local nextSweepAt: number? = nil

	local bb = {} :: Types.Blackboard
	bb.name = name
	bb.owner = owner
	bb.values = if initialValues then table.clone(initialValues) else {}

	function bb.get(_, key: string): any
		return bb.values[key]
	end

	function bb.set(_, key: string, value: any)
		bb.values[key] = value
	end

	-- Remember `value` under `key` with belief `confidence` (default 1), fading
	-- to forgotten across `ttl` seconds (nil = never fades). `now` defaults to
	-- the board's last update clock (then the package clock); inject when testing.
	function bb.setFact(_, key: string, value: any, ttl: number?, confidence: number?, now: number?)
		assert(type(key) == "string" and key ~= "", `Bots.Blackboard "{name}": fact key must be a non-empty string`)
		assert(
			ttl == nil or type(ttl) == "number",
			`Bots.Blackboard "{name}": fact "{key}" ttl must be a number when set`
		)
		assert(
			confidence == nil or type(confidence) == "number",
			`Bots.Blackboard "{name}": fact "{key}" confidence must be a number when set`
		)
		facts[key] = {
			value = value,
			confidence = confidence or 1,
			at = boardNow(now),
			ttl = ttl,
		}
	end

	-- (value, decayed confidence), or (nil, nil) when unknown or expired.
	function bb.getFact(_, key: string, now: number?): (any, number?)
		local fact = facts[key]
		if not fact then
			return nil, nil
		end
		local confidence = fact.confidence
		local ttl = fact.ttl
		if ttl then
			local age = boardNow(now) - fact.at
			if age >= ttl then
				facts[key] = nil -- fully decayed: forget it
				return nil, nil
			end
			confidence *= 1 - age / ttl
		end
		return fact.value, confidence
	end

	function bb.forget(_, key: string)
		facts[key] = nil
	end

	function bb.addSensor(_, key: string, read: (any, Types.Blackboard) -> any, interval: number?)
		assert(type(key) == "string" and key ~= "", `Bots.Blackboard "{name}": sensor key must be a non-empty string`)
		assert(type(read) == "function", `Bots.Blackboard "{name}": sensor "{key}" needs a read function`)
		assert(
			interval == nil or type(interval) == "number",
			`Bots.Blackboard "{name}": sensor "{key}" interval must be a number when set`
		)
		--[[
			-math.huge, not 0, so the FIRST read genuinely always runs -- the promise in the
			header. The clock only has to be MONOTONIC, so a game on its own epoch can drive
			this board with negative values, and `now >= 0` is false there: the sensor would
			never fire once, and the bot would plan against an empty board forever. Identical
			behaviour on any clock that starts above zero, which is why it went unnoticed.
		]]
		sensors[key] = { read = read, interval = interval or 0, nextAt = -math.huge }
	end

	function bb.removeSensor(_, key: string)
		sensors[key] = nil
	end

	--[[
		Marks a sensor DUE, so the next update recomputes it once. Returns whether there
		was such a sensor, so a misspelled key is visible rather than silent.

		FOR A DERIVED VALUE THAT CHANGES ON AN EVENT, which had no good home before. A
		sensor with an `interval` POLLS it -- a wasted read every lap, plus up to one
		interval of staleness -- and `set` PUSHES it, which is correct but puts the
		recompute outside the update and makes every caller debounce its own bursts.
		Invalidation is the standard shape for this: dirty flag, lazy recompute.

		It composes with what the board already does, which is the point:

		  * COALESCING. Fifty things tagged in one frame are one rebuild, not fifty,
		    because this only sets a flag and the read happens in the next update.
		  * The recompute stays INSIDE the update, where sensor reads belong, so a
		    shared list cannot be rebuilt while a bot is mid-read of it.

		IT RESETS THE TIMER, it does not insert an extra read. After the invalidated
		sensor runs, it is rescheduled from that moment like any other -- so a long
		interval invalidated repeatedly recomputes on demand and never faster than the
		update it rides on.

		-math.huge rather than 0: the clock only promises to be MONOTONIC, so a game on
		its own epoch can hand this board negative values, and `now >= 0` would read as
		"not due" -- a sensor that could never be invalidated, on the one timeline nobody
		tests with.
	]]
	function bb.invalidate(_, key: string): boolean
		assert(
			type(key) == "string" and key ~= "",
			`Bots.Blackboard "{name}": invalidate key must be a non-empty string`
		)
		local sensor = sensors[key]
		if not sensor then
			return false
		end
		sensor.nextAt = -math.huge
		return true
	end

	-- Run every due sensor and write its value, then sweep fully-decayed facts.
	-- The Brain calls this on its schedule; calling it yourself is fine too
	-- (e.g. to refresh due sensors right after a scripted event).
	function bb.update(_, now: number)
		updatedAt = now
		for key, sensor in sensors do
			if now >= sensor.nextAt then
				-- Reschedule with phase jitter (see the note at the top of this file).
				sensor.nextAt = now + sensor.interval * Rng.jitter(Config.PHASE_JITTER)
				bb.values[key] = sensor.read(owner, bb)
			end
		end
		if nextSweepAt == nil or now >= nextSweepAt then
			nextSweepAt = now + FACT_SWEEP_INTERVAL
			for key, fact in facts do
				local ttl = fact.ttl
				if ttl and now - fact.at >= ttl then
					facts[key] = nil
				end
			end
		end
	end

	return bb
end

return Blackboard
