# CommunityReward

Verify that a player belongs to a Roblox group, then pay them **once, ever**.

`CommunityReward.start(config)` on the server: it provisions its own remotes, builds a
`ProximityPrompt` on whatever wears a configured tag, and on claim checks live group
membership, checks a one-time flag on the player's profile, and calls the reward you supplied.

## Overview

- **The client proves nothing.** The claim remote carries no arguments at all — no amount, no
  membership proof, no reward name. There is nothing on the way in to forge.
- **Live membership, not `Player:IsInGroup`.** `IsInGroup` is cached when the player joins the
  *server*, so someone who joins the group and claims in the same session would be refused and
  told to rejoin — which is the very flow this feature walks them through.
- **The membership check is three-valued** — `true` / `false` / `nil` for a failed lookup — and
  injectable, so it can be replaced or tested without a network.
- **Ships no copy.** Refusals come back as reason *keys*, never sentences.
- **Self-contained.** No Wally packages, no external requires. Uses `CollectionService`,
  `GroupService`, `Players`, `ProximityPromptService` and `ReplicatedStorage`.

## Files

| File | Purpose |
|---|---|
| `src/server/init.luau` | Claim flow, prompt binding, transport. |
| `src/client/init.luau` | Transport only — no window, no copy. |

Tests: `test-community-reward.luau` (51 — the claim flow) and
`test-community-reward-client.luau` (18 — its transport). Headless, no Studio.

## Server API

```lua
local CommunityReward = require(path.to.CommunityReward.server)

CommunityReward.start({
    groupId = 362693839,

    -- Persistence. nil means "not loaded" (still joining, or already left).
    document = function(player) return Profiles.get(player) end,

    -- The reward. The only thing the two games this came from disagreed about.
    grant = function(player) Inventory.give(player, "EliteKnight") end,

    -- Optional
    claimedField = "communityRewardClaimed",        -- default
    rewardReady = function() return Content.has("EliteKnight") end,
    onClaimed = function(player) mirrorBool(player, "CommunityRewardClaimed", true) end,
    isInGroup = function(player, groupId) ... end,   -- defaults to GroupService
    promptTag = "CommunityReward",
    promptActionText = "Claim",
    promptObjectText = "Community Reward",
    promptDistance = 12,
})
```

- **`CommunityReward.claim(player) -> ClaimResult`** — verifies and pays. Public so an admin
  command shares this exact path rather than growing a second, subtly different one.
- **`CommunityReward.hasClaimed(player) -> boolean?`** — `nil` when the profile is not loaded, so
  a caller can tell "no" from "cannot say yet".
- **`CommunityReward.claimedField() -> string`**
- **`CommunityReward.configure(config)`** — the seams without any transport, for a claim path that
  needs no remotes.

`ClaimResult` is `{ ok: boolean, reason: Reason? }`. `Reason` is
`AlreadyClaimed | Unavailable | NotInGroup | NotReady | Failed`, exported so a host can map all
of them and fail its own build when a new one appears.

## Client API

```lua
local Client = require(path.to.CommunityReward.client)

Client.onOpenRequested(function() window:open() end)   -- the lobby prompt was triggered
Client.onResult(function(ok, reason) window:setStatus(ok, MESSAGES[reason]) end)
Client.claim()                                          -- carries nothing
```

The answer arrives through `onResult`, never as a return value: the server yields on a
membership lookup, and a call that looked synchronous would be a lie.

## The order of the checks is the design

Cheap and local first, then anything that could make the reward ungrantable, and only then the
yielding web call. The property that falls out: **every way this can refuse leaves the claim
still there to be made.**

1. in-flight guard → 2. profile loaded → 3. not already claimed → 4. `groupId` set →
5. `rewardReady` → 6. **membership lookup (yields)** → 7. re-read profile → 8. re-check flag →
9. **write the flag** → 10. `grant` → 11. `onClaimed`

**Why the flag is written before the grant.** A failure between them leaves a player marked as
paid who was not — fixable by hand. The other order leaves an unmarked player who can claim
again, which nobody can take back. `rewardReady` exists so the *predictable* version of that
failure — a reward id that does not exist — is caught at step 5, before the flag.

**What actually makes it pay once** is steps 7–9 being one synchronous block. There is no yield
between the re-read and the write, and coroutines only switch on a yield, so no second claim can
observe an unflagged profile once the first has got that far. The in-flight guard is *not* what
closes that window — removing it in a mutation test still paid exactly once. It earns its place
by not spending a second rate-limited `GetGroupsAsync` on a double-click, and by refusing the
second click immediately rather than after a round trip.

That second click comes back `Failed`, which reads as "try again" — and a retry then correctly
reports `AlreadyClaimed`. Vague on its own, coherent in sequence.

**`groupId = 0` disables the whole feature**, refusing every claim as `Unavailable` and warning
once at start. That is the safe failure: an unset id must never reward everybody, and a *guessed*
id would pay this game's players for joining somebody else's community.

## The lobby prop: a tag is the whole setup

Everything wearing `promptTag` gets a prompt built on it — now, and whenever one arrives: tagged
after start, streamed back in, or the art landing for the first time. A `Part` is its own anchor;
a `Model` gets its `PrimaryPart`, or any descendant part. Under `StreamingEnabled` a model
routinely replicates before its children, so a missing anchor is polled for up to 10 seconds
before the prop is reported as unusable.

Nothing is torn down when a tag is removed. An untagged prop keeps its prompt until it is
destroyed — a prompt with no handler does nothing, while chasing prompts across re-tags would be
bookkeeping for a case that only happens while somebody is editing the place.

Omit `promptTag` to skip prompt handling entirely and open your window from your own UI.

## From game system to package

Started in the CA game, which had ported it from RottenTomato. **The two games differed only
in what the reward was** — one paid gold, the other handed over a companion — so that became the
`grant` seam, and everything else here is what was identical in both.

Changes from the CA version:

1. **`grant`, `document`, `rewardReady`, `onClaimed` and `isInGroup` are injected** rather than
   requiring the game's persistence layer, its combat server, and its companion content.
2. **`isInGroup` is a seam.** The original called `GroupService` directly, which made the whole
   claim flow untestable and would force any game with its own social graph to fork.
3. **Copy is gone.** The original config mixed mechanism (`GROUP_ID`, `PROMPT_TAG`) with window
   copy (`TITLE`, `STEP_LIKE`, `RESULT_MESSAGES`). Only the mechanism is here; two games will
   word the same flow differently, and a package that ships strings forces either English or a
   localisation dependency.
4. **`grant` and `onClaimed` run under `xpcall`.** A throwing grant used to take the remote
   handler down with it. Now it warns that the player is flagged and unpaid — the one state that
   needs a human — and the claim still reports success, because from the player's side it did.
5. **`rewardReady` replaces a hardcoded content lookup.** The original checked its companion
   table by hand at exactly the right point in the order; that ordering is preserved and the
   check is now the host's to define.
6. **The in-flight guard's rationale is corrected.** The original claimed it was what stopped the
   reward paying twice. Mutation testing showed otherwise — see above.

The original's `--!strict` pragmas are kept, and the files are `stylua`-clean.
