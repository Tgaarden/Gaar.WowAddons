# BetterGaarForever

One standalone addon for the WoW Forever client (`_forever_`, interface 16001) that combines
[BetterBagsForever](../BetterBagsForever/README.md) (1.5) and
[BetterQuestsForever](../BetterQuestsForever/README.md) (1.4) as two modules, with one settings
store, one slash command and one minimap button. It needs no other addon or library, and it is not
part of the Gaar suite.

The two modules are the standalone addons' code, ported with as few changes as possible. Every
behaviour, and every taint decision behind it, is the one described in those two READMEs:

- **Bags** - Forever's Combined Backpack becomes movable (drag the title bar, or Alt-drag an empty
  part of it), a Clean Up Bags button sits left of the search box and does exactly what Forever's
  own button does (`C_Container.SortBags()`), and an optional Reverse (right-click the button)
  mirrors the whole visible Combined Backpack order afterwards, in one burst.
- **Quests** - the Quests section of the objective tracker is ordered by level (or by distance,
  with hysteresis) and limited to the first N quests, purely visually after Blizzard's layout; the
  watch list is never touched. Completed quests go to the bottom, top or among the others; an
  optional dark backdrop; hide in combat through Blizzard's secure state driver, during combat only.

## Install

Put the `BetterGaarForever` folder in `Interface/AddOns`. If you used the standalone addons,
see [Moving over from the standalone addons](#moving-over-from-the-standalone-addons) first.

## Modules on and off

Each module can be switched off on its own (`/bgf bags disable`, `/bgf quests disable`, or
**Enabled** in its submenu of the minimap menu); both are on by default. Off means Blizzard's own
behaviour, the same as not having that addon at all:

- **Bags off:** the bag frame goes back on Blizzard's last anchor, the search box back on the
  anchor and width Blizzard gave it, the Clean Up button and the drag handle are hidden, Blizzard's
  own Clean Up button is shown again if it was hidden, and a running Reverse is stopped. If the bag
  frame is protected in combat, that waits for the end of the fight.
- **Quests off:** every quest block goes back on Blizzard's anchor, everything that was hidden is
  shown, the section gets Blizzard's height, the backdrop is hidden and the distance timer stops.
  The tracker is no longer hidden in combat; if it was hidden for the fight in progress, it still
  comes back when the fight ends.

Hooks cannot be removed in WoW, so they stay in place but do nothing while their module is off.
The settings are kept, so a module comes back exactly as it was. The setting is saved, so a module
stays off across reloads. A module that was off at login never hooks anything.

`/bgf quests on` / `off` is still BetterQuestsForever's own switch: it turns only the order and
the limit on or off, and leaves the backdrop and hide in combat as they are.

## Moving over from the standalone addons

BetterGaarForever never runs a module next to its standalone addon. If BetterBagsForever or
BetterQuestsForever is also enabled, the matching module stays paused (it hooks nothing at all)
and you get one line at login, for example:

> BetterQuestsForever is also enabled — the Quests module is paused. Disable BetterQuestsForever
> and /reload to use the module.

That is also the way to bring your settings over, because a disabled addon's saved variables are
not loaded:

1. Enable BetterGaarForever **while the standalone addons are still enabled**, and log in once.
   Each module copies the standalone addon's settings (`BetterBagsForeverDB`:
   locked, hideNativeButton, position, reverse; `BetterQuestsForeverDB`: enabled, max, completed,
   sort, hideInCombat, backdrop, and the minimap button's angle), checks them with the same rules
   it uses for its own, and says `Imported your BetterQuestsForever settings.` (and the same for
   BetterBagsForever). Both modules are paused for that session.
2. Disable BetterBagsForever and BetterQuestsForever and `/reload`. Both modules are active with
   the imported settings.

The import happens once per module: a flag (`BetterGaarForeverDB.migrated`) stops it from
overwriting anything later. Enabling a standalone addon again only pauses its module again.

## Commands

| Command | Does |
|---|---|
| `/bgf` | Help |
| `/bgf status` | Each module (on, off or paused, with its state) and the minimap button |
| `/bgf bags <command>` | The Bags module's commands: `reset`, `lock`, `unlock`, `native hide`, `native show`, `reverse [on\|off]`, `stop`, `status`; `/bgf bags` alone lists them |
| `/bgf quests <command>` | The Quests module's commands: `max <n>\|all`, `sort level\|distance`, `completed top\|level\|bottom`, `on`, `off`, `bg on\|off\|<0-100>`, `combat on\|off`, `distance`, `status`; `/bgf quests` alone lists them |
| `/bgf bags enable\|disable`, `/bgf quests enable\|disable` | Switch a whole module on or off |
| `/bgf minimap`, `/bgf minimap reset` | Show or hide the minimap button; back to its default place (285 degrees) and shown |

`/bbf` and `/bqf` keep working as shortcuts for `/bgf bags` and `/bgf quests` (so `/bqf max 8` and
`/bbf reverse on` do what they always did, and `/bqf minimap` still toggles the button). Each is
registered only while its standalone addon is not loaded, so the two never clash.

## Minimap button

One button for both modules (`BetterGaarForeverMinimapButton`), with the placement code of
BetterQuestsForever and GaarVanguard: on the rim of the minimap (half its width plus 5), or on the
edge of a square minimap (`GetMinimapShape() == "SQUARE"`), dragged around it, angle saved, 285
degrees by default (clear of GaarOptions at 205 and GaarVanguard at 245). The tooltip shows one
state line per module. A click opens:

- **Bags**: Enabled, Lock position, Reset position, Reverse, Hide Blizzard's own Clean Up button.
- **Quests**: Enabled, Sort by (Level, Distance), Max quests shown (3, 5, 8, 10, 12, 15, 20, 25,
  All), Completed quests (Top, By level / With the others, Bottom), Backdrop, Backdrop opacity
  (20, 35, 50, 65, 80 %), Hide in combat.
- **Hide minimap button** (`/bgf minimap` brings it back).

The menu is Blizzard's `MenuUtil` where the client has it, otherwise a small menu drawn by the
addon with the submenus as indented headings (never `UIDropDownMenu`). While a module is paused,
its submenu says so at the top. `BetterGaarForever_PlaceMinimapButton()` re-places the button,
for an addon that changes the minimap's shape.

## Saved variables

`BetterGaarForeverDB`, read at `ADDON_LOADED`, never at file scope, and cleaned of anything it does
not know:

```
modules  = { bags = true, quests = true }      -- per-module on/off
migrated = { bags = true, quests = true }      -- settings imported from the standalone addon
minimap  = { hide = false, angle = 285 }
bags     = { locked, hideNativeButton, position = { x, y }, reverse }
quests   = { enabled, max, completed, sort, hideInCombat, backdrop = { enabled, alpha }, distanceProbe }
```

## Layout

```
BetterGaarForever.toc, BetterGaarForever_Camelot.toc   both at 16001, same file list
Core.lua            saved variables, module registry, conflict check, import, /bgf, minimap button and menu
Modules/Bags.lua    BetterBagsForever 1.5 as a module
Modules/Quests.lua  BetterQuestsForever 1.4 as a module
```

The files share the addon's private namespace (the second value of `...`); the modules export no
globals. Modules start at `PLAYER_LOGIN`, not `ADDON_LOADED`: the client loads addons in folder
order, so BetterQuestsForever (which sorts after BetterGaarForever) and its saved variables are
only there by then.

## License

MIT, see [LICENSE](LICENSE).
