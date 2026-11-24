--[[
  GaarGroupForever - Overview.lua: the group overview under the bar, and the shared "dock".

  Under the bar sits a dock: a header row of small buttons (Group, and the ones Checks.lua,
  Markers.lua and RunLog.lua register) and, below it, panels: the group overview list (this file)
  and the raid-marker row (Markers.lua). Everything is a child of the bar, so it hides, moves and
  scales with it.

  The overview lists each party member: role icon, name, level in class colour, and a status
  (offline / dead / far = out of range or not in view). Range comes from UnitInRange (or
  CheckInteractDistance when that cannot tell); a value the client does not give, or a secret
  value, is "unknown" and shows no status. Nothing here compares a secret value.

  Also here: M.UI.Window / M.UI.Button, the small text window Checks.lua and RunLog.lua use.
]]

local _G = _G
local API = _G.GaarGroupForeverAPI
local M = API and API._M
if not M then return end

local BF = _G.GaarForever
local IsSecret = BF.IsSecret

M.Defaults.overview = true
M.Defaults.ovCollapsed = false

local O = {}
M.Overview = O
local D = { buttons = {}, panels = {}, rows = {} }
M.Dock = D
M.UI = {}

local GAP, ROWH, ICON = 3, 15, 13

-- ---------------------------------------------------------------------------
-- Member info (logic; tested without a client)
-- ---------------------------------------------------------------------------

-- Two results of a client call, or nil: secret values are dropped.
local function Two(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    if IsSecret(a) then a = nil end
    if IsSecret(b) then b = nil end
    return a, b
end
O.Two = Two

-- The units to list: you, then party1-4 that exist. Solo only in test mode.
function O.Units()
    local list = {}
    if M.InGroup() or M.preview then
        list[1] = "player"
        for i = 1, 4 do
            local u = "party" .. i
            if M.Q(_G.UnitExists, u) then list[#list + 1] = u end
        end
    end
    return list
end

-- true / false, or nil when it cannot be told.
function O.InRange(unit)
    if unit == "player" then return true end
    local inr, checked = Two(_G.UnitInRange, unit)
    if inr ~= nil and checked ~= false then return inr and true or false end
    local near = M.Q(_G.CheckInteractDistance, unit, 4)
    if near ~= nil then return near and true or false end
    return nil
end

-- info: { connected = bool|nil, dead = bool|nil, inRange = bool|nil, visible = bool|nil }
function O.StatusOf(info)
    if info.connected == false then return "offline" end
    if info.dead then return "dead" end
    if info.inRange == false or info.visible == false then return "far" end
    return "ok"
end

O.STATUS_TEXT = { offline = "|cff9d9d9doffline|r", dead = "|cffff4040dead|r", far = "|cffffa040far|r" }

function O.Member(unit)
    local m = { unit = unit }
    local name = M.Q(_G.UnitName, unit)
    m.name = type(name) == "string" and name or "?"
    local lvl = M.Q(_G.UnitLevel, unit)
    m.level = type(lvl) == "number" and lvl or nil
    local _, token = Two(_G.UnitClass, unit)
    m.class = type(token) == "string" and token or nil
    local role = M.Q(_G.UnitGroupRolesAssigned, unit)
    m.role = type(role) == "string" and role or nil
    m.connected = M.Q(_G.UnitIsConnected, unit)
    m.dead = M.Q(_G.UnitIsDeadOrGhost, unit) and true or false
    m.visible = unit == "player" and true or M.Q(_G.UnitIsVisible, unit)
    m.inRange = O.InRange(unit)
    m.status = O.StatusOf(m)
    return m
end

function O.ClassColor(class)
    local t = _G.RAID_CLASS_COLORS
    local c = type(t) == "table" and class and t[class]
    if type(c) == "table" and type(c.r) == "number" then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- ---------------------------------------------------------------------------
-- Shared small UI: buttons and a text window
-- ---------------------------------------------------------------------------

function M.UI.Button(parent, text, width, onclick)
    local ok, b = pcall(_G.CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok or not b then
        b = _G.CreateFrame("Button", nil, parent)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.2, 0.2, 0.2, 0.9)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER")
        fs:SetText(text)
    else
        b:SetText(text)
    end
    b:SetSize(width, 20)
    b:SetScript("OnClick", function() M.Safe("button", onclick) end)
    return b
end

-- A movable, closable window of text lines. Returns w with w.frame, w.SetLines(lines),
-- w.AddButton(text, fn) and w.Show().
function M.UI.Window(name, title, width)
    local f = _G.CreateFrame("Frame", name, _G.UIParent)
    f:SetSize(width, 100)
    f:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 80)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() M.Safe("wdrag", f.StartMoving, f) end)
    f:SetScript("OnDragStop", function() M.Safe("wdragstop", f.StopMovingOrSizing, f) end)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.08, 0.92)
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOPLEFT", 10, -8)
    t:SetText(title)
    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT", 10, -28)
    body:SetWidth(width - 20)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    local ok, close = pcall(_G.CreateFrame, "Button", nil, f, "UIPanelCloseButton")
    if ok and close then
        close:SetPoint("TOPRIGHT", 2, 2)
        close:SetScript("OnClick", function() f:Hide() end)
    end
    if type(_G.UISpecialFrames) == "table" and name then table.insert(_G.UISpecialFrames, name) end
    f:Hide()
    local w = { frame = f, body = body, buttons = {}, nlines = 0 }
    function w.SetLines(lines)
        w.nlines = #lines
        body:SetText(table.concat(lines, "\n"))
        local h = ROWH * #lines
        local ok2, sh = pcall(body.GetStringHeight, body)
        if ok2 and type(sh) == "number" and sh > 0 then h = sh end
        f:SetHeight(28 + h + 40)
    end
    function w.AddButton(text, fn)
        local b = M.UI.Button(f, text, 80, fn)
        local n = #w.buttons
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10 + n * 84, 10)
        w.buttons[n + 1] = b
        return b
    end
    function w.Show() f:Show() end
    return w
end

-- ---------------------------------------------------------------------------
-- The dock: header buttons and panels
-- ---------------------------------------------------------------------------

-- spec: { key, text, opt (db key that switches it on, or nil), click, tip = {title, text...},
--         active = function() -> bool, optional }
function D.AddButton(spec) D.buttons[#D.buttons + 1] = spec end

-- panel: { frame or getFrame, height = function() -> number|nil (nil = hidden) }
function D.AddPanel(panel) D.panels[#D.panels + 1] = panel end

function D.OptOn(spec) return not spec.opt or (M.db and M.db[spec.opt] ~= false) end

function D.Build()
    if D.built or not M.bar then return end
    D.built = true
    for _, spec in ipairs(D.buttons) do
        local b = M.TextButton("GaarGroupForeverDock" .. spec.key, spec.text, 40)
        b:SetScript("OnClick", function() M.Safe(spec.key, spec.click) end)
        M.Tip(b, function()
            local l = {}
            for i, line in ipairs(spec.tip) do l[i] = line end
            l[#l + 1] = "Right-click: menu"
            return l
        end)
        spec.btn = b
    end
    local tick = _G.CreateFrame("Frame", nil, M.bar)
    local acc = 0
    tick:SetScript("OnUpdate", function(_, dt)
        acc = acc + (type(dt) == "number" and dt or 0)
        if acc < 1 then return end
        acc = 0
        M.Safe("dock", D.Update)
    end)
end

function D.Layout()
    local bar = M.bar
    if not bar then return end
    local w = bar:GetWidth()
    if type(w) ~= "number" or w < 50 then w = 240 end
    local vis = {}
    for _, spec in ipairs(D.buttons) do
        if spec.btn then
            if D.OptOn(spec) then vis[#vis + 1] = spec else spec.btn:Hide() end
        end
    end
    local y = 2
    if #vis > 0 then
        local bw = math.floor((w - (#vis - 1) * GAP) / #vis)
        for i, spec in ipairs(vis) do
            local b = spec.btn
            b:ClearAllPoints()
            b:SetWidth(bw)
            b:SetHeight(22)
            b:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", (i - 1) * (bw + GAP), -y)
            b:Show()
            if type(spec.active) == "function" then
                if spec.active() then b.active:Show() else b.active:Hide() end
            end
        end
        y = y + 22 + GAP
    end
    for _, p in ipairs(D.panels) do
        local h = p.height()
        local fr = p.frame or (p.getFrame and p.getFrame())
        if fr then
            if h and h > 0 then
                fr:ClearAllPoints()
                fr:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -y)
                fr:SetSize(w, h)
                fr:Show()
                y = y + h + GAP
            else
                fr:Hide()
            end
        end
    end
end

function D.Update()
    if not M.bar or not M.bar:IsShown() then return end
    D.Build()
    if O.Fill then O.Fill() end
    D.Layout()
end

-- Wrap the bar's creation and refresh (M is our own table) so the dock follows the bar.
do
    local create, refresh = M.CreateBar, M.Refresh
    function M.CreateBar()
        create()
        M.Safe("dockbuild", D.Build)
    end
    function M.Refresh()
        refresh()
        M.Safe("dock", D.Update)
    end
end

-- ---------------------------------------------------------------------------
-- The overview list
-- ---------------------------------------------------------------------------

function O.Enabled() return M.db and M.db.overview ~= false end
function O.Expanded() return O.Enabled() and not (M.db and M.db.ovCollapsed) end

local frame
local function EnsureFrame()
    if frame or not M.bar then return frame end
    frame = _G.CreateFrame("Frame", "GaarGroupForeverOverview", M.bar)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)
    for i = 1, 5 do
        local r = {}
        r.icon = frame:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(ICON, ICON)
        r.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -(2 + (i - 1) * ROWH))
        r.icon:SetTexture(M.ROLE_ICONS)
        r.name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
        r.name:SetJustifyH("LEFT")
        r.status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        r.status:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -(2 + (i - 1) * ROWH - 1))
        r.status:SetJustifyH("RIGHT")
        D.rows[i] = r
    end
    return frame
end

D.AddPanel({ getFrame = EnsureFrame, height = function()
    if not O.Expanded() then return nil end
    local n = #(O.shown or {})
    return n > 0 and (n * ROWH + 4) or nil
end })

function O.Fill()
    if not O.Enabled() then O.shown = {}; return end
    if not EnsureFrame() then return end
    local units = O.Units()
    O.shown = O.Expanded() and units or {}
    if not O.Expanded() then return end
    for i, r in ipairs(D.rows) do
        local unit = units[i]
        if not unit then
            r.icon:Hide(); r.name:SetText(""); r.status:SetText("")
        else
            local m = O.Member(unit)
            local mode = M.ModeByRole(m.role)
            if mode then
                r.icon:SetTexCoord(mode.coords[1], mode.coords[2], mode.coords[3], mode.coords[4])
                r.icon:Show()
            else
                r.icon:Hide()
            end
            r.name:SetText(m.name .. (m.level and ("  " .. m.level) or ""))
            r.name:SetTextColor(O.ClassColor(m.class))
            r.status:SetText(O.STATUS_TEXT[m.status] or "")
        end
    end
end

function O.SetEnabled(v) M.db.overview = v and true or false; M.Refresh() end
function O.SetCollapsed(v) M.db.ovCollapsed = v and true or false; M.Refresh() end

D.AddButton({ key = "Group", text = "Group", opt = "overview",
    click = function() O.SetCollapsed(not M.db.ovCollapsed) end,
    active = function() return O.Expanded() end,
    tip = { "Group overview", "Shows or hides the list of party members: role, name, level and status (dead, offline, out of range)." } })

M.MenuParts[#M.MenuParts + 1] = function()
    return {
        { text = "Group overview", checkbox = true,
          checked = function() return M.db.overview ~= false end, func = function() O.SetEnabled(M.db.overview == false) end },
        { text = "Collapse the overview list", checkbox = true,
          checked = function() return M.db.ovCollapsed == true end, func = function() O.SetCollapsed(not M.db.ovCollapsed) end },
    }
end

M.Slash.group = function(arg)
    if arg == "on" or arg == "off" then
        O.SetEnabled(arg == "on"); M.Print("group overview " .. (arg == "on" and "on." or "off."))
    elseif arg == "collapse" or arg == "expand" then
        O.SetCollapsed(arg == "collapse"); M.Print("overview list " .. (arg == "collapse" and "collapsed." or "expanded."))
    else
        M.Print("/ggf group on | off | collapse | expand")
    end
end

M.HelpParts[#M.HelpParts + 1] = function()
    return { "/ggf group on|off|collapse|expand - the member list under the bar (now "
        .. (M.db and M.db.overview ~= false and (M.db.ovCollapsed and "collapsed" or "shown") or "off") .. ")" }
end
