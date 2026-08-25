# LevellingRebirth

Opt-in addon over [`Levelling`](../Levelling): **trade the level you have for a permanently
faster one.**

The level is the price and nothing else is spent — which is what makes the deal explainable in
one sentence, and what stops it needing a confirmation dialog listing everything about to be
destroyed.

**Realms:** server + client + shared. **Wally deps:** none. **Depends on the base by shape,
not by path.**

---

## What a rebirth does

| | |
|---|---|
| **resets** | `level` → the starting level, `experience` → 0 |
| **keeps** | everything else — currency, collections, unlocks, records, purchases |
| **pays** | an XP multiplier from then on, plus whatever `rewards` the rung carries |

> **Anything a level unlocks permanently is a trap**, and it is worth knowing before authoring
> a ladder. A slot, a weapon or an area gated on `level >= N` is taken **back** by a rebirth,
> and a player reads that as the feature stealing from them. Gate permanent unlocks on the
> rebirth count, on a purchase, or on a flag the reset does not touch.

## Setup

```lua
local Levelling = require(ServerScriptService.Levelling.server)
local Rebirth = require(ServerScriptService.LevellingRebirth.server)

Levelling.start({ read = ..., write = ... })

Rebirth.start({
    levelling = Levelling,          -- the started base package, passed IN
    tiers = {
        { index = 1, requiredLevel = 10, multiplier = 2, title = "Awakening" },
        { index = 2, requiredLevel = 20, multiplier = 3, title = "Kindling" },
        { index = 3, requiredLevel = 30, multiplier = 4, title = "Ascension",
          rewards = { gold = 5000, badge = "Ascended" } },
    },
    read  = function(player) return Profiles.get(player).rebirths end,
    write = function(player, count) Profiles.get(player).rebirths = count end,
})

-- Whoever owns the state that should forbid one:
Rebirth.setGate(function(player) return not Match.isPlaying(player) end)

Rebirth.rebirthed:connect(function(player, count, tier)
    if tier.rewards then
        Rewards.pay(player, tier.rewards)
    end
end)
```

`Rebirth.start` registers a multiplier with the base and then never thinks about it again.
Nothing here has to announce the new rate: the base reads the count off the profile on every
grant and every rate announcement.

Client:

```lua
Rebirth.start({ levelling = LevellingClient, tiers = TIERS })   -- the SAME ladder

Rebirth.onChanged(function(state)
    button.Active = state.available
    label.Text = if state.nextTier
        then `{state.nextTier.title} — {state.levelsRemaining} to go`
        else "Nothing left to take"
end)

button.Activated:Connect(Rebirth.request)
```

---

## The ladder is the whole thing

To add an eleventh rung, append a row. Past the last row there is nothing left to take —
`nextTier` returns nil and `isMaxed` says so — which is deliberate, so a rebirth can never be
offered without a number authored for it.

**`setTiers` errors** on a ladder that is misindexed, that asks no more than the rung below, or
that pays **less** than it. A rung that costs no more, or pays worse, is a content bug that
would otherwise ship quietly and only look like bad balance.

A **repeated** multiplier is allowed where a decrease is not: a tier may pay in `rewards`
instead and keep the rate flat. The system this came from required a strictly increasing
multiplier because that was the only thing a rung could pay, which meant a rung could not be
made interesting without changing a number.

The multiplier is defined by the rung **taken**, not accumulated from a per-rebirth step, so
the `multiplier` column is the whole answer and a re-tuned rung changes the rate of exactly the
players who took it. A profile holding more rebirths than the ladder has rungs — a shortened
table, a rollback — reads as the **last** one rather than dropping to ×1, which is the version
of that bug a player writes in to complain about.

## Identity, and not even that

The request carries **nothing**. No tier index to validate, no level to trust, no multiplier on
the wire: the rung is the one after the count in the player's own profile, and the requirement
is read out of the ladder beside it.

A forged call is therefore indistinguishable from a real one and does exactly the same thing —
which is the strongest form of the rule, because there is no argument that could be wrong.

**No debounce**, unlike a high-frequency remote: the state check *is* the guard. A second call
arrives at the starting level, which no rung accepts, so a player hammering the button gets one
rebirth and a series of cheap table reads.

**No result remote.** The answer is the state moving, and the count attribute is written last so
a client watching it cannot read a half-applied trade. A refusal is silent by construction: the
button is disabled by the same ladder the server checks, so the only calls that can be refused
are ones no honest client sends.

### The gate

The state that forbids a rebirth is never in this package. Mid-run, mid-match, in a cutscene,
on a cooldown — whoever owns that state answers `setGate`, and this module refuses without
being told a new rule exists.

Asked **first**, before the profile is read, so a refusal during the common case costs nothing.
**Fails closed:** a gate that errors refuses. The trade is irreversible and the player can
simply press again, which is the cheap direction of that failure.

### Write order

The count is written **before** the level is reset, and the order is the whole safety property.
The base reads the count on every grant, so between the two writes the player is briefly at
their old level with the **new** multiplier — overpaying for an instant. The other order leaves
them at level 1 with the **old** multiplier, and if anything fails in between the player has
paid the price and received nothing.

Overpaying for one frame is recoverable. The trade going one way only is not.

---

## API

### Server

`start(options)` · `rebirth(player) -> tier?` · `canRebirth(player)` · `get(player)` ·
`publish(player)` · `setGate(fn?)` · `rebirthed` — `(player, count, tier)`

The tier is handed to the signal because that is where `rewards` lives: a host paying a title,
a cosmetic or a lump of currency reads it there rather than looking the count back up and
hoping it matches. Fired **last**, after the count, the level reset and the attribute all agree.

### Client

`start(options)` · `getState() -> State` · `getCount()` · `countOf(player)` · `request()` ·
`onChanged(fn) -> unsubscribe`

`getState` hands over everything a window draws in **one shape** — count, level, next tier,
current tier, multiplier, levels remaining, available — because a window reading five getters
one at a time can read them across a change and draw a state that never existed.

`onChanged` fires on a rebirth **and on every level change**. Availability depends on both, and
a rebirth becomes available by *levelling* far more often than by rebirthing: a window
subscribed to the count alone stays greyed out at precisely the moment the player qualifies.

### Shared (`Ladder`)

`setTiers(tiers)` · `validate(tiers)` · `nextTier(count)` · `currentTier(count)` ·
`isMaxed(count)` · `multiplierFor(count)` · `canRebirth(count, level)` ·
`levelsRemaining(count, level)` · `count()` · `tiers`

`validate` is separate from `setTiers` so a host with its ladder in a data file can check it at
build time.

### Why there is a client half at all

The ladder claims *a screen can never offer what the server would refuse* — and that is only
true if the screen is asking the **same** ladder. A game left to derive availability itself ends
up with a second opinion on the question the server already answers, and the two disagree the
first time a rung is re-tuned.

It draws nothing. No window, no button, no copy: `title` is a **key**, not a sentence
("Awakening", not "You have awakened"), and the host maps it to whatever it wants to show, in
whatever language.

---

## Composing by shape

`levelling` is passed in rather than required, so this package depends on the base by shape and
not by path — a vendored copy, a renamed folder or a host's own wrapper all work. Anything with
`get`, `reset`, `addMultiplier` and `refreshRate` will do.

That is also why the trade calls `refreshRate` even though the base's `reset` happens to
announce already: nothing in the four-function contract says it must, and a base that stopped
would leave every rebirthed player earning at the old *displayed* tempo until their next zone
change — which, for someone standing still, is never.

---

## Tests

[`Tests/tests/test-rebirth.luau`](../Tests/tests/test-rebirth.luau) (81, driven against the
**real** `Levelling` package so the composition is actually exercised, plus a stub base for the
shape contract) and
[`test-rebirth-client.luau`](../Tests/tests/test-rebirth-client.luau) (35). 116 checks, every
one of 26 mutants killed.
