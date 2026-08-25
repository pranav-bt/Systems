-- The CommunityReward client half: remote discovery and the three handlers.
--
-- Small, but not nothing: it decides which remote each listener attaches to, and a claim
-- that reached the wrong one would look identical from the server's side.
local rbx = require("./shim/roblox")
local Client = require("./shim/library")("CommunityReward", "client")

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

-- Named exactly as the server half provisions them.
local container = rbx.Instance.new("Folder")
container.Name = "CommunityRewardRemotes"
local claim = rbx.Instance.new("RemoteEvent")
claim.Name = "Claim"
local result = rbx.Instance.new("RemoteEvent")
result.Name = "Result"
local open = rbx.Instance.new("RemoteEvent")
open.Name = "Open"
container:Add(claim)
container:Add(result)
container:Add(open)
rbx.ReplicatedStorage:Add(container)

print("the exported reasons cover what the server can send")
do
	local reasons = Client.Reasons
	for _, key in { "AlreadyClaimed", "Unavailable", "NotInGroup", "NotReady", "Failed" } do
		check(`{key} is exported`, reasons[key] == key, reasons[key])
	end
	-- Frozen, so a host cannot accidentally shadow one and silently break its own mapping.
	check("and the table is frozen", not pcall(function()
		(reasons :: any).Extra = "Extra"
	end))
end

print("claiming carries nothing at all")
do
	local ana = rbx.addPlayer("Ana")
	claim:clearFired()
	Client.claim()
	local fired = claim:firedToServer()
	check("one claim was sent", #fired == 1, #fired)
	-- The entire security model: there is nothing on the way in to forge.
	check("with no arguments", #fired[1] == 0, #fired[1])
	rbx.removePlayer(ana)
end

print("results and open requests reach their own handlers")
do
	local results, opens = {}, 0
	Client.onResult(function(ok, reason)
		table.insert(results, { ok = ok, reason = reason })
	end)
	Client.onOpenRequested(function()
		opens += 1
	end)

	local ana = rbx.addPlayer("Ana")
	result:FireClient(ana, true, nil)
	check("a success reaches onResult", #results == 1 and results[1].ok == true)
	check("with no reason", results[1].reason == nil)

	result:FireClient(ana, false, "NotInGroup")
	check("a refusal reaches it too", #results == 2 and results[2].ok == false)
	check("carrying the reason key", results[2].reason == "NotInGroup")
	-- Keys, not sentences: the host maps them.
	check("which is a key the client exports", Client.Reasons[results[2].reason] ~= nil)

	check("the prompt did not fire onResult", opens == 0)
	open:FireClient(ana)
	check("and reaches onOpenRequested instead", opens == 1)
	check("without adding a result", #results == 2, #results)

	-- Each returns a connection, so a host can stop listening.
	local extra = 0
	local connection = Client.onResult(function()
		extra += 1
	end)
	result:FireClient(ana, true, nil)
	check("a second listener also fires", extra == 1)
	connection:Disconnect()
	result:FireClient(ana, true, nil)
	check("and stops once disconnected", extra == 1, extra)

	rbx.removePlayer(ana)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
