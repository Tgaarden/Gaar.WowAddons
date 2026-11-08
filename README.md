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
| `BetterBagsForever` | Standalone, not part of the suite, Forever only: makes the native Combined Backpack movable and adds a Clean Up Bags button left of its search box that does exactly what Forever's own button does (`C_Container.SortBags`), with an optional Reverse that mirrors the whole Combined Backpack order afterwards; item tooltips show how many of the item each of your characters on the realm has (bags, bank, equipped, mail), and hovering the bag gold shows every character's gold | `/bbf` |
| `BetterQuestsForever` | Standalone, not part of the suite, Forever only: orders the Quests section of the native objective tracker by quest level (completed quests at the bottom, top or by level) and shows only the first N (default 10); every quest stays tracked, the watch list is never changed | `/bqf`, minimap button |
| `BetterMapsForever` | Standalone, not part of the suite, Forever only: move the world map (Map & Quest Log) by its title bar, scale the whole window from a corner grip (50-150%), fade it while you move; lock and reset; the maximized map is left alone | `/bmf` |
| `BetterPlatesForever` | Standalone, not part of the suite, Forever only: cleaner enemy nameplates drawn over Blizzard's (flat health bar with reaction/class/health/solid colour, threat colours and percent, cast bar with time left and a grey look for uninterruptible casts, your debuffs with countdown, target scale and dimming); friendly plates left to Blizzard by default; changes no CVars | `/bpf` |
| `BetterCastbarsForever` | Standalone, not part of the suite, Forever only: own cast bars for player, target, focus and pet (icon, name, timer, spark, cast target, latency safe-zone on the player bar); drag and resize them, or let them follow Blizzard's bars (Edit Mode); lock, test bars and reset. A port of `GaarCast` - use one of the two | `/bcf` |
| `BetterGpsForever` | Standalone, not part of the suite, Forever only: one TomTom-style waypoint (`/way x y`, `/way <zone> x y`, or shift-click the world map) with a movable arrow showing distance and time to get there, a world map pin and a minimap pin; also sets Blizzard's own user waypoint; clears itself on arrival; leaves `/way` to TomTom when TomTom is loaded | `/bgps`, `/way` |
| `BetterFramesForever` | Standalone, not part of the suite, Forever only: X-Perl-style unit frames of its own (secure buttons) for player, target, target of target, focus, pet and party1-4: name bar, 2D/3D portrait, health and power with `cur/max  NN%`, class/reaction/low-health colours, target buffs and debuffs with combo points, party auras and range fade, raid/leader/combat/resting icons and a threat border; drag, per-frame scale, lock, reset and test mode. Blizzard's frames are switched off the oUF way (never restyled), out of combat only | `/bff` |
| `BetterGaarForever` | Optional hub, not part of the suite, Forever only: one minimap button whose menu holds the options of all seven Better...Forever addons (`BetterBagsForever`, `BetterQuestsForever`, `BetterMapsForever`, `BetterCastbarsForever`, `BetterPlatesForever`, `BetterGpsForever` and `BetterFramesForever`) through their small API; no bag, quest, map, cast bar, nameplate, waypoint or unit-frame code of its own, and the addons work the same without it | `/bgf`, minimap button |

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

## BetterBagsForever: the native bags on Forever

A standalone addon for Forever's own **Combined Backpack** - no Gaar addon or library needed, and
not listed in `GaarUI`. It makes the frame movable (drag the title bar, or Alt-drag an empty part
of it), saves the position in `BetterBagsForeverDB` and re-applies it whenever Blizzard re-anchors
the bags. It also adds a **Clean Up Bags** button left of the search box, because Forever's native
one ends up hidden under the bag slot icons. A left-click does exactly what Forever's own button
does: the sort sound and `C_Container.SortBags()`. A right-click toggles **Reverse** (off by
default): with it on, in the Combined Backpack only, the addon waits for Blizzard's sort to
settle and then mirrors the whole visible order, so the last slot on screen trades places with
the first, and so on. The sort-direction setting is never read or changed. Since 1.7 it also
keeps a compact record per character (bags, bank, equipped, mail and gold, by item id, per realm)
and adds a line per character on the realm to every item tooltip, plus a gold-per-character
tooltip on the bag window's money; the bank and mail are read only while they are open.
`/bbf` for help, `/bbf reset`, `/bbf lock`, `/bbf unlock`, `/bbf native hide|show`,
`/bbf reverse [on|off]`, `/bbf counts on|off`, `/bbf gold`, `/bbf forget <name>`, `/bbf stop` and
`/bbf status`. It ships only a `_Camelot` TOC and a
plain fallback TOC, both at 16001. Details in
[`addons/BetterBagsForever/README.md`](addons/BetterBagsForever/README.md).

## BetterQuestsForever: the native quest tracker on Forever

A standalone addon for the **Quests** section of Forever's own objective tracker - no Gaar addon
or library needed, and not listed in `GaarUI`. It orders the tracked quests by quest level,
lowest first, ties by title, with quests that are ready to turn in at the bottom (or `top`, or
sorted by `level`), and shows only the first N of them (default 10). Every quest stays tracked
and the watch list is never changed: after Blizzard's own layout, out of combat, the quest blocks
are re-anchored in the sorted order with Blizzard's own spacing and the ones past N are hidden.
During combat the section is Blizzard's own. Other tracker sections are not touched. `/bqf` for
help, `/bqf max <n>|all`, `/bqf completed top|level|bottom`, `/bqf on|off`, `/bqf minimap
[reset]` and `/bqf status`; a minimap button opens the same options as a menu. It ships a
`_Camelot` TOC and a plain fallback TOC, both at 16001. Details, including the taint analysis, in
[`addons/BetterQuestsForever/README.md`](addons/BetterQuestsForever/README.md).

## BetterMapsForever: the world map on Forever

A standalone addon for Forever's own world map window, **Map & Quest Log** - no Gaar addon or
library needed, and not listed in `GaarUI`. Drag the title bar to move it; the position is saved
account-wide in `BetterMapsForeverDB` and put back every time the map opens or Blizzard's panel
layout re-anchors it. Drag the grip in the bottom-right corner to scale the whole window (map and
quest log together, 50-150%) with the top-left corner held in place. While you move, the map fades
to 35% opacity (on by default, adjustable), as in GaarMap. Lock turns moving and resizing off,
reset goes back to Blizzard's position and 100%. Nothing is moved or scaled in combat (it waits
for combat to end), and the maximized map is left to Blizzard. No Blizzard function or table is
replaced. `/bmf` for help, `/bmf lock|unlock`, `/bmf reset`, `/bmf scale <50-150>`, `/bmf fade
on|off`, `/bmf fade <percent>` and `/bmf status`. It ships a `_Camelot` TOC and a plain fallback
TOC, both at 16001. Use it or GaarMap, not both. Details in
[`addons/BetterMapsForever/README.md`](addons/BetterMapsForever/README.md).

## BetterPlatesForever: nameplates on Forever

A standalone port of `GaarPlates` - no Gaar addon or library needed, and not listed in `GaarUI`.
It draws its own overlay on every enemy nameplate (the frame `C_NamePlate.GetNamePlateForUnit`
returns) and hides Blizzard's art there, through `HookScript("OnShow")` and `Hide()` only; a plate
it stops styling gets Blizzard's art back. A flat health bar (120x12 by default) coloured by
reaction, class, health or one solid colour, grey when someone else tagged the mob, an execute
tint at 20% or less; purple with a ring when you hold aggro, amber when your threat is high, threat
percent on the bar; name, level, health text and the unit's target; a cast bar with icon, spell
name and time left, grey for uninterruptible casts; up to 8 of your own debuffs with stacks and a
countdown; your target scaled to 115% and every other plate dimmed to 55%. Friendly plates are
Blizzard's unless `/bpf friendly on`. **No CVars are changed**, so stacking, overlap and plate size
stay as they were. Hidden (secret) values are guarded at the read, and each part of a plate's update
runs in `pcall`: the first refusal switches only that part off for the session, with one message.
`/bpf` for help, `/bpf status`, `/bpf on|off`, `/bpf color reaction|class|health|solid`,
`/bpf health off|percent|current`, `/bpf size <w> <h>`, `/bpf friendly|threat|threattext|execute|
debuffs|tot|dim|targetscale on|off` and `/bpf reset`. Use it or `GaarPlates`, not both (it warns
once at login when both are loaded). It ships a `_Camelot` TOC and a plain fallback TOC, both at
16001. Details in [`addons/BetterPlatesForever/README.md`](addons/BetterPlatesForever/README.md).

## BetterCastbarsForever: cast bars on Forever

A standalone addon - no Gaar addon or library needed, and not listed in `GaarUI`. It is a port of
`GaarCast` to the Better...Forever conventions and draws its own cast bars for the player, target
and focus (on by default; focus only where the client has one) and the pet (off by default): spell
icon with a 1px border (steel with a small shield when the cast cannot be interrupted), name,
`remain / total` or `remain` timer, spark, the cast's target under the bar and a latency
safe-zone on the player bar. Yellow cast, green channel, grey uninterruptible, a red flash on a
failed or interrupted cast and a 0.3 s fade when it finishes. Each bar has its own position by
default: drag to move, the bottom-right grip to resize, saved per bar account-wide in
`BetterCastbarsForeverDB`. **Follow Blizzard (Edit Mode)** anchors each bar to Blizzard's own bar
instead; dragging turns that off again. Blizzard's cast bar is hidden only for the units it
replaces, with `HookScript("OnShow")` and nothing else, and every cast timing and frame geometry is
checked for secret values first; a bar the client refuses is switched off with one line in chat.
`/bcf` for help, `/bcf status`, `lock`, `unlock`, `test`, `reset`, `follow on|off`,
`bar <unit> on|off`, `latency on|off`, `texture blizzard|smooth|flat`, `font 9|11|13` and
`timer total|remain`. It exports `BetterCastbarsForeverAPI` with the same shape as the others, and
BetterGaarForever 2.2 and later has a Castbars row for it. It ships a `_Camelot` TOC and a plain fallback TOC,
both at 16001. Use it or GaarCast, not both (it warns once at login if GaarCast is loaded).
Details in [`addons/BetterCastbarsForever/README.md`](addons/BetterCastbarsForever/README.md).

## BetterGpsForever: one waypoint on Forever

A standalone addon - no Gaar addon or library needed, and not listed in `GaarUI` - for one
TomTom-style waypoint. `/way x y`, `/way x,y` or `/way <zone> x y` (0-100, x first; the zone is
matched case-insensitively, exact or by a unique prefix, and an ambiguous name lists the
candidates) sets it, `/way clear` removes it, and shift + left-click on the world map sets it at
the point under the cursor on the map shown, worked out from the canvas's own scale so it is right
at any BetterMapsForever scale. A new waypoint replaces the old. A movable arrow (lock, reset,
on/off) points at it from `C_Map.GetPlayerMapPosition` and `GetPlayerFacing()`, with the distance
in yards from `C_Map.GetWorldPosFromMapPos` and, under it, the time to get there at the speed you
are closing in over the last 3 seconds (`--` while standing still or moving away). A pin on the
world map (also converted to the continent map) and one on the minimap (minimap zoom and
`rotateMinimap` respected, on the edge when out of range). Blizzard's own user waypoint is set
too where the client allows it and cleared with ours while it is still ours. Within 10 yards it
clears itself with "Arrived at ...". Saved account-wide in `BetterGpsForeverDB`. With TomTom
loaded `/way` stays TomTom's and `/bgps way x y` does the job (one note at login). No Blizzard
function or table is written; every read is guarded for errors and secret values, and each part
switches itself off after its first error with one line in chat. `/bgps` for help, `status`,
`arrow on|off`, `lock`, `unlock`, `reset`, `clear` and `way`. It exports `BetterGpsForeverAPI`,
and BetterGaarForever 2.3 and later has a GPS row for it. It ships a `_Camelot` TOC and a plain
fallback TOC, both at 16001. Details in
[`addons/BetterGpsForever/README.md`](addons/BetterGpsForever/README.md).

## BetterFramesForever: unit frames on Forever

A standalone addon - no Gaar addon or library needed, and not listed in `GaarUI` - that draws
X-Perl-style unit frames of its own for the player, target, target of target, focus, pet and
party1-4 (no raid, no XP bar): a name bar with level and class icon or Elite / Rare / Boss tag,
a 2D portrait (3D model as an option), health and power bars with `cur/max  NN%` text on a dark
see-through backdrop. Class colour for players, reaction colour for NPCs, grey when tapped by
someone else, orange under 35% and red under 20% health. The target gets combo points, a row of
buffs and one of debuffs (your own larger); party frames get small auras and fade out of range;
raid target, leader, combat and resting icons and a threat border. Left-click targets,
right-click opens Blizzard's unit menu. Drag when unlocked, scale per frame (0.6-1.5), lock,
reset and a test mode with made-up data (party without a group). It exists because `GaarFrames`
cannot run on Forever: restyling Blizzard's unit frames taints them. So the frames are
`SecureUnitButtonTemplate` buttons of its own (attributes set once, `RegisterUnitWatch` for
show/hide, every change to them out of combat, queued to `PLAYER_REGEN_ENABLED` otherwise), and
Blizzard's frames are switched off the oUF way - `UnregisterAllEvents`, `Hide`, re-parented to a
hidden frame - out of combat, back only after `/reload`. Hidden (secret) values go straight to the
bars; the text uses the client's secret-safe helpers where it has them, otherwise the bars stand
alone, and every part of an update runs in `pcall` and switches itself off after its first
refusal with one line in chat. `/bff` for help, `status`, `lock`, `unlock`, `test`, `reset`,
`scale <frame> <0.6-1.5>`, `frame <frame> on|off`, `portrait 2d|3d`, `text`, `lowhp` and
`classcolor on|off`. It exports `BetterFramesForeverAPI`, and BetterGaarForever 2.4 and later has
a Frames row for it. It ships a `_Camelot` TOC and a plain fallback TOC, both at 16001. Use it
instead of GaarFrames, X-Perl, ShadowedUnitFrames or PitBull4, not next to them (it warns once at
login). Details in [`addons/BetterFramesForever/README.md`](addons/BetterFramesForever/README.md).

## BetterGaarForever: an optional hub for all seven

An optional hub, not part of the Gaar suite and not listed in `GaarUI`: one minimap button whose
menu has a **Bags**, a **Quests**, a **Maps**, a **Castbars**, a **Plates**, a **GPS** and a
**Frames** submenu with the options of all seven Better...Forever addons: `BetterBagsForever`,
`BetterQuestsForever`, `BetterMapsForever`, `BetterCastbarsForever`, `BetterPlatesForever`,
`BetterGpsForever` and `BetterFramesForever`. It carries no bag, quest, map, cast bar, nameplate,
waypoint or unit-frame code of its own: the addons keep their logic, their saved variables and
`/bbf` / `/bqf` / `/bmf` / `/bcf` / `/bpf` / `/bgps` / `/bff`, and
behave exactly the same without the hub. Each exports a small global API
(`BetterBagsForeverAPI`, `BetterQuestsForeverAPI`, `BetterMapsForeverAPI`, `BetterCastbarsForeverAPI`, `BetterPlatesForeverAPI`, `BetterGpsForeverAPI`, `BetterFramesForeverAPI`: `version`,
`StatusLine()`, `MenuEntries()`, `AddMenuEntries(root)`, `SetMinimapHidden(hidden)`) that fills
its submenu from the same option list as the addon's own menu. While the hub is loaded,
`BetterQuestsForever`'s own minimap button is hidden for the session (its saved setting is not
changed). An addon that is not installed shows as a disabled `– not installed` line. `/bgf` for
help, `/bgf status` for each addon's version and state, `/bgf minimap [reset]`. Details in
[`addons/BetterGaarForever/README.md`](addons/BetterGaarForever/README.md).

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
