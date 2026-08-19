--!strict

-- Generalized "moveables": authored objects (rafts, platforms, ...) that travel a
-- designer-made waypoint path, pausing at stops, carrying players who stand on
-- them. Works on ANY `Moveables` folder in the workspace -- present at load or
-- spawned later -- mirroring how Buildables generalizes authored folders.
--
-- Authored structure (see workspace.MapExtra.Moveables):
--   Moveables/
--     Object(s)/         -- the movers; each is a Model/BasePart with a `Path`
--       Raft             -- attribute (string) + optional `Speed` (studs/s)
--     Paths/
--       RaftPath/        -- one folder per path, named by the objects' `Path`
--         1_Stop         -- BasePart waypoints named `<index>_<Path|Stop>`
--         2_Path         -- index sets the order; Stop parts carry a `StopTime`
--         ...            -- attribute (seconds to pause there)
--
-- Objects ping-pong along the index-sorted waypoints (reverse at each end), face
-- their travel direction, and pause StopTime at each Stop. Movement is
-- server-authoritative and anchored (so it's exact); the client `MoveableRider`
-- carries the local character (the character stays client-owned, so translating it
-- there -- never here -- avoids rubber-banding). The server tags each mover with
-- `MoveableRide` for the client to find.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local DEBUG = false -- gate verbose per-object setup prints

local MOVEABLES_FOLDER_NAME = "Moveables"
local OBJECT_FOLDER_NAMES = { object = true, objects = true }
local PATHS_FOLDER_NAME = "paths"
local PATH_ATTRIBUTE = "Path"
local SPEED_ATTRIBUTE = "Speed"
local STOP_TIME_ATTRIBUTE = "StopTime"
local RIDE_TAG = "MoveableRide" -- client MoveableRider watches this tag

local DEFAULT_SPEED = 16 -- studs/s when an object has no Speed attribute
local ARRIVE_EPSILON = 0.1 -- studs; snap + advance once this close to the target
local YAW_LERP_RATE = 5 -- higher = snappier turns; exponential, framerate-independent

type Waypoint = { position: Vector3, isStop: boolean, stopTime: number }
type MoveState = {
	object: PVInstance,
	waypoints: { Waypoint },
	targetIndex: number,
	direction: number, -- +1 / -1 for the ping-pong
	speed: number,
	resumeAt: number, -- os.clock() to resume after a stop (0 = moving)
}

local Moveables = {}

local states: { [Instance]: MoveState } = {}
local folderConnections: { [Instance]: { RBXScriptConnection } } = {}
local started = false

local function lowerName(instance: Instance): string
	return string.lower(instance.Name)
end

local function findObjectsFolder(moveables: Instance): Instance?
	for _, child in moveables:GetChildren() do
		if OBJECT_FOLDER_NAMES[lowerName(child)] then
			return child
		end
	end
	return nil
end

local function findPathsFolder(moveables: Instance): Instance?
	for _, child in moveables:GetChildren() do
		if lowerName(child) == PATHS_FOLDER_NAME then
			return child
		end
	end
	return nil
end

-- Waypoint parts are named `<index>_<Path|Stop>`: the index sets traversal order,
-- and a Stop pauses for its StopTime attribute. Non-conforming parts are skipped.
local function parseWaypoint(part: BasePart): (number?, Waypoint?)
	local indexText, kindText = string.match(part.Name, "^(%w+)_(%w+)$")
	local index = indexText and tonumber(indexText)
	if not index or not kindText then
		return nil, nil
	end

	local isStop = string.lower(kindText) == "stop"
	local stopTime = 0
	if isStop then
		-- Tolerant read: a number attribute OR a numeric string ("3") both work.
		stopTime = tonumber(part:GetAttribute(STOP_TIME_ATTRIBUTE)) or 0
		if stopTime <= 0 then
			warn(`[Moveables] Stop '{part:GetFullName()}' has no positive {STOP_TIME_ATTRIBUTE} attribute -- it won't pause`)
		end
	end

	return index, { position = part.Position, isStop = isStop, stopTime = stopTime }
end

local function buildWaypoints(pathFolder: Instance): { Waypoint }
	local indexed: { { index: number, waypoint: Waypoint } } = {}
	for _, child in pathFolder:GetChildren() do
		if child:IsA("BasePart") then
			local index, waypoint = parseWaypoint(child)
			if index and waypoint then
				table.insert(indexed, { index = index, waypoint = waypoint })
			end
		end
	end

	table.sort(indexed, function(a, b)
		return a.index < b.index
	end)

	local waypoints: { Waypoint } = {}
	for _, entry in indexed do
		table.insert(waypoints, entry.waypoint)
	end
	return waypoints
end

local function anchor(object: Instance)
	for _, descendant in object:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	if object:IsA("BasePart") then
		object.Anchored = true
	end
end

local function startObject(moveables: Instance, object: Instance)
	if states[object] then
		return
	end
	if not object:IsA("Model") and not object:IsA("BasePart") then
		return
	end

	local pathName = object:GetAttribute(PATH_ATTRIBUTE)
	if typeof(pathName) ~= "string" then
		return -- not a mover (no Path attribute) -- ignore it
	end

	local pathsFolder = findPathsFolder(moveables)
	local pathFolder = pathsFolder and pathsFolder:FindFirstChild(pathName)
	if not pathFolder then
		warn(`[Moveables] '{object.Name}' Path '{pathName}' not found under {moveables:GetFullName()}/Paths`)
		return
	end

	local waypoints = buildWaypoints(pathFolder)
	if #waypoints < 2 then
		warn(`[Moveables] path '{pathName}' needs at least 2 waypoints; has {#waypoints}`)
		return
	end

	local speedAttr = object:GetAttribute(SPEED_ATTRIBUTE)
	local speed = if typeof(speedAttr) == "number" and speedAttr > 0 then speedAttr else DEFAULT_SPEED

	anchor(object) -- server-authoritative CFrame movement

	states[object] = {
		object = object :: PVInstance,
		waypoints = waypoints,
		targetIndex = 1,
		direction = 1,
		speed = speed,
		resumeAt = 0,
	}
	CollectionService:AddTag(object, RIDE_TAG)

	if DEBUG then
		local summary = {}
		for i, waypoint in waypoints do
			table.insert(summary, `{i}:{if waypoint.isStop then `Stop({waypoint.stopTime}s)` else "Path"}`)
		end
		print(`[Moveables] '{object.Name}' -> {pathName} @ {speed} studs/s: {table.concat(summary, ", ")}`)
	end
end

local function stopObject(object: Instance)
	if states[object] then
		states[object] = nil
		CollectionService:RemoveTag(object, RIDE_TAG)
	end
end

local function stepState(state: MoveState, dt: number)
	local object = state.object
	local currentCF = object:GetPivot()
	local currentPos = currentCF.Position
	local now = os.clock()
	local paused = now < state.resumeAt

	local target = state.waypoints[state.targetIndex]
	local toTarget = target.position - currentPos
	local dist = toTarget.Magnitude

	-- Advance the position (unless paused at a stop).
	local newPos = currentPos
	if not paused then
		local step = state.speed * dt
		if dist <= math.max(step, ARRIVE_EPSILON) then
			newPos = target.position
			-- Arrived: pick the next waypoint (reversing at either end), honor a stop.
			local nextIndex = state.targetIndex + state.direction
			if nextIndex > #state.waypoints then
				state.direction = -1
				nextIndex = #state.waypoints - 1
			elseif nextIndex < 1 then
				state.direction = 1
				nextIndex = 2
			end
			state.targetIndex = nextIndex

			if target.isStop and target.stopTime > 0 then
				state.resumeAt = now + target.stopTime
			end
		else
			newPos = currentPos + (toTarget / dist) * step
		end
	end

	-- Lerp the yaw toward the travel direction rather than snapping, so corners and
	-- the ping-pong reversals turn smoothly. Position stays exact; while paused the
	-- object holds its facing (doesn't spin in place).
	local targetRot = currentCF.Rotation
	if not paused then
		local look = Vector3.new(toTarget.X, 0, toTarget.Z)
		if look.Magnitude > 1e-3 then
			targetRot = CFrame.lookAt(Vector3.zero, look.Unit, Vector3.yAxis).Rotation
		end
	end
	local blendedRot = currentCF.Rotation:Lerp(targetRot, 1 - math.exp(-dt * YAW_LERP_RATE))
	object:PivotTo(CFrame.new(newPos) * blendedRot)
end

local function update(dt: number)
	for object, state in states do
		if object.Parent then
			stepState(state, dt)
		else
			stopObject(object)
		end
	end
end

local function registerMoveables(moveables: Instance)
	if folderConnections[moveables] then
		return
	end
	local connections: { RBXScriptConnection } = {}
	folderConnections[moveables] = connections

	local objectsFolder = findObjectsFolder(moveables)

	local function hookObjectsFolder(folder: Instance)
		for _, child in folder:GetChildren() do
			startObject(moveables, child)
		end
		table.insert(
			connections,
			folder.ChildAdded:Connect(function(child)
				startObject(moveables, child)
			end)
		)
		table.insert(
			connections,
			folder.ChildRemoved:Connect(function(child)
				stopObject(child)
			end)
		)
	end

	if objectsFolder then
		hookObjectsFolder(objectsFolder)
	end
	-- The Object folder may be parented in after the Moveables folder (incremental
	-- spawn); pick it up when it appears.
	table.insert(
		connections,
		moveables.ChildAdded:Connect(function(child)
			if not objectsFolder and OBJECT_FOLDER_NAMES[lowerName(child)] then
				objectsFolder = child
				hookObjectsFolder(child)
			end
		end)
	)
end

local function unregisterMoveables(moveables: Instance)
	local connections = folderConnections[moveables]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
		folderConnections[moveables] = nil
	end
	for object in states do
		if object:IsDescendantOf(moveables) then
			stopObject(object)
		end
	end
end

function Moveables.start()
	if started then
		return
	end
	started = true

	for _, descendant in workspace:GetDescendants() do
		if descendant:IsA("Folder") and descendant.Name == MOVEABLES_FOLDER_NAME then
			registerMoveables(descendant)
		end
	end

	workspace.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Folder") and descendant.Name == MOVEABLES_FOLDER_NAME then
			registerMoveables(descendant)
		end
	end)

	workspace.DescendantRemoving:Connect(function(descendant)
		if folderConnections[descendant] then
			unregisterMoveables(descendant)
		end
	end)

	-- Self-contained tick: PostSimulation fires once per physics/render step with the
	-- frame delta as its sole argument, matching update(dt) exactly. No external
	-- scheduler required.
	RunService.PostSimulation:Connect(update)
end

return Moveables
