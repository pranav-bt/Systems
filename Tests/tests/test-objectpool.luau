-- ObjectPool: reuse, the cap policies, and the two mistakes every pool caller makes.
local rbx = require("./shim/roblox")
local Pool = require("./shim/library")("ObjectPool")

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

local function template(name)
	local part = rbx.Instance.new("Part")
	part.Name = name or "Bullet"
	return part
end

print("the basic cycle")
do
	local source = template()
	local pool = Pool.new(source)

	local free, active, created = pool:stats()
	check("a new pool holds nothing", free == 0 and active == 0 and created == 0, `{free}/{active}/{created}`)

	local first = pool:get()
	check("get produces an instance", first ~= nil)
	check("cloned from the template", first.Name == "Bullet", first.Name)
	-- The template is never handed out, so it can live in ServerStorage untouched.
	check("and is NOT the template itself", first ~= source)

	free, active, created = pool:stats()
	check("one is out", free == 0 and active == 1 and created == 1, `{free}/{active}/{created}`)

	check("release reports it was holding it", pool:release(first) == true)
	free, active = pool:stats()
	check("which returns it to the free list", free == 1 and active == 0, `{free}/{active}`)

	local second = pool:get()
	check("the next get REUSES it", second == first, "it cloned a new one")
	local _, _, madeSoFar = pool:stats()
	check("without cloning again", madeSoFar == 1, madeSoFar)
end

print("the two mistakes every caller makes")
do
	local pool = Pool.new(template())
	local mine = pool:get()

	-- Both predecessors did table.insert(free[active[obj]], obj) and died on a nil index.
	local stranger = rbx.Instance.new("Part")
	check("releasing a foreign object does not crash", pcall(function()
		return pool:release(stranger)
	end), "it threw")
	check("and reports it was not holding it", pool:release(stranger) == false)

	pool:release(mine)
	check("a double release does not crash", pcall(function()
		return pool:release(mine)
	end), "it threw")
	check("and reports false the second time", pool:release(mine) == false)

	-- The double release must not have put it in the free list twice, or two callers would
	-- be handed the same object.
	local free = pool:stats()
	check("nor does it duplicate the free entry", free == 1, free)

	check("releasing nil is a no-op", pool:release(nil) == false)
end

print("clones go where they are told")
do
	local folder = rbx.Instance.new("Folder")
	folder.Name = "Shots"
	folder.Parent = rbx.workspace

	local pool = Pool.new(template(), { parent = folder })
	local shot = pool:get()
	check("a clone is parented to the given parent", shot.Parent == folder, shot.Parent)

	-- With no parent given, the caller owns parenting -- the pool must not guess, and must
	-- not invent a folder in workspace the way one predecessor did AT REQUIRE TIME.
	local unparented = Pool.new(template())
	check("with no parent, a clone is left unparented", unparented:get().Parent == nil)
end

print("release strategies")
do
	-- unparent: the default.
	local a = Pool.new(template())
	local one = a:get()
	one.Parent = rbx.workspace
	a:release(one)
	check("unparent takes it out of the tree", one.Parent == nil, one.Parent)

	--[[
		park: stays parented, moves far below the map. The reason it exists is particles --
		unparenting a ParticleEmitter drops its streaming and resets its warm-up, so the next
		use hitches.
	]]
	local folder = rbx.Instance.new("Folder")
	folder.Parent = rbx.workspace
	local b = Pool.new(template(), { parent = folder, release = Pool.park })
	local two = b:get()
	b:release(two)
	check("park keeps it parented", two.Parent == folder, two.Parent)
	check("and moves it out of sight", two:GetPivot().Position.Y <= -1000, two:GetPivot().Position.Y)

	-- A custom strategy: the whole point of release being a function.
	local reset = 0
	local c = Pool.new(template(), {
		release = function(instance)
			reset += 1
			instance.Transparency = 1
		end,
	})
	local three = c:get()
	c:release(three)
	check("a custom release runs", reset == 1, reset)
	check("and can touch the instance", three.Transparency == 1, three.Transparency)
end

print("onCreate runs once per CLONE, not per get")
do
	local created = {}
	local pool = Pool.new(template(), {
		onCreate = function(instance)
			table.insert(created, instance)
		end,
	})

	local one = pool:get()
	check("it ran for the first clone", #created == 1, #created)
	pool:release(one)
	local again = pool:get()
	check("the same object came back", again == one)
	--[[
		The seam that replaces the predecessor's GetDescendants() walk on every clone. Running
		it per GET would put that cost on the hot path; running it per clone puts it where the
		cloning cost already is.
	]]
	check("but onCreate did NOT run again", #created == 1, #created)

	local other = pool:get() -- forces a second clone
	check("a genuinely new clone does run it", #created == 2, #created)
	check("with the new instance", created[2] == other)
end

print("warm pre-builds, through the release strategy")
do
	local folder = rbx.Instance.new("Folder")
	folder.Parent = rbx.workspace
	local pool = Pool.new(template(), { parent = folder, warm = 5, release = Pool.park })

	local free, active, created = pool:stats()
	check("warming fills the free list", free == 5, free)
	check("with nothing active", active == 0, active)
	check("and the clones exist", created == 5, created)

	--[[
		Warmed objects go through `release` on the way in, so they are in the same state a
		released one is. Otherwise the first get from a parked pool hands back something
		sitting at the origin, in view.
	]]
	local warmed = pool:get()
	check("a warmed object was parked, not left at the origin", warmed:GetPivot().Position.Y <= -1000, warmed:GetPivot().Position.Y)

	local _, _, after = pool:stats()
	check("and getting it clones nothing new", after == 5, after)

	-- Warming past the cap must not overshoot it.
	local capped = Pool.new(template(), { max = 3, warm = 10 })
	local cappedFree, _, cappedCreated = capped:stats()
	check("warm respects the cap", cappedCreated == 3, cappedCreated)
	check("and fills only that far", cappedFree == 3, cappedFree)
end

print("the cap: grow is the default")
do
	local pool = Pool.new(template(), { max = 2 })
	local held = { pool:get(), pool:get() }
	local _, _, created = pool:stats()
	check("two out at the cap", created == 2, created)

	--[[
		A cap is a MEMORY GUARD, and blowing through it is much less bad than the two
		alternatives: nothing visibly breaks and the warning names the pool to raise.
	]]
	local third = pool:get()
	check("a third is still handed out", third ~= nil)
	check("it is a distinct object", third ~= held[1] and third ~= held[2])
	local _, active, grown = pool:stats()
	check("the pool grew past the cap", grown == 3, grown)
	check("with all three active", active == 3, active)
end

print("the cap: nil is honest but demanding")
do
	local pool = Pool.new(template(), { max = 2, onExhausted = "nil" })
	local one, two = pool:get(), pool:get()
	check("the first two arrive", one ~= nil and two ~= nil)
	check("and the third is nil", pool:get() == nil, "it handed something out")

	-- Releasing one makes the pool usable again immediately.
	pool:release(one)
	check("releasing frees capacity", pool:get() ~= nil)
end

print("the cap: steal recycles the OLDEST")
do
	local pool = Pool.new(template(), { max = 2, onExhausted = "steal" })
	local first = pool:get()
	local second = pool:get()

	--[[
		For VFX this is usually what you want: a distant effect vanishing beats a new one
		failing to play. It is wrong for anything a caller still holds, which is why it is not
		the default.
	]]
	local third = pool:get()
	check("the oldest is handed back out", third == first, "it took the wrong one")
	check("not the newer one", third ~= second)

	local _, _, created = pool:stats()
	check("and nothing new was cloned", created == 2, created)

	-- Stealing again takes the next oldest, which is now `second`.
	local fourth = pool:get()
	check("stealing again takes the next oldest", fourth == second, "wrong object")
end

print("steal has a hazard, and it is why it is not the default")
do
	--[[
		A STOLEN OBJECT IS LIVE AGAIN UNDER A NEW OWNER. The original holder still has a
		reference to it and no way to know it was taken, so their eventual `release` hands
		back an object that now belongs to somebody else -- and the new owner keeps using
		something that is sitting in the free list, ready to be handed out a third time.

		Nothing here can prevent that: the pool cannot tell a stale release from a real one
		without a per-claim token, which would change `get` from returning an Instance into
		returning a handle. That trade is not worth it for the case steal exists for -- short
		lived VFX nobody holds -- so the hazard is DOCUMENTED and the option is opt-in.
	]]
	local resets = 0
	local pool = Pool.new(template(), {
		max = 1,
		onExhausted = "steal",
		release = function(instance)
			resets += 1
			instance.Transparency = 1
		end,
	})
	local mine = pool:get()
	mine.Transparency = 0 -- the previous owner's state
	local stolen = pool:get()
	check("the same object was handed to a second caller", stolen == mine)

	--[[
		A STOLEN OBJECT IS RESET ON THE WAY THROUGH. Every other reused object reaches its new
		owner having been through `release`, and a stolen one has to match -- otherwise the new
		owner is handed something still mid-effect from the last one: particles running, the
		wrong transparency, the wrong pose.
	]]
	check("stealing runs the release strategy", resets == 1, resets)
	check("so the new owner gets a reset object", stolen.Transparency == 1, stolen.Transparency)

	-- The original holder releases what it thinks is still its own.
	check("the stale release is accepted, because the object IS active", pool:release(mine) == true)
	local free, active = pool:stats()
	check("so it lands in the free list while still in use", free == 1 and active == 0, `{free}/{active}`)
end

print("releaseAll and destroy")
do
	local pool = Pool.new(template(), { warm = 2 })
	local a, b = pool:get(), pool:get()
	local _, active = pool:stats()
	check("two are out", active == 2, active)

	pool:releaseAll()
	local free, stillActive = pool:stats()
	check("releaseAll returns everything", stillActive == 0, stillActive)
	check("to the free list", free == 2, free)

	pool:get()
	pool:destroy()
	local dFree, dActive, dCreated = pool:stats()
	check("destroy empties the pool", dFree == 0 and dActive == 0, `{dFree}/{dActive}`)
	check("and resets the clone count", dCreated == 0, dCreated)
	-- Everything it made is destroyed, in use or not.
	check("clones are destroyed", a._destroyed == true and b._destroyed == true, `{tostring(a._destroyed)}/{tostring(b._destroyed)}`)

	-- Usable again afterwards rather than poisoned.
	check("the pool still works after destroy", pool:get() ~= nil)
end

print("two pools over the same template do not share")
do
	--[[
		The failure the singleton predecessors had: keyed by a string tag in module state, so
		two systems both using "bullet" handed each other's objects back and forth.
	]]
	local source = template()
	local a = Pool.new(source)
	local b = Pool.new(source)

	local fromA = a:get()
	a:release(fromA)
	local fromB = b:get()
	check("B does not receive A's released object", fromB ~= fromA, "the pools shared state")

	local aFree = a:stats()
	check("and A still holds its own", aFree == 1, aFree)
end

print("bad construction is refused")
do
	check("a template is required", not pcall(Pool.new, nil :: any))
	check("a non-Instance template is refused", not pcall(Pool.new, "bullet" :: any))
	check("a zero max is refused", not pcall(Pool.new, template(), { max = 0 }))
	check("a negative max is refused", not pcall(Pool.new, template(), { max = -1 }))
	check("no options at all is fine", pcall(Pool.new, template()))
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("object pool tests failed", 0)
end
