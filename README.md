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
| `GaarFrames` | Class-coloured unit frames with value and percent text | `/gaarframes` |
| `GaarSpellBook` | A searchable spell book window | `/spellbook` |
| `GaarLooter` | Loot library: every roll, who took part, who won | `/gaarlooter` |
| `GaarMap` | Scales the world map, fades it while you move, squares the minimap | `/gaarmap` |
| `GaarUI` | The suite in one switch: tick it and the client pulls in every module | `/gaarui` |

## One switch, eleven standalone addons

`GaarUI` carries no features. Its TOC lists every module under `## Dependencies`, so ticking
that one entry in the AddOns list brings the whole suite up, and `/gaarui` reports what
actually loaded and at which version.

Each module is still its own addon and runs alone. That is why they are separate folders
rather than files inside one addon: you can install only `GaarBags` and it works, and a fault
in one cannot stop the rest from loading. The cost is eleven entries in the AddOns list, which
is what `GaarUI` and the shared `Gaar [ ]` naming are there to tidy up.

## Layout

```
addons/          one folder per addon, exactly as the game expects it
tools/           link, unlink and check scripts
docs/            notes worth keeping, chiefly the Classic Era API findings
```

## Several game versions, one copy of the code

Each addon carries a TOC file per game flavour rather than a folder per flavour:

```
addons/GaarBags/GaarBags_Vanilla.toc     Classic Era
addons/GaarBags/GaarBags_Mainline.toc    retail, when it is targeted
```

The client picks `Name_<Flavor>.toc` itself and falls back to `Name.toc`. Blizzard's suffixes
are `_Vanilla`, `_TBC`, `_Wrath`, `_Cata`, `_Mists` and `_Mainline`. This is what Plater,
Questie, AtlasLoot and ThreatClassic2 all do, and the reason is worth restating: one copy of
the Lua that asks the client what it supports beats two copies that have to be kept in step.

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

It parses every file with LuaJIT (Lua 5.1, the same dialect the game runs) and then reads the
bytecode to catch locals used above their own declaration. That second check matters: Lua
resolves such a name as a global, which is `nil` at runtime, and a plain syntax check sees
nothing wrong. It has caught several real bugs in this codebase.

## What is not here

SavedVariables. Those live in `WTF/` and belong to the character, not the code.
