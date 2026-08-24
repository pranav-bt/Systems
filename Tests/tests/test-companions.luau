-- Companions' public surface, wired end to end: the collection, the slot-keyed
-- loadout, and the funnel every mutation goes through.
--
-- NO CHARACTER HERE, deliberately. syncPets no-ops without one, so everything below
-- exercises the record, the API's validation, and persistence -- the parts where the
-- decisions live. Rigs, welds and Motor6Ds are Instance wiring with no decisions in
-- them, and faking a streamed-in character to prove a Weld got parented would test
-- the shim rather than the library.
local rbx = require("./shim/roblox")
local Companions = require("./shim/library")("Companions")

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

-- A catalog: a Pets folder of Models, each with a part in it, exactly as a host would
-- author in ReplicatedStorage.
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
for _, name in { "Knight", "Mage", "Rogue" } do
	pets:Add(model(name))
end
rbx.ReplicatedStorage:Add(pets)

-- Persistence, captured so the tests can assert what was written and replay it.
local saved: { [any]: any } = {}
local seeded: { [any]: any } = {}
Companions.start({
	persistence = {
		load = function(player)
			-- By NAME, not by the Player: load runs inside onPlayerAdded, which fires
			-- synchronously from addPlayer, so a test cannot key a seed to a player it
			-- has not created yet.
			return seeded[player.Name]
		end,
		save = function(player, record)
			saved[player] = record
		end,
	},
})

print("the catalog loaded")
do
	local ids = Companions.getCatalogIds()
	table.sort(ids)
	check("three pets are catalogued", #ids == 3, #ids)
	check("by model name", table.concat(ids, ",") == "Knight,Mage,Rogue", table.concat(ids, ","))
end

print("ownership, and what equipping requires")
do
	local player = rbx.addPlayer("Ana")
	check("a joining player has an empty collection", #Companions.ownedIds(player) == 0)

	check("granting returns the new count", Companions.grant(player, "Knight") == 1)
	check("and again", Companions.grant(player, "Knight") == 2)
	check("ownedCount agrees", Companions.ownedCount(player, "Knight", 1) == 2)

	-- Equipping something unowned is refused even though it is catalogued.
	local unowned, unownedReason = Companions.equip(player, "Slot1", "Mage")
	check("an uncollected companion cannot be fielded", not unowned, unownedReason)

	-- ...and something owned but not catalogued is refused for the opposite reason.
	Companions.grant(player, "Ghost")
	check("an uncatalogued companion is still granted", Companions.ownedCount(player, "Ghost", 1) == 1)
	local ghost, ghostReason = Companions.equip(player, "Slot1", "Ghost")
	check("but cannot be fielded", not ghost)
	check("because it has no model", ghost == false and string.find(tostring(ghostReason), "no pet model") ~= nil, ghostReason)

	check("an owned, catalogued companion equips", Companions.equip(player, "Slot1", "Knight"))
	check("into the slot named", Companions.equippedAt(player, "Slot1").petId == "Knight")
	check("slotOf finds it", Companions.slotOf(player, "Knight") == "Slot1")

	-- Slot2 ships locked.
	local locked, lockedReason = Companions.equip(player, "Slot2", "Knight")
	check("a locked slot refuses", not locked)
	check("and says so", locked == false and string.find(tostring(lockedReason), "locked") ~= nil, lockedReason)
	check("unlocking it works", Companions.unlockSlot(player, "Slot2"))
	check("then it takes the second copy", Companions.equip(player, "Slot2", "Knight"))
	check("two slots occupied, in order", table.concat(Companions.equippedSlots(player), ",") == "Slot1,Slot2")
	check("no spare copies left", Companions.available(player, "Knight", 1) == 0)

	rbx.removePlayer(player)
end

print("every mutation goes through one funnel")
do
	local player = rbx.addPlayer("Ben")
	Companions.grant(player, "Knight", 1, 3)
	Companions.unlockSlot(player, "Slot2")
	Companions.unlockSlot(player, "Slot3")
	Companions.equip(player, "Slot1", "Knight")
	Companions.equip(player, "Slot2", "Knight")
	Companions.equip(player, "Slot3", "Knight")
	check("three are out", #Companions.equippedSlots(player) == 3)

	-- A merge eats two of the three copies that were out. Nothing else was called: the
	-- loadout must come back consistent on its own.
	check("moveCopies succeeds", Companions.moveCopies(player, "Knight", 1, 2, 2))
	check("one level 1 and one level 2 owned", Companions.ownedCount(player, "Knight", 1) == 1 and Companions.ownedCount(player, "Knight", 2) == 1)
	check("only one slot is still filled", #Companions.equippedSlots(player) == 1, #Companions.equippedSlots(player))
	check("and it is the earliest", Companions.equippedSlots(player)[1] == "Slot1")

	-- take goes through the same funnel.
	check("taking the last level 1 copy", Companions.take(player, "Knight", 1))
	check("empties the slot it was in", #Companions.equippedSlots(player) == 0)
	local short, shortReason = Companions.take(player, "Knight", 1)
	check("taking what is gone is refused", not short, shortReason)

	rbx.removePlayer(player)
end

print("slots: free, locked, relocked")
do
	local player = rbx.addPlayer("Cleo")
	Companions.grant(player, "Mage", 1, 2)
	check("only the first slot is unlocked", table.concat(Companions.unlockedSlots(player), ",") == "Slot1")
	check("the next to earn is Slot2", Companions.nextLockedSlot(player) == "Slot2")
	check("freeSlot is the unlocked empty one", Companions.freeSlot(player) == "Slot1")

	check("equipAnywhere takes it", Companions.equipAnywhere(player, "Mage"))
	check("no free slot now", Companions.freeSlot(player) == nil)
	local full, fullReason = Companions.equipAnywhere(player, "Mage")
	check("equipAnywhere refuses with a copy to spare", not full, fullReason)

	Companions.unlockSlot(player, "Slot2")
	check("unlocking frees one", Companions.freeSlot(player) == "Slot2")
	check("and it fills", Companions.equipAnywhere(player, "Mage"))
	check("relocking is allowed for an earned slot", Companions.relockSlot(player, "Slot2"))
	check("and empties it", Companions.equippedAt(player, "Slot2") == nil)
	check("a declared-free slot cannot be relocked", not Companions.relockSlot(player, "Slot1"))

	check("unequip by slot", Companions.unequip(player, "Slot1"))
	Companions.equipAnywhere(player, "Mage")
	Companions.unequipAll(player)
	check("unequipAll clears everything", #Companions.equippedSlots(player) == 0)

	rbx.removePlayer(player)
end

print("equipRandom tops the collection up rather than sidestepping it")
do
	local player = rbx.addPlayer("Dee")
	local picked = Companions.equipRandom(player)
	check("it fielded something", picked ~= nil, picked)
	check("and granted the copy it fielded", picked ~= nil and Companions.ownedCount(player, picked, 1) >= 1)
	check("which is in a slot", #Companions.equippedSlots(player) == 1)
	rbx.removePlayer(player)
end

print("persistence: the record is the unit")
do
	local player = rbx.addPlayer("Eve")
	Companions.grant(player, "Knight", 1, 2)
	Companions.equip(player, "Slot1", "Knight")
	local record = saved[player]
	check("saving happened on the mutation", record ~= nil)
	check("and carried the collection", record and record.owned.Knight[1] == 2)
	check("and the loadout", record and record.equipped.Slot1.petId == "Knight")

	-- getRecord hands out a copy: mutating it must change nothing.
	local copy = Companions.getRecord(player)
	copy.owned.Knight[1] = 99
	copy.equipped.Slot1 = nil
	check("getRecord is a copy", Companions.ownedCount(player, "Knight", 1) == 2)
	check("in both halves", Companions.equippedAt(player, "Slot1") ~= nil)
	rbx.removePlayer(player)

	-- Replayed on a new session. The stored form is exactly what a DataStore hands
	-- back: the level ladder returns keyed by the STRING "1".
	seeded.Returning = {
		owned = { Knight = { ["1"] = 2, ["3"] = 1 } },
		equipped = {
			Slot1 = { petId = "Knight", level = 1 },
			-- Slot2 is locked for a fresh profile, and Slot9 is not declared at all.
			-- Both must be emptied on load rather than fielded.
			Slot2 = { petId = "Knight", level = 3 },
			Slot9 = { petId = "Knight", level = 1 },
		},
		unlocked = {},
	}
	local returning = rbx.addPlayer("Returning")
	check("the string-keyed ladder was repaired", Companions.ownedCount(returning, "Knight", 1) == 2)
	check("at every level", Companions.ownedCount(returning, "Knight", 3) == 1)
	check("the legitimate slot was adopted", Companions.equippedAt(returning, "Slot1").petId == "Knight")
	check("a locked slot was emptied", Companions.equippedAt(returning, "Slot2") == nil)
	check("an undeclared slot was emptied", Companions.equippedAt(returning, "Slot9") == nil)
	check("so exactly one companion is out", #Companions.equippedSlots(returning) == 1)
	-- Loading must not write: a save on every join is a save nobody asked for.
	check("and the load did not trigger a save", saved[returning] == nil)
	rbx.reset()
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
