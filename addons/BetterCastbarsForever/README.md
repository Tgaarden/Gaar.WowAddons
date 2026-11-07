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

Not in 1.0: channel ticks, a GCD bar, nameplate cast bars, an options panel and a minimap button.

## Commands

| Command | Does |
|---|---|
| `/bcf`, `/bcf help` | Help, with the current value of every setting |
| `/bcf status` | Which APIs and Blizzard bars this client has, every setting, each bar's state, place and size, any bar the client refused, and a GaarCast warning if it is loaded |
| `/bcf lock`, `/bcf unlock` | Stop or allow moving and resizing |
| `/bcf test`, `/bcf test on`, `/bcf test off` | Toggle or set the looping test casts |
| `/bcf reset` | Positions and sizes back to the defaults |
| `/bcf follow on`, `/bcf follow off` | Anchor the bars to Blizzard's cast bars (Edit Mode) or use their own position |
| `/bcf bar <player\|target\|focus\|pet> on\|off` | Which bars to draw (without `on`/`off`: toggle) |
| `/bcf latency on\|off` | Latency safe-zone on the player bar (on by default) |
| `/bcf texture blizzard\|smooth\|flat` | Bar texture (Blizzard by default) |
| `/bcf font 9\|11\|13` | Font size (11 by default) |
| `/bcf timer total\|remain` | `remain / total` (default) or just `remain` |

`/bettercastbarsforever` works the same as `/bcf`.

## With BetterGaarForever (optional)

[BetterGaarForever](../BetterGaarForever/README.md) is an optional hub: one minimap button whose
menu has a submenu per Better...Forever addon. Its **Castbars** row is in
BetterGaarForever 2.2 and later; older versions of the hub do not list it. The submenu has **Lock position &
size**, **Test bars**, **Bars** (Player, Target, Focus, Pet), **Follow Blizzard (Edit Mode)**,
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
  `latency`, `texture`, `fontSize`, `timer`, `bars`, `positions` and `sizes` are kept, each
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
`EDIT_MODE_LAYOUTS_UPDATED`; the textures `Interface\TargetingFrame\UI-StatusBar`,
`Interface\RaidFrame\Raid-Bar-Hp-Fill`, `Interface\Buttons\WHITE8x8`,
`Interface\CastingBar\UI-CastingBar-Spark`, `Interface\ChatFrame\UI-ChatIM-SizeGrabber-*` and the
icon `Interface\Icons\INV_Shield_06`; the strings `INTERRUPTED` and `FAILED`.
