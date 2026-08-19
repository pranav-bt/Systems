--!strict

-- Tunables for the lag-compensated (rewind) hit validation pipeline. One flat
-- table so Snapshots/Rewind share a single tuning surface. All times are seconds
-- on the workspace:GetServerTimeNow() clock; distances are studs.
--
-- Everything here is PURE DATA. The behavioural injections (logger, getLatency,
-- isDamageable, scheduleSnapshots) are NOT stored here -- they are supplied to
-- LagCompensation.new(config) and default in init.luau. This module only owns the
-- numeric/geometry tunables plus the world-convention lists (folder names) and the
-- debug-visualisation flags.

export type Logger = {
	Error: (self: any, ...any) -> (),
	Warn: (self: any, ...any) -> (),
	Info: (self: any, ...any) -> (),
	Debug: (self: any, ...any) -> (),
}

-- The runtime config shape shared by Snapshots + Rewind. The last four fields are
-- the injected behaviours; init.luau merges them in (with defaults) after copying
-- the pure-data fields below, so they are typed optional here.
export type Config = {
	ENFORCE: boolean,
	SNAPSHOT_HZ: number,
	SNAPSHOT_CAPACITY: number,
	MAX_REWIND: number,
	FUTURE_SLACK: number,
	TARGET_REWIND_WINDOW: number,
	TARGET_FORWARD_SLACK: number,
	ATTACK_VOLUME_PADDING: number,
	TARGET_RADIUS_PADDING: number,
	MUZZLE_RAY_DEVIATION: number,
	PROJECTILE_FLIGHT_TOLERANCE: number,
	PROJECTILE_RANGE_MARGIN: number,
	DIRECT_HIT_ACCEPT_RADIUS: number,
	LOS_IMPACT_SLACK: number,
	TELEPORT_STEP_STUDS: number,
	SUSTAINED_SPEED_LIMIT: number,
	SPEED_WINDOW: number,
	FLAG_CLAIM_REJECT_SECONDS: number,
	BURST_GRACE_SECONDS: number,
	RATE_COMBAT_ACTION_PER_SEC: number,
	RATE_PROJECTILE_HIT_PER_SEC: number,
	RATE_COMBAT_CAST_PER_SEC: number,
	MAX_REPORTED_TARGETS: number,

	-- World conventions (extracted from hardcoded literals in the original).
	npcFolderNames: { string },
	losExcludeFolderNames: { string },

	-- Debug-visualisation flags (extracted from ReplicatedStorage.Shared.DebugConstants).
	debugEnabled: boolean,
	showHitboxes: boolean,
	rewindHitboxColor: Color3,
	hitboxLifetime: number,

	-- Injected behaviours (supplied via config, defaulted in init.luau).
	logger: Logger?,
	getLatency: ((player: Player) -> number)?,
	isDamageable: ((instance: Instance) -> boolean)?,
	scheduleSnapshots: ((interval: number, record: () -> ()) -> (() -> ())?)?,
}

return {
	-- Shadow switch for the instant-hit kinds (MeleeSwing/AreaDamage/Dash): while
	-- false, the legacy distance-only validation still applies damage and the
	-- rewind result is only compared + logged (so tolerances can be tuned against
	-- real play without eating legitimate hits). Flip to true once a few Studio
	-- sessions at 0/100/200ms show no mismatches, then delete the legacy path.
	-- Projectile and ContinuousAoE validation is always enforced.
	ENFORCE = true,

	-- Recorder: 20 Hz matches Roblox's character replication cadence; faster adds
	-- memory/CPU without adding real information. 40 slots ≈ 2s of history, which
	-- covers MAX_REWIND + TARGET_REWIND_WINDOW with margin.
	SNAPSHOT_HZ = 20,
	SNAPSHOT_CAPACITY = 40,

	-- Claim timestamps: reject anything older than MAX_REWIND (TimeSync already
	-- treats >1s RTT as insane) or further in the future than FUTURE_SLACK.
	MAX_REWIND = 1.0,
	FUTURE_SLACK = 0.05,

	-- The pose a target had "on the attacker's screen" at claim time t sits in
	-- roughly [t - one-way x2 - render interp, t]; testing every snapshot in this
	-- window (plus a touch of forward slack) beats trying to compute the exact
	-- offset per player.
	TARGET_REWIND_WINDOW = 0.35,
	TARGET_FORWARD_SLACK = 0.05,

	-- Geometry generosity: attack shapes grow by ATTACK_VOLUME_PADDING per side
	-- (limbs stick out past the root-anchored client box; the attacker anchor has
	-- sampling jitter), and the character capsule-sphere radius grows by
	-- TARGET_RADIUS_PADDING (capsule-vs-real-part mismatch + 20 Hz interp residue).
	-- Combined worst case ~3.5 studs — still ~10x tighter than the old
	-- direction-blind 12-45 stud distance check.
	ATTACK_VOLUME_PADDING = 2.0,
	TARGET_RADIUS_PADDING = 1.5,

	-- Projectile claim validation (straight-line, constant-speed bolts).
	MUZZLE_RAY_DEVIATION = 8.0, -- max ⊥ distance impact→shot ray (real muzzle sits 3-4 studs off root, +1.5 spawn offset, +sweep radius)
	PROJECTILE_FLIGHT_TOLERANCE = 0.3, -- |measured - expected| flight time (Heartbeat quantization + timestamp jitter)
	PROJECTILE_RANGE_MARGIN = 10,
	DIRECT_HIT_ACCEPT_RADIUS = 6.0, -- impact point ↔ rewound target volume
	LOS_IMPACT_SLACK = 4.0, -- a LOS ray blocked this close to the claimed impact IS the surface the bolt hit

	-- Movement sanity (players only; flag + log + briefly reject claims, never kick).
	TELEPORT_STEP_STUDS = 25, -- per-snapshot displacement; ~2.5x above any legit burst (Charge peaks ~9 studs/step)
	SUSTAINED_SPEED_LIMIT = 80, -- mean horizontal studs/s over SPEED_WINDOW (horizontal so free-fall never flags)
	SPEED_WINDOW = 0.75,
	FLAG_CLAIM_REJECT_SECONDS = 2.0,
	BURST_GRACE_SECONDS = 1.0, -- after knockback/dash/rally-snap the recorder expects fast motion

	-- Per-player remote budgets (sliding 1s window); ~5x legit peak (whirlwind
	-- ticks ≈3.3/s + basics ≈2/s).
	RATE_COMBAT_ACTION_PER_SEC = 25,
	RATE_PROJECTILE_HIT_PER_SEC = 8,
	RATE_COMBAT_CAST_PER_SEC = 15,

	MAX_REPORTED_TARGETS = 16,

	-- World conventions. Server-owned non-player character folders whose Models get
	-- pose history too (rewind can confirm hits on them). losExcludeFolderNames are
	-- the workspace folders a static-world LOS ray ignores (live rigs / cosmetics /
	-- debug parts), so LOS only answers "does a wall sit between muzzle and impact".
	npcFolderNames = { "Dummies", "Bots" },
	losExcludeFolderNames = { "Dummies", "ClientProjectiles", "HitboxDebug" },

	-- Debug visualisation (off by default). When both debugEnabled and showHitboxes
	-- are true, each rewind query draws its box/sphere as a translucent part.
	debugEnabled = false,
	showHitboxes = false,
	rewindHitboxColor = Color3.fromRGB(255, 140, 0),
	hitboxLifetime = 0.5,
}
