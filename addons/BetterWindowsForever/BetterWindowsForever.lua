--[[
  BetterWindowsForever - move and scale Blizzard's own windows on WoW Forever.

  It changes these things about Blizzard's windows (Character, Spellbook & Talents, Professions,
  Collections, Group Finder, Social, Guild & Communities, Achievements, Encounter Journal,
  Merchant, Gossip, Quest, Mail, Bank, Auction House, Class Trainer, Loot, Dressing Room, Macros,
  Settings, AddOn List, Inspect, Trade, Game Menu and more) and nothing else:

    * Move: drag a window by its title bar. An invisible handle sits over the title strip (or the
      top edge when the window has no title strip) and stops short of the close and maximize
      buttons, so clicks and item drags inside the window still work. The position is saved per
      window, account-wide, in BetterWindowsForeverDB, and put back every time the window opens
      and every time Blizzard's panel layout re-anchors it. It is kept on screen.
    * Scale: Ctrl + mouse wheel over a window, 50% to 150% in 5% steps. The top-left corner stays
      where it is. Saved per window.
    * On/off per window (all on by default). Off gives the window back to Blizzard: its anchor
      and its scale are put back and the addon does not touch it again.
    * Reset per window or all: Blizzard's position and 100% scale.
    * Load-on-demand windows (Blizzard_Collections, Blizzard_AchievementUI, ...) are picked up at
      ADDON_LOADED. A window this client does not have is listed as such and left out of the menu.
    * /bwf for help, list, on <name>, off <name>, reset <name>|all and status.
    * BetterWindowsForeverAPI, a small global table for BetterForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The addon runs exactly the same
      without the hub; the API only exposes the settings the slash command already changes.

  Left alone on purpose: the world map (BetterMapsForever owns it), the bags (BetterBagsForever
  and Blizzard's bag layout own them), and anything Edit Mode places (unit frames, action bars,
  the objective tracker, ...). A candidate window that turns out to be an Edit Mode system is
  skipped at runtime.

  Blizzard's panel manager: ShowUIPanel / HideUIPanel and UpdateUIPanelPositions put the panels
  in their left/center/right slots with SetPoint. The addon never replaces any of that. It follows
  it: HookScript on each window's OnShow, hooksecurefunc on the global ShowUIPanel, HideUIPanel and
  UpdateUIPanelPositions and on FramePositionDelegate's own UpdateUIPanelPositions, a re-apply on
  the next frame, and a cheap check every 0.1 s while a moved window is open, which puts the saved
  anchor and scale back whenever something else has set them.

  Taint: Blizzard code is only ever followed, never replaced. Hooks go through hooksecurefunc and
  HookScript; no Blizzard function or table is written (UIPanelWindows included), and SetAttribute
  is never called on a Blizzard frame. Only the frame's own widget methods are used (SetPoint,
  SetScale, StartMoving). A protected window (IsProtected, which includes one with protected
  children) is never moved or scaled in combat: dragging or Ctrl-wheeling it prints a short line
  instead, and anything that would move it waits for PLAYER_REGEN_ENABLED. Windows that are not
  protected (Merchant, Gossip, Loot, ...) can be moved at any time.
]]

local _G = _G
local ADDON_NAME = ... or "BetterWindowsForever"
local DOT = " \194\183 "

local VERSION = "1.0.2"

local MIN_SCALE, MAX_SCALE = 0.5, 1.5
local SCALE_STEP = 0.05     -- per mouse-wheel notch
local TICK = 0.1            -- seconds between layout checks while a moved window is open
local HANDLE_HEIGHT = 22    -- the top-edge handle, for a window without a title strip

-- Every window the addon knows, in menu order. frames: candidate global names, first one found
-- wins (the client has one of them or none). addons: the load-on-demand Blizzard addon(s) that
-- create it, used only to tell "not loaded yet" from "not on this client".
local WINDOWS = {
    { key = "character", label = "Character", frames = { "CharacterFrame" } },
    { key = "spells", label = "Spellbook & Talents", frames = { "PlayerSpellsFrame" }, addons = { "Blizzard_PlayerSpells" } },
    { key = "spellbook", label = "Spellbook", frames = { "SpellBookFrame" } },
    { key = "talents", label = "Talents", frames = { "ClassTalentFrame", "PlayerTalentFrame", "TalentFrame" },
      addons = { "Blizzard_ClassTalentUI", "Blizzard_TalentUI" } },
    { key = "professions", label = "Professions", frames = { "ProfessionsFrame" }, addons = { "Blizzard_Professions" } },
    { key = "tradeskill", label = "Trade Skill", frames = { "TradeSkillFrame" }, addons = { "Blizzard_TradeSkillUI" } },
    { key = "craft", label = "Craft", frames = { "CraftFrame" }, addons = { "Blizzard_CraftUI" } },
    { key = "orders", label = "Crafting Orders", frames = { "ProfessionsCustomerOrdersFrame" },
      addons = { "Blizzard_ProfessionsCustomerOrders" } },
    { key = "collections", label = "Collections", frames = { "CollectionsJournal" }, addons = { "Blizzard_Collections" } },
    { key = "groupfinder", label = "Group Finder", frames = { "PVEFrame", "LFGParentFrame" } },
    { key = "social", label = "Social", frames = { "FriendsFrame" } },
    { key = "communities", label = "Guild & Communities", frames = { "CommunitiesFrame" }, addons = { "Blizzard_Communities" } },
    { key = "guild", label = "Guild", frames = { "GuildFrame" }, addons = { "Blizzard_GuildUI" } },
    { key = "achievements", label = "Achievements", frames = { "AchievementFrame" }, addons = { "Blizzard_AchievementUI" } },
    { key = "journal", label = "Encounter Journal", frames = { "EncounterJournal" }, addons = { "Blizzard_EncounterJournal" } },
    { key = "calendar", label = "Calendar", frames = { "CalendarFrame" }, addons = { "Blizzard_Calendar" } },
    { key = "merchant", label = "Merchant", frames = { "MerchantFrame" } },
    { key = "gossip", label = "Gossip", frames = { "GossipFrame" } },
    { key = "quest", label = "Quest dialog", frames = { "QuestFrame" } },
    { key = "questdetails", label = "Quest details", frames = { "QuestLogPopupDetailFrame" } },
    { key = "mail", label = "Mail", frames = { "MailFrame" } },
    { key = "openmail", label = "Open mail", frames = { "OpenMailFrame" } },
    { key = "bank", label = "Bank", frames = { "BankFrame" } },
    { key = "guildbank", label = "Guild Bank", frames = { "GuildBankFrame" }, addons = { "Blizzard_GuildBankUI" } },
    { key = "auction", label = "Auction House", frames = { "AuctionHouseFrame", "AuctionFrame" },
      addons = { "Blizzard_AuctionHouseUI", "Blizzard_AuctionUI" } },
    { key = "trainer", label = "Class Trainer", frames = { "ClassTrainerFrame" }, addons = { "Blizzard_TrainerUI" } },
    { key = "loot", label = "Loot", frames = { "LootFrame" } },
    { key = "dressup", label = "Dressing Room", frames = { "DressUpFrame" } },
    { key = "macros", label = "Macros", frames = { "MacroFrame" }, addons = { "Blizzard_MacroUI" } },
    { key = "settings", label = "Settings & Keybindings", frames = { "SettingsPanel" }, addons = { "Blizzard_Settings" } },
    { key = "keybindings", label = "Key Bindings", frames = { "KeyBindingFrame" }, addons = { "Blizzard_BindingUI" } },
    { key = "addons", label = "AddOn List", frames = { "AddonList" } },
    { key = "inspect", label = "Inspect", frames = { "InspectFrame" }, addons = { "Blizzard_InspectUI" } },
    { key = "trade", label = "Trade", frames = { "TradeFrame" } },
    { key = "gamemenu", label = "Game Menu", frames = { "GameMenuFrame" } },
    { key = "taxi", label = "Flight Master", frames = { "TaxiFrame" } },
    { key = "itemtext", label = "Books & Letters", frames = { "ItemTextFrame" } },
    { key = "tabard", label = "Tabard", frames = { "TabardFrame" } },
    { key = "petition", label = "Petition", frames = { "PetitionFrame" } },
    { key = "socketing", label = "Item Socketing", frames = { "ItemSocketingFrame" }, addons = { "Blizzard_ItemSocketingUI" } },
    { key = "itemupgrade", label = "Item Upgrade", frames = { "ItemUpgradeFrame" }, addons = { "Blizzard_ItemUpgradeUI" } },
    { key = "stable", label = "Stable", frames = { "StableFrame", "PetStableFrame" } },
    { key = "channels", label = "Chat Channels", frames = { "ChannelFrame" }, addons = { "Blizzard_Channels" } },
    { key = "clock", label = "Clock", frames = { "TimeManagerFrame" }, addons = { "Blizzard_TimeManager" } },
    { key = "help", label = "Help", frames = { "HelpFrame" } },
}

-- Every key BetterWindowsForeverDB may hold, and every key one window's entry may hold.
local SAVED_KEYS = { windows = true }
local WINDOW_KEYS = { off = true, x = true, y = true, scale = true }

local db                -- BetterWindowsForeverDB, bound at ADDON_LOADED (never at file scope)
local pendingAny        -- something is waiting for combat to end
local panelHooked       -- the panel manager hooks are in

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- Print, InCombat, Num and AddOnLoaded come from the shared library (BetterForever, loaded
-- first as a dependency). Num treats a secret value - the client hands one back where it hides
-- a number, and it can be neither compared nor used in a sum - as no number at all.
local BF = _G.BetterForever
local A = BF.NewAddon(ADDON_NAME, { version = VERSION })
local function Print(msg) A:Print(msg) end
local InCombat, Num, AddOnLoaded = BF.InCombat, BF.Num, BF.AddOnLoaded

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function Percent(v) return math.floor(v * 100 + 0.5) end

local function Near(a, b, eps)
    return math.abs((a or 0) - (b or 0)) < (eps or 0.01)
end

-- Whether the client ships an addon at all (loaded or not). Unknown counts as no.
local function AddOnExists(name)
    local c = _G.C_AddOns
    if type(c) == "table" and type(c.DoesAddOnExist) == "function" then
        local ok, exists = pcall(c.DoesAddOnExist, name)
        if ok then return exists and true or false end
    end
    local info = (type(c) == "table" and c.GetAddOnInfo) or _G.GetAddOnInfo
    if type(info) == "function" then
        local ok, title, _, _, _, reason = pcall(info, name)
        if ok then return title ~= nil and reason ~= "MISSING" end
    end
    return false
end

local function CapturePoints(region)
    local points = {}
    local n = Num(region.GetNumPoints and region:GetNumPoints()) or 0
    for i = 1, n do
        local point, relativeTo, relativePoint, x, y = region:GetPoint(i)
        x, y = Num(x or 0), Num(y or 0)
        if not x or not y then return nil end -- secret offsets: unknown, not "different"
        if point then points[#points + 1] = { point, relativeTo, relativePoint, x, y } end
    end
    return points
end

local function SetPoints(region, points)
    region:ClearAllPoints()
    for _, p in ipairs(points) do
        region:SetPoint(p[1], p[2], p[3], p[4], p[5])
    end
end

local function SamePoints(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do
        local p, q = a[i], b[i]
        if p[1] ~= q[1] or p[2] ~= q[2] or p[3] ~= q[3] or not Near(p[4], q[4]) or not Near(p[5], q[5]) then
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Windows: state and saved settings
--
-- Each entry of WINDOWS also carries its runtime state once its frame is found:
--   frame, name            the Blizzard frame and its global name
--   handle, wheel          our drag handle over the title strip, our Ctrl-wheel overlay
--   blizzardPoints         the anchor Blizzard last gave it, for reset and off
--   appliedPoints          the anchor we last set, so it is not mistaken for Blizzard's
--   blizzardScale, scaled  the scale before ours, and whether ours is on the frame
--   pending                a move, scale or restore waiting for combat to end
--   restore                off or reset: put Blizzard's anchor and scale back on the next apply
--   moving                 a title-bar drag is in progress
--   editMode               the frame is an Edit Mode system: skipped
-- ---------------------------------------------------------------------------

local function Saved(w)
    if not db then return nil end
    return db.windows[w.key]
end

local function SavedOrNew(w)
    local s = db.windows[w.key]
    if not s then
        s = {}
        db.windows[w.key] = s
    end
    return s
end

-- Drops an entry that holds nothing, so the saved variables stay small.
local function Tidy(w)
    local s = db and db.windows[w.key]
    if s and next(s) == nil then db.windows[w.key] = nil end
end

local function WindowOn(w)
    local s = Saved(w)
    return not (s and s.off)
end

local function HasLayout(w)
    local s = Saved(w)
    return s and (s.x ~= nil or s.scale ~= nil) and true or false
end

-- Whether the addon needs to touch the window at all; untouched windows stay Blizzard's.
local function Managed(w)
    return w.frame and not w.editMode and WindowOn(w) and HasLayout(w) or false
end

local function IsProtectedFrame(f)
    if type(f.IsProtected) ~= "function" then return false end
    local ok, protected = pcall(f.IsProtected, f)
    return ok and protected and true or false
end

-- In combat a protected window is out of reach; anything else can be moved at any time.
local function Blocked(w)
    return InCombat() and IsProtectedFrame(w.frame)
end

local function Queue(w)
    w.pending = true
    pendingAny = true
end

-- Converts between the window's own coordinates and UIParent's. Saved positions are kept in
-- UIParent units, so they hold whatever scale the window is at.
local function ScaleRatio(f)
    local parent = _G.UIParent
    local mine = Num(f.GetEffectiveScale and f:GetEffectiveScale())
    local theirs = Num(parent and parent.GetEffectiveScale and parent:GetEffectiveScale())
    if not mine or mine <= 0 or not theirs or theirs <= 0 then return nil end
    return mine / theirs
end

-- The window's top-left corner in UIParent units, or nil when the client will not say.
local function TopLeft(w)
    local f = w.frame
    local ratio = ScaleRatio(f)
    local left, top = Num(f:GetLeft()), Num(f:GetTop())
    if not ratio or not left or not top then return nil end
    return left * ratio, top * ratio
end

-- Puts the window's top-left corner at (x, y) in UIParent units, kept on screen.
local function PlaceTopLeft(w, x, y)
    local f, parent = w.frame, _G.UIParent
    local ratio = ScaleRatio(f)
    if not parent or not ratio then return false end
    local pw, ph = Num(parent:GetWidth()), Num(parent:GetHeight())
    local fw, fh = Num(f:GetWidth()), Num(f:GetHeight())
    if pw and ph and fw and fh and pw > 0 and ph > 0 then
        fw, fh = fw * ratio, fh * ratio
        x = math.max(0, math.min(x, math.max(0, pw - fw)))
        y = math.min(ph, math.max(y, math.min(fh, ph)))
    end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", x / ratio, y / ratio)
    w.appliedPoints = CapturePoints(f)
    return true
end

-- ---------------------------------------------------------------------------
-- Layout: scale and position
-- ---------------------------------------------------------------------------

local UpdateWidgets -- defined with the widgets below

-- Remembers where Blizzard put the window (our own anchor does not count) and its scale before
-- ours, so off and reset can put both back.
local function RememberBlizzard(w)
    local f = w.frame
    local points = CapturePoints(f)
    if points and #points > 0 and not SamePoints(points, w.appliedPoints) then
        w.blizzardPoints = points
        w.appliedPoints = nil
    end
    if not w.scaled then w.blizzardScale = Num(f:GetScale()) or 1 end
end

-- Gives the window back to Blizzard: its anchor (if ours is on it) and its scale.
local function RestoreBlizzard(w)
    local f = w.frame
    w.restore = false
    if w.scaled then
        f:SetScale(w.blizzardScale or 1)
        w.scaled = false
    end
    if w.appliedPoints and w.blizzardPoints and #w.blizzardPoints > 0 then
        local same = SamePoints(CapturePoints(f), w.appliedPoints)
        if same then SetPoints(f, w.blizzardPoints) end
    end
    w.appliedPoints = nil
end

-- Puts the saved scale and position on the window, or Blizzard's back after off or reset.
local function ApplyLayout(w)
    local f = w.frame
    if not f or not db or w.moving or w.editMode then return end
    if UpdateWidgets then UpdateWidgets(w) end
    if not Managed(w) and not w.restore then return end
    if Blocked(w) then
        Queue(w)
        return
    end
    w.pending = false

    RememberBlizzard(w)
    if w.restore then
        RestoreBlizzard(w)
        if not Managed(w) then return end
    end

    local s = Saved(w)
    if s.scale then
        if not Near(Num(f:GetScale()), s.scale, 0.001) then f:SetScale(s.scale) end
        w.scaled = true
    elseif w.scaled then
        f:SetScale(w.blizzardScale or 1)
        w.scaled = false
    end
    -- Placed again every time: after a scale change the same offsets would land elsewhere.
    if s.x then PlaceTopLeft(w, s.x, s.y) end
end

-- Cheap check from the ticker: has something put Blizzard's anchor or scale back since?
local function LayoutDrifted(w)
    if not Managed(w) or w.moving or Blocked(w) then return false end
    local s, f = Saved(w), w.frame
    if s.scale and not Near(Num(f:GetScale()), s.scale, 0.001) then return true end
    if s.x then
        local now = CapturePoints(f)
        if now and not SamePoints(now, w.appliedPoints) then return true end
    end
    return false
end

local function SavePosition(w, x, y)
    if not db then return end
    if not x then x, y = TopLeft(w) end
    if x and y then
        local s = SavedOrNew(w)
        s.x, s.y = x, y
    end
end

-- ---------------------------------------------------------------------------
-- The ticker: one for all windows, running only while a managed window is open
-- ---------------------------------------------------------------------------

local ticker = CreateFrame("Frame")
local acc = 0
local function Tick(_, elapsed)
    acc = acc + (elapsed or 0)
    if acc < TICK then return end
    acc = 0
    local any = false
    for _, w in ipairs(WINDOWS) do
        local f = w.frame
        if f and f:IsShown() and Managed(w) then
            any = true
            if LayoutDrifted(w) then ApplyLayout(w) end
        end
    end
    if not any then ticker:SetScript("OnUpdate", nil) end
end

local function StartTicker()
    acc = 0
    ticker:SetScript("OnUpdate", Tick)
end

-- ---------------------------------------------------------------------------
-- Moving: the title bar
-- ---------------------------------------------------------------------------

local function StartDrag(handle)
    local w = handle.w
    local f = w and w.frame
    if not f or not db or w.moving or not WindowOn(w) then return end
    if Blocked(w) then
        Print(w.label .. " cannot be moved in combat.")
        return
    end
    RememberBlizzard(w)
    w.wasMovable = f.IsMovable and f:IsMovable() or false
    w.wasClamped = f.IsClampedToScreen and f:IsClampedToScreen() or false
    if not w.wasMovable and f.SetMovable then f:SetMovable(true) end
    if not w.wasClamped and f.SetClampedToScreen then f:SetClampedToScreen(true) end
    f:StartMoving()
    w.moving = true
end

local function StopDrag(handle)
    local w = handle.w
    if not w or not w.moving then return end
    local f = w.frame
    w.moving = false
    f:StopMovingOrSizing()
    -- StartMoving marks the frame user-placed, which would make the client keep its own copy of
    -- the position in layout-local.txt. Ours lives in the saved variables instead.
    if f.SetUserPlaced then pcall(f.SetUserPlaced, f, false) end
    if not w.wasMovable and f.SetMovable then pcall(f.SetMovable, f, false) end
    if not w.wasClamped and f.SetClampedToScreen then pcall(f.SetClampedToScreen, f, false) end
    SavePosition(w)
    -- Our own anchor straight away, so the client's drag anchor is never taken for Blizzard's.
    local s = Saved(w)
    if s and s.x then PlaceTopLeft(w, s.x, s.y) end
    ApplyLayout(w)
    StartTicker()
end

-- Close and maximize buttons the handle must stay clear of, by the names Blizzard's templates use.
local function TitleButtons(w)
    local f, list = w.frame, {}
    local function add(b)
        if type(b) == "table" and b.GetLeft and b.IsShown then list[#list + 1] = b end
    end
    add(f.CloseButton)
    add(f.ClosePanelButton)
    add(f.MaximizeMinimizeFrame)
    add(f.MaxMinButtonFrame)
    add(w.name and _G[w.name .. "CloseButton"])
    if type(f.BorderFrame) == "table" then
        add(f.BorderFrame.CloseButton)
        add(f.BorderFrame.MaximizeMinimizeFrame)
    end
    return list
end

-- The handle covers the title strip, or the top edge when there is none, and stops short of the
-- close and maximize buttons so their clicks still reach them. Their place is read on each show.
local function LayoutDragHandle(w)
    local handle, f = w.handle, w.frame
    if not handle or not f then return end
    local title = f.TitleContainer
    if type(title) ~= "table" and type(f.BorderFrame) == "table" then title = f.BorderFrame.TitleContainer end
    local strip = (type(title) == "table" and title.GetRight and title) or f
    local right = Num(strip:GetRight())
    local inset, unknown = 0, false
    for _, b in ipairs(TitleButtons(w)) do
        if b:IsShown() then
            local left = Num(b:GetLeft())
            if right and left then
                if left < right then inset = math.max(inset, right - left + 2) end
            else
                unknown = true
            end
        end
    end
    -- Not laid out yet: keep well clear of the buttons until the next look.
    if unknown and inset == 0 then inset = 60 end
    handle:ClearAllPoints()
    if strip ~= f then
        handle:SetPoint("TOPLEFT", strip, "TOPLEFT", 0, 0)
        handle:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", -inset, 0)
        handle:SetFrameLevel((Num(strip:GetFrameLevel()) or 0) + 1)
    else
        handle:SetPoint("TOPLEFT", f, "TOPLEFT", 4, 0)
        handle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -math.max(inset, 4), 0)
        handle:SetHeight(HANDLE_HEIGHT)
        handle:SetFrameLevel((Num(f:GetFrameLevel()) or 0) + 10)
    end
end

local function HideTooltip()
    if _G.GameTooltip then _G.GameTooltip:Hide() end
end

local function CreateDragHandle(w)
    if w.handle then return end
    local handle = CreateFrame("Frame", nil, w.frame)
    handle.w = w
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", StartDrag)
    handle:SetScript("OnDragStop", StopDrag)
    handle:SetScript("OnHide", StopDrag)
    handle:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_TOP")
        tip:SetText("Drag to move " .. w.label)
        tip:AddLine("Ctrl + mouse wheel over the window to scale it. /bwf reset " .. w.key .. " to reset, /bwf off "
            .. w.key .. " to leave it to Blizzard.", 1, 1, 1, true)
        tip:Show()
    end)
    handle:SetScript("OnLeave", HideTooltip)
    w.handle = handle
    LayoutDragHandle(w)
end

-- ---------------------------------------------------------------------------
-- Scaling: Ctrl + mouse wheel
--
-- An overlay of our own covers the window. It takes the mouse wheel only while Ctrl is held and
-- never clicks or hover, so scrolling lists, clicks, tooltips and item drags are untouched.
-- ---------------------------------------------------------------------------

local function CtrlDown()
    return type(_G.IsControlKeyDown) == "function" and _G.IsControlKeyDown() and true or false
end

local combatNoticeAt = 0
local function WheelScale(overlay, delta)
    local w = overlay.w
    local f = w and w.frame
    if not f or not db or w.moving or not WindowOn(w) or not CtrlDown() then return end
    if Blocked(w) then
        local now = type(_G.GetTime) == "function" and _G.GetTime() or 0
        if now - combatNoticeAt > 2 then
            combatNoticeAt = now
            Print(w.label .. " cannot be scaled in combat.")
        end
        return
    end
    delta = Num(delta)
    if not delta or delta == 0 then return end
    RememberBlizzard(w)
    local s = Saved(w)
    local current = (s and s.scale) or Num(f:GetScale()) or 1
    local new = Clamp(math.floor((current + (delta > 0 and SCALE_STEP or -SCALE_STEP)) * 100 + 0.5) / 100, MIN_SCALE, MAX_SCALE)
    if s and s.scale and Near(new, s.scale, 0.001) then return end
    local x, y = TopLeft(w)
    s = SavedOrNew(w)
    s.scale = new
    f:SetScale(new)
    w.scaled = true
    -- The top-left corner stays put, and is saved so the window opens there next time.
    if x then
        SavePosition(w, x, y)
        PlaceTopLeft(w, x, y)
    end
    StartTicker()
end

local function UpdateWheel(w)
    local o = w.wheel
    if not o then return end
    local on = CtrlDown() and WindowOn(w) and not w.editMode and true or false
    if o.EnableMouseWheel then o:EnableMouseWheel(on) end
end

local function CreateWheelOverlay(w)
    if w.wheel then return end
    local f = w.frame
    local o = CreateFrame("Frame", nil, f)
    o.w = w
    o:SetAllPoints(f)
    o:EnableMouse(false)
    o:SetFrameLevel(math.min((Num(f:GetFrameLevel()) or 0) + 200, 9000))
    o:SetScript("OnMouseWheel", WheelScale)
    o:SetScript("OnShow", function() UpdateWheel(w) end)
    w.wheel = o
    UpdateWheel(w)
end

-- The handle and the overlay are our own frames, so showing or hiding them is fine in combat.
UpdateWidgets = function(w)
    local on = db and WindowOn(w) and not w.editMode and true or false
    if w.handle then w.handle:SetShown(on) end
    UpdateWheel(w)
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- Blizzard's panel layout sets the anchor right after the window shows, and the title buttons
-- only have a place once it is laid out; the next frame catches both.
local function ApplySoon(w)
    local t = _G.C_Timer
    if type(t) == "table" and type(t.After) == "function" then
        t.After(0, function()
            if w.frame and w.frame:IsShown() then
                LayoutDragHandle(w)
                ApplyLayout(w)
            end
        end)
    end
end

local function OnWindowShown(w)
    LayoutDragHandle(w)
    ApplyLayout(w)
    ApplySoon(w)
    if Managed(w) then StartTicker() end
end

local function OnWindowHidden(w)
    if w.moving and w.handle then StopDrag(w.handle) end
end

-- The panel manager has just placed the open panels: every open, moved window goes back.
local function OnPanelPositions()
    for _, w in ipairs(WINDOWS) do
        if w.frame and w.frame:IsShown() and (Managed(w) or w.restore) then ApplyLayout(w) end
    end
end

local function OnPanelShownOrHidden()
    OnPanelPositions()
    local t = _G.C_Timer
    if type(t) == "table" and type(t.After) == "function" then t.After(0, OnPanelPositions) end
end

local function HookPanelManager()
    if panelHooked then return end
    panelHooked = true
    if type(_G.UpdateUIPanelPositions) == "function" then
        hooksecurefunc("UpdateUIPanelPositions", OnPanelPositions)
    end
    for _, name in ipairs({ "ShowUIPanel", "HideUIPanel" }) do
        if type(_G[name]) == "function" then hooksecurefunc(name, OnPanelShownOrHidden) end
    end
    -- ShowUIPanel runs the layout through the delegate's own method, not the global.
    local delegate = _G.FramePositionDelegate
    if type(delegate) == "table" and type(delegate.UpdateUIPanelPositions) == "function" then
        hooksecurefunc(delegate, "UpdateUIPanelPositions", OnPanelPositions)
    end
end

-- An Edit Mode system belongs to Edit Mode; moving it here would fight the layout it saves.
local function IsEditModeSystem(f)
    return f.system ~= nil or f.systemInfo ~= nil or type(f.OnEditModeEnter) == "function"
end

local function FindFrame(w)
    for _, name in ipairs(w.frames) do
        local f = _G[name]
        if type(f) == "table" and f.SetPoint and f.ClearAllPoints and f.HookScript and f.StartMoving then
            return f, name
        end
    end
end

-- Finds and hooks every window that exists by now; load-on-demand ones come with ADDON_LOADED.
local function HookWindows()
    if not db then return end
    HookPanelManager()
    for _, w in ipairs(WINDOWS) do
        if not w.frame then
            local f, name = FindFrame(w)
            if f then
                w.frame, w.name = f, name
                if IsEditModeSystem(f) then
                    w.editMode = true
                else
                    f:HookScript("OnShow", function() OnWindowShown(w) end)
                    f:HookScript("OnHide", function() OnWindowHidden(w) end)
                    CreateDragHandle(w)
                    CreateWheelOverlay(w)
                    UpdateWidgets(w)
                    if f:IsShown() then OnWindowShown(w) end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Settings, shared by the slash command and the menu entries of the API
-- ---------------------------------------------------------------------------

local function Available(w)
    if w.frame then return not w.editMode end
    for _, a in ipairs(w.addons or {}) do
        if AddOnExists(a) and not AddOnLoaded(a) then return true end
    end
    return false
end

local function StateText(w)
    if w.editMode then return "skipped (Edit Mode owns it)" end
    if not w.frame then
        return Available(w) and "not loaded yet" or "not on this client"
    end
    local s = Saved(w)
    local parts = { WindowOn(w) and "on" or "off" }
    if s and s.x then parts[#parts + 1] = "moved" end
    if s and s.scale then parts[#parts + 1] = Percent(s.scale) .. "%" end
    if w.pending then parts[#parts + 1] = "waiting for combat to end" end
    return table.concat(parts, ", ")
end

local function SetWindowOn(w, on, quiet)
    if not db then return end
    if on then
        local s = Saved(w)
        if s then s.off = nil end
        Tidy(w)
        w.restore = false
    else
        if w.moving and w.handle then StopDrag(w.handle) end
        SavedOrNew(w).off = true
        w.restore = true
    end
    if w.frame then
        if on then UpdateWidgets(w) end
        ApplyLayout(w)
        if w.frame:IsShown() and Managed(w) then StartTicker() end
    end
    if quiet then return end
    if on then
        Print(w.label .. " on: drag its title bar to move it, Ctrl + mouse wheel to scale it.")
    else
        Print(w.label .. " off: left to Blizzard" .. (w.pending and " once combat ends." or "."))
    end
end

local function ResetWindow(w, quiet)
    if not db then return end
    if w.moving and w.handle then StopDrag(w.handle) end
    local s = Saved(w)
    if s then s.x, s.y, s.scale = nil, nil, nil end
    Tidy(w)
    if w.frame then
        w.restore = true
        ApplyLayout(w)
    end
    if not quiet then
        Print(w.label .. ": position and scale reset to Blizzard's" .. (w.pending and ", once combat ends." or "."))
    end
end

local function ResetAll()
    if not db then return end
    for _, w in ipairs(WINDOWS) do ResetWindow(w, true) end
    Print("every window's position and scale reset to Blizzard's" .. (pendingAny and InCombat() and ", the protected ones once combat ends." or "."))
end

-- A window by key, label or frame name, ignoring case, spaces and punctuation.
local function Squash(s) return ((s or ""):lower():gsub("[^%w]", "")) end

local function FindWindow(text)
    local q = Squash(text)
    if q == "" then return nil end
    for _, w in ipairs(WINDOWS) do
        if q == w.key or q == Squash(w.label) then return w end
        for _, name in ipairs(w.frames) do
            if q == Squash(name) then return w end
        end
    end
    -- A unique prefix is good enough: "achiev", "auc".
    local hit
    for _, w in ipairs(WINDOWS) do
        if w.key:sub(1, #q) == q or Squash(w.label):sub(1, #q) == q then
            if hit then return nil end
            hit = w
        end
    end
    return hit
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function Yes(v) return v and "yes" or "MISSING" end

local function Counts()
    local found, on, moved = 0, 0, 0
    for _, w in ipairs(WINDOWS) do
        if Available(w) then
            found = found + 1
            if WindowOn(w) then on = on + 1 end
            if HasLayout(w) then moved = moved + 1 end
        end
    end
    return found, on, moved
end

-- The intro BetterForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "Move and scale Blizzard's own windows (Character, Spellbook, Professions, Bank, Auction House and many more); position and scale are remembered per window. Nice to know: drag a window's title bar to move it; Ctrl + mouse wheel over it scales it (50-150%); /bwf list shows every window and its key; protected windows are not moved in combat."

local function PrintHelp()
    Print(INTRO)
    Print("drag a Blizzard window's title bar to move it; Ctrl + mouse wheel over it to scale it (50-150%).")
    Print("/bwf list - every window, its key and its state")
    Print("/bwf on <name> | /bwf off <name> - let the addon move the window, or leave it to Blizzard")
    Print("/bwf reset <name> | /bwf reset all - Blizzard's position and 100% scale")
    Print("/bwf status - what this client offers and the current settings")
end

local function PrintList()
    Print("windows (name for /bwf on|off|reset: the key in brackets):")
    for _, w in ipairs(WINDOWS) do
        local avail = Available(w)
        local color = (not avail and "|cff808080") or (WindowOn(w) and "|cffffffff") or "|cffaaaaaa"
        Print(color .. w.label .. "|r [" .. w.key .. "]: " .. StateText(w))
    end
end

local function PrintStatus()
    local found, on, moved = Counts()
    Print("version " .. VERSION)
    Print("UpdateUIPanelPositions: " .. Yes(type(_G.UpdateUIPanelPositions) == "function")
        .. "   ShowUIPanel: " .. Yes(type(_G.ShowUIPanel) == "function")
        .. "   FramePositionDelegate: " .. Yes(type(_G.FramePositionDelegate) == "table"))
    Print(string.format("windows on this client: %d   on: %d   moved or scaled: %d", found, on, moved))
    local missing = {}
    for _, w in ipairs(WINDOWS) do
        if not Available(w) then missing[#missing + 1] = w.label end
    end
    if #missing > 0 then Print("not on this client: " .. table.concat(missing, ", ")) end
    if pendingAny and InCombat() then Print("waiting for combat to end to move protected windows.") end
    for _, other in ipairs({ "BlizzMove", "MoveAnything", "MoveAny" }) do
        if AddOnLoaded(other) then Print(other .. " is loaded too: it also moves Blizzard windows. Use one of the two.") end
    end
end

local function OnSlash(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = (cmd or ""):lower()
    if cmd == "list" then
        PrintList()
    elseif cmd == "status" then
        PrintStatus()
    elseif (cmd == "on" or cmd == "off" or cmd == "reset") and arg ~= "" then
        if cmd == "reset" and arg:lower() == "all" then
            ResetAll()
            return
        end
        local w = FindWindow(arg)
        if not w then
            Print("no window called \"" .. arg .. "\". /bwf list shows them.")
        elseif cmd == "reset" then
            ResetWindow(w)
        else
            SetWindowOn(w, cmd == "on")
        end
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterWindowsForeverAPI
--
-- For BetterForever, the family hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterWindowsForeverDB and change only through the
-- same functions /bwf uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "24 of 26 windows on · 3 moved"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func },
--                        { text, submenu } and { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    local found, on, moved = Counts()
    return string.format("%d of %d windows on", on, found) .. DOT .. moved .. " moved"
end

local function MenuEntries()
    if not db then return {} end
    local entries, resets = {}, {}
    for _, w in ipairs(WINDOWS) do
        if Available(w) then
            entries[#entries + 1] = { text = w.label, checkbox = true,
                checked = function() return WindowOn(w) end,
                func = function() SetWindowOn(w, not WindowOn(w)) end }
            if HasLayout(w) then
                resets[#resets + 1] = { text = w.label, func = function() ResetWindow(w) end }
            end
        end
    end
    entries[#entries + 1] = { divider = true }
    if #resets > 0 then entries[#entries + 1] = { text = "Reset one window", submenu = resets } end
    entries[#entries + 1] = { text = "Reset all positions & scales", func = ResetAll }
    return entries
end

_G.BetterWindowsForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries()) end,
    SetMinimapHidden = function() end,
}

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterWindowsForeverDB) ~= "table" then BetterWindowsForeverDB = {} end
    db = BetterWindowsForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    if type(db.windows) ~= "table" then db.windows = {} end
    for key, s in pairs(db.windows) do
        if type(key) ~= "string" or type(s) ~= "table" then
            db.windows[key] = nil
        else
            for k in pairs(s) do
                if not WINDOW_KEYS[k] then s[k] = nil end
            end
            if s.off ~= true then s.off = nil end
            if not Num(s.x) or not Num(s.y) then s.x, s.y = nil, nil end
            local scale = Num(tonumber(s.scale))
            s.scale = scale and Clamp(scale, MIN_SCALE, MAX_SCALE) or nil
            if next(s) == nil then db.windows[key] = nil end
        end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("MODIFIER_STATE_CHANGED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then BindSavedVariables() end
        -- Ours, or a Blizzard addon that may have just created one of the windows.
        HookWindows()
    elseif event == "PLAYER_LOGIN" then
        HookWindows()
        for _, other in ipairs({ "BlizzMove", "MoveAnything", "MoveAny" }) do
            if AddOnLoaded(other) then
                Print(other .. " is loaded too and also moves Blizzard windows; use one of the two.")
            end
        end
    elseif event == "MODIFIER_STATE_CHANGED" then
        for _, w in ipairs(WINDOWS) do
            if w.wheel and w.frame:IsShown() then UpdateWheel(w) end
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- A drag of a protected window that is still going when combat starts ends here, where it is.
        for _, w in ipairs(WINDOWS) do
            if w.moving and w.handle and IsProtectedFrame(w.frame) then StopDrag(w.handle) end
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingAny then
            pendingAny = false
            for _, w in ipairs(WINDOWS) do
                if w.pending and w.frame then ApplyLayout(w) end
            end
        end
        OnPanelPositions()
    end
end)

SLASH_BETTERWINDOWSFOREVER1 = "/bwf"
SLASH_BETTERWINDOWSFOREVER2 = "/betterwindowsforever"
SlashCmdList.BETTERWINDOWSFOREVER = OnSlash
