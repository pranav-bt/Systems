--!strict

-- The ladder: what each rebirth costs and what it pays.
--
-- REBIRTH IS A TRADE -- give back the level you have, earn faster forever. THE LEVEL IS THE
-- PRICE and nothing else is spent, which is what makes the deal explainable in one sentence
-- and what stops it needing a confirmation dialog listing everything about to be destroyed.
--
-- THE TABLE IS THE WHOLE LADDER. To add an eleventh rung, append a row. Past the last row
-- there is nothing left to take -- `nextTier` returns nil and `isMaxed` says so -- which is
-- deliberate, so a rebirth can never be offered without a number authored for it.
--
-- THE REQUIRE FAILS on a ladder that is not strictly increasing in required level, or that
-- pays less than the rung below it. A rung that costs no more than the one under it, or pays
-- worse, is a content bug that would otherwise ship quietly and only look like bad balance.
--
-- A TIER MAY PAY IN TWO CURRENCIES. `multiplier` is the XP rate, which the server registers
-- with the base package so every grant is scaled by it. `rewards` is an opaque payload -- a
-- title, a cosmetic, an amount of soft currency -- handed to whoever listens for the rebirth
-- and interpreted entirely by the host. The game this came from paid only the multiplier,
-- which meant a rung could not be made interesting without changing a number.

local Ladder = {}

export type Tier = {
	-- Which rung this is. 1 is the first, and it must equal the array position.
	index: number,
	-- The level the player must REACH before this rebirth is offered.
	requiredLevel: number,
	-- The XP rate from then on, as a multiple of the base rate.
	multiplier: number,
	--[[
		What the rung is called. A KEY, not a sentence: "Awakening", not "You have awakened".
		A package that shipped the sentence would be shipping English, and the host maps the
		key to whatever it wants to show, in whatever language.
	]]
	title: string,
	-- Anything else this rung pays. Opaque; the host reads it in the rebirth signal.
	rewards: any?,
}

-- The rate before any rebirth. Here so nothing has to spell "no rebirth yet" as a literal.
Ladder.baseMultiplier = 1

local tiers: { Tier } = {}

Ladder.tiers = tiers

--[[
	Checks a ladder and errors on the first thing wrong with it.

	Separate from `setTiers` so a host with its ladder in a data file can validate it at build
	time, and so this module can be tested without installing anything.
]]
function Ladder.validate(candidate: { Tier })
	local previousLevel = -math.huge
	local previousMultiplier = Ladder.baseMultiplier
	for position, tier in candidate do
		if tier.index ~= position then
			error(`Rebirth: tier "{tier.title}" has index {tier.index} at position {position}.`, 0)
		end
		if type(tier.requiredLevel) ~= "number" or type(tier.multiplier) ~= "number" then
			error(`Rebirth: tier "{tier.title}" needs a numeric requiredLevel and multiplier.`, 0)
		end
		if tier.requiredLevel <= previousLevel then
			error(`Rebirth: rebirth {tier.index} requires level {tier.requiredLevel}, not more than the rung below.`, 0)
		end
		--[[
			A DECREASE is the error, not a repeat. The game this came from required every rung to
			pay a strictly bigger multiplier, because the multiplier was the only thing a rung
			could pay. A tier may now pay in `rewards` instead and keep the rate flat, and
			forbidding that would make the payload useless.
		]]
		if tier.multiplier < previousMultiplier then
			error(`Rebirth: rebirth {tier.index} pays x{tier.multiplier}, less than the rung below.`, 0)
		end
		previousLevel = tier.requiredLevel
		previousMultiplier = tier.multiplier
	end
end

--[[
	Installs the ladder. Validated first, and REPLACED rather than appended to, so calling it
	twice leaves one ladder rather than two stacked end to end.
]]
function Ladder.setTiers(candidate: { Tier })
	Ladder.validate(candidate)
	table.clear(tiers)
	for _, tier in candidate do
		table.insert(tiers, tier)
	end
end

function Ladder.count(): number
	return #tiers
end

--[[
	The rung a player with this many behind them would take next, or nil once the ladder is
	spent. `rebirths` is a COUNT, so the next rung is the one after it.
]]
function Ladder.nextTier(rebirths: number): Tier?
	return tiers[math.max(0, math.floor(rebirths)) + 1]
end

-- The rung they most recently took, or nil before the first one.
function Ladder.currentTier(rebirths: number): Tier?
	local taken = math.max(0, math.floor(rebirths))
	if taken <= 0 then
		return nil
	end
	return tiers[math.min(taken, #tiers)]
end

--[[
	Whether there is nothing left to take.

	Its own function because a window says so in words and the server refuses on it, and
	`nextTier == nil` read at two call sites is one rule written twice.
]]
function Ladder.isMaxed(rebirths: number): boolean
	return Ladder.nextTier(rebirths) == nil
end

--[[
	The XP multiplier a player with this many rebirths earns at.

	DEFINED BY THE RUNG TAKEN rather than accumulated from a per-rebirth step, so the
	`multiplier` column is the whole answer and a re-tuned rung changes the rate of exactly
	the players who took it. Clamped at the top so a profile holding more rebirths than the
	ladder has rungs -- a shortened table, a rollback -- reads as the last one rather than
	dropping to x1, which is the version of that bug a player writes in to complain about.
]]
function Ladder.multiplierFor(rebirths: number): number
	local tier = Ladder.currentTier(rebirths)
	return if tier then tier.multiplier else Ladder.baseMultiplier
end

--[[
	Whether this player may rebirth right now, by the ladder alone.

	The server's own check and a button's disabled state are both this function, so a screen
	can never offer what the server would refuse. The server additionally asks the host's gate
	-- see `setGate` there -- which is state this module cannot see.
]]
function Ladder.canRebirth(rebirths: number, level: number): boolean
	local tier = Ladder.nextTier(rebirths)
	return tier ~= nil and level >= tier.requiredLevel
end

-- How many more levels are needed for the next rung. 0 when it is available -- clamped, because
-- a player PAST the requirement is not "-5 levels away" -- and math.huge at the top of the
-- ladder, where there is no number of levels that would unlock a rung that does not exist.
function Ladder.levelsRemaining(rebirths: number, level: number): number
	local tier = Ladder.nextTier(rebirths)
	if not tier then
		return math.huge
	end
	return math.max(0, tier.requiredLevel - level)
end

return Ladder
