# GaarChatForever

> Formerly **BetterChatForever**. The folder is now `GaarChatForever` as well; the update also ships a tiny `BetterChatForever` folder, a
> settings bridge that moves your old settings over on the first login (each character on its own
> first login). It is safe to delete after logging in once on each character, and later updates drop it. The command is
> now `/gchat` (`/gaarchatforever`); the old `/bchat` and `/betterchatforever` still work.
> CurseForge: https://www.curseforge.com/wow/addons/gaarchatforever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001): chat tweaks,
each one individually switchable. It needs GaarForever, the family hub, and no other addon or library and is not part of the Gaar
suite.

## Features

Every feature has a saved setting (account-wide, `GaarChatForeverDB`), a `/gchat <feature> on|off`
command and a checkbox in the GaarForever menu. A master switch turns them all off.

| Feature | Default | What it does |
|---|---|---|
| `shortChannels` | on | `[Guild]` becomes `[G]`, `[Party]` `[P]`, `[Party Leader]` `[PL]`, `[Raid]` `[R]`, `[Raid Leader]` `[RL]`, `[Raid Warning]` `[RW]`, `[Officer]` `[O]`; numbered channels `[2. Trade - City]` become `[2]`, General `[1]`, LookingForGroup `[LFG]`. Blizzard's `CHAT_*_GET` globals are rewritten (originals restored when off); numbered channels are shortened in each chat frame's `AddMessage`. |
| `classColors` | on | Blizzard's own "colour names by class" setting for say, yell, emote, guild, officer, whisper, party, raid, instance and channels 1-10 (`SetChatColorNameByClass`). Types it flipped on are flipped back off when the feature is switched off. |
| `timestamps` | off | Blizzard's `showTimestamps` cvar, drawn as a soft grey `[HH:MM]`. Switching it off sets the cvar to `none` again, but only if this addon set it. |
| `urlCopy` | on | `http(s)://...`, `www....` and `domain.tld/...` in plain text become clickable links; a click opens a small box with the URL selected for Ctrl+C. Existing hyperlinks (items, spells) are never touched. |
| `copyChat` | on | A small `C` button on each chat frame, or `/gchat copy [n]`: a scrollable edit box with the last 200 lines of that frame as plain text (colour codes and links stripped). |
| `whisperSound` | on | A short sound on incoming whispers and Battle.net whispers, never for your own outgoing ones. |
| `stickyChannels` | on | Remembers the last used chat type for say, emote, yell, party, raid, guild, officer, whisper, Battle.net whisper, instance and channels (`ChatTypeInfo[x].sticky = 1`). |
| `arrowKeys` | on | Arrow keys move the cursor in the chat edit box without Alt (`SetAltArrowKeyMode(false)`). |
| `feed` | on | A scrolling chat feed (since 1.2.0), see below. |

## Chat feed

Like scrolling combat text, but for the chat you should not miss: whispers in and out (Battle.net
too), party, raid and instance chat (leaders and raid warnings included), and lines in say, yell,
emote or a public channel that say your character's name (a whole word, any case). Each message
comes in at the bottom of a small area at the left of the screen, the older ones slide up, and
every line fades out after 10 seconds; at most 8 lines are shown and the oldest is pushed out. With
the mouse over the feed it stops and every line is shown in full. Your own messages are left out,
except the whispers you send (`[To] Name: text`).

A line reads `[P] Name: text`: a short tag (`W` whisper, `To` your whisper, `BN` Battle.net whisper,
`P` party, `R` raid, `RW` raid warning, `I` instance, `@` your name was said), in the chat type's
own colour, with the sender's name in their class colour when the client knows it. Long lines wrap
to the width of the feed. A click on a line replies: a whisper (or Battle.net whisper) to that
person, or the edit box opened on that group chat type; for a mention, a whisper to the sender.

The regular chat frames are not touched: the feed only shows copies. Each kind (whispers, group,
mentions) has its own switch, and the feed's settings are saved with the others in
`GaarChatForeverDB`. In the menu and on the Options page they are under **Chat feed**: the three
kinds, locked, font size, scale, width, seconds on screen, test lines and reset.

## Commands

| Command | Does |
|---|---|
| Right-click a chat tab | A `GaarChat` submenu at the bottom of Blizzard's tab menu (menu tag `MENU_FCF_TAB`) with the same options as the GaarForever hub menu |
| `/gchat` or `/gaarchatforever` | Help |
| `/gchat on`, `/gchat off` | Master switch |
| `/gchat <feature> on`, `/gchat <feature> off` | Switch one feature (`shortChannels`, `classColors`, `timestamps`, `urlCopy`, `copyChat`, `whisperSound`, `stickyChannels`, `arrowKeys`) |
| `/gchat feed` | The feed's state and its commands |
| `/gchat feed on`, `/gchat feed off` | Switch the feed (the same as the `feed` feature) |
| `/gchat feed whispers\|group\|mentions on\|off` | Switch one kind of message in the feed |
| `/gchat feed unlock`, `/gchat feed lock` | Unlocked, the feed shows a dark area with a label: drag it to move it |
| `/gchat feed scale <50-200>` | Size of the feed in percent (default 100) |
| `/gchat feed font <8-32>` | Font size (default 14) |
| `/gchat feed width <200-800>` | Width in pixels (default 400) |
| `/gchat feed time <3-60>` | Seconds a line stays before it is gone (default 10) |
| `/gchat feed test` | Sample lines of every kind |
| `/gchat feed reset` | Position, scale, font size, width and time back to default |
| `/gchat copy [n]` | Open the copy window for chat frame `n` (default: the selected one) |
| `/gchat status` | Version, master switch, every feature and the last error caught |

## Secret text

On the 12.x engine a chat message, its sender and stored history lines can be secret values,
especially in instances and in combat. A secret value is never compared, tested, matched or
`gsub`'ed: the filter and the `AddMessage` wrapper pass it on untouched, the copy window skips such
lines (and says how many), and the whisper sound never reads the event arguments.

The chat feed checks every value it reads (message, sender, GUID, channel number) before it uses
it. A message whose text or sender is secret is still shown: the tag, the name and the text are
put in separate pieces of text by the client itself, on one line cut to the feed's width (its
wrapped height cannot be read). A secret message is never searched for your name, so mentions
only come from plain text, and a click on a whisper with a secret name falls back to "reply to the
last whisper".

## With GaarForever (required)

Since 1.0.1 this addon lists `GaarForever` (the GaarForever folder) under `## Dependencies`: install the `GaarForever` folder next to it, or the client will not load this addon. GaarForever also gives it a page under **Esc > Options > AddOns > Gaar Forever**, built from the same `MenuEntries()` as the hub's menu, with a short intro at the top; that intro comes from `Intro()`, a field the API table gained in 1.0.1 (it is also the first line of the slash command's help).

Since 1.0.2 it takes its shared helpers from GaarForever's library (`GaarForever`, `Lib.lua`) instead of carrying its own copies: the chat prefix, the secret-value check (`IsSecret`) and the drawing of its menu (`RenderMenu`). Nothing you see or set changed.

[GaarForever](../GaarForever/README.md) is the family hub with one minimap button. The
hub talks to this addon only through `GaarChatForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `on · 7/8 features` |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, slider, min, max, step, value, set }`, `{ text, submenu }`, `{ divider }`): the master switch, one checkbox per feature and the **Chat feed** submenu |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide |

## How it stays out of the way

- Blizzard code is followed, not replaced. Only strings and flags are written (`CHAT_*_GET`,
  `ChatTypeInfo[x].sticky`, `CHAT_TIMESTAMP_FORMAT`) plus a wrapper on each chat frame's
  `AddMessage` that always calls the original. The chat feed has its own frame and events and
  registers only the chat events of the kinds that are on; its animation is one `OnUpdate` that
  runs only while a line is shown.
- Every client API is checked with `type(...) == "function"` before use and every handler runs in
  `pcall` (the last error is kept for `/gchat status`).
- Saved variables are read at `ADDON_LOADED`; unknown keys are dropped.

## License

MIT, see [LICENSE](LICENSE).

## Support

If you enjoy this addon, you can [buy me a coffee](https://buymeacoffee.com/tgaarden) ☕
