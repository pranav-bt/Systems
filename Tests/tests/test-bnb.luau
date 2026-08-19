-- BuildAndBattle archetype under Lune: voxel monsters as pure data on a
-- number line (the source has no Humanoids either -- this is the suite's
-- body-agnosticism stress test). Verifies the token layer (create /
-- failure-score give-up / damage-aggro re-target), the melee chase, the
-- Speedie commit, the PyroCaster kite bands, and the base-slot claim.

local Harness = require("./harness")
local BnbPolicy = require("../src/build/BnbPolicy")

local Bots, check = Harness.Bots, Harness.check
Bots.Brain.configure({ GOAL_JITTER = 0 })
local clock = Harness.newClock()

local function makeWorld()
	local world = {
		players = {},
		base = nil,
		slotClaims = {},
		releases = 0,
	}
	world.objectives = {
		base = function()
			return world.base
		end,
		claimBaseSlot = function(botId)
			world.slotClaims[botId] = 78
			return 78
		end,
		releaseBaseSlot = function(botId)
			if world.slotClaims[botId] then
				world.slotClaims[botId] = nil
				world.releases += 1
			end
		end,
	}
	return world
end

local function makeBody(world, opts)
	opts = opts or {}
	local rec = Harness.recorder()
	local body
	body = {
		rec = rec,
		now = clock.now,
		rng = opts.rng or Harness.deterministicRng,
		_pos = opts.pos or 0,
		_state = "Locomotion",
		state = function()
			return body._state
		end,
		distanceTo = function(point)
			return math.abs(point - body._pos)
		end,
		manhattanTo = function(point)
			return math.abs(point - body._pos)
		end,
		mover = Harness.fakeMover(),
		attack = rec.record("attack"),
		players = function()
			return world.players
		end,
		hasLineOfSight = function()
			return world.los ~= false
		end,
		castVolley = rec.record("volley"),
		awayFrom = function(point, dist)
			return body._pos + (if body._pos >= point then dist else -dist)
		end,
		chargeExplosion = rec.record("charge"),
		explode = rec.record("explode"),
		attackRange = opts.attackRange or 4,
		aggroThreshold = opts.aggroThreshold or 1,
		aggroInterval = opts.aggroInterval or 7,
		alwaysPlayerToken = opts.alwaysPlayerToken,
		kiter = opts.kiter,
		detonate = opts.detonate,
	}
	return body
end

local function makeBot(policy, body)
	return Bots.Bot.new({ body = body, goals = policy.goals, sensors = policy.sensors(body) })
end

-- ------------------------------------------------- chase and melee (Normie)
do
	local world = makeWorld()
	local policy = BnbPolicy.build(Bots, { tokenRatios = { Player = 5 }, objectives = world.objectives })
	world.players = { { ref = "P1", position = 30, alive = true } }
	local body = makeBody(world)
	local bot = makeBot(policy, body)
	clock.tick()
	local token = bot:get("token")
	check("player token created for the closest player", token ~= nil and token.type == "Player")
	check("chasing the target coord", body.mover.lastGoal == 30)
	body._pos = 27 -- within reach (dist 3 < 4)
	clock.tick()
	check("in reach: attacks instead of stepping", body.rec.count("attack") >= 1)
	bot:destroy()
end

-- ------------------------------------------------- failure-score give-up
do
	local world = makeWorld()
	local policy = BnbPolicy.build(Bots, { tokenRatios = { Player = 5 }, objectives = world.objectives })
	world.players = { { ref = "P1", position = 30, alive = true } }
	local body = makeBody(world)
	body.mover.status = "Unreachable" -- walled off: every step fails
	local bot = makeBot(policy, body)
	clock.tick()
	local firstToken = bot:get("token")
	check("failure accruing from the first blocked step", firstToken.failureScore >= 1 and firstToken.failureScore < 10)
	for _ = 1, 14 do
		clock.tick()
	end
	local current = bot:get("token")
	check("failure score expires the token (give-up at 10)", current ~= firstToken)
	check("fresh token starts clean", current ~= nil and current.failureScore < 10)
	bot:destroy()
end

-- ------------------------------------------------- damage aggro re-target
do
	local world = makeWorld()
	local policy = BnbPolicy.build(Bots, { tokenRatios = { Player = 5 }, objectives = world.objectives })
	world.players = {
		{ ref = "P1", position = 30, alive = true },
		{ ref = "P2", position = 40, alive = true },
	}
	local body = makeBody(world, { aggroThreshold = 1, aggroInterval = 0 })
	local bot = makeBot(policy, body)
	clock.tick()
	check("hunting the closest (P1)", bot:get("token").target.ref == "P1")
	policy.onDamaged(bot, "P2", 5, 10) -- P2 shoots us from close range
	clock.tick(0.3)
	check("damage aggro re-targets to the attacker", bot:get("token").target.ref == "P2")
	bot:destroy()
end

-- ------------------------------------------------- Speedie commit
do
	local world = makeWorld()
	local policy = BnbPolicy.build(Bots, { tokenRatios = { Player = 5 }, objectives = world.objectives })
	world.players = { { ref = "P1", position = 1.5, alive = true } }
	local body = makeBody(world, { detonate = { range = 2, chargeTime = 0.5 } })
	local bot = makeBot(policy, body)
	clock.tick()
	check("in range: charge begins", bot:currentGoal() == "Detonate" and body.rec.count("charge") == 1)
	world.players[1].position = 50 -- target flees mid-charge
	clock.tick(0.2)
	check("commit: still detonating (interruptible=false)", bot:currentGoal() == "Detonate")
	clock.tick(0.4) -- past the 0.5s fuse
	check("boom", body.rec.count("explode") == 1)
	bot:destroy()
end

-- ------------------------------------------------- PyroCaster kite bands
do
	local world = makeWorld()
	local policy = BnbPolicy.build(Bots, { tokenRatios = { Player = 5 }, objectives = world.objectives })
	world.players = { { ref = "P1", position = 10, alive = true } }
	local body = makeBody(world, {
		kiter = { idealMin = 20, idealMax = 25, hysteresis = 2, shootCooldown = 2.5 },
	})
	local bot = makeBot(policy, body)
	clock.tick()
	check("too close: retreats", body.mover.lastGoal == -6)
	world.players[1].position = 21 -- inside min+hysteresis while retreating
	clock.tick(0.3)
	check("hysteresis keeps it retreating at 21", bot:get("kiteRetreating") == true and body.mover.lastGoal == -6)
	world.players[1].position = 23 -- the shooting band
	clock.tick(0.3)
	check("in band: stops and volleys", body.rec.count("volley") == 1 and body.mover.stopped > 0)
	clock.tick(0.3)
	check("volley honors its cooldown", body.rec.count("volley") == 1)
	world.los = false
	clock.tick(3) -- past cooldown, but no line of sight
	check("no volley without line of sight", body.rec.count("volley") == 1)
	world.los = true
	world.players[1].position = 40 -- beyond idealMax
	clock.tick(0.3)
	check("too far: approaches", body.mover.lastGoal == 40)
	bot:destroy()
end

-- ------------------------------------------------- structure token + slot claim
do
	local world = makeWorld()
	local policy = BnbPolicy.build(Bots, { tokenRatios = { Structure = 1 }, objectives = world.objectives })
	world.base = { ref = "base", coord = 80 }
	world.players = { { ref = "P1", position = 500, alive = true } }
	local body = makeBody(world)
	local bot = makeBot(policy, body)
	clock.tick()
	local token = bot:get("token")
	check("structure token claims a walkable slot", token.type == "Structure" and token.slot == 78)
	check("marching on the claimed slot", body.mover.lastGoal == 78)
	body._pos = 76 -- within reach of the slot
	clock.tick()
	check(
		"attacks the base from the slot",
		body.rec.last("attack") ~= nil and body.rec.last("attack")[1] == "structure"
	)
	-- Give-up releases the claim for someone else.
	body._pos = 0
	body.mover.status = "Unreachable"
	for _ = 1, 14 do
		clock.tick()
	end
	check("give-up released the base slot", world.releases >= 1)
	bot:destroy()
end

Harness.finish()
