# Nametags

## Overview

Server-side overhead nametags for Roblox, coloured so you can tell friend from foe
at a glance. For every player character it:

- hides the default overhead username (`Humanoid.NameDisplayDistance = 0`) while
  keeping the default health bar,
- attaches a `BillboardGui` "Nametag" to the character's `Head` showing the player's
  `DisplayName`,
- hides that label from the owning player (`BillboardGui.PlayerToHideFrom`), so you
  only ever see other players' tags,
- colours the label per team, and re-colours it live when the player's `Team`
  changes.

Handles players already present at start as well as those who join later, and
players who respawn (`CharacterAdded`).

## Files

- `src/init.luau` — the entire library (single self-contained module, `--!strict`).

## Dependencies

None. Uses only the `Players` service. No Wally packages, no cross-package requires.

## Configuration / Injection API

Call `Nametags.start(config?)` once on the server. `config` is optional; every field
is optional and defaults to the original hardcoded value, so `Nametags.start()` with
no arguments reproduces the original behaviour exactly.

```lua
export type Config = {
	Font: Enum.Font?,                          -- default Enum.Font.GothamBold
	Size: UDim2?,                              -- default UDim2.fromOffset(200, 40)
	StudsOffset: Vector3?,                     -- default Vector3.new(0, 2.8, 0)
	MaxDistance: number?,                      -- default 150
	NeutralColor: Color3?,                     -- default Color3.fromRGB(220, 220, 220)
	ColorResolver: ((player: Player) -> Color3?)?, -- default nil
}
```

- `Size` is the `BillboardGui` size in offset pixels. The label uses `TextScaled`,
  so this box is what drives the on-screen text size (there is no separate `TextSize`).
- `NeutralColor` is used only when a player has no `Team` and no resolver colour applies.
- `ColorResolver` lets games without Roblox Teams provide their own colour:
  - if provided and it returns a `Color3`, that colour is used;
  - if it returns `nil`, the library falls back to the Team-based path;
  - if it is not provided at all, the Team-based path is used directly.
  - The Team-based path returns `player.Team.TeamColor.Color`, or `NeutralColor`
    when the player has no team.

Config is applied inside `start`; call `start` before you need the tags active.

## Usage example

Team-based colouring (original behaviour):

```lua
local Nametags = require(path.to.Nametags)
Nametags.start()
```

With custom style and a resolver for a game without Roblox Teams:

```lua
local Nametags = require(path.to.Nametags)

Nametags.start({
	Font = Enum.Font.FredokaOne,
	Size = UDim2.fromOffset(240, 48),
	StudsOffset = Vector3.new(0, 3.2, 0),
	MaxDistance = 200,
	NeutralColor = Color3.fromRGB(200, 200, 200),
	ColorResolver = function(player)
		-- e.g. look up your own faction/party system
		return MyFactions.getColor(player) -- may return nil to fall back
	end,
})
```

Note: because colours are only re-evaluated on `Team` change and on respawn, a
resolver whose result changes for other reasons won't push a live update on its own.
Trigger a respawn (or, if you expose one, add a manual refresh) to re-apply.

## Changes from CastleWars original

Source: `src/server/Systems/Nametags/init.luau` in CastleWars. Logic and behaviour
are preserved; the only changes are the decoupling points below.

1. **Style constants are now configurable.** `Font`, `Size` (BillboardGui size /
   scaled text size), `StudsOffset`, `MaxDistance`, and the neutral/fallback colour
   were hardcoded; they are now optional `Config` fields, each defaulting to the
   original value. `start()` gained an optional `config` parameter.
2. **Optional `ColorResolver` callback.** Added a `(player) -> Color3?` override so
   games without Roblox Teams can supply colours. When absent (or returning `nil`),
   the existing `player.Team.TeamColor` path is used unchanged, followed by the
   neutral colour when there is no team.

Not changed / not exposed (kept hardcoded to match the original): the label
`TextStrokeTransparency` (0.4), `TextScaled = true`, `BackgroundTransparency = 1`,
the `"Nametag"` gui name, and `NameDisplayDistance = 0`. These weren't part of the
requested decoupling.
