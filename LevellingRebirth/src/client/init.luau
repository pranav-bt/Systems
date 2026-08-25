--!strict

-- Rebirth, as the client sees it: how many, what the next rung costs, and whether it is
-- available right now.
--
-- WHY THERE IS A CLIENT HALF AT ALL. The ladder claims "a screen can never offer what the
-- server would refuse", and that is only true if the screen is asking the SAME ladder. A
-- game left to derive availability itself ends up with a second opinion on the question the
-- server already answers, and the two disagree the first time a rung is re-tuned.
--
-- IT DRAWS NOTHING. No window, no button, no copy -- `title` is a key and the host words it.
-- What this provides is the four facts a window needs and one call to make the request.
--
-- THE COUNT IS AN ATTRIBUTE, so a list of players shows everyone's rebirths without a round
-- trip. `countOf` is the whole reason a leaderboard does not need its own remote.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ladder = require(script.Parent.shared)

local Rebirth = {}

Rebirth.Ladder = Ladder

local CONTAINER_NAME = "LevellingRemotes"
local REQUEST_REMOTE_NAME = "RequestRebirth"

--[[
	Everything a rebirth window draws, in one shape.

	Handed over whole rather than as five getters, because a window that reads them one at a
	time can read them across a change and draw a state that never existed -- "3 rebirths,
	next is Awakening" while the attribute lands.
]]
export type State = {
	rebirths: number,
	level: number,
	-- The rung they would take next, or nil at the top of the ladder.
	nextTier: Ladder.Tier?,
	-- The rung they last took, or nil before the first one.
	currentTier: Ladder.Tier?,
	-- The XP multiplier they are earning at right now.
	multiplier: number,
	-- Levels still needed, 0 when available and math.huge at the top.
	levelsRemaining: number,
	-- Whether the button should be live. The ladder's half of the answer; the server also
	-- asks its gate, which no client can see.
	available: boolean,
}

type Listener = (state: State) -> ()

--[[
	The base package's client half, by SHAPE. Anything with `getLevel` and `onChanged` will
	do, which is what keeps this addon from requiring a path into a package the host may have
	vendored, renamed or wrapped.
]]
type Base = {
	getLevel: () -> number,
	onChanged: (listener: (reading: any) -> ()) -> () -> (),
}

local base: Base? = nil
local attribute = "Rebirths"
local rebirths = 0
local listeners: { Listener } = {}
local remote: RemoteEvent? = nil
local started = false

local function levelNow(): number
	local installed = base
	return if installed then installed.getLevel() else 0
end

function Rebirth.getState(): State
	local level = levelNow()
	return {
		rebirths = rebirths,
		level = level,
		nextTier = Ladder.nextTier(rebirths),
		currentTier = Ladder.currentTier(rebirths),
		multiplier = Ladder.multiplierFor(rebirths),
		levelsRemaining = Ladder.levelsRemaining(rebirths, level),
		available = Ladder.canRebirth(rebirths, level),
	}
end

function Rebirth.getCount(): number
	return rebirths
end

-- ANY player's rebirth count, straight off the published attribute. nil for one whose
-- profile has not published yet, which a caller should draw as blank rather than as 0 --
-- those are different facts.
function Rebirth.countOf(player: Player): number?
	local value = player:GetAttribute(attribute)
	return if type(value) == "number" then value else nil
end

local function notify()
	local state = Rebirth.getState()
	for _, listener in table.clone(listeners) do
		task.spawn(listener, state)
	end
end

--[[
	Registers a listener and immediately pushes the current state. Fires on a rebirth AND on
	every level change, because availability depends on both -- a window that only listened
	to the count would stay greyed out at the moment the player finally qualifies, which is
	precisely the moment it matters.

	Returns a function that unsubscribes.
]]
function Rebirth.onChanged(listener: Listener): () -> ()
	table.insert(listeners, listener)
	task.spawn(listener, Rebirth.getState())
	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

--[[
	Asks the server to rebirth. Carries nothing, and there is no reply.

	THE ANSWER IS THE STATE MOVING. A refusal is silent by construction: the button is
	disabled by the same ladder the server checks, so the only calls that can be refused are
	ones no honest client sends. A host whose gate refuses for a reason a player should be
	told -- "not during a match" -- should publish that reason itself, the way it already
	knows it, rather than expecting a result here.
]]
function Rebirth.request()
	local fire = remote
	if fire then
		fire:FireServer()
	end
end

--[[
	Starts mirroring. `levelling` is the base package's client half; `tiers` must be the same
	ladder the server was started with, or a button will offer a rung the server has never
	heard of.
]]
function Rebirth.start(options: {
	levelling: Base,
	tiers: { Ladder.Tier },
	attribute: string?,
})
	assert(type(options) == "table", "Rebirth.start: options are required")
	assert(type(options.levelling) == "table", "Rebirth.start: `levelling` must be the base package's client half")
	assert(type(options.tiers) == "table", "Rebirth.start: `tiers` must be a ladder")

	base = options.levelling
	Ladder.setTiers(options.tiers)
	if options.attribute then
		attribute = options.attribute
	end

	if started then
		return
	end
	started = true

	local player = Players.LocalPlayer

	local function readCount()
		local value = player:GetAttribute(attribute)
		rebirths = math.max(0, math.floor(tonumber(value) or 0))
	end

	readCount()
	player:GetAttributeChangedSignal(attribute):Connect(function()
		readCount()
		notify()
	end)

	-- The level half. A rebirth becomes available by LEVELLING far more often than by
	-- rebirthing, so this is the subscription that actually drives the button.
	options.levelling.onChanged(function()
		notify()
	end)

	task.spawn(function()
		local container = ReplicatedStorage:WaitForChild(CONTAINER_NAME, 30)
		if not container then
			return
		end
		remote = container:WaitForChild(REQUEST_REMOTE_NAME, 30) :: RemoteEvent?
	end)
end

return Rebirth
