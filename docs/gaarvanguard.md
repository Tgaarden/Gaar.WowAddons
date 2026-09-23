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

```json
{
  "k": "chars",
  "chars": [
    {
      "name": "Thrall",
      "realm": "Nostalrius",
      "race": "Orc",
      "class": "Shaman",
      "classFile": "SHAMAN",
      "level": 60,
      "faction": "Horde",
      "spec": "Enhancement",
      "professions": [
        { "name": "Mining", "rank": 300, "max": 300 },
        { "name": "First Aid", "rank": 225, "max": 300 }
      ],
      "equipment": [
        { "slot": 1, "itemId": 19019, "quality": 5, "name": "Thunderfury" }
      ],
      "loot": [
        { "item": "|Hitem:19019|h[Thunderfury]|h", "itemId": 19019, "quality": 5,
          "kind": "need", "winner": "Thrall", "when": 1727090000 }
      ]
    }
  ]
}
```

Field notes:

- `chars` is an **array**; each element is one character, keyed internally by `"Name-Realm"`.
- `classFile` is the locale-independent class token (`SHAMAN`), `class` the localized name.
- `spec` is the talent tab with the most points (Classic) or the active specialization
  (retail); it can be absent if neither API answers.
- `professions` is **every non-header skill line**, not only trade skills — the website can
  filter. Each has `name`, `rank`, `max`.
- `equipment` covers inventory slots 1–19. `itemId` and `quality` may be absent for an item the
  client had not cached at capture time; `name` falls back to the raw item link.
- `loot` is the last 100 rows for that character (see below). `item` is the full item link,
  `when` is a Unix timestamp (`time()`).

### What drives capture

| Event | Refreshes |
|---|---|
| `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD` | the whole record |
| `PLAYER_EQUIPMENT_CHANGED` | equipment |
| `PLAYER_LEVEL_UP` | the whole record |
| `SKILL_LINES_CHANGED` | professions |
| `CHARACTER_POINTS_CHANGED` | spec |

Every capture reader is wrapped in `pcall`, so an API missing or reshaped on one client leaves
a blank field instead of erroring.

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
      name, realm, race, class, classFile, level, faction, spec,
      professions = { { name, rank, max }, ... },
      equipment   = { { slot, itemId, quality, name }, ... },
      loot        = { { item, itemId, quality, kind, winner, when }, ... },  -- last 100
    },
    ...
  },
  maxLoot = 100,
  sync = <last decoded website sync document, or absent>,
}
```

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
