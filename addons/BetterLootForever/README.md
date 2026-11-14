# BetterLootForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). When a group
loot roll comes up, each of its Need, Greed and Pass buttons gets a small number: how many in
your group chose that option for that roll. Hover a button to see who. Every part has its own
switch. It needs BetterForever, the family hub, and no other addon or library, and it is not part
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
- **Preview** (`/bloot test`). A small window with three fake buttons and their counts, built by
  running the client's own loot chat strings through the same parser; the parse results are
  printed in chat too. The real roll frame cannot be opened without a real roll, so it is not
  used for this.
- **Master switch.** `/bloot off` turns all of the above off.

Settings are saved account-wide in `BetterLootForeverDB`: `enabled`, `counts`, `names`.

## Where the numbers come from

No event gives an addon the other players' choices for a roll, so the addon reads two things:

1. **The loot chat lines** (`CHAT_MSG_LOOT`, and `CHAT_MSG_SYSTEM`): "Elex has selected Need for:
   [item]", "You passed on: [item]", "Bob automatically passed on: ...", the "Need Roll - 87 for
   [item] by Elex" lines, and the result lines (won, everyone passed). The patterns are made at
   load from the client's own format strings (`LOOT_ROLL_NEED`, `LOOT_ROLL_GREED`,
   `LOOT_ROLL_PASSED`, the `_SELF`, `_AUTO`, `DISENCHANT` and `TRANSMOG` forms where the client has
   them, `LOOT_ROLL_WON`, `LOOT_ROLL_ALL_PASSED`, ...), so any locale works, including ones that
   reorder the arguments (`%1$s`). Each line names the item; it is matched to the open roll of
   that item (`GetLootRollItemLink`). When two rolls of the same item are open, a line goes to the
   oldest one where that player has not chosen yet.
2. **The loot history** (`C_LootHistory`, `LOOT_HISTORY_UPDATE_DROP`), where the client fills it:
   each player's roll state for a drop, matched to the open roll by item link. It is kept per boss
   encounter, so on trash it says nothing and the chat lines do the work.

A roll is forgotten when its result line arrives, when the client cancels all rolls, or once its
roll time is over. The client closes your roll frame as soon as you have chosen, so the numbers
are mainly there to see what the others picked before you choose.

`/bloot status` shows how many chat patterns were built from the client's strings, whether the
loot history is there, and how many rolls are open.

## Commands

`/bloot` or `/betterlootforever`:

| Command | Does |
|---|---|
| `/bloot` or `/bloot help` | list the commands |
| `/bloot on` / `off` | master switch |
| `/bloot counts on\|off` | the numbers on the buttons (`counts`) |
| `/bloot names on\|off` | the names in the button tooltips (`names`) |
| `/bloot test` | the preview window and the parse results |
| `/bloot status` | version, settings, patterns, open rolls, the last error |

## With BetterForever (required)

The addon lists `BetterForever` under `## Dependencies`: install the `BetterForever` folder next to
it. It is built on the hub's library (`BetterForever.NewAddon`): the switches above are registered
once and give the slash commands, the **Loot** submenu in the hub's minimap menu and the page under
**Esc > Options > AddOns > Better Forever**, with a short intro at the top.
`BetterLootForeverAPI` (`version`, `StatusLine`, `MenuEntries`, `AddMenuEntries`,
`SetMinimapHidden`, `Intro`) is what the hub reads. The hub lists it from BetterForever 3.0.2.

## How it is built

The roll frames are Blizzard's (`GroupLootFrame1`..`4` in `GroupLootContainer`, each with `rollID`
and the buttons `LootButtonContainer.NeedButton`, `GreedButton`, `PassButton` and
`TransmogButton`; `frame.NeedButton` and `GroupLootFrame1NeedButton` are tried as fallbacks). No
Blizzard function is replaced. The number sits on a frame of the addon's own, a child of the button
with the mouse off, so every click still reaches the button; the tooltip line is added with
`HookScript("OnEnter")`, after Blizzard's own handler. Every handler runs in `pcall`, every client
API is checked with `type(...)` first, and a secret value (chat text and names can be secret in
some contexts) is never compared or tested: such a line is skipped. It ships a `_Camelot` TOC and a
plain fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).
