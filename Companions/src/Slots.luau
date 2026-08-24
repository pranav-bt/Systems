--!strict

-- Resolves where a character's pets are allowed to sit, and tracks which of those
-- positions are taken. Three schemas are tried in order:
--
--   1. "Folder"    a Folder/Model named Config.slotFolderName under the character. Every
--                  Attachment inside it is a slot; a BasePart with no Attachment of its own
--                  is a slot too (designers usually place invisible marker parts).
--   2. "Prefix"    any Attachment in the character whose name starts with Config.slotNamePrefix.
--   3. "Generated" no schema exists, so a ring of attachments is built around the character
--                  root with randomised angles and heights. This path warns — it means the
--                  character rig is missing its schema, and pet placement is arbitrary.
--
-- Markers that are not already Attachments on a BasePart get materialised into real
-- Attachments on the root part: an Attachment only has a world CFrame when a BasePart
-- parents it, and physics constraints need that world CFrame.

local Config = require(script.Parent.Config)

export type SlotSource = "Folder" | "Prefix" | "Generated"

export type Slot = {
	key: string, -- stable per character, so a pet can ask for the position it had before respawning
	attachment: Attachment,
}

export type SlotSet = {
	source: SlotSource,
	root: BasePart,
	slots: { Slot },
	occupied: { [string]: string }, -- slot key → uid of the pet standing in it
}

local Slots = {}

-- Marks the attachments this module creates itself. Resolving a character twice has to
-- clear them first: they would otherwise pile up, and because generated slots are named
-- with slotNamePrefix they would pass as a hand-authored "Prefix" schema on the second
-- pass and silence the warning that the character has no schema at all.
local GENERATED_ATTRIBUTE = "PetServiceSlot"

-- ── Marker discovery ──────────────────────────────────────────────────────────

-- "Slot2" before "Slot10": markers are numbered by hand, so plain string order would
-- hand out positions in an order that looks scrambled to whoever built the rig.
local function naturalLess(a: string, b: string): boolean
	local aDigits = string.match(a, "%d+$")
	local bDigits = string.match(b, "%d+$")
	if aDigits and bDigits then
		local aStem = string.sub(a, 1, #a - #aDigits)
		local bStem = string.sub(b, 1, #b - #bDigits)
		if aStem == bStem then
			return (tonumber(aDigits) :: number) < (tonumber(bDigits) :: number)
		end
	end
	return a < b
end

local function findRoot(character: Model): BasePart?
	local named = character:FindFirstChild("HumanoidRootPart")
	if named and named:IsA("BasePart") then
		return named
	end
	if character.PrimaryPart then
		return character.PrimaryPart
	end
	return character:FindFirstChildWhichIsA("BasePart", true)
end

local function makeAttachment(root: BasePart, name: string, offset: CFrame): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = offset
	attachment:SetAttribute(GENERATED_ATTRIBUTE, true)
	attachment.Parent = root
	return attachment
end

local function clearGenerated(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Attachment") and descendant:GetAttribute(GENERATED_ATTRIBUTE) then
			descendant:Destroy()
		end
	end
end

-- Keys must be unique or occupancy bookkeeping collides; markers are named by hand
-- and duplicates are common enough to be worth handling quietly.
local function uniqueKey(taken: { [string]: boolean }, name: string): string
	if not taken[name] then
		taken[name] = true
		return name
	end
	local index = 2
	while taken[`{name}_{index}`] do
		index += 1
	end
	taken[`{name}_{index}`] = true
	return `{name}_{index}`
end

local function hasAttachment(part: BasePart): boolean
	return part:FindFirstChildWhichIsA("Attachment") ~= nil
end

local function fromContainer(container: Instance, root: BasePart): { Slot }
	local slots: { Slot } = {}
	local taken: { [string]: boolean } = {}

	local descendants = container:GetDescendants()
	table.sort(descendants, function(a: Instance, b: Instance)
		return naturalLess(a.Name, b.Name)
	end)

	for _, descendant in descendants do
		if descendant:IsA("Attachment") then
			local key = uniqueKey(taken, descendant.Name)
			local parent = descendant.Parent
			if parent and parent:IsA("BasePart") then
				table.insert(slots, { key = key, attachment = descendant })
			else
				-- Parented to the folder itself: its CFrame is only readable as an offset,
				-- so treat it as root-relative and rebuild it somewhere physics can use it.
				table.insert(slots, { key = key, attachment = makeAttachment(root, key, descendant.CFrame) })
			end
		elseif descendant:IsA("BasePart") and not hasAttachment(descendant) then
			-- Marker part: its own attachments would have been picked up above, so a part
			-- without any is standing in for a position itself.
			local key = uniqueKey(taken, descendant.Name)
			table.insert(
				slots,
				{ key = key, attachment = makeAttachment(root, key, root.CFrame:ToObjectSpace(descendant.CFrame)) }
			)
		end
	end

	return slots
end

local function fromPrefix(character: Model, prefix: string): { Slot }
	local matches: { Attachment } = {}
	for _, descendant in character:GetDescendants() do
		if not descendant:IsA("Attachment") then
			continue
		end
		if string.sub(descendant.Name, 1, #prefix) ~= prefix then
			continue
		end
		local parent = descendant.Parent
		if parent and parent:IsA("BasePart") then
			table.insert(matches, descendant)
		end
	end

	table.sort(matches, function(a: Attachment, b: Attachment)
		return naturalLess(a.Name, b.Name)
	end)

	local slots: { Slot } = table.create(#matches)
	local taken: { [string]: boolean } = {}
	for _, attachment in matches do
		table.insert(slots, { key = uniqueKey(taken, attachment.Name), attachment = attachment })
	end
	return slots
end

local function generate(root: BasePart, rng: Random): { Slot }
	local count = Config.generatedSlotCount
	local slots: { Slot } = table.create(count)
	local step = math.pi * 2 / count

	for index = 1, count do
		-- Even ring spacing with a jitter either side, so generated placement never looks
		-- like a deliberate formation that a designer might mistake for the real schema.
		local angle = (index - 1) * step + rng:NextNumber(-Config.generatedAngleJitter, Config.generatedAngleJitter)
		local height = Config.generatedSlotHeight
			+ rng:NextNumber(-Config.generatedHeightJitter, Config.generatedHeightJitter)
		local offset = Vector3.new(
			math.cos(angle) * Config.generatedSlotRadius,
			height,
			math.sin(angle) * Config.generatedSlotRadius
		)
		local key = `{Config.slotNamePrefix}{index}`
		-- Faces the same way the character does; pets keep the rig's forward direction.
		table.insert(slots, { key = key, attachment = makeAttachment(root, key, CFrame.new(offset)) })
	end

	return slots
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Returns nil when the character has no BasePart to work from, which happens if it is
-- called before the rig has replicated. Callers should retry on the next CharacterAdded.
function Slots.resolve(character: Model, rng: Random): SlotSet?
	local root = findRoot(character)
	if not root then
		return nil
	end
	clearGenerated(character)

	local container = character:FindFirstChild(Config.slotFolderName)
	if container then
		local slots = fromContainer(container, root)
		if #slots > 0 then
			return { source = "Folder", root = root, slots = slots, occupied = {} }
		end
	end

	local prefixed = fromPrefix(character, Config.slotNamePrefix)
	if #prefixed > 0 then
		return { source = "Prefix", root = root, slots = prefixed, occupied = {} }
	end

	warn(
		`[Companions] {character.Name} has no "{Config.slotFolderName}" schema and no "{Config.slotNamePrefix}*" `
			.. `attachments; generated {Config.generatedSlotCount} slots around the character root instead.`
	)
	return { source = "Generated", root = root, slots = generate(root, rng), occupied = {} }
end

function Slots.freeCount(set: SlotSet): number
	local free = 0
	for _, slot in set.slots do
		if not set.occupied[slot.key] then
			free += 1
		end
	end
	return free
end

-- Marks a position as taken by uid and hands it back. preferredKey lets a pet return to
-- the same position it held before the character respawned.
function Slots.claim(set: SlotSet, uid: string, preferredKey: string?): Slot?
	if preferredKey and not set.occupied[preferredKey] then
		for _, slot in set.slots do
			if slot.key == preferredKey then
				set.occupied[slot.key] = uid
				return slot
			end
		end
	end

	for _, slot in set.slots do
		if not set.occupied[slot.key] then
			set.occupied[slot.key] = uid
			return slot
		end
	end

	return nil
end

function Slots.release(set: SlotSet, uid: string)
	for key, occupant in set.occupied do
		if occupant == uid then
			set.occupied[key] = nil
		end
	end
end

return Slots
