local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local ItemDefinitions = require(script.Parent.Parent.shared.ItemDefinitions)

local Placement3D = {}
local GRID_SIZE = 0.5
local SNAP_DISTANCE_THRESHOLD = 5
local SNAP_SEARCH_DISTANCE_THRESHOLD = 10

local function snapToWorldGrid(position: Vector3, gridSize: number, normal): Vector3
	local x = position.X
	local y = position.Y
	local z = position.Z

	if math.abs(normal.X) < 0.99 then
		x = math.floor(x / gridSize + 0.5) * gridSize
	end
	if math.abs(normal.Y) < 0.99 then
		y = math.floor(y / gridSize + 0.5) * gridSize
	end
	if math.abs(normal.Z) < 0.99 then
		z = math.floor(z / gridSize + 0.5) * gridSize
	end

	return Vector3.new(x, y, z)
end

function Placement3D.alignToSurface(
	model: Model,
	hitPosition: Vector3,
	normal: Vector3,
	rotationAngleDeg: number?,
	offset: number?
)
	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart")
		if not model.PrimaryPart then
			warn("No PrimaryPart found for model", model.Name)
			return
		end
	end

	local angleRad = math.rad(rotationAngleDeg or 0)

	local up = normal.Unit
	local forward = Vector3.new(0, 1, 0)
	if math.abs(up:Dot(forward)) > 0.99 then
		forward = Vector3.new(1, 0, 0)
	end
	local right = up:Cross(forward).Unit
	local finalForward = right:Cross(up).Unit

	local userRotation = CFrame.fromAxisAngle(up, angleRad)
	local baseOrientation = userRotation * CFrame.fromMatrix(Vector3.zero, right, up, finalForward)

	local offsetDistance = offset or Placement3D.calculateOffsetFromCollider(model, normal)
	local offsetPosition = hitPosition + normal * offsetDistance
	local snappedPosition = snapToWorldGrid(offsetPosition, GRID_SIZE, normal)
	local finalCFrame = CFrame.new(snappedPosition) * baseOrientation
	model:SetPrimaryPartCFrame(finalCFrame)
end

function Placement3D.CanOverlap(PlacementData, voxelCoord, data)
	for _, itemsAtCoord in PlacementData.voxelPlacementData[`{voxelCoord.X},{voxelCoord.Y},{voxelCoord.Z}`].itemDefs do
		local foundCompatibility = false
		for _, compatibleItems in itemsAtCoord.AllowOverlapWith do
			if compatibleItems == data.itemDef.Category then
				foundCompatibility = true
				break
			end
		end
		if not foundCompatibility then
			return false
		end
	end
	return true
end

function Placement3D.CanPlaceItem(PlacementData, voxelCoord, data)
	if PlacementData.voxelPlacementData[`{voxelCoord.X},{voxelCoord.Y},{voxelCoord.Z}`] == nil then
		PlacementData.voxelPlacementData[`{voxelCoord.X},{voxelCoord.Y},{voxelCoord.Z}`] =
			{ Occupied = false, itemDefs = {} }
	end
	if
		data.itemDef.PlacementSurface == "Floor"
		and PlacementData.hitObject
		and (
			(
				ItemDefinitions[PlacementData.hitObject.Name]
				and ItemDefinitions[PlacementData.hitObject.Name].Category ~= "Floor"
			) or not ItemDefinitions[PlacementData.hitObject.Name]
		)
	then
		return false
	elseif
		((data.snapped and not data.itemDef.IgnorePointerOnSnap) or not data.snapped)
		and (
			(
				data.itemDef.PlacementSurface ~= "Floor"
				and (not PlacementData.hitObject or PlacementData.hitObject == workspace)
			)
			or (
				(data.itemDef.PlacementSurface ~= "Floor")
				and PlacementData.hitObject
				and ItemDefinitions[PlacementData.hitObject.Name]
				and ItemDefinitions[PlacementData.hitObject.Name].Type ~= data.itemDef.PlacementSurface
			)
		)
	then
		return false
	elseif
		data.itemDef.PlacementType
		and data.itemDef.PlacementType == "HorizontalSurface"
		and PlacementData.normal.Y < 0.9
	then
		return false
	elseif
		PlacementData.voxelPlacementData[`{voxelCoord.X},{voxelCoord.Y},{voxelCoord.Z}`].Occupied
		and not Placement3D.CanOverlap(PlacementData, voxelCoord, data)
	then
		return false
	else
		return true
	end
end

function Placement3D.snapModelToSnapPoint(sourceModel, sourceSnap, targetModel, targetSnap, normal, rotationAngleDeg)
	local sourceOffset = ItemDefinitions[sourceModel.Name].SnapPoints[sourceSnap].Position
	local targetOffset = ItemDefinitions[targetModel.Name].SnapPoints[targetSnap].Position

	local sourceWorldSnap = sourceModel.PrimaryPart.CFrame:PointToWorldSpace(sourceOffset)
	local targetWorldSnap = targetModel.PrimaryPart.CFrame:PointToWorldSpace(targetOffset)

	local angleRad = math.rad(rotationAngleDeg or 0)

	local up = normal.Unit
	local forward = Vector3.new(0, 1, 0)
	if math.abs(up:Dot(forward)) > 0.99 then
		forward = Vector3.new(1, 0, 0)
	end
	local right = up:Cross(forward).Unit
	local finalForward = right:Cross(up).Unit

	local userRotation = CFrame.fromAxisAngle(up, angleRad)
	local baseOrientation = userRotation * CFrame.fromMatrix(Vector3.zero, right, up, finalForward)

	local delta = targetWorldSnap - sourceWorldSnap
	local preAlignedCFrame = sourceModel.PrimaryPart.CFrame + delta
	local finalCFrame = CFrame.new(preAlignedCFrame.Position) * baseOrientation

	return finalCFrame
end

function Placement3D.trySnapToNearby(model: Model, itemDef, hitPoint, surfaceNormal, rotationAngle)
	if not model.PrimaryPart or not itemDef or not itemDef.SnapPoints then
		return { finalCFrame = nil }
	end

	if itemDef.FixedOrientationOnSnap then
		surfaceNormal = itemDef.FixedOrientationOnSnap
	end

	local function FindClosestSnap(previewModel, snapData, anchorPoint)
		local closestPoint = snapData.SnapTo[1]
		if #snapData.SnapTo > 1 then
			local closestDistance = (anchorPoint - previewModel.PrimaryPart[closestPoint].WorldCFrame.Position).Magnitude
			for _, snapPoint in snapData.SnapTo do
				if
					(anchorPoint - previewModel.PrimaryPart[snapPoint].WorldCFrame.Position).Magnitude
					< closestDistance
				then
					closestPoint = snapPoint
				end
			end
		end
		return closestPoint
	end

	local finalCframe = nil
	local finalModel = nil
	local SNAP_SEARCH_DISTANCE = if itemDef.SnapSearchDistanceThresholdOverride
		then itemDef.SnapSearchDistanceThresholdOverride
		else SNAP_SEARCH_DISTANCE_THRESHOLD
	local SNAP_DISTANCE = if itemDef.SnapDistanceThresholdOveride
		then itemDef.SnapDistanceThresholdOveride
		else SNAP_DISTANCE_THRESHOLD

	for _, snapData in pairs(itemDef.SnapPoints) do
		local snapWorldPos = model.PrimaryPart.CFrame:PointToWorldSpace(snapData.Position)

		local nearbyParts = workspace:GetPartBoundsInRadius(hitPoint, SNAP_SEARCH_DISTANCE)
		for _, part in nearbyParts do
			local nearbyModel = part:FindFirstAncestorWhichIsA("Model")
			if nearbyModel and nearbyModel ~= model and ItemDefinitions[nearbyModel.Name] then
				local nearbyDef = ItemDefinitions[nearbyModel.Name]
				local isCompatible = false

				if nearbyDef.SnapPoints then
					for _, value in pairs(nearbyDef.SnapPoints) do
						for _, allowed in value.CompatibleWith do
							if allowed == itemDef.Type then
								isCompatible = true
								break
							end
						end
					end

					if not isCompatible then
						continue
					end

					if isCompatible then
						local closestDistance = math.huge
						local closestSnapName = ""
						local closestSnapData = {}
						local finalWorldPos = nil
						for theirSnapName, theirSnapData in pairs(nearbyDef.SnapPoints) do
							local shouldConsiderThisSnap = false
							for _, item in theirSnapData.CompatibleWith do
								if item == itemDef.Type then
									shouldConsiderThisSnap = true
									break
								end
							end

							if not shouldConsiderThisSnap then
								continue
							end

							local theirWorldPos =
								nearbyModel.PrimaryPart.CFrame:PointToWorldSpace(theirSnapData.Position)
							if (hitPoint - theirWorldPos).Magnitude < closestDistance then
								closestDistance = (hitPoint - theirWorldPos).Magnitude
								closestSnapData = theirSnapData
								closestSnapName = theirSnapName
								finalWorldPos = theirWorldPos
							end
						end
						local closestSnap = FindClosestSnap(model, closestSnapData, finalWorldPos)
						if itemDef.SnapPoints[closestSnap] then
							snapWorldPos =
								model.PrimaryPart.CFrame:PointToWorldSpace(itemDef.SnapPoints[closestSnap].Position)
							if (finalWorldPos - snapWorldPos).Magnitude <= SNAP_DISTANCE then
								local theirCFrame = Placement3D.snapModelToSnapPoint(
									model,
									closestSnap,
									nearbyModel,
									closestSnapName,
									surfaceNormal,
									rotationAngle
								)
								finalCframe = theirCFrame
								finalModel = nearbyModel
							end
						else
							continue
						end
					end
				end
			end
		end
	end

	local wallstoIngnoreForCollision = {}

	local function FindOverlappingWallsInRadius(point, radius)
		local function arePositionsClose(posA: Vector3, posB: Vector3, threshold: number?): boolean
			return (posA - posB).Magnitude <= (threshold or 0.001)
		end

		local nearbyParts = workspace:GetPartBoundsInRadius(point, radius)
		for _, part in nearbyParts do
			local nearbyModel = part:FindFirstAncestorWhichIsA("Model")
			if
				nearbyModel
				and nearbyModel ~= model
				and ItemDefinitions[nearbyModel.Name]
				and ItemDefinitions[nearbyModel.Name].Category == "Wall"
				and not arePositionsClose(model.PrimaryPart.CFrame.Position, nearbyModel.PrimaryPart.CFrame.Position)
			then
				table.insert(wallstoIngnoreForCollision, nearbyModel)
			end
		end
	end

	if finalModel then
		model:SetPrimaryPartCFrame(finalCframe)
		if itemDef.Category == "Wall" then
			FindOverlappingWallsInRadius(model.PrimaryPart["Left"].WorldCFrame.Position, 0.2)
			FindOverlappingWallsInRadius(model.PrimaryPart["Right"].WorldCFrame.Position, 0.2)
		end
	end
	return {
		finalCFrame = finalCframe,
		wallsToIgnoreForCollisions = wallstoIngnoreForCollision,
		surfaceNormal = if itemDef.FixedOrientationOnSnap then itemDef.FixedOrientationOnSnap else nil,
	}
end

-- Known stub: always returns 0 (the CastleWars original never wired up a
-- per-collider offset). Preview offset comes entirely from the caller-provided
-- `offset`/`itemBase`. Kept as-is; see README "Known issues".
function Placement3D.calculateOffsetFromCollider(model: Model, normal: Vector3): number
	return 0
end

function Placement3D.getFloorPart(instance: Instance): Instance?
	local current: Instance? = instance
	while current and current ~= workspace do
		local def = ItemDefinitions[current.Name]
		if def and def.Category == "Floor" then
			return current
		end
		current = current.Parent
	end
	return nil
end

function Placement3D.checkPreviewCollision(model: Model, itemDef, wallsToIgnore): boolean
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = true
			PhysicsService:SetPartCollisionGroup(part, "Preview")
		end
	end

	RunService.Heartbeat:Wait()

	local function IsCompatibleTouchCollision(hit)
		local parentObject = hit:FindFirstAncestorOfClass("Model")
		if parentObject and itemDef.TouchAllowedObjects then
			for _, compatibleObject in itemDef.TouchAllowedObjects do
				if ItemDefinitions[parentObject.Name].Type == compatibleObject then
					return true
				end
			end
		end
		return false
	end

	local function ShouldIgnoreThisWall(part)
		local function checkAgainstIgnoringWalls(wallModel)
			for _, wall in wallsToIgnore do
				if wallModel == wall then
					return true
				end
			end
			return false
		end

		local intersectingModel = part:FindFirstAncestorOfClass("Model")
		if
			intersectingModel
			and ItemDefinitions[intersectingModel.Name].Category == "Wall"
			and checkAgainstIgnoringWalls(intersectingModel)
		then
			return true
		else
			return false
		end
	end

	local touching = false
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			for _, hit in part:GetTouchingParts() do
				if
					Placement3D.getFloorPart(hit) == nil
					and not ShouldIgnoreThisWall(hit)
					and not model:IsAncestorOf(hit)
					and not IsCompatibleTouchCollision(hit)
				then
					touching = true
					break
				end
			end
		end
		if touching then
			break
		end
	end

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
		end
	end

	return touching
end

return Placement3D
