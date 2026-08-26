-- A minimal Roblox stand-in for headless tests: Vector3, CFrame (position + yaw),
-- Enum.PartType, Instance.new for Part/MeshPart/Model/Folder/BindableEvent, the
-- Players / RunService / CollectionService services, task, and a manually-stepped
-- Heartbeat.
--
-- The Heartbeat being manual is the point: tests drive time exactly, so interval
-- and drift behaviour is asserted rather than sampled.
--
-- NOTE ON FIDELITY. This shim's BindableEvent passes arguments BY REFERENCE,
-- where the real engine deep-copies tables and strips metatables. That gap once
-- hid a real bug, so nothing in the libraries should rely on a BindableEvent to
-- carry a table -- see the signal section of Zone/src/init.luau.

local task = require("@lune/task")

local rbx = {}

-- Zone dispatches signal handlers through task.spawn, so the shim has to supply
-- it. Lune's task.spawn matches Roblox's shape: runs immediately on a new thread
-- until the first yield, and accepts a thread to resume as well as a function.
rbx.task = task

--[[
	Roblox's `debug` with the profiler entry points Lune does not have.

	`profilebegin` / `profileend` are Roblox-only and cost nothing here, but library code
	calls them around every per-frame loop -- so without these, the first suite to actually
	drive a heartbeat dies on a nil call rather than on anything it was testing.

	Falls through to the real `debug` for `traceback`, which the xpcall handlers rely on.
]]
rbx.debug = setmetatable({
	profilebegin = function() end,
	profileend = function() end,
}, { __index = debug })

-- ------------------------------------------------------------------ Vector3 --

local Vector3 = {}
Vector3.__index = Vector3

local function v3(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end

function Vector3.__add(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
function Vector3.__sub(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
function Vector3.__mul(a, b)
	-- `0 * vector` reaches here with a NUMBER on the left: Luau finds no metatable on the
	-- number and falls through to the right operand's. Spring does exactly this to build a
	-- zero velocity of the same type as its target.
	if type(a) == "number" then
		return v3(a * b.X, a * b.Y, a * b.Z)
	end
	if type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
function Vector3.__div(a, b)
	if type(a) == "number" then
		return v3(a / b.X, a / b.Y, a / b.Z)
	end
	if type(b) == "number" then
		return v3(a.X / b, a.Y / b, a.Z / b)
	end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
function Vector3.__unm(a)
	return v3(-a.X, -a.Y, -a.Z)
end
function Vector3.__eq(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
function Vector3.__tostring(self)
	return ("(%.2f, %.2f, %.2f)"):format(self.X, self.Y, self.Z)
end
function Vector3.__index(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
	elseif key == "Unit" then
		local magnitude = self.Magnitude
		-- A zero vector has no direction. NaN is what the engine gives back, and library code
		-- that guards on Magnitude before asking never sees it.
		return v3(self.X / magnitude, self.Y / magnitude, self.Z / magnitude)
	end
	return Vector3[key]
end
function Vector3.Dot(self, other)
	return self.X * other.X + self.Y * other.Y + self.Z * other.Z
end

-- The constants library code reaches for. `zero` in particular is what an unset offset
-- defaults to, so its absence shows up as a nil arithmetic error three calls away.
rbx.Vector3 = {
	new = v3,
	zero = v3(0, 0, 0),
	one = v3(1, 1, 1),
	xAxis = v3(1, 0, 0),
	yAxis = v3(0, 1, 0),
	zAxis = v3(0, 0, 1),
}

-- ------------------------------------------------------------------- CFrame --

-- Position plus a yaw about Y, stored as an orthonormal basis. PointToObjectSpace
-- projects onto that basis, which is a genuine inverse transform -- enough to
-- prove the rotated-volume tests.
local CFrame = {}
CFrame.__index = CFrame

local function cf(position, yaw)
	yaw = yaw or 0
	local cos, sin = math.cos(yaw), math.sin(yaw)
	return setmetatable({
		Position = position,
		_yaw = yaw,
		_right = v3(cos, 0, -sin),
		_up = v3(0, 1, 0),
		_back = v3(sin, 0, cos),
	}, CFrame)
end

function CFrame.__eq(a, b)
	return a.Position == b.Position and a._yaw == b._yaw
end
function CFrame.__tostring(self)
	return ("CFrame(%s, yaw %.2f)"):format(tostring(self.Position), self._yaw)
end
-- Local offset -> world direction, using the stored basis.
local function rotate(frame, offset)
	return frame._right * offset.X + frame._up * offset.Y + frame._back * offset.Z
end

-- Composition and inverse, enough for placing a rig: position plus a yaw is closed under
-- both, so no general rotation matrix is needed.
function CFrame.__mul(a, b)
	if getmetatable(b) == CFrame then
		return cf(a.Position + rotate(a, b.Position), a._yaw + b._yaw)
	end
	return a.Position + rotate(a, b)
end
function CFrame.__index(self, key)
	if key == "Rotation" then
		return cf(v3(0, 0, 0), rawget(self, "_yaw"))
	elseif key == "RightVector" then
		return rawget(self, "_right")
	elseif key == "UpVector" then
		return rawget(self, "_up")
	elseif key == "LookVector" then
		-- The engine's LookVector points along -Z of the frame; `_back` is +Z here.
		return -rawget(self, "_back")
	end
	return CFrame[key]
end
--[[
	Rotation as a CFrame at the origin, and a yaw-only Lerp between two of them.

	This shim carries a yaw and nothing else, so "rotation" is that angle at the origin and
	the interpolation is on the angle -- taking the short way round, which is what the engine's
	quaternion slerp does and what a platform turning a corner needs. Enough to tell "it turned
	toward its heading" from "it did not"; not enough for pitch or roll, which nothing here has.
]]
function CFrame.Lerp(self, goal, alpha)
	local from, to = rawget(self, "_yaw"), rawget(goal, "_yaw")
	local delta = (to - from) % (2 * math.pi)
	if delta > math.pi then
		delta -= 2 * math.pi
	end
	local position = rawget(self, "Position")
	local goalPosition = rawget(goal, "Position")
	return cf(position + (goalPosition - position) * alpha, from + delta * alpha)
end

function CFrame.Inverse(self)
	local inverted = cf(v3(0, 0, 0), -self._yaw)
	return cf(rotate(inverted, self.Position * -1), -self._yaw)
end
function CFrame.ToObjectSpace(self, other)
	return self:Inverse() * other
end
function CFrame.PointToObjectSpace(self, point)
	local d = point - self.Position
	return v3(d:Dot(self._right), d:Dot(self._up), d:Dot(self._back))
end

rbx.CFrame = {
	new = function(a, b, c)
		if type(a) == "number" then
			return cf(v3(a, b, c), 0)
		end
		return cf(a, 0)
	end,
	yaw = function(position, radians)
		return cf(position, radians)
	end,
	--[[
		Orientation from a DIRECTION rather than a target. The shim's CFrame carries a yaw
		only, so the direction is flattened onto the XZ plane -- enough to tell "it faced along
		the curve" from "it did not", which is what the callers here assert.

		A ZERO direction is an error, as it is in the engine: there is no facing to derive from
		it, and silently returning identity would hide exactly the degenerate-curve case a test
		is trying to catch.
	]]
	--[[
		Face `target` from `position`. Yaw only, like everything else here.

		A zero direction errors rather than quietly returning identity, the same as lookAlong:
		"face nowhere" is a caller bug and hiding it hides the degenerate case a test is
		usually hunting.
	]]
	lookAt = function(position, target, _up)
		local direction = target - position
		local flat = direction.X * direction.X + direction.Z * direction.Z
		assert(flat > 0, "CFrame.lookAt: position and target must differ in the XZ plane")
		return cf(position, math.atan2(direction.X, direction.Z))
	end,
	lookAlong = function(position, direction)
		assert(direction ~= nil, "CFrame.lookAlong: a direction is required")
		local flat = direction.X * direction.X + direction.Z * direction.Z
		assert(
			flat == flat and (flat > 0 or direction.Y ~= 0),
			"CFrame.lookAlong: direction must not be a zero vector"
		)
		return cf(position, math.atan2(direction.X, direction.Z))
	end,
}

-- ------------------------------------------------------------------ Color3 --

-- Stored as floats, as the engine does, with a fromRGB that divides by 255. Enough for a
-- caller to assert what a colour helper produced.
local function color3(r, g, b)
	return setmetatable({ R = r, G = g, B = b }, {
		__eq = function(a, other)
			return a.R == other.R and a.G == other.G and a.B == other.B
		end,
		__tostring = function(self)
			return `Color3({self.R}, {self.G}, {self.B})`
		end,
	})
end

rbx.Color3 = {
	new = color3,
	fromRGB = function(r, g, b)
		return color3((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
	end,
}

-- -------------------------------------------------------------------- Enum --

rbx.Enum = {
	-- Filter modes are compared by identity in library code, so these only have to be stable
	-- distinct values rather than the engine's own numbers.
	RaycastFilterType = {
		Exclude = "Exclude",
		Include = "Include",
	},
	AnimationPriority = {
		Core = "Core",
		Idle = "Idle",
		Movement = "Movement",
		Action = "Action",
	},
	PositionAlignmentMode = {
		OneAttachment = "OneAttachment",
		TwoAttachment = "TwoAttachment",
	},
	PartType = {
		Block = "Block",
		Cylinder = "Cylinder",
		Ball = "Ball",
		Wedge = "Wedge",
		CornerWedge = "CornerWedge",
	},
}

-- --------------------------------------------------------------- Random --

-- Seeded and deterministic, so a library that jitters or picks at random replays
-- identically between runs. A test that wants a fixed choice seeds its own.
rbx.Random = {
	new = function(seed: number?)
		local state = seed or 1
		local generator = {}
		local function nextFloat(): number
			-- A small LCG. Not good randomness; perfectly good repeatable randomness.
			state = (1103515245 * state + 12345) % 2147483648
			return state / 2147483648
		end
		function generator.NextNumber(_, min: number?, max: number?): number
			local value = nextFloat()
			if min and max then
				return min + value * (max - min)
			end
			return value
		end
		function generator.NextInteger(_, min: number, max: number): number
			return math.floor(min + nextFloat() * (max - min + 1))
		end
		return generator
	end,
}

-- ---------------------------------------------------------------- signals --

--[[
	A signal.

	HANDLERS ARE AN ARRAY, NOT A SET KEYED BY FUNCTION, and that is a fidelity fix rather
	than a style choice. Luau caches closures whose upvalues are identical, so calling a
	`start()` twice can hand `Connect` the SAME function object both times -- and a set
	keyed by function silently dedupes it. Roblox does not: two Connects are two
	connections and fire twice.

	Keyed by function, this shim made a double-start look harmless when in the engine it
	would double every remote handler in the module.
]]
local function makeSignal()
	local handlers = {}
	local signal = {}
	function signal.Connect(_, fn)
		local entry = { fn = fn }
		table.insert(handlers, entry)
		return {
			Disconnect = function()
				local index = table.find(handlers, entry)
				if index then
					table.remove(handlers, index)
				end
			end,
		}
	end
	local function fire(...)
		-- Snapshot, because a handler may disconnect itself or another mid-fire.
		for _, entry in table.clone(handlers) do
			entry.fn(...)
		end
	end
	return signal, fire, handlers
end

rbx.makeSignal = makeSignal

-- --------------------------------------------------------------- Instances --

--[[
	Moves a child between parents, the way the engine does when `.Parent` is assigned.

	SETTING `.Parent` IS HOW A THING GETS ADDED. The shim used to treat it as a plain field,
	so `Instance.new("Folder").Parent = ReplicatedStorage` left a folder that nothing could
	find -- which meant no test in this repo could see a library provision its own transport,
	the one thing the "own your transport" convention actually asks of them. Three libraries
	had that path uncovered.

	Tolerates a parent that is not a real instance (`{ Name = "Character" }` and friends):
	bookkeeping only happens where there is a child list to keep.
]]
local function reparent(child, newParent)
	local oldParent = rawget(child, "_parent")
	if oldParent == newParent then
		return
	end

	if type(oldParent) == "table" then
		local kids = rawget(oldParent, "_kids")
		if kids then
			local index = table.find(kids, child)
			if index then
				table.remove(kids, index)
			end
			local fire = rawget(oldParent, "_fireChildRemoved")
			if fire then
				fire(child)
			end
		end
	end

	--[[
		Under a PRIVATE key, never the public `Parent`. __newindex only fires for a key that is
		absent, so writing `Parent` onto the table here would make the FIRST assignment work
		and every one after it silently skip the bookkeeping -- which is exactly the bug this
		helper was written to fix.
	]]
	rawset(child, "_parent", newParent)

	--[[
		Descendant events fan UP the ancestry and cover the WHOLE SUBTREE being moved, as they
		do in the engine: parenting a folder that already has children announces the folder and
		everything inside it, to every ancestor. Library code that watches `workspace` for an
		authored folder appearing depends on exactly that -- the folder is usually populated
		first and parented last.
	]]
	local moved = { child }
	local scan = 1
	while scan <= #moved do
		local node = moved[scan]
		scan += 1
		for _, kid in rawget(node, "_kids") or {} do
			table.insert(moved, kid)
		end
	end

	local ancestor = newParent
	while type(ancestor) == "table" do
		local fire = rawget(ancestor, "_fireDescendantAdded")
		if fire then
			for _, node in moved do
				fire(node)
			end
		end
		ancestor = rawget(ancestor, "_parent")
	end

	if type(newParent) == "table" then
		local kids = rawget(newParent, "_kids")
		if kids and not table.find(kids, child) then
			table.insert(kids, child)
			local fire = rawget(newParent, "_fireChildAdded")
			if fire then
				fire(child)
			end
		end
	end
end

--[[
	Gives a plain instance table the same `.Parent` behaviour parts and containers have.

	Applied to EVERYTHING `Instance.new` hands back, because the alternative is remembering to
	write the metatable into each new class -- and the class that gets forgotten is one whose
	parenting silently does nothing, which reads as a library that never provisioned anything.

	Anything already carrying a metatable is left alone: it has its own, richer one.
]]
local function withParenting(instance)
	if getmetatable(instance) then
		return instance
	end
	return setmetatable(instance, {
		__index = function(self, key)
			if key == "Parent" then
				return rawget(self, "_parent")
			end
			return nil
		end,
		__newindex = function(self, key, value)
			if key == "Parent" then
				reparent(self, value)
			else
				rawset(self, key, value)
			end
		end,
	})
end

local function newPart()
	local destroying, fireDestroying = makeSignal()
	-- CFrame and Position share one piece of storage, as they do in the engine: moving a
	-- part by CFrame moves its Position and the other way round. Held apart, a part moved
	-- by CFrame keeps a stale Position forever, and any test that reads the one the code
	-- under test does not write agrees with everything.
	local part = {
		ClassName = "Part",
		Name = "Part",
		Size = v3(1, 1, 1),
		_cframe = cf(v3(0, 0, 0), 0),
		_kids = {},
		Anchored = false,
		CanCollide = true,
		CanQuery = true,
		CanTouch = true,
		CollisionGroup = "Default",
		Massless = false,
		Shape = "Block",
		Transparency = 0,
		Parent = nil,
		Destroying = destroying,
	}
	function part.__index(self, key)
		if key == "CFrame" then
			return rawget(self, "_cframe")
		elseif key == "Position" then
			return rawget(self, "_cframe").Position
		elseif key == "Parent" then
			return rawget(self, "_parent")
		end
		return nil
	end
	function part.__newindex(self, key, value)
		if key == "CFrame" then
			rawset(self, "_cframe", value)
		elseif key == "Position" then
			rawset(self, "_cframe", cf(value, rawget(self, "_cframe")._yaw))
		elseif key == "Parent" then
			reparent(self, value)
		else
			rawset(self, key, value)
		end
	end
	function part.Destroy(self)
		if self._destroyed then
			return
		end
		self._destroyed = true
		fireDestroying()
		self.Parent = nil
	end
	function part.IsA(_, class)
		return class == "Part" or class == "BasePart" or class == "PVInstance" or class == "Instance"
	end
	function part.SetAttribute(self, name, value)
		local bag = rawget(self, "_attributes")
		if not bag then
			bag = {}
			rawset(self, "_attributes", bag)
		end
		bag[name] = value
	end
	function part.GetAttribute(self, name)
		local bag = rawget(self, "_attributes")
		return if bag then bag[name] else nil
	end
	function part.SetNetworkOwner() end
	-- The PVInstance surface. A part's pose IS its CFrame, so these are that same storage
	-- under the names code reaches for when it does not care whether it holds a part or a
	-- model.
	function part.GetPivot(self)
		return rawget(self, "_cframe")
	end
	function part.PivotTo(self, target)
		rawset(self, "_cframe", target)
	end
	function part.Clone(self)
		local copy = newPart()
		for _, key in
			{
				"Name",
				"Size",
				"CFrame",
				"Anchored",
				"CanCollide",
				"CanQuery",
				"CanTouch",
				"CollisionGroup",
				"Shape",
				"Transparency",
				"Massless",
			}
		do
			copy[key] = self[key]
		end
		return copy
	end
	function part.GetDescendants(self)
		local out = {}
		for _, kid in rawget(self, "_kids") or {} do
			table.insert(out, kid)
		end
		return out
	end
	function part.Add(self, child)
		child.Parent = self
	end
	function part.FindFirstChild(self, name)
		for _, kid in rawget(self, "_kids") or {} do
			if kid.Name == name then
				return kid
			end
		end
		return nil
	end
	return setmetatable(part, { __index = part.__index, __newindex = part.__newindex })
end

local function newContainer(className)
	local childAdded, fireChildAdded = makeSignal()
	local childRemoved, fireChildRemoved = makeSignal()
	local descendantAdded, fireDescendantAdded = makeSignal()
	local descendantRemoving, fireDescendantRemoving = makeSignal()
	local container = {
		ClassName = className,
		Name = className,
		Parent = nil,
		_kids = {},
		ChildAdded = childAdded,
		ChildRemoved = childRemoved,
		DescendantAdded = descendantAdded,
		DescendantRemoving = descendantRemoving,
		-- Read by `reparent`, which has no access to these closures otherwise.
		_fireChildAdded = fireChildAdded,
		_fireChildRemoved = fireChildRemoved,
		_fireDescendantAdded = fireDescendantAdded,
		_fireDescendantRemoving = fireDescendantRemoving,
	}
	function container.IsA(_, class)
		return class == className or class == "Instance"
	end
	function container.GetFullName(self)
		return self.Name
	end
	function container.FindFirstChild(self, name)
		for _, kid in self._kids do
			if kid.Name == name then
				return kid
			end
		end
		return nil
	end
	function container.WaitForChild(self, name, _timeout)
		return self:FindFirstChild(name) -- manually stepped: nothing arrives while we wait
	end
	function container.GetDescendants(self)
		local out = {}
		for _, kid in self._kids do
			table.insert(out, kid)
			if kid.GetDescendants then
				for _, deep in kid:GetDescendants() do
					table.insert(out, deep)
				end
			end
		end
		return out
	end
	function container.FindFirstChildWhichIsA(self, class, recursive)
		for _, kid in (if recursive then self:GetDescendants() else self._kids) do
			if kid.IsA and kid:IsA(class) then
				return kid
			end
		end
		return nil
	end
	function container.FindFirstChildOfClass(self, class)
		for _, kid in self._kids do
			if kid.ClassName == class then
				return kid
			end
		end
		return nil
	end
	function container.ClearAllChildren(self)
		table.clear(self._kids)
	end
	function container.GetChildren(self)
		local out = {}
		for _, kid in self._kids do
			table.insert(out, kid)
		end
		return out
	end
	--[[
		A shallow-ish clone: a fresh container with fresh copies of its children.

		Deep enough for a catalog entry to be cloned into a live pet, which is the only
		thing that clones here. It deliberately does NOT copy grandchildren -- a test that
		needs a deeper rig should build one rather than lean on this.
	]]
	function container.SetAttribute(self, name, value)
		local bag = rawget(self, "_attributes")
		if not bag then
			bag = {}
			rawset(self, "_attributes", bag)
		end
		bag[name] = value
	end
	function container.GetAttribute(self, name)
		local bag = rawget(self, "_attributes")
		return if bag then bag[name] else nil
	end
	function container.Destroy(self)
		if self._destroyed then
			return
		end
		self._destroyed = true
		for _, kid in self._kids do
			if kid.Destroy then
				kid:Destroy()
			end
		end
		table.clear(self._kids)
		self.Parent = nil
	end
	function container.Clone(self)
		local copy = newContainer(className)
		copy.Name = self.Name
		if className == "Model" then
			copy._pivot = self._pivot
			copy._scale = self._scale
		end
		for _, kid in self._kids do
			local kidCopy = if kid.Clone then kid:Clone() else kid
			copy:Add(kidCopy)
			if className == "Model" and self.PrimaryPart == kid then
				copy.PrimaryPart = kidCopy
			end
		end
		return copy
	end
	-- Both are now thin wrappers: assigning `.Parent` does the bookkeeping and fires the
	-- signals, so these cannot drift from what a library setting `.Parent` itself gets.
	function container.Add(_, child)
		child.Parent = container
	end
	function container.Remove(_, child)
		child.Parent = nil
	end
	if className == "Model" then
		container.PrimaryPart = nil
		container._scale = 1
		-- Settable, because the whole point of one test here is what happens when a character
		-- changes size after its extents were first read.
		container._extents = v3(4, 5.2, 4)
		function container.GetExtentsSize(self)
			return rawget(self, "_extents")
		end
		function container.ScaleTo(self, scale)
			self._scale = scale
		end
		function container.GetScale(self)
			return self._scale
		end
		container._pivot = cf(v3(0, 0, 0), 0)
		function container.GetPivot(self)
			return self._pivot
		end
		-- Accepts a CFrame (what library code passes) or a bare Vector3 (what a test
		-- usually wants). Moves the pivot only: nothing here re-seats the children, so
		-- assert on GetPivot rather than on a part's CFrame.
		function container.PivotTo(self, target)
			self._pivot = if getmetatable(target) == getmetatable(cf(v3(0, 0, 0), 0)) then target else cf(target, 0)
		end
	end
	return setmetatable(container, {
		__index = function(self, key)
			if key == "Parent" then
				return rawget(self, "_parent")
			end
			return nil
		end,
		__newindex = function(self, key, value)
			if key == "Parent" then
				reparent(self, value)
			else
				rawset(self, key, value)
			end
		end,
	})
end

-- Declared before the services close over them. ReplicatedStorage is a real
-- container here because libraries provision remote folders into it.
rbx.ReplicatedStorage = newContainer("Folder")
rbx.ReplicatedStorage.Name = "ReplicatedStorage"
rbx.promptTriggered, rbx.firePromptTriggered = makeSignal()

local function newBindable()
	local event, fire = makeSignal()
	local bindable = { Event = event, _destroyed = false }
	function bindable.Fire(self, ...)
		if self._destroyed then
			error("Fire on a destroyed BindableEvent", 2)
		end
		fire(...)
	end
	function bindable.Destroy(self)
		self._destroyed = true
	end
	return bindable
end

local function makeInstance(class)
	do
		if class == "Part" then
			return newPart()
		elseif class == "BindableEvent" then
			return newBindable()
		elseif class == "Model" or class == "Folder" then
			return newContainer(class)
		elseif class == "AnimationController" or class == "Humanoid" or class == "Animator" then
			-- Containers so FindFirstChildOfClass/FindFirstChildWhichIsA can walk them, which
			-- is how a rig locates the animator it should load tracks on.
			local host = newContainer(class)
			if class == "Animator" then
				--[[
					LoadAnimation hands back a fake AnimationTrack that records what was asked of
					it. Nothing here plays: the point is the SEQUENCE -- which track was weighted
					out, which was stopped, what came back afterwards -- and a real animation
					system would only make that harder to assert.
				]]
				function host.LoadAnimation(_, animation)
					local stopped, fireStopped, stoppedHandlers = makeSignal()
					local track
					track = {
						ClassName = "AnimationTrack",
						Animation = animation,
						AnimationId = animation.AnimationId,
						Looped = false,
						Priority = nil,
						IsPlaying = false,
						Weight = 1,
						Speed = 1,
						Stopped = stopped,
						_stoppedHandlers = stoppedHandlers,
						-- What the rig asked for, in order, so a test can assert the handover.
						_calls = {},
					}
					function track.Play(_, fade)
						track.IsPlaying = true
						table.insert(track._calls, "Play")
						track._playFade = fade
					end
					function track.Stop(_, fade)
						if not track.IsPlaying then
							return
						end
						track.IsPlaying = false
						track._stopFade = fade
						table.insert(track._calls, "Stop")
						fireStopped()
					end
					function track.AdjustWeight(_, weight, fade)
						track.Weight = weight
						track._weightFade = fade
						table.insert(track._calls, `Weight={weight}`)
					end
					function track.AdjustSpeed(_, speed)
						track.Speed = speed
						table.insert(track._calls, `Speed={speed}`)
					end
					return track
				end
			end
			return host
		elseif class == "Animation" then
			local animation = { ClassName = "Animation", Name = "Animation", AnimationId = "", Parent = nil }
			function animation.IsA(_, queried)
				return queried == "Animation" or queried == "Instance"
			end
			return animation
		elseif class == "Attachment" then
			-- CFrame and Position are ONE piece of storage in the engine, not two: writing
			-- either moves the attachment, and reading either reflects the last write. The
			-- shim kept them independent, so code that positions a slot with `CFrame` (which
			-- is what Slots does) left `Position` at the origin and every slot reported the
			-- same world point. Tests about where a pet is CANNOT FAIL against that.
			local attachment = {
				ClassName = "Attachment",
				Name = "Attachment",
				Parent = nil,
				_cframe = cf(v3(0, 0, 0), 0),
			}
			function attachment.IsA(_, queried)
				return queried == "Attachment" or queried == "Instance"
			end
			function attachment.SetAttribute(self, name, value)
				local bag = rawget(self, "_attributes")
				if not bag then
					bag = {}
					rawset(self, "_attributes", bag)
				end
				bag[name] = value
			end
			function attachment.GetAttribute(self, name)
				local bag = rawget(self, "_attributes")
				return if bag then bag[name] else nil
			end
			function attachment.Destroy(self)
				self.Parent = nil
			end
			-- World space is the parent part's frame composed with the local offset. Enough
			-- for a slot to say where it is; nothing here simulates.
			function attachment.__index(self, key)
				if key == "Parent" then
					return rawget(self, "_parent")
				elseif key == "CFrame" then
					return rawget(self, "_cframe")
				elseif key == "Position" then
					return rawget(self, "_cframe").Position
				elseif key == "WorldCFrame" then
					local parent = rawget(self, "_parent")
					local base = if parent and parent.CFrame then parent.CFrame else cf(v3(0, 0, 0), 0)
					return cf(base.Position + self.Position, 0)
				elseif key == "WorldPosition" then
					return self.WorldCFrame.Position
				end
				return nil
			end
			-- Either name writes the shared frame, so a slot placed by CFrame reads back
			-- through Position and vice versa.
			function attachment.__newindex(self, key, value)
				if key == "CFrame" then
					rawset(self, "_cframe", value)
				elseif key == "Position" then
					rawset(self, "_cframe", cf(value, rawget(self, "_cframe")._yaw))
				elseif key == "Parent" then
					reparent(self, value)
				else
					rawset(self, key, value)
				end
			end
			return setmetatable(attachment, { __index = attachment.__index, __newindex = attachment.__newindex })
		elseif class == "AlignPosition" or class == "AlignOrientation" or class == "WeldConstraint" then
			-- Property bags. What matters to a test is WHICH constraint a mode created and
			-- what it was pointed at, not that anything moved.
			local constraint = {
				ClassName = class,
				Name = class,
				Parent = nil,
				Attachment0 = nil,
				Attachment1 = nil,
				Part0 = nil,
				Part1 = nil,
				Mode = nil,
				Position = v3(0, 0, 0),
				RigidityEnabled = false,
				ReactionForceEnabled = false,
				ReactionTorqueEnabled = false,
				Responsiveness = 0,
				MaxForce = 0,
				MaxTorque = 0,
			}
			function constraint.IsA(_, queried)
				return queried == class or queried == "Instance"
			end
			return constraint
		elseif class == "StringValue" then
			local value = { ClassName = "StringValue", Name = "StringValue", Value = "", Parent = nil }
			function value.IsA(_, queried)
				return queried == "StringValue" or queried == "Instance"
			end
			return value
		elseif class == "RemoteEvent" or class == "UnreliableRemoteEvent" then
			local toServer, fireToServer, serverHandlers = makeSignal()
			local toClient, fireToClient = makeSignal()
			local remote = {
				ClassName = class,
				Name = class,
				Parent = nil,
				OnServerEvent = toServer,
				OnClientEvent = toClient,
				_serverHandlers = serverHandlers,
			}
			function remote.IsA(self, queried)
				return queried == rawget(self, "ClassName") or queried == "Instance"
			end
			--[[
				FireClient LOGS who it was sent to, then fires OnClientEvent WITHOUT the
				player -- which is the real signature on the receiving end.

				The log is the point: a two-player flow like a trade is untestable if both
				sides share one undifferentiated signal, and "what did Ana see" needs the
				recipient kept.
			]]
			remote._sent = {}
			function remote.FireClient(_, player, ...)
				table.insert(remote._sent, { player = player, args = { ... } })
				fireToClient(...)
			end
			-- Everything sent to one player, oldest first.
			function remote.sentTo(_, player)
				local out = {}
				for _, entry in remote._sent do
					if entry.player == player then
						table.insert(out, entry.args)
					end
				end
				return out
			end
			function remote.clearSent()
				table.clear(remote._sent)
			end
			function remote.FireAllClients(_, ...)
				fireToClient(...)
			end
			--[[
				FireServer LOGS what the client sent, then fires OnServerEvent.

				The engine prepends the sending Player on the way in; this does not, because
				a headless shim has no LocalPlayer to prepend. Server-side tests therefore
				pass a player explicitly as the first argument, and CLIENT-side tests read
				`firedToServer()` instead of listening -- which keeps the two readings from
				quietly disagreeing about whether a player is in there.
			]]
			remote._fired = {}
			function remote.FireServer(_, ...)
				table.insert(remote._fired, { ... })
				fireToServer(...)
			end
			-- Everything the client sent, oldest first.
			function remote.firedToServer()
				return remote._fired
			end
			function remote.clearFired()
				table.clear(remote._fired)
			end
			return remote
		elseif class == "ProximityPrompt" then
			local prompt = {
				ClassName = "ProximityPrompt",
				Name = "ProximityPrompt",
				ActionText = "",
				ObjectText = "",
				MaxActivationDistance = 0,
				RequiresLineOfSight = true,
				Parent = nil,
			}
			function prompt.IsA(_, queried)
				return queried == "ProximityPrompt" or queried == "Instance"
			end
			return prompt
		elseif class == "MeshPart" then
			-- A BasePart with no Shape property: the case Zone.new must refuse rather
			-- than die on a property write.
			local mesh = newPart()
			mesh.ClassName = "MeshPart"
			mesh.Shape = nil
			function mesh.IsA(_, queried)
				return queried == "MeshPart" or queried == "TriangleMeshPart" or queried == "BasePart"
			end
			return mesh
		end
	end
	error(`rbx shim: Instance.new("{class}") is not implemented`)
end

rbx.Instance = {
	new = function(class)
		return withParenting(makeInstance(class))
	end,
}

-- Counted, because "how many of these does a hot path allocate per frame" is a finding in its
-- own right and invisible without a tally.
local raycastParamsMade = 0

function rbx.raycastParamsMade()
	return raycastParamsMade
end

function rbx.resetRaycastParamsCount()
	raycastParamsMade = 0
end

rbx.RaycastParams = {
	new = function()
		raycastParamsMade += 1
		return {
			FilterType = nil,
			FilterDescendantsInstances = {},
			IgnoreWater = false,
			RespectCanCollide = false,
		}
	end,
}

-- A real container: libraries provision folders into Workspace and then look for them.
--[[
	`workspace:GetServerTimeNow()`, the engine-synced clock lag compensation stamps its history
	on.

	Settable, and deliberately NOT tied to the heartbeat: rewind logic is entirely about "where
	was this at time t", so a test needs to place samples at exact times and then ask about
	instants between them. Sampling a real clock would make every interpolation assertion a
	tolerance instead of an equality.
]]
-- Everything handed to Debris:AddItem, oldest first.
local debrisItems = {}

function rbx.debrisItems()
	return debrisItems
end

local serverTime = 0

--[[
	What `workspace:Raycast` answers. nil -- the default -- means the ray hit nothing, which is
	an unobstructed line of sight.

	A function rather than a fixed value so a test can answer differently per ray: the
	interesting line-of-sight cases are "this one is blocked and that one is not".
]]
local raycastAnswer: (any, any, any) -> any = function()
	return nil
end

function rbx.setRaycastResult(fn)
	raycastAnswer = fn or function()
		return nil
	end
end

function rbx.setServerTime(value)
	serverTime = value
end

function rbx.advanceServerTime(delta)
	serverTime += delta
end

function rbx.serverTime()
	return serverTime
end

rbx.workspace = newContainer("Folder")
rbx.workspace.Name = "Workspace"
-- The engine-synced clock. See rbx.setServerTime / rbx.advanceServerTime.
function rbx.workspace.GetServerTimeNow()
	return serverTime
end
-- Raycasts default to hitting nothing. rbx.setRaycastResult replaces the answer for the
-- library under test; a nil result is "the ray reached the end", which is what an unobstructed
-- line of sight looks like.
function rbx.workspace.Raycast(_, origin, direction, params)
	return raycastAnswer(origin, direction, params)
end

-- --------------------------------------------------------------- services --

local playerList = {}
local playerListReads = 0

function rbx.playerListReads()
	return playerListReads
end

function rbx.resetPlayerListReads()
	playerListReads = 0
end

local nextUserId = 0
-- Stands in for the Players service as a parent, so `player.Parent` is truthy while a
-- player is here and nil once they are not.
local playerService = { Name = "Players" }
local playerAdded, firePlayerAdded = makeSignal()
local playerRemoving, firePlayerRemoving = makeSignal()

-- CollectionService: tag -> instances, plus the two signals Zone wires to.
-- GetTagged allocates a fresh array exactly like the real one, and the call count
-- is exposed -- so if the module ever went back to polling it, that is visible.
local tagged = {}
local tagAdded = {}
local tagRemoved = {}
local tagGetCalls = 0

local function tagSignals(tag)
	if not tagAdded[tag] then
		local addedSignal, fireAdded, addedHandlers = makeSignal()
		local removedSignal, fireRemoved = makeSignal()
		tagAdded[tag] = { signal = addedSignal, fire = fireAdded, handlers = addedHandlers }
		tagRemoved[tag] = { signal = removedSignal, fire = fireRemoved }
	end
	return tagAdded[tag], tagRemoved[tag]
end

function rbx.addTag(instance, tag)
	tagSignals(tag)
	tagged[tag] = tagged[tag] or {}
	table.insert(tagged[tag], instance)
	tagAdded[tag].fire(instance)
end

function rbx.removeTag(instance, tag)
	tagSignals(tag)
	local list = tagged[tag]
	if list then
		local index = table.find(list, instance)
		if index then
			table.remove(list, index)
		end
	end
	tagRemoved[tag].fire(instance)
end

function rbx.tagGetCalls()
	return tagGetCalls
end

-- How many listeners the tag's added signal has. Duplicate wiring is otherwise
-- invisible: the set writes are idempotent, so only the connection count shows it.
function rbx.tagListeners(tag)
	local added = tagAdded[tag]
	if not added then
		return 0
	end
	local count = 0
	for _ in added.handlers do
		count += 1
	end
	return count
end
-- Every params table handed to PathfindingService:CreatePath, newest last.
local pathParams = {}
local pathWaypoints = {}
local pathStatus = nil

function rbx.pathParams()
	return pathParams
end

function rbx.clearPathParams()
	table.clear(pathParams)
end

-- What a computed path should report back. Enough to drive an agent past construction.
function rbx.setPathResult(status, waypoints)
	pathStatus = status
	pathWaypoints = waypoints or {}
end

-- Roblox's `time()`: seconds since the game started. Advanced by a test rather than real,
-- so anything driven by it can be stepped exactly.
local gameTime = 0

function rbx.time()
	return gameTime
end

function rbx.setTime(value)
	gameTime = value
end

-- game:BindToClose handlers, run only when a test asks.
local closeHandlers = {}

function rbx.fireBindToClose()
	for _, fn in closeHandlers do
		fn()
	end
end

-- DataStore stand-in state. See GetService("DataStoreService").
local dataStores = {}
local dataStoreFailures = 0
local dataStoreWrites = 0
local guidCounter = 0

-- Make the next `count` DataStore writes throw, so a test can drive the failure path.
function rbx.failDataStore(count)
	dataStoreFailures = count or 1
end

function rbx.dataStoreWrites()
	return dataStoreWrites
end

function rbx.dataStoreValue(storeName, key)
	local store = dataStores[storeName]
	return if store then store._values[key] else nil
end

local heartbeat, fireHeartbeat, heartbeatHandlers = makeSignal()

--[[
	Who `Players.LocalPlayer` answers with.

	A headless run has no client, so a test playing the part of one says which player it is.
	Resolved live through the service table's metatable, so a test can name its player at any
	point before the client module actually reads it.
]]
local localPlayer = nil

function rbx.setLocalPlayer(player)
	localPlayer = player
end

rbx.game = {
	JobId = "test-job-id",
	PlaceVersion = 1,
	-- Recorded rather than run: a shutdown hook is a thing a library REGISTERS, and whether
	-- it registered one is the assertion worth making. rbx.fireBindToClose() runs them.
	BindToClose = function(_, fn)
		table.insert(closeHandlers, fn)
	end,
	GetService = function(_, name)
		if name == "Players" then
			return setmetatable({
				GetPlayers = function()
					-- Counted: "how often does this hot path re-read the roster" is exactly the
					-- question a cached filter is answering, and it is invisible without a tally.
					playerListReads += 1
					local out = {}
					for _, player in playerList do
						table.insert(out, player)
					end
					return out
				end,
				GetPlayerByUserId = function(_, userId)
					for _, player in playerList do
						if player.UserId == userId then
							return player
						end
					end
					return nil
				end,
				PlayerAdded = playerAdded,
				PlayerRemoving = playerRemoving,
			}, {
				-- LocalPlayer resolves LIVE. A client module captures this service table at
				-- require time and reads LocalPlayer later, inside start(), so a field baked in
				-- here would answer with whatever was set before the require -- an ordering
				-- trap in every test that names its player afterwards.
				__index = function(_, key)
					if key == "LocalPlayer" then
						return localPlayer
					end
					return nil
				end,
			})
		elseif name == "RunService" then
			-- PostSimulation is Heartbeat's current name and the same signal; both are handed
			-- the frame delta. Library code uses whichever name it was written against, and a
			-- test steps one clock either way.
			return { Heartbeat = heartbeat, PostSimulation = heartbeat, PreSimulation = heartbeat }
		elseif name == "ReplicatedStorage" then
			return rbx.ReplicatedStorage
		elseif name == "GroupService" then
			-- Enough to require a module that asks for the service. Membership itself is
			-- an injected seam in the libraries here, so nothing tests through this.
			return {
				GetGroupsAsync = function(_, _userId)
					return {}
				end,
			}
		elseif name == "DataStoreService" then
			--[[
				An in-memory DataStore whose failures a test can DRIVE.

				The interesting behaviour of anything that writes to a DataStore is what it does
				when the write does not land -- throttled, over the size limit, service down --
				and that path is invisible against a stub that always succeeds. `rbx.failDataStore(n)`
				makes the next n writes throw the way the real service does.
			]]
			return {
				GetDataStore = function(_, storeName)
					local store = dataStores[storeName]
					if not store then
						store = { _name = storeName, _values = {} }
						function store.UpdateAsync(_, key, transform)
							dataStoreWrites += 1
							if dataStoreFailures > 0 then
								dataStoreFailures -= 1
								error(`DataStore request was throttled (simulated) for key {key}`, 0)
							end
							local updated = transform(store._values[key])
							store._values[key] = updated
							return updated
						end
						function store.GetAsync(_, key)
							return store._values[key]
						end
						function store.SetAsync(_, key, value)
							dataStoreWrites += 1
							if dataStoreFailures > 0 then
								dataStoreFailures -= 1
								error("DataStore request was throttled (simulated)", 0)
							end
							store._values[key] = value
						end
						dataStores[storeName] = store
					end
					return store
				end,
			}
		elseif name == "HttpService" then
			return {
				-- Sequential rather than random: a test asserting on session identity needs
				-- reproducible keys, and nothing here depends on them being unguessable.
				GenerateGUID = function()
					guidCounter += 1
					return `guid-{guidCounter}`
				end,
				JSONEncode = function(_, value)
					return tostring(value)
				end,
			}
		elseif name == "Debris" then
			-- Debris:AddItem is fire-and-forget cleanup. Recorded rather than timed: what a
			-- test cares about is that something was handed over to be reaped, not when.
			return {
				AddItem = function(_, instance, lifetime)
					table.insert(debrisItems, { instance = instance, lifetime = lifetime })
				end,
			}
		elseif name == "PathfindingService" then
			--[[
				A RECORDER, not a pathfinder. There is no navmesh here and nothing to compute
				against, so the only thing worth asserting is WHAT WAS ASKED FOR: the params
				handed to CreatePath. That is exactly where an option like `Costs` either
				arrives or is silently dropped, and dropping it looks identical to working
				until a bot walks over the thing it was told to avoid.

				`rbx.pathParams()` returns every params table handed over, newest last.
			]]
			return {
				CreatePath = function(_, params)
					table.insert(pathParams, params or {})
					local path = {
						ClassName = "Path",
						Status = pathStatus,
						-- Whatever the test last put in rbx.setPathWaypoints.
						GetWaypoints = function()
							return pathWaypoints
						end,
						ComputeAsync = function() end,
						Destroy = function() end,
					}
					function path.IsA(_, queried)
						return queried == "Path" or queried == "Instance"
					end
					return path
				end,
			}
		elseif name == "PhysicsService" then
			-- Enough to require a module that asks. Registering a collision group is a
			-- side effect nothing headless can observe, so it is a no-op that reports
			-- "not registered" -- which is the branch a library should handle anyway.
			return {
				RegisterCollisionGroup = function() end,
				IsCollisionGroupRegistered = function()
					return false
				end,
				CollisionGroupSetCollidable = function() end,
			}
		elseif name == "ProximityPromptService" then
			return { PromptTriggered = rbx.promptTriggered }
		elseif name == "CollectionService" then
			return {
				-- The write side. Tests used to seed `tagged` directly; library code that tags
				-- its own instances needs to go through the service like anything else.
				AddTag = function(_, instance, tag)
					local list = tagged[tag]
					if not list then
						list = {}
						tagged[tag] = list
					end
					if not table.find(list, instance) then
						table.insert(list, instance)
						local added = tagAdded[tag]
						if added then
							added.fire(instance)
						end
					end
				end,
				RemoveTag = function(_, instance, tag)
					local list = tagged[tag]
					if not list then
						return
					end
					local index = table.find(list, instance)
					if index then
						table.remove(list, index)
						local _, removed = tagSignals(tag)
						removed.fire(instance)
					end
				end,
				HasTag = function(_, instance, tag)
					return table.find(tagged[tag] or {}, instance) ~= nil
				end,
				GetTagged = function(_, tag)
					tagGetCalls += 1
					local out = {}
					for _, instance in tagged[tag] or {} do
						table.insert(out, instance)
					end
					return out
				end,
				GetInstanceAddedSignal = function(_, tag)
					local added = tagSignals(tag)
					return added.signal
				end,
				GetInstanceRemovedSignal = function(_, tag)
					local _, removed = tagSignals(tag)
					return removed.signal
				end,
			}
		end
		error(`rbx shim: GetService("{name}") is not implemented`)
	end,
}

-- Test controls.
function rbx.addPlayer(name, position)
	local hrp = newPart()
	hrp.Name = "HumanoidRootPart"
	hrp.Parent = { Name = "Character" }
	hrp.CFrame = cf(position or v3(0, 0, 0), 0)
	hrp.Position = position or v3(0, 0, 0)
	local character = newContainer("Model")
	character.Name = name
	character:Add(hrp)
	-- Parented, because library code checks `character.Parent` before acting on it -- a
	-- character that has been torn down mid-defer must not be resolved. An unparented
	-- character silently fails that guard and nothing spawns.
	rbx.workspace:Add(character)
	local characterAdded, fireCharacterAdded = makeSignal()
	local characterRemoving, fireCharacterRemoving = makeSignal()
	nextUserId += 1
	local attributes = {}
	local attributeSignals = {}
	local player = {
		Name = name,
		DisplayName = name,
		UserId = nextUserId,
		-- Truthy while they are in the server: library code checks `player.Parent` before
		-- talking to somebody who may already have left.
		Parent = playerService,
		Character = character,
		_hrp = hrp,
		CharacterAdded = characterAdded,
		CharacterRemoving = characterRemoving,
		-- Exposed so a test can drive a respawn: `player._fireCharacterAdded(character)`.
		_fireCharacterAdded = fireCharacterAdded,
		_fireCharacterRemoving = fireCharacterRemoving,
	}
	function player.GetAttribute(_, key)
		return attributes[key]
	end
	function player.SetAttribute(_, key, value)
		attributes[key] = value
		local entry = attributeSignals[key]
		if entry then
			entry.fire()
		end
	end
	function player.GetAttributeChangedSignal(_, key)
		local entry = attributeSignals[key]
		if not entry then
			local signal, fire = makeSignal()
			entry = { signal = signal, fire = fire }
			attributeSignals[key] = entry
		end
		return entry.signal
	end
	table.insert(playerList, player)
	firePlayerAdded(player)
	return player
end

--[[
	A fresh character, for driving a respawn:

	  local reborn = rbx.newCharacter("Ana")
	  player.Character = reborn
	  player._fireCharacterAdded(reborn)

	Built the same way addPlayer builds the first one, so a respawned character is not a
	different shape from the original -- which is exactly the difference a respawn bug
	would hide in.
]]
function rbx.newCharacter(name, position)
	local hrp = newPart()
	hrp.Name = "HumanoidRootPart"
	hrp.CFrame = cf(position or v3(0, 0, 0), 0)
	hrp.Position = position or v3(0, 0, 0)
	local character = newContainer("Model")
	character.Name = name
	character:Add(hrp)
	rbx.workspace:Add(character)
	return character
end

function rbx.movePlayer(player, position)
	player._hrp.Position = position
end

function rbx.removePlayer(player)
	local index = table.find(playerList, player)
	if index then
		table.remove(playerList, index)
	end
	-- Cleared BEFORE the signal, so a handler asking "are they still here" gets the right
	-- answer -- which is exactly what library code checks before sending them anything.
	player.Parent = nil
	firePlayerRemoving(player)
end

function rbx.dropCharacter(player)
	player._hrp.Parent = nil
	player.Character = nil
end

function rbx.step(dt)
	fireHeartbeat(dt or 1 / 60)
end

function rbx.heartbeatConnections()
	local count = 0
	for _ in heartbeatHandlers do
		count += 1
	end
	return count
end

-- Zone maintains its own player set from PlayerAdded/PlayerRemoving now, so a
-- reset that only emptied playerList would leave the module tracking ghosts.
function rbx.reset()
	local leaving = table.clone(playerList)
	table.clear(playerList)
	for _, player in leaving do
		firePlayerRemoving(player)
	end
end

-- Instances are plain tables here, so `typeof` needs teaching.
function rbx.typeof(value)
	if type(value) == "table" and value.ClassName then
		return "Instance"
	end
	return type(value)
end

return rbx
