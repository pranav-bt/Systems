# Zone

A lightweight, server-side **subject-in-volume detector** for Roblox. `Zone.new(...)`
creates an anchored, non-colliding `Block`, `Cylinder` or `Ball` part and polls the positions
of whichever populations the zone watches — players by default, but equally bots, vehicles or
anything else you name — firing enter/exit events and an optional throttled interval
callback.

## Overview

- Supports **rotated** box, cylinder and sphere volumes (checks run in the part's object
  space, so any `CFrame` orientation works).
- **Watches named populations, not just players.** A "subject type" is a set of refs plus one
  function saying where a ref is, so a bot with no character or a plain Lua table with no
  Instance at all is detected the same way a player is. Each zone chooses which types it
  watches.
- **Populations are maintained, never polled.** No `GetTagged` or `GetPlayers` call per
  sweep — discovery costs O(1) per spawn.
- **One shared `Heartbeat` connection for every zone in the game**, not one per zone. Each
  zone keeps its own interval; the shared ticker gathers every player's position *once* per
  frame in which any zone is due and hands that single snapshot to whichever zones are due.
- **Two-phase membership test**: a cached bounding sphere rejects distant players with one
  dot product before any object-space transform happens.
- Fires `subjectEntered` / `subjectExited` / `onDestroyed`, with `playerEntered` /
  `playerExited` retained as the same signals. These are **pure-Lua signals, not
  `BindableEvent`s** — see Why the events are not BindableEvents.
- Auto-cleans up when the underlying part is destroyed, and removes players on
  `Players.PlayerRemoving`.
- Server-only (the built-in `player` type relies on `Players` and character
  `HumanoidRootPart`s).

## Files

| File | Purpose |
|---|---|
| `src/init.luau` | The entire Zone module (self-contained). |

Tests live in [`Tests/tests/`](../Tests): `test-zone.luau` (geometry, ticker, lifecycle),
`test-zone-types.luau` (the subject-type registry) and `test-zone-signals.luau` (event
identity and isolation) — 207 checks, run headless with no Studio. They load `src/init.luau`
itself rather than a copy, so they cannot drift from it.

## Dependencies

**None.** No Wally packages, no external requires. Uses only the `Players`, `RunService` and
`CollectionService` Roblox services.

It deliberately knows nothing about its sibling libraries either — there is no `Bots`
resolver, because that would mean Zone knowing the shape of a `Bots` body. Write the
one-liner in your game instead (see below); composition by shape, not by require.

## Configuration / Injection API

### Constructor

```lua
Zone.new(
    CFrame: CFrame,
    Size: Vector3,
    Shape: Enum.PartType,        -- Block, Cylinder or Ball (anything else errors)
    PartInstance: Part?,         -- optional existing Part to adopt; a new Part is created if nil
    params: {
        Transparency: number?,                 -- default 1 (invisible)
        ZoneUpdateInterval: number?,           -- seconds between player sweeps; default 1, must be > 0
        Name: string?,                         -- part name; default "Zone"
        EnableDebugPrints: boolean?,           -- default false
        IntervalCallbackDurationOverride: number?, -- seconds between intervalCallback fires; default = ZoneUpdateInterval
        types: { string }?,                    -- populations to watch; default { "player" }, or Zone.AllTypes
        excludeTypes: { string }?,             -- names removed from whatever `types` resolves to
        tagsToTrack: { string }?,              -- each tag becomes a population of the same name
        collisionGroup: string?,               -- optional collision group; if nil, CollisionGroup is left untouched
    }?
)
```

The created/adopted part is configured as `Anchored = true`, `CanCollide = false`,
`CanQuery = false`, `CanTouch = false`, and parented to `workspace`. **Note that adopting a
`PartInstance` overwrites those properties plus `Shape`, `Name`, `Transparency` and
`Parent`** — don't hand it a part that is also scenery.

An adopted part **must be a `Part`**. `MeshPart`, `UnionOperation` and `TrussPart` are
`BasePart`s with no `Shape` property, and the zone needs to set one; passing one raises at the
call site naming the class, rather than dying inside the library on a property write. If you
need a mesh-shaped trigger, create the zone with `nil` and position it over the mesh.

Constructor arguments are validated: an unsupported `Shape`, a `Size` with a non-positive
axis, or a non-positive interval all raise immediately.

### Shapes

| `Shape` | Volume tested |
|---|---|
| `Block` | Box with half-extents `Size/2`. |
| `Cylinder` | Height along **X** (`Size.X`), with an **elliptical** cross-section using `Size.Y` and `Size.Z` as diameters. |
| `Ball` | **Ellipsoid** with semi-axes `Size/2` — a sphere when the size is uniform. |

Cylinder and Ball use the ellipse/ellipsoid form rather than a single radius, so a
non-uniform size behaves sensibly instead of silently ignoring an axis.

### Config fields

- **`Transparency`** — visual transparency of the zone part. Defaults to `1` (fully invisible).
- **`ZoneUpdateInterval`** — how often (seconds) the zone sweeps all players. Defaults to `1`.
- **`Name`** — the part's `Name`. Defaults to `"Zone"`.
- **`EnableDebugPrints`** — when `true`, prints/warns on enter, exit, still-in-zone, destroy, and interval events. Defaults to `false`.
- **`IntervalCallbackDurationOverride`** — minimum seconds between successive `intervalCallback` invocations for a player. Defaults to `ZoneUpdateInterval`.
- **`collisionGroup`** *(injection point — added during extraction)* — if provided, the part's `CollisionGroup` is set to this string. If omitted/`nil`, the part's `CollisionGroup` is **left untouched** (stays `"Default"`). The collision group is **not** created for you; register it via `PhysicsService` beforehand if you pass one.
- **`types`** — which populations this zone watches. Defaults to `{ "player" }`. Pass `Zone.AllTypes` for every type registered at sweep time. Resolved *per sweep*, so a type registered after the zone still counts and require order stops mattering.
- **`excludeTypes`** — names removed from whatever `types` resolves to. Applies to an explicit list as well as to `Zone.AllTypes`, so `{ types = Zone.AllTypes, excludeTypes = { "player" } }` means "everything but players".
- **`tagsToTrack`** — each tag becomes a population of the same name (wired via `Zone.trackTagged`) and is appended to what this zone watches. This was accepted and silently ignored in every previous version.

### Events

Each is a pure-Lua signal with the `RBXScriptSignal` surface — `Connect`, `Once`, `Wait`, and
a connection with `Disconnect`. Handlers fire in connection order and each runs on its own
thread, so one that throws or yields cannot affect its siblings or the sweep:

- **`zone.subjectEntered`** — fires `(ref, typeName: string)` when a subject first enters the volume.
- **`zone.subjectExited`** — fires `(ref, typeName: string)` when a subject leaves the volume, stops being tracked, becomes unresolvable (a player who lost their character, a destroyed part), stops being of a watched type, or is still inside when the zone is destroyed.
- **`zone.onDestroyed`** — fires `(zone)` on teardown, whether that came from `zone:Destroy()` or from the underlying part being destroyed.

**`zone.playerEntered` and `zone.playerExited` are the *same two signals*** under their older
names — one signal pair, not two. A handler written the way every existing consumer wrote it
keeps working, because the type name simply arrives as a second argument it ignores:

```lua
zone.playerEntered:Connect(function(player) end)          -- still correct
zone.subjectEntered:Connect(function(ref, typeName) end)  -- the canonical form
```

One consequence to know about: because they are one signal, a zone that opts into
`types = { "player", "bot" }` will deliver bots to a handler connected as `playerEntered`.
Nothing that keeps the default can be affected, and the second argument is how you filter if
you do opt in.

### Interval callback

Assign a function to `zone.intervalCallback` after construction:

```lua
zone.intervalCallback = function(ref, typeName)
    -- called for subjects inside the zone, at most once per IntervalCallbackDurationOverride seconds
end
```

It is invoked during a sweep for subjects who are inside the zone, gated by
`intervalTimeElapsed >= intervalCallbackDurationOverride`. It is `nil` by default. As with the
events, a callback written as `function(player)` keeps working. It runs under `pcall` (see
Error isolation).

### Methods

- **`zone:Contains(position: Vector3): boolean`** — is this world position inside the volume? Broad-phase rejected first. Useful on its own, with no players involved ("would this spawn point be inside the safe zone?").
- **`zone:IsSubjectInZone(ref): boolean`** — membership, for any type.
- **`zone:IsPlayerInZone(player): boolean`** — membership *and* of type `player`.
- **`zone:GetSubjectsInZone(typeName?): { any }`** — array of subjects currently inside, optionally of one type (allocates).
- **`zone:GetPlayersInZone(): { Player }`** — the `player`-typed subjects (allocates).
- **`zone:CountInZone(typeName?): number`** — total inside, or the count of one type.
- **`zone:SetTypes(types?, excludeTypes?)`** — change what this zone watches at runtime, same arguments as the config fields. Subjects of a type that is no longer watched are exited on the next sweep rather than left stuck inside.
- **`zone:GetTypes(): { string }`** — the resolved, sorted type names this zone watches right now. Diagnostic: it answers "did my type name actually take effect?" without reading private fields.
- **`zone:UpdateZone(CFrame, Size)`** — move/resize the volume. **The only correct way to do it** — see below.
- **`zone:UpdateZoneInterval(newInterval)`** — change the sweep interval at runtime (must be `> 0`).
- **`zone:Destroy()`** — unregisters from the shared ticker, fires `subjectExited` for remaining subjects, fires `onDestroyed`, disconnects everything, clears membership state, and destroys the part. **Idempotent.**

Also readable: `zone.subjectCountInZone` (total inside), `zone.playerCountInZone`,
`zone.zoneInstance` (the part).

**`playerCountInZone` and `GetPlayersInZone` are deliberately players-only.** A bot-only zone
reports `0` and `{}` from them — which can look like a bug, and is the alternative to silently
redefining what an existing caller's number means. Use `CountInZone()` /
`GetSubjectsInZone()` when you want everyone.

`zone.playersInZone` is still there and is *the same table* as `zone.subjectsInZone`; its
values are type names now rather than `true`, so a truthiness check still reads correctly.
Prefer `IsSubjectInZone` / `GetSubjectsInZone` over reaching into either.

## Subject types

A **subject type** is a named population: a set of refs, plus one function saying where a ref
is. A "ref" can be anything — a `Player`, a `Model`, a `BasePart`, or a plain Lua table with
no Instance behind it at all. Zone never introspects a subject; it only asks its type where
that subject is.

```lua
-- 1. declare the population
Zone.registerType("bot", function(bot)
    return bot.body.rootPart.Position   -- your game knows this; Zone does not
end)

-- 2. maintain the set at the moments your game already knows about
Zone.track("bot", bot)      -- when it spawns
Zone.untrack("bot", bot)    -- when it dies

-- 3. point a zone at it
local trap = Zone.new(cf, size, Enum.PartType.Block, nil, { types = { "bot" } })
trap.subjectEntered:Connect(function(bot, typeName) end)
```

### Sets are maintained, not polled

`Zone.track` / `Zone.untrack` are the primitive, and they are what makes this cheap: discovery
costs O(1) at a spawn instead of O(population) on every sweep. Two helpers wire a set to
something that already emits lifecycle events, so you never have to call `track` by hand:

```lua
Zone.trackTagged("vehicle", "Vehicle")             -- CollectionService tag
Zone.trackChildren("crate", workspace.Crates)      -- a folder
```

Both seed the set once and then follow the added/removed signals, and both are idempotent per
source — several zones naming the same tag in `tagsToTrack` wire it once, not once each. This matters: polling
`CollectionService:GetTagged(tag)` would allocate a fresh array of the *entire* tagged
population on every sweep, which is exactly the cost these avoid. The built-in `player` type
works the same way, driven by `PlayerAdded` / `PlayerRemoving` — so the per-frame
`Players:GetPlayers()` allocation that earlier versions paid is gone too.

### Position resolvers

| Resolver | Reads |
|---|---|
| built-in `player` | the player's `HumanoidRootPart.Position`, via a cache refreshed per respawn |
| `Zone.positionFromPart` | `part.Position` |
| `Zone.positionFromModel` | `model:GetPivot().Position` — works with or without a `PrimaryPart` |
| `Zone.positionFromInstance` | auto-detects part vs model; the default for `trackTagged` / `trackChildren` |

A resolver returns a `Vector3`, or **`nil` to mean "gone"**. That single `nil` covers a dead
character, a despawned bot, a destroyed part and a streamed-out vehicle identically — a subject
absent from a frame's snapshot is exited from every zone it was in. The three instance
resolvers above treat a parentless instance as gone, so a destroyed subject leaves its zones
even if nobody remembered to call `untrack`.

Positions must be real `Vector3`s, because the narrow phase transforms them with
`CFrame:PointToObjectSpace`. If your game thinks in grid cells or voxels, convert in the
resolver — the volume is a Roblox part, so a world position is the common currency.

`Zone.registerType` on an existing name **replaces the resolver and keeps the set**, which is
how you override the built-in `player` resolver (a game with custom characters, say) without
losing everyone already tracked.

### Choosing what a zone watches

`types` defaults to `{ "player" }` rather than "everything registered" on purpose: if the
default were "all", then calling `Zone.registerType("bot", ...)` anywhere in your game would
silently change the behaviour of every zone already constructed. Ask for what you want.

```lua
{ types = { "bot" } }                                        -- bots only; Players is never touched
{ types = { "player", "bot" } }                              -- both
{ types = Zone.AllTypes }                                    -- everything registered at sweep time
{ types = Zone.AllTypes, excludeTypes = { "player" } }       -- everything but players
```

Excluding a type does not merely filter it out afterwards — a frame gathers only the types that
some **due** zone actually asked for, so a game whose zones all exclude players never resolves
a single `HumanoidRootPart`.

Type names are resolved *per sweep*, so registering a type after a zone was constructed still
takes effect and require order stops mattering. A name that is never registered warns once per
zone rather than silently detecting nothing forever.

### Registry helpers

- **`Zone.registerType(name, positionOf)`** — declare or replace a population's resolver.
- **`Zone.track(typeName, ref)`** — add to the set. Errors on an unregistered type, so a typo surfaces at the call site.
- **`Zone.untrack(typeName, ref)`** — remove from the set. Forgiving: untracking something never tracked, or of a type that does not exist, is a no-op, because that is what a teardown path does when it cannot be sure.
- **`Zone.isTracked(typeName, ref)`**, **`Zone.trackedCount(typeName)`**, **`Zone.hasType(name)`** — diagnostics.
- **`Zone.AllTypes`** — the sentinel for `types`.

## Moving a zone: use `UpdateZone`

Each zone caches its centre, a squared bounding-sphere radius, half-extents and its shape
predicate. That cache is what makes the broad phase cheap, and it is refreshed in exactly
two places: construction and `UpdateZone`.

```lua
zone:UpdateZone(CFrame.new(120, 5, 0), Vector3.new(30, 10, 30))   -- correct
zone.zoneInstance.CFrame = CFrame.new(120, 5, 0)                  -- WRONG: cache goes stale
```

Setting `zoneInstance.CFrame` or `.Size` directly leaves the cache describing the *old*
volume, so membership would be computed against where the zone used to be. `Contains` — the
single gate on the cache, used by the sweep and by external callers alike — compares the
instance against the cache and self-heals with a warning if they disagree. That is a safety
net for catching the mistake, not a licence to make it. Go through `UpdateZone`.

Membership updates on the next sweep, so a moved zone's enter/exit events lag by up to one
`ZoneUpdateInterval`. `Contains` is immediate.

## Usage example

```lua
local Zone = require(path.to.Zone)

local captureZone = Zone.new(
    CFrame.new(0, 5, 0),
    Vector3.new(20, 10, 20),
    Enum.PartType.Block,
    nil,
    {
        Name = "CapturePoint",
        ZoneUpdateInterval = 0.5,
        IntervalCallbackDurationOverride = 1, -- tick capture progress ~once per second
        Transparency = 0.7,
        -- collisionGroup = "Zones", -- optional; only if you registered this group
    }
)

captureZone.playerEntered:Connect(function(player)
    print(player.Name, "entered the capture point")
end)

captureZone.playerExited:Connect(function(player)
    print(player.Name, "left the capture point")
end)

captureZone.intervalCallback = function(player)
    -- award capture progress to player's team, etc.
end

-- later:
-- captureZone:Destroy()
```

A zone that watches something other than players — same shapes, same events, one extra config
field and one function saying where a subject is:

```lua
Zone.registerType("bot", function(bot)
    return bot.body.rootPart.Position
end)

-- wherever your game already spawns and despawns:
Zone.track("bot", bot)
Zone.untrack("bot", bot)

local minefield = Zone.new(
    CFrame.new(40, 3, 0),
    Vector3.new(30, 6, 30),
    Enum.PartType.Cylinder,
    nil,
    { Name = "Minefield", types = { "player", "bot" } }
)

minefield.subjectEntered:Connect(function(ref, typeName)
    if typeName == "bot" then
        alertSquad(ref)
    else
        damage(ref)
    end
end)

print(minefield:CountInZone())        -- everyone
print(minefield:CountInZone("bot"))   -- just the bots
print(minefield.playerCountInZone)    -- just the players
```

## Error isolation

One shared ticker means one zone's fault must not become everyone's, so there are three
guards:

- **Each sweep runs under `xpcall`.** A zone that throws for any reason — a consumer
  handler, a library fault — is warned about and skipped; every other zone due that frame
  still sweeps. With per-zone connections this came for free; with a shared one it has to be
  explicit.
- **`intervalCallback` runs under its own `pcall`.** It is the only consumer code called
  directly rather than through a signal (whose handlers each get their own thread). Without
  this, a throwing callback would abort the rest of *that* zone's sweep, so subjects later in
  the snapshot would miss their enter/exit for that tick.
- **Each population's gather runs under `xpcall`.** A position resolver that throws costs its
  own population for that frame — warned once, since a broken resolver throws every frame —
  rather than taking down the tick. Guarding per *type* rather than per *ref* means the cost of
  the guard does not scale with how much you track.

## Why the events are not BindableEvents

A `BindableEvent` **serialises its arguments**. A table crosses it as a deep copy with its
metatable stripped — measured in Studio, not assumed:

| | through a `BindableEvent` |
|---|---|
| table identity | not preserved |
| metatable | stripped; methods gone |
| function fields | silently dropped, no error |
| Instance identity | preserved |

That last row is why this went unnoticed for years: while the only payload was a `Player`, the
transport fitted the data. Subject types broke that, because a subject may be any ref at all.
Handed a copy, a handler sees:

```lua
zone.subjectEntered:Connect(function(ref)
    ref:damage(25)              -- errors: metatable stripped, method gone
    if ref == myBot then end     -- always false
    zone:IsSubjectInZone(ref)    -- false; the copy is not the tracked ref
    ref.health = 1               -- silently mutates the copy; the real bot is untouched
end)
```

The last line is the worst, because nothing raises: a damage handler runs to completion and the
bot walks away at full health.

**No payload can fix this.** A metatable is a table of functions, and functions do not survive
the boundary either — there is nothing to pass. The fix is to stop crossing a boundary that was
never needed: `BindableEvent` exists to carry values across script contexts and actors, and
Zone's firer and handler are in the same VM on the same thread. A pure-Lua signal is a list of
functions called in place, so identity holds for free.

Two properties were deliberately preserved rather than reinvented:

- **Handlers run in connection order**, because that is what `BindableEvent` did. Prepending
  would have been a line shorter and would have silently reversed the order for anyone with two
  handlers on one signal.
- **Each handler runs on its own thread** (`task.spawn`), so one that throws neither aborts its
  siblings nor propagates into the sweep, and one that yields does not suspend the sweep that
  fired it. A direct call loses both; `pcall` would recover only the first, since Luau permits
  yielding across it.

What it costs: `zone.playerEntered` is no longer a real `RBXScriptSignal`, so a
`typeof(...) == "RBXScriptSignal"` check would no longer match, and the events no longer show
up in the Instance tree for debugging. What it saves: three Instances per zone, and the
marshalling on every fire.

## Performance notes

The old shape was one `Heartbeat` connection *per zone*, each independently sweeping every
player and re-resolving each player's `HumanoidRootPart` by name. Twenty zones and thirty
players at the default interval meant ~1,200 connection callbacks and ~600
`FindFirstChild` calls per second.

Now:

- **One connection total**, created with the first zone and released with the last.
- **One position snapshot per population per frame** in which any zone is due, shared by all
  of them, into reused arrays (no per-frame allocation — not even the `xpcall` guard, which
  calls a named function rather than a closure).
- **Only the populations some *due* zone asked for are gathered.** Excluding a type stops the
  work rather than filtering it afterwards.
- **No discovery in the hot path.** Sets are maintained by signal, so there is no
  `Players:GetPlayers()` and no `CollectionService:GetTagged()` per sweep — both of which
  allocate a fresh array of the whole population every time they are called.
- **`HumanoidRootPart` resolved once per respawn**, cached and validated by `Parent`, rather
  than per zone per player per sweep.
- **A bounding-sphere rejection** (one dot product) before each object-space transform.
- Squared-distance comparisons throughout: no `math.sqrt` in the hot path.
- The liveness re-check calls a resolver once per *member*, not once per tracked subject — a
  zone's membership is small by construction.

## Changes from CastleWars original

Original source: `src/server/Systems/Zone.lua` in the CastleWars game.

**Extraction (no behaviour change):**

1. **Collision group is now configurable.** The original hardcoded
   `zoneInstance.CollisionGroup = "SuggestionBlock"`, which assumed a game-specific
   collision group. This is replaced with an optional `collisionGroup` param: if provided,
   the part's `CollisionGroup` is set to it; if omitted/`nil`, `CollisionGroup` is **not
   touched** (remains `"Default"`).
2. **Removed dead code.** The commented-out/unused `GetWorldAlignedBounds(part)` helper and
   its commented reference were deleted. They were genuinely unused.
3. **`collisionGroup`, `types`, `excludeTypes` and the type registry are additive.** Every
   pre-existing call site keeps its old behaviour: `types` defaults to `{ "player" }`.

**Bug fixes (behaviour changed, deliberately):**

4. **`onDestroyed` now fires on `zone:Destroy()`.** Previously it fired *only* when the part
   was destroyed directly, because `Destroy()` disconnected the `Destroying` listener before
   destroying the part — so the primary teardown path never fired the event at all.
5. **`Destroy()` clears membership state and is idempotent.** It fired exit for everyone but
   left `playersInZone` populated and `playerCountInZone` non-zero, so an `onDestroyed`
   handler saw stale members and a second `Destroy()` re-fired every exit.
6. **The `onDestroyed` event's handlers are released on teardown.** The `BindableEvent` this
   replaced was leaked — one Instance per zone, forever.
7. **Cylinders respect `Size.Z`.** The test used `Size.Y / 2` as a single radius and ignored
   `Size.Z`, so a zone sized `(10, 8, 4)` accepted points well outside the part along Z.
8. **Unsupported shapes error instead of failing silently.** A `Wedge` zone used to be
   created, parented and polled, and never detect anybody.
9. **Errors are isolated per zone and per population.** With one shared ticker, an unguarded
   throw in any zone would skip every zone still queued behind it that frame; a throwing
   `intervalCallback` would abort the rest of its own zone's sweep; and a throwing position
   resolver would take down the whole tick. All three are now guarded.
10. **The sweep interval no longer drifts.** The timer was zeroed after firing, discarding the
   overshoot, so every cycle ran one frame long. Both the sweep timer and the interval-callback
   timer now subtract their period, which also keeps them in phase with each other.
11. **The player population is maintained rather than enumerated.** `Players:GetChildren()`
    would raise *"Character is not a valid member of Folder"* every frame if anything
    non-Player were ever parented under `Players`; `Players:GetPlayers()` replaced it and then
    itself gave way to a set kept current by `PlayerAdded` / `PlayerRemoving`, which also
    retires an array allocation per sweep.
12. **Validation added** for `Shape`, `Size` (positive on every axis — a zero extent divided
    by zero in the ellipse tests), and both interval values.

**Additions:**

13. **`Ball` shape support**, and the ellipsoid/ellipse forms described above.
14. **`zone:Contains(position)`** and **`zone:IsPlayerInZone(player)`**. `Contains` is also the
    single gate that validates the geometry cache.
15. **Shared ticker, cached bounds, root cache** — see Performance notes. `self.MainConnection`
    no longer exists (there is no per-zone connection); nothing documented referenced it.
16. **`DoBoxCheck` / `DoCylinderCheck`** are retained as thin delegates for compatibility;
    both now route through one shape-agnostic membership update, and both accept an optional
    type name (defaulting to `"player"`).
17. **Subject types.** The original could only ever detect players, because the HRP lookup was
    written into the sweep. A zone now watches named populations, each supplying its own
    position resolver, so a bot with no character or a plain table with no Instance is detected
    the same way a player is. `subjectEntered` / `subjectExited` are the canonical signals, with
    `playerEntered` / `playerExited` retained as *the same two signals* so no existing handler
    breaks; `playersInZone` is likewise the same table as `subjectsInZone`. Liveness stopped
    being "has a `HumanoidRootPart`" and became "absent from this frame's snapshot", which is
    both more general and shorter.
18. **`tagsToTrack` is implemented.** It was accepted and silently ignored in the original and
    in every version since. Each tag now becomes a population of the same name, wired to that
    tag's added/removed signals, and appended to what the zone watches.
19. **`Zone.registerType` / `track` / `untrack` / `trackTagged` / `trackChildren`**, the
    `positionFrom*` resolvers, `Zone.AllTypes`, and the `types` / `excludeTypes` config —
    see Subject types.
20. **`GetSubjectsInZone`, `IsSubjectInZone`, `CountInZone`, `SetTypes`, `GetTypes`** and
    `zone.subjectCountInZone`.
21. **Events are pure-Lua signals, not `BindableEvent`s** — a correctness fix, not a saving.
    A `BindableEvent` deep-copies a table argument and strips its metatable, so every
    non-Instance subject reached its handler as a broken duplicate. `Connect` / `Once` / `Wait`
    / `Disconnect` and connection-order dispatch are unchanged; three Instances per zone are
    gone. See Why the events are not BindableEvents.
22. **Adopting a non-`Part` `BasePart` is refused at the call site.** A `MeshPart` used to die
    inside the library on the `.Shape` assignment with *"Shape is not a valid member of
    MeshPart"*, an error about a property the caller never mentioned.

There were no `--!strict`/`--!native` pragmas in the original, so none were added, and the
file is deliberately not `stylua`-formatted (per this repo's extraction conventions).
