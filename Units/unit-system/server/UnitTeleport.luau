--!strict
-- Authoritative character teleport that survives a client physics handoff. Optional
-- helper -- include it only if your game teleports characters whose physics a client
-- may own (e.g. right after a carry/grab ends).
--
-- A bare server `PivotTo` on a character whose root is client-owned gets overridden:
-- the owning client keeps replicating the old position for a frame and stomps the
-- teleport. This bites hardest right after a carry ends -- the carried body was welded
-- into the CARRIER's assembly, so the carrier's client owned its physics, and the
-- frame the weld is removed the server does not yet own the body.
--
-- The recipe: take server ownership, zero the carried-over velocity, wait a frame for
-- the detach to settle, PivotTo authoritatively, then hand ownership back to the
-- unit's client (nil for a bot -> stays server-owned).
--
-- MOVEMENT-SANITY HOOK: if your game runs server-side movement validation (lag-comp
-- pose history / anti-teleport), the jump is a legitimate discontinuity it would
-- otherwise flag. Assign `UnitTeleport.OnTeleported` to reset that unit's pose history.
-- Left nil (the default) it is simply skipped -- the teleport itself is unaffected.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UnitService = require(script.Parent.UnitService)
local UnitTypes = require(ReplicatedStorage.Shared.UnitTypes)

local UnitTeleport = {}

-- Optional sink, invoked with the teleported unit after an authoritative jump. Wire it
-- to your movement-sanity layer's "forget this unit's pose history" call. Left nil, the
-- teleport still happens; only the history reset is skipped.
UnitTeleport.OnTeleported = (nil :: any) :: ((unit: UnitTypes.Unit) -> ())?

-- Teleports `unit`'s character to `targetCFrame`, taking server physics ownership
-- across the jump so a client (the unit's own, or a former carrier's) can't replicate
-- the old position back over it. No-op if the character or its PrimaryPart is missing.
function UnitTeleport.TeleportCharacter(unit: UnitTypes.Unit, targetCFrame: CFrame)
	local character = unit.Character
	local root = character and character.PrimaryPart
	if not root then
		return
	end

	-- Take server ownership BEFORE moving so the (possibly former-carrier) client can't
	-- win the position race. Safe for a bot rig too -- it is already server-owned.
	root:SetNetworkOwner(nil)
	-- Drop any velocity carried over from being hauled, or the body drifts/launches on
	-- arrival instead of settling at the target.
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	-- Let the detach + ownership change settle before the authoritative move.
	task.wait()
	character:PivotTo(targetCFrame)

	-- Hand physics back to the unit's client; a bot's rig stays server-owned
	-- (ToRealPlayer returns nil, which SetNetworkOwner treats as server ownership).
	root:SetNetworkOwner(UnitService.ToRealPlayer(unit))

	-- The teleport is a legitimate discontinuity: let the host wipe any pose history so
	-- movement sanity doesn't read the jump as a teleport hack.
	if UnitTeleport.OnTeleported then
		UnitTeleport.OnTeleported(unit)
	end
end

return UnitTeleport
