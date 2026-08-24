--!strict

-- Generic companion/pet system. Server-owned: models are cloned out of ServerStorage,
-- parented into Workspace and replicated to everyone, so pets are visible to all players.
--
-- Drop-in contract — this folder requires nothing but its own modules, and every require in it
-- is relative, so it behaves like an installed package wherever it is parented (a Systems
-- folder, ServerPackages, anywhere). The host game only has to:
--   1. put pet models in the ReplicatedStorage folder named by Config.assetFolderName
--   2. call Companions.start() once from its server entry point
--   3. call Companions.equip(player, petId) whenever it decides a player owns a pet
--
-- Public API
--   start(options?)            options = { assetFolderName, persistence, collisionGroup }
--   setPersistence(adapter)    optional { load(player) -> any?, save(player, record) }
--   definePet(petId, entry)    the pet's settings and level table (Config.PetEntry). This is how
--                              a host declares its content without editing anything in here.
--   setTick(petId, interval, onTick)  run onTick every interval seconds (0 = every frame) for
--                              every live pet of that id, each on its own schedule. onTick gets
--                              one Ticker.TickContext table: player, petId, uid, model, root,
--                              slotKey, level, interval, dt, elapsed. Order does not matter — it
--                              applies to pets that are already out as well as future ones.
--                              A level carrying `tickInterval` overrides the interval given here.
--   clearTick(petId)           stop ticking that pet id
--   setLevelHook(petId, onLevelChanged)  called after a level change has been applied, for anything
--                              the config cannot express. Gets a LevelContext: player, petId, uid,
--                              model, root, slotKey, level, previousLevel, settings.
--   clearLevelHook(petId)
--   onEquippedChanged(listener)  (player, { petId }) on every change, including a persistence load
--   onLevelChanged(listener)   a LevelContext on every level change, whatever caused it. Any number
--                              of listeners, unlike setLevelHook's one slot per pet.
--   equip(player, petId)       -> boolean; false when the id is unknown or the cap is reached
--   equipRandom(player)        -> petId?; equips a random catalog entry
--   unequip(player, petId)     -> boolean
--   unequipAll(player)
--   getRecord(player)          -> a COPY of the collection (owned / equipped / unlocked)
--   grant(player, petId, level?, count?)   -> new count at that level
--   take(player, petId, level, count?)     -> (ok, reason?)
--   moveCopies(player, petId, from, to, count?)  -> (ok, reason?); the addons' primitive
--   ownedCount / ownedLevels / totalOwned / ownedIds / available
--   defineSlot(slotId, definition) / clearSlots()
--   unlockSlot / relockSlot / isSlotUnlocked / unlockedSlots / lockedSlots
--   nextLockedSlot(player)     -> the first slot still to be earned
--   freeSlot(player)           -> the first unlocked slot with nothing in it
--   equip(player, slotId, petId, level?)   -> (ok, reason?); refuses an occupied slot
--   equipAnywhere(player, petId, level?)   -> (ok, reason?)
--   unequip(player, slotId) / unequipAll(player)
--   equippedAt(player, slotId) -> { petId, level }?
--   equippedSlots(player)      -> { slotId }, in declared order
--   slotOf(player, petId, level?)  -> slotId?
--   onSpawned(listener) / onDespawned(listener)   per LIVE PET, keyed by uid -- where
--                              host-side state like health, nameplates or VFX belongs
--   getPet(player, slotId)     -> the live rig, for moving a Detached companion
--   playAction(player, slotId, animationId, speed?, fadeTime?)  -> boolean
--   stopAction / isPlayingAction(player, slotId)
--   setPhysics(player, slotId, { canCollide?, canQuery?, canTouch?, anchored? })
--   setRaycast(fn?)            replace how Ground mode finds the floor
--   getMaxLevel(petId)         -> number
--   getCatalogIds()            -> { petId }
--   reloadCatalog()            -> number; re-reads the asset folder after models are added
--   refreshSlots(player)       re-reads the character's slot schema and re-seats live pets
--   getSlotSource(player)      -> "Folder" | "Prefix" | "Generated" | nil, for diagnostics
--
-- Equipped ids live in memory. Wire the persistence adapter to whatever datastore the host
-- game already uses and equipping survives rejoins; leave it unset and pets are session-only.
--
-- Levels are deliberately not part of any of that. A pet spawns at Config.baseLevel every time,
-- including on respawn, and nothing here stores a level anywhere — levelling is something a run
-- does to the pet in front of you, not progression to carry between them.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Catalog = require(script.Catalog)
local Config = require(script.Config)
local Rig = require(script.Rig)
local Slots = require(script.Slots)
local Loadout = require(script.Loadout)
local Ticker = require(script.Ticker)

--[[
	Where a player's collection lives. The RECORD is the unit -- what they own, what is
	in which slot, which slots they unlocked -- because ownership and the loadout
	constrain each other and two adapters writing halves of one fact would eventually
	disagree about it.

	`load` may return anything at all: it is put through Loadout.sanitise, which repairs
	what it can and drops what it cannot. So a host may hand over a raw DataStore table
	without checking it first.
]]
export type Persistence = {
	load: ((player: Player) -> any?)?,
	save: ((player: Player, record: Loadout.Record) -> ())?,
}

export type StartOptions = {
	assetFolderName: string?,
	persistence: Persistence?,
	-- Applied to every part of every pet. A group the host has set non-collidable with everything is
	-- the only reliable way to stop a rig colliding: CanCollide is re-asserted by a Humanoid on its
	-- own root part, which is the part being driven.
	collisionGroup: string?,
}

-- Handed to a level hook after the new level's settings have already been applied to the pet.
export type LevelContext = {
	player: Player,
	petId: string,
	uid: string,
	model: Model,
	root: BasePart,
	slotKey: string?,
	level: number,
	previousLevel: number,
	settings: Config.PetSettings,
}

export type LevelHandler = (context: LevelContext) -> ()

--[[
	Fired on every level change, whatever caused it — setLevel, or a host's own reward path.

	Separate from setLevelHook, which is ONE handler per pet id and belongs to whatever gives that
	companion its special behaviour. A host mirroring levels somewhere needs to hear about all of them
	without taking that slot away, and a mirror built on the hook would go stale the day someone
	registered a hook for their own reasons.
]]
export type LevelListener = (context: LevelContext) -> ()

-- Fired whenever a player's equipped set changes, for hosts that mirror it somewhere — a loadout
-- UI, a quest condition. Gets a copy, so a listener cannot rewrite the real set.
-- Handed a COPY of the record, so a listener cannot mutate the collection it is
-- being told about.
export type RecordListener = (player: Player, record: Loadout.Record) -> ()

--[[
	One live pet, at the moment it appears or disappears.

	`slotId` is the LOADOUT slot -- the one getPet, playAction and setPhysics take -- and not
	the character attachment the pet happens to sit on. `uid` is unique per live pet and is
	the key to hang per-pet state on: it changes when a pet respawns, which is exactly when
	state about the previous body should stop applying.
]]
export type PetContext = {
	player: Player,
	petId: string,
	uid: string,
	slotId: string,
	model: Model,
	root: BasePart,
	level: number,
	settings: Config.PetSettings,
}

export type PetListener = (context: PetContext) -> ()

export type PetInfo = {
	uid: string,
	petId: string,
	level: number,
	slotKey: string?,
}

type PlayerState = {
	-- The persisted collection. `record.equipped` is what SHOULD be out; `rigs` is what
	-- is. syncPets is the only thing that closes the gap.
	record: Loadout.Record,
	rigs: { [string]: Rig.Rig }, -- uid → live pet
	bySlot: { [string]: string }, -- loadout slotId → uid of the pet serving it
	-- loadout slotId → the character attachment it last used, so a respawn puts the
	-- same slot back in the same place. Keyed by the LOGICAL slot, not by pet id: two
	-- copies of one companion are in two slots and must not fight over one position.
	attachments: { [string]: string },
	slots: Slots.SlotSet?, -- nil while the player has no living character
}

local Companions = {}

local _state: { [Player]: PlayerState } = {}
local _persistence: Persistence? = nil
local _container: Folder? = nil
local _rng = Random.new()
local _uidCounter = 0
local _started = false
local _levelHooks: { [string]: LevelHandler } = {}
local _levelListeners: { LevelListener } = {}
local _equippedListeners: { RecordListener } = {}
local _spawnedListeners: { PetListener } = {}
local _despawnedListeners: { PetListener } = {}

-- Only pets with a non-zero bobAmplitude land here, so the default configuration never
-- connects the per-frame loop at all.
-- Pets needing per-frame attention: the ones that bob, the ones that walk on the ground,
-- or both. A pet that does neither -- the default -- never reaches this list, so the
-- default configuration connects no per-frame work at all.
local _driven: { Rig.Rig } = {}
local _driveConnection: RBXScriptConnection? = nil

-- ── Container ─────────────────────────────────────────────────────────────────

local function container(): Folder
	local existing = _container
	if existing and existing.Parent then
		return existing
	end
	local found = workspace:FindFirstChild(Config.containerName)
	if found and found:IsA("Folder") then
		_container = found
		return found
	end
	local folder = Instance.new("Folder")
	folder.Name = Config.containerName
	folder.Parent = workspace
	_container = folder
	return folder
end

-- One folder per player keeps ownership obvious in the explorer and makes teardown a
-- single Destroy when they leave.
local function playerContainer(player: Player): Folder
	local root = container()
	local name = tostring(player.UserId)
	local existing = root:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = root
	return folder
end

-- ── Ground mode ───────────────────────────────────────────────────────────────

--[[
	Where the floor is, under a point. Injectable.

	A DOWNWARD RAY AND NOT GRAVITY. Letting a ground pet fall onto the floor would mean
	making it collide with the world, which needs a collision group this package cannot
	create -- and a collidable pet shoves its owner, shoves other pets, and gets wedged in
	doorways. Aiming the existing constraint at a point found by a ray keeps the pet as
	inert as a floating one, and keeps the whole mode testable without a physics world.

	Replaceable because "where is the floor" is a question about the world, and a game with
	a voxel terrain or a moving platform layer answers it better than a raycast does.
]]
local _raycast: ((origin: Vector3, direction: Vector3) -> number?)? = nil

--[[
	Sets the ground finder. The function is handed a world origin and a downward vector and
	returns the surface's Y, or nil for "nothing down there".

	nil restores the default, which raycasts against everything except the pet container and
	the owner's own character -- a pet must not stand on itself or on the head of the player
	it is following.
]]
function Companions.setRaycast(finder: ((origin: Vector3, direction: Vector3) -> number?)?)
	_raycast = finder
end

local function defaultRaycast(origin: Vector3, direction: Vector3, ignore: { Instance }): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	local hit = workspace:Raycast(origin, direction, params)
	return if hit then hit.Position.Y else nil
end

--[[
	Steps one ground pet's target, if it is due for a look.

	Throttled rather than per-frame: the floor under a running player changes slowly next to
	60Hz, and a ray per pet per frame buys nothing. The pet still MOVES smoothly between
	checks, because the constraint interpolates toward the target -- only the target is
	stepped.
]]
local function stepGround(rig: Rig.Rig, now: number, character: Model?)
	local align = rig.alignPosition
	local anchorPart = rig.root
	if not align or anchorPart.Parent == nil then
		return
	end
	local settings = rig.settings
	if now - rig.groundCheckedAt < settings.groundInterval then
		return
	end
	rig.groundCheckedAt = now

	-- Above the slot, looking down: the slot is where the pet WOULD hang, so the floor
	-- below it is where it should stand.
	local from = align.Position
	local slotAttachment = rig.slotAttachment
	if slotAttachment and slotAttachment.Parent then
		from = slotAttachment.WorldPosition
	end

	local down = -Vector3.yAxis * settings.groundDistance
	local surface: number?
	if _raycast then
		surface = _raycast(from, down)
	else
		local ignore: { Instance } = { rig.model }
		if character then
			table.insert(ignore, character)
		end
		surface = defaultRaycast(from, down, ignore)
	end

	if surface then
		rig.groundY = surface
	end
	-- No floor found keeps the last known height: a pet crossing a gap should not dive
	-- after it, and the next check will find the far side.
	local y = rig.groundY
	align.Position = if y then Vector3.new(from.X, y + settings.groundOffset, from.Z) else from
end

-- ── Idle bob ──────────────────────────────────────────────────────────────────

--[[
	Tells listeners a pet appeared or is about to disappear.

	Spawned once per BODY and not once per equip, because a character respawn builds new
	rigs without the loadout changing at all -- a host that only heard about equips would
	initialise its per-pet state once and never again.

	Despawn fires BEFORE the model is destroyed, so a listener can read where the pet ended
	up. As everywhere else here, listeners are spawned rather than called: host code may
	yield, and must not be able to fail the spawn or the teardown that told it. The
	consequence is worth knowing -- a despawn listener that YIELDS resumes to find the model
	already destroyed, so anything it needs off the rig has to be read first.
]]
local function announce(listeners: { PetListener }, player: Player, slotId: string, rig: Rig.Rig)
	if #listeners == 0 then
		return
	end
	local context: PetContext = {
		player = player,
		petId = rig.petId,
		uid = rig.uid,
		slotId = slotId,
		model = rig.model,
		root = rig.root,
		level = rig.level,
		settings = rig.settings,
	}
	for _, listener in listeners do
		task.spawn(listener, context)
	end
end

local function needsDriving(rig: Rig.Rig): boolean
	return rig.settings.bobAmplitude > 0 or rig.settings.followMode == "Ground"
end

local function stepDriven()
	debug.profilebegin("Companions.drive")
	local now = os.clock()
	for index = #_driven, 1, -1 do
		local rig = _driven[index]
		if rig.anchor.Parent == nil then
			table.remove(_driven, index)
			continue
		end
		-- A level change can switch bobbing off or change the mode. Rig.applySettings has
		-- already parked the anchor back on its slot, so there is nothing left to drive.
		if not needsDriving(rig) then
			table.remove(_driven, index)
			continue
		end

		local settings = rig.settings
		if settings.bobAmplitude > 0 then
			local wave = math.sin(now * settings.bobFrequency * math.pi * 2 + rig.bobPhase)
			-- The anchor is the point pinned to the slot, so lowering it raises the pet.
			rig.anchor.Position = rig.bobBase - Vector3.yAxis * wave * settings.bobAmplitude
		end
		if settings.followMode == "Ground" then
			local owner = rig.owner
			stepGround(rig, now, if owner then owner.Character else nil)
		end
	end
	debug.profileend()

	if #_driven == 0 and _driveConnection then
		_driveConnection:Disconnect()
		_driveConnection = nil
	end
end

-- Idempotent: a level change re-offers pets that may already be bobbing.
local function addDriven(rig: Rig.Rig)
	if not needsDriving(rig) or table.find(_driven, rig) then
		return
	end
	table.insert(_driven, rig)
	if not _driveConnection then
		_driveConnection = RunService.Heartbeat:Connect(stepDriven)
	end
end

-- ── Spawning ──────────────────────────────────────────────────────────────────

local function nextUid(): string
	_uidCounter += 1
	return `pet{_uidCounter}`
end

local function despawnRig(state: PlayerState, uid: string)
	local rig = state.rigs[uid]
	if not rig then
		return
	end
	state.rigs[uid] = nil
	-- The slot this rig was serving is free again. Left behind, the stale uid would make
	-- syncPets believe the slot is still filled and it would never respawn.
	local served: string? = nil
	for slotId, servingUid in state.bySlot do
		if servingUid == uid then
			served = slotId
			state.bySlot[slotId] = nil
		end
	end
	local set = state.slots
	if set then
		Slots.release(set, uid)
	end
	Ticker.detach(rig)
	-- After detaching, so no tick can run inside a listener; before destroying, so a
	-- listener can still read the body.
	local owner = rig.owner
	if owner and served then
		announce(_despawnedListeners, owner, served, rig)
	end
	Rig.destroy(rig)
end

local function destroyRigs(state: PlayerState)
	for uid in state.rigs do
		despawnRig(state, uid)
	end
	-- Belt and braces: despawnRig unhooks each slot as it goes, so this is only here to
	-- make "no character, nothing serving anything" true even if a rig was removed by
	-- some other route.
	table.clear(state.bySlot)
end

--[[
	Publishes one rig's level onto its own model, as an attribute, for anyone on the client who has to
	draw it.

	**PER RIG, BECAUSE TWO OF ONE COMPANION NEED NOT MATCH.** Ownership is a count per
	level, so a player holding a level 1 and a level 3 Knight can field both, and
	"this companion's level" mirrored once somewhere on the Player would have to pick
	one of them. The only place a per-body fact can live where a client can read it is
	on the body. Attributes replicate with the model and arrive with it, so a client
	that finds the rig finds its level too — no folder to watch, no ordering to get wrong.

	Named by the host (`Config.levelAttribute`) and skipped entirely when that is nil, the same shape
	`catalogFolderName` uses: a game with no client-side interest in levels should not pay for the
	writes.
]]
local function publishLevel(rig: Rig.Rig)
	local name = Config.levelAttribute
	if name then
		rig.model:SetAttribute(name, rig.level)
	end
end

-- Spawns one pet onto a slot that has already been decided. Shared by the equip path (which claims a
-- slot from the character's schema) and the upgrade path (which makes its own beside the leader), so
-- the two cannot drift apart in how a pet is built.
-- `slot` is nil for a Detached pet, which claims no attachment; `origin` then says where to
-- put it and nothing moves it afterwards.
local function buildOn(
	player: Player,
	state: PlayerState,
	petId: string,
	slot: Slots.Slot?,
	level: number,
	origin: CFrame?
): Rig.Rig?
	local entry = Catalog.get(petId)
	if not entry then
		warn(`[Companions] No pet model named "{petId}"; nothing spawned.`)
		return nil
	end

	local uid = nextUid()
	local settings = Config.resolve(petId, level)
	local rig = Rig.build(entry, settings, slot, playerContainer(player), player, uid, _rng, level, origin)
	if not rig then
		return nil
	end

	state.rigs[uid] = rig
	publishLevel(rig)
	-- Bobbing, ground-walking, or neither: addDriven decides, so the caller does not have
	-- to know which concerns need a heartbeat.
	addDriven(rig)
	Ticker.attach(player, rig)
	return rig
end

--[[
	Puts the copy standing in one LOADOUT slot onto a character ATTACHMENT.

	The two are different things and conflating them is the bug this signature exists
	to prevent: a loadout slot is a persisted identity ("Slot2"), an attachment is a
	position on a character that dies with it. The mapping is remembered per loadout
	slot so a respawn puts the same slot back where it was, and a slot may pin itself to
	a named attachment for good.
]]
local function spawnPet(player: Player, state: PlayerState, slotId: string, entry: Loadout.Equipped): boolean
	local set = state.slots
	if not set then
		return false
	end

	--[[
		A DETACHED PET CLAIMS NO POSITION. It is not following anything, so taking one of the
		character's attachments would deny it to a pet that is -- and there would be nothing
		to attach it with anyway.

		It is placed where the character stands and then left alone. Everything else about it
		is ordinary: it fills a loadout slot, it ticks, and it despawns with the slot and with
		the character. Only its MOVEMENT is the host's.
	]]
	local rig: Rig.Rig?
	if Config.resolve(entry.petId, entry.level).followMode == "Detached" then
		rig = buildOn(player, state, entry.petId, nil, entry.level, set.root.CFrame)
		if rig then
			state.bySlot[slotId] = rig.uid
		end
	else
		-- A pinned attachment wins over wherever this slot happened to sit last.
		local definition = Config.slot(slotId)
		local preferred = (definition and definition.attachment) or state.attachments[slotId]

		-- Claimed before the rig is built so a build failure can hand the position back.
		local uid = nextUid()
		local slot = Slots.claim(set, uid, preferred)
		if not slot then
			warn(
				`[Companions] {player.Name} has no free pet position left`
					.. ` ({#set.slots} in the "{set.source}" schema).`
			)
			return false
		end

		rig = buildOn(player, state, entry.petId, slot, entry.level)
		if not rig then
			Slots.release(set, uid)
			return false
		end

		-- The position was claimed under a placeholder uid; move it onto the rig that took it.
		Slots.release(set, uid)
		set.occupied[slot.key] = (rig :: Rig.Rig).uid
		state.attachments[slotId] = slot.key
		state.bySlot[slotId] = (rig :: Rig.Rig).uid
	end

	if not rig then
		return false
	end
	-- One exit, so the spawn signal cannot be announced on one path and forgotten on the
	-- other -- which is exactly the bug a two-branch spawn invites.
	announce(_spawnedListeners, player, slotId, rig)
	return true
end

-- ── Levels ────────────────────────────────────────────────────────────────────

-- Moves one live pet to a level and puts the new settings into effect. Returns false when the pet
-- is already there, so callers can tell a real change from a no-op.
local function applyLevel(player: Player, rig: Rig.Rig, level: number): boolean
	local clamped = math.clamp(math.floor(level), Config.baseLevel, Config.maxLevel(rig.petId))
	if clamped == rig.level then
		return false
	end

	local previousLevel = rig.level
	rig.level = clamped
	-- Everything the config can express is applied for free; the hook below is only for what it
	-- cannot.
	Rig.applySettings(rig, Config.resolve(rig.petId, clamped))

	-- The new level may have switched bobbing on, and the bob loop only drives pets it holds.
	addDriven(rig)
	-- Likewise for ticking: a pet that only starts acting at a higher level needs to be scheduled.
	-- The interval itself is read from rig.settings each tick, so it needs nothing here.
	Ticker.attach(player, rig)

	-- One body, not every copy of that companion. Two of the same kind may be out at
	-- different levels -- ownership is a count PER LEVEL -- so there is no pile to
	-- drag along.
	publishLevel(rig)

	-- Built once and shared by the pet's own hook and every listener: one level change is one event,
	-- and they all describe the same one.
	local context: LevelContext = {
		player = player,
		petId = rig.petId,
		uid = rig.uid,
		model = rig.model,
		root = rig.root,
		slotKey = rig.slotKey,
		level = clamped,
		previousLevel = previousLevel,
		settings = rig.settings,
	}

	local hook = _levelHooks[rig.petId]
	if hook then
		-- Spawned for the same reason tick handlers are: host code may yield, and it must not be
		-- able to fail the level change that called it.
		task.spawn(hook, context)
	end
	for _, listener in _levelListeners do
		task.spawn(listener, context)
	end

	return true
end

--[[
	Makes what is out match what the record says should be out. The only place rigs are
	created or destroyed for reasons other than a character dying.

	SLOT BY SLOT, which is what identified slots buy: a mismatch is answered per slot
	rather than by counting bodies, so the right pet is replaced when a slot changes and
	the others are left alone. A slot whose companion is merely at a different level is
	RETUNED rather than rebuilt -- an upgrade landing while the pet is out should be
	visible on it, not a despawn and a respawn.
]]
local function syncPets(player: Player, state: PlayerState)
	if not state.slots then
		return
	end

	-- Gone or moved: anything serving a slot the record no longer fills that way.
	for slotId, uid in state.bySlot do
		local entry = state.record.equipped[slotId]
		local rig = state.rigs[uid]
		if not rig then
			state.bySlot[slotId] = nil
		elseif not entry or entry.petId ~= rig.petId then
			despawnRig(state, uid)
			state.bySlot[slotId] = nil
		end
	end

	for slotId, entry in state.record.equipped do
		local uid = state.bySlot[slotId]
		local rig = if uid then state.rigs[uid] else nil
		if rig then
			if rig.level ~= entry.level then
				applyLevel(player, rig, entry.level)
			end
		else
			spawnPet(player, state, slotId, entry)
		end
	end
end

local function persist(player: Player, state: PlayerState)
	local adapter = _persistence
	local save = if adapter then adapter.save else nil
	if not save then
		return
	end
	-- xpcall rather than pcall: save returns nothing, so pcall would have no second value
	-- to carry the error message out in.
	xpcall(save, function(err: any)
		warn(`[Companions] persistence.save failed for {player.Name}: {err}`)
	end, player, state.record)
end

local function notifyEquipped(player: Player, state: PlayerState)
	for _, listener in _equippedListeners do
		-- Spawned: listener code may yield, and it must not be able to fail the equip that
		-- triggered it.
		task.spawn(listener, player, Loadout.sanitise(state.record))
	end
end

-- Persist and announce. Every path that changes what a player has equipped ends here, so a host
-- mirroring the set — a loadout UI, a quest condition — cannot miss one of them.
local function commitEquipped(player: Player, state: PlayerState)
	persist(player, state)
	notifyEquipped(player, state)
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

local function onCharacterAdded(player: Player, character: Model)
	local state = _state[player]
	if not state then
		return
	end

	-- Pets live in Workspace, not under the character, so they outlive it unless dropped here.
	destroyRigs(state)
	state.slots = nil

	-- Deferred so a host game that builds its slot schema from its own CharacterAdded
	-- handler gets to finish first; resolving now could miss it and generate a ring instead.
	task.defer(function()
		if _state[player] ~= state or player.Character ~= character or not character.Parent then
			return
		end
		local set = Slots.resolve(character, _rng)
		if not set then
			warn(`[Companions] {player.Name}'s character has no BasePart to attach pets to.`)
			return
		end
		state.slots = set
		syncPets(player, state)
	end)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Died:Connect(function()
			if _state[player] ~= state then
				return
			end
			destroyRigs(state)
			state.slots = nil
		end)
	end
end

local function onPlayerAdded(player: Player)
	if _state[player] then
		return
	end
	local state: PlayerState = { record = Loadout.newRecord(), rigs = {}, bySlot = {}, attachments = {}, slots = nil }
	_state[player] = state

	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		if _state[player] ~= state then
			return
		end
		destroyRigs(state)
		state.slots = nil
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end

	local adapter = _persistence
	if adapter and adapter.load then
		-- The adapter may yield on a datastore, so the character can arrive first. syncPets
		-- reconciles whatever the load produced against what is already spawned.
		local ok, loaded = pcall(adapter.load, player)
		if not ok then
			warn(`[Companions] persistence.load failed for {player.Name}: {loaded}`)
		elseif _state[player] == state then
			-- Whatever came back, however mangled. sanitise repairs the shapes a DataStore
			-- round trip breaks and drops what it cannot read; reconcile then empties slots
			-- that cannot legitimately hold what they hold -- a locked slot, an undeclared
			-- one, a copy that no longer exists.
			state.record = Loadout.sanitise(loaded)
			Loadout.reconcile(state.record)
			syncPets(player, state)
			-- Announced but NOT persisted: this is what was just loaded, so writing it back
			-- would be a save for every join. A host mirroring the collection still has to
			-- hear about it.
			notifyEquipped(player, state)
		end
	end
end

local function onPlayerRemoving(player: Player)
	local state = _state[player]
	if not state then
		return
	end
	persist(player, state)
	destroyRigs(state)
	_state[player] = nil

	local root = _container
	if root then
		local folder = root:FindFirstChild(tostring(player.UserId))
		if folder then
			folder:Destroy()
		end
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Safe to call before start(); the adapter is picked up by players who join afterwards.
function Companions.setPersistence(adapter: Persistence?)
	_persistence = adapter
end

-- Gives every pet of this id a repeating hook. Returns false if the registration was rejected
-- (see Ticker.define); the pet id does not have to exist in the catalog yet.
function Companions.setTick(petId: string, interval: number, onTick: Ticker.TickHandler): boolean
	if not Ticker.define(petId, interval, onTick) then
		return false
	end
	-- Pets of this id that are already spawned pick the hook up immediately, so a host game
	-- can register behaviour before or after equipping without a difference in result.
	for player, state in _state do
		for _, rig in state.rigs do
			if rig.petId == petId then
				Ticker.attach(player, rig)
			end
		end
	end
	return true
end

function Companions.clearTick(petId: string)
	Ticker.undefine(petId)
end

-- Declares a pet's settings and levels. Host content goes through here rather than into
-- Config.pets directly, so this package ships with no game's pets in it.
function Companions.definePet(petId: string, entry: Config.PetEntry): boolean
	if type(petId) ~= "string" or petId == "" then
		warn(`[Companions] definePet needs a pet id string.`)
		return false
	end
	Config.pets[petId] = entry

	-- Pets already out adopt the new definition at the level they are on, so calling this after
	-- something was equipped is not a different outcome from calling it first.
	for _, state in _state do
		for _, rig in state.rigs do
			if rig.petId == petId then
				Rig.applySettings(rig, Config.resolve(petId, rig.level))
				addDriven(rig)
			end
		end
	end
	return true
end

-- Runs after a level change has already been applied, for anything the config cannot express.
function Companions.setLevelHook(petId: string, onLevelChanged: LevelHandler): boolean
	if type(petId) ~= "string" or petId == "" then
		warn(`[Companions] setLevelHook needs a pet id string.`)
		return false
	end
	if type(onLevelChanged) ~= "function" then
		warn(`[Companions] setLevelHook for "{petId}" needs a function to run.`)
		return false
	end
	_levelHooks[petId] = onLevelChanged
	return true
end

function Companions.clearLevelHook(petId: string)
	_levelHooks[petId] = nil
end

-- Called on every change to a player's equipped set, including the one a persistence load makes.
function Companions.onEquippedChanged(listener: RecordListener)
	table.insert(_equippedListeners, listener)
end

-- Called on every level change, from any cause. Unlike setLevelHook there is no per-pet slot to
-- compete for, so a host can mirror levels without blocking a pet's own hook.
--[[
	Every time a pet APPEARS, including a character respawn -- which is the case an
	equip-only listener misses, because a respawn rebuilds bodies without the loadout
	changing.

	Where per-pet state belongs: health, a nameplate, a health bar, VFX. Key it on
	`context.uid`, which changes with each new body, so state about the previous one stops
	applying by construction.
]]
function Companions.onSpawned(listener: PetListener)
	table.insert(_spawnedListeners, listener)
end

--[[
	Every time a pet is about to DISAPPEAR -- unequipped, its copy consumed by a merge, its
	owner's character dying, or the player leaving.

	Fires before the model is destroyed so a listener can read where it ended up. A listener
	that yields resumes to find it gone, so read what you need first.
]]
function Companions.onDespawned(listener: PetListener)
	table.insert(_despawnedListeners, listener)
end

function Companions.onLevelChanged(listener: LevelListener)
	table.insert(_levelListeners, listener)
end

function Companions.getMaxLevel(petId: string): number
	return Config.maxLevel(petId)
end

-- The live pets, which is also how a caller finds the uid it needs to level one.
function Companions.getPets(player: Player): { PetInfo }
	local state = _state[player]
	if not state then
		return {}
	end
	local pets: { PetInfo } = {}
	for _, rig in state.rigs do
		table.insert(pets, { uid = rig.uid, petId = rig.petId, level = rig.level, slotKey = rig.slotKey })
	end
	return pets
end

function Companions.getLevel(player: Player, uid: string): number?
	local state = _state[player]
	local rig = if state then state.rigs[uid] else nil
	return if rig then rig.level else nil
end

function Companions.setLevel(player: Player, uid: string, level: number): boolean
	local state = _state[player]
	if not state then
		return false
	end
	local rig = state.rigs[uid]
	if not rig then
		return false
	end
	return applyLevel(player, rig, level)
end

function Companions.start(options: StartOptions?)
	if _started then
		warn(`[Companions] start() has already run; ignoring this call.`)
		return
	end
	_started = true

	local opts: StartOptions = options or {}
	if opts.persistence then
		_persistence = opts.persistence
	end
	if opts.collisionGroup then
		Config.collisionGroup = opts.collisionGroup
	end

	Catalog.load(opts.assetFolderName or Config.assetFolderName)
	container()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	-- Players who joined before start() ran still need their state built.
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

function Companions.reloadCatalog(): number
	return Catalog.load(Config.assetFolderName)
end

function Companions.getCatalogIds(): { string }
	return Catalog.ids()
end

--[[
	Every mutation ends here: the loadout is made consistent with what is owned, what is
	OUT is made to match the loadout, and the change is saved and announced.

	One funnel rather than three lines repeated at each call site, because the failure it
	prevents is silent -- a path that mutates and forgets to reconcile leaves a companion
	standing there with no copy behind it, and nothing complains until a save.
]]
local function afterChange(player: Player, state: PlayerState)
	Loadout.reconcile(state.record)
	syncPets(player, state)
	commitEquipped(player, state)
end

-- ── Ownership ─────────────────────────────────────────────────────────────────

--[[
	Adds copies to a player's collection. Returns the new count at that level, or nil
	when there is no state for that player.

	An unknown pet id WARNS but is granted anyway: ownership is a fact about the player,
	while the catalog is a fact about which models happen to have loaded, and refusing
	here would make a grant depend on asset timing. Equipping it will refuse, loudly.
]]
function Companions.grant(player: Player, petId: string, level: number?, count: number?): number?
	local state = _state[player]
	if not state then
		return nil
	end
	if not Catalog.get(petId) then
		warn(`[Companions] granting "{petId}", which has no model in the catalog; it cannot be equipped yet.`)
	end
	local now = Loadout.grant(state.record, petId, level or Config.baseLevel, count)
	afterChange(player, state)
	return now
end

-- Removes copies. Refuses rather than clamping, so a caller that has miscounted hears
-- about it instead of quietly taking what it can.
function Companions.take(player: Player, petId: string, level: number, count: number?): (boolean, string?)
	local state = _state[player]
	if not state then
		return false, "no state for that player"
	end
	local ok, reason = Loadout.take(state.record, petId, level, count)
	if ok then
		afterChange(player, state)
	end
	return ok, reason
end

--[[
	Moves copies up (or down) the ladder: `count` leave `fromLevel`, one arrives at
	`toLevel`.

	THE PRIMITIVE THE ADDONS SIT ON. Merging demands copies and paid upgrading demands
	currency, but both perform this same mutation -- so it lives here once and each addon
	supplies only its own rule for when it is allowed. Two addons owning two mutation
	paths would be two answers to "what does this player have".
]]
function Companions.moveCopies(
	player: Player,
	petId: string,
	fromLevel: number,
	toLevel: number,
	count: number?
): (boolean, string?)
	local state = _state[player]
	if not state then
		return false, "no state for that player"
	end
	local ok, reason = Loadout.moveCopies(state.record, petId, fromLevel, toLevel, count)
	if ok then
		afterChange(player, state)
	end
	return ok, reason
end

function Companions.ownedCount(player: Player, petId: string, level: number): number
	local state = _state[player]
	return if state then Loadout.ownedCount(state.record, petId, level) else 0
end

function Companions.ownedLevels(player: Player, petId: string): { number }
	local state = _state[player]
	return if state then Loadout.ownedLevels(state.record, petId) else {}
end

function Companions.totalOwned(player: Player, petId: string): number
	local state = _state[player]
	return if state then Loadout.totalOwned(state.record, petId) else 0
end

function Companions.ownedIds(player: Player): { string }
	local state = _state[player]
	return if state then Loadout.ownedIds(state.record) else {}
end

-- Owned minus already out. What an addon should spend, so a merge cannot eat the
-- companion the player is looking at.
function Companions.available(player: Player, petId: string, level: number): number
	local state = _state[player]
	return if state then Loadout.available(state.record, petId, level) else 0
end

-- A COPY of the collection. Read it, draw it, send it; mutating it changes nothing.
function Companions.getRecord(player: Player): Loadout.Record?
	local state = _state[player]
	return if state then Loadout.sanitise(state.record) else nil
end

-- ── Slots ─────────────────────────────────────────────────────────────────────

-- Declares a slot, or replaces a declaration. Slots are identified, so this is how a
-- host says how many exist, in what order, and which are free.
function Companions.defineSlot(slotId: string, definition: Config.SlotDefinition): boolean
	if type(slotId) ~= "string" or slotId == "" then
		warn("[Companions] defineSlot needs a non-empty string id.")
		return false
	end
	if type(definition) ~= "table" or type(definition.order) ~= "number" then
		warn(`[Companions] defineSlot("{slotId}") needs a definition with a numeric order.`)
		return false
	end
	Config.slots[slotId] = definition
	return true
end

-- Drops every declaration, including the defaults this package ships, for a host that
-- wants its own set rather than an addition to ours.
function Companions.clearSlots()
	table.clear(Config.slots)
end

function Companions.unlockSlot(player: Player, slotId: string): (boolean, string?)
	local state = _state[player]
	if not state then
		return false, "no state for that player"
	end
	local ok, reason = Loadout.unlock(state.record, slotId)
	if ok then
		afterChange(player, state)
	end
	return ok, reason
end

function Companions.relockSlot(player: Player, slotId: string): boolean
	local state = _state[player]
	if not state then
		return false
	end
	local ok = Loadout.relock(state.record, slotId)
	if ok then
		afterChange(player, state)
	end
	return ok
end

function Companions.isSlotUnlocked(player: Player, slotId: string): boolean
	local state = _state[player]
	return state ~= nil and Loadout.isUnlocked(state.record, slotId)
end

function Companions.unlockedSlots(player: Player): { string }
	local state = _state[player]
	return if state then Loadout.unlockedSlots(state.record) else {}
end

function Companions.lockedSlots(player: Player): { string }
	local state = _state[player]
	return if state then Loadout.lockedSlots(state.record) else Config.slotIds()
end

function Companions.nextLockedSlot(player: Player): string?
	local state = _state[player]
	return if state then Loadout.nextLocked(state.record) else nil
end

function Companions.freeSlot(player: Player): string?
	local state = _state[player]
	return if state then Loadout.freeSlot(state.record) else nil
end

-- ── The loadout ───────────────────────────────────────────────────────────────

--[[
	Puts one owned copy into one named slot.

	Refuses an OCCUPIED slot rather than replacing what is in it: a swap is two decisions
	and the caller has made one. Refuses an unknown pet id too -- a companion with no
	model cannot be fielded, whatever the collection says.
]]
function Companions.equip(player: Player, slotId: string, petId: string, level: number?): (boolean, string?)
	local state = _state[player]
	if not state then
		return false, "no state for that player"
	end
	if not Catalog.get(petId) then
		return false, `no pet model named "{petId}"`
	end
	local ok, reason = Loadout.equip(state.record, slotId, petId, level or Config.baseLevel)
	if ok then
		afterChange(player, state)
	end
	return ok, reason
end

-- The first free unlocked slot, in declared order.
function Companions.equipAnywhere(player: Player, petId: string, level: number?): (boolean, string?)
	local state = _state[player]
	if not state then
		return false, "no state for that player"
	end
	local slotId = Loadout.freeSlot(state.record)
	if not slotId then
		return false, "every unlocked slot is full"
	end
	return Companions.equip(player, slotId, petId, level)
end

--[[
	Grants a random catalogued companion if none is spare, then fields it.

	A convenience for hosts with no collection of their own yet -- equipping something
	unowned is refused by design, so this has to top the collection up first rather than
	sidestep it.
]]
function Companions.equipRandom(player: Player): string?
	local entry = Catalog.pick(_rng)
	local state = _state[player]
	if not entry or not state then
		return nil
	end
	if Loadout.available(state.record, entry.id, Config.baseLevel) <= 0 then
		Loadout.grant(state.record, entry.id, Config.baseLevel)
	end
	local ok = Companions.equipAnywhere(player, entry.id)
	return if ok then entry.id else nil
end

function Companions.unequip(player: Player, slotId: string): boolean
	local state = _state[player]
	if not state then
		return false
	end
	local ok = Loadout.unequip(state.record, slotId)
	if ok then
		afterChange(player, state)
	end
	return ok
end

function Companions.unequipAll(player: Player)
	local state = _state[player]
	if not state then
		return
	end
	Loadout.unequipAll(state.record)
	afterChange(player, state)
end

-- Copied: the caller is being told what is equipped, not handed the record's entry.
function Companions.equippedAt(player: Player, slotId: string): Loadout.Equipped?
	local state = _state[player]
	local entry = if state then Loadout.equippedAt(state.record, slotId) else nil
	return if entry then { petId = entry.petId, level = entry.level } else nil
end

function Companions.equippedSlots(player: Player): { string }
	local state = _state[player]
	return if state then Loadout.equippedSlots(state.record) else {}
end

function Companions.slotOf(player: Player, petId: string, level: number?): string?
	local state = _state[player]
	return if state then Loadout.slotOf(state.record, petId, level) else nil
end

-- ── Animation and physics ─────────────────────────────────────────────────────

-- The live pet serving a loadout slot, or nil when that slot is empty or the pet has not
-- spawned yet. What a host needs to move a Detached companion.
function Companions.getPet(player: Player, slotId: string): Rig.Rig?
	local state = _state[player]
	if not state then
		return nil
	end
	local uid = state.bySlot[slotId]
	return if uid then state.rigs[uid] else nil
end

--[[
	Plays a one-shot animation on the pet in a slot, over its idle loop, handing back to
	the loop when it finishes.

	BY SLOT AND NOT BY PET ID, because two copies of one companion may be out at once and
	"make the Knight swing" would not say which. A host that wants both asks twice.

	The loop is weighted out rather than stopped, so a pet that acts twice does not visibly
	reset its idle in between. A second action replaces the first: layering two one-shots
	produces a pose neither animation describes.
]]
function Companions.playAction(
	player: Player,
	slotId: string,
	animationId: string,
	speed: number?,
	fadeTime: number?
): boolean
	local rig = Companions.getPet(player, slotId)
	if not rig then
		return false
	end
	return Rig.playAction(rig, animationId, speed, fadeTime)
end

-- Cuts an action short. The loop comes back the same way it would have anyway, through the
-- track's Stopped -- one path back rather than two that could disagree.
function Companions.stopAction(player: Player, slotId: string)
	local rig = Companions.getPet(player, slotId)
	if rig then
		Rig.stopAction(rig)
	end
end

function Companions.isPlayingAction(player: Player, slotId: string): boolean
	local rig = Companions.getPet(player, slotId)
	return rig ~= nil and Rig.isPlayingAction(rig)
end

--[[
	Sets physics properties across every part of the pet in a slot.

	FOR DETACHED PETS, mostly. A following pet is decoration and is built inert on purpose:
	it must not block the host's raycasts or trip its collision handlers. A detached one may
	be a mount, a turret or a vehicle, and none of those work inert -- so the host says what
	it needs rather than this package guessing.

	Only the fields given are applied, so turning collision on does not silently also make
	the pet queryable.
]]
function Companions.setPhysics(player: Player, slotId: string, spec: Rig.PhysicsSpec): boolean
	local rig = Companions.getPet(player, slotId)
	if not rig then
		return false
	end
	Rig.setPhysics(rig, spec)
	return true
end

-- For hosts that add or move slot markers after the character spawned.
function Companions.refreshSlots(player: Player)
	local state = _state[player]
	if not state then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	destroyRigs(state)
	state.slots = Slots.resolve(character, _rng)
	syncPets(player, state)
end

function Companions.getSlotSource(player: Player): Slots.SlotSource?
	local state = _state[player]
	local set = if state then state.slots else nil
	return if set then set.source else nil
end

return Companions
