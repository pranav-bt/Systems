--!strict

-- Bots: a generic, game-agnostic agent brain for Roblox. Blackboard-driven
-- sensing, utility-scored goal selection, and sequenced action execution --
-- with zero assumptions about what a "bot" physically is. The same core drives
-- an ambient NPC, an enemy AI, or a playerbot puppeting a real player's
-- character: the consumer supplies the body, the sensors, the goals, and the
-- actions; the library supplies the thinking.
--
--   Blackboard -- named value bags + consumer sensors + working-memory facts
--                 (master / group / per-bot)
--   Bot        -- ties a free-form body + goals + boards together (Bot.new)
--   Goal/Action-- constructors: validate a definition where it is written
--   Planner    -- utility selection, commitment, sequenced execution, interrupts
--   Brain      -- the singleton heartbeat that senses and steps every bot,
--                 plus stimulate/stimulateGroup for out-of-band reactions
--   Tokens     -- claimable pools (at most N holders) for squad coordination
--   Utility    -- response-curve helpers for writing score functions
--
-- Movement is deliberately NOT here: this library contains no mover, no
-- movement actions, and no pathfinding types. Your actions drive whatever you
-- put in bot.body -- see the sibling Pathfinding library for a ready-made
-- Mover contract + PathAgent implementation.
--
-- This module is the package's whole public surface: consumers require it once
-- and never reach into the package's internals.

local Action = require(script.Action)
local Blackboard = require(script.Blackboard)
local Bot = require(script.Bot)
local Clock = require(script.Clock)
local Brain = require(script.Brain)
local Goal = require(script.Goal)
local Planner = require(script.Planner)
local Rng = require(script.Rng)
local Tokens = require(script.Tokens)
local Types = require(script.Types)
local Utility = require(script.Utility)

-- Public types, re-exported so callers can annotate everything from one require.
export type Action = Types.Action
export type ActionResult = Types.ActionResult
export type ActionOutcome = Types.ActionOutcome
export type Goal = Types.Goal
export type Bot = Types.Bot
export type BotParams = Types.BotParams
export type Blackboard = Types.Blackboard
export type SensorSpec = Types.SensorSpec
export type PlannerContext = Types.PlannerContext
export type Fact = Types.Fact
export type Tokens = Types.Tokens
export type TraceEvent = Types.TraceEvent
export type GoalVerdict = Types.GoalVerdict
export type Explanation = Types.Explanation
export type BrainDriver = Types.BrainDriver
export type BrainStats = Types.BrainStats

local Bots = {}

Bots.Bot = Bot -- Bots.Bot.new(params) -> Bot
Bots.Goal = Goal -- Bots.Goal.new(spec): validate a goal where it's written
Bots.Action = Action -- Bots.Action.new(spec): validate an action where it's written
Bots.Brain = Brain -- singleton: start/stop/tick/configure/stimulate/master/register/unregister/count
Bots.Planner = Planner -- Planner.context(bot) snapshots; Planner.abandon(bot)
Bots.Blackboard = Blackboard -- Blackboard.new(name, initialValues?, owner?) for group boards
Bots.Tokens = Tokens -- Tokens.new(name, capacity, ttl?): claimable pools for squad coordination
Bots.Utility = Utility -- response curves: linear/quad/logistic/combine

-- Replace the package's random generator (nil restores math.random). With the
-- three jitter tunables at 0, a seeded generator makes a headless run exactly
-- reproducible -- see Rng.luau.
function Bots.setRandom(fn: (() -> number)?)
	Rng.set(fn)
end

-- Replace the package's clock (nil restores os.clock). Set this to the same
-- timeline you pass to Brain.tick / Brain.step, so fact timestamps and token
-- leases cannot drift onto a different one -- see Clock.luau.
function Bots.setClock(fn: (() -> number)?)
	Clock.set(fn)
end

return Bots
