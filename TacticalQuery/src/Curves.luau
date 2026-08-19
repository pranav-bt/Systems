--!strict

-- Tiny scoring ramps for writing test `score` functions. Kept local to this
-- package (rather than depending on Bots.Utility) so TacticalQuery stays
-- zero-dependency; the semantics match Bots.Utility where they overlap.

local Curves = {}

function Curves.clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

-- Straight ramp: 0 at `from`, 1 at `to`, linear in between, clamped. Pass
-- from > to for a descending response.
function Curves.linear(x: number, from: number, to: number): number
	if from == to then
		-- Degenerate ramp: read it as a step at the shared boundary.
		return if x >= to then 1 else 0
	end
	return Curves.clamp01((x - from) / (to - from))
end

-- Tent around an ideal value: 1 at `center`, falling linearly to 0 at
-- `center ± halfWidth`. The curve for "prefer positions ABOUT this far away".
--
-- halfWidth must be > 0: at 0 this divides by zero, and `abs(0)/0` is NaN rather
-- than infinity -- a NaN that clamp01 will not sanitise and that poisons every
-- score it touches. `linear` guards its own degenerate case the same way.
function Curves.band(x: number, center: number, halfWidth: number): number
	assert(type(halfWidth) == "number" and halfWidth > 0, "TacticalQuery.Curves.band: halfWidth must be a number > 0")
	return 1 - Curves.clamp01(math.abs(x - center) / halfWidth)
end

return Curves
