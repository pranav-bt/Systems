# CLAUDE.md

Notes for Claude Code (and anyone using AI) in the libraries repo.

**Conventions live in [README.md](README.md)** — extraction rules, per-library
notes, the Lune test suites in [Tests/](Tests), and which packages are formatted
with stylua/selene (the AI suite is; the CastleWars extractions deliberately are
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

Raised while building on these libraries. Neither is urgent; both are recorded
here so the reasoning is not lost, and so whoever picks one up knows what the
consumer already tried instead.

### 1. `Blackboard:invalidate(key)` — Bots

**Ask:** mark a sensor as due, so the next board update recomputes it once.

**Why.** A blackboard value that is *derived* but changes on an **event** has no
good home today. `addSensor` polls it on a timer (a wasted lap per interval, plus
up to one interval of staleness), and `set` pushes it (correct, but every caller
must debounce its own bursts, and the recompute happens outside the board's
update rather than inside it). `nextAt` is private, so a consumer holding "the
thing changed" cannot ask the board to refresh a sensor without duplicating the
read closure.

Invalidation is the standard shape for this — dirty flag, lazy recompute — and it
composes with what the board already does:

- **Coalescing.** 50 stations tagged in one frame become one rebuild, not 50.
- **Recompute stays inside the drain**, where sensor reads belong, so a shared
  list cannot be rebuilt while a bot is mid-read of it.
- **No new failure mode.** A `manual = true` flag on `addSensor` was considered
  and rejected for the opposite reason: put it on something that *does* change and
  you get a permanently stale board with no symptom.

**Shape.** Three files, additive, no default behaviour change:

| File | Change |
| --- | --- |
| `Bots/src/Blackboard.luau` | `function bb.invalidate(_, key) local s = sensors[key]; if s then s.nextAt = 0 end end` |
| `Bots/src/Types.luau` | one line on the `Blackboard` type (methods are part of the typed surface) |
| `Bots/README.md` | the `addSensor`/`removeSensor` bullets and the API summary |

Worth a `Tests/` case: invalidate → next `update` recomputes exactly once, and an
un-invalidated sensor with a long interval does not.

**Status: not needed yet.** The consumer's case (a list of workable stations
published to the master board) turned out to be better solved by not recomputing
at all — the owning system maintains the array as it changes and pushes with
`master:set`. `invalidate` earns its place for the *next* derived value that is
genuinely expensive to rebuild and changes on an event; it should not be added
speculatively.

### 2. `Costs` / `Label` support in `PathAgent` — Pathfinding

**Ask:** let `PathAgent.Options` carry `PathfindingService` costs, i.e. pass
`Costs = { [label] = number }` through to `CreatePath` alongside the existing
agent parameters.

**Why.** Without it there is no way to tell the navmesh to *avoid* something that
is technically walkable. The consumer hit this on furniture: a crafting table with
flat collidable parts ~3 studs up is a platform as far as `PathfindingService` is
concerned, so a path across the room goes over the table. The waypoint sits a stud
above the floor, an R6 humanoid cannot step onto it, and the agent wedges —
reporting `Moving`, position frozen, stall detection never firing because each
repath produces the same route and resets it. Diagnosed from the game side; the
mover behaved correctly given the path it was handed.

`PathfindingModifier` + `Costs` is the engine's answer to exactly this, and it is
the one part of `CreatePath` the options table does not expose.

**Shape.** `Pathfinding/src/PathAgent.luau` — one option field, threaded into the
`CreatePath` call in the compute closure, plus the options table in the README.
The `Label` half is authored on Instances in the game, not here.

**Consumer workaround meanwhile:** an invisible blocker taller than `agentHeight`
over the model's footprint, so the navmesh routes around instead of over. Pure
level authoring, no code — which is why this is a nice-to-have rather than a bug.

---

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
