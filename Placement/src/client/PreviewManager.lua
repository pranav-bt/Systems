local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Context = require(script.Parent.Context)
local ItemDefinitions = require(script.Parent.Parent.shared.ItemDefinitions)
local Items = require(script.Parent.Items)
local Placement3D = require(script.Parent.Placement3D)
local PlacementValidator = require(script.Parent.PlacementValidator)
local PreviewManager =
	{ currentPreview = nil, lastHitMobile = nil, showingItemPreview = false, ISMOBILE_LOOK_PLACEMENT_MODE = true }

local itemDef = nil
local previewInventory = {}
for _, item in pairs(Items) do
	table.insert(previewInventory, item)
end

local placementData = {}
local clientPlacementData = { voxelPlacementData = {} }

local grid = Context.grid
local remotePlaceItem = ReplicatedStorage:WaitForChild("PlaceItem")
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local spawnedPreviewOnMobile = false
local currentHighlight = nil
local deleteMode = false
local currentPreviewIndex = 1
PreviewManager.currentPreview = previewInventory[currentPreviewIndex]:Clone()
local currentPreviewColor = Color3.new(0, 1, 0)
local deletePointer = nil

local itemBase = nil

local rotationAngle = 0
local rotationStep = 90

local occupiedCellsToCheck = {}

local canPlaceClientCheck = true

local cachedBoundsVariables = {
	cframe = nil,
	size = nil,
	min = nil,
	max = nil,

	minFloor = nil,
	maxFloor = nil,

	MinimumVoxelcoord = nil,
	MaximumVoxelcoord = nil,
}

local function ShowDeletePointer()
	deletePointer = if deletePointer then deletePointer else Instance.new("Part")
	deletePointer.Name = "DeletionPointer"
	deletePointer.Size = Vector3.new(1, 1, 1)
	deletePointer.Anchored = true
	deletePointer.CanCollide = false
	deletePointer.CanTouch = false
	deletePointer.CanQuery = false
	deletePointer.Transparency = 0
	deletePointer.Color = Color3.fromRGB(255, 0, 0)
	deletePointer.Material = Enum.Material.Neon
	deletePointer.CastShadow = false
	deletePointer.Parent = workspace
end

local function HideDeletePointer()
	if deletePointer then
		deletePointer.Transparency = 1
	end
end

local function ShowPreview()
	PreviewManager.currentPreview.Parent = workspace
	for _, mesh in PreviewManager.currentPreview:GetChildren() do
		if mesh:IsA("MeshPart") then
			mesh.Transparency = 0.0
			mesh.Anchored = true
			mesh.CanCollide = false
			mesh.CanQuery = if isMobile and not PreviewManager.ISMOBILE_LOOK_PLACEMENT_MODE then true else false
			mesh.CanTouch = false
		elseif mesh:IsA("BasePart") then
			if mesh.Name ~= "CustomCollider" then
				mesh.Transparency = 0.0
			end
			mesh.Anchored = true
			mesh.CanCollide = false
			mesh.CanQuery = if isMobile and not PreviewManager.ISMOBILE_LOOK_PLACEMENT_MODE then true else false
			mesh.CanTouch = false
		end
	end

	itemDef = ItemDefinitions[PreviewManager.currentPreview.Name]
	spawnedPreviewOnMobile = false
	HideDeletePointer()
end

local function HidePreview()
	for _, mesh in PreviewManager.currentPreview:GetChildren() do
		mesh.Transparency = 1.0
	end
end

PreviewManager.currentPreview.Parent = workspace
for _, mesh in PreviewManager.currentPreview:GetChildren() do
	if mesh:IsA("MeshPart") then
		mesh.Transparency = 1.0
		mesh.Anchored = true
		mesh.CanCollide = false
		mesh.CanQuery = false
		mesh.CanTouch = false
	end
end

function PreviewManager.AlignItemPreview(hit)
	local floorPart = Placement3D.getFloorPart(hit.Instance)
	if floorPart then
		placementData.hitObject = floorPart
		clientPlacementData.hitObject = floorPart
	else
		placementData.hitObject = hit.Instance:FindFirstAncestorWhichIsA("Model")
		clientPlacementData.hitObject = hit.Instance:FindFirstAncestorWhichIsA("Model")
	end
	local surfaceNormal = hit.Normal
	local hitPos = hit.Position
	if hitPos then
		if deleteMode then
			deletePointer.CFrame = CFrame.new(hit.Position)

			local hitModel = placementData.hitObject

			if hitModel and hitModel ~= PreviewManager.currentPreview and hitModel ~= workspace then
				currentHighlight = Instance.new("Highlight")
				currentHighlight.Adornee = hitModel
				currentHighlight.FillColor = Color3.fromRGB(0, 170, 255)
				currentHighlight.FillTransparency = 0.3
				currentHighlight.OutlineTransparency = 1
				currentHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
				currentHighlight.Parent = hitModel
			end

			return
		end
		placementData.normal = surfaceNormal
		clientPlacementData.normal = surfaceNormal

		local snapped =
			Placement3D.trySnapToNearby(PreviewManager.currentPreview, itemDef, hitPos, surfaceNormal, rotationAngle)
		if snapped.finalCFrame then
			placementData.snapped = true
			placementData.wallsToIgnore = snapped.wallsToIgnoreForCollisions
			if snapped.surfaceNormal then
				placementData.normal = snapped.surfaceNormal
				clientPlacementData.normal = snapped.surfaceNormal
			end
		else
			placementData.snapped = false
			placementData.wallsToIgnore = {}
			Placement3D.alignToSurface(PreviewManager.currentPreview, hitPos, surfaceNormal, rotationAngle, itemBase)
		end

		local ValidityData = PlacementValidator.CheckIfValidPlacement(
			PreviewManager.currentPreview,
			itemDef,
			currentHighlight,
			currentPreviewColor,
			clientPlacementData,
			snapped,
			cachedBoundsVariables
		)
		canPlaceClientCheck = ValidityData.canPlaceClientCheck
		currentPreviewColor = ValidityData.currentPreviewColor
		currentHighlight = ValidityData.currentHighlight
		occupiedCellsToCheck = ValidityData.occupiedCellsToCheck
	end
end

function PreviewManager.UpdateItem()
	if PreviewManager.showingItemPreview then
		PreviewManager.currentPreview:Destroy()
		currentPreviewIndex = (currentPreviewIndex % #previewInventory) + 1
		PreviewManager.currentPreview = previewInventory[currentPreviewIndex]:Clone()

		ShowPreview()
	end
end

function PreviewManager.SelectItem()
	if not PreviewManager.showingItemPreview then
		ShowPreview()
		deleteMode = false
		placementData.deleteMode = false
		PreviewManager.showingItemPreview = true
	end
end

function PreviewManager.SelectBlock()
	HidePreview()
	PreviewManager.showingItemPreview = false
	itemDef = false
	deleteMode = false
end

function PreviewManager.DeleteMode()
	if PreviewManager.showingItemPreview then
		HidePreview()
		PreviewManager.showingItemPreview = false
		itemDef = nil
	end
	ShowDeletePointer()
	deleteMode = true
	placementData.deleteMode = true
end

function PreviewManager.RotatePreview()
	rotationAngle = (rotationAngle + rotationStep) % 360
	if isMobile and not PreviewManager.ISMOBILE_LOOK_PLACEMENT_MODE then
		PreviewManager.AlignItemPreview(PreviewManager.lastHitMobile)
	end
end

function PreviewManager.TryToPlaceOrDeleteItem()
	if not PreviewManager.showingItemPreview and not deleteMode then
		return
	end

	if deleteMode then
		placementData.deleteMode = true
		remotePlaceItem:FireServer(placementData)
		return
	end

	if canPlaceClientCheck then
		local cachedPreviewCFrame = PreviewManager.currentPreview:GetPrimaryPartCFrame()
		placementData.occupiedCellsToCheck = occupiedCellsToCheck
		placementData.currentPreview = PreviewManager.currentPreview.Name
		placementData.itemDef = itemDef
		placementData.cachedPreviewCFrame = cachedPreviewCFrame
		remotePlaceItem:FireServer(placementData)
	else
		occupiedCellsToCheck = {}
	end
end

remotePlaceItem.OnClientEvent:Connect(function(finalPlacementData)
	if finalPlacementData.deletedCoords then
		local deletionitemDef = finalPlacementData.deletionItemDef
		for _, voxelCoord in finalPlacementData.deletedCoords do
			for _, itemDefinition in clientPlacementData.voxelPlacementData[voxelCoord].itemDefs do
				if itemDefinition == deletionitemDef then
					table.remove(itemDefinition)
				end
			end
			if #clientPlacementData.voxelPlacementData[voxelCoord] == 0 then
				clientPlacementData.voxelPlacementData[voxelCoord].Occupied = false
			end
		end
		return
	end
	if finalPlacementData.placementSuccess then
		for _, coord in finalPlacementData.occupiedCellsToCheck do
			if clientPlacementData.voxelPlacementData[`{coord.X},{coord.Y},{coord.Z}`] == nil then
				clientPlacementData.voxelPlacementData[`{coord.X},{coord.Y},{coord.Z}`] =
					{ Occupied = false, itemDefs = {} }
			end
			clientPlacementData.voxelPlacementData[`{coord.X},{coord.Y},{coord.Z}`].Occupied = true
			table.insert(
				clientPlacementData.voxelPlacementData[`{coord.X},{coord.Y},{coord.Z}`].itemDefs,
				finalPlacementData.itemDef
			)
		end
		if isMobile and not PreviewManager.ISMOBILE_LOOK_PLACEMENT_MODE then
			PreviewManager.AlignItemPreview(PreviewManager.lastHitMobile)
		end
	end
	occupiedCellsToCheck = {}
end)

function PreviewManager.UpdatePreview()
	if not PreviewManager.showingItemPreview and not deleteMode then
		return
	end

	if spawnedPreviewOnMobile and not deleteMode then
		return
	end

	local characters = {}
	for _, player in Players:GetPlayers() do
		if player.Character ~= nil then
			table.insert(characters, player.Character)
		end
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = characters
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	local finalPosition = nil
	if isMobile then
		finalPosition =
			Vector2.new(Workspace.CurrentCamera.ViewportSize.X / 2, Workspace.CurrentCamera.ViewportSize.Y / 2)
	else
		finalPosition = UserInputService:GetMouseLocation()
	end

	local ray = Workspace.CurrentCamera:ViewportPointToRay(finalPosition.X, finalPosition.Y)
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, raycastParams)

	if not deleteMode then
		cachedBoundsVariables.cframe, cachedBoundsVariables.size = PreviewManager.currentPreview:GetBoundingBox()

		cachedBoundsVariables.min = cachedBoundsVariables.cframe.Position - cachedBoundsVariables.size / 2
		cachedBoundsVariables.max = cachedBoundsVariables.cframe.Position + cachedBoundsVariables.size / 2

		local center = cachedBoundsVariables.cframe.Position
		local halfSize = cachedBoundsVariables.size / 2

		local minOffset = Vector3.new(-halfSize.X, 0, -halfSize.Z)
		local maxOffset = Vector3.new(halfSize.X, 0, halfSize.Z)

		local rotationOnly = cachedBoundsVariables.cframe - center

		local rotatedMin = center + rotationOnly:VectorToWorldSpace(minOffset)
		local rotatedMax = center + rotationOnly:VectorToWorldSpace(maxOffset)

		local baseY = center.Y - halfSize.Y

		cachedBoundsVariables.minFloor =
			Vector3.new(math.min(rotatedMin.X, rotatedMax.X), baseY, math.min(rotatedMin.Z, rotatedMax.Z))

		cachedBoundsVariables.maxFloor =
			Vector3.new(math.max(rotatedMin.X, rotatedMax.X), baseY, math.max(rotatedMin.Z, rotatedMax.Z))

		cachedBoundsVariables.MinimumVoxelcoord = grid.positionToCoord(cachedBoundsVariables.minFloor)
		cachedBoundsVariables.MaximumVoxelcoord = grid.positionToCoord(cachedBoundsVariables.maxFloor)

		itemBase = cachedBoundsVariables.size.Y / 2
		if itemDef then
			if itemDef.Origin == "Top" then
				itemBase = cachedBoundsVariables.size.Y
			elseif itemDef.Origin == "Bottom" then
				itemBase = 0
			end
		end
	end

	if currentHighlight and deleteMode then
		currentHighlight:Destroy()
		currentHighlight = nil
	end

	if hit then
		if isMobile and not PreviewManager.ISMOBILE_LOOK_PLACEMENT_MODE then
			spawnedPreviewOnMobile = true
		end

		PreviewManager.AlignItemPreview(hit)
	end
end

return PreviewManager
