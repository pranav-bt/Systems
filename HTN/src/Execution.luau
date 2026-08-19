--!strict

-- The step engine shared by the Bots adapter (BotsGoal) and the standalone
-- Runner: plan, execute one primitive.s operator at a time through the
-- enter/update/exit lifecycle, MONITOR (re-check each step.s planning
-- condition against fresh world state before starting it), and REPLAN from
-- the current state when a step fails or is invalidated -- up to replanLimit
-- CONSECUTIVE replans, then report Failure to whatever sits above.
--
-- Consecutive is the important word: completing a step resets the counter, so
-- the limit bounds thrash rather than a plan.s lifetime adaptability. A
-- companion that copes with four separate world changes over ten minutes, making
-- progress between each, is not thrashing.
--
-- Instantly-completing operators chain within a single step() call, mirroring
-- Bots' action chaining, so a plan of instant steps finishes in one tick.
--
-- Error semantics by host: operator enter/update errors are NOT caught here.
-- Under Bots they propagate into Bots' hook containment (goal fails, wrapper
-- exit runs, which lands back in Execution.interrupt -- so the in-flight
-- operator's exit still runs). Under the Runner they propagate to the caller.
-- Operator EXIT errors are caught and warned here in both hosts: cleanup
-- must never corrupt the run.

local Planner = require(script.Parent.Planner)
local Types = require(script.Parent.Types)

local Execution = {}

function Execution.newRun(): Types.RunState
	return { step = 1, entered = false, replans = 0 }
end

-- Shared validation for { primitiveName -> Operator } maps: every primitive
-- needs an operator (else a plan could contain an unrunnable step), and every
-- operator must name a primitive (catches typos).
function Execution.validateOperators(domain: Types.Domain, operators: any, label: string)
	assert(type(operators) == "table", `{label}: an operators table is required`)
	for name in domain.primitives do
		local operator = operators[name]
		assert(operator ~= nil, `{label}: missing operator for primitive "{name}"`)
		assert(type(operator) == "table", `{label}: operator "{name}" must be a table`)
		assert(
			operator.enter == nil or type(operator.enter) == "function",
			`{label}: operator "{name}".enter must be a function when set`
		)
		assert(
			operator.update == nil or type(operator.update) == "function",
			`{label}: operator "{name}".update must be a function when set`
		)
		assert(
			operator.exit == nil or type(operator.exit) == "function",
			`{label}: operator "{name}".exit must be a function when set`
		)
		assert(operator.enter ~= nil or operator.update ~= nil, `{label}: operator "{name}" needs enter or update`)
		if operator.requires ~= nil then
			assert(type(operator.requires) == "table", `{label}: operator "{name}".requires must be an array`)
			for _, field in operator.requires :: { any } do
				assert(type(field) == "string", `{label}: operator "{name}".requires must contain only strings`)
			end
		end
	end
	for name in operators do
		assert(domain.primitives[name] ~= nil, `{label}: operator "{name}" does not match any primitive in the domain`)
	end
end

-- Operator results share the Bots vocabulary. Anything else used to fall through
-- the Running/Failure checks in step() and count as SUCCESS, so a typo advanced
-- the plan and handed exit() a bogus outcome. Fail loudly instead.
local function checked(ctx: Types.ExecutionContext, taskName: string, result: any): Types.OperatorResult
	if result == nil then
		return "Running"
	end
	if result ~= "Running" and result ~= "Success" and result ~= "Failure" then
		warn(
			`[HTN] {ctx.label}: operator "{taskName}" returned {tostring(result)};`
				.. ` expected "Running" | "Success" | "Failure" -- treating as Failure`
		)
		return "Failure"
	end
	return result :: Types.OperatorResult
end

local function exitOperator(ctx: Types.ExecutionContext, owner: any, taskName: string, outcome: Types.OperatorOutcome)
	local operator = ctx.operators[taskName]
	if operator and operator.exit then
		local ok, err = pcall(operator.exit, owner, outcome)
		if not ok then
			warn(`[HTN] {ctx.label}: operator "{taskName}" errored in exit ({outcome}):\n{err}`)
		end
	end
end

-- (Re)derive state and plan into `run`. False = no plan exists right now.
local function planInto(ctx: Types.ExecutionContext, owner: any, run: Types.RunState): boolean
	local plan, trace = Planner.plan(ctx.domain, ctx.root, ctx.state(owner), ctx.planOptions)
	run.lastTrace = trace
	if not plan then
		run.plan = nil
		run.failedReason = "no plan (see lastTrace)"
		return false
	end
	run.plan = plan.steps
	run.step = 1
	run.entered = false
	return true
end

local function tryReplan(ctx: Types.ExecutionContext, owner: any, run: Types.RunState, why: string): boolean
	run.replans += 1
	if run.replans > ctx.replanLimit then
		run.failedReason = `replan limit ({ctx.replanLimit}) reached after {why}`
		return false
	end
	return planInto(ctx, owner, run)
end

-- Drive the plan as far as it can go this call: chain instantly-completing
-- operators, stop on Running, replan on failure/invalidation, Success when
-- the last step completes.
function Execution.step(ctx: Types.ExecutionContext, owner: any, run: Types.RunState, dt: number): Types.OperatorResult
	while true do
		local plan = run.plan -- re-read each pass: a replan swaps it
		if not plan then
			return "Failure"
		end
		local taskName = plan[run.step]
		if taskName == nil then
			return "Success" -- plan exhausted (or empty: root already satisfied)
		end
		local operator = ctx.operators[taskName]

		local result: Types.OperatorResult
		if not run.entered then
			-- PLAN MONITORING: the step was planned against a prediction;
			-- verify its condition against the world as it actually is now.
			local primitive = ctx.domain.primitives[taskName]
			if primitive.condition and not primitive.condition(ctx.state(owner)) then
				if not tryReplan(ctx, owner, run, `step "{taskName}" was invalidated`) then
					return "Failure"
				end
				continue
			end
			run.entered = true
			if operator.enter then
				result = checked(ctx, taskName, operator.enter(owner))
				if result == "Running" and not operator.update then
					warn(
						`[HTN] {ctx.label}: operator "{taskName}" returned Running from enter but has no update`
							.. ` hook, so it could never finish; treating as Failure`
					)
					result = "Failure"
				end
			else
				local update = operator.update :: (any, number) -> Types.OperatorResult?
				result = checked(ctx, taskName, update(owner, dt))
			end
		else
			local update = operator.update :: (any, number) -> Types.OperatorResult?
			result = checked(ctx, taskName, update(owner, dt))
		end

		if result == "Running" then
			return "Running"
		end
		exitOperator(ctx, owner, taskName, result)
		run.entered = false
		if result == "Failure" then
			if not tryReplan(ctx, owner, run, `step "{taskName}" failed`) then
				return "Failure"
			end
			continue
		end
		-- PROGRESS REFUNDS THE REPLAN BUDGET. replanLimit exists to stop thrash --
		-- the same step failing over and over -- not to cap how adaptable a plan is
		-- allowed to be. A long plan that copes with four unrelated world changes,
		-- completing steps between each, is HTN working exactly as intended; without
		-- this reset it would exhaust the default limit of 3 and give up.
		run.replans = 0
		run.step += 1
	end
end

-- Plan and drive as far as possible immediately. Failure = no plan (or the
-- first steps failed and replanning ran dry).
function Execution.start(ctx: Types.ExecutionContext, owner: any, run: Types.RunState): Types.OperatorResult
	if not planInto(ctx, owner, run) then
		return "Failure"
	end
	return Execution.step(ctx, owner, run, 0)
end

-- The run is ending from outside (goal interrupted/failed above us): close
-- out the in-flight operator with the real outcome so its cleanup runs.
function Execution.interrupt(
	ctx: Types.ExecutionContext,
	owner: any,
	run: Types.RunState,
	outcome: Types.OperatorOutcome
)
	local plan = run.plan
	if plan and run.entered then
		local taskName = plan[run.step]
		if taskName then
			exitOperator(ctx, owner, taskName, outcome)
		end
	end
	run.entered = false
end

return Execution
