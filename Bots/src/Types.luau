--!strict

-- Shared types for the agent core. This module has ZERO dependencies and no
-- Roblox instance types: everything is plain data and functions over it. That
-- is what keeps the core adaptable to NPCs, enemy AI, or a playerbot driving a
-- real player's character -- the library never assumes what a body is made of.

-- What an action hook reports back to the Planner:
--   "Running"  -- still working; call update again next tick (nil counts as Running)
--   "Success"  -- this action is done; the Planner moves to the goal's next action
--   "Failure"  -- this action can never finish; the Planner aborts the whole goal
--                 (its effects are NOT applied, and its failure cooldown starts)
export type ActionResult = "Running" | "Success" | "Failure"

-- Why an action ended, passed to its exit hook:
--   "Success"      -- it reported Success
--   "Failure"      -- it reported Failure
--   "Interrupted"  -- the Planner broke the goal mid-action (a stronger goal won
--                     the utility challenge, or the consumer called abandonGoal)
export type ActionOutcome = "Success" | "Failure" | "Interrupted"

-- A working-memory FACT: a value plus how well the holder currently believes
-- it. Facts live beside a blackboard's plain values (setFact/getFact/forget)
-- and are what plain values are not: timestamped and forgettable. confidence
-- decays linearly to 0 across `ttl` seconds; an expired fact reads as nil,
-- exactly like one never written. The canonical use is perception memory --
-- "last seen player position, forget after 8s" -- read as
-- `local pos, confidence = bot:getFact("lastSeenPos")`.
export type Fact = {
	value: any,
	confidence: number, -- belief at WRITE time (default 1); reads return it decayed
	at: number, -- clock time it was written
	ttl: number?, -- seconds until fully decayed/forgotten (nil = never)
}

-- A blackboard: a named bag of values plus consumer-registered sensors that
-- keep those values fresh (see Blackboard.luau). One class serves all three
-- scopes: the global master board (Brain.master), consumer-created group
-- boards shared by squads of bots, and each bot's personal board.
export type Blackboard = {
	name: string,
	owner: any, -- handed to every sensor: the bot for personal boards, your squad object (or nil) otherwise
	values: { [string]: any }, -- raw storage; reading/writing directly is fine
	get: (self: Blackboard, key: string) -> any,
	set: (self: Blackboard, key: string, value: any) -> (),
	-- Working memory (see Fact above). `now` params default to the board's last
	-- update clock, then the package clock -- never a second timeline.
	setFact: (self: Blackboard, key: string, value: any, ttl: number?, confidence: number?, now: number?) -> (),
	getFact: (self: Blackboard, key: string, now: number?) -> (any, number?), -- (value, decayed confidence) | (nil, nil)
	forget: (self: Blackboard, key: string) -> (),
	addSensor: (self: Blackboard, key: string, read: (owner: any, bb: Blackboard) -> any, interval: number?) -> (),
	removeSensor: (self: Blackboard, key: string) -> (),
	update: (self: Blackboard, now: number) -> (),
}

-- A sensor as passed to Bot.new: either just the read function (refreshes every
-- tick) or { read = fn, interval = seconds } to throttle expensive perception.
export type SensorSpec = ((owner: any, bb: Blackboard) -> any) | {
	read: (owner: any, bb: Blackboard) -> any,
	interval: number?,
}

-- One small, dumb piece of behaviour (move somewhere, swing, dodge, wait). No
-- thinking lives here: the Planner decides WHEN it runs, the action only knows
-- HOW. Lifecycle:
--   enter(bot)        -- called once when the action starts. May finish it
--                        instantly by returning Success/Failure; Running (or
--                        nil) hands off to update.
--   update(bot, dt)   -- called every tick while Running.
--   exit(bot, outcome)-- called exactly once when the action ends, however it
--                        ends -- including "Interrupted" -- so cleanup always runs.
-- At least one of enter/update is required. An action whose enter returns
-- Running MUST have an update hook (the Planner errors loudly otherwise).
export type Action = {
	name: string,
	requires: { string }?, -- body fields the hooks use; checked against the body at Bot.new
	enter: ((bot: Bot) -> ActionResult?)?,
	update: ((bot: Bot, dt: number) -> ActionResult?)?,
	exit: ((bot: Bot, outcome: ActionOutcome) -> ())?,
}

-- A goal: a precondition, the ordered actions that accomplish it, and the
-- effects of having accomplished it.
--   canRun   -- precondition. Gates SELECTION only: it is deliberately NOT
--               re-checked while the goal runs, because a goal legitimately
--               falsifies its own precondition as it works (reloading makes
--               "clip empty" false before the goal finishes).
--   score    -- desirability right now, for utility selection (default 1).
--               Weighted by `weight` and the bot's per-goal personality jitter.
--   actions  -- executed strictly in order; each must Succeed before the next
--               starts. Any Failure aborts the goal.
--   effects  -- applied exactly once, only when the LAST action succeeds.
--               Write blackboard state here ("clip full", "alarm raised").
--   interruptible -- false = only completion, failure, or an explicit
--               abandonGoal can break it (default true).
--   cooldown -- seconds this goal is ineligible after FAILING (prevents
--               instant re-pick thrash while its precondition still holds).
export type Goal = {
	name: string,
	canRun: (bot: Bot) -> boolean,
	score: ((bot: Bot) -> number)?,
	weight: number?,
	requires: { string }?, -- body fields canRun/score/effects use; checked at Bot.new
	actions: { Action },
	effects: ((bot: Bot) -> ())?,
	interruptible: boolean?,
	cooldown: number?,
}

-- The Planner's live execution record for one bot's current goal.
export type GoalExecution = {
	goal: Goal,
	baseScore: number, -- the weighted score FROZEN at selection (challengers compare against this * commitment bonus)
	startedAt: number,
	actionIndex: number,
	entered: boolean, -- current action's enter has run
}

-- One recorded planner decision (see TRACE_DECISIONS / bot:trace).
--   "adopt"     -- an idle bot picked `goal` (score = its weighted score)
--   "interrupt" -- `by` beat the running `goal` (score = challenger's, defended = what it had to beat)
--   "complete"  -- `goal` finished its last action; effects applied
--   "fail"      -- `action` of `goal` returned Failure (cooldown = seconds applied, if any)
--   "abandon"   -- consumer called abandonGoal/destroy while `goal` ran
--   "idle"      -- selection found nothing eligible (recorded once per idle spell, not per tick)
-- `scores` (selection events only) maps every considered goal to a compact
-- human-readable verdict: "0.42 -> 0.46 (picked)", "canRun() = false",
-- "on cooldown 2.1s", "score 0.00 <= 0".
export type TraceEvent = {
	at: number,
	kind: "adopt" | "interrupt" | "complete" | "fail" | "abandon" | "idle",
	goal: string?,
	by: string?, -- interrupting challenger (kind = "interrupt")
	action: string?, -- failing action (kind = "fail")
	score: number?, -- winner's/challenger's weighted score
	defended: number?, -- the bar the challenger had to clear (kind = "interrupt")
	cooldown: number?, -- failure cooldown applied (kind = "fail")
	scores: { [string]: string }?,
}

-- One goal's live selection verdict, as returned by bot:explain().
export type GoalVerdict = {
	goal: string,
	eligible: boolean,
	running: boolean, -- this is the currently executing goal
	reason: string?, -- why ineligible ("canRun() = false", "on cooldown 2.1s", "score 0.00 <= 0")
	score: number?, -- raw score(bot)
	weighted: number?, -- score * weight * jitter (eligible goals only)
}

-- bot:explain()'s answer to "what would happen right now, and why": the
-- current execution (nil fields when idle), the bar a challenger must clear
-- (defended = max(baseScore, liveScore) * commitment bonus), and every goal's
-- verdict, eligible-highest first.
export type Explanation = {
	goal: string?,
	action: string?,
	elapsed: number?,
	baseScore: number?,
	liveScore: number?,
	defended: number?,
	interruptible: boolean?,
	verdicts: { GoalVerdict },
}

-- Per-bot planner state, stored on the bot (the Planner module itself is stateless).
export type PlannerState = {
	current: GoalExecution?,
	cooldownUntil: { [string]: number }, -- goal name -> clock time it becomes eligible again
	jitter: { [string]: number }, -- goal name -> this bot's persistent personality multiplier
	lastSteppedAt: number?, -- clock time of this bot's last planner step; each step derives its dt from
	-- this, which keeps dt correct across out-of-band stimulate steps and per-bot tick rates
	-- True while a step is in flight. A hook that YIELDS suspends the step, and
	-- the next frame (or a stimulate) would otherwise re-enter the same bot and
	-- mutate this state underneath the suspended call. See Brain.luau.
	stepping: boolean?,
	nextStepAt: number?, -- this bot's own phase: earliest clock time the frame drain steps it again
	-- (nil = never stepped, so due immediately). Set on EVERY step, whatever
	-- triggered it, from bot.tickInterval or TICK_INTERVAL. See Brain.luau.
	trace: { TraceEvent }?, -- decision ring buffer (created lazily when TRACE_DECISIONS > 0)
	traceIndex: number?, -- ring write cursor
	idleTraced: boolean?, -- dedupe flag: the current idle spell has been recorded
}

-- Snapshot of what a bot is doing right now (every field nil when idle).
export type PlannerContext = {
	goal: string?,
	action: string?,
	actionIndex: number?,
	entered: boolean?,
	startedAt: number?,
	elapsed: number?,
	baseScore: number?,
}

-- The selection/commitment tunables the Planner reads (defaults in Config.luau,
-- overridable via Brain.configure).
export type PlannerTunables = {
	PLAN_COMMIT_BASE: number,
	PLAN_COMMIT_GROWTH: number,
	PLAN_COMMIT_MAX: number,
	GOAL_JITTER: number,
	TRACE_DECISIONS: number,
}

-- How Brain.start gets its per-frame callback. A driver subscribes the callback
-- to whatever frame phase you like and returns a function that unsubscribes it.
-- The built-in default is RunService.Heartbeat; inject your own to run the
-- scheduler inside your game's existing frame ordering instead.
export type BrainDriver = (step: (deltaTime: number) -> ()) -> () -> ()

-- What the last Brain.step did (Brain.stats()). `deferred` is how many bots the
-- frame never got to before the budget ran out -- an upper bound on how many
-- were actually due, and the number to watch: sustained non-zero means the fleet
-- wants more LOD or more budget.
export type BrainStats = {
	bots: number, -- registered bots
	stepped: number, -- bots stepped in the last Brain.step
	deferred: number, -- bots left unexamined when the budget ran out (0 = fully drained)
	seconds: number, -- real seconds the last Brain.step spent
	budgetHits: number, -- cumulative frames that hit the budget
	-- Cumulative Brain.step calls refused because a drain was still in flight.
	-- Non-zero means a consumer hook yielded: hooks must not yield. See Brain.luau.
	reentered: number,
}

-- The bot object (built by Bot.luau). `body` is a FREE-FORM table of whatever
-- the consumer's sensors and actions need -- a rig, a Humanoid, a player's
-- existing character, capability closures, a mover from the Pathfinding
-- library. The core never reads it; it only checks declared `requires`
-- against it at creation.
export type Bot = {
	id: string,
	body: { [string]: any },
	blackboard: Blackboard, -- personal board (sensed before this bot plans)
	group: Blackboard?, -- optional shared squad board (assignable at runtime)
	goals: { Goal },
	planner: PlannerState,
	tickInterval: number?, -- seconds between THIS bot's sense+plan steps (nil = every Brain
	-- tick). Assignable at runtime -- this is the LOD lever: raise it for distant or
	-- unimportant bots, clear it when they matter again.

	get: (self: Bot, key: string) -> any, -- read with personal -> group -> master fallthrough
	set: (self: Bot, key: string, value: any) -> (), -- write to the personal board
	getFact: (self: Bot, key: string) -> (any, number?), -- fact read with the same fallthrough as get
	setFact: (self: Bot, key: string, value: any, ttl: number?, confidence: number?) -> (), -- personal fact write
	stimulate: (self: Bot, values: { [string]: any }?, now: number?) -> (), -- write stimulus values, then sense+plan NOW (see Brain.stimulate)
	currentGoal: (self: Bot) -> string?,
	abandonGoal: (self: Bot) -> (), -- "something drastic happened": exit the in-flight action as Interrupted
	context: (self: Bot) -> PlannerContext,
	trace: (self: Bot) -> { TraceEvent }, -- recorded decisions, newest first (empty unless TRACE_DECISIONS > 0)
	explain: (self: Bot) -> Explanation, -- live "what would happen right now, and why"
	destroy: (self: Bot) -> (),
}

-- Bot.new params.
export type BotParams = {
	id: string?, -- default: auto ("bot_1", "bot_2", ...)
	body: { [string]: any }?,
	goals: { Goal },
	group: Blackboard?,
	values: { [string]: any }?, -- initial personal blackboard values
	sensors: { [string]: SensorSpec }?, -- personal sensors, keyed by the value they write
	tickInterval: number?, -- seconds between this bot's steps (nil = every Brain tick)
}

-- A claimable token pool (Tokens.luau): at most `capacity` holders at once.
-- The squad-coordination primitive -- "only 2 bots may attack simultaneously"
-- is a pool of capacity 2 that the attack goal's first action claims in enter
-- and releases in exit. Leases optionally expire after the pool's ttl so a
-- vanished holder can't strand a token; holders refresh their lease by calling
-- tryClaim again (it is idempotent while held).
export type Tokens = {
	name: string,
	capacity: number, -- mutable via setCapacity
	tryClaim: (self: Tokens, holder: any, now: number?) -> boolean, -- claim (or refresh) a token; false = pool full
	release: (self: Tokens, holder: any) -> (),
	holds: (self: Tokens, holder: any, now: number?) -> boolean,
	count: (self: Tokens, now: number?) -> number, -- live (unexpired) holders
	holders: (self: Tokens, now: number?) -> { any }, -- WHICH holders, for debug dumps
	setCapacity: (self: Tokens, capacity: number) -> (),
}

return {}
