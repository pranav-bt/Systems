# Tests

The repo's headless test suite. **Any change to a library belongs with tests here.**

Everything runs under [Lune](https://lune-org.github.io/docs) from the repo root — no Studio,
no Rojo, no place file:

```
lune run Tests/tests/test-mech.luau
lune run Tests/tests/test-castle.luau
lune run Tests/tests/test-bnb.luau
```

58 checks at present (18 Mech, 19 Castle, 21 BnB), all passing.

## Layout

| Path | What it is |
|---|---|
| `DESIGN.md` | working notes: how three shipped games' bot systems map onto the AI suite |
| `REPORT.md` | the feasibility findings that came out of it |
| `src/` | policy modules under test — the consumer-land code a game would actually write |
| `tests/harness.luau` | assembles the `Bots` facade and provides `check` / clock helpers |
| `tests/test-*.luau` | one file per archetype |
| `tests/vendor/` | copies of `Bots/src`, with `require(script.Parent.X)` rewritten to `require("./X")` |

## Why `vendor/` exists, and its one hazard

Library sources use `require(script.Parent.X)`, and `script` is a Roblox global that does not
exist under Lune — so the modules cannot be required as they are. `vendor/` holds copies with
those requires rewritten.

**The hazard is drift.** Nothing currently enforces that `vendor/` matches `Bots/src`, so a
library change leaves the copies stale and the tests keep passing against the old code. Twelve
of the thirteen files are byte-identical today; `vendor/init.luau` is not, though the harness
builds its own facade and never requires it. Before trusting a run after touching `Bots`,
re-vendor or diff.
