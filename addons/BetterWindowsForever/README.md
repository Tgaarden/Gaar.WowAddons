# BetterWindowsForever

A small standalone addon for the WoW Forever client (`_forever_`, interface 16001). It lets you
move and scale Blizzard's own windows (Character, Spellbook & Talents, Professions, Collections,
Group Finder, Social, Guild & Communities, Achievements, Encounter Journal, Merchant, Gossip,
Quest, Mail, Bank, Auction House, Class Trainer, Loot, Dressing Room, Macros, Settings, AddOn
List, Inspect, Trade, Game Menu and more), and does nothing else. It needs BetterForever, the family hub, and no other addon or library, and it is not part of the Gaar suite.

## What it does

- **Move.** Drag a window by its title bar. An invisible handle sits over the title strip
  (`TitleContainer`), or over the top 22 pixels when the window has none, and stops short of the
  close and maximize buttons, so those still work. Only the title bar moves the window: clicks,
  scrolling and item drags inside it work as before. The position is saved per window,
  account-wide, in `BetterWindowsForeverDB`, in UIParent units, and put back every time the window
  opens and every time Blizzard's panel layout re-anchors it. That holds through closing the
  window, `/reload` and relogging. It is kept on screen.
- **Scale.** Hold Ctrl and turn the mouse wheel over a window: 5% per notch, from 50% to 150%. The
  top-left corner stays where it is. Saved per window. Without Ctrl the wheel scrolls lists as
  always.
- **On/off per window.** Every window is on by default. Off gives the window back to Blizzard: its
  anchor and its scale are put back, the handle goes, and the addon does not touch it again until
  it is on again.
- **Reset.** One window or all of them: Blizzard's position and 100% scale.
- **Load-on-demand windows** (Collections, Achievements, Encounter Journal, Auction House, Macros,
  Inspect, Professions, ...) are picked up when their Blizzard addon loads.
- **Combat.** A protected window (one Blizzard's secure code guards, or one with protected
  children) is never moved or scaled in combat: dragging or Ctrl-wheeling it prints a short line
  instead, a drag that is still going when combat starts ends there, and anything that would move
  it waits for `PLAYER_REGEN_ENABLED`. Windows that are not protected (Merchant, Gossip, Loot and
  most others) can be moved at any time.

A window you have never moved or scaled is not touched at all.

## Windows

The addon knows these, and uses whichever this client has. `/bwf list` shows which ones that is;
a window the client does not have says `not on this client` and is left out of the hub menu.

| Key | Window | Frame(s) |
|---|---|---|
| `character` | Character | `CharacterFrame` |
| `spells` | Spellbook & Talents | `PlayerSpellsFrame` (Blizzard_PlayerSpells) |
| `spellbook` | Spellbook | `SpellBookFrame` |
| `talents` | Talents | `ClassTalentFrame`, `PlayerTalentFrame` or `TalentFrame` (Blizzard_ClassTalentUI, Blizzard_TalentUI) |
| `professions` | Professions | `ProfessionsFrame` (Blizzard_Professions) |
| `tradeskill` | Trade Skill | `TradeSkillFrame` (Blizzard_TradeSkillUI) |
| `craft` | Craft | `CraftFrame` (Blizzard_CraftUI) |
| `orders` | Crafting Orders | `ProfessionsCustomerOrdersFrame` (Blizzard_ProfessionsCustomerOrders) |
| `collections` | Collections | `CollectionsJournal` (Blizzard_Collections) |
| `groupfinder` | Group Finder | `PVEFrame` or `LFGParentFrame` |
| `social` | Social | `FriendsFrame` |
| `communities` | Guild & Communities | `CommunitiesFrame` (Blizzard_Communities) |
| `guild` | Guild | `GuildFrame` (Blizzard_GuildUI) |
| `achievements` | Achievements | `AchievementFrame` (Blizzard_AchievementUI) |
| `journal` | Encounter Journal | `EncounterJournal` (Blizzard_EncounterJournal) |
| `calendar` | Calendar | `CalendarFrame` (Blizzard_Calendar) |
| `merchant` | Merchant | `MerchantFrame` |
| `gossip` | Gossip | `GossipFrame` |
| `quest` | Quest dialog | `QuestFrame` |
| `questdetails` | Quest details | `QuestLogPopupDetailFrame` |
| `mail` | Mail | `MailFrame` |
| `openmail` | Open mail | `OpenMailFrame` |
| `bank` | Bank | `BankFrame` |
| `guildbank` | Guild Bank | `GuildBankFrame` (Blizzard_GuildBankUI) |
| `auction` | Auction House | `AuctionHouseFrame` or `AuctionFrame` (Blizzard_AuctionHouseUI, Blizzard_AuctionUI) |
| `trainer` | Class Trainer | `ClassTrainerFrame` (Blizzard_TrainerUI) |
| `loot` | Loot | `LootFrame` |
| `dressup` | Dressing Room | `DressUpFrame` |
| `macros` | Macros | `MacroFrame` (Blizzard_MacroUI) |
| `settings` | Settings & Keybindings | `SettingsPanel` (Blizzard_Settings) |
| `keybindings` | Key Bindings | `KeyBindingFrame` (Blizzard_BindingUI) |
| `addons` | AddOn List | `AddonList` |
| `inspect` | Inspect | `InspectFrame` (Blizzard_InspectUI) |
| `trade` | Trade | `TradeFrame` |
| `gamemenu` | Game Menu | `GameMenuFrame` |
| `taxi` | Flight Master | `TaxiFrame` |
| `itemtext` | Books & Letters | `ItemTextFrame` |
| `tabard` | Tabard | `TabardFrame` |
| `petition` | Petition | `PetitionFrame` |
| `socketing` | Item Socketing | `ItemSocketingFrame` (Blizzard_ItemSocketingUI) |
| `itemupgrade` | Item Upgrade | `ItemUpgradeFrame` (Blizzard_ItemUpgradeUI) |
| `stable` | Stable | `StableFrame` or `PetStableFrame` |
| `channels` | Chat Channels | `ChannelFrame` (Blizzard_Channels) |
| `clock` | Clock | `TimeManagerFrame` (Blizzard_TimeManager) |
| `help` | Help | `HelpFrame` |

### Left alone on purpose

| Window | Why |
|---|---|
| World map (`WorldMapFrame`) | [BetterMapsForever](../BetterMapsForever/README.md) moves and scales it, with the maximized map handled |
| Bags (`ContainerFrameCombinedBags`, `ContainerFrame1-13`) | [BetterBagsForever](../BetterBagsForever/README.md) moves the Combined Backpack; the separate bags are stacked by Blizzard's own bag layout, which would put them back |
| Edit Mode frames (unit frames, action bars, cast bar, objective tracker, minimap, buffs, ...) | Edit Mode saves their place itself. A candidate that turns out to be an Edit Mode system is skipped at runtime (`skipped (Edit Mode owns it)` in `/bwf list`) |
| Trading Post (`PerksProgramFrame`) | Full screen, nothing to move |
| Popups, tooltips, group loot rolls, the cinematic and movie frames | Short-lived or full screen, and positioned by Blizzard every time they appear |

## Commands

| Command | Does |
|---|---|
| `/bwf` | Help |
| `/bwf list` | Every window with its key and state: `on`/`off`, `moved`, the scale, `not loaded yet`, `not on this client` |
| `/bwf on <name>`, `/bwf off <name>` | Let the addon move and scale the window, or leave it to Blizzard (off puts Blizzard's anchor and scale back) |
| `/bwf reset <name>`, `/bwf reset all` | Blizzard's position and 100% scale |
| `/bwf status` | Version, which panel-manager functions this client has, how many windows are on and moved, and which are not on this client |

`<name>` is the key, the label or the frame name, ignoring case and spaces (`auction`,
`Auction House`, `AuctionHouseFrame`), or a unique start of one (`achiev`).

## With BetterForever (required)

Since 1.0.1 this addon lists `BetterForever` under `## Dependencies`: install the `BetterForever` folder next to it, or the client will not load this addon. BetterForever also gives it a page under **Esc > Options > AddOns > Better Forever**, built from the same `MenuEntries()` as the hub's menu, with a short intro at the top; that intro comes from `Intro()`, a field the API table gained in 1.0.1 (it is also the first line of the slash command's help). Since 1.0.2 it also takes its small helpers (the chat line, the number and secret-value checks, drawing the hub's menu) from BetterForever's shared library instead of carrying its own copies; nothing it does or shows changed.

[BetterForever](../BetterForever/README.md) is the family hub: one minimap button whose
menu has a **Windows** submenu with a checkbox per window this client has (the same as `/bwf
on|off <name>`), **Reset one window** (only the windows you have moved or scaled) and **Reset all
positions & scales**. Both go through the same functions as the slash command. This addon has no
minimap button or menu of its own, so nothing here changes with or without the hub.

The hub talks to this addon only through `BetterWindowsForeverAPI`:

| Field | What it is |
|---|---|
| `version` | This addon's version, a string |
| `StatusLine()` | One line of state, e.g. `26 of 26 windows on · 3 moved` |
| `MenuEntries()` | The options as plain data (`{ text, func }`, `{ text, checkbox, checked, func }`, `{ text, submenu }`, `{ divider }`), for a menu drawn without `MenuUtil` |
| `AddMenuEntries(root)` | Adds the same options to a `MenuUtil` root or submenu description |
| `SetMinimapHidden(hidden)` | Does nothing: there is no minimap button to hide. It is there so every addon the hub knows has the same API |

## How it stays out of the way

- Blizzard code is only followed, never replaced: `HookScript` on each window's `OnShow` and
  `OnHide`, and `hooksecurefunc` on `ShowUIPanel`, `HideUIPanel`, `UpdateUIPanelPositions` and
  `FramePositionDelegate:UpdateUIPanelPositions` (the one `ShowUIPanel` itself goes through). No
  Blizzard function or table is written, `UIPanelWindows` included, and `SetAttribute` is never
  called on a Blizzard frame. Only the window's own widget methods are used: `SetPoint`,
  `SetScale`, `StartMoving`.
- The panel manager keeps doing its job and puts the windows in its slots; the addon puts a moved
  window back right after, from the hooks, on the next frame, and from a check every 0.1 s while
  a moved window is open (it compares the anchor and scale with the ones it set, so it costs next
  to nothing). Other windows still open in Blizzard's slots next to where the moved one would be.
- The window is moved with `StartMoving` from the addon's handle and then anchored by the addon;
  `SetMovable` and `SetClampedToScreen` are switched on only for the drag and put back after, and
  the client's own copy of the position (`SetUserPlaced`) is switched off again, so the only saved
  position is the addon's.
- Ctrl + wheel goes to an overlay of the addon's own over the window that takes the mouse wheel
  only while Ctrl is held (`MODIFIER_STATE_CHANGED`) and never clicks or hover.
- Blizzard's last anchor and scale are remembered, so off and reset can put them back on an open
  window.
- Every name is checked before use, and secret geometry is treated as no geometry.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Only `windows` is kept, and per
  window only `off`, `x`, `y` and `scale`.

## BlizzMove, MoveAnything, MoveAny

They also move Blizzard's windows. With one of them loaded both would fight over the same frames,
so BetterWindowsForever says so at login and in `/bwf status`. Use one of the two.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source), `UIParent.lua` /
`UIParentPanelManager.lua` and the window addons): the frame names in the table above, their
`TitleContainer`, `CloseButton`, `ClosePanelButton`, `MaximizeMinimizeFrame` and
`MaxMinButtonFrame`, `ShowUIPanel`, `HideUIPanel`, `UpdateUIPanelPositions`,
`FramePositionDelegate`, `IsControlKeyDown`, `InCombatLockdown` and `C_AddOns.DoesAddOnExist`. It
ships a `_Camelot` TOC and a plain fallback TOC, both at 16001.

## License

MIT, see [LICENSE](LICENSE).
