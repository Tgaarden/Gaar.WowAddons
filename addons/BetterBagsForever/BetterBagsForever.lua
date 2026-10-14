--[[
  BetterBagsForever - small fixes for the native "Combined Backpack" on WoW Forever.

  Forever ships the retail-style combined bag frame (ContainerFrameCombinedBags). This addon
  changes these things about it and nothing else:

    * The frame can be moved: drag its title bar, or Alt-drag any empty part of it. The position
      is saved in BetterBagsForeverDB and put back every time Blizzard re-anchors the bags.
    * A "Clean Up Bags" button sits on the left of the search box, because on Forever the native
      one (BagItemAutoSortButton) ends up hidden under the bag slot icons on the right.
      Left-click runs Blizzard's own C_Container.SortBags. Right-clicking it switches Blizzard's
      sort order (C_Container.SetSortBagsRightToLeft), the same client setting Blizzard's own bag
      menu changes.
    * In the Combined Backpack with the "Standard" order (SortBagsRightToLeft = true) the order
      inside each bag reads backwards, because that view draws every bag's slots in reverse. In
      that one case the addon waits for Blizzard's sort to finish and then mirrors each bag
      (slot i swaps with slot n+1-i), so which items are in which bag stays exactly as Blizzard
      left it. Items are moved one at a time with C_Container.PickupContainerItem, out of
      combat only.
    * /bbf for help, reset, lock, unlock, direction, native, stop and status.

  Names come from Blizzard's retail FrameXML (Interface/AddOns/Blizzard_UIPanels_Game/Mainline/
  ContainerFrame.xml and ContainerFrame.lua): ContainerFrameCombinedBags, BagItemSearchBox,
  BagItemAutoSortButton, UpdateContainerFrameAnchors, ContainerFrameSettingsManager. Every one
  of them is checked before use; when something is missing the matching feature simply does not
  switch on.

  Taint: Blizzard code is only ever followed, never replaced. Hooks go through hooksecurefunc
  and HookScript, no Blizzard frame function is called, and nothing protected is touched (the
  item moves use the same unprotected container API every bag addon uses). If the bag
  frame ever turns out to be protected, a move that lands in combat waits for
  PLAYER_REGEN_ENABLED instead of being attempted.
]]

local _G = _G
local ADDON_NAME = ... or "BetterBagsForever"
local PREFIX = "|cff33ff99BetterBagsForever|r: "

-- How far the search box moves right to make room for the clean-up button: the button's width
-- plus a gap that clears the search box's own left border art.
local BUTTON_WIDTH, BUTTON_HEIGHT = 28, 26
local BUTTON_GAP = 6
local SEARCH_SHIFT = BUTTON_WIDTH + BUTTON_GAP
local MIN_SEARCH_WIDTH = 40

-- Blizzard's sort button art, and a stand-in for a client that lacks the atlas.
local ATLAS_UP, ATLAS_DOWN = "bags-button-autosort-up", "bags-button-autosort-down"
local FALLBACK_ICON = "Interface\\Icons\\INV_Pet_Broom"
local HIGHLIGHT = "Interface\\Buttons\\ButtonHilight-Square"

local DEFAULTS = {
    locked = false,
    hideNativeButton = false,
}

local db                -- BetterBagsForeverDB, bound at ADDON_LOADED (never at file scope)
local bagFrame          -- ContainerFrameCombinedBags once found
local cleanupButton     -- our button left of the search box
local dragHandle        -- invisible handle over the title bar
local blizzardPoints    -- the anchor Blizzard last gave the frame, for /bbf reset
local appliedPoint      -- the anchor we last set, so it is not mistaken for Blizzard's
local searchLayout      -- the search box anchor we last set, so it is shifted only once
local needsRestore      -- /bbf reset is waiting to put Blizzard's anchor back
local pendingApply      -- a move that has to wait for combat to end
local moving            -- a drag is in progress
local nativeHidden      -- we hid BagItemAutoSortButton and should show it again on request
local frameHooked, anchorsHooked

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end

local function InCombat()
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() and true or false
end

-- True when changing this region now could trip combat protection.
local function Blocked(region)
    if not InCombat() then return false end
    if region and region.IsProtected then
        local protected = region:IsProtected()
        return protected and true or false
    end
    return true
end

local function GetBagFrame()
    local f = _G.ContainerFrameCombinedBags
    if type(f) == "table" and f.SetPoint and f.ClearAllPoints then return f end
end

local function GetSearchBox()
    local box = _G.BagItemSearchBox
    if type(box) == "table" and box.SetPoint then return box end
    if bagFrame then
        box = bagFrame.SearchBox or bagFrame.searchBox
        if type(box) == "table" and box.SetPoint then return box end
    end
end

local function GetNativeSortButton()
    local b = _G.BagItemAutoSortButton
    if type(b) == "table" and b.Hide then return b end
end

local function GetSortFunction()
    local container = _G.C_Container
    if type(container) == "table" and type(container.SortBags) == "function" then
        return container.SortBags
    end
end

-- The sort direction is a client setting shared with Blizzard's own bag menu. Both halves have
-- to be there, or the direction feature stays off.
local function GetDirectionFunctions()
    local container = _G.C_Container
    if type(container) == "table" and type(container.GetSortBagsRightToLeft) == "function"
        and type(container.SetSortBagsRightToLeft) == "function" then
        return container.GetSortBagsRightToLeft, container.SetSortBagsRightToLeft
    end
end

-- Combined bags in use? Ask the settings manager when it is there, else trust the frame.
local function UsingCombinedBags()
    local manager = _G.ContainerFrameSettingsManager
    if type(manager) == "table" and type(manager.IsUsingCombinedBags) == "function" then
        local ok, using = pcall(manager.IsUsingCombinedBags, manager)
        if ok then return using and true or false end
    end
    return bagFrame ~= nil and bagFrame:IsShown() and true or false
end

local function HasAtlas(name)
    local tex = _G.C_Texture
    if type(tex) == "table" and type(tex.GetAtlasInfo) == "function" then
        local ok, info = pcall(tex.GetAtlasInfo, name)
        return ok and info ~= nil
    end
    return false
end

local function CapturePoints(region)
    local points = {}
    local n = region.GetNumPoints and region:GetNumPoints() or 0
    for i = 1, n do
        local point, relativeTo, relativePoint, x, y = region:GetPoint(i)
        if point then
            points[#points + 1] = { point, relativeTo, relativePoint, x or 0, y or 0 }
        end
    end
    return points
end

local function SetPoints(region, points)
    region:ClearAllPoints()
    for _, p in ipairs(points) do
        region:SetPoint(p[1], p[2], p[3], p[4], p[5])
    end
end

local function Near(a, b)
    return math.abs((a or 0) - (b or 0)) < 0.01
end

local function SamePoints(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do
        local p, q = a[i], b[i]
        if p[1] ~= q[1] or p[2] ~= q[2] or p[3] ~= q[3] or not Near(p[4], q[4]) or not Near(p[5], q[5]) then
            return false
        end
    end
    return true
end

-- Converts between the bag frame's own coordinates and UIParent's. Saved positions are kept in
-- UIParent units, so they survive Blizzard rescaling the bags to fit the screen.
local function ScaleRatio()
    local parent = _G.UIParent
    local mine = bagFrame.GetEffectiveScale and bagFrame:GetEffectiveScale() or 1
    local theirs = parent and parent.GetEffectiveScale and parent:GetEffectiveScale() or 1
    if not mine or mine <= 0 or not theirs or theirs <= 0 then return 1 end
    return mine / theirs
end

-- ---------------------------------------------------------------------------
-- Position
-- ---------------------------------------------------------------------------

local function SavePosition()
    if not bagFrame or not db then return end
    local left, top = bagFrame:GetLeft(), bagFrame:GetTop()
    if not left or not top then return end
    local ratio = ScaleRatio()
    db.position = { x = left * ratio, y = top * ratio }
end

-- Puts the frame where the player left it, or back on Blizzard's anchor after /bbf reset.
local function ApplyPosition()
    if not bagFrame or not db or moving then return end
    if not db.position and not needsRestore then return end
    if Blocked(bagFrame) then
        pendingApply = true
        return
    end

    if db.position then
        local parent = _G.UIParent
        local ratio = ScaleRatio()
        local x, y = db.position.x, db.position.y
        -- Keep it on screen if the resolution or UI scale shrank since it was saved.
        if parent and parent.GetWidth then
            local pw, ph = parent:GetWidth() or 0, parent:GetHeight() or 0
            local w = (bagFrame:GetWidth() or 0) * ratio
            local h = (bagFrame:GetHeight() or 0) * ratio
            if pw > 0 and ph > 0 then
                x = math.max(0, math.min(x, math.max(0, pw - w)))
                y = math.min(ph, math.max(y, math.min(h, ph)))
            end
        end
        if bagFrame.SetClampedToScreen then bagFrame:SetClampedToScreen(true) end
        bagFrame:ClearAllPoints()
        bagFrame:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", x / ratio, y / ratio)
        appliedPoint = CapturePoints(bagFrame)
    elseif needsRestore then
        if blizzardPoints and #blizzardPoints > 0 then SetPoints(bagFrame, blizzardPoints) end
        appliedPoint = nil
    end
    needsRestore = false
end

-- ---------------------------------------------------------------------------
-- Dragging
-- ---------------------------------------------------------------------------

local function StartDrag()
    if not bagFrame or not db or db.locked or moving then return end
    if Blocked(bagFrame) then
        Print("the bags cannot be moved in combat.")
        return
    end
    if bagFrame.IsMovable and not bagFrame:IsMovable() and bagFrame.SetMovable then
        bagFrame:SetMovable(true)
    end
    if bagFrame.SetClampedToScreen then bagFrame:SetClampedToScreen(true) end
    bagFrame:StartMoving()
    moving = true
end

local function StopDrag()
    if not moving then return end
    moving = false
    bagFrame:StopMovingOrSizing()
    -- StartMoving marks the frame user-placed, which would make the client keep its own copy of
    -- the position in layout-local.txt. Ours lives in the saved variables instead.
    if bagFrame.SetUserPlaced then pcall(bagFrame.SetUserPlaced, bagFrame, false) end
    SavePosition()
    ApplyPosition()
end

local function UpdateDragHandle()
    if dragHandle then dragHandle:SetShown(not (db and db.locked)) end
end

-- An invisible handle over the title bar. The title is covered by Blizzard's portrait-menu
-- router button, so dragging needs its own surface on top. Locking hides the handle again,
-- which gives clicks on the title back to the bag menu.
local function CreateDragHandle()
    if dragHandle or not bagFrame then return end
    local handle = CreateFrame("Frame", nil, bagFrame)
    local title = bagFrame.TitleContainer
    if type(title) == "table" and title.GetFrameLevel then
        handle:SetPoint("TOPLEFT", title, "TOPLEFT", 0, 0)
        handle:SetPoint("BOTTOMRIGHT", title, "BOTTOMRIGHT", 0, 0)
        handle:SetFrameLevel(title:GetFrameLevel() + 1)
    else
        -- PortraitFrameBaseTemplate's title strip, relative to the frame itself.
        handle:SetPoint("TOPLEFT", bagFrame, "TOPLEFT", 58, -1)
        handle:SetPoint("TOPRIGHT", bagFrame, "TOPRIGHT", -24, -1)
        handle:SetHeight(20)
        handle:SetFrameLevel(bagFrame:GetFrameLevel() + 10)
    end
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", StartDrag)
    handle:SetScript("OnDragStop", StopDrag)
    handle:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_TOP")
        tip:SetText("Drag to move the bags")
        tip:AddLine("Alt-drag works anywhere on the frame. /bbf lock to lock, /bbf reset to reset.", 1, 1, 1, true)
        tip:Show()
    end)
    handle:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    dragHandle = handle
    UpdateDragHandle()
end

-- ---------------------------------------------------------------------------
-- Clean-up and the per-bag mirror
--
-- Left-click always runs Blizzard's own C_Container.SortBags, which decides which item goes in
-- which bag and slot. The separate bag frames show that result the way it is meant, and so does
-- the Combined Backpack with the "Reversed" order (SortBagsRightToLeft = false). The Combined
-- Backpack with the "Standard" order (true) does not: it draws every bag's slots in reverse, so
-- the order inside each bag reads backwards there.
--
-- In that one case the addon waits for Blizzard's sort to finish and then mirrors each bag:
-- slot i swaps with slot n+1-i. Which items are in which bag stays exactly as Blizzard left it;
-- only the order inside each bag is turned round.
--
--   wait:   poll every 0.1 s. Blizzard's sort counts as finished once no BAG_UPDATE,
--           BAG_UPDATE_DELAYED or ITEM_LOCK_CHANGED has arrived for about 1 s and no carried
--           slot is locked. After about 15 s it gives up and does not mirror.
--   mirror: at most one move per 0.05 s tick with C_Container.PickupContainerItem. The two
--           slots are re-read before every move and checked after it; two different stacks of
--           the same item are swapped through a free slot, so they can never merge.
-- ---------------------------------------------------------------------------

local WAIT_STEP = 0.1           -- seconds between polls while Blizzard's sort runs
local QUIET_TICKS = 10          -- polls without a bag event (about 1 s) before the sort counts as done
local MAX_WAIT_TICKS = 150      -- give up waiting for Blizzard's sort after about 15 s
local MIRROR_STEP = 0.05        -- seconds between mirror ticks; one move per tick at most
local MAX_MIRROR_TICKS = 2400   -- hard cap on ticks for one mirror (about 2 minutes)
local MAX_LOCK_WAIT = 100       -- ticks in a row spent waiting on locked items (about 5 s)
local MAX_REFUSALS = 5          -- the same move refused this many times in a row: give up
local UNCHANGED_GRACE = 4       -- ticks a move may look undone (and unlocked) before it counts as refused
local CARRIED_BAGS = { 0, 1, 2, 3, 4 }   -- backpack and the four bag slots; not keyring, not bank

local cleanupRun        -- the wait or mirror in progress, or nil
local runGeneration = 0

local function ContainerAPI()
    local c = _G.C_Container
    if type(c) == "table" then return c end
end

-- Modern C_Container first, then the old global of the same name.
local function ContainerFunction(name)
    local c = ContainerAPI()
    if c and type(c[name]) == "function" then return c[name] end
    if type(_G[name]) == "function" then return _G[name] end
end

local function TimerAfter()
    local timer = _G.C_Timer
    if type(timer) == "table" and type(timer.After) == "function" then return timer.After end
end

-- Everything the mirror needs to move items safely.
local function CanMirror()
    return ContainerFunction("PickupContainerItem") and ContainerFunction("GetContainerItemInfo")
        and ContainerFunction("GetContainerNumSlots") and type(_G.GetCursorInfo) == "function"
        and type(_G.ClearCursor) == "function" and TimerAfter() and true or false
end

-- Blizzard's sort order, read live: true is "Standard", false "Reversed", nil when unknown.
local function SortRightToLeft()
    local c = ContainerAPI()
    if c and type(c.GetSortBagsRightToLeft) == "function" then
        local ok, v = pcall(c.GetSortBagsRightToLeft)
        if ok then return v and true or false end
    end
end

-- The next left-click will mirror the bags after Blizzard's sort.
local function WillMirror()
    return UsingCombinedBags() and SortRightToLeft() == true and CanMirror()
end

local function NumSlots(bag)
    local fn = ContainerFunction("GetContainerNumSlots")
    if not fn then return 0 end
    local ok, n = pcall(fn, bag)
    return ok and tonumber(n) or 0
end

-- The item id the cursor holds, false when it holds something that is not an item, nil when empty.
local function CursorItem()
    local kind, id = _G.GetCursorInfo()
    if kind == nil then return nil end
    if kind == "item" then return id or false end
    return false
end

local function Pickup(bag, slot)
    local fn = ContainerFunction("PickupContainerItem")
    if fn then fn(bag, slot) end
end

-- One slot's content: key (the item link, so different suffixes or enchants never count as the
-- same item), itemID, count and locked; nil for an empty slot. The second return is true while
-- the slot is busy: locked, or holding something that cannot be identified yet.
local function ReadSlot(bag, slot)
    local c = ContainerAPI()
    local itemID, link, count, locked, present
    if c and type(c.GetContainerItemInfo) == "function" then
        local ok, info = pcall(c.GetContainerItemInfo, bag, slot)
        if not ok or type(info) ~= "table" then return nil, false end
        present = true
        itemID, link, count, locked = info.itemID, info.hyperlink, info.stackCount, info.isLocked
    elseif type(_G.GetContainerItemInfo) == "function" then
        local tex, n, l, _, _, _, h, _, _, id = _G.GetContainerItemInfo(bag, slot)
        if not tex then return nil, false end
        present = true
        itemID, link, count, locked = id, h, n, l
    end
    if not present then return nil, false end
    if not itemID and type(link) == "string" then itemID = tonumber(link:match("item:(%d+)")) end
    local key = link or (itemID and ("item:" .. itemID))
    if not key then return nil, true end
    local content = { key = key, itemID = itemID, count = tonumber(count) or 1, locked = locked and true or false }
    return content, content.locked
end

local function Identical(a, b)
    if a == nil or b == nil then return a == b end
    return a.key == b.key and a.count == b.count
end

-- Same item in both slots: dropping one on the other could merge the stacks instead of swapping.
local function SameItem(a, b)
    return a ~= nil and b ~= nil and (a.key == b.key or (a.itemID ~= nil and a.itemID == b.itemID))
end

-- Bags Blizzard's sort leaves alone are left alone here too: "Ignore on clean up" on a bag
-- (Enum.BagSlotFlags.DisableAutoSort) or on the backpack (GetBackpackAutosortDisabled).
local function SortedByBlizzard(bag)
    if NumSlots(bag) <= 0 then return false end
    local c = ContainerAPI()
    if not c then return true end
    if bag == 0 then
        if type(c.GetBackpackAutosortDisabled) == "function" then
            local ok, off = pcall(c.GetBackpackAutosortDisabled)
            if ok and off then return false end
        end
    else
        local flags = type(_G.Enum) == "table" and _G.Enum.BagSlotFlags
        local flag = type(flags) == "table" and flags.DisableAutoSort
        if flag and type(c.GetBagSlotFlag) == "function" then
            local ok, off = pcall(c.GetBagSlotFlag, bag, flag)
            if ok and off then return false end
        end
    end
    return true
end

-- Bag family: 0 for an ordinary bag, anything else for a soul, quiver, ammo or profession bag.
local function BagFamily(bag)
    local free = ContainerFunction("GetContainerNumFreeSlots")
    if free then
        local ok, _, family = pcall(free, bag)
        if ok and tonumber(family) then return tonumber(family) end
    end
    return 0
end

local function AnyCarriedSlotBusy()
    for _, bag in ipairs(CARRIED_BAGS) do
        for slot = 1, NumSlots(bag) do
            local _, busy = ReadSlot(bag, slot)
            if busy then return true end
        end
    end
    return false
end

-- Why a run stopped, worded for the phase it was in.
local function StopMessage(run, reason)
    if run.phase == "wait" then return "bags not mirrored: " .. reason end
    return string.format("mirror stopped after %d swaps: %s", run.swaps, reason)
end

-- Stops the running clean-up. The cursor is cleared only when it holds the item this addon
-- picked up; anything else on it belongs to the player.
local function StopRun(message)
    local run = cleanupRun
    if not run then return false end
    cleanupRun = nil
    if run.holding ~= nil then
        -- Also reached from the error path, so the cursor check itself must not raise.
        local ok, held = pcall(CursorItem)
        if ok and held == run.holding then pcall(_G.ClearCursor) end
    end
    if message then Print(message) end
    return true
end

-- A free slot to park one stack in while two stacks of the same item trade places: the same
-- bag first (any item fits its own bag), else an ordinary bag that is being mirrored too.
local function FindTempSlot(run, bag, a, b)
    local function freeIn(where, skipA, skipB)
        for slot = 1, NumSlots(where) do
            if slot ~= skipA and slot ~= skipB then
                local content, busy = ReadSlot(where, slot)
                if not content and not busy then return { bag = where, slot = slot } end
            end
        end
    end
    local spot = freeIn(bag, a, b)
    if spot then return spot end
    for _, other in ipairs(run.bags) do
        if other ~= bag and BagFamily(other) == 0 then
            spot = freeIn(other)
            if spot then return spot end
        end
    end
end

-- The moves for the next pair that needs any. Returns "ready", "busy" (a slot of the pair is
-- locked; try again next tick) or "done" (every pair handled).
local function PreparePair(run)
    while run.index <= #run.pairs do
        local p = run.pairs[run.index]
        local A, B = { bag = p.bag, slot = p.a }, { bag = p.bag, slot = p.b }
        local a, busyA = ReadSlot(A.bag, A.slot)
        local b, busyB = ReadSlot(B.bag, B.slot)
        if busyA or busyB then return "busy" end
        run.index = run.index + 1
        if not Identical(a, b) then
            if not a then
                run.steps = { { from = B, to = A, intoEmpty = true } }
            elseif not b then
                run.steps = { { from = A, to = B, intoEmpty = true } }
            elseif SameItem(a, b) then
                local T = FindTempSlot(run, p.bag, p.a, p.b)
                if T then
                    run.steps = { { from = A, to = T, intoEmpty = true }, { from = B, to = A, intoEmpty = true },
                                  { from = T, to = B, intoEmpty = true } }
                else
                    run.skipped = run.skipped + 1
                end
            else
                run.steps = { { from = A, to = B } }
            end
            if #run.steps > 0 then return "ready" end
        end
    end
    return "done"
end

-- Picks the item up from one slot and puts it on the other: a move into an empty slot, or a
-- swap with a different item. Returns "issued", "refused" (nothing was picked up), "changed"
-- (the slots no longer hold what this move is for) or "cursor".
local function IssueStep(run, step)
    local from = ReadSlot(step.from.bag, step.from.slot)
    local to = ReadSlot(step.to.bag, step.to.slot)
    if not from or (step.intoEmpty and to) or SameItem(from, to) then return "changed" end
    step.before = { from = from, to = to }
    Pickup(step.from.bag, step.from.slot)
    local held = CursorItem()
    if held == nil then return "refused" end
    if held == false then return "cursor" end
    run.holding = held
    Pickup(step.to.bag, step.to.slot)
    -- Anything of ours still on the cursor goes back where it came from.
    if CursorItem() == held then Pickup(step.from.bag, step.from.slot) end
    if CursorItem() == held then _G.ClearCursor() end
    run.holding = nil
    run.moves = run.moves + 1
    run.pending = step
    run.unchanged = 0
    return "issued"
end

-- The result of the last move: "busy", "done", "unchanged" (the client refused it) or "changed".
local function CheckPending(run)
    local step = run.pending
    local from, busyFrom = ReadSlot(step.from.bag, step.from.slot)
    local to, busyTo = ReadSlot(step.to.bag, step.to.slot)
    if busyFrom or busyTo then return "busy" end
    if Identical(to, step.before.from) and Identical(from, step.before.to) then return "done" end
    if Identical(from, step.before.from) and Identical(to, step.before.to) then return "unchanged" end
    return "changed"
end

local function WaitOnLocks(run)
    run.lockWait = run.lockWait + 1
    if run.lockWait > MAX_LOCK_WAIT then StopRun(StopMessage(run, "items stayed locked.")) end
end

local function Refused(run)
    run.refusals = run.refusals + 1
    if run.refusals >= MAX_REFUSALS then StopRun(StopMessage(run, "the client keeps refusing a move.")) end
end

local function MirrorStep(run)
    run.ticks = run.ticks + 1
    if run.ticks > MAX_MIRROR_TICKS or run.moves > run.maxMoves then
        StopRun(StopMessage(run, "safety limit."))
        return
    end
    if CursorItem() ~= nil then
        StopRun(StopMessage(run, "the cursor is holding something."))
        return
    end

    if run.pending then
        local state = CheckPending(run)
        if state == "busy" then return WaitOnLocks(run) end
        run.lockWait = 0
        if state == "unchanged" then
            -- Give the client a moment to show the move before trying it again; retrying a
            -- move that is merely slow to appear would undo it.
            run.unchanged = run.unchanged + 1
            if run.unchanged < UNCHANGED_GRACE then return end
            run.pending = nil
            return Refused(run)          -- the same move is tried again next tick
        elseif state == "changed" then
            StopRun(StopMessage(run, "the bags changed."))
            return
        end
        run.pending = nil
        run.refusals = 0
        table.remove(run.steps, 1)
        if #run.steps == 0 then run.swaps = run.swaps + 1 end
    end

    if #run.steps == 0 then
        local state = PreparePair(run)
        if state == "busy" then return WaitOnLocks(run) end
        if state == "done" then
            local msg = string.format("Bags mirrored (%d swaps).", run.swaps)
            if run.skipped > 0 then
                msg = msg .. string.format(" %d pair(s) of the same item were left as they were (no free slot to swap through).", run.skipped)
            end
            StopRun(msg)
            return
        end
    end

    local step = run.steps[1]
    local _, busyFrom = ReadSlot(step.from.bag, step.from.slot)
    local _, busyTo = ReadSlot(step.to.bag, step.to.slot)
    if busyFrom or busyTo then return WaitOnLocks(run) end
    run.lockWait = 0
    local result = IssueStep(run, step)
    if result == "refused" then
        Refused(run)
    elseif result == "changed" then
        StopRun(StopMessage(run, "the bags changed."))
    elseif result == "cursor" then
        StopRun(StopMessage(run, "the cursor picked up something unexpected."))
    end
end

-- Blizzard's sort has settled: plan the pairs from what the bags hold now and start moving.
local function StartMirror(run)
    if CursorItem() ~= nil then
        StopRun(StopMessage(run, "the cursor is holding something."))
        return
    end
    run.bags, run.pairs = {}, {}
    for _, bag in ipairs(CARRIED_BAGS) do
        if SortedByBlizzard(bag) then
            run.bags[#run.bags + 1] = bag
            local n = NumSlots(bag)
            for i = 1, math.floor(n / 2) do
                local a, b = ReadSlot(bag, i), ReadSlot(bag, n + 1 - i)
                if not Identical(a, b) then
                    run.pairs[#run.pairs + 1] = { bag = bag, a = i, b = n + 1 - i }
                end
            end
        end
    end
    run.phase = "mirror"
    run.ticks, run.index, run.steps = 0, 1, {}
    run.maxMoves = 6 * #run.pairs + 20     -- up to three moves per pair, plus retries
end

local function WaitStep(run)
    run.ticks = run.ticks + 1
    if run.activity then
        run.activity = false
        run.quiet = 0
    else
        run.quiet = run.quiet + 1
    end
    if run.quiet >= QUIET_TICKS and not AnyCarriedSlotBusy() then
        StartMirror(run)
    elseif run.ticks >= MAX_WAIT_TICKS then
        StopRun("Blizzard's sort did not finish within 15 s, so the bags were not mirrored.")
    end
end

local RunTick
local function ScheduleTick(run)
    local generation = run.generation
    TimerAfter()(run.phase == "wait" and WAIT_STEP or MIRROR_STEP, function() RunTick(generation) end)
end

RunTick = function(generation)
    local run = cleanupRun
    if not run or run.generation ~= generation then return end
    if InCombat() then
        StopRun(StopMessage(run, "combat."))
        return
    end
    local ok, err = pcall(run.phase == "wait" and WaitStep or MirrorStep, run)
    if not ok then
        StopRun(StopMessage(run, "an error: " .. tostring(err)))
        return
    end
    if cleanupRun == run then ScheduleTick(run) end
end

local function PlaySortSound()
    local soundkit = _G.SOUNDKIT
    if type(_G.PlaySound) == "function" and type(soundkit) == "table" and soundkit.UI_BAG_SORTING_01 then
        _G.PlaySound(soundkit.UI_BAG_SORTING_01)
    end
end

-- Left-click: Blizzard's sort, then the mirror when the Combined Backpack is in use with the
-- Standard order. Separate bags and the Reversed order get Blizzard's sort and nothing else.
local function CleanUpBags()
    if cleanupRun then
        Print("a clean-up is still running; /bbf stop stops it.")
        return false
    end
    if InCombat() then
        Print("bags cannot be cleaned up in combat.")
        return false
    end
    local sort = GetSortFunction()
    if not sort then
        Print("this client has no C_Container.SortBags.")
        return false
    end
    local mirror = WillMirror()
    PlaySortSound()
    sort()
    if mirror then
        runGeneration = runGeneration + 1
        cleanupRun = { generation = runGeneration, phase = "wait", ticks = 0, quiet = 0, activity = false,
                       swaps = 0, moves = 0, lockWait = 0, refusals = 0, skipped = 0, unchanged = 0 }
        ScheduleTick(cleanupRun)
    end
    return true
end

-- A bag event while Blizzard's sort runs: it is not finished yet.
local function OnBagActivity()
    if cleanupRun and cleanupRun.phase == "wait" then cleanupRun.activity = true end
end

-- ---------------------------------------------------------------------------
-- Clean-up button and search row
-- ---------------------------------------------------------------------------

local function SetCombatLook(inCombat)
    if not cleanupButton then return end
    local tex = cleanupButton:GetNormalTexture()
    if tex and tex.SetDesaturated then tex:SetDesaturated(inCombat) end
end

-- Read live every time: Blizzard's bag menu can change the same setting behind our back.
-- "Standard" is SortBagsRightToLeft = true, what Forever's own Clean Up uses by default;
-- "Reversed" is false.
local function LabelFor(rightToLeft) return rightToLeft and "Standard" or "Reversed" end

local function DirectionLabel()
    if not GetDirectionFunctions() then return nil end
    return LabelFor(SortRightToLeft())
end

-- A sort order change the client has not confirmed yet: { target, generation }.
-- SetSortBagsRightToLeft may apply a moment later (it is account data) or not at all, so the
-- requested value is never shown anywhere; only what GetSortBagsRightToLeft returns.
local directionChange
local directionGeneration = 0
local DIRECTION_CHECKS = { 0.2, 0.3, 0.5 }   -- re-read 0.2 s, 0.5 s and 1 s after the change

local ShowCleanupTooltip

-- Redraws the clean-up tooltip if it is showing, so it follows the live sort order.
local function RefreshCleanupTooltip()
    local tip = _G.GameTooltip
    if cleanupButton and tip and tip:IsShown() and tip.GetOwner and tip:GetOwner() == cleanupButton then
        ShowCleanupTooltip(cleanupButton)
    end
end

local function ConfirmDirection(generation, attempt)
    local change = directionChange
    if not change or change.generation ~= generation then return end
    local now = SortRightToLeft()
    if now == change.target then
        directionChange = nil
        Print("Sort order: " .. LabelFor(now))
    elseif attempt >= #DIRECTION_CHECKS then
        directionChange = nil
        Print("Could not change the sort order (still: " .. LabelFor(now) .. ").")
    else
        TimerAfter()(DIRECTION_CHECKS[attempt + 1], function() ConfirmDirection(generation, attempt + 1) end)
    end
    RefreshCleanupTooltip()
end

-- Sets the sort order (true = Standard, false = Reversed), or flips the live value when
-- rightToLeft is nil. Only a client setting changes, nothing moves, so this is allowed in combat.
-- While a change is unconfirmed further requests are refused, so rapid right-clicks can never
-- toggle from a value the client does not actually have.
local function SetSortDirection(rightToLeft)
    local get, set = GetDirectionFunctions()
    if not get then
        Print("this client has no C_Container.SetSortBagsRightToLeft.")
        return false
    end
    if directionChange then
        Print("the sort order is still changing (now: " .. LabelFor(SortRightToLeft()) .. "); try again in a moment.")
        return false
    end
    if rightToLeft == nil then rightToLeft = not SortRightToLeft() end
    rightToLeft = rightToLeft and true or false
    set(rightToLeft)
    local now = SortRightToLeft()
    if now == rightToLeft then
        Print("Sort order: " .. LabelFor(now))
    elseif TimerAfter() then
        directionGeneration = directionGeneration + 1
        directionChange = { target = rightToLeft, generation = directionGeneration }
        local generation = directionGeneration
        TimerAfter()(DIRECTION_CHECKS[1], function() ConfirmDirection(generation, 1) end)
    else
        Print("Could not change the sort order (still: " .. LabelFor(now) .. ").")
    end
    RefreshCleanupTooltip()
    return true
end

ShowCleanupTooltip = function(self)
    local tip = _G.GameTooltip
    if not tip then return end
    local title = _G.BAG_CLEANUP_BAGS or "Clean Up Bags"
    tip:SetOwner(self, "ANCHOR_RIGHT")
    if type(_G.GameTooltip_SetTitle) == "function" then
        _G.GameTooltip_SetTitle(tip, title, _G.HIGHLIGHT_FONT_COLOR)
    else
        tip:SetText(title, 1, 1, 1)
    end
    if type(_G.BAG_CLEANUP_BAGS_DESCRIPTION) == "string" then
        tip:AddLine(_G.BAG_CLEANUP_BAGS_DESCRIPTION, nil, nil, nil, true)
    end
    tip:AddLine("Left-click: clean up bags", 0, 1, 0)
    tip:AddLine("In the Combined Backpack with Standard order, each bag is mirrored after sorting, so it reads the right way round.", 1, 1, 1, true)
    local short = DirectionLabel()
    if short then
        tip:AddLine("Right-click: switch sort order (now: " .. short .. ")", 0, 1, 0)
        if directionChange then
            tip:AddLine("Waiting for the client to confirm the change.", 0.7, 0.7, 0.7, true)
        end
    end
    tip:Show()
end

local function OnCleanupClick(self, button)
    if button == "RightButton" then
        if GetDirectionFunctions() then SetSortDirection(nil) end
        return
    end
    CleanUpBags()
end

local function CreateCleanupButton()
    if cleanupButton or not bagFrame or not GetSearchBox() then return end
    if not GetSortFunction() then return end
    local b = CreateFrame("Button", "BetterBagsForeverCleanUpButton", bagFrame)
    b:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
    if b.SetNormalAtlas and HasAtlas(ATLAS_UP) then
        b:SetNormalAtlas(ATLAS_UP)
        b:SetPushedAtlas(HasAtlas(ATLAS_DOWN) and ATLAS_DOWN or ATLAS_UP)
    else
        b:SetNormalTexture(FALLBACK_ICON)
        b:SetPushedTexture(FALLBACK_ICON)
    end
    b:SetHighlightTexture(HIGHLIGHT, "ADD")
    local highlight = b:GetHighlightTexture()
    if highlight then
        highlight:ClearAllPoints()
        highlight:SetSize(24, 23)
        highlight:SetPoint("CENTER", b, "CENTER", 0, 0)
    end
    if b.RegisterForClicks then b:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    b:SetScript("OnClick", OnCleanupClick)
    b:SetScript("OnEnter", ShowCleanupTooltip)
    b:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    b:Hide()
    cleanupButton = b
    SetCombatLook(InCombat())
end

-- The native button on the right is left alone unless the player asked for it to go.
local function UpdateNativeButton(owned)
    local native = GetNativeSortButton()
    if not native or not db or native:GetParent() ~= bagFrame then return end
    if db.hideNativeButton then
        if native:IsShown() then
            native:Hide()
            nativeHidden = true
        end
    elseif nativeHidden then
        nativeHidden = false
        if owned then native:Show() end
    end
end

-- Moves the search box right by the button's width and narrows it by the same amount, so its
-- right end stays put, then hangs the button off its left edge. Everything is relative to the
-- anchor Blizzard just gave the box, so a different client layout shifts the same way.
local function ShiftSearchBox(box)
    local points = CapturePoints(box)
    if #points == 0 then return end
    local width = box:GetWidth() or 0
    box:ClearAllPoints()
    if #points == 1 then
        local p = points[1]
        local dx
        if p[1]:find("LEFT") then
            dx = SEARCH_SHIFT
        elseif p[1]:find("RIGHT") then
            dx = 0
        else
            dx = SEARCH_SHIFT / 2
        end
        box:SetPoint(p[1], p[2], p[3], p[4] + dx, p[5])
        box:SetWidth(math.max(MIN_SEARCH_WIDTH, width - SEARCH_SHIFT))
    else
        for _, p in ipairs(points) do
            local dx = p[1]:find("LEFT") and SEARCH_SHIFT or 0
            box:SetPoint(p[1], p[2], p[3], p[4] + dx, p[5])
        end
    end
    searchLayout = { points = CapturePoints(box), width = box:GetWidth() }
end

local function LayoutSearchRow()
    if not bagFrame then return end
    local box = GetSearchBox()
    if not box then return end
    local owned = box:GetParent() == bagFrame
    UpdateNativeButton(owned)
    if not cleanupButton then return end
    if not owned then
        cleanupButton:Hide()
        searchLayout = nil
        return
    end
    if Blocked(box) then
        pendingApply = true
        return
    end
    -- Only shift once per placement by Blizzard; a second pass would push it further right.
    local current = CapturePoints(box)
    if not (searchLayout and SamePoints(current, searchLayout.points) and Near(box:GetWidth(), searchLayout.width)) then
        ShiftSearchBox(box)
    end
    cleanupButton:ClearAllPoints()
    cleanupButton:SetPoint("RIGHT", box, "LEFT", -BUTTON_GAP, 0)
    cleanupButton:SetShown(box:IsShown())
end

-- ---------------------------------------------------------------------------
-- Following Blizzard
-- ---------------------------------------------------------------------------

-- Runs after UpdateContainerFrameAnchors. Blizzard has just put every open bag at its default
-- spot; remember where the combined frame went (for /bbf reset), then put it back where the
-- player wants it. Separate bags are never touched.
local function OnBlizzardAnchored()
    if not bagFrame or not bagFrame:IsShown() or not UsingCombinedBags() then return end
    local points = CapturePoints(bagFrame)
    if #points > 0 and not SamePoints(points, appliedPoint) then
        blizzardPoints = points
        appliedPoint = nil
        needsRestore = false
    end
    ApplyPosition()
    LayoutSearchRow()
end

local function OnBagFrameShown()
    ApplyPosition()
    LayoutSearchRow()
end

local function OnBagFrameHidden()
    if moving then StopDrag() end
end

-- Alt-drag anywhere on the frame's own surface. Item buttons keep their own drag (picking up the
-- item), so this only fires on the border, the background and the empty strips.
local function OnBagFrameDragStart()
    local alt = type(_G.IsAltKeyDown) == "function" and _G.IsAltKeyDown()
    if alt then StartDrag() end
end

local function HookBlizzard()
    if not anchorsHooked and type(_G.UpdateContainerFrameAnchors) == "function" then
        hooksecurefunc("UpdateContainerFrameAnchors", OnBlizzardAnchored)
        anchorsHooked = true
    end

    if frameHooked then return true end
    bagFrame = GetBagFrame()
    if not bagFrame then return false end
    frameHooked = true

    bagFrame:HookScript("OnShow", OnBagFrameShown)
    bagFrame:HookScript("OnHide", OnBagFrameHidden)
    if bagFrame.RegisterForDrag then
        bagFrame:RegisterForDrag("LeftButton")
        bagFrame:HookScript("OnDragStart", OnBagFrameDragStart)
        bagFrame:HookScript("OnDragStop", StopDrag)
    end
    -- UpdateSearchBox is where Blizzard re-parents and re-anchors the search box and the native
    -- sort button; following it keeps our shift and button in step.
    if type(bagFrame.UpdateSearchBox) == "function" then
        hooksecurefunc(bagFrame, "UpdateSearchBox", LayoutSearchRow)
    end

    CreateDragHandle()
    CreateCleanupButton()
    if bagFrame:IsShown() then OnBagFrameShown() end
    return true
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function Yes(v) return v and "yes" or "MISSING" end

local function PrintHelp()
    Print("the Combined Backpack is movable: drag its title bar, or Alt-drag an empty part of it.")
    Print("/bbf reset - put the bags back at Blizzard's default position")
    Print("/bbf lock | /bbf unlock - stop or allow moving (now: " .. ((db and db.locked) and "locked" or "unlocked") .. ")")
    Print("/bbf native hide | /bbf native show - hide or show Blizzard's own clean-up button (now: " .. ((db and db.hideNativeButton) and "hidden" or "shown") .. ")")
    Print("Clean Up button: left-click = Blizzard's clean-up; in the Combined Backpack with Standard order each bag is then mirrored. Right-click = switch the sort order.")
    local label = DirectionLabel()
    if label then
        Print("/bbf direction - switch the sort order; /bbf direction standard | reversed to set it (now: " .. label .. ")")
    end
    Print("/bbf stop - stop a running mirror")
    Print("/bbf status - what this client offers and what the next clean-up will do")
end

local function PrintStatus()
    Print("ContainerFrameCombinedBags: " .. Yes(GetBagFrame()))
    Print("BagItemSearchBox: " .. Yes(_G.BagItemSearchBox))
    Print("BagItemAutoSortButton: " .. Yes(GetNativeSortButton()))
    Print("C_Container.SortBags: " .. Yes(GetSortFunction()))
    Print("C_Container.Get/SetSortBagsRightToLeft: " .. Yes(GetDirectionFunctions()))
    Print("mirror (PickupContainerItem, GetCursorInfo, C_Timer): " .. Yes(CanMirror()))
    Print("combined bags in use: " .. (UsingCombinedBags() and "yes" or "no"))
    Print("sort order: " .. (DirectionLabel() or "unknown")
        .. (directionChange and " (a change is waiting for the client to confirm it)" or ""))
    Print("next clean-up: " .. (WillMirror() and "Blizzard's sort, then each bag mirrored" or "Blizzard's sort only"))
    if cleanupRun then
        Print(cleanupRun.phase == "wait" and "running: waiting for Blizzard's sort to finish"
            or string.format("running: mirroring, %d swaps so far", cleanupRun.swaps))
    end
    Print("UpdateContainerFrameAnchors: " .. Yes(type(_G.UpdateContainerFrameAnchors) == "function"))
    local pos = db and db.position
    Print("saved position: " .. (pos and string.format("%.0f, %.0f", pos.x, pos.y) or "none (Blizzard default)"))
end

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    if msg == "reset" then
        db.position = nil
        needsRestore = true
        ApplyPosition()
        Print(pendingApply and "position reset; it moves back once combat ends."
            or "position reset to Blizzard's default.")
    elseif msg == "lock" then
        db.locked = true
        UpdateDragHandle()
        Print("bags locked.")
    elseif msg == "unlock" then
        db.locked = false
        UpdateDragHandle()
        Print("bags unlocked: drag the title bar to move them.")
    elseif msg == "native hide" or msg == "native show" then
        db.hideNativeButton = (msg == "native hide")
        LayoutSearchRow()
        Print("Blizzard's own clean-up button is " .. (db.hideNativeButton and "hidden." or "shown."))
    elseif msg == "direction" then
        SetSortDirection(nil)
    elseif msg == "direction standard" or msg == "direction rtl" then
        SetSortDirection(true)
    elseif msg == "direction reversed" or msg == "direction ltr" then
        SetSortDirection(false)
    elseif msg == "stop" then
        if not (cleanupRun and StopRun(StopMessage(cleanupRun, "stopped."))) then
            Print("nothing is running.")
        end
    elseif msg == "status" then
        PrintStatus()
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterBagsForeverDB) ~= "table" then BetterBagsForeverDB = {} end
    db = BetterBagsForeverDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    db.mode = nil       -- left over from 1.1's visual sort, which is gone
    local pos = db.position
    if pos ~= nil and (type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number") then
        db.position = nil
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("BAG_UPDATE")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("ITEM_LOCK_CHANGED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED" or event == "ITEM_LOCK_CHANGED" then
        OnBagActivity()
    elseif event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            BindSavedVariables()
            HookBlizzard()
        elseif db and not frameHooked then
            -- In case the bag frames arrive with a Blizzard addon loaded after us.
            HookBlizzard()
        end
    elseif event == "PLAYER_LOGIN" then
        if db then HookBlizzard() end
    elseif event == "PLAYER_REGEN_DISABLED" then
        SetCombatLook(true)
        if cleanupRun then StopRun(StopMessage(cleanupRun, "combat.")) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        SetCombatLook(false)
        if pendingApply then
            pendingApply = false
            ApplyPosition()
            LayoutSearchRow()
        end
    end
end)

SLASH_BETTERBAGSFOREVER1 = "/bbf"
SLASH_BETTERBAGSFOREVER2 = "/betterbagsforever"
SlashCmdList.BETTERBAGSFOREVER = OnSlash
