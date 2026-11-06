# BetterGaarForever

An optional hub for the WoW Forever client (`_forever_`, interface 16001): one minimap button
whose menu holds the options of [BetterBagsForever](../BetterBagsForever/README.md) (1.6) and
[BetterQuestsForever](../BetterQuestsForever/README.md) (1.5). It needs no other addon or library,
and it is not part of the Gaar suite.

It carries no bag or quest code of its own. Both addons stay fully independent: their logic, their
settings (`BetterBagsForeverDB`, `BetterQuestsForeverDB`) and their slash commands (`/bbf`,
`/bqf`) stay in their own addon, and without the hub they behave exactly as they do on their own.
Install the hub next to them if you want one button instead of one per addon.

## Install

Put the `BetterGaarForever` folder in `Interface/AddOns`, next to `BetterBagsForever` and/or
`BetterQuestsForever`. Either of the two can be missing: its entry in the menu then says so.

## Minimap button

One button (`BetterGaarForeverMinimapButton`), with the placement code of BetterQuestsForever and
GaarVanguard: on the rim of the minimap (half its width plus 5), or on the edge of a square
minimap (`GetMinimapShape() == "SQUARE"`), dragged around it, angle saved, 285 degrees by default
(clear of GaarOptions at 205 and GaarVanguard at 245). The tooltip shows each addon's state line.
A click opens:

- **Bags**: BetterBagsForever's options (Lock position, Reset position, Reverse, Hide Blizzard's
  own Clean Up button).
- **Quests**: BetterQuestsForever's options (Enabled, Max quests shown, Sort by, Completed quests,
  Backdrop, Backdrop opacity, Hide in combat).
- **Hide minimap button** (`/bgf minimap` brings it back).

Each submenu is filled by the addon itself, through its API, so it always has that addon's current
options. An addon that is not installed or not enabled shows a disabled
`BetterBagsForever – not installed` (or `BetterQuestsForever – not installed`) line instead; one
that is loaded but older than its API says to update it.

The menu is Blizzard's `MenuUtil` where the client has it, otherwise a small menu drawn by the
addon with the submenus as indented headings (never `UIDropDownMenu`).
`BetterGaarForever_PlaceMinimapButton()` re-places the button, for an addon that changes the
minimap's shape.

## One button, not three

While the hub is loaded, BetterQuestsForever's own minimap button is hidden (BetterBagsForever has
none). That is for the session only: the addon's saved minimap setting is never changed, so
without the hub its button is back as you left it. It holds whatever the load order:

- the TOC lists both addons under `## OptionalDeps`, so they load first;
- at `PLAYER_LOGIN` the hub calls `SetMinimapHidden(true)` on each addon's API;
- BetterQuestsForever also checks `C_AddOns.IsAddOnLoaded("BetterGaarForever")` (or the older
  `IsAddOnLoaded`) itself before it shows its button.

## The API it uses

Each addon exports a small global table, `BetterBagsForeverAPI` and `BetterQuestsForeverAPI`:

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

`/bbf` and `/bqf` belong to the addons themselves, as always.

## Saved variables

`BetterGaarForeverDB`, read at `ADDON_LOADED`, never at file scope:

```
minimap = { hide = false, angle = 285 }
```

Anything else is dropped on load, including 1.0's `bags`, `quests`, `modules` and `migrated`.

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
