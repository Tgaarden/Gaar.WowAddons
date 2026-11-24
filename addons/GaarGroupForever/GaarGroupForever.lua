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

  Taint and safety: plain (non-secure) buttons only; none of these APIs is protected. No Blizzard
  frame is touched. Every client API is checked with type(...) == "function" first and called in
  pcall, and a secret value is never compared: it is treated as no value.
]]

local _G = _G
local ADDON_NAME = ...
ADDON_NAME = ADDON_NAME or "GaarGroupForever"
local VERSION = "1.3.0"
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

local SIZE, GAP, PAD, SEP, WIDE = 26, 3, 5, 8, 46

function M.SavePos()
    local bar, db = M.bar, M.db
    if not bar or not db then return end
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
        bar:SetPoint("CENTER", _G.UIParent, "CENTER", 0, -200)
    end
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
            if M.db and not M.db.locked and M.bar then M.bar:StartMoving() end
        end)
    end)
    frame:SetScript("OnDragStop", function()
        M.Safe("dragstop", function() M.bar:StopMovingOrSizing(); M.SavePos() end)
    end)
end

function M.NewButton(name, width, entries)
    local b = _G.CreateFrame("Button", name, M.bar)
    b:SetSize(width, SIZE)
    b:RegisterForClicks("LeftButtonUp")
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    b.bg = bg
    local hl = b:CreateTexture(nil, "BORDER")
    hl:SetPoint("TOPLEFT", -2, 2)
    hl:SetPoint("BOTTOMRIGHT", 2, -2)
    hl:SetColorTexture(0.2, 0.9, 0.3, 1)
    hl:Hide()
    b.active = hl
    local hot = b:CreateTexture(nil, "HIGHLIGHT")
    hot:SetAllPoints()
    hot:SetColorTexture(1, 1, 1, 0.15)
    M.EnableDrag(b)
    if type(BF.AttachMenu) == "function" then
        BF.AttachMenu(b, { title = "GaarGroupForever", api = "GaarGroupForeverAPI", hook = true, entries = entries })
    end
    return b
end

function M.TextButton(name, text, width, entries)
    local b = M.NewButton(name, width, entries)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    fs:SetText(text)
    b.label = fs
    return b
end

function M.CreateBar()
    if M.bar then return end
    local bar = _G.CreateFrame("Frame", "GaarGroupForeverBar", _G.UIParent)
    M.bar = bar
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    bar:EnableMouse(true)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)
    M.EnableDrag(bar)
    if type(BF.AttachMenu) == "function" then
        BF.AttachMenu(bar, { title = "GaarGroupForever", api = "GaarGroupForeverAPI", hook = true }) -- right-click: the addon's menu
    end

    local x = PAD
    M.buttons.modes = {}
    for _, m in ipairs(M.Modes) do
        local b = M.NewButton("GaarGroupForeverMode" .. m.key, SIZE)
        b:SetPoint("LEFT", bar, "LEFT", x, 0)
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        icon:SetTexture(M.ROLE_ICONS)
        icon:SetTexCoord(m.coords[1], m.coords[2], m.coords[3], m.coords[4])
        b.icon = icon
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
        M.buttons.modes[m.key] = b
        x = x + SIZE + GAP
    end
    x = x - GAP + SEP

    local function shortcut(key, name, text, state, click, extra, entries)
        local b = M.TextButton("GaarGroupForever" .. name, text, WIDE, entries)
        b:SetPoint("LEFT", bar, "LEFT", x, 0)
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
    bar:SetSize(x - GAP + PAD, SIZE + 2 * PAD)
    M.PlaceBar()
    M.ApplyScale()
end

-- Grey a button out (leader rule) without hiding its tooltip.
function M.SetEnabled(btn, ok)
    if not btn then return end
    btn:SetEnabled(ok and true or false)
    btn:SetAlpha(ok and 1 or 0.4)
    if btn.icon then btn.icon:SetDesaturated(not ok) end
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
        for key, b in pairs(M.buttons.modes) do
            if active == key then b.active:Show() else b.active:Hide() end
        end
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
        if m and not M.GameRole() and type(_G.UnitSetRole) == "function" then
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

function M.OnEvent(_, event, arg1)
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
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
    "PLAYER_ROLES_ASSIGNED", "PARTY_LEADER_CHANGED" }) do
    pcall(events.RegisterEvent, events, ev)
end
events:SetScript("OnEvent", M.OnEvent)

_G.SLASH_GAARGROUPFOREVER1 = "/ggf"
_G.SLASH_GAARGROUPFOREVER2 = "/gaargroupforever"
_G.SlashCmdList.GAARGROUPFOREVER = M.OnSlash
