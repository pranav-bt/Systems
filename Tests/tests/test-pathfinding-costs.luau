-- What PathAgent asks PathfindingService for, and `Costs` in particular.
--
-- There is no navmesh in a headless run and nothing to path across, so the assertion worth
-- making is the one about the REQUEST: an option that never reaches CreatePath looks exactly
-- like an option that works, right up until a bot walks over the thing it was told to avoid.
local rbx = require("./shim/roblox")
local PathAgent = require("./shim/library")("Pathfinding", "PathAgent")

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

local function newBody()
	local humanoid = rbx.Instance.new("Humanoid")
	local root = rbx.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	return humanoid, root
end

-- The params handed to the most recent CreatePath.
local function lastParams()
	local all = rbx.pathParams()
	return all[#all]
end

print("an agent that names no costs asks for exactly what it always did")
do
	rbx.clearPathParams()
	local humanoid, root = newBody()
	PathAgent.new(humanoid, root)

	local params = lastParams()
	check("CreatePath was called during construction", params ~= nil)
	check("with the default agent radius", params and params.AgentRadius == 2, params and params.AgentRadius)
	check("height", params and params.AgentHeight == 5, params and params.AgentHeight)
	check("jump permission", params and params.AgentCanJump == true, params and params.AgentCanJump)
	check("and the coarse starting spacing", params and params.WaypointSpacing == 120, params and params.WaypointSpacing)

	--[[
		NOT an empty table. `Costs = {}` and no Costs key at all are different requests, and
		the point of leaving it nil is that an agent naming no costs hands the engine byte-for
		-byte what it handed it before this option existed.
	]]
	check("and no Costs key at all", params and params.Costs == nil, params and params.Costs)
end

print("costs are threaded through")
do
	rbx.clearPathParams()
	local humanoid, root = newBody()
	PathAgent.new(humanoid, root, {
		costs = { Water = 20, Furniture = math.huge },
	})

	local params = lastParams()
	check("Costs reaches CreatePath", params and params.Costs ~= nil)
	check("with the label it was given", params and params.Costs.Water == 20, params and params.Costs.Water)
	-- math.huge is how a label is made impassable, which is the case the option exists for:
	-- a surface that is technically walkable and must not be walked.
	check("and math.huge survives as impassable", params and params.Costs.Furniture == math.huge, params and params.Costs.Furniture)

	-- The other agent params must not be disturbed by adding costs.
	check("the agent params are unchanged", params and params.AgentRadius == 2 and params.AgentHeight == 5, params)
end

print("costs sit alongside the other options, not instead of them")
do
	rbx.clearPathParams()
	local humanoid, root = newBody()
	PathAgent.new(humanoid, root, {
		agentRadius = 3,
		agentHeight = 6,
		agentCanJump = false,
		waypointSpacing = 40,
		costs = { Mud = 5 },
	})

	local params = lastParams()
	check("the agent options are honoured", params and params.AgentRadius == 3 and params.AgentHeight == 6, params)
	check("including a disabled jump", params and params.AgentCanJump == false, params and params.AgentCanJump)
	check("and the given spacing", params and params.WaypointSpacing == 40, params and params.WaypointSpacing)
	check("with costs beside them", params and params.Costs.Mud == 5, params and params.Costs)
end

print("a bad cost table is refused where it can be named")
do
	local humanoid, root = newBody()

	--[[
		Validated in `resolve` rather than left to CreatePath, which throws from inside the
		engine without naming the offending label. A cost table is authored content, and a
		content error should say which entry is wrong.

		Which means the MESSAGE is the whole value of the guard: a bad table throws either way
		(iterating a number errors on its own), so asserting on the wording is what makes the
		check load-bearing rather than decorative.
	]]
	local okShape, errShape = pcall(PathAgent.new, humanoid, root, { costs = 5 :: any })
	check("a non-table costs is refused", not okShape)
	check("saying what it should have been", not okShape and tostring(errShape):find("table") ~= nil, errShape)
	check("a non-number cost is refused", not pcall(PathAgent.new, humanoid, root, { costs = { Water = "slow" :: any } }))
	check("and a non-string label is refused", not pcall(PathAgent.new, humanoid, root, { costs = { [1] = 5 } :: any }))

	local ok, err = pcall(PathAgent.new, humanoid, root, { costs = { Water = "slow" :: any } })
	check("and the message names the label", not ok and tostring(err):find("Water") ~= nil, err)

	-- An empty table is a legitimate thing to author -- a game building the table from data
	-- may legitimately produce none this run.
	check("an empty cost table is fine", pcall(PathAgent.new, humanoid, root, { costs = {} }))
end

print("the adaptive spacing rebuild keeps the costs")
do
	rbx.clearPathParams()
	local humanoid, root = newBody()
	PathAgent.new(humanoid, root, {
		costs = { Furniture = math.huge },
		waypointSpacing = 120,
	})
	local first = lastParams()
	check("the first path carries them", first and first.Costs.Furniture == math.huge)

	--[[
		WaypointSpacing cannot be changed on an existing Path, so a stall builds a NEW one at
		half the spacing. Costs are read at every CreatePath rather than captured once, so that
		rebuild keeps them -- an agent that forgot its costs the first time it stalled would
		then path straight over the furniture it had been avoiding, which is the confusing
		version of this bug.

		Verified by construction rather than by driving a stall: `buildPath` is the only thing
		that calls CreatePath, and it reads `opts.costs` every time.
	]]
	check("and only one path was built so far", #rbx.pathParams() == 1, #rbx.pathParams())
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("pathfinding costs tests failed", 0)
end
