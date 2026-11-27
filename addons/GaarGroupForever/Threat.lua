--[[
  GaarGroupForever - Threat.lua: threat bars at the bottom of the bar (1.6.0).

  One bar per party member (you included) with the threat % against one mob, highest first, in
  class colour, with the name and the %. The member who has aggro (tanking) gets a gold row tint and
  the main-tank shield icon.

  The mob: your target when you can attack it, else your target's target when you can attack that
  (you target the tank: you see the threat on what the tank is fighting), else none. The section is
  shown only in a group (or in /ggf test) with such a mob; otherwise it is hidden and the bar shrinks.
  It is the last panel of the dock (Threat.lua is last in the TOCs), so it only ever moves the bar's
  bottom edge.

  Threat comes from UnitDetailedThreatSituation(member, mob) (isTanking, status, scaled %), with
  UnitThreatSituation as the fallback for the status. Updated on UNIT_THREAT_LIST_UPDATE,
  UNIT_THREAT_SITUATION_UPDATE, PLAYER_TARGET_CHANGED, UNIT_TARGET (target), GROUP_ROSTER_UPDATE and
  a 0.3 s OnUpdate that runs only while the section is shown (it is on a child of the section).

  Secret values (12.x engine, in combat): nothing here compares, sorts, tests or does sums on a value
  IsSecret reports. A secret % goes straight to the client: StatusBar:SetValue and
  FontString:SetFormattedText("%.0f%%") (as GaarPlatesForever does with secret health), each in
  pcall; when the client refuses, the bar is empty and the text is "?". While any member's % is
  secret the list is not sorted by %: it is ordered by the plain isTanking / status where they are
  readable, else kept in party order (you, party1-4). A secret isTanking goes to
  Texture:SetVertexColorFromBoolean, so the client itself tints the aggro row; without that API the
  aggro mark is left off. /ggf status says which of these paths is in use.

  Taint / combat: the bar is not a protected frame (no secure child: the two secure buttons of the
  role modules are children of UIParent anchored to UIParent), so this section may show, hide and
  resize it in combat. The dock's own layout (Overview.lua D.Layout) does not run in combat, so in
  combat this file places only its own panel, at the y the last out-of-combat layout left for it,
  and sets the bar's height; the panels above it do not move, so the secure overlays stay aligned.
  When that cannot be done safely (no layout yet, not TOP-anchored, not the last panel) the change
  waits for PLAYER_REGEN_ENABLED. No event the client keeps from addons is registered.
]]

local _G = _G
local API = _G.GaarGroupForeverAPI
local M = API and API._M
if not M or not M.Dock then return end

local BF = _G.GaarForever
local IsSecret, Num = BF.IsSecret, BF.Num

M.Defaults.threat = true

local T = { rows = {}, list = {}, mob = nil, via = nil, want = false, mode = "none", laid = false, laidN = 0,
    last = 0, combatLayouts = 0, deferred = 0 }
M.Threat = T

T.PAD, T.HEAD_H, T.BAR_H, T.GAP = 3, 14, 14, 2
T.INTERVAL = 0.3
T.TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar" -- the Blizzard bar look of GaarCastbarsForever
T.TANK_ICON = "Interface\\GroupFrame\\UI-Group-MainTankIcon"
T.AGGRO = { 1, 0.82, 0, 0.30 }
local TOP_POINTS = { TOP = true, TOPLEFT = true, TOPRIGHT = true }

local function Now()
    local t = type(_G.GetTime) == "function" and Num(_G.GetTime()) or nil
    return t or 0
end

-- ---------------------------------------------------------------------------
-- Logic (tested without a client)
-- ---------------------------------------------------------------------------

function T.Enabled() return M.db ~= nil and M.db.threat ~= false end

-- "yes", "no" or "maybe" (the client hides the answer): a unit that exists, is alive and is attackable.
function T.Attackable(unit)
    if not M.Q(_G.UnitExists, unit) then return "no" end
    if M.Q(_G.UnitIsDeadOrGhost, unit) then return "no" end
    if type(_G.UnitCanAttack) ~= "function" then return "no" end
    local ok, can = pcall(_G.UnitCanAttack, "player", unit)
    if not ok then return "no" end
    if IsSecret(can) then return "maybe" end
    return can and "yes" or "no"
end

-- The mob to measure: target when attackable, else targettarget when attackable (a secret answer
-- counts only when neither is plainly attackable). Returns the unit and "target" / "targettarget".
function T.MobUnit()
    local t, tt = T.Attackable("target"), T.Attackable("targettarget")
    if t == "yes" then return "target", "target" end
    if tt == "yes" then return "targettarget", "targettarget" end
    if t == "maybe" then return "target", "target" end
    if tt == "maybe" then return "targettarget", "targettarget" end
    return nil
end

-- Shown only with the bar, the option on, and in a group (or /ggf test).
function T.Active()
    if not T.Enabled() or not M.ShouldShow() then return false end
    return M.InGroup() or M.preview
end

-- You, then party1-4 that exist.
function T.Units()
    local list = { "player" }
    for i = 1, 4 do
        local u = "party" .. i
        if M.Q(_G.UnitExists, u) then list[#list + 1] = u end
    end
    return list
end

-- One member's threat on mob. Plain fields: tanking (bool|nil), status (number|nil), pct (number|nil).
-- Secret ones are kept apart and never looked at: tankFlag (+ hasFlag), pctRaw (+ pctSecret), statusSecret.
function T.Read(unit, mob, idx)
    local e = { unit = unit, idx = idx }
    local fn = _G.UnitDetailedThreatSituation
    if type(fn) == "function" then
        local ok, tanking, status, scaled = pcall(fn, unit, mob)
        if ok then
            if IsSecret(tanking) then e.tankFlag, e.hasFlag = tanking, true
            elseif tanking ~= nil then e.tanking = tanking and true or false end
            if IsSecret(status) then e.statusSecret = true else e.status = Num(status) end
            if IsSecret(scaled) then e.pctRaw, e.pctSecret = scaled, true else e.pct = Num(scaled) end
        end
    end
    if e.status == nil and not e.statusSecret and type(_G.UnitThreatSituation) == "function" then
        local ok, st = pcall(_G.UnitThreatSituation, unit, mob)
        if ok then
            if IsSecret(st) then e.statusSecret = true else e.status = Num(st) end
        end
    end
    if e.tanking == nil and not e.hasFlag and e.status then e.tanking = e.status >= 2 end
    e.secret = (e.pctSecret or e.statusSecret or e.hasFlag) and true or false
    return e
end

-- Sorts in place. Plain %: highest first (aggro first on a tie). Any secret %: by the plain aggro /
-- status only, else party order. Only plain sort keys are ever compared. Returns "plain" / "secret".
function T.Sort(list)
    local anySecret = false
    for _, e in ipairs(list) do if e.pctSecret then anySecret = true end end
    for _, e in ipairs(list) do
        e.kPct = (not anySecret and e.pct) or -1
        e.kTank = e.tanking == true and 1 or 0
        e.kStatus = e.status or -1
    end
    table.sort(list, function(a, b)
        if a.kPct ~= b.kPct then return a.kPct > b.kPct end
        if a.kTank ~= b.kTank then return a.kTank > b.kTank end
        if a.kStatus ~= b.kStatus then return a.kStatus > b.kStatus end
        return a.idx < b.idx
    end)
    return anySecret and "secret" or "plain"
end

-- Reads everything: T.want, T.mob, T.via, T.list (sorted), T.mode. Returns T.want.
function T.Compute()
    local mob, via
    if T.Active() then mob, via = T.MobUnit() end
    T.mob, T.via, T.list, T.mode = mob, via, {}, "none"
    if mob then
        for i, u in ipairs(T.Units()) do T.list[i] = T.Read(u, mob, i) end
        T.mode = T.Sort(T.list)
        for _, e in ipairs(T.list) do if e.hasFlag or e.statusSecret then T.mode = "secret" end end
    end
    T.want = mob ~= nil
    return T.want
end

function T.Height(n)
    if not n or n <= 0 then return nil end
    return T.PAD + T.HEAD_H + n * (T.BAR_H + T.GAP) - T.GAP + T.PAD
end

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------

local frame
local function EnsureFrame()
    if frame or not M.bar then return frame end
    frame = M.NewInset("GaarGroupForeverThreat", M.bar)
    local head = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    head:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -T.PAD)
    head:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -T.PAD)
    head:SetHeight(T.HEAD_H)
    head:SetJustifyH("LEFT")
    pcall(head.SetWordWrap, head, false)
    T.head = head
    for i = 1, 5 do
        local y = -(T.PAD + T.HEAD_H + (i - 1) * (T.BAR_H + T.GAP))
        local bar = _G.CreateFrame("StatusBar", nil, frame)
        bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, y)
        bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, y)
        bar:SetHeight(T.BAR_H)
        bar:SetStatusBarTexture(T.TEXTURE)
        bar:SetMinMaxValues(0, 100)
        bar:SetValue(0)
        local bg = bar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.5)
        local hl = bar:CreateTexture(nil, "ARTWORK", nil, 3) -- aggro tint over the fill
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 1)
        hl:SetBlendMode("ADD")
        hl:Hide()
        local icon = bar:CreateTexture(nil, "OVERLAY")
        icon:SetSize(T.BAR_H - 2, T.BAR_H - 2)
        icon:SetPoint("LEFT", bar, "LEFT", 1, 0)
        icon:SetTexture(T.TANK_ICON)
        icon:Hide()
        local name = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", bar, "LEFT", T.BAR_H + 1, 0)
        name:SetPoint("RIGHT", bar, "RIGHT", -40, 0)
        name:SetJustifyH("LEFT")
        pcall(name.SetWordWrap, name, false)
        local pct = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pct:SetPoint("RIGHT", bar, "RIGHT", -3, 0)
        pct:SetJustifyH("RIGHT")
        bar.hl, bar.icon, bar.name, bar.pct = hl, icon, name, pct
        bar:Hide()
        T.rows[i] = bar
    end
    -- The 0.3 s tick: a child of the section, so it runs only while the section is shown.
    local tick = _G.CreateFrame("Frame", nil, frame)
    local acc = 0
    tick:SetScript("OnUpdate", function(_, dt)
        acc = acc + (Num(dt) or 0)
        if acc < T.INTERVAL then return end
        acc = 0
        M.Safe("threat", T.Update)
    end)
    T.tick = tick
    frame:Hide()
    return frame
end
T.EnsureFrame = EnsureFrame

-- A text that may be secret: SetFormattedText hands it to the client untouched.
local function SetMaybeSecret(fs, fmt, v, fallback)
    if IsSecret(v) then
        if not pcall(fs.SetFormattedText, fs, fmt, v) then fs:SetText(fallback) end
    elseif type(v) == "string" and v ~= "" then
        fs:SetText(string.format(fmt, v))
    else
        fs:SetText(fallback)
    end
end

local aggroOn, aggroOff, iconOn, iconOff
local function Colors()
    if aggroOn or type(_G.CreateColor) ~= "function" then return aggroOn ~= nil end
    local a = T.AGGRO
    aggroOn, aggroOff = _G.CreateColor(a[1], a[2], a[3], a[4]), _G.CreateColor(1, 1, 1, 0)
    iconOn, iconOff = _G.CreateColor(1, 1, 1, 1), _G.CreateColor(1, 1, 1, 0)
    return true
end

-- Aggro mark: plain -> shown or hidden; secret -> the client picks the colour from its own flag.
local function PaintAggro(r, e)
    local hl, icon = r.hl, r.icon
    if e.hasFlag then
        local ok = Colors()
            and pcall(hl.SetVertexColorFromBoolean, hl, e.tankFlag, aggroOn, aggroOff)
            and pcall(icon.SetVertexColorFromBoolean, icon, e.tankFlag, iconOn, iconOff)
        if ok then hl:Show(); icon:Show(); return end
        hl:Hide(); icon:Hide()
        return
    end
    if e.tanking then
        local a = T.AGGRO
        hl:SetVertexColor(a[1], a[2], a[3], a[4]); hl:Show()
        icon:SetVertexColor(1, 1, 1, 1); icon:Show()
    else
        hl:Hide(); icon:Hide()
    end
end

local function PaintPct(r, e)
    if e.pctSecret then
        if not pcall(r.SetValue, r, e.pctRaw) then r:SetValue(0) end
        if not pcall(r.pct.SetFormattedText, r.pct, "%.0f%%", e.pctRaw) then r.pct:SetText("?") end
    elseif e.pct then
        local p = e.pct
        if p < 0 then p = 0 elseif p > 100 then p = 100 end
        r:SetValue(p)
        r.pct:SetText(string.format("%d%%", math.floor(e.pct + 0.5)))
    else
        r:SetValue(0)
        r.pct:SetText("-") -- not on the mob's threat list
    end
end

function T.Paint()
    if not frame then return end
    if not T.want then
        for _, r in ipairs(T.rows) do r:Hide() end
        return
    end
    local ok, mobName = false, nil
    if type(_G.UnitName) == "function" then ok, mobName = pcall(_G.UnitName, T.mob) end
    SetMaybeSecret(T.head, T.via == "targettarget" and "Threat: %s (target's target)" or "Threat: %s",
        ok and mobName or nil, "Threat")
    local cc = M.Overview and M.Overview.ClassColor
    for i, r in ipairs(T.rows) do
        local e = T.list[i]
        if not e then
            r:Hide()
        else
            local name = M.Q(_G.UnitName, e.unit)
            r.name:SetText(type(name) == "string" and name or "?")
            local class
            if type(_G.UnitClass) == "function" then
                local ok2, _, token = pcall(_G.UnitClass, e.unit)
                if ok2 and not IsSecret(token) and type(token) == "string" then class = token end
            end
            local cr, cg, cb = 0.6, 0.6, 0.6
            if cc then cr, cg, cb = cc(class) end
            r:SetStatusBarColor(cr, cg, cb, 0.9)
            M.Safe("threatpct", PaintPct, r, e)
            M.Safe("threataggro", PaintAggro, r, e)
            r:Show()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

-- In combat: only this (last) panel is placed, at the y the last full layout left for it, and the
-- bar's height follows. Returns true when done; false = wait for the end of combat.
function T.CombatLayout()
    local bar, D, MT = M.bar, M.Dock, M.Metrics
    if not bar or not D.lastTotal or T.panelIndex ~= #D.panels then return false end
    local p = bar:GetPoint(1)
    if not TOP_POINTS[p] then return false end
    local f = EnsureFrame()
    if not f then return false end
    local ys = D.lastYs or {}
    local base = ys[T.panelIndex + 1] or (D.lastTotal - MT.bottom + MT.gap)
    local h = T.want and T.Height(#T.list) or nil
    if h then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", bar, "TOPLEFT", MT.inset, -base)
        f:SetSize(MT.inner, h)
        f:Show()
        bar:SetHeight(base + h + MT.bottom)
    else
        f:Hide()
        bar:SetHeight(base - MT.gap + MT.bottom)
    end
    T.combatLayouts = T.combatLayouts + 1
    return true
end

-- Re-reads, repaints and, when the section appears / disappears / changes size, re-lays the bar out.
function T.Update()
    if not M.db then return end
    T.last = Now()
    T.Compute()
    local n = T.want and #T.list or 0
    if (T.want and true or false) ~= T.laid or n ~= T.laidN then
        if M.Q(_G.InCombatLockdown) then
            if T.CombatLayout() then T.laid, T.laidN = T.want and true or false, n
            else T.deferred = T.deferred + 1 end
        elseif M.bar and M.bar:IsShown() then
            M.Safe("dock", M.Dock.Update) -- calls the panel's height below, which records T.laid
        elseif frame then
            frame:Hide(); T.laid, T.laidN = false, 0
        end
    end
    T.Paint()
end

M.Dock.AddPanel({ getFrame = EnsureFrame, height = function()
    T.Compute()
    T.laid, T.laidN = T.want and true or false, T.want and #T.list or 0
    T.Paint()
    return T.want and T.Height(#T.list) or nil
end })
T.panelIndex = #M.Dock.panels

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

T.EVENTS = { "UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE", "PLAYER_TARGET_CHANGED", "UNIT_TARGET",
    "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD" }

function T.OnEvent(_, event, arg1)
    if not M.db then return end
    if event == "UNIT_TARGET" and arg1 ~= "target" then return end
    if event == "PLAYER_REGEN_ENABLED" then
        if M.bar and M.bar:IsShown() then M.Safe("dock", M.Dock.Update) end
        return M.Safe("threat", T.Update)
    end
    -- threat events can come in bursts: at most one read per 0.1 s here (the tick covers the rest)
    if (event == "UNIT_THREAT_LIST_UPDATE" or event == "UNIT_THREAT_SITUATION_UPDATE") and Now() - T.last < 0.1 then return end
    M.Safe("threat", T.Update)
end

T.events = _G.CreateFrame("Frame")
for _, ev in ipairs(T.EVENTS) do M.RegisterEvent(T.events, ev) end
T.events:SetScript("OnEvent", function(...) M.Safe("threatevent", T.OnEvent, ...) end)

-- ---------------------------------------------------------------------------
-- Settings, slash, status
-- ---------------------------------------------------------------------------

function T.SetEnabled(v)
    M.db.threat = v and true or false
    if M.Q(_G.InCombatLockdown) then M.Safe("threat", T.Update) end
    M.Refresh()
end

function T.StatusText()
    if not M.db then return "threat bars: not loaded yet" end
    local s = "threat bars: " .. (T.Enabled() and "on" or "off")
    if not T.Enabled() then return s end
    T.Compute()
    if not T.want then
        s = s .. " \194\183 hidden (" .. (T.Active() and "no attackable target or target's target" or "not in a group") .. ")"
    else
        s = s .. " \194\183 showing " .. #T.list .. " on your " .. (T.via == "targettarget" and "target's target" or "target")
            .. " \194\183 values " .. (T.mode == "secret" and "secret (shown by the client, not sorted by %)" or "plain (sorted by %)")
    end
    if T.deferred > 0 then s = s .. " \194\183 " .. T.deferred .. " combat resize(s) waited for combat to end" end
    return s
end

M.StatusParts[#M.StatusParts + 1] = function() return { T.StatusText() } end

M.MenuParts[#M.MenuParts + 1] = function()
    return {
        { text = "Threat bars (group, attackable target)", checkbox = true,
          checked = function() return M.db.threat ~= false end, func = function() T.SetEnabled(M.db.threat == false) end },
    }
end

M.Slash.threat = function(arg)
    if arg == "on" or arg == "off" then
        T.SetEnabled(arg == "on"); M.Print("threat bars " .. arg .. ".")
    elseif arg == "toggle" then
        T.SetEnabled(M.db.threat == false); M.Print("threat bars " .. (T.Enabled() and "on" or "off") .. ".")
    else
        M.Print(T.StatusText())
        M.Print("/ggf threat on | off | toggle")
    end
end

M.HelpParts[#M.HelpParts + 1] = function()
    return { "/ggf threat on|off|toggle - threat bars at the bottom, in a group with an attackable target or target's target (now "
        .. (T.Enabled() and "on" or "off") .. ")" }
end
