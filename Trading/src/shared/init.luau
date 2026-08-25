--!strict

-- Whether a player may be traded with at all, and if not, why.
--
-- ONE FACT, PUBLISHED ON THE PLAYER, READ BY BOTH REALMS. The server has to REFUSE a
-- trade and the client has to SAY WHY -- a Trade button that greys out with no
-- explanation is the version of this that generates "the game is broken" reports -- so
-- the answer cannot live inside the server module alone. It is written onto the Player,
-- which replicates to everyone, so any client can ask about any other player in a list
-- without a round trip and without the server pushing a roster.
--
-- AN ATTRIBUTE, NOT A CHILD VALUE. This is a single value that every client reads about
-- every OTHER player the moment a trade list is drawn, and `GetAttributeChangedSignal`
-- exists whether or not the attribute has ever been set. A StringValue would put a
-- ChildAdded race in every reader, for nothing.
--
-- SET BY WHOEVER OWNS THE STATE THAT CAUSES IT. A player in a match, in a cutscene, on a
-- cooldown, on a restricted account -- the system that knows when each of those starts and
-- ends is the one that writes here, and the trading module refuses without being told a new
-- rule exists. That is the whole point of it being a published fact rather than a list of
-- conditions inside the trade code.
--
-- CLEARED, NOT SET TO "". A player who has never been blocked and one who has been
-- unblocked have to look identical to a reader, or every reader needs two checks.
--
-- WRITING IS THE SERVER'S. A client can set the attribute on its own Player object, but
-- that write does not replicate to anyone, so it can only ever lie to itself: the server
-- reads its own copy.
--
-- STORE A KEY, NOT A SENTENCE. "InMatch" rather than "Playing a match": the client maps it
-- to whatever it wants to show, in whatever language. A package that shipped the sentence
-- would be shipping English.

local Access = {}

Access.attribute = "TradeBlock"

-- Why this player cannot be traded with, or nil when they can.
function Access.reasonFor(player: Player): string?
	local value = player:GetAttribute(Access.attribute)
	return if type(value) == "string" and value ~= "" then value else nil
end

function Access.canTrade(player: Player): boolean
	return Access.reasonFor(player) == nil
end

-- SERVER ONLY, and the single writer. nil lifts the block.
function Access.set(player: Player, reason: string?)
	assert(
		reason == nil or (type(reason) == "string" and reason ~= ""),
		"Trading.Access.set: reason must be a non-empty string, or nil to lift the block"
	)
	player:SetAttribute(Access.attribute, reason)
end

-- Fires whenever this player's block changes, in either direction. What the trading server
-- listens to so a player who becomes unable to trade takes their trade with them, without
-- the system that blocked them having to know a trade existed.
function Access.changed(player: Player): RBXScriptSignal
	return player:GetAttributeChangedSignal(Access.attribute)
end

return Access
