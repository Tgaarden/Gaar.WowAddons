-- LuaJIT stub test: GaarGroupForever panel height stays the same when the mode (Tank / DPS / Healer) changes,
-- and the top edge never moves (mode switch, opening/closing a dock panel). Old CENTER saves become TOPLEFT.
-- Run: luajit tools/test/group_height_test.lua   (from the repo root)
local noop = function() end
local SW, SH = 1000, 800 -- UIParent size, origin bottom-left
local state = { combat = false }
local function sfn(t, k) local f = function() return t end; rawset(t, k, f); return f end
local W = {}
W.__index = function(t, k) local m = rawget(W, k); if m then return m end return sfn(t, k) end
local function frame(parent)
    return setmetatable({ parent = parent, shown = true, w = 0, h = 0, pts = {}, scale = 1 }, W)
end
local UIParent = frame(nil); UIParent.w, UIParent.h = SW, SH
function W.SetSize(f, w, h) f.w, f.h = w, h end
function W.SetWidth(f, w) f.w = w end
function W.SetHeight(f, h) f.h = h end
function W.GetHeight(f) return f.h end
function W.GetWidth(f) return f.w end
function W.ClearAllPoints(f) f.pts = {} end
function W.SetPoint(f, p, rel, rp, x, y)
    if type(rel) ~= "table" then rel, rp, x, y = f.parent, rel, rp, x end -- (p, x, y) / (p, rel...) forms
    if type(rp) == "number" then rp, x, y = p, rp, x end
    f.pts[#f.pts + 1] = { p, rel, rp or p, x or 0, y or 0 }
end
function W.GetPoint(f, i) local a = f.pts[i or 1]; if a then return a[1], a[2], a[3], a[4], a[5] end end
function W.Show(f) f.shown = true end
function W.Hide(f) f.shown = false end
function W.SetShown(f, v) f.shown = v and true or false end
function W.IsShown(f) return f.shown end
function W.IsVisible(f) local x = f; while x do if not x.shown then return false end; x = x.parent end return true end
function W.SetScale(f, s) f.scale = s end
function W.GetEffectiveScale(f) return f.scale end
-- screen position of a point of a frame whose anchor is f.pts[1] (only UIParent anchors are used on the bar)
local function top(f)
    local p, _, rp, x, y = f:GetPoint(1)
    if not p then return nil end
    local ax = rp:find("LEFT") and 0 or rp:find("RIGHT") and SW or SW / 2
    local ay = rp:find("TOP") and SH or rp:find("BOTTOM") and 0 or SH / 2
    local py = ay + y
    if p:find("TOP") then return py elseif p:find("BOTTOM") then return py + f.h else return py + f.h / 2 end
end
function W.GetTop(f) return top(f) end
function W.GetLeft(f) return 100 end

local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.UIParent = UIParent
G.GameTooltip = frame(nil)
G.CreateFrame = function(_, _, parent) return frame(parent or UIParent) end
G.GaarForever = {
    NewAddon = function() return { Print = noop, title = "GaarGroupForever" } end,
    OnOff = function(v) return v and "on" or "off" end,
    IsSecret = function() return false end,
    Num = function(v) return type(v) == "number" and v or nil end,
    Str = function(v) return type(v) == "string" and v ~= "" and v or nil end,
    RenderMenu = noop,
    PlayerFullName = function() return "Me" end,
    NamesMatch = function() return false end,
    UnitByName = noop,
    StripRealm = function(n) return n end,
}
G.SlashCmdList = {}; G.UISpecialFrames = {}
G.IsInGroup = function() return true end
G.IsInRaid = function() return false end
G.UnitExists = function(u) return u == "party1" end
G.UnitName = function(u) return u end
G.UnitGroupRolesAssigned = function(u) return u == "party1" and "TANK" or "NONE" end
G.InCombatLockdown = function() return state.combat end
G.GetTime = function() return 100 end
G.C_Timer = { After = noop }
G.SendChatMessage = noop

local function load(path)
    local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
    local c = assert(loadstring(src, path)); setfenv(c, G); c("GaarGroupForever", {})
end
local dir = "addons/GaarGroupForever/"
load(dir .. "GaarGroupForever.lua")
local M = G.GaarGroupForeverAPI._M
for _, f in ipairs({ "Overview", "Checks", "Markers", "RunLog", "Roles", "Tank", "Healer", "Dps" }) do load(dir .. f .. ".lua") end
G.GaarGroupForeverDB = { pos = { p = "CENTER", rp = "CENTER", x = 0, y = -100 } }
G.GaarGroupForeverCharDB = nil
M.BindSavedVariables()
M.preview = true

local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

M.CreateBar()
local bar = M.bar
local R = M.Roles

local function settle() for _ = 1, 3 do R.Tick(true); M.Dock.Update() end end
local function setMode(key) M.db.cdbMode = key; M.cdb.mode = key; G.UnitGroupRolesAssigned = function() return "NONE" end; M.Refresh(); settle() end

setMode("tank"); settle()
-- the old CENTER save became TOPLEFT (top edge kept) after the first layout
local p = bar:GetPoint(1)
eq(p, "TOPLEFT", "CENTER save converted to a TOPLEFT anchor")
eq(M.db.pos.p, "TOPLEFT", "converted position saved")

local topY = bar:GetTop()
local heights = {}
for _, key in ipairs({ "tank", "dps", "healer", "tank", "healer", "dps" }) do
    setMode(key)
    eq(R.current, key, "role row active: " .. key)
    heights[#heights + 1] = bar:GetHeight()
    eq(bar:GetTop(), topY, "top unchanged after switching to " .. key)
end
for i = 2, #heights do eq(heights[i], heights[1], "same panel height in every mode (" .. i .. ")") end

-- one compact strip: every role row has exactly ROW_H, and ROW_H is small (buttons + equal padding)
eq(R.ROW_H, 28, "compact single-strip row height")
for role, mod in pairs(R.mods) do
    if mod.row then
        eq(mod.height, R.ROW_H, role .. " build height equals ROW_H (" .. tostring(mod.height) .. ")")
    end
end

-- toggling a dock panel changes the height but not the top edge
local h0 = bar:GetHeight()
M.db.ovCollapsed = true; M.Refresh(); settle()
eq(bar:GetHeight() < h0, true, "collapsing the group list shrinks the panel")
eq(bar:GetTop(), topY, "top unchanged after collapsing a panel")
M.db.ovCollapsed = false; M.Refresh(); settle()
eq(bar:GetHeight(), h0, "height restored when reopened")
eq(bar:GetTop(), topY, "top unchanged after reopening a panel")
setMode("healer")
eq(bar:GetHeight(), h0, "healer height equals the others")

-- in combat nothing is moved or resized
state.combat = true
local before = bar:GetHeight()
M.db.ovCollapsed = true; M.Dock.Layout()
eq(bar:GetHeight(), before, "no relayout in combat")
state.combat = false

if fails == 0 then print("group height: all ok") else print(fails .. " FAILED"); os.exit(1) end
