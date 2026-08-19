local Context = require(script.Parent.Context)
local Placement3D = require(script.Parent.Placement3D)
local PlacementValidator = {}
local occupiedCellsToCheck = {}

local function getOccupiedVoxels(model: Model, cachedBoundsVariables)
	local collider = model:FindFirstChild("Collider") or model.PrimaryPart
	if not collider then
		warn("No Collider or PrimaryPart found")
		return {}
	end

	local voxelList = {}

	local size = collider.Size
	local resolution = 2.0
	local halfSize = size / 2
	local originCFrame = collider.CFrame

	for lx = -halfSize.X, halfSize.X, resolution do
		for ly = -halfSize.Y, halfSize.Y, resolution do
			for lz = -halfSize.Z, halfSize.Z, resolution do
				local localOffset = Vector3.new(lx, ly, lz)
				local worldPos = originCFrame:PointToWorldSpace(localOffset)
				local coord = Context.grid.positionToCoord(worldPos)
				local key = `{coord.X},{cachedBoundsVariables.MinimumVoxelcoord.Y},{coord.Z}`

				if not voxelList[key] then
					voxelList[key] = true
				end
			end
		end
	end

	local result = {}
	for k in pairs(voxelList) do
		local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
		table.insert(result, Vector3.new(tonumber(x), tonumber(y), tonumber(z)))
	end

	return result
end

function PlacementValidator.CheckIfValidPlacement(
	currentPreview,
	itemDef,
	currentHighlight,
	currentPreviewColor,
	clientPlacementData,
	snapped,
	cachedBoundsVariables
)
	local canPlaceClientCheck = false
	occupiedCellsToCheck = getOccupiedVoxels(currentPreview, cachedBoundsVariables)
	local isBlocked = Placement3D.checkPreviewCollision(currentPreview, itemDef, snapped.wallsToIgnoreForCollisions)
	canPlaceClientCheck = not isBlocked
	if canPlaceClientCheck then
		for _, voxelCoord in occupiedCellsToCheck do
			if
				not Placement3D.CanPlaceItem(
					clientPlacementData,
					voxelCoord,
					{ itemDef = itemDef, snapped = snapped.finalCFrame }
				)
			then
				canPlaceClientCheck = false
				break
			end
		end
	end

	currentHighlight = if currentHighlight then currentHighlight else Instance.new("Highlight")
	currentHighlight.Adornee = currentPreview
	currentHighlight.FillTransparency = 0.3
	currentHighlight.OutlineTransparency = 1
	currentHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
	currentHighlight.Parent = workspace
	currentPreviewColor = currentHighlight.FillColor

	if not canPlaceClientCheck and currentPreviewColor ~= Color3.new(1, 0, 0) then
		currentPreviewColor = Color3.new(1, 0, 0)
		currentHighlight.FillColor = Color3.fromRGB(255, 0, 0)
	elseif canPlaceClientCheck and currentPreviewColor ~= Color3.new(0, 1, 0) then
		currentPreviewColor = Color3.new(0, 1, 0)
		currentHighlight.FillColor = Color3.fromRGB(0, 255, 0)
	end

	return {
		canPlaceClientCheck = canPlaceClientCheck,
		currentPreviewColor = currentPreviewColor,
		currentHighlight = currentHighlight,
		occupiedCellsToCheck = occupiedCellsToCheck,
	}
end

return PlacementValidator
