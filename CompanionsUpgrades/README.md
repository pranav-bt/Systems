# CompanionsUpgrades

Pay to raise a companion's level. An **opt-in addon** over the
[`Companions`](../Companions) base package, installable alongside
[`CompanionsMerge`](../CompanionsMerge).

The two are the same mutation for different reasons — merging demands **copies**, this demands
**currency** — so both are policies over one primitive, `Companions.moveCopies`, and neither owns
the level. That is what stops them disagreeing about what a player has.

## Setup

```lua
local Companions = require(path.to.Companions)
local Upgrades = require(path.to.CompanionsUpgrades)

Upgrades.configure({
    companions = Companions,

    -- What a rung costs. nil means "not for sale at this rung".
    price = function(petId, targetLevel)
        return targetLevel * 100
    end,

    balance = function(player) return Wallet.gold(player) end,
    charge  = function(player, amount) return Wallet.spend(player, amount) end,
})
```

| Option | |
|---|---|
| `companions` | **required** — the `Companions` package |
| `price(petId, targetLevel) -> number?` | **required.** `nil` caps a ladder partway, or makes a companion merge-only |
| `balance(player) -> number` | **required** — what they can spend |
| `charge(player, amount) -> boolean` | **required** — take it. `false` aborts |
| `upgradeEquipped` | may the copy being upgraded be one that is currently out? **Default true** |

**`price` has no default** because there isn't a sensible one: a price is a statement about a
game's economy and this package cannot guess it. Nothing here knows what the currency is either —
gold, gems, energy, an off-server wallet — which is why `balance` and `charge` are seams rather
than a number and a field.

**`upgradeEquipped` defaults to *true*, the opposite of merge's `consumeEquipped`,** because the
verbs differ: merging *consumes* copies, so eating a fielded one is a loss the player did not ask
for, while upgrading *transforms* the copy in place — and the companion someone most wants to
improve is usually the one they are looking at.

## API

| | |
|---|---|
| `priceOf(petId, level)` | what raising `level` costs, or `nil` if that rung is not sold |
| `upgradable(player, petId, level)` | how many copies at that level are eligible |
| `canUpgrade(player, petId, level)` | `(ok, reason?, price?)` — the price comes back **with** the answer, so a caller need not ask twice and risk two answers |
| `upgrade(player, petId, level)` | charge, then raise |
| `affordable(player)` | every rung buyable right now, lowest level first |

## Charge first, then move

Every reason the move could fail is checked **before a coin is taken** — a copy exists, the next
rung is within the companion's ladder, it is for sale, they can afford it — so the move that
follows cannot legitimately refuse.

If it somehow does, the player has **paid and not received**, which is fixable by hand. The other
order risks a **free level**, which cannot be taken back. When it does happen, the warning names
the player, the amount and the rung so it can be found in a log rather than inferred from a
complaint.

`charge` is a separate seam from `balance` precisely so a host can refuse at the last moment — a
receipt that failed, a rate limit, another server having spent the same gold — and returning
`false` aborts **before** the level moves rather than after.

## What it does not own

The level, what a level changes, and the ladder's ceiling all belong to the base package. This
module enforces the ceiling rather than trusting it, though: `moveCopies` knows nothing about a
maximum and would happily mint a level 11.

Tests: `Tests/tests/test-companions-addons.luau`.
