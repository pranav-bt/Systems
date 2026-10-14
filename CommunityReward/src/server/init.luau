--!strict

-- CommunityReward: verify that a player belongs to a Roblox group, then pay them
-- once, ever.
--
-- Started in CA, which ported it from RottenTomato. The two games differ only
-- in what the reward IS -- one pays gold, the other hands over a companion -- so
-- that is the seam this package is built around, and everything else here is the
-- part that was identical in both.
--
-- THE CLIENT PROVES NOTHING. The claim remote carries no arguments at all: no
-- amount, no membership proof, no reward name. This module checks live membership
-- itself, checks the profile's one-time flag itself, and calls the host's grant.
-- There is nothing on the way in to forge.
--
-- LIVE MEMBERSHIP, NOT Player:IsInGroup. IsInGroup is cached when the player joins
-- the SERVER, so somebody who joins the group and claims in the same session would
-- be refused and told to rejoin -- and that is exactly the flow this feature walks
-- them through, so the cached answer is wrong precisely when it matters. The
-- default check calls GroupService:GetGroupsAsync, which is a web call and
-- therefore YIELDS; the in-flight guard below exists for that.
--
-- THE MEMBERSHIP CHECK IS THREE-VALUED. true / false / nil, where nil means the
-- lookup failed. Telling a member they are not one is the single outcome this must
-- never produce, so a failed web call becomes a retryable error rather than a
-- refusal.
--
-- WHAT ACTUALLY MAKES THIS PAY ONCE is that the profile is re-read after the
-- yielding lookup and the flag is written in the SAME synchronous block. There is
-- no yield between the re-read and the write, and coroutines only switch on a
-- yield, so no second claim can observe an unflagged profile once the first has
-- got that far. The in-flight guard below is not what closes that window --
-- removing it in a mutation test still paid exactly once. It earns its place for a
-- different reason, stated where it is declared.
--
-- IDEMPOTENT BY THE FLAG, NOT BY WHAT IT GRANTED. "Do they already have the
-- reward" cannot distinguish a second claim from a first: a currency balance moves
-- for other reasons and a collectible may be held more than once. The flag is the
-- whole gate, and it is written BEFORE the grant. A failure between the two leaves
-- a player marked as paid who was not, which can be put right by hand -- rather
-- than an unmarked player who can claim again, which nobody can take back. That is
-- also why `rewardReady` is checked before the flag: a misconfigured reward must
-- leave the claim still there to be made.
--
-- NO COPY LIVES HERE. Refusals come back as reason KEYS, never sentences. Two
-- games will word this window differently even though the flow is identical, and a
-- package that ships strings forces either English or a localisation dependency.

local CollectionService = game:GetService("CollectionService")
local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CommunityReward = {}

local CONTAINER_NAME = "CommunityRewardRemotes"
local CLAIM_REMOTE_NAME = "Claim" -- client -> server, carries nothing
local RESULT_REMOTE_NAME = "Result" -- server -> client, (ok, reason)
local OPEN_REMOTE_NAME = "Open" -- server -> client, "a prompt was triggered"

local DEFAULT_CLAIMED_FIELD = "communityRewardClaimed"
local PROMPT_NAME = "CommunityRewardPrompt"
local DEFAULT_PROMPT_DISTANCE = 12

-- How long to keep looking for a part to hang a prompt on, and how often. Ten
-- seconds is far longer than a stream-in takes and short enough that a genuinely
-- partless prop still says so.
local ANCHOR_WAIT = 10
local ANCHOR_POLL = 0.25

-- Every refusal this module can produce. Exported so a host can exhaustively map
-- them to its own copy and fail its own build when a new one appears.
export type Reason = "AlreadyClaimed" | "Unavailable" | "NotInGroup" | "NotReady" | "Failed"

export type ClaimResult = {
	ok: boolean,
	-- Absent on success.
	reason: Reason?,
}

export type Config = {
	-- The group to verify. 0 (or absent) disables the feature: every claim is
	-- refused as "Unavailable" and a warning is issued once at start. That is the
	-- safe failure -- an unset id must never reward everybody, and a GUESSED id
	-- would pay this game's players for joining somebody else's community.
	groupId: number?,

	-- Persistence. Returns the player's profile table, or nil when it is not
	-- loaded -- a player still joining, or one who has already left. Called MORE
	-- THAN ONCE per claim, deliberately: the membership lookup yields, and the
	-- profile a claim started with is not necessarily one that still exists.
	document: (player: Player) -> { [string]: any }?,

	-- The boolean field on that table recording the claim. Must persist.
	claimedField: string?,

	-- THE REWARD, and the only thing the two known ports disagree about. Called
	-- once, after the flag is written. It must not be able to refuse -- by the time
	-- it runs the player is already marked paid -- so anything that could make the
	-- reward ungrantable belongs in `rewardReady` instead.
	grant: (player: Player) -> (),

	-- Whether the reward can be granted AT ALL right now: a content id that
	-- actually exists, an item still in stock. Checked before the membership call
	-- and before the flag, so a misconfigured reward costs a refusal rather than
	-- marking somebody paid for nothing. Absent means "always ready".
	rewardReady: (() -> boolean)?,

	-- Run after a successful claim, for whatever mirror the client reads to draw
	-- the claimed state without a remote of its own.
	onClaimed: ((player: Player) -> ())?,

	-- Membership lookup, injected. Returns true / false / nil-on-failure. Defaults
	-- to GroupService:GetGroupsAsync. Replaceable so a game can use a cached
	-- social graph of its own -- and so this flow can be tested without a network.
	isInGroup: ((player: Player, groupId: number) -> boolean?)?,

	-- The lobby prop. A TAG IS THE WHOLE SETUP: everything wearing it gets a
	-- prompt built on it, now and whenever one arrives -- tagged after start,
	-- streamed back in, or the art landing for the first time. nil skips prompt
	-- handling entirely, for a game that opens its window from its own UI.
	promptTag: string?,
	promptActionText: string?,
	promptObjectText: string?,
	promptDistance: number?,

	-- Inject pre-made remotes to skip self-provisioning. Any subset may be given.
	claimRemote: RemoteEvent?,
	resultRemote: RemoteEvent?,
	openRemote: RemoteEvent?,
}

local config: Config? = nil
local resultRemote: RemoteEvent? = nil

--[[
	Claims currently mid-flight, per player.

	NOT what stops the reward paying twice -- the re-read-then-write does that; see
	the header. What this buys is a redundant web call NOT made: GetGroupsAsync is
	rate-limited, and a player who double-clicks would otherwise spend two of their
	budget to be told the same thing. It also refuses the second click immediately
	instead of after a round trip.

	Consequence worth knowing: that second click comes back "Failed", which reads as
	"try again" -- and a retry then correctly reports AlreadyClaimed. The two answers
	are coherent in sequence even though the first one is vague.
]]
local claiming: { [Player]: true } = {}

local function documentOf(player: Player): { [string]: any }?
	local settings = config
	if not settings then
		return nil
	end
	-- Guarded: a host's persistence layer may well throw for a player who left
	-- mid-claim, and that is a "not ready", not a crash in a remote handler.
	local ok, data = pcall(settings.document, player)
	return if ok then data else nil
end

-- The default membership check. Three-valued; see the header.
local function groupServiceCheck(player: Player, groupId: number): boolean?
	local ok, groups = pcall(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)
	if not ok then
		warn(`[CommunityReward] GetGroupsAsync failed for {player.Name}: {groups}`)
		return nil
	end
	for _, group in groups :: { any } do
		if group.Id == groupId then
			return true
		end
	end
	return false
end

local function refused(reason: Reason): ClaimResult
	return { ok = false, reason = reason }
end

-- Set the seams without wiring any transport. start() calls this; call it directly
-- when the claim path is wanted without remotes -- an admin command, or a test.
function CommunityReward.configure(settings: Config)
	assert(type(settings) == "table", "CommunityReward.configure: settings must be a table")
	assert(type(settings.document) == "function", "CommunityReward.configure: `document` must be a function")
	assert(type(settings.grant) == "function", "CommunityReward.configure: `grant` must be a function")
	config = settings
end

function CommunityReward.claimedField(): string
	local settings = config
	return (settings and settings.claimedField) or DEFAULT_CLAIMED_FIELD
end

-- Has this player already claimed? nil when their profile is not loaded, so a
-- caller can tell "no" apart from "cannot say yet".
function CommunityReward.hasClaimed(player: Player): boolean?
	local data = documentOf(player)
	if not data then
		return nil
	end
	return data[CommunityReward.claimedField()] == true
end

--[[
	Verifies and pays one claim.

	RETURNS the outcome rather than firing it, so an admin command shares this exact
	path instead of growing a second, subtly different one.

	The order of the checks is the whole design; see the header. Cheap and local
	first, then the thing that could make the reward ungrantable, and only then the
	yielding web call -- so every way this can refuse leaves the claim still there
	to be made.
]]
function CommunityReward.claim(player: Player): ClaimResult
	local settings = config
	if not settings then
		warn("[CommunityReward] claim before configure/start; refusing")
		return refused("NotReady")
	end

	if claiming[player] then
		return refused("Failed")
	end

	local data = documentOf(player)
	if not data then
		return refused("NotReady")
	end

	local field = CommunityReward.claimedField()
	if data[field] == true then
		return refused("AlreadyClaimed")
	end

	local groupId = settings.groupId or 0
	if groupId <= 0 then
		warn(`[CommunityReward] claim from {player.Name} refused -- groupId is unset`)
		return refused("Unavailable")
	end

	if settings.rewardReady then
		local ok, ready = pcall(settings.rewardReady)
		if not ok then
			warn(`[CommunityReward] rewardReady errored; refusing the claim rather than marking it paid:`, ready)
			return refused("Unavailable")
		elseif not ready then
			return refused("Unavailable")
		end
	end

	local check = settings.isInGroup or groupServiceCheck
	claiming[player] = true
	local inGroup: boolean?
	do
		-- xpcall rather than a bare call: an injected checker is host code, and a
		-- throw here must not leave the in-flight guard set forever.
		local ok, result = xpcall(check, debug.traceback, player, groupId)
		if ok then
			inGroup = result
		else
			warn(`[CommunityReward] membership check errored for {player.Name}:`, result)
			inGroup = nil
		end
	end
	claiming[player] = nil

	if inGroup == nil then
		return refused("Failed") -- retryable: never tell a member they are not one
	elseif not inGroup then
		return refused("NotInGroup")
	end

	-- Re-read after the yield. The player may have left, and the profile this claim
	-- started with is not necessarily one that still exists.
	local current = documentOf(player)
	if not current then
		return refused("NotReady")
	end
	if current[field] == true then
		return refused("AlreadyClaimed")
	end

	-- Flagged, then granted. See the header for why that order and not the other.
	current[field] = true

	--[[
		Guarded, and loudly. The flag is already written, so a throwing grant leaves
		this player marked paid with nothing to show for it -- the failure the header
		accepts as the lesser one, but it must not also take down the remote handler
		and it must be findable in the logs.
	]]
	local granted, err = xpcall(settings.grant, debug.traceback, player)
	if not granted then
		warn(
			`[CommunityReward] grant FAILED for {player.Name} AFTER the claim was flagged --`
				.. ` they are marked as paid and received nothing. Fix by hand:`,
			err
		)
	end

	if settings.onClaimed then
		local mirrored, mirrorErr = xpcall(settings.onClaimed, debug.traceback, player)
		if not mirrored then
			warn(`[CommunityReward] onClaimed errored for {player.Name}:`, mirrorErr)
		end
	end

	return { ok = true, reason = nil }
end

-- ─────────────────────────────────────────────────────────── the lobby prop ──

--[[
	The prompts this module built, so a trigger can be recognised without asking the
	tag again.

	Keyed by the prompt rather than by checking its parent's tag at trigger time,
	because a MODEL can carry the tag while the prompt has to live on a PART inside
	it -- the tag would not be on the parent to find, and walking ancestors at every
	prompt in the game to answer one question is a worse trade than remembering the
	few we made.
]]
local prompts: { [ProximityPrompt]: true } = {}

--[[
	Where to hang a prompt on a tagged thing. A Part is itself; a Model needs a part
	inside it, PrimaryPart first because that is the one the builder chose as its
	handle. nil when a Model has no parts YET, which is the ordinary case under
	StreamingEnabled -- the model replicates before its children do.
]]
local function anchorOf(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	elseif instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

--[[
	Builds the prompt on one tagged instance, WAITING for it to have a part to hang
	from. Idempotent at both ends -- before the wait and after it -- so a re-tag, a
	second start, or a model whose parts arrive in pieces cannot leave two prompts
	on one prop.

	Polled rather than waiting on a signal: the parts have no name to WaitForChild,
	and DescendantAdded:Wait() would block past the deadline on a prop that never
	gets one.
]]
local function bind(instance: Instance)
	local settings = config
	if not settings or instance:FindFirstChild(PROMPT_NAME, true) then
		return
	end

	local anchor = anchorOf(instance)
	local deadline = os.clock() + ANCHOR_WAIT
	while not anchor and os.clock() < deadline do
		task.wait(ANCHOR_POLL)
		anchor = anchorOf(instance)
	end
	if not anchor then
		warn(
			`[CommunityReward] "{instance:GetFullName()}" is tagged`
				.. ` "{settings.promptTag}" but has no part to hang a prompt on.`
		)
		return
	end
	if instance:FindFirstChild(PROMPT_NAME, true) then
		return -- another pass bound this prop while we yielded
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = settings.promptActionText or "Claim"
	prompt.ObjectText = settings.promptObjectText or "Community Reward"
	prompt.MaxActivationDistance = settings.promptDistance or DEFAULT_PROMPT_DISTANCE
	-- The prop is likely a statue or a board with something in front of it, and
	-- requiring line of sight makes a prompt that appears and vanishes as the player
	-- walks around it.
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	prompts[prompt] = true
end

-- ────────────────────────────────────────────────────────────────── transport ──

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

--[[
	Wires everything up. Self-provisioning: absent remotes are created in a
	dedicated folder, so there is no game-wide remotes registry to depend on and no
	boot ordering to get right.
]]
function CommunityReward.start(settings: Config)
	CommunityReward.configure(settings)

	local container: Instance? = nil
	local function remoteFor(injected: RemoteEvent?, name: string): RemoteEvent
		if injected then
			return injected
		end
		container = container or ensureContainer()
		return ensureRemote(container :: Instance, name)
	end

	local claimRemote = remoteFor(settings.claimRemote, CLAIM_REMOTE_NAME)
	resultRemote = remoteFor(settings.resultRemote, RESULT_REMOTE_NAME)
	local openRemote = remoteFor(settings.openRemote, OPEN_REMOTE_NAME)

	-- The claim takes no arguments, so there is nothing to validate on the way in.
	-- That is the design rather than an omission; every check that decides the
	-- outcome is in claim().
	claimRemote.OnServerEvent:Connect(function(player: Player)
		local outcome = CommunityReward.claim(player);
		(resultRemote :: RemoteEvent):FireClient(player, outcome.ok, outcome.reason)
	end)

	-- A player who leaves mid-lookup must not leave their guard behind: one left set
	-- would refuse them forever if they rejoined this server.
	Players.PlayerRemoving:Connect(function(player: Player)
		claiming[player] = nil
	end)

	if (settings.groupId or 0) <= 0 then
		warn("[CommunityReward] groupId is unset, so every claim will be refused as Unavailable.")
	end

	local tag = settings.promptTag
	if not tag then
		return -- no prop; the host opens its own window
	end

	--[[
		GetInstanceAddedSignal also fires for instances already tagged at the moment
		it is connected, so the loop below is only for ones tagged before this ran.

		Nothing is torn down on removal. An untagged prop keeps its prompt until it is
		destroyed, which is the honest failure -- a prompt with no handler does
		nothing, while chasing prompts across re-tags would be bookkeeping for a case
		that only happens while somebody is editing the place.
	]]
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance: Instance)
		task.spawn(bind, instance)
	end)
	local tagged = CollectionService:GetTagged(tag)
	for _, instance in tagged do
		task.spawn(bind, instance)
	end
	if #tagged == 0 then
		-- Said once at boot rather than discovered by a player who cannot find the
		-- reward: the prop is the only way in, so nothing wearing the tag means no way in.
		warn(`[CommunityReward] nothing in this place is tagged "{tag}" -- the reward has no way in.`)
	end

	--[[
		One game-wide signal, filtered to the prompts this module made. PromptTriggered
		fires for every prompt in the game, so the set is what says which are ours.
		Nothing here holds a prop: the prompt arrives as an argument, so
		StreamingEnabled taking one away and building another costs a table entry.
	]]
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if prompts[prompt] then
			openRemote:FireClient(player)
		end
	end)
end

return CommunityReward
