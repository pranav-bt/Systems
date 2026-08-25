--!strict

-- Client half of Trading. Transport only -- no window, no board, no copy.
--
-- WHY THERE IS NO MESSAGE TABLE HERE. Refusals arrive as reason KEYS. Mapping them to
-- sentences is the host's job: two games word the same refusal differently, and a package
-- that ships strings forces either English or a localisation dependency.
--
-- THE SERVER IS THE ONLY SOURCE OF STATE. `onState` hands over the whole session every time
-- it changes, and a screen should draw that rather than keeping its own copy -- the failure
-- this design exists to prevent is two screens quietly disagreeing about what is on the
-- table.
--
-- NOTE ON LINES CROSSING THE WIRE. A RemoteEvent copies tables, so the lines a screen
-- receives are copies of what the other player offered, with any metatable gone. Draw them;
-- do not expect them to be the same objects the server holds.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TradingClient = {}

local CONTAINER_NAME = "TradingRemotes"
local ACTION_REMOTE_NAME = "Action"
local UPDATE_REMOTE_NAME = "Update"

local REMOTE_WAIT = 30

export type State = {
	partner: Player,
	yours: { any },
	theirs: { any },
	youReady: boolean,
	theyReady: boolean,
	-- nil when no countdown is running.
	completesIn: number?,
}

local actionRemote: RemoteEvent? = nil
local updateRemote: RemoteEvent? = nil
local started = false

local stateHandlers: { (state: State) -> () } = {}
local noticeHandlers: { (reason: string, detail: Player?) -> () } = {}
local invitedHandlers: { (from: Player) -> () } = {}
local closedHandlers: { (reason: string) -> () } = {}

local function findRemote(name: string): RemoteEvent?
	local container = ReplicatedStorage:WaitForChild(CONTAINER_NAME, REMOTE_WAIT)
	if not container then
		warn(`[Trading] no "{CONTAINER_NAME}" folder appeared in {REMOTE_WAIT}s -- is the server half started?`)
		return nil
	end
	local remote = container:WaitForChild(name, REMOTE_WAIT)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

--[[
	Resolves the remotes and begins listening. YIELDS on first call while it waits for the
	server to provision them.

	Idempotent, which is what lets every function below just call it rather than depending on
	a host getting the start order right.
]]
function TradingClient.start()
	if started then
		return
	end
	started = true
	actionRemote = findRemote(ACTION_REMOTE_NAME)
	updateRemote = findRemote(UPDATE_REMOTE_NAME)

	local remote = updateRemote
	if not remote then
		return
	end
	remote.OnClientEvent:Connect(function(kind: string, a: any, b: any)
		local handlers = if kind == "state"
			then stateHandlers
			elseif kind == "notice" then noticeHandlers
			elseif kind == "invited" then invitedHandlers
			elseif kind == "closed" then closedHandlers
			else nil
		if not handlers then
			return
		end
		for _, handler in handlers do
			-- Spawned: a handler that yields must not stall the ones behind it, and must not
			-- be able to fail the dispatch that called it.
			task.spawn(handler, a, b)
		end
	end)
end

local function listen<T>(handlers: { T }, handler: T): () -> ()
	TradingClient.start()
	table.insert(handlers, handler)
	return function()
		local index = table.find(handlers, handler)
		if index then
			table.remove(handlers, index)
		end
	end
end

-- The whole session, every time anything about it changes. Returns a function that stops
-- listening.
function TradingClient.onState(handler: (state: State) -> ()): () -> ()
	return listen(stateHandlers, handler)
end

-- A refusal or an announcement, as a reason KEY plus whoever it is about.
function TradingClient.onNotice(handler: (reason: string, detail: Player?) -> ()): () -> ()
	return listen(noticeHandlers, handler)
end

function TradingClient.onInvited(handler: (from: Player) -> ()): () -> ()
	return listen(invitedHandlers, handler)
end

-- The session ended, with the reason it ended for.
function TradingClient.onClosed(handler: (reason: string) -> ()): () -> ()
	return listen(closedHandlers, handler)
end

local function send(kind: string, payload: any?)
	TradingClient.start()
	local remote = actionRemote
	if not remote then
		warn("[Trading] no action remote; is the server half started?")
		return
	end
	remote:FireServer(kind, payload)
end

-- BY USER ID, not by name: the server resolves it against players in this server, which is
-- the whole trust boundary for who may be traded with.
function TradingClient.invite(userId: number)
	send("invite", userId)
end

function TradingClient.respond(accept: boolean)
	send("respond", accept == true)
end

-- Replaces your whole side of the table. Not "add a line": the server stores what it is
-- given, so a partial update would be a second definition of what is on offer.
function TradingClient.offer(lines: { any })
	send("offer", lines)
end

function TradingClient.setReady(agreed: boolean)
	send("ready", agreed == true)
end

function TradingClient.cancel()
	send("cancel")
end

return TradingClient
