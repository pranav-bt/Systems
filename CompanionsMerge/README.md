# CompanionsMerge

Turn duplicate companions into stronger ones. An **opt-in addon** over the
[`Companions`](../Companions) base package.

## The rule

A merge costs **as many copies as the level it reaches**:

| To reach | You hand over |
|---|---|
| level 2 | 2 × level 1 |
| level 3 | 3 × level 2 |
| level 6 | 6 × level 5 |

Which lands the whole ladder at **N! pulls** — 120 for a level 5, 720 for a level 6 — and it is
a price a player can hold in their head after one merge, which a fitted curve never is.

A flat cost is wrong at both ends: out of sight for hours at the bottom, and every rung as cheap
as the one below it at the top. Doubling overcorrects, putting level 10 at 35 trillion pulls.
Matching the level is the shape that works, so it is the default — but it is replaceable, because
a package cannot know what ladder the next game wants.

## Setup

```lua
local Companions = require(path.to.Companions)
local Merge = require(path.to.CompanionsMerge)

Merge.configure({ companions = Companions })
```

The base package is **injected**, not required by path — the dependency is then visible at the
call site and this folder assumes nothing about where anything is parented. It does nothing
without it, by design.

| Option | |
|---|---|
| `companions` | **required** — the `Companions` package |
| `cost(targetLevel) -> number` | replaces the default price. Clamped to a minimum of 2, so no configuration can produce a free merge |
| `consumeEquipped` | may a merge eat a companion that is currently out? **Default false** |

`consumeEquipped = false` is the default on purpose: a player watching three Knights follow them
around should not press Merge and see one of them vanish into the result. The base package would
*survive* it — `reconcile` unequips whatever no longer exists — but surviving is not the same as
being what anybody wanted.

## API

| | |
|---|---|
| `copiesFor(targetLevel)` | the price. **The one place it is answered**, so what a UI shows and what is charged cannot drift |
| `progress(player, petId, level)` | `(have, need)` — a pair, so a UI draws "3 / 6" without asking twice and risking two answers |
| `canMerge(player, petId, level)` | `(ok, reason?)` |
| `merge(player, petId, level)` | one merge. Deliberately does **not** cascade — a UI offering one merge per press has to perform exactly one |
| `mergeAll(player, petId)` | cascades; returns how many merges happened |
| `pending(player)` | every merge available right now, lowest level first |

### Why `mergeAll` goes bottom-up

One pass, lowest level first, and that is **complete** rather than merely usual: a merge only ever
*removes* copies from its own level and adds one above, so it can never re-enable a merge lower
down. Visiting levels in increasing order therefore sees each level after everything that could
feed it — six level 1s become three level 2s become one level 3 in a single sweep.

An earlier version wrapped this in a repeat-until-stable loop. Mutation testing showed the
direction then made no difference to the outcome, which is the tell that the outer loop was doing
the work and hiding whether the ordering was right. It was removed and the ordering became the
argument.

## What it does not own

**The level, and what a level means.** Both live in the base package: the record holds it, and
`Config.levels` says what changes at each rung. This module only decides *when* a level may be
raised and *at what price*, then asks the base to raise it via `Companions.moveCopies`.

That is why it can be installed alongside [`CompanionsUpgrades`](../CompanionsUpgrades) without
the two fighting — both are policies over one primitive, and neither writes the level itself.

The ladder's **ceiling** is the base's too (`Companions.getMaxLevel`), not a number of this
addon's own. But enforcing it *is* this addon's job: `moveCopies` knows nothing about a maximum
and would happily mint a level 11, so `merge` refuses past the top rather than relying on the
base to stop it.

Tests: `Tests/tests/test-companions-addons.luau`.
