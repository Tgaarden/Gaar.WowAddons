# BetterForever

The hub of the Better...Forever family for the WoW Forever client (`_forever_`, interface 16001).
Until 2.8 it was called **BetterGaarForever**; 3.0 renamed it and made it the one addon every
family member depends on. It holds three things:

- **The shared library** (`Lib.lua`, global `BetterForever`): small helpers the addons used to copy
  into every file - secret-safe values, guarded API calls, a per-feature "switched off this
  session" latch, chat output, saved-variable defaults, an option registry that gives an addon its
  slash commands, menu entries and Options page from one list, and a few formatters. See
  [For addon authors](#for-addon-authors).
- **Options pages** (`Settings.lua`): **Esc > Options > AddOns > Better Forever**, with an overview
  page and one page per installed addon, generated from the same data as the minimap menu.
- **One minimap button** (`Core.lua`) whose menu has a submenu per addon, and `/bf`.

The family: [BetterBagsForever](../BetterBagsForever/README.md),
[BetterQuestsForever](../BetterQuestsForever/README.md),
[BetterMapsForever](../BetterMapsForever/README.md),
[BetterCastbarsForever](../BetterCastbarsForever/README.md),
[BetterPlatesForever](../BetterPlatesForever/README.md),
[BetterGpsForever](../BetterGpsForever/README.md),
[BetterFramesForever](../BetterFramesForever/README.md),
[BetterWindowsForever](../BetterWindowsForever/README.md),
[BetterFishingForever](../BetterFishingForever/README.md),
[BetterBuffsForever](../BetterBuffsForever/README.md),
[BetterMerchantForever](../BetterMerchantForever/README.md),
[BetterTooltipsForever](../BetterTooltipsForever/README.md),
[BetterMailForever](../BetterMailForever/README.md),
[BetterXPForever](../BetterXPForever/README.md),
[BetterChatForever](../BetterChatForever/README.md) and
[BetterBarsForever](../BetterBarsForever/README.md). It is not part of the Gaar suite.

The hub carries no bag, quest, map, cast bar, nameplate, waypoint, unit-frame, window, fishing,
buff, merchant, tooltip, mail, XP, chat or action-bar code of its own. Each addon keeps its logic,
its settings (`BetterBagsForeverDB`, `BetterQuestsForeverDB` and so on) and its slash command.

## Install

Put the `BetterForever` folder in `Interface/AddOns`, next to the Better...Forever addons you use.
Every one of them lists `## Dependencies: BetterForever`, so the client loads none of them without
it. Any of the addons can be missing: its menu entry then says so and it gets no Options page.

### Coming from BetterGaarForever

Delete (or disable) the old `BetterGaarForever` folder; BetterForever says so in chat if it finds
it loaded. **Your addons' settings are kept**: each lives in that addon's own saved variable,
which the rename does not touch. **The hub's own two settings reset** (the minimap button's
position and whether it is hidden): the client reads saved variables by addon name, from
`WTF/Account/<account>/SavedVariables/<AddonName>.lua`, so the renamed addon never sees
`BetterGaarForever.lua`, and listing `BetterGaarForeverDB` in the new TOC would not read that file
either. Carrying it over would need the old folder to stay installed as a stub, which is the very
thing the rename removes; for two settings that are back with one drag, it is not worth it.

## Options pages

**Esc > Options > AddOns > Better Forever** (or `/bf options`):

- **Better Forever** (the overview): what the family is, a checkbox for the hub's minimap button,
  and every addon's version, slash command and state line (or `not installed`), refreshed each
  time the page opens.
- **One page per installed addon** (`/bf options bags`, `/bf options quests`, ...): the addon's
  intro at the top (from `Intro()` in its API: what it does, key features, nice to know), its
  slash command and state line, then its options. The options are generated from the addon's own
  `MenuEntries()`, the same data the minimap menu draws, so the two always match:

| `MenuEntries()` entry | On the Options page |
|---|---|
| `{ text, checkbox = true, checked, func }` | A checkbox. It reads `checked()`; a click calls `func()` when the new state differs |
| A submenu whose entries are all radios | A dropdown named after the submenu (a trailing `: <current choice>` is dropped, as in BetterBuffsForever's `Warrior: Might`) |
| Radios in a row, outside a submenu | A dropdown; when they share a prefix (`Timer: Total`, `Timer: Remain`) it becomes the name |
| `{ text, func }` | A button row: the text on the left, its first word (`Reset`, `Clear`, `Sell`) on the button |
| `{ divider = true }` | A small gap between groups |
| A submenu of anything else | A section header with the submenu's text, then its entries (nested as deep as they go) |
| `{ label = "..." }` | A grey line of text |
| `{ text, slider = true, min, max, step, value, set, format }` (new in 3.0) | A slider |

The page is rebuilt from `MenuEntries()` every time it is shown, after a button, and after any
change that alters its shape (an entry appearing, disappearing or being renamed), so it always
shows the live state.

How they are built: each page is a canvas category (`Settings.RegisterCanvasLayoutCategory` /
`RegisterCanvasLayoutSubcategory`, then `Settings.RegisterAddOnCategory`) that holds its own copy
of Blizzard's settings list (`SettingsListTemplate`), filled with Blizzard's own row initializers
(`Settings.CreateCheckboxInitializer`, `CreateDropdownInitializer`, `CreateSliderInitializer`,
`CreateSettingsButtonInitializer`, `CreateSettingsListSectionHeaderInitializer`), so the rows look
and work like the game's. Two deliberate choices:

- **A canvas, not a vertical-layout category.** The settings search walks every vertical-layout
  category's rows outside `securecallfunction`; rows an addon made there taint the search, and after
  a search the keybinding rows run tainted (`SetBinding` then fails in combat). Canvas categories
  are not searched.
- **Unregistered proxy settings** (made from `ProxySettingMixin`; `Settings.RegisterProxySetting`
  only where the mixin is missing), so the panel's *Defaults* button never flips these options.

The text rows (intro, state, grey lines) use a small template of the hub's own
(`BetterForeverSettingsTextRowTemplate`, in `BetterForever.xml`). If anything above is missing on a
client, or fails, the page is drawn by hand instead (check buttons, buttons, one line per choice);
`/bf status` says how many pages that applies to. Without any Settings API the old
`InterfaceOptions_AddCategory` is tried, and without that there are no pages - the minimap menu and
slash commands work as before.

## Minimap button

One button (`BetterForeverMinimapButton`), with the placement code of BetterQuestsForever and
GaarVanguard: on the rim of the minimap (half its width plus 5), or on the edge of a square
minimap (`GetMinimapShape() == "SQUARE"`), dragged around it, angle saved, 285 degrees by default
(clear of GaarOptions at 205 and GaarVanguard at 245). The tooltip shows each addon's state line.
A click opens a submenu per addon - **Bags**, **Quests**, **Maps**, **Castbars**, **Plates**,
**GPS**, **Frames**, **Windows**, **Fishing**, **Buffs**, **Merchant**, **Tooltips**, **Mail**,
**XP**, **Chat** and **Bars** - each filled by the addon itself through its API, then
**Hide minimap button** (`/bf minimap` brings it back). An addon that is not installed shows a
disabled `BetterBagsForever – not installed` line instead; one that is loaded but older than its
API says to update it.

The menu is Blizzard's `MenuUtil` where the client has it, otherwise a small menu drawn by the
addon with the submenus as indented headings (never `UIDropDownMenu`).
`BetterForever_PlaceMinimapButton()` (also under its old name,
`BetterGaarForever_PlaceMinimapButton()`) re-places the button, for an addon that changes the
minimap's shape.

While the hub is loaded, BetterQuestsForever's own minimap button is hidden (the others have
none). That is for the session only: the addon's saved minimap setting is never changed. The
addons load after the hub (they depend on it), so at `PLAYER_LOGIN` the hub calls
`SetMinimapHidden(true)` on each addon's API; an addon loaded later is handled at its
`ADDON_LOADED`. BetterQuestsForever also checks for the hub itself.

## The API each addon exports

`BetterBagsForeverAPI`, `BetterQuestsForeverAPI`, ... `BetterBarsForeverAPI`:

| Field | What it is |
|---|---|
| `version` | The addon's version, a string |
| `StatusLine()` | One short line of state, for the tooltip, the overview page and `/bf status` |
| `MenuEntries()` | The options as plain data (see the table above), for the fallback menu and the Options page |
| `AddMenuEntries(root)` | Adds the options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Hides (or shows again) the addon's own minimap button for this session only |
| `Intro()` (3.0) | A short intro, shown at the top of the addon's Options page (a string field `intro` works too) |

The hub's own API is `BetterForeverAPI` (`BetterGaarForeverAPI` is the same table under the old
name): `version`, `ADDONS` (the list above), `PlaceMinimapButton()`, `OpenOptions([key])`,
`SetMinimapHidden(hidden)`.

## Commands

| Command | Does |
|---|---|
| `/bf` (also `/betterforever`, and `/bgf` from before 3.0) | Help |
| `/bf status` | The hub's and the library's version, each addon's version and state line (or `not installed`), the minimap button and the Options pages |
| `/bf options [name]` | Opens the Options pages, or one addon's page (`bags`, `quests`, `maps`, ..., the addon's name or its slash command) |
| `/bf minimap`, `/bf minimap reset` | Show or hide the minimap button; back to its default place (285 degrees) and shown |

`/bbf`, `/bqf`, `/bmf`, `/bcf`, `/bpf`, `/bgps` (and `/way`), `/bff`, `/bwf`, `/bfish`, `/bbuff`,
`/bmerch`, `/btip`, `/bmail`, `/bxp`, `/bchat` and `/bbars` belong to the addons themselves.

## Saved variables

`BetterForeverDB`, read at `ADDON_LOADED`, never at file scope:

```
minimap = { hide = false, angle = 285 }
```

Anything else is dropped on load.

## For addon authors

`Lib.lua` defines the global `BetterForever` before any family addon runs (they all depend on the
hub). Phase 1 (3.0) only adds the library; the addons still carry their own copies of these
helpers, and moving them over is the next step (see the recipe below).

### Values

The client hands back **secret** values where it hides something: they may be passed to a widget,
but comparing, testing or doing arithmetic on one is refused. Check before anything else.

| Helper | Returns |
|---|---|
| `BetterForever.IsSecret(v)` | `true` for a secret value (`false` where the client has no `issecretvalue`) |
| `BetterForever.Plain(v)` | `v`, or `nil` when it is secret |
| `BetterForever.Num(v)` | A plain, finite number, else `nil` |
| `BetterForever.Str(v)` | A plain, non-empty string, else `nil` |
| `BetterForever.Bool(v)` | `true` / `false`, or `nil` when it is secret |

### Calls

| Helper | Does |
|---|---|
| `BetterForever.API(ns, name)` | The function `_G[ns][name]`, or `_G[ns]` when `name` is nil; `nil` when it is not a function |
| `BetterForever.Call(fn, ...)` | `fn(...)` in `pcall`: its results, or nothing when `fn` is missing or errors |
| `BetterForever.Method(obj, name, ...)` | `obj:name(...)` the same way |
| `BetterForever.AddOnLoaded(name)` | `C_AddOns.IsAddOnLoaded`, or the old global |
| `BetterForever.InCombat()` | `InCombatLockdown()`, `false` where it is missing |

### Text

| Helper | Gives |
|---|---|
| `BetterForever.OnOff(v)` | `"on"` / `"off"` |
| `BetterForever.TimeShort(s)` | `"56"`, `"2m"`, `"1h"`, `"3d"`, rounded up (aura times, cooldown numbers); `""` for 0, nil or secret |
| `BetterForever.Clock(s)` | `"4:05"`, `"1:02:03"`; `"--"` for nil or secret |
| `BetterForever.Coins(copper)` | `"1g 2s 3c"`, only the parts that are there, `"0c"` for nothing |
| `BetterForever.ShortNumber(n)` | `"950"`, `"12.3k"`, `"1.2M"` |

### Menus

| Helper | Does |
|---|---|
| `BetterForever.RenderMenu(root, entries)` | Draws `MenuEntries()` data into a `MenuUtil` description (checkbox, radio, submenu, label, divider, button; a slider as a submenu of its steps) - the `RenderMenu` every addon carries a copy of |
| `BetterForever.IntroOf(api)` | An API table's intro (`Intro()` or `intro`), or `nil` |
| `BetterForever.Options.Rows(entries)` | The rows an Options page makes of `MenuEntries()` data, for checking a new shape with `/dump` |

### An addon object

```lua
local A = BetterForever.NewAddon("BetterExampleForever", {
    version = "1.0",
    intro = "What it does in one or two sentences. Nice to know: ...",
    status = function() return "on · 3 things" end,   -- optional: the state line
    help = { "/bex frob - frobnicate now" },          -- optional: extra help lines
})
```

| Method | Does |
|---|---|
| `A:Print(...)` | One chat line with the family prefix, `\|cff33ff99<Name>\|r: `, the arguments joined by spaces |
| `A:InitDB(globalName, defaults)` | Binds the saved variable (call it at `ADDON_LOADED`): creates the table, fills missing keys from `defaults` (nested tables too, copied) and from every option's default; returns it, also as `A.db` |
| `A:Toggle(key, label, default, onChange, opts)` | A checkbox stored in `db[key]`: `/x <key> on\|off` (no value toggles), a menu checkbox and an Options-page checkbox. `opts.cmd` renames the command word. The key `enabled` is the master switch: `/x on`, `/x off` |
| `A:Choice(key, label, values, default, onChange, opts)` | One of `values` (`{ "a", "b" }` or `{ { value = "a", label = "A" } }`): `/x <key> <value>`, a submenu of radios, a dropdown |
| `A:Slider(key, label, min, max, step, default, onChange, format, opts)` | A number: `/x <key> <n>` (clamped, snapped to the step), a submenu of steps in the menu, a slider on the Options page |
| `A:Button(label, func, opts)` | A button; with `opts.cmd`, `/x <cmd>` runs it too |
| `A:Divider()` | A gap in the menu and on the page |
| `A:Get(key)`, `A:Set(key, value)` | Read (the default while unset); write, checked against the option's kind, then `onChange(value)` in `pcall` |
| `A:MenuEntries()` | The options as `MenuEntries()` data |
| `A:Slash({ "/x", "/longname" }, handlers)` | Registers the commands (`SlashCmdList[<NAME>]`, the same key the addons use today). `handlers[word] = function(rest, msg)` run first; built in: `help` (the intro, one line per option, the extra help lines), `status`, `on\|off`, and one command per option |
| `A:Run(feature, fn, ...)` | `fn(...)` in `pcall`; the first error switches that feature off for the session with one chat line (BetterPlatesForever's `Run`), later calls return at once. `A:IsBlocked(feature)`, `A:Latch(feature, err)` |
| `A:On(event, handler)` | Registers an event on the addon's own frame; `handler(event, ...)` runs in `pcall`, the last error kept in `A.lastError` |
| `A:API(extra)` | Builds and exports `_G[<name> .. "API"]`: `version`, `StatusLine`, `MenuEntries`, `AddMenuEntries`, `SetMinimapHidden` (does nothing), `Intro`, plus `extra` |

### Migrating an addon (phase 2)

One addon at a time, behaviour unchanged, `tools/check.sh` clean after each:

1. **Helpers.** Replace the file's own `Secret`/`IsSecret`, `Plain`, `Num`, `Str`, `Bool`, `Call`,
   `API`, `AddOnLoaded`, `InCombat`, `OnOff` and time/coin formatters with locals bound to the
   library: `local BF = BetterForever; local Plain, Num = BF.Plain, BF.Num`. Watch the small
   differences: some addons' `Num` lets infinity through, `Call` variants return `ok, ...` instead
   of the results, `Secret(a, b)` takes two values.
2. **Print.** `local A = BF.NewAddon(ADDON_NAME, { version = VERSION, intro = INTRO })`, then
   `local function Print(msg) A:Print(msg) end` (or call `A:Print` directly).
3. **Run latch.** Replace the file's `blocked` / `Latch` / `Run` with `A:Run(feature, fn, ...)`;
   keep the addon's own clean-up per feature in the caller if it had one (`CLEAR[feature]`).
4. **Settings.** In `ADDON_LOADED`, `db = A:InitDB("BetterXForeverDB", DEFAULTS)`; keep the
   addon's own clean-up of old keys after it.
5. **Options.** Turn each on/off feature into `A:Toggle(...)` (and choices into `A:Choice`), with the
   existing setter as `onChange`, so the slash commands, the menu and the Options page come from
   one list. Keep hand-written slash commands as `handlers`.
6. **API.** Replace the hand-built `_G.BetterXForeverAPI = { ... }` and its `RenderMenu` copy with
   `A:API({ StatusLine = StatusLine })` (or `BF.RenderMenu` inside the existing table). The API's
   shape stays the same, so the hub needs no change.
7. Bump the version, run `tools/check.sh`, and check `/x`, `/x status`, the minimap submenu and
   the Options page in game.

## 3.0

- Renamed from **BetterGaarForever**: folder, TOCs (`BetterForever.toc`,
  `BetterForever_Camelot.toc`), saved variable `BetterForeverDB`, frames
  (`BetterForeverMinimapButton`, `BetterForeverMinimapMenu`), `/bf` and `/betterforever`.
  `/bgf`, `BetterGaarForever_PlaceMinimapButton` and `BetterGaarForeverAPI` stay as aliases.
  The minimap button's position resets once (see [Coming from BetterGaarForever](#coming-from-bettergaarforever)).
- Every Better...Forever addon now requires it (`## Dependencies: BetterForever`), so the hub no
  longer lists them under `## OptionalDeps`: they load after it, and their API is there at
  `PLAYER_LOGIN` as before.
- The shared library, `BetterForever` (`Lib.lua`).
- The Options pages under **Esc > Options > AddOns > Better Forever** (`Settings.lua`,
  `BetterForever.xml`), with an intro per addon from the new `Intro()` API field; `/bf options`.
- Rows for the six newer addons: **Merchant** (`BetterMerchantForever`), **Tooltips**
  (`BetterTooltipsForever`), **Mail** (`BetterMailForever`), **XP** (`BetterXPForever`), **Chat**
  (`BetterChatForever`) and **Bars** (`BetterBarsForever`).
- The fallback menu shows a slider entry as a line with its value.

## 2.8

Adds the **Buffs** submenu for BetterBuffsForever 1.0 (through `BetterBuffsForeverAPI`, the
same code path as the others), lists it under `## OptionalDeps`, in `/bgf` help and in
`/bgf status`. Nothing else changed.

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
BetterForever.toc, BetterForever_Camelot.toc   both at 16001, same file list
Lib.lua             the shared library, global BetterForever
Settings.lua        the Options pages (Esc > Options > AddOns > Better Forever)
BetterForever.xml   the text-row template the Options pages use
Core.lua            saved variables, minimap button and menu, /bf
```

## License

MIT, see [LICENSE](LICENSE).
