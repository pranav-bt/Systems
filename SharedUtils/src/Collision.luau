local Collision = {}

function Collision.pointInBox(point: Vector3, boxCframe: CFrame, boxSize: Vector3): boolean
	local boxHalfSize = boxSize / 2
	local localPoint = boxCframe:Inverse() * point

	return math.abs(localPoint.X) <= boxHalfSize.X
		and math.abs(localPoint.Y) <= boxHalfSize.Y
		and math.abs(localPoint.Z) <= boxHalfSize.Z
end

function Collision.aabbIntersectsBox(
	aabbCenter: Vector3,
	aabbSize: Vector3,
	boxCframe: CFrame,
	boxSize: Vector3
): boolean
	local boxHalfSize = boxSize / 2
	local aabbHalfSize = aabbSize / 2

	local localCenter = boxCframe:Inverse() * aabbCenter

	-- Calculate the AABB's extents when projected onto the box's local axes
	local boxRight = boxCframe.RightVector
	local boxUp = boxCframe.UpVector
	local boxLook = boxCframe.LookVector

	local extentX = math.abs(boxRight.X) * aabbHalfSize.X
		+ math.abs(boxRight.Y) * aabbHalfSize.Y
		+ math.abs(boxRight.Z) * aabbHalfSize.Z
	local extentY = math.abs(boxUp.X) * aabbHalfSize.X
		+ math.abs(boxUp.Y) * aabbHalfSize.Y
		+ math.abs(boxUp.Z) * aabbHalfSize.Z
	local extentZ = math.abs(boxLook.X) * aabbHalfSize.X
		+ math.abs(boxLook.Y) * aabbHalfSize.Y
		+ math.abs(boxLook.Z) * aabbHalfSize.Z

	-- Check intersection: AABB center distance + AABB extent must be <= box extent
	return math.abs(localCenter.X) <= boxHalfSize.X + extentX
		and math.abs(localCenter.Y) <= boxHalfSize.Y + extentY
		and math.abs(localCenter.Z) <= boxHalfSize.Z + extentZ
end

function Collision.aabbIntersectsSphere(
	aabbCenter: Vector3,
	aabbSize: Vector3,
	sphereCenter: Vector3,
	radius: number
): boolean
	local aabbMin = aabbCenter - aabbSize / 2
	local aabbMax = aabbCenter + aabbSize / 2

	local closestPoint = Vector3.new(
		math.clamp(sphereCenter.X, aabbMin.X, aabbMax.X),
		math.clamp(sphereCenter.Y, aabbMin.Y, aabbMax.Y),
		math.clamp(sphereCenter.Z, aabbMin.Z, aabbMax.Z)
	)

	local distanceSquared = (closestPoint - sphereCenter).Magnitude ^ 2
	return distanceSquared <= radius * radius
end

return Collision
