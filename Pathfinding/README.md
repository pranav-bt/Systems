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

---

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

`SetGoal` cancels the in-flight request whenever the destination actually moves.
If the computation had not started, it never runs at all; if it had, the result
arrives flagged `cancelled` and the agent discards it rather than walking to
where the target used to be. Calling `SetGoal` every tick with the *same*
position — which the `Mover` contract explicitly allows — cancels nothing.

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
