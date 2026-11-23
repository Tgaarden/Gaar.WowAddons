-- LuaJIT stub test: GaarXPForever ready-quest maths (remaining XP, kills, time) and the scan.
-- Run: luajit tools/test/xp_quests_ready_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarXPForever/GaarXPForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. [==[
_G.__T = { Calc = Calc, ScanReady = ScanReady, SegmentGeometry = SegmentGeometry, RestedGeometry = RestedGeometry, ready = ready, ClearCache = function() xpCache = {} end,
  MarkReadyDirty = MarkReadyDirty, MaybeScanReady = MaybeScanReady, QuestEvent = QuestEvent,
  SetDB = function(v) db = v end, GetCache = function() return xpCache end, Dirty = function() return readyDirty end,
  SetIgnore = function(t) ignoreLogUntil = t end, ResetScan = function() lastScan = -10; ignoreLogUntil = 0; scanTimerDue = nil; followDue = nil; readyDirty = true end }
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
local now = 100
G.GetTime = function() return now end
local timers = {}
G.C_Timer = { After = function(d, fn) timers[#timers + 1] = { at = now + d, fn = fn } end }
local function advance(dt)
    now = now + dt
    local i = 1
    while i <= #timers do
        if timers[i].at <= now then local t = table.remove(timers, i); t.fn() else i = i + 1 end
    end
end
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
eq("kills ignore quest xp", c.kills, 26); eq("secs", math.floor(c.secs), math.floor(146 / 12592 * 3600))
-- quests cover the level
c = T.Calc(6204, 8800, 2596, 12592, 100)
eq("exact remaining 0", c.remaining, 0); eq("exact levelup", c.levelUp, true); eq("exact kills ignore quest xp", c.kills, 26)
c = T.Calc(6204, 8800, 5000, nil, nil)
eq("over remaining 0", c.remaining, 0); eq("over after capped", c.after, 8800); eq("no rate", c.secs, nil); eq("no kills", c.kills, nil)
-- no quests: unchanged behaviour
c = T.Calc(6204, 8800, 0, 12592, 200)
eq("no q remaining", c.remaining, 2596); eq("no q levelUp", c.levelUp, false); eq("no q kills", c.kills, 13)

-- kills = ceil((max - cur) / avg) only; ready quest XP never lowers it (in-game case: 47,139/58,600, +11,700 ready, avg 330)
c = T.Calc(47139, 58600, 11700, 5000, 330)
eq("kills real case", c.kills, 35); eq("kills real case remaining still after quests", c.remaining, 0)
eq("kills same without quests", T.Calc(47139, 58600, 0, 5000, 330).kills, 35)

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

-- Source fallback. Classic-like: global ignores its argument and reads the selected quest; C_QuestLog has
-- no RewardXP (returns 0). Selection via C_QuestLog.SetSelectedQuest.
local selQ = 3
G.GetQuestLogSelection = nil; G.SelectQuestLogEntry = nil; G.GetQuestLogTitle = nil; G.GetNumQuestLogEntries = nil
local asked = {}
G.C_QuestLog = {
    GetNumQuestLogEntries = function() return #log end,
    GetInfo = function(i) return log[i] end,
    ReadyForTurnIn = function(q) return done[q] == true end,
    GetQuestLogRewardXP = function() return 0 end,
    GetSelectedQuest = function() return selQ end,
    SetSelectedQuest = function(q) selQ = q end,
    RequestLoadQuestByID = function(q) asked[#asked + 1] = q end,
}
G.GetQuestLogRewardXP = function() return xp[selQ] or 0 end   -- argument ignored
T.ClearCache()
T.ScanReady()
eq("select src count", T.ready.count, 2); eq("select src xp", T.ready.xp, 2450)
eq("selection restored", selQ, 3)
eq("source named", T.ready.list[1].src, "select+global")
-- cached: break the sources, value stays
G.GetQuestLogRewardXP = function() return 0 end
T.ScanReady(); eq("cache xp", T.ready.xp, 2450); eq("cache src", T.ready.list[1].src, "select+global")
-- nothing works: 0 xp, load requested once
T.ClearCache(); xp[1], xp[3] = 0, 0
T.ScanReady(); eq("none xp", T.ready.xp, 0); eq("none src", T.ready.list[1].src, nil); eq("load requested", #asked, 2)
-- retail-like: global takes questID, quest not selected
xp[1], xp[3] = 1000, 1450; selQ = 99; T.ClearCache()
G.C_QuestLog.SetSelectedQuest = nil
G.GetQuestLogRewardXP = function(q) return q and xp[q] or 0 end
T.ScanReady(); eq("not selected, no select api", T.ready.xp, 0)
selQ = 1
T.ClearCache(); T.ScanReady(); eq("selected quest uses global(id)", T.ready.xp, 1000)
-- bar segment geometry: offset and width, clamped
local function geo(name, o, w, ...) local a, b = T.SegmentGeometry(...); eq(name .. " offset", a, o); eq(name .. " width", b, w) end
geo("middle", 200, 100, 1000, 5000, 500, 1000)            -- 20% in, 10% wide
geo("clamped", 800, 200, 4000, 5000, 3000, 1000)          -- would pass the end
geo("covers", 500, 500, 2500, 5000, 9999, 1000)
geo("none", nil, nil, 100, 5000, 0, 1000)
geo("no width", nil, nil, 100, 5000, 50, 0)
geo("full bar", nil, nil, 5000, 5000, 50, 1000)

-- Trailing-edge throttle, no-zero-cache, follow-up scan
local function rg(name, o, w, t, ...) local a, b, c = T.RestedGeometry(...); eq(name .. " offset", a, o); eq(name .. " width", b, w); eq(name .. " tick", c, t) end
rg("rested after quest", 300, 100, 400, 1000, 500, 500, 5000, 1000)       -- 20%+10% in, 10% wide
rg("rested clamped", 800, 200, nil, 3500, 500, 3000, 5000, 1000)          -- passes the end: no tick
rg("rested exact end", 800, 200, 1000, 3500, 500, 1000, 5000, 1000)
rg("rested no quest", 200, 100, 300, 1000, 0, 500, 5000, 1000)
rg("rested none", nil, nil, nil, 1000, 500, 0, 5000, 1000)
rg("quest fills bar", nil, nil, nil, 4000, 2000, 500, 5000, 1000)

do
    local sc = 0
    local real = T.ScanReady
    -- count scans through the ready table identity: use count change as the signal
    T.SetDB({ questReady = true, enabled = true })
    G.GetNumQuestLogEntries = nil; G.GetQuestLogTitle = nil; G.GetQuestLogSelection = nil; G.SelectQuestLogEntry = nil
    local dn = { [1] = false }
    local qlog = { { questID = 1 } }
    G.C_QuestLog = {
        GetNumQuestLogEntries = function() return #qlog end,
        GetInfo = function(i) return qlog[i] end,
        ReadyForTurnIn = function(q) return dn[q] == true end,
        IsComplete = function(q) return dn[q] == true end,
        GetQuestLogRewardXP = function(q) return 700 end,
    }
    timers = {}; T.ClearCache(); T.ResetScan()
    T.MaybeScanReady(); eq("tf initial", T.ready.count, 0)
    -- completes inside the 0.5 s throttle: event must not be dropped
    advance(0.1); dn[1] = true
    T.MarkReadyDirty()
    eq("tf not yet scanned (throttled)", T.ready.count, 0); eq("tf still dirty", T.Dirty(), true)
    advance(0.6)
    eq("tf trailing scan ran", T.ready.count, 1); eq("tf trailing xp", T.ready.xp, 700)
    -- event inside own-selection ignore window: scheduled, not dropped
    dn[1] = false; advance(1)
    T.MarkReadyDirty(); eq("ign cleared", T.ready.count, 0)
    dn[1] = true; T.SetIgnore(now + 0.5); T.MarkReadyDirty()
    eq("ign not scanned in window", T.ready.count, 0)
    advance(0.7); eq("ign trailing scan", T.ready.count, 1)
    -- stale API at event time: the follow-up scan about 1 s later picks it up
    dn[1] = false; advance(1); T.MarkReadyDirty(); eq("stale start", T.ready.count, 0)
    advance(1); T.QuestEvent()       -- API still says not complete at the event
    eq("stale at event", T.ready.count, 0)
    dn[1] = true; advance(1.2)
    eq("follow-up scan after ~1 s", T.ready.count, 1)
    -- no zero/nil cache
    T.ClearCache(); G.C_QuestLog.GetQuestLogRewardXP = function() return 0 end
    advance(1); T.MarkReadyDirty(); advance(0.6)
    eq("zero xp not cached", next(T.GetCache()), nil)
    G.C_QuestLog.GetQuestLogRewardXP = function() return 450 end
    advance(1); T.MarkReadyDirty(); advance(0.6)
    eq("xp found after zero", T.ready.xp, 450); eq("positive cached", T.GetCache()[1] and T.GetCache()[1].xp, 450)
    -- turn-in (quest leaves the log) drops it at once
    qlog = {}; advance(1); T.MarkReadyDirty(); advance(0.6)
    eq("turned in count", T.ready.count, 0); eq("turned in xp", T.ready.xp, 0)
end
print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
