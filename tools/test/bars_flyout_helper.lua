-- Shared stub client for the bars_flyout*_test.lua files: GaarBarsForever's Flyouts.lua (and,
-- when asked, FlyoutEditor.lua) in a stub client with frames, restricted handles (only the methods
-- RestrictedFrames.lua gives a handle, so no :Click()), secure clicks with an OnClick wrap whose
-- preBody may cancel (false) or replace the button (a string), action slots, macros (account and
-- character sections, each kept sorted by name, so indexes move when a macro is created, renamed
-- or deleted, as in the client) and the cursor.
-- Used with dofile("tools/test/bars_flyout_helper.lua")(opts); does nothing when run on its own.
-- opts.charDB = GaarBarsForeverCharDB to start with; opts.editor = true also loads the editor.
return function(opts)
    opts = opts or {}
    local T = { combat = false, frames = {}, casts = {}, printed = {} }
    local restricted = 0
    local frames = T.frames

    -- One count for every stub client a test file makes.
    local counts = rawget(_G, "__barsFlyoutCounts") or { passes = 0, fails = 0 }
    rawset(_G, "__barsFlyoutCounts", counts)
    function T.check(cond, msg)
        if cond then counts.passes = counts.passes + 1 else counts.fails = counts.fails + 1; print("FAIL " .. msg) end
    end
    function T.done()
        print(string.format("%d passed, %d failed", counts.passes, counts.fails))
        os.exit(counts.fails == 0 and 0 or 1)
    end

    -- Frames -------------------------------------------------------------------------------
    local Frame = {}
    local function newFrame(kind, name, parent, template)
        local f = setmetatable({ kind = kind, name = name, parent = parent, template = template or "",
            attrs = {}, refs = {}, scripts = {}, shown = true, bindings = {} }, Frame)
        f.protected = f.template:find("Secure") ~= nil
        if name then frames[name] = f end
        frames[#frames + 1] = f
        return f
    end
    T.newFrame = newFrame
    Frame.__index = function(t, k)
        local m = rawget(Frame, k)
        if m then return m end
        if type(k) == "string" and k:match("^%u") then return function() return nil end end
        return nil
    end
    function Frame:SetAttribute(k, v)
        if self.protected and T.combat and restricted == 0 then error("ADDON_ACTION_BLOCKED SetAttribute " .. k) end
        self.attrs[k] = v
    end
    function Frame:GetAttribute(k) return self.attrs[k] end
    function Frame:SetScript(k, fn) self.scripts[k] = fn end
    function Frame:HookScript(k, fn) self.scripts["hook" .. k] = fn end
    function Frame:GetScript(k) return self.scripts[k] end
    function Frame:Show() if not self.shown then self.shown = true; local h = self.scripts.hookOnShow or self.scripts.OnShow; if h then h(self) end end end
    function Frame:Hide() if self.shown then self.shown = false; local h = self.scripts.hookOnHide or self.scripts.OnHide; if h then h(self) end end end
    function Frame:SetShown(v) if v then self:Show() else self:Hide() end end
    function Frame:IsShown() return self.shown end
    function Frame:IsVisible() return self.shown end
    function Frame:GetName() return self.name end
    function Frame:GetWidth() return 36 end
    function Frame:GetFrameLevel() return 1 end
    function Frame:GetEffectiveScale() return 1 end
    function Frame:IsMouseOver() return false end
    function Frame:HasFocus() return false end
    function Frame:GetChecked() return self.checked end
    function Frame:SetChecked(v) self.checked = v end
    function Frame:SetText(v) self.text = v end
    function Frame:GetText() return self.text end
    function Frame:GetMinMaxValues() return self.min or 0, self.max or 0 end
    function Frame:SetMinMaxValues(a, b) self.min, self.max = a, b end
    function Frame:SetValue(v) self.value = v; local h = self.scripts.OnValueChanged; if h then h(self, v) end end
    function Frame:CreateTexture() return newFrame("Texture") end
    function Frame:CreateFontString() return newFrame("FontString") end
    function Frame:CreateMaskTexture() return newFrame("MaskTexture") end
    function Frame:RegisterForClicks(...) self.clicks = { ... } end
    function Frame:RegisterEvent(e) self.events = self.events or {}; self.events[e] = true end

    -- Restricted handles -----------------------------------------------------------------------
    local handles = setmetatable({}, { __mode = "k" })
    local envs = {}
    local RunSnippet
    local function Handle(f)
        if not f then return nil end
        if handles[f] then return handles[f] end
        local h = {}
        h.GetAttribute = function(_, k) return f.attrs[k] end
        h.SetAttribute = function(_, k, v)
            if type(k) ~= "string" or k:match("^_") then error("Invalid attribute name") end
            f.attrs[k] = v
        end
        h.GetFrameRef = function(_, label) return Handle(f.refs[label]) end
        h.RunAttribute = function(_, name, ...) return RunSnippet(f, f.attrs[name], "", ...) end
        h.Show = function() f:Show() end
        h.Hide = function() f:Hide() end
        h.IsShown = function() return f.shown end
        h.ClearAllPoints = function() end
        h.SetPoint = function() end
        h.ClearBindings = function() f.bindings = {} end
        h.SetBindingClick = function(_, prio, key, target, button) f.bindings[key] = { target, button } end
        h.GetName = function() return f.name end
        handles[f] = h
        return h
    end
    local function Env(header)
        if not envs[header] then
            envs[header] = setmetatable({ owner = Handle(header), tonumber = tonumber, tostring = tostring,
                type = type, select = select }, { __index = function() return nil end })
        end
        return envs[header]
    end
    local function Run(header, selfFrame, argNames, body, ...)
        local code
        if argNames == "..." then
            code = "local self = ...\nreturn (function(...)\n" .. body .. "\nend)(select(2, ...))"
        else
            code = "local self" .. argNames .. " = ...\n" .. body
        end
        local chunk = assert(loadstring(code, "=snippet"))
        setfenv(chunk, Env(header))
        restricted = restricted + 1
        local res = { pcall(chunk, Handle(selfFrame), ...) }
        restricted = restricted - 1
        if not res[1] then error(res[2], 0) end
        return unpack(res, 2)
    end
    T.Run = Run
    RunSnippet = function(f, body, argNames, ...)
        if type(body) ~= "string" then return end
        return Run(f, f, "...", body, ...)
    end

    -- A click: the OnClick wrap's preBody (false cancels, a string replaces the button), then the
    -- secure action (type<suffix>). Binding clicks use the button name of the binding.
    function T.Click(f, button, down)
        down = down or false
        local registered = false
        for _, c in ipairs(f.clicks or {}) do
            if c == "AnyUp" and not down then registered = true end
            if c == "AnyDown" and down then registered = true end
            if c == button .. (down and "Down" or "Up") then registered = true end
        end
        if not registered then return "not registered" end
        if f.wrap then
            local r = Run(f.wrap.header, f, ", button, down", f.wrap.pre, button, down)
            if r == false then return "cancelled" end
            if type(r) == "string" then button = r end
        end
        if f.template:find("SecureActionButtonTemplate") then
            local useOnKeyDown = f.attrs.useOnKeyDown
            if useOnKeyDown == nil then useOnKeyDown = true end
            if (down and useOnKeyDown) or (not down and not useOnKeyDown) then
                local suffix = button == "LeftButton" and "1" or button == "RightButton" and "2"
                    or button == "MiddleButton" and "3" or ("-" .. button)
                local t = f.attrs["type" .. suffix] or f.attrs.type
                if not t then return "no action" end
                local v = f.attrs[t .. suffix] or f.attrs[t]
                T.casts[#T.casts + 1] = t .. "=" .. tostring(v)
                return "cast " .. t .. "=" .. tostring(v)
            end
            return "not this direction"
        elseif f.attrs._onclick then
            Run(f, f, ", button, down", f.attrs._onclick, button, down)
            return "onclick"
        end
    end

    -- A key press through the overlay's own binding (as the client clicks it).
    function T.Key(o, key)
        local b = o.bindings[key]
        if not b then return "unbound" end
        return T.Click(frames[b[1]], b[2], false)
    end

    -- The client ---------------------------------------------------------------------------
    local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
    G._G = G
    T.G = G
    G.CreateFrame = function(kind, name, parent, template) return newFrame(kind, name, parent, template) end
    G.UIParent = newFrame("Frame", "UIParent")
    G.UISpecialFrames = {}
    G.SecureHandlerSetFrameRef = function(f, label, ref) f.refs[label] = ref end
    G.SecureHandlerExecute = function(f, body) RunSnippet(f, body, "") end
    G.SecureHandlerWrapScript = function(f, script, header, pre, post)
        assert(script == "OnClick")
        f.wrap = { header = header, pre = pre, post = post }
    end
    G.RegisterStateDriver = function(f, state, cond) T.driver = { f = f, state = state, cond = cond } end
    G.UnregisterStateDriver = function() T.driver = nil end
    T.page = "1"
    G.SecureCmdOptionParse = function() return T.page end
    G.ClearOverrideBindings = function(f) f.bindings = {} end
    G.InCombatLockdown = function() return T.combat end
    G.GetBindingKey = function(cmd) return cmd == "ACTIONBUTTON1" and "1" or (cmd == "ACTIONBUTTON3" and "3")
        or (cmd == "MULTIACTIONBAR1BUTTON1" and "F1") or nil end
    T.itemCount = {}
    G.C_Item = { GetItemCount = function(id) return T.itemCount[id] or 5 end,
        GetItemNameByID = function(id) return "Item" .. id end }
    T.spellNames = {}
    G.C_Spell = { GetSpellTexture = function(id) return 1000 + id end }

    -- Macros: account 1-120, character 121-138, each section sorted by name.
    local MAXA, MAXC = 120, 18
    G.Constants = { MacroConsts = { MAX_ACCOUNT_MACROS = MAXA, MAX_CHARACTER_MACROS = MAXC } }
    T.acc, T.char = {}, {}
    local function sortSec(sec) table.sort(sec, function(a, b) return a.name < b.name end) end
    function T.MacroIndexOf(m)
        for i, x in ipairs(T.acc) do if x == m then return i end end
        for i, x in ipairs(T.char) do if x == m then return MAXA + i end end
    end
    local function byIndex(i)
        if type(i) == "string" then
            for _, x in ipairs(T.acc) do if x.name == i then return x end end
            for _, x in ipairs(T.char) do if x.name == i then return x end end
            return nil
        end
        if i <= MAXA then return T.acc[i] end
        return T.char[i - MAXA]
    end
    T.MacroByIndex = byIndex
    T.macroCalls = { create = 0, edit = 0, delete = 0 }
    function T.AddMacro(name, body, perChar, icon)
        local m = { name = name, body = body or "", icon = icon or 134400 }
        local sec = perChar and T.char or T.acc
        sec[#sec + 1] = m
        sortSec(sec)
        return m
    end
    G.GetNumMacros = function() return #T.acc, #T.char end
    G.CreateMacro = function(name, icon, body, perChar)
        local sec = perChar and T.char or T.acc
        if #sec >= (perChar and MAXC or MAXA) then error("macro section full") end
        T.macroCalls.create = T.macroCalls.create + 1
        local m = T.AddMacro(name, body, perChar, icon)
        return T.MacroIndexOf(m)
    end
    G.EditMacro = function(i, name, icon, body)
        local m = byIndex(i)
        if not m then return end
        T.macroCalls.edit = T.macroCalls.edit + 1
        if name then m.name = name end
        if icon then m.icon = icon end
        if body then m.body = body end
        sortSec(T.acc); sortSec(T.char)
        return T.MacroIndexOf(m)
    end
    G.DeleteMacro = function(i)
        local m = byIndex(i)
        if not m then return end
        T.macroCalls.delete = T.macroCalls.delete + 1
        for _, sec in ipairs({ T.acc, T.char }) do
            for k, x in ipairs(sec) do if x == m then table.remove(sec, k) break end end
        end
        for s, a in pairs(T.actions) do if a[1] == "macro" and a[2] == m then T.actions[s] = nil end end
    end
    G.GetMacroIndexByName = function(name) local m = byIndex(name); return m and T.MacroIndexOf(m) or 0 end
    G.GetMacroInfo = function(i) local m = byIndex(i); if m then return m.name, m.icon, m.body end end
    G.GetMacroBody = function(i) local m = byIndex(i); return m and m.body or nil end

    -- Action slots: { "spell", id } / { "item", id } / { "macro", macroObject } / { "companion", n }.
    T.actions = {}
    T.noActionText = false
    G.HasAction = function(s) return T.actions[s] ~= nil end
    G.GetActionInfo = function(s)
        local a = T.actions[s]
        if not a then return nil end
        if a[1] == "macro" then return "macro", T.MacroIndexOf(a[2]) end
        return a[1], a[2]
    end
    G.GetActionText = function(s)
        local a = T.actions[s]
        if not T.noActionText and a and a[1] == "macro" then return a[2].name end
        return nil
    end
    G.GetActionTexture = function() return 999 end

    -- The cursor.
    T.cursor = nil
    G.GetCursorInfo = function()
        local c = T.cursor
        if not c then return nil end
        if c[1] == "macro" then return "macro", T.MacroIndexOf(c[2]) end
        if c[1] == "spell" then return "spell", 1, "spell", c[2] end
        return c[1], c[2]
    end
    G.ClearCursor = function() T.cursor = nil end
    G.PickupSpell = function(id) T.cursor = { "spell", id } end
    G.PickupItem = function(id) T.cursor = { "item", id } end
    G.PickupMacro = function(i) local m = byIndex(i); if m then T.cursor = { "macro", m } end end
    G.PickupAction = function(s) T.cursor, T.actions[s] = T.actions[s], nil end
    G.PlaceAction = function(s)
        local old = T.actions[s]
        T.actions[s] = T.cursor
        T.cursor = old
    end

    for i = 1, 12 do
        G["ActionButton" .. i] = newFrame("CheckButton", "ActionButton" .. i, G.UIParent, "ActionBarButtonTemplate")
        G["ActionButton" .. i].action = i
        G["MultiBarBottomLeftButton" .. i] = newFrame("CheckButton", "MultiBarBottomLeftButton" .. i, G.UIParent)
        G["MultiBarBottomLeftButton" .. i].action = 60 + i
    end
    G.GaarBarsForeverCharDB = opts.charDB

    T.db = { flyoutDir = "up" }
    T.on = true
    local NS = { Bars = {
        Secret = function() return false end,
        Num = function(v) return type(v) == "number" and v or nil end,
        Str = function(v) return type(v) == "string" and v ~= "" and v or nil end,
        FieldOf = function(o, k) return type(o) == "table" and rawget(o, k) or nil end,
        CallOf = function(o, m, ...) local f = type(o) == "table" and o[m]; if type(f) == "function" then return f(o, ...) end end,
        InCombat = function() return T.combat end,
        On = function() return T.on end,
        DB = function() return T.db end,
        Print = function(m) T.printed[#T.printed + 1] = tostring(m) end,
        Fail = function(w, e) print("FAIL-CAUGHT " .. tostring(w) .. ": " .. tostring(e)); T.failed = true end,
        SpellName = function(id) return T.spellNames[id] or ("Spell" .. id) end,
        SpellRank = function(id) return id == 701 and 2 or nil end,
    } }
    T.NS = NS
    local function load(path)
        local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
        local chunk = assert(loadstring(src, "@" .. path)); setfenv(chunk, G)
        chunk("GaarBarsForever", NS)
    end
    load("addons/GaarBarsForever/Flyouts.lua")
    if opts.editor then load("addons/GaarBarsForever/FlyoutEditor.lua") end
    T.FL = NS.Flyouts

    for _, f in ipairs(frames) do if f.scripts.OnEvent and f.events and f.events.ADDON_LOADED then T.events = f end end
    function T.Event(e, ...) T.events.scripts.OnEvent(T.events, e, ...) end
    -- The clock frame's tick (MarkDirty rebuilds there): run it as the client would.
    function T.Tick()
        for _, f in ipairs(frames) do
            if f.scripts.OnUpdate and f.kind == "Frame" and not f.name then f.scripts.OnUpdate(f, 1) end
        end
    end
    function T.Login()
        T.Event("ADDON_LOADED", "GaarBarsForever")
        T.Event("PLAYER_ENTERING_WORLD")
        T.Tick()
    end
    function T.Header() return frames.GaarBarsForeverFlyoutHeader end
    function T.OverlayOf(btn)
        for _, f in ipairs(frames) do
            if f.name and f.name:match("^GaarBarsForeverFlyoutOverlay") and f.parent == btn then return f end
        end
    end
    function T.Page(p)
        local h = T.Header()
        Run(h, h, ", stateid, newstate", h.attrs["_onstate-page"], "page", p)
    end
    function T.SetCombat(v)
        T.combat = v
        T.Event(v and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
    end
    return T
end
