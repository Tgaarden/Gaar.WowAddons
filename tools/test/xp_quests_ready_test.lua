-- LuaJIT stub test: GaarXPForever ready-quest maths (remaining XP, kills, time) and the scan.
-- Run: luajit tools/test/xp_quests_ready_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarXPForever/GaarXPForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { Calc = Calc, ScanReady = ScanReady, ready = ready }\n"
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
G.GaarXPForeverDB = nil
local f = assert(loadstring(src, "xp")); setfenv(f, G); f("GaarXPForever")
local T = G.__T

local fails = 0
local function eq(name, got, want)
    if got ~= want then fails = fails + 1; print("FAIL " .. name .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end

-- Calc: 6204/8800, 2450 quest XP, rate 12592/h, kill avg 100
local c = T.Calc(6204, 8800, 2450, 12592, 100)
eq("remaining", c.remaining, 146); eq("after", c.after, 8654); eq("not levelup", c.levelUp, false)
eq("kills", c.kills, 2); eq("secs", math.floor(c.secs), math.floor(146 / 12592 * 3600))
-- quests cover the level
c = T.Calc(6204, 8800, 2596, 12592, 100)
eq("exact remaining 0", c.remaining, 0); eq("exact levelup", c.levelUp, true); eq("exact kills", c.kills, 0)
c = T.Calc(6204, 8800, 5000, nil, nil)
eq("over remaining 0", c.remaining, 0); eq("over after capped", c.after, 8800); eq("no rate", c.secs, nil); eq("no kills", c.kills, nil)
-- no quests: unchanged behaviour
c = T.Calc(6204, 8800, 0, 12592, 200)
eq("no q remaining", c.remaining, 2596); eq("no q levelUp", c.levelUp, false); eq("no q kills", c.kills, 13)

-- Scan, retail-style API
local log = {
    { isHeader = true }, { questID = 1 }, { questID = 2 }, { questID = 3 }, { isHeader = true }, { questID = 4 },
}
local done, xp = { [1] = true, [3] = true, [4] = false }, { [1] = 1000, [3] = 1450, [2] = 999 }
G.C_QuestLog = {
    GetNumQuestLogEntries = function() return #log end,
    GetInfo = function(i) return log[i] end,
    ReadyForTurnIn = function(q) return done[q] == true end,
    IsComplete = function(q) return done[q] == true end,
    GetQuestLogRewardXP = function(q) return xp[q] or 0 end,
}
T.ScanReady(); eq("retail count", T.ready.count, 2); eq("retail xp", T.ready.xp, 2450)

-- Scan, legacy API (selection based)
G.C_QuestLog = nil
local sel = 5
G.GetNumQuestLogEntries = function() return #log end
G.GetQuestLogTitle = function(i)
    local e = log[i]; return "t", 1, nil, e.isHeader and true or false, false, done[e.questID] and 1 or 0, nil, e.questID
end
G.GetQuestLogSelection = function() return sel end
G.SelectQuestLogEntry = function(i) sel = i end
G.GetQuestLogRewardXP = function() return xp[log[sel] and log[sel].questID] or 0 end
T.ScanReady()
eq("legacy selection restored", sel, 5)
eq("legacy count", T.ready.count, 2); eq("legacy xp", T.ready.xp, 2450)
print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
