--!strict

-- CompanionsMerge: turn duplicate companions into stronger ones.
--
-- AN ADDON. It requires the Companions package and does nothing without it; the base
-- works perfectly well without this. Install it when a game wants duplicates to be
-- worth something, leave it out when duplicates are just duplicates.
--
-- THE RULE. A merge costs AS MANY COPIES AS THE LEVEL IT REACHES: two level 1s make a
-- level 2, three level 2s make a level 3, six level 5s make a level 6. That lands the
-- whole ladder at N! pulls -- 120 for a level 5, 720 for a level 6 -- and it is a price
-- a player can hold in their head after one merge, which a fitted curve never is.
--
-- A flat cost is wrong at both ends: out of sight for hours at the bottom, and every
-- rung as cheap as the one below it at the top. Doubling overcorrects, putting level 10
-- at 35 trillion pulls. Matching the level is the shape that works, so it is the
-- default -- but it IS replaceable, because a package cannot know what ladder the next
-- game wants.
--
-- IT OWNS NO STATE AND NO STATS. The level lives in the base package's record, and what
-- a level CHANGES is the base package's per-level config. This module only decides when
-- a level may be raised and at what price, then asks the base to raise it. That is why
-- it can be installed alongside CompanionsUpgrades without the two fighting: both are
-- policies over one primitive, Companions.moveCopies.

local CompanionsMerge = {}

-- The base package, injected. A hard require would assume a folder layout; this way the
-- dependency is visible at the call site.
type Base = any

export type Config = {
	-- Required. The Companions package.
	companions: Base,

	-- How many copies of `target - 1` it takes to reach `target`. Defaults to `target`.
	-- THE ONE PLACE THE PRICE IS ANSWERED, so the cost a UI shows and the cost charged
	-- cannot drift.
	cost: ((targetLevel: number) -> number)?,

	--[[
		Whether a merge may consume copies that are currently EQUIPPED.

		False by default, and that default is the point: a player watching three Knights
		follow them around should not press Merge and see one of them vanish into the
		result. The base package would survive it -- reconcile unequips whatever no longer
		exists -- but surviving is not the same as being what anybody wanted.

		A game where companions are inventory rather than presence can turn it on.
	]]
	consumeEquipped: boolean?,
}

local config: Config? = nil

local function base(): Base
	local settings = config
	assert(settings, "CompanionsMerge: call configure({ companions = Companions }) first")
	return settings.companions
end

function CompanionsMerge.configure(settings: Config)
	assert(type(settings) == "table", "CompanionsMerge.configure: settings must be a table")
	assert(
		type(settings.companions) == "table",
		"CompanionsMerge.configure: `companions` must be the Companions package"
	)
	if settings.cost ~= nil then
		assert(type(settings.cost) == "function", "CompanionsMerge.configure: `cost` must be a function")
	end
	config = settings
end

-- How many copies of `targetLevel - 1` buy one `targetLevel`. Clamped so asking about
-- level 0 or 1 gets the first real rung rather than a free merge.
function CompanionsMerge.copiesFor(targetLevel: number): number
	local settings = config
	local target = math.max(2, math.floor(targetLevel))
	if settings and settings.cost then
		return math.max(2, math.floor(settings.cost(target)))
	end
	return target
end

-- How many copies at `level` this player may spend: everything they own, or only what is
-- not currently out, depending on `consumeEquipped`.
function CompanionsMerge.spendable(player: Player, petId: string, level: number): number
	local settings = config
	local companions = base()
	if settings and settings.consumeEquipped then
		return companions.ownedCount(player, petId, level)
	end
	return companions.available(player, petId, level)
end

--[[
	How close this player is to merging `level` into the next one: what they can spend,
	and what it would take.

	A pair rather than a boolean, so a UI can draw "3 / 6" without asking a second
	question and risking a different answer.
]]
function CompanionsMerge.progress(player: Player, petId: string, level: number): (number, number)
	local from = math.max(1, math.floor(level))
	return CompanionsMerge.spendable(player, petId, from), CompanionsMerge.copiesFor(from + 1)
end

function CompanionsMerge.canMerge(player: Player, petId: string, level: number): (boolean, string?)
	local companions = base()
	local from = math.max(1, math.floor(level))
	local target = from + 1
	local maxLevel = companions.getMaxLevel(petId)
	if target > maxLevel then
		return false, `{petId} tops out at level {maxLevel}`
	end
	local have, need = CompanionsMerge.progress(player, petId, from)
	if have < need then
		return false, `{have} of {need} copies at level {from}`
	end
	return true
end

--[[
	Merges once: `copiesFor(level + 1)` copies leave `level`, one arrives at `level + 1`.

	Deliberately does NOT cascade. A UI that offers one merge per press has to be able to
	perform exactly one; a caller that wants the cascade asks for it below.
]]
function CompanionsMerge.merge(player: Player, petId: string, level: number): (boolean, string?)
	local can, reason = CompanionsMerge.canMerge(player, petId, level)
	if not can then
		return false, reason
	end
	local from = math.max(1, math.floor(level))
	return base().moveCopies(player, petId, from, from + 1, CompanionsMerge.copiesFor(from + 1))
end

--[[
	Merges as far as the collection allows, lowest level first, and returns how many
	merges happened.

	ONE PASS, LOWEST FIRST, and that is complete rather than merely usual: a merge only
	ever REMOVES copies from its own level and adds one above, so it can never re-enable a
	merge lower down. Visiting levels in increasing order therefore sees each level after
	everything that could feed it -- six level 1s become three level 2s become one level 3
	in a single sweep. Sweeping downward would need a second pass to find the same result,
	which is why this direction is the correctness argument and not a preference.

	(An earlier version wrapped this in a repeat-until-stable loop. Mutation testing showed
	the direction then made no difference to the outcome, which is the tell that the outer
	loop was doing the work and hiding whether the ordering was right.)

	The step count is bounded rather than trusted. The default rule shrinks the collection
	on every merge, so it terminates on its own -- but a REPLACED cost function returning
	something perverse must not be able to spin here.
]]
function CompanionsMerge.mergeAll(player: Player, petId: string): number
	local companions = base()
	local maxLevel = companions.getMaxLevel(petId)
	local merges = 0
	local budget = math.max(1, maxLevel) * 64

	for level = 1, maxLevel - 1 do
		while CompanionsMerge.canMerge(player, petId, level) do
			if merges >= budget then
				warn(`[CompanionsMerge] mergeAll for "{petId}" hit its iteration budget; stopping.`)
				return merges
			end
			if not CompanionsMerge.merge(player, petId, level) then
				break
			end
			merges += 1
		end
	end
	return merges
end

-- Every merge this player could make right now, lowest level first. What a "you have
-- merges available" badge reads.
function CompanionsMerge.pending(player: Player): { { petId: string, level: number } }
	local companions = base()
	local out: { { petId: string, level: number } } = {}
	for _, petId in companions.ownedIds(player) do
		local maxLevel = companions.getMaxLevel(petId)
		for level = 1, maxLevel - 1 do
			if CompanionsMerge.canMerge(player, petId, level) then
				table.insert(out, { petId = petId, level = level })
			end
		end
	end
	return out
end

return CompanionsMerge
