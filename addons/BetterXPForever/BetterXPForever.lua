--[[
  BetterXPForever - XP at a glance, on WoW Forever (classic-era content, level cap 60).

  Every part is its own switch (saved setting + /bxp <feature> on|off + a hub menu entry):

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
    * /bxp reset        resets the session's numbers.

  How XP is counted. PLAYER_XP_UPDATE gives the change (UnitXP delta; across a level-up the rest of
  the old level plus the new XP). The change is classified a short moment later: a
  CHAT_MSG_COMBAT_XP_GAIN since the last one = a kill, a QUEST_TURNED_IN = a quest, anything else
  (exploring, gathering) counts only toward the XP/hour. Chat text is never parsed.

  Taint: Blizzard code is only followed, never replaced. The only hooks are hooksecurefunc on tooltip
  helpers and a HookScript on GameTooltip; the XP bar is only polled (IsMouseOver). Every client API is checked
  with type(...) == "function", every handler runs in pcall (the last error is kept for
  /bxp status), and a secret value is never compared or tested: it is treated as no value.
]]

local _G = _G
local ADDON_NAME = ...
ADDON_NAME = ADDON_NAME or "BetterXPForever"
local PREFIX = "|cff33ff99BetterXPForever|r: "
local DOT = " \194\183 "
local VERSION = "1.0"

local DEFAULT_MAX_LEVEL = 60
local MIN_RATE_SECONDS = 60   -- no XP/hour before a minute of session

local DEFAULTS = {
    enabled = true, panel = true, xpbarText = true, xpbarAlways = false,
    levelLog = true, questXP = false, locked = true,
}
local FEATURES = {            -- /bxp <name> on|off  (lower-case aliases map to the saved key)
    panel = "panel", xpbartext = "xpbarText", xpbar = "xpbarText", always = "xpbarAlways",
    xpbaralways = "xpbarAlways", levellog = "levelLog", level = "levelLog", questxp = "questXP",
    quest = "questXP",
}
local LABELS = {
    panel = "XP panel", xpbarText = "Text on the XP bar", xpbarAlways = "XP bar text always visible",
    levelLog = "Time played on level-up", questXP = "Quest XP in tooltips",
}

local db
local lastError

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end

local issecretvalue = _G.issecretvalue
local function Secret(v) return issecretvalue and issecretvalue(v) and true or false end
local function Num(v)
    if Secret(v) or type(v) ~= "number" or v ~= v then return nil end
    return v
end
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
-- Text
-- ---------------------------------------------------------------------------

local function BarText()
    local cur, max, rested = XPValues()
    if not cur then return nil end
    local s = Commas(cur) .. "/" .. Commas(max) .. string.format(" (%.1f%%)", cur / max * 100)
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
    local remaining = max - cur
    local lines = { string.format("XP: %s/%s (%.1f%%)", Commas(cur), Commas(max), cur / max * 100) }
    lines[#lines + 1] = (rested and rested > 0)
        and string.format("Rested: %s (%.0f%% of level)", Commas(rested), rested / max * 100)
        or "Rested: 0"
    local rate = Rate()
    lines[#lines + 1] = "XP/hour: " .. (rate and Commas(rate) or "--")
    lines[#lines + 1] = "To level: " .. (rate and Duration(remaining / rate * 3600) or "--")
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
    panel = CreateFrame("Frame", "BetterXPForeverPanel", UIParent)
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

local function RefreshPanel()
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

local function RefreshBarText()
    if not db then return end
    local want = Enabled("xpbarText") and not AtMax()
    if not want then
        if overlay then overlay:Hide() end
        return
    end
    barFrame = barFrame or FindBar()
    if not barFrame then if overlay then overlay:Hide() end return end
    if not overlay then
        overlay = CreateFrame("Frame", "BetterXPForeverBarText", UIParent)
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
    Safe("refresh", function() RefreshPanel(); RefreshBarText() end)
end

local function SetFlag(key, v)
    if not db then return end
    db[key] = v and true or false
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

local function PrintHelp()
    Print("/bxp  " .. VERSION)
    Print("/bxp on|off - everything on or off")
    Print("/bxp panel|xpbar|always|levellog|questxp on|off - one part (no value shows its state)")
    Print("/bxp unlock|lock|reset  panel drag without Alt; lock; reset the session (stats)")
    Print("/bxp resetpos - panel back to its default place; /bxp status")
end

local function PrintStatus()
    local function yn(b) return b and "on" or "off" end
    Print("version " .. VERSION .. DOT .. "enabled " .. yn(db.enabled))
    Print("panel " .. yn(db.panel) .. DOT .. "xpbarText " .. yn(db.xpbarText) .. DOT .. "xpbarAlways "
        .. yn(db.xpbarAlways) .. DOT .. "levelLog " .. yn(db.levelLog) .. DOT .. "questXP " .. yn(db.questXP)
        .. DOT .. "panel " .. (db.locked and "locked (Alt-drag)" or "unlocked"))
    local bar = FindBar()
    Print("xp bar frame: " .. (bar and (bar:GetName() or "?") or "none found") .. DOT .. "max level " .. MaxLevel()
        .. (AtMax() and " (reached)" or ""))
    Print("session " .. Duration(Now() - session.start) .. DOT .. "gained " .. Commas(session.gained) .. " xp"
        .. DOT .. session.kills .. " kills" .. DOT .. session.quests .. " quests")
    Print("last error: " .. (lastError or "none"))
end

local function OnSlash(msg)
    local ok, err = pcall(function()
        if not db then Print("not loaded yet"); return end
        local a, b = tostring(msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
        local v = OnOff(b)
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
            if v == nil then Print(LABELS[key] .. ": " .. (db[key] and "on" or "off") .. " (/bxp " .. a .. " on|off)")
            else SetFlag(key, v); Print(LABELS[key] .. " " .. b) end
        else PrintHelp() end
    end)
    if not ok then Fail("slash", err); Print("error: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterXPForeverAPI (for BetterGaarForever's hub)
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
        { text = "Panel unlocked (drag)", checkbox = true,
          checked = function() return not db.locked end,
          func = function() db.locked = not db.locked end },
        { text = "Reset session", func = function() ResetSession(); Refresh() end },
    }
end

local function RenderMenu(root, entries)
    if type(root) ~= "table" then return end
    for _, e in ipairs(entries) do
        if e.divider then
            if type(root.CreateDivider) == "function" then root:CreateDivider() end
        elseif e.submenu then
            if type(root.CreateButton) == "function" then RenderMenu(root:CreateButton(e.text), e.submenu) end
        elseif e.radio and type(root.CreateRadio) == "function" then
            root:CreateRadio(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox and type(root.CreateCheckbox) == "function" then
            root:CreateCheckbox(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox or e.radio then
            local mark = e.radio and (e.checked() and "(o) " or "( ) ") or (e.checked() and "[x] " or "[ ] ")
            if type(root.CreateButton) == "function" then root:CreateButton(mark .. e.text, function() e.func() end) end
        elseif type(root.CreateButton) == "function" then
            root:CreateButton(e.text, function() e.func() end)
        end
    end
end

_G.BetterXPForeverAPI = {
    version = VERSION,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) RenderMenu(root, MenuEntries()) end,
    SetMinimapHidden = function() end,
}

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterXPForeverDB) ~= "table" then BetterXPForeverDB = {} end
    db = BetterXPForeverDB
    for k in pairs(db) do
        if DEFAULTS[k] == nil and k ~= "pos" then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if type(db[k]) ~= "boolean" then db[k] = v end
    end
    if type(db.pos) ~= "table" then db.pos = nil end
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
events:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    Safe(event, function()
        if event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then BindSavedVariables() end
        elseif event == "PLAYER_LOGIN" then
            ResetSession()
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
    if db then Refresh() end
end)

SLASH_BETTERXPFOREVER1 = "/bxp"
SLASH_BETTERXPFOREVER2 = "/betterxpforever"
SlashCmdList.BETTERXPFOREVER = OnSlash
