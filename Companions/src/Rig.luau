--!strict

-- Builds one live pet: clones the catalog model, pins it to a slot attachment and
-- optionally starts a looping animation. Everything the rest of the system needs to
-- move or tear the pet down afterwards is returned in the Rig table.

local PhysicsService = game:GetService("PhysicsService")

local Catalog = require(script.Parent.Catalog)
local Config = require(script.Parent.Config)
local Slots = require(script.Parent.Slots)

export type Rig = {
	uid: string,
	petId: string,
	slotKey: string?, -- nil for a Detached pet, which claims no attachment
	level: number,
	settings: Config.PetSettings, -- resolved for `level`; re-resolved and re-applied on a change
	model: Model,
	root: BasePart,
	anchor: Attachment, -- point pinned to the slot; the bob loop animates its offset
	bobBase: Vector3,
	bobPhase: number, -- per-pet phase shift so a group of pets does not bob in lockstep
	-- The idle loop, playing for as long as the pet is out.
	track: AnimationTrack?,
	-- A one-shot action currently overriding the loop, and the Animation instances loaded
	-- for this rig so far, cached by asset id: LoadAnimation is cheap the second time but
	-- a fresh Animation instance per action would litter the model.
	actionTrack: AnimationTrack?,
	actionConnection: RBXScriptConnection?,
	animations: { [string]: Animation },
	-- Ground mode only: when the floor under this pet was last looked for, and where it
	-- was. Kept so a pet over a chasm holds its last known height instead of diving.
	groundCheckedAt: number,
	groundY: number?,
	-- The character attachment this pet is following. Held for Ground mode, which needs the
	-- slot's world position to look DOWN from -- its own AlignPosition target is the floor,
	-- so it cannot be asked where the slot is.
	slotAttachment: Attachment?,
	-- Who this pet follows. Held so per-frame work can reach the character without the
	-- caller threading a player through every step.
	owner: Player?,
	-- Kept so a level change can retune the follow without rebuilding the pet. nil in Weld mode.
	alignPosition: AlignPosition?,
	alignOrientation: AlignOrientation?,
	-- An attachment created FOR this pet rather than taken from the character's slot
	-- schema. NOTHING SETS THIS TODAY: it is the anchor a pet needs when it is not
	-- hanging off a character slot at all, which is what a ground-walking or fully
	-- detached follow mode will want. Kept rather than deleted because the teardown
	-- below is already correct for it, and re-deriving that is the expensive half.
	ownedAttachment: Attachment?,
}

local Rig = {}

-- ── Model preparation ─────────────────────────────────────────────────────────

local _collisionGroupResolved = false
local _collisionGroup: string? = nil

-- Assigning an unregistered collision group errors mid-spawn, so the configured name is
-- verified once and dropped with a warning if the host game never registered it.
local function collisionGroup(): string?
	if _collisionGroupResolved then
		return _collisionGroup
	end
	_collisionGroupResolved = true

	local name = Config.collisionGroup
	if not name then
		return nil
	end
	for _, group in PhysicsService:GetRegisteredCollisionGroups() do
		if group.name == name then
			_collisionGroup = name
			return _collisionGroup
		end
	end
	warn(`[Companions] Collision group "{name}" is not registered; pet parts keep the default group.`)
	return nil
end

local function findRoot(model: Model): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

--[[
	Every part the model's OWN joints already hold, reached from the root.

	A rig holds itself together through Motor6Ds, and its gear through Welds and WeldConstraints — so
	whether a part needs help is not a question about the MODEL, it is a question about that PART. This
	walks the joint graph outward from the root and reports what it reaches.

	Built from the joint instances rather than from `BasePart:GetConnectedParts`, which reads the
	physics engine's assemblies: at this point the model is a fresh clone that has never been parented
	to the world, so the engine has not assembled anything and that call answers "just me" for
	everything.
]]
local function jointedToRoot(model: Model, root: BasePart): { [BasePart]: boolean }
	local neighbours: { [BasePart]: { BasePart } } = {}
	local function link(a: Instance?, b: Instance?)
		if not a or not b or not a:IsA("BasePart") or not b:IsA("BasePart") then
			return
		end
		local first, second = a :: BasePart, b :: BasePart
		neighbours[first] = neighbours[first] or {}
		neighbours[second] = neighbours[second] or {}
		table.insert(neighbours[first], second)
		table.insert(neighbours[second], first)
	end

	--[[
		One branch for both, cast to reach `Part0`/`Part1`: a WeldConstraint is NOT a JointInstance, so
		both classes have to be named, but they carry the same two fields and the same meaning here.
	]]
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("JointInstance") or descendant:IsA("WeldConstraint") then
			local joint = descendant :: any
			link(joint.Part0, joint.Part1)
		end
	end

	local reached: { [BasePart]: boolean } = { [root] = true }
	local queue: { BasePart } = { root }
	while #queue > 0 do
		local part = table.remove(queue) :: BasePart
		local adjacent = neighbours[part]
		if adjacent then
			for _, next_ in adjacent do
				if not reached[next_] then
					reached[next_] = true
					table.insert(queue, next_)
				end
			end
		end
	end
	return reached
end

--[[
	Makes every part decoration, and attaches anything the rig does not already hold.

	THE WELD IS PER PART, NOT PER MODEL, and that is the fix for gear that drifts off a companion.
	This used to weld everything or nothing, on one question: does the model animate? Every companion
	has a Humanoid, so every one took the "animates, weld nothing" branch — correct for the limbs, and
	silently wrong for any part the artist left with no joint at all. Six of the fifteen ship one:
	`GuardPart` on five (an invisible plinth from the modelling scene) and `RocketPod1` on the Rogue
	Sorcerer, which is visible.

	Unanchored and held by nothing, those parts simply fall. Measured on a live rig: a jointed helm
	holds its offset to the head exactly, while an unjointed part goes from half a stud away to 450 in
	two and a half seconds — which on the way out reads as gear floating off the companion.

	Welding only the UNREACHED parts keeps the Motor6D limbs free to animate, which is what the old
	all-or-nothing test was protecting.
]]
local function prepareParts(model: Model, root: BasePart)
	local group = collisionGroup()
	local held = jointedToRoot(model, root)

	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		local part = descendant :: BasePart
		part.Anchored = false
		part.CanCollide = false
		-- Pets are decoration: they must not block the host game's raycasts or fire its
		-- Touched handlers, both of which would make equipping one change gameplay.
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		if group then
			part.CollisionGroup = group
		end
		if not held[part] then
			-- A WeldConstraint rather than a Weld: it captures the offset the part is already at, so
			-- this needs no arithmetic and cannot disagree with `ScaleTo`, which has run by now.
			local weld = Instance.new("WeldConstraint")
			weld.Name = "PetGearWeld"
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = root
		end
	end
end

-- ── Accessories ───────────────────────────────────────────────────────────────

--[[
	Puts a scaled companion's hat back on its head. THE FLOATING-HELMET FIX.

	Every one of these rigs wears its headgear as a legacy `Hat` (an Accoutrement), and that weld is the
	ENGINE'S, not the artist's: it builds a `HeadWeld` whose C1 mirrors the accessory's
	`AttachmentPoint` and whose C0 is a LIFT that puts the hat on top of the skull instead of inside it.

	`ScaleTo` scales both of those correctly. What it cannot do is stop the engine from REBUILDING the
	weld when the rig enters the DataModel, and the rebuild writes the lift for a full-size head — half
	a stud — no matter how small the head now is. A companion at 0.26 therefore wears its helm half a
	stud above a 0.26-stud head: roughly one head-height of daylight, which is the floating hat. Nothing
	else about it is wrong, which is why it reads as floating rather than as broken.

	So the lift is re-derived from the head the hat is actually sitting on rather than scaled from
	whatever the weld currently says. That makes this idempotent and free of any assumption about when
	the engine last touched the weld — the two things the first attempt at this got wrong, because a
	correction applied BEFORE parenting is simply discarded by the rebuild.
]]
local function reseatAccessories(model: Model)
	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end

	-- Gathered in one pass and matched afterwards rather than asked for per handle: `GetJoints` reports
	-- nothing on a model that is not in the DataModel yet, and a freshly cloned rig is exactly that.
	local handles: { [BasePart]: true } = {}
	local welds: { Weld } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Accoutrement") then
			local handle = descendant:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") then
				handles[handle :: BasePart] = true
			end
		elseif descendant:IsA("Weld") then
			table.insert(welds, descendant :: Weld)
		end
	end

	for _, weld in welds do
		-- Head-to-hat in that order: C0 is the head's half of the joint, and only its lift is wrong. A
		-- weld holding a handle the other way round is the artist's and not ours to touch.
		local part1 = weld.Part1
		if weld.Part0 ~= head or not (part1 and handles[part1]) then
			continue
		end
		-- Y only. C1 carries the accessory's own offset and ScaleTo has already scaled it, so replacing
		-- the whole position here would throw away a hat that is deliberately worn back or tilted.
		local position = weld.C0.Position
		weld.C0 = weld.C0.Rotation + Vector3.new(position.X, head.Size.Y * 0.5, position.Z)
	end
end

-- ── Animation ─────────────────────────────────────────────────────────────────

-- A Humanoid animates the model if the rig has one; otherwise an AnimationController does,
-- and a static model gets one added so any pet can be told to play a loop.
local function animationHost(model: Model): Instance
	local humanoid = model:FindFirstChildWhichIsA("Humanoid", true)
	if humanoid then
		return humanoid
	end
	local controller = model:FindFirstChildWhichIsA("AnimationController", true)
	if controller then
		return controller
	end
	local created = Instance.new("AnimationController")
	created.Parent = model
	return created
end

local function resolveAnimator(model: Model): Animator
	local host = animationHost(model)
	local existing = host:FindFirstChildOfClass("Animator")
	if existing then
		return existing
	end
	local animator = Instance.new("Animator")
	animator.Parent = host
	return animator
end

local function resolveAnimation(model: Model, settings: Config.PetSettings): Animation?
	if settings.animationId then
		local animation = Instance.new("Animation")
		animation.Name = "PetLoop"
		animation.AnimationId = settings.animationId
		animation.Parent = model
		return animation
	end
	if settings.animationName then
		local named = model:FindFirstChild(settings.animationName, true)
		return if named and named:IsA("Animation") then named else nil
	end
	return model:FindFirstChildWhichIsA("Animation", true) :: Animation?
end

--[[
	The idle loop.

	`loopAnimation` is three-valued on purpose. nil means "play one if there is one", so
	supplying an animationId is the whole configuration; true means "there had better be
	one" and warns when there is not; false means static even when an animation is
	authored inside the model.
]]
local function playLoop(petId: string, model: Model, settings: Config.PetSettings): AnimationTrack?
	if settings.loopAnimation == false then
		return nil
	end
	local animation = resolveAnimation(model, settings)
	if not animation then
		if settings.loopAnimation == true then
			warn(`[Companions] Pet "{petId}" has loopAnimation set but no Animation to play; spawning it static.`)
		end
		return nil
	end

	local animator = resolveAnimator(model)
	-- A bad or unpublished AnimationId throws out of LoadAnimation; one broken pet must
	-- not take down the equip call that spawned it.
	local ok, result = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		warn(`[Companions] Pet "{petId}" failed to load its animation: {result}`)
		return nil
	end

	local track = result :: AnimationTrack
	track.Looped = true
	track:Play()
	if settings.animationSpeed ~= 1 then
		track:AdjustSpeed(settings.animationSpeed)
	end
	return track
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Returns nil only when the model turns out to be unusable, which the catalog already
-- filters for; callers treat nil as "this pet could not spawn" and carry on.
function Rig.build(
	entry: Catalog.Entry,
	settings: Config.PetSettings,
	slot: Slots.Slot?,
	container: Instance,
	owner: Player?,
	uid: string,
	rng: Random,
	level: number,
	-- Where to put a pet that has no slot to sit on -- a Detached one. Ignored when a slot
	-- is given, because then the slot says where.
	origin: CFrame?
): Rig?
	local model = entry.model:Clone()
	local root = findRoot(model)
	if not root then
		model:Destroy()
		return nil
	end
	model.PrimaryPart = root
	model.Name = entry.id

	if settings.scale then
		model:ScaleTo(settings.scale)
	end

	-- After ScaleTo, deliberately: the welds this adds capture the offsets the parts are AT, so they
	-- have to be created at the size the rig will actually be.
	prepareParts(model, root)

	local anchor = Instance.new("Attachment")
	anchor.Name = "PetAnchor"
	anchor.CFrame = CFrame.new(settings.anchorOffset)
	anchor.Parent = root

	-- Place the pet so its anchor already sits on the slot; constraints then have nothing
	-- to correct and the pet does not visibly fly in from the model's authored position. A
	-- pet with no slot is placed at `origin` and left there for the host to move.
	local placement = if slot then slot.attachment.WorldCFrame else (origin or CFrame.new())
	local target = placement * anchor.CFrame:Inverse()
	local pivotToRoot = model:GetPivot():ToObjectSpace(root.CFrame)
	model:PivotTo(target * pivotToRoot:Inverse())
	model.Parent = container

	-- After parenting, and that is the whole point of where this sits: entering the DataModel is what
	-- makes the engine rebuild the hat weld at full-size lift, so correcting it any earlier is undone.
	reseatAccessories(model)

	local alignPosition: AlignPosition? = nil
	local alignOrientation: AlignOrientation? = nil

	local mode = settings.followMode
	--[[
		A Detached pet gets NOTHING below -- no constraint, no weld, no attachment claimed.
		The host owns where it is, and anything built here would fight that. It is the one
		mode defined by its absence, which is why it reads as a condition rather than a
		branch of its own.
	]]
	if mode == "Weld" then
		local slotPart = if slot then slot.attachment.Parent :: BasePart else nil
		if slotPart then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "PetSlotWeld"
			weld.Part0 = root
			weld.Part1 = slotPart
			weld.Parent = root
		end
	elseif mode ~= "Detached" and slot then
		local position = Instance.new("AlignPosition")
		position.Name = "PetFollowPosition"
		position.Attachment0 = anchor
		if mode == "Ground" then
			--[[
				ONE attachment, because the target is not the slot.

				A ground pet aims at the point on the FLOOR below its slot, and no attachment
				on the character describes that point -- it depends on the world, not on the
				rig. So the constraint is given a world Position that the ground loop steps,
				rather than a second attachment to chase.
			]]
			position.Mode = Enum.PositionAlignmentMode.OneAttachment
			position.Position = slot.attachment.WorldPosition
		else
			position.Attachment1 = slot.attachment
		end
		position.RigidityEnabled = false
		position.ReactionForceEnabled = false
		position.Responsiveness = settings.responsiveness
		position.MaxForce = settings.maxForce
		position.Parent = root

		-- Orientation still follows the slot in BOTH modes: a ground pet should face the way
		-- its owner does, and the floor has nothing to say about that.
		local orientation = Instance.new("AlignOrientation")
		orientation.Name = "PetFollowOrientation"
		orientation.Attachment0 = anchor
		orientation.Attachment1 = slot.attachment
		orientation.RigidityEnabled = false
		orientation.ReactionTorqueEnabled = false
		orientation.Responsiveness = settings.orientationResponsiveness
		orientation.MaxTorque = settings.maxTorque
		orientation.Parent = root

		alignPosition = position
		alignOrientation = orientation
	end

	-- Handing simulation to the owner keeps the pet in step with their character, which
	-- their client already simulates. Errors when the assembly is welded to the character
	-- or the part is not simulated, so the failure is expected and ignored.
	if settings.networkOwner == "Player" and owner then
		pcall(root.SetNetworkOwner, root, owner)
	elseif settings.networkOwner == "Server" then
		pcall(root.SetNetworkOwner, root, nil)
	end

	local track: AnimationTrack? = playLoop(entry.id, model, settings)

	return {
		uid = uid,
		petId = entry.id,
		slotKey = if slot then slot.key else nil,
		level = level,
		settings = settings,
		model = model,
		root = root,
		anchor = anchor,
		bobBase = settings.anchorOffset,
		bobPhase = rng:NextNumber() * math.pi * 2,
		track = track,
		actionTrack = nil,
		actionConnection = nil,
		animations = {},
		groundCheckedAt = 0,
		groundY = nil,
		slotAttachment = if slot then slot.attachment else nil,
		owner = owner,
		alignPosition = alignPosition,
		alignOrientation = alignOrientation,
	}
end

-- Moves a pet that is already out in the world onto a new settings table — what a level change
-- comes down to. Only fields that can change without rebuilding the pet are handled: followMode and
-- networkOwner decide how it was attached in the first place, so those warn rather than half-apply.
--
-- bobAmplitude and bobFrequency need nothing here beyond switching off cleanly, because the bob loop
-- reads them from rig.settings every frame.
function Rig.applySettings(rig: Rig, settings: Config.PetSettings)
	local previous = rig.settings
	rig.settings = settings

	if settings.followMode ~= previous.followMode or settings.networkOwner ~= previous.networkOwner then
		warn(
			`[Companions] Pet "{rig.petId}" changes followMode or networkOwner at level {rig.level}; `
				.. `that only takes effect the next time it spawns.`
		)
	end

	if settings.scale ~= previous.scale then
		-- ScaleTo is measured against the model's authored size, so repeated levels never compound.
		rig.model:ScaleTo(settings.scale or 1)
		reseatAccessories(rig.model)
	end

	if settings.anchorOffset ~= previous.anchorOffset then
		rig.anchor.CFrame = CFrame.new(settings.anchorOffset)
		rig.bobBase = settings.anchorOffset
	end

	local alignPosition = rig.alignPosition
	if alignPosition then
		alignPosition.Responsiveness = settings.responsiveness
		alignPosition.MaxForce = settings.maxForce
	end
	local alignOrientation = rig.alignOrientation
	if alignOrientation then
		alignOrientation.Responsiveness = settings.orientationResponsiveness
		alignOrientation.MaxTorque = settings.maxTorque
	end

	-- Leaves the pet resting on its slot instead of frozen at whatever offset the last bob wrote.
	if settings.bobAmplitude <= 0 and previous.bobAmplitude > 0 then
		rig.anchor.Position = rig.bobBase
	end

	local animationChanged = settings.loopAnimation ~= previous.loopAnimation
		or settings.animationId ~= previous.animationId
		or settings.animationName ~= previous.animationName
	if animationChanged then
		local track = rig.track
		if track then
			track:Stop()
			track:Destroy()
			rig.track = nil
		end
		if settings.loopAnimation then
			rig.track = playLoop(rig.petId, rig.model, settings)
		end
	else
		local track = rig.track
		if track and settings.animationSpeed ~= previous.animationSpeed then
			track:AdjustSpeed(settings.animationSpeed)
		end
	end
end

-- ── Action animations ─────────────────────────────────────────────────────────

-- Clears whatever action is playing and unhooks its listener. Separate from resuming the
-- loop, because stopping and handing back are different moments -- an interrupting action
-- wants the first without the second.
local function clearAction(rig: Rig)
	local connection = rig.actionConnection
	if connection then
		connection:Disconnect()
		rig.actionConnection = nil
	end
	local action = rig.actionTrack
	if action then
		if action.IsPlaying then
			action:Stop(rig.settings.actionFadeTime)
		end
		rig.actionTrack = nil
	end
end

-- Cached per rig by asset id: LoadAnimation is cheap the second time, but a fresh
-- Animation instance for every swing would litter the model with hundreds of them.
local function animationFor(rig: Rig, animationId: string): Animation
	local existing = rig.animations[animationId]
	if existing then
		return existing
	end
	local animation = Instance.new("Animation")
	animation.Name = `PetAction_{animationId}`
	animation.AnimationId = animationId
	animation.Parent = rig.model
	rig.animations[animationId] = animation
	return animation
end

--[[
	Plays a one-shot animation over the idle loop, and hands back to the loop when it ends.

	THE LOOP IS PAUSED, NOT STOPPED. Stopping it would restart it from frame zero on the
	way back, so a pet that swings twice visibly resets its idle in between. AnimationTrack
	has no pause, so the loop is weighted out and back instead -- which is also what makes
	the crossfade read as one motion rather than two.

	An action already playing is REPLACED. A second call means the pet is doing something
	new, and layering two one-shots produces a pose neither animation describes.

	Returns false when the animation cannot be loaded, which is a content error rather than
	a runtime one -- so it warns and the pet carries on idling.
]]
function Rig.playAction(rig: Rig, animationId: string, speed: number?, fadeTime: number?): boolean
	if type(animationId) ~= "string" or animationId == "" then
		return false
	end
	local fade = fadeTime or rig.settings.actionFadeTime

	local animator = resolveAnimator(rig.model)
	local ok, result = pcall(function()
		return animator:LoadAnimation(animationFor(rig, animationId))
	end)
	if not ok then
		warn(`[Companions] Pet "{rig.petId}" could not load action "{animationId}": {result}`)
		return false
	end

	clearAction(rig)

	local action = result :: AnimationTrack
	action.Looped = false
	action.Priority = Enum.AnimationPriority.Action
	rig.actionTrack = action

	local loop = rig.track
	if loop and loop.IsPlaying then
		loop:AdjustWeight(0, fade)
	end

	--[[
		Hooked BEFORE Play, and to Stopped rather than Ended.

		Stopped fires for an interrupted track as well as a finished one, which is what the
		handing-back belongs to: the loop has to come back either way.

		The identity guard below is the SECOND line and not the first -- clearAction
		disconnects before it stops, so a replaced action's handler does not run at all.
		Mutation testing confirmed that: removing the guard changes nothing today. It stays
		because the thing keeping it unreachable is an ordering inside another function, and
		that is a thin guarantee to hang "the loop weights up underneath a live action" on.
	]]
	rig.actionConnection = action.Stopped:Connect(function()
		if rig.actionTrack ~= action then
			return
		end
		rig.actionTrack = nil
		local resumed = rig.track
		if resumed then
			if not resumed.IsPlaying then
				resumed:Play(fade)
			end
			resumed:AdjustWeight(1, fade)
		end
	end)

	action:Play(fade)
	if speed and speed ~= 1 then
		action:AdjustSpeed(speed)
	end
	return true
end

-- Cuts an action short and hands straight back to the loop. Safe when nothing is playing.
function Rig.stopAction(rig: Rig)
	local action = rig.actionTrack
	if not action then
		return
	end
	-- Stop() fires Stopped, and the handler above is what restores the loop -- so this does
	-- not restore it itself. One path back, not two that can disagree.
	action:Stop(rig.settings.actionFadeTime)
end

function Rig.isPlayingAction(rig: Rig): boolean
	local action = rig.actionTrack
	return action ~= nil and action.IsPlaying
end

-- ── Physics ───────────────────────────────────────────────────────────────────

export type PhysicsSpec = {
	canCollide: boolean?,
	canQuery: boolean?,
	canTouch: boolean?,
	anchored: boolean?,
}

--[[
	Sets physics properties across every part of a pet.

	FOR DETACHED PETS, mostly. A pet following its owner is decoration and is deliberately
	built inert -- it must not block the host's raycasts or trip its collision handlers. A
	detached one may well be a mount, a turret or a vehicle, and none of those work inert,
	so the host says what it needs rather than this package guessing.

	Only the fields given are applied, so turning collision on does not silently also make
	the pet queryable.
]]
function Rig.setPhysics(rig: Rig, spec: PhysicsSpec)
	for _, descendant in rig.model:GetDescendants() do
		if descendant:IsA("BasePart") then
			if spec.canCollide ~= nil then
				descendant.CanCollide = spec.canCollide
			end
			if spec.canQuery ~= nil then
				descendant.CanQuery = spec.canQuery
			end
			if spec.canTouch ~= nil then
				descendant.CanTouch = spec.canTouch
			end
			if spec.anchored ~= nil then
				descendant.Anchored = spec.anchored
			end
		end
	end
end

function Rig.destroy(rig: Rig)
	clearAction(rig)
	table.clear(rig.animations)
	if rig.track then
		rig.track:Stop()
		rig.track:Destroy()
	end
	local owned = rig.ownedAttachment
	if owned then
		owned:Destroy()
	end
	rig.model:Destroy()
end

return Rig
