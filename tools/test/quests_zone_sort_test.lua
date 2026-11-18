-- LuaJIT stub test: GaarQuestsForever zone sort (current zone first, other zones A-Z, "Other" last,
-- level order inside a zone) and the quest-log header lookup.
-- Run: luajit tools/test/quests_zone_sort_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarQuestsForever/GaarQuestsForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. [==[
_G.__T = { ZoneCompare = ZoneCompare, OrderQuests = OrderQuests, QuestData = QuestData, SetDB = function(v) db = v end,
  SetZones = function(t) currentZones = t end, SortMode = SortMode }
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
-- quest log: header Elwynn, q1 (lvl 5), q2 (lvl 3), header Duskwood, q3, header Westfall, q4; q5 before any header
G.GetRealZoneText = function() return "Duskwood" end
local entries = {
    { isHeader = true, title = "Elwynn Forest" },
    { questID = 1, title = "B", level = 5 }, { questID = 2, title = "A", level = 3 },
    { isHeader = true, title = "Duskwood" }, { questID = 3, title = "C", level = 20 },
    { isHeader = true, title = "Westfall" }, { questID = 4, title = "D", level = 10 },
}
G.C_QuestLog = {
    GetLogIndexForQuestID = function(id) for i, e in ipairs(entries) do if e.questID == id then return i end end end,
    GetInfo = function(i) return entries[i] end,
    IsComplete = function() return false end,
}
local f = assert(loadstring(src, "q")); setfenv(f, G); f("GaarQuestsForever")
local T = G.__T
T.SetDB({ sort = "zone", completed = "bottom" })

local fails = 0
local function eq(name, got, want)
    if got ~= want then fails = fails + 1; print("FAIL " .. name .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end

eq("mode", T.SortMode(), "zone")
eq("zone of 1", T.QuestData(1).zone, "Elwynn Forest")
eq("zone of 3", T.QuestData(3).zone, "Duskwood")

local function ids(items) local t = {} for i, d in ipairs(items) do t[i] = d.id end return table.concat(t, ",") end
local function pool() local t = {} for _, id in ipairs({ 4, 1, 3, 2 }) do t[#t + 1] = T.QuestData(id) end return t end
-- current zone Duskwood: 3 first, then Elwynn (2,1 by level), then Westfall (4)
local p = pool(); T.OrderQuests(p); eq("current first", ids(p), "3,2,1,4")
-- current zone Westfall
G.GetRealZoneText = function() return "westfall" end
p = pool(); T.OrderQuests(p); eq("case-insensitive", ids(p), "4,3,2,1")
-- not in any quest zone: alphabetical (Duskwood, Elwynn, Westfall)
G.GetRealZoneText = function() return "Stormwind" end
p = pool(); T.OrderQuests(p); eq("alphabetical", ids(p), "3,2,1,4")
-- a quest without a header goes last, even in a later alphabet
local q = T.QuestData(1); q.zone, q.zoneKey = nil, nil
local list = { q, T.QuestData(4), T.QuestData(3) }
T.OrderQuests(list); eq("other last", ids(list), "3,4,1")
-- completed bottom within a zone, zone grouping kept
local a, b = T.QuestData(2), T.QuestData(1); a.complete = true
list = { a, b }; T.OrderQuests(list); eq("completed within zone", ids(list), "1,2")
-- level mode ignores zones
T.SetDB({ sort = "level", completed = "bottom" })
p = pool(); T.OrderQuests(p); eq("level mode", ids(p), "2,1,4,3")

if fails == 0 then print("ok") else os.exit(1) end
