-- TimeSync: round-trip latency measurement, and who gets to decide what it says.
--
-- The number this produces is consumed by LagCompensation as the amount it rewinds the world
-- before validating a hit, which makes "can a client influence it" the question that matters
-- most here.
--
-- Every honest measurement below is REAL: the test sleeps for the round trip it is claiming,
-- and echoes a value the server actually sent. There is no way to fabricate one any more, and
-- proving that is half the point of this file.
local rbx = require("./shim/roblox")
local Server = require("./shim/library")("TimeSync", "server")
local task = require("@lune/task")
local process = require("@lune/process")

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

local ping = rbx.Instance.new("UnreliableRemoteEvent")
ping.Name = "Ping"
local pingBack = rbx.Instance.new("UnreliableRemoteEvent")
pingBack.Name = "PingBack"

-- A fast ping so a test never waits long for one. The module pings immediately on start and
-- then on the interval.
local PING_INTERVAL = 0.02
Server.start({ pingRemote = ping, pingBackRemote = pingBack, pingInterval = PING_INTERVAL })

-- Every value the server has sent this player, oldest first.
local function pingsTo(player)
	local out = {}
	for _, entry in ping._sent do
		if entry.player == player then
			table.insert(out, entry.args[1])
		end
	end
	return out
end

local function newestPingTo(player)
	local all = pingsTo(player)
	return all[#all]
end

-- Play the client: send something back up the wire.
local function echo(player, value)
	pingBack:FireServer(player, value)
end

--[[
	An honest round trip of about `seconds`.

	Takes a ping the server really sent, waits, and echoes it. The measured value lands in
	[seconds, seconds + PING_INTERVAL], because the ping was sent up to one interval before it
	was picked up -- so assertions carry that tolerance rather than pretending to millisecond
	precision.
]]
local function measure(player, seconds)
	local value = newestPingTo(player)
	task.wait(seconds)
	echo(player, value)
	return value
end

local function joinAndPing(name)
	local player = rbx.addPlayer(name)
	-- Long enough for the ping loop to come round for the newly added player.
	task.wait(PING_INTERVAL * 3)
	return player
end

print("an unmeasured player reads the default")
do
	local ana = rbx.addPlayer("Ana")
	task.wait()
	-- 0.08 assumed until the first sample lands, rather than 0 -- a zero would tell
	-- LagCompensation to rewind not at all, which is worse than a guess.
	check("before any sample, the default", math.abs(Server.getLatency(ana) - 0.08) < 1e-9, Server.getLatency(ana))

	local stranger = { Name = "Nobody" }
	check("an unknown player reads the default too", math.abs(Server.getLatency(stranger :: any) - 0.08) < 1e-9)
	rbx.removePlayer(ana)
end

print("an honest round trip is measured")
do
	local ana = joinAndPing("Ana")
	check("the loop pinged them", newestPingTo(ana) ~= nil, "no ping went out")

	measure(ana, 0.05)
	local measured = Server.getLatency(ana)
	check("the sample replaced the default", measured ~= 0.08, measured)
	check("and reflects the real elapsed time", measured >= 0.045 and measured <= 0.05 + PING_INTERVAL + 0.04, measured)

	rbx.removePlayer(ana)
end

print("nonsense round trips are discarded")
do
	local ana = joinAndPing("Ana")
	local before = Server.getLatency(ana)

	-- Values the server never sent, whatever they imply.
	echo(ana, os.clock() + 5)
	check("a future clock is ignored", Server.getLatency(ana) == before, Server.getLatency(ana))

	echo(ana, os.clock() - 3)
	check("an absurd rtt is ignored", Server.getLatency(ana) == before, Server.getLatency(ana))

	echo(ana, "0.02" :: any)
	check("a non-number is ignored", Server.getLatency(ana) == before, Server.getLatency(ana))

	echo(ana, nil :: any)
	check("nil is ignored", Server.getLatency(ana) == before, Server.getLatency(ana))

	rbx.removePlayer(ana)
end

print("the average rolls over the last four samples")
do
	local ana = joinAndPing("Ana")

	for _ = 1, 4 do
		measure(ana, 0.04)
	end
	local fast = Server.getLatency(ana)
	check("four short round trips average short", fast < 0.1, fast)

	--[[
		Four slower ones must push the faster samples entirely out of the window. An average
		that kept accumulating would still be reading half the old value here.
	]]
	for _ = 1, 4 do
		measure(ana, 0.14)
	end
	local slow = Server.getLatency(ana)
	check("four slower ones displace them", slow > fast + 0.04, `{fast} -> {slow}`)
	check("landing near the newer round trip", slow >= 0.13, slow)

	rbx.removePlayer(ana)
end

print("a player who leaves is forgotten")
do
	local ana = joinAndPing("Ana")
	measure(ana, 0.05)
	check("measured while present", Server.getLatency(ana) ~= 0.08, Server.getLatency(ana))

	rbx.removePlayer(ana)
	task.wait()
	check("and back to the default once gone", math.abs(Server.getLatency(ana) - 0.08) < 1e-9, Server.getLatency(ana))

	echo(ana, os.clock() - 0.05)
	check("a late echo does not recreate them", math.abs(Server.getLatency(ana) - 0.08) < 1e-9, Server.getLatency(ana))
end

print("a client CANNOT name its own latency")
do
	--[[
		THE FIX. An echo used to be accepted on its own word: any number arriving on PingBack
		was treated as `os.clock() - it`, so a client that had never been pinged could report
		whatever round trip it liked, bounded only by MAX_SANE_LATENCY.

		Because LagCompensation rewinds by this number, a client claiming high latency was
		asking the server to judge its shots against where targets were further in the past.
		The clamps bounded the damage; they did not stop the client owning the number.

		An echo now has to carry a value this server actually sent, and that value is consumed
		when it is used.
	]]
	local liar = rbx.addPlayer("Liar")
	task.wait()

	--[[
		Values the server never sent. Whether a real ping happens to have gone out to this
		player by now does not matter and is deliberately not asserted -- the ping loop runs on
		real time, so that would be a race. What matters is that a value the server did not
		choose is refused either way.
	]]
	for _ = 1, 8 do
		echo(liar, os.clock() - 0.95)
	end
	check("a forged high latency is refused", math.abs(Server.getLatency(liar) - 0.08) < 1e-9, Server.getLatency(liar))

	task.wait(PING_INTERVAL * 3)
	check("even once they have genuinely been pinged", newestPingTo(liar) ~= nil)
	for _ = 1, 8 do
		echo(liar, os.clock() - 0.95)
	end
	check("the forgery is still refused", math.abs(Server.getLatency(liar) - 0.08) < 1e-9, Server.getLatency(liar))

	-- The near-zero direction, which helps a different kind of cheat.
	for _ = 1, 8 do
		echo(liar, os.clock())
	end
	check("so is a forged near-zero one", math.abs(Server.getLatency(liar) - 0.08) < 1e-9, Server.getLatency(liar))

	-- The honest path still works for the same player, so this is not merely "nothing is ever
	-- accepted".
	measure(liar, 0.05)
	check("but an honest echo from the same player IS accepted", Server.getLatency(liar) ~= 0.08, Server.getLatency(liar))

	rbx.removePlayer(liar)
end

print("one ping buys exactly one sample")
do
	--[[
		Consuming the outstanding value is what bounds spam. The window is four samples, so
		before this an honest measurement could be erased by four messages in a single frame.
	]]
	local ana = joinAndPing("Ana")
	local value = measure(ana, 0.1)
	local afterFirst = Server.getLatency(ana)
	check("the honest echo is measured", afterFirst ~= 0.08, afterFirst)

	for _ = 1, 7 do
		echo(ana, value)
	end
	check("replaying that exact value changes nothing", Server.getLatency(ana) == afterFirst, Server.getLatency(ana))

	rbx.removePlayer(ana)
end

print("a slow echo still counts")
do
	--[[
		The reason outstanding pings are a LIST rather than one slot. An echo can legitimately
		arrive after several later pings have gone out, and a single-slot design would drop it
		-- leaving anyone slower than the ping interval permanently on the assumed default,
		which is precisely the group whose real latency matters most.
	]]
	local ben = joinAndPing("Ben")
	local old = newestPingTo(ben)

	-- Let several more pings go out before answering the old one.
	task.wait(PING_INTERVAL * 6)
	echo(ben, old)
	check("an echo answering an older ping is accepted", Server.getLatency(ben) ~= 0.08, Server.getLatency(ben))

	rbx.removePlayer(ben)
end

print("stop() ends the loop and forgets everyone")
do
	local ana = joinAndPing("Ana")
	measure(ana, 0.03)
	check("measured before stopping", Server.getLatency(ana) ~= 0.08, Server.getLatency(ana))

	Server.stop()
	check("measurements are cleared", math.abs(Server.getLatency(ana) - 0.08) < 1e-9, Server.getLatency(ana))

	-- The loop had no way out before: `while true do task.wait() end` on a spawned thread ran
	-- for the life of the server, so this suite could not finish without forcing an exit.
	local before = #pingsTo(ana)
	task.wait(PING_INTERVAL * 5)
	check("and no further pings go out", #pingsTo(ana) == before, `{before} -> {#pingsTo(ana)}`)

	rbx.removePlayer(ana)
end

print(("%d passed, %d failed"):format(passed, failed))
process.exit(if failed > 0 then 1 else 0)
