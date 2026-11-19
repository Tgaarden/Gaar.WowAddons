-- LuaJIT stub test: GaarXPForever bar text assembly, priority drop, anchor maths and XP bar identification.
-- Run: luajit tools/test/xp_bar_text_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarXPForever/GaarXPForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. [==[
_G.__T = { ComposeBarText = ComposeBarText, SupplementAnchor = SupplementAnchor, TextEndX = TextEndX, FindXPBar = FindXPBar }
]==]
local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.GaarForever = {
    NewAddon = function() return setmetatable({}, { __index = function() return noop end }) end,
    IsSecret = function() return false end,
    Num = function(v) return type(v) == "number" and v or nil end,
    Migrate = noop, RenderMenu = noop,
}
G.CreateFrame = widget
G.hooksecurefunc = noop
G.SlashCmdList = {}
G.GetTime = function() return 100 end
G.C_Timer = { After = noop }
G.UnitXP = function() return 45394 end
G.UnitXPMax = function() return 50800 end
G.UnitLevel = function() return 30 end
G.GetXPExhaustion = function() return 6396 end
local f = assert(loadstring(src, "xp")); setfenv(f, G); f("GaarXPForever")
local T = G.__T

local fails = 0
local function eq(a, b, msg)
    if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": got " .. tostring(a) .. " want " .. tostring(b)) end
end

-- Text assembly: supplement mode (no totals), full mode (totals), priority drop rested -> quest.
local always = function() return true end
eq(T.ComposeBarText(45394, 50800, 6396, 3450, false, always), "(89.4%) \194\183 rested 6,396 \194\183 +3,450 quest", "supplement full")
eq(T.ComposeBarText(45394, 50800, 6396, 3450, true, always), "45,394/50,800 (89.4%) \194\183 rested 6,396 \194\183 +3,450 quest", "full mode")
eq(T.ComposeBarText(45394, 50800, 0, 0, false, always), "(89.4%)", "pct only")
eq(T.ComposeBarText(45394, 50800, nil, 3450, false, always), "(89.4%) \194\183 +3,450 quest", "quest only")
local function maxLen(n) return function(s) return #s <= n end end
eq(T.ComposeBarText(45394, 50800, 6396, 3450, false, maxLen(30)), "(89.4%) \194\183 +3,450 quest", "drop rested first")
eq(T.ComposeBarText(45394, 50800, 6396, 3450, false, maxLen(10)), "(89.4%)", "drop quest next")
eq(T.ComposeBarText(45394, 50800, 6396, 3450, false, maxLen(1)), "(89.4%)", "percent always stays")
eq(T.ComposeBarText(nil, 50800, 0, 0, false, always), nil, "no xp")

-- Anchor maths.
local rp, x = T.SupplementAnchor("CENTER", 100, 16); eq(rp, "CENTER", "center point"); eq(x, 66, "center offset")
rp, x = T.SupplementAnchor("LEFT", 100, 16); eq(rp, "LEFT", "left point"); eq(x, 116, "left offset")
rp, x = T.SupplementAnchor("RIGHT", 100, 16); eq(rp, "RIGHT", "right point"); eq(x, 16, "right offset")
eq(T.TextEndX("CENTER", 0, 400, 100), 250, "end centre")
eq(T.TextEndX("LEFT", 10, 400, 100), 110, "end left")
eq(T.TextEndX("RIGHT", 10, 400, 100), 400, "end right")

-- XP bar identification: a reputation bar stacked above the XP bar must never be returned.
local function bar(name, idx, mn, mx, val, withText)
    local sb = { GetMinMaxValues = function() return mn, mx end, GetValue = function() return val end,
        CreateTexture = noop, GetName = function() return nil end, SetAlpha = noop }
    local e = { StatusBar = sb, barIndex = idx, GetName = function() return name end, SetAlpha = noop }
    if withText then e.OverlayFrame = { SetAlpha = noop, Text = { GetStringWidth = noop, GetFont = noop } } end
    return e
end
local rep, xp = bar("MainStatusTrackingBarContainer.ReputationBar", 1, 0, 3000, 1200, true), bar(nil, 4, 0, 50800, 45394, true)
G.StatusTrackingBarInfo = { BarsEnum = { Reputation = 1, Experience = 4 } }
G.MainStatusTrackingBarContainer = { bars = { rep, xp }, SetAlpha = noop }
local r = T.FindXPBar()
eq(r and r.entry, xp, "by barIndex, rep first")
eq(r and r.text, xp.OverlayFrame.Text, "text region is the XP bar's")
G.MainStatusTrackingBarContainer.bars = { xp, rep }
r = T.FindXPBar(); eq(r and r.entry, xp, "order swapped")
xp.barIndex = nil                                   -- no index: found by max/value
r = T.FindXPBar(); eq(r and r.entry, xp, "by UnitXPMax")
G.MainStatusTrackingBarContainer.bars = { rep }     -- only a reputation bar: no XP bar at all
r = T.FindXPBar(); eq(r, nil, "rep only gives nil")
G.MainStatusTrackingBarContainer.bars = { bar("X.ReputationStatusBar", 1, 0, 50800, 45394) }   -- even with matching numbers
r = T.FindXPBar(); eq(r, nil, "name says reputation: never picked")

if fails == 0 then print("xp_bar_text_test: ok") else os.exit(1) end
