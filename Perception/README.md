# Perception

The sensing layer every game AI rewrites by hand, packaged: **vision with
awareness-over-time** (FOV cone + range + line-of-sight, filling toward
detection while a target stays visible and fading when lost), **hearing** as
an occlusion-aware stimulus bus (Roblox has no "sound happened" event for AI —
this is it), and **raycast budgeting** so a fleet of watchers degrades to
slower reactions instead of frame spikes.

Detection is deliberately **not binary**. Awareness accumulates — faster when
the target is close and centered, slower at the edges of vision — through the
classic ladder `None → Suspicious → Detected`. That accumulation is what makes
AI feel fair to sneak past and scary to stand in front of; instant binary
detection feels terrible and every good stealth/combat AI avoids it.

The package depends on nothing, including the sibling [`Bots`](../Bots/)
library — it integrates through Bots' *own* contracts (sensors, facts,
`stimulate`), with the exact wiring shown below. The core does vector math on
positions but never constructs them, and takes every world query as an
injectable raycast function (same shape as
[`TacticalQuery`](../TacticalQuery/)'s `probes.raycast` — one game function
can serve both).

**Reading the source?** Start with [`Types.luau`](src/Types.luau)
(`TargetPerception` / `VisionReport` are the mental model), then
[`Vision.luau`](src/Vision.luau) — its header documents the four-stage
pipeline (cull → prioritized budgeted rays → awareness integration → report)
that is the library's core idea: **detection is awareness accumulating over
time, not a binary raycast.** `Hearing`, `Budget`, and `Raycaster` are small
and self-contained after that.

---

## Architecture

| Module | Role |
|---|---|
| `Vision.luau` | `Vision.new(config)` → sensor. Each `update()`: cone/range cull → prioritized, budgeted LOS raycasts → awareness integration → report sorted by awareness. `forget()` resets (respawns, round ends). |
| `Hearing.luau` | `Hearing.new(config?)` → bus. `emit(kind, position, radius, data?, audience?)` reaches registered listeners; geometry occlusion shrinks the effective radius (muffled, not silenced). `audience` and per-listener `kinds` reject ears before any ray; occlusion rays are skipped where they cannot change audibility. Listener errors are isolated. |
| `Budget.luau` | `Budget.new(perSecond, burst?)` — token bucket shared by any number of Vision sensors, Hearing buses, and TacticalQuery probes. `stats()` counts grants and refusals. Dry bucket ⇒ sensors freeze the targets they couldn't cast for (awareness holds, flagged `stale`) and spend what rays remain on whoever has gone unsampled longest. |
| `Raycaster.luau` | The default `workspace:Raycast` wrapper (lazily constructed). Inject your own `RaycastFn` for custom worlds. |
| `Types.luau` | Every public type. Zero dependencies. |

---

## Quick start: a guard that sees and hears (full Bots wiring)

```lua
local Bots = require(path.to.Bots)
local Perception = require(path.to.Perception)

-- One shared ray allowance for the whole fleet.
local rayBudget = Perception.Budget.new(120)          -- 120 rays/s across all guards

-- SIGHT wants an EXCLUDE filter: characters are ignored, everything else blocks.
local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.FilterDescendantsInstances = { workspace.Characters, workspace.Bots }

-- SOUND wants the opposite: only real walls muffle. Cheaper, and it fails open.
local hearing = Perception.Hearing.new({
    occluders = { workspace.Walls },
    budget = rayBudget,
})
-- Anywhere in game code, at the noisy event:
--   hearing:emit("gunshot", muzzle.Position, 80, { shooter = player })

local function makeGuard(rig)
    local head: BasePart = rig.Head
    local bot
    local vision = Perception.Vision.new({
        eye = function()
            return head.Position, head.CFrame.LookVector
        end,
        targets = function()
            local out = {}
            for _, player in game.Players:GetPlayers() do
                local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
                if root then
                    table.insert(out, { ref = player, position = root.Position })
                end
            end
            return out
        end,
        fov = 110,
        range = 60,
        awarenessTime = 0.8,
        params = sightParams,
        budget = rayBudget,
    })

    bot = Bots.Bot.new({
        body = { model = rig, rootPart = rig.HumanoidRootPart, vision = vision },
        goals = { Attack, Investigate, Patrol },     -- yours
        sensors = {
            -- Vision hosted in a plain Bots sensor: report to the board,
            -- perception memory as decaying facts.
            vision = { interval = 0.15, read = function(bot, bb)
                local report = vision:update()
                local best = report.best
                if best and best.position then
                    bb:setFact("lastSeenPos", best.position, 8, best.awareness)
                end
                -- PUBLISH, THEN REACT. `stimulate` re-plans this bot on the spot
                -- and the goals it runs read the board — so the board has to hold
                -- the NEW report before we stimulate. Returning the report stores
                -- it too, but not until after this function returns, which is one
                -- tick too late for the plan step below.
                bb:set("vision", report)
                for _, event in report.events do
                    if event.to == "Detected" then
                        bot:stimulate({ spotted = event.ref })  -- react NOW, on fresh data
                    end
                end
                return report
            end },
        },
    })

    local disconnect = hearing:listen({
        ref = bot,                                   -- addressable by an array audience
        kinds = { gunshot = true, explosion = true }, -- footsteps cost this ear nothing
        position = function()
            return rig.HumanoidRootPart.Position
        end,
        onHeard = function(sound)
            bot:stimulate({ heardSound = sound })    -- even a slow-ticking bot reacts instantly
        end,
    })
    -- On despawn: disconnect() (or hearing:forget(bot)) and vision:forget().
    return bot
end
```

Goals then read it all through the normal blackboard:

```lua
local Investigate = Bots.Goal.new({
    name = "Investigate",
    canRun = function(bot)
        local report = bot:get("vision")
        local seesSomeone = report and report.best and report.best.visible
        return not seesSomeone and (bot:getFact("lastSeenPos") ~= nil or bot:get("heardSound") ~= nil)
    end,
    score = function(bot)
        local _, confidence = bot:getFact("lastSeenPos")
        return 0.4 + 0.3 * (confidence or 0)
    end,
    actions = { GoToLastKnown, LookAround },        -- yours
    effects = function(bot)
        bot:set("heardSound", nil)
    end,
})
```

> **Set your raycast filters — plural.** Vision defaults to excluding nothing, so
> LOS rays hit character bodies and a target's own limbs read as walls (never
> seen). Pass `params` excluding character/bot folders. Hearing wants the
> opposite polarity — `occluders` lists what muffles — so the two subsystems take
> separate filters rather than sharing one.

---

## Vision

```lua
Perception.Vision.new({
    eye = () -> (position, facing),      -- REQUIRED: eye position + unit look direction
    targets = () -> { { ref, position } }, -- REQUIRED: who to look for, positions fresh per call
    fov = 110,                           -- full cone angle, degrees
    range = 60,
    awarenessTime = 1,                   -- seconds to fully detect a point-blank centered target
    decayTime = 4,                       -- seconds for full awareness to fade when unseen
    maxFillStep = awarenessTime * 0.5,   -- most awareness one sighting may credit
    maxSampleAge = awarenessTime,        -- unsampled this long ⇒ jumps the ray queue
    suspicion = 0.35,                    -- awareness threshold for "Suspicious"
    strength = (distFrac, centerness) -> number, -- fill-rate curve override
    raycast = RaycastFn?, params = RaycastParams?, budget = Budget?,
    onStatus = (ref, from, to) -> (),    -- edge callback for hosts that publish no report
}) -> vision

vision:update(now?) -> {
    targets = { { ref, status, awareness, visible, strength, stale, position, seenAt } }, -- awareness desc
    events = { { ref, from, to } },       -- this update's status edges (empty when none)
    best = targets[1]?,
    sampled = number,                     -- in-cone targets that got a ray
    frozen = number,                      -- in-cone targets the budget refused
}
vision:forget(ref?)                      -- drop one target's awareness, or all
```

Semantics worth knowing:

- **Awareness** fills by `min(dt, maxFillStep) × strength / awarenessTime` while
  visible, falls by `dt / decayTime` when not. `strength` combines distance and
  how centered the target is — a target at the edge of your range/cone takes
  several times longer to detect than one in your face.
- **One sighting is capped evidence.** `visible` is a point sample (one ray, this
  instant) but `dt` is the whole interval since the last update, so an
  uncapped fill would let a bot on `tickInterval = 1.5` go cold → `Detected` off
  a single frame in which the target was in the open. `maxFillStep` (default
  `awarenessTime × 0.5`) caps what one sample can credit, so detection needs
  corroboration across updates. Decay is *not* capped — conservative about
  gaining awareness, generous about losing it. Set it to `awarenessTime` to
  restore pre-cap behaviour for full-strength targets, or `math.huge` to disable
  the cap entirely.
- **`Detected` is sticky**: once reached it holds until awareness decays below
  the suspicion threshold — an enemy doesn't flicker out of "detected" by
  strafing through cover for half a second.
- **`position` in the report is the last position actually *seen*** — while
  visible it tracks the target; after losing sight it freezes. Written as a
  ttl'd fact (as in the wiring above), it *is* the "search where they were"
  memory.
- **Budget starvation freezes**, it does not guess. A target that got no ray this
  update has its awareness *held* — no fill, no decay — and is flagged
  `stale = true` in the report, with `visible` / `strength` describing the last
  update that did sample it. The alternative (integrating off the carried
  visibility) extrapolates, and extrapolation is wrong in both directions: it
  fills a target who has since ducked behind cover all the way to `Detected`, and
  decays one who just stepped into plain view. Holding is the only honest answer
  to "I didn't look".
- **Rays go to the longest-unsampled target first**, then by awareness, then by
  nearness. `maxSampleAge` (default `awarenessTime`) is how long an in-cone target
  may go unsampled before it jumps the queue. Awareness-ordering *alone* would
  spend every ray of a dry budget re-confirming the targets a bot already tracks,
  leaving it structurally blind to a new one walking into its cone.
- Sizing: each update spends at most one ray per target inside the cone, so
  `bots × targets × updatesPerSecond` is the worst case — budget for the fraction
  you're willing to keep fresh. Note that a realistic budget is dry much of the
  time under load (30 guards × 5 updates/s × 1 candidate = 150 rays/s against the
  `Budget.new(120)` above), so freeze-and-age is the *normal* path in a busy
  fight, not an edge case.
- **Publish the report before reacting to `report.events`.** Reaction means
  re-planning, and a plan step reads the *board* — so if you `stimulate` before
  the new report is stored, the goals that run see the previous update, in which
  the target wasn't detected yet. That's a silently wrong plan on the exact frame
  the stimulus existed to sharpen. `bb:set("vision", report)` then loop
  `report.events`, as the wiring above does. `onStatus` fires from inside
  `update` — before any host can publish — so it suits hosts that keep no board;
  it is the wrong place for a `stimulate`.
- Vision never yields, and `update` computes `dt` internally from its own
  last call — host it in a throttled Bots sensor (`interval = 0.15` above)
  and reaction latency stays crisp because *detection edges* drive `stimulate`.

## Hearing

```lua
local bus = Perception.Hearing.new({
    occluders = { workspace.Walls },     -- ONLY these muffle (Include filter)
    params = RaycastParams?,             -- ...or bring your own filter; not both
    raycast = RaycastFn?,                -- ...or replace the probe entirely
    occludedScale = 0.5,                 -- muffled radius multiplier (1 = no occlusion rays)
    budget = Budget?,                    -- optional shared ray allowance
    preciseOcclusion = false,            -- force rays that can't change audibility
})

bus:emit(kind, position, radius, data?, audience?)   -- at the noisy event, one line
local disconnect = bus:listen({ position = fn, onHeard = fn, acuity?, ref?, kinds? })
bus:forget(ref)                                     -- drop every ear that ref registered
bus:count()
```

A sound reaches a listener when
`distance ≤ radius × acuity × (occluded ? occludedScale : 1)` — occlusion
(default scale 0.5) *muffles* through walls rather than hard-blocking. The
`Sound` delivered to `onHeard` carries
`kind / position / radius / distance / occluded / data`.

Emit sounds *from game code where they happen* (weapon fired, door slammed,
glass broke) — that one-line convention is what makes every future AI able to
hear.

### What a sound costs

A fleet-wide sound touches every ear, so the per-listener path is a funnel
ordered cheapest-rejection-first. Each stage below can end it:

| | Stage | Cost |
|---|---|---|
| 1 | **Audience** — `emit`'s optional 5th argument | free; an *array* audience doesn't even walk the registry |
| 2 | **Kinds** — the listener's `kinds` whitelist | one table lookup |
| 3 | **Range** — out of earshot even unoccluded | pure math, no ray |
| 4 | **Band** — the sound is audible whether occluded or not | pure math, **no ray** |
| 5 | **Budget** — nothing left in the bucket | no ray; treated as *unoccluded* |
| 6 | **Ray** — one raycast, sound position → that ear | one ray |

Stage 4 is the one worth understanding. The occlusion ray can only change
*audibility* between the muffled radius and the full radius — a listener closer
than `radius × acuity × occludedScale` hears the sound either way, so no ray is
cast for them. For a radius-80 gunshot at the default scale that's everyone
inside 40 studs, which in a firefight is most of the fleet. Their sound reports
`occluded = false`, meaning *clear, or close enough that we didn't check*
(`occluded = true` always means verified blocked). Set `preciseOcclusion = true`
if you need the flag exact everywhere.

Stage 5 is deliberately generous: **a refused ray means the listener hears it.**
Going deaf under load is far worse than occasionally hearing through a wall, and
reacting to events that can't wait is the entire point of this bus. Compare
Vision, which *holds* its awareness when starved — the two subsystems answer
"I couldn't afford to look" differently on purpose.

### Narrowing the audience

`emit`'s fifth argument decides who is even considered, before range or rays:

```lua
-- Teammates don't get alerted by their own gunfire — and cost no rays.
hearing:emit("gunshot", muzzle.Position, 80, { shooter = player }, function(ref)
    return ref ~= nil and ref.team ~= shooterTeam
end)

-- An array addresses ears directly: cost is O(#audience), not O(#listeners).
hearing:emit("radioOrder", commander.Position, math.huge, order, squadMembers)
```

A **predicate** receives each listener's `ref` (`nil` for listeners that didn't
declare one) and filters the whole registry. An **array of refs** is stronger
where you have the list: `emit` walks the audience and looks each ref up, so a
6-member squad order costs six lookups even with 200 ears registered. Refs with
no registered listener are skipped silently.

Per-listener `kinds` is the other half — an ear that only cares about gunshots
pays nothing at all for footstep spam:

```lua
hearing:listen({
    ref = bot,                              -- addressable by an array audience
    kinds = { gunshot = true, explosion = true },
    position = function() return rig.Head.Position end,
    onHeard = function(sound) bot:stimulate({ heardSound = sound }) end,
})
```

### Cleaning up

Listeners are held **strongly** — a bus has to keep an inline
`bus:listen({ ... })` alive, so weak keys would collect an ear whose caller never
stored a reference. That means a despawning bot must be unregistered, or its
listener (and the `ref` it names, usually the bot itself) stays reachable
forever. Either hold the disconnect closure, or use the ref:

```lua
hearing:forget(bot)     -- drops every ear registered under that ref
```

### Occluders

`occluders = { workspace.Walls, workspace.Buildings }` builds an **Include**
`RaycastParams`, so only listed geometry muffles. That's much cheaper per ray
than excluding everything else, and it states the intent directly.

> **It fails open.** Anything not listed is acoustically transparent, so a
> building you forget to list won't muffle anything. That's the opposite polarity
> to what Vision wants — Vision *excludes* characters so all remaining geometry
> blocks sight. **Don't share one `RaycastParams` between the two** if you use
> `occluders`; give each subsystem its own filter.

## Budget

```lua
local budget = Perception.Budget.new(perSecond, burst?)  -- starts full
budget:take(count?, now?) -> boolean                     -- spend, or refuse whole
budget:available(now?) -> number
budget:stats(now?) -> { granted, refused, available }
```

Token bucket, continuous refill, injectable clock. Share one across every Vision
sensor and Hearing bus in the fleet — and across the sibling `TacticalQuery`,
whose `Probes` accepts the same shape, so one bucket can cap everything a fleet
spends looking at the world.

A dry bucket costs *reaction speed*, never correctness: sensors freeze the
targets they couldn't sample (see the Vision semantics above) and spend the rays
they do have on whoever has gone unsampled longest. Raising `perSecond` makes
bots quicker to notice things; it never changes what they can conclude.

### Watching starvation

Since a dry bucket now HOLDS awareness rather than degrading it quietly, "how
starved was the fleet" is a gameplay question, not just a performance one --
which is why `stats()` counts **refusals**. Sampling `available()` cannot show
them: it reports the bucket at one instant, and the thing you need to know is how
often a sensor asked and was told no.

```lua
local s = rayBudget:stats()
print(("ray refusal rate: %.0f%%"):format(100 * s.refused / math.max(1, s.granted + s.refused)))
```

Each `VisionReport` carries the same story per update: `sampled` (targets that
got a ray) and `frozen` (targets the budget refused, whose entries are flagged
`stale`). When a playtester says the guards felt oblivious, these separate the
two candidate causes -- **starvation** versus **`awarenessTime` tuning** -- which
otherwise produce an identical symptom.

---

## Performance

### Share one target list across the fleet

`targets()` runs on **every update of every sensor**, and the obvious
implementation — walk `Players:GetPlayers()`, `FindFirstChild` a couple of parts —
is usually the most expensive thing in the layer. It is also *not* metered by the
raycast budget. Build the list once for the whole fleet instead:

```lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local livingPlayers: { Perception.Target } = {}

RunService.PostSimulation:Connect(function()
    table.clear(livingPlayers)
    for _, player in Players:GetPlayers() do
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if root and humanoid and humanoid.Health > 0 then
            table.insert(livingPlayers, { ref = player, position = root.Position })
        end
    end
end)

-- ...and every guard's sensor just hands back the shared table:
targets = function()
    return livingPlayers
end
```

This is safe because **Vision never mutates what `targets()` returns** — it reads
`ref` and `position` and nothing else. The cost goes from
`O(bots × targets × updateRate)` to `O(targets × rebuildRate)`: 50 guards at 5 Hz
means ~250 list walks per second collapsing to 60, and the rebuild doesn't need to
be per-frame either — 10–20 Hz is plenty for a target list, for another 3–6×.

The trade is that positions are up to one rebuild stale (~16 ms at
`PostSimulation`), which is far below the resolution any of this operates at.

### On batching raycasts

There's no batched raycast API in Roblox — `Raycast` / `Blockcast` / `Spherecast`
are all one query per call, so there is nothing for Vision to batch into. It also
wouldn't help at this scale: one update casts at most one ray per in-cone
candidate, typically a handful. **If you want more rays, raise `perSecond` and
measure** — a raycast is on the order of microseconds and the default 120/s sits
nowhere near any engine limit. With freeze + aging, that dial only buys reaction
speed; it can't change what a bot concludes.

Genuine ray throughput (Parallel Luau Actors, a cached visibility grid, an
analytic occlusion test for a voxel world) belongs behind the injected `raycast`
function — see [Custom worlds](#custom-worlds). That seam exists precisely so the
package never has to know.

### Steady-state allocation

Each `update` allocates a handful of tables (candidates, the report, one entry per
perceived target). That's deliberate: the report is a safe immutable snapshot a
consumer can hold onto and stuff into a blackboard. Reusable buffers would cut the
garbage and take that guarantee away — worth it only if a profile says so.

---

## Custom worlds

Inject `raycast` (shape: `(origin, direction) -> hit?`, ray exactly
`|direction|` long, nil = clear) into Vision and Hearing and no other part of
the package cares what a "wall" is. It is the same contract as
TacticalQuery's `probes.raycast`, so a voxel/grid game writes one occlusion
function and feeds all three AI packages with it.
