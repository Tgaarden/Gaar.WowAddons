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

-- XP bar identification: two containers, sparse keyed bars (BarsEnum keys), a rep bar never chosen.
local function bar(name, idx, mn, mx, val, withText, shown, tick)
    local sb = { GetMinMaxValues = function() return mn, mx end, GetValue = function() return val end,
        CreateTexture = noop, GetName = function() return nil end, SetAlpha = noop,
        IsVisible = function() return shown ~= false end }
    local e = { StatusBar = sb, barIndex = idx, GetName = function() return name end, SetAlpha = noop }
    if withText then e.OverlayFrame = { SetAlpha = noop, Text = { GetStringWidth = noop, GetFont = noop } } end
    if tick then e.ExhaustionTick = { SetAlpha = noop } end
    return e
end
local function cont(bars) return { bars = bars, SetAlpha = noop } end
local rep = bar("MainStatusTrackingBarContainer.ReputationBar", nil, 0, 3000, 1200, true)
local xp = bar(nil, nil, 0, 50800, 45394, true)
local xpMainHidden = bar(nil, nil, 0, 50800, 45394, true, false)
G.StatusTrackingBarInfo = { BarsEnum = { Reputation = 1, Honor = 2, Artifact = 3, Experience = 4, Azerite = 5 } }
G.MainStatusTrackingBarContainer = cont({ [1] = rep })
G.SecondaryStatusTrackingBarContainer = cont({ [4] = xp })
local r = T.FindXPBar()
eq(r and r.entry, xp, "rep Main[1], xp Secondary[4]: xp chosen")
eq(r and r.containerName, "SecondaryStatusTrackingBarContainer", "container name")
eq(r and r.key, 4, "key"); eq(r and r.via, "key", "via key")
eq(r and r.text, xp.OverlayFrame.Text, "text region is the XP bar's own")

-- both containers hold an XP instance: the shown one wins
G.MainStatusTrackingBarContainer = cont({ [1] = rep, [4] = xpMainHidden })
r = T.FindXPBar(); eq(r and r.entry, xp, "shown instance preferred over hidden")
G.MainStatusTrackingBarContainer = cont({ [4] = xp, [1] = rep })
G.SecondaryStatusTrackingBarContainer = cont({ [4] = xpMainHidden })
r = T.FindXPBar(); eq(r and r.entry, xp, "shown instance in Main")
eq(r and r.containerName, "MainStatusTrackingBarContainer", "Main container name")

-- barContainers list on the manager (containers not reachable by global name)
G.MainStatusTrackingBarContainer, G.SecondaryStatusTrackingBarContainer = nil, nil
G.StatusTrackingBarManager = { barContainers = { a = cont({ [1] = rep }), b = cont({ [4] = xp }) } }
r = T.FindXPBar(); eq(r and r.entry, xp, "via manager.barContainers")
G.StatusTrackingBarManager = nil

-- by structure: no usable key (array-style, key 2 is not the XP enum), ExhaustionTick present
local xpS = bar(nil, nil, 0, 1, 0, true, true, true)
G.MainStatusTrackingBarContainer = cont({ rep, xpS })
G.SecondaryStatusTrackingBarContainer = nil
r = T.FindXPBar(); eq(r and r.entry, xpS, "by ExhaustionTick without key"); eq(r and r.via, "structure", "via structure")
-- structure via UpdateExhaustion mixin method
local xpM = bar(nil, nil, 0, 1, 0, true); xpM.UpdateExhaustion = noop
G.MainStatusTrackingBarContainer = cont({ rep, xpM })
r = T.FindXPBar(); eq(r and r.entry, xpM, "by UpdateExhaustion"); eq(r and r.via, "structure", "via structure 2")

-- by max only
G.MainStatusTrackingBarContainer = cont({ rep, xp })
r = T.FindXPBar(); eq(r and r.entry, xp, "by UnitXPMax"); eq(r and r.via, "max", "via max")

-- the rep bar is never chosen
G.MainStatusTrackingBarContainer = cont({ [1] = rep })
G.SecondaryStatusTrackingBarContainer = nil
r = T.FindXPBar(); eq(r, nil, "rep only gives nil")
G.MainStatusTrackingBarContainer = cont({ [1] = bar("X.ReputationStatusBar", 1, 0, 50800, 45394) })
r = T.FindXPBar(); eq(r, nil, "name says reputation, even with matching numbers")
G.MainStatusTrackingBarContainer = cont({ [1] = bar(nil, nil, 0, 3000, 1200) })
r = T.FindXPBar(); eq(r, nil, "keyed as Reputation (1), no structure: never picked")

-- classic fallback
local classic = bar(nil, nil, 0, 50800, 45394)
G.MainStatusTrackingBarContainer = nil
G.MainMenuExpBar = classic.StatusBar
r = T.FindXPBar(); eq(r and r.sb, classic.StatusBar, "classic MainMenuExpBar fallback"); eq(r and r.via, "classic", "via classic")

if fails == 0 then print("xp_bar_text_test: ok") else os.exit(1) end
