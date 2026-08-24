--!strict

-- Per-pet tick hooks. A consumer registers, per pet id, how often that pet ticks and what to
-- run each time. Every live pet of that id then keeps its own independent schedule, so two
-- copies of the same pet do not fire together and one player's pets never gate another's.
--
-- Nothing here knows or cares what a handler does — that behaviour belongs to the host game,
-- which is what keeps this module free of any dependency on it.

local RunService = game:GetService("RunService")

local Rig = require(script.Parent.Rig)

-- Everything a handler needs to act on the pet and its owner, passed as one table so fields
-- can be added later without breaking a consumer's function signature.
export type TickContext = {
	player: Player,
	petId: string,
	uid: string, -- unique per live pet, so a handler can key its own state per instance
	model: Model,
	root: BasePart,
	slotKey: string,
	level: number,
	interval: number, -- the interval actually used, after any per-level override
	dt: number, -- seconds since this pet's previous tick; at least interval, more after a stall
	elapsed: number, -- seconds this pet has been alive
}

export type TickHandler = (context: TickContext) -> ()

type Behaviour = {
	interval: number,
	onTick: TickHandler,
}

type Entry = {
	rig: Rig.Rig,
	player: Player,
	accumulator: number,
	elapsed: number,
}

local Ticker = {}

local _behaviours: { [string]: Behaviour } = {}
local _entries: { Entry } = {}
local _connection: RBXScriptConnection? = nil

-- ── Scheduling ────────────────────────────────────────────────────────────────

local function indexOf(rig: Rig.Rig): number?
	for index, entry in _entries do
		if entry.rig == rig then
			return index
		end
	end
	return nil
end

local function step(deltaTime: number)
	debug.profilebegin("Companions.tick")
	for index = #_entries, 1, -1 do
		local entry = _entries[index]
		local rig = entry.rig
		-- A despawned pet or a player who left drops out here rather than needing every
		-- teardown path to remember to detach.
		if rig.anchor.Parent == nil or entry.player.Parent == nil then
			table.remove(_entries, index)
			continue
		end
		local behaviour = _behaviours[rig.petId]
		if not behaviour then
			table.remove(_entries, index)
			continue
		end

		-- Read per frame rather than cached at attach time: a level change rewrites the pet's
		-- settings in place, and the new cadence should take effect from the next tick on.
		local interval = rig.settings.tickInterval or behaviour.interval

		entry.accumulator += deltaTime
		entry.elapsed += deltaTime
		if entry.accumulator < interval then
			continue
		end

		local dt = entry.accumulator
		-- Keep the remainder so the cadence does not drift, but never bank more than one
		-- interval: a long frame or a server stall must not fire a burst of catch-up ticks.
		entry.accumulator = math.min(entry.accumulator - interval, interval)

		-- Spawned, not called: consumer code is free to yield, and a yield inside this loop
		-- would stall every other pet's schedule. It also keeps their errors out of here.
		task.spawn(behaviour.onTick, {
			player = entry.player,
			petId = rig.petId,
			uid = rig.uid,
			model = rig.model,
			root = rig.root,
			slotKey = rig.slotKey,
			level = rig.level,
			interval = interval,
			dt = dt,
			elapsed = entry.elapsed,
		})
	end
	debug.profileend()

	-- No pet is ticking, so nothing should be running per frame either.
	if #_entries == 0 and _connection then
		_connection:Disconnect()
		_connection = nil
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function Ticker.has(petId: string): boolean
	return _behaviours[petId] ~= nil
end

-- interval is in seconds between ticks; 0 means every frame. Returns false when the
-- registration is unusable, so a typo in host code is reported instead of silently doing
-- nothing forever.
function Ticker.define(petId: string, interval: number, onTick: TickHandler): boolean
	if type(petId) ~= "string" or petId == "" then
		warn(`[Companions] setTick needs a pet id string.`)
		return false
	end
	if type(onTick) ~= "function" then
		warn(`[Companions] setTick for "{petId}" needs a function to run.`)
		return false
	end
	if type(interval) ~= "number" or interval ~= interval or interval < 0 then
		warn(`[Companions] setTick for "{petId}" got an invalid interval; using 0 (every frame).`)
		interval = 0
	end

	_behaviours[petId] = { interval = interval, onTick = onTick }
	return true
end

function Ticker.undefine(petId: string)
	_behaviours[petId] = nil
	for index = #_entries, 1, -1 do
		if _entries[index].rig.petId == petId then
			table.remove(_entries, index)
		end
	end
end

-- Starts this pet ticking if its id has a handler. Safe to call again for a pet that is
-- already scheduled: its accumulator is left alone so re-registering does not reset cadence.
function Ticker.attach(player: Player, rig: Rig.Rig)
	if not _behaviours[rig.petId] then
		return
	end
	if indexOf(rig) then
		return
	end

	table.insert(_entries, { rig = rig, player = player, accumulator = 0, elapsed = 0 })
	if not _connection then
		_connection = RunService.Heartbeat:Connect(step)
	end
end

function Ticker.detach(rig: Rig.Rig)
	local index = indexOf(rig)
	if index then
		table.remove(_entries, index)
	end
end

return Ticker
