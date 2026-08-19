# HTN

A **SHOP-style total-order hierarchical task network planner** for Roblox —
the deliberation layer for AI whose action *ordering must be discovered at
runtime*: survival companions ("keep the fire going" might mean feed it, or
first find an axe, chop wood, *then* feed it), workers with tool and resource
dependencies, multi-step objectives with interchangeable means.

Compound tasks decompose through **priority-ordered methods** into primitive
tasks. The planner simulates each primitive's **declared effects forward on a
cloned world state**, so later steps are planned against the world *as it will
be*; dead ends backtrack to the next method. The output is a flat primitive
plan — plus a full **decomposition trace**, because "why won't it do the
thing" must always be answerable.

This package **does not require Bots** (or anything else — it contains zero
Roblox APIs and runs entirely under Lune). It integrates with the sibling
[`Bots`](../Bots/) library by *shape*: `HTN.goal(spec)` returns a table that
satisfies Bots' Goal contract, validated by `Bot.new` like any hand-written
goal. Utility arbitration stays in charge of **whether** deliberate behavior
wins right now; HTN decides **how** it unfolds.

**Reading the source?** Read the worked example below first (it exercises
everything), then [`Types.luau`](src/Types.luau) — the split it documents
(each primitive task has a PLANNING half simulated by the planner and a
RUNTIME half executed as an operator) is the library's core idea. Then
[`Planner.luau`](src/Planner.luau) (decomposition, backtracking, the trace)
and [`Execution.luau`](src/Execution.luau) (step, monitor, replan).
`Domain`/`BotsGoal`/`Runner` are thin shells around those two.

---

## Architecture

| Module | Role |
|---|---|
| `Domain.luau` | `Domain.new(spec)` — the task library, validated **where it is written** (unresolved subtask names, malformed methods all error at load). Pure data, reusable across goals/bots/games. |
| `Planner.luau` | `Planner.plan(domain, root, state, opts?)` — decomposition with forward effect simulation and backtracking. Pure; returns `(Plan?, trace)`, trace always (capped at `traceLimit`, default 64; `0` disables). |
| `Execution.luau` | The shared step engine: run one operator at a time, **monitor** each step's condition against fresh state before starting it, **replan** on failure/invalidation up to `replanLimit` CONSECUTIVE times — a completed step refunds the budget. |
| `BotsGoal.luau` | `HTN.goal(spec)` — wraps domain + root + operators into a Bots-shaped Goal. |
| `Runner.luau` | `Runner.new(config)` — the same engine standalone, driven by your own loop. |
| `Types.luau` | Every public type. Zero dependencies. |

The task split that makes it work: each primitive has a **planning half**
(`condition` + declared `effects`, simulated during decomposition) and a
**runtime half** (an `Operator` — the same `enter`/`update`/`exit` lifecycle
as a Bots Action, exit guaranteed on any outcome). The planner never runs
operators; executors never simulate effects.

---

## Worked example: the survival companion's campfire

```lua
local HTN = require(path.to.HTN)

-- THE DOMAIN: what the world means and how tasks decompose. Pure data.
local campDomain = HTN.Domain.new({
    compounds = {
        KeepFireBurning = {
            methods = { -- tried in order: order IS priority
                { name = "feed", condition = function(s) return s.hasWood end,
                  subtasks = { "GoToFire", "FeedFire" } },
                { name = "gatherFirst", condition = function(s) return s.treesNearby end,
                  subtasks = { "GoToTree", "ChopTree", "KeepFireBurning" } }, -- recursion: legal, capped
            },
        },
    },
    primitives = {
        GoToTree = { effects = function(s) s.at = "tree" end },
        ChopTree = {
            condition = function(s) return s.at == "tree" end,
            effects = function(s) s.hasWood = true end,
        },
        GoToFire = { effects = function(s) s.at = "fire" end },
        FeedFire = {
            condition = function(s) return s.hasWood and s.at == "fire" end,
            effects = function(s) s.hasWood = false end,
        },
    },
})

-- THE GOAL: one entry in a normal Bots goal list.
local MaintainFire = HTN.goal({
    name = "MaintainFire",
    domain = campDomain,
    root = "KeepFireBurning",
    state = function(bot) -- derive planning symbols from live knowledge
        return {
            hasWood = bot:get("woodCarried") > 0,
            treesNearby = bot:get("nearestTree") ~= nil,
            at = bot:get("location"),
        }
    end,
    operators = { -- runtime halves: Bots-Action-shaped, one per primitive
        GoToTree = { requires = { "mover" }, update = function(bot) --[[ drive mover ]] end,
                     exit = function(bot) bot.body.mover:Stop() end },
        ChopTree = { enter = function(bot) --[[ swing, add wood, return "Success" ]] end },
        GoToFire = { requires = { "mover" }, update = function(bot) --[[ ... ]] end },
        FeedFire = { enter = function(bot) --[[ consume wood, stoke fire ]] end },
    },
    score = function(bot) return 1 - bot:get("fireLevel") end, -- normal utility!
    cooldown = 5,
    replanLimit = 3,
})

-- Reactive goals sit beside it and interrupt through the normal arbiter:
local companion = Bots.Bot.new({
    body = { mover = ..., },
    goals = { FleeDanger, MaintainFire, FollowOwner },
})
```

With `hasWood = false` and a tree nearby, the planner emits
`GoToTree → ChopTree → GoToFire → FeedFire` — the recursion resolved because
the simulation *saw* `hasWood` become true after `ChopTree`. If wood is
already carried: `GoToFire → FeedFire`. Nobody authored either sequence.

---

## Runtime semantics (the load-bearing part)

1. **Plan on adoption.** The wrapper action's `enter` derives state and plans.
   No plan → `Failure` → the goal's normal cooldown starts and the utility
   layer moves on. Planning is synchronous, bounded by `maxExpansions` (2000
   decompose calls), `maxDepth` (32) /
   `maxSteps` (64), and never happens fleet-wide per tick.
2. **One operator at a time**, full lifecycle. Instantly-completing operators
   chain within one tick (a plan of instant steps finishes in a single tick),
   and `exit` always runs once an operator started — `Success`, `Failure`, or
   `Interrupted` — so cleanup habits from Bots transfer unchanged.
3. **Monitoring**: before each step *starts*, its planning `condition` is
   re-checked against freshly derived state. The plan was made against a
   prediction; the world may have disagreed (wood stolen, door now locked).
4. **Replanning**: a failed or invalidated step triggers a replan *from the
   current state* — not goal failure — up to `replanLimit` (default 3)
   **consecutive** replans, then the goal fails normally. An
   interrupted-and-readopted goal plans fresh; nothing is resumed blindly.
5. **Progress refunds the replan budget.** Completing a step resets the counter,
   so `replanLimit` bounds *thrash* — the same step failing over and over — and
   not how adaptable a plan is allowed to be. A companion whose tree gets taken,
   then whose path gets blocked, then whose axe breaks, completing steps between
   each, has adapted three times rather than failed three times; that is the
   behaviour HTN exists for and it must not exhaust the limit.
6. **Interrupts come from above.** A reactive goal that beats the HTN goal's
   utility+commitment interrupts it like any goal; the in-flight operator
   exits with `"Interrupted"`. HTN never fights the arbiter.
7. An **empty plan is success**: a method with `subtasks = {}` legitimately
   means "already satisfied, nothing to do".

### Debugging

Two tools, mirroring Bots' tracing philosophy:

- **The decomposition trace** — every method tried, condition failed,
  primitive emitted, backtrack, and cap hit, in order. Returned by
  `Planner.plan` alongside the plan (or the `nil`), and kept as
  `RunState.lastTrace` after every runtime (re)plan. Capped at `traceLimit`
  entries (default 64) so a heavily-backtracking domain cannot allocate an
  unbounded one; `traceLimit = 0` switches recording off entirely for a shipped
  build. It is on by default because "the bot won't do the thing" is HTN's
  characteristic failure and this is the only thing that answers it.
- **Live run introspection** — under Bots, the `RunState` (`plan`, `step`,
  `entered`, `replans` — consecutive, see above — `failedReason`, `lastTrace`)
  lives in the bot's **personal** blackboard at `planKey` (default
  `"htn:<name>"`); read it alongside `bot:trace()` / `bot:explain()`. Treat it as
  read-only, and read it off `bot.blackboard` rather than `bot:get`: `planKey` is
  the same string for every bot running the goal, so the group → master
  fallthrough is not what you want here.

```lua
local run = bot.blackboard:get("htn:MaintainFire")   -- personal board, not the fallthrough
print(run.step, table.concat(run.plan or {}, " -> "), run.replans, run.failedReason)
for _, entry in run.lastTrace or {} do
    print(("%s%-9s %-16s %s %s"):format(string.rep("  ", entry.depth), entry.kind,
        entry.task, entry.method or "", entry.reason or ""))
end
```

---

## API summary

```lua
-- Authoring
HTN.Domain.new({ compounds?, primitives? })      -- validated task library
HTN.goal(spec)                                   -- Bots-shaped Goal (see GoalSpec below)

-- Planning (call directly for tests/tools; executors call it for you)
HTN.Planner.plan(domain, root, state, { maxDepth?, maxSteps?, maxExpansions?, traceLimit? }?)
--> ({ steps, finalState }?, decompositionTrace)

-- Standalone execution (non-Bots hosts)
local runner = HTN.Runner.new({ domain, root, state, operators, owner?, replanLimit? })
runner:start()      -- plan + drive now -> "Running" | "Success" | "Failure"
runner:update(dt)   -- drive while Running (terminal statuses are sticky)
runner:stop()       -- interrupt: in-flight operator exits "Interrupted"
runner:inspect()    -- live RunState
```

`GoalSpec`: `name`, `domain`, `root`, `state(bot) -> WorldState`,
`operators { [primitive]: Operator }` — plus pass-through Bots fields
(`canRun?`, `score?`, `weight?`, `requires?`, `interruptible?`, `cooldown?`,
`effects?`) and `replanLimit?` (CONSECUTIVE replans; progress resets it),
`maxDepth?`, `maxSteps?`, `maxExpansions?`, `traceLimit?`, `planKey?`.
Operator `requires` are aggregated onto the wrapper action, so `Bot.new`
validates every operator's body needs at creation, as usual.

---

## Design notes & boundaries

- **World state is shallow-cloned** for planning. Keep symbols to values you
  treat as immutable (booleans, numbers, strings, refs); an `effects` that
  mutates a nested table would leak into sibling method attempts.
- **No task parameters/unification** — the pragmatic game-HTN simplification
  (data rides in state symbols). No cost-optimizing search — method *order*
  is the priority mechanism. No utility-scored method selection — the utility
  layer already lives above, in goal selection.
- **No parallel plans** — parallelism remains a body-channel concern, per the
  suite's design.
- Consumer `condition`/`effects`/`state` errors propagate: under Bots they
  land in Bots' hook containment (goal fails, exits still run); under the
  Runner they reach your caller. Operator `exit` errors are warned and
  swallowed here, in both hosts.
- When you need HTN vs. when you don't: if you catch yourself writing "first
  it needs X, but if it lacks Y it must first…" — domain. If the sequence is
  fixed and short — a plain Bots goal with ordered actions is simpler and
  easier to read.
