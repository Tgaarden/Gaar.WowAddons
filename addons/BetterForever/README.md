# GaarForever

> Formerly **BetterForever** (the Better...Forever family is now Gaar...Forever, 3.2). The
> folders on disk keep the old names (`BetterForever`, `BetterBagsForever`, ...) so settings carry
> over and installs keep working. The commands are now `/gf` (`/gaarforever`) and the g-commands
> of each addon; the old `/bf`, `/betterforever`, `/bgf` and every addon's old `/b...` command still
> work. CurseForge: https://www.curseforge.com/wow/addons/gaarforever

The hub of the Gaar...Forever family for the WoW Forever client (`_forever_`, interface 16001).
Until 2.8 it was called **BetterGaarForever**; 3.0 renamed it and made it the one addon every
family member depends on. It holds three things:

- **The shared library** (`Lib.lua`, global `BetterForever`): small helpers the addons used to copy
  into every file - secret-safe values, guarded API calls, a per-feature "switched off this
  session" latch, chat output, saved-variable defaults, an option registry that gives an addon its
  slash commands, menu entries and Options page from one list, and a few formatters. See
  [For addon authors](#for-addon-authors).
- **Options pages** (`Settings.lua`): **Esc > Options > AddOns > Gaar Forever**, with an overview
  page and one page per installed addon, generated from the same data as the minimap menu.
- **One minimap button** (`Core.lua`) whose menu has a submenu per addon, and `/gf`.
- **Tools** (`Tools.lua`, 3.1): a chat line per addon after an update saying what changed
  (`/gf news`), per-character settings and settings export / import for addons built on the
  library's settings (`/gf profile`, `/gf export`, `/gf import`), and an API self-test
  (`/gf selftest`) to copy and send.

The family: [GaarBagsForever](../BetterBagsForever/README.md),
[GaarQuestsForever](../BetterQuestsForever/README.md),
[GaarMapsForever](../BetterMapsForever/README.md),
[GaarCastbarsForever](../BetterCastbarsForever/README.md),
[GaarPlatesForever](../BetterPlatesForever/README.md),
[GaarGpsForever](../BetterGpsForever/README.md),
[GaarFramesForever](../BetterFramesForever/README.md),
[GaarWindowsForever](../BetterWindowsForever/README.md),
[GaarFishingForever](../BetterFishingForever/README.md),
[GaarBuffsForever](../BetterBuffsForever/README.md),
[GaarMerchantForever](../BetterMerchantForever/README.md),
[GaarTooltipsForever](../BetterTooltipsForever/README.md),
[GaarMailForever](../BetterMailForever/README.md),
[GaarXPForever](../BetterXPForever/README.md),
[GaarChatForever](../BetterChatForever/README.md),
[GaarBarsForever](../BetterBarsForever/README.md) and
[GaarLootForever](../BetterLootForever/README.md). It is not part of the Gaar suite.

The hub carries no bag, quest, map, cast bar, nameplate, waypoint, unit-frame, window, fishing,
buff, merchant, tooltip, mail, XP, chat or action-bar code of its own. Each addon keeps its logic,
its settings (`BetterBagsForeverDB`, `BetterQuestsForeverDB` and so on) and its slash command.

## Install

Put the `BetterForever` folder in `Interface/AddOns`, next to the Gaar...Forever addons you use.
Every one of them lists `## Dependencies: BetterForever`, so the client loads none of them without
it. Any of the addons can be missing: its menu entry then says so and it gets no Options page.

### Coming from BetterGaarForever

Delete (or disable) the old `BetterGaarForever` folder; GaarForever says so in chat if it finds
it loaded. **Your addons' settings are kept**: each lives in that addon's own saved variable,
which the rename does not touch. **The hub's own two settings reset** (the minimap button's
position and whether it is hidden): the client reads saved variables by addon name, from
`WTF/Account/<account>/SavedVariables/<AddonName>.lua`, so the renamed addon never sees
`BetterGaarForever.lua`, and listing `BetterGaarForeverDB` in the new TOC would not read that file
either. Carrying it over would need the old folder to stay installed as a stub, which is the very
thing the rename removes; for two settings that are back with one drag, it is not worth it.

## Options pages

**Esc > Options > AddOns > Gaar Forever** (or `/gf options`):

- **Gaar Forever** (the overview): what the family is, a checkbox for the hub's minimap button,
  and every addon's version, slash command and state line (or `not installed`), refreshed each
  time the page opens.
- **One page per installed addon** (`/gf options bags`, `/gf options quests`, ...): the addon's
  intro at the top (from `Intro()` in its API: what it does, key features, nice to know), its
  slash command and state line, then its options. The options are generated from the addon's own
  `MenuEntries()`, the same data the minimap menu draws, so the two always match:

| `MenuEntries()` entry | On the Options page |
|---|---|
| `{ text, checkbox = true, checked, func }` | A checkbox. It reads `checked()`; a click calls `func()` when the new state differs |
| A submenu whose entries are all radios | A dropdown named after the submenu (a trailing `: <current choice>` is dropped, as in GaarBuffsForever's `Warrior: Might`). A divider between the radios starts another dropdown, named by its radios' shared prefix or numbered |
| Radios in a row, outside a submenu | A dropdown; when they share a prefix (`Timer: Total`, `Timer: Remain`) it becomes the name |
| `{ text, func }` | A button row: the text on the left, its first word (`Reset`, `Clear`, `Sell`) on the button |
| `{ divider = true }` | A small gap between groups |
| A submenu of anything else | A section header with the submenu's text, then its entries (nested as deep as they go) |
| `{ label = "..." }` | A grey line of text |
| `{ text, slider = true, min, max, step, value, set, format }` (new in 3.0) | A slider |

The page is rebuilt from `MenuEntries()` every time it is shown, after a button, and after any
change that alters its shape (an entry appearing, disappearing or being renamed), so it always
shows the live state. Any other change rebuilds nothing: the intro and `Now:` lines take their new
text in place, and every control shows its current value again (an option that changes another
shows at once).

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
`/gf status` says how many pages that applies to. Without any Settings API the old
`InterfaceOptions_AddCategory` is tried, and without that there are no pages - the minimap menu and
slash commands work as before.

## Minimap button

One button (`BetterForeverMinimapButton`), with the placement code of GaarQuestsForever and
GaarVanguard: on the rim of the minimap (half its width plus 5), or on the edge of a square
minimap (`GetMinimapShape() == "SQUARE"`), dragged around it, angle saved, 285 degrees by default
(clear of GaarOptions at 205 and GaarVanguard at 245). The tooltip shows each addon's state line.
A click opens a submenu per addon - **Bags**, **Quests**, **Maps**, **Castbars**, **Plates**,
**GPS**, **Frames**, **Windows**, **Fishing**, **Buffs**, **Merchant**, **Tooltips**, **Mail**,
**XP**, **Chat**, **Bars** and **Loot** - each filled by the addon itself through its API, then
**Hide minimap button** (`/gf minimap` brings it back). An addon that is not installed shows a
disabled `GaarBagsForever – not installed` line instead; one that is loaded but older than its
API says to update it.

The menu is Blizzard's `MenuUtil` where the client has it, otherwise a small menu drawn by the
addon with the submenus as indented headings (never `UIDropDownMenu`).
`BetterForever_PlaceMinimapButton()` (also under its old name,
`BetterGaarForever_PlaceMinimapButton()`) re-places the button, for an addon that changes the
minimap's shape.

While the hub is loaded, GaarQuestsForever's own minimap button is hidden (the others have
none). That is for the session only: the addon's saved minimap setting is never changed. The
addons load after the hub (they depend on it), so at `PLAYER_LOGIN` the hub calls
`SetMinimapHidden(true)` on each addon's API; an addon loaded later is handled at its
`ADDON_LOADED`. GaarQuestsForever also checks for the hub itself.

## The API each addon exports

`BetterBagsForeverAPI`, `BetterQuestsForeverAPI`, ... `BetterLootForeverAPI`:

| Field | What it is |
|---|---|
| `version` | The addon's version, a string |
| `StatusLine()` | One short line of state, for the tooltip, the overview page and `/gf status` |
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
| `/gf` (also `/gaarforever`; the old `/bf`, `/betterforever`, and `/bgf` from before 3.0) | Help |
| `/gf status` | The hub's and the library's version, each addon's version and state line (or `not installed`), the minimap button and the Options pages |
| `/gf options [name]` | Opens the Options pages, or one addon's page (`bags`, `quests`, `maps`, ..., the addon's name or its slash command; an unknown name is answered with the list of names) |
| `/gf minimap`, `/gf minimap reset` | Show or hide the minimap button; back to its default place (285 degrees) and shown |
| `/gf news`, `/gf news on\|off` | Prints the last "what's new" block again; switches the lines at login (also a checkbox on the overview page) |
| `/gf profile` | Each covered addon and whether this character uses the shared settings or its own |
| `/gf profile char <addon\|all>` | This character gets its own copy of the addon's settings, seeded from the shared ones as they are now |
| `/gf profile shared <addon\|all>` | Back to the shared (account-wide) settings; the character's copy is dropped, the shared settings were never touched |
| `/gf export <addon>` | The settings in use as one string (`BF1:<Addon>:<check>:<base64>`) in a window, selected for Ctrl+C |
| `/gf import` | A window to paste such a string into; Import applies it to the addon it names |
| `/gf selftest`, `/gf selftest show` | Probes the client APIs the family relies on and shows the result in a window to copy; runs again at the next pull (or when combat ends) and compares; `show` reopens the last result |

## What's new

At login (a few seconds in) the hub compares every installed family addon's version - its API
table's `version`, else the TOC's `## Version` - with the one it saw last
(`BetterForeverDB.seen`), and prints one line per addon that is newer:

```
GaarForever: updated — GaarBuffsForever 1.5.1 → 1.6.0: <one-line note>
```

The note comes from the `CHANGES` table in `Tools.lua`, keyed by addon name and version, written
from the git history; a version that has no note there is announced without one. An addon
installed since the last login is announced as `new — <Name> <version>`. The very first login with
3.1 only records the versions. `/gf news` prints the last block again; `/gf news off` (or the
checkbox on the overview page) stops the lines, the versions are still recorded.

When you release a family addon, add its note to `CHANGES` in the hub (the addons themselves are
not touched for this).

## Profiles, export and import

These work for addons that keep their settings through the library (`A:InitDB` with options from
`A:Toggle` / `A:Choice` / `A:Slider`). Today that is **GaarLootForever**; the other addons keep
their own settings tables (`BetterBagsForeverDB`, ...) and are answered with "keeps its own
settings table". `/gf profile` lists what is covered on this client.

- **Saved data is unchanged.** The addon's saved variable stays its account-wide settings. A
  character that opts in (`/gf profile char loot`) gets a copy in the same saved variable, under
  `_perCharacter["Name - Realm"]`; on load the library binds `A.db` to that copy for that
  character and to the shared table for everyone else, so `A:Get` / `A:Set` work unchanged.
  Settings saved before 3.1 have no `_perCharacter` and are used exactly as before.
- A switch calls `onChange(value, key, old)` for every option whose value changes, so the addon
  applies it at once.
- **Export** writes the settings in use (not the other characters' copies). **Import** decodes
  the string by hand - base64, a checksum, then a small parser with limits on size (200 000
  characters), depth (12) and number of values (5000); the text is never run as code. Only keys
  that are options of that addon are taken, each through `A:Set` (a checkbox takes only a
  boolean, a slider only a number, a choice only one of its values); anything else is counted as
  left out.

## Self-test

`/gf selftest` calls, each in `pcall`, on `player`, `target` and `party1` where a unit applies:
`issecretvalue`, `C_UnitAuras.GetAuraDataByIndex`, `C_UnitAuras.GetUnitAuraInstanceIDs`,
`C_UnitAuras.GetAuraDispelTypeColor` (with the unit's first aura and a colour curve), `UnitAura`,
`UnitHealth` (plain and predicted), `UnitHealthMax`, `UnitGetIncomingHeals`, `UnitThreatSituation`,
`UnitDetailedThreatSituation`, `GetRaidTargetIndex`, `C_Spell.IsSpellInRange` and `IsSpellInRange`
(with a spell of the player's class), `UnitInRange`, `UnitIsConnected`, `GetWeaponEnchantInfo`,
which `C_LootHistory` functions exist, the `INTERACTTARGET` binding, the `SoftTargetInteract`
CVar, the `CustomAuraContainerTemplate` template and `CustomAuraContainerGroupDefaultOptions`.
Each answer is recorded as `ok (<value>)`, `nil`, `secret` (or `secret fields (n/m)` for a table,
`n more secret` for further return values), `missing`, `skip (<why>)` or `error: <message>` -
a secret value is only ever passed to `issecretvalue`, never compared or printed.

It runs once at once and once more on the other side of the next combat change (at the next pull
after an out-of-combat run), then prints a summary and the calls that answer differently in
combat. The text - client build, class and level, then one line per call, `out ... | in ...`,
`<<` where they differ - is in a window to copy (`/gf selftest show`; the in-combat run never
opens the window or takes the keyboard by itself) and is kept in `BetterForeverDB.selftest`.

`/gbf`, `/gqf`, `/gmf`, `/gcf`, `/gpf`, `/ggps` (and `/way`), `/gff`, `/gwf`, `/gfish`, `/gbuff`,
`/gmerch`, `/gtip`, `/gmail`, `/gxp`, `/gchat`, `/gbars` and `/glf` belong to the addons themselves.

## Saved variables

`BetterForeverDB`, read at `ADDON_LOADED`, never at file scope:

```
minimap  = { hide = false, angle = 285 }
news     = true                               -- what's new lines at login
seen     = { GaarBuffsForever = "1.5.1" }   -- the version of each addon seen last
lastNews = { "updated — ..." }                -- the last block, for /gf news
selftest = "GaarForever 3.1.0 self-test ..." -- the last self-test text
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
| `BetterForever.RenderMenu(root, entries, title)` | Draws `MenuEntries()` data into a `MenuUtil` description (checkbox, radio, submenu, label, divider, button; a slider as a submenu of its steps, at most about 25 of them across the whole range) - the `RenderMenu` every addon carries a copy of. `title` (optional) names the addon in the chat line of a click that errors |
| `BetterForever.Report(err, title)` | One chat line, `<title>: <err>` (`GaarForever` without a title), and the error to the game's error handler, once per distinct error a session |
| `BetterForever.IntroOf(api)` | An API table's intro (`Intro()` or `intro`), or `nil` |
| `BetterForever.Options.Rows(entries)` | The rows an Options page makes of `MenuEntries()` data, for checking a new shape with `/dump` |

### An addon object

```lua
local A = BetterForever.NewAddon("BetterExampleForever", {   -- the folder name: the key, API and slash ids
    title = "GaarExampleForever",                       -- optional (3.2): the shown name; default
                                                         -- BetterForever.DisplayName(name)
    version = "1.0",
    intro = "What it does in one or two sentences. Nice to know: ...",
    status = function() return "on · 3 things" end,   -- optional: the state line
    help = { "/bex frob - frobnicate now" },          -- optional: extra help lines
})
```

| Method | Does |
|---|---|
| `A:Print(...)` | One chat line with the family prefix, `\|cff33ff99<title>\|r: `, the arguments joined by spaces |
| `A:InitDB(globalName, defaults)` | Binds the saved variable (call it at `ADDON_LOADED`): creates the table, fills missing keys from `defaults` (nested tables too, copied) and from every option's default; returns it, also as `A.db` |
| `A:Toggle(key, label, default, onChange, opts)` | A checkbox stored in `db[key]`: `/x <key> on\|off` (no value toggles), a menu checkbox and an Options-page checkbox. `opts.cmd` renames the command word. The key `enabled` is the master switch: `/x on`, `/x off` |
| `A:Choice(key, label, values, default, onChange, opts)` | One of `values` (`{ "a", "b" }` or `{ { value = "a", label = "A" } }`): `/x <key> <value>`, a submenu of radios, a dropdown |
| `A:Slider(key, label, min, max, step, default, onChange, format, opts)` | A number: `/x <key> <n>` (snapped to the step, then clamped to `min` .. the largest step not above `max`), a submenu of steps in the menu, a slider on the Options page. A `step` that is not a positive number becomes 1 |
| `A:Button(label, func, opts)` | A button; with `opts.cmd`, `/x <cmd>` runs it too |
| `A:Divider()` | A gap in the menu and on the page |
| `A:Get(key)`, `A:Set(key, value)` | Read (the default while unset); write, checked against the option's kind, then `onChange(value, key, old)` in `pcall` - after the value is in the db |
| `A:MenuEntries()` | The options as `MenuEntries()` data |
| `A:Slash({ "/x", "/longname" }, handlers)` | Registers the commands (`SlashCmdList[<NAME>]`, the same key the addons use today). `handlers[word] = function(rest, msg)` run first; built in: `help` (the intro, one line per option, the extra help lines), `status`, `on\|off`, and one command per option |
| `A:Run(feature, fn, ...)` | `fn(...)` in `pcall`; the first error switches that feature off for the session with one chat line (GaarPlatesForever's `Run`), later calls return at once. `A:IsBlocked(feature)`, `A:Latch(feature, err)` |
| `A:On(event, handler)` | Registers an event on the addon's own frame; `handler(event, ...)` runs in `pcall`. An event can have several handlers, run in the order added. The last error is kept in `A.lastError` and shown by `/x status` |
| `A:API(extra)` | Builds and exports `_G[<name> .. "API"]`: `version`, `StatusLine`, `MenuEntries`, `AddMenuEntries`, `SetMinimapHidden` (does nothing), `Intro`, plus `extra` |
| `A:ProfileMode()` | (3.1) `"character"`, `"shared"`, or `nil` before `InitDB` |
| `A:SetProfileMode(mode)` | (3.1) `"character"`: this character gets its own copy, seeded from the shared settings; `"shared"`: the copy is dropped. Returns `ok, message`; `onChange` runs for each option that changes, then `A.onProfileChanged(mode)` if the addon set one (for settings that are not options) |
| `A:ExportSettings()` | (3.1) The settings in use as an export string |
| `A:ImportSettings(t)` | (3.1) Applies a decoded table through `A:Set`, options only; returns `applied, ignored` |

### Settings strings (3.1)

| Helper | Does |
|---|---|
| `BetterForever.CharKey()` | `"Name - Realm"`, or `nil` before the client knows the name (`InitDB` then binds again at `PLAYER_LOGIN`) |
| `BetterForever.Serialize(t)`, `BetterForever.Deserialize(s)` | A table of strings, finite numbers, booleans and tables as text (`S<len>:`, `N<n>;`, `B1`/`B0`, `T ... E`) and back, parsed by hand with size, depth and count limits; functions, userdata and secret values are left out |
| `BetterForever.Base64Encode(s)`, `BetterForever.Base64Decode(s)` | Plain base64; decode gives `nil` for anything that is not |
| `BetterForever.EncodeSettings(name, t)`, `BetterForever.DecodeSettings(s)` | `"BF1:<name>:<check>:<base64>"`; decode ignores spaces and line breaks and gives `name, t` or `nil, why` |

### Migrating an addon (phase 2)

One addon at a time, behaviour unchanged, `tools/check.sh` clean after each:

1. **Helpers.** Replace the file's own `Secret`/`IsSecret`, `Plain`, `Num`, `Str`, `Bool`, `Call`,
   `API`, `AddOnLoaded`, `InCombat`, `OnOff` and time/coin formatters with locals bound to the
   library: `local BF = GaarForever; local Plain, Num = BF.Plain, BF.Num`. Watch the small
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
   one list. Keep hand-written slash commands as `handlers`. `onChange(value, key, old)` runs
   after the new value is written to the db: read the db (or `value`) in it, not a copy taken
   before; `old` is what was stored before.
6. **API.** Replace the hand-built `_G.BetterXForeverAPI = { ... }` and its `RenderMenu` copy with
   `A:API({ StatusLine = StatusLine })` (or `BF.RenderMenu` inside the existing table). The API's
   shape stays the same, so the hub needs no change.
7. Bump the version, run `tools/check.sh`, and check `/x`, `/x status`, the minimap submenu and
   the Options page in game.

## 3.2.0

- **Renamed to GaarForever**, and the family to Gaar...Forever: TOC titles, the Options category
  (**Esc > Options > AddOns > Gaar Forever**), chat prefixes, tooltips, menus, the what's-new
  lines and help text. Folders, TOC file names, `## Dependencies: BetterForever`, saved variables,
  globals (`BetterForever`, `Better...ForeverAPI`) and frame names keep the old names, so settings
  carry over and installs keep working.
- **New commands**: `/gf` (`/gaarforever`) for the hub and a g-command per addon (`/gbf`, `/gqf`,
  `/gmf`, `/gcf`, `/gpf`, `/ggps`, `/gff`, `/gwf`, `/gfish`, `/gbuff`, `/gmerch`, `/gtip`, `/gmail`,
  `/gxp`, `/gchat`, `/gbars`, `/glf` - `/gloot` is GaarLooter's). Every old `/b...` command and
  `/better...forever` long form still works; `/gf options` takes either.
- Library 3.2: `BetterForever.DisplayName(name)`; `NewAddon` takes the shown name from it (or
  `opts.title`).

## 3.1.0

- **What's new**: one chat line per family addon whose version went up since the last login,
  with a note from the hub's `CHANGES` table; `/gf news [on|off]`, a checkbox on the overview page.
- **Profiles**: `/gf profile [char|shared] <addon|all>` - per-character settings for addons on
  the library's `A:InitDB` (GaarLootForever today), stored inside the addon's own saved
  variable, old data untouched. `/gf export <addon>` and `/gf import` move settings as a string,
  parsed by hand (never `loadstring`).
- **Self-test**: `/gf selftest [show]` - the client APIs the family uses, in `pcall`, on player,
  target and party1, out of and in combat, in a window to copy.
- Library 3.1.0: `A:ProfileMode`, `A:SetProfileMode`, `A:ExportSettings`, `A:ImportSettings`,
  `CharKey`, `Serialize` / `Deserialize`, `Base64Encode` / `Base64Decode`,
  `EncodeSettings` / `DecodeSettings`. `A:InitDB` returns (and sets as `A.db`) the character's copy
  where it has one.
- `BetterForeverDB` keeps `news`, `seen`, `lastNews` and `selftest` next to `minimap`.

## 3.0.2

- A **Loot** row for the new GaarLootForever 1.0 (`BetterLootForeverAPI`, `/glf`): its
  submenu in the minimap menu, its Options page, its line in `/gf status`. The library is
  unchanged (still 3.0.1); GaarLootForever is the first addon built on `NewAddon`'s option
  registry.

## 3.0.1

- Sliders: `A:Set` snaps to the step first and then clamps, so a value can no longer land above
  `max` (a 0-10 slider in steps of 4 stored 12); a step that is not a positive number becomes 1.
  A slider's menu covers its whole range in at most about 25 steps, the top value always included.
- Options pages: radios split by a divider in one submenu become separate dropdowns; a change in
  an addon's intro or "Now:" line no longer rebuilds the page (the text is updated in place);
  after any change every control shows its current value again, so an option that changes
  another shows at once. A client where the pages cannot be registered is not asked again on
  every `/gf options`.
- `/gf options <name>` says "unknown addon" (and lists the names) for a name it does not know,
  and "no Options page" when the page did not open.
- `A:On` keeps every handler of an event; `/x status` shows the last error. `onChange` gets
  `(value, key, old)`. A slash command before the addon's settings are loaded says "not ready
  yet". Menu-click errors name the addon they came from and also go to the error handler once.
- The plain menu (no checkboxes) marks radios `(o)` / `( )` again; `AddOnLoaded` also asks the old
  `IsAddOnLoaded` when `C_AddOns` does not say yes; `BetterForeverAPI.SetMinimapHidden` before
  the hub has loaded does nothing instead of erroring.

## 3.0

- Renamed from **BetterGaarForever**: folder, TOCs (`BetterForever.toc`,
  `BetterForever_Camelot.toc`), saved variable `BetterForeverDB`, frames
  (`BetterForeverMinimapButton`, `BetterForeverMinimapMenu`), `/gf` and `/betterforever`.
  `/bgf`, `BetterGaarForever_PlaceMinimapButton` and `BetterGaarForeverAPI` stay as aliases.
  The minimap button's position resets once (see [Coming from BetterGaarForever](#coming-from-bettergaarforever)).
- Every Gaar...Forever addon now requires it (`## Dependencies: BetterForever`), so the hub no
  longer lists them under `## OptionalDeps`: they load after it, and their API is there at
  `PLAYER_LOGIN` as before.
- The shared library, global `BetterForever` (`Lib.lua`).
- The Options pages under **Esc > Options > AddOns > Gaar Forever** (`Settings.lua`,
  `BetterForever.xml`), with an intro per addon from the new `Intro()` API field; `/gf options`.
- Rows for the six newer addons: **Merchant** (`GaarMerchantForever`), **Tooltips**
  (`GaarTooltipsForever`), **Mail** (`GaarMailForever`), **XP** (`GaarXPForever`), **Chat**
  (`GaarChatForever`) and **Bars** (`GaarBarsForever`).
- The fallback menu shows a slider entry as a line with its value.

## 2.8

Adds the **Buffs** submenu for GaarBuffsForever 1.0 (through `BetterBuffsForeverAPI`, the
same code path as the others), lists it under `## OptionalDeps`, in `/bgf` help and in
`/bgf status`. Nothing else changed.

## 2.7

The **Fishing** submenu gains a **Fishing route** checkbox (GaarFishingForever 1.2's Fishing
1-300 route, the same as `/gfish route on|off`). It comes from `BetterFishingForeverAPI.MenuEntries`
like the other Fishing options, so the hub's code is unchanged apart from the version.

## 2.6

Adds the **Fishing** submenu for GaarFishingForever 1.0 (through `BetterFishingForeverAPI`, the
same code path as the others), lists it under `## OptionalDeps`, in `/bgf` help and in
`/bgf status`. Nothing else changed.

## 2.5

Adds the **Windows** submenu for GaarWindowsForever 1.0 (through `BetterWindowsForeverAPI`, the
same code path as the others), lists it under `## OptionalDeps`, in `/bgf` help and in
`/bgf status`. Nothing else changed.

## 2.4

Adds the **Frames** submenu for GaarFramesForever 1.0 (through `BetterFramesForeverAPI`, the
same code path as the others), lists it under `## OptionalDeps`, in `/bgf` help and in
`/bgf status`. Nothing else changed.

## 2.3

Adds the **GPS** submenu for GaarGpsForever 1.0 (through `BetterGpsForeverAPI`, the same code
path as the others), lists it under `## OptionalDeps`, in `/bgf` help and in `/bgf status`.
Nothing else changed.

## 2.2

Adds the **Castbars** and **Plates** submenus for GaarCastbarsForever and GaarPlatesForever
(through `BetterCastbarsForeverAPI` and `BetterPlatesForeverAPI`, the same code path as the
others), lists them under `## OptionalDeps` and in `/bgf status`.

## 2.1

Adds the **Maps** submenu for GaarMapsForever 1.0 (through `BetterMapsForeverAPI`, the same code
path as Bags and Quests), lists it under `## OptionalDeps` and in `/bgf status`. Nothing else
changed.

## From 1.0

1.0 carried copies of both addons as modules, with its own copy of their settings. 2.0 is only the
hub: the modules, the settings import and the pause-when-both-are-loaded logic are gone, and so
are the `/gbf` and `/gqf` aliases. Your settings are the ones in `BetterBagsForeverDB` and
`BetterQuestsForeverDB`, so keep (or re-enable) both addons next to the hub. Settings changed only
inside 1.0 are not carried back.

## Layout

```
BetterForever.toc, BetterForever_Camelot.toc   both at 16001, same file list
Lib.lua             the shared library, global GaarForever
Settings.lua        the Options pages (Esc > Options > AddOns > Gaar Forever)
BetterForever.xml   the text-row template the Options pages use
Tools.lua           what's new, profiles / export / import, the self-test (3.1)
Core.lua            saved variables, minimap button and menu, /gf
```

## License

MIT, see [LICENSE](LICENSE).
