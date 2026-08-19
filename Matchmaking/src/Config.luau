--!strict

return {
	MIN_PLAYERS = 1, -- minimum players queued (after backfill) before a new Arena server is reserved. 1 because the Arena soft-starts a lone player and fills the field with bots (see Systems/Bots + MatchConfig.SOFT_MIN_PLAYERS), so nobody waits in the lobby for a second human.
	MAX_PLAYERS = 18, -- hard cap for a single Arena server, new or backfilled into
	GRACE_SECONDS = 3, -- once MIN_PLAYERS is met, wait this long for more before finalizing a new match
	REACTION_SECONDS = 3, -- min time a player must be queued before any teleport (even a backfill), so an accidental touch on the matchmaking part can still be cancelled
	QUEUE_ENTRY_TTL = 15, -- MemoryStore TTL for a queued player; refreshed at TTL/2 while still queued
	SERVER_REGISTRY_TTL = 30, -- MemoryStore TTL for an Arena server's open-slot entry; refreshed by its own heartbeat
	LEADER_TICK_SECONDS = 1,
}
