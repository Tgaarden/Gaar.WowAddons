--[[
  BetterBagsForever - small fixes for the native "Combined Backpack" on WoW Forever.

  Forever ships the retail-style combined bag frame (ContainerFrameCombinedBags). This addon
  changes these things about it and nothing else:

    * The frame can be moved: drag its title bar, or Alt-drag any empty part of it. The position
      is saved in BetterBagsForeverDB and put back every time Blizzard re-anchors the bags.
    * A "Clean Up Bags" button sits on the left of the search box, because on Forever the native
      one (BagItemAutoSortButton) ends up hidden under the bag slot icons on the right. A
      left-click does exactly what the native button does: the sort sound and
      C_Container.SortBags(). The sort-direction setting is never read or changed.
    * Reverse (right-click the button, or /bbf reverse; off by default): in the Combined Backpack,
      once Blizzard's sort has settled, the whole visible order is mirrored, so the slot shown
      last trades places with the slot shown first, and so on. Separate bags are never touched.
    * Item counts and gold across this realm's characters (since 1.7): every character that logs
      in keeps a compact record of its bags, bank, equipped items, mail and gold in
      BetterBagsForeverDB.inventory. Item tooltips list each character that has the item, and
      hovering the gold in the bag window lists every character's gold. /bbf counts on|off,
      /bbf gold, /bbf forget <name>.
    * Auto clean-up (since 1.8, on by default): opening the bag window runs the same clean-up as
      the button. Player bags only; skipped in combat, while a clean-up runs, or with a locked
      item or an item on the cursor. /bbf autosort on|off.
    * Do-not-sell item lock (since 1.9): Alt + left-click an item in the bags locks or unlocks it
      (per item ID, per character, in BetterBagsForeverCharDB.lockedItems). A locked item shows a
      padlock in the bottom-left corner of its slot, and a merchant cannot get it: right-click,
      drag-and-drop and Blizzard's Sell Junk are blocked, and a sale that slips through anyway is
      bought back once. /bbf locked, /bbf unlockall yes.
    * /bbf for help, reset, lock, unlock, native, reverse, autosort, counts, gold, forget, locked,
      unlockall, stop and status.
    * BetterBagsForeverAPI, a small global table for BetterForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The API only exposes the settings
      the slash command already changes. The small helpers (Print, InCombat, OnOff, Plain, the
      client API lookups and the menu drawing) come from BetterForever's library.

  Names come from Blizzard's retail FrameXML (Interface/AddOns/Blizzard_UIPanels_Game/Mainline/
  ContainerFrame.xml and ContainerFrame.lua): ContainerFrameCombinedBags, BagItemSearchBox,
  BagItemAutoSortButton, UpdateContainerFrameAnchors, ContainerFrameSettingsManager. Every one
  of them is checked before use; when something is missing the matching feature simply does not
  switch on.

  Taint: Blizzard code is only ever followed, never replaced. The item lock blocks a sale with
  separate guard frames of its own laid over the item button or the merchant window, never by
  replacing or wrapping a Blizzard click handler; see the item lock section. Hooks go through hooksecurefunc
  and HookScript, no Blizzard button is clicked, and nothing protected is touched; the reversal
  moves items only with C_Container.PickupContainerItem, outside combat. If the
  bag frame ever turns out to be protected, a move that lands in combat waits for
  PLAYER_REGEN_ENABLED instead of being attempted.
]]

local _G = _G
local ADDON_NAME = ... or "BetterBagsForever"
local VERSION = "1.9.2"

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
    reverse = false,
    showCounts = true,
    autoSort = true,
}

-- Every key BetterBagsForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = { locked = true, hideNativeButton = true, position = true, reverse = true,
                     showCounts = true, inventory = true, autoSort = true }

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

-- The shared helpers come from BetterForever's library (Lib.lua; the addon depends on
-- BetterForever). The addon object is scoped to the do-block: the main chunk is close to Lua's
-- limit of 200 locals.
local BF = _G.BetterForever
local InCombat, OnOff, Plain, PlainString = BF.InCombat, BF.OnOff, BF.Plain, BF.Str

local Print
do
    local A = BF.NewAddon("BetterBagsForever", { version = VERSION })
    function Print(msg) A:Print(msg) end
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
-- Clean-up and Reverse
--
-- A left-click always starts with exactly what Forever's own Clean Up Bags button does: the
-- sort sound and C_Container.SortBags(). Blizzard decides where every item goes.
--
-- With Reverse on (right-click toggles it, saved in BetterBagsForeverDB.reverse) and the
-- Combined Backpack in use, the addon then mirrors the whole visible order: the slot shown last
-- trades places with the slot shown first, the second-to-last with the second, and so on. Empty
-- slots are mirrored too, so gaps end up mirrored as well. Separate bags, and Reverse off, get
-- Blizzard's sort and nothing else. The sort-direction setting is never read or changed.
--
--   wait:    poll every 0.05 s. Blizzard's sort counts as finished once no BAG_UPDATE,
--            BAG_UPDATE_DELAYED or ITEM_LOCK_CHANGED has arrived for about 0.35 s and no
--            carried slot is locked. After about 15 s it gives up and reverses nothing.
--   read:    the order comes from the screen: the visible item buttons of
--            ContainerFrameCombinedBags, sorted top to bottom, then left to right. Only the
--            backpack and bags 1-4 count; specialty bags (soul, quiver, ammo, profession) are
--            left out entirely, since most items cannot go into them.
--   burst:   the mirrored pairs never share a slot, so no move depends on another one. Every
--            pair that needs a move gets it straight away, without waiting for the server in
--            between: C_Container.PickupContainerItem on one slot, then on the other, up to
--            BURST_CHUNK pairs per frame. Both slots are re-read right before each move. Pairs
--            that are both empty or hold the same item are skipped, so two stacks can never
--            merge. The cursor has to be empty after every pair, or the burst ends there.
--   verify:  poll every 0.05 s until none of the pairs' slots is locked (about 3 s at most),
--            then re-read them. Pairs that are not mirrored yet get another burst, up to
--            MAX_RETRIES more rounds.
-- ---------------------------------------------------------------------------

local WAIT_STEP = 0.05          -- seconds between polls while Blizzard's sort runs
local QUIET_TICKS = 7           -- polls without a bag event (about 0.35 s) before the sort counts as done
local MAX_WAIT_TICKS = 300      -- give up waiting for Blizzard's sort after about 15 s
local BURST_CHUNK = 10          -- pairs moved per frame during a burst; the rest follow next frame
local VERIFY_STEP = 0.05        -- seconds between polls while the server confirms a burst
local MAX_LOCK_WAIT = 60        -- verify polls spent waiting on locked items (about 3 s)
local UNCHANGED_GRACE = 4       -- verify polls a moved pair may still look unmoved before it is retried
local MAX_RETRIES = 3           -- extra bursts for pairs that did not end up mirrored
local MAX_RUN_TICKS = 2400      -- hard cap on ticks for one reversal
local FIRST_BAG, LAST_BAG = 0, 4    -- backpack and the four bag slots; not keyring, not bank

local cleanupRun        -- the wait or reversal in progress, or nil
local runGeneration = 0

local function ContainerAPI()
    local c = _G.C_Container
    if type(c) == "table" then return c end
end

-- Modern C_Container first, then the old global of the same name.
local function ContainerFunction(name)
    return BF.API("C_Container", name) or BF.API(name)
end

local function TimerAfter()
    return BF.API("C_Timer", "After")
end

-- Everything the reversal needs to move items safely.
local function CanReverse()
    return ContainerFunction("PickupContainerItem") and ContainerFunction("GetContainerItemInfo")
        and ContainerFunction("GetContainerNumSlots") and type(_G.GetCursorInfo) == "function"
        and type(_G.ClearCursor) == "function" and TimerAfter() and true or false
end

local function ReverseOn()
    return db ~= nil and db.reverse == true
end

-- The next left-click will reverse the visible order after Blizzard's sort.
local function WillReverse()
    return ReverseOn() and UsingCombinedBags() and CanReverse()
end

local function NumSlots(bag)
    local fn = ContainerFunction("GetContainerNumSlots")
    if not fn then return 0 end
    local ok, n = pcall(fn, bag)
    return ok and tonumber(n) or 0
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

-- Same item in both slots: swapping them changes nothing visible, and dropping one on the
-- other could merge the stacks instead of swapping them.
local function SameItem(a, b)
    return a ~= nil and b ~= nil and (a.key == b.key or (a.itemID ~= nil and a.itemID == b.itemID))
end

local function AnyCarriedSlotBusy()
    for bag = FIRST_BAG, LAST_BAG do
        for slot = 1, NumSlots(bag) do
            local _, busy = ReadSlot(bag, slot)
            if busy then return true end
        end
    end
    return false
end

local function BagSizes()
    local sizes = {}
    for bag = FIRST_BAG, LAST_BAG do sizes[bag] = NumSlots(bag) end
    return sizes
end

local function SameSizes(a, b)
    for bag = FIRST_BAG, LAST_BAG do
        if a[bag] ~= b[bag] then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- The visual order of the Combined Backpack
-- ---------------------------------------------------------------------------

-- Bag and slot of one item button: Blizzard's ContainerFrameItemButtonMixin:GetBagID, else the
-- bagID field, else the parent's id (Blizzard's own fallback); the slot is the button's id.
local function ButtonBagAndSlot(button)
    local bag
    if type(button.GetBagID) == "function" then
        local ok, v = pcall(button.GetBagID, button)
        if ok then bag = tonumber(v) end
    end
    if bag == nil then bag = tonumber(button.bagID) end
    if bag == nil and type(button.GetParent) == "function" then
        local parent = button:GetParent()
        if type(parent) == "table" and type(parent.GetID) == "function" then bag = tonumber(parent:GetID()) end
    end
    local slot = type(button.GetID) == "function" and tonumber(button:GetID()) or nil
    return bag, slot
end

-- The frame's item buttons: its Items list when it has one, else children that look like item
-- buttons (so our own clean-up button and the drag handle are never counted).
local function ItemButtons(frame)
    local list, seen = {}, {}
    local function add(b)
        if type(b) == "table" and not seen[b] and type(b.GetID) == "function" then
            seen[b] = true
            list[#list + 1] = b
        end
    end
    if type(frame.Items) == "table" then
        for _, b in ipairs(frame.Items) do add(b) end
    end
    if #list == 0 and type(frame.GetChildren) == "function" then
        for _, child in ipairs({ frame:GetChildren() }) do
            if type(child) == "table" and (type(child.GetBagID) == "function" or child.bagID ~= nil) then add(child) end
        end
    end
    return list
end

local function IsOnScreen(button)
    if type(button.IsShown) == "function" and not button:IsShown() then return false end
    if type(button.IsVisible) == "function" and not button:IsVisible() then return false end
    return true
end

-- Every visible slot of the backpack and bags 1-4 in the Combined Backpack, in the order the
-- player reads it: top row first, each row left to right. Positions use the effective scale,
-- and buttons whose tops are within half a button height of each other share a row. Returns
-- the list, or nil and the reason it could not be read.
local function BuildVisualSlots()
    local frame = GetBagFrame()
    if not frame then return nil, "the Combined Backpack frame was not found." end
    if type(frame.IsShown) == "function" and not frame:IsShown() then
        return nil, "the Combined Backpack is not open."
    end
    local entries, seen, families = {}, {}, {}
    for _, button in ipairs(ItemButtons(frame)) do
        if IsOnScreen(button) then
            local bag, slot = ButtonBagAndSlot(button)
            if bag and slot and bag >= FIRST_BAG and bag <= LAST_BAG and slot >= 1 and slot <= NumSlots(bag) then
                if families[bag] == nil then families[bag] = BagFamily(bag) end
                local key = bag .. ":" .. slot
                if families[bag] == 0 and not seen[key] then
                    local scale = type(button.GetEffectiveScale) == "function" and button:GetEffectiveScale() or 1
                    local left, top = button:GetLeft(), button:GetTop()
                    if left and top then
                        seen[key] = true
                        local height = (type(button.GetHeight) == "function" and button:GetHeight() or 0) * scale
                        entries[#entries + 1] = { bag = bag, slot = slot, x = left * scale, y = top * scale, h = height }
                    end
                end
            end
        end
    end
    if #entries == 0 then return nil, "no bag slots were found in the Combined Backpack." end

    table.sort(entries, function(a, b)
        if a.y ~= b.y then return a.y > b.y end
        return a.x < b.x
    end)
    local slots, row = {}, {}
    local function flush()
        table.sort(row, function(a, b) return a.x < b.x end)
        for _, e in ipairs(row) do slots[#slots + 1] = { bag = e.bag, slot = e.slot } end
        row = {}
    end
    for _, e in ipairs(entries) do
        local first = row[1]
        if first and first.y - e.y > math.max(1, first.h / 2) then flush() end
        row[#row + 1] = e
    end
    flush()
    return slots
end

-- ---------------------------------------------------------------------------
-- Running a reversal
-- ---------------------------------------------------------------------------

-- Where one mirrored pair stands: "busy" (a slot is locked), "done" (the two slots have traded
-- places), "todo" (still as planned) or "changed" (they hold something else).
local function PairState(pair)
    local a, busyA = ReadSlot(pair.A.bag, pair.A.slot)
    local b, busyB = ReadSlot(pair.B.bag, pair.B.slot)
    if busyA or busyB then return "busy" end
    if Identical(a, pair.b) and Identical(b, pair.a) then return "done" end
    if Identical(a, pair.a) and Identical(b, pair.b) then return "todo" end
    return "changed"
end

-- Pairs that show the mirrored state right now.
local function CountSwaps(run)
    if not run.pairs then return run.swaps end
    local n = 0
    for _, pair in ipairs(run.pairs) do
        if pair.done or PairState(pair) == "done" then n = n + 1 end
    end
    return n
end

-- Why a run stopped, worded for the phase it was in.
local function StopMessage(run, reason)
    if run.phase == "wait" then return "order not reversed: " .. reason end
    -- Also reached from the error path, so counting must not raise.
    local ok, swaps = pcall(CountSwaps, run)
    return string.format("reverse stopped after %d swaps: %s", ok and swaps or run.swaps, reason)
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

-- One pair's move: pick the item up from one slot and put it on the other, which is a move
-- into an empty slot or a swap with a different item. Nothing waits for the server here.
-- Returns "issued", "skipped" (locked, or already mirrored), "refused" (nothing was picked up),
-- "changed" (the slots no longer hold what the move is for), "cursor" (something that is not
-- an item came up) or "stuck" (the cursor is not empty afterwards).
local function IssuePair(run, pair)
    local state = PairState(pair)
    if state == "busy" or state == "done" then return "skipped" end
    if state == "changed" then return "changed" end
    local from, to = pair.A, pair.B
    if pair.a == nil then from, to = pair.B, pair.A end
    Pickup(from.bag, from.slot)
    local held = CursorItem()
    if held == nil then return "refused" end
    if held == false then return "cursor" end
    run.holding = held
    Pickup(to.bag, to.slot)
    -- Anything of ours still on the cursor goes back where it came from.
    if CursorItem() == held then Pickup(from.bag, from.slot) end
    if CursorItem() == held then _G.ClearCursor() end
    if CursorItem() == held then return "stuck" end      -- still ours: StopRun clears it
    run.holding = nil
    run.moves = run.moves + 1
    pair.issued = true
    pair.unchanged = 0
    if CursorItem() ~= nil then return "stuck" end
    return "issued"
end

local function StartVerify(run)
    run.phase = "verify"
    run.lockWait = 0
end

-- Moves the queued pairs, BURST_CHUNK per frame, then hands over to the verify pass.
local function BurstStep(run)
    if CursorItem() ~= nil then
        StopRun(StopMessage(run, "the cursor is holding something."))
        return
    end
    if not SameSizes(run.sizes, BagSizes()) then
        StopRun(StopMessage(run, "the bags changed."))
        return
    end
    local tried = 0
    while tried < BURST_CHUNK and run.queue[run.qi] do
        if InCombat() then
            StopRun(StopMessage(run, "combat."))
            return
        end
        if run.moves >= run.maxMoves then
            StopRun(StopMessage(run, "safety limit."))
            return
        end
        local pair = run.queue[run.qi]
        run.qi = run.qi + 1
        local result = IssuePair(run, pair)
        if result == "changed" then
            StopRun(StopMessage(run, "the bags changed."))
            return
        elseif result == "cursor" then
            StopRun(StopMessage(run, "the cursor picked up something unexpected."))
            return
        elseif result == "stuck" then
            -- Nothing more this burst; the verify pass stops the run unless the cursor empties.
            StartVerify(run)
            return
        elseif result ~= "skipped" then
            tried = tried + 1
        end
    end
    if not run.queue[run.qi] then StartVerify(run) end
end

-- Waits for the server to settle the moves, then retries the pairs that did not end up
-- mirrored, or finishes.
local function VerifyStep(run)
    if CursorItem() ~= nil then
        StopRun(StopMessage(run, "the cursor is holding something."))
        return
    end
    if not SameSizes(run.sizes, BagSizes()) then
        StopRun(StopMessage(run, "the bags changed."))
        return
    end
    local todo, waiting, swaps = {}, false, 0
    for _, pair in ipairs(run.pairs) do
        if not pair.done then
            local state = PairState(pair)
            if state == "changed" then
                StopRun(StopMessage(run, "the bags changed."))
                return
            elseif state == "busy" then
                waiting = true
            elseif state == "done" then
                pair.done = true
            else
                -- Give the client a moment to show a move before trying it again; retrying a
                -- move that is merely slow to appear would undo it.
                if pair.issued and pair.unchanged < UNCHANGED_GRACE then
                    pair.unchanged = pair.unchanged + 1
                    waiting = true
                end
                todo[#todo + 1] = pair
            end
        end
        if pair.done then swaps = swaps + 1 end
    end
    run.swaps = swaps
    if waiting then
        run.lockWait = run.lockWait + 1
        if run.lockWait > MAX_LOCK_WAIT then StopRun(StopMessage(run, "items stayed locked.")) end
        return
    end
    if #todo == 0 then
        StopRun(string.format("Reversed (%d swaps).", swaps))
        return
    end
    if run.round >= MAX_RETRIES then
        StopRun(string.format("Reversed (%d swaps); %d could not be swapped: the client keeps refusing a move.",
            swaps, #todo))
        return
    end
    run.round = run.round + 1
    for _, pair in ipairs(todo) do pair.issued = false end
    run.queue, run.qi, run.phase = todo, 1, "burst"
    BurstStep(run)
end

-- Blizzard's sort has settled: read the visible order, note every mirrored pair that needs a
-- move, and start the first burst.
local function StartReverse(run)
    if CursorItem() ~= nil then
        StopRun(StopMessage(run, "the cursor is holding something."))
        return
    end
    local slots, reason = BuildVisualSlots()
    if not slots then
        StopRun("order not reversed: " .. reason)
        return
    end
    local n = #slots
    run.pairs, run.queue = {}, {}
    for i = 1, math.floor(n / 2) do
        local A, B = slots[i], slots[n + 1 - i]
        local a, b = ReadSlot(A.bag, A.slot), ReadSlot(B.bag, B.slot)
        if (a or b) and not SameItem(a, b) then
            local pair = { A = A, B = B, a = a, b = b, unchanged = 0 }
            run.pairs[#run.pairs + 1] = pair
            run.queue[#run.queue + 1] = pair
        end
    end
    run.phase = "burst"
    run.slotCount = n
    run.sizes = BagSizes()
    run.ticks, run.qi, run.round = 0, 1, 0
    run.maxMoves = (MAX_RETRIES + 1) * #run.pairs + 20     -- one move per pair and round
    BurstStep(run)
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
        StartReverse(run)
    elseif run.ticks >= MAX_WAIT_TICKS then
        StopRun("Blizzard's clean-up did not finish within 15 s, so the order was not reversed.")
    end
end

local function MoveStep(run)
    run.ticks = run.ticks + 1
    if run.ticks > MAX_RUN_TICKS then
        StopRun(StopMessage(run, "safety limit."))
    elseif run.phase == "burst" then
        BurstStep(run)
    else
        VerifyStep(run)
    end
end

local RunTick
local function ScheduleTick(run)
    local generation = run.generation
    local delay = run.phase == "wait" and WAIT_STEP or run.phase == "burst" and 0 or VERIFY_STEP
    TimerAfter()(delay, function() RunTick(generation) end)
end

RunTick = function(generation)
    local run = cleanupRun
    if not run or run.generation ~= generation then return end
    if InCombat() then
        StopRun(StopMessage(run, "combat."))
        return
    end
    local ok, err = pcall(run.phase == "wait" and WaitStep or MoveStep, run)
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

-- Left-click: Blizzard's sort, then the reversal when Reverse is on and the Combined Backpack
-- is in use. Anything else gets Blizzard's sort and nothing more.
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
    local reverse = WillReverse()
    PlaySortSound()
    sort()
    if reverse then
        runGeneration = runGeneration + 1
        cleanupRun = { generation = runGeneration, phase = "wait", ticks = 0, quiet = 0, activity = false,
                       swaps = 0, moves = 0, lockWait = 0 }
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


-- Blizzard's own title and description, then what each mouse button does here.
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
    tip:AddLine("Left-click: clean up bags", 0, 1, 0)
    tip:AddLine("Right-click: reverse order (now: " .. OnOff(ReverseOn()) .. ")", 0, 1, 0)
    if ReverseOn() then
        tip:AddLine("In the Combined Backpack the whole order is mirrored after Blizzard's clean-up.", 1, 1, 1, true)
    end
    tip:Show()
end

-- Redraws the clean-up tooltip if it is showing, so it follows the Reverse setting.
local function RefreshCleanupTooltip()
    local tip = _G.GameTooltip
    if cleanupButton and tip and tip.IsShown and tip:IsShown() and tip.GetOwner and tip:GetOwner() == cleanupButton then
        ShowCleanupTooltip(cleanupButton)
    end
end

-- Turns Reverse on or off, or flips it when on is nil. It is the addon's own saved setting and
-- moves nothing, so it is allowed in combat.
local function SetReverse(on)
    if not db then return end
    if on == nil then on = not db.reverse end
    db.reverse = on and true or false
    Print("Reverse: " .. OnOff(db.reverse))
    RefreshCleanupTooltip()
end

-- Left-click cleans up; right-click toggles Reverse. Only those two are registered.
local function OnCleanupClick(self, button)
    if button == "RightButton" then
        SetReverse(nil)
    elseif button == nil or button == "LeftButton" then
        CleanUpBags()
    end
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
-- Inventory: item counts and gold across this realm's characters (since 1.7)
--
-- Every character that logs in with 1.7 keeps a compact record in the account-wide
-- BetterBagsForeverDB.inventory[realm][name]:
--
--   { class, faction, gold, bags = { [itemID] = count }, bank = {...}, equipped = {...},
--     mail = {...}, bankScanned = time(), mailScanned = time() }
--
-- Only the logged-in character's record is ever written, and only from what the client shows:
--   bags      backpack, bag slots and the keyring where the client has one; BAG_UPDATE_DELAYED
--             (coalesced) and login
--   bank      the character bank (bank tabs, or the bank container and bank bags) while the bank
--             is open; BANKFRAME_OPENED, PLAYERBANKSLOTS_CHANGED, BAG_UPDATE while open. The
--             warband/account bank is never counted. Otherwise the last scan is kept.
--   equipped  inventory slots 1-19, ranged included; PLAYER_EQUIPMENT_CHANGED and login. The
--             classic ammo slot is skipped: it only points at ammo that already sits in a bag.
--   mail      inbox attachments while the mailbox is open; MAIL_SHOW, MAIL_INBOX_UPDATE.
--             Otherwise the last scan is kept.
--   gold      PLAYER_MONEY and login
--
-- Scans are plain reads, each one behind pcall and type checks, and never run in combat: a scan
-- that falls in combat waits for PLAYER_REGEN_ENABLED. Item tooltips get their lines from
-- TooltipDataProcessor.AddTooltipPostCall (OnTooltipSetItem on a client without it); the gold
-- tooltip hooks OnEnter/OnLeave of the bag money frames with HookScript. No Blizzard table is
-- written: the "already added" guard lives in a weak table of our own.
-- ---------------------------------------------------------------------------

local SCAN_DELAY = 0.5          -- seconds that bag, bank and equipment events are coalesced over
local LOGIN_SCAN_DELAY = 1.5    -- the first scan after login, once the bags have arrived
local DOT = " \194\183 "        -- " · "

-- A value the client hides comes back secret; it can be neither compared nor counted. Plain (the
-- value, or nil when secret) and PlainString (a plain, non-empty string) are the library's Plain
-- and Str. PlainNumber stays here: it also reads a number from a string.
local function PlainNumber(v)
    v = Plain(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then return tonumber(v) end
    return nil
end


local playerName, playerRealm   -- known from PLAYER_LOGIN on
local bankOpen, mailOpen = false, false
local pendingScan = {}          -- sources waiting for the next scan: bags, bank, equipped
local scanScheduled = false
local moneyHooked = setmetatable({}, { __mode = "k" })    -- money frames already hooked
local tooltipGuard = setmetatable({}, { __mode = "k" })   -- tooltip -> itemID it already has lines for
local clearHooked = setmetatable({}, { __mode = "k" })    -- tooltips whose OnTooltipCleared we follow
local tooltipsHooked = false

local function CountsOn()
    return db ~= nil and db.showCounts ~= false
end

-- ---- where things are -----------------------------------------------------

local function BagIndexEnum()
    local enum = _G.Enum
    local bi = type(enum) == "table" and enum.BagIndex
    if type(bi) == "table" then return bi end
end

local function AddID(list, seen, id)
    id = PlainNumber(id)
    if id and not seen[id] then
        seen[id] = true
        list[#list + 1] = id
    end
end

-- The character bank: bank tabs where the client has them (Forever and current retail), else the
-- classic bank container plus bank bags. The warband (account) bank is shared by every
-- character, so it is left out.
local function BankContainers()
    local list, seen = {}, {}
    local bi = BagIndexEnum()
    if bi and bi.CharacterBankTab_1 ~= nil then
        for i = 1, 20 do
            local id = bi["CharacterBankTab_" .. i]
            if id == nil then break end
            AddID(list, seen, id)
        end
        return list
    end
    AddID(list, seen, (bi and bi.Bank) or _G.BANK_CONTAINER or -1)
    if bi and bi.BankBag_1 ~= nil then
        for i = 1, 20 do
            local id = bi["BankBag_" .. i]
            if id == nil then break end
            AddID(list, seen, id)
        end
    else
        local first = (PlainNumber(_G.NUM_BAG_SLOTS) or 4) + 1
        local n = PlainNumber(_G.NUM_BANKBAGSLOTS) or 7
        for i = 0, n - 1 do AddID(list, seen, first + i) end
    end
    return list
end

-- Everything the character carries: backpack, the four bag slots, a reagent bag and the keyring
-- where the client has them. No id that belongs to any kind of bank is ever counted here.
local function CarriedContainers()
    local banked = {}
    for _, id in ipairs(BankContainers()) do banked[id] = true end
    local bi = BagIndexEnum()
    if bi then
        for _, key in ipairs({ "Bank", "Bankbag", "Reagentbank", "Characterbanktab", "Accountbanktab" }) do
            local id = PlainNumber(bi[key])
            if id then banked[id] = true end
        end
        for i = 1, 20 do
            local id = PlainNumber(bi["AccountBankTab_" .. i])
            if not id then break end
            banked[id] = true
        end
    end

    local list, seen = {}, {}
    if bi and bi.Backpack ~= nil then
        AddID(list, seen, bi.Backpack)
        for i = 1, 4 do AddID(list, seen, bi["Bag_" .. i]) end
        AddID(list, seen, bi.ReagentBag)
    else
        for i = 0, PlainNumber(_G.NUM_BAG_SLOTS) or 4 do AddID(list, seen, i) end
    end
    AddID(list, seen, (bi and bi.Keyring) or _G.KEYRING_CONTAINER)

    local out = {}
    for _, id in ipairs(list) do
        if not banked[id] then out[#out + 1] = id end
    end
    return out
end

local function ContainerSize(bag)
    local fn = ContainerFunction("GetContainerNumSlots")
    if not fn then return 0 end
    local ok, n = pcall(fn, bag)
    return ok and PlainNumber(n) or 0
end

-- The item id and stack size in one slot, or nil.
local function SlotItem(bag, slot)
    local c = ContainerAPI()
    if c and type(c.GetContainerItemInfo) == "function" then
        local ok, info = pcall(c.GetContainerItemInfo, bag, slot)
        if not ok or type(info) ~= "table" then return nil end
        local id = PlainNumber(info.itemID)
        if not id then
            local link = PlainString(info.hyperlink)
            id = link and tonumber(link:match("item:(%d+)"))
        end
        if id then return id, PlainNumber(info.stackCount) or 1 end
    elseif type(_G.GetContainerItemInfo) == "function" then
        local ok, tex, count, _, _, _, _, link, _, _, id = pcall(_G.GetContainerItemInfo, bag, slot)
        if not ok or not Plain(tex) then return nil end
        id = PlainNumber(id)
        if not id then
            link = PlainString(link)
            id = link and tonumber(link:match("item:(%d+)"))
        end
        if id then return id, PlainNumber(count) or 1 end
    end
    return nil
end

-- Counts by itemID over the given containers, and how many slots they have in all.
local function ReadContainers(list)
    local counts, slots = {}, 0
    for _, bag in ipairs(list) do
        local n = ContainerSize(bag)
        slots = slots + n
        for slot = 1, n do
            local id, count = SlotItem(bag, slot)
            if id then counts[id] = (counts[id] or 0) + count end
        end
    end
    return counts, slots
end

local function ReadEquipped()
    local getID = _G.GetInventoryItemID
    if type(getID) ~= "function" then return nil end
    local getCount = _G.GetInventoryItemCount
    local ranged = PlainNumber(_G.INVSLOT_RANGED) or 18
    local last = PlainNumber(_G.INVSLOT_LAST_EQUIPPED) or 19
    local counts = {}
    -- From slot 1: slot 0 is the classic ammo slot, which only points at ammo in a bag.
    for slot = 1, last do
        local ok, id = pcall(getID, "player", slot)
        id = ok and PlainNumber(id) or nil
        if id then
            local n = 1
            -- A thrown-weapon stack sits in the ranged slot itself, not in a bag.
            if slot == ranged and type(getCount) == "function" then
                local okCount, c = pcall(getCount, "player", slot)
                c = okCount and PlainNumber(c) or nil
                if c and c > 1 then n = c end
            end
            counts[id] = (counts[id] or 0) + n
        end
    end
    return counts
end

local function ReadMail()
    local numItems, getItem = _G.GetInboxNumItems, _G.GetInboxItem
    if type(numItems) ~= "function" or type(getItem) ~= "function" then return nil end
    local getLink = _G.GetInboxItemLink
    local ok, n = pcall(numItems)
    n = ok and PlainNumber(n) or 0
    local attachments = PlainNumber(_G.ATTACHMENTS_MAX_RECEIVE) or 16
    local counts = {}
    for i = 1, n do
        for a = 1, attachments do
            local okItem, name, id, _, count = pcall(getItem, i, a)
            if okItem and Plain(name) then
                id = PlainNumber(id)
                if not id and type(getLink) == "function" then
                    local okLink, link = pcall(getLink, i, a)
                    link = okLink and PlainString(link) or nil
                    id = link and tonumber(link:match("item:(%d+)"))
                end
                if id then counts[id] = (counts[id] or 0) + (PlainNumber(count) or 1) end
            end
        end
    end
    return counts
end

-- ---- the saved records ----------------------------------------------------

local function RealmData(create)
    if not db or not playerRealm then return nil end
    if type(db.inventory) ~= "table" then
        if not create then return nil end
        db.inventory = {}
    end
    local realm = db.inventory[playerRealm]
    if type(realm) ~= "table" then
        if not create then return nil end
        realm = {}
        db.inventory[playerRealm] = realm
    end
    return realm
end

local function PlayerRecord()
    if not playerName then return nil end
    local realm = RealmData(true)
    if not realm then return nil end
    local rec = realm[playerName]
    if type(rec) ~= "table" then
        rec = {}
        realm[playerName] = rec
    end
    return rec
end

local function UpdateGold()
    local rec = PlayerRecord()
    if not rec or type(_G.GetMoney) ~= "function" then return end
    local ok, money = pcall(_G.GetMoney)
    money = ok and PlainNumber(money) or nil
    if money then rec.gold = money end
end

local function ScanBags(rec)
    local counts, slots = ReadContainers(CarriedContainers())
    if slots > 0 then rec.bags = counts end      -- no slots at all: the bags have not arrived yet
end

local function ScanBank(rec)
    if not bankOpen then return end
    local counts, slots = ReadContainers(BankContainers())
    if slots > 0 then
        rec.bank = counts
        rec.bankScanned = time()
    end
end

local function ScanEquipped(rec)
    local counts = ReadEquipped()
    if counts then rec.equipped = counts end
end

local function ScanMail()
    if not mailOpen or InCombat() then return end
    local rec = PlayerRecord()
    if not rec then return end
    local counts = ReadMail()
    if counts then
        rec.mail = counts
        rec.mailScanned = time()
    end
end

local SCANNERS = { bags = ScanBags, bank = ScanBank, equipped = ScanEquipped }

-- Runs every source that is waiting. In combat they keep waiting for PLAYER_REGEN_ENABLED.
local function RunScans()
    scanScheduled = false
    if InCombat() then return end
    local rec = PlayerRecord()
    if not rec then return end
    for source, scan in pairs(SCANNERS) do
        if pendingScan[source] then
            pendingScan[source] = nil
            pcall(scan, rec)
        end
    end
end

local function ScheduleScans(delay)
    if scanScheduled or not next(pendingScan) then return end
    local after = TimerAfter()
    if not after then
        RunScans()
        return
    end
    scanScheduled = true
    after(delay or SCAN_DELAY, function()
        local ok = pcall(RunScans)
        if not ok then scanScheduled = false end
    end)
end

local function QueueScan(source, delay)
    pendingScan[source] = true
    ScheduleScans(delay)
end

-- PLAYER_LOGIN: who and where this is, then the first scans.
local function InitInventory()
    local okName, name = pcall(_G.UnitName, "player")
    local okRealm, realm = pcall(_G.GetRealmName)
    playerName = okName and PlainString(name) or nil
    playerRealm = okRealm and PlainString(realm) or nil
    local rec = PlayerRecord()
    if not rec then return end
    local okClass, _, class = pcall(_G.UnitClass, "player")
    class = okClass and PlainString(class) or nil
    if class then rec.class = class end
    local okFaction, faction = pcall(_G.UnitFactionGroup, "player")
    faction = okFaction and PlainString(faction) or nil
    if faction then rec.faction = faction end
    UpdateGold()
    pendingScan.bags, pendingScan.equipped = true, true
    ScheduleScans(LOGIN_SCAN_DELAY)
end

-- ---- reading the records --------------------------------------------------

local function ClassColored(name, class)
    local colors = _G.RAID_CLASS_COLORS
    local c = type(class) == "string" and type(colors) == "table" and colors[class]
    if type(c) == "table" then
        if type(c.colorStr) == "string" then return "|c" .. c.colorStr .. name .. "|r" end
        if type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
            return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, name)
        end
    end
    return name
end

-- This realm's records, the logged-in character first, then by name.
local function RealmCharacters()
    local realm = RealmData(false)
    local list = {}
    if not realm then return list end
    for name, rec in pairs(realm) do
        if type(name) == "string" and type(rec) == "table" then
            list[#list + 1] = { name = name, rec = rec, me = name == playerName }
        end
    end
    table.sort(list, function(a, b)
        if a.me ~= b.me then return a.me end
        return a.name < b.name
    end)
    return list
end

local function CountIn(t, itemID)
    local n = type(t) == "table" and t[itemID]
    return type(n) == "number" and n or 0
end

local SOURCES = { "bags", "bank", "equipped", "mail" }

local function CoinText(copper)
    local text = BF.Call(BF.API("C_CurrencyInfo", "GetCoinTextureString") or BF.API("GetCoinTextureString"), copper)
    if type(text) == "string" then return text end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    return string.format("%dg %ds %dc", g, s, copper % 100)
end

-- ---- item tooltip -----------------------------------------------------------

local function FollowClears(tooltip)
    if clearHooked[tooltip] then return true end
    if type(tooltip.HookScript) ~= "function" then return false end
    if type(tooltip.HasScript) == "function" and not tooltip:HasScript("OnTooltipCleared") then return false end
    local ok = pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", function(tt) tooltipGuard[tt] = nil end)
    if ok then clearHooked[tooltip] = true end
    return ok
end

local function AddCountLines(tooltip, itemID)
    if not CountsOn() or type(tooltip) ~= "table" or type(tooltip.AddLine) ~= "function" then return end
    itemID = PlainNumber(itemID)
    if not itemID then return end
    -- Once per display: the guard is released when the tooltip is cleared for the next one.
    if tooltipGuard[tooltip] == itemID then return end
    if FollowClears(tooltip) then tooltipGuard[tooltip] = itemID end

    local rows, total, sourceCount = {}, 0, 0
    for _, ch in ipairs(RealmCharacters()) do
        local parts, sum = {}, 0
        for _, source in ipairs(SOURCES) do
            local n = CountIn(ch.rec[source], itemID)
            if n > 0 then
                parts[#parts + 1] = source .. " " .. n
                sum = sum + n
            end
        end
        if sum > 0 then
            rows[#rows + 1] = ClassColored(ch.name, ch.rec.class) .. ": " .. sum .. " (" .. table.concat(parts, DOT) .. ")"
            total = total + sum
            sourceCount = #parts
        end
    end
    if #rows == 0 then return end
    for _, line in ipairs(rows) do tooltip:AddLine(line, 1, 1, 1) end
    if #rows > 1 or sourceCount > 1 then
        tooltip:AddLine("Total: " .. total, 1, 0.82, 0)
    end
    -- An older tooltip does not grow to fit lines added after it was sized.
    if type(tooltip.IsShown) == "function" and tooltip:IsShown() and type(tooltip.Show) == "function" then
        tooltip:Show()
    end
end

local function OnTooltipItemData(tooltip, data)
    if type(data) ~= "table" then return end
    pcall(AddCountLines, tooltip, data.id)
end

-- Fallback for a client without TooltipDataProcessor.
local function OnTooltipSetItem(tooltip)
    if type(tooltip.GetItem) ~= "function" then return end
    local ok, _, link = pcall(tooltip.GetItem, tooltip)
    link = ok and PlainString(link) or nil
    local id = link and tonumber(link:match("item:(%d+)"))
    if id then pcall(AddCountLines, tooltip, id) end
end

local function HookTooltips()
    if tooltipsHooked then return end
    tooltipsHooked = true
    local tdp, enum = _G.TooltipDataProcessor, _G.Enum
    local item = type(enum) == "table" and type(enum.TooltipDataType) == "table" and enum.TooltipDataType.Item
    if type(tdp) == "table" and type(tdp.AddTooltipPostCall) == "function" and item ~= nil then
        tdp.AddTooltipPostCall(item, OnTooltipItemData)
        return
    end
    for _, tip in ipairs({ _G.GameTooltip, _G.ItemRefTooltip }) do
        if type(tip) == "table" and type(tip.HookScript) == "function"
            and (type(tip.HasScript) ~= "function" or tip:HasScript("OnTooltipSetItem")) then
            tip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
        end
    end
end

-- ---- gold -------------------------------------------------------------------

-- This realm's gold: rows of { name, class, gold } in the usual order, and the total.
local function GoldRows()
    UpdateGold()
    local rows, total = {}, 0
    for _, ch in ipairs(RealmCharacters()) do
        local gold = ch.rec.gold
        if type(gold) == "number" then
            rows[#rows + 1] = { name = ch.name, class = ch.rec.class, gold = gold }
            total = total + gold
        end
    end
    return rows, total
end

local function OnMoneyEnter(self)
    local tip = _G.GameTooltip
    if not tip or not db then return end
    local rows, total = GoldRows()
    if #rows == 0 then return end
    -- Blizzard's own tooltip, if it showed one for this frame, keeps its lines; ours follow.
    if tip.GetOwner and tip:GetOwner() == self and tip:IsShown() then
        tip:AddLine(" ")
    else
        tip:SetOwner(self, "ANCHOR_TOPLEFT")
    end
    tip:AddLine("Gold on " .. (playerRealm or "this realm"))
    for _, r in ipairs(rows) do
        tip:AddDoubleLine(ClassColored(r.name, r.class), CoinText(r.gold), 1, 1, 1, 1, 1, 1)
    end
    tip:AddDoubleLine("Total", CoinText(total), 1, 0.82, 0, 1, 1, 1)
    tip:Show()
end

local function OnMoneyLeave(self)
    local tip = _G.GameTooltip
    if tip and tip.GetOwner and tip:GetOwner() == self then tip:Hide() end
end

local function HookMoneyFrame(frame)
    if type(frame) ~= "table" or moneyHooked[frame] or type(frame.HookScript) ~= "function" then return end
    moneyHooked[frame] = true
    -- The coin buttons sit on top of the money frame and take the mouse, so they are hooked too.
    -- Only OnEnter and OnLeave: their clicks stay Blizzard's.
    local targets = { frame }
    local name = type(frame.GetName) == "function" and frame:GetName() or nil
    for _, coin in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
        local b = frame[coin]
        if type(b) ~= "table" and name then b = _G[name .. coin] end
        if type(b) == "table" and type(b.HookScript) == "function" then targets[#targets + 1] = b end
    end
    for _, t in ipairs(targets) do
        if type(t.HasScript) ~= "function" or t:HasScript("OnEnter") then
            pcall(t.HookScript, t, "OnEnter", function(...) pcall(OnMoneyEnter, ...) end)
            pcall(t.HookScript, t, "OnLeave", function(...) pcall(OnMoneyLeave, ...) end)
        end
    end
end

-- The Combined Backpack's money frame and the separate backpack's, under whichever name or key
-- this client gives them.
local function HookMoneyFrames()
    local combined = GetBagFrame()
    if combined then HookMoneyFrame(combined.MoneyFrame) end
    HookMoneyFrame(_G.ContainerFrameCombinedBagsMoneyFrame)
    local backpack = _G.ContainerFrame1
    if type(backpack) == "table" then HookMoneyFrame(backpack.MoneyFrame) end
    HookMoneyFrame(_G.ContainerFrame1MoneyFrame)
end

local function CountMoneyHooks()
    local n = 0
    for _ in pairs(moneyHooked) do n = n + 1 end
    return n
end

-- ---- commands and settings ------------------------------------------------

local function SetCounts(on)
    if not db then return end
    if on == nil then on = not CountsOn() end
    db.showCounts = on and true or false
    Print("item counts in tooltip: " .. OnOff(db.showCounts))
end

local function SetAutoSort(on)
    if not db then return end
    if on == nil then on = not db.autoSort end
    db.autoSort = on and true or false
    Print("auto clean-up when the bags open: " .. OnOff(db.autoSort))
end

local function PrintGold()
    local rows, total = GoldRows()
    if #rows == 0 then
        Print("no gold recorded on this realm yet.")
        return
    end
    Print("gold on " .. (playerRealm or "this realm") .. ":")
    for _, r in ipairs(rows) do
        Print("  " .. ClassColored(r.name, r.class) .. ": " .. CoinText(r.gold))
    end
    Print("  Total: " .. CoinText(total))
end

local function ForgetCharacter(who)
    local realm = RealmData(false)
    who = who and who:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if who == "" then
        Print("/bbf forget <name> - remove a character from this realm's item counts and gold.")
        return
    end
    local key
    if realm then
        for name in pairs(realm) do
            if type(name) == "string" and name:lower() == who:lower() then key = name end
        end
    end
    if not key then
        Print("no character named " .. who .. " is recorded on " .. (playerRealm or "this realm") .. ".")
    elseif key == playerName then
        Print("you are logged in as " .. key .. "; that character cannot be forgotten here.")
    else
        realm[key] = nil
        Print("removed " .. key .. " from " .. playerRealm .. ": its bags, bank, equipped, mail and gold.")
    end
end

local function Ago(t)
    if type(t) ~= "number" then return "never" end
    local s = math.max(0, time() - t)
    if s < 3600 then return string.format("%d min ago", math.floor(s / 60)) end
    if s < 86400 then return string.format("%d h ago", math.floor(s / 3600)) end
    return string.format("%d d ago", math.floor(s / 86400))
end

local function InventoryStatus()
    local rec = playerName and RealmData(false) and RealmData(false)[playerName]
    rec = type(rec) == "table" and rec or {}
    local chars, frames = #RealmCharacters(), CountMoneyHooks()
    return string.format("inventory: %d character%s on %s%scounts %s%sbank scanned %s%smail scanned %s%sgold hover on %d money frame%s",
        chars, chars == 1 and "" or "s", playerRealm or "?", DOT, OnOff(CountsOn()), DOT, Ago(rec.bankScanned), DOT,
        Ago(rec.mailScanned), DOT, frames, frames == 1 and "" or "s")
end

-- ---------------------------------------------------------------------------
-- Do-not-sell item lock (since 1.9)
--
-- Alt + left-click an item in any bag window BBF covers (the Combined Backpack, the separate
-- bags ContainerFrame1-13, which include the bank bags, and the bank's own slots: BankPanel on
-- Forever, BankFrameItemN on an older client) toggles a lock on that item ID, so every copy of
-- it is locked. Locks are kept per character in BetterBagsForeverCharDB.lockedItems[itemID]
-- (the value is the item link last seen, or true). A locked item shows a small padlock in the
-- bottom-left corner of its slot (the stack count sits bottom-right) and is kept from a merchant:
--
--   right-click  while a merchant is open, each locked slot gets an invisible guard button of
--                our own on top of Blizzard's item button. The guard takes the right-click, so
--                Blizzard's OnClick (C_Container.UseContainerItem, which sells at a merchant)
--                never runs for it, and prints "<link> is locked - Alt-click to unlock". Left
--                clicks and drags pass through to Blizzard's button (SetPassThroughButtons), so
--                the item can still be moved; mouse motion propagates too, so its tooltip still
--                shows. On a client that cannot pass the left button through, the guard takes
--                it as well: Alt-click still unlocks, a plain left-click just prints the message.
--   drag/drop    while a merchant is open and the cursor holds a locked item (polled every
--                0.05 s, plus CURSOR_CHANGED), a guard of our own covers MerchantFrame. Dropping
--                or clicking on it prints the same message and calls ClearCursor(), which puts
--                the item back in its slot. Blizzard's merchant code never sees the drop.
--   Sell Junk    the same kind of guard covers Blizzard's MerchantSellAllJunkButton while a
--                locked grey item sits in a bag that a junk sale would empty.
--   safety net   if a locked item is sold anyway (another addon, a path not covered here), and
--                within 3 s both its bag count drops and a new buyback entry of that item and
--                that stack size shows up, it is bought back once with BuybackItem.
--
-- Taint: no Blizzard function or script is replaced and no Blizzard button is clicked. The
-- guards are separate frames of our own that sit on top and take the mouse, so for a blocked
-- click Blizzard's handlers simply do not run; nothing of ours ever runs inside Blizzard's click
-- path. Alt-click is seen through HookScript (PreClick and OnClick), which only adds a handler
-- after Blizzard's. The padlock is a texture added to the item button; everything else lives in
-- weak tables of our own, so no field is written into a Blizzard frame. A guard is never shown
-- or hidden while it is protected in combat.
-- ---------------------------------------------------------------------------

local charDB                    -- BetterBagsForeverCharDB, bound at ADDON_LOADED
-- The entry points the slash command, the hooks and the event handler need; everything else of
-- the item lock is scoped to the function below, since the main chunk is close to Lua's limit
-- of 200 locals and a do-block would still count against it.
local Lock = {}

local function BuildItemLock()
    local merchantOpen = false
    local lockOverlay = setmetatable({}, { __mode = "k" })    -- item button -> padlock texture
    local lockGuard = setmetatable({}, { __mode = "k" })      -- item button -> our guard button
    local lockHooked = setmetatable({}, { __mode = "k" })     -- item buttons whose clicks we follow
    local lockFrameHooked = setmetatable({}, { __mode = "k" })
    local legacyBankButtons = setmetatable({}, { __mode = "k" })
    local lockRefreshPending = false
    local lockVisuals = false       -- a padlock or guard exists, so refreshes are needed even with no locks
    local padlockSource             -- which texture the padlock ended up with, for /bbf status
    local guardPassThrough          -- nil until a guard exists; then whether left clicks pass through
    local clickCursorBefore         -- what the cursor held right before an item button click
    local merchantGuard, junkGuard, cursorWatcher

    local PADLOCK_SIZE = 13
    local PADLOCK_ATLASES = { "Padlock", "AdventureMapIcon-Lock" }
    local PADLOCK_FILES = { "Interface\\PetBattles\\PetBattle-LockIcon", "Interface\\Buttons\\LockButton-Locked-Up" }
    local CURSOR_POLL = 0.05        -- seconds between cursor checks while a merchant is open
    local SOLD_CHECK_DELAY = 0.4    -- bag and buyback events are coalesced over this long
    local SOLD_WINDOW = 3           -- seconds a bag drop and a new buyback entry may lie apart

    local function LockedItems()
        return charDB and charDB.lockedItems
    end

    local function IsItemLocked(id)
        local items = LockedItems()
        return items ~= nil and id ~= nil and items[id] ~= nil
    end

    local function LockCount()
        local n = 0
        for _ in pairs(LockedItems() or {}) do n = n + 1 end
        return n
    end

    local function AltClickOnly()
        local alt = type(_G.IsAltKeyDown) == "function" and _G.IsAltKeyDown()
        local shift = type(_G.IsShiftKeyDown) == "function" and _G.IsShiftKeyDown()
        local ctrl = type(_G.IsControlKeyDown) == "function" and _G.IsControlKeyDown()
        return alt and not shift and not ctrl
    end

    -- The item link to show for an item id: the one given, the one saved with the lock, the
    -- client's, or a plain stand-in when the item is not cached yet.
    local function ItemLabel(id, link)
        if link then return link end
        local stored = LockedItems() and LockedItems()[id]
        if type(stored) == "string" then return stored end
        local ci = _G.C_Item
        local getInfo = (type(ci) == "table" and type(ci.GetItemInfo) == "function" and ci.GetItemInfo)
            or (type(_G.GetItemInfo) == "function" and _G.GetItemInfo)
        if getInfo then
            local ok, _, l = pcall(getInfo, id)
            l = ok and PlainString(l) or nil
            if l then return l end
        end
        return "item " .. tostring(id)
    end

    -- One slot: itemID, link, quality and whether it has no sell value; nil for an empty slot.
    local function SlotDetails(bag, slot)
        if bag == nil or slot == nil then return nil end
        local c = ContainerAPI()
        if c and type(c.GetContainerItemInfo) == "function" then
            local ok, info = pcall(c.GetContainerItemInfo, bag, slot)
            if not ok or type(info) ~= "table" then return nil end
            local link = PlainString(info.hyperlink)
            local id = PlainNumber(info.itemID) or (link and tonumber(link:match("item:(%d+)")))
            if not id then return nil end
            return id, link, PlainNumber(info.quality), Plain(info.hasNoValue) == true
        elseif type(_G.GetContainerItemInfo) == "function" then
            local ok, tex, _, _, quality, _, _, link, _, noValue, id = pcall(_G.GetContainerItemInfo, bag, slot)
            if not ok or not Plain(tex) then return nil end
            link = PlainString(link)
            id = PlainNumber(id) or (link and tonumber(link:match("item:(%d+)")))
            if not id then return nil end
            return id, link, PlainNumber(quality), Plain(noValue) == true
        end
        return nil
    end

    -- Bag and slot of an item button: a bank tab button of Forever's BankPanel, a classic bank slot,
    -- or an ordinary container button.
    local function LockButtonSlot(button)
        if type(button.GetBankTabID) == "function" and type(button.GetContainerSlotID) == "function" then
            local okBag, bag = pcall(button.GetBankTabID, button)
            local okSlot, slot = pcall(button.GetContainerSlotID, button)
            return okBag and PlainNumber(bag) or nil, okSlot and PlainNumber(slot) or nil
        end
        if legacyBankButtons[button] then
            return PlainNumber(_G.BANK_CONTAINER) or -1, PlainNumber(button:GetID())
        end
        local bag, slot = ButtonBagAndSlot(button)
        return PlainNumber(bag), PlainNumber(slot)
    end

    local function LockedMessage(label)
        Print(label .. " is locked - Alt-click to unlock")
    end

    -- ---- the snapshot the safety net compares against -------------------------

    local lockSnapshot              -- itemID -> count of locked items in the carried bags
    local buybackSnapshot           -- the buyback list as last seen
    local pendingDrops = {}         -- itemID -> { n, t }: locked items that left the bags
    local pendingSales = {}         -- new buyback entries of locked items, { id, link, qty, t }
    local soldCheckToken = 0

    local function LockedCarriedCounts()
        local counts = {}
        for _, bag in ipairs(CarriedContainers()) do
            for slot = 1, ContainerSize(bag) do
                local id, n = SlotItem(bag, slot)
                if id and IsItemLocked(id) then counts[id] = (counts[id] or 0) + n end
            end
        end
        return counts
    end

    local function BuybackList()
        local list = {}
        if type(_G.GetNumBuybackItems) ~= "function" or type(_G.GetBuybackItemLink) ~= "function" then return list end
        local ok, n = pcall(_G.GetNumBuybackItems)
        n = ok and PlainNumber(n) or 0
        for i = 1, n do
            local okLink, link = pcall(_G.GetBuybackItemLink, i)
            link = okLink and PlainString(link) or nil
            local qty = 1
            if type(_G.GetBuybackItemInfo) == "function" then
                local okInfo, _, _, _, q = pcall(_G.GetBuybackItemInfo, i)
                qty = okInfo and PlainNumber(q) or 1
            end
            list[i] = { link = link, id = link and tonumber(link:match("item:(%d+)")), qty = qty }
        end
        return list
    end

    local function BuybackKey(e) return (e.link or "?") .. "#" .. tostring(e.qty) end

    -- The entries of after that were not in before. A sale appends at the end, and a full list
    -- drops its oldest entry first, so before shifted left by some s must match the start of after.
    -- A shorter list means something was bought back, never sold: no new entries.
    local function NewBuybackEntries(before, after)
        local nb, na = #before, #after
        if na < nb then return {} end
        for s = 0, nb do
            local keep = nb - s
            if keep <= na then
                local match = true
                for j = 1, keep do
                    if BuybackKey(after[j]) ~= BuybackKey(before[j + s]) then
                        match = false
                        break
                    end
                end
                if match then
                    local out = {}
                    for j = keep + 1, na do out[#out + 1] = after[j] end
                    return out
                end
            end
        end
        return {}
    end

    local function TakeLockSnapshot()
        lockSnapshot = LockedCarriedCounts()
        buybackSnapshot = BuybackList()
        pendingDrops, pendingSales = {}, {}
    end

    local function Now()
        return type(_G.GetTime) == "function" and _G.GetTime() or time()
    end

    -- The safety net. Runs only while a merchant is open, after bag or buyback changes have settled.
    -- An item is bought back only when both halves are seen within SOLD_WINDOW: its count in the
    -- bags dropped, and a new buyback entry of the same item with no more than the dropped amount
    -- appeared. Each sale is bought back at most once: both halves are used up by the attempt.
    local function CheckSoldLocked()
        if not merchantOpen or not lockSnapshot or not buybackSnapshot then return end
        local now, t = LockedCarriedCounts(), Now()
        for id, before in pairs(lockSnapshot) do
            local diff = before - (now[id] or 0)
            if diff > 0 then
                local d = pendingDrops[id]
                pendingDrops[id] = { n = (d and d.n or 0) + diff, t = t }
            end
        end
        lockSnapshot = now
        local list = BuybackList()
        for _, e in ipairs(NewBuybackEntries(buybackSnapshot, list)) do
            if e.id and IsItemLocked(e.id) then
                pendingSales[#pendingSales + 1] = { id = e.id, link = e.link, qty = e.qty, t = t }
            end
        end
        buybackSnapshot = list
        for id, d in pairs(pendingDrops) do
            if t - d.t > SOLD_WINDOW then pendingDrops[id] = nil end
        end
        for i = #pendingSales, 1, -1 do
            if t - pendingSales[i].t > SOLD_WINDOW then table.remove(pendingSales, i) end
        end

        for i = #pendingSales, 1, -1 do
            local sale = pendingSales[i]
            local drop = pendingDrops[sale.id]
            if drop and sale.qty <= drop.n then
                table.remove(pendingSales, i)
                drop.n = drop.n - sale.qty
                if drop.n <= 0 then pendingDrops[sale.id] = nil end
                -- Its place in the list now: the newest entry with the same link and stack size.
                local index
                for j = #list, 1, -1 do
                    if list[j].link == sale.link and list[j].qty == sale.qty then
                        index = j
                        break
                    end
                end
                local label = ItemLabel(sale.id, sale.link)
                local ok = index and type(_G.BuybackItem) == "function" and pcall(_G.BuybackItem, index)
                if ok then
                    table.remove(list, index)
                    Print(label .. " is locked but was sold; bought it back.")
                else
                    Print(label .. " is locked but was sold; buy it back on the merchant's Buyback tab.")
                end
            end
        end
        buybackSnapshot = list
    end

    local function QueueSoldCheck()
        if not merchantOpen then return end
        local after = TimerAfter()
        if not after then
            pcall(CheckSoldLocked)
            return
        end
        soldCheckToken = soldCheckToken + 1
        local token = soldCheckToken
        after(SOLD_CHECK_DELAY, function()
            if token == soldCheckToken then pcall(CheckSoldLocked) end
        end)
    end

    -- ---- padlock and guards on the item buttons --------------------------------

    -- The first padlock art this client has: an atlas when it exists, else a file. The choice made
    -- for the first texture is reused for every later one.
    local function ApplyPadlockArt(tex)
        if padlockSource and padlockSource.atlas then
            tex:SetAtlas(padlockSource.atlas)
            return
        elseif padlockSource and padlockSource.file then
            tex:SetTexture(padlockSource.file)
            return
        end
        if type(tex.SetAtlas) == "function" then
            for _, atlas in ipairs(PADLOCK_ATLASES) do
                if HasAtlas(atlas) then
                    local ok, result = pcall(tex.SetAtlas, tex, atlas)
                    if ok and result ~= false then
                        padlockSource = { atlas = atlas }
                        return
                    end
                end
            end
        end
        for _, file in ipairs(PADLOCK_FILES) do
            local ok, result = pcall(tex.SetTexture, tex, file)
            if ok and result ~= false then
                padlockSource = { file = file }
                return
            end
        end
    end

    local function CreatePadlock(button)
        local tex = button:CreateTexture(nil, "OVERLAY", nil, 7)
        tex:SetSize(PADLOCK_SIZE, PADLOCK_SIZE)
        tex:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 1, 1)
        ApplyPadlockArt(tex)
        tex:Hide()
        lockOverlay[button] = tex
        lockVisuals = true
        return tex
    end

    local QueueLockRefresh

    -- Locks or unlocks the item in one slot.
    local function ToggleLockAt(bag, slot)
        local items = LockedItems()
        if not items then return end
        local id, link = SlotDetails(bag, slot)
        if not id then return end
        local label = ItemLabel(id, link)
        if items[id] ~= nil then
            items[id] = nil
            Print(label .. " unlocked")
        else
            items[id] = link or true
            Print(label .. " locked")
        end
        if merchantOpen then lockSnapshot = LockedCarriedCounts() end
        QueueLockRefresh()
    end

    local function OnGuardClick(guard, mouse)
        local button = guard:GetParent()
        local bag, slot = LockButtonSlot(button)
        if mouse == "LeftButton" and AltClickOnly() then
            ToggleLockAt(bag, slot)
            return
        end
        local id, link = SlotDetails(bag, slot)
        if id then LockedMessage(ItemLabel(id, link)) end
    end

    -- Only used where mouse motion cannot reach the item button underneath.
    local function OnGuardEnter(guard)
        local tip = _G.GameTooltip
        if not tip or type(tip.SetBagItem) ~= "function" then return end
        local bag, slot = LockButtonSlot(guard:GetParent())
        if not bag or not slot then return end
        tip:SetOwner(guard, "ANCHOR_RIGHT")
        pcall(tip.SetBagItem, tip, bag, slot)
        tip:Show()
    end

    local function CreateGuard(button)
        local guard = CreateFrame("Button", nil, button)
        guard:SetAllPoints(button)
        guard:SetFrameLevel((button:GetFrameLevel() or 0) + 5)
        guard:EnableMouse(true)
        guard:RegisterForClicks("AnyUp")
        local passes = false
        if type(guard.SetPassThroughButtons) == "function" then
            passes = pcall(guard.SetPassThroughButtons, guard, "LeftButton") and true or false
        end
        guardPassThrough = passes
        local propagates = false
        if type(guard.SetPropagateMouseMotion) == "function" then
            propagates = pcall(guard.SetPropagateMouseMotion, guard, true) and true or false
        end
        if not propagates then
            guard:SetScript("OnEnter", function(self) pcall(OnGuardEnter, self) end)
            guard:SetScript("OnLeave", function(self)
                local tip = _G.GameTooltip
                if tip and tip.GetOwner and tip:GetOwner() == self then tip:Hide() end
            end)
        end
        guard:SetScript("OnClick", function(self, mouse) pcall(OnGuardClick, self, mouse) end)
        guard:Hide()
        lockGuard[button] = guard
        lockVisuals = true
        return guard
    end

    local function CursorHoldsItem()
        if type(_G.GetCursorInfo) ~= "function" then return false end
        return _G.GetCursorInfo() == "item"
    end

    local function OnItemPreClick()
        clickCursorBefore = CursorHoldsItem()
    end

    -- Runs after Blizzard's own OnClick. Alt + left-click toggles the lock; if that click put the
    -- item on the cursor (Blizzard does not by default, but a client could), it goes straight back.
    local function OnItemClick(button, mouse)
        if mouse ~= "LeftButton" or not AltClickOnly() then return end
        if clickCursorBefore == false and CursorHoldsItem() and type(_G.ClearCursor) == "function" then
            _G.ClearCursor()
        end
        clickCursorBefore = nil
        ToggleLockAt(LockButtonSlot(button))
    end

    local function HookLockButton(button)
        if lockHooked[button] or type(button.HookScript) ~= "function" then return end
        lockHooked[button] = true
        if type(button.HasScript) ~= "function" or button:HasScript("PreClick") then
            pcall(button.HookScript, button, "PreClick", function() pcall(OnItemPreClick) end)
        end
        pcall(button.HookScript, button, "OnClick", function(self, mouse) pcall(OnItemClick, self, mouse) end)
    end

    local function UpdateLockButton(button)
        HookLockButton(button)
        local bag, slot
        if IsOnScreen(button) then bag, slot = LockButtonSlot(button) end
        local id, link = SlotDetails(bag, slot)
        local locked = IsItemLocked(id)
        -- Keep the saved link current, so /bbf locked can show it while the item is not cached.
        if locked and link and LockedItems()[id] == true then LockedItems()[id] = link end
        local tex = lockOverlay[button]
        if locked and not tex then tex = CreatePadlock(button) end
        if tex then tex:SetShown(locked) end
        local wantGuard = locked and merchantOpen
        local guard = lockGuard[button]
        if wantGuard and not guard and not InCombat() then guard = CreateGuard(button) end
        if guard and guard:IsShown() ~= wantGuard and not Blocked(guard) then guard:SetShown(wantGuard) end
    end

    -- Every frame that holds item buttons: the Combined Backpack, the separate bags (bank bags
    -- included) and Forever's BankPanel.
    local function LockItemFrames()
        local list = {}
        local function add(f)
            if type(f) == "table" and type(f.GetChildren) == "function" then list[#list + 1] = f end
        end
        add(GetBagFrame())
        local n = math.max(PlainNumber(_G.NUM_CONTAINER_FRAMES) or 0, 13)
        for i = 1, n do add(_G["ContainerFrame" .. i]) end
        add(_G.BankPanel)
        return list
    end

    local function LockButtons()
        local out, seen = {}, {}
        local function add(b)
            if type(b) == "table" and not seen[b] and type(b.GetID) == "function" and type(b.CreateTexture) == "function" then
                seen[b] = true
                out[#out + 1] = b
            end
        end
        for _, frame in ipairs(LockItemFrames()) do
            if type(frame.EnumerateValidItems) == "function" then
                -- A frame's Items list gives (index, button); a pool gives (button, true).
                pcall(function()
                    for a, b in frame:EnumerateValidItems() do add(type(a) == "table" and a or b) end
                end)
            end
            for _, b in ipairs(ItemButtons(frame)) do add(b) end
        end
        -- The classic bank window's own slots.
        local slots = PlainNumber(_G.NUM_BANKGENERIC_SLOTS) or 28
        for i = 1, slots do
            local b = _G["BankFrameItem" .. i]
            if type(b) ~= "table" then break end
            legacyBankButtons[b] = true
            add(b)
        end
        return out
    end

    -- A locked grey item that Blizzard's Sell Junk would sell: its link, or nil.
    local function LockedJunkLabel()
        if LockCount() == 0 then return nil end
        local c = ContainerAPI()
        local flags = type(_G.Enum) == "table" and _G.Enum.BagSlotFlags
        local exclude = type(flags) == "table" and flags.ExcludeJunkSell or nil
        for _, bag in ipairs(CarriedContainers()) do
            local skip = false
            if exclude ~= nil and c and type(c.GetBagSlotFlag) == "function" then
                local ok, v = pcall(c.GetBagSlotFlag, bag, exclude)
                skip = ok and Plain(v) == true
            end
            if not skip then
                for slot = 1, ContainerSize(bag) do
                    local id, link, quality, noValue = SlotDetails(bag, slot)
                    if id and quality == 0 and not noValue and IsItemLocked(id) then return ItemLabel(id, link) end
                end
            end
        end
        return nil
    end

    local function UpdateJunkGuard()
        local button = _G.MerchantSellAllJunkButton
        if type(button) ~= "table" or type(button.GetFrameLevel) ~= "function" then return end
        local label = merchantOpen and LockedJunkLabel() or nil
        if label and not junkGuard then
            junkGuard = CreateFrame("Button", nil, button)
            junkGuard:SetAllPoints(button)
            junkGuard:SetFrameLevel((button:GetFrameLevel() or 0) + 5)
            junkGuard:EnableMouse(true)
            junkGuard:RegisterForClicks("AnyUp")
            junkGuard:SetScript("OnClick", function(self)
                Print("Sell Junk blocked: " .. (self.label or "a locked item") .. " is locked junk. Alt-click it in your bags to unlock it, or move it to a bag set not to sell junk.")
            end)
            junkGuard:SetScript("OnEnter", function(self)
                local tip = _G.GameTooltip
                if not tip then return end
                tip:SetOwner(self, "ANCHOR_RIGHT")
                tip:SetText("Sell Junk blocked by BetterBagsForever")
                tip:AddLine((self.label or "A locked item") .. " is locked and would be sold.", 1, 1, 1, true)
                tip:Show()
            end)
            junkGuard:SetScript("OnLeave", function(self)
                local tip = _G.GameTooltip
                if tip and tip.GetOwner and tip:GetOwner() == self then tip:Hide() end
            end)
            lockVisuals = true
        end
        if junkGuard then
            junkGuard.label = label
            if junkGuard:IsShown() ~= (label ~= nil) and not Blocked(junkGuard) then junkGuard:SetShown(label ~= nil) end
        end
    end

    local function RefreshLocks()
        lockRefreshPending = false
        if not charDB then return end
        -- Nothing locked and nothing drawn yet: only make sure every button follows Alt-click.
        local idle = LockCount() == 0 and not lockVisuals
        for _, button in ipairs(LockButtons()) do
            pcall(idle and HookLockButton or UpdateLockButton, button)
        end
        if not idle then pcall(UpdateJunkGuard) end
    end

    QueueLockRefresh = function()
        if lockRefreshPending then return end
        lockRefreshPending = true
        local after = TimerAfter()
        if not after then
            pcall(RefreshLocks)
            lockRefreshPending = false
            return
        end
        after(0, function()
            local ok = pcall(RefreshLocks)
            if not ok then lockRefreshPending = false end
        end)
    end

    -- ---- the merchant drop guard -----------------------------------------------

    -- The locked item on the cursor: its id and link, or nil.
    local function CursorLockedItem()
        if type(_G.GetCursorInfo) ~= "function" then return nil end
        local kind, id, link = _G.GetCursorInfo()
        if kind ~= "item" then return nil end
        id = PlainNumber(id)
        if id and IsItemLocked(id) then return id, PlainString(link) end
        return nil
    end

    local function BlockCursorDrop()
        local id, link = CursorLockedItem()
        if not id then return end
        LockedMessage(ItemLabel(id, link))
        if type(_G.ClearCursor) == "function" then _G.ClearCursor() end
    end

    local function UpdateMerchantGuard()
        local merchant = _G.MerchantFrame
        if type(merchant) ~= "table" or type(merchant.GetFrameLevel) ~= "function" then return end
        local want = merchantOpen and CursorLockedItem() ~= nil
        if want and not merchantGuard then
            merchantGuard = CreateFrame("Button", nil, merchant)
            merchantGuard:SetAllPoints(merchant)
            merchantGuard:SetFrameStrata("DIALOG")
            merchantGuard:EnableMouse(true)
            merchantGuard:RegisterForClicks("AnyUp", "AnyDown")
            merchantGuard:SetScript("OnClick", function() pcall(BlockCursorDrop) end)
            merchantGuard:SetScript("OnReceiveDrag", function() pcall(BlockCursorDrop) end)
            merchantGuard:Hide()
        end
        if merchantGuard and merchantGuard:IsShown() ~= want and not Blocked(merchantGuard) then
            merchantGuard:SetShown(want)
        end
    end

    local function SetMerchantOpen(open)
        merchantOpen = open and true or false
        if merchantOpen then
            TakeLockSnapshot()
            if not cursorWatcher then
                cursorWatcher = CreateFrame("Frame")
                local elapsedSince = 0
                cursorWatcher:SetScript("OnUpdate", function(_, elapsed)
                    elapsedSince = elapsedSince + (elapsed or 0)
                    if elapsedSince < CURSOR_POLL then return end
                    elapsedSince = 0
                    pcall(UpdateMerchantGuard)
                end)
            end
            cursorWatcher:Show()
        else
            lockSnapshot, buybackSnapshot = nil, nil
            pendingDrops, pendingSales = {}, {}
            if cursorWatcher then cursorWatcher:Hide() end
        end
        pcall(UpdateMerchantGuard)
        QueueLockRefresh()
    end

    -- Follows every bag frame's OnShow and item updates, once per frame.
    local function HookLockFrames()
        for _, frame in ipairs(LockItemFrames()) do
            if not lockFrameHooked[frame] then
                lockFrameHooked[frame] = true
                if type(frame.HookScript) == "function" then
                    pcall(frame.HookScript, frame, "OnShow", function() QueueLockRefresh() end)
                end
                for _, method in ipairs({ "UpdateItems", "GenerateItemSlotsForSelectedTab", "RefreshAllItemsForSelectedTab" }) do
                    if type(frame[method]) == "function" then
                        pcall(hooksecurefunc, frame, method, function() QueueLockRefresh() end)
                    end
                end
            end
        end
    end

    -- ---- commands -----------------------------------------------------------------

    local function PrintLockedItems()
        local items = LockedItems()
        local ids = {}
        for id in pairs(items or {}) do ids[#ids + 1] = id end
        if #ids == 0 then
            Print("no items are locked. Alt-click an item in your bags to lock it.")
            return
        end
        table.sort(ids)
        Print(#ids .. " locked item" .. (#ids == 1 and "" or "s") .. " (never sold to a merchant; Alt-click to unlock):")
        for _, id in ipairs(ids) do Print("  " .. ItemLabel(id)) end
    end

    local function UnlockAll(confirmed)
        local n = LockCount()
        if n == 0 then
            Print("no items are locked.")
            return
        end
        if not confirmed then
            Print("this unlocks all " .. n .. " locked item" .. (n == 1 and "" or "s") .. ". Type /bbf unlockall yes to confirm.")
            return
        end
        charDB.lockedItems = {}
        if merchantOpen then lockSnapshot = LockedCarriedCounts() end
        Print("unlocked all " .. n .. " item" .. (n == 1 and "" or "s") .. ".")
        QueueLockRefresh()
    end

    function Lock.Status()
        local art = padlockSource and (padlockSource.atlas and ("atlas " .. padlockSource.atlas) or padlockSource.file)
            or "not drawn yet"
        local pass = guardPassThrough == nil and "not used yet" or (guardPassThrough and "yes" or "no")
        return string.format("item locks: %d locked item%s%spadlock %s%sleft clicks pass the merchant guard: %s%sbuyback: %s",
            LockCount(), LockCount() == 1 and "" or "s", DOT, art, DOT, pass, DOT,
            type(_G.BuybackItem) == "function" and "yes" or "MISSING")
    end

    Lock.Count = LockCount
    Lock.PrintLocked = PrintLockedItems
    Lock.UnlockAll = UnlockAll
    Lock.HookFrames = HookLockFrames
    Lock.Refresh = QueueLockRefresh
    Lock.SetMerchantOpen = SetMerchantOpen
    Lock.QueueSoldCheck = QueueSoldCheck
    Lock.UpdateMerchantGuard = UpdateMerchantGuard
    Lock.MerchantOpen = function() return merchantOpen end
end
BuildItemLock()

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
    HookMoneyFrames()
end

local function OnBagFrameHidden()
    if moving then StopDrag() end
end

-- Alt-drag anywhere on the frame's own surface. Item buttons keep their own drag (picking up the
-- item), so this only fires on the border, the background and the empty strips.
-- Auto clean-up (since 1.8): when the bag window is opened, run the same clean-up as the button.
-- Called only from the frame's OnShow, never from a bag event, so a sort that fires BAG_UPDATE
-- cannot start another one. It stays silent when it cannot run: combat, a clean-up already
-- running, an item on the cursor or a locked item (a sort or a move is in progress).
local function AnyBagItemLocked()
    local numSlots = ContainerFunction("GetContainerNumSlots")
    if not numSlots then return false end
    for bag = 0, (tonumber(_G.NUM_BAG_SLOTS) or 4) do
        local n = tonumber(numSlots(bag)) or 0
        for slot = 1, n do
            local _, busy = ReadSlot(bag, slot)
            if busy then return true end
        end
    end
    return false
end

local function AutoCleanUp()
    if not (db and db.autoSort) then return end
    if cleanupRun or InCombat() or not GetSortFunction() then return end
    if type(_G.GetCursorInfo) == "function" and _G.GetCursorInfo() then return end
    if AnyBagItemLocked() then return end
    CleanUpBags()
end

local function OnBagFrameDragStart()
    local alt = type(_G.IsAltKeyDown) == "function" and _G.IsAltKeyDown()
    if alt then StartDrag() end
end

local function HookBlizzard()
    pcall(Lock.HookFrames)
    Lock.Refresh()
    if not anchorsHooked and type(_G.UpdateContainerFrameAnchors) == "function" then
        hooksecurefunc("UpdateContainerFrameAnchors", OnBlizzardAnchored)
        anchorsHooked = true
    end

    if frameHooked then return true end
    bagFrame = GetBagFrame()
    if not bagFrame then return false end
    frameHooked = true

    bagFrame:HookScript("OnShow", function()
        OnBagFrameShown()
        AutoCleanUp()
    end)
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
    HookMoneyFrames()
    if bagFrame:IsShown() then OnBagFrameShown() end
    return true
end

-- ---------------------------------------------------------------------------
-- Settings, shared by the slash command and the menu entries of the API
-- ---------------------------------------------------------------------------

local function ResetPosition()
    if not db then return end
    db.position = nil
    needsRestore = true
    ApplyPosition()
    Print(pendingApply and "position reset; it moves back once combat ends."
        or "position reset to Blizzard's default.")
end

local function SetLocked(on)
    if not db then return end
    db.locked = on and true or false
    UpdateDragHandle()
    Print(db.locked and "bags locked." or "bags unlocked: drag the title bar to move them.")
end

local function SetNativeHidden(hide)
    if not db then return end
    db.hideNativeButton = hide and true or false
    LayoutSearchRow()
    Print("Blizzard's own clean-up button is " .. (db.hideNativeButton and "hidden." or "shown."))
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function Yes(v) return v and "yes" or "MISSING" end

-- The intro BetterForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "Makes Blizzard's Combined Backpack movable and adds a Clean Up button left of the search box, with an optional Reverse order and auto clean-up when the bags open. Tooltips count an item across this realm's characters; hover the bag gold for everyone's gold. Nice to know: drag the title bar (or Alt-drag an empty spot) to move; right-click Clean Up toggles Reverse; Alt-click an item to lock it so no merchant can buy it. Clean-up does not run in combat."

local function PrintHelp()
    Print(INTRO)
    Print("the Combined Backpack is movable: drag its title bar, or Alt-drag an empty part of it.")
    Print("/bbf reset - put the bags back at Blizzard's default position")
    Print("/bbf lock | /bbf unlock - stop or allow moving (now: " .. ((db and db.locked) and "locked" or "unlocked") .. ")")
    Print("/bbf native hide | /bbf native show - hide or show Blizzard's own clean-up button (now: " .. ((db and db.hideNativeButton) and "hidden" or "shown") .. ")")
    Print("Clean Up button (left of the search box): left-click = Blizzard's own clean-up, the same as Forever's own button; right-click = toggle Reverse.")
    Print("/bbf reverse - toggle Reverse; /bbf reverse on | off to set it (now: " .. OnOff(ReverseOn()) .. "). With Reverse on, the whole Combined Backpack order is mirrored after Blizzard's clean-up.")
    Print("/bbf autosort on | off - clean up the bags automatically when they open (now: " .. OnOff(db and db.autoSort) .. ")")
    Print("/bbf stop - stop a running reversal")
    Print("/bbf counts on | off - item counts of this realm's characters in item tooltips (now: " .. OnOff(CountsOn()) .. ")")
    Print("/bbf gold - gold of this realm's characters (also: hover the gold in the bag window)")
    Print("/bbf forget <name> - remove a character from this realm's counts and gold")
    Print("Alt-click an item in your bags: lock or unlock it (all copies). A locked item shows a padlock and cannot be sold to a merchant.")
    Print("/bbf locked - list the locked items (now: " .. Lock.Count() .. ")")
    Print("/bbf unlockall yes - unlock every locked item")
    Print("/bbf status - what this client offers and what the next clean-up will do")
end

local function PrintStatus()
    Print("ContainerFrameCombinedBags: " .. Yes(GetBagFrame()))
    Print("BagItemSearchBox: " .. Yes(_G.BagItemSearchBox))
    Print("BagItemAutoSortButton: " .. Yes(GetNativeSortButton()))
    Print("C_Container.SortBags: " .. Yes(GetSortFunction()))
    Print("UpdateContainerFrameAnchors: " .. Yes(type(_G.UpdateContainerFrameAnchors) == "function"))
    Print("reverse (PickupContainerItem, GetCursorInfo, C_Timer): " .. Yes(CanReverse()))
    Print("combined bags in use: " .. (UsingCombinedBags() and "yes" or "no"))
    Print("Reverse: " .. OnOff(ReverseOn()))
    Print("auto clean-up on open: " .. OnOff(db and db.autoSort))
    Print("next clean-up: " .. (WillReverse() and "Blizzard's sort, then the whole Combined Backpack order mirrored"
        or "Blizzard's sort only"))
    local slots, reason = BuildVisualSlots()
    Print("slots found in the Combined Backpack: " .. (slots and tostring(#slots) or ("none (" .. reason .. ")")))
    if cleanupRun then
        Print(cleanupRun.phase == "wait" and "running: waiting for Blizzard's sort to finish"
            or string.format("running: reversing, %d swaps so far", cleanupRun.swaps))
    end
    Print("locked: " .. ((db and db.locked) and "yes" or "no"))
    local pos = db and db.position
    Print("saved position: " .. (pos and string.format("%.0f, %.0f", pos.x, pos.y) or "none (Blizzard default)"))
    Print(InventoryStatus())
    Print(Lock.Status())
end

local function OnSlash(msg)
    local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    msg = raw:lower():gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    if msg == "reset" then
        ResetPosition()
    elseif msg == "lock" then
        SetLocked(true)
    elseif msg == "unlock" then
        SetLocked(false)
    elseif msg == "native hide" or msg == "native show" then
        SetNativeHidden(msg == "native hide")
    elseif msg == "reverse" then
        SetReverse(nil)
    elseif msg == "reverse on" or msg == "reverse off" then
        SetReverse(msg == "reverse on")
    elseif msg == "autosort" then
        SetAutoSort(nil)
    elseif msg == "autosort on" or msg == "autosort off" then
        SetAutoSort(msg == "autosort on")
    elseif msg == "stop" then
        if not (cleanupRun and StopRun(StopMessage(cleanupRun, "stopped."))) then
            Print("nothing is running.")
        end
    elseif msg == "counts" then
        SetCounts(nil)
    elseif msg == "counts on" or msg == "counts off" then
        SetCounts(msg == "counts on")
    elseif msg == "gold" then
        PrintGold()
    elseif msg == "forget" or msg:find("^forget ") then
        ForgetCharacter(raw:match("^%S+%s+(.+)$"))
    elseif msg == "locked" then
        Lock.PrintLocked()
    elseif msg == "unlockall" or msg == "unlockall yes" then
        Lock.UnlockAll(msg == "unlockall yes")
    elseif msg == "status" then
        PrintStatus()
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterBagsForeverAPI
--
-- For BetterForever, the family hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterBagsForeverDB and change only through the
-- same functions /bbf uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "Reverse off · unlocked · moved"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func } and { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    return "Reverse " .. OnOff(ReverseOn()) .. " \194\183 " .. (db.locked and "locked" or "unlocked")
        .. " \194\183 " .. (db.position and "moved" or "default position")
        .. " \194\183 counts " .. OnOff(CountsOn())
        .. " \194\183 auto-sort " .. OnOff(db.autoSort)
end

local function MenuEntries()
    if not db then return {} end
    return {
        { text = "Lock position", checkbox = true, checked = function() return db.locked end,
          func = function() SetLocked(not db.locked) end },
        { text = "Reset position", func = ResetPosition },
        { text = "Reverse", checkbox = true, checked = ReverseOn,
          func = function() SetReverse(not ReverseOn()) end },
        { text = "Auto clean-up when bags open", checkbox = true,
          checked = function() return db.autoSort end,
          func = function() SetAutoSort(not db.autoSort) end },
        { text = "Hide Blizzard's own Clean Up button", checkbox = true,
          checked = function() return db.hideNativeButton end,
          func = function() SetNativeHidden(not db.hideNativeButton) end },
        { text = "Item counts in tooltip", checkbox = true, checked = CountsOn,
          func = function() SetCounts(not CountsOn()) end },
    }
end

_G.BetterBagsForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries()) end,
    SetMinimapHidden = function() end,
}

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterBagsForeverDB) ~= "table" then BetterBagsForeverDB = {} end
    db = BetterBagsForeverDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    -- Drop anything older versions saved that this one no longer uses (1.1's "mode", for one).
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    if type(db.reverse) ~= "boolean" then db.reverse = false end
    if type(db.showCounts) ~= "boolean" then db.showCounts = true end
    if type(db.autoSort) ~= "boolean" then db.autoSort = true end
    if db.inventory ~= nil and type(db.inventory) ~= "table" then db.inventory = nil end
    local pos = db.position
    if pos ~= nil and (type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number") then
        db.position = nil
    end
end

-- Per character: the item locks (since 1.9).
local function BindCharacterVariables()
    if type(BetterBagsForeverCharDB) ~= "table" then BetterBagsForeverCharDB = {} end
    charDB = BetterBagsForeverCharDB
    local clean = {}
    if type(charDB.lockedItems) == "table" then
        for id, v in pairs(charDB.lockedItems) do
            if type(id) == "number" and id > 0 and (v == true or type(v) == "string") then clean[id] = v end
        end
    end
    charDB.lockedItems = clean
    for k in pairs(charDB) do
        if k ~= "lockedItems" then charDB[k] = nil end
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
-- The inventory events, each checked: a name this client does not know is skipped, not raised.
for _, name in ipairs({ "PLAYER_MONEY", "PLAYER_EQUIPMENT_CHANGED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
                        "PLAYERBANKSLOTS_CHANGED", "MAIL_SHOW", "MAIL_INBOX_UPDATE", "MAIL_CLOSED",
                        "MERCHANT_SHOW", "MERCHANT_CLOSED", "MERCHANT_UPDATE", "CURSOR_CHANGED" }) do
    pcall(events.RegisterEvent, events, name)
end

-- Inventory events. Every one only marks a source and schedules a read; nothing here can raise.
local function OnInventoryEvent(event)
    if event == "BAG_UPDATE_DELAYED" then
        QueueScan("bags")
        if bankOpen then QueueScan("bank") end
    elseif event == "BAG_UPDATE" or event == "PLAYERBANKSLOTS_CHANGED" then
        if bankOpen then QueueScan("bank") end
    elseif event == "PLAYER_MONEY" then
        UpdateGold()
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        QueueScan("equipped")
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        QueueScan("bank")
    elseif event == "BANKFRAME_CLOSED" then
        -- One last read of whatever is still waiting, while the bank is still readable.
        if pendingScan.bank and not InCombat() then
            pendingScan.bank = nil
            local rec = PlayerRecord()
            if rec then pcall(ScanBank, rec) end
        end
        bankOpen = false
        pendingScan.bank = nil
    elseif event == "MAIL_SHOW" then
        mailOpen = true
        ScanMail()
    elseif event == "MAIL_INBOX_UPDATE" then
        ScanMail()
    elseif event == "MAIL_CLOSED" then
        mailOpen = false
    end
end

local INVENTORY_EVENTS = {
    BAG_UPDATE = true, BAG_UPDATE_DELAYED = true, PLAYERBANKSLOTS_CHANGED = true, PLAYER_MONEY = true,
    PLAYER_EQUIPMENT_CHANGED = true, BANKFRAME_OPENED = true, BANKFRAME_CLOSED = true,
    MAIL_SHOW = true, MAIL_INBOX_UPDATE = true, MAIL_CLOSED = true,
}

-- Item lock events: the padlocks follow the bags, the guards follow the merchant and the cursor.
local LOCK_REFRESH_EVENTS = {
    BAG_UPDATE = true, BAG_UPDATE_DELAYED = true, ITEM_LOCK_CHANGED = true, PLAYERBANKSLOTS_CHANGED = true,
    BANKFRAME_OPENED = true,
}

local function OnLockEvent(event)
    if event == "MERCHANT_SHOW" then
        pcall(Lock.HookFrames)
        Lock.SetMerchantOpen(true)
    elseif event == "MERCHANT_CLOSED" then
        if Lock.MerchantOpen() then Lock.SetMerchantOpen(false) end
    elseif event == "MERCHANT_UPDATE" then
        Lock.QueueSoldCheck()
    elseif event == "CURSOR_CHANGED" then
        if Lock.MerchantOpen() then Lock.UpdateMerchantGuard() end
    elseif LOCK_REFRESH_EVENTS[event] then
        if event == "BANKFRAME_OPENED" then pcall(Lock.HookFrames) end
        if event == "BAG_UPDATE_DELAYED" then Lock.QueueSoldCheck() end
        Lock.Refresh()
    end
end

events:SetScript("OnEvent", function(_, event, arg1)
    if INVENTORY_EVENTS[event] and db and playerName then
        pcall(OnInventoryEvent, event)
    end
    if charDB then pcall(OnLockEvent, event) end
    if event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED" or event == "ITEM_LOCK_CHANGED" then
        OnBagActivity()
    elseif event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            BindSavedVariables()
            BindCharacterVariables()
            HookTooltips()
            HookBlizzard()
        elseif db and not frameHooked then
            -- In case the bag frames arrive with a Blizzard addon loaded after us.
            HookBlizzard()
        elseif db then
            pcall(Lock.HookFrames)
        end
    elseif event == "PLAYER_LOGIN" then
        if db then
            HookBlizzard()
            HookMoneyFrames()
            pcall(InitInventory)
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        SetCombatLook(true)
        if cleanupRun then StopRun(StopMessage(cleanupRun, "combat.")) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        SetCombatLook(false)
        ScheduleScans()
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
