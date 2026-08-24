-- Companions' record layer: ownership as a count per level, the slot-keyed loadout,
-- and the density invariant that keeps a collection alive across a DataStore round
-- trip. All pure -- no character, no rig, no services.
local Loadout = require("./shim/library")("Companions", "Loadout")
local Config = require("./shim/library")("Companions", "Config")

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

local function levels(record, petId)
	return table.concat(Loadout.ownedLevels(record, petId), ",")
end

print("the level array stays dense, because a DataStore demands it")
do
	local record = Loadout.newRecord()
	-- Owning only a level 3 copy has to be an ARRAY with zeros, not { [3] = 1 }: a
	-- number-keyed table returns from a DataStore keyed by "3" and stops matching.
	Loadout.grant(record, "Knight", 3)
	check("a level 3 copy fills the gap with zeros", levels(record, "Knight") == "0,0,1", levels(record, "Knight"))

	Loadout.grant(record, "Knight", 1, 2)
	check("granting below it leaves no hole", levels(record, "Knight") == "2,0,1", levels(record, "Knight"))

	Loadout.take(record, "Knight", 3)
	check("trailing zeros are trimmed away", levels(record, "Knight") == "2", levels(record, "Knight"))

	Loadout.take(record, "Knight", 1, 2)
	check("the whole entry goes when nothing is left", record.owned.Knight == nil)
	check("and counts read zero rather than erroring", Loadout.ownedCount(record, "Knight", 1) == 0)
end

print("ownership is a count per level")
do
	local record = Loadout.newRecord()
	Loadout.grant(record, "Knight", 1, 9)
	Loadout.grant(record, "Knight", 2, 2)
	Loadout.grant(record, "Mage", 1)
	check("nine at level 1", Loadout.ownedCount(record, "Knight", 1) == 9)
	check("two at level 2", Loadout.ownedCount(record, "Knight", 2) == 2)
	check("eleven in total", Loadout.totalOwned(record, "Knight") == 11, Loadout.totalOwned(record, "Knight"))
	check("a level nobody owns is 0", Loadout.ownedCount(record, "Knight", 5) == 0)
	local ids = Loadout.ownedIds(record)
	check("ownedIds is sorted and complete", #ids == 2 and ids[1] == "Knight" and ids[2] == "Mage", table.concat(ids, ","))

	-- The returned ladder must be a copy, or a caller can break the invariant from
	-- outside and the corruption surfaces somewhere else entirely.
	local ladder = Loadout.ownedLevels(record, "Knight")
	ladder[1] = 999
	check("ownedLevels hands out a copy, not the array", Loadout.ownedCount(record, "Knight", 1) == 9)
end

print("take refuses rather than clamping")
do
	local record = Loadout.newRecord()
	Loadout.grant(record, "Knight", 1, 2)
	local ok, reason = Loadout.take(record, "Knight", 1, 3)
	check("taking more than exists is refused", not ok)
	check("and says what it found", ok == false and string.find(tostring(reason), "have 2") ~= nil, reason)
	check("leaving the count untouched", Loadout.ownedCount(record, "Knight", 1) == 2)
end

print("moveCopies: the primitive both addons sit on")
do
	local record = Loadout.newRecord()
	Loadout.grant(record, "Knight", 1, 3)

	-- The merge case: three leave level 1, exactly one arrives at level 2.
	local ok = Loadout.moveCopies(record, "Knight", 1, 2, 3)
	check("three level 1s become one level 2", ok and levels(record, "Knight") == "0,1", levels(record, "Knight"))

	-- The paid case: one leaves, one arrives.
	Loadout.grant(record, "Mage", 2)
	check("one-for-one is the paid upgrade", Loadout.moveCopies(record, "Mage", 2, 3, 1))
	check("and lands a level 3", levels(record, "Mage") == "0,0,1", levels(record, "Mage"))

	local same, sameReason = Loadout.moveCopies(record, "Mage", 3, 3, 1)
	check("moving to the same level is refused", not same, sameReason)
	local short = Loadout.moveCopies(record, "Mage", 3, 4, 5)
	check("moving more than is owned is refused", not short)
	check("and nothing moved", levels(record, "Mage") == "0,0,1", levels(record, "Mage"))
end
print("slots are declared and identified, not counted")
do
	local ids = Config.slotIds()
	check("three slots ship by default", #ids == 3, #ids)
	check("in declared order", table.concat(ids, ",") == "Slot1,Slot2,Slot3", table.concat(ids, ","))

	local record = Loadout.newRecord()
	check("the first is free for everybody", Loadout.isUnlocked(record, "Slot1"))
	check("the rest are locked", not Loadout.isUnlocked(record, "Slot2"))
	-- A record naming an undeclared slot is stale, not permissive.
	check("an undeclared slot is never unlocked", not Loadout.isUnlocked(record, "Ghost"))
	record.unlocked.Ghost = true
	check("even if the record claims it", not Loadout.isUnlocked(record, "Ghost"))
	record.unlocked.Ghost = nil

	check("unlocking works", Loadout.unlock(record, "Slot2"))
	check("and takes effect", Loadout.isUnlocked(record, "Slot2"))
	local twice, twiceReason = Loadout.unlock(record, "Slot2")
	check("unlocking twice is refused", not twice, twiceReason)
	local typo, typoReason = Loadout.unlock(record, "Slot9")
	check("a typo is refused rather than stored", not typo)
	check("and says the slot is undeclared", typo == false and string.find(tostring(typoReason), "declared") ~= nil, typoReason)

	check("unlockedSlots is ordered", table.concat(Loadout.unlockedSlots(record), ",") == "Slot1,Slot2")
	check("lockedSlots is the rest", table.concat(Loadout.lockedSlots(record), ",") == "Slot3")
	check("nextLocked is the first of them", Loadout.nextLocked(record) == "Slot3")

	-- A slot free by declaration is not a per-player fact, so it cannot be relocked.
	check("relocking a declared-free slot is refused", not Loadout.relock(record, "Slot1"))

	-- relock must empty the slot ITSELF. Asserting this through the public API would
	-- prove nothing: afterChange runs reconcile, which would clear a locked slot anyway.
	Loadout.grant(record, "Sentry", 1)
	Loadout.equip(record, "Slot2", "Sentry", 1)
	check("a companion is standing in the earned slot", Loadout.equippedAt(record, "Slot2") ~= nil)
	check("relocking an earned slot works", Loadout.relock(record, "Slot2"))
	check("and it is locked again", not Loadout.isUnlocked(record, "Slot2"))
	check("and relock emptied it, with no reconcile involved", Loadout.equippedAt(record, "Slot2") == nil)
end

print("equipping names the slot")
do
	local record = Loadout.newRecord()
	Loadout.grant(record, "Knight", 1, 2)
	Loadout.grant(record, "Knight", 3)
	Loadout.unlock(record, "Slot2")

	check("into a named slot", Loadout.equip(record, "Slot1", "Knight", 1))
	check("and the record says which", Loadout.equippedAt(record, "Slot1").petId == "Knight")
	check("with the level it went in at", Loadout.equippedAt(record, "Slot1").level == 1)
	check("an empty slot reads nil", Loadout.equippedAt(record, "Slot2") == nil)

	local occupied, occupiedReason = Loadout.equip(record, "Slot1", "Knight", 3)
	check("an occupied slot is refused, not replaced", not occupied, occupiedReason)
	check("and what was there is untouched", Loadout.equippedAt(record, "Slot1").level == 1)

	local locked, lockedReason = Loadout.equip(record, "Slot3", "Knight", 3)
	check("a locked slot is refused", not locked)
	check("and says so", locked == false and string.find(tostring(lockedReason), "locked") ~= nil, lockedReason)

	check("an undeclared slot is refused", not Loadout.equip(record, "Ghost", "Knight", 3))

	-- The same companion may be out twice, at the same level or different ones.
	check("the same companion in another slot", Loadout.equip(record, "Slot2", "Knight", 1))
	check("two are out", #Loadout.equippedSlots(record) == 2)
	check("equippedSlots is in declared order", table.concat(Loadout.equippedSlots(record), ",") == "Slot1,Slot2")
	check("equippedCount counts a level", Loadout.equippedCount(record, "Knight", 1) == 2)
	check("or every level", Loadout.equippedCount(record, "Knight") == 2)
	check("available is owned minus equipped", Loadout.available(record, "Knight", 1) == 0)
	check("slotOf finds the first holder", Loadout.slotOf(record, "Knight", 1) == "Slot1")
	check("slotOf at a level nobody holds is nil", Loadout.slotOf(record, "Knight", 3) == nil)

	-- ATTRIBUTABLE: the slot has to be unlocked and empty, or the refusal could be the
	-- lock talking rather than the missing copy. Two owned at level 1, both already out.
	Loadout.unlock(record, "Slot3")
	local spare, spareReason = Loadout.equip(record, "Slot3", "Knight", 1)
	check("no spare copy is refused even into a free unlocked slot", not spare)
	check("and says the copy is the reason", spare == false and string.find(tostring(spareReason), "no spare") ~= nil, spareReason)
	-- The same slot takes a companion there IS a spare of, proving the slot was fine.
	check("the same slot accepts a spare copy", Loadout.equip(record, "Slot3", "Knight", 3))
end

print("equipAnywhere and unequip")
do
	local record = Loadout.newRecord()
	Loadout.grant(record, "Mage", 1, 3)
	Loadout.unlock(record, "Slot2")

	check("freeSlot is the first empty unlocked one", Loadout.freeSlot(record) == "Slot1")
	check("equipAnywhere takes it", Loadout.equipAnywhere(record, "Mage", 1))
	check("freeSlot moves on", Loadout.freeSlot(record) == "Slot2")
	check("and again", Loadout.equipAnywhere(record, "Mage", 1))
	check("no free slot left", Loadout.freeSlot(record) == nil)
	local full, fullReason = Loadout.equipAnywhere(record, "Mage", 1)
	check("equipAnywhere refuses when all are full", not full)
	check("with a copy still spare, so the slots are the reason", Loadout.available(record, "Mage", 1) == 1, fullReason)

	check("unequip by slot id", Loadout.unequip(record, "Slot1"))
	check("that slot is empty", Loadout.equippedAt(record, "Slot1") == nil)
	check("the other is untouched", Loadout.equippedAt(record, "Slot2") ~= nil)
	check("unequipping an empty slot is refused", not Loadout.unequip(record, "Slot1"))
	Loadout.unequipAll(record)
	check("unequipAll empties everything", #Loadout.equippedSlots(record) == 0)
end

print("reconcile: no slot may hold what it cannot")
do
	local record = Loadout.newRecord()
	Loadout.grant(record, "Knight", 1, 3)
	Loadout.unlock(record, "Slot2")
	Loadout.unlock(record, "Slot3")
	Loadout.equip(record, "Slot1", "Knight", 1)
	Loadout.equip(record, "Slot2", "Knight", 1)
	Loadout.equip(record, "Slot3", "Knight", 1)

	-- A merge eats two of the three copies that were out.
	Loadout.moveCopies(record, "Knight", 1, 2, 2)
	check("one level 1 copy is left", Loadout.ownedCount(record, "Knight", 1) == 1)
	check("two slots are cleared", Loadout.reconcile(record) == 2)
	-- Reverse order means the slot arranged FIRST survives.
	check("and the earliest slot is the survivor", Loadout.equippedAt(record, "Slot1") ~= nil)
	check("the later ones are empty", Loadout.equippedAt(record, "Slot2") == nil and Loadout.equippedAt(record, "Slot3") == nil)
	check("a consistent record reconciles to zero", Loadout.reconcile(record) == 0)

	-- A relocked slot cannot keep its occupant.
	local relocked = Loadout.newRecord()
	Loadout.grant(relocked, "Mage", 1, 2)
	Loadout.unlock(relocked, "Slot2")
	Loadout.equip(relocked, "Slot1", "Mage", 1)
	Loadout.equip(relocked, "Slot2", "Mage", 1)
	relocked.unlocked.Slot2 = nil -- straight to the field, as a stale record would be
	check("a slot that lost its unlock is cleared", Loadout.reconcile(relocked) == 1)
	check("leaving the free slot alone", Loadout.equippedAt(relocked, "Slot1") ~= nil)

	-- A slot Config no longer declares.
	local stale = Loadout.newRecord()
	Loadout.grant(stale, "Mage", 1)
	stale.equipped.Retired = { petId = "Mage", level = 1 }
	check("an undeclared slot is cleared", Loadout.reconcile(stale) == 1)
	check("and forgotten", stale.equipped.Retired == nil)
end

print("sanitise: nothing that came back from persistence is trusted")
do
	-- THE FAILURE THIS EXISTS FOR. A level ladder written as { [2] = 3 } comes back
	-- from a DataStore as { ["2"] = 3 }. Unrepaired, the collection reads as empty and
	-- the player appears to have been wiped.
	local roundTripped = Loadout.sanitise({ owned = { Knight = { ["1"] = 2, ["3"] = 1 } } })
	check("string-keyed levels are repaired to an array", levels(roundTripped, "Knight") == "2,0,1", levels(roundTripped, "Knight"))
	check("and the counts survive", Loadout.ownedCount(roundTripped, "Knight", 3) == 1)

	local junk = Loadout.sanitise({
		owned = {
			Knight = { 2 },
			[42] = { 1 }, -- a non-string pet id is not a pet
			Mage = "nonsense",
			Ghost = { 0, -1, "x" }, -- nothing valid at any level
		},
		equipped = {
			Slot1 = { petId = "Knight", level = 1 },
			Slot2 = { petId = "Knight", level = "2" }, -- a stringified level is still a level
			Slot3 = { petId = 7, level = 1 }, -- not a pet id
			[9] = { petId = "Knight", level = 1 }, -- not a slot id
			Slot4 = "nonsense",
		},
		unlocked = { Slot2 = true, Slot3 = false, [5] = true },
	})
	check("a valid ladder survives", Loadout.ownedCount(junk, "Knight", 1) == 2)
	check("a non-string pet id is dropped", junk.owned[42] == nil)
	check("a non-table ladder is dropped", junk.owned.Mage == nil)
	check("a ladder with nothing valid is dropped", junk.owned.Ghost == nil)
	check("a valid slot entry survives", junk.equipped.Slot1 ~= nil)
	check("including a stringified level", junk.equipped.Slot2 ~= nil and junk.equipped.Slot2.level == 2)
	check("a bad pet id is dropped", junk.equipped.Slot3 == nil)
	check("a non-string slot id is dropped", junk.equipped[9] == nil)
	check("a non-table entry is dropped", junk.equipped.Slot4 == nil)
	check("a truthy unlock survives", junk.unlocked.Slot2 == true)
	check("a falsy one does not", junk.unlocked.Slot3 == nil)
	check("nor a non-string slot id", junk.unlocked[5] == nil)

	-- Slot ids are NOT validated against Config on load: a slot undeclared while a
	-- Config file is mid-edit must not delete a player's loadout. reconcile empties it
	-- without forgetting it happened.
	local mid = Loadout.sanitise({ owned = { Mage = { 1 } }, equipped = { Retired = { petId = "Mage", level = 1 } } })
	check("an undeclared slot survives sanitise", mid.equipped.Retired ~= nil)
	check("and only reconcile clears it", Loadout.reconcile(mid) == 1)

	for label, input in { ["nil"] = nil, ["a string"] = "x", ["a number"] = 5, ["an empty table"] = {} } do
		local record = Loadout.sanitise(input)
		local usable = type(record.owned) == "table" and type(record.equipped) == "table" and type(record.unlocked) == "table"
		check(`{label} yields an empty usable record`, usable and #Loadout.equippedSlots(record) == 0)
	end

	-- A record this module wrote must survive its own sanitiser unchanged, or every
	-- save/load cycle would erode a collection.
	local original = Loadout.newRecord()
	Loadout.grant(original, "Knight", 1, 4)
	Loadout.grant(original, "Knight", 3, 2)
	Loadout.unlock(original, "Slot2")
	Loadout.equip(original, "Slot2", "Knight", 3)
	local reloaded = Loadout.sanitise(original)
	check("round trip is lossless: ladder", levels(reloaded, "Knight") == levels(original, "Knight"))
	check("round trip is lossless: slot", reloaded.equipped.Slot2 ~= nil and reloaded.equipped.Slot2.level == 3)
	check("round trip is lossless: unlock", reloaded.unlocked.Slot2 == true)
	check("and it reconciles clean", Loadout.reconcile(reloaded) == 0)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
