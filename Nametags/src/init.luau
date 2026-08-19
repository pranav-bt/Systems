--!strict

-- Overhead nametags coloured by team, so you can tell friend from foe at a glance.
-- Replaces the default username label (kept the health bar). The owner doesn't see
-- their own (PlayerToHideFrom). Colour comes from an optional resolver, otherwise
-- the player's Roblox Team, otherwise a neutral fallback.

local Players = game:GetService("Players")

export type Config = {
	-- Label font (default Enum.Font.GothamBold).
	Font: Enum.Font?,
	-- BillboardGui size in offset pixels; drives the scaled text size (default 200x40).
	Size: UDim2?,
	-- Vertical/positional offset above the head (default Vector3.new(0, 2.8, 0)).
	StudsOffset: Vector3?,
	-- BillboardGui MaxDistance (default 150).
	MaxDistance: number?,
	-- Colour used when a player has no Team and no resolver colour (default RGB 220,220,220).
	NeutralColor: Color3?,
	-- Optional colour override for games without Roblox Teams. Returning nil falls
	-- back to the Team-based path (and then NeutralColor).
	ColorResolver: ((player: Player) -> Color3?)?,
}

local DEFAULT_FONT = Enum.Font.GothamBold
local DEFAULT_SIZE = UDim2.fromOffset(200, 40)
local DEFAULT_STUDS_OFFSET = Vector3.new(0, 2.8, 0)
local DEFAULT_MAX_DISTANCE = 150
local DEFAULT_NEUTRAL_COLOR = Color3.fromRGB(220, 220, 220)

local font: Enum.Font = DEFAULT_FONT
local size: UDim2 = DEFAULT_SIZE
local studsOffset: Vector3 = DEFAULT_STUDS_OFFSET
local maxDistance: number = DEFAULT_MAX_DISTANCE
local neutralColor: Color3 = DEFAULT_NEUTRAL_COLOR
local colorResolver: ((player: Player) -> Color3?)? = nil

local Nametags = {}

local function teamColor(player: Player): Color3
	if colorResolver then
		local resolved = colorResolver(player)
		if resolved then
			return resolved
		end
	end
	if player.Team then
		return player.Team.TeamColor.Color
	end
	return neutralColor
end

local function getLabel(player: Player): TextLabel?
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local gui = head and head:FindFirstChild("Nametag")
	local label = gui and gui:FindFirstChildOfClass("TextLabel")
	return label
end

local function refreshColor(player: Player)
	local label = getLabel(player)
	if label then
		label.TextColor3 = teamColor(player)
	end
end

local function setupNametag(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid")
	local head = character:FindFirstChild("Head") or character:WaitForChild("Head")
	if not humanoid:IsA("Humanoid") or not head:IsA("BasePart") then
		return
	end

	-- Hide the default overhead username (keep the health bar).
	humanoid.NameDisplayDistance = 0

	local existing = head:FindFirstChild("Nametag")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "Nametag"
	gui.Size = size
	gui.StudsOffset = studsOffset
	gui.MaxDistance = maxDistance
	gui.PlayerToHideFrom = player -- you don't need to see your own
	gui.Adornee = head
	gui.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = font
	label.TextScaled = true
	label.TextStrokeTransparency = 0.4
	label.Text = player.DisplayName
	label.TextColor3 = teamColor(player)
	label.Parent = gui
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		setupNametag(player, character)
	end)
	player:GetPropertyChangedSignal("Team"):Connect(function()
		refreshColor(player)
	end)
	if player.Character then
		task.spawn(setupNametag, player, player.Character)
	end
end

function Nametags.start(config: Config?)
	if config then
		font = config.Font or font
		size = config.Size or size
		studsOffset = config.StudsOffset or studsOffset
		maxDistance = config.MaxDistance or maxDistance
		neutralColor = config.NeutralColor or neutralColor
		colorResolver = config.ColorResolver
	end

	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
end

return Nametags
