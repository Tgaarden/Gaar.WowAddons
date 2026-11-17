# GaarBuffsForever

> Formerly **BetterBuffsForever**. The folder is now `GaarBuffsForever` as well; the update also ships a tiny `BetterBuffsForever` folder, a
> settings bridge that moves your old settings over on the first login (each character on its own
> first login). It is safe to delete after logging in once on each character, and later updates drop it. The command is
> now `/gbuff` (`/gaarbuffsforever`); the old `/bbuff` and `/betterbuffsforever` still work.
> CurseForge: https://www.curseforge.com/wow/addons/gaarbuffsforever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001), for druids,
paladins, shamans, priests and mages, with a dispel panel for every class that can remove something (druids,
shamans, priests, paladins and mages). A box at the top centre of the screen lists who in your group lacks your buffs and
whether your reagents are running low. Click a name to buff that member. It needs GaarForever, the family hub, and no other addon or library, and it is not part of the Gaar suite.

New in 1.6: in combat **the game itself draws the dispellable debuff's icon** on the dispel strip
(Blizzard aura container), so a member with something to remove shows up even though the addon
cannot read auras in combat; a **low-level member gets a lower rank** they can actually receive;
an **"Expiring ..." warning** out of combat when one of your buffs has less than 2 minutes left
(`/gbuff expire 0-5`); and the "something went missing" sound no longer fires for members left
out because they are out of range.

New in 1.8: **dispel clicks follow what the member has**. Out of combat a dispel row whose member
has one kind casts that kind's spell on either mouse button (a poisoned member: Abolish/Cure
Poison on left- and right-click alike); a button whose own spell you do not know (or switched
off) casts the other one, on the rows and the in-combat strip, so a druid without Remove Curse
gets Cure Poison on left-click too. A spell the client can name but you have not learned
(Abolish Poison on a low-level druid) no longer counts as known. And druids get an optional
**leave form to dispel** (`/gbuff dispel form`, per character, off by default).

- **Druid**: **Mark of the Wild** (Gift of the Wild counts) on you and the group, **Thorns** on you
  and the tank, **Gift of the Wild and Rebirth reagents**, and a **dispel panel** for curses and
  poisons (a list out of combat, one click button per member in combat).
- **Paladin**: a **blessing per class** on every member (with a fallback when another paladin's
  blessing is already there), **No aura**, **Righteous Fury** while you tank, **Symbol of Kings**,
  and (new in 1.4) the **dispel panel**: Cleanse, else Purify, on either mouse button.
- **Shaman** (new in 1.3): a **weapon without an imbue** (click casts the imbue you chose),
  **Lightning Shield**, **Ankh, totem, Fish Oil and Shiny Fish Scales reagents**, and the same
  **dispel panel** for poisons and diseases.
- **Priest**: (new in 1.5) **Power Word: Fortitude** (Prayer of Fortitude counts) on you and the
  group, **Sacred Candle** once you know Prayer of Fortitude, and (since 1.4) the **dispel panel**
  for magic (left-click Dispel Magic) and diseases (right-click Abolish Disease, else Cure
  Disease).
- **Mage**: (new in 1.5) **Arcane Intellect** (Arcane Brilliance counts) on you and every group
  member whose class uses mana, **Arcane Powder** once you know Arcane Brilliance, and (since 1.4)
  the **dispel panel** for curses (Remove Lesser Curse on either mouse button).

## What it does (every class)

- **Druids, paladins, shamans, priests and mages** get the buff box and the dispel panel,
  picked by your class: there is nothing to set. On any other class (warrior,
  rogue, hunter, warlock) the addon stays idle: no scans, no box, no panel. `/gbuff status` says
  `not a druid, mage, paladin, priest or shaman: the addon is idle on this character.` A
  warlock's Felhunter (Devour Magic) is left out on purpose: it is the pet's spell, not yours.
- **The tank** is, in this order:
  1. every member `UnitGroupRolesAssigned(unit)` calls `"TANK"`;
  2. else, in a raid, every main tank (`GetPartyAssignment("MAINTANK", unit)`);
  3. else the tank you set by hand: target a group member and type `/gbuff tank` (saved per
     character, `/gbuff tank clear` removes it; also in the hub menu);
  4. else there is no tank. You can be the tank yourself.
- **Only spells you know.** A spell the character has not learned is not checked.
- **The box.** At the top centre, shown only while something is missing: one section per thing
  missing (`Missing Mark of the Wild:`, `Missing Blessing of Might:`, `No aura:`, ...; the spell
  names are the client's own), one row per member with the spell's icon and a class-coloured
  name, `(you)` for yourself and `(tank)` for a tank, then the low-reagent lines
  (`Low reagents: Wild Thornroot 3/10`). It hides again when everything is covered.
- **Who is never warned about:** dead or ghost members, offline members, and members the client
  does not see (`UnitIsVisible`, too far away). Members out of the spell's range are left out of the
  box (and of the out-of-combat dispel list) by default; with `/gbuff range on` (or the menu
  toggle `Show members out of range`, saved account-wide) they are shown dimmed with
  `(out of range)` and stay clickable, the cast just fails. An unknown (secret) range is always
  shown. If every missing member is out of range the section, and the box, disappears.
- **Expiring soon** (new in 1.6, out of combat): a buff the module tracks (Mark of the Wild,
  Thorns, Power Word: Fortitude, Arcane Intellect, your own blessings, Lightning Shield, a weapon
  imbue) with less than N minutes left gets a row in an `Expiring Mark of the Wild:` (...,
  `Expiring blessings:`, `Weapon imbue expiring:`) section with the time left after the name,
  `Healbot (1:45)`. Clicking recasts it. N is `/gbuff expire 0-5` or the menu slider (default 2,
  `0` = off). Only a plain, finite duration counts (a secret or permanent one is never warned
  about), and the box refreshes every 1.5 s while the warning is on. Expiring rows do not count
  as missing and do not play the sound.
- **Unknown is not missing.** A member whose buffs cannot be read (a secret aura, a refused read)
  counts as unknown and is never warned about. `/gbuff status` gives the count.
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

## Priest and mage

New in 1.5, in `PriestMage.lua`: one group buff each, checked the way the druid checks Mark of
the Wild.

- **Priest: Power Word: Fortitude.** Warns when you lack it and, in a party or raid, lists every
  member who lacks it. Prayer of Fortitude counts as having it.
- **Mage: Arcane Intellect**, the same way, but only for members whose class uses mana: a warrior
  or a rogue is never listed (hunters, paladins, priests, shamans, druids, mages and warlocks
  are). A member whose class the client does not give is listed. Arcane Brilliance counts as
  having it.
- **Clicks.** Left-click casts the highest rank you know on that member. Right-click casts
  **Prayer of Fortitude** / **Arcane Brilliance** (the whole party of that member) when you know
  it and are in a group (it needs its reagent). Otherwise right-click does what left-click does.
- **Reagents**, only once the group version is known (it is learned from a book):

  | Spell | Reagent | Default threshold |
  |---|---|---|
  | Prayer of Fortitude (21562, 21564) | Sacred Candle (17029) | 10 |
  | Arcane Brilliance (23028) | Arcane Powder (17020) | 10 |

- `/gbuff fort on|off` (priest) and `/gbuff ai on|off` (mage) switch the check, on by default;
  `/gbuff reagents prayer <n>` and `/gbuff reagents brilliance <n>` set the thresholds. The hub
  menu and the Options page have the same switches.

## The dispel panel (druid, shaman, priest, paladin, mage)

New in 1.2 for druids, since 1.3 for shamans and since 1.4 for priests, paladins and mages, in
`Dispel.lua`. On by default (`/gbuff dispel off` to switch it off). What differs per class is
which kinds each mouse button removes (one table, `CLASS_CONFIG`: one or two actions, each with
its spells and the kinds each spell removes):

| Class | Left-click | Right-click |
|---|---|---|
| Druid | Curse (purple): Remove Curse (2782) | Poison (green): Abolish Poison (2893), Cure Poison (8946) until Abolish is known |
| Shaman | Poison (green): Cure Poison (526) | Disease (ochre): Cure Disease (2870) |
| Priest | Magic (blue): Dispel Magic (988, 527: the highest rank you know) | Disease (ochre): Abolish Disease (552), Cure Disease (528) until Abolish is known |
| Paladin | Cleanse (4987: poison, disease, magic), else Purify (1152: poison, disease) | the same |
| Mage | Curse (purple): Remove Lesser Curse (475) | the same |

Warriors, rogues, hunters and warlocks get no panel (the warlock's Felhunter Devour Magic is left
out on purpose).

- **Spells**, only those you know. The IDs are the classic ones (the same as in WhatsTraining's
  Vanilla/Camelot class data), resolved by ID, else by the localized name, again on
  `SPELLS_CHANGED` / `LEARNED_SPELL_IN_TAB`; `/gbuff status` shows what was resolved. **Until you
  know the class's dispel spell the panel stays hidden** (a low-level character), and it appears
  once you learn it.
- **Only kinds your known spell removes count.** A paladin with only Purify is never shown a
  magic debuff; once Cleanse is learned, magic counts too.
- **A panel of its own**, not part of the buff box. By default it sits just below the box (and
  follows it). `/gbuff dispel unlock` to drag it (Alt + drag works when locked),
  `/gbuff dispel lock`, `/gbuff dispel reset` to put it back below the box. The position is saved
  account-wide.
- **Out of combat**: one row per member, you included, with something you can remove: the
  class-coloured name and a tag per kind, `Magic` (blue), `Curse` (purple), `Poison` (green),
  `Disease` (ochre);
  `(you)`,
  `(out of range)` (dimmed, only with `/gbuff range on`; left out otherwise). Dead, offline and unseen members are skipped. Read from the plain
  `dispelName` of `C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")` (`UnitDebuff` on an older
  client).
- **In combat**: the list is replaced by a fixed strip, one secure button per group member, shown
  for the whole fight by a state driver (`[combat] show; hide` on the strip, `[combat] hide; show`
  on the list):
  - solo: you; party: you and party1-4 in one row;
  - raid: every `raidN`, one column per subgroup that has members (in group order), up to 8
    columns of 5 smaller buttons, so at most 40.

  The strip is built out of combat whenever the roster changes, and at `PLAYER_REGEN_DISABLED` if
  a rebuild is still due. A roster change in combat only updates the names; the buttons follow
  unit tokens so they keep casting on whoever holds the token, and the rebuild runs at
  `PLAYER_REGEN_ENABLED`.
- **Only who has something to remove is seen** (since 1.2.3): a button whose member has nothing
  to remove is fully invisible (alpha 0, background included), and the strip has no background of
  its own, so a fight with nothing to remove shows nothing. When the client answers "has one" with
  a secret boolean, it goes straight to `SetAlphaFromBoolean(has, 1, 0)`. An invisible button still
  takes clicks in combat (a secure button's mouse cannot be switched off then), but shows no
  tooltip. Since 1.2.4 **unknown counts as nothing**: when no way answers (method 4 below), the
  detection fails, or `SetAlphaFromBoolean` refuses a secret answer, the button is invisible too.
  Only a real "has one" shows a button.
- **The game draws the icons in combat** (new in 1.6). On this client the addon cannot read
  auras in combat, so on its own the strip stayed empty there (unknown = hidden). Now each
  strip button has a Blizzard aura container under it (`CreateFrame("AuraContainer", nil, strip,
  "CustomAuraContainerTemplate")`, the technique GaarFramesForever uses for unit frame auras)
  for that member's unit, with one aura slot: filter `HARMFUL` plus the candidate filter
  `includeDispelTypes` = the kinds you can remove now (your known spell's kinds that are switched
  on, the same rule as the out-of-combat list; the retail engine's
  `HARMFUL|RAID_PLAYER_DISPELLABLE` is not used for it because it may not match a classic
  spellbook). The client reads the auras in its own secure code and shows the slot only while
  the member has such a debuff; everything the cell shows hangs off that slot: a dark
  background the size of the button, a bar in the dispel type's colour (the game's debuff
  colours), the debuff's icon, the member's name and the debuff's name (written by the client).
  So a member's cell appears and disappears with the client's own answer, and no addon code
  sees it. The secure button stays on top of it (higher frame level), invisible, and takes the
  click; its own alpha cannot follow the client's answer in combat because Lua never gets a
  boolean to hand to `SetAlphaFromBoolean`. If the addon can read a plain answer it still
  paints the button itself, covering the cell. No tooltip on a client-drawn cell. The
  containers are built with the strip, out of combat, and only shown (and listening) in
  combat. `/gbuff status` has a `combat icons (Blizzard aura container):` line: active (with
  how many buttons have one), not on this client, or refused (said once in chat; then the strip
  works as in 1.5).
- **What to remove**, like the buff box's rows: the debuff's icon on the left, then `Name:` and the
  debuff's name (party/solo: 150 px wide buttons, the name truncated to fit; raid: 58 px buttons
  with the icon and a short name only). Name and icon are the first dispellable debuff's
  (`aura.name` / `aura.icon`, or `C_UnitAuras.GetAuraDataByAuraInstanceID`); they may be secret
  and are set as they are in a font string and texture of their own. Without them: a question
  mark and `Magic`, `Curse`, `Poison`, `Disease` or `Dispel`.
- **The colour** (plain textures, allowed in combat): the kinds found, in the class's order
  (left-click's first), the first on the left half and the second on the right half; one kind =
  that colour all over. Druid: a curse = purple, a poison = green, both = left half purple, right
  half green. Shaman: a poison = green, a disease = ochre, both = left half green, right half
  ochre. Priest: magic = blue, a disease = ochre, both = left half blue, right half ochre.
  Paladin (one action): the kinds in the order poison, disease, magic, so poison + magic = left
  half green, right half blue (three kinds: the first two). Mage: a curse = purple all over.
  Dispellable but of an unknown kind (a druid's disease, say) = yellow.
- **Clicks**: **left-click** and **right-click** cast the spells in the table above on that member
  (`type1`/`spell1`, `type2`/`spell2`, `unit`); a paladin and a mage have one spell on both.
  Since 1.8:
  - **Out of combat a row follows what its member has**: when every kind the member has is
    removed by one spell, both buttons cast it. A druid's poisoned member: Abolish Poison (else
    Cure Poison) on left- and right-click; cursed: Remove Curse on both; cursed and poisoned:
    left = Remove Curse, right = poison, as in the table. The rows are bound again whenever that
    changes (out of combat only).
  - **In combat the strip keeps the fixed order** of the table (left = the first column, right =
    the second): a secure button's attributes cannot change in combat, and who has what is not
    known when the strip is built.
  - **The other spell as a fallback**, rows and strip alike: a button whose own spell you do not
    know, or whose kinds are all switched off, casts the other one. A druid without Remove Curse
    (level 14-23) gets Cure Poison on left-click too. Nothing known and switched on = the click
    does nothing.
  - The tooltip of a row or strip button says what each mouse button casts.

  Registered for the click direction `ActionButtonUseKeyDown` acts on.
- **Leave form to dispel** (druid, new in 1.8, **off by default**, per character):
  `/gbuff dispel form [on|off]`, or the checkbox *Dispel: leave form first (this character)* in
  the menu and settings page. On: the dispel rows and strip buttons use a macro instead of a
  plain spell cast, `/cancelform [form]` then `/cast [@<unit>] <spell name>`, so a click in cat,
  bear, aquatic or travel form drops the form and dispels (moonkin form too, since it is a form).
  Off: the plain spell cast, no form is left. Switched in combat it is saved at once and the
  buttons change after combat. `/gbuff status` shows it.
- **Spell lookup by name** (since 1.8): when no rank reports itself as known, the localized name
  counts only when the spellbook confirms it (`C_SpellBook.FindSpellBookSlotForSpell` or
  `IsSpellKnownOrOverridesKnown`), so a spell you have not learned yet no longer beats the one
  you have (Abolish Poison vs Cure Poison). Where neither API answers, the name alone counts as
  before.
- **`/gbuff dispel magic off`** / **`curse off`** / **`poison off`** / **`disease off`**: that
  kind is ignored (no rows, no colour, no click). The settings are account-wide, so `poison off`
  applies to a druid, a shaman and a paladin alike. The menu and settings page show only the
  kinds of your class.

### Finding a dispellable debuff in combat

Aura contents are secret in combat on this client, and index reads from addon code are refused.
Each member is tried in this order; the first way that answers wins, and `/gbuff status` says
which ways answered in the last fight:

1. **Plain read**: the out-of-combat read, when the client allows it. Exact.
2. **Aura instance IDs + dispel colour**: `C_UnitAuras.GetUnitAuraInstanceIDs(unit, filter, 2)`
   with the first filter `AuraUtil.IsValidFilterString` accepts of
   `HARMFUL|RAID_PLAYER_DISPELLABLE` and `HARMFUL|RAID` (the first is in Forever's client). A plain
   count says whether there is one. The colour comes from
   `C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, curve)` with a step colour curve over
   the dispel type (the kinds your known spell removes: Magic 1 blue, Curse 2 purple, Disease 3
   ochre, Poison 4 green; the rest and a switched-off kind transparent),
   passed straight to `SetVertexColor` and never read. Without a colour: yellow.
3. **Filtered read**: `GetAuraDataByIndex(unit, 1..2, filter)`; a non-nil answer means there is
   one, the kind from a plain `dispelName` or else the colour API, else yellow.
4. **None**: unknown, so the button is invisible (still clickable where it sits); `/gbuff status`
   says so. The client-drawn cell under it (above) still shows a dispellable debuff.

`/gbuff status` counts, per way, how each paint in the fight ended: `shown`, `hidden` (nothing to
remove), `secret` (left to `SetAlphaFromBoolean`) or `unknown` (hidden), and lists why the earlier
ways gave no answer (`ways that gave no answer: plain read: error: ...; aura instance IDs: ...`).

With method 2 a member counts as having something when the filter finds any debuff you can
dispel, even one of a kind you switched off (it is then shown, with that debuff's name, but gets
no colour).
`UNIT_AURA` marks a member; in combat the strip repaints marked members at most 10 times a second
and everyone once a second. The list updates at most 4 times a second, and every 1.5 s in a
group.

## Shaman

New in 1.3, in `Shaman.lua`. A shaman has no group buff, so only you are checked (the dispel
panel still covers the group).

- **Weapon imbue.** A `No weapon imbue:` row per hand that holds a weapon without a temporary
  enchant (`GetWeaponEnchantInfo`): the main hand, and the off hand only when it holds a weapon
  (not a shield, an off-hand item or nothing). Any temporary enchant counts (an imbue, but also a
  poison or a sharpening stone); a fishing pole is never warned about. Only a missing imbue is
  warned about, not one running out soon (the druid and paladin checks do not warn on expiry
  either). While the check is on, the box also refreshes every 1.5 s out of combat, since an
  imbue can run out without an event; `UNIT_INVENTORY_CHANGED`, `PLAYER_EQUIPMENT_CHANGED` and
  `WEAPON_ENCHANT_CHANGED` (where the client has it) refresh it at once.
- **Which imbue a click casts** (per character): `/gbuff imbue auto|rockbiter|flametongue|frostbrand|windfury`,
  or the hub's **Weapon imbue** submenu. `auto`, the default, is Windfury Weapon when you know it,
  else Flametongue Weapon, else Rockbiter Weapon. A chosen imbue you do not know yet falls back to
  auto (the row says so). Always the highest rank you know, by name. Classic shamans cannot dual
  wield; for a client that lets them, the game picks the weapon an imbue lands on.
- **Lightning Shield.** A row when you lack it, once you know it (level 8). The row casts it.
- **Reagents**, each only once you know the spell that needs it:

  | Reagent | For | Default threshold |
  |---|---|---|
  | Ankh (17030) | Reincarnation (20608) | 2 (`/gbuff reagents ankh <n>`) |
  | Earth Totem (5175), Fire Totem (5176), Water Totem (5177), Air Totem (5178) | any totem of that element | 1, so only when it is not in your bags; it is not used up (`/gbuff reagents totems 0` to switch off) |
  | Shiny Fish Scales (17057) | Water Breathing (131) | 5 (`/gbuff reagents water <n>`) |
  | Fish Oil (17058) | Water Walking (546) | 5 (the same threshold) |

  Counted by item ID, and by the item's name when the ID finds none.

## Paladin

### Blessings by class

Every member, you included, should have the blessing assigned to their class, from you:

| Class | Default |
|---|---|
| Warrior, Rogue, Hunter | Blessing of Might |
| Mage, Priest, Warlock, Druid, Paladin, Shaman | Blessing of Wisdom |

Change a class with `/gbuff bless <class> <might|wisdom|kings|salvation|light|sanctuary|none>` or
in the hub's **Blessings by class** submenu (one radio list per class). The assignments are
account-wide; `/gbuff bless reset` puts back the defaults. `none` switches a class off. Kings is
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
said you are tanking (`/gbuff tanking on`, per character, also a hub checkbox). Clicking casts it
on yourself.

### Symbol of Kings

`Low reagents: Symbol of Kings 12/20` when the bags hold fewer than the threshold (default 20,
`/gbuff reagents kings <n>`) of Symbol of Kings (21177), the reagent of the Greater Blessings, and
only while you know a Greater Blessing.

## Click to buff

Every row is a `SecureActionButtonTemplate` button of the addon's own: `type` = `spell`, `spell` =
the localized name of the highest rank you know (or its spell ID when the client gives no name),
`unit` = that member's unit token (`player`, `party1`, `raid7`, ...). Right-click uses `type2` /
`spell2` (Gift of the Wild, a Greater Blessing, Prayer of Fortitude, Arcane Brilliance).

- The rows are registered for the one click direction `ActionButtonUseKeyDown` acts on (read at
  every rebuild), so one click casts once with the CVar on or off.
- **Lower rank for a low-level member** (new in 1.6). A buff lands only on a target whose level is
  at least the rank's spell level - 10 (Mark of the Wild rank 7, level 60, needs a level 50
  target). For a member below that, the row casts the highest rank they can receive, by spell ID
  (`spell` = e.g. `5234`, which the secure button casts with `CastSpellByID`), and says `rank 4`
  after the name; the tooltip explains it. The rank levels are the classic trainer levels
  (WhatsTraining's Vanilla/Camelot data, the same on both): Mark of the Wild, Thorns, Power
  Word: Fortitude, Arcane Intellect, Blessing of Might, Wisdom, Light and Sanctuary. Only ranks
  you know count; a member whose level is hidden, or with no lower rank you know that fits,
  keeps the highest rank. The rows exist only out of combat, so this is set when the row is
  built. The right-click group version (Gift of the Wild, Prayer of Fortitude, Arcane
  Brilliance, a Greater Blessing) is not lowered.
- Hover a row for a tooltip with what each click casts.

## Combat

**The buff box is hidden in combat** (the dispel panel is not: see above), on purpose: aura data is secret then, secure attributes cannot
change, and buffing mid-fight is not what it is for. A visibility state driver
(`RegisterStateDriver(holder, "visibility", "[combat] hide; show")`) hides it the moment combat
starts, by secure code; on a client without state drivers `PLAYER_REGEN_DISABLED` does it.
Nothing is scanned in combat. At `PLAYER_REGEN_ENABLED` everything is checked again and the rows
are rebuilt. The rows' attributes, size and place are only ever changed out of combat.

## Moving the box

- `/gbuff unlock`: the box stays shown (with a hint line) and can be dragged anywhere.
  `/gbuff lock` when done.
- **Alt + drag** moves it at any time, locked or not (out of combat).
- `/gbuff reset`: back to the top centre.

The position is saved account-wide in `GaarBuffsForeverDB`, as an offset from the top centre.

## Commands

| Command | Does |
|---|---|
| `/gbuff` or `/gbuff help` | Help (the commands for your class) |
| `/gbuff on`, `/gbuff off` | Switch the addon on or off |
| `/gbuff group [on\|off]` | List group members (off: only you are checked) |
| `/gbuff sound [on\|off]` | A short sound when something new goes missing (off by default; never for members left out because they are out of range) |
| `/gbuff expire <0-5>` | Out of combat, warn when one of your buffs has less than this many minutes left (default 2; `0` or `off` = off) |
| `/gbuff range [on\|off]` | Show members out of range, dimmed (off by default: they are left out of the box and the dispel list) |
| `/gbuff reagents [on\|off]` | The low-reagent warning (on by default) |
| `/gbuff tank` (or `tank set`) | Your current target, a group member, becomes the tank set by hand |
| `/gbuff tank clear` | Clear the tank set by hand |
| `/gbuff unlock`, `/gbuff lock`, `/gbuff reset` | Move the box, stop moving it, put it back at the top centre |
| `/gbuff test` | Show the box with test rows for your class (they cast nothing), and for a class with a dispel panel the panel with sample rows and a sample strip in your class's colours; again to hide them |
| `/gbuff status` | Version, the class module (Druid, Paladin, Shaman, Priest, Mage, or none: idle), the options, the resolved spells, the reagents with count and threshold, the group, the tank and where it came from, the last check, the box (shown, lock, position, how combat hides it), which aura, role and main-tank APIs this client has, and the last error. A paladin also gets the assignment table (`*` = changed), the auras known, the active one and where it was read, the last-used aura, Righteous Fury and the tanking toggle. A shaman also gets the imbues known, the imbue choice and what a click casts, both hands' weapon and imbue state, Lightning Shield, Reincarnation, the totem elements known and Water Breathing / Walking. Every class with a dispel panel also gets it (state, spells per mouse button, the kinds it removes now, strip layout, filter and APIs, which in-combat detection answered in the last fight and how its paints ended: shown / hidden / secret / unknown, and why earlier ways gave no answer) |
| **Druid** | |
| `/gbuff motw [on\|off]` | The Mark of the Wild check (no argument toggles) |
| `/gbuff thorns [on\|off]` | Warn when you lack Thorns |
| `/gbuff tank on\|off` | Warn when the tank lacks Thorns |
| `/gbuff reagents gotw <n>`, `/gbuff reagents rebirth <n>` | Warn below n Gift of the Wild reagents (default 10) or Rebirth seeds (default 2), 0-200 |
| `/gbuff dispel [on\|off]` | The dispel panel (no argument toggles) |
| `/gbuff dispel curse [on\|off]`, `/gbuff dispel poison [on\|off]` | Each kind (also `magic` and `disease`, for the other classes) |
| `/gbuff dispel unlock`, `lock`, `reset` | Move the dispel panel, stop moving it, put it back below the box |
| `/gbuff dispel form [on\|off]` | Leave cat/bear/travel form when you click a dispel button (this character; off by default; changed in combat, it applies after combat) |
| **Paladin** | |
| `/gbuff bless [on\|off]` | The blessing check |
| `/gbuff bless <class> <type>` | Assign a blessing to a class: `warrior`, `rogue`, `hunter`, `mage`, `priest`, `warlock`, `druid`, `paladin`, `shaman`; `might`, `wisdom`, `kings`, `salvation`, `light`, `sanctuary` or `none` |
| `/gbuff bless reset` | Every class back to its default |
| `/gbuff aura [on\|off]` | Warn when no aura is on |
| `/gbuff fury [on\|off]` | Warn when you tank without Righteous Fury |
| `/gbuff tanking [on\|off]` | Say you are tanking (this character), for the Righteous Fury check |
| `/gbuff reagents kings <n>` | Warn below n Symbols of Kings (default 20), 0-200 |
| `/gbuff dispel [on\|off]`, `/gbuff dispel poison\|disease\|magic [on\|off]`, `unlock`, `lock`, `reset` | The dispel panel (Cleanse, else Purify; `magic` only matters with Cleanse) |
| **Shaman** | |
| `/gbuff imbue [on\|off]` | Warn when a weapon has no imbue |
| `/gbuff imbue auto\|rockbiter\|flametongue\|frostbrand\|windfury` | What a click on the imbue row casts (this character; default auto) |
| `/gbuff shield [on\|off]` | Warn when you lack Lightning Shield |
| `/gbuff reagents ankh <n>`, `totems <n>`, `water <n>` | Warn below n Ankhs (default 2), totem items (default 1), Fish Oil / Shiny Fish Scales (default 5) |
| `/gbuff dispel [on\|off]`, `/gbuff dispel poison\|disease [on\|off]`, `unlock`, `lock`, `reset` | The dispel panel, as for a druid |
| **Priest** | |
| `/gbuff fort [on\|off]` | The Power Word: Fortitude check (Prayer of Fortitude counts; no argument toggles) |
| `/gbuff reagents prayer <n>` | Warn below n Sacred Candles (default 10), 0-200, once Prayer of Fortitude is known |
| `/gbuff dispel [on\|off]`, `/gbuff dispel magic\|disease [on\|off]`, `unlock`, `lock`, `reset` | The dispel panel |
| **Mage** | |
| `/gbuff ai [on\|off]` | The Arcane Intellect check, classes with mana only (Arcane Brilliance counts; no argument toggles) |
| `/gbuff reagents brilliance <n>` | Warn below n Arcane Powder (default 10), 0-200, once Arcane Brilliance is known |
| `/gbuff dispel [on\|off]`, `/gbuff dispel curse [on\|off]`, `unlock`, `lock`, `reset` | The dispel panel |

The class settings are account-wide (except the shaman's imbue choice and the druid's leave form to dispel, per character), so the
druid commands also work on a paladin and the other way round; they only matter on that class.

## With GaarForever (required)

Since 1.2.1 this addon lists `GaarForever` (the GaarForever folder) under `## Dependencies`: install the `GaarForever` folder next to it, or the client will not load this addon. GaarForever also gives it a page under **Esc > Options > AddOns > Gaar Forever**, built from the same `MenuEntries()` as the hub's menu, with a short intro at the top; that intro comes from `Intro()`, a field the API table gained in 1.2.1 (it is also the first line of the slash command's help). Since 1.2.2 it also takes its small helpers (the chat line, the secret-value, text and true/false checks, the combat check, on/off text, drawing the hub's menu) from GaarForever's shared library instead of carrying its own copies; nothing it does or shows changed.

[GaarForever](../GaarForever/README.md) is the family hub: one minimap button whose
menu has a **Buffs** submenu with the options for your class:

- every class with a module: **Enabled**, then the class options, **List group members**, **Sound
  when something goes missing**, **Low reagent warning**, **Show members out of range**, **Warn
  when a buff expires within (minutes)** (a slider, 0-5), the class's reagent threshold(s), **Set
  tank: current target**, **Clear tank** (while one is set), **Lock box**, **Test box** and **Reset
  position**;
- a druid: **Mark of the Wild check**, **Thorns on you**, **Thorns on the tank**, **Dispel panel
  (curses, poisons)**, **Dispel: curses**, **Dispel: poisons**, **Gift of the Wild reagent warning
  below** (0/5/10/20/40), **Rebirth reagent warning below** (0/1/2/3/5), **Lock dispel panel**,
  **Reset dispel panel position**;
- a shaman: **Weapon imbue check**, **Lightning Shield on you**, **Dispel panel (poisons,
  diseases)**, **Dispel: poisons**, **Dispel: diseases**, the **Ankh** (0/1/2/3/5), **Totem items**
  (0/1) and **Fish Oil / Shiny Fish Scales** (0/1/5/10/20) reagent thresholds, **Weapon imbue
  (this character)** (a radio list: Auto, Rockbiter, Flametongue, Frostbrand, Windfury), **Lock
  dispel panel**, **Reset dispel panel position**;
- a paladin: **Blessing check (by class)**, **Warn when no aura is on**, **Righteous Fury when
  tanking**, **Dispel panel (poisons, diseases, magic)**, **Dispel: poisons**, **Dispel:
  diseases**, **Dispel: magic**, **Symbol of Kings reagent warning below** (0/10/20/40/60),
  **Blessings by class** (one submenu per class with a radio list of the blessings and None, plus
  Reset to defaults), **I'm tanking (this character)**, **Lock dispel panel** and **Reset dispel
  panel position**;
- a priest: **Power Word: Fortitude check**, **Dispel panel (magic, diseases)**, **Dispel:
  magic**, **Dispel: diseases**, **Prayer of Fortitude reagent warning below** (0/5/10/20/40),
  **Lock dispel panel**, **Reset dispel panel position**;
- a mage: **Arcane Intellect check**, **Dispel panel (curses)**, **Dispel: curses**, **Arcane
  Brilliance reagent warning below** (0/5/10/20/40), **Lock dispel panel**, **Reset dispel panel
  position**.

They go through the same functions as the slash command. This addon has no minimap button or menu
of its own, so nothing here changes with or without the hub.

The hub talks to this addon only through `GaarBuffsForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `on · 2 missing`, `on · all buffed`, `on · hidden in combat` or `idle (not a druid, mage, paladin, priest or shaman)` |
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
  - Shaman: Rockbiter Weapon 8017, 8018, 8019, 10399, 16314, 16315, 16316; Flametongue Weapon
    8024, 8027, 8030, 16339, 16341, 16342; Frostbrand Weapon 8033, 8038, 10456, 16355, 16356;
    Windfury Weapon 8232, 8235, 10486, 16362; Lightning Shield 324, 325, 905, 945, 8134, 10431,
    10432; Reincarnation 20608, Water Breathing 131, Water Walking 546 (reagents only); totems,
    rank 1, for "an element is known": Earth 8071, 2484, 5730, 8075, 8143; Fire 3599, 1535, 8181,
    8190, 8227; Water 5394, 8166, 5675, 8184, 8170; Air 8177, 10595, 8512, 6495, 15107, 8835,
    25908. Checked against WhatsTraining's Vanilla shaman data.
  - Priest: Power Word: Fortitude 1243, 1244, 1245, 2791, 10937, 10938; Prayer of Fortitude
    21562, 21564.
  - Mage: Arcane Intellect 1459, 1460, 1461, 10156, 10157; Arcane Brilliance 23028. Checked
    against WhatsTraining's Vanilla priest and mage data (the book-learned group versions against
    its TBC data, same IDs).

  The highest rank known (`C_SpellBook.IsSpellKnown`, `IsPlayerSpell`, `IsSpellKnown`) is resolved
  at login and on `SPELLS_CHANGED`, out of combat.
- Buffs are read by index, `C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")` (`UnitBuff` or
  `UnitAura` on an older client), one `pcall` per read, asking
  `C_Secrets.ShouldUnitAuraIndexBeSecret` first, as GaarFramesForever does. A buff is matched by
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

`GaarBuffsForever.lua` is the shared part (box, rows, aura scan, group and tank, settings, slash
command, API, events). `Druid.lua`, `Paladin.lua`, `Shaman.lua` and `PriestMage.lua` (one
factory, two modules: priest and mage) are the class modules; each registers itself in the
addon's private namespace (`local _, ns = ...`), so the modules add no globals.
`Dispel.lua` is the dispel panel of a druid, a shaman, a priest, a paladin and a mage: it adds its
options, commands, status lines and menu entries to those five modules and keeps its own
(unnamed) frames and events. One `CLASS_CONFIG` table says, per class, which spell each click
casts and which kinds each spell removes. Both TOCs list all six, the shared file first and
`Dispel.lua` last.

## How it stays out of the way

- Blizzard code is only followed, never replaced: no Blizzard function or table is written and no
  Blizzard frame is touched.
- Attributes and click registration are set only on the addon's own secure buttons, only out of
  combat; a spellbook change in combat waits for `PLAYER_REGEN_ENABLED`.
- Every client API is checked with `type(...) == "function"` before use, every handler runs in
  `pcall` (the last error is kept for `/gbuff status`), and a secret value is treated as no value,
  never compared or tested.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Account-wide
  (`GaarBuffsForeverDB`): `enabled`, `group`, `sound`, `reagents`, `locked`, `pos`,
  `showOutOfRange`, `expireMin` (unset = 2); druid
  `motw`, `thorns`, `thornsTank`, `gotwMin`, `rebirthMin`, `dispel`, `dispelCurse`,
  `dispelPoison`, `dispelPos`, `dispelLocked`; paladin `bless`, `aura`, `fury`,
  `kingsMin` and `blessings` (only the classes changed from the default), and the shared dispel
  keys plus `dispelMagic`; priest `fort`, `prayerMin`, `dispelMagic`, `dispelDisease`; mage `ai`,
  `brillianceMin`, `dispelCurse`; shaman `imbue`,
  `shield`, `ankhMin`, `totemMin`, `waterMin`, `dispelDisease` (and the shared `dispel`,
  `dispelPoison`, `dispelPos`, `dispelLocked`). Per character
  (`GaarBuffsForeverCharDB`): `tank` (`{ guid, name }`), for a paladin `lastAura` and
  `tanking`, and for a shaman `imbueChoice` (unset = auto). Every class's keys are kept whatever class logs in.

## Names it relies on

From Blizzard's retail FrameXML and API documentation, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source)): `SecureActionButtonTemplate`,
`RegisterStateDriver`, `C_UnitAuras.GetAuraDataByIndex`, `C_Secrets.ShouldUnitAuraIndexBeSecret`,
`C_UnitAuras.GetUnitAuraInstanceIDs`, `C_UnitAuras.GetAuraDataByAuraInstanceID`,
`C_UnitAuras.GetAuraDispelTypeColor`, `Region:SetAlphaFromBoolean`,
`C_CurveUtil.CreateColorCurve`, `AuraUtil.IsValidFilterString`, `C_Spell.GetSpellInfo`,
`C_Spell.IsSpellInRange`, `C_Item.GetItemCount`,
`C_Item.GetItemNameByID`, `UnitGroupRolesAssigned`, `GetPartyAssignment`, `GetNumShapeshiftForms`,
`GetShapeshiftFormInfo`, `GetWeaponEnchantInfo`, `GetInventoryItemID`, `C_Item.GetItemInfoInstant`, `UnitIsVisible`, `UnitIsConnected`, `UnitIsDeadOrGhost`, `IsInGroup`,
`IsInRaid` and `InCombatLockdown`. It ships a `_Camelot` TOC and a plain fallback TOC, both at
16001.

## License

MIT, see [LICENSE](LICENSE).

## Support

If you enjoy this addon, you can [buy me a coffee](https://buymeacoffee.com/tgaarden) ☕
