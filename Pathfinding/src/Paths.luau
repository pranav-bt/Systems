--!strict

-- The compute broker: one queue for every expensive, possibly-yielding movement
-- computation in the game, with a hard ceiling on how many run at once.
--
-- WHY. `PathfindingService:ComputeAsync` is the most expensive thing the default
-- mover does, and agents used to call it independently -- so a squad that all
-- received a destination in the same frame issued a burst of simultaneous
-- computations with nothing to bound them, entirely outside any budget the
-- decision layer thought it was enforcing. Worse, an agent whose goal moved
-- while a computation was in flight would still walk the answer to where the
-- target USED to be.
--
-- WHAT IT GIVES.
--   * BOUNDED CONCURRENCY. At most `maxConcurrent` computations run at once;
--     the rest queue. A fleet-wide retarget becomes a short queue, not a spike.
--   * FAIRNESS BY AGE. Requests are picked by priority PLUS how long they have
--     waited, so a low-priority request cannot be starved by a steady stream of
--     urgent ones -- it simply gets more urgent the longer it sits.
--   * PRIORITY. A fleeing bot outranks a patroller. Same numbers as anywhere
--     else: higher wins.
--   * CANCELLATION. A goal that moves cancels its own in-flight request. If it
--     had not started yet, it never runs at all; if it had, its result is
--     delivered flagged `cancelled` so nobody walks a stale path.
--   * EXACTLY ONE ANSWER PER REQUEST. onComplete always fires once -- with the
--     result, or flagged `cancelled` -- including for a request cancelled before
--     it started and for one dropped by `reset`. A caller that suspends until its
--     answer arrives (PathAgent does) is therefore always resumed. A queued
--     request's cancellation is delivered on the next resumption cycle
--     (task.defer), never from inside `cancel` itself: the canceller is often the
--     very code the answer resumes.
--
-- WHAT IT DOES NOT DO. No caching or coalescing of similar requests -- a cache
-- would have to be invalidated whenever the map changes, and a stale entry sends
-- a bot through a wall that was built after the path was computed. Deliberately
-- out of scope until profiling says otherwise.
--
-- WORLD-AGNOSTIC, like everything else here. The broker takes a `compute`
-- CLOSURE, not a Path: it never touches PathfindingService, Vector3, or Enum,
-- and it has no idea what a "path" is. PathAgent supplies a closure that drives
-- ComputeAsync; a voxel A*, a flow field, or a precomputed link graph supplies
-- its own and gets the same queueing, priority, aging and cancellation. That is
-- the same rule the rest of the suite follows -- the world enters through a
-- function the consumer writes -- and it is why this module is pure enough to
-- test headlessly with no shims.
--
-- WHAT THE CLOSURE MUST GUARANTEE. If it captures state that only holds one
-- result at a time -- a Roblox `Path` does -- then only one request against that
-- state may be in flight. PathAgent guarantees this by suspending until its
-- result arrives; any other caller must do the same.

local Paths = {}

local DEFAULT_MAX_CONCURRENT = 4
-- Priority units added per second spent waiting. At 1.0, a request that has
-- queued for two seconds outranks one that arrived just now with a priority two
-- points higher -- which is what stops steady urgent traffic starving the rest.
local DEFAULT_AGE_BOOST = 1.0

export type Result = {
	ok: boolean, -- compute returned a value without throwing
	cancelled: boolean, -- superseded or destroyed; ignore the value
	value: any, -- whatever compute returned (nil when it failed or threw)
	err: string?, -- the error, when compute threw
	waited: number, -- seconds spent queued before the computation started
}

export type RequestSpec = {
	-- The work. MAY YIELD -- that is the whole point of the queue. Return your
	-- result on success and nil on failure; throwing is caught and reported.
	-- Everything Roblox-specific about a navmesh path lives in the closure the
	-- CALLER writes, which is what lets a voxel A*, a flow field, or a
	-- precomputed link graph share this queue with PathfindingService.
	compute: () -> any,
	priority: number?, -- higher runs sooner (default 0)
	-- Called exactly once: with the result, or flagged `cancelled` (also when the
	-- request was cancelled, or dropped by `reset`, before it ever started).
	onComplete: (result: Result) -> (),
}

export type Handle = {
	cancel: (Handle) -> (),
}

export type Stats = {
	queued: number, -- waiting for a slot right now
	active: number, -- computing right now
	completed: number, -- cumulative computations finished
	discarded: number, -- cumulative requests cancelled (queued or in flight)
	failed: number, -- cumulative computations that threw or returned nothing
	lastWaitSeconds: number, -- queue wait of the most recently started request
	maxWaitSeconds: number, -- worst queue wait seen
}

type Entry = {
	spec: RequestSpec,
	priority: number,
	enqueuedAt: number,
	cancelled: boolean,
	started: boolean, -- taken off the queue to compute
	delivered: boolean, -- onComplete has been called (it never is twice)
}

local queue: { Entry } = {}
local active = 0
local maxConcurrent = DEFAULT_MAX_CONCURRENT
local ageBoost = DEFAULT_AGE_BOOST

local completed = 0
local discarded = 0
local failed = 0
local lastWait = 0
local maxWait = 0

-- Tunables. `maxConcurrent` is the real dial: too low and a squad takes visible
-- seconds to all get moving, too high and you are back to the burst this exists
-- to prevent. 4 is a starting point, not a law.
function Paths.configure(options: { maxConcurrent: number?, ageBoost: number? })
	assert(type(options) == "table", "Pathfinding.Paths.configure: an options table is required")
	if options.maxConcurrent ~= nil then
		assert(
			type(options.maxConcurrent) == "number" and options.maxConcurrent >= 1,
			"Pathfinding.Paths.configure: maxConcurrent must be a number >= 1"
		)
		maxConcurrent = math.floor(options.maxConcurrent)
	end
	if options.ageBoost ~= nil then
		assert(
			type(options.ageBoost) == "number" and options.ageBoost >= 0,
			"Pathfinding.Paths.configure: ageBoost must be a number >= 0"
		)
		ageBoost = options.ageBoost
	end
end

function Paths.stats(): Stats
	return {
		queued = #queue,
		active = active,
		completed = completed,
		discarded = discarded,
		failed = failed,
		lastWaitSeconds = lastWait,
		maxWaitSeconds = maxWait,
	}
end

-- Highest priority + age wins; ties break toward whoever has waited longest.
local function bestIndex(now: number): number
	local best, bestScore = 1, -math.huge
	for index, entry in queue do
		local waited = now - entry.enqueuedAt
		local score = entry.priority + waited * ageBoost
		if score > bestScore then
			best, bestScore = index, score
		end
	end
	return best
end

local function deliver(entry: Entry, result: Result)
	if entry.delivered then
		return
	end
	entry.delivered = true
	local ok, err = pcall(entry.spec.onComplete, result)
	if not ok then
		warn(`[Pathfinding] a path request callback errored:\n{err}`)
	end
end

-- The answer to a request that never ran. Deferred rather than delivered here: whoever
-- cancels is often the code the answer resumes (an agent re-goaling cancels the
-- request its own loop is suspended on), and resuming that synchronously would run
-- the caller's continuation inside the canceller's frame.
local function deliverCancelled(entry: Entry)
	task.defer(deliver, entry, {
		ok = false,
		cancelled = true,
		value = nil,
		err = nil,
		waited = os.clock() - entry.enqueuedAt,
	} :: Result)
end

local pump: () -> ()

local function run(entry: Entry)
	local spec = entry.spec
	local waited = os.clock() - entry.enqueuedAt
	lastWait = waited
	if waited > maxWait then
		maxWait = waited
	end

	-- The caller's closure owns the yield -- which is exactly what the
	-- concurrency cap exists to bound -- and everything world-specific with it.
	local ran, value = pcall(spec.compute)
	local err: string? = if ran then nil else tostring(value)
	if ran and value == nil then
		ran = false -- compute ran but reported no result
	end

	active -= 1
	completed += 1
	if not ran then
		failed += 1
	end
	if entry.cancelled then
		discarded += 1
	end

	deliver(entry, {
		ok = ran and not entry.cancelled,
		cancelled = entry.cancelled,
		value = if ran then value else nil,
		err = err,
		waited = waited,
	})

	pump() -- a slot just freed
end

-- Start as many queued requests as the ceiling allows. Called when work arrives
-- and when work finishes -- there is no polling loop anywhere in this module.
function pump()
	while active < maxConcurrent and #queue > 0 do
		local now = os.clock()
		-- (a cancelled entry is never here: cancel takes it off the queue)
		local entry = table.remove(queue, bestIndex(now)) :: Entry
		entry.started = true
		active += 1
		task.spawn(run, entry)
	end
end

-- Queue a computation. Returns a handle whose `cancel` is safe at any time and
-- idempotent: before the computation starts it prevents it entirely (and the
-- caller still hears back, flagged `cancelled`, on the next resumption cycle);
-- after it starts the result arrives flagged `cancelled`.
function Paths.request(spec: RequestSpec): Handle
	assert(type(spec) == "table", "Pathfinding.Paths.request: a request table is required")
	assert(type(spec.compute) == "function", "Pathfinding.Paths.request: spec.compute is required")
	assert(type(spec.onComplete) == "function", "Pathfinding.Paths.request: spec.onComplete is required")

	local entry: Entry = {
		spec = spec,
		priority = spec.priority or 0,
		enqueuedAt = os.clock(),
		cancelled = false,
		started = false,
		delivered = false,
	}
	table.insert(queue, entry)

	local handle = {}
	function handle.cancel(_)
		if entry.cancelled then
			return
		end
		entry.cancelled = true
		if entry.started then
			return -- computing: its result arrives flagged `cancelled`
		end
		--[[
			Queued: it will never run, so its caller must still hear back. This used to leave
			the entry on the queue for `pump` to discard without a word -- and a PathAgent
			suspended on that request was never resumed, so an agent whose goal moved while
			the broker was saturated froze for good, still reporting Computing or Moving.
		]]
		local index = table.find(queue, entry)
		if index then
			table.remove(queue, index)
		end
		discarded += 1
		deliverCancelled(entry)
	end

	pump()
	return (handle :: any) :: Handle
end

-- Drop every queued request and reset the counters. Each dropped request still
-- hears back once, flagged `cancelled` (deferred, as for `cancel`). In-flight
-- computations cannot be stopped mid-yield; they keep their slot and deliver
-- their own result when they finish. For round transitions and tests.
function Paths.reset()
	local dropped = table.clone(queue)
	table.clear(queue)
	completed = 0
	discarded = 0
	failed = 0
	lastWait = 0
	maxWait = 0
	for _, entry in dropped do
		entry.cancelled = true
		deliverCancelled(entry)
	end
end

return Paths
