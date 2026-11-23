# GaarGroupForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). A movable bar that
is shown only while you are in a party (hidden solo and in a raid): pick your group role and, as
party leader, start a ready check, a role check or a pull countdown. It needs GaarForever, the family
hub, and no other addon or library, and it is not part of the Gaar suite.

## Right-click menu

Right-click the bar to open this addon's menu (the same options as the GaarForever hub menu).

## What it does

- **Mode buttons: Tank, DPS, Healer** (role icons). A click sets your group role with
  `UnitSetRole("player", ...)` (when the client has it and you are in a group), highlights the mode
  and remembers it for this character. The highlight follows the game: a role set from the
  Group Finder or by someone else (`PLAYER_ROLES_ASSIGNED`, `GROUP_ROSTER_UPDATE`,
  `UnitGroupRolesAssigned`) shows on the bar too. When you join a party and the game has no role for
  you yet, your saved mode is applied once.
- **Ready**: starts a ready check (`DoReadyCheck`). Greyed out unless you are the party leader.
- **Roles**: starts a role check (`InitiateRolePoll`). Greyed out unless you are the party leader.
- **Pull**: a countdown. Left-click uses the default length (5 s); right-click opens a menu of 3, 5
  or 10 s. It uses the game's own `C_PartyInfo.DoCountdown(n)` when the client has it (the button is
  then greyed out unless you are the leader, as the game refuses anyone else). Without it, the
  countdown is typed to party chat (`Pull in 5`, `4`, `3`, `2`, `1`, `Go!`), only when you click, and
  needs no rank.
- **Tooltips** on every button; a greyed button explains why in red.
- **Position** is saved; lock it with `/ggf lock`.

Settings are saved account-wide in `GaarGroupForeverDB`: `show`, `locked`, `scale`, `countdown`
(default length 3, 5 or 10) and the bar's position. Your mode is saved per character in
`GaarGroupForeverCharDB`.

## Commands

`/ggf` or `/gaargroupforever`:

| Command | Does |
|---|---|
| `/ggf` or `/ggf help` | list the commands |
| `/ggf show` / `hide` / `toggle` | the bar in a party (option **Show the bar in a party**) |
| `/ggf lock` / `unlock` | lock or unlock the bar's position |
| `/ggf reset` | put the bar back where it started |
| `/ggf scale 0.5-2` | bar size |
| `/ggf countdown 3\|5\|10` | default pull countdown |
| `/ggf test` | show the bar solo to place it (this session only) |
| `/ggf status` | settings, group state, which countdown path is used |

## With GaarForever (required)

This addon lists `GaarForever` under `## Dependencies`: install the `GaarForever` folder next to it,
or the client will not load this addon. GaarForever gives it a **Group** page under
**Esc > Options > AddOns > Gaar Forever**, built from the same `MenuEntries()` as the hub's menu, with
a short intro from `Intro()`.

`GaarGroupForeverAPI` (`version`, `Intro`, `StatusLine`, `MenuEntries`, `AddMenuEntries`,
`SetMinimapHidden`) lets the hub list these options in its menu.

## How it is built

Plain (non-secure) buttons; none of the calls used is protected, and no Blizzard frame is touched.
Every handler runs in `pcall`, every client API is checked with `type(...) == "function"` first, and
a secret value is never compared: it is treated as no value. The modes are a table (`Modes`) with a
hook per mode (`ModeHooks`), so a per-mode module can be added later. It ships a `_Camelot` TOC and a
plain fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).

## Support

If you enjoy this addon, you can [buy me a coffee](https://buymeacoffee.com/tgaarden) ☕
