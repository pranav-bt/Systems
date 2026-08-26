--!strict

-- Ring-buffer position history for every combatant (players + server-owned NPC
-- rigs), stamped on the engine-synced workspace:GetServerTimeNow() clock, so hit
-- claims can be validated against where characters actually WERE at the attacker's
-- reported time instead of where they are now (Rewind.luau does the geometry).
--
-- The recorder doubles as the movement-sanity checkpoint: it already sees every
-- character's motion at a fixed rate, so impossible steps (teleports, sustained
-- super-speed) are flagged here and the player's hit claims are rejected for a
-- short window. Flag + log + bound only — never kick (a false positive costs one
-- swing, not the session). Legitimate bursts (knockback, dashes, rally snaps,
-- spawn teleports) are excused via NoteAuthorizedBurst / Reset.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LagCompConfig = require(script.Parent.LagCompConfig)

-- R15 at default scale when GetExtentsSize isn't available yet.
local DEFAULT_EXTENTS = Vector3.new(4, 5.2, 4)

type Record = {
	times: { number },
	cframes: { CFrame },
	head: number, -- write index of the newest sample (0 = empty)
	count: number,
	extents: Vector3?,
	player: Player?, -- nil for NPC rigs (sanity checks skip non-players)
	graceUntil: number,
	flaggedUntil: number,
}

export type Deps = {
	config: LagCompConfig.Config,
	logger: LagCompConfig.Logger,
	scheduleSnapshots: ((interval: number, record: () -> ()) -> (() -> ())?)?,
}

local Snapshots = {}

function Snapshots.new(deps: Deps)
	local Config = deps.config
	local Logger = deps.logger
	-- Server-owned non-player character folders whose Models get pose history too,
	-- so the rewind validation can confirm hits on them (players hit them exactly
	-- like each other). Both hold NPC rigs the server simulates.
	local NPC_FOLDER_NAMES = Config.npcFolderNames

	local records: { [Model]: Record } = {}
	local flagCounters: { [string]: number } = {}

	local snapshotConnection: RBXScriptConnection? = nil
	local snapshotDisconnect: (() -> ())? = nil

	local function now(): number
		return workspace:GetServerTimeNow()
	end

	local function newRecord(player: Player?): Record
		return {
			times = table.create(Config.SNAPSHOT_CAPACITY),
			cframes = table.create(Config.SNAPSHOT_CAPACITY),
			head = 0,
			count = 0,
			extents = nil,
			player = player,
			graceUntil = 0,
			flaggedUntil = 0,
		}
	end

	-- Index of the k-th newest sample (k = 0 is the newest).
	local function ringIndex(record: Record, k: number): number
		return (record.head - 1 - k) % Config.SNAPSHOT_CAPACITY + 1
	end

	local function bumpFlag(record: Record, reason: string, detail: string)
		flagCounters[reason] = (flagCounters[reason] or 0) + 1
		local wasFlagged = now() < record.flaggedUntil
		record.flaggedUntil = now() + Config.FLAG_CLAIM_REJECT_SECONDS
		if not wasFlagged then
			local name = if record.player then record.player.Name else "?"
			Logger:Warn(`movement flag [{reason}] {name}: {detail}`)
		end
	end

	-- Teleport = one impossible step; sustained = average horizontal speed over the
	-- window well past anything walk/dash/knockback can produce. Horizontal-only so
	-- free-fall never trips it.
	local function checkMovementSanity(record: Record, position: Vector3)
		if not record.player or record.count < 1 or now() < record.graceUntil then
			return
		end

		local previous = record.cframes[record.head].Position
		local step = (position - previous).Magnitude
		if step > Config.TELEPORT_STEP_STUDS then
			bumpFlag(record, "Teleport", `{math.floor(step)} studs in one snapshot`)
			return
		end

		local windowStart = now() - Config.SPEED_WINDOW
		local traveled = 0
		local spanStart = record.times[record.head]
		for k = 1, record.count - 1 do
			local index = ringIndex(record, k)
			if record.times[index] < windowStart then
				break
			end
			local a = record.cframes[index].Position
			local b = record.cframes[ringIndex(record, k - 1)].Position
			local delta = b - a
			traveled += Vector3.new(delta.X, 0, delta.Z).Magnitude
			spanStart = record.times[index]
		end
		local span = record.times[record.head] - spanStart
		if span >= Config.SPEED_WINDOW * 0.5 and traveled / span > Config.SUSTAINED_SPEED_LIMIT then
			bumpFlag(record, "Speed", `{math.floor(traveled / span)} studs/s over {span}s`)
		end
	end

	local function push(character: Model, record: Record)
		local root = character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		-- Dead characters stop recording but keep their history, so a claim that was
		-- in flight when they died still resolves geometrically.
		if not humanoid or humanoid.Health <= 0 then
			return
		end

		if not record.extents then
			record.extents = character:GetExtentsSize()
		end

		checkMovementSanity(record, root.Position)

		record.head = record.head % Config.SNAPSHOT_CAPACITY + 1
		record.times[record.head] = now()
		record.cframes[record.head] = root.CFrame
		record.count = math.min(record.count + 1, Config.SNAPSHOT_CAPACITY)
	end

	local function record()
		for character, characterRecord in records do
			if character.Parent then
				push(character, characterRecord)
			else
				records[character] = nil
			end
		end
	end

	local api = {}

	-- Interpolated pose at time t: clamps future times to the newest sample, returns
	-- nil when t predates the character's recorded existence (you can't be hit at a
	-- time you weren't there).
	function api.SampleAt(character: Model, t: number): CFrame?
		local characterRecord = records[character]
		if not characterRecord or characterRecord.count == 0 then
			return nil
		end

		local newestIndex = characterRecord.head
		if t >= characterRecord.times[newestIndex] then
			return characterRecord.cframes[newestIndex]
		end

		for k = 1, characterRecord.count - 1 do
			local index = ringIndex(characterRecord, k)
			local sampleTime = characterRecord.times[index]
			if t >= sampleTime then
				local nextIndex = ringIndex(characterRecord, k - 1)
				local nextTime = characterRecord.times[nextIndex]
				local alpha = if nextTime > sampleTime then (t - sampleTime) / (nextTime - sampleTime) else 0
				return characterRecord.cframes[index]:Lerp(characterRecord.cframes[nextIndex], alpha)
			end
		end

		return nil
	end

	-- Every pose the character plausibly held in [t0, t1]: the interpolated endpoint
	-- poses plus each raw sample inside the window, so a fast strafe can't slip
	-- between two samples.
	function api.SamplesInWindow(character: Model, t0: number, t1: number): { CFrame }
		local characterRecord = records[character]
		if not characterRecord or characterRecord.count == 0 then
			return {}
		end

		local poses: { CFrame } = {}
		local startPose = api.SampleAt(character, t0)
		if startPose then
			table.insert(poses, startPose)
		end
		for k = characterRecord.count - 1, 0, -1 do
			local index = ringIndex(characterRecord, k)
			local sampleTime = characterRecord.times[index]
			if sampleTime > t0 and sampleTime < t1 then
				table.insert(poses, characterRecord.cframes[index])
			end
		end
		local endPose = api.SampleAt(character, t1)
		if endPose then
			table.insert(poses, endPose)
		end
		return poses
	end

	function api.GetExtents(character: Model): Vector3
		local characterRecord = records[character]
		return (characterRecord and characterRecord.extents) or DEFAULT_EXTENTS
	end

	--[[
		Re-reads a character's hitbox size. Returns whether it was tracked.

		EXTENTS ARE CACHED ON FIRST SIGHT, because GetExtentsSize walks the whole model and
		doing that twenty times a second per character, to answer a question that almost never
		changes, is pure waste. The cost of caching is that a character which DOES change shape
		keeps the size it had when it was first recorded -- an R6/R15 swap, a size powerup, a
		vehicle seat -- and every later hit is then validated against the wrong volume, in
		whichever direction the change went.

		There is no reliable signal to watch for that. A model's extents can change from a
		scale, a limb swap, an accessory, or a humanoid description, and which of those counts
		as "the character is a different size now" is a game's judgement rather than this
		module's. So it is an explicit call, made by whoever changed the size.

		Pass `size` when the caller already knows it -- a host scaling a rig by a known factor
		has the answer and can skip the walk entirely.
	]]
	function api.RefreshExtents(character: Model, size: Vector3?): boolean
		local characterRecord = records[character]
		if not characterRecord then
			return false
		end
		characterRecord.extents = size or character:GetExtentsSize()
		return true
	end

	-- Wipe history across an authorized discontinuity (spawn-point teleport): the
	-- next sample has no predecessor, so the jump can neither flag nor be rewound
	-- through.
	function api.Reset(character: Model)
		local characterRecord = records[character]
		if characterRecord then
			characterRecord.head = 0
			characterRecord.count = 0
		end
	end

	-- Excuse a burst of legitimately fast motion (knockback, dash, rally snap).
	function api.NoteAuthorizedBurst(character: Model, duration: number?)
		local characterRecord = records[character]
		if characterRecord then
			characterRecord.graceUntil =
				math.max(characterRecord.graceUntil, now() + (duration or Config.BURST_GRACE_SECONDS))
		end
	end

	function api.IsClaimRejected(player: Player): boolean
		local character = player.Character
		local characterRecord = character and records[character]
		return characterRecord ~= nil and now() < characterRecord.flaggedUntil
	end

	function api.GetFlagCounters(): { [string]: number }
		return flagCounters
	end

	-- NPC rigs are tracked with player = nil, so movement sanity is skipped (they
	-- don't make claims) but pose history still records for rewind.
	local function trackNpc(child: Instance)
		if child:IsA("Model") and not records[child] then
			records[child] = newRecord(nil)
		end
	end

	local function watchNpcFolder(folder: Instance)
		for _, child in folder:GetChildren() do
			trackNpc(child)
		end
		folder.ChildAdded:Connect(trackNpc)
		folder.ChildRemoved:Connect(function(child)
			if child:IsA("Model") then
				records[child] = nil
			end
		end)
	end

	local function isNpcFolderName(name: string): boolean
		for _, folderName in NPC_FOLDER_NAMES do
			if name == folderName then
				return true
			end
		end
		return false
	end

	function api.start()
		local function onCharacterAdded(player: Player, character: Model)
			records[character] = newRecord(player)
		end

		Players.PlayerAdded:Connect(function(player)
			player.CharacterAdded:Connect(function(character)
				onCharacterAdded(player, character)
			end)
			player.CharacterRemoving:Connect(function(character)
				records[character] = nil
			end)
		end)
		for _, player in Players:GetPlayers() do
			player.CharacterAdded:Connect(function(character)
				onCharacterAdded(player, character)
			end)
			player.CharacterRemoving:Connect(function(character)
				records[character] = nil
			end)
			if player.Character then
				onCharacterAdded(player, player.Character)
			end
		end

		for _, name in NPC_FOLDER_NAMES do
			local folder = workspace:FindFirstChild(name)
			if folder and folder:IsA("Folder") then
				watchNpcFolder(folder)
			end
		end
		workspace.ChildAdded:Connect(function(child: Instance)
			if child:IsA("Folder") and isNpcFolderName(child.Name) then
				watchNpcFolder(child)
			end
		end)

		-- Fixed-rate recorder. Replaces the original ServerScheduler.interval on the
		-- "PostSimulation" schedule (which is itself backed by RunService.Heartbeat):
		-- accumulate real delta, run record() at ~SNAPSHOT_HZ, spawn so a slow record
		-- can't stall the frame. A caller may inject its own scheduler; otherwise we
		-- self-tick on Heartbeat.
		local interval = 1 / Config.SNAPSHOT_HZ
		if deps.scheduleSnapshots then
			snapshotDisconnect = deps.scheduleSnapshots(interval, record)
		else
			local accumulated = 0
			snapshotConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
				accumulated += deltaTime
				if accumulated < interval then
					return
				end
				accumulated %= interval
				debug.profilebegin("LagCompensationSnapshots")
				task.spawn(record)
				debug.profileend()
			end)
		end
	end

	-- Stop the recorder loop (disconnects the Heartbeat connection or invokes the
	-- injected scheduler's cleanup). Pose history is left intact.
	function api.stop()
		if snapshotConnection then
			snapshotConnection:Disconnect()
			snapshotConnection = nil
		end
		if snapshotDisconnect then
			snapshotDisconnect()
			snapshotDisconnect = nil
		end
	end

	return api
end

return Snapshots
