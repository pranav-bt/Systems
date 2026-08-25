--!strict

-- The player's level and its XP, as the client sees them.
--
-- READ-ONLY, AND THAT IS THE POINT. Every grant happens on the server, and this module holds
-- no XP arithmetic of its own: it mirrors the two attributes the server publishes and hands
-- them to whatever is drawing them. The game this came from used to accrue XP on the client
-- and report the result at run end through a save remote -- which is to say the client named
-- its own level. Bounds-checking that report narrowed the lie but could not remove it,
-- because the sender was the beneficiary.
--
-- BEING ONE REPLICATION BEHIND IS HARMLESS. A level scales rewards; it is not a
-- frame-accurate value, and nothing here is on a hot path.
--
-- WHAT IT ADDS OVER READING THE ATTRIBUTES YOURSELF, which is the whole reason it exists:
--
--   * the two attributes are COALESCED into one state change, so a listener never sees a new
--     level beside the old experience
--   * `gained` is worked out across level boundaries, where a subtraction would report a loss
--   * the first sync is not reported as a level-up, so a returning level-40 player does not
--     get forty toasts on join
--   * the tempo remote is subscribed to and folded in beside the numbers

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Curve = require(script.Parent.shared)

local Levelling = {}

Levelling.Curve = Curve

local CONTAINER_NAME = "LevellingRemotes"
local RATE_REMOTE_NAME = "Rate"

--[[
	`gained` is the XP earned since the previous notification, and 0 for the first one -- the
	join sync is not something the player just earned, and a pop-up saying "+9,000 XP" on
	spawn is a lie. It is reported from here rather than worked out by each listener because
	this is the only place that knows both the previous reading and whether there was one.

	`crossed` is how many levels this change carried them up, 0 for none.
]]
export type Reading = {
	level: number,
	experience: number,
	required: number,
	crossed: number,
	gained: number,
}

type Listener = (reading: Reading) -> ()
type RateListener = (xpPerSecond: number) -> ()

local levelAttribute = "Level"
local experienceAttribute = "Experience"

local level = Curve.settings.startLevel
local experience = 0
local rate = 0

local listeners: { Listener } = {}
local rateListeners: { RateListener } = {}
local started = false

local function reading(crossed: number, gained: number): Reading
	return {
		level = level,
		experience = experience,
		required = Curve.xpToNext(level),
		crossed = crossed,
		gained = gained,
	}
end

local function notify(crossed: number, gained: number)
	local snapshot = reading(crossed, gained)
	for _, listener in table.clone(listeners) do
		task.spawn(listener, snapshot)
	end
end

-- ── Reading ───────────────────────────────────────────────────────────────────

function Levelling.getLevel(): number
	return level
end

function Levelling.getExperience(): number
	return experience
end

-- What the current level costs. `math.huge` at the cap.
function Levelling.getRequired(): number
	return Curve.xpToNext(level)
end

--[[
	How far through the current level, 0 to 1.

	1 at the cap rather than 0: the bar is full and stays full, which is what "there is no
	more" looks like. Dividing by the huge `required` would draw an empty bar on the player
	who has earned the most.
]]
function Levelling.getProgress(): number
	if Curve.isMaxLevel(level) then
		return 1
	end
	local required = Curve.xpToNext(level)
	if required <= 0 then
		return 0
	end
	return math.clamp(experience / required, 0, 1)
end

-- The multiplier this level is worth. The host decides what it applies to.
function Levelling.getRewardMultiplier(): number
	return Curve.rewardMultiplier(level)
end

-- The current tempo, in XP per second, 0 for not earning.
function Levelling.getRate(): number
	return rate
end

--[[
	ANY player's level, not just this one.

	The published attribute is what makes this a lookup rather than a request: a list of
	twenty players draws twenty levels without the server pushing a roster or answering
	twenty round trips. nil for a player whose profile has not published yet, which a caller
	should draw as blank rather than as level 1 -- those are different facts.
]]
function Levelling.levelOf(player: Player): number?
	local value = player:GetAttribute(levelAttribute)
	return if type(value) == "number" then value else nil
end

-- ── Subscribing ───────────────────────────────────────────────────────────────

--[[
	Registers a listener and immediately pushes the current reading, so a caller does not
	depend on having been started first. Returns a function that unsubscribes.
]]
function Levelling.onChanged(listener: Listener): () -> ()
	table.insert(listeners, listener)
	task.spawn(listener, reading(0, 0))
	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

function Levelling.onRate(listener: RateListener): () -> ()
	table.insert(rateListeners, listener)
	task.spawn(listener, rate)
	return function()
		local index = table.find(rateListeners, listener)
		if index then
			table.remove(rateListeners, index)
		end
	end
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

--[[
	Starts mirroring. Idempotent, and safe to call before the server has published anything.

	`levelAttribute` / `experienceAttribute` must match what the server was started with. They
	are two ends of one wire, and a game that renamed one has to rename both.
]]
function Levelling.start(options: {
	levelAttribute: string?,
	experienceAttribute: string?,
	curve: Curve.Settings?,
}?)
	local given = options or {}
	if given.levelAttribute then
		levelAttribute = given.levelAttribute
	end
	if given.experienceAttribute then
		experienceAttribute = given.experienceAttribute
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

	local player = Players.LocalPlayer

	--[[
		THE SERVER'S NUMBERS ARE THE NUMBERS. There is no "only move forward" rule here, and it
		matters that there is not: a rebirth and an admin reset both move the level DOWN, and a
		forward-only filter would leave the bar showing a level the player no longer has.

		A level arriving higher than the last one counts as a level-up for the UI, except on
		the first sync -- a player who logs in at level 8 has not just levelled up eight times.
	]]
	local synced = false
	local function apply(nextLevel: number, nextExperience: number)
		local firstSync = not synced
		synced = true

		local crossed = if firstSync then 0 else math.max(0, nextLevel - level)
		local gained = if firstSync then 0 else Curve.gainedBetween(level, experience, nextLevel, nextExperience)

		level = nextLevel
		experience = nextExperience
		notify(crossed, gained)
	end

	local function currentReading(): (number, number)
		local rawLevel = player:GetAttribute(levelAttribute)
		local rawExperience = player:GetAttribute(experienceAttribute)
		return math.max(Curve.settings.startLevel, math.floor(tonumber(rawLevel) or Curve.settings.startLevel)),
			math.max(0, tonumber(rawExperience) or 0)
	end

	--[[
		Both attributes are read at the END of the frame rather than each change being applied
		as it lands. One grant writes two attributes, so it arrives as two changes -- the new
		level beside the OLD experience, then the new experience -- and applying each in turn
		shows listeners a level-up with a stale bar followed by a negative gain. Coalescing to
		one `task.defer` means one state change per grant, with one honest gain in it.
	]]
	local pending = false
	local function schedule()
		if pending then
			return
		end
		pending = true
		task.defer(function()
			pending = false
			apply(currentReading())
		end)
	end

	player:GetAttributeChangedSignal(levelAttribute):Connect(schedule)
	player:GetAttributeChangedSignal(experienceAttribute):Connect(schedule)

	-- Whatever is already published. A player whose profile loaded before this ran gets their
	-- real numbers here rather than waiting for the next grant to move an attribute.
	if player:GetAttribute(levelAttribute) ~= nil then
		apply(currentReading())
	end

	task.spawn(function()
		local container = ReplicatedStorage:WaitForChild(CONTAINER_NAME, 30)
		if not container then
			return
		end
		local remote = container:WaitForChild(RATE_REMOTE_NAME, 30) :: RemoteEvent?
		if not remote then
			return
		end
		remote.OnClientEvent:Connect(function(xpPerSecond: number)
			rate = math.max(0, tonumber(xpPerSecond) or 0)
			for _, listener in table.clone(rateListeners) do
				task.spawn(listener, rate)
			end
		end)
	end)
end

return Levelling
