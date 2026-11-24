-- LuaJIT stub test: GaarGpsForever 1.6 flight connections (Routes.lua + Data/FlightRoutes.lua).
-- Data integrity (every edge between existing node keys, no self-loops, no duplicates, no edge
-- between the two factions), faction filtering, merge (table + learned - removed), the tooltip
-- list, learning from a taxi scan (hops, removal), the world-position direction, the option.
-- Run: luajit tools/test/gps_routes_test.lua   (from the repo root)
local dir = "addons/GaarGpsForever/"
local ns = {}
local G = setmetatable({}, { __index = _G }); G._G = G
local function load(file)
    local f = assert(loadfile(dir .. file)); setfenv(f, G); return f("GaarGpsForever", ns)
end
local function Num(v) return type(v) == "number" and v == v and v or nil end
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
    PlayerFullName = function() return "Dru Tics" end,
}
local faction = "Alliance"
G.UnitFactionGroup = function() return faction end
G.GetRealmName = function() return "Realm" end
G.CreateFrame = function() return setmetatable({}, { __index = function(t, k)
    local f = function() return t end; rawset(t, k, f); return f end }) end
local printed = {}
local core = { Print = function(m) printed[#printed + 1] = m end, Safe = function(_, fn, ...) return fn(...) end,
    MapName = function() return "Map" end, DisplayedMapID = function() return 1429 end,
    WorldPos = function() return nil end }
setfenv(1, G)

local fails = 0
local function check(cond, msg) if not cond then fails = fails + 1; print("FAIL " .. msg) end end

load("Data/FlightPaths.lua"); load("Data/FlightRoutes.lua"); load("Places.lua"); load("Routes.lua")
local H = ns.routes.pure
local byNode = {}
for _, e in ipairs(ns.flightPaths) do byNode[e.node] = e end

-- data integrity
local seen, n = {}, 0
for i, ed in ipairs(ns.flightRoutes) do
    n = n + 1
    local a, b = ed[1], ed[2]
    check(byNode[a] and byNode[b], "edge " .. i .. " references a missing node " .. tostring(a) .. "-" .. tostring(b))
    check(a ~= b, "self loop " .. tostring(a))
    check(a < b, "edge not ordered " .. a .. "-" .. b)
    local k = a .. "-" .. b
    check(not seen[k], "duplicate edge " .. k); seen[k] = true
    if byNode[a] and byNode[b] then
        local fa, fb = byNode[a].faction, byNode[b].faction
        check(fa == "Neutral" or fb == "Neutral" or fa == fb, "edge between the factions " .. k)
    end
end
check(n == 143, "edge count " .. n)
check(#H.StaticEdges("Alliance") == 70, "alliance edges " .. #H.StaticEdges("Alliance"))
check(#H.StaticEdges("Horde") == 74, "horde edges " .. #H.StaticEdges("Horde"))
for _, ed in ipairs(H.StaticEdges("Alliance")) do
    check(byNode[ed[1]].faction ~= "Horde" and byNode[ed[2]].faction ~= "Horde", "horde node in alliance graph")
end
local aG, hG = H.Graph("Alliance"), H.Graph("Horde")
check(aG[80] and aG[80][32] and not aG[80][25], "Ratchet: Theramore for the Alliance, not Crossroads")
check(hG[80] and hG[80][25] and not hG[80][32], "Ratchet: Crossroads for the Horde")
check(aG[79] and aG[79][39] and aG[79][73] and hG[79][40] and hG[79][72], "Marshal's Refuge joins both")
check(aG[2][4] and aG[4][2], "undirected Stormwind - Sentinel Hill")
check(not hG[2], "no Stormwind in the Horde graph")

-- merge: table + learned - removed
local store = { learned = { ["2-3276"] = true, ["2-999"] = true, ["bad"] = true }, removed = { ["2-4"] = true } }
local g, keys = H.Graph("Alliance", store)
check(g[2][3276], "learned edge added (both nodes exist)")
check(not g[2][999], "learned edge to unknown node ignored")
check(not (g[2][4] or g[4] and g[4][2]), "removed edge gone")
check(g[2][5], "other edges stay")
local c = H.Counts("Alliance", store)
check(c.static == 70 and c.learned == 3 and c.extra == 3 and c.removed == 1 and c.merged == 70, "counts " ..
    c.static .. "/" .. c.learned .. "/" .. c.extra .. "/" .. c.removed .. "/" .. c.merged)
local horde = H.Graph("Horde", { learned = { ["2-5"] = true } })
check(not horde[2], "an Alliance edge in the Horde store is ignored")

-- tooltip list: sorted by name, learned flag, count
local list, nl = H.Destinations(2, "Alliance", nil, function(e) return e.name == "Ironforge" or e.name == "Booty Bay" end)
local names = {}
for _, it in ipairs(list) do names[#names + 1] = it.name end
check(table.concat(names, ",") == "Booty Bay,Darkshire,Ironforge,Lakeshire,Morgan's Vigil,Nethergarde Keep,Sentinel Hill",
    "sorted names " .. table.concat(names, ","))
check(nl == 2 and list[1].learned and not list[2].learned, "learned flags")
check(#H.Destinations(2, "Horde", nil) == 0, "Horde sees no Stormwind connections")

-- learning from a taxi scan
local function slot(name, kind, routesN, hops) return { name = name, kind = kind, routes = routesN, hops = hops or {} } end
local match = ns.places.pure.MatchName
local slots = {
    slot("Stormwind, Elwynn Forest", "CURRENT", 0),                        -- 1
    slot("Sentinel Hill, Westfall", "REACHABLE", 1, { { 1, 2 } }),         -- 2
    slot("Darkshire, Duskwood", "REACHABLE", 1, { { 1, 3 } }),             -- 3
    slot("Booty Bay, Stranglethorn Vale", "REACHABLE", 2, { { 1, 3 }, { 3, 4 } }), -- 4 via Darkshire
    slot("Zzz Unknown", "REACHABLE", 1, { { 1, 5 } }),                     -- 5
}
local scan = H.Resolve(slots, "Alliance", match)
check(scan and scan.current == 2, "current is Stormwind")
check(#scan.edges == 3, "edges seen " .. (scan and #scan.edges or -1))
check(#scan.multi == 1 and scan.multi[1] == 19, "multi-hop: Booty Bay (the Alliance row, node 19)")
local st = {}
local added, gone = H.Apply(st, "Alliance", scan)
check(added == 3 and gone == 1, "apply " .. added .. "/" .. gone)
check(st.learned["2-4"] and st.learned["2-12"] and st.learned["12-19"], "hop edges learned")
check(st.removed["2-19"] and not st.learned["2-19"], "static Stormwind - Booty Bay removed")
local g2 = H.Graph("Alliance", st)
check(not g2[2][19] and g2[12][19], "graph after the scan")
-- the Horde scan never touches Alliance rows
local hs = { slot("Orgrimmar, Durotar", "CURRENT", 0), slot("Crossroads, The Barrens", "REACHABLE", 1, { { 1, 2 } }) }
local hscan = H.Resolve(hs, "Horde", match)
check(hscan.current == 23 and hscan.edges[1][2] == 25, "Horde Orgrimmar - Crossroads")
-- a later scan where it is direct again restores it
local scan2 = H.Resolve({ slot("Stormwind, Elwynn Forest", "CURRENT", 0),
    slot("Booty Bay, Stranglethorn Vale", "REACHABLE", 1, { { 1, 2 } }) }, "Alliance", match)
H.Apply(st, "Alliance", scan2)
check(not st.removed["2-19"] and st.learned["2-19"] and H.Graph("Alliance", st)[2][19], "edge restored")
-- no current node / no edges: nothing changes
check(H.Resolve({ slot("Darkshire, Duskwood", "REACHABLE", 1) }, "Alliance", match) == nil, "no current")
local st3 = {}
check(select(1, H.Apply(st3, "Alliance", { current = 2, edges = {}, multi = { 19 } })) == 0 and not st3.removed, "empty scan")
-- routes == 1 without hop data still gives the edge
local s4 = H.Resolve({ slot("Stormwind, Elwynn Forest", "CURRENT", 0), slot("Lakeshire, Redridge Mountains", "REACHABLE", 1) },
    "Alliance", match)
check(#s4.edges == 1 and s4.edges[1][2] == 5, "single hop without hop data")

-- world position direction: the map turns x to world -y and y to world x (any axes work)
local dx, dy = H.MapDelta({ 100, 200 }, { 100, 200 - 0.05 * 1000 }, { 100 + 0.05 * 1000, 200 }, { 100 + 300, 200 - 500 }, 0.05, 0.05)
check(math.abs(dx - 0.5) < 1e-9 and math.abs(dy - 0.3) < 1e-9, "map delta " .. tostring(dx) .. "," .. tostring(dy))
check(H.MapDelta({ 0, 0 }, { 1, 1 }, { 2, 2 }, { 5, 5 }, 1, 1) == nil, "degenerate basis")

-- tooltip through the pin hook + option + slash
local db = { places_flights = true, places_graves = true }
ns.places.Bind(db, core)
check(db.places_routes == true, "default on")
local tipLines = {}
local tip = { AddLine = function(_, t, r, g, b) tipLines[#tipLines + 1] = { t = t, r = r, g = g, b = b } end }
local pin = { data = { kind = "flight", e = byNode[2], x = 0.5, y = 0.5 }, GetParent = function() return {} end }
ns.routes.OnEnter(pin, tip)
check(#tipLines == 9, "tooltip lines " .. #tipLines)
check(tipLines[2] and tipLines[2].t:find("Direct flights: 7 %(0 learned%)"), "tooltip header " .. tostring(tipLines[2] and tipLines[2].t))
check(tipLines[3] and tipLines[3].t == "Booty Bay" and tipLines[3].r == 0.6, "grey when not learned")
ns.places.Slash("routes", "off")
check(db.places_routes == false, "slash off")
tipLines = {}
ns.routes.OnEnter(pin, tip)
check(#tipLines == 0, "no tooltip lines when off")
ns.places.Slash("routes", "on")
check(db.places_routes == true, "slash on")
local m = ns.places.MenuEntries()
local found
for _, e in ipairs(m) do if e.text == "Show flight connections on hover" then found = e end end
check(found and found.checked() == true, "menu entry")
found.func(); check(db.places_routes == false, "menu toggles")
local status = table.concat(ns.places.StatusLines(), "\n")
check(status:find("flight routes: hover off") and status:find("Alliance 70 static") and status:find("Horde 74 static"), "status line")
-- the scan through the legacy API (stubs)
G.NumTaxiNodes = function() return #slots end
G.TaxiNodeName = function(i) return slots[i].name end
G.TaxiNodeGetType = function(i) return slots[i].kind end
G.GetNumRoutes = function(i) return slots[i].routes end
G.TaxiGetNodeSlot = function(i, hop, src) return slots[i].hops[hop][src and 1 or 2] end
db.placesRoutes = {}
ns.routes.Scan()
check(db.placesRoutes.Alliance and db.placesRoutes.Alliance.removed["2-19"], "Scan saves into the db")
check(db.placesRoutes._v == 1, "store version")

if fails == 0 then print("gps_routes_test: all ok") else print(fails .. " failures"); os.exit(1) end
