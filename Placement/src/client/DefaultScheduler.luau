-- Self-contained default scheduler used when the host does not inject one.
--
-- Replaces the game's `ReplicatedStorage.Client.ClientScheduler`. Phase
-- names match what the placement modules request; RunService events are chosen
-- to mirror the original ClientScheduler wiring:
--   "Input"          -> PreRender  (early each frame, after input is polled)
--   "PostSimulation" -> Heartbeat  (late each frame; the preview follows cursor)
-- Any other phase falls back to Heartbeat.

local RunService = game:GetService("RunService")

local DefaultScheduler = {}

local PHASE_EVENTS: { [string]: RBXScriptSignal } = {
	Input = RunService.PreRender,
	PostSimulation = RunService.Heartbeat,
}

function DefaultScheduler.schedule(phase: string, name: string, callback: (deltaTime: number) -> ()): () -> ()
	local event = PHASE_EVENTS[phase] or RunService.Heartbeat
	local connection = event:Connect(function(deltaTime: number)
		debug.profilebegin(name)
		callback(deltaTime)
		debug.profileend()
	end)
	return function()
		connection:Disconnect()
	end
end

return DefaultScheduler
