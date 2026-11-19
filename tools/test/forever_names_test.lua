-- LuaJIT stub test: GaarForever 3.2.27 name helpers (characters with surnames).
-- Run: luajit tools/test/forever_names_test.lua   (from the repo root)
local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
local units = { player = { "Dru", "Realm", "Dru Tics" }, target = { "Bob Smith", nil, "Bob Smith" },
    party1 = { "Dru", nil, "Dru Other" } }
_G.issecretvalue = function(v) return v == SECRET end
_G.UnitExists = function(u) return units[u] ~= nil end
_G.UnitGUID = function(u) return units[u] and ("G-" .. u) or nil end
_G.UnitName = function(u) local x = units[u]; if x then return x[1], x[2] end end
_G.UnitFullName = _G.UnitName
_G.GetUnitName = function(u, realm) local x = units[u]; if x then return x[3] end end
_G.GaarForever = nil
dofile("addons/GaarForever/Lib.lua")
local L = _G.GaarForever
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

eq(L.PlayerFullName(), "Dru Tics", "full name beats UnitName's first name")
eq(L.NamesMatch("Dru Tics", "Dru"), true, "surname vs first name")
eq(L.NamesMatch("Dru", "Dru Tics-Realm"), true, "first name vs surname with realm")
eq(L.NamesMatch("Bob-Realm", "Bob"), true, "realm suffix")
eq(L.NamesMatch("bob", "Bob"), true, "case")
eq(L.NamesMatch("Dru", "Druid"), false, "prefix without space is not a match")
eq(L.NamesMatch("Dru Tics", "Dru Other"), false, "different surname")
eq(L.NamesMatch(SECRET, "Dru"), false, "secret skipped")
eq(L.NamesMatch("Dru", nil), false, "nil")
eq(L.UnitByName("Bob Smith"), "target", "exact")
eq(L.UnitByName("Dru Tics"), "player", "exact full")
eq(L.UnitByName("Dru Zed"), "player", "prefix tie: you win")
eq(L.UnitByName("Nobody"), nil, "unknown")
eq(L.UnitByName(SECRET), nil, "secret name")
units.player = { SECRET, nil, SECRET }
eq(L.PlayerFullName(), nil, "secret player name skipped")
if fails == 0 then print("forever_names_test: ok") else os.exit(1) end
