--!strict

-- The reference Mover: a thin follower around Roblox PathfindingService. Given
-- a goal position it computes a navmesh path (which routes around the fixed map
-- geometry) and walks the waypoints with Humanoid:MoveTo. One agent per living
-- body; it runs its own loop so callers never block -- drive it by calling
-- SetGoal each tick and polling GetStatus (see Mover.luau for the contract and
-- the status semantics).
--
-- Self-contained: every tunable is an option on new(), no globals. Any system
-- exposing the same four methods substitutes for it.
--
-- COMPUTATIONS GO THROUGH THE BROKER (Paths.luau), not straight to
-- PathfindingService: a squad that all receive a destination in one frame would
-- otherwise fire a burst of simultaneous ComputeAsync calls with nothing bounding
-- them. The broker caps concurrency, ages queued requests so none starve, and
-- lets a moved goal cancel the computation it invalidated.
--
-- IDLE AGENTS COST NOTHING. An agent with no goal, or parked at its destination,
-- suspends its loop entirely rather than polling; SetGoal and Destroy resume it.
--
-- Recompute triggers: the goal moves past a threshold (a chased enemy), a repath
-- timer elapses (dynamic obstacles / being stuck), or the path fails (then a
-- straight-line MoveTo fallback). While parked at the destination it SLEEPS --
-- no computes, no polling -- so holding a post is free. Every risky call is
-- guarded so a body that dies mid-path can't error the loop.

local PathfindingService = game:GetService("PathfindingService")

local Mover = require(script.Parent.Mover)
local Paths = require(script.Parent.Paths)

export type PathAgent = Mover.Mover

export type Options = {
	agentRadius: number?, -- CreatePath agent radius (default 2)
	agentHeight: number?, -- CreatePath agent height (default 5)
	agentCanJump: boolean?, -- CreatePath jump permission (default true)
	--[[
		PathfindingModifier costs, by Label: `{ Water = 20, Furniture = math.huge }`.

		THE ONLY WAY TO SAY "WALKABLE, BUT DON'T". Without it the navmesh has no notion
		of a surface it should avoid, and anything technically standable is fair game --
		a crafting table with flat collidable parts three studs up is a platform as far
		as PathfindingService is concerned, so a route across the room goes OVER it. The
		waypoint sits a stud above the floor, an R6 humanoid cannot step onto it, and the
		agent wedges: reporting Moving, position frozen, and stall detection never firing
		because each repath produces the same route and resets it.

		`math.huge` means impassable. The LABEL half is authored in the game, on
		PathfindingModifier instances -- nothing here creates them.

		Read at every CreatePath, so the adaptive spacing rebuild keeps them.
	]]
	costs: { [string]: number }?,
	repathInterval: number?, -- periodic recompute (default 3.0; chasing repaths sooner via drift)
	repathThreshold: number?, -- goal drift that forces a recompute (default 8)
	waypointTimeout: number?, -- no-progress time that marks a segment stalled (default 1.5)
	waypointReached: number?, -- distance that counts a waypoint (and the goal) reached (default 4)
	waypointSpacing: number?, -- coarse starting spacing; smooth straight runs (default 120)
	waypointSpacingMin: number?, -- finest spacing after adaptive halving (default 4)
	stuckProgress: number?, -- studs moved to still count as progressing (default 2)
	straightLineMax: number?, -- on NoPath, only straight-line to a goal within this range (default 24)
	-- Queue priority for this agent's path computations; higher runs sooner when
	-- the broker is saturated (default 0). Give fleeing/reacting agents a lift
	-- over patrollers. See Paths.luau.
	priority: number?,
	debug: boolean?, -- draw computed paths in workspace.BotPathDebug (default false)
}

-- What this agent's compute closure hands back through the broker.
type PathComputation = {
	status: Enum.PathStatus,
	waypoints: { PathWaypoint },
}

type Resolved = {
	agentRadius: number,
	agentHeight: number,
	agentCanJump: boolean,
	costs: { [string]: number }?,
	repathInterval: number,
	repathThreshold: number,
	waypointTimeout: number,
	waypointReached: number,
	waypointSpacing: number,
	waypointSpacingMin: number,
	stuckProgress: number,
	straightLineMax: number,
	priority: number,
	debug: boolean,
}

local PathAgent = {}

local DEBUG_FOLDER_NAME = "BotPathDebug"

local function resolve(options: Options?): Resolved
	local given: Options = options or {}
	local costs = given.costs
	if costs ~= nil then
		assert(type(costs) == "table", "Pathfinding.PathAgent: `costs` must be a table of label -> number")
		for label, cost in costs do
			assert(
				type(label) == "string" and type(cost) == "number",
				`Pathfinding.PathAgent: cost "{tostring(label)}" must be a string label mapped to a number`
			)
		end
	end
	return {
		agentRadius = given.agentRadius or 2,
		agentHeight = given.agentHeight or 5,
		agentCanJump = if given.agentCanJump == nil then true else given.agentCanJump,
		-- Left nil when unset rather than defaulted to an empty table, so an agent that
		-- names no costs hands CreatePath exactly what it handed it before this existed.
		costs = costs,
		repathInterval = given.repathInterval or 3.0,
		repathThreshold = given.repathThreshold or 8,
		waypointTimeout = given.waypointTimeout or 1.5,
		waypointReached = given.waypointReached or 4,
		waypointSpacing = given.waypointSpacing or 120,
		waypointSpacingMin = given.waypointSpacingMin or 4,
		stuckProgress = given.stuckProgress or 2,
		straightLineMax = given.straightLineMax or 24,
		priority = given.priority or 0,
		debug = if given.debug == nil then false else given.debug,
	}
end

local function debugFolder(): Folder
	local existing = workspace:FindFirstChild(DEBUG_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = DEBUG_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function debugMarker(parent: Instance, position: Vector3, color: Color3, size: number): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(size, size, size)
	part.CFrame = CFrame.new(position)
	part.Anchored = true
	part.CanCollide = false -- MUST NOT collide: a collidable debug part would alter the navmesh
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.2
	part.Parent = parent
	return part
end

local function debugLine(parent: Instance, from: Vector3, to: Vector3, color: Color3): Part?
	local delta = to - from
	local distance = delta.Magnitude
	if distance < 0.05 then
		return nil
	end
	local part = Instance.new("Part")
	part.Size = Vector3.new(0.15, 0.15, distance)
	part.CFrame = CFrame.lookAt(from + delta / 2, to)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.4
	part.Parent = parent
	return part
end

function PathAgent.new(humanoid: Humanoid, root: BasePart, options: Options?): PathAgent
	local opts = resolve(options)
	local desiredGoal: Vector3? = nil
	local running = true
	-- Internal movement status. "Idle" and "Arrived" are derived on query (see
	-- GetStatus); "Stuck" is sticky until real progress resumes or a new goal is
	-- set, so pollers can't miss it between recovery attempts.
	local status: Mover.MoverStatus = "Computing"

	-- ADAPTIVE WaypointSpacing. Coarse spacing => the pathfinder emits waypoints
	-- only at real corners, so the bot walks long straight runs in one continuous
	-- MoveTo (smooth, no braking at intermediate nodes). If it STALLS on a coarse
	-- segment (MoveTo straight-lines and clips a wall/edge the fine navmesh curved
	-- around), the agent halves the spacing and recomputes a finer path; resets to
	-- coarse on arrival / a new goal. Changing WaypointSpacing needs a fresh Path.
	local currentSpacing = opts.waypointSpacing
	local function buildPath(): Path
		return PathfindingService:CreatePath({
			AgentRadius = opts.agentRadius,
			AgentHeight = opts.agentHeight,
			AgentCanJump = opts.agentCanJump,
			WaypointSpacing = currentSpacing,
			-- nil when unset, which is the same table CreatePath received before costs
			-- were an option at all.
			Costs = opts.costs,
		})
	end
	local path = buildPath()

	-- Halve the spacing (finer path) on a stall; returns whether it changed.
	local function reduceSpacing(): boolean
		if currentSpacing <= opts.waypointSpacingMin then
			return false
		end
		currentSpacing = math.max(opts.waypointSpacingMin, currentSpacing * 0.5)
		path = buildPath()
		return true
	end
	local function resetSpacing()
		if currentSpacing ~= opts.waypointSpacing then
			currentSpacing = opts.waypointSpacing
			path = buildPath()
		end
	end

	local function alive(): boolean
		return running and root.Parent ~= nil and humanoid.Parent ~= nil and humanoid.Health > 0
	end

	local function moveTo(position: Vector3)
		pcall(function()
			humanoid:MoveTo(position)
		end)
	end

	-- Fallback when there's no computed path: only straight-line toward the goal
	-- if it's CLOSE (a minor gap the navmesh missed). If it's far, the goal is
	-- genuinely unreachable from here -- hold position rather than marching blindly
	-- off a ledge toward it.
	local function fallbackMove(goal: Vector3)
		if (root.Position - goal).Magnitude <= opts.straightLineMax then
			status = "Moving" -- minor navmesh gap: nudge straight toward it
			moveTo(goal)
		else
			status = "Unreachable" -- no path and too far to nudge: hold
			moveTo(root.Position)
		end
	end

	local function goalDrifted(from: Vector3): boolean
		local current = desiredGoal
		return current == nil or (current - from).Magnitude > opts.repathThreshold
	end

	-- Debug: this agent's drawn path parts (cleared + redrawn each compute).
	local debugParts: { Instance } = {}
	local function clearDebug()
		for _, part in debugParts do
			part:Destroy()
		end
		table.clear(debugParts)
	end
	local function drawPath(waypoints: { PathWaypoint }, goal: Vector3, pathStatus: Enum.PathStatus)
		clearDebug()
		if not opts.debug then
			return
		end
		local folder = debugFolder()
		local goalMarker = debugMarker(folder, goal + Vector3.new(0, 1, 0), Color3.fromRGB(255, 220, 60), 1.6)
		table.insert(debugParts, goalMarker)
		print(`[Pathfinding] path {pathStatus.Name}: {#waypoints} waypoints -> {tostring(goal)}`)

		local previous: Vector3? = nil
		for _, waypoint in waypoints do
			local color = if waypoint.Action == Enum.PathWaypointAction.Jump
				then Color3.fromRGB(60, 200, 255)
				elseif waypoint.Action == Enum.PathWaypointAction.Walk then Color3.fromRGB(90, 230, 110)
				else Color3.fromRGB(230, 90, 230) -- Custom (PathfindingLink traversal)
			local marker = debugMarker(folder, waypoint.Position, color, 0.9)
			table.insert(debugParts, marker)
			if previous then
				local line = debugLine(folder, previous, waypoint.Position, Color3.fromRGB(235, 235, 235))
				if line then
					table.insert(debugParts, line)
				end
			end
			previous = waypoint.Position
		end
	end

	-- SLEEPING. An agent with no goal, or one parked at its destination, has
	-- nothing to do until SetGoal says otherwise -- so it SUSPENDS rather than
	-- polling. A hundred idle or posted agents used to cost a hundred wakeups
	-- every 0.15s between them; now they cost nothing at all, and SetGoal (or
	-- Destroy) resumes whoever is asleep.
	local sleeper: thread? = nil

	local function sleep()
		sleeper = coroutine.running()
		coroutine.yield()
	end

	local function wake()
		local thread = sleeper
		if thread then
			sleeper = nil
			task.spawn(thread)
		end
	end

	-- The in-flight broker request, if any, and the goal it is computing a path to.
	-- SetGoal cancels it once the goal has moved past repathThreshold from that
	-- goal: a queued request then never runs, and one already computing has its
	-- result discarded rather than walked to (see Paths.luau).
	local pending: Paths.Handle? = nil
	local pendingResult: Paths.Result? = nil
	local computingFor: Vector3? = nil

	-- Ask the broker for a path and suspend until it answers. Returns the result,
	-- or nil if the agent was destroyed while waiting.
	--
	-- Everything Roblox-specific about a navmesh computation lives in the closure
	-- below -- the broker itself only knows "run this, it might yield". That is
	-- what lets a voxel or grid pathfinder share the same queue.
	local function computePath(from: Vector3, to: Vector3): Paths.Result?
		pendingResult = nil
		computingFor = to
		local thread = coroutine.running()
		pending = Paths.request({
			priority = opts.priority,
			compute = function(): PathComputation?
				path:ComputeAsync(from, to)
				local pathStatus = path.Status
				return {
					status = pathStatus,
					waypoints = if pathStatus == Enum.PathStatus.Success then path:GetWaypoints() else {},
				}
			end,
			onComplete = function(result)
				pendingResult = result
				pending = nil
				computingFor = nil
				task.spawn(thread)
			end,
		})
		coroutine.yield()
		return pendingResult
	end

	task.spawn(function()
		while running do
			local goal = desiredGoal
			if not goal or not alive() then
				sleep() -- nothing to move toward; SetGoal/Destroy wakes us
				continue
			end

			-- PARKED AT THE DESTINATION: rest. A goal stays set for as long as the
			-- driving action runs (a bot holding a post keeps SetGoal-ing the same
			-- spot), and recomputing a path to where we already stand cannot change
			-- the outcome. Sleeping rather than polling means a posted guard costs
			-- the scheduler nothing until its goal actually moves.
			if (root.Position - goal).Magnitude <= opts.waypointReached then
				resetSpacing() -- next journey starts coarse/smooth again
				sleep()
				continue
			end

			local result = computePath(root.Position, goal)
			if not running then
				break
			end
			if result == nil or result.cancelled then
				continue -- superseded: the goal moved while we were queued
			end

			local computation = result.value :: PathComputation?
			if computation == nil then
				clearDebug()
				fallbackMove(goal) -- ComputeAsync errored
				task.wait(0.4)
				continue
			end

			local waypoints = computation.waypoints
			drawPath(waypoints, goal, computation.status) -- draws even on NoPath, so you see where it stops

			if computation.status ~= Enum.PathStatus.Success then
				-- Diagnostic: when the real path fails, probe tiny nearby hops. If a
				-- short hop also fails, the bot is standing OFF the navmesh (its floor
				-- isn't navigable); if a short hop SUCCEEDS, the bot is on navmesh and
				-- the goal is simply unreachable from here (disconnected island).
				-- Debug-only, and deliberately direct rather than brokered: these are
				-- diagnostic probes, not movement, and they must not queue behind the
				-- fleet's real work.
				if opts.debug then
					local function probeOnMesh(from: Vector3): boolean
						for _, offset in { Vector3.new(9, 0, 0), Vector3.new(-9, 0, 0), Vector3.new(0, 0, 9) } do
							local probed = pcall(function()
								path:ComputeAsync(from, from + offset)
							end)
							if probed and path.Status == Enum.PathStatus.Success then
								return true
							end
						end
						return false
					end
					local startOnMesh = probeOnMesh(root.Position)
					local goalOnMesh = probeOnMesh(goal)
					print(
						`[Pathfinding] NoPath: start on-mesh? {startOnMesh} | goal on-mesh? {goalOnMesh}`
							.. ` | start={tostring(root.Position)} goal={tostring(goal)}`
					)
				end
				fallbackMove(goal) -- no full path (e.g. NoPath): nudge if close, else hold
				task.wait(0.4)
				continue
			end

			-- A usable path: report Moving -- unless we're flagged Stuck, which only
			-- real progress (below) or a new goal may clear.
			if status ~= "Stuck" then
				status = "Moving"
			end

			local capturedGoal = goal
			local repathAt = os.clock() + opts.repathInterval
			local stalled = false

			for index = 2, #waypoints do -- skip [1], the current position
				if not alive() or goalDrifted(capturedGoal) or os.clock() >= repathAt then
					break
				end

				local waypoint = waypoints[index]
				if waypoint.Action == Enum.PathWaypointAction.Jump then
					pcall(function()
						humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
					end)
				end
				moveTo(waypoint.Position)

				-- Wait until REACHED (then advance) -- NOT a fixed time, since a coarse
				-- waypoint can be far and take a while. Only a genuine STALL (no
				-- progress for waypointTimeout) triggers a finer recompute.
				local progressPos = root.Position
				local progressAt = os.clock()
				while alive() do
					if (root.Position - waypoint.Position).Magnitude <= opts.waypointReached then
						break -- reached; advance to next waypoint
					end
					if goalDrifted(capturedGoal) or os.clock() >= repathAt then
						break
					end
					local now = os.clock()
					if (root.Position - progressPos).Magnitude >= opts.stuckProgress then
						progressPos = root.Position -- still moving; reset the stall timer
						progressAt = now
						if status == "Stuck" then
							status = "Moving" -- unwedged: real progress resumed
						end
					elseif now - progressAt >= opts.waypointTimeout then
						stalled = reduceSpacing() -- stuck on this segment -> finer path
						if not stalled then
							status = "Stuck" -- already at the finest spacing and still no progress
						end
						break
					end
					task.wait(0.08)
				end

				if stalled then
					break -- recompute with the finer spacing
				end
			end

			-- Yield before looping. Arrival is handled at the top of the loop; the
			-- paths that reach HERE want a fresh compute (goal drifted, repath
			-- timer elapsed, stalled onto finer spacing). One frame costs nothing
			-- against those, and it guarantees the loop can never spin on a path
			-- that produced no walkable segment.
			task.wait()
		end
	end)

	local agent = {}
	function agent:SetGoal(position: Vector3?)
		local previous = desiredGoal
		-- A genuinely new destination starts coarse/smooth again (a same-position
		-- re-set, e.g. the per-tick march, keeps any finer spacing it adapted to).
		if position and (not previous or (position - previous).Magnitude > opts.repathThreshold) then
			resetSpacing()
			status = "Computing" -- report Computing until the next compute lands
		end
		desiredGoal = position

		-- Did the destination actually MOVE? A driving action calls SetGoal every
		-- tick with the same spot, and that must stay free.
		local moved = if position == nil
			then previous ~= nil
			else (previous == nil or (position - previous).Magnitude > 1e-3)
		if not moved then
			return
		end

		--[[
			The in-flight computation is for the wrong place only once the goal has drifted
			past repathThreshold from the goal it is computing to -- the same drift the walk
			itself tolerates before it repaths (goalDrifted). Cancelling means a queued request
			never runs at all, and one already computing has its result discarded instead of
			walked to.

			It used to cancel on ANY move. A chaser re-setting a target that shuffles a stud a
			tick then cancelled every tick and re-queued at the back of the broker each time,
			losing the age that is its only protection against starvation: under load it never
			got a path at all. Now a near-enough computation finishes, the walk starts, and the
			walk's own drift check takes over.
		]]
		local inFlight = pending
		local target = computingFor
		if inFlight and (position == nil or target == nil or (position - target).Magnitude > opts.repathThreshold) then
			inFlight:cancel()
		end
		wake() -- a sleeping agent has somewhere to be
	end
	function agent:GetStatus(): Mover.MoverStatus
		local goal = desiredGoal
		if not goal or not alive() then
			return "Idle" -- no destination, or no living body to move
		end
		if (root.Position - goal).Magnitude <= opts.waypointReached then
			return "Arrived"
		end
		return status
	end
	function agent:Stop()
		desiredGoal = nil
		local inFlight = pending
		if inFlight then
			inFlight:cancel()
		end
		if alive() then
			moveTo(root.Position)
		end
		wake() -- let the loop notice the goal is gone and go back to sleep
	end
	function agent:Destroy()
		running = false
		desiredGoal = nil
		local inFlight = pending
		if inFlight then
			inFlight:cancel()
		end
		clearDebug()
		wake() -- a sleeping agent must be resumed to observe running = false and exit
	end
	return (agent :: any) :: PathAgent
end

return PathAgent
