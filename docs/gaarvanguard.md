# GaarVanguard

Captures the account's characters and their loot in game and hands them to the **Vanguard
website** as a copy-paste string, and accepts the website's own string back. The website is the
counterpart to this addon: the addon is the *source of truth for what you own and looted*, the
website is the *source of truth for vanguards, goals and instances*.

Both directions use the same envelope:

```
VGD1:<base64 of a JSON document>
```

`VGD1` is the format tag (Vanguard, version 1). The payload is a JSON object whose `k` field
says which of the two shapes it is. The base64 and JSON codecs are self-contained in
`GaarVanguard.lua` — no external libraries.

## `k = "chars"` — addon → website (the Export box)

Produced by `/gaarvanguard export`. One document holds **every character on the account** that
has logged in with the addon installed.

**This is the canonical contract with the website — the field names below must match exactly.**
The website's VGD1 `chars` importer reads these names; a mismatch is silently dropped (the live
Forever beta bug where the site showed *Level UNDEFINED* and no class/gear was exactly this — the
addon emitted `class`/`level`/numeric `slot` while the site wanted `cls`/`lvl`/slot-name, and
equipment was empty because it was read from cached events instead of scanned live).

```json
{
  "k": "chars",
  "chars": [
    {
      "name": "Thrall",
      "realm": "Nostalrius",
      "race": "Orc",
      "cls": "Shaman",
      "lvl": 60,
      "spec": "Enhancement",
      "guild": "Warsong Clan",
      "guildRank": "Warchief",
      "classFile": "SHAMAN",
      "faction": "Horde",
      "professions": [
        { "name": "Mining", "skill": 300, "max": 300 },
        { "name": "First Aid", "skill": 225, "max": 300 }
      ],
      "equipment": [
        { "slot": "MainHand", "itemId": 19019, "quality": 5, "name": "Thunderfury" }
      ],
      "loot": [
        { "item": "|Hitem:19019|h[Thunderfury]|h", "itemId": 19019, "quality": 5,
          "kind": "need", "winner": "Thrall", "when": 1727090000 }
      ]
    }
  ]
}
```

Canonical field names (each char object):

| Field | Type | Notes |
|---|---|---|
| `name` | string, required | character name |
| `realm` | string, optional | realm name |
| `race` | string | e.g. `"Gnome"`; the website derives faction from race |
| `cls` | string | localized class, e.g. `"Mage"` (was `class`) |
| `lvl` | number | character level (was `level`) |
| `spec` | string, optional | talent tab with most points (Classic) or active spec (retail) |
| `guild` | string, optional | guild name, or absent when not in a guild |
| `guildRank` | string, optional | guild rank name |
| `professions` | array | `{ name, skill, max }` per non-header skill line (`skill` was `rank`) |
| `equipment` | array | `{ slot, name, itemId, quality }` — **`slot` is the slot NAME string** |
| `loot` | array | `{ item, itemId, quality, kind, winner, when }` (see below) |

`equipment[].slot` is one of the canonical slot names, never a numeric inventory id:

```
Head Neck Shoulder Shirt Chest Waist Legs Feet Wrist Hands
Finger1 Finger2 Trinket1 Trinket2 Back MainHand OffHand Ranged Tabard
```

More field notes:

- `chars` is an **array**; each element is one character, keyed internally by `"Name-Realm"`.
- `classFile` (locale-independent token, `SHAMAN`) and `faction` are emitted as harmless extras
  alongside the canonical fields; the website may ignore them.
- `professions` is **every non-header skill line**, not only trade skills — the website can
  filter. Each has `name`, `skill`, `max`.
- `equipment` covers inventory slots 1–19. `itemId` and `quality` may be absent for an item the
  client had not cached at scan time; `name` falls back to the raw item link.
- `loot` is the last 100 rows for that character (see below). `item` is the full item link,
  `when` is a Unix timestamp (`time()`).

### Live scan at export (do not trust the cache)

On **every export** the current character is re-scanned from the live game state right before the
string is built — level (`UnitLevel`), race/class, faction, guild + rank (`GetGuildInfo`), spec,
professions, and **equipment** by looping equip slots 1–19 via `GetInventoryItemLink` (each id
mapped to its canonical slot name). This means the export reflects the live character **even when
the SavedVariables DB is empty**, which is the Forever-beta case (that client does not persist
addon SavedVariables and the equipment events may never have fired). Other characters still come
from the DB where it persists (Era). Every reader is wrapped in `pcall`, so a missing or reshaped
API on one client leaves a blank field instead of erroring.

### What else drives capture (keeps the DB fresh in-session / on Era)

| Event | Refreshes |
|---|---|
| `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD` | the whole record |
| `PLAYER_EQUIPMENT_CHANGED` | equipment |
| `PLAYER_LEVEL_UP` | the whole record |
| `SKILL_LINES_CHANGED` | professions |
| `CHARACTER_POINTS_CHANGED` | spec |
| `PLAYER_GUILD_UPDATE` | guild + rank |

### How loot is captured

Independently of GaarLooter (that addon need not be installed). The `LOOT_ROLL_*` chat lines
carry other players' choices and the winner — no event does — so patterns are derived from those
global format strings at load and matched to the open roll by item link, the same technique
GaarLooter uses. On a completed roll one row is stored with `kind` set to the **winner's
choice** (`need`/`greed`) and `winner` set to who won. Items you pick up yourself are stored as
`kind = "pickup"`, `winner` = you. The list is capped at the last 100 rows per character
(`GaarVanguardDB.maxLoot`).

## `k = "sync"` — website → addon (the Import box, stubbed)

Produced by the website, pasted into `/gaarvanguard import`. Expected shape (the website owns
this):

```json
{
  "k": "sync",
  "vanguards": [ { "id": 1, "name": "Weekend Warband" } ],
  "goals":     [ { "title": "Clear Molten Core" } ],
  "instances": [ { "name": "Molten Core" } ],
  "mapping":   { "Thrall-Nostalrius": 1 }
}
```

For this first draft the Import box only proves the round trip: it strips `VGD1:`,
base64-decodes, JSON-decodes, stores the result under `GaarVanguardDB.sync`, and prints a short
summary (kind, and the counts + titles/names of any `vanguards`, `goals`, `instances`, plus the
mapping size). A malformed string reports the parse error and stores nothing. The full in-game
view of vanguards/goals/instances comes later.

## SavedVariables shape

`GaarVanguardDB`:

```
GaarVanguardDB = {
  chars = {
    ["Name-Realm"] = {
      name, realm, race, cls, classFile, lvl, faction, spec, guild, guildRank,
      professions = { { name, skill, max }, ... },
      equipment   = { { slot, itemId, quality, name }, ... },  -- slot is the slot NAME string
      loot        = { { item, itemId, quality, kind, winner, when }, ... },  -- last 100
    },
    ...
  },
  maxLoot = 100,
  sync = <last decoded website sync document, or absent>,
}
```

Records written by an older addon version (numeric `slot`, `class`, `level`, profession `rank`)
are migrated to the canonical names on the way out, so a mixed DB still exports cleanly.

## Slash commands

- `/gaarvanguard` or `/gaarvg` — prints usage and opens the export box
- `/gaarvanguard export` — the VGD1 chars string
- `/gaarvanguard import` — paste the website's sync string
- `/gaarvanguard capture` — recapture the current character now
- `/gaarvanguard config` — settings under **Gaar → Vanguard**
- `/gaarvanguard wipe` — clear the whole database

## Client support

Targets Forever (Mainline TOC, interface `120100, 16001`) and Classic Era (Vanilla TOC,
`11509`), matching the rest of the suite. Per `docs/forever-client-findings.md` the only globals
Forever removed that the suite touches are three spellbook skill-line calls, which this addon
does not use. Note the same document's finding that **Forever does not currently persist addon
SavedVariables** — so on that client the export reflects the live session, and captured data may
not survive a reload until Blizzard fixes persistence.
