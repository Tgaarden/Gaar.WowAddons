-- LuaJIT stub test: GaarMapsForever portrait right-click button opens the shared menu.
-- Run: luajit tools/test/maps_portrait_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarMapsForever/GaarMapsForever.lua")); local src = fh:read("*a"); fh:close()
local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local allFrames = {}
local created, menuOwner, rendered, clicks = {}, nil, 0, nil
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.GaarForever = {
    NewAddon = function() return setmetatable({}, { __index = function() return noop end }) end,
    IsSecret = function() return false end,
    Num = function(v) return type(v) == "number" and v or nil end,
    InCombat = function() return false end, Print = noop, OnOff = noop, AddOnLoaded = function() return false end,
    Migrate = noop, RenderMenu = function() rendered = rendered + 1 end,
}
G.CreateFrame = function(kind, name)
    local w = widget()
    w.RegisterForClicks = function(self, ...) clicks = { ... } return self end
    w.SetScript = function(self, ev, fn) self["on" .. ev] = fn end
    w.GetFrameLevel = function() return 5 end
    w.HookScript = noop; w.IsShown = function() return false end
    allFrames[#allFrames + 1] = w
    if name then created[name] = w end
    return w
end
G.hooksecurefunc = noop
G.SlashCmdList = {}
G.WorldMapFrame = G.CreateFrame("Frame")
G.WorldMapFrame.BorderFrame = widget()
G.MenuUtil = { CreateContextMenu = function(owner, fn) menuOwner = owner; fn(owner, {}) end }
local f = assert(loadstring(src, "maps")); setfenv(f, G); f("GaarMapsForever")
local fails = 0
local function eq(n, got, want) if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end end
for _, fr in ipairs(allFrames) do
    if fr.onOnEvent then fr.onOnEvent(fr, "ADDON_LOADED", "GaarMapsForever") end
end
local b = created.GaarMapsForeverPortraitButton
eq("button created", b ~= nil, true)
if b then
    eq("right click only", clicks and clicks[1], "RightButtonUp")
    eq("one click type", clicks and #clicks, 1)
    b.onOnClick(b, "LeftButton")
    eq("left click ignored", menuOwner, nil)
    b.onOnClick(b, "RightButton")
    eq("menu owner", menuOwner, b)
    eq("shared menu builder used", rendered, 1)
end
if fails == 0 then print("maps_portrait_test: ok") else os.exit(1) end
