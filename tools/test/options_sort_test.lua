-- LuaJIT stub test: the hub's Options subpages are registered A-Z by label, whatever the load order.
-- Run: luajit tools/test/options_sort_test.lua   (from the repo root)
local fails = 0
local function eq(n, got, want) if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end end

local any
local mt = { __index = function(t, k) return rawget(t, "_f") end }
function any()
    local t = setmetatable({}, { __index = function(t, k) return t end, __call = function(t) return t end })
    return t
end
_G.CreateFrame = function() return any() end
local registered = {}
_G.Settings = {
    RegisterCanvasLayoutCategory = function(_, name) return { name = name } end,
    RegisterCanvasLayoutSubcategory = function(_, _, name) registered[#registered + 1] = name; return { name = name } end,
    RegisterAddOnCategory = function() end,
}
_G.GaarForever = { IntroOf = function() end }
local f = assert(loadfile("addons/GaarForever/Settings.lua"))
f("GaarForever", {})
local Pages = _G.GaarForever.Options

local labels = { "Bags", "Quests", "Maps", "Castbars", "Plates", "GPS", "Frames", "Windows", "Fishing", "Buffs",
    "Merchant", "Tooltips", "Mail", "XP", "Chat", "Bars", "Loot", "Group" }
local addons = {}
for _, l in ipairs(labels) do addons[#addons + 1] = { key = l:lower(), label = l, title = "Gaar" .. l .. "Forever", slash = "/x" } end
local hub = { version = "x", ADDONS = addons, API = function(a) return { version = "1" , MenuEntries = function() return {} end } end,
    StatusOf = function() return "" end, MinimapShown = function() return true end, SetMinimapShown = function() end }
local ok, err = pcall(Pages.Init, hub)
if not ok then fails = fails + 1; print("FAIL Init: " .. tostring(err)) end
local want = { "Bags", "Bars", "Buffs", "Castbars", "Chat", "Fishing", "Frames", "GPS", "Group", "Loot", "Mail", "Maps",
    "Merchant", "Plates", "Quests", "Tooltips", "Windows", "XP" }
eq("count", #registered, #want)
for i, w in ipairs(want) do eq("order " .. i, registered[i], w) end
eq("hub list untouched", addons[1].label, "Bags")
if fails == 0 then print("options_sort_test: ok") else os.exit(1) end
