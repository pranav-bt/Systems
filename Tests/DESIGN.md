# temp: unified bot template — design notes (working doc)

Goal: recreate the bot behaviors of BuildAndBattle, CastleWars, and
MechBattlegrounds in ONE template project built on the AI suite (Bots,
Pathfinding, Perception, TacticalQuery, HTN), to test the suite's feasibility.
Projects are read-only; everything here is throwaway/test.

Verification strategy: decision logic runs headless under Lune with fake
bodies/movers (the suite's cores are pure); Studio-facing body code is written
but exercised only by review.

---

## MechBattlegrounds → suite mapping (report received)

Source architecture: Dummy fake-players piloting real mech rigs; per-Heartbeat
prioritized if/else chain gated by a character state machine; steering-only
movement (orbit slots, no pathfinding); AIManager token arbiter; difficulty
gates capabilities.

| MechBattlegrounds mechanic | Suite recreation |
|---|---|
| Priority chain (skill > dash > block > attack > closeness > orbit) | Utility goals in descending score bands; gates become `canRun`/score guards. One `Engage` goal owns the in-combat sub-decisions as its action (the chain is reactive micro-combat, not plan-shaped) |
| AIManager tokens (2 attack / 2 skill / 3 closeness per player, 5s closeness auto-release) | `Bots.Tokens` pools **per target player** stored on the master/group board; closeness pool with ttl=5 |
| Orbit slots (8 slots, 20/70 radii, 10s re-roll, slowdown near point) | Steering mover: the Mover CONTRACT (SetGoal/GetStatus/Stop) implemented as a steering `OrbitMover` in template code — proves contract genericity (no PathfindingService) |
| Least-subscribed target selection (`findUniqueTarget`) | Sensor computing target load from a shared board registry; no LOS by design (matches source) |
| Combo chaining on animation markers, miss cooldown | `bot:stimulate({ attackLanded = ... })` from the marker event; combat action reads it |
| Difficulty gates (Easy/Normal/Hard capability table) | Per-bot blackboard values + goal `canRun` guards; cooldowns as values |
| Ragdoll-cancel dash (Normal+) | State-change event -> `stimulate`; high-score `RagdollCancel` goal, `canRun` = ragdolled && dashReady && windowOpen |
| Ultimate/overclock (timed buff, skill-set swap, 1/s drain) | Timed blackboard state + sensor; skill selection reads it |
| Gauntlet waves/modifiers/rebalancing | Fleet layer (consumer land): thin Wave module in template; rebalance = recompute target assignments + `stimulateGroup` |
| Area leash | Sensor: outside area -> return-home goal (or target invalid) |

Notable: source has NO perception model (table-lookup targeting) — Perception
lib not required for this archetype; used for the others.

## CastleWars → suite mapping (report received)

KEY FACT: the game ALREADY runs on an older copy of this exact Bots library
(pre-Tokens/Facts/tracing) + the same Pathfinding library. Feasibility for
this archetype is proven by construction; the recreation demonstrates the
game-side policy shape on the NEWER suite and shows where new features
(Tokens, Facts, stimulate, tracing) replace hand-rolled equivalents.

| CastleWars mechanic | Suite recreation |
|---|---|
| 21 goals in weight bands (ExitCastle 50000 ... Wander 0.1); bands spaced so jitter/scores can't cross; ClimbLadder 90 > DamageTarget 50×1.6 commitment ceiling | Same pattern verbatim — representative subset: ExitCastle(interruptible=false), Survive, FightPlayer, DefendHome, ClimbLadder, DamageTarget(door-first), BuildTower, RazeBase, KillEnemy, AttackEnemyCastle, Wander |
| Commander (5s per-team strategist: Defend/Sneak/BuildTowers/Attack intents, emergency=base losing HP, all-in rule, 25s min hold) | Template Commander module writing `intent` + `Brain.stimulateGroup` on emergency (replaces SetIntent+abandonGoal hand-wiring) |
| focusCounts group-board sensor (+0.35 target score if teammate engages) | Group blackboard sensor, same formula |
| Ladder claims via 2s-TTL attributes (BotClimber/Until) | `Bots.Tokens.new("ladder", 1, 2)` per ladder — direct replacement |
| Scored target pick (closeness + wounded + isPlayer + focus) @0.2s sensor | Same sensor formula; lastSeen memory upgrade available via Facts (not in source — no LOS anywhere) |
| Contest rule (enemy within 18 makes build goals ineligible + aborts) | canRun guard + action Failure — same |
| Door-vs-ladder rule (build ladders while doorFrac>=0.5; climb until breached; door always wins nearestDamageable) | Sensor + objective provider logic, same |
| Two movement systems (navmesh Mover + raw-MoveTo RouteWalker for navmesh islands) | Pathfinding.PathAgent + template RouteWalker vs the Mover contract; template fake movers under Lune |
| Fleet: top-up/cull to TARGET_TOTAL-players, team balance, avatar pool, nametags, respawn 10s, stuck watchdog, regen | Template Fleet module (consumer land) — thin version |
| Match gating (tick only while Active, Freeze on edge) | Brain.tick from own scheduler — supported (manual tick) |
| Skills table (slot-order first-rule-fires per class) | Skill picker inside engage action, same |
| Difficulty handicaps (aim error, reaction delay, skill level 1) | body capability parameters |

Suite features the game hand-rolled that the new library now provides:
tokens (ladder claims), facts (none used — candidate upgrade), stimulate
(SetIntent's abandonGoal+instant-replan), tracing (none — they debugged blind).

## BuildAndBattle → suite mapping (report received)

Source: monsters are pure data structs on a voxel grid (NO Humanoids, NO
Instances, custom HPA*, 20Hz fixed tick); two-layer split: token system
(target arbitration: create / failure-score give-up at 10 / damage-aggro
re-target) + per-kind hardcoded behavior closures gated by a 5-state machine.

| BuildAndBattle mechanic | Suite recreation |
|---|---|
| Monster = coord + closures | body table of closures — body-agnosticism stress test (passes) |
| Token layer (create/give-up/aggro) | "token" sensor owning the lifecycle; failure scores on the token record; damage → policy.onDamaged → stimulate |
| Voxel stepping + HPA* + step gate | grid Mover behind the Mover contract; Stuck/Unreachable feed failure score |
| 5-state machine gate | actions early-return unless Locomotion (Mech pattern) |
| Speedie charge-and-detonate commit | interruptible = false goal |
| PyroCaster 3-band kite + LOS volleys | band logic in the engage action, hysteresis + cooldown on blackboard |
| Structure slots (claimed base coords) | objectives provider claim/release (release on token give-up) |
| Waves/budget/mutations/bosses | fleet layer (consumer land; faked in tests) |

## Status: COMPLETE — see REPORT.md

All three archetypes built (src/mech, src/castle, src/build) and verified:
58/58 Lune scenario tests (tests/test-{mech,castle,bnb}.luau, vendored
library in tests/vendor). Feasibility verdict + gaps in REPORT.md.

---

## Template shape (draft)

```
Tests/
  DESIGN.md                this file
  REPORT.md                feasibility findings (final deliverable)
  src/
    shared/                cross-game pieces
      SteeringMover.luau   Mover-contract steering implementation (orbit/direct)
      Fleet.luau           minimal spawn/top-up/teams (consumer-land recreation)
      TargetRegistry.luau  who-targets-whom load balancing (shared board value)
    mech/                  MechBattlegrounds archetype
      MechBot.luau         goals/actions/sensors + difficulty table
    castle/                CastleWars archetype
      SiegeBot.luau        survive/fight/wander + siege objectives (+routes)
    build/                 BuildAndBattle archetype
      ???
  tests/
    (Lune) scenario tests per archetype driving Brain.tick with fake bodies
```

Open questions for feasibility report:
- Anything requiring per-frame (60Hz) decisions the 0.2s tick can't honor?
  Mech chain runs at 60Hz in source; template maps micro-combat into a
  Running action's update (ticks at Brain rate) + stimulate for edges. Assess
  whether TICK_INTERVAL needs lowering per-bot (tickInterval works both ways).
- Movers: suite assumed pathfinding-ish movement; Mech proves steering — does
  the Mover contract suffice? (SetGoal/GetStatus semantics for orbit points.)
