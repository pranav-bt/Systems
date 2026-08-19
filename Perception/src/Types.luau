--!strict

-- Shared types for the perception package. The core modules (Vision, Hearing,
-- Budget) only call METHODS on position values (`-`, `.Magnitude`, `:Dot`,
-- vector arithmetic), never construct them -- so they work with Vector3s (or
-- anything vector-shaped) and stay testable outside Roblox. The only module
-- that touches the world is the injectable raycast function; Raycaster.luau
-- builds the workspace default.

-- A ray query: first hit along `direction` from `origin` (the ray is exactly
-- that long); nil = clear line. Structurally identical to TacticalQuery's
-- probes.raycast, so one game function can serve both packages.
export type RaycastFn = (origin: any, direction: any) -> any?

-- Something a vision sensor can look for. `ref` is the stable identity that
-- awareness accumulates against (a player, a character model, a bot -- any
-- table/userdata); `position` is where to look this update (typically the
-- head or torso, refreshed by the provider each call).
export type Target = {
	ref: any,
	position: any,
}

-- Where a target sits in the classic three-stage detection ladder:
--   "None"       -- awareness below the suspicion threshold
--   "Suspicious" -- something's there (play alert animation, investigate)
--   "Detected"   -- fully seen (engage). STICKY: once reached, it holds until
--                   awareness decays below the suspicion threshold again --
--                   an enemy doesn't flicker out of "detected" by strafing.
export type TargetStatus = "None" | "Suspicious" | "Detected"

-- One target's perception snapshot, as returned in a VisionReport.
export type TargetPerception = {
	ref: any,
	status: TargetStatus,
	awareness: number, -- 0..1 accumulated belief
	visible: boolean, -- passed cone + range + line-of-sight (see `stale`)
	strength: number, -- visibility strength 0..1 (0 when not visible)
	-- True when a dry raycast budget meant this target got NO ray this update:
	-- its awareness is frozen (neither filling nor decaying) and `visible` /
	-- `strength` describe the last update that did sample it. Always false when
	-- no budget is configured.
	stale: boolean,
	position: any?, -- last position the target was actually SEEN at (nil if never)
	seenAt: number?, -- clock time of the last sighting (nil if never)
}

-- A status change that happened during ONE update ("None" -> "Suspicious",
-- "Suspicious" -> "Detected", ...). The detection EDGE, which is what reaction
-- code cares about -- a target that was already Detected last update produces
-- no event.
export type StatusEvent = {
	ref: any,
	from: TargetStatus,
	to: TargetStatus,
}

-- What Vision:update returns. `targets` is sorted by awareness, highest
-- first, and only contains entries with any awareness or visibility left;
-- `best` is targets[1] (nil when the sensor is fully cold). `events` holds
-- this update's status edges (empty when nothing changed) -- react to THOSE
-- after publishing the report, never from inside the update; see Vision.luau.
export type VisionReport = {
	targets: { TargetPerception },
	events: { StatusEvent },
	best: TargetPerception?,
	sampled: number, -- in-cone targets that got a line-of-sight ray this update
	frozen: number, -- in-cone targets the budget refused (awareness held, `stale`)
}

-- A vision sensor (build with Vision.new). Call update() on your cadence --
-- a Bots blackboard sensor is the natural host -- and read the report.
export type Vision = {
	update: (self: Vision, now: number?) -> VisionReport,
	forget: (self: Vision, ref: any?) -> (), -- drop one target's awareness (or all when nil)
}

-- A sound event as delivered to hearing listeners.
export type Sound = {
	kind: string, -- consumer vocabulary: "gunshot", "footstep", "explosion", ...
	position: any, -- where it happened
	radius: number, -- how far it carries (pre-occlusion)
	distance: number, -- how far THIS listener was from it
	occluded: boolean, -- geometry between the sound and this listener
	data: any?, -- whatever the emitter attached
}

-- One ear on the bus. `position` is polled at emit time; `onHeard` fires for
-- every sound that reaches it (errors are isolated per listener).
export type Listener = {
	position: () -> any,
	onHeard: (sound: Sound) -> (),
	acuity: number?, -- hearing multiplier: 2 = hears twice as far (default 1)
	-- Stable identity for this ear (the bot, its id, anything). Optional, but an
	-- array `Audience` can only reach listeners that declared one.
	ref: any?,
	-- When set, this ear hears ONLY these kinds: { gunshot = true }. Rejected
	-- before range or rays, so ignored kinds are free.
	kinds: { [string]: boolean }?,
}

-- Who an emit is even considered for, checked before range and occlusion.
-- An array of refs walks the audience rather than the registry (cost is
-- O(#audience)); a predicate filters every listener by its `ref`, which is nil
-- for listeners that declared none.
export type Audience = { any } | (ref: any) -> boolean

-- A hearing bus (build with Hearing.new): emit sounds, register listeners.
export type Hearing = {
	emit: (self: Hearing, kind: string, position: any, radius: number, data: any?, audience: Audience?) -> (),
	listen: (self: Hearing, listener: Listener) -> () -> (), -- returns disconnect
	forget: (self: Hearing, ref: any) -> (), -- drop every ear registered under a ref
	count: (self: Hearing) -> number, -- registered listeners
}

-- What a budget has done since it was created. Shaped like Bots' Brain.stats().
export type BudgetStats = {
	granted: number, -- take() calls that were afforded
	refused: number, -- take() calls that were refused (the number to watch)
	available: number, -- tokens in the bucket right now
}

-- A token-bucket raycast budget, shared by however many Vision sensors and
-- Hearing buses should compete for the same per-second allowance. A dry bucket
-- costs reaction speed, never correctness: Vision freezes the targets it could
-- not cast for (awareness holds, flagged `stale`), Hearing lets the sound
-- through, and TacticalQuery abstains -- see each package for why they differ.
export type Budget = {
	take: (self: Budget, count: number?, now: number?) -> boolean,
	available: (self: Budget, now: number?) -> number,
	stats: (self: Budget, now: number?) -> BudgetStats,
}

return {}
