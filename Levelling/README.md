# Levelling

A permanent player level, earned through **one door**.

XP is the number in a progression game that every system wants to hand out — a kill, a quest,
a timer, a zone, a daily login. The moment two of them write the profile directly there are
two copies of the level-up loop, two places a multiplier has to be remembered, and one of them
is always the one that gets missed. Everything here exists to make `grant` the single write.

**Realms:** server + client + shared. **Wally deps:** none.

Rebirth lives in its own package, [`LevellingRebirth`](../LevellingRebirth) — a level system
that never resets is the common case, and the base does not know the addon exists.

---

## The two calls that are the whole interface

```lua
Levelling.grant(player, amount)               -- the AMOUNT, into the profile
Levelling.setRate(player, source, perSecond)  -- the TEMPO, out to the one client earning it
```

`amount` is always a **base** number. Whatever the source thinks the thing was worth, before
any bonus — the caller never has to know the player owns a 2× gamepass, has rebirthed three
times, or caught a double-XP weekend.

## Setup

```lua
local Levelling = require(ServerScriptService.Levelling.server)

Levelling.start({
    read = function(player)
        local profile = Profiles.get(player)          -- yours, whatever it is
        if not profile then return nil end            -- nil = not loaded; the grant is dropped
        return profile.level, profile.experience
    end,
    write = function(player, level, experience)
        local profile = Profiles.get(player)
        if profile then
            profile.level, profile.experience = level, experience
        end
    end,
})

-- Once a profile has actually loaded:
Levelling.publish(player)
```

`read` / `write` are the only contact with storage. A ProfileService document, a plain table
and a set of attributes are all equally valid homes for the two numbers — this package never
picks a datastore, a schema or a key.

Client:

```lua
local Levelling = require(ReplicatedStorage.Levelling.client)
Levelling.start({})

Levelling.onChanged(function(reading)
    bar.Size = UDim2.fromScale(Levelling.getProgress(), 1)
    label.Text = `Level {reading.level}`
    if reading.crossed > 0 then
        playLevelUpSound()
    end
    if reading.gained > 0 then
        popXp(reading.gained)
    end
end)
```

---

## Multipliers are a named stack

The one real departure from the system this was extracted from, which hardcoded exactly one
multiplier (rebirth) inside the grant function. That works right up until the second one
exists.

```lua
Levelling.addMultiplier("gamepass", function(player)
    return if ownsDoubleXp(player) then 2 else 1
end)

Levelling.addMultiplier("weekend", function()
    return if isEventLive() then 2 else 1
end)
```

- **Composed by product.** A ×2 gamepass and a ×3 rebirth make ×6. That is what a player
  expects from two things that each say "double"; summing bonuses makes the second one worth
  less than the first, which reads as a bug in the shop.
- **Applied to the amount AND the tempo**, in one place, so the two cannot drift.
- **Registered by name**, so re-registering replaces rather than squaring, and a source can be
  removed when the pass is refunded.
- **Fail-soft.** Each is `pcall`ed; one that throws contributes 1. An XP source paying unscaled
  is a far smaller problem than one paying nothing. A multiplier of `0` or a non-number also
  counts as 1 — zero would silently switch off every XP source in the game, and nothing can
  tell that apart from a registrant with a bug.

An XP source added tomorrow is scaled by having been written at all.

## The curve

`cost(N) = base + perLevel × (N-1) + squared × (N-1)²` — 100 / 50 / 25 by default, so level
1→2 costs 100 and level 10→11 costs 2,575.

Quadratic rather than exponential because the numbers stay **sayable**: a player can read
"2,575 XP" off a bar, where an exponential reaches figures that mean nothing to anyone by
level 30.

```lua
Levelling.start({ curve = { base = 250, perLevel = 100, squared = 40, maxLevel = 50 } })

-- Or replace the shape entirely:
Levelling.Curve.setCurve(function(level) return LEVEL_COSTS[level] end)
```

| setting | default | |
|---|---|---|
| `base` / `perLevel` / `squared` | 100 / 50 / 25 | the quadratic's three terms |
| `startLevel` | 1 | what a fresh profile starts at, and what a reset returns to |
| `maxLevel` | `nil` | the ceiling, or none |
| `rewardPerLevel` | 0.05 | what a level is worth, as a multiplier |

Curve settings are **merged** into the defaults, so passing `maxLevel = nil` does not clear a
cap set earlier — write `Levelling.Curve.settings.maxLevel = nil` for that. In practice a game
sets the curve once, at start.

**`rewardPerLevel` is not applied to anything.** `Curve.rewardMultiplier(level)` is a number
you read and multiply into whatever levelling is meant to make better — pickup values, damage,
income, drop rates. Shipping the list of what-gets-scaled would be shipping a game's stat
table; the game this came from scaled six combat stats by name, and that is exactly the part
that does not travel.

### At the cap, XP stops accumulating

Rather than piling up invisibly. A capped player whose XP kept counting would level up the
instant a designer raised the cap, by an amount nobody can predict — and would meanwhile watch
a bar that fills forever and never resolves.

The overflow is **reported** rather than hidden:

```lua
Levelling.overflowed:connect(function(player, wasted)
    Currency.add(player, "gold", wasted * 0.1)   -- convert it, or ignore it
end)
```

---

## What replicates

Level and experience are published as **attributes on the Player**, not as a remote push and
not as NumberValues:

- they replicate to every client, so a level next to a name in a list is a lookup rather than a
  round trip — `Levelling.levelOf(anyPlayer)`
- `GetAttributeChangedSignal` exists whether or not the attribute has ever been written, which
  a `ChildAdded` race does not

**Experience is written before level, always.** The level attribute is what a client watches to
know something happened, so a reader woken by it must never find the experience still stale.

**Writing is the server's.** Every level is public to every client, which is the point — but a
client can set the attribute on its own Player object, and that write replicates to nobody, so
it can only ever lie to itself. The server reads its own copy, and `grant` is the only thing
that moves it.

The one edge that follows: a client's *own* `getLevel` / `levelOf` can be locally forged. Fine
for drawing a bar; **never gate anything on it client-side** — a door, a shop button, a reward —
without the server checking `Levelling.getLevel(player)` again.

Both names are configurable (`levelAttribute`, `experienceAttribute`) — "Level" is a popular
name and this package should not silently fight a game that already publishes one. **They are
two ends of one wire: a game that renames one has to rename both realms.**

### The client half is more than a mirror

| | |
|---|---|
| **coalescing** | one grant writes two attributes and lands as two changes. Applying each in turn shows a level-up with a stale bar, then a negative gain. They are folded into one `task.defer`, so one grant is one state change. |
| **`gained` across a boundary** | experience resets on every level, so a subtraction reports a **loss** on the one grant worth celebrating. `+250 XP` would draw as `-80`. |
| **first-sync suppression** | a returning level-40 player has not just levelled up forty times. |
| **no forward-only rule** | a rebirth and an admin reset both move the level *down*, and a forward-only filter would leave the bar showing a level the player no longer has. |

## The tempo

`setRate` exists because **the client cannot answer the question.** A UI that spells one grant
out as a stream of small "+1"s has to know the moment the income stopped — otherwise it is
still counting out the last payment seconds after the player left the zone, which is feedback
for something they are no longer doing.

Deriving it client-side means a second copy of the payout rule (is a menu open, is the run
paused, which of two overlapping zones wins), and the two eventually disagree.

```lua
Levelling.setRate(player, "trainingZone", 4)   -- entering
Levelling.setRate(player, "trainingZone", 0)   -- leaving
```

- **Keyed by source and summed**, because a timer and a zone are independent owners and neither
  should have to know the other exists. Where they are in practice mutually exclusive, the sum
  is a safety property: a source that forgets to switch off cannot be silently overwritten.
- **Sent on change only.** Re-announcing the same rate costs no message.
- **A tempo, never a reward.** The pops are paid for out of the published experience attribute,
  which is the server's own number, so a rate that is wrong or late makes the stream the wrong
  *shape* and cannot make the total wrong. That is what lets callers announce from wherever is
  convenient — the tick that decides to pay, rather than every place that could have changed
  the answer.

Sources hold **base** rates and the stack is applied to their sum on the way out, so a new
multiplier needs no announcement of its own. `Levelling.refreshRate(player)` for a bonus that
arrived from outside this package (a gamepass bought mid-session).

---

## API

### Server

| | |
|---|---|
| `start(options)` | seams, attribute names, curve settings. Provisions its own remote. Idempotent. |
| `grant(player, amount) -> granted, crossed` | the single door. Returns the **scaled** amount and how many levels it crossed. |
| `set(player, level, experience?)` | assign outright, ignoring multipliers. Fires `changed`, never `levelUp` — an assigned level is not a reached one, and a host paying per level must not pay out for an admin fixing a profile. |
| `reset(player)` | back to `startLevel` with no experience. |
| `get(player) -> level, experience` / `getLevel(player)` | |
| `publish(player)` | write both attributes. Call once a profile has loaded. |
| `addMultiplier(name, fn)` / `removeMultiplier(name)` / `multiplierFor(player)` | |
| `setRate(player, source, perSecond)` / `refreshRate(player)` / `getRate(player)` | |
| `levelUp` | `(player, level, crossed)`. `crossed` is a **count** — a big grant can cross several, and a host paying per level owes all of them. |
| `changed` | `(player, level, experience, gained)`, every grant that changed anything. |
| `overflowed` | `(player, wasted)`, capped players only. |

Signals are plain Lua, not BindableEvents — a BindableEvent **serialises** its arguments, so a
listener would receive a copy rather than the table that was fired. Handlers are spawned, so
one that errors or yields cannot hold up a grant. `connect` returns something with
`:disconnect()`.

### Client

`start(options)` · `getLevel()` · `getExperience()` · `getRequired()` · `getProgress()` ·
`getRewardMultiplier()` · `getRate()` · `levelOf(player)` · `onChanged(fn) -> unsubscribe` ·
`onRate(fn) -> unsubscribe`

`getProgress()` returns **1** at the cap, not 0 — the bar is full and stays full. Dividing by
the infinite `required` would draw an empty bar on the player who has earned the most.

### Shared (`Curve`)

`xpToNext(level)` · `applyExperience(level, experience, amount) -> level, experience, crossed, wasted` ·
`gainedBetween(...)` · `rewardMultiplier(level)` · `isMaxLevel(level)` · `totalFor(level, experience)` ·
`setCurve(fn?)` · `settings`

`totalFor` is what a **leaderboard** sorts on. Level alone cannot order two players — one a
single grant short of levelling ranks equal with one who just arrived — and (level, experience)
is two keys where an OrderedDataStore takes one.

---

## Tests

[`Tests/tests/test-levelling-curve.luau`](../Tests/tests/test-levelling-curve.luau) (57),
[`test-levelling.luau`](../Tests/tests/test-levelling.luau) (84),
[`test-levelling-client.luau`](../Tests/tests/test-levelling-client.luau) (35) — all three
realms, 176 checks, every one of 36 mutants killed.

---

## Extracted from

A permanent level with an XP-per-second run timer and paid training zones. What did **not**
come along: the combat stat allow-list (`bulletDamage`, `shootRate`, `pierceCount`) that the
level multiplier was applied to, the per-second run rate, and the game's own mirror system. The
hardcoded rebirth multiplier inside the grant function became the named stack above.
