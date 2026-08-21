-- CommunityReward's claim flow. This is the part worth testing: it decides whether
-- a player gets paid, whether they can get paid twice, and what happens when the
-- membership lookup fails halfway through.
--
-- All of it is reachable headlessly because the membership check is an injected
-- seam. The prompt binding is NOT covered -- it is Instance wiring with no
-- decisions in it, and faking a streamed-in Model to prove a ProximityPrompt got
-- parented would test the shim rather than the library.
local rbx = require("./shim/roblox")
local CommunityReward = require("./shim/library")("CommunityReward", "server")
local task = require("@lune/task")

local V = rbx.Vector3.new

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

-- One player, one profile table, and a recorder for everything the host side saw.
local function scenario(overrides)
	rbx.reset()
	local player = rbx.addPlayer("Ana", V(0, 0, 0))
	local profile = {}
	local log = { grants = 0, claimed = 0, checks = 0 }

	local settings = {
		groupId = 1234,
		document = function()
			return profile
		end,
		grant = function()
			log.grants += 1
			-- Read the flag from inside the grant: the ordering guarantee is that this
			-- is already true, and asserting it here is the only place it is visible.
			log.flagAtGrantTime = profile.communityRewardClaimed
		end,
		onClaimed = function()
			log.claimed += 1
		end,
		isInGroup = function()
			log.checks += 1
			return true
		end,
	}
	for key, value in overrides or {} do
		settings[key] = value
	end
	CommunityReward.configure(settings)
	return player, profile, log, settings
end

print("the happy path")
do
	local player, profile, log = scenario()
	local result = CommunityReward.claim(player)
	check("it succeeds", result.ok, result.reason)
	check("with no reason", result.reason == nil, result.reason)
	check("the flag is written", profile.communityRewardClaimed == true)
	check("the reward was granted once", log.grants == 1, log.grants)
	check("membership was checked once", log.checks == 1, log.checks)
	check("onClaimed ran", log.claimed == 1, log.claimed)
	-- The whole reason the order is what it is.
	check("the flag was ALREADY set when grant ran", log.flagAtGrantTime == true, log.flagAtGrantTime)
end

print("a second claim pays nothing")
do
	local player, profile, log = scenario()
	CommunityReward.claim(player)
	local second = CommunityReward.claim(player)
	check("it is refused", not second.ok)
	check("as AlreadyClaimed", second.reason == "AlreadyClaimed", second.reason)
	check("and granted nothing further", log.grants == 1, log.grants)
	check("the flag is untouched", profile.communityRewardClaimed == true)
end

print("every refusal leaves the claim still there to be made")
do
	-- Not a member: refused, and crucially NOT flagged.
	local player, profile, log = scenario({
		isInGroup = function()
			return false
		end,
	})
	local result = CommunityReward.claim(player)
	check("not in the group is refused", result.reason == "NotInGroup", result.reason)
	check("the flag stays unset", profile.communityRewardClaimed == nil)
	check("nothing was granted", log.grants == 0, log.grants)

	-- Lookup failure is a THIRD answer, not a no: telling a member they are not one
	-- is the outcome this must never produce.
	local p2, prof2 = scenario({
		isInGroup = function()
			return nil
		end,
	})
	local failedLookup = CommunityReward.claim(p2)
	check("a failed lookup is retryable, not a refusal", failedLookup.reason == "Failed", failedLookup.reason)
	check("and leaves the flag unset", prof2.communityRewardClaimed == nil)

	-- A checker that throws must behave like a failed lookup, not poison the guard.
	local p3, prof3 = scenario({
		isInGroup = function()
			error("network is on fire")
		end,
	})
	local threw = CommunityReward.claim(p3)
	check("a throwing checker becomes Failed", threw.reason == "Failed", threw.reason)
	check("the flag stays unset", prof3.communityRewardClaimed == nil)
	-- The guard must have been released, or the player could never claim again.
	local retry = CommunityReward.claim(p3)
	check("and the guard was released, so a retry is possible", retry.reason == "Failed", retry.reason)

	-- groupId unset disables the feature rather than rewarding everybody.
	local p4, prof4, log4 = scenario({ groupId = 0 })
	local unset = CommunityReward.claim(p4)
	check("groupId 0 refuses as Unavailable", unset.reason == "Unavailable", unset.reason)
	check("without even checking membership", log4.checks == 0, log4.checks)
	check("and without flagging", prof4.communityRewardClaimed == nil)

	-- No profile yet.
	local p5 = scenario({
		document = function()
			return nil
		end,
	})
	check("an unloaded profile is NotReady", CommunityReward.claim(p5).reason == "NotReady")
end

print("a misconfigured reward costs a refusal, not a paid-for-nothing player")
do
	local player, profile, log = scenario({
		rewardReady = function()
			return false
		end,
	})
	local result = CommunityReward.claim(player)
	check("an unready reward is Unavailable", result.reason == "Unavailable", result.reason)
	check("checked BEFORE the membership call", log.checks == 0, log.checks)
	check("and before the flag, so the claim survives", profile.communityRewardClaimed == nil)

	-- A throwing readiness check must fail closed the same way.
	local p2, prof2 = scenario({
		rewardReady = function()
			error("content table is missing")
		end,
	})
	check("a throwing rewardReady is Unavailable", CommunityReward.claim(p2).reason == "Unavailable")
	check("and still leaves the claim available", prof2.communityRewardClaimed == nil)

	-- Once ready, the same config pays.
	local p3, prof3 = scenario({
		rewardReady = function()
			return true
		end,
	})
	check("a ready reward pays", CommunityReward.claim(p3).ok)
	check("and flags", prof3.communityRewardClaimed == true)
end

print("the yielding lookup: what can change underneath a claim")
do
	-- The profile is re-read after the yield, because the player may have left and
	-- the table the claim started with need not still exist.
	local vanish = nil
	local player, profile, log = scenario({
		isInGroup = function()
			vanish = true
			return true
		end,
	})
	local settings = {
		groupId = 1234,
		document = function()
			return if vanish then nil else profile
		end,
		grant = function()
			log.grants += 1
		end,
		isInGroup = function()
			vanish = true
			return true
		end,
	}
	CommunityReward.configure(settings)
	local gone = CommunityReward.claim(player)
	check("a profile that disappears mid-claim is NotReady", gone.reason == "NotReady", gone.reason)
	check("and nothing was granted", log.grants == 0, log.grants)

	-- Somebody else flagged it while we were in the lookup: the re-read catches it.
	local p2, prof2, log2 = scenario()
	CommunityReward.configure({
		groupId = 1234,
		document = function()
			return prof2
		end,
		grant = function()
			log2.grants += 1
		end,
		isInGroup = function()
			prof2.communityRewardClaimed = true -- a concurrent claim landed
			return true
		end,
	})
	local raced = CommunityReward.claim(p2)
	check("a flag set during the lookup is caught by the re-read", raced.reason == "AlreadyClaimed", raced.reason)
	check("so the reward is not paid twice", log2.grants == 0, log2.grants)
end

print("two rapid clicks cannot both pass the claimed check")
do
	-- The real double-pay window: the lookup yields, so without an in-flight guard
	-- both claims read `claimed == false` before either writes it.
	local player, profile, log = scenario()
	CommunityReward.configure({
		groupId = 1234,
		document = function()
			return profile
		end,
		grant = function()
			log.grants += 1
		end,
		isInGroup = function()
			task.wait() -- the web call
			return true
		end,
	})

	local results = {}
	task.spawn(function()
		table.insert(results, CommunityReward.claim(player))
	end)
	task.spawn(function()
		table.insert(results, CommunityReward.claim(player))
	end)
	task.wait(0.05)

	check("both claims returned", #results == 2, #results)
	local succeeded, refusedCount = 0, 0
	for _, result in results do
		if result.ok then
			succeeded += 1
		else
			refusedCount += 1
		end
	end
	check("exactly one succeeded", succeeded == 1, succeeded)
	check("the other was refused", refusedCount == 1, refusedCount)
	-- The guard's refusal, specifically -- and a retry then reports AlreadyClaimed,
	-- so the two answers together are coherent rather than contradictory.
	for _, result in results do
		if not result.ok then
			check("refused by the in-flight guard", result.reason == "Failed", result.reason)
		end
	end
	check("and a retry now says AlreadyClaimed", CommunityReward.claim(player).reason == "AlreadyClaimed")
	check("and the reward was paid ONCE", log.grants == 1, log.grants)
end

print("a throwing grant leaves the player paid, loudly, not the handler broken")
do
	-- Counted through its own local: `log` is not in scope inside the override that
	-- is being passed to the call which declares it.
	local attempts = 0
	local player, profile, log = scenario({
		grant = function()
			attempts += 1
			error("the reward table exploded")
		end,
	})
	local ok, result = pcall(CommunityReward.claim, player)
	check("claim itself does not throw", ok, result)
	check("it still reports success", ok and result.ok)
	check("the grant was attempted", attempts == 1, attempts)
	-- The documented lesser evil: marked paid with nothing, fixable by hand.
	check("the flag stays written", profile.communityRewardClaimed == true)
	check("and onClaimed still ran", log.claimed == 1, log.claimed)
end

print("hasClaimed, and claiming before configure")
do
	local player, profile = scenario()
	check("false before claiming", CommunityReward.hasClaimed(player) == false)
	CommunityReward.claim(player)
	check("true after", CommunityReward.hasClaimed(player) == true)
	check("the field name is the documented default", CommunityReward.claimedField() == "communityRewardClaimed")

	-- nil rather than false when the profile is not loaded: a caller has to be able
	-- to tell "no" from "cannot say yet".
	CommunityReward.configure({
		groupId = 1,
		document = function()
			return nil
		end,
		grant = function() end,
	})
	check("nil when the profile is not loaded", CommunityReward.hasClaimed(player) == nil)

	-- A custom field name must be honoured on both the read and the write.
	local p2, prof2 = scenario({ claimedField = "gotTheGroupThing" })
	CommunityReward.claim(p2)
	check("a custom claimedField is written", prof2.gotTheGroupThing == true)
	check("and the default is untouched", prof2.communityRewardClaimed == nil)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
