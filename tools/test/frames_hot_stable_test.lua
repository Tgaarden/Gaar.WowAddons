-- LuaJIT stub test: GaarFramesForever HoT prediction (1.4.4) - ticks left around tick
-- boundaries, the stable per-tick amount, the one clamp, and the HoT memory through combat.
-- Run: luajit tools/test/frames_hot_stable_test.lua   (from the repo root)
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
G.C_Spell = { GetSpellName = function(id) return ({ [774] = "Rejuvenation", [8936] = "Regrowth", [139] = "Renew" })[id] end }

-- Auras on "target": a list of aura tables; secretAll makes every index secret (combat).
local auras, secretAll = {}, false
G.C_UnitAuras = {
    GetAuraDataByIndex = function(_, i) return auras[i] end,
    GetAuraDataByAuraInstanceID = function(_, iid)
        if secretAll then return SECRET end
        for _, a in ipairs(auras) do if a.auraInstanceID == iid then return a end end
        return nil
    end,
}
G.C_Secrets = { ShouldUnitAuraIndexBeSecret = function() return secretAll end }
G.C_TooltipInfo = {}   -- no tooltip reads: amounts come from points or stand-ins

local f = loadstring(src, "@GFF"); setfenv(f, G)
local ok, err = pcall(f, "GaarFramesForever", {})
assert(ok, "load: " .. tostring(err))
local HP = G.__T.HealPred
G.__T.SetDb({ hotPred = true, healPrediction = true })

local fails = 0
local function eq(name, got, want)
    local good = got == want
    print(string.format("%-58s got %-10s want %-10s %s", name, tostring(got), tostring(want), good and "ok" or "FAIL"))
    if not good then fails = fails + 1 end
end

-- 1. Ticks left: Renew-like, 15 s, every 3 s, applied at 100 (ticks at 103 ... 115).
local T = HP.TicksLeft
eq("just applied: 5 ticks", (T(100, 115, 15, 3)), 5)
eq("0.2 s before the first tick: still 5", (T(102.8, 115, 15, 3)), 5)
eq("0.05 s before the first tick (slack): 4", (T(102.95, 115, 15, 3)), 4)
eq("just after the first tick: 4", (T(103.01, 115, 15, 3)), 4)
eq("between ticks 3 and 4: 2", (T(110, 115, 15, 3)), 2)
eq("after the last tick: 0", (T(114.95, 115, 15, 3)), 0)
eq("expired: 0", (T(116, 115, 15, 3)), 0)
local _, nxt = T(100, 115, 15, 3)
eq("next drop is just before the first tick", math.floor(nxt * 100 + 0.5) / 100, 102.9)
-- Duration not a whole number of ticks (14 s every 3 s: ticks at 103, 106, 109, 112).
eq("14 s HoT after its 4th tick: 0 (no phantom tick)", (T(112.5, 114, 14, 3)), 0)
eq("14 s HoT just applied: 4", (T(100, 114, 14, 3)), 4)
-- Never goes up as time passes, and drops exactly once per tick.
local prev, drops, rose = 99, 0, false
for t = 100, 115.5, 0.01 do
    local n = T(t, 115, 15, 3)
    if n > prev then rose = true end
    if n < prev and prev ~= 99 then drops = drops + 1 end
    prev = n
end
eq("ticks left never rise over the HoT's life", rose, false)
eq("ticks left drop once per tick (5 drops)", drops, 5)
-- No duration: counted back from the expiration.
eq("no duration: 5 ticks with 15 s left", (T(100, 115, nil, 3)), 5)
eq("no duration: 4 ticks with 12.05 s left", (T(102.95, 115, nil, 3)), 4)

-- 2. Stable amount.
local e = {}
eq("points 61: from points", select(3, HP.StableAmount(e, 61, 3)), "points")
eq("points secret next update: kept 61", (HP.StableAmount(e, nil, 3)), 61)
eq("  source says cached", select(3, HP.StableAmount(e, nil, 3)), "cached points")
eq("points readable again (70): 70", (HP.StableAmount(e, 70, 3)), 70)
local e2 = { per = 55, interval = 3, source = "tooltip" }
eq("tooltip amount kept when points stay unreadable", (HP.StableAmount(e2, nil, 3)), 55)
eq("nothing read yet: nil", (HP.StableAmount({}, nil, 3)), nil)

-- 3. Clamp.
eq("clamp to missing after incoming (1000-500-300)", (HP.ClampHot(400, 1000, 500, 300)), 200)
eq("fits: unchanged", (HP.ClampHot(150, 1000, 500, 300)), 150)
eq("incoming fills the gap: 0", (HP.ClampHot(150, 1000, 800, 300)), 0)
eq("health secret: not cut", (HP.ClampHot(150, 1000, SECRET, 0)), 150)
eq("health secret: cut to max only", (HP.ClampHot(1500, 1000, SECRET, 0)), 1000)
eq("same inputs, same output", (HP.ClampHot(400, 1000, 500, 300)), (HP.ClampHot(400, 1000, 500, 300)))

-- 4. HoT memory: a Rejuvenation read out of combat, then combat (auras secret).
local function healing()
    local line = HP.HotLines("target")[1]
    return tonumber(line:match("HoTs will heal (%d+)")), line
end
now = 1000
auras = { { spellId = 774, name = "Rejuvenation", points = { 61 }, duration = 12, expirationTime = 1012,
    sourceUnit = "player", auraInstanceID = 7 } }
eq("out of combat: 4 ticks x 61", (healing()), 244)
secretAll = true
now = 1001
eq("combat, auras secret: still 244 from memory", (healing()), 244)
now = 1004
eq("combat, after one tick: 183", (healing()), 183)
now = 1012.5
eq("combat, run out: nothing", (healing()), nil)
-- Own cast in combat: SENT names the target, SUCCEEDED confirms; amount from the last reading.
now = 1020
HP.OnCast("UNIT_SPELLCAST_SENT", "player", "Tank", "cast-1", 774)
HP.OnCast("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 774)
eq("combat cast of Rejuvenation on the target: 244", (healing()), 244)
-- The real aura becomes readable: it counts, the cast does not count again.
secretAll = false
now = 1020.5
auras = { { spellId = 774, name = "Rejuvenation", points = { 61 }, duration = 12, expirationTime = 1032.4,
    sourceUnit = "player", auraInstanceID = 9 } }
eq("aura read after the cast: counted once (244)", (healing()), 244)
-- Points empty and no tooltip: stand-in from the rank's last reading, not nothing.
now = 1040
auras = { { spellId = 774, name = "Rejuvenation", points = {}, duration = 12, expirationTime = 1052,
    sourceUnit = "player", auraInstanceID = 11 } }
eq("no points, no tooltip: last reading of the rank (244)", (healing()), 244)
-- Unknown rank amount and no reading: the rank base.
auras = { { spellId = 8936, name = "Regrowth", points = {}, duration = 21, expirationTime = 1061,
    sourceUnit = "party1", auraInstanceID = 12 } }
eq("Regrowth r1, nothing readable: base 14 x 7 = 98", (healing()), 98)
-- Recast in combat over a remembered Rejuvenation: the new one replaces it, no double count.
now = 1100
secretAll = false
auras = { { spellId = 774, name = "Rejuvenation", points = { 61 }, duration = 12, expirationTime = 1112,
    sourceUnit = "player", auraInstanceID = 20 } }
eq("fresh Rejuvenation before combat: 244", (healing()), 244)
secretAll = true
now = 1106.5   -- two ticks landed, two left (122)
HP.OnCast("UNIT_SPELLCAST_SENT", "player", "Tank", "cast-2", 774)
HP.OnCast("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-2", 774)
eq("recast in combat: 244, not 244 + 122", (healing()), 244)
secretAll = false
auras = { { spellId = 8936, name = "Regrowth", points = {}, duration = 21, expirationTime = 1121,
    sourceUnit = "party1", auraInstanceID = 21 } }
local dbg = table.concat(HP.HotLines("target"), "\n")
eq("hotdebug line names the stand-in source", dbg:find("rank base", 1, true) ~= nil, true)

print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
