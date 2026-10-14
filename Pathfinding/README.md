# Pathfinding

Movement for driven bodies, behind two tiny contracts, with every navmesh
computation funnelled through one bounded broker. **`Mover`** answers "go
to this position" -- with **`PathAgent`**, a Roblox PathfindingService reference
implementation for Humanoid bodies. **`RouteFollower`** answers "walk this list"
-- authored waypoints walked with raw MoveTo and no navmesh at all, authored and
registered by **`Routes`**. They are separate capabilities, not alternatives: a
bot can hold both and walk a route out of spawn before handing off to free
pathing. A shared **`Paths`** broker caps how many expensive computations run at
once, ages queued requests so none starve, and lets a moved goal cancel the work
it invalidated — and because it takes a closure rather than a `Path`, your own
voxel or grid pathfinder queues through it too. It depends on nothing — including the `Bots` library:
decision systems
drive a `Mover` from their own behaviour code, and any custom movement system
that matches the contract substitutes for `PathAgent` without callers changing.

**Reading the source?** [`Mover.luau`](src/Mover.luau) is ~30 lines and IS
the library's whole idea — read it first. [`PathAgent.luau`](src/PathAgent.luau)
is just one implementation of it (open only when you need the navmesh
mechanics); [`Paths.luau`](src/Paths.luau) is the compute broker; and
[`Routes.luau`](src/Routes.luau) carries the authoring registry and the follower.

---

## The Mover contract

```lua
export type Mover = {
    SetGoal: (Mover, Vector3?) -> (),   -- destination (nil = stop); safe to call every tick
    GetStatus: (Mover) -> MoverStatus,  -- polled; movers never call back
    Stop: (Mover) -> (),
    Destroy: (Mover) -> (),
}

export type MoverStatus = "Idle" | "Computing" | "Moving" | "Arrived" | "Stuck" | "Unreachable"
```

| Status | Meaning |
|---|---|
| `Idle` | No destination set, or no living body to move. |
| `Computing` | Destination accepted; no path produced yet. |
| `Moving` | Making progress toward the destination. |
| `Arrived` | Within arrival distance of the destination. |
| `Stuck` | Has a path but no progress at the finest resolution (wedged). Sticky until real progress resumes or a new goal is set. |
| `Unreachable` | No path exists and the destination is too far to nudge toward in a straight line. |

The polling model fits tick-driven behaviour code: call `SetGoal` freely each
tick (movers dedupe near-identical goals), read `GetStatus`, and map `Arrived`
(or your own range check) to success and `Stuck` / `Unreachable` to failure.

## Quick start (standalone)

```lua
local Pathfinding = require(path.to.Pathfinding)

local rig = template:Clone()
rig.Parent = workspace
local mover = Pathfinding.PathAgent.new(rig.Humanoid, rig.HumanoidRootPart)

mover:SetGoal(workspace.Objective.Position)
task.spawn(function()
    while true do
        task.wait(0.2)
        local status = mover:GetStatus()
        if status == "Arrived" then
            print("made it")
            break
        elseif status == "Stuck" or status == "Unreachable" then
            warn("can't get there:", status)
            break
        end
    end
    mover:Destroy()
end)
```

Driving it from a [Bots](../Bots/) action:

```lua
local ChaseTarget = Bots.Action.new({
    name = "ChaseTarget",
    requires = { "mover" },
    update = function(bot)
        local target = bot:get("nearestTarget")
        if not target then
            return "Failure"
        end
        if target.distance < 6 then
            return "Success"
        end
        local mover = bot.body.mover
        mover:SetGoal(target.position)
        local status = mover:GetStatus()
        if status == "Stuck" or status == "Unreachable" then
            return "Failure"
        end
        return "Running"
    end,
    exit = function(bot)
        bot.body.mover:Stop()
    end,
})
```

---

## PathAgent

`PathAgent.new(humanoid, rootPart, options?) -> Mover`

The reference implementation: computes navmesh paths and walks the waypoints
with `Humanoid:MoveTo`, on its own loop so callers never block.

- **Adaptive waypoint spacing** — starts coarse (waypoints only at real
  corners, so long straights run at full speed with no braking), halves to a
  finer path on stall detection, resets on arrival or a new goal.
- **Repaths** when the goal drifts (chasing), on a periodic timer (dynamic
  obstacles), or after failure — always through the shared [broker](#paths--the-compute-broker), never straight to
  PathfindingService.
- **Sleeps at the destination** — parked within `waypointReached` of its goal it
  suspends entirely: no computes, no `MoveTo`, and no polling either. `SetGoal`
  wakes it when the goal actually moves. Holding a post costs nothing, so an
  action can keep `SetGoal`-ing the same spot for as long as it runs.
- **Straight-line fallback** across small navmesh gaps; holds position instead
  of marching blindly toward far unreachable goals.
- Every risky call is guarded, so a body dying mid-path can't error the loop.

All tunables are per-instance options (defaults in parentheses):

| Option | Default | Meaning |
|---|---|---|
| `agentRadius` / `agentHeight` / `agentCanJump` | `2` / `5` / `true` | `CreatePath` agent parameters. |
| `costs` | none | `PathfindingModifier` costs by label: `{ Water = 20, Furniture = math.huge }`. The **only** way to say "walkable, but don't" — see below. |
| `repathInterval` | `3.0` | Periodic recompute (chasing repaths sooner via drift). |
| `repathThreshold` | `8` | Goal drift that forces a recompute. |
| `waypointTimeout` | `1.5` | No-progress time that marks a segment stalled. |
| `waypointReached` | `4` | Distance that counts a waypoint (and the goal) reached. |
| `waypointSpacing` | `120` | Coarse starting spacing (smooth straight runs). |
| `waypointSpacingMin` | `4` | Finest spacing after adaptive halving. |
| `stuckProgress` | `2` | Studs moved to still count as progressing. |
| `straightLineMax` | `24` | On NoPath, only straight-line to a goal within this range. |
| `priority` | `0` | Queue priority for this agent's computations; higher runs sooner when the broker is saturated. |
| `debug` | `false` | Draw computed paths in `workspace.BotPathDebug` + print NoPath navmesh probes. |

### `costs` — telling the navmesh what to avoid

Everything else in that table describes the agent. `costs` describes the **world**, and it is
the only way to say *walkable, but don't*.

```lua
local agent = PathAgent.new(humanoid, root, {
    costs = { Water = 20, Furniture = math.huge },   -- math.huge = impassable
})
```

Without it, anything technically standable is fair game. The case this was added for: a
crafting table with flat collidable parts three studs up is a **platform** as far as
`PathfindingService` is concerned, so a route across the room goes *over* it. The waypoint
sits a stud above the floor, an R6 humanoid cannot step onto it, and the agent wedges —
reporting `Moving`, position frozen, and stall detection never firing, because each repath
produces the same route and resets it. The mover is behaving correctly given the path it was
handed; the path is the problem.

Two halves, and only one of them is here:

- **the cost** is this option, passed through to `CreatePath`
- **the label** is authored in your game, on `PathfindingModifier` instances. Nothing in this
  package creates them.

Costs are read at **every** `CreatePath`, not captured once, so the adaptive-spacing rebuild
keeps them — an agent that forgot its costs the first time it stalled would path straight over
the furniture it had been avoiding. Changing them needs a new agent, the same as
`waypointSpacing`.

The table is validated when the agent is built, naming the offending label, because
`CreatePath` throws from inside the engine without saying which entry was wrong.

**Before reaching for it:** an invisible blocker taller than `agentHeight` over the offending
model's footprint also makes the navmesh route around instead of over, with no code at all.
That is pure level authoring and it is often the right answer — `costs` earns its place when
the thing should be *discouraged* rather than forbidden, or when the geometry is authored by
players and cannot be blocked by hand.

---

## Paths — the compute broker

`ComputeAsync` is the most expensive thing the default mover does, and agents
used to call it independently. A squad that all received a destination in the same frame
issued a burst of simultaneous computations with nothing bounding them — outside
any budget the decision layer thought it was enforcing. Every `PathAgent`
computation now goes through one shared broker instead.

```lua
Pathfinding.Paths.configure({ maxConcurrent = 4, ageBoost = 1 })
Pathfinding.Paths.stats()   -- { queued, active, completed, discarded, failed,
                            --   lastWaitSeconds, maxWaitSeconds }
Pathfinding.Paths.reset()   -- drop the queue (round transitions, tests)
```

You do not have to call any of it — `PathAgent` uses the broker automatically.
The dials matter when a fleet gets large:

| Option | Default | Meaning |
|---|---|---|
| `maxConcurrent` | `4` | Computations allowed to run at once. Too low and a squad takes visible seconds to all get moving; too high and you are back to the burst this exists to prevent. |
| `ageBoost` | `1.0` | Priority units added per second spent queued. This is what stops a steady stream of urgent requests starving everything else. |

### Priority and fairness

`PathAgent.new(humanoid, root, { priority = 10 })` lifts an agent's requests up
the queue — give it to bots that are reacting, and leave patrollers at the
default `0`. Selection is `priority + secondsWaited × ageBoost`, so a humble
request that has queued for two seconds outranks a fresh one two points more
important. Priority decides who goes *first*; aging guarantees everyone goes
*eventually*.

### A moved goal cancels its own computation

`SetGoal` cancels the in-flight request once the destination has moved more than
`repathThreshold` (default 8) from the goal that request is computing a path to —
the same drift the walk itself tolerates before it repaths. If the computation had
not started, it never runs at all; if it had, the result arrives flagged
`cancelled` and the agent discards it rather than walking to where the target used
to be. Calling `SetGoal` every tick with the *same* position — which the `Mover`
contract explicitly allows — cancels nothing, and neither does a target that
shuffles a few studs: a chaser keeps its place in the queue, gets its path, and the
walk's drift check takes over. (It used to cancel on *any* move, so a chaser
re-queued at the back every tick, lost the age that protects it from starvation,
and under load never got a path.) `Stop` and `Destroy` always cancel.

### Every request is answered exactly once

`onComplete` fires once per request: with the result, or flagged `cancelled`. That
includes a request cancelled before it started and one dropped by `reset` — those
are answered on the next resumption cycle (`task.defer`), never from inside
`cancel`, because the canceller is often the code the answer resumes. A request
cancelled while queued used to be dropped silently, and a `PathAgent` suspended on
it was never resumed: an agent whose goal moved while the broker was saturated
froze for good, still reporting `Computing` or `Moving`.
(`Tests/tests/test-pathfinding-broker.luau` covers both.)

### Idle agents cost nothing

An agent with no goal, or one parked at its destination, **suspends its loop
entirely** rather than polling; `SetGoal` and `Destroy` resume it. A hundred
posted guards used to share several hundred wakeups a second between them purely
to re-check that nothing had changed. Now they cost the scheduler nothing until
their goal moves.

### It works for YOUR pathfinder too

The broker takes a **closure**, not a `Path`. It never touches
`PathfindingService`, `Vector3` or `Enum` and has no idea what a path is — so a
voxel A*, a flow field, or a precomputed link graph queues through it exactly the
way `PathAgent` does, and gets the same concurrency cap, priority, aging and
cancellation:

```lua
local handle = Pathfinding.Paths.request({
    priority = 5,
    compute = function()               -- MAY YIELD; return nil to mean "no answer"
        return myVoxelAStar(start, destination)
    end,
    onComplete = function(result)
        -- result: { ok, cancelled, value, err, waited }
        if result.ok then
            walk(result.value)
        end
    end,
})
handle:cancel()   -- safe any time, idempotent
```

This is the same rule the rest of the suite follows — the world enters through a
function you write — and it is why this module is pure enough to test headlessly
with no Roblox stand-ins at all.

> **If your closure captures single-result state, keep one request in flight.**
> A Roblox `Path` holds the result of its last computation, so two concurrent
> requests against the same one would clobber each other. `PathAgent` guarantees
> this by suspending until its result arrives; do the same if your pathfinder has
> the same property.

### What it deliberately does not do

No caching or coalescing of similar requests. A cache would need invalidating
whenever the map changes, and a stale entry sends a bot confidently through a
wall that was built after the path was computed — a much worse failure than
recomputing. Out of scope until profiling says otherwise.

---

## Routes

Not all movement is a pathfinding problem. Leading out of a spawn area the
navmesh can't route across, a patrol loop a designer laid out deliberately, a
scripted approach lane — for these the route *is* the answer, and asking
`PathfindingService` to rediscover it is both slower and worse, because it
smooths away the exact shape that was authored.

So a **`RouteFollower`** walks authored waypoints with raw `MoveTo`: no navmesh,
no path computes, ever.

```lua
Routes.load(container?)  -> { [name]: { Vector3 } }   -- default workspace.BotRoutes
Routes.get(name)         -> { Vector3 }?
Routes.names()           -> { string }                -- sorted, for debug dumps
Routes.fromFolder(folder) -> { Vector3 }              -- one folder, no registry

Routes.follower(humanoid, rootPart, options?) -> RouteFollower
    follower:SetRoute(positions | name | nil)
    follower:GetStatus()  -> MoverStatus
    follower:Progress()   -> (index, length)
    follower:Stop() / follower:Destroy()
```

### Authoring

Routes are folders of `BasePart` markers under one container, named in walk
order. Zero-pad the names so the lexical sort matches intent:

```
workspace.BotRoutes
  SpawnExit     -> 01, 02, 03
  PatrolNorth   -> 01, 02, 03, 04
```

`Routes.load()` reads that container once into a name → positions registry, so
`Routes.get("PatrolNorth")` afterwards is a table lookup and every bot spawned
shares one copy of the list. Call it again after streaming in new route folders;
it replaces the registry rather than merging. Folders with no parts are skipped.

### It is not a Mover — it's a second capability

A `Mover` answers *"go to this position"*. A follower answers *"walk this
list"*. Neither substitutes for the other, so give them separate body slots:

```lua
body = {
    mover = Pathfinding.PathAgent.new(humanoid, root),     -- free pathing
    route = Pathfinding.Routes.follower(humanoid, root),   -- authored movement
}
```

A follower does report the **same status vocabulary** as a `Mover`
(`Idle` / `Moving` / `Arrived` / `Stuck`), so driving code polls either one
identically — an action maps `Arrived` → `Success` and `Stuck` → `Failure`
exactly as it would for a `PathAgent`:

```lua
local LeaveSpawn = Bots.Action.new({
    name = "LeaveSpawn",
    requires = { "route" },
    enter = function(bot)
        bot.body.route:SetRoute("SpawnExit")
    end,
    update = function(bot)
        local status = bot.body.route:GetStatus()
        if status == "Arrived" then
            return "Success"            -- out of spawn; later actions use body.mover
        elseif status == "Stuck" or status == "Idle" then
            return "Failure"
        end
        return "Running"
    end,
    exit = function(bot)
        bot.body.route:Stop()
    end,
})
```

That is the canonical pattern: walk a route out of spawn, then hand off to the
mover for everything after.

### Traversal modes

| `mode` | Behaviour | `Arrived` |
|---|---|---|
| `"once"` (default) | Walks to the last waypoint and stops. | yes, at the end |
| `"loop"` | Wraps back to the first waypoint. | never |
| `"pingPong"` | Reverses at each end, without re-walking the endpoint. | never |

`startAtNearest = true` enters the route at the closest waypoint instead of the
first — what you want for a bot joining a patrol mid-lap rather than walking back
to the start.

| Option | Default | Meaning |
|---|---|---|
| `mode` | `"once"` | Traversal mode, above. |
| `waypointReached` | `4` | Distance that counts a waypoint reached. |
| `waypointTimeout` | `1.5` | No-progress seconds before reporting `Stuck`. |
| `stuckProgress` | `2` | Studs moved that still counts as progressing. |
| `startAtNearest` | `false` | Enter at the closest waypoint. |

### The trade

Being navmesh-free cuts both ways. Nothing recovers a follower that wedges on
geometry the author didn't anticipate — there is no path to recompute and no
finer resolution to fall back to. A stall is reported as `Stuck` and the decision
layer picks something else. That is the price of exact authored movement, and
it's why routes suit *deliberate* paths rather than general navigation.

## Planned improvements (TBD)

**Status: proposed, not implemented in this library.** Recorded 2026-09-21 after
comparing this library with the CastleWars project copy. The sections above
continue to describe the current API. Names and defaults for new options below
are still to be decided; they must not be treated as available API.

The goal is to bring over useful movement fixes without replacing this library
with the game copy. In particular, preserve `Paths` (bounded concurrency,
priority, aging and cancellation), sleeping idle/arrived `PathAgent` instances,
and the existing route registry and follower modes. The CastleWars copy does
not contain all of those features. Adaptive waypoint spacing, cost options and
request cancellation already exist here and should be extended, not reintroduced.

### 1. Do not advance past a stalled waypoint

**Problem:** `PathAgent` currently assigns `stalled = reduceSpacing()`. At the
minimum spacing, that returns false even though movement has stalled. The outer
waypoint loop can then advance past a point the agent never reached.

**Planned change:** separate "movement stalled" from "spacing was reduced".
Always stop advancing the current path after a stall. Recompute with finer
spacing when possible; otherwise report `Stuck` and apply the chosen recovery
policy. Preserve the existing sticky status semantics.

**Expected benefit:** agents do not attempt later segments through a corner or
obstacle that blocked the current segment.

**Acceptance:** a blocked waypoint at minimum spacing is never skipped; coarse
stalls still refine the route; real progress or a new goal clears `Stuck`.

### 2. Make arrival checks aware of floor and character height

**Problem:** root-to-waypoint 3D distance treats the normal height of a character
above a floor waypoint as remaining travel distance. Large rigs or tight arrival
radii can consequently fail to arrive.

**Planned change:** use horizontal distance plus a separate, bounded vertical
check, accounting for the rig's root-to-ground offset. Support both floor
waypoints and root-position destinations. Make tolerances appropriate for
multiple rig sizes rather than copying CastleWars constants. Use a consistent
check for following waypoints and reporting final arrival.

**Expected benefit:** fewer false stalls without declaring arrival on an upper
or lower floor simply because X/Z coordinates match.

**Acceptance:** cover floor/root targets, multiple rig sizes, ramps and stacked
floors. Document any unavoidable ambiguity in targets provided only as Vector3.

### 3. Validate direct fallback movement

**Problem:** after a failed path computation, a destination inside
`straightLineMax` currently permits a direct MoveTo based on distance alone.
Nearby destinations can still lie across a gap or behind a wall.

**Planned change:** require a verified walkable segment before this fallback.
Check floor support across the agent's width, slope/step limits, obstruction
clearance and prohibited terrain. If the segment is unsafe, hold position and
report `Unreachable`; update the status documentation accordingly. A failed
path by itself must not trigger a retreat along the previous journey.

**Expected benefit:** fewer avoidable falls and attempts to walk through nearby
obstacles when the navmesh cannot produce a route.

**Acceptance:** allow a supported unobstructed short walk; reject gaps, edges,
walls, forbidden ground and unsafe vertical transitions. Revalidate when moving
geometry invalidates a previously safe segment.

### 4. Add optional checked lookahead and continuous handoff

**Problem:** walking every small waypoint can cause braking and zigzag movement
on otherwise open ground. Very coarse waypoint spacing can hide important
corners instead.

**Planned change:** retain a sufficiently detailed computed path, but aim at a
farther waypoint when the entire shortcut is verified walkable. If the farthest
candidate is blocked, try a nearer candidate. Hand off to the next clear segment
before braking at an intermediate point. Keep lookahead and handoff configurable
and allow smoothing to be disabled.

Preserve jump/custom traversal actions and any labels or mandatory transitions
that consumers rely on. Never bypass required traversal merely because the
endpoint is visible. Do not silently replace the current spacing defaults with
the game's values.

**Expected benefit:** longer, smoother runs while retaining the detail needed
around corners and narrow approaches.

**Acceptance:** test open-ground bends, walls, ledges, intermediate transitions,
shorter valid shortcuts, disabled smoothing and uninterrupted long movement.

### 5. Replan on relevant events without interrupting healthy travel

**Problem:** the periodic repath timer interrupts valid routes, and the follower
currently does not use `Path.Blocked` to react directly to a new obstruction.

**Planned change:** listen for blockages affecting the remaining route, ignoring
blocks behind the agent. Replan for meaningful goal drift, blockage and lack of
progress. Provide an explicit policy for periodic refresh; where refresh is
requested, avoid unnecessary pauses while a still-valid route is followed.
All computations must continue through `Paths`.

Preserve compatibility with the documented `repathInterval`. The project copy
repurposes it as a failed-path retry delay; do not port that semantic change.
Use separate retry/refresh options or a documented migration if needed. Bound
failed-path retries so unreachable goals cannot flood the broker.

**Acceptance:** obstacles ahead trigger replanning, obstacles behind do not,
healthy paths remain continuous, and goal changes/cancellation work under a
saturated request queue. Disconnect path events when their path is replaced or
the agent is destroyed.

### 6. Strengthen progress tracking and movement lifecycle

**Planned changes:**

- Measure meaningful progress toward the current target, rather than counting
  any displacement as success. Sideways shuffling must not indefinitely hide a
  stall. Retain tunable thresholds suitable for slow agents and different rigs.
- Refresh long-running MoveTo commands before they expire, without changing the
  target or restarting the progress timer merely because a command was issued.
- Extend the existing broker cancellation with journey/generation checks where
  needed across yielded work, diagnostic probes and any future recovery loop.
  Stop/restart at the same destination must not reactivate old work.
- Ensure `SetGoal(nil)` stops owned movement, and stopping an already idle mover
  does not overwrite another controller's MoveTo. Apply the same principle to
  route followers and document the caller's responsibility to hand off control.
- Clean up replaced Path objects, connections and work on destruction.

**Acceptance:** test stop during compute, rapid stop/start, replacement goals,
destruction, long segments, sideways movement, and handoff between a route
follower and a path agent. Preserve the original broker and idle sleep behavior.

### 7. Adapt useful authored-route improvements

Extend the existing `Routes.follower` rather than replacing it with CastleWars'
`RouteWalker`, which depends on game configuration and has a different API.

Optional checked lookahead can combine safe flat segments. Once a shortcut is
selected, advance route progress consistently so a bypassed waypoint cannot
pull the agent backward. Keep exact waypoint traversal available, preserve
height-changing/mandatory nodes, and consider explicit per-node arrival radii
or mandatory flags for tight approaches. New option names remain TBD.

Preserve registry lookup, `Progress`, `startAtNearest`, and `once`, `loop`, and
`pingPong` behavior. Any pause/resume extension must be explicit: do not silently
change the current restart semantics of `SetRoute` or reset semantics of `Stop`.

**Acceptance:** cover mandatory corners/approaches, safe shortcuts, monotonic
progress within each traversal direction, loop boundaries, ping-pong reversal,
route replacement and movement ownership. Exact mode must remain exact.

### 8. Optional bounded recovery; preserve jump compatibility

**Recovery:** consider walking back to a previously observed, still-safe point
only after a confirmed physical stall and finer-path attempts. Keep it opt-in
and disabled by default. Limit attempts, time and distance; cancel immediately
on stop, new goal or destruction. Reject history across disconnected ground,
jumps or drops. Do not recover merely because a destination returns `NoPath`.
An optional recovery method must not become a required member of every custom
`Mover`. Verify that recovery cannot create repeated forward/backward loops.

**Jumping:** `agentCanJump` already exists. Keep its current default of true for
compatibility. Add a defensive check that refuses an unexpected jump waypoint
when false. CastleWars' default of no jumping belongs in game configuration.
This option alone cannot make a disconnected no-jump navmesh traversable or
prevent jumps commanded by some other controller.

### Requirements before porting the geometry helpers

The project `TravelSafety` and `PathSmoothing` modules are starting points, not
ready-to-copy general-purpose guarantees:

- Check full agent height as well as width; the current shortcut helper probes
  near root height and does not consume `agentHeight` for full clearance.
- Preserve terrain/modifier intent. The project checks some infinite-cost ground
  but does not account for finite weighted preferences, all modifier volumes,
  or all traversal labels. Smoothing must not undo the route's cost policy.
  A conservative option is to disable shortcuts when that policy cannot be
  evaluated reliably.
- Respect collision groups and make handling of transient humanoids explicit.
  Validate rig offsets, slope/step tolerances, moving obstacles and stacked
  surfaces beyond the particular maps used by CastleWars.
- Profile raycast work with many moving agents. Limit candidate scans and probe
  budgets; shortcuts must not trade smoother motion for excessive frame cost.
  Any caching needs invalidation appropriate to dynamic geometry.

### Implementation scope and validation plan

Likely scope: focused changes to `src/PathAgent.luau`, new travel-check and
smoothing helpers, optional additions to `src/Routes.luau`, and API/type/export
updates only where needed. Keep `src/Paths.luau` as the broker. Add regression
tests and update the implemented API documentation as each feature ships.

Suggested order: fix stalled-waypoint/lifecycle bugs first; generalize arrival
and travel checks; add optional smoothing and replanning policy; then assess
route smoothing and opt-in recovery separately.

CastleWars references (relative to that project's root):

- `src/ServerStorage/Libraries/Pathfinding/PathAgent.luau`
- `src/ServerStorage/Libraries/Pathfinding/TravelSafety.luau`
- `src/ServerStorage/Libraries/Pathfinding/PathSmoothing.luau`
- `src/server/Systems/Bots/RouteWalker.luau`
- `lune/test-navigation.luau`

The project's 41 navigation regression checks passed during the 2026-09-21
review. They test the project implementation, not this proposed integration.
Extract the reusable cases and add broker, existing API, rig-size, cost-policy,
route-mode and multi-agent performance coverage. Run live movement tests on
representative maps before choosing new defaults or marking this work complete.

**Excluded:** CastleWars castle/tower routes, target priorities, map ramps and
collision helpers, bot rig ownership, respawn physics and game-specific tuning.
Those changes should remain in the game. No library change can guarantee correct
traversal over disconnected or incorrectly authored navigation geometry.
