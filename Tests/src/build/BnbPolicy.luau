--!strict

-- BuildAndBattle monster AI, recreated on the AI suite.
--
-- SOURCE SHAPE (src/server/Systems/{Monsters,AIManager} in BuildAndBattle):
-- monsters are PURE DATA STRUCTS on a voxel grid -- no Humanoid, no
-- PathfindingService, no Instances in the decision path. A 20Hz fixed loop
-- runs one hardcoded behavior closure per monster, gated by a 5-state
-- machine; targeting is a TOKEN system (create / failure-score give-up at 10
-- / damage-aggro re-target), movement is a greedy voxel stepper or custom
-- HPA*, paced by a per-kind BaseStepDuration gate.
--
-- This is the suite's hardest body-agnosticism test: the "body" here is a
-- voxel coordinate plus closures. Nothing in the Bots core notices.
--
-- SUITE MAPPING:
--   * Token layer -> a "token" SENSOR owning create/re-roll/aggro-switch;
--     failure scores accumulate on the token record; damage events arrive
--     via bot:stimulate (the aggro path reacts the instant damage lands).
--   * Behavior ladder -> goals: Detonate (Speedie commit, interruptible =
--     false) > Engage (per-kind config: melee / kiter bands) > Wander.
--   * State machine gate -> actions early-return unless body.state() ==
--     "Locomotion" (same pattern as the Mech recreation).
--   * Voxel movement + step gate -> BEHIND THE MOVER CONTRACT: the body's
--     mover is a grid stepper (SetGoal(coord)/GetStatus/Stop); "Stuck" and
--     "Unreachable" feed the token's failure score exactly like the source's
--     getMoveDirectData nil-returns. This is the grid-world Mover swap the
--     suite promised (~30 lines in a real game; faked in tests).
--
-- PURE FACTORY: `BnbPolicy.build(Bots, deps)`.
--   deps.tokenRatios: { Player: number, Structure: number } -- mode weights
--   deps.objectives: { base() -> { ref, coord }?, claimBaseSlot(botId) ->
--     coord?, releaseBaseSlot(botId) }
--
-- BODY CONTRACT per monster:
--   now, rng, kind config fields (see KindSpec), coord(): point,
--   distanceTo(point) (voxel), manhattanTo(point),
--   mover (SetGoal/GetStatus/Stop), state(): "Locomotion"|"Attack"|"Stun"|...,
--   attack(targetRef, position), players() -> { { ref, position, alive } },
--   -- kiter extras:
--   hasLineOfSight(point)? , castVolley()?, awayFrom(point, dist) -> point,
--   -- speedie extras:
--   chargeExplosion()?, explode()?

local FAILURE_THRESHOLD = 10
local ATTACK_REACH = 4 -- studs-equivalent reach (source: dist < 4)
local AGGRO_CLOSE_RANGE = 15

local BnbPolicy = {}

export type KindSpec = {
	kind: string,
	attackRange: number?, -- default ATTACK_REACH
	aggroThreshold: number, -- damage before switching targets (Normie 1, Boomer inf)
	aggroInterval: number, -- seconds between accepted aggro events
	alwaysPlayerToken: boolean?, -- hardcoded chaser kinds
	-- kiter (PyroCaster) band control:
	kiter: { idealMin: number, idealMax: number, hysteresis: number, shootCooldown: number }?,
	-- suicide (Speedie/Boomer):
	detonate: { range: number, chargeTime: number }?,
}

function BnbPolicy.build(Bots: any, deps: any)
	local ratios = deps.tokenRatios or { Player = 5 }
	local objectives = deps.objectives

	-- ------------------------------------------------------------ tokens
	-- The AIManager:GetToken equivalent: one record on the personal board.
	local function closestPlayer(body: any): any?
		local best, bestDist = nil, math.huge
		for _, candidate in body.players() do
			if candidate.alive then
				local dist = body.distanceTo(candidate.position)
				if dist < bestDist then
					best, bestDist = candidate, dist
				end
			end
		end
		return best
	end

	local function rollToken(bot: any): any?
		local body = bot.body
		local total = 0
		local weights = if body.alwaysPlayerToken then { Player = 1 } else ratios
		for _, weight in weights do
			total += weight
		end
		local pick = body.rng() * total
		local chosen = "Player"
		for tokenType, weight in weights do
			pick -= weight
			if pick <= 0 then
				chosen = tokenType
				break
			end
		end

		if chosen == "Structure" and objectives.base() ~= nil then
			local slot = objectives.claimBaseSlot(bot.id)
			if slot then
				return { type = "Structure", slot = slot, failureScore = 0, aggro = {}, lastAggroAt = 0 }
			end
		end
		local target = closestPlayer(body)
		if target == nil then
			return nil -- nobody to hunt: behavior wanders
		end
		return { type = "Player", target = target, failureScore = 0, aggro = {}, lastAggroAt = 0 }
	end

	local function releaseToken(bot: any, token: any)
		if token and token.type == "Structure" then
			objectives.releaseBaseSlot(bot.id)
		end
	end

	-- Damage hook: game code calls this from its damage pipeline. Aggro
	-- accumulates on the token (close-range damage counts 3x more), then the
	-- bot is stimulated so a threshold-crossing re-target happens NOW.
	local function onDamaged(bot: any, attacker: any, amount: number, attackerPosition: any)
		local token = bot.blackboard.values.token
		if not token then
			return
		end
		local body = bot.body
		local now = body.now()
		if now - (token.lastAggroAt or 0) < body.aggroInterval then
			return -- rate limit (AggroInterval)
		end
		local gained = if body.distanceTo(attackerPosition) < AGGRO_CLOSE_RANGE then amount else amount / 3
		token.aggro[attacker] = (token.aggro[attacker] or 0) + gained
		bot:stimulate(nil, now) -- token sensor + goals react immediately, on the body's clock
	end

	local function tokenSensor(body: any)
		return {
			interval = 0.2,
			read = function(bot: any, bb: any)
				local token = bb.values.token
				-- 1) create
				if token == nil then
					return rollToken(bot)
				end
				-- 2) failure give-up: release and re-roll
				if token.failureScore >= FAILURE_THRESHOLD then
					releaseToken(bot, token)
					return rollToken(bot)
				end
				-- 3) aggro re-target: whoever hurts me most takes over
				local worst, worstScore = nil, 0
				for attacker, score in token.aggro do
					if score > worstScore then
						worst, worstScore = attacker, score
					end
				end
				if worst ~= nil and worstScore >= body.aggroThreshold then
					token.lastAggroAt = body.now()
					releaseToken(bot, token)
					local position
					for _, candidate in body.players() do
						if candidate.ref == worst and candidate.alive then
							position = candidate.position
						end
					end
					if position then
						return {
							type = "Player",
							target = { ref = worst, position = position, alive = true },
							failureScore = 0,
							aggro = {},
							lastAggroAt = body.now(),
						}
					end
					token.aggro = {}
				end
				-- refresh a player target's position from the live list
				if token.type == "Player" then
					local live = false
					for _, candidate in body.players() do
						if candidate.ref == token.target.ref then
							token.target = candidate
							live = candidate.alive
						end
					end
					if not live then
						token.failureScore += 1
					end
				end
				return token
			end,
		}
	end

	-- ------------------------------------------------------------ goals
	local function tokenTargetPosition(token: any): any?
		if token.type == "Player" then
			return if token.target.alive then token.target.position else nil
		end
		return token.slot
	end

	local goals = {
		-- Speedie's charge-and-detonate: once it commits, NOTHING stops it
		-- (source sets isExploding and early-returns forever after).
		Bots.Goal.new({
			name = "Detonate",
			weight = 100,
			interruptible = false,
			canRun = function(bot: any)
				local body = bot.body
				if not body.detonate then
					return false
				end
				local token = bot:get("token")
				return token ~= nil
					and token.type == "Player"
					and token.target.alive
					and body.manhattanTo(token.target.position) <= body.detonate.range
			end,
			actions = {
				Bots.Action.new({
					name = "ChargeAndExplode",
					enter = function(bot: any)
						bot.body.mover:Stop()
						bot.body.chargeExplosion()
						bot:set("explodeAt", bot.body.now() + bot.body.detonate.chargeTime)
						return nil
					end,
					update = function(bot: any)
						if bot.body.now() >= bot:get("explodeAt") then
							bot.body.explode()
							return "Success"
						end
						return "Running"
					end,
				}),
			},
		}),

		-- The token's work: chase-and-melee, hold a base slot, or run the
		-- kiter's three-band dance -- per-kind, like the behavior modules.
		Bots.Goal.new({
			name = "Engage",
			weight = 10,
			canRun = function(bot: any)
				return bot:get("token") ~= nil
			end,
			actions = {
				Bots.Action.new({
					name = "WorkToken",
					update = function(bot: any)
						local body = bot.body
						local token = bot:get("token")
						if token == nil then
							return "Success"
						end
						if body.state() ~= "Locomotion" then
							return "Running" -- attacking/stunned: behavior is inert (state gate)
						end
						local targetPosition = tokenTargetPosition(token)
						if targetPosition == nil then
							token.failureScore += 1
							return "Running"
						end
						local now = body.now()
						local dist = body.distanceTo(targetPosition)

						-- PyroCaster's three-band kite (retreat < shoot < approach).
						local kiter = body.kiter
						if kiter then
							local retreating = bot:get("kiteRetreating") == true
							if dist < kiter.idealMin or (retreating and dist < kiter.idealMin + kiter.hysteresis) then
								bot:set("kiteRetreating", true)
								body.mover:SetGoal(body.awayFrom(targetPosition, 6))
							elseif dist > kiter.idealMax then
								bot:set("kiteRetreating", false)
								token.failureScore = math.max(token.failureScore - 0.5, 0)
								body.mover:SetGoal(targetPosition)
							else
								bot:set("kiteRetreating", false)
								token.failureScore = math.max(token.failureScore - 1, 0)
								body.mover:Stop()
								if now >= (bot:get("nextCastAt") or 0) and body.hasLineOfSight(targetPosition) then
									bot:set("nextCastAt", now + kiter.shootCooldown)
									body.castVolley()
								end
							end
							return "Running"
						end

						-- Melee kinds (Normie shape): in reach -> attack; else step.
						if dist < (body.attackRange or ATTACK_REACH) then
							body.mover:Stop()
							body.attack(
								if token.type == "Player" then token.target.ref else "structure",
								targetPosition
							)
							token.failureScore = math.max(token.failureScore - 4, 0) -- success relieves give-up pressure
							return "Running"
						end
						body.mover:SetGoal(targetPosition)
						local status = body.mover:GetStatus()
						if status == "Stuck" or status == "Unreachable" then
							token.failureScore += 1 -- the source's "no valid move" +1
						end
						return "Running"
					end,
					exit = function(bot: any)
						bot.body.mover:Stop()
					end,
				}),
			},
		}),

		-- No token (nobody alive / roll failed): random-neighbor amble.
		Bots.Goal.new({
			name = "Wander",
			weight = 0.1,
			canRun = function()
				return true
			end,
			actions = {
				Bots.Action.new({
					name = "RandomStep",
					update = function(bot: any)
						local body = bot.body
						if body.state() == "Locomotion" then
							body.mover:SetGoal(nil) -- grid movers treat nil as "roam"
						end
						return "Running"
					end,
				}),
			},
		}),
	}

	local function sensors(body: any)
		return { token = tokenSensor(body) }
	end

	return {
		goals = goals,
		sensors = sensors,
		onDamaged = onDamaged, -- wire into the damage pipeline
	}
end

return BnbPolicy
