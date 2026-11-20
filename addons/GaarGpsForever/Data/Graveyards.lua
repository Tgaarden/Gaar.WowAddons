-- Graveyards (spirit healers) of the world: [uiMapID] = { { x, y, name }, ... }, x, y 0-1 on that map.
-- Sources, cross-checked: (1) the graveyard locations of the vanilla world server data (CMaNGOS
-- classic-db world_safe_locs + game_graveyard_zone: every graveyard a zone sends ghosts to), (2)
-- Wowhead Classic, Spirit Healer (NPC 6491) spawns. A graveyard in (1) is placed at its own location;
-- a spirit healer spot in (2) that no graveyard in (1) explains (later-season graveyards) is added at
-- its spawn. World positions are put on the zone maps of the WoW Forever 1.60.1 client
-- (UiMapAssignment, wago.tools branch wowf). Battlegrounds, instances and battleground exits are left
-- out; Thunder Bluff and Darnassus are on their city map and their zone map. Compiled by a hand-run
-- script; no code or data file of another addon is copied. At runtime C_DeathInfo.GetGraveyardsForMap
-- is merged in when the client has it (Places.lua).
local _, ns = ...
ns = type(ns) == "table" and ns or {}
ns.graveyards = {
    [1417] = { -- Arathi Highlands
        { 0.486, 0.558, "Arathi Highlands" },
    },
    [1440] = { -- Ashenvale
        { 0.178, 0.110 },
        { 0.222, 0.282 },
        { 0.404, 0.531, "Astranaar" },
        { 0.515, 0.632 },
        { 0.807, 0.586, "Kargathia" },
        { 0.842, 0.568 },
        { 0.932, 0.422 },
    },
    [1447] = { -- Azshara
        { 0.144, 0.787, "Talrendis Point" },
        { 0.544, 0.709, "Southridge Beach" },
        { 0.704, 0.164, "Legash Encampment" },
    },
    [1418] = { -- Badlands
        { 0.084, 0.552, "Kargath" },
        { 0.568, 0.241, "Graveyard NE" },
    },
    [1419] = { -- Blasted Lands
        { 0.510, 0.125, "Dreadmaul Hold" },
    },
    [1428] = { -- Burning Steppes
        { 0.637, 0.235, "Flame Crest" },
    },
    [1439] = { -- Darkshore
        { 0.417, 0.365, "Auberdine" },
        { 0.434, 0.926, "Twilight Vale" },
    },
    [1457] = { -- Darnassus
        { 0.776, 0.261, "Darnassus" },
    },
    [1430] = { -- Deadwind Pass
        { 0.400, 0.746, "Morgan's Plot" },
    },
    [1443] = { -- Desolace
        { 0.503, 0.632, "Ghost Walker Post" },
    },
    [1426] = { -- Dun Morogh
        { 0.298, 0.697, "Anvilmar" },
        { 0.471, 0.549, "Kharanos" },
        { 0.530, 0.357, "Ironforge" },
        { 0.544, 0.392, "Gates of Ironforge" },
    },
    [1411] = { -- Durotar
        { 0.441, 0.693, "Valley of Trials" },
        { 0.473, 0.179, "Northern Durotar" },
        { 0.535, 0.447, "Razor Hill" },
        { 0.572, 0.734, "Sen'jin Village" },
    },
    [1431] = { -- Duskwood
        { 0.200, 0.495, "Ravenhill" },
        { 0.448, 0.672 },
        { 0.478, 0.456 },
        { 0.749, 0.588, "Darkshire" },
    },
    [1445] = { -- Dustwallow Marsh
        { 0.395, 0.313, "Brackenwall Village" },
        { 0.636, 0.426, "Theramore Isle" },
    },
    [1423] = { -- Eastern Plaguelands
        { 0.325, 0.598, "Graveyard CG Tower" },
        { 0.336, 0.802, "Darrowshire" },
        { 0.409, 0.364, "Blackwood Lake" },
        { 0.705, 0.549, "Light's Hope Chapel" },
        { 0.852, 0.786 },
    },
    [1429] = { -- Elwynn Forest
        { 0.324, 0.524, "Stormwind" },
        { 0.393, 0.605, "Goldshire" },
        { 0.497, 0.430, "Northshire" },
        { 0.838, 0.697, "Eastvale Logging Camp" },
    },
    [1448] = { -- Felwood
        { 0.497, 0.312, "Irontree Woods" },
        { 0.564, 0.868, "Morlos'Aran" },
    },
    [1444] = { -- Feralas
        { 0.318, 0.481, "Feathermoon Stronghold" },
        { 0.440, 0.074 },
        { 0.504, 0.134 },
        { 0.548, 0.480, "Dire Maul" },
        { 0.730, 0.447, "Camp Mojache" },
    },
    [1424] = { -- Hillsbrad Foothills
        { 0.518, 0.531, "Southshore" },
        { 0.640, 0.196, "Tarren Mill" },
    },
    [1432] = { -- Loch Modan
        { 0.322, 0.470, "Thelsamar" },
    },
    [1450] = { -- Moonglade
        { 0.619, 0.692, "Moonglade" },
    },
    [1412] = { -- Mulgore
        { 0.415, 0.304, "Thunder Bluff" },
        { 0.428, 0.783, "Red Cloud Mesa" },
        { 0.458, 0.595, "Bloodhoof Village" },
    },
    [1433] = { -- Redridge Mountains
        { 0.164, 0.572, "Lakeshire" },
    },
    [1427] = { -- Searing Gorge
        { 0.354, 0.236, "Thorium Point" },
    },
    [1451] = { -- Silithus
        { 0.281, 0.875, "Scarab Wall (AQ Only)" },
        { 0.473, 0.376, "Cenarion Hold" },
        { 0.808, 0.204, "Valor's Rest" },
    },
    [1421] = { -- Silverpine Forest
        { 0.443, 0.411, "The Sepulcher" },
    },
    [1442] = { -- Stonetalon Mountains
        { 0.576, 0.620, "Webwinder Path" },
    },
    [1434] = { -- Stranglethorn Vale
        { 0.303, 0.733, "Booty Bay" },
        { 0.384, 0.088, "Northern Stranglethorn" },
    },
    [1435] = { -- Swamp of Sorrows
        { 0.503, 0.619, "Stonard" },
    },
    [1446] = { -- Tanaris
        { 0.540, 0.286, "Gadgetzan" },
    },
    [1438] = { -- Teldrassil
        { 0.333, 0.524, "Darnassus" },
        { 0.560, 0.921, "Rut'theran Village" },
        { 0.563, 0.628, "Dolanaar" },
        { 0.590, 0.426, "Aldrassil" },
    },
    [1413] = { -- The Barrens
        { 0.454, 0.611, "Camp Taurajo" },
        { 0.508, 0.326, "The Crossroads" },
        { 0.602, 0.399, "Ratchet" },
    },
    [1425] = { -- The Hinterlands
        { 0.169, 0.445, "Aerie Peak" },
        { 0.605, 0.386 },
        { 0.620, 0.268 },
        { 0.727, 0.685, "The Overlook Cliffs" },
    },
    [1441] = { -- Thousand Needles
        { 0.303, 0.235, "The Great Lift" },
        { 0.688, 0.533, "Shimmering Flats" },
    },
    [1456] = { -- Thunder Bluff
        { 0.567, 0.190, "Thunder Bluff" },
    },
    [1420] = { -- Tirisfal Glades
        { 0.311, 0.649, "Deathknell" },
        { 0.562, 0.494, "Brill" },
        { 0.622, 0.683, "Ruins of Lordaeron" },
        { 0.624, 0.669, "Undercity" },
        { 0.792, 0.409, "Faol's Rest" },
    },
    [1449] = { -- Un'Goro Crater
        { 0.803, 0.502, "The Marshlands" },
    },
    [1422] = { -- Western Plaguelands
        { 0.253, 0.564, "Bulwark" },
        { 0.450, 0.858, "Chillwind Camp" },
        { 0.658, 0.743, "Caer Darrow" },
    },
    [1436] = { -- Westfall
        { 0.520, 0.492, "Sentinel Hill" },
    },
    [1437] = { -- Wetlands
        { 0.113, 0.435, "Baradin Bay" },
        { 0.495, 0.414, "Crossroads" },
    },
    [1452] = { -- Winterspring
        { 0.612, 0.350, "Everlook" },
    },
}
