--!strict
-- Shared helper: the single definition of the bot/player distinction.
--
-- A "unit" (a real player or a bot) is identified across both realms by a numeric
-- id. A real player's id is its Roblox `UserId` (always positive); a bot's id is a
-- synthetic negative id allocated by the bot driver from `ALLOC_START` and
-- descending. Because real UserIds are never negative, the sign is a collision-proof
-- discriminator. This module owns that check so no `id < 0` literal lives anywhere
-- else in the codebase; every service asks `IsBot` / `IsPlayer` here.
--
-- WIRE NOTE: every unit-id field on the wire (zap/RemoteEvent) must be a SIGNED type
-- (i53/i32/f64), never u32 -- a negative bot id sent through an unsigned field wraps
-- to a large positive value and IsBot silently fails.

local UnitId = {
	-- The first synthetic bot id. The bot driver allocates from here downward
	-- (-1000, -1001, ...). Kept well clear of 0 so the negative-id space is
	-- unmistakable.
	ALLOC_START = -1000 :: number,
}

-- True if `id` identifies a bot (synthetic negative id).
function UnitId.IsBot(id: number): boolean
	return id <= UnitId.ALLOC_START
end

-- True if `id` identifies a real player (a Roblox UserId).
function UnitId.IsPlayer(id: number): boolean
	return not UnitId.IsBot(id)
end

table.freeze(UnitId)

return UnitId
