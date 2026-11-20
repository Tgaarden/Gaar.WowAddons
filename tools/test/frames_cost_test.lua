-- LuaJIT stub test: GaarFramesForever 1.6.0 - spell cost segment on the player's power bar.
-- Run: luajit tools/test/frames_cost_test.lua   (from the repo root)
local path = "addons/GaarFramesForever/GaarFramesForever.lua"
local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { PCost = HealPred.Cost, SetDb = function(d) db = d end, SetReal = function(f) real.player = f end,"
    .. " OnHotCast = OnHotCast }\n"

local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end,
    __lt = function() error("compared a secret") end, __le = function() error("compared a secret") end,
    __add = function() error("arith on a secret") end, __sub = function() error("arith on a secret") end })
local noop = function() end
local function widget()
    local w
    w = setmetatable({ shown = true, text = "" }, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
    w.Show = function(s) s.shown = true end
    w.Hide = function(s) s.shown = false end
    w.IsShown = function(s) return s.shown end
    w.IsVisible = function(s) return s.shown end
    w.SetText = function(s, v) s.text = v end
    w.SetValue = function(s, v) s.value = v end
    w.SetMinMaxValues = function(s, a, b) s.min, s.max = a, b end
    w.GetStatusBarTexture = function(s) return s end
    w.GetFrameLevel = function() return 1 end
    return w
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
local ptype, cur, mx = 0, 500, 1000
G.UnitPowerType = function() return ptype, "MANA" end
G.UnitPower = function() return cur end
G.UnitPowerMax = function() return mx end
G.CreateFrame = widget
G.SlashCmdList = {}
G.GaarFramesForeverDB = {}
G.GameTooltip = widget()
G.UIParent = widget()
local costs = { [1] = { { type = 0, cost = 340 } }, [2] = { { type = 3, cost = 40 } }, [3] = { { type = 0, cost = SECRET } },
    [4] = { { type = 0, cost = 0 } } }
G.C_Spell = { GetSpellPowerCost = function(id) return costs[id] end }

local fn = loadstring(src, "@GFF"); setfenv(fn, G)
assert(pcall(fn, "GaarFramesForever", {}))
local T = G.__T
local P = T.PCost
local db = { powerCost = true, healPrediction = true }
T.SetDb(db)

local fails = 0
local function eq(name, got, want)
    local good = got == want
    print(string.format("%-62s got %-10s want %-10s %s", name, tostring(got), tostring(want), good and "ok" or "FAIL"))
    if not good then fails = fails + 1 end
end

local f = { unit = "player", key = "player", layout = { mp = 10 }, healthW = 100, power = widget(), powerShown = true }
P.Build(f)
T.SetReal(f)
local function start(id, cast) P.OnCast("UNIT_SPELLCAST_START", "player", cast or "c1", id); P.Update(f) end
local function stop(ev, cast, id) local ch = P.OnCast(ev, "player", cast or "c1", id or 1); P.Update(f); return ch end

eq("hidden before a cast", f.costFrame.shown, false)
eq("CostOf picks the power type entry", P.CostOf(1, 0), 340)
eq("CostOf: other type ignored", P.CostOf(2, 0), nil)
eq("CostOf: zero cost is none", P.CostOf(4, 0), nil)
eq("CostOf: unknown spell", P.CostOf(99, 0), nil)

start(1)
eq("shown on cast start", f.costFrame.shown, true)
eq("span: value is the cost", f.costBar.value, 340)
eq("span: max is the power max", f.costBar.max, 1000)
eq("number text", f.costText.text, "-340")
eq("light when enough power", f.costColor, "light")
eq("spent: cast clears on STOP", stop("UNIT_SPELLCAST_STOP"), true)
eq("hidden after STOP", f.costFrame.shown, false)

cur = 200
start(1)
eq("red when power < cost", f.costColor, "red")
stop("UNIT_SPELLCAST_FAILED")
eq("hidden after FAILED", f.costFrame.shown, false)
cur = 500
start(1); stop("UNIT_SPELLCAST_INTERRUPTED")
eq("hidden after INTERRUPTED", f.costFrame.shown, false)
start(1); stop("UNIT_SPELLCAST_SUCCEEDED")
eq("hidden after SUCCEEDED", f.costFrame.shown, false)
start(1); stop("UNIT_SPELLCAST_STOP", "other-cast")
eq("another cast's STOP leaves it", f.costFrame.shown, true)
stop("UNIT_SPELLCAST_STOP", "c1")
eq("own STOP clears it", f.costFrame.shown, false)

start(2)
eq("power type mismatch ignored", f.costFrame.shown, false)
ptype = 3; start(2)
eq("energy cost on energy", f.costFrame.shown, true)
stop("UNIT_SPELLCAST_STOP", "c1", 2); ptype = 0

-- secret values: no crash, no compare
cur = SECRET
start(1)
eq("secret power: still drawn", f.costFrame.shown, true)
eq("secret power: not red", f.costColor, "light")
stop("UNIT_SPELLCAST_STOP")
cur, mx = 500, SECRET
start(1)
eq("secret max: drawn (client scales it)", f.costFrame.shown, true)
stop("UNIT_SPELLCAST_STOP")
mx = 1000
start(3)
eq("secret cost: drawn", f.costFrame.shown, true)
eq("secret cost: no number", f.costText.text, "")
cur = 10
P.Update(f)
eq("secret cost: not red", f.costColor, "light")
stop("UNIT_SPELLCAST_STOP"); cur = 500

-- toggle off
db.powerCost = false
start(1)
eq("toggle off: nothing drawn", f.costFrame.shown, false)
db.powerCost = true
start(1)
db.powerCost = false; P.Update(f)
eq("toggle off mid-cast hides", f.costFrame.shown, false)
db.powerCost = true
-- other unit's cast ignored
P.OnCast("UNIT_SPELLCAST_STOP", "target", "c1", 1)
stop("UNIT_SPELLCAST_STOP")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
