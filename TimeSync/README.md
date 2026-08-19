# TimeSync

Per-player round-trip latency measurement for Roblox.

## Overview

The server pings each connected client roughly once per second, carrying its own
`os.clock()` value. The client echoes that value back verbatim. The server then
computes `os.clock() - sent` and keeps a rolling average of the last few samples.
`getLatency(player)` returns that average, in seconds.

> **Note on the name:** despite being called "TimeSync", this library measures
> round-trip time / latency (RTT), **not** a wall-clock offset between machines.
> Because the client only echoes the server's own clock value, no client/server
> clock synchronization is involved or required.

This library is self-contained and owns its network transport, so it works with
zero game infrastructure. It pairs with the **LagCompensation** library, which
consumes it as its latency provider (see below).

## Files

| File | Role |
|---|---|
| `src/server/init.luau` | Server module. Provisions transport, runs the ping loop, records samples, exposes `getLatency`. `--!strict`. |
| `src/client/init.luau` | Client module. Echoes each ping straight back on the owned transport. |

## Dependencies

**None.** Zero external dependencies. No `require` leaves the library folder. No
dependency on any game-wide remotes registry or boot ordering.

## Configuration / Injection API

### Server

```lua
local TimeSync = require(path.to.server)

-- Start the ping loop. Idempotent (a second call is a no-op).
TimeSync.start()                       -- self-provisioning default
TimeSync.start(config)                 -- optional injection / overrides

-- Average round-trip time for a player, in seconds.
local seconds = TimeSync.getLatency(player)
```

`Config` (all fields optional):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `pingRemote` | `RemoteEvent?` | self-provisioned | Server→client remote. Inject to skip self-provisioning. |
| `pingBackRemote` | `RemoteEvent?` | self-provisioned | Client→server remote. Must be given together with `pingRemote`. |
| `container` | `Instance?` | `ReplicatedStorage/TimeSyncRemotes` | Parent for self-provisioned remotes. |
| `pingInterval` | `number?` | `1` | Seconds between pings. |

Injected remotes may be either `RemoteEvent` or `UnreliableRemoteEvent` — both
work at runtime. The self-provisioned defaults are `UnreliableRemoteEvent`s.

### Client

```lua
local TimeSyncClient = require(path.to.client)

TimeSyncClient.start()          -- waits for the owned transport, then echoes
TimeSyncClient.start(config)    -- optional injection
```

Client `Config` accepts `pingRemote` / `pingBackRemote` / `container` with the
same meanings. The echo loop is deferred off the calling thread, so `start()`
returns immediately and never yields.

### Constants (server)

| Constant | Value | Meaning |
|---|---|---|
| `DEFAULT_PING_INTERVAL` | `1` s | Ping cadence (overridable via `config.pingInterval`). |
| `SAMPLE_COUNT` | `4` | Rolling samples averaged. |
| `DEFAULT_LATENCY` | `0.08` s | Assumed RTT before the first sample lands. |
| `MAX_SANE_LATENCY` | `1` s | Echoes implying a longer RTT are discarded. |

## Remote ownership

By default the **server** module provisions the transport on `start()`:

```
ReplicatedStorage/
  TimeSyncRemotes/            (Folder)
    Ping        (UnreliableRemoteEvent)  -- server -> client, carries send clock
    PingBack    (UnreliableRemoteEvent)  -- client -> server, echoes it back
```

Existing instances of the same name are reused; missing ones are created. The
**client** module `WaitForChild`s that same folder and remotes. UnreliableRemotes
match the fire-and-forget nature of latency pings (an occasional dropped sample
is harmless).

## Usage example

Server:

```lua
local TimeSync = require(ReplicatedStorage.Packages.TimeSync.server)
TimeSync.start()

-- later, e.g. inside LagCompensation wiring:
local rttSeconds = TimeSync.getLatency(player)
```

Client:

```lua
local TimeSyncClient = require(ReplicatedStorage.Packages.TimeSync.client)
TimeSyncClient.start()
```

### Pairing with LagCompensation

LagCompensation does not talk to this library directly; it takes a latency
callback. Wire `getLatency` in as that provider:

```lua
LagCompensation.start({
    getLatency = function(player)
        return TimeSync.getLatency(player) -- seconds
    end,
})
```

## Changes from the CastleWars original

Extracted from `src/server/Systems/TimeSync/init.luau` and
`src/client/Systems/TimeSync/init.luau`. The rolling-average logic, constants,
and RTT computation are unchanged. Differences:

1. **Owns its transport.** The original read
   `ReplicatedStorage.Remotes.PingEvent_RS` and `.PingBackEvent_RC`, which were
   created by the game's `RemotesData` boot step — a hidden dependency on boot
   ordering. The library now provisions its own `TimeSyncRemotes` folder with
   `Ping` / `PingBack` `UnreliableRemoteEvent`s (matching the original's
   unreliable registration), or accepts injected remotes via config.
2. **`getLatency` (renamed from `GetLatency`)** for a clean lowercase API. Same
   behavior and return value.
3. **Client exposes `start(config)`** instead of running its echo loop as a
   side effect of `require`, so injected config can be applied. The loop is
   still deferred off the calling thread as before.
4. **Idempotent `start()`** on both sides (guarded so a second call is a no-op).
5. **`config.pingInterval`** override added; defaults to the original `1`s.
