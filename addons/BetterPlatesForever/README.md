# BetterPlatesForever

A small standalone addon for the WoW Forever client (`_classic_beta_`, interface 16001). It draws
cleaner **enemy nameplates** over Blizzard's own: a flat health bar with threat colours, a cast bar
with the time left, your own debuffs and a clear mark on your target. It is a port of the suite's
`GaarPlates` to the Better...Forever conventions and needs no other addon or library.

**It changes no CVars.** Plate stacking, overlap, size, distance and which plates are shown stay
exactly what the game, or you, set them to.

## What it does

- **Enemy plates only, by default.** Every plate you can attack gets the overlay. Friendly plates
  are left to Blizzard unless you turn on `/bpf friendly on` (off by default).
- **Health bar** (120x12 by default, `/bpf size`), flat, on a dark backdrop with a 1px border.
  Colour by **reaction** (default: red hostile, yellow neutral, green friendly), **class** (players;
  the name takes the class colour too), **health** (green to red) or one **solid** colour. Every
  colour is pulled slightly toward its own luminance so nothing reads as harsh pure red or purple.
  A mob tagged by someone else is grey. **Execute tint** at 20% health or less (on by default).
- **Threat on every plate.** Purple bar and a purple ring when you hold aggro, amber when your
  threat is high (status 2 or more), and your threat percent at the right end of the bar (on by
  default). Threat colours win over the colour mode and the execute tint.
- **Text.** The name above the bar, the level right of it (`??` when the client hides it), the
  health text inside it (`off`, `percent` (default), `current` or `both`, e.g. `850  85%`), and
  the unit's target under it
  as `-> Name` (on by default).
- **Cast bar** over the name row while the unit casts or channels: spell icon left of the bar,
  spell name and the time left in seconds. Casts are orange, channels green and drain from full.
  An **uninterruptible** cast gets the grey "shield" look from `GaarCast`: grey bar and a light
  steel edge round the icon.
- **Your debuffs.** Up to 8 of your own debuffs (`HARMFUL|PLAYER`) as 16px icons under the bar,
  with stacks and a countdown that turns yellow at 8 s and red at 3 s. In combat the client keeps
  auras secret and refuses reads by index; then each spell you have cast this session is looked
  up by spell ID instead, and a hidden countdown is drawn by the client's own Cooldown swipe and
  numbers. So a DoT shows once you have cast it once this session.
- **Your target.** Its plate is scaled to 115% with a faint grey ring (`targetscale`, on by
  default), and every other plate is dimmed to 55% while you have a target (`dim`, on by default).
- **Plates update 12.5 times a second**, the same loop as `GaarPlates`, over the plates being
  styled only; target changes update at once.
- **Elite and quest icons are not shown**, and there is no options panel and no minimap button of
  its own. `/bpf` and the optional hub are the whole interface.

## Commands

| Command | Does |
|---|---|
| `/bpf`, `/bpf help` | Help |
| `/bpf status` | Version, every setting, what this client offers (`C_NamePlate`, which aura API, threat, whether it can hide values), how many plates are styled now, anything this client switched off this session (with the reason), the debuff and health text state, and a warning if `GaarPlates` is loaded too |
| `/bpf debug` | Debuff and health text state: icons on your target's plate and how they were read, aura reads refused this session, the spells remembered for the spell-ID lookup, the last refusal, which aura and health-text APIs this client has, and whether your target's health is hidden |
| `/bpf on`, `/bpf off` | The whole addon. Off gives every plate back to Blizzard straight away |
| `/bpf color reaction\|class\|health\|solid` | Bar colour mode (`/bpf colour` works too) |
| `/bpf health off\|percent\|current\|both` | Health text |
| `/bpf size <width> <height>` | Health bar size, width 60-250 and height 6-30 (`/bpf size 140 16`, `/bpf size 140x16`) |
| `/bpf friendly on\|off` | Style friendly plates too (off by default) |
| `/bpf threat on\|off` | Threat colours and the aggro ring |
| `/bpf threattext on\|off` | Threat percent on the bar |
| `/bpf execute on\|off` | Execute tint at 20% or less |
| `/bpf debuffs on\|off` | Your debuffs on the plate |
| `/bpf tot on\|off` | The unit's target under the bar |
| `/bpf dim on\|off` | Dim non-target plates to 55% |
| `/bpf targetscale on\|off` | Scale your target's plate to 115% and ring it |
| `/bpf reset` | Every setting back to its default |

A switch without `on` or `off` toggles it. `/betterplatesforever` is the long form of `/bpf`.

## With BetterGaarForever (optional)

[BetterGaarForever](../BetterGaarForever/README.md) is an optional hub: one minimap button whose
menu holds the options of the Better...Forever addons. Its **Plates** submenu is in
BetterGaarForever 2.2 and later. It holds **Enabled**, **Colour mode** (Reaction / Class / Health / Solid),
**Health text** (Off / Percent / Current / Both), **Size** (Small 100x10 / Medium 120x12 / Large 140x16),
a checkbox for each of friendly, threat, threat text, execute, debuffs, target of target, dim and
target scale, and **Reset to defaults**: the same settings as `/bpf`, through the same functions.
This addon has no minimap button or menu of its own, so nothing here changes with or without the
hub: the settings stay in `BetterPlatesForeverDB` and `/bpf` stays as it is.

The hub talks to this addon only through `BetterPlatesForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `on · reaction · 120x12 · threat on` |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, submenu }`, `{ divider }`), for a menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide. It is there so every addon the hub knows has the same API |

## How it stays out of the way

- **No CVars are read or changed**, so stacking, overlap, plate size and range are untouched.
- The overlay is a frame of the addon's own, parented to the plate that
  `C_NamePlate.GetNamePlateForUnit` returns. Blizzard's art on that plate (`plate.UnitFrame`) is
  only hidden: `Hide()`, plus `HookScript("OnShow")` to hide it again when the nameplate driver
  shows it on a recycled plate. The hook acts only while that plate is styled by this addon. A
  plate that stops being styled (a friendly unit, `/bpf friendly off`, `/bpf off`) gets
  Blizzard's art back with `Show()`. No Blizzard function or table is replaced or written; which
  frames were hooked is kept in a weak table of the addon's own.
- **Hidden values.** Where the client hides a number (`issecretvalue`), the health bar still gets
  the raw values (handing a hidden value straight back to a widget is allowed), but nothing is
  worked out from them: no execute tint, no colour by health (it falls back to reaction). The
  health text is then written by the client's own secret-safe helpers, as in
  `BetterFramesForever`: `UnitHealthPercent` with `CurveConstants.ScaleTo100`,
  `AbbreviateNumbers` and `FontString:SetFormattedText`; without them it stays empty. Hidden threat values are dropped at the read, so the plate shows no threat;
  a hidden level shows `??`. Cast timings that are hidden mean no cast bar.
- **One refusal, one message.** The client can refuse a read that no check predicted. Each part of
  a plate's update (threat, health, names and levels, cast bar, debuffs, target emphasis) runs
  inside `pcall`. The first refusal switches that part off for the session on every plate, with
  one message in chat, instead of an error twelve times a second per plate. `/bpf status` lists
  what was switched off. If the overlay itself cannot be drawn, every plate goes back to Blizzard.
  An aura read the client refuses is **not** such a refusal: it is what the client does in combat
  (*"auras cannot be accessed when secret while tainted"*). Version 1.0 treated it as one and
  switched the debuff icons off for the session the first time you DoTed a mob. Now it is counted
  (`/bpf debug`), the spell-ID lookup takes over, and the next pass tries again.
- **`GaarPlates`.** Both addons draw over the same plates. If `GaarPlates` is loaded, a one-time
  warning is printed at login and `/bpf status` says so. Nothing is disabled; use one of the two.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Only `enabled`, `colorMode`,
  `healthText`, `width`, `height`, `friendly`, `threat`, `threatText`, `execute`, `debuffs`,
  `tot`, `dim` and `targetScale` are kept, each checked for its type and range on load; anything
  else is cleared.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source), `Blizzard_NamePlates`):
`C_NamePlate.GetNamePlateForUnit`, `C_NamePlate.GetNamePlates`, `NAME_PLATE_UNIT_ADDED`,
`NAME_PLATE_UNIT_REMOVED`, the plate's `namePlateUnitToken` and `UnitFrame`.

Unit API: `UnitHealth`, `UnitHealthMax`, `UnitLevel`, `UnitName`, `UnitClass`, `UnitIsPlayer`,
`UnitIsFriend`, `UnitReaction`, `UnitCanAttack`, `UnitIsUnit`, `UnitExists`, `UnitIsTapDenied`,
`UnitDetailedThreatSituation`, `UnitCastingInfo` / `UnitChannelInfo` (both return shapes, with
and without the old `nameSubtext`), `C_UnitAuras.GetAuraDataByIndex` (or `UnitAura`),
`C_UnitAuras.GetUnitAuraBySpellID`, `C_UnitAuras.GetAuraDuration`,
`C_UnitAuras.GetAuraApplicationDisplayCount`, `C_Secrets.ShouldUnitAuraIndexBeSecret`,
`UNIT_SPELLCAST_SUCCEEDED`, `Cooldown:SetCooldownFromDurationObject`, `UnitHealthPercent`,
`CurveConstants.ScaleTo100`, `AbbreviateNumbers`, `UnitIsDeadOrGhost`,
`issecretvalue` where it exists, `RAID_CLASS_COLORS`, `AbbreviateLargeNumbers`, `STANDARD_TEXT_FONT`,
`BackdropTemplate`, `C_AddOns.IsAddOnLoaded` (or `IsAddOnLoaded`).
