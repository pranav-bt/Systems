--!strict

-- The candidate visualizer. Tuning weights is the daily work with a query
-- system, and the question is always spatial -- "why THERE and not here?" The
-- engine already computes the whole answer (every candidate's position and its
-- per-test breakdown) and then throws all but the winner away. This draws it.
--
-- Two steps: set `debug = true` on the query so Engine.run keeps the scored
-- field in RunInfo.candidates, then hand the RunInfo here.
--
--   local spot, info = FindCover:run(context)
--   TacticalQuery.Debug.draw("FindCover", info, spot)
--
-- Candidates render as spheres graded red (0.0) -> green (1.0) by score, the
-- winner larger and white, each labelled with its score and -- on hover, via the
-- BillboardGui -- the per-test breakdown that produced it.
--
-- CanQuery = false IS NOT OPTIONAL. A debug sphere sitting on a candidate is
-- geometry, and the tests being visualized are raycasts: leave CanQuery on and
-- every `hidden` ray hits the marker drawn for its own candidate, so turning on
-- debugging reports the entire field as being in perfect cover. CanCollide is
-- off for the same reason PathAgent's markers are -- collidable debug parts alter
-- the navmesh that `isReachable` and the movers depend on.
--
-- Server-side drawing replicates to every client, so this is a development tool.
-- Gate it behind your own studio/dev check; nothing here does that for you.

local Types = require(script.Parent.Types)

local Debug = {}

local FOLDER_NAME = "TacticalQueryDebug"

export type DrawOptions = {
	candidateSize: number?, -- sphere diameter for a scored candidate (default 1.2)
	winnerSize: number?, -- sphere diameter for the winner (default 2.2)
	height: number?, -- studs above the position to draw (default 1)
	labels: boolean?, -- attach score + breakdown labels (default true)
}

local function container(): Folder
	local existing = workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = workspace
	return folder
end

-- One query's drawings live under their own child folder, so several queries can
-- be visualized at once and each redraw only clears its own.
local function bucket(name: string): Folder
	local root = container()
	local existing = root:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = root
	return folder
end

-- Red at 0, amber at 0.5, green at 1 -- the reading most people already have for
-- a score, and legible against both light and dark maps.
local function gradeColor(score: number): Color3
	local clamped = math.clamp(score, 0, 1)
	if clamped < 0.5 then
		return Color3.fromRGB(220, 60, 50):Lerp(Color3.fromRGB(235, 180, 40), clamped * 2)
	end
	return Color3.fromRGB(235, 180, 40):Lerp(Color3.fromRGB(70, 210, 90), (clamped - 0.5) * 2)
end

local function marker(parent: Folder, position: Vector3, size: number, color: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(size, size, size)
	part.CFrame = CFrame.new(position)
	part.Anchored = true
	part.CanCollide = false -- collidable debug parts alter the navmesh
	part.CanQuery = false -- MUST be false: else it becomes a hit for the LOS tests it visualizes
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	part.Parent = parent
	return part
end

local function label(part: Part, candidate: Types.Candidate, isWinner: boolean)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(180, 76)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 1.4, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 140
	billboard.Parent = part

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 0.35
	text.BackgroundColor3 = Color3.fromRGB(12, 16, 22)
	text.TextColor3 = if isWinner then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(215, 225, 235)
	text.Font = Enum.Font.Code
	text.TextSize = 12
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.RichText = false

	-- Score first, then the per-test breakdown that produced it: this IS the
	-- "why this spot" answer, in the order you ask the question.
	local lines = {
		if isWinner then `WINNER  {string.format("%.3f", candidate.score)}` else string.format("%.3f", candidate.score),
	}
	local names: { string } = {}
	for testName in candidate.breakdown do
		table.insert(names, testName)
	end
	table.sort(names)
	for _, testName in names do
		table.insert(lines, `  {testName} {string.format("%.2f", candidate.breakdown[testName])}`)
	end
	text.Text = table.concat(lines, "\n")
	text.Parent = billboard
end

-- Draw one run. `winner` is the candidate returned by run() (may be nil); it is
-- matched by position so it renders as the winner rather than a duplicate.
function Debug.draw(name: string, info: Types.RunInfo, winner: Types.Candidate?, options: DrawOptions?)
	assert(type(name) == "string" and name ~= "", "TacticalQuery.Debug.draw: a query name is required")
	assert(type(info) == "table", "TacticalQuery.Debug.draw: a RunInfo is required")
	local opts: DrawOptions = options or {}
	local candidateSize = opts.candidateSize or 1.2
	local winnerSize = opts.winnerSize or 2.2
	local height = opts.height or 1
	local labels = opts.labels ~= false

	local folder = bucket(name)
	local candidates = info.candidates
	if candidates == nil then
		warn(
			`[TacticalQuery] Debug.draw("{name}"): this RunInfo has no candidates.`
				.. ` Set debug = true on the query so the engine keeps them.`
		)
		return
	end

	local lift = Vector3.new(0, height, 0)
	for _, candidate in candidates do
		local isWinner = winner ~= nil and candidate.position == winner.position
		local part = marker(
			folder,
			candidate.position + lift,
			if isWinner then winnerSize else candidateSize,
			if isWinner then Color3.fromRGB(255, 255, 255) else gradeColor(candidate.score),
			if isWinner then 0 else 0.25
		)
		part.Name = string.format("%.3f", candidate.score)
		if labels then
			label(part, candidate, isWinner)
		end
	end

	-- A winner that isn't in the scored field means it passed validate after the
	-- snapshot was taken; draw it anyway so the picture is never missing the
	-- answer.
	if winner ~= nil then
		local found = false
		for _, candidate in candidates do
			if candidate.position == winner.position then
				found = true
				break
			end
		end
		if not found then
			local part = marker(folder, winner.position + lift, winnerSize, Color3.fromRGB(255, 255, 255), 0)
			part.Name = "winner"
			if labels then
				label(part, winner, true)
			end
		end
	end
end

-- Remove one query's drawing, or every drawing when name is nil.
function Debug.clear(name: string?)
	local root = workspace:FindFirstChild(FOLDER_NAME)
	if not root then
		return
	end
	if name == nil then
		root:Destroy()
		return
	end
	local existing = root:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
end

return Debug
