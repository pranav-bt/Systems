-- Rebirth: the ladder's rules, and the door that performs the trade.
--
-- Driven against the REAL Levelling package rather than a stub, because the claim worth
-- checking is that the two compose -- that a rebirth actually changes what a later grant is
-- worth, through a multiplier this addon registered and the base applies.
local rbx = require("./shim/roblox")
local Ladder = require("./shim/library")("LevellingRebirth", "shared")
local Levelling = require("./shim/library")("Levelling", "server")
local Rebirth = require("./shim/library")("LevellingRebirth", "server")
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

local TIERS = {
	{ index = 1, requiredLevel = 10, multiplier = 2, title = "Awakening" },
	{ index = 2, requiredLevel = 20, multiplier = 3, title = "Kindling" },
	{ index = 3, requiredLevel = 30, multiplier = 4, title = "Ascension", rewards = { gold = 500 } },
}

print("a broken ladder fails loudly rather than shipping as bad balance")
do
	local function refuses(name, tiers, fragment)
		local ok, err = pcall(Ladder.validate, tiers)
		check(name, not ok and tostring(err):find(fragment) ~= nil, if ok then "it was accepted" else err)
	end

	refuses("a rung out of order with its index", {
		{ index = 2, requiredLevel = 10, multiplier = 2, title = "Wrong" },
	}, "index")

	refuses("a rung that costs no more than the one below", {
		{ index = 1, requiredLevel = 10, multiplier = 2, title = "A" },
		{ index = 2, requiredLevel = 10, multiplier = 3, title = "B" },
	}, "not more than")

	refuses("a rung that pays LESS than the one below", {
		{ index = 1, requiredLevel = 10, multiplier = 3, title = "A" },
		{ index = 2, requiredLevel = 20, multiplier = 2, title = "B" },
	}, "less than")

	refuses("a rung with no numbers on it", {
		{ index = 1, requiredLevel = "ten" :: any, multiplier = 2, title = "A" },
	}, "numeric")

	--[[
		A REPEATED multiplier is allowed where a decrease is not. A tier may pay in `rewards`
		instead and keep the rate flat; the game this came from required a strict increase
		because the multiplier was the only thing a rung could pay, and forbidding a flat rung
		would make the payload useless.
	]]
	local flat = {
		{ index = 1, requiredLevel = 10, multiplier = 2, title = "A" },
		{ index = 2, requiredLevel = 20, multiplier = 2, title = "B", rewards = { crown = true } },
	}
	check("but a rung that pays the same rate and adds rewards is fine", pcall(Ladder.validate, flat))

	check("an empty ladder is not an error", pcall(Ladder.validate, {}))
end

print("reading the ladder")
do
	Ladder.setTiers(TIERS)
	check("the count is the table", Ladder.count() == 3, Ladder.count())

	check("the first rung is next for a new player", Ladder.nextTier(0).title == "Awakening")
	check("and the second after one", Ladder.nextTier(1).title == "Kindling")
	check("nothing is next past the end", Ladder.nextTier(3) == nil)
	check("isMaxed says so", Ladder.isMaxed(3), false)
	check("and does not below it", not Ladder.isMaxed(2), true)

	check("a new player has taken no rung", Ladder.currentTier(0) == nil)
	check("and after one holds the first", Ladder.currentTier(1).title == "Awakening")

	check("the base rate before any rebirth", Ladder.multiplierFor(0) == 1, Ladder.multiplierFor(0))
	check("the rung TAKEN, not accumulated", Ladder.multiplierFor(2) == 3, Ladder.multiplierFor(2))

	-- A shortened ladder or a rollback: reading as x1 is the version of this bug a player
	-- writes in to complain about.
	check("more rebirths than rungs reads as the last one", Ladder.multiplierFor(99) == 4, Ladder.multiplierFor(99))

	check("availability needs the level", not Ladder.canRebirth(0, 9), true)
	check("and grants it at the level", Ladder.canRebirth(0, 10), false)
	check("past the top nothing is available", not Ladder.canRebirth(3, 999), true)

	check("levels remaining counts down", Ladder.levelsRemaining(0, 4) == 6, Ladder.levelsRemaining(0, 4))
	check("and is 0 once available", Ladder.levelsRemaining(0, 10) == 0, Ladder.levelsRemaining(0, 10))
	-- Clamped, not signed: a player well past the requirement is not "-5 levels away", and a
	-- window drawing the number verbatim would say exactly that.
	check("and stays 0 well past it", Ladder.levelsRemaining(0, 40) == 0, Ladder.levelsRemaining(0, 40))
	check("and huge at the top", Ladder.levelsRemaining(3, 999) == math.huge, Ladder.levelsRemaining(3, 999))

	-- Replaced rather than appended to, or two calls would leave one ladder stacked on another.
	Ladder.setTiers(TIERS)
	check("setting the ladder twice leaves one ladder", Ladder.count() == 3, Ladder.count())
end

-- ── The server half ───────────────────────────────────────────────────────────

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

Rebirth.start({
	levelling = Levelling,
	tiers = TIERS,
	read = function(player)
		local entry = profiles[player]
		return if entry then entry.rebirths else nil
	end,
	write = function(player, rebirths)
		local entry = profiles[player]
		if entry then
			entry.rebirths = rebirths
		end
	end,
})

local function newPlayer(name, level, rebirths)
	local player = rbx.addPlayer(name)
	profiles[player] = { level = level or 1, experience = 0, rebirths = rebirths or 0 }
	Levelling.publish(player)
	Rebirth.publish(player)
	return player
end

print("the trade")
do
	Rebirth.setGate(nil)
	local player = newPlayer("Ana", 10)

	check("it is available at the required level", Rebirth.canRebirth(player), false)

	local tier = Rebirth.rebirth(player)
	check("the rung taken is returned", tier ~= nil and tier.title == "Awakening", tier)
	check("the count went up", profiles[player].rebirths == 1, profiles[player].rebirths)
	check("the level went back to the start", profiles[player].level == 1, profiles[player].level)
	check("the experience was cleared", profiles[player].experience == 0, profiles[player].experience)
	check("and the count is published", player:GetAttribute("Rebirths") == 1, player:GetAttribute("Rebirths"))
	check("as is the reset level", player:GetAttribute("Level") == 1, player:GetAttribute("Level"))

	-- The state check IS the guard: a second call arrives at the starting level, which no rung
	-- accepts. A player hammering the button gets one rebirth and some table reads.
	check("a second call is refused", Rebirth.rebirth(player) == nil)
	check("leaving the count where it was", profiles[player].rebirths == 1, profiles[player].rebirths)

	rbx.removePlayer(player)
end

print("nothing else in the profile is touched")
do
	Rebirth.setGate(nil)
	local player = newPlayer("Ana", 10)
	-- Everything a game keeps beside the level. A rebirth is paid for with the LEVEL and
	-- nothing else, and this is the assertion that says so.
	profiles[player].gold = 4200
	profiles[player].pets = { "Drake" }
	profiles[player].bestDistance = 91

	Rebirth.rebirth(player)
	check("gold survives", profiles[player].gold == 4200, profiles[player].gold)
	check("collections survive", profiles[player].pets[1] == "Drake")
	check("and records survive", profiles[player].bestDistance == 91)

	rbx.removePlayer(player)
end

print("the ladder is asked, not the caller")
do
	Rebirth.setGate(nil)
	local tooLow = newPlayer("Low", 9)
	check("one level short is refused", Rebirth.rebirth(tooLow) == nil)
	check("and canRebirth agrees", not Rebirth.canRebirth(tooLow), true)
	check("with nothing written", profiles[tooLow].rebirths == 0, profiles[tooLow].rebirths)

	local maxed = newPlayer("Maxed", 999, 3)
	check("the top of the ladder is refused", Rebirth.rebirth(maxed) == nil)
	check("however high the level", profiles[maxed].rebirths == 3, profiles[maxed].rebirths)

	-- The second rung asks for 20, not 10: the requirement comes from the rung being taken.
	local second = newPlayer("Second", 15, 1)
	check("a later rung asks its own price", Rebirth.rebirth(second) == nil)
	profiles[second].level = 20
	check("and is taken at it", Rebirth.rebirth(second) ~= nil)
	check("landing on the second rung", profiles[second].rebirths == 2, profiles[second].rebirths)

	rbx.removePlayer(tooLow)
	rbx.removePlayer(maxed)
	rbx.removePlayer(second)
end

print("the host's gate refuses whatever this package cannot see")
do
	local player = newPlayer("Ana", 10)

	local asked = 0
	Rebirth.setGate(function()
		asked += 1
		return false
	end)
	check("a closed gate refuses", Rebirth.rebirth(player) == nil)
	check("and canRebirth reports it", not Rebirth.canRebirth(player), true)
	check("nothing was written", profiles[player].rebirths == 0, profiles[player].rebirths)
	check("and the level survives", profiles[player].level == 10, profiles[player].level)

	-- Asked FIRST, so a player hammering a button mid-run costs a function call and no
	-- profile work at all.
	check("the gate was consulted", asked >= 1, asked)

	-- Fails CLOSED. The trade is irreversible and the player can simply press again.
	Rebirth.setGate(function()
		error("the gate has a bug")
	end)
	check("a gate that throws refuses", Rebirth.rebirth(player) == nil)
	check("and still writes nothing", profiles[player].rebirths == 0, profiles[player].rebirths)

	Rebirth.setGate(function()
		return true
	end)
	check("an open gate lets it through", Rebirth.rebirth(player) ~= nil)

	Rebirth.setGate(nil)
	rbx.removePlayer(player)
end

print("the rebirth signal carries the rung, so rewards can be paid")
do
	Rebirth.setGate(nil)
	local player = newPlayer("Ana", 30, 2)

	local seen = {}
	local connection = Rebirth.rebirthed:connect(function(who, count, tier)
		table.insert(seen, { who = who, count = count, tier = tier })
	end)

	Rebirth.rebirth(player)
	task.wait()
	check("it fired once", #seen == 1, #seen)
	check("naming the player", seen[1] and seen[1].who == player)
	check("with the new count", seen[1] and seen[1].count == 3, seen[1] and seen[1].count)
	-- The tier is handed over because that is where `rewards` lives; looking the count back up
	-- and hoping it matches is the version of this that drifts.
	check("and the rung taken", seen[1] and seen[1].tier.title == "Ascension", seen[1] and seen[1].tier.title)
	check("carrying its payload", seen[1] and seen[1].tier.rewards.gold == 500, seen[1] and seen[1].tier.rewards)

	--[[
		Fired LAST. A subscriber reading the profile must find a trade that has fully landed --
		count, level and attribute all agreeing -- not one caught halfway.
	]]
	check("by which time the level is already reset", profiles[player].level == 1, profiles[player].level)
	check("and the attribute already published", player:GetAttribute("Rebirths") == 3, player:GetAttribute("Rebirths"))

	connection:disconnect()
	Rebirth.rebirth(player)
	task.wait()
	check("a disconnected listener stops hearing", #seen == 1, #seen)

	rbx.removePlayer(player)
end

print("a rebirth is worth something: the base actually pays more")
do
	Rebirth.setGate(nil)
	local player = newPlayer("Ana", 10)

	check("before it, a grant is unscaled", Levelling.grant(player, 50) == 50)

	Rebirth.rebirth(player)
	check("the first rung pays double", Levelling.grant(player, 50) == 100)
	check("which is what the stack now says", Levelling.multiplierFor(player) == 2, Levelling.multiplierFor(player))

	-- The rung TAKEN, not accumulated: rung two pays x3, not x2 times x3.
	profiles[player].level = 20
	Rebirth.rebirth(player)
	check("the second rung pays its own rate", Levelling.grant(player, 50) == 150)

	-- Composed with everything else in the stack, which is the whole reason the base holds a
	-- stack rather than one hardcoded rebirth multiplier.
	Levelling.addMultiplier("gamepass", function()
		return 2
	end)
	check("and composes with another multiplier", Levelling.grant(player, 50) == 300)
	Levelling.removeMultiplier("gamepass")

	rbx.removePlayer(player)
end

print("the tempo follows the new rate without anyone announcing it")
do
	Rebirth.setGate(nil)
	local player = newPlayer("Ana", 10)
	local rateRemote = rbx.ReplicatedStorage:FindFirstChild("LevellingRemotes"):FindFirstChild("Rate")
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

	Levelling.setRate(player, "zone", 10)
	check("the rate goes out unscaled at first", lastRate() == 10, lastRate())

	--[[
		The source holds a BASE rate, so the rebirth changes what goes out without the payer
		being told anything. Storing the scaled rate instead would leave a stale multiplier in
		the table until the zone next changed its mind -- which, for a player standing in it,
		is never.
	]]
	Rebirth.rebirth(player)
	check("and doubles the moment the rebirth lands", lastRate() == 20, lastRate())

	rbx.removePlayer(player)
end

print("the count is written BEFORE the level is reset")
do
	Rebirth.setGate(nil)
	local player = newPlayer("Ana", 10)

	--[[
		THE ORDER IS THE SAFETY PROPERTY. The base reads the count on every grant and every rate
		announcement, so between the two writes the player is briefly at their old level with
		the NEW multiplier -- overpaying for an instant. The other order leaves them at level 1
		with the OLD multiplier, and anything failing in between means they paid the price and
		got nothing.

		Observed through the stack itself: a probe multiplier records what the count reads as
		each time the base consults it, and the reset consults it synchronously.
	]]
	local seen = {}
	Levelling.addMultiplier("probe", function(who)
		table.insert(seen, Rebirth.get(who))
		return 1
	end)
	-- A non-zero rate, or the announcement inside the reset never asks the stack at all.
	Levelling.setRate(player, "zone", 10)
	table.clear(seen)

	Rebirth.rebirth(player)
	check("the stack was consulted during the trade", #seen >= 1, #seen)
	check("and already saw the new count", seen[1] == 1, seen[1])

	Levelling.removeMultiplier("probe")
	Levelling.setRate(player, "zone", 0)
	rbx.removePlayer(player)
end

print("the base is depended on by shape, not by path")
do
	Rebirth.setGate(nil)

	--[[
		A stand-in base with the four named functions and nothing else. Its `reset` deliberately
		does NOT announce a rate, which is what makes the refresh after the trade load-bearing:
		the real base happens to announce today, and nothing in the contract says it must.
	]]
	local refreshed = 0
	local stub = {
		get = function()
			return 50, 0
		end,
		reset = function() end,
		addMultiplier = function() end,
		refreshRate = function()
			refreshed += 1
		end,
	}

	local counts = {}
	Rebirth.start({
		levelling = stub :: any,
		tiers = TIERS,
		read = function(who)
			return counts[who] or 0
		end,
		write = function(who, value)
			counts[who] = value
		end,
	})

	local player = rbx.addPlayer("Stubbed")
	local tier = Rebirth.rebirth(player)
	check("the trade goes through against a stub", tier ~= nil and tier.title == "Awakening", tier)
	check("reading the level through the stub's own get", counts[player] == 1, counts[player])
	-- The line a base that stays quiet on reset depends on.
	check("and the tempo is refreshed even though reset stayed quiet", refreshed >= 1, refreshed)

	rbx.removePlayer(player)

	--[[
		Re-pointing at a different base has to re-register the multiplier with it. Registration
		by name means this cannot double up, and skipping it would leave the new base with no
		rebirth multiplier at all -- every rebirth in the game silently worth x1.
	]]
	local reRegistered = false
	local watcher = {
		get = function()
			return 1, 0
		end,
		reset = function() end,
		addMultiplier = function()
			reRegistered = true
		end,
		refreshRate = function() end,
	}
	Rebirth.start({ levelling = watcher :: any, tiers = TIERS })
	check("re-pointing at another base registers with it", reRegistered, false)

	-- Put the real base back for anything after this.
	Rebirth.start({
		levelling = Levelling,
		tiers = TIERS,
		read = function(who)
			local entry = profiles[who]
			return if entry then entry.rebirths else nil
		end,
		write = function(who, value)
			local entry = profiles[who]
			if entry then
				entry.rebirths = value
			end
		end,
	})
end

print("the request remote carries nothing")
do
	Rebirth.setGate(nil)
	local remote = rbx.ReplicatedStorage:FindFirstChild("LevellingRemotes"):FindFirstChild("RequestRebirth")
	check("it was provisioned", remote ~= nil)
	check("beside the base's own remote", rbx.ReplicatedStorage:FindFirstChild("LevellingRemotes"):FindFirstChild("Rate") ~= nil)

	local player = newPlayer("Ana", 10)
	remote:FireServer(player)
	check("firing it takes the rebirth", profiles[player].rebirths == 1, profiles[player].rebirths)

	--[[
		A FORGED CALL IS INDISTINGUISHABLE FROM A REAL ONE and does exactly the same thing:
		the rung is the one after the count in the player's own profile, so there is no
		argument that could be wrong.
	]]
	profiles[player].level = 20
	remote:FireServer(player, 3, 999, "Ascension")
	check("extra arguments change nothing", profiles[player].rebirths == 2, profiles[player].rebirths)

	-- Still the second rung, not the third the crafted call named.
	check("and cannot skip a rung", Ladder.currentTier(profiles[player].rebirths).title == "Kindling")

	rbx.removePlayer(player)
end

print("a profile that cannot be read refuses rather than throwing")
do
	Rebirth.setGate(nil)
	local ghost = rbx.addPlayer("Ghost") -- no profile at all
	check("the count reads as none", Rebirth.get(ghost) == 0, Rebirth.get(ghost))
	check("and a rebirth is refused", Rebirth.rebirth(ghost) == nil)

	local player = newPlayer("Ana", 10)
	profiles[player].rebirths = -3
	check("a negative stored count reads as none", Rebirth.get(player) == 0, Rebirth.get(player))

	rbx.removePlayer(ghost)
	rbx.removePlayer(player)
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("rebirth tests failed", 0)
end
