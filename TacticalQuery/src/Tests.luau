--!strict

-- Built-in test builders. Each returns a plain Types.Test table -- writing a
-- custom test is just writing that table yourself; nothing here is special.
--
-- Tests reference positions by CONTEXT KEY (config.to = "threat" reads
-- context.threat at run time), which is what keeps one query definition
-- reusable across every bot. A test whose context key is missing at run time
-- errors loudly, naming the key.
--
-- The vector-math tests (distance/direction/spacing) only call METHODS on the
-- values (`-`, `.Magnitude`, `.Unit`, `:Dot`), so they work with anything
-- vector-shaped. `hidden`/`exposed` construct Vector3 height offsets and are
-- therefore Roblox-specific, like the default Probes.
--
-- LINE-OF-SIGHT CAVEAT: `hidden`/`exposed` cast rays between world positions.
-- If those rays can hit character bodies, a target's own limbs read as
-- "cover" -- exclude characters via the RaycastParams you build the probes
-- with (see Probes.new and the README).

local Curves = require(script.Parent.Curves)
local Types = require(script.Parent.Types)

local Tests = {}

local function req(config: { [string]: any }, key: string, builder: string): any
	local value = config[key]
	assert(value ~= nil, `TacticalQuery.Tests.{builder}: config.{key} is required`)
	return value
end

local function ctxGet(context: Types.Context, key: string, testName: string): any
	local value = context[key]
	assert(value ~= nil, `TacticalQuery: test "{testName}" needs context["{key}"] (not supplied to run)`)
	return value
end

-- Prefer positions at a distance from context[to]: score 1 at `best` studs,
-- 0 at `worst`, linear between (best < worst prefers near; best > worst
-- prefers far). For "about this far", pair with Curves.band in a custom test.
function Tests.distance(config: {
	to: string,
	best: number,
	worst: number,
	weight: number?,
	name: string?,
}): Types.Test
	local to = req(config, "to", "distance")
	local best = req(config, "best", "distance")
	local worst = req(config, "worst", "distance")
	local name = config.name or `distance({to})`
	return {
		name = name,
		cost = "cheap",
		weight = config.weight,
		score = function(point, context)
			local target = ctxGet(context, to, name)
			return Curves.linear((point - target).Magnitude, worst, best)
		end,
	}
end

-- Prefer positions in the direction of context[toward] as seen from
-- context[from]: 1 dead ahead, 0.5 perpendicular, 0 behind. `invert = true`
-- flips it -- the "retreat away from the threat" test.
function Tests.direction(config: {
	from: string,
	toward: string,
	invert: boolean?,
	weight: number?,
	name: string?,
}): Types.Test
	local fromKey = req(config, "from", "direction")
	local towardKey = req(config, "toward", "direction")
	local name = config.name or `direction({towardKey})`
	return {
		name = name,
		cost = "cheap",
		weight = config.weight,
		score = function(point, context)
			local from = ctxGet(context, fromKey, name)
			local toward = ctxGet(context, towardKey, name)
			local offset = point - from
			local aim = toward - from
			if offset.Magnitude < 1e-3 or aim.Magnitude < 1e-3 then
				return 0.5 -- degenerate: no direction to speak of
			end
			local dot = offset.Unit:Dot(aim.Unit)
			local score = (dot + 1) / 2
			return if config.invert then 1 - score else score
		end,
	}
end

-- Don't stack on allies: 0 on top of the nearest position in context[allies]
-- (an array), 1 at `radius` or farther from all of them. Empty array = 1.
function Tests.spacing(config: {
	allies: string,
	radius: number,
	weight: number?,
	name: string?,
}): Types.Test
	local alliesKey = req(config, "allies", "spacing")
	local radius = req(config, "radius", "spacing")
	assert(type(radius) == "number" and radius > 0, "TacticalQuery.Tests.spacing: config.radius must be > 0")
	local name = config.name or `spacing({alliesKey})`
	return {
		name = name,
		cost = "cheap",
		weight = config.weight,
		score = function(point, context)
			local allies = ctxGet(context, alliesKey, name)
			local worst = 1
			for _, ally in allies :: { any } do
				worst = math.min(worst, (point - ally).Magnitude / radius)
			end
			return worst
		end,
	}
end

-- COVER: how hidden is a body standing at the candidate, as seen from
-- context[from]? Casts one ray from `from` to the candidate plus each height
-- offset (default { 2.5 } -- roughly a torso; add e.g. { 1, 4 } to demand
-- full-height cover); score = fraction of rays blocked. Pass the threat's
-- EYE/HEAD position as `from`, not its feet.
function Tests.hidden(config: {
	from: string,
	heights: { number }?,
	weight: number?,
	name: string?,
}): Types.Test
	local fromKey = req(config, "from", "hidden")
	local heights = config.heights or { 2.5 }
	assert(#heights > 0, "TacticalQuery.Tests.hidden: config.heights must be non-empty when set")
	local name = config.name or `hidden({fromKey})`
	return {
		name = name,
		cost = "expensive",
		weight = config.weight,
		score = function(point, context, probes)
			local origin = ctxGet(context, fromKey, name)
			local blocked = 0
			for _, height in heights do
				local target = point + Vector3.new(0, height, 0)
				if probes.raycast(origin, target - origin) then
					blocked += 1
				end
			end
			return blocked / #heights
		end,
	}
end

-- The opposite: how visible is context[to] from a body standing at the
-- candidate? For attack/peek positions that need line of sight. Rays go from
-- candidate + `eye` (default 2.5) to the target plus each height offset
-- (default { 0 }); score = fraction of rays that reach unblocked.
function Tests.exposed(config: {
	to: string,
	eye: number?,
	heights: { number }?,
	weight: number?,
	name: string?,
}): Types.Test
	local toKey = req(config, "to", "exposed")
	local eye = config.eye or 2.5
	local heights = config.heights or { 0 }
	assert(#heights > 0, "TacticalQuery.Tests.exposed: config.heights must be non-empty when set")
	local name = config.name or `exposed({toKey})`
	return {
		name = name,
		cost = "expensive",
		weight = config.weight,
		score = function(point, context, probes)
			local target = ctxGet(context, toKey, name)
			local origin = point + Vector3.new(0, eye, 0)
			local visible = 0
			for _, height in heights do
				local dest = target + Vector3.new(0, height, 0)
				if not probes.raycast(origin, dest - origin) then
					visible += 1
				end
			end
			return visible / #heights
		end,
	}
end

-- Can the agent actually get there? Runs at the validate stage (top-K only)
-- because reachability is the priciest probe. Requires probes.isReachable --
-- the default Roblox probes provide a coarse non-yielding heuristic; swap in
-- a real pathfinding check for complex maps (see README).
function Tests.reachable(config: {
	from: string?,
	name: string?,
}?): Types.Test
	local cfg = config or {}
	local fromKey = cfg.from or "self"
	local name = cfg.name or "reachable"
	return {
		name = name,
		cost = "validate",
		score = function(point, context, probes)
			local isReachable = probes.isReachable
			assert(
				isReachable ~= nil,
				`TacticalQuery: test "{name}" needs probes.isReachable (the default probes provide one)`
			)
			local origin = ctxGet(context, fromKey, name)
			return if isReachable(origin, point) then 1 else nil
		end,
	}
end

return Tests
