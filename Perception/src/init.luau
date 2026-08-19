--!strict

-- Perception: the sensing layer every game AI rewrites by hand, packaged --
-- vision with awareness-over-time, hearing as an occlusion-aware stimulus
-- bus, and raycast budgeting for fleets.
--
--   Vision    -- Vision.new(config): FOV cone + range + line-of-sight +
--                awareness that FILLS while a target stays visible and decays
--                when lost (None -> Suspicious -> Detected, sticky detection)
--   Hearing   -- Hearing.new(config?): emit("gunshot", pos, radius) reaches
--                registered listeners, attenuated through walls
--   Budget    -- Budget.new(perSecond, burst?): token-bucket ray allowance
--                shared across sensors, so fleets degrade to slower reactions
--                instead of raycast spikes
--   Raycaster -- Raycaster.new(params?): the default workspace raycast;
--                inject your own RaycastFn for custom worlds
--
-- The core modules only do vector MATH on positions (never construct them)
-- and take every world query as an injectable raycast function -- same shape
-- as TacticalQuery's probes.raycast, so one game function serves both.
--
-- This package depends on nothing, including the sibling Bots library. It
-- integrates with Bots through Bots' own contracts: host a Vision in a
-- blackboard sensor (write `lastSeenPos` facts from the report), publish the
-- report to the board, and THEN call bot:stimulate for the report's status
-- events and from Hearing callbacks -- see the README for the exact wiring and
-- why that order matters.

local Budget = require(script.Budget)
local Hearing = require(script.Hearing)
local Raycaster = require(script.Raycaster)
local Types = require(script.Types)
local Vision = require(script.Vision)

-- Public types, re-exported so callers can annotate everything from one require.
export type RaycastFn = Types.RaycastFn
export type Target = Types.Target
export type TargetStatus = Types.TargetStatus
export type TargetPerception = Types.TargetPerception
export type StatusEvent = Types.StatusEvent
export type VisionReport = Types.VisionReport
export type Vision = Types.Vision
export type VisionConfig = Vision.Config
export type Sound = Types.Sound
export type Listener = Types.Listener
export type Audience = Types.Audience
export type Hearing = Types.Hearing
export type HearingConfig = Hearing.Config
export type Budget = Types.Budget
export type BudgetStats = Types.BudgetStats

local Perception = {}

Perception.Vision = Vision -- Vision.new(config) -> sensor with update/forget
Perception.Hearing = Hearing -- Hearing.new(config?) -> bus with emit/listen
Perception.Budget = Budget -- Budget.new(perSecond, burst?) -> shared ray allowance
Perception.Raycaster = Raycaster -- Raycaster.new(params?) -> default RaycastFn

return Perception
