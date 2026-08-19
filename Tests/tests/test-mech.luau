-- MechBattlegrounds archetype under Lune: fake mech bodies on a number line,
-- real Bots Brain, real Tokens. Verifies the recreated priority chain, token
-- caps, combo chaining via stimulate, difficulty gates, and ragdoll-cancel.

local Harness = require("./harness")
local Difficulty = require("../src/mech/Difficulty")
local MechPolicy = require("../src/mech/MechPolicy")

local Bots, check = Harness.Bots, Harness.check
Bots.Brain.configure({ GOAL_JITTER = 0 })
local clock = Harness.newClock()

local function makeBody(spec, opts)
	opts = opts or {}
	local rec = Harness.recorder()
	local body
	body = {
		rec = rec,
		now = clock.now,
		rng = opts.rng or Harness.deterministicRng,
		_state = "LOCOMOTION",
		state = function()
			return body._state
		end,
		targets = opts.targets or function()
			return {}
		end,
		_dist = opts.dist or 10,
		_angle = opts.angle or 0,
		distanceTo = function()
			return body._dist
		end,
		angleTo = function()
			return body._angle
		end,
		orbitPointAround = function(point, angle, radius)
			return { point = point, angle = angle, radius = radius }
		end,
		mover = Harness.fakeMover(),
		face = rec.record("face"),
		-- Attacking enters the ATTACK state until the marker resolves, like
		-- the real state machine; tests resolve via stimulate + state reset.
		useBasicAttack = function(...)
			body._state = "ATTACK"
			rec.record("attack")(...)
		end,
		useSkill = rec.record("skill"),
		useDash = rec.record("dash"),
		block = rec.record("block"),
		stopBlock = rec.record("stopBlock"),
		dashAvailable = function()
			return opts.dashReady ~= false
		end,
		skills = function()
			return opts.skills or {}
		end,
		skillReady = function()
			return true
		end,
		skillData = function(id)
			return opts.skillData and opts.skillData[id] or nil
		end,
		difficulty = spec,
		attackOnly = opts.attackOnly,
	}
	return body
end

local function makeBot(policy, body)
	return Bots.Bot.new({ body = body, goals = policy.goals, sensors = policy.sensors(body) })
end

-- ------------------------------------------------- least-subscribed targeting
do
	local policy = MechPolicy.build(Bots, Difficulty)
	local players = {
		{ ref = "P1", position = 100, alive = true },
		{ ref = "P2", position = 200, alive = true },
	}
	local bots = {}
	for _ = 1, 4 do
		table.insert(
			bots,
			makeBot(
				policy,
				makeBody(Difficulty.Normal, {
					targets = function()
						return players
					end,
					dist = 200, -- out of everything: they just orbit
				})
			)
		)
	end
	clock.tick()
	check("targets load-balanced 2/2", policy.assignments.P1 == 2 and policy.assignments.P2 == 2)
	for _, bot in bots do
		bot:destroy()
	end
end

-- ------------------------------------------------- token caps + combo chaining
do
	local policy = MechPolicy.build(Bots, Difficulty)
	local players = { { ref = "P1", position = 10, alive = true } }
	local bots, bodies = {}, {}
	for _ = 1, 5 do
		local body = makeBody(Difficulty.Normal, {
			targets = function()
				return players
			end,
			dist = 10,
			angle = 0,
		})
		table.insert(bodies, body)
		table.insert(bots, makeBot(policy, body))
	end
	clock.tick()
	local attacks = 0
	for _, body in bodies do
		attacks += body.rec.count("attack")
	end
	check("attack tokens cap simultaneous attackers at 2", attacks == 2)
	local closeOrbits = 0
	for _, body in bodies do
		local goal = body.mover.lastGoal
		if goal and goal.radius == Difficulty.ORBIT_RADIUS_CLOSE then
			closeOrbits += 1
		end
	end
	check("closeness tokens cap inner ring at 3", closeOrbits == 3)

	-- Combo: a landed hit chains INSTANTLY via stimulate (marker parity).
	local attacker
	for index, body in bodies do
		if body.rec.count("attack") == 1 then
			attacker = index
			break
		end
	end
	bots[attacker]:stimulate({ attackResolved = { landed = true } }, clock.now())
	check("landed hit chains the combo at marker time", bodies[attacker].rec.count("attack") == 2)
	bots[attacker]:stimulate({ attackResolved = { landed = false } }, clock.now())
	check("whiff stops the combo", bodies[attacker].rec.count("attack") == 2)
	bodies[attacker]._state = "LOCOMOTION" -- ON_ATTACK_OVER
	clock.tick()
	local attacksAfter = 0
	for _, body in bodies do
		attacksAfter += body.rec.count("attack")
	end
	-- bot1 made 2 swings, bot2 one (still mid-attack), and bot1's released
	-- token let exactly one ring bot start swinging: 4 total.
	check("released attack token passes to another bot", attacksAfter == 4)
	check("whiffed bot sits out its miss cooldown", bodies[attacker].rec.count("attack") == 2)
	for _, bot in bots do
		bot:destroy()
	end
end

-- ------------------------------------------------- skill priority + release
do
	local policy = MechPolicy.build(Bots, Difficulty)
	local players = { { ref = "P1", position = 10, alive = true } }
	local body = makeBody(Difficulty.Hard, {
		targets = function()
			return players
		end,
		dist = 10,
		angle = 0,
		skills = { "fireSlash" },
		skillData = { fireSlash = { minDistance = 5, maxDistance = 50, angle = math.rad(40) } },
	})
	local bot = makeBot(policy, body)
	clock.tick()
	check("skill outranks basic attack", body.rec.count("skill") == 1 and body.rec.count("attack") == 0)
	body._state = "SKILL"
	clock.tick()
	check("re-aims while skill runs", body.rec.count("face") >= 1)
	body._state = "LOCOMOTION"
	clock.tick()
	check("skill token freed on return to locomotion", policy.poolsFor("P1").skill:count(clock.now()) == 0)
	check("skill AI-cooldown falls through to block (Hard)", body.rec.count("block") == 1)
	bot:destroy()
end

-- ------------------------------------------------- dash gates by difficulty
do
	local policy = MechPolicy.build(Bots, Difficulty)
	local players = { { ref = "P1", position = 150, alive = true } }
	local normal = makeBody(Difficulty.Normal, {
		targets = function()
			return players
		end,
		dist = 150,
		angle = 0,
	})
	local easy = makeBody(Difficulty.Easy, {
		targets = function()
			return players
		end,
		dist = 150,
		angle = 0,
	})
	local botN = makeBot(policy, normal)
	local botE = makeBot(policy, easy)
	clock.tick()
	check("Normal dashes the gap", normal.rec.count("dash") == 1 and normal.rec.last("dash")[1] == false)
	check("Easy cannot dash; orbits instead", easy.rec.count("dash") == 0 and easy.mover.lastGoal ~= nil)
	normal._dist = 200
	clock.tick()
	check("double dash at 180+", normal.rec.last("dash")[1] == true)
	botN:destroy()
	botE:destroy()
end

-- ------------------------------------------------- standoff ring
do
	local policy = MechPolicy.build(Bots, Difficulty)
	local players = { { ref = "P1", position = 40, alive = true } }
	local bodies, bots = {}, {}
	for _ = 1, 4 do
		local body = makeBody(Difficulty.Easy, {
			targets = function()
				return players
			end,
			dist = 40, -- in the 25..70 ring, out of attack reach
			angle = math.rad(90), -- not facing: no attacks
		})
		table.insert(bodies, body)
		table.insert(bots, makeBot(policy, body))
	end
	clock.tick()
	local hovering = 0
	for _, body in bodies do
		if body.mover.lastGoal == nil and body.mover.stopped > 0 then
			hovering += 1
		end
	end
	check("closeness-less bot holds the standoff ring", hovering == 1) -- 3 closeness slots, 4th hovers
	for _, bot in bots do
		bot:destroy()
	end
end

-- ------------------------------------------------- ragdoll-cancel window
do
	local policy = MechPolicy.build(Bots, Difficulty)
	local players = { { ref = "P1", position = 200, alive = true } }
	local function ragdollScenario(spec)
		local body = makeBody(spec, {
			targets = function()
				return players
			end,
			dist = 60,
		})
		local bot = makeBot(policy, body)
		clock.tick() -- Engage adopts
		body._state = "RAGDOLL"
		clock.tick(0.2) -- window armed by the edge sensor
		local before = body.rec.count("dash")
		clock.tick(2) -- well past delay + jitter
		local after = body.rec.count("dash")
		bot:destroy()
		return before, after
	end
	local beforeN, afterN = ragdollScenario(Difficulty.Normal)
	check("no cancel before the window", beforeN == 0)
	check("Normal dashes out of ragdoll once the window opens", afterN == 1)
	local _, afterE = ragdollScenario(Difficulty.Easy)
	check("Easy never ragdoll-cancels", afterE == 0)
end

Harness.finish()
