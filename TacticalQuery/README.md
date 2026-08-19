# TacticalQuery

An EQS-style **tactical position-query** system for Roblox: *"find cover from
the threat"*, *"find a flanking spot"*, *"find a position near my allies with
line of sight"*. You define a query once — a candidate **generator** plus
weighted **tests** — and run it from anywhere with per-run context. The engine
generates points, scores them through the tests in cost order (pure math →
raycasts → reachability), and returns the winner with a per-test score
breakdown.

Everything world-shaped goes through one injectable **`Probes`** table
(raycast / snapToGround / isReachable). The default probes use
`workspace:Raycast`; a game with a different world — voxel grids, player-built
bases — swaps the probes (and possibly a generator) and keeps the engine,
tests, weighting, budgeting, and debugging unchanged.

The package depends on nothing, including the sibling
[`Bots`](../Bots/)/[`Pathfinding`](../Pathfinding/) libraries — decision
systems call `query:run` from their own behaviour code.

**Reading the source?** Start with [`Types.luau`](src/Types.luau) — the
`Probes` / `Generator` / `Test` contracts are the whole design — then
[`Engine.luau`](src/Engine.luau), whose header documents the five-stage
pipeline (generate → cheap → ground → expensive → validate). The core idea:
**all world geometry enters through one injectable Probes table**; everything
else (`Query`, `Generators`, `Tests`, `Probes`) is builders around those
contracts.

---

## Architecture

| Module | Role |
|---|---|
| `Query.luau` | `Query.new(spec)` — validates a definition **where it is written** (Bots-style) and attaches `run`. `Query.setDefaultProbes` wires the package-wide default world. |
| `Engine.luau` | The pure pipeline: generate → cheap tests → ground the best `maxExpensive` → expensive tests → validate top-K. Every probe a run spends is bounded by those two numbers. Positions are opaque values; no Roblox APIs — fully testable outside Roblox. |
| `Generators.luau` | Candidate producers: `ring`, `grid` (ungrounded — the Engine snaps survivors), `tagged` (authored CollectionService points, cached per tag; pair with `snap = false`). Any bare `(context, probes) -> { points }` function also works. |
| `Tests.luau` | Scoring criteria: `distance`, `direction`, `spacing` (cheap math), `hidden`, `exposed` (raycast LOS), `reachable` (validate). Any table shaped like a Test works. |
| `Probes.luau` | The **only world surface**. `Probes.new(config?)` builds the Roblox defaults and takes an optional shared `budget`, charged one token per probe. `Probes.meter(probes, budget)` wraps a custom probes table the same way. |
| `Debug.luau` | `Debug.draw(name, info, winner?)` — renders the scored field in-world: every candidate graded by score, the winner, and the breakdown that produced it. Development tool. |
| `Curves.luau` | `linear` / `band` / `clamp01` ramps for writing custom test scores. |
| `Types.luau` | Every public type. Zero dependencies. |

---

## Quick start: take cover (from a Bots action)

```lua
local TQ = require(path.to.TacticalQuery)

-- Define ONCE, at module scope. Definitions reference CONTEXT KEYS, not
-- captured values, so one query serves every bot.
local FindCover = TQ.Query.new({
    name = "FindCover",
    generator = TQ.Generators.ring({ radii = { 8, 14, 20 }, perRing = 12 }),
    tests = {
        TQ.Tests.hidden({ from = "threatEye", weight = 3 }),   -- covered from the threat?
        TQ.Tests.distance({ to = "self", best = 6, worst = 25 }), -- prefer nearby spots
        TQ.Tests.reachable({}),                                 -- can I actually get there?
    },
})

-- Run per bot, per need — here inside a Bots action:
local TakeCover = Bots.Action.new({
    name = "TakeCover",
    requires = { "mover", "rootPart" },
    enter = function(bot)
        local threat = bot:get("nearestTarget")
        if not threat then
            return "Failure"
        end
        local spot = FindCover:run({
            self = bot.body.rootPart.Position,
            threatEye = threat.position + Vector3.new(0, 4, 0),
        })
        if not spot then
            return "Failure" -- no cover exists: let the goal fail over to something else
        end
        bot:set("coverSpot", spot.position)
        return "Running"
    end,
    update = function(bot)
        local mover = bot.body.mover
        mover:SetGoal(bot:get("coverSpot"))
        local status = mover:GetStatus()
        if status == "Arrived" then
            return "Success"
        end
        return if status == "Stuck" or status == "Unreachable" then "Failure" else "Running"
    end,
    exit = function(bot)
        bot.body.mover:Stop()
    end,
})
```

> **Set up your raycast filter.** The default probes exclude nothing, so LOS
> rays can hit character bodies — a target's own limbs read as "cover". Wire
> your exclusion list once at startup:
>
> ```lua
> local params = RaycastParams.new()
> params.FilterType = Enum.RaycastFilterType.Exclude
> params.FilterDescendantsInstances = { charactersFolder, botsFolder }
> TQ.Query.setDefaultProbes(TQ.Probes.new({ params = params }))
> ```

---

## How a run works

```
query:run(context, probes?)          -- probes default to the package-wide default
  1. GENERATE   generator(context, probes) -> candidate points (no probes)
  2. CHEAP      pure-math tests on EVERY candidate; nil rejects, numbers
                accumulate into a weighted average; survivors ranked
  3. GROUND     the best `maxExpensive` survivors are snapped to the floor,
                one probe each; those with no floor are dropped
  4. EXPENSIVE  raycast tests on that same set — every probe in a run is
                spent on promising points; survivors re-ranked
  5. VALIDATE   the priciest checks (reachability) on the top `topK`
                (default 3), best-first, until one passes ALL of them
-> Candidate?  { position, score, breakdown }   -- breakdown: test name -> raw score
-> RunInfo     { generated, scored, grounded, expensiveTested, validateTried,
                 budgetStarved?, candidates? }
```

- **Scoring**: each test returns `[0, 1]` (clamped) or `nil` to reject. A
  candidate's score is the **weighted average** of every test that ran on it —
  predictable and designer-tunable. A hard filter is just a test returning nil.
- **Budgets bound EVERY probe in a run.** `maxExpensive` caps grounding and
  raycast tests together; `topK` caps reachability. Sizing a run:

  ```
  probes = min(candidates, maxExpensive)          -- grounding (0 if snap = false)
         + min(candidates, maxExpensive) x raysPerExpensiveTest
         + topK x reachability cost
  ```

  Note `raysPerExpensiveTest` is per HEIGHT: `hidden({ heights = {1, 2.5, 4} })`
  is three probes per candidate, not one.

  A 169-candidate `grid` with one `hidden` test and `reachable` therefore costs
  ~16 + 16 + 3 probes, not 169 — candidate count drives cheap-test *math*, never
  probes. Grounding is what makes this true: it happens after the cheap tests, so
  the generator itself never probes.
- **`snap = false`** on a query skips grounding, for generators that already
  return floor positions -- `tagged`, or your own authored-point generator.
  Everything else should leave it on: cheap tests score against the generator raw
  Y, which is horizontal-only for `distance` / `direction` / `spacing`, but a
  *custom* cheap test that reads height would see the generator plane rather than
  the floor.
- **`run` never yields, and must not be made to.** If you swap in a yielding
  `isReachable` (see below), do **not** call the query from a Bots action hook:
  Bots hooks run inside the scheduler's drain, and a yield there lets the next
  frame start a second drain over the same registry. Bots refuses the re-entry
  and counts it in `Brain.stats().reentered`, so the bot simply stops thinking
  for that frame. Run a yielding reachability check from your own coroutine and
  hand the result to the bot through its blackboard.
- **Debugging**: the winner's `breakdown` answers "why this spot"; `RunInfo`
  answers "why no spot" — `generated 60 -> scored 0` means your cheap tests reject
  everything, `grounded 16 -> expensiveTested 0` means nothing had a floor, and
  `validateTried 3` with no winner means reachability is the killer.

### Budgeting a fleet

`maxExpensive` / `topK` bound *one run*. A shared `budget` bounds *all of them*:

```lua
local rayBudget = Perception.Budget.new(240)   -- the SAME object Vision uses
local probes = TacticalQuery.Probes.new({ params = sightParams, budget = rayBudget })
TacticalQuery.Query.setDefaultProbes(probes)
```

The type is declared structurally in both packages rather than shared by a
`require`, so one bucket can meter everything a fleet spends looking at the
world — vision rays, hearing occlusion, and position queries — under a single
per-second ceiling.

**A token is one probe.** Metering lives inside the probe functions, not around
a test stage, so a `hidden` with three heights costs three tokens and a default
`isReachable` costs one plus a ground sample per stride. That is what makes the
shared bucket honest: a token means the same thing here as it does in
Perception, where it has always been one raycast.

> **Sizing changed with that.** Charging per candidate-stage used to make one
> token stand for up to six rays, so a budget tuned against the old accounting
> will drain several times faster now. Raise `perSecond` accordingly — the number
> did not get worse, it got truthful.

Custom worlds keep their budgeting by wrapping their own probes:

```lua
local probes = TQ.Probes.meter(myVoxelProbes, sharedBudget)   -- returns a new table
```

`Probes.new` already meters; `Probes.meter` is for the injected probe tables the
package exists to support.

A refused probe makes the run **abstain**: `nil` result, `budgetStarved = true`
in the `RunInfo`. It does not return a spot picked from whatever happened to get
probed.

```lua
local spot, info = FindCover:run(context)
if not spot then
    if info.budgetStarved then
        return "Running"    -- ask again next step; this is not "there is no cover"
    end
    return "Failure"        -- genuinely nowhere to go
end
```

That is deliberately different from its sibling packages, because the cost of
being wrong differs. Vision **holds** stale awareness (a belief that stops
updating is better than one invented from no evidence). Hearing **delivers the
sound anyway** (a missed gunshot is a broken bot; hearing through a wall
occasionally is not). TacticalQuery **abstains**, because a position is committed
to for seconds — a bot that confidently walks to a badly-probed spot reads as bad
tactics long after the frame that caused it, and the caller is an action that can
simply return `Running` and ask again. Three subsystems, three right answers to
"I could not afford to look".

---

## Debugging: see the scored field

`RunInfo` tells you *how many* candidates survived each stage. It cannot tell you
*where they were* — and weight tuning is entirely a spatial question. So set
`debug = true` on the query and draw the run:

```lua
local FindCover = TQ.Query.new({
    name = "FindCover",
    debug = true,                       -- keep every scored candidate in RunInfo
    generator = TQ.Generators.ring({ radii = { 8, 14, 20 }, perRing = 12 }),
    tests = { --[[ ... ]] },
})

local spot, info = FindCover:run(context)
TQ.Debug.draw("FindCover", info, spot)  -- spheres in workspace.TacticalQueryDebug
TQ.Debug.clear("FindCover")             -- or clear() for all of them
```

Candidates render graded red (0.0) → amber → green (1.0), the winner larger and
white, each labelled with its score and per-test breakdown. Every query name gets
its own folder, so several can be visualized at once and a redraw only clears its
own.

> **Debugging is not free, in two places.** `debug = true` keeps a `Candidate`
> per retained point on every run, and `Debug.draw` then creates **two Instances
> per candidate** (a sphere and its BillboardGui) — a 36-candidate ring is over a
> hundred Instances, replicated to every client. Pass `labels = false` to halve
> it, and leave both off in production. `Debug.draw` on a `RunInfo` with no
> candidates warns and does nothing rather than drawing a misleading empty field.

**Why the markers are `CanQuery = false`.** A debug sphere is geometry, and the
tests being visualized are raycasts. Leave `CanQuery` on and every `hidden` ray
hits the marker drawn for its own candidate — so switching debugging on would
report the entire field as being in perfect cover, changing the scores you are
trying to read. `CanCollide` is off for the same reason `PathAgent`'s markers
are: collidable debug parts alter the navmesh that `isReachable` and the movers
depend on. Both are set for you; the reason is recorded here because anyone
writing their own visualizer will hit it.

Drawing happens on the server and replicates to every client, so gate it behind
your own studio/dev check — the package deliberately doesn't guess at that.

---

## The contracts

```lua
export type Probes = {
    raycast: (origin, direction) -> { position, instance }?, -- ray exactly |direction| long
    snapToGround: (point) -> point?,                          -- nil = no floor, candidate dies
    isReachable: ((from, to) -> boolean)?,                    -- powers Tests.reachable
    budget: Budget?,                                          -- optional ceiling on probe work
}
export type Budget = {                                        -- shape-compatible with Perception.Budget
    take: (count?, now?) -> boolean,
    available: (now?) -> number,
}
export type Generator = (context, probes) -> { point }
export type Test = {
    name: string,
    cost: "cheap" | "expensive" | "validate",
    weight: number?,                                          -- default 1
    score: (point, context, probes) -> number?,               -- [0,1] or nil = reject
}
```

Positions are **opaque to the engine** — it never constructs or does math on
them. Only the built-in Generators (Vector3 offsets), the LOS Tests (height
offsets), and the default Probes assume Roblox Vector3s.

### Swapping the world

A grid-world game (or one where "cover" means player-built walls) replaces the
probes and generator — the queries, tests, weighting, and budgets don't change:

```lua
local gridProbes: TQ.Probes = {
    raycast = function(origin, direction)          -- march the voxel grid instead
        return MyGrid:blockedBetween(origin, origin + direction)
    end,
    snapToGround = function(point)
        return MyGrid:topOfColumn(point)
    end,
    isReachable = function(from, to)
        return MyGrid:pathExists(from, to)
    end,
}
local spot = FindCover:run(context, gridProbes)    -- per run, or setDefaultProbes once
```

### Real pathfinding reachability

The default `isReachable` is a coarse, non-yielding heuristic (torso ray +
ground-continuity samples): fast, good on open maps, blind to real routing.
For complex maps you can swap in PathfindingService — but `ComputeAsync` yields,
and a query that yields must never run inside a Bots hook (see above). Do the
yielding work in your own coroutine and publish the answer:

```lua
-- NOT inside an action hook. A worker coroutine that owns the yield:
task.spawn(function()
    while true do
        local candidate = pendingCoverRequest()
        local path = PathfindingService:CreatePath()
        path:ComputeAsync(botPosition, candidate)      -- yields, safely, here
        bot:set("coverReachable", path.Status == Enum.PathStatus.Success)
        task.wait()
    end
end)

-- The action stays synchronous: it reads what the worker published.
update = function(bot)
    local answer = bot:get("coverReachable")
    if answer == nil then
        return "Running"      -- still being computed
    end
    return if answer then "Success" else "Failure"
end
```

If you genuinely want a yielding probe and accept the consequences, drive the
query from a context Bots does not own — a commander loop, a spawn handler —
never from `enter` / `update` / `exit`.

---

## Built-ins

**Generators** — all take `around` (context key, default `"self"`):

| Builder | Produces |
|---|---|
| `Generators.ring({ radii, perRing? })` | Staggered concentric rings, snapped to ground. The default choice. |
| `Generators.grid({ extent, spacing })` | A square grid, snapped. Thorough; mind the count (`(2·extent/spacing + 1)²`). |
| `Generators.tagged({ tag, range? })` | Authored `CollectionService`-tagged BaseParts (cover points, perches). Not snapped. |

**Tests** — all take `weight?` and `name?` (name the test when using the same
builder twice in one query, so `breakdown` keys don't collide):

| Builder | Cost | Scores |
|---|---|---|
| `Tests.distance({ to, best, worst })` | cheap | 1 at `best` studs from `context[to]`, 0 at `worst`. `best > worst` prefers far. |
| `Tests.direction({ from, toward, invert? })` | cheap | 1 dead ahead of `from`→`toward`, 0 behind. `invert` = retreat test. |
| `Tests.spacing({ allies, radius })` | cheap | 0 on top of the nearest of `context[allies]` (array), 1 at `radius`+ from all. |
| `Tests.hidden({ from, heights? })` | expensive | Fraction of rays from `context[from]` to candidate+heights that are **blocked** (cover). Pass the threat's eye position. |
| `Tests.exposed({ to, eye?, heights? })` | expensive | Fraction of rays from candidate eye to `context[to]`+heights that get through (LOS for attack/peek spots). |
| `Tests.reachable({ from? })` | validate | Pass/reject via `probes.isReachable(context[from or "self"], candidate)`. |

A custom test is a plain table — e.g. "prefer spots about 12 studs out":

```lua
{ name = "idealRange", cost = "cheap", weight = 2,
  score = function(point, context)
      return TQ.Curves.band((point - context.threat).Magnitude, 12, 6)
  end }
```

---

## Deliberately out of v1

Async/time-sliced runs spread over frames (add when fleets of queriers demand
it), a debug visualizer that draws candidates in the world (would touch
Instances; the `breakdown`/`RunInfo` data it would draw is already returned),
and navmesh-based generators (`ring`/`grid`/`tagged` cover the common cases; a
navmesh sampler slots in as one more generator without contract changes).
