--!strict

-- Reusing Instances instead of cloning them.
--
-- Cloning is not free: a clone parents into the tree, streams to clients, and for anything
-- with a ParticleEmitter or a Sound it also warms up state the engine would rather keep. A
-- pool pays that cost once per object and then hands the same ones back out.
--
-- ONE POOL PER TEMPLATE, and a pool is an OBJECT rather than a namespace:
--
--   local bullets = Pool.new(bulletModel, { parent = workspace.Shots, warm = 20 })
--   local shot = bullets:get()
--   bullets:release(shot)
--
-- The two implementations this replaces were module-level singletons keyed by a string tag,
-- which meant two systems both using "bullet" silently shared one pool and one of them got
-- the other's objects back. A pool you construct cannot collide with a pool somebody else
-- constructed.
--
-- WHAT VARIES BETWEEN GAMES IS THE RELEASE, not the pooling. Sending an object back can mean
-- unparenting it, parking it out of sight, or just switching it off -- and which one is right
-- depends on what the object IS. That is `release`, a function, with the three common answers
-- provided. Everything else here is the same for everybody.
--
-- NO SIDE EFFECTS AT REQUIRE TIME. One of the predecessors created a Folder in `workspace`
-- when it was required, which fired on the client too and made the module impossible to load
-- anywhere else. Nothing here touches the tree until you call `new`.

local Pool = {}
Pool.__index = Pool

export type ReleaseFn = (instance: Instance) -> ()

--[[
	What to do when the pool is at `max` and everything is out.

	  "grow"   hand out a new clone anyway, and warn ONCE. The default, because a cap is a
	           memory guard and blowing through it is much less bad than the alternatives:
	           nothing visibly breaks and you are told which pool wants raising.
	  "steal"  recycle the object that has been out longest. Right for VFX -- you would
	           rather a distant effect vanish than a new one fail to play -- and wrong for
	           anything a caller still holds a reference to, because it gets reset underneath
	           them.
	  "nil"    return nil. Honest, and the behaviour of one of the predecessors, but it puts a
	           nil check in every caller and the ones that forget just stop spawning effects
	           with no clue why.
]]
export type Exhausted = "grow" | "steal" | "nil"

export type Options = {
	-- Where clones live. nil leaves them unparented and the caller parents each one.
	parent: Instance?,
	-- Ceiling on total clones. nil for none.
	max: number?,
	onExhausted: Exhausted?,
	release: ReleaseFn?,
	-- Runs once per clone, when it is first created. The seam for per-object setup a caller
	-- would otherwise redo on every `get` -- collecting emitters, wiring attributes, caching
	-- descendants.
	onCreate: ((instance: Instance) -> ())?,
	-- Clones to build up front. A pool that warms nothing pays its cloning cost during the
	-- first burst, which is exactly when the frame is busiest.
	warm: number?,
}

-- ── Release strategies ────────────────────────────────────────────────────────

--[[
	Take it out of the tree. The simplest answer, and right for anything with no internal
	state worth preserving.
]]
function Pool.unparent(instance: Instance)
	instance.Parent = nil
end

--[[
	Leave it parented and move it far below the map.

	FOR ANYTHING WITH WARM-UP STATE -- particles above all. Unparenting a ParticleEmitter
	drops its streaming and resets it, so the next use pays the warm-up again and shows a
	visible hitch. Parking keeps it live and ready at the cost of it still existing.

	Only meaningful for something with a pivot; a GuiObject wants `disable` instead.
]]
local PARKED = CFrame.new(0, -1000, 0)

function Pool.park(instance: Instance)
	if instance:IsA("PVInstance") then
		instance:PivotTo(PARKED)
	end
end

--[[
	Switch it off in place. For GUI and billboards, where "gone" is a property rather than a
	position -- and where clearing the Adornee matters, because a billboard still adorned to a
	destroyed part is a reference the engine keeps alive.
]]
function Pool.disable(instance: Instance)
	if instance:IsA("BillboardGui") or instance:IsA("SurfaceGui") then
		(instance :: any).Adornee = nil
	end
	if instance:IsA("GuiObject") or instance:IsA("LayerCollector") then
		(instance :: any).Visible = false
	end
	-- Not everything has an Enabled property, and setting one that does not exist throws.
	-- Parenting is deliberately left alone: the whole point of this strategy is that the
	-- object stays exactly where it is.
	pcall(function()
		(instance :: any).Enabled = false
	end)
end

-- ── Construction ──────────────────────────────────────────────────────────────

export type Pool = typeof(setmetatable(
	{} :: {
		_template: Instance,
		_parent: Instance?,
		_max: number?,
		_onExhausted: Exhausted,
		_release: ReleaseFn,
		_onCreate: ((instance: Instance) -> ())?,
		_free: { Instance },
		-- instance -> the order it was handed out, so "steal" can find the oldest.
		_active: { [Instance]: number },
		_order: number,
		_created: number,
		_warnedExhausted: boolean,
	},
	Pool
))

--[[
	A pool over one template.

	The template is never handed out -- every object is a clone of it -- so it can stay wher
	ever it was authored, including ServerStorage.
]]
function Pool.new(template: Instance, options: Options?): Pool
	assert(typeof(template) == "Instance", "Pool.new: a template Instance is required")
	local given = options or {}
	assert(
		given.max == nil or (type(given.max) == "number" and given.max >= 1),
		"Pool.new: `max` must be a positive number, or nil for no cap"
	)

	local self = setmetatable({
		_template = template,
		_parent = given.parent,
		_max = given.max,
		_onExhausted = given.onExhausted or "grow",
		_release = given.release or Pool.unparent,
		_onCreate = given.onCreate,
		_free = {},
		_active = {},
		_order = 0,
		_created = 0,
		_warnedExhausted = false,
	}, Pool)

	local warm = given.warm
	if warm then
		self:warm(warm)
	end
	return self
end

-- The clone path, and the only place `_created` moves.
function Pool._make(self: Pool): Instance
	local instance = self._template:Clone()
	self._created += 1
	if self._onCreate then
		self._onCreate(instance)
	end
	if self._parent then
		instance.Parent = self._parent
	end
	return instance
end

--[[
	Pre-builds clones so the first burst does not pay for them.

	They go straight to the free list THROUGH the release strategy, so a warmed object is in
	exactly the state a released one is -- otherwise the first `get` of a parked pool would
	hand back something sitting at the origin.
]]
function Pool.warm(self: Pool, count: number)
	for _ = 1, count do
		if self._max and self._created >= self._max then
			break
		end
		local instance = self:_make()
		self._release(instance)
		table.insert(self._free, instance)
	end
end

-- ── Getting and releasing ─────────────────────────────────────────────────────

--[[
	An object from the pool, or nil only when capped with `onExhausted = "nil"`.

	Reused objects are handed back in whatever state the release strategy left them. This does
	NOT reset them: what "reset" means belongs to the caller, and a pool that guessed would
	either miss something or undo something deliberate.
]]
function Pool.get(self: Pool): Instance?
	local instance = table.remove(self._free)

	if not instance then
		if self._max and self._created >= self._max then
			local exhausted = self._onExhausted
			if exhausted == "nil" then
				self:_warnExhausted()
				return nil
			elseif exhausted == "steal" then
				instance = self:_stealOldest()
				if not instance then
					-- Capped, nothing free, and nothing out either: only reachable if the cap
					-- is smaller than the number of objects already destroyed out from under
					-- the pool. Growing is the only thing left that works.
					instance = self:_make()
				end
			else
				self:_warnExhausted()
				instance = self:_make()
			end
		else
			instance = self:_make()
		end
	end

	local claimed = instance :: Instance
	self._order += 1
	self._active[claimed] = self._order
	return claimed
end

-- The object that has been out longest. Linear, because a pool at its cap is small by
-- definition -- that is what the cap is for -- and a heap would be more machinery than the
-- scan it replaces.
function Pool._stealOldest(self: Pool): Instance?
	local oldest: Instance? = nil
	local oldestOrder = math.huge
	for instance, order in self._active do
		if order < oldestOrder then
			oldest, oldestOrder = instance, order
		end
	end
	if oldest then
		self._active[oldest] = nil
		self._release(oldest)
	end
	return oldest
end

function Pool._warnExhausted(self: Pool)
	if self._warnedExhausted then
		return
	end
	self._warnedExhausted = true
	warn(
		`[ObjectPool] "{self._template.Name}" hit its cap of {self._max}. `
			.. 'Raise max, release sooner, or set onExhausted = "steal".'
	)
end

--[[
	Hands an object back.

	A FOREIGN OR ALREADY-RELEASED OBJECT IS A NO-OP, not a crash. Both predecessors looked the
	tag up in their active map and inserted into the free list at that key without checking it
	-- so an object they had never handed out indexed a nil table and threw. Double-release is
	the mistake every pool caller eventually makes, usually in the error path of something
	that has already gone wrong.

	Returns whether it was actually holding it, so a caller that wants to know can ask.
]]
function Pool.release(self: Pool, instance: Instance?): boolean
	if instance == nil or self._active[instance] == nil then
		return false
	end
	local claimed = instance :: Instance
	self._active[claimed] = nil
	self._release(claimed)
	table.insert(self._free, claimed)
	return true
end

-- Everything currently out, released. For a round ending or a scene tearing down.
function Pool.releaseAll(self: Pool)
	for instance in self._active do
		self._active[instance] = nil
		self._release(instance)
		table.insert(self._free, instance)
	end
end

-- ── Teardown and inspection ───────────────────────────────────────────────────

--[[
	Destroys every clone, in use or not, and empties the pool.

	The template is left alone -- the pool never owned it.
]]
function Pool.destroy(self: Pool)
	for _, instance in self._free do
		instance:Destroy()
	end
	for instance in self._active do
		instance:Destroy()
	end
	table.clear(self._free)
	table.clear(self._active)
	self._created = 0
	self._warnedExhausted = false
end

-- free, active, total created. What a debug overlay reads, and what a test asserts on.
function Pool.stats(self: Pool): (number, number, number)
	local active = 0
	for _ in self._active do
		active += 1
	end
	return #self._free, active, self._created
end

return Pool
