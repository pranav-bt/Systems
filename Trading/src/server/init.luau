--!strict

-- Two players agreeing to swap things.
--
-- THE SHAPE. One asks; the other accepts; both fill an offer; both press ready; it happens.
-- Every one of those is a server-held fact, and the clients are told what the server
-- believes after each move -- there is no state on a client that the server did not push,
-- because the alternative is two screens that quietly disagree about what is being traded.
--
--   invite   -> the target gets an invite and can accept or decline
--   respond  -> accept opens a session for both, decline tells the inviter
--   offer    -> replaces your side of the table, and CLEARS BOTH READY FLAGS
--   ready    -> agrees to what is on the table right now; both agreeing starts a countdown
--   cancel   -> either side, at any time, with no penalty
--
-- READY IS ABOUT A SPECIFIC TABLE, WHICH IS WHY ANY OFFER CHANGE CLEARS IT. Otherwise the
-- oldest trick in the genre works: wait for the other player to ready up, swap your
-- legendary for a common, and let their earlier agreement carry the trade through. A ready
-- flag that outlives the offer it agreed to is not consent to anything.
--
-- NOTHING IS COMMITTED HERE. The host's `swap` does the moving, in ONE call, because this
-- module is a conversation and not an owner. One call and not remove-then-give: two calls
-- open a window where an item exists twice or not at all, and that window is where trade
-- duplication bugs live.
--
-- AND IT IS RE-VALIDATED AT THE MOMENT OF THE SWAP, not trusted from when it was offered.
-- Seconds pass between an offer and a commit, and anything can happen in them -- an item
-- merged away, spent, traded in another window. `swap` is handed the lines and is expected
-- to check them again; this module never assumes its earlier validation still holds.
--
-- SESSIONS ARE IN-MEMORY AND PER-SERVER. A trade cannot survive a rejoin and should not:
-- nothing is held in escrow, so an abandoned session costs nobody anything.
--
-- NO COPY LIVES HERE. Every refusal is a reason KEY; the host words it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Access = require(script.Parent.shared)

local Trading = {}

local CONTAINER_NAME = "TradingRemotes"
local ACTION_REMOTE_NAME = "Action" -- client -> server, one move
local UPDATE_REMOTE_NAME = "Update" -- server -> client, state and notices

-- Every refusal this module can produce. Exported so a host can map them exhaustively and
-- fail its own build when a new one appears.
export type Reason =
	"Busy"
	| "Blocked"
	| "PartnerBlocked"
	| "SelfInvite"
	| "NotFound"
	| "Cooldown"
	| "NoInvite"
	| "TooManyLines"
	| "BadLine"
	| "NotEnough"
	| "Declined"
	| "Cancelled"
	| "PartnerLeft"
	| "Unavailable"
	| "Failed"
	| "Complete"

--[[
	One line on the table -- a STACK, not an item. Opaque to this module, which totals lines
	and compares them against what a player has without looking inside.
]]
export type Line = any

--[[
	The shape a line has when no `readLine` is supplied, which should cover most games.

	`level` is optional and means 1. It is in the DEFAULT rather than left to a custom reader
	because a collectible with a rank is the ordinary case in this genre -- a level 1 and a
	level 3 of the same thing are different things that stack, price and merge apart -- and a
	default that could not express that would be a default nobody used.
]]
export type DefaultLine = {
	id: string,
	level: number?,
	quantity: number,
}

export type Config = {
	--[[
		Reads one offered line, or returns nil to reject it outright.

		The KEY is what makes two lines the same thing. Lines sharing a key are totalled
		before being compared against what the player has, which is what stops naming the
		same stack twice getting past a per-line check that both halves would individually
		pass.

		OPTIONAL: omit it and lines are read as `DefaultLine`. Supply it when identity is not
		`id` plus `level` -- a durability band, an enchant, a foil flag.

		THE KEY IS DERIVED HERE, ON THE SERVER, AND NEVER SENT. That is the whole point of a
		reader rather than a `key` field on the line: a client cannot name an identity that
		disagrees with what it is actually offering, because it never names one at all.
	]]
	readLine: ((line: Line) -> { key: string, quantity: number }?)?,

	-- How many of that line the player actually has, right now.
	availableOf: (player: Player, line: Line) -> number,

	--[[
		THE SWAP. One call, atomic, and the only thing here that moves anything.

		It must RE-VALIDATE: it is called seconds after the offers were made and checked.
		Returning false aborts, both agreements are dropped, and the session stays open so
		the players can see what changed.
	]]
	swap: (a: Player, aLines: { Line }, b: Player, bLines: { Line }) -> (boolean, string?),

	-- Distinct lines one side may put on the table at once. A client asking for more is
	-- either a stale build or a crafted packet, and both get the same refusal.
	maxLines: number?,
	-- How long an unanswered invite stands.
	inviteSeconds: number?,
	-- Per-player floor between invites, so the button cannot spam somebody with toasts.
	inviteCooldown: number?,
	--[[
		The pause between both sides agreeing and the swap happening.

		A LAST LOOK, NOT A DELAY. Committing on the frame the second ready lands means the
		last thing either player saw was the board -- and the one moment a trade is worth
		double-checking is the moment it becomes irreversible. Un-readying during the count
		stops it, because it clears the agreement the count is running on.
	]]
	completeSeconds: number?,

	-- An extra gate beyond the published block, for a rule a host would rather not publish.
	-- Return a reason key to refuse, nil to allow.
	canTrade: ((player: Player) -> string?)?,

	--[[
		Rate limit on the action remote, as a token bucket: `moveBurst` moves may land
		back-to-back, refilling at `moveRate` a second.

		A BUCKET RATHER THAN A MINIMUM INTERVAL, because the two failure modes are
		different. Dragging four items onto the board in half a second is a burst and is
		legitimate; sending offers at sixty a second forever is not. A flat interval refuses
		the first to bound the second, which makes a responsive UI feel broken.

		Defaults are far above anything a person produces and far below anything worth
		amplifying.
	]]
	moveBurst: number?,
	moveRate: number?,

	actionRemote: RemoteEvent?,
	updateRemote: RemoteEvent?,
}

--[[
	A live trade. Two players, an offer each, a ready flag each.

	Offers are stored as the host sent them, after validation, rather than folded: a board
	shows LINES, and folding them for storage would mean unfolding them again to draw.
]]
type Session = {
	players: { Player },
	offers: { [Player]: { Line } },
	ready: { [Player]: boolean },
	--[[
		The countdown, as a TOKEN and a number of seconds left.

		A token rather than a boolean, and that is what makes ready -> not ready -> ready
		inside the countdown safe: the first count is still sleeping when the second starts,
		and only the one holding the current token may commit. A boolean would let the first
		wake up and swap against an agreement that had been taken back and given again.
	]]
	countdown: number,
	-- nil whenever no count is running, which is also what a client reads to decide whether
	-- to draw one.
	completesIn: number?,
}

local config: Config? = nil
local updateRemote: RemoteEvent? = nil

--[[
	The rate limiter's state: how many tokens each player has, and when it was last topped
	up. Refilled lazily on use rather than on a heartbeat, so a server full of players who
	are not trading costs nothing at all.
]]
local tokens: { [Player]: number } = {}
local refilledAt: { [Player]: number } = {}

local started = false
local sessions: { [Player]: Session } = {}
-- Keyed by the player being ASKED: one pending invite each, so a popular player is not
-- buried under them.
local invites: { [Player]: { from: Player, at: number } } = {}
local lastInvite: { [Player]: number } = {}

local function moveBurst(): number
	return math.max(1, (config and config.moveBurst) or 6)
end

local function moveRate(): number
	return math.max(0.1, (config and config.moveRate) or 4)
end

--[[
	Takes one token, or refuses.

	A refused move is DROPPED IN SILENCE. Answering it would send a packet, and sending a
	packet per unwanted packet is the amplification this exists to prevent -- a client that
	spams would get an equal stream back for its trouble.
]]
local function allowMove(player: Player): boolean
	local now = os.clock()
	local last = refilledAt[player]
	local available = tokens[player] or moveBurst()
	if last then
		available = math.min(moveBurst(), available + (now - last) * moveRate())
	end
	refilledAt[player] = now
	if available < 1 then
		tokens[player] = available
		return false
	end
	tokens[player] = available - 1
	return true
end

--[[
	Reads a `DefaultLine`. Exported so a host can wrap it rather than reimplement it.

	The key is `id@level`, built here from the line's own fields. Levels are integers and the
	level is always appended last, so two different (id, level) pairs cannot produce the same
	string -- an id that itself contains "@" is still safe.
]]
function Trading.readDefaultLine(line: Line): { key: string, quantity: number }?
	if type(line) ~= "table" then
		return nil
	end
	local id = (line :: DefaultLine).id
	if type(id) ~= "string" or id == "" then
		return nil
	end

	local level = (line :: DefaultLine).level
	if level == nil then
		level = 1
	elseif type(level) ~= "number" or level ~= math.floor(level) or level < 1 then
		return nil
	end

	local quantity = (line :: DefaultLine).quantity
	if type(quantity) ~= "number" then
		return nil
	end
	return { key = `{id}@{level}`, quantity = quantity }
end

local function lineReader(): (line: Line) -> { key: string, quantity: number }?
	local current = config
	return (current and current.readLine) or Trading.readDefaultLine
end

local function settings(): Config
	local current = config
	assert(current, "Trading: call start({ availableOf, swap }) first")
	return current
end

local function maxLines(): number
	return settings().maxLines or 9
end

local function inviteSeconds(): number
	return settings().inviteSeconds or 30
end

local function inviteCooldown(): number
	return settings().inviteCooldown or 3
end

local function completeSeconds(): number
	return settings().completeSeconds or 3
end

-- ─────────────────────────────────────────────────────── talking to clients ──

-- A refusal or an announcement, as a KEY. `detail` carries whoever the message is about,
-- so a host can write "{name} declined" without this module knowing what a sentence is.
local function notice(player: Player, reason: Reason, detail: Player?)
	local remote = updateRemote
	if remote then
		remote:FireClient(player, "notice", reason, detail)
	end
end

--[[
	Pushes the whole session to both sides.

	THE WHOLE THING, EVERY TIME. A trade is two players and a handful of lines; sending
	deltas would buy nothing and would let the two screens drift apart, which is the one
	failure this design exists to prevent.
]]
local function broadcast(session: Session)
	local remote = updateRemote
	if not remote then
		return
	end
	local a, b = session.players[1], session.players[2]
	for _, player in session.players do
		local partner = if player == a then b else a
		remote:FireClient(player, "state", {
			partner = partner,
			yours = session.offers[player],
			theirs = session.offers[partner],
			youReady = session.ready[player],
			theyReady = session.ready[partner],
			completesIn = session.completesIn,
		})
	end
end

-- Bumps the token, so anything already counting wakes up stale and returns.
local function stopCountdown(session: Session)
	session.countdown += 1
	session.completesIn = nil
end

local function close(session: Session, reason: Reason)
	stopCountdown(session)
	for _, player in session.players do
		sessions[player] = nil
	end
	local remote = updateRemote
	for _, player in session.players do
		if remote and player.Parent then
			remote:FireClient(player, "closed", reason)
		end
	end
end

-- ────────────────────────────────────────────────────────────────────  moves ──

-- Whether a player is free to start something new. Being mid-trade or mid-invite is what
-- makes an invite bounce, and saying WHICH is what stops the sender retrying into the same
-- wall.
local function busyReason(player: Player): Reason?
	if sessions[player] then
		return "Busy"
	end
	local pending = invites[player]
	if pending and os.clock() - pending.at < inviteSeconds() then
		return "Busy"
	end
	return nil
end

--[[
	Whether either side is barred from trading at all.

	SEPARATE FROM `busyReason`, because it is a different kind of no. Busy is about this
	trade queue; a block comes from somewhere else entirely and its wording belongs to the
	system that set it. Both sides are checked, and the SENDER'S OWN block first, so the
	refusal names the thing they can actually do something about.
]]
local function blockedReason(sender: Player, target: Player): (Reason?, Player?)
	--[[
		The host gate fails CLOSED. A throwing `canTrade` means the answer is unknown, and
		"unknown" must not read as "allowed" for the one check standing between a player and
		a trade they may be barred from.
	]]
	local gate = settings().canTrade
	local function gated(player: Player): boolean
		if Access.reasonFor(player) then
			return true
		end
		if not gate then
			return false
		end
		local ok, reason = pcall(gate, player)
		if not ok then
			warn(`[Trading] canTrade threw for {player.Name}; refusing the trade:`, reason)
			return true
		end
		return reason ~= nil
	end

	if gated(sender) then
		return "Blocked", nil
	end
	if gated(target) then
		return "PartnerBlocked", target
	end
	return nil, nil
end

local function invite(sender: Player, targetUserId: unknown)
	if type(targetUserId) ~= "number" then
		return
	end
	--[[
		Resolved from an id to a player IN THIS SERVER, which is the whole trust boundary for
		who may be traded with: there is no reaching an account that is not here.
	]]
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target or target == sender then
		notice(sender, if target == sender then "SelfInvite" else "NotFound")
		return
	end

	local since = lastInvite[sender]
	if since and os.clock() - since < inviteCooldown() then
		notice(sender, "Cooldown")
		return
	end

	local blocked, who = blockedReason(sender, target)
	if blocked then
		notice(sender, blocked, who)
		return
	end
	if busyReason(sender) then
		notice(sender, "Busy")
		return
	end
	if busyReason(target) then
		notice(sender, "Busy", target)
		return
	end

	lastInvite[sender] = os.clock()
	invites[target] = { from = sender, at = os.clock() }
	local remote = updateRemote
	if remote then
		remote:FireClient(target, "invited", sender)
		remote:FireClient(sender, "invitesent", target)
	end
end

local function respond(player: Player, accept: unknown)
	local pending = invites[player]
	if not pending then
		notice(player, "NoInvite")
		return
	end
	invites[player] = nil

	local sender = pending.from
	if accept ~= true then
		if sender.Parent then
			notice(sender, "Declined", player)
		end
		return
	end

	-- Everything is re-checked at accept, because an invite stands for seconds and any of it
	-- can have changed: the sender may have left, started another trade, or become blocked.
	if not sender.Parent or os.clock() - pending.at >= inviteSeconds() then
		notice(player, "Unavailable", sender)
		return
	end
	local blocked, who = blockedReason(player, sender)
	if blocked then
		notice(player, blocked, who)
		notice(sender, "Unavailable", player)
		return
	end
	if busyReason(sender) or busyReason(player) then
		notice(player, "Busy", sender)
		return
	end

	local session: Session = {
		players = { sender, player },
		offers = { [sender] = {}, [player] = {} },
		ready = { [sender] = false, [player] = false },
		countdown = 0,
		completesIn = nil,
	}
	sessions[sender] = session
	sessions[player] = session
	broadcast(session)
end

--[[
	Replaces one side of the table.

	Lines are validated INDIVIDUALLY and then TOTALLED BY KEY before being compared against
	what the player has. The totalling is the part that matters: two lines naming the same
	thing would each pass a per-line check while together exceeding what is owned.
]]
local function offer(player: Player, lines: unknown)
	local session = sessions[player]
	if not session or type(lines) ~= "table" then
		return
	end
	local current = settings()
	local count = #lines
	if count > maxLines() then
		notice(player, "TooManyLines")
		return
	end

	local checked: { Line } = {}
	local totals: { [string]: number } = {}
	--[[
		A NUMERIC LOOP, AND THAT IS THE SECURITY-RELEVANT PART.

		`#lines` measures the array part only, while `for _, line in lines` walks EVERY key.
		A payload of one array entry plus fifty string-keyed ones has a length of 1 -- so it
		sails past the cap -- and then hands fifty lines to the loop. Measured before this
		was fixed: cap 2, length 1, fifty-one lines processed.

		Iterating 1..#lines instead means the cap and the loop count the same thing, and
		anything hung off a non-numeric key is ignored rather than trusted.
	]]
	for index = 1, count do
		local line = (lines :: { Line })[index]
		-- Host code, so it may throw. A broken reader must fail CLOSED: the line is refused
		-- rather than let through unvalidated.
		local readOk, read = pcall(lineReader(), line)
		if
			not readOk
			or type(read) ~= "table"
			or type(read.key) ~= "string"
			or read.key == ""
			or type(read.quantity) ~= "number"
			or read.quantity ~= math.floor(read.quantity)
			or read.quantity < 1
		then
			notice(player, "BadLine")
			return
		end
		local availableOk, available = pcall(current.availableOf, player, line)
		if not availableOk or type(available) ~= "number" then
			-- Also closed: "we could not find out how many you have" is not "you have enough".
			notice(player, "NotEnough")
			return
		end
		totals[read.key] = (totals[read.key] or 0) + read.quantity
		if totals[read.key] > available then
			notice(player, "NotEnough")
			return
		end
		table.insert(checked, line)
	end

	session.offers[player] = checked
	--[[
		The table changed, so nobody has agreed to it. This is the whole reason ready is
		stored per session rather than per player -- and a count already running was counting
		down to a table that no longer exists, so it goes with the agreements.
	]]
	stopCountdown(session)
	for _, participant in session.players do
		session.ready[participant] = false
	end
	broadcast(session)
end

-- The swap itself, once the count has run out.
local function commit(session: Session)
	local a, b = session.players[1], session.players[2]
	--[[
		Guarded, because `swap` is host code called from inside a spawned countdown: an
		unguarded throw would kill that coroutine and leave the session open forever, showing
		a count that never resolves and agreements that never clear.

		A throw is treated exactly as a refusal, which is the honest reading -- nothing is
		known to have moved.
	]]
	local called, ok, reason = pcall(settings().swap, a, session.offers[a], b, session.offers[b])
	if not called then
		warn(`[Trading] swap THREW for {a.Name} and {b.Name}; treating it as refused:`, ok)
		ok, reason = false, nil
	end
	if ok then
		close(session, "Complete")
		return
	end

	--[[
		Both agreements are dropped rather than the trade being retried: whatever changed
		underneath means the table they agreed to is not the one in front of them any more,
		and re-running it would be committing to something neither of them looked at.

		The session STAYS OPEN so they can see what changed and decide again.
	]]
	stopCountdown(session)
	for _, participant in session.players do
		session.ready[participant] = false
		notice(participant, "Failed")
	end
	if reason then
		warn(`[Trading] swap refused for {a.Name} and {b.Name}: {reason}`)
	end
	broadcast(session)
end

--[[
	Counts both sides down to the swap, a second at a time.

	Broadcast per tick rather than sending an end time once: a session is two players and a
	few packets, and the alternative is two clients each running their own clock against a
	number that has to agree with the server's to the second. A screen draws what it was
	told, which is the rule the rest of this module works by.
]]
local function beginCountdown(session: Session)
	session.countdown += 1
	local token = session.countdown
	session.completesIn = completeSeconds()
	broadcast(session)

	task.spawn(function()
		for remaining = completeSeconds() - 1, 0, -1 do
			task.wait(1)
			-- Anything that touched the agreement while this slept has bumped the token, and
			-- that covers a cancel, a leave, a new offer and a block landing.
			if session.countdown ~= token then
				return
			end
			session.completesIn = remaining
			if remaining > 0 then
				broadcast(session)
			end
		end
		commit(session)
	end)
end

local function ready(player: Player, agreed: unknown)
	local session = sessions[player]
	if not session then
		return
	end
	local wanted = agreed == true
	-- A repeat of what is already true is not a move. Without this, holding the button
	-- restarts the countdown on every press -- which is a trade that never completes, and a
	-- broadcast to both clients for each one.
	if session.ready[player] == wanted then
		return
	end
	session.ready[player] = wanted

	local a, b = session.players[1], session.players[2]
	if session.ready[a] and session.ready[b] then
		beginCountdown(session)
	else
		-- Un-readying during the count stops it, because it clears the agreement the count
		-- is running on.
		stopCountdown(session)
		broadcast(session)
	end
end

local function cancel(player: Player, reason: Reason)
	local session = sessions[player]
	if session then
		close(session, reason)
	end
	local pending = invites[player]
	if pending then
		invites[player] = nil
		if pending.from.Parent then
			notice(pending.from, "Declined", player)
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────  start ──

--[[
	A player who becomes unable to trade takes their trade with them.

	WATCHED, NOT CALLED. Anything may set the block, and none of those systems should have to
	know that a trade exists, let alone end one. So this listens to the fact itself: the
	attribute changes and whatever was in flight stops.

	An invite this player SENT is left to expire on its own -- it is re-checked at accept,
	and that check includes this one, so a late yes is refused and both sides hear about it.
]]
local function watchAccess(player: Player)
	Access.changed(player):Connect(function()
		if Access.reasonFor(player) then
			cancel(player, "Unavailable")
		end
	end)
end

local function onPlayerRemoving(player: Player)
	-- Their partner is told, then everything keyed by them goes. A left player must not
	-- leave a session or an invite behind that would refuse them forever on a rejoin.
	local session = sessions[player]
	if session then
		close(session, "PartnerLeft")
	end
	local pending = invites[player]
	if pending and pending.from.Parent then
		notice(pending.from, "Declined", player)
	end
	invites[player] = nil
	lastInvite[player] = nil
	sessions[player] = nil
	tokens[player] = nil
	refilledAt[player] = nil
end

local function ensureRemote(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function ensureContainer(): Instance
	local existing = ReplicatedStorage:FindFirstChild(CONTAINER_NAME)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = CONTAINER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

-- Ends whatever this player is doing, for a host's own reason. The published block does
-- this automatically; this is for a one-off that is not worth publishing.
function Trading.cancel(player: Player, reason: string?)
	cancel(player, (reason :: any) or "Cancelled")
end

function Trading.isTrading(player: Player): boolean
	return sessions[player] ~= nil
end

-- Who this player is trading with, or nil.
function Trading.partnerOf(player: Player): Player?
	local session = sessions[player]
	if not session then
		return nil
	end
	local a, b = session.players[1], session.players[2]
	return if player == a then b else a
end

function Trading.start(options: Config)
	assert(type(options) == "table", "Trading.start: options must be a table")
	-- Every move would otherwise be handled once per call: the remote handler and the
	-- player connections below are additive, so a second start doubles them silently.
	if started then
		warn("[Trading] start() has already run; ignoring this call.")
		return
	end
	started = true
	for _, field in { "availableOf", "swap" } do
		assert(type((options :: any)[field]) == "function", `Trading.start: \`{field}\` must be a function`)
	end
	assert(
		options.readLine == nil or type(options.readLine) == "function",
		"Trading.start: `readLine` must be a function when given; omit it for the default line shape"
	)
	config = options

	local container: Instance? = nil
	local function remoteFor(injected: RemoteEvent?, name: string): RemoteEvent
		if injected then
			return injected
		end
		container = container or ensureContainer()
		return ensureRemote(container :: Instance, name)
	end
	local actionRemote = remoteFor(options.actionRemote, ACTION_REMOTE_NAME)
	updateRemote = remoteFor(options.updateRemote, UPDATE_REMOTE_NAME)

	--[[
		One remote, one `kind`, and everything validated on the way in. A move this module
		does not recognise is dropped without comment: a client sending one is either a stale
		build or a crafted packet, and neither is owed an explanation.
	]]
	actionRemote.OnServerEvent:Connect(function(player: Player, kind: unknown, payload: unknown)
		if type(kind) ~= "string" then
			return
		end
		-- Before the dispatch and before any validation, so a flood costs one table lookup
		-- rather than a walk through somebody's inventory.
		if not allowMove(player) then
			return
		end
		if kind == "invite" then
			invite(player, payload)
		elseif kind == "respond" then
			respond(player, payload)
		elseif kind == "offer" then
			offer(player, payload)
		elseif kind == "ready" then
			ready(player, payload)
		elseif kind == "cancel" then
			cancel(player, "Cancelled")
		end
	end)

	Players.PlayerAdded:Connect(watchAccess)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	-- Anyone already here: a host may start this after players have joined.
	for _, player in Players:GetPlayers() do
		watchAccess(player)
	end
end

return Trading
