--!strict

-- The only place a rebirth count is written.
--
-- The deal is the ladder's -- which level each rung asks for and what it pays -- and this
-- file is the door: it decides whether the player may take the next rung, and it performs
-- the trade.
--
-- IDENTITY, AND NOT EVEN THAT. The request carries NOTHING. There is no tier index to
-- validate, no level to trust and no multiplier on the wire: the rung is the one after the
-- count in the player's own profile, and the requirement is read out of the ladder beside
-- it. A forged call is therefore indistinguishable from a real one and does exactly the same
-- thing, which is the strongest form of the rule -- there is no argument that could be wrong.
--
-- WHAT IT WRITES, and the list is deliberately this short:
--
--   rebirths   += 1
--   level      -> the starting level
--   experience -> 0
--
-- Nothing else is touched, because a rebirth is paid for with the LEVEL and nothing else.
-- What the reset actually costs is whatever the host scales by `Curve.rewardMultiplier` --
-- that is what a level was worth in the first place, so paying it back is the trade rather
-- than a side effect.
--
-- ANYTHING A LEVEL UNLOCKS PERMANENTLY IS A TRAP, and it is worth knowing before authoring a
-- ladder: a slot, a weapon or an area gated on `level >= N` is taken BACK by a rebirth, and
-- the player will read that as the feature stealing from them. Gate permanent unlocks on the
-- rebirth count, on a purchase, or on a flag the reset does not touch.
--
-- THE MULTIPLIER IS APPLIED BY THE BASE PACKAGE, which this registers with on start and then
-- never thinks about again. Nothing here has to tell anything about the new rate: the base
-- reads the count off the profile on every grant and every rate announcement.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ladder = require(script.Parent.shared)

local Rebirth = {}

Rebirth.Ladder = Ladder

local CONTAINER_NAME = "LevellingRemotes"
local REQUEST_REMOTE_NAME = "RequestRebirth"
local MULTIPLIER_NAME = "rebirth"

export type Config = {
	-- How many rebirths this player has. 0, not nil, for one who has never taken any.
	read: (player: Player) -> number?,
	-- Stores the new count. Not expected to yield or to hit a DataStore.
	write: (player: Player, rebirths: number) -> (),
	-- The attribute the count is published under, so a client can draw it without a request.
	attribute: string,
}

local config: Config = {
	read = function()
		return nil
	end,
	write = function() end,
	attribute = "Rebirths",
}

--[[
	The base package. Held rather than required, because this addon must work against whatever
	the host actually installed -- a vendored copy, a renamed folder, a wrapper of their own --
	and a hardcoded `require` would make the two packages one.
]]
type Base = {
	get: (player: Player) -> (number, number),
	reset: (player: Player) -> (),
	addMultiplier: (name: string, fn: (player: Player) -> number) -> (),
	refreshRate: (player: Player) -> (),
}

local base: Base? = nil
local started = false

--[[
	A host gate, asked before every rebirth. Return false to refuse.

	IT EXISTS BECAUSE THE STATE THAT FORBIDS A REBIRTH IS NEVER IN THIS PACKAGE. Mid-run,
	mid-match, in a cutscene, on a cooldown: whoever owns that state answers here, and this
	module refuses without being told a new rule exists.

	Asked FIRST, before the profile is read, so a refusal during the common case -- a player
	hammering a button during a run -- costs nothing at all.

	Fails CLOSED: a gate that errors refuses the rebirth. The trade is irreversible and the
	player can simply press again, which is the cheap direction of that failure.
]]
local gate: ((player: Player) -> boolean)? = nil

function Rebirth.setGate(fn: ((player: Player) -> boolean)?)
	gate = fn
end

-- ── The signal ────────────────────────────────────────────────────────────────

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
	Fires (player, rebirths, tier) after a rebirth has fully landed.

	THE TIER IS HANDED OVER because that is where `rewards` lives -- a host paying a title, a
	cosmetic or a lump of currency for a rung reads it here rather than looking the count back
	up and hoping it matches.

	Fired LAST, after the profile, the level reset and the attribute all agree: a subscriber
	must never be able to read a half-applied trade.
]]
local rebirthedSignal, fireRebirthed = makeSignal()
Rebirth.rebirthed = rebirthedSignal

-- ── Reading ───────────────────────────────────────────────────────────────────

function Rebirth.get(player: Player): number
	local ok, count = pcall(config.read, player)
	if not ok then
		return 0
	end
	return math.max(0, math.floor(tonumber(count) or 0))
end

-- Whether this player may rebirth right now: the ladder AND the host's gate.
function Rebirth.canRebirth(player: Player): boolean
	local installed = base
	if not installed then
		return false
	end
	if gate then
		local ok, allowed = pcall(gate, player)
		if not ok or not allowed then
			return false
		end
	end
	local level = installed.get(player)
	return Ladder.canRebirth(Rebirth.get(player), level)
end

-- ── The trade ─────────────────────────────────────────────────────────────────

--[[
	Takes the next rebirth. Returns the tier taken, or nil if it was refused.

	NO DEBOUNCE, unlike a high-frequency remote: THE STATE CHECK IS THE GUARD. A second call
	arrives at the starting level, which no rung accepts, so a player hammering the button
	gets one rebirth and a series of cheap table reads rather than a queue of them.

	A refusal is silent by construction. The button is disabled by the same `canRebirth` the
	check below uses, so the only calls that can be refused are ones no honest client sends.
]]
function Rebirth.rebirth(player: Player): Ladder.Tier?
	local installed = base
	if not installed then
		return nil
	end

	-- Before the profile read, so a refusal during a run costs nothing at all.
	if gate then
		local ok, allowed = pcall(gate, player)
		if not ok or not allowed then
			return nil
		end
	end

	local rebirths = Rebirth.get(player)
	local tier = Ladder.nextTier(rebirths)
	if not tier then
		return nil
	end

	local level = installed.get(player)
	if level < tier.requiredLevel then
		return nil
	end

	local taken = rebirths + 1

	--[[
		THE COUNT IS WRITTEN BEFORE THE LEVEL IS RESET, and the order is the whole safety
		property. The base package reads the count on every grant to build its multiplier, so
		between these two lines the player is at their old level with the NEW multiplier --
		which pays them slightly too much for an instant. The other order leaves them at level
		1 with the OLD multiplier, and if anything in between fails the player has paid the
		price and received nothing. Overpaying for one frame is recoverable; the trade going
		one way only is not.
	]]
	pcall(config.write, player, taken)
	installed.reset(player)
	-- Last of the three, and the one a client watches to know the trade landed.
	player:SetAttribute(config.attribute, taken)

	--[[
		NOT REDUNDANT, though it looks it against the base package that ships beside this one.

		`reset` happens to re-announce the rate today, so this second ask usually dedupes to
		nothing. But the base is depended on by SHAPE -- four named functions -- and nothing in
		that contract says `reset` announces anything at all. A host wrapping the base, or a
		later version that stops announcing, would otherwise leave every rebirthed player
		earning at the old displayed tempo until their next zone change, which for someone
		standing still is never.
	]]
	installed.refreshRate(player)

	fireRebirthed(player, taken, tier)
	return tier
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

--[[
	Publishes a player's stored count onto their Player object.

	Call it once their profile has loaded, beside the base package's own `publish`. Separate
	for the same reason: only the host knows when a profile is real, and publishing 0 first
	would flash "no rebirths" at a player who has ten.
]]
function Rebirth.publish(player: Player)
	player:SetAttribute(config.attribute, Rebirth.get(player))
end

--[[
	Installs the addon over a started base package. Idempotent.

	`levelling` is passed IN rather than required, so this package depends on the base by
	SHAPE and not by path -- the same rule the rest of this repo composes by. Anything with
	`get`, `reset`, `addMultiplier` and `refreshRate` will do, which is also what makes this
	testable against a stub.
]]
function Rebirth.start(options: {
	levelling: Base,
	tiers: { Ladder.Tier },
	read: ((player: Player) -> number?)?,
	write: ((player: Player, rebirths: number) -> ())?,
	attribute: string?,
	gate: ((player: Player) -> boolean)?,
})
	assert(type(options) == "table", "Rebirth.start: options are required")
	assert(type(options.levelling) == "table", "Rebirth.start: `levelling` must be the started base package")
	assert(type(options.tiers) == "table", "Rebirth.start: `tiers` must be a ladder")

	base = options.levelling
	Ladder.setTiers(options.tiers)

	if options.read then
		config.read = options.read
	end
	if options.write then
		config.write = options.write
	end
	if options.attribute then
		config.attribute = options.attribute
	end
	if options.gate then
		gate = options.gate
	end

	--[[
		The one line that makes a rebirth worth anything.

		ABOVE THE IDEMPOTENCE GUARD, and deliberately. Registration is by NAME, so installing
		twice replaces rather than squaring -- there is nothing to protect against here. What
		the guard WOULD break is a second `start` naming a different base: `base` above would
		be reassigned and the new package would never be told about the multiplier, so every
		rebirth in the game would quietly stop being worth anything. A silent x1 is the worst
		failure this package has.
	]]
	options.levelling.addMultiplier(MULTIPLIER_NAME, function(player: Player)
		return Ladder.multiplierFor(Rebirth.get(player))
	end)

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

	local remote = (container :: Folder):FindFirstChild(REQUEST_REMOTE_NAME) :: RemoteEvent?
	if not remote then
		local created = Instance.new("RemoteEvent")
		created.Name = REQUEST_REMOTE_NAME
		created.Parent = container
		remote = created
	end -- No parameters past the player, and that is the point: the remote carries nothing, so
	-- anything a crafted call sends with it is not even received, let alone validated.
	(remote :: RemoteEvent).OnServerEvent:Connect(function(player: Player)
		Rebirth.rebirth(player)
	end)
end

return Rebirth
