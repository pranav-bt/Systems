--!strict

-- The Bots adapter: HTN.goal(spec) wraps a domain + root + operators into a
-- table SHAPED like a Bots Goal -- one long-running action that plans on
-- enter, steps the plan on update, and replans on failure/invalidation. This
-- module never requires Bots: the returned table simply satisfies the Goal
-- contract by shape, and Bot.new validates it like any hand-written goal.
--
-- WHO DECIDES WHAT. Utility arbitration (Bots) stays in charge of WHETHER
-- deliberate behavior wins right now -- a reactive Flee goal interrupts an
-- HTN plan through the normal commitment math, and the in-flight operator's
-- exit runs with "Interrupted" like any action's. HTN decides HOW the chosen
-- behavior unfolds. Planning happens on goal adoption and on invalidation,
-- never per tick, never fleet-wide.
--
-- FAILURE FLOW. No plan at adoption, or replanLimit exhausted mid-run ->
-- the wrapper action returns Failure -> the goal's normal failure cooldown
-- starts and the utility layer moves on. Set `cooldown` accordingly.
--
-- INTROSPECTION. The live RunState -- plan, current step, consecutive replans,
-- last decomposition trace, failure reason -- sits in the bot.s PERSONAL
-- blackboard at `planKey` (default "htn:<name>"): read it from debug output
-- alongside bot:trace()/bot:explain(). Treat it as read-only, and read it off
-- `bot.blackboard` rather than `bot:get` -- every bot running this goal uses the
-- same key, so the group/master fallthrough is not what you want here.

local Execution = require(script.Parent.Execution)
local Types = require(script.Parent.Types)

local BotsGoal = {}

export type GoalSpec = {
	name: string,
	domain: Types.Domain,
	root: string,
	state: (bot: any) -> Types.WorldState, -- derive symbols from the bot (blackboard/facts)
	operators: { [string]: Types.Operator }, -- one per primitive in the domain

	-- Passed straight through to the Bots goal:
	canRun: ((bot: any) -> boolean)?, -- default: always true (planning failure + cooldown handles the rest)
	score: ((bot: any) -> number)?,
	weight: number?,
	requires: { string }?,
	interruptible: boolean?,
	cooldown: number?,
	effects: ((bot: any) -> ())?,

	replanLimit: number?, -- CONSECUTIVE replans allowed before the goal fails (default 3); progress resets the count
	maxExpansions: number?, -- decompose() calls allowed per plan (default 2000)
	traceLimit: number?, -- decomposition-trace entries kept per plan (default 64; 0 = off)
	maxDepth: number?, -- planner caps (see Planner.luau)
	maxSteps: number?,
	planKey: string?, -- blackboard key for the RunState (default "htn:<name>")
}

local function alwaysTrue(): boolean
	return true
end

-- Build a Bots-shaped Goal. The return type is `any` on purpose: consumers
-- drop it straight into Bot.new's goals array, where it is validated by shape.
function BotsGoal.goal(spec: GoalSpec): any
	assert(type(spec) == "table", "HTN.goal: a spec table is required")
	assert(type(spec.name) == "string" and spec.name ~= "", "HTN.goal: spec.name must be a non-empty string")
	local label = `HTN.goal "{spec.name}"`
	assert(
		type(spec.domain) == "table" and spec.domain.primitives ~= nil and spec.domain.compounds ~= nil,
		`{label}: spec.domain must be an HTN.Domain`
	)
	assert(
		type(spec.root) == "string"
			and (spec.domain.primitives[spec.root] ~= nil or spec.domain.compounds[spec.root] ~= nil),
		`{label}: spec.root must name a task in the domain`
	)
	assert(type(spec.state) == "function", `{label}: spec.state(bot) -> WorldState is required`)
	Execution.validateOperators(spec.domain, spec.operators, label)
	assert(spec.canRun == nil or type(spec.canRun) == "function", `{label}: spec.canRun must be a function when set`)
	assert(
		spec.replanLimit == nil or (type(spec.replanLimit) == "number" and spec.replanLimit >= 0),
		`{label}: spec.replanLimit must be a number >= 0 when set`
	)

	local planKey = spec.planKey or `htn:{spec.name}`
	local ctx: Types.ExecutionContext = {
		label = `goal "{spec.name}"`,
		domain = spec.domain,
		root = spec.root,
		state = spec.state,
		operators = spec.operators,
		replanLimit = spec.replanLimit or 3,
		planOptions = {
			maxDepth = spec.maxDepth,
			maxSteps = spec.maxSteps,
			maxExpansions = spec.maxExpansions,
			traceLimit = spec.traceLimit,
		},
	}

	-- Aggregate operator `requires` onto the wrapper action, so Bot.new
	-- validates every operator's body needs exactly as it would a
	-- hand-written action's.
	local aggregated: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, operator in spec.operators do
		if operator.requires then
			for _, field in operator.requires do
				if not seen[field] then
					seen[field] = true
					table.insert(aggregated, field)
				end
			end
		end
	end

	local action = {
		name = `{spec.name}<plan>`,
		requires = if #aggregated > 0 then aggregated else nil,
		enter = function(bot: any): Types.OperatorResult
			local run = Execution.newRun()
			bot:set(planKey, run)
			return Execution.start(ctx, bot, run)
		end,
		update = function(bot: any, dt: number): Types.OperatorResult
			-- Read the PERSONAL board, not the fallthrough view: planKey defaults to
			-- "htn:<name>", the same key for every bot running this goal, so a
			-- fallthrough read could pick up a group/master entry and drive another
			-- agent's plan.
			local run = bot.blackboard:get(planKey)
			if not run then
				return "Failure" -- blackboard was externally cleared; nothing to drive
			end
			return Execution.step(ctx, bot, run, dt)
		end,
		exit = function(bot: any, outcome: Types.OperatorOutcome)
			-- Close out the in-flight operator with the REAL outcome. The
			-- RunState stays on the blackboard for post-mortem inspection;
			-- the next adoption overwrites it.
			local run = bot.blackboard:get(planKey)
			if run then
				Execution.interrupt(ctx, bot, run, outcome)
			end
		end,
	}

	return {
		name = spec.name,
		canRun = spec.canRun or alwaysTrue,
		score = spec.score,
		weight = spec.weight,
		requires = spec.requires,
		interruptible = spec.interruptible,
		cooldown = spec.cooldown,
		effects = spec.effects,
		actions = { action },
	}
end

return BotsGoal
