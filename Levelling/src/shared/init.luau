--!strict

-- The curve: how much XP a level costs, and what happens when a grant crosses one.
--
-- PURE, AND SHARED BY BOTH REALMS ON PURPOSE. The server owns every grant, but the client
-- has to draw a progress bar, and a bar needs to know what the current level is worth. Two
-- copies of this arithmetic would be two curves that agree until someone edits one -- and
-- the symptom of that is a bar that fills to 90% and then levels up, which reads to a
-- player as the server cheating them.
--
-- NOTHING HERE TOUCHES A PLAYER OR A PROFILE. It is (level, experience, amount) in and
-- (level, experience) out, which is what makes the whole rule testable without a game.
--
-- THE DEFAULT CURVE IS QUADRATIC:
--
--   cost(N) = base + perLevel * (N - 1) + squared * (N - 1)^2
--
-- with base 100, perLevel 50, squared 25 -- level 1->2 costs 100, level 10->11 costs 2,575.
-- A quadratic rather than an exponential because the numbers stay sayable: a player can
-- read "2,575 XP" off a bar, where an exponential reaches figures that mean nothing to
-- anyone by level 30. `setCurve` replaces the whole function for a game that disagrees.

local Curve = {}

export type Settings = {
	-- The default quadratic's three terms. Ignored entirely once `setCurve` is used.
	base: number,
	perLevel: number,
	squared: number,

	--[[
		The first level, which is what a fresh profile starts at and what a reset returns to.

		1 rather than 0, because "level 1" is what a player is told they are. A game that
		counts from 0 sets this and every function here follows -- the curve is asked about
		levels relative to `startLevel`, never relative to a hardcoded 1.
	]]
	startLevel: number,

	--[[
		The last level, or nil for no ceiling.

		AT THE CAP, EXPERIENCE STOPS ACCUMULATING rather than piling up invisibly. A capped
		player whose XP kept counting would level up the instant a designer raised the cap,
		by an amount nobody can predict -- and would meanwhile watch a bar that fills forever
		and never resolves. `applyExperience` reports the overflow, so a host that wants to
		turn leftover XP into something else still can.
	]]
	maxLevel: number?,

	--[[
		What a level is WORTH, as a plain multiplier -- 1 at `startLevel`, rising by this much
		for each level past it.

		THE LIBRARY DOES NOT APPLY IT TO ANYTHING. It is a number a host reads and multiplies
		into whatever levelling is meant to make better: pickup values, damage, income, drop
		rates. Shipping the list of what-gets-scaled would be shipping a game's stat table,
		and the game this came from scaled six combat stats by name -- which is exactly the
		part that does not travel.
	]]
	rewardPerLevel: number,
}

local settings: Settings = {
	base = 100,
	perLevel = 50,
	squared = 25,
	startLevel = 1,
	maxLevel = nil,
	rewardPerLevel = 0.05,
}

Curve.settings = settings

local custom: ((level: number) -> number)? = nil

--[[
	Replaces the curve wholesale.

	For a game whose costs come from a designer-authored table, or any shape that is not a
	polynomial. It must return a POSITIVE number for every level it is asked about: a cost of
	0 would make `applyExperience` loop forever, so it is asserted on rather than trusted.

	nil restores the default quadratic.
]]
function Curve.setCurve(fn: ((level: number) -> number)?)
	custom = fn
end

-- Whether this level is the last one. Always false when there is no cap.
function Curve.isMaxLevel(level: number): boolean
	local cap = settings.maxLevel
	return cap ~= nil and level >= cap
end

--[[
	What it costs to go from `level` to the next one.

	`math.huge` at the cap, which is what makes every comparison downstream do the right
	thing with no special case: nothing is ever >= huge, so a capped player never crosses,
	and a bar drawing `experience / required` sits at 0 rather than dividing by nothing.
]]
function Curve.xpToNext(level: number): number
	if Curve.isMaxLevel(level) then
		return math.huge
	end
	if custom then
		local cost = custom(level)
		assert(
			type(cost) == "number" and cost > 0,
			`Levelling: the curve returned {tostring(cost)} for level {level}; it must be a positive number`
		)
		return cost
	end
	local n = math.max(0, level - settings.startLevel)
	return settings.base + settings.perLevel * n + settings.squared * n * n
end

-- The multiplier held at `level`. See `rewardPerLevel` for why nothing here applies it.
function Curve.rewardMultiplier(level: number): number
	return 1 + settings.rewardPerLevel * math.max(0, level - settings.startLevel)
end

--[[
	Adds XP to a (level, experience) pair. Returns the new pair, how many levels it crossed,
	and how much XP was thrown away at the cap.

	A LOOP RATHER THAN A BRANCH, because one grant can cross more than one level: an early
	player is cheap to level, and a host paying a bonus or ticking fast can hand over several
	levels at once. A branch would swallow the rest.

	LEVELS CROSSED IS A COUNT, not a flag. The flag is what the game this came from returned,
	and it was enough for a "you levelled up" toast but not for the thing every game does
	next -- pay a reward per level -- which needs to know it owes three.

	Pure: it reads the numbers it is given and returns more numbers. Nothing is written to a
	profile, and the caller decides whether the result is worth storing.
]]
function Curve.applyExperience(level: number, experience: number, amount: number): (number, number, number, number)
	local nextLevel = math.max(settings.startLevel, math.floor(level))
	local nextExperience = math.max(0, experience) + math.max(0, amount)
	local crossed = 0

	local required = Curve.xpToNext(nextLevel)
	while nextExperience >= required do
		nextExperience -= required
		nextLevel += 1
		crossed += 1
		required = Curve.xpToNext(nextLevel)
	end

	-- At the cap `required` is huge, so the loop above has already stopped. Whatever sits in
	-- `experience` was earned past the ceiling: reported, not banked.
	local wasted = 0
	if Curve.isMaxLevel(nextLevel) then
		wasted = nextExperience
		nextExperience = 0
	end

	return nextLevel, nextExperience, crossed, wasted
end

--[[
	XP between two readings, across however many levels lie between them.

	A PLAIN SUBTRACTION IS WRONG EXACTLY WHEN THE PLAYER EARNED THE MOST. Experience resets
	on every level, so the two readings either side of a level-up look like a loss: the
	client that draws "+250 XP" would draw "-80" on the one grant worth celebrating.

	0 for a reading that went backwards, which is what a rebirth or an admin reset looks like
	from here -- not a gain, and not something to spell out as a negative one.
]]
function Curve.gainedBetween(fromLevel: number, fromExperience: number, toLevel: number, toExperience: number): number
	if toLevel == fromLevel then
		return math.max(0, toExperience - fromExperience)
	end
	if toLevel < fromLevel then
		return 0
	end
	local gained = Curve.xpToNext(fromLevel) - fromExperience
	for level = fromLevel + 1, toLevel - 1 do
		gained += Curve.xpToNext(level)
	end
	return math.max(0, gained + toExperience)
end

--[[
	Total XP earned since `startLevel` to reach this exact reading.

	WHAT A LEADERBOARD SORTS ON. Level alone cannot order two players -- one a single grant
	short of levelling ranks equal with one who just arrived -- and (level, experience) is
	two keys where an OrderedDataStore takes one.

	A caller storing this should clamp it: past the cap the sum includes no infinities (the
	loop stops below the cap), but a very high uncapped level can exceed what an
	OrderedDataStore accepts, which is a 64-bit integer.
]]
function Curve.totalFor(level: number, experience: number): number
	-- Clamped to the cap before summing. Past it `xpToNext` answers math.huge, and one of
	-- those in the sum turns a leaderboard entry into a value that will not serialise --
	-- from a profile that is merely out of date with a shortened ladder.
	local top = math.floor(level)
	local cap = settings.maxLevel
	if cap then
		top = math.min(top, cap)
	end

	local total = math.max(0, experience)
	for at = settings.startLevel, top - 1 do
		total += Curve.xpToNext(at)
	end
	return total
end

return Curve
