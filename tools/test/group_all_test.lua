-- LuaJIT stub test: GaarGroupForever 1.2 - Overview, Checks, Markers, RunLog.
-- Run: luajit tools/test/group_all_test.lua   (from the repo root)
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
    IsSecret = function(v) return type(v) == "table" and v.secret == true end,
    Num = function(v) return type(v) == "number" and v or nil end,
    RenderMenu = noop,
}
G.SlashCmdList = {}; G.UIParent = widget(); G.GameTooltip = widget()
G.CreateFrame = function() return widget() end
G.UISpecialFrames = {}
local state = { group = true, raid = false }
G.IsInGroup = function() return state.group end
G.IsInRaid = function() return state.raid end

local function load(path)
    local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
    local chunk = assert(loadstring(src, path)); setfenv(chunk, G); chunk("GaarGroupForever")
end
local base = "addons/GaarGroupForever/"
load(base .. "GaarGroupForever.lua")
local M = G.GaarGroupForeverAPI._M
for _, f in ipairs({ "Overview", "Checks", "Markers", "RunLog" }) do load(base .. f .. ".lua") end
G.GaarGroupForeverDB = nil; G.GaarGroupForeverCharDB = nil
M.BindSavedVariables()

local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

-- defaults: all on, kept through BindSavedVariables
for _, k in ipairs({ "overview", "checks", "markers", "markersOpen", "runlog" }) do eq(M.db[k], true, "default " .. k) end
eq(M.db.ovCollapsed, false, "default ovCollapsed")
-- menu: parts are merged in
local n = 0
for _, e in ipairs(M.MenuEntries()) do if e.text == "Pre-pull check button" or e.text == "Raid marker row"
    or e.text == "Record dungeon runs" or e.text == "Group overview" then n = n + 1 end end
eq(n, 4, "menu entries of the four modules")
eq(type(M.Slash.check) .. type(M.Slash.log) .. type(M.Slash.marks) .. type(M.Slash.group), "functionfunctionfunctionfunction", "slash")

-- ---- Overview ----
local O = M.Overview
eq(O.StatusOf({ connected = false, dead = true }), "offline", "offline wins")
eq(O.StatusOf({ connected = true, dead = true }), "dead", "dead")
eq(O.StatusOf({ connected = true, dead = false, inRange = false }), "far", "far")
eq(O.StatusOf({ connected = true, dead = false, visible = false }), "far", "not visible")
eq(O.StatusOf({ connected = true, dead = false, inRange = nil }), "ok", "unknown range is ok")
G.UnitInRange = function() return false, false end; G.CheckInteractDistance = nil
eq(O.InRange("party1"), nil, "range unchecked -> unknown")
G.UnitInRange = function() return false, true end
eq(O.InRange("party1"), false, "range out")
G.UnitInRange = function() return { secret = true }, true end
eq(O.InRange("party1"), nil, "secret range -> unknown")
G.UnitInRange = nil
G.CheckInteractDistance = function() return true end
eq(O.InRange("party1"), true, "interact fallback")
eq(O.InRange("player"), true, "player in range")
G.UnitExists = function(u) return u == "party1" or u == "party3" end
local units = O.Units()
eq(table.concat(units, ","), "player,party1,party3", "units")
state.group = false; local ue = G.UnitExists; G.UnitExists = function() return false end
eq(#O.Units(), 0, "solo no units"); M.preview = true; eq(#O.Units(), 1, "preview solo"); M.preview = false
state.group = true; G.UnitExists = ue
G.UnitName = function(u) return u == "party1" and { secret = true } or "Dru" end
eq(O.Member("party1").name, "?", "secret name -> ?")
G.UnitIsConnected = function() return false end
eq(O.Member("party3").status, "offline", "member offline")

-- ---- Checks ----
local C = M.Checks
local function mem(t) t.name = t.name or "X"; return t end
local rep = C.Evaluate({
    mem({ name = "Pri", class = "PRIEST", hasMana = true, mana = 0.9, buffs = { ["Power Word: Fortitude"] = true } }),
    mem({ name = "War", class = "WARRIOR", buffs = {} }),
    mem({ name = "Mag", class = "MAGE", hasMana = true, mana = 0.3, buffs = { ["Power Word: Fortitude"] = true } }),
    mem({ name = "Ded", class = "ROGUE", dead = true }),
    mem({ name = "Off", class = "ROGUE", offline = true }),
    mem({ name = "Far", class = "HUNTER", hasMana = true, mana = 0.5, far = true, buffs = { ["Power Word: Fortitude"] = true } }),
}, {})
eq(table.concat(rep.dead, ","), "Ded", "dead"); eq(table.concat(rep.offline, ","), "Off", "offline")
eq(table.concat(rep.far, ","), "Far", "far")
eq(#rep.lowmana, 1, "low mana count"); eq(rep.lowmana[1].name, "Mag", "low mana who"); eq(rep.lowmana[1].pct, 30, "pct")
-- hunter at exactly 50% is not low; warrior has no mana so no low mana even with mana nil
-- providers present: priest, mage. Fortitude missing: War only. Intellect: mages only matter for mana users: Pri, Mag, Far lack it.
local miss = {}
for _, e in ipairs(rep.missing) do miss[e.label] = table.concat(e.names, ",") end
eq(miss["Power Word: Fortitude"], "War", "fortitude missing")
eq(miss["Arcane Intellect"], "Pri,Mag,Far", "intellect only mana users")
eq(miss["Mark of the Wild"], nil, "no druid in party -> not checked")
eq(miss["a Blessing"], nil, "no paladin -> not checked")
eq(rep.ok, false, "not ok")
-- blessing prefix + druid gift
local rep2 = C.Evaluate({
    mem({ name = "Pal", class = "PALADIN", buffs = { ["Greater Blessing of Kings"] = true, ["Mark of the Wild"] = true } }),
    mem({ name = "Dru", class = "DRUID", buffs = { ["Gift of the Wild"] = true, ["Blessing of Might"] = true } }),
    mem({ name = "Rog", class = "ROGUE", buffs = { ["Mark of the Wild"] = true, ["Blessing of Might"] = true } }),
})
eq(#rep2.missing, 0, "all buffed"); eq(rep2.ok, true, "ok")
eq(C.Chunks(rep2)[1], "Pre-pull: all clear", "all clear text")
local rep3 = C.Evaluate({ mem({ name = "Pal", class = "PALADIN", buffs = {} }), mem({ name = "Rog", class = "ROGUE", buffs = { ["Blessing of Might"] = true } }) })
eq(table.concat(rep3.missing[1].names, ","), "Pal", "paladin without blessing")
-- unknown buffs skipped, not flagged
local rep4 = C.Evaluate({ mem({ name = "Pri", class = "PRIEST" }), mem({ name = "War", class = "WARRIOR" }) })
eq(#rep4.missing, 0, "unknown buffs not judged"); eq(rep4.unknown, 2, "unknown count")
local rep5 = C.Evaluate({ mem({ name = "Pri", class = "PRIEST", buffs = {} }) }, { buffsSkipped = true })
eq(#rep5.missing, 0, "combat skips buffs"); eq(rep5.buffsSkipped, true, "flag")
-- chunks split under 250
local many = {}
for i = 1, 30 do many[i] = mem({ name = "Player" .. i, class = "ROGUE", dead = true }) end
local chunks = C.Chunks(C.Evaluate(many))
local okLen = true
for _, c in ipairs(chunks) do if #c > 250 then okLen = false end end
eq(okLen, true, "chunks <= 250")
local rp = C.Evaluate({ mem({ name = "A", class = "ROGUE", dead = true }), mem({ name = "B", class = "MAGE", hasMana = true, mana = 0.2, buffs = { ["Arcane Intellect"] = true } }) })
eq(C.Chunks(rp)[1], "Pre-pull: Dead: A; Low mana: B 20%", "summary text")
-- ReadBuffs and ManaOf
G.C_UnitAuras = { GetAuraDataByIndex = function(_, i) local l = { { name = "Mark of the Wild" }, { name = "Thorns" } }; return l[i] end }
eq(C.ReadBuffs("party1")["Thorns"], true, "read buffs")
G.C_UnitAuras = { GetAuraDataByIndex = function() return { name = { secret = true } } end }
eq(C.ReadBuffs("party1"), nil, "secret aura name -> unknown")
G.C_UnitAuras = nil
G.UnitPowerType = function() return 0 end; G.UnitPower = function() return 40 end; G.UnitPowerMax = function() return 100 end
local has, frac = C.ManaOf("party1"); eq(has, true, "mana user"); eq(frac, 0.4, "mana fraction")
G.UnitPower = function() return { secret = true } end
has, frac = C.ManaOf("party1"); eq(frac, nil, "secret mana skipped")
G.UnitPowerType = function() return 1 end
has = C.ManaOf("party1"); eq(has, false, "rage user has no mana")
-- announce only on call, to PARTY
local sent = {}
G.SendChatMessage = function(t, ch) sent[#sent + 1] = ch .. ":" .. t end
eq(#sent, 0, "nothing sent by itself")
G.UnitExists = function() return false end; G.UnitName = function() return "Me" end
G.UnitIsConnected = function() return true end; G.UnitIsDeadOrGhost = function() return true end
G.UnitClass = function() return "Rogue", "ROGUE" end
C.Announce()
eq(sent[1], "PARTY:Pre-pull: Dead: Me", "announce to party")

-- ---- Markers ----
local K = M.Markers
local function near(a, b) return math.abs(a - b) < 1e-9 end
local l, r, t, b = K.Coords(1); eq(near(l, 0) and near(r, .25) and near(t, 0) and near(b, .25), true, "star coords")
l, r, t, b = K.Coords(4); eq(near(l, .75) and near(t, 0), true, "triangle coords")
l, r, t, b = K.Coords(5); eq(near(l, 0) and near(t, .25), true, "moon coords")
l, r, t, b = K.Coords(8); eq(near(l, .75) and near(r, 1) and near(t, .25) and near(b, .5), true, "skull coords")
eq(#K.NAMES, 8, "8 names"); eq(K.NAMES[8], "Skull", "skull")
local calls = {}
G.SetRaidTarget = function(u, i) calls[#calls + 1] = u .. ":" .. i end
G.UnitExists = function(u) return u == "target" end
K.Mark(3, "LeftButton"); eq(calls[1], "target:3", "left marks")
K.Mark(3, "RightButton"); eq(calls[2], "target:0", "right clears")
G.UnitExists = function() return false end
calls = {}; K.Mark(3, "LeftButton"); eq(#calls, 0, "no target no call")
G.GetRaidTargetIndex = function(u) if u == "party2" or u == "target" then return 5 end return nil end
eq(K.ClearAll(), 2, "clear all count")
eq(calls[1] .. calls[2], "target:0party2:0" , "clear all units")

-- ---- RunLog ----
local R = M.RunLog
R.patterns = R.LootPatterns()
G.LOOT_ITEM_SELF = "You receive loot: %s."; G.LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
G.LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
R.patterns = R.LootPatterns()
local link, cnt = R.ParseLoot("You receive loot: |cff1eff00|Hitem:1:0|h[Boots]|h|r.")
eq(link, "|cff1eff00|Hitem:1:0|h[Boots]|h|r", "loot link"); eq(cnt, 1, "count 1")
link, cnt = R.ParseLoot("You receive loot: |cffffffff|Hitem:2|h[Linen]|h|rx3.")
eq(cnt, 3, "multi count"); eq(link, "|cffffffff|Hitem:2|h[Linen]|h|r", "multi link")
eq(R.ParseLoot("Bob receives loot: [x]."), nil, "others' loot ignored")
eq(R.ParseLoot({ secret = true }), nil, "secret loot line skipped")
eq((R.ParseLoot("You receive item: [Key].")), "[Key]", "pushed item")

M.cdb = {}
local dun = { type = "party", name = "Deadmines", id = 36 }
eq(R.Sync({ type = "none" }, 100), nil, "outside, nothing")
eq(R.Sync(dun, 1000), "started", "enter starts"); eq(R.Cur().name, "Deadmines", "cur name")
eq(R.Sync(dun, 1010), nil, "same zone event no-op")
-- deaths and wipe
local added = R.Poll({ player = false, party1 = false, party2 = false }); eq(added, 0, "no deaths")
added = R.Poll({ player = false, party1 = true, party2 = false }); eq(added, 1, "one death")
added = R.Poll({ player = false, party1 = true, party2 = false }); eq(added, 0, "still dead not recounted")
local _, wiped = R.Poll({ player = true, party1 = true, party2 = true }); eq(wiped, true, "wipe")
eq(R.Cur().deaths, 3, "deaths total (party1 once, player, party2)"); eq(R.Cur().selfDeaths, 1, "self deaths")
_, wiped = R.Poll({ player = true, party1 = true, party2 = true }); eq(wiped, false, "wipe counted once")
R.Poll({ player = false, party1 = true, party2 = true })
_, wiped = R.Poll({ player = true, party1 = true, party2 = true }); eq(wiped, true, "second wipe")
eq(R.Cur().wipes, 2, "2 wipes")
-- xp
R.lastXP, R.lastXPMax = 100, 1000
eq(R.OnXP(250, 1000), 150, "xp gain"); eq(R.OnXP(20, 1200), 750 + 20, "level up xp")
eq(R.Cur().xp, 150 + 770, "xp on run")
R.OnLoot("You receive loot: |cff1eff00|Hitem:1|h[Boots]|h|r."); eq(#R.Cur().loot, 1, "loot recorded")
-- release outside: left, then return within grace = same run
eq(R.Sync({ type = "none" }, 1300), "left", "left"); eq(R.Cur().leftAt, 1300, "leftAt")
R.OnLoot("You receive loot: |cff1eff00|Hitem:9|h[Not in run]|h|r."); eq(#R.Cur().loot, 1, "no loot outside")
eq(R.Sync(dun, 1500), "resumed", "resumed within grace"); eq(R.Cur().wipes, 2, "state kept")
-- leave for good: finalised once grace passed, duration to leave time
eq(R.Sync({ type = "none" }, 1800), "left", "left again")
eq(R.Sync({ type = "none" }, 1800 + R.GRACE + 5), "finished", "finished after grace")
eq(R.Cur(), nil, "no current run"); eq(#R.Runs(), 1, "one run filed")
eq(R.Runs()[1].duration, 800, "duration to the time you left"); eq(R.Runs()[1].wipes, 2, "wipes saved")
eq(#R.Runs()[1].loot, 1, "loot saved")
-- entering another dungeon closes the previous
R.Sync(dun, 5000); eq(R.Sync({ type = "party", name = "Wailing Caverns", id = 43 }, 5100), "started", "new dungeon"); eq(#R.Runs(), 2, "closed previous")
eq(R.Runs()[1].name, "Deadmines", "newest first")
-- display
local lines = R.Lines(); eq(type(lines[1]), "string", "lines")
eq(R.Duration(3725), "1:02:05", "duration h"); eq(R.Duration(65), "1:05", "duration m")
R.Clear(); eq(#R.Runs(), 0, "cleared")
-- option off: no tracking
M.db.runlog = false; M.cdb.runcur = nil
G.IsInInstance = function() return true, "party" end; G.GetInstanceInfo = function() return "Foo", "party", 1, "", 5, 0, false, 99 end
eq(R.Check(), nil, "option off")
M.db.runlog = true
eq(R.Check(), "started", "instance info read"); eq(R.Cur().id, 99, "instance id")

-- ---- Panel layout (Blizzard style) ----
do
    local D = M.Dock
    local ys, total, shown = D.Stack(48, { 22, false, 100, 25 }, 3, 14)
    eq(ys[1], 48, "stack first"); eq(ys[2], nil, "stack hidden skipped"); eq(ys[3], 73, "stack third")
    eq(ys[4], 176, "stack fourth"); eq(total, 215, "stack total"); eq(shown, 3, "stack count")
    local _, t0, n0 = D.Stack(48, { false, false }, 3, 14)
    eq(n0, 0, "stack empty count"); eq(t0, 48 - 3 + 14, "stack empty total")
    state.group = true
    M.preview = false; M.cdb.mode = "tank"
    eq(M.TitleText(), "Group \194\183 Tank", "title with mode")
    M.cdb.mode = nil; M.preview = true
    eq(M.TitleText(), "Group \194\183 test", "title test mode")
    M.preview = false
    eq(M.Metrics.inner + 2 * M.Metrics.inset, 270, "panel width")
end

if fails > 0 then print(fails .. " failures"); os.exit(1) end
print("group_all_test ok")
