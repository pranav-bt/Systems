-- Echoes the server's latency pings straight back so it can measure our round
-- trip. Points at the transport the server module owns: a Folder
-- ("TimeSyncRemotes") under ReplicatedStorage holding the "Ping" / "PingBack"
-- remotes. Callers may instead inject pre-made remotes via config.
--
-- The echo loop is deferred off the caller thread (remotes replicate in, and
-- WaitForChild yields) so start() returns immediately and never yields.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CONTAINER_NAME = "TimeSyncRemotes"
local PING_REMOTE_NAME = "Ping"
local PING_BACK_REMOTE_NAME = "PingBack"

export type Config = {
	pingRemote: RemoteEvent?,
	pingBackRemote: RemoteEvent?,
	container: Instance?,
}

local TimeSyncClient = {}
local started = false

function TimeSyncClient.start(config: Config?)
	if started then
		return
	end
	started = true

	local cfg: Config = config or {}

	task.spawn(function()
		local pingEvent, pingBackEvent
		if cfg.pingRemote and cfg.pingBackRemote then
			pingEvent = cfg.pingRemote
			pingBackEvent = cfg.pingBackRemote
		else
			local container = cfg.container or ReplicatedStorage:WaitForChild(CONTAINER_NAME)
			pingEvent = container:WaitForChild(PING_REMOTE_NAME)
			pingBackEvent = container:WaitForChild(PING_BACK_REMOTE_NAME)
		end

		pingEvent.OnClientEvent:Connect(function(sentClock)
			pingBackEvent:FireServer(sentClock)
		end)
	end)
end

return TimeSyncClient
