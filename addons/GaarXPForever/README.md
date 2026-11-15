# GaarXPForever

> Formerly **BetterXPForever**. The folder is now `GaarXPForever` as well; the update also ships a tiny `BetterXPForever` folder, a
> settings bridge that moves your old settings over on the first login (each character on its own
> first login). It is safe to delete after logging in once on each character, and later updates drop it. The command is
> now `/gxp` (`/gaarxpforever`); the old `/bxp` and `/betterxpforever` still work.
> CurseForge: https://www.curseforge.com/wow/addons/gaarxpforever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001; classic-era
content, level cap 60). XP at a glance: a movable text panel, text on the XP bar, time played per
level on level-up, and quest XP in tooltips. Every part has its own switch. It needs GaarForever, the family hub, and no other addon or library and is not part of the Gaar suite.

## What it does

- **XP panel** (`panel`, on): a small movable text panel with XP `cur/max (pct%)`, rested XP (amount
  and % of the level), XP per hour this session, time to level at that rate and "~N kills / ~N
  quests" to level (the session's average XP per kill and per quest turn-in). At max level it says
  "Max level". Alt-drag moves it (or plain drag after `/gxp unlock`); the position is saved.
- **Text on the XP bar** (`xpbarText`, on): cur/max, pct and rested on Blizzard's XP bar
  (`MainMenuExpBar`, or `MainStatusTrackingBarContainer` / `StatusTrackingBarManager` on newer
  UIs), shown on hover, or always with `xpbarAlways` (off). `/gxp status` names the frame found.
- **Level log** (`levelLog`, on): on level-up, one chat line with the time played on that level and
  in total. Blizzard's own time-played print is held back for that one request.
- **Quest XP** (`questXP`, off): the quest's XP reward as a line in the quest log / quest link
  tooltip, where the client gives it (`C_QuestLog.GetQuestLogRewardXP`). Plain values only.
- **Session reset**: `/gxp reset` resets the session's XP, rate, kills and quests.

How the change is counted: `PLAYER_XP_UPDATE` deltas (across a level-up, the rest of the old level
plus the new XP), classified a moment later: a `CHAT_MSG_COMBAT_XP_GAIN` = a kill, a
`QUEST_TURNED_IN` = a quest, anything else only counts toward XP/hour. Chat text is never parsed.
The rate needs a minute of session.

Settings are saved account-wide in `GaarXPForeverDB`: `enabled`, `panel`, `xpbarText`,
`xpbarAlways`, `levelLog`, `questXP`, `locked` and `pos`.

## Commands

`/gxp` or `/gaarxpforever`

| Command | What it does |
|---|---|
| `/gxp` , `/gxp help` | Help |
| `/gxp on`, `/gxp off` | Everything on or off |
| `/gxp panel on\|off` | The XP panel |
| `/gxp xpbar on\|off` | Text on the XP bar (`xpbarText`) |
| `/gxp always on\|off` | Keep the bar text visible without hover (`xpbarAlways`) |
| `/gxp levellog on\|off` | Time played on level-up |
| `/gxp questxp on\|off` | Quest XP in tooltips |
| `/gxp unlock`, `/gxp lock` | Drag the panel without Alt / back to Alt-drag |
| `/gxp resetpos` | Panel back to its default place |
| `/gxp reset` | Reset the session |
| `/gxp status` | Version, every setting, the XP bar frame found, session numbers and the last error |

## With GaarForever (required)

Since 1.0.1 this addon lists `GaarForever` (the GaarForever folder) under `## Dependencies`: install the `GaarForever` folder next to it, or the client will not load this addon. GaarForever also gives it a page under **Esc > Options > AddOns > Gaar Forever**, built from the same `MenuEntries()` as the hub's menu, with a short intro at the top; that intro comes from `Intro()`, a field the API table gained in 1.0.1 (it is also the first line of the slash command's help).

Since 1.0.2 it takes its shared helpers from GaarForever's library (`GaarForever`, `Lib.lua`) instead of carrying its own copies: the chat prefix, the secret-value checks (`IsSecret`, `Num`) and the drawing of its menu (`RenderMenu`). Nothing you see or set changed.

The optional hub talks to this addon only through `GaarXPForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line, e.g. `on · 45.2% · 12,300 xp/h` |
| `MenuEntries()` | Options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, submenu }`, `{ divider }`) |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: no minimap button |

## How it stays out of the way

- Blizzard code is only followed: `hooksecurefunc` on tooltip helpers and a `HookScript` on
  `GameTooltip`; the XP bar is only polled (`IsMouseOver`), never hooked or changed.
- Every client API is checked with `type(...) == "function"`, every handler runs in `pcall` (the
  last error is shown by `/gxp status`), and a secret value is treated as no value.
- Saved variables are read at `ADDON_LOADED`, never at file scope.

## License

MIT, see [LICENSE](LICENSE).
