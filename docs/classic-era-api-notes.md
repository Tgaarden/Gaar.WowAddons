# Classic Era API notes

Findings from porting this suite from a WotLK 3.3.5a private-server codebase to Classic Era
1.15.x. Each one cost a round of "it loads but does nothing", so they are written down.

The general lesson: **a name that looks global need not be one, and a name that existed on
3.3.5a need not exist now.** Check, don't assume. Every one of these was settled by grepping
an installed, actively maintained addon on the same client rather than by memory.

## Renamed or removed since 3.3.5a

| Old | Now | Notes |
|---|---|---|
| `GetSpellName(i, "spell")` | `GetSpellBookItemName` | The old name is gone, not deprecated |
| `GetSpellTexture(i, "spell")` | `GetSpellBookItemTexture` | |
| `PickupSpell` | `PickupSpellBookItem` | |
| `GetContainerNumSlots` and friends | `C_Container.*` | See the table-return trap below |
| `CooldownFrame_SetTimer` | `cd:SetCooldown(start, duration)` | Hook the Cooldown metatable's `SetCooldown` to catch every swipe |
| `GetNumRaidMembers` / `GetNumPartyMembers` | `IsInRaid`, `GetNumGroupMembers`, `GetNumSubgroupMembers` | |
| `PARTY_MEMBERS_CHANGED` | `GROUP_ROSTER_UPDATE` | |
| `SetMinResize` / `SetMaxResize` | `SetResizeBounds` | |
| `texture:SetTexture(r,g,b,a)` | `SetColorTexture` | |
| `EasyMenu` / `UIDropDownMenu` | gone | Build plain widgets instead |
| `PlaySound("igQuestFailed")` | `PlaySound(SOUNDKIT.IG_QUEST_FAILED)` | |

`SetBackdrop` is no longer on a plain frame: create it with the `"BackdropTemplate"` mixin.

## Traps that fail silently

**`C_Container.GetContainerItemInfo` returns a table**, not a list of values. Reading it the
old way yields `nil` with no error, so icons and counts just come out empty.

**`GetItemInfo` is asynchronous** and returns `nil` for an item the client has not cached.
Never freeze its results into saved data - store the link and resolve at display time.
`GetItemInfoInstant` is synchronous and safe.

**Aura returns lost the old rank value**, so the icon moved from the third return to the
second. Read it the old way and you show the wrong texture, with nothing to indicate a fault.

**`UnitCastingInfo` / `UnitChannelInfo` lost `nameSubtext`**, so the texture and both
timestamps sit one slot earlier than on 3.3.5a.

**The combat log passes nothing to the event handler.** Fetch it with
`CombatLogGetCurrentEventInfo()`, and note the payload gained `hideCaster` plus two raid-flag
fields: every argument is three slots later than it was.

**Pawn's `PawnIsInitialized` is file-local**, so `_G.PawnIsInitialized` is always `nil`.
Gating on it disables everything downstream and looks like the feature simply not working.
`PawnCommon` is a saved variable and therefore genuinely global.

## Taint

**Never replace a Blizzard global.** Assigning over `ToggleBackpack`, `OpenAllBags` and the
rest puts addon code in the call chain whenever the stock UI uses them, and the taint that
spreads makes the game refuse protected actions later - it surfaces as *"blocked from an
action only available to the Blizzard UI"* when you try to use an item, far from the cause.
Use `hooksecurefunc` instead.

One consequence worth planning for: these functions call each other. `ToggleAllBags` calls
`ToggleBackpack` and `ToggleBag`, so a single keypress reaches several hooks. Collapse the
requests into one action per frame or the window toggles an even number of times and never
appears to move.

## The forward-reference trap

A `local` used above its own declaration resolves as a **global**, which is `nil` at runtime.
The parser accepts it, so syntax checking never sees it. This bit repeatedly here -
`MineRow`, `MarkDirty`, `bagButtons`, `charFilter` - and is why `tools/check.sh` dumps the
globals each file touches. A helper of your own in that list is the bug.

## Things that do exist here, contrary to expectation

- **The real threat API.** `UnitDetailedThreatSituation` and `UNIT_THREAT_LIST_UPDATE` both
  work, so a threat meter needs no combat-log estimation. Raw values come back 100x, which is
  why other Classic threat meters divide by 100.
- **The modern nameplate API**, `C_NamePlate` with real unit tokens per plate.
- **The modern map frame**, `WorldMapFrame` with `ScrollContainer`, `GetCanvas`, `BorderFrame`.

## Things that do not

- **No event reports other players' loot rolls.** `START_LOOT_ROLL` gives the item, but the
  choices, roll numbers and winner only arrive as chat lines built from the `LOOT_ROLL_*`
  global format strings. Derive patterns from those globals at load rather than hardcoding
  English, and correlate by item link, which every one of those lines carries.
- **No focus unit.** Detect it rather than assuming; `FocusFrame` is a usable signal.
- **`WorldMapFrame` cannot simply be dragged.** It is a managed UI panel: the panel system
  anchors it and re-anchors it on every show. Detaching it was attempted and abandoned.

## Textures

Icon paths fail silently, rendering blank rather than erroring. `INV_Misc_Broom_01` is not
present on this client. `Interface\Buttons\*` has been reliable. Where a glyph matters, draw
it from plain coloured rectangles - it cannot go missing.
