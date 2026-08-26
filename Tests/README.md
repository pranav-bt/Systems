# Tests

The repo's headless test suite. **Any change to a library belongs with tests here.**

Everything runs under [Lune](https://lune-org.github.io/docs) from the repo root — no Studio,
no Rojo, no place file:

```
lune run Tests/tests/test-zone.luau           # geometry, ticker, lifecycle      89
lune run Tests/tests/test-zone-types.luau     # subject-type registry           91
lune run Tests/tests/test-zone-signals.luau   # event identity and isolation    30
lune run Tests/tests/test-community-reward.luau  # claim flow, once and only once  51
lune run Tests/tests/test-community-reward-client.luau # its client transport      18
lune run Tests/tests/test-companions-loadout.luau # the record layer, pure        103
lune run Tests/tests/test-companions.luau        # public API, persistence, hooks  75
lune run Tests/tests/test-companions-addons.luau # merge and pay-to-level          66
lune run Tests/tests/test-companions-rig.luau    # follow modes and animation      54
lune run Tests/tests/test-companions-ticker.luau # per-pet tick scheduling         26
lune run Tests/tests/test-trading.luau           # trade sessions, offers, swaps   72
lune run Tests/tests/test-trading-lines.luau     # the default line shape          23
lune run Tests/tests/test-trading-client.luau    # its client transport            22
lune run Tests/tests/test-mech.luau           # AI suite: Mech archetype        18
lune run Tests/tests/test-castle.luau         # AI suite: Castle archetype      19
lune run Tests/tests/test-bnb.luau            # AI suite: BnB archetype         21
lune run Tests/tests/test-levelling-curve.luau   # the XP curve, pure              57
lune run Tests/tests/test-levelling.luau         # the grant door + tempo          84
lune run Tests/tests/test-levelling-client.luau  # its client mirror               35
lune run Tests/tests/test-rebirth.luau           # the ladder + the trade          81
lune run Tests/tests/test-rebirth-client.luau    # its client state                35
lune run Tests/tests/test-bots-blackboard.luau   # sensors + invalidate            30
lune run Tests/tests/test-pathfinding-costs.luau # what PathAgent asks CreatePath  22
lune run Tests/tests/test-objectpool.luau        # instance reuse + cap policy     65
lune run Tests/tests/test-zone-query.luau        # stateless geometry queries      44
lune run Tests/tests/test-timesync.luau          # latency, and who names it       26
lune run Tests/tests/test-heatmap.luau           # RLE + the flush failure path    24
lune run Tests/tests/test-lagcomp-snapshots.luau # the pose ring buffer            46
lune run Tests/tests/test-lagcomp-rewind.luau    # claim gates + LOS filter        49
```

1398 checks at present, all passing.

Libraries parked under `Temp/` (gitignored) keep their tests beside them rather than here, and
are run directly: `lune run Temp/test-moveables.luau`. A published test that loads an
unpublished library is a suite that fails on a fresh clone. **Every realm of every library is covered** --
server, client and shared -- because "tested" meaning only the server half is how a client
typo survives a green run. Each file prints `N passed, M failed` and exits non-zero
on failure.

## Layout

| Path | What it is |
|---|---|
| `DESIGN.md` | working notes: how three shipped games' bot systems map onto the AI suite |
| `REPORT.md` | the feasibility findings that came out of it |
| `src/` | policy modules under test — the consumer-land code a game would actually write |
| `tests/harness.luau` | assembles the `Bots` facade and provides `check` / clock helpers |
| `tests/test-*.luau` | one file per archetype or per library concern |
| `tests/shim/roblox.luau` | minimal Roblox stand-in: `Vector3`, `CFrame`, `Instance.new`, `Players` / `RunService` / `CollectionService`, `task`, and a **manually stepped** `Heartbeat` |
| `tests/shim/` fidelity | see below — three gaps found by mutation testing, each of which made a whole class of assertion unfalsifiable |
| `tests/shim/library.luau` | loads a library's real `src/init.luau` under that shim |

The manual `Heartbeat` is the point of the shim: tests drive time exactly, so interval, drift
and phase behaviour is **asserted** rather than sampled.

**Failure paths need to be drivable too.** `rbx.failDataStore(n)` makes the next n DataStore
writes throw the way the real service does. What a library does when a write does not land is
invisible against a stub that always succeeds — and driving it is what turned "Heatmap probably
loses data on a throttle" into a test, and then into a fix.

## How a library gets loaded

**One way: `shim/library.luau`.** It reads the library's real source and compiles it with the
shim injected as its environment, so every suite runs the file that ships. Nothing can drift.

Multi-file packages use `require(script.Parent.X)`, and `script` is a Roblox global that does
not exist under Lune. The loader resolves those itself — it reads the directory, extracts the
internal requires, and executes the modules in **dependency order**, so by the time a module
runs everything it asks for is already in the table. It also resolves a sibling *realm*
(`script.Parent.shared` from `src/server/init.luau`) on demand, so testing the server half
never drags in the client half.

Call it as `("Levelling", "server")` for a realm, `("Pathfinding", "PathAgent")` for one module,
or `("Bots")` for a package entry point.

**Do not reintroduce vendored copies.** Multi-file packages used to be duplicated under
`tests/vendor/` with the requires rewritten. That is gone, and the hazard it carried was never
hypothetical: a `Blackboard` fix landed in both the real file and its copy, and the mutant that
reverted *the copy* survived every archetype suite. A test passing against a duplicate proves
nothing about the file that ships. If a package will not load, fix the loader.

## Shim fidelity is load-bearing

Three gaps were found by mutation testing — each one a place where the shim disagreed with the
engine in a way that made assertions **pass no matter what the library did**. They are worth
knowing about, because the next one will look just as harmless:

| gap | what it hid |
|---|---|
| `Attachment` / `Part` held `CFrame` and `Position` as **independent** fields | they are one piece of storage in the engine. Slot attachments are positioned by writing `CFrame`, so every slot's `Position` stayed at the origin and every slot reported the same world point. Any assertion about *where* something sits agreed with everything. |
| assigning `.Parent` did **not** attach the child | setting `.Parent` *is* how a thing gets added. Nothing could see a library provision its own transport — the one thing the "own your transport" convention asks of them — leaving that path uncovered in three libraries. |
| signals keyed by function rather than an **array** | Luau caches closures with identical upvalues, so a set silently deduped double-`Connect`s that Roblox honours. |

The `.Parent` fix has a trap of its own worth recording: the parent is held under a **private**
key, because `__newindex` only fires for a key that is *absent*. Writing `Parent` onto the table
directly makes the first assignment work and every one after it silently skip the bookkeeping.

## A note on shim fidelity

The shim's `BindableEvent` passes arguments **by reference**; the real engine deep-copies tables
and strips metatables. That gap once let a real bug pass its tests — see *Why the events are not
BindableEvents* in `Zone/README.md`. Where a claim depends on engine behaviour the shim cannot
reproduce, verify it in Studio rather than trusting a green run here.
