# BetterChatForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001): chat tweaks,
each one individually switchable. It needs BetterForever, the family hub, and no other addon or library and is not part of the Gaar
suite.

## Features

Every feature has a saved setting (account-wide, `BetterChatForeverDB`), a `/bchat <feature> on|off`
command and a checkbox in the BetterForever menu. A master switch turns them all off.

| Feature | Default | What it does |
|---|---|---|
| `shortChannels` | on | `[Guild]` becomes `[G]`, `[Party]` `[P]`, `[Party Leader]` `[PL]`, `[Raid]` `[R]`, `[Raid Leader]` `[RL]`, `[Raid Warning]` `[RW]`, `[Officer]` `[O]`; numbered channels `[2. Trade - City]` become `[2]`, General `[1]`, LookingForGroup `[LFG]`. Blizzard's `CHAT_*_GET` globals are rewritten (originals restored when off); numbered channels are shortened in each chat frame's `AddMessage`. |
| `classColors` | on | Blizzard's own "colour names by class" setting for say, yell, emote, guild, officer, whisper, party, raid, instance and channels 1-10 (`SetChatColorNameByClass`). Types it flipped on are flipped back off when the feature is switched off. |
| `timestamps` | off | Blizzard's `showTimestamps` cvar, drawn as a soft grey `[HH:MM]`. Switching it off sets the cvar to `none` again, but only if this addon set it. |
| `urlCopy` | on | `http(s)://...`, `www....` and `domain.tld/...` in plain text become clickable links; a click opens a small box with the URL selected for Ctrl+C. Existing hyperlinks (items, spells) are never touched. |
| `copyChat` | on | A small `C` button on each chat frame, or `/bchat copy [n]`: a scrollable edit box with the last 200 lines of that frame as plain text (colour codes and links stripped). |
| `whisperSound` | on | A short sound on incoming whispers and Battle.net whispers, never for your own outgoing ones. |
| `stickyChannels` | on | Remembers the last used chat type for say, emote, yell, party, raid, guild, officer, whisper, Battle.net whisper, instance and channels (`ChatTypeInfo[x].sticky = 1`). |
| `arrowKeys` | on | Arrow keys move the cursor in the chat edit box without Alt (`SetAltArrowKeyMode(false)`). |

## Commands

| Command | Does |
|---|---|
| `/bchat` or `/betterchatforever` | Help |
| `/bchat on`, `/bchat off` | Master switch |
| `/bchat <feature> on`, `/bchat <feature> off` | Switch one feature (`shortChannels`, `classColors`, `timestamps`, `urlCopy`, `copyChat`, `whisperSound`, `stickyChannels`, `arrowKeys`) |
| `/bchat copy [n]` | Open the copy window for chat frame `n` (default: the selected one) |
| `/bchat status` | Version, master switch, every feature and the last error caught |

## Secret text

On the 12.x engine a chat message, its sender and stored history lines can be secret values,
especially in instances and in combat. A secret value is never compared, tested, matched or
`gsub`'ed: the filter and the `AddMessage` wrapper pass it on untouched, the copy window skips such
lines (and says how many), and the whisper sound never reads the event arguments.

## With BetterForever (required)

Since 1.0.1 this addon lists `BetterForever` under `## Dependencies`: install the `BetterForever` folder next to it, or the client will not load this addon. BetterForever also gives it a page under **Esc > Options > AddOns > Better Forever**, built from the same `MenuEntries()` as the hub's menu, with a short intro at the top; that intro comes from `Intro()`, a field the API table gained in 1.0.1 (it is also the first line of the slash command's help).

Since 1.0.2 it takes its shared helpers from BetterForever's library (`BetterForever`, `Lib.lua`) instead of carrying its own copies: the chat prefix, the secret-value check (`IsSecret`) and the drawing of its menu (`RenderMenu`). Nothing you see or set changed.

[BetterForever](../BetterForever/README.md) is the family hub with one minimap button. The
hub talks to this addon only through `BetterChatForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `on · 7/8 features` |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, submenu }`, `{ divider }`): the master switch and one checkbox per feature |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide |

## How it stays out of the way

- Blizzard code is followed, not replaced. Only strings and flags are written (`CHAT_*_GET`,
  `ChatTypeInfo[x].sticky`, `CHAT_TIMESTAMP_FORMAT`) plus a wrapper on each chat frame's
  `AddMessage` that always calls the original.
- Every client API is checked with `type(...) == "function"` before use and every handler runs in
  `pcall` (the last error is kept for `/bchat status`).
- Saved variables are read at `ADDON_LOADED`; unknown keys are dropped.

## License

MIT, see [LICENSE](LICENSE).
