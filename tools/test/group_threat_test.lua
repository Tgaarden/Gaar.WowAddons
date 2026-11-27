-- LuaJIT stub test: GaarGroupForever 1.6.0 threat section (Threat.lua).
-- Run: luajit tools/test/group_threat_test.lua   (from the repo root)
--
-- Covers: which mob is measured (target vs targettarget), hidden solo / with no mob / option off, sorting
-- with plain numbers, the secret-value path (no error, nothing compared, values handed to the widgets),
-- and the in-combat show / hide that resizes the bar without the dock's full layout.
local noop = function() end
local SW, SH = 1000, 800
local state = { combat = false, group = true, now = 100 }

-- ---- a "secret" value: any comparison, sum or concatenation on it raises, like the 12.x client ----
local SECRET_MT = {}
for _, mm in ipairs({ "__lt", "__le", "__add", "__sub", "__mul", "__div", "__mod", "__pow", "__unm", "__concat", "__len" }) do
    SECRET_MT[mm] = function() error("attempt to use a secret value (" .. mm .. ")", 2) end
end
local function secret(v) return setmetatable({ isSecret = true, v = v }, SECRET_MT) end
local function isSecret(v) return type(v) == "table" and rawget(v, "isSecret") == true end

-- ---- frames with a little geometry (as group_height_test) ----
local function sfn(t, k) local f = function() return t end; rawset(t, k, f); return f end
local W = {}
W.__index = function(t, k)
    local m = rawget(W, k); if m then return m end
    if k == "icon" then return nil end -- a field some buttons have, not a method
    return sfn(t, k)
end
local frames = {}
local function frame(parent, kind)
    local f = setmetatable({ parent = parent, kind = kind, shown = true, w = 0, h = 0, pts = {}, scale = 1, scripts = {} }, W)
    frames[#frames + 1] = f
    return f
end
local UIParent = frame(nil); UIParent.w, UIParent.h = SW, SH
function W.SetSize(f, w, h) f.w, f.h = w, h end
function W.SetWidth(f, w) f.w = w end
function W.SetHeight(f, h) f.h = h end
function W.GetHeight(f) return f.h end
function W.GetWidth(f) return f.w end
function W.ClearAllPoints(f) f.pts = {} end
function W.SetPoint(f, p, rel, rp, x, y)
    if type(rel) ~= "table" then rel, rp, x, y = f.parent, rel, rp, x end
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
function W.GetLeft() return 100 end
function W.GetTop(f)
    local p, _, rp, _, y = f:GetPoint(1)
    if not p then return nil end
    local ay = rp:find("TOP") and SH or rp:find("BOTTOM") and 0 or SH / 2
    local py = ay + y
    if p:find("TOP") then return py elseif p:find("BOTTOM") then return py + f.h else return py + f.h / 2 end
end
function W.SetScript(f, k, fn) f.scripts[k] = fn end
function W.CreateTexture(f) return frame(f, "Texture") end
function W.CreateFontString(f) return frame(f, "FontString") end
function W.SetText(f, s)
    if isSecret(s) then f.text = s else f.text = s end
end
-- The client's SetFormattedText takes a secret: here it records it and formats only plain values.
function W.SetFormattedText(f, fmt, v)
    if isSecret(v) then f.text = { fmt = fmt, secret = v } else f.text = string.format(fmt, v) end
end
function W.SetValue(f, v) f.value = v end
function W.SetStatusBarColor(f, r, g, b) f.color = { r, g, b } end
function W.SetVertexColor(f, r, g, b, a) f.vc = { r, g, b, a }; f.vcFlag = nil end
function W.SetVertexColorFromBoolean(f, flag) f.vcFlag = flag end
local events = {}
function W.RegisterEvent(f, ev) events[ev] = events[ev] or {}; table.insert(events[ev], f) end

-- ---- client ----
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.UIParent = UIParent
G.GameTooltip = frame(nil)
G.CreateFrame = function(kind, _, parent) return frame(parent or UIParent, kind) end
G.CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
G.GaarForever = {
    NewAddon = function() return { Print = noop, title = "GaarGroupForever" } end,
    OnOff = function(v) return v and "on" or "off" end,
    IsSecret = isSecret, -- the mocked secret helper
    Num = function(v) if isSecret(v) then return nil end return type(v) == "number" and v or nil end,
    Str = function(v) return type(v) == "string" and v ~= "" and v or nil end,
    RenderMenu = noop,
    PlayerFullName = function() return "Me" end,
    NamesMatch = function() return false end,
    UnitByName = noop,
    StripRealm = function(n) return n end,
}
G.SlashCmdList = {}; G.UISpecialFrames = {}
G.RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 }, MAGE = { r = 0.25, g = 0.78, b = 0.92 },
    PRIEST = { r = 1, g = 1, b = 1 } }

-- the world: party members, units and what each one targets
local units = {
    player = { name = "Me", class = "PRIEST" },
    party1 = { name = "Tanky", class = "WARRIOR" },
    party2 = { name = "Zap", class = "MAGE" },
}
local mobs = {} -- unit token -> { name, hostile (true/false/secret), dead }
local threat = {} -- [member] = { tanking, status, scaled }
G.IsInGroup = function() return state.group end
G.IsInRaid = function() return false end
G.UnitExists = function(u)
    if u == "player" then return true end
    if u:find("^party") then return state.group and units[u] ~= nil end
    return mobs[u] ~= nil
end
G.UnitName = function(u) local x = units[u] or mobs[u]; return x and x.name or nil end
G.UnitClass = function(u) local x = units[u]; if x then return x.class, x.class end end
G.UnitIsDeadOrGhost = function(u) return mobs[u] and mobs[u].dead or false end
G.UnitCanAttack = function(_, u) local m = mobs[u]; if not m then return false end return m.hostile end
G.UnitGroupRolesAssigned = function(u) return u == "party1" and "TANK" or "NONE" end
G.InCombatLockdown = function() return state.combat end
G.GetTime = function() return state.now end
G.C_Timer = { After = noop }
G.SendChatMessage = noop
G.UnitDetailedThreatSituation = function(member, mob)
    if not mobs[mob] then return nil end
    local t = threat[member]
    if not t then return nil end
    return t[1], t[2], t[3], t[3], 1000
end
G.UnitThreatSituation = function(member) local t = threat[member]; return t and t[2] or nil end

local function load(path)
    local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
    local c = assert(loadstring(src, path)); setfenv(c, G); c("GaarGroupForever", {})
end
local dir = "addons/GaarGroupForever/"
load(dir .. "GaarGroupForever.lua")
local M = G.GaarGroupForeverAPI._M
for _, f in ipairs({ "Overview", "Checks", "Markers", "RunLog", "Roles", "Tank", "Healer", "Dps", "Threat" }) do load(dir .. f .. ".lua") end
G.GaarGroupForeverDB = { pos = { p = "TOPLEFT", rp = "BOTTOMLEFT", x = 100, y = 600 } }
G.GaarGroupForeverCharDB = nil
M.BindSavedVariables()

local T, D = M.Threat, M.Dock
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end
local function fire(ev, ...) for _, f in ipairs(events[ev] or {}) do if f.scripts.OnEvent then f.scripts.OnEvent(f, ev, ...) end end end
local function order() local o = {}; for i, e in ipairs(T.list) do o[i] = e.unit end return table.concat(o, ",") end

eq(T ~= nil, true, "Threat module loaded")
eq(T.panelIndex, #D.panels, "threat is the last dock panel")
eq(M.db.threat, true, "option on by default")
for _, ev in ipairs({ "UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE", "PLAYER_TARGET_CHANGED", "UNIT_TARGET",
    "GROUP_ROSTER_UPDATE" }) do
    eq(events[ev] ~= nil, true, "registered " .. ev)
end
eq(events.COMBAT_LOG_EVENT_UNFILTERED, nil, "no combat log")

M.CreateBar(); M.Refresh(); D.Update()
local bar = M.bar
eq(bar:IsShown(), true, "bar shown in a party")
local topY = bar:GetTop()

-- ---- no mob: hidden, bar at its base height ----
T.Update()
eq(T.want, false, "no target: hidden")
local h0 = bar:GetHeight()
local tf = T.EnsureFrame()
eq(tf:IsShown(), false, "section frame hidden with no mob")

-- ---- target hostile: measured, shown, bar grows by the section ----
mobs.target = { name = "Boar", hostile = true }
threat = { player = { false, 0, 40 }, party1 = { true, 3, 100 }, party2 = { false, 0, 75 } }
fire("PLAYER_TARGET_CHANGED")
eq(T.want, true, "hostile target: shown")
eq(T.mob, "target", "mob = target"); eq(T.via, "target", "via target")
eq(#T.list, 3, "one bar per member (you included)")
eq(order(), "party1,party2,player", "sorted highest first")
eq(T.mode, "plain", "plain values")
eq(tf:IsShown(), true, "section frame shown")
eq(bar:GetHeight(), h0 + T.Height(3) + M.Metrics.gap, "bar grew by the section")
eq(bar:GetTop(), topY, "top edge unchanged")
local r1, r2, r3 = T.rows[1], T.rows[2], T.rows[3]
eq(r1.name.text, "Tanky", "row 1 name"); eq(r1.pct.text, "100%", "row 1 pct"); eq(r1.value, 100, "row 1 bar value")
eq(r1.icon.shown, true, "aggro icon on the tank"); eq(r1.hl.shown, true, "aggro tint on the tank")
eq(r2.icon.shown, false, "no aggro icon on row 2")
eq(r2.pct.text, "75%", "row 2 pct"); eq(r3.pct.text, "40%", "row 3 pct")
eq(r1.color[1], 0.78, "class colour (warrior)")
eq(T.head.text, "Threat: Boar", "header names the mob")
eq(T.rows[4].shown, false, "unused row hidden")

-- not on the threat list: "-" and last
threat.party2 = nil
T.Update()
eq(order(), "party1,player,party2", "member without threat sorted last")
eq(T.rows[3].pct.text, "-", "no threat shows -")

-- ---- target friendly (the tank), its target hostile: targettarget ----
mobs.target = { name = "Tanky", hostile = false }
mobs.targettarget = { name = "Wolf", hostile = true }
threat = { player = { false, 1, 90 }, party1 = { true, 3, 100 }, party2 = { false, 0, 10 } }
fire("UNIT_TARGET", "target")
eq(T.mob, "targettarget", "friendly target -> targettarget")
eq(T.head.text, "Threat: Wolf (target's target)", "header says target's target")
eq(order(), "party1,player,party2", "sorted on targettarget")
-- a hostile target wins over targettarget
mobs.target = { name = "Boar", hostile = true }
T.Update()
eq(T.mob, "target", "hostile target preferred")
-- both friendly: hidden
mobs.target = { name = "Tanky", hostile = false }; mobs.targettarget = { name = "Me", hostile = false }
T.Update()
eq(T.want, false, "friendly target and targettarget: hidden")
eq(bar:GetHeight(), h0, "bar shrinks back")
-- dead hostile target: not measured
mobs.target = { name = "Boar", hostile = true, dead = true }; mobs.targettarget = nil
T.Update()
eq(T.want, false, "dead target: hidden")

-- ---- solo: hidden (even with a hostile target) ----
mobs.target = { name = "Boar", hostile = true }
state.group = false; M.Refresh(); T.Update()
eq(T.want, false, "solo: hidden")
eq(bar:IsShown(), false, "bar hidden solo")
-- test mode shows it solo (to try it on a dummy)
M.SetPreview(true); T.Update()
eq(T.want, true, "test mode: shown solo with a hostile target")
eq(#T.list, 1, "solo: only you")
M.SetPreview(false)
state.group = true; M.Refresh(); D.Update(); T.Update()
eq(T.want, true, "back in group")

-- ---- option off ----
M.OnSlash("threat off")
eq(M.db.threat, false, "/ggf threat off")
eq(T.want, false, "option off: hidden")
eq(bar:GetHeight(), h0, "option off: bar shrinks")
M.OnSlash("threat on")
eq(T.want, true, "/ggf threat on")

-- ---- secret values: no error, nothing compared, the client gets the raw values ----
M.lastError = nil
local sPct = { player = secret(55), party1 = secret(100), party2 = secret(80) }
local sTank = { player = secret(false), party1 = secret(true), party2 = secret(false) }
threat = {}
for u in pairs(units) do threat[u] = { sTank[u], secret(0), sPct[u] } end
T.Update(); state.now = state.now + 1; T.Update()
eq(M.lastError, nil, "secret: no error (" .. tostring(M.lastError) .. ")")
eq(T.mode, "secret", "secret mode")
eq(order(), "player,party1,party2", "secret: party order (nothing sorted by a secret)")
eq(T.rows[1].value, sPct.player, "secret % handed to StatusBar:SetValue")
eq(type(T.rows[1].pct.text) == "table" and T.rows[1].pct.text.secret, sPct.player, "secret % handed to SetFormattedText")
eq(T.rows[2].hl.vcFlag, sTank.party1, "secret isTanking handed to SetVertexColorFromBoolean")
eq(T.rows[2].icon.vcFlag, sTank.party1, "aggro icon tinted by the client too")
eq(T.rows[2].hl.shown, true, "tint texture shown (the client picks its colour)")
-- secret % but a plain isTanking/status: sorted by those only
threat = { player = { false, 0, secret(55) }, party1 = { true, 3, secret(100) }, party2 = { false, 1, secret(80) } }
T.Update()
eq(M.lastError, nil, "mixed: no error")
eq(order(), "party1,party2,player", "secret %: sorted by plain aggro, then status")
-- some secret, some plain %: never mixed into one comparison
threat = { player = { false, 0, 99 }, party1 = { true, 3, secret(100) }, party2 = { false, 0, 20 } }
T.Update()
eq(M.lastError, nil, "partly secret: no error")
eq(order(), "party1,player,party2", "partly secret: % not used, aggro first then party order")
eq(T.rows[2].pct.text, "99%", "plain % still written plainly")
-- a client that refuses the secret in SetFormattedText: "?" and no error
local sft = W.SetFormattedText
W.SetFormattedText = function(f, fmt, v) if isSecret(v) then error("refused") end return sft(f, fmt, v) end
threat = { player = { false, 0, secret(1) }, party1 = { true, 3, secret(2) }, party2 = { false, 0, secret(3) } }
T.Update()
eq(M.lastError, nil, "refused secret text: no error")
eq(T.rows[1].pct.text, "?", "refused secret text shows ?")
W.SetFormattedText = sft
-- UnitCanAttack secret: still measured (target preferred), no error
mobs.target = { name = "Boar", hostile = secret(true) }
T.Update()
eq(T.want, true, "secret UnitCanAttack: measured")
eq(T.mob, "target", "secret UnitCanAttack: target")
mobs.targettarget = { name = "Wolf", hostile = true }
T.Update()
eq(T.mob, "targettarget", "plainly hostile targettarget beats a secret target")
mobs.targettarget = nil
-- status line with secrets
local st = T.StatusText()
eq(st:find("secret") ~= nil, true, "status line names the secret path")
M.OnSlash("status")
eq(M.lastError, nil, "/ggf status ok")

-- ---- in combat: show / hide resizes the bar without the dock's full layout ----
mobs.target = { name = "Boar", hostile = true }
threat = { player = { false, 0, 40 }, party1 = { true, 3, 100 }, party2 = { false, 0, 75 } }
T.Update()
local hShown = bar:GetHeight()
eq(hShown, h0 + T.Height(3) + M.Metrics.gap, "shown height before combat")
state.combat = true
local layoutCalls = T.combatLayouts
mobs.target = nil; fire("PLAYER_TARGET_CHANGED")
eq(T.want, false, "combat: target gone, hidden")
eq(tf:IsShown(), false, "combat: section hidden")
eq(bar:GetHeight(), h0, "combat: bar shrinks")
eq(bar:GetTop(), topY, "combat: top unchanged")
mobs.target = { name = "Boar", hostile = true }; fire("PLAYER_TARGET_CHANGED")
eq(tf:IsShown(), true, "combat: section shown again")
eq(bar:GetHeight(), hShown, "combat: bar grows back to the same height")
eq(bar:GetTop(), topY, "combat: top unchanged after growing")
eq(T.combatLayouts, layoutCalls + 2, "combat path used twice")
-- the 0.3 s tick runs while shown and updates the values
threat.player = { false, 1, 95 }
state.now = state.now + 1
T.tick.scripts.OnUpdate(T.tick, 0.31)
eq(order(), "party1,player,party2", "tick re-sorts")
-- a party member joins in combat: section grows by one bar
units.party3 = { name = "Heals", class = "PRIEST" }
threat.party3 = { false, 0, 5 }
fire("GROUP_ROSTER_UPDATE")
eq(#T.list, 4, "combat: new member listed")
eq(bar:GetHeight(), h0 + T.Height(4) + M.Metrics.gap, "combat: grows by one bar")
-- not TOP-anchored: waits for the end of combat instead
bar.pts[1][1] = "CENTER"
local deferred = T.deferred
mobs.target = nil; fire("PLAYER_TARGET_CHANGED")
eq(T.deferred, deferred + 1, "not TOP-anchored: deferred")
bar.pts[1][1] = "TOPLEFT"
units.party3, threat.party3 = nil, nil -- (the overview list is back to its old size too)
state.combat = false
fire("PLAYER_REGEN_ENABLED")
eq(bar:GetHeight(), h0, "after combat: laid out")
eq(tf:IsShown(), false, "after combat: hidden")
eq(M.lastError, nil, "no error overall (" .. tostring(M.lastError) .. ")")

if fails == 0 then print("group threat: all ok") else print(fails .. " FAILED"); os.exit(1) end
