--[[
  BetterBagsForever - small fixes for the native "Combined Backpack" on WoW Forever.

  Forever ships the retail-style combined bag frame (ContainerFrameCombinedBags). This addon
  changes three things about it and nothing else:

    * The frame can be moved: drag its title bar, or Alt-drag any empty part of it. The position
      is saved in BetterBagsForeverDB and put back every time Blizzard re-anchors the bags.
    * A "Clean Up Bags" button sits on the left of the search box, because on Forever the native
      one (BagItemAutoSortButton) ends up hidden under the bag slot icons on the right.
    * /bbf for help, reset, lock and unlock.

  Names come from Blizzard's retail FrameXML (Interface/AddOns/Blizzard_UIPanels_Game/Mainline/
  ContainerFrame.xml and ContainerFrame.lua): ContainerFrameCombinedBags, BagItemSearchBox,
  BagItemAutoSortButton, UpdateContainerFrameAnchors, ContainerFrameSettingsManager. Every one
  of them is checked before use; when something is missing the matching feature simply does not
  switch on.

  Taint: Blizzard code is only ever followed, never replaced. Hooks go through hooksecurefunc
  and HookScript, no Blizzard function is called, and nothing protected is touched. If the bag
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
-- Clean-up button and search row
-- ---------------------------------------------------------------------------

local function SetCombatLook(inCombat)
    if not cleanupButton then return end
    local tex = cleanupButton:GetNormalTexture()
    if tex and tex.SetDesaturated then tex:SetDesaturated(inCombat) end
end

local function CleanUpBags()
    if InCombat() then
        Print("bags cannot be cleaned up in combat.")
        return false
    end
    local sort = GetSortFunction()
    if not sort then
        Print("this client has no C_Container.SortBags.")
        return false
    end
    local soundkit = _G.SOUNDKIT
    if type(_G.PlaySound) == "function" and type(soundkit) == "table" and soundkit.UI_BAG_SORTING_01 then
        _G.PlaySound(soundkit.UI_BAG_SORTING_01)
    end
    sort()
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
    tip:Show()
end

local function CreateCleanupButton()
    if cleanupButton or not bagFrame or not GetSearchBox() or not GetSortFunction() then return end
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
    b:SetScript("OnClick", CleanUpBags)
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
    Print("/bbf status - what this client offers")
end

local function PrintStatus()
    Print("ContainerFrameCombinedBags: " .. Yes(GetBagFrame()))
    Print("BagItemSearchBox: " .. Yes(_G.BagItemSearchBox))
    Print("BagItemAutoSortButton: " .. Yes(GetNativeSortButton()))
    Print("C_Container.SortBags: " .. Yes(GetSortFunction()))
    Print("UpdateContainerFrameAnchors: " .. Yes(type(_G.UpdateContainerFrameAnchors) == "function"))
    Print("using combined bags: " .. (UsingCombinedBags() and "yes" or "no"))
    local pos = db and db.position
    Print("saved position: " .. (pos and string.format("%.0f, %.0f", pos.x, pos.y) or "none (Blizzard default)"))
end

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
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
