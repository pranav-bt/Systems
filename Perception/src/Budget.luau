--!strict

-- A token-bucket budget for raycasts (or any metered work). Refills at
-- `perSecond` tokens continuously, holds at most `burst`. Vision sensors that
-- share one budget compete fairly for rays: when the bucket runs dry they
-- freeze the targets they couldn't cast for -- holding awareness rather than
-- guessing at it -- so a 50-bot fleet degrades to slower reactions rather than
-- a raycast storm. Sensors spend their rays on the longest-unsampled targets
-- first, so a dry budget slows everyone down instead of starving newcomers.
--
-- Time is injectable everywhere (defaults to os.clock) to keep this testable.

local Types = require(script.Parent.Types)

local Budget = {}

function Budget.new(perSecond: number, burst: number?): Types.Budget
	assert(type(perSecond) == "number" and perSecond > 0, "Perception.Budget.new: perSecond must be a number > 0")
	assert(
		burst == nil or (type(burst) == "number" and burst >= 1),
		"Perception.Budget.new: burst must be a number >= 1 when set"
	)
	local capacity = burst or math.max(1, perSecond)

	local tokens = capacity -- start full so boot-time sensing isn't starved
	local lastRefillAt: number? = nil
	-- Cumulative, because REFUSALS are the number that matters and sampling
	-- `available` at an arbitrary moment cannot show them.
	local granted, refused = 0, 0

	local function refill(now: number)
		if lastRefillAt then
			tokens = math.min(capacity, tokens + (now - lastRefillAt) * perSecond)
		end
		lastRefillAt = now
	end

	local budget = {} :: Types.Budget

	-- Spend `count` tokens (default 1). Returns false -- spending nothing --
	-- when the bucket doesn't hold that many.
	function budget.take(_, count: number?, now: number?): boolean
		local cost = count or 1
		refill(now or os.clock())
		if tokens < cost then
			refused += 1
			return false
		end
		tokens -= cost
		granted += 1
		return true
	end

	-- What this bucket has done. `refused / (granted + refused)` over a minute is
	-- the number that turns "the AI feels oblivious" into a decision about
	-- perSecond -- since starvation now HOLDS awareness, it is a gameplay signal,
	-- not just a performance one.
	function budget.stats(_, now: number?): Types.BudgetStats
		return { granted = granted, refused = refused, available = budget:available(now) }
	end

	function budget.available(_, now: number?): number
		refill(now or os.clock())
		return math.floor(tokens)
	end

	return budget
end

return Budget
