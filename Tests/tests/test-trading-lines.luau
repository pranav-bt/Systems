-- The DEFAULT line shape: `{ id, level?, quantity }`, read without a `readLine` at all.
--
-- A separate file because `Trading.start` is idempotent by design, so a suite can only
-- configure the module once -- and this one has to configure it with NO reader to prove the
-- fallback is wired, not merely present.
local rbx = require("./shim/roblox")
local Trading = require("./shim/library")("Trading", "server")

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

print("readDefaultLine derives identity from the line's own fields")
do
	local read = Trading.readDefaultLine
	check("id and level make the key", read({ id = "Knight", level = 3, quantity = 2 }).key == "Knight@3")
	check("and quantity comes through", read({ id = "Knight", level = 3, quantity = 2 }).quantity == 2)

	-- A missing level means 1, so a game with no ranks writes { id, quantity } and nothing else.
	check("a missing level means 1", read({ id = "Knight", quantity = 1 }).key == "Knight@1")
	check("which is the same key as writing it out", read({ id = "Knight", level = 1, quantity = 1 }).key == "Knight@1")

	-- Level is part of identity: the whole reason it is in the default.
	check("different levels are different things", read({ id = "K", level = 1, quantity = 1 }).key ~= read({ id = "K", level = 2, quantity = 1 }).key)

	-- An id containing the separator is still unambiguous, because the level is appended last.
	check("an id containing @ is safe", read({ id = "Knight@2", level = 3, quantity = 1 }).key == "Knight@2@3")
	check("and cannot collide with a plain one", read({ id = "Knight@2", level = 3, quantity = 1 }).key ~= read({ id = "Knight", level = 2, quantity = 1 }).key)

	check("a non-table is refused", read("nope") == nil)
	check("a missing id is refused", read({ level = 1, quantity = 1 }) == nil)
	check("an empty id is refused", read({ id = "", quantity = 1 }) == nil)
	check("a non-string id is refused", read({ id = 7, quantity = 1 }) == nil)
	check("a fractional level is refused", read({ id = "K", level = 1.5, quantity = 1 }) == nil)
	check("a zero level is refused", read({ id = "K", level = 0, quantity = 1 }) == nil)
	check("a non-numeric quantity is refused", read({ id = "K", quantity = "two" }) == nil)
end

print("a host that supplies no reader still trades")
do
	local held: { [any]: { [string]: number } } = {}
	local swapped = nil
	local action = rbx.Instance.new("RemoteEvent")
	local update = rbx.Instance.new("RemoteEvent")

	Trading.start({
		actionRemote = action,
		updateRemote = update,
		completeSeconds = 1,
		moveBurst = 50,
		moveRate = 50,
		-- NO readLine. Everything below goes through the default.
		availableOf = function(player, line)
			local key = `{line.id}@{line.level or 1}`
			return (held[player] or {})[key] or 0
		end,
		swap = function(a, aLines, b, bLines)
			swapped = { a = a, aLines = aLines, b = b, bLines = bLines }
			return true
		end,
	})

	local function move(player, kind, payload)
		action:FireServer(player, kind, payload)
	end
	local function lastOfKind(player, kind)
		local found = nil
		for _, args in update:sentTo(player) do
			if args[1] == kind then
				found = args
			end
		end
		return found
	end

	local ana = rbx.addPlayer("Ana")
	local ben = rbx.addPlayer("Ben")
	move(ana, "invite", ben.UserId)
	move(ben, "respond", true)
	held[ana] = { ["Knight@3"] = 2, ["Knight@1"] = 1 }
	held[ben] = { ["Mage@1"] = 1 }

	update:clearSent()
	move(ana, "offer", { { id = "Knight", level = 3, quantity = 2 } })
	check("a default-shaped offer lands", lastOfKind(ana, "state") ~= nil)
	check("with the line kept as sent", lastOfKind(ana, "state")[2].yours[1].id == "Knight")

	-- Ownership is checked against the DERIVED key, so a level they own one of cannot be
	-- offered twice over.
	update:clearSent()
	move(ana, "offer", { { id = "Knight", level = 1, quantity = 2 } })
	check("offering more of a level than you own is refused", lastOfKind(ana, "notice")[2] == "NotEnough")

	--[[
		THE EXPLOIT, THROUGH THE DEFAULT READER. Two lines naming the same (id, level) each
		pass on their own -- one is fewer than the two owned -- while together they are three.
		Only totalling by the derived key catches it.
	]]
	update:clearSent()
	move(ana, "offer", {
		{ id = "Knight", level = 3, quantity = 1 },
		{ id = "Knight", level = 3, quantity = 1 },
		{ id = "Knight", level = 3, quantity = 1 },
	})
	check("three lines of one each is caught by the total", lastOfKind(ana, "notice")[2] == "NotEnough")

	-- But the SAME id at different levels are different things and do not pool.
	update:clearSent()
	move(ana, "offer", {
		{ id = "Knight", level = 3, quantity = 2 },
		{ id = "Knight", level = 1, quantity = 1 },
	})
	check("the same id at two levels is two totals", lastOfKind(ana, "state") ~= nil)
	check("and both lines stand", #lastOfKind(ana, "state")[2].yours == 2)

	update:clearSent()
	move(ana, "offer", { { id = 7, quantity = 1 } })
	check("a malformed default line is refused", lastOfKind(ana, "notice")[2] == "BadLine")

	-- And it completes.
	move(ana, "offer", { { id = "Knight", level = 3, quantity = 1 } })
	move(ben, "offer", { { id = "Mage", quantity = 1 } })
	move(ana, "ready", true)
	move(ben, "ready", true)
	require("@lune/task").wait(1.3)
	check("the trade completes", swapped ~= nil)
	check("with both sides' lines, unchanged", swapped and swapped.aLines[1].level == 3 and swapped.bLines[1].id == "Mage")

	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
