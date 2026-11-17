# GaarLootForever

> Formerly **BetterLootForever**. The folder is now `GaarLootForever` as well; the update also ships a tiny `BetterLootForever` folder, a
> settings bridge that moves your old settings over on the first login (each character on its own
> first login). It is safe to delete after logging in once on each character, and later updates drop it. The command is
> now `/glf` (`/gaarlootforever`); the old `/bloot` and `/betterlootforever` still work. `/gloot` belongs to GaarLooter, so this one is `/glf`.
> CurseForge: https://www.curseforge.com/wow/addons/gaarlootforever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). When a group
loot roll comes up, each of its Need, Greed and Pass buttons gets a small number: how many in
your group chose that option for that roll. Hover a button to see who. Since the client closes
the roll frame once you have chosen, a small movable summary panel lists the last rolls: who chose
what, the numbers they rolled and who won. Every part has its own switch. It needs GaarForever, the family hub, and no other addon or library, and it is not part
of the Gaar suite.

## What it does

- **Counts** (`counts`, on). A small white, outlined number in the bottom-right corner of the
  Need, Greed and Pass buttons (and the Transmog button, where the client shows one) of every open
  roll. It counts each player once per roll, the latest choice wins, and your own choice counts
  too. Hidden while 0. The counts start from nothing for each roll and follow a roll frame when the
  client reuses it for the next roll.
- **Names** (`names`, on). Hovering a button adds one line to the button's own tooltip, such as
  `Need: Elex, Bob`. Blizzard's tooltip (the button name, why it is disabled) is left as it is.
  Disenchant choices count with Greed and are marked `(DE)`.
- **Summary** (`summary`, on; new in 1.1.0). A small panel (dark, with a thin border) listing the
  recent rolls, newest on top. Each roll shows the item (its icon and coloured name; hover for the
  item tooltip), the result on the right (`» Elex 87` for the winner and their roll, `all passed`,
  `rolling` while it is open, `no result` when the roll ran out without a result line), and one line
  per choice with its count and who: `Need 2  Elex 87, Mira 42`. The numbers come from the
  "Need Roll - 87 for [item] by Elex" lines and are sorted highest first; Disenchant is counted with
  Greed and marked `(DE)`. A long line is cut; hover the lines for the full list. The last N rolls
  are kept (`rolls`, 1 to 10, default 5). It is shown only while you are in a group. Drag it to move
  it (the place is saved); `/glf reset` puts it back. The close button clears it; the next roll
  brings it back.
- **Auto-hide** (`autohide`, on). The summary clears itself 60 seconds after the last of its rolls
  has finished (its result line arrived, or its roll time ran out). Off: it stays until you close it.
- **Preview** (`/glf test`). A small window with three fake buttons and their counts, built by
  running the client's own loot chat strings through the same parser; the parse results are
  printed in chat too. It also puts three fake finished rolls in the summary (a winner with the
  numbers rolled, an "all passed" and one you won), shown even outside a group. The real roll frame
  cannot be opened without a real roll, so it is not used for this.
- **Master switch.** `/glf off` turns all of the above off.

Settings are saved account-wide in `GaarLootForeverDB`: `enabled`, `counts`, `names`, `summary`,
`autohide`, `summaryRolls` and the summary's place, `summaryPos`.

## Where the numbers come from

No event gives an addon the other players' choices for a roll, so the addon reads two things:

1. **The loot chat lines** (`CHAT_MSG_LOOT`, and `CHAT_MSG_SYSTEM`): "Elex has selected Need for:
   [item]", "You passed on: [item]", "Bob automatically passed on: ...", the "Need Roll - 87 for
   [item] by Elex" lines, and the result lines (won, everyone passed). The patterns are made at
   load from the client's own format strings (`LOOT_ROLL_NEED`, `LOOT_ROLL_GREED`,
   `LOOT_ROLL_PASSED`, the `_SELF`, `_AUTO`, `DISENCHANT` and `TRANSMOG` forms where the client has
   them, `LOOT_ROLL_WON`, `LOOT_ROLL_ALL_PASSED`, the short `LOOT_ROLL_WON_NO_SPAM_*` result lines
   where the client has them, ...), so any locale works, including ones that
   reorder the arguments (`%1$s`). Each line names the item; it is matched to the open roll of
   that item (`GetLootRollItemLink`). When two rolls of the same item are open, a line goes to the
   oldest one where that player has not chosen yet.
2. **The loot history** (`C_LootHistory`, `LOOT_HISTORY_UPDATE_DROP`), where the client fills it:
   each player's roll state for a drop, matched to the open roll by item link. It is kept per boss
   encounter, so on trash it says nothing and the chat lines do the work.

A roll is forgotten when its result line arrives, when the client cancels all rolls, or once its
roll time is over. The client closes your roll frame as soon as you have chosen, so the numbers
on the buttons are mainly there to see what the others picked before you choose; the summary keeps
the same roll (with its winner) for after. Only rolls the client opened for you
(`START_LOOT_ROLL`) are in the summary.

`/glf status` shows how many chat patterns were built from the client's strings, whether the
loot history is there, how many rolls are open and how many are in the summary.

## Commands

`/glf` or `/gaarlootforever`:

| Command | Does |
|---|---|
| `/glf` or `/glf help` | list the commands |
| `/glf on` / `off` | master switch |
| `/glf counts on\|off` | the numbers on the buttons (`counts`) |
| `/glf names on\|off` | the names in the button tooltips (`names`) |
| `/glf summary on\|off` | the summary panel of the last rolls (`summary`) |
| `/glf autohide on\|off` | clear the summary 60 s after the last roll finished (`autohide`) |
| `/glf rolls <1-10>` | how many rolls the summary keeps (`summaryRolls`, default 5) |
| `/glf reset` | the summary back to its default place |
| `/glf test` | the preview window, the parse results and fake rolls in the summary |
| `/glf status` | version, settings, patterns, open rolls, the last error |

## With GaarForever (required)

The addon lists `GaarForever` (the GaarForever folder) under `## Dependencies`: install the `GaarForever` folder next to
it. It is built on the hub's library (`GaarForever.NewAddon`): the switches above are registered
once and give the slash commands, the **Loot** submenu in the hub's minimap menu and the page under
**Esc > Options > AddOns > Gaar Forever**, with a short intro at the top.
`GaarLootForeverAPI` (`version`, `StatusLine`, `MenuEntries`, `AddMenuEntries`,
`SetMinimapHidden`, `Intro`) is what the hub reads. The hub lists it from GaarForever 3.0.2.

## How it is built

The roll frames are Blizzard's (`GroupLootFrame1`..`4` in `GroupLootContainer`, each with `rollID`
and the buttons `LootButtonContainer.NeedButton`, `GreedButton`, `PassButton` and
`TransmogButton`; `frame.NeedButton` and `GroupLootFrame1NeedButton` are tried as fallbacks). No
Blizzard function is replaced. The summary is a frame of the addon's own
(`GaarLootForeverSummary`, a 1px `BackdropTemplate` border like the other family panels); while
it is shown it checks once a second for rolls that ran out of time and for the auto-hide. The number sits on a frame of the addon's own, a child of the button
with the mouse off, so every click still reaches the button; the tooltip line is added with
`HookScript("OnEnter")`, after Blizzard's own handler. Every handler runs in `pcall`, every client
API is checked with `type(...)` first, and a secret value (chat text and names can be secret in
some contexts) is never compared or tested: such a line is skipped. It ships a `_Camelot` TOC and a
plain fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).

## Support

If you enjoy this addon, you can [buy me a coffee](https://buymeacoffee.com/tgaarden) ☕
