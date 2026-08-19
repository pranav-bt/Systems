local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RaycastUtils = {}

function RaycastUtils.getTouchRay(inputPosition: Vector2)
	return Workspace.CurrentCamera:ScreenPointToRay(inputPosition.X, inputPosition.Y)
end

function RaycastUtils.getRaycastResult(currentPreview, ray, start: boolean?)
	local params = RaycastParams.new()
	if not start then
		local characters = {}
		for _, player in Players:GetPlayers() do
			if player.Character then
				table.insert(characters, player.Character)
			end
		end

		table.insert(characters, currentPreview)

		params.FilterDescendantsInstances = characters
		params.FilterType = Enum.RaycastFilterType.Exclude
	else
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { currentPreview }
	end

	return Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
end

return RaycastUtils
