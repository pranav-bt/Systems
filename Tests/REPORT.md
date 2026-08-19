# Feasibility report: the AI suite vs three shipped bot systems

**Question asked:** can the AI suite (Bots + Pathfinding + Perception +
TacticalQuery + HTN) recreate the bot behaviors of BuildAndBattle, CastleWars,
and MechBattlegrounds — and if not, what's missing?

**Verdict: feasible, with zero library changes required.** All three games'
decision architectures were recreated as policy modules on the current suite
and verified by **58 headless Lune scenario tests** (18 Mech, 19 Castle, 21
BnB), covering token caps, combo chaining, weight-band arbitration,
commitment-ceiling interrupts, contest rules, failure-score give-up, aggro
re-targeting, kite bands, and commit-to-death semantics. One small library
improvement is recommended (below); nothing was blocking.

Run the evidence: `lune run Tests/tests/test-{mech,castle,bnb}.luau`
(vendored library copies in `tests/vendor/`; policies in `src/` are pure
factories that load unchanged under Lune and Studio).

---

## What each game proved

### CastleWars — proven by construction, upgraded by the new features
The game already runs on an older copy of this exact Bots library; its 4,724
lines of game-side policy are exactly the consumer-land shape the suite
intends. The recreation (`src/castle/`) keeps the source's load-bearing
mechanics verbatim and shows where new suite features replace hand-rolled
machinery:

- **Weight bands** (ExitCastle 50000 → Wander 0.1) and the deliberate
  arithmetic — ClimbLadder 90 > DamageTarget 50 × commitment cap 1.6 — work
  unchanged; the test proves a fresh ladder peels a bot off the door scrum.
- **Ladder claims** (source: hand-rolled 2s-TTL attributes) → `Bots.Tokens`
  pool of capacity 1, ttl 2. Direct replacement, less code.
- **Commander intent flips** (source: SetIntent + abandonGoal) → abandonGoal +
  `stimulate`, so the new intent takes effect the same instant.
- `interruptible = false` exit routes hold through a Survive emergency
  (tested), failure-cooldown-as-design redirects stuck bots (tested), the
  focus-count group sensor converges teammates onto one target (tested).

### MechBattlegrounds — the arbitration and event-timing test
Source: a 60Hz if/elseif chain + a global token arbiter + steering-only orbit
movement. Mapping (`src/mech/`):

- **AIManager's token system → `Bots.Tokens` per target** (2 attack / 2 skill
  / 3 closeness); the closeness pool's ttl=5 replaces AIManager's hand-rolled
  timed release. Tests prove the caps: 5 bots on one player = exactly 2
  attackers, 3 inner-ring orbiters, 1 standoff hoverer.
- **Marker-driven combo chaining → `bot:stimulate({ attackResolved })`**: the
  stimulate re-runs the combat action at marker time, so chains have the same
  event timing the source gets from animation-marker callbacks — not
  next-tick latency. Tested, including the miss-cooldown and token handoff.
- **The 60Hz chain maps to ONE Engage goal's action**, not per-branch goals —
  the same shape CastleWars' own engageStep uses. The suite arbitrates
  *modes* (engage vs ragdoll-cancel vs idle); micro-combat lives inside the
  mode. This is the correct altitude and it's worth stating as a rule.
- **Ragdoll-cancel** = a 1000-band goal interrupting through the normal
  arbiter when the edge-sensed window opens (tested; Easy never does).
- **No pathfinding anywhere**: orbit movement sits behind the Mover contract
  as a steering implementation — the contract never assumed a navmesh.

### BuildAndBattle — the body-agnosticism stress test
Source: monsters are **pure data on a voxel grid** — no Humanoid, no
Instances, custom HPA*, 20Hz fixed tick, token targeting with failure-score
give-up and damage aggro. Mapping (`src/build/`):

- A monster body is `coord + closures`. **Nothing in the Bots core noticed.**
  The suite's "never touches an Instance in its decision path" claim survives
  its hardest test.
- **Voxel movement behind the Mover contract**: grid stepper as
  `SetGoal(coord)/GetStatus/Stop`; `Stuck`/`Unreachable` feed the token's
  failure score exactly like the source's nil-move returns (tested to
  give-up and re-roll, including base-slot release).
- **Damage aggro → `stimulate`** from the damage pipeline; threshold-crossing
  re-target verified.
- **Speedie's commit-to-death** = `interruptible = false` (tested: target
  flees mid-charge, boom anyway). **PyroCaster's three-band kite** with
  hysteresis and LOS-gated volleys reproduced (tested band by band).

---

## Coverage honesty

The template recreates the *decision architectures* and representative
behaviors, not every content variant:

| Game | Recreated | Cataloged only (same patterns, more content) |
|---|---|---|
| CastleWars | 11 of 21 goals incl. every distinct pattern + Commander | Cleric heals/rallies, turrets (manned/field), Regroup, Sneak squads, BuildSiege/Defense — all workObjective/engage/intent variants |
| MechBattlegrounds | Full Regular chain, tokens, difficulty gates, ragdoll cancel | Ultimate/overclock mode, gauntlet wave/modifier scaling (fleet layer), training behaviors |
| BuildAndBattle | Token layer, Normie, Speedie, PyroCaster, structure slots | 22 more archetypes (Flier altitude columns, Healer, bosses' phases) — per-kind configs/actions on the same skeleton |

Fleet layers (avatar pools, wave budgets, top-up/cull, spawner pacing) were
faked, not rebuilt — see gaps below.

---

## Findings: gaps, frictions, recommendations

### Library changes needed: none blocking. One small recommendation — since implemented.
1. ~~**`Brain.stimulate` / `stimulateGroup` hardcode `os.clock()`**~~ —
   **implemented (2026-08-06)**: both (and `bot:stimulate`) now take an
   optional trailing `now`, so out-of-band steps stamp the same simulated
   timeline as `Brain.tick(now)`. The template's policies and tests pass
   their body clock through. (`bot:context`/`explain` still use `os.clock`;
   they are read-only debug surfaces, left as-is.)

### Consumer-land patterns worth codifying (presets material)
The tests caught two subtle policy-authoring pitfalls that any future game
will hit — exactly the kind of knowledge a presets/recipes package should
encode:

2. **Release what you claimed, not what you now see.** Sensors re-target
   between claim and exit; releasing a token against the *current* sensor
   value leaks the original claim (no ttl on attack/skill pools). Pattern:
   pin the claimed ref on the blackboard at claim time.
3. **Event resolutions process before state gates.** Combo markers resolve
   while the body is still in its Attack state; putting the resolution below
   a `state ~= Locomotion` early-return silently breaks chaining.
4. **Micro vs macro altitude rule**: goals arbitrate *modes* (sub-second
   alternatives live inside one action). All three source games converge on
   this shape independently; it should be stated in the Bots README rather
   than left for consumers to rediscover. *(Candidate one-paragraph doc
   addition.)*

### Structural observations
5. **The fleet layer is the genuinely missing package.** All three games
   built one (top-up/cull filler, budget-based waves, gauntlet slots) and
   they share real pieces: spawn pacing/backpressure, count targets, name/
   avatar pools, despawn hygiene. This is the strongest concrete candidate
   for the roadmap's presets phase — now with three real designs to distill
   from instead of speculation.
6. **State-machine-gated bodies** (Mech, BnB) produce recurring
   "return Running unless body is in state X" boilerplate. Tolerable; if a
   third game repeats it, a tiny action-decorator helper earns its place.
7. **Perception / TacticalQuery / HTN went unused** — all three shipped
   games target by radius scan (one raycast in PyroCaster), keep no memory,
   pick no tactical positions, and plan nothing. The suite is a superset of
   what these games needed; those packages exist to raise the bar (stealth,
   cover play, companions), not to reach parity.
8. **Tick rates**: sources tick 20–60Hz but their *effective decision
   cadence* is far slower (move gates 0.08–1.8s, attack cooldowns 1.5s+).
   The suite's 0.2s tick + `stimulate` for edges covered everything; true
   per-frame work (orbit slowdown, skill re-aim) belongs in the body/mover —
   where the sources put it too (Humanoid:Move per frame).

### Bottom line
The suite carried all three games' bot behaviors without modification, the
new features (Tokens, stimulate, interruptible, facts infrastructure)
replaced hand-rolled equivalents in every game, and the exercise produced a
concrete, evidence-backed next step: **distill the fleet layer + the four
policy-authoring patterns above into the presets package.**

---

## Onboarding: entry points for reading the suite

Every package follows the same deliberate reading pattern:
**README → `src/Types.luau` → one core module whose header comment is a
mini-spec.** Types.luau carries the whole mental model as documented
contracts; the core module carries the semantics. Nothing important hides in
the remaining files.

Recommended cross-package order (each builds on the previous one's ideas):

| # | Package | Read, in order | The one idea to get |
|---|---|---|---|
| 1 | **Bots** (the hub) | README → `Types.luau` (Action/Goal/Bot contracts) → `Planner.luau` (selection / commitment / execution — the heart) → `Brain.luau` (heartbeat, stimulate) → `Blackboard.luau` (sensors + facts) → `Tokens.luau` | Utility-scored goals arbitrate MODES; actions do the work; everything else feeds them data |
| 2 | **Pathfinding** | README → `Mover.luau` (~30 lines — the whole idea) → `PathAgent.luau` only if you need the reference implementation | Movement hides behind a 4-function contract; anything Mover-shaped plugs in |
| 3 | **Perception** | README quick start → `Types.luau` (TargetPerception/VisionReport) → `Vision.luau` (the 4-stage pipeline header) | Detection is awareness ACCUMULATING over time, not a binary raycast |
| 4 | **TacticalQuery** | README → `Types.luau` (Probes/Generator/Test) → `Engine.luau` (generate → cheap → budgeted expensive → validate) | All world geometry enters through one injectable Probes table |
| 5 | **HTN** | README (campfire example end-to-end) → `Types.luau` (planning-half vs runtime-half split) → `Planner.luau` (decomposition + trace) → `Execution.luau` (monitor/replan) | The planner SIMULATES declared effects forward; execution monitors and replans; utility arbitration stays above |

For this temp project: `DESIGN.md` (per-game mappings) → this report → any
one policy in `src/` (they share the same factory shape) → its test file.
