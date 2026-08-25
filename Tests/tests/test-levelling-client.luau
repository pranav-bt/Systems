-- The client half: mirroring the two attributes, coalescing them into one honest change, and
-- the four numbers a progress bar reads.
--
-- "It only reads attributes" is not "trivial". This module has to turn two separate
-- replications into one state change, work out a gain across a level boundary, and stay quiet
-- on the first sync -- and each of those is invisible until it is wrong.
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

-- Named before the module is loaded, though the shim resolves LocalPlayer live either way.
local ana = rbx.addPlayer("Ana")
rbx.setLocalPlayer(ana)

-- Provisioned exactly as the server half provisions it, because that is what the client looks
-- for by name.
local container = rbx.Instance.new("Folder")
container.Name = "LevellingRemotes"
local rate = rbx.Instance.new("RemoteEvent")
rate.Name = "Rate"
rate.Parent = container
container.Parent = rbx.ReplicatedStorage

local Client = require("./shim/library")("Levelling", "client")

-- One grant, as the server writes it: experience first, then level.
local function publish(level, experience)
	ana:SetAttribute("Experience", experience)
	ana:SetAttribute("Level", level)
end

--[[
	A returning level-40 player, published BEFORE start -- and start is deliberately NOT called
	yet.

	The first sync is the one moment worth watching here, and it happens inside `start`. A test
	that starts the module first can never observe it: by the time a listener exists the sync
	is done, and every assertion about it passes against a module that gets it completely
	wrong.
]]
publish(40, 25)

print("the first sync is a state, not forty level-ups")
do
	local seen = {}
	local stop = Client.onChanged(function(reading)
		table.insert(seen, reading)
	end)
	task.wait()

	-- onChanged pushes immediately, so a caller does not depend on having been started first.
	check("subscribing before start still pushes a reading", #seen == 1, #seen)
	check("at the starting level, since nothing has synced", seen[1] and seen[1].level == 1, seen[1] and seen[1].level)
	table.clear(seen)

	Client.start({})
	task.wait()

	-- Whatever was already published, without waiting for the next grant to move an attribute.
	check("starting picks up what was already there", #seen == 1, #seen)
	check("with the real level", seen[1] and seen[1].level == 40, seen[1] and seen[1].level)
	check("and the real experience", seen[1] and seen[1].experience == 25, seen[1] and seen[1].experience)
	-- Forty toasts and a "+150,000 XP" pop on join is the bug this guard exists for.
	check("but claiming no crossings", seen[1] and seen[1].crossed == 0, seen[1] and seen[1].crossed)
	check("and no gain", seen[1] and seen[1].gained == 0, seen[1] and seen[1].gained)

	stop()
	publish(5, 20)
	task.wait()
	check("an unsubscribed listener stops hearing", #seen == 1, #seen)
end

print("two attributes become ONE state change")
do
	local seen = {}
	local stop = Client.onChanged(function(reading)
		table.insert(seen, reading)
	end)
	task.wait()
	table.clear(seen)

	--[[
		A grant writes two attributes, so it lands as two changes: the new level beside the OLD
		experience, then the new experience. Applying each in turn shows a level-up with a stale
		bar followed by a NEGATIVE gain. Coalescing to one defer is what makes this one change.
	]]
	publish(6, 30)
	task.wait()
	check("one grant is one notification", #seen == 1, #seen)
	check("with both halves already agreeing", seen[1] and seen[1].level == 6 and seen[1].experience == 30, seen[1])

	stop()
end

print("the gain is counted across the level boundary")
do
	publish(1, 0)
	task.wait()

	local seen = {}
	local stop = Client.onChanged(function(reading)
		table.insert(seen, reading)
	end)
	task.wait()
	table.clear(seen)

	publish(1, 90)
	task.wait()
	check("within a level it is a subtraction", seen[1] and seen[1].gained == 90, seen[1] and seen[1].gained)

	-- 10 to finish level 1, then 30 into level 2. A subtraction would report -60 on the one
	-- grant worth celebrating.
	publish(2, 30)
	task.wait()
	check("across one it counts both parts", seen[2] and seen[2].gained == 40, seen[2] and seen[2].gained)
	check("and reports the crossing", seen[2] and seen[2].crossed == 1, seen[2] and seen[2].crossed)

	-- A rebirth, from the client's side: the level drops.
	publish(1, 0)
	task.wait()
	check("a reset is not a negative gain", seen[3] and seen[3].gained == 0, seen[3] and seen[3].gained)
	check("nor a crossing", seen[3] and seen[3].crossed == 0, seen[3] and seen[3].crossed)
	check("and the level follows the server down", Client.getLevel() == 1, Client.getLevel())

	stop()
end

print("the numbers a bar draws")
do
	publish(2, 35)
	task.wait()
	check("the level", Client.getLevel() == 2, Client.getLevel())
	check("the experience", Client.getExperience() == 35, Client.getExperience())
	check("what this level costs", Client.getRequired() == 175, Client.getRequired())
	check("and how far through it", math.abs(Client.getProgress() - 35 / 175) < 1e-9, Client.getProgress())

	check("the reward multiplier follows the level", math.abs(Client.getRewardMultiplier() - 1.05) < 1e-9, Client.getRewardMultiplier())

	--[[
		CLAMPED. The server's numbers are the numbers, and a client whose curve settings differ
		from the server's -- a game that retuned the curve and shipped one realm -- can be handed
		more experience than its own arithmetic says the level costs. A bar filled to 5.7 of 1
		draws straight out of its own frame.
	]]
	publish(2, 999)
	task.wait()
	check("more experience than the level costs still reads full", Client.getProgress() == 1, Client.getProgress())
end

print("at the cap the bar is full, not empty")
do
	Client.Curve.settings.maxLevel = 3
	publish(3, 0)
	task.wait()

	check("the cost is unreachable", Client.getRequired() == math.huge, Client.getRequired())
	-- Dividing by that huge would draw an EMPTY bar on the player who has earned the most,
	-- which is the wrong answer twice over.
	check("and the bar reads full", Client.getProgress() == 1, Client.getProgress())

	Client.Curve.settings.maxLevel = nil
	publish(1, 0)
	task.wait()
end

print("any player's level, straight off the attribute")
do
	local other = rbx.addPlayer("Ben")
	check("a player who has not published reads nil", Client.levelOf(other) == nil, Client.levelOf(other))

	other:SetAttribute("Level", 12)
	-- A list of twenty players draws twenty levels with no round trip and no roster push. nil
	-- and 1 are different facts, which is why the unpublished case above is not 1.
	check("and one who has reads their level", Client.levelOf(other) == 12, Client.levelOf(other))
	check("including the local player", Client.levelOf(ana) == 1, Client.levelOf(ana))

	rbx.removePlayer(other)
end

print("the tempo arrives on its own remote")
do
	local seen = {}
	local stop = Client.onRate(function(value)
		table.insert(seen, value)
	end)
	task.wait()
	check("subscribing pushes the current rate", #seen == 1 and seen[1] == 0, seen[1])

	rate:FireClient(ana, 25)
	task.wait()
	check("a rate lands", seen[2] == 25, seen[2])
	check("and is readable without a listener", Client.getRate() == 25, Client.getRate())

	rate:FireClient(ana, 0)
	task.wait()
	check("switching off lands too", seen[3] == 0, seen[3])

	-- A malformed rate must not become a NaN on a UI.
	rate:FireClient(ana, "fast")
	task.wait()
	check("nonsense reads as no rate", Client.getRate() == 0, Client.getRate())

	rate:FireClient(ana, -5)
	task.wait()
	check("and a negative one cannot go out backwards", Client.getRate() == 0, Client.getRate())

	stop()
	rate:FireClient(ana, 9)
	task.wait()
	check("an unsubscribed rate listener stops hearing", #seen == 5, #seen)
end

print("start is idempotent")
do
	local seen = {}
	local stop = Client.onChanged(function()
		table.insert(seen, true)
	end)
	task.wait()
	table.clear(seen)

	-- A second start must not double-connect the attribute signals; if it did, every grant
	-- from here on would notify twice.
	Client.start({})
	task.wait()
	publish(2, 10)
	task.wait()
	check("one change is still one notification", #seen == 1, #seen)

	stop()
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("levelling client tests failed", 0)
end
