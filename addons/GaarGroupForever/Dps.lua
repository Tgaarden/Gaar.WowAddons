--[[
  GaarGroupForever - Dps.lua: the DPS role module (active only while your mode is DPS).

    Assist tank     An "Assist" button under the bar: SECURE (SecureActionButtonTemplate, type "assist",
                    unit = the party member whose role is TANK). Created out of combat only; its unit is
                    changed out of combat only (in combat it keeps the old tank).
    Wrong target    In combat, while a skull is out and you attack a living mob that is not the skull: a
                    short warning. Needs readable marker indexes; a secret answer is skipped.
    Aggro           A hostile mob in combat that targets you (you are not the tank): "<mob> is on you".
    CC assignment   The party LEADER can give each DPS a marker (right-click the bar > DPS mode > Crowd
                    control). Stored for this session; on your click it says "Sheep = Moon (Name)" to PARTY
                    and sends a tiny addon message so the assigned player sees "CC: Moon" above their bar
                    (only players who run this addon see it). Never sent by itself.
    Interrupt       When your target or focus starts a cast that can be interrupted: a short alert.
                    UNIT_SPELLCAST_START / CHANNEL_START; a secret flag is skipped.
]]

local _G = _G
local API = _G.GaarGroupForeverAPI
local M = API and API._M
local R = M and M.Roles
if not R then return end
local BF = _G.GaarForever
local Num, Str = BF.Num, BF.Str

local D = { name = "DPS" }
M.Dps = D

R.AddOption("dps", "dpsAssist", "Assist tank button", true, "assist")
R.AddOption("dps", "dpsWrongTarget", "Wrong-target warning (not the skull)", true, "wrongtarget")
R.AddOption("dps", "dpsAggro", "Aggro warning", true, "aggro")
R.AddOption("dps", "dpsCC", "Show my crowd-control marker (leader assigns)", true, "cc")
R.AddOption("dps", "dpsInterrupt", "Interrupt alert (target / focus)", true, "interrupt")

local SKULL = 8
local PREFIX = "GGFcc"

D.MARKERS = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "X" } -- 1..7 (never skull)
D.CC_SPELL = { MAGE = "Sheep", ROGUE = "Sap", WARLOCK = "Fear", HUNTER = "Trap", PRIEST = "Shackle",
    DRUID = "Hibernate", PALADIN = "Turn" }

function D.MarkerIcon(idx)
    return "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_" .. idx .. ":14|t"
end

-- ---------------------------------------------------------------------------
-- Pure logic
-- ---------------------------------------------------------------------------

-- Warn when a skull exists and you attack something else (in combat, attackable, living).
function D.WrongTarget(skullExists, targetIdx, inCombat, attackable)
    if skullExists ~= true or inCombat ~= true or attackable ~= true then return false end
    if targetIdx == nil then return false end -- unreadable: no warning
    return targetIdx ~= SKULL
end

-- Mobs on you (onMe == true), for a non-tank.
function D.AggroOnMe(items)
    local out = {}
    for _, it in ipairs(items or {}) do
        if it.onMe == true then out[#out + 1] = it end
    end
    return out
end

-- UnitCastingInfo / UnitChannelInfo results (packed) -> spell name, notInterruptible (true/false/nil).
-- The two client generations differ by one value; r[6] is a boolean (isTradeSkill) in the newer one and
-- a number (end time) in the older one.
function D.ParseCast(kind, r)
    local newer = type(r[6]) == "boolean"
    local flag
    local pos = (kind == "cast" and 8 or 7) + (newer and 0 or 1)
    flag = r[pos]
    if BF.IsSecret(flag) or type(flag) ~= "boolean" then flag = nil end
    return Str(r[1]), flag
end

-- true when an alert is due: the flag must be a readable false.
function D.InterruptDue(notInterruptible)
    return notInterruptible == false
end

function D.CCText(class, idx)
    local m = D.MARKERS[idx]
    if not m then return nil end
    return (D.CC_SPELL[class] or "CC") .. " = " .. m
end

-- "CC|name|idx" (idx 0 clears) -> name, idx or nil.
function D.ParseCC(msg)
    if type(msg) ~= "string" then return nil end
    local name, idx = msg:match("^CC|([^|]+)|(%d)$")
    idx = tonumber(idx)
    if not name or not idx or idx < 0 or idx > 7 then return nil end
    return name, idx
end

function D.BuildCC(name, idx) return "CC|" .. name .. "|" .. idx end

-- ---------------------------------------------------------------------------
-- CC assignment (this session only)
-- ---------------------------------------------------------------------------

D.cc = {} -- player name -> marker index

function D.IsMe(name)
    local mine = BF.PlayerFullName()
    local short = R.Name("player")
    return (mine and BF.NamesMatch(name, mine)) or (short and BF.NamesMatch(name, short)) or false
end

function D.MyCC()
    for name, idx in pairs(D.cc) do
        if idx > 0 and D.IsMe(name) then return idx end
    end
end

-- Leader's click: assign (idx 0 clears). Says it to PARTY (explicit click) and sends the addon message.
function D.Assign(name, class, idx)
    if not M.IsLeader() then M.Print("Only the party leader can assign crowd control."); return false end
    if idx == 0 then
        D.cc[name] = nil
    else
        D.cc[name] = idx
        local text = D.CCText(class, idx)
        if text then R.Say(text .. " (" .. name .. ")") end
    end
    local C = _G.C_ChatInfo
    if type(C) == "table" and type(C.SendAddonMessage) == "function" and M.InGroup() then
        pcall(C.SendAddonMessage, PREFIX, D.BuildCC(name, idx), "PARTY")
    end
    return true
end

function D.OnAddon(prefix, msg, _, sender)
    if prefix ~= PREFIX then return end
    local name, idx = D.ParseCC(msg)
    if not name then return end
    -- only the party leader's assignments count
    local unit = BF.UnitByName(BF.StripRealm(Str(sender)) or "")
    if not unit or R.B(_G.UnitIsGroupLeader, unit) ~= true then return end
    if idx == 0 then D.cc[name] = nil else D.cc[name] = idx end
end

-- DPS-ish members the leader can give a marker: everyone but the tank and the healer.
function D.Candidates()
    local out = {}
    local units = { "player" }
    for _, u in ipairs(R.PartyUnits()) do units[#units + 1] = u end
    for _, u in ipairs(units) do
        local role = R.Q(_G.UnitGroupRolesAssigned, u)
        local name = R.Name(u)
        if name and role ~= "TANK" and role ~= "HEALER" then
            local _, _, class = pcall(_G.UnitClass, u)
            out[#out + 1] = { name = name, class = type(class) == "string" and class or nil }
        end
    end
    return out
end

-- Right-click menu: leader only.
function D.entries()
    if not M.IsLeader() then return nil end
    local subs = {}
    for _, c in ipairs(D.Candidates()) do
        local marks = { { text = "None", radio = true, checked = function() return (D.cc[c.name] or 0) == 0 end,
            func = function() D.Assign(c.name, c.class, 0) end } }
        for i, m in ipairs(D.MARKERS) do
            marks[#marks + 1] = { text = m, radio = true, checked = function() return D.cc[c.name] == i end,
                func = function() D.Assign(c.name, c.class, i) end }
        end
        subs[#subs + 1] = { text = c.name, submenu = marks }
    end
    if #subs == 0 then return nil end
    return { { text = "Crowd control (leader): who gets which marker", submenu = subs } }
end

-- ---------------------------------------------------------------------------
-- Skull / wrong target
-- ---------------------------------------------------------------------------

function D.SkullExists()
    for _, u in ipairs(R.ScanUnits()) do
        if R.Exists(u) and R.Q(_G.GetRaidTargetIndex, u) == SKULL and R.B(_G.UnitIsDeadOrGhost, u) ~= true then
            return true
        end
    end
    return false
end

function D.CheckWrongTarget(inCombat)
    if not R.Opt("dpsWrongTarget") or not R.Exists("target") then return end
    local attackable = R.B(_G.UnitCanAttack, "player", "target") == true and R.B(_G.UnitIsDeadOrGhost, "target") ~= true
    if not attackable then return end
    local okIdx, raw = pcall(_G.GetRaidTargetIndex, "target")
    if not okIdx or BF.IsSecret(raw) then return end -- unreadable: no warning
    local idx = Num(raw) or 0
    if D.WrongTarget(D.SkullExists(), idx, inCombat, attackable) then
        local n = R.Name("target") or "this mob"
        R.Alert("wrongTarget", "Not skull: " .. n, { gap = 8, ttl = 3, color = R.YELLOW })
    end
end

-- ---------------------------------------------------------------------------
-- Interrupt
-- ---------------------------------------------------------------------------

function D.CheckCast(unit)
    if not R.Opt("dpsInterrupt") then return end
    if unit ~= "target" and unit ~= "focus" then return end
    if R.B(_G.UnitCanAttack, "player", unit) ~= true then return end
    local function pack(...) return { ... } end
    local kind, r = "cast", nil
    if type(_G.UnitCastingInfo) == "function" then
        local ok, t = pcall(function() return pack(_G.UnitCastingInfo(unit)) end)
        if ok and t[1] ~= nil then r = t end
    end
    if not r and type(_G.UnitChannelInfo) == "function" then
        local ok, t = pcall(function() return pack(_G.UnitChannelInfo(unit)) end)
        if ok and t[1] ~= nil then kind, r = "channel", t end
    end
    if not r then return end
    local spell, notInt = D.ParseCast(kind, r)
    if D.InterruptDue(notInt) then
        local mob = R.Name(unit) or "Target"
        R.Alert("interrupt:" .. unit, "Interrupt " .. mob .. (spell and (": " .. spell) or "!"),
            { gap = 3, ttl = 3, color = R.RED })
    end
end

-- ---------------------------------------------------------------------------
-- Row, tick
-- ---------------------------------------------------------------------------

function D.build(row)
    local f = _G.CreateFrame("Button", "GaarGroupForeverAssist", row, "SecureActionButtonTemplate")
    f:SetSize(60, 26)
    f:SetPoint("LEFT", row, "LEFT", 5, 0)
    f:RegisterForClicks("AnyUp")
    f:SetAttribute("type", "assist")
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    local hot = f:CreateTexture(nil, "HIGHLIGHT")
    hot:SetAllPoints()
    hot:SetColorTexture(1, 1, 1, 0.15)
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    fs:SetText("Assist")
    M.Tip(f, function()
        local u = D.assistUnit
        return { "Assist the tank", u and ("Targets what " .. (R.Name(u) or "the tank") .. " is targeting.")
            or "No party member has the Tank role yet." }
    end)
    D.assistButton = f
    return 70, 26
end

function D.refresh()
    local f = D.assistButton
    if not f then return end
    local unit = R.Opt("dpsAssist") and R.UnitByRole("TANK") or nil
    if not R.InCombat() then
        if unit ~= f.unitSet then
            f:SetAttribute("unit", unit)
            f.unitSet = unit
        end
        local want = unit ~= nil
        if want and not f:IsShown() then f:Show() elseif not want and f:IsShown() then f:Hide() end
    end
    D.assistUnit = unit
    f:SetAlpha(unit and f.unitSet == unit and 1 or 0)
end

function D.tick(now)
    local inCombat = R.InCombat() or R.B(_G.UnitAffectingCombat, "player") == true
    local cc = R.Opt("dpsCC") and D.MyCC() or nil
    R.SetStatus("dpsCC", cc and ("CC: " .. D.MarkerIcon(cc) .. " " .. D.MARKERS[cc]) or nil, R.BLUE)
    if not inCombat then return end
    if R.Opt("dpsWrongTarget") then D.CheckWrongTarget(true) end
    if R.Opt("dpsAggro") then
        for _, it in ipairs(D.AggroOnMe(R.Scan(now))) do
            local mob = it.name or "A mob"
            R.Alert("aggro:" .. mob, mob .. " is on you!", { gap = 6, group = "aggro", groupGap = 2, ttl = 4, color = R.RED })
        end
    end
end

D.events = {
    UNIT_SPELLCAST_START = function(unit) D.CheckCast(unit) end,
    UNIT_SPELLCAST_CHANNEL_START = function(unit) D.CheckCast(unit) end,
}

function D.deactivate() end

function D.onRoster()
    if not M.InGroup() then D.cc = {} end
end

function D.demo()
    R.Alert("demo:skull", "Not skull: Wolf", { gap = 0, ttl = 6, color = R.YELLOW })
    R.Alert("demo:aggro", "Boar is on you!", { gap = 0, ttl = 6, color = R.RED })
    R.Alert("demo:int", "Interrupt Wolf: Healing Touch", { gap = 0, ttl = 6, color = R.RED })
    R.SetStatus("dpsCC", "CC: " .. D.MarkerIcon(5) .. " Moon", R.BLUE)
end

function D.help()
    return { "/ggf dps cc - list the crowd-control markers (leader: assign from the bar's right-click menu)",
        "/ggf dps test - show sample warnings" }
end

function D.slash(sub)
    if sub == "cc" then
        local any = false
        for name, idx in pairs(D.cc) do
            any = true
            M.Print(name .. " = " .. (D.MARKERS[idx] or "?"))
        end
        if not any then M.Print("No crowd-control markers assigned this session.") end
        return true
    end
end

pcall(function()
    local C = _G.C_ChatInfo
    if type(C) == "table" and type(C.RegisterAddonMessagePrefix) == "function" then C.RegisterAddonMessagePrefix(PREFIX) end
end)

-- CHAT_MSG_ADDON arrives whatever your mode is (an assignment can come before you switch), so the
-- module listens itself instead of using the active-role event table.
D.addonFrame = _G.CreateFrame("Frame")
pcall(D.addonFrame.RegisterEvent, D.addonFrame, "CHAT_MSG_ADDON")
D.addonFrame:SetScript("OnEvent", function(_, _, ...)
    pcall(D.OnAddon, ...)
end)

R.Register("dps", D)
