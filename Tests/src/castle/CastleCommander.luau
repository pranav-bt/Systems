--!strict

-- CastleWars' per-team strategist (Commander.luau), recreated. Runs every 5s
-- over a team's bot slots and assigns INTENTS ("Defend" | "Attack"), which
-- goals read from the blackboard (DefendHome gates on intent == "Defend").
--
-- Source rules kept:
--   defend count = DEFENDERS_PER_TEAM + enemies near home, capped at
--     floor(n * MAX_DEFEND_FRAC 0.7)
--   EMERGENCY (own base losing HP since last look) -> max defenders
--   ALL-IN (enemy base <= 0.35, own base >= 0.7, no threat) -> zero defenders
--   intents stick MIN_HOLD 25s unless emergency
-- (Sneak/BuildTowers intents omitted -- same assignment pattern; see REPORT.)
--
-- SUITE UPGRADE: the source's SetIntent calls abandonGoal so the new intent
-- takes effect immediately; we do the same, then stimulate -- the bot
-- re-plans against the new intent THIS instant instead of next tick.
--
-- deps.objectives.situation(teamName) -> { ownBaseFrac, enemyBaseFrac }
-- deps.objectives.homeThreatCount(teamName) -> number

local DEFENDERS_PER_TEAM = 0
local MAX_DEFEND_FRAC = 0.7
local ALL_IN_ENEMY_BASE_FRAC = 0.35
local ALL_IN_OWN_BASE_MIN = 0.7
local MIN_HOLD = 25

local CastleCommander = {}

function CastleCommander.build(deps: any)
	local objectives = deps.objectives
	local prevBaseFrac: { [string]: number } = {}

	local commander = {}

	-- One strategist pass for one team. `bots` = the team's living bot list;
	-- `now` injectable for tests.
	function commander.tick(teamName: string, bots: { any }, now: number)
		local situation = objectives.situation(teamName)
		local threat = objectives.homeThreatCount(teamName)
		local count = #bots
		if count == 0 then
			return
		end

		local previous = prevBaseFrac[teamName]
		prevBaseFrac[teamName] = situation.ownBaseFrac
		local emergency = previous ~= nil and situation.ownBaseFrac < previous

		local maxDefend = math.floor(count * MAX_DEFEND_FRAC)
		local defend = math.min(DEFENDERS_PER_TEAM + threat, maxDefend)
		if emergency then
			defend = maxDefend
		elseif
			threat == 0
			and situation.enemyBaseFrac <= ALL_IN_ENEMY_BASE_FRAC
			and situation.ownBaseFrac >= ALL_IN_OWN_BASE_MIN
		then
			defend = 0 -- all-in: race to finish before they do
		end

		-- Keep current holders first (stability), then fill/demote.
		local defenders: { any } = {}
		local attackers: { any } = {}
		for _, bot in bots do
			table.insert(if bot:get("intent") == "Defend" then defenders else attackers, bot)
		end

		local function setIntent(bot: any, intent: string)
			if bot:get("intent") == intent then
				return
			end
			local heldSince = bot:get("intentSince") or 0
			if not emergency and now - heldSince < MIN_HOLD then
				return -- intents stick 25s unless the base is bleeding
			end
			bot:set("intent", intent)
			bot:set("intentSince", now)
			bot:abandonGoal() -- new marching orders take effect NOW
			bot:stimulate(nil, now)
		end

		while #defenders > defend do
			setIntent(table.remove(defenders) :: any, "Attack")
		end
		local index = 1
		while #defenders < defend and index <= #attackers do
			local bot = attackers[index]
			setIntent(bot, "Defend")
			if bot:get("intent") == "Defend" then
				table.insert(defenders, bot)
			end
			index += 1
		end
	end

	return commander
end

return CastleCommander
