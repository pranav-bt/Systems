--!strict

-- Response-curve helpers for writing Goal.score functions. Each curve maps a raw
-- world metric (distance, health fraction, count, time) onto [0, 1]; combine()
-- merges several such considerations into one score. Games compose these in their
-- own goals exactly like the default policy in Goals.luau does.
--
-- Every ramp works in either direction: pass from > to for a descending response
-- (0 near `from`, 1 near `to`). All outputs are clamped to [0, 1].

local Utility = {}

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

-- Straight ramp: 0 at `from`, 1 at `to`, linear in between.
function Utility.linear(x: number, from: number, to: number): number
	if from == to then
		-- Degenerate ramp: read it as a step at the shared boundary.
		return if x >= to then 1 else 0
	end
	return clamp01((x - from) / (to - from))
end

-- Eased ramp: like linear but squared, so the response stays low near `from` and
-- accelerates toward `to`. Good for urgency that should only dominate near the end
-- of its range.
function Utility.quad(x: number, from: number, to: number): number
	local t = Utility.linear(x, from, to)
	return t * t
end

-- Smooth S-curve: ~0 well below `mid`, 0.5 at `mid`, ~1 well above. `steepness`
-- controls how sharp the transition is (8-15 works well on [0, 1] inputs);
-- a NEGATIVE steepness flips the curve (1 below `mid`, 0 above). The continuous
-- replacement for a hard threshold.
function Utility.logistic(x: number, mid: number, steepness: number): number
	return clamp01(1 / (1 + math.exp(-steepness * (x - mid))))
end

-- Merge several [0, 1] considerations into one score. A plain product punishes
-- goals for having MORE considerations (0.8 * 0.8 * 0.8 < 0.8 alone), so each
-- factor is first compensated toward 1 based on how many there are, then
-- multiplied. Any consideration at 0 still zeroes the result.
function Utility.combine(...: number): number
	local n = select("#", ...)
	if n == 0 then
		return 0
	end
	local compensation = 1 - 1 / n
	local result = 1
	for i = 1, n do
		local s = clamp01(select(i, ...))
		result *= s + (1 - s) * s * compensation
	end
	return result
end

return Utility
