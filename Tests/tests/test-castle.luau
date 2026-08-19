-- CastleWars archetype under Lune: fake siege world on a number line, real
-- Bots Brain + Tokens. Verifies weight bands, interruptible=false routes,
-- the ladder-beats-door-commitment arithmetic, contest rule, focus-count
-- coordination, and the Commander's intent assignment.

local Harness = require("./harness")
local CastlePolicy = require("../src/castle/CastlePolicy")
local CastleCommander = require("../src/castle/CastleCommander")

local Bots, check = Harness.Bots, Harness.check
Bots.Brain.configure({ GOAL_JITTER = 0 })
local clock = Harness.newClock()

local function fakeWalker()
	local walker = { started = 0, stops = 0, finished = false }
	function walker.Start()
		walker.started += 1
	end
	function walker.Update()
		return walker.finished
	end
	function walker.Stop()
		walker.stops += 1
	end
	return walker
end

local function makeWorld()
	local world = {
		enemies = {},
		damageable = nil,
		tower = nil,
		base = nil,
		ladder = nil,
		homeThreatValue = nil,
		situationValue = { ownBaseFrac = 1, enemyBaseFrac = 1 },
		threatCount = 0,
		enemiesNearCount = 0,
		damaged = {},
		buildProgress = {},
		teamBots = {},
	}
	world.objectives = {
		nearestDamageable = function()
			return world.damageable
		end,
		damageStep = function(ref, amount)
			world.damaged[ref] = (world.damaged[ref] or 0) + amount
			return world.damaged[ref] >= 100
		end,
		towerTarget = function()
			return world.tower
		end,
		buildStep = function(ref, dt)
			world.buildProgress[ref] = (world.buildProgress[ref] or 0) + dt
			return world.buildProgress[ref] >= 5
		end,
		baseTarget = function()
			return world.base
		end,
		razeStep = function()
			return false
		end,
		ladderNear = function()
			return world.ladder
		end,
		enemyGoalPos = function()
			return 100
		end,
		homeAnchor = function()
			return 0
		end,
		homeThreat = function()
			return world.homeThreatValue
		end,
		situation = function()
			return world.situationValue
		end,
		homeThreatCount = function()
			return world.threatCount
		end,
	}
	world.deps = {
		objectives = world.objectives,
		teamBots = function()
			return world.teamBots
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
		rng = Harness.deterministicRng,
		teamName = "Red",
		_pos = opts.pos or 0,
		_hf = 1,
		_recentlyDamaged = false,
		position = function()
			return body._pos
		end,
		distanceTo = function(point)
			return math.abs(point - body._pos)
		end,
		face = rec.record("face"),
		mover = Harness.fakeMover(),
		walkTo = rec.record("walkTo"),
		awayFrom = function(point, dist)
			return body._pos + (if body._pos >= point then dist else -dist)
		end,
		randomNear = function(point)
			return point + 5
		end,
		healthFrac = function()
			return body._hf
		end,
		recentlyDamaged = function()
			return body._recentlyDamaged
		end,
		lowHealthFrac = 0.3,
		detectRadius = 60,
		attackRange = 7,
		meleeCooldown = 1,
		meleeDamage = 6,
		canBlock = true,
		setBlocking = rec.record("blocking"),
		basicAttack = rec.record("melee"),
		hasRangedBasic = opts.ranged == true,
		rangedCooldown = 1,
		rangedAttack = rec.record("rangedAttack"),
		scanEnemies = function()
			return world.enemies
		end,
		enemiesNear = function()
			return world.enemiesNearCount
		end,
		exitWalker = opts.exitWalker,
		buildsTowers = true,
	}
	return body
end

local function makeBot(policy, world, body, values)
	local teamBoard = Bots.Blackboard.new("Red_" .. tostring(#world.teamBots))
	for key, spec in policy.groupSensors("Red") do
		teamBoard:addSensor(key, spec.read, spec.interval)
	end
	local bot = Bots.Bot.new({
		body = body,
		goals = policy.goals,
		group = teamBoard,
		values = values or { intent = "Attack", exiting = false },
		sensors = policy.sensors(body),
	})
	table.insert(world.teamBots, bot)
	return bot
end

-- ------------------------------------------------- exit route is unbreakable
do
	local world = makeWorld()
	local policy = CastlePolicy.build(Bots, world.deps)
	local walker = fakeWalker()
	local body = makeBody(world, { exitWalker = walker })
	local bot = makeBot(policy, world, body, { intent = "Attack", exiting = true })
	clock.tick()
	check("spawned inside: walks the exit route", bot:currentGoal() == "ExitCastle" and walker.started == 1)
	body._hf = 0.1 -- Survive would score 20000... but the route cannot break
	clock.tick()
	check("interruptible=false holds through a Survive emergency", bot:currentGoal() == "ExitCastle")
	walker.finished = true
	clock.tick()
	check("route done -> Survive takes over instantly", bot:currentGoal() == "Survive")
	check("retreating home", body.mover.lastGoal == 0)
	body._hf = 0.5
	clock.tick()
	-- Recovered attackers resume the march on the enemy castle (1.2 > Wander).
	check("recovered -> retreat succeeds, resumes the march", bot:currentGoal() == "AttackEnemyCastle")
	bot:destroy()
end

-- ------------------------------------------------- door > enemy bot; player > door
do
	local world = makeWorld()
	local policy = CastlePolicy.build(Bots, world.deps)
	local body = makeBody(world)
	local bot = makeBot(policy, world, body)
	world.enemies = { { ref = "EB", position = 20, isPlayer = false, healthFrac = 1, alive = true } }
	world.damageable = { ref = "door", position = 60 }
	clock.tick()
	check("door outranks a stray enemy bot", bot:currentGoal() == "DamageTarget")
	world.enemies = {
		{ ref = "EB", position = 20, isPlayer = false, healthFrac = 1, alive = true },
		{ ref = "PL", position = 5, isPlayer = true, healthFrac = 1, alive = true },
	}
	clock.tick(0.3) -- enemy sensor refresh
	clock.tick(0.3)
	check("a player in our face outranks the door", bot:currentGoal() == "FightPlayer")
	check("melee swung", body.rec.count("melee") >= 1)
	bot:destroy()
end

-- ------------------------------------------------- ladder beats door commitment
do
	local world = makeWorld()
	local policy = CastlePolicy.build(Bots, world.deps)
	local bodyA = makeBody(world)
	local botA = makeBot(policy, world, bodyA)
	world.damageable = { ref = "door", position = 60 }
	clock.tick()
	check("whacking the door", botA:currentGoal() == "DamageTarget")
	clock.tick(1) -- commitment grows toward the x1.6 cap
	world.ladder = { ref = "L1", walker = fakeWalker() }
	clock.tick(0.6) -- ladder sensor refresh + challenge
	check("fresh ladder (90) breaks door commitment ceiling (50 x 1.6)", botA:currentGoal() == "ClimbLadder")

	local bodyB = makeBody(world)
	local botB = makeBot(policy, world, bodyB)
	clock.tick(0.6)
	check("second bot can't claim the held ladder", botB:currentGoal() ~= "ClimbLadder")
	world.ladder.walker.finished = true
	clock.tick()
	check("climber topped the wall", botA:currentGoal() ~= "ClimbLadder")
	botA:destroy()
	botB:destroy()
end

-- ------------------------------------------------- contest rule
do
	local world = makeWorld()
	local policy = CastlePolicy.build(Bots, world.deps)
	local body = makeBody(world)
	local bot = makeBot(policy, world, body)
	world.tower = { ref = "T1", position = 10 }
	world.enemiesNearCount = 1
	clock.tick()
	check("contested tower not even considered", bot:currentGoal() ~= "BuildTower")
	world.enemiesNearCount = 0
	clock.tick(0.6)
	check("uncontested -> building", bot:currentGoal() == "BuildTower")
	world.enemiesNearCount = 1
	clock.tick()
	check("enemy arrives mid-build -> abort (fight first, build after)", bot:currentGoal() ~= "BuildTower")
	bot:destroy()
end

-- ------------------------------------------------- focus-count convergence
do
	local world = makeWorld()
	local policy = CastlePolicy.build(Bots, world.deps)
	world.enemies = {
		{ ref = "X", position = 30, isPlayer = false, healthFrac = 1, alive = true },
		{ ref = "Y", position = 20, isPlayer = false, healthFrac = 1, alive = true },
	}
	-- Bot A engages first; its focusTarget feeds the team board.
	local bodyA = makeBody(world, { pos = 0 })
	local botA = makeBot(policy, world, bodyA)
	-- Force A onto X by distance: move A next to X.
	bodyA._pos = 29
	clock.tick()
	local shared = botA.group -- reuse ONE team board for both (like the fleet does)
	local bodyB = makeBody(world, { pos = 0 })
	local botB = Bots.Bot.new({
		body = bodyB,
		goals = policy.goals,
		group = shared,
		values = { intent = "Attack", exiting = false },
		sensors = policy.sensors(bodyB),
	})
	table.insert(world.teamBots, botB)
	clock.tick(0.6) -- group board refresh + B's enemy pick
	local enemyB = botB:get("enemy")
	check("teammate focus (+0.35) converges B onto X over nearer Y", enemyB ~= nil and enemyB.ref == "X")
	botA:destroy()
	botB:destroy()
end

-- ------------------------------------------------- Commander intents
do
	local world = makeWorld()
	local policy = CastlePolicy.build(Bots, world.deps)
	local commander = CastleCommander.build(world.deps)
	local bots = {}
	for _ = 1, 4 do
		local body = makeBody(world)
		table.insert(bots, makeBot(policy, world, body))
	end
	world.threatCount = 2
	commander.tick("Red", bots, clock.now())
	local defenders = 0
	for _, bot in bots do
		if bot:get("intent") == "Defend" then
			defenders += 1
		end
	end
	check("threat drives defenders (2, capped by 0.7 frac)", defenders == 2)

	-- All-in: enemy base nearly down, ours healthy and stable, no threat.
	world.threatCount = 0
	world.situationValue = { ownBaseFrac = 1, enemyBaseFrac = 0.3 }
	clock.advance(30) -- past the 25s intent hold
	commander.tick("Red", bots, clock.now())
	defenders = 0
	for _, bot in bots do
		if bot:get("intent") == "Defend" then
			defenders += 1
		end
	end
	check("all-in empties the defense", defenders == 0)

	-- Emergency: base losing HP overrides the hold timer.
	world.situationValue = { ownBaseFrac = 0.8, enemyBaseFrac = 0.3 }
	world.threatCount = 1
	commander.tick("Red", bots, clock.now() + 1) -- within hold, but emergency
	defenders = 0
	for _, bot in bots do
		if bot:get("intent") == "Defend" then
			defenders += 1
		end
	end
	check("emergency floods the defense past the hold timer", defenders == math.floor(4 * 0.7))
	for _, bot in bots do
		bot:destroy()
	end
end

Harness.finish()
