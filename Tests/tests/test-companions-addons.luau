-- The two opt-in addons over the Companions base: merging duplicates, and paying to
-- level. Both are policies over one primitive (Companions.moveCopies), so the point of
-- these checks is that neither owns the level and the two can coexist.
local rbx = require("./shim/roblox")
local Companions = require("./shim/library")("Companions")
local Merge = require("./shim/library")("CompanionsMerge")
local Upgrades = require("./shim/library")("CompanionsUpgrades")

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

local function model(name)
	local m = rbx.Instance.new("Model")
	m.Name = name
	local part = rbx.Instance.new("Part")
	part.Name = "Body"
	m:Add(part)
	return m
end

local pets = rbx.Instance.new("Folder")
pets.Name = "Pets"
pets:Add(model("Knight"))
pets:Add(model("Mage"))
rbx.ReplicatedStorage:Add(pets)

Companions.start({})
-- A ten-rung ladder, so the factorial shape has room to show.
local levels = {}
for _ = 1, 10 do
	table.insert(levels, {})
end
Companions.definePet("Knight", { levels = levels })
Companions.definePet("Mage", { levels = { {}, {} } }) -- tops out at 2

local wallet: { [any]: number } = {}
Merge.configure({ companions = Companions })
Upgrades.configure({
	companions = Companions,
	price = function(_petId, targetLevel)
		-- Not for sale past level 3, so "this rung is not sold" is exercised.
		return if targetLevel <= 3 then targetLevel * 100 else nil
	end,
	balance = function(player)
		return wallet[player] or 0
	end,
	charge = function(player, amount)
		if (wallet[player] or 0) < amount then
			return false
		end
		wallet[player] -= amount
		return true
	end,
})

print("the merge price is the level being reached")
do
	check("two level 1s make a level 2", Merge.copiesFor(2) == 2, Merge.copiesFor(2))
	check("three level 2s make a level 3", Merge.copiesFor(3) == 3, Merge.copiesFor(3))
	check("six level 5s make a level 6", Merge.copiesFor(6) == 6, Merge.copiesFor(6))
	-- Clamped, so nobody gets a free merge by asking about level 0.
	check("level 0 clamps to the first real rung", Merge.copiesFor(0) == 2, Merge.copiesFor(0))
	check("level 1 does too", Merge.copiesFor(1) == 2, Merge.copiesFor(1))
end

print("merging consumes copies and produces one")
do
	local player = rbx.addPlayer("Ana")
	Companions.grant(player, "Knight", 1, 2)

	local can = Merge.canMerge(player, "Knight", 1)
	check("two copies is enough for level 2", can)
	check("merging succeeds", Merge.merge(player, "Knight", 1))
	check("both level 1 copies are gone", Companions.ownedCount(player, "Knight", 1) == 0)
	check("and one level 2 exists", Companions.ownedCount(player, "Knight", 2) == 1)

	local short, shortReason = Merge.canMerge(player, "Knight", 2)
	check("one level 2 is not enough for level 3", not short)
	check("and the reason counts it", short == false and string.find(tostring(shortReason), "1 of 3") ~= nil, shortReason)

	local have, need = Merge.progress(player, "Knight", 2)
	check("progress reports the pair", have == 1 and need == 3, `{have}/{need}`)

	-- The base package's ladder is the ceiling, not one of this addon's own.
	Companions.grant(player, "Mage", 2, 5)
	local topped, toppedReason = Merge.canMerge(player, "Mage", 2)
	check("a companion at its max cannot merge further", not topped)
	check("and says where it tops out", topped == false and string.find(tostring(toppedReason), "level 2") ~= nil, toppedReason)
	-- Through `merge` and not only `canMerge`: moveCopies would happily mint a level 3
	-- here, because the ladder's ceiling is this addon's to enforce, not the base's.
	local minted = Merge.merge(player, "Mage", 2)
	check("and merge itself refuses, not just canMerge", not minted)
	check("so no over-level copy was minted", Companions.ownedCount(player, "Mage", 3) == 0)
	rbx.removePlayer(player)
end

print("mergeAll cascades from the bottom up")
do
	local player = rbx.addPlayer("Ben")
	-- Six level 1s: three level 2s, which is exactly one level 3.
	Companions.grant(player, "Knight", 1, 6)
	local merges = Merge.mergeAll(player, "Knight")
	check("four merges happened", merges == 4, merges)
	check("nothing is left at level 1", Companions.ownedCount(player, "Knight", 1) == 0)
	check("nor at level 2", Companions.ownedCount(player, "Knight", 2) == 0)
	check("one level 3 came out", Companions.ownedCount(player, "Knight", 3) == 1)
	-- N! pulls: a level 3 costs 6, which is what went in.
	check("which cost the factorial: 3! = 6 pulls", Companions.totalOwned(player, "Knight") == 1)

	-- Sweeping downward would have stopped after the level 1s.
	check("a second sweep finds nothing", Merge.mergeAll(player, "Knight") == 0)
	rbx.removePlayer(player)
end

print("an equipped copy is not eaten by a merge, by default")
do
	local player = rbx.addPlayer("Cleo")
	Companions.grant(player, "Knight", 1, 2)
	Companions.equip(player, "Slot1", "Knight")
	check("one of the two is out", Companions.available(player, "Knight", 1) == 1)

	local guarded, guardedReason = Merge.canMerge(player, "Knight", 1)
	check("so the merge is refused", not guarded)
	check("counting only what is spare", guarded == false and string.find(tostring(guardedReason), "1 of 2") ~= nil, guardedReason)
	check("and the companion is still out", Companions.equippedAt(player, "Slot1") ~= nil)

	-- Opting in lets it consume the fielded one, and the base package unequips it.
	Merge.configure({ companions = Companions, consumeEquipped = true })
	check("with consumeEquipped it merges", Merge.merge(player, "Knight", 1))
	check("the level 2 exists", Companions.ownedCount(player, "Knight", 2) == 1)
	check("and the slot was emptied for us", Companions.equippedAt(player, "Slot1") == nil)
	Merge.configure({ companions = Companions })
	rbx.removePlayer(player)
end

print("a replaced cost function is honoured, and cannot spin forever")
do
	local player = rbx.addPlayer("Dee")
	Merge.configure({
		companions = Companions,
		cost = function()
			return 2 -- flat: two of anything makes the next
		end,
	})
	check("the replacement is used", Merge.copiesFor(6) == 2, Merge.copiesFor(6))
	Companions.grant(player, "Knight", 1, 4)
	local merges = Merge.mergeAll(player, "Knight")
	check("four level 1s cascade to one level 3", Companions.ownedCount(player, "Knight", 3) == 1, merges)

	-- A perverse cost must not hang mergeAll. Zero is clamped to the minimum of two, so
	-- the loop still consumes on every step and terminates.
	Merge.configure({
		companions = Companions,
		cost = function()
			return 0
		end,
	})
	check("a zero cost is clamped, not obeyed", Merge.copiesFor(4) == 2, Merge.copiesFor(4))
	Companions.grant(player, "Knight", 1, 8)
	local ok = pcall(Merge.mergeAll, player, "Knight")
	check("mergeAll terminates", ok)
	Merge.configure({ companions = Companions })
	rbx.removePlayer(player)
end

print("upgrades: pay to raise one copy")
do
	local player = rbx.addPlayer("Eve")
	wallet[player] = 1000
	Companions.grant(player, "Knight", 1)

	check("the price is the host's", Upgrades.priceOf("Knight", 1) == 200, Upgrades.priceOf("Knight", 1))
	local can, _, price = Upgrades.canUpgrade(player, "Knight", 1)
	check("it can be bought", can)
	check("and the price comes back with the answer", price == 200, price)

	check("upgrading works", Upgrades.upgrade(player, "Knight", 1))
	check("the copy moved up", Companions.ownedCount(player, "Knight", 2) == 1)
	check("and nothing is left below", Companions.ownedCount(player, "Knight", 1) == 0)
	check("the wallet was charged", wallet[player] == 800, wallet[player])

	-- Too poor.
	wallet[player] = 10
	local poor, poorReason = Upgrades.canUpgrade(player, "Knight", 2)
	check("an unaffordable rung is refused", not poor)
	check("and says the balance", poor == false and string.find(tostring(poorReason), "balance is 10") ~= nil, poorReason)
	check("nothing was charged", wallet[player] == 10)

	-- A rung with no price at all.
	wallet[player] = 100000
	Companions.grant(player, "Knight", 3)
	local unsold, unsoldReason = Upgrades.canUpgrade(player, "Knight", 3)
	check("a rung the host does not sell is refused", not unsold)
	check("even when affordable", unsold == false and string.find(tostring(unsoldReason), "not for sale") ~= nil, unsoldReason)

	-- Nothing to upgrade.
	local none = Upgrades.canUpgrade(player, "Mage", 1)
	check("a companion they do not own is refused", not none)
	rbx.removePlayer(player)
end

print("the charge is the last word, and it is taken before the level moves")
do
	local player = rbx.addPlayer("Frank")
	wallet[player] = 1000
	Companions.grant(player, "Knight", 1)

	-- A host may refuse at the last moment: a failed receipt, a rate limit, another
	-- server having spent the same gold. That must abort BEFORE the level moves.
	local refusing = {
		companions = Companions,
		price = function(_petId, targetLevel)
			return targetLevel * 100
		end,
		balance = function(p)
			return wallet[p] or 0
		end,
		charge = function()
			return false
		end,
	}
	Upgrades.configure(refusing)
	local refused, refusedReason = Upgrades.upgrade(player, "Knight", 1)
	check("a refused charge fails the upgrade", not refused, refusedReason)
	check("the level did not move", Companions.ownedCount(player, "Knight", 1) == 1)
	check("and the wallet is untouched", wallet[player] == 1000)

	-- Charge-before-move: the charge function sees the level not yet raised, which is
	-- what makes "paid but not received" the failure mode rather than a free level.
	local seenAtCharge = nil
	Upgrades.configure({
		companions = Companions,
		price = function(_petId, targetLevel)
			return targetLevel * 100
		end,
		balance = function(p)
			return wallet[p] or 0
		end,
		charge = function(p, amount)
			seenAtCharge = Companions.ownedCount(p, "Knight", 2)
			wallet[p] -= amount
			return true
		end,
	})
	check("the upgrade goes through", Upgrades.upgrade(player, "Knight", 1))
	check("the charge happened before the level moved", seenAtCharge == 0, seenAtCharge)
	check("and afterwards the level is there", Companions.ownedCount(player, "Knight", 2) == 1)
	rbx.removePlayer(player)
end

print("an equipped copy CAN be upgraded, which is the opposite default to merge")
do
	local player = rbx.addPlayer("Gwen")
	wallet[player] = 1000
	Companions.grant(player, "Knight", 1)
	Companions.equip(player, "Slot1", "Knight")
	check("the only copy is out", Companions.available(player, "Knight", 1) == 0)

	Upgrades.configure({
		companions = Companions,
		price = function()
			return 100
		end,
		balance = function(p)
			return wallet[p] or 0
		end,
		charge = function(p, amount)
			wallet[p] -= amount
			return true
		end,
	})
	check("upgrading the fielded copy is allowed", Upgrades.upgrade(player, "Knight", 1))
	check("it is now a level 2", Companions.ownedCount(player, "Knight", 2) == 1)
	-- The slot held a level 1 that no longer exists, so the base package emptied it.
	check("and the stale slot entry was cleared", Companions.equippedAt(player, "Slot1") == nil)

	-- Turning it off makes upgrades behave like merges.
	Upgrades.configure({
		companions = Companions,
		upgradeEquipped = false,
		price = function()
			return 100
		end,
		balance = function(p)
			return wallet[p] or 0
		end,
		charge = function(p, amount)
			wallet[p] -= amount
			return true
		end,
	})
	Companions.equip(player, "Slot1", "Knight", 2)
	local guarded, guardedReason = Upgrades.canUpgrade(player, "Knight", 2)
	check("with upgradeEquipped false a fielded copy is refused", not guarded, guardedReason)
	rbx.removePlayer(player)
end

print("both addons installed at once do not fight over the level")
do
	local player = rbx.addPlayer("Hal")
	wallet[player] = 10000
	Merge.configure({ companions = Companions })
	Upgrades.configure({
		companions = Companions,
		price = function()
			return 100
		end,
		balance = function(p)
			return wallet[p] or 0
		end,
		charge = function(p, amount)
			wallet[p] -= amount
			return true
		end,
	})

	Companions.grant(player, "Knight", 1, 2)
	check("merge takes it to level 2", Merge.merge(player, "Knight", 1))
	check("then upgrade takes it to level 3", Upgrades.upgrade(player, "Knight", 2))
	check("one level 3 exists", Companions.ownedCount(player, "Knight", 3) == 1)
	check("and nothing was left behind", Companions.totalOwned(player, "Knight") == 1)

	-- pending / affordable are the two "what can I do" queries; each should see its own.
	Companions.grant(player, "Knight", 1, 2)
	local mergeable = Merge.pending(player)
	check("merge lists the level 1 pair", #mergeable == 1 and mergeable[1].level == 1, #mergeable)
	local buyable = Upgrades.affordable(player)
	check("upgrades lists every rung with a copy and a price", #buyable >= 2, #buyable)
	rbx.removePlayer(player)
end

print("neither addon works without the base")
do
	-- A fresh require would be unconfigured; simulate by configuring badly.
	check("merge refuses a non-package", not pcall(Merge.configure, { companions = 5 }))
	check("upgrades refuses a missing price", not pcall(Upgrades.configure, { companions = Companions }))
	check(
		"merge refuses a non-function cost",
		not pcall(Merge.configure, { companions = Companions, cost = "cheap" })
	)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
