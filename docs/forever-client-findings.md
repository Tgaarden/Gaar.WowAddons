# WoW Forever: what the client on disk says

Read off the installed beta client on 2026-09-17, before any character login was possible.
Method: extract the strings from each client binary and diff Forever against Classic Era, so
that "absent" only counts where Era has the same literal. Era is the control precisely because
the suite is known to work on it.

    strings -n 3 ".../World of Warcraft Beta.app/Contents/MacOS/World of Warcraft" | sort -u

The later sections were added as the client was patched and the probes ran in game. Each one
names the build it comes from, and the build history below puts them in order.

## What it is

| | |
|---|---|
| Install folder | `_classic_beta_` |
| Product flavor (`.flavor.info`) | `wow_classic_beta` |
| Version | `1.60.1.69893` when first read; `1.60.1.70291` as of 2026-10-09 |
| Interface | `16001` |
| `WOW_PROJECT_ID` | `18` (`WOW_PROJECT_CAMELOT`) since at least 70245; it was `1` on 69913 |
| Branch codename | `Camelot` (see below) |

## Build history

| Build | Seen | What it meant for addons |
|---|---|---|
| `69893` | 2026-09-17 | First reading, from the binary only - no login was possible yet |
| `69913` | 2026-09-18 to 09-21 | First in-game probe. Interface `16001`, `WOW_PROJECT_ID` = 1 (`WOW_PROJECT_MAINLINE`). SavedVariables written but never loaded back |
| `69977` | 2026-09-23 to 09-24 | The profession and talent probes. On-disk evidence suggests SavedVariables started coming back around here (medium confidence) |
| `70058` | by 2026-09-29 | Nothing specific recorded |
| `70245` | installed 2026-10-07 | `WOW_PROJECT_ID` = 18 (`WOW_PROJECT_CAMELOT`). The change happened somewhere after 69913; which build exactly is unknown |
| `70291` | installed 2026-10-09 08:32 | SavedVariables persistence confirmed, account and per character, across a full client restart. Full probe report below |

The dates come from the build number stamped in the client's own `Errors/` reports and `Logs/`,
or from the install time, so "seen" means "in use on that day", not "released on that day".

The version is on the 1.x line, like Classic Era's 1.15.x, but the engine underneath is not
Era's. Forever's binary exposes **288** `C_*` namespaces against Era's **202**, including a
great deal of modern machinery Era has never had - `C_AuctionHouse`, `C_ClassTalents`,
`C_Garrison`, `C_TooltipInfo`, `C_Bank`, `C_DelvesUI`. What Era has and Forever does not is
the Season of Discovery work: `C_Engraving`, `C_Seasons`, `C_Reforge`, `C_QuestChoice`.

So: a Vanilla-numbered game on a current-generation client.

## What this means for the suite

Of the 115 globals the suite touches, the diff against Era comes to **three removals**, all in
one module:

| Gone | Replacement present in Forever |
|---|---|
| `GetNumSpellTabs` | `C_SpellBook.GetNumSpellBookSkillLines` |
| `GetSpellTabInfo` | `C_SpellBook.GetSpellBookSkillLineInfo` |
| `IsPassiveSpell` | `C_SpellBook.IsSpellBookItemPassive` |

All three belong to `GaarSpellBook`. Every other module's C API is intact, including the ones
that looked most at risk from a retail-shaped client: `UnitDetailedThreatSituation`,
`C_NamePlate.GetNamePlateForUnit`, `GetLootRollItemInfo`, `RollOnLoot`, `UnitAura`,
`hooksecurefunc`, `SetResizeBounds`, `SetColorTexture` are all there. `GetSpellBookItemName`,
`GetSpellBookItemTexture` and `PickupSpellBookItem` survive, so only the skill-line half of the
spell book has to move.

## What this method cannot answer

**FrameXML-level names.** 25 of the 115 are absent from *both* binaries - `RAID_CLASS_COLORS`,
`UnitFrameHealthBar_Update`, `SetItemButtonTexture`, `CombatLogGetCurrentEventInfo`,
`UISpecialFrames` and the rest. They live in FrameXML inside CASC, not in the executable, so
their absence here means nothing at all. `GaarFrames` depends most heavily on exactly this
layer, and is therefore **unverified rather than cleared**.

**Return shapes.** A function whose name is present can still answer with a table where it used
to answer with three values, which is the failure that does not announce itself. Nothing on
disk reveals this. `GaarProbe` exists for it.

**The interface number.** Not a literal in either binary - Era's own `11509` is not there
either, which is the control that shows the method cannot reach it. By the usual convention
(1.15.9 gives 11509) version 1.60.1 should give **16001**, but that is inference from a naming
pattern, not a reading.

## The TOC suffix

The client tries `%s%%s.toc` - name plus a flavour suffix - and falls back to `%s.toc`, the
same as every other flavour. The suffix itself is not a plain literal in Era's binary, so there
is no control for it.

In Forever's binary, one string sits between `Unknown Mainline expansion` and the TOC parser's
directive table, and appears in Forever but not in Era: **`Camelot`**. Position and exclusivity
both point at it being this branch's expansion name, and therefore its TOC suffix.

That is suggestive, not proven, so `GaarProbe` ships `GaarProbe_Camelot.toc` *and* a plain
`GaarProbe.toc`. The plain file is the guarantee: it is what the client falls back to whatever
the suffix turns out to be.

A caution worth recording, because it nearly went into this document as fact: `Mainline` and
`Vanilla` are both present in Forever's binary, which looked at first like the list of accepted
suffixes. They are not. Checking the surrounding strings shows both sitting inside
`PremadeGroupFinderStyleMeta`, among the LFG constants. Reading a literal without reading its
neighbours produces a confident wrong answer.

**Settled since.** The `Camelot` reading was right. Once the client started reporting
`WOW_PROJECT_CAMELOT`, every addon in the suite gained a `<Name>_Camelot.toc` at interface `16001`
(see *The TOC: `_Camelot` at 16001* below).

# Retail (12.1.0)

The same diff was run against retail, build `12.1.0.69814`, with Era as the control again.

**The result is identical**: the same three spell-book calls are the only C-API removals across
all 115 names the suite touches. Retail's interface number is **120100**, read from the TOCs of
the addons already installed there (DBM, Auctionator, Pawn) rather than inferred.

The retail install also carries 50 third-party addons, which gives the FrameXML layer the
second artefact the binary cannot provide. Of the names absent from both binaries:

- Used by installed retail addons, so they exist: `RAID_CLASS_COLORS`, `STANDARD_TEXT_FONT`,
  `SOUNDKIT`, `UISpecialFrames`, `ChatEdit_InsertLink`, `CombatLogGetCurrentEventInfo`,
  `NUM_CONTAINER_FRAMES`, `IsSpellKnownOrOverridesKnown`, `GetMinimapShape` (LibDBIcon reads it,
  so the square-minimap convention holds there too).
- Used by nobody among the 50: `UnitFrameHealthBar_Update`, `HealthBar_OnValueChanged`,
  `CLASS_ICON_TCOORDS`, `SetItemButtonTexture`, `SpellBookFrame`. Absence among 50 addons is
  weaker evidence than presence, so these are suspected gone rather than known gone. Every one
  of them is already behind a type guard, so the cost of being wrong is a feature that does
  nothing, not an error.

DBM settles the aura question outright, in `DBM-Core.lua`:

    local UnitAura = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex or UnitAura

which is the shape `GaarFrames` and `GaarPlates` already had.

# Confirmed from inside: the probe ran (2026-09-18)

`interface 16001`, build `1.60.1.69913`. The interface number inferred from the naming
convention was right.

**`WOW_PROJECT_ID` is 1, which is `WOW_PROJECT_MAINLINE`.** Forever identifies itself as retail
to addons. That settles the TOC question a different way than expected: `Camelot` is not needed,
`_Mainline` is what this client should match, and any code branching on the project id treats
Forever as retail automatically - which is what the suite now does.

**No longer true.** By build 70245 Forever reports its own project id, 18, and no longer counts as
retail. See *Forever is its own project now* below for what that broke and how the suite handles it.

It is retail-shaped but further along. Everything retail had moved, Forever has moved, and then
some:

| Gone on Forever | Where it went |
|---|---|
| `GetItemInfo`, `GetItemInfoInstant`, `GetItemQualityColor` | `C_Item` (all five members present) |
| `GetCoinTextureString` | nowhere found - formatted by hand where absent |
| `GetContainerItemInfo` and the rest | `C_Container` (all eight present) |
| `GetSpellBookItemName` and the rest | `C_SpellBook` (all eight present) |
| `UnitAura`, `UnitBuff` | `C_UnitAuras` |
| `InterfaceOptions_AddCategory` | `Settings` |

Retail still had the item globals; Forever does not. That is the one place where targeting
retail was not enough.

**The combat log has no getter at all.** `C_CombatLog` exists as a namespace but is empty of
both `GetCurrentEventInfo` and `GetEventInfo`, and the old global is gone too. The binary
carries `C_CombatLog` and `GetCurrentEventInfo` as separate strings, so the function exists
somewhere, but not under either name an addon would reach for. Until that is found, `GaarMeter`
cannot read the combat log on this client.

Frames match retail exactly: `PlayerFrame.healthbar`, `PartyFrame.MemberFrame1`,
`PlayerCastingBarFrame`, `MinimapCluster.ZoneTextButton`, `SettingsPanel`. `PlayerSpellsFrame`
is absent, but it is load-on-demand, so that proves nothing either way.

# Professions: read from the binary (2026-09-23)

`GaarVanguard` exported `"professions":[]` on Forever even after a full client restart, while
equipment captured fine. The `strings`-and-diff method settled why, and the two removals it found
are both silent - a name that resolves to nil, and a name that answers with a table where it used
to answer with values.

Method as before: `strings -n 3` on each binary, `sort -u`, diff Forever against Era, and read the
`Usage:` lines because a `Usage:` string names the exact namespace and signature the client
registers a call under.

**The profession readers are globals, not `C_TradeSkillUI` members.** Both binaries carry
`GetProfessions` and `GetProfessionInfo` as plain globals, and Forever carries
`Usage: GetProfessionInfo(index)` - the global signature - while `C_TradeSkillUI` has **no**
`GetProfessions` at all (its `Usage:` lines are all recipe/reagent/crafting calls). So
`C_TradeSkillUI.GetProfessions`, which the addon's "modern" path looked for, is nil on every
client, and the path bailed before reading anything. That single wrong namespace is why Forever
exported nothing. The fix reads the globals `GetProfessions()` + `GetProfessionInfo(index)` first,
with the `C_TradeSkillUI` names kept only as an alias for any odd client that namespaces them.

**The classic skill-line reader moved to a new namespace and changed shape.** Era exposes the bare
globals with multi-value returns - `Usage: GetSkillLineInfo(index)`, `Usage: ExpandSkillHeader(index)`.
Forever has neither global `Usage:` line; instead a **beta-only namespace `C_SkillInfo`** (absent
from Era entirely) carries them:

    Usage: C_SkillInfo.ExpandSkillHeader(index)
    Usage: C_SkillInfo.CollapseSkillHeader(index)
    Usage: C_SkillInfo.AbandonSkill(skillLineID)
    Usage: C_SkillInfo.SetSelectedSkill(index)
    Usage: local skillLineAttributes = C_SkillInfo.GetSkillLineInfo(index)
    Usage: local skillLineAttributes = C_SkillInfo.GetSkillLineInfoByID(ID)

`C_SkillInfo.GetSkillLineInfo(index)` returns a single **table** (`skillLineAttributes`), not the
`name, isHeader, isExpanded, rank, ...` tuple the global returned - the failure that does not
announce itself. The table's field names, read out of the binary near the struct, are `name`,
`isHeader`, `isHeaderExpanded` (note: not `isExpanded`), `isHeaderWithRep`, `rank`, `maxRank`,
`requiredSkillRank`, `skillModifier`, `skillLineIndex`, `description`. The count getter
`GetNumSkillLines` has **no** namespaced `Usage:` line in either binary, so whether it stays global
or lives under `C_SkillInfo` on Forever is the one thing the strings do not settle; the code tries
`C_SkillInfo.GetNumSkillLines` then the global, and `/gaarvanguard probe` reports which answered.

**Profession namespaces Forever adds over Era** (all standard modern retail, none Forever-bespoke):
`C_SkillInfo`, `C_ProfSpecs` (the profession specialization trees - this is what the guide's
"reworked tradeskills / Azeroth Commerce Authority" flavour maps to; it is spec/perk data, not
skill level), `C_CraftingOrders`, `C_LegendaryCrafting`. The `Commerce*` strings in the binary
(`CommerceObj`, `GetCommerceSystemStatus`, ...) are byte-identical to Era's and belong to the
real-money **shop**, not to professions - there is no custom profession API to chase.

**What this cannot answer, and the probe must.** Whether `GetProfessions()` returns live indices on
this Vanilla-content client, and whether `GetNumSkillLines` is global or namespaced, are runtime
facts. `/gaarvanguard probe` dumps, for the current character: `WOW_PROJECT_ID`/interface/build;
`GetProfessions`/`GetProfessionInfo` presence and their live returns; the `C_TradeSkillUI` alias
check; every skill-line reader (global vs `C_SkillInfo`, including the table's keys); a full dump of
all skill lines (index, name, isHeader, isExpanded, skill/max, PROFESSION tag) after expanding
headers; the extra namespaces; and the resolved `ScanProfessionsModern` / `ScanProfessionsClassic`
/ `CaptureProfessions` results. Run it on Forever and paste the box back to confirm the wiring.

# Talents / spec: read from the binary (2026-09-23)

`GaarVanguard` exported an empty `spec` (and empty `talents`) on Forever - a character with even one
point spent came back with nothing. Same class of fault as the professions: the readers the addon
reached for are the *classic* ones, and Forever has moved them. Method as before: `strings -n 3` on
each binary, `sort -u`, diff Forever (beta) against Era, and read the `Usage:` lines because a
`Usage:` string names the exact namespace and signature the client registers a call under.

**Forever has removed the classic Vanilla tab talent API.** The tab-based point-tree globals that
Era carries are simply absent from the Forever binary:

| Present on Era, gone on Forever | Note |
|---|---|
| `GetNumTalentTabs` | bare global; era has it, beta does not |
| `GetNumTalents` (`Usage: GetNumTalents(tabIndex[, isInspect[, isPet]])`) | the tab-count-of-talents reader |
| `GetNumTalentGroups`, `GetActiveTalentGroup`, `UnitCharacterPoints` | classic dual-spec / unspent-points readers |
| `GetTalentGroupRole`, `SetPrimaryTalentTree`, `AddPreviewTalentPoints(tabIndex, …)`, `GetTalentPrereqs(tabIndex, …)` | the rest of the classic tab machinery |

`GetTalentInfo` and `GetTalentLink` still *exist* on Forever, but only in their retail/ID shapes -
`Usage: GetTalentInfo(tier, column, specGroupIndex …)`, `Usage: GetTalentLink(talentID)`,
`Usage: LearnTalent(talentID)` - never the classic `(tabIndex, talentIndex)` forms Era also lists.
So the addon's tab loop (`for i = 1, GetNumTalentTabs()`) never ran on Forever: `GetNumTalentTabs` is
nil, the loop body is skipped, and `spec`/`talents` stay empty. That single missing global is the
whole bug, the exact analogue of the profession code looking under the wrong namespace.
`GetTalentTabInfo` is absent from *both* binaries (it lives in FrameXML, like `RAID_CLASS_COLORS`),
so it cannot be cleared or condemned from the strings - but with `GetNumTalentTabs` gone the point is
moot on Forever.

**Where the Vanilla trees went: the retail `C_SpecializationInfo` namespace.** Present in both
binaries, but on Forever it is the *only* spec reader left, and its `Usage:` lines give the shapes:

    Usage: local specCount = C_SpecializationInfo.GetNumSpecializationsForClassID(classID)
    Usage: local specId, name, description, icon, role, primaryStat, pointsSpent, background,
           previewPointsSpent, isUnlocked = C_SpecializationInfo.GetSpecializationInfo(query)
    Usage: local specializationIndex = C_SpecializationInfo.GetSpecialization([isInspect, isPet, specGroupIndex])

The key field is **`pointsSpent`** (the 7th return value): on this Vanilla-content client the class's
three talent trees are exposed as its "specializations", and each carries the points invested in it.
So the classic rule *"the talent tab with the most points spent is the spec"* becomes *"the
specialization with the most `pointsSpent` is the spec"*, and that spec's `name` (e.g. `Fire`) is
what the export needs. `GetSpecializationInfo` answers with a value tuple per the `Usage:` line, but
the accessor also handles a table return - the same silent shape change `C_SkillInfo.GetSkillLineInfo`
had. Era carries `SetSpecialization(specIndex)` as a bare global; on Forever even that has moved to
`C_SpecializationInfo.SetSpecialization`, confirming the whole spec surface is namespaced there now.

**Forever adds the retail per-tier talent system too** (`GetMaxTalentTier` is beta-only;
`GetTalentInfo(tier, column, specGroupIndex)`, `C_ClassTalents`, `C_Traits` are all present), but that
is the Dragonflight node/tier graph, not the Vanilla point tree, and it cannot reconstruct a
Vanilla-style per-talent build. So the addon captures the **spec name** (required) and a **compact
per-tree points summary** (`{ tab = treeName, points = pointsSpent, talents = {} }`) from
`C_SpecializationInfo`, and keeps the full per-talent tree only on the classic (Era) path.

**What this cannot answer, and the probe must.** Whether `GetSpecializationInfo(index)` accepts a
plain 1..N index on this Vanilla-content client (the `Usage:` says `query`, not `index`), whether it
reports live `pointsSpent` for the Vanilla trees, and whether it returns a tuple or a table, are all
runtime facts. `/gaarvanguard probe` now dumps, for the current character: the classic tab globals'
presence; the `C_SpecializationInfo` members; `Spec_GetNum()`; the active `GetSpecialization()` index;
`GetSpecializationInfo(i)` name/points/specId for every tree; the tuple-vs-table shape of return 1;
and the resolved path + `spec` + `talents` summary. Run it on Forever and paste the box back to
confirm the wiring. The selection logic itself (tuple/table normalisation, max-points pick, no-spec
when nothing is spent) was verified out of game with a stubbed-API luajit harness.

# Talents / spec: what the live probe showed (2026-09-23)

The extended `/gaarvanguard probe` was run in game on Forever - a level-10 Mage with exactly **one
point in Fire**. It corrected the binary-only guess above: the strings said *where the spec API
moved*, but only the live returns say *what it means on Vanilla content*, and the answer is that the
binary's obvious candidate is the wrong one.

- **Classic talent globals: all missing**, as the binary predicted.
- **The global `GetSpecialization` / `GetSpecializationInfo` are missing; `GetNumSpecializations`
  (global) is a function.** The spec surface is reached through `C_SpecializationInfo` only.
- **`C_SpecializationInfo` is class-level on Forever, not per-tree.** `C_SpecializationInfo.GetSpecialization()`
  returns `1`; `C_SpecializationInfo.GetSpecializationInfo(1)` returns a **tuple** (first value a
  number) whose `name` is **`"Mage"`** and whose `pointsSpent` is **`0`** - specId `1482`.
  `GetNumSpecializationsForClassID` and `GetActiveSpecGroup` are functions. So there is exactly one
  "specialization" and it is the *class*, with no point count. The previous fix's "the specialization
  with the most `pointsSpent`" therefore never resolves anything on Forever, and the spec/talent
  wiring **no longer relies on `C_SpecializationInfo`** (it is kept in the probe only, for the record).
- **The Vanilla talent trees appear as `C_SkillInfo` skill lines** under the "Class Skills" header -
  `[2] Arcane 1/1`, `[3] Fire 1/1`, `[4] Frost 1/1` - **but all three read `rank` 1/1** even though
  only Fire has a point. So the skill-line `rank` is *not* the talent-point count; some other field
  (or another namespace) must carry it.
- **`C_ClassTalents` and `C_Traits` both exist as tables** but had not been dumped, so the per-point
  location is still open.

**Where this leaves the wiring.** Spec is read as *the tree with the most points spent*: classic
tabs on Era, and on Forever the retail trait graph (`C_ClassTalents.GetActiveConfigID` ->
`C_Traits.GetConfigInfo` -> `GetTreeNodes` -> `GetNodeInfo` node ranks summed per tree), and only when
the winning tree resolves a real name - never a numeric tree id, never invented. Until a probe paste
confirms that the trait graph actually carries the Vanilla per-tree points (and their tree names),
**a Forever spec stays empty by design** rather than wrong. The selection logic (per-tree sum, name
gating, no-invent) is verified out of game with a stubbed-API luajit harness.

**What the next probe must pin.** `/gaarvanguard probe` now also dumps: every `C_ClassTalents` and
`C_Traits` member; the active config id and, from it, `GetConfigInfo`, each tree's `GetTreeInfo`,
`GetTreeNodes` count, and every node with `ranksPurchased`/`activeRank` > 0 (with a best-effort
resolved talent name) plus the per-tree rank total; and the **full raw `C_SkillInfo.GetSkillLineInfo`
table for every non-header skill line** (all fields: `rank`, `maxRank`, and whatever else - a
`skillModifier`, `stepCost`, `parentSkillLineID`, ...), because the field that distinguishes Fire
from Arcane/Frost is what pins the read.

# Talents / spec: the trait graph resolved (2026-09-23)

The second in-game probe (Mage lvl 10, one point in Fire) located the point and the model:

- `C_ClassTalents.GetActiveConfigID()` = `5921282`. `C_Traits.GetConfigInfo(5921282)` -> name `"Mage"`,
  **`treeIDs = {1112}`** (one trait tree for the whole class), type `4`. `GetTraitTreeForSpec(1)` is
  `nil` - the spec route is a dead end, as expected now that C_SpecializationInfo is class-level.
- Tree `1112` has **54 nodes**, of which **exactly one is purchased**: node `105795`, `ranks = 1`,
  `activeRank = 1`. Per-tree total ranks purchased = 1. So the trait graph *is* where the spent point
  lives - the profession-style fix applies one more level in.
- The Arcane/Fire/Frost `C_SkillInfo` skill lines all read `rank 1 / tempPoints 0` - no signal.
  `C_SpecializationInfo` is class-level (`Mage`, 0 points). **The only carrier of "Fire" is that
  purchased trait node.**

So the model is: **one class trait tree whose Vanilla trees (Arcane/Fire/Frost) are its subtrees**, and
a spent talent is a purchased node tagged with a `subTreeID`. The spec is therefore the **subtree with
the most purchased ranks**, and the subtree's name is the spec. The resolution chain the addon now
runs (all `pcall`-guarded):

    configID = C_ClassTalents.GetActiveConfigID()
    for each treeID in C_Traits.GetConfigInfo(configID).treeIDs:
      for each nodeID in C_Traits.GetTreeNodes(treeID):
        ni = C_Traits.GetNodeInfo(configID, nodeID)
        if (ni.ranksPurchased or ni.activeRank) > 0:
          group by ni.subTreeID; sum ranks
          name  = C_Traits.GetSubTreeInfo(configID, ni.subTreeID).name        -- e.g. "Fire"
          talent = C_Traits.GetEntryInfo(configID, entryID).definitionID
                 -> C_Traits.GetDefinitionInfo(definitionID)
                 -> .overrideName, or its .spellID/.overriddenSpellID resolved via
                    C_Spell.GetSpellName / C_Spell.GetSpellInfo (fallback global GetSpellInfo)
    spec = name of the subtree with the most ranks; if a purchased node has no subTreeID, fall back to
           the dominant purchased talent's own (spell) name; otherwise leave spec empty.

`talents` carries a compact summary per subtree - total ranks purchased and the resolved talent names -
exported only when the trees resolve real names, never a numeric id, and a spec is never invented. The
selection and name-resolution logic is verified out of game with a stubbed-API luajit harness (subtree
name, no-subtree spell-name fallback, dominant-subtree pick, nothing-purchased -> empty).

**What the next probe must confirm.** Whether node `105795` actually carries a `subTreeID` and whether
`GetSubTreeInfo` returns `"Fire"` for it - or, failing that, whether its entry/definition resolves to a
Fire spell name. `/gaarvanguard probe` now dumps, for every purchased node: the complete `GetNodeInfo`
table, `GetSubTreeInfo(configID, subTreeID).name`, and each entry -> definition -> `spellID` -> spell
name, plus the tree's own `subTreeIDs`. That output locks whether `spec` reads `"Fire"`.

# Talents / spec: the posX-band route (2026-09-24)

The decisive probe killed the subtree route and handed a cleaner one. Forever exposes **no C_Traits
subtrees at all**: `discovered subTreeIDs: (none)`, no `subTreeIDs` on the config, the tree, or any
node, and `GetTraitTreeForSpec` is `nil`. So the Vanilla tree cannot be read from a `subTreeID`.

But the all-nodes `posX` dump is deterministic. The Mage combat config
(`GetConfigsByType(CamelotCombat=4)` -> configID `5921282`, `treeIDs = {1112}`) has **54 nodes whose
`posX` cluster into exactly three bands**:

| Band | posX range | nodes |
|---|---|---|
| low  | 1020..2820  | 105798-105815 |
| mid  | 5020..6820  | 105781-105797 |
| high | 9080..10880 | 105762-105780 |

The one purchased node, `105795`, has `posX = 6220` -> **mid band**, and its entry resolves to spellID
`11069` = "Improved Fireball", a **Fire** talent. So the bands map left -> right onto the classic
talent tabs in tab order: for Mage low = Arcane, mid = Fire, high = Frost. mid = Fire matches - confirmed.

**The read.** For the active combat config, collect `posX` for every node (`GetTreeNodes` +
`GetNodeInfo`), cluster the unique values into 3 bands by splitting at the two largest gaps, and sort the
bands by ascending `posX` -> band index 1,2,3. Assign each purchased node (`ranksPurchased > 0`) to a
band by its `posX`, sum ranks per band, and map the dominant band to a name via a static
`CLASS_TREE_NAMES[classToken]` table (classic Vanilla tab names, ascending-posX order, per class). Spec
= that name; `talents` = one tab per band with purchased points, carrying the band's resolved talent
names (via the existing entry -> definition -> spell chain). For the test Mage this yields
`spec = "Fire"`, `talents = [ { tab = "Fire", points = 1, talents = ["Improved Fireball"] } ]`.

**Fallbacks (no regression).** If the clustering does not yield exactly 3 bands, the class token is not
in the table, or a purchased node's `posX` falls outside every band, the reader falls back to the prior
subtree / dominant-purchased-talent-name behaviour; a spec is still never invented. The banding and the
mapping are verified out of game with a stubbed-API luajit harness on the real posX ranges above.

`/gaarvanguard probe` prints the computed band boundaries (three min/max ranges), each purchased node's
`posX` and assigned band, the per-band summed ranks, the class token, and the final resolved spec + tab
name, so the next in-game run confirms `"Fire"` without guesswork.

# The client did not load addon SavedVariables on early builds (2026-09-18)

**Historical.** This held on build 69913 and is no longer true: on 70291 SavedVariables persist,
account-wide and per character (next section). It is kept because it explains code and comments
that were written while it held.

Settings never survive a reload on this build. Addons write their files correctly and are handed
nothing back.

`GaarCast` recorded what it was given at each stage of loading, into its own saved file:

    ["lastLoad"] = "12:13:10 bound at PLAYER_ENTERING_WORLD
                    [ADDON_LOADED=nil VARIABLES_LOADED=nil
                     PLAYER_LOGIN=nil PLAYER_ENTERING_WORLD=nil]"

`nil` at every stage, against a file the client had written moments earlier with a real saved
size in it. So this is not a matter of binding too early - the table never arrives.

**It is not specific to this suite.** TomTom is the control: its saved arrow position read
`CENTER, -65.99, -19.97` at 11:56 and `CENTER, 0, 0` in the next session, having reset to its
default. A mature third-party addon loses its settings the same way.

Worth knowing for anyone porting here: no addon could persist anything on that build, so a
missing setting after a reload was the client, not the port. It also meant the writing half
could not be tested end to end - a file that looks right on disk proves only that saving works.

**CVars are not a way round it.** `C_CVar.RegisterCVar` works at runtime: a registered CVar can
be set and read back within the session, confirmed in game with
`/dump C_CVar.GetCVar("gaarCastLayout")` returning `player:CENTER:225.8:-28.7::` right after a
drag. It is never written to `Config.wtf`. The file came back byte-identical across the exit,
so what `RegisterCVar` creates here is temporary - `C_CVar.RemoveTempCVar` sitting in the same
namespace was the hint, and this is the confirmation.

So there was no persistence available to an addon on that build at all. The workaround was
written, tested and removed rather than left in place looking like it saved something.

# SavedVariables persist (build 70291, 2026-10-09)

They work now, both kinds. `GaarProbe` carries a persistence canary for exactly this question: on
each login it reads the counter the previous session left, bumps it and writes it back, in an
account-wide table (`GaarProbeDB`, `## SavedVariables`) and a per-character one (`GaarProbeCharDB`,
`## SavedVariablesPerCharacter`), because a client can load one kind and not the other.

| Time | What happened | Canary |
|---|---|---|
| 09:02:14 | First login with the new probe; written, then flushed to disk by `/reload` | #1 written |
| 09:02:17 | After the `/reload`: #1 read back and bumped | #2, YES for both |
| 09:12:10 | Client fully quit, new process started, login on Pala-Tics | #3, YES for both |

The third row is the one that proves it. A `/reload` keeps the process, so in principle a client
could hand the table back from memory; a cold start cannot, so canary #3 came back from the files
on disk. The probe's own record of that login reads `checkedAt = 09:13:18`, `count = 3`, with the
previous canary `#2` from 09:02:17 on the same build.

**Load timing is the normal one.** At file scope both `GaarProbeDB` and `GaarProbeCharDB` are `nil`;
at `ADDON_LOADED` both are tables. So the client runs an addon's files, then loads its
SavedVariables, then fires `ADDON_LOADED`, as retail does, and binding a saved table at
`ADDON_LOADED` is correct here. `GaarCast`'s own load trace agrees: on the same login it recorded
`bound at ADDON_LOADED [ADDON_LOADED=table ...]`, where on 69913 it recorded `nil` at every stage.

**When it started is not pinned.** Earlier files on disk suggest saved variables began coming back
around build 69977 (roughly 2026-09-23 to 09-25), but that is medium confidence. Nobody checked on
the builds in between, which is why the canary now runs on every login.

The CVar finding above (`C_CVar.RegisterCVar` is temporary and never written to `Config.wtf`) was
not retested on 70291. It no longer matters for persistence, since saved variables do the job.

## Now possible

Several things in the suite were shaped by saved variables not coming back. None of them is wrong
now, but each could be reconsidered:

- `GaarVanguard` re-scans the live character at export and never trusts its stored record. That is
  still the right default for the current character, but records for the account's other characters
  now survive between sessions on Forever too, so `exportall` builds a real roster there.
- `GaarCast`'s fallback bar positions were measured by hand because a dragged position never came
  back, and its staged binding and load trace were built to chase the missing table. A dragged
  position should now persist, and the binding could go back to a plain `ADDON_LOADED` bind.
- `GaarMap` moves its clock strip out of the way of TomTom's coordinate block, which used to sit on
  top of it because TomTom forgot its position every session. TomTom should remember it now.

# Forever is its own project now: `WOW_PROJECT_CAMELOT` (18)

On 69913 Forever reported `WOW_PROJECT_ID` = 1, `WOW_PROJECT_MAINLINE`, and the suite relied on that
to treat it as retail. By 70245 it reports 18, and the 70291 probe reads:

    project id 18   constants: WOW_PROJECT_CAMELOT=18 WOW_PROJECT_CLASSIC=2 WOW_PROJECT_ID=18 WOW_PROJECT_MAINLINE=1

So Forever no longer counts as retail. A plain `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE` check is now
false on Forever, and every check of that kind silently started treating it as Classic Era again:

- `GaarBags`: the tidy button went back to Blizzard's `SortBags`, which has crashed this client.
- `GaarCC`: the `SetCooldown` hook went back inside Blizzard's cooldown path.
- `GaarFrames`: the addon went active and tainted the unit frames until it saw a secret value.

Each of those three now asks `IsRetailOrForever()`, which accepts `WOW_PROJECT_MAINLINE` or
`WOW_PROJECT_CAMELOT`. The constant only exists on Forever, so each falls back to a literal 18:

    local CAMELOT = _G.WOW_PROJECT_CAMELOT or 18
    local function IsRetailOrForever()
        local id = _G.WOW_PROJECT_ID
        return id ~= nil and (id == _G.WOW_PROJECT_MAINLINE or id == CAMELOT)
    end

Era (2) and retail (1) behave as before. The rest of the suite does not branch on the project id at
all: it checks for the API it needs (`C_Container`, `C_Item`, `BackdropTemplate` and so on), so it
was not affected. `GaarProbe` and `/gaarvanguard probe` both print the id and its constants.

# The TOC: `_Camelot` at 16001

Every addon now ships a `<Name>_Camelot.toc` at `## Interface: 16001`, a copy of its
`_Mainline.toc` with the interface line changed. This is the suffix the binary pointed at on day
one, and it is what third-party Forever addons ship. The `_Mainline.toc` files still list
`120100, 16001` and `GaarProbe` keeps its plain `GaarProbe.toc` as the fallback for a flavour with
no specific TOC, so whichever file this client picks, the interface matches. The probe does not
record which file was loaded.

# The API on 70291, from the probe

`GaarProbe`'s report for this build (`client 1.60.1 build 70291 (Oct 7 2026) interface 16001`),
per module. "Moved" means a `C_*` namespace carries a function of the same name, which a shim can
follow; "gone" means none does, so a replacement under a different name, or nothing, is the answer.

| Module | Present | Gone | Moved |
|---|---|---|---|
| `GaarBags` | 25 of 37 | - | `ContainerIDToInventoryID`, `GetContainerItemCooldown`, `GetContainerItemInfo`, `GetContainerItemLink`, `GetContainerItemQuestInfo`, `GetContainerNumFreeSlots`, `GetContainerNumSlots`, `PickupContainerItem`, `SortBags` -> `C_Container`; `GetItemQualityColor` -> `C_Item`; `GetCoinTextureString` -> `C_CurrencyInfo`; `GetItemInfo` -> `C_TransmogCollection` (see below) |
| `GaarCC` | 8 of 8 | - | - |
| `GaarCast` | 13 of 13 | - | - |
| `GaarFrames` | 20 of 21 | `UnitBuff` | - |
| `GaarLooter` | 27 of 28 | - | `GetItemInfoInstant` -> `C_Item` |
| `GaarMap` | 9 of 9 | - | - |
| `GaarMeter` | 18 of 20 | `CombatLogGetCurrentEventInfo` | `GetSpellTexture` -> `C_Spell` |
| `GaarOptions` | 9 of 11 | `InterfaceOptionsFrame_OpenToCategory`, `InterfaceOptions_AddCategory` | - |
| `GaarPlates` | 25 of 26 | `UnitAura` | - |
| `GaarSpellBook` | 22 of 33 | `GetNumSpellTabs`, `GetSpellTabInfo`, `IsPassiveSpell`, `SpellBookFrame` | `GetSpellBookItemInfo`, `GetSpellBookItemName`, `GetSpellBookItemTexture`, `PickupSpellBookItem` -> `C_SpellBook`; `GetSpellName`, `GetSpellTexture`, `PickupSpell` -> `C_Spell` |
| `GaarThreat` | 19 of 19 | - | - |
| `GaarUI` | 2 of 4 | - | `GetAddOnMetadata`, `IsAddOnLoaded` -> `C_AddOns` |

What the gone names mean in practice:

- `UnitAura`, `UnitBuff`: replaced by `C_UnitAuras` under new names (`GetAuraDataByIndex`,
  `GetBuffDataByIndex`, `GetDebuffDataByIndex`, `GetAuraDataBySlot`, `GetPlayerAuraBySpellID`, all
  present). `GetAuraDataByIndex` answers with one table, not the old list of values.
- `CombatLogGetCurrentEventInfo`: still no getter anywhere. `C_CombatLog` carries only
  `IsCombatLogRestricted`, `ClearEntries` and `SetMessageLimit`; `GetCurrentEventInfo`,
  `GetCurrentEntryInfo`, `GetEntryCount`, `SeekToNewestEntry`, `SeekToPreviousEntry` and
  `AddEventFilter` are all absent, and `C_CombatLog.IsCombatLogRestricted()` returns `true`.
  `GaarMeter` still cannot read the combat log on this client.
- `InterfaceOptions_AddCategory`, `InterfaceOptionsFrame_OpenToCategory`: replaced by `Settings`
  (`RegisterCanvasLayoutCategory`, `RegisterAddOnCategory`, `OpenToCategory`,
  `RegisterVerticalLayoutCategory`) and `SettingsPanel`. `EasyMenu` is gone; `MenuUtil` and
  `UIDropDownMenu_Initialize` are present.
- `GetNumSpellTabs`, `GetSpellTabInfo`, `IsPassiveSpell`: replaced by
  `C_SpellBook.GetNumSpellBookSkillLines`, `GetSpellBookSkillLineInfo` (one table) and
  `IsSpellBookItemPassive`, as on day one. `SpellBookFrame` is gone and `PlayerSpellsFrame` was not
  loaded at the time, which proves nothing since it is load-on-demand.

Two readings need care. `GetItemInfo` -> `C_TransmogCollection` is the probe taking the first
namespace it found with that name; `C_Item.GetItemInfo` is present too and is the one the suite
uses. And `GetCoinTextureString`, recorded as "nowhere found" on 69913, now shows up under
`C_CurrencyInfo`, which `GaarBags` already tries before formatting coins by hand.

Everything else matches 69913: `C_Container`, `C_Item`, `C_Spell` and `C_SpellBook` are complete for
what the suite uses; the frames are the retail ones (`PlayerFrame.healthbar`,
`PartyFrame.MemberFrame1`, `PlayerCastingBarFrame`, `SettingsPanel`); `SetMinResize` is gone and
`SetResizeBounds` present. The return shapes worth knowing are all tables:
`C_Container.GetContainerItemInfo`, `C_Minimap.GetTrackingInfo`, `C_UnitAuras.GetAuraDataByIndex`,
`C_SpellBook.GetSpellBookSkillLineInfo` and `C_SpellBook.GetSpellBookItemInfo`.
