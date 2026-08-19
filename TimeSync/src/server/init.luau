--!strict

-- Per-player round-trip latency, measured by pinging clients and timing their
-- echo. Despite the "TimeSync" name this measures RTT/latency, not a wall-clock
-- offset. Pairs with the LagCompensation library, which consumes getLatency as
-- its injected latency provider.
--
-- Self-contained: this module owns its transport. On start() it provisions a
-- dedicated Folder ("TimeSyncRemotes") in ReplicatedStorage holding two
-- UnreliableRemoteEvents ("Ping" / "PingBack"), creating them if absent and
-- reusing them if present. No dependency on any game-wide remotes registry or
-- boot ordering. Callers may instead inject pre-made remotes via config.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CONTAINER_NAME = "TimeSyncRemotes"
local PING_REMOTE_NAME = "Ping" -- server -> client (carries send clock)
local PING_BACK_REMOTE_NAME = "PingBack" -- client -> server (echoes it)

local DEFAULT_PING_INTERVAL = 1 -- seconds between pings
local SAMPLE_COUNT = 4 -- rolling samples averaged
local DEFAULT_LATENCY = 0.08 -- assumed round trip before the first sample
local MAX_SANE_LATENCY = 1 -- ignore echoes implying a >1s round trip

export type Config = {
	-- Inject pre-made remotes to skip self-provisioning. Both must be provided
	-- together; at runtime either RemoteEvent or UnreliableRemoteEvent works.
	pingRemote: RemoteEvent?,
	pingBackRemote: RemoteEvent?,
	-- Parent for the self-provisioned remotes (defaults to a Folder named
	-- "TimeSyncRemotes" under ReplicatedStorage).
	container: Instance?,
	-- Override the ping cadence (defaults to 1s).
	pingInterval: number?,
}

local samples: { [Player]: { number } } = {}
local averages: { [Player]: number } = {}
local started = false

local TimeSync = {}

-- Average round-trip time for the player, in seconds.
function TimeSync.getLatency(player: Player): number
	return averages[player] or DEFAULT_LATENCY
end

local function recordSample(player: Player, rtt: number)
	local list = samples[player]
	if not list then
		return
	end

	table.insert(list, rtt)
	while #list > SAMPLE_COUNT do
		table.remove(list, 1)
	end

	local sum = 0
	for _, value in list do
		sum += value
	end
	averages[player] = sum / #list
end

local function setup(player: Player)
	samples[player] = {}
	averages[player] = DEFAULT_LATENCY
end

local function cleanup(player: Player)
	samples[player] = nil
	averages[player] = nil
end

local function ensureRemote(parent: Instance, name: string): UnreliableRemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("UnreliableRemoteEvent") then
		return existing
	end
	local remote = Instance.new("UnreliableRemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function ensureContainer(): Instance
	local existing = ReplicatedStorage:FindFirstChild(CONTAINER_NAME)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = CONTAINER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

function TimeSync.start(config: Config?)
	if started then
		return
	end
	started = true

	local cfg: Config = config or {}
	local pingInterval = cfg.pingInterval or DEFAULT_PING_INTERVAL

	local pingEvent, pingBackEvent
	if cfg.pingRemote and cfg.pingBackRemote then
		pingEvent = cfg.pingRemote
		pingBackEvent = cfg.pingBackRemote
	else
		local container = cfg.container or ensureContainer()
		pingEvent = ensureRemote(container, PING_REMOTE_NAME)
		pingBackEvent = ensureRemote(container, PING_BACK_REMOTE_NAME)
	end

	for _, player in Players:GetPlayers() do
		setup(player)
	end
	Players.PlayerAdded:Connect(setup)
	Players.PlayerRemoving:Connect(cleanup)

	-- The client echoes back the exact clock value we sent; round trip is just
	-- now - sent, so no client/server clock sync is needed.
	pingBackEvent.OnServerEvent:Connect(function(player: Player, sentClock: unknown)
		if typeof(sentClock) ~= "number" then
			return
		end
		local rtt = os.clock() - sentClock
		if rtt >= 0 and rtt <= MAX_SANE_LATENCY then
			recordSample(player, rtt)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(pingInterval)
			local now = os.clock()
			for _, player in Players:GetPlayers() do
				pingEvent:FireClient(player, now)
			end
		end
	end)
end

return TimeSync
