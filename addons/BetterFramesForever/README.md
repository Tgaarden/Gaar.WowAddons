# BetterFramesForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). It draws
X-Perl-style unit frames of its own for the player, target, target of target, focus, pet and
party, and switches Blizzard's off. It needs no other addon or library.

## What it does

- **Frames.** Player, target, target of target, focus (only where the client has a focus unit),
  pet and party1-4. No raid frames and no XP bar.
- **X-Perl layout.** A name bar on top with the name, the level (coloured by difficulty, `??` for
  a boss) and, for players, a class icon; NPCs get an `Elite`, `Rare`, `Rare Elite` or `Boss`
  tag there instead. The portrait sits on the left (2D by default, a 3D model as an option), the
  health and power bars on the right with `cur/max  NN%` text, all on a dark see-through
  backdrop with a thin border. Target of target and pet are smaller, the party frames are a
  compact version of the same. A unit that is dead, a ghost or offline says so in its health bar.
- **Colours.** Class colour for players, reaction colour for NPCs, grey when someone else tagged
  the mob. Under 35% health the bar turns orange, under 20% red (option, on by default). The
  power bar is coloured by power type (mana, rage, energy, focus).
- **Target.** Combo points above the frame for rogues and druids. A row of buffs and a row of
  debuffs under it, up to 16 each, with stacks and a cooldown swipe; your own debuffs are larger
  with a bright border, other debuffs are smaller and greyed. Elites and bosses get a gold
  border, rares a silver one.
- **Party.** Small debuffs and buffs under each frame (up to 8 each), and the frame fades to 50%
  when the member is out of range.
- **Icons.** Raid target icon on every frame, group leader on the player and party frames, combat
  and resting on the player portrait, and a coloured border round any frame with threat
  (yellow, orange, red).
- **Click.** Left-click targets the unit, right-click opens Blizzard's own unit menu.
- **Move.** `/bff unlock` and drag a frame (out of combat; the border turns blue while unlocked).
  The party frames move as one block. Each frame has its own scale, 0.6 to 1.5. Positions and
  scales are saved account-wide in `BetterFramesForeverDB`. `/bff reset` puts them back.
- **Test mode.** Shows every enabled frame with made-up data, the party included without a group,
  so they can be placed. Out of combat only; entering combat ends it. Not saved.

Not in 1.0: raid frames, an XP bar, an options panel, a minimap button, cast bars on the frames
(use BetterCastbarsForever), click-casting.

## Commands

| Command | Does |
|---|---|
| `/bff`, `/bff help` | Help, with the current settings |
| `/bff status` | Settings, each frame and its scale, what this client allows (secure frames, focus, hidden values, text for hidden values, range), which Blizzard frames are switched off, anything the client refused, changes waiting for the end of combat, and conflicting unit-frame addons |
| `/bff lock`, `/bff unlock` | Stop or allow dragging the frames (locked by default) |
| `/bff test`, `/bff test on\|off` | Test mode with made-up data |
| `/bff reset` | Positions and scales back to the defaults |
| `/bff scale <player\|target\|tot\|focus\|pet\|party> <0.6-1.5>` | One frame's scale (`120` works for 1.2 too) |
| `/bff frame <player\|target\|tot\|focus\|pet\|party> on\|off` | Which frames are drawn (without `on`/`off`: toggle) |
| `/bff portrait 2d\|3d` | 2D portrait (default) or 3D model |
| `/bff text on\|off` | `cur/max  NN%` text on the bars (on by default) |
| `/bff lowhp on\|off` | Orange under 35%, red under 20% (on by default) |
| `/bff classcolor on\|off` | Class colour for players (on by default; off: green) |

`/betterframesforever` works the same as `/bff`. `targettarget` works for `tot`.

## With BetterGaarForever (optional)

[BetterGaarForever](../BetterGaarForever/README.md) is an optional hub: one minimap button whose
menu has a submenu per Better...Forever addon. Its **Frames** row is in BetterGaarForever 2.4
and later; older versions of the hub do not list it. The submenu has **Lock**, **Test mode**,
**Frames** (a checkbox per frame), **Portrait** (2D or 3D), **Bar text**, **Low-health colour**,
**Class colour** and **Reset positions & scales**, the same settings as `/bff` (both go through
the same functions). This addon has no minimap button or menu of its own, so nothing here
changes with or without the hub.

The hub talks to this addon only through `BetterFramesForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `unlocked · 6 frames · 2D` (` · test mode` while testing) |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, submenu }`, `{ divider }`), for a menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide. It is there so every addon the hub knows has the same API |

## How it stays out of the way

- **Own frames, not Blizzard's restyled.** [GaarFrames](../GaarFrames/GaarFrames.lua) restyles
  Blizzard's unit frames in place, and turns itself off on Forever: writing to those frames
  taints them, and once the client hands out secret values Blizzard's own code inside a tainted
  frame can no longer compare them (`Blizzard_UnitFrame/Mainline/UnitFrame.lua:777` in the taint
  log). So this addon never writes to Blizzard's unit frames. It builds its own, the way X-Perl
  and oUF do.
- **Secure frames, changed only out of combat.** Each frame is a `SecureUnitButtonTemplate`
  button with `unit`, `type1 = "target"` and `type2 = "togglemenu"` set once, at creation, out of
  combat. `RegisterUnitWatch` shows and hides every frame but the player's. Creating, showing,
  hiding, moving and scaling a secure frame happen only out of combat; asked for in combat
  (`/bff scale`, `/bff frame`, `/bff reset`, a login or `/reload` in combat), the change is
  queued and made at `PLAYER_REGEN_ENABLED`, with one line in chat. In combat the addon only
  paints: bars, text, icons and alpha. A drag in progress when combat starts is ended and saved
  first.
- **How Blizzard's frames are switched off.** oUF's `DisableBlizzard` approach, out of combat
  only, when a frame of ours is switched on (at login, or `/bff frame <x> on`): the Blizzard frame
  gets `UnregisterAllEvents()`, `Hide()` and is re-parented to a hidden frame of the addon's own
  (`BetterFramesForeverHiddenParent`); its health, mana, cast, buff and similar sub-frames lose
  their events too. Player: `PlayerFrame`. Target: `TargetFrame` and `ComboFrame`. Target of
  target: `TargetFrameToT`. Focus: `FocusFrame`, `FocusFrameToT`, `TargetofFocusFrame`. Pet:
  `PetFrame`. Party: `PartyFrame` (its member frames `PartyFrame.MemberFrame1-4` lose their
  events and are hidden, but are not re-parented, as in oUF) or the old `PartyMemberFrame1-4`.
  Every name is checked first; a missing one is skipped. **`CompactPartyFrame`** (the raid-style
  party frames) is deliberately left alone: if "Use Raid-Style Party Frames" is on in Edit Mode,
  turn it off or you see both.
- **The trade-off.** Events cannot be handed back, so turning a frame off (`/bff frame <x> off`)
  hides ours at once but brings Blizzard's back only after `/reload`. With `PlayerFrame` gone,
  anything Blizzard hangs off it goes too (a class bar under the player frame, for example); the
  combo points on our target frame are there for that reason. Vehicle art on the player frame is
  not handled.
- **Edit Mode.** After `EDIT_MODE_LAYOUTS_UPDATED` and every loading screen the addon checks,
  out of combat, that the frames it parked are still parked and hidden. If doing so ever raises
  an error, switching Blizzard's frames off is stopped for the session with one line in chat,
  rather than an error every time.
- **Hidden (secret) values.** The bars always get the raw values (`SetMinMaxValues(0, max)`,
  `SetValue(cur)`): a StatusBar takes a secret. Nothing is worked out from a secret: no
  comparison, no sum, no boolean test, not even `x or y`. The `cur/max  NN%` text is written from
  plain numbers when they are plain. When they are hidden, the client's own secret-safe helpers
  are used where it has them (`AbbreviateNumbers` for `cur/max`, `UnitHealthPercent` /
  `UnitPowerPercent` with `CurveConstants.ScaleTo100` for the percent, written with
  `SetFormattedText`); without them the text is left empty and the bar alone shows the value.
  The low-health and class colours are used only when they can be worked out; a hidden threat
  status, level or classification is dropped. Party range uses `UnitInRange`; a hidden answer
  goes straight to `SetAlphaFromBoolean` where the client has it. Aura timings that are hidden
  use the client's duration object (`C_UnitAuras.GetAuraDuration` and
  `SetCooldownFromDurationObject`) where it has one.
- **One refusal, one message.** `issecretvalue` does not flag everything, so each part of a
  frame's update (health, power, name and level, portrait, icons, threat, auras, range, combo
  points, text for hidden values) runs inside `pcall`. The first refusal switches that part off
  for the session on every frame, with one line in chat and a note in `/bff status`, instead of
  an error on every event.
- **Test mode does not touch the secure frames.** The previews are plain, non-secure frames of
  their own, filled with made-up data; the real frames only go see-through (`SetAlpha(0)`) under
  them, with every attribute and the unit watch as they were.
- **Other unit-frame addons.** If `GaarFrames`, `XPerl`, `XPerl_Player`, `ShadowedUnitFrames` or
  `PitBull4` is loaded, a one-time warning is printed at login and `/bff status` repeats it.
  Nothing is disabled: use one of them.
- Events are registered with `pcall`, so an event this client does not have is skipped. Target
  of target has no events of its own, so it and party range are refreshed by a light 0.2 s
  ticker; everything else is event-driven.
- Party frames follow `RegisterUnitWatch`, so in a raid they show your own subgroup.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Only `locked`, `portrait`,
  `text`, `lowhp`, `classColor`, `frames`, `scales` and `positions` are kept, each type-checked
  (scales clamped to 0.6-1.5, positions with a missing field dropped); anything else is cleared
  on load. A position is saved only when none of its numbers is secret. Test mode is never saved.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source)): `SecureUnitButtonTemplate`
(with the `togglemenu` action), `RegisterUnitWatch` / `UnregisterUnitWatch`, `BackdropTemplate`,
`CooldownFrameTemplate`; the frames `PlayerFrame`, `TargetFrame`, `ComboFrame`, `TargetFrameToT`,
`FocusFrame`, `FocusFrameToT`, `TargetofFocusFrame`, `PetFrame`, `PartyFrame` (and
`PartyFrame.MemberFrame1-4`, `PartyMemberFramePool`) or `PartyMemberFrame1-4`; the tables
`RAID_CLASS_COLORS`, `CLASS_ICON_TCOORDS`, `FACTION_BAR_COLORS`, `PowerBarColor`,
`DebuffTypeColor` and `CurveConstants`; `GameTooltip_SetDefaultAnchor`.

Unit API (every one of these is a string in Forever's client binary, build 70790; the FrameXML names above cannot be read off disk and are feature-detected): `UnitHealth`,
`UnitHealthMax`, `UnitPower`, `UnitPowerMax`, `UnitPowerType`, `UnitHealthPercent`,
`UnitPowerPercent`, `AbbreviateNumbers`, `UnitName`, `UnitLevel`, `UnitClass`,
`UnitClassification`, `UnitIsPlayer`, `UnitReaction`, `UnitCanAttack`, `UnitIsTapDenied`,
`UnitIsConnected`, `UnitIsDeadOrGhost`, `UnitIsGhost`, `UnitIsVisible`, `UnitGUID`,
`UnitThreatSituation` (mob GUID as second argument, unit token tried as well),
`UnitInRange` (or `CheckInteractDistance` out of combat), `UnitIsGroupLeader`,
`UnitAffectingCombat`, `IsResting`, `GetRaidTargetIndex`, `GetComboPoints`,
`SetPortraitTexture`, `C_UnitAuras.GetAuraDataByIndex` (or `UnitAura`),
`C_UnitAuras.GetAuraDuration`, `issecretvalue`, `InCombatLockdown`,
`C_AddOns.IsAddOnLoaded` / `IsAddOnLoaded`; widget methods `SetFormattedText`,
`SetAlphaFromBoolean`, `SetCooldownFromDurationObject` where they exist. Events:
`UNIT_HEALTH`, `UNIT_MAXHEALTH`, `UNIT_CONNECTION`, `UNIT_POWER_UPDATE`, `UNIT_POWER_FREQUENT`,
`UNIT_MAXPOWER`, `UNIT_DISPLAYPOWER`, `UNIT_AURA`, `UNIT_PORTRAIT_UPDATE`, `UNIT_MODEL_CHANGED`,
`UNIT_NAME_UPDATE`, `UNIT_LEVEL`, `UNIT_CLASSIFICATION_CHANGED`, `UNIT_FACTION`,
`UNIT_THREAT_SITUATION_UPDATE`, `UNIT_THREAT_LIST_UPDATE`, `UNIT_TARGET`, `UNIT_PET`,
`RAID_TARGET_UPDATE`, `PARTY_LEADER_CHANGED`, `GROUP_ROSTER_UPDATE`,
`PLAYER_TARGET_CHANGED`, `PLAYER_FOCUS_CHANGED`, `PLAYER_REGEN_DISABLED`,
`PLAYER_REGEN_ENABLED`, `PLAYER_UPDATE_RESTING`, `PLAYER_ENTERING_WORLD`,
`EDIT_MODE_LAYOUTS_UPDATED`; `UNIT_HEALTH_FREQUENT` and `UNIT_COMBO_POINTS` are registered too, but are not in Forever's binary, so there they are simply skipped (combo points come from `UNIT_POWER_UPDATE` with `COMBO_POINTS`). Textures: `Interface\TargetingFrame\UI-StatusBar`,
`UI-Classes-Circles`, `UI-RaidTargetingIcons`, `Interface\GroupFrame\UI-Group-LeaderIcon`,
`Interface\CharacterFrame\UI-StateIcon`, `Interface\Buttons\WHITE8x8`.

## Layout

```
BetterFramesForever.toc, BetterFramesForever_Camelot.toc   both at 16001, same file list
BetterFramesForever.lua    frames, Blizzard hiding, combat queue, /bff, BetterFramesForeverAPI
```

## License

MIT, see [LICENSE](LICENSE).
