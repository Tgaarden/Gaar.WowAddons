# BetterMailForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001): mailbox
helpers. It needs no other addon or library and is not part of the Gaar suite. Every feature
is its own setting (`/bmail <feature> on|off`) and there is a master switch (`/bmail on|off`).

## Features

| Feature | Command word | Default | What it does |
|---|---|---|---|
| Open All | `openall` | on | An **Open All** button at the top of the inbox. Takes money, then items, from one mail at a time and waits for `MAIL_INBOX_UPDATE` / `MAIL_SUCCESS` between actions (0.3 s apart at the fastest). **Shift-click: money only.** Click again (the button reads *Stop*) to stop. Prints a summary: gold taken, item count. |
| Delete empty | `deleteempty` | off | With Open All: deletes mails that are empty after taking. See the safety rules. |
| Recipient list | `recipients` | on | A `v` button right of the **To:** box on the Send Mail tab: your own characters on this realm and faction (every character that logs in is recorded) and the last 15 recipients (account-wide, recorded when a letter is sent). Click a name to fill in **To:**. |
| Alt-click to attach | `sendmulti` | on | On the Send Mail tab, **Alt-click** an item in your bags to attach it. **Ctrl+Alt-click** attaches up to 12 stacks of the same item. Out of combat only. |
| New mail notice | `notice` | on | A chat line at login and when new mail arrives, with the senders from `GetLatestThreeSenders` (plain values only). |

## Safety rules

- **COD is never paid.** A mail with a cash-on-delivery amount is skipped by Open All and counted
  in the summary (`N COD skipped`). Take it by hand if you want it.
- **Open All stops** when the bags are full (`ERR_INV_FULL`), when you click *Stop*, when you turn
  Open All off, and when the mailbox closes. A mail that does not answer three times is skipped.
- **Delete empty** deletes a mail only when all of this holds: it has no money, no item and no
  COD; it has been read; you cannot reply to it (a system or auction house mail); and it is not
  from a GM. **A letter from a player is never deleted**, with or without a text. It is off by
  default and only runs during Open All.
- Attaching never sends anything; it only fills the attachment slots. Items that cannot be sent
  (soulbound, say) are put back.

## Commands

| Command | Does |
|---|---|
| `/bmail` or `/bmail help` | Help |
| `/bmail on`, `/bmail off` | Master switch |
| `/bmail openall\|deleteempty\|recipients\|sendmulti\|notice on\|off` | One feature on or off (without `on`/`off` it prints the state) |
| `/bmail open` | Run Open All, the same as the button (mailbox must be open) |
| `/bmail status` | Version, master and every feature, mailbox open or closed, Open All running or idle, remembered names, the last error caught |

Also `/bettermailforever`. Settings are saved account-wide in `BetterMailForeverDB`
(the features, `recent`, `alts`).

## With BetterGaarForever (optional)

The hub talks to this addon only through `BetterMailForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `on · openall, recipients, sendmulti, notice` |
| `MenuEntries()` | The options as plain data: a master checkbox, a divider and one checkbox per feature |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button |

## How it stays out of the way

- Blizzard code is only followed (`hooksecurefunc` on `SendMail`, `HandleModifiedItemClick` and
  `ContainerFrameItemButton_OnModifiedClick`, `HookScript` on `SendMailFrame`), never replaced.
- Every handler runs in `pcall` (the last error is kept for `/bmail status`), every client API is
  checked with `type(...) == "function"`, and a secret value is treated as no value.
- The Open All button sits at the top left of the inbox and the recipient button right of the
  **To:** box. Neither can be checked here without the client, so move them if they collide with
  another addon.

## License

MIT, see [LICENSE](LICENSE).
