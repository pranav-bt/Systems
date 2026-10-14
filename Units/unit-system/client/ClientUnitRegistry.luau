--!strict
-- Singleton. The client's single source of "who is in the game" (real players + bots)
-- and the resolver from a wire unit id to a uniform ClientUnit view. It is also the
-- client's unified UNIT/CHARACTER EVENT SOURCE: controllers subscribe to its
-- UnitAdded / UnitRemoving / CharacterAdded signals instead of touching
-- `Players.PlayerAdded` / `player.CharacterAdded` directly, so their per-unit and
-- respawn logic fires for bots exactly as it does for players.
--
-- Real players: the registry wires Players.PlayerAdded/PlayerRemoving and each
-- player's CharacterAdded and re-emits them through its signals. Roblox already tracks
-- players + their characters, so no player data is cached here; Resolve reads live
-- from the Players service.
--
-- Bots: the host game's remote layer feeds bot lifecycle in by calling
-- OnBotRegistered / OnBotCharacterAdded / OnBotRemoved (see "Transport seam" below),
-- which drive the SAME signals from a small replicated cache. A bot id is negative
-- (see UnitId); a real id is a Roblox UserId.
--
-- ORDERING: a state event (healthChanged, etc.) may reference an id whose registration
-- hasn't arrived yet -- different reliable remotes have no cross-order guarantee.
-- Resolve returns nil for an unknown id and callers SKIP (state events are idempotent;
-- the next one after registration renders correctly). A resolved unit's `.character`
-- can also be nil briefly (id known, rig not streamed in yet), so visual attachment
-- should key off the CharacterAdded SIGNAL, not off polling `.character`.
--
-- TypedSubject is a tiny host-provided dependency (a typed facade over any
-- subject/signal library); see the README. Swap the require for your own if you
-- already have one -- the registry only needs new/subscribe/notify.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TypedSubject = require(ReplicatedStorage.Shared.TypedSubject)
local UnitId = require(ReplicatedStorage.Shared.UnitId)
local UnitTypes = require(ReplicatedStorage.Shared.UnitTypes)

type Subject<T...> = TypedSubject.Subject<T...>

local ClientUnitRegistry = {
	-- A unit (player or bot) entered the game.
	UnitAdded = TypedSubject.new() :: Subject<number>,
	-- A unit left / a bot despawned.
	UnitRemoving = TypedSubject.new() :: Subject<number>,
	-- A unit's character rig (re)spawned. The unified form of Player.CharacterAdded;
	-- fires for players (from the engine event) and bots (from OnBotCharacterAdded).
	CharacterAdded = TypedSubject.new() :: Subject<number, Model>,
}

-- Replicated bot metadata, keyed by the bot's (negative) id. Empty until bots exist.
type BotEntry = { name: string, character: Model? }
local BotsById: { [number]: BotEntry } = {}

-- ── Resolution ───────────────────────────────────────────────────────────────

-- Resolves a wire unit id to a uniform view, or nil if the id is unknown (not yet
-- registered / already gone). Callers treat nil as "skip".
function ClientUnitRegistry.Resolve(id: number): UnitTypes.ClientUnit?
	if UnitId.IsBot(id) then
		local entry = BotsById[id]
		if not entry then
			return nil
		end
		return { id = id, name = entry.name, character = entry.character, isBot = true }
	end

	local player = Players:GetPlayerByUserId(id)
	if not player then
		return nil
	end
	return { id = id, name = player.Name, character = player.Character, isBot = false }
end

-- Resolves a character Model to its unit id (player or bot), or nil if the Model isn't
-- a known unit's character. The client mirror of UnitService.GetUnitFromCharacter --
-- used by e.g. melee hit detection, which finds character parts in a box and needs the
-- id (not the Player, which a bot rig doesn't have) to report.
function ClientUnitRegistry.GetIdFromCharacter(character: Model): number?
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		return player.UserId
	end
	for id, entry in BotsById do
		if entry.character == character then
			return id
		end
	end
	return nil
end

-- Every known unit id (players + bots). The replacement for `Players:GetPlayers()`
-- wherever a controller enumerates units to attach visuals to.
function ClientUnitRegistry.GetAll(): { number }
	local ids: { number } = {}
	for _, player in Players:GetPlayers() do
		table.insert(ids, player.UserId)
	end
	for id in BotsById do
		table.insert(ids, id)
	end
	return ids
end

-- ── Transport seam (host game's remote layer drives these) ─────────────────────
-- A bot has no client, so the server replicates its lifecycle over the wire. Decode
-- those messages in your remote layer and forward them here. Keep the ordering the
-- server sends: an id must be registered before any event references it, and the
-- character is a separate message from registration.

-- A bot's identity arrived: id is resolvable from now on. Drives UnitAdded.
function ClientUnitRegistry.OnBotRegistered(id: number, name: string)
	BotsById[id] = { name = name, character = nil }
	ClientUnitRegistry.UnitAdded:notify(id)
end

-- A bot's rig (re)spawned. Drives CharacterAdded (the respawn-visual seam).
function ClientUnitRegistry.OnBotCharacterAdded(id: number, character: Model)
	local entry = BotsById[id]
	if entry then
		entry.character = character
	end
	ClientUnitRegistry.CharacterAdded:notify(id, character)
end

-- A bot despawned. Drives UnitRemoving.
function ClientUnitRegistry.OnBotRemoved(id: number)
	BotsById[id] = nil
	ClientUnitRegistry.UnitRemoving:notify(id)
end

-- ── Player wiring (re-emit engine events through the unified signals) ──────────

local function TrackPlayer(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		ClientUnitRegistry.CharacterAdded:notify(player.UserId, character)
	end)
	-- Character may already exist when we start tracking (player was here first).
	if player.Character then
		ClientUnitRegistry.CharacterAdded:notify(player.UserId, player.Character)
	end
end

function ClientUnitRegistry.Start()
	Players.PlayerAdded:Connect(function(player: Player)
		ClientUnitRegistry.UnitAdded:notify(player.UserId)
		TrackPlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		ClientUnitRegistry.UnitRemoving:notify(player.UserId)
	end)

	-- Players already present when this controller starts.
	for _, player in Players:GetPlayers() do
		ClientUnitRegistry.UnitAdded:notify(player.UserId)
		TrackPlayer(player)
	end
end

return ClientUnitRegistry
