-- Zone: server-side "who is inside this volume" detection for rotated boxes,
-- cylinders and spheres.
--
-- ONE TICKER FOR EVERY ZONE. Zones do not own a Heartbeat connection each --
-- twenty zones used to mean twenty connections all accumulating dt every frame,
-- and twenty independent sweeps that each re-resolved every player's
-- HumanoidRootPart by name. There is now a single shared connection: it advances
-- every zone's timer, gathers positions ONCE per frame in which any zone is due,
-- and hands that one snapshot to whichever zones are due.
--
-- SUBJECT TYPES. A zone does not know what a player is. It watches named
-- populations -- "player", "bot", "vehicle" -- and a population is a SET of refs
-- plus one function saying where a ref is. The set is maintained, never polled:
-- Zone.track/Zone.untrack are the primitive, and Zone.trackTagged/trackChildren
-- wire that set to a CollectionService tag or a folder through their added and
-- removed signals. Nothing calls GetTagged or GetPlayers per frame, so discovery
-- costs O(1) per spawn rather than O(population) per frame -- and a frame gathers
-- only the types some DUE zone actually asked for, so a bot-only game never
-- touches Players at all.
--
-- TWO-PHASE MEMBERSHIP TEST. Every candidate is first rejected against a cached
-- bounding sphere (one dot product) and only then transformed into the zone's
-- object space for the exact test. The bounding sphere and half-extents are
-- computed once, not per subject per frame.
--
-- THE CACHE INVARIANT: MOVE ZONES THROUGH UpdateZone. The cached centre, radius
-- and half-extents are refreshed there. Setting `zone.zoneInstance.CFrame` or
-- `.Size` directly leaves the cache describing the old volume, so membership
-- would be computed against where the zone used to be. Contains compares the
-- instance against the cache and self-heals with a warning if they disagree, but
-- that is a safety net, not a licence -- go through UpdateZone.
--
-- ISOLATION. One shared ticker means one zone must not be able to break another,
-- so each sweep runs under xpcall, each population's gather runs under one of its
-- own, and the interval callback -- the only consumer code called directly rather
-- than through a BindableEvent -- runs under pcall, so a throwing callback loses
-- only that call rather than the rest of the sweep.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Zone = {}
Zone.__index = Zone

local SUPPORTED_SHAPES = {
	[Enum.PartType.Block] = true,
	[Enum.PartType.Cylinder] = true,
	[Enum.PartType.Ball] = true,
}

-- The one built-in population. Named rather than inlined because the
-- player-shaped API (playerCountInZone, GetPlayersInZone) is defined as "of this
-- type", and nothing else in the module is player-specific.
local PLAYER_TYPE = "player"

-- Passed as `types` to mean "every population registered at sweep time". A table
-- rather than a magic string so it can never collide with a real type name.
Zone.AllTypes = table.freeze({})

local DEFAULT_TYPES = table.freeze({ PLAYER_TYPE })

-- ---------------------------------------------------------------- geometry --

-- Half-extents for the narrow phase, plus a SQUARED bounding-sphere radius for
-- the broad phase. Computed on construction and on UpdateZone, never per check.
local function computeBounds(shape: Enum.PartType, size: Vector3): (Vector3, number)
	local half = size * 0.5
	if shape == Enum.PartType.Cylinder then
		-- Roblox cylinders run their height along X, with Y and Z as the
		-- cross-section diameters. The bounding sphere has to cover the larger of
		-- the two, whether or not they match.
		local crossRadius = math.max(size.Y, size.Z) * 0.5
		return half, half.X * half.X + crossRadius * crossRadius
	elseif shape == Enum.PartType.Ball then
		local radius = math.max(size.X, size.Y, size.Z) * 0.5
		return half, radius * radius
	end
	-- Block: the bounding sphere passes through the corners.
	local diagonal = size.Magnitude * 0.5
	return half, diagonal * diagonal
end

-- Exact tests, in the zone's object space. Each takes the LOCAL point and the
-- cached half-extents, so nothing here recomputes anything.
--
-- Cylinder and Ball use the ellipse/ellipsoid form rather than a single radius:
-- a zone sized (10, 8, 4) has different Y and Z extents, and testing it as a
-- circle of radius 4 -- as this module used to -- accepted points a third of the
-- way outside the part along Z.
local function insideBox(local_: Vector3, half: Vector3): boolean
	return math.abs(local_.X) <= half.X and math.abs(local_.Y) <= half.Y and math.abs(local_.Z) <= half.Z
end

local function insideCylinder(local_: Vector3, half: Vector3): boolean
	if math.abs(local_.X) > half.X then
		return false
	end
	local y = local_.Y / half.Y
	local z = local_.Z / half.Z
	return y * y + z * z <= 1 -- squared: no sqrt needed to compare against a radius
end

local function insideBall(local_: Vector3, half: Vector3): boolean
	local x = local_.X / half.X
	local y = local_.Y / half.Y
	local z = local_.Z / half.Z
	return x * x + y * y + z * z <= 1
end

local TESTS: { [Enum.PartType]: (Vector3, Vector3) -> boolean } = {
	[Enum.PartType.Block] = insideBox,
	[Enum.PartType.Cylinder] = insideCylinder,
	[Enum.PartType.Ball] = insideBall,
}

-- ------------------------------------------------------- shared root cache --

-- player -> their HumanoidRootPart. FindFirstChild is a name lookup, and the old
-- code did one per zone per player per sweep; this does one per player per
-- respawn. Validated by `Parent` rather than by connecting to CharacterAdded, so
-- it self-heals for a character replaced or a root destroyed without ceremony.
local roots: { [Player]: BasePart } = {}

local function rootOf(player: Player): BasePart?
	local cached = roots[player]
	if cached and cached.Parent then
		return cached
	end
	local character = player.Character
	if not character then
		roots[player] = nil
		return nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		roots[player] = hrp
		return hrp
	end
	roots[player] = nil
	return nil
end

-- ----------------------------------------------------------- type registry --

-- One entry per named population. `refs` is the maintained set; `snapRefs` and
-- `snapPositions` are the per-frame snapshot, reused across frames so a gather
-- allocates nothing.
type TypeEntry = {
	positionOf: (any) -> Vector3?,
	refs: { [any]: true },
	connections: { RBXScriptConnection },
	sources: { [string]: true },
	snapRefs: { any },
	snapPositions: { Vector3 },
	snapCount: number,
	snapFilled: number,
	warned: boolean,
}

local registry: { [string]: TypeEntry } = {}

-- Position resolvers ship for the shapes a game actually has. There is
-- deliberately no bot resolver: knowing the shape of a Bots body would couple
-- these libraries, and a game writes that one-liner itself.
--
-- All three treat a parentless instance as gone, which is the same liveness
-- signal rootOf uses -- so a destroyed or streamed-out subject exits its zones
-- even if nobody remembered to call untrack.
function Zone.positionFromPart(part: BasePart): Vector3?
	return if part.Parent then part.Position else nil
end

function Zone.positionFromModel(model: Model): Vector3?
	return if model.Parent then model:GetPivot().Position else nil
end

-- Auto-detecting: the default when a population is wired from a tag or a folder,
-- where the game has not said which of the two it is.
function Zone.positionFromInstance(instance: Instance): Vector3?
	if not instance.Parent then
		return nil
	elseif instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

-- Declare a population. Re-registering an existing name REPLACES the resolver and
-- keeps the set, which is how the built-in player resolver is overridden without
-- losing everyone already tracked.
function Zone.registerType(name: string, positionOf: (any) -> Vector3?)
	assert(type(name) == "string" and name ~= "", `Zone.registerType: name must be a non-empty string`)
	assert(type(positionOf) == "function", `Zone.registerType: positionOf for "{name}" must be a function`)
	local existing = registry[name]
	if existing then
		existing.positionOf = positionOf
		existing.warned = false
		return
	end
	registry[name] = {
		positionOf = positionOf,
		refs = {},
		connections = {},
		sources = {},
		snapRefs = {},
		snapPositions = {},
		snapCount = 0,
		snapFilled = 0,
		warned = false,
	}
end

function Zone.hasType(name: string): boolean
	return registry[name] ~= nil
end

local function entryFor(name: string, caller: string): TypeEntry
	local entry = registry[name]
	assert(entry, `{caller}: no type named "{name}" -- call Zone.registerType("{name}", positionOf) first`)
	return entry
end

-- The primitive. Zero per-frame cost: the set is maintained here, at the moments
-- the game already knows about, rather than rediscovered on every sweep.
function Zone.track(typeName: string, ref: any)
	assert(ref ~= nil, `Zone.track: ref must not be nil`)
	entryFor(typeName, "Zone.track").refs[ref] = true
end

-- Forgiving by design: untracking something never tracked, or of a type that does
-- not exist, is what a teardown path does when it cannot be sure.
function Zone.untrack(typeName: string, ref: any)
	local entry = registry[typeName]
	if entry then
		entry.refs[ref] = nil
	end
end

function Zone.isTracked(typeName: string, ref: any): boolean
	local entry = registry[typeName]
	return entry ~= nil and entry.refs[ref] == true
end

function Zone.trackedCount(typeName: string): number
	local entry = registry[typeName]
	if not entry then
		return 0
	end
	local count = 0
	for _ in entry.refs do
		count += 1
	end
	return count
end

-- Wire a population to a CollectionService tag. GetTagged is called ONCE, here;
-- everything after that arrives through the added/removed signals. Polling
-- GetTagged instead would allocate a fresh array of the entire tagged population
-- on every sweep, which is the cost this exists to avoid.
function Zone.trackTagged(typeName: string, tag: string, positionOf: ((any) -> Vector3?)?)
	assert(type(tag) == "string" and tag ~= "", `Zone.trackTagged: tag must be a non-empty string`)
	if not registry[typeName] or positionOf then
		Zone.registerType(typeName, positionOf or Zone.positionFromInstance)
	end
	local entry = registry[typeName]
	-- Idempotent: several zones naming the same tag in tagsToTrack must not each add
	-- their own pair of connections all writing the same set.
	local source = `tag:{tag}`
	if entry.sources[source] then
		return
	end
	entry.sources[source] = true
	for _, instance in CollectionService:GetTagged(tag) do
		entry.refs[instance] = true
	end
	table.insert(entry.connections, CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
		entry.refs[instance] = true
	end))
	table.insert(entry.connections, CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
		entry.refs[instance] = nil
	end))
end

-- The same idea for a game that keeps a population in a folder.
function Zone.trackChildren(typeName: string, container: Instance, positionOf: ((any) -> Vector3?)?)
	assert(typeof(container) == "Instance", `Zone.trackChildren: container must be an Instance`)
	if not registry[typeName] or positionOf then
		Zone.registerType(typeName, positionOf or Zone.positionFromInstance)
	end
	local entry = registry[typeName]
	local source = `children:{container:GetFullName()}`
	if entry.sources[source] then
		return
	end
	entry.sources[source] = true
	for _, child in container:GetChildren() do
		entry.refs[child] = true
	end
	table.insert(entry.connections, container.ChildAdded:Connect(function(child)
		entry.refs[child] = true
	end))
	table.insert(entry.connections, container.ChildRemoved:Connect(function(child)
		entry.refs[child] = nil
	end))
end

-- The built-in population, maintained by PlayerAdded/PlayerRemoving. This also
-- retires a per-frame allocation: the old gather called Players:GetPlayers(),
-- which builds a fresh array every time it is asked.
Zone.registerType(PLAYER_TYPE, function(player: Player): Vector3?
	local hrp = rootOf(player)
	return if hrp then hrp.Position else nil
end)

do
	local players = registry[PLAYER_TYPE].refs
	for _, player in Players:GetPlayers() do
		players[player] = true
	end
	Players.PlayerAdded:Connect(function(player)
		players[player] = true
	end)
	Players.PlayerRemoving:Connect(function(player)
		players[player] = nil
		roots[player] = nil
	end)
end

-- ------------------------------------------------------------ shared ticker --

local activeZones: { any } = {}
local dueZones: { any } = {}
local heartbeat: RBXScriptConnection? = nil

-- Reused: the union of types the due zones asked for this frame.
local wantedTypes: { [string]: boolean } = {}

-- Split out of gatherType so the xpcall below has a named function to call. A
-- closure there would allocate once per type per frame, which is exactly the cost
-- the reused snapshot arrays exist to avoid.
local function fillSnapshot(entry: TypeEntry): number
	local refs, positions, positionOf = entry.snapRefs, entry.snapPositions, entry.positionOf
	local count = 0
	for ref in entry.refs do
		local position = positionOf(ref)
		if position then
			count += 1
			refs[count] = ref
			positions[count] = position
		end
	end
	return count
end

local function gatherType(name: string)
	local entry = registry[name]
	if not entry then
		return
	end
	-- Guarded once per type per frame, not once per ref: a resolver that throws
	-- costs its own population for this frame rather than the whole tick, and the
	-- cost of guarding does not scale with how much is being tracked.
	local ok, result = xpcall(fillSnapshot, debug.traceback, entry)
	local count = if ok then result else 0
	if not ok and not entry.warned then
		entry.warned = true -- once: a broken resolver throws every single frame
		warn(`[Zone] the "{name}" position resolver errored; that population is skipped:`, result)
	end
	entry.snapCount = count
	-- Release the tail so a departed subject is not pinned by a stale slot.
	for index = count + 1, entry.snapFilled do
		entry.snapRefs[index] = nil
		entry.snapPositions[index] = nil
	end
	entry.snapFilled = count
end

local function tick(dt: number)
	-- Phase 1: advance every timer, collect who is due, and resolve what each due
	-- zone watches into this frame's union. No consumer code runs here, so walking
	-- `activeZones` directly is safe.
	local dueCount = 0
	for _, zone in activeZones do
		zone._timeElapsed += dt
		zone.intervalTimeElapsed += dt
		if zone._timeElapsed >= zone.interval then
			dueCount += 1
			dueZones[dueCount] = zone
			table.clear(zone._resolved)
			zone:_ResolveTypes(zone._resolved)
			for name in zone._resolved do
				wantedTypes[name] = true
			end
		end
	end
	if dueCount == 0 then
		return
	end

	-- One snapshot per population, for however many zones are due this frame -- and
	-- only for populations somebody asked for, so excluding a type really does stop
	-- the work rather than merely filtering it out afterwards.
	for name in wantedTypes do
		gatherType(name)
	end
	table.clear(wantedTypes)

	-- Phase 2: sweep. This DOES run consumer code (enter/exit handlers), which may
	-- create or destroy zones -- hence the private due-list and the _active check
	-- rather than iterating the live registry.
	for index = 1, dueCount do
		local zone = dueZones[index]
		dueZones[index] = nil
		if zone._active then
			-- Subtract rather than zero: zeroing discards the overshoot, so every
			-- cycle ran one frame long and the interval drifted.
			zone._timeElapsed -= zone.interval
			if zone._timeElapsed >= zone.interval then
				zone._timeElapsed = 0 -- fell far behind (a long hitch); do not burst
			end
			-- Isolated per zone. Sharing one ticker created shared fate where the old
			-- per-zone connections had none: without this, anything throwing inside one
			-- zone.s sweep would abort the loop and every zone still queued behind it
			-- would miss this frame. Guarding here makes "a zone cannot break another
			-- zone" true by construction rather than by enumerating call sites.
			local swept, err = xpcall(zone._Sweep, debug.traceback, zone)
			if not swept then
				warn(
					`[Zone] "{zone.zoneInstance and zone.zoneInstance.Name or "?"}" errored mid-sweep;`
						.. ` other zones are unaffected:`,
					err
				)
			end
			-- Subtract here for the same reason as above, and crucially for CONSISTENCY
			-- with it: zeroing this one while the sweep timer keeps its overshoot put
			-- the two out of phase, so the callback timer fell a frame short of its
			-- threshold on alternate sweeps and the callback fired half as often as
			-- asked. Both timers keep their remainder, so both stay in lockstep.
			local override = zone.intervalCallbackDurationOverride
			if zone.intervalTimeElapsed >= override then
				zone.intervalTimeElapsed -= override
				if zone.intervalTimeElapsed >= override then
					zone.intervalTimeElapsed = 0 -- fell far behind; do not burst
				end
			end
		end
	end
end

local function register(zone: any)
	table.insert(activeZones, zone)
	if not heartbeat then
		heartbeat = RunService.Heartbeat:Connect(tick)
	end
end

local function unregister(zone: any)
	local index = table.find(activeZones, zone)
	if index then
		-- Swap-remove: order is irrelevant, and phase 2 never walks this list.
		local last = #activeZones
		activeZones[index] = activeZones[last]
		activeZones[last] = nil
	end
	if #activeZones == 0 and heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

-- ------------------------------------------------------------------- checks --

-- Recompute the cached geometry from the instance. Called on construction, from
-- UpdateZone, and by the self-heal in _EnsureBounds.
function Zone:_RefreshBounds()
	local instance = self.zoneInstance
	self._cachedCFrame = instance.CFrame
	self._cachedSize = instance.Size
	self._center = instance.CFrame.Position
	self._half, self._radiusSq = computeBounds(instance.Shape, instance.Size)
	self._test = TESTS[instance.Shape]
end

-- The single gate on the cached geometry. Everything that reads the cache goes
-- through Contains, so checking here covers the sweep and any external caller
-- alike -- one always-correct path rather than a fast internal one plus a safe
-- public one, which is the kind of split where somebody eventually calls the
-- wrong one.
function Zone:_EnsureBounds()
	local instance = self.zoneInstance
	if instance.CFrame ~= self._cachedCFrame or instance.Size ~= self._cachedSize then
		warn(
			`[Zone] "{instance.Name}" was moved or resized without UpdateZone; refreshing cached bounds.`
				.. ` Use zone:UpdateZone(cframe, size) so the cache stays correct.`
		)
		self:_RefreshBounds()
	end
end

-- Is this world position inside the volume? Public because it is useful on its
-- own ("would this spawn point be inside the safe zone?") and costs nothing to
-- expose. Broad phase first: one dot product rejects anything outside the
-- bounding sphere before the object-space transform.
function Zone:Contains(position: Vector3): boolean
	self:_EnsureBounds()
	local offset = position - self._center
	if offset:Dot(offset) > self._radiusSq then
		return false
	end
	return self._test(self._cachedCFrame:PointToObjectSpace(position), self._half)
end

-- Which populations does this zone watch? Resolved per sweep rather than frozen
-- at construction, so a type registered after the zone still counts and require
-- order stops mattering.
function Zone:_ResolveTypes(out: { [string]: boolean })
	local exclude = self._excludeTypes
	if self._types == Zone.AllTypes then
		for name in registry do
			if not (exclude and exclude[name]) then
				out[name] = true
			end
		end
		return
	end
	for _, name in self._types do
		if not (exclude and exclude[name]) then
			if registry[name] then
				out[name] = true
			elseif not self._warnedTypes[name] then
				self._warnedTypes[name] = true -- once per zone per name, not once per sweep
				warn(
					`[Zone] "{self.zoneInstance and self.zoneInstance.Name or "?"}" watches unregistered type`
						.. ` "{name}", so nothing of that type can ever be detected.`
						.. ` Call Zone.registerType("{name}", positionOf).`
				)
			end
		end
	end
end

-- Change what this zone watches at runtime. A subject of a type that is no longer
-- watched is exited on the next sweep rather than left stuck inside.
function Zone:SetTypes(types: { string }?, excludeTypes: { string }?)
	if types == nil then
		self._types = DEFAULT_TYPES
	elseif types == Zone.AllTypes then
		self._types = Zone.AllTypes
	else
		assert(type(types) == "table", `Zone:SetTypes: types must be an array of names, Zone.AllTypes, or nil`)
		self._types = table.clone(types)
	end
	if excludeTypes then
		local set = {}
		for _, name in excludeTypes do
			set[name] = true
		end
		self._excludeTypes = set
	else
		self._excludeTypes = nil
	end
	table.clear(self._warnedTypes)
end

-- What this zone watches right now, resolved and sorted. Diagnostic: it answers
-- "did my type name actually take effect?" without reading private fields.
function Zone:GetTypes(): { string }
	local resolved = {}
	self:_ResolveTypes(resolved)
	local names = {}
	for name in resolved do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function Zone:_Enter(ref: any, typeName: string)
	self.subjectsInZone[ref] = typeName
	self.subjectCountInZone += 1
	if typeName == PLAYER_TYPE then
		self.playerCountInZone += 1
	end
	self:_TriggerSubjectEntered(ref, typeName)
	self:OnIntervalCallback(ref, typeName)
end

function Zone:_Exit(ref: any)
	local typeName = self.subjectsInZone[ref]
	if not typeName then
		return
	end
	self.subjectsInZone[ref] = nil
	self.subjectCountInZone = math.max(0, self.subjectCountInZone - 1)
	if typeName == PLAYER_TYPE then
		self.playerCountInZone = math.max(0, self.playerCountInZone - 1)
	end
	self:_TriggerSubjectExited(ref, typeName)
end

-- One membership update for one candidate, for every shape. This used to be two
-- near-identical 20-line methods plus a per-subject-per-frame shape comparison;
-- the shape is fixed at construction, so it is resolved once into self._test.
function Zone:_UpdateMembership(ref: any, position: Vector3, typeName: string?)
	local name = typeName or PLAYER_TYPE
	local inside = self:Contains(position)
	if not self.subjectsInZone[ref] then
		if inside then
			self:_Enter(ref, name)
		end
	elseif not inside then
		self:_Exit(ref)
	else
		if self.EnableDebugPrints then
			print("SUBJECT STILL IN ZONE")
		end
		self:OnIntervalCallback(ref, name)
	end
end

-- Retained for compatibility: the original exposed these two. Both now delegate.
function Zone:DoBoxCheck(ref: any, position: Vector3, typeName: string?)
	self:_UpdateMembership(ref, position, typeName)
end

function Zone:DoCylinderCheck(ref: any, position: Vector3, typeName: string?)
	self:_UpdateMembership(ref, position, typeName)
end

function Zone:_Sweep()
	local instance = self.zoneInstance
	if not instance or not instance.Parent then
		return
	end

	for typeName in self._resolved do
		local entry = registry[typeName]
		if entry then
			-- The reused SNAPSHOT arrays, not entry.refs: an enter/exit handler is free
			-- to call Zone.track or Zone.untrack, and mutating the set being iterated is
			-- exactly the hazard the snapshot removes.
			local refs, positions = entry.snapRefs, entry.snapPositions
			for index = 1, entry.snapCount do
				if not self._active then
					return -- an enter/exit handler destroyed this zone mid-sweep
				end
				self:_UpdateMembership(refs[index], positions[index], typeName)
			end
		end
	end

	-- A subject absent from this frame's snapshot -- untracked, destroyed, a player
	-- with no root because they are dead or respawning, or of a type this zone has
	-- stopped watching -- was never tested above, so exit it explicitly. That one
	-- rule replaces what used to be a HumanoidRootPart-specific check, and it holds
	-- for populations with no character and no Instance at all.
	--
	-- Collected FIRST: _Exit fires a consumer handler, and letting that run
	-- mid-traversal means consumer code could insert into the table being iterated.
	local stale: { any }? = nil
	for ref, typeName in self.subjectsInZone do
		local entry = registry[typeName]
		local gone = not self._resolved[typeName] or entry == nil or not entry.refs[ref]
		if not gone then
			-- Still tracked, but unresolvable this frame. One resolver call per MEMBER,
			-- not per tracked subject: a zone's membership is small by construction.
			gone = entry.positionOf(ref) == nil
		end
		if gone then
			stale = stale or {}
			table.insert(stale, ref)
		end
	end
	if stale then
		for _, ref in stale do
			if not self._active then
				return
			end
			self:_Exit(ref)
		end
	end
end

function Zone:OnIntervalCallback(ref: any, typeName: string?)
	if self.EnableDebugPrints then
		print(`for subject {ref}, {self.intervalTimeElapsed}, {self.intervalCallbackDurationOverride}`)
	end
	if self.intervalCallback and self.intervalTimeElapsed >= self.intervalCallbackDurationOverride then
		-- Consumer code, called directly rather than through a BindableEvent (which
		-- isolates its own handlers). Without this guard a throwing callback aborts
		-- the REST of this zone.s sweep, so subjects later in the snapshot would miss
		-- their enter/exit this tick.
		local ok, err = pcall(self.intervalCallback, ref, typeName or PLAYER_TYPE)
		if not ok then
			warn(`[Zone] "{self.zoneInstance and self.zoneInstance.Name or "?"}" intervalCallback errored`
				.. ` for {ref}:`, err)
		end
	end
end

-- ------------------------------------------------------------- constructor --

function Zone.new(
	CFrame: CFrame,
	Size: Vector3,
	Shape: Enum.PartType,
	PartInstance: BasePart?,
	params: {
		Transparency: number?,
		ZoneUpdateInterval: number?,
		Name: string?,
		EnableDebugPrints: boolean?,
		IntervalCallbackDurationOverride: number?,
		tagsToTrack: { string }?,
		types: { string }?,
		excludeTypes: { string }?,
		collisionGroup: string?,
	}?
)
	-- An unsupported shape used to produce a zone that was created, parented and
	-- polled, and silently never detected anybody. Fail at the definition site.
	assert(
		SUPPORTED_SHAPES[Shape],
		`Zone.new: unsupported Shape "{tostring(Shape)}" -- use Block, Cylinder or Ball`
	)
	-- A zero extent divides by zero in the ellipse/ellipsoid tests, producing NaN
	-- comparisons that read as "outside" for every point.
	assert(
		Size.X > 0 and Size.Y > 0 and Size.Z > 0,
		`Zone.new: Size must be positive on every axis (got {tostring(Size)})`
	)

	local interval = (params and params.ZoneUpdateInterval) or 1
	assert(interval > 0, `Zone.new: ZoneUpdateInterval must be > 0 (got {interval})`)
	local override = (params and params.IntervalCallbackDurationOverride) or interval
	assert(override > 0, `Zone.new: IntervalCallbackDurationOverride must be > 0 (got {override})`)

	local zoneInstance = if PartInstance then PartInstance else Instance.new("Part")
	zoneInstance.CFrame = CFrame
	zoneInstance.Size = Size
	zoneInstance.Anchored = true
	zoneInstance.CanCollide = false
	zoneInstance.CanQuery = false
	zoneInstance.CanTouch = false
	zoneInstance.Parent = workspace
	if params and params.collisionGroup then
		zoneInstance.CollisionGroup = params.collisionGroup
	end
	zoneInstance.Shape = Shape
	zoneInstance.Name = if params and params.Name then params.Name else "Zone"
	zoneInstance.Transparency = if params and params.Transparency then params.Transparency else 1

	local self = {}
	setmetatable(self, Zone)

	self.zoneInstance = zoneInstance
	self._subjectEnteredEvent = Instance.new("BindableEvent")
	self._subjectExitedEvent = Instance.new("BindableEvent")
	-- ONE BindableEvent pair, two names. The subject.* names are canonical; the
	-- player.* names are the SAME signal, kept because a handler written as
	-- function(player) simply ignores the type name that now arrives as a second
	-- argument. A second pair would double the Instance count per zone to separate
	-- payloads that are identical.
	self.subjectEntered = self._subjectEnteredEvent.Event
	self.subjectExited = self._subjectExitedEvent.Event
	self.playerEntered = self._subjectEnteredEvent.Event
	self.playerExited = self._subjectExitedEvent.Event
	self._onDestroyed = Instance.new("BindableEvent")
	self.onDestroyed = self._onDestroyed.Event
	self.subjectsInZone = {}
	-- The same table under its old name: the values are type names now rather than
	-- `true`, so an existing truthiness check still reads correctly.
	self.playersInZone = self.subjectsInZone
	self.subjectCountInZone = 0
	-- Players only, deliberately: a bot-only zone reports 0 here rather than
	-- silently redefining what an existing caller's number means.
	self.playerCountInZone = 0
	self.intervalCallback = nil
	self.EnableDebugPrints = if params and params.EnableDebugPrints then params.EnableDebugPrints else false
	self._active = true
	self._resolved = {} -- reused per sweep; filled in phase 1 of the tick
	self._warnedTypes = {}

	self:SetTypes(params and params.types, params and params.excludeTypes)

	-- tagsToTrack was accepted and ignored for as long as this module has existed.
	-- It now means what it looks like it means: each tag becomes a population of the
	-- same name, wired to that tag's added/removed signals, and appended to what
	-- this zone watches.
	self.tagsToTrack = if params and params.tagsToTrack then params.tagsToTrack else nil
	if self.tagsToTrack then
		-- Nothing to append to under AllTypes: a tag population is registered, so it
		-- is already included by definition.
		local appended = if self._types == Zone.AllTypes then nil else table.clone(self._types)
		for _, tag in self.tagsToTrack do
			Zone.trackTagged(tag, tag)
			if appended and not table.find(appended, tag) then
				table.insert(appended, tag)
			end
		end
		if appended then
			self._types = appended
		end
	end

	self:_RefreshBounds()

	self._destroyConnection = zoneInstance.Destroying:Connect(function()
		if self.EnableDebugPrints then
			warn(`ZONE {zoneInstance.Name} INSTANCE DESTROYED - AUTO CLEANUP`)
		end
		self:Destroy()
	end)

	self.playerRemovedConnection = Players.PlayerRemoving:Connect(function(player)
		if self.subjectsInZone[player] then
			self:_Exit(player)
		end
	end)

	self.interval = interval
	self.intervalCallbackDurationOverride = override
	-- Both start AT their threshold so the first sweep and the first interval
	-- callback happen on the first frame rather than a full interval later.
	self._timeElapsed = interval
	self.intervalTimeElapsed = override

	register(self)

	return self
end

function Zone:_TriggerSubjectEntered(ref: any, typeName: string)
	if self.EnableDebugPrints then
		print(`SUBJECT {ref} ({typeName}) ENTERED ZONE {self.zoneInstance.Name}`)
	end
	self._subjectEnteredEvent:Fire(ref, typeName)
end

function Zone:_TriggerSubjectExited(ref: any, typeName: string)
	if self.EnableDebugPrints then
		print(`SUBJECT {ref} ({typeName}) EXITED ZONE {self.zoneInstance and self.zoneInstance.Name or "?"}`)
	end
	self._subjectExitedEvent:Fire(ref, typeName)
end

function Zone:GetSubjectsInZone(typeName: string?): { any }
	local subjects = {}
	for ref, name in self.subjectsInZone do
		if typeName == nil or name == typeName then
			table.insert(subjects, ref)
		end
	end
	return subjects
end

function Zone:GetPlayersInZone(): { Player }
	return self:GetSubjectsInZone(PLAYER_TYPE)
end

function Zone:IsSubjectInZone(ref: any): boolean
	return self.subjectsInZone[ref] ~= nil
end

function Zone:IsPlayerInZone(player: Player): boolean
	return self.subjectsInZone[player] == PLAYER_TYPE
end

-- Nil counts every subject; a type name counts that population. The two
-- maintained counters cover the common cases without walking the table.
function Zone:CountInZone(typeName: string?): number
	if typeName == nil then
		return self.subjectCountInZone
	elseif typeName == PLAYER_TYPE then
		return self.playerCountInZone
	end
	local count = 0
	for _, name in self.subjectsInZone do
		if name == typeName then
			count += 1
		end
	end
	return count
end

function Zone:Destroy()
	if not self._active then
		return -- idempotent: a second Destroy used to re-fire every exit
	end
	self._active = false
	unregister(self)

	local name = if self.zoneInstance then self.zoneInstance.Name else "?"

	-- Fire exit for whoever is still inside, then actually clear the membership
	-- state -- leaving it populated meant onDestroyed handlers saw stale members.
	for _, ref in self:GetSubjectsInZone() do
		self:_TriggerSubjectExited(ref, self.subjectsInZone[ref])
	end
	table.clear(self.subjectsInZone)
	self.subjectCountInZone = 0
	self.playerCountInZone = 0

	if self._onDestroyed then
		self._onDestroyed:Fire(self)
	end

	if self.playerRemovedConnection then
		self.playerRemovedConnection:Disconnect()
		self.playerRemovedConnection = nil
	end
	if self._destroyConnection then
		self._destroyConnection:Disconnect()
		self._destroyConnection = nil
	end

	self._subjectEnteredEvent:Destroy()
	self._subjectExitedEvent:Destroy()
	self._onDestroyed:Destroy() -- was leaked: one BindableEvent per zone, forever

	if self.EnableDebugPrints then
		print(`ZONE {name} DESTROYED`)
	end
	if self.zoneInstance then
		if self.zoneInstance.Parent then
			self.zoneInstance:Destroy()
		end
		self.zoneInstance = nil
	end
end

-- Move and/or resize the volume. THE place to do it: the cached centre, radius
-- and half-extents are refreshed here, and nothing else keeps them correct.
function Zone:UpdateZone(CFrame: CFrame, Size: Vector3)
	assert(
		Size.X > 0 and Size.Y > 0 and Size.Z > 0,
		`Zone:UpdateZone: Size must be positive on every axis (got {tostring(Size)})`
	)
	self.zoneInstance.CFrame = CFrame
	self.zoneInstance.Size = Size
	self:_RefreshBounds()
	if self.EnableDebugPrints then
		print(
			`ZONE {self.zoneInstance.Name} UPDATED WITH CFRAME : {self.zoneInstance.CFrame}, SIZE {self.zoneInstance.Size}`
		)
	end
end

function Zone:UpdateZoneInterval(newInterval: number)
	assert(
		type(newInterval) == "number" and newInterval > 0,
		`Zone:UpdateZoneInterval: interval must be a number > 0 (got {tostring(newInterval)})`
	)
	self.interval = newInterval
end

return Zone
