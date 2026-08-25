-- The curve: costs, the multi-level loop, the cap, and the two derived numbers a UI and a
-- leaderboard read.
--
-- Pure arithmetic, so nothing here touches a player -- which is the whole reason this half is
-- a separate module from the door that writes profiles.
local Curve = require("./shim/library")("Levelling", "shared")

local passed, failed = 0, 0
local function check(name, ok, detail)
	if ok then
		passed += 1
		print(("  ok   %s"):format(name))
	else
		failed += 1
		print(("  FAIL %s -- %s"):format(name, tostring(detail)))
	end
end

-- The settings table is module state, so every block that changes it puts it back.
local function reset()
	Curve.setCurve(nil)
	Curve.settings.base = 100
	Curve.settings.perLevel = 50
	Curve.settings.squared = 25
	Curve.settings.startLevel = 1
	Curve.settings.maxLevel = nil
	Curve.settings.rewardPerLevel = 0.05
end

print("the default quadratic")
do
	reset()
	-- cost(N) = 100 + 50*(N-1) + 25*(N-1)^2
	check("level 1 costs the base", Curve.xpToNext(1) == 100, Curve.xpToNext(1))
	check("level 2 costs 175", Curve.xpToNext(2) == 175, Curve.xpToNext(2))
	check("level 10 costs 2575", Curve.xpToNext(10) == 2575, Curve.xpToNext(10))

	-- Rising, and rising faster each time: the second difference of a quadratic is constant,
	-- which is what "quadratic" has to mean if the word in the header is honest.
	local first = Curve.xpToNext(6) - Curve.xpToNext(5)
	local second = Curve.xpToNext(7) - Curve.xpToNext(6)
	check("each level costs more than the last", second > first, `{first} then {second}`)
	check("and the step itself grows by a constant", second - first == 50, second - first)
end

print("a level below the start is treated as the start")
do
	reset()
	-- A profile holding 0 or a negative level is corrupt, not a reason to hand out a free
	-- level: the cost must not fall below the first rung's.
	check("level 0 costs the base", Curve.xpToNext(0) == 100, Curve.xpToNext(0))
	check("level -5 costs the base", Curve.xpToNext(-5) == 100, Curve.xpToNext(-5))
end

print("startLevel moves the whole curve")
do
	reset()
	Curve.settings.startLevel = 0
	check("level 0 now costs the base", Curve.xpToNext(0) == 100, Curve.xpToNext(0))
	check("and level 1 costs the second rung", Curve.xpToNext(1) == 175, Curve.xpToNext(1))
	check("the reward multiplier is 1 at the start", Curve.rewardMultiplier(0) == 1, Curve.rewardMultiplier(0))
	reset()
end

print("applyExperience crosses as many levels as the grant pays for")
do
	reset()
	local level, experience, crossed, wasted = Curve.applyExperience(1, 0, 30)
	check("a small grant crosses nothing", level == 1 and crossed == 0, `{level}/{crossed}`)
	check("and banks the experience", experience == 30, experience)
	check("with nothing wasted", wasted == 0, wasted)

	level, experience, crossed = Curve.applyExperience(1, 0, 100)
	check("exactly the cost crosses one", level == 2 and crossed == 1, `{level}/{crossed}`)
	check("leaving no remainder", experience == 0, experience)

	-- 100 + 175 = 275 for two levels, so 300 buys two and leaves 25.
	level, experience, crossed = Curve.applyExperience(1, 0, 300)
	check("ONE grant can cross several", level == 3 and crossed == 2, `{level}/{crossed}`)
	check("and the remainder carries", experience == 25, experience)

	-- The count, not a flag: a host paying a reward per level owes three here.
	level, _, crossed = Curve.applyExperience(1, 0, 100 + 175 + 300)
	check("three levels report as three", level == 4 and crossed == 3, `{level}/{crossed}`)
end

print("a grant lands on top of experience already banked")
do
	reset()
	local level, experience, crossed = Curve.applyExperience(1, 90, 20)
	check("90 + 20 crosses the 100 rung", level == 2 and crossed == 1, `{level}/{crossed}`)
	check("carrying the 10 over", experience == 10, experience)
end

print("negative and nonsense inputs cannot move a player backwards")
do
	reset()
	local level, experience, crossed = Curve.applyExperience(3, 40, -500)
	check("a negative grant is ignored", level == 3 and crossed == 0, `{level}/{crossed}`)
	check("and does not eat banked experience", experience == 40, experience)

	level, experience = Curve.applyExperience(3, -20, 0)
	check("negative stored experience reads as none", experience == 0, experience)
	check("and the level is unharmed", level == 3, level)
end

print("the cap stops the curve dead")
do
	reset()
	Curve.settings.maxLevel = 3

	check("below the cap is an ordinary cost", Curve.xpToNext(2) == 175, Curve.xpToNext(2))
	check("at the cap it is unreachable", Curve.xpToNext(3) == math.huge, Curve.xpToNext(3))
	check("isMaxLevel says so", Curve.isMaxLevel(3), false)
	check("and does not say so below it", not Curve.isMaxLevel(2), true)

	-- 100 + 175 = 275 buys the two levels to the cap; the remaining 725 has nowhere to go.
	local level, experience, crossed, wasted = Curve.applyExperience(1, 0, 1000)
	check("it stops at the cap", level == 3, level)
	check("having crossed only what exists", crossed == 2, crossed)
	check("banked experience is cleared, not left filling a bar", experience == 0, experience)
	check("and the overflow is REPORTED rather than hidden", wasted == 725, wasted)

	-- The whole point of clearing it: a designer raising the cap tomorrow must not hand out
	-- levels nobody earned today.
	local capped = Curve.applyExperience(3, 0, 5000)
	check("a grant to a capped player crosses nothing", capped == 3, capped)

	reset()
	check("no cap means isMaxLevel is never true", not Curve.isMaxLevel(9999), true)
end

print("gainedBetween is honest across a level boundary")
do
	reset()
	check("within one level it is a subtraction", Curve.gainedBetween(1, 10, 1, 60) == 50, Curve.gainedBetween(1, 10, 1, 60))

	-- The case a subtraction gets exactly wrong: 90 -> level 2 with 30 banked is 40 XP
	-- earned (10 to finish the level, then 30), and reads as -60 if you subtract.
	check("across one level it counts both parts", Curve.gainedBetween(1, 90, 2, 30) == 40, Curve.gainedBetween(1, 90, 2, 30))

	-- Two levels: 10 to finish level 1, all 175 of level 2, then 5.
	check("across two it includes the level in between", Curve.gainedBetween(1, 90, 3, 5) == 190, Curve.gainedBetween(1, 90, 3, 5))

	-- A rebirth looks like this from the client's side.
	check("a reading that went backwards is not a negative gain", Curve.gainedBetween(9, 400, 1, 0) == 0, Curve.gainedBetween(9, 400, 1, 0))

	-- And so does experience dropping WITHIN a level, which an admin `set` produces: the
	-- level is unchanged, so the level-crossing guard above never sees it.
	check(
		"experience falling inside one level is not a negative gain either",
		Curve.gainedBetween(2, 50, 2, 10) == 0,
		Curve.gainedBetween(2, 50, 2, 10)
	)
end

print("totalFor is one sortable number")
do
	reset()
	check("the first level with nothing banked is 0", Curve.totalFor(1, 0) == 0, Curve.totalFor(1, 0))
	check("banked experience counts", Curve.totalFor(1, 40) == 40, Curve.totalFor(1, 40))
	check("level 3 with 25 is 300", Curve.totalFor(3, 25) == 300, Curve.totalFor(3, 25))

	-- What it is FOR: two players on the same level are ordered by their progress through it,
	-- which is the comparison a level alone cannot make.
	check("it separates two players on one level", Curve.totalFor(5, 10) < Curve.totalFor(5, 11), true)
	-- The tightest honest case: a player one XP short of level 6 must still rank below a
	-- player who has just reached it. 699 rather than 999 because level 5 costs 700 -- a
	-- reading past that is one no player can hold, and ordering it is meaningless.
	check(
		"and a player one XP short still ranks below the next level",
		Curve.totalFor(5, 699) < Curve.totalFor(6, 0),
		`{Curve.totalFor(5, 699)} vs {Curve.totalFor(6, 0)}`
	)
end

print("totalFor never returns an unserialisable number")
do
	reset()
	Curve.settings.maxLevel = 3
	-- A profile holding a level past the cap -- a shortened ladder, a rollback. Summing
	-- xpToNext over it would pull in the huge the cap returns and poison a leaderboard entry.
	local total = Curve.totalFor(10, 0)
	check("an over-cap profile still totals finitely", total == 275, total)
	reset()
end

print("setCurve replaces the whole shape")
do
	reset()
	Curve.setCurve(function(level)
		return level * 10
	end)
	check("costs come from the function", Curve.xpToNext(4) == 40, Curve.xpToNext(4))

	-- The loop still works against an arbitrary curve: 10 + 20 + 30 = 60 for three levels.
	local level, experience, crossed = Curve.applyExperience(1, 0, 65)
	check("and the crossing loop follows it", level == 4 and crossed == 3, `{level}/{crossed}`)
	check("with the remainder carried", experience == 5, experience)

	-- The cap outranks a custom curve, or a game could not have both.
	Curve.settings.maxLevel = 2
	check("the cap still overrides it", Curve.xpToNext(2) == math.huge, Curve.xpToNext(2))

	reset()
	check("nil restores the default", Curve.xpToNext(4) == 475, Curve.xpToNext(4))
end

print("a curve that returns nothing usable is refused, not looped on")
do
	reset()
	-- A cost of 0 would make applyExperience spin forever, which is the failure this assert
	-- exists to turn into a message.
	Curve.setCurve(function()
		return 0
	end)
	local ok, err = pcall(Curve.xpToNext, 1)
	check("a zero cost errors", not ok, "it was accepted")
	check("and the message names the problem", tostring(err):find("positive number") ~= nil, err)

	Curve.setCurve(function()
		return nil :: any
	end)
	check("so does a nil cost", not pcall(Curve.xpToNext, 1), "it was accepted")
	reset()
end

print("the reward multiplier")
do
	reset()
	check("is 1 at the starting level", Curve.rewardMultiplier(1) == 1, Curve.rewardMultiplier(1))
	check("and rises per level past it", math.abs(Curve.rewardMultiplier(3) - 1.1) < 1e-9, Curve.rewardMultiplier(3))
	check("a level below the start still reads 1", Curve.rewardMultiplier(0) == 1, Curve.rewardMultiplier(0))

	Curve.settings.rewardPerLevel = 0
	check("a game that wants no such multiplier gets a flat 1", Curve.rewardMultiplier(50) == 1, Curve.rewardMultiplier(50))
	reset()
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("levelling curve tests failed", 0)
end
