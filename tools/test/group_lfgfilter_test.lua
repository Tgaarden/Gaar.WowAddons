-- LuaJIT stub test: GaarGroupForever group finder role filter (LfgFilter.lua, 1.7.0).
-- Run: luajit tools/test/group_lfgfilter_test.lua   (from the repo root)
--
-- Covers: the role matching (multi-role, no role), toggling, persistence in GaarGroupForeverDB, the
-- "last role stays on" rule, /ggf lfg, no errors while the Blizzard group finder is not loaded, and a
-- stubbed LFGBrowseFrame (Blizzard_GroupFinder_VanillaStyle): only solo players under your own listing
-- are faded (alpha 0 + mouse off), never your own row, a group, the selected card or a secret value;
-- nothing is written on a Blizzard frame and no Blizzard function is replaced.
local noop = function() end
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end
local function ok(v, msg) eq(v and true or false, true, msg) end

local function read(path) local fh = assert(io.open(path)); local s = fh:read("*a"); fh:close(); return s end

-- ---- our own widgets (anything the addon creates) ----
local function widget(kind)
    local w = { kind = kind, shown = true, alpha = 1, scripts = {}, points = {}, level = 1 }
    function w:Show() self.shown = true end
    function w:Hide() self.shown = false end
    function w:IsShown() return self.shown end
    function w:IsVisible() return self.shown end
    function w:SetScript(k, f) self.scripts[k] = f end
    function w:GetScript(k) return self.scripts[k] end
    function w:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function w:ClearAllPoints() self.points = {} end
    function w:SetFrameLevel(l) self.level = l end
    function w:SetText(t) self.text = t end
    function w:GetText() return self.text end
    function w:SetAlpha(a) self.alpha = a end
    function w:SetDesaturated(v) self.desat = v end
    function w:SetAtlas(a) self.atlas = a end
    function w:CreateTexture() return widget("Texture") end
    function w:CreateFontString() return widget("FontString") end
    return setmetatable(w, { __index = function() return noop end })
end

-- ---- Blizzard frames: writing a new field on one is a taint bug, so it is flagged ----
local blizzWrites = {}
local function blizz(name, t)
    t.__name = name
    return setmetatable(t, { __newindex = function(_, k) blizzWrites[#blizzWrites + 1] = name .. "." .. tostring(k) end })
end
local function region(name, shown)
    local r = { shown = shown ~= false }
    function r:IsShown() return self.shown end
    function r:GetWidth() return 16 end
    return blizz(name, r)
end
local function card(resultID, selected)
    local c = { resultID = resultID, Selected = region("Selected", selected or false), alpha = 1, mouse = true, shown = true }
    function c:SetAlpha(a) rawset(self, "alpha", a) end
    function c:EnableMouse(v) rawset(self, "mouse", v) end
    function c:IsShown() return self.shown end
    return blizz("card" .. tostring(resultID), c)
end
local function header(dividerType)
    local h = { CategoryLabel = region("CategoryLabel"), CollapseIcon = region("CollapseIcon"), dividerType = dividerType }
    function h:GetFrameLevel() return 7 end
    return blizz("header" .. dividerType, h)
end

-- ---- client ----
local SECRET = setmetatable({ secret = true }, { __tostring = function() return "<secret>" end })
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
local printed = {}
G.GaarForever = {
    NewAddon = function() return { Print = function(_, m) printed[#printed + 1] = m end, title = "GaarGroupForever" } end,
    OnOff = function(v) return v and "on" or "off" end,
    IsSecret = function(v) return v == SECRET end,
    Num = function(v) return type(v) == "number" and v or nil end,
    RenderMenu = noop,
}
G.SlashCmdList = {}
G.UIParent = widget("Frame")
G.GameTooltip = widget("GameTooltip")
local created = {}
G.CreateFrame = function(kind) local f = widget(kind); created[#created + 1] = f; return f end
G.IsInGroup = function() return false end
G.IsInRaid = function() return false end
G.UnitIsGroupLeader = function() return false end
G.C_Timer = { After = noop }

local results = {}   -- resultID -> { numMembers, hasSelf, roles = {tank, healer, dps} }
local lfgState = { listing = true }
G.C_LFGList = {
    HasActiveEntryInfo = function() return lfgState.listing end,
    GetSearchResultInfo = function(id)
        local r = results[id]
        if not r then return nil end
        return { numMembers = r.numMembers, hasSelf = r.hasSelf, leaderName = "P" .. id }
    end,
    GetSearchResultPlayerInfo = function(id, i)
        local r = results[id]
        if not r or i ~= 1 then return nil end
        return { lfgRoles = r.roles, classFilename = "WARRIOR", level = 30 }
    end,
}

-- ---- load the addon (main file + the filter) ----
local function load(path, name)
    local chunk = assert(loadstring(read(path), name)); setfenv(chunk, G); chunk("GaarGroupForever")
end
local mainSrc = read("addons/GaarGroupForever/GaarGroupForever.lua")
local chunk = assert(loadstring(mainSrc, "GaarGroupForever")); setfenv(chunk, G); chunk("GaarGroupForever")
local M = G.GaarGroupForeverAPI._M
load("addons/GaarGroupForever/LfgFilter.lua", "LfgFilter")
local L = M.LfgFilter
ok(L, "LfgFilter loaded")

-- the filter's own event frame (the last frame it created before the Blizzard addon loaded)
local driver = L.driver
local function fire(event, ...) driver.scripts.OnEvent(driver, event, ...) end

-- ---- 1. nothing loaded yet: no errors, slash and status work ----
G.GaarForeverDB = nil
G.GaarGroupForeverDB = nil; G.GaarGroupForeverCharDB = nil
M.BindSavedVariables()
eq(L.installed, false, "not installed without LFGBrowseFrame")
fire("PLAYER_LOGIN")
eq(L.installed, false, "still not installed after login")
L.Sync(); L.Changed()
M.OnSlash("lfg")
M.OnSlash("status")
local sawStatus = false
for _, p in ipairs(printed) do if p:find("LFG role filter:", 1, true) and p:find("not loaded", 1, true) then sawStatus = true end end
ok(sawStatus, "status line says the group finder is not loaded")
eq(M.lastError, nil, "no error with the frames missing")

-- ---- 2. matching ----
local all = { tank = true, healer = true, dps = true }
local noTank = { tank = false, healer = true, dps = true }
local dpsOnly = { tank = false, healer = false, dps = true }
eq(L.Matches({ tank = true }, all), true, "all on: tank shown")
eq(L.Matches({ tank = true, healer = false, dps = false }, noTank), false, "tank-only hidden when tank off")
eq(L.Matches({ tank = true, healer = true, dps = false }, noTank), true, "tank+healer shown while healer on")
eq(L.Matches({ tank = true, healer = true, dps = false }, dpsOnly), false, "tank+healer hidden with only dps on")
eq(L.Matches({ tank = true, healer = true, dps = true }, dpsOnly), true, "all-role player shown with only dps on")
eq(L.Matches({ tank = false, healer = false, dps = true }, dpsOnly), true, "dps shown with dps on")
eq(L.Matches({ tank = false, healer = false, dps = false }, dpsOnly), true, "no listed role: always shown")
eq(L.Matches(nil, dpsOnly), true, "unknown roles: shown")

-- ---- 3. toggling, persistence, the last role ----
eq(L.AllOn(), true, "defaults: all on")
eq(G.GaarGroupForeverDB.lfgTank, true, "lfgTank saved default")
local okSet = L.Set("tank", false)
eq(okSet, true, "tank off")
eq(G.GaarGroupForeverDB.lfgTank, false, "tank off saved")
L.Toggle("healer")
eq(L.IsOn("healer"), false, "healer toggled off")
local okLast, msg = L.Set("dps", false)
eq(okLast, false, "last role cannot be switched off")
ok(msg and msg:find("at least one", 1, true), "last role message")
eq(L.IsOn("dps"), true, "dps still on")
eq(L.NumOn(), 1, "one role on")
-- reload: the same saved table is bound again
M.BindSavedVariables()
eq(L.IsOn("tank"), false, "tank off after reload")
eq(L.IsOn("healer"), false, "healer off after reload")
eq(L.IsOn("dps"), true, "dps on after reload")
-- a broken saved value falls back to the default
G.GaarGroupForeverDB.lfgHealer = "x"; M.BindSavedVariables()
eq(L.IsOn("healer"), true, "bad saved value -> default on")
-- slash
M.OnSlash("lfg all"); eq(L.AllOn(), true, "/ggf lfg all")
M.OnSlash("lfg tank off"); eq(L.IsOn("tank"), false, "/ggf lfg tank off")
M.OnSlash("lfg heal off"); eq(L.IsOn("healer"), false, "/ggf lfg heal off (alias)")
M.OnSlash("lfg dps off"); eq(L.IsOn("dps"), true, "/ggf lfg dps off refused (last role)")
M.OnSlash("lfg tank on"); eq(L.IsOn("tank"), true, "/ggf lfg tank on")
M.OnSlash("lfg tank"); eq(L.IsOn("tank"), false, "/ggf lfg tank toggles")
M.OnSlash("lfg all")
eq(M.lastError, nil, "no error from the slash")

-- ---- 4. the Blizzard group finder loads ----
-- results: 1 = your own row, 2 = tank, 3 = healer, 4 = dps, 5 = tank+healer, 6 = a group,
-- 7 = no role, 8 = secret roles, 9 = tank (selected), 10 = tank scrolled out of view (no frame)
results[1] = { numMembers = 1, hasSelf = true, roles = { tank = true, healer = false, dps = false } }
results[2] = { numMembers = 1, hasSelf = false, roles = { tank = true, healer = false, dps = false } }
results[3] = { numMembers = 1, hasSelf = false, roles = { tank = false, healer = true, dps = false } }
results[4] = { numMembers = 1, hasSelf = false, roles = { tank = false, healer = false, dps = true } }
results[5] = { numMembers = 1, hasSelf = false, roles = { tank = true, healer = true, dps = false } }
results[6] = { numMembers = 3, hasSelf = false, roles = { tank = true, healer = false, dps = false } }
results[7] = { numMembers = 1, hasSelf = false, roles = { tank = false, healer = false, dps = false } }
results[8] = { numMembers = 1, hasSelf = false, roles = { tank = SECRET, healer = false, dps = false } }
results[9] = { numMembers = 1, hasSelf = false, roles = { tank = true, healer = false, dps = false } }
results[10] = { numMembers = 1, hasSelf = false, roles = { tank = true, healer = false, dps = false } }

local cards = {}
for i = 1, 9 do cards[i] = card(i, i == 9) end
local playersHeader, groupsHeader = header(1), header(2)
local list = { -- the active frames, as ForEachFrame hands them out: (frame, elementData)
    { cards[1], { data = { index = 1, resultID = 1 } } },
    { playersHeader, { data = { dividerType = 1 } } },
}
for i = 2, 9 do if i ~= 6 then list[#list + 1] = { cards[i], { data = { resultID = i, category = 1 } } } end end
list[#list + 1] = { groupsHeader, { data = { dividerType = 2 } } }
list[#list + 1] = { cards[6], { data = { resultID = 6, category = 2 } } }

local scrollBox = { }
function scrollBox:ForEachFrame(fn) for _, e in ipairs(list) do if fn(e[1], e[2]) then return end end end
local hooks = {}
local function original(c) c.updated = true end
G.LFGBrowseSearchEntry_Update = original
G.hooksecurefunc = function(a, b, c)
    if type(a) == "string" then hooks[a] = b else hooks[b] = c end
end
G.LFGVanillaBrowseDividerType = { CategorySolo = 1, CategoryGroup = 2 }
local browseScripts = {}
local browse = { ScrollBox = blizz("ScrollBox", scrollBox), results = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } }
function browse:HookScript(k, fn) browseScripts[k] = fn end
function browse:IsVisible() return true end
G.LFGBrowseFrame = blizz("LFGBrowseFrame", browse)

fire("ADDON_LOADED", "Blizzard_GroupFinder_VanillaStyle")
eq(L.installed, true, "installed on the Blizzard addon's ADDON_LOADED")
ok(hooks.LFGBrowseSearchEntry_Update, "card update hooked with hooksecurefunc")
eq(G.LFGBrowseSearchEntry_Update, original, "Blizzard's function not replaced")
ok(browseScripts.OnShow and browseScripts.OnHide, "OnShow/OnHide hooked with HookScript")
eq(driver.shown, true, "poll runs while the browse frame is shown")

local function alphaOf(i) return cards[i].alpha end
local function check(expectHidden, label)
    for i = 1, 9 do
        local hid = expectHidden[i] == true
        eq(alphaOf(i), hid and 0 or 1, label .. ": card " .. i .. " alpha")
        eq(cards[i].mouse, not hid, label .. ": card " .. i .. " mouse")
    end
end

-- all on: nothing touched, toggles on the Players header
L.Sync()
check({}, "all on")
eq(L.bar.shown, true, "toggles shown on the Players header")
local p = L.bar.points[1]
eq(p and p[2], playersHeader.CollapseIcon, "toggles anchored left of the Players header's -")
eq(L.bar.label.text, "", "no hidden count while all on")

-- tank off: tank-only solo players hidden; own row, group, multi-role, no-role, secret, selected shown
L.Set("tank", false)
check({ [2] = true }, "tank off")
eq(L.hiddenCount, 2, "tank off: 2 hidden (one scrolled out of view; the selected tank not)")
eq(L.cardsHidden, 1, "tank off: 1 card hidden on screen")
eq(L.bar.label.text, "2 hidden", "hidden count label")
eq(L.bar.buttons.tank.icon.desat, true, "tank icon greyed")
eq(L.bar.buttons.healer.icon.desat, false, "healer icon in colour")

-- tank and healer off: only dps or players with dps stay
L.Set("healer", false)
check({ [2] = true, [3] = true, [5] = true }, "tank+healer off")
eq(L.hiddenCount, 4, "tank+healer off: 4 hidden (the off-screen one counted, the selected one not)")

-- the card hook re-applies after Blizzard's own update (a pooled frame reused for another result)
rawset(cards[4], "resultID", 2) -- Blizzard reuses card 4's frame for result 2
hooks.LFGBrowseSearchEntry_Update(cards[4])
eq(cards[4].alpha, 0, "reused frame for a tank faded by the hook")
rawset(cards[4], "resultID", 4)
hooks.LFGBrowseSearchEntry_Update(cards[4])
eq(cards[4].alpha, 1, "reused frame for a dps restored by the hook")
eq(cards[4].mouse, true, "reused frame mouse restored")

-- a result update for one id refreshes that id
results[3].roles = { tank = false, healer = true, dps = true }
fire("LFG_LIST_SEARCH_RESULT_UPDATED", 3)
L.Sync()
eq(cards[3].alpha, 1, "healer who added dps is shown again after the update event")

-- no listing of your own: nothing filtered, toggles hidden
lfgState.listing = false
L.Changed()
check({}, "no listing")
eq(L.bar.shown, false, "toggles hidden without a listing")
lfgState.listing = true
L.Changed()

-- all on again: every card restored
M.OnSlash("lfg all")
check({}, "all on again")
eq(L.hiddenCount, 0, "nothing hidden when all on")

-- the Players header scrolled away: toggles hidden
table.remove(list, 2)
L.Sync()
eq(L.bar.shown, false, "toggles hidden without a Players header")

-- the poll and the browse OnHide
driver.scripts.OnUpdate(driver, 1)
browseScripts.OnHide()
eq(driver.shown, false, "poll stops when the browse frame hides")

M.OnSlash("status")
local sawFound = false
for _, s in ipairs(printed) do if s:find("viewer: LFGBrowseFrame found", 1, true) then sawFound = true end end
ok(sawFound, "status names the viewer frame")

eq(#blizzWrites, 0, "no field written on a Blizzard frame" .. (blizzWrites[1] and (" (" .. blizzWrites[1] .. ")") or ""))
eq(M.lastError, nil, "no error recorded" .. (M.lastError and (": " .. M.lastError) or ""))

if fails == 0 then print("group lfg filter test: ok") else print(fails .. " FAILED"); os.exit(1) end
