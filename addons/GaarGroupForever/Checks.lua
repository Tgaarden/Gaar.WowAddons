--[[
  GaarGroupForever - Checks.lua: the pre-pull check.

  One button (Check, in the dock under the bar) or /ggf check opens a local report window: who is
  dead, offline, out of range, low on mana (under 50 percent, mana users only) and who lacks a key
  classic buff - Power Word: Fortitude, Arcane Intellect, Mark of the Wild, a Blessing - counted
  only when a class that can give it is in the party. The report is NOT sent to chat; the window's
  Announce button posts a short summary to PARTY, only on that click.

  Secret values: a mana or buff value the client keeps secret is skipped (that member is not
  judged on it); buffs are not read at all while you are in combat. A skipped check is said so in
  the report.
]]

local _G = _G
local API = _G.GaarGroupForeverAPI
local M = API and API._M
if not M then return end

local BF = _G.GaarForever
local IsSecret = BF.IsSecret

M.Defaults.checks = true

local C = {}
M.Checks = C

C.LOW_MANA = 0.5

-- The buffs worth a look. names: exact aura names; prefixes: any aura starting so. manaOnly: only
-- members with a mana bar need it.
C.BUFFS = {
    { id = "fort", label = "Power Word: Fortitude", class = "PRIEST",
      names = { ["Power Word: Fortitude"] = true, ["Prayer of Fortitude"] = true } },
    { id = "int", label = "Arcane Intellect", class = "MAGE", manaOnly = true,
      names = { ["Arcane Intellect"] = true, ["Arcane Brilliance"] = true } },
    { id = "motw", label = "Mark of the Wild", class = "DRUID",
      names = { ["Mark of the Wild"] = true, ["Gift of the Wild"] = true } },
    { id = "bless", label = "a Blessing", class = "PALADIN",
      prefixes = { "Blessing of ", "Greater Blessing of " } },
}

-- Does the aura name satisfy the buff?
function C.BuffMatches(def, aura)
    if type(aura) ~= "string" then return false end
    if def.names and def.names[aura] then return true end
    for _, p in ipairs(def.prefixes or {}) do
        if aura:sub(1, #p) == p then return true end
    end
    return false
end

-- buffs: set of aura names, nil when unknown.
function C.HasBuff(buffs, def)
    for aura in pairs(buffs) do
        if C.BuffMatches(def, aura) then return true end
    end
    return false
end

-- members: { { name, class, dead, offline, far, hasMana, mana (0..1 or nil), buffs (set or nil) } }
-- Returns the report: dead, offline, far = { names }; lowmana = { { name, pct } };
-- missing = { { label, names } }; unknown = number of members whose buffs could not be read.
function C.Evaluate(members, opts)
    opts = opts or {}
    local rep = { dead = {}, offline = {}, far = {}, lowmana = {}, missing = {}, unknown = 0,
        buffsSkipped = opts.buffsSkipped and true or false }
    local providers = {}
    for _, m in ipairs(members) do
        if m.class then providers[m.class] = true end
        if m.offline then
            rep.offline[#rep.offline + 1] = m.name
        elseif m.dead then
            rep.dead[#rep.dead + 1] = m.name
        else
            if m.far then rep.far[#rep.far + 1] = m.name end
            if m.hasMana and type(m.mana) == "number" and m.mana < C.LOW_MANA then
                rep.lowmana[#rep.lowmana + 1] = { name = m.name, pct = math.floor(m.mana * 100 + 0.5) }
            end
        end
    end
    if not rep.buffsSkipped then
        for _, m in ipairs(members) do
            if not m.offline and not m.dead and m.buffs == nil then rep.unknown = rep.unknown + 1 end
        end
        for _, def in ipairs(C.BUFFS) do
            if providers[def.class] then
                local names = {}
                for _, m in ipairs(members) do
                    if not m.offline and not m.dead and m.buffs ~= nil
                        and (not def.manaOnly or m.hasMana) and not C.HasBuff(m.buffs, def) then
                        names[#names + 1] = m.name
                    end
                end
                if #names > 0 then rep.missing[#rep.missing + 1] = { label = def.label, names = names } end
            end
        end
    end
    rep.ok = #rep.dead == 0 and #rep.offline == 0 and #rep.far == 0 and #rep.lowmana == 0 and #rep.missing == 0
    return rep
end

-- Short plain-text parts, in a fixed order: used for the window and for the chat summary.
function C.Parts(rep)
    local p = {}
    if #rep.dead > 0 then p[#p + 1] = "Dead: " .. table.concat(rep.dead, ", ") end
    if #rep.offline > 0 then p[#p + 1] = "Offline: " .. table.concat(rep.offline, ", ") end
    if #rep.far > 0 then p[#p + 1] = "Out of range: " .. table.concat(rep.far, ", ") end
    if #rep.lowmana > 0 then
        local l = {}
        for i, e in ipairs(rep.lowmana) do l[i] = e.name .. " " .. e.pct .. "%" end
        p[#p + 1] = "Low mana: " .. table.concat(l, ", ")
    end
    for _, e in ipairs(rep.missing) do
        p[#p + 1] = "No " .. e.label .. ": " .. table.concat(e.names, ", ")
    end
    return p
end

-- Chat messages for Announce: parts joined with "; ", split so none passes 250 characters.
function C.Chunks(rep)
    local prefix = "Pre-pull: "
    local parts = C.Parts(rep)
    if #parts == 0 then return { prefix .. "all clear" } end
    local out, cur = {}, prefix
    for _, part in ipairs(parts) do
        if #part > 240 then part = part:sub(1, 237) .. "..." end
        local joined = cur == prefix and (cur .. part) or (cur .. "; " .. part)
        if #joined > 250 then
            out[#out + 1] = cur
            cur = prefix .. part
        else
            cur = joined
        end
    end
    out[#out + 1] = cur
    return out
end

-- ---------------------------------------------------------------------------
-- Reading the group
-- ---------------------------------------------------------------------------

-- The names of the unit's helpful auras as a set, or nil when they cannot be read.
function C.ReadBuffs(unit)
    local set = {}
    local ua = _G.C_UnitAuras
    if type(ua) == "table" and type(ua.GetAuraDataByIndex) == "function" then
        for i = 1, 40 do
            local ok, d = pcall(ua.GetAuraDataByIndex, unit, i, "HELPFUL")
            if not ok or IsSecret(d) then return nil end
            if not d then break end
            local n = type(d) == "table" and d.name
            if IsSecret(n) or type(n) ~= "string" then return nil end
            set[n] = true
        end
        return set
    end
    if type(_G.UnitBuff) == "function" then
        for i = 1, 40 do
            local ok, n = pcall(_G.UnitBuff, unit, i)
            if not ok or IsSecret(n) then return nil end
            if not n then break end
            if type(n) ~= "string" then return nil end
            set[n] = true
        end
        return set
    end
    return nil
end

-- 0..1, or nil (no mana bar, or a value we may not read).
function C.ManaOf(unit)
    local ptype = M.Q(_G.UnitPowerType, unit)
    if ptype ~= 0 then return false, nil end
    local cur, mx = M.Q(_G.UnitPower, unit, 0), M.Q(_G.UnitPowerMax, unit, 0)
    if type(cur) ~= "number" or type(mx) ~= "number" or mx <= 0 then return true, nil end
    return true, cur / mx
end

function C.InCombat()
    return (M.Q(_G.InCombatLockdown) or M.Q(_G.UnitAffectingCombat, "player")) and true or false
end

function C.Gather()
    local O = M.Overview
    local members = {}
    local combat = C.InCombat()
    for _, unit in ipairs(O and O.Units() or {}) do
        local info = O.Member(unit)
        local m = { name = info.name, class = info.class, dead = info.dead, offline = info.status == "offline",
            far = info.status == "far" }
        m.hasMana, m.mana = C.ManaOf(unit)
        if not combat and not m.offline and not m.dead and info.visible ~= false then
            m.buffs = C.ReadBuffs(unit)
        end
        members[#members + 1] = m
    end
    return members, combat
end

function C.Run()
    local members, combat = C.Gather()
    return C.Evaluate(members, { buffsSkipped = combat }), #members
end

-- ---------------------------------------------------------------------------
-- Window and announce
-- ---------------------------------------------------------------------------

-- Sends the summary to PARTY (RAID in a raid). Only called from a click or /ggf check announce.
function C.Announce()
    if not M.InGroup() then return false, "You are not in a group." end
    if type(_G.SendChatMessage) ~= "function" then return false, "This client cannot send chat." end
    local rep = C.Run()
    local ch = M.InRaid() and "RAID" or "PARTY"
    for _, text in ipairs(C.Chunks(rep)) do pcall(_G.SendChatMessage, text, ch) end
    return true
end

function C.Lines(rep, n)
    local lines = {}
    if n == 0 then return { "No group to check." } end
    if rep.ok then lines[1] = "|cff40ff40All clear.|r" end
    for _, part in ipairs(C.Parts(rep)) do lines[#lines + 1] = part end
    if rep.buffsSkipped then lines[#lines + 1] = "|cff9d9d9dBuffs not checked in combat.|r"
    elseif rep.unknown > 0 then lines[#lines + 1] = "|cff9d9d9dBuffs unknown for " .. rep.unknown .. " member(s).|r" end
    return lines
end

function C.Open()
    if not C.win then
        local w = M.UI.Window("GaarGroupForeverCheck", "Pre-pull check", 300)
        w.AddButton("Refresh", function() C.Refresh() end)
        w.AddButton("Announce", function()
            local ok, why = C.Announce()
            if not ok then M.Print(why) end
        end)
        C.win = w
    end
    C.Refresh()
    C.win.Show()
end

function C.Refresh()
    if not C.win then return end
    local rep, n = C.Run()
    C.win.SetLines(C.Lines(rep, n))
end

-- ---------------------------------------------------------------------------
-- Dock button, menu, slash
-- ---------------------------------------------------------------------------

M.Dock.AddButton({ key = "Check", text = "Check", opt = "checks", click = C.Open,
    tip = { "Pre-pull check", "Lists who is dead, offline, out of range, low on mana or missing a key buff. Local only; the window has an Announce button for party chat." } })

M.MenuParts[#M.MenuParts + 1] = function()
    return {
        { text = "Pre-pull check button", checkbox = true,
          checked = function() return M.db.checks ~= false end,
          func = function() M.db.checks = M.db.checks == false; M.Refresh() end },
        { text = "Run the pre-pull check", func = C.Open },
    }
end

M.Slash.check = function(arg)
    if arg == "announce" then
        local ok, why = C.Announce()
        M.Print(ok and "summary sent to party chat." or why)
    else
        C.Open()
    end
end

M.HelpParts[#M.HelpParts + 1] = function()
    return { "/ggf check - the pre-pull report window (local); /ggf check announce - post the summary to party chat" }
end
