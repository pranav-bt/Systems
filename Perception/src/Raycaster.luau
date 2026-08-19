--!strict

-- The default Roblox raycast: a tiny factory wrapping workspace:Raycast into
-- the package's RaycastFn shape. Everything Roblox-specific about rays lives
-- here; Vision and Hearing only ever see the injected function.
--
-- FILTERING MATTERS. Line-of-sight rays that can hit character bodies make a
-- target's own limbs read as "cover" (never seen) and bots block each other's
-- ears. Pass a RaycastParams excluding character/bot folders -- most games
-- already maintain exactly that list.
--
-- Construction is lazy (params are only built on the first actual cast), so
-- requiring this module -- and building sensors with default config -- stays
-- safe outside Roblox; only casting needs the real workspace.

local Types = require(script.Parent.Types)

local Raycaster = {}

function Raycaster.new(params: RaycastParams?): Types.RaycastFn
	local resolved = params
	return function(origin: Vector3, direction: Vector3)
		if resolved == nil then
			local fresh = RaycastParams.new()
			fresh.FilterType = Enum.RaycastFilterType.Exclude
			resolved = fresh
		end
		return workspace:Raycast(origin, direction, resolved)
	end
end

return Raycaster
