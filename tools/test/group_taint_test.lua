-- LuaJIT stub test: GaarGroupForever taint safety (1.4.1).
-- Run: luajit tools/test/group_taint_test.lua   (from the repo root)
--
-- Loads the whole addon (every file in TOC order) in a stub client that flags what the real client would
-- block or forbid:
--   * Show / Hide / SetPoint / SetSize / SetScale / SetParent / SetAttribute / ... in combat on a secure-template
--     frame, or on a frame that has a secure frame below it (the client protects the parents too)
--   * a secure frame created as the child of anything but UIParent, or anchored to anything but UIParent
--   * registering an event the client keeps from addons (COMBAT_LOG_EVENT_UNFILTERED: forbidden at load)
--   * calling a protected global (AssistUnit, TargetUnit, CastSpellByName, ...), at run time and in the source
-- and drives the login (solo), joining a party, each role, and in combat: roster changes, mode changes,
-- collapse, test mode, scale, drag, reset, leaving the party, the timers.
local noop = function() end
local violations = {}
local function flag(msg) violations[#violations + 1] = msg end

local state = { combat = false, group = false, raid = false, roles = {}, leader = {}, units = {} }
local frames, eventsOf = {}, {}

local FORBIDDEN_EVENTS = { COMBAT_LOG_EVENT_UNFILTERED = true, COMBAT_LOG_EVENT = true }
local RESTRICTED = { Show = true, Hide = true, SetShown = true, SetPoint = true, ClearAllPoints = true, SetAllPoints = true,
    SetSize = true, SetWidth = true, SetHeight = true, SetScale = true, SetParent = true, SetAttribute = true,
    RegisterForClicks = true, EnableMouse = true, SetFrameStrata = true, SetFrameLevel = true, StartMoving = true,
    StopMovingOrSizing = true, SetMovable = true, RegisterForDrag = true }
local PROTECTED = { "AssistUnit", "TargetUnit", "FocusUnit", "ClearTarget", "ClearFocus", "CastSpell", "CastSpellByName",
    "CastSpellByID", "UseAction", "RunMacro", "RunMacroText", "SetBinding", "SetBindingClick", "SetBindingSpell",
    "SetBindingMacro", "SetBindingItem", "SetOverrideBinding", "SetOverrideBindingClick", "SetOverrideBindingSpell",
    "SetOverrideBindingMacro", "SetOverrideBindingItem", "ClearOverrideBindings", "ToggleGameMenu", "ShowUIPanel",
    "HideUIPanel", "TargetNearestEnemy", "TargetLastTarget", "SpellStopCasting", "PetAttack", "UseContainerItem",
    "PickupAction", "PlaceAction", "TargetUnitByName", "AttackTarget", "StartAttack", "ToggleDropDownMenu",
    "EasyMenu", "UIDropDownMenu_Initialize", "RegisterStateDriver", "RegisterUnitWatch", "ChangeActionBarPage",
    "UnitPopup_ShowMenu", "JumpOrAscendStart", "MoveForwardStart", "Dismount", "CancelShapeshiftForm" }

-- ---- frames ----
local UIParent
local function isSecure(f) return f.secure == true end
local function hasSecureBelow(f)
    for _, c in ipairs(f.children) do
        if isSecure(c) or hasSecureBelow(c) then return true end
    end
    return false
end
local function protected(f) return isSecure(f) or hasSecureBelow(f) end

local W = {}
W.__index = function(t, k)
    local m = rawget(W, k)
    if m then return m end
    return function() return nil end -- any other widget method: a no-op
end
local function guard(f, method)
    if state.combat and RESTRICTED[method] and f ~= UIParent and protected(f) then
        flag("in combat: " .. tostring(f.name or "?") .. ":" .. method .. "()")
    end
end
local function newFrame(kind, name, parent, template)
    parent = type(parent) == "table" and parent or nil
    local f = setmetatable({ kind = kind, name = name, parent = parent, children = {}, shown = true, scripts = {},
        events = {}, attrs = {}, alpha = 1, scale = 1, x = 0, y = 0 }, W)
    f.secure = type(template) == "string" and template:find("Secure") ~= nil
    if parent then parent.children[#parent.children + 1] = f end
    if f.secure and parent ~= UIParent then
        flag("secure frame " .. tostring(name) .. " created under " .. tostring(parent and parent.name or "nil"))
    end
    frames[#frames + 1] = f
    return f
end
local function wrap(method, fn)
    W[method] = function(f, ...)
        guard(f, method)
        if fn then return fn(f, ...) end
    end
end
wrap("Show", function(f) f.shown = true end)
wrap("Hide", function(f) f.shown = false end)
wrap("SetShown", function(f, v) f.shown = v and true or false end)
wrap("SetPoint", function(f, _, rel)
    if isSecure(f) and type(rel) == "table" and rel ~= UIParent then
        flag("secure frame " .. tostring(f.name) .. " anchored to " .. tostring(rel.name))
    end
end)
for _, m in ipairs({ "ClearAllPoints", "SetAllPoints", "SetSize", "SetWidth", "SetHeight", "RegisterForClicks",
    "EnableMouse", "SetFrameStrata", "SetFrameLevel", "StartMoving", "StopMovingOrSizing", "SetMovable", "RegisterForDrag" }) do
    wrap(m)
end
wrap("SetScale", function(f, s) f.scale = s end)
wrap("SetAttribute", function(f, k, v) f.attrs[k] = v end)
wrap("SetParent", function(f, p)
    if rawget(f, "parent") then
        for i, c in ipairs(f.parent.children) do if c == f then table.remove(f.parent.children, i); break end end
    end
    f.parent = p
    if p then p.children[#p.children + 1] = f end
end)
function W.IsShown(f) return f.shown end
function W.IsVisible(f)
    local x = f
    while x do
        if not x.shown then return false end
        x = rawget(x, "parent")
    end
    return true
end
function W.SetAlpha(f, a) f.alpha = a end -- allowed on protected frames in combat
function W.GetAlpha(f) return f.alpha end
function W.GetLeft() return 100 end
function W.GetTop() return 400 end
function W.GetWidth() return 240 end
function W.GetHeight() return 30 end
function W.GetEffectiveScale(f) return f.scale end
function W.GetFrameLevel() return 5 end
function W.GetStringWidth() return 50 end
function W.GetStringHeight() return 12 end
function W.GetPoint() return "CENTER", UIParent, "CENTER", 0, -200 end
function W.GetName(f) return f.name end
function W.SetScript(f, k, fn) f.scripts[k] = fn end
function W.GetScript(f, k) return f.scripts[k] end
function W.HookScript(f, k, fn) local old = f.scripts[k]; f.scripts[k] = function(...) if old then old(...) end fn(...) end end
function W.IsMouseOver() return false end
function W.CreateTexture(f) return newFrame("Texture", nil, f) end
function W.CreateFontString(f) return newFrame("FontString", nil, f) end
function W.RegisterEvent(f, ev)
    if FORBIDDEN_EVENTS[ev] then flag("forbidden event registered: " .. ev) end
    f.events[ev] = true
    eventsOf[ev] = eventsOf[ev] or {}
    eventsOf[ev][#eventsOf[ev] + 1] = f
end
UIParent = newFrame("Frame", "UIParent", nil)

-- ---- client ----
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.UIParent = UIParent
G.GameTooltip = newFrame("GameTooltip", "GameTooltip", UIParent)
G.CreateFrame = function(kind, name, parent, template) return newFrame(kind, name, parent, template) end
G.UISpecialFrames = {}
G.SlashCmdList = {}
local printed = {}
G.GaarForever = {
    NewAddon = function() return { Print = function(_, m) printed[#printed + 1] = m end, title = "GaarGroupForever" } end,
    OnOff = function(v) return v and "on" or "off" end,
    IsSecret = function(v) return type(v) == "table" and v.secret == true end,
    Num = function(v) return type(v) == "number" and v or nil end,
    Str = function(v) return type(v) == "string" and v ~= "" and v or nil end,
    RenderMenu = noop,
    AttachMenu = noop,
    LevelDifficultyColor = function() return 1, 1, 1 end,
    PlayerFullName = function() return "Me" end,
    NamesMatch = function(a, b) return a == b end,
    UnitByName = function() return nil end,
    StripRealm = function(n) return n end,
}
G.InCombatLockdown = function() return state.combat end
G.UnitAffectingCombat = function() return state.combat end
G.IsInGroup = function() return state.group end
G.IsInRaid = function() return state.raid end
G.IsInInstance = function() return false end
G.GetInstanceInfo = function() return "Elwynn Forest", "none" end
G.UnitIsGroupLeader = function(u) return state.leader[u] or false end
G.UnitGroupRolesAssigned = function(u) return state.roles[u] or "NONE" end
G.UnitSetRole = function(u, r) state.roles[u] = r end
G.UnitExists = function(u) return u == "player" or (state.group and state.units[u]) or false end
G.UnitName = function(u) return u == "player" and "Me" or (state.units[u] and u) or nil end
G.UnitLevel = function() return 30 end
G.UnitClass = function() return "Priest", "PRIEST" end
G.UnitIsConnected = function() return true end
G.UnitIsDeadOrGhost = function() return false end
G.UnitIsVisible = function() return true end
G.UnitInRange = function() return true, true end
G.UnitHealth = function() return 100 end
G.UnitHealthMax = function() return 100 end
G.UnitPower = function() return 50 end
G.UnitPowerMax = function() return 100 end
G.UnitPowerType = function() return 0 end
G.UnitCanAttack = function() return false end
G.UnitIsUnit = function(a, b) return a == b end
G.UnitGUID = function(u) return u end
G.GetRaidTargetIndex = function() return nil end
G.GetTime = function() return state.now or 100 end
G.time = function() return 1000 end
G.date = function() return "12:34:56" end
G.DoReadyCheck = noop; G.InitiateRolePoll = noop; G.SendChatMessage = noop; G.SetRaidTarget = noop
G.C_Timer = { After = noop }
G.C_ChatInfo = { RegisterAddonMessagePrefix = noop, SendAddonMessage = noop }
G.C_PartyInfo = { DoCountdown = noop }
G.RAID_CLASS_COLORS = {}
for _, name in ipairs(PROTECTED) do
    G[name] = function() flag("protected function called: " .. name) end
end

-- ---- load the addon in TOC order ----
local dir = "addons/GaarGroupForever/"
local files = {}
for line in io.lines(dir .. "GaarGroupForever.toc") do
    line = line:gsub("\r", "")
    if line:match("%.lua$") and not line:match("^#") then files[#files + 1] = (line:gsub("\\", "/")) end
end
local sources = {}
for _, f in ipairs(files) do
    local fh = assert(io.open(dir .. f)); local src = fh:read("*a"); fh:close()
    sources[f] = src
    local chunk = assert(loadstring(src, "@" .. f)); setfenv(chunk, G); chunk("GaarGroupForever", {})
end
local M = G.GaarGroupForeverAPI._M
local R = M.Roles

local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end
local function fire(ev, ...)
    for _, f in ipairs(eventsOf[ev] or {}) do
        local fn = f.scripts.OnEvent
        if fn then fn(f, ev, ...) end
    end
end
local function pump(n)
    for _ = 1, n or 1 do
        state.now = (state.now or 100) + 1
        for _, f in ipairs(frames) do
            local fn = f.scripts.OnUpdate
            if fn and W.IsVisible(f) then fn(f, 1) end
        end
    end
end
local function noViolations(where)
    if #violations > 0 then
        fails = fails + 1
        print("FAIL " .. where .. ":")
        for _, v in ipairs(violations) do print("   " .. v) end
    end
    violations = {}
end

-- source scan: no protected global and no combat-log registration anywhere in the addon
for f, src in pairs(sources) do
    local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
    for _, name in ipairs(PROTECTED) do
        if code:find("[^%w_]" .. name .. "%s*%(") or code:find("_G%." .. name .. "[^%w_]") then
            flag("source " .. f .. " uses protected " .. name)
        end
    end
    if code:find('"COMBAT_LOG_EVENT') then flag("source " .. f .. " names a COMBAT_LOG_EVENT event") end
end
noViolations("source scan")
noViolations("file load")

-- 1. login solo, after /reload (the reported case): nothing forbidden, nothing secure
fire("ADDON_LOADED", "GaarGroupForever")
fire("PLAYER_ENTERING_WORLD")
fire("GROUP_ROSTER_UPDATE")
pump(5)
noViolations("login solo")
eq(M.bar, nil, "no bar solo")
eq(#R.secure, 0, "no secure frame solo")
eq(M.lastError, nil, "no error at login")

-- 2. join a party as healer, a tank in it (out of combat): the secure frames are made and shown
state.group = true; state.units = { party1 = true, party2 = true }
state.roles = { player = "HEALER", party1 = "TANK", party2 = "DAMAGER" }
fire("GROUP_ROSTER_UPDATE"); fire("PLAYER_ROLES_ASSIGNED")
pump(3)
noViolations("join party as healer")
local tank = M.Healer.tankFrame
eq(tank ~= nil, true, "tank frame made")
eq(tank and tank.parent, UIParent, "tank frame is a child of UIParent")
eq(tank and tank.shown, true, "tank frame shown")
eq(tank and tank.attrs.unit, "party1", "tank frame unit")
eq(tank and tank.alpha, 1, "tank frame visible")
-- the DPS row too
state.roles.player = "DAMAGER"; fire("PLAYER_ROLES_ASSIGNED"); pump(3)
noViolations("switch to dps")
local assist = M.Dps.assistButton
eq(assist and assist.parent, UIParent, "assist is a child of UIParent")
eq(assist and assist.shown, true, "assist shown")
eq(assist and assist.attrs.type, "assist", "assist type")
eq(assist and assist.attrs.unit, "party1", "assist unit")
eq(tank.shown, false, "tank frame hidden when not healer")
state.roles.player = "HEALER"; fire("PLAYER_ROLES_ASSIGNED"); pump(3)
eq(tank.shown, true, "tank frame back"); eq(assist.shown, false, "assist hidden when not dps")

-- detector check: a direct Hide in combat on the secure frame IS flagged (the stubs work)
state.combat = true
tank:Hide(); eq(#violations, 1, "detector flags a secure Hide in combat"); violations = {}
tank.shown = true
state.combat = false

-- 3. in combat: everything that moves the bar
state.combat = true
fire("PLAYER_REGEN_DISABLED")
pump(3)
for _, m in ipairs({ "tank", "dps", "healer" }) do -- mode buttons
    M.SetMode(m); M.Refresh(); pump(2)
end
state.roles.player = "HEALER"
state.roles.party1 = "DAMAGER"; state.roles.party2 = "TANK"; fire("GROUP_ROSTER_UPDATE"); pump(2) -- new tank
eq(tank.attrs.unit, "party1", "unit kept in combat")
eq(tank.alpha, 0, "stale tank frame faded in combat")
M.db.ovCollapsed = true; M.Refresh(); M.db.ovCollapsed = false; M.Refresh() -- collapse
M.db.markersOpen = false; M.Refresh(); M.db.markersOpen = true; M.Refresh()
M.db.instOpen = false; M.Refresh(); M.db.instOpen = true; M.Refresh()
M.SetScale(1.5); M.SetScale(1) -- scale
M.SetPreview(true); M.SetPreview(false) -- test mode
M.bar.scripts.OnDragStart(M.bar); M.bar.scripts.OnDragStop(M.bar) -- drag (locked or not)
M.ResetPos()
M.SetShow(false); M.SetShow(true) -- /ggf hide|show
if R.Slash then R.Slash("healer", "test"); R.Slash("dps", "test"); R.Slash("tank", "test") end
pump(3)
-- threat section (1.6.0) in combat: a hostile target appears and goes, the option flips
do
    local canAttack, uex, threat = G.UnitCanAttack, G.UnitExists, G.UnitDetailedThreatSituation
    G.UnitCanAttack = function(_, u) return u == "target" end
    G.UnitExists = function(u) return u == "target" or uex(u) end
    G.UnitDetailedThreatSituation = function(u) return u == "party2", u == "party2" and 3 or 0, u == "party2" and 100 or 30 end
    fire("PLAYER_TARGET_CHANGED"); fire("UNIT_THREAT_LIST_UPDATE", "target"); pump(3)
    eq(M.Threat.want, true, "threat section wanted in combat")
    M.OnSlash("threat off"); M.OnSlash("threat on"); pump(1)
    G.UnitCanAttack, G.UnitExists, G.UnitDetailedThreatSituation = canAttack, uex, threat
    fire("PLAYER_TARGET_CHANGED"); pump(2)
    eq(M.Threat.want, false, "threat section gone with the target")
end
state.group = false; state.units = {}; fire("GROUP_ROSTER_UPDATE"); pump(3) -- left the party in combat
eq(M.bar:IsShown(), false, "bar hidden in combat")
eq(tank.shown, true, "secure frame left alone in combat")
eq(tank.alpha, 0, "but faded out")
noViolations("combat paths")

-- 4. combat ends: the queued changes happen
state.combat = false
fire("PLAYER_REGEN_ENABLED"); pump(2)
noViolations("after combat")
eq(tank.shown, false, "tank frame hidden after combat (no party)")
eq(assist.shown, false, "assist hidden after combat")
state.group = true; state.units = { party1 = true, party2 = true }; fire("GROUP_ROSTER_UPDATE"); pump(2)
eq(tank.shown, true, "tank frame back in a party")
eq(tank.attrs.unit, "party2", "re-pointed out of combat")
eq(tank.alpha, 1, "visible again")
noViolations("back in party")

-- 5. diagnostic: blocked / forbidden actions of this addon are recorded, one chat note per session
local before = #printed
fire("ADDON_ACTION_FORBIDDEN", "OtherAddon", "CastSpellByName()")
eq(#M.blocked, 0, "other addons ignored")
fire("ADDON_ACTION_FORBIDDEN", "GaarGroupForever", "Frame:RegisterEvent()")
state.combat = true
fire("ADDON_ACTION_BLOCKED", "GaarGroupForever", "GaarGroupForeverTankFrame:Hide()")
state.combat = false
eq(#M.blocked, 2, "two recorded")
eq(M.blocked[1].func, "Frame:RegisterEvent()", "function name")
eq(M.blocked[1].combat, false, "out of combat")
eq(M.blocked[2].combat, true, "in combat")
eq(#printed - before, 1, "one chat note per session")
eq(printed[#printed]:find("blocked: Frame:RegisterEvent()", 1, true) ~= nil, true, "chat note text")
for i = 1, 30 do fire("ADDON_ACTION_BLOCKED", "GaarGroupForever", "f" .. i) end
eq(#printed - before, 1, "still one note")
eq(#M.BlockedLines(5), 5, "last 5 lines")
eq(M.BlockedLines(5)[5]:find("f30", 1, true) ~= nil, true, "newest last")
local n0 = #printed
M.OnSlash("status")
local listed = false
for i = n0 + 1, #printed do if printed[i]:find("f30", 1, true) then listed = true end end
eq(listed, true, "/ggf status lists them")

if fails == 0 then print("group taint test: ok") else print(fails .. " FAILED"); os.exit(1) end
