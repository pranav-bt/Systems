-- The rig's animation and physics behaviour: the idle loop's three-valued gate, the
-- one-shot action that overrides it and hands back, and the physics spec.
--
-- SCOPE, stated honestly. These drive Rig directly against hand-built rig tables and a
-- fake Animator, because that is where the DECISIONS are -- which track was weighted out,
-- what came back, whether a second action layers or replaces. Building a real pet needs a
-- character, a slot schema, constraints and welds, none of which contain a decision; the
-- ground loop's Instance wiring is not covered here for the same reason.
local rbx = require("./shim/roblox")
local Rig = require("./shim/library")("Companions", "Rig")
local Config = require("./shim/library")("Companions", "Config")

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

-- A rig is a plain table; only the fields these functions touch need to be real.
local function fakeRig(overrides)
	local model = rbx.Instance.new("Model")
	model.Name = "Knight"
	local part = rbx.Instance.new("Part")
	part.Name = "Body"
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Anchored = false
	model:Add(part)

	local rig = {
		uid = "u1",
		petId = "Knight",
		model = model,
		root = part,
		settings = Config.resolve("Knight", 1),
		animations = {},
		track = nil,
		actionTrack = nil,
		actionConnection = nil,
	}
	for key, value in overrides or {} do
		rig[key] = value
	end
	return rig
end

print("an action overrides the idle loop and hands it back")
do
	local rig = fakeRig()
	-- Stand in an idle loop that is already running, as a spawned pet would have.
	local animator = rbx.Instance.new("Animator")
	local loop = animator:LoadAnimation(rbx.Instance.new("Animation"))
	loop.Looped = true
	loop:Play()
	rig.track = loop

	check("playing an action succeeds", Rig.playAction(rig, "rbxassetid://123"))
	check("it reports as playing", Rig.isPlayingAction(rig))
	check("the action is not looped", rig.actionTrack.Looped == false)
	check("and carries the Action priority", rig.actionTrack.Priority == "Action")

	-- Weighted out, NOT stopped: stopping would restart the loop from frame zero on the
	-- way back, so a pet that acts twice would visibly reset its idle in between.
	check("the loop was weighted out, not stopped", loop.Weight == 0 and loop.IsPlaying, loop.Weight)

	-- Finishing hands back.
	rig.actionTrack:Stop()
	check("the action is cleared when it ends", rig.actionTrack == nil)
	check("and the loop is weighted back in", loop.Weight == 1, loop.Weight)
	check("nothing is playing any more", not Rig.isPlayingAction(rig))
end

print("a second action replaces the first rather than layering")
do
	local rig = fakeRig()
	local animator = rbx.Instance.new("Animator")
	local loop = animator:LoadAnimation(rbx.Instance.new("Animation"))
	loop.Looped = true
	loop:Play()
	rig.track = loop

	Rig.playAction(rig, "rbxassetid://first")
	local first = rig.actionTrack
	Rig.playAction(rig, "rbxassetid://second")
	local second = rig.actionTrack

	check("the second is a different track", first ~= second)
	check("the first was stopped", first.IsPlaying == false)
	check("the second is playing", second.IsPlaying)
	-- The stale connection must not weight the loop back up underneath the new action.
	check("and the loop stayed out of the way", loop.Weight == 0, loop.Weight)

	second:Stop()
	check("only the surviving action hands back", loop.Weight == 1, loop.Weight)
end

print("stopAction cuts it short through the same path")
do
	local rig = fakeRig()
	local animator = rbx.Instance.new("Animator")
	local loop = animator:LoadAnimation(rbx.Instance.new("Animation"))
	loop:Play()
	rig.track = loop

	Rig.playAction(rig, "rbxassetid://swing")
	Rig.stopAction(rig)
	check("the action is gone", rig.actionTrack == nil)
	check("the loop came back", loop.Weight == 1, loop.Weight)
	-- Safe when nothing is playing.
	check("stopping nothing is harmless", pcall(Rig.stopAction, rig))
end

print("an action works on a pet with no idle loop at all")
do
	local rig = fakeRig()
	check("it still plays", Rig.playAction(rig, "rbxassetid://solo"))
	local action = rig.actionTrack
	check("and reports playing", Rig.isPlayingAction(rig))
	action:Stop()
	check("and clears with nothing to hand back to", rig.actionTrack == nil)
end

print("animations are cached per rig, not rebuilt per action")
do
	local rig = fakeRig()
	Rig.playAction(rig, "rbxassetid://swing")
	local first = rig.animations["rbxassetid://swing"]
	Rig.stopAction(rig)
	Rig.playAction(rig, "rbxassetid://swing")
	check("the same Animation instance is reused", rig.animations["rbxassetid://swing"] == first)
	Rig.playAction(rig, "rbxassetid://cast")
	check("a different id gets its own", rig.animations["rbxassetid://cast"] ~= first)

	check("an empty id is refused", not Rig.playAction(rig, ""))
	check("a non-string id is refused", not Rig.playAction(rig, 42))
end

print("setPhysics applies only what it is given")
do
	local rig = fakeRig()
	local part = rig.root
	-- Started TRUE so "left alone" is distinguishable from "set to false". With both at
	-- false, a setPhysics that clobbered every field would look identical to one that did
	-- not touch them.
	part.CanQuery = true
	part.CanTouch = true
	Rig.setPhysics(rig, { canCollide = true })
	check("collision was turned on", part.CanCollide == true)
	check("a field not mentioned is untouched", part.CanQuery == true and part.CanTouch == true)
	check("including one that was already false", part.Anchored == false)

	Rig.setPhysics(rig, { canQuery = false, anchored = true })
	check("query can be turned off explicitly", part.CanQuery == false)
	check("anchored was set", part.Anchored == true)
	check("collision kept its earlier value", part.CanCollide == true)

	Rig.setPhysics(rig, { canCollide = false })
	check("and it can be turned back off", part.CanCollide == false)
end

print("the four follow modes each attach differently")
do
	local function petModel()
		local m = rbx.Instance.new("Model")
		m.Name = "Knight"
		local p = rbx.Instance.new("Part")
		p.Name = "Body"
		m:Add(p)
		m.PrimaryPart = p
		return m
	end

	local slotPart = rbx.Instance.new("Part")
	slotPart.Name = "HumanoidRootPart"
	local attachment = rbx.Instance.new("Attachment")
	attachment.Name = "PetSlot1"
	attachment.Parent = slotPart
	local slot = { key = "PetSlot1", attachment = attachment }
	local container = rbx.Instance.new("Folder")

	local function build(overrides, withSlot)
		Config.pets.Knight = { settings = overrides }
		local settings = Config.resolve("Knight", 1)
		local entry = { id = "Knight", category = nil, model = petModel() }
		local origin = rbx.CFrame.new(rbx.Vector3.new(10, 0, 10))
		return Rig.build(
			entry,
			settings,
			if withSlot == false then nil else slot,
			container,
			nil,
			"u" .. tostring(math.random(1, 1e6)),
			rbx.Random.new(1),
			1,
			origin
		)
	end

	-- Float: the default. Two-attachment, so the pet chases the slot itself.
	local float = build({})
	check("float builds an AlignPosition", float.alignPosition ~= nil)
	check("aimed at the slot attachment", float.alignPosition.Attachment1 == attachment)
	check("in two-attachment mode", float.alignPosition.Mode == nil, float.alignPosition.Mode)
	check("with an AlignOrientation too", float.alignOrientation ~= nil)
	check("and it remembers the slot", float.slotKey == "PetSlot1")

	--[[
		Ground: ONE attachment, because the target is the floor below the slot and no
		attachment on the character describes that point. Orientation still follows the
		slot -- the floor has nothing to say about which way a pet faces.
	]]
	local ground = build({ followMode = "Ground" })
	check("ground uses one-attachment mode", ground.alignPosition.Mode == "OneAttachment", ground.alignPosition.Mode)
	check("with no second attachment to chase", ground.alignPosition.Attachment1 == nil)
	check("seeded at the slot's world position", ground.alignPosition.Position ~= nil)
	check("but orientation still follows the slot", ground.alignOrientation.Attachment1 == attachment)

	-- Weld: rigid, so no constraints at all.
	local weld = build({ followMode = "Weld" })
	check("weld builds no AlignPosition", weld.alignPosition == nil)
	check("nor an AlignOrientation", weld.alignOrientation == nil)
	check("but it still holds a slot", weld.slotKey == "PetSlot1")

	-- Detached: no constraints AND no slot. The host owns where it is.
	local detached = build({ followMode = "Detached" }, false)
	check("detached builds no constraints", detached.alignPosition == nil and detached.alignOrientation == nil)
	check("and claims no attachment", detached.slotKey == nil, detached.slotKey)
	check("nor holds one to look down from", detached.slotAttachment == nil)
	-- On the MODEL's pivot, which is what the library sets. The shim does not re-seat
	-- children from a pivot move, so asserting on the root part would be testing the shim.
	check(
		"it was placed at the origin it was given",
		detached.model:GetPivot().Position.X == 10,
		detached.model:GetPivot().Position.X
	)

	--[[
		DETACHED MEANS DETACHED even when a slot is handed over. Nothing in this package
		does that today -- spawnPet builds a detached pet with no slot at all -- so without
		this the mode check is carried entirely by the caller, and a future caller that
		passes a slot would silently get a pet welded to a shoulder it is supposed to be
		free of.
	]]
	local detachedWithSlot = build({ followMode = "Detached" }, true)
	check("a detached pet given a slot still builds no constraints", detachedWithSlot.alignPosition == nil)
	check("nor an orientation", detachedWithSlot.alignOrientation == nil)

	Config.pets.Knight = nil
end

print("providing an animation id is enough to get a loop")
do
	local function modelWith(animationInside)
		local m = rbx.Instance.new("Model")
		m.Name = "Mage"
		local p = rbx.Instance.new("Part")
		p.Name = "Body"
		m:Add(p)
		m.PrimaryPart = p
		if animationInside then
			local a = rbx.Instance.new("Animation")
			a.Name = "Idle"
			a.AnimationId = "rbxassetid://inside"
			m:Add(a)
		end
		return m
	end

	local slotPart = rbx.Instance.new("Part")
	local attachment = rbx.Instance.new("Attachment")
	attachment.Parent = slotPart
	local slot = { key = "S", attachment = attachment }
	local container = rbx.Instance.new("Folder")

	local function build(overrides, animationInside)
		Config.pets.Mage = { settings = overrides }
		local entry = { id = "Mage", category = nil, model = modelWith(animationInside) }
		return Rig.build(entry, Config.resolve("Mage", 1), slot, container, nil, "u", rbx.Random.new(1), 1)
	end

	-- The default: nothing authored, nothing to play, and no complaint about it.
	check("a pet with no animation spawns static", build({}).track == nil)

	-- The feature: an id alone, with no loopAnimation flag beside it.
	local byId = build({ animationId = "rbxassetid://loop" })
	check("an animationId alone starts a loop", byId.track ~= nil)
	check("and it loops", byId.track ~= nil and byId.track.Looped == true)

	-- An Animation authored inside the model works the same way.
	check("an Animation inside the model is found", build({}, true).track ~= nil)

	-- false means static even when there is something to play.
	check("loopAnimation false stays static", build({ animationId = "rbxassetid://loop", loopAnimation = false }).track == nil)

	-- true with nothing to play is a configuration mistake, and says so.
	check("loopAnimation true with nothing to play is still static", build({ loopAnimation = true }).track == nil)

	Config.pets.Mage = nil
end


print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
