--[[
    Heatmap
    --------------
    Tracks per-session player movement as a voxelized, RLE-compressed journey
    array, tagged with funnel metadata. Flushes anonymised session batches to
    DataStore on server shutdown.

    Usage:
        local Heatmap = require(path.to.Heatmap)

        -- Optional: override any CONFIG field before init().
        Heatmap.configure({
            DATASTORE_NAME = "MyGameHeatmap_v1",
            CELL_SIZE = 8,
        })

        Heatmap.init()

        -- When a player reaches a funnel step:
        Heatmap.setFunnelStep(player, 3)

        -- When a player takes a path (e.g. skipped tutorial):
        Heatmap.setMeta(player, "funnelPath", "skip")

    Data shape written to DataStore:
        HeatmapBatch_{jobId} = {
            meta     = { lastUpdated, placeVersion, serverJobId },
            sessions = {
                [guid] = {
                    meta    = { funnelStep, funnelPath, ... },
                    journey = { {x,y,z,run}, ... }  -- RLE encoded
                }
            }
        }
]]

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local CONFIG = {
	-- Voxel cell size in studs. Larger = less precision, smaller DataStore footprint.
	CELL_SIZE = 12,

	-- World-space origin that voxel cells are measured relative to. Positions are
	-- offset by this before flooring into cells, so a map that is not centred on
	-- (0, 0, 0) can be anchored here. Default keeps cells relative to world origin.
	ORIGIN = Vector3.new(0, 0, 0),

	-- How often to sample each player's position in seconds.
	SAMPLE_INTERVAL = 1,

	-- Hard cap on the number of journey samples kept per session.
	-- Samples beyond this are dropped (oldest are kept, newest are truncated).
	MAX_JOURNEY_SAMPLES = 600,

	-- DataStore name.
	DATASTORE_NAME = "LobbyHeatmap_v1",
}

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

-- Resolved lazily so CONFIG.DATASTORE_NAME can be overridden via configure()
-- before the first flush. Reset to nil whenever the name changes.
local DataStore = nil

local function getDataStore()
	if not DataStore then
		DataStore = DataStoreService:GetDataStore(CONFIG.DATASTORE_NAME)
	end
	return DataStore
end

-- Keyed by UserId while player is in-server. UserId never written to DataStore.
local activeSessions = {} -- [userId] = { journey: {cell,...}, meta: {...} }
local lastSampleTime = {} -- [userId] = os.clock()

-- Sessions move here on PlayerRemoving, keyed by anonymous GUID.
-- BindToClose drains this alongside any remaining activeSessions.
local pendingFlush = {} -- [guid]   = { journey: RLE, meta: {...} }

--------------------------------------------------------------------------------
-- Voxelization
--------------------------------------------------------------------------------

local function posToCell(pos)
	local origin = CONFIG.ORIGIN
	return {
		math.floor((pos.X - origin.X) / CONFIG.CELL_SIZE),
		math.floor((pos.Y - origin.Y) / CONFIG.CELL_SIZE),
		math.floor((pos.Z - origin.Z) / CONFIG.CELL_SIZE),
	}
end

--------------------------------------------------------------------------------
-- RLE encode / decode
--
-- Encoded format: array of { x, y, z, runLength }
-- Runs of identical cells (player standing still) compress to a single tuple.
--------------------------------------------------------------------------------

local function encodeJourney(raw)
	if #raw == 0 then
		return {}
	end

	local rle = {}
	local cur = raw[1]
	local run = 1

	for i = 2, #raw do
		local c = raw[i]
		if c[1] == cur[1] and c[2] == cur[2] and c[3] == cur[3] then
			run += 1
		else
			table.insert(rle, { cur[1], cur[2], cur[3], run })
			cur = c
			run = 1
		end
	end

	table.insert(rle, { cur[1], cur[2], cur[3], run })
	return rle
end

local function decodeJourney(rle)
	local raw = {}
	for _, entry in rle do
		for _ = 1, entry[4] do
			table.insert(raw, { entry[1], entry[2], entry[3] })
		end
	end
	return raw
end

--------------------------------------------------------------------------------
-- Session helpers
--------------------------------------------------------------------------------

local function newSession()
	return {
		journey = {},
		meta = {
			funnelStep = 0,
			funnelPath = "none",
		},
	}
end

-- Strip UserId from a session, RLE-encode the journey, and move to pendingFlush.
local function archiveSession(userId)
	local session = activeSessions[userId]
	if not session then
		return
	end

	activeSessions[userId] = nil
	lastSampleTime[userId] = nil

	-- Assign an anonymous GUID. This is the only identifier from here on.
	local guid = HttpService:GenerateGUID(false)

	-- Enforce the hard journey cap before encoding.
	local raw = session.journey
	if #raw > CONFIG.MAX_JOURNEY_SAMPLES then
		local start = #raw - CONFIG.MAX_JOURNEY_SAMPLES + 1
		local trimmed = {}
		for i = start, #raw do
			trimmed[#trimmed + 1] = raw[i]
		end
		raw = trimmed
	end

	pendingFlush[guid] = {
		meta = session.meta,
		journey = encodeJourney(raw),
	}
end

--------------------------------------------------------------------------------
-- Flush
--
-- Merges all pending and remaining active sessions into one DataStore write.
-- Active sessions are stripped of UserId at this point.
-- Called exclusively from BindToClose — no periodic timer.
--------------------------------------------------------------------------------

local function flush()
	local batch = {
		meta = {
			lastUpdated = os.time(),
			placeVersion = game.PlaceVersion,
			serverJobId = game.JobId,
		},
		sessions = {},
	}

	-- Archive any players still in-server at shutdown time.
	for userId in activeSessions do
		archiveSession(userId)
	end

	-- Drain pendingFlush into the batch.
	for guid, session in pendingFlush do
		batch.sessions[guid] = session
		pendingFlush[guid] = nil
	end

	-- Skip write if nothing to record.
	if next(batch.sessions) == nil then
		return
	end

	local success, err = pcall(function()
		getDataStore():UpdateAsync("HeatmapBatch_" .. game.JobId, function(oldValue)
			local existing = oldValue or { meta = batch.meta, sessions = {} }

			-- Merge sessions. GUID keys ensure no collisions.
			for guid, session in batch.sessions do
				existing.sessions[guid] = session
			end

			return existing
		end)
	end)

	if not success then
		warn("[Heatmap] Flush failed:", err)
	end

	local numberOfSessions = 0
	for _ in batch.sessions do
		numberOfSessions += 1
	end
	print("[Heatmap] Flush complete. Recorded", tostring(numberOfSessions), "sessions.")
end

--------------------------------------------------------------------------------
-- Sampling loop
--
-- Runs on Heartbeat but throttled per-player to CONFIG.SAMPLE_INTERVAL.
-- Samples HumanoidRootPart position and appends the voxelized cell to journey.
--------------------------------------------------------------------------------

local function startSamplingLoop()
	RunService.Heartbeat:Connect(function()
		local now = os.clock()

		for userId, session in activeSessions do
			if now - (lastSampleTime[userId] or 0) < CONFIG.SAMPLE_INTERVAL then
				continue
			end

			lastSampleTime[userId] = now

			local player = Players:GetPlayerByUserId(userId)
			if not player then
				continue
			end

			local character = player.Character
			if not character then
				continue
			end

			local hrp = character:FindFirstChild("HumanoidRootPart")
			if not hrp then
				continue
			end

			table.insert(session.journey, posToCell(hrp.Position))
		end
	end)
end

--------------------------------------------------------------------------------
-- Module
--------------------------------------------------------------------------------

local Heatmap = {}

--[[
    Heatmap.configure(overrides)
    Shallow-merges the given table into CONFIG, keeping any unspecified field at
    its current default. Call once before Heatmap.init() for predictable
    behaviour. CELL_SIZE, ORIGIN, SAMPLE_INTERVAL and MAX_JOURNEY_SAMPLES are
    read live so they also take effect if changed after init(); changing
    DATASTORE_NAME re-resolves the DataStore on the next flush.

    Recognised fields: CELL_SIZE, ORIGIN, SAMPLE_INTERVAL, MAX_JOURNEY_SAMPLES,
    DATASTORE_NAME.
]]
function Heatmap.configure(overrides)
	if type(overrides) ~= "table" then
		return
	end

	for key, value in overrides do
		CONFIG[key] = value
	end

	-- DataStore is captured lazily; drop the cached handle so a new name resolves.
	if overrides.DATASTORE_NAME ~= nil then
		DataStore = nil
	end
end

--[[
    Heatmap.init()
    Registers player lifecycle hooks, starts the sampling loop, and binds flush
    to server shutdown. Call once from a server Script on startup.
]]
function Heatmap.init()
	-- Register any players already in-server (e.g. if init is called late).
	for _, player in Players:GetPlayers() do
		activeSessions[player.UserId] = newSession()
		lastSampleTime[player.UserId] = os.clock()
	end

	Players.PlayerAdded:Connect(function(player)
		activeSessions[player.UserId] = newSession()
		lastSampleTime[player.UserId] = os.clock()
	end)

	-- On leave, strip UserId and move to pending immediately.
	-- Their encoded journey is ready for the next flush.
	Players.PlayerRemoving:Connect(function(player)
		archiveSession(player.UserId)
	end)

	startSamplingLoop()

	game:BindToClose(flush)
end

--[[
    Heatmap.setFunnelStep(player, step)
    Updates the highest funnel step reached for this session.
    Safe to call multiple times — only advances, never regresses.
]]
function Heatmap.setFunnelStep(player, step)
	local session = activeSessions[player.UserId]
	if not session then
		return
	end

	session.meta.funnelStep = math.max(session.meta.funnelStep, step)
end

--[[
    Heatmap.setMeta(player, key, value)
    Attach arbitrary string metadata to a session for custom filtering.
    E.g. Heatmap.setMeta(player, "mapName", "Skybridge")
    Values are stored as-is. Avoid UserId or any identifying data.
]]
function Heatmap.setMeta(player, key, value)
	local session = activeSessions[player.UserId]
	if not session then
		return
	end

	session.meta[key] = value
end

--[[
    Heatmap.decodeJourney(rle)
    Utility exposed for the Open Cloud analysis script.
    Returns a flat array of { x, y, z } cells, one per sample.
    Index N corresponds to (N-1) * SAMPLE_INTERVAL seconds into the session.
]]
Heatmap.decodeJourney = decodeJourney

return Heatmap
