--[[
  GaarGroupForever - Healer.lua: the Healer role module (active only while your mode is Healer).

    Drink / OOM     Two buttons under the bar post "Drinking" / "OOM" to PARTY on your click (also
                    /ggf healer drink | oom). Optional, off by default: post by itself when you start
                    drinking, or when your mana drops below 10 %.
    Dispel alert    A line above the bar for party members (and you) with a debuff your class can remove:
                    Priest Magic/Disease, Paladin Magic/Poison/Disease, Druid Curse/Poison, Shaman
                    Poison/Disease (mirrors GaarBuffsForever's dispel table; a kind needs the spell known
                    when the client says so). Read out of combat-style with plain dispelName; a secret
                    aura is skipped (so in combat it often shows nothing).
    Tank frame      A small frame under the buttons for the party member whose role is TANK: name, health
                    bar, target. SECURE (SecureUnitButtonTemplate): click targets the tank. Created out of
                    combat only, as a child of UIParent laid over the row (R.Secure), so the bar can hide,
                    move and scale in combat; its unit, Show/Hide and position change out of combat only
                    (in combat it keeps the old tank, and is only faded out when the bar goes away).
    Dead / range    A warning when a party member dies, or leaves heal range (UnitInRange, checked ones only).
    PvP flag        A warning when your target or mouseover is a PvP-flagged friendly player and you are not.
]]

local _G = _G
local API = _G.GaarGroupForeverAPI
local M = API and API._M
local R = M and M.Roles
if not R then return end
local BF = _G.GaarForever
local Num, Str = BF.Num, BF.Str

local H = { name = "Healer" }
M.Healer = H

R.AddOption("healer", "healButtons", "Drink / OOM buttons", true, "buttons")
R.AddOption("healer", "healAutoDrink", "Say \"Drinking\" to party when I start drinking", false, "autodrink")
R.AddOption("healer", "healAutoOom", "Say \"OOM\" to party below 10% mana", false, "autooom")
R.AddOption("healer", "healDispel", "Dispel alert", true, "dispel")
R.AddOption("healer", "healTankFrame", "Tank frame", true, "tankframe")
R.AddOption("healer", "healDeadRange", "Dead / out-of-range warning", true, "deadrange")
R.AddOption("healer", "healPvp", "PvP-flag warning", true, "pvp")

local OOM_LOW, OOM_REARM = 10, 20
local MAX_DEBUFFS = 40

-- ---------------------------------------------------------------------------
-- Dispel table (mirrors GaarBuffsForever/Dispel.lua CLASS_CONFIG: the kinds and the spell IDs)
-- ---------------------------------------------------------------------------

-- kind (the game's dispelName) -> spell ids that remove it, per class
H.CLASS_KINDS = {
    PRIEST = { Magic = { 988, 527 }, Disease = { 552, 528 } },
    PALADIN = { Magic = { 4987 }, Poison = { 4987, 1152 }, Disease = { 4987, 1152 } },
    DRUID = { Curse = { 2782 }, Poison = { 2893, 8946 } },
    SHAMAN = { Poison = { 526 }, Disease = { 2870 } },
}

-- The kinds this class can dispel, as a set. known(id) -> true/false/nil: when it answers (not nil) a kind
-- needs one of its spells known; without an answer every kind of the class counts.
function H.KindsFor(class, known)
    local out = {}
    local t = H.CLASS_KINDS[class]
    if not t then return out end
    for kind, ids in pairs(t) do
        local has = true
        if type(known) == "function" then
            has = false
            for _, id in ipairs(ids) do
                if known(id) == true then has = true; break end
            end
        end
        if has then out[kind] = true end
    end
    return out
end

function H.CanDispel(class, kind, known)
    return H.KindsFor(class, known)[kind] == true
end

-- auras: list of dispelName strings on one unit -> the kinds you can remove, in a stable order.
local ORDER = { "Magic", "Curse", "Poison", "Disease" }
function H.Removable(kinds, auras)
    local have, out = {}, {}
    for _, k in ipairs(auras or {}) do have[k] = true end
    for _, k in ipairs(ORDER) do
        if have[k] and kinds[k] then out[#out + 1] = k end
    end
    return out
end

-- entries: list of { name, kinds = { "Magic", ... } } -> "Dispel: Mira (Magic), Bob (Poison, Disease)"
function H.DispelText(entries)
    if #entries == 0 then return nil end
    local parts = {}
    for i, e in ipairs(entries) do
        if i > 4 then parts[#parts + 1] = "..."; break end
        parts[#parts + 1] = e.name .. " (" .. table.concat(e.kinds, ", ") .. ")"
    end
    return "Dispel: " .. table.concat(parts, ", ")
end

local function KnownFn()
    local f = type(_G.IsSpellKnown) == "function" and _G.IsSpellKnown
    if not f and type(_G.IsPlayerSpell) == "function" then f = _G.IsPlayerSpell end
    if not f then return nil end
    return function(id)
        local ok, v = pcall(f, id)
        if not ok or BF.IsSecret(v) then return nil end
        return v and true or false
    end
end

function H.MyKinds()
    local _, _, class = pcall(_G.UnitClass, "player")
    if type(class) ~= "string" then return {} end
    return H.KindsFor(class, KnownFn())
end

-- The dispelName strings on a unit's harmful auras; nil when it cannot be read (secret).
function H.DebuffKinds(unit)
    local out = {}
    local C = _G.C_UnitAuras
    local byData = type(C) == "table" and type(C.GetAuraDataByIndex) == "function"
    local old = type(_G.UnitDebuff) == "function" and _G.UnitDebuff
    if not byData and not old then return nil end
    for i = 1, MAX_DEBUFFS do
        local kind
        if byData then
            local ok, a = pcall(C.GetAuraDataByIndex, unit, i, "HARMFUL")
            if not ok or BF.IsSecret(a) then return nil end
            if type(a) ~= "table" then break end
            local ok2, dn = pcall(function() return a.dispelName end)
            if not ok2 or BF.IsSecret(dn) then return nil end
            kind = dn
        else
            local ok, name, _, _, dt = pcall(old, unit, i)
            if not ok or BF.IsSecret(name) or BF.IsSecret(dt) then return nil end
            if not Str(name) then break end
            kind = dt
        end
        if type(kind) == "string" then out[#out + 1] = kind end
    end
    return out
end

function H.DispelEntries()
    local kinds = H.MyKinds()
    local entries = {}
    if next(kinds) == nil then return entries end
    local units = { "player" }
    for _, u in ipairs(R.PartyUnits()) do units[#units + 1] = u end
    for _, u in ipairs(units) do
        if R.B(_G.UnitIsDeadOrGhost, u) ~= true and R.B(_G.UnitIsConnected, u) ~= false then
            local auras = H.DebuffKinds(u)
            if auras then
                local list = H.Removable(kinds, auras)
                local name = R.Name(u)
                if #list > 0 and name then entries[#entries + 1] = { name = name, kinds = list } end
            end
        end
    end
    return entries
end

-- ---------------------------------------------------------------------------
-- Drinking / OOM
-- ---------------------------------------------------------------------------

function H.IsDrinkName(name)
    if type(name) ~= "string" then return false end
    local l = name:lower()
    return l == "drink" or l:find("^drink") ~= nil or l:find("refreshment", 1, true) ~= nil
end

function H.IsDrinking()
    local C = _G.C_UnitAuras
    local byData = type(C) == "table" and type(C.GetAuraDataByIndex) == "function"
    local old = type(_G.UnitBuff) == "function" and _G.UnitBuff
    for i = 1, MAX_DEBUFFS do
        local name
        if byData then
            local ok, a = pcall(C.GetAuraDataByIndex, "player", i, "HELPFUL")
            if not ok or BF.IsSecret(a) then return nil end
            if type(a) ~= "table" then break end
            local ok2, n = pcall(function() return a.name end)
            if not ok2 or BF.IsSecret(n) then return nil end
            name = n
        elseif old then
            local ok, n = pcall(old, "player", i)
            if not ok or BF.IsSecret(n) then return nil end
            name = n
        else
            return nil
        end
        if not Str(name) then break end
        if H.IsDrinkName(name) then return true end
    end
    return false
end

-- OOM auto-post: state { low = bool }. Returns "post" once when mana first falls below 10 %, re-armed above 20 %.
function H.OomStep(state, pct)
    pct = Num(pct)
    if not pct then return nil end
    if pct < OOM_LOW and not state.low then state.low = true; return "post" end
    if pct > OOM_REARM then state.low = false end
    return nil
end

-- Drink auto-post: "post" when you were not drinking and now are.
function H.DrinkStep(state, drinking)
    if drinking == nil then return nil end
    local was = state.drinking
    state.drinking = drinking
    if drinking and not was then return "post" end
    return nil
end

H.state = { drink = {}, oom = {} }

function H.Post(text)
    if not R.Say(text) then M.Print("Not in a party (or the client cannot send chat).") end
end

-- ---------------------------------------------------------------------------
-- Dead / out of range
-- ---------------------------------------------------------------------------

-- "out" / "in" / nil (unknown: secret or not checked).
function H.RangeState(inRange, checked)
    if inRange == nil or checked == false then return nil end
    return inRange == false and "out" or "in"
end

-- Previous state per unit name; returns the events to alert: "died" / "out".
function H.MemberStep(prev, dead, range)
    local ev
    if dead == true and not prev.dead then ev = "died"
    elseif dead == false and range == "out" and prev.range ~= "out" then ev = "out" end
    if dead ~= nil then prev.dead = dead end
    if range ~= nil then prev.range = range end
    return ev
end

H.members = {}

function H.CheckMembers()
    for _, u in ipairs(R.PartyUnits()) do
        local name = R.Name(u)
        if name then
            local prev = H.members[name]
            if not prev then prev = {}; H.members[name] = prev end
            local dead = R.B(_G.UnitIsDeadOrGhost, u)
            local range
            if type(_G.UnitInRange) == "function" then
                local ok, a, b = pcall(_G.UnitInRange, u)
                if ok and not BF.IsSecret(a) and not BF.IsSecret(b) then
                    range = H.RangeState(a, b)
                end
            end
            local ev = H.MemberStep(prev, dead, range)
            if ev == "died" then
                R.Alert("dead:" .. name, name .. " died", { gap = 10, ttl = 5, color = R.RED })
            elseif ev == "out" then
                R.Alert("range:" .. name, name .. " is out of range", { gap = 15, ttl = 4, color = R.YELLOW })
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- PvP-flag warning
-- ---------------------------------------------------------------------------

function H.PvpWarn(isPlayer, isFriend, targetPvp, mePvp)
    return isPlayer == true and isFriend == true and targetPvp == true and mePvp == false
end

function H.CheckPvp(unit)
    if not R.Opt("healPvp") or not R.Exists(unit) then return end
    if R.B(_G.UnitIsUnit, unit, "player") == true then return end
    local isPlayer = R.B(_G.UnitIsPlayer, unit)
    local isFriend = R.B(_G.UnitIsFriend, "player", unit)
    local theirs = R.B(_G.UnitIsPVP, unit)
    local mine = R.B(_G.UnitIsPVP, "player")
    if R.B(_G.UnitIsPVPFreeForAll, "player") == true then mine = true end
    if H.PvpWarn(isPlayer, isFriend, theirs, mine) then
        local n = R.Name(unit) or "That player"
        R.Alert("pvp:" .. n, n .. " is PvP flagged - you are not", { gap = 20, ttl = 5, color = R.YELLOW })
    end
end

-- ---------------------------------------------------------------------------
-- Row: Drink / OOM buttons + the secure tank frame
-- ---------------------------------------------------------------------------

-- The tank frame sits in the same strip, right of Drink / OOM, filling the rest of the inset width.
local TANK_X = 5 + 46 + 3 + 46 + 4
local TANK_W = (M.Metrics and M.Metrics.inner or 242) - TANK_X
local TANK_H = 22

function H.build(row)
    local b1 = R.Button(row, "GaarGroupForeverHealDrink", "Drink", 46, function() H.Post("Drinking") end, function()
        return { "Drinking", "Posts \"Drinking\" to party chat when you click." }
    end)
    b1:SetPoint("TOPLEFT", row, "TOPLEFT", 5, R.BTN_Y)
    local b2 = R.Button(row, "GaarGroupForeverHealOom", "OOM", 46, function() H.Post("OOM") end, function()
        return { "Out of mana", "Posts \"OOM\" to party chat when you click." }
    end)
    b2:SetPoint("LEFT", b1, "RIGHT", 3, 0)
    H.drinkButton, H.oomButton = b1, b2

    -- The tank frame: secure, created here (out of combat, guaranteed by R.BuildRow) as a child of UIParent
    -- laid over the row; R.SyncSecure shows, hides and places it out of combat only.
    -- Muted placeholder (plain, not secure) in the same spot while there is no tank, so the height stays fixed.
    local none = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    none:SetPoint("LEFT", row, "TOPLEFT", TANK_X + 4, R.BTN_Y - TANK_H / 2)
    none:SetText("No tank")
    H.noTank = none
    local f = R.Secure(row, TANK_X, R.BTN_Y, TANK_W, TANK_H, "SecureUnitButtonTemplate", "GaarGroupForeverTankFrame",
        function() return H.TankLive() end)
    if not f then return 56 * 2, R.ROW_H end
    f:RegisterForClicks("AnyUp")
    f:SetAttribute("type1", "target")
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    local hp = _G.CreateFrame("StatusBar", nil, f)
    hp:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    hp:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    hp:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    hp:SetStatusBarColor(0.2, 0.7, 0.3, 0.85)
    hp:SetMinMaxValues(0, 1)
    hp:SetValue(1)
    local name = hp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("LEFT", hp, "LEFT", 3, 0)
    name:SetWidth(math.floor(TANK_W * 0.55))
    name:SetJustifyH("LEFT")
    local tgt = hp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tgt:SetPoint("RIGHT", hp, "RIGHT", -3, 0)
    tgt:SetWidth(math.floor(TANK_W * 0.35))
    tgt:SetJustifyH("RIGHT")
    tgt:SetTextColor(1, 0.5, 0.5)
    f.hp, f.nameText, f.targetText = hp, name, tgt
    H.tankFrame = f
    return TANK_X + TANK_W, R.ROW_H
end

-- The tank the frame should show (option on and a party member has the TANK role), or nil.
function H.TankUnit() return R.Opt("healTankFrame") and R.UnitByRole("TANK") or nil end

-- Shown when there is a tank and the secure unit attribute already points at it.
function H.TankLive()
    local f, unit = H.tankFrame, H.TankUnit()
    return f ~= nil and unit ~= nil and f.unitSet == unit
end

-- Applies options and the current tank to the row. Only plain widgets in combat; the secure unit attribute
-- only out of combat (Show/Hide/placing: R.SyncSecure, out of combat only).
function H.refresh()
    if H.drinkButton then
        H.drinkButton:SetShown(R.Opt("healButtons"))
        H.oomButton:SetShown(R.Opt("healButtons"))
    end
    local f = H.tankFrame
    if not f then return end
    local unit = H.TankUnit()
    if H.noTank then H.noTank:SetShown(R.Opt("healTankFrame") and not (unit and f.unitSet == unit)) end
    if not R.InCombat() and unit ~= f.unitSet then
        f:SetAttribute("unit", unit)
        f.unitSet = unit
    end
    if unit and f.unitSet == unit then
        pcall(function()
            f.nameText:SetText(_G.UnitName(unit))
            local max = _G.UnitHealthMax(unit)
            f.hp:SetMinMaxValues(0, max)
            f.hp:SetValue(_G.UnitHealth(unit))
            f.targetText:SetText(_G.UnitName(unit .. "target") or "")
        end)
    end
end

function H.tick(now)
    -- Dispel alert
    if R.Opt("healDispel") then
        R.SetStatus("healDispel", H.DispelText(H.DispelEntries()), R.BLUE)
    else
        R.SetStatus("healDispel", nil)
    end
    if R.Opt("healDeadRange") then H.CheckMembers() end
    -- Auto-posts: only on a real change, and only with the option on.
    if R.Opt("healAutoDrink") then
        if H.DrinkStep(H.state.drink, H.IsDrinking()) == "post" and R.Throttle("autoDrink", 30, now) then
            R.Say("Drinking")
        end
    else
        H.state.drink.drinking = nil
    end
    if R.Opt("healAutoOom") then
        if H.OomStep(H.state.oom, R.ManaPct("player")) == "post" and R.Throttle("autoOom", 30, now) then
            R.Say("OOM")
        end
    else
        H.state.oom.low = nil
    end
end

function H.deactivate()
    H.members = {}
    H.state = { drink = {}, oom = {} }
end

H.events = {
    PLAYER_TARGET_CHANGED = function() H.CheckPvp("target") end,
    UPDATE_MOUSEOVER_UNIT = function() H.CheckPvp("mouseover") end,
}

function H.demo()
    R.Alert("demo:dead", "Mira died", { gap = 0, ttl = 6, color = R.RED })
    R.Alert("demo:range", "Bob is out of range", { gap = 0, ttl = 6, color = R.YELLOW })
    R.Alert("demo:pvp", "Kaz is PvP flagged - you are not", { gap = 0, ttl = 6, color = R.YELLOW })
    R.Alert("demo:dispel", "Dispel: Mira (Magic)", { gap = 0, ttl = 6, color = R.BLUE })
end

function H.help()
    return { "/ggf healer drink | oom - say it to party now", "/ggf healer test - show sample warnings" }
end

function H.slash(sub)
    if sub == "drink" then H.Post("Drinking"); return true end
    if sub == "oom" then H.Post("OOM"); return true end
end

R.Register("healer", H)
