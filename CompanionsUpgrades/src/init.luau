--!strict

-- CompanionsUpgrades: pay to raise a companion's level.
--
-- AN ADDON, like CompanionsMerge, and installable alongside it. The two are the same
-- mutation for different reasons -- merging demands COPIES, this demands CURRENCY -- so
-- both are policies over one primitive, Companions.moveCopies, and neither owns the
-- level. That is what stops them disagreeing about what a player has.
--
-- THE ECONOMY IS NOT HERE. What the currency is, where the balance lives and how a
-- charge is recorded are all the host's, injected as `balance` and `charge`. A package
-- that knew about gold would be a package that could not be used by a game with gems,
-- energy, or an off-server wallet.
--
-- CHARGE FIRST, THEN MOVE, and the order is deliberate. Every reason the move could
-- fail is checked before a coin is taken, so the move that follows cannot legitimately
-- refuse -- but if it somehow does, the player has paid and not received, which is
-- fixable by hand. The other order risks a free level, which cannot be taken back.

local CompanionsUpgrades = {}

type Base = any

export type Config = {
	-- Required. The Companions package.
	companions: Base,

	--[[
		What it costs to raise `petId` from `level` to `level + 1`.

		Required, because there is no sensible default: a price is a statement about a
		game's economy and this package has no way to guess one. Return nil to mean "not
		for sale at this rung", which is how a ladder is capped partway or a companion is
		made merge-only.
	]]
	price: (petId: string, targetLevel: number) -> number?,

	-- What the player can spend. Called before every charge.
	balance: (player: Player) -> number,

	-- Take the money. Returns false to refuse, which aborts the upgrade before the level
	-- moves -- so a host that does its own last-moment check still gets the last word.
	charge: (player: Player, amount: number) -> boolean,

	--[[
		Whether an EQUIPPED copy may be the one upgraded.

		True by default, and the opposite of CompanionsMerge's default, because the two
		verbs differ: merging CONSUMES copies, so eating a fielded one is a loss the player
		did not ask for, while upgrading transforms the copy in place -- and the companion a
		player most wants to improve is usually the one they are looking at.
	]]
	upgradeEquipped: boolean?,
}

local config: Config? = nil

local function settingsOrError(): Config
	local settings = config
	assert(settings, "CompanionsUpgrades: call configure({ companions, price, balance, charge }) first")
	return settings
end

function CompanionsUpgrades.configure(settings: Config)
	assert(type(settings) == "table", "CompanionsUpgrades.configure: settings must be a table")
	assert(
		type(settings.companions) == "table",
		"CompanionsUpgrades.configure: `companions` must be the Companions package"
	)
	for _, field in { "price", "balance", "charge" } do
		assert(
			type((settings :: any)[field]) == "function",
			`CompanionsUpgrades.configure: \`{field}\` must be a function`
		)
	end
	config = settings
end

-- What raising `level` to the next one costs, or nil when that rung is not for sale.
function CompanionsUpgrades.priceOf(petId: string, level: number): number?
	local settings = settingsOrError()
	local target = math.max(2, math.floor(level) + 1)
	local price = settings.price(petId, target)
	if price == nil then
		return nil
	end
	return math.max(0, price)
end

-- How many copies at `level` are eligible to be upgraded.
function CompanionsUpgrades.upgradable(player: Player, petId: string, level: number): number
	local settings = settingsOrError()
	local companions = settings.companions
	if settings.upgradeEquipped == false then
		return companions.available(player, petId, level)
	end
	return companions.ownedCount(player, petId, level)
end

--[[
	Everything checked before any money moves: is there a copy, is the next rung within
	the companion's ladder, is it for sale, can they afford it.

	Returns the price on success so a caller does not have to ask twice and risk a
	different answer between the check and the charge.
]]
function CompanionsUpgrades.canUpgrade(player: Player, petId: string, level: number): (boolean, string?, number?)
	local settings = settingsOrError()
	local companions = settings.companions
	local from = math.max(1, math.floor(level))
	local target = from + 1

	local maxLevel = companions.getMaxLevel(petId)
	if target > maxLevel then
		return false, `{petId} tops out at level {maxLevel}`
	end
	if CompanionsUpgrades.upgradable(player, petId, from) <= 0 then
		return false, `no {petId} at level {from} to upgrade`
	end

	local price = CompanionsUpgrades.priceOf(petId, from)
	if price == nil then
		return false, `level {target} is not for sale for {petId}`
	end
	if settings.balance(player) < price then
		return false, `costs {price}, balance is {settings.balance(player)}`
	end
	return true, nil, price
end

--[[
	Raises one copy from `level` to `level + 1`, charging for it.

	The charge is a SEPARATE seam from the balance check on purpose: a host may want to
	refuse at the last moment -- a receipt that failed, a rate limit, a second server
	having spent the same gold -- and returning false from `charge` aborts before the
	level moves rather than after.
]]
function CompanionsUpgrades.upgrade(player: Player, petId: string, level: number): (boolean, string?)
	local settings = settingsOrError()
	local can, reason, price = CompanionsUpgrades.canUpgrade(player, petId, level)
	if not can then
		return false, reason
	end

	local charged = settings.charge(player, price :: number)
	if not charged then
		return false, "the charge was refused"
	end

	local from = math.max(1, math.floor(level))
	local moved, moveReason = settings.companions.moveCopies(player, petId, from, from + 1, 1)
	if not moved then
		-- Everything that could refuse was checked above, so reaching here means the
		-- collection changed underneath us. The player has paid: say so loudly enough to
		-- be found and put right, rather than swallowing it.
		warn(
			`[CompanionsUpgrades] {player.Name} was charged {price} for {petId} level {from + 1}`
				.. ` and the level did NOT move. Refund by hand:`,
			moveReason
		)
		return false, moveReason
	end
	return true
end

-- Every rung this player could buy right now, lowest level first. What an upgrade screen
-- lists without asking about each companion in turn.
function CompanionsUpgrades.affordable(player: Player): { { petId: string, level: number, price: number } }
	local settings = settingsOrError()
	local companions = settings.companions
	local out: { { petId: string, level: number, price: number } } = {}
	for _, petId in companions.ownedIds(player) do
		local maxLevel = companions.getMaxLevel(petId)
		for level = 1, maxLevel - 1 do
			local can, _, price = CompanionsUpgrades.canUpgrade(player, petId, level)
			if can and price then
				table.insert(out, { petId = petId, level = level, price = price })
			end
		end
	end
	return out
end

return CompanionsUpgrades
