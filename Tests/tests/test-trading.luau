-- The trade session state machine: who may start one, what clears an agreement, and what
-- happens at the moment of the swap.
--
-- The swap itself is an injected seam, so these drive a fake inventory and assert on WHEN
-- it is called and with what -- which is where the exploitable bugs in a trade system live.
local rbx = require("./shim/roblox")
local Trading = require("./shim/library")("Trading", "server")
local Access = require("./shim/library")("Trading", "shared")
local task = require("@lune/task")

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

-- A fake collection: player -> key -> count. Lines are { key, amount }.
local held: { [any]: { [string]: number } } = {}
local swaps: { any } = {}
-- Flipped by the tests that need the swap to refuse.
local swapOk = true
local swapReason: string? = nil
-- Flipped by the hardening checks: host callbacks are allowed to throw, and every one of
-- them has to fail closed rather than let a trade through.
local readLineThrows = false
local availableThrows = false
local swapThrows = false
local gateThrows = false
-- Set by the rate-limit checks to count how many offers actually reached validation.
local countReads: (() -> ())? = nil

local action = rbx.Instance.new("RemoteEvent")
local update = rbx.Instance.new("RemoteEvent")

Trading.start({
	actionRemote = action,
	updateRemote = update,
	completeSeconds = 1, -- keep the tests quick; the token logic is the same at any length
	-- Far above anything the behaviour tests produce, so the rate limiter never throttles
	-- them incidentally -- it is exercised deliberately at the end instead. A real client
	-- sends nothing like this fast; a test suite does.
	moveBurst = 30,
	moveRate = 30,
	canTrade = function()
		if gateThrows then
			error("the gate is broken")
		end
		return nil
	end,
	readLine = function(line)
		if countReads then
			countReads()
		end
		if readLineThrows then
			error("the reader is broken")
		end
		if type(line) ~= "table" or type(line.key) ~= "string" or type(line.amount) ~= "number" then
			return nil
		end
		return { key = line.key, quantity = line.amount }
	end,
	availableOf = function(player, line)
		if availableThrows then
			error("the inventory is broken")
		end
		return (held[player] or {})[line.key] or 0
	end,
	swap = function(a, aLines, b, bLines)
		if swapThrows then
			error("the inventory exploded mid-swap")
		end
		table.insert(swaps, { a = a, aLines = aLines, b = b, bLines = bLines })
		return swapOk, swapReason
	end,
})

-- Drives a client move through the action remote, as a real client would.
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

--[[
	Makes one move and returns the notice it produced, or nil.

	CLEARS THE LOG FIRST, and that is not tidiness. `lastOfKind` reads the whole history, so
	without this an assertion can be satisfied by a message from an EARLIER step -- which is
	precisely what happened here: a stale "NotEnough" made the duplicate-line check pass even
	with the totalling removed, hiding the one exploit this module exists to prevent.
]]
local function noticeFrom(player, kind, payload)
	update:clearSent()
	move(player, kind, payload)
	local last = lastOfKind(player, "notice")
	return if last then last[2] else nil
end

local function openSession(nameA, nameB)
	update:clearSent()
	local a = rbx.addPlayer(nameA)
	local b = rbx.addPlayer(nameB)
	move(a, "invite", b.UserId)
	move(b, "respond", true)
	return a, b
end

print("invites: who may ask, and who may be asked")
do
	update:clearSent()
	local ana = rbx.addPlayer("Ana")
	local ben = rbx.addPlayer("Ben")

	check("inviting yourself is refused", noticeFrom(ana, "invite", ana.UserId) == "SelfInvite")
	check("inviting somebody not here is refused", noticeFrom(ana, "invite", 999999) == "NotFound")

	move(ana, "invite", ben.UserId)
	check("a real invite reaches the target", lastOfKind(ben, "invited") ~= nil)
	check("naming the sender", lastOfKind(ben, "invited")[2] == ana)

	-- The cooldown is per sender, so the button cannot be used to spam toasts.
	check("a second invite too soon is refused", noticeFrom(ana, "invite", ben.UserId) == "Cooldown")

	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("a published block stops a trade before it starts")
do
	update:clearSent()
	local ana = rbx.addPlayer("Ana")
	local ben = rbx.addPlayer("Ben")

	Access.set(ana, "InMatch")
	check("Access reports the reason", Access.reasonFor(ana) == "InMatch")
	check("and canTrade is false", not Access.canTrade(ana))
	-- The sender's OWN block is reported first: it names the thing they can act on.
	check("their own block is what they are told about", noticeFrom(ana, "invite", ben.UserId) == "Blocked")

	Access.set(ana, nil)
	check("clearing lifts it", Access.canTrade(ana))
	Access.set(ben, "InMatch")
	update:clearSent()
	move(ana, "invite", ben.UserId)
	local notice = lastOfKind(ana, "notice")
	check("a blocked partner is a different refusal", notice[2] == "PartnerBlocked")
	check("and names who", notice[3] == ben)

	Access.set(ben, nil)
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("offers are validated per line and TOTALLED by key")
do
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 2 }

	move(ana, "offer", { { key = "Knight", amount = 2 } })
	local state = lastOfKind(ana, "state")[2]
	check("a valid offer lands", #state.yours == 1, #state.yours)
	check("and the partner sees it", lastOfKind(ben, "state")[2].theirs[1].amount == 2)

	check(
		"offering more than you have is refused",
		noticeFrom(ana, "offer", { { key = "Knight", amount = 3 } }) == "NotEnough"
	)

	--[[
		THE ONE THAT MATTERS. Two lines naming the same thing each pass a per-line check --
		1 <= 2 and 1 <= 2 -- while together they are three of something there are two of.
		Only totalling by key before comparing catches it.
	]]
	local duplicated = noticeFrom(ana, "offer", {
		{ key = "Knight", amount = 1 },
		{ key = "Knight", amount = 1 },
		{ key = "Knight", amount = 1 },
	})
	check("but three lines of one each is caught by the total", duplicated == "NotEnough", duplicated)

	move(ana, "offer", { { key = "Knight", amount = 1 }, { key = "Knight", amount = 1 } })
	check("two lines totalling what you have is fine", lastOfKind(ana, "state")[2].yours ~= nil)
	check("and both lines are kept, not folded", #lastOfKind(ana, "state")[2].yours == 2)

	check("a malformed line is refused", noticeFrom(ana, "offer", { "not a line" }) == "BadLine")

	local many = {}
	for _ = 1, 20 do
		table.insert(many, { key = "Knight", amount = 1 })
	end
	check("too many lines is refused", noticeFrom(ana, "offer", many) == "TooManyLines")

	move(ana, "cancel")
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("changing an offer clears BOTH agreements -- the oldest trick in the genre")
do
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Legendary = 1, Common = 5 }
	held[ben] = { Gold = 1 }

	move(ana, "offer", { { key = "Legendary", amount = 1 } })
	move(ben, "offer", { { key = "Gold", amount = 1 } })
	move(ben, "ready", true)
	check("the partner has agreed", lastOfKind(ana, "state")[2].theyReady == true)

	-- The swap: ana replaces her legendary with a common AFTER ben agreed. If his ready
	-- flag survived that, his earlier consent would carry a trade he never saw.
	move(ana, "offer", { { key = "Common", amount = 1 } })
	local state = lastOfKind(ben, "state")[2]
	check("the switch cleared the victim's agreement", state.youReady == false)
	check("and the switcher's too", state.theyReady == false)
	check("no swap happened", #swaps == 0, #swaps)

	move(ana, "cancel")
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("both ready starts a countdown; un-readying stops it")
do
	swaps = {}
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 1 }
	held[ben] = { Mage = 1 }
	move(ana, "offer", { { key = "Knight", amount = 1 } })
	move(ben, "offer", { { key = "Mage", amount = 1 } })

	move(ana, "ready", true)
	check("one side alone starts nothing", lastOfKind(ana, "state")[2].completesIn == nil)
	move(ben, "ready", true)
	check("both sides start the count", lastOfKind(ana, "state")[2].completesIn ~= nil)

	-- Un-readying during the count is a real out: it clears the agreement the count runs on.
	move(ana, "ready", false)
	check("un-readying stops the count", lastOfKind(ana, "state")[2].completesIn == nil)
	task.wait(1.2)
	check("and nothing was swapped", #swaps == 0, #swaps)

	-- Ready again, and let it run.
	move(ana, "ready", true)
	task.wait(1.3)
	check("a count left alone commits", #swaps == 1, #swaps)
	check("with both sides' lines", swaps[1].aLines[1].key == "Knight" and swaps[1].bLines[1].key == "Mage")
	check("and the session closed as complete", lastOfKind(ana, "closed")[2] == "Complete")
	check("so neither is trading any more", not Trading.isTrading(ana) and not Trading.isTrading(ben))

	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("ready -> not ready -> ready inside the count cannot double-commit")
do
	swaps = {}
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 1 }
	held[ben] = { Mage = 1 }
	move(ana, "offer", { { key = "Knight", amount = 1 } })
	move(ben, "offer", { { key = "Mage", amount = 1 } })
	move(ana, "ready", true)
	move(ben, "ready", true)

	--[[
		The token's whole reason for existing. The first count is still sleeping when the
		second starts; a boolean would let it wake and commit against an agreement that had
		been taken back and given again, swapping twice.
	]]
	move(ana, "ready", false)
	move(ana, "ready", true)
	task.wait(1.4)
	check("exactly one swap happened", #swaps == 1, #swaps)

	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("a refused swap keeps the session open rather than retrying")
do
	swaps = {}
	swapOk, swapReason = false, "a copy was merged away"
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 1 }
	held[ben] = { Mage = 1 }
	move(ana, "offer", { { key = "Knight", amount = 1 } })
	move(ben, "offer", { { key = "Mage", amount = 1 } })
	move(ana, "ready", true)
	move(ben, "ready", true)
	update:clearSent()
	task.wait(1.3)

	check("the swap was attempted", #swaps == 1, #swaps)
	check("both were told it failed", lastOfKind(ana, "notice")[2] == "Failed" and lastOfKind(ben, "notice")[2] == "Failed")
	-- Open, so they can see what changed and decide again -- rather than retried against a
	-- table neither of them has looked at since.
	check("the session is still open", Trading.isTrading(ana))
	local state = lastOfKind(ana, "state")[2]
	check("with both agreements dropped", state.youReady == false and state.theyReady == false)

	-- And it does not retry on its own.
	task.wait(1.2)
	check("no second attempt", #swaps == 1, #swaps)

	swapOk, swapReason = true, nil
	move(ana, "cancel")
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("a session ends when it has to")
do
	-- Cancel, from either side.
	local ana, ben = openSession("Ana", "Ben")
	move(ben, "cancel")
	check("cancelling closes it for both", not Trading.isTrading(ana) and not Trading.isTrading(ben))
	check("and says why", lastOfKind(ana, "closed")[2] == "Cancelled")
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)

	-- A block landing mid-trade, from a system that knows nothing about trading.
	local cara, dan = openSession("Cara", "Dan")
	check("they are trading", Trading.isTrading(cara))
	check("and know about each other", Trading.partnerOf(cara) == dan)
	Access.set(cara, "InMatch")
	check("a block mid-trade ends it", not Trading.isTrading(cara) and not Trading.isTrading(dan))
	check("as unavailable", lastOfKind(dan, "closed")[2] == "Unavailable")
	Access.set(cara, nil)
	rbx.removePlayer(cara)
	rbx.removePlayer(dan)

	-- A player leaving.
	local eve, fin = openSession("Eve", "Fin")
	rbx.removePlayer(eve)
	check("a leaver ends it for the other side", not Trading.isTrading(fin))
	check("who is told they left", lastOfKind(fin, "closed")[2] == "PartnerLeft")
	rbx.removePlayer(fin)
end

print("moves outside a session do nothing")
do
	update:clearSent()
	local ana = rbx.addPlayer("Ana")
	check("offering with no session is ignored", pcall(move, ana, "offer", { { key = "Knight", amount = 1 } }))
	check("readying with no session is ignored", pcall(move, ana, "ready", true))
	check("cancelling with no session is ignored", pcall(move, ana, "cancel"))
	check("responding to no invite says so", noticeFrom(ana, "respond", true) == "NoInvite")
	-- An unrecognised move is dropped without comment: a client sending one is a stale
	-- build or a crafted packet, and neither is owed an explanation.
	update:clearSent()
	check("an unknown move is dropped", pcall(move, ana, "explode", {}))
	check("silently", #update:sentTo(ana) == 0, #update:sentTo(ana))
	rbx.removePlayer(ana)
end


print("hardening: what a crafted payload or a broken host cannot do")
do
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 99 }

	--[[
		THE CAP AND THE LOOP MUST COUNT THE SAME THING.

		`#lines` measures the array part; generalized iteration walks every key. A payload of
		one array entry plus fifty string-keyed ones has a length of 1, so it passes a cap of
		nine while carrying fifty-one lines. Measured before the fix: fifty-one lines
		processed against a cap of two.
	]]
	local crafted = { { key = "Knight", amount = 1 } }
	for index = 1, 50 do
		crafted[`extra{index}`] = { key = "Knight", amount = 1 }
	end
	update:clearSent()
	move(ana, "offer", crafted)
	local state = lastOfKind(ana, "state")
	check("a dictionary payload is not refused outright", state ~= nil)
	check("but only its array part is read", state and #state[2].yours == 1, state and #state[2].yours)

	move(ana, "cancel")
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("a host callback that throws fails closed")
do
	-- readLine throwing must refuse the line, not let it through unvalidated.
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 5 }
	readLineThrows = true
	update:clearSent()
	move(ana, "offer", { { key = "Knight", amount = 1 } })
	check("a throwing readLine refuses the offer", lastOfKind(ana, "notice")[2] == "BadLine")
	-- A refused offer must not change the table, and the table not changing means nobody is
	-- told anything: no state was broadcast at all.
	check("and the table was not touched", lastOfKind(ben, "state") == nil)
	readLineThrows = false

	-- availableOf throwing means "we do not know how many you have", which is not "enough".
	availableThrows = true
	check("a throwing availableOf refuses too", noticeFrom(ana, "offer", { { key = "Knight", amount = 1 } }) == "NotEnough")
	availableThrows = false

	check("and with both working the same offer lands", noticeFrom(ana, "offer", { { key = "Knight", amount = 1 } }) == nil)
	move(ana, "cancel")
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("a throwing swap does not wedge the session")
do
	swaps = {}
	swapThrows = true
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 1 }
	held[ben] = { Mage = 1 }
	move(ana, "offer", { { key = "Knight", amount = 1 } })
	move(ben, "offer", { { key = "Mage", amount = 1 } })
	move(ana, "ready", true)
	move(ben, "ready", true)
	update:clearSent()
	task.wait(1.3)

	-- Unguarded, the throw would kill the countdown coroutine and leave a session showing a
	-- count that never resolves and agreements that never clear.
	check("both sides are told it failed", lastOfKind(ana, "notice")[2] == "Failed")
	local state = lastOfKind(ana, "state")[2]
	check("the countdown is gone", state.completesIn == nil, state.completesIn)
	check("and the agreements were dropped", state.youReady == false and state.theyReady == false)
	check("the session is still usable", Trading.isTrading(ana))

	-- And it recovers: with the host working, the same session completes.
	swapThrows = false
	move(ana, "ready", true)
	move(ben, "ready", true)
	task.wait(1.3)
	check("a retry after the host recovers completes", #swaps == 1, #swaps)

	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("a throwing canTrade refuses rather than allows")
do
	update:clearSent()
	local ana = rbx.addPlayer("Ana")
	local ben = rbx.addPlayer("Ben")
	gateThrows = true
	check("the invite is refused", noticeFrom(ana, "invite", ben.UserId) == "Blocked")
	gateThrows = false
	check("and allowed once the gate works", noticeFrom(ana, "invite", ben.UserId) == nil)
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("holding the ready button does not restart the countdown")
do
	swaps = {}
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 1 }
	held[ben] = { Mage = 1 }
	move(ana, "offer", { { key = "Knight", amount = 1 } })
	move(ben, "offer", { { key = "Mage", amount = 1 } })
	move(ana, "ready", true)
	move(ben, "ready", true)

	--[[
		SPREAD OVER TIME, and that is what makes this assert anything.

		Pressing repeatedly in the same frame proves nothing: every restarted count would
		still expire together and one swap would land either way. Pressing again PARTWAY
		THROUGH is the real case -- a held button, or a nervous player -- and a repeat that
		restarts the count pushes completion past the window entirely.

		completeSeconds is 1 here, so a press at 0.6s would move completion to 1.6s.
	]]
	task.wait(0.6)
	move(ana, "ready", true)
	move(ben, "ready", true)
	task.wait(0.7)
	check("the original count completed on time", #swaps == 1, #swaps)

	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end


print("the action remote is rate limited")
do
	-- A session so the moves are real work rather than early returns.
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 99 }

	--[[
		Burst is 30 here. Firing 45 offers in one frame means no measurable time passes, so
		the bucket cannot refill: exactly the burst should be read and the rest dropped.
	]]
	local reads = 0
	countReads = function()
		reads += 1
	end
	update:clearSent()
	for index = 1, 45 do
		move(ana, "offer", { { key = "Knight", amount = (index % 5) + 1 } })
	end
	check("the burst was accepted", reads > 0, reads)
	check("but the flood was not", reads <= 30, reads)

	-- Dropped in SILENCE: answering each unwanted packet with a packet is the amplification
	-- the limiter exists to prevent.
	local answers = 0
	for _, args in update:sentTo(ana) do
		if args[1] == "notice" then
			answers += 1
		end
	end
	check("and nothing was sent back for the dropped ones", answers == 0, answers)

	-- Refills over time, so a throttled player is not locked out.
	reads = 0
	task.wait(0.5)
	move(ana, "offer", { { key = "Knight", amount = 1 } })
	check("a move lands again once tokens refill", reads == 1, reads)

	countReads = nil
	move(ana, "cancel")
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("one player's flood does not throttle another")
do
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 99 }
	held[ben] = { Mage = 99 }

	for _ = 1, 45 do
		move(ana, "offer", { { key = "Knight", amount = 1 } })
	end
	-- Ben has spent nothing, so his move must land: the bucket is per player, and a shared
	-- one would let anybody deny the trade to everybody.
	update:clearSent()
	move(ben, "offer", { { key = "Mage", amount = 2 } })
	local state = lastOfKind(ben, "state")
	check("the other side is unaffected", state ~= nil)
	check("and their offer landed", state and state[2].yours[1].amount == 2)

	move(ben, "cancel")
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end

print("start is idempotent")
do
	-- A second start would connect the remote handler again, so every move would be handled
	-- twice -- which for `offer` means two broadcasts and for `ready` two countdowns.
	Trading.start({
		actionRemote = action,
		updateRemote = update,
		readLine = function(line)
			return { key = line.key, amount = line.amount }
		end,
		availableOf = function()
			return 99
		end,
		swap = function()
			return true
		end,
	})
	local ana, ben = openSession("Ana", "Ben")
	held[ana] = { Knight = 2 }
	update:clearSent()
	move(ana, "offer", { { key = "Knight", amount = 1 } })
	local states = 0
	for _, args in update:sentTo(ana) do
		if args[1] == "state" then
			states += 1
		end
	end
	check("one move still produces one state push", states == 1, states)
	move(ana, "cancel")
	rbx.removePlayer(ana)
	rbx.removePlayer(ben)
end


print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	process.exit(1)
end
