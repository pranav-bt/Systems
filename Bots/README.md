# Bots

A generic, game-agnostic **agent brain** for Roblox. Blackboard-driven sensing,
utility-scored goal selection, and sequenced action execution — with **zero
assumptions about what a bot physically is**. The same core drives an ambient
NPC, an enemy AI, or a playerbot puppeting a real player's character: you supply
the body, the sensors, the goals, and the actions; the library supplies the
thinking.

The package spawns nothing, requires nothing outside its own folder, and never
touches an Instance in its decision path.

---

## Architecture

| Module | Role |
|---|---|
| `Blackboard.luau` | Named value bags + the consumer **sensors** that keep them fresh + **working-memory facts** (timestamped, confidence-decaying, forgettable). One class, three scopes: master / group / per-bot. |
| `Bot.luau` | `Bot.new(params)` — ties a free-form **body** + goal set + personal blackboard together, validates everything loudly, registers with the Brain. |
| `Goal.luau` / `Action.luau` | `Goal.new(spec)` / `Action.new(spec)` constructors: validate a definition **where it is written** and return the typed table. Plain tables stay accepted (Bot.new re-validates either way). |
| `Planner.luau` | The per-bot decision engine: utility selection, commitment, sequenced action execution, interrupts, failure cooldowns. Pure logic, no Roblox APIs. |
| `Brain.luau` | The **singleton scheduler**: shared boards update on their own cadence; each bot carries its own phase and is drained by `step()` under a frame budget. `start()` for its own driver, `step()`/`tick()` from your own loop. Also `stimulate` / `stimulateGroup` for **immediate out-of-band reactions**, and `stats()` for what the last frame cost. |
| `Tokens.luau` | Claimable token pools (at most N holders at once) — the squad-coordination primitive behind "only 2 bots attack simultaneously". |
| `Types.luau` | Every public type. Zero dependencies. |
| `Config.luau` | Default tunables (tick rate, frame budget, commitment curve, jitters) — override via `Brain.configure`, which range-checks them. |
| `Rng.luau` / `Clock.luau` | The package's single sources of randomness and time. Swap them (`Bots.setRandom` / `Bots.setClock`) to make a headless run reproducible; see [Determinism](#determinism). |
| `Utility.luau` | Response-curve helpers for writing `score` functions: `linear`, `quad`, `logistic`, `combine`. |

There is deliberately **no movement code in this package** — no mover, no
movement actions, no pathfinding types. Your actions drive whatever you put in
`bot.body`; the sibling [`Pathfinding`](../Pathfinding/) library provides a
ready-made `Mover` contract + `PathAgent` implementation if you want one.

Every bot thinks every `TICK_INTERVAL` (default 0.2s) — but not all on the same
frame. Each bot carries its own phase, and each frame drains whoever is due
under a time budget:

```
Brain.step()                          -- once per frame, from the driver
    Brain.master:update()            -- master sensors, at most once per TICK_INTERVAL
    for each bot that is due, resuming where the last frame stopped:
        its group board:update()     -- squad sensors, at most once per TICK_INTERVAL
        bot.blackboard:update()      -- personal sensors
        Planner.step(bot)            -- select / execute / interrupt
        stop if FRAME_BUDGET is spent -- the rest go first next frame
```

100 bots at 0.2s is ~8 steps every frame instead of 100 steps landing on one
frame in twelve. The cursor persists across frames, so a bot can be *late* under
overload but is never starved; [`Brain.stats()`](#api-summary) reports how much
got deferred so a game can lower its own LOD in response.

`Brain.tick()` is the other way to drive it: one full, unbudgeted cycle of
everything due, right now. It's the deterministic path — inject `now` and a
headless test replays identically.

Between scheduled steps, `bot:stimulate(...)` runs that same sense+plan step for
one bot **immediately** — the reaction path for events that can't wait 0.2s.

**Reading the source?** Start with [`Types.luau`](src/Types.luau) — every
contract (Action, Goal, Bot, Blackboard) lives there with its semantics
documented. Then [`Planner.luau`](src/Planner.luau), whose header comment is
the spec for selection, commitment, and execution — the heart of the library.
[`Brain.luau`](src/Brain.luau) (scheduling + stimulate),
[`Blackboard.luau`](src/Blackboard.luau) (sensors + facts), and
[`Tokens.luau`](src/Tokens.luau) each stand alone after that. The one idea to
hold: **goals arbitrate modes; actions do the work; everything else feeds
them data.**

---

## Quick start: a guard NPC

```lua
local Bots = require(path.to.Bots)
local Pathfinding = require(path.to.Pathfinding) -- separate library; any Mover-shaped thing works
local Utility = Bots.Utility

-- ACTIONS: dumb behaviour bits. enter once -> update while "Running" -> exit
-- exactly once with "Success" | "Failure" | "Interrupted". The constructors
-- validate the definition right here, where it's written.
local ChaseTarget = Bots.Action.new({
    name = "ChaseTarget",
    requires = { "mover" },  -- validated against the body at Bot.new
    update = function(bot, dt)
        local target = bot:get("nearestTarget")
        if not target then
            return "Failure"                     -- lost them: abort the goal
        end
        if target.distance < 6 then
            return "Success"                     -- in range: next action
        end
        local mover = bot.body.mover
        mover:SetGoal(target.position)
        local status = mover:GetStatus()
        if status == "Stuck" or status == "Unreachable" then
            return "Failure"                     -- can't reach them: abort (goal cooldown kicks in)
        end
        return "Running"
    end,
    exit = function(bot)
        bot.body.mover:Stop()                    -- runs on ANY outcome, incl. Interrupted
    end,
})

local Swing = Bots.Action.new({
    name = "Swing",
    enter = function(bot)                        -- instant action: finishes from enter
        local target = bot:get("nearestTarget")
        if not target then
            return "Failure"
        end
        bot.body.swing(target.ref)
        return "Success"
    end,
})

-- GOALS: precondition -> ordered actions -> effects.
local Attack = Bots.Goal.new({
    name = "Attack",
    canRun = function(bot)
        return bot:get("nearestTarget") ~= nil
    end,
    score = function(bot)                        -- continuous utility, not binary
        local target = bot:get("nearestTarget")
        return 0.3 + 0.7 * Utility.linear(target.distance, 60, 6)
    end,
    actions = { ChaseTarget, Swing },
    effects = function(bot)
        bot:set("lastVictoryAt", os.clock())     -- blackboard writes on success
    end,
})

local Patrol = Bots.Goal.new({
    name = "Patrol",
    canRun = function()
        return true
    end,
    score = function()
        return 0.05                              -- idle baseline
    end,
    actions = { WalkPatrolRoute },               -- your own action
})

-- BODY: free-form. A rig you spawned, a player's character, anything.
local rig = guardTemplate:Clone()
rig.Parent = workspace
local bot = Bots.Bot.new({
    id = "guard_gate",
    body = {
        model = rig,
        rootPart = rig.HumanoidRootPart,
        mover = Pathfinding.PathAgent.new(rig.Humanoid, rig.HumanoidRootPart),
        swing = function(targetModel) --[[ your combat ]] end,
    },
    goals = { Attack, Patrol },
    sensors = {
        -- Consumer decides WHAT is sensed and HOW. Interval throttles cost.
        nearestTarget = { interval = 0.3, read = function(bot)
            return findNearestPlayer(bot.body.rootPart.Position, 60) -- your perception
        end },
    },
})

Bots.Brain.start()
```

A **playerbot** is the same thing with a different body: pass the player's
existing `character`/`Humanoid` in `body` and write actions that drive it —
nothing else changes. Nothing in the core knows the difference.

---

## Blackboards

Three scopes, one class. Reads through `bot:get(key)` fall through
**personal → group → master**, so decision code asks one question and doesn't
care where the answer lives.

```lua
-- MASTER: values every bot shares. Owned by the Brain.
Bots.Brain.master:set("alarmLevel", 0)
Bots.Brain.master:addSensor("playerCount", function()
    return #game.Players:GetPlayers()
end, 1.0)

-- GROUP: consumer-created, shared by whichever bots you give it.
local squadBoard = Bots.Blackboard.new("RedSquad", { lastSeenPlayerPos = nil }, squadObject)
squadBoard:addSensor("squadCenter", function(squad) return squad:center() end)
local bot = Bots.Bot.new({ ..., group = squadBoard })   -- also assignable later: bot.group = board

-- PERSONAL: per bot, declared at Bot.new (or bot.blackboard:addSensor later).
```

- `Blackboard.new(name, initialValues?, owner?)` — `owner` is passed to every
  sensor as its first argument (the bot for personal boards).
- `addSensor(key, read, interval?)` — `read(owner, bb)`'s return value is
  written to `key` each update; `interval` (seconds) throttles expensive
  perception. Default: every update of its board. Reschedules carry ±10% phase
  jitter, so same-interval sensors across a fleet drift apart instead of spiking
  together (the first read always runs on the first update, whatever the clock's
  origin).
- `invalidate(key)` — marks a sensor **due**, so the next board update recomputes
  it once. Returns `false` if there is no such sensor, so a misspelled key is
  visible rather than silent. **For a derived value that changes on an EVENT**,
  which otherwise has no good home: a sensor with an `interval` polls it (a wasted
  read every lap, plus up to one interval of staleness) and `set` pushes it
  (correct, but the recompute happens outside the update and every caller has to
  debounce its own bursts). Invalidation is the standard shape — dirty flag, lazy
  recompute — and it composes with what the board already does: fifty things tagged
  in one frame are **one** rebuild, and the read stays *inside* the update, so a
  shared list cannot be rebuilt while a bot is mid-read of it. It resets the timer
  rather than inserting an extra read.
- Master and each **distinct** group board update at most once per
  `TICK_INTERVAL`, no matter how many bots share them or how often the frame
  driver runs — an `interval = 0` sensor on a shared board fires at
  `TICK_INTERVAL`, not once per frame.
- `bb:update(now)` can also be called manually to run due sensors right after a
  scripted event (for an instant write + re-plan, prefer `bot:stimulate`).

### Working memory: facts

Plain values are for current state (`alarmLevel`). **Facts** are for beliefs
that go stale: each carries a timestamp, a confidence, and an optional ttl.
Confidence decays linearly to 0 across the ttl; an expired fact reads as `nil`,
exactly like one never written — the bot *forgets*.

```lua
-- A sensor remembering perception (sensors receive the board as 2nd arg):
sensors = {
    canSeePlayer = { interval = 0.3, read = function(bot, bb)
        local seen = lineOfSightScan(bot.body.rootPart)
        if seen then
            bb:setFact("lastSeenPos", seen.position, 8) -- forget after 8s
        end
        return seen ~= nil
    end },
}

-- A goal using the memory: search where they WERE, urgency fading with belief.
local Investigate = Bots.Goal.new({
    name = "Investigate",
    canRun = function(bot)
        return not bot:get("canSeePlayer") and bot:getFact("lastSeenPos") ~= nil
    end,
    score = function(bot)
        local _, confidence = bot:getFact("lastSeenPos")
        return 0.5 * (confidence or 0)  -- stale memory = weaker pull
    end,
    actions = { GoToLastSeen, LookAround },
})
```

- `bb:setFact(key, value, ttl?, confidence?)` — remember (`confidence` default
  1, `ttl` nil = never fades). `bb:forget(key)` drops it early.
- `bb:getFact(key)` → `(value, decayedConfidence)`, or `(nil, nil)` when
  unknown or expired. `bot:getFact(key)` reads with the same
  personal → group → master fallthrough as `bot:get`; `bot:setFact(...)`
  writes personal.
- Fully-decayed facts are also swept on each board update, so memory doesn't
  accumulate.

---

## Goals & actions: the contract

```lua
export type Action = {
    name: string,
    requires: { string }?,                            -- body fields the hooks use
    enter: ((bot) -> ActionResult?)?,                 -- once, at start; may finish instantly
    update: ((bot, dt: number) -> ActionResult?)?,    -- every tick while "Running"
    exit: ((bot, outcome: ActionOutcome) -> ())?,     -- exactly once, however it ends
}
-- ActionResult:  "Running" | "Success" | "Failure"   (nil counts as Running)
-- ActionOutcome: "Success" | "Failure" | "Interrupted"

export type Goal = {
    name: string,
    canRun: (bot) -> boolean,        -- precondition (selection gate)
    score: ((bot) -> number)?,       -- utility (default 1); <= 0 = ineligible
    weight: number?,                 -- static multiplier (default 1)
    requires: { string }?,
    actions: { Action },             -- executed strictly in order
    effects: ((bot) -> ())?,         -- applied once, on full success only
    interruptible: boolean?,         -- default true
    cooldown: number?,               -- seconds ineligible after FAILURE
}
```

The load-bearing semantics:

1. **Preconditions gate selection only.** `canRun` is *not* re-checked while the
   goal runs — a goal legitimately falsifies its own precondition as it works
   (reloading makes "clip empty" false before the goal ends). A running goal
   ends only by finishing, failing, losing a utility challenge, or an explicit
   abandon.
2. **Actions are a strict sequence.** Each must return `Success` before the next
   starts. Instantly-completing actions chain within a single tick.
3. **`exit` always runs** — exactly once per started action, with the real
   outcome, including `"Interrupted"`. Put your cleanup there (stop pathing,
   cancel animations) and it holds no matter how the goal ends.
4. **`Failure` aborts the goal**: no effects, and the goal's failure `cooldown`
   starts so a still-true precondition can't re-pick it into a failure loop.
5. **Effects fire only when the last action succeeds** — the place to write
   declarative blackboard state ("clip full", "alarm raised").
6. An action whose `enter` returns `Running` **must** have an `update` hook —
   the Planner warns loudly and fails the goal at the moment it would otherwise
   hang forever.
7. **A hook that throws cannot wedge the bot.** An error in `enter`/`update` is
   warned (with traceback) and treated as the action returning `Failure` —
   `exit` still runs, the goal aborts, its cooldown starts, and the bot
   recovers on its next step. Errors in `exit`/`effects` are warned and
   swallowed (the goal is already ending).

**Two validation gates, same rules.** `Bots.Goal.new(spec)` / `Bots.Action.new(spec)`
validate a definition **where it is written** (a typo errors at module load, in
the file that contains it) and return the typed table. `Bot.new` then
re-validates everything it receives — shapes, duplicate goal names, and every
`requires` against the body — so plain tables are equally accepted, and nothing
malformed can reach the Planner either way.

---

## The Planner: selection, commitment, interruption

- **Eligible** = `canRun(bot)` passes, off cooldown, `score > 0`.
- **Ranked** by `score(bot) × weight × jitter`, where jitter is the bot's
  persistent per-goal personality multiplier (`GOAL_JITTER`, ±10% by default) —
  so twenty identical bots don't act in lockstep. Exact ties keep the earlier
  goal in the list.
- The winner's weighted score is **frozen** as `baseScore` for the run — a goal
  is judged by how important it was when adopted, so it can't undermine itself
  by (correctly) becoming less urgent as it works.
- **Commitment**: while running, the goal is defended by
  `max(baseScore, liveScore) × min(PLAN_COMMIT_MAX, PLAN_COMMIT_BASE + PLAN_COMMIT_GROWTH × secondsInGoal)`,
  where `liveScore` is the goal's score re-evaluated right now. The frozen side
  stops a goal from undermining itself; the live side stops a goal whose
  urgency has **grown** (fleeing as danger mounts) from being interrupted at a
  stale, too-low value. The default curve starts at ×1.15 and grows 5%/s to a
  ×1.6 cap: brand-new plans hold a small edge, old plans a strong one — but a
  drastic-enough challenger always breaks through the cap.
- `interruptible = false` goals ignore challengers entirely; only completion,
  failure, or `bot:abandonGoal()` end them.
- **Interrupt** = in-flight action's `exit(bot, "Interrupted")`, then the new
  goal enters the same tick.
- `Planner.context(bot)` / `bot:context()` returns the live snapshot:
  `{ goal, action, actionIndex, entered, startedAt, elapsed, baseScore }`
  (all nil when idle).

---

## Reacting instantly: `stimulate`

Scheduled stepping gives a worst-case reaction time of one `TICK_INTERVAL`. For events that
can't wait — got shot, heard an explosion, received an order —
`bot:stimulate(values?)` writes the stimulus to the personal board and runs one
**immediate** out-of-band sense+plan step for just that bot:

```lua
humanoid.HealthChanged:Connect(function()
    bot:stimulate({ lastHitAt = os.clock() })   -- re-plans NOW, not next tick
end)
```

Commitment still applies: a stimulus interrupts by raising challenger scores
through the normal arbiter, not by bypassing it.

**One more update runs first.** A step ADVANCES the running goal before it
arbitrates, so a damage stimulus lets the current action tick once — one more
shot before fleeing — and only then can a challenger take over. That ordering is
deliberate (an action that was mid-swing gets to finish its frame rather than
being cut off between `enter` and `exit`), but it is why "react NOW" is not the
same as "stop NOW". For an unconditional drop, call `bot:abandonGoal()` FIRST
and then `stimulate`: abandon exits the in-flight action with `"Interrupted"`, so
the stimulated step starts from a clean slate with nothing to advance.

A stimulus *is* that bot's step, so it also pushes out the bot's next scheduled
one — stimulating and then being drained a frame later would be two steps'
worth of work for one bot's worth of thinking. Stimulate freely; it costs a
step, it doesn't add one.

Both stimulate calls take an optional trailing `now` — it defaults to
`os.clock()` and only matters when you drive the Brain with a simulated clock
(headless tests): pass the same fabricated time you pass `Brain.tick(now)`, so
out-of-band steps stamp the same timeline.

`Brain.stimulateGroup(groupBoard, values?)` is the squad-wide version: it
writes to the **group** board, then immediately steps every registered bot
sharing it — the delivery mechanism for orders:

```lua
Bots.Brain.stimulateGroup(squadBoard, { order = "fallBack" })
-- every squad member re-plans against bot:get("order") the same instant
```

---

## Coordination: token pools & orders

`Bots.Tokens` is the primitive behind "only N bots may do X at once" (classic
attack tokens). A pool is a plain value — store it where the bots that share it
can reach it, naturally a blackboard:

```lua
local squadBoard = Bots.Blackboard.new("RedSquad")
squadBoard:set("attackTokens", Bots.Tokens.new("attack", 2, 5)) -- capacity 2, 5s lease backstop

local EngageSlot = Bots.Action.new({
    name = "EngageSlot",
    enter = function(bot)
        -- Claim in enter: Failure = pool full = not my turn (goal cooldown kicks in).
        return if bot:get("attackTokens"):tryClaim(bot.id) then "Success" else "Failure"
    end,
    exit = function(bot)
        bot:get("attackTokens"):release(bot.id)  -- exit ALWAYS runs: tokens can't leak
    end,
})
-- Attack goal: actions = { EngageSlot, ChaseTarget, Swing }
```

- `tryClaim(holder)` claims or refreshes (idempotent while held); `release`
  frees; `holds` / `count` / `setCapacity` inspect and retune.
- The optional `ttl` expires leases whose holder vanished without exiting;
  long-running holders just `tryClaim` again each update to refresh.
- Claim in `enter`, release in `exit` — the exit guarantee (including
  `Interrupted`) is what makes the pairing leak-proof.

**Orders** need no dedicated machinery: write an order onto the group board
(`stimulateGroup` above), give bots goals whose `canRun`/`score` read
`bot:get("order")`, and clear the order in an `effects` when fulfilled. The
squad-level *decider* (who issues orders, when) is consumer territory — a plain
script, or its own "commander" bot whose body is the squad.

---

## Scaling: per-bot tick rates

`bot.tickInterval` (settable at `Bot.new` or any time after) paces an
individual bot: it senses + plans every `tickInterval` seconds instead of at the
default `TICK_INTERVAL`. This is the LOD lever for big fleets:

```lua
-- A cheap master sensor demoting far-away bots to slow thinking:
Bots.Brain.master:addSensor("lod", function()
    for _, bot in fleet do
        local nearPlayer = isAnyPlayerWithin(bot.body.rootPart.Position, 120)
        bot.tickInterval = if nearPlayer then nil else 1.5   -- nil = every tick
    end
    return true
end, 1)
```

Paced bots keep correct behaviour: the Planner derives each step's `dt` from
that bot's own last step, so action `update(bot, dt)` code needs no changes.
A bot's first scheduled step lands at a random phase inside its interval, and
reschedules carry ±10% jitter, so a fleet spawned in one frame spreads itself
across the interval instead of thinking in lockstep. A `stimulate` always steps
the bot immediately, whatever its pace — so even a slow-thinking bot reacts
instantly to real events — and it *consumes* that bot's scheduled step, so a bot
that just re-planned because it got shot isn't stepped again a frame later.

Each bot also carries roughly nineteen closures (eleven from `Bot.new`, eight
from its blackboard), so a 200-bot fleet holds ~3,800 of them. That is a
deliberate trade — capturing `bot` is what lets `bot:get(k)` be called without a
self-argument mistake — but it is worth knowing when sizing a very large fleet.

`tickInterval` is the cheap lever; `FRAME_BUDGET` is the backstop. Raising
`tickInterval` on distant bots removes work; `FRAME_BUDGET` only spreads whatever
work exists across more frames. If `Brain.stats().deferred` is non-zero frame
after frame, reach for the former first.

---

## API summary

```lua
-- Brain (singleton)
Bots.Brain.start(driver?)           -- budgeted frame drain (idempotent); default driver = Heartbeat
Bots.Brain.stop()                   -- disconnects the driver
Bots.Brain.step(now?, budget?)      -- ONE budgeted frame, from your own per-frame loop
Bots.Brain.tick(now?)               -- ONE full unbudgeted cycle, from your own loop
Bots.Brain.stats()                  -- { bots, stepped, deferred, seconds, budgetHits, reentered }
Bots.setRandom(fn?)                 -- swap the package RNG (nil = math.random); see Determinism
Bots.setClock(fn?)                  -- swap the package clock (nil = os.clock); see Determinism
Bots.Brain.configure({ TICK_INTERVAL = 0.1, FRAME_BUDGET = 0.004, PLAN_COMMIT_MAX = 2 })
Bots.Brain.master                   -- the global Blackboard
Bots.Brain.count()                  -- registered bots
Bots.Brain.register(bot) / unregister(bot)   -- manual control (Bot.new auto-registers)
Bots.Brain.reset(clearMaster?)      -- drop every bot; round transitions and tests
Bots.Brain.stimulate(bot, values?, now?)     -- out-of-band: write + sense + plan one bot NOW
Bots.Brain.stimulateGroup(board, values?, now?) -- same for every bot sharing a group board
Bots.Brain.tunables()                        -- effective tunables snapshot (a copy)

-- Authoring
Bots.Goal.new(spec)                 -- validate a goal at the definition site; returns it typed
Bots.Action.new(spec)               -- same for actions
Bots.Goal.validate(goal, label) / Bots.Action.validate(action, label)   -- the raw gates, reused by Bot.new

-- Bot
local bot = Bots.Bot.new({ id?, body?, goals, group?, values?, sensors?, tickInterval? })
bot:get(key) / bot:set(key, value)  -- fallthrough read / personal write
bot:getFact(key) / bot:setFact(key, value, ttl?, confidence?)   -- working memory (fallthrough read)
bot:stimulate(values?, now?)        -- react NOW (see above; `now` for simulated clocks)
bot:currentGoal()                   -- string? 
bot:context()                       -- PlannerContext snapshot
bot:trace()                         -- recorded decisions, newest first (TRACE_DECISIONS > 0)
bot:explain()                       -- live per-goal verdicts + the bar a challenger must clear
bot:abandonGoal()                   -- drop everything (exits action as Interrupted)
bot:destroy()                       -- abandon + unregister
bot.body / bot.blackboard / bot.group / bot.tickInterval   -- yours to use

-- Blackboard
Bots.Blackboard.new(name, initialValues?, owner?)
bb:get(key) / bb:set(key, value) / bb.values
bb:setFact(key, value, ttl?, confidence?) / bb:getFact(key) / bb:forget(key)
bb:addSensor(key, read, interval?) / bb:removeSensor(key) / bb:invalidate(key)
bb:update(now)

-- Tokens
local pool = Bots.Tokens.new(name, capacity, ttl?)
pool:tryClaim(holder) / pool:release(holder) / pool:holds(holder)
pool:count() / pool:holders() / pool:setCapacity(n)
```

Consumer errors are contained at every layer: a throwing master/group sensor is
warned and that board skipped for the cycle; a throwing personal sensor skips
just that bot; a throwing action hook fails just that goal (its `exit` still
runs). The scheduler itself never dies, and every other bot still steps.

### Hooks must not yield

Every consumer hook — a sensor `read`, a goal's `canRun` / `score` / `effects`,
an action's `enter` / `update` / `exit` — runs **inside** the scheduler's drain.
None of them may yield: no `task.wait`, no `:ComputeAsync`, no
`RemoteFunction:InvokeClient`, no `:AwaitValue`.

A yield there suspends the drain mid-fleet. The driver fires again on the next
frame and would start a second drain over the same registry while the first is
still parked — two coroutines mutating one bot's planner state, a frame budget
measuring wall time instead of work, and the slow-step warning reporting the
yield rather than the cost.

Bots refuses that rather than corrupting state. A second drain returns
immediately and increments `Brain.stats().reentered`; a bot re-entered by a
`stimulate` while its own step is suspended is skipped with a warning. So the
symptom of a yielding hook is **bots quietly missing steps**, and the number to
check is:

```lua
if Bots.Brain.stats().reentered > 0 then
    -- a hook yielded; the warning above it names the bot
end
```

**Do the waiting elsewhere.** Own the yield in your own coroutine and publish the
answer through the blackboard; the hook reads it and returns `Running` until it
arrives:

```lua
-- a worker you control
task.spawn(function()
    local result = someYieldingCall()
    bot:set("pathAnswer", result)
end)

-- the hook stays synchronous
update = function(bot)
    local answer = bot:get("pathAnswer")
    if answer == nil then
        return "Running"
    end
    return if answer then "Success" else "Failure"
end
```

This is why `Pathfinding`'s movers are polled rather than awaited: `SetGoal` and
`GetStatus` never block, and the action returns `Running` while the mover works.
Anything expensive you add should follow the same shape.

### When one bot eats the frame

`FRAME_BUDGET` bounds how **many** bots step, not what **one** step costs — and
because the drain always steps at least one bot (otherwise a single expensive bot
would wedge the rotation forever), a step that overruns cannot be prevented here.
So it is reported instead:

```
[Bots] slow step: bot "guard_12" spent 4ms in goal "TakeCover" (FRAME_BUDGET is 2ms)
```

The instinct on seeing a high `stats().seconds` is to lower `FRAME_BUDGET`, which
changes nothing — the overrun happens inside the one step the budget always
allows. The warning names the bot and the goal because the cause is nearly always
something heavy called per *step* that belongs per *goal adoption*: a position
query, a big scan, a fresh target list. Move it into the action's `enter`, or
meter it (`TacticalQuery` takes a shared ray budget for exactly this).

### Determinism

Three things jitter on purpose, and all of them exist to stop a fleet acting in
lockstep: each bot's per-goal personality (`GOAL_JITTER`), its step phase
(`STEP_JITTER`), and each sensor's phase (`PHASE_JITTER`). That is right for a
game and awkward for a test, so the generator is swappable:

```lua
local rng = Random.new(1234)
local simNow = 0
Bots.setRandom(function() return rng:NextNumber() end)
Bots.setClock(function() return simNow end)      -- the SAME timeline you tick with
Bots.Brain.configure({ GOAL_JITTER = 0, STEP_JITTER = 0, PHASE_JITTER = 0 })
-- ...now Brain.tick(simNow) / Brain.step(simNow) replay exactly, run to run.
Bots.setRandom(nil); Bots.setClock(nil)          -- back to math.random / os.clock
```

`setClock` matters as much as `setRandom`. Several APIs take `now` as optional
(`bot:setFact`, `pool:tryClaim`, ...); without the seam those defaults reach for
`os.clock()` while you drive the Brain with a simulated time, and the two are
unrelated numbers. Blackboards additionally prefer the clock they were last
updated with, so a sensor writing a fact during an update is already on the right
timeline with no configuration at all — the seam covers everything else.

A bot's *first* scheduled step is placed at a random phase inside its interval —
that is what actually spreads a fleet spawned in one frame — so zeroing the
jitters is not enough on its own; the seam is what makes scheduling assertable.
Leave all of it at its defaults in production, where spreading the fleet is the
entire point.

### Tunables (`Brain.configure`)

| Key | Default | Meaning |
|---|---|---|
| `TICK_INTERVAL` | `0.2` | Seconds between a bot's sense → plan → act steps, and the cadence for shared board sensors. |
| `FRAME_BUDGET` | `0.002` | Seconds of real frame time `Brain.step` may spend before deferring the rest. Ignored by `Brain.tick`. |
| `PLAN_COMMIT_BASE` | `1.15` | Starting utility multiplier on the running goal. |
| `PLAN_COMMIT_GROWTH` | `0.05` | Bonus growth per second in-goal. |
| `PLAN_COMMIT_MAX` | `1.6` | Growth cap — challengers above the defended score × MAX always win. |
| `GOAL_JITTER` | `0.1` | ± spread of each bot's per-goal personality multiplier (0 = uniform). |
| `STEP_JITTER` | `0.1` | ± spread when rescheduling a bot's next step, so same-interval bots drift apart. |
| `PHASE_JITTER` | `0.1` | ± spread when rescheduling a blackboard sensor, so same-interval sensors stop spiking together. |
| `TRACE_DECISIONS` | `0` | Per-bot decision-trace ring size (`bot:trace()`). 0 = off: nothing recorded, nothing allocated. |

Values are range-checked, not just type-checked: intervals and budgets must be
> 0, jitters fall in `[0, 1]`, and commitment multipliers are >= 1. A negative
`TICK_INTERVAL` would make every bot permanently due and a negative
`FRAME_BUDGET` would stop the drain after one bot — both present as "the
scheduler is broken" a long way from the `configure` call that caused them.

---

## Debugging: `trace` & `explain`

The two answers to *"why is this bot doing that?"*:

**`bot:explain()`** — live, works with tracing off. Re-runs selection scoring
read-only and returns every goal's verdict plus what a challenger must beat:

```lua
local ex = bot:explain()
print(ex.goal, ex.action, ("defended %.2f (base %.2f, live %.2f)"):format(
    ex.defended or 0, ex.baseScore or 0, ex.liveScore or 0))
for _, v in ex.verdicts do
    print(("  %-12s %s%s"):format(v.goal,
        if v.eligible then ("%.2f -> %.2f"):format(v.score, v.weighted) else v.reason,
        if v.running then "  (running)" else ""))
end
-- Attack       0.62 -> 0.68   (running)
-- Investigate  canRun() = false
-- Patrol       0.05 -> 0.05
```

**`bot:trace()`** — the recorded history. Turn on
`Brain.configure({ TRACE_DECISIONS = 32 })` while developing and every
*decision event* (not every tick) lands in a per-bot ring buffer, newest
first: `adopt` / `interrupt` / `complete` / `fail` / `abandon` / `idle`.
Selection events carry a per-goal `scores` map of compact verdicts —
`"0.42 -> 0.46 (picked)"`, `"canRun() = false"`, `"on cooldown 2.1s"` — i.e.
the *why*, captured at the moment it happened:

```lua
for _, e in bot:trace() do
    print(("%.1f %-9s %s%s%s"):format(e.at, e.kind, e.goal or "",
        if e.by then " <- " .. e.by else "",
        if e.action then " @" .. e.action else ""))
end
-- 512.4 interrupt Patrol <- Attack     (score 0.71 beat defended 0.09)
-- 507.1 adopt     Patrol
-- 506.9 fail      Attack @ChaseTarget  (cooldown 3s)
```

Because idle spells record once (not per tick) and everything else is
event-driven, 32 entries typically cover minutes of behaviour. Tracing off
(the default) records and allocates nothing; `explain` is always available.

---

## Helpers

**`Bots.Utility`** — response curves for `score` functions:

```lua
Utility.linear(x, from, to)          -- straight ramp: 0 at `from`, 1 at `to` (from > to = descending)
Utility.quad(x, from, to)            -- eased ramp: stays low near `from`, accelerates toward `to`
Utility.logistic(x, mid, steepness)  -- S-curve threshold: 0.5 at `mid`; negative steepness flips it
Utility.combine(a, b, ...)           -- merge [0,1] considerations (compensated product)
```

---

## Movement (separate library)

Decision-making and pathfinding are **fully separated**: this package contains
no mover, no movement actions, and no pathfinding types. Movement is consumer
territory — your actions drive whatever you put in `bot.body`, and the Planner
only ever sees `Running` / `Success` / `Failure` coming back.

The sibling [`Pathfinding`](../Pathfinding/) library provides the ready-made
pieces: a minimal **`Mover` contract** (`SetGoal` / `GetStatus` / `Stop` /
`Destroy`, with polled status
`Idle | Computing | Moving | Arrived | Stuck | Unreachable`), **`PathAgent`**
(a PathfindingService reference implementation for Humanoid bodies), and
**`Routes`** (authored waypoint helper). Any movement system matching that
contract — grid A*, flow fields, vehicles — plugs into your actions the same
way. See its README for the contract semantics and a worked action example.

---

## The rest of the AI suite

Bots is the decision core of a family of sibling packages, each standalone and
composing by **shape contracts**, never by dependency:

| Package | Gives your bots |
|---|---|
| [`Pathfinding`](../Pathfinding/) | Movement: the `Mover` contract + `PathAgent` — actions drive `bot.body.mover`. |
| [`Perception`](../Perception/) | Senses: vision with awareness-over-time and a hearing bus — host a Vision in a sensor, write facts, `stimulate` on detection. |
| [`TacticalQuery`](../TacticalQuery/) | Positioning: "find cover from the threat" — call queries from your actions. |
| [`HTN`](../HTN/) | Deliberation: multi-step plans discovered at runtime — `HTN.goal(spec)` drops into a normal goal list. |

Each sibling's README carries the exact Bots wiring for its piece.

---

## Legacy

The previous incarnation of this package — a self-contained filler-bot fleet
(avatar template pool, team balancing, top-up/cull, nametags, a built-in melee
policy) — lives untouched in [`Bot_Legacy/legacy/`](../Bot_Legacy/legacy/) with
its own README. It is reference material for rebuilding a fleet layer on top of
this core; nothing in `src/` depends on it.
