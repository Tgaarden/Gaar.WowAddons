# BetterTooltipsForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001) that adds useful
lines to item and unit tooltips. Every feature is individually switchable. It needs BetterForever, the family hub, and no other addon or library and is not part of the Gaar suite.

## Features

Item tooltips (GameTooltip and ItemRefTooltip; the Blizzard compare tooltips are left alone):

| Feature | Default | What it adds |
|---|---|---|
| `vendorPrice` | on | Vendor sell price per item and for the stack (count read from the hovered bag slot), or "No sell price". Skipped when the client already shows a sell price line. |
| `itemId` | off | Item ID, and spell ID on spell tooltips. |
| `itemLevel` | on | Item level of equippable items (not added when the tooltip already has it). |
| `compare` | on | "vs equipped:" with the top 5 differing stats against the item in the matching slot, green for better, red for worse. Uses `C_Item.GetItemStats`. |

Unit tooltips:

| Feature | Default | What it adds |
|---|---|---|
| `target` | on | "Target: name", class coloured for players; a red YOU when it targets you. |
| `guildRank` | on | Guild rank next to the guild name of players. |
| `health` | on | Health value / max and percent. |
| `classColor` | on | Class coloured player name and tooltip border. |
| `anchor` | off | Tooltip at the cursor instead of the default corner. |

## Commands

`/btip` or `/bettertooltipsforever`

| Command | Does |
|---|---|
| `/btip` | Help |
| `/btip on`, `/btip off` | Master switch |
| `/btip <feature> on\|off` | Switch one feature (`vendorPrice`, `itemId`, `itemLevel`, `compare`, `target`, `guildRank`, `health`, `classColor`, `anchor`); without `on`/`off` it toggles |
| `/btip status` | Version, master, hook method, every feature, last error caught |

Settings are saved account-wide in `BetterTooltipsForeverDB`.

## With BetterForever (required)

Since 1.0.1 this addon lists `BetterForever` under `## Dependencies`: install the `BetterForever` folder next to it, or the client will not load this addon. BetterForever also gives it a page under **Esc > Options > AddOns > Better Forever**, built from the same `MenuEntries()` as the hub's menu, with a short intro at the top; that intro comes from `Intro()`, a field the API table gained in 1.0.1 (it is also the first line of the slash command's help).

The optional hub talks to this addon only through `BetterTooltipsForeverAPI`: `version`,
`StatusLine()`, `MenuEntries()` (a master checkbox, a divider and one checkbox per feature, as
plain data), `AddMenuEntries(root)` for a `MenuUtil` menu and `SetMinimapHidden()` (does nothing;
there is no minimap button).

## How it stays out of the way

- Tooltips are hooked the modern way, `TooltipDataProcessor.AddTooltipPostCall` for items, units and
  spells, falling back to `GameTooltip:HookScript("OnTooltipSetItem" / "OnTooltipSetUnit")` on older
  clients. Blizzard code is only followed, never replaced; the anchor feature is a
  `hooksecurefunc` on `GameTooltip_SetDefaultAnchor`.
- **Secret values.** Every value from the client passes through a check that treats a secret as no
  value; a secret is never compared, tested or formatted. A line whose value is secret (for
  instance a unit's health in combat) is skipped.
- Every handler runs in `pcall`, every client API is checked with `type(...) == "function"`, and
  saved variables are read at `ADDON_LOADED`.

## License

MIT, see [LICENSE](LICENSE).
