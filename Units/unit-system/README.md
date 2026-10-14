# Unit System

A small, drop-in abstraction that lets every gameplay system treat **real players and
server-driven bots identically**. You write your combat / KO / carry / scoring / stats
code against a single `Unit` type, and bots flow through all of it for free — they
don't error, and they don't get silently skipped.

> Formerly called the "Actor" system. `Actor` → `Unit` throughout (the term "actor" is
> overloaded in Roblox with `Actor` instances / parallel Luau, so this version uses
> **Unit**).

---

## The one idea

A gameplay participant is a **Unit**: either a real `Player`, or a `BotPlayer` — a
server-only object that duck-types the handful of `Player` members gameplay actually
reads (`.Name`, `.UserId`, `.Character`, `.CharacterAdded`). Because a `BotPlayer` has
the same shape, code written against `Unit` accepts both with no narrowing.

Identity is unified as a single number:

| Unit kind | `UserId` | On the wire |
|-----------|----------|-------------|
| Real player | its Roblox `UserId` (always **positive**) | that number |
| Bot | a synthetic **negative** id (from `-1000` down) | that number |

Real UserIds are never negative, so **the sign is a collision-proof discriminator**.
`UnitId.IsBot(id)` / `IsPlayer(id)` is the only place that check lives. There is no
`id < 0` literal anywhere else, and no `Player` instance ever travels on the wire —
only the number does.

This buys you three rules that make bot-support automatic. Follow them and bots just
work; break them and bots are the thing that silently breaks.

1. **Type gameplay participants as `Unit`, not `Player`.** Key state tables by `Unit`.
2. **Never enumerate `Players:GetPlayers()` for gameplay** — use `UnitService.GetAll()`
   so bots are in the roster. (Iterating `Players` is only correct when you literally
   mean network sockets, e.g. fanning a remote out to clients.)
3. **Never resolve a character with `Players:GetPlayerFromCharacter(model)` for
   gameplay** — it returns `nil` for a bot rig. Use
   `UnitService.GetUnitFromCharacter(model)`. This is the #1 source of
   "bots-silently-don't-work" bugs (hit detection, touch triggers).

---

## What's in this folder

```
unit-system/
├── shared/
│   ├── UnitId.luau            # the bot/player sign discriminator (both realms)
│   └── UnitTypes.luau         # the `Unit` and `ClientUnit` types (pure types)
├── server/
│   ├── UnitService.luau       # server roster + id<->unit<->character resolver
│   ├── BotPlayer.luau         # the duck-typed Player stand-in for a bot
│   └── UnitTeleport.luau      # (optional) ownership-safe character teleport
└── client/
    └── ClientUnitRegistry.luau # client roster + resolver + unified unit/char signals
```

Everything here is reusable as-is. The pieces that make it *run* in a specific game —
an event bus, the bot spawner, the wire messages that replicate bots — are **not**
shipped (they're game-specific). They are documented below as small interfaces you
implement against your own stack. Where this repo already has an equivalent (a signal
library, a networking layer), wire the Unit modules to it; you should not need to adopt
any particular framework.

### The six modules at a glance

| Module | Realm | Role | Host dependencies |
|--------|-------|------|-------------------|
| `UnitId` | shared | `ALLOC_START`, `IsBot`, `IsPlayer` | none |
| `UnitTypes` | shared | `Unit`, `ClientUnit` type exports | none |
| `UnitService` | server | `GetAll`, `GetUnit`, `GetUnitFromCharacter`, `GetId`, `ToRealPlayer`, `Register`/`Unregister` | `UnitId`, `BotPlayer`, `UnitTypes` |
| `BotPlayer` | server | `new`, `SetCharacter`, `Destroy` | none |
| `UnitTeleport` | server | `TeleportCharacter` (+ optional `OnTeleported` hook) | `UnitService`, `UnitTypes` |
| `ClientUnitRegistry` | client | `Resolve`, `GetIdFromCharacter`, `GetAll`, `UnitAdded`/`UnitRemoving`/`CharacterAdded`, `OnBot*` | `TypedSubject`, `UnitId`, `UnitTypes` |

---

## Server API (`UnitService`)

```lua
UnitService.GetAll(): { Unit }                       -- every player + live bot
UnitService.GetUnit(id): Unit?                       -- wire id -> unit (nil if gone)
UnitService.GetUnitFromCharacter(model): Unit?       -- character -> unit (bot-aware)
UnitService.GetId(unit): number                      -- unit -> wire id (= unit.UserId)
UnitService.ToRealPlayer(unit): Player?              -- the real Player, or nil for a bot
UnitService.Register(bot) / Unregister(bot)          -- called by the bot driver only
```

`ToRealPlayer` is the escape hatch for the few Roblox APIs that genuinely need a
`Player`:

- **Per-client remotes** — `FireClient` / `fireExcept`. A bot maps to `nil`: there's no
  client to send to / exclude.
- **Network ownership** — `SetNetworkOwner`. A bot rig is server-owned, and
  `SetNetworkOwner(nil)` *means* server-owned, so a `nil` from `ToRealPlayer` is exactly
  right.

The pattern is always: *"the server owns this bot's physics, so apply the impulse /
velocity / teleport server-side instead of sending a remote the (nonexistent) client
would apply."*

```lua
-- Example: knockback that works for both kinds.
local client = UnitService.ToRealPlayer(unit)
if client then
    KnockbackRemote.fire(client, impulse)   -- player: its client applies it
else
    root:ApplyImpulse(impulse)              -- bot: server applies it directly
end
```

## Client API (`ClientUnitRegistry`)

```lua
ClientUnitRegistry.Resolve(id): ClientUnit?          -- { id, name, character, isBot } or nil
ClientUnitRegistry.GetIdFromCharacter(model): number?
ClientUnitRegistry.GetAll(): { number }              -- every known unit id

-- Subscribe to these instead of Players.PlayerAdded / player.CharacterAdded:
ClientUnitRegistry.UnitAdded        -- Subject<number>
ClientUnitRegistry.UnitRemoving     -- Subject<number>
ClientUnitRegistry.CharacterAdded   -- Subject<number, Model>
```

Two disciplines the registry's design depends on:

- **`Resolve` returns `nil` → skip, don't error.** Reliable remotes have no cross-order
  guarantee, so a state event can reference an id before its registration has arrived.
  State events are idempotent; the next one after registration renders fine.
- **Attach visuals off the `CharacterAdded` *signal*, not by polling `.character`.** A
  unit's id can be known while its rig hasn't streamed in yet (`.character == nil`
  briefly).

---

## Host-provided seams

The Unit system plugs into three things your game already has (or needs) in some form.
None are shipped; each is a small contract.

### 1. A `Unit`-aware lifecycle bus (server) — **required**

The whole model hinges on per-participant setup/teardown running for bots too. You need
a server event bus whose "participant added / removing" signals carry a **`Unit`**, and
that fires for **both** real players and bots:

```
PlayerAdded    : Subject<Unit>   -- fired for a real Player on join AND a bot on spawn
PlayerRemoving : Subject<Unit>   -- fired for a real Player on leave AND a bot on despawn
PlayerReady    : Subject<Player> -- a real player's client finished loading (players only)
```

Implement it however you like (any signal/subject library). The critical rules:

- **Never bind `Players.PlayerAdded` / `PlayerRemoving` directly for gameplay.**
  Have exactly **one** place fan the engine events onto this bus (and replay players
  already present at boot, so nothing is missed during synchronous startup). Everything
  else subscribes to the bus. The bot driver notifies the *same* signals itself.
- `PlayerAdded` must fire **before** a unit's first `CharacterAdded`. For per-spawn
  setup, subscribe to `PlayerAdded` and hook the unit's **own** `unit.CharacterAdded`
  (which fires for players via the engine and for bots via `BotPlayer:SetCharacter`) —
  not `player.CharacterAdded`:

  ```lua
  Signals.PlayerAdded:subscribe(function(unit: Unit)
      unit.CharacterAdded:Connect(function(character)
          SetupCharacter(unit, character)   -- runs for players AND bots
      end)
  end)
  ```

- Any signal naming a participant (`Damaged`, `KnockedOut`, …) should carry `Unit`, not
  `Player`, and subscribers should type the param `Unit` / `Unit?`.

> **The one-place fan-out, sketched.** A single server module, required *last* so every
> service is already subscribed:
> ```lua
> Players.PlayerAdded:Connect(function(p) Signals.PlayerAdded:notify(p) end)
> for _, p in Players:GetPlayers() do Signals.PlayerAdded:notify(p) end  -- replay boot
> Players.PlayerRemoving:Connect(function(p) Signals.PlayerRemoving:notify(p) end)
> ```

### 2. Bot replication (server → client) — **required if you use bots on the client**

Bots exist only on the server, so the client learns about them over the wire. Your
networking layer sends three server→client messages; **the id field must be a signed
numeric type** (`f64` / `i53` / `i32`) — a `u32` wraps negative bot ids and breaks the
sign check. Decode them client-side and forward into the registry:

| Server sends (on …) | Client calls |
|---------------------|--------------|
| bot registered — `{ id, name }` (on spawn; re-sent per live bot on client-ready) | `ClientUnitRegistry.OnBotRegistered(id, name)` |
| bot character (re)spawned — `{ id, character }` (after registered; every respawn; re-sent on client-ready) | `ClientUnitRegistry.OnBotCharacterAdded(id, character)` |
| bot removed — `{ id }` | `ClientUnitRegistry.OnBotRemoved(id)` |

Preserve ordering: **registered before character**, and re-send all live bots when a
new client finishes loading (a mid-join client must be able to resolve existing bots).
The registry wires real players itself; you only feed it bots.

### 3. `TypedSubject` (client) — **required by `ClientUnitRegistry`**

A tiny typed facade over whatever subject/signal library you use, exposing:

```lua
TypedSubject.new<T...>(): Subject<T...>
-- Subject<T...> = { subscribe, once, notify, promise }
```

The registry only needs `new` / `subscribe` / `notify`. If you already have a typed
signal type, point the `require` at it and delete the facade.

### 4. A bot driver (server) — **required only if you want bots**

`UnitService` and `BotPlayer` are the *roster + stand-in*; they don't spawn anything. A
**bot driver** owns the bot lifecycle. It is inherently game-specific (it clones *your*
rig, places it in *your* lobby, assigns *your* teams), so it isn't shipped — but it's
small, and the contract is fixed. On **spawn** it must, in order:

1. Allocate the next id: start at `UnitId.ALLOC_START` and go **down** (never reuse —
   a despawned bot's id must not collide with a later one).
2. `local bot = BotPlayer.new(id, name)`.
3. Clone your rig. Parent it; **don't** assign `bot.Character` yet (step 6 does, as it
   fires `CharacterAdded`). Take server ownership of the root: `root:SetNetworkOwner(nil)`.
4. `UnitService.Register(bot)` — so `GetUnit(id)` resolves before anyone is told.
5. `Signals.PlayerAdded:notify(bot)` — runs the same per-participant setup players get.
6. `bot:SetCharacter(rig)` — assigns the rig and fires the bot's `CharacterAdded`
   (the server-side equivalent of the engine signal), so per-spawn logic runs.
7. Replicate to clients: **registered first, then character** (seam #2).

On **respawn**, call `bot:SetCharacter(newRig)` again and re-send the character message.
On **despawn**, in order: `Signals.PlayerRemoving:notify(bot)` (same teardown a real
leave triggers) → `UnitService.Unregister(bot)` → tell clients to drop it → destroy the
rig → `bot:Destroy()`.

> A reference bot driver (`BotService`) and server-callable action shims for bots
> (`BotActions` — attack/carry/throw, since a bot has no client to perform them) live in
> the originating project. They're worth reading as a worked example, but you'll write
> your own against your game's rig, lobby, and combat authority.

---

## Integrating in a new game

1. **Drop the files in.** Place `shared/` under a shared/replicated location, `server/`
   under server-only storage, `client/` under client storage. Adjust the `require`
   paths at the top of each module — they assume `UnitId`, `UnitTypes`, and
   `TypedSubject` live under `ReplicatedStorage.Shared`, and that `BotPlayer` /
   `UnitTeleport` are server siblings of `UnitService`. These are the only edits inside
   the shipped files.

2. **Provide the lifecycle bus** (seam #1) and make one module fan the engine's
   `Players` events onto it, replaying boot-present players. Require that module *last*
   in server startup.

3. **Start the roster/registry.** Server: call `UnitService.Start()` early (before
   anything resolves ids). Client: call `ClientUnitRegistry.Start()` **first**, before
   any controller subscribes or resolves an id.

4. **Adopt the three rules** as you write gameplay: type participants `Unit`; use
   `UnitService.GetAll()` not `Players:GetPlayers()`; use
   `UnitService.GetUnitFromCharacter()` not `Players:GetPlayerFromCharacter()`. On the
   client, subscribe to the registry's `UnitAdded` / `UnitRemoving` / `CharacterAdded`
   rather than the `Players` equivalents.

5. **When you want bots:** write the bot driver (seam #4) and wire bot replication
   (seam #2). Because every gameplay system already speaks `Unit` and iterates the
   roster, bots light up across all of it without per-system changes. Reach for
   `ToRealPlayer` at the points that touch per-client remotes or network ownership.

6. **(Optional) `UnitTeleport`.** Include it only if you teleport characters whose
   physics a client may own (e.g. just after a carry/grab). If you run server-side
   movement validation, set `UnitTeleport.OnTeleported` to reset that unit's pose
   history after the jump; otherwise leave it `nil`.

---

## Why bots break without this (the failure modes)

Each rule exists because a specific thing regressed on its violation:

- **Iterating `Players:GetPlayers()`** for a gameplay sweep → bots aren't in the list →
  they're skipped by scoring/effects/cleanup with no error.
- **`Players:GetPlayerFromCharacter(rig)`** on a bot → `nil` → hit detection and touch
  triggers drop the bot.
- **A `u32` id field on the wire** → a negative bot id wraps to a huge positive number →
  `IsBot` returns false → the client treats a bot as a (nonexistent) player and
  mis-resolves it.
- **Sending a per-client remote to a bot** (instead of checking `ToRealPlayer`) → there's
  no client → the effect never applies; the bot stands still.
- **Binding `Players.PlayerAdded` directly** → the engine event never fires for bots →
  their per-spawn setup silently never runs.

The modules and seams here are arranged so the easy path is the correct one.
