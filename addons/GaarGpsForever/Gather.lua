--[[
  GaarGpsForever - gathering spots (1.4).

  Addons cannot read the minimap's tracking blips (herbs, ore), so this module remembers the
  nodes you actually gather, the way GatherMate does, and points the GPS arrow at them.

    * Recording. UNIT_SPELLCAST_SENT for "player" names the node you are gathering (its target
      argument, e.g. "Peacebloom" or "Copper Vein"); the spot is stored when that cast succeeds
      (UNIT_SPELLCAST_SUCCEEDED with the same cast GUID) or, failing that, when the loot window
      opens (LOOT_OPENED) within PENDING_TTL seconds. A failed or interrupted cast drops it.
      Gathering spells are matched by spell ID (Herb Gathering 2366/2368/3570/11993, Mining
      2575/2576/3564/10248, Opening 3365/6247/6477/6478/8917/21248/21288/21651/22810) and else
      by their localized names (C_Spell.GetSpellName / GetSpellInfo of those IDs, plus the enUS
      names). Skinning and Fishing are not matched: a skinned mob is no spot, and fishing
      belongs to GaarFishingForever. "Opening" counts only for a target whose name holds Chest,
      Footlocker or Strongbox (the "treasure" kind), so doors and quest objects are not stored.
      Nothing is recorded in combat or where the client gives no position (instances).
    * Storage, account-wide in GaarGpsForeverDB.gatherNodes[uiMapID] = list of
      { x, y, name, kind = "herb"|"ore"|"treasure", count, lastSeen, unconfirmed }, with x, y the
      player's own map position (C_Map.GetPlayerMapPosition on C_Map.GetBestMapForUnit) when the
      cast went off; lastSeen is time(). A gather within MERGE_YARDS of a stored spot with the same
      name is the same spot: count + 1 and the position averaged.
    * Yards. Each map's size in yards is worked out once, from C_Map.GetWorldPosFromMapPos of its
      corners (0,0) and (1,1) (the same world positions the arrow uses), else from
      C_Map.GetMapWorldSize. Inside one map, positions are linear in yards, so the distance
      between two points is sqrt((dx * width)^2 + (dy * height)^2). One API call per map, not
      one per node per check.
    * Proximity alert (gatherAlert, gatherRadius 80 yd, gatherSound). Once a second, out of
      combat only, the nearest stored spot of a tracked kind within the radius gives a sound, a
      line in UIErrorsFrame and a line in chat: "Herb spot nearby: Peacebloom (62 yd)". It is a
      known spot, not a promise that the node is up. One spot alerts again only after you have
      been more than 1.5 x the radius away from it, or after 5 minutes; spots you have just
      gathered or reached are skipped, and there are at least ALERT_GAP seconds between alerts.
    * Tracked kinds. C_Minimap.GetNumTrackingTypes / GetTrackingInfo (a table or the old
      name, texture, active), else the old globals, else GetTrackingTexture: Find Herbs (2383),
      Find Minerals (2580) and Find Treasure (2481), matched by spell ID, name or the spell's
      icon. When none of these can be read, alerts go to the kinds you have a profession for
      (IsPlayerSpell / C_SpellBook.IsSpellKnown / IsSpellKnown on the gathering spells; herb and
      ore when that cannot be read either). The GPS commands use the tracked kinds, else the
      profession kinds, else every kind.
    * GPS. /ggps gather sets the waypoint to the nearest known spot of those kinds in your zone
      (not one within 10 yards, not one gathered or reached in the last 5 minutes); /ggps gather
      next also skips the current one. On arrival (Gps's own 10-yard arrival) the next one is set
      by itself while gatherAutoNext is on. Gathering the target node counts as arriving.
    * Minimap hover (gatherHover). GameTooltip's OnShow and SetText are followed (HookScript and
      hooksecurefunc); while the owner is the Minimap (or a child of it), its lines are split
      into names, and one that is a known herb, ore or treasure name (the built-in enUS lists
      below, the names already stored, or Chest / Footlocker / Strongbox) is placed on the map:
      the cursor's offset from the minimap centre (GetCursorPosition over the minimap's
      effective scale, minus its centre), over half the minimap's width, times its view radius
      in yards (C_Minimap.GetViewRadius, else the classic per-zoom table, indoor via IsIndoors),
      turned back by GetPlayerFacing when rotateMinimap is on, then divided by the map's size.
      A chat hint says "Peacebloom on minimap - /ggps gather hover to go there" (throttled), and
      /ggps gather hover sets the waypoint there. The spot is also stored as unconfirmed (count
      0): it never adds to a known spot, counts 25 % further away when choosing the nearest,
      and turns into a real spot the first time you gather there.

  Taint: no Blizzard function is replaced and nothing protected is touched; the hooks are
  HookScript and hooksecurefunc on GameTooltip. Every client value is checked for secrecy and
  type before it is compared, and each part runs through Gps's Safe (pcall, switched off for the
  session after its first error).

  The core (GaarGpsForever.lua) hands its helpers in with gather.Bind(db, core) at ADDON_LOADED
  and calls gather.Start() at login, gather.OnArrived(waypoint) on arrival, gather.Slash(args)
  for /ggps gather, and gather.HelpLines / StatusLines / MenuEntry for help, status and menu.
]]

local _G = _G
local _, ns = ...
ns = type(ns) == "table" and ns or {}

local BF = _G.GaarForever
local IsSecret, Plain, Num, Str, Bool = BF.IsSecret, BF.Plain, BF.Num, BF.Str, BF.Bool
local Call, Method, API = BF.Call, BF.Method, BF.API
local OnOff = BF.OnOff

local gather = {}
ns.gather = gather

local MERGE_YARDS = 15          -- a gather this close to a stored spot of the same name is that spot
local DEFAULT_RADIUS = 80       -- yards, proximity alert
local RADIUS_MIN, RADIUS_MAX = 20, 300
local CHECK_EVERY = 1           -- seconds between proximity checks
local REARM_FACTOR = 1.5        -- a spot alerts again after you were this x the radius away
local REALERT_AFTER = 300       -- or after this many seconds
local ALERT_GAP = 8             -- seconds between any two alerts
local VISITED_TTL = 300         -- seconds a gathered or reached spot is skipped (respawn time)
local PENDING_TTL = 8           -- seconds from the cast to the loot window that still count
local HOVER_TTL = 300           -- seconds /ggps gather hover still goes to the last hovered spot
local HOVER_EVERY = 0.25        -- seconds between reads of the same minimap tooltip
local HINT_GAP = 3              -- seconds between any two hover hints
local HINT_SAME_GAP = 30        -- seconds between hints for the same name
local SKIP_NEAR = 10            -- yards: a spot this close is where you stand, not where to go
local UNCONFIRMED_WEIGHT = 1.25 -- a minimap estimate counts this much further away
local TIP_LINES = 20

local KIND_LABEL = { herb = "Herb", ore = "Ore", treasure = "Treasure" }
local KIND_ORDER = { "herb", "ore", "treasure" }

-- Gathering spells by ID (classic ranks), and the enUS names as a last resort.
local SPELL_KIND = {
    [2366] = "herb", [2368] = "herb", [3570] = "herb", [11993] = "herb",
    [2575] = "ore", [2576] = "ore", [3564] = "ore", [10248] = "ore",
    [3365] = "treasure", [6247] = "treasure", [6477] = "treasure", [6478] = "treasure",
    [8917] = "treasure", [21248] = "treasure", [21288] = "treasure", [21651] = "treasure",
    [22810] = "treasure",
}
local SPELL_NAME_KIND = { ["Herb Gathering"] = "herb", ["Mining"] = "ore", ["Opening"] = "treasure",
    ["Opening - No Text"] = "treasure" }
local PROFESSION_SPELLS = { herb = { 2366, 2368, 3570, 11993 }, ore = { 2575, 2576, 3564, 10248 } }

-- Minimap tracking: spell ID, enUS name and a piece of the icon path.
local TRACKING = {
    herb = { id = 2383, name = "Find Herbs", icon = "flower_02" },
    ore = { id = 2580, name = "Find Minerals", icon = "earthquake" },
    treasure = { id = 2481, name = "Find Treasure", icon = "findtreasure" },
}

-- Classic herb and ore node names, enUS only: other locales still learn their names from what
-- is gathered (stored names count for the minimap hover too).
local HERBS = { "Peacebloom", "Silverleaf", "Earthroot", "Mageroyal", "Briarthorn", "Stranglekelp",
    "Bruiseweed", "Wild Steelbloom", "Grave Moss", "Kingsblood", "Liferoot", "Fadeleaf", "Goldthorn",
    "Khadgar's Whisker", "Wintersbite", "Firebloom", "Purple Lotus", "Arthas' Tears", "Sungrass",
    "Blindweed", "Ghost Mushroom", "Gromsblood", "Golden Sansam", "Dreamfoil", "Mountain Silversage",
    "Plaguebloom", "Icecap", "Black Lotus" }
local ORES = { "Copper Vein", "Tin Vein", "Silver Vein", "Iron Deposit", "Gold Vein", "Mithril Deposit",
    "Truesilver Deposit", "Dark Iron Deposit", "Small Thorium Vein", "Rich Thorium Vein",
    "Hakkari Thorium Vein", "Incendicite Mineral Vein", "Indurium Mineral Vein",
    "Lesser Bloodstone Deposit", "Small Obsidian Chunk", "Large Obsidian Chunk", "Ooze Covered Silver Vein",
    "Ooze Covered Gold Vein", "Ooze Covered Mithril Deposit", "Ooze Covered Truesilver Deposit",
    "Ooze Covered Thorium Vein", "Ooze Covered Rich Thorium Vein" }
local TREASURE_WORDS = { "Chest", "Footlocker", "Strongbox" }

local NAME_KIND = {}
for _, n in ipairs(HERBS) do NAME_KIND[n] = "herb" end
for _, n in ipairs(ORES) do NAME_KIND[n] = "ore" end

local db, core          -- GaarGpsForeverDB and the core's helpers, from gather.Bind
local started
local pending           -- { name, kind, guid, t } between UNIT_SPELLCAST_SENT and its success
local target            -- { node, mapID, x, y }: the waypoint this module set
local hoverSpot         -- { mapID, x, y, name, kind, node, t }: the last minimap estimate
local spellNameKind = {}  -- localized gathering spell name -> kind
local storedNames = {}  -- node name -> kind, from what was stored
local sizeCache = {}    -- uiMapID -> { w, h } in yards, or false
local visited = setmetatable({}, { __mode = "k" })  -- node -> GetTime() gathered or reached
local alerted = setmetatable({}, { __mode = "k" })  -- node -> GetTime() of its last alert
local lastAlert, lastHint, lastHintName, lastTipRead, lastTipKey = -1e9, -1e9, nil, -1e9, nil
local trackCache, trackCacheAt = nil, -1e9
local stats = { recorded = 0, newSpots = 0, noName = 0, hovered = 0, alerts = 0 }
local tipHooked

local function Print(msg) if core then core.Print(msg) end end
local function Now() return Num(Call(_G.GetTime)) or 0 end
local function Epoch() return Num(Call(_G.time)) or 0 end
local function Safe(feature, fn, ...)
    if core and core.Safe then return core.Safe(feature, fn, ...) end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
end

-- ---------------------------------------------------------------------------
-- Pure helpers (no client calls; tools/test/gps_gather_test.lua runs these)
-- ---------------------------------------------------------------------------

-- Yards between two points of one map whose size is w x h yards.
local function MapYards(ax, ay, bx, by, w, h)
    local dx, dy = (bx - ax) * w, (by - ay) * h
    return math.sqrt(dx * dx + dy * dy)
end

-- Adds a gather (or, with rec.unconfirmed, a minimap estimate) to a map's list. A spot of the
-- same name within `radius` yards is the same spot: a gather adds one to its count and moves it
-- to the average position (or, on an unconfirmed spot, confirms it at the gathered position); an
-- estimate never changes a spot. Returns the spot and whether it is new.
local function MergeNode(list, rec, w, h, radius, now)
    local best, bestD
    for _, n in ipairs(list) do
        if n.name == rec.name then
            local d = MapYards(n.x, n.y, rec.x, rec.y, w, h)
            if d <= radius and (not bestD or d < bestD) then best, bestD = n, d end
        end
    end
    if best then
        if rec.unconfirmed then return best, false end
        if best.unconfirmed then
            best.x, best.y, best.count, best.unconfirmed = rec.x, rec.y, 1, nil
        else
            local c = best.count or 1
            best.x = (best.x * c + rec.x) / (c + 1)
            best.y = (best.y * c + rec.y) / (c + 1)
            best.count = c + 1
        end
        best.lastSeen = now
        return best, false
    end
    local n = { x = rec.x, y = rec.y, name = rec.name, kind = rec.kind, lastSeen = now,
        count = rec.unconfirmed and 0 or 1, unconfirmed = rec.unconfirmed and true or nil }
    list[#list + 1] = n
    return n, true
end

-- The nearest spot of one of `kinds` (a set), further than minYards, that skip(node) does not
-- rule out. Unconfirmed spots count UNCONFIRMED_WEIGHT x further. Returns the spot and its yards.
local function Nearest(list, px, py, w, h, kinds, skip, minYards)
    local best, bestScore, bestD
    for _, n in ipairs(list) do
        if kinds[n.kind] and not (skip and skip(n)) then
            local d = MapYards(px, py, n.x, n.y, w, h)
            if d > (minYards or 0) then
                local score = n.unconfirmed and d * UNCONFIRMED_WEIGHT or d
                if not bestScore or score < bestScore then best, bestScore, bestD = n, score, d end
            end
        end
    end
    return best, bestD
end

-- The spot to alert for: the nearest of `kinds` within `radius` that has no live alert in
-- `marks` (node -> time) and that skip(node) does not rule out. A mark is cleared once the
-- player is more than REARM_FACTOR x radius from its spot, or after REALERT_AFTER seconds.
local function PickAlert(list, px, py, w, h, kinds, radius, marks, now, skip)
    local best, bestD
    for _, n in ipairs(list) do
        if kinds[n.kind] then
            local d = MapYards(px, py, n.x, n.y, w, h)
            local t = marks[n]
            if t and (d > radius * REARM_FACTOR or now - t > REALERT_AFTER) then
                marks[n] = nil
                t = nil
            end
            if not t and d <= radius and not (skip and skip(n)) and (not bestD or d < bestD) then
                best, bestD = n, d
            end
        end
    end
    return best, bestD
end

-- A point under the cursor on the minimap, as a position on the player's map.
--   dx, dy     cursor offset from the minimap centre, in the minimap's own units (right, up)
--   half       half the minimap's width in the same units; radius: its view radius in yards
--   rotating   rotateMinimap is on; facing: GetPlayerFacing() (radians, counter-clockwise from
--              north), needed only while rotating
--   px, py     the player on the map (0-1); w, h: the map's size in yards
-- The inverse of the core's MinimapOffset: on a rotating minimap, screen = R(facing) * world,
-- so world = R(-facing) * screen. Returns x, y (0-1) and the yards from the player, or nil.
local function MinimapToMap(dx, dy, half, radius, rotating, facing, px, py, w, h)
    if not half or half <= 0 or not radius or radius <= 0 or not w or w <= 0 or not h or h <= 0 then return nil end
    local sx, sy = dx / half * radius, dy / half * radius
    local yards = math.sqrt(sx * sx + sy * sy)
    if yards > radius * 1.05 then return nil end -- outside the minimap
    local east, north = sx, sy
    if rotating then
        if not facing then return nil end
        local c, s = math.cos(facing), math.sin(facing)
        east, north = sx * c - sy * s, sx * s + sy * c
    end
    local x, y = px + east / w, py - north / h
    if x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    return x, y, yards
end

-- Tooltip text into names: colour codes, textures and atlases out, split at line breaks.
local function SplitNames(text, out)
    local s = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    s = s:gsub("|n", "\n")
    for part in s:gmatch("[^\n]+") do
        part = part:gsub("^%s+", ""):gsub("%s+$", "")
        if part ~= "" then out[#out + 1] = part end
    end
    return out
end

local function IsTreasureName(name)
    for _, w in ipairs(TREASURE_WORDS) do
        if name:find(w, 1, true) then return true end
    end
    return false
end

gather.pure = { MapYards = MapYards, MergeNode = MergeNode, Nearest = Nearest, PickAlert = PickAlert,
    MinimapToMap = MinimapToMap, SplitNames = SplitNames, IsTreasureName = IsTreasureName,
    MERGE_YARDS = MERGE_YARDS, REARM_FACTOR = REARM_FACTOR, REALERT_AFTER = REALERT_AFTER }

-- ---------------------------------------------------------------------------
-- Client reads
-- ---------------------------------------------------------------------------

local function SpellName(id)
    local n = Str(Call(API("C_Spell", "GetSpellName"), id))
    if n then return n end
    local info = Call(API("C_Spell", "GetSpellInfo"), id)
    if not IsSecret(info) and type(info) == "table" then
        n = Str(info.name)
        if n then return n end
    end
    return Str(Call(API("GetSpellInfo"), id))
end

local function SpellTexture(id)
    local t = Call(API("C_Spell", "GetSpellTexture"), id)
    if t == nil then t = Call(API("GetSpellTexture"), id) end
    t = Plain(t)
    if type(t) == "number" or type(t) == "string" then return t end
end

local function BuildSpellNames()
    for name, kind in pairs(SPELL_NAME_KIND) do spellNameKind[name] = kind end
    for id, kind in pairs(SPELL_KIND) do
        local n = SpellName(id)
        if n then spellNameKind[n] = kind end
    end
end

local function KindOfSpell(spellID)
    local id = Num(spellID)
    if not id then return nil end
    if SPELL_KIND[id] then return SPELL_KIND[id] end
    local n = SpellName(id)
    return n and spellNameKind[n] or nil
end

-- The kind of a node name: the built-in lists, what was stored, or a treasure word.
local function NameKind(name)
    local k = NAME_KIND[name] or storedNames[name]
    if k then return k end
    if IsTreasureName(name) then return "treasure" end
end

-- The size of a map in yards (width east-west, height north-south), cached per map.
local function MapSize(mapID)
    local c = sizeCache[mapID]
    if c then return c.w, c.h end
    if c == false then return nil end
    local w, h
    local c1, ax, ay = core.WorldPos(mapID, 0, 0)
    local c2, bx, by = core.WorldPos(mapID, 1, 1)
    if c1 and c2 and c1 == c2 then w, h = math.abs(ay - by), math.abs(ax - bx) end
    if not w or w <= 0 or h <= 0 then
        local fw, fh = Call(API("C_Map", "GetMapWorldSize"), mapID)
        w, h = Num(fw), Num(fh)
    end
    if w and h and w > 0 and h > 0 then
        sizeCache[mapID] = { w = w, h = h }
        return w, h
    end
    -- Nothing cached on failure: loading may still be under way.
end

local function TrackKindOf(name, texture, spellID)
    for kind, t in pairs(TRACKING) do
        if spellID and spellID == t.id then return kind end
        if name and (name == t.name or name == SpellName(t.id)) then return kind end
        if texture ~= nil then
            local tex = SpellTexture(t.id)
            if tex ~= nil and tostring(tex) == tostring(texture) then return kind end
            if type(texture) == "string" and texture:lower():find(t.icon, 1, true) then return kind end
        end
    end
end

-- The gathering kinds minimap tracking has on: a set and where it was read, or nil when the
-- client gives no way to read tracking. Cached for 2 seconds.
local function TrackedKinds()
    local now = Now()
    if now - trackCacheAt < 2 then return trackCache and trackCache.kinds, trackCache and trackCache.from end
    local kinds, from = {}, nil
    local function scan(count, get, label)
        count = Num(count)
        if not count or count <= 0 or type(get) ~= "function" then return end
        from = label
        for i = 1, count do
            local a, b, c = Call(get, i)
            local name, tex, active, spellID
            if not IsSecret(a) and type(a) == "table" then
                name, tex, active, spellID = Str(a.name), Plain(a.texture), Bool(a.active), Num(a.spellID)
            else
                name, tex, active = Str(a), Plain(b), Bool(c)
            end
            if active then
                local k = TrackKindOf(name, tex, spellID)
                if k then kinds[k] = true end
            end
        end
    end
    scan(Call(API("C_Minimap", "GetNumTrackingTypes")), API("C_Minimap", "GetTrackingInfo"), "C_Minimap")
    if not from then scan(Call(API("GetNumTrackingTypes")), API("GetTrackingInfo"), "GetTrackingInfo") end
    if not from and API("GetTrackingTexture") then
        from = "GetTrackingTexture"
        local tex = Plain(Call(API("GetTrackingTexture")))
        if tex ~= nil then
            local k = TrackKindOf(nil, tex, nil)
            if k then kinds[k] = true end
        end
    end
    trackCacheAt = now
    trackCache = from and { kinds = kinds, from = from } or nil
    if from then return kinds, from end
end

-- The gathering professions the player has: a set, or nil when no spell check is there.
local function ProfessionKinds()
    local fns = {}
    for _, fn in pairs({ API("IsPlayerSpell"), API("C_SpellBook", "IsSpellKnown"), API("IsSpellKnown") }) do
        fns[#fns + 1] = fn -- pairs, not ipairs: a missing one leaves a hole
    end
    local any, kinds = false, {}
    for _, fn in ipairs(fns) do
        any = true
        for kind, ids in pairs(PROFESSION_SPELLS) do
            for _, id in ipairs(ids) do
                if Bool(Call(fn, id)) then kinds[kind] = true end
            end
        end
    end
    if any then return kinds end
end

local function Empty(set) return next(set) == nil end

-- Kinds for the proximity alert: tracked; untrackable -> professions; unknown -> herb and ore.
local function AlertKinds()
    local tracked, from = TrackedKinds()
    if tracked then return tracked, "tracking (" .. from .. ")" end
    local prof = ProfessionKinds()
    if prof then return prof, "professions (tracking not readable)" end
    return { herb = true, ore = true }, "herb and ore (neither tracking nor professions readable)"
end

-- Kinds for the GPS: tracked; none -> professions; none -> every kind.
local function GoKinds()
    local tracked = TrackedKinds()
    if tracked and not Empty(tracked) then return tracked end
    local prof = ProfessionKinds()
    if prof and not Empty(prof) then return prof end
    return { herb = true, ore = true, treasure = true }
end

local function KindsText(kinds)
    local parts = {}
    for _, k in ipairs(KIND_ORDER) do
        if kinds[k] then parts[#parts + 1] = k end
    end
    return #parts > 0 and table.concat(parts, "/") or "none"
end

local function IsVisited(n, now)
    local t = visited[n]
    return t ~= nil and now - t < VISITED_TTL
end

local function WaypointIsTarget()
    local wp = core and core.Waypoint()
    local t = target
    return wp and t and wp.mapID == t.mapID and math.abs(wp.x - t.x) < 1e-6 and math.abs(wp.y - t.y) < 1e-6
end

local function NodesOf(mapID)
    local list = db.gatherNodes[mapID]
    if not list then
        list = {}
        db.gatherNodes[mapID] = list
    end
    return list
end

-- ---------------------------------------------------------------------------
-- GPS to spots
-- ---------------------------------------------------------------------------

local function OffText() return "gathering spots are off: /ggps gather on" end

-- mode: "nearest" (/ggps gather), "next" (skips the current target) or "auto" (after arrival).
local function Go(mode)
    if not db.gather then
        Print(OffText())
        return false
    end
    local _, _, _, m, px, py = core.PlayerPosition()
    if not m then
        Print("no position here (an instance, or the client gives none).")
        return false
    end
    local now = Now()
    if mode == "next" and target and target.node then visited[target.node] = now end
    local kinds = GoKinds()
    local list, w, h = db.gatherNodes[m], MapSize(m)
    local node, d
    if list and w then
        node, d = Nearest(list, px, py, w, h, kinds, function(n) return IsVisited(n, now) end, SKIP_NEAR)
    end
    if not node then
        if mode ~= "nearest" and WaypointIsTarget() then core.ClearWaypoint("silent") end
        target = nil
        Print(string.format("no%s known %s spot in %s%s.", mode == "nearest" and "" or " more",
            KindsText(kinds), core.MapName(m), mode == "nearest" and " yet - gather some first" or ""))
        return false
    end
    target = { node = node, mapID = m, x = node.x, y = node.y }
    core.SetWaypoint(m, node.x, node.y, { title = node.name, quiet = true })
    Print(string.format("%s%s spot: %s, %s%s.", mode == "auto" and "next " or "",
        mode == "auto" and KIND_LABEL[node.kind]:lower() or KIND_LABEL[node.kind], node.name, core.YardsText(d),
        node.unconfirmed and " (seen on the minimap, not gathered yet)" or ""))
    return true
end

local function GoHover()
    if not db.gather then
        Print(OffText())
        return
    end
    local s = hoverSpot
    if not s or Now() - s.t > HOVER_TTL then
        Print("hover a herb, ore or treasure on the minimap first (it is kept for 5 minutes).")
        return
    end
    target = { node = s.node, mapID = s.mapID, x = s.x, y = s.y }
    core.SetWaypoint(s.mapID, s.x, s.y, { title = s.name .. " (minimap)", quiet = true })
    Print(string.format("%s from the minimap: %s %s (an estimate).", s.name, core.MapName(s.mapID),
        core.CoordText(s.x, s.y)))
end

-- From the core's ClearWaypoint("arrived"): our target reached -> the next one, if wanted.
function gather.OnArrived(had)
    local t = target
    if not db or not t or type(had) ~= "table" then return end
    if had.mapID ~= t.mapID or math.abs(had.x - t.x) > 1e-6 or math.abs(had.y - t.y) > 1e-6 then return end
    target = nil
    if t.node then visited[t.node] = Now() end
    if db.gather and db.gatherAutoNext then Go("auto") end
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

local function Record(p)
    if not p or BF.InCombat() then return end
    local _, _, _, m, px, py = core.PlayerPosition()
    if not m then return end
    local w, h = MapSize(m)
    if not w then return end
    local node, isNew = MergeNode(NodesOf(m), { x = px, y = py, name = p.name, kind = p.kind }, w, h,
        MERGE_YARDS, Epoch())
    storedNames[p.name] = p.kind
    stats.recorded = stats.recorded + 1
    visited[node] = Now()
    if isNew then
        stats.newSpots = stats.newSpots + 1
        Print(string.format("new %s spot: %s, %s %s.", p.kind, p.name, core.MapName(m), core.CoordText(px, py)))
    end
    -- Gathering the target node counts as arriving at it.
    if target and target.node == node and WaypointIsTarget() then core.ClearWaypoint("arrived") end
end

local function OnSent(unit, targetName, guid, spellID)
    if IsSecret(unit) or unit ~= "player" or not db or not db.gather or BF.InCombat() then return end
    local kind = KindOfSpell(spellID)
    if not kind then return end
    local name = Str(targetName)
    if not name then
        stats.noName = stats.noName + 1
        return
    end
    if kind == "treasure" and not IsTreasureName(name) then return end
    pending = { name = name, kind = kind, guid = Str(guid), t = Now() }
end

local function OnCastEnd(event, unit, guid)
    if IsSecret(unit) or unit ~= "player" or not pending then return end
    local g = Str(guid)
    if pending.guid and g and g ~= pending.guid then return end -- another cast
    local p = pending
    pending = nil
    if event == "UNIT_SPELLCAST_SUCCEEDED" and Now() - p.t <= PENDING_TTL then Record(p) end
end

local function OnLoot()
    local p = pending
    if not p then return end
    pending = nil
    if Now() - p.t <= PENDING_TTL then Record(p) end
end

-- ---------------------------------------------------------------------------
-- Proximity alert
-- ---------------------------------------------------------------------------

local function Alert(n, d)
    local text = string.format("%s spot nearby: %s (%s)%s", KIND_LABEL[n.kind], n.name, core.YardsText(d),
        n.unconfirmed and " - seen on the minimap only" or "")
    local ef = _G.UIErrorsFrame
    if type(ef) == "table" and type(ef.AddMessage) == "function" then
        Method(ef, "AddMessage", text, 0.4, 1, 0.4)
    end
    Print(text .. " - a known spot, /ggps gather to go there.")
    if db.gatherSound then
        local kit = _G.SOUNDKIT
        local id = type(kit) == "table" and (Num(kit.MAP_PING) or Num(kit.RAID_WARNING)) or nil
        Call(_G.PlaySound, id or 3175)
    end
    stats.alerts = stats.alerts + 1
end

local function CheckNearby()
    if not db or not db.gather or not db.gatherAlert or BF.InCombat() then return end
    local _, _, _, m, px, py = core.PlayerPosition()
    local list = m and db.gatherNodes[m]
    if not list or #list == 0 then return end
    local w, h = MapSize(m)
    if not w then return end
    local now = Now()
    local node, d = PickAlert(list, px, py, w, h, (AlertKinds()), db.gatherRadius, alerted, now,
        function(n) return IsVisited(n, now) or (target and target.node == n) end)
    if node and now - lastAlert >= ALERT_GAP then
        alerted[node] = now
        lastAlert = now
        Alert(node, d)
    end
end

local driver = CreateFrame("Frame")
local acc = 0
local function OnUpdate(_, elapsed)
    acc = acc + (Num(elapsed) or 0)
    if acc < CHECK_EVERY then return end
    acc = 0
    Safe("gatherAlert", CheckNearby)
end

local function ApplyDriver()
    local on = started and db and db.gather and db.gatherAlert
    driver:SetScript("OnUpdate", on and OnUpdate or nil)
end

-- ---------------------------------------------------------------------------
-- Minimap hover
-- ---------------------------------------------------------------------------

local function TipNames(tip)
    local names = {}
    local n = Num(Method(tip, "NumLines")) or 0
    for i = 1, math.min(n, TIP_LINES) do
        local fs = _G["GameTooltipTextLeft" .. i]
        local text = type(fs) == "table" and Str(Method(fs, "GetText")) or nil
        if text then SplitNames(text, names) end
    end
    return names
end

local function ReadTip(tip)
    if not db or not db.gather or not db.gatherHover or BF.InCombat() then return end
    local mm = _G.Minimap
    if type(mm) ~= "table" or type(tip) ~= "table" then return end
    local owner = Method(tip, "GetOwner")
    if IsSecret(owner) or type(owner) ~= "table" then return end
    if owner ~= mm and Method(owner, "GetParent") ~= mm then return end
    local found = {}
    for _, name in ipairs(TipNames(tip)) do
        local kind = NameKind(name)
        if kind then found[#found + 1] = { name = name, kind = kind } end
    end
    if #found == 0 then return end
    local now = Now()
    local key = found[1].name
    if key == lastTipKey and now - lastTipRead < HOVER_EVERY then return end
    lastTipKey, lastTipRead = key, now

    local _, _, _, m, px, py = core.PlayerPosition()
    if not m then return end
    local w, h = MapSize(m)
    local cx, cy = Call(_G.GetCursorPosition)
    cx, cy = Num(cx), Num(cy)
    local eff = Num(Method(mm, "GetEffectiveScale"))
    local mx, my = Method(mm, "GetCenter")
    mx, my = Num(mx), Num(my)
    local width = Num(Method(mm, "GetWidth"))
    if not w or not cx or not cy or not eff or eff <= 0 or not mx or not my or not width then return end
    local rotating = core.RotatingMinimap()
    local facing = rotating and Num(Call(_G.GetPlayerFacing)) or nil
    local x, y = MinimapToMap(cx / eff - mx, cy / eff - my, width / 2, core.MinimapRadius(mm), rotating, facing,
        px, py, w, h)
    if not x then return end

    local list, nodes = NodesOf(m), {}
    for i, f in ipairs(found) do
        nodes[i] = MergeNode(list, { x = x, y = y, name = f.name, kind = f.kind, unconfirmed = true }, w, h,
            MERGE_YARDS, Epoch())
        storedNames[f.name] = storedNames[f.name] or f.kind
    end
    hoverSpot = { mapID = m, x = x, y = y, name = found[1].name, kind = found[1].kind, node = nodes[1], t = now }
    stats.hovered = stats.hovered + 1

    if now - lastHint >= HINT_GAP and (key ~= lastHintName or now - lastHint >= HINT_SAME_GAP) then
        lastHint, lastHintName = now, key
        local names = {}
        for i, f in ipairs(found) do names[i] = f.name end
        Print(table.concat(names, ", ") .. " on minimap - /ggps gather hover to go there")
    end
end

local function OnTip(tip) Safe("gatherHover", ReadTip, tip) end

local function HookTooltip()
    if tipHooked then return end
    local tip = _G.GameTooltip
    if type(tip) ~= "table" then return end
    tipHooked = true
    if type(tip.HookScript) == "function" then pcall(tip.HookScript, tip, "OnShow", OnTip) end
    if type(_G.hooksecurefunc) == "function" and type(tip.SetText) == "function" then
        pcall(_G.hooksecurefunc, tip, "SetText", OnTip)
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
local registered = {}
local function OnEvent(_, event, a1, a2, a3, a4)
    if event == "UNIT_SPELLCAST_SENT" then
        Safe("gatherRecord", OnSent, a1, a2, a3, a4)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_INTERRUPTED" then
        Safe("gatherRecord", OnCastEnd, event, a1, a2)
    elseif event == "LOOT_OPENED" then
        Safe("gatherRecord", OnLoot)
    elseif event == "PLAYER_ENTERING_WORLD" then
        sizeCache = {}
        pending = nil
    end
end
gather.OnEvent = OnEvent

local UNIT_EVENTS = { "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED" }

local function RegisterEvents()
    for _, e in ipairs(UNIT_EVENTS) do
        local ok = type(events.RegisterUnitEvent) == "function" and pcall(events.RegisterUnitEvent, events, e, "player")
        if not ok then ok = pcall(events.RegisterEvent, events, e) end
        registered[e] = ok and true or nil
    end
    for _, e in ipairs({ "LOOT_OPENED", "PLAYER_ENTERING_WORLD" }) do
        registered[e] = pcall(events.RegisterEvent, events, e) and true or nil
    end
    events:SetScript("OnEvent", OnEvent)
end

-- ---------------------------------------------------------------------------
-- Settings and saved data
-- ---------------------------------------------------------------------------

local function CleanNodes(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, list in pairs(t) do
        local id = Num(k)
        if id and id > 0 and id == math.floor(id) and type(list) == "table" then
            local clean = {}
            for _, n in ipairs(list) do
                if type(n) == "table" then
                    local x, y, name, kind = Num(n.x), Num(n.y), Str(n.name), n.kind
                    if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 and name and KIND_LABEL[kind] then
                        local count = Num(n.count)
                        clean[#clean + 1] = { x = x, y = y, name = name, kind = kind,
                            count = count and count >= 0 and math.floor(count) or 1,
                            lastSeen = Num(n.lastSeen) or 0, unconfirmed = n.unconfirmed == true or nil }
                    end
                end
            end
            if #clean > 0 then out[id] = clean end
        end
    end
    return out
end

local BOOL_DEFAULTS = { gather = true, gatherAlert = true, gatherSound = true, gatherHover = true,
    gatherAutoNext = true }

-- The keys this module keeps in GaarGpsForeverDB (the core keeps them on load).
gather.SAVED_KEYS = { gather = true, gatherAlert = true, gatherRadius = true, gatherSound = true,
    gatherHover = true, gatherAutoNext = true, gatherNodes = true }

function gather.Bind(d, c)
    db, core = d, c
    for k, v in pairs(BOOL_DEFAULTS) do
        if type(db[k]) ~= "boolean" then db[k] = v end
    end
    local r = Num(db.gatherRadius)
    db.gatherRadius = r and math.max(RADIUS_MIN, math.min(RADIUS_MAX, math.floor(r + 0.5))) or DEFAULT_RADIUS
    db.gatherNodes = CleanNodes(db.gatherNodes)
    storedNames = {}
    for _, list in pairs(db.gatherNodes) do
        for _, n in ipairs(list) do storedNames[n.name] = storedNames[n.name] or n.kind end
    end
end

function gather.Start()
    if started or not db then return end
    started = true
    BuildSpellNames()
    RegisterEvents()
    HookTooltip()
    ApplyDriver()
end

local function SetFlag(key, on, text)
    db[key] = on and true or false
    ApplyDriver()
    Print(text .. " " .. OnOff(db[key]) .. ".")
end

local function SetOn(on) SetFlag("gather", on, "gathering spots") end
local function SetAlert(on) SetFlag("gatherAlert", on, "alert near a known gathering spot") end
local function SetSound(on) SetFlag("gatherSound", on, "gathering alert sound") end
local function SetHover(on) SetFlag("gatherHover", on, "minimap hover hint for gathering nodes") end
local function SetAutoNext(on) SetFlag("gatherAutoNext", on, "next gathering spot on arrival") end

local function SetRadius(v)
    v = Num(v)
    if not v then
        Print(string.format("usage: /ggps gather radius <%d-%d> (now %d yd)", RADIUS_MIN, RADIUS_MAX, db.gatherRadius))
        return
    end
    db.gatherRadius = math.max(RADIUS_MIN, math.min(RADIUS_MAX, math.floor(v + 0.5)))
    Print("gathering alert radius " .. db.gatherRadius .. " yd.")
end

local function Counts(list)
    local c = { herb = 0, ore = 0, treasure = 0, seen = 0, total = 0 }
    for _, n in ipairs(list) do
        c[n.kind] = c[n.kind] + 1
        c.total = c.total + 1
        if n.unconfirmed then c.seen = c.seen + 1 end
    end
    return c
end

local function CountsText(c)
    local parts = {}
    for _, k in ipairs(KIND_ORDER) do
        if c[k] > 0 then parts[#parts + 1] = c[k] .. " " .. k end
    end
    local s = #parts > 0 and table.concat(parts, ", ") or "none"
    if c.seen > 0 then s = s .. " (" .. c.seen .. " seen on the minimap only)" end
    return s
end

local function Totals()
    local spots, zones = 0, 0
    for _, list in pairs(db.gatherNodes) do
        if #list > 0 then
            zones = zones + 1
            spots = spots + #list
        end
    end
    return spots, zones
end

local function List()
    local rows = {}
    for id, list in pairs(db.gatherNodes) do
        if #list > 0 then rows[#rows + 1] = { name = core.MapName(id), c = Counts(list) } end
    end
    if #rows == 0 then
        Print("no gathering spots known yet: gather a herb, ore or chest and it is remembered.")
        return
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    local spots, zones = Totals()
    Print(string.format("known gathering spots: %d in %d zone%s", spots, zones, zones == 1 and "" or "s"))
    for i, r in ipairs(rows) do
        if i > 25 then
            Print("... and " .. (#rows - 25) .. " more zones")
            break
        end
        Print("  " .. r.name .. ": " .. CountsText(r.c))
    end
end

local function Clear(scope, yes)
    if scope == "all" then
        local spots = Totals()
        if not yes then
            Print(string.format("this forgets all %d known gathering spots (every character): /ggps gather clear all yes", spots))
            return
        end
        db.gatherNodes = {}
        target, hoverSpot = nil, nil
        Print("all " .. spots .. " gathering spots forgotten.")
    elseif scope == "zone" then
        local m = core.PlayerMapID()
        if not m then
            Print("no map for where you are.")
            return
        end
        local n = db.gatherNodes[m] and #db.gatherNodes[m] or 0
        if not yes then
            Print(string.format("this forgets the %d gathering spots in %s: /ggps gather clear zone yes", n, core.MapName(m)))
            return
        end
        db.gatherNodes[m] = nil
        if target and target.mapID == m then target = nil end
        if hoverSpot and hoverSpot.mapID == m then hoverSpot = nil end
        Print(n .. " gathering spots in " .. core.MapName(m) .. " forgotten.")
    else
        Print("usage: /ggps gather clear zone yes | /ggps gather clear all yes")
    end
end

-- ---------------------------------------------------------------------------
-- Slash, help, status, menu
-- ---------------------------------------------------------------------------

function gather.HelpLines()
    local on = db and db.gather
    return {
        "/ggps gather - waypoint to the nearest known herb/ore/treasure spot of the tracked kinds in this zone;"
            .. " /ggps gather next - the next one; /ggps gather hover - the node last hovered on the minimap",
        "/ggps gather on|off (now " .. OnOff(on) .. ") | alert on|off | radius <yd> | sound on|off | hover on|off"
            .. " | autonext on|off | list | clear zone|all yes",
    }
end

function gather.StatusLines()
    if not db then return {} end
    local spots, zones = Totals()
    local alertKinds, from = AlertKinds()
    local prof = ProfessionKinds()
    return {
        string.format("gathering: %s%salert %s (%d yd, sound %s)%shover hint %s%sauto-next %s%s%d spot%s in %d zone%s",
            OnOff(db.gather), " \194\183 ", OnOff(db.gatherAlert), db.gatherRadius, OnOff(db.gatherSound),
            " \194\183 ", OnOff(db.gatherHover), " \194\183 ", OnOff(db.gatherAutoNext), " \194\183 ",
            spots, spots == 1 and "" or "s", zones, zones == 1 and "" or "s"),
        string.format("gathering kinds: alerts for %s from %s; professions: %s; target: %s",
            KindsText(alertKinds), from, prof and KindsText(prof) or "not readable",
            target and (target.node and target.node.name or "a minimap estimate") or "none"),
        string.format("gathering this session: %d gathers, %d new spots, %d without a name, %d minimap reads, %d alerts"
            .. "   events: %s   tooltip hooked: %s   C_Minimap.GetTrackingInfo: %s",
            stats.recorded, stats.newSpots, stats.noName, stats.hovered, stats.alerts,
            (registered.UNIT_SPELLCAST_SENT and registered.UNIT_SPELLCAST_SUCCEEDED) and "yes" or "MISSING",
            tipHooked and "yes" or "no", API("C_Minimap", "GetTrackingInfo") and "yes" or "no"),
    }
end

-- The help line used for /ggps gather help.
local function PrintHelp()
    for _, l in ipairs(gather.HelpLines()) do Print(l) end
end

local function Toggle(arg, cur, fn)
    if arg == "on" then fn(true) elseif arg == "off" then fn(false) elseif arg == "" then fn(not cur)
    else PrintHelp() end
end

function gather.Slash(msg)
    if not db then
        Print("not loaded yet.")
        return
    end
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    local cmd, arg = msg:match("^(%S+)%s*(.-)$")
    cmd, arg = cmd or "", arg or ""
    if cmd == "" then
        Go("nearest")
    elseif cmd == "next" then
        Go("next")
    elseif cmd == "hover" and arg == "" then
        GoHover()
    elseif cmd == "hover" then
        Toggle(arg, db.gatherHover, SetHover)
    elseif cmd == "on" or cmd == "off" then
        SetOn(cmd == "on")
    elseif cmd == "alert" then
        Toggle(arg, db.gatherAlert, SetAlert)
    elseif cmd == "sound" then
        Toggle(arg, db.gatherSound, SetSound)
    elseif cmd == "autonext" or cmd == "auto" then
        Toggle(arg, db.gatherAutoNext, SetAutoNext)
    elseif cmd == "radius" then
        SetRadius(tonumber(arg))
    elseif cmd == "list" then
        List()
    elseif cmd == "clear" then
        local scope, yes = arg:match("^(%S*)%s*(%S*)$")
        Clear(scope, yes == "yes")
    else
        PrintHelp()
    end
end

function gather.MenuEntry()
    if not db then return nil end
    return { text = "Gathering spots", submenu = {
        { text = "Remember gathering spots", checkbox = true, checked = function() return db.gather end,
          func = function() SetOn(not db.gather) end },
        { text = "Alert near a known spot", checkbox = true, checked = function() return db.gatherAlert end,
          func = function() SetAlert(not db.gatherAlert) end },
        { text = "Alert radius", slider = true, min = 30, max = 200, step = 10,
          value = function() return db.gatherRadius end,
          set = function(v) db.gatherRadius = v end,
          format = function(v) return v .. " yd" end },
        { text = "Alert sound", checkbox = true, checked = function() return db.gatherSound end,
          func = function() SetSound(not db.gatherSound) end },
        { text = "Minimap hover hint", checkbox = true, checked = function() return db.gatherHover end,
          func = function() SetHover(not db.gatherHover) end },
        { text = "Next spot on arrival", checkbox = true, checked = function() return db.gatherAutoNext end,
          func = function() SetAutoNext(not db.gatherAutoNext) end },
        { text = "Go to nearest spot", func = function() Go("nearest") end },
        { text = "Go to next spot", func = function() Go("next") end },
    } }
end
