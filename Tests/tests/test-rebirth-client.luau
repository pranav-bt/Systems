-- The Rebirth client half: the state a window draws, and when it is told to redraw.
--
-- Driven against the REAL Levelling client, because the claim worth checking is that the
-- button lights up when the player LEVELS -- not only when they rebirth. A window subscribed
-- to the count alone stays greyed out at exactly the moment it matters.
local rbx = require("./shim/roblox")
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

local ana = rbx.addPlayer("Ana")
rbx.setLocalPlayer(ana)

-- Provisioned exactly as the two server halves provision it.
local container = rbx.Instance.new("Folder")
container.Name = "LevellingRemotes"
local rateRemote = rbx.Instance.new("RemoteEvent")
rateRemote.Name = "Rate"
rateRemote.Parent = container
local requestRemote = rbx.Instance.new("RemoteEvent")
requestRemote.Name = "RequestRebirth"
requestRemote.Parent = container
container.Parent = rbx.ReplicatedStorage

local Levelling = require("./shim/library")("Levelling", "client")
local Rebirth = require("./shim/library")("LevellingRebirth", "client")

local TIERS = {
	{ index = 1, requiredLevel = 10, multiplier = 2, title = "Awakening" },
	{ index = 2, requiredLevel = 20, multiplier = 3, title = "Kindling" },
}

local function publish(level, experience, rebirths)
	ana:SetAttribute("Experience", experience or 0)
	ana:SetAttribute("Level", level)
	if rebirths ~= nil then
		ana:SetAttribute("Rebirths", rebirths)
	end
end

publish(1, 0, 0)
Levelling.start({})
Rebirth.start({ levelling = Levelling, tiers = TIERS })
task.wait()

print("the state a window draws")
do
	local state = Rebirth.getState()
	check("the count", state.rebirths == 0, state.rebirths)
	check("the level", state.level == 1, state.level)
	check("the rung they would take", state.nextTier.title == "Awakening")
	check("no rung taken yet", state.currentTier == nil)
	check("the rate they earn at", state.multiplier == 1, state.multiplier)
	check("how far off they are", state.levelsRemaining == 9, state.levelsRemaining)
	check("and that the button is dead", not state.available, true)
end

print("levelling is what lights the button up")
do
	local seen = {}
	local stop = Rebirth.onChanged(function(state)
		table.insert(seen, state)
	end)
	task.wait()
	check("subscribing pushes the current state", #seen == 1, #seen)
	table.clear(seen)

	--[[
		THE SUBSCRIPTION THAT ACTUALLY MATTERS. A rebirth becomes available by LEVELLING far
		more often than by rebirthing, so a window listening only to the count would stay grey
		at precisely the moment the player finally qualifies.
	]]
	publish(9, 0)
	task.wait()
	check("a level change redraws", #seen >= 1, #seen)
	check("still one short", seen[#seen] and not seen[#seen].available, true)
	check("and says how short", seen[#seen] and seen[#seen].levelsRemaining == 1, seen[#seen] and seen[#seen].levelsRemaining)

	publish(10, 0)
	task.wait()
	check("reaching the level makes it available", seen[#seen] and seen[#seen].available, false)
	check("with nothing left to wait for", seen[#seen] and seen[#seen].levelsRemaining == 0, seen[#seen] and seen[#seen].levelsRemaining)

	stop()
	publish(15, 0)
	task.wait()
	local before = #seen
	publish(16, 0)
	task.wait()
	check("an unsubscribed listener stops hearing", #seen == before, #seen)
end

print("a rebirth landing moves the state")
do
	local seen = {}
	local stop = Rebirth.onChanged(function(state)
		table.insert(seen, state)
	end)
	task.wait()
	table.clear(seen)

	-- What the server writes: the level goes back down and the count goes up.
	publish(1, 0, 1)
	task.wait()

	local state = Rebirth.getState()
	check("the count followed", state.rebirths == 1, state.rebirths)
	check("the rung taken is the first", state.currentTier.title == "Awakening")
	check("the next is the second", state.nextTier.title == "Kindling")
	check("the rate is the rung taken", state.multiplier == 2, state.multiplier)
	check("and the button is dead again", not state.available, true)
	check("listeners were told", #seen >= 1, #seen)

	stop()
end

print("the count changing on its OWN redraws")
do
	publish(15, 0, 0)
	task.wait()
	local seen = {}
	local stop = Rebirth.onChanged(function(state)
		table.insert(seen, state)
	end)
	task.wait()
	table.clear(seen)

	-- Only the rebirth count moves. Every other block here changes the level too, which the
	-- levelling subscription would redraw for -- so this is the one that proves the ATTRIBUTE
	-- subscription notifies rather than only updating a private field.
	ana:SetAttribute("Rebirths", 1)
	task.wait()
	check("a count change alone notifies", #seen == 1, #seen)
	check("with the new count in it", seen[1] and seen[1].rebirths == 1, seen[1] and seen[1].rebirths)

	stop()
end

print("the top of the ladder is a state, not an error")
do
	publish(999, 0, 2)
	task.wait()

	local state = Rebirth.getState()
	check("nothing is next", state.nextTier == nil)
	check("the last rung is held", state.currentTier.title == "Kindling")
	check("it is not available at any level", not state.available, true)
	-- There is no number of levels that would unlock a rung that does not exist.
	check("and no number of levels would help", state.levelsRemaining == math.huge, state.levelsRemaining)
end

print("any player's count, straight off the attribute")
do
	local other = rbx.addPlayer("Ben")
	check("one who has not published reads nil", Rebirth.countOf(other) == nil, Rebirth.countOf(other))

	other:SetAttribute("Rebirths", 7)
	-- nil and 0 are different facts: a leaderboard should draw blank for the first, not zero.
	check("and one who has reads their count", Rebirth.countOf(other) == 7, Rebirth.countOf(other))
	check("including the local player", Rebirth.countOf(ana) == 2, Rebirth.countOf(ana))

	rbx.removePlayer(other)
end

print("the request carries nothing")
do
	requestRemote._fired = {}
	Rebirth.request()
	check("it reached the server", #requestRemote:firedToServer() == 1, #requestRemote:firedToServer())
	-- No tier index, no level, no multiplier: there is no argument that could be wrong.
	check("with no arguments at all", #requestRemote:firedToServer()[1] == 0, #requestRemote:firedToServer()[1])
end

print("start is idempotent")
do
	publish(10, 0, 0)
	task.wait()
	local seen = {}
	local stop = Rebirth.onChanged(function()
		table.insert(seen, true)
	end)
	task.wait()
	table.clear(seen)

	--[[
		A second start must not double-connect the attribute signal or the level subscription.

		Only the LEVEL is republished. Re-writing the rebirth count as the same 0 would fire
		the shim's attribute signal a second time -- the shim does not dedupe a write of an
		unchanged value -- and count as a second redraw for a reason that has nothing to do
		with double-connecting.
	]]
	Rebirth.start({ levelling = Levelling, tiers = TIERS })
	task.wait()
	publish(11, 0)
	task.wait()
	check("one level change is still one redraw", #seen == 1, #seen)

	stop()
end

print("a ladder is required, and a base package with it")
do
	check("no options at all is refused", not pcall(Rebirth.start, nil :: any))
	check("no base package is refused", not pcall(Rebirth.start, { tiers = TIERS } :: any))
	check("no ladder is refused", not pcall(Rebirth.start, { levelling = Levelling } :: any))
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("rebirth client tests failed", 0)
end
