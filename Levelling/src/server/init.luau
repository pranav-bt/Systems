--!strict

-- The only place XP enters a profile.
--
-- WHY A DOOR AT ALL. XP is the one number in a progression game that every system wants to
-- hand out -- a kill, a quest, a timer, a zone, a daily -- and the moment two of them write
-- the profile directly there are two copies of the level-up loop, two places a multiplier
-- has to be remembered, and one of them is always the one that gets missed. Everything here
-- exists to make `grant` the single write.
--
-- THE PAIR THAT IS THE WHOLE INTERFACE:
--
--   grant(player, amount)              the AMOUNT -- into the profile, and out as a fact
--   setRate(player, source, perSecond) the TEMPO -- out to the one client earning it
--
-- The tempo is not a reward and cannot make a total wrong; see `setRate` for why a client
-- cannot work it out for itself.
--
-- MULTIPLIERS ARE A NAMED STACK, applied here and nowhere else. A caller hands over a BASE
-- amount and never has to know the player owns a 2x gamepass, has rebirthed three times, or
-- caught a double-XP weekend -- an XP source added tomorrow is scaled by having been written
-- at all. The in-game version this started as hardcoded exactly one multiplier (rebirth) inside
-- this function, which works right up until the second one exists.
--
-- THE PROFILE IS THE HOST'S. This module never picks a datastore, a schema or a key: `read`
-- and `write` are two functions a host supplies, so a ProfileService document, a plain table
-- and a set of attributes are all equally valid homes for the two numbers.
--
-- WHAT REPLICATES, AND HOW. Level and experience are published as ATTRIBUTES on the Player,
-- for the reasons Trading's Access module gives: they replicate to every client, they can be
-- read about any OTHER player without a round trip (a level next to a name in a list), and
-- `GetAttributeChangedSignal` exists whether or not the attribute has ever been written,
-- which a ChildAdded race does not.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Curve = require(script.Parent.shared)

local Levelling = {}

Levelling.Curve = Curve

local CONTAINER_NAME = "LevellingRemotes"
local RATE_REMOTE_NAME = "Rate" -- server -> one client, XP per second

export type Config = {
	--[[
		Reads this player's stored progress, or nil if there is nothing to read.

		nil is not an error and is not logged: a player who left mid-grant, or whose profile
		has not loaded yet, is the ordinary case. The grant is dropped, which is the harmless
		direction -- the alternative is writing a level onto a profile that is about to be
		overwritten by the real one.
	]]
	read: (player: Player) -> (number?, number?),

	--[[
		Stores it. Called only when something actually changed.

		Not expected to yield and not expected to save to a DataStore -- a host that grants
		per second would be writing per second. Write into whatever in-memory document the
		host already flushes on its own schedule.
	]]
	write: (player: Player, level: number, experience: number) -> (),

	--[[
		The attribute names published on the Player.

		Configurable because "Level" is a popular name, and a game that already publishes one
		of its own should not have this module silently fighting it for the same key.
	]]
	levelAttribute: string,
	experienceAttribute: string,
}

local config: Config = {
	read = function()
		return nil, nil
	end,
	write = function() end,
	levelAttribute = "Level",
	experienceAttribute = "Experience",
}

local started = false

-- ── Signals ───────────────────────────────────────────────────────────────────

--[[
	A minimal signal, in plain Lua.

	Not a BindableEvent, and the difference is load-bearing: a BindableEvent SERIALISES its
	arguments -- tables are deep-copied, metatables stripped, functions dropped -- so a
	listener handed the crossed-levels detail would receive a different table than the one
	fired. Handlers are spawned, so one that errors or yields cannot hold up a grant.
]]
type Handler = (...any) -> ()

local function makeSignal()
	local handlers: { Handler } = {}
	local signal = {}

	function signal.connect(_: any, handler: Handler)
		table.insert(handlers, handler)
		local connected = true
		return {
			disconnect = function()
				if not connected then
					return
				end
				connected = false
				local index = table.find(handlers, handler)
				if index then
					table.remove(handlers, index)
				end
			end,
		}
	end

	local function fire(...)
		for _, handler in table.clone(handlers) do
			task.spawn(handler, ...)
		end
	end

	return signal, fire
end

--[[
	Fires (player, level, crossed) when a grant carries a player up at least one level.

	`crossed` is how many, because a big grant can cross several and a host paying a reward
	per level owes all of them.

	Fired LAST, after the profile and both attributes agree, for the reason every signal in
	this repo fires last: a subscriber must never be able to read a half-applied level.
]]
local levelUpSignal, fireLevelUp = makeSignal()
Levelling.levelUp = levelUpSignal

--[[
	Fires (player, level, experience, gained) on every grant that changed anything, level-up
	or not. What an XP-pop or a bar animation listens to.
]]
local changedSignal, fireChanged = makeSignal()
Levelling.changed = changedSignal

--[[
	Fires (player, wasted) when a grant landed on a capped player and the XP had nowhere to
	go. A host that converts overflow into currency listens here; one with no cap never sees
	it fire.
]]
local wastedSignal, fireWasted = makeSignal()
Levelling.overflowed = wastedSignal

-- ── The multiplier stack ──────────────────────────────────────────────────────

-- Named so a source can be replaced or removed, and so two of them cannot collide.
local multipliers: { [string]: (player: Player) -> number } = {}
local multiplierOrder: { string } = {}

--[[
	Registers a multiplier applied to every grant and every rate announcement.

	COMPOSED BY PRODUCT: a 2x gamepass and a 3x rebirth make 6x. That is the behaviour a
	player expects from two things that each say "double", and summing bonuses instead would
	make the second one worth less than the first, which reads as a bug in the shop.

	Each is pcalled and a failure contributes 1 rather than aborting the grant -- an XP source
	that pays unscaled is a much smaller problem than one that pays nothing.

	Registering the same name twice REPLACES, so a host reloading a module does not end up
	multiplying by it twice.
]]
function Levelling.addMultiplier(name: string, fn: (player: Player) -> number)
	assert(type(name) == "string" and name ~= "", "Levelling.addMultiplier: name must be a non-empty string")
	assert(type(fn) == "function", "Levelling.addMultiplier: fn must be a function")
	if multipliers[name] == nil then
		table.insert(multiplierOrder, name)
	end
	multipliers[name] = fn
end

function Levelling.removeMultiplier(name: string)
	if multipliers[name] == nil then
		return
	end
	multipliers[name] = nil
	local index = table.find(multiplierOrder, name)
	if index then
		table.remove(multiplierOrder, index)
	end
end

--[[
	The product of every registered multiplier for this player.

	Recomputed on every call rather than cached. Each one is expected to be a table lookup,
	both callers are already doing profile work, and a cache would be one more thing every
	registrant had to remember to invalidate -- which is the failure that leaves a player
	earning at yesterday's rate with nothing to point at.

	A multiplier that returns a non-number or something <= 0 counts as 1. Zero would silently
	turn off every XP source in the game, and there is no way to tell that apart from a
	registrant with a bug.
]]
function Levelling.multiplierFor(player: Player): number
	local total = 1
	for _, name in multiplierOrder do
		local fn = multipliers[name]
		if fn then
			local ok, value = pcall(fn, player)
			if ok and type(value) == "number" and value > 0 then
				total *= value
			end
		end
	end
	return total
end

-- ── Reading ───────────────────────────────────────────────────────────────────

--[[
	This player's stored progress, defaulted.

	A profile that has never been written reads as (startLevel, 0) rather than nil, so a host
	does not have to seed the two fields to make the first grant work.
]]
function Levelling.get(player: Player): (number, number)
	local ok, level, experience = pcall(config.read, player)
	if not ok then
		return Curve.settings.startLevel, 0
	end
	return math.max(Curve.settings.startLevel, math.floor(tonumber(level) or Curve.settings.startLevel)),
		math.max(0, tonumber(experience) or 0)
end

function Levelling.getLevel(player: Player): number
	local level = Levelling.get(player)
	return level
end

-- ── Writing ───────────────────────────────────────────────────────────────────

--[[
	Persists and publishes one reading.

	THE ORDER MATTERS AND IS THE SAME EVERYWHERE: profile, then experience, then level. The
	level attribute is written LAST because it is the one a client watches to know something
	happened, and a reader woken by it must not find the experience still stale.
]]
local function commit(player: Player, level: number, experience: number)
	pcall(config.write, player, level, experience)
	player:SetAttribute(config.experienceAttribute, experience)
	player:SetAttribute(config.levelAttribute, level)
end

--[[
	Sets a player's progress outright, ignoring every multiplier.

	FOR THINGS THAT ARE NOT EARNING: an admin command, a migration, a rebirth handing the
	level back. It fires `changed` but never `levelUp` -- a level that was assigned is not one
	that was reached, and a host paying a per-level reward would otherwise pay out for an
	admin fixing a bug.
]]
function Levelling.set(player: Player, level: number, experience: number?)
	local nextLevel = math.max(Curve.settings.startLevel, math.floor(level))
	local cap = Curve.settings.maxLevel
	if cap then
		nextLevel = math.min(nextLevel, cap)
	end
	local nextExperience = math.max(0, experience or 0)
	if Curve.isMaxLevel(nextLevel) then
		nextExperience = 0
	end

	commit(player, nextLevel, nextExperience)
	fireChanged(player, nextLevel, nextExperience, 0)

	-- The rate is announced pre-multiplied, so a change that could have moved a multiplier
	-- has to be re-sent. Cheap: it dedupes against what was last sent.
	Levelling.refreshRate(player)
end

--[[
	Back to the beginning: `startLevel`, no experience.

	Its own function because a rebirth, a season reset and a wipe are the same operation
	spelled three ways, and because `set(player, Curve.settings.startLevel, 0)` at three call
	sites is a rule in three places.
]]
function Levelling.reset(player: Player)
	Levelling.set(player, Curve.settings.startLevel, 0)
end

--[[
	The single door. Adds XP, scaled by the multiplier stack.

	`amount` is a BASE number: whatever the source thinks the thing was worth, before any
	bonus. Non-positive amounts are dropped rather than subtracted -- taking XP away is
	`set`'s job, and a source paying a negative reward is a bug in the source that should not
	quietly demote the player.

	Returns the scaled amount actually granted, and how many levels it crossed, so a caller
	that wants to say "+40 XP" has the real number without recomputing the stack.
]]
function Levelling.grant(player: Player, amount: number): (number, number)
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return 0, 0
	end

	local ok, storedLevel, storedExperience = pcall(config.read, player)
	if not ok or storedLevel == nil then
		-- No profile: the player left, or theirs has not loaded. Dropping is the harmless
		-- direction; writing would put a level on a document about to be replaced.
		return 0, 0
	end

	local level = math.max(Curve.settings.startLevel, math.floor(tonumber(storedLevel) or Curve.settings.startLevel))
	local experience = math.max(0, tonumber(storedExperience) or 0)

	if Curve.isMaxLevel(level) then
		fireWasted(player, amount * Levelling.multiplierFor(player))
		return 0, 0
	end

	local granted = amount * Levelling.multiplierFor(player)
	local nextLevel, nextExperience, crossed, wasted = Curve.applyExperience(level, experience, granted)

	commit(player, nextLevel, nextExperience)

	fireChanged(player, nextLevel, nextExperience, granted)
	if crossed > 0 then
		fireLevelUp(player, nextLevel, crossed)
	end
	if wasted > 0 then
		fireWasted(player, wasted)
	end

	return granted, crossed
end

-- ── The tempo ─────────────────────────────────────────────────────────────────

-- Per player, the base rate each source is paying. Cleared entirely when every source is
-- off, which is also what keeps this from outliving the player.
local rates: { [Player]: { [string]: number } } = {}
-- The total last actually sent, so a rate that has not changed costs no message.
local sent: { [Player]: number } = {}

local rateRemote: RemoteEvent? = nil

local function remote(): RemoteEvent?
	return rateRemote
end

local function announce(player: Player, total: number)
	local scaled = if total > 0 then total * Levelling.multiplierFor(player) else 0
	if sent[player] == scaled then
		return
	end
	-- Dropped rather than stored as 0, so a player who stops earning leaves nothing here. The
	-- guard above is what stops that re-sending 0 on every later call.
	sent[player] = if scaled > 0 then scaled else nil
	local fire = remote()
	if fire then
		fire:FireClient(player, scaled)
	end
end

local function totalFor(player: Player): number
	local sources = rates[player]
	if not sources then
		return 0
	end
	local total = 0
	for _, value in sources do
		total += value
	end
	return total
end

--[[
	Says how fast this player is being paid, in XP per second, 0 for not at all. Sent on
	CHANGE only.

	IT EXISTS BECAUSE THE CLIENT CANNOT ANSWER THE QUESTION. A UI that spells one grant out as
	a stream of small "+1"s has to know the moment the income stopped -- otherwise it is still
	counting out the last payment seconds after the player walked out of the zone, which is
	feedback for something they are no longer doing. Deriving it client-side would mean a
	second copy of the payout rule (is a menu open, is the run paused, which of two
	overlapping zones wins), and the two eventually disagree.

	A TEMPO, NEVER A REWARD. The pops are paid for out of the published experience attribute,
	which is this server's own number, so a rate that is wrong or late makes the stream the
	wrong SHAPE and cannot make the total wrong. That is what lets callers announce from
	wherever is convenient -- the tick that decides to pay, rather than every place that could
	have changed the answer.

	KEYED BY SOURCE AND SUMMED, because a timer and a zone are independent owners with
	independent state and neither should have to know the other exists. Where they are in
	practice mutually exclusive the sum is a safety property rather than a feature: a source
	that forgets to switch off cannot be silently overwritten by the other one.

	The sources hold BASE rates and the stack is applied to their sum on the way out, which is
	what makes a new multiplier need no announcement of its own.
]]
function Levelling.setRate(player: Player, source: string, xpPerSecond: number)
	local rate = math.max(0, tonumber(xpPerSecond) or 0)
	local sources = rates[player]
	if not sources then
		-- A source turning off before it ever turned on: nothing recorded, nothing to say.
		-- Also the line that makes a caller's own clean-up idempotent.
		if rate <= 0 then
			return
		end
		sources = {}
		rates[player] = sources
	end
	sources[source] = if rate > 0 then rate else nil

	local total = 0
	for _, value in sources do
		total += value
	end
	if next(sources) == nil then
		rates[player] = nil
	end

	announce(player, total)
end

--[[
	Re-sends the rate if the stack now makes it a different number.

	Called automatically whenever this module changes a level, and exposed because a host that
	grants a multiplier from somewhere else -- a gamepass bought mid-session -- has no other
	way to say so. Costs nothing when the answer has not moved.
]]
function Levelling.refreshRate(player: Player)
	announce(player, totalFor(player))
end

-- The rate this player is being paid, scaled. Mostly for tests and for a host that wants to
-- show it somewhere the client module does not reach.
function Levelling.getRate(player: Player): number
	return sent[player] or 0
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

--[[
	Publishes a player's stored progress onto their Player object.

	Call it once a profile has loaded. It is separate from `start` because only the host knows
	when that is, and publishing a default before the real numbers arrive would show every
	returning player level 1 for a moment.
]]
function Levelling.publish(player: Player)
	local level, experience = Levelling.get(player)
	player:SetAttribute(config.experienceAttribute, experience)
	player:SetAttribute(config.levelAttribute, level)
end

local function forget(player: Player)
	rates[player] = nil
	sent[player] = nil
end

--[[
	Wires the transport and takes the host's seams. Idempotent.

	The remote is created here rather than assumed to exist, per this repo's "own your
	transport" rule -- a library that needs a central registry to have been built first is a
	library with a boot-order dependency nobody documented.
]]
function Levelling.start(options: {
	read: ((player: Player) -> (number?, number?))?,
	write: ((player: Player, level: number, experience: number) -> ())?,
	levelAttribute: string?,
	experienceAttribute: string?,
	curve: Curve.Settings?,
}?)
	local given = options or {}
	if given.read then
		config.read = given.read
	end
	if given.write then
		config.write = given.write
	end
	if given.levelAttribute then
		config.levelAttribute = given.levelAttribute
	end
	if given.experienceAttribute then
		config.experienceAttribute = given.experienceAttribute
	end
	if given.curve then
		for key, value in given.curve :: any do
			(Curve.settings :: any)[key] = value
		end
	end

	if started then
		return
	end
	started = true

	local container = ReplicatedStorage:FindFirstChild(CONTAINER_NAME)
	if not container then
		container = Instance.new("Folder");
		(container :: Folder).Name = CONTAINER_NAME;
		(container :: Folder).Parent = ReplicatedStorage
	end
	local existing = (container :: Folder):FindFirstChild(RATE_REMOTE_NAME)
	if existing then
		rateRemote = existing :: RemoteEvent
	else
		local created = Instance.new("RemoteEvent")
		created.Name = RATE_REMOTE_NAME
		created.Parent = container
		rateRemote = created
	end

	Players.PlayerRemoving:Connect(forget)
end

return Levelling
