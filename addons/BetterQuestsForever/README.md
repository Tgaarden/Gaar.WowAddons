# BetterQuestsForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). It
changes how the **Quests** section of Blizzard's own objective tracker (`QuestObjectiveTracker`)
orders and limits the tracked quests, and does nothing else. It needs no other addon or library.

## What it does

- **Order.** Tracked quests are shown by quest level, lowest first (the `[n]` the tracker shows,
  `C_QuestLog.GetInfo(logIndex).level`, falling back to `difficultyLevel`). Quests of the same
  level are ordered by title, ignoring case.
- **Completed quests.** Quests that are ready to turn in (`C_QuestLog.IsComplete`) go to the
  **bottom** by default. `/bqf completed top` puts them first; `/bqf completed level` sorts
  them among the others by level.
- **Limit.** Only the first **N** quests of that order are shown (default **10**, 1-49, or all).
  With 30 tracked quests and N = 10, you see the 10 lowest-level quests that are not complete.
  When one of them completes it moves to the bottom, out of the 10, and the next tracked quest
  takes its place.
- **Every tracked quest stays tracked, and the watch list is never touched.** The addon does not
  call `AddQuestWatch`, `RemoveQuestWatch` or `SortQuestWatches`. The order and the limit only
  change what the tracker draws. The quest log, the map and the watch count still see all of them.
- **Only the Quests section.** Campaign quests, world quests, bonus objectives, achievements,
  professions and every other section are left alone.
- It re-evaluates after every layout of the Quests section, and also (throttled to once per
  0.3 s) after `QUEST_LOG_UPDATE`, `QUEST_WATCH_LIST_CHANGED`, `QUEST_ACCEPTED`,
  `QUEST_REMOVED`, `QUEST_TURNED_IN`, `PLAYER_LEVEL_UP`, login and the end of combat. A
  settings change is applied at once (after combat if you are in one).

- **Backdrop.** An optional plain dark rectangle (black, 50% opacity by default) behind the
  whole objective tracker, from just above the "All Objectives" header down to the last visible
  block, with 4 px of padding. It follows the content as it grows and shrinks (including after
  the order and the limit change the height) and is hidden when the tracker is hidden, collapsed
  or empty. See [Backdrop](#backdrop).
- **Hide in combat** (default on). When a fight starts the whole objective tracker ("All
  Objectives", every section) and the backdrop are hidden; when it ends the tracker comes back,
  sorted and limited as before, with its backdrop. It only comes back if it was shown when the
  fight started, so a tracker Blizzard had hidden (no quests, a cinematic) stays hidden. Off, the
  tracker stays visible in combat with Blizzard's own order, as in 1.2. See
  [Hide in combat](#hide-in-combat).

## Commands

| Command | Does |
|---|---|
| `/bqf` | Help |
| `/bqf max <n>`, `/bqf max all` | Show at most n quests, 1-49 (default 10); `all` (stored as 50) shows every one, still sorted |
| `/bqf completed top`, `level`, `bottom` | Where quests ready to turn in go (default bottom) |
| `/bqf on`, `/bqf off` | Switch on or off. Off puts the section back exactly as Blizzard laid it out |
| `/bqf bg on`, `/bqf bg off` | Show or hide the backdrop behind the tracker (default on) |
| `/bqf bg <0-100>` | Backdrop opacity in percent (default 50; values outside 0-100 are clamped) |
| `/bqf combat on`, `/bqf combat off` | Hide the whole objective tracker during combat (default on) |
| `/bqf minimap` | Show or hide the minimap button |
| `/bqf minimap reset` | Minimap button back to its default place (285 degrees) and shown |
| `/bqf status` | On/off, max, completed mode, how many quests are tracked and shown, whether the tracker was recognised, which hooks are in place, `order: visual (applied to N blocks)` or why it could not be applied, which client functions exist, whether hide in combat is ready (or why not), whether `ObjectiveTrackerFrame` is shown and protected, and the minimap button's state |

## Minimap button

Left- or right-click opens a menu with the same settings: **Enabled** (checkbox), **Max quests
shown** (3, 5, 8, 10, 12, 15, 20, 25, All), **Completed quests** (Top, By level, Bottom),
**Backdrop** (checkbox), **Backdrop opacity** (20, 35, 50, 65, 80 %), **Hide in combat**
(checkbox) and **Hide minimap button** (`/bqf minimap` brings it back). Changes apply at once. Drag the button
to move it around the minimap's edge; on a square minimap (`GetMinimapShape() == "SQUARE"`,
e.g. with GaarMap) it follows the square edge. The menu is Blizzard's `MenuUtil` where the
client has it, otherwise a small menu drawn by the addon (never `UIDropDownMenu`). The placement
code is a copy of GaarVanguard's, so this addon still has no dependencies; its default angle
(285 degrees) keeps it clear of GaarOptions (205) and GaarVanguard (245).
`BetterQuestsForever_PlaceMinimapButton()` re-places it, for an addon that changes the minimap's
shape.

Settings are saved in `BetterQuestsForeverDB` (`enabled`, `max`, `completed`, `hideInCombat`,
`backdrop = { enabled, alpha }` (alpha 0-1), `minimap = { hide, angle }`), read at `ADDON_LOADED`, never at file scope.

## How it works

Version 1.0 set the order in the client's watch list. Forever orders the watch list itself (a
re-added watch is not appended at the end), so that cannot work there. Since 1.1 the order is
purely visual, applied on top of Blizzard's layout:

- **Hooks.** `hooksecurefunc` on the `QuestObjectiveTracker` instance's `Update` and
  `UpdateHeight` runs after Blizzard has laid the section out, out of combat only.
- **Blizzard's layout, measured.** Blizzard lays the quest blocks out as a chain
  (`ObjectiveTrackerModuleMixin:AnchorBlock`): the first block's `TOP` on the section's
  `ContentsFrame` `TOP` at `fromHeaderOffsetY`, every next block's `TOP` on the previous
  block's `BOTTOM` at `fromBlockOffsetY`, and `contentsHeight` grows by each block's height
  minus that offset. The addon reads those anchors back with `GetPoint`, so the spacing it uses is
  Blizzard's own, measured from the layout (the module's offset fields are only a fallback).
- **Re-anchored in sorted order.** The quest blocks are sorted with the order above and the
  first N are re-anchored top to bottom: the first on the same point Blizzard used for its first
  block, each next one on the `BOTTOM` of the one above it in the new order, with the offset
  Blizzard used at that position. Only the `TOP` point is replaced; the block's `LEFT`/`RIGHT`
  points stay Blizzard's. Blocks that are not tracked quests (a quest pop-up, or a block
  Blizzard keeps for a moment after a turn-in) stay on top in Blizzard's order and are not
  counted toward N.
- **The rest hidden.** Blocks after the N-th are hidden with `Hide()`, along with their
  `addedRegions` (item button, find-group button, progress and timer bars). Those frames are
  parented to the section, not to the block, so they are hidden one by one.
- **Buttons follow their block.** Blizzard anchors the item and find-group buttons to their
  own block (`AddRightEdgeFrame`: `TOPRIGHT` on the block, or `RIGHT` on the block's previous
  right-edge frame) and progress and timer bars to the block's lines, so they move with their
  block. Nothing of theirs is re-anchored.
- **Height.** The section's frame gets Blizzard's height minus what Blizzard added for its
  blocks plus what the shown blocks take with the same offsets, so the sections below move up
  with no gap.
- **Put back exactly.** Before moving a block the addon records Blizzard's anchor for it. Off,
  combat, or a problem: every moved block goes back on Blizzard's anchor (in chain order, so no
  anchor loop can form), every hidden frame is shown again (only while Blizzard still uses it for
  the same block), and the section gets Blizzard's height again.
- **Combat.** Nothing changes while `InCombatLockdown()` is true. On `PLAYER_REGEN_DISABLED`,
  which fires just before the lockdown starts, the layout is put back as above, so during a fight
  the Quests section is exactly Blizzard's own (every tracked quest is visible, in Blizzard's
  order). On `PLAYER_REGEN_ENABLED` the order and the limit are applied again.

**Limitation.** Blizzard only lays out as many quests as fit in the tracker's height. If the
tracker is too short for every tracked quest, the addon sorts the ones Blizzard laid out; a
quest Blizzard did not lay out cannot be shown.

## Backdrop

The backdrop is the addon's own frame (`BetterQuestsForeverBackdrop`, parent `UIParent`, strata
`BACKGROUND`, mouse disabled) with a solid black texture. It is independent of the `on`/`off`
switch for ordering and limiting. It is placed by absolute coordinates, never anchored to a
Blizzard frame:

- **Measured, not anchored.** The addon reads `GetLeft`/`GetRight`/`GetTop`/`GetBottom` of
  `ObjectiveTrackerFrame.Header`, of each shown tracker module and of each shown block of those
  modules (scaled to `UIParent`'s coordinates), and covers them: the top is the header's, the
  bottom the lowest visible block's, left and right the widest of the lot. Blocks the limit
  hides are not shown, so they do not count.
- **When.** `hooksecurefunc` on `ObjectiveTrackerFrame` and each module (`Update`, `UpdateHeight`,
  `SetCollapsed`) and `HookScript` (`OnShow`, `OnHide`, `OnSizeChanged`) only set a flag; our own
  frame measures on the next frame, and every 0.1 s anyway, so a dragged or rescaled tracker is
  followed too. The addon's own layout pass sets the flag as well.
- **Hidden** when the tracker frame is hidden or collapsed, or when no module has a visible block.
- **Combat.** With hide in combat on, the backdrop is hidden for the fight together with the
  tracker. With it off, the backdrop only reads Blizzard's positions and writes to its own frame,
  so it keeps following the tracker in combat. `/bqf status` shows why it is hidden, if it is.
- **Moving the tracker** is Blizzard's Edit Mode. A move fires none of the hooks, but the 0.1 s
  measurement picks up the new position, so the backdrop follows.

## Hide in combat

`ObjectiveTrackerFrame` is not a protected frame, so the client lets it be hidden in combat. The
catch is what runs when it is hidden or shown: its `OnHide` (`ManagedFrameMixin`,
`EditModeSystemMixin:OnSystemHide`) calls `RightManagedFrameContainer:RemoveManagedFrame`, which
writes the container's `showingFrames`, calls `ObjectiveTrackerFrame:UpdateHeight` and lays out
the right-hand container (which also holds the boss and arena frames, which are protected); its
`OnShow` calls `AddManagedFrame` (`SetParent` and `Layout`) and `UpdateHeight`, whose
`OnSizeChanged` marks the tracker dirty. Whoever calls `Hide()` or `Show()` runs all of that. From
addon code it would run tainted, and the tracker update that sets the quest item buttons'
`questLogIndex` attribute would carry the taint, so a click on a quest item would be blocked.
Fading it instead (alpha) would leave the item buttons clickable. So the addon never calls
`Hide()` or `Show()` on it.

A secure handler of the addon's own with a frame reference to the tracker does not work either:
the restricted environment refuses a handle to a frame that is not protected while
`InCombatLockdown()` is true (`RestrictedFrames.lua`, "Invalid frame handle"), and a state driver
only reaches that handler after the lockdown has started.

What it does instead:

- On `PLAYER_REGEN_DISABLED` (which fires just before the lockdown starts) it notes whether the
  tracker is shown and registers Blizzard's state driver on it:
  `RegisterStateDriver(ObjectiveTrackerFrame, "visibility", "hide")`. `SecureStateDriverManager`
  hides it at once from its own secure code, so `OnHide` and everything it calls run untainted.
- If Blizzard shows the tracker during the fight (its update does, on a quest update), the driver
  hides it again within its 0.2 s throttle, so it can blink for a moment. The backdrop stays
  hidden throughout.
- On `PLAYER_REGEN_ENABLED` (just after the lockdown ends), if the tracker was shown when the
  fight started, the driver is set to `show` once (Blizzard's code shows it, untainted) and then
  removed with `UnregisterStateDriver`. After that the order, the limit and the backdrop are
  applied again as after any fight.
- The driver is on the tracker only between those two events. Out of combat Blizzard's own
  show/hide logic is never overridden. The driver itself sets the tracker's `statehidden`
  attribute (`true` when it hides, `nil` when it shows), which nothing in the tracker reads; it
  stays `true` after a fight where the tracker was hidden to begin with.
- It is independent of `/bqf on`/`off` (which only switches the order and the limit) and of the
  backdrop setting.
- A change of the setting during a fight applies from the next fight; turning it off during a
  fight still brings the tracker back when the fight ends.
- If the client has no `RegisterStateDriver`, if there is no `ObjectiveTrackerFrame`, or if the
  lockdown had already started when the event arrived, nothing is hidden (there is no insecure
  fallback) and `/bqf status` says why.

## Taint

The Quests section carries quest item buttons. Clicking one runs Blizzard's
`QuestObjectiveItemButtonMixin:OnClick`, which reads the button's `questLogIndex` attribute and
calls the protected `UseQuestLogSpecialItem`. That attribute is set by Blizzard's layout
(`UpdateSingle` -> `AddRightEdgeFrame` -> `SetUp` -> `SetAttribute`). If addon code ever ran
inside that layout, or left a value Blizzard's layout reads, the attribute would be set from
tainted code and the click would be blocked (`ADDON_ACTION_BLOCKED`). So:

- No Blizzard function is replaced, global or method, and the watch list is never changed, so
  no client event is raised from addon code.
- The addon never writes a field into a Blizzard table, never calls a Blizzard Lua function of
  the tracker (`MarkDirty`, `Update`, `UpdateHeight`, ...), never sets an attribute and never
  calls a protected function. Hide in combat goes through Blizzard's public
  `RegisterStateDriver`/`UnregisterStateDriver`, out of the lockdown only; see
  [Hide in combat](#hide-in-combat). Its only effect on the tracker is the widget methods `GetPoint`,
  `SetPoint`, `Hide`, `Show` and `SetHeight`, from inside `hooksecurefunc` hooks (which do not
  taint the caller), out of combat.
- Before each pass it checks every frame it would touch. If a quest block is protected or
  anchoring-restricted (`IsProtected()`, `IsAnchoringRestricted()`), or an item button or bar it
  would hide is protected, or the section itself is, that pass changes nothing (Blizzard's layout
  is put back) and `/bqf status` says why.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source),
`Interface/AddOns/Blizzard_ObjectiveTracker`): `QuestObjectiveTracker` (its `Update`,
`UpdateHeight`, `usedBlocks`, `blockTemplate`, `firstBlock`, `ContentsFrame`,
`contentsHeight`, `bottomSpacing`, `heightModifiers`, `fromHeaderOffsetY`,
`fromBlockOffsetY`), the blocks' `nextBlock`, `template`, `id`, `height`, `used`,
`parentModule`, `addedRegions`; `C_QuestLog.GetNumQuestWatches`,
`GetQuestIDForQuestWatchIndex`, `GetLogIndexForQuestID`, `GetInfo`, `IsComplete`,
`IsQuestDisabledForSession`; `C_QuestInfoSystem.GetQuestClassification` with
`Enum.QuestClassification.Campaign`; `ObjectiveTrackerFrame`, `RegisterStateDriver`,
`UnregisterStateDriver`; `MenuUtil.CreateContextMenu`, `Minimap`, `GetMinimapShape`. Every one is checked before use. If the tracker is not recognised the addon
does nothing and `/bqf status` says what is missing.

It ships a `_Camelot` TOC and a plain fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).
