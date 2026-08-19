--!native
--!optimize 2

-- Server entry point for the Placement library.
--
-- Call `Placement.init(config)` once from a Script. `config` fields:
--   modelsSource : Folder  -- Folder of placeable Model instances (required;
--                             must contain the same models the client places).
--
-- Self-provisions its own `PlaceItem` RemoteEvent under ReplicatedStorage and
-- registers the "Preview"/"Players" collision groups, so the host needs no
-- central remotes folder. Call init exactly once.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local PlacementData = require(script.PlacementData)
local ItemDefinitions = require(script.Parent.shared.ItemDefinitions)

local Placement = {}

function Placement.init(config)
	config = config or {}
	local modelsSource = config.modelsSource or ReplicatedStorage:FindFirstChild("ItemDefinitions")
	assert(modelsSource, "[Placement] server init: config.modelsSource (Folder of Models) is required")

	local remotePlaceItem = Instance.new("RemoteEvent")
	remotePlaceItem.Name = "PlaceItem"
	remotePlaceItem.Parent = ReplicatedStorage

	local function getFloorPart(instance: Instance): Instance?
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

	PhysicsService:RegisterCollisionGroup("Preview")
	PhysicsService:RegisterCollisionGroup("Players")
	PhysicsService:CollisionGroupSetCollidable("Preview", "Players", false)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			for _, part in character:GetDescendants() do
				if part:IsA("BasePart") then
					PhysicsService:SetPartCollisionGroup(part, "Players")
				end
			end
		end)
	end)

	local function PlaceItem(currentPreview, cachedPreviewCFrame)
		local PlacedItem = modelsSource:FindFirstChild(currentPreview):Clone()
		PlacedItem.Parent = workspace
		PlacedItem:SetPrimaryPartCFrame(cachedPreviewCFrame)
		for _, mesh in PlacedItem:GetChildren() do
			if mesh:IsA("MeshPart") or mesh:IsA("BasePart") then
				if mesh.Name ~= "CustomCollider" then
					mesh.CanCollide = true
					mesh.Transparency = 0
				end
				mesh.Anchored = true
				mesh.CanQuery = false
				mesh.CanTouch = false
			end
		end
		return PlacedItem
	end

	local function CollisionCheckForOverlaps(data): boolean
		local model = modelsSource:FindFirstChild(data.currentPreview):Clone()
		model.Parent = workspace
		model:SetPrimaryPartCFrame(data.cachedPreviewCFrame)
		for _, mesh in model:GetChildren() do
			if mesh:IsA("MeshPart") then
				mesh.Transparency = 1
				mesh.Anchored = true
				mesh.CanCollide = false
				mesh.CanQuery = false
				mesh.CanTouch = false
			end
		end

		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = true
				PhysicsService:SetPartCollisionGroup(part, "Preview")
			end
		end

		local function IsCompatibleTouchCollision(hit)
			local parentObject = hit:FindFirstAncestorOfClass("Model")
			local itemDef = data.itemDef
			if itemDef.TouchAllowedObjects then
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
				for _, wall in data.wallsToIgnore do
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
						getFloorPart(hit) == nil
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

		model:Destroy()
		return touching
	end

	local function CanOverlap(voxelCoord, data)
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
		if CollisionCheckForOverlaps(data) then
			return false
		end

		return true
	end

	local function CanPlaceItem(voxelCoord, data)
		if
			data.itemDef.PlacementSurface == "Floor"
			and data.hitObject
			and (
				(ItemDefinitions[data.hitObject.Name] and ItemDefinitions[data.hitObject.Name].Category ~= "Floor")
				or not ItemDefinitions[data.hitObject.Name]
			)
		then
			return false
		elseif
			((data.snapped and not data.itemDef.IgnorePointerOnSnap) or not data.snapped)
			and (
				(data.itemDef.PlacementSurface ~= "Floor" and (not data.hitObject or data.hitObject == workspace))
				or (
					(data.itemDef.PlacementSurface ~= "Floor")
					and data.hitObject
					and ItemDefinitions[data.hitObject.Name]
					and ItemDefinitions[data.hitObject.Name].Type ~= data.itemDef.PlacementSurface
				)
			)
		then
			return false
		elseif data.itemDef.PlacementType and data.itemDef.PlacementType == "HorizontalSurface" and data.normal.Y < 0.9 then
			return false
		elseif
			PlacementData.voxelPlacementData[`{voxelCoord.X},{voxelCoord.Y},{voxelCoord.Z}`].Occupied
			and not CanOverlap(voxelCoord, data)
		then
			return false
		else
			return true
		end
	end

	local function DeleteItem(data)
		local deletionItemDef = nil
		local coordsForClientCopy = {}
		if PlacementData.itemToVoxelData[data.hitObject] then
			local deletionitemDef = ItemDefinitions[data.hitObject.Name]
			deletionItemDef = deletionitemDef
			for _, voxelCoord in PlacementData.itemToVoxelData[data.hitObject] do
				for _, itemDef in PlacementData.voxelPlacementData[voxelCoord].itemDefs do
					if itemDef.Type == deletionitemDef.Type then
						table.insert(coordsForClientCopy, voxelCoord)
						table.remove(itemDef)
						continue
					end
				end
				if #PlacementData.voxelPlacementData[voxelCoord] == 0 then
					PlacementData.voxelPlacementData[voxelCoord].Occupied = false
				end
			end
			PlacementData.itemToVoxelData[data.hitObject] = nil
			data.hitObject:Destroy()
		end
		return coordsForClientCopy, deletionItemDef
	end

	remotePlaceItem.OnServerEvent:Connect(function(_, data)
		if data.deleteMode and data.hitObject then
			remotePlaceItem:FireAllClients(data)
			local deletedCoords, deletionItemDef = DeleteItem(data)
			if deletedCoords ~= nil then
				data.deletedCoords = deletedCoords
				data.deletionItemDef = deletionItemDef
				remotePlaceItem:FireAllClients(data)
			end
			return
		end
		for _, voxelCoord in data.occupiedCellsToCheck do
			if PlacementData.voxelPlacementData[`{voxelCoord.X},{voxelCoord.Y},{voxelCoord.Z}`] == nil then
				PlacementData.voxelPlacementData[`{voxelCoord.X},{voxelCoord.Y},{voxelCoord.Z}`] =
					{ Occupied = false, itemDefs = {} }
			end
			if not CanPlaceItem(voxelCoord, data) then
				data.placementSuccess = false
				remotePlaceItem:FireAllClients(data)
				return
			end
		end

		local placedItem = PlaceItem(data.currentPreview, data.cachedPreviewCFrame)
		data.placementSuccess = true

		PlacementData.itemToVoxelData[placedItem] = {}
		for _, voxelCoord in data.occupiedCellsToCheck do
			PlacementData.voxelPlacementData[`{voxelCoord.X},{voxelCoord.Y},{voxelCoord.Z}`].Occupied = true
			table.insert(
				PlacementData.voxelPlacementData[`{voxelCoord.X},{voxelCoord.Y},{voxelCoord.Z}`].itemDefs,
				data.itemDef
			)
			table.insert(PlacementData.itemToVoxelData[placedItem], `{voxelCoord.X},{voxelCoord.Y},{voxelCoord.Z}`)
		end

		remotePlaceItem:FireAllClients(data)
	end)

	return Placement
end

return Placement
