--!strict

-- Loads a library's REAL source under the Roblox shim, resolving its internal
-- `require(script.Parent.X)` calls as it goes.
--
-- WHY NOT COPY THE FILES. A vendored copy silently drifts from the library, and the
-- tests then keep passing against code that no longer ships. There is nothing to
-- drift here, because this reads the files themselves.
--
-- HOW `script` IS FAKED. Rojo turns `dir/init.luau` into the module named after the
-- directory and every sibling file into a CHILD of it. So from `init.luau`,
-- `script.Config` is `dir/Config.luau`; from `dir/Config.luau`, `script.Parent` is
-- that directory module and `script.Parent.Rig` is `dir/Rig.luau`. Both spell the
-- same lookup, so one table serves as both.
--
-- ONE LEVEL UP AS WELL, for the multi-realm packages. `src/server/init.luau` is
-- `Package.server`, so `script.Parent.shared` is `src/shared` -- a SIBLING DIRECTORY
-- rather than a sibling file. A name that resolves to neither a file here nor a
-- folder here is looked for there, and only then, so testing the server half never
-- drags in the client half.
--
-- WHY IT IS A PLAIN TABLE AND NOT A LAZY PROXY. The obvious shape is an __index that
-- loads on demand -- and it cannot work here, because Lune's `fs` yields and Luau
-- refuses to yield across a metamethod. So the directory is read, internal requires
-- are extracted, and the modules are executed in DEPENDENCY ORDER into one table. By
-- the time a module runs, everything it asks for is already in there.
--
-- ONLY WHAT WAS ASKED FOR, AND ITS DEPENDENCIES, IS EXECUTED. Loading a whole
-- directory would run modules that reach for services at require time, so asking for
-- one pure module would drag in the package's entry point and fail on a folder that
-- does not exist in a headless run.
--
-- A require cycle is therefore caught and named rather than recursing until the stack
-- gives out.
--
-- Paths are relative to the REPO ROOT, so run tests from the Libraries directory:
--   lune run Tests/tests/test-companions-loadout.luau

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local rbx = require("./roblox")

local ENVIRONMENT = {
	game = rbx.game,
	Instance = rbx.Instance,
	Enum = rbx.Enum,
	Vector3 = rbx.Vector3,
	CFrame = rbx.CFrame,
	Color3 = rbx.Color3,
	UDim2 = rbx.UDim2,
	RaycastParams = rbx.RaycastParams,
	workspace = rbx.workspace,
	time = rbx.time,
	typeof = rbx.typeof,
	task = rbx.task,
	Random = rbx.Random,
	debug = rbx.debug,
}

-- dir -> { [moduleName]: module }. Cached because Roblox's require is: a module
-- required twice is the same table, and library code relies on that for its state.
local loaded: { [string]: { [string]: any } } = {}

local loadModule

-- Every `require(script.X)` / `require(script.Parent.X)` in one source, by name.
local function dependenciesOf(source: string): { string }
	local names: { string } = {}
	local seen: { [string]: true } = {}
	for name in source:gmatch("require%s*%(%s*script%.Parent%.([%a_][%w_]*)%s*%)") do
		if not seen[name] then
			seen[name] = true
			table.insert(names, name)
		end
	end
	for name in source:gmatch("require%s*%(%s*script%.([%a_][%w_]*)%s*%)") do
		if name ~= "Parent" and not seen[name] then
			seen[name] = true
			table.insert(names, name)
		end
	end
	return names
end

local function parentOf(dir: string): string
	return dir:match("^(.*)/[^/]+$") or dir
end

local function moduleNames(dir: string): { string }
	local names: { string } = {}
	for _, entry in fs.readDir(dir) do
		local name = entry:match("^(.+)%.luau$")
		if name then
			table.insert(names, name)
		elseif fs.isFile(`{dir}/{entry}/init.luau`) then
			table.insert(names, entry)
		end
	end
	table.sort(names) -- deterministic, so a cycle error names the same module twice running
	return names
end

local function pathFor(dir: string, name: string): string
	local direct = `{dir}/{name}.luau`
	return if fs.isFile(direct) then direct else `{dir}/{name}/init.luau`
end

local dirState: { [string]: { [string]: string } } = {}

function loadModule(dir: string, wanted: string): any
	local modules = loaded[dir]
	if not modules then
		modules = {}
		loaded[dir] = modules
		dirState[dir] = {}
	end
	if modules[wanted] ~= nil then
		return modules[wanted]
	end

	local sources: { [string]: string } = {}
	for _, name in moduleNames(dir) do
		sources[name] = fs.readFile(pathFor(dir, name))
	end

	-- Sibling realms, filled in only for the ones actually required.
	local parents: { [string]: any } = {}

	local state = dirState[dir] -- name -> "running" | "done"
	local run
	function run(name: string, chain: { string })
		if state[name] == "done" then
			return
		end
		if state[name] == "running" then
			table.insert(chain, name)
			error(`shim/library: require cycle in {dir}: {table.concat(chain, " -> ")}`)
		end
		local source = sources[name]
		if not source then
			--[[
				Not beside us. In a multi-realm package this is a sibling REALM --
				`script.Parent.shared` from inside `src/server`. Resolved on demand rather
				than eagerly, so asking for the server half never loads the client half.
			]]
			local sibling = `{parentOf(dir)}/{name}/init.luau`
			if fs.isFile(sibling) then
				parents[name] = loadModule(`{parentOf(dir)}/{name}`, "init")
			end
			return -- otherwise: a require this shim cannot see; the module will complain
		end
		state[name] = "running"
		table.insert(chain, name)
		for _, dependency in dependenciesOf(source) do
			run(dependency, chain)
		end
		table.remove(chain)

		local environment = table.clone(ENVIRONMENT)
		-- One table for both spellings: an init module's children and a sibling's
		-- Parent's children are the same set of files.
		if name == "init" then
			-- An init module's children are the files beside it; its Parent is the package,
			-- whose children are the other realms.
			modules.Parent = parents
			environment.script = modules
		else
			environment.script = { Parent = modules }
		end
		--[[
			`script.Parent.Config` already IS the module, because the table above holds
			loaded modules rather than instances. So require hands its argument straight
			back.

			It has to be overridden rather than left alone: Lune's own require takes a
			path STRING and rejects a table outright, which is what every
			`require(script.Parent.X)` in a library would hand it.
		]]
		environment.require = function(target: any): any
			if target == nil then
				error(`shim/library: {name} required something this shim could not resolve in {dir}`, 2)
			end
			return target
		end
		modules[name] = luau.load(source, {
			debugName = pathFor(dir, name),
			environment = environment,
			injectGlobals = true,
		})()
		state[name] = "done"
	end

	run(wanted, {})
	return modules[wanted]
end

--[[
	`part` addresses something inside a library's src, covering all three shapes:

	  library("Zone")                      -> Zone/src/init.luau
	  library("Companions", "Loadout")     -> Companions/src/Loadout.luau
	  library("CommunityReward", "server") -> CommunityReward/src/server/init.luau
]]
return function(name: string, part: string?): any
	local dir, module = `{name}/src`, "init"
	if part then
		if fs.isFile(`{name}/src/{part}.luau`) then
			module = part
		else
			dir = `{name}/src/{part}`
		end
	end
	assert(fs.isFile(pathFor(dir, module)), `shim/library: no {pathFor(dir, module)} -- run tests from the repo root`)
	return loadModule(dir, module)
end
