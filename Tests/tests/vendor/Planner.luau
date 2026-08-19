--!strict

-- The per-bot decision engine: pick the best goal by utility, then execute its
-- action sequence one completed step at a time. Pure logic -- no clocks, no
-- scheduling, no Roblox instance APIs (`warn` for hook-error reporting is the
-- only ambient global). The Brain heartbeat calls Planner.step for every
-- registered bot each tick and passes the clock in, which keeps this module
-- fully testable outside Roblox (e.g. under Lune).
--
-- SELECTION. A goal is eligible when canRun(bot) passes, it is off cooldown,
-- and its score is positive. Eligible goals rank by
-- score(bot) * weight * per-bot jitter; the highest wins, exact ties keep the
-- earlier goal in the bot's list. The winner's weighted score is FROZEN as the
-- execution's baseScore -- a goal is judged by how important it was when
-- adopted, so it can't undermine itself by (correctly) becoming less urgent as
-- it works.
--
-- COMMITMENT. While a goal runs, it is defended by max(baseScore, its LIVE
-- score right now) multiplied by a commitment bonus that grows with time in
-- the goal (PLAN_COMMIT_BASE + GROWTH * elapsed, capped at PLAN_COMMIT_MAX).
-- The frozen side stops a goal that (correctly) becomes less urgent as it
-- works from undermining itself; the live side stops a goal whose urgency has
-- GROWN from being defended at a stale, too-low value. A challenger must beat
-- that product to interrupt, so bots don't flip-flop -- but a drastic-enough
-- challenger always can, unless the goal is interruptible = false.
--
-- EXECUTION. Actions run strictly in order: enter once, update every tick
-- while Running, exit exactly once with the outcome. Instantly-completing
-- actions chain within a single step. Success on the last action applies the
-- goal's effects and frees the bot the same tick; Failure aborts the goal
-- WITHOUT effects and starts its failure cooldown. canRun is NOT re-checked
-- while a goal runs (see Types.Goal) -- a running goal ends only by finishing,
-- failing, losing a utility challenge, or an explicit abandon.
--
-- ERRORS. A hook that throws cannot wedge the planner: enter/update errors are
-- warned (with traceback) and treated as the action returning Failure -- exit
-- still runs, the goal aborts, its cooldown starts, and the bot recovers next
-- step. exit/effects errors are warned and swallowed (the goal is already
-- ending). Each step's dt derives from the bot's own lastSteppedAt, so
-- out-of-band steps (Brain.stimulate) and per-bot tick rates stay correct.
--
-- TRACING. When TRACE_DECISIONS > 0, every decision EVENT (adopt, interrupt,
-- complete, fail, abandon, one entry per idle spell) is pushed into a per-bot
-- ring buffer of that size, with per-goal score verdicts captured at
-- selection time -- Planner.trace / bot:trace reads it newest-first. This is
-- event-driven, not per-tick, so the buffer holds the story of WHAT CHANGED,
-- not thousands of identical frames. Planner.explain / bot:explain is the
-- live counterpart: it re-runs selection scoring read-only and reports every
-- goal's verdict plus the bar a challenger must clear, regardless of whether
-- tracing is on. Both are debugging tools: when TRACE_DECISIONS is 0 (the
-- default) nothing is recorded and nothing allocates.

local Rng = require("./Rng")
local Types = require("./Types")

local Planner = {}

-- Fresh per-bot execution state (Bot.new calls this).
function Planner.newState(): Types.PlannerState
	return { current = nil, cooldownUntil = {}, jitter = {} }
end

-- The bot's persistent personality multiplier for a goal, rolled on first use
-- and kept for the bot's whole life.
local function jitterFor(bot: Types.Bot, goalName: string, tunables: Types.PlannerTunables): number
	local jitter = bot.planner.jitter[goalName]
	if jitter == nil then
		jitter = Rng.jitter(tunables.GOAL_JITTER)
		bot.planner.jitter[goalName] = jitter
	end
	return jitter
end

-- Best eligible goal (skipping `skipGoal`, the one already running) and its
-- weighted score. Returns nil when nothing is worth doing. When `verdicts` is
-- given (tracing), every considered goal gets a compact human-readable
-- verdict written into it.
local function selectBest(
	bot: Types.Bot,
	now: number,
	tunables: Types.PlannerTunables,
	skipGoal: Types.Goal?,
	verdicts: { [string]: string }?
): (Types.Goal?, number)
	local state = bot.planner
	local best: Types.Goal? = nil
	local bestScore = 0
	for _, goal in bot.goals do
		if goal == skipGoal then
			continue
		end
		local readyAt = state.cooldownUntil[goal.name]
		if readyAt ~= nil and now < readyAt then
			if verdicts then
				verdicts[goal.name] = string.format("on cooldown %.1fs", readyAt - now)
			end
			continue
		end
		if not goal.canRun(bot) then
			if verdicts then
				verdicts[goal.name] = "canRun() = false"
			end
			continue
		end
		local score = if goal.score then goal.score(bot) else 1
		if score <= 0 then
			if verdicts then
				verdicts[goal.name] = string.format("score %.2f <= 0", score)
			end
			continue
		end
		local weighted = score * (goal.weight or 1) * jitterFor(bot, goal.name, tunables)
		if verdicts then
			verdicts[goal.name] = string.format("%.2f -> %.2f", score, weighted)
		end
		if weighted > bestScore then
			best = goal
			bestScore = weighted
		end
	end
	return best, bestScore
end

-- Push one event into the bot's decision ring buffer (no-op when tracing is
-- off). The buffer is created lazily, sized by TRACE_DECISIONS at push time.
local function pushTrace(bot: Types.Bot, tunables: Types.PlannerTunables, event: Types.TraceEvent)
	local size = tunables.TRACE_DECISIONS
	if size <= 0 then
		return
	end
	local state = bot.planner
	local buffer = state.trace
	if not buffer then
		buffer = {}
		state.trace = buffer
	end
	local index = (state.traceIndex or 0) % size + 1
	state.traceIndex = index
	buffer[index] = event
	state.idleTraced = event.kind == "idle"
end

-- The running goal's score as it stands right now, weighted exactly like
-- selection. canRun and cooldown are deliberately not consulted: a running
-- goal may legitimately falsify them while it works (see Types.Goal).
local function liveScore(bot: Types.Bot, goal: Types.Goal, tunables: Types.PlannerTunables): number
	local score = if goal.score then goal.score(bot) else 1
	if score <= 0 then
		return 0
	end
	return score * (goal.weight or 1) * jitterFor(bot, goal.name, tunables)
end

-- Run an enter/update hook, converting a thrown error into Failure: a buggy
-- hook fails its goal (exit runs, cooldown starts) instead of wedging the
-- planner in a half-entered state.
local function callHook(
	hook: (...any) -> Types.ActionResult?,
	action: Types.Action,
	goal: Types.Goal,
	...: any
): Types.ActionResult
	local ok, result = xpcall(hook, debug.traceback, ...)
	if not ok then
		warn(`[Bots] action "{action.name}" (goal "{goal.name}") errored; treating as Failure:\n{result}`)
		return "Failure"
	end
	if result == nil then
		return "Running" -- an action that returns nothing is still working
	end
	if result ~= "Running" and result ~= "Success" and result ~= "Failure" then
		-- Anything unrecognised used to fall straight through the Running/Failure
		-- checks in advance() and be treated as SUCCESS -- so a typo ("success",
		-- "Done", true) silently advanced the goal and handed exit() a bogus
		-- outcome. Fail instead: an action that returned something meaningless has
		-- not shown it did its job, and failing is the recoverable direction (the
		-- goal aborts, its cooldown starts, the bot moves on).
		warn(
			`[Bots] action "{action.name}" (goal "{goal.name}") returned {tostring(result)};`
				.. ` expected "Running" | "Success" | "Failure" -- treating as Failure`
		)
		return "Failure"
	end
	return result :: Types.ActionResult
end

-- Run an action's exit hook (if any). An error here is warned and swallowed --
-- the action is already over, and cleanup code must never corrupt the planner.
local function runExit(bot: Types.Bot, action: Types.Action, goal: Types.Goal, outcome: Types.ActionOutcome)
	if not action.exit then
		return
	end
	local ok, err = xpcall(action.exit, debug.traceback, bot, outcome)
	if not ok then
		warn(`[Bots] action "{action.name}" (goal "{goal.name}") errored in exit ({outcome}):\n{err}`)
	end
end

-- Exit the execution's current action (if it ever entered) with `outcome`.
local function exitCurrentAction(bot: Types.Bot, execution: Types.GoalExecution, outcome: Types.ActionOutcome)
	local action = execution.goal.actions[execution.actionIndex]
	if action and execution.entered then
		runExit(bot, action, execution.goal, outcome)
	end
end

-- Drive the current execution as far as it can go this tick: chain instantly-
-- completing actions, stop on Running, clear the execution on goal end/failure.
local function advance(bot: Types.Bot, now: number, dt: number, tunables: Types.PlannerTunables)
	local state = bot.planner
	while true do
		local execution = state.current
		if not execution then
			return
		end
		local action = execution.goal.actions[execution.actionIndex]

		local result: Types.ActionResult
		if not execution.entered then
			execution.entered = true
			if action.enter then
				result = callHook(action.enter, action, execution.goal, bot)
				if result == "Running" and not action.update then
					-- Authoring error: this action could never finish. Warn loudly
					-- and fail the goal, so the bot recovers instead of wedging.
					warn(
						`[Bots] action "{action.name}" (goal "{execution.goal.name}") returned Running`
							.. ` from enter but has no update hook, so it could never finish; treating as Failure`
					)
					result = "Failure"
				end
			else
				-- No enter: the action is pure update; its first update runs this tick.
				local update = action.update :: (Types.Bot, number) -> Types.ActionResult?
				result = callHook(update, action, execution.goal, bot, dt)
			end
		else
			local update = action.update :: (Types.Bot, number) -> Types.ActionResult?
			result = callHook(update, action, execution.goal, bot, dt)
		end

		if result == "Running" then
			return
		end

		-- Terminal: close the action out.
		runExit(bot, action, execution.goal, result)

		if result == "Failure" then
			-- Abort the goal: no effects, and start the failure cooldown so the
			-- (likely still-true) precondition doesn't re-pick it instantly.
			local cooldown = execution.goal.cooldown or 0
			if cooldown > 0 then
				state.cooldownUntil[execution.goal.name] = now + cooldown
			end
			state.current = nil
			pushTrace(bot, tunables, {
				at = now,
				kind = "fail",
				goal = execution.goal.name,
				action = action.name,
				cooldown = if cooldown > 0 then cooldown else nil,
			})
			return
		end

		execution.actionIndex += 1
		execution.entered = false
		if execution.actionIndex > #execution.goal.actions then
			-- Goal complete: apply its declared effects, free the bot. The goal
			-- HAS succeeded by this point, so an effects error is warned, not
			-- converted into a failure.
			local effects = execution.goal.effects
			if effects then
				local ok, err = xpcall(effects, debug.traceback, bot)
				if not ok then
					warn(`[Bots] goal "{execution.goal.name}" errored in effects:\n{err}`)
				end
			end
			state.current = nil
			pushTrace(bot, tunables, { at = now, kind = "complete", goal = execution.goal.name })
			return
		end
	end
end

local function begin(bot: Types.Bot, goal: Types.Goal, weightedScore: number, now: number)
	bot.planner.current = {
		goal = goal,
		baseScore = weightedScore,
		startedAt = now,
		actionIndex = 1,
		entered = false,
	}
end

-- One decision step for one bot: keep the running goal moving, then either fill
-- an idle bot with the best eligible goal or let a strong-enough challenger
-- interrupt the running one. dt is derived from the bot's own lastSteppedAt, so
-- the Brain heartbeat, per-bot tick rates, and out-of-band stimulate steps all
-- hand actions the true seconds elapsed since THEIR bot last stepped.
function Planner.step(bot: Types.Bot, now: number, tunables: Types.PlannerTunables)
	local state = bot.planner
	local dt = if state.lastSteppedAt then now - state.lastSteppedAt else 0
	state.lastSteppedAt = now

	if state.current then
		advance(bot, now, dt, tunables)
	end

	local execution = state.current
	local tracing = tunables.TRACE_DECISIONS > 0
	local verdicts: { [string]: string }? = if tracing then {} else nil
	local challenger, challengerScore =
		selectBest(bot, now, tunables, if execution then execution.goal else nil, verdicts)
	if execution then
		if challenger and execution.goal.interruptible ~= false then
			local elapsed = now - execution.startedAt
			local bonus =
				math.min(tunables.PLAN_COMMIT_MAX, tunables.PLAN_COMMIT_BASE + tunables.PLAN_COMMIT_GROWTH * elapsed)
			-- Defend with the BETTER of the frozen selection score and the live
			-- score: frozen stops self-undermining, live stops a now-critical
			-- goal being interrupted at yesterday's value (see header).
			local defended = math.max(execution.baseScore, liveScore(bot, execution.goal, tunables))
			if challengerScore > defended * bonus then
				exitCurrentAction(bot, execution, "Interrupted")
				state.current = nil
				begin(bot, challenger, challengerScore, now)
				if verdicts then
					verdicts[challenger.name] ..= " (picked)"
				end
				pushTrace(bot, tunables, {
					at = now,
					kind = "interrupt",
					goal = execution.goal.name,
					by = challenger.name,
					score = challengerScore,
					defended = defended * bonus,
					scores = verdicts,
				})
				advance(bot, now, dt, tunables)
			end
		end
	elseif challenger then
		begin(bot, challenger, challengerScore, now)
		if verdicts then
			verdicts[challenger.name] ..= " (picked)"
		end
		pushTrace(bot, tunables, {
			at = now,
			kind = "adopt",
			goal = challenger.name,
			score = challengerScore,
			scores = verdicts,
		})
		advance(bot, now, dt, tunables)
	elseif tracing and not state.idleTraced then
		-- Nothing eligible: record the START of the idle spell, once, with the
		-- verdicts saying why every goal was passed over.
		pushTrace(bot, tunables, { at = now, kind = "idle", scores = verdicts })
	end
end

-- Abandon whatever is running: the in-flight action exits with "Interrupted",
-- and the bot re-plans from scratch on its next step. This is the consumer's
-- lever for "something drastic happened, drop everything" -- it also works on
-- interruptible = false goals. `tunables`/`now` are only needed for the trace
-- event; passing nil skips recording.
function Planner.abandon(bot: Types.Bot, tunables: Types.PlannerTunables?, now: number?)
	local state = bot.planner
	local execution = state.current
	if execution then
		exitCurrentAction(bot, execution, "Interrupted")
		state.current = nil
		if tunables then
			pushTrace(bot, tunables, { at = now or 0, kind = "abandon", goal = execution.goal.name })
		end
	end
end

-- The recorded decision events, newest first (empty when tracing is/was off).
function Planner.trace(bot: Types.Bot): { Types.TraceEvent }
	local buffer = bot.planner.trace
	if not buffer then
		return {}
	end
	local count = #buffer
	local newest = bot.planner.traceIndex or 0
	local out: { Types.TraceEvent } = {}
	for offset = 0, count - 1 do
		local position = newest - offset
		if position < 1 then
			position += count
		end
		table.insert(out, buffer[position])
	end
	return out
end

-- Live selection X-ray: every goal's verdict as selection would judge it RIGHT
-- NOW (including the running goal, flagged), plus the bar a challenger must
-- clear. Read-only -- it calls the same canRun/score functions selection does,
-- but changes nothing. Works whether or not tracing is enabled.
function Planner.explain(bot: Types.Bot, now: number, tunables: Types.PlannerTunables): Types.Explanation
	local state = bot.planner
	local execution = state.current

	local verdicts: { Types.GoalVerdict } = {}
	for _, goal in bot.goals do
		local verdict: Types.GoalVerdict = {
			goal = goal.name,
			eligible = false,
			running = execution ~= nil and execution.goal == goal,
		}
		local readyAt = state.cooldownUntil[goal.name]
		if readyAt ~= nil and now < readyAt then
			verdict.reason = string.format("on cooldown %.1fs", readyAt - now)
		elseif not goal.canRun(bot) then
			verdict.reason = "canRun() = false"
		else
			local score = if goal.score then goal.score(bot) else 1
			verdict.score = score
			if score <= 0 then
				verdict.reason = string.format("score %.2f <= 0", score)
			else
				verdict.eligible = true
				verdict.weighted = score * (goal.weight or 1) * jitterFor(bot, goal.name, tunables)
			end
		end
		table.insert(verdicts, verdict)
	end
	table.sort(verdicts, function(a, b)
		if a.eligible ~= b.eligible then
			return a.eligible
		end
		return (a.weighted or 0) > (b.weighted or 0)
	end)

	local explanation: Types.Explanation = { verdicts = verdicts }
	if execution then
		local action = execution.goal.actions[execution.actionIndex]
		explanation.goal = execution.goal.name
		explanation.action = if action then action.name else nil
		explanation.elapsed = now - execution.startedAt
		explanation.baseScore = execution.baseScore
		explanation.liveScore = liveScore(bot, execution.goal, tunables)
		explanation.interruptible = execution.goal.interruptible ~= false
		local bonus = math.min(
			tunables.PLAN_COMMIT_MAX,
			tunables.PLAN_COMMIT_BASE + tunables.PLAN_COMMIT_GROWTH * (explanation.elapsed :: number)
		)
		explanation.defended = math.max(explanation.baseScore :: number, explanation.liveScore :: number) * bonus
	end
	return explanation
end

-- Snapshot of what the bot is doing right now (all fields nil when idle).
-- Pass `now` to get `elapsed` filled in.
function Planner.context(bot: Types.Bot, now: number?): Types.PlannerContext
	local execution = bot.planner.current
	if not execution then
		return {}
	end
	local action = execution.goal.actions[execution.actionIndex]
	return {
		goal = execution.goal.name,
		action = if action then action.name else nil,
		actionIndex = execution.actionIndex,
		entered = execution.entered,
		startedAt = execution.startedAt,
		elapsed = if now then now - execution.startedAt else nil,
		baseScore = execution.baseScore,
	}
end

return Planner
