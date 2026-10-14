--!strict
-- Singleton. The single source of "who is in the game" (real players + live bots)
-- and the server-side id<->unit<->character resolver. Replaces scattered
-- `Players:GetPlayers()` loops over gameplay units, so bot-aware code iterates one
-- roster.
--
-- Identity: a unit's id is `unit.UserId` for both kinds -- a Roblox UserId for a real
-- player, a synthetic negative id for a bot (see UnitId). Bots register here via
-- Register/Unregister (called by the bot driver); real players are read live from the
-- Players service (Roblox already tracks them), so no per-player bookkeeping is
-- duplicated here.
--
-- WIRING: update the three `require` paths below to wherever you place the Unit
-- modules. As shipped they assume:
--   * UnitId     under ReplicatedStorage.Shared
--   * BotPlayer  as a sibling server module
--   * UnitTypes  under ReplicatedStorage.Shared

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BotPlayer = require(script.Parent.BotPlayer)
local UnitId = require(ReplicatedStorage.Shared.UnitId)
local UnitTypes = require(ReplicatedStorage.Shared.UnitTypes)

local UnitService = {}

-- Live bots keyed by their synthetic id. Real players are not stored here -- they are
-- read from the Players service on demand.
local BotsById: { [number]: BotPlayer.BotPlayer } = {}

function UnitService.Start() end

-- Registers a bot so it appears in the roster and resolves by id/character. Called by
-- the bot driver's Spawn.
function UnitService.Register(bot: BotPlayer.BotPlayer)
	BotsById[bot.UserId] = bot
end

-- Removes a bot from the roster. Called by the bot driver's Despawn (after the shared
-- PlayerRemoving teardown has run for it).
function UnitService.Unregister(bot: BotPlayer.BotPlayer)
	BotsById[bot.UserId] = nil
end

-- Every gameplay unit: real players plus live bots. The replacement for
-- `Players:GetPlayers()` wherever the loop is over game units (not network sockets).
function UnitService.GetAll(): { UnitTypes.Unit }
	local units: { UnitTypes.Unit } = {}
	for _, player in Players:GetPlayers() do
		table.insert(units, player)
	end
	for _, bot in BotsById do
		table.insert(units, bot)
	end
	return units
end

-- Resolves a wire id to its unit: a bot from the registry, else the real player with
-- that UserId. Returns nil if unknown (e.g. the unit left).
function UnitService.GetUnit(id: number): UnitTypes.Unit?
	if UnitId.IsBot(id) then
		return BotsById[id]
	end
	return Players:GetPlayerByUserId(id)
end

-- Resolves a character Model to its unit: a registered bot first, else the real player
-- that owns the character.
function UnitService.GetUnitFromCharacter(character: Model): UnitTypes.Unit?
	for _, bot in BotsById do
		if bot.Character == character then
			return bot
		end
	end
	return Players:GetPlayerFromCharacter(character)
end

-- The wire/identity id for a unit. Unified for both kinds: `unit.UserId`.
function UnitService.GetId(unit: UnitTypes.Unit): number
	return unit.UserId
end

-- The real `Player` a unit is, or nil if it is a bot. For the (few) Roblox APIs that
-- genuinely require a Player -- per-client targeting (`fireExcept`, `FireClient`) and
-- network ownership (`SetNetworkOwner`) -- a bot legitimately maps to nil: it has no
-- client socket and its rig is server-owned. Call sites decide what nil means (exclude
-- nobody / send to nobody / leave server-owned). This is NOT used for wire unit
-- identity -- that is always `GetId` (a number).
function UnitService.ToRealPlayer(unit: UnitTypes.Unit): Player?
	if UnitId.IsBot(unit.UserId) then
		return nil
	end
	return unit :: any
end

return UnitService
