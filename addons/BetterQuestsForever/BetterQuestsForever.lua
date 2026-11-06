--[[
  BetterQuestsForever - order and limit the Quests section of the native objective tracker on
  WoW Forever.

  Forever ships the retail objective tracker (Blizzard_ObjectiveTracker). Its Quests section,
  QuestObjectiveTracker, shows the tracked (watched) quests in watch-list order. This addon
  changes two things about that section and nothing else:

    * Order: by quest level, lowest first, ties by title. Quests that are ready to turn in go to
      the bottom (default), to the top, or are sorted among the others by level.
    * Limit: only the first N quests of that order are shown (default 10). The rest stay tracked;
      they are only not drawn.

  Every tracked quest stays tracked. The addon never untracks a quest to satisfy the limit.

  How, and why it is taint-safe (the Quests section carries quest item buttons, and the click
  on one calls the protected UseQuestLogSpecialItem):

    * The order is set in the watch list itself. Blizzard's tracker reads the watch list through
      C_QuestLog.GetNumQuestWatches and C_QuestLog.GetQuestIDForQuestWatchIndex and keeps that
      order (QuestObjectiveTrackerMixin:BuildQuestWatchInfos). A quest that is out of place is
      moved to the end with C_QuestLog.RemoveQuestWatch immediately followed by
      C_QuestLog.AddQuestWatch with the same watch type, so it is tracked again before the
      next line of code runs. The values Blizzard reads come from the client, not from addon
      code, so its layout code never reads anything this addon wrote. Only out of combat.
    * The limit is applied after Blizzard's own layout, from hooksecurefunc hooks on the
      QuestObjectiveTracker instance's Update and UpdateHeight. Quest blocks past the N-th are
      hidden with the widget method Hide(), together with the frames Blizzard parks next to
      them (the item button, the find-group button, progress and timer bars), and the section's
      frame is made shorter so the next section moves up. Only out of combat, and only frames
      that are not protected. The addon never writes a field into a Blizzard table, never calls
      a Blizzard Lua function of the tracker and never sets an attribute, so the code path that
      sets up the quest item buttons (SetAttribute("questLogIndex", ...)) always runs untainted.
    * Combat: nothing is changed while InCombatLockdown() is true. On PLAYER_REGEN_DISABLED,
      which fires just before the lockdown starts, everything the addon hid is shown again, so
      for the whole fight the Quests section is exactly Blizzard's own. On PLAYER_REGEN_ENABLED
      the order and the limit are applied again.

  Everything is feature-checked. If the tracker is not the structure this was written against,
  the addon does nothing and says so in /bqf status.
]]

local _G = _G
local ADDON_NAME = ... or "BetterQuestsForever"
local PREFIX = "|cff33ff99BetterQuestsForever|r: "

local MIN_MAX, MAX_MAX = 1, 50
local COMPLETED_MODES = { top = true, level = true, bottom = true }

local DEFAULTS = {
    enabled = true,
    max = 10,
    completed = "bottom",
}

-- Every key BetterQuestsForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = { enabled = true, max = true, completed = true }

-- How long events are collected before the order and the limit are re-evaluated.
local THROTTLE = 0.3

-- If the client keeps undoing the order (it re-sorts the watch list on its own), the addon
-- stops reordering instead of fighting it: more than this many reorders inside the window.
local LOOP_LIMIT, LOOP_WINDOW = 15, 10

local db                -- BetterQuestsForeverDB, bound at ADDON_LOADED (never at file scope)
local tracker           -- the QuestObjectiveTracker module once recognised
local trackerProblem    -- why the tracker was not recognised, for /bqf status
local hooked            -- our hooksecurefunc hooks are in place
local limitProblem      -- why the limit is switched off, for /bqf status
local sortProblem       -- why sorting is switched off, for /bqf status
local lastWarning       -- the last thing that went wrong while reordering
local pending           -- an evaluation is waiting (throttle or combat)
local trimmedHeight     -- we shortened the section's frame
local shownCount        -- quest blocks visible after the last limit pass
local reorderTimes = {} -- GetTime() of recent reorders, for the loop guard
local reorderCount = 0

-- Frames we hid, so they can be shown again. Weak keys: a frame Blizzard drops is forgotten.
local hiddenBlocks = setmetatable({}, { __mode = "k" })
local hiddenRegions = setmetatable({}, { __mode = "k" }) -- region -> the block it belonged to

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end

local function InCombat()
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() and true or false
end

local function Now()
    return type(_G.GetTime) == "function" and _G.GetTime() or 0
end

-- Calls a client function without letting an unexpected error escape.
local function Try(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function QuestLog()
    local ql = _G.C_QuestLog
    if type(ql) == "table" then return ql end
end

-- The watch-list functions sorting needs. Returns the missing name, or nil when all are there.
local WATCH_API = { "GetNumQuestWatches", "GetQuestIDForQuestWatchIndex", "AddQuestWatch", "RemoveQuestWatch",
    "GetLogIndexForQuestID" }

local function MissingWatchApi()
    local ql = QuestLog()
    if not ql then return "C_QuestLog" end
    for _, name in ipairs(WATCH_API) do
        if type(ql[name]) ~= "function" then return "C_QuestLog." .. name end
    end
    if type(ql.GetInfo) ~= "function" and type(_G.GetQuestLogTitle) ~= "function" then
        return "C_QuestLog.GetInfo"
    end
end

local function IsFrame(f)
    return type(f) == "table" and type(f.Hide) == "function" and type(f.Show) == "function"
        and type(f.IsShown) == "function"
end

local function IsProtectedFrame(f)
    if type(f) == "table" and type(f.IsProtected) == "function" then
        local ok, protected = pcall(f.IsProtected, f)
        return ok and protected and true or false
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The watch list
-- ---------------------------------------------------------------------------

local function GetWatches()
    local ql = QuestLog()
    local list = {}
    if not ql then return list end
    local ok, n = Try(ql.GetNumQuestWatches)
    if not ok or type(n) ~= "number" then return list end
    for i = 1, n do
        local okID, questID = Try(ql.GetQuestIDForQuestWatchIndex, i)
        if okID and type(questID) == "number" and questID > 0 then list[#list + 1] = questID end
    end
    return list
end

local function IsWatched(questID)
    for _, id in ipairs(GetWatches()) do
        if id == questID then return true end
    end
    return false
end

local function GetWatchType(questID)
    local ql = QuestLog()
    if ql and type(ql.GetQuestWatchType) == "function" then
        local ok, watchType = pcall(ql.GetQuestWatchType, questID)
        if ok then return watchType end
    end
end

-- Tracks the quest again, with its old watch type when the client has watch types.
local function ReAdd(questID, watchType)
    local ql = QuestLog()
    if watchType ~= nil then Try(ql.AddQuestWatch, questID, watchType) end
    if not IsWatched(questID) then Try(ql.AddQuestWatch, questID) end
    if not IsWatched(questID) then Try(ql.AddQuestWatch, questID) end
    return IsWatched(questID)
end

-- ---------------------------------------------------------------------------
-- Quest data and the order
-- ---------------------------------------------------------------------------

local function Classification(questID)
    local qis = _G.C_QuestInfoSystem
    if type(qis) == "table" and type(qis.GetQuestClassification) == "function" then
        local ok, c = pcall(qis.GetQuestClassification, questID)
        if ok then return c end
    end
end

local function CampaignClassification()
    local enum = _G.Enum
    local qc = type(enum) == "table" and enum.QuestClassification
    return type(qc) == "table" and qc.Campaign or nil
end

local function IsComplete(questID, info)
    local ql = QuestLog()
    if ql and type(ql.IsComplete) == "function" then
        local ok, complete = pcall(ql.IsComplete, questID)
        if ok then return complete and true or false end
    end
    return info and info.isComplete and true or false
end

-- Level, title, completion and whether the Quests section shows it at all.
local function QuestData(questID)
    local ql = QuestLog()
    local okIndex, index = Try(ql and ql.GetLogIndexForQuestID, questID)
    if not okIndex then index = nil end
    local level, title, isTask, isBounty, info
    if index and ql and type(ql.GetInfo) == "function" then
        local ok, i = pcall(ql.GetInfo, index)
        if ok and type(i) == "table" then
            info = i
            level = i.level
            if type(level) ~= "number" or level <= 0 then level = i.difficultyLevel end
            title, isTask, isBounty = i.title, i.isTask, i.isBounty
        end
    elseif index and type(_G.GetQuestLogTitle) == "function" then
        local ok, t, l = pcall(_G.GetQuestLogTitle, index)
        if ok then title, level = t, l end
    end
    local d = {
        id = questID,
        level = type(level) == "number" and level or 0,
        title = type(title) == "string" and title or "",
        complete = IsComplete(questID, info),
    }
    d.titleKey = d.title:lower()

    -- The same test as QuestObjectiveTrackerMixin:ShouldDisplayQuest: tasks, bounties, campaign
    -- quests (their own section) and quests disabled for the session are not in the Quests section.
    local shown = not isTask and not isBounty
    local campaign = CampaignClassification()
    if shown and campaign ~= nil and Classification(questID) == campaign then shown = false end
    if shown and ql and type(ql.IsQuestDisabledForSession) == "function" then
        local ok, disabled = pcall(ql.IsQuestDisabledForSession, questID)
        if ok and disabled then shown = false end
    end
    d.inQuestsSection = shown
    return d
end

-- Level ascending, ties by title, then quest ID so the order is always the same. Completed
-- quests first or last unless the mode is "level".
local function Compare(a, b)
    local mode = db and db.completed or DEFAULTS.completed
    if a.complete ~= b.complete and mode ~= "level" then
        if mode == "top" then return a.complete end
        return b.complete
    end
    if a.level ~= b.level then return a.level < b.level end
    if a.titleKey ~= b.titleKey then return a.titleKey < b.titleKey end
    if a.title ~= b.title then return a.title < b.title end
    return a.id < b.id
end

-- The Quests-section quests in the wanted order, plus their current watch order.
local function DesiredOrder()
    local current, data = {}, {}
    for _, questID in ipairs(GetWatches()) do
        local d = QuestData(questID)
        if d.inQuestsSection then
            current[#current + 1] = questID
            data[#data + 1] = d
        end
    end
    table.sort(data, Compare)
    local sorted = {}
    for i, d in ipairs(data) do sorted[i] = d.id end
    return sorted, current
end

-- The quests that have to move to the end of the watch list. The longest run of the wanted
-- order that already stands in the right relative order stays put; everything after it is
-- moved, in order. Other watches (campaign, tasks) are never moved.
local function QuestsToMove(sorted, current)
    local p = 1
    for _, questID in ipairs(current) do
        if sorted[p] == questID then p = p + 1 end
    end
    local moves = {}
    for i = p, #sorted do moves[#moves + 1] = sorted[i] end
    return moves
end

local function LoopGuardTripped()
    local now = Now()
    local kept = {}
    for _, t in ipairs(reorderTimes) do
        if now - t <= LOOP_WINDOW then kept[#kept + 1] = t end
    end
    kept[#kept + 1] = now
    reorderTimes = kept
    return #kept > LOOP_LIMIT
end

-- Puts the watch list in the wanted order. Out of combat only. Every quest that is taken off
-- the list is put back immediately, and at the end every quest that was tracked before is
-- checked and re-tracked if the client dropped it.
local function ReorderWatches()
    if sortProblem or InCombat() then return end
    local missing = MissingWatchApi()
    if missing then
        sortProblem = missing .. " missing"
        return
    end

    local sorted, current = DesiredOrder()
    local moves = QuestsToMove(sorted, current)
    if #moves == 0 then return end
    if LoopGuardTripped() then
        sortProblem = "paused: the client keeps changing the watch order back (/bqf on to try again)"
        Print("sorting paused - the client keeps re-sorting the watch list. /bqf on tries again.")
        return
    end

    local ql = QuestLog()
    local before = GetWatches()
    local watchTypes = {}
    for _, questID in ipairs(before) do watchTypes[questID] = GetWatchType(questID) end
    local superTrack = _G.C_SuperTrack
    local superTracked
    if type(superTrack) == "table" and type(superTrack.GetSuperTrackedQuestID) == "function" then
        local ok, id = pcall(superTrack.GetSuperTrackedQuestID)
        if ok then superTracked = id end
    end

    for i, questID in ipairs(moves) do
        Try(ql.RemoveQuestWatch, questID)
        if not ReAdd(questID, watchTypes[questID]) then
            lastWarning = "could not re-track quest " .. questID
            break
        end
        if i == 1 then
            local list = GetWatches()
            if list[#list] ~= questID then
                -- This client does not append a re-added watch at the end, so the order cannot
                -- be set this way. Stop for good rather than shuffle the list again.
                sortProblem = "the client does not append re-added watches; order left to Blizzard"
                break
            end
        end
    end

    -- Nothing tracked before may end up untracked.
    for _, questID in ipairs(before) do
        if not IsWatched(questID) and not ReAdd(questID, watchTypes[questID]) then
            lastWarning = "quest " .. questID .. " could not be re-tracked"
            Print("|cffff6666could not re-track quest " .. questID .. "; track it again from the quest log.|r")
        end
    end

    if superTracked and superTracked ~= 0 and type(superTrack.SetSuperTrackedQuestID) == "function" then
        local ok, now = pcall(superTrack.GetSuperTrackedQuestID)
        if ok and now ~= superTracked and IsWatched(superTracked) then
            Try(superTrack.SetSuperTrackedQuestID, superTracked)
        end
    end
    reorderCount = reorderCount + 1
end

-- ---------------------------------------------------------------------------
-- The tracker and the limit
-- ---------------------------------------------------------------------------

-- Checks that QuestObjectiveTracker is the module structure this addon was written against.
local function RecogniseTracker()
    if tracker then return tracker end
    local t = _G.QuestObjectiveTracker
    if type(t) ~= "table" then
        trackerProblem = "QuestObjectiveTracker not found"
        return
    end
    if type(t.Update) ~= "function" or type(t.UpdateHeight) ~= "function" then
        trackerProblem = "QuestObjectiveTracker:Update/UpdateHeight not found"
        return
    end
    if type(t.BuildQuestWatchInfos) ~= "function" and type(t.EnumQuestWatchData) ~= "function" then
        trackerProblem = "QuestObjectiveTracker does not list quests by watch index"
        return
    end
    if type(t.usedBlocks) ~= "table" or type(t.blockTemplate) ~= "string" then
        trackerProblem = "QuestObjectiveTracker block bookkeeping not found"
        return
    end
    if not IsFrame(t) or type(t.SetHeight) ~= "function" then
        trackerProblem = "QuestObjectiveTracker is not a frame"
        return
    end
    trackerProblem = nil
    tracker = t
    return t
end

local function IsQuestBlock(block)
    return type(block) == "table" and block.template == tracker.blockTemplate and type(block.id) == "number"
end

-- The blocks of the Quests section in the order Blizzard laid them out.
local function BlockChain()
    local chain = {}
    local block = tracker.firstBlock
    local guard = 0
    while type(block) == "table" and guard < 1000 do
        chain[#chain + 1] = block
        block = block.nextBlock
        guard = guard + 1
    end
    return chain
end

local function Regions(block)
    local regions = type(block) == "table" and block.addedRegions
    return type(regions) == "table" and regions or {}
end

-- Blizzard's own section height (ObjectiveTrackerModuleMixin:UpdateHeight), read, not called.
local function FullHeight()
    local contents = tracker.contentsHeight
    if type(contents) ~= "number" then return end
    local h = contents + (type(tracker.bottomSpacing) == "number" and tracker.bottomSpacing or 0)
    if type(tracker.heightModifiers) == "table" then
        for _, v in pairs(tracker.heightModifiers) do
            if type(v) == "number" then h = h + v end
        end
    end
    return h
end

local function SetSectionHeight(trim)
    if not tracker:IsShown() then
        trimmedHeight = false
        return
    end
    local full = FullHeight()
    if not full then return end
    if trim > 0 then
        tracker:SetHeight(math.max(full - trim, 1))
        trimmedHeight = true
    elseif trimmedHeight then
        tracker:SetHeight(full)
        trimmedHeight = false
    end
end

-- Shows again what we hid, except the blocks in keep. A frame is shown only while Blizzard
-- still uses it for the same block, so nothing it released to a pool comes back.
local function Restore(keep)
    for block in pairs(hiddenBlocks) do
        if not keep[block] then
            if block.used and block.parentModule == tracker and not block:IsShown() then block:Show() end
            hiddenBlocks[block] = nil
        end
    end
    for region, owner in pairs(hiddenRegions) do
        if not keep[owner] then
            if owner.used and Regions(owner)[region] ~= nil and not region:IsShown() then region:Show() end
            hiddenRegions[region] = nil
        end
    end
end

local function RestoreAll()
    if not tracker then return end
    Restore({})
    if trimmedHeight then SetSectionHeight(0) end
    shownCount = nil
end

-- Hides the quest blocks past the N-th and shortens the section. Runs after Blizzard's layout.
local function ApplyLimit()
    if not tracker or not db or InCombat() then return end
    if not db.enabled or limitProblem then
        RestoreAll()
        return
    end

    local chain = BlockChain()
    local hide, count, visible = {}, 0, 0
    for _, block in ipairs(chain) do
        if IsQuestBlock(block) then
            count = count + 1
            if count > db.max then
                hide[block] = true
            else
                visible = visible + 1
            end
        end
    end

    -- A protected frame cannot be hidden safely; then the limit stays off on this client.
    for block in pairs(hide) do
        local bad = not IsFrame(block) or IsProtectedFrame(block)
        for region in pairs(Regions(block)) do
            if not IsFrame(region) or IsProtectedFrame(region) then bad = true end
        end
        if bad then
            limitProblem = "a quest block or its item button is protected or not a frame; limit off"
            RestoreAll()
            return
        end
    end

    Restore(hide)
    for block in pairs(hide) do
        if block:IsShown() then block:Hide() end
        hiddenBlocks[block] = true
        for region in pairs(Regions(block)) do
            if region:IsShown() then region:Hide() end
            hiddenRegions[region] = block
        end
    end

    -- Hidden blocks are at the end of the chain; take their share off the section's height,
    -- the same share Blizzard added for them (ObjectiveTrackerModuleMixin:InternalAddBlock).
    local trim = 0
    local offset = type(tracker.fromBlockOffsetY) == "number" and tracker.fromBlockOffsetY or 0
    for i = #chain, 1, -1 do
        local block = chain[i]
        if not hide[block] then break end
        trim = trim + (type(block.height) == "number" and block.height or 0) - offset
    end
    SetSectionHeight(trim)
    shownCount = visible
end

local function OnTrackerLaidOut()
    ApplyLimit()
end

local function HookTracker()
    if hooked then return true end
    if type(_G.hooksecurefunc) ~= "function" then
        trackerProblem = "hooksecurefunc not found"
        return false
    end
    if not RecogniseTracker() then return false end
    -- Instance hooks only: the Campaign section and every other module keep their own methods.
    hooksecurefunc(tracker, "Update", OnTrackerLaidOut)
    hooksecurefunc(tracker, "UpdateHeight", OnTrackerLaidOut)
    hooked = true
    return true
end

-- ---------------------------------------------------------------------------
-- Evaluation: order first, then the limit
-- ---------------------------------------------------------------------------

local function Evaluate()
    pending = false
    if not db then return end
    if InCombat() then
        pending = true
        return
    end
    if not HookTracker() then return end
    if not db.enabled then
        RestoreAll()
        return
    end
    ReorderWatches()
    -- A reorder makes Blizzard lay the section out again, and the hook applies the limit then.
    -- This pass covers a settings change that needs no new layout.
    ApplyLimit()
end

local throttle = CreateFrame("Frame")
throttle:Hide()
local throttleLeft = 0
throttle:SetScript("OnUpdate", function(self, elapsed)
    throttleLeft = throttleLeft - (elapsed or 0)
    if throttleLeft <= 0 then
        self:Hide()
        Evaluate()
    end
end)

local function Schedule()
    if not db then return end
    pending = true
    if InCombat() then return end
    throttleLeft = THROTTLE
    throttle:Show()
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function Yes(v) return v and "yes" or "MISSING" end

local function PrintHelp()
    Print("orders the Quests section of the objective tracker by level and shows only the first N.")
    Print("/bqf max <n> - show at most n quests, 1-50 (now: " .. (db and db.max or DEFAULTS.max) .. ")")
    Print("/bqf completed top | level | bottom - where quests ready to turn in go (now: "
        .. (db and db.completed or DEFAULTS.completed) .. ")")
    Print("/bqf on | off - switch the addon on or off; off is Blizzard's own tracker (now: "
        .. ((db and db.enabled) and "on" or "off") .. ")")
    Print("/bqf status - settings, counts and what this client offers")
end

local function PrintStatus()
    local ql = QuestLog()
    Print("enabled: " .. ((db and db.enabled) and "yes" or "no") .. "   max: " .. db.max
        .. "   completed: " .. db.completed)
    local watches = GetWatches()
    local inSection = 0
    for _, questID in ipairs(watches) do
        if QuestData(questID).inQuestsSection then inSection = inSection + 1 end
    end
    Print(string.format("tracked: %d (Quests section: %d)   shown: %s", #watches, inSection,
        shownCount and tostring(shownCount) or "all (limit not applied)"))
    Print("tracker: " .. (tracker and "QuestObjectiveTracker recognised" or ("not recognised - " .. (trackerProblem or "not checked yet"))))
    Print("hooks: " .. (hooked and "hooksecurefunc on QuestObjectiveTracker Update + UpdateHeight" or "none"))
    Print("sorting: " .. (sortProblem and ("off - " .. sortProblem) or "on") .. "   reorders this session: " .. reorderCount)
    Print("limit: " .. (limitProblem and ("off - " .. limitProblem) or "on"))
    Print("C_QuestLog watches (GetNumQuestWatches, GetQuestIDForQuestWatchIndex, Add/RemoveQuestWatch): "
        .. Yes(not MissingWatchApi()))
    Print("C_QuestLog.GetQuestWatchType: " .. Yes(ql and type(ql.GetQuestWatchType) == "function")
        .. "   C_QuestLog.IsComplete: " .. Yes(ql and type(ql.IsComplete) == "function")
        .. "   C_QuestLog.SortQuestWatches: " .. Yes(ql and type(ql.SortQuestWatches) == "function"))
    local qis = _G.C_QuestInfoSystem
    Print("C_QuestInfoSystem.GetQuestClassification: " .. Yes(type(qis) == "table"
        and type(qis.GetQuestClassification) == "function")
        .. "   C_SuperTrack: " .. Yes(type(_G.C_SuperTrack) == "table"))
    if InCombat() then
        Print("in combat: the tracker is Blizzard's own until combat ends" .. (pending and "; an update is waiting" or ""))
    end
    if lastWarning then Print("last warning: " .. lastWarning) end
end

local function SetEnabled(on)
    db.enabled = on
    if on then
        if sortProblem and sortProblem:find("^paused") then sortProblem = nil end
        reorderTimes = {}
        limitProblem = nil
        Print("on.")
        Schedule()
        return
    end
    -- Off: show everything again and hand the order back to Blizzard's own sort, the one the
    -- tracker itself runs on zone changes (ObjectiveTrackerFrameMixin:OnEvent).
    if InCombat() then
        Print("off. The tracker is already Blizzard's own during combat; the order is handed back after combat.")
        pending = true
        return
    end
    RestoreAll()
    local ql = QuestLog()
    if ql and type(ql.SortQuestWatches) == "function" then Try(ql.SortQuestWatches) end
    Print("off - Blizzard's own tracker.")
end

local offSortPending -- /bqf off in combat: Blizzard's sort runs after combat

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    local n = msg:match("^max (%d+)$")
    local mode = msg:match("^completed (%a+)$")
    if n then
        n = tonumber(n)
        if n < MIN_MAX or n > MAX_MAX then
            Print("max must be between " .. MIN_MAX .. " and " .. MAX_MAX .. ".")
            return
        end
        db.max = n
        Print("showing at most " .. n .. " quests." .. (InCombat() and " Applied after combat." or ""))
        Schedule()
    elseif mode then
        if not COMPLETED_MODES[mode] then
            Print("use /bqf completed top, level or bottom.")
            return
        end
        db.completed = mode
        Print("quests ready to turn in: " .. mode .. "." .. (InCombat() and " Applied after combat." or ""))
        Schedule()
    elseif msg == "on" then
        SetEnabled(true)
    elseif msg == "off" then
        if InCombat() then offSortPending = true end
        SetEnabled(false)
    elseif msg == "status" then
        PrintStatus()
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterQuestsForeverDB) ~= "table" then BetterQuestsForeverDB = {} end
    db = BetterQuestsForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    if type(db.enabled) ~= "boolean" then db.enabled = DEFAULTS.enabled end
    local m = tonumber(db.max)
    if not m or m < MIN_MAX or m > MAX_MAX then m = DEFAULTS.max end
    db.max = math.floor(m)
    if not COMPLETED_MODES[db.completed] then db.completed = DEFAULTS.completed end
end

local events = CreateFrame("Frame")
-- RegisterEvent raises on an event the client does not know, so each one is tried on its own.
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED", "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED", "QUEST_ACCEPTED", "QUEST_REMOVED",
    "QUEST_TURNED_IN", "PLAYER_LEVEL_UP" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            BindSavedVariables()
            Schedule()
        elseif db and not hooked and arg1 == "Blizzard_ObjectiveTracker" then
            Schedule()
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Fires before the lockdown starts: hand the section back to Blizzard for the fight.
        RestoreAll()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if offSortPending and db and not db.enabled then
            offSortPending = false
            local ql = QuestLog()
            if ql and type(ql.SortQuestWatches) == "function" then Try(ql.SortQuestWatches) end
        end
        Schedule()
    else
        Schedule()
    end
end)

SLASH_BETTERQUESTSFOREVER1 = "/bqf"
SLASH_BETTERQUESTSFOREVER2 = "/betterquestsforever"
SlashCmdList.BETTERQUESTSFOREVER = OnSlash
