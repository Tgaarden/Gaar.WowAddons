-- LuaJIT stub test: GaarFramesForever pet health bar colour by happiness.
-- Run: luajit tools/test/frames_pet_happy_test.lua   (from the repo root)
local path = "addons/GaarFramesForever/GaarFramesForever.lua"
local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { UpdateHealth = UpdateHealth, SetDb = function(d) db = d end }\n"

local happy, unitName = 3, "pet"
local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local G = setmetatable({}, { __index = function(t, k)
    if _G[k] ~= nil then return _G[k] end
    return nil end })
G._G = G
G.GaarForever = {
    NewAddon = function() return setmetatable({}, { __index = function() return noop end }) end,
    OnOff = tostring, ShortNumber = tostring, InCombat = function() return false end, IsSecret = function() return false end,
    Plain = function(v) return v end,
    Num = function(v) return type(v) == "number" and v or nil end,
}
G.GetPetHappiness = function() return happy, 3, 1 end
G.UnitClass = function() return "Hunter", "HUNTER" end
G.UnitExists = function() return true end
G.UnitHealthMax = function() return 100 end
G.UnitHealth = function() return 80 end
G.UnitIsConnected = function() return true end
G.UnitIsDeadOrGhost = function() return false end
G.UnitIsPlayer = function() return false end
G.UnitIsTapDenied = function() return false end
G.UnitReaction = function() return 5 end
G.UnitPower = function() return 0 end
G.UnitPowerMax = function() return 0 end
G.CreateFrame = widget
G.SlashCmdList = {}
G.GaarFramesForeverDB = {}
G.GameTooltip = widget()
G.UIParent = widget()
G.CreateColor = function(r, g, b, a)
    local c = { r = r, g = g, b = b, a = a }
    function c:SetRGBA(r2, g2, b2, a2) self.r, self.g, self.b, self.a = r2, g2, b2, a2 end
    return c
end
local f = loadstring(src, "@GFF"); setfenv(f, G)
local ok, err = pcall(f, "GaarFramesForever", {})
assert(ok, "load: " .. tostring(err))
local T = G.__T

-- A status bar whose texture records the gradient; the final colour is the gradient's base.
local function newBar()
    local tex = { }
    function tex:SetGradient(o, lo, hi) self.lo = { lo.r, lo.g, lo.b }; self.hi = { hi.r, hi.g, hi.b } end
    local bar = { text = { SetText = noop, SetFormattedText = noop, GetStringWidth = function() return 10 end }, flat = nil }
    function bar:GetStatusBarTexture() return tex end
    function bar:SetStatusBarColor(r, g, b) self.flat = { r, g, b } end
    bar.SetMinMaxValues, bar.SetValue = noop, noop
    function bar:GetWidth() return 100 end
    bar.tex = tex
    return bar
end
local function final(bar)   -- colour the user would see: the gradient's mid-point, or the flat colour
    if bar.tex.lo then
        local m = {}
        for i = 1, 3 do m[i] = (bar.tex.lo[i] + bar.tex.hi[i]) / 2 end
        return m
    end
    return bar.flat
end

local fails = 0
local function near(a, b) return math.abs(a - b) < 0.12 end   -- gradient mid-point ~ base colour
local function check(name, bar, want)
    local c = final(bar)
    local good = c and near(c[1], want[1]) and near(c[2], want[2]) and near(c[3], want[3])
    print(string.format("%-34s got %s want %s  %s", name,
        c and string.format("%.2f,%.2f,%.2f", c[1], c[2], c[3]) or "nil",
        string.format("%.2f,%.2f,%.2f", want[1], want[2], want[3]), good and "ok" or "FAIL"))
    if not good then fails = fails + 1 end
end

local function run(frame, h)
    happy = h
    T.UpdateHealth(frame)
end
local function mkframe(key, unit, withFace)
    return { key = key, unit = unit, health = newBar(), happyFrame = withFace and {} or nil }
end

T.SetDb({ petHappiness = true, text = true, classColor = true })
local want = { { 0.9, 0.15, 0.1 }, { 1, 0.85, 0.1 }, { 0.1, 0.8, 0.1 } }
local names = { "Unhappy", "Content", "Happy" }
for _, h in ipairs({ 3, 2, 1, 3 }) do   -- same bar, levels changing, as in game
    local pet = mkframe("pet", "pet", true)
    run(pet, h); check("fresh pet bar, " .. names[h], pet.health, want[h])
end
local pet = mkframe("pet", "pet", true)
for _, h in ipairs({ 3, 2, 1, 3 }) do run(pet, h); check("same pet bar, " .. names[h], pet.health, want[h]) end

local normal = { 0, 0.6, 0.1 }   -- friendly reaction
local tgt = mkframe("target", "target", false); run(tgt, 3); check("target frame keeps normal", tgt.health, normal)
local prev = mkframe("pet", "pet", true); prev.preview = true; run(prev, 3); check("preview pet keeps normal", prev.health, normal)
T.SetDb({ petHappiness = false, text = true, classColor = true })
local off = mkframe("pet", "pet", true); run(off, 3); check("setting off keeps normal", off.health, normal)
-- Happy.Level hidden (no hunter pet): normal colour
G.UnitExists = function() return false end
T.SetDb({ petHappiness = true, text = true, classColor = true })
local nope = mkframe("pet", "pet", true); run(nope, 3); check("no pet keeps normal", nope.health, normal)
print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
