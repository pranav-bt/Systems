--!strict

-- Default tunables for the agent core. Override any subset via
-- Brain.configure({ ... }) before (or while) the Brain runs. Everything here is
-- about the DECISION layer -- there are no body, movement, or game numbers,
-- because the core has no body.

local Config = {
	-- Seconds between a bot's sense -> plan -> act steps. Bots with their own
	-- `tickInterval` override it; everyone else thinks at this rate. Also the
	-- cadence for shared (master / group) board sensor updates.
	TICK_INTERVAL = 0.2,

	-- Seconds of real frame time Brain.step may spend draining due bots before
	-- deferring the rest to the next frame (2ms of a 16.6ms frame). It bounds the
	-- PEAK only: bots carry their own phase, so a healthy fleet spreads itself
	-- thin enough that this is never reached. Frames that do hit it show up in
	-- Brain.stats().deferred -- sustained non-zero means raise tickInterval on
	-- distant bots (cheaper) or raise this (more frame time). Unused by
	-- Brain.tick, which is deliberately unbudgeted.
	FRAME_BUDGET = 0.002,

	-- Commitment (anti flip-flop). The running goal's frozen selection score is
	-- multiplied by min(MAX, BASE + GROWTH * secondsInGoal); a challenger goal
	-- must beat that product to interrupt. So a just-started goal already holds
	-- a small edge, and the longer a plan has been running the harder it is to
	-- break -- up to the cap, past which drastic-enough challengers still win.
	PLAN_COMMIT_BASE = 1.15,
	PLAN_COMMIT_GROWTH = 0.05,
	PLAN_COMMIT_MAX = 1.6,

	-- ± spread of each bot's persistent per-goal personality multiplier, so a
	-- fleet of identical bots doesn't pick identical goals in lockstep
	-- (0 = uniform bots).
	GOAL_JITTER = 0.1,

	-- ± spread applied when rescheduling a bot's next step, so same-interval bots
	-- created together drift apart instead of converging on the same frames.
	STEP_JITTER = 0.1,

	-- ± spread applied when rescheduling a blackboard sensor, so same-interval
	-- sensors across a fleet stop firing as one synchronized spike.
	PHASE_JITTER = 0.1,

	-- All three jitters at 0, plus a seeded generator via Bots.setRandom, makes a
	-- headless run exactly reproducible. See Rng.luau.

	-- Decision tracing: keep the last N planner decisions per bot (adopt /
	-- interrupt / complete / fail / abandon / idle, with per-goal score
	-- verdicts at selection time), readable via bot:trace(). 0 = off (the
	-- default: no recording, no allocation). Turn on while developing/tuning;
	-- bot:explain() works regardless of this setting.
	TRACE_DECISIONS = 0,
}

return Config
