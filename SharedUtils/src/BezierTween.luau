local BezierTween = {}

-- Inlined from CastleWars ReplicatedStorage.SharedLibraries.Utilities:Bezier3d
-- to keep this module dependency-free. Cubic Bezier position + tangent,
-- returned as a CFrame oriented along the curve's tangent.
local function bezier3d(p1: Vector3, h1: Vector3, p2: Vector3, h2: Vector3, t: number): CFrame
	local u = 1 - t
	local position = p1 * (u ^ 3) + h1 * 3 * (u ^ 2) * t + h2 * 3 * u * (t ^ 2) + p2 * (t ^ 3)
	local tangent = (h1 - p1) * 3 * u ^ 2 + (h2 - h1) * 6 * u * t + (p2 - h2) * 3 * t ^ 2
	return CFrame.lookAlong(position, tangent)
end

function BezierTween.CreateTween(startPosition, startHandle, endPosition, endHandle, duration)
	local startTime = time()

	local function evaluate()
		return bezier3d(
			startPosition,
			startHandle,
			endPosition,
			endHandle,
			math.min((time() - startTime) / duration, 1)
		)
	end

	return { evaluate = evaluate }
end

return BezierTween
