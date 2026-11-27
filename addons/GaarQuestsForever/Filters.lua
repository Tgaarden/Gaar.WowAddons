--[[
  GaarQuestsForever - quest filter (1.16)

  Two settings, saved in GaarQuestsForeverDB like every other option:

    * questFilter: "all" (default), "completed" (only quests ready to turn in:
      C_QuestLog.ReadyForTurnIn, else C_QuestLog.IsComplete) or "uncompleted" (the others).
    * instanceFilter: "all" (default), "only" (only quests tagged Dungeon or Raid) or "none" (hide
      them) - C_QuestLog.GetQuestTagInfo, else the classic GetQuestTagInfo; tag IDs Dungeon 81,
      Heroic 85, Raid 62/88/89 or the tag names. Group and Elite quests count as neither. The tag
      reader is the one the dungeon filter uses. Combines with questFilter. (Before 1.16 this was
      the checkbox hideInstanceQuests, migrated once in the core's BindSavedVariables.)

  Where they apply: the quest log list (QuestMapFrame's QuestScrollFrame) and the Quests section
  of the objective tracker. Never the map pins.

  Settings: Blizzard's own gear menu in the quest log header (QuestScrollFrame.SettingsDropdown,
  tag MENU_QUEST_MAP_FRAME_SETTINGS, which only has "Show Quest Objectives"), the tracker header's
  right-click menu ("Quest log filter" submenu), the hub's menu, and /gqf filter. All of them
  change the same two saved keys, so they always agree.

  The dungeon filter (/gqf dungeon) and this one: the dungeon filter watches only the current
  instance's quests while you are inside a dungeon or raid. So that the two never fight, the instance
  filter pauses (in the log and the tracker) while the dungeon filter is on and
  you are inside a dungeon or raid. The status filter always applies.

  How, and why it is taint-safe:

    * Quest log: a hooksecurefunc post-hook on the global QuestLogQuests_Update. Blizzard has then
      built the whole list (pooled title, header and objective frames) and laid it out with its
      VerticalLayoutFrame (every row anchored TOPLEFT on QuestScrollFrame.Contents at an absolute
      offset). The hook hides the rows of filtered quests (with their objective lines and POI
      number buttons) and the zone headers left without a visible quest, moves the rows below up
      by the space the hidden rows took (read back from Blizzard's own offsets, not assumed) and
      makes Contents that much shorter. Only widget methods (Hide, Show, ClearAllPoints, SetPoint,
      SetHeight) on frames that are not protected; nothing of Blizzard's is called, replaced or
      written into. Blizzard's next update rebuilds everything, and its own Layout skips hidden
      rows, so nothing can get stuck. Changing the setting puts back exactly what the last pass
      changed, then filters again. The quest log has no protected frames, so this also works in
      combat.
    * The "Quests: 37/40" count gets " (12 shown)" while a filter is on, re-applied after each
      of Blizzard's updates of the count.
    * Gear menu: Menu.ModifyMenu on Blizzard's tag (the public API for adding to a Blizzard menu).
    * Tracker: no new mechanism. The main file's layout pass (hooksecurefunc on the
      QuestObjectiveTracker's Update/UpdateHeight, out of combat only) already hides quest blocks
      past "Max quests shown"; filtered quests are hidden by that same code. With auto-watch on,
      filtered quests are also left out of the ranking, so auto-watch fills the tracker with
      quests you can see (auto-watch owns the watch list then anyway). With auto-watch off, your
      watch list is never touched: filtered quests are only hidden from view, and in combat the
      section is Blizzard's own (as for the limit), so they show until the fight ends.
]]

local _, NS = ...
if type(NS) ~= "table" then NS = {} end
local _G = _G

local F = {
    logState = "not hooked yet",
    menuState = "not registered yet",
    STATUS = { all = "Show all quests", completed = "Only completed", uncompleted = "Only uncompleted" },
    ORDER = { "all", "completed", "uncompleted" },
    INSTANCE = { all = "All quests (any type)", only = "Only dungeon & raid quests", none = "No dungeon & raid quests" },
    INSTANCE_ORDER = { "all", "only", "none" },
    MENU_TAG = "MENU_QUEST_MAP_FRAME_SETTINGS",
    SUFFIX_COLOR = "|cffff9933",
}
NS.filters = F

local function Core() return NS.core end

local function DB()
    local c = NS.core
    return c and c.DB() or nil
end

local function IsSecret(v)
    local c = NS.core
    return c ~= nil and c.IsSecret(v) == true
end

local function Print(msg)
    local c = NS.core
    if c and c.Print then c.Print(msg) end
end

local function pcall1(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if ok then return v end
end

-- true only for a plain true (or 1); a secret value is never compared.
local function True(v)
    if IsSecret(v) then return false end
    return v == true or v == 1
end

local function Num(v)
    if type(v) == "number" and not IsSecret(v) then return v end
end

local function Protected(f)
    if type(f) ~= "table" or type(f.IsProtected) ~= "function" then return false end
    local ok, p = pcall(f.IsProtected, f)
    return ok and True(p)
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function F.Status()
    local db = DB()
    local s = db and db.questFilter
    return (s == "completed" or s == "uncompleted") and s or "all"
end

-- "all" | "only" | "none".
function F.Instance()
    local db = DB()
    local v = db and db.instanceFilter
    return (v == "only" or v == "none") and v or "all"
end

function F.Active()
    return F.Status() ~= "all" or F.Instance() ~= "all"
end

-- Ready to turn in.
function F.IsReady(questID)
    local ql = _G.C_QuestLog
    if type(ql) ~= "table" then return false end
    if True(pcall1(ql.ReadyForTurnIn, questID)) then return true end
    return True(pcall1(ql.IsComplete, questID))
end

-- Tagged Dungeon or Raid (the core's guarded tag reader, shared with the dungeon filter).
function F.IsInstanceQuest(questID)
    local c = Core()
    if not (c and type(c.IsInstanceQuest) == "function") then return false end
    local ok, v = pcall(c.IsInstanceQuest, questID)
    return ok and v == true
end

-- The dungeon & raid choice pauses while the dungeon filter applies (inside a dungeon or raid).
function F.InstancePaused()
    local c = Core()
    if not (c and type(c.DungeonFilterApplies) == "function") then return false end
    local ok, v = pcall(c.DungeonFilterApplies)
    return ok and v == true
end

-- The test for one pass: hides(questID[, complete]) -> true when the quest is filtered out, or
-- nil when nothing is filtered right now.
function F.Tester()
    local status = F.Status()
    local inst = F.Instance()
    if inst ~= "all" and F.InstancePaused() then inst = "all" end
    if status == "all" and inst == "all" then return nil end
    return function(questID, complete)
        if Num(questID) == nil then return false end
        if status ~= "all" then
            if not complete then complete = F.IsReady(questID) end
            if (status == "completed") ~= (complete == true) then return true end
        end
        if inst ~= "all" and (inst == "only") ~= F.IsInstanceQuest(questID) then return true end
        return false
    end
end

-- Auto-watch's ranking without the filtered quests, or nil when nothing is filtered.
function F.Narrow(list)
    local hides = F.Tester()
    if not hides or type(list) ~= "table" then return nil end
    local out = {}
    for _, d in ipairs(list) do
        if not hides(d.id, d.complete) then out[#out + 1] = d end
    end
    return out
end

-- Quests in the log (not headers, not hidden or task entries) and how many the filter keeps.
-- shown is nil when no filter is on.
function F.Counts(hides)
    local ql = _G.C_QuestLog
    if type(ql) ~= "table" then return 0, nil end
    local n = Num(pcall1(ql.GetNumQuestLogEntries)) or 0
    local total, shown = 0, hides and 0 or nil
    for i = 1, n do
        local info = pcall1(ql.GetInfo, i)
        if type(info) == "table" and not True(info.isHeader) and not True(info.isHidden) and not True(info.isTask) then
            local id = Num(info.questID)
            if id then
                total = total + 1
                if hides and not hides(id) then shown = shown + 1 end
            end
        end
    end
    return total, shown
end

-- ---------------------------------------------------------------------------
-- Quest log list
-- ---------------------------------------------------------------------------

function F.LogFrames()
    local sf = _G.QuestScrollFrame
    if type(sf) ~= "table" then
        local qmf = _G.QuestMapFrame
        local qf = type(qmf) == "table" and qmf.QuestsFrame
        sf = type(qf) == "table" and qf.ScrollFrame or nil
    end
    local contents = type(sf) == "table" and sf.Contents
    if type(contents) ~= "table" or type(contents.GetChildren) ~= "function" or type(contents.SetHeight) ~= "function" then
        return nil
    end
    return sf, contents
end

-- Puts back exactly what the last pass changed (only valid while Blizzard has not rebuilt the
-- list since; a rebuild drops the record instead, see ApplyLog).
function F.RestoreLog()
    local rec = F.log
    F.log = nil
    if not rec then return end
    for frame, a in pairs(rec.anchors) do
        pcall(frame.ClearAllPoints, frame)
        pcall(frame.SetPoint, frame, a[1], a[2] or rec.contents, a[3] or "TOPLEFT", a[4], a[5])
    end
    for frame in pairs(rec.hidden) do pcall(frame.Show, frame) end
    if rec.height then pcall(rec.contents.SetHeight, rec.contents, rec.height) end
end

-- The rows of the list (Blizzard's layout children) top to bottom, with their TOPLEFT offsets.
-- nil and why when the layout is not the one this was written against.
function F.ReadRows(contents)
    local rows = {}
    for _, c in ipairs({ contents:GetChildren() }) do
        if type(c) == "table" and Num(c.layoutIndex) and not c.ignoreInLayout
            and type(c.IsShown) == "function" and c:IsShown() then
            rows[#rows + 1] = c
        end
    end
    table.sort(rows, function(a, b) return a.layoutIndex < b.layoutIndex end)
    local prev
    for k, c in ipairs(rows) do
        if Protected(c) then return nil, "a quest log row is protected" end
        local np = pcall1(c.GetNumPoints, c)
        if Num(np) ~= 1 then return nil, "a quest log row has " .. tostring(np) .. " anchors" end
        local ok, p, rel, rp, x, y = pcall(c.GetPoint, c, 1)
        if not ok or p ~= "TOPLEFT" or (rel ~= nil and rel ~= contents) or not Num(x) or not Num(y) then
            return nil, "a quest log row is not anchored TOPLEFT on the list"
        end
        local top = -y
        local start = top - (Num(c.topPadding) or 0)
        if prev and start < prev - 0.5 then return nil, "the quest log rows are not top to bottom" end
        prev = start
        rows[k] = { frame = c, point = { p, rel, rp, x, y }, start = start }
    end
    return rows
end

-- fromHook: Blizzard has just rebuilt the list, so the last record is void.
function F.ApplyLog(fromHook)
    if fromHook then F.log = nil else F.RestoreLog() end
    local _, contents = F.LogFrames()
    if not contents then F.logState = "quest log not found" return end
    local hides = F.Tester()
    if not hides then
        F.logState = "no filter"
        F.UpdateCount()
        return
    end
    local ql = _G.C_QuestLog
    if type(ql) ~= "table" or type(ql.GetInfo) ~= "function" then F.logState = "C_QuestLog.GetInfo missing" return end

    -- Which zone headers keep a visible quest (collapsed or not, so a header can still be opened).
    local n = Num(pcall1(ql.GetNumQuestLogEntries)) or 0
    local isHeader, keepHeader, lastHeader = {}, {}, nil
    for i = 1, n do
        local info = pcall1(ql.GetInfo, i)
        if type(info) == "table" then
            if True(info.isHeader) then
                isHeader[i], lastHeader = true, i
            elseif lastHeader and not True(info.isHidden) and not True(info.isTask) then
                local id = Num(info.questID)
                if id and not hides(id) then keepHeader[lastHeader] = true end
            end
        end
    end

    local rows, why = F.ReadRows(contents)
    if not rows then
        F.logState = "left to Blizzard - " .. why
        F.UpdateCount()
        return
    end
    local hide, hiddenQuests, titles = {}, {}, {}
    for _, r in ipairs(rows) do
        local c = r.frame
        local id = Num(c.questID)
        if type(c.info) == "table" and id then
            titles[c] = true
            if hides(id) then hide[c], hiddenQuests[id] = true, true end
        else
            local index = Num(c.questLogIndex)
            if index and isHeader[index] and not keepHeader[index] then hide[c] = true end
        end
    end
    -- Objective lines and POI buttons of hidden quests: not rows, anchored to their row.
    local attached = {}
    for _, c in ipairs({ contents:GetChildren() }) do
        if type(c) == "table" and not titles[c] and not hide[c] and type(c.IsShown) == "function" and c:IsShown() then
            local id = Num(c.questID)
            if (c.parent ~= nil and hide[c.parent]) or (id and hiddenQuests[id] and not Num(c.layoutIndex)) then
                if Protected(c) then
                    F.logState = "left to Blizzard - a quest log element is protected"
                    return
                end
                attached[#attached + 1] = c
            end
        end
    end
    if not next(hide) then
        F.logState = "on - nothing to hide"
        F.UpdateCount()
        return
    end

    local height = Num(pcall1(contents.GetHeight, contents))
    if not height then F.logState = "left to Blizzard - list height unreadable" return end
    local bottom = height - (Num(contents.bottomPadding) or 0)
    local rec = { contents = contents, hidden = {}, anchors = {}, height = height }
    F.log = rec
    local shift = 0
    for k, r in ipairs(rows) do
        local c = r.frame
        if hide[c] then
            local stop = rows[k + 1] and rows[k + 1].start or bottom
            shift = shift + math.max(0, stop - r.start)
            c:Hide()
            rec.hidden[c] = true
        elseif shift > 0 then
            local p = r.point
            rec.anchors[c] = p
            c:ClearAllPoints()
            c:SetPoint(p[1], contents, p[3] or "TOPLEFT", p[4], p[5] + shift)
        end
    end
    for _, c in ipairs(attached) do
        c:Hide()
        rec.hidden[c] = true
    end
    if shift > 0 then contents:SetHeight(math.max(1, height - shift)) end
    local quests = 0
    for _ in pairs(hiddenQuests) do quests = quests + 1 end
    F.logState = "on - " .. quests .. " quest row" .. (quests == 1 and "" or "s") .. " hidden"
    F.UpdateCount()
end

-- "Quests: 37/40" + " (12 shown)" while a filter is on (" (12)" when the long form would not fit).
function F.UpdateCount()
    local fs = _G.QuestLogQuestCount
    if type(fs) ~= "table" or type(fs.GetText) ~= "function" or type(fs.SetText) ~= "function" then return end
    local ok, text = pcall(fs.GetText, fs)
    if not ok or type(text) ~= "string" or IsSecret(text) then return end
    local base = text:gsub("%s*|cffff9933%(%d+[^%)]*%)|r$", "")
    local want = base
    local hides = F.Tester()
    if hides then
        local _, shown = F.Counts(hides)
        if shown then
            want = base .. " " .. F.SUFFIX_COLOR .. "(" .. shown .. " shown)|r"
            local box = fs.GetParent and fs:GetParent()
            local room = type(box) == "table" and Num(pcall1(box.GetWidth, box))
            if want ~= text then pcall(fs.SetText, fs, want) end
            local w = Num(pcall1(fs.GetStringWidth, fs))
            if room and w and w > room - 8 then want = base .. " " .. F.SUFFIX_COLOR .. "(" .. shown .. ")|r" end
        end
    end
    local okNow, now = pcall(fs.GetText, fs)
    if not okNow or IsSecret(now) or now ~= want then pcall(fs.SetText, fs, want) end
end

function F.OnLogUpdate()
    local ok, err = pcall(F.ApplyLog, true)
    if not ok then
        F.logState = "error: " .. tostring(err)
        pcall(F.RestoreLog)
    end
end

-- Hooks and the gear menu; idempotent, called again when the world map loads late.
function F.Setup()
    if type(_G.hooksecurefunc) ~= "function" then F.logState = "hooksecurefunc not found" return end
    if not F.logHooked and type(_G.QuestLogQuests_Update) == "function" then
        F.logHooked = pcall(_G.hooksecurefunc, "QuestLogQuests_Update", F.OnLogUpdate)
        if F.logHooked then F.logState = "hooked" end
    end
    if not F.countHooked and type(_G.QuestLogQuests_ShowQuestCount) == "function" then
        F.countHooked = pcall(_G.hooksecurefunc, "QuestLogQuests_ShowQuestCount", function() pcall(F.UpdateCount) end)
    end
    if not F.logHooked then F.logState = "QuestLogQuests_Update not found (quest log not loaded yet?)" end
    F.RegisterMenu()
end

-- After a settings change: the log at once (works in combat), the tracker through the core
-- (deferred until after combat there).
function F.Refresh()
    local ok, err = pcall(F.ApplyLog, false)
    if not ok then
        F.logState = "error: " .. tostring(err)
        pcall(F.RestoreLog)
    end
    local c = Core()
    if c and c.ApplyNow then pcall(c.ApplyNow) end
end

-- Only the dungeon & raid part depends on where you are.
function F.OnZoneChanged()
    if F.Instance() ~= "all" then F.Refresh() end
end

-- ---------------------------------------------------------------------------
-- Menus, slash, status
-- ---------------------------------------------------------------------------

function F.Describe()
    local parts = {}
    if F.Status() ~= "all" then parts[#parts + 1] = F.STATUS[F.Status()]:lower() end
    if F.Instance() ~= "all" then
        parts[#parts + 1] = (F.Instance() == "only" and "only dungeon & raid quests" or "dungeon & raid quests hidden")
            .. (F.InstancePaused() and " (paused: dungeon filter in this instance)" or "")
    end
    if #parts == 0 then return "off (all quests shown)" end
    return table.concat(parts, ", ")
end

function F.SetStatus(mode)
    local db = DB()
    if not db or not F.STATUS[mode] then return end
    db.questFilter = mode
    Print("quest filter: " .. F.Describe() .. ". Applies to the quest log and the tracker"
        .. ((Core() and Core().InCombat and Core().InCombat()) and " (tracker after combat)." or "."))
    F.Refresh()
end

function F.SetInstance(mode)
    local db = DB()
    if not db or not F.INSTANCE[mode] then return end
    db.instanceFilter = mode
    Print("quest filter: " .. F.Describe() .. "."
        .. (mode ~= "all" and " Inside a dungeon or raid with the dungeon filter on, this pauses so that instance's quests stay visible." or ""))
    F.Refresh()
end

-- The filter as menu data (BF.RenderMenu format), shared by the gear menu, the tracker header's
-- "Quest log filter" submenu and the hub.
function F.MenuEntries()
    local list = {}
    for _, k in ipairs(F.ORDER) do
        list[#list + 1] = { text = F.STATUS[k], radio = true,
            checked = function() return F.Status() == k end, func = function() F.SetStatus(k) end }
    end
    list[#list + 1] = { divider = true }
    for _, k in ipairs(F.INSTANCE_ORDER) do
        list[#list + 1] = { text = F.INSTANCE[k], radio = true,
            checked = function() return F.Instance() == k end, func = function() F.SetInstance(k) end }
    end
    return list
end

function F.AddGearEntries(root)
    local c = Core()
    if type(root.CreateDivider) == "function" then root:CreateDivider() end
    if type(root.CreateTitle) == "function" then root:CreateTitle((c and c.Title) or "GaarQuestsForever") end
    if c and type(c.RenderMenu) == "function" then c.RenderMenu(root, F.MenuEntries(), c.Title) end
end

function F.RegisterMenu()
    if F.menuState == "registered" then return end
    local menu = _G.Menu
    if type(menu) ~= "table" or type(menu.ModifyMenu) ~= "function" then
        F.menuState = "Menu.ModifyMenu not available"
        return
    end
    local ok, err = pcall(menu.ModifyMenu, F.MENU_TAG, function(_, root)
        if F.menuBroken or not DB() then return end
        local okAdd, errAdd = pcall(F.AddGearEntries, root)
        if not okAdd then
            F.menuBroken = true
            Print("the quest log gear menu entries are switched off for this session: this client refused them. ("
                .. tostring(errAdd) .. ") /gqf filter still works.")
        end
    end)
    F.menuState = ok and "registered" or ("error: " .. tostring(err))
end

function F.Usage()
    Print("/gqf filter all | completed | uncompleted - which quests the quest log and the tracker show (now: " .. F.Status() .. ")")
    Print("/gqf filter dungeons all | only | none - all quests, only Dungeon/Raid quests, or none of them (now: " .. F.Instance() .. "; on = none, off = all)")
end

function F.Slash(rest)
    rest = rest or ""
    if rest == "" then
        Print("quest filter: " .. F.Describe())
        F.Usage()
    elseif F.STATUS[rest] then
        F.SetStatus(rest)
    elseif rest == "uncomplete" or rest == "incomplete" then
        F.SetStatus("uncompleted")
    elseif rest == "complete" then
        F.SetStatus("completed")
    else
        local onOff = rest:match("^dungeons? (%a+)$") or rest:match("^instances? (%a+)$") or rest:match("^raids? (%a+)$")
        local alias = { on = "none", off = "all" }
        local mode = onOff and (alias[onOff] or onOff)
        if mode and F.INSTANCE[mode] then
            F.SetInstance(mode)
        else
            F.Usage()
        end
    end
end

function F.StatusLines()
    local _, shown = F.Counts(F.Tester())
    local total = F.Counts(nil)
    local lines = { "quest filter: " .. F.Describe()
        .. (shown and string.format(" - %d of %d quests shown", shown, total) or "") }
    local c = Core()
    local tf = c and c.TrackerFiltered and c.TrackerFiltered()
    lines[2] = "  quest log: " .. tostring(F.logState) .. "   gear menu: " .. tostring(F.menuState)
        .. (F.menuBroken and " (switched off after an error)" or "")
        .. "   tracker: " .. (tf and (tf .. " block" .. (tf == 1 and "" or "s") .. " hidden by the filter") or "-")
    return lines
end

-- One short word for the minimap tooltip line, or nil.
function F.StateWord()
    if not F.Active() then return nil end
    local parts = {}
    if F.Status() ~= "all" then parts[#parts + 1] = F.Status() end
    if F.Instance() ~= "all" then parts[#parts + 1] = F.Instance() == "only" and "only dungeons" or "no dungeons" end
    return "filter: " .. table.concat(parts, "+")
end
