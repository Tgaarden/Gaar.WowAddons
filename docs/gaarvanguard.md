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
      "talents": [
        {
          "tab": "Arcane", "points": 0,
          "talents": [
            { "name": "Arcane Subtlety", "rank": 0, "max": 2, "tier": 0, "col": 0,
              "icon": "spell_holy_dispelmagic", "spellId": 11210 }
          ]
        },
        {
          "tab": "Fire", "points": 5,
          "talents": [
            { "name": "Improved Fireball", "rank": 5, "max": 5, "tier": 0, "col": 0,
              "icon": "spell_fire_flamebolt", "spellId": 11069 },
            { "name": "Ignite", "rank": 0, "max": 5, "tier": 1, "col": 1,
              "icon": "spell_fire_incinerate", "spellId": 11119 }
          ],
          "edges": [
            { "ft": 0, "fc": 0, "tt": 1, "tc": 1 }
          ]
        },
        { "tab": "Frost", "points": 0, "talents": [], "edges": [] }
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
| `spec` | string, optional | the talent tree with the most points spent — Vanilla tabs on Era, the `C_Traits` posX band mapped to the classic tab name (e.g. "Fire") on Forever; empty when nothing is spent or no name resolves |
| `talents` | array | the full talent build — one entry per tab: `{ tab, points, talents: [ { name, rank, max, tier, col, icon?, spellId? } ], edges: [ { ft, fc, tt, tc } ] }` (see below) |
| `guild` | string, optional | guild name, or absent when not in a guild |
| `guildRank` | string, optional | guild rank name |
| `professions` | array | `{ name, skill, max }` per real primary/secondary trade skill (`skill` was `rank`) |
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
- `professions` is the **real primary + secondary trade skills only** (Alchemy, Blacksmithing,
  Enchanting, Engineering, Herbalism, Leatherworking, Mining, Skinning, Tailoring,
  Jewelcrafting, Inscription, Cooking, First Aid, Fishing) — weapon skills, Defense, Unarmed,
  languages and riding are filtered out. Each has `name`, `skill`, `max`. See *How professions
  are read* below for the API path.
- `talents` is the **full talent build**, not just the spec name, so the website can render the
  whole calculator grid. It is an **array of trees/tabs** (3 for a normal class, in ascending-posX
  band order); each has `tab` (name), `points` (ranks spent in it) and `talents`, an array of
  **every** node in the tree (not only ranked ones — an unpurchased node is emitted with `rank: 0`
  so the grid is complete), ordered by `tier` then `col`. Each talent has `name`, `rank`, `max`,
  `tier`, `col`, and optionally `icon` and `spellId`:
  - On the **Forever** client (the calculator route, `ScanTalentsCalculator`): `tier` is the
    **0-based** row from the sorted-unique `posY` across the whole tree (top = 0), `col` is the
    **0-based** column from the sorted-unique `posX` within that tree's band (left = 0). `spellId`
    is the node's spell (omitted when unresolved). `icon` is a lowercase Wowhead icon basename
    (e.g. `"spell_fire_flamebolt"`) when `GetSpellTexture` returns a path string; it is **omitted**
    when the client returns a numeric fileDataID, and the website should then fall back to a generic
    icon + a Wowhead tooltip keyed on `spellId`.
  - On **Era** (the classic route, `ScanTalentsClassic`): `tier`/`col` come straight from
    `GetTalentInfo` (1-based) and `icon`/`spellId` are not emitted.
  - `spec` is the tree with the most points. If neither route resolves (an edge case), the
    purchased-only fallback (`ScanTalentsTraits`) is used. See *How talents are read* below.
- `talents[].edges` are the **prerequisite connector arrows** the calculator draws between talents,
  so the website can render the lines without needing node IDs. Each edge is expressed purely in the
  same grid coordinates as `talents`: `ft`/`fc` = the source node's `(tier, col)`, `tt`/`tc` = the
  target node's `(tier, col)`. They come from `C_Traits.GetNodeInfo(configID, nodeID).visibleEdges`
  (each entry's `targetNode`) on the **Forever** calculator route, resolved through the same
  tier/col mapping as the talents; identical edges are deduplicated and unresolvable endpoints are
  skipped. `edges` is **additive** — it is `[]` when the client exposes no edges (or on the Era /
  purchased-only routes, which do not emit edges), so an older record without it still renders.
- `equipment` covers inventory slots 1–19. `itemId` and `quality` may be absent for an item the
  client had not cached at scan time; `name` falls back to the raw item link.
- `loot` is the last 100 rows for that character (see below). `item` is the full item link,
  `when` is a Unix timestamp (`time()`).

### Live scan at export (do not trust the cache)

On **every export** the current character is re-scanned from the live game state right before the
string is built — level (`UnitLevel`), race/class, faction, guild + rank (`GetGuildInfo`), spec,
the full talent build, professions, and **equipment** by looping equip slots 1–19 via
`GetInventoryItemLink` (each id
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
| `CHARACTER_POINTS_CHANGED` | spec + full talent build |
| `PLAYER_GUILD_UPDATE` | guild + rank |

### How loot is captured

Independently of GaarLooter (that addon need not be installed). The `LOOT_ROLL_*` chat lines
carry other players' choices and the winner — no event does — so patterns are derived from those
global format strings at load and matched to the open roll by item link, the same technique
GaarLooter uses. On a completed roll one row is stored with `kind` set to the **winner's
choice** (`need`/`greed`) and `winner` set to who won. Items you pick up yourself are stored as
`kind = "pickup"`, `winner` = you. The list is capped at the last 100 rows per character
(`GaarVanguardDB.maxLoot`).

### How professions are read

Professions are **skill lines**, and the reader has to cope with two very different clients, so it
tries two API paths in turn (both `pcall`-guarded, scanned live at capture/export):

1. **Modern / retail-shaped (Forever, retail).** `GetProfessions()` returns the profession
   skill-line **indices** directly (primary 1, primary 2, archaeology, fishing, cooking, first
   aid). Each index is resolved with `GetProfessionInfo(index)` →
   `name, icon, skillLevel, maxSkillLevel, …`. This path returns only professions, so nothing has
   to be filtered, and there is no enumeration problem. Indices are pushed one at a time (not via
   a table literal) so a `nil` in the middle — e.g. cooking but no primary profession — does not
   truncate the list.

   **These are globals, not `C_TradeSkillUI` members.** The first version looked for
   `C_TradeSkillUI.GetProfessions`, which is nil on every client (that namespace only holds
   recipe/crafting calls), so the whole path bailed and Forever exported `"professions":[]`. The
   Forever binary carries `GetProfessions`/`GetProfessionInfo` as plain globals
   (`Usage: GetProfessionInfo(index)`), so the reader now uses the globals first and keeps the
   `C_TradeSkillUI` names only as an alias for any odd client that namespaces them. See
   `docs/forever-client-findings.md` → *Professions: read from the binary*.
2. **Skill-line fallback (Era via globals, Forever via `C_SkillInfo`).** `GetNumSkillLines()` +
   `GetSkillLineInfo(i)`. The trap this originally hit: **a collapsed skill header hides its child
   skill lines from enumeration**, so a profession under a collapsed header reads as absent and
   the list came back empty. The fix expands every header first, reads, then re-collapses the
   headers that were collapsed (found by name, re-scanning per collapse because each collapse
   renumbers the rows) so the player's Skills window is left as it was. This path enumerates
   *every* skill line, so it filters to the real trade skills by name.

   **On Forever these calls moved namespace and shape.** Era has the bare globals returning
   `name, isHeader, isExpanded, rank, …`; Forever has no such globals and instead exposes
   `C_SkillInfo.GetSkillLineInfo(i)`, which returns a single **table**
   (`name, isHeader, isHeaderExpanded, rank, maxRank, …`), with `ExpandSkillHeader`/
   `CollapseSkillHeader` under the same namespace. A set of `SkillLine_*` accessors normalises both
   shapes to the Era-style tuple so the scanner reads one shape. `GetNumSkillLines` is tried under
   `C_SkillInfo` then as a global (the binary does not settle which Forever uses).

An empty scan leaves any previously captured profession list in place rather than wiping it.

### How talents are read

The **full talent build** (not just the spec name) is captured live at capture/export, `pcall`-guarded,
trying the readers in order and using whichever the client exposes:

1. **Classic talent API (Era only).**
   `GetNumTalentTabs()` + `GetTalentTabInfo(tab)` → `name, icon, pointsSpent`; then, per tab,
   `GetNumTalents(tab)` + `GetTalentInfo(tab, i)` → `name, icon, tier, column, rank, maxRank, …`
   (the classic signature). **Every** talent is kept — including rank-0 ones, so the tree is
   complete — and `rank`/`max` are always emitted. Tabs are ordered by tab index; talents within a
   tab by `tier` then `col`. The resulting shape is
   `talents = [ { tab, points, talents: [ { name, rank, max, tier, col } ] } ]` and `spec` is set to
   the tab with the most points spent.
2. **Forever full calculator grid (`ScanTalentsCalculator`, `C_ClassTalents` + `C_Traits`).** The
   classic tab globals are **gone on Forever**, and the probes ruled out `C_SpecializationInfo`
   (class-level: name = the class, 0 points), the `C_SkillInfo` Arcane/Fire/Frost lines (all rank 1/1),
   **and C_Traits subtrees** (none exist on this client — no `subTreeID` on the config, tree, or any
   node). What is deterministic is node **`posX`**: the one class trait tree (Mage → treeID 1112, 54
   nodes) lays its three Vanilla trees out as three horizontal `posX` bands (low ≈ 1020–2820 = Arcane,
   mid ≈ 5020–6820 = Fire, high ≈ 9080–10880 = Frost), confirmed because the purchased node 105795
   (posX 6220, mid band) resolves to spellID 11069 "Improved Fireball", a Fire talent. The reader walks
   `C_ClassTalents.GetActiveConfigID()` → `C_Traits.GetConfigInfo(configID).treeIDs` →
   `C_Traits.GetTreeNodes(treeID)` → `C_Traits.GetNodeInfo(configID, nodeID)` over **every** node
   (purchased or not), clusters every node's `posX` into 3 bands (split at the two largest gaps), and
   maps each band left→right to a classic tab name via a static `CLASS_TREE_NAMES[classToken]` table.
   For each node it emits `name`, `rank` (= `ranksPurchased`, 0 if unpurchased), `max` (= `maxRanks`),
   `tier` (0-based row from the sorted-unique `posY` across the whole tree), `col` (0-based column from
   the sorted-unique `posX` within the band), and — when they resolve — `spellId` and `icon`. Names,
   spellIDs and icons come from the entry → definition chain (`GetEntryInfo` → `GetDefinitionInfo` →
   `spellID`; name via `C_Spell.GetSpellName`/`GetSpellInfo`; icon via `GetSpellTexture`). Each tree's
   `points` is the sum of `ranksPurchased` in it; `spec` is the band with the most purchased ranks
   (e.g. `"Fire"`). This is the route the website renders the calculator from.
3. **Forever purchased-only summary (`ScanTalentsTraits`, fallback).** If the calculator route returns
   nil (clustering does not yield exactly 3 bands, or the class is not in `CLASS_TREE_NAMES`), the
   reader falls back to the earlier purchased-only band summary — one tab per band carrying only the
   purchased talents' resolved names — and, failing that, the subtree / dominant-purchased-talent-name
   grouping. Exported only when every tree carries a real name.
4. **Empty.** If nothing resolves a real name, `spec` and `talents` are left empty — never invented.

An empty scan leaves any previously captured build in place rather than wiping it. A character with
no points spent anywhere legitimately reports **no** spec — none is ever invented.

Because WoW cannot be run from the build environment, the readers are derived from the client binaries
(`strings` diff, Forever vs Era) and the in-game probe, plus a stubbed-API luajit check of the
selection logic. See *Talents / spec* in `docs/forever-client-findings.md` for the live findings.

### Confirming the profession + talent API in game: `/gaarvanguard probe`

Because WoW cannot be run from the build environment, the wiring above is inferred from the client
binary and needs one in-game confirmation. `/gaarvanguard probe` (also the **Probe prof + talents**
button under Gaar → Vanguard) dumps to chat **and** into a copyable box, for the current character:
`WOW_PROJECT_ID`/interface/build; whether `GetProfessions`/`GetProfessionInfo` exist and what they
return live; the `C_TradeSkillUI` alias check; each skill-line reader (global vs `C_SkillInfo`, plus
the table's keys); a full dump of every skill line (index, name, isHeader, isExpanded, skill/max,
and a `PROFESSION` tag) after expanding headers; the extra namespaces (`C_ProfSpecs`,
`C_CraftingOrders`, `C_Traits`); and the resolved `ScanProfessionsModern` / `ScanProfessionsClassic`
/ `CaptureProfessions` output. It is read-only and fully `pcall`-guarded. Paste the box back to
finish confirming the paths.

The same command also dumps a **talent probe**, extended after the live findings above to locate where
the Vanilla per-tree points live:

- **Classic talent globals** (`GetNumTalentTabs` / `GetTalentTabInfo` / `GetNumTalents` /
  `GetTalentInfo`) and, when present, each tab's name / points / talent count with the live
  `GetTalentInfo(tab, 1)` return.
- **The spec namespace** — `GetSpecialization` / `GetSpecializationInfo` / `GetNumSpecializations`
  globals, `C_SpecializationInfo` and its members, `Spec_GetNum()`, the active `GetSpecialization()`
  index, `GetSpecializationInfo(i)` (name / points / specId) for every entry, and whether return 1 is
  a **tuple or a table**. (On Forever this is class-level: one entry, name = the class, 0 points.)
- **`C_ClassTalents`** — every member, `GetActiveConfigID()`, `GetConfigIDsBySpecID()`,
  `GetHasStarterBuild` / `GetStarterBuildActive`, and `GetTraitTreeForSpec(activeSpec)`.
- **`C_Traits`** — every member and, from the active config id: `GetConfigInfo` (all fields), each
  tree's `GetTreeInfo` and its `subTreeIDs` (`GetSubTreeInfo` for each), and, for **every purchased
  node** (`ranksPurchased`/`activeRank` > 0): the **complete `GetNodeInfo` table**, its
  `GetSubTreeInfo(subTreeID).name`, each `entryID` → `definitionID` → `GetDefinitionInfo`
  (`overrideName`, `spellID`) with the resolved spell name, and the final `ResolveNodeTalentName`; plus
  the per-tree rank total. Then the raw `ScanTalentsTraits` result (grouping, points, `named` flag,
  resolved talent names) before the export gate.
- **Raw `C_SkillInfo` skill-line tables** — the full field dump (`KV`) of every non-header skill line.
- **posX band mapping** — the class token, the `CLASS_TREE_NAMES` row, the three computed band ranges
  (min/max, each labelled with its tab), each purchased node's `posX` + assigned band + resolved name,
  the per-band summed ranks, and the dominant band → tab name. This is the line that confirms `"Fire"`.
- The **path used** (`classic tabs` / `Forever trait graph` / `none`) and the resolved `spec` +
  `talents`.

It is read-only and fully `pcall`-guarded (any skill headers it expands are restored). **If spec still
does not resolve on Forever, paste the talent section back** — the band mapping and node dump will pin
the read, and the reader can then be finalised.

**Spec** is read as *the talent tree with the most points spent*: on Era via the classic
`GetNumTalentTabs`/`GetTalentTabInfo` tabs, on Forever via the `C_ClassTalents` / `C_Traits` trait
graph — the **posX band** (left→right = Arcane/Fire/Frost, mapped via `CLASS_TREE_NAMES`) with the most
purchased node ranks, with the subtree / dominant-purchased-talent name as a fallback — and only when a real
name resolves. A character with no points spent, or one whose purchased node resolves to no name,
legitimately reports no spec; none is invented.

## `k = "sync"` — website → addon (the Import box + the in-game view)

Produced by the website, pasted into `/gaarvanguard import`. **The canonical shape is the
website's `encodeSync()` in `Vanguard/src/lib/protocol.ts`** — the addon reads exactly those
short field names. Sync is account-level and asymmetric: it carries the player's Vanguards,
their goals, a members/readiness summary and the player's own character→Vanguard/goal mapping.
It deliberately does **not** carry gear/stats back (the addon already has those).

```json
{
  "k": "sync",
  "vanguards": [ { "name": "Weekend Warband", "tag": "WKND", "faction": "Horde", "type": "PvE" } ],
  "goals":     [ { "vg": "WKND", "t": "Clear Molten Core", "i": "MC", "s": "Ready" } ],
  "members":   [ { "vg": "WKND", "name": "Thrall", "ready": 3, "total": 3 } ],
  "mapping":   [ { "char": "Thrall", "vanguard": "Weekend Warband", "goals": ["Clear Molten Core"] } ]
}
```

Field reference (what the addon reads):

| Path | Meaning |
|---|---|
| `vanguards[].name` / `.tag` | Vanguard name and short tag |
| `vanguards[].faction` / `.type` | `Alliance`/`Horde`, `PvE`/`PvP` |
| `goals[].vg` | tag of the Vanguard the goal belongs to |
| `goals[].t` | goal title |
| `goals[].i` | linked instance code (optional; absent when the goal has no instance) |
| `goals[].s` | status: `Waiting`, `Ready` or `Done` |
| `members[].name` | member character name (readiness summary) |
| `members[].ready` / `.total` | how many tracked instances the member is Ready on, out of the total |
| `mapping[].char` | one of the player's own characters |
| `mapping[].vanguard` | that character's Vanguard name (optional) |
| `mapping[].goals` | titles of the goals that apply to that character |

The decoder is deliberately tolerant: the longhand `goals[].title` / `.status` / `.instanceCode`
are accepted as fallbacks, non-table entries and missing arrays are skipped, and every reader is
`pcall`-guarded so a reshaped or partial document renders what is present rather than erroring.

**The Import box** strips `VGD1:`, base64-decodes, JSON-decodes, stores the result under
`GaarVanguardDB.sync`, prints a short summary, and then opens/refreshes the in-game view (below)
so the pasted data is visible at once. A malformed string reports the parse error and stores
nothing.

### The in-game view (Phase 2)

`/gaarvanguard` (or **Gaar → Vanguard → Open Vanguard view**) opens a movable, closable,
scrollable window (`BackdropTemplate`, registered in `UISpecialFrames`, drag by the title bar,
close button, mouse-wheel scroll) that renders `GaarVanguardDB.sync` read-only:

- **Your Vanguards** — name, `[tag]`, and `faction · type`.
- **Goals** — title, coloured status (Waiting/Ready/Done), the linked instance code when present,
  the owning Vanguard tag, and **Your characters:** the player's characters the goal applies to
  (from `mapping`).
- **Instances / readiness** — the distinct instances the goals track, then each member's
  `ready/total`, highlighting a member who is **GO** (fully ready). The sync carries no
  per-instance GO flag, only the per-member summary, so GO is shown per member.
- **My characters** — for each mapped character, its Vanguard and the goals that apply.
- **Empty state** — when there is no `sync` yet, the window explains: Export from the website's
  Addon sync page and paste the code into the Import box.

The view is display-only (Phase 2 writes nothing) and toolbar buttons open the Export/Import
boxes without leaving it.

## SavedVariables shape

`GaarVanguardDB`:

```
GaarVanguardDB = {
  chars = {
    ["Name-Realm"] = {
      name, realm, race, cls, classFile, lvl, faction, spec, guild, guildRank,
      talents     = { { tab, points, talents = { { name, rank, max, tier, col }, ... } }, ... },
      professions = { { name, skill, max }, ... },
      equipment   = { { slot, itemId, quality, name }, ... },  -- slot is the slot NAME string
      loot        = { { item, itemId, quality, kind, winner, when }, ... },  -- last 100
    },
    ...
  },
  maxLoot = 100,
  sync = <last decoded website sync document (k="sync"), or absent>,  -- rendered by the in-game view
}
```

Records written by an older addon version (numeric `slot`, `class`, `level`, profession `rank`)
are migrated to the canonical names on the way out, so a mixed DB still exports cleanly.

## Slash commands

- `/gaarvanguard` or `/gaarvg` — open the in-game Vanguard view (the synced goals/instances)
- `/gaarvanguard view` — same as above, explicitly
- `/gaarvanguard export` — the VGD1 chars string
- `/gaarvanguard import` — paste the website's sync string (opens the view on success)
- `/gaarvanguard capture` — recapture the current character now
- `/gaarvanguard probe` — dump which profession + talent APIs this client exposes (chat + copyable box)
- `/gaarvanguard config` — settings under **Gaar → Vanguard**
- `/gaarvanguard wipe` — clear the whole database

## Client support

Targets Forever (Mainline TOC, interface `120100, 16001`) and Classic Era (Vanilla TOC,
`11509`), matching the rest of the suite. Per `docs/forever-client-findings.md` the only globals
Forever removed that the suite touches are three spellbook skill-line calls, which this addon
does not use. Note the same document's finding that **Forever does not currently persist addon
SavedVariables** — so on that client the export reflects the live session, and captured data may
not survive a reload until Blizzard fixes persistence.
