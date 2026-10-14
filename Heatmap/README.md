# Heatmap

An anonymized player-movement heatmap recorder for Roblox servers. It samples
each player's `HumanoidRootPart` position on a fixed interval, voxelizes the
position into a grid cell, RLE-compresses the per-session journey, strips all
identifying data (UserId is replaced with a random GUID), and flushes anonymized
session batches to a DataStore on server shutdown.

## Overview

- **Sampling** — a single `RunService.Heartbeat` connection samples every active
  player, throttled per-player to `SAMPLE_INTERVAL` seconds. Each sample is the
  player's position floored into a voxel cell (`{x, y, z}` integers).
- **Anonymization** — sessions are keyed by `UserId` only while the player is
  in-server. On `PlayerRemoving` (and at shutdown for anyone still present) the
  session is re-keyed to a fresh `HttpService:GenerateGUID(false)`. The `UserId`
  is never written to the DataStore.
- **Compression** — before writing, each journey is run-length encoded: runs of
  identical cells (a player standing still) collapse to a single
  `{x, y, z, runLength}` tuple.
- **Persistence** — all pending + remaining active sessions are merged into one
  `UpdateAsync` write, keyed by the server `JobId`. Writes happen only from
  `BindToClose` — there is no periodic timer.

## Files

| File | Purpose |
|---|---|
| `src/init.luau` | The entire library. Returns the `Heatmap` module table. |

## Dependencies

None beyond Roblox services. The module uses only `DataStoreService`,
`HttpService`, `Players`, and `RunService`. There are no Wally packages and no
`require` calls of any kind — it is fully standalone.

## Configuration / Injection API

Call `Heatmap.configure(overrides)` once **before** `Heatmap.init()` to override
any of the fields below. It shallow-merges `overrides` into the internal
`CONFIG`, leaving unspecified fields at their defaults, so calling nothing keeps
the original CastleWars behavior. `CELL_SIZE`, `ORIGIN`, `SAMPLE_INTERVAL`, and
`MAX_JOURNEY_SAMPLES` are read live (they also take effect if changed after
`init()`); changing `DATASTORE_NAME` re-resolves the DataStore on the next flush.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `CELL_SIZE` | number | `12` | Voxel cell edge length in studs. Larger = coarser heatmap, smaller DataStore footprint. |
| `ORIGIN` | Vector3 | `Vector3.new(0, 0, 0)` | World-space point that cells are measured relative to. Positions are offset by this before flooring, so a map not centred on world origin can be anchored here. Default reproduces the original behavior (cells relative to world origin). |
| `SAMPLE_INTERVAL` | number | `1` | Seconds between position samples per player. |
| `MAX_JOURNEY_SAMPLES` | number | `600` | Hard cap on samples kept per session. When exceeded, the **oldest** samples are dropped and the most recent `MAX_JOURNEY_SAMPLES` are kept. |
| `DATASTORE_NAME` | string | `"LobbyHeatmap_v1"` | Name passed to `DataStoreService:GetDataStore`. |

> Note: positions are **not** bounds-clamped. Cells can be negative or
> arbitrarily large depending on where players roam relative to `ORIGIN`; the
> only size limit is `MAX_JOURNEY_SAMPLES`. There is no fixed map size assumed.

### Public functions

| Function | Description |
|---|---|
| `Heatmap.configure(overrides)` | Merge config overrides. Call before `init()`. |
| `Heatmap.init()` | Register player lifecycle hooks, start the sampling loop, and bind flush to shutdown. Call once from a server Script. |
| `Heatmap.setFunnelStep(player, step)` | Record the highest funnel step reached this session. Only advances, never regresses. |
| `Heatmap.setMeta(player, key, value)` | Attach arbitrary (non-identifying) metadata to the session, e.g. `mapName` or `funnelPath`. |
| `Heatmap.decodeJourney(rle)` | Utility (for offline/Open Cloud analysis): expand an RLE journey back to a flat array of `{x, y, z}` cells, one per sample. Index `N` maps to `(N-1) * SAMPLE_INTERVAL` seconds into the session. |

## Record / flush lifecycle

1. `Heatmap.init()` seeds `activeSessions` for players already present, then
   listens for `PlayerAdded` / `PlayerRemoving`.
2. The Heartbeat loop appends a voxel cell to each active session's `journey`
   every `SAMPLE_INTERVAL` seconds.
3. On `PlayerRemoving`, `archiveSession` fires: it removes the `UserId` keys,
   enforces the `MAX_JOURNEY_SAMPLES` cap (keeping the newest samples),
   RLE-encodes the journey, and moves it into `pendingFlush` under a new GUID.
4. On `BindToClose`, `flush` archives anyone still in-server, drains
   `pendingFlush`, and writes everything in one `UpdateAsync` keyed by `JobId`.
   The write is a no-op if there are no sessions.

## DataStore layout

- **DataStore:** `CONFIG.DATASTORE_NAME` (default `"LobbyHeatmap_v1"`)
- **Key:** `"HeatmapBatch_" .. game.JobId` — one entry per server instance.
- **Value:**

```lua
{
    meta = {
        lastUpdated  = <os.time()>,      -- unix seconds of the flush
        placeVersion = <game.PlaceVersion>,
        serverJobId  = <game.JobId>,
    },
    sessions = {
        [guid] = {                        -- anonymous GUID, never a UserId
            meta = {
                funnelStep = <number>,    -- 0 by default
                funnelPath = <string>,    -- "none" by default
                -- ...any keys added via setMeta
            },
            journey = {                   -- RLE-encoded
                { x, y, z, runLength },   -- integer cell coords + run count
                ...
            },
        },
        ...
    },
}
```

`UpdateAsync` merges new sessions into any existing value for the same `JobId`;
GUID keys guarantee no collisions across merges.

## Usage example

```lua
local Heatmap = require(ServerStorage.Libraries.Heatmap)

-- Optional: override defaults before init().
Heatmap.configure({
    DATASTORE_NAME = "CastleWarsHeatmap_v1",
    CELL_SIZE = 8,
    ORIGIN = workspace.Map.RedBase.Position, -- anchor cells to the map
})

Heatmap.init()

-- Later, from funnel/gameplay code:
Heatmap.setFunnelStep(player, 3)
Heatmap.setMeta(player, "funnelPath", "skip")
Heatmap.setMeta(player, "mapName", "Skybridge")
```

## From game system to package

Started as `src/ServerStorage/Libraries/Analytics/LobbyHeatmap.lua` in CastleWars.

- **Renamed** the public identity from `LobbyHeatmap` to `Heatmap` (module table,
  header title, and the `[LobbyHeatmap]` log prefixes → `[Heatmap]`). The
  internal algorithm (voxelization, RLE, session/flush logic) is unchanged.
- **Added `Heatmap.configure(overrides)`** — shallow-merges into `CONFIG` so
  `DATASTORE_NAME`, `CELL_SIZE`, `ORIGIN`, `SAMPLE_INTERVAL`, and
  `MAX_JOURNEY_SAMPLES` are all overridable. Defaults are unchanged, so
  unconfigured behavior is identical to the original.
- **Made the DataStore handle lazy.** The original resolved
  `DataStoreService:GetDataStore(CONFIG.DATASTORE_NAME)` at module load, which
  would ignore a later `DATASTORE_NAME` override. It is now resolved on first use
  via `getDataStore()` and re-resolved when `configure` changes the name. Runtime
  behavior with the default name is unchanged (the store is still resolved before
  the only write, which happens at shutdown).
- **Surfaced the implicit map origin as `CONFIG.ORIGIN`** (default
  `Vector3.new(0, 0, 0)`). The original voxelized positions relative to world
  origin with no offset; `posToCell` now subtracts `ORIGIN` first. With the
  default, the arithmetic is identical.
- **Doc fix:** the original header showed `LobbyHeatmap.setFunnelPath(...)`, but
  no such function exists (there is no dedicated funnel-path setter). The usage
  example now uses `setMeta(player, "funnelPath", ...)`, which is the actual API.
  No functions were added or removed.
- No project-specific requires existed, so none were injected or inlined — the
  module was already free of CastleWars dependencies.
