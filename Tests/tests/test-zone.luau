-- Headless checks for the Zone rewrite, against a minimal Roblox shim with a
-- manually-stepped Heartbeat, so timing is asserted rather than sampled.
local rbx = require("./shim/roblox")
local Zone = require("./shim/library")("Zone")

local V = rbx.Vector3.new
local CF = rbx.CFrame.new
local PartType = rbx.Enum.PartType

-- Pin the phase jitter off, so a step of `interval` always lands a sweep and the
-- timing assertions below stay exact. Spreading is asserted separately.
Zone.setRandom(function()
	return 0
end)

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

-- Run one full sweep: the interval starts AT its threshold, so a single step is
-- enough for the first sweep; later sweeps need `interval` worth of time.
local function sweep(seconds)
	rbx.step(seconds or 1)
end

print("geometry: box, cylinder and sphere")
do
	local box = Zone.new(CF(0, 0, 0), V(10, 4, 6), PartType.Block)
	check("box: centre is inside", box:Contains(V(0, 0, 0)))
	check("box: just inside each face", box:Contains(V(4.9, 1.9, 2.9)))
	check("box: just outside X", not box:Contains(V(5.1, 0, 0)))
	check("box: just outside Y", not box:Contains(V(0, 2.1, 0)))
	check("box: just outside Z", not box:Contains(V(0, 0, 3.1)))
	check("box: corner beyond the bounding sphere", not box:Contains(V(100, 100, 100)))
	box:Destroy()

	-- Roblox cylinders: height along X, Y and Z are the cross-section diameters.
	local cyl = Zone.new(CF(0, 0, 0), V(10, 8, 4), PartType.Cylinder)
	check("cylinder: centre is inside", cyl:Contains(V(0, 0, 0)))
	check("cylinder: within half-height", cyl:Contains(V(4.9, 0, 0)))
	check("cylinder: beyond half-height", not cyl:Contains(V(5.1, 0, 0)))
	check("cylinder: on the Y semi-axis", cyl:Contains(V(0, 3.9, 0)))
	check("cylinder: past the Y semi-axis", not cyl:Contains(V(0, 4.1, 0)))
	-- The old code used Y/2 as a single radius and ignored Z entirely, so a point
	-- 3 studs out along Z (semi-axis 2) read as INSIDE. It must not.
	check("cylinder: Z is not ignored", not cyl:Contains(V(0, 0, 3)), "the old radius bug is back")
	check("cylinder: within the Z semi-axis", cyl:Contains(V(0, 0, 1.9)))
	cyl:Destroy()

	local ball = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Ball)
	check("ball: centre is inside", ball:Contains(V(0, 0, 0)))
	check("ball: on the radius", ball:Contains(V(4.9, 0, 0)))
	check("ball: past the radius", not ball:Contains(V(5.1, 0, 0)))
	-- A corner of the bounding box is outside the sphere.
	check("ball: box corner is outside", not ball:Contains(V(4, 4, 4)))
	ball:Destroy()

	-- Non-uniform ball: an ellipsoid, not a silent single-axis guess.
	local ellipsoid = Zone.new(CF(0, 0, 0), V(20, 4, 4), PartType.Ball)
	check("ellipsoid: long axis", ellipsoid:Contains(V(9.9, 0, 0)))
	check("ellipsoid: past the long axis", not ellipsoid:Contains(V(10.1, 0, 0)))
	check("ellipsoid: short axis", not ellipsoid:Contains(V(0, 2.1, 0)))
	ellipsoid:Destroy()
end

print("geometry: rotation is respected")
do
	-- A long thin box turned 90 degrees about Y: what was reachable along X is now
	-- reachable along Z.
	local turned = Zone.new(rbx.CFrame.yaw(V(0, 0, 0), math.pi / 2), V(20, 4, 2), PartType.Block)
	check("rotated: along the new long axis", turned:Contains(V(0, 0, 9)))
	check("rotated: not along the old one", not turned:Contains(V(9, 0, 0)))
	turned:Destroy()
end

print("membership: enter and exit fire once each")
do
	rbx.reset()
	local player = rbx.addPlayer("A", V(100, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	local entered, exited = 0, 0
	zone.playerEntered:Connect(function()
		entered += 1
	end)
	zone.playerExited:Connect(function()
		exited += 1
	end)

	sweep()
	check("outside: nothing fires", entered == 0 and exited == 0, `{entered}/{exited}`)
	check("count is 0", zone.playerCountInZone == 0, zone.playerCountInZone)

	rbx.movePlayer(player, V(0, 0, 0))
	sweep()
	check("entered once", entered == 1, entered)
	check("count is 1", zone.playerCountInZone == 1, zone.playerCountInZone)
	check("IsPlayerInZone agrees", zone:IsPlayerInZone(player))

	sweep()
	check("staying inside does not re-fire", entered == 1 and exited == 0, `{entered}/{exited}`)

	rbx.movePlayer(player, V(100, 0, 0))
	sweep()
	check("exited once", exited == 1, exited)
	check("count back to 0", zone.playerCountInZone == 0, zone.playerCountInZone)
	check("GetPlayersInZone is empty", #zone:GetPlayersInZone() == 0)
	zone:Destroy()
end

print("membership: losing a character exits the player")
do
	rbx.reset()
	local player = rbx.addPlayer("B", V(0, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	local exited = 0
	zone.playerExited:Connect(function()
		exited += 1
	end)
	sweep()
	check("inside first", zone:IsPlayerInZone(player))
	rbx.dropCharacter(player)
	sweep()
	check("exited when the character went away", exited == 1, exited)
	check("count is 0", zone.playerCountInZone == 0, zone.playerCountInZone)
	zone:Destroy()
end

print("membership: PlayerRemoving exits the player")
do
	rbx.reset()
	local player = rbx.addPlayer("C", V(0, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	local exited = 0
	zone.playerExited:Connect(function()
		exited += 1
	end)
	sweep()
	check("inside first", zone:IsPlayerInZone(player))
	rbx.removePlayer(player)
	check("exited immediately on removal", exited == 1, exited)
	zone:Destroy()
end

print("ticker: one shared Heartbeat connection for any number of zones")
do
	rbx.reset()
	local before = rbx.heartbeatConnections()
	local zones = {}
	for index = 1, 8 do
		table.insert(zones, Zone.new(CF(0, 0, 0), V(4, 4, 4), PartType.Block, nil, { Name = `z{index}` }))
	end
	check("8 zones added 1 connection, not 8", rbx.heartbeatConnections() - before == 1, rbx.heartbeatConnections() - before)
	for _, zone in zones do
		zone:Destroy()
	end
	check("the connection is released with the last zone", rbx.heartbeatConnections() == before, rbx.heartbeatConnections())
end

print("ticker: the player snapshot is gathered once per frame, not once per zone")
do
	rbx.reset()
	local player = rbx.addPlayer("D", V(0, 0, 0))
	-- Count how often the character is asked for its root: the shim's Character
	-- proxy records each FindFirstChild.
	local lookups = 0
	local realFind = player.Character.FindFirstChild
	player.Character.FindFirstChild = function(self, key)
		lookups += 1
		return realFind(self, key)
	end

	local zones = {}
	for index = 1, 6 do
		table.insert(zones, Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { Name = `s{index}` }))
	end
	sweep()
	-- Six zones, one player: the root is resolved once and cached, not six times.
	check("at most one root lookup for 6 zones", lookups <= 1, lookups)
	sweep()
	check("and none on the next sweep (cached)", lookups <= 1, lookups)
	for _, zone in zones do
		zone:Destroy()
	end
end

print("timing: the interval does not drift")
do
	rbx.reset()
	rbx.addPlayer("E", V(0, 0, 0))
	local sweeps = 0
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { ZoneUpdateInterval = 1 })
	zone.intervalCallback = function()
		sweeps += 1
	end
	-- 120 frames of 1/60s = exactly 2 seconds. Zeroing the timer instead of
	-- subtracting used to lose the overshoot every cycle and run slow.
	for _ = 1, 120 do
		rbx.step(1 / 60)
	end
	-- First sweep is immediate, then one per second: 1 + 2 = 3.
	check("3 interval callbacks across 2 seconds", sweeps == 3, sweeps)
	zone:Destroy()
end

print("UpdateZone refreshes the cached bounds")
do
	rbx.reset()
	local player = rbx.addPlayer("F", V(40, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	sweep()
	check("outside to begin with", not zone:IsPlayerInZone(player))

	-- Move the zone onto the player. If the cached centre were stale this would
	-- keep testing the old position and never notice.
	zone:UpdateZone(CF(40, 0, 0), V(10, 10, 10))
	check("Contains uses the new centre immediately", zone:Contains(V(40, 0, 0)))
	sweep()
	check("the sweep sees them inside", zone:IsPlayerInZone(player))

	-- Resize down so they fall outside, without moving anything.
	zone:UpdateZone(CF(40, 0, 0), V(1, 1, 1))
	rbx.movePlayer(player, V(42, 0, 0))
	sweep()
	check("a resize is picked up too", not zone:IsPlayerInZone(player))
	zone:Destroy()
end

print("moving the part directly is caught and self-healed")
do
	rbx.reset()
	local player = rbx.addPlayer("G", V(60, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	sweep()
	check("outside", not zone:IsPlayerInZone(player))
	-- Bypass the API, which the header explicitly tells you not to do.
	zone.zoneInstance.CFrame = CF(60, 0, 0)
	sweep() -- should warn once and refresh
	check("the sweep recovered", zone:IsPlayerInZone(player), "stale bounds went unnoticed")
	zone:Destroy()
end

print("Destroy: idempotent, clears state, and fires onDestroyed")
do
	rbx.reset()
	local player = rbx.addPlayer("H", V(0, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	local exited, destroyed = 0, 0
	zone.playerExited:Connect(function()
		exited += 1
	end)
	zone.onDestroyed:Connect(function()
		destroyed += 1
	end)
	sweep()
	check("inside before teardown", zone:IsPlayerInZone(player))

	zone:Destroy()
	check("exit fired for the occupant", exited == 1, exited)
	check("onDestroyed fired on an explicit Destroy", destroyed == 1, destroyed)
	check("membership cleared", #zone:GetPlayersInZone() == 0, #zone:GetPlayersInZone())
	check("count reset", zone.playerCountInZone == 0, zone.playerCountInZone)

	zone:Destroy() -- second call: used to re-fire every exit, on destroyed events
	check("a second Destroy is a no-op", exited == 1 and destroyed == 1, `{exited}/{destroyed}`)
end

print("Destroy: destroying the part still tears the zone down")
do
	rbx.reset()
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	local destroyed = 0
	zone.onDestroyed:Connect(function()
		destroyed += 1
	end)
	local before = rbx.heartbeatConnections()
	zone.zoneInstance:Destroy()
	check("onDestroyed fired", destroyed == 1, destroyed)
	check("and it unregistered from the ticker", rbx.heartbeatConnections() < before or before == 1, rbx.heartbeatConnections())
end

print("validation rejects what used to fail silently")
do
	check("Wedge is refused", not (pcall(Zone.new, CF(0, 0, 0), V(4, 4, 4), PartType.Wedge)))
	check("a zero extent is refused", not (pcall(Zone.new, CF(0, 0, 0), V(4, 0, 4), PartType.Block)))
	check(
		"a non-positive interval is refused",
		not (pcall(Zone.new, CF(0, 0, 0), V(4, 4, 4), PartType.Block, nil, { ZoneUpdateInterval = 0 }))
	)
	local zone = Zone.new(CF(0, 0, 0), V(4, 4, 4), PartType.Block)
	check("UpdateZoneInterval rejects 0", not (pcall(zone.UpdateZoneInterval, zone, 0)))
	check("UpdateZoneInterval rejects negatives", not (pcall(zone.UpdateZoneInterval, zone, -1)))
	check("UpdateZoneInterval accepts a positive", pcall(zone.UpdateZoneInterval, zone, 0.25))
	check("UpdateZone rejects a zero extent", not (pcall(zone.UpdateZone, zone, CF(0, 0, 0), V(0, 4, 4))))
	zone:Destroy()
end

print("a zone destroyed by an enter handler does not break the sweep")
do
	rbx.reset()
	rbx.addPlayer("I", V(0, 0, 0))
	rbx.addPlayer("J", V(0, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	local other = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { Name = "other" })
	local otherEntered = 0
	other.playerEntered:Connect(function()
		otherEntered += 1
	end)
	zone.playerEntered:Connect(function()
		zone:Destroy() -- suicide mid-sweep, on the first of two players
	end)
	local ok = pcall(sweep)
	check("the sweep survived", ok, "it threw")
	check("the other zone still ran", otherEntered == 2, otherEntered)
	other:Destroy()
end

print("R1 - a throwing intervalCallback cannot break other zones")
do
	rbx.reset()
	rbx.addPlayer("R1a", V(0, 0, 0))
	-- Two zones, both due on the same frame. The first one's callback throws.
	local bad = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { Name = "bad" })
	local good = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { Name = "good" })
	local goodTicks, goodEntered = 0, 0
	bad.intervalCallback = function()
		error("callback boom")
	end
	good.intervalCallback = function()
		goodTicks += 1
	end
	good.playerEntered:Connect(function()
		goodEntered += 1
	end)

	local ok = pcall(sweep)
	check("the shared ticker survived", ok, "it threw out of Heartbeat")
	check("the healthy zone still swept", goodTicks == 1, goodTicks)
	check("and still fired its enter", goodEntered == 1, goodEntered)
	-- The bad zone must still have processed membership: only the callback failed.
	check("the bad zone still tracked membership", bad.playerCountInZone == 1, bad.playerCountInZone)
	bad:Destroy()
	good:Destroy()
end

print("R1 - a throwing callback does not abort the rest of its OWN sweep")
do
	rbx.reset()
	rbx.addPlayer("R1b", V(0, 0, 0))
	rbx.addPlayer("R1c", V(0, 0, 0))
	rbx.addPlayer("R1d", V(0, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { Name = "throwsEveryTime" })
	local entered = 0
	zone.playerEntered:Connect(function()
		entered += 1
	end)
	zone.intervalCallback = function()
		error("boom")
	end
	local ok = pcall(sweep)
	check("the sweep completed", ok, "it threw")
	-- All three must be admitted: the callback throwing for the first player must
	-- not stop the second and third being processed.
	check("every player was still processed", entered == 3, entered)
	check("count is 3", zone.playerCountInZone == 3, zone.playerCountInZone)
	zone:Destroy()
end

print("R1 - a zone whose sweep throws outright is isolated too")
do
	rbx.reset()
	rbx.addPlayer("R1e", V(0, 0, 0))
	local broken = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { Name = "broken" })
	local healthy = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { Name = "healthy" })
	local healthyTicks = 0
	healthy.intervalCallback = function()
		healthyTicks += 1
	end
	-- Sabotage the zone's own internals, standing in for a library-side fault
	-- rather than a consumer one.
	broken._test = function()
		error("internal fault")
	end
	local ok = pcall(sweep)
	check("the ticker survived a library-side throw", ok, "it threw")
	check("the healthy zone was unaffected", healthyTicks == 1, healthyTicks)
	broken:Destroy()
	healthy:Destroy()
end

print("R2 - Contains self-heals stale bounds, not just the sweep")
do
	rbx.reset()
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	check("inside before the move", zone:Contains(V(0, 0, 0)))
	-- Bypass UpdateZone, then ask Contains DIRECTLY -- no sweep in between. Before
	-- this fix the staleness check lived only in _Sweep, so Contains happily
	-- answered for the old volume.
	zone.zoneInstance.CFrame = CF(80, 0, 0)
	check("Contains sees the new centre", zone:Contains(V(80, 0, 0)), "answered for the old volume")
	check("and no longer the old one", not zone:Contains(V(0, 0, 0)))
	-- A resize with no move, same story.
	zone.zoneInstance.Size = V(2, 2, 2)
	check("Contains sees the new size", not zone:Contains(V(83, 0, 0)))
	check("still inside the smaller volume", zone:Contains(V(80, 0, 0)))
	zone:Destroy()
end

print("R2 - the gate warns once, not once per call")
do
	rbx.reset()
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	zone.zoneInstance.CFrame = CF(50, 0, 0)
	-- First call refreshes; the rest find the cache current.
	for _ = 1, 20 do
		zone:Contains(V(50, 0, 0))
	end
	check("repeated calls stay correct", zone:Contains(V(50, 0, 0)))
	check("and the cache matches the instance", zone._cachedCFrame == zone.zoneInstance.CFrame)
	zone:Destroy()
end

print("adopting a part: only a Part has a Shape to set")
do
	rbx.reset()
	-- MeshPart, UnionOperation and TrussPart are BaseParts with no Shape property.
	-- Zone.new used to reach line 2 of its own property writes and die with
	-- "Shape is not a valid member of MeshPart" -- an error from inside the library
	-- about a property the caller never mentioned.
	local mesh = rbx.Instance.new("MeshPart")
	local ok, err = pcall(function()
		return Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, mesh)
	end)
	check("adopting a MeshPart is refused", not ok)
	check("the message names the class", ok == false and string.find(tostring(err), "MeshPart") ~= nil, err)
	check("and says what to do instead", ok == false and string.find(tostring(err), "Pass nil") ~= nil, err)
	check("it failed before touching the part", mesh.Anchored == false, mesh.Anchored)

	-- The supported path is unchanged.
	local part = rbx.Instance.new("Part")
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, part)
	check("adopting a real Part still works", zone.zoneInstance == part)
	check("and it is configured as a zone part", part.Anchored and not part.CanCollide and not part.CanQuery)
	zone:Destroy()
end

print("phase spreading: many zones do not all sweep on one frame")
do
	rbx.reset()
	for i = 1, 30 do
		rbx.addPlayer("P" .. i, V(i * 3, 0, 0))
	end

	-- A deterministic spread of offsets across [0, 1): enough to prove the zones
	-- scatter, without depending on a real RNG.
	local nth = 0
	Zone.setRandom(function()
		nth += 1
		return (nth % 50) / 50
	end)

	local tests = 0
	local realContains = Zone.Contains
	Zone.Contains = function(self, position)
		tests += 1
		return realContains(self, position)
	end

	local zones = {}
	for i = 1, 50 do
		zones[i] = Zone.new(CF(i * 8, 0, 0), V(6, 6, 6), PartType.Block, nil, { ZoneUpdateInterval = 1 })
	end
	rbx.step(1 / 60) -- the deliberate startup sweep: every zone is due at once

	local busy, worst, total = 0, 0, 0
	for _ = 1, 90 do
		tests = 0
		rbx.step(1 / 60)
		if tests > 0 then
			busy += 1
		end
		worst = math.max(worst, tests)
		total += tests
	end

	Zone.Contains = realContains
	for _, zone in zones do
		zone:Destroy()
	end
	Zone.setRandom(function()
		return 0
		end)

	-- Before this fix: 2 busy frames out of 90, worst frame 1500.
	check("the work lands on many frames, not one or two", busy >= 20, busy)
	check("and no single frame carries the whole fleet", worst < 1500, worst)
	check("without losing work overall", total > 0, total)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("zone check failed")
end
