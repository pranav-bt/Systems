local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Context = require(script.Parent.Context)
local Spark = require(ReplicatedStorage.Packages.Spark)

type Action = "SelectItem" | "SelectBlock" | "UpdateItem" | "RotateItem" | "DeleteItem" | "PlaceBlock"

local actions = (
	Spark.Actions.new({
		"SelectItem",
		"SelectBlock",
		"UpdateItem",
		"RotateItem",
		"DeleteItem",
		"PlaceBlock",
	}) :: any
) :: Spark.Actions<Action>

actions:setRebuildBindings(function(bindings)
	bindings:bind("SelectItem", Enum.KeyCode.Q)
	bindings:bind("SelectBlock", Enum.KeyCode.E)
	bindings:bind("UpdateItem", Enum.KeyCode.Z)
	bindings:bind("RotateItem", Enum.KeyCode.R)
	bindings:bind("DeleteItem", Enum.KeyCode.F)
	bindings:bind("PlaceBlock", Enum.UserInputType.MouseButton1)
end)

local inputState = Spark.InputState.new()

Context.scheduler.schedule("Input", "Placement Input", function()
	actions:update(inputState)
	inputState:clear()
end)

return {
	actions = actions,
}
