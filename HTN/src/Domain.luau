--!strict

-- Constructor + validator for Domains (task libraries), in the same style as
-- Bots.Goal.new: Domain.new(spec) checks the whole shape at the DEFINITION
-- SITE -- including that every method's subtasks resolve to a declared task --
-- and returns the typed table, so a typo'd task name errors right where the
-- domain is written instead of failing a decomposition at runtime.
--
-- A domain is pure data: reusable across goals, bots, and games. Recursion
-- (a method whose subtasks include the compound being defined, directly or
-- indirectly) is legal and useful -- "gather wood, then try again" -- and the
-- planner's maxDepth/maxSteps caps make it safe.

local Types = require(script.Parent.Types)

local Domain = {}

export type Spec = {
	primitives: { [string]: Types.PrimitiveSpec }?,
	compounds: { [string]: Types.CompoundSpec }?,
}

function Domain.new(spec: Spec): Types.Domain
	assert(type(spec) == "table", "HTN.Domain.new: a spec table is required")
	local primitives = spec.primitives or {}
	local compounds = spec.compounds or {}
	assert(type(primitives) == "table", "HTN.Domain.new: primitives must be a table when set")
	assert(type(compounds) == "table", "HTN.Domain.new: compounds must be a table when set")
	assert(next(primitives) ~= nil or next(compounds) ~= nil, "HTN.Domain.new: at least one task is required")

	for name, primitive in primitives do
		assert(type(name) == "string" and name ~= "", "HTN.Domain.new: primitive names must be non-empty strings")
		local who = `primitive "{name}"`
		assert(type(primitive) == "table", `HTN.Domain.new: {who} must be a table`)
		assert(
			primitive.condition == nil or type(primitive.condition) == "function",
			`HTN.Domain.new: {who}.condition must be a function when set`
		)
		assert(
			primitive.effects == nil or type(primitive.effects) == "function",
			`HTN.Domain.new: {who}.effects must be a function when set`
		)
	end

	for name, compound in compounds do
		assert(type(name) == "string" and name ~= "", "HTN.Domain.new: compound names must be non-empty strings")
		local who = `compound "{name}"`
		assert(primitives[name] == nil, `HTN.Domain.new: "{name}" is declared as both a primitive and a compound`)
		assert(type(compound) == "table", `HTN.Domain.new: {who} must be a table`)
		assert(
			type(compound.methods) == "table" and #compound.methods > 0,
			`HTN.Domain.new: {who} needs a non-empty methods array`
		)
		for index, method in compound.methods do
			local where = `{who}.methods[{index}]`
			assert(type(method) == "table", `HTN.Domain.new: {where} must be a table`)
			assert(
				method.name == nil or (type(method.name) == "string" and method.name ~= ""),
				`HTN.Domain.new: {where}.name must be a non-empty string when set`
			)
			assert(
				method.condition == nil or type(method.condition) == "function",
				`HTN.Domain.new: {where}.condition must be a function when set`
			)
			assert(
				type(method.subtasks) == "table",
				`HTN.Domain.new: {where}.subtasks must be an array of task names (empty = "nothing to do")`
			)
			for _, subtask in method.subtasks do
				assert(type(subtask) == "string", `HTN.Domain.new: {where}.subtasks must contain only strings`)
				assert(
					primitives[subtask] ~= nil or compounds[subtask] ~= nil,
					`HTN.Domain.new: {where} references unknown task "{subtask}"`
				)
			end
		end
	end

	return { primitives = primitives, compounds = compounds }
end

return Domain
