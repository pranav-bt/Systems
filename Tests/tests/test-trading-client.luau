-- The Trading client half: remote discovery, the dispatch table, and what each call puts on
-- the wire.
--
-- "Transport only" is not "trivial". This module maps four message kinds onto four handler
-- lists, hands back an unsubscribe closure, and has a `start` that yields on first call and
-- must stay idempotent across every entry point. A typo in the dispatch table means a signal
-- silently never fires, which no amount of server-side testing would notice.
local rbx = require("./shim/roblox")
local Client = require("./shim/library")("Trading", "client")
local task = require("@lune/task")

local passed, failed = 0, 0
local function check(name, ok, detail)
	if ok then
		passed += 1
		print(("  ok   %s"):format(name))
	else
		failed += 1
		print(("  FAIL %s -- %s"):format(name, tostring(detail)))
	end
end

-- Provisioned exactly as the server half provisions it, because that is what the client
-- looks for by name.
local container = rbx.Instance.new("Folder")
container.Name = "TradingRemotes"
local action = rbx.Instance.new("RemoteEvent")
action.Name = "Action"
local update = rbx.Instance.new("RemoteEvent")
update.Name = "Update"
container:Add(action)
container:Add(update)
rbx.ReplicatedStorage:Add(container)

print("the dispatch table routes each kind to its own handlers")
do
	local seen = { state = {}, notice = {}, invited = {}, closed = {} }
	Client.onState(function(state)
		table.insert(seen.state, state)
	end)
	Client.onNotice(function(reason, who)
		table.insert(seen.notice, { reason = reason, who = who })
	end)
	Client.onInvited(function(from)
		table.insert(seen.invited, from)
	end)
	Client.onClosed(function(reason)
		table.insert(seen.closed, reason)
	end)

	local ana = rbx.addPlayer("Ana")
	update:FireClient(ana, "state", { partner = ana, yours = {}, theirs = {}, youReady = false, theyReady = false })
	task.wait()
	check("a state message reaches onState", #seen.state == 1, #seen.state)
	check("and nothing else", #seen.notice == 0 and #seen.invited == 0 and #seen.closed == 0)

	update:FireClient(ana, "notice", "NotEnough", ana)
	task.wait()
	check("a notice reaches onNotice", #seen.notice == 1)
	check("carrying the reason key", seen.notice[1].reason == "NotEnough")
	check("and who it is about", seen.notice[1].who == ana)

	update:FireClient(ana, "invited", ana)
	task.wait()
	check("an invite reaches onInvited", #seen.invited == 1 and seen.invited[1] == ana)

	update:FireClient(ana, "closed", "Complete")
	task.wait()
	check("a close reaches onClosed", #seen.closed == 1 and seen.closed[1] == "Complete")

	-- A kind this module does not know is dropped rather than fanned out to everybody.
	update:FireClient(ana, "somethingelse", "payload")
	task.wait()
	check("an unknown kind reaches nobody", #seen.state == 1 and #seen.notice == 1 and #seen.closed == 1)
	rbx.removePlayer(ana)
end

print("handlers stack, and unsubscribe")
do
	local first, second = 0, 0
	local stopFirst = Client.onClosed(function()
		first += 1
	end)
	Client.onClosed(function()
		second += 1
	end)

	local ana = rbx.addPlayer("Ana")
	update:FireClient(ana, "closed", "Cancelled")
	task.wait()
	check("both handlers ran", first == 1 and second == 1, `{first}/{second}`)

	stopFirst()
	update:FireClient(ana, "closed", "Cancelled")
	task.wait()
	check("the unsubscribed one stopped", first == 1, first)
	check("while the other kept going", second == 2, second)
	rbx.removePlayer(ana)
end

print("a throwing handler does not take its siblings with it")
do
	local after = 0
	Client.onNotice(function()
		error("this handler is broken")
	end)
	Client.onNotice(function()
		after += 1
	end)

	local ana = rbx.addPlayer("Ana")
	-- Spawned per handler, so the throw lands on its own thread rather than aborting the
	-- dispatch. The error prints above; that is the same place a Roblox handler's would go.
	local ok = pcall(function()
		update:FireClient(ana, "notice", "Failed")
	end)
	task.wait()
	check("the dispatch did not throw", ok)
	check("and the sibling still ran", after == 1, after)
	rbx.removePlayer(ana)
end

print("each call puts the right move on the wire")
do
	action:clearFired()
	Client.invite(4242)
	Client.respond(true)
	Client.offer({ { id = "Knight", level = 3, quantity = 2 } })
	Client.setReady(true)
	Client.cancel()
	local fired = action:firedToServer()

	check("five moves were sent", #fired == 5, #fired)
	check("invite carries the user id", fired[1][1] == "invite" and fired[1][2] == 4242)
	check("respond carries the answer", fired[2][1] == "respond" and fired[2][2] == true)
	check("offer carries the lines", fired[3][1] == "offer" and fired[3][2][1].id == "Knight")
	check("ready carries the flag", fired[4][1] == "ready" and fired[4][2] == true)
	check("cancel carries nothing", fired[5][1] == "cancel" and fired[5][2] == nil)

	-- Coerced rather than passed through, so a truthy value cannot arrive as a table the
	-- server then has to interpret.
	action:clearFired()
	Client.respond("yes" :: any)
	Client.setReady(0 :: any)
	local coerced = action:firedToServer()
	check("respond coerces to a boolean", coerced[1][2] == false, coerced[1][2])
	check("setReady coerces too", coerced[2][2] == false, coerced[2][2])
end

print("start is idempotent across every entry point")
do
	-- Every public function calls start(); it must not connect a second listener each time.
	local hits = 0
	Client.onState(function()
		hits += 1
	end)
	Client.start()
	Client.start()
	Client.invite(1)
	local ana = rbx.addPlayer("Ana")
	update:FireClient(ana, "state", { partner = ana, yours = {}, theirs = {}, youReady = false, theyReady = false })
	task.wait()
	check("one message still produces one call", hits == 1, hits)
	rbx.removePlayer(ana)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
