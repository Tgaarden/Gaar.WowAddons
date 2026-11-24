-- LuaJIT stub test: GaarGroupForever 1.0 - visibility, mode -> role, countdown fallback, leader gating.
-- Run: luajit tools/test/group_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarGroupForever/GaarGroupForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__M = M\n"

local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.GaarForever = {
    NewAddon = function() return { Print = noop, title = "GaarGroupForever" } end,
    OnOff = function(v) return v and "on" or "off" end,
    IsSecret = function() return false end,
    Num = function(v) return type(v) == "number" and v or nil end,
    RenderMenu = noop,
}
G.SlashCmdList = {}; G.UIParent = widget(); G.GameTooltip = widget()
G.CreateFrame = function() return widget() end
local state = { group = false, raid = false, leader = false, role = "NONE" }
G.IsInGroup = function() return state.group end
G.IsInRaid = function() return state.raid end
G.UnitIsGroupLeader = function() return state.leader end
G.UnitGroupRolesAssigned = function() return state.role end
local setRole = {}
G.UnitSetRole = function(u, r) setRole[#setRole + 1] = u .. ":" .. r; state.role = r end
G.DoReadyCheck = noop; G.InitiateRolePoll = noop
local chat, timers = {}, {}
G.SendChatMessage = function(t, ch) chat[#chat + 1] = ch .. ":" .. t end
G.C_Timer = { After = function(d, fn) timers[#timers + 1] = { d, fn } end }

local chunk = assert(loadstring(src, "group")); setfenv(chunk, G); chunk("GaarGroupForever")
local M = G.__M
G.GaarGroupForeverDB = nil; G.GaarGroupForeverCharDB = nil
M.BindSavedVariables()

local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

-- visibility: party only
state.group, state.raid = false, false
eq(M.ShouldShow(), false, "solo hidden")
state.group = true
eq(M.ShouldShow(), true, "party shown")
state.raid = true
eq(M.ShouldShow(), false, "raid hidden")
state.raid = false
M.db.show = false
eq(M.ShouldShow(), false, "option off hides in party")
M.db.show = true
state.group = false; M.preview = true
eq(M.ShouldShow(), true, "test preview shows solo")
M.preview = false

-- mode -> role
state.group = true
for key, role in pairs({ tank = "TANK", dps = "DAMAGER", healer = "HEALER" }) do
    setRole = {}
    local m, result = M.SetMode(key)
    eq(m and m.role, role, key .. " role")
    eq(setRole[1], "player:" .. role, key .. " UnitSetRole")
    eq(result, "set", key .. " result")
    eq(M.cdb.mode, key, key .. " saved")
    eq(M.ActiveMode(), key, key .. " active follows game role")
end
state.role = "HEALER"; eq(M.ActiveMode(), "healer", "external role change reflected")
state.group = false; setRole = {}
local _, r = M.SetMode("tank")
eq(#setRole, 0, "solo: no UnitSetRole"); eq(r, "saved", "solo: saved only"); eq(M.ActiveMode(), "tank", "solo: saved mode active")
eq(M.SetMode("bogus"), nil, "unknown mode")

-- joining a party with no role applies the saved mode once
state.group, state.role, setRole = false, "NONE", {}
M.wasInGroup = false; M.cdb.mode = "dps"
state.group = true; M.OnRosterUpdate()
eq(setRole[1], "player:DAMAGER", "saved mode applied on join")
M.OnRosterUpdate()
eq(#setRole, 1, "applied once")

-- leader gating
state.group = true; state.leader = false
eq((M.ReadyState()), false, "ready needs leader"); eq((M.RoleState()), false, "role needs leader")
state.leader = true
eq((M.ReadyState()), true, "ready for leader"); eq((M.RoleState()), true, "role for leader")
local d = G.DoReadyCheck; G.DoReadyCheck = nil
eq((M.ReadyState()), false, "no DoReadyCheck API"); G.DoReadyCheck = d

-- countdown: fallback (no C_PartyInfo): chat sequence, no leader needed
local plan = M.CountdownPlan(5)
local want = { { 0, "Pull in 5" }, { 1, "4" }, { 2, "3" }, { 3, "2" }, { 4, "1" }, { 5, "Go!" } }
eq(#plan, #want, "plan length")
for i, w in ipairs(want) do eq(plan[i][1] .. plan[i][2], w[1] .. w[2], "plan step " .. i) end
state.leader = false
eq((M.CountState()), true, "fallback countdown needs no leader")
chat, timers = {}, {}
eq(M.StartCountdown(3), "chat", "fallback used")
eq(#chat, 0, "nothing sent before the timers")
for _, t in ipairs(timers) do t[2]() end
eq(table.concat(chat, "|"), "PARTY:Pull in 3|PARTY:2|PARTY:1|PARTY:Go!", "chat sequence")
eq(M.fallbackRunning, false, "fallback finished")
-- leaving the party mid-countdown stops it
chat, timers = {}, {}
M.StartCountdown(3); timers[1][2](); state.group = false
for i = 2, #timers do timers[i][2]() end
eq(table.concat(chat, "|"), "PARTY:Pull in 3", "stops when the party is left")
state.group = true; M.fallbackRunning = false

-- countdown: native, leader gated
local called
G.C_PartyInfo = { DoCountdown = function(n) called = n; return true end }
state.leader = false
eq((M.CountState()), false, "native countdown needs leader")
eq(M.StartCountdown(10), nil, "native: refused for non-leader")
state.leader = true
eq(M.StartCountdown(10), "native", "native used"); eq(called, 10, "native length")
chat = {}; M.ShortcutCount(); eq(called, 5, "default length 5")
M.SetCountdown(3); M.ShortcutCount(); eq(called, 3, "default length option")
eq(M.SetCountdown(7), false, "only 3/5/10")

-- test mode: a menu checkbox (just before Reset) that follows M.preview, and the same switch as /ggf test
do
    local entries = M.MenuEntries()
    local ti, last
    for i, e in ipairs(entries) do if e.text == "Test mode" then ti = i end; last = i end
    eq(ti ~= nil, true, "menu has Test mode")
    eq(entries[ti].checkbox, true, "Test mode is a checkbox")
    eq(entries[last].text, "Reset position", "Reset stays last")
    eq(ti, last - 1, "Test mode sits just before Reset")
    state.group, state.raid = false, false; M.preview = false
    eq(entries[ti].checked(), false, "test off")
    entries[ti].func()
    eq(entries[ti].checked(), true, "test on after click"); eq(M.ShouldShow(), true, "solo bar shown in test")
    M.OnSlash("test")
    eq(M.preview, false, "/ggf test toggles it back off"); eq(M.ShouldShow(), false, "solo bar hidden again")
end

if fails == 0 then print("group_test: ok") else os.exit(1) end
