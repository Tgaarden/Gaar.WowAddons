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
    if d.squareMinimap == nil then d.squareMinimap = true end
    if d.hideZoomButtons == nil then d.hideZoomButtons = true end
    if d.fillWidth == nil then d.fillWidth = true end   -- square matches the zone bar's width
    if d.squareSize == nil then d.squareSize = 0 end    -- 0 = take it from the zone bar
    if d.showClock == nil then d.showClock = true end
    if d.headerGap == nil then d.headerGap = 2 end      -- pixels between the zone bar and the map
    -- Only even gaps are offered, so an odd one saved before that would match no button and
    -- leave the panel looking as though nothing were selected.
    if d.headerGap % 2 ~= 0 then d.headerGap = d.headerGap + 1 end
    if d.locked == nil then d.locked = false end
    return d
end

local Map = _G.WorldMapFrame

-- ---------------------------------------------------------------------------
-- Position and scale
-- ---------------------------------------------------------------------------
-- Blizzard works the map cursor out against the scroll container's own scale, which stops
-- agreeing with the canvas once the frame itself is scaled. The zone highlight then lands on a
-- different zone from the one under the pointer, and clicks go with it.
--
-- Mapster carries the same correction and notes why it does not call through to the original:
-- two addons both fixing this by hooking would apply the correction twice. So this replaces
-- the method outright while a scale is in force, and puts the original back at 1, where the
-- two scales agree and there is nothing to correct.
local originalGetCursorPosition

local function ApplyCursorFix()
    local sc = Map and Map.ScrollContainer
    if not sc then return end
    if not originalGetCursorPosition then originalGetCursorPosition = sc.GetCursorPosition end

    if (DB().scale or 1) == 1 then
        sc.GetCursorPosition = originalGetCursorPosition
        return
    end

    sc.GetCursorPosition = function()
        local x, y = GetCursorPosition()
        local s = Map:GetEffectiveScale()
        return x / s, y / s
    end
end

local function ApplyScale()
    if not Map then return end
    Map:SetScale(DB().scale or 1)
    ApplyCursorFix()
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
-- Square minimap
--
-- The round shape is a mask texture, so swapping it for a plain white square is all the
-- shape change takes. The rest is Blizzard's round border art, which has to be hidden or it
-- keeps drawing a circle over the corners.
--
-- Other addons place their minimap buttons by asking GetMinimapShape(), so that function is
-- defined here. Without it every other addon's button would keep arcing round a circle that
-- is no longer there.
-- ---------------------------------------------------------------------------
-- Retail keeps these pieces but hangs them off MinimapCluster and Minimap instead of naming
-- them globally, so each entry is a plain global or a dotted path and Piece() takes either.
-- Confirmed by the probe on retail 12.1: MinimapBorder is gone, MinimapCluster.BorderTop and
-- MinimapCompassTexture are there. Nothing here asserts - a piece that does not resolve is a
-- piece this client does not have.
local ROUND_ART = {
    "MinimapBorder", "MinimapBorderTop", "MinimapNorthTag", "MinimapBackdrop",
    "MiniMapMailBorder", "MiniMapTrackingBorder", "MiniMapWorldBorder",
    "MinimapCluster.BorderTop", "MinimapCompassTexture", "Minimap.BorderTop",
}
local ZOOM_BUTTONS = { "MinimapZoomIn", "MinimapZoomOut", "Minimap.ZoomIn", "Minimap.ZoomOut" }

local function Piece(path)
    local node = _G
    for part in string.gmatch(path, "[^.]+") do
        if type(node) ~= "table" then return nil end
        node = node[part]
        if node == nil then return nil end
    end
    return node
end

local squared = false

local function HideIfPresent(names)
    for _, n in ipairs(names) do
        local f = Piece(n)
        if f and f.Hide then f:Hide() end
    end
end

-- The zone bar and its close button sit above the minimap and are wider than the round map
-- ever was, which leaves the square looking inset. These are the frames that make up that
-- header; the widest one that exists decides how wide the square should be. Which of them
-- exist varies by client version, hence the lookup by name rather than a fixed reference.
local HEADER_FRAMES = {
    "MinimapZoneTextButton", "MinimapBorderTop", "MinimapZoneText",
    "MinimapCluster.ZoneTextButton", "MinimapCluster.BorderTop",
}

-- Geometry read off a Blizzard frame can be secret on this client, and a secret cannot be
-- compared, divided, or even tested with "or" - the fallback itself is a boolean test. So it
-- has to be checked before it is touched at all.
local issecretvalue = _G.issecretvalue
local function Secret(a, b)
    if not issecretvalue then return false end
    if issecretvalue(a) then return true end
    return b ~= nil and issecretvalue(b) or false
end

local function HeaderWidth()
    local best = 0
    for _, n in ipairs(HEADER_FRAMES) do
        local f = Piece(n)
        if f and f.GetWidth then
            local w = f:GetWidth()
            if not Secret(w) and w and w > best then best = w end
        end
    end
    return best
end

local function ApplySquareSize()
    local mm = _G.Minimap
    if not mm then return end

    local want = DB().squareSize
    if not want or want <= 0 then
        if not DB().fillWidth then return end
        want = HeaderWidth()
        -- A header that reports something implausible is a sign the name guess was wrong.
        -- Leaving the size alone beats resizing the minimap to nonsense.
        if want < 80 or want > 400 then return end
    end

    local have = mm:GetWidth()
    if Secret(have) then return end   -- nothing to compare against, so leave the size alone
    if not mm._gaarBaseSize then mm._gaarBaseSize = have end
    if math.abs((have or 0) - want) > 0.5 then mm:SetSize(want, want) end
end

-- Clock and tracking strip
--
-- Blizzard's own clock is a load-on-demand addon wearing a round plate meant for the bottom
-- of a round minimap, and its 24-hour setting lives behind a CVar whose name varies. Drawing
-- the text here instead costs the alarm and stopwatch menu, and buys a format that is simply
-- correct, a backdrop that matches the square, and room for the tracking icon beside it.
--
-- date() is local time; GetGameTime() is the server's. Both are shown - local on the bar,
-- server in the tooltip - because on a realm in another timezone people want each at
-- different moments.
local clockBar

-- Which tracking API answers depends on the client version, so each is tried in turn.
--
-- The shape of the answer varies too. GetTrackingInfo returned name, texture, active as three
-- values, and now returns one table with those as fields - the same trap C_Container's item
-- info sprang, and it fails the same silent way: nothing is ever active, nothing is ever
-- shown, no error. Both shapes are read here.
local function Scan(count, get)
    for i = 1, (count or 0) do
        local a, b, c = get(i)
        if type(a) == "table" then
            if a.active then return a.texture, a.name end
        elseif c then
            return b, a
        end
    end
end

local function ActiveTracking()
    local C = _G.C_Minimap
    if C and C.GetNumTrackingTypes and C.GetTrackingInfo then
        local tex, name = Scan(C.GetNumTrackingTypes(), C.GetTrackingInfo)
        if tex then return tex, name end
    end
    if _G.GetNumTrackingTypes and _G.GetTrackingInfo then
        local tex, name = Scan(_G.GetNumTrackingTypes(), _G.GetTrackingInfo)
        if tex then return tex, name end
    end
    -- Last resort: the texture alone, with no name to go with it.
    if _G.GetTrackingTexture then return _G.GetTrackingTexture() end
end

local function RefreshTracking()
    if not clockBar then return end
    local texture, name = ActiveTracking()
    clockBar.trackName = name
    if texture then
        clockBar.track:SetTexture(texture)
        clockBar.track:Show()
    else
        clockBar.track:Hide()
    end
end

local function RefreshClock()
    if not clockBar then return end
    clockBar.time:SetText(date("%H:%M"))
end

local function BuildClockBar(mm)
    if clockBar then return clockBar end

    local f = CreateFrame("Frame", "GaarMinimapClock", mm)
    -- A little wider than the map and set further down: flush against the map with a hard
    -- border it read as a second box rather than something belonging to the map.
    f:SetPoint("TOPLEFT", mm, "BOTTOMLEFT", -4, -7)
    f:SetPoint("TOPRIGHT", mm, "BOTTOMRIGHT", 4, -7)
    f:SetHeight(13)

    -- Two halves, each tapering to nothing at its outer end. Fading the strip out at the sides
    -- is what stops it reading as a slab; a border round it did the opposite. The gradient is
    -- guarded because its signature has changed between client versions - where the call does
    -- not take, a flat fill stands in and the strip is merely square-ended.
    local FADE = 0.5
    local function half(outerEdge, leftAlpha, rightAlpha)
        local tex = f:CreateTexture(nil, "BACKGROUND")
        tex:SetPoint("TOP" .. outerEdge); tex:SetPoint("BOTTOM" .. outerEdge)
        tex:SetPoint(outerEdge == "LEFT" and "RIGHT" or "LEFT", f, "CENTER", 0, 0)
        tex:SetColorTexture(1, 1, 1, 1)
        local ok = _G.CreateColor and pcall(function()
            tex:SetGradient("HORIZONTAL",
                _G.CreateColor(0, 0, 0, leftAlpha), _G.CreateColor(0, 0, 0, rightAlpha))
        end)
        if not ok then tex:SetColorTexture(0, 0, 0, FADE) end
    end
    half("LEFT", 0, FADE)    -- transparent at the outer edge, solid at the middle
    half("RIGHT", FADE, 0)

    -- The clock is centred, with the tracking icon tucked against its left so the two read as
    -- one group in the middle rather than drifting to opposite ends of the strip.
    local t = f:CreateFontString(nil, "OVERLAY")
    t:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    t:SetPoint("CENTER", f, "CENTER", 0, 0)
    t:SetTextColor(0.92, 0.92, 0.92)
    f.time = t

    local track = f:CreateTexture(nil, "ARTWORK")
    track:SetSize(11, 11)
    track:SetPoint("RIGHT", t, "LEFT", -4, 0)
    track:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    track:Hide()
    f.track = track

    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Local " .. date("%H:%M:%S"), 1, 1, 1)
        local h, m = GetGameTime()
        if h then GameTooltip:AddLine(string.format("Server %02d:%02d", h, m), 0.7, 0.7, 0.7) end
        if self.trackName then GameTooltip:AddLine("Tracking: " .. self.trackName, 0.4, 0.9, 0.4) end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Once a second is plenty for a display that only shows minutes.
    local since = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        since = since + elapsed
        if since < 1 then return end
        since = 0
        RefreshClock()
        -- Polled as well as evented. A second's delay on a tracking change is nothing, and it
        -- means the icon does not depend on MINIMAP_UPDATE_TRACKING firing as expected.
        RefreshTracking()
    end)

    local ev = CreateFrame("Frame")
    ev:RegisterEvent("MINIMAP_UPDATE_TRACKING")
    ev:SetScript("OnEvent", RefreshTracking)

    clockBar = f
    return f
end

local function ApplyClock()
    local mm = _G.Minimap
    if not mm then return end

    if not DB().showClock then
        if clockBar then clockBar:Hide() end
        return
    end

    -- Blizzard's clock, if some other addon or the options panel has pulled it in, would sit
    -- on top of this one saying the same thing in a different format.
    local blizz = _G.TimeManagerClockButton
    if blizz then blizz:Hide() end

    BuildClockBar(mm)
    RefreshClock()
    RefreshTracking()
    clockBar:Show()
end

-- The zone bar sits directly on top of the map with no seam between them. Hanging the map off
-- the bar's bottom edge puts a controlled gap there instead. The map alone moves: shifting the
-- whole cluster took the bar and the buttons with it, which was not the point.
local function ApplyHeaderGap()
    local mm = _G.Minimap
    if not mm then return end

    local header
    for _, n in ipairs(HEADER_FRAMES) do
        local f = Piece(n)
        if f and f.GetHeight then
            local fh = f:GetHeight()
            if not Secret(fh) and fh and fh > 0 then header = f; break end
        end
    end
    if not header then return end

    -- Some versions anchor the header to the minimap rather than the other way round, and
    -- anchoring back would close a loop the client refuses. Keep the original point so a
    -- refusal leaves the map where it was instead of unanchored in a corner.
    if not mm._gaarBasePoint then
        local point, rel, relPoint, x, y = mm:GetPoint()
        if point then mm._gaarBasePoint = { point, rel, relPoint, x or 0, y or 0 } end
    end

    mm:ClearAllPoints()
    local ok = pcall(mm.SetPoint, mm, "TOP", header, "BOTTOM", 0, -(DB().headerGap or 1))
    if not ok then
        local b = mm._gaarBasePoint
        if b then mm:SetPoint(b[1], b[2], b[3], b[4], b[5]) end
        print("|cff5599ff" .. ADDON .. ":|r cannot hang the map off the zone bar - it is anchored to the map.")
    end
end

local function ApplyMinimapShape()
    local mm = _G.Minimap
    if not mm then return end

    if not DB().squareMinimap then
        -- Undoing this properly needs the original art back, which a reload is the honest way
        -- to get. Say so rather than half-restoring it.
        if squared then
            print("|cff5599ff" .. ADDON .. ":|r square minimap off - reload to restore the round border.")
        end
        return
    end

    if mm.SetMaskTexture then mm:SetMaskTexture("Interface\\Buttons\\WHITE8x8") end
    HideIfPresent(ROUND_ART)
    if DB().hideZoomButtons then
        HideIfPresent(ZOOM_BUTTONS)
        -- the zoom buttons are gone, so the wheel has to do their job
        mm:EnableMouseWheel(true)
        if not mm._gaarWheel then
            mm._gaarWheel = true
            mm:SetScript("OnMouseWheel", function(self, delta)
                local z = self:GetZoom()
                if delta > 0 then
                    if z < (self:GetZoomLevels() or 5) - 1 then self:SetZoom(z + 1) end
                elseif z > 0 then
                    self:SetZoom(z - 1)
                end
            end)
        end
    end

    if not mm._gaarBorder then
        local b = CreateFrame("Frame", nil, mm, "BackdropTemplate")
        b:SetPoint("TOPLEFT", -1, 1)
        b:SetPoint("BOTTOMRIGHT", 1, -1)
        b:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        b:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
        b:SetFrameLevel(math.max(0, (mm:GetFrameLevel() or 1) - 1))
        mm._gaarBorder = b
    end
    mm._gaarBorder:Show()

    ApplySquareSize()
    ApplyHeaderGap()
    ApplyClock()

    squared = true

    if _G.GaarOptions_PlaceMinimapButton then _G.GaarOptions_PlaceMinimapButton() end
end

-- Asked by other addons before they place a minimap button. Returning the wrong answer is
-- worse than returning none, so it only claims SQUARE while the square is actually applied.
function GetMinimapShape()
    return squared and "SQUARE" or "ROUND"
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
    ApplyMinimapShape()
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

    local mmHead = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mmHead:SetPoint("TOPLEFT", 16, y); mmHead:SetText("Minimap")
    y = y - 28

    check("Square minimap with a thin border", function() return DB().squareMinimap end, function(v)
        DB().squareMinimap = v
        ApplyMinimapShape()
    end)
    check("Hide the zoom buttons (use the mouse wheel)", function() return DB().hideZoomButtons end, function(v)
        DB().hideZoomButtons = v
        ApplyMinimapShape()
    end)
    y = y - 6

    check("Widen the square to the zone bar", function() return DB().fillWidth end, function(v)
        DB().fillWidth = v
        if v then DB().squareSize = 0 end
        ApplyMinimapShape()
    end)
    check("Clock and tracking under the minimap", function() return DB().showClock end, function(v)
        DB().showClock = v
        ApplyClock()
    end)
    y = y - 10

    local sizeLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sizeLabel:SetPoint("TOPLEFT", 18, y); sizeLabel:SetText("Size:")
    local sx = 130
    for _, sz in ipairs({ { "Auto", 0 }, { "140", 140 }, { "160", 160 }, { "180", 180 } }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(52, 20); b:SetPoint("TOPLEFT", sx, y + 4); b:SetText(sz[1])
        b:SetScript("OnClick", function()
            DB().squareSize = sz[2]
            DB().fillWidth = (sz[2] == 0)
            ApplyMinimapShape()
        end)
        sx = sx + 54
    end
    y = y - 32

    local gapLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gapLabel:SetPoint("TOPLEFT", 18, y); gapLabel:SetText("Gap under zone bar:")
    local dx = 150
    for gp = 0, 10, 2 do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(30, 20); b:SetPoint("TOPLEFT", dx, y + 4); b:SetText(tostring(gp))
        b:SetScript("OnClick", function() DB().headerGap = gp; ApplyHeaderGap() end)
        dx = dx + 32
    end
    y = y - 32

    local mmHint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    mmHint:SetPoint("TOPLEFT", 18, y); mmHint:SetWidth(340); mmHint:SetJustifyH("LEFT")
    mmHint:SetText("Squaring the minimap swaps its round mask for a square one and hides the border art, which cannot be put back without a reload. Other addons are told about the new shape through GetMinimapShape, so their minimap buttons follow the corners rather than an invisible circle. Auto size measures the zone bar above the map and matches it, so the square reaches the same edges. /gaarmap mmdebug prints the frames it found and their sizes. The strip under the map shows the clock in 24-hour local time and the icon of whatever you are tracking; hover it for server time and the tracking's name.")
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
-- Which frames make up the minimap header differs between client versions, and guessing at
-- the names is how this sort of thing quietly does nothing. This prints what is actually
-- there, with sizes, so a wrong guess can be corrected from what the client reports.
local function DumpMinimap()
    print("|cff33ff99" .. ADDON .. "|r minimap frames")
    for _, parent in ipairs({ "Minimap", "MinimapCluster" }) do
        local f = _G[parent]
        if not f then
            print("  " .. parent .. ": |cffff6666absent|r")
        else
            local pw, ph = f:GetWidth(), f:GetHeight()
            if Secret(pw, ph) then print(string.format("  %s  <secret size>", parent))
            else print(string.format("  %s  %.0fx%.0f", parent, pw or 0, ph or 0)) end
            for _, child in ipairs({ f:GetChildren() }) do
                local n = child.GetName and child:GetName()
                if n then
                    local cw, ch = child:GetWidth(), child:GetHeight()
                    local mark = child:IsShown() and "|cff40ff40+|r" or "|cff777777-|r"
                    if Secret(cw, ch) then print(string.format("    %s %s  <secret size>", mark, n))
                    else print(string.format("    %s %s  %.0fx%.0f", mark, n, cw or 0, ch or 0)) end
                end
            end
            for _, r in ipairs({ f:GetRegions() }) do
                local n = r.GetName and r:GetName()
                if n then
                    print(string.format("    %s %s  |cff777777%s|r", r:IsShown() and "|cff40ff40+|r" or "|cff777777-|r",
                        n, r:GetObjectType()))
                end
            end
        end
    end
    print(string.format("  header width: %.0f", HeaderWidth()))

    local C = _G.C_Minimap
    local count = (C and C.GetNumTrackingTypes and C.GetNumTrackingTypes())
        or (_G.GetNumTrackingTypes and _G.GetNumTrackingTypes())
    local get = (C and C.GetTrackingInfo) or _G.GetTrackingInfo
    print(string.format("  tracking API: %s   types: %s",
        (C and C.GetTrackingInfo) and "C_Minimap" or (_G.GetTrackingInfo and "global" or "|cffff6666none|r"),
        tostring(count)))
    if get and count then
        for i = 1, count do
            local a, b, c = get(i)
            if type(a) == "table" then
                print(string.format("    %s %s |cff777777table|r", a.active and "|cff40ff40+|r" or "-", tostring(a.name)))
            else
                print(string.format("    %s %s |cff777777%s|r", c and "|cff40ff40+|r" or "-", tostring(a), tostring(b)))
            end
        end
    end
end

SlashCmdList["GAARMAP"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "reset" then ResetLayout()
    elseif msg == "mmdebug" then DumpMinimap()
    else OpenOptions() end
end
