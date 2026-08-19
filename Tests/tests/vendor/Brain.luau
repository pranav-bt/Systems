--!strict

-- The singleton scheduler. Owns the master blackboard and the bot registry;
-- stepping a bot means (1) updating its personal board, then (2) running one
-- Planner step. Shared boards (master, group) update on their own cadence, once
-- each, no matter how many bots read them. That is ALL it does -- decisions live
-- in Planner, state lives in the blackboards, behaviour lives in the consumer's
-- actions.
--
-- Drive it either way:
--   Brain.start()  -- own driver, budgeted: drains what is due each frame
--   Brain.step()   -- one budgeted frame's worth, from your own per-frame loop
--   Brain.tick()   -- one FULL cycle, unbudgeted, from your own loop
--
-- BUDGETED FRAMES vs FULL TICKS. `tick` is the original contract and is
-- unchanged: every bot that its own tickInterval says is due steps, right now,
-- however long that takes. It is the deterministic path -- inject `now` and a
-- headless test gets identical behaviour every run.
--
-- `step` is what the built-in driver calls, once per frame. Instead of doing the
-- whole fleet in one resumption every TICK_INTERVAL, each bot carries its own
-- `nextStepAt` phase and the frame drains whoever is due until FRAME_BUDGET
-- seconds of real time are spent. Same think rate per bot, a fraction of the
-- peak: 100 bots at TICK_INTERVAL 0.2 is 100 steps landing on one frame in
-- twelve under `tick`, versus ~8 steps every frame under `step`.
--
-- FAIRNESS. The drain cursor persists ACROSS frames -- each frame resumes where
-- the last one stopped and wraps -- so every registered bot is examined once
-- before any bot is examined twice. A bot can therefore be LATE under sustained
-- overload, but it can never be starved by louder neighbours. Overload degrades
-- the whole fleet's think rate evenly, which is also what Brain.stats() reports
-- so a game can lower its own LOD in response.
--
-- Degrading is safe because Planner derives each step's dt from that bot's own
-- lastSteppedAt: a bot that thinks late still hands its actions the true elapsed
-- seconds. Thinking less often costs reaction time, never correctness.
--
-- ISOLATION. Anything consumer-written that errors mid-step is contained: a
-- master or group sensor error is warned and that board's update abandoned for
-- the cycle; a bot whose personal sensors or hooks error is warned and skipped.
-- Every other board and bot still steps, and the scheduler never dies.
--
-- PACING. Bots with `tickInterval` set think at their own (slower) rate -- the
-- LOD lever for big fleets: distant or unimportant bots think at 1-2s while
-- important ones think every TICK_INTERVAL. Brain.stimulate is the opposite
-- direction: an immediate out-of-band sense+plan for one bot (or a whole group
-- via stimulateGroup) when something drastic just happened, instead of waiting
-- for its next scheduled step.

local Blackboard = require("./Blackboard")
local Clock = require("./Clock")
local Config = require("./Config")
local Planner = require("./Planner")
local Rng = require("./Rng")
local Types = require("./Types")

-- (STEP_JITTER / PHASE_JITTER now live in Config, and all randomness goes
-- through Rng, so a seeded run is reproducible -- see Rng.luau.)

-- MicroProfiler labels under Roblox; absent headless (Lune), hence the guards.
local profileBegin = (debug :: any).profilebegin
local profileEnd = (debug :: any).profileend

local Brain = {}

-- The global board: values every bot shares (round state, alarm level, ...).
-- Seed values and add sensors from your game setup: Brain.master:addSensor(...).
Brain.master = Blackboard.new("Master")

local config = table.clone(Config)
-- The registry. `false` marks a tombstoned slot; see the note above indexOf.
local bots: { Types.Bot | false } = {}
local liveCount = 0
local tombstones = 0
-- Depth of in-flight registry walks. Compaction is deferred while any loop is
-- holding indices into `bots`.
local iterating = 0
local running = false
-- Bumped by every start(). A driver callback only runs while it still owns the
-- current generation, so a stop() immediately followed by a start() retires the
-- old subscription instead of leaving two live drivers stepping every bot twice.
local generation = 0
local disconnectDriver: (() -> ())? = nil

-- Where the last frame's drain stopped; see FAIRNESS in the header.
local cursor = 1

-- Per-board "next update due at". Weak-keyed so a group board whose squad is
-- gone doesn't linger here. See updateBoardIfDue.
local boardDueAt: { [Types.Blackboard]: number } = setmetatable({}, { __mode = "k" }) :: any

local stats = { bots = 0, stepped = 0, deferred = 0, seconds = 0, budgetHits = 0, reentered = 0 }

-- True while a drain is in flight. Consumer hooks are supposed to be
-- non-yielding; if one yields anyway, the driver fires again on the next frame
-- and would start a SECOND drain over the same registry while the first is
-- suspended -- two coroutines mutating one bot's planner state, a frame budget
-- measuring wall time instead of work, and a slow-step warning reporting the
-- yield. The guard turns that from silent corruption into a counted, visible
-- refusal (Brain.stats().reentered).
local draining = false

-- Per-tunable bounds. Type alone was not enough: TICK_INTERVAL = -1 makes every
-- bot permanently due, FRAME_BUDGET = -1 makes the deadline immediately exceeded
-- so exactly one bot steps per frame, and a jitter above 1 can schedule a step
-- in the past. All three present as "the scheduler is broken" a long way from
-- the configure() call that caused them.
local BOUNDS: { [string]: { min: number, max: number? } } = {
	TICK_INTERVAL = { min = 1e-3 },
	FRAME_BUDGET = { min = 1e-5 },
	PLAN_COMMIT_BASE = { min = 1 },
	PLAN_COMMIT_GROWTH = { min = 0 },
	PLAN_COMMIT_MAX = { min = 1 },
	GOAL_JITTER = { min = 0, max = 1 },
	STEP_JITTER = { min = 0, max = 1 },
	PHASE_JITTER = { min = 0, max = 1 },
	TRACE_DECISIONS = { min = 0 },
}

-- Override any subset of the Config.luau defaults (TICK_INTERVAL, FRAME_BUDGET,
-- PLAN_COMMIT_*, the jitters, TRACE_DECISIONS). Takes effect from the next step.
function Brain.configure(overrides: { [string]: number })
	assert(type(overrides) == "table", "Bots.Brain.configure: an overrides table is required")
	local defaults = Config :: { [string]: number }
	local mutable = config :: { [string]: number }
	for key, value in overrides do
		assert(defaults[key] ~= nil, `Bots.Brain.configure: unknown tunable "{key}"`)
		assert(type(value) == "number" and value == value, `Bots.Brain.configure: tunable "{key}" must be a number`)
		local bound = BOUNDS[key]
		if bound then
			assert(value >= bound.min, `Bots.Brain.configure: "{key}" must be >= {bound.min} (got {value})`)
			local max = bound.max
			assert(max == nil or value <= max, `Bots.Brain.configure: "{key}" must be <= {max} (got {value})`)
		end
		mutable[key] = value
	end
end

-- THE REGISTRY. Unregistering tombstones the slot (`false`) instead of removing
-- it, and compaction happens only when nothing is iterating.
--
-- table.remove shifts every later element down, which is unsafe under the two
-- ways this array is walked: the frame drain holds a cursor ACROSS calls, so a
-- shift makes it skip a bot; and a removal at a lower index than the current
-- position makes an in-progress loop revisit a bot it already stepped. The old
-- code dodged the second by cloning the whole registry every tick -- correct, but
-- an O(bots) allocation per tick, and it never addressed the first.
local function indexOf(bot: Types.Bot): number?
	for index, entry in bots do
		if entry == bot then
			return index
		end
	end
	return nil
end

local function compact()
	if iterating > 0 or tombstones == 0 then
		return -- a live iteration is holding indices; compaction can wait
	end
	local live: { Types.Bot | false } = {}
	for _, entry in bots do
		if entry then
			table.insert(live, entry)
		end
	end
	bots = live
	tombstones = 0
	cursor = 1 -- indices moved; restart the rotation rather than skew fairness
end

-- Bot.new registers automatically; use register/unregister only when managing
-- bots manually
-- (e.g. re-registering a bot you unregistered to pause it).
function Brain.register(bot: Types.Bot)
	if indexOf(bot) == nil then
		table.insert(bots, bot)
		liveCount += 1
	end
end

function Brain.unregister(bot: Types.Bot)
	local index = indexOf(bot)
	if index then
		bots[index] = false
		liveCount -= 1
		tombstones += 1
		compact()
	end
end

function Brain.count(): number
	return liveCount
end

-- Drop every registered bot and reset the scheduler's own state: the rotation
-- cursor, the shared-board due times, and the stats counters. Meant for round
-- transitions and headless tests, where leftover bots from the last scenario
-- otherwise keep thinking.
--
-- Deliberately does NOT touch Config (a game's tuning survives a round),
-- the Rng/Clock seams, or the master board's SENSORS -- wiping those would be a
-- nasty surprise for a caller who only wanted the fleet cleared. Pass
-- `clearMaster = true` to also empty the master board's values and facts.
function Brain.reset(clearMaster: boolean?)
	for _, entry in bots do
		if entry then
			liveCount -= 1
		end
	end
	bots = {}
	tombstones = 0
	liveCount = 0
	cursor = 1
	table.clear(boardDueAt :: any)
	stats.stepped = 0
	stats.deferred = 0
	stats.seconds = 0
	stats.budgetHits = 0
	stats.reentered = 0
	if clearMaster then
		table.clear(Brain.master.values)
	end
end

-- A snapshot of the effective tunables (defaults + configure overrides). Used
-- by bot:explain()/abandonGoal(); a copy, so mutating it changes nothing --
-- go through Brain.configure.
function Brain.tunables(): Types.PlannerTunables
	return (table.clone(config) :: any) :: Types.PlannerTunables
end

-- What the last Brain.step did, plus the cumulative count of frames that ran out
-- of budget. `deferred > 0` frame after frame is the signal that the fleet wants
-- more LOD (raise tickInterval on distant bots) or a bigger FRAME_BUDGET.
function Brain.stats(): Types.BrainStats
	stats.bots = #bots
	return table.clone(stats) :: any
end

-- Update one shared board, isolated: a throwing sensor is warned and that
-- board's update abandoned for the cycle -- it must never kill the scheduler.
local function updateBoard(board: Types.Blackboard, clock: number)
	local ok, err = xpcall(board.update, debug.traceback, board, clock)
	if not ok then
		warn(`[Bots] blackboard "{board.name}" errored during sensor update:\n{err}`)
	end
end

-- Shared boards update at most once per TICK_INTERVAL even though the driver
-- fires every frame. WITHOUT this gate, moving from a 0.2s heartbeat to a
-- per-frame driver would silently fire every interval-0 sensor ~12x as often --
-- a large, invisible cost increase from what is meant to be a spike fix.
local function updateBoardIfDue(board: Types.Blackboard, clock: number)
	local dueAt = boardDueAt[board]
	if dueAt and clock < dueAt then
		return
	end
	boardDueAt[board] = clock + config.TICK_INTERVAL
	updateBoard(board, clock)
end

-- When this bot should next be stepped by the frame drain. The FIRST schedule
-- lands at a uniformly random phase inside the interval, which is what actually
-- spreads a fleet spawned in one frame across the whole interval; every schedule
-- after that is interval ±STEP_JITTER (Config), which keeps them from
-- re-converging.
local function scheduleNext(bot: Types.Bot, clock: number)
	local state = bot.planner
	local interval = bot.tickInterval or config.TICK_INTERVAL
	if state.nextStepAt == nil then
		state.nextStepAt = clock + interval * Rng.next()
	else
		state.nextStepAt = clock + interval * Rng.jitter(config.STEP_JITTER)
	end
end

-- Sense + plan one bot, isolated: a throwing personal sensor or hook is warned
-- and the bot skipped; every other bot still steps. Rescheduling lives HERE, so
-- every route into a step -- the frame drain, a manual tick, an out-of-band
-- stimulate -- pushes out the bot's next scheduled step. A bot that just
-- re-planned because it got shot should not also be stepped by the very next
-- frame drain.
local function stepBot(bot: Types.Bot, clock: number)
	local state = bot.planner
	if state.stepping then
		-- Reached only when a hook yielded: a stimulate (or a second drain) arrived
		-- while this bot's previous step was still suspended. Refuse, rather than
		-- run two steps over one planner state.
		warn(
			`[Bots] bot "{bot.id}" was stepped while its previous step was still running.`
				.. ` A sensor or action hook yielded -- Bots hooks must not yield.`
		)
		return
	end
	state.stepping = true
	local ok, err = xpcall(function()
		bot.blackboard:update(clock)
		Planner.step(bot, clock, config)
	end, debug.traceback)
	state.stepping = false
	if not ok then
		warn(`[Bots] bot "{bot.id}" errored during tick:\n{err}`)
	end
	scheduleNext(bot, clock)
end

-- One FULL cycle, unbudgeted: sense (master -> group boards -> per bot) then
-- plan/act for every bot its tickInterval says is due. Shared boards update
-- unconditionally here -- a tick is "bring the whole fleet up to date now", so
-- it deliberately does not consult the per-frame board gate. `now` is injectable
-- for tests; defaults to the package clock (Clock.luau).
function Brain.tick(now: number?)
	local clock = now or Clock.now()

	updateBoard(Brain.master, clock)

	iterating += 1

	-- Each distinct group board updates ONCE, no matter how many bots share it.
	local seenGroups: { [Types.Blackboard]: boolean } = {}
	for _, bot in bots do
		local group = if bot then bot.group else nil
		if group and not seenGroups[group] then
			seenGroups[group] = true
			updateBoard(group, clock)
		end
	end

	-- Tombstoned slots make this safe without cloning the registry: a bot
	-- destroyed mid-tick leaves a `false` behind rather than shifting its
	-- neighbours down under the loop.
	for _, entry in bots do
		local bot = entry
		if not bot then
			continue
		end
		local interval = bot.tickInterval
		if interval then
			-- Paced bot: only step when due. Its planner derives dt from its own
			-- last step, so slower thinking still hands actions the true elapsed
			-- seconds. (stepBot reschedules it.)
			local state = bot.planner
			if state.nextStepAt and clock < state.nextStepAt then
				continue
			end
		end
		stepBot(bot, clock)
	end

	iterating -= 1
	compact()
end

-- One frame's worth of scheduling: drain the bots that are due, oldest position
-- in the rotation first, until `budget` seconds of REAL time are spent. This is
-- what Brain.start's driver calls. `now` is injectable exactly as for tick;
-- note the budget is always measured against os.clock() even when `now` is a
-- simulated timeline, because a frame budget is about actual elapsed time.
local function drain(clock: number, total: number, budgetSeconds: number)
	local startedAt = os.clock()
	iterating += 1
	updateBoardIfDue(Brain.master, clock)

	local scanned = 0
	while scanned < total do
		local size = #bots
		if size == 0 then
			break
		end
		if cursor > size then
			cursor = 1
		end
		local bot = bots[cursor]
		cursor += 1
		scanned += 1
		if not bot then
			continue -- tombstoned slot, compacted once nothing is iterating
		end

		local state = bot.planner
		if state.nextStepAt == nil or clock >= state.nextStepAt then
			local group = bot.group
			if group then
				updateBoardIfDue(group, clock)
			end
			local stepStartedAt = os.clock()
			stepBot(bot, clock)
			stats.stepped += 1

			-- ONE bot ate the whole frame allowance. The budget bounds how MANY
			-- bots step, not what one step costs, and "always step at least one"
			-- means this cannot be prevented here -- so name it, because the
			-- instinct is to lower FRAME_BUDGET, which changes nothing. The usual
			-- culprit is a position query or a heavy sensor called per step
			-- instead of per goal adoption.
			local spent = os.clock() - stepStartedAt
			if spent >= budgetSeconds then
				warn(
					`[Bots] slow step: bot "{bot.id}" spent {math.floor(spent * 1000 + 0.5)}ms in goal`
						.. ` "{bot:currentGoal() or "<none>"}" (FRAME_BUDGET is {math.floor(budgetSeconds * 1000 + 0.5)}ms)`
				)
			end
			-- Budget is checked AFTER a step, never before, so at least one bot
			-- always moves: a single bot more expensive than the whole budget must
			-- not be able to wedge the rotation forever.
			if os.clock() - startedAt >= budgetSeconds then
				stats.deferred = total - scanned
				stats.budgetHits += 1
				break
			end
		end
	end

	iterating -= 1
	compact()
	stats.seconds = os.clock() - startedAt
end

-- One frame's worth of scheduling: drain the bots that are due, oldest position
-- in the rotation first, until `budget` seconds of REAL time are spent. This is
-- what Brain.start's driver calls. `now` is injectable exactly as for tick;
-- note the budget is always measured against os.clock() even when `now` is a
-- simulated timeline, because a frame budget is about actual elapsed time.
--
-- Refuses to overlap itself: see `draining`.
function Brain.step(now: number?, budget: number?)
	local clock = now or Clock.now()
	local total = #bots -- includes tombstones; the loop skips them
	stats.stepped = 0
	stats.deferred = 0
	stats.seconds = 0
	if total == 0 then
		return
	end
	if liveCount == 0 then
		return -- registry is all tombstones
	end
	if draining then
		stats.reentered += 1
		return
	end

	draining = true
	if profileBegin then
		profileBegin("Bots.Brain")
	end
	-- xpcall so a throw cannot leave `draining` stuck true, which would silently
	-- stop the entire fleet -- a far worse failure than the throw itself.
	local ok, err = xpcall(drain, debug.traceback, clock, total, budget or config.FRAME_BUDGET)
	if profileEnd then
		profileEnd()
	end
	draining = false
	if not ok then
		warn(`[Bots] Brain.step errored mid-drain:\n{err}`)
	end
end

-- Out-of-band reaction: write stimulus values to the bot's personal board, then
-- sense+plan JUST this bot immediately -- so a drastic event (got shot, heard
-- an explosion) is reacted to NOW instead of at its next scheduled step.
-- Commitment still applies: a stimulus interrupts by raising challenger scores,
-- not by bypassing the arbiter; pair with bot:abandonGoal() for unconditional
-- drops. bot:stimulate(values?, now?) forwards here. `now` defaults to
-- the package clock; inject it when driving simulated clocks (headless tests), so
-- out-of-band steps stamp the same timeline as your Brain.tick(now) calls.
function Brain.stimulate(bot: Types.Bot, values: { [string]: any }?, now: number?)
	assert(values == nil or type(values) == "table", "Bots.Brain.stimulate: values must be a table when set")
	assert(now == nil or type(now) == "number", "Bots.Brain.stimulate: now must be a number when set")
	if values then
		for key, value in values do
			bot.blackboard.values[key] = value
		end
	end
	stepBot(bot, now or Clock.now())
end

-- Squad-wide stimulate: write values to the GROUP board, then immediately step
-- every registered bot sharing it. This is the delivery mechanism for orders:
-- `Brain.stimulateGroup(squadBoard, { order = "fallBack" })` and every squad
-- member re-plans against the new order the same instant. Deliberately
-- unbudgeted -- "react NOW" is the whole contract -- but because each member is
-- rescheduled as it steps, the squad's NEXT scheduled steps land spread apart
-- rather than all together. `now` as above.
function Brain.stimulateGroup(group: Types.Blackboard, values: { [string]: any }?, now: number?)
	assert(type(group) == "table", "Bots.Brain.stimulateGroup: a group blackboard is required")
	assert(values == nil or type(values) == "table", "Bots.Brain.stimulateGroup: values must be a table when set")
	assert(now == nil or type(now) == "number", "Bots.Brain.stimulateGroup: now must be a number when set")
	if values then
		for key, value in values do
			group.values[key] = value
		end
	end
	local clock = now or Clock.now()
	iterating += 1
	for _, entry in bots do
		if entry and entry.group == group then
			stepBot(entry, clock)
		end
	end
	iterating -= 1
	compact()
end

-- The self-contained default: one Brain.step per Heartbeat. Built lazily inside
-- start(), so requiring this module stays safe outside Roblox -- Brain.tick and
-- Brain.step are pure and headless-testable, and only start() needs a world.
local function defaultDriver(): Types.BrainDriver
	assert(
		(game :: any) ~= nil,
		"Bots.Brain.start: no RunService here -- pass a driver, or call Brain.step/Brain.tick from your own loop"
	)
	local RunService = game:GetService("RunService")
	return function(callback)
		local connection = RunService.Heartbeat:Connect(callback)
		return function()
			connection:Disconnect()
		end
	end
end

-- Start the built-in scheduler: Brain.step once per frame, under FRAME_BUDGET.
-- Idempotent. Pass a driver to hang it off your game's own frame phase instead
-- of Heartbeat; it receives a callback and returns a disconnect function.
function Brain.start(driver: Types.BrainDriver?)
	if running then
		return
	end
	running = true
	generation += 1
	local mine = generation
	local subscribe = driver or defaultDriver()
	disconnectDriver = subscribe(function()
		if running and generation == mine then
			Brain.step()
		end
	end)
end

function Brain.stop()
	running = false
	local disconnect = disconnectDriver
	disconnectDriver = nil
	if disconnect then
		disconnect()
	end
end

return Brain
