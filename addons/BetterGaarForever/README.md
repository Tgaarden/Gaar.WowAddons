# BetterGaarForever

An optional hub for the WoW Forever client (`_forever_`, interface 16001): one minimap button
whose menu holds the options of all nine Better...Forever addons:
[BetterBagsForever](../BetterBagsForever/README.md),
[BetterQuestsForever](../BetterQuestsForever/README.md),
[BetterMapsForever](../BetterMapsForever/README.md),
[BetterCastbarsForever](../BetterCastbarsForever/README.md),
[BetterPlatesForever](../BetterPlatesForever/README.md),
[BetterGpsForever](../BetterGpsForever/README.md),
[BetterFramesForever](../BetterFramesForever/README.md),
[BetterWindowsForever](../BetterWindowsForever/README.md) and
[BetterFishingForever](../BetterFishingForever/README.md). It needs no other addon or library, and
it is not part of the Gaar suite.

It carries no bag, quest, map, cast bar, nameplate, waypoint, unit-frame, window or fishing code of its own. The addons stay fully independent: their logic,
their settings (`BetterBagsForeverDB`, `BetterQuestsForeverDB`, `BetterMapsForeverDB` and so on) and their
slash commands (`/bbf`, `/bqf`, `/bmf`, `/bcf`, `/bpf`, `/bgps`, `/bff`, `/bwf`, `/bfish`) stay in their own addon, and without the hub they behave
exactly as they do on their own. Install the hub next to them if you want one button instead of one
per addon.

## Install

Put the `BetterGaarForever` folder in `Interface/AddOns`, next to any of `BetterBagsForever`,
`BetterQuestsForever`, `BetterMapsForever`, `BetterCastbarsForever`, `BetterPlatesForever`, `BetterGpsForever`, `BetterFramesForever`, `BetterWindowsForever` and `BetterFishingForever`. Any of them can be missing: its entry in the menu
then says so.

## Minimap button

One button (`BetterGaarForeverMinimapButton`), with the placement code of BetterQuestsForever and
GaarVanguard: on the rim of the minimap (half its width plus 5), or on the edge of a square
minimap (`GetMinimapShape() == "SQUARE"`), dragged around it, angle saved, 285 degrees by default
(clear of GaarOptions at 205 and GaarVanguard at 245). The tooltip shows each addon's state line.
A click opens:

- **Bags**: BetterBagsForever's options (Lock position, Reset position, Reverse, Hide Blizzard's
  own Clean Up button, and since BetterBagsForever 1.7 Item counts in tooltip).
- **Quests**: BetterQuestsForever's options (Enabled, Max quests shown, Sort by, Completed quests,
  Backdrop, Backdrop opacity, Hide in combat).
- **Maps**: BetterMapsForever's options (Lock position & size, Reset position & size, Scale
  75/90/100/110/125%, Fade while moving, Fade opacity 25/35/50/75%).
- **Castbars**: BetterCastbarsForever's options (Lock position & size, Test bars, Bars, Follow
  Blizzard (Edit Mode), Latency safe-zone, Texture, Font size, Timer, Reset positions).
- **Plates**: BetterPlatesForever's options (Enabled, Colour mode, Health text, Size, the
  friendly / threat / execute / debuffs / target-of-target / dim / target-scale toggles, Reset to
  defaults).
- **GPS**: BetterGpsForever's options (Show arrow, Lock arrow, Reset arrow position, Clear
  waypoint; the last is a grey line that cannot be clicked while there is no waypoint). The
  tooltip line is the waypoint, its distance and the time to get there, or `no waypoint`.
- **Frames**: BetterFramesForever's options (Lock, Test mode, Frames with a checkbox per frame,
  Portrait 2D / 3D, Bar text, Low-health colour, Class colour, Reset positions & scales). The
  tooltip line is e.g. `locked · 6 frames · 2D`.
- **Windows**: BetterWindowsForever's options (a checkbox per Blizzard window this client has,
  Reset one window, Reset all positions & scales). The tooltip line is e.g.
  `26 of 26 windows on · 3 moved`.
- **Fishing**: BetterFishingForever's options (Double right-click casts Fishing, Double-click
  window 0.2-0.8 s, Fishing route). The tooltip line is e.g. `on · 0.40 s · pole equipped`, plus
  `· route 152/225` while the route is on.
- **Hide minimap button** (`/bgf minimap` brings it back).

Each submenu is filled by the addon itself, through its API, so it always has that addon's current
options. An addon that is not installed or not enabled shows a disabled
`BetterBagsForever – not installed` (or `BetterQuestsForever – not installed`,
`BetterMapsForever – not installed`, and so on) line instead; one
that is loaded but older than its API says to update it.

The menu is Blizzard's `MenuUtil` where the client has it, otherwise a small menu drawn by the
addon with the submenus as indented headings (never `UIDropDownMenu`).
`BetterGaarForever_PlaceMinimapButton()` re-places the button, for an addon that changes the
minimap's shape.

## One button, not several

While the hub is loaded, BetterQuestsForever's own minimap button is hidden (BetterBagsForever and
BetterMapsForever, BetterCastbarsForever, BetterPlatesForever, BetterGpsForever, BetterFramesForever, BetterWindowsForever and BetterFishingForever have none). That is for the session only: the addon's saved minimap setting is never changed, so
without the hub its button is back as you left it. It holds whatever the load order:

- the TOC lists all nine addons under `## OptionalDeps`, so they load first;
- at `PLAYER_LOGIN` the hub calls `SetMinimapHidden(true)` on each addon's API;
- BetterQuestsForever also checks `C_AddOns.IsAddOnLoaded("BetterGaarForever")` (or the older
  `IsAddOnLoaded`) itself before it shows its button.

## The API it uses

Each addon exports a small global table, `BetterBagsForeverAPI`, `BetterQuestsForeverAPI`,
`BetterMapsForeverAPI`, `BetterCastbarsForeverAPI`, `BetterPlatesForeverAPI`, `BetterGpsForeverAPI`,
`BetterFramesForeverAPI`, `BetterWindowsForeverAPI` and `BetterFishingForeverAPI`:

| Field | What it is |
|---|---|
| `version` | The addon's version, a string |
| `StatusLine()` | One short line of state, for the tooltip and `/bgf status` |
| `MenuEntries()` | The options as plain data, for the menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Hides (or shows again) the addon's own minimap button for this session only |

BetterQuestsForever's own menu and its API build on the same list of options, so they cannot
drift apart.

## Commands

| Command | Does |
|---|---|
| `/bgf` | Help |
| `/bgf status` | The hub's version, and each addon's version and state line, or `not installed` |
| `/bgf minimap`, `/bgf minimap reset` | Show or hide the minimap button; back to its default place (285 degrees) and shown |

`/bbf`, `/bqf`, `/bmf`, `/bcf`, `/bpf`, `/bgps` (and `/way`), `/bff`, `/bwf` and `/bfish` belong to the addons themselves, as always.

## Saved variables

`BetterGaarForeverDB`, read at `ADDON_LOADED`, never at file scope:

```
minimap = { hide = false, angle = 285 }
```

Anything else is dropped on load, including 1.0's `bags`, `quests`, `modules` and `migrated`.

## 2.7

The **Fishing** submenu gains a **Fishing route** checkbox (BetterFishingForever 1.2's Fishing
1-300 route, the same as `/bfish route on|off`). It comes from `BetterFishingForeverAPI.MenuEntries`
like the other Fishing options, so the hub's code is unchanged apart from the version.

## 2.6

Adds the **Fishing** submenu for BetterFishingForever 1.0 (through `BetterFishingForeverAPI`, the
same code path as the others), lists it under `## OptionalDeps`, in `/bgf` help and in
`/bgf status`. Nothing else changed.

## 2.5

Adds the **Windows** submenu for BetterWindowsForever 1.0 (through `BetterWindowsForeverAPI`, the
same code path as the others), lists it under `## OptionalDeps`, in `/bgf` help and in
`/bgf status`. Nothing else changed.

## 2.4

Adds the **Frames** submenu for BetterFramesForever 1.0 (through `BetterFramesForeverAPI`, the
same code path as the others), lists it under `## OptionalDeps`, in `/bgf` help and in
`/bgf status`. Nothing else changed.

## 2.3

Adds the **GPS** submenu for BetterGpsForever 1.0 (through `BetterGpsForeverAPI`, the same code
path as the others), lists it under `## OptionalDeps`, in `/bgf` help and in `/bgf status`.
Nothing else changed.

## 2.2

Adds the **Castbars** and **Plates** submenus for BetterCastbarsForever and BetterPlatesForever
(through `BetterCastbarsForeverAPI` and `BetterPlatesForeverAPI`, the same code path as the
others), lists them under `## OptionalDeps` and in `/bgf status`.

## 2.1

Adds the **Maps** submenu for BetterMapsForever 1.0 (through `BetterMapsForeverAPI`, the same code
path as Bags and Quests), lists it under `## OptionalDeps` and in `/bgf status`. Nothing else
changed.

## From 1.0

1.0 carried copies of both addons as modules, with its own copy of their settings. 2.0 is only the
hub: the modules, the settings import and the pause-when-both-are-loaded logic are gone, and so
are the `/bbf` and `/bqf` aliases. Your settings are the ones in `BetterBagsForeverDB` and
`BetterQuestsForeverDB`, so keep (or re-enable) both addons next to the hub. Settings changed only
inside 1.0 are not carried back.

## Layout

```
BetterGaarForever.toc, BetterGaarForever_Camelot.toc   both at 16001, same file list
Core.lua            saved variables, minimap button and menu, /bgf
```

## License

MIT, see [LICENSE](LICENSE).
