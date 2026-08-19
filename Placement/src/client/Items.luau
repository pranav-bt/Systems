-- Runtime placeable-model catalog for the client preview.
--
-- Derived from the injected `Context.modelsSource` folder rather than a
-- hardcoded `ReplicatedStorage.ItemDefinitions`. Every Model directly under the
-- source folder becomes a placeable item keyed by its name; each should have a
-- matching entry in the shared ItemDefinitions data table.

local Context = require(script.Parent.Context)

local Items: { [string]: Model } = {}

local source = Context.modelsSource
if source then
	for _, model in source:GetChildren() do
		if model:IsA("Model") then
			Items[model.Name] = model
		end
	end
else
	warn("[Placement] Items: no modelsSource injected; preview catalog is empty")
end

return Items
