# BetterBarsForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). It makes
Blizzard's own action buttons easier to read: a red icon when the action is out of range, a blue
icon when you lack the mana, energy or rage, big cooldown numbers, short hotkey labels, and macro
names you can switch off. Every part can be switched on or off on its own. It needs BetterForever, the family hub, and no other addon or library, and it is not part of the Gaar suite.

## What it does

| Feature | Default | What it does |
|---|---|---|
| `rangeColor` | on | The icon is tinted red (0.8, 0.1, 0.1) while the action is out of range of your target |
| `manaColor` | on | The icon is tinted blue (0.3, 0.3, 1.0) while you lack the mana, energy or rage (`IsUsableAction`: usable false, notEnoughMana true). Unusable for any other reason stays Blizzard's grey |
| `cooldownText` | on | A big, centred, outlined cooldown number on the button: `56`, `2m`, `1h` (no space, rounded up, the same format as BetterFramesForever's aura times). Nothing for the global cooldown (1.5 s or less) |
| `hotkeyShort` | on | Short hotkey labels: `Mouse Button 4` -> `M4`, `Middle Mouse` -> `M3`, `Num Pad 1` -> `N1`, `Mouse Wheel Up/Down` -> `WU`/`WD`, `Shift-` -> `s`, `Ctrl-` -> `c`, `Alt-` -> `a` (`Ctrl-Shift-4` -> `cs4`). Blizzard's own short forms (`s-`, `MwU`, ...) are shortened the same way |
| `macroText` | on | Macro names on the buttons. Off hides them (the text is made transparent, never hidden) |
| `outOfRangeHotkey` | off | Out of range tints only the hotkey text red, not the icon. While on, it overrides `rangeColor` for the icon |

- **Order.** Out of range wins over no mana. When neither applies, the icon gets its normal
  colour back.
- **Which buttons.** The main bar (`ActionButton1-12`), the multi bars
  (`MultiBarBottomLeft/BottomRight/Right/Left`, `MultiBar5-7`), the bonus and override bars where
  the client has them, plus anything Blizzard's `ActionBarButtonEventsFrame` lists. The stance bar
  (`StanceButton1-10`) and the pet bar (`PetActionButton1-10`) get the cooldown numbers, short
  hotkeys and macro switch; range and mana colours are for action buttons only.
- **Master switch.** `/bbars off` hands every button back exactly as Blizzard draws it: colours,
  hotkey text and colour, macro names and the cooldown's own numbers.

Settings are saved account-wide in `BetterBarsForeverDB`: `enabled` and one key per feature above.

## How it works

- **A ticker of its own** (5 times a second, visible buttons only) reads `IsUsableAction`,
  `IsActionInRange` and the cooldown, and sets the colours and texts.
- **Right after Blizzard.** So that Blizzard's own update never shows its colour for a moment in
  between, the addon also runs right after it, through `hooksecurefunc` on whichever of these the
  client has: the 12.x mixin methods on each button (`UpdateUsable`, `UpdateRangeIndicator`,
  `Update`, `UpdateHotkeys`, `SetHotkeys`) and the older globals (`ActionButton_UpdateUsable`,
  `ActionButton_UpdateRangeIndicator`, `ActionButton_Update`, `ActionButton_UpdateHotkeys`,
  `PetActionButton_SetHotkeys`). `/bbars status` lists which were found. `ActionButton_OnUpdate`
  is not hooked on purpose: it runs every frame for every button, and the ticker covers it.
- **Cooldown numbers.** While the timing is plain, the addon draws its own number from
  `C_ActionBar.GetActionCooldown` (else `GetActionCooldown`; `GetShapeshiftFormCooldown` and
  `GetPetActionCooldown` for the stance and pet bars) in a frame of its own above the swipe, and
  keeps the cooldown's built-in numbers off so they never show twice. Where the client hides the
  timing (a secret), only the client can draw it: the cooldown's own countdown numbers are
  switched on (`SetHideCountdownNumbers(false)`), in the bigger font (`GetCountdownFontString`,
  else `SetCountdownFont`) and in the same `56 / 2m / 1h` format where the client has
  `C_StringUtil`'s rule formatter (`SetCountdownFormatter`). Those are hidden for the global
  cooldown only when the client says so in plain (`isOnGCD`). Whether built-in numbers show at all
  may also depend on the client's `countdownForCooldowns` setting; `/bbars status` prints it.

## Secret values

On the 12.x engine `IsUsableAction`, `IsActionInRange` and cooldown values may come back secret. A
secret is never compared or tested; it only goes into a widget setter that takes it as it is, each
one checked first:

- **Range secret, usable plain:** `Texture:SetVertexColorFromBoolean(inRange, normal, red)` on the
  icon. Without it, a red texture of the addon's own over the icon, with
  `SetAlphaFromBoolean(inRange, 0, 0.55)`.
- **Usable secret:** `SetVertexColorFromBoolean(usable, white, grey)` (blue too when the mana flag
  is plain). Two secret booleans cannot be combined, so then there is no blue. A secret range on
  top uses the red overlay.
- **No setter:** the icon is left to Blizzard.
- **Hotkey mode with a secret range:** Blizzard's own range indicator already reds the hotkey; the
  addon only takes over where the hotkey has `SetVertexColorFromBoolean`.

`/bbars status` counts every secret answer and every missing or refused setter.

## Commands

| Command | Does |
|---|---|
| `/bbars` or `/bbars help` | Help |
| `/bbars on`, `/bbars off` | Switch the addon on or off |
| `/bbars range on\|off` (or `rangeColor`) | Red icon out of range |
| `/bbars mana on\|off` (or `manaColor`) | Blue icon without mana |
| `/bbars cooldown on\|off` (or `cooldownText`) | Cooldown numbers |
| `/bbars hotkey on\|off` (or `hotkeyShort`) | Short hotkeys |
| `/bbars macro on\|off` (or `macroText`) | Macro names |
| `/bbars rangehotkey on\|off` (or `outOfRangeHotkey`) | Out of range: red hotkey instead of red icon |
| `/bbars status` | Version, the switches, the buttons handled (action, stance, pet), the hooks found and the ones this client lacks, the secret answers counted, which secret-safe setters and cooldown APIs exist, `countdownForCooldowns`, the client countdown formatter and the last error caught |

A feature command with no `on`/`off` toggles it. `/betterbarsforever` works as well as `/bbars`.

## With BetterForever (required)

Since 1.0.1 this addon lists `BetterForever` under `## Dependencies`: install the `BetterForever` folder next to it, or the client will not load this addon. BetterForever also gives it a page under **Esc > Options > AddOns > Better Forever**, built from the same `MenuEntries()` as the hub's menu, with a short intro at the top; that intro comes from `Intro()`, a field the API table gained in 1.0.1 (it is also the first line of the slash command's help).

[BetterForever](../BetterForever/README.md) is the family hub with one minimap button
whose menu can hold this addon's options: **Enabled**, then one checkbox per feature (**Red icon
out of range**, **Blue icon without mana**, **Cooldown numbers**, **Short hotkeys**, **Macro
names**, **Out of range: red hotkey instead of red icon**). They go through the same functions as
the slash command. This addon has no minimap button or menu of its own, so nothing here changes
with or without the hub.

The hub talks to this addon only through `BetterBarsForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `on · 120 buttons · 5/6 features`, or `off` |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, radio, checked, func }`, `{ text, submenu }`, `{ divider }`), for a menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide. It is there so every addon the hub knows has the same API |

## How it stays out of the way

- Action buttons are secure. Blizzard code is only followed, never replaced: `hooksecurefunc`
  only. No Blizzard function, script or table is written, no protected function is called, and no
  button is shown, hidden, moved or given an attribute.
- Only visual properties of non-secure regions change: the icon's vertex colour, the hotkey's
  text and colour, the macro name's alpha and the cooldown's own countdown numbers, plus textures,
  font strings and one plain frame per button that the addon creates itself, out of combat (a
  `/reload` in combat waits for `PLAYER_REGEN_ENABLED`).
- Every client API is checked with `type(...) == "function"` before use, every handler runs in
  `pcall` (the last error is kept for `/bbars status`), and a secret value is never compared or
  tested.
- Saved variables are read at `ADDON_LOADED`, never at file scope.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source)): the action button names above,
`ActionBarButtonEventsFrame`, the button fields `action`, `icon`, `HotKey`, `Name` and `cooldown`,
`IsUsableAction`, `IsActionInRange`, `HasAction`, `C_ActionBar.GetActionCooldown`,
`GetActionCooldown`, `GetShapeshiftFormCooldown`, `GetPetActionCooldown`, `RANGE_INDICATOR`,
`Texture:SetVertexColorFromBoolean`, `Region:SetAlphaFromBoolean`, `CreateColor`,
`Cooldown:SetHideCountdownNumbers`, `GetCountdownFontString`, `SetCountdownFont`,
`SetCountdownFormatter`, `C_StringUtil.CreateNumericRuleFormatter`, `issecretvalue`,
`issecrettable`, `hooksecurefunc` and `InCombatLockdown`. It ships a `_Camelot` TOC and a plain
fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).
