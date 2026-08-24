--!strict

-- The player's companion record: what they own, what they have out, and how many
-- they may have out.
--
-- PURE. No Instances, no services, no rig, no player. Every function takes a
-- record and returns a decision, which is what makes the whole collection layer
-- testable without a character standing anywhere. init.luau owns the live pets and
-- comes here for every question about the record.
--
-- THE LEVEL DIMENSION IS A DENSE ARRAY, AND THAT IS NOT A STYLE CHOICE.
-- `owned[petId]` is indexed by level. A table keyed by NUMBER does not survive a
-- DataStore round trip: it comes back keyed by the string "2" and silently stops
-- matching, so every count reads as zero and a player's collection appears to have
-- been wiped. The shapes that survive are a string-keyed dictionary or a
-- CONTIGUOUS array. This is the array, which means holes are filled with zeros --
-- owning one level 3 copy and nothing else is `{ 0, 0, 1 }`. Trailing zeros are
-- trimmed because they carry nothing; leading ones cannot be.
--
-- OWNERSHIP IS A COUNT PER LEVEL, not a boolean. "Do you have a Knight" stopped
-- being the question the moment levels existed: a player may hold nine level 1s
-- and two level 2s, and a collection screen lists those as two entries.
--
-- SLOTS ARE IDENTIFIED, NOT COUNTED. A companion is equipped INTO a named slot and
-- the record says which one. A count would be smaller and would throw away
-- everything a count cannot express -- a slot that is always the left shoulder, one
-- unlocked by a route the others are not, a UI drawing the third square greyed out,
-- an ability that reads "whatever is in slot 1" -- and none of it can be recovered
-- from a number afterwards. Slots are declared in Config; this module only ever
-- reads that declaration.
--
-- EVERY KEY IN A RECORD IS A STRING, and the one table that is not keyed at all is
-- an array. That is the whole record made safe for a DataStore round trip, not just
-- the level ladder.
--
-- NOTHING HERE CHARGES ANYTHING. `unlock` records that a slot is open; deciding
-- that a player earned it -- gold, Robux, a level, a promotion -- is the host's
-- economy and none of this module's business.

local Config = require(script.Parent.Config)

local Loadout = {}

export type Equipped = {
	petId: string,
	level: number,
}

export type Record = {
	-- petId -> dense array; index is the level, value is how many copies at it.
	owned: { [string]: { number } },
	-- slotId -> the copy standing in it. Sparse: an absent slot is an empty one.
	equipped: { [string]: Equipped },
	-- slotId -> true, for slots this player unlocked by DOING something. Slots that
	-- are free for everybody are absent from here, so making one free later lifts
	-- every existing player at once with nothing to migrate.
	unlocked: { [string]: true },
}

function Loadout.newRecord(): Record
	return { owned = {}, equipped = {}, unlocked = {} }
end

-- ─────────────────────────────────────────────────────── density invariant ──

-- Reads a count without materialising anything: a level nobody owns is absent, not
-- zero-valued, so callers must not index straight into the array.
local function countAt(levels: { number }?, level: number): number
	if not levels then
		return 0
	end
	local value = levels[level]
	return if type(value) == "number" and value > 0 then math.floor(value) else 0
end

-- Writes a count, filling any gap below it with zeros and trimming any zeros left
-- above it. The array is contiguous on both sides of this call, which is the whole
-- invariant the DataStore constraint demands.
local function setCount(levels: { number }, level: number, count: number)
	for index = #levels + 1, level - 1 do
		levels[index] = 0
	end
	levels[level] = math.max(0, math.floor(count))
	while #levels > 0 and levels[#levels] == 0 do
		levels[#levels] = nil
	end
end

function Loadout.ownedCount(record: Record, petId: string, level: number): number
	return countAt(record.owned[petId], level)
end

-- The whole ladder for one companion, as a copy: callers get to iterate it without
-- being able to break the density invariant from outside.
function Loadout.ownedLevels(record: Record, petId: string): { number }
	local levels = record.owned[petId]
	return if levels then table.clone(levels) else {}
end

function Loadout.totalOwned(record: Record, petId: string): number
	local total = 0
	for _, count in record.owned[petId] or {} do
		total += count
	end
	return total
end

-- Every companion the player holds at least one of, sorted so a UI drawing the
-- collection gets a stable order without doing it again itself.
function Loadout.ownedIds(record: Record): { string }
	local ids: { string } = {}
	for petId, levels in record.owned do
		if #levels > 0 then
			table.insert(ids, petId)
		end
	end
	table.sort(ids)
	return ids
end

-- ────────────────────────────────────────────────────────────── ownership ──

-- Adds copies. Returns the new count at that level.
function Loadout.grant(record: Record, petId: string, level: number, count: number?): number
	local howMany = math.max(1, math.floor(count or 1))
	local levels = record.owned[petId]
	if not levels then
		levels = {}
		record.owned[petId] = levels
	end
	local now = countAt(levels, level) + howMany
	setCount(levels, level, now)
	return now
end

-- Removes copies. Refuses rather than clamping: a caller asking to take three when
-- two exist has miscounted, and silently taking two would hide it.
function Loadout.take(record: Record, petId: string, level: number, count: number?): (boolean, string?)
	local howMany = math.max(1, math.floor(count or 1))
	local levels = record.owned[petId]
	local have = countAt(levels, level)
	if have < howMany then
		return false, `have {have} of {petId} at level {level}, asked to take {howMany}`
	end
	setCount(levels :: { number }, level, have - howMany)
	if #(levels :: { number }) == 0 then
		record.owned[petId] = nil
	end
	return true
end

--[[
	THE PRIMITIVE BOTH ADDONS SIT ON. Moves `count` copies from one level to another.

	Merge and pay-to-upgrade are the same mutation for different reasons -- one
	demands copies, the other demands currency -- so the mutation lives here once and
	each addon supplies only its own rule for when it is allowed. Two addons owning
	two mutation paths would be two answers to "what is this player's collection".

	`count` is what LEAVES `fromLevel`; exactly one copy arrives at `toLevel`, because
	that is what both callers mean: three level 2s become one level 3, and a paid
	upgrade turns one level 2 into one level 3. Pass count = 1 for the paid case.
]]
function Loadout.moveCopies(
	record: Record,
	petId: string,
	fromLevel: number,
	toLevel: number,
	count: number?
): (boolean, string?)
	local howMany = math.max(1, math.floor(count or 1))
	if fromLevel == toLevel then
		return false, "fromLevel and toLevel are the same"
	end
	local took, reason = Loadout.take(record, petId, fromLevel, howMany)
	if not took then
		return false, reason
	end
	Loadout.grant(record, petId, toLevel, 1)
	return true
end

-- ────────────────────────────────────────────────────────────────── the slots ──

-- Free for everybody, or unlocked by this player. An undeclared slot is never
-- unlocked -- a record naming one is stale, not permissive.
function Loadout.isUnlocked(record: Record, slotId: string): boolean
	local definition = Config.slot(slotId)
	if not definition then
		return false
	end
	return definition.unlockedByDefault == true or record.unlocked[slotId] == true
end

-- Records that a slot is open. Refuses a slot that does not exist, so a typo shows
-- up here rather than as a square that never appears.
function Loadout.unlock(record: Record, slotId: string): (boolean, string?)
	if not Config.slot(slotId) then
		return false, `no slot is declared as "{slotId}"`
	end
	if Loadout.isUnlocked(record, slotId) then
		return false, `slot "{slotId}" is already unlocked`
	end
	record.unlocked[slotId] = true
	return true
end

-- Takes an explicit unlock back, and empties the slot with it: a companion standing
-- in a slot the player no longer has is the inconsistency `reconcile` exists to
-- prevent, so this does not create one. A slot that is free by declaration cannot be
-- relocked -- that is a Config decision, not a per-player one.
function Loadout.relock(record: Record, slotId: string): boolean
	if record.unlocked[slotId] == nil then
		return false
	end
	record.unlocked[slotId] = nil
	record.equipped[slotId] = nil
	return true
end

-- Declared order, filtered. Ordered rather than a set because these drive a UI and
-- "which is the next one to offer" has to be the same answer twice running.
function Loadout.unlockedSlots(record: Record): { string }
	local out: { string } = {}
	for _, slotId in Config.slotIds() do
		if Loadout.isUnlocked(record, slotId) then
			table.insert(out, slotId)
		end
	end
	return out
end

function Loadout.lockedSlots(record: Record): { string }
	local out: { string } = {}
	for _, slotId in Config.slotIds() do
		if not Loadout.isUnlocked(record, slotId) then
			table.insert(out, slotId)
		end
	end
	return out
end

-- The cheapest thing left to want: what an "unlock a slot" button acts on when the
-- player has not picked a square themselves.
function Loadout.nextLocked(record: Record): string?
	return Loadout.lockedSlots(record)[1]
end

-- First unlocked slot with nothing in it, in declared order. What "equip this
-- companion" means when the caller has no particular slot in mind.
function Loadout.freeSlot(record: Record): string?
	for _, slotId in Loadout.unlockedSlots(record) do
		if record.equipped[slotId] == nil then
			return slotId
		end
	end
	return nil
end

-- ────────────────────────────────────────────────────────────── the loadout ──

function Loadout.equippedAt(record: Record, slotId: string): Equipped?
	return record.equipped[slotId]
end

-- Occupied slots in declared order.
function Loadout.equippedSlots(record: Record): { string }
	local out: { string } = {}
	for _, slotId in Config.slotIds() do
		if record.equipped[slotId] ~= nil then
			table.insert(out, slotId)
		end
	end
	return out
end

-- Nil level counts every level.
function Loadout.equippedCount(record: Record, petId: string, level: number?): number
	local count = 0
	for _, entry in record.equipped do
		if entry.petId == petId and (level == nil or entry.level == level) then
			count += 1
		end
	end
	return count
end

-- Which slot holds this companion, in declared order, or nil.
function Loadout.slotOf(record: Record, petId: string, level: number?): string?
	for _, slotId in Config.slotIds() do
		local entry = record.equipped[slotId]
		if entry and entry.petId == petId and (level == nil or entry.level == level) then
			return slotId
		end
	end
	return nil
end

--[[
	Owned but not already out.

	An addon that consumes copies should almost always spend THESE rather than the raw
	owned count, so a merge cannot quietly eat the companion the player is looking at.
	This module does not enforce that -- a host may legitimately want "consume
	anything" -- but `reconcile` makes the unsafe choice survivable rather than
	corrupting.
]]
function Loadout.available(record: Record, petId: string, level: number): number
	return math.max(0, Loadout.ownedCount(record, petId, level) - Loadout.equippedCount(record, petId, level))
end

--[[
	Puts one owned copy into one named slot.

	REFUSES AN OCCUPIED SLOT rather than replacing what is in it. A swap is two
	decisions and the caller has made only one; silently dropping a companion because
	the player dragged something onto its square is the kind of helpfulness that loses
	a level 5.
]]
function Loadout.equip(record: Record, slotId: string, petId: string, level: number): (boolean, string?)
	if not Config.slot(slotId) then
		return false, `no slot is declared as "{slotId}"`
	end
	if not Loadout.isUnlocked(record, slotId) then
		return false, `slot "{slotId}" is locked`
	end
	if record.equipped[slotId] ~= nil then
		return false, `slot "{slotId}" already holds something`
	end
	if Loadout.available(record, petId, level) <= 0 then
		return false, `no spare {petId} at level {level} to equip`
	end
	record.equipped[slotId] = { petId = petId, level = level }
	return true
end

-- The convenience form: the first free slot, or a refusal naming why there is none.
function Loadout.equipAnywhere(record: Record, petId: string, level: number): (boolean, string?)
	local slotId = Loadout.freeSlot(record)
	if not slotId then
		return false, "every unlocked slot is full"
	end
	return Loadout.equip(record, slotId, petId, level)
end

function Loadout.unequip(record: Record, slotId: string): boolean
	if record.equipped[slotId] == nil then
		return false
	end
	record.equipped[slotId] = nil
	return true
end

function Loadout.unequipAll(record: Record)
	table.clear(record.equipped)
end

-- ──────────────────────────────────────────────────── keeping it consistent ──

--[[
	Empties slots that cannot legitimately hold what they hold. Returns how many were
	cleared.

	Three ways a slot goes wrong, and all three are ordinary rather than exceptional:
	the slot id is no longer declared (a Config change), the slot is not unlocked for
	this player (a relock, or a slot that used to be free), or the copy standing in it
	does not exist any more (a merge or a trade consumed it).

	CALLED AFTER EVERY OWNERSHIP OR SLOT CHANGE, which is what makes `moveCopies` safe
	to expose as a raw primitive: an addon that consumes a copy the player had out gets
	a companion unequipped, not a phantom one still standing there.

	Walked in DECLARED order, which is what makes the survivor the slot the player
	arranged FIRST: the earliest slot is counted before the later ones, so it is the one
	still inside the owned count when copies run short. Walking backwards keeps the last
	slot instead -- easy to write by accident, and the opposite of what a player expects
	when a merge eats two of their three.
]]
function Loadout.reconcile(record: Record): number
	local cleared = 0
	local kept: { [string]: number } = {}

	local slotIds = Config.slotIds()
	for _, slotId in slotIds do
		local entry = record.equipped[slotId]
		if entry then
			if not Loadout.isUnlocked(record, slotId) then
				record.equipped[slotId] = nil
				cleared += 1
			else
				local key = `{entry.petId}@{entry.level}`
				local seen = (kept[key] or 0) + 1
				if seen > Loadout.ownedCount(record, entry.petId, entry.level) then
					record.equipped[slotId] = nil
					cleared += 1
				else
					kept[key] = seen
				end
			end
		end
	end

	-- Anything sitting under an id Config no longer declares. Swept separately because
	-- the loop above only visits declared slots -- which is the point of it.
	local declared: { [string]: true } = {}
	for _, slotId in slotIds do
		declared[slotId] = true
	end
	for slotId in record.equipped do
		if not declared[slotId] then
			record.equipped[slotId] = nil
			cleared += 1
		end
	end

	return cleared
end

--[[
	Coerces whatever came back from persistence into a Record.

	NOTHING LOADED IS TRUSTED. A record has been through a DataStore, an older build of
	the game, and possibly a hand edit, so every field is checked and anything
	unrecognisable is dropped rather than carried forward as a nil that surfaces three
	calls later.

	The level ladder is accepted in EITHER shape -- a dense array, or a dictionary keyed
	by the strings a JSON round trip produces -- and normalised to the array. That is
	not defensive padding for its own sake: it is the exact failure the header warns
	about, so a record written by anything that got it wrong is repaired on load instead
	of reading as an empty collection.

	Slot ids are NOT checked against Config here. A record loaded while a slot happens
	to be undeclared must not lose it -- a Config file mid-edit, or a rollback, would
	otherwise quietly delete a player's loadout. `reconcile` empties those slots without
	forgetting them.
]]
function Loadout.sanitise(raw: any): Record
	local record = Loadout.newRecord()
	if type(raw) ~= "table" then
		return record
	end

	if type(raw.owned) == "table" then
		for petId, levels in raw.owned do
			if type(petId) ~= "string" or type(levels) ~= "table" then
				continue
			end
			local rebuilt: { number } = {}
			for key, value in levels do
				-- tonumber covers both 2 and "2"; a key that is neither is not a level.
				local level = tonumber(key)
				local count = tonumber(value)
				if level and count and level >= 1 and count >= 1 then
					setCount(rebuilt, math.floor(level), math.floor(count))
				end
			end
			if #rebuilt > 0 then
				record.owned[petId] = rebuilt
			end
		end
	end

	if type(raw.equipped) == "table" then
		for slotId, entry in raw.equipped do
			if type(slotId) ~= "string" or type(entry) ~= "table" then
				continue
			end
			local petId = entry.petId
			local level = tonumber(entry.level)
			if type(petId) == "string" and level and level >= 1 then
				record.equipped[slotId] = { petId = petId, level = math.floor(level) }
			end
		end
	end

	if type(raw.unlocked) == "table" then
		for slotId, value in raw.unlocked do
			if type(slotId) == "string" and value then
				record.unlocked[slotId] = true
			end
		end
	end

	return record
end

return Loadout
