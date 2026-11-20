-- LuaJIT stub test: GaarGpsForever 1.5 graveyards and flight paths on the map (Places.lua + Data/).
-- Data sanity, the checklist of flight paths (name, faction, map), The Barrens complete, faction
-- filter, learned / unlearned (green / grey), name and node matching, the client API merge (no
-- doubles), toggles, continent placement.
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
local rtNodes, rtGraves = {}, {}
G.C_TaxiMap = { GetAllTaxiNodes = function(id) return id == 1415 and nodes or {} end,
    GetTaxiNodesForMap = function(id) return rtNodes[id] or {} end }
G.C_DeathInfo = { GetGraveyardsForMap = function(id) return rtGraves[id] or {} end }
G.Enum = { FlightPathFaction = { Neutral = 0, Horde = 1, Alliance = 2 }, UIMapType = { Continent = 2 } }
G.C_Map = { GetMapInfo = function(id) return { mapType = (id == 1415 or id == 1414) and 2 or 3 } end,
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
    check(type(e.map) == "number" and (e.map >= 1411 and e.map <= 1458 or e.map == 2482 or e.map == 2548), "map " .. e.name)
    check(e.x > 0 and e.x < 1 and e.y > 0 and e.y < 1, "xy range " .. e.name)
    check(counts[e.faction] ~= nil, "faction " .. e.name)
    counts[e.faction] = (counts[e.faction] or 0) + 1
    local k = e.name .. e.faction .. e.map
    check(not seen[k], "duplicate " .. k); seen[k] = true
end
check(counts.Alliance >= 30 and counts.Horde >= 30 and counts.Neutral >= 2, "per-faction counts")
local g = 0
for map, list in pairs(gy) do
    check(type(map) == "number" and map >= 1411 and map <= 1458, "graveyard map " .. tostring(map))
    for _, p in ipairs(list) do
        g = g + 1
        check(p[1] > 0 and p[1] < 1 and p[2] > 0 and p[2] < 1, "graveyard xy " .. map)
    end
end
check(g >= 90, "graveyard count " .. g)

-- the checklist: every vanilla flight path by name, faction and map
local function has(name, map, fac)
    for _, e in ipairs(fp) do
        if e.name == name and (e.map == map or (e.also and e.also[1] == map)) and e.faction == fac then return e end
    end
end
local LIST = {
    { "Crossroads", 1413, "Horde" }, { "Camp Taurajo", 1413, "Horde" }, { "Ratchet", 1413, "Neutral" },
    { "Rut'theran Village", 1438, "Alliance" }, { "Thunder Bluff", 1456, "Horde" }, { "Thunder Bluff", 1412, "Horde" },
    { "Orgrimmar", 1454, "Horde" }, { "Orgrimmar", 1411, "Horde" }, { "Undercity", 1458, "Horde" },
    { "Stormwind", 1453, "Alliance" }, { "Stormwind", 1429, "Alliance" }, { "Ironforge", 1455, "Alliance" },
    { "Moonglade", 1450, "Alliance" }, { "Moonglade", 1450, "Horde" }, { "Feathermoon", 1444, "Alliance" },
    { "Valormok", 1447, "Horde" }, { "Splintertree Post", 1440, "Horde" }, { "Zoram'gar Outpost", 1440, "Horde" },
    { "Talrendis Point", 1447, "Alliance" }, { "Astranaar", 1440, "Alliance" }, { "Auberdine", 1439, "Alliance" },
    { "Stonetalon Peak", 1442, "Alliance" }, { "Sun Rock Retreat", 1442, "Horde" }, { "Nijel's Point", 1443, "Alliance" },
    { "Shadowprey Village", 1443, "Horde" }, { "Freewind Post", 1441, "Horde" }, { "Theramore", 1445, "Alliance" },
    { "Brackenwall Village", 1445, "Horde" }, { "Thalanaar", 1444, "Alliance" }, { "Camp Mojache", 1444, "Horde" },
    { "Revantusk Village", 1425, "Horde" }, { "Aerie Peak", 1425, "Alliance" }, { "Chillwind Camp", 1422, "Alliance" },
    { "Hammerfall", 1417, "Horde" }, { "Refuge Pointe", 1417, "Alliance" }, { "Thorium Point", 1427, "Alliance" },
    { "Thorium Point", 1427, "Horde" }, { "Morgan's Vigil", 1428, "Alliance" }, { "Flame Crest", 1428, "Horde" },
    { "Kargath", 1418, "Horde" }, { "Thelsamar", 1432, "Alliance" }, { "Menethil Harbor", 1437, "Alliance" },
    { "Southshore", 1424, "Alliance" }, { "Tarren Mill", 1424, "Horde" }, { "The Sepulcher", 1421, "Horde" },
    { "Lakeshire", 1433, "Alliance" }, { "Sentinel Hill", 1436, "Alliance" }, { "Darkshire", 1431, "Alliance" },
    { "Stonard", 1435, "Horde" }, { "Nethergarde Keep", 1419, "Alliance" }, { "Grom'gol", 1434, "Horde" },
    { "Booty Bay", 1434, "Alliance" }, { "Booty Bay", 1434, "Horde" }, { "Light's Hope Chapel", 1423, "Alliance" },
    { "Light's Hope Chapel", 1423, "Horde" }, { "Everlook", 1452, "Alliance" }, { "Everlook", 1452, "Horde" },
    { "Gadgetzan", 1446, "Alliance" }, { "Gadgetzan", 1446, "Horde" }, { "Cenarion Hold", 1451, "Alliance" },
    { "Cenarion Hold", 1451, "Horde" }, { "Marshal's Refuge", 1449, "Neutral" }, { "Bloodvenom Post", 1448, "Horde" },
    { "Talonbranch Glade", 1448, "Alliance" },
}
for _, c in ipairs(LIST) do check(has(c[1], c[2], c[3]), "checklist " .. c[1] .. " " .. c[2] .. " " .. c[3]) end
-- positions at the flight master (the client's node), on WoW Forever's own map bounds
local cr = has("Crossroads", 1413, "Horde")
check(math.abs(cr.x - 0.515) < 0.01 and math.abs(cr.y - 0.304) < 0.01, "Crossroads at 51.5, 30.4")
local lh = has("Light's Hope Chapel", 1423, "Alliance")
check(math.abs(lh.x - 0.717) < 0.01 and math.abs(lh.y - 0.496) < 0.01, "Light's Hope on the WoW Forever EPL map")
-- The Barrens: all three flight paths and graveyards (Crossroads, Camp Taurajo, Ratchet)
local bfp = 0
for _, e in ipairs(fp) do if e.map == 1413 then bfp = bfp + 1 end end
check(bfp >= 3, "Barrens flight paths " .. bfp)
check(#gy[1413] >= 3, "Barrens graveyards " .. #gy[1413])
local function graveNear(map, x, y)
    for _, p in ipairs(gy[map] or {}) do if math.abs(p[1] - x) < 0.02 and math.abs(p[2] - y) < 0.02 then return p end end
end
check(graveNear(1413, 0.508, 0.326), "Crossroads graveyard")
check(graveNear(1413, 0.454, 0.611), "Camp Taurajo graveyard")
check(graveNear(1413, 0.602, 0.399), "Ratchet graveyard")
check(graveNear(1456, 0.567, 0.19) and graveNear(1412, 0.415, 0.304), "Thunder Bluff graveyard on city and zone map")
-- WoW Forever zones
check(has("Summit of Eternity", 2482, "Neutral") and has("Rog'mar", 2548, "Horde") and has("Farholde Keep", 2548, "Alliance"),
    "WoW Forever flight paths (Hyjal, Riverglades)")

-- binding
local db = {}
local core = { Print = function(m) printed[#printed + 1] = m end, Safe = function(_, f, ...) return f(...) end,
    WorldPos = function(m, x, y) return 1, x * 1000, y * 1000 end, Vec = function(x, y) return { x = x, y = y } end,
    XY = function(v) return v and v.x, v and v.y end, MapName = function() return "Zone" end,
    Map = function() end, Canvas = function() end, DisplayedMapID = function() end,
    PlayerMapID = function() return 1413 end }
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
-- Elwynn: its graveyards and Stormwind's flight path (placed on the zone map too)
local el = P.Visible(1429, "Alliance", true, true)
check(#el == #gy[1429] + 1, "elwynn shows its graveyards and the Stormwind flight path")
check(#P.Visible(1429, "Horde", true, false) == 0, "horde sees no flight path in Elwynn")
-- Stormwind City (1453): Alliance flight path, not for Horde
local sw = P.Visible(1453, "Alliance", true, false)
check(#sw == 1 and sw[1].e.name == "Stormwind", "stormwind flight path")
check(#P.Visible(1453, "Horde", true, false) == 0, "horde does not see stormwind")
-- toggles
check(#P.Visible(1453, "Alliance", false, true) == 0, "flights off")
for _, d in ipairs(P.Visible(1429, "Alliance", true, false)) do check(d.kind == "flight", "graves off") end
-- continent placement (stub conversion): flight paths of all zones, no graveyards
local cont = P.Visible(1415, "Alliance", true, true)
local nf = 0
for _, d in ipairs(cont) do check(d.kind == "flight", "no graveyards on a continent"); nf = nf + 1 end
check(nf >= 20, "continent shows flight paths " .. nf)

-- learned / unlearned
check(not P.IsLearned(sw[1].e), "unlearned before any scan")
check(sw[1].learned == false, "grey before any scan")
local new = P.Record({ "Stormwind, Elwynn", "Nowhere, Nowhere" })
-- green when learned, grey when not
local d0, r0, g0, b0, a0 = P.PinStyle({ kind = "flight", learned = false })
local d1, r1, g1, b1, a1 = P.PinStyle({ kind = "flight", learned = true })
check(d0 and r0 == 1 and g0 == 1 and b0 == 1 and a0 < 1, "unlearned grey and faded")
check(g1 == 1 and r1 < 0.5 and b1 < 0.5 and a1 == 1, "learned green")
local tex = {}
local fakePin = { icon = setmetatable({}, { __index = function(t, k) return function(_, ...) tex[k] = { ... } end end }) }
P.Skin(fakePin, { kind = "flight", learned = true })
check(tex.SetVertexColor and tex.SetVertexColor[2] == 1 and tex.SetVertexColor[1] < 0.5, "skin tints a learned flight path green")
P.Skin(fakePin, { kind = "flight", learned = false })
check(tex.SetVertexColor[1] == 1 and tex.SetDesaturated[1] == true, "skin greys an unlearned one")
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
check(#P.MatchName("Gadgetzan, Tanaris") == 2, "Gadgetzan: an Alliance and a Horde flight master")
check(P.MatchName("") == nil and P.MatchName(nil) == nil, "bad names")
-- a TAXIMAP_OPENED scan through C_TaxiMap
nodes = { { name = "Ironforge, Dun Morogh", state = 0 }, { name = "Menethil Harbor, Wetlands", state = 1 },
    { name = "Everlook, Winterspring", nodeID = 52, state = 2 }, { name = "Auberdine, Darkshore" } }
P.Scan()
check(P.IsLearned(P.MatchName("Ironforge")[1]) and P.IsLearned(P.MatchName("Menethil Harbor")[1]), "scan: Current/Reachable learned")
check(P.LearnedSource(P.MatchName("Ironforge")[1]) == "taxi", "source tag taxi")
check(not P.IsLearned(has("Everlook", 1452, "Alliance")), "scan: Unreachable node not learned")
check(not P.IsLearned(P.MatchName("Auberdine")[1]), "scan: node without a state not learned")
check(P.KnownState(0) and P.KnownState(1) and not P.KnownState(2) and not P.KnownState(nil), "known states")
-- the old API: only CURRENT / REACHABLE
local savedTaxi = G.C_TaxiMap.GetAllTaxiNodes
G.C_TaxiMap.GetAllTaxiNodes = nil
local legacy = { { "Astranaar, Ashenvale", "DISTANT" }, { "Thelsamar, Loch Modan", "REACHABLE" }, { "Darkshire, Duskwood", "NONE" } }
G.NumTaxiNodes = function() return #legacy end
G.TaxiNodeName = function(i) return legacy[i][1] end
G.TaxiNodeGetType = function(i) return legacy[i][2] end
P.Scan()
check(P.IsLearned(has("Thelsamar", 1432, "Alliance")), "legacy REACHABLE learned")
check(not P.IsLearned(has("Astranaar", 1440, "Alliance")) and not P.IsLearned(has("Darkshire", 1431, "Alliance")),
    "legacy DISTANT / NONE not learned")
G.C_TaxiMap.GetAllTaxiNodes, G.NumTaxiNodes = savedTaxi, nil
-- a name marks only the player's faction's row: Alliance Everlook, not the Horde one
P.Record({ "Everlook, Winterspring" })
check(P.IsLearned(has("Everlook", 1452, "Alliance")) and not P.IsLearned(has("Everlook", 1452, "Horde")),
    "same-name Alliance/Horde rows learned apart")
-- a scan matches by node ID before the name (the client node "Moonglade" of the Horde, node 69)
nodes = { { name = "Something Else", nodeID = 69, state = 1 } }
P.Scan()
check(P.IsLearned(has("Moonglade", 1450, "Horde")) and not P.IsLearned(has("Moonglade", 1450, "Alliance")),
    "scan by node ID marks exactly that row")
-- the learned lists of 1.5.0 / 1.5.1 are wiped once
local keep = db.placesLearned
db.placesLearned = { ["Dru Tics-Realm"] = { ["crossroads:1413"] = true, ["everlook:1452"] = true } }
check(not P.IsLearned(has("Crossroads", 1413, "Horde")) and not P.IsLearned(has("Everlook", 1452, "Alliance")),
    "old learned entries wiped")
check(db.placesLearned._v == 2 and next(db.placesLearned["Dru Tics-Realm"]) == nil, "wiped once, versioned")
db.placesLearned["Dru Tics-Realm"]["everlook:1452:Alliance"] = true
check(not P.IsLearned(has("Everlook", 1452, "Alliance")), "a learned entry without a source does not count")
db.placesLearned = keep

-- the client API merged into the table on The Barrens, no doubles
P.ClearCache()
faction = "Horde"
local before = #P.Visible(1413, "Horde", true, true)
rtNodes[1413] = {
    { nodeID = 25, name = "Crossroads, The Barrens", position = { x = 0.516, y = 0.303 }, faction = 1 },
    { nodeID = 77, name = "Camp Taurajo, The Barrens", position = { x = 0.446, y = 0.590 }, faction = 1, isUndiscovered = false },
}
played = "Nil Check"
P.ClearCache()
for _, d in ipairs(P.Visible(1413, "Horde", true, false)) do
    check(not d.learned, "untrusted API (no isUndiscovered == true seen): " .. d.e.name .. " not learned")
end
check(P.Undiscovered.seenNil == 1 and P.Undiscovered.seenTrue == 0, "isUndiscovered nil counted, not trusted")
rtNodes[1413] = {
    { nodeID = 25, name = "Crossroads, The Barrens", position = { x = 0.516, y = 0.303 }, faction = 1, isUndiscovered = false },
    { nodeID = 80, name = "Ratchet, The Barrens", position = { x = 0.631, y = 0.371 }, faction = 0, isUndiscovered = true },
    { name = "Camp Taurajo", position = { x = 0.446, y = 0.590 }, faction = 1 },
    { nodeID = 9001, name = "New Camp, The Barrens", position = { x = 0.30, y = 0.30 }, faction = 1, isUndiscovered = false },
    { nodeID = 9002, name = "Far Hold, The Barrens", position = { x = 0.70, y = 0.70 }, faction = 2 },
    { nodeID = 9003, name = "zzOLDPowderfuse Port (Neutral)", position = { x = 0.25, y = 0.25 }, faction = 0, isUndiscovered = false },
}
rtGraves[1413] = { { position = { x = 0.509, y = 0.327 }, name = "Crossroads" }, { position = { x = 0.5, y = 0.9 }, name = "South" } }
played = "Taur En"
P.ClearCache()
local b = P.Visible(1413, "Horde", true, true)
local nf2, ng2, names = 0, 0, {}
for _, d in ipairs(b) do
    if d.kind == "flight" then nf2 = nf2 + 1; names[d.e.name] = d else ng2 = ng2 + 1 end
end
check(nf2 == 4, "barrens merged: 3 table + 1 new Horde node, got " .. nf2)
check(ng2 == #gy[1413] + 1, "barrens graveyards merged: one added, one deduped, got " .. ng2)
check(names["New Camp"] and names["New Camp"].learned, "client-only node, discovered: green")
check(names["Crossroads"] and names["Crossroads"].learned, "client says discovered (API trusted): learned")
check(P.LearnedSource(names["Crossroads"].e) == "api", "source tag api")
check(not names["Camp Taurajo"].learned, "client node with isUndiscovered nil: not learned")
check(names["Ratchet"] and not names["Ratchet"].learned, "client says undiscovered: grey")
check(not names["Far Hold"], "client-only Alliance node hidden from the Horde")
check(not names["zzOLDPowderfuse Port"], "client zzOLD node (deprecated) is neither drawn nor listed")
check(P.IsDeadName("zzOLDPowderfuse Port (Neutral)") and P.IsDeadName("ZZtest") and P.IsDeadName("[DNT] Old Hold")
    and P.IsDeadName("Foo DEPRECATED") and P.IsDeadName("Bar UNUSED") and P.IsDeadName("TEST Hub") and P.IsDeadName(nil),
    "dead client names filtered")
check(not P.IsDeadName("Crossroads, The Barrens") and not P.IsDeadName("Testament Rise"), "real names kept")
local pc = P.Positions(1413)
check(pc.n.rtFlights == 5 and pc.n.stFlights == 3 and pc.n.flights == 5 and pc.n.rtGraves == 2 and pc.n.gravesAdded == 1,
    "status counts per map")
local merged = P.MergeFlights({ { e = has("Booty Bay", 1434, "Alliance"), x = 0.275, y = 0.777 },
    { e = has("Booty Bay", 1434, "Horde"), x = 0.268, y = 0.770 } },
    { { name = "Booty Bay", x = 0.269, y = 0.771, faction = "Horde" } }, 1434, "Stranglethorn Vale")
check(#merged == 2, "same-name nodes of two factions: matched by faction, not added")
local m2 = P.MergeFlights({ { e = has("Everlook", 1452, "Alliance"), x = 0.623, y = 0.366 } },
    { { name = "Everlook, Winterspring", x = 0.40, y = 0.40, faction = "Horde", known = true } }, 1452, "Winterspring")
check(#m2 == 1, "a client node with a table row's name never becomes a second pin")
local mg = P.MergeGraves({ { x = 0.5, y = 0.5 } }, { { x = 0.51, y = 0.5, name = "A" }, { x = 0.51, y = 0.505 } })
check(#mg == 1 and mg[1].name == "A", "graveyard dedupe by distance, client name kept")
rtNodes[1413], rtGraves[1413] = nil, nil
G.C_TaxiMap.GetTaxiNodesForMap, G.C_DeathInfo = nil, nil
P.ClearCache()
check(#P.Visible(1413, "Horde", true, true) == before, "without the client API the table alone")
local st = places.StatusLines()
check(#st >= 3 and st[2]:find("(1413)", 1, true) and st[3]:find("Crossroads", 1, true), "status line for this map")
faction, played = "Alliance", "Dru Tics"

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
