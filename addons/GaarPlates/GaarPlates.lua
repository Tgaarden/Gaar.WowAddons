--[[
  Gaar Plates — cleaner nameplates, rebuilt from Deepward Plates (WotLK 3.3.5a) for
  WoW Classic Era.

  This is a rewrite rather than a port. The Deepward version existed to work around 3.3.5a
  having no nameplate unit API: it scraped WorldFrame's children, guessed the default plate's
  region order, blanked those textures and read health/cast values back out of the hidden
  widgets. Classic Era has the modern nameplate API (C_NamePlate, NAME_PLATE_UNIT_ADDED), so
  every plate comes with a real unit token. That means the values are read straight from the
  unit, and the three things the original called impossible - per-plate threat, per-plate
  auras and per-plate target-of-target - work on every plate here, not just your target.

  Features:
    * Flat health bar with dark backdrop and a 1px border.
    * Colour by reaction, by class (players), by health percent, or solid; execute tint low.
    * Name above the bar, level off the bar's right edge, health text (off / percent / current),
      then the unit's target, then its debuffs.
    * Cast bar with spell icon and name, its own backdrop and border.
    * Per-plate threat colouring (purple = you hold aggro, amber = high) and threat percent.
    * Your own debuffs on the plate, with stacks and a countdown.
    * Target highlight and scale-up; non-target plates dimmed.

  /gaarplates for options (also under Gaar -> Plates in the AddOns options).
]]

local _G = _G
local BAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"
local WHITE = "Interface\\Buttons\\WHITE8x8"
local AURA_N, AURA_SZ = 8, 16

local function DB()
    if type(GaarPlatesDB) ~= "table" then GaarPlatesDB = {} end
    local d = GaarPlatesDB
    if d.enabled     == nil then d.enabled = true end
    if d.width       == nil then d.width = 120 end
    if d.height      == nil then d.height = 12 end
    if d.castHeight  == nil then d.castHeight = 9 end
    if d.colorMode   == nil then d.colorMode = "reaction" end   -- reaction | class | health | solid
    if d.solid       == nil then d.solid = { 0.2, 0.6, 1.0 } end
    if d.execute     == nil then d.execute = true end
    if d.executePct  == nil then d.executePct = 20 end
    if d.healthText  == nil then d.healthText = "percent" end   -- off | percent | current
    if d.nameSize    == nil then d.nameSize = 11 end
    if d.targetHi    == nil then d.targetHi = true end
    if d.targetBorder == nil then d.targetBorder = true end   -- ring around your target's bar
    if d.targetScale == nil then d.targetScale = 1.15 end
    if d.threat      == nil then d.threat = true end
    if d.threatText  == nil then d.threatText = true end
    if d.dimOthers   == nil then d.dimOthers = true end
    if d.dimAlpha    == nil then d.dimAlpha = 0.55 end
    if d.totText     == nil then d.totText = true end
    if d.auras       == nil then d.auras = true end
    if d.friendly    == nil then d.friendly = false end         -- style friendly plates too
    return d
end

local overlays = {}   -- [nameplate frame] = our overlay
local active = {}     -- [unit] = overlay

local function SetSolid(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
end

local function BorderFrame(parent, level, size)
    local bd = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bd:SetFrameLevel(level)
    bd:SetPoint("TOPLEFT", -1, 1); bd:SetPoint("BOTTOMRIGHT", 1, -1)
    bd:SetBackdrop({ edgeFile = WHITE, edgeSize = size or 1 })
    bd:SetBackdropBorderColor(0, 0, 0, 1)
    return bd
end

local function ApplySize(o)
    o.health:SetSize(DB().width, DB().height)
    o.cast:SetSize(DB().width, DB().castHeight)
    o.cast.icon:SetSize(DB().castHeight + 8, DB().castHeight + 8)
    o.auraRow:SetSize(DB().width, AURA_SZ)
end

local function SetFonts(o)
    local ns = DB().nameSize
    local hs = math.max(8, DB().height - 2)
    o.name:SetFont(STANDARD_TEXT_FONT, ns, "OUTLINE")
    o.level:SetFont(STANDARD_TEXT_FONT, ns - 2, "OUTLINE")
    o.htext:SetFont(STANDARD_TEXT_FONT, hs, "OUTLINE")
    o.ttext:SetFont(STANDARD_TEXT_FONT, hs, "OUTLINE")
    local ts = math.max(7, ns - 3)
    o.tot:SetFont(STANDARD_TEXT_FONT, ts, "OUTLINE")
    -- The aura row hangs off this line, so it is given a fixed height. Left to size itself it
    -- would collapse to nothing whenever the unit has no target, and the icons would jump.
    o.tot:SetHeight(ts + 2)
    o.cast.text:SetFont(STANDARD_TEXT_FONT, math.max(8, DB().castHeight), "OUTLINE")
end

-- Blizzard's own plate art. Hidden rather than restyled, and re-hidden on show because the
-- nameplate driver puts it back when a plate is recycled onto a new unit.
local function HideDefault(plate)
    local uf = plate.UnitFrame
    if not uf then return end
    if not uf._gaarHidden then
        uf._gaarHidden = true
        uf:HookScript("OnShow", function(self) if DB().enabled then self:Hide() end end)
    end
    if DB().enabled then uf:Hide() end
end

local function BuildOverlay(plate)
    if overlays[plate] then return overlays[plate] end

    local o = { plate = plate }

    local f = CreateFrame("Frame", nil, plate)
    f:SetAllPoints(plate)
    f:SetFrameLevel((plate:GetFrameLevel() or 0) + 2)
    o.frame = f

    local h = CreateFrame("StatusBar", nil, f)
    h:SetStatusBarTexture(BAR_TEX)
    h:SetPoint("CENTER", f, "CENTER", 0, 0)
    o.health = h
    local bg = h:CreateTexture(nil, "BACKGROUND"); SetSolid(bg, 0, 0, 0, 0.85)
    bg:SetPoint("TOPLEFT", -1, 1); bg:SetPoint("BOTTOMRIGHT", 1, -1)
    o.hbd = BorderFrame(h, h:GetFrameLevel(), 1)

    local hi = CreateFrame("Frame", nil, h, "BackdropTemplate")
    hi:SetFrameLevel(h:GetFrameLevel() + 2)
    hi:SetPoint("TOPLEFT", -1, 1); hi:SetPoint("BOTTOMRIGHT", 1, -1)
    hi:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 }); hi:Hide()
    o.hi = hi

    o.name  = h:CreateFontString(nil, "OVERLAY"); o.name:SetPoint("BOTTOM", h, "TOP", 0, 2)
    -- Level sits outside the bar's right edge rather than on the name row: a long mob name
    -- runs the full width of the plate and the two ran into each other there.
    o.level = h:CreateFontString(nil, "OVERLAY"); o.level:SetPoint("LEFT", h, "RIGHT", 3, 0)
    o.htext = h:CreateFontString(nil, "OVERLAY"); o.htext:SetPoint("CENTER", h, "CENTER", 0, 0)
    o.ttext = h:CreateFontString(nil, "OVERLAY"); o.ttext:SetPoint("RIGHT", h, "RIGHT", -2, 0)

    -- cast bar sits over the name row, same as the original
    local c = CreateFrame("StatusBar", nil, f); c:SetStatusBarTexture(BAR_TEX)
    c:SetPoint("CENTER", o.name, "CENTER", 0, 0)
    c:SetFrameLevel(h:GetFrameLevel() + 4)
    local cbg = c:CreateTexture(nil, "BACKGROUND"); SetSolid(cbg, 0, 0, 0, 0.85)
    cbg:SetPoint("TOPLEFT", -1, 1); cbg:SetPoint("BOTTOMRIGHT", 1, -1)
    BorderFrame(c, c:GetFrameLevel(), 1)
    local ci = c:CreateTexture(nil, "OVERLAY"); ci:SetPoint("RIGHT", c, "LEFT", -2, 0)
    ci:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    c.icon = ci
    c.text = c:CreateFontString(nil, "OVERLAY")
    c.text:SetPoint("LEFT", c, "LEFT", 3, 0); c.text:SetJustifyH("LEFT")
    c:Hide()
    o.cast = c

    o.auraRow = CreateFrame("Frame", nil, f)
    o.auraIcons = {}
    for i = 1, AURA_N do
        local ic = CreateFrame("Frame", nil, o.auraRow)
        ic:SetSize(AURA_SZ, AURA_SZ)
        local t = ic:CreateTexture(nil, "ARTWORK"); t:SetAllPoints(); t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic.tex = t
        local cnt = ic:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        cnt:SetPoint("BOTTOMRIGHT", 1, 0); ic.cnt = cnt
        local tm = ic:CreateFontString(nil, "OVERLAY")
        tm:SetPoint("CENTER", ic, "CENTER", 0, 0)
        tm:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE"); ic.timer = tm
        BorderFrame(ic, ic:GetFrameLevel(), 1)
        ic:Hide()
        o.auraIcons[i] = ic
    end

    -- Target first, then the auras under it. The target line belongs with the bar it describes,
    -- and the icons read better as a block at the bottom than wedged between the two.
    o.tot = h:CreateFontString(nil, "OVERLAY"); o.tot:SetPoint("TOP", h, "BOTTOM", 0, -1)
    o.auraRow:SetPoint("TOP", o.tot, "BOTTOM", 0, -2)

    ApplySize(o); SetFonts(o)
    overlays[plate] = o
    return o
end

-- Retail can answer with a "secret value" for a unit's health or power: it may be shown, and
-- handed back to Blizzard's own widgets, but arithmetic on one is blocked and logged as taint.
-- That is what "an attempt to perform arithmetic on a secret value" in taint.log means, and it
-- fires on every update, so it has to be checked before the maths rather than caught after.
-- issecretvalue does not exist on Era, where nothing is secret, so the guard costs nothing.
local issecretvalue = _G.issecretvalue
local function Secret(a, b)
    if not issecretvalue then return false end
    if issecretvalue(a) then return true end
    return b ~= nil and issecretvalue(b) or false
end

local function BarColor(o, unit)
    local mode = DB().colorMode
    if mode == "solid" then return DB().solid[1], DB().solid[2], DB().solid[3] end
    if mode == "class" and UnitIsPlayer(unit) then
        local _, cls = UnitClass(unit)
        local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        if c then return c.r, c.g, c.b end
    end
    if mode == "health" then
        local cur, mx = UnitHealth(unit), UnitHealthMax(unit)
        -- No percentage means no health gradient; fall through to the reaction colour rather
        -- than colouring every hidden unit as though it were at full health.
        if not Secret(cur, mx) then
            mx = mx or 1
            local p = (mx > 0) and ((cur or 0) / mx) or 1
            return (1 - p), p, 0
        end
    end
    -- reaction
    if UnitIsPlayer(unit) then
        if UnitIsFriend("player", unit) then return 0.25, 0.5, 0.9 else return 0.85, 0.2, 0.2 end
    end
    local r = UnitReaction(unit, "player") or 4
    if r <= 3 then return 0.8, 0.2, 0.2
    elseif r == 4 then return 0.9, 0.8, 0.2
    else return 0.2, 0.7, 0.25 end
end

-- Auras: the player's own harmful auras on this unit. "PLAYER|HARMFUL" keeps the scan to ours.
local function UpdateAuras(o, unit)
    local shown = 0
    if DB().auras then
        for i = 1, 40 do
            local name, icon, count, _, duration, expiration
            if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
                local a = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL|PLAYER")
                if not a then break end
                name, icon, count, duration, expiration = a.name, a.icon, a.applications, a.duration, a.expirationTime
            else
                name, icon, count, _, duration, expiration = UnitAura(unit, i, "HARMFUL|PLAYER")
                if not name then break end
            end
            if shown < AURA_N then
                shown = shown + 1
                local ic = o.auraIcons[shown]
                if ic._icon ~= icon then ic.tex:SetTexture(icon); ic._icon = icon end
                local cn = (count and count > 1) and count or 0
                if ic._cnt ~= cn then ic.cnt:SetText(cn > 0 and cn or ""); ic._cnt = cn end
                if duration and duration > 0 and expiration then
                    local rem = expiration - GetTime()
                    if rem > 0 then
                        if rem >= 60 then ic.timer:SetText(math.floor(rem / 60 + 0.5) .. "m")
                        else ic.timer:SetText(string.format("%d", rem + 0.5)) end
                        if rem <= 3 then ic.timer:SetTextColor(1, 0.2, 0.2)
                        elseif rem <= 8 then ic.timer:SetTextColor(1, 0.9, 0.2)
                        else ic.timer:SetTextColor(1, 1, 1) end
                    else ic.timer:SetText("") end
                else
                    ic.timer:SetText("")
                end
                if not ic:IsShown() then ic:Show() end
            end
        end
    end
    for i = shown + 1, AURA_N do
        if o.auraIcons[i]:IsShown() then o.auraIcons[i]:Hide() end
    end
    if shown ~= o._lastShown then
        o._lastShown = shown
        local step = AURA_SZ + 2
        local startX = -((shown * step - 2) / 2) + AURA_SZ / 2
        for i = 1, shown do
            o.auraIcons[i]:ClearAllPoints()
            o.auraIcons[i]:SetPoint("CENTER", o.auraRow, "CENTER", startX + (i - 1) * step, 0)
        end
    end
end

-- Same return-shape guard as Gaar Cast: this client dropped the old nameSubtext return, so
-- texture and the timestamps sit one slot earlier than they did on 3.3.5a.
local function ReadCast(unit, channel)
    local r
    if channel then r = { UnitChannelInfo(unit) } else r = { UnitCastingInfo(unit) } end
    if not r[1] then return nil end
    if type(r[4]) == "number" and type(r[5]) == "number" then
        return r[1], r[3], r[4], r[5]      -- name, texture, startMs, endMs
    end
    return r[1], r[4], r[5], r[6]
end

local function UpdateCast(o, unit)
    local name, icon, startMs, endMs, channel
    name, icon, startMs, endMs = ReadCast(unit, false)
    if name then
        channel = false
    else
        name, icon, startMs, endMs = ReadCast(unit, true)
        channel = true
    end
    if not name or not startMs or not endMs then o.cast:Hide(); return end
    local now = GetTime() * 1000
    local dur = endMs - startMs
    if dur <= 0 then o.cast:Hide(); return end
    local frac = (now - startMs) / dur
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    if channel then frac = 1 - frac end
    o.cast:SetMinMaxValues(0, 1); o.cast:SetValue(frac)
    o.cast.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    o.cast.text:SetText(name)
    o.cast:SetStatusBarColor(channel and 0.2 or 1.0, channel and 0.75 or 0.7, channel and 0.3 or 0.0)
    o.cast:Show()
end

local function UpdatePlate(o, unit)
    if not UnitExists(unit) then return end

    local mx = UnitHealthMax(unit)
    local cur = UnitHealth(unit)
    -- The bar itself still takes the raw values - passing them straight back to a widget is
    -- allowed. Only the percentage this file works out from them is off limits.
    local hidden = Secret(cur, mx)
    local pct = 1
    if not hidden then
        mx = mx or 1; cur = cur or 0
        pct = (mx > 0) and (cur / mx) or 1
    end
    o.health:SetMinMaxValues(0, (not hidden and mx and mx > 0) and mx or 1)
    o.health:SetValue(cur)

    local isTarget = UnitIsUnit(unit, "target")

    local br, bg, bb = BarColor(o, unit)
    if not hidden and DB().execute and pct * 100 <= DB().executePct then br, bg, bb = 0.5, 0.22, 0.22 end

    -- Per-plate threat: with a real unit token this works on every plate, not just the target.
    local aggro
    o.ttext:SetText("")
    if DB().threat and UnitCanAttack("player", unit) then
        local tanking, status, pctThreat = UnitDetailedThreatSituation("player", unit)
        if tanking then br, bg, bb = 0.55, 0.38, 0.68; aggro = true         -- you hold aggro
        elseif status and status >= 2 then br, bg, bb = 0.8, 0.6, 0.35 end  -- high threat
        if DB().threatText and pctThreat and not Secret(pctThreat) then
            o.ttext:SetText(string.format("%d%%", pctThreat + 0.5))
        end
    end

    -- pull the colour toward its own luminance so nothing reads as harsh pure red/purple
    local lum = 0.3 * br + 0.59 * bg + 0.11 * bb
    local m = 0.28
    o.health:SetStatusBarColor(br + (lum - br) * m, bg + (lum - bg) * m, bb + (lum - bb) * m)

    o.name:SetText(UnitName(unit) or "")
    if DB().colorMode == "class" and UnitIsPlayer(unit) then
        local _, cls = UnitClass(unit)
        local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        if c then o.name:SetTextColor(c.r, c.g, c.b) else o.name:SetTextColor(1, 1, 1) end
    else
        o.name:SetTextColor(1, 1, 1)
    end
    local lvl = UnitLevel(unit)
    o.level:SetText((lvl and lvl > 0) and tostring(lvl) or "??")

    local mode = DB().healthText
    if mode == "off" or hidden or cur <= 0 then o.htext:SetText("")
    elseif mode == "current" then
        o.htext:SetText(AbbreviateLargeNumbers and AbbreviateLargeNumbers(cur) or tostring(cur))
    else o.htext:SetText(math.floor(pct * 100 + 0.5) .. "%") end
    if cur <= 0 then o.ttext:SetText("") end

    if DB().totText and UnitExists(unit .. "target") then
        o.tot:SetText("-> " .. (UnitName(unit .. "target") or ""))
    else
        o.tot:SetText("")
    end

    UpdateCast(o, unit)
    UpdateAuras(o, unit)

    -- The aggro ring stays bold, since that one is a warning. The target ring is only a
    -- "this is the one you're on" hint, and the scale-up already says that, so it is dim.
    if aggro then
        o.hi:SetBackdropBorderColor(0.55, 0.38, 0.68, 1); o.hi:Show()
    elseif DB().targetBorder and isTarget then
        o.hi:SetBackdropBorderColor(0.7, 0.7, 0.75, 0.35); o.hi:Show()
    else
        o.hi:Hide()
    end
    o.frame:SetScale((DB().targetHi and isTarget) and DB().targetScale or 1)

    if DB().dimOthers then
        o.frame:SetAlpha((not UnitExists("target") or isTarget) and 1 or DB().dimAlpha)
    else
        o.frame:SetAlpha(1)
    end
end

-- ---------------------------------------------------------------------------
-- Plate lifecycle
-- ---------------------------------------------------------------------------
local function AddPlate(unit)
    if not unit or unit == "player" then return end
    if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return end
    if not DB().friendly and not UnitCanAttack("player", unit) then
        -- leave friendly plates to Blizzard
        local o = overlays[plate]
        if o then o.frame:Hide() end
        return
    end
    HideDefault(plate)
    local o = BuildOverlay(plate)
    o.unit = unit
    o.frame:Show()
    active[unit] = o
    UpdatePlate(o, unit)
end

local function RemovePlate(unit)
    local o = active[unit]
    if o then
        o.unit = nil
        o.frame:Hide()
        active[unit] = nil
    end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
                     "PLAYER_TARGET_CHANGED", "PLAYER_ENTERING_WORLD" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, unit)
    if not DB().enabled then return end
    if event == "NAME_PLATE_UNIT_ADDED" then AddPlate(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then RemovePlate(unit)
    elseif event == "PLAYER_ENTERING_WORLD" then
        if C_NamePlate and C_NamePlate.GetNamePlates then
            for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
                local u = plate.namePlateUnitToken
                if u then AddPlate(u) end
            end
        end
    end
end)

local driver = CreateFrame("Frame")
local acc = 0
driver:SetScript("OnUpdate", function(_, e)
    if not DB().enabled then return end
    acc = acc + e
    if acc < 0.08 then return end
    acc = 0
    for unit, o in pairs(active) do
        if UnitExists(unit) then UpdatePlate(o, unit) else RemovePlate(unit) end
    end
end)

local function RefreshAll()
    for _, o in pairs(overlays) do ApplySize(o); SetFonts(o) end
end

local function SetEnabled(v)
    DB().enabled = v
    for _, o in pairs(overlays) do
        if v then
            if o.unit then o.frame:Show() end
            HideDefault(o.plate)
        else
            o.frame:Hide()
            local uf = o.plate.UnitFrame
            if uf then uf:Show() end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Options — same builder feeds the Gaar options entry and the standalone panel
-- ---------------------------------------------------------------------------
local uid = 0
local function MakeCheck(parent, label, y, get, set)
    uid = uid + 1
    local name = "GaarPlatesCheck" .. uid
    local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24); c:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    c:SetChecked(get() and true or false)
    local fs = _G[name .. "Text"]
    fs:SetText(label); fs:SetFontObject(GameFontHighlight)
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    c.gaarRefresh = function() c:SetChecked(get() and true or false) end
    return c
end

local function Choices(container, y, label, values, set)
    local fs = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 18, y); fs:SetText(label)
    local x = 150
    for _, v in ipairs(values) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(66, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(v[1])
        b:SetScript("OnClick", function() set(v[2]) end)
        x = x + 68
    end
    return y - 28
end

function GaarPlates_BuildOptions(container)
    local refreshers = {}
    local y = -8

    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("Nameplates")
    y = y - 26

    local function check(lbl, get, set)
        local c = MakeCheck(container, lbl, y, get, set)
        refreshers[#refreshers + 1] = c.gaarRefresh
        y = y - 26
    end

    check("Enabled", function() return DB().enabled end, function(v) SetEnabled(v) end)
    check("Execute tint at low health", function() return DB().execute end, function(v) DB().execute = v end)
    check("Scale up your target's plate", function() return DB().targetHi end, function(v) DB().targetHi = v end)
    check("Ring around your target's bar", function() return DB().targetBorder end, function(v) DB().targetBorder = v end)
    check("Threat colouring", function() return DB().threat end, function(v) DB().threat = v end)
    check("Threat percent text", function() return DB().threatText end, function(v) DB().threatText = v end)
    check("Target-of-target name", function() return DB().totText end, function(v) DB().totText = v end)
    check("My debuffs on the plate", function() return DB().auras end, function(v) DB().auras = v end)
    check("Dim non-target plates", function() return DB().dimOthers end, function(v) DB().dimOthers = v end)
    check("Style friendly plates too", function() return DB().friendly end, function(v) DB().friendly = v end)
    y = y - 10

    y = Choices(container, y, "Colour by:", {
        { "Reaction", "reaction" }, { "Class", "class" }, { "Health", "health" }, { "Solid", "solid" },
    }, function(v) DB().colorMode = v end)

    y = Choices(container, y, "Health text:", {
        { "Off", "off" }, { "Percent", "percent" }, { "Current", "current" },
    }, function(v) DB().healthText = v end)

    y = Choices(container, y, "Bar width:", {
        { "100", 100 }, { "120", 120 }, { "140", 140 },
    }, function(v) DB().width = v; RefreshAll() end)

    y = Choices(container, y, "Bar height:", {
        { "10", 10 }, { "12", 12 }, { "16", 16 },
    }, function(v) DB().height = v; RefreshAll() end)

    y = Choices(container, y, "Name size:", {
        { "10", 10 }, { "11", 11 }, { "13", 13 },
    }, function(v) DB().nameSize = v; RefreshAll() end)

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(340); hint:SetJustifyH("LEFT")
    hint:SetText("Threat, debuffs and target-of-target work on every plate here - Classic Era gives each nameplate a real unit, which the WotLK original had to do without.")
    y = y - 50

    container.gaarRefresh = function() for _, fn in ipairs(refreshers) do fn() end end
    return -y
end

local panel
local function BuildPanel()
    if panel then return panel end
    panel = CreateFrame("Frame", "GaarPlatesPanel", UIParent, "BackdropTemplate")
    panel:SetSize(420, 560); panel:SetPoint("CENTER")
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
    table.insert(UISpecialFrames, "GaarPlatesPanel")

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16); title:SetText("Gaar Plates")
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -8, -8)

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", 8, -40); body:SetPoint("BOTTOMRIGHT", -8, 12)
    local used = GaarPlates_BuildOptions(body)
    panel:SetHeight(used + 60)
    panel:SetScript("OnShow", function() if body.gaarRefresh then body.gaarRefresh() end end)

    panel:Hide()
    return panel
end

local function OpenOptions()
    if _G.GaarOptions_Open and _G.GaarOptions_Open("plates") then return end
    local p = BuildPanel()
    if p:IsShown() then p:Hide() else p:Show() end
end
_G.GaarPlates_Config = OpenOptions

SLASH_GAARPLATES1 = "/gaarplates"
SLASH_GAARPLATES2 = "/gplates"
SlashCmdList["GAARPLATES"] = function() OpenOptions() end
