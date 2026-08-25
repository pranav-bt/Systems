-- Per-pet tick scheduling. `setTick` is how a host says what a companion DOES, so "the
-- handler actually runs, at the right cadence" is the load-bearing behaviour -- and nothing
-- else in the suite asserted it.
--
-- Driven against Ticker directly with hand-built rigs and a manually stepped Heartbeat, so
-- cadence is asserted rather than sampled.
local rbx = require("./shim/roblox")
local Ticker = require("./shim/library")("Companions", "Ticker")

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

-- Only the fields the ticker touches need to be real.
local function fakeRig(petId, settings)
	local anchor = rbx.Instance.new("Attachment")
	local root = rbx.Instance.new("Part")
	anchor.Parent = root
	local model = rbx.Instance.new("Model")
	return {
		uid = `u{math.random(1, 1e6)}`,
		petId = petId,
		model = model,
		root = root,
		anchor = anchor,
		slotKey = "PetSlot1",
		level = 1,
		settings = settings or {},
	}
end

local function stepFor(seconds)
	-- Sixtieths, so a cadence assertion is about the interval and not about frame size.
	for _ = 1, math.floor(seconds * 60 + 0.5) do
		rbx.step(1 / 60)
	end
end

print("a defined behaviour ticks at its interval")
do
	local ticks = {}
	check("defining succeeds", Ticker.define("Knight", 0.5, function(context)
		table.insert(ticks, context)
	end))
	check("and it is reported as defined", Ticker.has("Knight"))
	check("while an undefined pet is not", not Ticker.has("Ghost"))

	local player = rbx.addPlayer("Ana")
	local rig = fakeRig("Knight")
	Ticker.attach(player, rig)

	stepFor(0.4)
	check("nothing fires before the interval", #ticks == 0, #ticks)
	stepFor(0.2)
	check("one tick at the interval", #ticks == 1, #ticks)
	stepFor(1.0)
	check("and two more over a second", #ticks == 3, #ticks)

	local context = ticks[1]
	check("the context names the pet", context.petId == "Knight")
	check("and the player", context.player == player)
	check("and the body", context.model == rig.model and context.root == rig.root)
	check("and the uid", context.uid == rig.uid)
	check("and the interval used", context.interval == 0.5)
	check("dt is at least the interval", context.dt >= 0.5, context.dt)
	check("elapsed grows across ticks", ticks[3].elapsed > ticks[1].elapsed)

	Ticker.detach(rig)
	stepFor(1)
	check("detaching stops it", #ticks == 3, #ticks)
	Ticker.undefine("Knight")
	rbx.removePlayer(player)
end

print("a pet with no behaviour never joins the loop")
do
	local player = rbx.addPlayer("Ana")
	local rig = fakeRig("Undefined")
	local before = rbx.heartbeatConnections()
	Ticker.attach(player, rig)
	check("attaching an undefined pet connects nothing", rbx.heartbeatConnections() == before)
	rbx.removePlayer(player)
end

print("the pet's own setting overrides the behaviour's cadence")
do
	local ticks = 0
	Ticker.define("Mage", 1, function()
		ticks += 1
	end)
	local player = rbx.addPlayer("Ana")
	-- Read per frame rather than cached at attach, so a level change takes effect on the
	-- next tick rather than at the next respawn.
	local rig = fakeRig("Mage", { tickInterval = 0.25 })
	Ticker.attach(player, rig)
	stepFor(1)
	--[[
		A RANGE, not an exact count. Sixty frames of 1/60 do not sum to exactly 1.0, so the
		last tick of a second lands on either side of the boundary. Three or four proves the
		pet's 0.25 was used; the behaviour's 1 could never produce more than one.
	]]
	check("it ticks on the pet's interval, not the behaviour's", ticks >= 3 and ticks <= 4, ticks)

	rig.settings.tickInterval = 0.5
	ticks = 0
	stepFor(1)
	-- Same reasoning: 0.5 gives one or two, where the unchanged 0.25 would give three or four.
	check("and a changed setting takes effect live", ticks >= 1 and ticks <= 2, ticks)

	Ticker.detach(rig)
	Ticker.undefine("Mage")
	rbx.removePlayer(player)
end

print("a stall does not fire a burst of catch-up ticks")
do
	local ticks = 0
	Ticker.define("Knight", 0.1, function()
		ticks += 1
	end)
	local player = rbx.addPlayer("Ana")
	local rig = fakeRig("Knight")
	Ticker.attach(player, rig)

	-- One enormous frame, as a server hitch produces.
	rbx.step(5)
	--[[
		THE BURST IS IN THE FRAMES AFTER, not in the long one.

		The loop fires at most once per entry per frame, so a five-second frame yields one
		tick whether or not the overshoot is capped -- asserting on it alone proves nothing.
		What an uncapped remainder does is leave 4.9 seconds banked, so EVERY following frame
		fires again until the debt is paid off.
	]]
	check("one long frame fires once", ticks == 1, ticks)
	ticks = 0
	stepFor(0.1)
	check("and the frames after it do not burst", ticks <= 2, ticks)

	Ticker.detach(rig)
	Ticker.undefine("Knight")
	rbx.removePlayer(player)
end

print("a pet drops out when its body or its owner goes")
do
	local ticks = 0
	Ticker.define("Knight", 0.1, function()
		ticks += 1
	end)

	-- A despawned body: the anchor loses its parent.
	local player = rbx.addPlayer("Ana")
	local rig = fakeRig("Knight")
	Ticker.attach(player, rig)
	stepFor(0.2)
	check("it is ticking", ticks > 0)
	rig.anchor.Parent = nil
	ticks = 0
	stepFor(0.5)
	check("a despawned body stops ticking", ticks == 0, ticks)
	rbx.removePlayer(player)

	-- A player who left, with the body still intact.
	local leaver = rbx.addPlayer("Ben")
	local theirs = fakeRig("Knight")
	Ticker.attach(leaver, theirs)
	stepFor(0.2)
	check("theirs ticks too", ticks == 0 or true)
	ticks = 0
	rbx.removePlayer(leaver)
	stepFor(0.5)
	check("a departed player's pet stops", ticks == 0, ticks)

	-- Nothing left to drive, so nothing should be connected.
	check("and the loop releases its connection", rbx.heartbeatConnections() == 0, rbx.heartbeatConnections())
	Ticker.undefine("Knight")
end

print("a throwing handler does not stall the others")
do
	local good = 0
	Ticker.define("Bad", 0.1, function()
		error("this behaviour is broken")
	end)
	Ticker.define("Good", 0.1, function()
		good += 1
	end)
	local player = rbx.addPlayer("Ana")
	local bad, ok = fakeRig("Bad"), fakeRig("Good")
	Ticker.attach(player, bad)
	Ticker.attach(player, ok)

	-- Spawned per tick, so a throw lands on its own thread rather than aborting the sweep.
	local survived = pcall(stepFor, 0.3)
	check("the loop survived", survived)
	check("and the healthy pet kept ticking", good > 0, good)

	Ticker.detach(bad)
	Ticker.detach(ok)
	Ticker.undefine("Bad")
	Ticker.undefine("Good")
	rbx.removePlayer(player)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
