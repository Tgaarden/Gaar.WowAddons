--[[
  GaarGroupForever - a small party assist bar, on WoW Forever.

  A movable bar that is shown ONLY while you are in a party (IsInGroup() and not IsInRaid()); it is
  hidden solo and in a raid. Settings are saved in GaarGroupForeverDB (account-wide), the chosen
  mode per character in GaarGroupForeverCharDB.

    Mode buttons   Tank, DPS, Healer (role icons). Clicking one sets your group role with
                   UnitSetRole("player", "TANK" / "DAMAGER" / "HEALER") when the client has it,
                   highlights it and remembers it for this character. The highlight follows the
                   game (PLAYER_ROLES_ASSIGNED, GROUP_ROSTER_UPDATE, UnitGroupRolesAssigned): a role
                   someone else gives you shows here too. When you join a party with no role set,
                   your saved mode is applied once.
    Shortcuts      Ready (DoReadyCheck) and Role (InitiateRolePoll), both greyed unless you are the
                   party leader; Pull countdown: left-click = the default length (5 s), right-click
                   = choose 3 / 5 / 10 s. C_PartyInfo.DoCountdown(n) is used when the client has it
                   (the game then decides who may start one, so the button is leader-gated like the
                   other two); without it the countdown is typed to PARTY chat ("Pull in 5", 4, 3,
                   2, 1, "Go!") - only on your click, never by itself.
    Per-mode modules  Modes is a table (key, role, label, icon); a later per-mode module can add
                   entries to M.ModeHooks[key] (called with the new mode when it is picked).

  Taint and safety: the bar has plain (non-secure) buttons only; none of these APIs is protected. The
  two secure buttons of the role modules (Healer tank frame, DPS Assist) are children of UIParent, not
  of the bar, and are only shown, hidden, moved or changed out of combat (Roles.lua). No event the
  client keeps from addons is registered (M.RegisterEvent refuses the combat log). ADDON_ACTION_BLOCKED /
  ADDON_ACTION_FORBIDDEN naming this addon are recorded for /ggf status. No Blizzard
  frame is touched. Every client API is checked with type(...) == "function" first and called in
  pcall, and a secret value is never compared: it is treated as no value.
]]

local _G = _G
local ADDON_NAME = ...
ADDON_NAME = ADDON_NAME or "GaarGroupForever"
local VERSION = "1.5.6"
local DOT = " \194\183 "

local BF = _G.GaarForever
local A = BF.NewAddon("GaarGroupForever", { title = "GaarGroupForever", version = VERSION })
local IsSecret, Num, OnOff = BF.IsSecret, BF.Num, BF.OnOff

local DEFAULTS = { show = true, locked = false, scale = 1, countdown = 5 }
local COUNTDOWNS = { 3, 5, 10 }
local SCALES = { 0.75, 1, 1.25, 1.5 }

-- Everything lives in M (the chunk has a 200-locals limit, and the test reaches in through it).
local M = {
    db = nil,        -- GaarGroupForeverDB, bound at ADDON_LOADED
    cdb = nil,       -- GaarGroupForeverCharDB
    bar = nil,       -- the frame
    buttons = {},    -- modes = { tank = btn, ... }, ready, role, count
    preview = false, -- /ggf test: show the bar solo, this session only
    wasInGroup = false,
    fallbackRunning = false,
    lastError = nil,
    ModeHooks = {},  -- ModeHooks[modeKey] = function(modeKey): per-mode modules plug in here
    -- Extension points for the other files (Overview, Checks, Markers, RunLog ...), reached through
    -- GaarGroupForeverAPI._M: saved-variable defaults, menu entries, slash subcommands, help lines.
    Defaults = {},   -- Defaults[key] = value, kept and filled in in GaarGroupForeverDB
    MenuParts = {},  -- function() return { menu entries } end
    Slash = {},      -- Slash[cmd] = function(arg)
    HelpParts = {},  -- function() return { help lines } end
}

-- The modes, in button order. role: what UnitSetRole / UnitGroupRolesAssigned use.
M.Modes = {
    { key = "tank", role = "TANK", label = "Tank", coords = { 0, 19 / 64, 22 / 64, 41 / 64 } },
    { key = "dps", role = "DAMAGER", label = "DPS", coords = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 } },
    { key = "healer", role = "HEALER", label = "Healer", coords = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 } },
}
M.ROLE_ICONS = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

function M.Print(msg) A:Print(msg) end

function M.Fail(where, err) M.lastError = where .. ": " .. tostring(err) end

-- Safe(where, fn, ...): fn in pcall, the error kept for /ggf status.
function M.Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then M.Fail(where, err) end
    return ok
end

-- Call a client function: its first result, or nil when missing, failing or secret.
function M.Q(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if not ok or IsSecret(v) then return nil end
    return v
end

-- Events WoW Forever (12.x engine) keeps from addons: registering one is itself a forbidden action
-- ("blocked from an action only available to the Blizzard UI"), so it is never done.
M.FORBIDDEN_EVENTS = { COMBAT_LOG_EVENT_UNFILTERED = true, COMBAT_LOG_EVENT = true }

function M.RegisterEvent(frame, event)
    if M.FORBIDDEN_EVENTS[event] then return false end
    return (pcall(frame.RegisterEvent, frame, event))
end

-- ---------------------------------------------------------------------------
-- Diagnostic: actions the client blocked for this addon (this session only)
-- ---------------------------------------------------------------------------

M.blocked = {}        -- { { event, func, combat, time } ...}, the last BLOCKED_KEEP
M.blockedNoted = false
local BLOCKED_KEEP = 20

function M.OnBlocked(event, addon, func)
    if addon ~= ADDON_NAME then return false end
    local combat = type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() and true or false
    local stamp = "?"
    if type(_G.date) == "function" then
        local ok, d = pcall(_G.date, "%H:%M:%S")
        if ok and type(d) == "string" then stamp = d end
    end
    local fn = type(func) == "string" and not IsSecret(func) and func or "?"
    local list = M.blocked
    list[#list + 1] = { event = event, func = fn, combat = combat, time = stamp }
    while #list > BLOCKED_KEEP do table.remove(list, 1) end
    if not M.blockedNoted then
        M.blockedNoted = true
        M.Print("blocked: " .. fn .. " \226\128\148 see /ggf status")
    end
    return true
end

-- The last n records as lines, newest last.
function M.BlockedLines(n)
    local out, list = {}, M.blocked
    for i = math.max(1, #list - (n or 5) + 1), #list do
        local b = list[i]
        out[#out + 1] = b.time .. " " .. (b.event == "ADDON_ACTION_FORBIDDEN" and "forbidden" or "blocked") .. " "
            .. b.func .. (b.combat and " (in combat)" or " (out of combat)")
    end
    return out
end

function M.InGroup() return M.Q(_G.IsInGroup) and true or false end
function M.InRaid() return M.Q(_G.IsInRaid) and true or false end
function M.IsLeader() return M.Q(_G.UnitIsGroupLeader, "player") and true or false end

function M.ModeByKey(key)
    for _, m in ipairs(M.Modes) do if m.key == key then return m end end
end

function M.ModeByRole(role)
    for _, m in ipairs(M.Modes) do if m.role == role then return m end end
end

-- Your group role as the game has it: "TANK" / "DAMAGER" / "HEALER", or nil for none / unknown.
function M.GameRole()
    local r = M.Q(_G.UnitGroupRolesAssigned, "player")
    if type(r) == "string" and r ~= "NONE" and M.ModeByRole(r) then return r end
end

-- ---------------------------------------------------------------------------
-- Logic (pure enough to test without a client)
-- ---------------------------------------------------------------------------

-- Shown only in a party (not solo, not raid), when the option is on. /ggf test shows it solo.
function M.ShouldShow()
    if not M.db then return false end
    if M.preview then return true end
    return M.db.show ~= false and M.InGroup() and not M.InRaid()
end

-- The active mode key: the game's role in a group, else the saved mode.
function M.ActiveMode()
    if M.InGroup() then
        local m = M.ModeByRole(M.GameRole())
        if m then return m.key end
    end
    return M.cdb and M.ModeByKey(M.cdb.mode) and M.cdb.mode or nil
end

-- Picks a mode: saved per character, group role set when the client can. Returns the mode, and
-- "set" / "saved" / "norole" (could not set the group role: not in a group or no API).
function M.SetMode(key)
    local m = M.ModeByKey(key)
    if not m then return nil end
    if M.cdb then M.cdb.mode = m.key end
    local result = "saved"
    if M.InGroup() then
        if type(_G.UnitSetRole) == "function" then
            result = M.Safe("UnitSetRole", _G.UnitSetRole, "player", m.role) and "set" or "norole"
        else
            result = "norole"
        end
    end
    local hook = M.ModeHooks[m.key]
    if type(hook) == "function" then M.Safe("modehook", hook, m.key) end
    return m, result
end

-- Ready check and role poll: leader only (the client refuses anyone else).
function M.ReadyState()
    if type(_G.DoReadyCheck) ~= "function" then return false, "This client has no ready check." end
    if not M.IsLeader() then return false, "Only the party leader can start a ready check." end
    return true
end

function M.RoleState()
    if type(_G.InitiateRolePoll) ~= "function" then return false, "This client has no role check." end
    if not M.IsLeader() then return false, "Only the party leader can start a role check." end
    return true
end

function M.NativeCountdown()
    local c = _G.C_PartyInfo
    return type(c) == "table" and type(c.DoCountdown) == "function"
end

-- The countdown button is leader-gated only when the client's own countdown is used (it is the
-- game that refuses non-leaders there); the chat fallback needs no rank.
function M.CountState()
    if M.NativeCountdown() then
        if not M.IsLeader() then return false, "Only the party leader can start a countdown." end
        return true
    end
    if type(_G.SendChatMessage) ~= "function" then return false, "This client cannot send chat." end
    return true
end

-- Chat fallback plan for an n second countdown: { delay seconds, text } steps.
function M.CountdownPlan(n)
    n = math.floor(Num(n) or 5)
    local plan = { { 0, "Pull in " .. n } }
    for i = n - 1, 1, -1 do plan[#plan + 1] = { n - i, tostring(i) } end
    plan[#plan + 1] = { n, "Go!" }
    return plan
end

function M.DefaultCountdown()
    local n = M.db and Num(M.db.countdown)
    for _, c in ipairs(COUNTDOWNS) do if c == n then return c end end
    return DEFAULTS.countdown
end

-- Starts an n second countdown (user click only). Returns "native", "chat" or nil + why.
function M.StartCountdown(n)
    n = Num(n) or M.DefaultCountdown()
    local ok, why = M.CountState()
    if not ok then return nil, why end
    if M.NativeCountdown() then
        local r = M.Q(_G.C_PartyInfo.DoCountdown, n)
        if r == false then return nil, "The game refused the countdown (leader or assistant only)." end
        return "native"
    end
    if M.fallbackRunning then return nil, "A countdown is already running." end
    local timer = _G.C_Timer
    local after = type(timer) == "table" and timer.After
    local plan = M.CountdownPlan(n)
    local function say(text)
        if not M.InGroup() then M.fallbackRunning = false; return false end
        local ch = M.InRaid() and "RAID" or "PARTY"
        pcall(_G.SendChatMessage, text, ch)
        return true
    end
    if type(after) ~= "function" then
        say(plan[1][2]) -- no timers: only the opening line, never a burst
        return "chat"
    end
    M.fallbackRunning = true
    for i, step in ipairs(plan) do
        local last = i == #plan
        after(step[1], function()
            if not M.fallbackRunning then return end
            local sent = say(step[2])
            if last or not sent then M.fallbackRunning = false end
        end)
    end
    return "chat"
end

function M.ShortcutReady()
    local ok, why = M.ReadyState()
    if not ok then return M.Print(why) end
    M.Safe("DoReadyCheck", _G.DoReadyCheck)
end

function M.ShortcutRole()
    local ok, why = M.RoleState()
    if not ok then return M.Print(why) end
    M.Safe("InitiateRolePoll", _G.InitiateRolePoll)
end

function M.ShortcutCount(n)
    local how, why = M.StartCountdown(n)
    if not how then M.Print(why) end
end

-- ---------------------------------------------------------------------------
-- The bar
-- ---------------------------------------------------------------------------

-- Panel metrics (shared with Overview.lua, which stacks the dock panels inside the frame).
M.Metrics = { icon = 26, btnH = 22, gap = 3, sep = 8, wide = 48, inset = 14, top = 22, bottom = 14, inner = 242 }
local MT = M.Metrics
MT.roleBottom = MT.top + MT.icon -- y (down from the panel top) where the role row ends
local SIZE, GAP, SEP, WIDE = MT.icon, MT.gap, MT.sep, MT.wide

local TOP_POINTS = { TOP = true, TOPLEFT = true, TOPRIGHT = true }

-- The panel changes height when panels open or close; a TOP-anchored frame then grows and shrinks downward and
-- the title never moves. Older saves (and a drag in some clients) can anchor on CENTER / BOTTOM...: convert to
-- the same screen spot anchored TOPLEFT to UIParent's BOTTOMLEFT. Returns true when it re-anchored.
function M.EnsureTopAnchor()
    local bar = M.bar
    if not bar or M.Q(_G.InCombatLockdown) then return false end
    local p = bar:GetPoint(1)
    if type(p) ~= "string" or TOP_POINTS[p] then return false end
    local ok, l, t = pcall(function() return bar:GetLeft(), bar:GetTop() end)
    l, t = Num(l), Num(t)
    if not ok or not l or not t then return false end
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMLEFT", l, t)
    return true
end

function M.SavePos()
    local bar, db = M.bar, M.db
    if not bar or not db then return end
    M.EnsureTopAnchor()
    local p, _, rp, x, y = bar:GetPoint(1)
    if p and Num(x) and Num(y) then db.pos = { p = p, rp = rp, x = x, y = y } end
end

function M.PlaceBar()
    local bar, db = M.bar, M.db
    bar:ClearAllPoints()
    local pos = db.pos
    if type(pos) == "table" and type(pos.p) == "string" and Num(pos.x) and Num(pos.y) then
        bar:SetPoint(pos.p, _G.UIParent, type(pos.rp) == "string" and pos.rp or pos.p, pos.x, pos.y)
    else
        bar:SetPoint("TOP", _G.UIParent, "CENTER", 0, -150)
    end
    M.topChecked = nil -- re-check once the dock has sized the bar (Overview.lua D.Layout)
end

function M.ApplyScale()
    local s = Num(M.db and M.db.scale) or 1
    if s < 0.5 or s > 2 then s = 1 end
    if M.bar then M.bar:SetScale(s) end
end

-- Tooltip: lines() returns { title, text, ... }; a "|cff..." grey reason is added by the caller.
function M.Tip(btn, lines)
    btn:SetScript("OnEnter", function(self)
        M.Safe("tip", function()
            local tip = _G.GameTooltip
            if not tip then return end
            tip:SetOwner(self, "ANCHOR_TOP")
            local l = lines()
            tip:SetText(l[1], 1, 1, 1)
            for i = 2, #l do tip:AddLine(l[i], 0.8, 0.8, 0.8, true) end
            tip:Show()
        end)
    end)
    btn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
end

function M.EnableDrag(frame)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function()
        M.Safe("drag", function()
            if M.db and not M.db.locked and M.bar and not M.Q(_G.InCombatLockdown) then M.bar:StartMoving() end
        end)
    end)
    frame:SetScript("OnDragStop", function()
        M.Safe("dragstop", function() M.bar:StopMovingOrSizing(); M.SavePos() end)
    end)
end

-- Blizzard dialog look: dark dialog background + the gold-rimmed border and a title plate. A frame
-- needs the BackdropTemplate to take a backdrop (12.x); without it (or if SetBackdrop fails) it
-- falls back to a flat dark fill, and f.dialog stays false.
M.DIALOG = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 11, top = 12, bottom = 11 },
}
M.FLAT = {
    bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

-- A frame with the given backdrop table (or a flat colour fill when that is not possible).
function M.NewBackdropFrame(name, parent, backdrop, flatColor)
    local ok, f = pcall(_G.CreateFrame, "Frame", name, parent, "BackdropTemplate")
    if not ok or not f then f = _G.CreateFrame("Frame", name, parent) end
    f.dialog = false
    if type(f.SetBackdrop) == "function" and pcall(f.SetBackdrop, f, backdrop) then
        f.dialog = true
    else
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(flatColor[1], flatColor[2], flatColor[3], flatColor[4])
    end
    return f
end

function M.NewDialog(name, parent)
    return M.NewBackdropFrame(name, parent, M.DIALOG, { 0.05, 0.05, 0.08, 0.92 })
end

-- A thin dark inset with a grey 1px edge: the well the dock panels and lists sit in.
function M.NewInset(name, parent)
    local f = M.NewBackdropFrame(name, parent, M.FLAT, { 0, 0, 0, 0.4 })
    if f.dialog then
        pcall(f.SetBackdropColor, f, 0, 0, 0, 0.4)
        pcall(f.SetBackdropBorderColor, f, 0.4, 0.4, 0.4, 0.8)
    end
    return f
end

-- The gold title plate on a dialog frame's top edge, with the title text. Returns the FontString.
function M.DialogTitle(f, text)
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if f.dialog then
        local hdr = f:CreateTexture(nil, "ARTWORK")
        hdr:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
        hdr:SetSize(256, 64)
        hdr:SetPoint("TOP", f, "TOP", 0, 12)
        fs:SetPoint("TOP", hdr, "TOP", 0, -14)
    else
        fs:SetPoint("TOP", f, "TOP", 0, -8)
    end
    fs:SetText(text)
    return fs
end

-- The classic red Blizzard button textures on a plain Button (no template): used when
-- UIPanelButtonTemplate is not there, and to dress a frame that must keep its own template.
function M.SkinPanelButton(b)
    local T = "Interface\\Buttons\\UI-Panel-Button-"
    pcall(function()
        b:SetNormalTexture(T .. "Up")
        b:SetPushedTexture(T .. "Down")
        b:SetDisabledTexture(T .. "Disabled")
        b:SetHighlightTexture(T .. "Highlight", "ADD")
        for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }) do
            local t = b[get](b)
            if t then t:SetTexCoord(0, 0.625, 0, 0.6875) end
        end
        local fs = b:GetFontString() or b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b:SetFontString(fs)
        b:SetNormalFontObject("GameFontNormalSmall")
        b:SetHighlightFontObject("GameFontHighlightSmall")
        b:SetDisabledFontObject("GameFontDisableSmall")
    end)
end

-- A real red Blizzard button (UIPanelButtonTemplate, not secure) with the small fonts; falls back
-- to the same textures on a plain Button.
function M.PanelButton(parent, name, text, width, height)
    local ok, b = pcall(_G.CreateFrame, "Button", name, parent, "UIPanelButtonTemplate")
    if ok and b then
        pcall(function()
            b:SetNormalFontObject("GameFontNormalSmall")
            b:SetHighlightFontObject("GameFontHighlightSmall")
            b:SetDisabledFontObject("GameFontDisableSmall")
        end)
    else
        b = _G.CreateFrame("Button", name, parent)
        M.SkinPanelButton(b)
    end
    b:SetText(text)
    b:SetSize(width, height or MT.btnH)
    return b
end

-- Selected state of a panel button (the tabs): the highlight stays on and the text turns white.
function M.SetSelected(btn, on)
    if not btn then return end
    pcall(on and btn.LockHighlight or btn.UnlockHighlight, btn)
    pcall(btn.SetNormalFontObject, btn, on and "GameFontHighlightSmall" or "GameFontNormalSmall")
end

-- A square action-button-like icon button: dark well, icon, the Quickslot border, hover and pushed
-- textures and (checkable) a lit "checked" state. texture may be nil (then it carries text only).
function M.IconButton(name, parent, size, texture, coords, checkable)
    local b = _G.CreateFrame(checkable and "CheckButton" or "Button", name, parent)
    b:SetSize(size, size)
    local well = b:CreateTexture(nil, "BACKGROUND")
    well:SetAllPoints()
    well:SetColorTexture(0, 0, 0, 0.6)
    local icon = b:CreateTexture(nil, "ARTWORK", nil, 2) -- above the border (ARTWORK 0): never covered
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    if texture then
        icon:SetTexture(texture)
        if coords then icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4]) end
    end
    b.icon = icon
    pcall(function()
        local big = size * 66 / 36 -- the ActionButton border is drawn 66 px for a 36 px button
        b:SetNormalTexture("Interface\\Buttons\\UI-Quickslot2")
        local n = b:GetNormalTexture()
        n:ClearAllPoints()
        n:SetPoint("CENTER", b, "CENTER", 0, -size / 36)
        n:SetSize(big, big)
        b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    end)
    -- Active state: our own additive glow on top. (SetCheckedTexture takes no blend mode, so the
    -- native checked texture drew opaque over the icon and hid it.)
    local glow = b:CreateTexture(nil, "OVERLAY")
    glow:SetAllPoints()
    glow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.7)
    glow:Hide()
    b.glow = glow
    b:RegisterForClicks("LeftButtonUp")
    M.EnableDrag(b)
    return b
end

-- Active (checked) state of an icon button: glow overlay on top, the icon is never touched.
function M.SetIconChecked(b, on)
    if b.SetChecked then b:SetChecked(on and true or false) end
    if b.glow then if on then b.glow:Show() else b.glow:Hide() end end
end

function M.TextButton(name, text, width, entries)
    local b = M.PanelButton(M.bar, name, text, width, MT.btnH)
    b:RegisterForClicks("LeftButtonUp")
    M.EnableDrag(b)
    if type(BF.AttachMenu) == "function" then
        BF.AttachMenu(b, { title = "GaarGroupForever", api = "GaarGroupForeverAPI", hook = true, entries = entries })
    end
    return b
end

-- The panel title: "Group", plus your mode when you have one (and "test" in test mode).
function M.TitleText()
    local m = M.ModeByKey(M.ActiveMode())
    return "Group" .. (m and (DOT .. m.label) or "") .. (M.preview and (DOT .. "test") or "")
end

function M.CreateBar()
    if M.bar then return end
    local bar = M.NewDialog("GaarGroupForeverBar", _G.UIParent)
    M.bar = bar
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:EnableMouse(true)
    M.EnableDrag(bar) -- drag by any part of the panel, the title included
    if type(BF.AttachMenu) == "function" then
        BF.AttachMenu(bar, { title = "GaarGroupForever", api = "GaarGroupForeverAPI", hook = true }) -- right-click: the addon's menu
    end
    bar.title = M.DialogTitle(bar, "Group")

    local x = MT.inset
    M.buttons.modes = {}
    for _, m in ipairs(M.Modes) do
        local b = M.IconButton("GaarGroupForeverMode" .. m.key, bar, SIZE, M.ROLE_ICONS, m.coords, true)
        b:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -MT.top)
        b:SetScript("OnClick", function()
            M.Safe("mode", function()
                local _, result = M.SetMode(m.key)
                if result == "norole" then M.Print("could not set your group role here; " .. m.label .. " is saved as your mode.") end
                M.Refresh()
            end)
        end)
        M.Tip(b, function()
            return { m.label, "Sets your group role to " .. m.label .. " and remembers it for this character.",
                "Right-click: menu" }
        end)
        if type(BF.AttachMenu) == "function" then
            BF.AttachMenu(b, { title = "GaarGroupForever", api = "GaarGroupForeverAPI", hook = true })
        end
        M.buttons.modes[m.key] = b
        x = x + SIZE + GAP
    end
    x = x - GAP + SEP

    local function shortcut(key, name, text, state, click, extra, entries)
        local b = M.TextButton("GaarGroupForever" .. name, text, WIDE, entries)
        b:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -(MT.top + (SIZE - MT.btnH) / 2))
        b:SetScript("OnClick", function() M.Safe(key, click) end)
        M.Tip(b, function()
            local l = extra()
            local ok, why = state()
            if not ok then l[#l + 1] = "|cffff6060" .. why .. "|r" end
            return l
        end)
        M.buttons[key] = b
        x = x + WIDE + GAP
        return b
    end
    shortcut("ready", "Ready", "Ready", M.ReadyState, M.ShortcutReady, function()
        return { "Ready check", "Asks the party to confirm they are ready." }
    end)
    shortcut("role", "Role", "Roles", M.RoleState, M.ShortcutRole, function()
        return { "Role check", "Asks the party to pick Tank, Healer or DPS." }
    end)
    shortcut("count", "Count", "Pull", M.CountState, function() M.ShortcutCount() end, function()
        return { "Pull countdown",
            "Left-click: " .. M.DefaultCountdown() .. " second countdown.",
            "Right-click: choose 3, 5 or 10 seconds." }
    end, M.CountdownEntries) -- right-click: its own menu of lengths
    bar:SetSize(x - GAP + MT.inset, MT.roleBottom + MT.bottom) -- the dock (Overview.lua) grows the height
    M.PlaceBar()
    M.ApplyScale()
end

-- Grey a button out (leader rule) without hiding its tooltip: the Blizzard disabled look on the
-- text buttons, desaturated and dimmed icon buttons.
function M.SetEnabled(btn, ok)
    if not btn then return end
    btn:SetEnabled(ok and true or false)
    if btn.icon then
        btn:SetAlpha(ok and 1 or 0.4)
        btn.icon:SetDesaturated(not ok)
    end
end

function M.Refresh()
    if not M.db then return end
    M.Safe("refresh", function()
        local show = M.ShouldShow()
        if show then M.CreateBar() end
        local bar = M.bar
        if not bar then return end
        if not show then bar:Hide(); return end
        bar:Show()
        -- Follow the game's role: remember it for this character.
        local role = M.InGroup() and M.ModeByRole(M.GameRole())
        if role and M.cdb then M.cdb.mode = role.key end
        local active = M.ActiveMode()
        for key, b in pairs(M.buttons.modes) do M.SetIconChecked(b, active == key) end
        if bar.title then bar.title:SetText(M.TitleText()) end
        M.SetEnabled(M.buttons.ready, (M.ReadyState()))
        M.SetEnabled(M.buttons.role, (M.RoleState()))
        M.SetEnabled(M.buttons.count, (M.CountState()))
    end)
end

-- Joined a party: apply the saved mode once when the game has no role for you yet.
function M.OnRosterUpdate()
    local inGroup = M.InGroup()
    if inGroup and not M.wasInGroup then
        local m = M.cdb and M.ModeByKey(M.cdb.mode)
        if m and not M.GameRole() and type(_G.UnitSetRole) == "function" and not M.Q(_G.InCombatLockdown) then
            M.Safe("UnitSetRole", _G.UnitSetRole, "player", m.role)
        end
    end
    if not inGroup then M.fallbackRunning = false end
    M.wasInGroup = inGroup
    M.Refresh()
end

-- ---------------------------------------------------------------------------
-- Settings, menu and slash command
-- ---------------------------------------------------------------------------

function M.SetShow(v) M.db.show = v and true or false; M.Refresh() end

function M.SetLocked(v) M.db.locked = v and true or false end

function M.SetScale(s) M.db.scale = s; M.ApplyScale() end

function M.SetCountdown(n)
    for _, c in ipairs(COUNTDOWNS) do
        if c == n then M.db.countdown = c; return true end
    end
    return false
end

function M.SetPreview(on)
    M.preview = on and true or false
    M.Refresh()
end

function M.ResetPos()
    M.db.pos = nil
    if M.bar then M.PlaceBar() end
end

function M.CountdownEntries()
    local e = {}
    for _, n in ipairs(COUNTDOWNS) do
        e[#e + 1] = { text = "Start " .. n .. " second countdown", func = function() M.ShortcutCount(n) end }
    end
    return e
end

local INTRO = "A small bar that shows only while you are in a party: pick your group role (Tank, DPS, Healer) and, as party leader, start a ready check, a role check or a pull countdown. Nice to know: right-click the bar for this menu; right-click the Pull button to choose 3, 5 or 10 seconds; /ggf test shows the bar solo so you can place it."

function M.MenuEntries()
    if not M.db then return {} end
    local scales, counts = {}, {}
    for _, s in ipairs(SCALES) do
        scales[#scales + 1] = { text = math.floor(s * 100 + 0.5) .. "%", radio = true,
            checked = function() return math.abs((Num(M.db.scale) or 1) - s) < 1e-6 end,
            func = function() M.SetScale(s) end }
    end
    for _, n in ipairs(COUNTDOWNS) do
        counts[#counts + 1] = { text = n .. " seconds", radio = true,
            checked = function() return M.DefaultCountdown() == n end,
            func = function() M.SetCountdown(n) end }
    end
    local entries = {
        { text = "Show the bar in a party", checkbox = true,
          checked = function() return M.db.show ~= false end, func = function() M.SetShow(M.db.show == false) end },
        { text = "Lock the bar", checkbox = true,
          checked = function() return M.db.locked == true end, func = function() M.SetLocked(not M.db.locked) end },
        { text = "Scale", submenu = scales },
        { text = "Default countdown", submenu = counts },
    }
    for _, part in ipairs(M.MenuParts) do
        local ok, list = pcall(part)
        if ok and type(list) == "table" and #list > 0 then
            entries[#entries + 1] = { divider = true }
            for _, e in ipairs(list) do entries[#entries + 1] = e end
        end
    end
    entries[#entries + 1] = { divider = true }
    entries[#entries + 1] = { text = "Test mode", checkbox = true, checked = function() return M.preview and true or false end,
        func = function() M.SetPreview(not M.preview) end }
    entries[#entries + 1] = { text = "Reset position", func = M.ResetPos }
    return entries
end

function M.StatusLine()
    if not M.db then return "not loaded yet" end
    return (M.db.show ~= false and "on" or "off") .. DOT .. (M.db.locked and "locked" or "unlocked")
        .. DOT .. "countdown " .. M.DefaultCountdown() .. " s"
end

function M.PrintHelp()
    M.Print("Right-click the bar: this addon's menu (the same options as the hub menu).")
    M.Print(INTRO)
    M.Print("/ggf show | hide | toggle - the bar in a party (now " .. OnOff(M.db and M.db.show ~= false) .. ")")
    M.Print("/ggf lock | unlock - the bar's position (now " .. (M.db and M.db.locked and "locked" or "unlocked") .. ")")
    M.Print("/ggf reset - put the bar back where it started")
    M.Print("/ggf scale 0.5-2 | countdown 3|5|10 - size and default pull time")
    M.Print("/ggf test - show the bar solo to place it (this session)")
    for _, part in ipairs(M.HelpParts) do
        local ok, lines = pcall(part)
        if ok and type(lines) == "table" then for _, l in ipairs(lines) do M.Print(l) end end
    end
    M.Print("/ggf status - settings")
    if M.Roles then M.Roles.Help() end
end

function M.PrintStatus()
    M.Print("version " .. VERSION .. DOT .. M.StatusLine())
    local role = M.GameRole()
    M.Print("in group: " .. OnOff(M.InGroup()) .. DOT .. "raid: " .. OnOff(M.InRaid()) .. DOT .. "leader: " .. OnOff(M.IsLeader())
        .. DOT .. "role: " .. (role or "none") .. DOT .. "mode: " .. (M.cdb and M.cdb.mode or "none"))
    M.Print("bar shown: " .. OnOff(M.bar and M.bar:IsShown()) .. DOT .. "countdown: "
        .. (M.NativeCountdown() and "game (C_PartyInfo.DoCountdown)" or "party chat fallback"))
    if M.lastError then M.Print("last error: " .. M.lastError) end
    if #M.blocked > 0 then
        M.Print("actions the game blocked for this addon this session: " .. #M.blocked .. " (last 5):")
        for _, l in ipairs(M.BlockedLines(5)) do M.Print("  " .. l) end
    end
end

function M.OnSlash(msg)
    local ok, err = pcall(function()
        if not M.db then M.Print("not loaded yet."); return end
        local cmd, arg = (msg or ""):match("^(%S+)%s*(.*)$")
        cmd, arg = (cmd or ""):lower(), (arg or ""):lower()
        if cmd == "show" or cmd == "hide" then
            M.SetShow(cmd == "show"); M.Print("bar " .. (cmd == "show" and "shown (in a party)." or "hidden."))
        elseif cmd == "toggle" then
            M.SetShow(M.db.show == false); M.Print("bar " .. OnOff(M.db.show ~= false) .. ".")
        elseif cmd == "lock" or cmd == "unlock" then
            M.SetLocked(cmd == "lock"); M.Print("bar " .. (cmd == "lock" and "locked." or "unlocked: drag it."))
        elseif cmd == "reset" then
            M.ResetPos(); M.Print("bar position reset.")
        elseif cmd == "scale" then
            local s = Num(tonumber(arg))
            if s and s >= 0.5 and s <= 2 then M.SetScale(s); M.Print("scale " .. s .. ".")
            else M.Print("/ggf scale 0.5-2") end
        elseif cmd == "countdown" then
            if M.SetCountdown(tonumber(arg)) then M.Print("default countdown " .. M.DefaultCountdown() .. " s.")
            else M.Print("/ggf countdown 3|5|10") end
        elseif cmd == "test" then
            M.SetPreview(not M.preview); M.Print("test mode " .. OnOff(M.preview) .. ".")
        elseif cmd == "status" then
            M.PrintStatus()
        elseif type(M.Slash[cmd]) == "function" then
            M.Slash[cmd](arg)
        else
            M.PrintHelp()
        end
    end)
    if not ok then M.Fail("slash", err); M.Print("error: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Public API: GaarGroupForeverAPI (for the GaarForever hub: menu and Options page)
-- ---------------------------------------------------------------------------

_G.GaarGroupForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = M.StatusLine,
    MenuEntries = M.MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, M.MenuEntries(), A.title) end,
    SetMinimapHidden = function() end,
    _M = M, -- for the other files of this addon (Overview.lua, Checks.lua, Markers.lua, RunLog.lua)
}

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function M.BindSavedVariables()
    if type(_G.GaarGroupForeverDB) ~= "table" then _G.GaarGroupForeverDB = {} end
    if type(_G.GaarGroupForeverCharDB) ~= "table" then _G.GaarGroupForeverCharDB = {} end
    local db = _G.GaarGroupForeverDB
    M.db, M.cdb = db, _G.GaarGroupForeverCharDB
    for k in pairs(db) do
        if DEFAULTS[k] == nil and M.Defaults[k] == nil and k ~= "pos" then db[k] = nil end
    end
    for k, v in pairs(M.Defaults) do
        if type(db[k]) ~= type(v) then db[k] = v end
    end
    if type(db.show) ~= "boolean" then db.show = DEFAULTS.show end
    if type(db.locked) ~= "boolean" then db.locked = DEFAULTS.locked end
    if type(db.scale) ~= "number" then db.scale = DEFAULTS.scale end
    if type(db.countdown) ~= "number" then db.countdown = DEFAULTS.countdown end
    if not M.ModeByKey(M.cdb.mode) then M.cdb.mode = nil end
end

function M.OnEvent(_, event, arg1, arg2)
    local ok, err = pcall(function()
        if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
            M.OnBlocked(event, arg1, arg2)
        elseif event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then M.BindSavedVariables() end
        elseif not M.db then
            return
        elseif event == "PLAYER_ENTERING_WORLD" then
            M.wasInGroup = M.InGroup()
            M.Refresh()
        elseif event == "PLAYER_ROLES_ASSIGNED" or event == "PARTY_LEADER_CHANGED" then
            M.Refresh()
        else -- GROUP_ROSTER_UPDATE
            M.OnRosterUpdate()
        end
    end)
    if not ok then M.Fail(event, err) end
end

local events = _G.CreateFrame("Frame")
for _, ev in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE",
    "PLAYER_ROLES_ASSIGNED", "PARTY_LEADER_CHANGED", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    M.RegisterEvent(events, ev)
end
events:SetScript("OnEvent", M.OnEvent)

_G.SLASH_GAARGROUPFOREVER1 = "/ggf"
_G.SLASH_GAARGROUPFOREVER2 = "/gaargroupforever"
_G.SlashCmdList.GAARGROUPFOREVER = M.OnSlash
