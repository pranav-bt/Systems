--!strict

-- Client half of CommunityReward. It owns the transport and NOTHING else -- no
-- window, no copy, no layout. The host draws the UI; this exists so the remote
-- names are not written out twice, once per realm.
--
-- WHY THERE IS NO MESSAGE TABLE HERE. Refusals arrive as reason KEYS
-- ("NotInGroup", "AlreadyClaimed", ...). Mapping them to sentences is the host's
-- job, because two games word the same flow differently and a package that ships
-- strings forces either English or a localisation dependency. `Reasons` below is
-- exported so a host can map all of them and fail its own build when a new one
-- appears.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CommunityRewardClient = {}

local CONTAINER_NAME = "CommunityRewardRemotes"
local CLAIM_REMOTE_NAME = "Claim"
local RESULT_REMOTE_NAME = "Result"
local OPEN_REMOTE_NAME = "Open"

local REMOTE_WAIT = 30 -- generous: the server provisions these during its own start

-- Every refusal the server can send. Exported for exhaustive mapping.
CommunityRewardClient.Reasons = table.freeze({
	AlreadyClaimed = "AlreadyClaimed",
	Unavailable = "Unavailable",
	NotInGroup = "NotInGroup",
	NotReady = "NotReady",
	Failed = "Failed",
})

export type Config = {
	-- Inject pre-made remotes to skip the lookup. Any subset may be given.
	claimRemote: RemoteEvent?,
	resultRemote: RemoteEvent?,
	openRemote: RemoteEvent?,
}

local claimRemote: RemoteEvent? = nil
local resultRemote: RemoteEvent? = nil
local openRemote: RemoteEvent? = nil
local started = false

local function findRemote(injected: RemoteEvent?, name: string): RemoteEvent?
	if injected then
		return injected
	end
	local container = ReplicatedStorage:WaitForChild(CONTAINER_NAME, REMOTE_WAIT)
	if not container then
		warn(`[CommunityReward] no "{CONTAINER_NAME}" folder appeared in {REMOTE_WAIT}s -- is the server half started?`)
		return nil
	end
	local remote = container:WaitForChild(name, REMOTE_WAIT)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

--[[
	Resolves the remotes. YIELDS on first call while it waits for the server to
	provision them, so call it from a thread that may wait.

	Idempotent: calling it again is free, which is what lets `claim` and the
	listeners below each just ask rather than depending on start order.
]]
function CommunityRewardClient.start(settings: Config?)
	if started then
		return
	end
	started = true
	claimRemote = findRemote(settings and settings.claimRemote, CLAIM_REMOTE_NAME)
	resultRemote = findRemote(settings and settings.resultRemote, RESULT_REMOTE_NAME)
	openRemote = findRemote(settings and settings.openRemote, OPEN_REMOTE_NAME)
end

-- Ask the server to pay. Carries nothing -- see the server header. The answer
-- arrives through onResult, never as a return value: the server yields on a
-- membership lookup, and a call that looked synchronous would be a lie.
function CommunityRewardClient.claim()
	CommunityRewardClient.start()
	if not claimRemote then
		warn("[CommunityReward] claim() with no remote; is the server half started?")
		return
	end
	claimRemote:FireServer()
end

-- (ok: boolean, reason: string?) -- reason is a key from Reasons, absent on success.
function CommunityRewardClient.onResult(handler: (ok: boolean, reason: string?) -> ()): RBXScriptConnection?
	CommunityRewardClient.start()
	if not resultRemote then
		return nil
	end
	return resultRemote.OnClientEvent:Connect(handler)
end

-- Fired when the player triggers the lobby prop's prompt. The host opens its window.
function CommunityRewardClient.onOpenRequested(handler: () -> ()): RBXScriptConnection?
	CommunityRewardClient.start()
	if not openRemote then
		return nil
	end
	return openRemote.OnClientEvent:Connect(handler)
end

return CommunityRewardClient
