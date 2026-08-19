--!strict

-- The default Roblox world probes: raycasts and ground snapping via
-- workspace:Raycast, plus a coarse NON-YIELDING reachability heuristic. This
-- is the only module that touches world geometry -- a game with a different
-- world (voxel grid, player-built bases) supplies its own Probes table (or
-- overrides single fields) and every query, generator, and test works
-- unchanged.
--
-- FILTERING MATTERS. Pass a RaycastParams excluding things rays must ignore:
-- character models (or a target's own limbs read as "cover" to the LOS
-- tests), bot bodies, and debris. Most games maintain one exclusion list
-- already; hand it in here.
--
-- REACHABILITY is deliberately a heuristic: a torso-height ray to the point
-- plus ground-continuity samples along the way. Fast, never yields, good on
-- open maps; blind to real routing (a wall gap it can't see around, a ledge
-- needing a detour). For complex maps swap `isReachable` for a real
-- pathfinding check -- the README shows the PathfindingService version and
-- when it's safe to let it yield.

local Types = require(script.Parent.Types)

local Probes = {}

export type Config = {
	params: RaycastParams?, -- exclusion filter for ALL rays (characters!)
	-- Optional ceiling on probe-priced work, shared with anything else that meters
	-- world queries (Perception.Budget fits by shape). See Engine.luau BUDGET.
	budget: Types.Budget?,
	groundProbeHeight: number?, -- how far above a candidate the ground ray starts (default 4)
	groundMaxDrop: number?, -- how far below it may fall and still count as floor (default 12)
	torsoHeight: number?, -- body-height offset for reachability rays (default 2.5)
	stride: number?, -- spacing of ground-continuity samples (default 4)
}

function Probes.new(config: Config?): Types.Probes
	local cfg: Config = config or {}
	local params = cfg.params
	if params == nil then
		local fresh = RaycastParams.new()
		fresh.FilterType = Enum.RaycastFilterType.Exclude
		params = fresh
	end
	local probeHeight = cfg.groundProbeHeight or 4
	local maxDrop = cfg.groundMaxDrop or 12
	local torso = cfg.torsoHeight or 2.5
	local stride = cfg.stride or 4

	local probes = {} :: Types.Probes
	local budget = cfg.budget
	probes.budget = budget

	-- METERING LIVES HERE, not around a test stage. Charging per candidate-stage
	-- meant one token could stand for many rays: `hidden` casts one per configured
	-- height, a query may carry several expensive tests, and the default
	-- isReachable casts a torso ray plus floor(distance/stride) ground samples.
	-- A budget shared with Perception -- where a token IS one raycast -- was
	-- therefore being overspent several-fold by this package. Metering the probe
	-- functions makes a token mean the same thing everywhere, and custom tests are
	-- covered for free: they can only reach the world through this table.
	--
	-- A refused probe records starvation and answers "nothing there" (nil/false).
	-- The Engine reads `starved` between stages and abstains from the whole query
	-- rather than returning a position chosen from a half-probed field.
	local function afford(): boolean
		if budget == nil or budget:take(1) then
			return true
		end
		probes.starved = true
		return false
	end

	probes.raycast = function(origin: Vector3, direction: Vector3): Types.ProbeHit?
		if not afford() then
			return nil
		end
		local hit = workspace:Raycast(origin, direction, params)
		return if hit then { position = hit.Position, instance = hit.Instance } else nil
	end

	probes.snapToGround = function(point: Vector3): Vector3?
		if not afford() then
			return nil
		end
		local origin = point + Vector3.new(0, probeHeight, 0)
		local hit = workspace:Raycast(origin, Vector3.new(0, -(probeHeight + maxDrop), 0), params)
		return if hit then hit.Position else nil
	end

	probes.isReachable = function(from: Vector3, to: Vector3): boolean
		if not afford() then
			return false
		end
		-- Torso-height ray: anything solid between the bodies means blocked.
		local a = from + Vector3.new(0, torso, 0)
		local b = to + Vector3.new(0, torso, 0)
		if workspace:Raycast(a, b - a, params) then
			return false
		end
		-- Ground continuity: sample the walk line every `stride` studs; a
		-- missing floor (gap, cliff) means unreachable.
		local flat = to - from
		local length = Vector3.new(flat.X, 0, flat.Z).Magnitude
		local steps = math.floor(length / stride)
		for step = 1, steps do
			if not afford() then
				return false -- every ground sample is its own probe
			end
			local sample = from:Lerp(to, step / (steps + 1)) + Vector3.new(0, torso, 0)
			if not workspace:Raycast(sample, Vector3.new(0, -(torso + maxDrop), 0), params) then
				return false
			end
		end
		return true
	end

	return probes
end

-- Wrap ANY probes table so its probes draw on `budget`, one token each. The
-- built-in Probes.new already meters; this is for the custom worlds the package
-- exists to support -- a voxel grid or player-built base supplies its own probe
-- functions, and without this it would silently lose budgeting when metering
-- moved out of the Engine.
--
--   local probes = TacticalQuery.Probes.meter(myVoxelProbes, sharedBudget)
--
-- Returns a NEW table; the original is untouched.
function Probes.meter(probes: Types.Probes, budget: Types.Budget): Types.Probes
	assert(type(probes) == "table", "TacticalQuery.Probes.meter: a probes table is required")
	assert(
		type(budget) == "table" and type(budget.take) == "function",
		"TacticalQuery.Probes.meter: a Budget (take/available) is required"
	)
	local metered = {} :: Types.Probes
	metered.budget = budget

	local function afford(): boolean
		if budget:take(1) then
			return true
		end
		metered.starved = true
		return false
	end

	metered.raycast = function(origin, direction)
		if not afford() then
			return nil
		end
		return probes.raycast(origin, direction)
	end
	metered.snapToGround = function(point)
		if not afford() then
			return nil
		end
		return probes.snapToGround(point)
	end
	local reachable = probes.isReachable
	if reachable then
		metered.isReachable = function(from, to)
			if not afford() then
				return false
			end
			return reachable(from, to)
		end
	end
	return metered
end

return Probes
