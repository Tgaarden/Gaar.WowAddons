-- LuaJIT stub test: GaarGpsForever 1.5 graveyards and flight paths on the map (Places.lua + Data/).
-- Data sanity, faction filter, learned / unlearned, name matching, toggles, continent placement.
-- Run: luajit tools/test/gps_places_test.lua   (from the repo root)
local dir = "addons/GaarGpsForever/"
local ns = {}
local G = setmetatable({}, { __index = _G }); G._G = G
local function load(file)
    local f = assert(loadfile(dir .. file)); setfenv(f, G); return f("GaarGpsForever", ns)
end
local function Num(v) return type(v) == "number" and v == v and v or nil end
local faction, played = "Alliance", "Dru Tics"
G.GaarForever = {
    IsSecret = function() return false end, Num = Num,
    Str = function(v) return type(v) == "string" and v ~= "" and v or nil end,
    Bool = function(v) if v == nil then return nil end return v and true or false end,
    Call = function(fn, ...) if type(fn) ~= "function" then return end
        local r = { pcall(fn, ...) }; if not r[1] then return end; return unpack(r, 2, table.maxn(r)) end,
    Method = function(o, name, ...) if type(o) ~= "table" or type(o[name]) ~= "function" then return end
        return o[name](o, ...) end,
    API = function(n, name) local t = G[n]; return type(t) == "table" and type(t[name]) == "function" and t[name] or nil end,
    OnOff = function(v) return v and "on" or "off" end,
    PlayerFullName = function() return played end,
}
G.UnitFactionGroup = function() return faction end
G.GetRealmName = function() return "Realm" end
G.CreateFrame = function() return setmetatable({}, { __index = function(t, k)
    local f = function() return t end; rawset(t, k, f); return f end }) end
local printed = {}
local nodes = {}
G.C_TaxiMap = { GetAllTaxiNodes = function(id) return id == 1415 and nodes or {} end }
G.C_Map = { GetMapInfo = function(id) return { mapType = (id == 1415) and 2 or 3 } end,
    GetBestMapForUnit = function() return 1429 end,
    GetMapPosFromWorldPos = function(c, v, m) return m, { x = v.x / 1000, y = v.y / 1000 } end }
setfenv(1, G)

local fails = 0
local function check(cond, msg) if not cond then fails = fails + 1; print("FAIL " .. msg) end end

load("Data/FlightPaths.lua"); load("Data/Graveyards.lua"); load("Places.lua")
-- the tests use _G pcall etc. through G
local fp, gy = ns.flightPaths, ns.graveyards
check(#fp > 40, "flight path count " .. #fp)
local counts = { Alliance = 0, Horde = 0, Neutral = 0 }
local seen = {}
for _, e in ipairs(fp) do
    check(type(e.name) == "string" and e.name ~= "" and type(e.zone) == "string", "name/zone " .. tostring(e.name))
    check(type(e.map) == "number" and e.map >= 1411 and e.map <= 1458, "map " .. e.name)
    check(e.x > 0 and e.x < 1 and e.y > 0 and e.y < 1, "xy range " .. e.name)
    check(counts[e.faction] ~= nil, "faction " .. e.name)
    counts[e.faction] = (counts[e.faction] or 0) + 1
    local k = e.name .. e.faction
    check(not seen[k], "duplicate " .. k); seen[k] = true
end
check(counts.Alliance > 15 and counts.Horde > 15 and counts.Neutral >= 5, "per-faction counts")
local g = 0
for map, list in pairs(gy) do
    check(type(map) == "number" and map >= 1411 and map <= 1452, "graveyard map " .. tostring(map))
    for _, p in ipairs(list) do
        g = g + 1
        check(p[1] > 0 and p[1] < 1 and p[2] > 0 and p[2] < 1, "graveyard xy " .. map)
    end
end
check(g > 60, "graveyard count " .. g)

-- binding
local db = {}
local core = { Print = function(m) printed[#printed + 1] = m end, Safe = function(_, f, ...) return f(...) end,
    WorldPos = function(m, x, y) return 1, x * 1000, y * 1000 end, Vec = function(x, y) return { x = x, y = y } end,
    XY = function(v) return v and v.x, v and v.y end, MapName = function() return "Zone" end,
    Map = function() end, Canvas = function() end, DisplayedMapID = function() end }
local places = ns.places
check(places, "places module exists")
places.Bind(db, core)
check(db.places_flights == true and db.places_graves == true, "on by default")

-- faction filter
local P = places.pure
check(P.FactionShows("Neutral", "Alliance") and P.FactionShows("Alliance", "Alliance"), "alliance sees A+N")
check(not P.FactionShows("Horde", "Alliance") and not P.FactionShows("Alliance", "Horde"), "no opposite faction")
check(not P.FactionShows("Alliance", nil) and P.FactionShows("Neutral", nil), "neutral player sees neutral only")
for _, f in ipairs({ "Alliance", "Horde" }) do
    local list = P.Visible(1429, f, true, true)
    for _, d in ipairs(list) do check(d.kind ~= "flight" or d.e.faction ~= (f == "Alliance" and "Horde" or "Alliance"), "visible " .. f) end
end
-- Elwynn: graveyards, no flight path of its own
local el = P.Visible(1429, "Alliance", true, true)
check(#el == #gy[1429] , "elwynn shows its graveyards only")
-- Stormwind City (1453): Alliance flight path, not for Horde
local sw = P.Visible(1453, "Alliance", true, false)
check(#sw == 1 and sw[1].e.name == "Stormwind City", "stormwind flight path")
check(#P.Visible(1453, "Horde", true, false) == 0, "horde does not see stormwind")
-- toggles
check(#P.Visible(1453, "Alliance", false, true) == 0, "flights off")
check(#P.Visible(1429, "Alliance", true, false) == 0, "graves off")
-- continent placement (stub conversion): flight paths of all zones, no graveyards
local cont = P.Visible(1415, "Alliance", true, true)
local nf = 0
for _, d in ipairs(cont) do check(d.kind == "flight", "no graveyards on a continent"); nf = nf + 1 end
check(nf >= 20, "continent shows flight paths " .. nf)

-- learned / unlearned
check(not P.IsLearned(sw[1].e), "unlearned before any scan")
check(sw[1].learned == false, "grey before any scan")
local new = P.Record({ "Stormwind, Elwynn", "Nowhere, Nowhere" })
check(new == 1, "one learned, got " .. new)
sw = P.Visible(1453, "Alliance", true, false)
check(sw[1].learned == true, "learned after scan")
check(db.placesLearned["Dru Tics-Realm"], "saved per character")
played = "Other Char"
check(not P.IsLearned(sw[1].e), "other character has not learned it")
played = "Dru Tics"
-- name matching
check(P.MatchName("Theramore, Dustwallow Marsh"), "prefix match Theramore")
check(P.MatchName("Light's Hope Chapel, Eastern Plaguelands"), "Light's Hope")
check(P.MatchName("Gadgetzan, Tanaris")[1].faction == "Neutral", "Gadgetzan neutral")
check(P.MatchName("") == nil and P.MatchName(nil) == nil, "bad names")
-- a TAXIMAP_OPENED scan through C_TaxiMap
nodes = { { name = "Ironforge, Dun Morogh" }, { name = "Menethil Harbor, Wetlands" } }
P.Scan()
check(P.IsLearned(P.MatchName("Ironforge")[1]) and P.IsLearned(P.MatchName("Menethil Harbor")[1]), "scan via C_TaxiMap learns nodes")
check(not P.IsLearned(P.MatchName("Auberdine")[1]), "unlisted node stays unlearned")
places.Start()
-- toggles through slash
check(places.Slash("flights", "off") and db.places_flights == false, "slash flights off")
check(places.Slash("graves", "off") and db.places_graves == false, "slash graves off")
check(places.Slash("flights", "on") and db.places_flights == true, "slash flights on")
check(places.Slash("graves", "") and db.places_graves == true, "slash graves toggles")
check(places.Slash("gather", "") == false, "other commands are not ours")
check(#places.MenuEntries() == 2, "two menu entries")

if fails > 0 then print(fails .. " failures"); os.exit(1) end
print("gps_places_test: ok (" .. #fp .. " flight paths, " .. g .. " graveyards)")
