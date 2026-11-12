--[[
  BetterGpsForever - one waypoint with an arrow, a world map pin and a minimap pin, for WoW Forever.

  A light, TomTom-style single waypoint:

    * /way x y, /way x,y or /way <zone> x y sets the waypoint (x first, then y, 0-100). Without a
      zone it goes in the zone the player is in. /way alone shows it, /way clear removes it.
    * Alt + left-click (Option on Mac) on the world map (windowed or maximized) sets it at the clicked point on
      the map that is shown. Blizzard's own click still happens.
    * One waypoint only: a new one replaces the old.
    * An arrow on screen points at it and shows the distance in yards. Drag it to move it (unless
      locked), right-click it to clear the waypoint.
    * A pin on the world map and one on the minimap; the minimap pin sits on the edge when the
      waypoint is further away than the minimap shows.
    * Blizzard's own user waypoint is set too where the client allows it, and cleared with ours
      while it is still ours.
    * Under the distance, the time to get there at the speed you are closing in (m:ss, or h:mm:ss
      over an hour), from how fast the distance shrank over the last 3 seconds; "--" while you
      stand still, move away or have no position.
    * Within 10 yards the waypoint clears itself: "Arrived at <zone> x, y".
    * Corpse route (1.1, /bgps corpse on|off, default on): once you have released and are a ghost,
      the waypoint is your corpse, titled "Corpse", from C_DeathInfo.GetCorpseMapPosition on your
      map or one of its parents. It follows you across maps (graveyard, zone change) and does not
      clear itself on arrival. After resurrection it is cleared and the waypoint you had before
      comes back (or none). A waypoint you set yourself while dead replaces the corpse route and
      is the one kept after resurrection; clearing the corpse waypoint ends the route and brings
      the previous waypoint back at once.
    * Saved account-wide in BetterGpsForeverDB: the waypoint, the arrow's place, lock, on/off, the
      corpse setting and, while a corpse route runs, the waypoint to bring back.
    * /bgps (or /bettergpsforever) for help, status, arrow on|off, lock, unlock, reset, clear,
      corpse on|off and way <x y>. When TomTom is loaded /way stays TomTom's and /bgps way does
      the same job.
    * BetterGpsForeverAPI, a small global table for BetterGaarForever's hub menu and for other
      addons that set the waypoint (BetterQuestsForever's "Set GPS target"): SetWaypoint,
      ClearWaypoint, GetWaypoint.

  Coordinates. Positions are compared in world yards: C_Map.GetWorldPosFromMapPos turns a map
  point (the waypoint, and the player's C_Map.GetPlayerMapPosition) into a continent and a world
  position. World x grows to the north and world y to the west, so the bearing to the waypoint,
  counter-clockwise from north, is atan2(dy, dx) - the same sense as GetPlayerFacing(), and the
  arrow's rotation is the difference of the two. Two points on different continents have no
  distance.

  The world map pin sits on the waypoint's own map, or is converted to the map on display through
  the world position (C_Map.GetMapPosFromWorldPos with that map as the override), so it shows on
  the continent map as well. An alt-click is read from GetCursorPosition() against the canvas's
  own effective scale and rect, not Blizzard's cursor helper, so it lands under the pointer at any
  map scale (BetterMapsForever's or anyone's).

  Taint: Blizzard code is only ever followed, never replaced. The only hooks are HookScript on the
  map's scroll container (mouse down and up) and hooksecurefunc on WorldMapFrame's OnMapChanged.
  No Blizzard function or table is written. The pins are our own frames, made children of the
  map canvas and the minimap and placed by their normalised coordinates. Every API read is
  pcall-guarded and checked for type and secrecy; each feature (navigation, world map pin,
  minimap pin, native waypoint, alt-click) runs inside pcall and switches itself off for the
  session after its first error, with one line in chat.
]]

local _G = _G
local ADDON_NAME = ... or "BetterGpsForever"
local PREFIX = "|cff33ff99BetterGpsForever|r: "
local DOT = " \194\183 "

local VERSION = "1.2"

local ARRIVAL_YARDS = 10
local TICK = 0.05                -- seconds between arrow and minimap updates
local MAP_TICK = 0.1             -- seconds between world map pin checks while the map is open
local ETA_WINDOW = 3             -- seconds of distance samples the closing speed is measured over
local ETA_MIN_SPAN = 1           -- seconds of samples needed before a time is shown
local ETA_MIN_SPEED = 0.5        -- yards per second; slower than this counts as standing still
local CLICK_SLOP = 6             -- pixels the cursor may move between mouse down and up on a click
local ARROW_SIZE = 56
local PIN_SIZE = 16              -- world map pin, in screen units at any zoom
local MINIMAP_PIN_SIZE = 12
local DEFAULT_ARROW_POS = { point = "TOP", x = 0, y = -140 }
local FLAT = "Interface\\Buttons\\WHITE8x8"
-- Built-in arrow art, best first; the first one the client resolves is used.
local ARROW_TEXTURES = {
    "Interface\\Minimap\\MinimapArrow",
    "Interface\\Minimap\\ROTATING-MINIMAPARROW",
}
-- Minimap view radius in yards per zoom level, for a client without C_Minimap.GetViewRadius.
local MINIMAP_RADIUS = {
    outdoor = { [0] = 233.33, [1] = 200, [2] = 166.67, [3] = 133.33, [4] = 100, [5] = 66.67 },
    indoor = { [0] = 150, [1] = 120, [2] = 90, [3] = 60, [4] = 40, [5] = 25 },
}
local MAPTYPE_CONTINENT, MAPTYPE_ZONE = 2, 3 -- Enum.UIMapType, read from the client when it has it

local CORPSE_TITLE = "Corpse"
local CORPSE_POLL = 2            -- seconds between corpse checks while dead or a ghost
local TITLE_MAX = 60             -- characters of a waypoint title set through the API

local DEFAULTS = {
    arrow = true,
    locked = false,
    corpse = true,
}

-- Every key BetterGpsForeverDB may hold; anything else is cleared on load.
-- corpseRun: { prev = <waypoint or nil>, done = <bool> } while a corpse route runs.
local SAVED_KEYS = { waypoint = true, arrow = true, locked = true, arrowPos = true, corpse = true,
    corpseRun = true }

local db                -- BetterGpsForeverDB, bound at ADDON_LOADED (never at file scope)
local started           -- PLAYER_LOGIN work done
local wayRegistered     -- /way is ours
local wayOwner          -- why /way is not ours: "TomTom" or another addon's command
local worldCache        -- the waypoint's continent and world position, worked out once per waypoint
local native            -- the native user waypoint we set: { mapID, x, y }
local zoneList          -- zones for /way <zone>, read once on first use
local lastNav           -- the latest navigation result, for the status line and tooltip
local broken = {}       -- feature -> true once it has failed on this client
local clock = 0         -- seconds, summed from OnUpdate's elapsed (no clock API to trust or guard)
local samples = {}      -- { t, dist } of the last ETA_WINDOW seconds, oldest first

local arrowFrame, minimapPin, worldPin, mapDriver
local mapHooked

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end

-- Where the client hides a number it hands back a secret value, which can be neither compared
-- nor used in a sum. Those are treated as no number at all, and checked before anything else.
local issecretvalue = _G.issecretvalue
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

local function Num(v)
    if IsSecret(v) then return nil end
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

local function Bool(v)
    if IsSecret(v) then return nil end
    return v and true or false
end

local function Str(v)
    if IsSecret(v) or type(v) ~= "string" then return nil end
    return v
end

local function pack(ok, ...)
    if ok then return ... end
end

-- All the return values of fn, or nothing when it is missing or errors.
local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    return pack(pcall(fn, ...))
end

local function Method(obj, name, ...)
    if type(obj) ~= "table" then return nil end
    local fn = obj[name]
    if type(fn) ~= "function" then return nil end
    return pack(pcall(fn, obj, ...))
end

local function API(ns, name)
    local t = _G[ns]
    if type(t) ~= "table" then return nil end
    local fn = t[name]
    if type(fn) == "function" then return fn end
end

local function MapAPI(name) return API("C_Map", name) end

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function Round1(v) return math.floor(v * 10 + 0.5) / 10 end

local function CoordText(x, y)
    return string.format("%.1f, %.1f", Round1(x * 100), Round1(y * 100))
end

local function YardsText(d)
    return string.format("%d yd", math.floor(d + 0.5))
end

local function OnOff(v) return v and "on" or "off" end

-- m:ss, or h:mm:ss from an hour up.
local function DurationText(sec)
    sec = math.floor(sec + 0.5)
    local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

-- Whether an addon is loaded: C_AddOns on newer clients, the old global otherwise.
local function AddOnLoaded(name)
    local c = _G.C_AddOns
    if type(c) == "table" and type(c.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(c.IsAddOnLoaded, name)
        if ok and Bool(loaded) then return true end
    end
    if type(_G.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(_G.IsAddOnLoaded, name)
        if ok and Bool(loaded) then return true end
    end
    return false
end

-- A Vector2D for the map API: Blizzard's own where it exists, otherwise the plain fields it reads.
local function Vec(x, y)
    local v = Call(_G.CreateVector2D, x, y)
    if type(v) == "table" then return v end
    return { x = x, y = y }
end

-- The two numbers of a vector the client handed back, or nothing.
local function XY(v)
    if IsSecret(v) or type(v) ~= "table" then return nil end
    local x, y
    if type(v.GetXY) == "function" then
        x, y = Method(v, "GetXY")
    else
        x, y = v.x, v.y
    end
    x, y = Num(x), Num(y)
    if x and y then return x, y end
end

local function MapID(v)
    v = Num(v)
    if v and v > 0 then return v end
end

local function MapInfo(mapID)
    local info = Call(MapAPI("GetMapInfo"), mapID)
    if not IsSecret(info) and type(info) == "table" then return info end
end

local function MapName(mapID)
    local info = MapInfo(mapID)
    return info and Str(info.name) or ("map " .. tostring(mapID))
end

-- Runs one feature inside pcall. The first error switches that feature off for the session, with
-- one line in chat; after that it is never tried again (GaarCast's SafeUpdate).
local FEATURE_TEXT = {
    nav = "the arrow",
    worldPin = "the world map pin",
    minimapPin = "the minimap pin",
    native = "Blizzard's own waypoint",
    click = "Alt + left-click (Option on Mac) on the world map",
    corpse = "the corpse route",
}
local OnFeatureBroken -- hides what belongs to a feature; defined with the frames below

local function Safe(feature, fn, ...)
    if broken[feature] then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    broken[feature] = true
    Print(string.format("%s is switched off for this session: this client refused it. (%s)",
        FEATURE_TEXT[feature] or feature, tostring(a)))
    if OnFeatureBroken then pcall(OnFeatureBroken, feature) end
    return nil
end

-- ---------------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------------

local function InInstance()
    local inside = Call(_G.IsInInstance)
    return Bool(inside) or false
end

-- Continent and world position (north, west) of a point on a map, or nothing.
local function WorldPos(mapID, x, y)
    local cont, pos = Call(MapAPI("GetWorldPosFromMapPos"), mapID, Vec(x, y))
    cont = Num(cont)
    local wx, wy = XY(pos)
    if cont and wx then return cont, wx, wy end
end

-- The player's map, position on it and world position; nothing in an instance or wherever the
-- client gives no position.
local function PlayerPosition()
    if InInstance() then return nil end
    local m = MapID(Call(MapAPI("GetBestMapForUnit"), "player"))
    if not m then return nil end
    local px, py = XY(Call(MapAPI("GetPlayerMapPosition"), m, "player"))
    if not px or (px == 0 and py == 0) then return nil end
    local cont, wx, wy = WorldPos(m, px, py)
    if not cont then return nil end
    return cont, wx, wy, m, px, py
end

local function WaypointWorld()
    local wp = db and db.waypoint
    if not wp then return nil end
    if not worldCache then
        local cont, wx, wy = WorldPos(wp.mapID, wp.x, wp.y)
        if not cont then return nil end -- not ready yet (early in loading); asked again next tick
        worldCache = { cont = cont, x = wx, y = wy }
    end
    return worldCache.cont, worldCache.x, worldCache.y
end

-- Where the waypoint is from the player:
--   { state = "ok", dist, north, east, facing, rel } - rel is nil when facing is unknown
--   { state = "nopos" } - no player position here (instance, loading, no map)
--   { state = "far" } - on another continent
local function Navigate()
    local wc, wx, wy = WaypointWorld()
    local pc, px, py = PlayerPosition()
    if not pc or not wc then return { state = "nopos" } end
    if pc ~= wc then return { state = "far" } end
    local dn, dw = wx - px, wy - py
    local nav = { state = "ok", dist = math.sqrt(dn * dn + dw * dw), north = dn, east = -dw }
    nav.facing = Num(Call(_G.GetPlayerFacing))
    if nav.facing then nav.rel = atan2(dw, dn) - nav.facing end
    return nav
end

-- Time to the waypoint from the closing speed: how fast the distance shrank over the samples of
-- the last ETA_WINDOW seconds. nil (shown as "--") while standing still, moving away, or without
-- enough samples.
local function ResetEta()
    samples = {}
end

local function AddSample(t, dist)
    samples[#samples + 1] = { t = t, dist = dist }
    while #samples > 1 and t - samples[1].t > ETA_WINDOW do table.remove(samples, 1) end
end

local function Eta()
    local n = #samples
    if n < 2 then return nil end
    local first, last = samples[1], samples[n]
    local span = last.t - first.t
    if span < ETA_MIN_SPAN then return nil end
    local speed = (first.dist - last.dist) / span
    if speed < ETA_MIN_SPEED then return nil end
    return last.dist / speed
end

local function EtaText(nav)
    local eta = nav and nav.state == "ok" and nav.eta
    return eta and DurationText(eta) or "--"
end

-- ---------------------------------------------------------------------------
-- Blizzard's own user waypoint
-- ---------------------------------------------------------------------------

local function SetNative(mapID, x, y)
    native = nil
    if not Bool(Call(MapAPI("CanSetUserWaypointOnMap"), mapID)) then return end
    local point
    local UMP = _G.UiMapPoint
    if type(UMP) == "table" and type(UMP.CreateFromCoordinates) == "function" then
        point = Call(UMP.CreateFromCoordinates, mapID, x, y)
    end
    if type(point) ~= "table" then point = { uiMapID = mapID, position = Vec(x, y) } end
    if not Bool(Call(MapAPI("SetUserWaypoint"), point)) then
        -- Some builds return nothing; whether it took is read back.
        if not Bool(Call(MapAPI("HasUserWaypoint"))) then return end
    end
    native = { mapID = mapID, x = x, y = y }
    Call(API("C_SuperTrack", "SetSuperTrackedUserWaypoint"), true)
end

-- Clears Blizzard's waypoint only while it is still the one we set.
local function ClearNative()
    local mine = native
    native = nil
    if not mine then return end
    if not Bool(Call(MapAPI("HasUserWaypoint"))) then return end
    local point = Call(MapAPI("GetUserWaypoint"))
    if IsSecret(point) or type(point) ~= "table" then return end
    local px, py = XY(point.position)
    if MapID(point.uiMapID) ~= mine.mapID or not px then return end
    if math.abs(px - mine.x) > 0.0005 or math.abs(py - mine.y) > 0.0005 then return end
    Call(MapAPI("ClearUserWaypoint"))
end

-- ---------------------------------------------------------------------------
-- Waypoint
-- ---------------------------------------------------------------------------

local UpdateNow -- refreshes arrow, pins and ticker; defined with the frames below

local function WaypointText(wp)
    wp = wp or (db and db.waypoint)
    if not wp then return "no waypoint" end
    return (wp.label or MapName(wp.mapID)) .. " " .. CoordText(wp.x, wp.y)
end

-- opts (all optional): quiet = no chat line, title = the name shown instead of the zone's,
-- corpse = this is the corpse route's waypoint.
local function SetWaypoint(mapID, x, y, opts)
    if not db then return false end
    opts = type(opts) == "table" and opts or {}
    mapID = MapID(mapID)
    x, y = Num(x), Num(y)
    if not mapID or not x or not y or x < 0 or x > 1 or y < 0 or y > 1 then return false end
    -- A waypoint set while a corpse route runs replaces it and is the one kept after resurrection.
    local run = db.corpseRun
    if run and not opts.corpse then
        run.done = true
        run.prev = nil
    end
    local quiet = opts.quiet
    Safe("native", ClearNative)
    db.waypoint = { mapID = mapID, x = x, y = y, label = Str(opts.title) or MapName(mapID),
        corpse = opts.corpse and true or nil }
    worldCache = nil
    lastNav = nil
    ResetEta()
    Safe("native", SetNative, mapID, x, y)
    if not quiet then Print("waypoint set: " .. WaypointText() .. ".") end
    UpdateNow()
    return true
end

-- Puts a waypoint saved by the corpse route back, with its title. The line comes first, so an
-- arrival right away (already standing there) reads in order.
local function RestoreWaypoint(prev)
    if type(prev) ~= "table" then return false end
    Print("waypoint back: " .. WaypointText(prev) .. ".")
    return SetWaypoint(prev.mapID, prev.x, prev.y, { title = prev.label, quiet = true })
end

local function ClearWaypoint(reason)
    if not db then return end
    local had = db.waypoint
    Safe("native", ClearNative)
    db.waypoint = nil
    worldCache = nil
    lastNav = nil
    ResetEta()
    UpdateNow()
    if reason == "arrived" and had then
        Print("Arrived at " .. WaypointText(had) .. ".")
    elseif reason ~= "silent" then
        Print(had and ("waypoint cleared (" .. WaypointText(had) .. ").") or "there is no waypoint to clear.")
    end
    -- Clearing the corpse waypoint while the route runs ends the route: the waypoint from before
    -- comes back at once, and nothing is brought back at resurrection.
    local run = db.corpseRun
    if had and had.corpse and run and not run.done then
        local prev = run.prev
        run.done = true
        run.prev = nil
        RestoreWaypoint(prev)
    end
end

-- ---------------------------------------------------------------------------
-- Zones for /way <zone> x y
-- ---------------------------------------------------------------------------

local function ZoneTypes()
    local enum = _G.Enum
    local t = type(enum) == "table" and type(enum.UIMapType) == "table" and enum.UIMapType or nil
    return Num(t and t.Continent) or MAPTYPE_CONTINENT, Num(t and t.Zone) or MAPTYPE_ZONE
end

local function AddZone(list, seen, info)
    if IsSecret(info) or type(info) ~= "table" then return end
    local id, name, kind = MapID(info.mapID), Str(info.name), Num(info.mapType)
    local continent, zone = ZoneTypes()
    if not id or not name or name == "" or seen[id] or (kind ~= zone and kind ~= continent) then return end
    seen[id] = true
    list[#list + 1] = { mapID = id, name = name, key = name:lower(), kind = kind }
end

-- Every zone and continent under the top of the player's map tree, read once. Without the tree
-- (no position, no GetMapChildrenInfo) the map ids are walked instead.
local function Zones()
    if zoneList and #zoneList > 0 then return zoneList end
    local list, seen = {}, {}
    local root = MapID(Call(MapAPI("GetBestMapForUnit"), "player")) or 947
    for _ = 1, 12 do
        local info = MapInfo(root)
        local parent = info and MapID(info.parentMapID)
        if not parent then break end
        root = parent
    end
    local kids = Call(MapAPI("GetMapChildrenInfo"), root, nil, true)
    if not IsSecret(kids) and type(kids) == "table" then
        for _, info in ipairs(kids) do AddZone(list, seen, info) end
    end
    if #list == 0 then
        for id = 1, 3000 do AddZone(list, seen, MapInfo(id)) end
    end
    table.sort(list, function(a, b)
        if a.kind ~= b.kind then return a.kind > b.kind end -- zones before continents
        return a.mapID < b.mapID
    end)
    zoneList = list
    return list
end

-- One zone for a typed name: exact, then prefix, then anywhere in the name. Several maps with the
-- same name count as one (the first). Returns the zone, or nil and the candidate names.
local function FindZone(text)
    local key = text:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if key == "" then return nil, {} end
    local zones = Zones()
    local tests = {
        function(z) return z.key == key end,
        function(z) return z.key:sub(1, #key) == key end,
        function(z) return z.key:find(key, 1, true) ~= nil end,
    }
    for _, test in ipairs(tests) do
        local hits, names, byName = {}, {}, {}
        for _, z in ipairs(zones) do
            if test(z) and not byName[z.key] then
                byName[z.key] = z
                hits[#hits + 1] = z
                names[#names + 1] = z.name
            end
        end
        if #hits == 1 then return hits[1] end
        if #hits > 1 then
            table.sort(names)
            return nil, names
        end
    end
    return nil, {}
end

-- ---------------------------------------------------------------------------
-- /way parsing
-- ---------------------------------------------------------------------------

local USAGE = "usage: /way x y, /way x,y or /way <zone> x y (0-100, x first), /way clear"

-- Reads "x y", "x,y", "x, y" and "<zone> x y". Returns { zone = <text or nil>, x, y } with x and
-- y as 0-1, the word "clear" or "show", or nil and a reason.
local function ParseWay(msg)
    local s = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return "show" end
    if s:lower() == "clear" or s:lower() == "reset" then return "clear" end
    local tokens = {}
    for t in s:gsub(",", " "):gmatch("%S+") do tokens[#tokens + 1] = t end
    local n = #tokens
    if n < 2 then return nil, USAGE end
    local function number(t)
        if not t:match("^%d+%.?%d*$") and not t:match("^%.%d+$") then return nil end
        return tonumber(t)
    end
    local x, y = number(tokens[n - 1]), number(tokens[n])
    if not x or not y then return nil, USAGE end
    if x < 0 or x > 100 or y < 0 or y > 100 then return nil, "coordinates go from 0 to 100." end
    -- Anything before the two numbers is the zone; a number in front of them is a mistake.
    local zone = n > 2 and table.concat(tokens, " ", 1, n - 2) or nil
    if zone and number(tokens[n - 2]) and n == 3 then return nil, USAGE end
    return { zone = zone, x = x / 100, y = y / 100 }
end

local function PrintWayHelp()
    Print(USAGE)
    Print("Alt + left-click (Option on Mac) on the world map sets it too. One waypoint: a new one replaces the old.")
end

local function DoWay(msg)
    if not db then
        Print("not loaded yet.")
        return
    end
    local r, err = ParseWay(msg)
    if r == "show" then
        local wp = db.waypoint
        if wp then
            local nav = lastNav
            Print("waypoint: " .. WaypointText()
                .. (nav and nav.state == "ok" and (DOT .. YardsText(nav.dist) .. DOT .. EtaText(nav)) or ""))
        else
            Print("no waypoint.")
        end
        PrintWayHelp()
        return
    elseif r == "clear" then
        ClearWaypoint()
        return
    elseif not r then
        Print(err or USAGE)
        return
    end
    local mapID
    if r.zone then
        local z, names = FindZone(r.zone)
        if not z then
            if names and #names > 1 then
                local shown = {}
                for i = 1, math.min(#names, 8) do shown[i] = names[i] end
                Print(string.format("\"%s\" matches %d zones: %s%s. Type more of the name.", r.zone, #names,
                    table.concat(shown, ", "), #names > 8 and ", ..." or ""))
            else
                Print(string.format("no zone called \"%s\". %s", r.zone, USAGE))
            end
            return
        end
        mapID = z.mapID
    else
        mapID = MapID(Call(MapAPI("GetBestMapForUnit"), "player"))
        if not mapID then
            Print("no map for where you are; name the zone: /way <zone> x y")
            return
        end
    end
    if not SetWaypoint(mapID, r.x, r.y) then Print("that waypoint could not be set.") end
end

-- ---------------------------------------------------------------------------
-- The arrow
-- ---------------------------------------------------------------------------

local function PickArrowTexture()
    local getID = _G.GetFileIDFromPath
    if type(getID) ~= "function" then return ARROW_TEXTURES[1] end
    for _, path in ipairs(ARROW_TEXTURES) do
        if Num(Call(getID, path)) then return path end
    end
    return ARROW_TEXTURES[1]
end

local function PlaceArrow()
    if not arrowFrame or not db then return end
    local pos = db.arrowPos or DEFAULT_ARROW_POS
    arrowFrame:ClearAllPoints()
    arrowFrame:SetPoint(pos.point, _G.UIParent, pos.point, pos.x, pos.y)
end

-- The arrow's centre against UIParent's centre, saved in UIParent units.
local function SaveArrowPosition()
    local f, parent = arrowFrame, _G.UIParent
    if not f or not parent or not db then return end
    local fx, fy = Method(f, "GetCenter")
    local cx, cy = Method(parent, "GetCenter")
    fx, fy, cx, cy = Num(fx), Num(fy), Num(cx), Num(cy)
    if fx and fy and cx and cy then
        db.arrowPos = { point = "CENTER", x = math.floor(fx - cx + 0.5), y = math.floor(fy - cy + 0.5) }
    end
end

local function ShowArrowTooltip(self)
    local tip = _G.GameTooltip
    if not tip then return end
    tip:SetOwner(self, "ANCHOR_BOTTOM")
    tip:AddLine("BetterGpsForever")
    tip:AddLine(WaypointText(), 1, 1, 1)
    local nav = lastNav
    if nav and nav.state == "ok" then
        tip:AddLine(YardsText(nav.dist) .. DOT .. EtaText(nav), 1, 1, 1)
    end
    tip:AddLine(db and db.locked and "Right-click: clear waypoint" or "Drag: move" .. DOT .. "Right-click: clear waypoint",
        0.6, 0.6, 0.6)
    tip:Show()
end

local function BuildArrow()
    if arrowFrame then return arrowFrame end
    local f = CreateFrame("Button", "BetterGpsForeverArrow", _G.UIParent)
    f:SetSize(ARROW_SIZE + 40, ARROW_SIZE + 42)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:RegisterForClicks("RightButtonUp")

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(PickArrowTexture())
    tex:SetSize(ARROW_SIZE, ARROW_SIZE)
    tex:SetPoint("TOP", f, "TOP", 0, 0)
    f.arrow = tex

    local dist = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dist:SetPoint("TOP", tex, "BOTTOM", 0, 2)
    f.dist = dist

    local eta = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    eta:SetPoint("TOP", dist, "BOTTOM", 0, -1)
    f.eta = eta

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOP", eta, "BOTTOM", 0, -1)
    f.label = label

    f:SetScript("OnDragStart", function(self)
        if db and not db.locked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Ours lives in the saved variables, not in the client's layout file.
        if self.SetUserPlaced then pcall(self.SetUserPlaced, self, false) end
        SaveArrowPosition()
        PlaceArrow()
    end)
    f:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ClearWaypoint() end
    end)
    f:SetScript("OnEnter", ShowArrowTooltip)
    f:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    f:Hide()
    arrowFrame = f
    PlaceArrow()
    return f
end

local function DrawArrow(nav)
    local f = arrowFrame
    if not f then return end
    local wp = db.waypoint
    f.label:SetText(WaypointText(wp))
    f.eta:SetText(EtaText(nav))
    if nav.state == "ok" then
        f.dist:SetText(YardsText(nav.dist))
        if nav.rel and type(f.arrow.SetRotation) == "function" then
            f.arrow:SetRotation(nav.rel)
            -- Green while it points roughly ahead.
            local r = (nav.rel + math.pi) % (2 * math.pi) - math.pi
            if math.abs(r) < math.rad(15) then
                f.arrow:SetVertexColor(0.4, 1, 0.4)
            else
                f.arrow:SetVertexColor(1, 1, 1)
            end
            f.arrow:Show()
        else
            f.arrow:Hide()
        end
    elseif nav.state == "far" then
        f.arrow:Hide()
        f.dist:SetText("on another continent")
    else
        f.arrow:Hide()
        f.dist:SetText("no position here")
    end
end

-- ---------------------------------------------------------------------------
-- The minimap pin
-- ---------------------------------------------------------------------------

-- A small square marker from plain textures, which cannot go missing on a client.
local function MarkerTextures(f, size)
    local edge = f:CreateTexture(nil, "OVERLAY", nil, 1)
    edge:SetTexture(FLAT)
    edge:SetVertexColor(0, 0, 0, 0.9)
    edge:SetAllPoints(f)
    local fill = f:CreateTexture(nil, "OVERLAY", nil, 2)
    fill:SetTexture(FLAT)
    fill:SetVertexColor(1, 0.82, 0, 1)
    fill:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    local dot = f:CreateTexture(nil, "OVERLAY", nil, 3)
    dot:SetTexture(FLAT)
    dot:SetVertexColor(0.6, 0.1, 0, 1)
    dot:SetSize(math.max(2, math.floor(size / 4)), math.max(2, math.floor(size / 4)))
    dot:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.edge, f.fill, f.dot = edge, fill, dot
end

local function BuildMinimapPin()
    if minimapPin then return minimapPin end
    local mm = _G.Minimap
    if type(mm) ~= "table" then return nil end
    local p = CreateFrame("Frame", "BetterGpsForeverMinimapPin", mm)
    p:SetSize(MINIMAP_PIN_SIZE, MINIMAP_PIN_SIZE)
    p:SetFrameLevel((Num(Method(mm, "GetFrameLevel")) or 0) + 6)
    p:EnableMouse(false)
    MarkerTextures(p, MINIMAP_PIN_SIZE)
    p:Hide()
    minimapPin = p
    return p
end

local function MinimapRadius(mm)
    local r = Num(Call(API("C_Minimap", "GetViewRadius")))
    if r and r > 0 then return r end
    local zoom = Num(Method(mm, "GetZoom")) or 0
    local cvar = Num(tonumber(Call(_G.GetCVar, "minimapZoom") or ""))
    local outdoor = cvar == nil or cvar == zoom
    return (outdoor and MINIMAP_RADIUS.outdoor or MINIMAP_RADIUS.indoor)[zoom] or 150
end

local function RotatingMinimap()
    local v = Str(Call(API("C_CVar", "GetCVar"), "rotateMinimap")) or Str(Call(_G.GetCVar, "rotateMinimap"))
    return v == "1"
end

-- Offset in minimap pixels from the centre for a point `east`/`north` yards away; the second
-- return says whether it was pulled in to the edge.
local function MinimapOffset(east, north, facing, rotating, radius, half, square)
    local sx, sy = east, north
    if rotating then
        if not facing then return nil end
        local c, s = math.cos(facing), math.sin(facing)
        sx, sy = east * c + north * s, -east * s + north * c
    end
    local px, py = sx / radius * half, sy / radius * half
    local limit = half - MINIMAP_PIN_SIZE / 2
    local reach = square and math.max(math.abs(px), math.abs(py)) or math.sqrt(px * px + py * py)
    if reach > limit and reach > 0 then
        return px * limit / reach, py * limit / reach, true
    end
    return px, py, false
end

local function DrawMinimapPin(nav)
    local p, mm = minimapPin, _G.Minimap
    if not p or not mm then return end
    if nav.state ~= "ok" or not Bool(Method(mm, "IsVisible")) then
        p:Hide()
        return
    end
    local w = Num(Method(mm, "GetWidth"))
    if not w or w <= 0 then
        p:Hide()
        return
    end
    local square = Str(Call(_G.GetMinimapShape)) == "SQUARE"
    local x, y, edge = MinimapOffset(nav.east, nav.north, nav.facing, RotatingMinimap(), MinimapRadius(mm), w / 2, square)
    if not x then
        p:Hide()
        return
    end
    p:ClearAllPoints()
    p:SetPoint("CENTER", mm, "CENTER", x, y)
    p:SetAlpha(edge and 0.6 or 1)
    p:Show()
end

-- ---------------------------------------------------------------------------
-- The world map: pin and alt-click
-- ---------------------------------------------------------------------------

local function GetMap()
    local f = _G.WorldMapFrame
    if type(f) == "table" and type(f.HookScript) == "function" then return f end
end

local function Canvas()
    local map = GetMap()
    if not map then return nil end
    local c = Method(map, "GetCanvas")
    if type(c) == "table" then return c end
    local sc = map.ScrollContainer
    if type(sc) == "table" and type(sc.Child) == "table" then return sc.Child end
end

local function DisplayedMapID()
    return MapID(Method(GetMap(), "GetMapID"))
end

-- Normalised position of the cursor on the canvas, from the screen position and the canvas's own
-- effective scale and rect. That holds at any scale of the map frame and any zoom.
local function CursorMapPosition(canvas)
    local cx, cy = Call(_G.GetCursorPosition)
    cx, cy = Num(cx), Num(cy)
    local eff = Num(Method(canvas, "GetEffectiveScale"))
    local left, top = Num(Method(canvas, "GetLeft")), Num(Method(canvas, "GetTop"))
    local w, h = Num(Method(canvas, "GetWidth")), Num(Method(canvas, "GetHeight"))
    if not cx or not cy or not eff or not left or not top or not w or not h or eff <= 0 or w <= 0 or h <= 0 then
        return nil
    end
    local x, y = (cx / eff - left) / w, (top - cy / eff) / h
    if x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    return x, y
end

-- Where the waypoint is on a given map, 0-1, or nothing when that map does not hold it.
local pinCache = {} -- mapID -> { x, y } or false, for the current waypoint
local function WaypointOnMap(mapID)
    local wp = db and db.waypoint
    if not wp or not mapID then return nil end
    if mapID == wp.mapID then return wp.x, wp.y end
    local c = pinCache[mapID]
    if c == nil then
        c = false
        local cont, wx, wy = WaypointWorld()
        if cont then
            local id, pos = Call(MapAPI("GetMapPosFromWorldPos"), cont, Vec(wx, wy), mapID)
            local x, y = XY(pos)
            if MapID(id) == mapID and x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                c = { x = x, y = y }
            end
            pinCache[mapID] = c
        end
        -- Without the waypoint's world position yet, nothing is cached: asked again next time.
    end
    if c then return c.x, c.y end
end

local function BuildWorldPin(canvas)
    if worldPin then
        if worldPin:GetParent() ~= canvas then worldPin:SetParent(canvas) end
        return worldPin
    end
    local p = CreateFrame("Frame", "BetterGpsForeverWorldMapPin", canvas)
    p:SetSize(PIN_SIZE, PIN_SIZE)
    p:EnableMouse(false)
    MarkerTextures(p, PIN_SIZE)
    p:Hide()
    worldPin = p
    return p
end

local function DrawWorldPin()
    local map, canvas = GetMap(), Canvas()
    if not map or not canvas or not Bool(Method(map, "IsVisible")) then
        if worldPin then worldPin:Hide() end
        return
    end
    local x, y = WaypointOnMap(DisplayedMapID())
    if not x then
        if worldPin then worldPin:Hide() end
        return
    end
    local w, h = Num(Method(canvas, "GetWidth")), Num(Method(canvas, "GetHeight"))
    local zoom = Num(Method(canvas, "GetScale"))
    if not w or not h or not zoom or zoom <= 0 then
        if worldPin then worldPin:Hide() end
        return
    end
    local p = BuildWorldPin(canvas)
    -- The canvas zooms by its scale; the pin keeps one screen size by undoing it.
    local size = PIN_SIZE / zoom
    p:SetSize(size, size)
    p:SetFrameLevel((Num(Method(canvas, "GetFrameLevel")) or 0) + 500)
    p:ClearAllPoints()
    p:SetPoint("CENTER", canvas, "TOPLEFT", x * w, -y * h)
    p:Show()
end

-- Alt + left button: the point is taken at mouse down, on the map shown then (Blizzard may
-- change maps on the way up), and set at mouse up if the cursor has not moved, i.e. a click and
-- not a drag.
local pendingClick
local function OnMapMouseDown(_, button)
    pendingClick = nil
    if button ~= "LeftButton" or not Bool(Call(_G.IsAltKeyDown)) then return end
    local canvas, mapID = Canvas(), DisplayedMapID()
    if not canvas or not mapID then return end
    local x, y = CursorMapPosition(canvas)
    local cx, cy = Call(_G.GetCursorPosition)
    if x and Num(cx) and Num(cy) then
        pendingClick = { mapID = mapID, x = x, y = y, cx = cx, cy = cy }
    end
end

local function OnMapMouseUp(_, button)
    local c = pendingClick
    pendingClick = nil
    if not c or button ~= "LeftButton" then return end
    local cx, cy = Call(_G.GetCursorPosition)
    cx, cy = Num(cx), Num(cy)
    if not cx or math.abs(cx - c.cx) > CLICK_SLOP or math.abs(cy - c.cy) > CLICK_SLOP then return end
    SetWaypoint(c.mapID, c.x, c.y)
end

local mapAcc = 0
local function MapTick(_, elapsed)
    mapAcc = mapAcc + (elapsed or 0)
    if mapAcc < MAP_TICK then return end
    mapAcc = 0
    Safe("worldPin", DrawWorldPin)
end

local function HookMap()
    if mapHooked then return true end
    local map = GetMap()
    if not map then return false end
    mapHooked = true
    local sc = map.ScrollContainer
    if type(sc) == "table" and type(sc.HookScript) == "function" then
        sc:HookScript("OnMouseDown", function(self, button) Safe("click", OnMapMouseDown, self, button) end)
        sc:HookScript("OnMouseUp", function(self, button) Safe("click", OnMapMouseUp, self, button) end)
    end
    if type(map.OnMapChanged) == "function" then
        hooksecurefunc(map, "OnMapChanged", function() Safe("worldPin", DrawWorldPin) end)
    end
    -- Our own frame inside the map: it only runs while the map is open.
    mapDriver = CreateFrame("Frame", nil, map)
    mapDriver:SetScript("OnUpdate", MapTick)
    mapDriver:SetScript("OnShow", function() mapAcc = MAP_TICK end)
    return true
end

-- ---------------------------------------------------------------------------
-- The ticker: arrow, minimap pin, arrival
-- ---------------------------------------------------------------------------

local ticker = CreateFrame("Frame")
local acc = 0

local function Step()
    if not db or not db.waypoint then return end
    local nav = Safe("nav", Navigate)
    if not nav then
        lastNav = nil
        return
    end
    if nav.state == "ok" then
        AddSample(clock, nav.dist)
        nav.eta = Eta()
    else
        ResetEta()
    end
    lastNav = nav
    -- The corpse waypoint stays until resurrection; it is cleared (and the old one restored) then.
    if nav.state == "ok" and nav.dist <= ARRIVAL_YARDS and not db.waypoint.corpse then
        ClearWaypoint("arrived")
        return
    end
    if arrowFrame and arrowFrame:IsShown() then Safe("nav", DrawArrow, nav) end
    Safe("minimapPin", DrawMinimapPin, nav)
end

local function Tick(_, elapsed)
    elapsed = Num(elapsed) or 0
    clock = clock + elapsed
    acc = acc + elapsed
    if acc < TICK then return end
    acc = 0
    Step()
end

local function ApplyArrowVisibility()
    if not arrowFrame then return end
    local on = db and db.arrow and db.waypoint and not broken.nav
    arrowFrame:SetShown(on and true or false)
end

UpdateNow = function()
    pinCache = {}
    if db and db.waypoint then
        BuildArrow()
        BuildMinimapPin()
        ApplyArrowVisibility()
        ticker:SetScript("OnUpdate", Tick)
        acc = TICK
        Step()
    else
        ticker:SetScript("OnUpdate", nil)
        if arrowFrame then arrowFrame:Hide() end
        if minimapPin then minimapPin:Hide() end
    end
    Safe("worldPin", DrawWorldPin)
end

OnFeatureBroken = function(feature)
    if feature == "nav" then
        if arrowFrame then arrowFrame:Hide() end
        if minimapPin then minimapPin:Hide() end
    elseif feature == "minimapPin" then
        if minimapPin then minimapPin:Hide() end
    elseif feature == "worldPin" then
        if worldPin then worldPin:Hide() end
    end
end

-- ---------------------------------------------------------------------------
-- Corpse route
--
-- While the player is a ghost (released), the waypoint is the corpse. It replaces the waypoint
-- the player had, which is kept in db.corpseRun.prev and brought back at resurrection. The rule
-- for a waypoint set while dead: it replaces the corpse route (run.done) and is the one kept
-- after resurrection; the corpse route is not put back until the next death. Clearing the corpse
-- waypoint (right-click, /way clear) also ends the route, and the previous waypoint comes back
-- at once (see ClearWaypoint). db.corpseRun is saved, so a /reload while dead keeps all of this.
-- ---------------------------------------------------------------------------

local corpseDriver = CreateFrame("Frame")
local corpseAcc = 0

-- One of UnitIsGhost / UnitIsDeadOrGhost for the player: true, false, or nil when the client has
-- no such function, it errors, or the answer is secret.
local function PlayerFlag(fn)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, "player")
    if not ok then return nil end
    return Bool(v)
end

-- "ghost", "dead" (not released yet), "alive", or nil when the client gives no clear answer.
local function PlayerState()
    local ghost = PlayerFlag(_G.UnitIsGhost)
    if ghost == nil then return nil end
    if ghost then return "ghost" end
    local dead = PlayerFlag(_G.UnitIsDeadOrGhost)
    if dead == nil then return nil end
    return dead and "dead" or "alive"
end

-- The player's map and its parents, most detailed first.
local function PlayerMapChain()
    local list, seen = {}, {}
    local m = MapID(Call(MapAPI("GetBestMapForUnit"), "player"))
    for _ = 1, 12 do
        if not m or seen[m] then break end
        seen[m] = true
        list[#list + 1] = m
        local info = MapInfo(m)
        m = info and MapID(info.parentMapID)
    end
    return list
end

local function CorpseOn(mapID)
    local x, y = XY(Call(API("C_DeathInfo", "GetCorpseMapPosition"), mapID))
    if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 and not (x == 0 and y == 0) then return x, y end
end

-- The corpse as mapID, x, y (0-1): on the player's map, or else on the first parent map that
-- holds it, narrowed to the zone it lies in where the client says which one that is.
local function CorpsePosition()
    if not API("C_DeathInfo", "GetCorpseMapPosition") then return nil end
    for i, m in ipairs(PlayerMapChain()) do
        local x, y = CorpseOn(m)
        if x then
            if i > 1 then
                local info = Call(MapAPI("GetMapInfoAtPosition"), m, x, y)
                local zone = not IsSecret(info) and type(info) == "table" and MapID(info.mapID) or nil
                if zone and zone ~= m then
                    local zx, zy = CorpseOn(zone)
                    if zx then return zone, zx, zy end
                end
            end
            return m, x, y
        end
    end
end

local function CopyWaypoint(wp)
    if type(wp) ~= "table" then return nil end
    return { mapID = wp.mapID, x = wp.x, y = wp.y, label = wp.label }
end

-- Ghost: start the route, or move its waypoint when the corpse is now read on another map.
local function RouteToCorpse()
    local run = db.corpseRun
    if run and run.done then return end
    local mapID, x, y = CorpsePosition()
    if not mapID then return end -- not known here yet; asked again on the next poll or event
    local cur = db.waypoint
    if not run then
        run = { prev = (cur and not cur.corpse) and CopyWaypoint(cur) or nil, done = false }
        db.corpseRun = run
    end
    if cur and cur.corpse and cur.mapID == mapID and math.abs(cur.x - x) < 0.0005 and math.abs(cur.y - y) < 0.0005 then
        return
    end
    local first = not (cur and cur.corpse)
    SetWaypoint(mapID, x, y, { title = CORPSE_TITLE, corpse = true, quiet = true })
    if first then
        Print("waypoint set to your corpse"
            .. (run.prev and (": " .. WaypointText(run.prev) .. " comes back after resurrection.") or "."))
    end
end

-- Resurrected, or the setting was switched off: the corpse waypoint goes and the one from before
-- comes back. Nothing is restored when the player set or cleared a waypoint while dead (done).
local function EndCorpseRun()
    local run = db.corpseRun
    if not run then return end
    db.corpseRun = nil
    if run.done then return end
    local cur = db.waypoint
    if cur and cur.corpse then ClearWaypoint("silent") end
    if not RestoreWaypoint(run.prev) and cur and cur.corpse then
        Print("corpse waypoint cleared.")
    end
end

local function CorpseCheck()
    if not db then return "stop" end
    local state = PlayerState()
    if state == nil then return "poll" end
    if state == "alive" then
        EndCorpseRun()
        -- A corpse waypoint with no route behind it (an old save) has nothing left to show.
        if db.waypoint and db.waypoint.corpse then ClearWaypoint("silent") end
        return "stop"
    end
    if state == "ghost" and db.corpse then RouteToCorpse() end
    return "poll"
end

local function CorpsePoll(_, elapsed)
    corpseAcc = corpseAcc + (Num(elapsed) or 0)
    if corpseAcc < CORPSE_POLL then return end
    corpseAcc = 0
    local r = Safe("corpse", CorpseCheck)
    if r ~= "poll" then corpseDriver:SetScript("OnUpdate", nil) end
end

-- Runs on the death events and on every map change: checks at once, then every CORPSE_POLL
-- seconds while the player is dead or a ghost (the corpse may only be known a moment later).
local function UpdateCorpse()
    if not db then return end
    if Safe("corpse", CorpseCheck) == "poll" then
        corpseAcc = 0
        corpseDriver:SetScript("OnUpdate", CorpsePoll)
    else
        corpseDriver:SetScript("OnUpdate", nil)
    end
end

-- ---------------------------------------------------------------------------
-- Settings, shared by the slash command and the menu entries of the API
-- ---------------------------------------------------------------------------

local function SetArrowShown(on)
    if not db then return end
    db.arrow = on and true or false
    if db.arrow and db.waypoint then BuildArrow() end
    ApplyArrowVisibility()
    Print("arrow " .. OnOff(db.arrow) .. ".")
end

local function SetLocked(on)
    if not db then return end
    db.locked = on and true or false
    if db.locked and arrowFrame then arrowFrame:StopMovingOrSizing() end
    Print(db.locked and "arrow locked." or "arrow unlocked: drag it to move it.")
end

local function SetCorpse(on)
    if not db then return end
    db.corpse = on and true or false
    if db.corpse then
        UpdateCorpse()
    elseif db.corpseRun then
        Safe("corpse", EndCorpseRun)
    end
    Print("route to your corpse when dead " .. OnOff(db.corpse) .. ".")
end

local function ResetArrow()
    if not db then return end
    db.arrowPos = nil
    PlaceArrow()
    Print("arrow moved back to its default place.")
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

local function Yes(v) return v and "yes" or "MISSING" end

local function WayCommandText()
    if wayRegistered then return "/way" end
    return "/bgps way"
end

local function PrintHelp()
    Print("version " .. VERSION .. ": one waypoint with an arrow and map pins.")
    Print(WayCommandText() .. " x y | " .. WayCommandText() .. " <zone> x y | " .. WayCommandText()
        .. " clear - set or clear the waypoint (0-100, x first); Alt + left-click (Option on Mac) on the world map sets it too")
    Print("/bgps arrow on | /bgps arrow off - show the arrow (now: " .. OnOff(db and db.arrow) .. ")")
    Print("/bgps lock | /bgps unlock - stop or allow dragging the arrow (now: "
        .. ((db and db.locked) and "locked" or "unlocked") .. "); /bgps reset - arrow back to its default place")
    Print("/bgps corpse on | /bgps corpse off - waypoint to your corpse while you are a ghost, the old one back after"
        .. " resurrection (now: " .. OnOff(db and db.corpse) .. ")")
    Print("/bgps clear - clear the waypoint (or right-click the arrow); /bgps status - what this client offers")
    if wayOwner then Print("/way belongs to " .. wayOwner .. ", so use /bgps way x y here.") end
end

local function PrintStatus()
    Print("version " .. VERSION)
    Print("waypoint: " .. WaypointText()
        .. ((lastNav and lastNav.state == "ok") and (DOT .. YardsText(lastNav.dist) .. DOT .. EtaText(lastNav)) or "")
        .. ((lastNav and lastNav.state == "far") and (DOT .. "on another continent") or "")
        .. ((lastNav and lastNav.state == "nopos") and (DOT .. "no position here") or ""))
    Print("arrow: " .. OnOff(db and db.arrow) .. ", " .. ((db and db.locked) and "locked" or "unlocked")
        .. ", " .. (db and db.arrowPos and "moved" or "default place"))
    local run = db and db.corpseRun
    local corpse = OnOff(db and db.corpse)
    if run and run.done then
        corpse = corpse .. " - dead, your own waypoint is kept after resurrection"
    elseif run then
        corpse = corpse .. " - routing to your corpse; after resurrection: "
            .. (run.prev and WaypointText(run.prev) or "no waypoint")
    end
    Print("corpse route: " .. corpse .. "   C_DeathInfo.GetCorpseMapPosition: "
        .. Yes(API("C_DeathInfo", "GetCorpseMapPosition")) .. "   UnitIsGhost: "
        .. Yes(type(_G.UnitIsGhost) == "function"))
    Print("/way: " .. (wayRegistered and "ours" or ("not ours (" .. (wayOwner or "not registered yet") .. "); use /bgps way")))
    Print("GetWorldPosFromMapPos: " .. Yes(MapAPI("GetWorldPosFromMapPos"))
        .. "   GetMapPosFromWorldPos: " .. Yes(MapAPI("GetMapPosFromWorldPos"))
        .. "   GetPlayerFacing: " .. Yes(type(_G.GetPlayerFacing) == "function"))
    Print("user waypoint: " .. Yes(MapAPI("SetUserWaypoint"))
        .. "   super track: " .. Yes(API("C_SuperTrack", "SetSuperTrackedUserWaypoint"))
        .. "   minimap radius: " .. (API("C_Minimap", "GetViewRadius") and "C_Minimap" or "zoom table")
        .. "   world map: " .. Yes(Canvas()))
    local off = {}
    for k in pairs(broken) do off[#off + 1] = FEATURE_TEXT[k] or k end
    if #off > 0 then
        table.sort(off)
        Print("switched off after an error: " .. table.concat(off, ", "))
    end
end

local function OnSlash(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = msg:lower():gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    if lower == "way" or lower:sub(1, 4) == "way " then
        DoWay(msg:sub(4))
    elseif lower == "status" then
        PrintStatus()
    elseif lower == "arrow on" or lower == "arrow off" then
        SetArrowShown(lower == "arrow on")
    elseif lower == "arrow" then
        SetArrowShown(not db.arrow)
    elseif lower == "lock" then
        SetLocked(true)
    elseif lower == "unlock" then
        SetLocked(false)
    elseif lower == "reset" then
        ResetArrow()
    elseif lower == "clear" then
        ClearWaypoint()
    elseif lower == "corpse on" or lower == "corpse off" then
        SetCorpse(lower == "corpse on")
    elseif lower == "corpse" then
        SetCorpse(not db.corpse)
    else
        PrintHelp()
    end
end

-- Whether some other addon already answers /way: TomTom by name, or any registered command.
local function FindWayOwner()
    if AddOnLoaded("TomTom") then return "TomTom" end
    local list = _G.SlashCmdList
    if type(list) ~= "table" then return nil end
    for key in pairs(list) do
        if type(key) == "string" and key ~= "BETTERGPSFOREVERWAY" then
            for i = 1, 9 do
                local s = _G["SLASH_" .. key .. i]
                if s == nil then break end
                if type(s) == "string" and s:lower() == "/way" then return "another addon (" .. key .. ")" end
            end
        end
    end
    return nil
end

local function RegisterWay()
    wayOwner = FindWayOwner()
    if wayOwner then
        wayRegistered = false
        Print(wayOwner .. " is loaded and owns /way, so BetterGpsForever leaves it alone. Use |cffffd100/bgps way x y|r instead.")
        return
    end
    _G.SLASH_BETTERGPSFOREVERWAY1 = "/way"
    _G.SlashCmdList.BETTERGPSFOREVERWAY = DoWay
    wayRegistered = true
end

-- ---------------------------------------------------------------------------
-- Public API: BetterGpsForeverAPI
--
-- For BetterGaarForever, the optional hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterGpsForeverDB and change only through the same
-- functions /bgps uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "The Barrens 45.2, 63.1 · 312 yd · 1:24" or "no waypoint"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func }, { label }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
--   SetWaypoint(uiMapID, x, y [, title])  sets the one waypoint (x, y 0-1), shown as title instead
--                        of the zone name; true when it was set. Same as /way, so it replaces the
--                        waypoint there was, and while dead it replaces the corpse route.
--   ClearWaypoint()      clears the waypoint, as /way clear does
--   GetWaypoint()        uiMapID, x, y, title of the waypoint, or nil when there is none
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    if not db.waypoint then
        return "no waypoint" .. (wayOwner and (DOT .. "/bgps way") or "")
    end
    local line = WaypointText()
    local nav = lastNav
    if nav and nav.state == "ok" then
        line = line .. DOT .. YardsText(nav.dist) .. DOT .. EtaText(nav)
    elseif nav and nav.state == "far" then
        line = line .. DOT .. "other continent"
    end
    return line
end

local function MenuEntries()
    if not db then return {} end
    local entries = {
        { text = "Show arrow", checkbox = true, checked = function() return db.arrow end,
          func = function() SetArrowShown(not db.arrow) end },
        { text = "Lock arrow", checkbox = true, checked = function() return db.locked end,
          func = function() SetLocked(not db.locked) end },
        { text = "Reset arrow position", func = ResetArrow },
        { text = "Route to corpse when dead", checkbox = true, checked = function() return db.corpse end,
          func = function() SetCorpse(not db.corpse) end },
    }
    if db.waypoint then
        entries[#entries + 1] = { text = "Clear waypoint", func = function() ClearWaypoint() end }
    else
        entries[#entries + 1] = { label = "Clear waypoint (none set)" }
    end
    return entries
end

-- Draws the entries into a MenuUtil description (root or submenu); every method is checked first.
local function RenderMenu(root, entries)
    if type(root) ~= "table" or type(root.CreateButton) ~= "function" then return end
    for _, e in ipairs(entries) do
        if e.label then
            local d = root:CreateButton("|cff808080" .. e.label .. "|r")
            if type(d) == "table" and type(d.SetEnabled) == "function" then pcall(d.SetEnabled, d, false) end
        elseif e.checkbox and type(root.CreateCheckbox) == "function" then
            root:CreateCheckbox(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox then
            root:CreateButton((e.checked() and "[x] " or "[ ] ") .. e.text, function() e.func() end)
        else
            root:CreateButton(e.text, function() e.func() end)
        end
    end
end

-- A title from another addon: one line, no escape sequences, at most TITLE_MAX characters.
local function CleanTitle(title)
    title = Str(title)
    if not title then return nil end
    title = title:gsub("|", "/"):gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then return nil end
    if #title > TITLE_MAX then title = title:sub(1, TITLE_MAX) end
    return title
end

_G.BetterGpsForeverAPI = {
    version = VERSION,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) RenderMenu(root, MenuEntries()) end,
    SetMinimapHidden = function() end,
    SetWaypoint = function(mapID, x, y, title)
        return SetWaypoint(mapID, x, y, { title = CleanTitle(title) }) and true or false
    end,
    ClearWaypoint = function() ClearWaypoint() end,
    GetWaypoint = function()
        local wp = db and db.waypoint
        if not wp then return nil end
        return wp.mapID, wp.x, wp.y, wp.label
    end,
}

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function ValidWaypoint(wp)
    if type(wp) ~= "table" then return nil end
    local id, x, y = MapID(wp.mapID), Num(wp.x), Num(wp.y)
    if not id or not x or not y or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    return { mapID = id, x = x, y = y, label = type(wp.label) == "string" and wp.label or nil,
        corpse = wp.corpse == true or nil }
end

local function ValidCorpseRun(run)
    if type(run) ~= "table" then return nil end
    local prev = ValidWaypoint(run.prev)
    if prev then prev.corpse = nil end
    return { prev = prev, done = run.done == true }
end

local function BindSavedVariables()
    if type(_G.BetterGpsForeverDB) ~= "table" then _G.BetterGpsForeverDB = {} end
    db = _G.BetterGpsForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    if type(db.arrow) ~= "boolean" then db.arrow = true end
    if type(db.locked) ~= "boolean" then db.locked = false end
    if type(db.corpse) ~= "boolean" then db.corpse = DEFAULTS.corpse end
    db.waypoint = ValidWaypoint(db.waypoint)
    db.corpseRun = ValidCorpseRun(db.corpseRun)
    local pos = db.arrowPos
    if pos ~= nil and (type(pos) ~= "table" or type(pos.point) ~= "string" or not Num(pos.x) or not Num(pos.y)) then
        db.arrowPos = nil
    end
end

local function Start()
    if started or not db then return end
    started = true
    RegisterWay()
    HookMap()
    UpdateNow()
    UpdateCorpse()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
-- RegisterEvent raises on an event the client does not know, so these are tried one by one.
local CORPSE_EVENTS = { PLAYER_DEAD = true, PLAYER_ALIVE = true, PLAYER_UNGHOST = true,
    ZONE_CHANGED_NEW_AREA = true, ZONE_CHANGED = true, ZONE_CHANGED_INDOORS = true }
for event in pairs(CORPSE_EVENTS) do pcall(events.RegisterEvent, events, event) end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            BindSavedVariables()
            HookMap()
            -- Loaded after login (LoadAddOn): no PLAYER_LOGIN is coming, so start now.
            if type(_G.IsLoggedIn) == "function" and Bool(Call(_G.IsLoggedIn)) then Start() end
        elseif db and not mapHooked then
            -- In case the map arrives with a Blizzard addon loaded after us.
            HookMap()
        end
    elseif event == "PLAYER_LOGIN" then
        Start()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- A new zone or continent: world positions are worked out again.
        worldCache = nil
        pinCache = {}
        if started then
            UpdateNow()
            UpdateCorpse()
        end
    elseif CORPSE_EVENTS[event] then
        -- Death, release, resurrection, or a new map while dead: the corpse is read again.
        if started then UpdateCorpse() end
    end
end)

SLASH_BETTERGPSFOREVER1 = "/bgps"
SLASH_BETTERGPSFOREVER2 = "/bettergpsforever"
SlashCmdList.BETTERGPSFOREVER = OnSlash
