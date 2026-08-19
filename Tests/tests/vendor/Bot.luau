--!strict

-- The bot object: identity + body + blackboard + goal set + planner state, tied
-- together and registered with the Brain. The library spawns NOTHING -- `body`
-- is a free-form table of whatever the consumer's sensors and actions need (a
-- rig, a Humanoid, a player's existing character, capability closures, a mover
-- from the Pathfinding library). That is what lets the same core drive an NPC,
-- an enemy, or a playerbot: only the body table differs.
--
-- Everything is validated loudly here, ONCE, at creation: goal/action shapes,
-- duplicate names, and every declared `requires` field against the body -- so
-- a missing wire is a clear error at Bot.new, not a nil-call mid-game.

local Blackboard = require("./Blackboard")
local Brain = require("./Brain")
local Clock = require("./Clock")
local Goal = require("./Goal")
local Planner = require("./Planner")
local Types = require("./Types")

local Bot = {}

local nextId = 0

-- The final validation gate. Shape checks are shared with the Goal/Action
-- constructors (Goal.validate cascades into Action.validate); the list-level
-- rule -- no duplicate goal names -- is checked here, where the list exists.
local function validateGoals(goals: { Types.Goal })
	assert(type(goals) == "table" and #goals > 0, "Bots.Bot.new: goals must be a non-empty array of Goals")
	local seen: { [string]: boolean } = {}
	for index, goal in goals do
		Goal.validate(goal, `Bots.Bot.new: goals[{index}]`)
		assert(not seen[goal.name], `Bots.Bot.new: duplicate goal name "{goal.name}"`)
		seen[goal.name] = true
	end
end

-- Every `requires` declared by the goals/actions must exist on the body.
local function checkBody(goals: { Types.Goal }, body: { [string]: any })
	local function check(requires: { string }?, owner: string)
		if requires then
			for _, field in requires do
				if body[field] == nil then
					error(`Bots.Bot.new: body is missing '{field}' (required by {owner})`, 3)
				end
			end
		end
	end
	for _, goal in goals do
		check(goal.requires, `goal "{goal.name}"`)
		for _, action in goal.actions do
			check(action.requires, `action "{action.name}" of goal "{goal.name}"`)
		end
	end
end

function Bot.new(params: Types.BotParams): Types.Bot
	assert(type(params) == "table", "Bots.Bot.new: a params table is required")
	validateGoals(params.goals)
	local body = params.body or {}
	checkBody(params.goals, body)
	assert(
		params.tickInterval == nil or (type(params.tickInterval) == "number" and params.tickInterval > 0),
		"Bots.Bot.new: tickInterval must be a positive number when set"
	)

	nextId += 1
	local id = params.id or `bot_{nextId}`

	local bot = {} :: Types.Bot
	bot.id = id
	bot.body = body
	bot.goals = params.goals
	bot.group = params.group
	bot.tickInterval = params.tickInterval
	bot.planner = Planner.newState()
	bot.blackboard = Blackboard.new(id, params.values, bot)

	if params.sensors then
		for key, spec in params.sensors do
			if type(spec) == "function" then
				bot.blackboard:addSensor(key, spec)
			else
				local record = spec :: { read: (any, Types.Blackboard) -> any, interval: number? }
				bot.blackboard:addSensor(key, record.read, record.interval)
			end
		end
	end

	-- Read with personal -> group -> master fallthrough; writes go personal.
	function bot.get(_, key: string): any
		local value = bot.blackboard.values[key]
		if value ~= nil then
			return value
		end
		local group = bot.group
		if group then
			value = group.values[key]
			if value ~= nil then
				return value
			end
		end
		return Brain.master.values[key]
	end

	function bot.set(_, key: string, value: any)
		bot.blackboard.values[key] = value
	end

	-- Fact read with the same personal -> group -> master fallthrough as get;
	-- returns (value, decayed confidence) or (nil, nil) when unknown/expired.
	function bot.getFact(_, key: string): (any, number?)
		local value, confidence = bot.blackboard:getFact(key)
		if value ~= nil then
			return value, confidence
		end
		local group = bot.group
		if group then
			value, confidence = group:getFact(key)
			if value ~= nil then
				return value, confidence
			end
		end
		return Brain.master:getFact(key)
	end

	-- Remember a personal fact: fades to forgotten across ttl seconds (see
	-- Blackboard.setFact).
	function bot.setFact(_, key: string, value: any, ttl: number?, confidence: number?)
		bot.blackboard:setFact(key, value, ttl, confidence)
	end

	-- "React NOW": write stimulus values to the personal board, then run one
	-- immediate out-of-band sense+plan step for this bot (see Brain.stimulate).
	-- `now` is optional and only matters under simulated clocks.
	function bot.stimulate(_, values: { [string]: any }?, now: number?)
		Brain.stimulate(bot, values, now)
	end

	function bot.currentGoal(_): string?
		local execution = bot.planner.current
		return if execution then execution.goal.name else nil
	end

	-- "Something drastic happened, drop everything": the in-flight action exits
	-- with "Interrupted" and the bot re-plans from scratch next tick.
	function bot.abandonGoal(_)
		Planner.abandon(bot, Brain.tunables(), Clock.now())
	end

	function bot.context(_): Types.PlannerContext
		return Planner.context(bot, Clock.now())
	end

	-- Recorded decisions, newest first (see the TRACE_DECISIONS tunable).
	function bot.trace(_): { Types.TraceEvent }
		return Planner.trace(bot)
	end

	-- Live "what would happen right now, and why" -- every goal's selection
	-- verdict plus the bar a challenger must clear. Works with tracing off.
	function bot.explain(_): Types.Explanation
		return Planner.explain(bot, Clock.now(), Brain.tunables())
	end

	function bot.destroy(_)
		Planner.abandon(bot, Brain.tunables(), Clock.now())
		Brain.unregister(bot)
	end

	Brain.register(bot)
	return bot
end

return Bot
