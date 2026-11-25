--[[
  GaarMapsForever - move, scale and fade the world map ("Map & Quest Log") on WoW Forever.

  It changes these things about Blizzard's own WorldMapFrame and nothing else:

    * Move: drag the title bar of the windowed map. The position is saved account-wide in
      GaarMapsForeverDB and put back every time the map opens or Blizzard's panel layout
      re-anchors it.
    * Resize: drag the grip in the bottom-right corner. It drives the frame's scale, not its width
      and height, so the map, its pins and the quest log grow and shrink together (50% to 150%).
      The top-left corner stays where it is while you drag.
    * Fade while moving (on by default): while the player moves the map drops to a lower opacity
      (35% by default) and comes back to full once the player stands still.
    * Lock: no moving and no resizing; the grip and the title-bar handle are hidden.
    * Reset: Blizzard's default position and 100% scale.
    * The maximized map is left to Blizzard: no handle, no grip, 100% scale. Going back to the
      windowed map puts the saved position and scale back.
    * Right-click the map's round portrait (top-left) for the addon's menu.
    * Zone levels (on by default): the zone's level range, "Level 35-45", coloured like mob difficulty,
      as one line under Blizzard's hover name: the neighbour's range while hovering one, else the shown zone's. /gmf levels on|off.
    * /gmf for help, lock, unlock, reset, status, scale <50-150>, fade on|off, fade <percent> and levels on|off.
    * GaarMapsForeverAPI, a small global table for GaarForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The addon runs exactly the same
      without the hub; the API only exposes the settings the slash command already changes.

  The resize and the fade follow GaarMap, which does both on the same frame. Resizing drives
  scale because the map is a canvas with its own pins and overlays: scaling moves all of it
  together, where resizing would leave the contents laid out for the old size. Movement is read
  with IsPlayerMoving first, because GetUnitSpeed answers with a secret number on this client.

  GaarMap also replaces WorldMapFrame.ScrollContainer.GetCursorPosition while the map is scaled,
  so the zone under the pointer matches the zone highlighted. That writes a Blizzard table, which
  this addon never does, so that correction is not here: see the README.

  Names come from Blizzard's retail FrameXML (Blizzard_WorldMap: WorldMapFrame, its BorderFrame
  with TitleContainer, MaximizeMinimizeFrame and CloseButton, the mixin's IsMaximized, Maximize,
  Minimize and SynchronizeDisplayState) and UIParent.lua (UpdateUIPanelPositions). Every one of
  them is checked before use; when something is missing the matching feature does not switch on.

  Taint: Blizzard code is only ever followed, never replaced. Hooks go through hooksecurefunc and
  HookScript, no Blizzard function or table is written, and SetAttribute is never called on a
  Blizzard frame. The map is moved and scaled only out of combat; anything that would move or
  scale it in combat waits for PLAYER_REGEN_ENABLED. The fade is SetAlpha on the map frame only,
  which is allowed at any time. Opening the map in combat is Blizzard's own path, untouched.
]]

local _G = _G
local ADDON_NAME, ns = ...
ADDON_NAME = ADDON_NAME or "GaarMapsForever"
local DOT = " \194\183 "

local VERSION = "1.5.0"

local MIN_SCALE, MAX_SCALE = 0.5, 1.5
local MIN_FADE, MAX_FADE = 0.1, 1
local DEFAULT_FADE_ALPHA = 0.35                 -- GaarMap's default
local SCALE_PRESETS = { 75, 90, 100, 110, 125 } -- percent, for the menu
local FADE_PRESETS = { 25, 35, 50, 75 }         -- percent, for the menu
local TICK = 0.1                                -- seconds between fade and layout checks

local DEFAULTS = {
    locked = false,
    scale = 1,
    fade = true,
    fadeAlpha = DEFAULT_FADE_ALPHA,
    zoneMapScale = 1,
    zoneLevels = true,
}

-- Every key GaarMapsForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = { locked = true, scale = true, position = true, fade = true, fadeAlpha = true,
    zoneMapPoint = true, zoneMapScale = true, zoneLevels = true }

local db                -- GaarMapsForeverDB, bound at ADDON_LOADED (never at file scope)
local map               -- WorldMapFrame once found
local dragHandle        -- invisible handle over the title bar
local grip              -- resize grip in the bottom-right corner
local blizzardPoints    -- the anchor Blizzard last gave the map, for /gmf reset
local appliedPoints     -- the anchor we last set, so it is not mistaken for Blizzard's
local scaled            -- we have set a scale other than Blizzard's 100% on the map
local pendingApply      -- a move or scale that has to wait for combat to end
local pendingRestore    -- /gmf reset is waiting to put Blizzard's anchor and scale back
local moving            -- a title-bar drag is in progress
local sizing            -- a grip drag is in progress
local faded             -- the map is at the fade opacity right now
local hooked, panelHooked

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- Print, InCombat, Num, OnOff and AddOnLoaded come from the shared library (GaarForever,
-- loaded first as a dependency). Num treats a secret value - the client hands one back where it
-- hides a number, and it can be neither compared nor used in a sum - as no number at all.
local BF = _G.GaarForever
local A = BF.NewAddon("GaarMapsForever", { title = "GaarMapsForever", version = VERSION })
local function Print(msg) A:Print(msg) end
local InCombat, Num, OnOff, AddOnLoaded = BF.InCombat, BF.Num, BF.OnOff, BF.AddOnLoaded

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function Percent(v) return math.floor(v * 100 + 0.5) end

local function GetMap()
    local f = _G.WorldMapFrame
    if type(f) == "table" and f.SetScale and f.SetPoint and f.ClearAllPoints and f.HookScript then return f end
end

local function IsMaximized()
    if not map then return false end
    if type(map.IsMaximized) == "function" then
        local ok, v = pcall(map.IsMaximized, map)
        if ok then return v and true or false end
    end
    return map.isMaximized and true or false
end

local function CapturePoints(region)
    local points = {}
    local n = Num(region.GetNumPoints and region:GetNumPoints()) or 0
    for i = 1, n do
        local point, relativeTo, relativePoint, x, y = region:GetPoint(i)
        x, y = Num(x or 0), Num(y or 0)
        if not x or not y then return nil end -- secret offsets: unknown, not "different"
        if point then points[#points + 1] = { point, relativeTo, relativePoint, x, y } end
    end
    return points
end

local function SetPoints(region, points)
    region:ClearAllPoints()
    for _, p in ipairs(points) do
        region:SetPoint(p[1], p[2], p[3], p[4], p[5])
    end
end

local function Near(a, b, eps)
    return math.abs((a or 0) - (b or 0)) < (eps or 0.01)
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

-- Converts between the map's own coordinates and UIParent's. Saved positions are kept in UIParent
-- units, so they hold whatever scale the map is at.
local function ScaleRatio()
    local parent = _G.UIParent
    local mine = Num(map.GetEffectiveScale and map:GetEffectiveScale())
    local theirs = Num(parent and parent.GetEffectiveScale and parent:GetEffectiveScale())
    if not mine or mine <= 0 or not theirs or theirs <= 0 then return nil end
    return mine / theirs
end

-- The map's top-left corner in UIParent units, or nil when the client will not say.
local function TopLeft()
    local ratio = ScaleRatio()
    local left, top = Num(map:GetLeft()), Num(map:GetTop())
    if not ratio or not left or not top then return nil end
    return left * ratio, top * ratio
end

-- Puts the map's top-left corner at (x, y) in UIParent units, kept on screen.
local function PlaceTopLeft(x, y)
    local parent = _G.UIParent
    local ratio = ScaleRatio()
    if not parent or not ratio then return false end
    local pw, ph = Num(parent:GetWidth()), Num(parent:GetHeight())
    local w, h = Num(map:GetWidth()), Num(map:GetHeight())
    if pw and ph and w and h and pw > 0 and ph > 0 then
        w, h = w * ratio, h * ratio
        x = math.max(0, math.min(x, math.max(0, pw - w)))
        y = math.min(ph, math.max(y, math.min(h, ph)))
    end
    map:ClearAllPoints()
    map:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", x / ratio, y / ratio)
    appliedPoints = CapturePoints(map)
    return true
end

-- Whether the addon needs to touch the map at all; at 100% and the default position it does not.
local function Managed()
    return db and (db.position ~= nil or not Near(db.scale, 1, 0.001)) or false
end

-- ---------------------------------------------------------------------------
-- Layout: scale and position
-- ---------------------------------------------------------------------------

local UpdateWidgets -- defined with the widgets below

-- Puts the saved scale and position on the windowed map, gives the maximized map back to
-- Blizzard, or restores Blizzard's own layout after /gmf reset. Never in combat.
local function ApplyLayout()
    if not map or not db or moving or sizing then return end
    if UpdateWidgets then UpdateWidgets() end

    if IsMaximized() then
        -- Blizzard's: only undo our scale, if any. The position is Blizzard's anyway.
        if scaled or pendingRestore then
            if InCombat() then
                pendingApply = true
                return
            end
            map:SetScale(1)
            scaled = false
        end
        return
    end

    if not Managed() and not pendingRestore then return end
    if InCombat() then
        pendingApply = true
        return
    end

    -- Remember where Blizzard put it, for /gmf reset; our own anchor does not count.
    local points = CapturePoints(map)
    if points and #points > 0 and not SamePoints(points, appliedPoints) then
        blizzardPoints = points
        appliedPoints = nil
    end

    if pendingRestore then
        pendingRestore = false
        map:SetScale(1)
        scaled = false
        if appliedPoints and blizzardPoints and #blizzardPoints > 0 then SetPoints(map, blizzardPoints) end
        appliedPoints = nil
        if not Managed() then return end
    end

    local s = db.scale
    if not Near(Num(map:GetScale()), s, 0.001) then map:SetScale(s) end
    scaled = not Near(s, 1, 0.001)

    -- Placed again every time: after a scale change the same offsets would land elsewhere.
    local pos = db.position
    if pos then PlaceTopLeft(pos.x, pos.y) end
end

-- Cheap check from the ticker: has something put Blizzard's anchor or scale back since?
local function LayoutDrifted()
    if not map or not db or moving or sizing or InCombat() then return false end
    if IsMaximized() then return scaled end
    if not Managed() then return false end
    if not Near(Num(map:GetScale()), db.scale, 0.001) then return true end
    if db.position then
        local now = CapturePoints(map)
        if now and not SamePoints(now, appliedPoints) then return true end
    end
    return false
end

local function SavePosition(x, y)
    if not db then return end
    if not x then x, y = TopLeft() end
    if x and y then db.position = { x = x, y = y } end
end

-- ---------------------------------------------------------------------------
-- Moving: the title bar
-- ---------------------------------------------------------------------------

local function StartDrag()
    if not map or not db or db.locked or moving or sizing or IsMaximized() then return end
    if InCombat() then
        Print("the map cannot be moved in combat.")
        return
    end
    if map.IsMovable and not map:IsMovable() and map.SetMovable then map:SetMovable(true) end
    if map.SetClampedToScreen then map:SetClampedToScreen(true) end
    map:StartMoving()
    moving = true
end

local function StopDrag()
    if not moving then return end
    moving = false
    map:StopMovingOrSizing()
    -- StartMoving marks the frame user-placed, which would make the client keep its own copy of
    -- the position in layout-local.txt. Ours lives in the saved variables instead.
    if map.SetUserPlaced then pcall(map.SetUserPlaced, map, false) end
    SavePosition()
    -- Our own anchor straight away, so the client's drag anchor is never taken for Blizzard's.
    if db.position then PlaceTopLeft(db.position.x, db.position.y) end
    ApplyLayout()
end

-- The handle covers the title strip, but stops short of the maximize and close buttons so their
-- clicks still reach them. Their place is read each time the map opens.
local function LayoutDragHandle()
    if not dragHandle or not map then return end
    local border = map.BorderFrame
    local title = type(border) == "table" and border.TitleContainer
    dragHandle:ClearAllPoints()
    if type(title) == "table" and title.GetRight then
        local right = Num(title:GetRight())
        local inset, unknown = 0, false
        local buttons = {
            border.MaximizeMinimizeFrame, map.MaximizeMinimizeFrame, border.CloseButton, map.CloseButton,
        }
        for _, b in pairs(buttons) do
            if type(b) == "table" and b.GetLeft and b.IsShown and b:IsShown() then
                local left = Num(b:GetLeft())
                if right and left then
                    if left < right then inset = math.max(inset, right - left + 2) end
                else
                    unknown = true
                end
            end
        end
        -- Not laid out yet: keep well clear of the buttons until the next look.
        if unknown and inset == 0 then inset = 70 end
        dragHandle:SetPoint("TOPLEFT", title, "TOPLEFT", 0, 0)
        dragHandle:SetPoint("BOTTOMRIGHT", title, "BOTTOMRIGHT", -inset, 0)
        dragHandle:SetFrameLevel((Num(title:GetFrameLevel()) or 0) + 1)
    else
        -- PortraitFrameTemplate's title strip, relative to the map itself, clear of the buttons.
        dragHandle:SetPoint("TOPLEFT", map, "TOPLEFT", 58, -1)
        dragHandle:SetPoint("TOPRIGHT", map, "TOPRIGHT", -70, -1)
        dragHandle:SetHeight(20)
        dragHandle:SetFrameLevel((Num(map:GetFrameLevel()) or 0) + 10)
    end
end

local function CreateDragHandle()
    if dragHandle or not map then return end
    local handle = CreateFrame("Frame", "GaarMapsForeverDragHandle", map)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", StartDrag)
    handle:SetScript("OnDragStop", StopDrag)
    handle:SetScript("OnHide", StopDrag)
    handle:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_TOP")
        tip:SetText("Drag to move the map")
        tip:AddLine("Resize from the grip in the bottom-right corner. /gmf lock to lock, /gmf reset to reset.", 1, 1, 1, true)
        tip:Show()
    end)
    handle:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    dragHandle = handle
    LayoutDragHandle()
end

-- ---------------------------------------------------------------------------
-- Resizing: the corner grip
-- ---------------------------------------------------------------------------

local function StopSizing()
    if not sizing then return end
    sizing = false
    if grip then grip:SetScript("OnUpdate", nil) end
    if grip and grip.anchorX then SavePosition(grip.anchorX, grip.anchorY) end
    ApplyLayout()
end

-- The corner follows the cursor: the scale is the cursor's distance from the fixed top-left
-- corner against that distance when the drag began, in both directions, averaged.
local function SizingUpdate(self)
    if InCombat() then
        StopSizing()
        return
    end
    local cx, cy = GetCursorPosition()
    cx, cy = Num(cx), Num(cy)
    if not cx or not cy then return end
    local s
    if self.screenLeft then
        local dx0, dy0 = self.startX - self.screenLeft, self.screenTop - self.startY
        local dx, dy = cx - self.screenLeft, self.screenTop - cy
        if dx0 > 10 and dy0 > 10 then
            s = self.startScale * ((dx / dx0) + (dy / dy0)) / 2
        end
    end
    if not s then
        -- GaarMap's rule, for when the corner's place is unknown: 400 pixels down is +100%.
        s = self.startScale + (self.startY - cy) / 400
    end
    s = Clamp(math.floor(s * 100 + 0.5) / 100, MIN_SCALE, MAX_SCALE)
    if Near(s, db.scale, 0.001) and Near(Num(map:GetScale()), s, 0.001) then return end
    db.scale = s
    map:SetScale(s)
    scaled = not Near(s, 1, 0.001)
    if self.anchorX then PlaceTopLeft(self.anchorX, self.anchorY) end
end

local function StartSizing(self, button)
    if button and button ~= "LeftButton" then return end
    if not map or not db or db.locked or moving or sizing or IsMaximized() then return end
    if InCombat() then
        Print("the map cannot be resized in combat.")
        return
    end
    local cx, cy = GetCursorPosition()
    cx, cy = Num(cx), Num(cy)
    if not cx or not cy then return end
    self.startX, self.startY = cx, cy
    self.startScale = db.scale
    self.anchorX, self.anchorY = TopLeft()
    local eff = Num(map:GetEffectiveScale())
    local left, top = Num(map:GetLeft()), Num(map:GetTop())
    if eff and left and top then
        self.screenLeft, self.screenTop = left * eff, top * eff
    else
        self.screenLeft, self.screenTop = nil, nil
    end
    sizing = true
    self:SetScript("OnUpdate", SizingUpdate)
end

local function ShowGripTooltip(self)
    local tip = _G.GameTooltip
    if not tip then return end
    tip:SetOwner(self, "ANCHOR_LEFT")
    tip:AddLine("Drag to resize the map")
    tip:AddLine(string.format("Scale: %d%%", Percent(db and db.scale or 1)), 1, 1, 1)
    tip:Show()
end

local function CreateGrip()
    if grip or not map then return end
    local g = CreateFrame("Button", "GaarMapsForeverGrip", map)
    g:SetSize(18, 18)
    g:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", -4, 4)
    g:SetFrameStrata("HIGH")
    g:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    g:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    if g.SetPushedTexture then g:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down") end
    g:SetScript("OnMouseDown", StartSizing)
    g:SetScript("OnMouseUp", StopSizing)
    g:SetScript("OnHide", StopSizing)
    g:SetScript("OnEnter", ShowGripTooltip)
    g:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    grip = g
end

-- The grip and the handle are our own frames, so showing or hiding them is fine in combat.
UpdateWidgets = function()
    local on = db and not db.locked and map and not IsMaximized() or false
    if dragHandle then dragHandle:SetShown(on and true or false) end
    if grip then grip:SetShown(on and true or false) end
end

-- ---------------------------------------------------------------------------
-- Fade while moving (GaarMap's behaviour)
-- ---------------------------------------------------------------------------

-- IsPlayerMoving answers as a boolean and needs no arithmetic, so it is asked first; the speed,
-- which can be secret here, is only consulted where that is missing. nil means neither could
-- answer, and then the map is left as it is rather than faded back in.
local function PlayerIsMoving()
    if type(_G.IsPlayerMoving) == "function" then
        local m = _G.IsPlayerMoving()
        if not BF.IsSecret(m) then return m and true or false end
    end
    if type(_G.GetUnitSpeed) == "function" then
        local sp = Num(_G.GetUnitSpeed("player"))
        if sp then return sp > 0 end
    end
    return nil
end

-- True while the cursor is over the map window or one of its shown child frames (the quest log
-- panel may sit outside the parent's own rect). pcall-guarded: a failed check counts as "not over".
local function CursorOverMap()
    if not map then return false end
    local ok, over = pcall(map.IsMouseOver, map)
    if ok and over then return true end
    local okc, kids = pcall(function() return { map:GetChildren() } end)
    if okc and type(kids) == "table" then
        for _, kid in ipairs(kids) do
            local oks, shown = pcall(kid.IsShown, kid)
            if oks and shown then
                local okm, m = pcall(kid.IsMouseOver, kid)
                if okm and m then return true end
            end
        end
    end
    return false
end

local function SetFaded(on)
    if not map then return end
    map:SetAlpha(on and db.fadeAlpha or 1)
    faded = on and true or false
end

local function FadeStep()
    if not db.fade then
        if faded then SetFaded(false) end
        return
    end
    local m = PlayerIsMoving()
    if m == nil then return end
    -- Hovering the map keeps it at full opacity even while moving; it fades again on leave.
    if m and CursorOverMap() then m = false end
    if m and not faded then
        SetFaded(true)
    elseif not m and faded then
        SetFaded(false)
    end
end

-- One ticker for the fade and the layout check, running only while the map is shown.
local ticker = CreateFrame("Frame")
local acc = 0
local function Tick(_, elapsed)
    acc = acc + (elapsed or 0)
    if acc < TICK then return end
    acc = 0
    if not map or not db or not map:IsShown() then
        ticker:SetScript("OnUpdate", nil)
        return
    end
    FadeStep()
    if LayoutDrifted() then ApplyLayout() end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- Blizzard may set the anchor again a moment after the map shows, and the title bar's buttons
-- only have a place once it is laid out; the next frame catches both.
local function ApplySoon()
    local t = _G.C_Timer
    if type(t) == "table" and type(t.After) == "function" then
        t.After(0, function()
            LayoutDragHandle()
            ApplyLayout()
        end)
    end
end

local function OnMapShown()
    LayoutDragHandle()
    ApplyLayout()
    ApplySoon()
    acc = 0
    ticker:SetScript("OnUpdate", Tick)
end

local function OnMapHidden()
    if moving then StopDrag() end
    if sizing then StopSizing() end
    -- Closed while faded: open again at full opacity, not stuck at the faded one.
    if faded then SetFaded(false) end
    ticker:SetScript("OnUpdate", nil)
end

-- Maximize, Minimize and SynchronizeDisplayState: windowed and maximized swap here.
local function OnDisplayStateChanged()
    if moving then StopDrag() end
    if sizing then StopSizing() end
    LayoutDragHandle()
    ApplyLayout()
    ApplySoon()
end

-- Blizzard's panel layout has just re-anchored the open panels, the map among them.
local function OnPanelPositions()
    if map and map:IsShown() then ApplyLayout() end
end

-- ---------------------------------------------------------------------------
-- Right-click the portrait: the addon's menu
--
-- The round book portrait in the map's top-left corner is not mouse-enabled, so a small
-- transparent Button of our own sits over it. Right-click opens the same menu the hub shows
-- (MenuEntries, below). Our own frame only; no Blizzard handler is replaced. Created lazily,
-- out of combat.
-- ---------------------------------------------------------------------------

local portraitButton
local portraitPending -- creation had to wait for combat to end
local portraitFoundAs     -- path of the portrait region we anchored to, for /gmf status
local portraitErrShown    -- the menu error is printed once
local ShowPortraitMenu -- defined with the API, below

local PORTRAIT_SIZE = 60

local function Size(r)
    if type(r) ~= "table" or not r.GetWidth then return 0, 0 end
    local ok, w, h = pcall(function() return Num(r:GetWidth()) or 0, Num(r:GetHeight()) or 0 end)
    if ok then return w, h end
    return 0, 0
end

-- The portrait's region, if one of Blizzard's usual names has a sensible size (a ButtonFrame's
-- PortraitContainer can be a 1x1 holder, so size counts). Otherwise nil and the button is
-- placed by offset.
local function PortraitRegion()
    local border = map and map.BorderFrame
    local cands = {}
    local function add(path, r) cands[#cands + 1] = { path, r } end
    if type(border) == "table" then
        add("BorderFrame.PortraitContainer", border.PortraitContainer)
        add("BorderFrame.PortraitContainer.portrait", type(border.PortraitContainer) == "table" and border.PortraitContainer.portrait or nil)
        add("BorderFrame.portrait", border.portrait)
        add("BorderFrame.Portrait", border.Portrait)
        add("BorderFrame.PortraitFrame", border.PortraitFrame)
    end
    if map then
        add("WorldMapFrame.PortraitContainer", map.PortraitContainer)
        add("WorldMapFrame.portrait", map.portrait)
    end
    add("WorldMapFramePortrait", _G.WorldMapFramePortrait)
    for _, c in ipairs(cands) do
        local r = c[2]
        if type(r) == "table" and r.GetObjectType then
            local w, h = Size(r)
            if w >= 30 and h >= 30 and w <= 120 and h <= 120 then return r, c[1] end
        end
    end
    -- Scan the border's own textures and children for one that looks like the portrait.
    if type(border) == "table" and border.GetRegions then
        local ok, list = pcall(function() return { border:GetRegions() } end)
        if ok then
            for i, r in ipairs(list) do
                local name = tostring(r.GetName and r:GetName() or "")
                local atlas = tostring(r.GetAtlas and r:GetAtlas() or "")
                local w, h = Size(r)
                if (name:lower():find("portrait") or atlas:lower():find("portrait")) and w >= 30 and w <= 120 then
                    return r, "BorderFrame region " .. i
                end
            end
        end
    end
    return nil
end

local function PlacePortraitButton()
    local b = portraitButton
    if not b or not map then return end
    local border = type(map.BorderFrame) == "table" and map.BorderFrame or nil
    local region, path = PortraitRegion()
    b:ClearAllPoints()
    b:SetSize(PORTRAIT_SIZE, PORTRAIT_SIZE)
    if region then
        b:SetPoint("CENTER", region, "CENTER", 0, 0)
        portraitFoundAs = path
    else
        b:SetPoint("TOPLEFT", border or map, "TOPLEFT", -5, 7)
        portraitFoundAs = nil
    end
    -- Above the border and portrait; Blizzard may re-level them, so this runs on every show.
    local parent = border or map
    if parent.GetFrameStrata and b.SetFrameStrata then b:SetFrameStrata(parent:GetFrameStrata()) end
    b:SetFrameLevel((Num(parent:GetFrameLevel()) or 0) + 20)
    b:EnableMouse(true)
end

local function CreatePortraitButton()
    if not map then return end
    if portraitButton then PlacePortraitButton() return end
    if InCombat() then portraitPending = true return end
    portraitPending = false
    local b = CreateFrame("Button", "GaarMapsForeverPortraitButton", map)
    b:RegisterForClicks("RightButtonUp", "RightButtonDown")
    b:SetScript("OnClick", function(self, button, down)
        if button == "RightButton" and not down then ShowPortraitMenu(self) end
    end)
    b:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_RIGHT")
        tip:SetText("Right-click: GaarMaps menu")
        tip:Show()
    end)
    b:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    portraitButton = b
    PlacePortraitButton()
end

local function PortraitStatus()
    local b = portraitButton
    if not b then
        Print("portrait button: not created" .. (portraitPending and " (waiting for combat to end)" or ""))
        return
    end
    local border = map and map.BorderFrame
    local w, h = Size(b)
    Print("portrait region: " .. (portraitFoundAs or "none found, placed by offset at the border's top-left"))
    local over = "?"
    if b.IsMouseOver then
        local ok, v = pcall(b.IsMouseOver, b)
        if ok then over = v and "yes" or "no" end
    end
    Print(string.format("portrait button: shown=%s mouse=%s size=%dx%d strata=%s level=%s (border: %s, %s) mouse over now=%s",
        tostring(b.IsShown and b:IsShown() or false), tostring(b.IsMouseEnabled and b:IsMouseEnabled() or false), w, h,
        tostring(b.GetFrameStrata and b:GetFrameStrata()), tostring(b.GetFrameLevel and b:GetFrameLevel()),
        tostring(type(border) == "table" and border.GetFrameStrata and border:GetFrameStrata() or "?"),
        tostring(type(border) == "table" and border.GetFrameLevel and border:GetFrameLevel() or "?"), over))
end

local function HookBlizzard()
    if not panelHooked and type(_G.UpdateUIPanelPositions) == "function" then
        hooksecurefunc("UpdateUIPanelPositions", OnPanelPositions)
        panelHooked = true
    end
    if hooked then return true end
    map = GetMap()
    if not map then return false end
    hooked = true

    map:HookScript("OnShow", OnMapShown)
    map:HookScript("OnShow", function() CreatePortraitButton() end)
    map:HookScript("OnHide", OnMapHidden)
    for _, name in ipairs({ "Maximize", "Minimize", "SynchronizeDisplayState" }) do
        if type(map[name]) == "function" then hooksecurefunc(map, name, OnDisplayStateChanged) end
    end

    CreateDragHandle()
    CreateGrip()
    CreatePortraitButton()
    UpdateWidgets()
    if map:IsShown() then OnMapShown() end
    return true
end

-- ---------------------------------------------------------------------------
-- Zone map (Shift+M): BattlefieldMapFrame, from the load-on-demand Blizzard_BattlefieldMap
--
-- Same approach as the world map, in its own saved keys (zoneMapPoint, zoneMapScale). Blizzard
-- already lets you drag it by its tab and sets the opacity from the tab's menu; this adds a
-- scale grip and drags from the frame itself. Its opacity is never touched, and it does not
-- fade while you move.
-- ---------------------------------------------------------------------------

local ZMIN, ZMAX = 0.5, 2
local ZONE_PRESETS = { 75, 100, 125, 150, 200 } -- percent, for the menu

local zf                -- BattlefieldMapFrame once found
local zGrip             -- resize grip, bottom-right
local zHooked           -- hooks are in place
local zBlizz            -- the anchor Blizzard gave the frame, for /gmf zone reset
local zApplied          -- the anchor we last set
local zMoving, zSizing  -- a drag or a grip drag is in progress
local zPending          -- a move or scale that has to wait for combat to end
local zRestore          -- /gmf zone reset is waiting to put Blizzard's anchor and scale back

local ZoneApply -- defined below

local function ZoneFrame()
    local f = _G.BattlefieldMapFrame
    if type(f) == "table" and f.SetScale and f.SetPoint and f.ClearAllPoints and f.HookScript then return f end
end

-- Protected frames cannot be moved or scaled in combat. Unknown counts as protected.
local function ZoneLocked()
    if not InCombat() then return false end
    if not zf or not zf.IsProtected then return true end
    local ok, v = pcall(zf.IsProtected, zf)
    if not ok then return true end
    return v and true or false
end

-- The frame that carries the anchor: normally the frame itself, but the tab if the frame hangs
-- off it. Moving that one keeps frame and tab together.
local function ZoneRoot()
    local tab = _G.BattlefieldMapTab
    if type(tab) == "table" and tab.SetPoint and tab.ClearAllPoints and zf and zf.GetPoint then
        local ok, _, rel = pcall(zf.GetPoint, zf, 1)
        if ok and rel == tab then return tab end
    end
    return zf
end

local function ZoneRatio(r)
    local parent = _G.UIParent
    local mine = Num(r.GetEffectiveScale and r:GetEffectiveScale())
    local theirs = Num(parent and parent.GetEffectiveScale and parent:GetEffectiveScale())
    if not mine or mine <= 0 or not theirs or theirs <= 0 then return nil end
    return mine / theirs
end

local function ZoneTopLeft()
    local r = ZoneRoot()
    local ratio = ZoneRatio(r)
    local left, top = Num(r:GetLeft()), Num(r:GetTop())
    if not ratio or not left or not top then return nil end
    return left * ratio, top * ratio
end

local function ZonePlace(x, y)
    local r = ZoneRoot()
    local parent = _G.UIParent
    local ratio = ZoneRatio(r)
    if not parent or not ratio then return false end
    local pw, ph = Num(parent:GetWidth()), Num(parent:GetHeight())
    local w, h = Num(r:GetWidth()), Num(r:GetHeight())
    if pw and ph and w and h and pw > 0 and ph > 0 then
        w, h = w * ratio, h * ratio
        x = math.max(0, math.min(x, math.max(0, pw - w)))
        y = math.min(ph, math.max(y, math.min(h, ph)))
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", x / ratio, y / ratio)
    zApplied = CapturePoints(r)
    return true
end

local function ZoneManaged()
    return db and (db.zoneMapPoint ~= nil or not Near(db.zoneMapScale, 1, 0.001)) or false
end

local function ZoneSavePosition(x, y)
    if not db then return end
    if not x then x, y = ZoneTopLeft() end
    if x and y then db.zoneMapPoint = { x = x, y = y } end
end

local function ZoneApplyNow()
    if not zf or not db or zMoving or zSizing then return end
    if ZoneLocked() then
        zPending = true
        return
    end
    zPending = false
    local root = ZoneRoot()
    if not zBlizz and not zApplied then zBlizz = CapturePoints(root) end
    if zRestore then
        zRestore = false
        zf:SetScale(1)
        if zApplied and zBlizz and #zBlizz > 0 then SetPoints(root, zBlizz) end
        zApplied = nil
        if not ZoneManaged() then return end
    end
    local s = db.zoneMapScale
    if not Near(Num(zf:GetScale()), s, 0.001) then zf:SetScale(s) end
    local pos = db.zoneMapPoint
    if pos then ZonePlace(pos.x, pos.y) end
end

ZoneApply = function()
    local ok = pcall(ZoneApplyNow)
    if not ok then zPending = true end
end

-- Moving: drag the frame itself (the tab's own drag is Blizzard's; see OnTabDragStop).
local function ZoneStartDrag()
    if not zf or not db or db.locked or zMoving or zSizing then return end
    if ZoneLocked() then
        Print("the zone map cannot be moved in combat.")
        return
    end
    if zf.IsMovable and not zf:IsMovable() and zf.SetMovable then zf:SetMovable(true) end
    if zf.SetClampedToScreen then zf:SetClampedToScreen(true) end
    local r = ZoneRoot()
    if r ~= zf and r.SetMovable then r:SetMovable(true) end
    r:StartMoving()
    zMoving = true
end

local function ZoneStopDrag()
    if not zMoving then return end
    zMoving = false
    local r = ZoneRoot()
    r:StopMovingOrSizing()
    -- Ours lives in the saved variables, not in the client's layout-local copy.
    if r.SetUserPlaced then pcall(r.SetUserPlaced, r, false) end
    ZoneSavePosition()
    if db.zoneMapPoint then pcall(ZonePlace, db.zoneMapPoint.x, db.zoneMapPoint.y) end
    ZoneApply()
end

-- Blizzard's tab drag has just ended: keep where it put the frame, or undo it if locked.
local function OnTabDragStop()
    if not zf or not db then return end
    C_Timer.After(0, function()
        if not zf or not db then return end
        if db.locked then
            if db.zoneMapPoint or zBlizz then
                if db.zoneMapPoint then pcall(ZonePlace, db.zoneMapPoint.x, db.zoneMapPoint.y)
                elseif zBlizz and #zBlizz > 0 and not ZoneLocked() then pcall(SetPoints, ZoneRoot(), zBlizz) end
            end
        else
            ZoneSavePosition()
            ZoneApply()
        end
    end)
end

-- Resizing: the corner grip, scale only, the top-left corner stays put.
local function ZoneStopSizing()
    if not zSizing then return end
    zSizing = false
    if zGrip then zGrip:SetScript("OnUpdate", nil) end
    if zGrip and zGrip.anchorX then ZoneSavePosition(zGrip.anchorX, zGrip.anchorY) end
    ZoneApply()
end

local function ZoneSizingUpdate(self)
    if ZoneLocked() then
        ZoneStopSizing()
        return
    end
    local cx, cy = GetCursorPosition()
    cx, cy = Num(cx), Num(cy)
    if not cx or not cy then return end
    local s
    if self.screenLeft then
        local dx0, dy0 = self.startX - self.screenLeft, self.screenTop - self.startY
        local dx, dy = cx - self.screenLeft, self.screenTop - cy
        if dx0 > 10 and dy0 > 10 then
            s = self.startScale * ((dx / dx0) + (dy / dy0)) / 2
        end
    end
    if not s then s = self.startScale + (self.startY - cy) / 400 end
    s = Clamp(math.floor(s * 100 + 0.5) / 100, ZMIN, ZMAX)
    if Near(s, db.zoneMapScale, 0.001) and Near(Num(zf:GetScale()), s, 0.001) then return end
    db.zoneMapScale = s
    pcall(zf.SetScale, zf, s)
    if self.anchorX then pcall(ZonePlace, self.anchorX, self.anchorY) end
end

local function ZoneStartSizing(self, button)
    if button and button ~= "LeftButton" then return end
    if not zf or not db or db.locked or zMoving or zSizing then return end
    if ZoneLocked() then
        Print("the zone map cannot be resized in combat.")
        return
    end
    local cx, cy = GetCursorPosition()
    cx, cy = Num(cx), Num(cy)
    if not cx or not cy then return end
    self.startX, self.startY = cx, cy
    self.startScale = db.zoneMapScale
    self.anchorX, self.anchorY = ZoneTopLeft()
    local eff = Num(zf:GetEffectiveScale())
    local left, top = Num(zf:GetLeft()), Num(zf:GetTop())
    if eff and left and top then
        self.screenLeft, self.screenTop = left * eff, top * eff
    else
        self.screenLeft, self.screenTop = nil, nil
    end
    zSizing = true
    self:SetScript("OnUpdate", ZoneSizingUpdate)
end

local function ZoneUpdateWidgets()
    if zGrip then zGrip:SetShown((db and not db.locked and zf) and true or false) end
end

local function ZoneCreateGrip()
    if zGrip or not zf then return end
    local g = CreateFrame("Button", "GaarMapsForeverZoneGrip", zf)
    g:SetSize(18, 18)
    g:SetPoint("BOTTOMRIGHT", zf, "BOTTOMRIGHT", -2, 2)
    g:SetFrameStrata("HIGH")
    g:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    g:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    if g.SetPushedTexture then g:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down") end
    g:SetScript("OnMouseDown", ZoneStartSizing)
    g:SetScript("OnMouseUp", ZoneStopSizing)
    g:SetScript("OnHide", ZoneStopSizing)
    g:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_LEFT")
        tip:AddLine("Drag to resize the zone map")
        tip:AddLine(string.format("Scale: %d%%", Percent(db and db.zoneMapScale or 1)), 1, 1, 1)
        tip:Show()
    end)
    g:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    zGrip = g
end

local function OnZoneShown()
    if not db then return end
    ZoneApply()
    -- Blizzard may place its own saved position a moment after the show.
    C_Timer.After(0, ZoneApply)
    C_Timer.After(0.5, ZoneApply)
end

local function HookZone()
    if zHooked then return true end
    zf = ZoneFrame()
    if not zf or not db then zf = nil return false end
    zHooked = true
    zf:HookScript("OnShow", OnZoneShown)
    zf:HookScript("OnHide", ZoneStopDrag)
    -- The frame drags from anywhere on it; Blizzard's own tab drag keeps working.
    if zf.RegisterForDrag then
        pcall(zf.RegisterForDrag, zf, "LeftButton")
        if zf.EnableMouse and not ZoneLocked() then pcall(zf.EnableMouse, zf, true) end
        zf:HookScript("OnDragStart", ZoneStartDrag)
        zf:HookScript("OnDragStop", ZoneStopDrag)
    end
    local tab = _G.BattlefieldMapTab
    if type(tab) == "table" and tab.HookScript then
        pcall(tab.HookScript, tab, "OnDragStop", OnTabDragStop)
    end
    ZoneCreateGrip()
    ZoneUpdateWidgets()
    if zf:IsShown() then OnZoneShown() end
    return true
end

local function ZoneReset()
    if not db then return end
    if zMoving then ZoneStopDrag() end
    if zSizing then ZoneStopSizing() end
    db.zoneMapPoint = nil
    db.zoneMapScale = 1
    zRestore = true
    ZoneApply()
    if zPending then
        Print("zone map position and size reset; it moves back once combat ends.")
    else
        Print("zone map position and size reset (100%).")
    end
end

local function ZoneSetScalePercent(p)
    if not db then return end
    p = Num(tonumber(p))
    if not p or p < ZMIN * 100 or p > ZMAX * 100 then
        Print(string.format("zone map scale must be between %d and %d.", ZMIN * 100, ZMAX * 100))
        return
    end
    local s = math.floor(p + 0.5) / 100
    if zf and zf:IsShown() and not ZoneLocked() then
        local x, y = ZoneTopLeft()
        db.zoneMapScale = s
        if x then ZoneSavePosition(x, y) end
    else
        db.zoneMapScale = s
    end
    ZoneApply()
    if zPending then
        Print(string.format("zone map scale set to %d%%; it applies once combat ends.", Percent(s)))
    else
        Print(string.format("zone map scale set to %d%%.", Percent(s)))
    end
end

-- ---------------------------------------------------------------------------
-- Settings, shared by the slash command and the menu entries of the API
-- ---------------------------------------------------------------------------

local function ResetLayout()
    if not db then return end
    if moving then StopDrag() end
    if sizing then StopSizing() end
    db.position = nil
    db.scale = 1
    pendingRestore = true
    ApplyLayout()
    if pendingApply then
        Print("position and size reset; the map moves back once combat ends.")
    else
        Print("position and size reset to Blizzard's default (100%).")
    end
end

local function SetLocked(on)
    if not db then return end
    db.locked = on and true or false
    if db.locked then
        if moving then StopDrag() end
        if sizing then StopSizing() end
    end
    UpdateWidgets()
    ZoneUpdateWidgets()
    Print(db.locked and "maps locked: no moving or resizing (world map and zone map)."
        or "map unlocked: drag the title bar to move it, the bottom-right grip to resize it.")
end

-- Sets the scale from a percentage. On the open, windowed map the top-left corner stays put.
local function SetScalePercent(p, quiet)
    if not db then return end
    p = Num(tonumber(p))
    if not p or p < MIN_SCALE * 100 or p > MAX_SCALE * 100 then
        Print(string.format("scale must be between %d and %d.", MIN_SCALE * 100, MAX_SCALE * 100))
        return
    end
    local s = math.floor(p + 0.5) / 100
    if map and map:IsShown() and not IsMaximized() and not InCombat() then
        local x, y = TopLeft()
        db.scale = s
        if x then SavePosition(x, y) end
    else
        db.scale = s
    end
    ApplyLayout()
    if quiet then return end
    if pendingApply and InCombat() then
        Print(string.format("scale set to %d%%; it applies once combat ends.", Percent(s)))
    else
        Print(string.format("scale set to %d%%.", Percent(s)))
    end
end

local function SetFade(on)
    if not db then return end
    db.fade = on and true or false
    if not db.fade and faded then SetFaded(false) end
    Print("fade while moving " .. OnOff(db.fade) .. string.format(" (%d%% opacity while moving).", Percent(db.fadeAlpha)))
end

local function SetFadePercent(p, quiet)
    if not db then return end
    p = Num(tonumber(p))
    if not p or p < MIN_FADE * 100 or p > MAX_FADE * 100 then
        Print(string.format("fade opacity must be between %d and %d.", MIN_FADE * 100, MAX_FADE * 100))
        return
    end
    db.fadeAlpha = math.floor(p + 0.5) / 100
    if faded then SetFaded(true) end
    if quiet then return end
    Print(string.format("fade opacity set to %d%%", Percent(db.fadeAlpha))
        .. (db.fade and "." or " (fade is off: /gmf fade on)."))
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function Yes(v) return v and "yes" or "MISSING" end

-- ---------------------------------------------------------------------------
-- Zone levels: "Level 35-45" on the world map (setting zoneLevels)
--
-- One level line, no name text of our own. Continent view: while the cursor is over a zone, the line sits
-- directly under the name Blizzard's own area label shows (the label frame's Name, found among the map's
-- overlay frames). Zone view: the same spot (distance below the canvas top measured from that Name while
-- it shows text, cached; fallback ZL_LINE_TOP), showing the hovered neighbour's range, else the map's own.
-- The hovered zone comes from C_Map.GetMapInfoAtPosition on the cursor's normalised position, the same
-- read Blizzard's label uses. Only our own frame and font strings are created; no Blizzard function or
-- frame is written. Helpers live in one table (LuaJIT's 200-locals-per-chunk limit).
-- ---------------------------------------------------------------------------

-- Zone view: the level line's fixed distance below the canvas top, until measured from Blizzard's label.
local ZL_LINE_TOP = -48
local ZL = { frame = nil, hoverFS = nil, matched = nil, shownId = nil, acc = 0, lineTop = nil }
local EN_DASH = "\226\128\147"

local function SafeString(v)
    if type(v) ~= "string" then return nil end
    if _G.issecretvalue and _G.issecretvalue(v) then return nil end
    return v
end

-- Range of a uiMapID: { min, max, source } or nil. The static table first (id, then name), then
-- C_Map.GetMapLevels only when it answers with sane classic numbers for a zone map.
function ZL.Range(id, name)
    id = Num(id)
    if not id then return nil end
    local data = type(ns) == "table" and ns.zoneLevels
    if data then
        local r = data.byId[id]
        if r then return r[1], r[2], "id" end
        name = SafeString(name)
        if not name then
            local ok, info = pcall(C_Map.GetMapInfo, id)
            name = ok and type(info) == "table" and SafeString(info.name) or nil
        end
        r = name and data.byName[name]
        if r then return r[1], r[2], "name" end
    end
    if C_Map and C_Map.GetMapLevels then
        local ok, info = pcall(C_Map.GetMapInfo, id)
        local mt = ok and type(info) == "table" and Num(info.mapType)
        if mt == 3 then
            local ok2, lo, hi = pcall(C_Map.GetMapLevels, id)
            lo, hi = ok2 and Num(lo), ok2 and Num(hi)
            if lo and hi and lo > 0 and hi <= 60 and lo <= hi then return lo, hi, "api" end
        end
    end
end

function ZL.Colored(lo, hi)
    local mine = Num(UnitLevel("player"))
    local r, g, b = BF.LevelDifficultyColor((lo + hi) / 2, mine)
    local text = (lo == hi) and ("Level " .. lo) or ("Level " .. lo .. EN_DASH .. hi)
    return text, r, g, b
end

function ZL.Create()
    if ZL.frame then return true end
    local m = GetMap()
    local parent = m and m.ScrollContainer
    if type(parent) ~= "table" or not parent.GetObjectType or InCombat() then return false end
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f:SetFrameLevel((parent:GetFrameLevel() or 0) + 50)
    local hoverFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    hoverFS:SetShadowOffset(1, -1)
    hoverFS:Hide()
    ZL.frame, ZL.hoverFS = f, hoverFS
    f:SetScript("OnUpdate", function(_, elapsed)
        ZL.acc = ZL.acc + elapsed
        if ZL.acc >= 0.1 then ZL.acc = 0 ZL.Update() end
    end)
    return true
end

-- Blizzard's area label frame (has Name and SetLabel), if the map has one; anchoring target only.
function ZL.LabelFrame()
    local m = GetMap()
    local list = m and m.overlayFrames
    if type(list) == "table" then
        for _, fr in pairs(list) do
            if type(fr) == "table" and type(fr.SetLabel) == "function" and type(fr.Name) == "table" then return fr end
        end
    end
end

function ZL.HideAll()
    if not ZL.frame then return end
    ZL.hoverFS:Hide()
    ZL.matched = nil
end

-- Cursor's zone on the shown map: the neighbour's { mapID, name } or nil (nothing, or the map itself).
function ZL.Hovered(m, mapID)
    local sc = m.ScrollContainer
    local over = sc and sc.IsMouseOver and sc:IsMouseOver()
    if not (over and sc.GetNormalizedCursorPosition and C_Map.GetMapInfoAtPosition) then return nil end
    local ok, x, y = pcall(sc.GetNormalizedCursorPosition, sc)
    x, y = ok and Num(x), ok and Num(y)
    if not (x and y) then return nil end
    local hover = C_Map.GetMapInfoAtPosition(mapID, x, y)
    local hid = type(hover) == "table" and Num(hover.mapID)
    if not hid or hid == mapID then return nil end
    return hid, hover.name
end

-- Zone view: measure how far below the canvas top Blizzard's label Name ends, while it shows text (the
-- cache keeps the line from jumping when the label is empty). Reads positions only.
function ZL.MeasureLine(label)
    local name = label and label.Name
    if type(name) ~= "table" or not name.GetText or not name.GetBottom then return end
    local okT, t = pcall(name.GetText, name)
    if not okT or not SafeString(t) or t == "" then return end
    local okB, bottom = pcall(name.GetBottom, name)
    local okF, top = pcall(ZL.frame.GetTop, ZL.frame)
    bottom, top = okB and Num(bottom), okF and Num(top)
    local sn, sf = Num(name:GetEffectiveScale()), Num(ZL.frame:GetEffectiveScale())
    if not (bottom and top and sn and sf and sf > 0) then return end
    local off = (top * sf - bottom * sn) / sf
    if off > 0 and off < 200 then ZL.lineTop = -off - 2 end
end

function ZL.Update()
    local m = GetMap()
    if not (db and db.zoneLevels) or not m or not m:IsShown() then return ZL.HideAll() end
    local mapID = Num(m.GetMapID and m:GetMapID())
    local ok, info = pcall(C_Map.GetMapInfo, mapID or 0)
    if not mapID or not ok or type(info) ~= "table" then return ZL.HideAll() end
    local mapType = Num(info.mapType)
    ZL.mapID = mapID
    local label = ZL.LabelFrame()
    local lo, hi, src, shownId, shownName
    if mapType == 3 then
        -- Zone view: neighbour under the cursor, else the map's own zone; same spot either way.
        ZL.MeasureLine(label)
        local hid, hname = ZL.Hovered(m, mapID)
        if hid then
            shownId, shownName = hid, SafeString(hname)
        else
            shownId, shownName = mapID, SafeString(info.name)
        end
    elseif mapType == 2 or mapType == 1 then
        -- Continent view: a level line under Blizzard's hover label.
        local hid, hname = ZL.Hovered(m, mapID)
        if hid then shownId, shownName = hid, SafeString(hname) end
    else
        return ZL.HideAll()
    end
    if shownId then lo, hi, src = ZL.Range(shownId, shownName) end
    if not lo then
        ZL.hoverFS:Hide()
        ZL.matched = shownId and (shownId .. " (no range)") or nil
        return
    end
    local text, r, g, b = ZL.Colored(lo, hi)
    ZL.hoverFS:ClearAllPoints()
    if mapType == 3 then
        ZL.hoverFS:SetPoint("TOP", ZL.frame, "TOP", 0, ZL.lineTop or ZL_LINE_TOP)
    elseif label and label.Name.GetObjectType then
        ZL.hoverFS:SetPoint("TOP", label.Name, "BOTTOM", 0, -2)
    else
        ZL.hoverFS:SetPoint("TOP", ZL.frame, "TOP", 0, -50)
    end
    ZL.hoverFS:SetText(text)
    ZL.hoverFS:SetTextColor(r, g, b)
    ZL.hoverFS:Show()
    ZL.matched = string.format("%d %s %d%s%d (%s)", shownId, shownName or "?", lo, EN_DASH, hi, src)
end

function ZL.Init()
    if ZL.hooked then return end
    local m = GetMap()
    if not m then return end
    if not ZL.Create() then return end
    ZL.hooked = true
end

function ZL.SetEnabled(on)
    if not db then return end
    db.zoneLevels = on and true or false
    if not db.zoneLevels then ZL.HideAll() end
    Print("zone levels on the map " .. OnOff(db.zoneLevels) .. ".")
end

local function PositionText()
    local pos = db and db.position
    return pos and string.format("moved (%.0f, %.0f)", pos.x, pos.y) or "default position"
end

-- The intro GaarForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "Move, scale and fade Blizzard's world map window (Map & Quest Log). Nice to know: drag the title bar to move it and the bottom-right grip to scale it (50-150%); it fades while you move (35% by default); the map is never moved or scaled in combat, and the maximized map is left alone."

local function PrintHelp()
    Print(INTRO)
    Print("drag the world map's title bar to move it, and the grip in its bottom-right corner to resize it (windowed map only).")
    Print("/gmf lock | /gmf unlock - stop or allow moving and resizing (now: " .. ((db and db.locked) and "locked" or "unlocked") .. ")")
    Print("/gmf reset - Blizzard's default position and 100% scale")
    Print(string.format("/gmf scale <%d-%d> - set the scale in percent (now: %d%%)", MIN_SCALE * 100, MAX_SCALE * 100, Percent(db and db.scale or 1)))
    Print("/gmf fade on | /gmf fade off - fade the map while you move (now: " .. OnOff(db and db.fade) .. ")")
    Print(string.format("/gmf fade <%d-%d> - opacity while moving, in percent (now: %d%%)", MIN_FADE * 100, MAX_FADE * 100, Percent(db and db.fadeAlpha or DEFAULT_FADE_ALPHA)))
    Print("Zone map (Shift+M): drag the frame or Blizzard's tab to move it, the bottom-right grip to scale it (50-200%).")
    Print(string.format("/gmf zone scale <%d-%d> - zone map scale in percent (now: %d%%)", ZMIN * 100, ZMAX * 100, Percent(db and db.zoneMapScale or 1)))
    Print("/gmf zone reset - zone map back to its default position and 100%")
    Print("Right-click the round portrait in the world map's top-left corner for this addon's menu (lock, reset, scale, fade).")
    Print("/gmf portrait - state of the portrait right-click button (hover it first)")
    Print("/gmf levels on | /gmf levels off - show the zone's level range, Level 35" .. EN_DASH .. "45, on the world map (now: " .. OnOff(db and db.zoneLevels) .. ")")
    Print("/gmf status - what this client offers and the current settings")
end

local function PrintStatus()
    local f = GetMap()
    local border = f and f.BorderFrame
    Print("version " .. VERSION)
    Print("WorldMapFrame: " .. Yes(f) .. "   IsMaximized: " .. Yes(f and type(f.IsMaximized) == "function")
        .. "   title bar: " .. Yes(type(border) == "table" and type(border.TitleContainer) == "table"))
    Print("UpdateUIPanelPositions: " .. Yes(type(_G.UpdateUIPanelPositions) == "function")
        .. "   IsPlayerMoving: " .. Yes(type(_G.IsPlayerMoving) == "function"))
    if f then
        Print("map: " .. (f:IsShown() and "open" or "closed") .. ", " .. (IsMaximized() and "maximized" or "windowed")
            .. string.format(", scale now %d%%", Percent(Num(f:GetScale()) or 1)))
    end
    PortraitStatus()
    Print("zone levels: " .. OnOff(db and db.zoneLevels) .. " (one line under the hover name; zone view: hovered neighbour, else this map; line top " .. tostring(ZL.lineTop or (ZL_LINE_TOP .. " fallback")) .. "), map id " .. tostring(ZL.mapID or "?") .. ", match: " .. tostring(ZL.matched or "none") .. ", zones in table: " .. tostring(ns and ns.zoneLevels and ns.zoneLevels.count or 0))
    Print("locked: " .. ((db and db.locked) and "yes" or "no"))
    Print(string.format("scale: %d%%", Percent(db and db.scale or 1)) .. "   position: " .. PositionText())
    Print("fade while moving: " .. OnOff(db and db.fade) .. string.format(" (%d%% opacity)", Percent(db and db.fadeAlpha or DEFAULT_FADE_ALPHA)))
    Print("zone map: " .. (zf and "hooked" or "not loaded yet") .. string.format(", scale %d%%", Percent(db and db.zoneMapScale or 1))
        .. "   position: " .. ((db and db.zoneMapPoint) and string.format("moved (%.0f, %.0f)", db.zoneMapPoint.x, db.zoneMapPoint.y) or "default position"))
    if pendingApply or zPending then Print("waiting for combat to end to apply the layout.") end
    if AddOnLoaded("GaarMap") then Print("GaarMap is loaded too: it also scales and fades the map. Use one of the two.") end
end

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    local scaleArg = msg:match("^scale (%d+)%%?$")
    local fadeArg = msg:match("^fade (%d+)%%?$")
    local zoneScaleArg = msg:match("^zone scale (%d+)%%?$")
    if msg == "lock" then
        SetLocked(true)
    elseif msg == "unlock" then
        SetLocked(false)
    elseif msg == "reset" then
        ResetLayout()
    elseif msg == "zone reset" then
        ZoneReset()
    elseif zoneScaleArg then
        ZoneSetScalePercent(zoneScaleArg)
    elseif msg == "status" then
        PrintStatus()
    elseif msg == "levels on" or msg == "levels off" then
        ZL.SetEnabled(msg == "levels on")
    elseif msg == "portrait" then
        PortraitStatus()
    elseif scaleArg then
        SetScalePercent(scaleArg)
    elseif msg == "fade on" or msg == "fade off" then
        SetFade(msg == "fade on")
    elseif fadeArg then
        SetFadePercent(fadeArg)
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: GaarMapsForeverAPI
--
-- For GaarForever, the family hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in GaarMapsForeverDB and change only through the
-- same functions /gmf uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "unlocked · 100% · default position · fade 35%"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func },
--                        { text, radio = true, checked, func }, { text, submenu } and { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    return (db.locked and "locked" or "unlocked") .. DOT .. Percent(db.scale) .. "%" .. DOT
        .. (db.position and "moved" or "default position") .. DOT
        .. (db.fade and ("fade " .. Percent(db.fadeAlpha) .. "%") or "fade off")
end

local function MenuEntries()
    if not db then return {} end
    local scales, fades = {}, {}
    for _, p in ipairs(SCALE_PRESETS) do
        scales[#scales + 1] = { text = p .. "%", radio = true,
            checked = function() return Percent(db.scale) == p end,
            func = function() SetScalePercent(p) end }
    end
    local zones = {}
    for _, p in ipairs(ZONE_PRESETS) do
        zones[#zones + 1] = { text = p .. "%", radio = true,
            checked = function() return Percent(db.zoneMapScale) == p end,
            func = function() ZoneSetScalePercent(p) end }
    end
    for _, p in ipairs(FADE_PRESETS) do
        fades[#fades + 1] = { text = p .. "%", radio = true,
            checked = function() return Percent(db.fadeAlpha) == p end,
            func = function() SetFadePercent(p) end }
    end
    return {
        { text = "Lock position & size", checkbox = true, checked = function() return db.locked end,
          func = function() SetLocked(not db.locked) end },
        { text = "Reset position & size", func = ResetLayout },
        { text = "Scale", submenu = scales },
        { divider = true },
        { text = "Fade while moving", checkbox = true, checked = function() return db.fade end,
          func = function() SetFade(not db.fade) end },
        { text = "Fade opacity", submenu = fades },
        { divider = true },
        { text = "Zone level range on the map", checkbox = true, checked = function() return db.zoneLevels end,
          func = function() ZL.SetEnabled(not db.zoneLevels) end },
        { divider = true },
        { text = "Zone map (Shift+M) scale", submenu = zones },
        { text = "Reset zone map", func = ZoneReset },
    }
end

-- Right-click on the map's portrait: the same entries as the hub's menu, drawn by MenuUtil.
ShowPortraitMenu = function(owner)
    local MU = _G.MenuUtil
    if type(MU) == "table" and type(MU.CreateContextMenu) == "function" then
        local ok, err = pcall(MU.CreateContextMenu, owner, function(_, root)
            BF.RenderMenu(root, MenuEntries(), A.title)
        end)
        if ok then return end
        if not portraitErrShown then
            portraitErrShown = true
            Print("the menu failed: " .. tostring(err) .. " - type /gmf for the options.")
        end
        return
    end
    Print("the menu is not available on this client; type /gmf for the options.")
end

_G.GaarMapsForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries(), A.title) end,
    SetMinimapHidden = function() end,
}
_G.BetterMapsForeverAPI = _G.GaarMapsForeverAPI -- the name before the folder rename

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    BF.Migrate("GaarMapsForeverDB", "BetterMapsForeverDB") -- the old folder's settings, once (see Lib.lua)
    if type(GaarMapsForeverDB) ~= "table" then GaarMapsForeverDB = {} end
    db = GaarMapsForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    if type(db.locked) ~= "boolean" then db.locked = false end
    if type(db.fade) ~= "boolean" then db.fade = true end
    if type(db.zoneLevels) ~= "boolean" then db.zoneLevels = true end
    db.scale = Clamp(Num(tonumber(db.scale)) or 1, MIN_SCALE, MAX_SCALE)
    db.fadeAlpha = Clamp(Num(tonumber(db.fadeAlpha)) or DEFAULT_FADE_ALPHA, MIN_FADE, MAX_FADE)
    local pos = db.position
    if pos ~= nil and (type(pos) ~= "table" or not Num(pos.x) or not Num(pos.y)) then
        db.position = nil
    end
    db.zoneMapScale = Clamp(Num(tonumber(db.zoneMapScale)) or 1, ZMIN, ZMAX)
    local zpos = db.zoneMapPoint
    if zpos ~= nil and (type(zpos) ~= "table" or not Num(zpos.x) or not Num(zpos.y)) then
        db.zoneMapPoint = nil
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
            ZL.Init()
            HookZone() -- immediately, if Blizzard_BattlefieldMap is already loaded
        elseif db and not hooked then
            -- In case the map arrives with a Blizzard addon loaded after us.
            HookBlizzard()
        end
        if db and not ZL.hooked and arg1 == "Blizzard_WorldMap" then ZL.Init() end
        if db and arg1 == "Blizzard_BattlefieldMap" then HookZone() end
    elseif event == "PLAYER_LOGIN" then
        if db then HookBlizzard() HookZone() ZL.Init() end
        if AddOnLoaded("GaarMap") then
            Print("GaarMap is loaded too and also scales and fades the world map; use one of the two.")
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- A drag that is still going when combat starts ends here, where it is.
        if moving then StopDrag() end
        if sizing then StopSizing() end
        if zMoving then ZoneStopDrag() end
        if zSizing then ZoneStopSizing() end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if portraitPending then CreatePortraitButton() end
        if not ZL.hooked then ZL.Init() end
        if pendingApply or (map and map:IsShown()) then
            pendingApply = false
            ApplyLayout()
        end
        if zPending then ZoneApply() end
    end
end)

SLASH_GAARMAPSFOREVER1 = "/gmf"
SLASH_GAARMAPSFOREVER2 = "/gaarmapsforever"
SLASH_GAARMAPSFOREVER3 = "/bmf" -- the command before the Gaar rename
SLASH_GAARMAPSFOREVER4 = "/bettermapsforever"
SlashCmdList.GAARMAPSFOREVER = OnSlash
