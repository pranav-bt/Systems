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

	--[[
		Seconds between automatic flushes.

		The only trigger used to be game:BindToClose, which meant every session a server ever
		recorded sat in memory until it shut down -- so a crash or an unclean close lost all of
		it, and the single write had to fit inside BindToClose's ~30s budget. Flushing
		periodically bounds the loss to one interval and leaves shutdown with little to do.

		0 disables the timer, leaving the shutdown flush as the only one.
	]]
	FLUSH_INTERVAL = 120,

	--[[
		Sessions per DataStore key before rotating to a new one.

		Everything used to merge into a single "HeatmapBatch_<JobId>" for the life of the
		server, and a DataStore value is capped at 4MB -- so a busy server eventually built a
		value too large to store, which then failed to write. Rotating bounds each key.
	]]
	MAX_SESSIONS_PER_KEY = 150,
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
local flushLoop: thread? = nil

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

--[[
	The key currently being written to, and how many sessions have landed in it.

	Rotation is counted rather than measured, because there is no way to ask how large a value
	will be before writing it. A count is a proxy, but it is a bounded one -- and the failure
	it prevents (a value over 4MB) is unrecoverable in the old design, since the write that
	discovers it is also the write that discarded the batch.
]]
local keyIndex = 0
local sessionsInKey = 0

local function currentKey(): string
	return `HeatmapBatch_{game.JobId}_{keyIndex}`
end

--[[
	Writes everything pending, and KEEPS IT if the write does not land.

	The order here is the whole fix. This used to drain `pendingFlush` into a local batch
	before attempting the write, so a failure -- throttling, a value over the size limit, the
	service being down -- left the sessions already gone from the queue and written by nobody.
	DataStore throttling is normal operation rather than an exceptional event, so that was
	guaranteed data loss on a schedule.

	Now the batch is only cleared once the write has succeeded. A failed flush leaves
	everything queued for the next one.

	Returns whether it wrote, so the caller can say something true about it.
]]
local function flush(): boolean
	-- Archive any players still in-server, so their partial journeys are included.
	for userId in activeSessions do
		archiveSession(userId)
	end

	local batch = {
		meta = {
			lastUpdated = os.time(),
			placeVersion = game.PlaceVersion,
			serverJobId = game.JobId,
		},
		sessions = {},
	}

	local count = 0
	for guid, session in pendingFlush do
		batch.sessions[guid] = session
		count += 1
	end

	if count == 0 then
		return true
	end

	-- Rotate before writing rather than after, so this batch goes to a key that has room.
	if sessionsInKey > 0 and sessionsInKey + count > CONFIG.MAX_SESSIONS_PER_KEY then
		keyIndex += 1
		sessionsInKey = 0
	end

	local key = currentKey()
	local success, err = pcall(function()
		getDataStore():UpdateAsync(key, function(oldValue)
			local existing = oldValue or { meta = batch.meta, sessions = {} }
			-- Refreshed on every merge. Stamped once, it left a reader with no way to tell a
			-- live server's batch from an abandoned one.
			existing.meta = batch.meta
			for guid, session in batch.sessions do
				existing.sessions[guid] = session
			end
			return existing
		end)
	end)

	if not success then
		-- Left in pendingFlush deliberately: the next flush retries it.
		warn(`[Heatmap] Flush failed, {count} session(s) kept for the next attempt:`, err)
		return false
	end

	for guid in batch.sessions do
		pendingFlush[guid] = nil
	end
	sessionsInKey += count
	return success
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

	--[[
		The periodic flush. Without it, the shutdown hook below was the only writer, and a
		server that crashed took every session with it.
	]]
	if CONFIG.FLUSH_INTERVAL > 0 then
		flushLoop = task.spawn(function()
			while true do
				task.wait(CONFIG.FLUSH_INTERVAL)
				flush()
			end
		end)
	end

	--[[
		Shutdown still flushes, and now RETRIES once. There is no later attempt after this one,
		so the usual "leave it queued for next time" has nowhere to leave it -- a single retry
		covers the throttle that would otherwise be the last word.
	]]
	game:BindToClose(function()
		if not flush() then
			task.wait(1)
			flush()
		end
	end)
end

--[[
	Writes everything pending now. Returns whether it landed.

	Public because a host may want to flush on its own schedule -- a round ending, a lobby
	emptying -- and because a module whose only trigger is server shutdown cannot be exercised
	by anything, including a test.
]]
function Heatmap.flush(): boolean
	return flush()
end

-- Stops the periodic flush. Pairs with init for a host that tears the system down.
function Heatmap.stop()
	if flushLoop then
		task.cancel(flushLoop)
		flushLoop = nil
	end
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
