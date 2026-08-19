--!strict

-- Constructor + validator for Queries, in the same style as Bots.Goal.new:
-- Query.new(spec) checks the whole shape at the DEFINITION SITE and returns
-- the spec with `run` attached, so a malformed query errors right where it is
-- written, with a message naming the field.
--
-- Definitions are reusable across bots because they reference CONTEXT KEYS
-- ("self", "threat"), not captured values -- callers supply the values per
-- run: `query:run({ self = pos, threat = target })`. Probes may be passed per
-- run; when omitted, the package-level default (wired by init.luau) is used.

local Engine = require(script.Parent.Engine)
local Types = require(script.Parent.Types)

local VALID_COSTS = { cheap = true, expensive = true, validate = true }

local Query = {}

local defaultProbes: Types.Probes? = nil

-- init.luau wires the Roblox default probes here so query:run() works out of
-- the box. Call it yourself to make a custom world the package-wide default.
function Query.setDefaultProbes(probes: Types.Probes?)
	defaultProbes = probes
end

-- Validate one query table. `label` says where the check is happening.
function Query.validate(spec: any, label: string): Types.Query
	assert(type(spec) == "table", `{label}: a query must be a table`)
	assert(type(spec.name) == "string" and spec.name ~= "", `{label}: query.name must be a non-empty string`)
	local who = `query "{spec.name}"`
	assert(type(spec.generator) == "function", `{label}: {who} needs a generator(context, probes) function`)
	assert(
		type(spec.tests) == "table" and #spec.tests > 0,
		`{label}: {who} needs a non-empty tests array (a hard filter is a test that returns nil)`
	)
	for index, test in spec.tests :: { any } do
		local where = `{label}: {who}.tests[{index}]`
		assert(type(test) == "table", `{where}: a test must be a table`)
		assert(type(test.name) == "string" and test.name ~= "", `{where}: test.name must be a non-empty string`)
		assert(
			VALID_COSTS[test.cost] == true,
			`{where}: test "{test.name}" cost must be "cheap", "expensive" or "validate"`
		)
		assert(
			type(test.score) == "function",
			`{where}: test "{test.name}" needs a score(point, context, probes) function`
		)
		assert(
			test.weight == nil or (type(test.weight) == "number" and test.weight > 0),
			`{where}: test "{test.name}" weight must be a positive number when set`
		)
	end
	assert(
		spec.maxExpensive == nil or (type(spec.maxExpensive) == "number" and spec.maxExpensive >= 1),
		`{label}: {who}.maxExpensive must be a number >= 1 when set`
	)
	assert(
		spec.topK == nil or (type(spec.topK) == "number" and spec.topK >= 1),
		`{label}: {who}.topK must be a number >= 1 when set`
	)
	assert(spec.snap == nil or type(spec.snap) == "boolean", `{label}: {who}.snap must be a boolean when set`)
	return spec :: Types.Query
end

-- Define a query, validated where it is written.
function Query.new(spec: Types.Query): Types.Query
	Query.validate(spec, "TacticalQuery.Query.new")

	-- Partition the tests ONCE. `tests` is immutable after this point, so redoing
	-- it per run (as Engine used to) rebuilt three tables to rediscover a fact
	-- known at the definition site -- and a query re-run from an action costs that
	-- every step, per bot.
	spec.stages = Engine.partition(spec.tests)

	function spec.run(_, context: Types.Context, probes: Types.Probes?): (Types.Candidate?, Types.RunInfo)
		assert(type(context) == "table", `TacticalQuery: query "{spec.name}" run needs a context table`)
		local resolved = probes or defaultProbes
		assert(
			resolved ~= nil,
			`TacticalQuery: query "{spec.name}" was run without probes and no default is set`
				.. ` (require the package root once, or pass probes to run)`
		)
		return Engine.run(spec, context, resolved)
	end

	return spec
end

return Query
