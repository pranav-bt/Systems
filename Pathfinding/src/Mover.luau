--!strict

-- THE mover contract: what any pathfinding/movement system must expose to be
-- driven from the outside (e.g. by a Bots action). Deliberately tiny -- four
-- methods, plain data -- so navmesh followers, grid A*, flow fields, or vehicle
-- controllers all fit behind the same shape. PathAgent.luau is the reference
-- implementation; this module is types only.
--
-- Status semantics (polled -- callers ask each tick, movers never call back):
--   "Idle"        -- no destination set, or no living body to move
--   "Computing"   -- destination accepted; no path produced yet
--   "Moving"      -- making progress toward the destination
--   "Arrived"     -- within arrival distance of the destination
--   "Stuck"       -- has a path but is making no progress at its finest
--                    resolution (wedged); clears if real progress resumes
--   "Unreachable" -- no path exists and the destination is too far to nudge
--                    toward in a straight line
--
-- A typical driving action: SetGoal every tick (cheap -- movers dedupe), then
-- poll GetStatus and map "Arrived" (or your own range check) to Success and
-- "Stuck" / "Unreachable" to Failure.
export type MoverStatus = "Idle" | "Computing" | "Moving" | "Arrived" | "Stuck" | "Unreachable"

export type Mover = {
	-- Move toward this world position, recomputing as needed (nil = stop).
	-- Safe to call every tick with the same or a drifting goal.
	SetGoal: (Mover, Vector3?) -> (),
	GetStatus: (Mover) -> MoverStatus,
	Stop: (Mover) -> (),
	Destroy: (Mover) -> (),
}

return {}
