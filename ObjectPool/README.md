# ObjectPool

Reusing Instances instead of cloning them.

Cloning isn't free: a clone parents into the tree, streams to clients, and for anything with a
`ParticleEmitter` or a `Sound` it warms up state the engine would rather keep. A pool pays that
once per object and hands the same ones back out.

**Realm:** any. **Wally deps:** none. **No side effects at require time.**

```lua
local Pool = require(ReplicatedStorage.ObjectPool)

local bullets = Pool.new(bulletTemplate, {
    parent = workspace.Shots,
    warm = 20,
})

local shot = bullets:get()
shot:PivotTo(muzzle)
-- later
bullets:release(shot)
```

---

## One pool per template, and a pool is an object

`Pool.new` returns an instance. That matters: the two implementations this replaces were
module-level singletons keyed by a **string tag**, so two systems both using `"bullet"`
silently shared one pool and each got the other's objects back. A pool you construct cannot
collide with a pool somebody else constructed.

The template is never handed out — every object is a clone — so it can stay wherever it was
authored, including `ServerStorage`.

## The release strategy is the thing that varies

Sending an object back can mean unparenting it, parking it out of sight, or switching it off,
and which is right depends on what the object *is*. That's one function:

| | |
|---|---|
| `Pool.unparent` *(default)* | takes it out of the tree. Right for anything with no internal state worth keeping. |
| `Pool.park` | leaves it parented and moves it to `(0, -1000, 0)`. |
| `Pool.disable` | clears `Adornee`, sets `Visible`/`Enabled` false, leaves it where it is. For GUI and billboards, where "gone" is a property rather than a position. |
| your own | `function(instance) … end` |

**`park` exists for particles**, and it's the one genuinely reasoned difference between the two
predecessors. Unparenting a `ParticleEmitter` drops its streaming and resets its warm-up, so
the next use pays for that again and shows a visible hitch. Parking keeps it live and ready,
at the cost of it still existing.

`get` does **not** reset the object it hands you. What "reset" means belongs to the caller, and
a pool that guessed would either miss something or undo something deliberate.

## When the pool is full

A cap bounds memory. What happens when you hit it is a real tradeoff, and it's explicit:

| `onExhausted` | |
|---|---|
| `"grow"` *(default)* | hand out a new clone anyway and **warn once**. Nothing visibly breaks and you're told which pool wants raising. |
| `"steal"` | recycle the object that's been out longest. Usually right for VFX — a distant effect vanishing beats a new one failing to play. |
| `"nil"` | return `nil`. Honest, but it puts a nil check in every caller, and the ones that forget just stop spawning effects with no clue why. |

`"grow"` is the default because blowing a memory guard is much less bad than the alternatives.

> **`"steal"` has a hazard, which is why it isn't the default.** The original holder still has a
> reference and no way to know the object was taken, so their eventual `release` hands back
> something that now belongs to somebody else — and the new owner keeps using an object sitting
> in the free list. The pool can't prevent that without a per-claim token, which would change
> `get` from returning an Instance into returning a handle. Not worth it for short-lived VFX
> nobody holds, so it's opt-in and documented. A stolen object *is* put through `release` on
> the way out, so the new owner gets it in the same state any other reused object arrives in.

## Warming

```lua
Pool.new(template, { warm = 20 })
```

Pre-builds clones so the first burst doesn't pay for them — which is exactly when the frame is
busiest. Warmed objects go **through the release strategy** on the way in, so a warmed object
is in the same state a released one is; otherwise the first `get` from a parked pool would hand
back something sitting at the origin, in view.

`warm` never overshoots `max`.

## `onCreate`

```lua
Pool.new(vfxTemplate, {
    onCreate = function(instance)
        emitters[instance] = instance:GetDescendants()   -- once, not per get
    end,
})
```

Runs once per **clone**, not per `get`. It's the seam that replaces a predecessor's
`GetDescendants()` walk on *every* clone to build a table the library never read — per-clone
puts that cost where the cloning cost already is.

## Releasing is forgiving

```lua
pool:release(somethingElse)  --> false, no error
pool:release(alreadyBack)    --> false, no error
```

Both predecessors looked the tag up in their active map and inserted into the free list at that
key without checking — so an object they'd never handed out indexed a nil table and threw.
Double-release is the mistake every pool caller eventually makes, usually in the error path of
something that has already gone wrong. It returns whether the pool was actually holding it, so
a caller that wants to know can ask.

## API

| | |
|---|---|
| `Pool.new(template, options?)` | |
| `pool:get() -> Instance?` | `nil` only when capped with `onExhausted = "nil"` |
| `pool:release(instance) -> boolean` | whether it was holding it |
| `pool:releaseAll()` | everything currently out |
| `pool:warm(count)` | |
| `pool:destroy()` | destroys every clone, in use or not. Leaves the template alone — the pool never owned it. Usable again afterwards. |
| `pool:stats() -> free, active, created` | what a debug overlay reads |

Options: `parent` · `max` · `onExhausted` · `release` · `onCreate` · `warm`

---

## Tests

[`Tests/tests/test-objectpool.luau`](../Tests/tests/test-objectpool.luau) — 65 checks, all 15
mutants killed.

## Replaces

`SharedUtils.ObjectPool` and `SharedUtils.InstanceObjectPool`, which were the same idea with
divergent choices. What came across: keying by the template rather than a string tag, the
parking strategy, the cap. What didn't: the global singletons, the `Release` crash on a foreign
or double release, the `emissions`/`isVfx` state that was built and never read, and the Folder
one of them created in `workspace` **at require time** — which fired on the client too and made
the module impossible to load anywhere else.

`RegisterObjectFromStringKeys` didn't come across either. It wasn't pooling: it's *variant
lookup* ("which template for this set of attributes"), which is a separate helper that picks a
template and hands it to `Pool.new`.
