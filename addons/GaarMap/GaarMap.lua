--[[
  Gaar Map — move, scale and fade the world map, in the spirit of Mapster.

    * Resize from a corner grip. This drives the frame's scale rather than its width and
      height: the map is a canvas with its own pins and overlays, and scaling moves all of it
      together, where resizing would leave the contents laid out for the old size.
    * Fade while you move. Movement is read from GetUnitSpeed on a throttled tick rather than
      from PLAYER_STARTED_MOVING/STOPPED_MOVING, because the speed call is one this client is
      known to answer and needs no event to exist.

  /gaarmap for options (also under Gaar -> Map).

  Moving the map deliberately isn't here. WorldMapFrame is one of Blizzard's managed UI
  panels: the panel system anchors it and re-anchors it on every show, and detaching it from
  that system to allow dragging did not work on this client. Rather than leave a half-working
  drag in place, it was taken out - the scale and fade below do not need it.

  This client has the modern map frame - WorldMapFrame with a ScrollContainer, GetCanvas and
  BorderFrame - so that is what the code expects, and every piece of it is checked for before
  use rather than assumed.
]]

local _G = _G
local ADDON = "Gaar Map"

local function DB()
    if type(GaarMapDB) ~= "table" then GaarMapDB = {} end
    local d = GaarMapDB
    if d.scale == nil then d.scale = 1 end
    if d.fade == nil then d.fade = true end
    if d.moveAlpha == nil then d.moveAlpha = 0.35 end   -- alpha while running
    if d.locked == nil then d.locked = false end
    return d
end

local Map = _G.WorldMapFrame

-- ---------------------------------------------------------------------------
-- Position and scale
-- ---------------------------------------------------------------------------
local function ApplyScale()
    if not Map then return end
    Map:SetScale(DB().scale or 1)
end

local function ResetLayout()
    DB().scale = 1
    ApplyScale()
    print("|cff5599ff" .. ADDON .. ":|r map back to normal size.")
end
_G.GaarMap_Reset = ResetLayout

-- ---------------------------------------------------------------------------
-- Resize grip
-- ---------------------------------------------------------------------------
local grip

local function BuildGrip()
    if grip or not Map then return end
    grip = CreateFrame("Button", "GaarMapGrip", Map)
    grip:SetSize(18, 18)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetFrameStrata("HIGH")
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")

    -- Dragging the grip changes scale, so the distance dragged is converted into a scale
    -- delta rather than a new width.
    grip:SetScript("OnMouseDown", function(self)
        if DB().locked then return end
        local _, startY = GetCursorPosition()
        self.startY = startY
        self.startScale = DB().scale or 1
        self:SetScript("OnUpdate", function()
            local _, y = GetCursorPosition()
            local delta = (self.startY - y) / 400
            local s = math.max(0.5, math.min(2.0, self.startScale + delta))
            DB().scale = s
            Map:SetScale(s)
        end)
    end)
    grip:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Drag to resize the map")
        GameTooltip:AddLine(string.format("Scale: %.2f", DB().scale or 1), 1, 1, 1)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ---------------------------------------------------------------------------
-- Fade while moving
-- ---------------------------------------------------------------------------
local fader = CreateFrame("Frame")
local acc, faded = 0, false

fader:SetScript("OnUpdate", function(_, elapsed)
    if not Map or not Map:IsShown() then
        if faded then faded = false end
        return
    end
    acc = acc + elapsed
    if acc < 0.1 then return end
    acc = 0

    if not DB().fade then
        if faded then Map:SetAlpha(1); faded = false end
        return
    end

    local moving = (GetUnitSpeed and GetUnitSpeed("player") or 0) > 0
    if moving and not faded then
        Map:SetAlpha(DB().moveAlpha or 0.35)
        faded = true
    elseif not moving and faded then
        Map:SetAlpha(1)
        faded = false
    end
end)

-- ---------------------------------------------------------------------------
-- Start-up
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
    Map = _G.WorldMapFrame
    if not Map then
        print("|cffff6666" .. ADDON .. ":|r no WorldMapFrame on this client; nothing to do.")
        return
    end
    BuildGrip()
    ApplyScale()
    -- the map re-anchors itself every time it opens, so the scale is re-applied with it
    Map:HookScript("OnShow", ApplyScale)
end)

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------
local uid = 0
function GaarMap_BuildOptions(container)
    local refreshers = {}
    local y = -8

    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("World map")
    y = y - 28

    local function check(label, get, set)
        uid = uid + 1
        local nm = "GaarMapCheck" .. uid
        local c = CreateFrame("CheckButton", nm, container, "UICheckButtonTemplate")
        c:SetSize(24, 24); c:SetPoint("TOPLEFT", 16, y)
        c:SetChecked(get() and true or false)
        local fs = _G[nm .. "Text"]
        fs:SetText(label); fs:SetFontObject(GameFontHighlight)
        c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
        refreshers[#refreshers + 1] = function() c:SetChecked(get() and true or false) end
        y = y - 26
    end

    check("Fade the map while moving", function() return DB().fade end, function(v)
        DB().fade = v
        if not v and Map then Map:SetAlpha(1) end
    end)
    check("Lock the size", function() return DB().locked end, function(v) DB().locked = v end)
    y = y - 10

    local fadeLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fadeLabel:SetPoint("TOPLEFT", 18, y); fadeLabel:SetText("Faded to:")
    local x = 130
    for _, a in ipairs({ { "15%", 0.15 }, { "35%", 0.35 }, { "60%", 0.6 } }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(56, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(a[1])
        b:SetScript("OnClick", function() DB().moveAlpha = a[2] end)
        x = x + 58
    end
    y = y - 30

    local scaleLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    scaleLabel:SetPoint("TOPLEFT", 18, y); scaleLabel:SetText("Scale:")
    x = 130
    for _, sc in ipairs({ { "70%", 0.7 }, { "85%", 0.85 }, { "100%", 1 }, { "125%", 1.25 } }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(56, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(sc[1])
        b:SetScript("OnClick", function() DB().scale = sc[2]; ApplyScale() end)
        x = x + 58
    end
    y = y - 34

    local reset = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    reset:SetSize(170, 24); reset:SetPoint("TOPLEFT", 16, y)
    reset:SetText("Reset size")
    reset:SetScript("OnClick", ResetLayout)
    y = y - 34

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(340); hint:SetJustifyH("LEFT")
    hint:SetText("Resize from the grip in the bottom-right corner. It drives scale rather than width and height, so the pins and overlays scale with the map instead of being left behind. Moving the map is not offered: it is one of Blizzard's managed panels, which re-anchors it on every open, and prying it loose was not worth the risk of breaking the map itself.")
    y = y - 58

    container.gaarRefresh = function() for _, fn in ipairs(refreshers) do fn() end end
    return -y
end

local function OpenOptions()
    if _G.GaarOptions_Open and _G.GaarOptions_Open("map") then return end
    print("|cff5599ff" .. ADDON .. ":|r settings live under Gaar -> Map in the AddOns options.")
end
_G.GaarMap_Config = OpenOptions

SLASH_GAARMAP1 = "/gaarmap"
SLASH_GAARMAP2 = "/gmap"
SlashCmdList["GAARMAP"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "reset" then ResetLayout() else OpenOptions() end
end
