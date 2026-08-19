# Placement

A standalone Roblox library for free-form structure placement: a live client-side
**preview ghost** with server **re-validation** and authoritative spawning. It has
**zero gameplay coupling** — no class/economy/team/match ties. Everything it needs
is injected: an infrastructure grid, an asset catalog, and (optionally) a scheduler.

## Overview

- **Client** raycasts from the cursor (or camera center on mobile), snaps a ghost
  model to a `0.5`-stud world grid and to neighbouring `SnapPoints`, then tints a
  `Highlight` green/red based on `GetTouchingParts` collision + voxel-occupancy
  checks. On click it fires a `PlaceItem` remote (or, in delete mode, sends the
  targeted object).
- **Server** re-validates every placement (surface rules, voxel occupancy, overlap
  compatibility, and its own `GetTouchingParts` collision pass), clones the real
  model into `workspace`, records voxel occupancy, and replicates the result to all
  clients. It also handles deletion.
- The server **self-provisions** its `PlaceItem` `RemoteEvent` under
  `ReplicatedStorage` and registers the `Preview`/`Players` collision groups, so no
  central remotes folder is required. The client resolves the same remote with
  `WaitForChild`.

Input controls (default bindings): `Q` select item, `E` hide preview, `Z` cycle
item, `R` rotate, `F` delete mode, `MouseButton1` place/delete. A minimal on-screen
touch UI is created for mobile.

## Files

```
src/
  client/
    init.luau            -- entry point; ClientPlacement.init(config)
    Context.luau         -- injection context (grid / modelsSource / scheduler)
    DefaultGrid.luau     -- default uniform voxel grid (replaces CastleWars Map)
    DefaultScheduler.luau-- default self-contained RunService scheduler
    PlacementInput.luau  -- Spark Actions + bindings
    PreviewManager.lua   -- ghost lifecycle, raycast, place/delete driving
    Placement3D.luau     -- alignment, snapping, surface rules, collision test
    PlacementValidator.lua-- voxel occupancy + highlight tinting
    Items.luau           -- placeable-model catalog derived from modelsSource
    Utils/
      RaycastUtils.lua   -- screen-ray helpers (see Notes: unused by live modules)
  server/
    init.luau            -- entry point; Placement.init(config)
    PlacementData.lua    -- server voxel/occupancy state tables
  shared/
    ItemDefinitions.luau -- item-definition schema + example catalog (both sides)
default.project.json     -- mounts src/ as a single `Placement` folder
wally.toml               -- Spark dependency
```

## Dependencies

- **Spark** (`nezuo/spark@0.3.0`) — used by `PlacementInput` for input Actions.
  Resolved at `ReplicatedStorage.Packages.Spark` (the standard Wally shared path).
  This is the only permitted require outside the library. To swap in a different
  input system, replace `PlacementInput.luau` (it only needs to expose
  `actions` with `justPressedSignal(name)` and `press(name)`).

Install with your usual Wally flow (`wally install`).

## Mounting

`default.project.json` maps `src/` into a single `Placement` folder with `client`,
`server`, and `shared` as siblings. **All requires are relative and depend on this
sibling layout** (e.g. a client submodule reaches the shared schema via
`script.Parent.Parent.shared.ItemDefinitions`; the server via
`script.Parent.shared.ItemDefinitions`). Mount the whole `Placement` folder
somewhere replicated (e.g. `ReplicatedStorage.Placement`), then:

- a **Script** requires `Placement.server` and calls `.init(...)`;
- a **LocalScript** requires `Placement.client` and calls `.init(...)`.

Keeping the whole tree together (including `server`) in a replicated location is
fine — the server ModuleScript only runs when a server Script requires it.

## Configuration / Injection API

### Client — `require(Placement.client).init(config)`

| field | type | default | purpose |
|---|---|---|---|
| `modelsSource` | `Folder` | `ReplicatedStorage:FindFirstChild("ItemDefinitions")` | Folder whose child `Model`s are the placeable catalog. **Effectively required** — without it the preview inventory is empty. |
| `grid` | `Grid?` | `DefaultGrid.new(gridConfig)` | Voxel-grid interface (see below). Inject the host's grid/Map to share occupancy with other systems. |
| `gridConfig` | `table?` | — | Passed to `DefaultGrid.new` when `grid` is omitted. |
| `scheduler` | `Scheduler?` | `DefaultScheduler` | Per-frame scheduler (see below). |
| `createMobileUI` | `boolean?` | `true` | Whether to build the on-screen touch buttons. |

### Server — `require(Placement.server).init(config)`

| field | type | default | purpose |
|---|---|---|---|
| `modelsSource` | `Folder` | `ReplicatedStorage:FindFirstChild("ItemDefinitions")` | Folder to clone placed models from. **Must contain the same models the client places** (matched by name). Asserted non-nil. |

Call each `init` exactly once (the server one creates a `RemoteEvent` and registers
collision groups).

### Grid interface

The client only ever calls `grid.positionToCoord(pos)` and reads `grid.voxelSize`.
`positionToCoord` is a **dot** function (not a method), so a host can inject a plain
module such as CastleWars' `Map`:

```lua
type Grid = {
    positionToCoord: (position: Vector3) -> Vector3, -- world pos -> integer voxel coord
    voxelSize: number,
}
```

`DefaultGrid.new(config)` provides a uniform grid out of the box:

```lua
DefaultGrid.new({
    voxelSize = 3,             -- studs per voxel (default 3)
    origin = Vector3.zero,     -- world position mapped to coord (0,0,0)
    bounds = nil,              -- optional { min = Vector3, max = Vector3 } (unused by placement)
})
-- positionToCoord(p) = floor((p - origin) / voxelSize) per axis
```

The server never computes coordinates — it stores whatever coords the client sends —
so grid consistency is automatic and the grid is a **client-only** injection.

### Catalog / models source

The catalog has two halves:

1. **Data** — `shared/ItemDefinitions.luau`: a keyed table of `ItemData` (schema
   below). Required by both client and server from the shared location.
2. **Models** — a `Folder` of `Model` instances (`modelsSource`), injected via
   `init`. `Items.luau` turns every `Model` directly under this folder into a
   placeable preview keyed by its name; each such model should have a matching
   `ItemDefinitions` entry. The server clones the real model from the same folder
   by name.

The bundled entries (`Chunks`, `Baseplate`, `Barricade`) are an **example** catalog;
replace/extend `ItemDefinitions` and point `modelsSource` at your own models.

### Scheduler

```lua
type Scheduler = {
    schedule: (phase: string, name: string, callback: (dt: number) -> ()) -> () -> (),
}
```

Two phases are used: `"Input"` (poll input each frame) and `"PostSimulation"`
(update the preview). `DefaultScheduler` maps them to `RunService.PreRender` and
`RunService.Heartbeat` respectively — matching the original CastleWars
`ClientScheduler` wiring — so no external scheduler is needed. Inject your own to
integrate with a host frame loop.

## ItemDefinition schema

```lua
export type ItemData = {
    Type: string,                    -- logical type used for snap/surface matching
    PlacementSurface: string,        -- "Floor" or another item's Type it may sit on
    Category: string,                -- e.g. "Floor", "Wall", "Barricade"
    AllowOverlapWith: { string },    -- Categories this item may share a voxel with
    PlacementType: string?,          -- "HorizontalSurface" forces normal.Y >= 0.9
    TouchAllowedObjects: {}?,        -- Types allowed to touch without blocking
    PlacementAnchorType: string?,
    Origin: string?,                 -- "Top" | "Bottom" adjusts vertical base offset
    RotationCorrection: CFrame?,
    IgnorePointerOnSnap: boolean?,   -- skip pointer/surface rule while snapped
    SnapSearchDistanceThresholdOverride: number?,
    SnapDistanceThresholdOveride: number?,   -- (sic) original spelling preserved
    FixedOrientationOnSnap: Vector3?,        -- force this normal while snapped
    SnapPoints: {
        [string]: {                  -- snap point name (also an attachment name)
            Position: Vector3,       -- local offset from the model center
            CompatibleWith: { string }, -- item Types that may snap here
            SnapTo: { string },      -- this model's own snap points to align
        },
    }?,
}
```

`ItemDefinitions.luau` also exports the same via `cloneItem(item, primaryPart?)`. If
you pass a model's `PrimaryPart`, `SnapPoints[*].Position` is derived from live
attachment geometry (`primaryPart[snapName].WorldCFrame - primaryPart.Center...`);
otherwise the authored `Position` is used. The example catalog passes nil.

## Usage example

Server `Script`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Placement = require(ReplicatedStorage.Placement.server)

Placement.init({
    modelsSource = ReplicatedStorage.PlaceableModels, -- your Folder of Models
})
```

Client `LocalScript`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Placement = require(ReplicatedStorage.Placement.client)

Placement.init({
    modelsSource = ReplicatedStorage.PlaceableModels,
    -- grid = require(ReplicatedStorage.Shared.Map),  -- optional: inject your own
    gridConfig = { voxelSize = 3 },                    -- used by the default grid
})
```

## Changes from CastleWars original

- **Removed dormancy guards.** Both `init` files began with `if true then return {} end`;
  removed so the system runs.
- **Init is now a function.** Client `init.luau` and server `init.luau` moved their
  require-time wiring into `init(config)`; the client sets the injection `Context`
  before requiring its runtime sub-modules.
- **Grid decoupled.** `PreviewManager` and `PlacementValidator` no longer
  `require(ReplicatedStorage.Shared.Map)`; they read `Context.grid` and call
  `grid.positionToCoord`. Only `positionToCoord` (+ `voxelSize` for completeness) is
  consumed. A `DefaultGrid` uniform-grid implementation ships as the fallback.
- **ItemDefinitions moved to `shared/`.** Previously the schema lived in the client
  tree and the **server** required it across trees
  (`ReplicatedStorage.Client.Systems.Placement.ItemDefinitions`). Both sides now
  require `shared/ItemDefinitions` relatively. The module also dropped its
  `require(Items)` dependency: `cloneItem` takes an optional `PrimaryPart` argument
  instead (behaviour identical for the example catalog, which never passed one).
- **Models source injected.** Both `Items.luau` (client) and the server no longer
  hardcode `ReplicatedStorage.ItemDefinitions`; the folder comes from
  `config.modelsSource`. `Items` now derives from **all** `Model`s in that folder
  rather than a single hardcoded `Barricade` entry.
- **Scheduler decoupled.** Replaced `ReplicatedStorage.Client.ClientScheduler` with
  an injectable scheduler defaulting to self-contained `RunService` loops
  (`PreRender` for input, `Heartbeat` for preview).
- **Relative requires.** All absolute game-tree self-requires converted to
  `script.Parent`/`script.Parent.Parent` navigation. The server's `PlacementData`
  require now points at its sibling instead of `ServerScriptService.Server.Systems...`.
- **Debug print removed.** `PreviewManager`'s `print("SHOW PREVIEW CALLED")` stripped.
- **Dead code omitted.** `DragHandler.lua` and `Utils/BoundUtils.lua` were not
  copied.

## Known issues / stubs (flagged, not fixed)

These are latent in the original and preserved as-is:

- **`Placement3D.calculateOffsetFromCollider` is a stub** that always returns `0`.
  The preview's surface offset therefore comes entirely from the caller-supplied
  `offset`/`itemBase`. Left functionally unchanged.
- **`table.remove(itemDef)` misuse in delete paths.** In `PreviewManager`'s
  `OnClientEvent` delete branch (`table.remove(itemDefinition)`) and the server's
  `DeleteItem` (`table.remove(itemDef)`), `table.remove` is called on the element
  value rather than the containing list with an index — this does not remove the
  entry as intended.
- **`#PlacementData.voxelPlacementData[voxelCoord]` on a keyed table.** In both the
  client delete branch and server `DeleteItem`, the occupancy entry is a keyed table
  (`{ Occupied, itemDefs }`), so `#` is `0` and the `Occupied = false` reset fires
  unconditionally / incorrectly. (The intended check is likely
  `#...itemDefs == 0`.)
- **`RaycastUtils` is unused by the live modules** — only the omitted `DragHandler`
  referenced it. It is kept under `client/Utils/` per spec but is not wired in.
- **`modelsSource` must be populated before `init`.** If it is nil/empty, the client
  preview inventory is empty and the first `:Clone()` will error; the server
  `init` asserts a non-nil folder.
