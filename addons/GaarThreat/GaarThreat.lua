--[[
  Gaar Threat — real-time group threat meter, ported from Deepward Threat (WotLK 3.3.5a)
  to WoW Classic Era.

    * One class-coloured bar per group member with threat on your current target.
    * Bars scaled to the highest threat; each shows the threat value and aggro percent.
    * The aggro holder is flagged red, your own row is marked.
    * Pull warning: when you cross ~90% of the pull threshold without tanking, the window
      flashes and (optionally) plays a sound.

  /gaarthreat (or /gthreat) toggles it. Drag to move, corner grip to resize, right-click for
  options. Settings also live under Gaar -> Threat in the AddOns options.

  Classic Era port notes vs the WotLK original:
   * The real threat API is here too - UnitDetailedThreatSituation and UNIT_THREAT_LIST_UPDATE
     both exist on this client - so the threat numbers are the server's, not estimates.
   * Raw threat comes back 100x on this client, so it is divided by 100 by default ("1 damage
     = 1 threat"), same as other Classic threat meters do.
   * GetNumRaidMembers/GetNumPartyMembers are gone: group scanning uses IsInRaid,
     GetNumGroupMembers and GetNumSubgroupMembers.
   * SetBackdrop needs the "BackdropTemplate" mixin; solid textures need SetColorTexture;
     SetMinResize/SetMaxResize became SetResizeBounds; PlaySound takes a SOUNDKIT id, not a
     string. Every one of those is feature-detected rather than assumed.
   * No EasyMenu/dropdown API: options are a checkbox panel, shared with the Gaar options entry.
]]

local _G = _G
local ADDON = "Gaar Threat"

local function DB()
    if type(GaarThreatDB) ~= "table" then GaarThreatDB = {} end
    local d = GaarThreatDB
    if d.width  == nil then d.width  = 220 end
    if d.height == nil then d.height = 150 end
    if d.autoShow == nil then d.autoShow = false end  -- show when combat starts (never auto-hides)
    if d.warn == nil then d.warn = true end           -- pull-aggro warning flash
    if d.sound == nil then d.sound = true end
    if d.shown == nil then d.shown = false end        -- persistent visibility
    if d.showInInstance == nil then d.showInInstance = true end
    if d.downscale == nil then d.downscale = true end -- raw threat is 100x on this client
    if d.showPets == nil then d.showPets = true end   -- pets hold threat of their own
    return d
end

local function SetSolid(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
end

local function ClassColor(unit)
    if unit and UnitIsPlayer(unit) then
        local _, cls = UnitClass(unit)
        local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        if c then return c.r, c.g, c.b end
    end
    return 0.55, 0.55, 0.6
end

local function ShortNum(n)
    n = n or 0
    if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end

-- Group member unit tokens, each with its pet. Pets hold real threat - a warlock's voidwalker
-- or a hunter's boar can be the one tanking - so leaving them out makes the list lie.
-- GetNumRaidMembers/GetNumPartyMembers are gone on this client.
local function GroupUnits()
    local u = {}
    local pets = DB().showPets
    local function add(unit, petUnit, owner)
        u[#u + 1] = { unit = unit }
        if pets and petUnit and UnitExists(petUnit) then
            u[#u + 1] = { unit = petUnit, pet = true, owner = owner }
        end
    end
    local inRaid = IsInRaid and IsInRaid()
    if inRaid then
        local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
        for i = 1, n do add("raid" .. i, "raidpet" .. i, "raid" .. i) end
    else
        add("player", "pet", "player")
        local n = (GetNumSubgroupMembers and GetNumSubgroupMembers())
            or (GetNumGroupMembers and math.max(0, GetNumGroupMembers() - 1)) or 0
        for i = 1, n do add("party" .. i, "partypet" .. i, "party" .. i) end
    end
    return u
end

local function WarnSound()
    if not PlaySound then return end
    if SOUNDKIT and SOUNDKIT.IG_QUEST_FAILED then
        PlaySound(SOUNDKIT.IG_QUEST_FAILED)
    else
        pcall(PlaySound, "igQuestFailed")
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
local Redraw
local frame = CreateFrame("Frame", "GaarThreatFrame", UIParent, "BackdropTemplate")
local d0 = DB()
frame:SetSize(d0.width, d0.height)
if d0.point then frame:SetPoint(d0.point, UIParent, d0.point, d0.x or 0, d0.y or 0)
else frame:SetPoint("CENTER", -300, 0) end
frame:SetMovable(true); frame:SetResizable(true); frame:EnableMouse(true); frame:SetClampedToScreen(true)
if frame.SetResizeBounds then frame:SetResizeBounds(160, 80, 500, 640)
elseif frame.SetMinResize then frame:SetMinResize(160, 80); frame:SetMaxResize(500, 640) end
frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
frame:SetBackdropColor(0.05, 0.07, 0.12, 0.92)
frame:SetBackdropBorderColor(0.35, 0.55, 0.9, 1)
frame:Hide()
-- Deliberately NOT in UISpecialFrames: Escape shouldn't close the threat meter mid-pull.

local function SavePos()
    local d = DB()
    local p, _, _, x, y = frame:GetPoint()
    d.point, d.x, d.y = p, x, y
    d.width, d.height = math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5)
end

local header = CreateFrame("Frame", nil, frame)
header:SetPoint("TOPLEFT", 4, -4); header:SetPoint("TOPRIGHT", -4, -4); header:SetHeight(16)
local htex = header:CreateTexture(nil, "BACKGROUND"); htex:SetAllPoints(); SetSolid(htex, 0.12, 0.16, 0.28, 0.9)
frame.title = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
frame.title:SetPoint("LEFT", 4, 0); frame.title:SetText("|cffffd100Threat|r")

frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function() frame:StartMoving() end)
frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing(); SavePos() end)

local ROW_H = 16
local rows = {}
local function Row(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, frame)
    r:SetHeight(ROW_H)
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    r.bar:SetPoint("TOPLEFT"); r.bar:SetPoint("BOTTOMLEFT"); r.bar:SetWidth(1)
    r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(); SetSolid(r.bg, 0, 0, 0, 0.35)
    r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.left:SetPoint("LEFT", 4, 0); r.left:SetJustifyH("LEFT")
    r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.right:SetPoint("RIGHT", -4, 0); r.right:SetJustifyH("RIGHT")
    rows[i] = r
    return r
end

local function VisibleRows()
    return math.max(1, math.floor((frame:GetHeight() - 24) / ROW_H))
end

local flash = frame:CreateTexture(nil, "OVERLAY")
flash:SetAllPoints(); SetSolid(flash, 1, 0, 0, 0.25); flash:Hide()
local flashT = 0

Redraw = function()
    if not frame:IsShown() then return end
    local mob = "target"
    local haveMob = UnitExists(mob) and UnitCanAttack("player", mob)
    frame.title:SetText(haveMob and ("|cffffd100Threat:|r " .. (UnitName(mob) or "")) or "|cffffd100Threat|r")

    local list, topVal, myPct, myTanking = {}, 1, 0, false
    local scale = DB().downscale and 100 or 1
    if haveMob then
        for _, entry in ipairs(GroupUnits()) do
            local u = entry.unit
            if UnitExists(u) then
                local isTanking, _, threatpct, _, threatval = UnitDetailedThreatSituation(u, mob)
                if threatval and threatval > 0 then
                    threatval = threatval / scale
                    list[#list + 1] = { unit = u, name = UnitName(u) or "?", pct = threatpct or 0,
                                        val = threatval, tanking = isTanking,
                                        pet = entry.pet, owner = entry.owner }
                    if threatval > topVal then topVal = threatval end
                    if UnitIsUnit(u, "player") then myPct = threatpct or 0; myTanking = isTanking end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.val > b.val end)

    local shown = VisibleRows()
    for i = 1, shown do
        local r = Row(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 4, -22 - (i - 1) * ROW_H)
        r:SetPoint("TOPRIGHT", -4, -22 - (i - 1) * ROW_H)
        local e = list[i]
        if e then
            -- A pet borrows its owner's class colour, dimmed, so it reads as theirs without
            -- being mistaken for the player's own row.
            local cr, cg, cb
            if e.pet then
                cr, cg, cb = ClassColor(e.owner)
                cr, cg, cb = cr * 0.65, cg * 0.65, cb * 0.65
            else
                cr, cg, cb = ClassColor(e.unit)
            end
            if e.tanking then cr, cg, cb = 0.85, 0.2, 0.2 end   -- aggro holder = red
            r.bar:SetWidth(math.max(1, (frame:GetWidth() - 8) * (e.val / topVal)))
            r.bar:SetVertexColor(cr, cg, cb, 0.9)
            local tag = e.tanking and "|cffff4040<|r " or ""
            local me = UnitIsUnit(e.unit, "player") and "|cffffff00>|r " or ""
            local label = e.name
            if e.pet then
                local owner = e.owner and UnitName(e.owner)
                label = label .. (owner and (" |cff888888(" .. owner .. ")|r") or " |cff888888(pet)|r")
            end
            r.left:SetText(tag .. me .. label); r.left:SetTextColor(1, 1, 1)
            r.right:SetText(string.format("%d%%  %s", e.pct, ShortNum(e.val))); r.right:SetTextColor(1, 1, 1)
            r:Show()
        else
            r:Hide()
        end
    end
    for i = shown + 1, #rows do rows[i]:Hide() end

    if DB().warn and haveMob and not myTanking and myPct >= 90 then
        flash:Show()
        if DB().sound and not frame._warned then WarnSound(); frame._warned = true end
    else
        flash:Hide(); frame._warned = false
    end
end
_G.GaarThreat_Redraw = Redraw

local acc = 0
frame:SetScript("OnUpdate", function(_, e)
    if flash:IsShown() then
        flashT = flashT + e * 4
        flash:SetAlpha(0.15 + 0.15 * math.abs(math.sin(flashT)))
    end
    acc = acc + e
    if acc >= 0.25 then acc = 0; Redraw() end
end)

local grip = CreateFrame("Button", nil, frame)
grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -2, 2)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing(); SavePos(); Redraw() end)

local function Toggle()
    if frame:IsShown() then frame:Hide(); DB().shown = false
    else frame:Show(); DB().shown = true; Redraw() end
end
_G.GaarThreat_Toggle = Toggle
_G.GaarThreat_IsShown = function() return frame:IsShown() end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
                     "PLAYER_TARGET_CHANGED", "UNIT_THREAT_LIST_UPDATE" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        if DB().shown then frame:Show(); Redraw() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if DB().showInInstance and IsInInstance() then DB().shown = true; frame:Show(); Redraw() end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if DB().autoShow and not frame:IsShown() then frame:Show(); DB().shown = true; Redraw() end
    else
        if frame:IsShown() then Redraw() end
    end
end)

-- ---------------------------------------------------------------------------
-- Options — the same builder feeds the Gaar options entry and the right-click panel
-- ---------------------------------------------------------------------------
local uid = 0
local function MakeCheck(parent, label, y, get, set)
    uid = uid + 1
    local name = "GaarThreatCheck" .. uid
    local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24); c:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    c:SetChecked(get() and true or false)
    local fs = _G[name .. "Text"]
    fs:SetText(label); fs:SetFontObject(GameFontHighlight)
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    c.gaarRefresh = function() c:SetChecked(get() and true or false) end
    return c
end

function GaarThreat_BuildOptions(container)
    local refreshers = {}
    local y = -8

    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("Threat meter")
    y = y - 28

    local toggle = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    toggle:SetSize(170, 24); toggle:SetPoint("TOPLEFT", 16, y)
    local function label() return frame:IsShown() and "Hide the meter" or "Show the meter" end
    toggle:SetText(label())
    toggle:SetScript("OnClick", function(self) Toggle(); self:SetText(label()) end)
    refreshers[#refreshers + 1] = function() toggle:SetText(label()) end
    y = y - 34

    local function check(lbl, get, set)
        local c = MakeCheck(container, lbl, y, get, set)
        refreshers[#refreshers + 1] = c.gaarRefresh
        y = y - 26
    end

    check("Show when combat starts", function() return DB().autoShow end, function(v) DB().autoShow = v end)
    check("Show on entering an instance", function() return DB().showInInstance end, function(v) DB().showInInstance = v end)
    check("Pull warning (flash)", function() return DB().warn end, function(v) DB().warn = v end)
    check("Warning sound", function() return DB().sound end, function(v) DB().sound = v end)
    check("Scale threat down (1 damage = 1 threat)", function() return DB().downscale end, function(v) DB().downscale = v end)
    check("Show pets as their own rows", function() return DB().showPets end, function(v) DB().showPets = v end)
    y = y - 12

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(340); hint:SetJustifyH("LEFT")
    hint:SetText("Drag the window to move it, corner grip to resize, right-click it for these options. The raw threat this client reports is 100x, which the scaling option divides back out.")
    y = y - 52

    container.gaarRefresh = function() for _, fn in ipairs(refreshers) do fn() end end
    return -y
end

local panel
local function BuildPanel()
    if panel then return panel end
    panel = CreateFrame("Frame", "GaarThreatPanel", UIParent, "BackdropTemplate")
    panel:SetSize(392, 320); panel:SetPoint("CENTER")
    panel:SetBackdrop({
        bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true); panel:EnableMouse(true)
    panel:SetScript("OnMouseDown", function(self) self:StartMoving() end)
    panel:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)
    table.insert(UISpecialFrames, "GaarThreatPanel")

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16); title:SetText(ADDON)
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -8, -8)

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", 8, -40); body:SetPoint("BOTTOMRIGHT", -8, 12)
    local used = GaarThreat_BuildOptions(body)
    panel:SetHeight(used + 60)
    panel:SetScript("OnShow", function() if body.gaarRefresh then body.gaarRefresh() end end)

    panel:Hide()
    return panel
end

local function OpenOptions()
    if _G.GaarOptions_Open and _G.GaarOptions_Open("threat") then return end
    local p = BuildPanel()
    if p:IsShown() then p:Hide() else p:Show() end
end
_G.GaarThreat_Config = OpenOptions

frame:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then OpenOptions() end
end)

SLASH_GAARTHREAT1 = "/gaarthreat"
SLASH_GAARTHREAT2 = "/gthreat"
SlashCmdList["GAARTHREAT"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "config" or msg == "options" then OpenOptions() else Toggle() end
end
