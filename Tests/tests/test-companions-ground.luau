-- Ground mode at RUNTIME: the floor being found, the target being stepped, the throttle, and
-- what happens over a gap. Only the mode's CONSTRUCTION was covered before -- that a
-- one-attachment AlignPosition gets built -- which says nothing about whether it ever moves.
--
-- The floor finder is injected, so no physics world is needed and "where the ground is" is a
-- value this file controls frame by frame.
local rbx = require("./shim/roblox")
local Companions = require("./shim/library")("Companions")
local task = require("@lune/task")

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

local function model(name)
	local m = rbx.Instance.new("Model")
	m.Name = name
	local part = rbx.Instance.new("Part")
	part.Name = "Body"
	m:Add(part)
	m.PrimaryPart = part
	return m
end

local pets = rbx.Instance.new("Folder")
pets.Name = "Pets"
pets:Add(model("Walker"))
pets:Add(model("Floater"))
rbx.ReplicatedStorage:Add(pets)

Companions.start({})
Companions.definePet("Walker", { settings = { followMode = "Ground", groundOffset = 2, groundInterval = 0.1 } })
Companions.definePet("Floater", { settings = {} }) -- Float, the default

--[[
	The fake world. `floorY = nil` means "nothing down there".

	It HONOURS THE DIRECTION rather than ignoring it: a ray that does not point down finds
	nothing, the same as the engine would over flat ground. A fake that answers whatever it
	is asked cannot tell a floor-finder from a ceiling-finder.
]]
local floorY: number? = 0
local rays = 0
local lastFrom: any = nil
local lastDirection: any = nil
Companions.setRaycast(function(from, direction)
	rays += 1
	lastFrom, lastDirection = from, direction
	if direction.Y >= 0 then
		return nil
	end
	return floorY
end)

--[[
	Advances real time and then pumps a frame.

	The throttle is measured against os.clock, not against a frame count, so stepping the
	heartbeat in a tight loop would only ever produce ONE ground check however many times it
	ran. Waiting is what makes the next one due.
]]
local function tick(seconds)
	if seconds then
		task.wait(seconds)
	end
	rbx.step(1 / 60)
end

print("a ground pet aims at the floor below its slot")
do
	local player = rbx.addPlayer("Ana")
	task.wait()
	Companions.grant(player, "Walker")
	Companions.equip(player, "Slot1", "Walker")
	task.wait()

	local rig = Companions.getPet(player, "Slot1")
	check("the pet spawned", rig ~= nil)
	check("in one-attachment mode", rig.alignPosition.Mode == "OneAttachment", rig.alignPosition.Mode)

	rays = 0
	floorY = 10
	tick()
	check("the floor was looked for", rays >= 1, rays)
	-- groundOffset is 2, so the anchor sits at floor + 2.
	check("the target sits above the floor it found", rig.alignPosition.Position.Y == 12, rig.alignPosition.Position.Y)

	check(
		"it looked straight down",
		lastDirection.Y < 0 and lastDirection.X == 0 and lastDirection.Z == 0,
		lastDirection
	)
	check("as far as groundDistance", math.abs(lastDirection.Y) == 64, lastDirection.Y)
	check("from the slot, not from the pet", lastFrom.X == rig.slotAttachment.WorldPosition.X, lastFrom)

	--[[
		X and Z come from the SLOT, not from wherever the target happens to sit: the pet walks
		below where it would hang.

		The player is walked first, so the slot no longer agrees with the last target. Asserting
		against a slot the target was just built from proves nothing -- a version that never
		re-read the slot passed that check.
	]]
	local root = player.Character:FindFirstChild("HumanoidRootPart")
	root.CFrame = rbx.CFrame.new(rbx.Vector3.new(40, 5, -25))
	local slotPosition = rig.slotAttachment.WorldPosition
	check("the walk moved the slot", slotPosition.X ~= rig.alignPosition.Position.X)
	tick(0.15)
	check(
		"the target followed the slot's X",
		rig.alignPosition.Position.X == slotPosition.X,
		rig.alignPosition.Position.X
	)
	check("and its Z", rig.alignPosition.Position.Z == slotPosition.Z, rig.alignPosition.Position.Z)
	check(
		"while the height still comes from the floor",
		rig.alignPosition.Position.Y == 12,
		rig.alignPosition.Position.Y
	)

	rbx.removePlayer(player)
	task.wait()
end

print("the look is throttled, not per frame")
do
	local player = rbx.addPlayer("Ana")
	task.wait()
	Companions.grant(player, "Walker")
	Companions.equip(player, "Slot1", "Walker")
	task.wait()
	local rig = Companions.getPet(player, "Slot1")

	floorY = 0
	tick(0.15)
	rays = 0

	-- Ten frames inside one interval: the floor under a running player changes slowly next
	-- to 60Hz, and a ray per pet per frame buys nothing.
	for _ = 1, 10 do
		rbx.step(1 / 60)
	end
	check("ten frames inside the interval look once at most", rays <= 1, rays)

	-- The target does not chase a floor that moved during the throttle...
	local before = rig.alignPosition.Position.Y
	floorY = 50
	for _ = 1, 10 do
		rbx.step(1 / 60)
	end
	check(
		"so the target does not move mid-interval",
		rig.alignPosition.Position.Y == before,
		rig.alignPosition.Position.Y
	)

	-- ...and catches up on the next one.
	tick(0.15)
	check("and catches up once the interval passes", rig.alignPosition.Position.Y == 52, rig.alignPosition.Position.Y)

	rbx.removePlayer(player)
	task.wait()
end

print("a gap in the floor holds the last known height")
do
	local player = rbx.addPlayer("Ana")
	task.wait()
	Companions.grant(player, "Walker")
	Companions.equip(player, "Slot1", "Walker")
	task.wait()
	local rig = Companions.getPet(player, "Slot1")

	floorY = 8
	tick(0.15)
	check("it found the floor", rig.alignPosition.Position.Y == 10, rig.alignPosition.Position.Y)

	--[[
		Out over a chasm. Diving after a floor that is not there would drop the pet through
		the world; keeping the last known height means it crosses the gap and finds the far
		side on the next look.
	]]
	floorY = nil
	tick(0.15)
	check("nothing found keeps the last height", rig.alignPosition.Position.Y == 10, rig.alignPosition.Position.Y)
	tick(0.15)
	check("and keeps it for as long as the gap lasts", rig.alignPosition.Position.Y == 10, rig.alignPosition.Position.Y)

	floorY = 3
	tick(0.15)
	check("the far side is picked up", rig.alignPosition.Position.Y == 5, rig.alignPosition.Position.Y)

	rbx.removePlayer(player)
	task.wait()
end

print("only ground pets are driven")
do
	local player = rbx.addPlayer("Ana")
	task.wait()
	Companions.grant(player, "Floater")
	Companions.equip(player, "Slot1", "Floater")
	task.wait()
	local rig = Companions.getPet(player, "Slot1")

	floorY = 99
	rays = 0
	tick(0.15)
	tick(0.15)
	-- A floating pet chases its slot attachment directly, so there is no floor to find and
	-- nothing per-frame to run for it at all.
	check("a float pet never looks for the floor", rays == 0, rays)
	check("and stays in two-attachment mode", rig.alignPosition.Mode == nil, rig.alignPosition.Mode)
	check("aimed at the slot itself", rig.alignPosition.Attachment1 == rig.slotAttachment)

	rbx.removePlayer(player)
	task.wait()
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
