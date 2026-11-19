--[[
  GaarXPForever - XP at a glance, on WoW Forever (classic-era content, level cap 60).

  Every part is its own switch (saved setting + /gxp <feature> on|off + a hub menu entry):

    * panel (on)        a small movable text panel: XP cur/max (pct%), rested XP (amount and % of
                        the level), XP per hour this session, time to level at that rate, and
                        "about N kills / N quests to level" from the session's average XP per kill
                        and per quest turn-in. Hidden at max level ("Max level").
    * xpbarText (on)    text on Blizzard's XP bar (MainMenuExpBar, or the container of the newer
                        status tracking bars): cur/max, pct and rested. On hover, or always with
                        xpbarAlways (off).
    * levelLog (on)     on level-up, the time played this level and in total (RequestTimePlayed /
                        TIME_PLAYED_MSG). Blizzard's own time-played print is held back for that
                        one request, so chat gets one line, not two.
    * questXP (off)     a quest's XP reward in its tooltip, where the client gives it.
    * questReady (on)   quests in the log that are complete but not turned in: a panel line
                        "Quests ready: N (+X XP)" and "After turn-in: ...", or "Turn in to level
                        up!". Their XP is also taken off the remaining XP, so "To level" and the
                        kill/quest counts are about what is left AFTER turning them in. (The
                        older questXP setting is the reward line in quest tooltips.)
    * questBar (on)     the XP of ready quests as a coloured segment on the XP bar, from the current
                        fill to fill + quest XP (clamped at the end of the bar). Own frame, child of
                        the bar's StatusBar; follows its size and visibility. Needs questReady.
                        /gxp readybar on|off, /gxp readybar color orange|green|yellow.
                        While that segment is shown, the rested XP is drawn after it (quest XP comes
                        first on turn-in and does not use rested): Blizzard's rested overlay and tick
                        are made invisible (SetAlpha 0, restored when the segment goes) and our own
                        rested segment + tick are drawn from fill + quest XP. No extra setting.
    * /gxp reset        resets the session's numbers.

  How XP is counted. PLAYER_XP_UPDATE gives the change (UnitXP delta; across a level-up the rest of
  the old level plus the new XP). The change is classified a short moment later: a
  CHAT_MSG_COMBAT_XP_GAIN since the last one = a kill, a QUEST_TURNED_IN = a quest, anything else
  (exploring, gathering) counts only toward the XP/hour. Chat text is never parsed.

  Taint: Blizzard code is only followed, never replaced. The only hooks are hooksecurefunc on tooltip
  helpers and a HookScript on GameTooltip; the XP bar is only polled (IsMouseOver). Every client API is checked
  with type(...) == "function", every handler runs in pcall (the last error is kept for
  /gxp status), and a secret value is never compared or tested: it is treated as no value.

  Shared helpers come from GaarForever's library (global GaarForever, Lib.lua, loaded first
  through ## Dependencies): the chat prefix, Secret / Num and the menu drawing.
]]

local _G = _G
local ADDON_NAME = ...
ADDON_NAME = ADDON_NAME or "GaarXPForever"
local DOT = " \194\183 "
local VERSION = "1.3.2"

local BF = _G.GaarForever
local A = BF.NewAddon("GaarXPForever", { title = "GaarXPForever", version = VERSION })

local DEFAULT_MAX_LEVEL = 60
local MIN_RATE_SECONDS = 60   -- no XP/hour before a minute of session

local DEFAULTS = {
    enabled = true, panel = true, xpbarText = true, xpbarAlways = false,
    levelLog = true, questXP = false, questReady = true, questBar = true, locked = true,
}
local BAR_COLORS = {          -- /gxp readybar color <name>: r, g, b (alpha is set in SegmentAlpha)
    orange = { 1, 0.5, 0 }, green = { 0.2, 0.9, 0.2 }, yellow = { 1, 0.9, 0.1 },
}
local FEATURES = {            -- /gxp <name> on|off  (lower-case aliases map to the saved key)
    panel = "panel", xpbartext = "xpbarText", xpbar = "xpbarText", always = "xpbarAlways",
    xpbaralways = "xpbarAlways", levellog = "levelLog", level = "levelLog", questxp = "questXP",
    quest = "questXP", ready = "questReady", questready = "questReady",
    readybar = "questBar", questbar = "questBar",
}
local LABELS = {
    panel = "XP panel", xpbarText = "Text on the XP bar", xpbarAlways = "XP bar text always visible",
    levelLog = "Time played on level-up", questXP = "Quest XP in tooltips",
    questReady = "Ready quests in the XP panel", questBar = "Ready quest XP on the XP bar",
}

local db
local lastError

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Print(msg) A:Print(msg) end

local Secret, Num = BF.IsSecret, BF.Num
local function Now() return type(_G.GetTime) == "function" and (Num(_G.GetTime()) or 0) or 0 end
local function Fail(where, err) lastError = where .. ": " .. tostring(err) end
local function Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Fail(where, err) end
end

local function Commas(n)
    n = math.floor((n or 0) + 0.5)
    local s = tostring(math.abs(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. out
end

local function Duration(sec)
    sec = Num(sec)
    if not sec or sec < 0 then return "--" end
    sec = math.floor(sec + 0.5)
    local d, h, m = math.floor(sec / 86400), math.floor(sec % 86400 / 3600), math.floor(sec % 3600 / 60)
    if d > 0 then return d .. "d " .. h .. "h" end
    if h > 0 then return h .. "h " .. m .. "m" end
    if m > 0 then return m .. "m " .. (sec % 60) .. "s" end
    return sec .. "s"
end

local function Enabled(key)
    if not db then return false end
    if key == "enabled" then return db.enabled end
    return db.enabled and db[key] and true or false
end

-- ---------------------------------------------------------------------------
-- XP state
-- ---------------------------------------------------------------------------

local function PlayerLevel()
    return type(_G.UnitLevel) == "function" and Num(_G.UnitLevel("player")) or nil
end

local function MaxLevel()
    local m
    if type(_G.GetMaxPlayerLevel) == "function" then m = Num(_G.GetMaxPlayerLevel()) end
    if not m and type(_G.GetMaxLevelForPlayerExpansion) == "function" then
        m = Num(_G.GetMaxLevelForPlayerExpansion())
    end
    return m or Num(_G.MAX_PLAYER_LEVEL) or DEFAULT_MAX_LEVEL
end

local function AtMax()
    if type(_G.IsPlayerAtEffectiveMaxLevel) == "function" then
        local ok, r = pcall(_G.IsPlayerAtEffectiveMaxLevel)
        if ok and not Secret(r) and type(r) == "boolean" then return r end
    end
    local l = PlayerLevel()
    return l ~= nil and l >= MaxLevel()
end

local function XPValues()
    local cur = type(_G.UnitXP) == "function" and Num(_G.UnitXP("player")) or nil
    local max = type(_G.UnitXPMax) == "function" and Num(_G.UnitXPMax("player")) or nil
    if not cur or not max or max <= 0 then return nil end
    local rested = type(_G.GetXPExhaustion) == "function" and Num(_G.GetXPExhaustion()) or 0
    return cur, max, rested
end

local session
local function ResetSession()
    local cur, max = XPValues()
    session = { start = Now(), gained = 0, kills = 0, killXP = 0, quests = 0, questXP = 0,
        lastXP = cur, lastMax = max }
end
ResetSession()

local flagKill, flagQuest, pendingDelta, pendingTimer

local function Resolve()
    pendingTimer = nil
    local d = pendingDelta
    pendingDelta = nil
    if not d or d <= 0 then flagKill, flagQuest = nil, nil; return end
    session.gained = session.gained + d
    if flagKill then
        session.kills = session.kills + 1; session.killXP = session.killXP + d
    elseif flagQuest then
        session.quests = session.quests + 1; session.questXP = session.questXP + d
    end
    flagKill, flagQuest = nil, nil
end

local function OnXPUpdate()
    local cur, max = XPValues()
    if not cur then return end
    local delta
    if session.lastXP then
        if cur >= session.lastXP and max == session.lastMax then
            delta = cur - session.lastXP
        elseif session.lastMax then   -- level-up: rest of the old level plus the new XP
            delta = (session.lastMax - session.lastXP) + cur
        end
    end
    session.lastXP, session.lastMax = cur, max
    if delta and delta > 0 then
        pendingDelta = (pendingDelta or 0) + delta
        if not pendingTimer then
            pendingTimer = true
            if _G.C_Timer and type(_G.C_Timer.After) == "function" then
                _G.C_Timer.After(0.3, function() Safe("resolve", Resolve) end)
            else
                Resolve()
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Ready quests (complete, not turned in) and the XP maths
-- ---------------------------------------------------------------------------

-- Pure: remaining XP after the ready quests are turned in, kills and time to level.
-- killAvg / rate may be nil (no data). Plain numbers only.
local function Calc(cur, max, questXP, rate, killAvg)
    questXP = (questXP and questXP > 0) and questXP or 0
    local r = { remaining = math.max(0, max - cur - questXP), questXP = questXP }
    r.levelUp = questXP > 0 and questXP >= max - cur
    r.after = math.min(max, cur + questXP)
    r.secs = rate and rate > 0 and (r.remaining / rate * 3600) or nil
    r.kills = killAvg and killAvg > 0 and math.ceil(r.remaining / killAvg) or nil
    return r
end

local ready = { count = 0, xp = 0 }     -- last scan
local RefreshQuestBar                   -- defined with the XP bar code below (forward declared here)

-- Pure geometry of the quest segment on a bar barWidth wide: offset from the left edge and width,
-- clamped at the end of the bar. nil when there is nothing to draw.
local function SegmentGeometry(cur, max, questXP, barWidth)
    if not (cur and max and questXP and barWidth) or max <= 0 or questXP <= 0 or barWidth <= 0 then return nil end
    cur = math.min(math.max(cur, 0), max)
    local offset = barWidth * cur / max
    local width = math.min(barWidth * questXP / max, barWidth - offset)
    if width <= 0 then return nil end
    return offset, width
end

-- Pure geometry of the rested segment drawn AFTER the quest segment: offset, width and tickX (x of the
-- rested marker), all clamped at the end of the bar. tickX is nil when the marker would be beyond the
-- end. nil when there is nothing to draw (no rested, or quest XP already fills the bar).
local function RestedGeometry(cur, questXP, rested, max, barWidth)
    if not (cur and max and rested and barWidth) or max <= 0 or rested <= 0 or barWidth <= 0 then return nil end
    cur = math.min(math.max(cur, 0), max)
    questXP = math.max(questXP or 0, 0)
    local start = math.min(cur + questXP, max)
    local offset = barWidth * start / max
    local width = math.min(barWidth * rested / max, barWidth - offset)
    if width <= 0 then return nil end
    local tickX = (start + rested <= max) and (offset + width) or nil
    return offset, width, tickX
end
local readyDirty, lastScan, ignoreLogUntil = true, -10, 0
local scanNoSelect, scanTimerDue, followDue = false, nil, nil
local SCAN_INTERVAL = 0.5

local function Call(f, ...)
    if type(f) ~= "function" then return nil end
    local ok, a, b, c, d, e, g, h, i = pcall(f, ...)
    if ok and not Secret(a) then return a, b, c, d, e, g, h, i end
end

-- XP reward of one quest, first source that gives > 0 wins (the old questXP tooltip line uses 1 + 2):
--  1. C_QuestLog.GetQuestLogRewardXP(questID)
--  2. global GetQuestLogRewardXP(questID): retail engine takes a questID, classic ignores it and reads
--     the SELECTED entry, so it is only trusted when that quest is the selected one
--  3. select the quest (C_QuestLog.SetSelectedQuest) and call GetQuestLogRewardXP(), then restore the
--     selection; skipped while a quest log / map window may show the player's own selection
--  4. legacy SelectQuestLogEntry(index) + GetQuestLogRewardXP(), same window rule
-- A value is cached per questID (until QUEST_TURNED_IN or the quest leaves the log). If nothing gave
-- XP, the quest data is requested (RequestLoadQuestByID) and QUEST_DATA_LOAD_RESULT rescans.
-- Our own selection changes fire QUEST_LOG_UPDATE; those are ignored for 0.5 s (ignoreLogUntil).
local xpCache = {}      -- [questID] = { xp, src }
local loadAsked = {}    -- [questID] = time of the last data request
local LOAD_RETRY = 30

local function LogWindowOpen()
    for _, name in ipairs({ "QuestLogFrame", "QuestMapFrame", "WorldMapFrame" }) do
        local f = _G[name]
        if f and type(f.IsShown) == "function" then
            local ok, shown = pcall(f.IsShown, f)
            if ok and shown then return true end
        end
    end
    return false
end

local function Raw(v)
    if v == nil then return "nil" end
    if Secret(v) then return "secret" end
    return tostring(v)
end

-- Returns xp (number, may be 0), source name or nil, and a list of raw returns for the debug output.
local function ReadyQuestXP(questID, index)
    local hit = xpCache[questID]
    if hit then return hit.xp, hit.src, { "cached" } end
    local C = _G.C_QuestLog
    local raws = {}
    local function try(src, f, ...)
        local v = Call(f, ...)
        raws[#raws + 1] = src .. "=" .. Raw(v)
        v = Num(v)
        if v and v > 0 then xpCache[questID] = { xp = v, src = src }; return v, src end
    end
    local gFn = type(_G.GetQuestLogRewardXP) == "function" and _G.GetQuestLogRewardXP or nil

    -- 1
    if C and type(C.GetQuestLogRewardXP) == "function" then
        local v, src = try("C_QuestLog", C.GetQuestLogRewardXP, questID)
        if v then return v, src, raws end
    end
    -- 2
    if gFn then
        local selected
        if C and type(C.GetSelectedQuest) == "function" then selected = Num(Call(C.GetSelectedQuest)) end
        local selIndex = type(_G.GetQuestLogSelection) == "function" and Num(Call(_G.GetQuestLogSelection)) or nil
        if (selected and selected == questID) or (index and selIndex and selIndex == index) then
            local v, src = try("global(selected)", gFn, questID)
            if v then return v, src, raws end
        else
            raws[#raws + 1] = "global=skipped(not selected)"
        end
    end
    -- 3
    if gFn and C and type(C.SetSelectedQuest) == "function" and not scanNoSelect and not LogWindowOpen() then
        local prev = type(C.GetSelectedQuest) == "function" and Num(Call(C.GetSelectedQuest)) or nil
        ignoreLogUntil = Now() + 0.5
        pcall(C.SetSelectedQuest, questID)
        local v, src = try("select+global", gFn)
        if not v then v, src = try("select+global(id)", gFn, questID) end
        if prev and prev > 0 then ignoreLogUntil = Now() + 0.5; pcall(C.SetSelectedQuest, prev) end
        if v then return v, src, raws end
    end
    -- 4
    if index and gFn and type(_G.SelectQuestLogEntry) == "function" and type(_G.GetQuestLogSelection) == "function"
        and not scanNoSelect and not LogWindowOpen() then
        local prev = Num(Call(_G.GetQuestLogSelection))
        ignoreLogUntil = Now() + 0.5
        pcall(_G.SelectQuestLogEntry, index)
        local v, src = try("legacy-select", gFn)
        if prev then pcall(_G.SelectQuestLogEntry, prev) end
        if v then return v, src, raws end
    end
    -- nothing: ask the client to load the quest data, at most once in a while per quest
    if C and type(C.RequestLoadQuestByID) == "function" then
        local t = Now()
        if not loadAsked[questID] or t - loadAsked[questID] >= LOAD_RETRY then
            loadAsked[questID] = t
            pcall(C.RequestLoadQuestByID, questID)
            raws[#raws + 1] = "requested-load"
        end
    end
    return 0, nil, raws
end

local function ScanReady()
    local count, xp = 0, 0
    local list, seen = {}, {}
    local C = _G.C_QuestLog
    local n
    if C and type(C.GetNumQuestLogEntries) == "function" then n = Num(Call(C.GetNumQuestLogEntries)) end
    if not n then n = Num(Call(_G.GetNumQuestLogEntries)) end
    for i = 1, n or 0 do
        local qid, header, complete, title
        if C and type(C.GetInfo) == "function" then
            local info = Call(C.GetInfo, i)
            if type(info) == "table" and not Secret(info) then
                header, qid = info.isHeader, Num(info.questID)
                if type(info.title) == "string" then title = info.title end
            end
        end
        if qid == nil and header == nil and type(_G.GetQuestLogTitle) == "function" then
            -- legacy: title, level, tag, isHeader, isCollapsed, isComplete, frequency, questID
            local t, _, _, h, _, c, _, id = Call(_G.GetQuestLogTitle, i)
            header, qid = h, Num(id)
            if type(t) == "string" then title = t end
            if c == 1 then complete = true end
        end
        if not header and qid and qid > 0 then
            if C and type(C.ReadyForTurnIn) == "function" and Call(C.ReadyForTurnIn, qid) == true then
                complete = true
            elseif C and type(C.IsComplete) == "function" and Call(C.IsComplete, qid) == true then
                complete = true
            end
            seen[qid] = true
            if complete then
                count = count + 1
                local v, src, raws = ReadyQuestXP(qid, i)
                xp = xp + (v or 0)
                list[#list + 1] = { id = qid, title = title or "?", xp = v or 0, src = src, raws = raws }
            end
        end
    end
    for id in pairs(xpCache) do if not seen[id] then xpCache[id] = nil end end
    ready.count, ready.xp, ready.list = count, xp, list
end

-- Trailing-edge throttle: a scan asked for during the throttle or the own-selection ignore window is
-- never dropped, one scan is scheduled for when the window ends.
local function After(delay, fn)
    if _G.C_Timer and type(_G.C_Timer.After) == "function" then pcall(_G.C_Timer.After, delay, fn) end
end

local MaybeScanReady, RefreshPanel, RefreshBarText
local function ScheduleScan(delay)
    local t = Now()
    local due = t + delay
    if scanTimerDue and scanTimerDue >= t and scanTimerDue <= due + 0.01 then return end   -- earlier one pending
    scanTimerDue = due
    After(delay, function()
        if scanTimerDue == due then scanTimerDue = nil end
        Safe("quest scan timer", function() MaybeScanReady() end)
    end)
end

MaybeScanReady = function()
    if not readyDirty or not Enabled("questReady") then return end
    local t = Now()
    if t < ignoreLogUntil then ScheduleScan(ignoreLogUntil - t + 0.05); return end
    if t - lastScan < SCAN_INTERVAL then ScheduleScan(SCAN_INTERVAL - (t - lastScan) + 0.02); return end
    readyDirty, lastScan = false, t
    Safe("quest scan", ScanReady)
    scanNoSelect = false
    Safe("quest bar", RefreshQuestBar)
    Safe("refresh", function() RefreshPanel(); RefreshBarText() end)
end

-- Own selection changes fire QUEST_LOG_UPDATE too. Those must not be dropped (a real completion can land
-- in the same window), but the scan they cause must not select quests again (no loop).
local function MarkReadyDirty()
    readyDirty = true
    if Now() < ignoreLogUntil then scanNoSelect = true end
    MaybeScanReady()
end

-- Any quest-related event: scan now (throttled, trailing) and once more ~1 s later (debounced), because
-- the completion API can still return the old state at the moment of the event.
local function QuestEvent()
    MarkReadyDirty()
    local due = Now() + 1
    followDue = due
    After(1, function()
        if followDue ~= due then return end   -- a later event re-armed it
        followDue = nil
        readyDirty = true
        Safe("quest followup", function() MaybeScanReady() end)
    end)
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

local function BarText()
    local cur, max, rested = XPValues()
    if not cur then return nil end
    local s = Commas(cur) .. "/" .. Commas(max) .. string.format(" (%.1f%%)", cur / max * 100)
    if ready.xp > 0 and Enabled("questReady") then s = s .. " (+" .. Commas(ready.xp) .. ")" end
    if rested and rested > 0 then
        s = s .. DOT .. "rested " .. Commas(rested) .. string.format(" (%.0f%%)", rested / max * 100)
    end
    return s
end

local function Rate()
    local el = Now() - session.start
    if el < MIN_RATE_SECONDS or session.gained <= 0 then return nil end
    return session.gained / el * 3600
end

local function PanelText()
    if AtMax() then return "Max level" end
    local cur, max, rested = XPValues()
    if not cur then return "XP: no data" end
    local qx = Enabled("questReady") and ready.count > 0 and ready.xp or 0
    local rate = Rate()
    local killAvg = session.kills > 0 and session.killXP > 0 and session.killXP / session.kills or nil
    local calc = Calc(cur, max, qx, rate, killAvg)
    local remaining = calc.remaining
    local lines = { string.format("XP: %s/%s (%.1f%%)", Commas(cur), Commas(max), cur / max * 100) }
    lines[#lines + 1] = (rested and rested > 0)
        and string.format("Rested: %s (%.0f%% of level)", Commas(rested), rested / max * 100)
        or "Rested: 0"
    lines[#lines + 1] = "XP/hour: " .. (rate and Commas(rate) or "--")
    if Enabled("questReady") and ready.count > 0 then
        lines[#lines + 1] = "Quests ready: " .. ready.count .. " (+" .. Commas(ready.xp) .. " XP)"
        if calc.levelUp then
            lines[#lines + 1] = "Turn in to level up!"
        elseif ready.xp > 0 then
            lines[#lines + 1] = string.format("After turn-in: %s/%s (%.1f%%)",
                Commas(calc.after), Commas(max), calc.after / max * 100)
        end
    end
    lines[#lines + 1] = "To level: " .. (calc.levelUp and "turn in quests" or (calc.secs and Duration(calc.secs) or "--"))
    local parts = {}
    if session.kills > 0 and session.killXP > 0 then
        parts[#parts + 1] = "~" .. math.ceil(remaining / (session.killXP / session.kills)) .. " kills"
    end
    if session.quests > 0 and session.questXP > 0 then
        parts[#parts + 1] = "~" .. math.ceil(remaining / (session.questXP / session.quests)) .. " quests"
    end
    lines[#lines + 1] = #parts > 0 and table.concat(parts, DOT) or "~ kills/quests: no data yet"
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

local panel, panelText
local function SavePos()
    if not panel or not db then return end
    local p, _, rp, x, y = panel:GetPoint(1)
    if p and Num(x) and Num(y) then db.pos = { p = p, rp = rp, x = x, y = y } end
end

local function PlacePanel()
    panel:ClearAllPoints()
    local pos = db.pos
    if type(pos) == "table" and type(pos.p) == "string" and Num(pos.x) and Num(pos.y) then
        panel:SetPoint(pos.p, UIParent, type(pos.rp) == "string" and pos.rp or pos.p, pos.x, pos.y)
    else
        panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -200)
    end
end

local function CreatePanel()
    if panel then return end
    panel = CreateFrame("Frame", "GaarXPForeverPanel", UIParent)
    panel:SetFrameStrata("MEDIUM")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)
    panelText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panelText:SetPoint("TOPLEFT", 6, -5)
    panelText:SetJustifyH("LEFT")
    panel:SetScript("OnDragStart", function(self)
        Safe("drag", function()
            if db and (not db.locked or (type(_G.IsAltKeyDown) == "function" and _G.IsAltKeyDown())) then
                self:StartMoving()
            end
        end)
    end)
    panel:SetScript("OnDragStop", function(self)
        Safe("dragstop", function() self:StopMovingOrSizing(); SavePos() end)
    end)
    PlacePanel()
end

RefreshPanel = function()
    if not db then return end
    if not Enabled("panel") then
        if panel then panel:Hide() end
        return
    end
    CreatePanel()
    panelText:SetText(PanelText())
    panel:SetSize(math.max(60, (panelText:GetStringWidth() or 0) + 12),
        math.max(20, (panelText:GetStringHeight() or 0) + 10))
    panel:Show()
end

-- ---------------------------------------------------------------------------
-- XP bar text
-- ---------------------------------------------------------------------------

local overlay, overlayText, barFrame
local function FindBar()
    local b = _G.MainMenuExpBar or _G.MainStatusTrackingBarContainer or _G.StatusTrackingBarManager
    if b and type(b.IsShown) == "function" then return b end
end

RefreshBarText = function()
    if not db then return end
    local want = Enabled("xpbarText") and not AtMax()
    if not want then
        if overlay then overlay:Hide() end
        return
    end
    barFrame = barFrame or FindBar()
    if not barFrame then if overlay then overlay:Hide() end return end
    if not overlay then
        overlay = CreateFrame("Frame", "GaarXPForeverBarText", UIParent)
        overlay:SetFrameStrata("HIGH")
        overlay:EnableMouse(false)
        overlayText = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        overlayText:SetPoint("CENTER")
        overlay:SetPoint("CENTER", barFrame, "CENTER", 0, 0)
        overlay:SetSize(10, 10)
    end
    local hover = false
    if type(barFrame.IsMouseOver) == "function" then
        local ok, r = pcall(barFrame.IsMouseOver, barFrame)
        hover = ok and r == true
    end
    local txt = BarText()
    if barFrame:IsShown() and txt and (db.xpbarAlways or hover) then
        overlayText:SetText(txt)
        overlay:Show()
    else
        overlay:Hide()
    end
end

-- ---------------------------------------------------------------------------
-- Quest XP segment on the XP bar
-- ---------------------------------------------------------------------------

-- The StatusBar that is the XP bar. Old UI: MainMenuExpBar itself. Newer UI: a bar in the container's
-- .bars (each with .StatusBar); the one whose max matches UnitXPMax, else the first shown one.
local function FindStatusBar(container)
    if not container then return nil end
    if type(container.GetMinMaxValues) == "function" and type(container.SetStatusBarColor) == "function" then
        return container
    end
    local _, xpMax = XPValues()
    local first
    local bars = container.bars
    if type(bars) == "table" and not Secret(bars) then
        for i = 1, #bars do
            local b = bars[i]
            local sb = type(b) == "table" and (b.StatusBar or b) or nil
            if sb and type(sb.GetMinMaxValues) == "function" and type(sb.CreateTexture) == "function" then
                local ok, _, mx = pcall(sb.GetMinMaxValues, sb)
                if ok and xpMax and Num(mx) == xpMax then return sb end
                local shown = type(sb.IsShown) == "function" and sb:IsShown()
                if not first and shown then first = sb end
            end
        end
    end
    return first or (type(container.StatusBar) == "table" and container.StatusBar) or nil
end

local segFrame, segTex, segBar
local restTex, tickFrame, tickTex
local restedState = "off"            -- off | on | blizzard-hidden | not-found (for /gxp status)

-- Blizzard's rested visuals: the overlay (bar or texture) and the tick. Retail-engine bars carry
-- ExhaustionLevelFillBar / ExhaustionTick (on the StatusBar, its parent or the bar entry), classic
-- ones ExhaustionLevelBar / ExhaustionTick (+ ExhaustionTickNormal/Highlight, ExhaustionLevelBarTexture).
local restedRegions = { over = {}, tick = {} }
local restedHooked = {}
local function Field(o, k)
    if type(o) ~= "table" or Secret(o) then return nil end
    local ok, v = pcall(function() return o[k] end)
    if ok and type(v) == "table" and not Secret(v) and type(v.SetAlpha) == "function" then return v end
end
local function AddUnique(list, v) for _, x in ipairs(list) do if x == v then return end end list[#list + 1] = v end

local function FindRestedVisuals(sb, container)
    local over, tick = {}, {}
    local owners = {}
    local function own(o) if type(o) == "table" then AddUnique(owners, o) end end
    own(sb); own(container)
    if sb and type(sb.GetParent) == "function" then local ok, par = pcall(sb.GetParent, sb); if ok then own(par) end end
    local bars = type(container) == "table" and container.bars
    if type(bars) == "table" and not Secret(bars) then
        for i = 1, #bars do own(bars[i]) end
    end
    for _, o in ipairs(owners) do
        for _, k in ipairs({ "ExhaustionLevelFillBar", "ExhaustionLevelBar", "RestedBar", "ExhaustionBar" }) do
            local v = Field(o, k); if v then AddUnique(over, v) end
        end
        for _, k in ipairs({ "ExhaustionTick", "RestedTick" }) do
            local v = Field(o, k); if v then AddUnique(tick, v) end
        end
    end
    for _, n in ipairs({ "ExhaustionLevelBar", "ExhaustionLevelFillBar" }) do
        local v = Field(_G, n); if v then AddUnique(over, v) end
    end
    local v = Field(_G, "ExhaustionTick"); if v then AddUnique(tick, v) end
    return over, tick, owners
end

-- Blizzard's rested colour from the (about to be hidden) overlay, else classic rested blue.
local function RestedColor()
    for _, r in ipairs(restedRegions.over) do
        for _, m in ipairs({ "GetStatusBarColor", "GetVertexColor" }) do
            if type(r[m]) == "function" then
                local ok, a, b, c = pcall(r[m], r)
                if ok and Num(a) and Num(b) and Num(c) and not (a == 1 and b == 1 and c == 1) then return a, b, c end
            end
        end
    end
    return 0.0, 0.39, 0.88
end

local function SetRestedAlpha(a)
    for _, list in ipairs({ restedRegions.over, restedRegions.tick }) do
        for _, r in ipairs(list) do pcall(r.SetAlpha, r, a) end
    end
end

local function TickTexture()
    for _, r in ipairs(restedRegions.tick) do
        local cands = { r, Field(r, "Normal"), Field(r, "ExhaustionTickNormal"), Field(r, "Highlight") }
        if type(r.GetRegions) == "function" then
            local ok, a, b, c, d = pcall(r.GetRegions, r)
            if ok then cands[#cands + 1] = a; cands[#cands + 1] = b; cands[#cands + 1] = c; cands[#cands + 1] = d end
        end
        for _, t in pairs(cands) do
            if type(t) == "table" and type(t.GetTexture) == "function" then
                local ok, tex = pcall(t.GetTexture, t)
                if ok and (type(tex) == "string" or type(tex) == "number") and not Secret(tex) then return tex end
            end
        end
    end
end

local function HideSegment()
    if segFrame then segFrame:Hide() end
    if restTex then restTex:Hide() end
    if tickFrame then tickFrame:Hide() end
end

-- Give Blizzard's regions their normal look back and hide ours.
local function RestoreRested()
    SetRestedAlpha(1)
    restedState = "off"
    HideSegment()
end

local function HookRested(owners)
    for _, o in ipairs(owners) do
        for _, m in ipairs({ "UpdateExhaustion", "UpdateExhaustionTick", "UpdateTick", "Update", "UpdateBar" }) do
            local key = tostring(o) .. m
            if not restedHooked[key] and type(o[m]) == "function" and type(_G.hooksecurefunc) == "function" then
                restedHooked[key] = true
                pcall(_G.hooksecurefunc, o, m, function()
                    if restedState == "blizzard-hidden" or restedState == "on" then SetRestedAlpha(0) end
                end)
            end
        end
    end
end

RefreshQuestBar = function()
    if not db then return end
    if not (Enabled("questBar") and Enabled("questReady")) or AtMax() or ready.xp <= 0 then
        RestoreRested(); return
    end
    barFrame = barFrame or FindBar()
    local sb = FindStatusBar(barFrame)
    if not sb or type(sb.GetWidth) ~= "function" then RestoreRested(); return end
    if sb ~= segBar then
        RestoreRested()
        segBar = sb
        segFrame = CreateFrame("Frame", "GaarXPForeverQuestBar", sb)
        segFrame:EnableMouse(false)
        segTex = segFrame:CreateTexture(nil, "ARTWORK")
        segTex:SetAllPoints(segFrame)
        segTex:SetTexture("Interface\\Buttons\\WHITE8X8")
        restTex = segFrame:CreateTexture(nil, "ARTWORK")      -- positioned on segFrame's parent bar below
        restTex:SetTexture("Interface\\Buttons\\WHITE8X8")
        tickFrame = CreateFrame("Frame", "GaarXPForeverRestedTick", sb)
        tickFrame:EnableMouse(false)
        tickTex = tickFrame:CreateTexture(nil, "ARTWORK")
        tickTex:SetAllPoints(tickFrame)
        -- Follow the bar: size and visibility (our frames are its children, so Hide/Show propagate).
        if type(sb.HookScript) == "function" then
            pcall(sb.HookScript, sb, "OnSizeChanged", function() Safe("quest bar", RefreshQuestBar) end)
            pcall(sb.HookScript, sb, "OnShow", function() Safe("quest bar", RefreshQuestBar) end)
        end
    end
    local cur, max, rested = XPValues()
    local w = Num(sb:GetWidth())
    local h = type(sb.GetHeight) == "function" and Num(sb:GetHeight()) or nil
    local offset, width = SegmentGeometry(cur, max, ready.xp, w)
    if not offset or not h or h <= 0 or not sb:IsShown() then RestoreRested(); return end
    local lvl = (type(sb.GetFrameLevel) == "function" and Num(sb:GetFrameLevel()) or 0) + 1
    local c = BAR_COLORS[db.questBarColor] or BAR_COLORS.orange
    local covers = ready.xp >= max - cur   -- fills to the end: a little brighter
    segTex:SetColorTexture(c[1], c[2], c[3], covers and 0.75 or 0.5)
    segFrame:SetFrameLevel(lvl)
    segFrame:ClearAllPoints()
    segFrame:SetPoint("TOPLEFT", sb, "TOPLEFT", offset, 0)
    segFrame:SetSize(width, h)
    segFrame:Show()

    -- Rested after the quest segment.
    local roff, rwid, tickX = RestedGeometry(cur, ready.xp, rested, max, w)
    if not roff then
        SetRestedAlpha(1)           -- nothing rested to move: leave Blizzard's visuals as stock
        restedState = "off"
        if restTex then restTex:Hide() end
        if tickFrame then tickFrame:Hide() end
        return
    end
    local over, tick, owners = FindRestedVisuals(sb, barFrame)
    restedRegions.over, restedRegions.tick = over, tick
    local found = #over + #tick > 0
    local r, g, b = RestedColor()   -- read before hiding
    if found then
        SetRestedAlpha(0); HookRested(owners)
        restedState = "blizzard-hidden"
    else
        restedState = "not-found"
    end
    restTex:SetColorTexture(r, g, b, 0.6)
    restTex:ClearAllPoints()
    restTex:SetPoint("TOPLEFT", sb, "TOPLEFT", roff, 0)
    restTex:SetSize(rwid, h)
    restTex:Show()
    if tickX then
        local tex = TickTexture()
        if tex then tickTex:SetTexture(tex); tickTex:SetVertexColor(1, 1, 1, 1)
        else tickTex:SetColorTexture(1, 1, 1, 0.9) end
        tickFrame:SetFrameLevel(lvl)
        tickFrame:ClearAllPoints()
        tickFrame:SetPoint("CENTER", sb, "LEFT", tickX, 0)
        tickFrame:SetSize(tex and 16 or 2, h)
        tickFrame:Show()
    else
        tickFrame:Hide()
    end
end

-- ---------------------------------------------------------------------------
-- Level log
-- ---------------------------------------------------------------------------

local playedRequested, playedFrames = nil, {}

local function RestoreChat()
    for _, f in ipairs(playedFrames) do
        if f and type(f.RegisterEvent) == "function" then pcall(f.RegisterEvent, f, "TIME_PLAYED_MSG") end
    end
    playedFrames = {}
end

local function RequestPlayed()
    if type(_G.RequestTimePlayed) ~= "function" then return end
    playedRequested = true
    -- Hold back Blizzard's own print for this one request: unregister, restore after our line.
    playedFrames = {}
    for i = 1, (Num(_G.NUM_CHAT_WINDOWS) or 10) do
        local f = _G["ChatFrame" .. i]
        if f and type(f.IsEventRegistered) == "function" and f:IsEventRegistered("TIME_PLAYED_MSG") then
            f:UnregisterEvent("TIME_PLAYED_MSG")
            playedFrames[#playedFrames + 1] = f
        end
    end
    if _G.C_Timer and type(_G.C_Timer.After) == "function" then
        _G.C_Timer.After(5, function() playedRequested = nil; RestoreChat() end)
    end
    _G.RequestTimePlayed()
end

local function OnTimePlayed(total, thisLevel)
    if not playedRequested then return end
    playedRequested = nil
    local t, l = Num(total), Num(thisLevel)
    if Enabled("levelLog") and t and l then
        Print("level time " .. Duration(l) .. DOT .. "total played " .. Duration(t))
    end
    RestoreChat()
end

-- ---------------------------------------------------------------------------
-- Quest XP in tooltips
-- ---------------------------------------------------------------------------

local function QuestRewardXP(questID)
    questID = Num(questID)
    if not questID then return nil end
    local f = _G.C_QuestLog and _G.C_QuestLog.GetQuestLogRewardXP
    if type(f) == "function" then
        local ok, v = pcall(f, questID)
        if ok and Num(v) and v > 0 then return v end
    end
    if type(_G.GetQuestLogRewardXP) == "function" then
        local ok, v = pcall(_G.GetQuestLogRewardXP, questID)
        if ok and Num(v) and v > 0 then return v end
    end
end

local function AddQuestXP(tip, questID)
    if not Enabled("questXP") or not tip then return end
    local xp = QuestRewardXP(questID)
    if not xp or tip.bxpQuest == questID then return end
    tip.bxpQuest = questID
    tip:AddLine("XP reward: " .. Commas(xp), 0.6, 0.8, 1)
    tip:Show()
end

local function HookTooltips()
    local tip = _G.GameTooltip
    if tip and type(tip.HookScript) == "function" then
        tip:HookScript("OnHide", function(self) self.bxpQuest = nil end)
        tip:HookScript("OnTooltipCleared", function(self) self.bxpQuest = nil end)
    end
    if type(_G.QuestLogTitleButton_OnEnter) == "function" then
        hooksecurefunc("QuestLogTitleButton_OnEnter", function(self)
            Safe("questlog", function()
                local id = self.questID
                if not id and _G.C_QuestLog and type(_G.C_QuestLog.GetInfo) == "function" and self.questLogIndex then
                    local info = _G.C_QuestLog.GetInfo(self.questLogIndex)
                    id = type(info) == "table" and not Secret(info) and info.questID or nil
                end
                AddQuestXP(_G.GameTooltip, id)
            end)
        end)
    end
    if tip and type(tip.SetHyperlink) == "function" then
        hooksecurefunc(tip, "SetHyperlink", function(self, link)
            Safe("quest link", function()
                if type(link) == "string" and not Secret(link) then
                    local id = link:match("quest:(%d+)")
                    if id then AddQuestXP(self, tonumber(id)) end
                end
            end)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Setters, slash
-- ---------------------------------------------------------------------------

local function Refresh()
    Safe("refresh", function() RefreshPanel(); RefreshBarText(); RefreshQuestBar() end)
end

local function SetFlag(key, v)
    if not db then return end
    db[key] = v and true or false
    if key == "questReady" or key == "enabled" then readyDirty = true end
    Refresh()
end

local function OnOff(v)
    if v == "on" then return true elseif v == "off" then return false end
end

local function StatusLine()
    if not db then return "not loaded yet" end
    if not db.enabled then return "off" end
    if AtMax() then return "on" .. DOT .. "max level" end
    local cur, max = XPValues()
    local rate = Rate()
    return "on" .. (cur and string.format(DOT .. "%.1f%%", cur / max * 100) or "")
        .. (rate and (DOT .. Commas(rate) .. " xp/h") or "")
end

-- The intro GaarForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "XP at a glance: a movable panel with XP per hour, time to level and kills or quests to level, text on the XP bar, time played per level on level-up, quest XP in tooltips, and the XP of quests ready to turn in (taken off the XP left). Nice to know: Alt-drag moves the panel (or /gxp unlock); /gxp reset starts a new session."

local function PrintHelp()
    Print(INTRO)
    Print("/gxp  " .. VERSION)
    Print("/gxp on|off - everything on or off")
    Print("/gxp panel|xpbar|always|levellog|questxp|ready|readybar on|off - one part (no value shows its state)")
    Print("/gxp readybar color orange|green|yellow - colour of the ready-quest segment on the XP bar")
    Print("/gxp ready debug - per ready quest: id, XP and which source gave it")
    Print("/gxp unlock|lock|reset  panel drag without Alt; lock; reset the session (stats)")
    Print("/gxp resetpos - panel back to its default place; /gxp status")
end

local function PrintStatus()
    local function yn(b) return b and "on" or "off" end
    Print("version " .. VERSION .. DOT .. "enabled " .. yn(db.enabled))
    Print("panel " .. yn(db.panel) .. DOT .. "xpbarText " .. yn(db.xpbarText) .. DOT .. "xpbarAlways "
        .. yn(db.xpbarAlways) .. DOT .. "levelLog " .. yn(db.levelLog) .. DOT .. "questXP " .. yn(db.questXP)
        .. DOT .. "questReady " .. yn(db.questReady) .. DOT .. "questBar " .. yn(db.questBar)
        .. " (" .. (db.questBarColor or "orange") .. ")" .. DOT .. "ready quests " .. ready.count
        .. " (+" .. Commas(ready.xp) .. " xp)"
        .. DOT .. "panel " .. (db.locked and "locked (Alt-drag)" or "unlocked"))
    local bar = FindBar()
    Print("xp bar frame: " .. (bar and (bar:GetName() or "?") or "none found") .. DOT .. "max level " .. MaxLevel()
        .. (AtMax() and " (reached)" or ""))
    Print("session " .. Duration(Now() - session.start) .. DOT .. "gained " .. Commas(session.gained) .. " xp"
        .. DOT .. session.kills .. " kills" .. DOT .. session.quests .. " quests")
    Print("rested shift: " .. (restedState == "off" and "off (stock bar)" or restedState))
    Print("last error: " .. (lastError or "none"))
end

local function PrintReadyDebug()
    readyDirty = true; lastScan = -10
    Safe("quest scan", ScanReady)
    local lst = ready.list or {}
    Print("ready quests " .. ready.count .. " (+" .. Commas(ready.xp) .. " xp)" .. DOT
        .. "C_QuestLog " .. (_G.C_QuestLog and type(_G.C_QuestLog.GetQuestLogRewardXP) == "function" and "yes" or "no")
        .. DOT .. "global " .. (type(_G.GetQuestLogRewardXP) == "function" and "yes" or "no")
        .. DOT .. "SetSelectedQuest " .. (_G.C_QuestLog and type(_G.C_QuestLog.SetSelectedQuest) == "function" and "yes" or "no")
        .. DOT .. "log window " .. (LogWindowOpen() and "open" or "closed"))
    for _, q in ipairs(lst) do
        Print(q.title .. " [" .. q.id .. "] xp " .. q.xp .. " via " .. (q.src or "none")
            .. (q.src and "" or (" (" .. table.concat(q.raws or {}, ", ") .. ")")))
    end
end

local function OnSlash(msg)
    local ok, err = pcall(function()
        if not db then Print("not loaded yet"); return end
        local a, b = tostring(msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
        local v = OnOff(b)
        if a == "ready" and b == "debug" then PrintReadyDebug(); return end
        if a == "readybar" and b == "color" then
            local col = tostring(msg):lower():match("^%s*%S+%s+%S+%s+(%S+)")
            if col and BAR_COLORS[col] then
                db.questBarColor = col; Refresh(); Print("ready bar colour " .. col)
            else Print("ready bar colour: " .. (db.questBarColor or "orange") .. " (/gxp readybar color orange|green|yellow)") end
            return
        end
        if a == "" or a == "help" then PrintHelp()
        elseif a == "on" or a == "off" then SetFlag("enabled", a == "on"); Print("master " .. a)
        elseif a == "status" then PrintStatus()
        elseif a == "reset" then ResetSession(); Refresh(); Print("session reset")
        elseif a == "unlock" or a == "lock" then
            db.locked = (a == "lock")
            Print(a == "lock" and "panel locked (Alt-drag to move)" or "panel unlocked: drag it")
        elseif a == "resetpos" then
            db.pos = nil
            if panel then PlacePanel() end
            Print("panel position reset")
        elseif FEATURES[a] then
            local key = FEATURES[a]
            if v == nil then Print(LABELS[key] .. ": " .. (db[key] and "on" or "off") .. " (/gxp " .. a .. " on|off)")
            else SetFlag(key, v); Print(LABELS[key] .. " " .. b) end
        else PrintHelp() end
    end)
    if not ok then Fail("slash", err); Print("error: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Public API: GaarXPForeverAPI (for GaarForever's hub)
--   version, StatusLine(), MenuEntries(), AddMenuEntries(root), SetMinimapHidden(b)
-- ---------------------------------------------------------------------------

local function MenuEntries()
    if not db then return {} end
    local function toggle(key, text)
        return { text = text, checkbox = true,
            checked = function() return db[key] and true or false end,
            func = function() SetFlag(key, not db[key]) end }
    end
    return {
        { text = "XP tools on", checkbox = true,
          checked = function() return db.enabled and true or false end,
          func = function() SetFlag("enabled", not db.enabled) end },
        toggle("panel", LABELS.panel),
        toggle("xpbarText", LABELS.xpbarText),
        toggle("xpbarAlways", LABELS.xpbarAlways),
        toggle("levelLog", LABELS.levelLog),
        toggle("questXP", LABELS.questXP),
        toggle("questReady", LABELS.questReady),
        toggle("questBar", LABELS.questBar),
        { text = "Ready bar colour: " .. (db.questBarColor or "orange") .. " (click to change)",
          func = function()
              local order = { "orange", "green", "yellow" }
              for i, n in ipairs(order) do
                  if n == (db.questBarColor or "orange") then db.questBarColor = order[i % #order + 1]; break end
              end
              Refresh()
          end },
        { text = "Panel unlocked (drag)", checkbox = true,
          checked = function() return not db.locked end,
          func = function() db.locked = not db.locked end },
        { text = "Reset session", func = function() ResetSession(); Refresh() end },
    }
end


_G.GaarXPForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries(), A.title) end,
    SetMinimapHidden = function() end,
}
_G.BetterXPForeverAPI = _G.GaarXPForeverAPI -- the name before the folder rename

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    BF.Migrate("GaarXPForeverDB", "BetterXPForeverDB") -- the old folder's settings, once (see Lib.lua)
    if type(GaarXPForeverDB) ~= "table" then GaarXPForeverDB = {} end
    db = GaarXPForeverDB
    for k in pairs(db) do
        if DEFAULTS[k] == nil and k ~= "pos" and k ~= "questBarColor" then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if type(db[k]) ~= "boolean" then db[k] = v end
    end
    if type(db.pos) ~= "table" then db.pos = nil end
    if not BAR_COLORS[db.questBarColor] then db.questBarColor = "orange" end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_XP_UPDATE")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("UPDATE_EXHAUSTION")
events:RegisterEvent("TIME_PLAYED_MSG")
events:RegisterEvent("QUEST_TURNED_IN")
events:RegisterEvent("QUEST_LOG_UPDATE")
events:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
for _, e in ipairs({ "QUEST_DATA_LOAD_RESULT", "UNIT_QUEST_LOG_CHANGED", "QUEST_WATCH_UPDATE",
    "QUEST_LOG_CRITERIA_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "UI_INFO_MESSAGE" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    Safe(event, function()
        if event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then BindSavedVariables() end
        elseif event == "PLAYER_LOGIN" then
            ResetSession()
            readyDirty = true
            HookTooltips()
            Refresh()
        elseif event == "PLAYER_ENTERING_WORLD" or event == "UPDATE_EXHAUSTION" then
            Refresh()
        elseif event == "PLAYER_XP_UPDATE" then
            OnXPUpdate(); Refresh()
        elseif event == "PLAYER_LEVEL_UP" then
            if Enabled("levelLog") then RequestPlayed() end
            Refresh()
        elseif event == "TIME_PLAYED_MSG" then
            OnTimePlayed(arg1, arg2)
        elseif event == "QUEST_TURNED_IN" then
            flagQuest = true
            xpCache = {}
            QuestEvent()
        elseif event == "QUEST_DATA_LOAD_RESULT" then
            local id = Num(arg1)
            if id then loadAsked[id] = nil end
            QuestEvent()
        elseif event == "UNIT_QUEST_LOG_CHANGED" then
            if arg1 == "player" then QuestEvent() end
        elseif event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" then
            local id = Num(arg2) or Num(arg1)
            if id then loadAsked[id] = nil end
            QuestEvent()
        elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_WATCH_UPDATE" or event == "QUEST_LOG_CRITERIA_UPDATE"
            or event == "UI_INFO_MESSAGE" then
            QuestEvent()
        elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
            flagKill = true
        end
    end)
end)

-- Refreshes the bar text (hover) and the panel (rate, time to level) a few times a second.
local acc = 0
events:SetScript("OnUpdate", function(_, dt)
    acc = acc + (Num(dt) or 0)
    if acc < 0.25 then return end
    acc = 0
    if db then MaybeScanReady(); Refresh() end
end)

SLASH_GAARXPFOREVER1 = "/gxp"
SLASH_GAARXPFOREVER2 = "/gaarxpforever"
SLASH_GAARXPFOREVER3 = "/bxp" -- the command before the Gaar rename
SLASH_GAARXPFOREVER4 = "/betterxpforever"
SlashCmdList.GAARXPFOREVER = OnSlash
