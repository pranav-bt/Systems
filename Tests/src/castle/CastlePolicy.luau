--!strict

-- CastleWars siege-bot policy, recreated on the AI suite.
--
-- SOURCE SHAPE (src/server/Systems/Bots in CastleWars, 4,724 lines): 21 goals
-- in spaced WEIGHT BANDS over the same Bots library (an older copy without
-- Tokens/Facts/tracing), per-team Commander strategist, Objectives seam to
-- the Match systems, authored routes across navmesh islands, ladder claims
-- via 2s-TTL attributes.
--
-- This is the representative subset that proves every PATTERN, with source
-- weights kept verbatim:
--   ExitCastle 50000 (interruptible=false, authored route)
--   Survive 20000 (score curve + failure-cooldown-as-design)
--   FightPlayer 4000 / KillEnemy 5 (same engage, different trigger band)
--   DefendHome 400 (Commander-intent gated)
--   ClimbLadder 90 (> DamageTarget 50 x 1.6 commitment ceiling -- the
--     deliberate "peel off the door scrum to a fresh ladder" arithmetic)
--   DamageTarget 50 (door always wins), BuildTower 24 (contest rule),
--   RazeBase 12 (breach-gated), AttackEnemyCastle 1.2, Wander 0.1
-- Omitted-but-same-pattern goals (HealAllies, JoinRally, turrets, Regroup,
-- Sneak, BuildSiege/Defense/FieldTurret) are catalogued in REPORT.md.
--
-- SUITE UPGRADES USED: ladder claims -> Bots.Tokens (1 holder, ttl 2) instead
-- of hand-rolled TTL attributes; Commander intent flips -> abandonGoal +
-- stimulate (see CastleCommander.luau).
--
-- PURE FACTORY: `CastlePolicy.build(Bots, deps)`. deps:
--   objectives: the Match seam (all functions; fake in tests):
--     nearestDamageable(team, pos) -> { ref, position, isDoor }?
--     damageStep(ref, amount) -> boolean done
--     towerTarget(team, pos) -> { ref, position }?
--     buildStep(ref, dt) -> boolean done
--     baseTarget(team, pos) -> { ref, position }?   -- returns nil until breach
--     razeStep(ref, dt) -> boolean done
--     ladderNear(team, pos) -> { ref, walker }?     -- walker: Start/Update->done/Stop
--     enemyGoalPos(team) -> point?
--     homeAnchor(team) -> point
--     homeThreat(team) -> enemy?                     -- sensed FROM HOME, radius 90
--
-- BODY CONTRACT per bot:
--   now, rng, teamName, position(), distanceTo(point), face(point),
--   mover (SetGoal/GetStatus/Stop), walkTo(point) raw, awayFrom(point, dist) -> point,
--   randomNear(point, radius) -> point,
--   healthFrac(), recentlyDamaged(), lowHealthFrac, detectRadius, attackRange,
--   meleeCooldown, canBlock, setBlocking(on), basicAttack(ref),
--   hasRangedBasic, rangedCooldown?, rangedAttack(ref),
--   scanEnemies() -> { { ref, position, isPlayer, healthFrac, alive } },
--   enemiesNear(point, radius) -> number,
--   exitWalker?: { Start, Update -> done, Stop },
--   buildsTowers: boolean

local ATTACK_INTERVAL = 1.1
local RANGED_MAX = 55
local KITE_MIN = 18
local CONTEST_BREAK_RANGE = 18
local CASTLE_ARRIVE = 18
local WANDER_RADIUS = 40
local WANDER_BUDGET = 8

local CastlePolicy = {}

function CastlePolicy.build(Bots: any, deps: any)
	local objectives = deps.objectives

	-- Ladder claims: one climber per ladder, lease expires in 2s if the
	-- climber stops refreshing (died mid-climb) -- the source's
	-- BotClimber/BotClimberUntil attributes, now a token pool per ladder.
	local ladderClaims: { [any]: any } = {}
	local function claimFor(ladderRef: any)
		local pool = ladderClaims[ladderRef]
		if not pool then
			pool = Bots.Tokens.new("ladder", 1, 2)
			ladderClaims[ladderRef] = pool
		end
		return pool
	end

	-- ------------------------------------------------------------ shared steps
	-- The fight loop (engageStep, Goals.luau:323): melee in reach (block
	-- between swings when pressured), ranged+kite for staff bots, else chase.
	local function engageStep(bot: any, enemy: any): string
		local body = bot.body
		if not enemy or enemy.alive == false then
			return "Success"
		end
		local now = body.now()
		local dist = body.distanceTo(enemy.position)
		if dist > body.detectRadius * 1.25 then
			return "Success" -- they got away
		end
		bot:set("focusTarget", enemy.ref) -- feeds the team focusCounts board

		if dist <= body.attackRange then
			body.mover:Stop()
			body.face(enemy.position)
			if now >= (bot:get("nextAttackAt") or 0) then
				body.setBlocking(false)
				bot:set("nextAttackAt", now + math.max(ATTACK_INTERVAL, body.meleeCooldown))
				body.basicAttack(enemy.ref)
			elseif body.canBlock and body.recentlyDamaged() then
				body.setBlocking(true) -- guard out the swing cooldown
			end
			return "Running"
		end

		if body.hasRangedBasic and dist <= RANGED_MAX then
			body.face(enemy.position)
			if now >= (bot:get("nextAttackAt") or 0) then
				bot:set("nextAttackAt", now + math.max(ATTACK_INTERVAL, body.rangedCooldown or ATTACK_INTERVAL))
				body.rangedAttack(enemy.ref)
			end
			if dist < KITE_MIN then
				body.walkTo(body.awayFrom(enemy.position, 8)) -- kite while firing
			end
			return "Running"
		end

		body.mover:SetGoal(enemy.position)
		local status = body.mover:GetStatus()
		if status == "Stuck" or status == "Unreachable" then
			return "Failure" -- goal cooldown redirects the bot (design tool)
		end
		return "Running"
	end

	local function engageAction(name: string, enemyKey: string)
		return Bots.Action.new({
			name = name,
			update = function(bot: any)
				return engageStep(bot, bot:get(enemyKey))
			end,
			exit = function(bot: any)
				bot:set("focusTarget", nil)
				bot.body.setBlocking(false)
				bot.body.mover:Stop()
			end,
		})
	end

	-- Build/raze/damage objective shape (workObjectiveStep, Goals.luau:390):
	-- travel, then stand in range and work; contested/unreachable -> Failure.
	local function workAction(
		name: string,
		config: {
			targetKey: string,
			range: number,
			contestable: boolean?,
			work: (bot: any, target: any, dt: number) -> boolean, -- true = done
		}
	)
		return Bots.Action.new({
			name = name,
			update = function(bot: any, dt: number)
				local body = bot.body
				local target = bot:get(config.targetKey)
				if not target then
					return "Success" -- objective gone (destroyed/completed elsewhere)
				end
				if config.contestable and body.enemiesNear(target.position, CONTEST_BREAK_RANGE) > 0 then
					return "Failure" -- fight first, build after (contest rule)
				end
				if body.distanceTo(target.position) <= config.range then
					body.mover:Stop()
					body.face(target.position)
					return if config.work(bot, target, dt) then "Success" else "Running"
				end
				body.mover:SetGoal(target.position)
				local status = body.mover:GetStatus()
				return if status == "Stuck" or status == "Unreachable" then "Failure" else "Running"
			end,
			exit = function(bot: any)
				bot.body.mover:Stop()
			end,
		})
	end

	-- ------------------------------------------------------------ goals
	local goals = {
		-- Spawned inside the castle: walk the authored exit route, and let
		-- NOTHING interrupt (the interior is a navmesh island; stopping
		-- mid-route strands the bot).
		Bots.Goal.new({
			name = "ExitCastle",
			weight = 50000,
			interruptible = false,
			canRun = function(bot: any)
				return bot:get("exiting") == true and bot.body.exitWalker ~= nil
			end,
			actions = {
				Bots.Action.new({
					name = "WalkExitRoute",
					enter = function(bot: any)
						bot.body.mover:Stop() -- never fight the walker (source assert)
						bot.body.exitWalker.Start()
						return nil
					end,
					update = function(bot: any)
						return if bot.body.exitWalker.Update() then "Success" else "Running"
					end,
				}),
			},
			effects = function(bot: any)
				bot:set("exiting", false)
			end,
		}),

		-- Low health -> disengage home; regen brings it back. Failure (home
		-- unreachable) cooldowns 2s so it fights on instead of freezing.
		Bots.Goal.new({
			name = "Survive",
			weight = 20000,
			cooldown = 2,
			canRun = function(bot: any)
				local vitals = bot:get("vitals")
				return vitals ~= nil and vitals.healthFrac < bot.body.lowHealthFrac
			end,
			score = function(bot: any)
				local vitals = bot:get("vitals")
				return 0.5 + 0.5 * Bots.Utility.linear(vitals.healthFrac, bot.body.lowHealthFrac, 0)
			end,
			actions = {
				Bots.Action.new({
					name = "RetreatHome",
					update = function(bot: any)
						local body = bot.body
						if bot:get("vitals").healthFrac >= body.lowHealthFrac then
							return "Success" -- recovered
						end
						body.mover:SetGoal(objectives.homeAnchor(body.teamName))
						local status = body.mover:GetStatus()
						return if status == "Stuck" or status == "Unreachable" then "Failure" else "Running"
					end,
					exit = function(bot: any)
						bot.body.mover:Stop()
					end,
				}),
			},
		}),

		-- A real player pressing us outranks every objective.
		Bots.Goal.new({
			name = "FightPlayer",
			weight = 4000,
			cooldown = 2,
			canRun = function(bot: any)
				local enemy = bot:get("enemy")
				return enemy ~= nil
					and enemy.isPlayer == true
					and (bot.body.recentlyDamaged() or bot.body.distanceTo(enemy.position) <= bot.body.attackRange)
			end,
			score = function(bot: any)
				local body = bot.body
				local enemy = bot:get("enemy")
				return 0.5
					+ 0.5
						* Bots.Utility.linear(body.distanceTo(enemy.position), body.detectRadius, body.attackRange)
			end,
			actions = { engageAction("EngagePlayer", "enemy") },
		}),

		-- Commander said Defend and something is at the walls: travel map-wide.
		Bots.Goal.new({
			name = "DefendHome",
			weight = 400,
			cooldown = 2,
			canRun = function(bot: any)
				return bot:get("intent") == "Defend" and bot:get("homeThreat") ~= nil
			end,
			actions = { engageAction("EngageHomeThreat", "homeThreat") },
		}),

		-- A built ladder while the door still stands: weight 90 deliberately
		-- beats DamageTarget's commitment CEILING (50 x 1.6 = 80), so bots
		-- already whacking the door peel off to a fresh ladder.
		Bots.Goal.new({
			name = "ClimbLadder",
			weight = 90,
			cooldown = 4,
			canRun = function(bot: any)
				local ladder = bot:get("ladderClimb")
				if ladder == nil or bot:get("ladderGaveUp") == ladder.ref or bot:get("climbedThisLife") == true then
					return false -- source rule: one wall-scale per life
				end
				local pool = claimFor(ladder.ref)
				return pool:holds(bot.id, bot.body.now()) or pool:count(bot.body.now()) == 0
			end,
			effects = function(bot: any)
				bot:set("climbedThisLife", true)
			end,
			actions = {
				Bots.Action.new({
					name = "ClimbLadderRoute",
					enter = function(bot: any)
						local ladder = bot:get("ladderClimb")
						if not ladder or not claimFor(ladder.ref):tryClaim(bot.id, bot.body.now()) then
							return "Failure" -- someone beat us to it
						end
						-- Pin the ladder we claimed: the sensor may surface a
						-- DIFFERENT ladder mid-climb, and exit must release the
						-- one we actually hold.
						bot:set("climbingLadder", ladder)
						bot.body.mover:Stop()
						ladder.walker.Start()
						return nil
					end,
					update = function(bot: any)
						local ladder = bot:get("climbingLadder")
						if not ladder then
							return "Failure"
						end
						claimFor(ladder.ref):tryClaim(bot.id, bot.body.now()) -- refresh the 2s lease
						return if ladder.walker.Update() then "Success" else "Running"
					end,
					exit = function(bot: any, outcome: string)
						local ladder = bot:get("climbingLadder")
						bot:set("climbingLadder", nil)
						if ladder then
							claimFor(ladder.ref):release(bot.id)
							ladder.walker.Stop()
							if outcome == "Failure" then
								bot:set("ladderGaveUp", ladder.ref) -- not this ladder again this life
							end
						end
					end,
				}),
			},
		}),

		-- Doors first, always (Objectives.nearestDamageable door override).
		Bots.Goal.new({
			name = "DamageTarget",
			weight = 50,
			cooldown = 3,
			canRun = function(bot: any)
				return bot:get("damageTarget") ~= nil
			end,
			actions = {
				workAction("DamageObjective", {
					targetKey = "damageTarget",
					range = 7,
					work = function(bot: any, target: any)
						local body = bot.body
						local now = body.now()
						if now >= (bot:get("nextAttackAt") or 0) then
							bot:set("nextAttackAt", now + math.max(ATTACK_INTERVAL, body.meleeCooldown))
							return objectives.damageStep(target.ref, body.meleeDamage or 6)
						end
						return false
					end,
				}),
			},
		}),

		-- Contest rule lives in workAction: an enemy within 18 aborts the build.
		Bots.Goal.new({
			name = "BuildTower",
			weight = 24,
			cooldown = 3,
			canRun = function(bot: any)
				return bot.body.buildsTowers
					and bot:get("towerTarget") ~= nil
					and bot.body.enemiesNear(bot:get("towerTarget").position, CONTEST_BREAK_RANGE) == 0
			end,
			actions = {
				workAction("BuildTowerAction", {
					targetKey = "towerTarget",
					range = 8,
					contestable = true,
					work = function(_bot: any, target: any, dt: number)
						return objectives.buildStep(target.ref, dt)
					end,
				}),
			},
		}),

		-- Only sensed after the door is breached (provider-gated).
		Bots.Goal.new({
			name = "RazeBase",
			weight = 12,
			cooldown = 3,
			canRun = function(bot: any)
				return bot:get("baseTarget") ~= nil
			end,
			actions = {
				workAction("RazeBaseAction", {
					targetKey = "baseTarget",
					range = 16,
					work = function(_bot: any, target: any, dt: number)
						return objectives.razeStep(target.ref, dt)
					end,
				}),
			},
		}),

		-- Any enemy at all (bots included) is worth 5 -- above travel, below
		-- every real objective.
		Bots.Goal.new({
			name = "KillEnemy",
			weight = 5,
			cooldown = 2,
			canRun = function(bot: any)
				return bot:get("enemy") ~= nil
			end,
			score = function(bot: any)
				local body = bot.body
				local enemy = bot:get("enemy")
				return 0.6
					+ 0.4
						* Bots.Utility.linear(body.distanceTo(enemy.position), body.detectRadius, body.attackRange)
			end,
			actions = { engageAction("EngageEnemy", "enemy") },
		}),

		-- The march: head for the enemy castle when there's nothing better.
		Bots.Goal.new({
			name = "AttackEnemyCastle",
			weight = 1.2,
			cooldown = 3,
			canRun = function(bot: any)
				local goalPos = objectives.enemyGoalPos(bot.body.teamName)
				return bot:get("intent") ~= "Defend" and goalPos ~= nil and bot.body.distanceTo(goalPos) > CASTLE_ARRIVE
			end,
			actions = {
				Bots.Action.new({
					name = "GoToEnemyCastle",
					update = function(bot: any)
						local body = bot.body
						local goalPos = objectives.enemyGoalPos(body.teamName)
						if goalPos == nil or body.distanceTo(goalPos) <= CASTLE_ARRIVE then
							return "Success"
						end
						body.mover:SetGoal(goalPos)
						local status = body.mover:GetStatus()
						return if status == "Stuck" or status == "Unreachable" then "Failure" else "Running"
					end,
					exit = function(bot: any)
						bot.body.mover:Stop()
					end,
				}),
			},
		}),

		-- The floor: one bounded amble near home.
		Bots.Goal.new({
			name = "Wander",
			weight = 0.1,
			canRun = function()
				return true
			end,
			score = function()
				return 0.5
			end,
			actions = {
				Bots.Action.new({
					name = "WanderOnce",
					enter = function(bot: any)
						local body = bot.body
						bot:set("wanderTarget", body.randomNear(objectives.homeAnchor(body.teamName), WANDER_RADIUS))
						bot:set("wanderUntil", body.now() + WANDER_BUDGET)
						return nil
					end,
					update = function(bot: any)
						local body = bot.body
						local target = bot:get("wanderTarget")
						if body.now() >= bot:get("wanderUntil") or body.distanceTo(target) <= 4 then
							return "Success"
						end
						body.mover:SetGoal(target)
						return "Running"
					end,
					exit = function(bot: any)
						bot.body.mover:Stop()
					end,
				}),
			},
		}),
	}

	-- ------------------------------------------------------------ sensors
	local function sensors(body: any)
		return {
			vitals = {
				read = function()
					return { healthFrac = body.healthFrac() }
				end,
			},
			-- Scored target pick (Sensors.luau:70): closer + wounded + real
			-- player + already-focused-by-a-teammate (group board).
			enemy = {
				interval = 0.2,
				read = function(bot: any)
					local focusCounts = bot:get("focusCounts") -- group fallthrough
					local best, bestScore = nil, -math.huge
					for _, candidate in body.scanEnemies() do
						if candidate.alive then
							local dist = body.distanceTo(candidate.position)
							if dist <= body.detectRadius then
								local score = (1 - math.clamp(dist / body.detectRadius, 0, 1))
									+ (1 - candidate.healthFrac) * 0.5
									+ (if candidate.isPlayer then 0.3 else 0)
									+ (if focusCounts and (focusCounts[candidate.ref] or 0) > 0 then 0.35 else 0)
								if score > bestScore then
									best, bestScore = candidate, score
								end
							end
						end
					end
					return best
				end,
			},
			damageTarget = {
				interval = 0.4,
				read = function()
					return objectives.nearestDamageable(body.teamName, body.position())
				end,
			},
			towerTarget = {
				interval = 0.5,
				read = function()
					return objectives.towerTarget(body.teamName, body.position())
				end,
			},
			baseTarget = {
				interval = 0.5,
				read = function()
					return objectives.baseTarget(body.teamName, body.position())
				end,
			},
			ladderClimb = {
				interval = 0.5,
				read = function()
					return objectives.ladderNear(body.teamName, body.position())
				end,
			},
			homeThreat = {
				interval = 0.5,
				read = function()
					return objectives.homeThreat(body.teamName)
				end,
			},
		}
	end

	-- Per-team group-board sensor: how many living teammates focus each enemy
	-- (init.luau:69). deps.teamBots(teamName) -> { bot } supplied by the fleet.
	local function groupSensors(teamName: string)
		return {
			focusCounts = {
				interval = 0.5,
				read = function()
					local counts: { [any]: number } = {}
					for _, teammate in deps.teamBots(teamName) do
						local focus = teammate.blackboard.values.focusTarget
						if focus ~= nil then
							counts[focus] = (counts[focus] or 0) + 1
						end
					end
					return counts
				end,
			},
		}
	end

	return {
		goals = goals,
		sensors = sensors,
		groupSensors = groupSensors,
	}
end

return CastlePolicy
