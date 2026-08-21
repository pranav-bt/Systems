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

rbx.Vector3 = { new = v3 }

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
	PartType = {
		Block = "Block",
		Cylinder = "Cylinder",
		Ball = "Ball",
		Wedge = "Wedge",
		CornerWedge = "CornerWedge",
	},
}

-- ---------------------------------------------------------------- signals --

local function makeSignal()
	local handlers = {}
	local signal = {}
	function signal.Connect(_, fn)
		handlers[fn] = true
		return {
			Disconnect = function()
				handlers[fn] = nil
			end,
		}
	end
	local function fire(...)
		for fn in handlers do
			fn(...)
		end
	end
	return signal, fire, handlers
end

rbx.makeSignal = makeSignal

-- --------------------------------------------------------------- Instances --

local function newPart()
	local destroying, fireDestroying = makeSignal()
	local part = {
		ClassName = "Part",
		Name = "Part",
		Size = v3(1, 1, 1),
		CFrame = cf(v3(0, 0, 0), 0),
		Position = v3(0, 0, 0),
		Anchored = false,
		CanCollide = true,
		CanQuery = true,
		CanTouch = true,
		CollisionGroup = "Default",
		Shape = "Block",
		Transparency = 0,
		Parent = nil,
		Destroying = destroying,
	}
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
	function part.FindFirstChild(self, name)
		local children = self._children
		return if children then children[name] else nil
	end
	return part
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
	function container.GetChildren(self)
		local out = {}
		for _, kid in self._kids do
			table.insert(out, kid)
		end
		return out
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
		container._pivot = cf(v3(0, 0, 0), 0)
		function container.GetPivot(self)
			return self._pivot
		end
		function container.PivotTo(self, position)
			self._pivot = cf(position, 0)
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
			-- FireClient drops the player argument the real API takes first: a headless
			-- test has one client, and keeping the signature would only invite asserting
			-- on a value the shim invented.
			function remote.FireClient(_, _player, ...)
				fireToClient(...)
			end
			function remote.FireAllClients(_, ...)
				fireToClient(...)
			end
			function remote.FireServer(_, ...)
				fireToServer(...)
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

rbx.workspace = { Name = "Workspace" }

-- --------------------------------------------------------------- services --

local playerList = {}
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
	local character = { _children = { HumanoidRootPart = hrp } }
	function character.FindFirstChild(self, key)
		return self._children[key]
	end
	local player = { Name = name, Character = character, _hrp = hrp }
	table.insert(playerList, player)
	firePlayerAdded(player)
	return player
end

function rbx.movePlayer(player, position)
	player._hrp.Position = position
end

function rbx.removePlayer(player)
	local index = table.find(playerList, player)
	if index then
		table.remove(playerList, index)
	end
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
