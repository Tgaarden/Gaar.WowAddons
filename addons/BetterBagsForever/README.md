# BetterBagsForever

A small standalone addon for the WoW Forever client (`_classic_beta_`, interface 16001). It
improves Blizzard's own **Combined Backpack** (`ContainerFrameCombinedBags`) and does nothing
else. It needs no other addon or library.

## What it does

- **Movable bags.** Drag the title bar, or Alt-drag any empty part of the frame (item slots keep
  their normal drag). The position is saved in `BetterBagsForeverDB` and put back every time
  Blizzard re-anchors the bags, which it does whenever a bag opens, closes or changes size. It is
  stored in UIParent units, so it holds when Blizzard rescales the bags to fit the screen, and it
  is clamped to the screen.
- **Clean Up Bags on the left.** On Forever the native button (`BagItemAutoSortButton`) ends up
  hidden under the bag slot icons right of the search box. A copy of it, with the same broom art
  and tooltip, sits left of the search box; the search box moves right and narrows by the same
  amount, so its right end stays where it was. It is greyed out in combat and refuses with a
  short message there.
  - **Left-click: visual sort** (the default, see below).
  - **Shift+left-click: Blizzard's sort**, `C_Container.SortBags()`.
  - **Right-click: switch Blizzard's sort order** (below).
  - `/bbf mode blizzard` swaps the two left-clicks (plain = Blizzard, Shift = visual);
    `/bbf mode visual` puts them back. Saved in `BetterBagsForeverDB`.
- **Visual sort: sorted the way you see it.** Blizzard's sort fills the bags in bag/slot order.
  The separate bag frames show that order as intended, but the Combined Backpack draws each bag's
  slots in reverse, so a bag sorted as stone, 12, bread, scroll reads backwards there - and
  `SetSortBagsRightToLeft` is one global switch, so it can fix the order of the bags or the order
  inside them, never both. The visual sort assumes no layout: it reads where every item button
  actually is on screen (bag from `GetBagID()` or the parent frame's ID, slot from `GetID()`,
  position from `GetTop()`/`GetLeft()`), and fills the slots in reading order, top-left first:
  1. partial stacks of the same item are merged;
  2. **equipment** (armor, weapons) -> **consumables** (food, potions, scrolls, ammo) -> **trade
     goods** (reagents, cloth, ore, gems, recipes, profession items) -> **quest items** -> **the
     rest** (containers, keys, hearthstone, misc) are packed from the top-left; inside a group, higher
     quality first, then item level, name and stack size;
  3. **junk** (grey with a sell value) is packed into the **bottom-right corner**, with the free
     slots between it and the rest.

  It works the same in the combined view and in separate bag frames (there, frames are read
  column by column, top frame first). Bags marked "Ignore on clean up", and specialty bags (soul,
  quiver, ammo, profession), are left exactly as they are; only the backpack and bags 1-4 are
  sorted, never the keyring or the bank. If the bags are not open it sorts in plain bag/slot
  order and says so.

  Safety: one move per 0.05 s with `C_Container.PickupContainerItem`, never a protected function.
  It waits while items are locked, re-reads the bags before every move (and re-plans if loot or
  the server changed them), and stops at once on combat, on `/bbf stop`, when the cursor holds
  something it did not pick up, when a move keeps being refused, or after a hard cap
  (1500 ticks, or 5 s waiting on locks). It only ever clears the cursor when the cursor holds the
  item it picked up itself. It finishes with one line, "Sorted: N moves."
- **Sort order on right-click.** Right-clicking the same button switches the order Blizzard's
  clean-up fills your bags in (`C_Container.SetSortBagsRightToLeft`), prints the new order and shows it in
  the tooltip. The two orders are named by what you see in the Combined Backpack: **Standard
  (junk bottom-right)** and **Reversed (junk top-left)**. Standard is Blizzard's
  `SortBagsRightToLeft = true`, which is what Forever's own Clean Up uses by default for the
  combined view (the combined view shows the bags in reverse, so Blizzard's "right to left"
  wording is misleading there). It is the client setting Blizzard's own bag menu changes, so the two
  always agree; it is read fresh every time. Switching it works in combat (only sorting is
  blocked there). On a client without the API, right-click does nothing and the tooltip leaves
  the line out.
- Separate (non-combined) bags are left exactly as Blizzard draws them.

## Commands

| Command | Does |
|---|---|
| `/bbf` | Help |
| `/bbf reset` | Back to Blizzard's default position |
| `/bbf lock`, `/bbf unlock` | Stop or allow moving. Locking also gives clicks on the title back to the bag menu |
| `/bbf native hide`, `/bbf native show` | Hide or show Blizzard's own clean-up button (shown by default) |
| `/bbf sort` | Run the visual sort |
| `/bbf stop` | Stop a running visual sort |
| `/bbf mode visual`, `/bbf mode blizzard` | What a plain left-click on Clean Up does (Shift+left-click does the other); `/bbf mode` shows it |
| `/bbf direction` | Switch Blizzard's sort order (same as right-clicking the button) |
| `/bbf direction standard`, `/bbf direction reversed` | Set it to Standard (junk bottom-right) or Reversed (junk top-left); `rtl` and `ltr` work as aliases |
| `/bbf status` | Which of the frames and functions this client has, the sort order and mode, how many bag slots were found on screen, and the saved position |

## How it stays out of the way

- Item moves use `C_Container.PickupContainerItem`, `GetCursorInfo` and `ClearCursor`, the same
  unprotected calls every bag addon uses, and only out of combat.
- Blizzard code is only followed, never replaced: `hooksecurefunc("UpdateContainerFrameAnchors")`,
  `hooksecurefunc(ContainerFrameCombinedBags, "UpdateSearchBox")` and `HookScript` on the frame's
  `OnShow`, `OnHide` and drag scripts. No Blizzard function is called from addon code.
- Every name is checked before use. A missing frame or function switches the matching feature
  off instead of raising an error.
- If the bag frame is protected and a move falls in combat, it waits for `PLAYER_REGEN_ENABLED`.
- Saved variables are read at `ADDON_LOADED`, never at file scope.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source),
`Interface/AddOns/Blizzard_UIPanels_Game/Mainline/ContainerFrame.xml` and `ContainerFrame.lua`):
`ContainerFrameCombinedBags` (and its `TitleContainer`, `UpdateSearchBox`), `BagItemSearchBox`,
`BagItemAutoSortButton`, `UpdateContainerFrameAnchors`, `ContainerFrameSettingsManager:IsUsingCombinedBags`,
`C_Container.SortBags`, `C_Container.GetSortBagsRightToLeft` / `SetSortBagsRightToLeft`,
the item buttons' `GetBagID` (retail `ContainerFrameItemButtonMixin`) and the frames' `Items`,
`EnumerateValidItems` and `ContainerFrameNItemM` names, `ContainerFrameContainer.ContainerFrames`,
`C_Container.GetContainerItemInfo` / `PickupContainerItem` / `GetContainerNumFreeSlots` /
`GetBagSlotFlag` / `GetBackpackAutosortDisabled`, `Enum.BagSlotFlags.DisableAutoSort`,
`C_Item.GetItemInfo` / `GetItemInfoInstant` / `RequestLoadItemDataByID`, `C_Timer.After`,
the atlases `bags-button-autosort-up` / `-down`, `BAG_CLEANUP_BAGS` and `SOUNDKIT.UI_BAG_SORTING_01`.
