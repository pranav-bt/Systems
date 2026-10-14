--!strict
-- Shared Luau types for the Unit system. A pure type module (no runtime values) so it
-- can be required cheaply from anywhere, on either realm.
--
-- In the originating game these two types lived in the project-wide `Types` module.
-- They are split out here so the Unit system carries its own type surface; if your
-- game has a central Types module you may prefer to paste `Unit` / `ClientUnit` into
-- it and point the Unit modules at that instead.

-- A unit identity that stands in for a Roblox `Player` across the server's gameplay
-- systems: either a real player or a server-driven bot. Both expose the same
-- duck-typed surface, so services key state and reason about gameplay over `Unit`
-- without caring which kind it is. Real players carry their Roblox UserId; bots carry
-- a synthetic negative id (see UnitId).
--
-- Declared as a structural interface of the members the server actually touches
-- (rather than `Player | BotPlayer`) so both a real `Player` and a `BotPlayer` are
-- assignable by shape, and existing `player: Player` code keeps working when widened
-- to `unit: Unit` with no narrowing at call sites. The immutable Player members are
-- marked `read` so a real `Player` (whose Name/UserId/CharacterAdded are read-only)
-- assigns cleanly; `Character` stays writable because the bot driver reassigns it on
-- (re)spawn.
export type Unit = {
	read Name: string,
	read UserId: number,
	Character: Model?,
	read CharacterAdded: RBXScriptSignal,
}

-- A client-side view of a unit (real player or bot), resolved from a wire unit id by
-- ClientUnitRegistry. Unifies the two so consumer controllers read `.name` /
-- `.character` without caring which kind it is. `character` is nil between the id
-- arriving and the rig streaming in (see the registry's ordering discipline).
export type ClientUnit = {
	id: number,
	name: string,
	character: Model?,
	isBot: boolean,
}

return nil
