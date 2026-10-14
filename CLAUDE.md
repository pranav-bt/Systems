# CLAUDE.md

Notes for Claude Code (and anyone using AI) in the libraries repo.

**Conventions live in [CONVENTIONS.md](CONVENTIONS.md)** — packaging rules, per-library
notes, the Lune test suites in [Tests/](Tests), and which packages are formatted
with stylua/selene (the AI suite is; the packages rebuilt from CastleWars deliberately are
not). Read it first; this file only covers what it does not.

---

## This repo is upstream of games that vendor it

Consumer games copy a **snapshot** of a library into their own tree rather than
depending on it live. `CompanionAutomation` (`../CompanionAutomation`, working dir
`../PetAutomation`) vendors `Bots`, `Pathfinding`, `HTN` and `Zone`, pulls them
with its own `lune run lune/sync-libraries`, and records the commit it took them
from in its `Libraries/vendored.json`.

Two consequences:

- **A fix has to land here first.** Editing the copy in a game is lost the next
  time that game re-syncs, silently. Games are told not to do it; the flip side is
  that this repo is the only place a real fix can be made.
- **A behaviour change here reaches games as an upgrade they read.** Keep the
  READMEs honest about semantics, not just signatures — the last Zone upgrade
  changed sweep *timing* (phase spreading), which no API diff would have shown.

---

## Requested changes from consumer games

Both requests recorded here were **implemented on 2026-08-25**. Kept as a record of the
reasoning, and because each turned up something the request itself did not mention.

### 1. `Blackboard:invalidate(key)` — Bots — **done**

Marks a sensor due, so the next board update recomputes it once. Returns `false` for a key with
no sensor, so a misspelled key is visible rather than silent.

The case it exists for: a derived value that changes on an **event** had no good home. A sensor
with an `interval` polls it — a wasted read every lap, plus up to one interval of staleness —
and `set` pushes it, which is correct but moves the recompute outside the update and makes
every caller debounce its own bursts. Invalidation composes with what the board already does:
bursts coalesce into one rebuild, and the read stays *inside* the drain, so a shared list
cannot be rebuilt while a bot is mid-read of it.

A `manual = true` flag on `addSensor` was considered and rejected for the opposite reason: put
it on something that *does* change and you get a permanently stale board with no symptom.

**"Due" is spelled `-math.huge`, not `0`** — and writing the test for that found a **pre-existing
bug**. `addSensor` initialised `nextAt = 0`, so on a clock whose values are negative (the clock
contract only promises *monotonic*, and a game may run on its own epoch) `now >= 0` is false and
the sensor **never fired once** — breaking the promise in Blackboard's own header that the first
read always runs. Identical behaviour on any clock starting above zero, which is why it went
unnoticed. Fixed in the same change.

`Tests/tests/test-bots-blackboard.luau`, 30 checks.

### 2. `Costs` in `PathAgent` — Pathfinding — **done**

One option field, validated at construction and threaded into every `CreatePath`. The `Label`
half is authored on Instances in the game, as always.

Left **nil** when unset rather than defaulted to `{}`, so an agent naming no costs hands the
engine exactly the params it handed it before the option existed. Read at every `CreatePath`
rather than captured once, so the adaptive-spacing rebuild keeps them — an agent that forgot
its costs the first time it stalled would path straight over what it had been avoiding.

The consumer's level-authoring workaround (an invisible blocker taller than `agentHeight`) is
still the right answer for a hard "never go here" on hand-placed geometry, and the README says
so. `costs` earns its place when the thing should be *discouraged*, or when the geometry is
player-authored and cannot be blocked by hand.

`Tests/tests/test-pathfinding-costs.luau`, 22 checks, over a new `PathfindingService` recorder
in the shim that captures what was asked for — an option that never reaches `CreatePath` looks
exactly like one that works.

### 3. Pathfinding broker + SetGoal drift, LagCompensation facade — Heat — **done** (2026-10-01)

Found while vendoring the AI suite into Heat (`../Heat`, a GTA-style game whose police will
chase), all three by reading the code, each now with a regression test that fails on the old
source:

- **A queued request cancelled was never answered** (`Paths.luau`). `pump` dropped it silently;
  `PathAgent` suspends on its request until `onComplete`, so an agent whose goal moved while all
  `maxConcurrent` slots were busy froze for good, reporting `Computing`/`Moving` (and no action
  times out by itself). Every request is now answered exactly once: `cancel` takes a queued entry
  off the queue and delivers `{ cancelled = true }` via `task.defer` — never synchronously,
  because the canceller is usually the code the answer resumes; `reset` does the same for every
  entry it drops. `Tests/tests/test-pathfinding-broker.luau`, 37 checks.
- **`SetGoal` cancelled on any move > 1e-3** (`PathAgent.luau`), not the `repathThreshold` the
  walk uses. A chaser re-setting a shuffling target cancelled and re-queued every tick, losing
  its queue age each time — under load it never got a path. It now cancels only when the new goal
  is past `repathThreshold` from the goal being computed (`computingFor`); `Stop`/`Destroy`
  still always cancel. Same test file.
- **`InvalidateLineOfSightFilter` was unreachable** (`LagCompensation/src/init.luau`): defined on
  Rewind (whose tests called it there) but missing from the table `LagCompensation.new` returns.
  `Tests/tests/test-lagcomp-facade.luau` asserts the whole public table, 24 checks.

### Fallout worth keeping: `Tests/tests/vendor/` is gone

The archetype suites ran against **copies** of `Bots/src`, because the loader could not resolve
`require(script.Parent.X)`. It can now, so `harness.luau` loads the real source and the copies
are deleted.

This was not a tidy-up. The `nextAt` fix above landed in both the real file and the copy, and
the mutant that reverted **the copy** survived every archetype suite — a live demonstration of
the drift hazard the Tests README had warned about in the abstract. Do not reintroduce vendored
copies; if a package will not load, fix the loader.

## Deliberate non-changes

Both came up as "shouldn't the library do this?" and the answer was no. Recorded
so they are not re-litigated:

- **No action timeout in `Bots`.** An action that returns `Running` forever runs
  forever, and commitment/cooldowns only apply when a goal *ends*. That is correct:
  "too long" is behaviour-specific — a thirty-second walk across a map is fine, a
  thirty-second swing is a bug — and only the caller can tell them apart. The
  consumer wraps actions in its own deadline decorator.
- **`Zone.new` parenting its part to `workspace`.** A game that wants zone parts to
  stay where they were authored (inside the model they describe, or in a folder)
  can set the parent itself immediately after construction; the cache holds because
  a `Part` keeps its world `CFrame`/`Size` across a reparent, and the sweep only
  requires *some* parent. Wrapping is the right layer for a game's scene-layout
  preference.
