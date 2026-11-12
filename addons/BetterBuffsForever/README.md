# BetterBuffsForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001), for druids. A
box at the top centre of the screen lists who lacks **Mark of the Wild** (Gift of the Wild counts),
whether you or your tank lack **Thorns**, and whether your **Gift of the Wild or Rebirth reagents**
are running low. Click a name to buff that member. It needs no other addon or library, and it is
not part of the Gaar suite.

## What it does

- **Druids only.** On any other class the addon stays idle: no scans, no box. `/bbuff status`
  says `not a druid: the addon is idle on this character.`
- **Mark of the Wild.** Warns when you lack it and, in a party or raid, lists every member who
  lacks it. Gift of the Wild counts as having it.
- **Thorns.** Warns when you lack it, and when the group's tank lacks it. The tank is, in this
  order:
  1. every member `UnitGroupRolesAssigned(unit)` calls `"TANK"`;
  2. else, in a raid, every main tank (`GetPartyAssignment("MAINTANK", unit)`);
  3. else the tank you set by hand: target a group member and type `/bbuff tank` (saved per
     character, `/bbuff tank clear` removes it; also in the hub menu);
  4. else there is no tank check.
- **Only spells you know.** A spell the character has not learned is not checked (no Thorns
  warning before level 6).
- **Low reagents** (on by default). A `Low reagents: Wild Thornroot 3/10` line when the bags
  hold fewer than the threshold of the reagent for the highest rank you know:

  | Spell | Rank | Reagent | Default threshold |
  |---|---|---|---|
  | Gift of the Wild | 1 (21849) | Wild Berries (17021) | 10 |
  | Gift of the Wild | 2 (21850) | Wild Thornroot (17026) | 10 |
  | Rebirth | 1 (20484) | Maple Seed (17034) | 2 |
  | Rebirth | 2 (20739) | Stranglethorn Seed (17035) | 2 |
  | Rebirth | 3 (20742) | Ashwood Seed (17036) | 2 |
  | Rebirth | 4 (20747) | Hornbeam Seed (17037) | 2 |
  | Rebirth | 5 (20748) | Ironwood Seed (17038) | 2 |

  A spell you do not know is skipped entirely. Counted in the bags only (`C_Item.GetItemCount`,
  else `GetItemCount`, bank not included), updated on `BAG_UPDATE_DELAYED`. The line is not
  clickable.
- **The box.** At the top centre, shown only while something is missing: a `Missing Mark of the
  Wild:` section and a `Missing Thorns:` section (the spell names are the client's own), one row
  per member with the spell's icon and a class-coloured name, `(you)` for yourself and `(tank)`
  for a tank, then the low-reagent lines. It hides again when everything is covered.
- **Who is never warned about:** dead or ghost members, offline members, and members the client
  does not see (`UnitIsVisible`, too far away). Members out of the spell's range are shown dimmed
  with `(out of range)`; they stay clickable, the cast just fails.
- **Unknown is not missing.** A member whose buffs cannot be read (a secret aura, a refused read)
  counts as unknown and is never warned about. `/bbuff status` gives the count.

## Click to buff

Every row is a `SecureActionButtonTemplate` button of the addon's own: `type` = `spell`, `spell` =
the localized name of the highest rank you know (or its spell ID when the client gives no name),
`unit` = that member's unit token (`player`, `party1`, `raid7`, ...).

- **Left-click** casts the row's spell (Mark of the Wild or Thorns) on that member.
- **Right-click** on a Mark of the Wild row casts **Gift of the Wild** when you know it and are in
  a group (it needs its reagent). Otherwise right-click does what left-click does.
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
| `/bbuff` or `/bbuff help` | Help |
| `/bbuff on`, `/bbuff off` | Switch the addon on or off |
| `/bbuff motw [on\|off]` | The Mark of the Wild check (no argument toggles) |
| `/bbuff thorns [on\|off]` | Warn when you lack Thorns |
| `/bbuff tank` (or `tank set`) | Your current target, a group member, becomes the tank set by hand |
| `/bbuff tank clear` | Clear the tank set by hand |
| `/bbuff tank on\|off` | Warn when the tank lacks Thorns |
| `/bbuff group [on\|off]` | List group members (off: only you are checked for Mark of the Wild) |
| `/bbuff sound [on\|off]` | A short sound when something new goes missing (off by default) |
| `/bbuff reagents [on\|off]` | The low-reagent warning (on by default) |
| `/bbuff reagents gotw <n>`, `/bbuff reagents rebirth <n>` | Warn below n Gift of the Wild reagents (default 10) or Rebirth seeds (default 2), 0-200 |
| `/bbuff unlock`, `/bbuff lock`, `/bbuff reset` | Move the box, stop moving it, put it back at the top centre |
| `/bbuff test` | Show the box with test rows (they cast nothing); again to hide them |
| `/bbuff status` | Version, druid or idle, the options, the resolved spells (Mark of the Wild, Gift of the Wild, Thorns, Rebirth), the reagents with count and threshold, the group, the tank and where it came from, the last check (members checked, missing, unknown), the box (shown, lock, position, how combat hides it), which aura, role and main-tank APIs this client has, and the last error |

## With BetterGaarForever (optional)

[BetterGaarForever](../BetterGaarForever/README.md) is an optional hub: one minimap button whose
menu has a **Buffs** submenu with **Enabled**, **Mark of the Wild check**, **Thorns on you**,
**Thorns on the tank**, **List group members**, **Sound when something goes missing**, **Low
reagent warning**, **Gift of the Wild reagent warning below** (0/5/10/20/40), **Rebirth reagent
warning below** (0/1/2/3/5), **Set tank: current target**, **Clear tank** (while one is set),
**Lock box**, **Test box** and **Reset position**. They go through the same functions as the
slash command. This addon has no minimap button or menu of its own, so nothing here changes with
or without the hub.

The hub talks to this addon only through `BetterBuffsForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `on · 2 missing`, `on · all buffed`, `on · hidden in combat` or `idle (not a druid)` |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, submenu }`, `{ divider }`), for a menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide. It is there so every addon the hub knows has the same API |

## How it reads buffs

- Spells, all classic ranks: Mark of the Wild 1126, 5232, 6756, 5234, 8907, 9884, 9885; Gift of
  the Wild 21849, 21850; Thorns 467, 782, 1075, 8914, 9756, 9910; Rebirth 20484, 20739, 20742,
  20747, 20748 (reagents only). The highest rank known (`C_SpellBook.IsSpellKnown`,
  `IsPlayerSpell`, `IsSpellKnown`) is resolved at login and on `SPELLS_CHANGED`, out of combat.
- Buffs are read by index, `C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")` (`UnitBuff` or
  `UnitAura` on an older client), one `pcall` per read, asking
  `C_Secrets.ShouldUnitAuraIndexBeSecret` first, as BetterFramesForever does. A buff is matched by
  spell ID, else by the localized name of any rank. A read that is refused or secret, or a buff
  with neither a readable ID nor name, makes the member unknown for that check.
- Updates come from `UNIT_AURA` (player, party and raid units only), `GROUP_ROSTER_UPDATE`,
  `PLAYER_ENTERING_WORLD`, `PLAYER_REGEN_ENABLED`, `SPELLS_CHANGED`, `BAG_UPDATE_DELAYED`, and
  `PLAYER_ROLES_ASSIGNED` / `UNIT_CONNECTION` where the client has them; at most 4 a second. In a
  group the check also runs every 1.5 s, for range, death and visibility, which have no cheap
  event.
- Range is `C_Spell.IsSpellInRange` (else `IsSpellInRange`, else `UnitInRange`). A secret answer
  goes straight to `SetAlphaFromBoolean` where the client has it, never tested.

## How it stays out of the way

- Blizzard code is only followed, never replaced: no Blizzard function or table is written and no
  Blizzard frame is touched.
- Attributes and click registration are set only on the addon's own secure buttons, only out of
  combat; a spellbook change in combat waits for `PLAYER_REGEN_ENABLED`.
- Every client API is checked with `type(...) == "function"` before use, every handler runs in
  `pcall` (the last error is kept for `/bbuff status`), and a secret value is treated as no value,
  never compared or tested.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Account-wide
  (`BetterBuffsForeverDB`): `enabled`, `motw`, `thorns`, `thornsTank`, `group`, `sound`,
  `reagents`, `gotwMin`, `rebirthMin`, `locked` and `pos`. Per character
  (`BetterBuffsForeverCharDB`): only `tank` (`{ guid, name }`).

## Names it relies on

From Blizzard's retail FrameXML and API documentation, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source)): `SecureActionButtonTemplate`,
`RegisterStateDriver`, `C_UnitAuras.GetAuraDataByIndex`, `C_Secrets.ShouldUnitAuraIndexBeSecret`,
`C_Spell.GetSpellInfo`, `C_Spell.IsSpellInRange`, `C_Item.GetItemCount`,
`C_Item.GetItemNameByID`, `UnitGroupRolesAssigned`, `GetPartyAssignment`, `UnitIsVisible`,
`UnitIsConnected`, `UnitIsDeadOrGhost`, `IsInGroup`, `IsInRaid` and `InCombatLockdown`. It ships a
`_Camelot` TOC and a plain fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).
