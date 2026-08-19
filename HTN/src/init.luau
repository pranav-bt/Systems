--!strict

-- HTN: a SHOP-style total-order hierarchical task network planner -- the
-- deliberation layer for AI whose action ORDERING must be discovered at
-- runtime (workers with tool dependencies, survival companions, multi-step
-- objectives with interchangeable means).
--
--   Domain   -- Domain.new(spec): the task library. Compound tasks decompose
--               through priority-ordered methods into primitives; primitives
--               carry a planning condition + declared effects.
--   Planner  -- Planner.plan(domain, root, state): simulate effects forward
--               on a cloned world state, backtrack on dead ends, emit a flat
--               primitive plan + a full decomposition trace.
--   goal     -- HTN.goal(spec): the Bots adapter. Returns a table SHAPED like
--               a Bots Goal (this package never requires Bots) whose single
--               action plans on enter, steps operators on update, monitors
--               each step's condition against fresh state, and replans on
--               failure/invalidation. Utility arbitration stays above:
--               reactive goals interrupt HTN plans through the normal
--               commitment math.
--   Runner   -- Runner.new(config): the same execution engine, standalone,
--               for consumers not running Bots.
--
-- No Roblox APIs anywhere -- the whole package (planner and executors) runs
-- under Lune. Positions, items, and identities live inside the consumer's
-- world-state symbols and operators; the package only ever sees plain data.

local BotsGoal = require(script.BotsGoal)
local Domain = require(script.Domain)
local Execution = require(script.Execution)
local Planner = require(script.Planner)
local Runner = require(script.Runner)
local Types = require(script.Types)

-- Public types, re-exported so callers can annotate everything from one require.
export type WorldState = Types.WorldState
export type Condition = Types.Condition
export type Effects = Types.Effects
export type PrimitiveSpec = Types.PrimitiveSpec
export type Method = Types.Method
export type CompoundSpec = Types.CompoundSpec
export type Domain = Types.Domain
export type Plan = Types.Plan
export type PlanOptions = Types.PlanOptions
export type TraceEntry = Types.TraceEntry
export type DecompositionTrace = Types.DecompositionTrace
export type Operator = Types.Operator
export type OperatorResult = Types.OperatorResult
export type OperatorOutcome = Types.OperatorOutcome
export type RunState = Types.RunState
export type GoalSpec = BotsGoal.GoalSpec
export type RunnerConfig = Runner.Config
export type RunnerInstance = Runner.RunnerInstance

local HTN = {}

HTN.Domain = Domain -- Domain.new(spec): validate the task library where it is written
HTN.Planner = Planner -- Planner.plan(domain, root, state, opts?) -> (Plan?, trace)
HTN.goal = BotsGoal.goal -- HTN.goal(spec) -> a Bots-shaped Goal (drop into Bot.new)
HTN.Runner = Runner -- Runner.new(config): standalone executor
HTN.Execution = Execution -- the shared step engine, exposed for advanced hosts

return HTN
