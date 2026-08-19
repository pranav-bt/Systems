--!strict

-- Constructor + validator for Actions. Action.new(spec) checks the whole shape
-- at the DEFINITION SITE and returns the (typed) table -- so a malformed action
-- errors right where it is written, with a message naming the field, instead of
-- later when some bot happens to be created with it.
--
-- Plain tables shaped like an Action remain perfectly valid everywhere -- the
-- constructor is the recommended authoring path, not a requirement. Bot.new
-- re-validates every action it receives either way (via Goal/Action.validate),
-- so nothing malformed can reach the Planner.

local Types = require(script.Parent.Types)

local Action = {}

local function validateRequires(requires: any, label: string, who: string)
	if requires == nil then
		return
	end
	assert(type(requires) == "table", `{label}: {who}.requires must be an array of body field names`)
	for _, field in requires :: { any } do
		assert(type(field) == "string", `{label}: {who}.requires must contain only strings`)
	end
end

-- Validate one action table. `label` says where the check is happening, so the
-- same message reads correctly from every gate (e.g. "Bots.Action.new" or
-- `Bots.Bot.new: goals[2]: goal "Fight".actions[1]`).
function Action.validate(action: any, label: string): Types.Action
	assert(type(action) == "table", `{label}: an action must be a table`)
	assert(type(action.name) == "string" and action.name ~= "", `{label}: action.name must be a non-empty string`)
	local who = `action "{action.name}"`
	assert(action.enter == nil or type(action.enter) == "function", `{label}: {who}.enter must be a function when set`)
	assert(
		action.update == nil or type(action.update) == "function",
		`{label}: {who}.update must be a function when set`
	)
	assert(action.exit == nil or type(action.exit) == "function", `{label}: {who}.exit must be a function when set`)
	assert(action.enter ~= nil or action.update ~= nil, `{label}: {who} needs at least one of enter/update`)
	validateRequires(action.requires, label, who)
	return action :: Types.Action
end

-- Define an action, validated where it is written.
function Action.new(spec: Types.Action): Types.Action
	return Action.validate(spec, "Bots.Action.new")
end

return Action
