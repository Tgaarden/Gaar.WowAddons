-- LuaJIT stub test: GaarForever.AttachMenu (right-click a window or portrait opens the addon's menu)
-- and the GaarBagsForever wiring. Run: luajit tools/test/attach_menu_test.lua   (from the repo root)
local fails = 0
local function eq(n, got, want) if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end end

local combat = false
local created = {}
local function newFrame(name)
    local f = { hooks = {}, scripts = {}, points = {}, shown = true, w = 60, h = 60 }
    function f:HookScript(ev, fn) self.hooks[ev] = self.hooks[ev] or {}; table.insert(self.hooks[ev], fn) end
    function f:SetScript(ev, fn) self.scripts[ev] = fn end
    function f:RegisterForClicks(...) self.clicks = { ... } end
    function f:RegisterEvent() end
    function f:ClearAllPoints() self.points = {} end
    function f:SetPoint(...) table.insert(self.points, { ... }) end
    function f:SetSize(w, h) self.w, self.h = w, h end
    function f:GetWidth() return self.w end
    function f:GetHeight() return self.h end
    function f:GetObjectType() return "Frame" end
    function f:GetFrameStrata() return "HIGH" end
    function f:SetFrameStrata(s) self.strata = s end
    function f:GetFrameLevel() return 5 end
    function f:SetFrameLevel(l) self.level = l end
    function f:EnableMouse(v) self.mouse = v end
    function f:SetPropagateMouseClicks(v) self.propagate = v end
    function f:IsShown() return self.shown end
    function f.IsMouseOver() return true end
    if name then created[name] = f end
    return f
end
_G.CreateFrame = function(kind, name) return newFrame(name) end
_G.InCombatLockdown = function() return combat end
_G.GaarForever = nil
dofile("addons/GaarForever/Lib.lua")
local L = _G.GaarForever

local opened, rendered = {}, 0
_G.MenuUtil = { CreateContextMenu = function(owner, fn) table.insert(opened, owner); fn(owner, {}) end }
_G.GaarTestAPI = { MenuEntries = function() rendered = rendered + 1; return {} end }
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) _G.lastChat = m end }

-- Overlay mode over a portrait
local win = newFrame()
win.PortraitContainer = newFrame() -- 60x60 region
local h = L.AttachMenu(win, { title = "GaarTestForever", api = "GaarTestAPI", portrait = true, propagate = true, name = "TestBtn" })
local b = created.TestBtn
eq("button created", b ~= nil, true)
eq("returns handle", h and h.button, b)
eq("same handle on second call", L.AttachMenu(win, { title = "GaarTestForever" }), h)
eq("right clicks registered", b.clicks and b.clicks[1], "RightButtonUp")
eq("anchored to portrait", b.points[1] and b.points[1][2], win.PortraitContainer)
eq("raised above parent", b.level, 25)
eq("strata follows parent", b.strata, "HIGH")
eq("left-click reaches Blizzard (propagate)", b.propagate, true)
b.scripts.OnClick(b, "LeftButton", false)
eq("left click ignored", #opened, 0)
b.scripts.OnClick(b, "RightButton", true)
eq("right button down ignored", #opened, 0)
b.scripts.OnClick(b, "RightButton", false)
eq("right click opens menu", opened[1], b)
eq("entries from the api", rendered, 1)
win.PortraitContainer.w, win.PortraitContainer.h = 1, 1 -- a 1x1 holder
b.points = {}
for _, fn in ipairs(win.hooks.OnShow) do fn() end
eq("tiny holder: placed by offset", b.points[1] and b.points[1][1], "TOPLEFT")

-- Hook mode (own frame): right button only, nothing replaced
local own = newFrame()
local h2 = L.AttachMenu(own, { title = "GaarOwnForever", api = "GaarTestAPI", hook = true })
eq("hook mode makes no button", h2.button, nil)
eq("hook installed", own.hooks.OnMouseUp ~= nil, true)
eq("no scripts replaced", next(own.scripts), nil)
opened = {}
own.hooks.OnMouseUp[1](own, "LeftButton")
eq("hook: left ignored", #opened, 0)
own.hooks.OnMouseUp[1](own, "RightButton")
eq("hook: right opens", opened[1], own)

-- Combat: nothing is created until combat ends
combat = true
local late = newFrame()
local h3 = L.AttachMenu(late, { title = "GaarLateForever", api = "GaarTestAPI", portrait = true, name = "LateBtn" })
eq("no button in combat", created.LateBtn, nil)
combat = false
for _, f in pairs(created) do end
local ok = pcall(function() for ev, fn in pairs(late.hooks) do for _, x in ipairs(fn) do x() end end end)
eq("created on the next show", created.LateBtn ~= nil, true)

-- No MenuUtil: a hint, no error
_G.MenuUtil = nil
local okc = pcall(h.Open)
eq("no MenuUtil is a no-op", okc, true)
eq("hint printed", tostring(_G.lastChat):find("not available") ~= nil, true)

-- Menu error is printed once
_G.MenuUtil = { CreateContextMenu = function() error("boom") end }
_G.lastChat = nil
h.Open(); eq("error printed", tostring(_G.lastChat):find("boom") ~= nil, true)
_G.lastChat = nil
h.Open(); eq("error printed only once", _G.lastChat, nil)

-- Bags wiring: the Combined Backpack's portrait, left-click stays with Blizzard
local fh = assert(io.open("addons/GaarBagsForever/GaarBagsForever.lua")); local src = fh:read("*a"); fh:close()
eq("bags: AttachMenu on the bag frame", src:find("BF.AttachMenu(bagFrame", 1, true) ~= nil, true)
eq("bags: portrait + propagate", src:find('portrait = true, propagate = true', 1, true) ~= nil, true)
eq("bags: api name", src:find('api = "GaarBagsForeverAPI"', 1, true) ~= nil, true)

if fails == 0 then print("attach_menu_test: ok") else os.exit(1) end
