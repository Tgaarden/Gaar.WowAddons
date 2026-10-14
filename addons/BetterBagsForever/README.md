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
  amount, so its right end stays where it was. Clicking it plays the sorting sound and calls
  `C_Container.SortBags()`. It is greyed out in combat and refuses with a short message there.
- **Sort direction on right-click.** Right-clicking the same button flips the direction the
  clean-up fills your bags in (`C_Container.SetSortBagsRightToLeft`), prints the new direction and
  shows it in the tooltip. It is the client setting Blizzard's own bag menu changes, so the two
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
| `/bbf direction` | Switch the clean-up sort direction (same as right-clicking the button) |
| `/bbf direction ltr`, `/bbf direction rtl` | Set it to left to right or right to left |
| `/bbf status` | Which of the frames and functions this client has, the sort direction and the saved position |

## How it stays out of the way

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
the atlases `bags-button-autosort-up` / `-down`, `BAG_CLEANUP_BAGS` and `SOUNDKIT.UI_BAG_SORTING_01`.
