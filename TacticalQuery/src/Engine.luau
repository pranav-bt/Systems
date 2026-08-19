--!strict

-- The query pipeline: generate candidates, score them through tests in cost
-- order, validate the winners. Pure logic -- positions are opaque values, no
-- Roblox APIs, everything world-shaped arrives through `probes` -- which keeps
-- this module fully testable outside Roblox (e.g. under Lune).
--
-- THE PIPELINE.
--   1. GENERATE   generator(context, probes) produces candidate positions.
--   2. CHEAP      every candidate runs the cheap (pure math) tests. A test
--                 returning nil rejects the candidate; numbers accumulate into
--                 a weighted average. Survivors are ranked best-first.
--   3. GROUND     the best `maxExpensive` survivors are snapped to the floor
--                 (one probe each) -- see SNAPPING below.
--   4. EXPENSIVE  those same candidates receive the raycast-grade tests -- the
--                 budget is spent on promising points, not uniformly. Survivors
--                 are re-ranked.
--   5. VALIDATE   the priciest checks (reachability) run on the top `topK`
--                 candidates one at a time, best-first, until one passes all
--                 of them. That candidate wins. If none pass, the query
--                 returns nil -- with the RunInfo saying exactly where the
--                 field thinned out.
--
-- SNAPPING. Grounding happens HERE, after the cheap tests, not in the
-- generator. It is a probe per candidate, so doing it during generation meant a
-- `grid` of 169 points spent 169 rays before a single test ran -- uniformly,
-- which is exactly what the rest of this pipeline exists to avoid. Snapping the
-- cheap-stage survivors instead makes every probe in a run bounded by
-- `maxExpensive`. Cheap tests therefore score against the generator's raw Y;
-- distance/direction/spacing are horizontal and don't care, but a custom cheap
-- test that reads height would. Set `snap = false` on the query when the
-- generator already returns floor positions (authored points -- see
-- Generators.tagged).
--
-- BUDGET. Metering lives in the PROBES (Probes.luau), one token per actual
-- probe -- not one per candidate per stage, which let a single token stand for
-- the six rays a default isReachable spends, or the three a `hidden` with three
-- heights spends. Charging the probes makes a token mean the same thing here as
-- in Perception, so one bucket can honestly cap a whole fleet, and custom tests
-- are metered for free because they can only reach the world through `probes`.
--
-- The Engine's job is what a refusal MEANS: it checks `probes.starved` between
-- stages and ABSTAINS -- nil result, `budgetStarved` in the RunInfo -- rather than
-- pick from whatever happened to get probed. That matters because a position is committed
-- to for seconds: silently shrinking the field would have the bot confidently
-- take a bad spot, where abstaining lets the calling action stay Running and ask
-- again next step. Compare Perception, which holds stale awareness, and Hearing,
-- which hears the sound anyway -- three subsystems, three right answers to "I
-- could not afford to look".
--
-- SCORING. Each test returns [0, 1] (clamped) or nil (reject). A candidate's
-- score is the weighted average of every test that ran on it: predictable,
-- designer-tunable via `weight`, and a hard filter is just a test that
-- returns nil. Validate-stage scores fold into the average like any other,
-- but selection order among the top K is fixed before validation starts --
-- "first passer wins", by design, so validation cost stays bounded.

local Types = require(script.Parent.Types)

local DEFAULT_MAX_EXPENSIVE = 16
local DEFAULT_TOP_K = 3

local Engine = {}

-- A candidate mid-pipeline: running weighted-average terms, the average itself
-- (kept current so sorting never recomputes it), and the raw per-test scores
-- for the final breakdown.
type Scored = {
	position: any,
	sumWeights: number,
	sumWeighted: number,
	average: number,
	breakdown: { [string]: number },
}

local function refreshAverage(candidate: Scored)
	candidate.average = if candidate.sumWeights > 0 then candidate.sumWeighted / candidate.sumWeights else 1
end

local function byAverageDesc(a: Scored, b: Scored): boolean
	return a.average > b.average
end

-- Move the `k` best candidates into positions 1..k (unordered among themselves)
-- and leave the rest behind them. Quickselect: linear on average, where sorting
-- the whole field is n log n -- and the field is mostly thrown away, since only
-- `maxExpensive` candidates can ever be probed. A 169-point grid ranks 16.
local function selectTop(list: { Scored }, k: number)
	local left, right = 1, #list
	while left < right do
		local pivot = list[right].average
		local store = left
		for index = left, right - 1 do
			if list[index].average > pivot then
				list[index], list[store] = list[store], list[index]
				store += 1
			end
		end
		list[store], list[right] = list[right], list[store]
		if store == k then
			return
		elseif store < k then
			left = store + 1
		else
			right = store - 1
		end
	end
end

-- Split tests by cost. Query.new precomputes this onto the spec; Engine.run
-- falls back to it for hand-built query tables, which the package supports.
function Engine.partition(tests: { Types.Test }): Types.TestStages
	local stages: Types.TestStages = { cheap = {}, expensive = {}, validate = {} }
	for _, test in tests do
		table.insert(stages[test.cost], test)
	end
	return stages
end

-- Run `tests` against one candidate, folding scores into its running average.
-- Returns false the moment any test rejects (nil).
local function applyTests(
	candidate: Scored,
	tests: { Types.Test },
	context: Types.Context,
	probes: Types.Probes
): boolean
	for _, test in tests do
		local score = test.score(candidate.position, context, probes)
		if score == nil then
			return false
		end
		-- `score == score` rejects NaN, which type() reports as a number and clamp
		-- does not sanitise. An unnoticed NaN makes a candidate compare EQUAL to
		-- everything (every comparison with NaN is false), so ranking silently goes
		-- arbitrary instead of erroring -- catch it at the source.
		assert(
			type(score) == "number" and score == score,
			`TacticalQuery: test "{test.name}" returned {tostring(score)}; score must return a number or nil`
		)
		score = math.clamp(score, 0, 1)
		local weight = test.weight or 1
		candidate.breakdown[test.name] = score
		candidate.sumWeights += weight
		candidate.sumWeighted += weight * score
	end
	refreshAverage(candidate)
	return true
end

-- Did the probes run dry since the last check? Probes meter themselves (one
-- token per probe) and raise `starved`; the Engine turns that into abstention.
local function starved(probes: Types.Probes, info: Types.RunInfo): boolean
	if not probes.starved then
		return false
	end
	info.budgetStarved = true
	return true
end

local function finalize(candidate: Scored): Types.Candidate
	return {
		position = candidate.position,
		score = candidate.average,
		breakdown = candidate.breakdown,
	}
end

-- One full query run. Returns the winning candidate (or nil) plus the RunInfo
-- counters for debugging/tuning.
function Engine.run(query: Types.Query, context: Types.Context, probes: Types.Probes): (Types.Candidate?, Types.RunInfo)
	local info: Types.RunInfo = { generated = 0, scored = 0, grounded = 0, expensiveTested = 0, validateTried = 0 }
	probes.starved = false -- probes raise this; see BUDGET in the header

	local points = query.generator(context, probes)
	info.generated = #points

	local stages = query.stages or Engine.partition(query.tests)
	local cheap, expensive, validate = stages.cheap, stages.expensive, stages.validate

	-- Stage 2: cheap tests on everything.
	local candidates: { Scored } = {}
	for _, point in points do
		local candidate: Scored = { position = point, sumWeights = 0, sumWeighted = 0, average = 1, breakdown = {} }
		if applyTests(candidate, cheap, context, probes) then
			table.insert(candidates, candidate)
		end
	end
	info.scored = #candidates
	if info.scored == 0 then
		return nil, info
	end
	-- Everything from here on is probe-priced, so it applies to the best
	-- `maxExpensive` candidates only; the rest are discarded (they were never
	-- going to be probed, so they cannot win). Select those first, THEN sort --
	-- ordering a field we are about to throw 90% of away is wasted work.
	local limit = math.min(#candidates, query.maxExpensive or DEFAULT_MAX_EXPENSIVE)
	if #candidates > limit then
		selectTop(candidates, limit)
		for index = #candidates, limit + 1, -1 do
			candidates[index] = nil
		end
	end
	table.sort(candidates, byAverageDesc)

	-- Stage 3: ground the survivors (see SNAPPING in the header).
	if query.snap ~= false then
		local grounded: { Scored } = {}
		for index = 1, limit do
			local candidate = candidates[index]
			info.grounded += 1
			local floor = probes.snapToGround(candidate.position)
			if starved(probes, info) then
				return nil, info
			end
			if floor ~= nil then
				candidate.position = floor
				table.insert(grounded, candidate)
			end
		end
		if #grounded == 0 then
			return nil, info -- nothing the agent could stand on
		end
		candidates = grounded
		limit = #candidates
	end

	-- Stage 4: expensive tests on that same set.
	if #expensive > 0 then
		local kept: { Scored } = {}
		for index = 1, limit do
			local candidate = candidates[index]
			info.expensiveTested += 1
			local kept_ok = applyTests(candidate, expensive, context, probes)
			if starved(probes, info) then
				return nil, info
			end
			if kept_ok then
				table.insert(kept, candidate)
			end
		end
		if #kept == 0 then
			return nil, info
		end
		table.sort(kept, byAverageDesc)
		candidates = kept
	end
	-- (No trim needed here any more: the field was already cut to `limit` before
	-- ranking, so nothing beyond it survives to this point.)

	-- Debug: keep the scored field for the visualizer (opt-in; it allocates).
	if query.debug then
		local snapshot: { Types.Candidate } = {}
		for _, candidate in candidates do
			table.insert(snapshot, finalize(candidate))
		end
		info.candidates = snapshot
	end

	-- Stage 5: validate the top K, best-first; first full passer wins.
	if #validate == 0 then
		return finalize(candidates[1]), info
	end
	local attempts = math.min(#candidates, query.topK or DEFAULT_TOP_K)
	for index = 1, attempts do
		local candidate = candidates[index]
		info.validateTried += 1
		local ok = applyTests(candidate, validate, context, probes)
		if starved(probes, info) then
			return nil, info
		end
		if ok then
			return finalize(candidate), info
		end
	end
	return nil, info
end

return Engine
