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
    * Limit: only the first N quests of that order are shown (default 10).
    * Auto-watch (1.9, default on): the addon decides WHICH quests are watched. It watches the
      quests of the Quests section that come first in the order above and fit in the tracker's
      height, and un-watches the rest, so the quests Blizzard draws are exactly the addon's top
      quests that fit. The tracker's height is never changed: it is Blizzard's (the Edit Mode
      Height). See "Auto-watch" above AutoWatch.Run for how the fit is measured and why it settles.
      Off (/bqf autowatch off), the watch list is the player's and is never touched; the order and
      the limit then only change what is drawn of it.
    * Dungeon filter (1.10, default off, /bqf dungeon on): inside a dungeon or raid instance only
      the quests of that instance are watched (in the order above); the rest are un-watched. No
      matching quest: the normal behaviour. See "Dungeon filter" below auto-watch.

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

  Height (1.9): the tracker's container is never resized and Blizzard's UpdateHeight is never
  topped up; 1.7/1.7.1 did that and are gone. The only SetHeight left is on the Quests section
  itself, and only to make it shorter when the limit hides blocks (see SetSectionHeight); with
  auto-watch on, the limit has nothing to hide once the watch list has settled.

  Auto-watch and taint: C_QuestLog.AddQuestWatch/RemoveQuestWatch are not protected. They are
  called only from this addon's own throttle frame (never from inside a Blizzard function or one
  of our hooks on it), out of combat and outside Edit Mode. Blizzard's tracker learns of the
  change from the client's QUEST_WATCH_LIST_CHANGED event, as when the player clicks Track.

  Hide in combat (default on): the whole objective tracker (ObjectiveTrackerFrame) and the
  backdrop are hidden for the length of a fight. The tracker is hidden and shown by Blizzard's
  secure state driver (RegisterStateDriver), never by this addon's own code; see "Hide in combat"
  below for why that is the only taint-safe way.

  Options: /bqf, and a minimap button whose menu has the same settings.

  Set GPS target (1.6): with BetterGpsForever loaded, the tracker's own right-click menu for a
  quest (Focus, Open Quest Details, ...) gets a "Set GPS target" entry after Focus. It sets
  BetterGpsForever's one waypoint, titled with the quest's name, on the point Blizzard shows for
  the quest: its next waypoint (C_QuestLog.GetNextWaypoint), else its POI on the quest's own map
  or the player's maps (C_QuestLog.GetQuestsOnMap; the turn-in point once the quest is complete),
  else C_QuestLog.GetNextWaypointForMap. Greyed out when there is no such point. The entry is
  added through Blizzard's public Menu.ModifyMenu("MENU_QUEST_OBJECTIVE_TRACKER", ...), and the
  waypoint is set only through BetterGpsForeverAPI.SetWaypoint. Without BetterGpsForever there is
  no entry and nothing else changes.

  BetterQuestsForeverAPI is a small global table for BetterForever, the family hub that
  shows these options in its own minimap menu (version, StatusLine, MenuEntries, AddMenuEntries,
  SetMinimapHidden). While the hub is loaded this addon's own minimap button is hidden for the
  session; the saved minimap setting is never changed for that. Without the hub nothing changes.

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
    autoWatch = true,
    dungeonFilter = false,
}
local BACKDROP_DEFAULTS = { enabled = true, alpha = 0.5 }

-- Every key BetterQuestsForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = { enabled = true, max = true, completed = true, minimap = true, backdrop = true,
    hideInCombat = true, distanceProbe = true, sort = true, autoWatch = true, dungeonFilter = true,
    dungeonRestore = true }

-- How long events are collected before the layout is re-evaluated.
local THROTTLE = 0.3

local db                -- BetterQuestsForeverDB, bound at ADDON_LOADED (never at file scope)
local tracker           -- the QuestObjectiveTracker module once recognised
local trackerProblem    -- why the tracker was not recognised, for /bqf status
local hooked            -- our hooksecurefunc hooks are in place
local layoutProblem     -- why the last pass could not order/limit the section, for /bqf status
local pending           -- an evaluation is waiting (throttle or combat)
local heightSet         -- the section's frame is shorter than Blizzard's (the limit hid blocks)
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
    -- Only ever shorter than Blizzard's: never taller than what Blizzard laid out.
    if h and h < full - 0.001 then
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

    -- Shown: Blizzard's fixed blocks, then the quests in our order, at most N. Blizzard only drew
    -- what fits its own height, so everything shown fits it too.
    local visible, hide = {}, {}
    for _, b in ipairs(fixed) do visible[#visible + 1] = b end
    local shownQuests = 0
    for _, d in ipairs(sortable) do
        if shownQuests < db.max then
            visible[#visible + 1] = d.block
            shownQuests = shownQuests + 1
        else
            hide[d.block] = true
        end
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
    shownCount = shownQuests
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

-- ---------------------------------------------------------------------------
-- Auto-watch (1.9)
--
-- Blizzard lays the Quests section out in its own watch order and stops at the first quest that
-- does not fit the room the container gives the section (ObjectiveTrackerModuleMixin:AddBlock /
-- CanFitBlock: contentsHeight + block.height - offsetY <= availableHeight). That quest and every
-- one after it get no block, so no sorting afterwards can draw them. Which quests are drawn
-- therefore depends on which are watched, and auto-watch manages exactly that - never the
-- height: the container's height is Blizzard's (the Edit Mode Height), nothing here resizes it.
--
-- The fit is read, never written, after each update of the QuestObjectiveTracker instance (a
-- hooksecurefunc post-hook on Update, see Observe):
--   * the availableHeight argument Blizzard passed to Update: the room for the section,
--   * contentsHeight (header and drawn blocks), hasSkippedBlocks (a quest did not fit), the block
--     chain (firstBlock/nextBlock: which quests got a block, and each block's height),
--   * fromHeaderOffsetY / fromBlockOffsetY: the spacing Blizzard adds per block.
-- Per quest it keeps the height of its block when it was last drawn, and for the quest that did
-- not fit (the first watched quest, in watch order, without a block) a lower bound on its height:
-- more than the room that was left.
--
-- A pass (out of combat, outside Edit Mode, throttled, from this addon's own throttle frame, and
-- only once Blizzard has laid out the previous change) ranks every quest of the Quests section in
-- the quest log with the addon's order (level or distance, completed quests as set), then walks
-- that ranking from the top, adding each quest's cost (its measured height, else an estimate from
-- its objective count, raised to its lower bound) to what the header and pop-ups take. It stops at the
-- first quest that does not fit, so a lower-ranked short quest never jumps a higher-ranked tall
-- one, and at N quests (Max quests shown) and Blizzard's watch cap. Those quests are watched, the
-- other quests of the section are un-watched. The focused (super-tracked) quest is never
-- un-watched and counts first; at least one quest stays watched. Campaign quests, world quests,
-- bonus objectives and anything else outside the Quests section are never touched.
--
-- Why it settles instead of oscillating:
--   * A quest that is not watched is added only when it fits with ADD_MARGIN px to spare; a
--     watched one stays while it fits at all (hysteresis at the edge).
--   * When an added quest does not fit after all, Blizzard's layout says so: it got no block (its
--     lower bound is now above the room that was left), or another quest got none and the added
--     one now has a measured height. Either way the next walk stops before it, and keeps doing so
--     until the room grows or the quest changes (a completed quest is measured afresh).
--   * Nothing is changed until Blizzard has laid out the last change (or SETTLE seconds passed).
--   * At most MAX_CHANGES watch changes per pass; more than THRASH_PASSES changing passes within
--     THRASH_WINDOW seconds pause auto-watch for THRASH_PAUSE seconds (said in chat and status).
--   * In distance mode the ranking keeps the distance order's own hysteresis (SortByDistance).
--
-- Manual tracking: while auto-watch is on, a quest tracked or untracked by hand is set back the
-- way the ranking wants on the next pass. /bqf autowatch off hands the watch list back; nothing
-- is restored or changed when it goes off (or when the addon is switched off).
-- ---------------------------------------------------------------------------

local Dungeon = {} -- the dungeon filter (1.10); its functions are defined below auto-watch

local AutoWatch = {
    ADD_MARGIN = 4,       -- px a quest that is not watched must leave free before it is added
    MAX_CHANGES = 10,     -- watch changes per pass
    THRASH_PASSES = 10, THRASH_WINDOW = 30, THRASH_PAUSE = 60,
    SETTLE = 2,           -- s to wait for Blizzard's layout of a change
    HEIGHT_TTL = 1800,    -- s a measured height is used for a quest that is not drawn now
    MIN_TTL = 600,        -- s a "did not fit" lower bound is kept
    REFUSED_TTL = 60,     -- s before a quest the client would not watch is tried again
    DEFAULT_LINE = 16,    -- px per text line for a quest never measured, before any block was seen
    heights = {},         -- questID -> { h, t, complete } of its last drawn block
    minHeights = {},      -- questID -> { h, t }: it did not fit, its block is taller than h
    refused = {},         -- questID -> time the client did not watch it
    passTimes = {},       -- times of passes that changed the watch list (thrash guard)
    changeSeq = 0,        -- bumped on every change; an observation carries the value it saw
    changedAt = -1000,
    -- snap: the last observation; plan: the last walk; last: the last change; state: for status;
    -- prevOrder: the distance ranking of the last pass; editModeHook: how Edit Mode is followed
}

function AutoWatch.Now()
    return pcall1(_G.GetTime) or 0
end

function AutoWatch.IsEditMode()
    local em = _G.EditModeManagerFrame
    if type(em) ~= "table" or type(em.IsEditModeActive) ~= "function" then return false end
    return pcall1(em.IsEditModeActive, em) and true or false
end

-- The C_QuestLog functions auto-watch needs; the first missing name, or nil.
function AutoWatch.MissingApi()
    local ql = QuestLog()
    if not ql then return "C_QuestLog" end
    for _, name in ipairs({ "AddQuestWatch", "RemoveQuestWatch", "GetNumQuestLogEntries", "GetInfo",
        "GetNumQuestWatches", "GetQuestIDForQuestWatchIndex", "GetLogIndexForQuestID" }) do
        if type(ql[name]) ~= "function" then return "C_QuestLog." .. name end
    end
end

-- Blizzard's cap on watched quests (retail constant, else the old global, else 25).
function AutoWatch.Cap()
    local c = _G.Constants
    local n = type(c) == "table" and type(c.QuestWatchConsts) == "table" and c.QuestWatchConsts.MAX_QUEST_WATCHES
    if type(n) ~= "number" then n = _G.MAX_WATCHABLE_QUESTS end
    if type(n) ~= "number" or IsSecret(n) or n < 1 then n = 25 end
    return n
end

function AutoWatch.Collapsed()
    local otf = _G.ObjectiveTrackerFrame
    if type(otf) == "table" and otf.isCollapsed == true then return true end
    local c = tracker and tracker.parentContainer
    if type(c) == "table" and c.isCollapsed == true then return true end
    return tracker ~= nil and tracker.isCollapsed == true
end

function AutoWatch.Focused()
    local st = _G.C_SuperTrack
    local id = type(st) == "table" and pcall1(st.GetSuperTrackedQuestID) or nil
    if type(id) == "number" and not IsSecret(id) and id > 0 then return id end
end

-- Text lines of a quest's block: its title and one per objective, or title and the completion line.
function AutoWatch.Lines(d)
    if d.complete then return 2 end
    local ql = QuestLog()
    local objectives = ql and pcall1(ql.GetQuestObjectives, d.id)
    local n = type(objectives) == "table" and not IsSecret(objectives) and #objectives or 1
    return 1 + math.max(n, 1)
end

local function QuestLabel(d)
    return "[" .. (d.level or 0) .. "] " .. (d.title ~= "" and d.title or ("quest " .. d.id))
end

-- Reads Blizzard's last layout of the section. Runs in the post-hook on Update, read-only.
function AutoWatch.Observe(avail)
    if not tracker or not db then return end
    local now = AutoWatch.Now()
    avail = Num(avail)
    local contents = Num(tracker.contentsHeight)
    local firstOff = Num(tracker.fromHeaderOffsetY) or 0
    local nextOff = Num(tracker.fromBlockOffsetY) or 0
    local watches = GetWatches()
    local watched = {}
    for _, id in ipairs(watches) do watched[id] = true end

    local chain = BlockChain()
    local drawn, ids, nDrawn, nFixed, linePx = {}, {}, 0, 0, nil
    local base = contents -- what the header and the blocks that are not ours take
    for k, b in ipairs(chain) do
        local d = IsQuestBlock(b) and watched[b.id] and QuestData(b.id)
        if d and d.inLog and d.inQuestsSection then
            local h = BlockHeight(b)
            drawn[b.id] = h
            ids[#ids + 1] = b.id
            nDrawn = nDrawn + 1
            if base then base = base - (h - (k == 1 and firstOff or nextOff)) end
            AutoWatch.heights[b.id] = { h = h, t = now, complete = d.complete }
            AutoWatch.minHeights[b.id] = nil
            local perLine = h / AutoWatch.Lines(d)
            if perLine > 0 and (not linePx or perLine < linePx) then linePx = perLine end
        else
            nFixed = nFixed + 1
        end
    end
    if linePx then AutoWatch.linePx = linePx end

    -- The quest Blizzard tried and could not fit: the first watched one in watch order without a
    -- block (BuildQuestWatchInfos keeps watch order). Its block is taller than the room left.
    local skipped = tracker.hasSkippedBlocks == true
    local failed
    if skipped and avail and contents then
        for _, id in ipairs(watches) do
            if not drawn[id] then
                local d = QuestData(id)
                if d.inLog and d.inQuestsSection then
                    failed = d
                    local low = avail - contents + (#chain == 0 and firstOff or nextOff) + 0.5
                    local m = AutoWatch.minHeights[id]
                    if low > 0 and (not m or m.h < low or now - m.t > AutoWatch.MIN_TTL) then
                        AutoWatch.minHeights[id] = { h = low, t = now }
                    end
                    break
                end
            end
        end
    end

    local collapsed = AutoWatch.Collapsed()
    AutoWatch.snap = { avail = avail, contents = contents, base = base, firstOff = firstOff, nextOff = nextOff,
        nFixed = nFixed, drawn = drawn, nDrawn = nDrawn, skipped = skipped, failed = failed,
        collapsed = collapsed, seq = AutoWatch.changeSeq }
    local key = string.format("%s:%s:%s:%s:%s", avail and math.floor(avail + 0.5) or "-",
        contents and math.floor(contents + 0.5) or "-", tostring(skipped), tostring(collapsed), table.concat(ids, ","))
    if key ~= AutoWatch.snapKey or AutoWatch.seenSeq ~= AutoWatch.changeSeq then
        AutoWatch.snapKey, AutoWatch.seenSeq = key, AutoWatch.changeSeq
        if db.enabled and db.autoWatch and AutoWatch.Schedule then AutoWatch.Schedule() end
    end
end

-- Every quest of the Quests section in the quest log, in the addon's order.
function AutoWatch.Pool()
    local ql = QuestLog()
    local pool, seen = {}, {}
    local ok, n = Try(ql.GetNumQuestLogEntries)
    if not ok or type(n) ~= "number" then return pool end
    for i = 1, n do
        local info = pcall1(ql.GetInfo, i)
        local id = type(info) == "table" and not info.isHeader and not info.isHidden and info.questID
        if type(id) == "number" and id > 0 and not seen[id] then
            seen[id] = true
            local d = QuestData(id)
            if d.inLog and d.inQuestsSection then pool[#pool + 1] = d end
        end
    end
    if SortMode() == "distance" then
        for _, d in ipairs(pool) do d.dist = QuestDistance(d.id) end
        SortByDistance(pool, AutoWatch.prevOrder)
        AutoWatch.prevOrder = {}
        for i, d in ipairs(pool) do AutoWatch.prevOrder[i] = d.id end
    else
        table.sort(pool, Compare)
    end
    return pool
end

-- The height a quest's block is expected to have: measured when it was drawn, else its text lines
-- times the smallest height per line seen in drawn blocks (on the low side on purpose: a quest
-- that then does not fit gets a measured height or a lower bound, and is not tried again).
function AutoWatch.Estimate(d, snap, now)
    local h = snap.drawn[d.id]
    if not h then
        local known = AutoWatch.heights[d.id]
        if known and now - known.t <= AutoWatch.HEIGHT_TTL and known.complete == d.complete then h = known.h end
    end
    h = h or AutoWatch.Lines(d) * (AutoWatch.linePx or AutoWatch.DEFAULT_LINE)
    local m = AutoWatch.minHeights[d.id]
    if m and now - m.t <= AutoWatch.MIN_TTL and m.h > h then h = m.h end
    return h
end

-- The set of quests that should be watched: the top of the ranking that fits (see above).
-- walk: the ranking to take quests from when it is narrower than the pool (the dungeon filter's
-- matching quests, in the pool's order); the focused quest still counts first.
function AutoWatch.Plan(snap, pool, watched, now, walk)
    walk = walk or pool
    local inPool = {}
    for _, d in ipairs(pool) do inPool[d.id] = true end
    local others = 0
    for id in pairs(watched) do
        if not inPool[id] then others = others + 1 end
    end
    local cap = AutoWatch.Cap() - others
    if db.max < MAX_MAX then cap = math.min(cap, db.max) end
    cap = math.max(cap, 1)

    local focused = AutoWatch.Focused()
    if not (focused and inPool[focused] and watched[focused]) then focused = nil end

    local target, count = {}, 0
    local used, slot = snap.base or 0, snap.nFixed
    local function cost(d)
        return AutoWatch.Estimate(d, snap, now) - (slot == 0 and snap.firstOff or snap.nextOff)
    end
    for _, d in ipairs(pool) do
        if d.id == focused then
            used, slot, count = used + cost(d), slot + 1, 1
            target[d.id] = true
            break
        end
    end
    local nextCost
    for _, d in ipairs(walk) do
        if not target[d.id] then
            if count >= cap then break end
            local c = cost(d)
            local need = watched[d.id] and c or (c + AutoWatch.ADD_MARGIN)
            if used + need > snap.avail + 0.01 then
                nextCost = c
                break
            end
            used, slot, count = used + c, slot + 1, count + 1
            target[d.id] = true
        end
    end
    if count == 0 and walk[1] then
        target[walk[1].id] = true
        count = 1
    end
    AutoWatch.plan = { count = count, cap = cap, used = used, avail = snap.avail, nextCost = nextCost }
    return target
end

-- Watches a quest as if the player clicked Track (watch type Manual where the client has it).
function AutoWatch.AddWatch(questID)
    local ql = QuestLog()
    local enum = _G.Enum
    local manual = type(enum) == "table" and type(enum.QuestWatchType) == "table" and enum.QuestWatchType.Manual or nil
    if manual ~= nil then Try(ql.AddQuestWatch, questID, manual) else Try(ql.AddQuestWatch, questID) end
end

-- Makes the watch list match target for the quests of the pool. Returns true when it changed.
function AutoWatch.Apply(pool, target, watched, now)
    local removes, adds = {}, {}
    for _, d in ipairs(pool) do
        if watched[d.id] and not target[d.id] then
            removes[#removes + 1] = d
        elseif target[d.id] and not watched[d.id] then
            local r = AutoWatch.refused[d.id]
            if not (r and now - r <= AutoWatch.REFUSED_TTL) then adds[#adds + 1] = d end
        end
    end
    if #removes == 0 and #adds == 0 then return false end

    local recent = {}
    for _, t in ipairs(AutoWatch.passTimes) do
        if now - t <= AutoWatch.THRASH_WINDOW then recent[#recent + 1] = t end
    end
    AutoWatch.passTimes = recent
    if #recent >= AutoWatch.THRASH_PASSES then
        AutoWatch.pausedUntil = now + AutoWatch.THRASH_PAUSE
        Print("watch changes paused for " .. AutoWatch.THRASH_PAUSE .. " s: the watch list kept changing. /bqf status shows the last change.")
        return false
    end
    recent[#recent + 1] = now

    local ql = QuestLog()
    local done, removed, added = 0, {}, {}
    -- Lowest-ranked first, then the adds in ranking order.
    for i = #removes, 1, -1 do
        if done >= AutoWatch.MAX_CHANGES then break end
        Try(ql.RemoveQuestWatch, removes[i].id)
        removed[#removed + 1] = removes[i]
        done = done + 1
    end
    for _, d in ipairs(adds) do
        if done >= AutoWatch.MAX_CHANGES then break end
        AutoWatch.AddWatch(d.id)
        added[#added + 1] = d
        done = done + 1
    end

    local nowWatched = {}
    for _, id in ipairs(GetWatches()) do nowWatched[id] = true end
    local last = { at = type(_G.date) == "function" and _G.date("%H:%M:%S") or "", added = {}, removed = {}, refused = {} }
    for _, d in ipairs(added) do
        if nowWatched[d.id] then
            last.added[#last.added + 1] = QuestLabel(d)
        else
            AutoWatch.refused[d.id] = now
            last.refused[#last.refused + 1] = QuestLabel(d)
        end
    end
    for _, d in ipairs(removed) do
        if not nowWatched[d.id] then last.removed[#last.removed + 1] = QuestLabel(d) end
    end
    AutoWatch.last = last
    AutoWatch.changeSeq = AutoWatch.changeSeq + 1
    AutoWatch.changedAt = now
    -- In case Blizzard does not lay the tracker out again (nothing it draws changed).
    if type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" and AutoWatch.Schedule then
        pcall(_G.C_Timer.After, AutoWatch.SETTLE + 0.1, AutoWatch.Schedule)
    end
    return true
end

-- One pass. Called from Evaluate on this addon's throttle frame, never from a Blizzard hook.
function AutoWatch.Run()
    local function state(s) AutoWatch.state = s end
    if not db then return end
    if not db.enabled then return state("off - BetterQuestsForever is off") end
    if not db.autoWatch then return state("off - the watch list is yours (/bqf autowatch on)") end
    if InCombat() then return state("waiting for the end of combat") end
    if AutoWatch.IsEditMode() then return state("paused while Edit Mode is open") end
    if not tracker then return state("waiting for the tracker") end
    local missing = AutoWatch.MissingApi()
    if missing then return state("not available - " .. missing .. " missing") end
    local now = AutoWatch.Now()
    if AutoWatch.pausedUntil then
        if now < AutoWatch.pausedUntil then
            return state(string.format("paused for %d s more: the watch list kept changing", AutoWatch.pausedUntil - now))
        end
        AutoWatch.pausedUntil = nil
        AutoWatch.passTimes = {}
    end
    local snap = AutoWatch.snap
    if not snap or not snap.avail or not snap.contents then return state("waiting for the tracker's first layout") end
    if snap.collapsed then return state("tracker collapsed - watches left alone") end
    if snap.avail <= 0 then
        return state("no room for the Quests section (the sections above use it all) - watches left alone")
    end
    if snap.seq ~= AutoWatch.changeSeq and now - AutoWatch.changedAt < AutoWatch.SETTLE then
        return state("waiting for Blizzard's layout of the last change")
    end
    local watched = {}
    for _, id in ipairs(GetWatches()) do watched[id] = true end
    local pool = AutoWatch.Pool()
    if #pool == 0 then return state("no quests for the Quests section in the quest log") end
    -- Inside a dungeon or raid with the filter on: only that instance's quests are ranked.
    local okWalk, walk = pcall(Dungeon.Walk, pool)
    if not okWalk then
        Dungeon.state = "error: " .. tostring(walk)
        walk = nil
    end
    local target = AutoWatch.Plan(snap, pool, watched, now, walk)
    if AutoWatch.Apply(pool, target, watched, now) then
        state("changed the watch list; checking Blizzard's new layout")
    elseif AutoWatch.pausedUntil then
        state(string.format("paused for %d s: the watch list kept changing", AutoWatch.THRASH_PAUSE))
    else
        state("settled")
    end
    if walk then AutoWatch.state = AutoWatch.state .. " (dungeon filter: " .. #walk .. " quests ranked)" end
end

-- Edit Mode: the watch list is left alone while it is open (Run checks), and looked at again when
-- it closes. EditModeManagerFrame:EnterEditMode/ExitEditMode end with EventRegistry's
-- "EditMode.Enter"/"EditMode.Exit"; without EventRegistry the two methods are hooked instead.
-- Either way the addon only reacts, after Blizzard's own code.
function AutoWatch.OnEditMode()
    if AutoWatch.Schedule then AutoWatch.Schedule() end
end

function AutoWatch.HookEditMode()
    if AutoWatch.editModeHook then return end
    local reg = _G.EventRegistry
    if type(reg) == "table" and type(reg.RegisterCallback) == "function" then
        local owner = {}
        if pcall(reg.RegisterCallback, reg, "EditMode.Enter", AutoWatch.OnEditMode, owner)
            and pcall(reg.RegisterCallback, reg, "EditMode.Exit", AutoWatch.OnEditMode, owner) then
            AutoWatch.editModeHook = "EventRegistry EditMode.Enter/Exit"
            return
        end
    end
    local em = _G.EditModeManagerFrame
    if type(em) == "table" and type(em.EnterEditMode) == "function" and type(em.ExitEditMode) == "function"
        and type(_G.hooksecurefunc) == "function" then
        if pcall(hooksecurefunc, em, "EnterEditMode", AutoWatch.OnEditMode)
            and pcall(hooksecurefunc, em, "ExitEditMode", AutoWatch.OnEditMode) then
            AutoWatch.editModeHook = "hooksecurefunc on EditModeManagerFrame Enter/ExitEditMode"
        end
    end
end

-- /bqf status lines.
function AutoWatch.StatusLines(inSection)
    local lines = {}
    lines[1] = "auto-watch: " .. (db.autoWatch and "on" or "off") .. " - " .. (AutoWatch.state or "not run yet")
    local snap = AutoWatch.snap
    if snap and snap.avail and snap.contents then
        lines[#lines + 1] = string.format("  Quests section: %d watched, %d drawn; room %.0f px (Blizzard's height), used %.0f%s",
            inSection, snap.nDrawn, snap.avail, snap.contents,
            snap.skipped and ("; did not fit: " .. (snap.failed and QuestLabel(snap.failed) or "a block")) or "")
    end
    local plan = AutoWatch.plan
    if plan and db.autoWatch then
        local line = string.format("  fit: %d quests (limit %d)", plan.count, plan.cap)
        if plan.nextCost and plan.avail then
            line = line .. string.format("; next in line needs ~%.0f px, %.0f px free", plan.nextCost, plan.avail - plan.used)
        end
        lines[#lines + 1] = line
    end
    local last = AutoWatch.last
    if last then
        local function list(t) return #t > 0 and table.concat(t, ", ") or "none" end
        lines[#lines + 1] = "  last change " .. last.at .. ": watched " .. list(last.added) .. "; un-watched " .. list(last.removed)
            .. (#last.refused > 0 and ("; the client would not watch " .. list(last.refused)) or "")
    elseif db.autoWatch then
        lines[#lines + 1] = "  last change: none this session"
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- Dungeon filter (1.10)
--
-- Off by default (/bqf dungeon on). While the player is inside a dungeon or raid instance
-- (IsInInstance: "party" or "raid"), only the quests that belong to that instance are watched and
-- the other quests of the Quests section are un-watched. A quest belongs to the instance when
--   1. it sits under the quest-log header whose title is the instance's name (GetInstanceInfo,
--      and GetRealZoneText), compared without case, extra spaces or a leading "The ", or
--   2. it is tagged Dungeon or Raid (C_QuestLog.GetQuestTagInfo, else GetQuestTagInfo) and its map
--      (GetQuestUiMapID) is the player's instance map (C_Map.GetBestMapForUnit) or one of that
--      map's parents that is itself an instance map (dungeon, micro or orphan map type; never the
--      zone or continent around it), or its title, description (GetQuestLogQuestText) or
--      objective text (C_QuestLog.GetQuestObjectives) names the instance.
-- Every client function is feature-checked; a missing or secret value is no match.
--
-- Auto-watch on: the filter only narrows the ranking auto-watch walks (Plan's walk): the matching
-- quests in the usual order, as many as fit. Everything else of the section is un-watched by the
-- same Apply, so combat, Edit Mode, the focused quest and the thrash guard work as for auto-watch.
-- Auto-watch off: the filter makes the watch list the matching quests itself (the same Apply, so
-- the same rules) and remembers each change in BetterQuestsForeverDB.dungeonRestore (a /reload
-- inside the instance keeps it). Once the filter no longer applies (the player left, no quest
-- matches any more, the option or the addon was switched off), the quests it un-watched are
-- watched again in their old order and the ones it added are un-watched: the player's own list.
-- No matching quest inside the instance, outside an instance, or the option off: the normal
-- behaviour. Passes run on PLAYER_ENTERING_WORLD, ZONE_CHANGED_NEW_AREA and QUEST_LOG_UPDATE
-- through the same throttle as everything else, and only out of combat.
-- ---------------------------------------------------------------------------

-- A string the client gave that can be used: not secret, not empty.
function Dungeon.Text(v)
    if type(v) == "string" and not IsSecret(v) and v ~= "" then return v end
end

-- A name made comparable: lower case, single spaces, no leading "the ". nil when nothing is left.
function Dungeon.Norm(s)
    s = Dungeon.Text(s)
    if not s then return nil end
    s = s:lower():gsub("%s+", " ")
    s = s:gsub("^ ", ""):gsub(" $", "")
    s = s:gsub("^the ", "")
    if s ~= "" then return s end
end

-- Quest tags that mean "dungeon" or "raid": Enum.QuestTag where the client has it, the classic
-- IDs (Dungeon 81, Heroic 85, Raid 62, Raid10 88, Raid25 89) otherwise, and the tag names.
function Dungeon.Tags()
    if Dungeon.tagIDs then return Dungeon.tagIDs, Dungeon.tagNames end
    local ids = { [81] = true, [85] = true, [62] = true, [88] = true, [89] = true }
    local e = type(_G.Enum) == "table" and _G.Enum.QuestTag
    if type(e) == "table" then
        for _, k in ipairs({ "Dungeon", "Heroic", "Raid", "Raid10", "Raid25" }) do
            local v = Num(e[k])
            if v then ids[v] = true end
        end
    end
    local names = { dungeon = true, raid = true }
    for _, k in ipairs({ "LFG_TYPE_DUNGEON", "LFG_TYPE_RAID", "RAID" }) do
        local s = Dungeon.Text(_G[k])
        if s then names[s:lower()] = true end
    end
    Dungeon.tagIDs, Dungeon.tagNames = ids, names
    return ids, names
end

function Dungeon.IsGroupQuest(questID)
    local tagID, tagName
    local ql = QuestLog()
    local info = ql and pcall1(ql.GetQuestTagInfo, questID)
    if type(info) == "table" and not IsSecret(info) then tagID, tagName = info.tagID, info.tagName end
    if tagID == nil and tagName == nil and type(_G.GetQuestTagInfo) == "function" then
        local ok, a, b = pcall(_G.GetQuestTagInfo, questID)
        if ok and type(a) == "table" and not IsSecret(a) then
            tagID, tagName = a.tagID, a.tagName
        elseif ok then
            tagID, tagName = a, b
        end
    end
    local ids, names = Dungeon.Tags()
    tagID = Num(tagID)
    if tagID and ids[tagID] then return true end
    local name = Dungeon.Text(tagName)
    return name ~= nil and names[name:lower()] == true
end

-- The quest's map, or nil.
function Dungeon.QuestMap(questID)
    local ql = QuestLog()
    local m = Num(ql and pcall1(ql.GetQuestUiMapID, questID))
    if not m then m = Num(pcall1(_G.GetQuestUiMapID, questID)) end
    if m and m > 0 then return m end
end

-- The dungeon or raid instance the player is in: { name, kind, names (normalised name -> true),
-- findNames (those long enough to look for in text), maps (uiMapID -> true) }; nil and why not.
function Dungeon.Instance()
    if type(_G.IsInInstance) ~= "function" then return nil, "IsInInstance is not available" end
    local ok, inside, kind = pcall(_G.IsInInstance)
    if not ok or IsSecret(inside) or IsSecret(kind) or not inside or (kind ~= "party" and kind ~= "raid") then
        return nil, "not in an instance"
    end
    local inst = { kind = kind, names = {}, findNames = {}, maps = {} }
    local function addName(s)
        s = Dungeon.Text(s)
        local n = Dungeon.Norm(s)
        if n and not inst.names[n] then
            inst.names[n] = true
            inst.name = inst.name or s
            if #n >= 4 then inst.findNames[#inst.findNames + 1] = n end
        end
    end
    local okI, name = Try(_G.GetInstanceInfo)
    if okI then addName(name) end
    addName(pcall1(_G.GetRealZoneText))

    local cmap = _G.C_Map
    if type(cmap) == "table" then
        local e = type(_G.Enum) == "table" and _G.Enum.UIMapType
        local instanceTypes = {}
        for k, fallback in pairs({ Dungeon = 4, Micro = 5, Orphan = 6 }) do
            instanceTypes[type(e) == "table" and Num(e[k]) or fallback] = true
        end
        local m = Num(pcall1(cmap.GetBestMapForUnit, "player"))
        for _ = 1, 12 do
            if not m or m <= 0 or inst.maps[m] then break end
            inst.maps[m] = true
            local info = pcall1(cmap.GetMapInfo, m)
            local parent = type(info) == "table" and not IsSecret(info) and Num(info.parentMapID) or nil
            local pinfo = parent and pcall1(cmap.GetMapInfo, parent)
            local ptype = type(pinfo) == "table" and not IsSecret(pinfo) and Num(pinfo.mapType) or nil
            if not ptype or not instanceTypes[ptype] then break end
            m = parent
        end
    end
    if not inst.name and not next(inst.maps) then return nil, "in an instance the client gives no name or map for" end
    inst.name = inst.name or "this instance"
    return inst
end

-- questID -> { index = its quest-log index, header = the title of the header it sits under }.
function Dungeon.LogEntries()
    local ql = QuestLog()
    local entries = {}
    local ok, n = Try(ql and ql.GetNumQuestLogEntries)
    if not ok or type(n) ~= "number" or IsSecret(n) then return entries end
    local header
    for i = 1, n do
        local info = pcall1(ql.GetInfo, i)
        if type(info) == "table" then
            if info.isHeader then
                header = Dungeon.Text(info.title)
            else
                local id = Num(info.questID)
                if id and id > 0 and not entries[id] then entries[id] = { index = i, header = header } end
            end
        end
    end
    return entries
end

-- Does the quest's title, description or objective text name the instance (plain find)?
function Dungeon.NamedInText(inst, d, entry)
    if #inst.findNames == 0 then return false end
    local texts = {}
    local function add(s)
        s = Dungeon.Text(s)
        if s then texts[#texts + 1] = s:lower() end
    end
    add(d.title)
    if entry and type(_G.GetQuestLogQuestText) == "function" then
        local ok, desc, objectives = pcall(_G.GetQuestLogQuestText, entry.index)
        if ok then
            add(desc)
            add(objectives)
        end
    end
    local ql = QuestLog()
    local list = ql and pcall1(ql.GetQuestObjectives, d.id)
    if type(list) == "table" and not IsSecret(list) then
        for _, o in ipairs(list) do
            if type(o) == "table" then add(o.text) end
        end
    end
    for _, text in ipairs(texts) do
        for _, name in ipairs(inst.findNames) do
            if text:find(name, 1, true) then return true end
        end
    end
    return false
end

function Dungeon.Belongs(inst, d, entry)
    local header = entry and Dungeon.Norm(entry.header)
    if header and inst.names[header] then return true end
    if not Dungeon.IsGroupQuest(d.id) then return false end
    local m = Dungeon.QuestMap(d.id)
    if m and inst.maps[m] then return true end
    return Dungeon.NamedInText(inst, d, entry)
end

-- The quests of pool (in pool's order) that belong to inst.
function Dungeon.MatchIn(inst, pool)
    local entries = Dungeon.LogEntries()
    local list = {}
    for _, d in ipairs(pool) do
        if Dungeon.Belongs(inst, d, entries[d.id]) then list[#list + 1] = d end
    end
    return list
end

-- The ranking auto-watch walks: the matching quests, or nil when the filter does not apply now
-- (option off, not in a dungeon or raid, or no quest of the pool matches).
function Dungeon.Walk(pool)
    if not (db and db.enabled and db.dungeonFilter) then return nil end
    local inst = Dungeon.Instance()
    if not inst then return nil end
    local list = Dungeon.MatchIn(inst, pool)
    if #list > 0 then return list end
end

-- BetterQuestsForeverDB.dungeonRestore = { removed = { questID, ... }, added = { questID, ... } }:
-- what the filter changed while auto-watch was off, in the order it happened. Cleaned on load and
-- after every change; nil when there is nothing to undo.
function Dungeon.CleanRestore()
    local r = db.dungeonRestore
    if type(r) ~= "table" then
        db.dungeonRestore = nil
        return
    end
    local clean = {}
    for _, k in ipairs({ "removed", "added" }) do
        local list, seen = {}, {}
        if type(r[k]) == "table" then
            for _, id in ipairs(r[k]) do
                if type(id) == "number" and id > 0 and not seen[id] then
                    seen[id] = true
                    list[#list + 1] = id
                end
            end
        end
        clean[k] = list
    end
    db.dungeonRestore = (#clean.removed > 0 or #clean.added > 0) and clean or nil
end

function Dungeon.PendingRestore()
    local r = db and db.dungeonRestore
    if type(r) ~= "table" then return 0 end
    return (type(r.removed) == "table" and #r.removed or 0) + (type(r.added) == "table" and #r.added or 0)
end

-- kind "removed" or "added". Undoing the opposite change cancels it out.
function Dungeon.Remember(kind, questID)
    local r = db.dungeonRestore
    if type(r) ~= "table" then
        r = { removed = {}, added = {} }
        db.dungeonRestore = r
    end
    local own = r[kind]
    local other = kind == "removed" and r.added or r.removed
    for i, id in ipairs(other) do
        if id == questID then
            table.remove(other, i)
            return
        end
    end
    for _, id in ipairs(own) do
        if id == questID then return end
    end
    own[#own + 1] = questID
end

-- The filter no longer applies: undo what it changed. At most MAX_CHANGES per pass; the rest on
-- the next one. Returns the state for /bqf status.
function Dungeon.Restore(now)
    local r = db.dungeonRestore
    if type(r) ~= "table" then return nil end
    local ql = QuestLog()
    -- Right after login the quest log can still be empty: nothing is dropped until it is read.
    local ok, n = Try(ql.GetNumQuestLogEntries)
    if not ok or type(n) ~= "number" or IsSecret(n) or n <= 0 then return "waiting for the quest log to restore your watch list" end
    local watched, count = {}, 0
    for _, id in ipairs(GetWatches()) do
        watched[id] = true
        count = count + 1
    end
    local done, keepAdded, keepRemoved = 0, {}, {}
    for _, id in ipairs(r.added or {}) do
        if done >= AutoWatch.MAX_CHANGES then
            keepAdded[#keepAdded + 1] = id
        elseif watched[id] then
            Try(ql.RemoveQuestWatch, id)
            watched[id] = nil
            count = count - 1
            done = done + 1
        end
    end
    local cap = AutoWatch.Cap()
    for _, id in ipairs(r.removed or {}) do
        local okI, index = Try(ql.GetLogIndexForQuestID, id)
        local inLog = okI and Num(index) ~= nil
        if done >= AutoWatch.MAX_CHANGES then
            keepRemoved[#keepRemoved + 1] = id
        elseif inLog and not watched[id] and count < cap then
            AutoWatch.AddWatch(id)
            watched[id] = true
            count = count + 1
            done = done + 1
        end
    end
    r.added, r.removed = keepAdded, keepRemoved
    Dungeon.CleanRestore()
    if done > 0 then
        AutoWatch.changeSeq = AutoWatch.changeSeq + 1
        AutoWatch.changedAt = now
        Dungeon.lastRestore = (type(_G.date) == "function" and _G.date("%H:%M:%S") or "") .. ", " .. done .. " watch changes"
        if db.dungeonRestore and type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" and AutoWatch.Schedule then
            pcall(_G.C_Timer.After, AutoWatch.SETTLE + 0.1, AutoWatch.Schedule)
        end
    end
    return db.dungeonRestore and "restoring your watch list" or "restored your watch list"
end

-- The pass for auto-watch off (with auto-watch on, AutoWatch.Run does the filtering through
-- Walk). Called from Evaluate on the throttle frame, like AutoWatch.Run.
function Dungeon.Run()
    local function state(s) Dungeon.state = s end
    if not db then return end
    if db.enabled and db.autoWatch then
        -- Auto-watch owns the watch list; there is no list of the player's to give back.
        db.dungeonRestore = nil
        return state(nil)
    end
    if not db.dungeonFilter and not db.dungeonRestore then return state(nil) end
    if InCombat() then return state("waiting for the end of combat") end
    if AutoWatch.IsEditMode() then return state("paused while Edit Mode is open") end
    local missing = AutoWatch.MissingApi()
    if missing then return state("not available - " .. missing .. " missing") end
    local now = AutoWatch.Now()
    if AutoWatch.pausedUntil then
        if now < AutoWatch.pausedUntil then
            return state(string.format("paused for %d s more: the watch list kept changing", AutoWatch.pausedUntil - now))
        end
        AutoWatch.pausedUntil = nil
        AutoWatch.passTimes = {}
    end

    local pool = (db.enabled and db.dungeonFilter) and AutoWatch.Pool() or {}
    local walk = #pool > 0 and Dungeon.Walk(pool) or nil
    if not walk then return state(Dungeon.Restore(now)) end

    local before = GetWatches()
    local watched = {}
    for _, id in ipairs(before) do watched[id] = true end
    local inPool, others = {}, 0
    for _, d in ipairs(pool) do inPool[d.id] = true end
    for id in pairs(watched) do
        if not inPool[id] then others = others + 1 end
    end
    local cap = math.max(AutoWatch.Cap() - others, 1)
    local target, count = {}, 0
    local focused = AutoWatch.Focused()
    if focused and inPool[focused] and watched[focused] then
        target[focused] = true
        count = 1
    end
    for _, d in ipairs(walk) do
        if count >= cap then break end
        if not target[d.id] then
            target[d.id] = true
            count = count + 1
        end
    end
    if AutoWatch.Apply(pool, target, watched, now) then
        local after = {}
        for _, id in ipairs(GetWatches()) do after[id] = true end
        for _, id in ipairs(before) do
            if inPool[id] and not after[id] then Dungeon.Remember("removed", id) end
        end
        for _, d in ipairs(pool) do
            if after[d.id] and not watched[d.id] then Dungeon.Remember("added", d.id) end
        end
        Dungeon.CleanRestore()
        return state("changed the watch list to the instance's quests")
    end
    state(AutoWatch.pausedUntil and "paused: the watch list kept changing" or "settled")
end

-- The quests of the Quests section in the quest log, in level order (for /bqf status; read-only,
-- so the distance ranking's memory is not touched).
function Dungeon.QuestsInLog()
    local list = {}
    for id in pairs(Dungeon.LogEntries()) do
        local d = QuestData(id)
        if d.inLog and d.inQuestsSection then list[#list + 1] = d end
    end
    table.sort(list, Compare)
    return list
end

function Dungeon.StatusLines()
    local lines = {}
    local pending = Dungeon.PendingRestore()
    local tail = pending > 0 and string.format("; %d watch change%s to undo when the filter stops", pending,
        pending == 1 and "" or "s") or ""
    local line
    if not db.dungeonFilter then
        line = "dungeon filter: off"
    elseif not db.enabled then
        line = "dungeon filter: on - BetterQuestsForever is off"
    else
        local inst, why = Dungeon.Instance()
        if not inst then
            line = "dungeon filter: on - " .. why
        else
            local list = Dungeon.MatchIn(inst, Dungeon.QuestsInLog())
            if #list == 0 then
                line = "dungeon filter: on - in " .. inst.name .. ", no match, normal sort"
            else
                line = string.format("dungeon filter: on - in %s, %d quest%s match", inst.name, #list, #list == 1 and "" or "s")
                local labels = {}
                for _, d in ipairs(list) do labels[#labels + 1] = QuestLabel(d) end
                lines[2] = "  matching: " .. table.concat(labels, ", ")
            end
        end
    end
    lines[1] = line .. tail .. (Dungeon.state and (" - " .. Dungeon.state) or "")
    if Dungeon.lastRestore then lines[#lines + 1] = "  last restore of your watch list: " .. Dungeon.lastRestore end
    local ql = QuestLog()
    lines[#lines + 1] = "  IsInInstance: " .. (type(_G.IsInInstance) == "function" and "yes" or "MISSING")
        .. "   GetInstanceInfo: " .. (type(_G.GetInstanceInfo) == "function" and "yes" or "MISSING")
        .. "   quest tags: " .. ((ql and type(ql.GetQuestTagInfo) == "function") and "C_QuestLog.GetQuestTagInfo"
            or type(_G.GetQuestTagInfo) == "function" and "GetQuestTagInfo" or "MISSING")
        .. "   quest map: " .. ((ql and type(ql.GetQuestUiMapID) == "function") and "C_QuestLog.GetQuestUiMapID"
            or type(_G.GetQuestUiMapID) == "function" and "GetQuestUiMapID" or "MISSING")
        .. "   GetQuestLogQuestText: " .. (type(_G.GetQuestLogQuestText) == "function" and "yes" or "MISSING")
    return lines
end

local function HookTracker()
    if hooked then return true end
    if type(_G.hooksecurefunc) ~= "function" then
        trackerProblem = "hooksecurefunc not found"
        return false
    end
    if not RecogniseTracker() then return false end
    -- Instance hooks only: the Campaign section and every other module keep their own methods.
    -- Update gets the room the container gives the section (its availableHeight argument); auto-watch
    -- reads it, with the result of Blizzard's layout, before the order is applied.
    hooksecurefunc(tracker, "Update", function(_, availableHeight)
        pcall(AutoWatch.Observe, availableHeight)
        OnTrackerLaidOut()
    end)
    hooksecurefunc(tracker, "UpdateHeight", OnTrackerLaidOut)
    hooked = true
    return true
end

-- ---------------------------------------------------------------------------
-- Evaluation
-- ---------------------------------------------------------------------------

-- runWatch: also run an auto-watch pass. Only the throttle frame passes it, so the watch list is
-- only ever changed from this addon's own OnUpdate.
local function Evaluate(runWatch)
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
    if runWatch then
        -- The dungeon filter's own pass first (it acts only with auto-watch off), then auto-watch
        -- (which applies the filter itself when it is on).
        local okD, errD = pcall(Dungeon.Run)
        if not okD then Dungeon.state = "error: " .. tostring(errD) end
        local ok, err = pcall(AutoWatch.Run)
        if not ok then AutoWatch.state = "error: " .. tostring(err) end
    end
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
    -- Auto-watch ranks the whole quest log by distance; its pass decides whether anything changes.
    if db.autoWatch and AutoWatch.Schedule then AutoWatch.Schedule() end
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
    if SortMode() ~= "distance" or not (db and db.enabled) then prevOrder, AutoWatch.prevOrder = nil, nil end
end

local throttle = CreateFrame("Frame")
throttle:Hide()
local throttleLeft = 0
throttle:SetScript("OnUpdate", function(self, elapsed)
    throttleLeft = throttleLeft - (elapsed or 0)
    if throttleLeft <= 0 then
        self:Hide()
        Evaluate(true)
    end
end)

local function Schedule()
    if not db then return end
    pending = true
    if InCombat() then return end
    throttleLeft = THROTTLE
    throttle:Show()
end

AutoWatch.Schedule = Schedule

-- A settings change: the order and the limit at once, the auto-watch pass from the throttle
-- frame a moment later; both after combat when in one.
local function ApplyNow()
    if not db then return end
    if InCombat() then
        pending = true
        return
    end
    Evaluate()
    Schedule()
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
    prevOrder, AutoWatch.prevOrder = nil, nil
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

local function SetAutoWatch(on)
    db.autoWatch = on and true or false
    if on then
        Print("auto-watch on: the lowest quests that fit the tracker are watched, the rest un-watched."
            .. (InCombat() and " Applied after combat." or ""))
        ApplyNow()
    else
        -- Nothing is restored: the watch list stays as it is and is the player's again.
        AutoWatch.state = "off - the watch list is yours (/bqf autowatch on)"
        Print("auto-watch off: the watch list is yours again; it is left as it is.")
    end
end

local function SetDungeonFilter(on)
    db.dungeonFilter = on and true or false
    if on then
        Print("dungeon filter on: inside a dungeon or raid only its quests are watched; no matching quest, the normal sort."
            .. (InCombat() and " Applied after combat." or ""))
    else
        Print("dungeon filter off." .. (Dungeon.PendingRestore() > 0
            and " The quests it un-watched are watched again." or "")
            .. (InCombat() and " Applied after combat." or ""))
    end
    ApplyNow()
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

local SaveMinimapHidden -- defined below; the menu's "Hide" entry calls it

-- The options as data, shared by Blizzard's menu, the fallback menu and BetterQuestsForeverAPI
-- (which BetterForever's hub menu reads), so there is one list to keep up to date.
local function OptionEntries()
    local list = {
        { text = "Enabled", checkbox = true, checked = function() return db.enabled end,
          func = function() SetEnabled(not db.enabled) end },
        { text = "Auto-watch quests that fit", checkbox = true, checked = function() return db.autoWatch end,
          func = function() SetAutoWatch(not db.autoWatch) end },
        { text = "Dungeon filter", checkbox = true, checked = function() return db.dungeonFilter end,
          func = function() SetDungeonFilter(not db.dungeonFilter) end },
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
    return list
end

-- This addon's own minimap menu: the options, then the entry for its own button.
local function MenuEntries()
    local list = OptionEntries()
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Hide minimap button", func = function() SaveMinimapHidden(true) end }
    return list
end

-- Draws the entries into a MenuUtil description (root or submenu).
local function RenderMenu(root, entries)
    for _, e in ipairs(entries) do
        if e.divider then
            if type(root.CreateDivider) == "function" then root:CreateDivider() end
        elseif e.submenu then
            local sub = root:CreateButton(e.text)
            if type(sub) == "table" then RenderMenu(sub, e.submenu) end
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
            RenderMenu(root, entries)
        end)
        if ok then return "MenuUtil" end
    end
    ShowCustomMenu(owner, entries)
    return "custom"
end

-- ---------------------------------------------------------------------------
-- Right-click on the tracker headers
--
-- Right-clicking the objective tracker's "All Objectives" header (ObjectiveTrackerFrame.Header) or
-- the "Quests" header (QuestObjectiveTracker.Header) opens the same options as the minimap menu.
-- Blizzard's headers are plain Frames that do not take mouse input (only their MinimizeButton
-- does, and that keeps its left-click collapse), so a Blizzard script cannot be hooked and none is
-- replaced. Instead this addon parents its own transparent, mouse-enabled frame to each header,
-- stopping short of the MinimizeButton. Nothing on a Blizzard frame is written; the overlay is
-- not protected and the menu changes only this addon's settings, so it works in combat too.
-- ---------------------------------------------------------------------------

local headerOverlays = {} -- header frame -> our overlay

local function ShowHeaderMenu(owner)
    if not db then return end
    local entries = OptionEntries()
    local MU = _G.MenuUtil
    if type(MU) == "table" and type(MU.CreateContextMenu) == "function" then
        local ok = pcall(MU.CreateContextMenu, owner, function(_, root)
            if type(root.CreateTitle) == "function" then root:CreateTitle(TITLE) end
            RenderMenu(root, entries)
        end)
        if ok then return end
    end
    ShowCustomMenu(owner, entries)
end

local function HookHeader(header)
    if type(header) ~= "table" or type(header.CreateTexture) ~= "function" or headerOverlays[header] then return end
    local ok, o = pcall(CreateFrame, "Frame", nil, header)
    if not ok or type(o) ~= "table" then return end
    o:SetAllPoints(header)
    local mb = header.MinimizeButton
    if type(mb) == "table" and type(mb.GetLeft) == "function" then
        o:ClearAllPoints()
        o:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
        o:SetPoint("BOTTOMRIGHT", mb, "BOTTOMLEFT", 0, 0)
    end
    o:EnableMouse(true)
    o:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then ShowHeaderMenu(self) end
    end)
    headerOverlays[header] = o
end

-- Idempotent; called again when the tracker loads late or a header did not exist yet.
local function HookTrackerHeaders()
    local otf = _G.ObjectiveTrackerFrame
    if type(otf) == "table" then HookHeader(otf.Header) end
    local q = _G.QuestObjectiveTracker
    if type(q) == "table" then HookHeader(q.Header) end
end

local function StateLine()
    if not db then return "not loaded yet" end
    return (db.enabled and "On" or "Off") .. " \194\183 " .. SortMode() .. " \194\183 max " .. MaxLabel(db.max)
        .. " \194\183 completed: " .. db.completed
        .. (db.autoWatch and " \194\183 auto-watch" or "")
        .. (db.dungeonFilter and " \194\183 dungeon filter" or "")
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

-- Whether an addon is loaded: C_AddOns on newer clients, the old global otherwise.
local function AddOnLoaded(name)
    local c = _G.C_AddOns
    if type(c) == "table" and type(c.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(c.IsAddOnLoaded, name)
        if ok and loaded then return true end
    end
    if type(_G.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(_G.IsAddOnLoaded, name)
        if ok and loaded then return true end
    end
    return false
end

-- Hidden for this session only, never saved: true while BetterForever's button holds these
-- options. nil until the hub says so (SetMinimapHidden) or is found loaded at the next apply.
local hubHidden

local function HiddenByHub()
    if hubHidden == nil and (AddOnLoaded("BetterForever") or AddOnLoaded("BetterGaarForever")) then hubHidden = true end
    return hubHidden == true
end

local function ApplyMinimap()
    if not db then return end
    if MinimapDB().hide or HiddenByHub() then
        if minimapButton then minimapButton:Hide() end
        if customMenu then customMenu:Hide() end
        return
    end
    if BuildMinimapButton() then
        PlaceMinimapButton()
        minimapButton:Show()
    end
end

-- The player's own choice, saved in BetterQuestsForeverDB.minimap.hide.
SaveMinimapHidden = function(hide)
    MinimapDB().hide = hide and true or false
    ApplyMinimap()
    if hide then
        Print("minimap button hidden. Type |cffffd100/bqf minimap|r to show it again.")
    elseif HiddenByHub() then
        Print("minimap button set to shown; it stays hidden while BetterForever is loaded, whose button has these options.")
    else
        Print("minimap button shown.")
    end
end

local function ResetMinimapButton()
    local m = MinimapDB()
    m.angle = MINIMAP_DEFAULT_ANGLE
    m.hide = false
    ApplyMinimap()
    Print("minimap button reset to its default position."
        .. (HiddenByHub() and " It stays hidden while BetterForever is loaded." or ""))
end

-- ---------------------------------------------------------------------------
-- "Set GPS target" in the quest tracker's right-click menu
--
-- Blizzard builds that menu in QuestObjectiveTrackerMixin:OnBlockHeaderClick with the tag
-- MENU_QUEST_OBJECTIVE_TRACKER (the Campaign section uses the same mixin and tag). Menu.ModifyMenu
-- is Blizzard's public way for an addon to add to a tagged menu: our callback runs after
-- Blizzard's generator, and only adds an element of our own. The menu does not say which quest it
-- is for, so the quest is the tracker block under the mouse (the right-click that opened it),
-- checked against the menu's title, or else the one tracked quest with that title.
-- ---------------------------------------------------------------------------

local GPS_ADDON = "BetterGpsForever"
local GPS_MENU_TAG = "MENU_QUEST_OBJECTIVE_TRACKER"
local GPS_TEXT = "Set GPS target"
local gpsMenuState      -- "registered", or why the entry cannot be offered; for /bqf status
local gpsMenuBroken     -- switched off for the session after its first error

-- BetterGpsForeverAPI when BetterGpsForever is loaded and can take a waypoint from us (1.1+).
local function GpsApi()
    if not AddOnLoaded(GPS_ADDON) then return nil end
    local api = _G.BetterGpsForeverAPI
    if type(api) == "table" and type(api.SetWaypoint) == "function" then return api end
end

local function MapNum(v)
    v = Num(v)
    if v and v > 0 then return v end
end

-- A map point from the client, 0-1 and not the empty 0,0, or nothing.
local function Point01(x, y)
    x, y = Num(x), Num(y)
    if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 and not (x == 0 and y == 0) then return x, y end
end

local function MapChain(mapID)
    local chain, seen = {}, {}
    local getInfo = type(_G.C_Map) == "table" and _G.C_Map.GetMapInfo
    local m = MapNum(mapID)
    for _ = 1, 12 do
        if not m or seen[m] then break end
        seen[m] = true
        chain[#chain + 1] = m
        local info = pcall1(getInfo, m)
        m = type(info) == "table" and not IsSecret(info) and MapNum(info.parentMapID) or nil
    end
    return chain
end

-- The maps to look on: the quest's own map, the player's map, then the parents of each.
local function QuestMaps(questID)
    local q = MapChain(pcall1(_G.GetQuestUiMapID, questID))
    local p = MapChain(pcall1(type(_G.C_Map) == "table" and _G.C_Map.GetBestMapForUnit, "player"))
    local list, seen = {}, {}
    local function add(m)
        if m and not seen[m] then
            seen[m] = true
            list[#list + 1] = m
        end
    end
    add(q[1])
    add(p[1])
    for i = 2, #q do add(q[i]) end
    for i = 2, #p do add(p[i]) end
    return list
end

-- Blizzard's point for a quest as uiMapID, x, y (0-1), or nothing:
--   1. C_QuestLog.GetNextWaypoint: the next step of the route Blizzard plots to a quest elsewhere
--   2. the quest's POI in C_QuestLog.GetQuestsOnMap: the objective area, or the turn-in point
--      once the quest is complete
--   3. C_QuestLog.GetNextWaypointForMap on the same maps
local function QuestPoint(questID)
    local ql = QuestLog()
    if not ql or type(questID) ~= "number" then return nil end
    local ok, m, x, y = Try(ql.GetNextWaypoint, questID)
    if ok then
        m = MapNum(m)
        x, y = Point01(x, y)
        if m and x then return m, x, y end
    end
    local maps = QuestMaps(questID)
    if type(ql.GetQuestsOnMap) == "function" then
        for _, mapID in ipairs(maps) do
            local quests = pcall1(ql.GetQuestsOnMap, mapID)
            if type(quests) == "table" and not IsSecret(quests) then
                for _, info in ipairs(quests) do
                    if type(info) == "table" and Num(info.questID) == questID then
                        local px, py = Point01(info.x, info.y)
                        if px then return mapID, px, py end
                    end
                end
            end
        end
    end
    if type(ql.GetNextWaypointForMap) == "function" then
        for _, mapID in ipairs(maps) do
            local okW, wx, wy = Try(ql.GetNextWaypointForMap, questID, mapID)
            if okW then
                wx, wy = Point01(wx, wy)
                if wx then return mapID, wx, wy end
            end
        end
    end
end

local function QuestTitle(questID)
    local ql = QuestLog()
    local t = ql and pcall1(ql.GetTitleForQuestID, questID)
    if type(t) == "string" and not IsSecret(t) and t ~= "" then return t end
    t = QuestData(questID).title
    if t ~= "" then return t end
end

local function ElementText(desc)
    local MU = _G.MenuUtil
    local t
    if type(MU) == "table" and type(MU.GetElementText) == "function" then t = pcall1(MU.GetElementText, desc) end
    if type(t) == "string" and not IsSecret(t) then return t end
end

local function MouseFrames()
    local foci = pcall1(_G.GetMouseFoci)
    if type(foci) == "table" then return foci end
    local f = pcall1(_G.GetMouseFocus)
    return f and { f } or {}
end

-- The quest of the tracker block a frame belongs to (the block itself, or its header button).
local function BlockQuestID(frame)
    for _ = 1, 4 do
        if type(frame) ~= "table" then return nil end
        local id = frame.id
        if type(frame.parentModule) == "table" and type(id) == "number" and not IsSecret(id) and id > 0 then
            return id
        end
        frame = type(frame.GetParent) == "function" and pcall1(frame.GetParent, frame) or nil
    end
end

local function MenuQuestID(title)
    for _, f in ipairs(MouseFrames()) do
        local id = BlockQuestID(f)
        if id and (not title or QuestTitle(id) == title) then return id end
    end
    if not title then return nil end
    local found
    for _, questID in ipairs(GetWatches()) do
        if QuestTitle(questID) == title then
            if found then return nil end -- two tracked quests with this title: not guessed
            found = questID
        end
    end
    return found
end

local function SetGpsTarget(questID, title)
    local api = GpsApi()
    local m, x, y = QuestPoint(questID)
    if not api or not m then
        Print("No map point for this quest.")
        return
    end
    local ok, set = pcall(api.SetWaypoint, m, x, y, title)
    if not ok or not set then Print("BetterGpsForever could not take that point.") end
end

-- Our ModifyMenu callback: adds the entry after Focus (Blizzard's SUPER_TRACK_QUEST or
-- STOP_SUPER_TRACK_QUEST), or third (after the title and Focus) when Focus is not found.
local function AddGpsEntry(root)
    if not GpsApi() or type(root) ~= "table" or type(root.EnumerateElementDescriptions) ~= "function" then return end
    local title, count, focusAt = nil, 0, nil
    local focusTexts = {}
    for _, name in ipairs({ "SUPER_TRACK_QUEST", "STOP_SUPER_TRACK_QUEST" }) do
        if type(_G[name]) == "string" then focusTexts[_G[name]] = true end
    end
    for i, desc in root:EnumerateElementDescriptions() do
        count = i
        local text = ElementText(desc)
        if i == 1 then title = text end
        if text and focusTexts[text] and not focusAt then focusAt = i end
    end
    local questID = MenuQuestID(title)
    if not questID then return end
    local name = QuestTitle(questID) or title
    local hasPoint = QuestPoint(questID) ~= nil
    local function onClick() SetGpsTarget(questID, name) end

    local MU, desc = _G.MenuUtil, nil
    if type(MU) == "table" and type(MU.CreateButton) == "function" and type(root.Insert) == "function" then
        local index = focusAt and (focusAt + 1) or math.min(3, count + 1)
        desc = root:Insert(MU.CreateButton(GPS_TEXT, onClick), index)
    elseif type(root.CreateButton) == "function" then
        desc = root:CreateButton(GPS_TEXT, onClick)
    end
    if not hasPoint and type(desc) == "table" and type(desc.SetEnabled) == "function" then
        desc:SetEnabled(false)
    end
end

local function RegisterGpsMenu()
    if gpsMenuState == "registered" then return end
    local menu = _G.Menu
    if type(menu) ~= "table" or type(menu.ModifyMenu) ~= "function" then
        gpsMenuState = "Menu.ModifyMenu not available"
        return
    end
    local ok, err = pcall(menu.ModifyMenu, GPS_MENU_TAG, function(_, root)
        if gpsMenuBroken then return end
        local okAdd, errAdd = pcall(AddGpsEntry, root)
        if not okAdd then
            gpsMenuBroken = true
            Print("\"" .. GPS_TEXT .. "\" is switched off for this session: this client refused it. ("
                .. tostring(errAdd) .. ")")
        end
    end)
    gpsMenuState = ok and "registered" or ("error: " .. tostring(err))
end

local function GpsMenuStatus()
    if gpsMenuBroken then return "switched off after an error" end
    if gpsMenuState ~= "registered" then return "not available - " .. (gpsMenuState or "not set up yet") end
    if not AddOnLoaded(GPS_ADDON) then return "hidden - BetterGpsForever is not loaded" end
    if not GpsApi() then return "hidden - BetterGpsForever 1.1 or later is needed" end
    return "in the tracker's quest menu, after Focus"
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

-- The intro BetterForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "Orders the Quests section of the objective tracker by level or distance, shows at most N quests and auto-watches the lowest ones that fit. Nice to know: right-click the tracker's Quests header for the same options; inside a dungeon the dungeon filter watches only its quests; the tracker can hide in combat (/bqf combat on)."

local function PrintHelp()
    Print(INTRO)
    Print("/bqf sort level | distance - order by quest level or by how near the quest is (now: "
        .. (db and db.sort or DEFAULTS.sort) .. ")")
    Print("/bqf max <n> | all - show at most n quests, 1-" .. (MAX_MAX - 1) .. ", or all (now: "
        .. MaxLabel(db and db.max or DEFAULTS.max) .. ")")
    Print("/bqf completed top | level | bottom - where quests ready to turn in go (now: "
        .. (db and db.completed or DEFAULTS.completed) .. ")")
    Print("/bqf autowatch on | off - watch the lowest quests that fit the tracker's height and un-watch the rest (now: "
        .. ((db and db.autoWatch or not db and DEFAULTS.autoWatch) and "on" or "off") .. ")")
    Print("/bqf dungeon on | off - inside a dungeon or raid, watch only that instance's quests (now: "
        .. ((db and db.dungeonFilter) and "on" or "off") .. ")")
    Print("/bqf on | off - switch the addon on or off; off is Blizzard's own tracker (now: "
        .. ((db and db.enabled) and "on" or "off") .. ")")
    Print("/bqf bg on | off | <0-100> - dark backdrop behind the tracker, on/off or its opacity in percent (now: "
        .. (db and (BackdropDB().enabled and (AlphaPercent() .. "%") or "off") or "?") .. ")")
    Print("/bqf combat on | off - hide the whole objective tracker during combat (now: "
        .. ((db and db.hideInCombat or not db and DEFAULTS.hideInCombat) and "on" or "off") .. ")")
    Print("Right-click the tracker's \"All Objectives\" or \"Quests\" header for the same settings menu.")
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
    Print("hooks: " .. (hooked and "hooksecurefunc on QuestObjectiveTracker Update + UpdateHeight" or "none")
        .. "   Edit Mode: " .. (AutoWatch.editModeHook or "not followed"))
    for _, line in ipairs(AutoWatch.StatusLines(inSection)) do Print(line) end
    local okD, dungeonLines = pcall(Dungeon.StatusLines)
    if okD then
        for _, line in ipairs(dungeonLines) do Print(line) end
    else
        Print("dungeon filter: " .. (db.dungeonFilter and "on" or "off") .. " - error: " .. tostring(dungeonLines))
    end
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
    Print("height: Blizzard's own (Edit Mode Height); the addon never resizes the tracker"
        .. (heightSet and " - the Quests section is shorter while the limit hides quests" or ""))
    Print("C_QuestLog (GetNumQuestWatches, GetQuestIDForQuestWatchIndex, GetLogIndexForQuestID, GetInfo): "
        .. Yes(not MissingQuestApi()) .. "   IsComplete: " .. Yes(ql and type(ql.IsComplete) == "function"))
    local qis = _G.C_QuestInfoSystem
    Print("C_QuestInfoSystem.GetQuestClassification: " .. Yes(type(qis) == "table"
        and type(qis.GetQuestClassification) == "function")
        .. "   MenuUtil: " .. (type(_G.MenuUtil) == "table" and "yes" or "no (own menu)"))
    local m = MinimapDB()
    local state = m.hide and "hidden (/bqf minimap shows it)" or string.format("shown at %d degrees", m.angle)
    if HiddenByHub() then state = "hidden while BetterForever is loaded (saved setting: " .. state .. ")" end
    Print("minimap button: " .. state .. (type(_G.Minimap) ~= "table" and " - no Minimap frame on this client" or ""))
    Print("Set GPS target: " .. GpsMenuStatus() .. "   GetNextWaypoint: " .. Yes(ql and type(ql.GetNextWaypoint) == "function")
        .. "   GetQuestsOnMap: " .. Yes(ql and type(ql.GetQuestsOnMap) == "function")
        .. "   GetQuestUiMapID: " .. Yes(type(_G.GetQuestUiMapID) == "function"))
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
    elseif msg == "autowatch on" then
        SetAutoWatch(true)
    elseif msg == "autowatch off" then
        SetAutoWatch(false)
    elseif msg == "autowatch" or msg:match("^autowatch ") then
        Print("use /bqf autowatch on or off (now: " .. (db.autoWatch and "on" or "off") .. ").")
    elseif msg == "dungeon on" then
        SetDungeonFilter(true)
    elseif msg == "dungeon off" then
        SetDungeonFilter(false)
    elseif msg == "dungeon" or msg:match("^dungeon ") then
        Print("use /bqf dungeon on or off (now: " .. (db.dungeonFilter and "on" or "off") .. ").")
    elseif msg == "combat on" then
        SetHideInCombat(true)
    elseif msg == "combat off" then
        SetHideInCombat(false)
    elseif msg == "combat" or msg:match("^combat ") then
        Print("use /bqf combat on or off (now: " .. (db.hideInCombat and "on" or "off") .. ").")
    elseif msg == "minimap" then
        SaveMinimapHidden(not MinimapDB().hide)
    elseif msg == "minimap reset" then
        ResetMinimapButton()
    elseif msg == "status" then
        PrintStatus()
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterQuestsForeverAPI
--
-- For BetterForever, the family hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterQuestsForeverDB and change only through the
-- same functions /bqf and this addon's own menu use.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state (the minimap button's tooltip line)
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox|radio = true, checked, func },
--                        { text, submenu = { ... } } and { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  hides (true) or shows again (false) this addon's own minimap button for
--                        this session; BetterQuestsForeverDB.minimap.hide is never changed
-- The "Hide minimap button" entry of this addon's own menu is not part of the API's entries.
-- ---------------------------------------------------------------------------

local VERSION = "1.10.1"

local function ApiEntries()
    if not db then return {} end
    return OptionEntries()
end

_G.BetterQuestsForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StateLine,
    MenuEntries = ApiEntries,
    AddMenuEntries = function(root)
        if type(root) == "table" then RenderMenu(root, ApiEntries()) end
    end,
    SetMinimapHidden = function(hidden)
        hubHidden = hidden and true or false
        if db then pcall(ApplyMinimap) end
    end,
}

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
    if type(db.autoWatch) ~= "boolean" then db.autoWatch = DEFAULTS.autoWatch end
    if type(db.dungeonFilter) ~= "boolean" then db.dungeonFilter = DEFAULTS.dungeonFilter end
    Dungeon.CleanRestore()
    MinimapDB()
    BackdropDB()
end

local events = CreateFrame("Frame")
-- RegisterEvent raises on an event the client does not know, so each one is tried on its own.
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED", "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED", "QUEST_ACCEPTED", "QUEST_REMOVED",
    "QUEST_TURNED_IN", "PLAYER_LEVEL_UP", "EDIT_MODE_LAYOUTS_UPDATED", "SUPER_TRACKING_CHANGED",
    "ZONE_CHANGED_NEW_AREA" }) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            BindSavedVariables()
            UpdateDistanceTicker()
            pcall(ApplyMinimap)
            pcall(HookBackdropTargets)
            pcall(HookTrackerHeaders)
            pcall(RegisterGpsMenu)
            pcall(AutoWatch.HookEditMode)
            MarkBackdrop()
            Schedule()
        elseif db and arg1 == "Blizzard_ObjectiveTracker" then
            pcall(HookTrackerHeaders)
            if not hooked then Schedule() end
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
        if db then pcall(RegisterGpsMenu) end
        if db then pcall(HookTrackerHeaders) end
        pcall(AutoWatch.HookEditMode)
        Schedule()
    else
        Schedule()
    end
end)

SLASH_BETTERQUESTSFOREVER1 = "/bqf"
SLASH_BETTERQUESTSFOREVER2 = "/betterquestsforever"
SlashCmdList.BETTERQUESTSFOREVER = OnSlash
