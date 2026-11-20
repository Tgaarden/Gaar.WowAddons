-- LuaJIT stub test: GaarXPForever mob / quest XP split (kill average, rate split, message classifier).
-- Run: luajit tools/test/xp_split_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarXPForever/GaarXPForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. [==[
_G.__T = { ClassifyXPMessage = ClassifyXPMessage, KillAvg = KillAvg, Session = function() return session end,
  Kill = function(base) pendingKills = pendingKills + 1; pendingKillBase = pendingKillBase + (base or 0) end,
  Quest = function(xp) flagQuest = true; pendingQuestXP = pendingQuestXP + (xp or 0) end,
  Gain = function(d) pendingDelta = (pendingDelta or 0) + d; Resolve() end,
  Panel = function() return PanelText() end, SetStart = function(t) session.start = t end }
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
G.COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
G.COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = "You gain %d experience."
G.UnitXP = function() return 15323 end
G.UnitXPMax = function() return 54500 end
G.GaarXPForeverDB = nil
local f = assert(loadstring(src, "xp")); setfenv(f, G); f("GaarXPForever")
local T = G.__T

local fails = 0
local function eq(name, got, want)
    if got ~= want then fails = fails + 1; print("FAIL " .. name .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end

-- classifier
local k, n = T.ClassifyXPMessage("Boar dies, you gain 120 experience. (+60 exp Rested bonus)", G)
eq("kill kind", k, "kill"); eq("kill base without rested", n, 120)
eq("quest text is other", (T.ClassifyXPMessage("You gain 2800 experience.", G)), "other")
eq("nil text", (T.ClassifyXPMessage(nil, G)), nil)

-- quest XP never enters the kill average
local s = T.Session()
T.Quest(1500); T.Gain(1500)
eq("quest only: no kill avg", T.KillAvg(s), nil)
eq("quest only: quests", s.quests, 1); eq("quest only: questXP", s.questXP, 1500); eq("quest only: mobXP", s.mobXP, 0)
-- kills: base 100 and 140
T.Kill(100); T.Gain(200)      -- 100 base + 100 rested bonus
T.Kill(140); T.Gain(140)
eq("kill avg from base", T.KillAvg(s), 120)
eq("kills counted", s.kills, 2); eq("mobXP", s.mobXP, 340)
-- kill and quest in the same window: quest part comes from the QUEST_TURNED_IN xp
T.Kill(100); T.Quest(800); T.Gain(900)
eq("mixed kill avg", math.floor(T.KillAvg(s)), 113); eq("mixed questXP", s.questXP, 2300); eq("mixed mobXP", s.mobXP, 440)
-- exploring: counts only toward gained
T.Gain(300)
eq("other gained", s.gained, 1500 + 340 + 900 + 300); eq("other mobXP unchanged", s.mobXP, 440)
-- rate split and kills line in the panel
T.SetStart(100 - 3600)
local p = T.Panel()
eq("rate split", p:find("XP/hour: 3,040 (mobs 440", 1, true) ~= nil, true)
eq("quests in split", p:find("quests 2,300", 1, true) ~= nil, true)
eq("other in split", p:find("other 300", 1, true) ~= nil, true)
eq("kills line", p:find("kills (avg 113 XP)", 1, true) ~= nil, true)
print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
