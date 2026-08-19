--!strict

-- Shared types for the HTN package. Everything here is plain data and
-- functions over it -- no Roblox APIs anywhere in this package, so the whole
-- thing (planner AND executors) runs under Lune.
--
-- The split that makes HTN work: each primitive task has a PLANNING half
-- (condition + declared effects, simulated against a cloned world state while
-- the planner thinks ahead) and a RUNTIME half (an Operator -- the same
-- enter/update/exit lifecycle as a Bots Action -- that actually does the
-- thing). The planner never runs operators; executors never simulate effects.

-- The symbolic world the planner reasons over: a plain, shallow-clonable bag
-- of values ("hasWood", "atFire", counts, refs). Consumers DERIVE it from
-- live game state (a Bots blackboard, usually) via a state function; the
-- planner works on a clone and never touches the source.
export type WorldState = { [string]: any }

export type Condition = (state: WorldState) -> boolean
export type Effects = (state: WorldState) -> () -- mutate the SIMULATION clone

-- A primitive task's planning half. `condition` gates it during decomposition
-- AND is re-checked against fresh state before the step starts at runtime
-- (plan monitoring); `effects` declare what completing it will make true, so
-- the planner can think PAST it.
export type PrimitiveSpec = {
	condition: Condition?,
	effects: Effects?,
}

-- One way to accomplish a compound task: a guard plus the subtasks (compound
-- or primitive names) that do it, in order. Methods are tried strictly in
-- array order -- ordering IS the priority mechanism (SHOP-style). An empty
-- subtasks array is legal: "already satisfied, nothing to do".
export type Method = {
	name: string?, -- for the decomposition trace (default "method #n")
	condition: Condition?,
	subtasks: { string },
}

export type CompoundSpec = {
	methods: { Method },
}

-- A validated task library (build with Domain.new). Reusable across goals,
-- bots, and games; contains no runtime state.
export type Domain = {
	primitives: { [string]: PrimitiveSpec },
	compounds: { [string]: CompoundSpec },
}

export type PlanOptions = {
	maxDepth: number?, -- compound nesting cap (default 32) -- makes recursion safe
	maxSteps: number?, -- plan length cap (default 64)
	-- Total decompose() calls allowed (default 2000). Caps the BRANCHES explored,
	-- which maxDepth/maxSteps do not -- see Planner.luau.
	maxExpansions: number?,
	-- Decomposition-trace entries to record; 0 = off (default 64). The trace is
	-- how you answer "why will the bot not do the thing", so it is ON by default
	-- -- but a shipped game can silence it, and no domain can grow it without
	-- bound. See Planner.luau.
	traceLimit: number?,
}

-- A successful decomposition: the flat primitive sequence to execute, plus
-- the simulated world state after all of it (handy in tests and debugging).
export type Plan = {
	steps: { string },
	finalState: WorldState,
}

-- One record in the decomposition trace -- the "why did planning fail / why
-- this method" answer. Every attempt is recorded, successes and dead ends.
export type TraceEntry = {
	depth: number,
	task: string,
	kind: "primitive" | "method" | "backtrack" | "limit",
	method: string?, -- which method (kind = "method" / "backtrack")
	ok: boolean,
	reason: string?, -- "condition failed", "a subtask could not be decomposed", limit text
}
export type DecompositionTrace = { TraceEntry }

-- What an operator hook reports / how an operator ends -- deliberately the
-- same vocabulary as Bots actions, because operators ARE action-shaped.
export type OperatorResult = "Running" | "Success" | "Failure"
export type OperatorOutcome = "Success" | "Failure" | "Interrupted"

-- The runtime half of one primitive task. `owner` is the bot when running
-- under Bots (HTN.goal) or whatever you passed the Runner. At least one of
-- enter/update is required; exit always runs once the operator started,
-- whatever the outcome -- the same contract as Bots actions, so cleanup
-- habits transfer unchanged.
export type Operator = {
	requires: { string }?, -- body fields (aggregated onto the wrapper action under Bots)
	enter: ((owner: any) -> OperatorResult?)?,
	update: ((owner: any, dt: number) -> OperatorResult?)?,
	exit: ((owner: any, outcome: OperatorOutcome) -> ())?,
}

-- Live execution state for one plan run. Under Bots this sits in the bot's
-- personal blackboard at the goal's planKey, so it doubles as introspection:
-- what the plan is, where the bot is in it, how many replans it has burned,
-- and (after failures) the last decomposition trace.
export type RunState = {
	plan: { string }?,
	step: number,
	entered: boolean, -- current step's operator has started
	-- CONSECUTIVE replans without progress. Reset to 0 whenever a step completes,
	-- so replanLimit bounds thrash rather than a plan's lifetime adaptability.
	replans: number,
	lastTrace: DecompositionTrace?,
	failedReason: string?,
}

-- Everything the shared step engine (Execution.luau) needs to drive a plan;
-- built once per HTN.goal / Runner.
export type ExecutionContext = {
	label: string, -- for warnings: `goal "MaintainFire"`
	domain: Domain,
	root: string,
	state: (owner: any) -> WorldState,
	operators: { [string]: Operator },
	replanLimit: number,
	planOptions: PlanOptions?,
}

return {}
