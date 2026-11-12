# BetterFishingForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). Double
right-click in the 3D world casts Fishing while a fishing pole is equipped, and Shift + double
right-click swaps the fishing pole in and out. Since 1.2 it also carries an optional **Fishing
1-300 route**: the current step from your Fishing skill, pins on the world map and minimap, and
BetterGpsForever's arrow on the nearest spot. It needs no other addon or library (the arrow needs
BetterGpsForever), and it is not part of the Gaar suite.

## What it does

- **Double right-click casts Fishing.** Right-click twice in the world (on the water, say)
  within the double-click window and Fishing is cast. Double right-click the bobber and it is
  looted by the first click and cast again by the second.
- **Only with a fishing pole.** The main-hand slot (16) must hold a fishing pole (item class 2,
  subclass 20). Without one, right-clicks are not touched at all.
- **A single right-click is left alone.** The bobber is looted, an NPC is talked to, the camera
  turns, exactly as without the addon.
- **Never in combat.** Nothing is armed in combat, and an armed binding is cleared at
  `PLAYER_REGEN_DISABLED`, before combat locks it.
- **Not while the cursor holds an item**, and never for clicks on the UI (those do not reach
  `WorldFrame`).
- **Window.** 0.4 s from the first right press to the second by default, 0.2 to 0.8 s.
- **Fishing is found for you.** At login and whenever the spellbook changes (`SPELLS_CHANGED`,
  `LEARNED_SPELL_IN_TAB` where the client has it), out of combat: the highest rank the character
  knows of 7620, 7731, 7732 and 18248 (and 131474, retail's one Fishing spell), else the spellbook
  entry under the localized name of 7620. The button casts it by localized name (the highest
  known rank), or by ID when the client gives no name.

- **Shift + double right-click swaps the pole** (1.1). See [Pole swap](#pole-swap).
- **Fishing 1-300 route** (1.2, off until `/bfish route on`). See
  [Fishing route](#fishing-route-1-300).

Settings are saved account-wide in `BetterFishingForeverDB`: `enabled` (default on) and
`dblClick` (the window in seconds, default 0.4). The pole swap's memory is saved per character in
`BetterFishingForeverCharDB.swap`, the route's state in `BetterFishingForeverCharDB.route` (on/off,
skipped steps, a step picked by hand, and the waypoint the route set).

## Pole swap

**Shift + double right-click** in the world (the second press with Shift held, within the
double-click window of the first) or **`/bfish swap`**:

- **No pole in the main hand:** the main hand (slot 16) and off hand (slot 17) are remembered
  (itemID + link, per character, so they survive `/reload`), and the best fishing pole in the
  bags is equipped. Best = the highest classic fishing bonus among the known poles: Arcanite
  Fishing Pole 19970 (+35), Nat Pagle's Extreme Angler FC-5000 19022 (+25), Big Iron Fishing
  Pole 6367 (+20), Darkwood Fishing Pole 6366 (+15), Strong Fishing Pole 6365 (+5), Blump Family
  Fishing Pole 12225 (+3), Fishing Pole 6256 (0). Any other item of class 2 / subclass 20 counts
  as a pole with bonus 0; on a tie the first one in the bags wins. Chat: `equipped <pole>`.
- **A pole in the main hand:** the remembered weapons go back on, found in the bags by the exact
  link first, else by itemID. A remembered two-hander puts back only the main hand. The off hand
  is equipped once the main-hand swap has landed (at most 3 s), so the two never race. Chat:
  `weapons back: <links>`, and `not in your bags: <links>` for anything missing. With nothing
  remembered it says so.
- **It never casts Fishing** and never leaves an override binding behind. A press with Shift held
  never starts the Fishing sequence; Shift pressed while the binding is armed (after a plain first
  click) clears it at once; and a Shift click that still reaches the secure button does nothing
  (`shift-type*` is set to an action type that does not exist) and swaps from its `PreClick`.
  **Shift + single right-click** is untouched.
- **Not in combat** (`can't swap weapons in combat`), **not while casting or channelling**,
  Fishing included (`stop fishing first`), and not with an item on the cursor. The gesture follows
  `/bfish on|off`; `/bfish swap` always works.
- **Equip path:** `C_Item.EquipItemByName`, else `EquipItemByName`, else
  `PickupContainerItem` + `EquipCursorItem`, called directly. These are not protected out of
  combat on classic or on the retail engine, and the gesture calls them inside the second press's
  own handler (a hardware event) anyway, so no secure macro button is needed. If the client ever
  blocks the call, `ADDON_ACTION_BLOCKED` / `ADDON_ACTION_FORBIDDEN` is caught, printed and shown
  in `/bfish status`.

## Fishing route (1-300)

`/bfish route on` (per character, off by default) shows where to go next on the way from 1 to
300. The route data is in `Route.lua`, the logic in `RouteGuide.lua`; both reach the main file
through the addon namespace, not a global.

- **Your skill and cap.** Classic first: `GetNumSkillLines` / `GetSkillLineInfo`, scanned for the
  line named like spell 7620 (Fishing, localized), giving the rank and the max rank (the cap:
  75 Apprentice, 150 Journeyman, 225 Expert, 300 Artisan). Where that finds nothing, the retail
  `GetProfessions` / `GetProfessionInfo`. No Fishing at all reads as 0/0. A collapsed
  *Secondary Skills* header in the skill window hides the line; `/bfish status` says so, and the
  route then keeps the step it had.
- **Your faction.** Only the steps for `UnitFactionGroup("player")` and the ones for both.
- **The current step** is the first step in route order that is not done and whose range holds
  your skill:
  - a **trainer, the Expert book and the Artisan quest** (with its four fish) are done once the
    cap reaches the rank they give, and only come up while the skill sits at the cap: 0/0 ->
    Apprentice trainer, 75/75 -> Journeyman trainer, 150/150 -> the Expert book, 225/225 -> Nat
    Pagle;
  - a **fish** step is done once the skill reaches its upper end;
  - an **optional** vendor or quest step (a pole and lures, Nightcrawlers, the FC-5000 pole quest)
    is done once you skip it with `/bfish route next` (saved), or once the skill is past it.
- **`/bfish route next | prev`** moves by hand (next on an optional step skips it for good). A step
  picked by hand holds until the automatic step changes (a skill-up past it, a new rank). The
  Artisan quest needs four fish: `/bfish route next` after each one.
- **Auto-advance** on `SKILL_LINES_CHANGED`, `CHAT_MSG_SKILL`, `SPELLS_CHANGED` and
  `LEARNED_SPELL_IN_TAB` (where the client has it): `Fishing route: <step>` in chat when the step
  changes.
- **Pins.** The current step's fishing spots (fish icon) or its NPC (book for a trainer, `!` for a
  quest, coin for a vendor) on the world map, when that map or the continent holding it is shown,
  and on the minimap within its radius. The tooltip has the step, the NPC, the note and the
  coordinate with its source. They are drawn the way BetterGpsForever draws its pins: our own
  frames on the map canvas and the minimap, placed by normalised coordinates; no library.
- **GPS arrow.** With BetterGpsForever loaded, `BetterGpsForeverAPI.SetWaypoint(mapID, x, y,
  title)` points its arrow at the step's nearest spot (on your continent; else the first one),
  titled with the step. Only when the step changes and at `/bfish route on`: a waypoint you set
  yourself stays until the step changes. `/bfish route off` clears the waypoint only while it is
  still the route's. Without BetterGpsForever: pins only, and `/bfish status` says so.

### The route in short

Alliance:

| Skill | Step |
|---|---|
| 0 | Apprentice trainer: Lee Brown, Goldshire, Elwynn Forest (47.6, 62.2) |
| 1-75 | Buy a pole and Shiny Baubles (optional); fish any water in Elwynn Forest |
| 75 | Journeyman trainer: Arnold Leland, Stormwind (55.0, 69.6); Nightcrawlers (optional) |
| 75-150 | Westfall, north coast |
| 150 | Expert book: Old Man Heming, Booty Bay (27.4, 77.0) |
| 150-225 | Pole quest 'Snapjaws, Lad!' (optional, unconfirmed); Dustwallow Marsh (or Desolace) |
| 225 | Artisan: Nat Pagle (Dustwallow 58.6, 60.0), the four fish, hand in |
| 225-260 | Dustwallow Marsh |
| 260-300 | Feralas, around Feathermoon (or Tanaris) |

Horde:

| Skill | Step |
|---|---|
| 0 | Apprentice trainer: Lau'Tiki, Durotar (53.2, 81.6) |
| 1-75 | Buy a pole and Shiny Baubles (optional); fish any water in Durotar |
| 75 | Journeyman trainer: Lumak, Orgrimmar (69.8, 29.6); Nightcrawlers (optional) |
| 75-150 | The Barrens: the Wailing Caverns pools or Ratchet |
| 150 | Expert book: Old Man Heming, Booty Bay (27.4, 77.0) |
| 150-225 | Pole quest 'Snapjaws, Mon!', Katoom, Revantusk Village (optional); Dustwallow Marsh (or Desolace) |
| 225 | Artisan: Nat Pagle (Dustwallow 58.6, 60.0), the four fish, hand in |
| 225-260 | Dustwallow Marsh |
| 260-300 | The Hinterlands, Revantusk Village (or Tanaris) |

The four Artisan fish: Feralas Ahi (Verdantis River, Feralas), Misty Reed Mahi Mahi (Misty Reed
Strand, Swamp of Sorrows), Sar'theris Striker (Sar'theris Strand, Desolace) and Savage Coast Blue
Sailfin (Savage Coast, Stranglethorn Vale). `/bfish route list` prints every step with its range,
`/bfish route gear` the poles and lures worth having.

Some facts differ between sources and are marked in the notes: whether the FC-5000 quest exists
for the Alliance, the character level for Artisan (guides say 35), and the Stormwind trainer's
position. Elwynn Forest and Durotar have no pool data, so their pin is the trainer: fish any water
nearby.

## The click sequence

An addon cannot cast a spell itself; only a secure button clicked by a real key or mouse press
can. The addon owns one `SecureActionButtonTemplate` button (`type` = `spell`, `spell` =
Fishing) and binds the right mouse button to it for a moment with
`SetOverrideBindingClick(owner, true, "BUTTON2", "BetterFishingForeverButton")`. In the world the
right mouse button is itself a binding (`TURNORACTION`: turn the camera while held, interact on
release), so the override takes the press instead, and the press clicks the button.

1. **First right press** (`WorldFrame` `OnMouseDown`, followed with `HookScript`). If the addon
   is on, you are out of combat, a pole is equipped, Fishing is known and the cursor is empty,
   the time is noted and the release is watched (`IsMouseButtonDown("RightButton")`, polled by
   an `OnUpdate` that runs only while something is pending). Nothing is bound yet: this click
   goes to `TURNORACTION` as always.
2. **First release** within the window (a click, not a camera drag): the override is armed for
   what is left of the window.
3. **Second right press** within the window goes to the binding, which clicks the button on the
   press (`down = true`) and on the release (`down = false`). The secure template acts on one of
   the two: the press when the `ActionButtonUseKeyDown` CVar is 1, the release when it is 0. The
   button is registered for that one direction only (`RegisterForClicks("AnyDown")` or
   `("AnyUp")`, read from the CVar each time it is armed), so it can never cast twice.
4. **Disarm.** `PostClick` marks the cast; the binding is cleared (`ClearOverrideBindings`) once
   the right button is up again, so the second release never falls through to `TURNORACTION`.
   Without a second press it is cleared when the window runs out; a held press is waited for at
   most 2 s.

Why not arm on the second press and catch its release, the way older fishing addons do: with
`ActionButtonUseKeyDown` = 1, which retail ships with, the template acts on the press only, so a
click that reaches the button on the release casts nothing. Arming after the first release works
with both settings and never takes the first click away from the bobber.

## Limitations

- **Combat:** no cast from a double-click in combat, by design and because bindings are locked
  then. If a binding ever could not be cleared because combat had already started, it is cleared
  at `PLAYER_REGEN_ENABLED`.
- **The first click** always does what a right-click does: loot, interact, or nothing on open
  water. Only the second one casts.
- **After a right-click**, for the rest of the window, the next right press casts instead of
  turning the camera. That is the double-click; set a shorter window if it gets in the way.
- **A client without `IsMouseButtonDown`** gets the older way (arm on the second press, catch its
  release, `AnyUp`), which casts only with `ActionButtonUseKeyDown` = 0. `/bfish status` says so.

## Commands

| Command | Does |
|---|---|
| `/bfish` or `/bfish help` | Help |
| `/bfish on`, `/bfish off` | Switch double right-click fishing on or off |
| `/bfish window <0.2-0.8>` | Seconds between the two right presses (default 0.4) |
| `/bfish swap` | Swap the fishing pole in or out, the same as Shift + double right-click (out of combat) |
| `/bfish route on`, `/bfish route off` | Switch the Fishing 1-300 route (pins and GPS arrow) on or off, per character; off by default |
| `/bfish route` | Your Fishing skill, the current step with its NPC and note, and the next step |
| `/bfish route next`, `/bfish route prev` | Move one step by hand; next on an optional vendor or quest step skips it for good |
| `/bfish route list` | Every step for your faction with its range; the current one marked, done ones say so |
| `/bfish route gear` | Poles and lures worth having on the way |
| `/bfish status` | Version, enabled, the window, fishing pole equipped yes/no, the resolved Fishing spell, whether the override is armed, `ActionButtonUseKeyDown`, the remembered weapons and the equip path (`swap: remembered <links> / none`), the route (on/off, skill and where it was read, faction, step, GPS available) and the last error caught |

## With BetterGaarForever (optional)

[BetterGaarForever](../BetterGaarForever/README.md) is an optional hub: one minimap button whose
menu has a **Fishing** submenu with **Double right-click casts Fishing** (the same as `/bfish
on|off`), **Double-click window** (0.2 to 0.8 s, the same as `/bfish window`) and **Fishing
route** (the same as `/bfish route on|off`). Both go through
the same functions as the slash command. This addon has no minimap button or menu of its own, so
nothing here changes with or without the hub.

The hub talks to this addon only through `BetterFishingForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `on · 0.40 s · pole equipped`, plus `· route 152/225` while the route is on |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, submenu }`, `{ divider }`), for a menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide. It is there so every addon the hub knows has the same API |

## How it stays out of the way

- Blizzard code is only followed, never replaced: one `HookScript` on `WorldFrame`'s
  `OnMouseDown`. No Blizzard function or table is written.
- The binding is an override on the addon's own frame, set only out of combat and only for the
  moment between the two clicks; the right mouse button's own binding is never changed.
- Attributes and click registration are set only on the addon's own secure button, only out of
  combat; a spellbook change in combat waits for `PLAYER_REGEN_ENABLED`.
- Every client API is checked with `type(...) == "function"` before use, every handler runs in
  `pcall` (the last error is kept for `/bfish status`), and a secret value is treated as no value,
  never compared or tested.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Only `enabled` and `dblClick`
  are kept account-wide, and only `swap` and `route` per character.
- The route's pins are plain frames of our own on the map canvas and the minimap; its only hook is
  `hooksecurefunc` on `WorldMapFrame.OnMapChanged`.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source), `SecureTemplates.lua`):
`SecureActionButtonTemplate`, `WorldFrame`, `SetOverrideBindingClick`, `ClearOverrideBindings`,
`IsMouseButtonDown`, `IsShiftKeyDown`, `GetCursorInfo`, `GetInventoryItemID`, `GetInventoryItemLink`,
`IsInventoryItemLocked`, `C_Container.*` (or the old container globals), `C_Item.EquipItemByName`
(or `EquipItemByName`), `EquipCursorItem`, `UnitCastingInfo`, `UnitChannelInfo`, `C_Item.GetItemInfoInstant` (or
`GetItemInfoInstant`), `C_Spell.GetSpellInfo` (or `GetSpellInfo`), `C_SpellBook.IsSpellKnown`,
`IsPlayerSpell`, `IsSpellKnown`, `C_CVar.GetCVarBool("ActionButtonUseKeyDown")` and
`InCombatLockdown`; for the route `GetNumSkillLines`, `GetSkillLineInfo`, `GetProfessions`,
`GetProfessionInfo`, `UnitFactionGroup`, `C_Map.GetWorldPosFromMapPos`, `C_Map.GetMapPosFromWorldPos`,
`C_Map.GetBestMapForUnit`, `C_Map.GetPlayerMapPosition`, `WorldMapFrame` (`GetCanvas`, `GetMapID`,
`OnMapChanged`), `Minimap`, `C_Minimap.GetViewRadius`, `GetPlayerFacing`, `GetMinimapShape` and
`GameTooltip`. It ships a `_Camelot` TOC and a plain fallback TOC, both at 16001.

## Credits

- **Fishing pool coordinates** are derived from the GatherMate2 data dumps:
  [Thurdi/GatherMate2_Data_Classic](https://github.com/Thurdi/GatherMate2_Data_Classic) (Classic
  Era maps, marked `GM2 Classic` in `Route.lua`) and
  [Nevcairiel/GatherMate2_Data](https://github.com/Nevcairiel/GatherMate2_Data) (retail maps,
  `GM2 retail`, used only where the Classic data has nothing), by kagaro, Xinhuan, Nevcairiel and
  Thurdi. Neither repository states a license, so no file or code of theirs is shipped here: only
  about 30 hand-picked positions in the game world, kept as facts with their source.
- **NPCs, quests and the Artisan fish** from [warcraft.wiki.gg](https://warcraft.wiki.gg/) and
  [method.gg](https://www.method.gg/wow-forever/fishing-in-wow-forever-leveling-guide-fishing-items-trainers),
  cross-checked with [Warcraft Tavern](https://warcrafttavern.com/wow-classic/guides/fishing-1-300),
  [wow-professions.com](https://www.wow-professions.com/classic/fishing-leveling-guide-classic-wow)
  and [noobtoboss](https://noobtoboss.com/wow-classic-fishing-leveling-guide/).
- **Classic Era uiMapIDs** checked against `WoWPro_ZoneData_Vanilla.lua` from
  [WoW-Pro-Guides](https://github.com/Ludovicus-Maior/WoW-Pro-Guides).

## License

MIT, see [LICENSE](LICENSE). The credits above cover where the route's facts come from.
