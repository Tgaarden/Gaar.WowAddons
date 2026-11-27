-- Classic zone level ranges of the world map, for GaarMapsForever's "Level 35-45" line.
-- ns.zoneLevels.byId[uiMapID] = { min, max }: the classic uiMapIDs (1411-1452) the WoW Forever client
-- uses (the same ids as GaarGpsForever's data). ns.zoneLevels.byName is the same table by English zone
-- name, a fallback for a client whose ids differ. Cities, instances and TBC+ zones are left out on
-- purpose: no entry means no line. The ranges are the standard classic zone ranges.
-- WoW Forever's own zones (1.8.0) use the ranges Thomas gave: Riverglades (2548) and Mount Hyjal (2482,
-- the id GaarGpsForever's flight paths use) by id, Shen'dralas by name only (its uiMapID is not known
-- yet). ns.zoneLevels.byKey is byName keyed by NameKey (lower case, letters and digits only), so a
-- hovered name with another apostrophe or case still matches.
local _, ns = ...
ns = type(ns) == "table" and ns or {}

local ZONES = {
    { 1411, "Durotar", 1, 10 },            { 1412, "Mulgore", 1, 10 },
    { 1413, "The Barrens", 10, 25 },       { 1416, "Alterac Mountains", 30, 40 },
    { 1417, "Arathi Highlands", 30, 40 },  { 1418, "Badlands", 35, 45 },
    { 1419, "Blasted Lands", 45, 55 },     { 1420, "Tirisfal Glades", 1, 10 },
    { 1421, "Silverpine Forest", 10, 20 }, { 1422, "Western Plaguelands", 51, 58 },
    { 1423, "Eastern Plaguelands", 53, 60 }, { 1424, "Hillsbrad Foothills", 20, 30 },
    { 1425, "The Hinterlands", 40, 50 },   { 1426, "Dun Morogh", 1, 10 },
    { 1427, "Searing Gorge", 43, 50 },     { 1428, "Burning Steppes", 50, 58 },
    { 1429, "Elwynn Forest", 1, 10 },      { 1430, "Deadwind Pass", 55, 60 },
    { 1431, "Duskwood", 18, 30 },          { 1432, "Loch Modan", 10, 20 },
    { 1433, "Redridge Mountains", 15, 25 }, { 1434, "Stranglethorn Vale", 30, 45 },
    { 1435, "Swamp of Sorrows", 35, 45 },  { 1436, "Westfall", 10, 20 },
    { 1437, "Wetlands", 20, 30 },          { 1438, "Teldrassil", 1, 10 },
    { 1439, "Darkshore", 10, 20 },         { 1440, "Ashenvale", 18, 30 },
    { 1441, "Thousand Needles", 25, 35 },  { 1442, "Stonetalon Mountains", 15, 27 },
    { 1443, "Desolace", 30, 40 },          { 1444, "Feralas", 40, 50 },
    { 1445, "Dustwallow Marsh", 35, 45 },  { 1446, "Tanaris", 40, 50 },
    { 1447, "Azshara", 45, 55 },           { 1448, "Felwood", 48, 55 },
    { 1449, "Un'Goro Crater", 48, 55 },    { 1450, "Moonglade", 55, 60 },
    { 1451, "Silithus", 55, 60 },          { 1452, "Winterspring", 53, 60 },
    -- WoW Forever zones
    { 2548, "Riverglades", 36, 44 },       { 2482, "Mount Hyjal", 55, 60 },
    { nil, "Shen'dralas", 40, 45 },        -- id unknown: matched by name
}

-- "Shen’dralas" / "shen'dralas" -> "shendralas"; nil for anything that is not a non-empty string.
local function NameKey(s)
    if type(s) ~= "string" then return nil end
    s = s:lower():gsub("[^%w]", "")
    return s ~= "" and s or nil
end

local byId, byName, byKey = {}, {}, {}
for _, z in ipairs(ZONES) do
    local r = { z[3], z[4] }
    if z[1] then byId[z[1]] = r end
    byName[z[2]] = r
    byKey[NameKey(z[2])] = r
end
ns.zoneLevels = { byId = byId, byName = byName, byKey = byKey, NameKey = NameKey, count = #ZONES }
