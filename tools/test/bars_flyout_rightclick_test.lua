-- LuaJIT stub test: GaarBarsForever 1.5.2 - right-click on a button with a flyout casts the flyout's
-- entry 1 (type2 / spell2 / item2 / macro2 on the overlay), left click toggles it, the main bar's
-- paging moves the right-click action in combat, an item you have none of clears it, and the
-- /gbars status right-click line. Restricted code runs through handle proxies that only have the
-- methods the real restricted environment has (no :Click()), and SetAttribute on a protected frame
-- from addon code in combat raises, like the client.
-- Run: luajit tools/test/bars_flyout_rightclick_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarBarsForever/Flyouts.lua")); local src = fh:read("*a"); fh:close()

local fails, passes = 0, 0
local function check(cond, msg)
    if cond then passes = passes + 1 else fails = fails + 1; print("FAIL " .. msg) end
end

local combat = false
local restricted = 0 -- > 0 while a snippet runs (secure)
local frames = {}

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------
local Frame = {}
local function newFrame(kind, name, parent, template)
    local f = setmetatable({ kind = kind, name = name, parent = parent, template = template or "",
        attrs = {}, refs = {}, scripts = {}, shown = true, bindings = {} }, Frame)
    f.protected = f.template:find("Secure") ~= nil
    if name then frames[name] = f end
    frames[#frames + 1] = f
    return f
end
Frame.__index = function(t, k)
    local m = rawget(Frame, k)
    if m then return m end
    if type(k) == "string" and k:match("^%u") then return function() return nil end end
    return nil
end
function Frame:SetAttribute(k, v)
    if self.protected and combat and restricted == 0 then error("ADDON_ACTION_BLOCKED SetAttribute " .. k) end
    self.attrs[k] = v
end
function Frame:GetAttribute(k) return self.attrs[k] end
function Frame:SetScript(k, fn) self.scripts[k] = fn end
function Frame:HookScript(k, fn) self.scripts["hook" .. k] = fn end
function Frame:GetScript(k) return self.scripts[k] end
function Frame:Show() if not self.shown then self.shown = true; local h = self.scripts.hookOnShow; if h then h(self) end end end
function Frame:Hide() if self.shown then self.shown = false; local h = self.scripts.hookOnHide; if h then h(self) end end end
function Frame:IsShown() return self.shown end
function Frame:IsVisible() return self.shown end
function Frame:GetName() return self.name end
function Frame:GetWidth() return 36 end
function Frame:GetFrameLevel() return 1 end
function Frame:GetEffectiveScale() return 1 end
function Frame:IsMouseOver() return false end
function Frame:CreateTexture() return newFrame("Texture") end
function Frame:CreateFontString() return newFrame("FontString") end
function Frame:RegisterForClicks(...) self.clicks = { ... } end
function Frame:RegisterEvent(e) self.events = self.events or {}; self.events[e] = true end

-- ---------------------------------------------------------------------------
-- Restricted handles (only the methods RestrictedFrames.lua gives a handle)
-- ---------------------------------------------------------------------------
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
        envs[header] = setmetatable({ owner = Handle(header), tonumber = tonumber, tostring = tostring, type = type, select = select },
            { __index = function() return nil end })
    end
    return envs[header]
end
-- Run `body` in `header`'s environment, self = `selfFrame` handle, with named args.
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
RunSnippet = function(f, body, argNames, ...)
    if type(body) ~= "string" then return end
    return Run(f, f, "...", body, ...)
end

-- A click on a frame: the OnClick wrap's pre body, then the secure action (type<n>).
local casts = {}
local function Click(f, button, down)
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
    end
    if f.template:find("SecureActionButtonTemplate") then
        local useOnKeyDown = f.attrs.useOnKeyDown
        if useOnKeyDown == nil then useOnKeyDown = true end -- ActionButtonUseKeyDown = 1, the default
        if (down and useOnKeyDown) or (not down and not useOnKeyDown) then
            local suffix = button == "LeftButton" and "1" or button == "RightButton" and "2" or "3"
            local t = f.attrs["type" .. suffix] or f.attrs.type
            if not t then return "no action" end
            local v = f.attrs[t .. suffix] or f.attrs[t]
            casts[#casts + 1] = t .. "=" .. tostring(v)
            return "cast " .. t .. "=" .. tostring(v)
        end
        return "not this direction"
    elseif f.attrs._onclick then
        Run(f, f, ", button, down", f.attrs._onclick, button, down)
        return "onclick"
    end
end

-- ---------------------------------------------------------------------------
-- The client
-- ---------------------------------------------------------------------------
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.CreateFrame = function(kind, name, parent, template) return newFrame(kind, name, parent, template) end
G.UIParent = newFrame("Frame", "UIParent")
G.SecureHandlerSetFrameRef = function(f, label, ref) f.refs[label] = ref end
G.SecureHandlerExecute = function(f, body) RunSnippet(f, body, "") end
G.SecureHandlerWrapScript = function(f, script, header, pre, post)
    assert(script == "OnClick")
    f.wrap = { header = header, pre = pre, post = post }
end
local driver
G.RegisterStateDriver = function(f, state, cond) driver = { f = f, state = state, cond = cond } end
G.UnregisterStateDriver = function() driver = nil end
G.SecureCmdOptionParse = function() return "1" end
G.ClearOverrideBindings = function(f) f.bindings = {} end
G.InCombatLockdown = function() return combat end

-- Slots: 1 = spell 100 (ActionButton1, page 1), 13 = spell 500 (ActionButton1 on page 2),
-- 61 = item 900 you have none of, 62 = macro "Foo".
local actions = { [1] = { "spell", 100 }, [13] = { "spell", 500 }, [61] = { "item", 900 }, [62] = { "macro", 7 } }
G.HasAction = function(s) return actions[s] ~= nil end
G.GetActionInfo = function(s) local a = actions[s]; if a then return a[1], a[2] end end
G.GetActionText = function(s) return s == 62 and "Foo" or nil end
G.GetMacroInfo = function(i) return i == 7 and "Foo" or nil end
G.GetBindingKey = function(cmd) return cmd == "ACTIONBUTTON1" and "1" or nil end
G.C_Item = { GetItemCount = function(id) return id == 900 and 0 or 5 end }
G.GaarBarsForeverCharDB = { flyouts = {
    ["spell:100"] = { { t = "spell", id = 100 }, { t = "spell", id = 200 }, { t = "item", id = 300 } },
    ["spell:500"] = { { t = "spell", id = 500 }, { t = "spell", id = 600 } },
    ["item:900"] = { { t = "item", id = 900 }, { t = "spell", id = 901 } },
    ["macro:Foo"] = { { t = "macro", name = "Foo" }, { t = "spell", id = 902 } },
} }
for i = 1, 12 do
    G["ActionButton" .. i] = newFrame("CheckButton", "ActionButton" .. i, G.UIParent, "ActionBarButtonTemplate")
    G["ActionButton" .. i].action = i
    G["MultiBarBottomLeftButton" .. i] = newFrame("CheckButton", "MultiBarBottomLeftButton" .. i, G.UIParent)
    G["MultiBarBottomLeftButton" .. i].action = 60 + i
end

local NS = { Bars = {
    Secret = function() return false end,
    Num = function(v) return type(v) == "number" and v or nil end,
    Str = function(v) return type(v) == "string" and v ~= "" and v or nil end,
    FieldOf = function(o, k) return type(o) == "table" and rawget(o, k) or nil end,
    CallOf = function(o, m, ...) local f = type(o) == "table" and o[m]; if type(f) == "function" then return f(o, ...) end end,
    InCombat = function() return combat end,
    On = function() return true end,
    DB = function() return {} end,
    Print = function(m) print("print: " .. tostring(m)) end,
    Fail = function(w, e) print("FAIL-CAUGHT " .. tostring(w) .. ": " .. tostring(e)) end,
} }
local chunk = assert(loadstring(src, "@Flyouts.lua")); setfenv(chunk, G)
chunk("GaarBarsForever", NS)
local FL = NS.Flyouts

local events
for _, f in ipairs(frames) do if f.scripts.OnEvent and f.events and f.events.ADDON_LOADED then events = f end end
events.scripts.OnEvent(events, "ADDON_LOADED", "GaarBarsForever")
FL.Refresh()

local h = frames.GaarBarsForeverFlyoutHeader
local function OverlayOf(btn)
    for _, f in ipairs(frames) do
        if f.name and f.name:match("^GaarBarsForeverFlyoutOverlay") and f.parent == btn then return f end
    end
end
local o1, o61, o62 = OverlayOf(G.ActionButton1), OverlayOf(G.MultiBarBottomLeftButton1), OverlayOf(G.MultiBarBottomLeftButton2)

-- ---------------------------------------------------------------------------
-- Out of combat
-- ---------------------------------------------------------------------------
check(h ~= nil and o1 and o61 and o62, "header and three overlays built")
check(o1.template == "SecureActionButtonTemplate", "overlay is a SecureActionButtonTemplate")
check(o1.attrs._onclick == nil, "no _onclick snippet on the overlay")
check(o1.wrap and o1.wrap.header == h, "overlay OnClick wrapped by the header")
check(o1.attrs.useOnKeyDown == false, "useOnKeyDown = false")
check(o1.shown and o1.attrs.curslot == 1, "ActionButton1 overlay live on slot 1")
check(o1.attrs.type2 == "spell" and o1.attrs.spell2 == 100, "type2/spell2 = entry 1 (spell 100)")
check(o1.attrs.type1 == nil and o1.attrs.type == nil, "no left-click action on the overlay")
check(o61.shown and o61.attrs.type2 == nil and o61.attrs.item2 == nil, "item entry 1 you have none of: type2 cleared")
check(o62.attrs.type2 == "macro" and o62.attrs.macro2 == "Foo", "macro entry 1: type2 macro, macro2 Foo")
check(o1.bindings["1"] and o1.bindings["1"][1] == o1.name and o1.bindings["1"][2] == "LeftButton",
    "key 1 bound to the overlay with LeftButton")

check(Click(o1, "RightButton") == "cast spell=100", "right-click casts spell 100")
check(h.attrs.open == 0, "right-click leaves the flyout closed")
check(Click(o1, "LeftButton") == "cancelled", "left click cancels the secure action")
check(h.attrs.open == 1 and frames.GaarBarsForeverFlyout1.shown, "left click opens slot 1's flyout")
check(h.bindings["1"] ~= nil and h.bindings.ESCAPE ~= nil, "1-12 and Escape bound while open")
check(Click(o1, "RightButton") == "cast spell=100", "right-click with the flyout open casts spell 100")
check(h.attrs.open == 0 and not frames.GaarBarsForeverFlyout1.shown, "...and closes the flyout")
check(Click(o1, "LeftButton") == "cancelled" and h.attrs.open == 1, "left click opens again")
check(Click(o1, "LeftButton") == "cancelled" and h.attrs.open == 0, "left click again closes")
check(Click(o61, "RightButton") == "no action", "right-click on the item-with-none overlay does nothing")
check(Click(o62, "RightButton") == "cast macro=Foo", "right-click runs macro Foo")
-- A binding click (LeftButton) on key down is not delivered (AnyUp only); on release it toggles.
check(Click(o1, "LeftButton", true) == "not registered", "key down not delivered")
check(Click(o1, "LeftButton", false) == "cancelled" and h.attrs.open == 1, "key release toggles open")
Click(o1, "LeftButton")

local line = FL.RightClickLine()
check(line == "right-click: entry 1 set on 2 of 3 shown overlays (1 spell, 1 macro)", "status line: " .. line)

-- ---------------------------------------------------------------------------
-- Combat: the main bar pages to 2 (slot 13, spell 500)
-- ---------------------------------------------------------------------------
combat = true
check(driver and driver.f == h, "page state driver registered on the header")
h.attrs["state-page"] = "2"
Run(h, h, ", stateid, newstate", h.attrs["_onstate-page"], "page", "2")
check(o1.attrs.curslot == 13 and o1.shown, "in combat, page 2: overlay follows slot 13")
check(o1.attrs.type2 == "spell" and o1.attrs.spell2 == 500, "in combat, page 2: spell2 = 500")
check(Click(o1, "RightButton") == "cast spell=500", "in combat, right-click casts spell 500")
check(Click(o1, "LeftButton") == "cancelled" and h.attrs.open == 13, "in combat, left click opens slot 13's flyout")
check(Click(o1, "RightButton") == "cast spell=500" and h.attrs.open == 0, "in combat, right-click closes and casts")
-- A page without a flyout hides the overlay and clears its right-click action.
Run(h, h, ", stateid, newstate", h.attrs["_onstate-page"], "page", "3")
check(not o1.shown and o1.attrs.type2 == nil and o1.attrs.spell2 == nil, "page 3 (no flyout): hidden, type2 cleared")
Run(h, h, ", stateid, newstate", h.attrs["_onstate-page"], "page", "1")
check(o1.shown and o1.attrs.spell2 == 100, "back to page 1: spell2 = 100")
-- Data changes in combat wait for the fight to end.
FL.Refresh()
combat = false
events.scripts.OnEvent(events, "PLAYER_REGEN_ENABLED")
check(o1.attrs.spell2 == 100 and o1.shown, "after combat: rebuilt, spell2 = 100")

-- ---------------------------------------------------------------------------
-- Entries change out of combat: entry 1 removed, the flyout's new entry 1 is used
-- ---------------------------------------------------------------------------
local list = G.GaarBarsForeverCharDB.flyouts["spell:100"]
table.remove(list, 1)
FL.Refresh()
check(o1.attrs.type2 == "spell" and o1.attrs.spell2 == 200, "entry 1 removed: right-click casts spell 200")
-- Item 900 arrives in the bags: its overlay gets item2.
G.C_Item.GetItemCount = function() return 3 end
FL.Refresh()
check(o61.attrs.type2 == "item" and o61.attrs.item2 == "item:900", "item now owned: type2 item, item2 item:900")

-- ---------------------------------------------------------------------------
-- A druid in cat form (main bar page 7, slots 73-84): flyouts on slot 75 (ActionButton3 on page
-- 7) and slot 61 (MultiBarBottomLeftButton1, also ActionButton1 on page 6). Two flyouts on bars,
-- three overlays (ActionButton1's only shows on page 6), as /gbars status reported in game.
-- ---------------------------------------------------------------------------
G.GaarBarsForeverCharDB.flyouts = {
    ["spell:700"] = { { t = "spell", id = 700 }, { t = "spell", id = 701 } },
    ["item:900"] = { { t = "item", id = 900 }, { t = "spell", id = 901 } },
}
actions = { [75] = { "spell", 700 }, [61] = { "item", 900 }, [62] = { "macro", 7 } }
for i = 1, 12 do G["ActionButton" .. i].action = 72 + i end
G.SecureCmdOptionParse = function() return "7" end
FL.Refresh()
local o3 = OverlayOf(G.ActionButton3)
local st = FL.StatusLine()
check(st:find("2 on bars", 1, true) and st:find("3 buttons with an overlay (2 shown now)", 1, true)
    and st:find("paging ok (page 7)", 1, true), "page 7 status: " .. st)
check(o3 and o3.shown and o3.attrs.curslot == 75, "page 7: ActionButton3 overlay live on slot 75")
check(o3.attrs.type2 == "spell" and o3.attrs.spell2 == 700, "page 7: type2/spell2 = 700")
check(not o1.shown and o1.attrs.type2 == nil, "page 7: ActionButton1's overlay (page 6 alias of slot 61) hidden, no type2")
check(not o62.shown and o62.attrs.type2 == nil, "macro flyout gone: its overlay hidden, type2 cleared")
check(Click(o3, "RightButton") == "cast spell=700", "page 7: right-click casts spell 700")
check(Click(o3, "LeftButton") == "cancelled" and h.attrs.open == 75, "page 7: left click opens slot 75's flyout")
check(h.bindings["1"] and h.bindings["1"][1] == "GaarBarsForeverFlyout75Entry1", "page 7: key 1 casts entry 1")
check(Click(o3, "RightButton") == "cast spell=700" and h.attrs.open == 0, "page 7: right-click closes and casts")
check(FL.RightClickLine() == "right-click: entry 1 set on 2 of 2 shown overlays (1 spell, 1 item)",
    "page 7 right-click line: " .. FL.RightClickLine())
-- Leaving cat form in combat (page 1): slot 3 has no flyout, so ActionButton3's overlay hides.
combat = true
Run(h, h, ", stateid, newstate", h.attrs["_onstate-page"], "page", "1")
check(not o3.shown and o3.attrs.type2 == nil, "combat, page 1: ActionButton3 overlay hidden, type2 cleared")
check(Click(o3, "RightButton") == "no action", "combat, page 1: nothing cast (overlay hidden anyway)")
Run(h, h, ", stateid, newstate", h.attrs["_onstate-page"], "page", "6")
check(o1.shown and o1.attrs.curslot == 61 and o1.attrs.type2 == "item" and o1.attrs.item2 == "item:900",
    "combat, page 6: ActionButton1 overlay shows slot 61 with its item")
Run(h, h, ", stateid, newstate", h.attrs["_onstate-page"], "page", "7")
check(o3.shown and o3.attrs.spell2 == 700 and not o1.shown, "combat, back to cat (page 7): spell2 = 700 again")
check(Click(o3, "RightButton") == "cast spell=700", "combat, page 7: right-click casts spell 700")
combat = false

-- Flyouts off: everything cleared.
NS.Bars.On = function() return false end
FL.Refresh()
check(not o1.shown and o1.attrs.type2 == nil, "flyouts off: overlay hidden, type2 cleared")
check(h.attrs.first1type == nil and h.attrs.first1value == nil, "flyouts off: header first<slot> cleared")

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
