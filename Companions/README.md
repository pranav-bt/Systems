# Companions

Server-owned pet/companion system: models are cloned out of `ReplicatedStorage`, parented into
`Workspace` and replicated, so companions are visible to everyone. Owns the **collection**
(who owns what, at which level), the **loadout** (which named slot holds what), and the
**bodies** (rigs, positions, per-pet tick hooks).

## Overview

- **Content is declared, not built in.** `definePet` says what a companion is; `setTick` says
  what it does. The package ships no companions and knows nothing about any game.
- **Ownership is a count per level**, not a boolean. A player may hold nine level 1 Knights and
  two level 2s, and a collection screen lists those as two entries.
- **Slots are identified**, not counted. A companion is equipped *into* `"Slot2"` and the record
  says so.
- **No combat.** Nothing here shoots, swings, damages or raycasts (bar finding the floor for a
  ground-walking pet), and following pets are configured not to block the host's raycasts.
  What a companion *does* is a tick hook.
- **No UI, no copy.** Refusals come back as reasons for the host to word.
- **No in-run levelling.** A level is a permanent property of an owned copy. Raising one is what
  the addons are for.
- Self-contained: no Wally packages, no external requires.

## Files

| File | Purpose |
|---|---|
| `src/init.luau` | Lifecycle, spawning, the public API. |
| `src/Loadout.luau` | The record: ownership, slots, the loadout. **Pure** — no Instances. |
| `src/Config.luau` | Every tunable, plus the slot and pet declarations. |
| `src/Catalog.luau` | Reads the asset folder into a list of available companions. |
| `src/Rig.luau` | Builds one live pet: clone, weld, animate, attach to a position. |
| `src/Slots.luau` | Resolves a character's attachment positions. |
| `src/Ticker.luau` | Per-pet tick scheduling. |

Movement modes, the idle loop and one-shot actions are covered below.

Tests: `test-companions-loadout.luau` (103 checks, the pure record layer),
`test-companions.luau` (75, the public API, persistence and the per-pet hooks) and `test-companions-rig.luau`
(54, follow modes and animation) — all headless, no Studio.

## Quick start

```lua
local Companions = require(path.to.Companions)

-- What a companion IS.
Companions.definePet("Knight", {
    settings = { tickInterval = 2, scale = 0.8 },
    levels = { {}, { tickInterval = 1.6 }, { tickInterval = 1.2, scale = 1 } },
})

-- What it DOES. Nothing in here may yield.
Companions.setTick("Knight", 2, function(context)
    -- context: player, petId, uid, model, root, slotKey, level, interval, dt, elapsed
end)

Companions.start({
    persistence = {
        load = function(player) return Profiles.get(player).companions end,
        save = function(player, record) Profiles.get(player).companions = record end,
    },
})

Companions.grant(player, "Knight")            -- one level 1 copy
Companions.equipAnywhere(player, "Knight")    -- into the first free unlocked slot
```

Put one `Model` per companion in `ReplicatedStorage.Pets` (configurable), named by its pet id.
Subfolders become categories.

## Ownership

`owned[petId]` is a **dense array indexed by level**. Owning one level 3 copy and nothing else is
`{ 0, 0, 1 }`.

That is not a style choice. A table keyed by *number* does not survive a DataStore round trip —
it comes back keyed by the string `"2"` and silently stops matching, so every count reads zero
and the player's collection appears to have been wiped. A contiguous array survives. `sanitise`
also *repairs* the string-keyed shape on load, so a record written by anything that got this
wrong heals instead of reading empty.

| | |
|---|---|
| `grant(player, petId, level?, count?)` | adds copies; returns the new count |
| `take(player, petId, level, count?)` | removes copies; **refuses** rather than clamping |
| `moveCopies(player, petId, from, to, count?)` | `count` leave `from`, **one** arrives at `to` |
| `ownedCount` / `ownedLevels` / `totalOwned` / `ownedIds` | reads |
| `available(player, petId, level)` | owned minus already equipped |
| `getRecord(player)` | a **copy** of the whole collection |

An unknown pet id is granted anyway, with a warning: ownership is a fact about the player, the
catalog is a fact about which models have loaded, and refusing would make a grant depend on asset
timing. Equipping it refuses.

## Slots

A slot is **declared and identified**, not counted:

```lua
Companions.clearSlots()  -- drop the three this package ships
Companions.defineSlot("LeftShoulder",  { order = 1, unlockedByDefault = true, attachment = "PetSlotL" })
Companions.defineSlot("RightShoulder", { order = 2, attachment = "PetSlotR" })
Companions.defineSlot("Trail",         { order = 3 })
```

- **`order`** — display and allocation order. Ties break by id, so the sequence is total and never
  depends on table iteration.
- **`unlockedByDefault`** — free for everybody. A record stores only *explicit* unlocks, so making
  a slot free later lifts every existing player at once, with nothing to migrate.
- **`attachment`** — pins the slot to a character attachment **by name**, so "slot 2 is the left
  shoulder" holds across respawns. Omit it and the slot takes the next free position the
  character's schema offers, remembering it for next time.

A count would have been smaller and would have thrown all of that away — and none of it can be
recovered from a number afterwards.

**There is no separate cap on how many companions may be out.** It is how many unlocked slots the
player has, full stop. A second number would be a second answer to one question, and the two would
eventually disagree.

| | |
|---|---|
| `unlockSlot` / `relockSlot` / `isSlotUnlocked` | `relock` empties the slot with it |
| `unlockedSlots` / `lockedSlots` / `nextLockedSlot` | in declared order |
| `freeSlot(player)` | first unlocked slot with nothing in it |

Nothing here charges anything. Deciding a player earned a slot — gold, Robux, a level, a promotion
— is the host's economy.

## The loadout

| | |
|---|---|
| `equip(player, slotId, petId, level?)` | into a named slot |
| `equipAnywhere(player, petId, level?)` | the first free unlocked slot |
| `unequip(player, slotId)` / `unequipAll(player)` | |
| `equippedAt(player, slotId)` | `{ petId, level }?` |
| `equippedSlots(player)` | occupied slots, in declared order |
| `slotOf(player, petId, level?)` | which slot holds it |

**`equip` refuses an occupied slot** rather than replacing what is in it. A swap is two decisions
and the caller has made one; silently dropping a companion because the player dragged something
onto its square is the kind of helpfulness that loses a level 5.

The same companion may occupy several slots at once — that is what a count-per-level collection
means — at the same level or different ones.

## One funnel, and why it matters

Every mutation ends the same way: **reconcile → sync → save and announce.**

`reconcile` empties slots that cannot legitimately hold what they hold — an undeclared slot id, a
slot the player no longer has unlocked, or a copy that no longer exists because a merge or a trade
consumed it. That is what makes `moveCopies` safe to expose as a raw primitive: an addon that
consumes a fielded copy gets a companion **unequipped**, not a phantom one still standing there.

When copies run short, the survivor is the slot the player arranged **first** — reconcile walks in
declared order, so the earliest slot is counted before the later ones.

`syncPets` then makes the bodies match the loadout, slot by slot. A slot whose companion is merely
at a different level is **retuned rather than rebuilt**, so an upgrade landing while the pet is out
is visible on it instead of causing a despawn and a respawn.

## Persistence

The **record is the unit** — ownership, loadout and unlocks together — because they constrain each
other, and two adapters writing halves of one fact would eventually disagree about it.

```lua
persistence = {
    load = function(player) return anything end,   -- put through sanitise
    save = function(player, record) end,
}
```

`load` may return anything at all: it goes through `sanitise`, which repairs what it can and drops
what it cannot, then `reconcile`. So a host may hand over a raw DataStore table without checking
it. **A load never triggers a save** — otherwise every join would write.

## Per-pet hooks: where host state belongs

```lua
Companions.onSpawned(function(context)
    health[context.uid] = 100
end)

Companions.onDespawned(function(context)
    health[context.uid] = nil
end)
```

`context` is `{ player, petId, uid, slotId, model, root, level, settings }`.

**`onSpawned` fires per BODY, not per equip** — including a character respawn, which rebuilds
rigs without the loadout changing at all. A listener hung on `onEquippedChanged` would
initialise once and never again, and its state would silently carry over from a previous life.

**Key on `uid`, not on `slotId` or `petId`.** A `uid` is unique per live pet and changes when
one respawns, so state about the previous body stops applying by construction rather than by
the host remembering to clear it. A slot, by contrast, can be refilled by a different body.

**`onDespawned` fires before the model is destroyed**, so a listener can read where the pet
ended up. It covers every way a pet goes away: unequipped, its copy consumed by a merge or a
trade, its owner's character dying, or the player leaving.

Listeners are `task.spawn`ed, like every other hook here — host code may yield and must not be
able to fail the spawn or teardown that told it. The consequence for `onDespawned` is worth
knowing: **a listener that yields resumes to find the model destroyed**, so read what you need
before you wait on anything.

### There is no health, deliberately

Nothing in this package tracks damage or hit points, and nothing can kill a companion. Health
is a game's rule, not a companion system's — what it means to die, whether death unequips the
slot or leaves a corpse, whether it persists across a respawn. These two hooks plus `uid` are
what a host needs to build it, and `unequip(player, slotId)` is how it removes the loser.

## Movement modes

`followMode`, per companion:

| | |
|---|---|
| **`Float`** *(default)* | `AlignPosition` + `AlignOrientation` onto the character's slot attachment. Hangs in the air, collides with nothing. Add `bobAmplitude` for an idle bob. |
| **`Ground`** | the same constraints, aimed at the floor *below* the slot, so the pet walks along it. |
| **`Weld`** | rigidly locked to the slot. No drift, no lag, no life. |
| **`Detached`** | no attachment claimed and no constraints at all. |

### Ground finds the floor by ray, not by gravity

The obvious implementation is to make a ground pet collide with the world and let gravity
hold it down. That needs a **collision group this package cannot create**, and a collidable
pet shoves its owner, shoves other pets, and wedges itself in doorways.

Instead the existing `AlignPosition` is switched to one-attachment mode and aimed at a point
found by a downward ray. The pet stays as inert as a floating one, and the whole mode is
testable without a physics world.

The ray is **throttled**, not per-frame (`Config.groundInterval`, default 0.1s): the floor
under a running player changes slowly next to 60Hz. The pet still *moves* smoothly between
checks, because the constraint interpolates — only the target is stepped. A pet over a chasm
keeps its last known height rather than diving after the floor.

`Companions.setRaycast(fn)` replaces the finder. "Where is the floor" is a question about the
world, and a game with voxel terrain or a moving platform layer answers it better than a
raycast does.

Orientation still follows the slot in **both** modes — the floor has nothing to say about
which way a pet faces.

### Detached is defined by its absence

No attachment, no constraints, placed where the character stands and then left alone.
Everything else about it is ordinary: it fills a loadout slot, it ticks, and it despawns with
the slot and with the character. **Only its movement is the host's.**

```lua
local rig = Companions.getPet(player, "Slot1")   -- rig.model, rig.root
Companions.setPhysics(player, "Slot1", { canCollide = true, canQuery = true })
```

A following pet is decoration and is built inert on purpose — it must not block the host's
raycasts or trip its collision handlers. A detached one may be a mount, a turret or a
vehicle, and none of those work inert, so the host says what it needs. Only the fields given
are applied, so turning collision on does not silently also make the pet queryable.

## Animation

### The idle loop

Supply an `animationId` and that is the whole configuration:

```lua
Companions.definePet("Knight", { settings = { animationId = "rbxassetid://123" } })
```

`loopAnimation` is three-valued: **nil** (the default) plays a loop if there is one to play;
**true** means there had better be one, and warns when there is not; **false** stays static
even when an animation is authored inside the model. An `Animation` instance inside the model
works as well as an id, via `animationName` or simply the first one found.

### One-shot actions

```lua
Companions.playAction(player, "Slot1", "rbxassetid://swing")
```

Plays over the idle loop and hands back when it ends. **By slot, not by pet id** — two copies
of one companion may be out at once, and "make the Knight swing" would not say which.

The loop is **weighted out, not stopped**. Stopping it would restart it from frame zero on
the way back, so a pet that acts twice would visibly reset its idle in between. A second
action **replaces** the first rather than layering: two one-shots at once produce a pose
neither animation describes.

`stopAction` cuts one short, and the loop returns through the track's `Stopped` — one path
back rather than two that could disagree. `isPlayingAction` reports the state. Animation
instances are cached per rig by asset id, so a pet that swings a thousand times does not
accumulate a thousand `Animation` children.

## Levels

A level is a permanent property of an owned copy. This package treats it as a **parameter**: a pet
spawns at its copy's level, and `Config` says what each level changes (`tickInterval`, `scale`,
follow tuning, anything a host adds via `setLevelHook`). It is published on each rig's `Model` as
an attribute, because two copies of one companion may be out at different levels and a single
mirrored number could only describe one of them.

*Raising* a level is not here. That is `CompanionsMerge` (hand over copies) and
`CompanionsUpgrades` (pay a cost) — both policies over the same `moveCopies` primitive, so the two
can be installed together without fighting over who writes the level.

## Extraction notes

Extracted from the CA game, whose `PetService` was already written as a drop-in package — its own
header declared the contract and every require in it was relative. The core moved almost as-is;
what changed was everything around it.

1. **The in-run levelling subsystem is gone** — 507 lines. CA had *two* ladders: a per-run star
   rank fed by reinforcement cards, which auto-merged three-of-a-kind **on the field**, and a
   permanent one from merging owned duplicates. Only the permanent one is a companion system's
   business, so `upgrade`, `getStack`, `getStackLevels`, `levelUp`, `levelUpAll`, the whole
   leader/follower stack machinery and `stackSize`/`stackOffset`/`stackCentreBand` all stayed
   behind. CA's own code carried a warning comment about the two levels being different things;
   with one level there is nothing to warn about.
2. **The loadout is slot-keyed.** CA keyed it by pet id and expressed multiples through the stack
   mechanism, so removing stacks would have meant owning five Knights and fielding exactly one.
3. **Ownership moved in.** CA's loadout server wrote the game's profile directly; the record and
   its persistence adapter are the package's now, so the addons have one place to write.
4. **`maxEquipped` is gone**, replaced by the slot declaration — see above.
5. **Prices left behind.** CA's slot config carried gold costs and developer-product ids. Only the
   mechanism came across.
6. **`ownedAttachment` is kept but unwritten.** `spawnFollower` was its only producer. It is the
   anchor a pet needs when it is *not* hanging off a character slot — a ground-walking or detached
   follow mode — and its teardown path is already correct, which is the expensive half.

Nothing here yields. Tick handlers, level hooks and equip listeners are all `task.spawn`ed, so host
code that blocks cannot stall a sweep or fail the change that called it.
