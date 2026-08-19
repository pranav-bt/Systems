--!strict

-- Constructor + validator for Goals. Goal.new(spec) checks the whole shape --
-- including every action in `actions`, via Action.validate -- at the DEFINITION
-- SITE and returns the (typed) table, so a malformed goal errors right where it
-- is written with a message naming the field.
--
-- Plain tables shaped like a Goal remain perfectly valid everywhere -- the
-- constructor is the recommended authoring path, not a requirement. Bot.new
-- re-validates every goal it receives either way, so nothing malformed can
-- reach the Planner.

local Action = require(script.Parent.Action)
local Types = require(script.Parent.Types)

local Goal = {}

local function validateRequires(requires: any, label: string, who: string)
	if requires == nil then
		return
	end
	assert(type(requires) == "table", `{label}: {who}.requires must be an array of body field names`)
	for _, field in requires :: { any } do
		assert(type(field) == "string", `{label}: {who}.requires must contain only strings`)
	end
end

-- Validate one goal table (and, recursively, its actions). `label` says where
-- the check is happening, so the same message reads correctly from every gate
-- (e.g. "Bots.Goal.new" or "Bots.Bot.new: goals[2]").
function Goal.validate(goal: any, label: string): Types.Goal
	assert(type(goal) == "table", `{label}: a goal must be a table`)
	assert(type(goal.name) == "string" and goal.name ~= "", `{label}: goal.name must be a non-empty string`)
	local who = `goal "{goal.name}"`
	assert(type(goal.canRun) == "function", `{label}: {who} needs a canRun(bot) precondition function`)
	assert(goal.score == nil or type(goal.score) == "function", `{label}: {who}.score must be a function when set`)
	assert(goal.weight == nil or type(goal.weight) == "number", `{label}: {who}.weight must be a number when set`)
	assert(
		goal.effects == nil or type(goal.effects) == "function",
		`{label}: {who}.effects must be a function when set`
	)
	assert(
		goal.interruptible == nil or type(goal.interruptible) == "boolean",
		`{label}: {who}.interruptible must be a boolean when set`
	)
	assert(goal.cooldown == nil or type(goal.cooldown) == "number", `{label}: {who}.cooldown must be a number when set`)
	validateRequires(goal.requires, label, who)
	assert(type(goal.actions) == "table" and #goal.actions > 0, `{label}: {who} needs a non-empty actions array`)
	for index, action in goal.actions :: { any } do
		Action.validate(action, `{label}: {who}.actions[{index}]`)
	end
	return goal :: Types.Goal
end

-- Define a goal, validated where it is written.
function Goal.new(spec: Types.Goal): Types.Goal
	return Goal.validate(spec, "Bots.Goal.new")
end

return Goal
