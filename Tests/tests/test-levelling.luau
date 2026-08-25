-- The server door: the single grant, the multiplier stack, what gets published, and the
-- tempo announcements.
local rbx = require("./shim/roblox")
local Levelling = require("./shim/library")("Levelling", "server")
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

-- The host's profile store, standing in for whatever a game actually uses. A player with no
-- entry here is one whose profile has not loaded -- the case `grant` has to drop.
local profiles = {}

Levelling.start({
	read = function(player)
		local entry = profiles[player]
		if not entry then
			return nil, nil
		end
		return entry.level, entry.experience
	end,
	write = function(player, level, experience)
		local entry = profiles[player]
		if entry then
			entry.level = level
			entry.experience = experience
		end
	end,
})

local function newPlayer(name, level, experience)
	local player = rbx.addPlayer(name)
	profiles[player] = { level = level or 1, experience = experience or 0 }
	Levelling.publish(player)
	return player
end

local function clearMultipliers()
	for _, name in { "gamepass", "event", "broken", "zero", "rebirth" } do
		Levelling.removeMultiplier(name)
	end
end

-- The rate remote the module provisioned, so a test can read what actually went on the wire.
local rateRemote = rbx.ReplicatedStorage:FindFirstChild("LevellingRemotes"):FindFirstChild("Rate")

print("start provisions its own transport")
do
	local container = rbx.ReplicatedStorage:FindFirstChild("LevellingRemotes")
	check("the container exists", container ~= nil)
	check("with a Rate remote in it", rateRemote ~= nil)
	check("which is a RemoteEvent", rateRemote.ClassName == "RemoteEvent", rateRemote.ClassName)

	-- Idempotent: a host that starts twice must not end up with two containers or two
	-- OnServerEvent handlers.
	Levelling.start({})
	local again = rbx.ReplicatedStorage:FindFirstChild("LevellingRemotes")
	check("starting again reuses the container", again == container)
	check("and the same remote", again:FindFirstChild("Rate") == rateRemote)
end

print("a grant adds XP and publishes it")
do
	clearMultipliers()
	local player = newPlayer("Ana")

	local granted, crossed = Levelling.grant(player, 40)
	check("it reports what it granted", granted == 40, granted)
	check("and that nothing was crossed", crossed == 0, crossed)
	check("the profile holds the experience", profiles[player].experience == 40, profiles[player].experience)
	check("the attribute mirrors it", player:GetAttribute("Experience") == 40, player:GetAttribute("Experience"))
	check("and the level is unchanged", player:GetAttribute("Level") == 1, player:GetAttribute("Level"))

	rbx.removePlayer(player)
end

print("a grant that crosses a level says so, once, with a count")
do
	clearMultipliers()
	local player = newPlayer("Ana")

	local ups = {}
	local connection = Levelling.levelUp:connect(function(who, level, count)
		table.insert(ups, { who = who, level = level, count = count })
	end)

	Levelling.grant(player, 40)
	task.wait()
	check("a grant below the rung says nothing", #ups == 0, #ups)

	-- 100 + 175 + 300 = 575 buys three levels from the bottom, and 40 is already banked.
	local _, crossed = Levelling.grant(player, 535)
	task.wait()
	check("crossing three fires ONCE", #ups == 1, #ups)
	check("naming the player", ups[1] and ups[1].who == player)
	check("the level they landed on", ups[1] and ups[1].level == 4, ups[1] and ups[1].level)
	-- The count is what a host paying a reward per level needs; a flag would owe one.
	check("and how many rungs it covered", ups[1] and ups[1].count == 3, ups[1] and ups[1].count)
	check("grant returns the same count", crossed == 3, crossed)

	connection:disconnect()
	Levelling.grant(player, 5000)
	task.wait()
	check("a disconnected listener stops hearing", #ups == 1, #ups)

	rbx.removePlayer(player)
end

print("experience is published BEFORE the level")
do
	clearMultipliers()
	local player = newPlayer("Ana")

	--[[
		The level attribute is what a client watches to know something happened, so a reader
		woken by it must not find the experience still stale. Reading the other attribute from
		inside this handler is the only way to observe the order.
	]]
	local experienceSeen = nil
	player:GetAttributeChangedSignal("Level"):Connect(function()
		experienceSeen = player:GetAttribute("Experience")
	end)

	Levelling.grant(player, 130) -- crosses to level 2 with 30 left
	check("the level moved", player:GetAttribute("Level") == 2, player:GetAttribute("Level"))
	check("and the experience was already correct when it did", experienceSeen == 30, experienceSeen)

	rbx.removePlayer(player)
end

print("a grant with nowhere to go is dropped, not written")
do
	clearMultipliers()
	local ghost = rbx.addPlayer("Ghost") -- deliberately no profile

	local granted, crossed = Levelling.grant(ghost, 500)
	check("nothing is granted without a profile", granted == 0 and crossed == 0, `{granted}/{crossed}`)
	check("and no attribute is invented", ghost:GetAttribute("Level") == nil, ghost:GetAttribute("Level"))

	local player = newPlayer("Ana")
	check("a zero grant does nothing", Levelling.grant(player, 0) == 0)
	check("a negative grant does nothing", Levelling.grant(player, -500) == 0)
	check("and does not take experience away", profiles[player].experience == 0, profiles[player].experience)
	check("NaN does nothing", Levelling.grant(player, 0 / 0) == 0)
	check("a non-number does nothing", Levelling.grant(player, "500" :: any) == 0)

	rbx.removePlayer(ghost)
	rbx.removePlayer(player)
end

print("the multiplier stack composes by product")
do
	clearMultipliers()
	local player = newPlayer("Ana")

	check("nothing registered is x1", Levelling.multiplierFor(player) == 1, Levelling.multiplierFor(player))

	Levelling.addMultiplier("gamepass", function()
		return 2
	end)
	check("one multiplier applies", Levelling.multiplierFor(player) == 2, Levelling.multiplierFor(player))

	Levelling.addMultiplier("event", function()
		return 3
	end)
	-- Product, not sum: two things that each say "double" have to compound, or the second one
	-- is worth less than the first and the shop looks broken.
	check("two multiply rather than add", Levelling.multiplierFor(player) == 6, Levelling.multiplierFor(player))

	local granted = Levelling.grant(player, 10)
	check("a grant is scaled by the stack", granted == 60, granted)
	check("and the profile holds the scaled number", profiles[player].experience == 60, profiles[player].experience)

	Levelling.removeMultiplier("event")
	check("removing one drops it from the product", Levelling.multiplierFor(player) == 2, Levelling.multiplierFor(player))

	-- Re-registering a name REPLACES, so a hot reload cannot square the bonus.
	Levelling.addMultiplier("gamepass", function()
		return 5
	end)
	check("re-registering a name replaces it", Levelling.multiplierFor(player) == 5, Levelling.multiplierFor(player))

	clearMultipliers()
	check("removing them all is back to x1", Levelling.multiplierFor(player) == 1, Levelling.multiplierFor(player))
	check("removing one that was never there is harmless", (function()
		Levelling.removeMultiplier("never")
		return true
	end)())

	rbx.removePlayer(player)
end

print("a multiplier is per player, not global")
do
	clearMultipliers()
	local rich = newPlayer("Rich")
	local poor = newPlayer("Poor")

	Levelling.addMultiplier("gamepass", function(who)
		return if who == rich then 4 else 1
	end)

	check("the one who owns it is scaled", Levelling.grant(rich, 10) == 40, profiles[rich].experience)
	check("and the one who does not is not", Levelling.grant(poor, 10) == 10, profiles[poor].experience)

	clearMultipliers()
	rbx.removePlayer(rich)
	rbx.removePlayer(poor)
end

print("a broken multiplier cannot stop a grant")
do
	clearMultipliers()
	local player = newPlayer("Ana")

	Levelling.addMultiplier("broken", function()
		error("this registrant has a bug")
	end)
	Levelling.addMultiplier("gamepass", function()
		return 2
	end)

	-- Paying unscaled is a much smaller problem than paying nothing, so a thrown registrant
	-- contributes 1 and the rest of the stack still applies.
	local granted = Levelling.grant(player, 10)
	check("the grant still lands", granted == 20, granted)

	-- Zero would silently switch off every XP source in the game, and there is no way to tell
	-- that from a registrant with a bug.
	Levelling.addMultiplier("zero", function()
		return 0
	end)
	check("a zero multiplier counts as 1", Levelling.grant(player, 10) == 20, Levelling.grant(player, 10))

	Levelling.addMultiplier("zero", function()
		return "lots" :: any
	end)
	check("so does a non-number", Levelling.grant(player, 10) == 20)

	clearMultipliers()
	rbx.removePlayer(player)
end

print("set assigns without paying a level-up")
do
	clearMultipliers()
	local player = newPlayer("Ana")

	local ups, changes = 0, 0
	local upConnection = Levelling.levelUp:connect(function()
		ups += 1
	end)
	local changeConnection = Levelling.changed:connect(function()
		changes += 1
	end)

	Levelling.set(player, 12, 40)
	task.wait()
	check("the level is assigned", profiles[player].level == 12, profiles[player].level)
	check("and the experience with it", profiles[player].experience == 40, profiles[player].experience)
	check("the attributes follow", player:GetAttribute("Level") == 12, player:GetAttribute("Level"))
	-- An assigned level is not a reached one: a host paying per level must not pay out for an
	-- admin fixing a profile.
	check("no level-up is claimed", ups == 0, ups)
	check("but it still counts as a change", changes == 1, changes)

	Levelling.addMultiplier("gamepass", function()
		return 10
	end)
	Levelling.set(player, 3)
	check("set ignores the multiplier stack", profiles[player].level == 3, profiles[player].level)
	check("and clears experience when none is given", profiles[player].experience == 0, profiles[player].experience)

	Levelling.set(player, -50)
	check("it cannot go below the starting level", profiles[player].level == 1, profiles[player].level)

	upConnection:disconnect()
	changeConnection:disconnect()
	clearMultipliers()
	rbx.removePlayer(player)
end

print("reset is set(startLevel, 0)")
do
	clearMultipliers()
	local player = newPlayer("Ana", 30, 900)

	local ups = 0
	local connection = Levelling.levelUp:connect(function()
		ups += 1
	end)

	Levelling.reset(player)
	task.wait()
	check("the level goes back to the start", profiles[player].level == 1, profiles[player].level)
	check("and the experience is cleared", profiles[player].experience == 0, profiles[player].experience)
	check("the attributes follow it down", player:GetAttribute("Level") == 1, player:GetAttribute("Level"))
	check("and no level-up is claimed on the way", ups == 0, ups)

	connection:disconnect()
	rbx.removePlayer(player)
end

print("changed reports the gain, level-up or not")
do
	clearMultipliers()
	local player = newPlayer("Ana")
	local seen = {}
	local connection = Levelling.changed:connect(function(_, level, experience, gained)
		table.insert(seen, { level = level, experience = experience, gained = gained })
	end)

	Levelling.grant(player, 40)
	task.wait()
	check("an ordinary grant reports", #seen == 1, #seen)
	check("with the gain in it", seen[1] and seen[1].gained == 40, seen[1] and seen[1].gained)

	Levelling.addMultiplier("gamepass", function()
		return 2
	end)
	Levelling.grant(player, 10)
	task.wait()
	-- The SCALED number, because that is what the player actually earned and what a "+20 XP"
	-- pop has to say.
	check("the gain is the scaled amount", seen[2] and seen[2].gained == 20, seen[2] and seen[2].gained)

	connection:disconnect()
	clearMultipliers()
	rbx.removePlayer(player)
end

print("the tempo is summed by source and sent on change only")
do
	clearMultipliers()
	local player = newPlayer("Ana")
	rateRemote._sent = {}

	local function sentCount()
		local count = 0
		for _, entry in rateRemote._sent do
			if entry.player == player then
				count += 1
			end
		end
		return count
	end
	local function lastRate()
		local last = nil
		for _, entry in rateRemote._sent do
			if entry.player == player then
				last = entry.args[1]
			end
		end
		return last
	end

	Levelling.setRate(player, "zone", 5)
	check("a rate goes out", sentCount() == 1, sentCount())
	check("as the number given", lastRate() == 5, lastRate())

	-- Two independent owners; neither should have to know the other exists.
	Levelling.setRate(player, "run", 3)
	check("a second source sums", lastRate() == 8, lastRate())

	Levelling.setRate(player, "zone", 5)
	check("re-announcing the same rate costs no message", sentCount() == 2, sentCount())

	Levelling.setRate(player, "zone", 0)
	check("switching a source off leaves the other", lastRate() == 3, lastRate())

	Levelling.setRate(player, "run", 0)
	check("switching the last one off announces zero", lastRate() == 0, lastRate())

	local before = sentCount()
	Levelling.setRate(player, "run", 0)
	Levelling.setRate(player, "never", 0)
	-- The line that makes a caller's own clean-up idempotent: every payer announces 0 on its
	-- way out, including ones that never announced anything.
	check("switching off what is already off says nothing", sentCount() == before, sentCount())

	rbx.removePlayer(player)
end

print("the tempo is scaled by the same stack as the amount")
do
	clearMultipliers()
	local player = newPlayer("Ana")
	rateRemote._sent = {}
	local function lastRate()
		local last = nil
		for _, entry in rateRemote._sent do
			if entry.player == player then
				last = entry.args[1]
			end
		end
		return last
	end

	Levelling.addMultiplier("gamepass", function()
		return 3
	end)
	Levelling.setRate(player, "zone", 5)
	check("the rate goes out pre-multiplied", lastRate() == 15, lastRate())
	check("and getRate agrees", Levelling.getRate(player) == 15, Levelling.getRate(player))

	--[[
		The sources hold BASE rates, so a multiplier arriving later re-announces to a different
		number. Storing the scaled rate instead would leave a stale multiplier in the table
		until the payer next changed its own mind -- which, for a player standing in a zone, is
		never.
	]]
	Levelling.addMultiplier("event", function()
		return 2
	end)
	Levelling.refreshRate(player)
	check("a new multiplier re-announces", lastRate() == 30, lastRate())

	clearMultipliers()
	Levelling.refreshRate(player)
	check("and losing one re-announces down", lastRate() == 5, lastRate())

	rbx.removePlayer(player)
end

print("a player who leaves takes their rate with them")
do
	clearMultipliers()
	local player = newPlayer("Ana")
	Levelling.setRate(player, "zone", 5)
	check("the rate is held", Levelling.getRate(player) == 5, Levelling.getRate(player))

	rbx.removePlayer(player)
	task.wait()
	check("and dropped when they leave", Levelling.getRate(player) == 0, Levelling.getRate(player))

	--[[
		THE PER-SOURCE TABLE HAS TO GO TOO, not just the last-sent total. Clearing only the
		total leaves the old source sitting in the sum, so the next rate this player is paid --
		after a rejoin, on a recycled table -- comes out too high by however much they were
		earning when they left. Reading getRate alone cannot see that; announcing a DIFFERENT
		source can.
	]]
	Levelling.setRate(player, "run", 2)
	check("and a later rate does not sum with the stale one", Levelling.getRate(player) == 2, Levelling.getRate(player))
	Levelling.setRate(player, "run", 0)
end

print("a capped player earns nothing and the overflow is announced")
do
	clearMultipliers()
	Levelling.Curve.settings.maxLevel = 3
	local player = newPlayer("Ana")

	local wasted = {}
	local connection = Levelling.overflowed:connect(function(_, amount)
		table.insert(wasted, amount)
	end)

	-- 275 reaches the cap; the rest has nowhere to go.
	Levelling.grant(player, 1000)
	task.wait()
	check("the level stops at the cap", profiles[player].level == 3, profiles[player].level)
	check("with no experience left filling a bar", profiles[player].experience == 0, profiles[player].experience)
	check("and the overflow is announced", wasted[1] == 725, wasted[1])

	-- A player already at the cap: the grant is refused outright rather than written.
	local granted = Levelling.grant(player, 500)
	task.wait()
	check("a further grant pays nothing", granted == 0, granted)
	check("and is announced as wasted in full", wasted[2] == 500, wasted[2])

	Levelling.addMultiplier("gamepass", function()
		return 2
	end)
	Levelling.grant(player, 100)
	task.wait()
	-- The scaled number, because that is what the player would have earned -- a host
	-- converting overflow into currency has to convert what was actually lost.
	check("the wasted amount is scaled too", wasted[3] == 200, wasted[3])

	connection:disconnect()
	clearMultipliers()
	Levelling.Curve.settings.maxLevel = nil
	rbx.removePlayer(player)
end

print("get and publish default a profile that has never been written")
do
	clearMultipliers()
	local player = rbx.addPlayer("Ana")
	profiles[player] = {} -- loaded, but with neither field set

	local level, experience = Levelling.get(player)
	check("the level defaults to the start", level == 1, level)
	check("and the experience to none", experience == 0, experience)

	Levelling.publish(player)
	check("publish writes both attributes", player:GetAttribute("Level") == 1, player:GetAttribute("Level"))
	check("including experience", player:GetAttribute("Experience") == 0, player:GetAttribute("Experience"))

	-- A corrupt profile must not become a corrupt attribute.
	profiles[player] = { level = -4, experience = -900 }
	level, experience = Levelling.get(player)
	check("a negative stored level reads as the start", level == 1, level)
	check("and negative experience as none", experience == 0, experience)

	check("getLevel is the level alone", Levelling.getLevel(player) == 1, Levelling.getLevel(player))

	rbx.removePlayer(player)
end

print("a read that throws is survived")
do
	clearMultipliers()
	local player = rbx.addPlayer("Ana")
	profiles[player] = setmetatable({}, {
		__index = function()
			error("the profile store is having a bad day")
		end,
	})

	local level = Levelling.get(player)
	check("get falls back to the starting level", level == 1, level)
	check("and a grant is dropped rather than thrown", Levelling.grant(player, 100) == 0)

	profiles[player] = nil
	rbx.removePlayer(player)
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("levelling server tests failed", 0)
end
