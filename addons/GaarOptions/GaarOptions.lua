--[[
  Gaar Options — one "Gaar" entry in Blizzard's AddOns options holding the settings for
  every Gaar addon, with a sub-entry per addon.

  Each Gaar addon exposes a builder (GaarCast_BuildOptions, GaarCC_BuildOptions, ...) that
  fills a frame it is handed, so the controls here are the same code as that addon's own
  window - nothing is duplicated or able to drift. Panels are built the first time they are
  shown, so load order between the addons doesn't matter.

  Registration goes through whichever options API this client has: the modern Settings
  namespace if present, otherwise InterfaceOptions_AddCategory. If neither exists the panels
  still work as standalone windows.

  /gaar opens it.
]]

local _G = _G
local ADDON = "Gaar"

-- Each module: the sub-entry name, the builder it exposes, and the addon folder it needs.
local MODULES = {
    { key = "cast",      title = "Cast",           builder = "GaarCast_BuildOptions",      folder = "GaarCast" },
    { key = "cc",        title = "Cooldown Count", builder = "GaarCC_BuildOptions",        folder = "GaarCC" },
    { key = "plates",    title = "Plates",         builder = "GaarPlates_BuildOptions",    folder = "GaarPlates" },
    { key = "threat",    title = "Threat",         builder = "GaarThreat_BuildOptions",    folder = "GaarThreat" },
    { key = "meter",     title = "Meter",          builder = "GaarMeter_BuildOptions",     folder = "GaarMeter" },
    { key = "bags",      title = "Bags",           builder = "GaarBags_BuildOptions",      folder = "GaarBags" },
    { key = "frames",    title = "Frames",         builder = "GaarFrames_BuildOptions",    folder = "GaarFrames" },
    { key = "loot",      title = "Looter",         builder = "GaarLooter_BuildOptions",    folder = "GaarLooter" },
    { key = "map",       title = "Map",            builder = "GaarMap_BuildOptions",       folder = "GaarMap" },
    { key = "spellbook", title = "Spell Book",     builder = "GaarSpellBook_BuildOptions", folder = "GaarSpellBook" },
}

-- ---------------------------------------------------------------------------
-- Options-API compatibility
-- ---------------------------------------------------------------------------
local useSettings = (type(Settings) == "table" and type(Settings.RegisterCanvasLayoutCategory) == "function")
local useLegacy = (type(_G.InterfaceOptions_AddCategory) == "function")

local parentCategory   -- Settings category object, or the frame itself on the legacy API
local categories = {}  -- [key] = category object / frame

local function RegisterParent(frame, name)
    frame.name = name
    if useSettings then
        local cat = Settings.RegisterCanvasLayoutCategory(frame, name)
        if Settings.RegisterAddOnCategory then Settings.RegisterAddOnCategory(cat) end
        return cat
    elseif useLegacy then
        InterfaceOptions_AddCategory(frame)
        return frame
    end
end

local function RegisterChild(frame, name, parentName)
    frame.name = name
    if useSettings and parentCategory and Settings.RegisterCanvasLayoutSubcategory then
        return Settings.RegisterCanvasLayoutSubcategory(parentCategory, frame, name)
    elseif useLegacy then
        frame.parent = parentName
        InterfaceOptions_AddCategory(frame)
        return frame
    end
end

local function OpenCategory(cat)
    if not cat then return false end
    if useSettings and Settings.OpenToCategory then
        local id = cat.GetID and cat:GetID() or cat
        Settings.OpenToCategory(id)
        return true
    elseif useLegacy and _G.InterfaceOptionsFrame_OpenToCategory then
        -- The legacy call lands on the wrong panel the first time; calling it twice is the
        -- long-standing workaround.
        InterfaceOptionsFrame_OpenToCategory(cat)
        InterfaceOptionsFrame_OpenToCategory(cat)
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Panels
-- ---------------------------------------------------------------------------
local function MakeCanvas(name)
    local f = CreateFrame("Frame", "GaarOptions" .. name .. "Panel", UIParent)
    f:Hide()
    return f
end

-- A module panel fills itself from that addon's own builder the first time it is shown.
local function BuildModulePanel(mod)
    local panel = MakeCanvas(mod.title:gsub("%s+", ""))

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Gaar " .. mod.title)

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", 0, -44)
    body:SetPoint("BOTTOMRIGHT", 0, 0)

    local built = false
    panel:SetScript("OnShow", function()
        if not built then
            built = true
            local build = _G[mod.builder]
            if type(build) == "function" then
                build(body)
            else
                local msg = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                msg:SetPoint("TOPLEFT", 16, -8); msg:SetWidth(520); msg:SetJustifyH("LEFT")
                msg:SetText("|cffff8080" .. mod.folder .. " isn't loaded.|r Enable it in the AddOns list and reload.")
            end
        end
        if body.gaarRefresh then body.gaarRefresh() end
    end)

    return panel
end

local function BuildParentPanel()
    local panel = MakeCanvas("Main")

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16); title:SetText("Gaar")

    local blurb = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    blurb:SetPoint("TOPLEFT", 16, -44); blurb:SetWidth(520); blurb:SetJustifyH("LEFT")
    blurb:SetText("Settings for the Gaar addons. Pick a sub-entry on the left, or use the shortcuts below.")

    local y = -84
    local quick = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    quick:SetPoint("TOPLEFT", 16, y); quick:SetText("Quick actions")
    y = y - 28

    -- Cast bar test toggle, right on the front page: it's the one thing you want while
    -- dragging bars around, and it stays on until switched off.
    local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testBtn:SetSize(220, 24); testBtn:SetPoint("TOPLEFT", 16, y)
    local function testLabel()
        if not _G.GaarCast_IsTesting then return "Test cast bars (Gaar Cast not loaded)" end
        return _G.GaarCast_IsTesting() and "Test cast bars: ON (click to stop)" or "Test cast bars: off"
    end
    testBtn:SetText(testLabel())
    testBtn:SetScript("OnClick", function(self)
        if _G.GaarCast_SetTesting and _G.GaarCast_IsTesting then
            _G.GaarCast_SetTesting(not _G.GaarCast_IsTesting())
        end
        self:SetText(testLabel())
    end)

    local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetBtn:SetSize(220, 24); resetBtn:SetPoint("TOPLEFT", 248, y)
    resetBtn:SetText("Cast bars: reset to Blizzard spot")
    resetBtn:SetScript("OnClick", function()
        if _G.GaarCast_ResetPositions then _G.GaarCast_ResetPositions() end
    end)
    y = y - 40

    local mm = CreateFrame("CheckButton", "GaarOptionsMinimapCheck", panel, "UICheckButtonTemplate")
    mm:SetSize(24, 24); mm:SetPoint("TOPLEFT", 16, y)
    _G["GaarOptionsMinimapCheckText"]:SetText("Minimap button")
    _G["GaarOptionsMinimapCheckText"]:SetFontObject(GameFontHighlight)
    mm:SetScript("OnClick", function(self)
        GaarOptionsDB = GaarOptionsDB or {}
        GaarOptionsDB.minimap = self:GetChecked() and true or false
        if _G.GaarOptions_ApplyMinimap then _G.GaarOptions_ApplyMinimap() end
    end)
    panel.minimapCheck = mm
    y = y - 34

    local loaded = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    loaded:SetPoint("TOPLEFT", 16, y); loaded:SetText("Modules")
    y = y - 24

    local rows = {}
    for _, mod in ipairs(MODULES) do
        local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("TOPLEFT", 24, y); fs:SetWidth(520); fs:SetJustifyH("LEFT")
        rows[#rows + 1] = { fs = fs, mod = mod }
        y = y - 20
    end
    y = y - 16

    local slash = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    slash:SetPoint("TOPLEFT", 16, y); slash:SetWidth(520); slash:SetJustifyH("LEFT")
    slash:SetText("Slash commands: /gaar (this panel)  |  /gaarcast, /gcast  |  /gaarcc, /gcc  |  /spellbook, /spells")

    panel:SetScript("OnShow", function()
        testBtn:SetText(testLabel())
        if panel.minimapCheck then
            panel.minimapCheck:SetChecked(not (GaarOptionsDB and GaarOptionsDB.minimap == false))
        end
        for _, row in ipairs(rows) do
            local present = type(_G[row.mod.builder]) == "function"
            row.fs:SetText((present and "|cff33ff99+|r " or "|cffff8080-|r ") .. "Gaar " .. row.mod.title ..
                (present and "" or "  (not loaded)"))
        end
    end)

    return panel
end

-- ---------------------------------------------------------------------------
-- Standalone fallback, used only if this client has neither options API
-- ---------------------------------------------------------------------------
local fallback
local function ShowFallback(key)
    if not fallback then
        fallback = CreateFrame("Frame", "GaarOptionsWindow", UIParent, "BackdropTemplate")
        fallback:SetSize(600, 560); fallback:SetPoint("CENTER")
        fallback:SetBackdrop({
            bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
            edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        fallback:SetFrameStrata("DIALOG")
        fallback:SetMovable(true); fallback:EnableMouse(true)
        fallback:SetScript("OnMouseDown", function(self) self:StartMoving() end)
        fallback:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)
        table.insert(UISpecialFrames, "GaarOptionsWindow")
        local close = CreateFrame("Button", nil, fallback, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -8, -8)
        fallback.pages = {}
        local x = 16
        for _, mod in ipairs(MODULES) do
            local page = CreateFrame("Frame", nil, fallback)
            page:SetPoint("TOPLEFT", 8, -70); page:SetPoint("BOTTOMRIGHT", -8, 12)
            page:Hide()
            local built = false
            page:SetScript("OnShow", function()
                if not built then
                    built = true
                    local build = _G[mod.builder]
                    if type(build) == "function" then build(page) end
                end
                if page.gaarRefresh then page.gaarRefresh() end
            end)
            fallback.pages[mod.key] = page
            local tab = CreateFrame("Button", nil, fallback, "UIPanelButtonTemplate")
            tab:SetSize(150, 22); tab:SetPoint("TOPLEFT", x, -40); tab:SetText(mod.title)
            tab:SetScript("OnClick", function()
                for _, p in pairs(fallback.pages) do p:Hide() end
                fallback.pages[mod.key]:Show()
            end)
            x = x + 154
        end
        local title = fallback:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 16, -16); title:SetText("Gaar")
    end
    for _, p in pairs(fallback.pages) do p:Hide() end
    local page = fallback.pages[key] or fallback.pages.cast
    if page then page:Show() end
    fallback:Show()
end

-- ---------------------------------------------------------------------------
-- Wire everything up
-- ---------------------------------------------------------------------------
if useSettings or useLegacy then
    local main = BuildParentPanel()
    parentCategory = RegisterParent(main, ADDON)
    categories.main = parentCategory
    for _, mod in ipairs(MODULES) do
        categories[mod.key] = RegisterChild(BuildModulePanel(mod), mod.title, ADDON)
    end
end

-- Returns true when it managed to open, so the addons' own slash commands can fall back.
function GaarOptions_Open(which)
    local cat = categories[which or "main"] or categories.main
    if cat and OpenCategory(cat) then return true end
    if not (useSettings or useLegacy) then
        ShowFallback(which)
        return true
    end
    return false
end
_G.GaarOptions_Open = GaarOptions_Open


-- ---------------------------------------------------------------------------
-- Minimap button
--
-- Sits on the minimap's edge at a saved angle and can be dragged around it. Written here
-- rather than pulled from LibDBIcon, which isn't installed and would be a dependency for
-- what amounts to thirty lines of trigonometry.
-- ---------------------------------------------------------------------------
local function DB()
    if type(GaarOptionsDB) ~= "table" then GaarOptionsDB = {} end
    local d = GaarOptionsDB
    if d.minimap == nil then d.minimap = true end
    if d.minimapAngle == nil then d.minimapAngle = 205 end
    return d
end

local minimapButton

-- Geometry read off a Blizzard frame can be secret on this client, and a secret cannot be
-- compared, divided, or even tested with "or" - the fallback itself is a boolean test. So it
-- has to be checked before it is touched at all.
local issecretvalue = _G.issecretvalue
local function Secret(a, b)
    if not issecretvalue then return false end
    if issecretvalue(a) then return true end
    return b ~= nil and issecretvalue(b) or false
end

local function PlaceButton()
    if not minimapButton then return end
    local angle = math.rad(DB().minimapAngle)
    local cos, sin = math.cos(angle), math.sin(angle)
    local x, y

    -- GetMinimapShape is the convention every minimap-button addon reads before placing
    -- itself, and GaarMap defines it when it squares the minimap. Honour it here too, or this
    -- button would be the one still arcing round a circle that is no longer drawn.
    local shape = _G.GetMinimapShape and _G.GetMinimapShape() or "ROUND"
    if shape == "SQUARE" then
        -- A fixed radius would bury the button inside the corners and float it off the flat
        -- sides. Stretching the vector until its longest component reaches the edge keeps it
        -- on the rim the whole way round.
        local mw = Minimap and Minimap:GetWidth()
        if Secret(mw) then mw = nil end   -- a secret width cannot be halved
        local half = (mw or 140) / 2 + 8
        local reach = math.max(math.abs(cos), math.abs(sin))
        if reach < 0.0001 then reach = 1 end
        x, y = half * cos / reach, half * sin / reach
    else
        -- 80 sits just outside the minimap art on the default round minimap
        x, y = 80 * cos, 80 * sin
    end

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end
-- GaarMap calls this once it has changed the shape, so the button moves with it rather than
-- waiting for the next drag.
_G.GaarOptions_PlaceMinimapButton = PlaceButton

local function BuildMinimapButton()
    if minimapButton or not Minimap then return minimapButton end

    local b = CreateFrame("Button", "GaarMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\GaarOptions\\mark")
    icon:SetSize(19, 19)
    icon:SetPoint("CENTER", 0, 0)
    b.icon = icon

    -- the ring every minimap button wears, so this one doesn't look pasted on
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)

    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    -- Dragging: the angle is taken from the cursor's offset to the minimap's centre, which
    -- keeps the button on the rim however the minimap is positioned or scaled.
    b:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            DB().minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            PlaceButton()
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self.dragging = nil
        self:SetScript("OnUpdate", nil)
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Gaar")
        GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
        GameTooltip:AddLine("Right-click: loot log", 1, 1, 1)
        GameTooltip:AddLine("Drag to move around the minimap", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if _G.GaarLooter_Toggle then
                _G.GaarLooter_Toggle()
            else
                GaarOptions_Open("main")
            end
        else
            GaarOptions_Open("main")
        end
    end)

    minimapButton = b
    PlaceButton()
    return b
end

local function ApplyMinimap()
    if DB().minimap then
        BuildMinimapButton()
        if minimapButton then minimapButton:Show() end
    elseif minimapButton then
        minimapButton:Hide()
    end
end
_G.GaarOptions_ApplyMinimap = ApplyMinimap

local minimapEv = CreateFrame("Frame")
minimapEv:RegisterEvent("PLAYER_LOGIN")
minimapEv:SetScript("OnEvent", function() ApplyMinimap() end)

SLASH_GAAROPTIONS1 = "/gaar"
SlashCmdList["GAAROPTIONS"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "" then GaarOptions_Open("main") else GaarOptions_Open(msg) end
end
