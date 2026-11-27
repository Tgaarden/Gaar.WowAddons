# Gaar.WowAddons

A suite of World of Warcraft addons, sharing one look and one settings hub. Built for
**Classic Era (1.15.x)**, laid out so other game versions can be added without a second copy
of the code.

## The addons

| Addon | What it does | Slash |
|---|---|---|
| `GaarOptions` | One "Gaar" entry in the AddOns options holding every addon's settings, plus the minimap button | `/gaar` |
| `GaarBags` | One-bag window in the OneBag3 mould, with a per-character inventory cache | `/gaarbags` |
| `GaarCast` | Cast bars for player, target and pet, anchored to Blizzard's own positions | `/gaarcast` |
| `GaarCC` | Cooldown count text on anything with a cooldown swipe | `/gaarcc` |
| `GaarPlates` | Nameplates with per-plate threat, debuffs and cast bars | `/gaarplates` |
| `GaarThreat` | Group threat meter, pets included | `/gaarthreat` |
| `GaarMeter` | Damage, healing and interrupt meter with a per-spell breakdown | `/gaarmeter` |
| `GaarFrames` | Class-coloured unit frames with value and percent text (Era only - see the API notes) | `/gaarframes` |
| `GaarSpellBook` | A searchable spell book window | `/spellbook` |
| `GaarLooter` | Loot library: every roll, who took part, who won | `/gaarlooter` |
| `GaarVanguard` | Captures your characters and their loot account-wide and exports them for the Vanguard website (export-only); minimap button for one-click copy | `/gaarvanguard` |
| `GaarMap` | Scales the world map, fades it while you move, squares the minimap | `/gaarmap` |
| `GaarUI` | The suite in one switch: tick it and the client pulls in every module | `/gaarui` |
| `GaarProbe` | Diagnostic, not part of the suite: reports what an unknown client's API actually has | `/gaarprobe` |
| `GaarBagsForever` | Not part of the suite, Forever only, needs `GaarForever`: makes the native Combined Backpack movable and adds a Clean Up Bags button left of its search box that does exactly what Forever's own button does (`C_Container.SortBags`), with an optional Reverse that mirrors the whole Combined Backpack order afterwards; item tooltips show how many of the item each of your characters on the realm has (bags, bank, equipped, mail), hovering the bag gold shows every character's gold, and Alt-click locks an item so a merchant cannot buy it (padlock overlay) | `/gbf` |
| `GaarQuestsForever` | Not part of the suite, Forever only, needs `GaarForever`: orders the Quests section of the native objective tracker by quest level (completed quests at the bottom, top or by level) and shows only the first N (default 10); auto-watch (default on) watches the lowest quests that fit the tracker's Edit Mode height and un-watches the rest; an optional dungeon filter (1.10) watches only the current dungeon's or raid's quests while inside; with GaarGpsForever loaded, "Set GPS target" in the tracker's quest menu | `/gqf`, minimap button |
| `GaarMapsForever` | Not part of the suite, Forever only, needs `GaarForever`: move the world map (Map & Quest Log) by its title bar, scale the whole window from a corner grip (50-150%), fade it while you move; lock and reset; the maximized map is left alone | `/gmf` |
| `GaarPlatesForever` | Not part of the suite, Forever only, needs `GaarForever`: cleaner enemy nameplates drawn over Blizzard's (flat health bar with reaction/class/health/solid colour, threat colours and percent, cast bar with time left and a grey look for uninterruptible casts, your debuffs with countdown, target scale and dimming); friendly plates left to Blizzard by default; changes no CVars | `/gpf` |
| `GaarCastbarsForever` | Not part of the suite, Forever only, needs `GaarForever`: own cast bars for player, target, focus and pet (icon, name, timer, spark, cast target, latency safe-zone on the player bar) and a swing timer under the player bar (main hand, off hand, ranged); drag and resize them, or let them follow Blizzard's bars (Edit Mode); lock, test bars and reset. A port of `GaarCast` - use one of the two | `/gcf` |
| `GaarFramesForever` | Not part of the suite, Forever only, needs `GaarForever`: X-Perl-style unit frames of its own (secure buttons) for player, target, target of target, focus, pet and party1-4: name bar, 2D/3D portrait, health and power with `cur/max  NN%`, heal prediction and absorbs (with overheal past the bar and the HoT of a Regrowth you are casting), a druid mana bar in forms, class/reaction/low-health colours, target buffs and debuffs with combo points, your own buffs under the player frame, party auras and range fade, raid/leader/combat/resting icons and a threat border; drag, per-frame scale, lock, reset and test mode; optionally follows Blizzard's frames placed in Edit Mode. Blizzard's frames are switched off the oUF way (never restyled), out of combat only | `/gff` |
| `GaarGpsForever` | Not part of the suite, Forever only, needs `GaarForever`: one TomTom-style waypoint (`/way x y`, `/way <zone> x y`, or Alt + left-click (Option on Mac) the world map) with a movable arrow showing distance and time to get there, a world map pin and a minimap pin; also sets Blizzard's own user waypoint; clears itself on arrival; routes you to your corpse while you are a ghost and brings the old waypoint back after resurrection; leaves `/way` to TomTom when TomTom is loaded; since 1.4 remembers the herbs, ore and chests you gather (account-wide), alerts near a known spot of a tracked kind, and `/ggps gather` (next, hover) points the arrow at the nearest one, the next one on arrival, or a node hovered on the minimap; since 1.6 hovering a flight path on the map shows its direct flight connections (lines and tooltip, `/ggps routes on\|off`) | `/ggps`, `/way` |
| `GaarWindowsForever` | Not part of the suite, Forever only, needs `GaarForever`: makes Blizzard's own windows movable by their title bar (Character, Spellbook & Talents, Professions, Collections, Group Finder, Social, Guild & Communities, Achievements, Encounter Journal, Merchant, Gossip, Quest, Mail, Bank, Auction House, Class Trainer, Loot, Dressing Room, Macros, Settings, AddOn List, Inspect, Trade, Game Menu and more); Ctrl + mouse wheel scales a window (50-150%); position and scale remembered per window and put back after Blizzard's panel layout; on/off and reset per window; world map and bags left to their own addons | `/gwf` |
| `GaarFishingForever` | Not part of the suite, Forever only, needs `GaarForever`: double right-click in the world casts Fishing while a fishing pole is equipped (a secure button and a short-lived `BUTTON2` override binding, armed after the first click so a single right-click still loots the bobber); Shift + double right-click swaps the pole in and out; since 1.3, while the line is out the same double right-click anywhere reels in (`INTERACTTARGET` + soft interact CVars, put back after), plus a **Cast / Reel** key binding; never in combat; works with `ActionButtonUseKeyDown` on or off; on/off and a 0.2-0.8 s double-click window; an optional Fishing 1-300 route (current step from your skill, world map and minimap pins, GaarGpsForever's arrow); since 1.4 a movable session panel (casts, catches, catches/hour, skill gained, loot) and an optional loud splash mode (sound CVars while the line is out, put back after) | `/gfish` |
| `GaarBuffsForever` | Not part of the suite, Forever only, needs `GaarForever`, druids, paladins, shamans, priests and mages (picked by class): a box at the top centre lists who lacks your buffs. Druid: Mark of the Wild (Gift of the Wild counts) in your party or raid, Thorns on you and your tank (role, raid main tank, or one set by hand), low Gift of the Wild / Rebirth reagents. Paladin: a blessing per class (Might for Warrior/Rogue/Hunter, Wisdom for the rest, editable; a fallback when another paladin's blessing is already there; no Salvation for the tank), No aura, Righteous Fury while you tank, low Symbol of Kings. Shaman: a weapon without an imbue (click casts the chosen imbue, auto = Windfury > Flametongue > Rockbiter), Lightning Shield, low Ankh / totem items / Fish Oil / Shiny Fish Scales. Priest: Power Word: Fortitude (Prayer of Fortitude counts), low Sacred Candles once Prayer is known. Mage: Arcane Intellect on members with mana (no warriors or rogues; Arcane Brilliance counts), low Arcane Powder once Brilliance is known. Druids, shamans, priests, paladins and mages get a dispel panel, by class (druid: curse left-click, poison right-click; shaman: poison left, disease right; priest: magic left, disease right; paladin: Cleanse, else Purify, on either click; mage: Remove Lesser Curse on either click), shown once the dispel spell is known; in combat the game itself draws a member's dispellable debuff icon on the strip (Blizzard aura container). Each name is a secure button, click to cast the buff on that member (a low-level member gets the highest rank that lands on them; right-click: Gift of the Wild, the Greater Blessing, Prayer of Fortitude or Arcane Brilliance); buffs with less than 2 minutes left get an "Expiring" row out of combat (`/gbuff expire 0-5`); dead, offline and unseen members are skipped, out-of-range ones left out (`/gbuff range on` dims them instead), unreadable (secret) auras never warned about; hidden in combat; movable | `/gbuff` |
| `GaarMerchantForever` | Not part of the suite, Forever only, needs `GaarForever`: at a merchant sells your grey items (3 every 0.2 s, never an item locked in GaarBagsForever) and repairs your gear, optionally with guild funds first and an ask-first popup; one summary line; every part switchable | `/gmerch` |
| `GaarTooltipsForever` | Not part of the suite, Forever only, needs `GaarForever`: extra lines in item tooltips (vendor price for the stack, item level, item and spell IDs, a compare against what you wear) and unit tooltips (target, guild rank, health); every line switchable | `/gtip` |
| `GaarMailForever` | Not part of the suite, Forever only, needs `GaarForever`: mailbox helpers - Open All (Shift: money only, COD never paid, stops on full bags), an optional delete of empty system mail, a recipient list with your own characters and recent names, Alt-click to attach (Ctrl+Alt: up to 12 stacks), a new-mail notice | `/gmail` |
| `GaarXPForever` | Not part of the suite, Forever only, needs `GaarForever`: a movable XP panel (rested, XP per hour, time to level, kills or quests to level), text on the XP bar, time played per level on level-up, quest XP in tooltips | `/gxp` |
| `GaarChatForever` | Not part of the suite, Forever only, needs `GaarForever`: chat tweaks, each switchable - short channel names, class-coloured names, timestamps, clickable URLs, a copy-chat window, a whisper sound, sticky channels, arrow keys without Alt, a scrolling feed of whispers, group chat and mentions | `/gchat` |
| `GaarBarsForever` | Not part of the suite, Forever only, needs `GaarForever`: clearer action buttons - red out of range, blue without mana, big cooldown numbers, short hotkey labels, macro names on or off, a spellbook tab of the spells missing from your bars; `/gbars off` gives the buttons back exactly as Blizzard draws them | `/gbars` |
| `GaarLootForever` | Not part of the suite, Forever only, needs `GaarForever`: on a group loot roll, a small number on the Need, Greed and Pass buttons counting how many in the group chose each for that roll; hover a button to see who ("Need: Elex, Bob"); a small movable summary panel of the last rolls (who chose what, the numbers rolled, the winner, auto-hides 60 s after) for after the roll frame has closed. Read from the loot chat lines (the client's own `LOOT_ROLL_*` strings, so any locale) and the loot history where the client fills it; counts, names and summary each switchable; `/glf test` previews it | `/glf` |
| `GaarGroupForever` | Not part of the suite, Forever only, needs `GaarForever`: a small movable bar that shows only while you are in a party (hidden solo and in a raid): Tank / DPS / Healer buttons that set your group role (`UnitSetRole`) and remember it per character, and leader shortcuts for a ready check, a role check and a pull countdown (left-click 5 s, right-click 3 / 5 / 10 s; the game's own countdown, else typed to party chat on your click); tooltips on every button; lockable, scalable | `/ggf` |
| `GaarProfessionsForever` | Not part of the suite, Forever only, needs `GaarForever`: a +/- button right of the profession window's Filter button that collapses or expands every recipe category at once (Blizzard's own collapse calls on the retail `ProfessionsFrame`, `CollapseTradeSkillSubClass(0)` on a classic `TradeSkillFrame`), and a "Have Part of Materials" checkbox in the Filter menu: only recipes where you have at least 1 of at least one reagent in your bags; `/gprof status` says which profession window the client has | `/gprof` |
| `GaarForever` | The hub of the Gaar...Forever family (named `BetterGaarForever` before 3.0), not part of the suite, Forever only, and a required dependency of all nineteen: the shared library (global `GaarForever`), one minimap button whose menu holds every addon's options, and their pages under **Esc > Options > AddOns > Gaar Forever** - an overview plus one page per installed addon, with a short intro, generated from the same options as the menu. Since 3.1 also a chat line per addon after an update saying what changed (`/gf news`), per-character settings for addons on the library's settings (`/gf profile`), since 3.2.1 every addon's settings exported and imported as one string (`/gf export all`, `/gf import`), and an API self-test to copy and send (`/gf selftest`). No feature code of its own | `/gf`, minimap button, Options |

The `Gaar...Forever` addons were formerly **Better...Forever** (renamed in hub 3.2), folders
included (`addons/GaarForever`, `addons/GaarBagsForever`, ...). Settings from the old Better...Forever names were migrated up to hub 3.2.91 by a small
"settings bridge" folder per addon (a TOC listing the old saved variables, no code) that shipped in
the same zip; those folders are no longer in the repo or the downloads (3.2.91). The migration code
(`GaarForever.Migrate`, see [the hub's README](addons/GaarForever/README.md#coming-from-betterforever))
stays and simply finds nothing. The old globals
(`BetterForever`, `Better...ForeverAPI`) stay as aliases. Each
addon's command is now a g-command (`/gf`, `/gbf`, `/gqf`, ...; `/glf` for GaarLootForever, as
`/gloot` is GaarLooter's); the old `/b...` commands (`/bf`, `/bbf`, `/bqf`, `/bloot`, ...) still work.
On CurseForge: https://www.curseforge.com/wow/addons/gaarforever (the hub) and
`gaar<name>forever` for the others, e.g. https://www.curseforge.com/wow/addons/gaarbagsforever.

## GaarBags: sorting and junk

- **Clean up** (the three-bar button, `/gbags sort`): the built-in stack-and-pack cleanup by
  default. Ticking "Use the client's own bag sorting" under Gaar -> Bags switches it to the
  client's own `C_Container.SortBags` where the client has one (retail, Forever), and sorts the
  character bank too when the bank is open. It is off by default on retail and Forever until it has
  been tested there. The window's refresh is coalesced and held back while a sort runs - rebuilding
  on every bag event during a sort is what most likely hung retail 12.1 before, not the sort.
- **Sell junk** (the coin button left of clean-up, only while a merchant is open, `/gbags junk`):
  the client's own junk sale where it has one, otherwise grey items with a sell value, one at a
  time. Asks first by default; the merchant's buyback only holds the last 12 items.
- **Per-bag flags**: on clients that have them, right-clicking a bag on the bag bar offers
  "Ignore on clean up" and "Don't sell junk from this bag". These, and "sort right to left" / "new
  items left to right" in the settings, are the client's own settings, shared with its native bag
  window, not copies kept by GaarBags.

## GaarBagsForever: the native bags on Forever

A standalone addon for Forever's own **Combined Backpack** - no Gaar addon or library needed, and
not listed in `GaarUI`. It makes the frame movable (drag the title bar, or Alt-drag an empty part
of it), saves the position in `GaarBagsForeverDB` and re-applies it whenever Blizzard re-anchors
the bags. It also adds a **Clean Up Bags** button left of the search box, because Forever's native
one ends up hidden under the bag slot icons. A left-click does exactly what Forever's own button
does: the sort sound and `C_Container.SortBags()`. A right-click toggles **Reverse** (off by
default): with it on, in the Combined Backpack only, the addon waits for Blizzard's sort to
settle and then mirrors the whole visible order, so the last slot on screen trades places with
the first, and so on. The sort-direction setting is never read or changed. Since 1.7 it also
keeps a compact record per character (bags, bank, equipped, mail and gold, by item id, per realm)
and adds a line per character on the realm to every item tooltip, plus a gold-per-character
tooltip on the bag window's money; the bank and mail are read only while they are open.
Since 1.9, Alt + left-click an item in the bags to lock it (per item, per character): it gets a
padlock and a merchant cannot buy it (right-click, drag-and-drop and Sell Junk are blocked, and a
sale that slips through is bought back once).
`/gbf` for help, `/gbf reset`, `/gbf lock`, `/gbf unlock`, `/gbf native hide|show`,
`/gbf reverse [on|off]`, `/gbf autosort [on|off]`, `/gbf counts on|off`, `/gbf gold`,
`/gbf forget <name>`, `/gbf locked`, `/gbf unlockall yes`, `/gbf stop` and `/gbf status`. It ships only a `_Camelot` TOC and a
plain fallback TOC, both at 16001. Details in
[`addons/GaarBagsForever/README.md`](addons/GaarBagsForever/README.md).

## GaarQuestsForever: the native quest tracker on Forever

A standalone addon for the **Quests** section of Forever's own objective tracker - no Gaar addon
or library needed, and not listed in `GaarUI`. It orders the tracked quests by quest level,
lowest first, ties by title, with quests that are ready to turn in at the bottom (or `top`, or
sorted by `level`), and shows only the first N of them (default 10). After Blizzard's own layout,
out of combat, the quest blocks are re-anchored in the sorted order with Blizzard's own spacing.
Since 1.9 **auto-watch** (default on) manages which quests are watched: the lowest quests (in that
order) that fit the tracker's height are watched and the rest un-watched, so Blizzard draws
exactly those; the tracker's height is always Blizzard's (Edit Mode) and is never changed.
`/gqf autowatch off` hands the watch list back untouched. Since 1.10 an optional **dungeon
filter** (`/gqf dungeon on`, default off) watches only the current dungeon's or raid's quests while
inside one, and falls back to the normal behaviour when none match. Since 1.13 `/gqf sort zone`
groups quests by their quest-log zone: your current zone first, the others A-Z, unknown zone last,
level order inside each (`/gqf sort level|distance|zone`).
During combat the section is Blizzard's own. Other tracker sections are not touched. `/gqf` for
help, `/gqf max <n>|all`, `/gqf completed top|level|bottom`, `/gqf autowatch on|off`, `/gqf dungeon on|off`, `/gqf on|off`,
`/gqf minimap [reset]` and `/gqf status`; a minimap button opens the same options as a menu. Since 1.6, with
GaarGpsForever 1.1 loaded, the tracker's right-click menu for a quest has **Set GPS target**
after Focus: the waypoint goes to Blizzard's point for the quest (next waypoint, else its POI or
turn-in point), titled with the quest's name, and is greyed out when there is none. It ships a
`_Camelot` TOC and a plain fallback TOC, both at 16001. Details, including the taint analysis, in
[`addons/GaarQuestsForever/README.md`](addons/GaarQuestsForever/README.md).

## GaarMapsForever: the world map on Forever

A standalone addon for Forever's own world map window, **Map & Quest Log** - no Gaar addon or
library needed, and not listed in `GaarUI`. Drag the title bar to move it; the position is saved
account-wide in `GaarMapsForeverDB` and put back every time the map opens or Blizzard's panel
layout re-anchors it. Drag the grip in the bottom-right corner to scale the whole window (map and
quest log together, 50-150%) with the top-left corner held in place. While you move, the map fades
to 35% opacity (on by default, adjustable), as in GaarMap. Lock turns moving and resizing off,
reset goes back to Blizzard's position and 100%. Nothing is moved or scaled in combat (it waits
for combat to end), and the maximized map is left to Blizzard. No Blizzard function or table is
replaced. `/gmf` for help, `/gmf lock|unlock`, `/gmf reset`, `/gmf scale <50-150>`, `/gmf fade
on|off`, `/gmf fade <percent>` and `/gmf status`. It ships a `_Camelot` TOC and a plain fallback
TOC, both at 16001. Use it or GaarMap, not both. Details in
[`addons/GaarMapsForever/README.md`](addons/GaarMapsForever/README.md).

## GaarPlatesForever: nameplates on Forever

A standalone port of `GaarPlates` - no Gaar addon or library needed, and not listed in `GaarUI`.
It draws its own overlay on every enemy nameplate (the frame `C_NamePlate.GetNamePlateForUnit`
returns) and hides Blizzard's art there, through `HookScript("OnShow")` and `Hide()` only; a plate
it stops styling gets Blizzard's art back. A flat health bar (120x12 by default) coloured by
reaction, class, health or one solid colour, grey when someone else tagged the mob, an execute
tint at 20% or less; purple with a ring when you hold aggro, amber when your threat is high, threat
percent on the bar; name, level, health text and the unit's target; a cast bar with icon, spell
name and time left, grey for uninterruptible casts; up to 8 of your own debuffs with stacks and a
countdown, drawn by the client's own `AuraContainer` so they show in combat too; your target scaled to 115% and every other plate dimmed to 55%. Friendly plates are
Blizzard's unless `/gpf friendly on`. **No CVars are changed**, so stacking, overlap and plate size
stay as they were. Hidden (secret) values are guarded at the read, and each part of a plate's update
runs in `pcall`: the first refusal switches only that part off for the session, with one message.
`/gpf` for help, `/gpf status`, `/gpf on|off`, `/gpf color reaction|class|health|solid`,
`/gpf health off|percent|current|both`, `/gpf size <w> <h>`, `/gpf friendly|threat|threattext|execute|
debuffs|native|tot|combo|dim|targetscale|marks on|off`, `/gpf debug` and `/gpf reset`. Use it or `GaarPlates`, not both (it warns
once at login when both are loaded). It ships a `_Camelot` TOC and a plain fallback TOC, both at
16001. Details in [`addons/GaarPlatesForever/README.md`](addons/GaarPlatesForever/README.md).

## GaarCastbarsForever: cast bars on Forever

A standalone addon - no Gaar addon or library needed, and not listed in `GaarUI`. It is a port of
`GaarCast` to the Gaar...Forever conventions and draws its own cast bars for the player, target
and focus (on by default; focus only where the client has one) and the pet (off by default): spell
icon with a 1px border (steel with a small shield when the cast cannot be interrupted), name,
`remain / total` or `remain` timer, spark, the cast's target under the bar and a latency
safe-zone on the player bar. Since 1.1 thin swing bars hang under the player bar (main hand, off
hand while dual-wielding, ranged while Auto Shot / Shoot repeats), driven by the client's own
`PLAYER_SWING` event since Forever has no combat log reader. Yellow cast, green channel, grey uninterruptible, a red flash on a
failed or interrupted cast and a 0.3 s fade when it finishes. Each bar has its own position by
default: drag to move, the bottom-right grip to resize, saved per bar account-wide in
`GaarCastbarsForeverDB`. **Follow Blizzard (Edit Mode)** anchors each bar to Blizzard's own bar
instead; dragging turns that off again. Blizzard's cast bar is hidden only for the units it
replaces, with `HookScript("OnShow")` and nothing else, and every cast timing and frame geometry is
checked for secret values first; a bar the client refuses is switched off with one line in chat.
`/gcf` for help, `/gcf status`, `lock`, `unlock`, `test`, `reset`, `follow on|off`,
`bar <unit> on|off`, `latency on|off`, `texture blizzard|smooth|flat`, `font 9|11|13` and
`timer total|remain`, `swing on|off`, `swing offhand on|off`, `swing ranged on|off`. It exports `GaarCastbarsForeverAPI` with the same shape as the others, and
the GaarForever hub has a Castbars row for it. It ships a `_Camelot` TOC and a plain fallback TOC,
both at 16001. Use it or GaarCast, not both (it warns once at login if GaarCast is loaded).
Details in [`addons/GaarCastbarsForever/README.md`](addons/GaarCastbarsForever/README.md).

## GaarGpsForever: one waypoint on Forever

A standalone addon - no Gaar addon or library needed, and not listed in `GaarUI` - for one
TomTom-style waypoint. `/way x y`, `/way x,y` or `/way <zone> x y` (0-100, x first; the zone is
matched case-insensitively, exact or by a unique prefix, and an ambiguous name lists the
candidates) sets it, `/way clear` removes it, and Alt + left-click (Option on Mac) on the world map sets it at
the point under the cursor on the map shown, worked out from the canvas's own scale so it is right
at any GaarMapsForever scale. A new waypoint replaces the old. A movable arrow (lock, reset,
on/off) points at it from `C_Map.GetPlayerMapPosition` and `GetPlayerFacing()`, with the distance
in yards from `C_Map.GetWorldPosFromMapPos` and, under it, the time to get there at the speed you
are closing in over the last 3 seconds (`--` while standing still or moving away). A pin on the
world map (also converted to the continent map) and one on the minimap (minimap zoom and
`rotateMinimap` respected, on the edge when out of range). Blizzard's own user waypoint is set
too where the client allows it and cleared with ours while it is still ours. Within 10 yards it
clears itself with "Arrived at ...". Saved account-wide in `GaarGpsForeverDB`. With TomTom
loaded `/way` stays TomTom's and `/ggps way x y` does the job (one note at login). No Blizzard
function or table is written; every read is guarded for errors and secret values, and each part
switches itself off after its first error with one line in chat. Since 1.1, while you are a
ghost the waypoint is your corpse (`C_DeathInfo.GetCorpseMapPosition`, titled "Corpse", followed
across maps, never cleared on arrival), and after resurrection the waypoint you had comes back; one
you set while dead is the one kept (`/ggps corpse on|off`, default on). Since 1.4 (`Gather.lua`)
it remembers the gathering nodes you gather (`UNIT_SPELLCAST_SENT` names the node; stored per map,
account-wide, merged within 15 yards), gives a sound and a line near a known spot of a kind
minimap tracking has on, and `/ggps gather`, `/ggps gather next` and `/ggps gather hover` (a node
hovered on the minimap, placed from the cursor's offset and the minimap's view radius) set the
arrow to one, moving on to the next on arrival. `/ggps` for help, `status`,
`arrow on|off`, `lock`, `unlock`, `reset`, `clear`, `corpse` and `way`. It exports `GaarGpsForeverAPI`
(with `SetWaypoint`, `ClearWaypoint` and `GetWaypoint` since 1.1),
and the GaarForever hub has a GPS row for it. It ships a `_Camelot` TOC and a plain
fallback TOC, both at 16001. Details in
[`addons/GaarGpsForever/README.md`](addons/GaarGpsForever/README.md).

## GaarFramesForever: unit frames on Forever

A standalone addon - no Gaar addon or library needed, and not listed in `GaarUI` - that draws
X-Perl-style unit frames of its own for the player, target, target of target, focus, pet and
party1-4 (no raid, no XP bar): a name bar with level and class icon or Elite / Rare / Boss tag,
a 2D portrait (3D model as an option), health and power bars with `cur/max  NN%` text on a dark
see-through backdrop. Class colour for players, reaction colour for NPCs, grey when tapped by
someone else, orange under 35% and red under 20% health. The target gets combo points, a row of
buffs and one of debuffs (your own larger); party frames get small auras and fade out of range;
raid target, leader, combat and resting icons and a threat border. Left-click targets,
right-click opens Blizzard's unit menu. Drag when unlocked, scale per frame (0.6-1.5), lock,
reset and a test mode with made-up data (party without a group). Since 1.1 an option (off by
default) has player, target, focus and party follow Blizzard's own frames placed in Edit Mode -
pet and target of target move along - without anchoring to them: Blizzard's frames are given back
while Edit Mode is open and their place is copied when it closes. 1.1 also draws target and party
auras through Blizzard's aura container where the client has one, since this client refuses
addon aura reads in combat, and hides the power bar of a unit without power. 1.2.2 adds heal
prediction and absorbs on the health bars (`/gff healpred on|off`), the player's mana under a
druid form's power, and Blizzard buff-frame aura times under the icons (`45`, `9m`, `1h`). It exists because `GaarFrames`
cannot run on Forever: restyling Blizzard's unit frames taints them. So the frames are
`SecureUnitButtonTemplate` buttons of its own (attributes set once, `RegisterUnitWatch` for
show/hide, every change to them out of combat, queued to `PLAYER_REGEN_ENABLED` otherwise), and
Blizzard's frames are switched off the oUF way - `UnregisterAllEvents`, `Hide`, re-parented to a
hidden frame - out of combat, back only after `/reload`. Hidden (secret) values go straight to the
bars; the text uses the client's secret-safe helpers where it has them, otherwise the bars stand
alone, and every part of an update runs in `pcall` and switches itself off after its first
refusal with one line in chat. `/gff` for help, `status`, `lock`, `unlock`, `test`, `reset`,
`scale <frame> <0.6-1.5>`, `frame <frame> on|off`, `editmode on|off`, `portrait 2d|3d`, `text`,
`lowhp`, `classcolor`, `healpred`, `hotpred`, `hotcast`, `overheal` and `marks on|off`,
`overheal cap <0.1-1>`. 1.5.0 draws heals past the maximum as an overheal segment past the
health bar's right edge, and shows the HoT of a Regrowth you are casting from the cast's start. It exports `GaarFramesForeverAPI`, and the GaarForever hub has
a Frames row for it. It ships a `_Camelot` TOC and a plain fallback TOC, both at 16001. Use it
instead of GaarFrames, X-Perl, ShadowedUnitFrames or PitBull4, not next to them (it warns once at
login). Details in [`addons/GaarFramesForever/README.md`](addons/GaarFramesForever/README.md).

## GaarWindowsForever: Blizzard's windows on Forever

A standalone addon for Forever's own windows - no Gaar addon or library needed, and not part of
the suite. Drag a window by its title bar to move it (an invisible handle over the title strip,
or the top edge, clear of the close and maximize buttons, so clicks and item drags inside still
work), and hold Ctrl and turn the mouse wheel over it to scale it from 50% to 150%. Position and
scale are saved per window, account-wide, in `GaarWindowsForeverDB`, and put back every time the
window opens and every time Blizzard's panel manager (`ShowUIPanel`, `UpdateUIPanelPositions`)
re-anchors it; it is followed with `hooksecurefunc` and `HookScript` only, no Blizzard function
or table is written. A protected window is never moved or scaled in combat (that waits for
`PLAYER_REGEN_ENABLED`); the others can be moved any time. Load-on-demand windows (Collections,
Achievements, Auction House, Macros, ...) are picked up at `ADDON_LOADED`, and a window the client
does not have is listed as such. The world map is left to GaarMapsForever, the bags to
GaarBagsForever and Blizzard's bag layout, and Edit Mode frames to Edit Mode. Every window can
be switched off on its own, which gives it back to Blizzard. `/gwf` for help, `list`,
`on <name>`, `off <name>`, `reset <name>|all` and `status`. It exports `GaarWindowsForeverAPI`,
and the GaarForever hub has a Windows row for it with a checkbox per window. It ships a `_Camelot`
TOC and a plain fallback TOC, both at 16001. Details in
[`addons/GaarWindowsForever/README.md`](addons/GaarWindowsForever/README.md).

## GaarFishingForever: double right-click fishing on Forever

A standalone addon - no Gaar addon or library needed, and not part of the suite. Double
right-click in the world casts Fishing, but only while a fishing pole is in the main-hand slot
and only out of combat; nothing happens while the cursor holds an item. An addon cannot cast by
itself, so it owns a `SecureActionButtonTemplate` button and, for a moment, binds the right
mouse button to it (`SetOverrideBindingClick(..., "BUTTON2", ...)`): the first right-click goes
to the game as always (the bobber is looted), its release arms the binding for the rest of the
double-click window (0.4 s by default, 0.2-0.8), the second right press clicks the button, and
the binding is cleared once the button is up again, when the window runs out, or at
`PLAYER_REGEN_DISABLED`. The button is registered for the one click direction
`ActionButtonUseKeyDown` acts on, so it casts once with the CVar on or off. Fishing is resolved
out of combat at login and on `SPELLS_CHANGED` (highest known rank of 7620/7731/7732/18248, cast
by localized name). Shift + double right-click (or `/gfish swap`) swaps the fishing pole in and
out: it remembers the main and off hand per character, equips the best pole in the bags, and puts
the weapons back the next time; never in combat or while casting, and it never casts Fishing.
Since 1.3, while the Fishing channel runs (the line is out), the same double right-click anywhere
reels in instead of casting again: the second press is bound to `INTERACTTARGET` (Interact With
Target) and the soft interact CVars (`SoftTargetInteract` 3, `SoftTargetInteractRange` 30,
`SoftTargetInteractArc` 2, `SoftTargetInteractRangeIsHard` 0) are set only while the line is out
and out of combat, the previous values put back at the channel stop, combat, logout or next login
(`/gfish reel on|off`, on by default). A **Cast / Reel** key binding (Esc > Options > Keybindings >
GaarFishingForever) casts with one key and reels in with the same key while the line is out.
Since 1.2, `/gfish route on` (off by default, per character) adds a Fishing 1-300 route for
your faction: the current step from your Fishing skill and cap (trainers and the Expert book come
up when the skill is capped, Nat Pagle at 225/225), its spots or NPC as pins on the world map and
minimap with a tooltip, and GaarGpsForever's arrow on the nearest spot when the step changes;
`/gfish route`, `next`, `prev`, `list` and `gear`. Pool coordinates come from the GatherMate2 data
dumps, NPCs and quests from warcraft.wiki.gg and method.gg (credits in the addon's README).
Since 1.4, a small movable session panel (while a pole is equipped or the line is out) shows the
session time, casts, catches, catches per hour, Fishing skill and what it gained, and the six most
looted items (all of them in its tooltip), counted only from fishing loot (`IsFishingLoot()`);
`/gfish stats` toggles it, `/gfish stats reset` resets it, and it resets by itself after 30
minutes without fishing. The client has no bite signal, so the bite alert is `/gfish splash on`
(off by default): while the line is out, sound effects and master volume go to full and music and
ambience to 0, put back exactly like the reel CVars (never changed in combat).
`/gfish` for help, `on`, `off`, `window <0.2-0.8>`, `reel on|off`, `splash on|off`, `stats`, `swap`, `route` and `status`. It exports
`GaarFishingForeverAPI`, and the GaarForever hub has a Fishing row for it. It ships a `_Camelot`
TOC and a plain fallback TOC, both at 16001. Details in
[`addons/GaarFishingForever/README.md`](addons/GaarFishingForever/README.md).

## GaarBuffsForever: a druid's, a paladin's, a shaman's, a priest's and a mage's buff check on Forever

A standalone addon - no Gaar addon or library needed, and not part of the suite - that does
something only for a Druid, a Paladin, a Shaman, a Priest or a Mage, picked by class (any other class leaves it idle). A box at the top centre
of the screen, shown only while something is missing, lists who lacks your buffs. The class parts
are modules (`Druid.lua`, `Paladin.lua`, `Shaman.lua`, `PriestMage.lua`, and `Dispel.lua`, the dispel panel of druids, shamans, priests, paladins and mages) sharing the box, rows, aura scan and tank detection in
`GaarBuffsForever.lua`. The tank is every member with the `TANK` role, else in a raid every
main tank, else the one set by hand with `/gbuff tank` (your target); you can be the tank.

- **Druid**: who lacks Mark of the Wild (Gift of the Wild counts): you, and in a party or raid
  every member; whether you or the tank lack Thorns; low reagents for the highest rank you know of
  Gift of the Wild (Wild Berries / Wild Thornroot, below 10) and Rebirth (Maple, Stranglethorn,
  Ashwood, Hornbeam or Ironwood Seed, below 2). Right-click on a Mark of the Wild row casts Gift
  of the Wild in a group. **Dispel panel** (1.2): its own movable frame below the box. Out of
  combat it lists who has a curse or poison you can remove (`Curse` purple, `Poison` green); in
  combat it is a fixed strip of one secure button per member (you and your party in a row, a
  raid as one column per subgroup, up to 40), dimmed with nothing to remove and lit purple, green
  or split when there is. Left-click casts Remove Curse, right-click Abolish Poison (Cure Poison
  until Abolish is known). In combat the debuff is found without reading a secret: a plain read
  where the client allows it, else `C_UnitAuras.GetUnitAuraInstanceIDs` with the
  `HARMFUL|RAID_PLAYER_DISPELLABLE` filter and `GetAuraDispelTypeColor` through a colour curve,
  else a filtered read; if the client answers none of them the strip stays clickable without
  glow, and `/gbuff status` says which one answered.
- **Paladin**: every member should have the blessing assigned to their class (Might for Warrior,
  Rogue and Hunter, Wisdom for the rest; `/gbuff bless <class> <type>` or the hub to change).
  Covered when that type is on from anyone (any rank, normal or Greater); when it is there from
  another paladin and nothing of yours is on, the row asks for the fallback: Kings (if known),
  then the other of Might/Wisdom, then Light. The tank never gets Salvation. Right-click casts
  the Greater Blessing (the whole class) when known. Also "No aura" (read from the shapeshift
  bar; the row casts the aura you used last), Righteous Fury while you are the tank or say you
  are tanking (`/gbuff tanking on`), and low Symbol of Kings (below 20) once you know a Greater
  Blessing.
- **Shaman** (1.3): only you are checked. A `No weapon imbue:` row per hand holding a weapon
  without a temporary enchant (`GetWeaponEnchantInfo`; the off hand only when it holds a weapon);
  the row casts the imbue chosen per character (`/gbuff imbue auto|rockbiter|flametongue|frostbrand|windfury`,
  auto = Windfury, else Flametongue, else Rockbiter). Lightning Shield when you lack it. Low
  reagents once the spell is known: Ankh (Reincarnation, below 2), Earth/Fire/Water/Air Totem
  (any totem of that element, warned only when missing), Shiny Fish Scales (Water Breathing) and
  Fish Oil (Water Walking), below 5. The same **dispel panel** as the druid's, with left-click
  Cure Poison (green) and right-click Cure Disease (ochre).
- **Dispel panel for priests, paladins and mages** (1.4): the same panel, auto by class, shown
  once the dispel spell is known. Priest: left-click Dispel Magic (blue), right-click Abolish
  Disease, else Cure Disease (ochre). Paladin: Cleanse (poison, disease, magic), else Purify
  (poison, disease), on either click; the glow shows the kind(s) found. Mage: Remove Lesser Curse
  (purple) on either click. Warriors, rogues, hunters and
  warlocks get nothing (Felhunter Devour Magic left out on purpose).
- **Priest and mage buff check** (1.5): the priest's box lists who lacks Power Word: Fortitude
  (Prayer of Fortitude counts), the mage's who lacks Arcane Intellect, only members whose class
  uses mana (Arcane Brilliance counts). Right-click casts Prayer of Fortitude / Arcane Brilliance
  in a group once known; low Sacred Candles / Arcane Powder (below 10) once the group version is
  known. `/gbuff fort on|off`, `/gbuff ai on|off`, `/gbuff reagents prayer|brilliance <n>`.

Each name is a `SecureActionButtonTemplate` button (`type` spell, the highest known rank by name,
or since 1.6 a lower rank by spell ID for a member too low for it, `unit` the member). Since 1.6
an "Expiring ..." section lists your buffs with less than N minutes left (`/gbuff expire 0-5`,
default 2), and in combat the dispel strip shows the game's own icon of a dispellable debuff
(Blizzard aura container) although the addon cannot read auras then. Dead, offline and unseen members are skipped, out-of-range ones left out (`/gbuff range on` dims them instead), and a
member whose auras are secret counts as unknown, never as missing. The box is hidden in combat (a
`[combat] hide` state driver; nothing is scanned or rebuilt until `PLAYER_REGEN_ENABLED`).
Unlock, Alt + drag, reset; position saved. `/gbuff` for help, `on`, `off`, `group`, `sound`,
`reagents`, `tank`, `unlock`, `lock`, `reset`, `test` and `status`; a druid adds `motw`,
`thorns`, `tank on|off` and `dispel` (`on|off`, `curse|poison on|off`, `unlock|lock|reset`), a paladin `bless`, `aura`, `fury` and `tanking`, a shaman `imbue`, `shield` and `dispel` (`poison|disease on|off`), a paladin also `dispel` (`poison|disease|magic on|off`), a priest `fort` and `dispel` (`magic|disease on|off`) and a mage `ai` and `dispel` (`curse on|off`). It exports
`GaarBuffsForeverAPI`, and the GaarForever hub has a Buffs row for it with the options for your
class. It ships a `_Camelot` TOC and a plain fallback TOC, both at 16001. Details in
[`addons/GaarBuffsForever/README.md`](addons/GaarBuffsForever/README.md).

## GaarMerchantForever, GaarTooltipsForever, GaarMailForever, GaarXPForever, GaarChatForever, GaarBarsForever, GaarLootForever, GaarGroupForever, GaarProfessionsForever

Nine smaller Forever-only addons, each with one master switch and a switch per feature
(`/<cmd> <feature> on|off`), an API table for the hub and a `_Camelot` TOC plus a plain fallback
TOC, both at 16001:

- **GaarMerchantForever** (`/gmerch`): at a merchant, sells grey items and repairs; respects
  GaarBagsForever's item locks; optional guild repair and ask-first popup; `/gmerch sell`.
  [`addons/GaarMerchantForever/README.md`](addons/GaarMerchantForever/README.md)
- **GaarTooltipsForever** (`/gtip`): vendor price, item level, IDs and a compare in item
  tooltips; target, guild rank and health in unit tooltips.
  [`addons/GaarTooltipsForever/README.md`](addons/GaarTooltipsForever/README.md)
- **GaarMailForever** (`/gmail`): Open All, delete empty, recipient list, Alt-click to attach,
  new-mail notice. [`addons/GaarMailForever/README.md`](addons/GaarMailForever/README.md)
- **GaarXPForever** (`/gxp`): XP panel, XP bar text, level log, quest XP.
  [`addons/GaarXPForever/README.md`](addons/GaarXPForever/README.md)
- **GaarChatForever** (`/gchat`): short channels, class colours, timestamps, URL copy, copy chat
  (`/gchat copy [n]`), whisper sound, sticky channels, arrow keys, a scrolling chat feed of
  whispers, group chat and mentions (`/gchat feed`).
  [`addons/GaarChatForever/README.md`](addons/GaarChatForever/README.md)
- **GaarBarsForever** (`/gbars`): range and mana colours, cooldown numbers, short hotkeys, macro
  names, low-rank rings and a spellbook tab of the spells missing from your bars. [`addons/GaarBarsForever/README.md`](addons/GaarBarsForever/README.md)
- **GaarLootForever** (`/glf`): how many chose Need, Greed and Pass, as a number on each button
  of a group loot roll, and who, in the button's tooltip; a movable summary of the last rolls with
  the numbers rolled and the winner; `/glf test` for a preview.
  [`addons/GaarLootForever/README.md`](addons/GaarLootForever/README.md)
- **GaarGroupForever** (`/ggf`): a party-only bar with Tank / DPS / Healer role buttons and leader
  shortcuts (ready check, role check, pull countdown). [`addons/GaarGroupForever/README.md`](addons/GaarGroupForever/README.md)
- **GaarProfessionsForever** (`/gprof`): a +/- button beside the profession window's Filter button
  that collapses or expands every recipe category, and a "Have Part of Materials" filter.
  [`addons/GaarProfessionsForever/README.md`](addons/GaarProfessionsForever/README.md)

## GaarForever: the hub of all nineteen

Named `BetterGaarForever` until 2.8. Not part of the Gaar suite and not listed in `GaarUI`, but
**every Gaar...Forever addon requires it**: each lists `## Dependencies: GaarForever` in both
TOCs, so the client loads none of them without the `GaarForever` folder. It carries no feature
code of its own; the addons keep their logic, their saved variables and their slash commands
(`/gbf`, `/gqf`, `/gmf`, `/gcf`, `/gpf`, `/ggps`, `/gff`, `/gwf`, `/gfish`, `/gbuff`, `/gmerch`,
`/gtip`, `/gmail`, `/gxp`, `/gchat`, `/gbars`, `/glf`). What it adds:

- **The shared library**, global `GaarForever`: secret-safe value helpers (`Plain`, `Num`,
  `Str`, `Bool`, `IsSecret`), guarded calls (`API`, `Call`, `Method`), formatters (`TimeShort`,
  `Clock`, `Coins`, `ShortNumber`), the shared menu renderer, and `NewAddon(name, opts)`: an object
  with `:Print`, `:InitDB`, an option registry (`:Toggle`, `:Choice`, `:Slider`, `:Button`) that
  gives slash commands, menu entries and an Options page from one list, `:Slash`, a per-feature
  `:Run` latch and `:API`. The addons do not use it yet; moving them over is the next step.
- **Options pages** under **Esc > Options > AddOns > Gaar Forever**: an overview (each addon's
  version and state, the hub's minimap switch, a pointer to `/gf`) and one page per installed
  addon, with a short intro at the top (the API's new `Intro()` field) and the options generated
  from the addon's own `MenuEntries()` - checkboxes, dropdowns for radio groups, buttons, section
  headers for submenus - so the page and the minimap menu always match. `/gf options [name]`.
- **One minimap button** whose menu has a submenu per addon: **Bags**, **Quests**, **Maps**,
  **Castbars**, **Plates**, **GPS**, **Frames**, **Windows**, **Fishing**, **Buffs**,
  **Merchant**, **Tooltips**, **Mail**, **XP**, **Chat**, **Bars**, **Loot**, **Group** and **Professions**. While it is loaded,
  `GaarQuestsForever`'s own minimap button is hidden for the session.

Each addon exports a small global API (`GaarBagsForeverAPI` ... `GaarLootForeverAPI`:
`version`, `StatusLine()`, `MenuEntries()`, `AddMenuEntries(root)`, `SetMinimapHidden(hidden)`,
`Intro()`). An addon that is not installed shows as a disabled `– not installed` line. `/gf` for
help (`/bgf` still works), `/gf status` for each addon's version and state, `/gf minimap [reset]`.
Coming from BetterGaarForever: delete the old folder; the addons' settings are kept, only the
hub's minimap button position resets. Details, and the library's API for addon authors, in
[`addons/GaarForever/README.md`](addons/GaarForever/README.md).

## One switch, eleven standalone addons

`GaarUI` carries no features. Its TOC lists every module under `## Dependencies`, so ticking
that one entry in the AddOns list brings the whole suite up, and `/gaarui` reports what
actually loaded and at which version.

Each module is still its own addon and runs alone. That is why they are separate folders
rather than files inside one addon: you can install only `GaarBags` and it works, and a fault
in one cannot stop the rest from loading. The cost is eleven entries in the AddOns list, which
is what `GaarUI` and the shared `Gaar [ ]` naming are there to tidy up.

## Porting to a client nobody has yet

`GaarProbe` exists because every port so far has cost the same round of "it loads but does
nothing", and every one was settled by asking an artefact rather than remembering. It asks
that question up front. Drop the folder into an unknown client, log in, and it reports:

- every global the suite touches, per module, with its type or `MISSING`
- the `C_*` namespaces, listing both the names this suite uses and the retail replacements it
  would have to move to, so the report doubles as a migration target
- named frames against the modern field paths that replaced them (`PlayerFrameHealthBar`
  against `PlayerFrame.healthbar`)
- **return shapes**, which are the failures that do not announce themselves: a function that
  still exists, is called the old way, and answers with one table instead of three values.
  `C_Container.GetContainerItemInfo` and `C_Minimap.GetTrackingInfo` have both done exactly
  that here, and neither raised an error.

The report is written to `SavedVariables/GaarProbe.lua`, so it can be read off disk after
logging out rather than copied out of a scrollback. `/gaarprobe copy` opens a copyable box
if the file is not to hand.

It carries a plain `GaarProbe.toc` with no flavour suffix on purpose: that is the file a
client falls back to for any flavour it has no specific TOC for, which is the only way to
reach a branch whose suffix is not published yet.

## Layout

```
addons/          one folder per addon, exactly as the game expects it
tools/           link, unlink and check scripts
docs/            notes worth keeping, chiefly the Classic Era API findings
```

## Several game versions, one copy of the code

Every addon carries `_Vanilla`, `_Mainline` and `_Camelot` TOCs: Classic Era 1.15.x at interface
11509, retail 12.1.x at 120100, and WoW Forever at 16001. `GaarProbe` also keeps a plain fallback
TOC for a client whose suffix is not known yet.

Each addon carries a TOC file per game flavour rather than a folder per flavour:

```
addons/GaarBags/GaarBags_Vanilla.toc     Classic Era
addons/GaarBags/GaarBags_Mainline.toc    retail, when it is targeted
addons/GaarBags/GaarBags_Camelot.toc     WoW Forever
```

The client picks `Name_<Flavor>.toc` itself and falls back to `Name.toc`. Blizzard's suffixes
are `_Vanilla`, `_TBC`, `_Wrath`, `_Cata`, `_Mists` and `_Mainline`, and Forever uses `_Camelot`.
This is what Plater, Questie, AtlasLoot and ThreatClassic2 all do, and the reason is worth
restating: one copy of the Lua that asks the client what it supports beats two copies that have
to be kept in step.

Forever reports its own project id, `WOW_PROJECT_CAMELOT` (18), not retail's
`WOW_PROJECT_MAINLINE` (1), so the few checks that mean "retail-shaped client" accept both. See
`docs/forever-client-findings.md`.

The code already works that way. It checks for `C_Container`, `BackdropTemplate`,
`SetResizeBounds` and the rest before using them, so most of a retail port is adding a TOC and
testing, not branching the source.

## Working on them

Link the addons into a client once:

```sh
tools/link.sh _classic_era_
```

That points the client's `AddOns` folder at this repo, so editing here and typing `/reload`
in game is the whole loop. `tools/unlink.sh _classic_era_` reverses it.

Before committing:

```sh
tools/check.sh
```

It parses every file with LuaJIT (Lua 5.1, the same dialect the game runs), checks that every
TOC lists exactly the Lua files its addon ships, and then reads the bytecode to catch locals used
above their own declaration. That second check matters: Lua
resolves such a name as a global, which is `nil` at runtime, and a plain syntax check sees
nothing wrong. It has caught several real bugs in this codebase.

## What is not here

SavedVariables. Those live in `WTF/` and belong to the character, not the code.

## Releasing an addon (GitHub + CurseForge)

`tools/release.sh <AddonName>` (the new folder name, e.g. `GaarBagsForever`; tags are now
`GaarXForever-v<version>`) reads `## Version` from `addons/<AddonName>/<AddonName>.toc` and
pushes the tag `<AddonName>-v<version>` (from an up-to-date `main`). That triggers
`.github/workflows/release-addon.yml`, which zips the addon folder, creates a GitHub Release and
uploads to CurseForge (`workflow_dispatch` with an `addon` input does the same without a tag).
Bump `## Version` in both TOCs and merge first; the tag must match the TOC version.

- CurseForge project IDs: `tools/curseforge-projects.json` (`null` = skip CurseForge, GitHub
  release is still made). Seeded from the `X-Curse-Project-ID` lines in the TOCs.
- Game version(s): `tools/curseforge-config.json` (`gameVersionIds`, or `gameVersionNames`
  resolved via the API). The upload fails and lists candidate IDs if they can't be resolved.
- CurseForge relations (required GaarForever, optional extras) come from `relations` in `tools/curseforge-config.json`.
- Secret `CF_API_KEY` (repo Settings > Secrets > Actions): API token from
  https://wow.curseforge.com/account/api-tokens. Without it the CurseForge step is skipped.
- The changelog is the tag message (release.sh fills it from the addon's commits).
- **Settings bridges** (removed in hub 3.2.91): the zips used to carry the old `Better...Forever`
  folder next to each new one. They are gone; each zip holds only its own `Gaar...Forever/` folder.

## Support

If you enjoy these addons, you can [buy me a coffee](https://buymeacoffee.com/tgaarden) ☕
