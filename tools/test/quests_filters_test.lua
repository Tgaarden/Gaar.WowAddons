-- LuaJIT stub test: GaarQuestsForever quest filter (Filters.lua) - status and dungeon/raid tests,
-- the quest log pass (rows hidden, rows below moved up by the space Blizzard gave the hidden ones,
-- empty zone headers hidden, objective lines and POI buttons hidden, list shorter, exact restore),
-- the "Quests: n/m (k shown)" count, the gear menu (Menu.ModifyMenu tag), the tracker header
-- menu's "Quest log filter" submenu on the same settings, /gqf filter, saved-variable cleanup,
-- the pause while the dungeon filter applies, auto-watch narrowing and the tracker layout pass.
-- Run: luajit tools/test/quests_filters_test.lua   (from the repo root)
local function read(p) local fh = assert(io.open(p)); local s = fh:read("*a"); fh:close(); return s end
local src = read("addons/GaarQuestsForever/GaarQuestsForever.lua") .. [==[
_G.__T = { SetDB = function(v) db = v end, OptionEntries = OptionEntries, OnSlash = OnSlash,
  Bind = BindSavedVariables, ApplyLayout = ApplyLayout, Recognise = RecogniseTracker, Hidden = hiddenBlocks }
]==]
local filtersSrc = read("addons/GaarQuestsForever/Filters.lua")

local noop = function() end
local printed = {}

-- A frame stub: points, shown state, size, text.
local Frame = {}
Frame.__index = Frame
local function NewFrame(t)
    t = t or {}
    t.points = t.points or {}
    if t.shown == nil then t.shown = true end
    return setmetatable(t, Frame)
end
function Frame:IsShown() return self.shown end
function Frame:Show() self.shown = true end
function Frame:Hide() self.shown = false end
function Frame:IsProtected() return false end
function Frame:GetNumPoints() return #self.points end
function Frame:GetPoint(i) local p = self.points[i or 1]; if p then return p[1], p[2], p[3], p[4], p[5] end end
function Frame:ClearAllPoints() self.points = {} end
function Frame:SetPoint(p, rel, rp, x, y)
    for i, q in ipairs(self.points) do if q[1] == p then table.remove(self.points, i) break end end
    self.points[#self.points + 1] = { p, rel, rp, x, y }
end
function Frame:GetHeight() return self.height or 0 end
function Frame:SetHeight(h) self.height = h end
function Frame:GetWidth() return self.width or 0 end
function Frame:GetChildren() return unpack(self.children or {}) end
function Frame:GetParent() return self.parent end
function Frame:GetText() return self.text end
function Frame:SetText(t) self.text = t end
function Frame:GetStringWidth() return #(self.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") * 5 end

local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end

local hooks, menus = {}, {}
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.GaarForever = {
    NewAddon = function() return setmetatable({}, { __index = function(_, k)
        if k == "Print" then return function(_, msg) printed[#printed + 1] = msg end end
        return noop end }) end,
    IsSecret = function() return false end,
    Num = function(v) return type(v) == "number" and v or nil end,
    InCombat = function() return false end,
    Migrate = noop,
    RenderMenu = function(root, entries) root.entries = entries end,
}
G.CreateFrame = widget
G.hooksecurefunc = function(a, b, c)
    if type(a) == "string" then hooks[a] = b else hooks[b] = c end
end
G.SlashCmdList = {}
G.Menu = { ModifyMenu = function(tag, fn) menus[tag] = fn end }
G.QuestLogQuests_Update = noop
G.QuestLogQuests_ShowQuestCount = noop
G.IsInInstance = function() return false end

-- Quest log: Elwynn (1 complete, 2), Deadmines (3, dungeon-tagged), Westfall (4 complete,
-- 5 group-tagged), Duskwood (6 raid-tagged, complete).
local entries = {
    { isHeader = true, title = "Elwynn Forest" },
    { questID = 1, title = "A", level = 5 }, { questID = 2, title = "B", level = 6 },
    { isHeader = true, title = "The Deadmines" }, { questID = 3, title = "C", level = 18 },
    { isHeader = true, title = "Westfall" }, { questID = 4, title = "D", level = 10 }, { questID = 5, title = "E", level = 11 },
    { isHeader = true, title = "Duskwood" }, { questID = 6, title = "F", level = 25 },
}
local complete = { [1] = true, [4] = true, [6] = true }
local tags = { [3] = 81, [5] = 1, [6] = 62 }
local watches = {}
G.C_QuestLog = {
    GetNumQuestLogEntries = function() return #entries, 6 end,
    GetInfo = function(i) return entries[i] end,
    GetLogIndexForQuestID = function(id) for i, e in ipairs(entries) do if e.questID == id then return i end end end,
    IsComplete = function(id) return complete[id] == true end,
    ReadyForTurnIn = function(id) return complete[id] == true end,
    GetQuestTagInfo = function(id) return tags[id] and { tagID = tags[id] } or nil end,
    GetNumQuestWatches = function() return #watches end,
    GetQuestIDForQuestWatchIndex = function(i) return watches[i] end,
}

local NS = {}
local f = assert(loadstring(src, "q")); setfenv(f, G); f("GaarQuestsForever", NS)
local g = assert(loadstring(filtersSrc, "filters")); setfenv(g, G); g("GaarQuestsForever", NS)
local T, F = G.__T, NS.filters

local fails = 0
local function eq(name, got, want)
    if got ~= want then fails = fails + 1; print("FAIL " .. name .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end

-- Saved variables: defaults, junk cleaned.
G.GaarQuestsForeverDB = { questFilter = "bogus", hideInstanceQuests = "yes" }
T.Bind()
local db = G.GaarQuestsForeverDB
eq("default status", db.questFilter, "all")
eq("default instance filter", db.instanceFilter, "all")
eq("old key dropped", db.hideInstanceQuests, nil)
-- Migration from the old checkbox, once.
G.GaarQuestsForeverDB = { hideInstanceQuests = true }
T.Bind()
eq("migrate true -> none", G.GaarQuestsForeverDB.instanceFilter, "none")
eq("migrate drops old key", G.GaarQuestsForeverDB.hideInstanceQuests, nil)
G.GaarQuestsForeverDB = { hideInstanceQuests = false }
T.Bind()
eq("migrate false -> all", G.GaarQuestsForeverDB.instanceFilter, "all")
G.GaarQuestsForeverDB = { instanceFilter = "only", hideInstanceQuests = true }
T.Bind()
eq("existing value wins over old key", G.GaarQuestsForeverDB.instanceFilter, "only")
G.GaarQuestsForeverDB = { instanceFilter = "bogus" }
T.Bind()
eq("junk -> all", G.GaarQuestsForeverDB.instanceFilter, "all")
G.GaarQuestsForeverDB = { questFilter = "bogus", hideInstanceQuests = "yes" }
T.Bind()
db = G.GaarQuestsForeverDB
db.enabled, db.max = true, 10

-- Tests.
eq("no filter -> no tester", F.Tester(), nil)
db.questFilter = "uncompleted"
local h = F.Tester()
eq("uncompleted hides complete", h(1), true)
eq("uncompleted keeps open", h(2), false)
db.questFilter = "completed"
h = F.Tester()
eq("completed hides open", h(2), true)
eq("completed keeps complete", h(1), false)
db.questFilter = "all"; db.instanceFilter = "none"
h = F.Tester()
eq("dungeon tag hidden", h(3), true)
eq("raid tag hidden", h(6), true)
eq("group tag kept", h(5), false)
eq("untagged kept", h(2), false)

-- "only": just the dungeon/raid-tagged quests.
db.instanceFilter = "only"
h = F.Tester()
eq("only: dungeon kept", h(3), false)
eq("only: raid kept", h(6), false)
eq("only: group hidden", h(5), true)
eq("only: untagged hidden", h(2), true)
-- All 3x3 combinations: quest 1 complete untagged, 2 open untagged, 3 open dungeon, 6 raid.
local function ready(id) return F.IsReady(id) end
for _, st in ipairs({ "all", "completed", "uncompleted" }) do
    for _, inst in ipairs({ "all", "only", "none" }) do
        db.questFilter, db.instanceFilter = st, inst
        local hh = F.Tester()
        for _, id in ipairs({ 1, 2, 3, 5, 6 }) do
            local isInst = F.IsInstanceQuest(id)
            local want = true
            if st == "completed" and not ready(id) then want = false end
            if st == "uncompleted" and ready(id) then want = false end
            if inst == "only" and not isInst then want = false end
            if inst == "none" and isInst then want = false end
            local got = hh == nil and true or not hh(id)
            eq(("combo %s/%s q%d shown"):format(st, inst, id), got, want)
        end
    end
end
db.questFilter, db.instanceFilter = "all", "none"

-- Paused inside a dungeon while the dungeon filter is on (and only then).
G.IsInInstance = function() return true, "party" end
G.GetInstanceInfo = function() return "The Deadmines" end
eq("in instance, dungeon filter off: active", F.Tester() ~= nil, true)
db.dungeonFilter = true
eq("in instance, dungeon filter on: paused", F.Tester(), nil)
db.instanceFilter = "only"
eq("in instance, dungeon filter on: only paused too", F.Tester(), nil)
db.instanceFilter = "none"
G.IsInInstance = function() return false end
eq("outside: active again", F.Tester() ~= nil, true)
db.dungeonFilter = false

-- Auto-watch narrowing.
db.instanceFilter = "all"; db.questFilter = "uncompleted"
local narrowed = F.Narrow({ { id = 1, complete = true }, { id = 2 }, { id = 3 } })
eq("narrow count", #narrowed, 2)
eq("narrow first", narrowed[1].id, 2)
db.questFilter = "all"
eq("narrow off", F.Narrow({ { id = 1 } }), nil)

-- Quest log list as Blizzard lays it out: rows anchored TOPLEFT at absolute offsets.
local contents = NewFrame({ children = {}, bottomPadding = 0 })
local function row(t, height, topPadding)
    t.height, t.topPadding = height, topPadding
    return NewFrame(t)
end
local rows = {
    row({ questLogIndex = 1 }, 20, 8),                                   -- Elwynn header
    row({ questID = 1, questLogIndex = 2, info = entries[2] }, 30, 2),  -- q1 complete
    row({ questID = 2, questLogIndex = 3, info = entries[3] }, 40, -3), -- q2
    row({ questLogIndex = 4 }, 20, 4),                                   -- Deadmines header
    row({ questID = 3, questLogIndex = 5, info = entries[5] }, 30, 2),  -- q3 dungeon
    row({ questLogIndex = 6 }, 20, 4),                                   -- Westfall header
    row({ questID = 4, questLogIndex = 7, info = entries[7] }, 30, 2),  -- q4 complete
    row({ questID = 5, questLogIndex = 8, info = entries[8] }, 30, -3), -- q5
    row({ questLogIndex = 9 }, 20, 4),                                   -- Duskwood header
    row({ questID = 6, questLogIndex = 10, info = entries[10] }, 30, 2), -- q6 complete raid
}
local orig = {}
local top = 0
for i, r in ipairs(rows) do
    r.layoutIndex = i
    top = top + r.topPadding
    r:SetPoint("TOPLEFT", contents, "TOPLEFT", 0, -top)
    orig[r] = -top
    top = top + r.height
    contents.children[#contents.children + 1] = r
end
contents.height = top
local fullHeight = top
local objective2 = NewFrame({ questID = 2 })                 -- q2's objective line
local poi3 = NewFrame({ parent = rows[5] })                   -- q3's POI button
contents.children[#contents.children + 1] = objective2
contents.children[#contents.children + 1] = poi3
G.QuestScrollFrame = { Contents = contents }
local countBox = NewFrame({ width = 200 })
G.QuestLogQuestCount = NewFrame({ text = "Quests: 6/40", parent = countBox })

local function y(r) return select(5, r:GetPoint(1)) end

-- Setup: hooks and gear menu.
F.Setup()
eq("log hook", hooks.QuestLogQuests_Update ~= nil, true)
eq("count hook", hooks.QuestLogQuests_ShowQuestCount ~= nil, true)
eq("gear menu tag", type(menus.MENU_QUEST_MAP_FRAME_SETTINGS), "function")
local root = { CreateDivider = function(self) self.divider = true end, CreateTitle = function(self, t) self.title = t end }
menus.MENU_QUEST_MAP_FRAME_SETTINGS(nil, root)
eq("gear menu divider", root.divider, true)
eq("gear menu entries", root.entries and #root.entries, 7)
eq("gear menu radio", root.entries and root.entries[2].text, "Only completed")

-- Filter off: Blizzard's list untouched.
hooks.QuestLogQuests_Update()
for _, r in ipairs(rows) do eq("off shown " .. r.layoutIndex, r.shown, true) end
eq("off count", G.QuestLogQuestCount.text, "Quests: 6/40")

-- Only uncompleted, through Blizzard's update (the hook).
db.questFilter = "uncompleted"
hooks.QuestLogQuests_Update()
eq("q1 hidden", rows[2].shown, false)
eq("q2 shown", rows[3].shown, true)
eq("q4 hidden", rows[7].shown, false)
eq("Duskwood header hidden (only a complete quest)", rows[9].shown, false)
eq("q6 hidden", rows[10].shown, false)
eq("Westfall header kept (q5)", rows[6].shown, true)
-- q1's slot: from its own start (top - padding) to q2's start.
local q1slot = (-orig[rows[3]] - rows[3].topPadding) - (-orig[rows[2]] - rows[2].topPadding)
eq("q2 moved up by q1's slot", y(rows[3]), orig[rows[3]] + q1slot)
eq("header above untouched", y(rows[1]), orig[rows[1]])
local q4slot = (-orig[rows[8]] - rows[8].topPadding) - (-orig[rows[7]] - rows[7].topPadding)
eq("q5 moved up by both slots", y(rows[8]), orig[rows[8]] + q1slot + q4slot)
local tail = fullHeight - (-orig[rows[9]] - rows[9].topPadding)
eq("list shorter", contents.height, fullHeight - q1slot - q4slot - tail)
eq("count suffix", G.QuestLogQuestCount.text, "Quests: 6/40 |cffff9933(3 shown)|r")
eq("objective of shown quest kept", objective2.shown, true)

-- Switch to only completed (a settings change: restore, then filter again).
F.SetStatus("completed")
eq("q1 back", rows[2].shown, true)
eq("q1 at Blizzard's place", y(rows[2]), orig[rows[2]])
eq("q2 hidden", rows[3].shown, false)
eq("q2 objective hidden", objective2.shown, false)
eq("Deadmines header hidden", rows[4].shown, false)
eq("q3 hidden", rows[5].shown, false)
eq("q3 POI hidden", poi3.shown, false)
eq("Duskwood back", rows[9].shown, true)
eq("count completed", G.QuestLogQuestCount.text, "Quests: 6/40 |cffff9933(3 shown)|r")

-- Narrow count box: the short form.
countBox.width = 70
F.UpdateCount()
eq("short suffix", G.QuestLogQuestCount.text, "Quests: 6/40 |cffff9933(3)|r")
countBox.width = 200

-- Off again: exactly Blizzard's layout.
F.SetStatus("all")
for _, r in ipairs(rows) do
    eq("restored shown " .. r.layoutIndex, r.shown, true)
    eq("restored y " .. r.layoutIndex, y(r), orig[r])
end
eq("objective back", objective2.shown, true)
eq("poi back", poi3.shown, true)
eq("height back", contents.height, fullHeight)
eq("count back", G.QuestLogQuestCount.text, "Quests: 6/40")

-- Hide dungeon & raid quests via the slash command.
T.OnSlash("filter dungeons on")
eq("slash dungeons on = none", db.instanceFilter, "none")
eq("q3 hidden by tag", rows[5].shown, false)
eq("Deadmines header hidden by tag", rows[4].shown, false)
eq("q5 (group) kept", rows[8].shown, true)
eq("q6 (raid) hidden", rows[10].shown, false)
T.OnSlash("filter dungeons off")
eq("slash dungeons off = all", db.instanceFilter, "all")
eq("q3 back", rows[5].shown, true)
T.OnSlash("filter dungeons only")
eq("slash dungeons only", db.instanceFilter, "only")
eq("only: q3 kept", rows[5].shown, true)
eq("only: q5 (group) hidden", rows[8].shown, false)
T.OnSlash("filter dungeons none")
eq("slash dungeons none", db.instanceFilter, "none")
T.OnSlash("filter dungeons all")
eq("slash dungeons all", db.instanceFilter, "all")
local nb = #printed
T.OnSlash("filter dungeons bogus")
eq("slash bogus keeps value", db.instanceFilter, "all")
T.OnSlash("filter")
eq("filter status shows instance value", (table.concat(printed, "\n", nb + 1)):find("now: all", 1, true) ~= nil, true)
T.OnSlash("filter completed")
eq("slash completed", db.questFilter, "completed")
T.OnSlash("filter all")
eq("slash all", db.questFilter, "all")
local before = #printed
T.OnSlash("filter")
eq("slash status prints", #printed > before, true)

-- Unexpected layout: nothing touched.
db.questFilter = "uncompleted"
rows[3].points[1][1] = "TOP"
F.Refresh()
eq("unknown layout left alone", rows[2].shown, true)
eq("unknown layout state", F.logState:match("^left to Blizzard") ~= nil, true)
rows[3].points[1][1] = "TOPLEFT"
db.questFilter = "all"
F.Refresh()

-- Tracker header menu: "Quest log filter" submenu on the same settings.
local sub
for _, e in ipairs(T.OptionEntries()) do if e.text == "Quest log filter" then sub = e.submenu end end
eq("submenu present", sub ~= nil, true)
if sub then
    eq("submenu size", #sub, 7)
    sub[3].func()
    eq("submenu sets status", db.questFilter, "uncompleted")
    eq("submenu radio checked", sub[3].checked(), true)
    eq("submenu divider", sub[4].divider, true)
    eq("submenu labels", sub[5].text .. "|" .. sub[6].text .. "|" .. sub[7].text,
        "All quests (any type)|Only dungeon & raid quests|No dungeon & raid quests")
    sub[7].func()
    eq("submenu sets none", db.instanceFilter, "none")
    eq("submenu none checked", sub[7].checked(), true)
    sub[6].func()
    eq("submenu sets only", db.instanceFilter, "only")
    sub[5].func()
    eq("submenu sets all", db.instanceFilter, "all")
    sub[1].func()
end

-- Tracker: filtered quests hidden like the ones past the limit.
local tracker = NewFrame({ usedBlocks = {}, blockTemplate = "Q", contentsHeight = 100, bottomSpacing = 0,
    fromHeaderOffsetY = -10, fromBlockOffsetY = -5, Update = noop, UpdateHeight = noop })
tracker.ContentsFrame = NewFrame({})
local blocks = {}
for i, id in ipairs({ 1, 2, 3 }) do
    local b = NewFrame({ template = "Q", id = id, height = 20, used = true, parentModule = tracker, addedRegions = {} })
    b:SetPoint("TOP", i == 1 and tracker.ContentsFrame or blocks[i - 1], i == 1 and "TOP" or "BOTTOM", 0, i == 1 and -10 or -5)
    if i > 1 then blocks[i - 1].nextBlock = b end
    blocks[i] = b
end
tracker.firstBlock = blocks[1]
G.QuestObjectiveTracker = tracker
watches = { 1, 2, 3 }
T.Recognise()
db.questFilter = "uncompleted"
T.ApplyLayout()
eq("tracker complete block hidden", blocks[1].shown, false)
eq("tracker open blocks shown", blocks[2].shown and blocks[3].shown, true)
eq("tracker filtered count", NS.core.TrackerFiltered(), 1)
db.questFilter = "all"
T.ApplyLayout()
eq("tracker block back", blocks[1].shown, true)

if fails == 0 then print("ok") else os.exit(1) end
