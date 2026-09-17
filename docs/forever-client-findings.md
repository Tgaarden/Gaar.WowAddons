# WoW Forever: what the client on disk says

Read off the installed beta client on 2026-09-17, before any character login was possible.
Method: extract the strings from each client binary and diff Forever against Classic Era, so
that "absent" only counts where Era has the same literal. Era is the control precisely because
the suite is known to work on it.

    strings -n 3 ".../World of Warcraft Beta.app/Contents/MacOS/World of Warcraft" | sort -u

## What it is

| | |
|---|---|
| Install folder | `_classic_beta_` |
| Product flavor (`.flavor.info`) | `wow_classic_beta` |
| Version | `1.60.1.69893` |
| Branch codename | `Camelot` (see below) |

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
