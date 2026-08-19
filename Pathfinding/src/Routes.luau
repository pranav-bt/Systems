--!strict

-- Authored routes: ordered waypoint lists a body walks WITHOUT pathfinding.
--
-- Some movement isn't a pathfinding problem. Leading out of a spawn area the
-- navmesh can't route across, a patrol loop a designer laid out deliberately, a
-- scripted approach lane -- for these the route IS the answer, and asking
-- PathfindingService to rediscover it is both slower and worse (it smooths away
-- the exact shape that was authored). So a RouteFollower walks the waypoints
-- with raw MoveTo: no navmesh, no path computes, ever.
--
-- AUTHORING. Routes live as folders of BasePart markers under one container
-- (default workspace.BotRoutes), named in walk order -- use zero-padded names
-- ("01", "02", ...) so the lexical sort matches intent:
--
--   workspace.BotRoutes
--     SpawnExit    -> 01, 02, 03
--     PatrolNorth  -> 01, 02, 03, 04
--
-- Routes.load() reads that container once into a name -> positions registry;
-- Routes.get("PatrolNorth") is then a table lookup, so every bot spawned
-- afterwards shares one copy of the list.
--
-- THE CONTRACT. A follower is NOT a Mover: a Mover answers "go to this
-- position", a follower answers "walk this list". It reports the same STATUS
-- vocabulary though (Mover.MoverStatus), so driving code polls it identically
-- and an action maps Arrived -> Success and Stuck -> Failure exactly as it does
-- for a PathAgent. Keep it in its own body slot (body.route) beside body.mover;
-- the natural pattern is to walk a route out of spawn, then hand off to the
-- mover for everything after.
--
-- Being navmesh-free cuts both ways: nothing recovers a follower that wedges on
-- geometry, so a stall is reported as "Stuck" and the decision layer picks
-- something else. That is the trade you accept for exact authored movement.

local Mover = require(script.Parent.Mover)

local Routes = {}

local DEFAULT_CONTAINER = "BotRoutes"

export type Route = { Vector3 }

export type Mode = "once" | "loop" | "pingPong"

export type FollowerOptions = {
	mode: Mode?, -- "once" (default), "loop", or "pingPong"
	waypointReached: number?, -- distance that counts a waypoint reached (default 4)
	waypointTimeout: number?, -- no-progress seconds that marks the follower stuck (default 1.5)
	stuckProgress: number?, -- studs moved to still count as progressing (default 2)
	startAtNearest: boolean?, -- enter at the closest waypoint instead of the first (default false)
}

export type RouteFollower = {
	-- Walk this route: a positions array, or a name registered via Routes.load.
	-- nil stops and clears. Re-setting restarts from the entry waypoint.
	SetRoute: (RouteFollower, (Route | string)?) -> (),
	GetStatus: (RouteFollower) -> Mover.MoverStatus,
	-- 1-based index of the waypoint being walked toward, and the route length.
	-- Both 0 when idle -- for "resume where I left off" and debug output.
	Progress: (RouteFollower) -> (number, number),
	Stop: (RouteFollower) -> (),
	Destroy: (RouteFollower) -> (),
}

-- ---------------------------------------------------------------- authoring --

-- Ordered world positions from one folder of BasePart markers (lexical by name).
function Routes.fromFolder(folder: Instance?): Route
	local positions: Route = {}
	if not folder then
		return positions
	end

	local parts: { BasePart } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end
	table.sort(parts, function(a, b)
		return a.Name < b.Name
	end)

	for _, part in parts do
		table.insert(positions, part.Position)
	end
	return positions
end

local registry: { [string]: Route } = {}

-- Read every child folder of `container` (default workspace.BotRoutes) into the
-- registry, replacing what was there. Call once at startup, or again after
-- streaming in new route folders. Returns the registry (a live reference).
function Routes.load(container: Instance?): { [string]: Route }
	local root = container or workspace:FindFirstChild(DEFAULT_CONTAINER)
	table.clear(registry)
	if not root then
		return registry
	end
	for _, child in root:GetChildren() do
		local positions = Routes.fromFolder(child)
		if #positions > 0 then
			registry[child.Name] = positions
		end
	end
	return registry
end

-- A loaded route by name (nil when unknown -- callers assert or fall back).
function Routes.get(name: string): Route?
	return registry[name]
end

-- Every loaded route name, sorted. For debug dumps and editor tooling.
function Routes.names(): { string }
	local out: { string } = {}
	for name in registry do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- ----------------------------------------------------------------- follower --

type Resolved = {
	mode: Mode,
	waypointReached: number,
	waypointTimeout: number,
	stuckProgress: number,
	startAtNearest: boolean,
}

local function resolve(options: FollowerOptions?): Resolved
	local given: FollowerOptions = options or {}
	local mode: Mode = given.mode or "once"
	assert(
		mode == "once" or mode == "loop" or mode == "pingPong",
		`Pathfinding.Routes.follower: mode must be "once", "loop" or "pingPong"`
	)
	return {
		mode = mode,
		waypointReached = given.waypointReached or 4,
		waypointTimeout = given.waypointTimeout or 1.5,
		stuckProgress = given.stuckProgress or 2,
		startAtNearest = given.startAtNearest == true,
	}
end

-- Walk a route with raw Humanoid:MoveTo. One follower per living body; it runs
-- its own loop so callers never block, exactly like PathAgent.
function Routes.follower(humanoid: Humanoid, root: BasePart, options: FollowerOptions?): RouteFollower
	local opts = resolve(options)

	local route: Route? = nil
	local index = 0
	local step = 1 -- +1 forward, -1 walking a pingPong route back
	local running = true
	local finished = false -- a "once" route walked to its end
	local stuck = false

	local function alive(): boolean
		return running and root.Parent ~= nil and humanoid.Parent ~= nil and humanoid.Health > 0
	end

	local function moveTo(position: Vector3)
		pcall(function()
			humanoid:MoveTo(position)
		end)
	end

	local function nearestIndex(positions: Route): number
		local best, bestDistance = 1, math.huge
		for i, position in positions do
			local distance = (root.Position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = i, distance
			end
		end
		return best
	end

	-- Move past the waypoint just reached. False = the route is done, which only
	-- happens in "once" mode; loop and pingPong always have somewhere to go.
	local function advance(positions: Route): boolean
		local nextIndex = index + step
		if nextIndex >= 1 and nextIndex <= #positions then
			index = nextIndex
			return true
		end
		if opts.mode == "loop" then
			index = if step == 1 then 1 else #positions
			return true
		end
		if opts.mode == "pingPong" then
			-- Turn around, then step so the endpoint is not walked twice.
			step = -step
			index = math.clamp(index + step, 1, #positions)
			return true
		end
		return false
	end

	task.spawn(function()
		while running do
			local positions = route
			local target = if positions and not finished and alive() then positions[index] else nil
			if not target then
				task.wait(0.15)
				continue
			end

			moveTo(target)

			-- Wait until REACHED rather than for a fixed time: authored waypoints
			-- can be far apart. Only a genuine stall marks the follower stuck.
			local progressPos = root.Position
			local progressAt = os.clock()
			while alive() and route == positions do
				if (root.Position - target).Magnitude <= opts.waypointReached then
					stuck = false
					if not advance(positions :: Route) then
						finished = true
					end
					break
				end
				local now = os.clock()
				if (root.Position - progressPos).Magnitude >= opts.stuckProgress then
					progressPos = root.Position -- still moving; reset the stall timer
					progressAt = now
					stuck = false
				elseif now - progressAt >= opts.waypointTimeout then
					-- Nothing to fall back on by design. Report it and let the
					-- driving action decide (usually Failure, so utility moves on).
					stuck = true
					break
				end
				task.wait(0.08)
			end

			-- ALWAYS yield before the next waypoint. Reaching one costs no wait (the
			-- inner loop breaks immediately), so without this a body already inside
			-- waypointReached of its target -- a dense authored route, startAtNearest,
			-- or a single-waypoint loop -- would spin this loop with no yield at all
			-- and wedge the whole scheduler.
			if stuck then
				task.wait(0.3) -- do not spin re-issuing MoveTo into a wall
			else
				task.wait()
			end
		end
	end)

	local follower = {}

	function follower.SetRoute(_, next: (Route | string)?)
		step = 1
		finished = false
		stuck = false
		if next == nil then
			route = nil
			index = 0
			return
		end
		local positions: Route
		if type(next) == "string" then
			local found = registry[next]
			assert(found ~= nil, `Pathfinding.Routes: no route named "{next}" is loaded (call Routes.load first)`)
			positions = found
		else
			positions = next
		end
		assert(#positions > 0, "Pathfinding.Routes: a route needs at least one waypoint")
		route = positions
		index = if opts.startAtNearest then nearestIndex(positions) else 1
	end

	function follower.GetStatus(_): Mover.MoverStatus
		if not route or not alive() then
			return "Idle"
		end
		if finished then
			return "Arrived"
		end
		if stuck then
			return "Stuck"
		end
		return "Moving"
	end

	function follower.Progress(_): (number, number)
		local positions = route
		if not positions then
			return 0, 0
		end
		return index, #positions
	end

	function follower.Stop(_)
		route = nil
		index = 0
		step = 1
		finished = false
		stuck = false
		if alive() then
			moveTo(root.Position)
		end
	end

	function follower.Destroy(_)
		running = false
		route = nil
	end

	return (follower :: any) :: RouteFollower
end

return Routes
