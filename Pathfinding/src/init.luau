--!strict

-- Pathfinding: movement for driven bodies, behind two tiny contracts.
--
--   Mover          -- "go to this position": SetGoal / GetStatus / Stop /
--                     Destroy, polled status. PathAgent is the
--                     PathfindingService reference implementation.
--   RouteFollower  -- "walk this list": authored waypoints with raw MoveTo and
--                     no navmesh at all. Routes authors and registers them.
--
-- They are separate capabilities, not alternatives -- a bot can hold both
-- (body.mover and body.route) and walk a route out of spawn before handing off
-- to free pathing. Followers report the Mover status vocabulary, so driving
-- code polls either one the same way.
--
-- Deliberately independent of the Bots library (and everything else): decision
-- systems drive a Mover from their own behaviour code; any custom system that
-- matches the contract (grid A*, flow fields, vehicles) substitutes for
-- PathAgent without the caller changing.

local Mover = require(script.Mover)
local PathAgent = require(script.PathAgent)
local Paths = require(script.Paths)
local Routes = require(script.Routes)

export type Mover = Mover.Mover
export type MoverStatus = Mover.MoverStatus
export type PathAgentOptions = PathAgent.Options
export type Route = Routes.Route
export type RouteMode = Routes.Mode
export type RouteFollower = Routes.RouteFollower
export type RouteFollowerOptions = Routes.FollowerOptions
export type PathRequest = Paths.RequestSpec
export type PathResult = Paths.Result
export type PathStats = Paths.Stats

local Pathfinding = {}

Pathfinding.PathAgent = PathAgent -- PathAgent.new(humanoid, rootPart, options?) -> Mover
Pathfinding.Paths = Paths -- the shared compute broker: configure / stats / request / reset
Pathfinding.Routes = Routes -- load/get/names authoring + Routes.follower(humanoid, root, options?)

return Pathfinding
