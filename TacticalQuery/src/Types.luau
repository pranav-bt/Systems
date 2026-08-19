--!strict

-- Shared types for the tactical position-query system. Positions flow through
-- the engine as OPAQUE values -- the engine never constructs or does math on
-- them -- so the core works with Vector3s, Vector2s, or anything a consumer's
-- generators/tests agree on. Only the built-in Generators/Tests/Probes assume
-- Roblox Vector3s.

-- The values a query run is parameterized by, keyed by name ("self", "threat",
-- "allies", ...). Query DEFINITIONS reference keys; callers supply the values
-- per run -- which is what lets one definition serve every bot.
export type Context = { [string]: any }

-- What a raycast probe reports back (nil = the ray hit nothing).
export type ProbeHit = {
	position: any,
	instance: any,
}

-- The ENTIRE world surface of the system. Everything that touches geometry --
-- rays, floors, reachability -- goes through this table, so swapping worlds
-- (voxel grids, player-built bases, abstract maps) means swapping these three
-- functions, not the engine, generators, or tests. Probes.luau ships the
-- default Roblox implementation; all fields are plain functions (dot-called).
-- A metered allowance for probe-priced work. Structurally identical to
-- Perception.Budget ON PURPOSE: the packages compose by shape, never by require,
-- so ONE budget object can be handed to both and a fleet gets a single ceiling on
-- everything it spends looking at the world.
export type Budget = {
	take: (self: Budget, count: number?, now: number?) -> boolean,
	available: (self: Budget, now: number?) -> number,
}

export type Probes = {
	-- First hit along `direction` from `origin` (the ray is exactly that long).
	raycast: (origin: any, direction: any) -> ProbeHit?,
	-- Project a floating candidate onto walkable ground; nil = no floor there,
	-- the candidate dies.
	snapToGround: (point: any) -> any?,
	-- Can an agent actually get there? Powers Tests.reachable; optional because
	-- not every query validates (and not every world has an answer).
	isReachable: ((from: any, to: any) -> boolean)?,
	-- Optional ceiling on probe work. ONE TOKEN PER PROBE, charged inside the
	-- probe functions themselves so custom tests are metered too. When a probe is
	-- refused it answers "nothing there" and sets `starved`; the Engine abstains
	-- from the whole run rather than pick from a half-probed field.
	budget: Budget?,
	-- Set by the probes when the budget refused one. The Engine clears it at the
	-- start of a run and checks it between stages.
	starved: boolean?,
}

-- Produces candidate positions for a query run. Built-ins live in
-- Generators.luau (ring / grid / tagged); any bare function works.
export type Generator = (context: Context, probes: Probes) -> { any }

-- When a test runs, by cost:
--   "cheap"     -- pure math; runs on every generated candidate
--   "expensive" -- raycasts; runs on the best `maxExpensive` candidates only
--   "validate"  -- the priciest checks (path reachability); tried on the final
--                  top `topK` candidates until one passes all of them
export type TestCost = "cheap" | "expensive" | "validate"

-- One scoring/filtering criterion. `score` returns a number in [0, 1] (values
-- outside are clamped) or nil to REJECT the candidate outright. Scores combine
-- as a weighted average across all tests that ran.
export type Test = {
	name: string,
	cost: TestCost,
	weight: number?, -- default 1
	score: (point: any, context: Context, probes: Probes) -> number?,
}

-- A validated query definition (build with Query.new). `run` executes the
-- pipeline; `probes` defaults to the package-level default (set by init.luau)
-- when omitted.
-- Tests grouped by cost, precomputed by Query.new so Engine.run never has to
-- re-derive an immutable fact on every run.
export type TestStages = {
	cheap: { Test },
	expensive: { Test },
	validate: { Test },
}

export type Query = {
	name: string,
	generator: Generator,
	tests: { Test },
	maxExpensive: number?, -- candidates that receive probes: grounding + expensive tests (default 16)
	topK: number?, -- candidates attempted through validate tests (default 3)
	-- Ground candidates through probes.snapToGround after the cheap tests
	-- (default true). Set false when the generator already returns floor
	-- positions -- authored points, see Generators.tagged.
	snap: boolean?,
	stages: TestStages?, -- set by Query.new; Engine.run partitions on the fly without it
	debug: boolean?, -- keep every scored candidate in RunInfo.candidates for TacticalQuery.Debug
	run: (self: Query, context: Context, probes: Probes?) -> (Candidate?, RunInfo),
}

-- A winning position: where, how good, and the per-test raw scores that made
-- it win -- `breakdown` is the built-in "why did it pick that spot" answer.
export type Candidate = {
	position: any,
	score: number, -- weighted average of every test that ran, in [0, 1]
	breakdown: { [string]: number }, -- test name -> raw (unweighted) score
}

-- What one run did, returned alongside the result (even a nil result) --
-- the numbers to read when a query comes back empty or slow.
export type RunInfo = {
	generated: number, -- candidates the generator produced
	scored: number, -- survivors of the cheap tests
	grounded: number, -- candidates put through snapToGround (0 when snap = false)
	expensiveTested: number, -- candidates that received expensive tests
	validateTried: number, -- candidates attempted through validate tests
	-- True when probes.budget refused and the run abstained rather than picking
	-- from a silently-shrunk field. Retry next step; do not treat as "no cover".
	budgetStarved: boolean?,
	-- Every scored candidate, for TacticalQuery.Debug. Only populated when the
	-- query sets `debug = true` -- it is a per-run allocation.
	candidates: { Candidate }?,
}

return {}
