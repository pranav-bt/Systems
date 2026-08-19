-- Zone's enter/exit signals: ref identity across the event boundary, and the
-- isolation properties the module's error doctrine depends on.
--
-- WHY THIS FILE EXISTS. Zone used BindableEvents until subject types arrived. A
-- BindableEvent deep-copies a table argument and strips its metatable, so a
-- non-Instance subject reached its handler as a broken duplicate: `ref ~= theBot`,
-- methods gone, membership lookups failing. Instances were unaffected, which is
-- why five years of player-only use never revealed it. These checks would have
-- caught it -- had the shim not passed by reference, which it still does.
local rbx = require("./shim/roblox")
local Zone = require("./shim/library")("Zone")
local process = require("@lune/process")
local task = require("@lune/task")

local V = rbx.Vector3.new
local CF = rbx.CFrame.new
local PartType = rbx.Enum.PartType

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

local function sweep(seconds)
	rbx.step(seconds or 1)
end

-- A subject with a metatable and methods: exactly what a BindableEvent destroys.
local Bot = {}
Bot.__index = Bot
local function newBot(x, y, z)
	return setmetatable({ at = V(x or 0, y or 0, z or 0), health = 100 }, Bot)
end
function Bot.damage(self, amount)
	self.health -= amount
end

Zone.registerType("bot", function(b)
	return b.at
end)

local function boxZone(params)
	return Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, params)
end

print("a table subject survives the event intact")
do
	rbx.reset()
	local bot = newBot()
	Zone.track("bot", bot)
	local zone = boxZone({ types = { "bot" } })
	local received, receivedType
	zone.subjectEntered:Connect(function(ref, typeName)
		received, receivedType = ref, typeName
	end)
	sweep()

	check("the handler got the SAME object, not a copy", received == bot)
	check("with its type name", receivedType == "bot", receivedType)
	check("its metatable survived", getmetatable(received) == Bot)
	local ok = pcall(function()
		received:damage(25)
	end)
	check("its methods are callable", ok)
	check("and mutations reach the real subject", bot.health == 75, bot.health)
	check("membership lookup works on what was received", zone:IsSubjectInZone(received))
	check("equality against the original holds", received == bot)
	zone:Destroy()
	Zone.untrack("bot", bot)
end

print("onDestroyed hands over the live zone")
do
	rbx.reset()
	local zone = boxZone()
	local handed, methodWorked
	zone.onDestroyed:Connect(function(z)
		handed = z
		methodWorked = pcall(function()
			return z:GetSubjectsInZone()
		end)
	end)
	zone:Destroy()
	check("the handler got the zone itself", handed == zone)
	check("and can call methods on it", methodWorked)
end

print("a throwing handler is contained")
do
	rbx.reset()
	local bot = newBot()
	Zone.track("bot", bot)
	local zone = boxZone({ types = { "bot" } })
	local siblingRan = false
	zone.subjectEntered:Connect(function()
		error("handler is broken")
	end)
	zone.subjectEntered:Connect(function()
		siblingRan = true
	end)
	-- The error surfaces on its own thread (stderr above), exactly as a
	-- BindableEvent handler's would.
	local threw = not pcall(sweep)
	check("it does not propagate into the sweep", not threw)
	check("its sibling still ran", siblingRan)
	check("and membership was still recorded", zone:IsSubjectInZone(bot))
	zone:Destroy()
	Zone.untrack("bot", bot)
end

print("a yielding handler does not suspend the sweep")
do
	rbx.reset()
	local a, b = newBot(0, 0, 0), newBot(1, 0, 0)
	Zone.track("bot", a)
	Zone.track("bot", b)
	local zone = boxZone({ types = { "bot" } })
	zone.subjectEntered:Connect(function()
		task.wait() -- a direct call would stall the whole tick here
	end)
	sweep()
	check("both subjects were processed anyway", zone:CountInZone() == 2, zone:CountInZone())
	zone:Destroy()
	Zone.untrack("bot", a)
	Zone.untrack("bot", b)
end

print("connection semantics match RBXScriptSignal")
do
	rbx.reset()
	local bot = newBot()
	Zone.track("bot", bot)
	local zone = boxZone({ types = { "bot" } })

	local first, second = 0, 0
	local c1 = zone.subjectEntered:Connect(function()
		first += 1
	end)
	zone.subjectEntered:Connect(function()
		second += 1
	end)
	sweep()
	check("both connections fired", first == 1 and second == 1, `{first}/{second}`)

	c1:Disconnect()
	bot.at = V(100, 0, 0)
	sweep() -- exit
	bot.at = V(0, 0, 0)
	sweep() -- enter again
	check("a disconnected handler stops receiving", first == 1, first)
	check("the other keeps receiving", second == 2, second)
	check("Disconnect is idempotent", pcall(function()
		c1:Disconnect()
	end))
	zone:Destroy()
	Zone.untrack("bot", bot)
end

print("Once, Wait, and disconnect-during-fire")
do
	rbx.reset()
	local bot = newBot()
	Zone.track("bot", bot)
	local zone = boxZone({ types = { "bot" } })

	local onceCount = 0
	zone.subjectEntered:Once(function()
		onceCount += 1
	end)

	-- Wait must be connected before the fire, which task.spawn guarantees: it runs
	-- the body up to the yield inside Wait immediately.
	local waited
	task.spawn(function()
		local ref, typeName = zone.subjectEntered:Wait()
		waited = { ref = ref, typeName = typeName }
	end)

	-- A handler that unhooks a LATER one mid-fire: the loop must skip it, not
	-- call it and not lose its place.
	local laterRan = false
	local later
	zone.subjectEntered:Connect(function()
		if later then
			later:Disconnect()
		end
	end)
	later = zone.subjectEntered:Connect(function()
		laterRan = true
	end)

	sweep()
	check("Once fired", onceCount == 1, onceCount)
	check("Wait resumed with the ref", waited ~= nil and waited.ref == bot)
	check("Wait resumed with the type name", waited ~= nil and waited.typeName == "bot", waited and waited.typeName)
	check("a handler disconnected mid-fire did not run", not laterRan)

	bot.at = V(100, 0, 0)
	sweep()
	bot.at = V(0, 0, 0)
	sweep()
	check("Once did not fire a second time", onceCount == 1, onceCount)
	zone:Destroy()
	Zone.untrack("bot", bot)
end

print("the public face cannot be fired, and stops after Destroy")
do
	rbx.reset()
	local bot = newBot()
	Zone.track("bot", bot)
	local zone = boxZone({ types = { "bot" } })
	local fired = 0
	zone.subjectEntered:Connect(function()
		fired += 1
	end)
	check("no Fire on the public face", zone.subjectEntered.Fire == nil)
	check("so an event cannot be forged", not pcall(function()
		(zone.subjectEntered :: any):Fire(bot, "bot")
	end))
	check("Connect rejects a non-function", not pcall(function()
		zone.subjectEntered:Connect(42 :: any)
	end))

	sweep()
	check("a real sweep still delivers", fired == 1, fired)
	zone:Destroy()
	local afterDestroy = fired
	sweep()
	check("a destroyed zone is no longer swept", fired == afterDestroy, fired)
	-- That check alone is vacuous for Destroy's teardown: a destroyed zone has left
	-- the ticker, so nothing fires either way. Fire the private emitter directly.
	zone._subjectEnteredEvent:Fire(bot, "bot")
	check("Destroy marked the handlers disconnected", fired == afterDestroy, fired)
	-- White-box on purpose. Emptying the list is not a behaviour -- Fire already
	-- skips disconnected nodes -- it is about releasing the references: the nodes
	-- hold consumer closures, and a zone that keeps them pins whatever they capture
	-- for the lifetime of the game. Nothing observable proves that, so assert it.
	check("and released the list, so consumer closures can be collected", zone._subjectEnteredEvent._head == nil)
	check("including the tail pointer", zone._subjectEnteredEvent._tail == nil)
	Zone.untrack("bot", bot)
end

print(("\n%d passed, %d failed"):format(passed, failed))
-- Explicit, unlike the other suites: a deliberately throwing handler above lands
-- on its own thread, and Lune sets a non-zero exit code for that even though the
-- error was correctly contained. Without this, a green run would look like a
-- failure.
process.exit(if failed > 0 then 1 else 0)
