# Moveables

Server-authoritative moving platforms for Roblox. Authored objects (rafts,
elevators, patrol platforms, ...) travel a designer-made waypoint path,
ping-ponging along index-sorted waypoints, pausing at stops, and facing their
direction of travel. A companion client module carries the local character
smoothly while it stands on a platform, with no rubber-banding.

The system is generic: it scans the workspace for **any** `Folder` named
`Moveables` — present at load or spawned later — so you drive it entirely from
authored instances and attributes. There is no per-object code to write.

## Files

| File | Side | What it does |
|---|---|---|
| `src/server/init.luau` | Server | The platform mover. Discovers `Moveables` folders, anchors each mover, and drives its CFrame along the waypoints every `PostSimulation` step. Tags each mover with `MoveableRide`. |
| `src/client/init.luau` | Client | The rider. Watches the `MoveableRide` tag; when the local character stands on a tagged moveable, translates the character by the platform's per-frame movement. |

Both modules return a table with a single `start()` method.

## Dependencies

**None.** The library has zero external dependencies and zero `require`s that
point outside its own folder. It uses only Roblox services
(`CollectionService`, `RunService`, `Players`, `Workspace`). Drop the folder in
anywhere and it works.

The server module ticks itself off `RunService.PostSimulation` — no external
scheduler is needed.

## Configuration / Injection API

There is no runtime injection or config table — behavior is driven entirely by
authored instances/attributes (see the workspace convention below). The tunables
below are module-local constants; edit them in source if you need to change them.

**Server (`src/server/init.luau`):**

| Constant | Default | Meaning |
|---|---|---|
| `DEBUG` | `false` | When `true`, prints a per-object waypoint summary on setup. |
| `MOVEABLES_FOLDER_NAME` | `"Moveables"` | Folder name the workspace scan looks for. |
| `OBJECT_FOLDER_NAMES` | `{ object, objects }` | Accepted names (case-insensitive) for the movers folder. |
| `PATHS_FOLDER_NAME` | `"paths"` | Name (case-insensitive) of the paths folder. |
| `PATH_ATTRIBUTE` | `"Path"` | Object attribute naming which path to follow. |
| `SPEED_ATTRIBUTE` | `"Speed"` | Object attribute for studs/s (optional). |
| `STOP_TIME_ATTRIBUTE` | `"StopTime"` | Stop-waypoint attribute for pause seconds. |
| `RIDE_TAG` | `"MoveableRide"` | CollectionService tag applied to movers (cross-side contract; see below). |
| `DEFAULT_SPEED` | `16` | studs/s when an object has no `Speed`. |
| `ARRIVE_EPSILON` | `0.1` | studs; snap + advance once this close to the target. |
| `YAW_LERP_RATE` | `5` | Higher = snappier turns (exponential, framerate-independent). |

**Client (`src/client/init.luau`):**

| Constant | Default | Meaning |
|---|---|---|
| `RIDE_TAG` | `"MoveableRide"` | Tag the rider watches (must match the server; see below). |
| `FLOOR_PROBE` | `6` | studs below the root still counted as "standing on". |

### The `MoveableRide` tag contract

`RIDE_TAG = "MoveableRide"` is the **only** cross-side contract between server
and client. The server adds this CollectionService tag to every active mover; the
client rider raycasts down from the character and, if it lands on a tagged
instance (or a descendant of one), carries the character by that platform's
per-frame translation. If you change the string, change it in **both** files
identically.

## Usage example

```lua
-- Server (e.g. a Script in ServerScriptService)
local Moveables = require(path.to.Moveables.server)
Moveables.start()

-- Client (e.g. a LocalScript in StarterPlayerScripts)
local MoveableRider = require(path.to.Moveables.client)
MoveableRider.start()
```

Call each `start()` once. `start()` is idempotent on the server (guarded by a
`started` flag). No further calls are needed — new `Moveables` folders and movers
spawned later are picked up automatically.

## Workspace convention (the public API)

You author everything as instances + attributes. The layout:

```
workspace/
  <anywhere>/
    Moveables/               -- a Folder literally named "Moveables"
      Object(s)/             -- Folder named "Object" or "Objects" (case-insensitive)
        Raft                 -- a Model or BasePart mover (see attributes below)
        Elevator             -- ...more movers
      Paths/                 -- Folder named "Paths" (case-insensitive)
        RaftPath/            -- one Folder per path, named to match a mover's `Path`
          1_Stop             -- BasePart waypoints, named "<index>_<Path|Stop>"
          2_Path
          3_Stop
          ...
```

- **`Moveables` folder** — the system finds every `Folder` named exactly
  `Moveables` anywhere in the workspace, at load or spawned later. You may have
  many. Each holds one objects folder and one paths folder.
- **`Object` / `Objects` folder** — holds the movers. Each mover is a `Model` or
  `BasePart`. May be parented in after the `Moveables` folder (incremental spawn);
  it is picked up when it appears. Adding/removing children starts/stops movers
  live.
- **`Paths` folder** — holds one child `Folder` per path. A mover finds its path
  by name: the folder's name must equal the mover's `Path` attribute.

### Mover attributes

| Attribute | Type | Required | Meaning |
|---|---|---|---|
| `Path` | string | **Yes** | Name of the path folder under `Paths` to follow. An object with no `Path` attribute is ignored (not a mover). |
| `Speed` | number | No | Travel speed in studs/s. Falls back to `DEFAULT_SPEED` (16) if absent or not a positive number. |

Movers are **anchored** by the library (all descendant `BasePart`s + the object
itself) so movement is exact and server-authoritative.

### Waypoint parts

Inside a path folder, each waypoint is a `BasePart` named `<index>_<kind>`:

- **`<index>`** — an integer that sets traversal order (parts are index-sorted;
  the numbers need not be contiguous). e.g. `1_Path`, `2_Stop`, `10_Path`.
- **`<kind>`** — `Path` (a pass-through waypoint) or `Stop` (pause here).
  Case-insensitive. Parts whose name doesn't match `^<index>_<word>$` are skipped.

A path needs **at least 2 waypoints**; fewer produces a warning and the mover
does not start.

### Stop attribute

| Attribute | Type | On | Meaning |
|---|---|---|---|
| `StopTime` | number (or numeric string) | `<index>_Stop` waypoints | Seconds to pause when the mover arrives. A `Stop` with no positive `StopTime` warns and does not pause. |

### Motion behavior

- Movers **ping-pong**: they traverse the sorted waypoints, then reverse
  direction at either end (no wrap-around).
- The mover **faces its travel direction** via a framerate-independent yaw lerp
  (`YAW_LERP_RATE`); position is always exact. While paused at a stop it holds its
  facing (no spin in place).
- Carry is **translation-only** on the client: the rider keeps its own facing when
  a platform yaws, avoiding a disorienting camera swing.

## Changes from the CastleWars original

The library preserves the original logic and behavior exactly; only the two
external couplings were removed:

1. **Debug gating** — the original `require(ReplicatedStorage.Shared.DebugConstants)`
   and its `DebugConstants.DebugEnabled` check (used only to gate the per-object
   setup `print`) were replaced with a module-local `local DEBUG = false`. The
   gated prints are unchanged.
2. **Scheduler** — the original `require(ServerScriptService.Server.ServerScheduler)`
   and its `ServerScheduler.schedule("PostSimulation", "Moveables", update)` call
   were replaced with a self-contained `RunService.PostSimulation:Connect(update)`.
   `PostSimulation` fires once per step with the frame delta as its sole argument,
   which matches `update(dt)`'s signature exactly — so the timing and behavior are
   identical, with no external scheduler.

The unused `ReplicatedStorage` and `ServerScriptService` service handles were
dropped along with those requires; `RunService` was added.

The client rider was **copied verbatim** — it already had zero requires. Its
`RIDE_TAG = "MoveableRide"` const is kept identical to the server's.
