--[[
  Gaar Meter — compact combat meter, ported from Deepward Meter (WotLK 3.3.5a) to
  WoW Classic Era. Everything is derived from the combat log; no server data.

  Features
    * Modes: Damage (DPS), Healing (HPS, effective), Damage taken, Interrupts, Dispels, Deaths.
    * Segments: current fight, Overall, and a history of the last fights.
    * Click a bar for that actor's per-spell breakdown, each row with the spell's own icon,
      its share, hit count and crit rate; "< Back" returns.
    * Hovering an actor lists their top ten spells with icons; hovering a spell row gives that
      spell's total, per-second, hits, crits, misses, average and biggest hit.
    * Header: segment picker left, group total in the middle, mode picker right. Right-click
      the window for reset/report.
    * Movable, resizable; position, size and mode persist.

  /gaarmeter (toggle) · reset · report · mode · config

  Classic Era port notes vs the WotLK original:
   * The combat log no longer passes its payload to the event handler - it is fetched with
     CombatLogGetCurrentEventInfo() - and the layout gained hideCaster plus the two raid-flag
     fields, so every argument sits three slots later than on 3.3.5a. Reading it with the old
     offsets is the classic way to silently record garbage, so the parser below is written for
     the modern layout and falls back to the old one only if that function is missing.
   * GetNumRaidMembers/GetNumPartyMembers are gone: IsInRaid, GetNumGroupMembers and
     GetNumSubgroupMembers replace them.
   * No EasyMenu on this client, so the pickers use a small dropdown built here.
   * SetBackdrop needs "BackdropTemplate"; solid textures need SetColorTexture;
     SetMinResize/SetMaxResize became SetResizeBounds.
]]

local _G = _G
local ADDON = "Gaar Meter"

local MODES = {
    { key = "damage",     label = "Damage done",  short = "DPS",   perSec = true },
    { key = "healing",    label = "Healing done", short = "HPS",   perSec = true },
    { key = "taken",      label = "Damage taken", short = "DTPS",  perSec = true },
    { key = "interrupts", label = "Interrupts",   short = "Int",   perSec = false },
    { key = "dispels",    label = "Dispels",      short = "Disp",  perSec = false },
    { key = "deaths",     label = "Deaths",       short = "Death", perSec = false },
}
local MODE_BY_KEY = {}
for _, m in ipairs(MODES) do MODE_BY_KEY[m.key] = m end

local function DB()
    if type(GaarMeterDB) ~= "table" then GaarMeterDB = {} end
    local d = GaarMeterDB
    if d.mode == nil then d.mode = "damage" end
    if d.width == nil then d.width = 240 end
    if d.height == nil then d.height = 190 end
    if d.reportChannel == nil then d.reportChannel = "PARTY" end
    if d.shown == nil then d.shown = false end
    if d.showInInstance == nil then d.showInInstance = true end
    return d
end

local function SetSolid(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
end

-- ---------------------------------------------------------------------------
-- Data model
-- ---------------------------------------------------------------------------
local MAX_FIGHTS = 20
local overall = { name = "Overall", start = GetTime(), actors = {} }
local fights = {}
local cur = nil
local wasInside = nil

local function NewSeg(name) return { name = name, start = GetTime(), actors = {} } end

local function NewActor(name)
    return { name = name, class = nil,
             amount = { damage = 0, healing = 0, taken = 0, interrupts = 0, dispels = 0, deaths = 0 },
             spells = { damage = {}, healing = {}, taken = {}, interrupts = {}, dispels = {} } }
end

local function GetActor(seg, name)
    local a = seg.actors[name]
    if not a then a = NewActor(name); seg.actors[name] = a end
    return a
end

local classByName = {}
local function RefreshClassCache()
    local pn = UnitName("player"); local _, pc = UnitClass("player")
    if pn then classByName[pn] = pc end
    if IsInRaid and IsInRaid() then
        local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
        for i = 1, n do
            local nm = UnitName("raid" .. i); local _, cl = UnitClass("raid" .. i)
            if nm then classByName[nm] = cl end
        end
    else
        local n = (GetNumSubgroupMembers and GetNumSubgroupMembers()) or 0
        for i = 1, n do
            local nm = UnitName("party" .. i); local _, cl = UnitClass("party" .. i)
            if nm then classByName[nm] = cl end
        end
    end
end

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 0.4, 0.55, 0.85
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------
local AFF_GROUP = 0x7   -- MINE | PARTY | RAID

-- Spell icons: the combat log gives a spell id, and the lookup for it moved into C_Spell on
-- this client, with the old global kept as a fallback.
local iconCache = {}
local function SpellIcon(spellID)
    if not spellID then return nil end
    local cached = iconCache[spellID]
    if cached ~= nil then return cached or nil end
    local tex
    if C_Spell and C_Spell.GetSpellTexture then tex = C_Spell.GetSpellTexture(spellID)
    elseif GetSpellTexture then tex = GetSpellTexture(spellID) end
    iconCache[spellID] = tex or false
    return tex
end

local function SpellRecord(a, mode, spell)
    local t = a.spells[mode]
    if not t then return nil end
    local s = t[spell]
    if not s then
        s = { amt = 0, hits = 0, crits = 0, misses = 0, max = 0 }
        t[spell] = s
    end
    return s
end

local function AddToSeg(seg, name, mode, spell, amount, icon, crit)
    local a = GetActor(seg, name)
    if not a.class then a.class = classByName[name] end
    a.amount[mode] = (a.amount[mode] or 0) + amount
    if mode == "damage" or mode == "healing" then
        a.hits = (a.hits or 0) + 1
        if crit then a.crits = (a.crits or 0) + 1 end
    end
    if spell then
        local s = SpellRecord(a, mode, spell)
        if s then
            s.amt = s.amt + amount
            s.hits = s.hits + 1
            if crit then s.crits = s.crits + 1 end
            if amount > s.max then s.max = amount end
            if icon and not s.icon then s.icon = icon end
        end
    end
end

local function Record(name, mode, spell, amount, icon, crit)
    if not name or not amount or amount <= 0 then return end
    if not cur then cur = NewSeg("Current fight") end
    AddToSeg(cur, name, mode, spell, amount, icon, crit)
    AddToSeg(overall, name, mode, spell, amount, icon, crit)
end

-- Misses carry no amount, so they are counted straight onto the spell record.
local function RecordMiss(name, mode, spell, icon)
    if not name or not spell then return end
    if not cur then cur = NewSeg("Current fight") end
    for _, seg in ipairs({ cur, overall }) do
        local a = GetActor(seg, name)
        if not a.class then a.class = classByName[name] end
        local s = SpellRecord(a, mode, spell)
        if s then
            s.misses = s.misses + 1
            if icon and not s.icon then s.icon = icon end
        end
    end
end

local function InGroup(flags) return bit.band(flags or 0, AFF_GROUP) ~= 0 end

local MELEE = "Melee"

-- Modern layout: timestamp, subevent, hideCaster, srcGUID, srcName, srcFlags, srcRaidFlags,
-- dstGUID, dstName, dstFlags, dstRaidFlags, then the per-subevent payload from index 12.
local function Parse(...)
    local sub      = select(2, ...)
    local srcName  = select(5, ...)
    local srcFlags = select(6, ...)
    local dstName  = select(9, ...)
    local dstFlags = select(10, ...)

    if sub == "SWING_DAMAGE" then
        -- amount, overkill, school, resisted, blocked, absorbed, critical
        local amount = select(12, ...)
        local crit   = select(18, ...)
        if InGroup(srcFlags) then Record(srcName, "damage", MELEE, amount, nil, crit) end
        if InGroup(dstFlags) then Record(dstName, "taken", MELEE, amount, nil, crit) end

    elseif sub == "SPELL_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" or sub == "RANGE_DAMAGE"
        or sub == "DAMAGE_SHIELD" or sub == "DAMAGE_SPLIT" then
        -- spellId, spellName, school, amount, overkill, school, resisted, blocked, absorbed, critical
        local spellID = select(12, ...)
        local spell   = select(13, ...)
        local amount  = select(15, ...)
        local crit    = select(21, ...)
        local icon = SpellIcon(spellID)
        if InGroup(srcFlags) then Record(srcName, "damage", spell, amount, icon, crit) end
        if InGroup(dstFlags) then Record(dstName, "taken", spell, amount, icon, crit) end

    elseif sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
        -- spellId, spellName, school, amount, overhealing, absorbed, critical
        local spellID  = select(12, ...)
        local spell    = select(13, ...)
        local amount   = select(15, ...)
        local overheal = select(16, ...) or 0
        local crit     = select(18, ...)
        local eff = (amount or 0) - overheal          -- effective healing
        if eff > 0 and InGroup(srcFlags) then
            Record(srcName, "healing", spell, eff, SpellIcon(spellID), crit)
        end

    elseif sub == "SPELL_MISSED" or sub == "RANGE_MISSED" then
        local spellID = select(12, ...)
        local spell   = select(13, ...)
        if InGroup(srcFlags) then RecordMiss(srcName, "damage", spell, SpellIcon(spellID)) end

    elseif sub == "SWING_MISSED" then
        if InGroup(srcFlags) then RecordMiss(srcName, "damage", MELEE, nil) end

    elseif sub == "SPELL_INTERRUPT" then
        if InGroup(srcFlags) then
            Record(srcName, "interrupts", select(16, ...) or "Interrupt", 1, SpellIcon(select(12, ...)))
        end

    elseif sub == "SPELL_DISPEL" then
        if InGroup(srcFlags) then
            Record(srcName, "dispels", select(16, ...) or "Dispel", 1, SpellIcon(select(12, ...)))
        end

    elseif sub == "UNIT_DIED" then
        if InGroup(dstFlags) then Record(dstName, "deaths", nil, 1) end
    end
end

-- Pre-Cata layout, kept only as a fallback: no hideCaster and no raid-flag fields, so
-- everything sits three slots earlier.
local function ParseLegacy(...)
    local sub      = select(2, ...)
    local srcName  = select(4, ...)
    local srcFlags = select(5, ...)
    local dstName  = select(7, ...)
    local dstFlags = select(8, ...)

    if sub == "SWING_DAMAGE" then
        local amount = select(9, ...)
        if InGroup(srcFlags) then Record(srcName, "damage", MELEE, amount) end
        if InGroup(dstFlags) then Record(dstName, "taken", MELEE, amount) end
    elseif sub == "SPELL_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" or sub == "RANGE_DAMAGE"
        or sub == "DAMAGE_SHIELD" or sub == "DAMAGE_SPLIT" then
        local spell, amount = select(10, ...), select(12, ...)
        if InGroup(srcFlags) then Record(srcName, "damage", spell, amount) end
        if InGroup(dstFlags) then Record(dstName, "taken", spell, amount) end
    elseif sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
        local spell, amount, overheal = select(10, ...), select(12, ...), select(13, ...) or 0
        local eff = (amount or 0) - overheal
        if eff > 0 and InGroup(srcFlags) then Record(srcName, "healing", spell, eff) end
    elseif sub == "SPELL_INTERRUPT" then
        if InGroup(srcFlags) then Record(srcName, "interrupts", select(13, ...) or "Interrupt", 1) end
    elseif sub == "SPELL_DISPEL" then
        if InGroup(srcFlags) then Record(srcName, "dispels", select(13, ...) or "Dispel", 1) end
    elseif sub == "UNIT_DIED" then
        if InGroup(dstFlags) then Record(dstName, "deaths", nil, 1) end
    end
end

-- ---------------------------------------------------------------------------
-- Segment selection
-- ---------------------------------------------------------------------------
local viewSeg = "current"
local detailActor = nil

local function SelectedSeg()
    if viewSeg == "overall" then return overall end
    if viewSeg == "current" then return cur or fights[1] end
    return fights[viewSeg]
end

local function SegDuration(seg)
    if not seg or not seg.start then return 1 end
    local endt = seg.endt or GetTime()
    local d = endt - seg.start
    return d < 1 and 1 or d
end

local function SegName(seg)
    if not seg then return "-" end
    if seg == overall then return "Overall" end
    if seg == cur then return "Current" end
    return seg.name or "Fight"
end

-- ---------------------------------------------------------------------------
-- A small dropdown (this client has no EasyMenu)
-- ---------------------------------------------------------------------------
local dropdown
local function Dropdown()
    if dropdown then return dropdown end
    dropdown = CreateFrame("Frame", "GaarMeterDropdown", UIParent, "BackdropTemplate")
    dropdown:SetFrameStrata("FULLSCREEN_DIALOG")
    dropdown:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    dropdown:SetBackdropColor(0.05, 0.07, 0.12, 0.95)
    dropdown:SetBackdropBorderColor(0.35, 0.55, 0.9, 1)
    dropdown:EnableMouse(true)
    dropdown.buttons = {}
    dropdown:Hide()
    table.insert(UISpecialFrames, "GaarMeterDropdown")
    return dropdown
end

local function ShowMenu(items, anchor)
    local d = Dropdown()
    local w, y = 120, -8
    for i, it in ipairs(items) do
        local b = d.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, d)
            b:SetHeight(16)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 8, 0); b.text:SetJustifyH("LEFT")
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            d.buttons[i] = b
        end
        b:SetPoint("TOPLEFT", 4, y); b:SetPoint("TOPRIGHT", -4, y)
        local mark = it.checked and "|cff33ff99*|r " or (it.isTitle and "" or "  ")
        b.text:SetText((it.isTitle and "|cffffd100" or "") .. mark .. it.text .. (it.isTitle and "|r" or ""))
        w = math.max(w, b.text:GetStringWidth() + 24)
        if it.isTitle or not it.func then
            b:SetScript("OnClick", nil); b:EnableMouse(false)
        else
            b:EnableMouse(true)
            b:SetScript("OnClick", function() d:Hide(); it.func() end)
        end
        b:Show()
        y = y - 16
    end
    for i = #items + 1, #d.buttons do d.buttons[i]:Hide() end
    d:SetSize(w, -y + 8)

    d:ClearAllPoints()
    if anchor then
        d:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    else
        local x, cy = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        d:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, cy / s)
    end
    d:Show()
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
local Redraw
local frame = CreateFrame("Frame", "GaarMeterFrame", UIParent, "BackdropTemplate")
local db0 = DB()
frame:SetSize(db0.width, db0.height)
if db0.point then frame:SetPoint(db0.point, UIParent, db0.point, db0.x or 0, db0.y or 0)
else frame:SetPoint("CENTER", 300, 0) end
frame:SetMovable(true); frame:SetResizable(true); frame:EnableMouse(true)
frame:SetClampedToScreen(true)
if frame.SetResizeBounds then frame:SetResizeBounds(170, 90, 560, 760)
elseif frame.SetMinResize then frame:SetMinResize(170, 90); frame:SetMaxResize(560, 760) end
frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
frame:SetBackdropColor(0.05, 0.07, 0.12, 0.92)
frame:SetBackdropBorderColor(0.35, 0.55, 0.9, 1)
frame:Hide()
-- Deliberately NOT in UISpecialFrames: Escape shouldn't close the meter mid-fight.

local function SavePos()
    local d = DB()
    local p, _, _, x, y = frame:GetPoint()
    d.point, d.x, d.y = p, x, y
    d.width, d.height = math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5)
end

local header = CreateFrame("Button", nil, frame)
header:SetPoint("TOPLEFT", 4, -4); header:SetPoint("TOPRIGHT", -4, -4); header:SetHeight(18)
header:RegisterForDrag("LeftButton")
header:SetScript("OnDragStart", function() frame:StartMoving() end)
header:SetScript("OnDragStop", function() frame:StopMovingOrSizing(); SavePos() end)
header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
local htex = header:CreateTexture(nil, "BACKGROUND"); htex:SetAllPoints(); SetSolid(htex, 0.12, 0.16, 0.28, 0.9)

local segBtn = CreateFrame("Button", nil, header)
segBtn:SetPoint("LEFT", 2, 0); segBtn:SetHeight(16); segBtn:SetWidth(90)
segBtn.text = segBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
segBtn.text:SetPoint("LEFT", 2, 0); segBtn.text:SetJustifyH("LEFT"); segBtn.text:SetWidth(88)
segBtn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

local modeBtn = CreateFrame("Button", nil, header)
modeBtn:SetPoint("RIGHT", -2, 0); modeBtn:SetHeight(16); modeBtn:SetWidth(96)
modeBtn.text = modeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
modeBtn.text:SetPoint("RIGHT", -2, 0); modeBtn.text:SetJustifyH("RIGHT"); modeBtn.text:SetWidth(94)
modeBtn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

-- Group total for the selected mode, shown in the middle of the header.
local totalText = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
totalText:SetPoint("CENTER", header, "CENTER", 0, 0)

local ROW_H = 16
local rows = {}
local OnRowClick, OnRowEnter

local function AcquireRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, frame)
    r:SetHeight(ROW_H)
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    r.bar:SetPoint("TOPLEFT"); r.bar:SetPoint("BOTTOMLEFT"); r.bar:SetWidth(1)
    r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(); SetSolid(r.bg, 0, 0, 0, 0.35)
    r.icon = r:CreateTexture(nil, "OVERLAY"); r.icon:SetSize(14, 14); r.icon:SetPoint("LEFT", 2, 0)
    r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.left:SetPoint("LEFT", r.icon, "RIGHT", 3, 0); r.left:SetJustifyH("LEFT")
    r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.right:SetPoint("RIGHT", -3, 0); r.right:SetJustifyH("RIGHT")
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button) OnRowClick(self, button) end)
    r:SetScript("OnEnter", function(self) OnRowEnter(self) end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = r
    return r
end

local CLASS_ICON = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local function SetClassIcon(tex, class)
    local c = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if c then tex:SetTexture(CLASS_ICON); tex:SetTexCoord(c[1], c[2], c[3], c[4]); tex:Show()
    else tex:Hide() end
end

local function ShortNum(n)
    n = n or 0
    if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end

local function BuildList(seg, modeKey)
    local out, total = {}, 0
    if seg then
        for name, a in pairs(seg.actors) do
            local v = a.amount[modeKey] or 0
            if v > 0 then out[#out + 1] = { name = name, amount = v, class = a.class }; total = total + v end
        end
    end
    table.sort(out, function(a, b) return a.amount > b.amount end)
    return out, total
end

local function BuildSpells(seg, actorName, modeKey)
    local out, total = {}, 0
    local a = seg and seg.actors[actorName]
    local sp = a and a.spells[modeKey]
    if sp then
        for spell, s in pairs(sp) do
            out[#out + 1] = {
                spell = spell, amt = s.amt, hits = s.hits, crits = s.crits or 0,
                misses = s.misses or 0, max = s.max or 0, icon = s.icon,
                avg = (s.hits > 0) and (s.amt / s.hits) or 0,
            }
            total = total + s.amt
        end
    end
    table.sort(out, function(a, b) return a.amt > b.amt end)
    return out, total
end

-- An inline icon for tooltip lines; the trailing numbers crop the icon's own border.
local function IconText(icon)
    if not icon then return "" end
    return "|T" .. icon .. ":14:14:0:0:64:64:5:59:5:59|t "
end

local function VisibleRowCount()
    local h = frame:GetHeight() - 26
    return math.max(1, math.floor(h / ROW_H))
end

Redraw = function()
    if not frame:IsShown() then return end
    RefreshClassCache()
    local mode = MODE_BY_KEY[DB().mode] or MODES[1]
    local seg = SelectedSeg()
    local dur = SegDuration(seg)

    segBtn.text:SetText("|cffffd100" .. SegName(seg) .. "|r v")
    modeBtn.text:SetText("v |cffffd100" .. mode.label .. "|r")

    -- group total for this mode, so the headline number is visible without adding up rows
    local _, groupTotal = BuildList(seg, mode.key)
    if groupTotal > 0 then
        if mode.perSec then
            totalText:SetText(string.format("|cffffffff%s|r |cffaaaaaa(%s)|r",
                ShortNum(groupTotal), ShortNum(groupTotal / dur)))
        else
            totalText:SetText("|cffffffff" .. groupTotal .. "|r")
        end
    else
        totalText:SetText("")
    end

    local shown = VisibleRowCount()
    local top = -26

    if detailActor then
        local list, total = BuildSpells(seg, detailActor, mode.key)
        for idx = 1, shown do
            local r = AcquireRow(idx)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 4, top - (idx - 1) * ROW_H)
            r:SetPoint("TOPRIGHT", -4, top - (idx - 1) * ROW_H)
            if idx == 1 then
                r.icon:Hide()
                r.bar:SetWidth(1)
                r.left:SetText("|cff66ccff< Back|r  |cffffffff" .. detailActor .. "|r")
                r.left:SetTextColor(1, 1, 1)
                r.right:SetText("|cffaaaaaa" .. mode.short .. "|r")
                r.data = "__back__"
                r.spellData = nil
                r:Show()
            else
                local e = list[idx - 1]
                if e then
                    local pct = total > 0 and (e.amt / total * 100) or 0
                    if e.icon then
                        r.icon:SetTexture(e.icon)
                        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        r.icon:Show()
                    else
                        r.icon:Hide()
                    end
                    r.bar:SetWidth(math.max(1, (frame:GetWidth() - 8) * (list[1] and (e.amt / list[1].amt) or 0)))
                    r.bar:SetVertexColor(0.35, 0.5, 0.8, 0.55)
                    r.left:SetText(e.spell); r.left:SetTextColor(1, 1, 1)
                    -- amount, share, then hit count with the crit rate folded in
                    local critPart = ""
                    if e.crits > 0 and e.hits > 0 then
                        critPart = string.format(" |cffffcc66%.0f%%c|r", e.crits / e.hits * 100)
                    end
                    r.right:SetText(string.format("%s  |cffaaaaaa%.0f%%|r  %d%s",
                        ShortNum(e.amt), pct, e.hits, critPart))
                    r.right:SetTextColor(1, 1, 1)
                    r.data = nil
                    r.spellData = e
                    r:Show()
                else
                    r:Hide()
                end
            end
        end
        for idx = shown + 1, #rows do rows[idx]:Hide() end
        return
    end

    local list, total = BuildList(seg, mode.key)
    local topAmt = list[1] and list[1].amount or 1
    for idx = 1, shown do
        local r = AcquireRow(idx)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 4, top - (idx - 1) * ROW_H)
        r:SetPoint("TOPRIGHT", -4, top - (idx - 1) * ROW_H)
        local e = list[idx]
        if e then
            local cr, cg, cb = ClassColor(e.class)
            local pct = total > 0 and (e.amount / total * 100) or 0
            r.bar:SetWidth(math.max(1, (frame:GetWidth() - 8) * (e.amount / topAmt)))
            r.bar:SetVertexColor(cr, cg, cb, 0.85)
            -- SetClassIcon applies the class sheet's own texcoords, so nothing to reset here
            -- even when this row last held a spell icon.
            SetClassIcon(r.icon, e.class)
            r.left:SetText(string.format("%d. %s", idx, e.name)); r.left:SetTextColor(1, 1, 1)
            -- total, then the per-second figure and share in a dimmer tone so the eye lands
            -- on the number that matters first
            if mode.perSec then
                r.right:SetText(string.format("%s  |cffffd100%s|r  |cffaaaaaa%.0f%%|r",
                    ShortNum(e.amount), ShortNum(e.amount / dur), pct))
            else
                r.right:SetText(string.format("%d  |cffaaaaaa%.0f%%|r", e.amount, pct))
            end
            r.right:SetTextColor(1, 1, 1)
            r.data = e.name
            r.spellData = nil
            r:Show()
        else
            r:Hide()
        end
    end
    for idx = shown + 1, #rows do rows[idx]:Hide() end
end
_G.GaarMeter_Redraw = Redraw

OnRowClick = function(self, button)
    if self.data == "__back__" then detailActor = nil; Redraw(); return end
    if button == "RightButton" then detailActor = nil; Redraw(); return end
    if self.data then detailActor = (detailActor == self.data) and nil or self.data; Redraw() end
end

OnRowEnter = function(self)
    local seg = SelectedSeg()
    local mode = MODE_BY_KEY[DB().mode] or MODES[1]
    local dur = SegDuration(seg)

    -- Hovering a spell row: everything known about that one spell.
    local e = self.spellData
    if e then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(IconText(e.icon) .. e.spell)
        GameTooltip:AddDoubleLine("Total", ShortNum(e.amt), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Per second", ShortNum(e.amt / dur), 0.8, 0.8, 0.8, 1, 0.82, 0)
        GameTooltip:AddDoubleLine("Hits", tostring(e.hits), 0.8, 0.8, 0.8, 1, 1, 1)
        if e.crits > 0 then
            GameTooltip:AddDoubleLine("Crits",
                string.format("%d  (%.0f%%)", e.crits, e.crits / math.max(1, e.hits) * 100),
                0.8, 0.8, 0.8, 1, 0.82, 0)
        end
        if e.misses > 0 then
            local attempts = e.hits + e.misses
            GameTooltip:AddDoubleLine("Missed",
                string.format("%d  (%.0f%%)", e.misses, e.misses / attempts * 100),
                0.8, 0.8, 0.8, 1, 0.5, 0.5)
        end
        GameTooltip:AddDoubleLine("Average", ShortNum(e.avg), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Biggest", ShortNum(e.max), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:Show()
        return
    end

    if not self.data or self.data == "__back__" then return end

    -- Hovering an actor row: their spell breakdown, with icons.
    local list, total = BuildSpells(seg, self.data, mode.key)
    local actor = seg and seg.actors[self.data]
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local cr, cg, cb = ClassColor(actor and actor.class)
    GameTooltip:AddLine(self.data .. "  |cffaaaaaa" .. mode.label .. "|r", cr, cg, cb)
    if actor then
        GameTooltip:AddDoubleLine("Total", ShortNum(actor.amount[mode.key] or 0), 0.8, 0.8, 0.8, 1, 1, 1)
        if mode.perSec then
            GameTooltip:AddDoubleLine(mode.short,
                ShortNum((actor.amount[mode.key] or 0) / dur), 0.8, 0.8, 0.8, 1, 0.82, 0)
        end
        if actor.hits and actor.hits > 0 and (actor.crits or 0) > 0 then
            GameTooltip:AddDoubleLine("Crit rate",
                string.format("%.0f%%", actor.crits / actor.hits * 100), 0.8, 0.8, 0.8, 1, 0.82, 0)
        end
    end
    if #list > 0 then
        GameTooltip:AddLine(" ")
        for i = 1, math.min(10, #list) do
            local s = list[i]
            local pct = total > 0 and (s.amt / total * 100) or 0
            GameTooltip:AddDoubleLine(IconText(s.icon) .. s.spell,
                string.format("%s  %.0f%%  |cffaaaaaa%d hits|r", ShortNum(s.amt), pct, s.hits),
                1, 1, 1, 1, 0.82, 0)
        end
        GameTooltip:AddLine("Click for the full breakdown.", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- Menus / actions
-- ---------------------------------------------------------------------------
local function Reset()
    overall = { name = "Overall", start = GetTime(), actors = {} }
    fights = {}; cur = nil; detailActor = nil
    Redraw()
end
_G.GaarMeter_Reset = Reset

local function ModeMenu()
    local t = { { text = "Mode", isTitle = true } }
    for _, m in ipairs(MODES) do
        t[#t + 1] = { text = m.label, checked = (DB().mode == m.key),
            func = function() DB().mode = m.key; detailActor = nil; Redraw() end }
    end
    return t
end

local function SegMenu()
    local t = {
        { text = "Segment", isTitle = true },
        { text = "Current fight", checked = (viewSeg == "current"),
          func = function() viewSeg = "current"; detailActor = nil; Redraw() end },
        { text = "Overall (instance)", checked = (viewSeg == "overall"),
          func = function() viewSeg = "overall"; detailActor = nil; Redraw() end },
    }
    for i, f in ipairs(fights) do
        if i > 10 then break end
        local idx = i
        t[#t + 1] = { text = (f.name or ("Fight " .. i)) .. string.format("  (%ds)", math.floor(SegDuration(f))),
            checked = (viewSeg == idx),
            func = function() viewSeg = idx; detailActor = nil; Redraw() end }
    end
    return t
end

local function Report()
    local mode = MODE_BY_KEY[DB().mode] or MODES[1]
    local seg = SelectedSeg()
    local dur = SegDuration(seg)
    local list, total = BuildList(seg, mode.key)
    local ch = DB().reportChannel
    local inRaid = IsInRaid and IsInRaid()
    local groupSize = (GetNumSubgroupMembers and GetNumSubgroupMembers()) or 0
    if ch == "PARTY" and inRaid then ch = "RAID" end
    if ch == "PARTY" and groupSize == 0 then ch = "SAY" end
    SendChatMessage(string.format("Gaar Meter - %s (%s):", mode.label, SegName(seg)), ch)
    for i = 1, math.min(5, #list) do
        local e = list[i]
        local pct = total > 0 and (e.amount / total * 100) or 0
        if mode.perSec then
            SendChatMessage(string.format("%d. %s  %s (%s, %.0f%%)", i, e.name, ShortNum(e.amount),
                ShortNum(e.amount / dur), pct), ch)
        else
            SendChatMessage(string.format("%d. %s  %d (%.0f%%)", i, e.name, e.amount, pct), ch)
        end
    end
end
_G.GaarMeter_Report = Report

local function ConfigMenu()
    return {
        { text = ADDON, isTitle = true },
        { text = "Reset data", func = Reset },
        { text = "Report to chat", func = Report },
        { text = "Settings...", func = function()
            if _G.GaarOptions_Open then _G.GaarOptions_Open("meter") end
        end },
    }
end

segBtn:SetScript("OnClick", function() ShowMenu(SegMenu(), segBtn) end)
modeBtn:SetScript("OnClick", function() ShowMenu(ModeMenu(), modeBtn) end)
header:SetScript("OnClick", function(_, button)
    if button == "RightButton" then ShowMenu(ConfigMenu()) end
end)
frame:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then ShowMenu(ConfigMenu()) end
end)

local grip = CreateFrame("Button", nil, frame)
grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -2, 2)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing(); SavePos(); Redraw() end)

local acc = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc >= 0.3 then acc = 0; Redraw() end
end)

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
-- The combat log getter moved into C_CombatLog on retail; the probe read the old global as
-- nil there. Ask the namespace first and fall back, rather than deciding which client this is:
-- getting this wrong costs the whole meter, silently, since the event still fires.
local function CombatLogInfo()
    local C = _G.C_CombatLog
    if C and C.GetCurrentEventInfo then return C.GetCurrentEventInfo() end
    if CombatLogGetCurrentEventInfo then return CombatLogGetCurrentEventInfo() end
end

-- Where there is no getter at all, this meter cannot work, and an empty window looks like a
-- bug rather than a client that has closed the door. It says so once, and again whenever the
-- window is opened, so the reason is never further away than the thing it explains.
--
-- On Forever, C_CombatLog exists but carries only IsCombatLogRestricted, ClearEntries and
-- SetMessageLimit - every reader is absent. There is nothing to shim.
local HAS_CLEU_GETTER = (_G.C_CombatLog and type(_G.C_CombatLog.GetCurrentEventInfo) == "function")
    or (type(CombatLogGetCurrentEventInfo) == "function")

frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if HAS_CLEU_GETTER then Parse(CombatLogInfo()) else ParseLegacy(...) end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if not cur then cur = NewSeg("Current fight") end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if cur then
            cur.endt = GetTime()
            cur.name = date("%H:%M:%S")
            table.insert(fights, 1, cur)
            while #fights > MAX_FIGHTS do table.remove(fights) end
            if type(viewSeg) == "number" then viewSeg = viewSeg + 1 end
            cur = nil
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        RefreshClassCache()
        local inside = IsInInstance()
        if inside and not wasInside then Reset() end
        wasInside = inside
        if inside and DB().showInInstance then DB().shown = true end
        if DB().shown then frame:Show(); Redraw() end
    end
end)

local warnedNoLog = false
local function WarnIfBlind()
    if HAS_CLEU_GETTER or type(_G.CombatLogGetCurrentEventInfo) == "function" then return false end
    if not warnedNoLog then
        warnedNoLog = true
        local restricted = ""
        local C = _G.C_CombatLog
        if C and C.IsCombatLogRestricted then
            local ok, r = pcall(C.IsCombatLogRestricted)
            if ok and r then restricted = " (the client reports the combat log as restricted)" end
        end
        print("|cff5599ffGaar Meter:|r this client gives addons no way to read the combat log" ..
              restricted .. " - nothing can be measured here.")
    end
    return true
end

local function Toggle()
    WarnIfBlind()
    if frame:IsShown() then frame:Hide(); DB().shown = false
    else frame:Show(); DB().shown = true; Redraw() end
end
_G.GaarMeter_Toggle = Toggle

-- ---------------------------------------------------------------------------
-- Options — shared with the Gaar options entry
-- ---------------------------------------------------------------------------
local uid = 0
function GaarMeter_BuildOptions(container)
    local refreshers = {}
    local y = -8

    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("Combat meter")
    y = y - 28

    local toggle = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    toggle:SetSize(150, 24); toggle:SetPoint("TOPLEFT", 16, y)
    local function label() return frame:IsShown() and "Hide the meter" or "Show the meter" end
    toggle:SetText(label())
    toggle:SetScript("OnClick", function(self) Toggle(); self:SetText(label()) end)
    refreshers[#refreshers + 1] = function() toggle:SetText(label()) end

    local resetBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    resetBtn:SetSize(100, 24); resetBtn:SetPoint("TOPLEFT", 172, y)
    resetBtn:SetText("Reset data")
    resetBtn:SetScript("OnClick", Reset)

    local reportBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    reportBtn:SetSize(100, 24); reportBtn:SetPoint("TOPLEFT", 276, y)
    reportBtn:SetText("Report")
    reportBtn:SetScript("OnClick", Report)
    y = y - 34

    uid = uid + 1
    local cbName = "GaarMeterCheck" .. uid
    local inst = CreateFrame("CheckButton", cbName, container, "UICheckButtonTemplate")
    inst:SetSize(24, 24); inst:SetPoint("TOPLEFT", 16, y)
    inst:SetChecked(DB().showInInstance)
    local cbText = _G[cbName .. "Text"]
    cbText:SetText("Show automatically in instances"); cbText:SetFontObject(GameFontHighlight)
    inst:SetScript("OnClick", function(self) DB().showInInstance = self:GetChecked() and true or false end)
    refreshers[#refreshers + 1] = function() inst:SetChecked(DB().showInInstance) end
    y = y - 34

    local modeLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    modeLabel:SetPoint("TOPLEFT", 18, y); modeLabel:SetText("Mode:")
    local x = 90
    for i, m in ipairs(MODES) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(74, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(m.short)
        b:SetScript("OnClick", function() DB().mode = m.key; detailActor = nil; Redraw() end)
        x = x + 76
        if i == 3 then x = 90; y = y - 24 end
    end
    y = y - 30

    local chLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    chLabel:SetPoint("TOPLEFT", 18, y); chLabel:SetText("Report to:")
    x = 110
    for _, c in ipairs({ "PARTY", "SAY", "GUILD" }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(70, 20); b:SetPoint("TOPLEFT", x, y + 4)
        b:SetText(c == "PARTY" and "Party/Raid" or (c == "SAY" and "Say" or "Guild"))
        b:SetScript("OnClick", function() DB().reportChannel = c end)
        x = x + 72
    end
    y = y - 34

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(340); hint:SetJustifyH("LEFT")
    hint:SetText("On the meter itself: click the header's left label for segments, the right one for modes, right-click for reset/report, click a bar for its spell breakdown.")
    y = y - 48

    container.gaarRefresh = function() for _, fn in ipairs(refreshers) do fn() end end
    return -y
end

-- ---------------------------------------------------------------------------
-- Slash
-- ---------------------------------------------------------------------------
SLASH_GAARMETER1 = "/gaarmeter"
SLASH_GAARMETER2 = "/gmeter"
SlashCmdList["GAARMETER"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "reset" then
        Reset(); print("|cff5599ff" .. ADDON .. ":|r reset.")
    elseif msg == "report" then
        Report()
    elseif msg == "mode" then
        local keys = {}
        for _, m in ipairs(MODES) do keys[#keys + 1] = m.key end
        local i = 1
        for k, key in ipairs(keys) do if key == DB().mode then i = k end end
        DB().mode = keys[(i % #keys) + 1]; detailActor = nil; Redraw()
        print("|cff5599ff" .. ADDON .. ":|r mode = " .. MODE_BY_KEY[DB().mode].label)
    elseif msg == "config" or msg == "options" then
        if not (_G.GaarOptions_Open and _G.GaarOptions_Open("meter")) then ShowMenu(ConfigMenu()) end
    else
        Toggle()
    end
end

local loginF = CreateFrame("Frame")
loginF:RegisterEvent("PLAYER_LOGIN")
loginF:SetScript("OnEvent", function() if DB().shown then frame:Show(); Redraw() end end)
