-- LuaJIT stub test: GaarGroupForever Instances.lua + Data/Instances.lua.
-- Run: luajit tools/test/group_instances_test.lua   (from the repo root)
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
    LevelDifficultyColor = function(lvl, mine)
        local d = lvl - mine
        if d >= 5 then return 1, 0.1, 0.1 end
        if d >= 3 then return 1, 0.5, 0.25 end
        if d >= -2 then return 1, 0.82, 0 end
        if d >= -8 then return 0.25, 0.75, 0.25 end
        return 0.6, 0.6, 0.6
    end,
}
G.SlashCmdList = {}; G.UIParent = widget(); G.GameTooltip = widget()
G.CreateFrame = function() return widget() end
G.UISpecialFrames = {}
local state = { group = false, level = 20, class = "WARRIOR", iname = "The Deadmines", itype = "party" }
G.IsInGroup = function() return state.group end
G.IsInRaid = function() return false end
G.UnitLevel = function(u) if u == "player" then return state.level end return 25 end
G.UnitExists = function(u) return u == "party1" end
G.UnitClass = function() return state.class, state.class end
G.GetInstanceInfo = function() return state.iname, state.itype end
G.time = function() return 1000 end

local function load(path)
    local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
    local chunk = assert(loadstring(src, path)); setfenv(chunk, G); chunk("GaarGroupForever")
end
local base = "addons/GaarGroupForever/"
load(base .. "GaarGroupForever.lua")
local M = G.GaarGroupForeverAPI._M
M.Dock = { AddButton = noop, AddPanel = noop }
M.UI = { Window = function() return { SetLines = noop, Show = noop } end }
load(base .. "Data/Instances.lua")
load(base .. "Instances.lua")
G.GaarGroupForeverDB = nil; G.GaarGroupForeverCharDB = nil
M.BindSavedVariables()
local N = M.Inst

local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

-- data integrity
local data = N.Data()
eq(#data >= 19, true, "at least 19 instances")
local names, keys = {}, {}
local bosses, items = 0, 0
for _, inst in ipairs(data) do
    eq(type(inst.name) == "string" and inst.name ~= "", true, "name")
    eq(names[inst.name], nil, "duplicate name " .. inst.name); names[inst.name] = true
    eq(keys[inst.key], nil, "duplicate key " .. inst.key); keys[inst.key] = true
    eq(type(inst.lo) == "number" and type(inst.hi) == "number" and inst.lo <= inst.hi, true, inst.name .. " levels")
    eq(type(inst.min) == "number" and inst.min <= inst.lo, true, inst.name .. " min level")
    eq(#inst.bosses >= 1, true, inst.name .. " has bosses")
    for _, b in ipairs(inst.bosses) do
        bosses = bosses + 1
        eq(type(b.name) == "string" and b.name ~= "", true, inst.name .. " boss name")
        if b.wing then eq(N.WingInfo(inst, b.wing) ~= nil, true, inst.name .. " wing " .. b.wing) end
        for _, it in ipairs(N.Loot(b)) do
            items = items + 1
            eq(it.slot ~= "" and it.name ~= "", true, "item " .. it.name)
            eq(it.q == "r" or it.q == "e", true, "quality " .. it.name)
        end
        eq(#N.Loot(b), #(b.loot or {}), "all loot strings parse in " .. b.name)
    end
end
eq(bosses > 150 and items > 300, true, "data size " .. bosses .. "/" .. items)

-- names and aliases
eq(N.FindExact("The Deadmines").key, "vc", "deadmines exact")
eq(N.FindExact("Deadmines").key, "vc", "deadmines alias")
eq(N.FindExact("Zul'Farrak").key, "zf", "zul'farrak apostrophe")
eq(N.FindExact("Sunken Temple").key, "st", "sunken temple alias")
eq(N.FindExact("The Temple of Atal'Hakkar").key, "st", "temple name")
eq(N.FindExact("Lower Blackrock Spire").key, "brs", "lbrs name")
eq(N.FindExact("Stormwind City"), nil, "city is no instance")
local i, w = N.Find("dire maul north"); eq(i and i.key .. w, "dmNorth", "dm north wing")
i, w = N.Find("scarlet lib"); eq(i and i.key .. w, "smLibrary", "prefix of wing alias")
eq(N.Find("brd").key, "brd", "short alias")
eq(N.Find("x"), nil, "too short")
eq(N.Find("nothing like this"), nil, "no match")

-- class armor filter
eq(N.TopArmor("PRIEST", 60), "Cloth", "priest cloth")
eq(N.TopArmor("WARRIOR", 39), "Mail", "warrior mail <40")
eq(N.TopArmor("WARRIOR", 40), "Plate", "warrior plate 40")
eq(N.TopArmor("PALADIN", 40), "Plate", "paladin plate 40")
eq(N.TopArmor("HUNTER", 39), "Leather", "hunter leather <40")
eq(N.TopArmor("HUNTER", 40), "Mail", "hunter mail 40")
eq(N.TopArmor("SHAMAN", 40), "Mail", "shaman mail 40")
eq(N.TopArmor("ROGUE", 60), "Leather", "rogue leather")
local function it(t, stats) return { name = "x", slot = "Chest", type = t, stats = stats or "" } end
eq(N.UsableBy(it("Cloth", "int/spi"), "PRIEST", 30), true, "priest cloth")
eq(N.UsableBy(it("Leather", "agi"), "PRIEST", 30), false, "priest no leather")
eq(N.UsableBy(it("Plate", "str"), "WARRIOR", 39), false, "warrior no plate at 39")
eq(N.UsableBy(it("Plate", "str"), "WARRIOR", 40), true, "warrior plate at 40")
eq(N.UsableBy(it("Mail", "str"), "WARRIOR", 40), false, "warrior no mail at 40")
eq(N.UsableBy(it("Mail", "agi"), "HUNTER", 40), true, "hunter mail 40")
eq(N.UsableBy(it("Leather", "agi"), "HUNTER", 40), false, "hunter no leather 40")
eq(N.UsableBy(it("Shield", "str"), "ROGUE", 50), false, "rogue no shield")
eq(N.UsableBy(it("Shield", "str"), "SHAMAN", 50), true, "shaman shield")
eq(N.UsableBy(it("Staff", "int"), "MAGE", 50), true, "mage staff")
eq(N.UsableBy(it("2H Axe", "str"), "ROGUE", 50), false, "rogue no 2h axe")
eq(N.UsableBy(it("Wand", "int"), "PRIEST", 50), true, "priest wand")
eq(N.UsableBy(it("Libram", ""), "PALADIN", 50), true, "paladin libram")
eq(N.UsableBy(it("Libram", ""), "DRUID", 50), false, "druid no libram")
eq(N.UsableBy(it(nil, "int/spi"), "WARRIOR", 50), false, "warrior no int ring")
eq(N.UsableBy(it(nil, "str/sta"), "WARRIOR", 50), true, "warrior str ring")
eq(N.UsableBy(it(nil, ""), "WARRIOR", 50), true, "plain ring")
eq(N.UsableBy(it(nil, "int"), "NOCLASS", 50), true, "unknown class: all")

-- difficulty colours
local r, g, b = N.DiffColor(17, 26, 20)       -- mid 22: +2 = yellow
eq(r == 1 and g == 0.82, true, "even = yellow")
r, g = N.DiffColor(55, 60, 20); eq(r == 1 and g == 0.1, true, "far above = red")
r, g = N.DiffColor(15, 25, 60); eq(g == 0.6, true, "far below = grey")

-- detection
M.db.instInfo = true
state.iname = "The Deadmines"; N.Update(); eq(N.cur and N.cur.key, "vc", "in deadmines")
state.itype = "raid"; eq(N.Detect(), nil, "raid is not a dungeon")
state.itype = "party"; state.iname = "Stormwind City"; N.Update(); eq(N.cur, nil, "left the instance")
state.iname = "The Deadmines"; N.Update()

-- boss check-off
local vc = N.cur
eq(N.KillCount(vc), 0, "no kills yet")
N.OnEvent(nil, "ENCOUNTER_END", 1, "Edwin VanCleef", 1, 5, 1)
eq(N.IsKilled(vc, N.BossByName(vc, "Edwin VanCleef")), true, "ENCOUNTER_END ticks the boss")
N.OnEvent(nil, "ENCOUNTER_END", 2, "Mr. Smite", 1, 5, 0)
eq(N.IsKilled(vc, N.BossByName(vc, "Mr. Smite")), false, "a wipe ticks nothing")
N.OnEvent(nil, "BOSS_KILL", 3, "Mr. Smite")
eq(N.IsKilled(vc, N.BossByName(vc, "Mr. Smite")), true, "BOSS_KILL ticks the boss")
G.CombatLogGetCurrentEventInfo = function() return 0, "UNIT_DIED", false, nil, nil, nil, nil, nil, "Gilnid" end
N.OnEvent(nil, "COMBAT_LOG_EVENT_UNFILTERED")
eq(N.IsKilled(vc, N.BossByName(vc, "Gilnid")), true, "UNIT_DIED ticks by name")
G.CombatLogGetCurrentEventInfo = function() return 0, "UNIT_DIED", false, nil, nil, nil, nil, nil, { secret = true } end
N.OnEvent(nil, "COMBAT_LOG_EVENT_UNFILTERED")
eq(N.KillCount(vc), 3, "secret name ignored")
G.CombatLogGetCurrentEventInfo = function() return 0, "UNIT_DIED", false, nil, nil, nil, nil, nil, "Defias Pillager" end
N.OnEvent(nil, "COMBAT_LOG_EVENT_UNFILTERED")
eq(N.KillCount(vc), 3, "other mobs ignored")
N.SetKilled(vc, N.BossByName(vc, "Gilnid"), false)
eq(N.KillCount(vc), 2, "manual untick")
state.iname = "Wailing Caverns"; N.Update(); eq(N.Run(N.cur).key, "wc", "new instance resets the run"); eq(N.KillCount(N.cur), 0, "reset kills")
state.iname = "The Deadmines"; N.Update()

-- rows and text
state.group = true; state.class = "PRIEST"; state.level = 20
local ctx = N.Ctx(); eq(#ctx.party, 1, "party level list"); eq(ctx.party[1], 25, "party level")
local rows = N.Rows(vc, ctx)
eq(rows[1].kind, "header", "header row"); eq(rows[2].kind, "party", "party row")
local nb = 0; for _, row in ipairs(rows) do if row.kind == "boss" then nb = nb + 1 end end
eq(nb, #vc.bosses, "a row per boss")
ctx.collapsed = true; eq(#N.Rows(vc, ctx), 1, "collapsed = header only")
ctx.collapsed = false; ctx.lootOpen = true
local with = #N.Rows(vc, ctx); ctx.lootOpen = false
eq(with >= #N.Rows(vc, ctx), true, "loot rows only when open")
local lines = N.TextLines(vc, ctx)
eq(#lines > #vc.bosses, true, "text window lines")
for _, l in ipairs(N.LootForYou(vc, "PRIEST", 20)) do eq(l.type == nil or l.type == "Cloth" or l.type == "Dagger" or l.type == "1H Mace" or l.type == "Staff" or l.type == "Wand", true, "priest loot type " .. tostring(l.type)) end
local tip = N.BossTip(vc.bosses[1], ctx); eq(type(tip[1][1]), "string", "boss tooltip")

-- option, menu, slash
eq(M.db.instInfo, true, "default on")
local found = false
for _, e in ipairs(M.MenuEntries()) do if e.text == "Show instance info" then found = true end end
eq(found, true, "menu entry")
eq(type(M.Slash.info), "function", "slash info")
M.Slash.info("list"); M.Slash.info("deadmines"); M.Slash.info("nonsense"); M.Slash.info("off")
eq(M.db.instInfo, false, "/ggf info off"); M.Slash.info("on"); eq(M.db.instInfo, true, "/ggf info on")

if fails == 0 then print("group instances test: ok (" .. #data .. " instances, " .. bosses .. " bosses, " .. items .. " items)") else print(fails .. " FAILED"); os.exit(1) end
