# BetterQuestsForever

A small standalone addon for the WoW Forever client (`_classic_beta_`, interface 16001). It
changes how the **Quests** section of Blizzard's own objective tracker (`QuestObjectiveTracker`)
orders and limits the tracked quests, and does nothing else. It needs no other addon or library.

## What it does

- **Order.** Tracked quests are shown by quest level, lowest first (the `[n]` the tracker shows,
  `C_QuestLog.GetInfo(logIndex).level`, falling back to `difficultyLevel`). Quests of the same
  level are ordered by title, ignoring case.
- **Completed quests.** Quests that are ready to turn in (`C_QuestLog.IsComplete`) go to the
  **bottom** by default. `/bqf completed top` puts them first; `/bqf completed level` sorts
  them among the others by level.
- **Limit.** Only the first **N** quests of that order are shown (default **10**, 1-50). With
  30 tracked quests and N = 10, you see the 10 lowest-level quests that are not complete. When
  one of them completes it moves to the bottom, out of the 10, and the next tracked quest takes
  its place.
- **Every tracked quest stays tracked.** The limit only changes what the tracker draws. The
  quest log, the map and the watch count still see all of them.
- **Only the Quests section.** Campaign quests, world quests, bonus objectives, achievements,
  professions and every other section are left alone.
- It re-evaluates on its own (throttled to once per 0.3 s) after `QUEST_LOG_UPDATE`,
  `QUEST_WATCH_LIST_CHANGED`, `QUEST_ACCEPTED`, `QUEST_REMOVED`, `QUEST_TURNED_IN`,
  `PLAYER_LEVEL_UP`, login and the end of combat.

## Commands

| Command | Does |
|---|---|
| `/bqf` | Help |
| `/bqf max <n>` | Show at most n quests, 1-50 (default 10) |
| `/bqf completed top`, `level`, `bottom` | Where quests ready to turn in go (default bottom) |
| `/bqf on`, `/bqf off` | Switch on or off. Off shows every tracked quest again and hands the order back to Blizzard's own sort (`C_QuestLog.SortQuestWatches`, the one the tracker runs on zone changes) |
| `/bqf status` | On/off, max, completed mode, how many quests are tracked and shown, whether the tracker was recognised, which hooks are in place, which client functions exist, and why sorting or the limit is off if it is |

Settings are saved in `BetterQuestsForeverDB` (`enabled`, `max`, `completed`), read at
`ADDON_LOADED`, never at file scope.

## How it works

- **Order: the watch list itself.** Blizzard's tracker lists the Quests section in watch-list
  order (`QuestObjectiveTrackerMixin:BuildQuestWatchInfos` walks
  `C_QuestLog.GetQuestIDForQuestWatchIndex` and keeps that order). The addon moves quests that
  are out of place to the end of the list: `C_QuestLog.RemoveQuestWatch` immediately followed by
  `C_QuestLog.AddQuestWatch` with the quest's old watch type (`C_QuestLog.GetQuestWatchType`),
  so every quest is tracked again before the next line of code runs. Only the quests that have
  to move are touched; campaign quests, tasks and bounties never are. At the end it checks that
  every quest tracked before is still tracked (and re-tracks it if the client dropped it), and
  puts the super-tracked quest back if that changed. If the client does not append a re-added
  watch at the end, or keeps putting its own order back (more than 15 reorders in 10 s), sorting
  switches off and `/bqf status` says why; `/bqf on` tries again.
- **Limit: hidden after Blizzard's layout.** `hooksecurefunc` on the `QuestObjectiveTracker`
  instance's `Update` and `UpdateHeight` runs after Blizzard has laid the section out. The addon
  hides the quest blocks after the N-th with `Hide()`, along with the frames Blizzard places next
  to them (item button, find-group button, progress and timer bars: the block's
  `addedRegions`), and shortens the section's frame by exactly the height Blizzard added for
  those blocks, so the sections below move up. Frames are shown again only while Blizzard still
  uses them for the same block.
- **Combat.** Nothing changes while `InCombatLockdown()` is true. On `PLAYER_REGEN_DISABLED`,
  which fires just before the lockdown starts, everything the addon hid is shown again, so during
  a fight the Quests section is exactly Blizzard's own (every tracked quest is visible). On
  `PLAYER_REGEN_ENABLED` the order and the limit are applied again.

## Taint

The Quests section carries quest item buttons. Clicking one runs Blizzard's
`QuestObjectiveItemButtonMixin:OnClick`, which reads the button's `questLogIndex` attribute and
calls the protected `UseQuestLogSpecialItem`. That attribute is set by Blizzard's layout
(`UpdateSingle` -> `AddRightEdgeFrame` -> `SetUp` -> `SetAttribute`). If addon code ever ran
inside that layout, or left a value Blizzard's layout reads, the attribute would be set from
tainted code and the click would be blocked (`ADDON_ACTION_BLOCKED`). So:

- No Blizzard function is replaced, global or method. `ShouldDisplayQuest` is not touched.
- The addon never writes a field into a Blizzard table, never calls a Blizzard Lua function of
  the tracker (`MarkDirty`, `Update`, `UpdateHeight`, ...), never sets an attribute and never
  calls a protected function. Its only effect on the tracker is the widget methods `Hide`,
  `Show` and `SetHeight`, from inside `hooksecurefunc` hooks (which do not taint the caller),
  out of combat, on frames that are not protected. If a quest block or one of its frames reports
  `IsProtected()`, the limit switches off on that client.
- The order reaches Blizzard only through the client's watch list, so Blizzard's layout reads
  client values, not addon values.

**Residual risk.** `RemoveQuestWatch` / `AddQuestWatch` raise `QUEST_WATCH_LIST_CHANGED`. If the
client dispatches that event synchronously, inside the addon's call, Blizzard's tracker handler
would run in the addon's execution and its dirty flag would be written by tainted code; the
next tracker update could then set up the item buttons tainted, until a later clean update.
Whether Forever dispatches it that way can only be checked in game (`/console taintLog 1`, see
the test steps in the PR). It only happens when the order actually changes, never in combat.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source),
`Interface/AddOns/Blizzard_ObjectiveTracker`): `QuestObjectiveTracker` (its `Update`,
`UpdateHeight`, `BuildQuestWatchInfos`/`EnumQuestWatchData`, `usedBlocks`, `blockTemplate`,
`firstBlock`, `contentsHeight`, `bottomSpacing`, `heightModifiers`, `fromBlockOffsetY`), the
blocks' `nextBlock`, `template`, `id`, `height`, `used`, `parentModule`, `addedRegions`;
`C_QuestLog.GetNumQuestWatches`, `GetQuestIDForQuestWatchIndex`, `AddQuestWatch`,
`RemoveQuestWatch`, `GetQuestWatchType`, `GetLogIndexForQuestID`, `GetInfo`, `IsComplete`,
`IsQuestDisabledForSession`, `SortQuestWatches`; `C_QuestInfoSystem.GetQuestClassification`
with `Enum.QuestClassification.Campaign`; `C_SuperTrack`. Every one is checked before use. If
the tracker is not recognised the addon does nothing and `/bqf status` says what is missing.

It ships a `_Camelot` TOC and a plain fallback TOC, both at 16001.
