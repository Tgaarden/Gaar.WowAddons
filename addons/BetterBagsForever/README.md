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
  and the same tooltip (Blizzard's `BAG_CLEANUP_BAGS` title and `BAG_CLEANUP_BAGS_DESCRIPTION`),
  sits left of the search box; the search box moves right and narrows by the same amount, so its
  right end stays where it was. It is greyed out in combat and refuses with a short message there.
- **What a clean-up does.** A left-click always starts with exactly what Forever's own button
  does: it plays the sort sound and calls `C_Container.SortBags()`. Blizzard decides where every
  item goes.
- **Reverse (optional, off by default).** Right-click the button (or `/bbf reverse`) to turn it
  on or off; it is saved in `BetterBagsForeverDB.reverse` and the tooltip shows the current
  value. With Reverse on and the Combined Backpack in use, a left-click waits for Blizzard's sort
  to settle and then mirrors the whole visible order: the last slot on screen trades places with
  the first, the second-to-last with the second, and so on. Empty slots count too, so a block of
  empty slots ends up mirrored as well. After Blizzard's Standard sort that puts the Hearthstone
  (last slot) first and whatever was first in the last slot.

  | View | Reverse | Left-click |
  |---|---|---|
  | Separate bags | either | Sound + `SortBags()`, nothing else |
  | Combined Backpack | off | Sound + `SortBags()`, nothing else |
  | Combined Backpack | on | Sound + `SortBags()`, then the whole visible order mirrored |

  How it works:
  - *Waiting:* Blizzard's sort counts as finished once no `BAG_UPDATE`, `BAG_UPDATE_DELAYED` or
    `ITEM_LOCK_CHANGED` has arrived for about 0.35 s and no carried slot is locked. After about
    15 s it gives up with a message and moves nothing.
  - *Reading the order:* from the screen. The visible item buttons of `ContainerFrameCombinedBags`
    are mapped to bag and slot (`GetBagID()`, `GetID()`) and sorted top to bottom, then left to
    right, using their effective scale. Only the backpack and bags 1-4 count; the keyring, the
    bank, hidden buttons and specialty bags (soul, quiver, ammo, profession) are left out.
  - *Mirroring:* slot i pairs with slot N+1-i. Pairs that are both empty or hold the same item are
    skipped (nothing visible would change, and stacks can never merge). Every other pair is one
    `C_Container.PickupContainerItem` on each slot: a move into an empty slot or a swap.
  - *One burst (since 1.5):* no two pairs share a slot, so the moves do not depend on each other
    and all of them go out in one burst, without waiting for the server between them: up to 10
    pairs per frame, the rest in the next frames. Both slots are re-read right before each move,
    and the cursor has to be empty after every pair or the burst ends there. Then a verify pass
    waits until none of the slots is locked (about 3 s at most), re-reads them, and gives any
    pair that did not end up mirrored another burst, up to three more rounds. It prints
    `Reversed (N swaps).` at the end, or how many pairs could not be swapped. Version 1.4 made
    one move per 0.05 s and waited for the server after each one, plus about 1 s before the
    first, so the same bags now take a fraction of the time.
  - *Stops* on combat (checked before every pair), `/bbf stop`, something on the cursor that the addon did not pick up, the
    client refusing a move repeatedly, the bags changing underneath, or a safety limit. The
    cursor is cleared only when it holds the addon's own item.
- **The sort direction is left alone.** The addon never calls `C_Container.SetSortBagsRightToLeft`
  and does not read it either. Version 1.2 could switch it; if you changed it there and want
  Forever's default back, run `/run C_Container.SetSortBagsRightToLeft(true)` once.

## Commands

| Command | Does |
|---|---|
| `/bbf` | Help |
| `/bbf reset` | Back to Blizzard's default position |
| `/bbf lock`, `/bbf unlock` | Stop or allow moving. Locking also gives clicks on the title back to the bag menu |
| `/bbf native hide`, `/bbf native show` | Hide or show Blizzard's own clean-up button (shown by default) |
| `/bbf reverse`, `/bbf reverse on`, `/bbf reverse off` | Toggle or set Reverse (same as right-clicking the button) |
| `/bbf stop` | Stop a running reversal |
| `/bbf status` | Which of the frames and functions this client has, whether combined bags are in use, Reverse and what the next clean-up will do, how many slots it finds in the Combined Backpack, whether the bags are locked, and the saved position |

## How it stays out of the way

- The clean-up is Blizzard's own `C_Container.SortBags()`. Items are moved by the addon only for
  Reverse, only with `C_Container.PickupContainerItem`, never in combat. No Blizzard button is
  clicked and no protected function is called.
- Blizzard code is only followed, never replaced: `hooksecurefunc("UpdateContainerFrameAnchors")`,
  `hooksecurefunc(ContainerFrameCombinedBags, "UpdateSearchBox")` and `HookScript` on the frame's
  `OnShow`, `OnHide` and drag scripts. No Blizzard function is called from addon code.
- Every name is checked before use. A missing frame or function switches the matching feature
  off instead of raising an error.
- If the bag frame is protected and a move falls in combat, it waits for `PLAYER_REGEN_ENABLED`.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Only `locked`,
  `hideNativeButton`, `position` and `reverse` are kept; anything older versions saved is cleared
  on load.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source),
`Interface/AddOns/Blizzard_UIPanels_Game/Mainline/ContainerFrame.xml` and `ContainerFrame.lua`):
`ContainerFrameCombinedBags` (and its `TitleContainer`, `UpdateSearchBox`), `BagItemSearchBox`,
`BagItemAutoSortButton`, `UpdateContainerFrameAnchors`, `ContainerFrameSettingsManager:IsUsingCombinedBags`,
`C_Container.SortBags`, `C_Container.PickupContainerItem`, `C_Container.GetContainerItemInfo`,
`C_Container.GetContainerNumSlots`, `C_Container.GetContainerNumFreeSlots` (bag family), the item
buttons' `GetBagID` / `GetID` (`ContainerFrameItemButtonMixin`), the atlases `bags-button-autosort-up` / `-down`, `BAG_CLEANUP_BAGS`,
`BAG_CLEANUP_BAGS_DESCRIPTION` and `SOUNDKIT.UI_BAG_SORTING_01`.
