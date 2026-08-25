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
	if type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
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
}

-- -------------------------------------------------------------------- Enum --

rbx.Enum = {
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
		end
		return rawget(part, key)
	end
	function part.__newindex(self, key, value)
		if key == "CFrame" then
			rawset(self, "_cframe", value)
		elseif key == "Position" then
			rawset(self, "_cframe", cf(value, rawget(self, "_cframe")._yaw))
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
		return class == "Part" or class == "BasePart"
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
		local kids = rawget(self, "_kids")
		if not kids then
			kids = {}
			rawset(self, "_kids", kids)
		end
		table.insert(kids, child)
		child.Parent = self
	end
	function part.FindFirstChild(self, name)
		local children = self._children
		return if children then children[name] else nil
	end
	return setmetatable(part, { __index = part.__index, __newindex = part.__newindex })
end

local function newContainer(className)
	local childAdded, fireChildAdded = makeSignal()
	local childRemoved, fireChildRemoved = makeSignal()
	local container = {
		ClassName = className,
		Name = className,
		Parent = nil,
		_kids = {},
		ChildAdded = childAdded,
		ChildRemoved = childRemoved,
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
	function container.Add(self, child)
		table.insert(self._kids, child)
		child.Parent = self
		fireChildAdded(child)
	end
	function container.Remove(self, child)
		local index = table.find(self._kids, child)
		if index then
			table.remove(self._kids, index)
		end
		child.Parent = nil
		fireChildRemoved(child)
	end
	if className == "Model" then
		container.PrimaryPart = nil
		container._scale = 1
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
	return container
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

rbx.Instance = {
	new = function(class)
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
				if key == "CFrame" then
					return rawget(self, "_cframe")
				elseif key == "Position" then
					return rawget(self, "_cframe").Position
				elseif key == "WorldCFrame" then
					local parent = rawget(self, "Parent")
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
		elseif class == "RemoteEvent" then
			local toServer, fireToServer, serverHandlers = makeSignal()
			local toClient, fireToClient = makeSignal()
			local remote = {
				ClassName = "RemoteEvent",
				Name = "RemoteEvent",
				Parent = nil,
				OnServerEvent = toServer,
				OnClientEvent = toClient,
				_serverHandlers = serverHandlers,
			}
			function remote.IsA(_, queried)
				return queried == "RemoteEvent" or queried == "Instance"
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
		error(`rbx shim: Instance.new("{class}") is not implemented`)
	end,
}

-- A real container: libraries provision folders into Workspace and then look for them.
rbx.workspace = newContainer("Folder")
rbx.workspace.Name = "Workspace"

-- --------------------------------------------------------------- services --

local playerList = {}
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
local heartbeat, fireHeartbeat, heartbeatHandlers = makeSignal()

rbx.game = {
	GetService = function(_, name)
		if name == "Players" then
			return {
				GetPlayers = function()
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
			}
		elseif name == "RunService" then
			return { Heartbeat = heartbeat }
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
