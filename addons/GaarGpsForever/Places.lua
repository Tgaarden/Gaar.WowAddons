--[[
  GaarGpsForever - Places.lua (1.5): every graveyard and flight path on the world map and the zone map.

    * Graveyards (spirit healers) and flight paths (flight masters) are drawn as small icons on the map
      WorldMapFrame shows, whether or not you have found them. Two sources, merged per map:
        - the client, when it has the API: C_TaxiMap.GetTaxiNodesForMap(uiMapID) and
          C_DeathInfo.GetGraveyardsForMap(uiMapID), read through pcall with every value checked for
          secrecy;
        - the static tables in Data/FlightPaths.lua and Data/Graveyards.lua (built from the WoW
          Forever client's own TaxiNodes and map tables, see their headers).
      A client node is the same as a table row when its node ID matches, or its name matches and it
      is near; a client graveyard when it is within 2 % of the map of a table graveyard. What the
      client lists that the table lacks is added; nothing is drawn twice. /ggps status says, for the
      map you look at, whether the client API is there and how many places each source gave.
    * Flight paths: your own faction's and the neutral ones only. A flight path you have learned is
      green, one you have not is grey and faded. The tooltip says the name, the zone and "Learned" or
      "Not learned". On a continent map flight paths are shown too (placed through the world
      position, as the waypoint pin is); graveyards only on a zone map.
    * Learned: whenever a flight master's map opens (TAXIMAP_OPENED) the nodes the client lists are
      read (C_TaxiMap.GetAllTaxiNodes / GetTaxiNodesForMap, or the old NumTaxiNodes / TaxiNodeName)
      and matched to the table by node ID or name; a node C_TaxiMap.GetTaxiNodesForMap reports as
      discovered (isUndiscovered == false) counts as learned too. Saved per character in
      GaarGpsForeverDB.placesLearned.
    * Not on the minimap. Nothing here is clickable beyond its tooltip.

  The pins are plain frames on the world map canvas, like the waypoint pin of the core: nothing of
  Blizzard's map is replaced, no secure frame is touched, and every client value is checked for
  secrecy before use. Draw runs inside the core's Safe, so an error switches it off for the session.
]]

local _G = _G
local _, ns = ...
ns = type(ns) == "table" and ns or {}
local places = {}
ns.places = places

local BF = _G.GaarForever
local Num, Bool, Call, Method, API, OnOff = BF.Num, BF.Bool, BF.Call, BF.Method, BF.API, BF.OnOff
local Str = BF.Str

local PIN_SIZE = 14           -- screen units at any zoom
local PIN_LEVEL = 490         -- above the canvas; the waypoint pin of the core is at 500
local MAPTYPE_CONTINENT = 2   -- Enum.UIMapType.Continent
local FLIGHT_ICON = "Interface\\Minimap\\Tracking\\FlightMaster"
local GRAVE_ATLAS = "poi-graveyard-neutral"
local GRAVE_ICON = "Interface\\Icons\\Spell_Shadow_DeathCoil"
local NEAR_FLIGHT = 0.05      -- a client node with a table row's name within 5 % of the map is that row
local NEAR_GRAVE = 0.02       -- a client graveyard within 2 % of the map of a table graveyard is that one
local REFRESH = 20            -- seconds before the client part of a map is read again

local db, core
local started
local pins = {}               -- pool of pin frames
local lastSig
local posCache = {}           -- mapID -> { flights = { {e, x, y} }, graves = { {x, y, name} }, n, gen, t }
local gen = 0
local rev = 0                 -- bumped when what is shown could change (toggles, learned)
local stats = { scans = 0, nodes = 0, matched = 0, unmatched = 0 }
local lastUnmatched = {}

local function Print(msg) if core then core.Print(msg) end end
local function Now() return Num(Call(_G.GetTime)) or 0 end

-- ---------------------------------------------------------------------------
-- Pure helpers (tested)
-- ---------------------------------------------------------------------------

-- "Light's Hope Chapel, Eastern Plaguelands" -> "lightshopechapel": the part before the first comma,
-- letters and digits only, lower case.
local function Norm(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub(",.*$", ""):lower():gsub("[^%w]", "")
    if name == "" then return nil end
    return name
end

local byNorm, byNode
local function EntriesByNorm()
    if byNorm then return byNorm end
    byNorm, byNode = {}, {}
    for _, e in ipairs(ns.flightPaths or {}) do
        local n = Norm(e.name)
        if n then
            byNorm[n] = byNorm[n] or {}
            table.insert(byNorm[n], e)
        end
        if type(e.node) == "number" then byNode[e.node] = e end
    end
    return byNorm
end
local function EntryByNode(id)
    EntriesByNorm()
    return id and byNode[id] or nil
end

-- The static flight paths a client node name stands for: an exact normalised match, else one whose
-- name starts with the other (the client says "Theramore", an older table "Theramore Isle").
local function MatchName(name)
    local n = Norm(name)
    if not n then return nil end
    local map = EntriesByNorm()
    if map[n] then return map[n] end
    local found
    for k, list in pairs(map) do
        if #n >= 5 and (k:sub(1, #n) == n or n:sub(1, #k) == k) then
            if found then return nil end -- ambiguous
            found = list
        end
    end
    return found
end

-- Whether a flight path is shown to a player of this faction: its own and the neutral ones. A
-- player without a faction (neutral) sees the neutral ones only.
local function FactionShows(entryFaction, playerFaction)
    if entryFaction == "Neutral" then return true end
    return entryFaction == playerFaction
end

local function Key(e) return (Norm(e.name) or "?") .. ":" .. tostring(e.map) end

-- Learned keys of 1.5.0, whose table rows had other names than the client's nodes.
local LEGACY = {
    ["thecrossroads:1413"] = "crossroads:1413", ["theramoreisle:1445"] = "theramore:1445",
    ["feathermoonstronghold:1444"] = "feathermoon:1444", ["stormwindcity:1453"] = "stormwind:1453",
    ["gromgolbasecamp:1434"] = "gromgol:1434", ["nighthaven:1450"] = "moonglade:1450",
}

-- The icon look of a pin: desaturated, r, g, b, alpha. Learned flight paths green, unlearned grey.
local function PinStyle(d)
    if d.kind == "flight" then
        if d.learned then return true, 0.3, 1, 0.3, 1 end
        return true, 1, 1, 1, 0.55
    end
    return false, 1, 1, 1, 1
end

local function Dist(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

-- The client's flight nodes merged into the table's on one map. static: { {e, x, y} }; runtime:
-- { {id, name, x, y, faction, known} }. Returns the merged list (the static ones, then the client
-- nodes the table lacks as rows of their own) and the pairs { p = merged row, r = client node }.
local function MergeFlights(static, runtime, mapID, zoneName)
    local out, hits = {}, {}
    for _, p in ipairs(static) do out[#out + 1] = p end
    for _, r in ipairs(runtime or {}) do
        local hit
        if r.id then
            for _, p in ipairs(static) do
                if p.e.node == r.id then hit = p; break end
            end
        end
        if not hit then
            local n, best = Norm(r.name), NEAR_FLIGHT
            for _, p in ipairs(static) do
                local d = Dist(p.x, p.y, r.x, r.y)
                if n and Norm(p.e.name) == n and d <= best and (not r.faction or r.faction == "Neutral"
                    or p.e.faction == "Neutral" or p.e.faction == r.faction) then
                    hit, best = p, d
                end
            end
        end
        if not hit then
            -- the same client node listed twice
            for i = #static + 1, #out do
                if out[i].e.node and out[i].e.node == r.id then hit = out[i]; break end
            end
        end
        if hit then
            hits[#hits + 1] = { p = hit, r = r }
        else
            local e = { name = (r.name:gsub(",.*$", "")), zone = zoneName or "", map = mapID, x = r.x, y = r.y,
                faction = r.faction or "Neutral", node = r.id, runtime = true }
            out[#out + 1] = { e = e, x = r.x, y = r.y }
            hits[#hits + 1] = { p = out[#out], r = r }
        end
    end
    return out, hits
end

-- The client's graveyards merged into the table's: static { {x, y, name} }, runtime { {x, y, name} }.
-- Returns the merged list and how many the client added.
local function MergeGraves(static, runtime)
    local out = {}
    for _, g in ipairs(static) do out[#out + 1] = { x = g.x, y = g.y, name = g.name } end
    local nStatic = #out
    for _, r in ipairs(runtime or {}) do
        local hit
        for i = 1, #out do
            local g = out[i]
            if Dist(g.x, g.y, r.x, r.y) <= NEAR_GRAVE then hit = g; break end
        end
        if hit then
            if not hit.name then hit.name = r.name end
        else
            out[#out + 1] = { x = r.x, y = r.y, name = r.name, runtime = true }
        end
    end
    return out, #out - nStatic
end

places.pure = { Norm = Norm, MatchName = MatchName, FactionShows = FactionShows, PinStyle = PinStyle,
    MergeFlights = MergeFlights, MergeGraves = MergeGraves }

-- ---------------------------------------------------------------------------
-- Learned flight paths, saved per character
-- ---------------------------------------------------------------------------

local function CharKey()
    local n = Call(BF.PlayerFullName)
    if type(n) ~= "string" or n == "" then n = Str(Call(_G.UnitName, "player")) end
    local realm = Str(Call(_G.GetRealmName))
    if not n then return nil end
    return n .. "-" .. (realm or "")
end

local function Learned()
    if not db then return {} end
    local key = CharKey()
    if not key then return {} end
    if type(db.placesLearned) ~= "table" then db.placesLearned = {} end
    if type(db.placesLearned[key]) ~= "table" then db.placesLearned[key] = {} end
    local set = db.placesLearned[key]
    for old, new in pairs(LEGACY) do
        if set[old] then set[new] = true; set[old] = nil end
    end
    return set
end

local function IsLearned(e)
    return Learned()[Key(e)] == true
end

-- Marks one flight path learned; true when it was new.
local function MarkLearned(e)
    local set = Learned()
    local k = Key(e)
    if set[k] then return false end
    set[k] = true
    rev = rev + 1
    return true
end

local function PlayerFaction()
    local f = Call(_G.UnitFactionGroup, "player")
    if type(f) == "string" and (f == "Alliance" or f == "Horde") then return f end
    return nil
end

-- Marks the static flight paths matching these client nodes as learned; returns how many were new.
-- names: node names; ids (optional): the node IDs of the same nodes, matched first.
local function Record(names, ids)
    local set, new = Learned(), 0
    stats.nodes = stats.nodes + #names
    lastUnmatched = {}
    for i, nm in ipairs(names) do
        local list
        local byId = EntryByNode(ids and ids[i])
        if byId then list = MatchName(byId.name) or { byId } else list = MatchName(nm) end
        if list then
            for _, e in ipairs(list) do
                local k = Key(e)
                if not set[k] then set[k] = true; new = new + 1 end
            end
            stats.matched = stats.matched + 1
        else
            stats.unmatched = stats.unmatched + 1
            lastUnmatched[#lastUnmatched + 1] = nm
        end
    end
    if new > 0 then rev = rev + 1 end
    return new
end
places.pure.Record = Record
places.pure.IsLearned = IsLearned

local function NodesFromTaxiMap()
    local names, ids = {}, {}
    local get = API("C_TaxiMap", "GetAllTaxiNodes") or API("C_TaxiMap", "GetTaxiNodesForMap")
    if not get then return nil end
    local seen = {}
    local maps = {}
    local f = _G.FlightMapFrame
    if type(f) == "table" then maps[#maps + 1] = Num(Method(f, "GetMapID")) end
    for _, c in ipairs({ 1414, 1415 }) do maps[#maps + 1] = c end
    local best = Num(Call(API("C_Map", "GetBestMapForUnit"), "player"))
    maps[#maps + 1] = best
    for _, id in ipairs(maps) do
        if not seen[id] then
            seen[id] = true
            local list = Call(get, id)
            if not BF.IsSecret(list) and type(list) == "table" then
                for _, info in ipairs(list) do
                    if not BF.IsSecret(info) and type(info) == "table" then
                        local nm = Str(info.name)
                        if nm then names[#names + 1] = nm; ids[#names] = Num(info.nodeID) or false end
                    end
                end
            end
        end
    end
    return names, ids
end

local function NodeNamesLegacy()
    if type(_G.NumTaxiNodes) ~= "function" or type(_G.TaxiNodeName) ~= "function" then return nil end
    local n = Num(Call(_G.NumTaxiNodes))
    if not n then return nil end
    local names = {}
    for i = 1, n do
        local kind = Str(Call(_G.TaxiNodeGetType, i))
        local nm = Str(Call(_G.TaxiNodeName, i))
        if nm and kind ~= "NONE" then names[#names + 1] = nm end
    end
    return names
end

local function ScanTaxi()
    stats.scans = stats.scans + 1
    local names, ids = NodesFromTaxiMap()
    if not names or #names == 0 then names, ids = NodeNamesLegacy() or names or {}, nil end
    Record(names, ids)
end

places.pure.Scan = ScanTaxi

-- ---------------------------------------------------------------------------
-- The client's own places (runtime), when it has the API
-- ---------------------------------------------------------------------------

local function RuntimeFaction(v)
    v = Num(v)
    if not v then return nil end
    local E = _G.Enum and _G.Enum.FlightPathFaction
    local neutral = E and Num(E.Neutral) or 0
    local horde = E and Num(E.Horde) or 1
    local alliance = E and Num(E.Alliance) or 2
    if v == horde then return "Horde" elseif v == alliance then return "Alliance" elseif v == neutral then return "Neutral" end
    return nil
end

-- C_TaxiMap.GetTaxiNodesForMap: { {id, name, x, y, faction, known} }, or nil without the API.
local function RuntimeFlights(mapID)
    local get = API("C_TaxiMap", "GetTaxiNodesForMap")
    if not get then return nil end
    local out = {}
    local list = Call(get, mapID)
    if BF.IsSecret(list) or type(list) ~= "table" then return out end
    for _, info in ipairs(list) do
        if not BF.IsSecret(info) and type(info) == "table" then
            local nm = Str(info.name)
            local x, y = core.XY(info.position)
            local layer = info.isMapLayerTransition
            local skip = not BF.IsSecret(layer) and layer == true
            if nm and x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 and not skip then
                local und, known = info.isUndiscovered, nil
                if not BF.IsSecret(und) and type(und) == "boolean" then known = not und end
                out[#out + 1] = { id = Num(info.nodeID), name = nm, x = x, y = y,
                    faction = RuntimeFaction(info.faction), known = known }
            end
        end
    end
    return out
end

-- C_DeathInfo.GetGraveyardsForMap: { {x, y, name} }, or nil without the API.
local function RuntimeGraves(mapID)
    local get = API("C_DeathInfo", "GetGraveyardsForMap")
    if not get then return nil end
    local out = {}
    local list = Call(get, mapID)
    if BF.IsSecret(list) or type(list) ~= "table" then return out end
    for _, info in ipairs(list) do
        if not BF.IsSecret(info) and type(info) == "table" then
            local x, y = core.XY(info.position)
            if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                out[#out + 1] = { x = x, y = y, name = Str(info.name) }
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Positions on the shown map
-- ---------------------------------------------------------------------------

local function IsContinent(mapID)
    local info = Call(API("C_Map", "GetMapInfo"), mapID)
    if BF.IsSecret(info) or type(info) ~= "table" then return false end
    local t = Num(info.mapType)
    local want = _G.Enum and _G.Enum.UIMapType and Num(_G.Enum.UIMapType.Continent) or MAPTYPE_CONTINENT
    return t == want
end

local function StaticFlights(mapID, cont)
    local list = {}
    for _, e in ipairs(ns.flightPaths or {}) do
        if e.map == mapID then
            list[#list + 1] = { e = e, x = e.x, y = e.y }
        elseif type(e.also) == "table" and e.also[1] == mapID then
            list[#list + 1] = { e = e, x = e.also[2], y = e.also[3] }
        elseif cont then
            local wc, wx, wy = core.WorldPos(e.map, e.x, e.y)
            if wc then
                local id, pos = Call(API("C_Map", "GetMapPosFromWorldPos"), wc, core.Vec(wx, wy), mapID)
                local x, y = core.XY(pos)
                if Num(id) == mapID and x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                    list[#list + 1] = { e = e, x = x, y = y }
                end
            end
        end
    end
    return list
end

local function Compute(mapID)
    local cont = IsContinent(mapID)
    local sf = StaticFlights(mapID, cont)
    local rf = RuntimeFlights(mapID)
    local flights, hits = MergeFlights(sf, rf, mapID, core.MapName(mapID))
    for _, h in ipairs(hits) do
        if h.r.known == true and not h.p.e.runtime then MarkLearned(h.p.e) end
        if h.r.known ~= nil then h.p.known = h.r.known end
    end
    local sg = {}
    for _, g in ipairs((ns.graveyards or {})[mapID] or {}) do
        sg[#sg + 1] = { x = g[1], y = g[2], name = g[3] }
    end
    local rg = (not cont) and RuntimeGraves(mapID) or nil
    local graves, added = MergeGraves(sg, rg)
    if cont then graves = {} end
    gen = gen + 1
    return { flights = flights, graves = graves, gen = gen, t = Now(), runtime = (rf ~= nil or rg ~= nil),
        n = { rtFlights = rf and #rf, stFlights = #sf, flights = #flights, rtGraves = rg and #rg,
              stGraves = #sg, graves = #graves, gravesAdded = added } }
end

local function Positions(mapID)
    local c = posCache[mapID]
    if c and c.runtime and Now() - c.t > REFRESH then c = nil end
    if not c then
        c = Compute(mapID)
        -- A continent map before the client can convert positions yields nothing: not cached.
        if #c.flights > 0 or #c.graves > 0 or not IsContinent(mapID) then posCache[mapID] = c end
    end
    return c
end
places.pure.Positions = function(mapID) return Positions(mapID) end
places.pure.ClearCache = function() posCache = {} end

-- The entries to show on a map for a faction and the toggles:
-- { kind = "flight"|"grave", e, x, y, learned, name }.
local function Visible(mapID, faction, flightsOn, gravesOn)
    local out = {}
    local c = Positions(mapID)
    if flightsOn then
        for _, p in ipairs(c.flights) do
            if FactionShows(p.e.faction, faction) then
                local learned = IsLearned(p.e) or (p.e.runtime == true and p.known == true)
                out[#out + 1] = { kind = "flight", e = p.e, x = p.x, y = p.y, learned = learned }
            end
        end
    end
    if gravesOn then
        for _, g in ipairs(c.graves) do
            out[#out + 1] = { kind = "grave", x = g.x, y = g.y, name = g.name }
        end
    end
    return out
end
places.pure.Visible = Visible

-- ---------------------------------------------------------------------------
-- Pins
-- ---------------------------------------------------------------------------

local function HasAtlas(name)
    local info = Call(API("C_Texture", "GetAtlasInfo"), name)
    return type(info) == "table"
end

local function OnEnter(self)
    local d = self.data
    local tip = _G.GameTooltip
    if not d or not tip then return end
    tip:SetOwner(self, "ANCHOR_RIGHT")
    if d.kind == "flight" then
        tip:SetText(d.e.name, 1, 1, 1)
        tip:AddLine(d.e.zone, 0.8, 0.8, 0.8)
        if d.learned then tip:AddLine("Learned", 0.2, 1, 0.2) else tip:AddLine("Not learned", 0.6, 0.6, 0.6) end
    else
        tip:SetText("Graveyard", 1, 1, 1)
        if d.name then tip:AddLine(d.name, 1, 0.82, 0) end
        tip:AddLine(core.MapName(core.DisplayedMapID() or 0), 0.8, 0.8, 0.8)
    end
    tip:Show()
end

local function OnLeave()
    if _G.GameTooltip then _G.GameTooltip:Hide() end
end

local function BuildPin(canvas, i)
    local p = CreateFrame("Frame", nil, canvas)
    p:SetSize(PIN_SIZE, PIN_SIZE)
    p.icon = p:CreateTexture(nil, "OVERLAY")
    p.icon:SetAllPoints(p)
    p:EnableMouse(true)
    p:SetScript("OnEnter", OnEnter)
    p:SetScript("OnLeave", OnLeave)
    p:Hide()
    pins[i] = p
    return p
end

local function Skin(p, d)
    local t = p.icon
    p.data = d
    local desat, r, g, b, a = PinStyle(d)
    if d.kind == "flight" then
        t:SetTexture(FLIGHT_ICON)
        t:SetTexCoord(0, 1, 0, 1)
    else
        local ok = HasAtlas(GRAVE_ATLAS) and pcall(t.SetAtlas, t, GRAVE_ATLAS)
        if not ok then t:SetTexture(GRAVE_ICON) end
    end
    t:SetDesaturated(desat)
    t:SetVertexColor(r, g, b, 1)
    t:SetAlpha(a)
end
places.pure.Skin = Skin

function places.HideAll()
    for _, p in ipairs(pins) do p:Hide() end
    lastSig = nil
end

local drawn = { flights = 0, graves = 0 }

-- Called by the core while the world map is open (its map tick and OnMapChanged hook).
function places.Draw()
    if not db or not core then return end
    if not db.places_flights and not db.places_graves then
        if lastSig then places.HideAll() end
        return
    end
    local map, canvas = core.Map(), core.Canvas()
    if not map or not canvas or not Bool(Method(map, "IsVisible")) then
        if lastSig then places.HideAll() end
        return
    end
    local mapID = core.DisplayedMapID()
    local w, h = Num(Method(canvas, "GetWidth")), Num(Method(canvas, "GetHeight"))
    local zoom = Num(Method(canvas, "GetScale"))
    if not mapID or not w or not h or not zoom or zoom <= 0 then
        if lastSig then places.HideAll() end
        return
    end
    local c = Positions(mapID)
    local sig = table.concat({ mapID, w, h, zoom, rev, c.gen }, ":")
    if sig == lastSig then return end
    lastSig = sig
    local list = Visible(mapID, PlayerFaction(), db.places_flights, db.places_graves)
    local size = PIN_SIZE / zoom
    local level = (Num(Method(canvas, "GetFrameLevel")) or 0) + PIN_LEVEL
    drawn = { map = mapID, flights = 0, graves = 0 }
    for i, d in ipairs(list) do
        local p = pins[i] or BuildPin(canvas, i)
        if p:GetParent() ~= canvas then p:SetParent(canvas) end
        p:SetSize(size, size)
        p:SetFrameLevel(level)
        Skin(p, d)
        p:ClearAllPoints()
        p:SetPoint("CENTER", canvas, "TOPLEFT", d.x * w, -d.y * h)
        p:Show()
        if d.kind == "flight" then drawn.flights = drawn.flights + 1 else drawn.graves = drawn.graves + 1 end
    end
    for i = #list + 1, #pins do pins[i]:Hide() end
end

-- ---------------------------------------------------------------------------
-- Events, settings, slash, menu
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event)
    if event == "TAXIMAP_OPENED" then
        core.Safe("places", ScanTaxi)
    end
    -- entering the world, death and resurrection, a flight map: read the client again
    posCache = {}
    rev = rev + 1
end)

function places.Bind(d, c)
    db, core = d, c
    if type(db.places_flights) ~= "boolean" then db.places_flights = true end
    if type(db.places_graves) ~= "boolean" then db.places_graves = true end
    if type(db.placesLearned) ~= "table" then db.placesLearned = {} end
end

places.SAVED_KEYS = { places_flights = true, places_graves = true, placesLearned = true }

function places.Start()
    if started or not db then return end
    started = true
    for _, ev in ipairs({ "TAXIMAP_OPENED", "TAXIMAP_CLOSED", "PLAYER_ENTERING_WORLD", "PLAYER_DEAD",
        "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
        pcall(events.RegisterEvent, events, ev)
    end
end

local function SetFlag(key, on, text)
    if not db then return end
    db[key] = on and true or false
    rev = rev + 1
    lastSig = nil
    if core then core.Safe("places", places.Draw) end
    Print(text .. " " .. OnOff(db[key]) .. ".")
end

local function SetFlights(on) SetFlag("places_flights", on, "flight paths on the map") end
local function SetGraves(on) SetFlag("places_graves", on, "graveyards on the map") end
places.SetFlights, places.SetGraves = SetFlights, SetGraves

local function Counts()
    local total, learned, show = 0, 0, 0
    local f = PlayerFaction()
    for _, e in ipairs(ns.flightPaths or {}) do
        if FactionShows(e.faction, f) then
            show = show + 1
            if IsLearned(e) then learned = learned + 1 end
        end
        total = total + 1
    end
    local g = 0
    for _, list in pairs(ns.graveyards or {}) do g = g + #list end
    return show, learned, total, g
end

function places.HelpLines()
    return {
        "/ggps flights on|off (now " .. OnOff(db and db.places_flights) .. ") - all flight paths of your faction on the"
            .. " world and zone map, green when learned, grey until then; /ggps graves on|off (now "
            .. OnOff(db and db.places_graves) .. ") - all graveyards on the zone map",
    }
end

local function YesNo(v) return v and "yes" or "no" end

-- The map the world map shows, else the player's own zone map: what each source gave there.
local function MapStatusLines()
    if not core then return {} end
    local mapID
    local map = core.Map and core.Map()
    if map and Bool(Method(map, "IsVisible")) then mapID = core.DisplayedMapID() end
    mapID = mapID or (core.PlayerMapID and core.PlayerMapID())
    if not mapID then return { "this map: none" } end
    local c = Positions(mapID)
    local n = c.n
    local shown = Visible(mapID, PlayerFaction(), true, true)
    local names, ng = {}, 0
    for _, d in ipairs(shown) do
        if d.kind == "flight" then names[#names + 1] = d.e.name .. (d.learned and " (learned)" or "")
        else ng = ng + 1 end
    end
    local lines = {
        string.format("this map: %s (%d)   flight paths: client API %s, %s from the client, %d in the table,"
            .. " %d merged, %d for your faction   graveyards: client API %s, %s from the client, %d in the table,"
            .. " %d merged (%d added by the client)",
            core.MapName(mapID), mapID, YesNo(API("C_TaxiMap", "GetTaxiNodesForMap")),
            n.rtFlights and tostring(n.rtFlights) or "none", n.stFlights, n.flights, #names,
            YesNo(API("C_DeathInfo", "GetGraveyardsForMap")), n.rtGraves and tostring(n.rtGraves) or "none",
            n.stGraves, n.graves, n.gravesAdded or 0),
        "  flight paths here: " .. (#names > 0 and table.concat(names, ", ") or "none") .. "   graveyards here: " .. ng,
    }
    if drawn.map == mapID then
        lines[#lines + 1] = string.format("  last drawn on this map: %d flight paths, %d graveyards (pin level canvas + %d)",
            drawn.flights, drawn.graves, PIN_LEVEL)
    end
    return lines
end

function places.StatusLines()
    if not db then return {} end
    local show, learned, total, g = Counts()
    local lines = {
        string.format("map places: flight paths %s (%d for your faction, %d learned, %d in the table), graveyards %s"
            .. " (%d in the table)   taxi scans: %d, matched %d, unmatched %d%s",
            OnOff(db.places_flights), show, learned, total, OnOff(db.places_graves), g,
            stats.scans, stats.matched, stats.unmatched,
            #lastUnmatched > 0 and (" (" .. table.concat(lastUnmatched, ", ") .. ")") or ""),
    }
    for _, l in ipairs(MapStatusLines()) do lines[#lines + 1] = l end
    return lines
end

-- /ggps flights|graves [on|off]. Returns true when it was one of ours.
function places.Slash(cmd, arg)
    local fn
    local cur
    if cmd == "flights" or cmd == "flight" then fn, cur = SetFlights, db and db.places_flights
    elseif cmd == "graves" or cmd == "graveyards" or cmd == "graveyard" then fn, cur = SetGraves, db and db.places_graves
    else return false end
    if arg == "on" then fn(true) elseif arg == "off" then fn(false) elseif arg == "" then fn(not cur)
    else for _, l in ipairs(places.HelpLines()) do Print(l) end end
    return true
end

function places.MenuEntries()
    if not db then return {} end
    return {
        { text = "Flight paths on the map", checkbox = true, checked = function() return db.places_flights end,
          func = function() SetFlights(not db.places_flights) end },
        { text = "Graveyards on the map", checkbox = true, checked = function() return db.places_graves end,
          func = function() SetGraves(not db.places_graves) end },
    }
end
