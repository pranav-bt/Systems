--!strict

-- Carries the local character along with any "moveable" it stands on. The server
-- (Systems/Moveables) drives moveables anchored + authoritatively and tags each
-- with `MoveableRide`. Because the character stays client-owned, we translate it
-- HERE by the moveable's per-frame movement (never on the server) so it rides
-- smoothly with no rubber-banding, while the player can still walk around on it.
--
-- Carry is translation-only: the rider keeps its own facing when a platform yaws
-- (a raft that mostly travels straight), which avoids disorienting the camera.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local RIDE_TAG = "MoveableRide"
local FLOOR_PROBE = 6 -- studs below the root still counted as "standing on"

local localPlayer = Players.LocalPlayer

-- Last frame's pivot per moveable, so we carry by the delta. Weak keys drop
-- entries when a moveable is collected.
local lastPivot: { [Instance]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local MoveableRider = {}

local function localRoot(): BasePart?
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root :: BasePart else nil
end

-- The tagged moveable an instance belongs to (walk up the ancestry), or nil.
local function moveableOf(instance: Instance?): Instance?
	local current = instance
	while current and current ~= Workspace do
		if CollectionService:HasTag(current, RIDE_TAG) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function moveableUnderRoot(root: BasePart): Instance?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = localPlayer.Character
	params.FilterDescendantsInstances = if character then { character } else {}

	local result = Workspace:Raycast(root.Position, Vector3.new(0, -FLOOR_PROBE, 0), params)
	return if result then moveableOf(result.Instance) else nil
end

function MoveableRider.start()
	RunService.Heartbeat:Connect(function()
		local root = localRoot()
		local ridden = if root then moveableUnderRoot(root) else nil

		-- Refresh every moveable's pivot each frame (so stepping onto a new one has
		-- no stale delta) and carry the one we're standing on by its translation.
		for _, object in CollectionService:GetTagged(RIDE_TAG) do
			local current = (object :: any):GetPivot() :: CFrame
			local previous = lastPivot[object]
			if root and object == ridden and previous then
				root.CFrame = root.CFrame + (current.Position - previous.Position)
			end
			lastPivot[object] = current
		end
	end)
end

return MoveableRider
