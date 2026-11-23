-- LuaJIT stub test: GaarPlatesForever level colour by difficulty (LevelColor / UpdateText).
-- Run: luajit tools/test/plates_levelcolor_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarPlatesForever/GaarPlatesForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. [==[
_G.__T = { UpdateText = UpdateText, LevelColor = LevelColor, SetDB = function(v) db = v end }
]==]
local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local SECRET = {}
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.GaarForever = {
    NewAddon = function() return setmetatable({}, { __index = function() return noop end }) end,
    IsSecret = function(v) return v == SECRET end,
    Plain = function(v) if v ~= SECRET then return v end end,
    Num = function(v) return type(v) == "number" and v or nil end,
    OnOff = function(v) return v and "on" or "off" end,
    Migrate = noop, RenderMenu = noop,
}
G.CreateFrame = widget
G.hooksecurefunc = noop
G.SlashCmdList = {}
G.GetTime = function() return 100 end
G.C_Timer = { After = noop }
G.UnitName = function() return "Mob" end
G.UnitExists = function() return false end
local level, calls = 33, {}
G.UnitLevel = function(u) if u == "player" then return 30 end return level end
G.GaarForever.LevelDifficultyColor = function(l, mine)
    local d = l - mine
    if d >= 5 then return 1, 0.1, 0.1 end
    if d >= 3 then return 1, 0.5, 0.25 end
    if d >= -2 then return 1, 0.82, 0 end
    if d >= -8 then return 0.25, 0.75, 0.25 end
    return 0.6, 0.6, 0.6
end
G.GetCreatureDifficultyColor = function(l) calls[#calls + 1] = l; return { r = 0.1, g = 0.2, b = 0.3 } end
local f = assert(loadstring(src, "plates")); setfenv(f, G); f("GaarPlatesForever")
local T = G.__T

local fails = 0
local function eq(a, b, msg)
    if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": got " .. tostring(a) .. " want " .. tostring(b)) end
end
local function overlay()
    local o = { name = { SetText = noop, SetTextColor = noop }, tot = { SetText = noop } }
    o.level = { SetText = function(_, t) o.text = t end, SetTextColor = function(_, r, g, b) o.col = { r, g, b } end }
    return o
end
local function run(lvl, on)
    level = lvl; calls = {}
    T.SetDB({ levelColor = on, colorMode = "reaction", tot = false })
    local o = overlay(); T.UpdateText(o, "nameplate1"); return o
end

-- Colour comes from the shared classic bands (player 30), NOT GetCreatureDifficultyColor.
local o = run(33, true)
eq(o.text, "33", "text"); eq(#calls, 0, "retail api not used")
eq(o.col[1], 1, "orange r"); eq(o.col[2], 0.5, "orange g")
o = run(22, true); eq(o.col[1], 0.25, "green band r (-8)"); eq(o.col[2], 0.75, "green band g")
o = run(21, true); eq(o.col[1], 0.6, "grey r (-9)")
o = run(30, true); eq(o.col[2], 0.82, "yellow")

-- Skull level: red, API not needed.
o = run(-1, true)
eq(o.text, "??", "skull text"); eq(o.col[1], 1, "skull r"); eq(o.col[2], 0.1, "skull g"); eq(#calls, 0, "skull no api")

-- Secret level: nothing compared, API untouched, default white, no crash.
o = run(SECRET, true)
eq(o.text, "??", "secret text"); eq(#calls, 0, "secret no api")
eq(o.col[1], 1, "secret white r"); eq(o.col[2], 1, "secret white g"); eq(o.col[3], 1, "secret white b")

-- Toggle off: default colour, API untouched.
o = run(33, false)
eq(o.col[1], 1, "off r"); eq(o.col[2], 1, "off g"); eq(o.col[3], 1, "off b"); eq(#calls, 0, "off no api")

-- Unknown player level: default white.
G.UnitLevel = function(u) if u == "player" then return nil end return level end
local w = T.LevelColor(33); eq(w, 1, "no player level white")

if fails == 0 then print("plates level colour: all ok") else os.exit(1) end
