# BetterXPForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001; classic-era
content, level cap 60). XP at a glance: a movable text panel, text on the XP bar, time played per
level on level-up, and quest XP in tooltips. Every part has its own switch. It needs BetterForever, the family hub, and no other addon or library and is not part of the Gaar suite.

## What it does

- **XP panel** (`panel`, on): a small movable text panel with XP `cur/max (pct%)`, rested XP (amount
  and % of the level), XP per hour this session, time to level at that rate and "~N kills / ~N
  quests" to level (the session's average XP per kill and per quest turn-in). At max level it says
  "Max level". Alt-drag moves it (or plain drag after `/bxp unlock`); the position is saved.
- **Text on the XP bar** (`xpbarText`, on): cur/max, pct and rested on Blizzard's XP bar
  (`MainMenuExpBar`, or `MainStatusTrackingBarContainer` / `StatusTrackingBarManager` on newer
  UIs), shown on hover, or always with `xpbarAlways` (off). `/bxp status` names the frame found.
- **Level log** (`levelLog`, on): on level-up, one chat line with the time played on that level and
  in total. Blizzard's own time-played print is held back for that one request.
- **Quest XP** (`questXP`, off): the quest's XP reward as a line in the quest log / quest link
  tooltip, where the client gives it (`C_QuestLog.GetQuestLogRewardXP`). Plain values only.
- **Session reset**: `/bxp reset` resets the session's XP, rate, kills and quests.

How the change is counted: `PLAYER_XP_UPDATE` deltas (across a level-up, the rest of the old level
plus the new XP), classified a moment later: a `CHAT_MSG_COMBAT_XP_GAIN` = a kill, a
`QUEST_TURNED_IN` = a quest, anything else only counts toward XP/hour. Chat text is never parsed.
The rate needs a minute of session.

Settings are saved account-wide in `BetterXPForeverDB`: `enabled`, `panel`, `xpbarText`,
`xpbarAlways`, `levelLog`, `questXP`, `locked` and `pos`.

## Commands

`/bxp` or `/betterxpforever`

| Command | What it does |
|---|---|
| `/bxp` , `/bxp help` | Help |
| `/bxp on`, `/bxp off` | Everything on or off |
| `/bxp panel on\|off` | The XP panel |
| `/bxp xpbar on\|off` | Text on the XP bar (`xpbarText`) |
| `/bxp always on\|off` | Keep the bar text visible without hover (`xpbarAlways`) |
| `/bxp levellog on\|off` | Time played on level-up |
| `/bxp questxp on\|off` | Quest XP in tooltips |
| `/bxp unlock`, `/bxp lock` | Drag the panel without Alt / back to Alt-drag |
| `/bxp resetpos` | Panel back to its default place |
| `/bxp reset` | Reset the session |
| `/bxp status` | Version, every setting, the XP bar frame found, session numbers and the last error |

## With BetterForever (required)

Since 1.0.1 this addon lists `BetterForever` under `## Dependencies`: install the `BetterForever` folder next to it, or the client will not load this addon. BetterForever also gives it a page under **Esc > Options > AddOns > Better Forever**, built from the same `MenuEntries()` as the hub's menu, with a short intro at the top; that intro comes from `Intro()`, a field the API table gained in 1.0.1 (it is also the first line of the slash command's help).

The optional hub talks to this addon only through `BetterXPForeverAPI`:

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
  last error is shown by `/bxp status`), and a secret value is treated as no value.
- Saved variables are read at `ADDON_LOADED`, never at file scope.

## License

MIT, see [LICENSE](LICENSE).
