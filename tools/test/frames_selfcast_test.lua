-- LuaJIT stub test: GaarFramesForever 1.5.2 - a Regrowth cast on yourself, whole way through
-- HealPred.Update on the player frame, and the /gff hotdebug cast summary and trace.
-- Run: luajit tools/test/frames_selfcast_test.lua   (from the repo root)
local path = "addons/GaarFramesForever/GaarFramesForever.lua"
local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { HealPred = HealPred, real = real, OnHotCast = OnHotCast, SetDb = function(d) db = d end }\n"

OUT = {}
local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
local function IsSecret(v) return v == SECRET end
G.GaarForever = {
    NewAddon = function() return setmetatable({ Print = function(_, m) OUT[#OUT + 1] = tostring(m) end }, { __index = function() return noop end }) end,
    OnOff = tostring, ShortNumber = tostring, InCombat = function() return false end,
    IsSecret = IsSecret,
    Plain = function(v) if IsSecret(v) then return nil end return v end,
    Num = function(v) if IsSecret(v) or type(v) ~= "number" then return nil end return v end,
}
local now = 1000
G.GetTime = function() return now end
G.UnitExists = function() return true end
G.UnitGUID = function(u) return "GUID-" .. u end
G.UnitName = function(u) return u == "target" and "Tank" or "Me" end
G.UnitIsUnit = function(a, b) return a == b end
local canAssist = true
G.UnitCanAssist = function() return canAssist end
G.UnitHealthMax = function() return 1000 end
local health = 500
G.UnitHealth = function() return health end
G.UnitIsDeadOrGhost = function() return false end
G.UnitClass = function() return "Druid", "DRUID" end
G.CreateFrame = widget
G.SlashCmdList = {}
G.GaarFramesForeverDB = {}
G.GameTooltip = widget()
G.UIParent = widget()
local desc = {}
G.C_Spell = {
    GetSpellName = function(id) return ({ [774] = "Rejuvenation", [8936] = "Regrowth", [8938] = "Regrowth", [139] = "Renew" })[id] end,
    GetSpellDescription = function(id) return desc[id] end,
}
local auras = {}
G.C_UnitAuras = {
    GetAuraDataByIndex = function(_, i) return auras[i] end,
    GetAuraDataByAuraInstanceID = function(_, iid)
        for _, a in ipairs(auras) do if a.auraInstanceID == iid then return a end end
        return nil
    end,
}
G.C_Secrets = { ShouldUnitAuraIndexBeSecret = function() return false end }
G.C_TooltipInfo = {}

local f = loadstring(src, "@GFF"); setfenv(f, G)
local ok, err = pcall(f, "GaarFramesForever", {})
assert(ok, "load: " .. tostring(err))
local HP = G.__T.HealPred
local db = { hotPred = true, healPrediction = true, hotCastPreview = true, overheal = true, overhealCap = 0.3 }
G.__T.SetDb(db)


local fails = 0
local function eq(name, got, want)
    if type(got) == "number" then got = math.floor(got * 1000 + 0.5) / 1000 end
    local good = got == want
    print(string.format("%-62s got %-10s want %-10s %s", name, tostring(got), tostring(want), good and "ok" or "FAIL"))
    if not good then fails = fails + 1 end
end

-- A recording stand-in for a bar.
local function bar()
    local b = { shown = false, value = 0, w = 0 }
    function b:Show() self.shown = true end
    function b:Hide() self.shown = false end
    function b:IsShown() return self.shown end
    function b:SetValue(v) self.value = v end
    function b:SetWidth(w) self.w = w end
    function b:SetMinMaxValues() end
    function b:ClearAllPoints() end
    function b:SetPoint() end
    function b:GetStatusBarTexture() return self end
    return b
end
local pf = { unit = "player", healthW = 200, health = bar(), healPred = {}, overFrame = bar() }
for _, k in ipairs({ "all", "mine", "hot", "absorb", "healAbsorb", "overInc", "overHot" }) do pf.healPred[k] = bar() end
pf.hotAt, pf.absorbAt = pf.healPred.all, pf.healPred.hot
function pf:IsVisible() return true end
G.__T.real.player = pf
G.UnitGetIncomingHeals = function(u, who) if who then return 120 end return 120 end   -- the client has your direct heal

-- At 500/1000 health, Regrowth rank 1 on yourself (by your own name): green 120 + yellow in the bar.
HP.OnCast("UNIT_SPELLCAST_SENT", "player", "Me", "z1", 8936)
G.__T.OnHotCast("UNIT_SPELLCAST_SENT", "player", "Me", "z1", 8936)
G.__T.OnHotCast("UNIT_SPELLCAST_START", "player", "z1", 8936)
eq("self-cast: preview is on the player's GUID", HP.CastPreview(now).guid, "GUID-player")
eq("self-cast: the yellow bar shows", pf.healPred.hot.shown, true)
eq("self-cast: yellow = the full HoT (98)", pf.healPred.hot.value, 98)
-- Nearly full: the yellow in the bar is cut, the rest hangs past the bar's end.
health = 950
G.__T.OnHotCast("UNIT_SPELLCAST_START", "player", "z1", 8936)
eq("near full: HoT past the bar (overHot shown)", pf.healPred.overHot.shown, true)
-- Full health.
health = 1000
G.UnitGetIncomingHeals = function() return 0 end
G.__T.OnHotCast("UNIT_SPELLCAST_START", "player", "z1", 8936)
eq("full health: all HoT past the bar (overHot shown)", pf.healPred.overHot.shown, true)
local sum = table.concat(HP.CastSummary(), "\n")
eq("summary names the spell", sum:find("Regrowth", 1, true) ~= nil, true)
eq("summary names the player frame", sum:find("frame player", 1, true) ~= nil, true)
HP.OnCast("UNIT_SPELLCAST_STOP", "player", "z1", 8936)
-- hotdebug: last line is the cast summary, auras one short line each.
auras = { { spellId = 5234, name = "Mark of the Wild" } }
OUT = {}
HP.HotDebug("player")
eq("hotdebug: last line is the cast summary", OUT[#OUT]:find("^CAST") ~= nil, true)
local mark
for _, l in ipairs(OUT) do if l:find("5234 Mark of the Wild - not HoT", 1, true) then mark = true end end
eq("hotdebug: one short line per aura", mark, true)
-- hotdebug cast: armed trace prints on SENT, START and the end.
OUT = {}
HP.HotDebug("cast")
health = 500
G.UnitGetIncomingHeals = function() return 120 end
G.__T.OnHotCast("UNIT_SPELLCAST_SENT", "player", "Me", "z2", 8936)
G.__T.OnHotCast("UNIT_SPELLCAST_START", "player", "z2", 8936)
G.__T.OnHotCast("UNIT_SPELLCAST_STOP", "player", "z2", 8936)
local t = table.concat(OUT, "\n")
eq("trace: SENT line", t:find("trace SENT: spell 8936", 1, true) ~= nil, true)
eq("trace: START line with the summary", t:find("trace START", 1, true) ~= nil and t:find("CAST: Regrowth", 1, true) ~= nil, true)
eq("trace: end line", t:find("trace STOP", 1, true) ~= nil, true)
OUT = {}
G.__T.OnHotCast("UNIT_SPELLCAST_SENT", "player", "Me", "z3", 8936)
eq("trace: disarmed after one cast", #OUT, 0)

-- 1.5.3: surnames. SENT gives "First Surname"; UnitName gives only the first name.
local names = { player = "Dru", target = "Tank", party1 = "Bob" }
local fulls = { player = "Dru Tics", party1 = "Bob Smith" }
local realms = { party2 = "Realm" }
names.party2 = "Carl"
G.UnitExists = function(u) return names[u] ~= nil end
G.UnitName = function(u) return names[u], realms[u] end
G.UnitFullName = function(u) return fulls[u] or names[u], realms[u] end
G.GetUnitName = function(u, withRealm) if withRealm and realms[u] then return names[u] .. "-" .. realms[u] end return fulls[u] or names[u] end
G.UnitCanAssist = function() return true end
local function who(name)
    HP.OnCast("UNIT_SPELLCAST_SENT", "player", name, "n1", 8936)
    local g = HP.OnCast("UNIT_SPELLCAST_START", "player", "n1", 8936)
    HP.OnCast("UNIT_SPELLCAST_STOP", "player", "n1", 8936)
    return g
end
eq("surname self: 'Dru Tics' -> player", who("Dru Tics"), "GUID-player")
eq("surname party member: 'Bob Smith' -> party1", who("Bob Smith"), "GUID-party1")
eq("realm suffix: 'Carl-Realm' -> party2", who("Carl-Realm"), "GUID-party2")
eq("exact first name still works", who("Tank"), "GUID-target")
fulls.player = nil   -- the client only gives the first name: prefix match, unique
eq("prefix only: 'Dru Tics' -> player", who("Dru Tics"), "GUID-player")

print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
