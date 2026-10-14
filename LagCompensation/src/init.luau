--!strict

-- LagCompensation: server-authoritative lag-compensation / rewind core for hit
-- validation. Snapshots keeps a per-combatant ring-buffer of root CFrames stamped
-- on workspace:GetServerTimeNow(); Rewind rewinds each claimed target to the
-- attacker's reported time and re-tests the attack volume geometrically. Damage
-- lands only on the client-claim ∩ server-verify intersection. The recorder also
-- doubles as a movement-sanity (teleport / speed-hack) checkpoint.
--
-- The core knows NOTHING about damage numbers, abilities, classes, or teams —
-- that is entirely the caller's business. All host coupling is injected through
-- config (see README): a logger, a getLatency(player) provider, an isDamageable
-- predicate, folder-name conventions, and an optional snapshot scheduler.

local LagCompConfig = require(script.LagCompConfig)
local Rewind = require(script.Rewind)
local Snapshots = require(script.Snapshots)

export type Logger = LagCompConfig.Logger

-- Caller-supplied configuration. Every field is optional; anything omitted falls
-- back to the LagCompConfig default (tunables) or the defaults below (behaviours).
export type Config = {
	-- Behaviours (defaulted below).
	logger: Logger?,
	getLatency: ((player: Player) -> number)?,
	isDamageable: ((instance: Instance) -> boolean)?,
	scheduleSnapshots: ((interval: number, record: () -> ()) -> (() -> ())?)?,

	-- World conventions / viz (default in LagCompConfig).
	npcFolderNames: { string }?,
	losExcludeFolderNames: { string }?,
	debugEnabled: boolean?,
	showHitboxes: boolean?,
	rewindHitboxColor: Color3?,
	hitboxLifetime: number?,

	-- Any numeric tunable from LagCompConfig may also be overridden by key
	-- (SNAPSHOT_HZ, MAX_REWIND, TARGET_REWIND_WINDOW, ...).
	[string]: any,
}

local function noop(_self: any, ...: any) end

-- Zero-infrastructure default logger: swallows every level. Inject a real one
-- (e.g. a Debugger scope with :Error/:Warn/:Info/:Debug) to see rewind telemetry.
local DefaultLogger: Logger = {
	Error = noop,
	Warn = noop,
	Info = noop,
	Debug = noop,
}

local LagCompensation = {}

function LagCompensation.new(config: Config?)
	local overrides: Config = config or {}

	-- Merge caller overrides over the pure-data defaults into a fresh runtime table
	-- (LagCompConfig itself is never mutated). Behaviour defaults are applied after.
	local merged: LagCompConfig.Config = {} :: any
	for key, value in pairs(LagCompConfig) do
		(merged :: any)[key] = value
	end
	for key, value in pairs(overrides) do
		(merged :: any)[key] = value
	end

	local logger: Logger = overrides.logger or DefaultLogger
	-- No latency provider => rewind samples at t directly (no client-lag offset).
	-- Fine for LAN/testing; wire a real getLatency (e.g. TimeSync.GetLatency) in
	-- production or high-latency clients under-reach their own claims.
	local getLatency = overrides.getLatency or function(_player: Player): number
		return 0
	end
	local isDamageable = overrides.isDamageable
		or function(instance: Instance): boolean
			return instance:GetAttribute("Damageable") == true
		end

	local snapshots = Snapshots.new({
		config = merged,
		logger = logger,
		scheduleSnapshots = overrides.scheduleSnapshots,
	})

	local rewind = Rewind.new({
		config = merged,
		logger = logger,
		snapshots = snapshots,
		getLatency = getLatency,
		isDamageable = isDamageable,
	})

	snapshots.start()

	-- Combined public surface. Snapshots + Rewind methods live under one table.
	return {
		config = merged,

		-- Snapshots
		SampleAt = snapshots.SampleAt,
		SamplesInWindow = snapshots.SamplesInWindow,
		GetExtents = snapshots.GetExtents,
		RefreshExtents = snapshots.RefreshExtents,
		Reset = snapshots.Reset,
		NoteAuthorizedBurst = snapshots.NoteAuthorizedBurst,
		IsClaimRejected = snapshots.IsClaimRejected,
		GetFlagCounters = snapshots.GetFlagCounters,
		start = snapshots.start,
		stop = snapshots.stop,

		-- Rewind
		SanitizeTargets = rewind.SanitizeTargets,
		ClampClaimTime = rewind.ClampClaimTime,
		AttackerPoseAt = rewind.AttackerPoseAt,
		ApproveBox = rewind.ApproveBox,
		ApproveRadius = rewind.ApproveRadius,
		HasLineOfSight = rewind.HasLineOfSight,
		-- For a host that changes the excluded set itself (an NPC spawned into an excluded
		-- folder, a folder streamed in): the LOS filter otherwise only rebuilds on a player
		-- joining, leaving or respawning.
		InvalidateLineOfSightFilter = rewind.InvalidateLineOfSightFilter,
		AllowRate = rewind.AllowRate,
		Reject = rewind.Reject,
		GetCounters = rewind.GetCounters,
		CleanupPlayer = rewind.CleanupPlayer,
	}
end

return LagCompensation
