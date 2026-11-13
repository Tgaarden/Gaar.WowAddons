# BetterGpsForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001): one
TomTom-style waypoint with an arrow, the distance and the time to get there, a world map pin and a
minimap pin. It needs BetterForever, the family hub, and no other addon or library, and it is not part of the Gaar suite.

## What it does

- **One waypoint.** A new one replaces the old.
- **`/way`.** `/way x y`, `/way x,y` or `/way x, y` sets it in the zone you are in
  (`C_Map.GetBestMapForUnit("player")`). `/way <zone> x y` sets it in that zone. x comes first,
  then y, both 0-100, decimals with a dot. `/way` alone shows the waypoint and the usage,
  `/way clear` removes it, anything else prints the usage line.
- **Zone names** are matched case-insensitively against every zone and continent map under the
  top of your map tree (`C_Map.GetMapChildrenInfo`): an exact name first, then a unique prefix,
  then a unique part of the name. `/way barr 45 63` is The Barrens. When several zones match, they
  are listed and nothing is set. Maps that share a name (a city's floors) count as one.
- **Alt + left-click (Option on Mac) on the world map** (windowed or maximized) sets it at the point under the
  cursor on the map shown. Blizzard's own click still happens (a click on a continent still zooms
  into the zone); the point is taken at mouse down, before that, and set at mouse up if the cursor
  has not moved, so an alt-drag sets nothing.
- **Arrow.** A frame on screen that turns towards the waypoint, with the distance in yards under
  it, the time to get there under that, and the zone and coordinates at the bottom. It turns
  green while you face the waypoint. Drag it to move it (unless locked), right-click it to clear
  the waypoint. Its place is saved. In an instance, or wherever the client gives no position, it
  says `no position here`; on another continent, `on another continent`.
- **Time to get there.** From how fast the distance has shrunk over the last 3 seconds: the
  distance left divided by that closing speed, as `m:ss`, or `h:mm:ss` from an hour up. While you
  stand still, move away, or have no position, it shows `--`.
- **World map pin.** A small gold marker on the waypoint's own map, and on any other map that
  holds it (the continent map, a parent or child zone), converted through the world position.
  It keeps one size at every zoom.
- **Minimap pin.** The same marker on the minimap, placed from the yards between you and the
  waypoint against the minimap's view radius (`C_Minimap.GetViewRadius`, or the zoom level where
  that is missing), turned with the minimap when `rotateMinimap` is on, square or round. Beyond
  the edge it sits on the edge, a little faded.
- **Blizzard's own waypoint.** Where the client allows it on that map
  (`C_Map.CanSetUserWaypointOnMap`), Blizzard's user waypoint is set too
  (`C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(...))`) and super-tracked
  (`C_SuperTrack.SetSuperTrackedUserWaypoint(true)`). Clearing ours clears it only while it is
  still the one we set; one you placed yourself afterwards is left alone.
- **Arrival.** Within 10 yards the waypoint clears itself, with `Arrived at <zone> x, y.` in chat.
- **Corpse route** (1.1, default on, `/bgps corpse on|off`). Once you have released and are a
  ghost, the waypoint is your corpse, titled **Corpse**: `C_DeathInfo.GetCorpseMapPosition` on
  your map, or on the first parent map that holds it (then narrowed to the zone it lies in with
  `C_Map.GetMapInfoAtPosition`). It is read again on every map change (graveyard, zone change,
  loading screen) and every 2 seconds while you are dead, so it follows you and appears as soon
  as the client knows the corpse. It does not clear itself when you reach the corpse; it stays
  until you are resurrected. The waypoint you had before is kept aside and comes back
  automatically after resurrection (at your corpse, at a spirit healer, or by another player),
  with its title; with no waypoint before, there is none after. The rules:
  - A waypoint you set yourself while dead (`/way`, Alt-click, another addon) replaces the
    corpse route and is the one kept after resurrection; the corpse route does not come back
    until the next death.
  - Clearing the corpse waypoint (right-click the arrow, `/way clear`) ends the route; the
    waypoint from before comes back at once.
  - `/bgps corpse off` while the route runs ends it the same way.
  - The state is saved, so a `/reload` or a relog while dead keeps the waypoint to bring back.
- **Waypoints from other addons.** `BetterGpsForeverAPI.SetWaypoint(uiMapID, x, y, title)` sets
  the one waypoint with a title of its own (BetterQuestsForever 1.6 uses it for "Set GPS target"
  in the quest tracker's menu, titled with the quest's name); the title is shown on the arrow,
  in `/way`, `/bgps status` and the arrival line instead of the zone name. `/way` itself is
  unchanged.
- **Saved** account-wide in `BetterGpsForeverDB`, so it survives `/reload` and logging out.

Not in 1.1: more than one waypoint, a queue, routes, importing, and the arrow inside instances.

## Commands

| Command | Does |
|---|---|
| `/bgps` | Help |
| `/way x y`, `/way x,y`, `/way <zone> x y` | Set the waypoint (0-100, x first) |
| `/way`, `/way clear` | Show the waypoint and the usage; clear it |
| `/bgps way ...` | The same as `/way ...`, always there (the one to use with TomTom) |
| `/bgps arrow on`, `/bgps arrow off` | Show the arrow or not (the pins stay) |
| `/bgps lock`, `/bgps unlock` | Stop or allow dragging the arrow |
| `/bgps reset` | Arrow back to its default place |
| `/bgps clear` | Clear the waypoint (or right-click the arrow) |
| `/bgps corpse on`, `/bgps corpse off` | Waypoint to your corpse while you are a ghost, the old one back after resurrection (default on) |
| `/bgps status` | The waypoint, the arrow settings, the corpse route, who owns `/way`, which map functions this client has, and anything switched off |

`/bettergpsforever` is the long form of `/bgps`.

## TomTom

When TomTom is loaded (or any other addon already answers `/way`), BetterGpsForever does not
register `/way`, so TomTom's keeps working. It says so once at login, `/bgps way x y` does the same
job, and `/bgps status` shows who owns `/way`. The check runs at `PLAYER_LOGIN`, when every addon
has loaded.

## With BetterForever (required)

Since 1.2.1 this addon lists `BetterForever` under `## Dependencies`: install the `BetterForever` folder next to it, or the client will not load this addon. BetterForever also gives it a page under **Esc > Options > AddOns > Better Forever**, built from the same `MenuEntries()` as the hub's menu, with a short intro at the top; that intro comes from `Intro()`, a field the API table gained in 1.2.1 (it is also the first line of the slash command's help).

Since 1.2.2 the small helpers (the chat prefix, secret-value and number checks, safe client
calls, the time text and the menu drawing) come from BetterForever's shared library
(`BetterForever`, `Lib.lua`) instead of a copy in this addon. Nothing you see changed.

[BetterForever](../BetterForever/README.md) 2.3 and later has a **GPS** submenu with
**Show arrow**, **Lock arrow**, **Reset arrow position**, **Route to corpse when dead** (1.1) and
**Clear waypoint** (a grey line that cannot be clicked while there is no waypoint), the same as
`/bgps arrow on|off`, `/bgps lock|unlock`, `/bgps reset`, `/bgps corpse on|off` and `/bgps
clear`. This addon has no minimap button of its own.

The hub talks to this addon only through `BetterGpsForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `The Barrens 45.2, 63.1 · 312 yd · 1:24` or `no waypoint` |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ label }`), for a menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide |
| `SetWaypoint(uiMapID, x, y [, title])` | 1.1. Sets the one waypoint (`x`, `y` 0-1) with an optional title (one line, at most 60 characters) shown instead of the zone name; `true` when it was set. Like `/way`, it replaces the waypoint there was, and while dead it replaces the corpse route |
| `ClearWaypoint()` | 1.1. Clears the waypoint, as `/way clear` does |
| `GetWaypoint()` | 1.1. `uiMapID, x, y, title` of the waypoint, or `nil` |

## How the numbers are worked out

- **Distance and direction.** The waypoint and the player (`C_Map.GetPlayerMapPosition`) are both
  turned into a continent and a world position with `C_Map.GetWorldPosFromMapPos`, so the two can
  be on different maps (a zone and its city, a zone and its continent). World x grows to the
  north and y to the west; the distance is the straight line between them in yards, and the
  bearing, counter-clockwise from north, is `atan2(dy, dx)`. `GetPlayerFacing()` counts the same
  way, so the arrow's rotation is the bearing minus the facing. On different continents there is
  no distance.
- **World map pin.** Our own frame, a child of the map canvas (`WorldMapFrame:GetCanvas()`, i.e.
  `ScrollContainer.Child`), anchored at `x * width, -y * height` from its top-left corner, sized
  `16 / zoom` so it stays 16 pixels at any zoom. On another map the point comes from
  `C_Map.GetMapPosFromWorldPos(continent, worldPos, shownMap)`. It is placed again when Blizzard
  changes the map (`hooksecurefunc(WorldMapFrame, "OnMapChanged")`) and checked every 0.1 s while
  the map is open.
- **Alt-click.** `GetCursorPosition()` divided by the canvas's own effective scale, minus the
  canvas's left and top, over its width and height. Blizzard's helper divides by UIParent's scale
  instead, which is off once the map frame is scaled (BetterMapsForever's known limit); this is
  right at any scale and zoom.
- **Minimap pin.** The yards east and north, turned by the facing when the minimap rotates,
  divided by the view radius and multiplied by half the minimap's width.

## How it stays out of the way

- Blizzard code is only followed, never replaced: `HookScript("OnMouseDown" | "OnMouseUp")` on
  `WorldMapFrame.ScrollContainer` and `hooksecurefunc(WorldMapFrame, "OnMapChanged")`. No Blizzard
  function or table is written (no data provider, no pin pool). The pins and the arrow are the
  addon's own frames.
- Every read of the API goes through `pcall` and is checked for its type and with `issecretvalue`
  before any arithmetic or comparison; a missing, failing or secret answer counts as no answer.
- Each part (arrow, world map pin, minimap pin, Blizzard's waypoint, alt-click) runs in
  `pcall`; the first error switches that part off for the session with one line in chat, and the
  rest keeps going. Nothing it does is protected, so nothing changes in combat.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Only `waypoint`
  (`mapID`, `x`, `y`, `label`, `corpse`), `arrow`, `locked`, `arrowPos`, `corpse` and
  `corpseRun` (`prev`, `done`) are kept, each type-checked.
- The corpse route reads `UnitIsGhost("player")` and `UnitIsDeadOrGhost("player")`; a missing,
  failing or secret answer changes nothing. It listens to `PLAYER_DEAD`, `PLAYER_ALIVE`,
  `PLAYER_UNGHOST`, `PLAYER_ENTERING_WORLD`, `ZONE_CHANGED_NEW_AREA`, `ZONE_CHANGED` and
  `ZONE_CHANGED_INDOORS` (each registered on its own, so an unknown event is skipped), and polls
  every 2 seconds only while dead.

## Names it relies on

Present in the Forever binary (build of 2026-11-07): `C_Map.GetBestMapForUnit`,
`GetPlayerMapPosition`, `GetWorldPosFromMapPos`, `GetMapPosFromWorldPos`, `GetMapInfo`,
`GetMapChildrenInfo`, `CanSetUserWaypointOnMap`, `SetUserWaypoint`, `GetUserWaypoint`,
`HasUserWaypoint`, `ClearUserWaypoint`, `C_SuperTrack.SetSuperTrackedUserWaypoint`,
`C_Minimap.GetViewRadius`, `GetPlayerFacing` and the `rotateMinimap` CVar; for the corpse route
(1.1) `C_DeathInfo.GetCorpseMapPosition`, `C_Map.GetMapInfoAtPosition`, `UnitIsGhost`,
`UnitIsDeadOrGhost` and the `PLAYER_DEAD`, `PLAYER_ALIVE` and `PLAYER_UNGHOST` events. From Blizzard's
FrameXML: `WorldMapFrame` (`GetCanvas`, `GetMapID`, `ScrollContainer`, `OnMapChanged`),
`CreateVector2D`, `UiMapPoint`. The arrow is the built-in `Interface\Minimap\MinimapArrow`; the
pins are drawn from plain textures. Every one is checked before use. It ships a `_Camelot` TOC
and a plain fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).
