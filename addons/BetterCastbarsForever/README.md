# BetterCastbarsForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). It draws its
own cast bars for the player, target, focus and pet, which you can place yourself or let follow
Blizzard's own bars (Edit Mode). It needs no other addon or library. It is a port of
[GaarCast](../GaarCast/GaarCast.lua) to the Better...Forever conventions, and keeps everything
GaarCast learnt about secret values.

## What it does

- **Four bars.** Player, target and focus are on by default (focus only where the client has a
  focus unit), pet is off. Each bar has:
  - the spell icon with a 1px border on the left,
  - the spell name on the left of the bar and a timer on the right (`1.4 / 2.5`, or just `1.4`),
  - a spark at the cast edge,
  - the name of the cast's target under the bar (best effort: the unit's own target, since the
    client has no API for a cast's real target),
  - on the player bar only, a red latency safe-zone at the right end of a cast (world latency
    from `GetNetStats`, home latency if world latency is hidden). Channels have none.
- **Colours.** Yellow for a cast, green for a channel (it drains from right to left), grey for a
  cast that cannot be interrupted, whose icon also gets a steel border and a small shield. A
  failed or interrupted cast flashes red with `Failed` / `Interrupted` for half a second. A
  finished cast fades out over 0.3 s.
- **Own position (default).** Drag a bar to move it, drag the grip in its bottom-right corner to
  resize it (80x10 to 600x60). Position and size are saved per bar, account-wide, in
  `BetterCastbarsForeverDB`. Until a bar is moved it sits at its own default: the player bar
  bottom-centre above the action bars, the target, focus and pet bars centred under their unit
  frames (or at a fixed spot near them if the unit frame's place cannot be read).
- **Follow Blizzard (Edit Mode)** (off by default). Each bar is anchored to Blizzard's own cast bar
  for that unit, so it sits wherever Edit Mode puts that bar. Blizzard's bar stays hidden, except
  while Edit Mode is open so it can be placed. A bar whose Blizzard counterpart is missing, or
  whose geometry the client will not report, keeps its own position. Dragging or resizing any bar
  by hand turns following off, with a line in chat.
- **Lock.** Hides the grips and turns dragging off; clicks then go through the bars. Unlocked,
  a bar takes mouse clicks where it is drawn.
- **Test bars.** A looping 3 s fake cast on every enabled bar, so the bars can be placed out of
  combat: player a cast with the latency zone, target a cast, focus an uninterruptible cast, pet a
  channel. Not saved; off after `/reload`. A real cast takes over a test bar while it lasts.
- **Reset.** Positions and sizes back to the defaults (following is left as it is).
- **Looks.** Bar texture Blizzard, Smooth or Flat; font size 9, 11 or 13.
- **Blizzard's own bars.** For each bar this addon draws, Blizzard's cast bar for that unit is
  hidden. Turn a bar off and Blizzard's shows again from its next cast; no `/reload` needed.
- **Swing timer** (1.1, on by default). Thin 8 px bars hang right under the player cast bar, the
  same width and texture, so they move, resize and follow Edit Mode with it. Stacked top to
  bottom: **MH** (main hand), **OH** (only while dual-wielding) and **Ranged** (only while Auto
  Shot or a wand's Shoot repeats, or a ranged swing is still running). Each fills over the swing
  and shows the seconds left on the right (`1.8`). They show in combat or while a swing runs and
  fade out otherwise; test bars loop fake swings (2.6 s, 1.8 s, 3.0 s) so they can be previewed.
  While they show, the player bar's cast-target line moves under them. The client's own built-in
  "Main Hand" swing bar is left alone; turn it off yourself (Edit Mode) if you use this one.

1.1.1: PLAYER_SWING payload is (duration, swingType), so OffHand and Ranged swings now drive the right bars with the real duration.
1.1.2: the swing rows start at the spell icon's left edge instead of the bar's.

Not in 1.1: channel ticks, a GCD bar, nameplate cast bars, an options panel and a minimap button.

## How the swing timer finds swings

Forever gives addons no combat log reader (`C_CombatLog` has only `IsCombatLogRestricted`,
`ClearEntries` and `SetMessageLimit`, see `docs/forever-client-findings.md`), so the usual
`SWING_DAMAGE` / `SWING_MISSED` route is closed. Instead:

- **`PLAYER_SWING`**, an event this client has and retail does not, next to `C_SwingTimer` and
  `Enum.PlayerSwingType`; it is what the client's own swing bar runs on. Each one restarts the
  bar of the hand it names, so hits, misses, dodges, parries, blocks and landed on-next-swing
  abilities all count. The payload is `(duration, swingType)`: the second value (an `Enum.PlayerSwingType`: main hand 0, off hand 1, ranged 2) picks the bar and the first is the swing length in seconds when sane, else it comes from
  `UnitAttackSpeed` / `UnitRangedDamage`. A ranged swing drives the Ranged bar (Auto Shot/Shoot only as a fallback). `/bcf swing debug` prints every payload and the enum, to check this in game.
- **An estimate** until `PLAYER_SWING` has been seen this session, or where it cannot be
  registered: turning auto-attack on (`PLAYER_ENTER_COMBAT`) starts a swing at once and the bar
  loops while auto-attack lasts; Heroic Strike, Cleave, Maul and Raptor Strike restart the main
  hand when `UNIT_SPELLCAST_SUCCEEDED` reports them. `/bcf status` says which source is in use.
- **Always:** Slam restarts the main hand when it succeeds; Auto Shot and Shoot (wand) restart
  the ranged bar on `UNIT_SPELLCAST_SUCCEEDED` (length from `UnitRangedDamage`); a haste change
  (`UNIT_ATTACK_SPEED`, `UNIT_RANGEDDAMAGE`) rescales a running swing, keeping the share already
  done; parrying an attack (`UNIT_COMBAT` `PARRY` on the player) takes 40% of the swing off what
  is left of the main hand, never below 20%. Spell IDs are all Classic ranks; their names are
  looked up from those IDs, so a rank the list misses still matches by its localised name.
- Every value is checked with `issecretvalue` first and a secret skips that update (a secret
  attack speed means no bar for that swing). The swing timer runs on its own event frame under
  `pcall`; its first error switches it off until `/reload` with one line in chat, and the cast
  bars carry on.

Not handled: a weapon swap does not restart the bars, and parry haste on the enemy's timer when
it parries you does not apply (only your own timer is tracked).

## Commands

| Command | Does |
|---|---|
| `/bcf`, `/bcf help` | Help, with the current value of every setting |
| `/bcf status` | Which APIs and Blizzard bars this client has, every setting, each bar's state, place and size, any bar the client refused, the swing timer settings and where its swings come from, and a GaarCast warning if it is loaded |
| `/bcf lock`, `/bcf unlock` | Stop or allow moving and resizing |
| `/bcf test`, `/bcf test on`, `/bcf test off` | Toggle or set the looping test casts |
| `/bcf reset` | Positions and sizes back to the defaults |
| `/bcf follow on`, `/bcf follow off` | Anchor the bars to Blizzard's cast bars (Edit Mode) or use their own position |
| `/bcf bar <player\|target\|focus\|pet> on\|off` | Which bars to draw (without `on`/`off`: toggle) |
| `/bcf latency on\|off` | Latency safe-zone on the player bar (on by default) |
| `/bcf texture blizzard\|smooth\|flat` | Bar texture (Blizzard by default) |
| `/bcf font 9\|11\|13` | Font size (11 by default) |
| `/bcf timer total\|remain` | `remain / total` (default) or just `remain` |
| `/bcf swing on\|off` | Swing timer under the player bar (on by default; without `on`/`off`: toggle) |
| `/bcf swing offhand on\|off` | Off-hand swing bar while dual-wielding (on by default) |
| `/bcf swing ranged on\|off` | Ranged swing bar for Auto Shot / Shoot (on by default) |
| `/bcf swing debug` | Print every `PLAYER_SWING` payload and `Enum.PlayerSwingType` (not saved) |

`/bettercastbarsforever` works the same as `/bcf`.

## With BetterGaarForever (optional)

[BetterGaarForever](../BetterGaarForever/README.md) is an optional hub: one minimap button whose
menu has a submenu per Better...Forever addon. Its **Castbars** row is in
BetterGaarForever 2.2 and later; older versions of the hub do not list it. The submenu has **Lock position &
size**, **Test bars**, **Bars** (Player, Target, Focus, Pet), **Swing timer** (Show swing
timer, Off hand, Ranged), **Follow Blizzard (Edit Mode)**,
**Latency safe-zone**, **Texture**, **Font size**, the two **Timer** styles and **Reset positions
& sizes**, the same settings as `/bcf` (both go through the same functions). This addon has no
minimap button or menu of its own, so nothing here changes with or without the hub: the settings
stay in `BetterCastbarsForeverDB` and `/bcf` stays as it is.

The hub talks to this addon only through `BetterCastbarsForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `unlocked · player target focus · own position` (` · test bars on` while testing) |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, submenu }`, `{ divider }`), for a menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide. It is there so every addon the hub knows has the same API |

## How it stays out of the way

- **Blizzard's cast bars are never restyled, moved or written to.** Writing to their frames
  taints them, and their own cast code then cannot read the timings a retail-shaped client hides.
  The only touch is `HookScript("OnShow")` with a `Hide()`, installed the first time a bar is
  turned on and only for the units this addon replaces. Which frames are hooked is kept in a
  table of the addon's own, not as a field on Blizzard's frame. While Edit Mode is open the hook
  leaves Blizzard's bar alone.
- **Secret values are checked before they are touched.** Cast timings, the interruptible flag,
  `GetNetStats` and every number read from a frame are passed through `issecretvalue` first
  (where the client has it) and a secret is treated as no value at all. A cast whose timings are
  secret is not drawn. Not even `x or default` is used on a value that could be secret, since `or`
  is a boolean test.
- **Blizzard's geometry is never copied unchecked.** Following anchors to Blizzard's bar only
  when its size and centre are readable; the default places under the unit frames copy numbers
  into a UIParent anchor only after the same check. Otherwise the bar uses its own default, so
  our frame never inherits a secret size or position.
- **A secret position is never saved.** A drag or resize saves the bar's centre and size only
  when none of the numbers is secret (the client writes a secret as `nil`); otherwise it says so
  in chat and keeps the last good value. Saved entries with a field missing are purged on load.
- **The client's refusal is the answer.** `issecretvalue` does not flag everything, so each
  bar's per-frame update and its event handling run under `pcall`. The first error switches that
  one bar off until `/reload`, with one line in chat and a note in `/bcf status`, instead of an
  error every frame.
- **GaarCast.** Both addons hide and replace the same Blizzard cast bars. If GaarCast is loaded
  (`C_AddOns.IsAddOnLoaded`, or `IsAddOnLoaded`), a one-time warning is printed at login and
  `/bcf status` repeats it. Nothing is disabled: use one of the two.
- Every name is checked before use; a missing frame or function means that feature or bar falls
  back or stays off instead of raising an error.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Only `locked`, `follow`,
  `latency`, `texture`, `fontSize`, `timer`, `swingTimer`, `swingRanged`, `swingOffhand`, `bars`,
  `positions` and `sizes` are kept, each
  type-checked; anything else is cleared on load. Test mode is never saved.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source)): the cast bars
`PlayerCastingBarFrame` (or `CastingBarFrame`), `TargetFrameSpellBar` (or `TargetFrame.spellbar`),
`FocusFrameSpellBar` (or `FocusFrame.spellbar`) and `PetCastingBarFrame`; the unit frames
`TargetFrame`, `FocusFrame` and `PetFrame` (for the default places); `EditModeManagerFrame:IsEditModeActive`;
`UnitCastingInfo`, `UnitChannelInfo` (both return shapes, detected), `GetNetStats`,
`UnitExists`, `UnitIsUnit`, `UnitName`, `issecretvalue`, `C_AddOns.IsAddOnLoaded` /
`IsAddOnLoaded`; the events `UNIT_SPELLCAST_START`, `_STOP`, `_FAILED`, `_INTERRUPTED`,
`_DELAYED`, `_CHANNEL_START`, `_CHANNEL_UPDATE`, `_CHANNEL_STOP`, `_INTERRUPTIBLE`,
`_NOT_INTERRUPTIBLE`, `PLAYER_TARGET_CHANGED`, `PLAYER_FOCUS_CHANGED`, `UNIT_PET` and
`EDIT_MODE_LAYOUTS_UPDATED`; for the swing timer `PLAYER_SWING` and `Enum.PlayerSwingType`
(Forever only), `UnitAttackSpeed`, `UnitRangedDamage`, `UnitAffectingCombat`,
`C_Spell.GetSpellName` (or `GetSpellInfo`), and the events `PLAYER_ENTER_COMBAT`,
`PLAYER_LEAVE_COMBAT`, `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED`, `START_AUTOREPEAT_SPELL`,
`STOP_AUTOREPEAT_SPELL`, `UNIT_SPELLCAST_SUCCEEDED`, `UNIT_ATTACK_SPEED`, `UNIT_RANGEDDAMAGE`,
`UNIT_INVENTORY_CHANGED` and `UNIT_COMBAT`; the textures `Interface\TargetingFrame\UI-StatusBar`,
`Interface\RaidFrame\Raid-Bar-Hp-Fill`, `Interface\Buttons\WHITE8x8`,
`Interface\CastingBar\UI-CastingBar-Spark`, `Interface\ChatFrame\UI-ChatIM-SizeGrabber-*` and the
icon `Interface\Icons\INV_Shield_06`; the strings `INTERRUPTED` and `FAILED`.
