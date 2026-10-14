--!strict
-- A server-only stand-in for a Roblox `Player`, used for bots. It implements exactly
-- the subset of the `Player` API the server's gameplay systems read (see
-- UnitTypes.Unit): `.Name`, `.UserId`, `.Character`, `.CharacterAdded`, and a
-- `tostring` that yields the name (so `{unit}` log interpolation matches a real
-- Player). It is NOT a general Player polyfill.
--
-- A BotPlayer is created by the bot driver with a synthetic negative UserId (see
-- UnitId), which is also its identity on the wire. The Character is assigned by the
-- bot driver on each rig (re)spawn, at which point it fires CharacterAdded -- the
-- server-side equivalent of the engine's per-Player CharacterAdded, so respawn-driven
-- setup runs for bots exactly as it does for players.

local BotPlayer = {}
BotPlayer.__index = BotPlayer

export type BotPlayer = typeof(setmetatable(
	{} :: {
		Name: string,
		UserId: number,
		Character: Model?,
		-- The .Event of an internal BindableEvent, so it is a genuine RBXScriptSignal
		-- (matching Player.CharacterAdded's type). Fired via _characterAddedBindable.
		CharacterAdded: RBXScriptSignal,
		_characterAddedBindable: BindableEvent,
	},
	BotPlayer
))

function BotPlayer.new(userId: number, name: string): BotPlayer
	local characterAddedBindable = Instance.new("BindableEvent")
	return setmetatable({
		Name = name,
		UserId = userId,
		Character = nil,
		CharacterAdded = characterAddedBindable.Event,
		_characterAddedBindable = characterAddedBindable,
	}, BotPlayer)
end

-- Assigns the bot's current character rig and fires CharacterAdded (mirroring the
-- engine's per-Player signal). Called by the bot driver on spawn and on each respawn.
function BotPlayer.SetCharacter(self: BotPlayer, character: Model)
	self.Character = character
	self._characterAddedBindable:Fire(character)
end

function BotPlayer.Destroy(self: BotPlayer)
	self.Character = nil
	self._characterAddedBindable:Destroy()
end

-- So `tostring(bot)` / `{bot}` log interpolation reads as the name, like a Player.
function BotPlayer.__tostring(self: BotPlayer): string
	return self.Name
end

return BotPlayer
