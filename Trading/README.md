# Trading

Two players agreeing to swap things. The **conversation** is here; what may be swapped, and
the swap itself, are yours.

## The shape

```
invite   → the target gets an invite and can accept or decline
respond  → accept opens a session for both, decline tells the inviter
offer    → replaces your side of the table, and CLEARS BOTH READY FLAGS
ready    → agrees to what is on the table right now; both agreeing starts a countdown
cancel   → either side, at any time, with no penalty
```

Every one of those is a server-held fact, and the clients are told what the server believes
after each move. **There is no state on a client that the server did not push**, because the
alternative is two screens quietly disagreeing about what is being traded.

## Setup

```lua
local Trading = require(path.to.Trading.server)

Trading.start({
    -- How many of that line the player has, right now.
    availableOf = function(player, line)
        return Companions.available(player, line.id, line.level or 1)
    end,

    -- THE SWAP. One call, atomic, re-validating. See below.
    swap = function(a, aLines, b, bLines)
        return Inventory.swap(a, aLines, b, bLines)
    end,

    -- Optional
    maxLines = 9, inviteSeconds = 30, inviteCooldown = 3, completeSeconds = 3,
    moveBurst = 6, moveRate = 4,
    canTrade = function(player) return nil end,
})
```

## Lines

A line is a **stack, not an item** — a board shows cells, and `maxLines` caps cells rather
than things. With no `readLine` supplied, a line is:

```lua
{ id = "Knight", level = 3, quantity = 2 }   -- two level-3 Knights
{ id = "Coin", quantity = 500 }              -- level is optional and means 1
```

`level` is in the default rather than left to a custom reader because a collectible with a
rank is the ordinary case here: a level 1 and a level 3 of the same thing stack, price and
merge apart, so they must not pool. A game with no ranks simply omits it.

**Identity is derived on the server and never sent.** The key is built from the line's own
fields (`id@level`), which is why this is a *reader* rather than a `key` field on the line: a
client cannot name an identity that disagrees with what it is actually offering, because it
never names one at all. Give a line a `key` and a crafted payload can claim three different
identities for three copies of the same thing, and the totalling below stops working.

Supply `readLine` when identity is something else — a durability band, an enchant, a foil
flag:

```lua
readLine = function(line)
    return { key = `{line.id}/{line.enchant}`, quantity = line.quantity }
end
```

`Trading.readDefaultLine` is exported, so a custom reader can wrap it rather than
reimplement it.

## Three rules that make it safe

**Any offer change clears both ready flags.** Otherwise the oldest trick in the genre works:
wait for the other player to ready up, swap your legendary for a common, and let their
earlier agreement carry the trade through. *A ready flag that outlives the offer it agreed
to is not consent to anything.*

**Lines are totalled by key before being compared.** Two lines naming the same thing each
pass a per-line check — one is fewer than the two you own, twice — while together they are
three of something there are two of. That is why a line is *read* into a key rather than
merely validated.

**`swap` is one call, and it must re-validate.** One call and not remove-then-give: two calls
open a window where an item exists twice or not at all, and that window is where trade
duplication bugs live. It is called *seconds* after the offers were checked, and anything can
happen in them — an item merged away, spent, traded in another window — so it is expected to
check again. This module never assumes its earlier validation still holds.

A refused swap **drops both agreements and leaves the session open** rather than retrying:
whatever changed underneath means the table they agreed to is not the one in front of them
any more, and re-running it would commit to something neither of them looked at.

## Hardening

Four things this module does that a straightforward implementation would not.

**The cap and the loop count the same thing.** `#lines` measures only the array part of a
table, while generalized iteration walks *every* key — so a payload of one array entry plus
fifty string-keyed ones has a length of 1, sails past a cap of nine, and hands fifty-one
lines to the loop. Measured on the in-game version: cap 2, length 1, **51 lines
processed**. Offers are now read with a numeric loop, so anything hung off a non-numeric key
is ignored rather than trusted.

**Every host callback fails closed.** `readLine`, `availableOf`, `canTrade` and `swap` are
all yours, so all of them can throw. A throwing `availableOf` means *"we could not find out
how many you have"*, which is not *"you have enough"*; a throwing `canTrade` means the answer
is unknown, which must not read as allowed for the one check standing between a player and a
trade they may be barred from.

**A throwing `swap` cannot wedge a session.** It is called from inside a spawned countdown,
so an unguarded throw would kill that coroutine and leave the session open forever — showing
a count that never resolves and agreements that never clear. A throw is treated exactly as a
refusal, which is the honest reading: nothing is known to have moved.

**A repeated `ready` is not a move.** Without that, holding the button restarts the countdown
on every press — a trade that never completes, plus a broadcast to both clients each time.

**The action remote is rate limited**, per player, as a token bucket: `moveBurst` moves may
land back-to-back (default 6), refilling at `moveRate` a second (default 4). A bucket rather
than a minimum interval, because the two failure modes differ — dragging four items onto the
board in half a second is a burst and is legitimate, while sending offers at sixty a second
forever is not, and a flat interval refuses the first to bound the second.

Over-budget moves are **dropped in silence**. Answering each unwanted packet with a packet is
the amplification the limit exists to prevent. The check runs *before* dispatch and before any
validation, so a flood costs one table lookup rather than a walk through somebody's inventory.

**`start` is idempotent.** Its remote handler and player connections are additive, so a second
call would handle every move twice — two broadcasts per offer, two countdowns per ready.

## The countdown is a last look

The pause between both sides agreeing and the swap happening is not a delay for its own sake.
Committing on the frame the second ready lands means the last thing either player saw was the
board — and the one moment a trade is worth double-checking is the moment it becomes
irreversible.

**Un-readying during the count stops it**, because it clears the agreement the count is
running on. The count is guarded by a **token** rather than a boolean: ready → not ready →
ready inside the window would otherwise let the first count wake up and commit against an
agreement that had been taken back and given again — swapping twice.

## Who may trade: `Trading.shared`

```lua
local Access = require(path.to.Trading.shared)

Access.set(player, "InMatch")   -- blocked, with a reason key
Access.set(player, nil)         -- lifted
Access.reasonFor(player)        -- "InMatch" | nil, readable from either realm
```

**One fact, published on the Player, read by both realms.** The server has to refuse and the
client has to say why — a Trade button that greys out with no explanation is the version of
this that generates "the game is broken" reports.

It is an **attribute**, not a child value: every client reads it about every *other* player
the moment a trade list is drawn, and `GetAttributeChangedSignal` exists whether or not the
attribute has ever been set. A `StringValue` would put a `ChildAdded` race in every reader,
for nothing.

**Set it from whatever owns the state that causes it.** A match, a cutscene, a cooldown, a
restricted account — the system that knows when each starts and ends writes here, and this
module refuses without being told a new rule exists. It is **watched**, not polled: a player
who becomes unable to trade takes their trade with them, and the blocking system never has to
know a trade existed.

Store a **key**, not a sentence. `"InMatch"`, not `"Playing a match"` — the client maps it,
in whatever language.

## Client

```lua
local Client = require(path.to.Trading.client)

Client.onInvited(function(from) end)
Client.onState(function(state) end)     -- the whole session, every change
Client.onNotice(function(reason, who) end)
Client.onClosed(function(reason) end)

Client.invite(userId)   -- by USER ID: the server resolves it against players in THIS server,
                        -- which is the whole trust boundary for who may be traded with
Client.respond(true)
Client.offer(lines)     -- replaces your whole side, never "adds a line"
Client.setReady(true)
Client.cancel()
```

`Reason` is `Busy | Blocked | PartnerBlocked | SelfInvite | NotFound | Cooldown | NoInvite |
TooManyLines | BadLine | NotEnough | Declined | Cancelled | PartnerLeft | Unavailable |
Failed | Complete`, exported so a host can map them all and fail its own build when a new one
appears.

A `RemoteEvent` copies tables, so the lines a screen receives are copies with any metatable
gone. Draw them; don't expect them to be the objects the server holds.

## From game system to package

Started in a game where it traded companions. Changes:

1. **`readLine`, `availableOf` and `swap` are injected** rather than reaching into the game's
   persistence, its companion content and its loadout server.
2. **Copy is gone** — refusals are reason keys, and the table of English strings stayed
   behind.
3. **Sessions are in-memory and per-server, unchanged.** A trade cannot survive a rejoin and
   should not: nothing is held in escrow, so an abandoned session costs nobody anything.

Tests, all headless: `test-trading.luau` (72 — the session machine, crafted payloads,
throwing host callbacks, flood behaviour), `test-trading-lines.luau` (23 — the default line
shape end to end) and `test-trading-client.luau` (22 — remote discovery, the dispatch table,
what each call puts on the wire).
