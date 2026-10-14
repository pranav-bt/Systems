-- LagCompensation.new's public table: everything the halves expose reaches the host.
--
-- The facade is hand-assembled from Snapshots + Rewind, so a function added to either half can
-- be missed -- and was: `InvalidateLineOfSightFilter` existed on Rewind (and its tests called it
-- there) while a host using LagCompensation.new could not call it at all. The LOS exclude list
-- then only rebuilt on a player joining, leaving or respawning, so an NPC spawned into an excluded
-- folder kept blocking line of sight until some player happened to do one of those.
local rbx = require("./shim/roblox")
local LagCompensation = require("./shim/library")("LagCompensation")
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

local quiet = { Warn = function() end, Info = function() end, Error = function() end, Debug = function() end }

-- No snapshot loop: nothing here needs pose history, and a scheduler that never fires keeps it so.
local api = LagCompensation.new({
	logger = quiet,
	scheduleSnapshots = function()
		return function() end
	end,
	losExcludeFolderNames = { "Npcs" },
})

print("the public table carries every documented call")
do
	for _, name in {
		"SampleAt",
		"SamplesInWindow",
		"GetExtents",
		"RefreshExtents",
		"Reset",
		"NoteAuthorizedBurst",
		"IsClaimRejected",
		"GetFlagCounters",
		"start",
		"stop",
		"SanitizeTargets",
		"ClampClaimTime",
		"AttackerPoseAt",
		"ApproveBox",
		"ApproveRadius",
		"HasLineOfSight",
		"InvalidateLineOfSightFilter",
		"AllowRate",
		"Reject",
		"GetCounters",
		"CleanupPlayer",
	} do
		check(name, type(api[name]) == "function", type(api[name]))
	end
end

print("invalidating through the facade rebuilds the LOS filter")
do
	local seen = nil
	rbx.setRaycastResult(function(_, _, params)
		seen = params and params.FilterDescendantsInstances
		return nil
	end)
	api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))
	local before = seen and #seen or 0

	-- the excluded folder appears after the first LOS check (an NPC folder made at runtime)
	local folder = rbx.Instance.new("Folder")
	folder.Name = "Npcs"
	folder.Parent = rbx.workspace
	task.wait()

	api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))
	local stale = false
	for _, entry in seen or {} do
		if entry == folder then
			stale = true
		end
	end
	check("without being told, the cached filter does not know the folder", not stale, "already excluded")

	api.InvalidateLineOfSightFilter()
	api.HasLineOfSight(V(0, 0, 0), V(10, 0, 0))
	local excluded = false
	for _, entry in seen or {} do
		if entry == folder then
			excluded = true
		end
	end
	check("after InvalidateLineOfSightFilter it excludes it", excluded, seen and #seen)
	check("one more entry than before", seen and #seen == before + 1, `{before} -> {seen and #seen}`)
	rbx.setRaycastResult(nil)
end

print(("%d passed, %d failed"):format(passed, failed))
process.exit(if failed > 0 then 1 else 0)
