--!strict

-- MechBattlegrounds bot policy, recreated on the AI suite.
--
-- SOURCE SHAPE (ServerStorage/Libraries/Bots in MechBattlegrounds): a 60Hz
-- prioritized if/elseif chain per bot (Behaviors/Regular.lua:250-319) --
-- skill > dash gap-closer > block > basic attack > closeness > orbit -- with
-- a global AIManager token arbiter (2 attack / 2 skill / 3 closeness tokens
-- per target player) and least-subscribed target assignment
-- (Bot.lua findUniqueTarget).
--
-- SUITE MAPPING:
--   * The 60Hz chain is MICRO-combat: it lives inside ONE "Engage" goal's
--     action (the same shape CastleWars' engageStep uses), stepped by the
--     Brain tick and by out-of-band stimulates.
--   * AIManager tokens -> Bots.Tokens pools per target (closeness pool gets
--     ttl = 5, replacing AIManager's hand-rolled 5s auto-release).
--   * Combo chaining on animation markers -> bot:stimulate({ attackResolved })
--     from the body's marker event: the stimulate runs the Engage action
--     immediately, so combos chain at marker time, not next tick -- the same
--     event-driven timing the source gets from its marker callbacks.
--   * Ragdoll-cancel -> a high-band goal that interrupts Engage through the
--     normal arbiter when the cancel window opens.
--   * Difficulty gates -> data (Difficulty.luau) read by the chain.
--
-- PURE FACTORY: no requires. `MechPolicy.build(Bots, Difficulty)` receives
-- the Bots library table and the difficulty data, and returns { goals,
-- sensors }. The same file therefore loads under Lune (tests inject fakes)
-- and Roblox Studio (inject the real things).
--
-- BODY CONTRACT (what a mech body must provide; see tests/Studio adapters):
--   now(): number                          -- clock (injectable for tests)
--   rng(): number                          -- [0,1) randomness (injectable)
--   state(): string                        -- "LOCOMOTION"|"SKILL"|"BLOCK"|"RAGDOLL"|...
--   targets(): { { ref: any, position: any, alive: boolean } }
--   distanceTo(point): number              -- horizontal
--   angleTo(point): number                 -- radians off facing, horizontal
--   orbitPointAround(point, angle, radius): any  -- point + (cos,0,sin)*r
--   mover: { SetGoal: (self, point?) -> (), Stop: (self) -> () } -- steering mover, Mover-contract shaped
--   face(point), useBasicAttack(), useSkill(id), useDash(double: boolean),
--   dashAvailable(): boolean, block(), stopBlock(),
--   skills(): { any },                     -- equipped skill ids (basic or ultimate set)
--   skillReady(id): boolean,               -- real game cooldown
--   skillData(id): { minDistance: number, maxDistance: number, angle: number, canUseSkill: boolean? }?
--   difficulty: Difficulty.Spec
--   attackOnly: boolean?                   -- gauntlet "Minion": no skills/dash/block

local MechPolicy = {}

function MechPolicy.build(Bots: any, Difficulty: any)
	-- Per-TARGET token pools, shared by every bot this policy instance drives
	-- (the AIManager equivalent). Created lazily per target ref.
	local pools: { [any]: { attack: any, skill: any, closeness: any } } = {}
	local function poolsFor(ref: any)
		local entry = pools[ref]
		if not entry then
			entry = {
				attack = Bots.Tokens.new("attack", Difficulty.MAX_ATTACK_TOKENS),
				skill = Bots.Tokens.new("skill", Difficulty.MAX_SKILL_TOKENS),
				closeness = Bots.Tokens.new(
					"closeness",
					Difficulty.MAX_CLOSENESS_TOKENS,
					Difficulty.CLOSENESS_TOKEN_TTL
				),
			}
			pools[ref] = entry
		end
		return entry
	end

	-- Least-subscribed target assignment (findUniqueTarget): how many bots
	-- currently target each ref.
	local assignments: { [any]: number } = {}
	local function retarget(oldRef: any, newRef: any)
		if oldRef ~= nil then
			assignments[oldRef] = math.max((assignments[oldRef] or 1) - 1, 0)
		end
		if newRef ~= nil then
			assignments[newRef] = (assignments[newRef] or 0) + 1
		end
	end

	-- Pick a random equipped skill that is off cooldown, bot-enabled, and
	-- passes its BotData range/angle envelope (chooseSkill + passesSkillRequirements).
	local function chooseSkill(body: any, dist: number, angle: number): any?
		local list = table.clone(body.skills())
		-- Shuffle (Fisher-Yates on injected rng): random pick, not utility.
		for index = #list, 2, -1 do
			local swap = math.floor(body.rng() * index) + 1
			list[index], list[swap] = list[swap], list[index]
		end
		for _, id in list do
			if body.skillReady(id) then
				local data = body.skillData(id)
				if
					data
					and data.canUseSkill ~= false
					and dist >= data.minDistance
					and dist <= data.maxDistance
					and angle <= data.angle / 2
				then
					return id
				end
			end
		end
		return nil
	end

	-- Release against the ref we actually CLAIMED from (recorded at claim
	-- time) -- the target sensor may have re-targeted since, and releasing
	-- into the new target's pools would leak the old target's tokens.
	local function releaseCombatTokens(bot: any)
		local claimedRef = bot:get("claimedTokenRef")
		if claimedRef ~= nil then
			local pool = poolsFor(claimedRef)
			pool.attack:release(bot.id)
			pool.skill:release(bot.id)
			bot:set("claimedTokenRef", nil)
		end
	end

	-- ============================================================ The chain
	-- One action = the whole in-combat micro-decision chain, faithful to
	-- Regular.lua's priority order. Cooldowns/combo state live on the bot's
	-- personal blackboard; body.now() is the clock throughout.
	local Combat = Bots.Action.new({
		name = "Combat",
		requires = { "mover", "face", "useBasicAttack", "state" },
		update = function(bot: any, _dt: number)
			local body = bot.body
			local spec = body.difficulty
			local now = body.now()
			local target = bot:get("target")
			if not target or not target.alive then
				return "Success" -- target lost/dead: goal ends, selection re-runs
			end
			local pool = poolsFor(target.ref)

			-- Combo continuation FIRST, before any state gating: the body
			-- stimulates { attackResolved } at the swing's animation marker,
			-- which happens while the character is still IN the attack state
			-- (source: DummyAttackStateServer marker wiring). The stimulate
			-- re-runs this update immediately, so chains happen at marker
			-- time, not next tick.
			local resolved = bot:get("attackResolved")
			if resolved ~= nil then
				bot:set("attackResolved", nil)
				local combo = bot:get("comboIndex") or 0
				if resolved.landed and combo < spec.comboLength then
					bot:set("comboIndex", combo + 1)
					body.useBasicAttack()
					return "Running"
				end
				-- Combo over (finished or whiffed).
				pool.attack:release(bot.id)
				bot:set("comboIndex", 0)
				if not resolved.landed then
					bot:set("attackMissCooldownAt", now + spec.attackMissCooldown)
				elseif spec.comboIntoSkill then
					bot:set("chainSkill", true) -- Hard: combo-cancel into a skill
				end
				if spec.sharedCooldown then
					bot:set("sharedUntil", now + spec.sharedCooldown)
				end
			end

			local state = body.state()
			if state == "SKILL" then
				body.face(target.position) -- re-aim so root-motion skills track (Regular.lua:225)
				return "Running"
			end
			if bot:get("holdingSkillToken") and state ~= "SKILL" then
				poolsFor(bot:get("claimedTokenRef") or target.ref).skill:release(bot.id)
				bot:set("holdingSkillToken", nil) -- skill finished: free the slot (release-on-LOCOMOTION)
			end
			if state == "BLOCK" then
				if now >= (bot:get("stopBlockAt") or 0) then
					body.stopBlock()
				else
					body.face(target.position)
				end
				return "Running"
			end
			if state ~= "LOCOMOTION" then
				return "Running" -- ragdolled/stunned: RagdollCancel may interrupt from above
			end

			local dist = body.distanceTo(target.position)
			local angle = body.angleTo(target.position)
			local sharedOk = now >= (bot:get("sharedUntil") or 0)

			-- 1) SKILL (cooldown or combo-chain, plus a skill token).
			if
				not body.attackOnly
				and (bot:get("chainSkill") == true or (sharedOk and now >= (bot:get("skillCooldownAt") or 0)))
				and pool.skill:tryClaim(bot.id, now)
			then
				local id = chooseSkill(body, dist, angle)
				if id ~= nil then
					bot:set("chainSkill", nil)
					bot:set("holdingSkillToken", true)
					bot:set("claimedTokenRef", target.ref)
					bot:set("skillCooldownAt", now + spec.skillCooldown)
					if spec.sharedCooldown then
						bot:set("sharedUntil", now + spec.sharedCooldown)
					end
					body.useSkill(id)
					return "Running"
				end
				pool.skill:release(bot.id) -- nothing fit: free the slot
			end

			-- 2) DASH gap-closer (Normal+, aligned, far).
			if
				spec.canDash
				and not body.attackOnly
				and angle <= Difficulty.DASH_ALIGN_CONE
				and dist >= Difficulty.DASH_MIN_DISTANCE
				and body.dashAvailable()
			then
				body.useDash(dist >= Difficulty.DOUBLE_DASH_DISTANCE)
				return "Running"
			end

			-- 3) BLOCK (Hard, close, facing).
			if
				spec.canBlock
				and not body.attackOnly
				and dist < Difficulty.BLOCK_RANGE
				and angle <= Difficulty.BASIC_ATTACK_CONE
				and now >= (bot:get("blockCooldownAt") or 0)
			then
				body.block()
				bot:set(
					"stopBlockAt",
					now
						+ Difficulty.BLOCK_HOLD_MIN
						+ body.rng() * (Difficulty.BLOCK_HOLD_MAX - Difficulty.BLOCK_HOLD_MIN)
				)
				bot:set("blockCooldownAt", now + Difficulty.BLOCK_COOLDOWN) -- source intent (its os.clock bug fixed)
				return "Running"
			end

			-- 4) BASIC ATTACK (close, facing, off miss cooldown, attack token).
			if
				sharedOk
				and now >= (bot:get("attackMissCooldownAt") or 0)
				and dist < Difficulty.BASIC_ATTACK_RANGE
				and angle <= Difficulty.BASIC_ATTACK_CONE
				and pool.attack:tryClaim(bot.id, now)
			then
				bot:set("claimedTokenRef", target.ref)
				bot:set("comboIndex", 1)
				body.useBasicAttack()
				return "Running"
			end

			-- 5) CLOSENESS: claim an inner-ring slot (ttl auto-expires it at 5s,
			-- replacing AIManager's timed release).
			local hasCloseness = pool.closeness:holds(bot.id, now)
			if not hasCloseness and dist <= Difficulty.CLOSENESS_THRESHOLD then
				hasCloseness = pool.closeness:tryClaim(bot.id, now)
			end

			-- 6) ORBIT / STANDOFF movement (followTarget).
			local slotAt = bot:get("orbitSlotAt") or 0
			if now - slotAt >= Difficulty.ORBIT_REROLL_SECONDS then
				bot:set("orbitSlot", math.floor(body.rng() * Difficulty.ORBIT_SLOTS) + 1)
				bot:set("orbitSlotAt", now)
			end
			if not hasCloseness and dist > Difficulty.STANDOFF_MIN and dist <= Difficulty.ORBIT_RADIUS_FAR then
				-- No inner slot and already in the ring: hover and face (Bot.lua:691).
				body.mover:Stop()
				body.face(target.position)
				return "Running"
			end
			local radius = if hasCloseness then Difficulty.ORBIT_RADIUS_CLOSE else Difficulty.ORBIT_RADIUS_FAR
			local slotAngle = (bot:get("orbitSlot") or 1) / Difficulty.ORBIT_SLOTS * 2 * math.pi
			body.mover:SetGoal(body.orbitPointAround(target.position, slotAngle, radius))
			return "Running"
		end,
		exit = function(bot: any)
			releaseCombatTokens(bot)
			bot:set("comboIndex", 0)
			bot:set("holdingSkillToken", nil)
			bot.body.mover:Stop()
		end,
	})

	local goals = {
		-- Ragdoll-cancel tech (Regular.lua:320): band far above Engage so it
		-- interrupts through the arbiter the moment the window opens.
		Bots.Goal.new({
			name = "RagdollCancel",
			weight = 1000,
			canRun = function(bot: any)
				local body = bot.body
				return body.difficulty.canRagdollCancel
					and not body.attackOnly
					and bot:get("bodyState") == "RAGDOLL"
					and body.dashAvailable()
					and body.now() >= (bot:get("ragdollCancelAt") or math.huge)
			end,
			actions = {
				Bots.Action.new({
					name = "CancelDash",
					enter = function(bot: any)
						bot.body.useDash(false)
						bot:set("ragdollCancelAt", nil)
						return "Success"
					end,
				}),
			},
		}),

		-- The whole fight (the source's Regular behavior).
		Bots.Goal.new({
			name = "Engage",
			weight = 10,
			canRun = function(bot: any)
				local target = bot:get("target")
				return target ~= nil and target.alive == true
			end,
			actions = { Combat },
		}),

		-- Nothing to fight: stand, face whoever is remembered, idle anim.
		Bots.Goal.new({
			name = "Idle",
			weight = 0.1,
			canRun = function()
				return true
			end,
			actions = {
				Bots.Action.new({
					name = "Stand",
					enter = function(bot: any)
						bot.body.mover:Stop()
						return nil
					end,
					update = function()
						return "Running"
					end,
				}),
			},
		}),
	}

	-- Personal sensors per bot.
	local function sensors(body: any)
		return {
			-- Target assignment: keep a valid current target, else pick the
			-- least-subscribed candidate (findUniqueTarget load balancing).
			target = {
				interval = 0.2,
				read = function(bot: any)
					local list = body.targets()
					local current = bot.blackboard.values.target
					if current then
						for _, candidate in list do
							if candidate.ref == current.ref and candidate.alive then
								return candidate -- fresh position, same ref
							end
						end
						retarget(current.ref, nil) -- lost them
					end
					local best, bestCount = nil, math.huge
					for _, candidate in list do
						if candidate.alive then
							local count = assignments[candidate.ref] or 0
							if count < bestCount then
								best, bestCount = candidate, count
							end
						end
					end
					if best then
						retarget(nil, best.ref)
					end
					return best
				end,
			},
			-- Ragdoll edge watch: opens the cancel window once per ragdoll.
			bodyState = {
				read = function(_bot: any, bb: any)
					local state = body.state()
					if state == "RAGDOLL" and bb.values.bodyState ~= "RAGDOLL" then
						bb.values.ragdollCancelAt = body.now()
							+ Difficulty.RAGDOLL_CANCEL_DELAY
							+ 0.25
							+ body.rng() * 1.25
					elseif state ~= "RAGDOLL" then
						bb.values.ragdollCancelAt = nil
					end
					return state
				end,
			},
		}
	end

	return {
		goals = goals,
		sensors = sensors,
		poolsFor = poolsFor, -- exposed for tests/inspection
		assignments = assignments,
	}
end

return MechPolicy
