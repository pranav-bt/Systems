-- Loads a library's REAL source under the Roblox shim.
--
-- Zone's sources use only Roblox globals -- no `require(script.Parent.X)` -- so
-- they can be compiled with an injected environment instead of being copied and
-- rewritten. That matters: a vendored copy silently drifts from the library, and
-- the tests then keep passing against code that no longer ships. There is nothing
-- to drift here, because this reads the file itself.
--
-- Paths are relative to the REPO ROOT, so run tests from the Libraries directory:
--   lune run Tests/tests/test-zone.luau
--
-- LIMITATION: single-file libraries only. A multi-file package needs its internal
-- `require(script.Parent.X)` calls resolved, which this does not do -- that is why
-- `tests/vendor/` still exists for Bots.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local rbx = require("./roblox")

local ENVIRONMENT = {
	game = rbx.game,
	Instance = rbx.Instance,
	Enum = rbx.Enum,
	Vector3 = rbx.Vector3,
	CFrame = rbx.CFrame,
	workspace = rbx.workspace,
	typeof = rbx.typeof,
	task = rbx.task,
}

return function(name: string, realm: string?): any
	-- A realm names a subfolder for the server+client libraries (TimeSync, CommunityReward);
	-- omit it for the single-file ones.
	local path = if realm then `{name}/src/{realm}/init.luau` else `{name}/src/init.luau`
	assert(fs.isFile(path), `shim/library: no {path} -- run tests from the repo root`)
	local chunk = luau.load(fs.readFile(path), {
		debugName = name,
		environment = ENVIRONMENT,
		injectGlobals = true,
	})
	return chunk()
end
