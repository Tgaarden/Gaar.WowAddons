-- LuaJIT stub test: GaarGpsForever 1.4 gathering spots (Gather.lua) - merge within radius,
-- nearest / next selection, yards on a map, alert cooldown, minimap cursor -> map position with
-- and without rotation, and the record -> GPS -> arrival -> auto-next flow with a stub core.
-- Run: luajit tools/test/gps_gather_test.lua   (from the repo root)
local path = "addons/GaarGpsForever/Gather.lua"
local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()

local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local G = setmetatable({}, { __index = function(t, k)
    if _G[k] ~= nil then return _G[k] end
    return nil end })
G._G = G
local function Num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v or nil end
G.GaarForever = {
    IsSecret = function() return false end,
    Plain = function(v) return v end,
    Num = Num,
    Str = function(v) return type(v) == "string" and v ~= "" and v or nil end,
    Bool = function(v) if v == nil then return nil end return v and true or false end,
    Call = function(fn, ...) if type(fn) ~= "function" then return end
        local r = { pcall(fn, ...) }; if not r[1] then return end; return unpack(r, 2, table.maxn(r)) end,
    Method = function(o, name, ...) if type(o) ~= "table" or type(o[name]) ~= "function" then return end
        return o[name](o, ...) end,
    API = function(ns, name)
        local t = G[ns]; if name == nil then return type(t) == "function" and t or nil end
        return type(t) == "table" and type(t[name]) == "function" and t[name] or nil end,
    InCombat = function() return G.__combat end,
    OnOff = function(v) return v and "on" or "off" end,
}
G.CreateFrame = widget
local clock = 1000
G.GetTime = function() return clock end
G.time = function() return 1700000000 end
G.PlaySound = function() G.__sounds = (G.__sounds or 0) + 1 end
G.C_Minimap = {   -- Find Herbs on
    GetNumTrackingTypes = function() return 2 end,
    GetTrackingInfo = function(i)
        if i == 1 then return { name = "Find Herbs", texture = 133939, active = true, spellID = 2383 } end
        return { name = "Find Minerals", texture = 136025, active = false, spellID = 2580 }
    end,
}

local ns = {}
local f = loadstring(src, "@Gather.lua"); setfenv(f, G)
local ok, err = pcall(f, "GaarGpsForever", ns)
assert(ok, "load: " .. tostring(err))
local gather, P = ns.gather, ns.gather.pure

local fails = 0
local function check(name, cond)
    print(string.format("%-62s %s", name, cond and "ok" or "FAIL"))
    if not cond then fails = fails + 1 end
end
local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end

-- A map 1000 x 500 yards (width east-west, height north-south).
local W, H = 1000, 500

-- Yards ---------------------------------------------------------------------
check("yards: 0.1 east on a 1000 yd map is 100 yd", near(P.MapYards(0.5, 0.5, 0.6, 0.5, W, H), 100))
check("yards: 0.1 south on a 500 yd map is 50 yd", near(P.MapYards(0.5, 0.5, 0.5, 0.6, W, H), 50))
check("yards: 3-4-5 triangle", near(P.MapYards(0, 0, 0.03, 0.08, W, H), 50))

-- Merge -----------------------------------------------------------------------
local list = {}
local n1, new1 = P.MergeNode(list, { x = 0.5, y = 0.5, name = "Peacebloom", kind = "herb" }, W, H, 15, 1)
check("merge: first gather is a new spot", new1 and #list == 1 and n1.count == 1)
local n2, new2 = P.MergeNode(list, { x = 0.51, y = 0.5, name = "Peacebloom", kind = "herb" }, W, H, 15, 2)
check("merge: 10 yd away, same name -> same spot, count 2", not new2 and n2 == n1 and n1.count == 2)
check("merge: position averaged", near(n1.x, 0.505) and n1.lastSeen == 2)
local _, new3 = P.MergeNode(list, { x = 0.53, y = 0.5, name = "Peacebloom", kind = "herb" }, W, H, 15, 3)
check("merge: 25 yd away -> a new spot", new3 and #list == 2)
local _, new4 = P.MergeNode(list, { x = 0.505, y = 0.5, name = "Silverleaf", kind = "herb" }, W, H, 15, 4)
check("merge: other name at the same place -> a new spot", new4 and #list == 3)
local seen, newSeen = P.MergeNode(list, { x = 0.506, y = 0.501, name = "Peacebloom", kind = "herb", unconfirmed = true }, W, H, 15, 5)
check("merge: minimap estimate never changes a known spot", not newSeen and seen == n1 and n1.count == 2 and near(n1.x, 0.505))
local u, newU = P.MergeNode(list, { x = 0.2, y = 0.2, name = "Copper Vein", kind = "ore", unconfirmed = true }, W, H, 15, 6)
check("merge: estimate far from all -> unconfirmed spot, count 0", newU and u.unconfirmed and u.count == 0)
local u2 = P.MergeNode(list, { x = 0.201, y = 0.2, name = "Copper Vein", kind = "ore" }, W, H, 15, 7)
check("merge: gather confirms it at the gathered position", u2 == u and not u.unconfirmed and u.count == 1 and near(u.x, 0.201))

-- Nearest / next -------------------------------------------------------------
local spots = {
    { x = 0.50, y = 0.50, name = "A", kind = "herb" },   -- 0 yd from the player
    { x = 0.55, y = 0.50, name = "B", kind = "herb" },   -- 50 yd
    { x = 0.60, y = 0.50, name = "C", kind = "herb" },   -- 100 yd
    { x = 0.52, y = 0.50, name = "D", kind = "ore" },    -- 20 yd, other kind
    { x = 0.50, y = 0.585, name = "E", kind = "herb", unconfirmed = true }, -- 42.5 yd, x1.25 = 53
}
local herb = { herb = true }
local best, d = P.Nearest(spots, 0.5, 0.5, W, H, herb, nil, 10)
check("nearest: skips the spot you stand on, picks B (50 yd)", best == spots[2] and near(d, 50))
best = P.Nearest(spots, 0.5, 0.5, W, H, { herb = true, ore = true }, nil, 10)
check("nearest: ore tracked too -> D (20 yd)", best == spots[4])
best = P.Nearest(spots, 0.5, 0.5, W, H, herb, function(n) return n == spots[2] end, 10)
check("next: B excluded -> E (unconfirmed 42.5 yd beats C 100 yd)", best == spots[5])
best = P.Nearest(spots, 0.5, 0.5, W, H, herb, function(n) return n == spots[2] or n == spots[5] end, 10)
check("next: B and E excluded -> C", best == spots[3])
spots[5].x = 0.5; spots[5].y = 0.598 -- 49 yd, x1.25 = 61 > B's 50
best = P.Nearest(spots, 0.5, 0.5, W, H, herb, nil, 10)
check("nearest: unconfirmed 49 yd loses to a known 50 yd spot", best == spots[2])

-- Alert pick and cooldown ----------------------------------------------------
local marks = {}
local a, ad = P.PickAlert(spots, 0.5, 0.5, W, H, herb, 80, marks, 0)
check("alert: nearest herb within 80 yd (A, 0 yd)", a == spots[1] and near(ad, 0))
marks[spots[1]] = 0
a = P.PickAlert(spots, 0.5, 0.5, W, H, herb, 80, marks, 10)
check("alert: A on cooldown -> next nearest by real yards, E (49 yd)", a == spots[5])
marks[spots[2]], marks[spots[5]] = 10, 10
a = P.PickAlert(spots, 0.5, 0.5, W, H, herb, 80, marks, 20)
check("alert: all within radius marked -> none (C is 100 yd)", a == nil)
a = P.PickAlert(spots, 0.5, 0.5, W, H, herb, 80, marks, 10 + P.REALERT_AFTER + 1)
check("alert: after 5 minutes A alerts again", a == spots[1] and marks[spots[1]] == nil)
marks = { [spots[1]] = 0 }
P.PickAlert(spots, 0.62, 0.5, W, H, herb, 80, marks, 30) -- A now 120 yd = 1.5 x 80
check("alert: exactly 1.5 x radius keeps the mark", marks[spots[1]] == 0)
P.PickAlert(spots, 0.63, 0.5, W, H, herb, 80, marks, 31) -- 130 yd
check("alert: beyond 1.5 x radius re-arms it", marks[spots[1]] == nil)

-- Minimap cursor -> map ------------------------------------------------------
-- Minimap 140 wide (half 70), radius 100 yd; player at 0.5, 0.5 of the 1000 x 500 map.
local x, y, yd = P.MinimapToMap(35, 0, 70, 100, false, nil, 0.5, 0.5, W, H)
check("minimap: cursor right of centre -> 50 yd east", near(x, 0.55) and near(y, 0.5) and near(yd, 50))
x, y = P.MinimapToMap(0, 35, 70, 100, false, nil, 0.5, 0.5, W, H)
check("minimap: cursor above centre -> 50 yd north (y smaller)", near(x, 0.5) and near(y, 0.4))
x = P.MinimapToMap(80, 0, 70, 100, false, nil, 0.5, 0.5, W, H)
check("minimap: cursor outside the minimap -> nil", x == nil)
-- Rotating, facing west (pi/2 counter-clockwise from north): up on the minimap is west.
x, y = P.MinimapToMap(0, 35, 70, 100, true, math.pi / 2, 0.5, 0.5, W, H)
check("minimap rotating, facing west: up is 50 yd west", near(x, 0.45) and near(y, 0.5))
x, y = P.MinimapToMap(35, 0, 70, 100, true, math.pi / 2, 0.5, 0.5, W, H)
check("minimap rotating, facing west: right is 50 yd north", near(x, 0.5) and near(y, 0.4))
x = P.MinimapToMap(0, 35, 70, 100, true, nil, 0.5, 0.5, W, H)
check("minimap rotating without facing -> nil", x == nil)
-- Round trip against the core's MinimapOffset (forward rotation), at an odd facing.
local function forward(east, north, facing)
    local c, s = math.cos(facing), math.sin(facing)
    return east * c + north * s, -east * s + north * c
end
local sx, sy = forward(30, -20, 2.1) -- yards on screen, before scaling to pixels
x, y = P.MinimapToMap(sx / 100 * 70, sy / 100 * 70, 70, 100, true, 2.1, 0.5, 0.5, W, H)
check("minimap rotating: inverse of the core's MinimapOffset", near(x, 0.53) and near(y, 0.54))

-- Tooltip names --------------------------------------------------------------
local names = P.SplitNames("|cffffffffPeacebloom|r\nSilverleaf|nCopper Vein |TInterface\\x:0|t", {})
check("tooltip: colour, texture and both line breaks", #names == 3 and names[1] == "Peacebloom"
    and names[2] == "Silverleaf" and names[3] == "Copper Vein")
check("treasure names", P.IsTreasureName("Battered Chest") and not P.IsTreasureName("Wooden Door"))

-- Flow with a stub core: record, GPS, arrival, auto-next ---------------------
local printed, wp = {}, nil
local player = { m = 12, x = 0.5, y = 0.5 }
local core = {
    Print = function(msg) printed[#printed + 1] = msg end,
    Safe = function(_, fn, ...) return fn(...) end,
    PlayerPosition = function() return 1, 0, 0, player.m, player.x, player.y end,
    PlayerMapID = function() return player.m end,
    WorldPos = function(_, mx, my) return 1, (1 - my) * H, (1 - mx) * W end, -- north, west
    MapName = function() return "Elwynn Forest" end,
    CoordText = function(a, b) return string.format("%.1f, %.1f", a * 100, b * 100) end,
    YardsText = function(v) return string.format("%d yd", math.floor(v + 0.5)) end,
    SetWaypoint = function(m, a, b, o) wp = { mapID = m, x = a, y = b, label = o and o.title } return true end,
    ClearWaypoint = function(reason) local had = wp; wp = nil; if reason == "arrived" then gather.OnArrived(had) end end,
    Waypoint = function() return wp end,
    MinimapRadius = function() return 100 end,
    RotatingMinimap = function() return false end,
}
local db = { gatherRadius = 5000, gatherNodes = { [12] = { { x = 2, y = 0.1, name = "Bad", kind = "herb" } } } }
gather.Bind(db, core)
check("bind: defaults on, radius clamped, bad node dropped", db.gather and db.gatherAutoNext
    and db.gatherRadius == 300 and db.gatherNodes[12] == nil)
gather.Start()

local function gatherAt(px, py, name, spell, guid)
    player.x, player.y = px, py
    gather.OnEvent(nil, "UNIT_SPELLCAST_SENT", "player", name, guid, spell)
    gather.OnEvent(nil, "UNIT_SPELLCAST_SUCCEEDED", "player", guid, spell)
end
gatherAt(0.50, 0.50, "Peacebloom", 2366, "g1")
gatherAt(0.55, 0.50, "Silverleaf", 2366, "g2")
gatherAt(0.60, 0.50, "Peacebloom", 2366, "g3")
gatherAt(0.30, 0.50, "Copper Vein", 2575, "g4")
gatherAt(0.70, 0.50, "Raw Brilliant Smallfish", 7620, "g5")         -- fishing: skipped
gatherAt(0.70, 0.50, "Wooden Door", 3365, "g6")                     -- opening a door: skipped
player.x = 0.40
gather.OnEvent(nil, "UNIT_SPELLCAST_SENT", "player", "Earthroot", "g7", 2366)
gather.OnEvent(nil, "UNIT_SPELLCAST_FAILED", "player", "g7", 2366)   -- failed: skipped
gather.OnEvent(nil, "UNIT_SPELLCAST_SENT", "player", "Battered Chest", "g8", 3365)
gather.OnEvent(nil, "LOOT_OPENED")                                  -- chest via loot window
local zone = db.gatherNodes[12]
check("record: 3 herbs, 1 ore, 1 chest; fishing, door, failed cast skipped", #zone == 5)
local kinds = {}
for _, n in ipairs(zone) do kinds[n.kind] = (kinds[n.kind] or 0) + 1 end
check("record: kinds herb 3, ore 1, treasure 1", kinds.herb == 3 and kinds.ore == 1 and kinds.treasure == 1)
G.__combat = true
gatherAt(0.9, 0.9, "Peacebloom", 2366, "g9")
G.__combat = nil
check("record: nothing in combat", #zone == 5)

-- Herbs tracked (Find Herbs on): GPS goes to herbs only. Everything was just gathered, so
-- wait out the visited time first.
clock = clock + 400
player.x, player.y = 0.535, 0.5
gather.Slash("")
check("gather: nearest herb is Silverleaf (15 yd), the ore is not tracked", wp and wp.label == "Silverleaf"
    and near(wp.x, 0.55))
gather.Slash("next")
check("gather next: skips Silverleaf -> Peacebloom at 0.5 (35 yd)", wp and wp.label == "Peacebloom" and near(wp.x, 0.5))
-- Arrive: the core clears with "arrived" -> auto-next to the remaining herb.
core.ClearWaypoint("arrived")
check("arrival: auto-next to the other Peacebloom (0.6)", wp and wp.label == "Peacebloom" and near(wp.x, 0.6))
-- Gathering the target counts as arriving; then nothing is left -> no waypoint.
gatherAt(0.6, 0.5, "Peacebloom", 2366, "g10")
check("gathering the target arrives; no herbs left -> no waypoint", wp == nil)
check("that spot was merged, count 2", zone[3].count == 2)
gather.Slash("autonext off")
check("autonext off saved", db.gatherAutoNext == false)

-- Proximity alert: via the driver's check (radius 300 here, so the 0.3 ore would count if
-- tracked; herbs are all visited right now -> no alert yet).
gather.Slash("radius 80")
check("radius 80 saved", db.gatherRadius == 80)

-- Clear.
gather.Slash("clear zone")
check("clear zone without yes keeps the spots", #db.gatherNodes[12] == 5)
gather.Slash("clear zone yes")
check("clear zone yes forgets them", db.gatherNodes[12] == nil)

print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
