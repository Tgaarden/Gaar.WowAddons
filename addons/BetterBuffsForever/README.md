# BetterBuffsForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001), for druids and
paladins. A box at the top centre of the screen lists who in your group lacks your buffs and
whether your reagents are running low. Click a name to buff that member. It needs no other addon
or library, and it is not part of the Gaar suite.

- **Druid**: **Mark of the Wild** (Gift of the Wild counts) on you and the group, **Thorns** on you
  and the tank, **Gift of the Wild and Rebirth reagents**.
- **Paladin**: a **blessing per class** on every member (with a fallback when another paladin's
  blessing is already there), **No aura**, **Righteous Fury** while you tank, **Symbol of Kings**.

## What it does (every class)

- **Druids and paladins only.** On any other class the addon stays idle: no scans, no box.
  `/bbuff status` says `not a druid or paladin: the addon is idle on this character.`
- **The tank** is, in this order:
  1. every member `UnitGroupRolesAssigned(unit)` calls `"TANK"`;
  2. else, in a raid, every main tank (`GetPartyAssignment("MAINTANK", unit)`);
  3. else the tank you set by hand: target a group member and type `/bbuff tank` (saved per
     character, `/bbuff tank clear` removes it; also in the hub menu);
  4. else there is no tank. You can be the tank yourself.
- **Only spells you know.** A spell the character has not learned is not checked.
- **The box.** At the top centre, shown only while something is missing: one section per thing
  missing (`Missing Mark of the Wild:`, `Missing Blessing of Might:`, `No aura:`, ...; the spell
  names are the client's own), one row per member with the spell's icon and a class-coloured
  name, `(you)` for yourself and `(tank)` for a tank, then the low-reagent lines
  (`Low reagents: Wild Thornroot 3/10`). It hides again when everything is covered.
- **Who is never warned about:** dead or ghost members, offline members, and members the client
  does not see (`UnitIsVisible`, too far away). Members out of the spell's range are shown dimmed
  with `(out of range)`; they stay clickable, the cast just fails.
- **Unknown is not missing.** A member whose buffs cannot be read (a secret aura, a refused read)
  counts as unknown and is never warned about. `/bbuff status` gives the count.
- **Low reagents** (on by default): counted in the bags only (`C_Item.GetItemCount`, else
  `GetItemCount`, bank not included), updated on `BAG_UPDATE_DELAYED`. A spell you do not know is
  skipped entirely. The line is not clickable.

## Druid

- **Mark of the Wild.** Warns when you lack it and, in a party or raid, lists every member who
  lacks it. Gift of the Wild counts as having it.
- **Thorns.** Warns when you lack it, and when the group's tank lacks it. No Thorns warning before
  level 6.
- **Clicks.** Left-click casts the row's spell (Mark of the Wild or Thorns) on that member.
  Right-click on a Mark of the Wild row casts **Gift of the Wild** when you know it and are in a
  group (it needs its reagent). Otherwise right-click does what left-click does.
- **Reagents**, for the highest rank you know:

  | Spell | Rank | Reagent | Default threshold |
  |---|---|---|---|
  | Gift of the Wild | 1 (21849) | Wild Berries (17021) | 10 |
  | Gift of the Wild | 2 (21850) | Wild Thornroot (17026) | 10 |
  | Rebirth | 1 (20484) | Maple Seed (17034) | 2 |
  | Rebirth | 2 (20739) | Stranglethorn Seed (17035) | 2 |
  | Rebirth | 3 (20742) | Ashwood Seed (17036) | 2 |
  | Rebirth | 4 (20747) | Hornbeam Seed (17037) | 2 |
  | Rebirth | 5 (20748) | Ironwood Seed (17038) | 2 |

## Paladin

### Blessings by class

Every member, you included, should have the blessing assigned to their class, from you:

| Class | Default |
|---|---|
| Warrior, Rogue, Hunter | Blessing of Might |
| Mage, Priest, Warlock, Druid, Paladin, Shaman | Blessing of Wisdom |

Change a class with `/bbuff bless <class> <might|wisdom|kings|salvation|light|sanctuary|none>` or
in the hub's **Blessings by class** submenu (one radio list per class). The assignments are
account-wide; `/bbuff bless reset` puts back the defaults. `none` switches a class off. Kings is
never a default (it is a talent); it is the first fallback when you know it.

The rules, per member:

- **Covered** when the member has the assigned blessing type from anyone: any rank, the normal or
  the Greater version.
- **Fallback.** In classic a paladin can keep only one blessing on a target, and the same type
  from two paladins overwrites. So when the assigned type is already there from **another**
  paladin and the member has nothing from you, the row asks for the first of these that you know
  and the member does not already have:
  1. Blessing of Kings (if you know it);
  2. Might or Wisdom, the other one (Wisdom when Might is assigned, Might when Wisdom is; for any
     other assigned type, the class's default of the two);
  3. Blessing of Light.

  None left means nothing to do. The row says `(fallback)` and its tooltip names the blessing
  that is already there. When something of yours is on the member, they are covered.
- **The tank never gets Salvation.** A class assigned Salvation gives its tank the fallback
  (Kings, Might/Wisdom, Light) instead.
- **Only blessings you know** are warned about: an assigned blessing you have not learned (Wisdom
  before level 14, Kings without the talent) gives no row. A member whose class is hidden is
  skipped. Who cast a blessing is read from `isFromPlayerOrPlayerPet` (else `sourceUnit`); when
  that is secret, the member counts as unknown, never as missing.
- **Clicks.** Left-click casts the blessing (the assigned one, or the fallback) on that member, the
  highest rank you know by name. Right-click casts the **Greater Blessing** of that type on the
  member, which buffs every member of that class in your group, when you know it (level 52+; it
  needs a Symbol of Kings). Otherwise right-click does what left-click does.

### No aura

A `No aura:` row when none of your paladin auras is on (Devotion, Retribution, Concentration,
Shadow, Frost or Fire Resistance, Sanctity). Classic paladin auras sit on the shapeshift bar as
"forms", so the aura is read there: `GetNumShapeshiftForms` and `GetShapeshiftFormInfo(i)`, a form
whose spell ID is a paladin aura and whose `isActive` is true. That bar is about your own auras
only (another paladin's Devotion Aura on you does not count) and is not a buff read, so no secret
aura gets in the way. Only when the bar lists no paladin aura at all (a client that does not put
them there) are your own buffs read instead (cast by you). Clicking the row casts the aura you
used last, remembered per character whenever the active form changes (`UPDATE_SHAPESHIFT_FORM`);
Devotion Aura before you have used one. No row before you know an aura.

### Righteous Fury when tanking

A `Missing Righteous Fury:` row when you lack Righteous Fury (25780) and either you are the tank
(the same tank rule as above: role `TANK`, raid main tank, or the tank set by hand is you) or you
said you are tanking (`/bbuff tanking on`, per character, also a hub checkbox). Clicking casts it
on yourself.

### Symbol of Kings

`Low reagents: Symbol of Kings 12/20` when the bags hold fewer than the threshold (default 20,
`/bbuff reagents kings <n>`) of Symbol of Kings (21177), the reagent of the Greater Blessings, and
only while you know a Greater Blessing.

## Click to buff

Every row is a `SecureActionButtonTemplate` button of the addon's own: `type` = `spell`, `spell` =
the localized name of the highest rank you know (or its spell ID when the client gives no name),
`unit` = that member's unit token (`player`, `party1`, `raid7`, ...). Right-click uses `type2` /
`spell2` (Gift of the Wild, a Greater Blessing).

- The rows are registered for the one click direction `ActionButtonUseKeyDown` acts on (read at
  every rebuild), so one click casts once with the CVar on or off.
- Casting by name casts the highest rank you know; a low-level member may need a lower rank, which
  the addon does not pick.
- Hover a row for a tooltip with what each click casts.

## Combat

**The box is hidden in combat**, on purpose: aura data is secret then, secure attributes cannot
change, and buffing mid-fight is not what it is for. A visibility state driver
(`RegisterStateDriver(holder, "visibility", "[combat] hide; show")`) hides it the moment combat
starts, by secure code; on a client without state drivers `PLAYER_REGEN_DISABLED` does it.
Nothing is scanned in combat. At `PLAYER_REGEN_ENABLED` everything is checked again and the rows
are rebuilt. The rows' attributes, size and place are only ever changed out of combat.

## Moving the box

- `/bbuff unlock`: the box stays shown (with a hint line) and can be dragged anywhere.
  `/bbuff lock` when done.
- **Alt + drag** moves it at any time, locked or not (out of combat).
- `/bbuff reset`: back to the top centre.

The position is saved account-wide in `BetterBuffsForeverDB`, as an offset from the top centre.

## Commands

| Command | Does |
|---|---|
| `/bbuff` or `/bbuff help` | Help (the commands for your class) |
| `/bbuff on`, `/bbuff off` | Switch the addon on or off |
| `/bbuff group [on\|off]` | List group members (off: only you are checked) |
| `/bbuff sound [on\|off]` | A short sound when something new goes missing (off by default) |
| `/bbuff reagents [on\|off]` | The low-reagent warning (on by default) |
| `/bbuff tank` (or `tank set`) | Your current target, a group member, becomes the tank set by hand |
| `/bbuff tank clear` | Clear the tank set by hand |
| `/bbuff unlock`, `/bbuff lock`, `/bbuff reset` | Move the box, stop moving it, put it back at the top centre |
| `/bbuff test` | Show the box with test rows for your class (they cast nothing); again to hide them |
| `/bbuff status` | Version, the class module (Druid, Paladin, or none: idle), the options, the resolved spells, the reagents with count and threshold, the group, the tank and where it came from, the last check, the box (shown, lock, position, how combat hides it), which aura, role and main-tank APIs this client has, and the last error. A paladin also gets the assignment table (`*` = changed), the auras known, the active one and where it was read, the last-used aura, Righteous Fury and the tanking toggle |
| **Druid** | |
| `/bbuff motw [on\|off]` | The Mark of the Wild check (no argument toggles) |
| `/bbuff thorns [on\|off]` | Warn when you lack Thorns |
| `/bbuff tank on\|off` | Warn when the tank lacks Thorns |
| `/bbuff reagents gotw <n>`, `/bbuff reagents rebirth <n>` | Warn below n Gift of the Wild reagents (default 10) or Rebirth seeds (default 2), 0-200 |
| **Paladin** | |
| `/bbuff bless [on\|off]` | The blessing check |
| `/bbuff bless <class> <type>` | Assign a blessing to a class: `warrior`, `rogue`, `hunter`, `mage`, `priest`, `warlock`, `druid`, `paladin`, `shaman`; `might`, `wisdom`, `kings`, `salvation`, `light`, `sanctuary` or `none` |
| `/bbuff bless reset` | Every class back to its default |
| `/bbuff aura [on\|off]` | Warn when no aura is on |
| `/bbuff fury [on\|off]` | Warn when you tank without Righteous Fury |
| `/bbuff tanking [on\|off]` | Say you are tanking (this character), for the Righteous Fury check |
| `/bbuff reagents kings <n>` | Warn below n Symbols of Kings (default 20), 0-200 |

The class settings are account-wide, so the druid commands also work on a paladin and the other
way round; they only matter on that class.

## With BetterGaarForever (optional)

[BetterGaarForever](../BetterGaarForever/README.md) is an optional hub: one minimap button whose
menu has a **Buffs** submenu with the options for your class:

- every class with a module: **Enabled**, then the class options, **List group members**, **Sound
  when something goes missing**, **Low reagent warning**, the class's reagent threshold(s), **Set
  tank: current target**, **Clear tank** (while one is set), **Lock box**, **Test box** and **Reset
  position**;
- a druid: **Mark of the Wild check**, **Thorns on you**, **Thorns on the tank**, **Gift of the
  Wild reagent warning below** (0/5/10/20/40), **Rebirth reagent warning below** (0/1/2/3/5);
- a paladin: **Blessing check (by class)**, **Warn when no aura is on**, **Righteous Fury when
  tanking**, **Symbol of Kings reagent warning below** (0/10/20/40/60), **Blessings by class** (one
  submenu per class with a radio list of the blessings and None, plus Reset to defaults) and **I'm
  tanking (this character)**.

They go through the same functions as the slash command. This addon has no minimap button or menu
of its own, so nothing here changes with or without the hub.

The hub talks to this addon only through `BetterBuffsForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `on · 2 missing`, `on · all buffed`, `on · hidden in combat` or `idle (not a druid or paladin)` |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, submenu }`, `{ divider }`), for a menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide. It is there so every addon the hub knows has the same API |

## How it reads buffs

- Spells, all classic ranks:
  - Druid: Mark of the Wild 1126, 5232, 6756, 5234, 8907, 9884, 9885; Gift of the Wild 21849,
    21850; Thorns 467, 782, 1075, 8914, 9756, 9910; Rebirth 20484, 20739, 20742, 20747, 20748
    (reagents only).
  - Paladin: Blessing of Might 19740, 19834, 19835, 19836, 19837, 19838, 25291; Blessing of Wisdom
    19742, 19850, 19852, 19853, 19854, 25290; Blessing of Kings 20217; Blessing of Salvation 1038;
    Blessing of Light 19977, 19978, 19979; Blessing of Sanctuary 20911, 20912, 20913, 20914;
    Greater Blessing of Might 25782, 25916; of Wisdom 25894, 25918; of Kings 25898; of Salvation
    25895; of Light 25890; of Sanctuary 25899; Righteous Fury 25780; Devotion Aura 465, 10290,
    643, 10291, 1032, 10292, 10293; Retribution Aura 7294, 10298, 10299, 10300, 10301;
    Concentration Aura 19746; Shadow Resistance Aura 19876, 19895, 19896; Frost Resistance Aura
    19888, 19897, 19898; Fire Resistance Aura 19891, 19899, 19900; Sanctity Aura 20218.

  The highest rank known (`C_SpellBook.IsSpellKnown`, `IsPlayerSpell`, `IsSpellKnown`) is resolved
  at login and on `SPELLS_CHANGED`, out of combat.
- Buffs are read by index, `C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")` (`UnitBuff` or
  `UnitAura` on an older client), one `pcall` per read, asking
  `C_Secrets.ShouldUnitAuraIndexBeSecret` first, as BetterFramesForever does. A buff is matched by
  spell ID, else by the localized name of any rank. A read that is refused or secret, or a buff
  with neither a readable ID nor name, makes the member unknown for that check.
- Updates come from `UNIT_AURA` (player, party and raid units only), `GROUP_ROSTER_UPDATE`,
  `PLAYER_ENTERING_WORLD`, `PLAYER_REGEN_ENABLED`, `SPELLS_CHANGED`, `BAG_UPDATE_DELAYED`, and
  `PLAYER_ROLES_ASSIGNED` / `UNIT_CONNECTION` / `UPDATE_SHAPESHIFT_FORM(S)` where the client has
  them; at most 4 a second. In a group the check also runs every 1.5 s, for range, death and
  visibility, which have no cheap event.
- Range is `C_Spell.IsSpellInRange` (else `IsSpellInRange`, else `UnitInRange`). A secret answer
  goes straight to `SetAlphaFromBoolean` where the client has it, never tested.

## Files

`BetterBuffsForever.lua` is the shared part (box, rows, aura scan, group and tank, settings, slash
command, API, events). `Druid.lua` and `Paladin.lua` are the class modules; each registers itself
in the addon's private namespace (`local _, ns = ...`), so the modules add no globals. Both TOCs
list all three, the shared file first.

## How it stays out of the way

- Blizzard code is only followed, never replaced: no Blizzard function or table is written and no
  Blizzard frame is touched.
- Attributes and click registration are set only on the addon's own secure buttons, only out of
  combat; a spellbook change in combat waits for `PLAYER_REGEN_ENABLED`.
- Every client API is checked with `type(...) == "function"` before use, every handler runs in
  `pcall` (the last error is kept for `/bbuff status`), and a secret value is treated as no value,
  never compared or tested.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Account-wide
  (`BetterBuffsForeverDB`): `enabled`, `group`, `sound`, `reagents`, `locked`, `pos`; druid
  `motw`, `thorns`, `thornsTank`, `gotwMin`, `rebirthMin`; paladin `bless`, `aura`, `fury`,
  `kingsMin` and `blessings` (only the classes changed from the default). Per character
  (`BetterBuffsForeverCharDB`): `tank` (`{ guid, name }`), and for a paladin `lastAura` and
  `tanking`. Every class's keys are kept whatever class logs in.

## Names it relies on

From Blizzard's retail FrameXML and API documentation, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source)): `SecureActionButtonTemplate`,
`RegisterStateDriver`, `C_UnitAuras.GetAuraDataByIndex`, `C_Secrets.ShouldUnitAuraIndexBeSecret`,
`C_Spell.GetSpellInfo`, `C_Spell.IsSpellInRange`, `C_Item.GetItemCount`,
`C_Item.GetItemNameByID`, `UnitGroupRolesAssigned`, `GetPartyAssignment`, `GetNumShapeshiftForms`,
`GetShapeshiftFormInfo`, `UnitIsVisible`, `UnitIsConnected`, `UnitIsDeadOrGhost`, `IsInGroup`,
`IsInRaid` and `InCombatLockdown`. It ships a `_Camelot` TOC and a plain fallback TOC, both at
16001.

## License

MIT, see [LICENSE](LICENSE).
