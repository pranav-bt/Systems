--!strict

-- TacticalQuery: an EQS-style tactical position-query system for Roblox --
-- "find cover from the threat", "find a flank", "find a spot near my allies
-- with line of sight". Generate candidate points, score them through weighted
-- tests in cost order (math -> raycasts -> reachability), return the winner
-- with a per-test score breakdown.
--
--   Query      -- Query.new(spec): validate a definition where it is written
--   Engine     -- the pure pipeline (generate -> cheap -> ground -> expensive -> validate)
--   Generators -- ring / grid / tagged candidate producers (or any function)
--   Tests      -- distance / direction / spacing / hidden / exposed / reachable
--   Probes     -- the ONLY world surface: raycast / snapToGround / isReachable.
--                 Defaults use workspace:Raycast; swap the table for other worlds.
--   Curves     -- tiny scoring ramps (linear / band) for custom tests
--   Debug      -- draw a run: every candidate graded by score, the winner, and
--                 the breakdown that produced it (development tool)
--
-- The engine treats positions as opaque values and touches no Roblox APIs;
-- only the built-in Generators/Tests/Probes assume Vector3s. Decision systems
-- (e.g. the sibling Bots library) call query:run from their actions -- this
-- package depends on nothing and nothing depends on it.

local Curves = require(script.Curves)
local Debug = require(script.Debug)
local Engine = require(script.Engine)
local Generators = require(script.Generators)
local Probes = require(script.Probes)
local Query = require(script.Query)
local Tests = require(script.Tests)
local Types = require(script.Types)

-- Public types, re-exported so callers can annotate everything from one require.
export type Query = Types.Query
export type Test = Types.Test
export type TestCost = Types.TestCost
export type Generator = Types.Generator
export type Probes = Types.Probes
export type ProbeHit = Types.ProbeHit
export type Context = Types.Context
export type Candidate = Types.Candidate
export type RunInfo = Types.RunInfo
export type Budget = Types.Budget
export type TestStages = Types.TestStages
export type DrawOptions = Debug.DrawOptions

local TacticalQuery = {}

TacticalQuery.Query = Query -- Query.new(spec) -> Query; Query.setDefaultProbes(probes)
TacticalQuery.Generators = Generators -- ring / grid / tagged builders
TacticalQuery.Tests = Tests -- distance / direction / spacing / hidden / exposed / reachable builders
TacticalQuery.Probes = Probes -- Probes.new(config?) -> the default Roblox world surface
TacticalQuery.Engine = Engine -- Engine.run(query, context, probes) if you bypass query:run
TacticalQuery.Curves = Curves -- linear / band / clamp01 ramps for custom tests
TacticalQuery.Debug = Debug -- Debug.draw(name, info, winner?, options?) / Debug.clear(name?)

-- Wire the Roblox defaults so query:run() works out of the box; games with an
-- exclusion list (characters!) should overwrite this with their own:
-- TacticalQuery.Query.setDefaultProbes(TacticalQuery.Probes.new({ params = myParams })).
Query.setDefaultProbes(Probes.new())

return TacticalQuery
