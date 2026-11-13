# BetterMerchantForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). When you open a
merchant it sells your grey items and repairs your gear. Every feature has its own switch. It
needs no other addon or library, and it is not part of the Gaar suite.

## What it does

- **Sell junk** (on by default). At a merchant, sells every grey (quality 0) item in your bags,
  out of combat, 3 items every 0.2 s so the server never throttles it. It stops when the merchant
  closes or combat starts. Items with no sell price are left alone.
- **BetterBagsForever locks are respected.** An item you locked in BetterBagsForever (Alt + click)
  is never sold. BBF has no API for this, so the addon reads its per-character saved table
  `BetterBagsForeverCharDB.lockedItems[itemID]`, read-only, and checks it again right before each
  sale. If BBF later gets `BetterBagsForeverAPI.IsItemLocked(itemID)`, that is used first.
- **Ask first** (`sellJunkConfirm`, off by default). A popup says how many items and roughly what
  they are worth before anything is sold.
- **Auto repair** (on by default). Repairs everything when the merchant can repair, the cost is
  above zero and you can pay it. If you cannot pay, it says what the repair would cost.
- **Guild repair** (`guildRepair`, off by default). Tries guild funds first when the client offers
  `CanGuildBankRepair` and the guild's withdraw allowance covers the cost; if the guild refuses,
  your own money is used.
- **Summary** (on by default). One chat line, e.g. `sold 12 junk items for 3s 40c; repaired for 1g 2s`.
  With it off, each part prints its own line.
- **Master switch.** `/bmerch off` turns all of the above off (`/bmerch sell` still works).

Settings are saved account-wide in `BetterMerchantForeverDB`: `enabled`, `sellJunk`,
`sellJunkConfirm`, `autoRepair`, `guildRepair`, `summary`.

## Commands

`/bmerch` or `/bettermerchantforever`:

| Command | Does |
|---|---|
| `/bmerch` or `/bmerch help` | list the commands |
| `/bmerch on` / `off` | master switch |
| `/bmerch junk on\|off` | sell junk (`sellJunk`) |
| `/bmerch confirm on\|off` | ask before selling (`sellJunkConfirm`) |
| `/bmerch repair on\|off` | auto repair (`autoRepair`) |
| `/bmerch guild on\|off` | guild funds first (`guildRepair`) |
| `/bmerch summary on\|off` | one-line summary |
| `/bmerch sell` | sell the junk now, while a merchant is open |
| `/bmerch status` | settings, BBF lock count and the last result |

## BetterGaarForever

`BetterMerchantForeverAPI` (`version`, `StatusLine`, `MenuEntries`, `AddMenuEntries`,
`SetMinimapHidden`) lets the BetterGaarForever hub list these switches in its menu. The addon runs
the same without the hub.

## How it is built

No Blizzard function or frame is replaced or hooked. Selling is `C_Container.UseContainerItem`
(which sells at a merchant), repairing is `RepairAllItems`. Every handler runs in `pcall`, every
client API is checked with `type(...) == "function"` first, and a secret value is never compared
or tested. It ships a `_Camelot` TOC and a plain fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).
