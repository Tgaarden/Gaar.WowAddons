--[[
  GaarGpsForever - Places.lua (1.5): every graveyard and flight path on the world map and the zone map.

    * Graveyards (spirit healers) and flight paths (flight masters) of the vanilla world are drawn
      as small icons on the map WorldMapFrame shows, whether or not you have found them. The static
      positions are in Data/Graveyards.lua and Data/FlightPaths.lua.
    * Flight paths: your own faction's and the neutral ones only. A flight path you have learned has
      the normal flight master icon, one you have not is grey and faded. The tooltip says the name,
      the zone and "Learned" or "Not learned". On a continent map flight paths are shown too (placed
      through the world position, as the waypoint pin is); graveyards only on a zone map.
    * Learned: whenever a flight master's map opens (TAXIMAP_OPENED) the nodes the client lists are
      read (C_TaxiMap.GetAllTaxiNodes / GetTaxiNodesForMap, or the old NumTaxiNodes / TaxiNodeName)
      and matched to the static table by name. Saved per character in GaarGpsForeverDB.placesLearned.
      Until your first flight master visit on a character, every flight path shows grey.
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
local MAPTYPE_CONTINENT = 2   -- Enum.UIMapType.Continent
local FLIGHT_ICON = "Interface\\Minimap\\Tracking\\FlightMaster"
local GRAVE_ATLAS = "poi-graveyard-neutral"
local GRAVE_ICON = "Interface\\Icons\\Spell_Shadow_DeathCoil"

local db, core
local started
local pins = {}               -- pool of pin frames
local lastSig
local posCache = {}           -- mapID -> { flights = { {e, x, y} }, graves = { {x, y} } }
local rev = 0                 -- bumped when what is shown could change (toggles, learned)
local stats = { scans = 0, nodes = 0, matched = 0, unmatched = 0 }
local lastUnmatched = {}

local function Print(msg) if core then core.Print(msg) end end

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

local byNorm
local function EntriesByNorm()
    if byNorm then return byNorm end
    byNorm = {}
    for _, e in ipairs(ns.flightPaths or {}) do
        local n = Norm(e.name)
        if n then
            byNorm[n] = byNorm[n] or {}
            table.insert(byNorm[n], e)
        end
    end
    return byNorm
end

-- The static flight paths a client node name stands for: an exact normalised match, else one whose
-- name starts with the other (the client says "Theramore", the table "Theramore Isle").
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

local function Key(e) return Norm(e.name) .. ":" .. tostring(e.map) end

places.pure = { Norm = Norm, MatchName = MatchName, FactionShows = FactionShows }

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
    return db.placesLearned[key]
end

local function IsLearned(e)
    return Learned()[Key(e)] == true
end

local function PlayerFaction()
    local f = Call(_G.UnitFactionGroup, "player")
    if type(f) == "string" and (f == "Alliance" or f == "Horde") then return f end
    return nil
end

-- Marks the static flight paths matching these client node names as learned; returns how many were new.
local function Record(names)
    local set, new = Learned(), 0
    stats.nodes = stats.nodes + #names
    lastUnmatched = {}
    for _, nm in ipairs(names) do
        local list = MatchName(nm)
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

local function NodeNamesFromTaxiMap()
    local names = {}
    local get = API("C_TaxiMap", "GetAllTaxiNodes") or API("C_TaxiMap", "GetTaxiNodesForMap")
    if not get then return nil end
    local seen = {}
    local ids = {}
    local f = _G.FlightMapFrame
    if type(f) == "table" then ids[#ids + 1] = Num(Method(f, "GetMapID")) end
    for _, c in ipairs({ 1414, 1415 }) do ids[#ids + 1] = c end
    local best = Num(Call(API("C_Map", "GetBestMapForUnit"), "player"))
    ids[#ids + 1] = best
    for _, id in ipairs(ids) do
        if not seen[id] then
            seen[id] = true
            local list = Call(get, id)
            if not BF.IsSecret(list) and type(list) == "table" then
                for _, info in ipairs(list) do
                    if not BF.IsSecret(info) and type(info) == "table" then
                        local nm = Str(info.name)
                        if nm then names[#names + 1] = nm end
                    end
                end
            end
        end
    end
    return names
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
    local names = NodeNamesFromTaxiMap()
    if not names or #names == 0 then names = NodeNamesLegacy() or names or {} end
    Record(names)
end

places.pure.Scan = ScanTaxi

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

local function Compute(mapID)
    local c = { flights = {}, graves = {} }
    local cont = IsContinent(mapID)
    for _, e in ipairs(ns.flightPaths or {}) do
        if e.map == mapID then
            c.flights[#c.flights + 1] = { e = e, x = e.x, y = e.y }
        elseif cont then
            local wc, wx, wy = core.WorldPos(e.map, e.x, e.y)
            if wc then
                local id, pos = Call(API("C_Map", "GetMapPosFromWorldPos"), wc, core.Vec(wx, wy), mapID)
                local x, y = core.XY(pos)
                if Num(id) == mapID and x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                    c.flights[#c.flights + 1] = { e = e, x = x, y = y }
                end
            end
        end
    end
    for _, g in ipairs((ns.graveyards or {})[mapID] or {}) do
        c.graves[#c.graves + 1] = { x = g[1], y = g[2] }
    end
    return c
end

local function Positions(mapID)
    local c = posCache[mapID]
    if not c then
        c = Compute(mapID)
        -- A continent map before the client can convert positions yields nothing: not cached.
        if #c.flights > 0 or #c.graves > 0 or not IsContinent(mapID) then posCache[mapID] = c end
    end
    return c
end
places.pure.Positions = function(mapID) return Positions(mapID) end

-- The entries to show on a map for a faction and the toggles: { kind = "flight"|"grave", e, x, y, learned }.
local function Visible(mapID, faction, flightsOn, gravesOn)
    local out = {}
    local c = Positions(mapID)
    if flightsOn then
        for _, p in ipairs(c.flights) do
            if FactionShows(p.e.faction, faction) then
                out[#out + 1] = { kind = "flight", e = p.e, x = p.x, y = p.y, learned = IsLearned(p.e) }
            end
        end
    end
    if gravesOn then
        for _, g in ipairs(c.graves) do
            out[#out + 1] = { kind = "grave", x = g.x, y = g.y }
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
    if d.kind == "flight" then
        t:SetTexture(FLIGHT_ICON)
        t:SetTexCoord(0, 1, 0, 1)
        t:SetDesaturated(not d.learned)
        t:SetVertexColor(1, 1, 1, 1)
        t:SetAlpha(d.learned and 1 or 0.55)
    else
        t:SetDesaturated(false)
        t:SetAlpha(1)
        t:SetVertexColor(1, 1, 1, 1)
        local ok = HasAtlas(GRAVE_ATLAS) and pcall(t.SetAtlas, t, GRAVE_ATLAS)
        if not ok then t:SetTexture(GRAVE_ICON) end
    end
end

function places.HideAll()
    for _, p in ipairs(pins) do p:Hide() end
    lastSig = nil
end

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
    local sig = table.concat({ mapID, w, h, zoom, rev }, ":")
    if sig == lastSig then return end
    lastSig = sig
    local list = Visible(mapID, PlayerFaction(), db.places_flights, db.places_graves)
    local size = PIN_SIZE / zoom
    local level = (Num(Method(canvas, "GetFrameLevel")) or 0) + 400
    for i, d in ipairs(list) do
        local p = pins[i] or BuildPin(canvas, i)
        if p:GetParent() ~= canvas then p:SetParent(canvas) end
        p:SetSize(size, size)
        p:SetFrameLevel(level)
        Skin(p, d)
        p:ClearAllPoints()
        p:SetPoint("CENTER", canvas, "TOPLEFT", d.x * w, -d.y * h)
        p:Show()
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
    elseif event == "PLAYER_ENTERING_WORLD" then
        posCache = {}
        rev = rev + 1
    end
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
    for _, ev in ipairs({ "TAXIMAP_OPENED", "PLAYER_ENTERING_WORLD" }) do
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
            .. " world and zone map, grey until learned; /ggps graves on|off (now " .. OnOff(db and db.places_graves)
            .. ") - all graveyards on the zone map",
    }
end

function places.StatusLines()
    if not db then return {} end
    local show, learned, total, g = Counts()
    return {
        string.format("map places: flight paths %s (%d shown, %d learned, %d in the table), graveyards %s (%d)"
            .. "   taxi scans: %d, matched %d, unmatched %d   C_TaxiMap: %s",
            OnOff(db.places_flights), show, learned, total, OnOff(db.places_graves), g,
            stats.scans, stats.matched, stats.unmatched,
            (API("C_TaxiMap", "GetAllTaxiNodes") or API("C_TaxiMap", "GetTaxiNodesForMap")) and "yes" or "no"),
    }
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
