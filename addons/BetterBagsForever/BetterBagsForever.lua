--[[
  BetterBagsForever - small fixes for the native "Combined Backpack" on WoW Forever.

  Forever ships the retail-style combined bag frame (ContainerFrameCombinedBags). This addon
  changes these things about it and nothing else:

    * The frame can be moved: drag its title bar, or Alt-drag any empty part of it. The position
      is saved in BetterBagsForeverDB and put back every time Blizzard re-anchors the bags.
    * A "Clean Up Bags" button sits on the left of the search box, because on Forever the native
      one (BagItemAutoSortButton) ends up hidden under the bag slot icons on the right.
      Left-click runs this addon's own "visual" sort (below); Shift+left-click runs the other one
      (Blizzard's C_Container.SortBags by default; /bbf mode swaps the two). Right-clicking it
      switches Blizzard's sort order (C_Container.SetSortBagsRightToLeft), the same client setting
      Blizzard's own bag menu changes.
    * The visual sort orders the carried bags by what the player actually sees: it reads where
      each item button sits on screen, so the first slot is the top-left one and junk ends up in
      the bottom-right corner, in the Combined Backpack (which draws every bag's slots in reverse)
      as well as in the separate bag frames. Items are moved one at a time with
      C_Container.PickupContainerItem, out of combat only.
    * /bbf for help, reset, lock, unlock, direction, mode, sort and stop.

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
    mode = "visual",        -- what a plain left-click on Clean Up does: "visual" or "blizzard"
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
-- Visual sort
--
-- Blizzard's C_Container.SortBags fills the bags in bag/slot order. The separate bag frames show
-- that order the way it is meant, but the Combined Backpack draws every bag's slots in reverse,
-- so a sorted bag reads backwards there. SetSortBagsRightToLeft is one global switch: it can fix
-- the order of the bags or the order inside them, never both.
--
-- This sort does not assume any layout. It reads where each item button is on screen, puts the
-- carried-bag slots in reading order (top to bottom, left to right), works out where every item
-- should go, and then moves items one at a time until each slot holds what the plan says:
--
--   1. merge partial stacks (later stack onto the earlier one), one move per tick;
--   2. plan: equipment, consumables, trade goods, quest items, the rest, packed from the top-left;
--      junk (grey with a sell value) packed into the bottom-right corner;
--   3. place: for the first slot that is wrong, swap in an item that belongs there, preferring
--      one whose own slot wants what is here now (that fixes two slots in one swap).
--
-- Every tick re-reads the live bags, so a slot the server changed meanwhile (loot, a consumed
-- stack) is never acted on blindly; if the plan no longer fits the bags, it is made again.
-- ---------------------------------------------------------------------------

local SORT_STEP = 0.05          -- seconds between ticks; one move per tick at most
local MAX_TICKS = 1500          -- hard cap on ticks for one sort (about 75 s)
local MAX_LOCK_WAIT = 100       -- ticks in a row spent waiting on locked items (about 5 s)
local MAX_STUCK = 6             -- the same move chosen with nothing changing: it is being refused
local MAX_REPLANS = 3           -- the bags changed under the plan this many times: give up
local MIN_ROW_TOLERANCE = 4     -- screen units; buttons closer than this vertically share a row
local CARRIED_BAGS = { 0, 1, 2, 3, 4 }   -- backpack and the four bag slots; not keyring, not bank

-- Groups in the order they are laid out. Item classes are Enum.ItemClass numbers, which have been
-- the same since Classic: 0 consumable, 1 container, 2 weapon, 3 gem, 4 armor, 5 reagent,
-- 6 projectile, 7 trade goods, 8 item enhancement, 9 recipe, 11 quiver, 12 quest, 13 key,
-- 15 miscellaneous, 19 profession. Anything else, or an item whose class is not known yet,
-- goes in the "rest" group.
local GROUP_EQUIPMENT, GROUP_CONSUMABLE, GROUP_TRADE, GROUP_QUEST, GROUP_REST, GROUP_JUNK = 1, 2, 3, 4, 5, 6
local CLASS_GROUP = {
    [2] = GROUP_EQUIPMENT, [4] = GROUP_EQUIPMENT,
    [0] = GROUP_CONSUMABLE, [6] = GROUP_CONSUMABLE,
    [3] = GROUP_TRADE, [5] = GROUP_TRADE, [7] = GROUP_TRADE, [8] = GROUP_TRADE, [9] = GROUP_TRADE,
    [19] = GROUP_TRADE,
    [12] = GROUP_QUEST,
}

local sortRun           -- the sort in progress, or nil
local sortGeneration = 0

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

local function ItemFunction(name)
    local item = _G.C_Item
    if type(item) == "table" and type(item[name]) == "function" then return item[name] end
    if type(_G[name]) == "function" then return _G[name] end
end

local function TimerAfter()
    local timer = _G.C_Timer
    if type(timer) == "table" and type(timer.After) == "function" then return timer.After end
end

-- Everything the visual sort needs to move items safely.
local function CanVisualSort()
    return ContainerFunction("PickupContainerItem") and ContainerFunction("GetContainerItemInfo")
        and ContainerFunction("GetContainerNumSlots") and type(_G.GetCursorInfo) == "function"
        and type(_G.ClearCursor) == "function" and TimerAfter() and true or false
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
-- same item), itemID, count, locked, quality, noValue. nil for an empty slot. The second return
-- is true for a slot that holds something that cannot be identified yet.
local function SlotContent(bag, slot)
    local c = ContainerAPI()
    local itemID, link, count, locked, quality, noValue, present
    if c and type(c.GetContainerItemInfo) == "function" then
        local ok, info = pcall(c.GetContainerItemInfo, bag, slot)
        if not ok or type(info) ~= "table" then return nil end
        present = true
        itemID, link, count, locked = info.itemID, info.hyperlink, info.stackCount, info.isLocked
        quality, noValue = info.quality, info.hasNoValue
    elseif type(_G.GetContainerItemInfo) == "function" then
        local tex, n, l, q, _, _, h, _, nv, id = _G.GetContainerItemInfo(bag, slot)
        if not tex then return nil end
        present = true
        itemID, link, count, locked, quality, noValue = id, h, n, l, q, nv
    end
    if not present then return nil end
    if not itemID and type(link) == "string" then itemID = tonumber(link:match("item:(%d+)")) end
    local key = link or (itemID and ("item:" .. itemID))
    if not key then return nil, true end
    return { key = key, itemID = itemID, link = link, count = tonumber(count) or 1,
             locked = locked and true or false, quality = quality, noValue = noValue }
end

-- Reads every slot in the list. Returns the contents (index -> content or nil), whether any of
-- them is locked, and whether any could not be read.
local function ReadSlots(slots)
    local contents, anyLocked, unreadable = {}, false, false
    for i, s in ipairs(slots) do
        local content, unknown = SlotContent(s.bag, s.slot)
        contents[i] = content
        if content and content.locked then anyLocked = true end
        if unknown then unreadable = true end
    end
    return contents, anyLocked, unreadable
end

local function RequestItem(itemID)
    if not itemID then return end
    local item = _G.C_Item
    if type(item) == "table" and type(item.RequestLoadItemDataByID) == "function" then
        pcall(item.RequestLoadItemDataByID, itemID)
    end
end

-- Name, quality, item level, stack size, sell price and class, from whatever the client has.
-- Item data that is not cached yet is requested and the instant (always local) info is used;
-- only complete answers are remembered, so a later tick picks up what has arrived.
local function ItemDetails(content, cache)
    local known = cache[content.key]
    if known then return known end
    local d = {}
    local info = ItemFunction("GetItemInfo")
    if info then
        local ok, name, _, quality, ilvl, _, _, _, maxStack, _, _, sellPrice, classID =
            pcall(info, content.link or content.itemID)
        if ok and name then
            d.name, d.quality, d.ilvl, d.maxStack, d.sellPrice, d.classID =
                name, quality, ilvl, maxStack, sellPrice, classID
        end
    end
    local complete = d.name ~= nil
    if not complete then RequestItem(content.itemID) end
    if d.classID == nil then
        local instant = ItemFunction("GetItemInfoInstant")
        if instant then
            local ok, _, _, _, _, _, classID = pcall(instant, content.itemID or content.link)
            if ok then d.classID = classID end
        end
    end
    if d.maxStack == nil and content.itemID then
        local stackSize = ItemFunction("GetItemMaxStackSizeByID")
        if stackSize then
            local ok, n = pcall(stackSize, content.itemID)
            if ok then d.maxStack = n end
        end
    end
    d.name = d.name or (content.link and content.link:match("%[(.-)%]")) or ""
    if complete then cache[content.key] = d end
    return d
end

local function IsQuestItem(bag, slot)
    local fn = ContainerFunction("GetContainerItemQuestInfo")
    if not fn then return false end
    local ok, a, b = pcall(fn, bag, slot)
    if not ok then return false end
    if type(a) == "table" then return (a.isQuestItem or a.questID) and true or false end
    return (a or b) and true or false
end

-- "Ignore on clean up" (the client's own flag, the one Blizzard's sort obeys) and specialty
-- bags (soul, quiver, ammo, profession: a bag family other than 0), which only take some items
-- and are left exactly as they are.
local function BagSortable(bag)
    if NumSlots(bag) <= 0 then return false end
    local c = ContainerAPI()
    if c then
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
    end
    local free = ContainerFunction("GetContainerNumFreeSlots")
    if free then
        local ok, _, family = pcall(free, bag)
        if ok and family and family ~= 0 then return false end
    end
    return true
end

-- The open bag frames: the combined one, the separate ContainerFrameN, and anything listed in
-- retail's ContainerFrameContainer.ContainerFrames.
local function BagFrames()
    local frames, seen = {}, {}
    local function add(f)
        if type(f) == "table" and not seen[f] and type(f.IsVisible) == "function" then
            seen[f] = true
            frames[#frames + 1] = f
        end
    end
    add(_G.ContainerFrameCombinedBags)
    local holder = _G.ContainerFrameContainer
    if type(holder) == "table" and type(holder.ContainerFrames) == "table" then
        for _, f in ipairs(holder.ContainerFrames) do add(f) end
    end
    for i = 1, tonumber(_G.NUM_CONTAINER_FRAMES) or 13 do add(_G["ContainerFrame" .. i]) end
    return frames
end

-- Every item button a frame may hold, from each place retail and classic FrameXML keep them.
-- Duplicates are fine; the caller keeps the first visible button per slot.
local function EachItemButton(frame, visit)
    if type(frame.Items) == "table" then
        for _, b in ipairs(frame.Items) do visit(b) end
    end
    if type(frame.EnumerateValidItems) == "function" then
        pcall(function()
            for _, b in frame:EnumerateValidItems() do visit(b) end
        end)
    end
    local name = type(frame.GetName) == "function" and frame:GetName()
    if name then
        for i = 1, tonumber(_G.MAX_CONTAINER_ITEMS) or 36 do visit(_G[name .. "Item" .. i]) end
    end
    if type(frame.GetChildren) == "function" then
        for _, child in ipairs({ frame:GetChildren() }) do
            if type(child) == "table" and type(child.GetBagID) == "function" then visit(child) end
        end
    end
end

-- Bag and slot of an item button: GetBagID() on retail's ContainerFrameItemButtonMixin, else the
-- parent frame's ID (classic FrameXML); the slot is the button's own ID.
local function ButtonBagSlot(b)
    if type(b) ~= "table" or type(b.GetID) ~= "function" then return nil end
    local bag
    if type(b.GetBagID) == "function" then
        local ok, v = pcall(b.GetBagID, b)
        if ok then bag = v end
    end
    if bag == nil then bag = b.bagID end
    if bag == nil and type(b.GetParent) == "function" then
        local parent = b:GetParent()
        if type(parent) == "table" and type(parent.GetID) == "function" then bag = parent:GetID() end
    end
    return tonumber(bag), tonumber(b:GetID())
end

-- Screen position in common units, so frames with different scales compare.
local function ScreenRect(region)
    if type(region.GetTop) ~= "function" or type(region.GetLeft) ~= "function" then return nil end
    local top, left = region:GetTop(), region:GetLeft()
    if not top or not left then return nil end
    local s = type(region.GetEffectiveScale) == "function" and region:GetEffectiveScale() or 1
    local w = (type(region.GetWidth) == "function" and region:GetWidth() or 0) * s
    local h = (type(region.GetHeight) == "function" and region:GetHeight() or 0) * s
    return left * s, top * s, w, h
end

-- Reading order inside one frame: rows from the top (buttons within half a button height of the
-- row's first one share it), each row from the left.
local function ReadingOrder(entries)
    table.sort(entries, function(a, b)
        if a.top ~= b.top then return a.top > b.top end
        return a.left < b.left
    end)
    local rows, row, rowTop, tol = {}, nil, nil, nil
    for _, e in ipairs(entries) do
        if not row or rowTop - e.top > tol then
            row = {}
            rows[#rows + 1] = row
            rowTop, tol = e.top, math.max(MIN_ROW_TOLERANCE, e.h / 2)
        end
        row[#row + 1] = e
    end
    local out = {}
    for _, r in ipairs(rows) do
        table.sort(r, function(a, b) return a.left < b.left end)
        for _, e in ipairs(r) do out[#out + 1] = e end
    end
    return out
end

-- Frames in reading order: columns from the left (frames whose left edges are within half a
-- frame width of each other), each column from the top. Separate bag frames stack in columns.
local function FrameOrder(groups)
    table.sort(groups, function(a, b)
        if a.left ~= b.left then return a.left < b.left end
        return a.top > b.top
    end)
    local columns, column, colLeft, tol = {}, nil, nil, nil
    for _, g in ipairs(groups) do
        if not column or g.left - colLeft > tol then
            column = {}
            columns[#columns + 1] = column
            colLeft, tol = g.left, math.max(MIN_ROW_TOLERANCE, g.w / 2)
        end
        column[#column + 1] = g
    end
    local out = {}
    for _, col in ipairs(columns) do
        table.sort(col, function(a, b) return a.top > b.top end)
        for _, g in ipairs(col) do out[#out + 1] = g end
    end
    return out
end

-- The slots to sort, first = top-left as the player sees it. Returns the slot list and how many
-- of them were found on screen. Slots of sortable bags that are not on screen (a bag frame that
-- is closed) follow in bag/slot order; with nothing on screen, that is the whole list.
local function SortSlots()
    local sortable, sizes = {}, {}
    for _, bag in ipairs(CARRIED_BAGS) do
        if BagSortable(bag) then
            sortable[bag] = true
            sizes[bag] = NumSlots(bag)
        end
    end

    local seen, groups = {}, {}
    for _, frame in ipairs(BagFrames()) do
        if frame:IsVisible() then
            local entries = {}
            EachItemButton(frame, function(b)
                if type(b) ~= "table" or type(b.IsVisible) ~= "function" or not b:IsVisible() then return end
                local bag, slot = ButtonBagSlot(b)
                if not bag or not slot or not sortable[bag] or slot < 1 or slot > sizes[bag] then return end
                local id = bag * 1000 + slot
                if seen[id] then return end
                local left, top, _, h = ScreenRect(b)
                if not left then return end
                seen[id] = true
                entries[#entries + 1] = { bag = bag, slot = slot, left = left, top = top, h = h }
            end)
            if #entries > 0 then
                local left, top, w = ScreenRect(frame)
                groups[#groups + 1] = { entries = entries, left = left or entries[1].left,
                    top = top or entries[1].top, w = w or 0 }
            end
        end
    end

    local slots, onScreen = {}, 0
    for _, g in ipairs(FrameOrder(groups)) do
        for _, e in ipairs(ReadingOrder(g.entries)) do
            slots[#slots + 1] = { bag = e.bag, slot = e.slot }
            onScreen = onScreen + 1
        end
    end
    for _, bag in ipairs(CARRIED_BAGS) do
        if sortable[bag] then
            for slot = 1, sizes[bag] do
                if not seen[bag * 1000 + slot] then slots[#slots + 1] = { bag = bag, slot = slot } end
            end
        end
    end
    return slots, onScreen
end

-- Finds two partial stacks of the same item; returns (from, to): the later one goes onto the
-- earlier one, so stacks gather toward the top-left.
local function FindMerge(contents, count, cache)
    local firstPartial = {}
    for i = 1, count do
        local c = contents[i]
        if c and c.itemID then
            local max = tonumber(ItemDetails(c, cache).maxStack)
            if max and max > 1 and c.count < max then
                local prev = firstPartial[c.itemID]
                if prev then return i, prev end
                firstPartial[c.itemID] = i
            end
        end
    end
end

local function SortKey(content, slot, pos, cache)
    local d = ItemDetails(content, cache)
    local quality = content.quality or d.quality or 1
    local junk = quality == 0 and ((d.sellPrice and d.sellPrice > 0)
        or (d.sellPrice == nil and not content.noValue)) and true or false
    local group
    if junk then
        group = GROUP_JUNK
    elseif d.classID == 12 or IsQuestItem(slot.bag, slot.slot) then
        group = GROUP_QUEST
    else
        group = CLASS_GROUP[d.classID] or GROUP_REST
    end
    return { content = content, group = group, quality = quality, ilvl = tonumber(d.ilvl) or 0,
             name = d.name, count = content.count, key = content.key, pos = pos }
end

local function CompareSortKeys(a, b)
    if a.group ~= b.group then return a.group < b.group end
    if a.quality ~= b.quality then return a.quality > b.quality end
    if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
    if a.name ~= b.name then return a.name < b.name end
    if a.count ~= b.count then return a.count > b.count end
    if a.key ~= b.key then return a.key < b.key end
    return a.pos < b.pos
end

-- The target arrangement: slot index -> { key, count } or nil for a slot that should be empty.
-- Everything but junk is packed from the first (top-left) slot; junk is packed against the last
-- (bottom-right) one, with the free slots in between.
local function BuildPlan(slots, contents, cache)
    local items = {}
    for i, s in ipairs(slots) do
        if contents[i] then items[#items + 1] = SortKey(contents[i], s, i, cache) end
    end
    table.sort(items, CompareSortKeys)
    local target, rest, junk = {}, {}, {}
    for _, it in ipairs(items) do
        if it.group == GROUP_JUNK then junk[#junk + 1] = it else rest[#rest + 1] = it end
    end
    for k, it in ipairs(rest) do target[k] = { key = it.key, count = it.count } end
    local base = #slots - #junk
    for k, it in ipairs(junk) do target[base + k] = { key = it.key, count = it.count } end
    return target
end

local function Fits(content, want)
    if want == nil then return content == nil end
    return content ~= nil and content.key == want.key and content.count == want.count
end

-- The next swap: the first slot that does not hold what the plan wants, and a slot that holds
-- it and is not already right. Returns (to, from), or nil plus "done" when every slot fits, or
-- nil plus "changed" when the bags no longer match the plan.
local function NextSwap(contents, target, count)
    local pending = false
    for i = 1, count do
        local want = target[i]
        if not Fits(contents[i], want) then
            if want == nil then
                -- Something sits in a slot that should be empty; it is pulled out when its own
                -- target slot comes up. If no target slot is left, the bags changed.
                pending = true
            else
                local fallback
                for j = 1, count do
                    if j ~= i and Fits(contents[j], want) and not Fits(contents[j], target[j]) then
                        if Fits(contents[i], target[j]) then return i, j end
                        fallback = fallback or j
                    end
                end
                if fallback then return i, fallback end
                return nil, "changed"
            end
        end
    end
    if pending then return nil, "changed" end
    return nil, "done"
end

local function FinishSort(message)
    sortRun = nil
    if message then Print(message) end
end

-- Stops the running sort. The cursor is cleared only when it holds the item this sort picked up;
-- anything else on it belongs to the player.
local function StopSort(message)
    local run = sortRun
    if not run then return false end
    sortRun = nil
    if run.holding ~= nil then
        -- Also reached from the error path, so the cursor check itself must not raise.
        local ok, held = pcall(CursorItem)
        if ok and held == run.holding then pcall(_G.ClearCursor) end
    end
    if message then Print(message) end
    return true
end

-- Picks the item up from one slot and puts it on another. On an occupied slot the client swaps
-- the two; onto a partial stack of the same item it merges, and any remainder left on the
-- cursor goes back where it came from. Returns true when something was picked up.
local function MoveItem(run, from, to)
    Pickup(from.bag, from.slot)
    local held = CursorItem()
    if held == nil then return false end
    if held == false then
        StopSort("sort stopped: the cursor picked up something unexpected.")
        return false
    end
    run.holding = held
    Pickup(to.bag, to.slot)
    if CursorItem() == held then Pickup(from.bag, from.slot) end
    if CursorItem() == held then _G.ClearCursor() end
    run.holding = nil
    return true
end

-- Same move chosen twice in a row with the bags unchanged means the client refused it.
local function MoveSignature(contents, from, to)
    local a, b = contents[from], contents[to]
    return from .. ">" .. to .. ":" .. (a and (a.key .. "x" .. a.count) or "-") .. ":"
        .. (b and (b.key .. "x" .. b.count) or "-")
end

local function DoMove(run, contents, from, to)
    local sig = MoveSignature(contents, from, to)
    if sig == run.lastSig then
        run.stuck = run.stuck + 1
        if run.stuck >= MAX_STUCK then
            StopSort(string.format("sort stopped after %d moves: the client keeps refusing a move.", run.moves))
            return
        end
    else
        run.stuck = 0
    end
    run.lastSig = sig
    if MoveItem(run, run.slots[from], run.slots[to]) then run.moves = run.moves + 1 end
end

local function SortStep()
    local run = sortRun
    if InCombat() then
        StopSort(string.format("sort stopped after %d moves: combat.", run.moves))
        return
    end
    run.ticks = run.ticks + 1
    if run.ticks > MAX_TICKS or run.moves > run.maxMoves then
        StopSort(string.format("sort stopped after %d moves (safety limit).", run.moves))
        return
    end
    if CursorItem() ~= nil then
        StopSort(string.format("sort stopped after %d moves: the cursor is holding something.", run.moves))
        return
    end

    local count = #run.slots
    local contents, anyLocked, unreadable = ReadSlots(run.slots)
    if anyLocked or unreadable then
        -- A move is still in flight (or an item is loading): wait for it to settle.
        run.waiting = run.waiting + 1
        if run.waiting > MAX_LOCK_WAIT then
            StopSort(string.format("sort stopped after %d moves: items stayed locked.", run.moves))
        end
        return
    end
    run.waiting = 0

    if run.phase == "merge" then
        local from, to = FindMerge(contents, count, run.cache)
        if from then
            DoMove(run, contents, from, to)
            return
        end
        run.phase = "place"
        run.target = BuildPlan(run.slots, contents, run.cache)
    end

    local to, fromOrStatus = NextSwap(contents, run.target, count)
    if to then
        DoMove(run, contents, fromOrStatus, to)
    elseif fromOrStatus == "done" then
        FinishSort(run.moves == 0 and "bags already sorted." or string.format("Sorted: %d moves.", run.moves))
    else
        run.replans = run.replans + 1
        if run.replans > MAX_REPLANS then
            StopSort(string.format("sort stopped after %d moves: the bags kept changing.", run.moves))
            return
        end
        run.phase = "merge"      -- new loot may stack with what is there; then plan again
        run.target = nil
    end
end

local SortTick
local function ScheduleTick(generation)
    TimerAfter()(SORT_STEP, function() SortTick(generation) end)
end

SortTick = function(generation)
    local run = sortRun
    if not run or run.generation ~= generation then return end
    local ok, err = pcall(SortStep)
    if not ok then
        StopSort("sort stopped after an error: " .. tostring(err))
        return
    end
    if sortRun == run then ScheduleTick(generation) end
end

local function PlaySortSound()
    local soundkit = _G.SOUNDKIT
    if type(_G.PlaySound) == "function" and type(soundkit) == "table" and soundkit.UI_BAG_SORTING_01 then
        _G.PlaySound(soundkit.UI_BAG_SORTING_01)
    end
end

local function VisualSort()
    if sortRun then
        Print("already sorting; /bbf stop stops it.")
        return false
    end
    if InCombat() then
        Print("bags cannot be cleaned up in combat.")
        return false
    end
    if not CanVisualSort() then
        Print("this client lacks what the visual sort needs (C_Container.PickupContainerItem, GetCursorInfo, C_Timer).")
        return false
    end
    if CursorItem() ~= nil then
        Print("put down what the cursor is holding first.")
        return false
    end
    local slots, onScreen = SortSlots()
    if #slots == 0 then
        Print("no bags to sort (all ignored, specialty or empty).")
        return false
    end
    if onScreen == 0 then
        Print("the bags are not open, so this sorts in bag order. Open them to sort in on-screen order.")
    end
    sortGeneration = sortGeneration + 1
    sortRun = { generation = sortGeneration, slots = slots, phase = "merge", cache = {},
                moves = 0, ticks = 0, waiting = 0, replans = 0, stuck = 0,
                maxMoves = 3 * #slots + 20 }
    PlaySortSound()
    ScheduleTick(sortGeneration)
    return true
end

-- ---------------------------------------------------------------------------
-- Clean-up button and search row
-- ---------------------------------------------------------------------------

local function SetCombatLook(inCombat)
    if not cleanupButton then return end
    local tex = cleanupButton:GetNormalTexture()
    if tex and tex.SetDesaturated then tex:SetDesaturated(inCombat) end
end

-- Blizzard's own sort, C_Container.SortBags.
local function CleanUpBags()
    if sortRun then
        Print("a visual sort is running; /bbf stop stops it.")
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
    PlaySortSound()
    sort()
    return true
end

local MODE_LABEL = { visual = "visual sort (on-screen order)", blizzard = "Blizzard sort (C_Container.SortBags)" }

local function CurrentMode()
    return (db and db.mode == "blizzard") and "blizzard" or "visual"
end

-- Runs a sort by mode name; a mode this client cannot do falls back to the other one.
local function RunSort(mode)
    if mode == "visual" and not CanVisualSort() and GetSortFunction() then mode = "blizzard" end
    if mode == "blizzard" and not GetSortFunction() and CanVisualSort() then mode = "visual" end
    if mode == "visual" then return VisualSort() end
    return CleanUpBags()
end

local function OtherMode(mode)
    return mode == "visual" and "blizzard" or "visual"
end

-- Read live every time: Blizzard's bag menu can change the same setting behind our back.
-- The labels describe what the player sees in the Combined Backpack, not Blizzard's wording: the
-- combined view lists the bags in reverse, so "right to left" (true) is the one that looks normal
-- there and is what Forever's own Clean Up uses by default. Returns the short and the full label.
local function DirectionLabel()
    local get = GetDirectionFunctions()
    if not get then return nil end
    if get() then return "Standard", "Standard (junk bottom-right)" end
    return "Reversed", "Reversed (junk top-left)"
end

-- Sets the sort order (true = Standard, Blizzard's right to left), or flips it when rightToLeft
-- is nil. Only a client setting changes, nothing moves, so this is allowed in combat.
local function SetSortDirection(rightToLeft)
    local get, set = GetDirectionFunctions()
    if not get then
        Print("this client has no C_Container.SetSortBagsRightToLeft.")
        return false
    end
    if rightToLeft == nil then rightToLeft = not get() end
    set(rightToLeft and true or false)
    local _, full = DirectionLabel()
    Print("Sort order: " .. full)
    return true
end

local function ShowCleanupTooltip(self)
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
    local mode = CurrentMode()
    tip:AddLine("Left-click: " .. MODE_LABEL[mode], 0, 1, 0)
    tip:AddLine("Shift+left-click: " .. MODE_LABEL[OtherMode(mode)], 0, 1, 0)
    local short, full = DirectionLabel()
    if short then
        tip:AddLine("Right-click: switch Blizzard's sort order (now: " .. short .. ")", 0, 1, 0)
        tip:AddLine("Blizzard sort order: " .. full, 1, 1, 1)
    end
    tip:AddLine("The visual sort fills the bags in the order you see them: top-left first, junk in the bottom-right corner.", 1, 1, 1, true)
    tip:AddLine("/bbf mode visual | blizzard picks what left-click does (now: " .. mode .. "). /bbf stop stops a running sort.", 0.7, 0.7, 0.7, true)
    tip:Show()
end

local function OnCleanupClick(self, button)
    if button == "RightButton" then
        if not GetDirectionFunctions() then return end
        SetSortDirection(nil)
        local tip = _G.GameTooltip
        if tip and tip:IsShown() and tip.GetOwner and tip:GetOwner() == self then
            ShowCleanupTooltip(self)
        end
        return
    end
    local mode = CurrentMode()
    if type(_G.IsShiftKeyDown) == "function" and _G.IsShiftKeyDown() then mode = OtherMode(mode) end
    RunSort(mode)
end

local function CreateCleanupButton()
    if cleanupButton or not bagFrame or not GetSearchBox() then return end
    if not GetSortFunction() and not CanVisualSort() then return end
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
    Print("Clean Up button: left-click = " .. MODE_LABEL[CurrentMode()] .. ", Shift+left-click = "
        .. MODE_LABEL[OtherMode(CurrentMode())] .. ", right-click = switch Blizzard's sort order.")
    Print("/bbf mode visual | blizzard - what a plain left-click does (now: " .. CurrentMode() .. ")")
    Print("/bbf sort - run the visual sort; /bbf stop - stop a running one")
    local _, full = DirectionLabel()
    if full then
        Print("/bbf direction - switch Blizzard's sort order; /bbf direction standard | reversed to set it (now: " .. full .. ")")
    end
    Print("/bbf status - what this client offers")
end

local function PrintStatus()
    Print("ContainerFrameCombinedBags: " .. Yes(GetBagFrame()))
    Print("BagItemSearchBox: " .. Yes(_G.BagItemSearchBox))
    Print("BagItemAutoSortButton: " .. Yes(GetNativeSortButton()))
    Print("C_Container.SortBags: " .. Yes(GetSortFunction()))
    Print("C_Container.Get/SetSortBagsRightToLeft: " .. Yes(GetDirectionFunctions()))
    local _, full = DirectionLabel()
    Print("sort order: " .. (full or "unknown"))
    Print("visual sort (PickupContainerItem, GetCursorInfo, C_Timer): " .. Yes(CanVisualSort()))
    Print("left-click mode: " .. CurrentMode() .. (sortRun and " (a visual sort is running)" or ""))
    if CanVisualSort() then
        local slots, onScreen = SortSlots()
        Print(string.format("slots to sort: %d, found on screen: %d", #slots, onScreen))
    end
    Print("UpdateContainerFrameAnchors: " .. Yes(type(_G.UpdateContainerFrameAnchors) == "function"))
    Print("using combined bags: " .. (UsingCombinedBags() and "yes" or "no"))
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
    elseif msg == "mode" then
        Print("left-click runs the " .. MODE_LABEL[CurrentMode()] .. ". /bbf mode visual | blizzard to change it.")
    elseif msg == "mode visual" or msg == "mode blizzard" then
        db.mode = msg:sub(6)
        Print("left-click now runs the " .. MODE_LABEL[db.mode] .. "; Shift+left-click the "
            .. MODE_LABEL[OtherMode(db.mode)] .. ".")
    elseif msg == "sort" then
        VisualSort()
    elseif msg == "stop" then
        if not StopSort(string.format("sort stopped after %d moves.", sortRun and sortRun.moves or 0)) then
            Print("no sort is running.")
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
    if db.mode ~= "visual" and db.mode ~= "blizzard" then db.mode = DEFAULTS.mode end
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
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
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
        if sortRun then StopSort(string.format("sort stopped after %d moves: combat.", sortRun.moves)) end
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
