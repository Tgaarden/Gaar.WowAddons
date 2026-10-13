# GaarVanguard

Captures the account's characters and their loot in game and hands them to the **Vanguard
website** as a copy-paste string. **The addon is export-only** — it does not import anything back;
everything you do with the data (vanguards, goals, instances) happens on the website. The addon is
the *source of truth for what you own and looted*, the website is the *source of truth for
vanguards, goals and instances*.

The export envelope is:

```
VGD1:<base64 of a JSON document>
```

`VGD1` is the format tag (Vanguard, version 1). The payload is a JSON object whose `k` field is
`"chars"`. The base64 and JSON encoders are self-contained in `GaarVanguard.lua` — no external
libraries.

## `k = "chars"` — addon → website (the Export boxes)

There are **two** exports, both emitting the same `k = "chars"` envelope — they differ only in
*which* characters and *how much* per character:

| Command | Characters | Per-character data | Use |
|---|---|---|---|
| `/gaarvanguard export` | **the current character only** (1 element) | **full** — everything below (identity, professions, equipment, loot, full talent trees), scanned live | **primary flow.** One character → a short string that survives the copy out of the in-game EditBox |
| `/gaarvanguard exportall` | **every stored character** (N elements) | **identity only** — `name`, `realm`, `race`, `cls`, `classFile`, `faction`, `lvl`, `xp`, `xpMax`, `spec`; **no** professions/equipment/loot/talents | a lightweight skeleton to populate the account pool |

The split exists because a single string dumping *all* characters *with* their heavy data grew long
enough to be **truncated** when copied from the in-game EditBox (losing talents and tail
characters). The per-character full export keeps each string short and reliable; the bulk export
stays short by carrying identity fields only.

Both are the same contract; the bulk export simply omits the heavy arrays. The full per-character
JSON is shown below; a bulk element is just the identity fields (a `chars` array of objects with
`name`, `realm`, `race`, `cls`, `classFile`, `faction`, `lvl`, `xp`, `xpMax`, `spec` and nothing else).

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
      "lvl": 42,
      "xp": 31250,
      "xpMax": 89300,
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
| `xp` | integer, optional | XP earned within the current level (`UnitXP("player")`). Absent when unknown; always belongs to `lvl` (see *XP within the level* below) |
| `xpMax` | integer, optional | XP the current level needs (`UnitXPMax("player")`), always > 0 when present. `xp` and `xpMax` come together or not at all |
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
  client could not describe at scan time (quality falls back to `GetInventoryItemQuality`); `name`
  falls back to the raw item link. See *Equipment* below for how a slot is read.
- `loot` is the last 100 rows for that character (see below). `item` is the full item link,
  `when` is a Unix timestamp (`time()`).
- `xp` / `xpMax` are **additive and optional** (added for the website's XP bar; rested XP is not
  exported). Both are omitted when either API is missing, errors, returns a secret or non-number
  value, when `xpMax` is 0 (a level that needs no XP, e.g. the cap), or when `xp` falls outside
  `0..xpMax`. The envelope stays `VGD1:`; an older reader ignores the two keys.

### Live scan at export (do not trust the cache)

On **both exports** the current character is re-scanned from the live game state right before the
string is built — name (see *Full character name* below), level (`UnitLevel`), race/class, faction,
guild + rank (`GetGuildInfo`), spec, the full talent build, professions, and **equipment** by
looping equip slots 1–19 (each id mapped to its canonical slot name; see *Equipment* below).
This means the export reflects the live character **even when the SavedVariables DB is empty or
stale**. That was the normal case on early Forever beta builds, which wrote addon SavedVariables but
never loaded them back. From build `1.60.1.70291` they persist, account-wide and per character (see
`docs/forever-client-findings.md`), but the live scan stays: the equipment events may not have fired
this session, and the character being exported should always be read as it is now.

The **per-character full export** (`/gaarvanguard export`) then emits **only that current
character** — one full element. The **bulk export** (`/gaarvanguard exportall`) emits every stored
character but keeps only the identity fields for each (other characters come from the DB, which
persists on Era and, from build 70291, on Forever too). Every reader is wrapped in `pcall`, so a
missing or reshaped API on one client leaves a blank field instead of erroring.

### Full character name (first + last)

The `name` field is the character's **identity key** on the website, so both exports depend
on it being complete. WoW Forever names are `"Firstname Lastname"`, but `UnitName("player")` has
been seen to return only the first name (e.g. `"Mag"` instead of `"Mag Tics"`). `FullPlayerName()`
therefore asks every name API the client exposes and keeps the **most complete** answer — the value
that actually carries a surname (a space) — never inventing one (every candidate is a verbatim API
return):

- `UnitName("player")` — name (and its 2nd return; on Forever's surname system the surname may come
  back there instead of the realm, so a plain-word 2nd value that is not the realm is combined into
  `"First Last"`).
- `GetUnitName("player", true)` — `"Name"` on the player's own realm, `"Name-Realm"` cross-realm.
- `UnitFullName("player")` — name (first return).

Any `"-Realm"` suffix is stripped (the realm is captured separately via `GetRealmName`), and among
the candidates the one carrying a surname wins (ties broken by length), falling back to
`UnitName`'s value when none carry a surname. `/gaarvanguard probe` dumps each raw API return plus
the value `FullPlayerName()` picked, so which API carries the full name on a given client can be
confirmed in game.

Both the **capture/store path** (`CaptureIdentity`) and both exports use `FullPlayerName()`, so a
stored record always holds `"First Last"` and the bulk `exportall` roster emits full names — not a
bare first name. `exportall` additionally overrides the **currently logged-in** character's stored
name with the live `FullPlayerName()` at export time, so the active character is always correct.
A record written by an older build that stored only a first name **self-corrects the next time that
character logs in** (login re-runs capture with the full name).

### Equipment

On build `1.60.1.70338` the exports stored at `PLAYER_LOGOUT` came out with an **empty equipment
list** for every character while loot, talents, professions and level were intact, and the next
desktop upload wiped the gear on the website. Either the client has already torn the inventory down
when `PLAYER_LOGOUT` fires, or an inventory reader returns nothing on that build. The capture no
longer depends on any single scan:

- **Every slot is read through several APIs**, each feature-detected and `pcall`-guarded:
  `GetInventoryItemLink` and `GetInventoryItemID`, then `C_Item.GetItemLink` / `C_Item.GetItemID` with
  `ItemLocation:CreateFromEquipmentSlot(slot)`, then `C_TooltipInfo.GetInventoryItem`. A **secret
  value** is treated as "could not read" and never compared or indexed. `GetInventoryItemTexture`
  tells a genuinely empty slot from one that holds something we could not read.
- **A reading is taken at face value only in-session**, once the inventory has had a few seconds to
  load after `PLAYER_ENTERING_WORLD`, and only when all 19 slots were accounted for. Anything else -
  including **every scan at logout** - is laid over the best earlier reading slot by slot (this
  session's, else the stored record's `chars[...].equipment`), so a failed read never drops gear.
- A reading with **no items at all where there were several before** is not trusted either; going
  naked happens one piece at a time, and the last step (one item to none) is accepted.
- The result is kept in `chars[...].equipment`, so the stored record carries the equipment too.

### Level, talents and professions at logout

The same build (`1.60.1.70338`) later stored an export at **client exit** with the level and talents
the character had at **login** (level 24, 20 talent points) although it had levelled to 25 and spent
a point during play; a `/reload` a few minutes later stored 25 / 21 correctly. When the client exits,
`UnitLevel` and the trait graph can answer at `PLAYER_LOGOUT` with the state from login, or with
nothing, and a stale answer looks perfectly valid. So the most recent capture made **while playing**
is the source of truth, and the logout scan only adds what is plausibly newer:

- **level** — the highest level seen this session (a level never goes down within one), including
  the level `PLAYER_LEVEL_UP` / `PLAYER_LEVEL_CHANGED` announce before `UnitLevel` catches up;
- **talents** (and the spec they give) — the in-play build, unless the logout read has **more**
  points spent, and no more than the level, i.e. a point spent in the last seconds before logout;
- **professions** — the in-play list, each skill raised to the logout value where that is higher;
- **equipment** — merged slot by slot as above;
- **XP** — see below.

#### XP within the level

`xp` / `xpMax` follow the same in-play rule. Every live read (at capture and on each
`PLAYER_XP_UPDATE`) is kept in memory together with the level `UnitLevel` reported in the same
moment. The record, and so the export, takes that pair **only while that level equals the stored
`lvl`**: XP resets at a level-up and `UnitLevel` can lag behind `PLAYER_LEVEL_UP`, so a read from the
other level is dropped (the fields are omitted) until a read at the new level arrives, rather than
exported against the wrong level. At `PLAYER_LOGOUT` the live read is not used at all (the client can
answer with the state from login, or 0); the last in-play pair is exported. When there was no read
this session, the pair already in the record stands as long as the level has not changed.

The logout writes `GaarVanguardDB.lastLogoutDiag` with what it could read live next to what it used
(see *SavedVariables shape*), and `/gaarvanguard sync` prints it.

### What else drives capture (keeps the DB fresh between exports)

| Event | Refreshes |
|---|---|
| `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD` | the whole record |
| `PLAYER_EQUIPMENT_CHANGED` | equipment |
| `PLAYER_ENTERING_WORLD` + 3 s | equipment, now trusted as loaded |
| `UNIT_INVENTORY_CHANGED` (`player`) | equipment (at the debounced store check) |
| `PLAYER_LEVEL_UP` | the whole record |
| `PLAYER_XP_UPDATE` (`player`) | XP (read at once; the record at the debounced store check) |
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
button under Gaar → Vanguard) dumps to chat **and** into a copyable box, for the current character.
It opens with a **name probe** — the raw return of `UnitName("player")` (both returns),
`GetUnitName("player", true)`, `UnitFullName("player")` and `GetRealmName()`, plus the value
`FullPlayerName()` picked — so the full "First Last" can be confirmed on Forever. It then dumps
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

## `k = "sync"` — legacy website sync (in-game view only)

> **Import has been removed — the addon is export-only.** Earlier versions could paste the
> website's sync string back with `/gaarvanguard import`; that command, its paste box and its
> decode path are gone. The in-game view below is kept and still renders a `GaarVanguardDB.sync`
> document if one is already stored from an older version, but the addon no longer writes it. This
> section documents that legacy shape for reference.

**The canonical shape is the website's `encodeSync()` in `Vanguard/src/lib/protocol.ts`** — the
view reads exactly those short field names. Sync is account-level and asymmetric: it carries the
player's Vanguards, their goals, a members/readiness summary and the player's own
character→Vanguard/goal mapping. It deliberately does **not** carry gear/stats (the addon already
has those).

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

The view is deliberately tolerant: the longhand `goals[].title` / `.status` / `.instanceCode`
are accepted as fallbacks, non-table entries and missing arrays are skipped, and every reader is
`pcall`-guarded so a reshaped or partial document renders what is present rather than erroring.

### The in-game view

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
- **Empty state** — with no stored `sync` (the normal case now that import is removed), the window
  shows an export-only prompt: use Export / Sync all and paste the code into the Vanguard website,
  where the data is viewed and managed.

The view is display-only (it writes nothing) and its toolbar button opens the Export box without
leaving it.

## Minimap button

For players who would rather click than type, GaarVanguard puts its own button on the minimap
edge (a note icon, `Interface\Icons\INV_Misc_Note_03`, with `INV_Misc_Map_01` and the question
mark as fallbacks where `GetFileIDFromPath` says the first is missing).

- **Left-click** opens a small copy box holding this character's full export — built by the same
  `BuildExportStringCurrent()` as `/gaarvanguard export`, so the string is byte-identical — with the
  text already selected and focused. Press **Ctrl+C** (**Cmd+C** on a Mac; the hint follows
  `IsMacClient()`) and the box closes itself and prints *Copied!*. **Esc** closes it without
  copying. The text is read-only: edits are undone and a click re-selects everything.
- **Right-click** opens a menu: *Copy export (this character)*, *Copy export (all characters)*
  (the `exportall` string, in the same copy box), *Open website* (puts
  `https://vanguard.gaaruniverse.no` in the copy box), *Open Vanguard view*, *Recapture this
  character*, *Auto-sync (Vanguard Sync app)* (a checkbox; see *Stored exports for the desktop app*
  below), *Settings* (only when GaarOptions is installed) and *Hide minimap button*. The menu
  is Blizzard's `MenuUtil.CreateContextMenu` where it exists (retail, Forever) and a small
  self-drawn menu otherwise (Classic Era), so `UIDropDownMenu` is never touched.
- **Drag** moves it around the minimap. The angle is saved; on a square minimap (GaarMap, via
  `GetMinimapShape`) it follows the edge and corners instead of a circle.

Why the copy box instead of the clipboard: addons cannot write to the system clipboard —
`CopyToClipboard` is reserved for Blizzard code — so the box does everything except the one
keystroke only the player can press.

The button is self-contained in `GaarVanguard.lua` (the placement logic mirrors GaarOptions' button
but is copied, not shared), because GaarVanguard ships on its own as a ZIP. Its default angle (245°)
is 40° away from GaarOptions' (205°) so both can show at once. Settings are read once
SavedVariables have loaded (`ADDON_LOADED`), never at file scope.

## Stored exports for the desktop app (Vanguard Sync)

The **Vanguard Sync** desktop app cannot talk to the game. It reads GaarVanguard's SavedVariables
file from disk and uploads what it finds, so the addon keeps each character's ready-made export
string in `GaarVanguardDB.exports`. **This section is the contract with that app.**

File location (one per WoW account, per client folder; Forever installs to `_classic_beta_`, Era to
`_classic_era_`, retail to `_retail_`):

```
<WoW install>/<client folder>/WTF/Account/<ACCOUNT>/SavedVariables/GaarVanguard.lua
```

Shape:

```lua
GaarVanguardDB = {
  -- ...
  autoSync = true,
  exports = {
    ["Mag Tics-Nostalrius"] = {
      v = 1,
      export = "VGD1:eyJjaGFycyI6W3sib...",
      updatedAt = 1760000000,
      build = "1.60.1.70291",
      project = 18,
    },
  },
}
```

| Field | Type | Notes |
|---|---|---|
| key | string | `"Full Name-Realm"`, the same key as `GaarVanguardDB.chars` (full `"First Last"` name on Forever) |
| `v` | number, always present | version of **this record's** shape, currently `1`. A reader should skip entries whose `v` it does not know. It versions the record, not the payload (the payload carries its own `VGD1` tag) |
| `export` | string, always present | the full `VGD1:<base64 JSON>` string, **byte-identical to what `/gaarvanguard export` produces for that character at that moment** (same function, `BuildExportStringCurrent()`, live scan included) |
| `updatedAt` | number, optional | Unix seconds (`time()`) when the string was built. Compare against the app's last upload to skip unchanged characters |
| `build` | string, optional | `GetBuildInfo()` version and build joined with a dot, e.g. `"1.60.1.70291"`; absent if the client did not answer |
| `project` | number, optional | `WOW_PROJECT_ID` (Forever 18, retail 1, Classic Era 2); absent where the client does not define it |

**`autoSync`** (top level, boolean, account-wide) is the player's on/off switch for the desktop app:

- **Missing means `true`.** The addon writes an explicit `true` the first time it reads the flag.
- **When `autoSync == false` the app must skip uploading** for that account (every character in the
  file), even though `exports` may still hold entries.
- While it is off the addon writes and refreshes nothing: no trigger below runs, and existing
  entries are left exactly as they were (no pruning either). Turning it back on resumes from the next
  trigger.
- It is toggled from the minimap right-click menu (*Auto-sync (Vanguard Sync app)*, a checkbox on
  retail/Forever and a check-mark row in the Classic Era menu), the *Auto-sync (Vanguard Sync app)*
  checkbox under Gaar → Vanguard, and `/gaarvanguard sync on` / `/gaarvanguard sync off`. A chat line
  confirms each change. Like every SavedVariable, a change reaches the file on the next logout,
  `/reload` or exit.

The `export` string is exactly what the player would otherwise paste into the website, so the app
handles it the same way the website does: strip `VGD1:`, base64-decode, parse the `k = "chars"` JSON
(see the contract above; the website does this in `Vanguard/src/lib/protocol.ts`) and send the
characters to `POST /api/vanguard/characters/import-batch`.

**When an entry is written** (only while `autoSync` is on; always for the logged-in character only,
overwriting its previous entry):

| Trigger | Notes |
|---|---|
| `PLAYER_LOGOUT` | fires before the client saves SavedVariables on **logout, `/reload` and client exit**, so this is the entry the app normally reads. Its equipment scan only tops up what the session already read (see *Equipment*), never empties it. Fully `pcall`-guarded: a failure never gets in the way of logging out (the previous entry is then simply kept) |
| copying the export | `/gaarvanguard export`, the *Export this char* button and the minimap left-click / *Copy export (this character)* store exactly the string they show |
| a manual recapture | `/gaarvanguard capture`, the minimap *Recapture this character* and the *Recapture now* button |
| login / loading screen | 3 seconds after `PLAYER_ENTERING_WORLD` the equipment is re-read, and the entry is stored if level, XP, talents, equipment or professions differ from the last store this session (so always once per login) |
| `PLAYER_EQUIPMENT_CHANGED`, `UNIT_INVENTORY_CHANGED` (`player`), `SKILL_LINES_CHANGED`, `UNIT_LEVEL` (`player`), `PLAYER_XP_UPDATE` (`player`), and the talent events `TRAIT_CONFIG_UPDATED`, `TRAIT_TREE_CHANGED`, `PLAYER_TALENT_UPDATE`, `CHARACTER_POINTS_CHANGED`, `ACTIVE_COMBAT_CONFIG_CHANGED` | debounced: 3 seconds after the last such event level, talents and equipment are re-read, and the entry is stored only if level, XP, talents (points per tree and every rank), equipment or professions changed. `PLAYER_XP_UPDATE` fires on every kill or quest turn-in; the debounce folds a run of them into one store 3 seconds after the last (and waits out combat). Events a client does not know are skipped |
| `PLAYER_LEVEL_UP`, `PLAYER_LEVEL_CHANGED` | always stored, 3 seconds after the event, with the level the event announces (`UnitLevel` can still report the old level when it fires); if `UnitLevel` has not caught up by then, stored once more 3 seconds later |
| every 30 seconds in play | a cheap read of the level and the points spent; a change schedules the debounced store above. A safety net for clients that do not fire the talent events |

The debounced refreshes use `C_Timer.After` (where the client lacks it they run at once), wait out
combat, and re-check `autoSync` when they fire.

**When the app can see it:** the game only writes SavedVariables to disk on **logout, `/reload`
and client exit**. An entry written mid-session (copy, recapture, level-up) sits in memory until
then. A client crash or a killed process writes nothing, so the file keeps the entries from the last
clean save.

**Growth is bounded:** one entry per character, overwritten each time. When an entry is stored,
entries whose key is no longer in `GaarVanguardDB.chars` (and anything that is not a table) are
dropped, so `exports` never holds more than the characters the addon knows about.
`/gaarvanguard wipe` clears it with the rest of the database. The legacy `sync` key is unrelated and
is left alone.

`/gaarvanguard sync` prints when this character's entry was last stored (time and age, string length,
build), what that stored string holds (equipped items, loot rows, level and XP - read back from the string
itself), its level and talent points next to the values read while playing, what the last logout
could read live against what it stored (`lastLogoutDiag`), a live equipment read next to the record's count, how many entries exist and whether
auto-sync is on, so a player can check the app will have fresh data after the next logout or
`/reload`. `/gaarvanguard probe` adds an equipment section: which inventory readers the client has
and what each returns for the head, chest and main-hand slots.

## SavedVariables shape

`GaarVanguardDB`:

```
GaarVanguardDB = {
  chars = {
    ["Name-Realm"] = {
      name, realm, race, cls, classFile, lvl, xp, xpMax, faction, spec, guild, guildRank,
      talents     = { { tab, points, talents = { { name, rank, max, tier, col }, ... } }, ... },
      professions = { { name, skill, max }, ... },
      equipment   = { { slot, itemId, quality, name }, ... },  -- slot is the slot NAME string
      loot        = { { item, itemId, quality, kind, winner, when }, ... },  -- last 100
    },
    ...
  },
  maxLoot = 100,
  minimap = { hide = false, angle = 245 },   -- minimap button: hidden?, position in degrees
  autoSync = true,                           -- Vanguard Sync desktop app on/off (missing = true)
  exports = {                                -- for the Vanguard Sync desktop app (see above)
    ["Name-Realm"] = { v = 1, export = "VGD1:...", updatedAt, build, project },
    ...
  },
  lastLogoutDiag = {                         -- written at every PLAYER_LOGOUT while auto-sync is on
    when, build,                             -- time() and "version.build"
    levelLive, levelInPlay, levelUsed,       -- UnitLevel at logout / highest in play / exported
    xpLive, xpInPlay, xpUsed,                -- UnitXP at logout (nil = unreadable) / last in play / exported
    talentsLive, talentsInPlay, talentsUsed, -- points spent: logout read (nil = unreadable) / in play / exported
    equipLive, equipUnknown, equipUsed,      -- items read at logout / slots unreadable / exported
    profsLive, profsUsed,                    -- professions read at logout / exported
  },
  sync = <legacy website sync document (k="sync") from a pre-export-only version, or absent>,  -- rendered by the in-game view; the addon no longer writes it
}
```

Records written by an older addon version (numeric `slot`, `class`, `level`, profession `rank`)
are migrated to the canonical names on the way out, so a mixed DB still exports cleanly.

## Slash commands

- `/gaarvanguard` or `/gaarvg` — open the in-game Vanguard view (the synced goals/instances)
- `/gaarvanguard view` — same as above, explicitly
- `/gaarvanguard export` — full VGD1 `chars` string for **this character** (the primary export)
- `/gaarvanguard exportall` (alias `syncall`) — lightweight VGD1 `chars` string for **all stored
  characters**, identity fields only
- `/gaarvanguard capture` — recapture the current character now
- `/gaarvanguard sync` — when this character's export was last stored for the Vanguard Sync desktop app,
  what it holds (level and talent points next to the in-play values), what the last logout could
  read, and whether auto-sync is on
- `/gaarvanguard sync on` / `/gaarvanguard sync off` — turn auto-sync for the desktop app on or off
- `/gaarvanguard probe` — dump which profession + talent APIs this client exposes (chat + copyable box)
- `/gaarvanguard minimap` — show or hide the minimap button
- `/gaarvanguard minimap reset` — put the minimap button back at its default position (and show it)
- `/gaarvanguard config` — settings under **Gaar → Vanguard**
- `/gaarvanguard wipe` — clear the whole database

## Client support

Targets Forever (`GaarVanguard_Camelot.toc`, interface `16001`; the `_Mainline.toc` also lists
`120100, 16001`) and Classic Era (`_Vanilla.toc`, `11509`), matching the rest of the suite. Forever
reports `WOW_PROJECT_ID` = 18 (`WOW_PROJECT_CAMELOT`) rather than retail's 1; this addon does not
branch on the project id, it checks for each API it uses, so that change did not affect it. The
`/gaarvanguard probe` box prints the id with the build and interface.

**SavedVariables persist on Forever** from build `1.60.1.70291`, account-wide and per character,
proven across a full client restart (`docs/forever-client-findings.md`). Early beta builds did not
load them back, which is why the export re-scans the live character instead of trusting the
stored record; on current builds `GaarVanguardDB` survives reloads and restarts as it does on Era.
