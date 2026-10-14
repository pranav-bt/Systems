-- The Paths broker's answer contract, and the two PathAgent failures it used to allow.
--
-- 1. EXACTLY ONE ANSWER PER REQUEST. A request cancelled while still queued used to be left on
--    the queue for `pump` to discard without a word. PathAgent suspends on its request until the
--    answer arrives, so an agent whose goal moved while the broker was saturated was never
--    resumed: frozen for good, still reporting Computing or Moving. Now every request hears back
--    once -- its result, or flagged `cancelled`.
-- 2. A NEAR-ENOUGH COMPUTATION FINISHES. SetGoal used to cancel the computation in flight on ANY
--    goal move. A chaser re-setting a target that shuffles a stud a tick then cancelled and
--    re-queued every tick, at the back of the broker each time, and under load never got a path.
--    Now it cancels only past repathThreshold -- the drift the walk itself tolerates.
--
-- The broker is pure (it takes compute closures), so it is driven with computations the test
-- holds open and releases by hand: that is how "the broker is saturated" is made exact.
local rbx = require("./shim/roblox")
local library = require("./shim/library")
local Paths = library("Pathfinding", "Paths")
local PathAgent = library("Pathfinding", "PathAgent")
local task = require("@lune/task")
local process = require("@lune/process")

local passed, failed = 0, 0
local function check(name, ok, detail)
	if ok then
		passed += 1
		print(("  ok   %s"):format(name))
	else
		failed += 1
		print(("  FAIL %s -- %s"):format(name, tostring(detail)))
	end
end

local V = rbx.Vector3.new

-- A computation that holds its broker slot until released.
local function gate()
	local g = { open = false, thread = nil :: thread? }
	function g.compute()
		if not g.open then
			g.thread = coroutine.running()
			coroutine.yield()
		end
		return "computed"
	end
	function g.release()
		g.open = true
		local thread = g.thread
		g.thread = nil
		if thread then
			task.spawn(thread)
		end
	end
	return g
end

-- Fill every slot (the default ceiling is 4) with gates; returns them for release.
local function saturate(): { any }
	local gates = {}
	for _ = 1, 4 do
		local g = gate()
		Paths.request({ compute = g.compute, onComplete = function() end })
		table.insert(gates, g)
	end
	return gates
end

local function releaseAll(gates: { any })
	for _, g in gates do
		g.release()
	end
	task.wait()
end

-- Records every answer a request gets.
local function recorder()
	local r = { answers = {} :: { any }, ran = 0 }
	function r.compute()
		r.ran += 1
		return "value"
	end
	function r.onComplete(result)
		table.insert(r.answers, result)
	end
	return r
end

print("a request cancelled while queued still hears back, once")
do
	Paths.reset()
	local gates = saturate()
	check("the broker is saturated", Paths.stats().active == 4, Paths.stats().active)

	local r = recorder()
	local handle = Paths.request({ compute = r.compute, onComplete = r.onComplete })
	check("the request queues", Paths.stats().queued == 1, Paths.stats().queued)

	local discardedBefore = Paths.stats().discarded
	handle:cancel()
	check("cancel takes it off the queue at once", Paths.stats().queued == 0, Paths.stats().queued)
	check("and counts it discarded", Paths.stats().discarded == discardedBefore + 1, Paths.stats().discarded)
	--[[
		Deferred, not synchronous: the canceller is often the very code the answer resumes (an
		agent re-goaling cancels the request its own loop is suspended on).
	]]
	check("the answer is not delivered from inside cancel", #r.answers == 0, #r.answers)

	task.wait()
	check("it is delivered on the next cycle", #r.answers == 1, #r.answers)
	local answer = r.answers[1]
	check("flagged cancelled", answer and answer.cancelled == true, answer and answer.cancelled)
	check("not ok, and with no value", answer and answer.ok == false and answer.value == nil, answer and answer.ok)
	check("with how long it waited", answer and type(answer.waited) == "number", answer and answer.waited)

	handle:cancel()
	task.wait()
	check("cancelling again changes nothing", #r.answers == 1, #r.answers)

	releaseAll(gates)
	check("its computation never ran, even once slots freed", r.ran == 0, r.ran)
	check("and it is still answered exactly once", #r.answers == 1, #r.answers)
end

print("a request cancelled mid-computation gets its result, flagged cancelled")
do
	Paths.reset()
	local g = gate()
	local answers = {}
	local handle = Paths.request({
		compute = g.compute,
		onComplete = function(result)
			table.insert(answers, result)
		end,
	})
	check("it started", Paths.stats().active == 1, Paths.stats().active)
	handle:cancel()
	task.wait()
	check("nothing is delivered while it still computes", #answers == 0, #answers)
	g.release()
	task.wait()
	check("the answer arrives when it finishes", #answers == 1, #answers)
	check("flagged cancelled and not ok", answers[1] and answers[1].cancelled and not answers[1].ok, answers[1])
	check("and its slot is free again", Paths.stats().active == 0, Paths.stats().active)
end

print("an uncancelled request is unaffected")
do
	Paths.reset()
	local r = recorder()
	Paths.request({ compute = r.compute, onComplete = r.onComplete })
	task.wait()
	check("it ran", r.ran == 1, r.ran)
	check("and was answered once, ok, with its value", #r.answers == 1 and r.answers[1].ok and r.answers[1].value == "value", r.answers[1])
end

print("reset answers every request it drops")
do
	Paths.reset()
	local gates = saturate()
	local a, b = recorder(), recorder()
	Paths.request({ compute = a.compute, onComplete = a.onComplete })
	Paths.request({ compute = b.compute, onComplete = b.onComplete })
	check("two queued", Paths.stats().queued == 2, Paths.stats().queued)
	Paths.reset()
	check("reset empties the queue", Paths.stats().queued == 0, Paths.stats().queued)
	task.wait()
	check("each dropped request hears back once, cancelled", #a.answers == 1 and #b.answers == 1 and a.answers[1].cancelled and b.answers[1].cancelled, `{#a.answers} {#b.answers}`)
	releaseAll(gates)
	check("and neither ever runs", a.ran == 0 and b.ran == 0, `{a.ran} {b.ran}`)
	check("the in-flight work kept its slots until it finished", Paths.stats().active == 0, Paths.stats().active)
end

-- PathAgent --------------------------------------------------------------------------------------

local function newAgent()
	local model = rbx.Instance.new("Model")
	model.Parent = rbx.workspace
	local humanoid = rbx.Instance.new("Humanoid")
	humanoid.Parent = model
	local root = rbx.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Parent = model
	return PathAgent.new(humanoid, root, { repathThreshold = 8 })
end

-- Count the agent's requests: it calls Paths.request through the module table it shares with us.
local requests = 0
local realRequest = Paths.request
Paths.request = function(spec)
	requests += 1
	return realRequest(spec)
end

print("an agent whose goal moves while it is queued is not frozen")
do
	Paths.reset()
	local gates = saturate()
	requests = 0
	local agent = newAgent()
	agent:SetGoal(V(100, 0, 0))
	check("its first computation is requested", requests == 1, requests)
	check("and queued behind the full broker", Paths.stats().queued == 1, Paths.stats().queued)

	agent:SetGoal(V(-100, 0, 0)) -- far past repathThreshold: that computation is for the wrong place
	task.wait()
	--[[
		THE BUG. Before the fix the cancelled request sat on the queue, the agent stayed suspended
		on it, and no second request was ever made -- the agent was frozen, reporting Computing.
	]]
	check("it hears its request was cancelled and asks again", requests == 2, requests)
	check("one live request queued, not a stale one", Paths.stats().queued == 1, Paths.stats().queued)
	check("still reporting Computing, truthfully", agent:GetStatus() == "Computing", agent:GetStatus())

	agent:Stop()
	task.wait()
	check("Stop cancels it and the agent goes back to sleep", Paths.stats().queued == 0 and requests == 2, `{Paths.stats().queued} {requests}`)

	agent:SetGoal(V(50, 0, 50))
	check("and wakes for a new goal", requests == 3, requests)
	agent:Destroy()
	task.wait()
	check("Destroy cancels it and the loop exits without asking again", requests == 3 and Paths.stats().queued == 0, `{requests} {Paths.stats().queued}`)
	releaseAll(gates)
end

print("a goal that moves less than repathThreshold lets the computation finish")
do
	Paths.reset()
	local gates = saturate()
	requests = 0
	local agent = newAgent()
	local target = V(100, 0, 0)
	agent:SetGoal(target)
	local discarded = Paths.stats().discarded

	-- a chaser re-setting a target that shuffles a little each tick
	for step = 1, 10 do
		agent:SetGoal(target + V(step * 0.5, 0, 0))
	end
	task.wait()
	check("no cancellation for a 5-stud drift", Paths.stats().discarded == discarded, Paths.stats().discarded - discarded)
	check("no re-request", requests == 1, requests)
	check("the original request is still the one queued", Paths.stats().queued == 1, Paths.stats().queued)

	agent:SetGoal(target + V(20, 0, 0)) -- now past the threshold
	task.wait()
	check("drift past repathThreshold does cancel", Paths.stats().discarded == discarded + 1, Paths.stats().discarded - discarded)
	check("and the agent asks again for the new goal", requests == 2, requests)

	agent:Destroy()
	task.wait()
	releaseAll(gates)
end

Paths.request = realRequest
print(("%d passed, %d failed"):format(passed, failed))
process.exit(if failed > 0 then 1 else 0)
