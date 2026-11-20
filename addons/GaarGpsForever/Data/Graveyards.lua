-- Graveyards (spirit healer spawns) of the vanilla world: [uiMapID] = { { x, y }, ... }, x, y 0-1 on that zone's map.
-- Source: Wowhead Classic, Spirit Healer (NPC 6491) spawn coordinates, clustered (spawns within 3% of each
-- other count as one graveyard) and compiled by hand into this table; no other addon's data is copied.
-- Capital cities, battlegrounds and instances are left out. The data does not tell which faction a
-- graveyard serves, so all are shown. Positions are spirit healer spawns, a little off the graveyard.
local _, ns = ...
ns = type(ns) == "table" and ns or {}
ns.graveyards = {
    [1411] = { -- Durotar
        { 0.442, 0.694 }, { 0.470, 0.174 }, { 0.534, 0.444 }, { 0.574, 0.732 },
    },
    [1412] = { -- Mulgore
        { 0.426, 0.780 }, { 0.464, 0.554 },
    },
    [1413] = { -- The Barrens
        { 0.452, 0.610 }, { 0.506, 0.326 }, { 0.602, 0.398 },
    },
    [1417] = { -- Arathi Highlands
        { 0.486, 0.556 },
    },
    [1418] = { -- Badlands
        { 0.082, 0.554 }, { 0.568, 0.244 },
    },
    [1419] = { -- Blasted Lands
        { 0.510, 0.122 },
    },
    [1420] = { -- Tirisfal Glades
        { 0.312, 0.648 }, { 0.562, 0.494 }, { 0.790, 0.408 }, { 0.820, 0.694 },
    },
    [1421] = { -- Silverpine Forest
        { 0.442, 0.414 },
    },
    [1422] = { -- Western Plaguelands
        { 0.454, 0.854 }, { 0.654, 0.748 },
    },
    [1423] = { -- Eastern Plaguelands
        { 0.382, 0.704 }, { 0.390, 0.924 }, { 0.472, 0.442 }, { 0.800, 0.644 }, { 0.964, 0.914 },
    },
    [1424] = { -- Hillsbrad Foothills
        { 0.514, 0.526 }, { 0.634, 0.194 },
    },
    [1425] = { -- The Hinterlands
        { 0.168, 0.444 }, { 0.604, 0.388 }, { 0.620, 0.268 }, { 0.726, 0.680 },
    },
    [1426] = { -- Dun Morogh
        { 0.294, 0.698 }, { 0.470, 0.550 }, { 0.542, 0.390 },
    },
    [1427] = { -- Searing Gorge
        { 0.354, 0.224 },
    },
    [1428] = { -- Burning Steppes
        { 0.632, 0.234 },
    },
    [1429] = { -- Elwynn Forest
        { 0.394, 0.604 }, { 0.494, 0.434 }, { 0.834, 0.694 },
    },
    [1430] = { -- Deadwind Pass
        { 0.400, 0.750 },
    },
    [1431] = { -- Duskwood
        { 0.200, 0.494 }, { 0.448, 0.672 }, { 0.478, 0.456 }, { 0.750, 0.590 },
    },
    [1432] = { -- Loch Modan
        { 0.324, 0.464 },
    },
    [1433] = { -- Redridge Mountains
        { 0.208, 0.564 },
    },
    [1434] = { -- Stranglethorn Vale
        { 0.300, 0.730 }, { 0.384, 0.088 },
    },
    [1435] = { -- Swamp of Sorrows
        { 0.502, 0.622 },
    },
    [1436] = { -- Westfall
        { 0.514, 0.498 },
    },
    [1437] = { -- Wetlands
        { 0.114, 0.434 }, { 0.494, 0.414 },
    },
    [1438] = { -- Teldrassil
        { 0.562, 0.632 }, { 0.586, 0.424 },
    },
    [1439] = { -- Darkshore
        { 0.418, 0.364 }, { 0.434, 0.924 },
    },
    [1440] = { -- Ashenvale
        { 0.178, 0.110 }, { 0.222, 0.282 }, { 0.402, 0.530 }, { 0.514, 0.632 }, { 0.806, 0.580 }, { 0.842, 0.568 }, { 0.932, 0.422 },
    },
    [1441] = { -- Thousand Needles
        { 0.304, 0.234 }, { 0.690, 0.534 },
    },
    [1442] = { -- Stonetalon Mountains
        { 0.574, 0.620 },
    },
    [1443] = { -- Desolace
        { 0.502, 0.628 },
    },
    [1444] = { -- Feralas
        { 0.314, 0.480 }, { 0.440, 0.074 }, { 0.504, 0.134 }, { 0.548, 0.474 }, { 0.730, 0.448 },
    },
    [1445] = { -- Dustwallow Marsh
        { 0.396, 0.308 }, { 0.634, 0.430 },
    },
    [1446] = { -- Tanaris
        { 0.540, 0.286 },
    },
    [1447] = { -- Azshara
        { 0.144, 0.784 }, { 0.542, 0.714 }, { 0.704, 0.156 },
    },
    [1448] = { -- Felwood
        { 0.494, 0.306 }, { 0.562, 0.866 },
    },
    [1449] = { -- Un'Goro Crater
        { 0.800, 0.498 },
    },
    [1450] = { -- Moonglade
        { 0.620, 0.694 },
    },
    [1451] = { -- Silithus
        { 0.280, 0.874 }, { 0.470, 0.384 }, { 0.806, 0.198 },
    },
    [1452] = { -- Winterspring
        { 0.612, 0.348 },
    },
}
