# BetterFishingForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). Double
right-click in the 3D world casts Fishing while a fishing pole is equipped, and it does nothing
else. It needs no other addon or library, and it is not part of the Gaar suite.

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

Settings are saved account-wide in `BetterFishingForeverDB`: `enabled` (default on) and
`dblClick` (the window in seconds, default 0.4).

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
| `/bfish status` | Version, enabled, the window, fishing pole equipped yes/no, the resolved Fishing spell, whether the override is armed, `ActionButtonUseKeyDown`, and the last error caught |

## With BetterGaarForever (optional)

[BetterGaarForever](../BetterGaarForever/README.md) is an optional hub: one minimap button whose
menu has a **Fishing** submenu with **Double right-click casts Fishing** (the same as `/bfish
on|off`) and **Double-click window** (0.2 to 0.8 s, the same as `/bfish window`). Both go through
the same functions as the slash command. This addon has no minimap button or menu of its own, so
nothing here changes with or without the hub.

The hub talks to this addon only through `BetterFishingForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `on · 0.40 s · pole equipped` |
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
  are kept.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source), `SecureTemplates.lua`):
`SecureActionButtonTemplate`, `WorldFrame`, `SetOverrideBindingClick`, `ClearOverrideBindings`,
`IsMouseButtonDown`, `GetCursorInfo`, `GetInventoryItemID`, `C_Item.GetItemInfoInstant` (or
`GetItemInfoInstant`), `C_Spell.GetSpellInfo` (or `GetSpellInfo`), `C_SpellBook.IsSpellKnown`,
`IsPlayerSpell`, `IsSpellKnown`, `C_CVar.GetCVarBool("ActionButtonUseKeyDown")` and
`InCombatLockdown`. It ships a `_Camelot` TOC and a plain fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).
