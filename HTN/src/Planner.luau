--!strict

-- The decomposition planner: SHOP-style total-order HTN. Given a domain, a
-- root task, and a world-state snapshot, it expands compounds through their
-- methods IN ORDER (ordering is the priority mechanism), simulating each
-- primitive's declared effects forward on a working clone -- so later steps
-- are planned against the world AS IT WILL BE, not as it is. A dead end
-- backtracks: the failed method's simulated effects and emitted steps are
-- rolled back, and the next method gets a try.
--
-- Pure logic: no clocks, no Roblox APIs, the input state is cloned and never
-- touched. Errors thrown by consumer condition/effects functions propagate to
-- the caller (under Bots, the goal's error containment turns them into a goal
-- Failure).
--
-- Every attempt -- method tried, condition failed, primitive emitted,
-- backtrack, cap hit -- is recorded in the DECOMPOSITION TRACE returned
-- alongside the plan (or alongside nil when no plan exists). Planners without
-- this are the ones teams abandon; when a bot "won't do the thing", read the
-- trace, not the domain.
--
-- maxDepth caps compound nesting and maxSteps caps plan length, which is what
-- makes recursive methods ("gather wood, then try the root again") safe.
--
-- The trace is capped by traceLimit (default 64) and can be switched off with 0.
-- Recording is deliberately on by default -- HTN.s failure mode is "the bot will
-- not do the thing", and this is the only thing that answers it -- but a domain
-- that backtracks hard must not be able to allocate an unbounded trace, and a
-- shipped game should be able to stop paying for one at all.

local Types = require(script.Parent.Types)

local DEFAULT_MAX_DEPTH = 32
local DEFAULT_MAX_STEPS = 64
local DEFAULT_TRACE_LIMIT = 64
-- decompose() calls allowed per plan. maxDepth and maxSteps cap NESTING and plan
-- LENGTH; neither caps how many branches are ATTEMPTED, and the method loop
-- recurses per method per compound -- so b methods at depth d can explore on the
-- order of b^d failed decompositions, synchronously, inside one goal adoption.
-- Small hand-written domains are nowhere near this; a generated or carelessly
-- recursive one can spend a whole frame. This is the cap that makes the other
-- two honest.
local DEFAULT_MAX_EXPANSIONS = 2000

local Planner = {}

-- Append one trace entry, up to `limit` (0 = tracing off). Every recording site
-- goes through here so no path can grow the trace without bound.
local function record(trace: Types.DecompositionTrace, limit: number, entry: Types.TraceEntry)
	if limit <= 0 or #trace >= limit then
		return
	end
	table.insert(trace, entry)
end

-- Roll `target` back to `snapshot` in place (callers up the stack hold the
-- same table reference, so restoring must mutate, not reassign).
local function restore(target: Types.WorldState, snapshot: Types.WorldState)
	table.clear(target)
	for key, value in snapshot do
		target[key] = value
	end
end

-- Mutable per-plan counters, so the recursion carries one table rather than an
-- ever-growing argument list.
type Budget = { expansions: number, maxExpansions: number }

local function decompose(
	domain: Types.Domain,
	task: string,
	state: Types.WorldState,
	steps: { string },
	trace: Types.DecompositionTrace,
	traceLimit: number,
	budget: Budget,
	depth: number,
	maxDepth: number,
	maxSteps: number
): boolean
	budget.expansions += 1
	if budget.expansions > budget.maxExpansions then
		record(trace, traceLimit, {
			depth = depth,
			task = task,
			kind = "limit",
			ok = false,
			reason = `exceeded maxExpansions ({budget.maxExpansions})`,
		})
		return false
	end
	local primitive = domain.primitives[task]
	if primitive then
		if #steps >= maxSteps then
			record(trace, traceLimit, {
				depth = depth,
				task = task,
				kind = "limit",
				ok = false,
				reason = `plan would exceed maxSteps ({maxSteps})`,
			})
			return false
		end
		if primitive.condition and not primitive.condition(state) then
			record(
				trace,
				traceLimit,
				{ depth = depth, task = task, kind = "primitive", ok = false, reason = "condition failed" }
			)
			return false
		end
		if primitive.effects then
			primitive.effects(state)
		end
		table.insert(steps, task)
		record(trace, traceLimit, { depth = depth, task = task, kind = "primitive", ok = true })
		return true
	end

	-- Domain.new guarantees resolution, and Planner.plan validates the root.
	local compound = domain.compounds[task] :: Types.CompoundSpec
	if depth >= maxDepth then
		record(trace, traceLimit, {
			depth = depth,
			task = task,
			kind = "limit",
			ok = false,
			reason = `decomposition exceeds maxDepth ({maxDepth})`,
		})
		return false
	end

	for index, method in compound.methods do
		local label = method.name or `method #{index}`
		if method.condition and not method.condition(state) then
			record(
				trace,
				traceLimit,
				{ depth = depth, task = task, kind = "method", method = label, ok = false, reason = "condition failed" }
			)
			continue
		end
		record(trace, traceLimit, { depth = depth, task = task, kind = "method", method = label, ok = true })

		local stateSnapshot = table.clone(state)
		local stepCount = #steps
		local succeeded = true
		for _, subtask in method.subtasks do
			if
				not decompose(domain, subtask, state, steps, trace, traceLimit, budget, depth + 1, maxDepth, maxSteps)
			then
				succeeded = false
				break
			end
		end
		if succeeded then
			return true
		end

		-- Backtrack: undo this method's simulated effects and emitted steps,
		-- then let the next method try.
		record(trace, traceLimit, {
			depth = depth,
			task = task,
			kind = "backtrack",
			method = label,
			ok = false,
			reason = "a subtask could not be decomposed",
		})
		restore(state, stateSnapshot)
		for i = #steps, stepCount + 1, -1 do
			steps[i] = nil
		end
	end
	return false
end

-- Decompose `root` against a CLONE of `state`. Returns the plan (nil when no
-- decomposition exists) and the full trace, always. An empty plan (zero
-- steps) is a legitimate success: the root is already satisfied.
function Planner.plan(
	domain: Types.Domain,
	root: string,
	state: Types.WorldState,
	options: Types.PlanOptions?
): (Types.Plan?, Types.DecompositionTrace)
	assert(type(domain) == "table" and domain.primitives and domain.compounds, "HTN.Planner.plan: a Domain is required")
	assert(
		type(root) == "string" and (domain.primitives[root] ~= nil or domain.compounds[root] ~= nil),
		`HTN.Planner.plan: root task "{tostring(root)}" is not in the domain`
	)
	assert(type(state) == "table", "HTN.Planner.plan: a world-state table is required")
	local maxDepth = (options and options.maxDepth) or DEFAULT_MAX_DEPTH
	local maxSteps = (options and options.maxSteps) or DEFAULT_MAX_STEPS
	local traceLimit = if options and options.traceLimit ~= nil then options.traceLimit else DEFAULT_TRACE_LIMIT
	local maxExpansions = (options and options.maxExpansions) or DEFAULT_MAX_EXPANSIONS

	local working = table.clone(state)
	local steps: { string } = {}
	local trace: Types.DecompositionTrace = {}
	local budget: Budget = { expansions = 0, maxExpansions = maxExpansions }
	if not decompose(domain, root, working, steps, trace, traceLimit, budget, 0, maxDepth, maxSteps) then
		return nil, trace
	end
	return { steps = steps, finalState = working }, trace
end

return Planner
