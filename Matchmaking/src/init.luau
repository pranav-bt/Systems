-- Cross-server, region-sharded matchmaking for a Lobby place. No rank/ELO --
-- just pools players and gets them into an Arena server. Adapted from
-- MechBattlegrounds's Matchmaking/init.lua (MemoryStore queue + leader
-- election + MessagingService hand-off), simplified and extended with
-- backfill (supports mid-match joining).
--
-- Flow per region, each leader tick:
--   1. Backfill: any Arena server with open slots (self-registered in
--      MemoryStore.getServerRegistry) is topped up from the queue immediately
--      -- no minimum required, since joining a match in progress is fine.
--   2. New match: whatever's left after backfill only ships once at least
--      Config.MIN_PLAYERS are waiting; once that's met, wait up to
--      Config.GRACE_SECONDS for more (capped at Config.MAX_PLAYERS) before
--      reserving a new Arena server.
-- Players who queued from the same Lobby server (same game.JobId) are
-- preferred when filling a new match, so a group that queues together tends
-- to land together instead of being scattered by strict join-order FIFO.
--
-- This is a standalone, host-agnostic library. It has NO direct dependency on
-- any game's place table or remotes. The host injects those via the config
-- passed to Matchmaking.start (see the `Config` type below) and wires its own
-- remotes to the public API (joinQueue / exitQueue / getStatus + onStatus).

local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local _LocalizationService = game:GetService("LocalizationService") -- TEMP: unused while region sharding is disabled

local Promise = require(script.Parent.Promise)

local Config = require(script.Config)
local LeaderElection = require(script.LeaderElection)
local MemoryStore = require(script.MemoryStore)
local Regions = require(script.Regions)

-- Host-supplied wiring.
--  * resolveTargetPlaceId : the Arena place a formed match is teleported to
--                           (replaces Places.GetPlaceId("Arena", ...)).
--  * keyPrefix            : MemoryStore namespace (replaces
--                           Places.GetCurrentPlaceKind()); threaded into
--                           MemoryStore so environments don't share a queue.
--  * onStatus             : optional push callback the host uses to relay
--                           queue-status updates to a client (replaces the
--                           direct MatchmakingStatus_RS:FireClient).
--  * tunables             : optional per-boot overrides for any Config field.
--  * onBeforeTeleport     : optional, called with the matched group immediately
--                           before TeleportAsync -- the host's last chance to act
--                           on these players while they are still its own. The
--                           reason this exists rather than the host hooking
--                           PlayerRemoving: by then the players are already gone
--                           and nothing can distinguish "teleported into a match"
--                           from "quit", which is exactly the distinction a
--                           session-continuation handoff (telemetry) or a final
--                           save needs. Called ONCE with the whole group, since
--                           that is how a match is teleported.
--  * onMatchFormed       : optional, called with the local players a formed match
--                           has selected, immediately before dispatch. Narrower
--                           than it looks: a match forms on the leader but its
--                           players may sit on several lobby servers, so this
--                           fires wherever a selected player actually IS and only
--                           for players that server can see. The gap it exposes
--                           against onBeforeTeleport is dispatch failure -- the
--                           TeleportAsync call failing and the party being
--                           re-queued -- not "selected and never heard from
--                           again", which no per-player hook can report because
--                           there is no Player object to report it against.
export type Config = {
	resolveTargetPlaceId: () -> number,
	keyPrefix: string,
	onStatus: ((player: Player, status: { queued: boolean }) -> ())?,
	onBeforeTeleport: ((players: { Player }, accessCode: string) -> ())?,
	onMatchFormed: ((players: { Player }, accessCode: string) -> ())?,
	tunables: { [string]: number }?,
}

local Matchmaking = {}

local config: Config = nil :: any

local queueStates: { [Player]: any } = {}

-- The Lobby server has one region, resolved once from the first player whose
-- country lookup succeeds and then shared by everyone who queues from this
-- server. Keying the queue by the lobby's region (rather than each player's own
-- country) guarantees a party that queues together lands in the same region
-- shard instead of being scattered across per-country queues.
local lobbyRegionPromise: any = nil

local function placeId(): number
	return config.resolveTargetPlaceId()
end

local function fireStatus(player: Player, status: { queued: boolean })
	if config.onStatus ~= nil then
		config.onStatus(player, status)
	end
end

local function getRegion(player: Player)
	-- TEMP: single global queue. Region sharding (incl. the lobby-region logic
	-- below) is disabled while the playerbase is small, so every player enqueues
	-- into one shard and small/mixed-region pools still reach MIN_PLAYERS. The
	-- region string is only an internal partition key -- it never gates player
	-- eligibility -- so all players still match, just with possibly higher ping.
	-- Restore the lobby-region resolution below to re-enable sharding. See also
	-- the single-region loop in the leader loop.
	if lobbyRegionPromise == nil then
		lobbyRegionPromise = Promise.resolve(Regions.Regions.NorthAmerica)
	end
	return lobbyRegionPromise

	--[[ TEMP: disabled -- lobby-region resolution
	if lobbyRegionPromise ~= nil then
		return lobbyRegionPromise
	end

	lobbyRegionPromise = Promise.try(function()
		local countryCode = _LocalizationService:GetCountryRegionForPlayerAsync(player)
		local region = Regions.CountryToRegion[countryCode]

		if region == nil then
			warn(`[Matchmaking] No region mapped for country code {countryCode}; defaulting to NorthAmerica`)
			return Regions.Regions.NorthAmerica
		end

		return region
	end):catch(function(err)
		-- Don't cache a failed lookup: clear it so the next player to queue
		-- retries and can still establish the lobby's region.
		lobbyRegionPromise = nil
		return Promise.reject(err)
	end)

	return lobbyRegionPromise
	]]
end

-- Groups queue entries by originating jobId (Lobby server) and orders the
-- largest/oldest groups first, so players who queued together get pulled
-- into the same new match ahead of unrelated stragglers.
local function groupBySameLobbyPriority(entries: { { key: string, value: string, sortKey: number } })
	local groups: { [string]: { any } } = {}
	local order: { string } = {}

	for _, entry in entries do
		local jobId = entry.value
		if groups[jobId] == nil then
			groups[jobId] = {}
			table.insert(order, jobId)
		end
		table.insert(groups[jobId], entry)
	end

	table.sort(order, function(a, b)
		local groupA, groupB = groups[a], groups[b]
		if #groupA ~= #groupB then
			return #groupA > #groupB
		end
		return groupA[1].sortKey < groupB[1].sortKey
	end)

	local flattened = {}
	for _, jobId in order do
		for _, entry in groups[jobId] do
			table.insert(flattened, entry)
		end
	end
	return flattened
end

local function teleportPlayers(players: { Player }, accessCode: string, region: string)
	if #players == 0 then
		return
	end

	-- Before the Studio branch and before any dispatch can fail, so "a match was
	-- formed for these players" is recorded even when getting them into it does
	-- not work. Both entry points reach here -- the leader with its own local
	-- players, and each other lobby server on the broadcast -- so every selected
	-- player is covered exactly once, on whichever server holds them.
	if config.onMatchFormed then
		local formedOk, formedErr = pcall(config.onMatchFormed, players, accessCode)
		if not formedOk then
			warn(`[Matchmaking] onMatchFormed errored: {formedErr}`)
		end
	end

	if RunService:IsStudio() then
		for _, player in players do
			player:Kick("Matchmaking found a match. Rejoin and open the Arena place directly to test it.")
		end
		return
	end

	local teleportOptions = Instance.new("TeleportOptions")
	teleportOptions.ReservedServerAccessCode = accessCode
	teleportOptions:SetTeleportData({ matchmaking = true, accessCode = accessCode, region = region })

	-- Host hook, on the real teleport path only: the Studio branch above kicks
	-- instead, and a kick genuinely IS a leave, so a handoff there would be wrong.
	-- pcall'd because a host callback must never be able to strand a matched party
	-- in the lobby -- whatever it was doing matters less than the match happening.
	if config.onBeforeTeleport then
		local hookOk, hookErr = pcall(config.onBeforeTeleport, players, accessCode)
		if not hookOk then
			warn(`[Matchmaking] onBeforeTeleport errored: {hookErr}`)
		end
	end

	local ok = pcall(function()
		TeleportService:TeleportAsync(placeId(), players, teleportOptions)
	end)

	if not ok then
		warn(`[Matchmaking] TeleportAsync failed for {#players} player(s); re-queuing them`)
		for _, player in players do
			Matchmaking.joinQueue(player)
		end
	end
end

-- entries are MemoryStore queue rows: key=userId (string), value=jobId.
-- Players still local to this server teleport directly; everyone else is
-- reached by broadcasting to every Lobby server via MessagingService.
local function teleportEntries(
	entries: { { key: string, value: string, sortKey: number } },
	accessCode: string,
	region: string
)
	local localPlayers = {}
	local remoteUserIds = {}

	for _, entry in entries do
		local userId = tonumber(entry.key)
		local player = userId and Players:GetPlayerByUserId(userId)
		if player ~= nil then
			table.insert(localPlayers, player)
		elseif userId ~= nil then
			table.insert(remoteUserIds, userId)
		end
	end

	teleportPlayers(localPlayers, accessCode, region)

	if #remoteUserIds > 0 and game.GameId ~= 0 then
		MessagingService:PublishAsync(`{MemoryStore.PREFIX}MMTeleport`, {
			userIds = remoteUserIds,
			accessCode = accessCode,
			region = region,
		})
	end
end

function Matchmaking.isQueued(player: Player): boolean
	return queueStates[player] ~= nil
end

-- Current queue status for a player, for the host to poll/push to clients.
function Matchmaking.getStatus(player: Player): { queued: boolean }
	return { queued = queueStates[player] ~= nil }
end

function Matchmaking.joinQueue(player: Player)
	if queueStates[player] ~= nil then
		return
	end

	local joinTime = os.time()
	local queueState = { exiting = false, region = nil :: string? }
	queueStates[player] = queueState

	getRegion(player)
		:andThen(function(region)
			if queueStates[player] ~= queueState then
				return
			end

			queueState.region = region

			local function refresh()
				queueState.refreshAt = nil
				queueState.refreshPromise = MemoryStore.joinQueue(player.UserId, region, joinTime, game.JobId)
					:finally(function()
						if queueStates[player] == queueState then
							queueState.refreshAt = os.clock() + Config.QUEUE_ENTRY_TTL / 2
						end
					end)
			end

			refresh()

			queueState.connection = RunService.Heartbeat:Connect(function()
				if queueState.refreshAt ~= nil and os.clock() >= queueState.refreshAt then
					refresh()
				end
			end)

			if player.Parent ~= nil then
				fireStatus(player, { queued = true })
			end
		end)
		:catch(function()
			if queueStates[player] == queueState then
				queueStates[player] = nil
			end
		end)
end

function Matchmaking.exitQueue(player: Player)
	local queueState = queueStates[player]
	if queueState == nil or queueState.exiting then
		return
	end
	queueState.exiting = true
	queueStates[player] = nil

	if queueState.connection ~= nil then
		queueState.connection:Disconnect()
	end

	local region = queueState.region
	if region == nil then
		return
	end

	MemoryStore.exitQueue(player.UserId, region):finally(function()
		if player.Parent ~= nil then
			fireStatus(player, { queued = false })
		end
	end)
end

function Matchmaking.onPlayerRemoving(player: Player)
	Matchmaking.exitQueue(player)

	-- TEMP: lobby-region change -- the region is now a shared server-level value
	-- (lobbyRegionPromise), so there's no per-player promise to cancel here.
	-- Restore the per-player regionPromises cleanup when reverting to per-player
	-- region resolution.
end

-- The leader scan loop. Only ever invoked on the single elected leader server
-- (see LeaderElection). Returns a cancellable Promise that LeaderElection
-- cancels when this server loses the lock.
local function runLeaderLoop()
	local matchedUserIds: { [number]: number } = {}
	local formingSince: { [string]: number } = {}

	local queues: { [string]: { updateAt: number? } } = {}
	-- TEMP: single global queue -- only scan the one region getRegion assigns.
	-- Restore the `for _, region in Regions.Regions` loop to re-enable sharding.
	queues[Regions.Regions.NorthAmerica] = { updateAt = os.clock() + Config.LEADER_TICK_SECONDS }

	local cancelled = false

	local function update(region: string)
		local queueInfo = queues[region]
		queueInfo.updateAt = nil

		local queueOk, queueEntries = Promise.try(function()
			return MemoryStore.getQueue(region):GetRangeAsync(Enum.SortDirection.Ascending, 100)
		end):await()

		if cancelled then
			return
		end

		if not queueOk then
			queueInfo.updateAt = os.clock() + Config.LEADER_TICK_SECONDS
			return
		end

		-- Reaction window: a player is only eligible to be teleported once they
		-- have been queued for at least REACTION_SECONDS. entry.sortKey is the
		-- joinTime (os.time), shared across servers, so a fresh entry (e.g. an
		-- accidental touch on the matchmaking part) is left in the queue and
		-- reconsidered next tick, giving the player time to cancel. Anyone who
		-- has already waited longer than the window is teleported without delay.
		local now = os.time()
		local remaining = {}
		for _, entry in queueEntries :: { any } do
			local userId = tonumber(entry.key)
			if userId ~= nil and matchedUserIds[userId] == nil then
				if now - (entry.sortKey :: number) >= Config.REACTION_SECONDS then
					table.insert(remaining, entry)
				end
			end
		end

		if #remaining == 0 then
			formingSince[region] = nil
			queueInfo.updateAt = os.clock() + Config.LEADER_TICK_SECONDS
			return
		end

		local registryOk, registryEntries = Promise.try(function()
			return MemoryStore.getServerRegistry(region):GetRangeAsync(Enum.SortDirection.Descending, 20)
		end):await()

		if cancelled then
			return
		end

		if not registryOk then
			registryEntries = {}
		end

		-- 1) Backfill into existing Arena servers with room -- opportunistic, no minimum.
		for _, server in registryEntries :: { any } do
			if #remaining == 0 then
				break
			end

			local openSlots = server.sortKey :: number
			if openSlots <= 0 then
				continue
			end

			local takeCount = math.min(openSlots, #remaining)
			local batch = table.move(remaining, 1, takeCount, 1, {})
			remaining = table.move(remaining, takeCount + 1, #remaining, 1, {})

			local expireAt = os.clock() + Config.QUEUE_ENTRY_TTL
			for _, entry in batch do
				local userId = tonumber(entry.key) :: number
				matchedUserIds[userId] = expireAt
				MemoryStore.exitQueue(userId, region)
			end

			task.spawn(teleportEntries, batch, server.key, region)
		end

		-- 2) New match formation for whatever backfill couldn't place.
		if #remaining < Config.MIN_PLAYERS then
			formingSince[region] = nil
		else
			if formingSince[region] == nil then
				formingSince[region] = os.clock()
			end

			local elapsed = os.clock() - (formingSince[region] :: number)
			if #remaining >= Config.MAX_PLAYERS or elapsed >= Config.GRACE_SECONDS then
				local ordered = groupBySameLobbyPriority(remaining)
				local batchSize = math.min(Config.MAX_PLAYERS, #ordered)
				local batch = table.move(ordered, 1, batchSize, 1, {})

				local reserveOk, accessCode = pcall(function()
					return TeleportService:ReserveServer(placeId())
				end)

				if reserveOk then
					local expireAt = os.clock() + Config.QUEUE_ENTRY_TTL
					for _, entry in batch do
						local userId = tonumber(entry.key) :: number
						matchedUserIds[userId] = expireAt
						MemoryStore.exitQueue(userId, region)
					end

					formingSince[region] = nil
					task.spawn(teleportEntries, batch, accessCode, region)
				else
					warn(`[Matchmaking] ReserveServer failed for region {region}; will retry next tick`)
				end
			end
		end

		queueInfo.updateAt = os.clock() + Config.LEADER_TICK_SECONDS
	end

	return Promise.new(function(_, _, onCancel)
		local connection = RunService.Heartbeat:Connect(function()
			for userId, expireAt in matchedUserIds do
				if os.clock() >= expireAt then
					matchedUserIds[userId] = nil
				end
			end

			for region, queueInfo in queues do
				if queueInfo.updateAt ~= nil and os.clock() >= queueInfo.updateAt then
					task.spawn(update, region)
				end
			end
		end)

		onCancel(function()
			cancelled = true
			connection:Disconnect()
		end)
	end)
end

-- Boot the matchmaking system on this Lobby server. Pass the host wiring (see
-- the `Config` type). The host is responsible for connecting its own remotes to
-- Matchmaking.joinQueue / Matchmaking.exitQueue and for relaying status (via
-- config.onStatus and/or polling Matchmaking.getStatus).
function Matchmaking.start(matchmakingConfig: Config)
	config = matchmakingConfig

	MemoryStore.setKeyPrefix(config.keyPrefix)

	if config.tunables ~= nil then
		for key, value in config.tunables do
			(Config :: any)[key] = value
		end
	end

	if game.GameId ~= 0 then
		task.spawn(function()
			MessagingService:SubscribeAsync(`{MemoryStore.PREFIX}MMTeleport`, function(message)
				local data = message.Data

				local localPlayers = {}
				for _, userId in data.userIds do
					local player = Players:GetPlayerByUserId(userId)
					if player ~= nil then
						table.insert(localPlayers, player)
					end
				end

				teleportPlayers(localPlayers, data.accessCode, data.region)
			end)
		end)
	end

	LeaderElection.start(runLeaderLoop)

	Players.PlayerRemoving:Connect(Matchmaking.onPlayerRemoving)
end

return Matchmaking
