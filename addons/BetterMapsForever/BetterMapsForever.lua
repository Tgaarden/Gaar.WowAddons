--[[
  BetterMapsForever - move, scale and fade the world map ("Map & Quest Log") on WoW Forever.

  It changes these things about Blizzard's own WorldMapFrame and nothing else:

    * Move: drag the title bar of the windowed map. The position is saved account-wide in
      BetterMapsForeverDB and put back every time the map opens or Blizzard's panel layout
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
    * /bmf for help, lock, unlock, reset, status, scale <50-150>, fade on|off and fade <percent>.
    * BetterMapsForeverAPI, a small global table for BetterForever's hub menu (version,
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
local ADDON_NAME = ... or "BetterMapsForever"
local PREFIX = "|cff33ff99BetterMapsForever|r: "
local DOT = " \194\183 "

local VERSION = "1.1.1"

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
}

-- Every key BetterMapsForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = { locked = true, scale = true, position = true, fade = true, fadeAlpha = true }

local db                -- BetterMapsForeverDB, bound at ADDON_LOADED (never at file scope)
local map               -- WorldMapFrame once found
local dragHandle        -- invisible handle over the title bar
local grip              -- resize grip in the bottom-right corner
local blizzardPoints    -- the anchor Blizzard last gave the map, for /bmf reset
local appliedPoints     -- the anchor we last set, so it is not mistaken for Blizzard's
local scaled            -- we have set a scale other than Blizzard's 100% on the map
local pendingApply      -- a move or scale that has to wait for combat to end
local pendingRestore    -- /bmf reset is waiting to put Blizzard's anchor and scale back
local moving            -- a title-bar drag is in progress
local sizing            -- a grip drag is in progress
local faded             -- the map is at the fade opacity right now
local hooked, panelHooked

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

-- Where the client hides a number it hands back a secret value, which can be neither compared
-- nor used in a sum. Those are treated as no number at all, and checked before anything else.
local issecretvalue = _G.issecretvalue
local function Num(v)
    if issecretvalue and issecretvalue(v) then return nil end
    if type(v) ~= "number" or v ~= v then return nil end
    return v
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function Percent(v) return math.floor(v * 100 + 0.5) end

local function OnOff(v) return v and "on" or "off" end

-- Whether an addon is loaded: C_AddOns on newer clients, the old global otherwise.
local function AddOnLoaded(name)
    local c = _G.C_AddOns
    if type(c) == "table" and type(c.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(c.IsAddOnLoaded, name)
        if ok and loaded then return true end
    end
    if type(_G.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(_G.IsAddOnLoaded, name)
        if ok and loaded then return true end
    end
    return false
end

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
-- Blizzard, or restores Blizzard's own layout after /bmf reset. Never in combat.
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

    -- Remember where Blizzard put it, for /bmf reset; our own anchor does not count.
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
    local handle = CreateFrame("Frame", "BetterMapsForeverDragHandle", map)
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
        tip:AddLine("Resize from the grip in the bottom-right corner. /bmf lock to lock, /bmf reset to reset.", 1, 1, 1, true)
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
    local g = CreateFrame("Button", "BetterMapsForeverGrip", map)
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
        if not (issecretvalue and issecretvalue(m)) then return m and true or false end
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
    map:HookScript("OnHide", OnMapHidden)
    for _, name in ipairs({ "Maximize", "Minimize", "SynchronizeDisplayState" }) do
        if type(map[name]) == "function" then hooksecurefunc(map, name, OnDisplayStateChanged) end
    end

    CreateDragHandle()
    CreateGrip()
    UpdateWidgets()
    if map:IsShown() then OnMapShown() end
    return true
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
    Print(db.locked and "map locked: no moving or resizing."
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
        .. (db.fade and "." or " (fade is off: /bmf fade on)."))
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function Yes(v) return v and "yes" or "MISSING" end

local function PositionText()
    local pos = db and db.position
    return pos and string.format("moved (%.0f, %.0f)", pos.x, pos.y) or "default position"
end

-- The intro BetterForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "Move, scale and fade Blizzard's world map window (Map & Quest Log). Nice to know: drag the title bar to move it and the bottom-right grip to scale it (50-150%); it fades while you move (35% by default); the map is never moved or scaled in combat, and the maximized map is left alone."

local function PrintHelp()
    Print(INTRO)
    Print("drag the world map's title bar to move it, and the grip in its bottom-right corner to resize it (windowed map only).")
    Print("/bmf lock | /bmf unlock - stop or allow moving and resizing (now: " .. ((db and db.locked) and "locked" or "unlocked") .. ")")
    Print("/bmf reset - Blizzard's default position and 100% scale")
    Print(string.format("/bmf scale <%d-%d> - set the scale in percent (now: %d%%)", MIN_SCALE * 100, MAX_SCALE * 100, Percent(db and db.scale or 1)))
    Print("/bmf fade on | /bmf fade off - fade the map while you move (now: " .. OnOff(db and db.fade) .. ")")
    Print(string.format("/bmf fade <%d-%d> - opacity while moving, in percent (now: %d%%)", MIN_FADE * 100, MAX_FADE * 100, Percent(db and db.fadeAlpha or DEFAULT_FADE_ALPHA)))
    Print("/bmf status - what this client offers and the current settings")
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
    Print("locked: " .. ((db and db.locked) and "yes" or "no"))
    Print(string.format("scale: %d%%", Percent(db and db.scale or 1)) .. "   position: " .. PositionText())
    Print("fade while moving: " .. OnOff(db and db.fade) .. string.format(" (%d%% opacity)", Percent(db and db.fadeAlpha or DEFAULT_FADE_ALPHA)))
    if pendingApply then Print("waiting for combat to end to apply the layout.") end
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
    if msg == "lock" then
        SetLocked(true)
    elseif msg == "unlock" then
        SetLocked(false)
    elseif msg == "reset" then
        ResetLayout()
    elseif msg == "status" then
        PrintStatus()
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
-- Public API: BetterMapsForeverAPI
--
-- For BetterForever, the family hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterMapsForeverDB and change only through the
-- same functions /bmf uses, so the addon behaves the same with or without the hub.
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
    }
end

-- Draws the entries into a MenuUtil description (root or submenu); every method is checked first.
local function RenderMenu(root, entries)
    if type(root) ~= "table" then return end
    for _, e in ipairs(entries) do
        if e.divider then
            if type(root.CreateDivider) == "function" then root:CreateDivider() end
        elseif e.submenu then
            if type(root.CreateButton) == "function" then
                local sub = root:CreateButton(e.text)
                RenderMenu(sub, e.submenu)
            end
        elseif e.radio and type(root.CreateRadio) == "function" then
            root:CreateRadio(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox and type(root.CreateCheckbox) == "function" then
            root:CreateCheckbox(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox or e.radio then
            -- A menu without checkboxes or radios: show the state in the label instead.
            local mark = e.radio and (e.checked() and "(o) " or "( ) ") or (e.checked() and "[x] " or "[ ] ")
            root:CreateButton(mark .. e.text, function() e.func() end)
        else
            root:CreateButton(e.text, function() e.func() end)
        end
    end
end

_G.BetterMapsForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) RenderMenu(root, MenuEntries()) end,
    SetMinimapHidden = function() end,
}

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterMapsForeverDB) ~= "table" then BetterMapsForeverDB = {} end
    db = BetterMapsForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    if type(db.locked) ~= "boolean" then db.locked = false end
    if type(db.fade) ~= "boolean" then db.fade = true end
    db.scale = Clamp(Num(tonumber(db.scale)) or 1, MIN_SCALE, MAX_SCALE)
    db.fadeAlpha = Clamp(Num(tonumber(db.fadeAlpha)) or DEFAULT_FADE_ALPHA, MIN_FADE, MAX_FADE)
    local pos = db.position
    if pos ~= nil and (type(pos) ~= "table" or not Num(pos.x) or not Num(pos.y)) then
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
        elseif db and not hooked then
            -- In case the map arrives with a Blizzard addon loaded after us.
            HookBlizzard()
        end
    elseif event == "PLAYER_LOGIN" then
        if db then HookBlizzard() end
        if AddOnLoaded("GaarMap") then
            Print("GaarMap is loaded too and also scales and fades the world map; use one of the two.")
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- A drag that is still going when combat starts ends here, where it is.
        if moving then StopDrag() end
        if sizing then StopSizing() end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingApply or (map and map:IsShown()) then
            pendingApply = false
            ApplyLayout()
        end
    end
end)

SLASH_BETTERMAPSFOREVER1 = "/bmf"
SLASH_BETTERMAPSFOREVER2 = "/bettermapsforever"
SlashCmdList.BETTERMAPSFOREVER = OnSlash
