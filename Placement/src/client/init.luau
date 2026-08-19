-- Client entry point for the Placement library.
--
-- Call `ClientPlacement.init(config)` once from a LocalScript. `config` fields:
--   modelsSource : Folder      -- Folder of placeable Model instances (required)
--   grid         : Grid?       -- { positionToCoord(pos)->Vector3, voxelSize }
--                                 defaults to a uniform grid (see DefaultGrid)
--   gridConfig   : table?      -- passed to DefaultGrid.new when grid omitted
--   scheduler    : Scheduler?  -- { schedule(phase, name, cb)->disconnect }
--                                 defaults to self-contained RunService loops
--   createMobileUI : boolean?  -- build the on-screen touch buttons (default true)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Context = require(script.Context)
local DefaultGrid = require(script.DefaultGrid)
local DefaultScheduler = require(script.DefaultScheduler)

local ClientPlacement = {}

function ClientPlacement.init(config)
	config = config or {}

	Context.grid = config.grid or DefaultGrid.new(config.gridConfig)
	Context.modelsSource = config.modelsSource or ReplicatedStorage:FindFirstChild("ItemDefinitions")
	Context.scheduler = config.scheduler or DefaultScheduler

	-- Required AFTER Context is populated: these modules read grid / modelsSource
	-- / scheduler at require-time.
	local Input = require(script.PlacementInput)
	local PreviewManager = require(script.PreviewManager)

	Input.actions:justPressedSignal("UpdateItem"):connect(function()
		PreviewManager.UpdateItem()
	end)

	Input.actions:justPressedSignal("SelectItem"):connect(function()
		PreviewManager.SelectItem()
	end)

	Input.actions:justPressedSignal("SelectBlock"):connect(function()
		PreviewManager.SelectBlock()
	end)

	Input.actions:justPressedSignal("DeleteItem"):connect(function()
		PreviewManager.DeleteMode()
	end)

	Input.actions:justPressedSignal("PlaceBlock"):connect(function()
		PreviewManager.TryToPlaceOrDeleteItem()
	end)

	Input.actions:justPressedSignal("RotateItem"):connect(function()
		PreviewManager.RotatePreview()
	end)

	Context.scheduler.schedule("PostSimulation", "Placement UpdatePreview", function()
		PreviewManager.UpdatePreview()
	end)

	local function createMobilePlacementUI()
		local player = Players.LocalPlayer
		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "PlacementMobileUI"
		screenGui.IgnoreGuiInset = true
		screenGui.ResetOnSpawn = false
		screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		screenGui.Parent = player:WaitForChild("PlayerGui")

		local function createButton(name, position, anchorPoint, callback)
			local btn = Instance.new("TextButton")
			btn.Name = name
			btn.Size = UDim2.new(0, 100, 0, 50)
			btn.Position = position
			btn.AnchorPoint = anchorPoint
			btn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
			btn.TextColor3 = Color3.new(1, 1, 1)
			btn.TextScaled = true
			btn.Font = Enum.Font.GothamBold
			btn.Text = name
			btn.Parent = screenGui

			btn.Activated:Connect(callback)
		end

		createButton("Place/Delete", UDim2.new(1, -20, 1, -20), Vector2.new(1, 1), function()
			Input.actions:press("PlaceBlock")
		end)

		createButton("RotateItem", UDim2.new(1, -130, 1, -20), Vector2.new(1, 1), function()
			Input.actions:press("RotateItem")
		end)

		createButton("NextItem", UDim2.new(1, -240, 1, -20), Vector2.new(1, 1), function()
			Input.actions:press("UpdateItem")
		end)

		createButton("DeleteMode", UDim2.new(1, -20, 0, 20), Vector2.new(1, 0), function()
			Input.actions:press("DeleteItem")
		end)

		createButton("PlaceMode", UDim2.new(1, -130, 0, 20), Vector2.new(1, 0), function()
			Input.actions:press("SelectItem")
		end)
	end

	Input.actions:press("SelectItem")

	if config.createMobileUI ~= false then
		createMobilePlacementUI()
	end

	return ClientPlacement
end

return ClientPlacement
