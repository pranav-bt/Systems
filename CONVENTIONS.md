# Conventions and maintainer notes

The working rules for this repo. The project overview is in [README.md](README.md).

Standalone, reusable Roblox packages. Each folder is a self-contained package: it requires
nothing outside its own folder except declared Wally packages.

Two lineages live here:

- **Rebuilt from CastleWars game systems** (Zone, Nametags, Heatmap, TimeSync, LagCompensation,
  Placement) — turned into standalone packages by replacing game-specific coupling with injected
  config / callbacks or self-provisioning, without modifying the game itself. The packaging
  conventions below apply to these.
- **The AI suite, designed as packages from scratch** (Bots, Pathfinding, Perception, TacticalQuery, HTN) — five
  zero-dependency packages composing by shape contracts, not requires. Decision cores are pure
  (no Roblox APIs) and Lune-tested; these ARE formatted with stylua and linted with selene.
  To learn them, read in that order (Bots is the hub); every package follows the same reading
  pattern — **README → `src/Types.luau` (the contracts ARE the mental model) → one core module
  whose header comment is the spec** — and each README's "Reading the source" note names that
  core module.

## Packaging conventions (CastleWars packages)

- **Injection over globals** — anything a library used to reach for (schedulers, loggers, latency,
  place IDs, voxel grids, catalogs) is now a config field with a sensible default, so each library
  works out of the box and can be wired to a host game's systems when needed.
- **Own your transport** — networked libraries create/accept their own RemoteEvents instead of
  assuming a central registry exists at boot.
- **Behavior preserved** — only the specified coupling points were changed; core logic (especially
  the lag-comp geometry) is byte-for-byte identical to the in-game version. `--!strict`/`--!native`
  pragmas were preserved where present.
- Formatting was intentionally **not** run through stylua/rojo (the game's own toolchain handles that).

## Libraries

| Library | Realm | Wally deps | What it does |
|---|---|---|---|
| **Companions** | server | none | Pet/companion system: declared content, per-pet tick hooks, a collection where ownership is a count per LEVEL, and a loadout of identified slots. Server-owned rigs replicated to everyone. No combat, no UI, no in-run levelling -- raising a level is what the Merge and Upgrades addons are for. |
| **CompanionsMerge** | server | none | Opt-in addon over Companions: duplicates merge into stronger copies at N! pulls a level (2 x lvl1 -> lvl2, 6 x lvl5 -> lvl6). Owns no level and no stats -- a policy over the base's `moveCopies`. |
| **CompanionsUpgrades** | server | none | Opt-in addon over Companions: pay to raise a level. Currency injected, charge-before-move, installable alongside CompanionsMerge without the two fighting over the level. |
| **Trading** | server + client + shared | none | Player-to-player trading: the invite/offer/ready/countdown session, with what may be swapped and the swap itself injected. Any offer change clears both agreements; lines are totalled by key so duplicates cannot slip past a per-line check; the swap is one atomic call that must re-validate. |
| **Levelling** | server + client + shared | none | A permanent player level earned through ONE door. Every XP source hands over a BASE amount; a named multiplier stack (gamepass x rebirth x event, composed by product) is applied here and nowhere else, to the amount and to the per-second tempo alike. Profile storage injected, level/experience published as Player attributes, and a client half that coalesces the two writes into one honest change. No stat table -- what a level is worth is a number the host reads. |
| **LevellingRebirth** | server + client + shared | none | Opt-in addon over Levelling: trade the level you have for a permanently faster one. The ladder is one table and validated on install; the request carries NOTHING, so a forged call is indistinguishable from a real one; the host's own state refuses through a gate. Composes with the base by shape, and pays in an XP multiplier plus an opaque rewards payload. |
| **CommunityReward** | server + client | none | Verify a player is in a Roblox group, then pay them once, ever. Live `GroupService` membership rather than the cached `IsInGroup`, a one-time profile flag written before the grant, and the reward itself injected -- the only thing the two games it started in disagreed about. Ships no copy. |
| **Zone** | server | none | Subject-in-volume detection (rotated box / cylinder / sphere), enter/exit events. Watches named populations -- players by default, or bots/vehicles/anything with a position resolver -- with sets maintained by signal rather than polled. One shared Heartbeat for every zone, cached bounds with a broad-phase reject, and a cached HumanoidRootPart per player. |
| **Nametags** | server | none | Team-colored overhead BillboardGui nametags; hides own, keeps health bar, recolors on team change. |
| **Heatmap** | server | none | Anonymized player-movement voxel heatmap, RLE-compressed to a DataStore. Flushes on a timer as well as at shutdown, keeps the batch queued when a write fails instead of discarding it, and rotates its key so a value cannot grow past the 4MB limit. |
| **TimeSync** | server + client | none | Per-player round-trip latency measurement (rolling average). Pairs with LagCompensation. An echo is only believed if it carries a value the server actually sent, and that value is consumed on use -- so a client cannot name its own latency, replay a ping, or flood the sample window. |
| **LagCompensation** | server | none | Server-authoritative rewind/snapshot hit-validation core (claim ∩ verify). The flagship. Pose history in a ring buffer on the engine-synced clock, interpolated between samples; claims bounded in both directions (stale beyond `MAX_REWIND`, ahead beyond `FUTURE_SLACK`) and capped by a per-key token bucket. The line-of-sight filter is cached and invalidated on join/leave/respawn rather than rebuilt per raycast; hitbox extents are cached on first sight with `RefreshExtents(character, size?)` for a character that genuinely changes shape. |
| **Placement** | server + client + shared | `nezuo/spark` | Free-form structure placement: grid-snapped preview ghost + server validation. |
| **ObjectPool** | any | none | Instance reuse. One pool per template (an object, not a singleton keyed by string), with the release strategy injected -- unparent, park out of sight for particles whose warm-up must survive, or disable in place. Explicit cap policy (grow / steal-oldest / nil), warm-up, and a `release` that no-ops on a foreign or double release rather than crashing. |
| **Bots** | server | none | Generic, body-agnostic agent brain: blackboard sensing + decaying working-memory facts, utility goal selection with commitment, sequenced actions with guaranteed exits, squad token pools, per-bot tick pacing under a budgeted per-frame scheduler, out-of-band `stimulate`. |
| **Pathfinding** | server | none | Movement behind two tiny contracts: `Mover` ("go to this position" -- `PathAgent` is the PathfindingService implementation) and `RouteFollower` ("walk this list" -- authored waypoints with raw MoveTo, no navmesh), authored via `Routes`. A shared `Paths` broker bounds concurrent navmesh computations, ages the queue so none starve, and cancels work a moved goal invalidated. Pairs with Bots; depends on nothing. |
| **Perception** | server | none | AI sensing: vision with awareness-over-time (FOV + LOS + None/Suspicious/Detected ladder), occlusion-aware hearing stimulus bus, token-bucket raycast budgeting that freezes unsampled targets instead of guessing at them. |
| **HTN** | server | none | SHOP-style hierarchical task network planner: domains with priority-ordered methods, forward effect simulation with backtracking + decomposition trace, plan monitoring/replanning. Ships a Bots-shaped goal adapter (no dependency) and a standalone runner. Zero Roblox APIs. |
| **TacticalQuery** | server | none | EQS-style position queries ("find cover from the threat"): candidate generators + weighted tests (LOS/distance/spacing/reachability) over an injectable world-probe surface, with every probe in a run bounded and an in-world visualizer for the scored field. |

Each library's `README.md` documents its public API and a complete usage example (plus, for the
packages that started in a game, the configuration/injection points and exactly what changed on
the way to a package).

### Parked

`Temp/` is gitignored and holds libraries kept locally rather than published, with their tests
beside them. Nothing in it ships, and the suite in [`Tests/`](Tests) never references it — a
published test that loads an unpublished library is a suite that fails on a fresh clone.

- **Matchmaking** (server) — cross-server MemoryStore queue with leader election, teleport
  hand-off and backfill. **Superseded by `neurealroblox/matchmaker`** and its family
  (`leader-election`, `regions`, `session-router`, `skill-rating`), which this repo's consumer
  games already depend on through `server-bundle`.

  Compared against the real source, not the registry blurb: every capability ours has, theirs
  has — including the two I expected to be ours alone. `session-router` backfills into live
  servers and packs into *the fullest with room*, a better policy than our first-with-space;
  and both queues TTL-self-heal a crashed server's entries. Theirs additionally has
  rating-based matching (expanding windows gated by accumulated wait), rating-balanced teams
  and a skill-rating package, none of which ours has at all. Ours also shipped with its
  headline region sharding **disabled** behind `TEMP` comments.

  Genuinely only ours, and worth remembering if it ever comes back: a **variable batch size**
  (`MIN_PLAYERS`…`MAX_PLAYERS` with a `GRACE_SECONDS` window) rather than a fixed `matchSize`,
  and party grouping by originating `JobId` so lobby-mates land together. Both are expressible
  through their `onMatchFormed` — a config on their matchmaker, not a second library.

- **Moveables** (server + client) — authored objects follow waypoint paths (ping-pong + stops)
  and carry riders standing on them. Tested and correct (19 checks, `Temp/test-moveables.luau`),
  parked pending a decision on whether it earns a slot. Two things to weigh if it comes back:
  the client raycasts and rebuilds its `RaycastParams` every frame and walks *every* tagged
  moveable rather than only the ridden one; and the path is **ping-pong only**, so a game
  wanting a looping patrol has to fork it. The genuinely valuable part is the rider carry —
  translating the character client-side, because it stays client-owned, so it rides without
  rubber-banding.

## Tests

[`Tests/`](Tests) is the repo's headless suite, and **any library change belongs with tests
there.** Everything runs under Lune from this directory — no Studio, no Rojo, no place file:

```
lune run Tests/tests/test-zone.luau
```

1485 checks at present. See [`Tests/README.md`](Tests/README.md) for the full list, and for how
the loader runs each library's real source (vendored test copies are gone and must not return).

## Notes per library

- **LagCompensation** — the two internal modules became `.new(deps)` factories. Inject a
  `getLatency(player)` callback (TimeSync provides exactly this), a logger (default no-op), NPC /
  LOS-exclude folder-name lists, and a `isDamageable` predicate. Self-ticks its snapshot loop on
  `RunService.Heartbeat`. Some `LagCompConfig` tunables are caller-side tuning (padding, rate
  limits) that the host applies when building attack volumes — the core doesn't read them; the
  README lists which keys are core-read vs. carried.
- **TimeSync + LagCompensation** compose: `LagCompensation.new{ getLatency = timeSync.getLatency }`.
- **Placement** — grid is abstracted behind an injectable interface (`positionToCoord` + `voxelSize`)
  with a `DefaultGrid` fallback; the item catalog lives in `src/shared/ItemDefinitions.luau` and the
  models source is an injected `Folder`. Server self-provisions its `PlaceItem` remote + collision
  groups. Ships a `default.project.json` because it spans client/server/shared. Carries a few
  documented known port-bugs (delete-path `table.remove` misuse, a `calculateOffsetFromCollider`
  stub) flagged but not silently altered — see its README "Known issues".
- **LagCompensation** — `RefreshExtents(character, size?)` re-reads a character's hitbox size.
  Extents are cached on first sight because `GetExtentsSize` walks the whole model, and doing
  that 20×/second per character to answer a question that almost never changes is pure waste —
  but a character that *does* change shape (R6↔R15, a size powerup, a vehicle seat) would
  otherwise keep the box it had when first recorded, and every later hit would be validated
  against the wrong volume. It is explicit rather than automatic because there is no reliable
  signal to watch: extents move from a scale, a limb swap, an accessory or a humanoid
  description, and which of those counts as "a different size now" is a game's judgement.
  Pass `size` when the caller already knows it and the model walk is skipped entirely.
- **Matchmaking** — inject `resolveTargetPlaceId()` and `keyPrefix`; wire your own remotes to
  `joinQueue` / `exitQueue` and push status via the `onStatus` callback (or pull `getStatus`).
  Region sharding ships disabled (single shard) exactly as in the original.
- **ObjectPool** — replaced `SharedUtils` (removed Aug 2026), which was a namespace rather than a
  library: nine unrelated modules of very different quality, none of them consumed anywhere in this
  repo, none of them ever tested. Testing it turned up 11 bugs, a module that could not be required
  at all without a Wally `Promise` that was never vendored, and a pool that created a Folder in
  `workspace` **at require time**. Its two pools were unified here; `Collision`'s geometry moved
  into `Zone.query`, where the same maths already lived and was already tested. The rest was
  deleted: `Cleanup` was a worse Maid than Trove/Janitor already on Wally, `Scheduler` was a thin
  `Connect` wrapper with none of the budgeting that makes a scheduler worth having (Bots and Zone
  both contain better ones), and `Spring` is Quenty's, available upstream.
- **Bots** — rebuilt (Aug 2026) from the original filler-bot fleet into a generic agent brain with
  **zero** assumptions about what a bot physically is: the consumer supplies a free-form `body`,
  sensors, goals, and actions; the library supplies selection, commitment, execution, and error
  isolation. Movement was evicted entirely into the sibling **Pathfinding** package (the `Mover`
  contract + `PathAgent`). The previous fleet implementation is archived untouched in
  `Bot_Legacy/legacy/`. `Brain` schedules rather than batches: each bot carries its own phase and
  every frame drains whoever is due under a time budget, with a cursor that persists across frames
  so overload makes bots *late*, never starved (`Brain.stats()` reports what got deferred).
  `Brain.tick` remains the unbudgeted, clock-injectable path the headless tests drive. Hooks must
  NOT yield -- they run inside the drain, and a yield there is refused and counted
  (`Brain.stats().reentered`) rather than silently corrupting a step. `Brain.reset()` clears the
  fleet for round transitions and tests, and `Bots.setClock` / `Bots.setRandom` make a headless run
  reproducible. See the package README for the full contract.
- **Perception** — awareness is only ever moved by *evidence*. A dry raycast budget freezes the
  targets it couldn't sample (flagged `stale`) rather than integrating off carried visibility, which
  would fill a target that has ducked behind cover all the way to `Detected` and decay one standing
  in plain view; rays go to the longest-unsampled candidate first so a busy fleet can't go blind to
  newcomers. Detection edges surface as `report.events` so a host can publish the report *before*
  reacting to it — reacting from inside the sensor re-plans against the previous update.
  Hearing meters itself the same way, but answers starvation differently: a refused occlusion ray
  means the listener HEARS the sound, because going deaf under load is worse than occasionally
  hearing through a wall. It also skips rays that cannot change audibility at all, filters by
  listener `kinds`, and takes a per-emit `audience` so a shot never costs a ray for the shooter's
  own team.
- **TacticalQuery** — the engine is pure (positions are opaque; Lune-testable) and all world
  geometry goes through one injectable `Probes` table (raycast / snapToGround / isReachable), so
  non-standard worlds swap ~30 lines, not the package. Wire a character-exclusion `RaycastParams`
  into `Probes.new` at startup or LOS tests will read bodies as cover. Grounding happens after the
  cheap tests rather than in the generator, so EVERY probe a run spends is bounded by `maxExpensive`
  / `topK` — a 169-candidate grid costs ~32 probes, not ~185. A starved shared budget makes a query
  ABSTAIN (`budgetStarved`) rather than commit to a half-probed field, since a position is lived
  with for seconds. `Debug.draw` renders the scored field in-world for weight tuning.
- **Pathfinding** — two capabilities, not one: `Mover` answers "go to this position", and
  `RouteFollower` answers "walk this list" with raw `MoveTo` and no navmesh at all — for spawn exits
  and designed patrols that a navmesh would smooth away. A bot can hold both (`body.mover` and
  `body.route`) and hand off between them. `PathAgent` SLEEPS while parked at its destination --
  no computes and no polling -- so holding a post is genuinely free, and every computation it does
  make goes through the shared `Paths` broker rather than straight to PathfindingService.
- **HTN** — `replanLimit` bounds CONSECUTIVE replans: completing a step refunds the budget, so a
  plan that adapts to four separate world changes is not punished like one that thrashes on the
  same step four times. The decomposition trace is capped (`traceLimit`, default 64; `0` disables),
  and `maxExpansions` (default 2000) bounds how many BRANCHES a decomposition explores — which
  `maxDepth`/`maxSteps` never did.

## Installing (per package that has a `wally.toml`)

```
cd <LibraryFolder>
wally install
```

This populates a `Packages/` folder that the package-relative requires resolve against.
