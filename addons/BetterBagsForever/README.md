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
- **What a clean-up does.** A left-click does exactly what Forever's own button does: it plays the
  sort sound and calls `C_Container.SortBags()`, the same whichever bag view is in use. Blizzard
  decides where every item goes, and nothing is mirrored or rearranged afterwards. Only left
  clicks are registered; right-click does nothing.
- **The sort direction is left alone.** The addon never calls `C_Container.SetSortBagsRightToLeft`.
  Version 1.2 could switch it; if you changed it there and want Forever's default back, run
  `/run C_Container.SetSortBagsRightToLeft(true)` once.
- Separate (non-combined) bags are left exactly as Blizzard draws them.

## Commands

| Command | Does |
|---|---|
| `/bbf` | Help |
| `/bbf reset` | Back to Blizzard's default position |
| `/bbf lock`, `/bbf unlock` | Stop or allow moving. Locking also gives clicks on the title back to the bag menu |
| `/bbf native hide`, `/bbf native show` | Hide or show Blizzard's own clean-up button (shown by default) |
| `/bbf status` | Which of the frames and functions this client has, whether combined bags are in use, whether the bags are locked, and the saved position |

## How it stays out of the way

- The clean-up is Blizzard's own `C_Container.SortBags()`; the addon never picks up or moves an
  item itself. No Blizzard button is clicked.
- Blizzard code is only followed, never replaced: `hooksecurefunc("UpdateContainerFrameAnchors")`,
  `hooksecurefunc(ContainerFrameCombinedBags, "UpdateSearchBox")` and `HookScript` on the frame's
  `OnShow`, `OnHide` and drag scripts. No Blizzard function is called from addon code.
- Every name is checked before use. A missing frame or function switches the matching feature
  off instead of raising an error.
- If the bag frame is protected and a move falls in combat, it waits for `PLAYER_REGEN_ENABLED`.
- Saved variables are read at `ADDON_LOADED`, never at file scope. Only `locked`,
  `hideNativeButton` and `position` are kept; anything older versions saved is cleared on load.

## Names it relies on

From Blizzard's retail FrameXML, which Forever's UI follows
([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source),
`Interface/AddOns/Blizzard_UIPanels_Game/Mainline/ContainerFrame.xml` and `ContainerFrame.lua`):
`ContainerFrameCombinedBags` (and its `TitleContainer`, `UpdateSearchBox`), `BagItemSearchBox`,
`BagItemAutoSortButton`, `UpdateContainerFrameAnchors`, `ContainerFrameSettingsManager:IsUsingCombinedBags`,
`C_Container.SortBags`, the atlases `bags-button-autosort-up` / `-down`, `BAG_CLEANUP_BAGS`,
`BAG_CLEANUP_BAGS_DESCRIPTION` and `SOUNDKIT.UI_BAG_SORTING_01`.
