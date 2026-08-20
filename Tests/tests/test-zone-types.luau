-- Headless checks for Zone's subject-type registry: arbitrary populations, the
-- maintained (never polled) sets, per-zone include/exclude, and the compatibility
-- of the player-shaped API that existed before any of this.
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

local function sweep(seconds)
	rbx.step(seconds or 1)
end

-- A subject with no character, no HumanoidRootPart and no Instance at all: the
-- case the old HRP assumption could not express.
local function bot(x, y, z)
	return { at = V(x, y, z) }
end

Zone.registerType("bot", function(b)
	return b.at
end)

print("a population with no Instance behind it")
do
	rbx.reset()
	local ally = bot(0, 0, 0)
	local far = bot(100, 0, 0)
	Zone.track("bot", ally)
	Zone.track("bot", far)

	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "bot" } })
	local entered, exited = {}, {}
	zone.subjectEntered:Connect(function(ref, typeName)
		table.insert(entered, { ref = ref, typeName = typeName })
	end)
	zone.subjectExited:Connect(function(ref)
		table.insert(exited, ref)
	end)

	sweep()
	check("the bot inside entered", #entered == 1 and entered[1].ref == ally, #entered)
	check("and carried its type name", #entered == 1 and entered[1].typeName == "bot", entered[1] and entered[1].typeName)
	check("the far bot did not", not zone:IsSubjectInZone(far))
	check("CountInZone() counts it", zone:CountInZone() == 1, zone:CountInZone())
	check("CountInZone('bot') counts it", zone:CountInZone("bot") == 1, zone:CountInZone("bot"))

	-- The user's F1 question in one assertion: position tracking for a subject the
	-- module cannot introspect at all.
	ally.at = V(100, 0, 0)
	sweep()
	check("moving a plain-table subject exits it", #exited == 1 and exited[1] == ally, #exited)

	-- Untracking is the despawn path, and it must not need a zone to be told.
	ally.at = V(0, 0, 0)
	sweep()
	check("re-entering works", zone:IsSubjectInZone(ally))
	Zone.untrack("bot", ally)
	sweep()
	check("untracking exits it", not zone:IsSubjectInZone(ally))
	check("and the count went back to zero", zone:CountInZone() == 0, zone:CountInZone())

	zone:Destroy()
	Zone.untrack("bot", far)
end

print("player-shaped API stays player-shaped")
do
	rbx.reset()
	local b = bot(0, 0, 0)
	Zone.track("bot", b)
	local player = rbx.addPlayer("Ana", V(0, 0, 0))

	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "player", "bot" } })
	sweep()
	check("both are inside", zone:CountInZone() == 2, zone:CountInZone())
	check("playerCountInZone counts only the player", zone.playerCountInZone == 1, zone.playerCountInZone)
	check("GetPlayersInZone returns only the player", #zone:GetPlayersInZone() == 1, #zone:GetPlayersInZone())
	check("GetPlayersInZone returns the right one", zone:GetPlayersInZone()[1] == player)
	check("IsPlayerInZone is false for a bot", not zone:IsPlayerInZone(b))
	check("IsSubjectInZone is true for a bot", zone:IsSubjectInZone(b))
	check("GetSubjectsInZone('bot') is just the bot", #zone:GetSubjectsInZone("bot") == 1)
	check("GetSubjectsInZone() is both", #zone:GetSubjectsInZone() == 2, #zone:GetSubjectsInZone())
	zone:Destroy()
	Zone.untrack("bot", b)
end

print("a bot-only zone reports zero players, as documented")
do
	rbx.reset()
	local b = bot(0, 0, 0)
	Zone.track("bot", b)
	rbx.addPlayer("Ana", V(0, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "bot" } })
	sweep()
	check("the bot is in", zone:CountInZone() == 1, zone:CountInZone())
	check("playerCountInZone is 0", zone.playerCountInZone == 0, zone.playerCountInZone)
	check("the co-located player was never tested", #zone:GetPlayersInZone() == 0)
	zone:Destroy()
	Zone.untrack("bot", b)
end

print("playerEntered is the same signal, and old handlers still work")
do
	rbx.reset()
	local player = rbx.addPlayer("Ana", V(0, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block)
	local seen = nil
	-- Written the way every existing consumer wrote it: one parameter.
	zone.playerEntered:Connect(function(who)
		seen = who
	end)
	check("playerEntered and subjectEntered are one signal", zone.playerEntered == zone.subjectEntered)
	check("playerExited and subjectExited are one signal", zone.playerExited == zone.subjectExited)
	sweep()
	check("a single-argument handler still receives the player", seen == player)
	check("playersInZone is the same table as subjectsInZone", zone.playersInZone == zone.subjectsInZone)
	check("and a truthiness check on it still reads correctly", zone.playersInZone[player] ~= nil)
	zone:Destroy()
end

print("the default is players only, so registering a type changes nothing")
do
	rbx.reset()
	local b = bot(0, 0, 0)
	Zone.track("bot", b)
	rbx.addPlayer("Ana", V(0, 0, 0))
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block) -- no types param
	sweep()
	local types = zone:GetTypes()
	check("it watches exactly one type", #types == 1, #types)
	check("and that type is player", types[1] == "player", types[1])
	check("the bot sitting in the volume is ignored", not zone:IsSubjectInZone(b))
	check("the player is not", zone.playerCountInZone == 1, zone.playerCountInZone)
	zone:Destroy()
	Zone.untrack("bot", b)
end

print("AllTypes and excludeTypes")
do
	rbx.reset()
	local b = bot(0, 0, 0)
	Zone.track("bot", b)
	rbx.addPlayer("Ana", V(0, 0, 0))

	local all = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = Zone.AllTypes })
	sweep()
	check("AllTypes picks up both populations", all:CountInZone() == 2, all:CountInZone())
	all:Destroy()

	local noPlayers =
		Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = Zone.AllTypes, excludeTypes = { "player" } })
	sweep()
	check("excluding player leaves the bot", noPlayers:CountInZone() == 1, noPlayers:CountInZone())
	check("and no players at all", noPlayers.playerCountInZone == 0, noPlayers.playerCountInZone)
	local types = noPlayers:GetTypes()
	check("player is absent from the resolved set", table.find(types, "player") == nil, table.concat(types, ","))
	noPlayers:Destroy()

	-- Exclusion has to apply to the explicit list too, not only to AllTypes.
	local excluded = Zone.new(
		CF(0, 0, 0),
		V(10, 10, 10),
		PartType.Block,
		nil,
		{ types = { "player", "bot" }, excludeTypes = { "bot" } }
	)
	sweep()
	check("exclusion applies to an explicit list as well", excluded:CountInZone() == 1, excluded:CountInZone())
	check("and it kept the player", excluded.playerCountInZone == 1, excluded.playerCountInZone)
	excluded:Destroy()
	Zone.untrack("bot", b)
end

print("an excluded type is not merely filtered -- it is never gathered")
do
	rbx.reset()
	-- The resolver counts its own calls, so "did the work happen" is observable
	-- rather than inferred.
	local resolved = 0
	Zone.registerType("counted", function(ref)
		resolved += 1
		return ref.at
	end)
	local a, b = bot(0, 0, 0), bot(50, 0, 0)
	Zone.track("counted", a)
	Zone.track("counted", b)

	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block) -- players only
	sweep()
	check("a players-only zone never resolved the other population", resolved == 0, resolved)

	zone:SetTypes({ "counted" })
	sweep()
	-- Two for the snapshot, plus one liveness re-check for the single member that
	-- ended up inside.
	check("asking for it resolves both members", resolved == 3, resolved)

	zone:SetTypes(nil) -- back to players only
	resolved = 0
	sweep()
	check("dropping it stops the work again", resolved == 0, resolved)
	zone:Destroy()
	Zone.untrack("counted", a)
	Zone.untrack("counted", b)
end

print("SetTypes exits subjects of a type no longer watched")
do
	rbx.reset()
	local b = bot(0, 0, 0)
	Zone.track("bot", b)
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "bot" } })
	local exited = 0
	zone.subjectExited:Connect(function()
		exited += 1
	end)
	sweep()
	check("the bot is in to begin with", zone:IsSubjectInZone(b))
	zone:SetTypes({ "player" })
	sweep()
	check("it is exited rather than left stuck inside", not zone:IsSubjectInZone(b))
	check("and the exit actually fired", exited == 1, exited)
	check("the count is consistent", zone:CountInZone() == 0, zone:CountInZone())
	zone:Destroy()
	Zone.untrack("bot", b)
end

print("one snapshot per frame, shared across due zones")
do
	rbx.reset()
	local resolved = 0
	Zone.registerType("shared", function(ref)
		resolved += 1
		return ref.at
	end)
	local s = bot(0, 0, 0)
	Zone.track("shared", s)

	local zones = {}
	for index = 1, 5 do
		zones[index] = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "shared" } })
	end
	resolved = 0
	sweep()
	-- Five zones, one gather: 1 resolve for the snapshot, plus one per zone for the
	-- liveness check on its own single member.
	check("five due zones gathered the population once", resolved == 6, resolved)
	for _, zone in zones do
		check("and each of them saw the subject", zone:IsSubjectInZone(s))
	end
	for _, zone in zones do
		zone:Destroy()
	end
	Zone.untrack("shared", s)
end

print("a throwing resolver costs its own population, not the tick")
do
	rbx.reset()
	Zone.registerType("broken", function()
		error("resolver is broken")
	end)
	Zone.track("broken", bot(0, 0, 0))
	local b = bot(0, 0, 0)
	Zone.track("bot", b)

	local bad = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "broken" } })
	local good = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "bot" } })
	local threw = not pcall(sweep)
	check("the ticker survived a throwing resolver", not threw)
	check("the broken population detected nobody", bad:CountInZone() == 0, bad:CountInZone())
	check("the healthy population was unaffected", good:CountInZone() == 1, good:CountInZone())
	bad:Destroy()
	good:Destroy()
	Zone.untrack("bot", b)
end

print("registerType replaces the resolver and keeps the set")
do
	rbx.reset()
	Zone.registerType("swap", function(ref)
		return ref.at
	end)
	local s = bot(0, 0, 0)
	Zone.track("swap", s)
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "swap" } })
	sweep()
	check("in under the first resolver", zone:IsSubjectInZone(s))
	-- Override: same subject, a resolver that reports it somewhere else entirely.
	Zone.registerType("swap", function()
		return V(500, 0, 0)
	end)
	sweep()
	check("the replacement resolver took effect", not zone:IsSubjectInZone(s))
	check("without losing the tracked set", Zone.isTracked("swap", s))
	zone:Destroy()
	Zone.untrack("swap", s)
end

print("Zone.track / isTracked / trackedCount")
do
	local a, b = bot(0, 0, 0), bot(1, 1, 1)
	check("untracked to begin with", not Zone.isTracked("bot", a))
	Zone.track("bot", a)
	Zone.track("bot", b)
	check("tracked after track", Zone.isTracked("bot", a) and Zone.isTracked("bot", b))
	check("trackedCount reports 2", Zone.trackedCount("bot") == 2, Zone.trackedCount("bot"))
	Zone.untrack("bot", a)
	check("and 1 after untrack", Zone.trackedCount("bot") == 1, Zone.trackedCount("bot"))
	Zone.untrack("bot", b)
	check("untracking twice is harmless", pcall(Zone.untrack, "bot", b))
	check("untracking an unknown type is harmless", pcall(Zone.untrack, "nosuchtype", b))
	check("tracking an unknown type errors loudly", not pcall(Zone.track, "nosuchtype", b))
	check("trackedCount of an unknown type is 0", Zone.trackedCount("nosuchtype") == 0)
	check("hasType is honest", Zone.hasType("bot") and not Zone.hasType("nosuchtype"))
end

print("tags are read once, then maintained by signal")
do
	rbx.reset()
	local folder = rbx.Instance.new("Folder")
	folder.Parent = rbx.workspace
	local car = rbx.Instance.new("Part")
	car.Parent = folder
	car.Position = V(0, 0, 0)
	rbx.addTag(car, "Vehicle")

	local before = rbx.tagGetCalls()
	Zone.trackTagged("vehicle", "Vehicle")
	check("GetTagged was called once to seed the set", rbx.tagGetCalls() - before == 1, rbx.tagGetCalls() - before)
	check("and the existing tagged instance was picked up", Zone.isTracked("vehicle", car))

	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "vehicle" } })
	local seeded = rbx.tagGetCalls()
	sweep()
	sweep()
	sweep()
	check("three sweeps called GetTagged zero more times", rbx.tagGetCalls() == seeded, rbx.tagGetCalls() - seeded)
	check("the tagged part is inside", zone:IsSubjectInZone(car))

	-- A spawn arriving after registration has to be picked up by the added signal.
	local truck = rbx.Instance.new("Part")
	truck.Parent = folder
	truck.Position = V(1, 0, 0)
	rbx.addTag(truck, "Vehicle")
	sweep()
	check("a newly tagged instance is detected", zone:IsSubjectInZone(truck))
	check("still no extra GetTagged calls", rbx.tagGetCalls() == seeded, rbx.tagGetCalls() - seeded)

	rbx.removeTag(truck, "Vehicle")
	sweep()
	check("untagging exits it", not zone:IsSubjectInZone(truck))

	-- The other liveness route: destroyed without anyone untagging it.
	car.Parent = nil
	sweep()
	check("a parentless instance is treated as gone", not zone:IsSubjectInZone(car))
	zone:Destroy()
end

print("trackChildren follows a folder")
do
	rbx.reset()
	local folder = rbx.Instance.new("Folder")
	folder.Parent = rbx.workspace
	local first = rbx.Instance.new("Part")
	first.Position = V(0, 0, 0)
	folder:Add(first)

	Zone.trackChildren("crate", folder)
	check("existing children are seeded", Zone.isTracked("crate", first))

	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "crate" } })
	sweep()
	check("the seeded child is inside", zone:IsSubjectInZone(first))

	local second = rbx.Instance.new("Part")
	second.Position = V(2, 0, 0)
	folder:Add(second)
	sweep()
	check("ChildAdded picks up a new child", zone:IsSubjectInZone(second))

	folder:Remove(second)
	sweep()
	check("ChildRemoved exits it", not zone:IsSubjectInZone(second))
	check("and it is no longer tracked", not Zone.isTracked("crate", second))
	zone:Destroy()
end

print("positionFromModel, and tagsToTrack finally means something")
do
	rbx.reset()
	local model = rbx.Instance.new("Model")
	model.Parent = rbx.workspace
	model:PivotTo(V(0, 0, 0))

	-- tagsToTrack was accepted and ignored for the whole life of this module.
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { tagsToTrack = { "Turret" } })
	rbx.addTag(model, "Turret")
	sweep()
	check("a tagged Model is detected via its pivot", zone:IsSubjectInZone(model))
	local types = zone:GetTypes()
	table.sort(types)
	check("the tag was appended to the default", #types == 2 and types[1] == "Turret" and types[2] == "player", table.concat(types, ","))
	check("so players still work alongside it", zone.playerCountInZone == 0, zone.playerCountInZone)

	model:PivotTo(V(100, 0, 0))
	sweep()
	check("moving the model's pivot exits it", not zone:IsSubjectInZone(model))
	zone:Destroy()

	check("positionFromModel reads the pivot", Zone.positionFromModel(model) == V(100, 0, 0))
	model.Parent = nil
	check("and reports nil once parentless", Zone.positionFromModel(model) == nil)

	local part = rbx.Instance.new("Part")
	part.Parent = rbx.workspace
	part.Position = V(3, 4, 5)
	check("positionFromPart reads Position", Zone.positionFromPart(part) == V(3, 4, 5))
	check("positionFromInstance detects a part", Zone.positionFromInstance(part) == V(3, 4, 5))
	part.Parent = nil
	check("positionFromPart reports nil once parentless", Zone.positionFromPart(part) == nil)
end

print("an unregistered type name warns instead of silently detecting nothing")
do
	rbx.reset()
	local zone = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { types = { "typoed" } })
	rbx.addPlayer("Ana", V(0, 0, 0))
	local threw = not pcall(sweep)
	check("it does not throw", not threw)
	check("and detects nobody", zone:CountInZone() == 0, zone:CountInZone())
	check("GetTypes reports nothing resolvable", #zone:GetTypes() == 0, #zone:GetTypes())
	-- Registering it later has to take effect without rebuilding the zone: require
	-- order should not decide whether a zone works.
	Zone.registerType("typoed", function(ref)
		return ref.at
	end)
	local late = bot(0, 0, 0)
	Zone.track("typoed", late)
	sweep()
	check("registering the type later starts it working", zone:IsSubjectInZone(late))
	zone:Destroy()
	Zone.untrack("typoed", late)
end

print("wiring the same tag twice does not double the connections")
do
	rbx.reset()
	local drone = rbx.Instance.new("Part")
	drone.Parent = rbx.workspace
	drone.Position = V(0, 0, 0)
	rbx.addTag(drone, "Drone")

	-- Two zones naming the same tag is the ordinary case, not an abuse.
	local a = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { tagsToTrack = { "Drone" } })
	local listeners = rbx.tagListeners("Drone")
	local b = Zone.new(CF(0, 0, 0), V(10, 10, 10), PartType.Block, nil, { tagsToTrack = { "Drone" } })
	check("the second zone added no further listeners", rbx.tagListeners("Drone") == listeners, rbx.tagListeners("Drone"))

	sweep()
	check("and both zones still detect it", a:IsSubjectInZone(drone) and b:IsSubjectInZone(drone))
	a:Destroy()
	b:Destroy()
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
