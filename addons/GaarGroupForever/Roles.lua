--[[
  GaarGroupForever - Roles.lua: the shared part of the role modules (Tank.lua, Healer.lua, Dps.lua).

  The modules are active only while your mode is that role (the bar's mode: the game's group role in
  a party, else the saved one) and the bar is shown. This file gives them
    * options     R.AddOption / R.Opt / R.SetOpt, saved in GaarGroupForeverDB.roles; every feature has one
                  (on by default), every option that types in chat is off by default
    * alerts      R.Alert(key, text, opts): a short line above the bar, throttled per key (and per group)
    * statuses    R.SetStatus(key, text): a line that stays while its condition holds (nil removes it)
    * a row       one insecure frame under the bar per role; a module builds its buttons in it ONCE, out of
                  combat
    * secure      R.Secure(row, x, y, w, h, template, name, live): a secure button (Healer tank frame, DPS
                  Assist) that is a child of UIParent, NOT of the bar or the row, laid over the row at x, y.
                  The bar and its dock can then show, hide, move and scale in combat without touching a
                  protected frame. R.SyncSecure() shows / hides / places it only out of combat (also on
                  PLAYER_REGEN_ENABLED); in combat it only changes its alpha (0 when the row is gone).
    * a scan      R.Scan(): hostile units around you (nameplates, target, focus, party members' targets)
                  with whether they target you / which party member
    * the tick    0.25 s OnUpdate and the events the modules ask for
    * slash       /ggf tank | healer | dps ...

  Taint and secret values: events, OnUpdate and our own frames only; no protected function is called
  from here. Every client call is in pcall and a secret result is treated as "unknown": R.B / R.Name
  return nil for it, and a warning that needs the value is simply skipped.
]]

local _G = _G
local API = _G.GaarGroupForeverAPI
local M = API and API._M
if not M then return end
local BF = _G.GaarForever
local IsSecret, Num, Str = BF.IsSecret, BF.Num, BF.Str

local R = {
    mods = {},       -- role key ("tank" ...) -> module
    order = { "tank", "healer", "dps" },
    options = {},    -- list of { role, key, text, default, short }
    defaults = {},   -- option key -> default
    status = {},     -- key -> { text, color }
    alerts = {},     -- { text, color, expire }
    last = {},       -- throttle: key -> time
    current = nil,   -- the active role key
    acc = 0,
    scan = nil, scanAt = -10,
}
M.Roles = R
M.Defaults.roles = {} -- saved in GaarGroupForeverDB.roles (option key -> value)

R.RED, R.YELLOW, R.GREEN, R.BLUE = { 1, 0.35, 0.35 }, { 1, 0.85, 0.2 }, { 0.45, 1, 0.45 }, { 0.55, 0.8, 1 }
R.TICK = 0.25
R.MAX_ALERTS = 3
R.SCAN_CACHE = 0.2

function R.Now()
    return type(_G.GetTime) == "function" and (Num(_G.GetTime()) or 0) or 0
end

-- A client call: its first result, or nil when missing, failing or secret.
function R.Q(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if not ok or IsSecret(v) then return nil end
    return v
end

-- A client boolean: true / false, or nil when missing, failing or secret (unknown).
function R.B(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if not ok or IsSecret(v) then return nil end
    return v and true or false
end

function R.Name(unit) return Str(R.Q(_G.UnitName, unit)) end

function R.InCombat()
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() and true or false
end

function R.Exists(unit) return R.B(_G.UnitExists, unit) == true end

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

-- role: "tank" / "healer" / "dps"; short: the /ggf <role> <short> on|off name; default: true unless it
-- types in chat (then false). kind "number": a value, not a checkbox (min/max/step).
function R.AddOption(role, key, text, default, short, extra)
    local o = { role = role, key = key, text = text, default = default, short = short }
    if extra then for k, v in pairs(extra) do o[k] = v end end
    R.options[#R.options + 1] = o
    R.defaults[key] = default
    return o
end

function R.Store()
    local db = M.db
    if type(db) ~= "table" then return nil end
    if type(db.roles) ~= "table" then db.roles = {} end
    return db.roles
end

function R.Opt(key)
    local s = R.Store()
    local v = s and s[key]
    local d = R.defaults[key]
    if type(d) == "number" then return Num(v) or d end
    if type(v) == "boolean" then return v end
    return d and true or false
end

function R.SetOpt(key, v)
    local s = R.Store()
    if not s or R.defaults[key] == nil then return false end
    if type(R.defaults[key]) == "number" then
        v = Num(tonumber(v))
        if not v then return false end
        s[key] = v
    else
        s[key] = v and true or false
    end
    R.Tick(true)
    return true
end

-- ---------------------------------------------------------------------------
-- Throttle, alerts, statuses (the logic is plain Lua and tested)
-- ---------------------------------------------------------------------------

-- Allowed when key has not fired within gap seconds (a clock that went backwards counts as allowed).
function R.Ready(key, gap, now)
    now = now or R.Now()
    local last = R.last[key]
    if last and now >= last and now - last < gap then return false end
    return true
end

function R.Throttle(key, gap, now)
    now = now or R.Now()
    if not R.Ready(key, gap, now) then return false end
    R.last[key] = now
    return true
end

-- Shows an alert line. opts: gap (seconds per key, default 5), group + groupGap (a shared limit across
-- keys, e.g. all lost-aggro lines), ttl (seconds shown, default 4), color. Returns true when shown.
function R.Alert(key, text, opts)
    opts = opts or {}
    if type(text) ~= "string" or text == "" then return false end
    local now = opts.now or R.Now()
    if not R.Ready(key, opts.gap or 5, now) then return false end
    if opts.group and not R.Ready(opts.group, opts.groupGap or 2, now) then return false end
    R.last[key] = now
    if opts.group then R.last[opts.group] = now end
    local list = R.alerts
    list[#list + 1] = { text = text, color = opts.color or R.YELLOW, expire = now + (opts.ttl or 4) }
    while #list > R.MAX_ALERTS do table.remove(list, 1) end
    R.Render()
    return true
end

function R.SetStatus(key, text, color)
    local cur = R.status[key]
    if text == nil or text == "" then
        if cur then R.status[key] = nil end
    elseif not cur or cur.text ~= text then
        R.status[key] = { text = text, color = color or R.YELLOW }
    elseif color then
        cur.color = color
    end
end

function R.ClearAll()
    R.status = {}
    R.alerts = {}
end

-- The lines to draw: statuses (by key) then live alerts. Expired alerts are dropped.
function R.Lines(now)
    now = now or R.Now()
    local out = {}
    local keys = {}
    for k in pairs(R.status) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = R.status[k] end
    local alive = {}
    for _, a in ipairs(R.alerts) do
        if a.expire > now then alive[#alive + 1] = a; out[#out + 1] = a end
    end
    R.alerts = alive
    return out
end

-- ---------------------------------------------------------------------------
-- Display: a click-through frame above the bar
-- ---------------------------------------------------------------------------

local LINE_H, MAX_LINES = 16, 8

function R.EnsureDisplay()
    if R.display or not M.bar then return R.display end
    local f = _G.CreateFrame("Frame", "GaarGroupForeverAlerts", M.bar)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(false)
    f:SetPoint("BOTTOM", M.bar, "TOP", 0, 4)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.55)
    f.lines = {}
    for i = 1, MAX_LINES do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("BOTTOM", f, "BOTTOM", 0, 3 + (i - 1) * LINE_H)
        f.lines[i] = fs
    end
    f:SetSize(240, LINE_H + 6)
    f:Hide()
    R.display = f
    return f
end

function R.Render()
    if not M.bar then return end
    local f = R.EnsureDisplay()
    if not f then return end
    local lines = R.Lines()
    local n = math.min(#lines, MAX_LINES)
    if n == 0 or not M.bar:IsShown() then f:Hide(); return end
    local widest = 0
    for i = 1, MAX_LINES do
        local fs = f.lines[i]
        local l = lines[i]
        if l and i <= n then
            fs:SetText(l.text)
            fs:SetTextColor(l.color[1], l.color[2], l.color[3])
            fs:Show()
            local w = Num(fs:GetStringWidth()) or 0
            if w > widest then widest = w end
        else
            fs:Hide()
        end
    end
    f:SetSize(math.max(120, widest + 16), n * LINE_H + 6)
    f:Show()
end

-- ---------------------------------------------------------------------------
-- The scan: hostile units and who they target (booleans only, nil = unknown/secret)
-- ---------------------------------------------------------------------------

function R.PartyUnits()
    local t = {}
    for i = 1, 4 do
        local u = "party" .. i
        if R.Exists(u) then t[#t + 1] = u end
    end
    return t
end

function R.ScanUnits()
    local t = { "target", "focus" }
    for i = 1, 40 do t[#t + 1] = "nameplate" .. i end
    for i = 1, 4 do t[#t + 1] = "party" .. i .. "target" end
    return t
end

-- Items { unit, name, onMe (true/false/nil), victim (party unit token or nil) } for every attackable,
-- living unit in combat. Cached for a moment: several features share one scan.
function R.Scan(now)
    now = now or R.Now()
    if R.scan and now >= R.scanAt and now - R.scanAt < R.SCAN_CACHE then return R.scan end
    local items, seen = {}, {}
    local party = R.PartyUnits()
    for _, u in ipairs(R.ScanUnits()) do
        if R.Exists(u) and R.B(_G.UnitCanAttack, "player", u) == true
            and R.B(_G.UnitIsDeadOrGhost, u) ~= true and R.B(_G.UnitAffectingCombat, u) == true then
            local key = Str(R.Q(_G.UnitGUID, u)) or u
            if not seen[key] then
                seen[key] = true
                local t = u .. "target"
                local item = { unit = u, name = R.Name(u), onMe = R.B(_G.UnitIsUnit, t, "player") }
                if item.onMe == false then
                    for _, p in ipairs(party) do
                        if R.B(_G.UnitIsUnit, t, p) == true then item.victim = p; break end
                    end
                end
                items[#items + 1] = item
            end
        end
    end
    R.scan, R.scanAt = items, now
    return items
end

-- Party member (not you) with this group role: the unit token, or nil.
function R.UnitByRole(role)
    for _, u in ipairs(R.PartyUnits()) do
        if R.Q(_G.UnitGroupRolesAssigned, u) == role then return u end
    end
end

-- Mana percent of a unit (0-100) when it uses mana and both numbers are readable, else nil.
function R.ManaPct(unit)
    if R.Q(_G.UnitPowerType, unit) ~= 0 then return nil end
    local cur, max = Num(R.Q(_G.UnitPower, unit, 0)), Num(R.Q(_G.UnitPowerMax, unit, 0))
    if not cur or not max or max <= 0 then return nil end
    return cur * 100 / max
end

function R.Say(text, channel)
    if type(_G.SendChatMessage) ~= "function" or not M.InGroup() then return false end
    return pcall(_G.SendChatMessage, text, channel or "PARTY") and true or false
end

-- ---------------------------------------------------------------------------
-- Modules, rows, tick
-- ---------------------------------------------------------------------------

-- mod: { build = function(row) -> width, height; tick = function(now); events = { EVENT = fn(...) };
--        refresh = function() (apply options to the row); deactivate = function(); entries = function() }
function R.Register(role, mod)
    R.mods[role] = mod
    mod.role = role
    if M.Dock and M.Dock.AddPanel then
        M.Dock.AddPanel({ getFrame = function() return mod.row end,
            height = function() return R.current == role and mod.row and mod.height or nil end })
    end
    if type(mod.events) == "table" then
        for ev in pairs(mod.events) do
            if R.frame then M.RegisterEvent(R.frame, ev) end
        end
    end
    return mod
end

-- The active role: the bar's mode, only while the bar is shown.
function R.ActiveRole()
    if not M.db or not M.ShouldShow() then return nil end
    local mode = M.ActiveMode()
    return mode and R.mods[mode] and mode or nil
end

function R.Active(role) return R.current == role end

function R.Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then M.Fail("roles " .. where, err) end
    return ok
end

-- A button for a role row: a plain bar button re-parented to the row.
function R.Button(row, name, text, width, onClick, tip)
    local b = M.TextButton(name, text, width)
    b:SetParent(row)
    b:SetScript("OnClick", function(_, ...) R.Safe(name, onClick, ...) end)
    if tip then M.Tip(b, tip) end
    return b
end

-- Secure buttons: never children of the bar (a hidden / moved / scaled insecure parent would carry the
-- protected child with it, which the client blocks in combat), never anchored to an insecure frame.
R.secure = {}

-- Creates the button (out of combat only: R.BuildRow guarantees it). live() -> true when it should be
-- shown and its unit attribute is current.
function R.Secure(row, x, y, w, h, template, name, live)
    if R.InCombat() then return nil end
    local f = _G.CreateFrame("Button", name, _G.UIParent, template)
    f:SetSize(w, h)
    f:SetFrameStrata("MEDIUM")
    if M.bar and type(M.bar.GetFrameLevel) == "function" then
        local lvl = Num(M.bar:GetFrameLevel())
        if lvl then f:SetFrameLevel(lvl + 10) end
    end
    f:Hide()
    R.secure[#R.secure + 1] = { frame = f, row = row, x = x, y = y, live = live }
    return f
end

local function Visible(fr)
    if not fr or type(fr.IsVisible) ~= "function" then return false end
    local ok, v = pcall(fr.IsVisible, fr)
    return ok and v == true
end

-- Places the secure button over its row (row's scale; the offsets are in the row's coordinates).
local function PlaceSecure(s)
    local f, row = s.frame, s.row
    local ui = _G.UIParent
    local ok, l, t, rs, us = pcall(function()
        return row:GetLeft(), row:GetTop(), row:GetEffectiveScale(), ui:GetEffectiveScale()
    end)
    l, t, rs, us = Num(l), Num(t), Num(rs), Num(us)
    if not ok or not l or not t or not rs or not us or us <= 0 then return end
    local scale = rs / us
    if s.l == l and s.t == t and s.scale == scale then return end
    s.l, s.t, s.scale = l, t, scale
    f:SetScale(scale)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", ui, "BOTTOMLEFT", l + s.x, t + s.y)
end

-- Out of combat: show (and place) or hide each secure button. In combat: alpha only.
function R.SyncSecure()
    local combat = R.InCombat()
    for _, s in ipairs(R.secure) do
        local f = s.frame
        local okLive, live = pcall(s.live)
        local want = Visible(s.row) and okLive and live == true
        if combat then
            f:SetAlpha(want and f:IsShown() and 1 or 0)
        else
            if want then PlaceSecure(s) end
            if want and not f:IsShown() then f:Show() elseif not want and f:IsShown() then f:Hide() end
            f:SetAlpha(want and 1 or 0)
        end
    end
end

function R.BuildRow(role)
    local mod = R.mods[role]
    if not mod or mod.row or not M.bar or R.InCombat() or type(mod.build) ~= "function" then return end
    local row = _G.CreateFrame("Frame", "GaarGroupForever" .. role .. "Row", M.bar)
    row:SetPoint("TOPLEFT", M.bar, "BOTTOMLEFT", 0, -2) -- the dock re-places it
    row:Hide()
    local ok, w, h = pcall(mod.build, row)
    if not ok then M.Fail("build " .. role, w); return end
    row:SetSize(Num(w) or 100, Num(h) or 26)
    mod.row, mod.height = row, Num(h) or 26
end

-- Show the active role's row (and hide the others); build it first when needed (out of combat).
function R.Sync()
    local role = R.ActiveRole()
    local changed = role ~= R.current
    if changed then
        local prev = R.mods[R.current]
        if prev and type(prev.deactivate) == "function" then R.Safe("deactivate", prev.deactivate) end
        R.ClearAll()
        R.current = role
    end
    local built = false
    local cur = R.mods[role]
    if cur and not cur.row then R.BuildRow(role); built = cur.row ~= nil end
    if changed or built then R.Dock() end
end

function R.Tick(force)
    if not M.db then return end
    R.Safe("tick", function()
        R.Sync()
        local mod = R.mods[R.current]
        if mod then
            if type(mod.refresh) == "function" then R.Safe("refresh", mod.refresh) end
            if type(mod.tick) == "function" then R.Safe("modtick", mod.tick, R.Now(), force) end
        end
        R.Render()
        R.SyncSecure()
    end)
end

function R.OnEvent(_, event, ...)
    if not M.db then return end
    if event == "PLAYER_REGEN_ENABLED" or event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ROLES_ASSIGNED" then
        R.scan = nil
        R.Tick(true)
    end
    local mod = R.mods[R.current]
    local fn = mod and type(mod.events) == "table" and mod.events[event]
    if type(fn) == "function" then R.Safe(event, fn, ...) end
    if event == "GROUP_ROSTER_UPDATE" then
        for _, m in pairs(R.mods) do
            if type(m.onRoster) == "function" then R.Safe("roster", m.onRoster) end
        end
    end
end

R.frame = _G.CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "GROUP_ROSTER_UPDATE", "PLAYER_ROLES_ASSIGNED" }) do
    M.RegisterEvent(R.frame, ev)
end
R.frame:SetScript("OnEvent", R.OnEvent)
R.frame:SetScript("OnUpdate", function(_, elapsed)
    R.acc = R.acc + (Num(elapsed) or 0)
    if R.acc < R.TICK then return end
    R.acc = 0
    R.Tick()
end)

-- The bar's own Refresh (mode, roster, role changes) re-syncs the rows at once. The rows are panels of
-- the shared dock under the bar (Overview.lua), which lays them out.
do
    local baseRefresh = M.Refresh
    M.Refresh = function(...)
        baseRefresh(...)
        if M.db then R.Safe("sync", R.Sync); R.Safe("secure", R.SyncSecure) end
    end
end

function R.Dock()
    if M.Dock and M.Dock.Update then M.Safe("dock", M.Dock.Update) end
end

-- ---------------------------------------------------------------------------
-- Menu and slash
-- ---------------------------------------------------------------------------

local ROLE_LABEL = { tank = "Tank", healer = "Healer", dps = "DPS" }
R.ROLE_LABEL = ROLE_LABEL

function R.MenuEntries()
    local e = {}
    for _, role in ipairs(R.order) do
        local mod = R.mods[role]
        if mod then
            if #e > 0 then e[#e + 1] = { divider = true } end
            e[#e + 1] = { label = ROLE_LABEL[role] .. " mode" }
            for _, o in ipairs(R.options) do
                if o.role == role then
                    if o.kind == "number" then
                        local subs = {}
                        for _, v in ipairs(o.values) do
                            subs[#subs + 1] = { text = v .. "%", radio = true,
                                checked = function() return R.Opt(o.key) == v end,
                                func = function() R.SetOpt(o.key, v) end }
                        end
                        e[#e + 1] = { text = o.text, submenu = subs }
                    else
                        e[#e + 1] = { text = o.text, checkbox = true,
                            checked = function() return R.Opt(o.key) end,
                            func = function() R.SetOpt(o.key, not R.Opt(o.key)) end }
                    end
                end
            end
            if type(mod.entries) == "function" then
                local ok, extra = pcall(mod.entries)
                if ok and type(extra) == "table" then
                    for _, x in ipairs(extra) do e[#e + 1] = x end
                end
            end
        end
    end
    return e
end

function R.PrintRole(role)
    local mod = R.mods[role]
    if not mod then return end
    M.Print(ROLE_LABEL[role] .. " mode (active only while that is your mode" ..
        (R.current == role and "; it is now" or "") .. "):")
    for _, o in ipairs(R.options) do
        if o.role == role then
            local v = R.Opt(o.key)
            M.Print("  /ggf " .. role .. " " .. o.short .. (o.kind == "number" and (" " .. o.values[1] .. "-" .. o.values[#o.values])
                or " on|off") .. " - " .. o.text .. " (now " .. (o.kind == "number" and tostring(v) or BF.OnOff(v)) .. ")")
        end
    end
    if type(mod.help) == "function" then
        for _, l in ipairs(mod.help()) do M.Print("  " .. l) end
    end
end

-- /ggf <role> ...: returns true when it handled the command.
function R.Slash(cmd, arg)
    local mod = R.mods[cmd]
    if not mod then return false end
    local sub, rest = (arg or ""):match("^(%S+)%s*(.*)$")
    if not sub then R.PrintRole(cmd); return true end
    if sub == "test" then
        if type(mod.demo) == "function" then R.Safe("demo", mod.demo) end
        M.Print(ROLE_LABEL[cmd] .. " demo shown (alerts above the bar).")
        return true
    end
    for _, o in ipairs(R.options) do
        if o.role == cmd and o.short == sub then
            if o.kind == "number" then
                local n = Num(tonumber(rest))
                if n and n >= o.values[1] and n <= o.values[#o.values] and R.SetOpt(o.key, n) then
                    M.Print(o.text .. ": " .. n)
                else
                    M.Print("/ggf " .. cmd .. " " .. sub .. " " .. o.values[1] .. "-" .. o.values[#o.values])
                end
            else
                local v = rest:lower()
                if v ~= "on" and v ~= "off" then v = R.Opt(o.key) and "off" or "on" end
                R.SetOpt(o.key, v == "on")
                M.Print(o.text .. ": " .. v)
            end
            return true
        end
    end
    if type(mod.slash) == "function" then
        local ok, handled = pcall(mod.slash, sub, rest)
        if ok and handled then return true end
    end
    R.PrintRole(cmd)
    return true
end

M.MenuParts[#M.MenuParts + 1] = function() return R.MenuEntries() end
M.HelpParts[#M.HelpParts + 1] = function()
    return { "/ggf tank | healer | dps - the role modules (options, actions; 'test' shows sample warnings)" }
end
for _, role in ipairs(R.order) do
    M.Slash[role] = function(arg) R.Slash(role, arg) end
end

-- Per-mode hook (M.ModeHooks): picking a mode re-syncs the rows and warnings at once.
for _, m in ipairs(M.Modes) do
    local prev = M.ModeHooks[m.key]
    M.ModeHooks[m.key] = function(key)
        if type(prev) == "function" then prev(key) end
        R.Tick(true)
    end
end
