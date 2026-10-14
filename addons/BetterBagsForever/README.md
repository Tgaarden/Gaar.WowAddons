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
  - **Left-click: clean up bags** (below).
  - **Right-click: switch the sort order** (below).
- **What a clean-up does.** Left-click always runs Blizzard's own `C_Container.SortBags()`, with
  the sort sound. Blizzard decides which item goes in which bag. The Combined Backpack draws each
  bag's slots in reverse, so with the **Standard** order the order inside each bag looks mirrored
  there; in that one case the addon turns each bag round afterwards:

  | View | Sort order (`C_Container.GetSortBagsRightToLeft()`) | Left-click does |
  |---|---|---|
  | Separate bags | any | `C_Container.SortBags()` only |
  | Combined Backpack | Reversed (`false`) | `C_Container.SortBags()` only |
  | Combined Backpack | Standard (`true`) | `C_Container.SortBags()`, wait until it has finished, then mirror each bag |

  "Combined" means `ContainerFrameSettingsManager:IsUsingCombinedBags()`, or, on a client without
  it, that `ContainerFrameCombinedBags` is shown.

  **Mirroring** swaps slot i with slot n+1-i in the backpack and bags 1-4 (specialty bags
  included), so the order inside each bag is reversed and every item stays in the bag Blizzard
  put it in. Bags marked "Ignore on clean up" (and the backpack, if it is) are skipped, because
  Blizzard did not sort them; the keyring and the bank are never touched.

  - **Waiting for Blizzard's sort:** it counts as finished once no `BAG_UPDATE`,
    `BAG_UPDATE_DELAYED` or `ITEM_LOCK_CHANGED` has arrived for about 1 s and no carried slot is
    locked. If that has not happened after about 15 s it gives up, says so, and does not mirror.
  - **Safety:** the swaps are planned from the bags as Blizzard left them, and done one move per
    0.05 s with `C_Container.PickupContainerItem`, never a protected function. Pairs that are
    both empty or hold identical stacks are skipped. Both slots are re-read before every move and
    checked after it; it waits while either is locked. Two different stacks of the same item
    (say 20 and 7 linen) are swapped through a free slot, so they can never merge; with no free
    slot in the carried bags that pair is left as it is and the final message says so. It stops
    at once on combat, on `/bbf stop`, when the cursor holds something it did not pick up, when a
    move keeps being refused, when the bags change under a move, or after a hard cap (2 minutes, or
    5 s waiting on locks). It only ever clears the cursor when the cursor holds the item it picked
    up itself. It finishes with one line, "Bags mirrored (N swaps)."
- **Sort order on right-click.** Right-clicking the same button switches the order Blizzard's
  clean-up uses (`C_Container.SetSortBagsRightToLeft`): **Standard** is
  `SortBagsRightToLeft = true`, what Forever's own Clean Up uses by default, and **Reversed** is
  `false`. It is the client setting Blizzard's own bag menu changes, so the two always agree.
  Chat, tooltip, `/bbf status` and the choice whether to mirror all read
  `GetSortBagsRightToLeft()` live, never the value that was asked for: after a change the addon
  re-reads it (again after 0.2 s, 0.5 s and 1 s if the client is slow) and prints "Sort order: X"
  only once the client reports X, or "Could not change the sort order (still: X)" if it never
  does. Further right-clicks are ignored while a change is unconfirmed. Switching works in combat
  (only sorting is blocked there). On a client without the API, right-click does nothing and the
  tooltip leaves the line out.
- Separate (non-combined) bags are left exactly as Blizzard draws them.

## Commands

| Command | Does |
|---|---|
| `/bbf` | Help |
| `/bbf reset` | Back to Blizzard's default position |
| `/bbf lock`, `/bbf unlock` | Stop or allow moving. Locking also gives clicks on the title back to the bag menu |
| `/bbf native hide`, `/bbf native show` | Hide or show Blizzard's own clean-up button (shown by default) |
| `/bbf direction` | Switch the sort order (same as right-clicking the button) |
| `/bbf direction standard`, `/bbf direction reversed` | Set it to Standard (`true`) or Reversed (`false`); `rtl` and `ltr` work as aliases |
| `/bbf stop` | Stop a running clean-up (the wait or the mirror) |
| `/bbf status` | Which of the frames and functions this client has, whether combined bags are in use, the sort order, whether the next clean-up will mirror, and the saved position |

## How it stays out of the way

- Item moves use `C_Container.PickupContainerItem`, `GetCursorInfo` and `ClearCursor`, the same
  unprotected calls every bag addon uses, and only out of combat. No Blizzard button is clicked.
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
`C_Container.GetContainerNumSlots` / `GetContainerItemInfo` / `PickupContainerItem` /
`GetContainerNumFreeSlots` / `GetBagSlotFlag` / `GetBackpackAutosortDisabled`,
`Enum.BagSlotFlags.DisableAutoSort`, the events `BAG_UPDATE`, `BAG_UPDATE_DELAYED` and
`ITEM_LOCK_CHANGED`, `C_Timer.After`,
the atlases `bags-button-autosort-up` / `-down`, `BAG_CLEANUP_BAGS` and `SOUNDKIT.UI_BAG_SORTING_01`.
