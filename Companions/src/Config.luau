--!strict

-- Pet system tuning. Every value the other Companions modules read lives here, so a
-- host game only ever edits this file. Nothing in this folder requires anything outside
-- of it — the whole directory is meant to be copied between projects as-is.
--
-- Instance paths
--   assetFolderName   Folder under ReplicatedStorage holding the pet models. One Model per pet and the
--                     Model's Name is its pet id. Subfolders are walked too and become the category.
--   containerName     Folder created under Workspace that parents every live pet.
--   catalogFolderName Folder created under ReplicatedStorage listing the loaded pet ids, one
--                     StringValue per pet (Name = id, Value = category). Lets client code and
--                     tooling enumerate pets without a remote; the models stay server-side.
--                     nil skips publishing entirely.
--   slotFolderName    Folder/Model under the character holding the slot markers (the position schema).
--   slotNamePrefix    Second-choice schema: Attachments anywhere in the character named with this prefix.
--   collisionGroup    Applied to every pet part when a group of that name exists. nil = leave default.
--
-- Slot generation — only used when the character carries no schema at all
--   generatedSlotCount    how many attachments to build on the character root
--   generatedSlotRadius   ring radius in studs, measured from the root part
--   generatedSlotHeight   ring height above the root part, so pets sit in the air
--   generatedHeightJitter / generatedAngleJitter  per-slot randomness, drawn from the caller's Random
--
-- Equipping
--   slots             the loadout's slots, declared by id. See the Slots section.
--
-- Per-pet settings — Config.defaults, overridable per pet id through Config.pets
--   followMode        how the pet moves with its owner. See the FollowMode note below.
--   anchorOffset      local point of the pet's root part that gets pinned to the slot; +Y lowers the pet
--   scale             Model:ScaleTo value; nil keeps the model's authored size
--   responsiveness / maxForce                     AlignPosition tuning (Constraint mode only)
--   orientationResponsiveness / maxTorque         AlignOrientation tuning (Constraint mode only)
--   bobAmplitude / bobFrequency  vertical idle bob, in studs and cycles per second.
--                                bobAmplitude = 0 means the pet is skipped by the per-frame loop entirely.
--   loopAnimation     nil (the default) plays a loop IF there is one to play, so supplying an
--                     animationId is enough on its own. false leaves the model static even when
--                     an animation is authored; true warns when there is none to find.
--   animationId       rbxassetid to load; nil means "use an Animation instance inside the model"
--   animationName     name of that Animation instance; nil means "first Animation found in the model"
--   actionFadeTime    crossfade, in seconds, between the idle loop and a one-shot action
--   animationSpeed    AnimationTrack:AdjustSpeed value
--   networkOwner      "Player" lets the owner's client simulate the pet (smoothest for them, since the
--                     character it follows is client-simulated too), "Server" keeps simulation on the
--                     server, "Auto" leaves Roblox's own assignment alone
--   tickInterval      overrides the interval passed to setTick, so a level can change how often the
--                     pet acts. nil keeps the interval the host registered.
--
-- Levels — Config.pets[petId], normally filled in by the host through Companions.definePet
--   settings   the pet's base overrides, in effect at Config.baseLevel
--   levels     what each level changes. Entries stack: resolving level N applies 1..N in order, so
--              an entry only has to list what is different about that level, and a value set at
--              level 2 still holds at level 3 unless level 3 restates it.
--   maxLevel   caps levelling. Defaults to #levels, so a purely hook-driven pet with no level
--              entries has to say how high it goes.
--
-- Every field above is re-read on a level change and applied to the live pet, so a level that
-- changes `scale` resizes the model and one that changes `tickInterval` re-paces it, with no work
-- from the host. followMode and networkOwner decide how the pet is attached in the first place and
-- so only take effect the next time it spawns.

--[[
	How a pet moves with its owner.

	  Float     AlignPosition + AlignOrientation onto the character's slot attachment. The
	            pet hangs in the air beside its owner and does not collide with anything.
	  Ground    the same constraints, but aimed at the point on the ground BELOW the slot
	            rather than at the slot itself, so the pet walks along the floor. Found by
	            a downward ray on a throttled cadence -- not by making the pet collide and
	            letting gravity hold it down, which would need a collision group this
	            package cannot create and would let pets shove each other and the player.
	  Weld      rigidly locked to the slot. No drift, no lag, no life.
	  Detached  no attachment claimed and no constraints at all. This package spawns it,
	            despawns it with the slot and the character, and otherwise leaves it alone:
	            moving it is the host's, which is what makes a stationary turret, a mount or
	            a vehicle expressible. Use setPhysics to make it collidable or queryable.
]]
export type FollowMode = "Float" | "Ground" | "Weld" | "Detached"
export type NetworkOwner = "Player" | "Server" | "Auto"

-- Fully resolved settings for one pet at one level. Config.defaults is the only complete
-- literal; everything else is a sparse override of it.
export type PetSettings = {
	followMode: FollowMode,
	anchorOffset: Vector3,
	scale: number?,
	responsiveness: number,
	maxForce: number,
	orientationResponsiveness: number,
	maxTorque: number,
	bobAmplitude: number,
	bobFrequency: number,
	loopAnimation: boolean?,
	animationId: string?,
	animationName: string?,
	-- Crossfade when an action takes over from the idle loop and when it hands back. Short
	-- enough to read as a reaction, long enough not to snap.
	actionFadeTime: number,
	animationSpeed: number,
	networkOwner: NetworkOwner,
	tickInterval: number?,
}

export type PetOverrides = {
	followMode: FollowMode?,
	anchorOffset: Vector3?,
	scale: number?,
	responsiveness: number?,
	maxForce: number?,
	orientationResponsiveness: number?,
	maxTorque: number?,
	bobAmplitude: number?,
	bobFrequency: number?,
	loopAnimation: boolean?,
	animationId: string?,
	animationName: string?,
	actionFadeTime: number?,
	animationSpeed: number?,
	networkOwner: NetworkOwner?,
	tickInterval: number?,
}

-- One pet's content: its base settings and, optionally, what each level changes.
export type PetEntry = {
	settings: PetOverrides?,
	levels: { PetOverrides }?,
	maxLevel: number?,
}

local Config = {}

-- ── Instance paths ────────────────────────────────────────────────────────────

Config.assetFolderName = "Pets"
-- Not "Pets": a game staging its art in a folder by that name would end up with the live pets
-- parented inside its own source models. The live container wants a name nothing else is likely to
-- own, and this one is observed to bite.
Config.containerName = "LivePets"
Config.catalogFolderName = "PetCatalog" :: string?
Config.slotFolderName = "PetAttachments"
Config.slotNamePrefix = "PetSlot"
Config.collisionGroup = nil :: string?

--[[
	Attribute written on every live pet's Model holding that pet's current level; nil skips publishing,
	like `catalogFolderName`.

	THE ONLY ROUTE A PER-BODY LEVEL HAS TO A CLIENT. A host can mirror "this companion's level" onto
	the Player easily enough, and that was sufficient while every copy of a companion
	stood at one level — but ownership is a count PER LEVEL, so two of the same kind
	may be out at different ones and there is no single number to
	mirror and the fact belongs on the body it describes. Attributes replicate with the model, so a
	client that has found the rig has already been told.
]]
Config.levelAttribute = "PetLevel" :: string?

-- ── Slot generation fallback ──────────────────────────────────────────────────

Config.generatedSlotCount = 6
Config.generatedSlotRadius = 4
Config.generatedSlotHeight = 4
Config.generatedHeightJitter = 0.75
Config.generatedAngleJitter = 0.35 -- radians, applied either side of the even ring spacing

-- ── Ground mode ───────────────────────────────────────────────────────────────

--[[
	Where "the ground" is, for a Ground-mode pet.

	  groundOffset    how far above the surface the pet's anchor sits, in studs. Raise it for
	                  a rig whose authored origin is at its feet rather than its middle.
	  groundDistance  how far down to look from the slot before giving up. A pet over a
	                  chasm keeps its last known height rather than diving after the floor.
	  groundInterval  seconds between ground re-checks. NOT every frame: the floor under a
	                  running player changes slowly compared to 60Hz, and one ray per pet per
	                  frame is a cost with nothing to show for it. The pet still moves
	                  smoothly between checks, because the constraint interpolates -- only
	                  the TARGET is stepped.
]]
Config.groundOffset = 1.5
Config.groundDistance = 64
Config.groundInterval = 0.1

-- ── Slots ─────────────────────────────────────────────────────────────────────

--[[
	The loadout's slots, DECLARED AND IDENTIFIED rather than counted.

	A companion is equipped INTO a named slot, and the record says which. That costs a
	little more than a count and buys everything a count cannot express: a slot that is
	always the left shoulder, a slot unlocked by one route and not another, a UI that
	draws the third square greyed out, an ability that reads "whatever is in slot 1".
	None of those can be recovered later from a number, and a library cannot know which
	of them the next game wants.

	  order              display and allocation order. Ties break by id, so the order is
	                     always total and never depends on table iteration.
	  unlockedByDefault  free for everybody. A record stores only EXPLICIT unlocks, so
	                     making a slot free later lifts every existing player at once,
	                     with nothing to migrate.
	  attachment         pins this slot to a character attachment BY NAME, so "slot 2 is
	                     the left shoulder" holds across respawns. nil takes the next
	                     free attachment the character's schema offers.

	THERE IS NO SEPARATE CAP. How many companions a player may field is how many unlocked
	slots they have, full stop. A second number would be a second answer to one question,
	and the two would eventually disagree.
]]
export type SlotDefinition = {
	order: number,
	unlockedByDefault: boolean?,
	attachment: string?,
}

-- Three slots, the first free. A default so the package works before a host has said
-- anything; replace it wholesale with Companions.defineSlot / clearSlots.
Config.slots = {
	Slot1 = { order = 1, unlockedByDefault = true },
	Slot2 = { order = 2 },
	Slot3 = { order = 3 },
} :: { [string]: SlotDefinition }

-- Ordered ids. Sorted by `order` then by id, so the sequence is total and stable no
-- matter how the table was built.
function Config.slotIds(): { string }
	local ids: { string } = {}
	for slotId in Config.slots do
		table.insert(ids, slotId)
	end
	table.sort(ids, function(a, b)
		local orderA, orderB = Config.slots[a].order, Config.slots[b].order
		if orderA == orderB then
			return a < b
		end
		return orderA < orderB
	end)
	return ids
end

function Config.slot(slotId: string): SlotDefinition?
	return Config.slots[slotId]
end

-- Every pet spawns here. A pet that respawns comes back at the level its owned copy
-- stands at; this is the floor for anything the host has not levelled.
Config.baseLevel = 1

-- ── Per-pet settings ──────────────────────────────────────────────────────────

Config.defaults = {
	followMode = "Float",
	anchorOffset = Vector3.zero,
	scale = nil,
	responsiveness = 25,
	maxForce = 100000,
	orientationResponsiveness = 15,
	maxTorque = 100000,
	bobAmplitude = 0,
	bobFrequency = 1,
	loopAnimation = nil,
	animationId = nil,
	animationName = nil,
	actionFadeTime = 0.1,
	animationSpeed = 1,
	networkOwner = "Player",
	tickInterval = nil,
} :: PetSettings

-- Per-pet content, keyed by the model's Name. Left empty on purpose: a host game fills it through
-- Companions.definePet so its pets stay in its own code and this package ships with none.
-- Unlisted pets use the defaults untouched, which is what makes dropping a model into the asset
-- folder enough to ship it.
Config.pets = {} :: { [string]: PetEntry }

-- Copied field by field through a string index so adding a setting to PetSettings needs no change
-- here; both sides are the same shape by construction.
local function merge(target: { [string]: any }, overrides: PetOverrides?)
	if not overrides then
		return
	end
	for key, value in (overrides :: any) :: { [string]: any } do
		target[key] = value
	end
end

-- How high this pet can go. Level entries define the cap unless the pet states one, so a pet whose
-- levels only exist inside a host's level hook must set maxLevel itself.
function Config.maxLevel(petId: string): number
	local entry = Config.pets[petId]
	if not entry then
		return Config.baseLevel
	end
	if entry.maxLevel then
		return math.max(Config.baseLevel, math.floor(entry.maxLevel))
	end
	local levels = entry.levels
	return if levels then math.max(Config.baseLevel, #levels) else Config.baseLevel
end

-- Defaults merged with the pet's base overrides, then with every level entry up to `level`.
-- Callers always get a complete PetSettings, so no downstream code has to nil-check a tuning value.
function Config.resolve(petId: string, level: number?): PetSettings
	local settings = table.clone(Config.defaults)
	local entry = Config.pets[petId]
	if not entry then
		return settings
	end

	local target = (settings :: any) :: { [string]: any }
	merge(target, entry.settings)

	local levels = entry.levels
	if levels then
		-- Entries stack, so levelling is expressed as "what changes at this level". Levels past the
		-- last entry keep the last entry's values, which is what lets maxLevel run higher than the
		-- table for pets whose remaining growth lives in a host hook.
		local highest = math.clamp(math.floor(level or Config.baseLevel), Config.baseLevel, #levels)
		for index = 1, highest do
			merge(target, levels[index])
		end
	end

	return settings
end

return Config
