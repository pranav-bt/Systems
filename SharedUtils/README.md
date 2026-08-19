# SharedUtils

A collection of small, self-contained Roblox utility modules extracted from the
CastleWars game. Each module lives in `src/` and can be required independently.

With one exception (Scheduler, which needs the Promise Wally package), no module
requires anything outside this package — they depend only on Luau/Roblox globals.

## Files

| File | What it does |
|---|---|
| `src/ObjectPool.luau` | Generic clone/free pool keyed by string tag; also builds composite tags from sorted string-key sets. |
| `src/InstanceObjectPool.luau` | Instance pool with per-tag caps, ParticleEmitter emit-count capture, and a `PooledObjects` staging folder. |
| `src/Spring.luau` | Quenty's lazy Hooke's-law spring (numbers/Vectors); position/velocity computed on index. |
| `src/BezierTween.luau` | Creates a cubic-Bezier tween whose `evaluate()` returns a CFrame oriented along the curve tangent over a duration. |
| `src/Color.luau` | Pure Color3 `darken`/`lighten` helpers. |
| `src/noYield.luau` | Runs a callback once inside a generic-for so a yield throws instead of silently suspending. |
| `src/Collision.luau` | Pure AABB / OBB / sphere intersection math (point-in-box, AABB-vs-box, AABB-vs-sphere). |
| `src/Scheduler.luau` | Event-driven scheduler: register named callbacks/intervals against RBXScriptSignals, or await a tick as a Promise. |
| `src/Cleanup.luau` | Maid/Trove-style cleanup profile tracking instances, connections, and cleanup calls. |

## Dependencies

Only **Scheduler** has an external dependency: `evaera/promise@4.0.0`, declared in
`wally.toml`. After `wally install`, it is expected at
`SharedUtils/Packages/Promise`, which is what Scheduler requires via
`require(script.Parent.Parent.Packages.Promise)`.

All other modules have zero external requires.

## Configuration / Injection API

### InstanceObjectPool

Debug reporting is off by default and needs no game infrastructure:

- `InstanceObjectPool.DEBUG` (boolean, default `false`) — gates the
  "already initialized" warning.
- `InstanceObjectPool.DebugReporter` (`(message: string) -> ()`, optional) — if
  set, debug messages are routed here; otherwise they go to `warn`.
- `InstanceObjectPool.ReportFreeObjectCounts()` — manual call that reports each
  pool's free-object count (replaces the old debug remote). No-op unless invoked.

`InitializeObjectPool(object, params?)` accepts `params.overrideParent` and
`params.overrideMaxObjectCountCap` (default cap 20).

### Scheduler

`Scheduler.new(events)` where `events` is a list of
`{ schedules: { string }, event: RBXScriptSignal }`. It returns `schedule`,
`interval`, and `promise` functions. Requires the Promise package (see above).

## Usage examples

### Scheduler

```lua
local RunService = game:GetService("RunService")
local Scheduler = require(path.to.Scheduler)

local scheduler = Scheduler.new({
	{ schedules = { "render" }, event = RunService.RenderStepped },
	{ schedules = { "physics" }, event = RunService.Heartbeat },
})

local disconnect = scheduler.schedule("render", "MoveCamera", function(dt)
	-- runs every RenderStepped
end)

scheduler.interval("physics", "Tick", 0.5, function()
	-- runs at most every 0.5s on Heartbeat
end)

scheduler.promise("render"):andThen(function()
	-- resolves on the next render tick
end)

disconnect() -- remove the scheduled callback
```

### BezierTween

```lua
local BezierTween = require(path.to.BezierTween)

local tween = BezierTween.CreateTween(startPos, startHandle, endPos, endHandle, 1.5)
-- each frame:
local cframe = tween.evaluate() -- CFrame along the curve, clamped at t = 1
```

### InstanceObjectPool

```lua
local Pool = require(path.to.InstanceObjectPool)

local tag = Pool.GetObjectTag(vfxTemplate) -- auto-initializes with default cap
local data = Pool.Get(tag)                 -- nil if the cap is reached
if data then
	data.instance:PivotTo(someCFrame)
	-- ... use it, then:
	Pool.Release(data)
end
```

### Cleanup

```lua
local Cleanup = require(path.to.Cleanup)

local profile = Cleanup.CreateProfile()
profile:AddInstance("part", workspace.Part)
profile:AddCleanupConnection("touch", part.Touched:Connect(onTouch))
profile:AddCleanupCall("log", function() print("cleaned") end)

profile:Destroy() -- disconnects, destroys, and runs all registered cleanups
```

## Changes from CastleWars original

All extracted modules preserve their original logic. Only the decoupling points
below changed:

- **Renames:** `ObjectPool.lua`, `Spring.lua`, `Cleanup.lua`, `BezierTween.lua`,
  and `InstanceObjectPool.lua` are now `.luau` files. `Color.luau`,
  `noYield.luau`, and `Collision.luau` were already `.luau` and copied verbatim.
- **ObjectPool, Spring, Color, noYield, Collision:** copied as-is (no logic
  changes).
- **Scheduler:** the Promise require was changed from
  `require(ReplicatedStorage.Packages.Promise)` to
  `require(script.Parent.Parent.Packages.Promise)` (package-relative). The unused
  `ReplicatedStorage` service grab was dropped. Logic unchanged.
- **BezierTween:** the `require(SharedLibraries.Utilities)` dependency was
  removed. `Utilities:Bezier3d(...)` is inlined verbatim as a local `bezier3d`
  function (cubic Bezier position + tangent, returned via
  `CFrame.lookAlong`). Behavior is identical.
- **Cleanup:** the `ReplicatedStorage.SharedLibraries.Debugger` require was
  removed. The `if Debugger.Enabled then Debugger.Warn(Category.SYSTEM, msg) end`
  guards in `AddCleanupCall` / `AddCleanupConnection` were replaced with plain
  `warn(msg)`. Because the `Debugger.Enabled` gate no longer exists, these
  warnings now always fire on a duplicate name (previously only when the game
  Debugger was enabled). The `AddCleanupConnection` early `return` on duplicate
  is preserved. `AddInstance` already used raw `warn` and is unchanged.
- **InstanceObjectPool:** the `Debugger` require, the `RunService` and
  `ReplicatedStorage` service grabs, and the client-side
  `ReplicatedStorage.Remotes.DebugVfxObjectPool_RS` handler were all removed.
  Debug reporting is now an opt-in no-op: a `DEBUG` flag (default `false`) gates
  the "already initialized" warning, and an injectable `DebugReporter` callback
  (falling back to `warn`) routes messages. The old remote-driven free-count
  dump is now the manually-callable `ReportFreeObjectCounts()`. The pooling
  logic, caps, emission capture, and the `"VFX"` name-based `isVfx` tagging are
  all intact.
```
