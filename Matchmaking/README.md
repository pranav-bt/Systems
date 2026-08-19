# Matchmaking

Cross-server, region-shardable matchmaking for a two-place (Lobby → Arena) Roblox
game. No rank/ELO — it simply pools queued players and gets them into an Arena
server as fast as possible.

## Overview

Runs on your **Lobby** servers. Across all Lobby servers a single **leader** is
elected (MemoryStore compare-and-swap on `game.JobId`), and only that leader runs
the scan loop. Each tick the leader:

1. **Backfill** — tops up any Arena server that self-registered open slots
   (`MemoryStore.publishServerCapacity`) from the queue, immediately and with no
   minimum, since joining a match in progress is fine.
2. **New match formation** — whatever is left ships only once at least
   `MIN_PLAYERS` are waiting; after that it waits up to `GRACE_SECONDS` for more
   (capped at `MAX_PLAYERS`), then `TeleportService:ReserveServer`s a fresh Arena
   server and teleports the batch.

Players who queued from the same Lobby server (same `JobId`) are grouped and
preferred when forming a new match, so parties tend to land together. Players who
have moved to another Lobby server since queueing are reached via a
`MessagingService` broadcast (`<keyPrefix>MMTeleport`).

Region sharding is available (an ISO country → region table in `Regions.luau`)
but is **disabled in the shipped code** behind `TEMP` comments — everyone enqueues
into a single `NorthAmerica` shard so small/mixed pools still reach `MIN_PLAYERS`.
The region string is only an internal partition key; it never gates eligibility.
The commented-out blocks in `init.luau` (`getRegion` and the region loop in the
leader loop) restore per-lobby region resolution.

## Files

| File | Role |
|---|---|
| `src/init.luau` | Orchestrator + public API. Queue lifecycle, teleport, MessagingService hand-off, and the leader scan loop. |
| `src/LeaderElection.luau` | Cross-server mutual exclusion — MemoryStore hashmap compare-and-swap so exactly one Lobby server runs the loop. |
| `src/MemoryStore.luau` | MemoryStore helpers: the queue (`SortedMap`, sortKey = joinTime) and the per-server capacity registry (`SortedMap`, sortKey = openSlots). Holds the injected key prefix. |
| `src/Regions.luau` | ISO 3166-1 alpha-2 country → broad region table. Fully generic. |
| `src/Config.luau` | Plain tunables table (see below). |

## Dependencies

- **[Promise](https://github.com/evaera/roblox-lua-promise)** (`evaera/promise`) —
  declared in `wally.toml`. This is the only external dependency. Everything else
  is Roblox engine services (`MemoryStoreService`, `MessagingService`,
  `TeleportService`, `Players`, `RunService`).

Run your usual Wally install so the package resolves `Promise` as a sibling. Within
the package the require paths are already package-relative:
`init.luau` → `require(script.Parent.Promise)`, `MemoryStore.luau` →
`require(script.Parent.Parent.Promise)`.

## Configuration / Injection API

`Matchmaking.start(config)` takes a table. This is how the library stays
host-agnostic — the two CastleWars-specific `Places` calls in the original are now
injected, and remotes are no longer referenced at all.

| Field | Type | Required | Purpose |
|---|---|---|---|
| `resolveTargetPlaceId` | `() -> number` | yes | The Arena place formed matches are teleported to / reserved on. **Replaces** `Places.GetPlaceId("Arena", Places.GetCurrentPlaceKind())`. Called at teleport/reserve time, so you can return different IDs per environment. |
| `keyPrefix` | `string` | yes | MemoryStore namespace prepended to every queue/registry/leader/messaging key. **Replaces** `Places.GetCurrentPlaceKind()` inside `MemoryStore.luau` (which the original used as the prefix). Keep it distinct per environment (e.g. `"Production"`, `"Testing"`, `"Studio"`) so Studio/staging/production never share a queue. Threaded into `MemoryStore` via `MemoryStore.setKeyPrefix` at boot. |
| `onStatus` | `(player: Player, status: { queued: boolean }) -> ()` | no | Push callback fired when a player's queue status changes (`{ queued = true }` on join, `{ queued = false }` on exit). **Replaces** the direct `ReplicatedStorage.Remotes.MatchmakingStatus_RS:FireClient(player, …)`. Wire it to your own remote. Omit it if you only poll `getStatus`. |
| `onMatchFormed` | `(players: { Player }, accessCode: string) -> ()` | no | Called with the local players a formed match has selected, immediately before dispatch — before the Studio branch and before any teleport can fail, so a formed match is recorded even when getting players into it does not work. Narrower than it looks: a match forms on the leader, but its players may sit on several lobby servers, so this fires wherever each selected player actually **is** and only for players that server can see. Paired with `onBeforeTeleport`, the gap between them is *dispatch failure* (TeleportAsync failing and re-queueing the party) — not "selected and never heard from again", which no per-player hook can report. Errors are caught and warned. |
| `onBeforeTeleport` | `(players: { Player }, accessCode: string) -> ()` | no | Called once with the matched group immediately before `TeleportAsync` — the host's last chance to act on those players while they are still its own. Use it for anything that must distinguish *"teleported into a match"* from *"quit"*, which `PlayerRemoving` cannot: a telemetry session handoff so the hop reads as one continuous session rather than a bounce, or a final save. Runs only on the real teleport path (the Studio branch kicks, and a kick genuinely **is** a leave). Errors are caught and warned — a host callback can never strand a matched party in the lobby. |
| `tunables` | `{ [string]: number }` | no | Per-boot overrides for any `Config.luau` field (`MIN_PLAYERS`, `MAX_PLAYERS`, `GRACE_SECONDS`, `REACTION_SECONDS`, `QUEUE_ENTRY_TTL`, `SERVER_REGISTRY_TTL`, `LEADER_TICK_SECONDS`). Applied over the defaults at `start`. |

### Config.luau defaults

| Key | Default | Meaning |
|---|---|---|
| `MIN_PLAYERS` | `1` | Min queued (after backfill) before a new Arena server is reserved. |
| `MAX_PLAYERS` | `18` | Hard cap for a single Arena server, new or backfilled into. |
| `GRACE_SECONDS` | `3` | Once `MIN_PLAYERS` is met, wait this long for more before finalizing. |
| `REACTION_SECONDS` | `3` | Min time queued before any teleport, so an accidental queue can be cancelled. |
| `QUEUE_ENTRY_TTL` | `15` | MemoryStore TTL for a queued player; refreshed at TTL/2 while queued. |
| `SERVER_REGISTRY_TTL` | `30` | MemoryStore TTL for an Arena server's open-slot entry. |
| `LEADER_TICK_SECONDS` | `1` | Leader scan cadence. |

> The default `MIN_PLAYERS = 1` and its comment reflect CastleWars (its Arena
> soft-starts a lone human and fills the field with bots). Override via `tunables`
> if your Arena needs a real minimum.

## Public API

Returned by `require`:

| Member | Signature | Notes |
|---|---|---|
| `Matchmaking.start` | `(config: Config) -> ()` | Boot on each Lobby server. Sets the key prefix, applies tunable overrides, subscribes to the teleport broadcast, starts leader election, and connects `PlayerRemoving`. Does **not** create or connect any remotes. |
| `Matchmaking.joinQueue` | `(player: Player) -> ()` | Enqueue a player. Idempotent while queued. Fires `onStatus(player, { queued = true })`. |
| `Matchmaking.exitQueue` | `(player: Player) -> ()` | Dequeue a player. Fires `onStatus(player, { queued = false })`. |
| `Matchmaking.getStatus` | `(player: Player) -> { queued: boolean }` | Current status for polling / on-demand pushes. |
| `Matchmaking.isQueued` | `(player: Player) -> boolean` | Convenience predicate. |
| `Matchmaking.onPlayerRemoving` | `(player: Player) -> ()` | Connected automatically by `start`; exposed for manual wiring/testing. |

Arena servers publish their capacity themselves using the `MemoryStore` helpers so
the leader can backfill them:

```lua
local MemoryStore = require(path.to.Matchmaking.MemoryStore)
-- On the Arena server (use the SAME keyPrefix and region the lobby used):
MemoryStore.setKeyPrefix("Production")
MemoryStore.publishServerCapacity(accessCode, region, game.JobId, openSlots) -- refresh on a heartbeat
MemoryStore.removeServerCapacity(accessCode, region)                        -- when full/closing
```

## Usage example (host wiring remotes to the API)

```lua
-- ServerScriptService on the LOBBY place
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Matchmaking = require(ReplicatedStorage.Packages.Matchmaking)

-- The host owns its remotes; the library never touches them.
local joinRemote = ReplicatedStorage.Remotes.JoinMatchmaking_RC   -- RemoteEvent
local leaveRemote = ReplicatedStorage.Remotes.LeaveMatchmaking_RC  -- RemoteEvent
local statusRemote = ReplicatedStorage.Remotes.MatchmakingStatus_RS -- RemoteEvent

Matchmaking.start({
    -- was Places.GetPlaceId("Arena", Places.GetCurrentPlaceKind())
    resolveTargetPlaceId = function()
        return MyPlaces.GetArenaPlaceId()
    end,

    -- was Places.GetCurrentPlaceKind()
    keyPrefix = MyPlaces.GetCurrentPlaceKind(), -- e.g. "Production"

    -- was ReplicatedStorage.Remotes.MatchmakingStatus_RS:FireClient(player, status)
    onStatus = function(player, status)
        statusRemote:FireClient(player, status)
    end,

    -- optional
    -- tunables = { MIN_PLAYERS = 4, MAX_PLAYERS = 12 },
})

-- Wire your remotes to the public API.
joinRemote.OnServerEvent:Connect(function(player)
    Matchmaking.joinQueue(player)
end)

leaveRemote.OnServerEvent:Connect(function(player)
    Matchmaking.exitQueue(player)
end)

-- Push initial status on request (or poll however you like):
-- statusRemote:FireClient(player, Matchmaking.getStatus(player))
```

## Changes from the CastleWars original

- **Removed the `Places` dependency entirely.** The two call sites are now injected:
  - `placeId()` was `Places.GetPlaceId("Arena", Places.GetCurrentPlaceKind())` →
    now `config.resolveTargetPlaceId()`.
  - `MemoryStore.luau` computed its key prefix from `Places.GetCurrentPlaceKind()`
    at module load → the prefix is now injected via `config.keyPrefix` and threaded
    in with `MemoryStore.setKeyPrefix(config.keyPrefix)` inside `Matchmaking.start`.
    `MemoryStore.PREFIX` starts as `""`.
- **Removed all three direct remote references.** The old `Matchmaking.init`
  connected `JoinMatchmaking_RC` / `LeaveMatchmaking_RC` and fired
  `MatchmakingStatus_RS`. The library no longer references any remote. Instead:
  - `Matchmaking.joinQueue` / `Matchmaking.exitQueue` are the public entry points
    the host connects its own remotes to.
  - Status updates go through `config.onStatus(player, status)` (fired exactly
    where the old code fired `MatchmakingStatus_RS`), plus a pull-style
    `Matchmaking.getStatus(player)`.
- **Boot entry point renamed/reshaped.** The old boot function `Matchmaking.init()`
  became `Matchmaking.start(config)`. The old leader-loop producer (previously the
  public `Matchmaking.start`) is now a private `runLeaderLoop` local passed to
  `LeaderElection.start`.
- **Added `config.tunables`** for optional per-boot overrides of `Config.luau`
  values.
- **Require paths made package-relative.** `require(ReplicatedStorage.Packages.Promise)`
  → `require(script.Parent.Promise)` in `init.luau` and
  `require(script.Parent.Parent.Promise)` in `MemoryStore.luau`. Internal
  cross-module requires (`script.Config`, `script.Parent.MemoryStore`, …) were
  already relative and are unchanged.
- **Behavior preserved.** Queue lifecycle, TTL refresh, reaction window, backfill,
  grace/cap formation, same-lobby grouping, Studio kick path, MessagingService
  hand-off, and leader election are byte-for-byte unchanged aside from the wiring
  points above. `--!strict` pragmas are kept where they were present
  (`Regions`, `LeaderElection`, `MemoryStore`, `Config`); `init.luau` remains
  non-strict, as in the original.
- **Region sharding remains disabled** behind the original `TEMP` comments (single
  `NorthAmerica` shard), unchanged from CastleWars.
```
