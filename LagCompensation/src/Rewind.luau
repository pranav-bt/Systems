--!strict

-- Rewound hit validation: pure geometry against the Snapshots history. The client
-- still claims what it saw (WYSIWYG prediction), but damage only lands on the
-- claim ∩ verify intersection — targets the server can confirm were inside the
-- attack volume at the attacker's reported time. GetPartBounds* can't query the
-- past, so characters are approximated as three stacked spheres (a capsule) along
-- the rewound root's up-vector and tested with plain math. Static damageables
-- (towers/bases) never move, so they're tested at their current pose.
--
-- Every rejection lands in a per-reason counter + the injected logger, so
-- tolerances are tuned with data instead of vibes.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local LagCompConfig = require(script.Parent.LagCompConfig)

local DEBUG_FOLDER_NAME = "HitboxDebug"

export type RejectReason =
	"BadPayload"
	| "FutureTimestamp"
	| "StaleTimestamp"
	| "RateLimited"
	| "NoSnapshots"
	| "OutOfVolume"
	| "LOSBlocked"
	| "FlightTime"
	| "RayDeviation"
	| "OverRange"
	| "MovementFlagged"
	| "NoPendingShot"

-- Only the three Snapshots methods this module reads, typed inline so Rewind does
-- not have to require Snapshots (the instance is injected).
type SnapshotsRef = {
	SampleAt: (character: Model, t: number) -> CFrame?,
	SamplesInWindow: (character: Model, t0: number, t1: number) -> { CFrame },
	GetExtents: (character: Model) -> Vector3,
}

export type Deps = {
	config: LagCompConfig.Config,
	logger: LagCompConfig.Logger,
	snapshots: SnapshotsRef,
	getLatency: (player: Player) -> number,
	isDamageable: (instance: Instance) -> boolean,
}

local Rewind = {}

function Rewind.new(deps: Deps)
	local Config = deps.config
	local Logger = deps.logger
	local Snapshots = deps.snapshots
	local getLatency = deps.getLatency
	local isDamageable = deps.isDamageable

	local rejectCounters: { [string]: number } = {}
	local rateBuckets: { [Player]: { [string]: { windowStart: number, count: number } } } = {}

	local function now(): number
		return workspace:GetServerTimeNow()
	end

	local api = {}

	function api.Reject(player: Player, reason: RejectReason)
		rejectCounters[reason] = (rejectCounters[reason] or 0) + 1
		Logger:Debug(`claim rejected [{reason}] {player.Name}`)
	end

	function api.GetCounters(): { [string]: number }
		return rejectCounters
	end

	-- Fixed 1s-bucket budget per player+key. Coarse (a burst can straddle the bucket
	-- edge for ~2x), but it only exists to stop floods, not to pace legit play.
	function api.AllowRate(player: Player, key: string, perSecond: number): boolean
		local buckets = rateBuckets[player]
		if not buckets then
			buckets = {}
			rateBuckets[player] = buckets
		end
		local bucket = buckets[key]
		local clock = os.clock()
		if not bucket or clock - bucket.windowStart >= 1 then
			buckets[key] = { windowStart = clock, count = 1 }
			return true
		end
		bucket.count += 1
		if bucket.count > perSecond then
			api.Reject(player, "RateLimited")
			return false
		end
		return true
	end

	function api.CleanupPlayer(player: Player)
		rateBuckets[player] = nil
	end

	local function isDamageTarget(target: Model): boolean
		return target:FindFirstChildOfClass("Humanoid") ~= nil or isDamageable(target)
	end

	local function isStaticDamageable(target: Model): boolean
		return target:FindFirstChildOfClass("Humanoid") == nil and isDamageable(target)
	end

	-- The old per-entry payload checks, in one place: real Model instances, not the
	-- attacker, damageable, capped.
	function api.SanitizeTargets(reported: unknown, attacker: Model): { Model }
		if typeof(reported) ~= "table" then
			return {}
		end

		local targets: { Model } = {}
		local scanned = 0
		for _, target in reported :: { any } do
			scanned += 1
			if scanned > Config.MAX_REPORTED_TARGETS then
				break
			end
			if typeof(target) ~= "Instance" or not target:IsA("Model") or target == attacker then
				continue
			end
			if isDamageTarget(target) then
				table.insert(targets, target)
			end
		end
		return targets
	end

	-- nil = unusable claim time (wrong type / NaN / outside the rewind horizon).
	function api.ClampClaimTime(t: unknown, player: Player): number?
		if typeof(t) ~= "number" or t ~= t or math.abs(t) == math.huge then
			api.Reject(player, "BadPayload")
			return nil
		end
		local serverNow = now()
		if t > serverNow + Config.FUTURE_SLACK then
			api.Reject(player, "FutureTimestamp")
			return nil
		end
		if t < serverNow - Config.MAX_REWIND then
			api.Reject(player, "StaleTimestamp")
			return nil
		end
		return math.min(t, serverNow)
	end

	-- The server's snapshot stream of a client-owned character lags that client's
	-- self-view by ~one-way latency, so the sample matching "where the attacker's
	-- client was at its own time t" arrives about one-way later.
	function api.AttackerPoseAt(player: Player, character: Model, root: BasePart, t: number): CFrame
		local sampleTime = math.min(now(), t + getLatency(player) / 2)
		return Snapshots.SampleAt(character, sampleTime) or root.CFrame
	end

	local function drawDebug(shape: Enum.PartType, cframe: CFrame, size: Vector3)
		if not Config.debugEnabled or not Config.showHitboxes then
			return
		end

		local folder = workspace:FindFirstChild(DEBUG_FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = DEBUG_FOLDER_NAME
			folder.Parent = workspace
		end

		local part = Instance.new("Part")
		part.Shape = shape
		part.Size = size
		part.CFrame = cframe
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.Material = Enum.Material.ForceField
		part.Color = Config.rewindHitboxColor
		part.Transparency = 0.5
		part.Parent = folder

		Debris:AddItem(part, Config.hitboxLifetime)
	end

	local function drawDebugPose(position: Vector3, radius: number)
		drawDebug(Enum.PartType.Ball, CFrame.new(position), Vector3.new(radius * 2, radius * 2, radius * 2))
	end

	-- Character hit volume: three stacked spheres along the pose's up-vector.
	-- Sphere-vs-box/sphere tests are trivial and the stack fits R15 well.
	local function characterSpheres(target: Model, pose: CFrame): ({ Vector3 }, number)
		local extents = Snapshots.GetExtents(target)
		local radius = math.max(extents.X, extents.Z) / 2 + Config.TARGET_RADIUS_PADDING
		local offset = math.max(extents.Y / 2 - radius, 0)
		local up = pose.UpVector
		return {
			pose.Position,
			pose.Position + up * offset,
			pose.Position - up * offset,
		}, radius
	end

	local function sphereTouchesBox(center: Vector3, radius: number, boxCFrame: CFrame, halfSize: Vector3): boolean
		local localPoint = boxCFrame:PointToObjectSpace(center)
		local clamped = Vector3.new(
			math.clamp(localPoint.X, -halfSize.X, halfSize.X),
			math.clamp(localPoint.Y, -halfSize.Y, halfSize.Y),
			math.clamp(localPoint.Z, -halfSize.Z, halfSize.Z)
		)
		return (localPoint - clamped).Magnitude <= radius
	end

	local function staticBoundingSphere(target: Model): (Vector3, number)
		local extents = target:GetExtentsSize()
		return target:GetPivot().Position, math.max(extents.X, extents.Y, extents.Z) / 2
	end

	local function poseWindow(t: number): (number, number)
		return t - Config.TARGET_REWIND_WINDOW, t + Config.TARGET_FORWARD_SLACK
	end

	-- Claim ∩ verify for a box volume (melee swings, dash sweeps): each claimed
	-- target must overlap the box at SOME pose it plausibly held around t.
	function api.ApproveBox(player: Player, claimed: { Model }, boxCFrame: CFrame, size: Vector3, t: number): { Model }
		local halfSize = size / 2
		drawDebug(Enum.PartType.Block, boxCFrame, size)

		local approved: { Model } = {}
		for _, target in claimed do
			if isStaticDamageable(target) then
				local center, radius = staticBoundingSphere(target)
				if sphereTouchesBox(center, radius, boxCFrame, halfSize) then
					table.insert(approved, target)
				else
					api.Reject(player, "OutOfVolume")
				end
				continue
			end

			local t0, t1 = poseWindow(t)
			local poses = Snapshots.SamplesInWindow(target, t0, t1)
			if #poses == 0 then
				api.Reject(player, "NoSnapshots")
				continue
			end

			local hit = false
			for _, pose in poses do
				local centers, radius = characterSpheres(target, pose)
				for _, center in centers do
					if sphereTouchesBox(center, radius, boxCFrame, halfSize) then
						hit = true
						drawDebugPose(pose.Position, radius)
						break
					end
				end
				if hit then
					break
				end
			end

			if hit then
				table.insert(approved, target)
			else
				api.Reject(player, "OutOfVolume")
			end
		end
		return approved
	end

	-- Claim ∩ verify for a sphere volume (AoE pulses, splash, direct impacts).
	function api.ApproveRadius(player: Player, claimed: { Model }, center: Vector3, radius: number, t: number): { Model }
		drawDebug(Enum.PartType.Ball, CFrame.new(center), Vector3.new(radius * 2, radius * 2, radius * 2))

		local approved: { Model } = {}
		for _, target in claimed do
			if isStaticDamageable(target) then
				local targetCenter, targetRadius = staticBoundingSphere(target)
				if (targetCenter - center).Magnitude <= radius + targetRadius then
					table.insert(approved, target)
				else
					api.Reject(player, "OutOfVolume")
				end
				continue
			end

			local t0, t1 = poseWindow(t)
			local poses = Snapshots.SamplesInWindow(target, t0, t1)
			if #poses == 0 then
				api.Reject(player, "NoSnapshots")
				continue
			end

			local hit = false
			for _, pose in poses do
				local centers, sphereRadius = characterSpheres(target, pose)
				for _, sphereCenter in centers do
					if (sphereCenter - center).Magnitude <= radius + sphereRadius then
						hit = true
						drawDebugPose(pose.Position, sphereRadius)
						break
					end
				end
				if hit then
					break
				end
			end

			if hit then
				table.insert(approved, target)
			else
				api.Reject(player, "OutOfVolume")
			end
		end
		return approved
	end

	-- Static-world occlusion only: live characters/NPC rigs/cosmetics are excluded,
	-- so this answers "does a wall sit between muzzle and impact". A hit closer than
	-- LOS_IMPACT_SLACK to the claimed impact IS the surface the bolt struck.
	--[[
		The line-of-sight filter, REUSED rather than rebuilt.

		This is the hottest path the module has -- one call per target per claim -- and it used
		to iterate every player, build a fresh exclude table and allocate a new RaycastParams
		on each of them. Across a full lobby that is a steady stream of garbage produced to
		describe a world that had not changed.

		Both parts are cached now. The params object is reused because RaycastParams is
		mutable; the exclude list is rebuilt only when it can actually have changed, which is
		when a player joins, leaves or respawns. `losParamsDirty` is the flag those signals
		set, and it starts true so the first call always builds one.
	]]
	local losParams: RaycastParams? = nil
	local losExclude: { Instance } = {}
	local losParamsDirty = true

	local function markLosDirty()
		losParamsDirty = true
	end

	Players.PlayerAdded:Connect(function(player: Player)
		markLosDirty()
		-- A respawn swaps the Character out, so the cached list holds a destroyed one.
		player.CharacterAdded:Connect(markLosDirty)
		player.CharacterRemoving:Connect(markLosDirty)
	end)
	Players.PlayerRemoving:Connect(markLosDirty)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(markLosDirty)
		player.CharacterRemoving:Connect(markLosDirty)
	end

	local function losRaycastParams(): RaycastParams
		local params = losParams
		if not params then
			params = RaycastParams.new()
			;(params :: RaycastParams).FilterType = Enum.RaycastFilterType.Exclude
			;(params :: RaycastParams).RespectCanCollide = true
			losParams = params
		end
		if not losParamsDirty then
			return params :: RaycastParams
		end
		losParamsDirty = false

		table.clear(losExclude)
		for _, player in Players:GetPlayers() do
			if player.Character then
				table.insert(losExclude, player.Character)
			end
		end
		for _, name in Config.losExcludeFolderNames do
			local folder = workspace:FindFirstChild(name)
			if folder then
				table.insert(losExclude, folder)
			end
		end
		--[[
			Reassigned rather than mutated in place. FilterDescendantsInstances hands back a
			COPY on read and takes a copy on write, so mutating what you read changes nothing
			-- the assignment is what actually updates the filter.
		]]
		;(params :: RaycastParams).FilterDescendantsInstances = losExclude
		return params :: RaycastParams
	end

	--[[
		Exposed so a host that moves the excluded set itself -- streaming a folder in, spawning
		an NPC into one -- can say so. Cheap: it only sets a flag.
	]]
	function api.InvalidateLineOfSightFilter()
		markLosDirty()
	end

	function api.HasLineOfSight(from: Vector3, to: Vector3): boolean
		local params = losRaycastParams()
		local result = workspace:Raycast(from, to - from, params)
		if not result then
			return true
		end
		return (result.Position - to).Magnitude <= Config.LOS_IMPACT_SLACK
	end

	return api
end

return Rewind
