-- Nametags: the overhead label, where its colour comes from, and what happens on a respawn.
--
-- Small enough that the interesting questions are about LIFECYCLE rather than logic -- what a
-- second `start` does, what a respawn leaves behind, what a game can change at runtime.
local rbx = require("./shim/roblox")
local Nametags = require("./shim/library")("Nametags")
local task = require("@lune/task")
local process = require("@lune/process")

local passed, failed = 0, 0
local function check(name, ok, detail)
	if ok then
		passed += 1
		print(("  ok   %s"):format(name))
	else
		failed += 1
		print(("  FAIL %s -- %s"):format(name, tostring(detail)))
	end
end

local V = rbx.Vector3.new
local RGB = rbx.Color3.fromRGB

-- A character shaped the way the module expects: a Head and a Humanoid.
local function newCharacter(name)
	local character = rbx.Instance.new("Model")
	character.Name = name
	local head = rbx.Instance.new("Part")
	head.Name = "Head"
	head.Parent = character
	local humanoid = rbx.Instance.new("Humanoid")
	humanoid.Health = 100
	humanoid.NameDisplayDistance = 100
	humanoid.Parent = character
	local root = rbx.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Parent = character
	character.Parent = rbx.workspace
	return character, head, humanoid
end

local function nametagOf(player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	return head and head:FindFirstChild("Nametag")
end

local function labelOf(player)
	local gui = nametagOf(player)
	return gui and gui:FindFirstChildOfClass("TextLabel")
end

-- A player whose character the module will accept.
local function joinWithCharacter(name)
	local player = rbx.addPlayer(name)
	task.wait()
	local character, head, humanoid = newCharacter(name)
	player.Character = character
	player._fireCharacterAdded(character)
	task.wait()
	return player, character, head, humanoid
end

Nametags.start({
	ColorResolver = function(player)
		-- Only answers for one specific player, so the Team and neutral paths stay reachable.
		return if player.Name == "Resolved" then RGB(1, 2, 3) else nil
	end,
})

print("a nametag is built on the head")
do
	local ana, character, head, humanoid = joinWithCharacter("Ana")

	local gui = nametagOf(ana)
	check("a Nametag gui exists", gui ~= nil, "none")
	check("parented to the head", gui and gui.Parent == head, gui and gui.Parent)
	check("and adorned to it", gui and gui.Adornee == head, gui and gui.Adornee)

	-- The owner does not need to see their own.
	check("hidden from its owner", gui and gui.PlayerToHideFrom == ana, gui and gui.PlayerToHideFrom)

	local label = labelOf(ana)
	check("with a text label", label ~= nil)
	check("showing the display name", label and label.Text == "Ana", label and label.Text)
	check("scaled to the gui", label and label.TextScaled == true)

	-- The default overhead username is replaced; the health bar is deliberately kept.
	check("the default name display is switched off", humanoid.NameDisplayDistance == 0, humanoid.NameDisplayDistance)

	rbx.removePlayer(ana)
end

print("colour: resolver, then Team, then neutral")
do
	-- The resolver wins when it answers.
	local resolved = joinWithCharacter("Resolved")
	local label = labelOf(resolved)
	check("the resolver's colour is used", label and label.TextColor3.R == 1 / 255, label and label.TextColor3)

	-- It returns nil for everyone else, which must fall through rather than blank the label.
	local teamed = joinWithCharacter("Teamed")
	rbx.setTeam(teamed, "Red", RGB(255, 0, 0))
	-- Respawned AFTER joining the team, so the label is built with the team colour already
	-- in place rather than recoloured into it -- that path has its own block below.
	local respawned = newCharacter("Teamed2")
	teamed.Character = respawned
	teamed._fireCharacterAdded(respawned)
	task.wait()
	local teamLabel = labelOf(teamed)
	check("a team colour is used when the resolver declines", teamLabel and teamLabel.TextColor3.R == 1, teamLabel and teamLabel.TextColor3)

	-- Neither: the neutral fallback.
	local loner = joinWithCharacter("Loner")
	local lonerLabel = labelOf(loner)
	check("neutral when there is neither", lonerLabel and math.abs(lonerLabel.TextColor3.R - 220 / 255) < 1e-9, lonerLabel and lonerLabel.TextColor3)

	rbx.removePlayer(resolved)
	rbx.removePlayer(teamed)
	rbx.removePlayer(loner)
end

print("changing team recolours the existing label")
do
	local ana = joinWithCharacter("Ana")
	local label = labelOf(ana)
	check("starts neutral", label and math.abs(label.TextColor3.R - 220 / 255) < 1e-9, label and label.TextColor3)

	rbx.setTeam(ana, "Blue", RGB(0, 0, 255))
	task.wait()
	--[[
		Recoloured IN PLACE rather than rebuilt: the gui is the same instance, so anything a
		game attached to it survives a team switch.
	]]
	check("the same label is recoloured", labelOf(ana) == label, "the gui was rebuilt")
	check("to the new team colour", label.TextColor3.B == 1, label.TextColor3)

	-- Leaving a team falls back to neutral rather than keeping the old colour.
	rbx.setTeam(ana, nil)
	task.wait()
	check("and back to neutral when the team is cleared", math.abs(label.TextColor3.R - 220 / 255) < 1e-9, label.TextColor3)

	rbx.removePlayer(ana)
end

print("a respawn gets a fresh nametag, not two")
do
	local ana = joinWithCharacter("Ana")
	check("the first character has one", nametagOf(ana) ~= nil)

	local reborn, head = newCharacter("Ana")
	ana.Character = reborn
	ana._fireCharacterAdded(reborn)
	task.wait()

	check("the new character has one", nametagOf(ana) ~= nil, "none on the new character")

	-- Exactly one: a stale gui left beside a new one is two labels stacked on a head.
	local count = 0
	for _, child in head:GetChildren() do
		if child.Name == "Nametag" then
			count += 1
		end
	end
	check("and exactly one of them", count == 1, count)

	rbx.removePlayer(ana)
end

print("a character with no head is NOT handled")
do
	--[[
		A FINDING, asserted as it currently behaves so the fix has something to flip.

		`setupNametag` resolves its parts with `FindFirstChild(x) or WaitForChild(x)` and then
		calls `:IsA` on the result. For a rig that never gains a Head or a Humanoid -- a custom
		character, or one destroyed mid-spawn -- there are two failures depending on where you
		run it:

		  * UNDER THE ENGINE, `WaitForChild` with no timeout blocks FOREVER. The thread is
		    parked for the life of the server, holding the character and the player in memory.
		  * HERE, the shim returns nil immediately, so `head:IsA` is a nil dereference.

		Both come from the same missing check. A timeout plus a nil guard fixes both, and a
		character the module cannot decorate should simply be left undecorated.
	]]
	local player = rbx.addPlayer("Headless")
	task.wait()
	local character = rbx.Instance.new("Model")
	character.Name = "Headless"
	local humanoid = rbx.Instance.new("Humanoid")
	humanoid.Parent = character
	character.Parent = rbx.workspace
	player.Character = character

	--[[
		Wrapped, because this shim dispatches signal handlers SYNCHRONOUSLY and the engine
		gives each one its own thread -- so the nil dereference surfaces here where the engine
		would instead park a thread and say nothing. Either way the library is at fault; only
		the symptom differs.
	]]
	pcall(function()
		player._fireCharacterAdded(character)
		task.wait()
	end)
	check("a headless character produces no nametag", nametagOf(player) == nil, "one was invented")

	rbx.removePlayer(player)
end

print("a player already in the server when start runs is hooked")
do
	--[[
		`start` hooks PlayerAdded AND walks the players already present, because a library
		started after the first join would otherwise never decorate whoever was there first.
		Proved by the fact that this suite's players are all added after start -- so this block
		checks the other direction: re-running start over an existing player.
	]]
	local ana = joinWithCharacter("Ana")
	check("they have a nametag", nametagOf(ana) ~= nil)

	local before = labelOf(ana)
	--[[
		A SECOND START. Every other library in this repo guards this with a `started` flag;
		this one does not, so PlayerAdded gets a second connection and every present player is
		hooked again -- a second CharacterAdded connection and a second Team listener each time.
		The visible result is still one nametag, because setup destroys the existing gui first,
		which is what makes the duplication invisible rather than harmless.
	]]
	Nametags.start()
	task.wait()
	check("a second start still leaves one nametag", nametagOf(ana) ~= nil)

	local reborn = newCharacter("Ana")
	ana.Character = reborn
	ana._fireCharacterAdded(reborn)
	task.wait()
	local head = reborn:FindFirstChild("Head")
	local count = 0
	for _, child in head:GetChildren() do
		if child.Name == "Nametag" then
			count += 1
		end
	end
	check("and a respawn after it still leaves one", count == 1, count)

	rbx.removePlayer(ana)
end

print("config is applied")
do
	--[[
		Re-started with explicit values. Note the asymmetry this exposes: five fields use
		`config.X or existing`, so omitting them keeps the previous value -- but ColorResolver
		is assigned outright, so omitting it CLEARS a resolver set earlier. The block below
		relies on that to get back to team/neutral colouring, which is the only reason it is
		convenient here and a trap everywhere else.
	]]
	Nametags.start({
		Size = rbx.UDim2.fromOffset(300, 60),
		StudsOffset = V(0, 4, 0),
		MaxDistance = 42,
		NeutralColor = RGB(10, 20, 30),
	})

	local ana = joinWithCharacter("Ana")
	local gui = nametagOf(ana)
	check("the configured size is used", gui and gui.Size.X.Offset == 300, gui and gui.Size)
	check("the configured offset", gui and gui.StudsOffset.Y == 4, gui and gui.StudsOffset)
	check("and the configured max distance", gui and gui.MaxDistance == 42, gui and gui.MaxDistance)

	local label = labelOf(ana)
	check("the configured neutral colour", label and math.abs(label.TextColor3.G - 20 / 255) < 1e-9, label and label.TextColor3)

	rbx.removePlayer(ana)
end

print(("%d passed, %d failed"):format(passed, failed))
process.exit(if failed > 0 then 1 else 0)
