-- LuaJIT stub test: GaarXPForever 1.5 test mode - the XP panel with made-up numbers (also at max level), a menu
-- checkbox just before Reset session, /gxp test, and nothing saved.
-- Run: luajit tools/test/xp_testmode_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarXPForever/GaarXPForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. [==[
_G.__T = { PanelText = PanelText, SetDB = function(v) db = v end, OnSlash = OnSlash, MenuEntries = MenuEntries,
    Panel = function() return panel end, SetTest = SetTest, Refresh = Refresh }
]==]
local noop = function() end
local function widget()
    local w = setmetatable({ shown = false, txt = "" }, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
    w.Show = function(self) self.shown = true end
    w.Hide = function(self) self.shown = false end
    w.SetText = function(self, t) self.txt = t end
    w.GetStringWidth = function() return 100 end
    w.GetStringHeight = function() return 50 end
    w.CreateFontString = function() return widget() end
    w.CreateTexture = function() return widget() end
    return w
end
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
local prints = {}
G.GaarForever = {
    NewAddon = function() return setmetatable({ Print = function(_, m) prints[#prints + 1] = m end }, { __index = function() return noop end }) end,
    IsSecret = function() return false end,
    Num = function(v) return type(v) == "number" and v or nil end,
    Migrate = noop, RenderMenu = noop,
}
G.CreateFrame = widget
G.UIParent = widget()
G.hooksecurefunc = noop; G.SlashCmdList = {}
G.GetTime = function() return 100 end
G.C_Timer = { After = noop }
G.UnitLevel = function() return 60 end
G.GetMaxPlayerLevel = function() return 60 end
G.UnitXP = function() return 0 end
G.UnitXPMax = function() return 0 end
local f = assert(loadstring(src, "xp")); setfenv(f, G); f("GaarXPForever")
local T = G.__T
local db = { enabled = true, panel = true, locked = true, questReady = true }
T.SetDB(db)

local fails = 0
local function eq(n, got, want) if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end end

eq("max level normally", T.PanelText(), "Max level")
local entries = T.MenuEntries()
local ti, ri
for i, e in ipairs(entries) do
    if e.text == "Test mode" then ti = i end
    if e.text == "Reset session" then ri = i end
end
eq("menu has Test mode", ti ~= nil, true)
eq("Test mode is a checkbox", entries[ti].checkbox, true)
eq("Test mode just before Reset session", ti, ri - 1)
eq("starts off", entries[ti].checked(), false)
entries[ti].func()
eq("on after click", entries[ti].checked(), true)
local t = T.PanelText()
eq("made-up text at max level", t:find("XP: 12,450/21,300", 1, true) ~= nil, true)
eq("marked as test", t:find("test mode", 1, true) ~= nil, true)
eq("panel shown", T.Panel() and T.Panel().shown, true)
eq("nothing saved", db.testing, nil)
db.panel = false; T.Refresh()
eq("shown even with the panel option off", T.Panel().shown, true)
T.OnSlash("test")
eq("/gxp test toggles off", entries[ti].checked(), false)
eq("panel hidden again", T.Panel().shown, false)
eq("real text back", T.PanelText(), "Max level")
for k in pairs(db) do if k == "testing" or k == "test" then eq("no test key saved", k, nil) end end

if fails == 0 then print("xp_testmode_test: ok") else os.exit(1) end
