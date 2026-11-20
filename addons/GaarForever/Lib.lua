--[[
  GaarForever - the shared core of the Gaar...Forever family, for WoW Forever.

  This file is loaded first (GaarForever.toc lists it before anything else) and every
  Gaar...Forever addon lists GaarForever under ## Dependencies, so the global table below is
  there before any of them runs a line. It only defines helpers: nothing here creates a frame,
  registers an event or touches a Blizzard function until an addon asks for it.

  Global: GaarForever (the library), also under its name before the folder rename, BetterForever.
  The hub's own API is GaarForeverAPI (Core.lua).

  Values (the client hands back "secret" values where it hides something: they may be passed to
  a widget, but comparing, testing or doing arithmetic on one is refused, so they are checked
  before anything else):
    GaarForever.IsSecret(v)      true for a secret value
    GaarForever.Plain(v)         v, or nil when it is secret
    GaarForever.Num(v)           a plain, finite number, else nil
    GaarForever.Str(v)           a plain, non-empty string, else nil
    GaarForever.Bool(v)          true / false, or nil when it is secret

  Names (3.2.27, characters have surnames - never compare names with == across sources):
    GaarForever.PlayerFullName() your whole name, "Dru Tics" where UnitName says "Dru"
    GaarForever.NamesMatch(a, b) same character: case/realm-insensitive, or first name vs full
    GaarForever.NameVariants(unit), GaarForever.UnitByName(name), GaarForever.StripRealm(name)

  Calls:
    GaarForever.API(ns, name)    the function _G[ns][name] (or _G[ns] when name is nil), else nil
    GaarForever.Call(fn, ...)    fn(...) in pcall; its results, or nothing when fn is missing or errors
    GaarForever.Method(o, name, ...)  o:name(...) the same way
    GaarForever.AddOnLoaded(name), GaarForever.InCombat()

  Text:
    GaarForever.OnOff(v)         "on" / "off"
    GaarForever.TimeShort(s)     "56", "2m", "1h", "3d" (rounded up; "" for 0, nil or secret)
    GaarForever.Clock(s)         "4:05", "1:02:03" ("--" for nil or secret)
    GaarForever.Coins(copper)    "1g 2s 3c" ("0c" for 0)
    GaarForever.ShortNumber(n)   "950", "12.3k", "1.2M"

  Menus:
    GaarForever.RenderMenu(root, entries, title)  draws MenuEntries() data into a MenuUtil description
    GaarForever.Report(err, title)  a click's error: one chat line and the error handler, once each
    GaarForever.IntroOf(api)     an addon API table's intro text (Intro() or intro), or nil
    GaarForever.AttachMenu(target, opts)  right-click a window or portrait opens the addon's menu (3.2.37)
    GaarForever.FindPortrait(frame, names)  the round portrait region of a Blizzard frame, or nil (3.2.37)

  Addons:
    GaarForever.DisplayName(name) "BetterBagsForever" -> "GaarBagsForever", the name users see (3.2)
    GaarForever.OldName(name)     "GaarBagsForever" -> "BetterBagsForever", the folder before the rename
    GaarForever.Migrate(new, old) copies the old folder's saved variable into the new one, once
    GaarForever.NewAddon(name, opts) -> addon object; see the README ("For addon authors") for
    :Print, :InitDB, :Toggle, :Choice, :Slider, :Button, :Divider, :Get, :Set, :MenuEntries,
    :Slash, :Run, :On and :API; since 3.1 also :ProfileMode, :SetProfileMode, :ExportSettings
    and :ImportSettings (per-character settings, export / import strings).

  Settings strings (3.1):
    GaarForever.CharKey()        "Name - Realm" of the logged-in character, or nil
    GaarForever.Serialize(t)     a table of strings, numbers, booleans and tables as text
    GaarForever.Deserialize(s)   the table back, parsed by hand (never loadstring), or nil, why
    GaarForever.Base64Encode(s), GaarForever.Base64Decode(s)
    GaarForever.EncodeSettings(name, t)  "BF1:<name>:<check>:<base64>"
    GaarForever.DecodeSettings(s)        name, t - or nil, why
    GaarForever.EncodeBundle(t)          "GFA1:<check>:<base64>", a larger table (/gf export all, 3.2.1)
    GaarForever.DecodeBundle(s)          t - or nil, why; parsed by hand with larger limits
]]

local _G = _G

local Lib = _G.GaarForever
if type(Lib) ~= "table" then
    Lib = {}
    _G.GaarForever = Lib
end
-- The name before the folder rename, for anything that still looks the library up by it. The
-- BetterForever folder is only a settings bridge now and defines nothing.
_G.BetterForever = Lib
Lib.version = "3.2.40"

local PREFIX_COLOR = "|cff33ff99"

-- ---------------------------------------------------------------------------
-- Values
-- ---------------------------------------------------------------------------

-- Looked up once at load; a client that defines it later is still asked (looked up per call
-- until it appears).
local issecretvalue = type(_G.issecretvalue) == "function" and _G.issecretvalue or nil

local function IsSecret(v)
    local f = issecretvalue
    if not f then
        f = _G.issecretvalue
        if type(f) ~= "function" then return false end
        issecretvalue = f
    end
    return f(v) and true or false
end

local function Plain(v)
    if IsSecret(v) then return nil end
    return v
end

local function Num(v)
    if IsSecret(v) or type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

local function Str(v)
    if IsSecret(v) or type(v) ~= "string" or v == "" then return nil end
    return v
end

local function Bool(v)
    if IsSecret(v) then return nil end
    return v and true or false
end

Lib.IsSecret, Lib.Plain, Lib.Num, Lib.Str, Lib.Bool = IsSecret, Plain, Num, Str, Bool

-- ---------------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------------

local function Pass(ok, ...)
    if ok then return ... end
end

function Lib.API(ns, name)
    if name == nil then
        local f = _G[ns]
        if type(f) == "function" then return f end
        return nil
    end
    local t = _G[ns]
    if type(t) ~= "table" then return nil end
    local f = t[name]
    if type(f) == "function" then return f end
    return nil
end

function Lib.Call(fn, ...)
    if type(fn) ~= "function" then return end
    return Pass(pcall(fn, ...))
end

-- ---------------------------------------------------------------------------
-- Names (3.2.27)
-- WoW Forever characters have surnames ("Dru Tics", with a space). UnitName may give only the
-- first name where chat senders, cast targets, the combat log and rosters give the whole thing,
-- so a name is never compared with == across sources: use these. Secret values are skipped.
-- ---------------------------------------------------------------------------

-- "Name-Realm" -> "Name" (a plain string only; anything else comes back nil).
function Lib.StripRealm(name)
    name = Str(name)
    if not name then return nil end
    return (name:gsub("%-[^%- ]+$", ""))
end
local StripRealm = Lib.StripRealm

-- Every plain spelling of a unit's name: UnitName, UnitFullName, GetUnitName(u, false / true),
-- each also without its realm. Empty when the unit has no readable name.
function Lib.NameVariants(unit)
    local out, seen = {}, {}
    local function add(n)
        n = Str(n)
        if n and not seen[n] then seen[n] = true; out[#out + 1] = n end
    end
    local function try(fn, ...)
        if type(fn) ~= "function" then return end
        local r = { pcall(fn, ...) }
        if not r[1] then return end
        local n, realm = Str(r[2]), Str(r[3])
        add(n)
        if n and realm then add(n .. "-" .. realm) end
    end
    try(_G.UnitName, unit)
    try(_G.UnitFullName, unit)
    try(_G.GetUnitName, unit, false)
    try(_G.GetUnitName, unit, true)
    for i = 1, #out do add(StripRealm(out[i])) end
    return out
end

-- The longest realm-less name the client gives for you ("Dru Tics" where UnitName says "Dru"),
-- or nil before it knows.
function Lib.PlayerFullName()
    local best
    for _, n in ipairs(Lib.NameVariants("player")) do
        n = StripRealm(n)
        if n and (not best or #n > #best) then best = n end
    end
    return best
end

-- True when two names are the same character: equal ignoring case and realm, or one is only the
-- first name of the other ("Dru" and "Dru Tics"). Secret or non-string values never match.
function Lib.NamesMatch(a, b)
    a, b = StripRealm(a), StripRealm(b)
    if not a or not b then return false end
    a, b = a:lower(), b:lower()
    if a == b then return true end
    if #a > #b then a, b = b, a end
    return b:sub(1, #a + 1) == a .. " "
end

local NAME_UNITS = { "player", "target", "focus", "mouseover", "pet", "targettarget" }
for i = 1, 4 do NAME_UNITS[#NAME_UNITS + 1] = "party" .. i end
for i = 1, 40 do NAME_UNITS[#NAME_UNITS + 1] = "raid" .. i end

-- The unit token (player, target, party1, raid7, ...) whose name is name: an exact spelling
-- first, then a unique "First Surname" prefix match, you winning a tie. Nil when none.
function Lib.UnitByName(name)
    name = Str(name)
    if not name then return nil end
    local cands, seenGuid = {}, {}
    for _, u in ipairs(NAME_UNITS) do
        local ok, ex = pcall(_G.UnitExists, u)
        if ok and ex == true and not IsSecret(ex) then
            local ok2, guid = pcall(_G.UnitGUID, u)
            guid = ok2 and Str(guid) or nil
            local key = guid or u
            if not seenGuid[key] then
                seenGuid[key] = true
                cands[#cands + 1] = { u = u, v = Lib.NameVariants(u) }
            end
        end
    end
    for _, c in ipairs(cands) do
        for _, n in ipairs(c.v) do
            if n == name then return c.u end
        end
    end
    local hits = {}
    for _, c in ipairs(cands) do
        for _, n in ipairs(c.v) do
            if name:sub(1, #n + 1) == n .. " " then hits[#hits + 1] = c; break end
        end
    end
    if #hits == 1 then return hits[1].u end
    for _, c in ipairs(hits) do
        if c.u == "player" then return "player" end
    end
    return nil
end

function Lib.Method(obj, name, ...)
    if type(obj) ~= "table" then return end
    local fn = obj[name]
    if type(fn) ~= "function" then return end
    return Pass(pcall(fn, obj, ...))
end

local function AskLoaded(f, name)
    if not f then return false end
    local ok, loaded = pcall(f, name)
    return ok and Bool(loaded) == true
end

-- Whether an addon is loaded: C_AddOns on newer clients; when that does not say yes (false, an
-- error, or missing), the old global is asked too.
function Lib.AddOnLoaded(name)
    if AskLoaded(Lib.API("C_AddOns", "IsAddOnLoaded"), name) then return true end
    return AskLoaded(Lib.API("IsAddOnLoaded"), name)
end

function Lib.InCombat()
    local f = _G.InCombatLockdown
    if type(f) ~= "function" then return false end
    return Bool(f()) == true
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

function Lib.OnOff(v) return v and "on" or "off" end

-- "45", "9m", "2h", "3d" from a plain number of seconds - rounded up, so 0 never shows while
-- something is still running. The format of GaarFramesForever's aura times and BetterBars'
-- cooldown numbers.
function Lib.TimeShort(left)
    left = Num(left)
    if not left or left <= 0 then return "" end
    local s = math.ceil(left)
    if s < 60 then return tostring(s) end
    if s < 3600 then return math.ceil(s / 60) .. "m" end
    if s < 86400 then return math.ceil(s / 3600) .. "h" end
    return math.ceil(s / 86400) .. "d"
end

-- "m:ss", or "h:mm:ss" from an hour up.
function Lib.Clock(sec)
    sec = Num(sec)
    if not sec or sec < 0 then return "--" end
    sec = math.floor(sec + 0.5)
    local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

-- "1g 2s 3c": only the parts that are there, "0c" for nothing.
function Lib.Coins(copper)
    copper = Num(copper)
    if not copper then return "?" end
    copper = math.floor(math.abs(copper))
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local out = {}
    if g > 0 then out[#out + 1] = g .. "g" end
    if s > 0 then out[#out + 1] = s .. "s" end
    if c > 0 or #out == 0 then out[#out + 1] = c .. "c" end
    return table.concat(out, " ")
end

function Lib.ShortNumber(n)
    n = Num(n)
    if not n then return "?" end
    local a = math.abs(n)
    if a >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if a >= 1e4 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end

-- ---------------------------------------------------------------------------
-- Menus
--
-- MenuEntries() data, the shape every Gaar...Forever addon hands the hub:
--   { text, func }                           a button
--   { text, checkbox = true, checked, func } a checkbox; func toggles
--   { text, radio = true, checked, func }    one choice of a group; func picks it
--   { text, submenu = { ... } }              a submenu (or, in the Options pages, a section)
--   { label = "..." }                        a line that cannot be clicked
--   { divider = true }                       a line between groups
--   { text, slider = true, min, max, step, value, set, format }   a number (new in 3.0)
-- ---------------------------------------------------------------------------

-- The number of steps from min to the largest value on the grid that is not above max.
local function GridSteps(lo, hi, step)
    return math.floor((hi - lo) / step + 1e-9)
end

-- At most about 25 values for a menu: every value on the grid, or every k-th one (k = ceil(n / 25))
-- across the whole range; the top of the range is always the last one.
local MENU_STEPS = 25
local function SliderValues(e)
    local lo, hi, step = Num(e.min), Num(e.max), Num(e.step) or 1
    if not lo or not hi or step <= 0 or hi < lo then return {} end
    local last = GridSteps(lo, hi, step)
    local stride = math.max(1, math.ceil((last + 1) / MENU_STEPS))
    local list = {}
    for i = 0, last, stride do list[#list + 1] = lo + i * step end
    if (last % stride) ~= 0 then list[#list + 1] = lo + last * step end
    return list
end
Lib.SliderValues = SliderValues

local function SliderText(e, v)
    if type(e.format) == "function" then
        local ok, s = pcall(e.format, v)
        if ok and s ~= nil then return tostring(s) end
    end
    return tostring(v)
end
Lib.SliderText = SliderText

local function Checked(e)
    if type(e.checked) ~= "function" then return false end
    local ok, v = pcall(e.checked)
    return ok and v and true or false
end

local function Click(e, title)
    if type(e.func) == "function" then
        local ok, err = pcall(e.func)
        if not ok then Lib.Report(err, title) end
    end
end

-- Errors from a menu click or an Options page: one chat line each, under the title of the addon
-- they came from (title; "GaarForever" when not given), and once each to the game's error
-- handler, so a tool such as BugSack has a copy. Each distinct error is reported once a session.
local reported = {}
function Lib.Report(err, title)
    err = tostring(err)
    title = (type(title) == "string" and title ~= "") and title or "GaarForever"
    local id = title .. "\0" .. err
    if reported[id] then return end
    reported[id] = true
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and type(chat.AddMessage) == "function" then
        chat:AddMessage(PREFIX_COLOR .. title .. "|r: " .. err)
    end
    local geh = _G.geterrorhandler
    if type(geh) == "function" then
        local okH, handler = pcall(geh)
        if okH and type(handler) == "function" then pcall(handler, title .. ": " .. err) end
    end
end

-- Draws the entries into a MenuUtil description (root or submenu); every method is checked first.
-- title: the addon the entries belong to, for the chat line of an error (see Lib.Report).
function Lib.RenderMenu(root, entries, title)
    if type(root) ~= "table" or type(entries) ~= "table" then return end
    for _, e in ipairs(entries) do
        if type(e) ~= "table" then
            -- skipped
        elseif e.divider then
            if type(root.CreateDivider) == "function" then root:CreateDivider() end
        elseif e.label then
            if type(root.CreateButton) == "function" then
                local d = root:CreateButton("|cff808080" .. tostring(e.label) .. "|r")
                if type(d) == "table" and type(d.SetEnabled) == "function" then pcall(d.SetEnabled, d, false) end
            end
        elseif e.submenu then
            local sub = type(root.CreateButton) == "function" and root:CreateButton(tostring(e.text))
            if type(sub) == "table" then Lib.RenderMenu(sub, e.submenu, title) end
        elseif e.slider then
            -- MenuUtil has no slider: a submenu of the steps, as radios.
            local sub = type(root.CreateButton) == "function" and root:CreateButton(tostring(e.text))
            if type(sub) == "table" then
                local radios = {}
                for _, v in ipairs(SliderValues(e)) do
                    radios[#radios + 1] = { text = SliderText(e, v), radio = true,
                        checked = function()
                            local ok, cur = pcall(e.value)
                            return ok and Num(cur) ~= nil and math.abs(cur - v) < 1e-6
                        end,
                        func = function()
                            if type(e.set) ~= "function" then return end
                            local ok, err = pcall(e.set, v)
                            if not ok then Lib.Report(err, title) end
                        end }
                end
                Lib.RenderMenu(sub, radios, title)
            end
        elseif e.checkbox and type(root.CreateCheckbox) == "function" then
            root:CreateCheckbox(tostring(e.text), function() return Checked(e) end, function() Click(e, title) end)
        elseif e.radio and type(root.CreateRadio) == "function" then
            root:CreateRadio(tostring(e.text), function() return Checked(e) end, function() Click(e, title) end)
        elseif (e.checkbox or e.radio) and type(root.CreateButton) == "function" then
            -- A menu without checkboxes or radios: the state goes in the label instead,
            -- "[x] " / "[ ] " for a checkbox, "(o) " / "( ) " for a radio.
            local mark
            if e.radio then mark = Checked(e) and "(o) " or "( ) " else mark = Checked(e) and "[x] " or "[ ] " end
            root:CreateButton(mark .. tostring(e.text), function() Click(e, title) end)
        elseif type(root.CreateButton) == "function" then
            root:CreateButton(tostring(e.text), function() Click(e, title) end)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Right-click a window: the addon's menu (3.2.37)
--
-- Lib.AttachMenu(target, opts) makes a right-click on target open the addon's menu, drawn by
-- MenuUtil.CreateContextMenu from the addon's MenuEntries (the same data the hub shows).
--   target  the frame to click. With opts.portrait it is the frame that OWNS the portrait.
--   opts.title    the addon's title, for the menu and its error line (required)
--   opts.entries  function returning the MenuEntries data (default: _G[opts.api].MenuEntries)
--   opts.api      the global API table name, e.g. "GaarBagsForeverAPI" (for the default entries)
--   opts.hook     true: our own frame, or a Blizzard frame that already takes the mouse: only a
--                 HookScript("OnMouseUp") that reacts to the RIGHT button. Nothing is replaced,
--                 left-click and dragging are untouched. No tooltip is added.
--   opts.portrait true: target's round portrait is not mouse-enabled, so a transparent 60x60
--                 Button of ours sits over it (strata of the frame, level +20, re-anchored on every
--                 OnShow), right-click only. Tooltip "Right-click: <title> menu".
--   opts.propagate true: a left-click also reaches a Blizzard button under the portrait
--   opts.names    extra global names for the portrait (see Lib.FindPortrait)
--   opts.name     global name of the overlay button (optional)
--   opts.hit      hook mode: a region the cursor must be over for the click to count
-- Created out of combat only (a pending one is finished when combat ends). A menu error is
-- printed once. Without MenuUtil a right-click prints a hint. Returns a handle:
--   h.Open(owner), h.Place(), h.button (overlay button or nil), h.Status() -> text
-- Calling it again for the same target returns the first handle.
-- ---------------------------------------------------------------------------

-- The round portrait of a Blizzard window, if one of the usual names has a sensible size (a
-- ButtonFrame's PortraitContainer can be a 1x1 holder). names: extra globals to try. Returns
-- region, path - or nil.
local function RegionSize(r)
    if type(r) ~= "table" or type(r.GetWidth) ~= "function" then return 0, 0 end
    local ok, w, h = pcall(function() return Num(r:GetWidth()) or 0, Num(r:GetHeight()) or 0 end)
    if ok then return w, h end
    return 0, 0
end

function Lib.FindPortrait(frame, names)
    if type(frame) ~= "table" then return nil end
    local cands = {}
    local function add(path, r) cands[#cands + 1] = { path, r } end
    local border = frame.BorderFrame
    for _, holder in ipairs({ { "BorderFrame", border }, { "frame", frame } }) do
        local h = holder[2]
        if type(h) == "table" then
            local pc = h.PortraitContainer
            add(holder[1] .. ".PortraitContainer", pc)
            add(holder[1] .. ".PortraitContainer.portrait", type(pc) == "table" and pc.portrait or nil)
            add(holder[1] .. ".portrait", h.portrait)
            add(holder[1] .. ".Portrait", h.Portrait)
            add(holder[1] .. ".PortraitFrame", h.PortraitFrame)
        end
    end
    for _, n in ipairs(names or {}) do add(n, _G[n]) end
    for _, c in ipairs(cands) do
        local r = c[2]
        if type(r) == "table" and type(r.GetObjectType) == "function" then
            local w, h = RegionSize(r)
            if w >= 30 and h >= 30 and w <= 120 and h <= 120 then return r, c[1] end
        end
    end
    return nil
end

local menuHandles = setmetatable({}, { __mode = "k" })
local menuPending = {}
local menuEvents

local function MenuPendingRun()
    local list = menuPending
    menuPending = {}
    for _, fn in ipairs(list) do pcall(fn) end
end

local function MenuPendingAdd(fn)
    menuPending[#menuPending + 1] = fn
    if not menuEvents and type(_G.CreateFrame) == "function" then
        local ok, f = pcall(_G.CreateFrame, "Frame")
        if ok and type(f) == "table" then
            menuEvents = f
            pcall(f.RegisterEvent, f, "PLAYER_REGEN_ENABLED")
            pcall(f.SetScript, f, "OnEvent", MenuPendingRun)
        end
    end
end

function Lib.AttachMenu(target, opts)
    if type(target) ~= "table" or type(opts) ~= "table" then return nil end
    if menuHandles[target] then return menuHandles[target] end
    local title = Str(opts.title) or "GaarForever"
    local h = { button = nil }
    local errShown = false

    local function Entries()
        if type(opts.entries) == "function" then return opts.entries() end
        local api = opts.api and _G[opts.api]
        if type(api) == "table" and type(api.MenuEntries) == "function" then return api.MenuEntries() end
    end

    function h.Open(owner)
        local MU = _G.MenuUtil
        if type(MU) == "table" and type(MU.CreateContextMenu) == "function" then
            local ok, err = pcall(MU.CreateContextMenu, owner or target, function(_, root)
                Lib.RenderMenu(root, Entries(), title)
            end)
            if not ok and not errShown then
                errShown = true
                local chat = _G.DEFAULT_CHAT_FRAME
                if chat and type(chat.AddMessage) == "function" then
                    chat:AddMessage(PREFIX_COLOR .. title .. "|r: the menu failed: " .. tostring(err))
                end
            end
            return
        end
        local chat = _G.DEFAULT_CHAT_FRAME
        if chat and type(chat.AddMessage) == "function" then
            chat:AddMessage(PREFIX_COLOR .. title .. "|r: the menu is not available on this client; use the slash command.")
        end
    end

    local function Place()
        local b = h.button
        if not b then return end
        local parent = target
        local region, path = nil, nil
        if opts.portrait then region, path = Lib.FindPortrait(target, opts.names) end
        h.foundAs = path
        b:ClearAllPoints()
        b:SetSize(60, 60)
        if region then
            b:SetPoint("CENTER", region, "CENTER", 0, 0)
        else
            local border = type(target.BorderFrame) == "table" and target.BorderFrame or target
            b:SetPoint("TOPLEFT", border, "TOPLEFT", -5, 7)
            parent = border
        end
        if type(parent.GetFrameStrata) == "function" and type(b.SetFrameStrata) == "function" then
            b:SetFrameStrata(parent:GetFrameStrata())
        end
        if type(parent.GetFrameLevel) == "function" then b:SetFrameLevel((Num(parent:GetFrameLevel()) or 0) + 20) end
        b:EnableMouse(true)
        -- A Blizzard button under the portrait (a bag window's) must keep its left-click.
        if opts.propagate and type(b.SetPropagateMouseClicks) == "function" then
            pcall(b.SetPropagateMouseClicks, b, true)
        end
    end
    h.Place = function()
        if h.button and not Lib.InCombat() then pcall(Place) end
    end

    local function Create()
        if h.button or h.hooked then h.Place() return end
        if Lib.InCombat() then
            if not h.queued then h.queued = true; MenuPendingAdd(function() h.queued = false; Create() end) end
            return
        end
        if opts.hook then
            if type(target.HookScript) ~= "function" then return end
            h.hooked = true
            pcall(target.HookScript, target, "OnMouseUp", function(_, button)
                if button ~= "RightButton" then return end
                if opts.hit and type(opts.hit) == "table" and type(opts.hit.IsMouseOver) == "function" then
                    local ok, over = pcall(opts.hit.IsMouseOver, opts.hit)
                    if ok and not over then return end
                end
                h.Open(target)
            end)
            return
        end
        local b = _G.CreateFrame("Button", opts.name, target)
        b:RegisterForClicks("RightButtonUp", "RightButtonDown")
        b:SetScript("OnClick", function(self, button, down)
            if button == "RightButton" and not down then h.Open(self) end
        end)
        b:SetScript("OnEnter", function(self)
            local tip = _G.GameTooltip
            if not tip then return end
            tip:SetOwner(self, "ANCHOR_RIGHT")
            tip:SetText("Right-click: " .. title:gsub("Forever$", "") .. " menu")
            tip:Show()
        end)
        b:SetScript("OnLeave", function()
            if _G.GameTooltip then _G.GameTooltip:Hide() end
        end)
        h.button = b
        Place()
    end

    function h.Status()
        if h.hooked then return "right-click: hooked on the window" end
        local b = h.button
        if not b then return "right-click button: not created" .. (h.queued and " (waiting for combat to end)" or "") end
        local w, hh = RegionSize(b)
        return string.format("right-click button: portrait region %s, size %dx%d, shown=%s",
            tostring(h.foundAs or "none (offset)"), w, hh, tostring(b.IsShown and b:IsShown() or false))
    end

    menuHandles[target] = h
    -- Re-anchor and re-raise on every show: Blizzard may re-level the portrait.
    if type(target.HookScript) == "function" then
        pcall(target.HookScript, target, "OnShow", function() Create() end)
    end
    Create()
    return h
end

-- An addon API table's intro: Intro() (a function returning a string) or intro (a string).
function Lib.IntroOf(api)
    if type(api) ~= "table" then return nil end
    if type(api.Intro) == "function" then
        local ok, s = pcall(api.Intro)
        if ok and type(s) == "string" and s ~= "" then return s end
    end
    if type(api.intro) == "string" and api.intro ~= "" then return api.intro end
    return nil
end

-- ---------------------------------------------------------------------------
-- Addon objects
-- ---------------------------------------------------------------------------

local Addon = {}
Addon.__index = Addon
Lib.AddonMixin = Addon

local addons = {}
Lib.addons = addons

local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = DeepCopy(x) end
    return t
end
Lib.DeepCopy = DeepCopy

-- Missing keys get the default (tables copied); a nested table is filled the same way.
local function MergeDefaults(t, defaults)
    if type(defaults) ~= "table" then return t end
    for k, v in pairs(defaults) do
        if t[k] == nil then
            t[k] = DeepCopy(v)
        elseif type(v) == "table" and type(t[k]) == "table" then
            MergeDefaults(t[k], v)
        end
    end
    return t
end
Lib.MergeDefaults = MergeDefaults

-- The name an addon is shown under. The folders were renamed too, so a family name is already
-- right; an old name (from an old settings string, say) gets "Better" swapped for "Gaar".
-- "BetterBagsForever" -> "GaarBagsForever".
function Lib.DisplayName(name)
    if type(name) ~= "string" then return name end
    return (name:gsub("^Better", "Gaar"))
end

-- The folder (and global prefix) a family addon had before the rename:
-- "GaarBagsForever" -> "BetterBagsForever", "GaarForever" -> "BetterForever"; nil for any other name.
function Lib.OldName(name)
    if type(name) ~= "string" or not name:match("^Gaar%w*Forever") then return nil end
    return (name:gsub("^Gaar", "Better"))
end

-- ---------------------------------------------------------------------------
-- Settings from the old folders
--
-- The family's folders were renamed BetterXForever -> GaarXForever. The client reads saved
-- variables by folder name, so each update also ships a small BetterXForever folder (a "settings
-- bridge": a TOC listing the old saved variables, no code) that each addon lists under
-- ## OptionalDeps, so the old settings are loaded first. At its own ADDON_LOADED, before its
-- defaults, each addon calls Lib.Migrate(newName, oldName) for each of its saved variables:
--   * the new one is nil or an empty table, and the old one a table not yet marked: the old one
--     is copied (deep, nothing shared), marked old.__migratedTo = newName, and one chat line per
--     addon says so;
--   * otherwise nothing happens: the bridge missing (old nil), already moved, or new settings.
-- Per-character saved variables work the same way, so each character moves on its own first
-- login. The old data is never deleted; the bridge folder may be deleted once moved.
-- ---------------------------------------------------------------------------

local MIGRATED_KEY = "__migratedTo"
Lib.MIGRATED_KEY = MIGRATED_KEY
local MIGRATE_MAX_DEPTH = 40

local function CopyTree(v, depth)
    if type(v) ~= "table" then return v end
    if depth > MIGRATE_MAX_DEPTH then error("nested too deep", 0) end
    local t = {}
    for k, x in pairs(v) do t[CopyTree(k, depth + 1)] = CopyTree(x, depth + 1) end
    return t
end

local migratedOwners = {}   -- owner -> true once its line is printed (or queued)
local migrateQueue, migrateFrame

local function MigrateLine(text)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and type(chat.AddMessage) == "function" then pcall(chat.AddMessage, chat, PREFIX_COLOR .. text) end
end

-- Lines wait for PLAYER_LOGIN (at ADDON_LOADED the chat frame may not show them yet).
local function AnnounceMigration(owner, oldName)
    if migratedOwners[owner] then return end
    migratedOwners[owner] = true
    local text = owner .. "|r: settings moved from " .. oldName .. " (the folder's old name). The "
        .. oldName .. " folder is only a bridge now; it may be deleted after logging in once on each character."
    local loggedIn = type(_G.IsLoggedIn) == "function" and Lib.Call(_G.IsLoggedIn)
    if loggedIn or type(_G.CreateFrame) ~= "function" then return MigrateLine(text) end
    migrateQueue = migrateQueue or {}
    migrateQueue[#migrateQueue + 1] = text
    if migrateFrame then return end
    local ok, f = pcall(_G.CreateFrame, "Frame")
    if not ok or not f then return MigrateLine(text) end
    migrateFrame = f
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        local list = migrateQueue or {}
        migrateQueue = nil
        for _, line in ipairs(list) do MigrateLine(line) end
    end)
end

-- Returns true when it copied. owner: the name for the chat line (default: newName without DB).
function Lib.Migrate(newName, oldName, owner)
    if type(newName) ~= "string" or type(oldName) ~= "string" or newName == oldName then return false end
    local new, old = _G[newName], _G[oldName]
    if type(old) ~= "table" or old[MIGRATED_KEY] ~= nil then return false end
    if new ~= nil and not (type(new) == "table" and next(new) == nil) then return false end
    local ok, copy = pcall(CopyTree, old, 0)
    if not ok or type(copy) ~= "table" then return false end
    copy[MIGRATED_KEY] = nil
    if type(new) == "table" then
        for k, v in pairs(copy) do new[k] = v end -- the same table: anything already bound to it sees the settings
    else
        _G[newName] = copy
    end
    old[MIGRATED_KEY] = newName
    owner = owner or (newName:gsub("CharDB$", ""):gsub("DB$", ""))
    AnnounceMigration(owner, (oldName:gsub("CharDB$", ""):gsub("DB$", "")))
    return true
end

-- opts: version (string), title (chat prefix; Lib.DisplayName(name) by default), intro (string),
-- status (function returning the status line), help (list of extra /x help lines).
function Lib.NewAddon(name, opts)
    opts = opts or {}
    local a = setmetatable({
        name = name,
        version = opts.version or "?",
        title = opts.title or Lib.DisplayName(name),
        intro = opts.intro,
        statusFn = opts.status,
        helpLines = opts.help or {},
        options = {},
        byKey = {},
        byCmd = {},
        blocked = {},
        blockedWhy = {},
    }, Addon)
    a.prefix = PREFIX_COLOR .. a.title .. "|r: "
    addons[#addons + 1] = a
    addons[name] = a
    return a
end

function Addon:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and type(chat.AddMessage) == "function" then chat:AddMessage(self.prefix .. table.concat(parts, " ")) end
end

-- ---------------------------------------------------------------------------
-- Per-character settings (3.1)
--
-- The saved variable stays what it was: the account-wide settings, read and written exactly as
-- before. A character that opts in gets its own copy, kept inside the same saved variable under
-- PER_CHAR_KEY, keyed "Name - Realm":
--   GaarLootForeverDB = { enabled = true, counts = true, ...,
--                           _perCharacter = { ["Elex - Forever"] = { enabled = true, counts = false } } }
-- A:InitDB binds A.db to that copy for such a character, to the shared table for every other one,
-- so A:Get / A:Set (and any code reading A.db) need not know. Old saved data is untouched: with no
-- _perCharacter entry every character keeps using the shared table.
-- ---------------------------------------------------------------------------

local PER_CHAR_KEY = "_perCharacter"
Lib.PER_CHAR_KEY = PER_CHAR_KEY

-- "Name - Realm" of the logged-in character, or nil before the client knows it.
function Lib.CharKey()
    local name = Str(Lib.Call(_G.UnitName, "player"))
    local realm = Str(Lib.Call(_G.GetRealmName))
    if not name or name == "Unknown" or name == (_G.UNKNOWNOBJECT or "Unknown") then return nil end
    return name .. " - " .. (realm or "?")
end

-- A copy of a settings table without the per-character copies.
local function SettingsCopy(t)
    local c = {}
    if type(t) ~= "table" then return c end
    for k, v in pairs(t) do
        if k ~= PER_CHAR_KEY then c[k] = DeepCopy(v) end
    end
    return c
end
Lib.SettingsCopy = SettingsCopy

local function FillOptionDefaults(self, t)
    for _, o in ipairs(self.options) do
        if o.key and t[o.key] == nil then t[o.key] = DeepCopy(o.default) end
    end
end

-- Every option's current value, to tell afterwards which ones a switch changed.
local function Snapshot(self)
    local s = {}
    for _, o in ipairs(self.options) do
        if o.key then s[o.key] = self:Get(o.key) end
    end
    return s
end

-- onChange(value, key, old) for every option whose value differs from before, then the addon's
-- own onProfileChanged(mode), if it has one (for settings that are not options).
local function NotifySwitch(self, before)
    for _, o in ipairs(self.options) do
        if o.key and type(o.onChange) == "function" then
            local v = self:Get(o.key)
            if v ~= before[o.key] then
                local ok, err = pcall(o.onChange, v, o.key, before[o.key])
                if not ok then self:Print("error: " .. tostring(err)) end
            end
        end
    end
    if type(self.onProfileChanged) == "function" then
        local ok, err = pcall(self.onProfileChanged, self.profile)
        if not ok then self:Print("error: " .. tostring(err)) end
    end
end

-- Points self.db at this character's copy when it has one, else at the shared table.
local function BindProfile(self)
    local shared = self.dbShared
    local key = Lib.CharKey()
    self.charKey = key
    local chars = shared[PER_CHAR_KEY]
    local own = key and type(chars) == "table" and chars[key]
    if type(own) == "table" then
        MergeDefaults(own, self.dbDefaults)
        FillOptionDefaults(self, own)
        self.db, self.profile = own, "character"
    else
        self.db, self.profile = shared, "shared"
    end
    return key ~= nil
end

-- Addons whose InitDB ran before the character's name was known: bound again at PLAYER_LOGIN.
local pendingBind, bindFrame
local function BindLater(self)
    pendingBind = pendingBind or {}
    pendingBind[#pendingBind + 1] = self
    if bindFrame or type(_G.CreateFrame) ~= "function" then return end
    bindFrame = _G.CreateFrame("Frame")
    bindFrame:RegisterEvent("PLAYER_LOGIN")
    bindFrame:SetScript("OnEvent", function(f)
        f:UnregisterAllEvents()
        local list = pendingBind or {}
        pendingBind = nil
        for _, a in ipairs(list) do
            local before = Snapshot(a)
            local okBind = pcall(BindProfile, a)
            if okBind and a.profile == "character" then NotifySwitch(a, before) end
        end
    end)
end

-- Binds the saved variable (call it at ADDON_LOADED, never at file scope): creates the table,
-- fills missing keys from defaults and from every registered option's default. A.db is this
-- character's own copy when it has one (see A:SetProfileMode), else the shared table.
function Addon:InitDB(globalName, defaults)
    local t = _G[globalName]
    if type(t) ~= "table" then
        t = {}
        _G[globalName] = t
    end
    MergeDefaults(t, defaults)
    FillOptionDefaults(self, t)
    self.dbName, self.dbShared, self.dbDefaults = globalName, t, defaults
    if not BindProfile(self) then BindLater(self) end
    return self.db
end

-- "character", "shared", or nil before InitDB.
function Addon:ProfileMode()
    if not self.dbShared then return nil end
    return self.profile or "shared"
end

-- mode "character": this character gets its own copy, seeded from the shared settings as they are
-- now (a character that already has one keeps it). mode "shared": the copy is dropped and the character uses the
-- shared settings again; the shared settings are never changed by either. Options whose value
-- changes get their onChange. Returns ok, message.
function Addon:SetProfileMode(mode)
    local shared = self.dbShared
    if not shared then return false, "its settings are not loaded yet" end
    local key = self.charKey or Lib.CharKey()
    if not key then return false, "the character's name is not known yet" end
    self.charKey = key
    if mode == self.profile then return true, mode end
    local before = Snapshot(self)
    if mode == "character" then
        local chars = shared[PER_CHAR_KEY]
        if type(chars) ~= "table" then
            chars = {}
            shared[PER_CHAR_KEY] = chars
        end
        local own = SettingsCopy(shared)
        chars[key] = own
        self.db, self.profile = own, "character"
    elseif mode == "shared" then
        local chars = shared[PER_CHAR_KEY]
        if type(chars) == "table" then
            chars[key] = nil
            if next(chars) == nil then shared[PER_CHAR_KEY] = nil end
        end
        self.db, self.profile = shared, "shared"
    else
        return false, "unknown mode " .. tostring(mode)
    end
    NotifySwitch(self, before)
    return true, mode
end

-- The settings in use (this character's copy or the shared ones) as an export string.
function Addon:ExportSettings()
    if not self.db then return nil, "its settings are not loaded yet" end
    return Lib.EncodeSettings(self.name, SettingsCopy(self.db))
end

-- Applies a table from DecodeSettings to the settings in use: only keys that are options, each
-- through A:Set (so checked against its kind, and onChange runs); a checkbox takes only a
-- boolean, a slider only a number. Returns applied, ignored (counts).
function Addon:ImportSettings(t)
    if not self.db or type(t) ~= "table" then return 0, 0 end
    local applied, ignored = 0, 0
    for k, v in pairs(t) do
        local o = type(k) == "string" and self.byKey[k] or nil
        local fits = o and (
            (o.kind == "checkbox" and type(v) == "boolean")
            or (o.kind == "slider" and type(v) == "number")
            or (o.kind == "choice" and (type(v) == "string" or type(v) == "number" or type(v) == "boolean")))
        if fits and self:Set(k, v) then
            applied = applied + 1
        else
            ignored = ignored + 1
        end
    end
    return applied, ignored
end

local function AddOption(self, o)
    self.options[#self.options + 1] = o
    if o.key then self.byKey[o.key] = o end
    if o.cmd then self.byCmd[o.cmd] = o end
    if o.key and self.db and self.db[o.key] == nil then self.db[o.key] = DeepCopy(o.default) end
    return o
end

-- A checkbox stored in db[key]. /x <cmd> on|off (cmd = key lower-cased unless opts.cmd), a
-- MenuEntries checkbox and, through the hub, a checkbox on the addon's Options page. The key
-- "enabled" is the master switch: /x on and /x off set it.
function Addon:Toggle(key, label, default, onChange, opts)
    opts = opts or {}
    return AddOption(self, { kind = "checkbox", key = key, label = label, default = default and true or false,
        onChange = onChange, cmd = opts.cmd or key:lower(), tooltip = opts.tooltip })
end

-- One of a list of values, stored in db[key]. values: { v1, v2 } or { { value = v, label = "..." } }.
-- A submenu of radios in the menu, a dropdown on the Options page, /x <cmd> <value>.
function Addon:Choice(key, label, values, default, onChange, opts)
    opts = opts or {}
    local list = {}
    for _, v in ipairs(values) do
        if type(v) == "table" then
            list[#list + 1] = { value = v.value, label = v.label or tostring(v.value) }
        else
            list[#list + 1] = { value = v, label = tostring(v) }
        end
    end
    return AddOption(self, { kind = "choice", key = key, label = label, values = list, default = default,
        onChange = onChange, cmd = opts.cmd or key:lower(), tooltip = opts.tooltip })
end

-- A number from min to max in steps, stored in db[key]. format(v) gives its text. A step that is
-- not a positive number becomes 1.
function Addon:Slider(key, label, min, max, step, default, onChange, format, opts)
    opts = opts or {}
    step = Num(step)
    if not step or step <= 0 then step = 1 end
    return AddOption(self, { kind = "slider", key = key, label = label, min = min, max = max, step = step,
        default = default, onChange = onChange, format = format, cmd = opts.cmd or key:lower(), tooltip = opts.tooltip })
end

-- A button; with opts.cmd, /x <cmd> runs it too.
function Addon:Button(label, func, opts)
    opts = opts or {}
    return AddOption(self, { kind = "button", label = label, func = func, cmd = opts.cmd })
end

function Addon:Divider()
    return AddOption(self, { kind = "divider" })
end

function Addon:Get(key)
    local o = self.byKey[key]
    local v = self.db and self.db[key]
    if v == nil and o then v = o.default end
    return v
end

-- Sets an option, checked against its kind, writes it to the db and then calls
-- onChange(value, key, old) in pcall. A slider value is snapped to the step grid, then clamped to
-- min .. the largest grid value not above max. Returns true when the value was accepted.
function Addon:Set(key, value)
    local o = self.byKey[key]
    if not o or not self.db then return false end
    if o.kind == "checkbox" then
        value = value and true or false
    elseif o.kind == "choice" then
        local found
        for _, c in ipairs(o.values) do
            if c.value == value then found = true end
        end
        if not found then return false end
    elseif o.kind == "slider" then
        value = Num(tonumber(value))
        if not value then return false end
        local lo, hi, step = Num(o.min), Num(o.max), o.step
        if lo then
            value = lo + math.floor((value - lo) / step + 0.5) * step
            if value < lo then value = lo end
            if hi and hi >= lo then
                local top = lo + GridSteps(lo, hi, step) * step
                if value > top then value = top end
            end
        end
    end
    local old = self.db[key]
    self.db[key] = value
    if type(o.onChange) == "function" then
        local ok, err = pcall(o.onChange, value, key, old)
        if not ok then self:Print("error: " .. tostring(err)) end
    end
    return true
end

-- The options as MenuEntries() data: the same list the hub's menu and Options page read.
function Addon:MenuEntries()
    local list = {}
    for _, o in ipairs(self.options) do
        if o.kind == "checkbox" then
            list[#list + 1] = { text = o.label, checkbox = true,
                checked = function() return self:Get(o.key) and true or false end,
                func = function() self:Set(o.key, not self:Get(o.key)) end }
        elseif o.kind == "choice" then
            local sub = {}
            for _, c in ipairs(o.values) do
                sub[#sub + 1] = { text = c.label, radio = true,
                    checked = function() return self:Get(o.key) == c.value end,
                    func = function() self:Set(o.key, c.value) end }
            end
            list[#list + 1] = { text = o.label, submenu = sub }
        elseif o.kind == "slider" then
            list[#list + 1] = { text = o.label, slider = true, min = o.min, max = o.max, step = o.step,
                value = function() return self:Get(o.key) end,
                set = function(v) self:Set(o.key, v) end,
                format = o.format }
        elseif o.kind == "button" then
            list[#list + 1] = { text = o.label, func = o.func }
        elseif o.kind == "divider" then
            list[#list + 1] = { divider = true }
        end
    end
    return list
end

function Addon:StatusLine()
    if type(self.statusFn) == "function" then
        local ok, s = pcall(self.statusFn)
        if ok and s ~= nil then return tostring(s) end
    end
    if not self.db then return "not loaded yet" end
    if self.byKey.enabled then return Lib.OnOff(self:Get("enabled")) end
    return "loaded"
end

local function ValueText(o, v)
    if o.kind == "checkbox" then return Lib.OnOff(v) end
    if o.kind == "choice" then
        for _, c in ipairs(o.values) do
            if c.value == v then return c.label end
        end
    end
    if o.kind == "slider" then return SliderText(o, v) end
    return tostring(v)
end

function Addon:PrintHelp()
    if self.intro then self:Print(self.intro) end
    local slash = self.slash or ("/" .. self.title:lower())
    if self.byKey.enabled then
        self:Print(slash .. " on | off - " .. self.byKey.enabled.label .. " (now " .. Lib.OnOff(self:Get("enabled")) .. ")")
    end
    for _, o in ipairs(self.options) do
        if o.cmd and o.key ~= "enabled" then
            if o.kind == "checkbox" then
                self:Print(string.format("%s %s on|off - %s (now %s)", slash, o.cmd, o.label, ValueText(o, self:Get(o.key))))
            elseif o.kind == "choice" then
                local vals = {}
                for _, c in ipairs(o.values) do vals[#vals + 1] = tostring(c.value) end
                self:Print(string.format("%s %s %s - %s (now %s)", slash, o.cmd, table.concat(vals, "|"), o.label,
                    ValueText(o, self:Get(o.key))))
            elseif o.kind == "slider" then
                self:Print(string.format("%s %s <%s-%s> - %s (now %s)", slash, o.cmd, tostring(o.min), tostring(o.max),
                    o.label, ValueText(o, self:Get(o.key))))
            elseif o.kind == "button" then
                self:Print(string.format("%s %s - %s", slash, o.cmd, o.label))
            end
        end
    end
    for _, line in ipairs(self.helpLines) do self:Print(line) end
    self:Print(slash .. " status - version, settings and what was switched off this session")
end

function Addon:PrintStatus()
    self:Print("version " .. tostring(self.version) .. ": " .. self:StatusLine())
    for _, o in ipairs(self.options) do
        if o.key then self:Print("  " .. o.label .. ": " .. ValueText(o, self:Get(o.key))) end
    end
    for feature, why in pairs(self.blockedWhy) do
        self:Print("  switched off this session: " .. feature .. " (" .. why .. ")")
    end
    if self.lastError then self:Print("  last error: " .. tostring(self.lastError)) end
end

local function OnOffWord(w)
    if w == "on" or w == "1" or w == "true" or w == "yes" then return true end
    if w == "off" or w == "0" or w == "false" or w == "no" then return false end
    return nil
end

local NOT_READY = "not ready yet - its settings load with the addon; try again in a moment."

function Addon:HandleSlash(msg)
    msg = tostring(msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    local lcmd = (cmd or ""):lower()
    rest = rest or ""
    local h = self.handlers and self.handlers[lcmd]
    if type(h) == "function" then return h(rest, msg) end
    if lcmd == "" or lcmd == "help" then return self:PrintHelp() end
    if lcmd == "status" then return self:PrintStatus() end
    if (lcmd == "on" or lcmd == "off") and self.byKey.enabled then
        if not self.db then return self:Print(NOT_READY) end
        self:Set("enabled", lcmd == "on")
        return self:Print(self.byKey.enabled.label .. ": " .. lcmd)
    end
    local o = self.byCmd[lcmd]
    if not o then return self:PrintHelp() end
    local word = rest:lower()
    if o.kind == "button" then
        local ok, err = pcall(o.func)
        if not ok then self:Print("error: " .. tostring(err)) end
        return
    end
    if word == "" and o.kind ~= "checkbox" then
        return self:Print(o.label .. ": " .. ValueText(o, self:Get(o.key)))
    end
    local value
    if o.kind == "checkbox" then
        if word == "" then value = not self:Get(o.key) else value = OnOffWord(word) end
    elseif o.kind == "choice" then
        for _, c in ipairs(o.values) do
            if tostring(c.value):lower() == word or tostring(c.label):lower() == word then value = c.value end
        end
    elseif o.kind == "slider" then
        value = tonumber(word)
    end
    if not self.db then return self:Print(NOT_READY) end
    if value == nil or not self:Set(o.key, value) then
        return self:Print("unknown value for " .. o.cmd .. ": " .. rest)
    end
    self:Print(o.label .. ": " .. ValueText(o, self:Get(o.key)))
end

-- Registers the slash commands: cmds = { "/x", "/longname" }. handlers[word] = function(rest, msg)
-- runs before the built-ins (help, status, on|off, and one command per option with a cmd).
function Addon:Slash(cmds, handlers)
    self.handlers = handlers or {}
    self.slash = cmds[1]
    local id = (self.name:upper():gsub("[^%w]", ""))
    for i, c in ipairs(cmds) do _G["SLASH_" .. id .. i] = c end
    _G.SlashCmdList[id] = function(msg)
        local ok, err = pcall(self.HandleSlash, self, msg)
        if not ok then self:Print("error: " .. tostring(err)) end
    end
end

-- Runs fn(...) in pcall under a feature name. The first error switches that feature off for the
-- session (one chat line says so) and later calls return at once: a client that refuses an API
-- costs one message, not one error per frame.
function Addon:IsBlocked(feature) return self.blocked[feature] and true or false end

function Addon:Latch(feature, err)
    if self.blocked[feature] then return end
    self.blocked[feature] = true
    self.blockedWhy[feature] = tostring(err)
    self:Print("this client will not let an addon do " .. tostring(feature)
        .. " - that part is off for this session. (" .. tostring(err) .. ")")
end

local function Finish(self, feature, ok, ...)
    if ok then return ... end
    self:Latch(feature, (...))
end

function Addon:Run(feature, fn, ...)
    if self.blocked[feature] then return end
    return Finish(self, feature, pcall(fn, ...))
end

-- Events: handler(event, ...) in pcall; an event may have several handlers, run in the order they
-- were added (the same handler twice is kept once). The last error is kept for /x status.
function Addon:On(event, handler)
    if type(handler) ~= "function" then return end
    if not self.events then
        self.events = {}
        self.eventFrame = CreateFrame("Frame")
        self.eventFrame:SetScript("OnEvent", function(_, ev, ...)
            local list = self.events[ev]
            if not list then return end
            for i = 1, #list do
                local ok, err = pcall(list[i], ev, ...)
                if not ok then self.lastError = ev .. ": " .. tostring(err) end
            end
        end)
    end
    local list = self.events[event]
    if not list then
        list = {}
        self.events[event] = list
    end
    for _, h in ipairs(list) do
        if h == handler then return end
    end
    list[#list + 1] = handler
    pcall(self.eventFrame.RegisterEvent, self.eventFrame, event)
end

-- Builds and exports _G[name .. "API"], the table the hub reads: version, StatusLine, MenuEntries,
-- AddMenuEntries, SetMinimapHidden (does nothing) and Intro. extra overrides or adds fields.
function Addon:API(extra)
    local api = {
        version = self.version,
        StatusLine = function() return self:StatusLine() end,
        MenuEntries = function() return self:MenuEntries() end,
        AddMenuEntries = function(root) Lib.RenderMenu(root, self:MenuEntries(), self.title) end,
        SetMinimapHidden = function() end,
        Intro = function() return self.intro end,
    }
    for k, v in pairs(extra or {}) do api[k] = v end
    _G[self.name .. "API"] = api
    local old = Lib.OldName(self.name)
    if old then _G[old .. "API"] = api end -- the name before the folder rename
    self.api = api
    return api
end

-- ---------------------------------------------------------------------------
-- Settings strings (3.1)
--
-- A settings table as text a player can copy out of the game and paste back in:
--   "BF1:<AddonName>:<check>:<base64 of the serialized table>"
-- Serialized: S<len>:<bytes> a string, N<number>; a number, B1 / B0 a boolean, T ... E a table of
-- key, value pairs (keys are strings or numbers). Functions, userdata and secret values are left
-- out. Reading it back is a hand-written parser with limits on size, depth and the number of
-- values: nothing in the text is ever run as code (no loadstring).
-- ---------------------------------------------------------------------------

local MAX_DEPTH = 12
local MAX_NODES = 5000
local MAX_TEXT = 200000

local function Storable(v)
    if IsSecret(v) then return false end
    local t = type(v)
    if t == "number" then return v == v and v ~= math.huge and v ~= -math.huge end
    return t == "string" or t == "boolean" or t == "table"
end

local function KeyOrder(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta == "number" end
    return a < b
end

local function SerializeValue(v, out, depth, maxDepth)
    local t = type(v)
    if t == "string" then
        out[#out + 1] = "S" .. #v .. ":" .. v
    elseif t == "number" then
        out[#out + 1] = "N" .. string.format("%.17g", v) .. ";"
    elseif t == "boolean" then
        out[#out + 1] = v and "B1" or "B0"
    elseif t == "table" then
        if depth >= (maxDepth or MAX_DEPTH) then error("nested too deep", 0) end
        local keys = {}
        for k, x in pairs(v) do
            local kt = type(k)
            if (kt == "string" or kt == "number") and Storable(k) and Storable(x) then keys[#keys + 1] = k end
        end
        table.sort(keys, KeyOrder)
        out[#out + 1] = "T"
        for _, k in ipairs(keys) do
            SerializeValue(k, out, depth + 1, maxDepth)
            SerializeValue(v[k], out, depth + 1, maxDepth)
        end
        out[#out + 1] = "E"
    end
end

-- The text, or nil, why. limits (optional): { depth = n }.
function Lib.Serialize(t, limits)
    if type(t) ~= "table" then return nil, "not a table" end
    local out = {}
    local ok, err = pcall(SerializeValue, t, out, 0, type(limits) == "table" and limits.depth or nil)
    if not ok then return nil, tostring(err) end
    return table.concat(out)
end

-- The parser: a value from s at pos; returns value, next pos. Errors (caught by Deserialize) on
-- anything it does not expect.
local function ParseValue(s, pos, depth, budget)
    budget.n = budget.n + 1
    if budget.n > budget.nodes then error("too many values", 0) end
    local tag = s:sub(pos, pos)
    if tag == "S" then
        local len, p = s:match("^(%d+):()", pos + 1)
        len = tonumber(len)
        if not len or len > budget.text then error("bad string at " .. pos, 0) end
        local str = s:sub(p, p + len - 1)
        if #str ~= len then error("string cut short at " .. pos, 0) end
        return str, p + len
    elseif tag == "N" then
        local num, p = s:match("^([%-%+%d%.eE]+);()", pos + 1)
        local v = tonumber(num)
        if not v or v ~= v or v == math.huge or v == -math.huge then error("bad number at " .. pos, 0) end
        return v, p
    elseif tag == "B" then
        local b = s:sub(pos + 1, pos + 1)
        if b == "1" then return true, pos + 2 end
        if b == "0" then return false, pos + 2 end
        error("bad boolean at " .. pos, 0)
    elseif tag == "T" then
        if depth >= budget.depth then error("nested too deep", 0) end
        local t = {}
        pos = pos + 1
        while true do
            local c = s:sub(pos, pos)
            if c == "E" then return t, pos + 1 end
            if c == "" then error("table not closed", 0) end
            local k, v
            k, pos = ParseValue(s, pos, depth + 1, budget)
            if type(k) ~= "string" and type(k) ~= "number" then error("bad key at " .. pos, 0) end
            v, pos = ParseValue(s, pos, depth + 1, budget)
            t[k] = v
        end
    end
    error("unexpected '" .. tag .. "' at " .. pos, 0)
end

-- The table, or nil, why. Only a table at the top, and nothing after it. limits (optional):
-- { text = max length, nodes = max values, depth = max nesting }; the defaults suit one addon.
function Lib.Deserialize(s, limits)
    if type(s) ~= "string" or IsSecret(s) then return nil, "not text" end
    limits = type(limits) == "table" and limits or {}
    local budget = { n = 0, text = limits.text or MAX_TEXT, nodes = limits.nodes or MAX_NODES, depth = limits.depth or MAX_DEPTH }
    if #s > budget.text then return nil, "too long" end
    if s:sub(1, 1) ~= "T" then return nil, "not a settings table" end
    local ok, v, nextPos = pcall(ParseValue, s, 1, 0, budget)
    if not ok then return nil, tostring(v) end
    if nextPos ~= #s + 1 then return nil, "extra text after the settings" end
    return v
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64Index = {}
for i = 1, 64 do B64Index[B64:byte(i)] = i - 1 end

local function B64Char(n) return B64:sub(n + 1, n + 1) end

function Lib.Base64Encode(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = B64Char(math.floor(n / 262144) % 64) .. B64Char(math.floor(n / 4096) % 64)
            .. (b and B64Char(math.floor(n / 64) % 64) or "=") .. (c and B64Char(n % 64) or "=")
    end
    return table.concat(out)
end

-- The bytes, or nil for text that is not base64.
function Lib.Base64Decode(s)
    if type(s) ~= "string" or #s % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, #s, 4 do
        local q = { s:byte(i, i + 3) }
        local pad = 0
        local n = 0
        for j = 1, 4 do
            local v = B64Index[q[j]]
            if q[j] == 61 and i + 3 == #s and j >= 3 then -- "=" padding, only at the very end
                pad = pad + 1
                v = 0
            elseif v == nil or pad > 0 then
                return nil
            end
            n = n * 64 + v
        end
        local a, b, c = math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
        if pad == 0 then
            out[#out + 1] = string.char(a, b, c)
        elseif pad == 1 then
            out[#out + 1] = string.char(a, b)
        else
            out[#out + 1] = string.char(a)
        end
    end
    return table.concat(out)
end

-- Fletcher-style check of the serialized text, 8 hex digits: a cut-off paste is caught.
local function Check(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%04x%04x", b, a)
end

function Lib.EncodeSettings(name, t)
    if type(name) ~= "string" or not name:match("^[%w_]+$") then return nil, "bad addon name" end
    local body, err = Lib.Serialize(t)
    if not body then return nil, err end
    return "BF1:" .. name .. ":" .. Check(body) .. ":" .. Lib.Base64Encode(body)
end

-- name, table - or nil, why. Spaces and line breaks in the pasted text are ignored.
function Lib.DecodeSettings(s)
    if type(s) ~= "string" or IsSecret(s) then return nil, "not text" end
    if #s > MAX_TEXT * 2 then return nil, "too long" end
    s = s:gsub("%s+", "")
    if s == "" then return nil, "nothing pasted" end
    local name, check, b64 = s:match("^BF1:([%w_]+):(%x%x%x%x%x%x%x%x):([%w%+/=]+)$")
    if not name then return nil, "not a GaarForever settings string" end
    local body = Lib.Base64Decode(b64)
    if not body then return nil, "the string is damaged (not base64)" end
    if Check(body) ~= check:lower() then return nil, "the string is damaged or cut short" end
    local t, err = Lib.Deserialize(body)
    if not t then return nil, err end
    return name, t
end

-- ---------------------------------------------------------------------------
-- Settings bundles (3.2.1): every family addon's saved variables in one string, for /gf export
-- all and /gf import. "GFA1:<check>:<base64 of the serialized table>", the same serializer and
-- hand-written parser as above, with limits sized for a whole account's settings.
-- ---------------------------------------------------------------------------

local BUNDLE_LIMITS = { text = 4000000, nodes = 200000, depth = 24 }
Lib.BUNDLE_LIMITS = BUNDLE_LIMITS

function Lib.EncodeBundle(t)
    local body, err = Lib.Serialize(t, BUNDLE_LIMITS)
    if not body then return nil, err end
    if #body > BUNDLE_LIMITS.text then return nil, "too large to export" end
    return "GFA1:" .. Check(body) .. ":" .. Lib.Base64Encode(body)
end

-- The table, or nil, why. Spaces and line breaks in the pasted text are ignored.
function Lib.DecodeBundle(s)
    if type(s) ~= "string" or IsSecret(s) then return nil, "not text" end
    if #s > BUNDLE_LIMITS.text * 2 then return nil, "too long" end
    s = s:gsub("%s+", "")
    if s == "" then return nil, "nothing pasted" end
    local check, b64 = s:match("^GFA1:(%x%x%x%x%x%x%x%x):([%w%+/=]+)$")
    if not check then return nil, "not a GaarForever export (it starts with GFA1:)" end
    local body = Lib.Base64Decode(b64)
    if not body then return nil, "the string is damaged (not base64)" end
    if Check(body) ~= check:lower() then return nil, "the string is damaged or cut short" end
    return Lib.Deserialize(body, BUNDLE_LIMITS)
end
