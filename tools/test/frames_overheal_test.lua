-- LuaJIT stub test: GaarFramesForever 1.5.0 - the heal layout with overheal past the bar
-- (HealLayout) and the HoT preview while you cast a HoT spell (start, stop, fail, hand-over).
-- Run: luajit tools/test/frames_overheal_test.lua   (from the repo root)
local path = "addons/GaarFramesForever/GaarFramesForever.lua"
local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { HealPred = HealPred, SetDb = function(d) db = d end }\n"

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
    NewAddon = function() return setmetatable({}, { __index = function() return noop end }) end,
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
G.UnitHealth = function() return 500 end
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

-- 1. HealLayout(cur, max, incoming, hot, overCap)
local L = HP.HealLayout(500, 1000, 200, 100, 0.3)
eq("no overflow: green 0.2", L.incomingWidthFrac, 0.2)
eq("no overflow: yellow 0.1", L.hotWidthFrac, 0.1)
eq("no overflow: over 0", L.overFrac, 0)
L = HP.HealLayout(800, 1000, 150, 150, 0.3)
eq("partial: green fits (0.15)", L.incomingWidthFrac, 0.15)
eq("partial: yellow cut to what is left (0.05)", L.hotWidthFrac, 0.05)
eq("partial: over 0.1, all HoT", L.overFrac, 0.1)
eq("partial: over heal part 0", L.overIncFrac, 0)
eq("partial: over HoT part 0.1", L.overHotFrac, 0.1)
L = HP.HealLayout(950, 1000, 150, 100, 0.3)
eq("green overflows: green 0.05", L.incomingWidthFrac, 0.05)
eq("green overflows: yellow 0", L.hotWidthFrac, 0)
eq("green overflows: over heal part 0.1", L.overIncFrac, 0.1)
eq("green overflows: over HoT part 0.1", L.overHotFrac, 0.1)
L = HP.HealLayout(1437, 1437, 0, 1064 / 1, 1)   -- full health, Regrowth's HoT only
eq("full health: nothing in the bar", L.incomingWidthFrac + L.hotWidthFrac, 0)
eq("full health: all of it over (1064/1437)", L.overFrac, math.floor(1064 / 1437 * 1000 + 0.5) / 1000)
L = HP.HealLayout(1000, 1000, 400, 300, 0.3)
eq("cap: over cut to 0.3", L.overFrac, 0.3)
eq("cap: heal part first (0.3)", L.overIncFrac, 0.3)
eq("cap: HoT part squeezed out (0)", L.overHotFrac, 0)
L = HP.HealLayout(1000, 1000, 100, 300, 0.3)
eq("cap: heal 0.1 then HoT 0.2", L.overHotFrac, 0.2)
L = HP.HealLayout(1000, 1000, nil, nil, 0.3)
eq("absent heals count as 0", L.overFrac, 0)
eq("secret health: nil", HP.HealLayout(SECRET, 1000, 0, 100, 0.3), nil)
eq("secret incoming: nil", HP.HealLayout(500, 1000, SECRET, 100, 0.3), nil)
eq("max 0: nil", HP.HealLayout(0, 0, 0, 0, 0.3), nil)
-- The yellow in the bar is the same cut as ClampHot.
local same = true
for _, c in ipairs({ { 500, 300, 400 }, { 800, 300, 150 }, { 0, 0, 5000 }, { 990, 5, 50 } }) do
    local l = HP.HealLayout(c[1], 1000, c[2], c[3], 0.3)
    if math.abs(l.hotWidthFrac * 1000 - (HP.ClampHot(c[3], 1000, c[1], c[2]))) > 1e-9 then same = false end
end
eq("yellow in the bar equals ClampHot", same, true)

-- 2. Cast preview.
local function healing(u)
    local line = HP.HotLines(u or "target")[1]
    return tonumber(line:match("HoTs will heal (%d+)")), line
end
local function lines(u) return table.concat(HP.HotLines(u or "target"), "\n") end
eq("before the cast: no HoT", (healing()), nil)
-- Regrowth rank 1 on the target, by name: base 14 x 7 = 98, direct 100 (93-107).
HP.OnCast("UNIT_SPELLCAST_SENT", "player", "Tank", "c1", 8936)
eq("SENT alone shows nothing yet", (healing()), nil)
local g = HP.OnCast("UNIT_SPELLCAST_START", "player", "c1", 8936)
eq("START returns the target's GUID", g, "GUID-target")
eq("during the cast: the HoT shows (98)", (healing()), 98)
eq("hotdebug names the preview", lines():find("cast preview: Regrowth", 1, true) ~= nil, true)
eq("preview direct part from the rank base (100)", HP.CastPreview(now).direct, 100)
eq("not on the player's frame", (healing("player")), nil)
-- A failed attempt at another cast (spam) does not clear it.
HP.OnCast("UNIT_SPELLCAST_FAILED", "player", "c2", 774)
eq("FAILED of another cast: still 98", (healing()), 98)
-- Stop: gone.
eq("STOP returns the GUID to redraw", HP.OnCast("UNIT_SPELLCAST_STOP", "player", "c1", 8936), "GUID-target")
eq("after STOP: nothing", (healing()), nil)
-- Interrupted: gone.
HP.OnCast("UNIT_SPELLCAST_SENT", "player", "Tank", "c3", 8936)
HP.OnCast("UNIT_SPELLCAST_START", "player", "c3", 8936)
eq("again during the cast: 98", (healing()), 98)
HP.OnCast("UNIT_SPELLCAST_INTERRUPTED", "player", "c3", 8936)
eq("after INTERRUPTED: nothing", (healing()), nil)
-- Succeeded: the preview hands over to the cast memory, counted once; STOP after it is harmless.
HP.OnCast("UNIT_SPELLCAST_SENT", "player", "Tank", "c4", 8936)
HP.OnCast("UNIT_SPELLCAST_START", "player", "c4", 8936)
now = 1002
HP.OnCast("UNIT_SPELLCAST_SENT", "player", "Me", "c5", 774)   -- another SENT before SUCCEEDED
HP.OnCast("UNIT_SPELLCAST_SUCCEEDED", "player", "c4", 8936)
HP.OnCast("UNIT_SPELLCAST_STOP", "player", "c4", 8936)
eq("SUCCEEDED: handed over, still 98 (not 196)", (healing()), 98)
eq("  no preview left", HP.CastPreview(now), nil)
eq("  on the cast's own target, not the later SENT", (healing("player")), nil)
-- The real aura becomes readable: it counts, the cast does not.
now = 1002.5
auras = { { spellId = 8936, name = "Regrowth", points = { 0, 14 }, duration = 21, expirationTime = 1023.4,
    sourceUnit = "player", auraInstanceID = 5 } }
eq("aura read: counted once (98)", (healing()), 98)
-- Recast while that aura ticks: the preview replaces it, not on top of it.
now = 1009   -- two ticks landed: 5 x 14 = 70 left
eq("aura after two ticks: 70", (healing()), 70)
HP.OnCast("UNIT_SPELLCAST_SENT", "player", "Tank", "c6", 8936)
HP.OnCast("UNIT_SPELLCAST_START", "player", "c6", 8936)
eq("recast preview replaces your own Regrowth: 98, not 168", (healing()), 98)
HP.OnCast("UNIT_SPELLCAST_STOP", "player", "c6", 8936)
eq("stopped: the old one again (70)", (healing()), 70)
auras = {}
now = 1100
-- Amount from the spell description of rank 2 (no reading of it yet).
desc[8938] = "Heals a friendly target for 176 to 201 and another 175 over 21 sec."
HP.OnCast("UNIT_SPELLCAST_SENT", "player", "Tank", "c7", 8938)
HP.OnCast("UNIT_SPELLCAST_START", "player", "c7", 8938)
eq("rank 2 from its description: 175", (healing()), 175)
eq("  source says spell description", HP.CastPreview(now).source, "spell description")
eq("  direct part from the description (188.5)", HP.CastPreview(now).direct, 188.5)
HP.OnCast("UNIT_SPELLCAST_STOP", "player", "c7", 8938)
-- No target name: friendly target, else (enemy target) yourself.
canAssist = false
HP.OnCast("UNIT_SPELLCAST_SENT", "player", nil, "c8", 8936)
HP.OnCast("UNIT_SPELLCAST_START", "player", "c8", 8936)
eq("enemy target, no name: self-cast on the player (98)", (healing("player")), 98)
eq("  not on the target", (healing("target")), nil)
HP.OnCast("UNIT_SPELLCAST_STOP", "player", "c8", 8936)
canAssist = true
HP.OnCast("UNIT_SPELLCAST_SENT", "player", nil, "c9", 8936)
HP.OnCast("UNIT_SPELLCAST_START", "player", "c9", 8936)
eq("friendly target, no name: on the target (98)", (healing("target")), 98)
HP.OnCast("UNIT_SPELLCAST_STOP", "player", "c9", 8936)
-- /gff hotcast off: not shown; a missed STOP is dropped after 10 s.
db.hotCastPreview = false
HP.OnCast("UNIT_SPELLCAST_SENT", "player", "Tank", "c10", 8936)
HP.OnCast("UNIT_SPELLCAST_START", "player", "c10", 8936)
eq("hotcast off: nothing", (healing()), nil)
db.hotCastPreview = true
eq("hotcast on again, same cast: 98", (healing()), 98)
now = now + 11
eq("no STOP for 11 s: dropped", (healing()), nil)

print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
