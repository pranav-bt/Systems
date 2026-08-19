--!strict

-- Claimable token pools: at most `capacity` holders at once. This is the
-- squad-coordination primitive behind classic "attack token" systems -- "only
-- two bots may engage the player simultaneously" is a pool of capacity 2 that
-- the attack goal claims before committing. Everything else about coordination
-- (WHO should get a token, orders, roles) is consumer policy layered on top;
-- the pool only enforces the count.
--
-- WHERE IT LIVES. A pool is a plain value: store it wherever the bots that
-- share it can reach it. The natural home is a blackboard --
-- `squadBoard:set("attackTokens", Tokens.new("attack", 2))` -- read in actions
-- via the usual `bot:get("attackTokens")` fallthrough.
--
-- LIFECYCLE PAIRING. Claim in an action's `enter` (Failure when the pool is
-- full), release in its `exit` -- exit ALWAYS runs, on Success, Failure, and
-- Interrupted alike, so a token cannot leak however the goal ends. The
-- optional `ttl` is the belt-and-braces backstop for holders that vanish
-- without exiting (a destroyed bot mid-action): leases expire after `ttl`
-- seconds unless refreshed, and tryClaim refreshes -- it is idempotent while
-- held, so a long-running action just claims again each update.
--
-- Holders are compared by identity and can be anything stable: the bot itself,
-- its id, or any token you choose. All `now` params default to Clock.now();
-- inject them when testing.

local Clock = require(script.Parent.Clock)
local Types = require(script.Parent.Types)

local Tokens = {}

function Tokens.new(name: string, capacity: number, ttl: number?): Types.Tokens
	assert(type(name) == "string" and name ~= "", "Bots.Tokens.new: a non-empty name is required")
	assert(type(capacity) == "number" and capacity >= 0, "Bots.Tokens.new: capacity must be a number >= 0")
	assert(ttl == nil or (type(ttl) == "number" and ttl > 0), "Bots.Tokens.new: ttl must be a positive number when set")

	-- holder -> lease expiry clock time (math.huge when the pool has no ttl).
	local leases: { [any]: number } = {}

	local pool = {} :: Types.Tokens
	pool.name = name
	pool.capacity = capacity

	-- Drop expired leases; return the live holder count.
	local function sweep(now: number): number
		local count = 0
		for holder, expiresAt in leases do
			if now >= expiresAt then
				leases[holder] = nil
			else
				count += 1
			end
		end
		return count
	end

	-- Claim a token for `holder`, or refresh their lease if they already hold
	-- one. Returns false when the pool is full (holder should treat that as
	-- "not my turn": fail or pick another goal).
	function pool.tryClaim(_, holder: any, now: number?): boolean
		assert(holder ~= nil, `Bots.Tokens "{name}": tryClaim needs a holder`)
		local clock = now or Clock.now()
		local expiresAt = if ttl then clock + ttl else math.huge
		local existing = leases[holder]
		if existing and clock < existing then
			leases[holder] = expiresAt -- already holding: refresh
			return true
		end
		if sweep(clock) >= pool.capacity then
			return false
		end
		leases[holder] = expiresAt
		return true
	end

	function pool.release(_, holder: any)
		leases[holder] = nil
	end

	function pool.holds(_, holder: any, now: number?): boolean
		local expiresAt = leases[holder]
		if not expiresAt then
			return false
		end
		if (now or Clock.now()) >= expiresAt then
			leases[holder] = nil
			return false
		end
		return true
	end

	-- Live (unexpired) holder count.
	function pool.count(_, now: number?): number
		return sweep(now or Clock.now())
	end

	-- WHO holds one right now. `count` answers "how many", which is what the pool
	-- enforces -- but when two bots sit in Patrol because the pool is full, the
	-- question is which two, and the likely bug is a holder that claimed and never
	-- released. That is exactly the holder a count cannot show you.
	function pool.holders(_, now: number?): { any }
		local clock = now or Clock.now()
		local out: { any } = {}
		for holder, expiresAt in leases do
			if clock < expiresAt then
				table.insert(out, holder)
			end
		end
		return out
	end

	-- Retune at runtime (e.g. difficulty scaling). Shrinking never evicts
	-- current holders; the pool just refuses new claims until attrition brings
	-- the count under the new capacity.
	function pool.setCapacity(_, newCapacity: number)
		assert(
			type(newCapacity) == "number" and newCapacity >= 0,
			`Bots.Tokens "{name}": capacity must be a number >= 0`
		)
		pool.capacity = newCapacity
	end

	return pool
end

return Tokens
