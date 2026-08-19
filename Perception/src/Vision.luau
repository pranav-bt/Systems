--!strict

-- The vision model every game otherwise rewrites by hand: FOV cone + range +
-- line-of-sight raycast + AWARENESS OVER TIME. Detection is not a binary "can
-- I see you" -- awareness fills while a target stays visible (faster when
-- close and centered, slower at the edges) and decays when sight is lost,
-- climbing the classic ladder None -> Suspicious -> Detected. That
-- accumulation is what makes AI feel fair to sneak past and scary to stand in
-- front of.
--
-- PIPELINE, per update:
--   1. eye() gives the origin + facing; targets() gives who to look for.
--   2. Cone + range cull (pure math) picks the LOS candidates.
--   3. Candidates are raycast in priority order (longest unsampled first, then
--      highest awareness, then nearest) under the optional shared Budget --
--      when the bucket runs dry the remaining candidates are FROZEN rather
--      than cast, so fleets degrade to slower reactions, never frame spikes
--      and never awareness invented from evidence nobody gathered.
--   4. Awareness integrates, but only on evidence: visible -> += min(dt,
--      maxFillStep) * strength / awarenessTime; unseen -> -= dt / decayTime;
--      frozen -> unchanged. Status thresholds apply (Detected is sticky down to
--      the suspicion threshold). The fill cap keeps one lucky raycast from
--      standing in for a whole slow tick -- see stage 4.
--
-- The report is plain data. The natural host is a Bots blackboard sensor that
-- stores the report and writes `lastSeenPos` facts -- but nothing here knows
-- Bots exists.
--
-- REACTING TO EDGES. Detection edges arrive two ways, and the difference
-- matters. `report.events` lists them as data, so the host can PUBLISH the
-- report first and react second -- which is the only correct order when
-- reacting means re-planning, because a planner that runs mid-update reads
-- whatever the host published LAST update and cannot see the detection that
-- just triggered it. The `onStatus` callback is the convenience form for hosts
-- that don't publish anything (it fires after the report is assembled, so it
-- can safely re-enter this sensor, but it still runs before the host has
-- stored the new report). Under Bots: prefer events, and see the README.

local Raycaster = require(script.Parent.Raycaster)
local Types = require(script.Parent.Types)

local Vision = {}

export type Config = {
	-- Origin + unit facing for this update, in one call so they can't be
	-- inconsistent. For a Humanoid body: head position + head/root LookVector.
	eye: () -> (any, any),
	-- Who to look for this update. Refresh positions each call; `ref` is the
	-- stable identity awareness accumulates against.
	targets: () -> { Types.Target },

	fov: number?, -- full cone angle in degrees (default 110)
	range: number?, -- sight distance (default 60)
	awarenessTime: number?, -- seconds to fully detect a point-blank, centered target (default 1)
	decayTime: number?, -- seconds for full awareness to fade to zero when unseen (default 4)
	suspicion: number?, -- awareness threshold for "Suspicious" (default 0.35)
	-- Most seconds of awareness ONE visibility sample may credit (default
	-- awarenessTime * 0.5, i.e. two samples minimum to go cold -> detected).
	-- awarenessTime restores pre-cap behaviour for full-strength targets;
	-- math.huge disables the cap outright. See the sampling note above stage 4.
	maxFillStep: number?,
	-- How long an in-cone target may go without a line-of-sight ray before it
	-- jumps the budget queue (default awarenessTime). See stage 3.
	maxSampleAge: number?,
	-- Visibility strength in [0,1] from distFrac (0 point-blank .. 1 at range)
	-- and centerness (1 dead-center .. 0 at the cone edge). Scales the
	-- awareness fill rate. Default: (1 - 0.75*distFrac) * (0.6 + 0.4*centerness).
	strength: ((distFrac: number, centerness: number) -> number)?,

	raycast: Types.RaycastFn?, -- line-of-sight probe (default: Raycaster.new(params))
	params: RaycastParams?, -- filter for the DEFAULT raycast only (exclude characters!)
	budget: Types.Budget?, -- optional shared raycast budget (see Budget.luau)
	-- Edge callback: fires for each status change, AFTER the report is assembled
	-- but before the host has published it (so a re-plan triggered from here
	-- still reads the previous report -- use report.events instead when the host
	-- publishes one). Errors are warned and swallowed.
	onStatus: ((ref: any, from: Types.TargetStatus, to: Types.TargetStatus) -> ())?,
}

-- Internal per-ref tracking record.
type State = {
	awareness: number,
	status: Types.TargetStatus,
	wasDetected: boolean, -- drives Detected stickiness
	visible: boolean, -- as of the latest EVIDENCE (carried while frozen)
	strength: number, -- visibility strength of that evidence
	fresh: boolean, -- did THIS update produce evidence for this ref?
	sampledAt: number?, -- clock of the last actual ray (nil = never sampled)
	seenPosition: any?, -- last position actually seen at
	seenAt: number?,
	currentPosition: any?, -- provider's latest position (pre-LOS)
}

local function defaultStrength(distFrac: number, centerness: number): number
	return (1 - 0.75 * distFrac) * (0.6 + 0.4 * centerness)
end

function Vision.new(config: Config): Types.Vision
	assert(type(config) == "table", "Perception.Vision.new: a config table is required")
	assert(type(config.eye) == "function", "Perception.Vision.new: config.eye() -> (position, facing) is required")
	assert(type(config.targets) == "function", "Perception.Vision.new: config.targets() -> { Target } is required")
	local function optNumber(key: string, min: number): number?
		local value = (config :: { [string]: any })[key]
		assert(
			value == nil or (type(value) == "number" and value > min),
			`Perception.Vision.new: config.{key} must be a number > {min} when set`
		)
		return value
	end

	local fov = optNumber("fov", 0) or 110
	assert(fov < 360, "Perception.Vision.new: config.fov must be < 360 degrees")
	local cosHalfFov = math.cos(math.rad(fov) / 2)
	local range = optNumber("range", 0) or 60
	local awarenessTime = optNumber("awarenessTime", 0) or 1
	local decayTime = optNumber("decayTime", 0) or 4
	local maxFillStep = optNumber("maxFillStep", 0) or awarenessTime * 0.5
	local maxSampleAge = optNumber("maxSampleAge", 0) or awarenessTime
	local suspicion = config.suspicion or 0.35
	assert(
		type(suspicion) == "number" and suspicion > 0 and suspicion < 1,
		"Perception.Vision.new: config.suspicion must be between 0 and 1"
	)
	local strengthOf = config.strength or defaultStrength
	local raycast = config.raycast or Raycaster.new(config.params)
	local budget = config.budget
	local onStatus = config.onStatus

	local states: { [any]: State } = {}
	local lastUpdateAt: number? = nil

	local sensor = {} :: Types.Vision

	function sensor.update(_, now: number?): Types.VisionReport
		local clock = now or os.clock()
		local dt = if lastUpdateAt then clock - lastUpdateAt else 0
		lastUpdateAt = clock

		local origin, facing = config.eye()
		local facingLength = facing.Magnitude
		facing = if facingLength > 1e-4 then facing / facingLength else facing

		-- Stage 1+2: refresh positions, cull by range + cone into candidates.
		--
		-- `fresh` tracks whether this update produced real EVIDENCE about a ref, and
		-- it is what stage 4 integrates on. The cone/range cull is pure math, so a
		-- culled target is evidence (definitively not visible); an in-cone candidate
		-- is NOT evidence until a ray resolves it, which the budget may refuse.
		type Candidate = { state: State, position: any, dist: number, centerness: number, urgent: boolean }
		local candidates: { Candidate } = {}
		local provided: { [any]: boolean } = {}
		for _, target in config.targets() do
			provided[target.ref] = true
			local state = states[target.ref]
			if not state then
				state = {
					awareness = 0,
					status = "None" :: Types.TargetStatus,
					wasDetected = false,
					visible = false,
					strength = 0,
					fresh = true,
				}
				states[target.ref] = state
			end
			state.currentPosition = target.position
			local wasVisible = state.visible
			state.visible = false -- until a ray proves otherwise
			state.fresh = true
			local offset = target.position - origin
			local dist = offset.Magnitude
			if dist <= range and dist > 1e-4 and facingLength > 1e-4 then
				local dot = facing:Dot(offset / dist)
				if dot >= cosHalfFov then
					local centerness = if cosHalfFov < 1 then (dot - cosHalfFov) / (1 - cosHalfFov) else 1
					-- Never sampled, or not sampled for maxSampleAge: jumps the queue.
					local sampledAt = state.sampledAt
					local candidate: Candidate = {
						state = state,
						position = target.position,
						dist = dist,
						centerness = centerness,
						urgent = sampledAt == nil or (clock - sampledAt) >= maxSampleAge,
					}
					-- Carry the last evidence in case the budget refuses this ray.
					state.visible = wasVisible
					state.fresh = false
					table.insert(candidates, candidate)
					continue
				end
			end
			state.strength = 0 -- culled: definitively not visible this update
		end
		-- A ref NOT provided this update (left range, despawned, died) is
		-- definitively unseen -- that absence IS evidence, so clear the visibility
		-- the provided-loop above never touched. Otherwise stage 4 would keep
		-- FILLING its awareness off the carried visible+strength forever: a phantom
		-- "Detected" that re-engages from any angle the moment the ref reappears,
		-- and a state entry that never decays away.
		for ref, state in states do
			if not provided[ref] then
				state.visible = false
				state.strength = 0
				state.fresh = true
			end
		end

		-- Stage 3: line-of-sight, priority order, under the shared budget.
		--
		-- PRIORITY. Rays go to urgent candidates first -- never sampled, or not
		-- sampled for maxSampleAge -- and only then by awareness, then by nearness.
		-- Without that first tier, awareness-ordering alone means a bot under a dry
		-- budget spends every ray re-confirming the targets it already tracks and is
		-- structurally blind to a new one walking into its cone.
		table.sort(candidates, function(a, b)
			if a.urgent ~= b.urgent then
				return a.urgent
			end
			if a.state.awareness ~= b.state.awareness then
				return a.state.awareness > b.state.awareness
			end
			return a.dist < b.dist
		end)
		local sampled, frozen = 0, 0
		for _, candidate in candidates do
			local state = candidate.state
			if budget and not budget:take(1, clock) then
				frozen += 1
				-- STARVED: no ray, so no evidence, so `fresh` stays false and stage 4
				-- FREEZES this target's awareness -- it neither fills nor decays. The
				-- alternative (integrating off the carried visibility) extrapolates:
				-- it fills a target that has since ducked behind cover all the way to
				-- Detected, and decays one standing in plain view. Holding is the only
				-- honest answer to "I didn't look".
				continue
			end
			state.sampledAt = clock
			state.fresh = true
			sampled += 1
			if raycast(origin, candidate.position - origin) == nil then
				state.visible = true
				state.strength = math.clamp(strengthOf(candidate.dist / range, candidate.centerness), 0, 1)
			else
				state.visible = false
				state.strength = 0
			end
		end

		-- Stage 4: integrate awareness, resolve statuses, build the report.
		--
		-- SAMPLING. `visible` is a point sample -- one ray at THIS instant -- but
		-- dt is the whole interval since the last update. Crediting the full
		-- interval to that one ray lets a slow-ticking bot (tickInterval 1.5, the
		-- LOD lever) go from cold to Detected off a single frame in which the
		-- target happened to be in the open. So the FILL step is capped at
		-- maxFillStep: one sighting is worth only so much evidence, and detection
		-- needs corroboration across updates. DECAY is deliberately NOT capped --
		-- conservative about gaining awareness, generous about losing it, which is
		-- the bias that keeps sneaking past a fair fight.
		local fillStep = math.min(dt, maxFillStep)
		local perceptions: { Types.TargetPerception } = {}
		local events: { Types.StatusEvent } = {}
		for ref, state in states do
			-- Integrate ONLY on evidence. A frozen ref -- one whose ray the budget
			-- refused -- holds everything: awareness, seenPosition, seenAt. Its
			-- `visible`/`strength` still report the last evidence, flagged `stale`.
			if state.fresh then
				if state.visible then
					state.awareness = math.min(1, state.awareness + fillStep * state.strength / awarenessTime)
					state.seenPosition = state.currentPosition
					state.seenAt = clock
				else
					state.awareness = math.max(0, state.awareness - dt / decayTime)
				end
			end

			local status: Types.TargetStatus
			if state.awareness >= 1 then
				status = "Detected"
				state.wasDetected = true
			elseif state.wasDetected and state.awareness >= suspicion then
				status = "Detected" -- sticky: no flickering out of engagement
			elseif state.awareness >= suspicion then
				status = "Suspicious"
			else
				status = "None"
				state.wasDetected = false
			end
			if status ~= state.status then
				-- Record the edge; hooks run once the report is whole (see below).
				-- Firing consumer code from HERE used to mean it ran while `states`
				-- was mid-traversal, and a hook that re-entered this sensor could
				-- insert into the table being iterated.
				local previous = state.status
				state.status = status
				table.insert(events, { ref = ref, from = previous, to = status })
			end

			if state.awareness <= 0 and not state.visible then
				if not provided[ref] then
					states[ref] = nil -- gone and forgotten
				end
				continue -- cold entries stay out of the report either way
			end
			table.insert(perceptions, {
				ref = ref,
				status = state.status,
				awareness = state.awareness,
				visible = state.visible,
				strength = if state.visible then state.strength else 0,
				stale = not state.fresh,
				position = state.seenPosition,
				seenAt = state.seenAt,
			})
		end

		table.sort(perceptions, function(a, b)
			return a.awareness > b.awareness
		end)
		local report: Types.VisionReport =
			{ targets = perceptions, events = events, best = perceptions[1], sampled = sampled, frozen = frozen }

		-- Callbacks last, against a finished report: by here `states` is no longer
		-- being iterated, so a hook may safely call back into this sensor.
		if onStatus then
			for _, event in events do
				local ok, err = pcall(onStatus, event.ref, event.from, event.to)
				if not ok then
					warn(`[Perception] Vision onStatus hook errored:\n{err}`)
				end
			end
		end
		return report
	end

	-- Drop accumulated awareness for one ref (or everything when nil) -- e.g.
	-- on respawn, round reset, or a scripted "lose the player" beat.
	function sensor.forget(_, ref: any?)
		if ref == nil then
			table.clear(states)
		else
			states[ref] = nil
		end
	end

	return sensor
end

return Vision
