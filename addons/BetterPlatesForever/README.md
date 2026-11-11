# BetterPlatesForever

A small standalone addon for the WoW Forever client (`_classic_beta_`, interface 16001). It draws
cleaner **enemy nameplates** over Blizzard's own: a softly shaded health bar with threat colours, a cast bar
with the time left, your own debuffs and a clear mark on your target. It is a port of the suite's
`GaarPlates` to the Better...Forever conventions and needs no other addon or library.

**It changes no CVars.** Plate stacking, overlap, size, distance and which plates are shown stay
exactly what the game, or you, set them to.

## What it does

- **Enemy plates only, by default.** Every plate you can attack gets the overlay. Friendly plates
  are left to Blizzard unless you turn on `/bpf friendly on` (off by default).
- **Health bar** (120x12 by default, `/bpf size`) on a dark backdrop. Colour by **reaction**
  (default: red hostile, yellow neutral, green friendly), **class** (players; the name takes the
  class colour too), **health** (red through yellow to green) or one **solid** colour. A mob
  tagged by someone else is grey. **Execute tint** (dark wine) at 20% health or less (on by
  default).
- **The look** (1.2.7). Every bar - health and cast - has a soft vertical gradient in its own
  colour: lighter at the top, darker at the bottom, so the bars have some depth instead of a flat
  hard fill. The health bar has a thin near-black border and a faint shadow fading out 3 px
  around it; the aggro ring, the raid mark, the cast bar and the debuff icons sit above it and are
  never covered. The colours are a richer, softer palette: deeper, slightly less saturated tones
  that suit the gradient. Class colours keep their hue (only the gradient is applied). Up to
  1.2.6 every colour was pulled toward its own luminance instead; the new palette is already
  soft, so that step is gone rather than desaturating twice.

  | Colour | 1.2.7 (r, g, b) |
  |---|---|
  | Hostile | 0.78, 0.25, 0.22 |
  | Neutral | 0.85, 0.72, 0.25 |
  | Friendly NPC | 0.30, 0.68, 0.32 |
  | Friendly player | 0.30, 0.52, 0.85 |
  | Tagged by someone else | 0.50, 0.50, 0.54 |
  | Execute | 0.52, 0.16, 0.24 |
  | Aggro (purple) | 0.56, 0.34, 0.80 |
  | High threat (amber) | 0.88, 0.60, 0.25 |
  | Cast / channel / uninterruptible | 0.92, 0.66, 0.20 / 0.30, 0.70, 0.36 / 0.58, 0.58, 0.62 |
  | Solid mode | 0.25, 0.55, 0.88 |
- **Threat on every plate.** Purple bar and a purple ring when you hold aggro (threat status 2 or
  3), amber when your threat is higher than the tank's (status 1), and your threat percent at the
  right end of the bar (on by default). Threat colours win over the colour mode and the execute
  tint. Since 1.2.5 aggro is read from the first source that answers plainly:
  `UnitDetailedThreatSituation`, then `UnitThreatSituation`, then "the mob is in combat and
  targeting you" (`UnitAffectingCombat` + `UnitIsUnit(unit.."target", "player")`). When all of
  them are hidden (secret), the client colours the bar itself from its secret boolean
  (`Texture:SetVertexColorFromBoolean`, and the ring with `SetAlphaFromBoolean`) where it has
  those. Plates refresh at once on `UNIT_THREAT_SITUATION_UPDATE` / `UNIT_THREAT_LIST_UPDATE`.
  `/bpf status` shows, for your target's plate, which source was used and what each returns.
- **Text.** The name above the bar, the level right of it (`??` when the client hides it), the
  health text inside it (`off`, `percent` (default), `current` or `both`, e.g. `850  85%`), and
  the unit's target under it
  as `-> Name` (on by default).
- **Cast bar** over the name row while the unit casts or channels: spell icon left of the bar,
  spell name and the time left in seconds. Casts are orange, channels green and drain from full.
  An **uninterruptible** cast gets the grey "shield" look from `GaarCast`: grey bar and a light
  steel edge round the icon.
- **Your debuffs.** Up to 8 of your own debuffs (`HARMFUL|PLAYER`) as 20px icons above the name,
  with stacks, a cooldown swipe and the time left. Since 1.2.3 the time left looks like an action
  button's cooldown count: a white outlined number centred on the icon, never with a seconds unit
  - `56` under a minute, then `2m`, `59m`, `1h` (rounded up). In combat the time is secret, so it
  is formatted by the client: a `C_StringUtil.CreateNumericRuleFormatter` with one breakpoint per
  unit, given to each button's `SetDurationText` as its `textFormatter` (and to the fallback
  icons' `Cooldown:SetCountdownFormatter`). It is checked on a few plain numbers when built; where
  it is missing or gives other text, the client's default is used (`56s`, `2m`) and
  `/bpf debug` says so. In combat this client keeps auras secret and
  refuses every aura read from addon code, so since 1.2 the icons are **drawn by the client**
  (`native`, on by default): each plate gets an `AuraContainer` made from Blizzard's
  `CustomAuraContainerTemplate`, the 12.1 aura API for addons. The client reads the auras in its
  own secure code and fills the buttons; the addon only gives each button its icon texture,
  `Cooldown`, count and time text once, when it is created. With `native off`, or on a client
  without that API, the addon reads the auras itself as in 1.1 (by index, then by spell ID for the
  spells you cast), with the same white countdown - but in combat the
  client refuses those reads, so that fallback in practice shows debuffs out of combat only.
- **Other players' debuffs** (1.2.4, `others`, on by default). On enemy plates, after your own
  icons on the same row: up to 6 debuffs that are not yours - a group mate's DoTs, and the mob's
  own debuffs - as smaller (15px) grey icons with the same time text. The client draws them in a
  second group of the same `AuraContainer`, filter `HARMFUL|!PLAYER` (every harmful aura not cast
  by you, your pet or vehicle), so with `HARMFUL|PLAYER` next to it each debuff is shown once.
  `!` negates a filter component since retail 12.1; on a client without it there is no way to
  tell yours from theirs in the container (its caster flag `isFromPlayerOrPlayerPet` is true for
  every player's aura), and plain `HARMFUL` would show yours twice, so the group is left out and
  only yours are shown; `/bpf status` says which. Only with `native` on (the addon's own fallback
  reading stays yours-only), and not on friendly plates: BPF draws no buffs or HoTs on plates.
- **Raid target marks** (1.2.6, `marks`, on by default). A 20 px icon left of the bar, as on Blizzard's
  plates, updated at once on `RAID_TARGET_UPDATE`. A hidden (secret) mark index is only passed to
  `SetRaidTargetIconTexture` inside a `pcall`; if the client refuses it the icon is hidden.
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
| `/bpf status` | Version, every setting, what this client offers (`C_NamePlate`, which aura API, threat, whether it can hide values), how many plates are styled now, anything this client switched off this session (with the reason), the debuff, health text and threat state (which threat source your target's plate uses, and whether each threat API returns secret, nil or a value), and a warning if `GaarPlates` is loaded too |
| `/bpf debug` | Debuff and health text state: icons on your target's plate and how they were drawn (client `AuraContainer` or the addon's own reading), whether this client has the `AuraContainer` API and how many containers were built or failed (with the last error), whether Blizzard's own plate `AurasFrame` exists, the nameplate aura CVars (read only), aura reads refused this session, the spells remembered for the spell-ID lookup, which aura and health-text APIs this client has, and whether your target's health is hidden |
| `/bpf on`, `/bpf off` | The whole addon. Off gives every plate back to Blizzard straight away |
| `/bpf color reaction\|class\|health\|solid` | Bar colour mode (`/bpf colour` works too) |
| `/bpf health off\|percent\|current\|both` | Health text |
| `/bpf size <width> <height>` | Health bar size, width 60-250 and height 6-30 (`/bpf size 140 16`, `/bpf size 140x16`) |
| `/bpf friendly on\|off` | Style friendly plates too (off by default) |
| `/bpf threat on\|off` | Threat colours and the aggro ring |
| `/bpf threattext on\|off` | Threat percent on the bar |
| `/bpf execute on\|off` | Execute tint at 20% or less |
| `/bpf debuffs on\|off` | Your debuffs on the plate |
| `/bpf others on\|off` | Other players' debuffs (and the mob's own) after yours, smaller and grey, on enemy plates (on by default) |
| `/bpf native on\|off` | Debuffs drawn by the client's `AuraContainer` (on by default; works in combat). Off uses the addon's own reading, which this client refuses in combat |
| `/bpf tot on\|off` | The unit's target under the bar |
| `/bpf dim on\|off` | Dim non-target plates to 55% |
| `/bpf targetscale on\|off` | Scale your target's plate to 115% and ring it |
| `/bpf marks on\|off` | Raid target marks (skull, cross ...) as a 20 px icon left of the bar (on by default) |
| `/bpf reset` | Every setting back to its default |

A switch without `on` or `off` toggles it. `/betterplatesforever` is the long form of `/bpf`.

## With BetterGaarForever (optional)

[BetterGaarForever](../BetterGaarForever/README.md) is an optional hub: one minimap button whose
menu holds the options of the Better...Forever addons. Its **Plates** submenu is in
BetterGaarForever 2.2 and later. It holds **Enabled**, **Colour mode** (Reaction / Class / Health / Solid),
**Health text** (Off / Percent / Current / Both), **Size** (Small 100x10 / Medium 120x12 / Large 140x16),
a checkbox for each of friendly, threat, threat text, execute, debuffs, other players' debuffs, native debuffs, target of target, dim and
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
  `AbbreviateNumbers` and `FontString:SetFormattedText`; without them it stays empty. Hidden threat values are dropped at the read, except the "you hold aggro" boolean, which is handed to the client to colour the bar (see Threat above);
  a hidden level shows `??`. Cast timings that are hidden mean no cast bar.
- **Gradient without allocations** (1.2.7). Every bar colour goes through one helper,
  `SetBarColor`, which calls `Texture:SetGradient("VERTICAL", bottom, top)` on the bar's white
  texture with two `Color` objects cached on the bar (`SetRGBA`, no new tables per update), and
  skips a colour the bar already has. `SetStatusBarColor` would put one flat vertex colour over
  the gradient, so it is only the fallback where `SetGradient` or `CreateColor` is missing. When
  aggro is only known as a secret, the client tints the bar with
  `SetVertexColorFromBoolean` - one flat colour - so a white-to-black shading texture over the
  fill (`sheen`) keeps the lighter top and darker bottom while that tint is in use, and the
  gradient is painted again once it is not.
- **One refusal, one message.** The client can refuse a read that no check predicted. Each part of
  a plate's update (threat, health, names and levels, cast bar, debuffs, target emphasis) runs
  inside `pcall`. The first refusal switches that part off for the session on every plate, with
  one message in chat, instead of an error twelve times a second per plate. `/bpf status` lists
  what was switched off. If the overlay itself cannot be drawn, every plate goes back to Blizzard.
  An aura read the client refuses is **not** such a refusal: it is what the client does in combat
  (*"auras cannot be accessed when secret while tainted"*). Version 1.0 treated it as one and
  switched the debuff icons off for the session the first time you DoTed a mob. Now it is counted
  (`/bpf debug`), the spell-ID lookup takes over, and the next pass tries again. In game the
  spell-ID lookup also came back empty in combat (1.1, Moonfire and Faerie Fire), which is why
  1.2 hands the reading to the client.
- **Blizzard's plate debuffs.** Blizzard's own nameplate draws your debuffs in
  `plate.UnitFrame.AurasFrame.DebuffListFrame` (`Blizzard_NamePlateAuras.lua`), only for auras
  flagged `nameplateShowPersonal` unless the CVar `nameplateShowAllPersonalAuras` is set, and
  only when the `nameplateEnemyNpcAuraDisplay` bitfield includes debuffs. Since this addon hides
  `plate.UnitFrame`, that frame is hidden with it. It is left alone rather than un-hidden or
  re-anchored: moving Blizzard's frames from addon code risks tainting their layout, and the
  `AuraContainer` does the same job inside the overlay. `/bpf debug` shows those CVars read only;
  the addon never changes them.
- **`GaarPlates`.** Both addons draw over the same plates. If `GaarPlates` is loaded, a one-time
  warning is printed at login and `/bpf status` says so. Nothing is disabled; use one of the two.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Only `enabled`, `colorMode`,
  `healthText`, `width`, `height`, `friendly`, `threat`, `threatText`, `execute`, `debuffs`,
  `others`, `native`, `tot`, `dim`, `targetScale` and `raidMark` are kept, each checked for its type and range on load; anything
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
`CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")` with `AddAuraGroup`,
`SetUnit`, `SetEnabled`, `GetAuraGroupFrameCount` and, on its buttons, `SetIcon`,
`SetDurationCooldown`, `SetDurationText` (with `textFormatter`), `SetApplicationCount` (`Blizzard_AuraContainer`),
`C_StringUtil.CreateNumericRuleFormatter`, `Enum.NumericRuleFormatRounding`, `Cooldown:SetCountdownFormatter`,
`C_CVar.GetCVar` (read only),
`issecretvalue` where it exists, `RAID_CLASS_COLORS`, `AbbreviateLargeNumbers`, `STANDARD_TEXT_FONT`,
`BackdropTemplate`, `C_AddOns.IsAddOnLoaded` (or `IsAddOnLoaded`), `CreateColor`,
`Texture:SetGradient`.
