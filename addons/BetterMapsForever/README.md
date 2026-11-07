# BetterMapsForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). It lets you
move, scale and fade Blizzard's own world map window, **Map & Quest Log** (`WorldMapFrame`), and
does nothing else. It needs no other addon or library, and it is not part of the Gaar suite.

## What it does

- **Move.** Drag the title bar of the windowed map. An invisible handle sits over the title strip
  and stops short of the maximize and close buttons, so those still work. The position is saved
  account-wide in `BetterMapsForeverDB`, in UIParent units, and put back every time the map
  opens and every time Blizzard's panel layout re-anchors it. It is kept on screen.
- **Resize.** Drag the grip in the bottom-right corner. It changes the frame's **scale**, not its
  width and height, so the whole window (map, pins, overlays and the quest log) grows and shrinks
  together, from 50% to 150%. The top-left corner stays where it is while you drag, and the
  corner follows the cursor. Releasing the grip saves the scale and the top-left corner, so the
  map opens exactly there next time. This is GaarMap's approach: the map is a canvas with its own
  pins, and scaling moves all of it together where resizing would leave the contents laid out for
  the old size.
- **Fade while moving** (on by default). While your character moves, the map drops to a lower
  opacity (35% by default), and it comes back to full opacity once you stand still. This is
  GaarMap's fade: a check ten times a second, `IsPlayerMoving()` first (it answers as a plain
  boolean), `GetUnitSpeed("player")` only where that is missing (it can be a secret number on this
  client), and the map is left alone when neither can answer. One difference: closing the map
  while it is faded puts it back to full opacity, so it never opens faded while you stand still.
  While the mouse cursor is over the map window (including its quest log panel) the map stays at
  full opacity even while you move, and it fades again when the cursor leaves.
  The fade works in both windowed and maximized mode, and in combat (it is only `SetAlpha`).
- **Lock.** No moving and no resizing; the grip and the title-bar handle are hidden.
- **Reset.** Blizzard's default position and 100% scale.
- **Combat.** The map is never moved or scaled in combat. Dragging the title bar or the grip
  prints a short message instead, a drag that is still going when combat starts ends there, and
  anything that would move or scale the map (opening it, Blizzard re-anchoring it, `/bmf scale`,
  `/bmf reset`) waits for `PLAYER_REGEN_ENABLED`. Opening the map in combat is Blizzard's own
  path and keeps working; it opens at Blizzard's anchor and moves to your position once combat
  ends.
- **Maximized map.** Left to Blizzard: no handle, no grip, 100% scale. Going back to the windowed
  map puts the saved position and scale back.

At 100% and the default position the addon does not touch the map at all.

## Commands

| Command | Does |
|---|---|
| `/bmf` | Help |
| `/bmf lock`, `/bmf unlock` | Stop or allow moving and resizing (hides or shows the grip and the handle) |
| `/bmf reset` | Back to Blizzard's default position and 100% scale |
| `/bmf scale <50-150>` | Set the scale in percent. On the open, windowed map the top-left corner stays put (and is saved) |
| `/bmf fade on`, `/bmf fade off` | Fade the map while you move, or not |
| `/bmf fade <10-100>` | Opacity while moving, in percent (default 35) |
| `/bmf status` | Which frames and functions this client has, whether the map is open and maximized, and the current settings |

## With BetterGaarForever (optional)

[BetterGaarForever](../BetterGaarForever/README.md) is an optional hub: one minimap button whose
menu has a **Maps** submenu with **Lock position & size**, **Reset position & size**, **Scale**
(75, 90, 100, 110, 125%), **Fade while moving** and **Fade opacity** (25, 35, 50, 75%), the same
settings as `/bmf lock|unlock`, `/bmf reset`, `/bmf scale`, `/bmf fade on|off` and `/bmf fade
<percent>` (both go through the same functions). This addon has no minimap button or menu of its
own, so nothing here changes with or without the hub.

The hub talks to this addon only through `BetterMapsForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `unlocked · 100% · default position · fade 35%` |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, submenu }`, `{ divider }`), for a menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description (`CreateCheckbox`, `CreateRadio`, submenus via `CreateButton`) |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide. It is there so every addon the hub knows has the same API |

## How it stays out of the way

- Blizzard code is only followed, never replaced: `HookScript` on the map's `OnShow` and `OnHide`,
  `hooksecurefunc(WorldMapFrame, "Maximize" | "Minimize" | "SynchronizeDisplayState")` and
  `hooksecurefunc("UpdateUIPanelPositions")`. No Blizzard function or table is written, and
  `SetAttribute` is never called on a Blizzard frame.
- The map is moved with `StartMoving` from its own handle, then anchored by the addon; the client's
  own copy of the position (`SetUserPlaced`) is switched off again, so the only saved position is
  the addon's.
- Because Blizzard's panel layout can re-anchor the map at moments no hook sees, the addon also
  checks once a frame after the map opens and then every 0.1 s while it is open (only out of
  combat, and only when it manages the map) whether the anchor or the scale has been put back,
  and re-applies them.
- Blizzard's last anchor is remembered, so `/bmf reset` can put it back on the open map.
- Every name is checked before use, and secret geometry is treated as no geometry.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Only `locked`, `scale`,
  `position`, `fade` and `fadeAlpha` are kept.

## Known limit: the cursor on a scaled map

Blizzard's map works out the point under the cursor against UIParent's scale, not the map's. Once
the map is scaled, the zone highlight on a continent map, a click that zooms into a zone, and
mouse-wheel zoom can land a little off from the pointer; the further from 100%, the more. Pins,
the quest log and buttons are normal frames and are not affected. GaarMap and Mapster correct it
by replacing `WorldMapFrame.ScrollContainer.GetCursorPosition`, which writes a Blizzard table.
This addon does not do that, so the correction is not here.

## GaarMap

GaarMap also scales and fades the world map. With both loaded they fight over the same frame, so
BetterMapsForever says so at login and in `/bmf status`. Use one of the two.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source), `Blizzard_WorldMap` and
`UIParent.lua`): `WorldMapFrame` (its `BorderFrame` with `TitleContainer`,
`MaximizeMinimizeFrame` and `CloseButton`, and `IsMaximized`, `Maximize`, `Minimize`,
`SynchronizeDisplayState` from `WorldMapMixin`), `UpdateUIPanelPositions`, `IsPlayerMoving`,
`GetUnitSpeed`, `InCombatLockdown` and the size-grabber textures
`Interface\ChatFrame\UI-ChatIM-SizeGrabber-*`. It ships a `_Camelot` TOC and a plain fallback
TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).
