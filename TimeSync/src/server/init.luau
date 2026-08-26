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
--[[
	Per player, the clock values sent that have not been echoed yet.

	THIS IS WHAT MAKES THE MEASUREMENT THE SERVER'S. Without it `OnServerEvent` accepted any
	number and treated `os.clock() - it` as a round trip, so a client that ignored the pings
	entirely -- or had never been sent one -- could report whatever latency it liked, bounded
	only by MAX_SANE_LATENCY. That number is consumed by LagCompensation as the amount it
	rewinds the world before validating a hit, which makes "the client picks it" the whole
	shape of a lag-compensation exploit.

	An echo now has to carry a value this server actually sent, and the value is consumed on
	use. So a forged echo has to guess an exact float, a replayed one matches nothing, and
	spam gets at most one sample per ping.

	A LIST RATHER THAN A SINGLE VALUE, because an echo can legitimately arrive after the next
	ping has gone out -- a player slower than the ping interval would otherwise never produce
	a sample at all and sit on the default forever. Bounded by pruning: a value older than
	MAX_SANE_LATENCY can no longer produce an acceptable sample, so it is dropped.
]]
local outstanding: { [Player]: { number } } = {}
local started = false
local pingLoop: thread? = nil

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
	outstanding[player] = {}
end

local function cleanup(player: Player)
	samples[player] = nil
	averages[player] = nil
	outstanding[player] = nil
end

--[[
	Records that we sent this value, and forgets any too old to be echoed usefully.

	The prune is what bounds the list: at a 1s interval and a 1s sanity limit it holds one or
	two entries, and a client that never echoes cannot make it grow.
]]
local function noteSent(player: Player, clockValue: number)
	local pending = outstanding[player]
	if not pending then
		return
	end
	table.insert(pending, clockValue)
	local cutoff = clockValue - MAX_SANE_LATENCY
	while pending[1] and pending[1] < cutoff do
		table.remove(pending, 1)
	end
end

-- Consumes a matching outstanding ping, or reports that there was none. Consuming is what
-- stops a single ping being echoed repeatedly to flood the sample window.
local function claimSent(player: Player, clockValue: number): boolean
	local pending = outstanding[player]
	if not pending then
		return false
	end
	local index = table.find(pending, clockValue)
	if not index then
		return false
	end
	table.remove(pending, index)
	return true
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
		-- Unmatched means forged, replayed, or so late it can no longer be a real sample.
		-- All three are the same thing from here: not a measurement.
		if not claimSent(player, sentClock) then
			return
		end
		local rtt = os.clock() - sentClock
		if rtt >= 0 and rtt <= MAX_SANE_LATENCY then
			recordSample(player, rtt)
		end
	end)

	local function pingEveryone()
		local now = os.clock()
		for _, player in Players:GetPlayers() do
			noteSent(player, now)
			pingEvent:FireClient(player, now)
		end
	end

	pingLoop = task.spawn(function()
		-- Immediately, then on the interval. Waiting first left every joining player on the
		-- assumed default for a full interval before anything was measured.
		pingEveryone()
		while true do
			task.wait(pingInterval)
			pingEveryone()
		end
	end)
end

--[[
	Stops pinging and forgets every measurement.

	Exists because the loop had no way out: `while true do task.wait() end` on a spawned
	thread runs for the life of the server, which is fine in a live game and means the module
	cannot be stopped, restarted, or torn down anywhere else.
]]
function TimeSync.stop()
	if pingLoop then
		task.cancel(pingLoop)
		pingLoop = nil
	end
	started = false
	table.clear(samples)
	table.clear(averages)
	table.clear(outstanding)
end

return TimeSync
