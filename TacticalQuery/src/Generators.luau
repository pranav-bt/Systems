--!strict

-- Built-in candidate generators. Each builder returns a plain Types.Generator
-- function -- a custom generator is just any (context, probes) -> { points }
-- function passed straight into the query spec; nothing here is special.
--
-- ring/grid produce FLOATING points and leave them ungrounded: the Engine snaps
-- the cheap-stage survivors through probes.snapToGround, so a probe is only ever
-- spent on a candidate that is still in the running (see SNAPPING in
-- Engine.luau). `tagged` reads authored positions (CollectionService tags) which
-- are trusted where they are -- pair it with `snap = false` on the query.
--
-- ring/grid construct Vector3 offsets, so they are Roblox-specific (like the
-- default Probes). A grid-world game replaces them with its own generator and
-- keeps everything else.

local Types = require(script.Parent.Types)

local CollectionService = game:GetService("CollectionService")

local Generators = {}

-- tag -> the tagged BaseParts, cached because GetTagged allocates a fresh array
-- of every tagged instance on each call and `tagged` is run per bot, per query.
-- Cached INSTANCES rather than positions, so a marker that moves is still read
-- correctly; the signals below cover parts appearing and disappearing.
local taggedParts: { [string]: { BasePart } } = {}

local function partsFor(tag: string): { BasePart }
	local cached = taggedParts[tag]
	if cached then
		return cached
	end
	local parts: { BasePart } = {}
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("BasePart") then
			table.insert(parts, instance)
		end
	end
	taggedParts[tag] = parts
	-- Connected once per tag, for the lifetime of the server.
	local function invalidate()
		taggedParts[tag] = nil
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(invalidate)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(invalidate)
	return parts
end

local function ctxGet(context: Types.Context, key: string, generator: string): any
	local value = context[key]
	assert(value ~= nil, `TacticalQuery: generator "{generator}" needs context["{key}"] (not supplied to run)`)
	return value
end

-- Concentric rings of candidates around context[around] (default "self").
-- Rings are staggered against each other so candidates don't line up in rays.
function Generators.ring(config: {
	around: string?,
	radii: { number },
	perRing: number?,
}): Types.Generator
	assert(type(config) == "table", "TacticalQuery.Generators.ring: a config table is required")
	assert(
		type(config.radii) == "table" and #config.radii > 0,
		"TacticalQuery.Generators.ring: config.radii must be a non-empty array of numbers"
	)
	for _, radius in config.radii do
		assert(type(radius) == "number" and radius > 0, "TacticalQuery.Generators.ring: radii must be numbers > 0")
	end
	local perRing = config.perRing or 12
	assert(type(perRing) == "number" and perRing >= 3, "TacticalQuery.Generators.ring: perRing must be >= 3")
	local aroundKey = config.around or "self"

	return function(context)
		local origin = ctxGet(context, aroundKey, "ring")
		local points = {}
		for ringIndex, radius in config.radii do
			local stagger = (ringIndex - 1) * (math.pi / perRing)
			for step = 1, perRing do
				local angle = stagger + (step / perRing) * 2 * math.pi
				table.insert(points, origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
			end
		end
		return points
	end
end

-- A square grid of candidates centered on context[around] (default "self"):
-- x/z from -extent to +extent in `spacing` steps. Denser than ring; use for
-- thorough area searches, mind the candidate count ((2*extent/spacing + 1)^2).
function Generators.grid(config: {
	around: string?,
	extent: number,
	spacing: number,
}): Types.Generator
	assert(type(config) == "table", "TacticalQuery.Generators.grid: a config table is required")
	assert(
		type(config.extent) == "number" and config.extent > 0,
		"TacticalQuery.Generators.grid: config.extent must be a number > 0"
	)
	assert(
		type(config.spacing) == "number" and config.spacing > 0,
		"TacticalQuery.Generators.grid: config.spacing must be a number > 0"
	)
	local aroundKey = config.around or "self"

	return function(context)
		local origin = ctxGet(context, aroundKey, "grid")
		local points = {}
		local extent = config.extent
		local spacing = config.spacing
		local x = -extent
		while x <= extent do
			local z = -extent
			while z <= extent do
				table.insert(points, origin + Vector3.new(x, 0, z))
				z += spacing
			end
			x += spacing
		end
		return points
	end
end

-- Authored positions: every BasePart carrying the CollectionService `tag`
-- (level designers place and tag cover points, snipe perches, rally spots).
-- `range` (with `around`, default "self") keeps only points near the agent.
-- Authored points are trusted where they are, so pair this generator with
-- `snap = false` on the query (grounding them is merely wasteful, not wrong).
-- The tagged set is cached per tag and invalidated by CollectionService.
function Generators.forgetTagged(tag: string?)
	if tag == nil then
		table.clear(taggedParts)
	else
		taggedParts[tag] = nil
	end
end

function Generators.tagged(config: {
	tag: string,
	around: string?,
	range: number?,
}): Types.Generator
	assert(type(config) == "table", "TacticalQuery.Generators.tagged: a config table is required")
	assert(
		type(config.tag) == "string" and config.tag ~= "",
		"TacticalQuery.Generators.tagged: config.tag must be a non-empty string"
	)
	assert(
		config.range == nil or (type(config.range) == "number" and config.range > 0),
		"TacticalQuery.Generators.tagged: config.range must be a number > 0 when set"
	)
	local aroundKey = config.around or "self"

	return function(context)
		local range = config.range
		local origin = if range then ctxGet(context, aroundKey, "tagged") else nil
		local points = {}
		for _, part in partsFor(config.tag) do
			local position = part.Position
			if origin == nil or (position - origin).Magnitude <= range :: number then
				table.insert(points, position)
			end
		end
		return points
	end
end

return Generators
