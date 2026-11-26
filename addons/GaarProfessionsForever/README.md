# GaarProfessionsForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001) that adds two
helpers to the profession window. It needs GaarForever, the family hub, and no other addon or
library, and it is not part of the Gaar suite.

## What it does

- **Collapse-all button** (`collapseButton`, on by default). A +/- button right of the profession
  window's **Filter** button. While any visible category of the recipe list is open it shows
  minus, and a click collapses every category; when all are collapsed it shows plus, and a click
  expands them all. Same art and behaviour as the collapse-all button in GaarQuestsForever.
  `/gprof collapse` does the same from chat.
- **Have Part of Materials** (`partial`, off by default). A checkbox in the Filter menu, right
  under Blizzard's **Have Materials**. While it is checked the list shows only recipes where you
  have at least 1 of at least one required reagent in your bags, so it covers having some of the
  materials and having all of them. Categories with no recipe left are hidden. The setting is
  saved; `/gprof partial on|off` switches it from chat. Blizzard's own filter reset does not touch
  it.
- **Master switch.** `/gprof off` turns both off.

Settings are saved account-wide in `GaarProfessionsForeverDB`: `enabled`, `collapseButton`,
`partial`.

## Which profession window

WoW Forever runs classic content on the retail 12.x engine. Its binary carries the retail
`Blizzard_Professions` addon and `C_TradeSkillUI`, and none of the classic `GetNumTradeSkills` /
`GetTradeSkillInfo` / `CollapseTradeSkillSubClass` globals, so the window is expected to be the
retail `ProfessionsFrame`. Both are handled; `/gprof status` says which one this client has.

| Window | Collapse | Have Part of Materials |
|---|---|---|
| `ProfessionsFrame` (retail, `Blizzard_Professions`) | Blizzard's own `dataProvider:SetAllCollapsed()` on the recipe list's tree data provider | yes: a checkbox added with `Menu.ModifyMenu("MENU_PROFESSIONS_FILTER")`; Blizzard's provider is filtered in a `hooksecurefunc` post-hook on `CraftingPage:Init` |
| `TradeSkillFrame` (classic, `Blizzard_TradeSkillUI`) | `CollapseTradeSkillSubClass(0)` / `ExpandTradeSkillSubClass(0)`, checked by a rescan of the header rows, else one header at a time | no: its rows are engine indices; a real filter there needs `TradeSkillFrame_Update` replaced, which this addon never does |

Both profession UIs are load-on-demand: the addon attaches at their `ADDON_LOADED`, at
`TRADE_SKILL_SHOW`, and at login when the window already exists.

## Commands

`/gprof` or `/gaarprofessionsforever`:

| Command | Does |
|---|---|
| `/gprof` or `/gprof help` | list the commands |
| `/gprof on` / `off` | master switch |
| `/gprof collapse` | collapse all categories, or expand all when all are collapsed |
| `/gprof partial on\|off` | the Have Part of Materials filter |
| `/gprof button on\|off` | the collapse-all button |
| `/gprof status` | which window and API path was found, whether the button is attached, the filter, whether the crafting form is tainted, any blocked action, the last error |

## With GaarForever (required)

This addon lists `GaarForever` under `## Dependencies`: install the `GaarForever` folder next to
it, or the client will not load it. GaarForever gives it a **Professions** row in the hub menu
and a page under **Esc > Options > AddOns > Gaar Forever**, built from `GaarProfessionsForeverAPI`
(`version`, `Intro`, `StatusLine`, `MenuEntries`, `AddMenuEntries`, `SetMinimapHidden`).

## How it is built

Only `hooksecurefunc`, `HookScript`, events and Blizzard's menu extension `Menu.ModifyMenu`. No
Blizzard function is replaced and no Blizzard layout method is called. The button is a plain
child frame of the recipe list.

Taint: collapsing and filtering change Blizzard's tree data provider from addon code, so the recipe
rows laid out right after are tainted until Blizzard rebuilds the list. The craft calls
(`C_TradeSkillUI.CraftRecipe`, `CraftEnchant`, `CraftSalvage`) are not protected functions, so
Create and Create All keep working. `/gprof status` shows whether the crafting form is tainted and
records any `ADDON_ACTION_BLOCKED` / `ADDON_ACTION_FORBIDDEN` that names this addon.

Turning the filter off, or a bag change while it is on, asks Blizzard to rebuild the list by
flipping one of its own C filters (`SetOnlyShowSkillUpRecipes`) and back; the rebuild then runs in
Blizzard's own `TRADE_SKILL_LIST_UPDATE` handler. Blizzard rebuilds the list after every craft and
only restores the top-level collapses it stored at the last close, so after a click on the button
the collapse state is carried over to the rebuilt list (same profession, until the window closes).

Every handler runs in `pcall`, every client API is checked with `type(...) == "function"` first,
and a secret value is never compared: it counts as no value. No combat-log event is registered. It
ships a `_Camelot` TOC and a plain fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).

## Support

If you enjoy this addon, you can [buy me a coffee](https://buymeacoffee.com/tgaarden) ☕

## Screenshots

None yet. They go in `docs/screenshots/GaarProfessionsForever/` (numbered, e.g.
`1-collapse-button.jpg`, `2-filter-menu.jpg`), shown here like the other addons' READMEs.
