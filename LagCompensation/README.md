# LagCompensation

Server-authoritative lag-compensation / rewind core for hit validation in Roblox.

## Overview

The client predicts and claims what it saw (WYSIWYG). The server re-derives the
truth: it keeps a per-combatant ring-buffer of root `CFrame`s stamped on
`workspace:GetServerTimeNow()`, rewinds each claimed target back to the attacker's
reported timestamp, and re-tests the attack volume geometrically. Damage is only
authorized on the **client-claim ∩ server-verify** intersection.

Because `GetPartBounds*` can't query the past, moving characters are approximated
as a capsule (three stacked spheres along the rewound root's up-vector) and tested
with plain sphere-vs-box / sphere-vs-sphere math. Static damageables (towers,
bases) never move, so they're tested at their current pose.

The same recorder that feeds the rewind doubles as a **movement-sanity
checkpoint**: because it already samples every character at a fixed rate,
impossible steps (teleports, sustained super-speed) are flagged there and the
offending player's claims are rejected for a short window (flag + log + bound —
never kick).

This core knows **nothing** about damage numbers, abilities, classes, or teams.
It answers one question — "was this target geometrically inside this volume at
this rewound time?" — and hands back the approved subset. All game rules stay on
the caller side.

## Files

| File | Role |
|---|---|
| `src/init.luau` | `LagCompensation.new(config)` — merges config, wires Snapshots + Rewind with the injected logger / latency provider / predicates / folder lists, starts the snapshot loop, returns the combined public API. |
| `src/Snapshots.luau` | `Snapshots.new(deps)` — the ring-buffer recorder + interpolation + movement-sanity checks + self-ticking record loop. |
| `src/Rewind.luau` | `Rewind.new(deps)` — timestamp clamping, attacker-pose rewind, capsule geometry, box/sphere approval, LOS, rate limiting, reject counters. |
| `src/LagCompConfig.luau` | Pure-data tunables (times in seconds on the server-time clock, distances in studs) + world-convention lists + debug-viz flags + the `Config`/`Logger` types. Zero requires. |

## Dependencies

**None.** No Wally packages, no cross-repo requires. Every module requires only
its siblings under `src/`. All host coupling (logging, latency, scheduling,
damageable predicate, world-folder conventions) is injected through `config`.

## Configuration / Injection API

`LagCompensation.new(config)` — every field is optional.

### Injected behaviours (defaulted in `init.luau`)

| Field | Type | Default | Notes |
|---|---|---|---|
| `logger` | `{ Error, Warn, Info, Debug: (self, ...any) -> () }` | no-op logger (all levels swallowed) | Inject e.g. a `Debugger.CreateScope(...)`; call sites use `:Debug` (rejections) and `:Warn` (movement flags). |
| `getLatency` | `(player: Player) -> number` (seconds) | `function() return 0 end` | Average RTT. **Implication of the default:** `AttackerPoseAt` samples at `t` with no client-lag offset — correct only at ~0 latency (LAN/testing). Wire a real provider (e.g. the TimeSync library's `GetLatency`) in production, or high-ping clients under-reach their own claims. |
| `isDamageable` | `(instance: Instance) -> boolean` | `function(i) return i:GetAttribute("Damageable") == true end` | Replaces the hardcoded attribute check. The Humanoid / HumanoidRootPart R15 assumptions stay hardcoded (generic). A target is a "static damageable" iff it has no Humanoid **and** `isDamageable` is true. |
| `scheduleSnapshots` | `(interval: number, record: () -> ()) -> (() -> ())?` | `nil` → self-tick | If provided, called once with the recorder; return an optional cleanup fn. If omitted, the library self-ticks the recorder on `RunService.Heartbeat` with a delta accumulator at `SNAPSHOT_HZ`. |

### World conventions & debug-viz (defaults live in `LagCompConfig`)

| Field | Type | Default | Notes |
|---|---|---|---|
| `npcFolderNames` | `{ string }` | `{ "Dummies", "Bots" }` | `workspace` folders whose child Models get pose history (tracked with `player = nil`, so sanity checks skip them). |
| `losExcludeFolderNames` | `{ string }` | `{ "Dummies", "ClientProjectiles", "HitboxDebug" }` | Folders a LOS ray ignores, so `HasLineOfSight` sees only static world (live rigs / cosmetics / debug parts excluded). Player characters are always excluded on top of these. |
| `debugEnabled` | `boolean` | `false` | Master switch for hitbox visualisation. |
| `showHitboxes` | `boolean` | `false` | Draw each rewind query's box/sphere as a translucent part (needs `debugEnabled` too). |
| `rewindHitboxColor` | `Color3` | `Color3.fromRGB(255, 140, 0)` | Colour of the drawn volumes. |
| `hitboxLifetime` | `number` | `0.5` | Seconds each drawn part survives. |

### Numeric tunables (in `LagCompConfig`, overridable by key)

Times are seconds on the `GetServerTimeNow()` clock; distances are studs.

**Read by this core:**

| Key | Default | Used by |
|---|---|---|
| `SNAPSHOT_HZ` | `20` | recorder rate |
| `SNAPSHOT_CAPACITY` | `40` | ring-buffer size (≈2s of history) |
| `MAX_REWIND` | `1.0` | oldest accepted claim time |
| `FUTURE_SLACK` | `0.05` | newest accepted claim time |
| `TARGET_REWIND_WINDOW` | `0.35` | rewind window lower bound around `t` |
| `TARGET_FORWARD_SLACK` | `0.05` | rewind window upper bound around `t` |
| `TARGET_RADIUS_PADDING` | `1.5` | capsule-sphere radius growth |
| `LOS_IMPACT_SLACK` | `4.0` | a LOS hit this close to the claimed impact IS the struck surface |
| `TELEPORT_STEP_STUDS` | `25` | per-snapshot displacement flag |
| `SUSTAINED_SPEED_LIMIT` | `80` | mean horizontal studs/s flag |
| `SPEED_WINDOW` | `0.75` | speed-check window |
| `FLAG_CLAIM_REJECT_SECONDS` | `2.0` | claim-reject window after a flag |
| `BURST_GRACE_SECONDS` | `1.0` | default `NoteAuthorizedBurst` duration |
| `MAX_REPORTED_TARGETS` | `16` | payload cap in `SanitizeTargets` |

**Carried for the caller's own combat rules (not read internally):** `ENFORCE`
(1), `ATTACK_VOLUME_PADDING` (2.0), `MUZZLE_RAY_DEVIATION` (8.0),
`PROJECTILE_FLIGHT_TOLERANCE` (0.3), `PROJECTILE_RANGE_MARGIN` (10),
`DIRECT_HIT_ACCEPT_RADIUS` (6.0), `RATE_COMBAT_ACTION_PER_SEC` (25),
`RATE_PROJECTILE_HIT_PER_SEC` (8), `RATE_COMBAT_CAST_PER_SEC` (15). These lived in
the same tuning surface in the original game; the caller reads them to size attack
volumes, validate projectile flight, and pick the `perSecond` budget it passes to
`AllowRate`. They're kept here so the whole tuning surface stays in one place.

## Public API

`LagCompensation.new(config)` returns a table exposing (plus `config`, the merged
runtime config):

### Snapshots (recorder / history)

| Method | Signature | Description |
|---|---|---|
| `SampleAt` | `(character: Model, t: number) -> CFrame?` | Interpolated pose at time `t`; clamps future to newest, `nil` if `t` predates the character's history. |
| `SamplesInWindow` | `(character: Model, t0: number, t1: number) -> { CFrame }` | Every pose plausibly held in `[t0, t1]` (interpolated endpoints + raw samples inside). |
| `GetExtents` | `(character: Model) -> Vector3` | Cached `GetExtentsSize` (falls back to the default R15 extents). |
| `Reset` | `(character: Model) -> ()` | Wipe history across an authorized discontinuity (spawn teleport). |
| `NoteAuthorizedBurst` | `(character: Model, duration: number?) -> ()` | Excuse a legit fast burst (knockback/dash/rally) from sanity flagging. |
| `IsClaimRejected` | `(player: Player) -> boolean` | True while the player's claims are suppressed by a movement flag. |
| `GetFlagCounters` | `() -> { [string]: number }` | Per-reason movement-flag tallies. |
| `start` | `() -> ()` | Wire character/folder tracking and start the record loop. **`new` already calls this**; don't call again. |
| `stop` | `() -> ()` | Disconnect the record loop (history retained). |

### Rewind (validation)

| Method | Signature | Description |
|---|---|---|
| `SanitizeTargets` | `(reported: unknown, attacker: Model) -> { Model }` | Filter a client payload to real, non-attacker, damageable Models, capped at `MAX_REPORTED_TARGETS`. |
| `ClampClaimTime` | `(t: unknown, player: Player) -> number?` | Validate/clamp the claim timestamp to the rewind horizon; `nil` (and rejects) if unusable. |
| `AttackerPoseAt` | `(player: Player, character: Model, root: BasePart, t: number) -> CFrame` | Rewound attacker pose at claim time, offset by half the player's latency; falls back to current `root.CFrame`. |
| `ApproveBox` | `(player: Player, claimed: { Model }, boxCFrame: CFrame, size: Vector3, t: number) -> { Model }` | Claim ∩ verify for a box volume (melee/dash); returns the subset overlapping the box at some plausible pose. |
| `ApproveRadius` | `(player: Player, claimed: { Model }, center: Vector3, radius: number, t: number) -> { Model }` | Claim ∩ verify for a sphere volume (AoE/splash/direct). |
| `HasLineOfSight` | `(from: Vector3, to: Vector3) -> boolean` | Static-world occlusion test; true if no wall sits between the points (or the hit is within `LOS_IMPACT_SLACK` of the target). |
| `InvalidateLineOfSightFilter` | `() -> ()` | Mark the LOS exclude list stale so the next `HasLineOfSight` rebuilds it. It rebuilds by itself only when a player joins, leaves or respawns; call this when the excluded set changes some other way (an NPC spawned into an excluded folder, a folder created or streamed in). Cheap: it sets a flag. |
| `AllowRate` | `(player: Player, key: string, perSecond: number) -> boolean` | Fixed 1s-bucket per player+key flood guard; rejects (`"RateLimited"`) when over budget. |
| `Reject` | `(player: Player, reason: RejectReason) -> ()` | Bump a reject counter and log the reason. |
| `GetCounters` | `() -> { [string]: number }` | Per-reason rejection tallies. |
| `CleanupPlayer` | `(player: Player) -> ()` | Drop a leaving player's rate buckets. |

`RejectReason` (exported from `Rewind`): `"BadPayload" | "FutureTimestamp" |
"StaleTimestamp" | "RateLimited" | "NoSnapshots" | "OutOfVolume" | "LOSBlocked" |
"FlightTime" | "RayDeviation" | "OverRange" | "MovementFlagged" | "NoPendingShot"`.

## Usage

```lua
local ServerScriptService = game:GetService("ServerScriptService")

local LagCompensation = require(ServerScriptService.LagCompensation)
local TimeSync = require(ServerScriptService.TimeSync) -- your latency library
-- local Debugger = require(...) -- optional real logger

local lc = LagCompensation.new({
	-- The key injection: per-player average RTT in seconds. TimeSync.GetLatency
	-- already has exactly the (player) -> number signature.
	getLatency = TimeSync.GetLatency,

	-- Optional: route rewind telemetry somewhere. Defaults to a no-op logger.
	-- logger = Debugger.CreateScope(Debugger.Category.COMBAT),

	-- Optional overrides (defaults shown):
	-- isDamageable = function(inst) return inst:GetAttribute("Damageable") == true end,
	-- npcFolderNames = { "Dummies", "Bots" },
})

-- Example: validating a melee-swing claim from a client remote.
local function onMeleeClaim(player: Player, claimTime, reportedTargets, localSwingCFrame, swingSize)
	-- Flood guard + movement-flag gate (game rules, on the caller side).
	if not lc.AllowRate(player, "melee", 25) then
		return
	end
	if lc.IsClaimRejected(player) then
		return -- player is currently movement-flagged; drop the claim
	end

	local t = lc.ClampClaimTime(claimTime, player)
	if not t then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root or not root:IsA("BasePart") then
		return
	end

	-- Rebuild the swing volume around where the attacker's client actually was at t.
	local attackerPose = lc.AttackerPoseAt(player, character, root, t)
	local boxCFrame = attackerPose * localSwingCFrame -- caller composes the volume

	-- Claim ∩ verify.
	local sanitized = lc.SanitizeTargets(reportedTargets, character)
	local approved = lc.ApproveBox(player, sanitized, boxCFrame, swingSize, t)

	for _, target in approved do
		-- ALL game rules live here: teams, class, block, damage numbers, effects.
		-- The core has already confirmed the geometry/timing.
	end
end
```

## The claim ∩ verify model

The client owns feel: it swings, predicts a hit, and *claims* a set of targets at
a timestamp `t` (what it saw locally). The server owns truth: it rewinds each
claimed target to `t` (adjusting for the attacker's latency) and re-tests the
attack volume against the recorded poses. A target is damaged only if it appears in
**both** sets — the client claimed it **and** the server can geometrically confirm
it was in the volume at that time. Claims the server can't confirm are dropped and
counted by reason; nothing damaging is ever trusted from the client outright.

## From game system to package

Geometry, temporal logic, ring-buffer, interpolation, movement-sanity math, and
reject bookkeeping are preserved **byte-for-byte**. Only the coupling points
changed:

1. **Singletons → factories.** `Snapshots` and `Rewind` were module-level
   singletons; they're now `Snapshots.new(deps)` / `Rewind.new(deps)` wired by
   `init.luau`'s `LagCompensation.new(config)`. Method names and bodies are
   unchanged (module-level state moved into per-instance closures).
2. **Debugger require removed** → injected `logger` (default no-op). The original
   `DebugConstants.DebugEnabled → Debugger.EnableCategories(COMBAT)` bootstrap was
   dropped; log verbosity is now the injected logger's concern. Log call sites are
   unchanged.
3. **DebugConstants require removed** → the four viz flags (`debugEnabled`,
   `showHitboxes`, `rewindHitboxColor`, `hitboxLifetime`) moved into config,
   defaulting to viz-off.
4. **TimeSync require removed** → injected `getLatency(player) -> number`. The
   library no longer bundles TimeSync; the host wires it.
5. **ServerScheduler require removed** → self-contained fixed-rate recorder on
   `RunService.Heartbeat` with a delta accumulator (matching the original
   scheduler's `accumulated %= interval; task.spawn(record)` semantics — the
   original `"PostSimulation"` schedule was itself Heartbeat-backed). An optional
   `scheduleSnapshots` injection overrides this. Added `stop()` to disconnect.
6. **Hardcoded folder names → config.** `{ "Dummies", "Bots" }` → `npcFolderNames`;
   the LOS-exclude `{ "Dummies", "ClientProjectiles", "HitboxDebug" }` →
   `losExcludeFolderNames`.
7. **Damageable predicate injectable.** The hardcoded
   `GetAttribute("Damageable") == true` → `config.isDamageable` (default keeps that
   check). Humanoid / HumanoidRootPart R15 assumptions unchanged.

Comments that named game specifics ("training dummies", "filler Bots", "COMBAT
debug scope") were lightly reworded to be generic; the tuning-rationale comments
are preserved verbatim.
