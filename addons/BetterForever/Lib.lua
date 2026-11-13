--[[
  BetterForever - the shared core of the Better...Forever family, for WoW Forever.

  This file is loaded first (BetterForever.toc lists it before anything else) and every
  Better...Forever addon lists BetterForever under ## Dependencies, so the global table below is
  there before any of them runs a line. It only defines helpers: nothing here creates a frame,
  registers an event or touches a Blizzard function until an addon asks for it.

  Global: BetterForever (the library). The hub's own API is BetterForeverAPI (Core.lua).

  Values (the client hands back "secret" values where it hides something: they may be passed to
  a widget, but comparing, testing or doing arithmetic on one is refused, so they are checked
  before anything else):
    BetterForever.IsSecret(v)      true for a secret value
    BetterForever.Plain(v)         v, or nil when it is secret
    BetterForever.Num(v)           a plain, finite number, else nil
    BetterForever.Str(v)           a plain, non-empty string, else nil
    BetterForever.Bool(v)          true / false, or nil when it is secret

  Calls:
    BetterForever.API(ns, name)    the function _G[ns][name] (or _G[ns] when name is nil), else nil
    BetterForever.Call(fn, ...)    fn(...) in pcall; its results, or nothing when fn is missing or errors
    BetterForever.Method(o, name, ...)  o:name(...) the same way
    BetterForever.AddOnLoaded(name), BetterForever.InCombat()

  Text:
    BetterForever.OnOff(v)         "on" / "off"
    BetterForever.TimeShort(s)     "56", "2m", "1h", "3d" (rounded up; "" for 0, nil or secret)
    BetterForever.Clock(s)         "4:05", "1:02:03" ("--" for nil or secret)
    BetterForever.Coins(copper)    "1g 2s 3c" ("0c" for 0)
    BetterForever.ShortNumber(n)   "950", "12.3k", "1.2M"

  Menus:
    BetterForever.RenderMenu(root, entries)  draws MenuEntries() data into a MenuUtil description
    BetterForever.IntroOf(api)     an addon API table's intro text (Intro() or intro), or nil

  Addons:
    BetterForever.NewAddon(name, opts) -> addon object; see the README ("For addon authors") for
    :Print, :InitDB, :Toggle, :Choice, :Slider, :Button, :Divider, :Get, :Set, :MenuEntries,
    :Slash, :Run, :On and :API.
]]

local _G = _G

local Lib = _G.BetterForever
if type(Lib) ~= "table" then
    Lib = {}
    _G.BetterForever = Lib
end
Lib.version = "3.0"

local PREFIX_COLOR = "|cff33ff99"

-- ---------------------------------------------------------------------------
-- Values
-- ---------------------------------------------------------------------------

local function IsSecret(v)
    local f = _G.issecretvalue
    if type(f) ~= "function" then return false end
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

function Lib.Method(obj, name, ...)
    if type(obj) ~= "table" then return end
    local fn = obj[name]
    if type(fn) ~= "function" then return end
    return Pass(pcall(fn, obj, ...))
end

-- Whether an addon is loaded: C_AddOns on newer clients, the old global otherwise.
function Lib.AddOnLoaded(name)
    local f = Lib.API("C_AddOns", "IsAddOnLoaded") or Lib.API("IsAddOnLoaded")
    if not f then return false end
    local ok, loaded = pcall(f, name)
    return ok and Bool(loaded) == true
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
-- something is still running. The format of BetterFramesForever's aura times and BetterBars'
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
-- MenuEntries() data, the shape every Better...Forever addon hands the hub:
--   { text, func }                           a button
--   { text, checkbox = true, checked, func } a checkbox; func toggles
--   { text, radio = true, checked, func }    one choice of a group; func picks it
--   { text, submenu = { ... } }              a submenu (or, in the Options pages, a section)
--   { label = "..." }                        a line that cannot be clicked
--   { divider = true }                       a line between groups
--   { text, slider = true, min, max, step, value, set, format }   a number (new in 3.0)
-- ---------------------------------------------------------------------------

local function SliderValues(e)
    local lo, hi, step = Num(e.min), Num(e.max), Num(e.step) or 1
    if not lo or not hi or step <= 0 or hi < lo then return {} end
    local list = {}
    local v = lo
    while v <= hi + step / 1000 and #list < 25 do
        list[#list + 1] = v
        v = v + step
    end
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

local function Click(e)
    if type(e.func) == "function" then
        local ok, err = pcall(e.func)
        if not ok then Lib.Report(err) end
    end
end

-- Errors from a menu click go to the chat frame once each, not to the error frame.
local reported = {}
function Lib.Report(err)
    err = tostring(err)
    if reported[err] then return end
    reported[err] = true
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and type(chat.AddMessage) == "function" then
        chat:AddMessage(PREFIX_COLOR .. "BetterForever|r: " .. err)
    end
end

-- Draws the entries into a MenuUtil description (root or submenu); every method is checked first.
function Lib.RenderMenu(root, entries)
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
            if type(sub) == "table" then Lib.RenderMenu(sub, e.submenu) end
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
                        func = function() if type(e.set) == "function" then pcall(e.set, v) end end }
                end
                Lib.RenderMenu(sub, radios)
            end
        elseif e.checkbox and type(root.CreateCheckbox) == "function" then
            root:CreateCheckbox(tostring(e.text), function() return Checked(e) end, function() Click(e) end)
        elseif e.radio and type(root.CreateRadio) == "function" then
            root:CreateRadio(tostring(e.text), function() return Checked(e) end, function() Click(e) end)
        elseif (e.checkbox or e.radio) and type(root.CreateButton) == "function" then
            -- A menu without checkboxes or radios: the state goes in the label instead.
            root:CreateButton((Checked(e) and "[x] " or "[ ] ") .. tostring(e.text), function() Click(e) end)
        elseif type(root.CreateButton) == "function" then
            root:CreateButton(tostring(e.text), function() Click(e) end)
        end
    end
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

-- opts: version (string), title (chat prefix; the name by default), intro (string),
-- status (function returning the status line), help (list of extra /x help lines).
function Lib.NewAddon(name, opts)
    opts = opts or {}
    local a = setmetatable({
        name = name,
        version = opts.version or "?",
        title = opts.title or name,
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

-- Binds the saved variable (call it at ADDON_LOADED, never at file scope): creates the table,
-- fills missing keys from defaults and from every registered option's default.
function Addon:InitDB(globalName, defaults)
    local t = _G[globalName]
    if type(t) ~= "table" then
        t = {}
        _G[globalName] = t
    end
    MergeDefaults(t, defaults)
    for _, o in ipairs(self.options) do
        if o.key and t[o.key] == nil then t[o.key] = DeepCopy(o.default) end
    end
    self.db = t
    return t
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

-- A number from min to max in steps, stored in db[key]. format(v) gives its text.
function Addon:Slider(key, label, min, max, step, default, onChange, format, opts)
    opts = opts or {}
    return AddOption(self, { kind = "slider", key = key, label = label, min = min, max = max, step = step or 1,
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

-- Sets an option, checked against its kind, and calls its onChange (in pcall). Returns true when
-- the value was accepted.
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
        if value < o.min then value = o.min end
        if value > o.max then value = o.max end
        value = o.min + math.floor((value - o.min) / o.step + 0.5) * o.step
    end
    self.db[key] = value
    if type(o.onChange) == "function" then
        local ok, err = pcall(o.onChange, value)
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
    local slash = self.slash or ("/" .. self.name:lower())
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
end

local function OnOffWord(w)
    if w == "on" or w == "1" or w == "true" or w == "yes" then return true end
    if w == "off" or w == "0" or w == "false" or w == "no" then return false end
    return nil
end

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

-- Events: handler(event, ...) in pcall; the last error is kept for /x status.
function Addon:On(event, handler)
    if not self.events then
        self.events = {}
        self.eventFrame = CreateFrame("Frame")
        self.eventFrame:SetScript("OnEvent", function(_, ev, ...)
            local h = self.events[ev]
            if h then
                local ok, err = pcall(h, ev, ...)
                if not ok then self.lastError = ev .. ": " .. tostring(err) end
            end
        end)
    end
    self.events[event] = handler
    pcall(self.eventFrame.RegisterEvent, self.eventFrame, event)
end

-- Builds and exports _G[name .. "API"], the table the hub reads: version, StatusLine, MenuEntries,
-- AddMenuEntries, SetMinimapHidden (does nothing) and Intro. extra overrides or adds fields.
function Addon:API(extra)
    local api = {
        version = self.version,
        StatusLine = function() return self:StatusLine() end,
        MenuEntries = function() return self:MenuEntries() end,
        AddMenuEntries = function(root) Lib.RenderMenu(root, self:MenuEntries()) end,
        SetMinimapHidden = function() end,
        Intro = function() return self.intro end,
    }
    for k, v in pairs(extra or {}) do api[k] = v end
    _G[self.name .. "API"] = api
    self.api = api
    return api
end
