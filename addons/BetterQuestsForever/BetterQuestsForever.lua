--[[
  BetterQuestsForever - order and limit the Quests section of the native objective tracker on
  WoW Forever.

  Forever ships the retail objective tracker (Blizzard_ObjectiveTracker). Its Quests section,
  QuestObjectiveTracker, shows the tracked (watched) quests in an order the client decides. This
  addon changes two things about that section and nothing else:

    * Order: by quest level, lowest first, ties by title. Quests that are ready to turn in go to
      the bottom (default), to the top, or are sorted among the others by level.
    * Sort by distance (optional, /bqf sort distance): nearest first, from
      C_QuestLog.GetDistanceSqToQuest; quests without a distance go last. The order is worked
      out again every few seconds out of combat, with hysteresis so near-equal quests do not
      jump around, and applied through the same hook-time code as the level order.
    * Limit: only the first N quests of that order are shown (default 10). The rest stay tracked;
      they are only not drawn.

  Every tracked quest stays tracked, and the watch list is never touched: the addon does not call
  AddQuestWatch, RemoveQuestWatch or SortQuestWatches at all.

  How, and why it is taint-safe (the Quests section carries quest item buttons, and the click
  on one calls the protected UseQuestLogSpecialItem):

    * Everything happens after Blizzard's own layout, from hooksecurefunc hooks on the
      QuestObjectiveTracker instance's Update and UpdateHeight, and only out of combat.
    * Blizzard lays the quest blocks out as a chain (ObjectiveTrackerModuleMixin:AnchorBlock): the
      first block's TOP sits on the section's ContentsFrame TOP at fromHeaderOffsetY, every next
      block's TOP on the previous block's BOTTOM at fromBlockOffsetY. The addon reads that layout
      back with GetPoint (so the spacing is Blizzard's, measured, not assumed), sorts the blocks,
      and moves the TOP point of each of the first N blocks onto the one before it in the sorted
      order with the same offsets. Blocks past the N-th are hidden with Hide(), together with the
      frames Blizzard parks next to them (the block's addedRegions: item button, find-group
      button, progress and timer bars; they are parented to the section, not to the block). The
      section's frame gets exactly the height of the shown blocks, so the next section moves up.
    * The item and find-group buttons are anchored to their own block (AddRightEdgeFrame:
      TOPRIGHT on the block, or RIGHT on the block's previous right-edge frame), and progress and
      timer bars to the block's lines, so they follow their block when it moves. Nothing of
      theirs is re-anchored.
    * Only widget methods are used on Blizzard frames (GetPoint, SetPoint, Hide, Show, SetHeight),
      and only on frames that are not protected and not anchoring-restricted; otherwise that
      update is skipped and /bqf status says why. The addon never writes a field into a Blizzard
      table, never calls a Blizzard Lua function of the tracker and never sets an attribute, so
      the code path that sets up the quest item buttons (SetAttribute("questLogIndex", ...))
      always runs untainted.
    * Combat: nothing is changed while InCombatLockdown() is true. On PLAYER_REGEN_DISABLED,
      which fires just before the lockdown starts, every block is put back where Blizzard put it
      and everything the addon hid is shown again, so for the whole fight the Quests section is
      exactly Blizzard's own. On PLAYER_REGEN_ENABLED the order and the limit are applied again.

  Hide in combat (default on): the whole objective tracker (ObjectiveTrackerFrame) and the
  backdrop are hidden for the length of a fight. The tracker is hidden and shown by Blizzard's
  secure state driver (RegisterStateDriver), never by this addon's own code; see "Hide in combat"
  below for why that is the only taint-safe way.

  Options: /bqf, and a minimap button whose menu has the same settings.

  Everything is feature-checked. If the tracker is not the structure this was written against,
  the addon does nothing and says so in /bqf status.
]]

local _G = _G
local ADDON_NAME = ... or "BetterQuestsForever"
local TITLE = "BetterQuestsForever"
local PREFIX = "|cff33ff99BetterQuestsForever|r: "

local MIN_MAX, MAX_MAX = 1, 50 -- MAX_MAX doubles as "All" in the menu
local COMPLETED_MODES = { top = true, level = true, bottom = true }
local SORT_MODES = { level = true, distance = true }
-- Distance mode: re-evaluate the order this often (seconds), and only reorder two quests when the
-- one behind is closer by at least this many yards AND this fraction of the other's distance.
local DISTANCE_TICK = 3
local HYST_YARDS, HYST_FRACTION = 50, 0.10

local DEFAULTS = {
    enabled = true,
    max = 10,
    completed = "bottom",
    sort = "level",
    hideInCombat = true,
}
local BACKDROP_DEFAULTS = { enabled = true, alpha = 0.5 }

-- Every key BetterQuestsForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = { enabled = true, max = true, completed = true, minimap = true, backdrop = true,
    hideInCombat = true, distanceProbe = true, sort = true }

-- How long events are collected before the layout is re-evaluated.
local THROTTLE = 0.3

local db                -- BetterQuestsForeverDB, bound at ADDON_LOADED (never at file scope)
local tracker           -- the QuestObjectiveTracker module once recognised
local trackerProblem    -- why the tracker was not recognised, for /bqf status
local hooked            -- our hooksecurefunc hooks are in place
local layoutProblem     -- why the last pass could not order/limit the section, for /bqf status
local pending           -- an evaluation is waiting (throttle or combat)
local heightSet         -- the section's frame has a height other than Blizzard's
local shownCount        -- quest blocks visible after the last pass
local orderedCount      -- quest blocks sorted in the last pass
local prevOrder         -- quest IDs in the order of the last distance-mode pass (for hysteresis)
local distanceTicker    -- the C_Timer ticker that re-evaluates the order in distance mode

-- Frames we changed, so they can be put back. Weak keys: a frame Blizzard drops is forgotten.
local hiddenBlocks = setmetatable({}, { __mode = "k" })
local hiddenRegions = setmetatable({}, { __mode = "k" }) -- region -> the block it belonged to
local moved = setmetatable({}, { __mode = "k" })         -- block -> Blizzard's TOP anchor for it

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

-- Calls a client function without letting an unexpected error escape.
local function Try(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function pcall1(fn, ...) -- first return value of fn, or nil if it errors or is missing
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
end

-- Geometry read off a frame can be a secret value on newer clients; a secret cannot be compared.
local function IsSecret(v)
    if type(_G.issecretvalue) ~= "function" then return false end
    return _G.issecretvalue(v) and true or false
end

local function QuestLog()
    local ql = _G.C_QuestLog
    if type(ql) == "table" then return ql end
end

-- The quest-log functions ordering needs (read-only). Returns the missing name, or nil.
local READ_API = { "GetNumQuestWatches", "GetQuestIDForQuestWatchIndex", "GetLogIndexForQuestID" }

local function MissingQuestApi()
    local ql = QuestLog()
    if not ql then return "C_QuestLog" end
    for _, name in ipairs(READ_API) do
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

local function IsAnchoringRestricted(f)
    if type(f) == "table" and type(f.IsAnchoringRestricted) == "function" then
        local ok, restricted = pcall(f.IsAnchoringRestricted, f)
        return ok and restricted and true or false
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Backdrop
--
-- A plain dark rectangle behind the objective tracker. It is this addon's own frame (parent
-- UIParent, strata BACKGROUND, no mouse), positioned by absolute coordinates computed from the
-- geometry Blizzard's frames report (GetLeft/GetRight/GetTop/GetBottom). Blizzard frames are only
-- read: nothing is anchored to our frame, nothing is written into a Blizzard table and no
-- tracker Lua is called. Because it only reads, it follows the tracker in combat too; with
-- "Hide in combat" on it is hidden for the fight together with the tracker.
-- ---------------------------------------------------------------------------

local BACKDROP_PAD = 4      -- px around the content
local BACKDROP_POLL = 0.1   -- seconds between measurements when no hook has fired
-- Tracker modules to measure when ObjectiveTrackerFrame.modules is not available.
local MODULE_NAMES = { "ScenarioObjectiveTracker", "UIWidgetObjectiveTracker", "CampaignQuestObjectiveTracker",
    "QuestObjectiveTracker", "AdventureObjectiveTracker", "AchievementObjectiveTracker",
    "MonthlyActivitiesObjectiveTracker", "ProfessionsRecipeTracker", "BonusObjectiveTracker",
    "WorldQuestObjectiveTracker", "InitiativeTasksObjectiveTracker" }

local backdropFrame, backdropTexture
local backdropDirty = true  -- a measurement is wanted on the next frame
local backdropState         -- "shown", "off", or why it is hidden; for /bqf status
local backdropKey           -- the geometry last applied
local backdropAlpha         -- the alpha last applied
local backdropHooked = {}   -- frame -> true once our hooks are on it
local combatHidden          -- the tracker is hidden for the current fight (see Hide in combat)

local function BackdropDB()
    local b = db.backdrop
    if type(b) ~= "table" then
        b = {}
        db.backdrop = b
    end
    if type(b.enabled) ~= "boolean" then b.enabled = BACKDROP_DEFAULTS.enabled end
    local a = tonumber(b.alpha)
    if not a or a ~= a then a = BACKDROP_DEFAULTS.alpha end
    b.alpha = math.min(1, math.max(0, a))
    for k in pairs(b) do
        if k ~= "enabled" and k ~= "alpha" then b[k] = nil end
    end
    return b
end

local function Num(v)
    if type(v) == "number" and not IsSecret(v) and v == v then return v end
end

local function Call(f, method)
    if type(f) == "table" and type(f[method]) == "function" then return pcall1(f[method], f) end
end

local function IsShownFrame(f)
    return type(f) == "table" and Call(f, "IsShown") == true
end

-- Multiplier from a frame's coordinates to UIParent's.
local function ScaleTo(f)
    local s, ps = Num(Call(f, "GetEffectiveScale")), Num(Call(_G.UIParent, "GetEffectiveScale"))
    if s and ps and s > 0 and ps > 0 then return s / ps end
    return 1
end

-- left, right, top, bottom of a frame in UIParent's coordinates; nil when not available.
local function Edges(f)
    local l, r = Num(Call(f, "GetLeft")), Num(Call(f, "GetRight"))
    local t, b = Num(Call(f, "GetTop")), Num(Call(f, "GetBottom"))
    if not (l and r and t and b) then return nil end
    local k = ScaleTo(f)
    return l * k, r * k, t * k, b * k
end

local function TrackerModules()
    local otf = _G.ObjectiveTrackerFrame
    if type(otf) == "table" and type(otf.modules) == "table" then return otf.modules end
    local list = {}
    for _, name in ipairs(MODULE_NAMES) do
        if type(_G[name]) == "table" then list[#list + 1] = _G[name] end
    end
    return list
end

-- The rectangle the objective tracker's visible content covers: left, right, top, bottom.
-- Returns nil and the reason when there is nothing to put a backdrop behind.
local function MeasureTracker()
    local otf = _G.ObjectiveTrackerFrame
    if type(otf) ~= "table" then return nil, "no ObjectiveTrackerFrame" end
    if not IsShownFrame(otf) then return nil, "tracker hidden" end
    if otf.isCollapsed == true or Call(otf, "IsCollapsed") == true then return nil, "tracker collapsed" end

    local left, right, top, bottom
    local function include(f, withVertical)
        local l, r, t, b = Edges(f)
        if not l then return false end
        left = left and math.min(left, l) or l
        right = right and math.max(right, r) or r
        if withVertical then
            top = top and math.max(top, t) or t
            bottom = bottom and math.min(bottom, b) or b
        end
        return true
    end

    -- From just above the "All Objectives" header.
    local headerTop
    if IsShownFrame(otf.Header) then
        local l, r, t = Edges(otf.Header)
        if l then
            headerTop = t
            include(otf.Header, false)
        end
    end

    local blocks = 0
    for _, module in ipairs(TrackerModules()) do
        if IsShownFrame(module) then
            local block, guard = module.firstBlock, 0
            while type(block) == "table" and guard < 1000 do
                if IsShownFrame(block) and include(block, true) then blocks = blocks + 1 end
                block = block.nextBlock
                guard = guard + 1
            end
            if IsShownFrame(module.Header) then include(module.Header, false) end
        end
    end
    if blocks == 0 then return nil, "no visible objectives" end
    if headerTop then top = headerTop end
    if not (left and right and top and bottom) then return nil, "geometry unavailable" end
    return left, right, top, bottom
end

local function HideBackdrop(reason)
    backdropState = reason
    backdropKey = nil
    if backdropFrame then backdropFrame:Hide() end
end

local function EnsureBackdropFrame()
    if backdropFrame then return backdropFrame end
    if type(_G.UIParent) ~= "table" then return nil end
    local f = CreateFrame("Frame", "BetterQuestsForeverBackdrop", _G.UIParent)
    f:SetFrameStrata("BACKGROUND")
    f:EnableMouse(false)
    local tex = f:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints(f)
    backdropFrame, backdropTexture = f, tex
    return f
end

local function ApplyBackdropNow()
    if not db then return end
    backdropDirty = false
    local cfg = BackdropDB()
    if not cfg.enabled then return HideBackdrop("off") end
    -- Also while Blizzard briefly re-shows the tracker mid-fight, before the driver hides it again.
    if combatHidden then return HideBackdrop("hidden in combat") end
    local left, right, top, bottom = MeasureTracker()
    if not left then return HideBackdrop(right) end -- the second value is the reason
    local f = EnsureBackdropFrame()
    if not f then return HideBackdrop("no UIParent") end

    local x, y = left - BACKDROP_PAD, top + BACKDROP_PAD
    local w, h = (right - left) + 2 * BACKDROP_PAD, (top - bottom) + 2 * BACKDROP_PAD
    local key = string.format("%.2f:%.2f:%.2f:%.2f", x, y, w, h)
    if key ~= backdropKey then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMLEFT", x, y)
        f:SetSize(w, h)
        backdropKey = key
    end
    if backdropAlpha ~= cfg.alpha then
        backdropTexture:SetColorTexture(0, 0, 0, cfg.alpha)
        backdropAlpha = cfg.alpha
    end
    f:Show()
    backdropState = "shown"
end

local function ApplyBackdrop()
    local ok, err = pcall(ApplyBackdropNow)
    if not ok then
        backdropState = "error: " .. tostring(err)
        pcall(HideBackdrop, backdropState)
    end
end

local function MarkBackdrop() backdropDirty = true end

-- Post-hooks on Blizzard's tracker: they only set our flag, the measuring happens on our frame.
local function HookBackdropFrame(f, methods, scripts)
    if type(f) ~= "table" or backdropHooked[f] or type(_G.hooksecurefunc) ~= "function" then return end
    backdropHooked[f] = true
    for _, name in ipairs(methods) do
        if type(f[name]) == "function" then pcall(hooksecurefunc, f, name, MarkBackdrop) end
    end
    if type(f.HookScript) == "function" then
        for _, name in ipairs(scripts) do pcall(f.HookScript, f, name, MarkBackdrop) end
    end
end

local function HookBackdropTargets()
    HookBackdropFrame(_G.ObjectiveTrackerFrame, { "Update", "UpdateHeight", "SetCollapsed" },
        { "OnShow", "OnHide", "OnSizeChanged" })
    for _, module in ipairs(TrackerModules()) do
        HookBackdropFrame(module, { "Update", "UpdateHeight" }, { "OnShow", "OnHide" })
    end
end

-- Our own frame measures on the next frame after a hook fired, and every BACKDROP_POLL seconds
-- otherwise, so a tracker that was dragged or rescaled is followed too.
local backdropDriver = CreateFrame("Frame")
local backdropWait = 0
backdropDriver:SetScript("OnUpdate", function(_, elapsed)
    backdropWait = backdropWait + (elapsed or 0)
    if backdropDirty or backdropWait >= BACKDROP_POLL then
        backdropWait = 0
        ApplyBackdrop()
    end
end)

-- ---------------------------------------------------------------------------
-- Hide in combat
--
-- The whole objective tracker is hidden while the player is in combat and shown again afterwards,
-- but only if it was shown when the fight started.
--
-- Why Blizzard's state driver, and why nothing else is safe:
--
--   * ObjectiveTrackerFrame is not a protected frame (no secure template; the quest item buttons
--     are plain Buttons whose Blizzard OnClick calls the protected UseQuestLogSpecialItem). So the
--     client allows it to be hidden in combat, but whoever hides or shows it runs its scripts:
--     OnHide (ManagedFrameMixin / EditModeSystemMixin:OnSystemHide) calls
--     RightManagedFrameContainer:RemoveManagedFrame, which writes the container's showingFrames,
--     calls ObjectiveTrackerFrame:UpdateHeight and lays out the right-hand container (it also holds
--     the boss and arena frames, which are protected); OnShow (ObjectiveTrackerContainerMixin)
--     calls AddManagedFrame (SetParent + Layout) and UpdateHeight, whose OnSizeChanged marks the
--     tracker dirty. Hide() or Show() called from addon code runs all of that tainted, so the
--     container's layout and the tracker update that sets the item buttons' questLogIndex
--     attribute would carry our taint. Hiding it from our own PLAYER_REGEN_DISABLED handler is
--     therefore not acceptable, and fading it (alpha) would leave the item buttons clickable.
--   * A SecureHandlerStateTemplate frame of our own with a frame ref to the tracker does not work
--     either: the restricted environment rejects a handle to a frame that is not protected while
--     InCombatLockdown() is true (RestrictedFrames.lua, GetPossiblyForbiddenHandleFrame:
--     "Invalid frame handle"), and the state driver only runs on the frame after the lockdown has
--     started.
--   * Blizzard's SecureStateDriverManager runs a "visibility" driver from its own secure code
--     (an attribute change and its OnUpdate), and Hide()/Show() from secure code are allowed on
--     this frame in combat. So OnHide/OnShow and everything they call run untainted.
--
-- The driver is on the tracker only from PLAYER_REGEN_DISABLED (which fires just before the
-- lockdown starts) until PLAYER_REGEN_ENABLED (just after it ends), with the plain value "hide":
-- out of combat Blizzard's own show/hide logic is never overridden. If Blizzard shows the tracker
-- during the fight (a quest update does), the driver hides it again within its 0.2 s throttle.
-- After the fight, if the tracker was shown when the fight started, the driver is set to "show"
-- once - Blizzard's code shows it - and then removed. The addon itself never calls Hide, Show or
-- SetAttribute on a Blizzard frame, never writes a Blizzard table and never calls tracker Lua.
-- The driver itself sets the tracker's "statehidden" attribute (true on hide, nil on show), which
-- nothing in the tracker reads.
-- ---------------------------------------------------------------------------

local combatWasShown        -- the tracker was shown when the current fight started
local combatProblem         -- why the tracker could not be hidden, for /bqf status

-- The tracker, or nil and why it cannot be hidden in combat on this client.
local function CombatHideTarget()
    local otf = _G.ObjectiveTrackerFrame
    if not IsFrame(otf) then return nil, "no ObjectiveTrackerFrame" end
    if type(_G.RegisterStateDriver) ~= "function" or type(_G.UnregisterStateDriver) ~= "function" then
        return nil, "RegisterStateDriver not available"
    end
    if Call(otf, "IsForbidden") == true then return nil, "the tracker is forbidden" end
    return otf
end

-- PLAYER_REGEN_DISABLED: the lockdown has not started yet.
local function StartCombatHide()
    combatProblem = nil
    if not db or not db.hideInCombat or combatHidden then return end
    if InCombat() then
        combatProblem = "the combat lockdown had already started"
        return
    end
    local otf, why = CombatHideTarget()
    if not otf then
        combatProblem = why
        return
    end
    combatWasShown = IsShownFrame(otf)
    local ok, err = pcall(_G.RegisterStateDriver, otf, "visibility", "hide")
    if not ok then
        combatProblem = "error: " .. tostring(err)
        pcall(_G.UnregisterStateDriver, otf, "visibility")
        combatWasShown = nil
        return
    end
    combatHidden = true
    ApplyBackdrop()
end

-- PLAYER_REGEN_ENABLED: the lockdown is over. Runs whatever the setting is now, so turning the
-- option off during a fight still brings the tracker back.
local function EndCombatHide()
    if not combatHidden or InCombat() then return end
    local otf = _G.ObjectiveTrackerFrame
    if combatWasShown then
        -- Replaces "hide"; the driver resolves it at once and shows the tracker from secure code.
        local ok, err = pcall(_G.RegisterStateDriver, otf, "visibility", "show")
        if not ok then combatProblem = "could not show the tracker again: " .. tostring(err) end
    end
    local ok, err = pcall(_G.UnregisterStateDriver, otf, "visibility")
    if not ok then combatProblem = "could not remove the combat driver: " .. tostring(err) end
    combatHidden, combatWasShown = false, nil
    MarkBackdrop()
end

-- ---------------------------------------------------------------------------
-- Quest data and the order
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

-- Level, title, completion, whether it is in the quest log, and whether the Quests section
-- shows it at all.
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
        inLog = index ~= nil,
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

local function SortMode()
    return db and db.sort == "distance" and "distance" or "level"
end

-- Distance to the quest in yards, or nil when the client has none (missing API, no distance,
-- not a number, negative). C_QuestLog.GetDistanceSqToQuest returns squared yards.
local function QuestDistance(questID)
    local ql = QuestLog()
    local fn = ql and ql.GetDistanceSqToQuest
    if type(fn) ~= "function" then return nil end
    local ok, sq = pcall(fn, questID)
    if not ok or IsSecret(sq) or type(sq) ~= "number" or sq ~= sq or sq < 0 or sq == math.huge then return nil end
    return math.sqrt(sq)
end

-- Distance mode, plain order: completed quests first or last unless the mode is "level" (then
-- "with the others"), nearest first, quests without a distance after those with one (by level,
-- then title, then quest ID).
local function DistanceCompare(a, b)
    local mode = db and db.completed or DEFAULTS.completed
    if a.complete ~= b.complete and mode ~= "level" then
        if mode == "top" then return a.complete end
        return b.complete
    end
    if a.dist and b.dist then
        if a.dist ~= b.dist then return a.dist < b.dist end
    elseif a.dist or b.dist then
        return a.dist ~= nil
    end
    if a.level ~= b.level then return a.level < b.level end
    if a.titleKey ~= b.titleKey then return a.titleKey < b.titleKey end
    if a.title ~= b.title then return a.title < b.title end
    return a.id < b.id
end

-- Should x go in front of y, which is directly ahead of it now? Like DistanceCompare, except two
-- quests with distances only swap when x is clearly closer: by HYST_YARDS and HYST_FRACTION of y's.
local function ClearlyBefore(x, y)
    if x.dist and y.dist then
        local mode = db and db.completed or DEFAULTS.completed
        if x.complete == y.complete or mode == "level" then
            local gap = y.dist - x.dist
            return gap >= HYST_YARDS and gap >= HYST_FRACTION * y.dist
        end
    end
    return DistanceCompare(x, y)
end

-- Sorts items (each with .id and .dist) in place by distance. With a previous order, quests
-- that were there keep their relative order unless the one behind is clearly closer (an
-- insertion pass seeded with that order); new quests take their plain sorted place.
local function SortByDistance(items, previous)
    if not previous then
        table.sort(items, DistanceCompare)
        return
    end
    local rank = {}
    for i, id in ipairs(previous) do rank[id] = i end
    local kept, fresh = {}, {}
    for _, d in ipairs(items) do
        if rank[d.id] then kept[#kept + 1] = d else fresh[#fresh + 1] = d end
    end
    table.sort(kept, function(a, b) return rank[a.id] < rank[b.id] end)
    table.sort(fresh, DistanceCompare)
    for _, d in ipairs(fresh) do
        local at = #kept + 1
        for i, k in ipairs(kept) do
            if DistanceCompare(d, k) then at = i; break end
        end
        table.insert(kept, at, d)
    end
    for i = 2, #kept do
        local j = i
        while j > 1 and ClearlyBefore(kept[j], kept[j - 1]) do
            kept[j], kept[j - 1] = kept[j - 1], kept[j]
            j = j - 1
        end
    end
    for i, d in ipairs(kept) do items[i] = d end
end

-- Orders items (quest data) for the current sort mode and remembers the distance order.
local function OrderQuests(items)
    if SortMode() == "distance" then
        for _, d in ipairs(items) do d.dist = QuestDistance(d.id) end
        SortByDistance(items, prevOrder)
        prevOrder = {}
        for i, d in ipairs(items) do prevOrder[i] = d.id end
    else
        table.sort(items, Compare)
    end
end

-- ---------------------------------------------------------------------------
-- The tracker
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

local function BlockHeight(block)
    if type(block.height) == "number" then return block.height end
    local h = pcall1(block.GetHeight, block)
    if type(h) == "number" and not IsSecret(h) then return h end
    return 0
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

-- The frame's TOP anchor as { rel, relPoint, x, y }, or nil when it cannot be read.
local function GetTop(frame)
    if type(frame) ~= "table" or type(frame.GetNumPoints) ~= "function" or type(frame.GetPoint) ~= "function" then
        return nil
    end
    local n = pcall1(frame.GetNumPoints, frame)
    if type(n) ~= "number" or IsSecret(n) then return nil end
    for i = 1, n do
        local ok, point, rel, relPoint, x, y = pcall(frame.GetPoint, frame, i)
        if ok and point == "TOP" then
            if IsSecret(x) or IsSecret(y) then return nil end
            return { rel = rel, relPoint = relPoint, x = tonumber(x) or 0, y = tonumber(y) or 0 }
        end
    end
end

local function SameAnchor(a, rel, relPoint, x, y)
    return a ~= nil and a.rel == rel and a.relPoint == relPoint and a.x == x and a.y == y
end

-- Blizzard's TOP anchor for every block of the chain, by position. A block whose current anchor
-- is Blizzard's (the first on something outside the chain, every other on its predecessor in the
-- chain) is read as it is. A block that still carries our anchor - no Blizzard layout since we
-- moved it - gets the anchor we recorded before moving it. Blizzard re-anchors every block on
-- each full layout, so a recorded anchor is never older than the current chain.
local function ReadBlizzardLayout(chain)
    local inChain = {}
    for k, b in ipairs(chain) do inChain[b] = k end
    local anchors = {}
    for k, b in ipairs(chain) do
        local top = GetTop(b)
        local blizzards
        if top then
            if k == 1 then
                blizzards = top.rel == nil or not inChain[top.rel]
            else
                blizzards = top.rel == chain[k - 1]
            end
        end
        if blizzards then
            anchors[k] = top
            moved[b] = nil
        elseif moved[b] then
            anchors[k] = moved[b]
        elseif k == 1 and type(tracker.fromHeaderOffsetY) == "number" and type(tracker.ContentsFrame) == "table" then
            anchors[k] = { rel = tracker.ContentsFrame, relPoint = "TOP", x = 0, y = tracker.fromHeaderOffsetY }
        elseif k > 1 and type(tracker.fromBlockOffsetY) == "number" then
            anchors[k] = { rel = chain[k - 1], relPoint = "BOTTOM", x = 0, y = tracker.fromBlockOffsetY }
        else
            return nil, "could not read where Blizzard placed quest block " .. k
        end
    end
    return anchors
end

local function SetTop(block, rel, relPoint, x, y)
    if not SameAnchor(GetTop(block), rel, relPoint, x, y) then
        block:SetPoint("TOP", rel, relPoint, x, y)
    end
end

-- Puts every block we moved back on Blizzard's anchor, in chain order so no anchor loop can form.
local function RestoreAnchors()
    local chain = BlockChain()
    local inChain = {}
    for _, b in ipairs(chain) do inChain[b] = true end
    for k, b in ipairs(chain) do
        local orig = moved[b]
        if orig then
            local top = GetTop(b)
            local blizzards = top and ((k == 1 and (top.rel == nil or not inChain[top.rel]))
                or (k > 1 and top.rel == chain[k - 1]))
            if not blizzards and not IsProtectedFrame(b) and not IsAnchoringRestricted(b) then
                local rel = k == 1 and orig.rel or chain[k - 1]
                pcall(SetTop, b, rel, orig.relPoint, orig.x, orig.y)
            end
        end
    end
    for b in pairs(moved) do moved[b] = nil end
end

local function SetSectionHeight(h)
    if not tracker:IsShown() then
        heightSet = false
        return
    end
    local full = FullHeight()
    if not full then return end
    if h and math.abs(h - full) > 0.001 then
        tracker:SetHeight(math.max(h, 1))
        heightSet = true
    elseif heightSet then
        tracker:SetHeight(full)
        heightSet = false
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

-- Hands the section back to Blizzard exactly as it laid it out.
local function RestoreAll()
    if not tracker then return end
    pcall(RestoreAnchors)
    Restore({})
    if heightSet then SetSectionHeight(nil) end
    shownCount, orderedCount = nil, nil
end

local function Skip(reason)
    layoutProblem = reason
    RestoreAll()
end

local function CanMove(f)
    return IsFrame(f) and type(f.SetPoint) == "function" and not IsProtectedFrame(f) and not IsAnchoringRestricted(f)
end

local function CanHide(f)
    return IsFrame(f) and not IsProtectedFrame(f)
end

-- Orders and limits the Quests section. Runs after Blizzard's layout, out of combat.
local function ApplyLayout()
    if not tracker or not db or InCombat() then return end
    if not db.enabled then
        layoutProblem = nil
        RestoreAll()
        return
    end
    local missing = MissingQuestApi()
    if missing then return Skip(missing .. " missing") end

    local chain = BlockChain()
    if #chain == 0 then
        layoutProblem = nil
        Restore({})
        if heightSet then SetSectionHeight(nil) end
        shownCount, orderedCount = 0, 0
        return
    end
    for _, b in ipairs(chain) do
        if not CanMove(b) then
            return Skip("a quest block is protected, anchoring-restricted or not a frame; left to Blizzard")
        end
    end
    if IsProtectedFrame(tracker) then return Skip("the Quests section is protected; left to Blizzard") end
    local anchors, err = ReadBlizzardLayout(chain)
    if not anchors then return Skip(err) end

    -- Quest blocks of watched quests are sorted; anything else (quest pop-ups, a block Blizzard
    -- keeps for a moment after a turn-in) stays on top in Blizzard's order and is never hidden.
    local watched = {}
    for _, questID in ipairs(GetWatches()) do watched[questID] = true end
    local fixed, sortable = {}, {}
    for _, b in ipairs(chain) do
        local d = IsQuestBlock(b) and watched[b.id] and QuestData(b.id)
        if d and d.inLog then
            d.block = b
            sortable[#sortable + 1] = d
        else
            fixed[#fixed + 1] = b
        end
    end
    OrderQuests(sortable)

    local visible, hide = {}, {}
    for _, b in ipairs(fixed) do visible[#visible + 1] = b end
    for i, d in ipairs(sortable) do
        if i <= db.max then visible[#visible + 1] = d.block else hide[d.block] = true end
    end
    for block in pairs(hide) do
        for region in pairs(Regions(block)) do
            if not CanHide(region) then
                return Skip("a quest item button or bar is protected or not a frame; left to Blizzard")
            end
        end
    end

    -- Hide first, then move: nothing shown is ever anchored to a hidden block.
    Restore(hide)
    for block in pairs(hide) do
        if block:IsShown() then block:Hide() end
        hiddenBlocks[block] = true
        for region in pairs(Regions(block)) do
            if region:IsShown() then region:Hide() end
            hiddenRegions[region] = block
        end
    end

    -- Top to bottom: slot k gets the offset Blizzard used at position k, on the block above it in
    -- our order. Each block is anchored to one already placed, so no anchor loop can form.
    local position = {}
    for k, b in ipairs(chain) do position[b] = k end
    for k, b in ipairs(visible) do
        local slot = anchors[k]
        local rel = k == 1 and slot.rel or visible[k - 1]
        local own = anchors[position[b]]
        if SameAnchor(own, rel, slot.relPoint, slot.x, slot.y) then
            moved[b] = nil
        else
            moved[b] = own
        end
        SetTop(b, rel, slot.relPoint, slot.x, slot.y)
    end

    -- Blizzard's height minus what it added for its blocks plus what our shown blocks take, with
    -- the same per-position offsets (ObjectiveTrackerModuleMixin:InternalAddBlock).
    local full = FullHeight()
    if full then
        local h = full
        for k, b in ipairs(chain) do h = h - (BlockHeight(b) - anchors[k].y) end
        for k, b in ipairs(visible) do h = h + (BlockHeight(b) - anchors[k].y) end
        SetSectionHeight(h)
    end

    layoutProblem = nil
    shownCount = math.min(#sortable, db.max)
    orderedCount = #sortable
end

local function OnTrackerLaidOut()
    MarkBackdrop()
    local ok, err = pcall(ApplyLayout)
    if not ok then
        layoutProblem = "error: " .. tostring(err)
        pcall(RestoreAll)
    end
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
-- Evaluation
-- ---------------------------------------------------------------------------

local function Evaluate()
    pending = false
    if not db then return end
    if InCombat() then
        pending = true
        return
    end
    pcall(HookBackdropTargets)
    if not HookTracker() then return end
    -- The hooks apply the layout after every Blizzard update; this pass covers a settings change
    -- or an event that needs no new Blizzard layout.
    OnTrackerLaidOut()
end

-- Distance mode: the quests' distances change as the player moves, so every DISTANCE_TICK
-- seconds the order is worked out again (with hysteresis); the layout is re-applied, through the
-- same OnTrackerLaidOut the hooks use, only when it would change. Never in combat, and nothing
-- is done while the tracker is hidden.
local function DistanceTick()
    if not db or not db.enabled or SortMode() ~= "distance" or InCombat() then return end
    if not tracker or not hooked then return end
    local otf = _G.ObjectiveTrackerFrame
    if IsFrame(otf) and not IsShownFrame(otf) then return end
    local items = {}
    for _, questID in ipairs(GetWatches()) do
        local d = QuestData(questID)
        if d.inLog and d.inQuestsSection then
            d.dist = QuestDistance(questID)
            items[#items + 1] = d
        end
    end
    SortByDistance(items, prevOrder)
    local same = prevOrder ~= nil and #prevOrder == #items
    if same then
        for i, d in ipairs(items) do
            if prevOrder[i] ~= d.id then same = false; break end
        end
    end
    if not same then OnTrackerLaidOut() end
end

-- One ticker, running only while the addon is on and sorts by distance.
local function UpdateDistanceTicker()
    local want = db and db.enabled and SortMode() == "distance"
        and type(_G.C_Timer) == "table" and type(_G.C_Timer.NewTicker) == "function"
    if want and not distanceTicker then
        distanceTicker = _G.C_Timer.NewTicker(DISTANCE_TICK, function() pcall(DistanceTick) end)
    elseif not want and distanceTicker then
        pcall(distanceTicker.Cancel, distanceTicker)
        distanceTicker = nil
    end
    if SortMode() ~= "distance" or not (db and db.enabled) then prevOrder = nil end
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

-- A settings change: applied at once out of combat, after combat otherwise.
local function ApplyNow()
    if not db then return end
    if InCombat() then
        pending = true
        return
    end
    Evaluate()
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function MaxLabel(n)
    return n >= MAX_MAX and "All" or tostring(n)
end

local function SetEnabled(on)
    db.enabled = on and true or false
    UpdateDistanceTicker()
    if on then
        layoutProblem = nil
        Print("on." .. (InCombat() and " Applied after combat." or ""))
        ApplyNow()
        return
    end
    -- Off: Blizzard's own tracker again. In combat it already is (see PLAYER_REGEN_DISABLED).
    if not InCombat() then RestoreAll() end
    Print("off - Blizzard's own tracker.")
end

local function SetMax(n)
    db.max = n
    Print("showing at most " .. MaxLabel(n) .. " quests." .. (InCombat() and " Applied after combat." or ""))
    ApplyNow()
end

local function SetCompleted(mode)
    db.completed = mode
    Print("quests ready to turn in: " .. mode .. "." .. (InCombat() and " Applied after combat." or ""))
    ApplyNow()
end

local function SetSort(mode)
    db.sort = mode
    prevOrder = nil
    UpdateDistanceTicker()
    Print("sort by " .. mode .. "." .. (InCombat() and " Applied after combat." or ""))
    ApplyNow()
end

local function SetHideInCombat(on)
    db.hideInCombat = on and true or false
    local note = ""
    if InCombat() then
        if on and not combatHidden then note = " Applies from the next fight." end
        if not on and combatHidden then note = " The tracker comes back when this fight ends." end
    end
    Print("hide in combat " .. (on and "on" or "off") .. "." .. note)
end

local function AlphaPercent()
    return math.floor(BackdropDB().alpha * 100 + 0.5)
end

local function SetBackdropEnabled(on)
    BackdropDB().enabled = on and true or false
    Print("backdrop " .. (on and "on" or "off") .. ".")
    ApplyBackdrop()
end

local function SetBackdropAlpha(pct)
    pct = math.min(100, math.max(0, math.floor(pct + 0.5)))
    BackdropDB().alpha = pct / 100
    Print("backdrop opacity " .. pct .. "%." .. (BackdropDB().enabled and "" or " (The backdrop is off: /bqf bg on.)"))
    ApplyBackdrop()
end

-- ---------------------------------------------------------------------------
-- Minimap button
--
-- The placement mirrors GaarVanguard's button, copied rather than shared: this addon has no
-- dependencies. Settings live in BetterQuestsForeverDB.minimap = { hide = <bool>, angle = <deg> }
-- and are read only after ADDON_LOADED.
-- ---------------------------------------------------------------------------

-- GaarOptions sits at 205 degrees and GaarVanguard at 245; 285 keeps clear of both.
local MINIMAP_DEFAULT_ANGLE = 285
local FLAT = "Interface\\Buttons\\WHITE8x8"
-- Built-in icons, best first; the first one the client resolves is used.
local MINIMAP_ICONS = {
    "Interface\\Icons\\INV_Scroll_03",
    "Interface\\Icons\\INV_Misc_Note_01",
    "Interface\\Icons\\INV_Misc_QuestionMark",
}
local MENU_MAX = { 3, 5, 8, 10, 12, 15, 20, 25, MAX_MAX }
local MENU_ALPHA = { 20, 35, 50, 65, 80 }
local MENU_COMPLETED = { { "top", "Top" }, { "level", "By level" }, { "bottom", "Bottom" } }
local MENU_SORT = { { "level", "Level" }, { "distance", "Distance" } }

local function MinimapDB()
    local m = db.minimap
    if type(m) ~= "table" then
        m = {}
        db.minimap = m
    end
    if type(m.hide) ~= "boolean" then m.hide = false end
    local a = tonumber(m.angle)
    if not a or a ~= a or a == math.huge or a == -math.huge then a = MINIMAP_DEFAULT_ANGLE end
    m.angle = a % 360
    for k in pairs(m) do
        if k ~= "hide" and k ~= "angle" then m[k] = nil end
    end
    return m
end

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function PickMinimapIcon()
    local getID = _G.GetFileIDFromPath
    if type(getID) ~= "function" then return MINIMAP_ICONS[1] end
    for _, path in ipairs(MINIMAP_ICONS) do
        if pcall1(getID, path) then return path end
    end
    return MINIMAP_ICONS[1]
end

local minimapButton

local function PlaceMinimapButton()
    local b, mm = minimapButton, _G.Minimap
    if not b or not mm or not db then return end
    local angle = math.rad(MinimapDB().angle)
    local cos, sin = math.cos(angle), math.sin(angle)
    local x, y
    -- GetMinimapShape is the convention minimap-button addons read (GaarMap defines it when it
    -- squares the minimap). On a square minimap the direction is stretched to the edge.
    local shape = pcall1(_G.GetMinimapShape) or "ROUND"
    local mw = type(mm.GetWidth) == "function" and pcall1(mm.GetWidth, mm)
    if IsSecret(mw) or type(mw) ~= "number" or mw <= 0 then mw = 140 end
    if shape == "SQUARE" then
        local half = mw / 2 + 8
        local reach = math.max(math.abs(cos), math.abs(sin))
        if reach < 0.0001 then reach = 1 end
        x, y = half * cos / reach, half * sin / reach
    else
        -- On the rim: half the minimap's width plus 5, the ring LibDBIcon buttons sit on.
        local r = mw / 2 + 5
        x, y = r * cos, r * sin
    end
    b:ClearAllPoints()
    b:SetPoint("CENTER", mm, "CENTER", x, y)
end
-- For an addon that changes the minimap's shape and wants the button re-placed at once.
_G.BetterQuestsForever_PlaceMinimapButton = PlaceMinimapButton

-- The cursor's angle around the minimap's centre, in degrees; nil when it cannot be read.
local function CursorAngle()
    local mm = _G.Minimap
    if not mm or type(_G.GetCursorPosition) ~= "function" then return nil end
    local mx, my = mm:GetCenter()
    local scale = mm:GetEffectiveScale()
    if IsSecret(mx) or IsSecret(my) or IsSecret(scale) then return nil end
    local cx, cy = _G.GetCursorPosition()
    if type(mx) ~= "number" or type(my) ~= "number" or type(cx) ~= "number" or type(cy) ~= "number"
        or type(scale) ~= "number" or scale == 0 then
        return nil
    end
    cx, cy = cx / scale, cy / scale
    return math.deg(atan2(cy - my, cx - mx)) % 360
end

local SetMinimapHidden -- defined below; the menu's "Hide" entry calls it

-- The options as data, shared by Blizzard's menu and the fallback menu.
local function MenuEntries()
    local list = {
        { text = "Enabled", checkbox = true, checked = function() return db.enabled end,
          func = function() SetEnabled(not db.enabled) end },
    }
    local maxItems = {}
    for _, n in ipairs(MENU_MAX) do
        maxItems[#maxItems + 1] = { text = MaxLabel(n), radio = true,
            checked = function() return db.max == n end, func = function() SetMax(n) end }
    end
    list[#list + 1] = { text = "Max quests shown", submenu = maxItems }
    local sortItems = {}
    for _, m in ipairs(MENU_SORT) do
        sortItems[#sortItems + 1] = { text = m[2], radio = true,
            checked = function() return db.sort == m[1] end, func = function() SetSort(m[1]) end }
    end
    list[#list + 1] = { text = "Sort by", submenu = sortItems }
    local completedItems = {}
    for _, m in ipairs(MENU_COMPLETED) do
        local text = m[2]
        if m[1] == "level" and db.sort == "distance" then text = "With the others" end
        completedItems[#completedItems + 1] = { text = text, radio = true,
            checked = function() return db.completed == m[1] end, func = function() SetCompleted(m[1]) end }
    end
    list[#list + 1] = { text = "Completed quests", submenu = completedItems }
    list[#list + 1] = { text = "Backdrop", checkbox = true, checked = function() return BackdropDB().enabled end,
        func = function() SetBackdropEnabled(not BackdropDB().enabled) end }
    local alphaItems = {}
    for _, n in ipairs(MENU_ALPHA) do
        alphaItems[#alphaItems + 1] = { text = n .. "%", radio = true,
            checked = function() return AlphaPercent() == n end, func = function() SetBackdropAlpha(n) end }
    end
    list[#list + 1] = { text = "Backdrop opacity", submenu = alphaItems }
    list[#list + 1] = { text = "Hide in combat", checkbox = true, checked = function() return db.hideInCombat end,
        func = function() SetHideInCombat(not db.hideInCombat) end }
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Hide minimap button", func = function() SetMinimapHidden(true) end }
    return list
end

local function AddMenuEntries(root, entries)
    for _, e in ipairs(entries) do
        if e.divider then
            if type(root.CreateDivider) == "function" then root:CreateDivider() end
        elseif e.submenu then
            local sub = root:CreateButton(e.text)
            if type(sub) == "table" then AddMenuEntries(sub, e.submenu) end
        elseif e.checkbox and type(root.CreateCheckbox) == "function" then
            root:CreateCheckbox(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.radio and type(root.CreateRadio) == "function" then
            root:CreateRadio(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox or e.radio then
            -- A menu without checkboxes or radios: show the state in the label instead.
            root:CreateButton((e.checked() and "[x] " or "[ ] ") .. e.text, function() e.func() end)
        else
            root:CreateButton(e.text, function() e.func() end)
        end
    end
end

-- A small menu drawn here for clients without MenuUtil (not UIDropDownMenu, whose shared state
-- is prone to taint). Submenus are shown inline under their heading.
local customMenu
local function ShowCustomMenu(owner, entries)
    local m = customMenu
    if not m then
        m = CreateFrame("Frame", "BetterQuestsForeverMinimapMenu", _G.UIParent, "BackdropTemplate")
        m:SetFrameStrata("DIALOG")
        if type(m.SetBackdrop) == "function" then
            m:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 } })
            m:SetBackdropColor(0.07, 0.08, 0.10, 0.97)
            m:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
        end
        m:EnableMouse(true)
        m:SetClampedToScreen(true)
        m.rows = {}
        m:Hide()
        if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "BetterQuestsForeverMinimapMenu") end
        -- Close once the mouse has been away from both the menu and the button for a moment.
        m:SetScript("OnUpdate", function(self, elapsed)
            local over = self:IsMouseOver() or (self.owner and self.owner:IsMouseOver())
            if over then
                self.idle = 0
            else
                self.idle = (self.idle or 0) + (elapsed or 0)
                if self.idle > 2 then self:Hide() end
            end
        end)
        customMenu = m
    end
    if m:IsShown() and m.owner == owner then
        m:Hide()
        return m
    end

    local rows = { { title = TITLE } }
    for _, e in ipairs(entries) do
        if e.submenu then
            rows[#rows + 1] = { heading = e.text }
            for _, s in ipairs(e.submenu) do rows[#rows + 1] = s end
        else
            rows[#rows + 1] = e
        end
    end
    local w, y = 170, -6
    for i, it in ipairs(rows) do
        local r = m.rows[i]
        if not r then
            r = CreateFrame("Button", nil, m)
            r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.text:SetPoint("LEFT", 8, 0)
            r.text:SetJustifyH("LEFT")
            r:SetHighlightTexture(FLAT, "ADD")
            local hl = r:GetHighlightTexture()
            if hl then hl:SetVertexColor(1, 1, 1, 0.10) end
            m.rows[i] = r
        end
        local h = it.divider and 8 or 18
        r:SetHeight(h)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 4, y)
        r:SetPoint("TOPRIGHT", -4, y)
        if it.title or it.heading or it.divider then
            local label = it.title and ("|cffffd100" .. it.title .. "|r")
                or it.heading and ("|cffaaaaaa" .. it.heading .. "|r") or ""
            r.text:SetText(label)
            r:EnableMouse(false)
            r:SetScript("OnClick", nil)
        else
            local label = it.text
            if it.checkbox then
                label = (it.checked() and "|TInterface\\Buttons\\UI-CheckBox-Check:14:14|t "
                    or "|TInterface\\Buttons\\UI-CheckBox-Up:14:14|t ") .. label
            elseif it.radio then
                label = "   " .. (it.checked() and "|cff33ff99(o)|r " or "( ) ") .. label
            end
            r.text:SetText(label)
            r:EnableMouse(true)
            r:SetScript("OnClick", function()
                m:Hide()
                it.func()
            end)
        end
        w = math.max(w, (pcall1(r.text.GetStringWidth, r.text) or 0) + 24)
        r:Show()
        y = y - h
    end
    for i = #rows + 1, #m.rows do m.rows[i]:Hide() end
    m:SetSize(w, -y + 6)
    m:ClearAllPoints()
    m:SetPoint("TOPRIGHT", owner, "BOTTOMLEFT", 0, 0)
    m.owner = owner
    m.idle = 0
    m:Show()
    return m
end

-- Returns which menu was used ("MenuUtil" or "custom").
local function ShowMinimapMenu(owner)
    local entries = MenuEntries()
    local MU = _G.MenuUtil
    if type(MU) == "table" and type(MU.CreateContextMenu) == "function" then
        local ok = pcall(MU.CreateContextMenu, owner, function(_, root)
            if type(root.CreateTitle) == "function" then root:CreateTitle(TITLE) end
            AddMenuEntries(root, entries)
        end)
        if ok then return "MenuUtil" end
    end
    ShowCustomMenu(owner, entries)
    return "custom"
end

local function StateLine()
    return (db.enabled and "On" or "Off") .. " \194\183 " .. SortMode() .. " \194\183 max " .. MaxLabel(db.max)
        .. " \194\183 completed: " .. db.completed
        .. " \194\183 bg " .. (BackdropDB().enabled and (AlphaPercent() .. "%") or "off")
end

local function BuildMinimapButton()
    if minimapButton then return minimapButton end
    local mm = _G.Minimap
    if type(mm) ~= "table" then return nil end

    local b = CreateFrame("Button", "BetterQuestsForeverMinimapButton", mm)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel((pcall1(mm.GetFrameLevel, mm) or 0) + 8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    -- The standard minimap-button look: dark disc, the icon, the gold tracking ring on top.
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(PickMinimapIcon())
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    b.icon = icon

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)

    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    local tip = _G.GameTooltip
    b:SetScript("OnDragStart", function(self)
        if tip then tip:Hide() end
        self:SetScript("OnUpdate", function()
            local a = CursorAngle()
            if a then
                MinimapDB().angle = a
                PlaceMinimapButton()
            end
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    b:SetScript("OnEnter", function(self)
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_LEFT")
        tip:AddLine(TITLE)
        tip:AddLine(StateLine(), 1, 1, 1)
        tip:AddLine("Click: options", 1, 1, 1)
        tip:AddLine("Drag: move", 0.6, 0.6, 0.6)
        tip:Show()
    end)
    b:SetScript("OnLeave", function()
        if tip then tip:Hide() end
    end)
    b:SetScript("OnClick", function(self)
        if tip then tip:Hide() end
        ShowMinimapMenu(self)
    end)

    minimapButton = b
    return b
end

local function ApplyMinimap()
    if not db then return end
    if MinimapDB().hide then
        if minimapButton then minimapButton:Hide() end
        if customMenu then customMenu:Hide() end
        return
    end
    if BuildMinimapButton() then
        PlaceMinimapButton()
        minimapButton:Show()
    end
end

SetMinimapHidden = function(hide)
    MinimapDB().hide = hide and true or false
    ApplyMinimap()
    if hide then
        Print("minimap button hidden. Type |cffffd100/bqf minimap|r to show it again.")
    else
        Print("minimap button shown.")
    end
end

local function ResetMinimapButton()
    local m = MinimapDB()
    m.angle = MINIMAP_DEFAULT_ANGLE
    m.hide = false
    ApplyMinimap()
    Print("minimap button reset to its default position.")
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function Yes(v) return v and "yes" or "MISSING" end

-- /bqf distance: a read-only check of whether this client can tell how far away each tracked
-- quest is (C_QuestLog.GetDistanceSqToQuest, what Blizzard's own proximity sort uses). It prints
-- one line per tracked quest and keeps the last result in BetterQuestsForeverDB.distanceProbe so
-- it can be read from the SavedVariables file after /reload. Nothing about the tracker changes.
local function DistanceProbe()
    local ql = QuestLog()
    local fn = ql and ql.GetDistanceSqToQuest
    local mapID = pcall1(_G.C_Map and _G.C_Map.GetBestMapForUnit, "player")
    local okB, version, build = Try(_G.GetBuildInfo)
    if not okB then version, build = nil, nil end
    local result = {
        when = type(_G.date) == "function" and _G.date("%Y-%m-%d %H:%M:%S") or nil,
        build = build and ((version or "") .. "." .. build) or nil,
        mapID = mapID,
        api = type(fn) == "function",
        quests = {},
    }
    Print("distance check - C_QuestLog.GetDistanceSqToQuest: " .. (result.api and "yes" or "no")
        .. ", map " .. tostring(mapID))
    local withDistance = 0
    for _, questID in ipairs(GetWatches()) do
        local d = QuestData(questID)
        local okD, distSq, onContinent = Try(fn, questID)
        if not okD then distSq, onContinent = nil, nil end
        local yards = type(distSq) == "number" and distSq >= 0 and math.floor(math.sqrt(distSq) + 0.5) or nil
        if yards then withDistance = withDistance + 1 end
        result.quests[#result.quests + 1] = { id = questID, title = d.title, level = d.level,
            complete = d.complete, distSq = distSq, onContinent = onContinent }
        Print(string.format("[%d] %s%s - %s", d.level or 0, d.title ~= "" and d.title or ("quest " .. questID),
            d.complete and " (complete)" or "",
            yards and (yards .. " yd" .. (onContinent == false and ", other continent" or "")) or "no distance"))
    end
    result.withDistance = withDistance
    db.distanceProbe = result
    Print(string.format("%d of %d tracked quests have a distance. Saved; /reload to write it to disk.",
        withDistance, #result.quests))
end

local function PrintHelp()
    Print("orders the Quests section of the objective tracker by level or distance and shows only the first N.")
    Print("/bqf sort level | distance - order by quest level or by how near the quest is (now: "
        .. (db and db.sort or DEFAULTS.sort) .. ")")
    Print("/bqf max <n> | all - show at most n quests, 1-" .. (MAX_MAX - 1) .. ", or all (now: "
        .. MaxLabel(db and db.max or DEFAULTS.max) .. ")")
    Print("/bqf completed top | level | bottom - where quests ready to turn in go (now: "
        .. (db and db.completed or DEFAULTS.completed) .. ")")
    Print("/bqf on | off - switch the addon on or off; off is Blizzard's own tracker (now: "
        .. ((db and db.enabled) and "on" or "off") .. ")")
    Print("/bqf bg on | off | <0-100> - dark backdrop behind the tracker, on/off or its opacity in percent (now: "
        .. (db and (BackdropDB().enabled and (AlphaPercent() .. "%") or "off") or "?") .. ")")
    Print("/bqf combat on | off - hide the whole objective tracker during combat (now: "
        .. ((db and db.hideInCombat or not db and DEFAULTS.hideInCombat) and "on" or "off") .. ")")
    Print("/bqf minimap - show or hide the minimap button; /bqf minimap reset - default place, shown")
    Print("/bqf status - settings, counts and what this client offers")
    Print("/bqf distance - check whether this client knows how far away each tracked quest is")
end

local function PrintStatus()
    local ql = QuestLog()
    Print("enabled: " .. (db.enabled and "yes" or "no") .. "   sort: " .. db.sort .. "   max: " .. MaxLabel(db.max)
        .. "   completed: " .. db.completed)
    local watches = GetWatches()
    local inSection = 0
    for _, questID in ipairs(watches) do
        if QuestData(questID).inQuestsSection then inSection = inSection + 1 end
    end
    Print(string.format("tracked: %d (Quests section: %d)   shown: %s", #watches, inSection,
        shownCount and tostring(shownCount) or "all (limit not applied)"))
    Print("backdrop: " .. (BackdropDB().enabled and (AlphaPercent() .. "% opacity") or "off") .. " - "
        .. (backdropState or "not measured yet"))
    local hide
    if combatHidden then
        hide = (db.hideInCombat and "on" or "off (after this fight)") .. " - hidden for this fight"
    elseif not db.hideInCombat then
        hide = "off - the tracker stays visible in combat"
    else
        local otf, why = CombatHideTarget()
        if not otf then
            hide = "on - not available: " .. why
        elseif combatProblem then
            hide = "on - last fight: " .. combatProblem
        else
            hide = "on - ready (Blizzard's secure state driver, during combat only)"
        end
    end
    Print("hide in combat: " .. hide)
    local otf = _G.ObjectiveTrackerFrame
    if IsFrame(otf) then
        Print("ObjectiveTrackerFrame: " .. (IsShownFrame(otf) and "shown" or "hidden")
            .. "   protected: " .. (IsProtectedFrame(otf) and "yes" or "no"))
    end
    Print("tracker: " .. (tracker and "QuestObjectiveTracker recognised" or ("not recognised - " .. (trackerProblem or "not checked yet"))))
    Print("hooks: " .. (hooked and "hooksecurefunc on QuestObjectiveTracker Update + UpdateHeight" or "none"))
    local order
    if not db.enabled then
        order = "off (Blizzard's own)"
    elseif layoutProblem then
        order = "not applied - " .. layoutProblem
    elseif InCombat() then
        order = "Blizzard's own during combat" .. (pending and "; applied after combat" or "")
    elseif orderedCount then
        order = "visual (applied to " .. orderedCount .. " blocks)"
    else
        order = "visual (waiting for the tracker's next layout)"
    end
    Print("order: " .. order)
    Print("watch list: never changed by this addon")
    Print("C_QuestLog (GetNumQuestWatches, GetQuestIDForQuestWatchIndex, GetLogIndexForQuestID, GetInfo): "
        .. Yes(not MissingQuestApi()) .. "   IsComplete: " .. Yes(ql and type(ql.IsComplete) == "function"))
    local qis = _G.C_QuestInfoSystem
    Print("C_QuestInfoSystem.GetQuestClassification: " .. Yes(type(qis) == "table"
        and type(qis.GetQuestClassification) == "function")
        .. "   MenuUtil: " .. (type(_G.MenuUtil) == "table" and "yes" or "no (own menu)"))
    local m = MinimapDB()
    Print("minimap button: " .. (m.hide and "hidden (/bqf minimap shows it)" or string.format("shown at %d degrees", m.angle))
        .. (type(_G.Minimap) ~= "table" and " - no Minimap frame on this client" or ""))
end

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    if msg == "distance" then
        DistanceProbe()
        return
    end
    local n = msg:match("^max (%d+)$")
    local mode = msg:match("^completed (%a+)$")
    local sortMode = msg:match("^sort (%a+)$")
    if msg == "max all" then
        SetMax(MAX_MAX)
    elseif n then
        n = tonumber(n)
        if n < MIN_MAX or n > MAX_MAX then
            Print("max must be between " .. MIN_MAX .. " and " .. MAX_MAX .. ", or all.")
            return
        end
        SetMax(n)
    elseif mode then
        if not COMPLETED_MODES[mode] then
            Print("use /bqf completed top, level or bottom.")
            return
        end
        SetCompleted(mode)
    elseif sortMode or msg == "sort" then
        if not SORT_MODES[sortMode] then
            Print("use /bqf sort level or distance (now: " .. db.sort .. ").")
            return
        end
        SetSort(sortMode)
    elseif msg == "on" then
        SetEnabled(true)
    elseif msg == "off" then
        SetEnabled(false)
    elseif msg == "bg on" then
        SetBackdropEnabled(true)
    elseif msg == "bg off" then
        SetBackdropEnabled(false)
    elseif msg:match("^bg ") then
        local pct = tonumber(msg:match("^bg (.+)$"))
        if not pct or pct ~= pct then
            Print("use /bqf bg on, off or a percentage 0-100.")
            return
        end
        SetBackdropAlpha(pct)
    elseif msg == "combat on" then
        SetHideInCombat(true)
    elseif msg == "combat off" then
        SetHideInCombat(false)
    elseif msg == "combat" or msg:match("^combat ") then
        Print("use /bqf combat on or off (now: " .. (db.hideInCombat and "on" or "off") .. ").")
    elseif msg == "minimap" then
        SetMinimapHidden(not MinimapDB().hide)
    elseif msg == "minimap reset" then
        ResetMinimapButton()
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
    if not SORT_MODES[db.sort] then db.sort = DEFAULTS.sort end
    if type(db.hideInCombat) ~= "boolean" then db.hideInCombat = DEFAULTS.hideInCombat end
    MinimapDB()
    BackdropDB()
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
            UpdateDistanceTicker()
            pcall(ApplyMinimap)
            pcall(HookBackdropTargets)
            MarkBackdrop()
            Schedule()
        elseif db and not hooked and arg1 == "Blizzard_ObjectiveTracker" then
            Schedule()
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Fires before the lockdown starts: hand the section back to Blizzard for the fight, then
        -- hide the whole tracker if that is wanted.
        RestoreAll()
        pcall(StartCombatHide)
        MarkBackdrop()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Fires after the lockdown ends: the tracker back first, then order, limit and backdrop.
        pcall(EndCombatHide)
        Schedule()
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        -- Placed again in case another addon changed the minimap's shape since ADDON_LOADED.
        if db then pcall(ApplyMinimap) end
        Schedule()
    else
        Schedule()
    end
end)

SLASH_BETTERQUESTSFOREVER1 = "/bqf"
SLASH_BETTERQUESTSFOREVER2 = "/betterquestsforever"
SlashCmdList.BETTERQUESTSFOREVER = OnSlash
