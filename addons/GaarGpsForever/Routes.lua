--[[
  GaarGpsForever - Routes.lua (1.6): the direct flight connections of a flight path, shown on hover.

    * Hover a flight path pin of Places.lua and the tooltip lists every flight path it connects to
      directly (a flight A - B - C is the two connections A-B and B-C, never A-C): green when
      learned, grey when not, sorted by name, with a count. On the map, a line runs from the pin to
      each connection that is on the map shown (green when learned, grey when not). A connection
      that is not on that map (a zone map) gets a short stub of a line from the pin, pointing the
      way it lies; the direction is worked out from the world positions of the two places (no
      assumption about the map's axes). Everything disappears when the mouse leaves the pin.
    * The network: Data/FlightRoutes.lua (the client's own TaxiPath table, see its header) merged
      with what the game itself says. When a flight master's map opens (TAXIMAP_OPENED) the routes
      it offers are read through the old taxi API (NumTaxiNodes, TaxiNodeName, TaxiNodeGetType,
      GetNumRoutes, TaxiGetNodeSlot): every hop of every route is one direct connection, saved
      account-wide in GaarGpsForeverDB.placesRoutes per faction as "learned". A node you can fly to
      in more than one hop while the table says there is a direct leg to it is marked "removed" (it
      is only ever removed from the node you stand at, never guessed). Network = (table + learned)
      - removed. Nothing leaves your own faction: an edge counts when both ends are your faction's
      or neutral nodes.
    * Options: "Show flight connections on hover" (default on): /ggps routes on|off and the menu.

  The lines are textures of a plain frame of ours on the map canvas, like the pins; nothing of
  Blizzard's map is replaced or hooked, and every client value is checked for secrecy.
]]

local _G = _G
local _, ns = ...
ns = type(ns) == "table" and ns or {}
local routes = {}
ns.routes = routes

local BF = _G.GaarForever
local Num, Bool, Call, Method, API, OnOff, Str = BF.Num, BF.Bool, BF.Call, BF.Method, BF.API, BF.OnOff, BF.Str

local STORE_VERSION = 1
local STUB = 34               -- screen units: the line toward a destination that is off the map
local LINE_LEVEL = 480        -- under the pins (490)
local LINE_WIDTH = 2          -- screen units
local STEP = 0.05             -- map step used to find how map positions turn into world positions
local GREEN = { 0.3, 1, 0.3 }
local GREY = { 0.6, 0.6, 0.6 }

local db, core, places
local overlay
local lines = {}
local stats = { scans = 0, learned = 0, removed = 0, noApi = 0 }
local last                    -- summary of the last scan, for /ggps status

local H = {}                  -- helpers (a table: the 200-locals limit)
routes.pure = H

-- ---------------------------------------------------------------------------
-- Pure helpers (tested)
-- ---------------------------------------------------------------------------

local byNode
function H.ClearCache() byNode = nil end
function H.Node(id)
    if not byNode then
        byNode = {}
        for _, e in ipairs(ns.flightPaths or {}) do
            if type(e.node) == "number" then byNode[e.node] = e end
        end
    end
    return id and byNode[id] or nil
end

-- A node of this faction or neutral; a player without a faction sees the neutral ones only.
function H.Shows(entryFaction, faction)
    if entryFaction == "Neutral" then return true end
    return entryFaction == faction
end

function H.EdgeKey(a, b)
    if a > b then a, b = b, a end
    return a .. "-" .. b
end

local function KeyNodes(key)
    local a, b = tostring(key):match("^(%d+)%-(%d+)$")
    a, b = tonumber(a), tonumber(b)
    if a and b then return a, b end
end

-- The edges of the table both of whose ends this faction shows: { {a, b, key} }.
function H.StaticEdges(faction)
    local out = {}
    for _, ed in ipairs(ns.flightRoutes or {}) do
        local a, b = ed[1], ed[2]
        local ea, eb = H.Node(a), H.Node(b)
        if ea and eb and a ~= b and H.Shows(ea.faction, faction) and H.Shows(eb.faction, faction) then
            out[#out + 1] = { a, b, H.EdgeKey(a, b) }
        end
    end
    return out
end

local function Set(store, name)
    if type(store[name]) ~= "table" then store[name] = {} end
    return store[name]
end

-- The network of a faction: adjacency { [node] = { [node] = true } } = (table + learned) - removed.
-- store: { learned = { key = true }, removed = { key = true } } (may be empty or nil).
function H.Graph(faction, store)
    store = store or {}
    local adj, keys = {}, {}
    local function add(a, b)
        local ea, eb = H.Node(a), H.Node(b)
        if not ea or not eb or a == b or not H.Shows(ea.faction, faction) or not H.Shows(eb.faction, faction) then return end
        local k = H.EdgeKey(a, b)
        if keys[k] or (type(store.removed) == "table" and store.removed[k]) then return end
        keys[k] = true
        adj[a] = adj[a] or {}; adj[b] = adj[b] or {}
        adj[a][b] = true; adj[b][a] = true
    end
    for _, ed in ipairs(H.StaticEdges(faction)) do add(ed[1], ed[2]) end
    if type(store.learned) == "table" then
        for k, v in pairs(store.learned) do
            if v then
                local a, b = KeyNodes(k)
                if a then add(a, b) end
            end
        end
    end
    return adj, keys
end

-- Counts of a faction: static edges, learned keys, learned keys the table lacks, removed, merged.
function H.Counts(faction, store)
    store = store or {}
    local static = H.StaticEdges(faction)
    local inStatic = {}
    for _, ed in ipairs(static) do inStatic[ed[3]] = true end
    local learned, extra, removed = 0, 0, 0
    for k, v in pairs(type(store.learned) == "table" and store.learned or {}) do
        if v then learned = learned + 1; if not inStatic[k] then extra = extra + 1 end end
    end
    for _, v in pairs(type(store.removed) == "table" and store.removed or {}) do
        if v then removed = removed + 1 end
    end
    local _, keys = H.Graph(faction, store)
    local merged = 0
    for _ in pairs(keys) do merged = merged + 1 end
    return { static = #static, learned = learned, extra = extra, removed = removed, merged = merged }
end

-- The direct destinations of a node for a faction, sorted by name (then node):
-- { {node, name, zone, e, learned} }, and how many are learned. isLearned(e) -> boolean.
function H.Destinations(node, faction, store, isLearned)
    local adj = H.Graph(faction, store)
    local list, n = {}, 0
    for other in pairs(adj[node] or {}) do
        local e = H.Node(other)
        local learned = isLearned and isLearned(e) and true or false
        if learned then n = n + 1 end
        list[#list + 1] = { node = other, name = e.name, zone = e.zone, e = e, learned = learned }
    end
    table.sort(list, function(x, y)
        local a, b = x.name:lower(), y.name:lower()
        if a ~= b then return a < b end
        return x.node < y.node
    end)
    return list, n
end

-- The flight path of a taxi node name for a faction: the row of that faction, else the neutral one.
-- matchName(name) -> list of table rows (Places' MatchName).
function H.Pick(name, faction, matchName)
    local list = matchName and matchName(name) or nil
    if not list then return nil end
    local neutral
    for _, e in ipairs(list) do
        if type(e.node) == "number" then
            if e.faction == faction then return e.node end
            if e.faction == "Neutral" then neutral = neutral or e.node end
        end
    end
    return neutral
end

-- What the taxi map says as data. slots: { [i] = { name, kind = "CURRENT"|"REACHABLE"|..., routes = n,
-- hops = { {fromSlot, toSlot} } } }. Returns { current = node, edges = { {a, b} }, multi = { node } },
-- or nil without a resolved current node.
function H.Resolve(slots, faction, matchName)
    if not faction then return nil end
    local nodeOf = {}
    for i, s in ipairs(slots) do nodeOf[i] = H.Pick(s.name, faction, matchName) end
    local current
    for i, s in ipairs(slots) do
        if s.kind == "CURRENT" and nodeOf[i] then current = nodeOf[i]; break end
    end
    if not current then return nil end
    local edges, seen, multi = {}, {}, {}
    local function edge(a, b)
        if a and b and a ~= b then
            local k = H.EdgeKey(a, b)
            if not seen[k] then seen[k] = true; edges[#edges + 1] = { a, b } end
        end
    end
    for i, s in ipairs(slots) do
        local node = nodeOf[i]
        if node and s.kind == "REACHABLE" and (s.routes or 0) > 0 then
            if s.hops and #s.hops > 0 then
                for _, hop in ipairs(s.hops) do edge(nodeOf[hop[1]], nodeOf[hop[2]]) end
            elseif s.routes == 1 then
                edge(current, node)
            end
            if s.routes >= 2 then multi[#multi + 1] = node end
        end
    end
    return { current = current, edges = edges, multi = multi }
end

-- Saves a scan into the store of a faction: every edge seen is learned (and no longer removed); a
-- node reachable from the current one only in two hops or more, where the network has a direct
-- edge to it that the scan did not show, loses that edge ("removed"). A scan without edges
-- changes nothing. Returns the number of new learned edges and of newly removed ones.
function H.Apply(store, faction, scan)
    if not scan or not scan.current or #scan.edges == 0 then return 0, 0 end
    local learned, removed = Set(store, "learned"), Set(store, "removed")
    local added, gone = 0, 0
    local seen = {}
    for _, ed in ipairs(scan.edges) do
        local k = H.EdgeKey(ed[1], ed[2])
        seen[k] = true
        if not learned[k] then learned[k] = true; added = added + 1 end
        removed[k] = nil
    end
    local adj = H.Graph(faction, store)
    for _, x in ipairs(scan.multi) do
        local k = H.EdgeKey(scan.current, x)
        if adj[scan.current] and adj[scan.current][x] and not seen[k] then
            removed[k] = true; learned[k] = nil; gone = gone + 1
        end
    end
    return added, gone
end

-- Map delta (dx, dy) of a place from a pin, from world positions: s = the pin, a = the pin moved
-- sx along the map's x, b = the pin moved sy along its y, e = the place. All { x, y } world pairs.
function H.MapDelta(s, a, b, e, sx, sy)
    local u1, u2 = (a[1] - s[1]) / sx, (a[2] - s[2]) / sx
    local v1, v2 = (b[1] - s[1]) / sy, (b[2] - s[2]) / sy
    local det = u1 * v2 - u2 * v1
    if math.abs(det) < 1e-9 then return nil end
    local d1, d2 = e[1] - s[1], e[2] - s[2]
    return (d1 * v2 - d2 * v1) / det, (u1 * d2 - u2 * d1) / det
end

-- ---------------------------------------------------------------------------
-- Saved routes (account-wide, per faction)
-- ---------------------------------------------------------------------------

local function PlayerFaction()
    local f = Call(_G.UnitFactionGroup, "player")
    if type(f) == "string" and (f == "Alliance" or f == "Horde") then return f end
    return nil
end

local function StoreFor(faction)
    if not db or not faction then return nil end
    if type(db.placesRoutes) ~= "table" or db.placesRoutes._v ~= STORE_VERSION then
        db.placesRoutes = { _v = STORE_VERSION }
    end
    local s = db.placesRoutes
    if type(s[faction]) ~= "table" then s[faction] = {} end
    Set(s[faction], "learned"); Set(s[faction], "removed")
    return s[faction]
end

-- ---------------------------------------------------------------------------
-- Learning from the taxi map
-- ---------------------------------------------------------------------------

local TAXI_FUNCS = { "NumTaxiNodes", "TaxiNodeName", "TaxiNodeGetType", "GetNumRoutes", "TaxiGetNodeSlot" }

local function HaveTaxiAPI()
    for _, fn in ipairs(TAXI_FUNCS) do
        if type(_G[fn]) ~= "function" then return false end
    end
    return true
end

-- The open taxi map as slots (see H.Resolve), or nil when the old taxi API is not there.
local function ReadSlots()
    if not HaveTaxiAPI() then return nil end
    local n = Num(Call(_G.NumTaxiNodes))
    if not n or n < 1 then return nil end
    local slots = {}
    for i = 1, n do
        local name = Str(Call(_G.TaxiNodeName, i))
        local kind = Str(Call(_G.TaxiNodeGetType, i))
        local s = { name = name, kind = kind, routes = 0, hops = {} }
        if kind == "REACHABLE" then
            s.routes = Num(Call(_G.GetNumRoutes, i)) or 0
            for hop = 1, s.routes do
                local from = Num(Call(_G.TaxiGetNodeSlot, i, hop, true))
                local to = Num(Call(_G.TaxiGetNodeSlot, i, hop, false))
                if from and to then s.hops[#s.hops + 1] = { from, to } end
            end
        end
        slots[i] = s
    end
    return slots
end

function routes.Scan()
    stats.scans = stats.scans + 1
    local faction = PlayerFaction()
    local store = StoreFor(faction)
    if not store or not places then return end
    local slots = ReadSlots()
    if not slots then stats.noApi = stats.noApi + 1; last = { noApi = true }; return end
    local scan = H.Resolve(slots, faction, places.pure.MatchName)
    if not scan then last = { slots = #slots }; return end
    local added, gone = H.Apply(store, faction, scan)
    stats.learned, stats.removed = stats.learned + added, stats.removed + gone
    last = { slots = #slots, current = (H.Node(scan.current) or {}).name, edges = #scan.edges,
        multi = #scan.multi, added = added, removed = gone }
end

-- ---------------------------------------------------------------------------
-- Hover: tooltip and lines
-- ---------------------------------------------------------------------------

local function Overlay(canvas)
    if overlay and overlay:GetParent() == canvas then return overlay end
    if not overlay then
        overlay = CreateFrame("Frame", nil, canvas)
        overlay:EnableMouse(false)
    elseif overlay:GetParent() ~= canvas then
        overlay:SetParent(canvas)
    end
    overlay:SetAllPoints(canvas)
    overlay:SetFrameLevel((Num(Method(canvas, "GetFrameLevel")) or 0) + LINE_LEVEL)
    overlay:Show()
    return overlay
end

local function GetLine(i)
    if not lines[i] then
        if type(overlay.CreateLine) ~= "function" then return nil end
        local ok, ln = pcall(overlay.CreateLine, overlay, nil, "ARTWORK")
        if not ok or not ln then return nil end
        lines[i] = ln
    end
    return lines[i]
end

function routes.Hide()
    for _, ln in ipairs(lines) do ln:Hide() end
end

-- The map direction (dx, dy; y down, in screen units, length 1) of a place from a pin, or nil.
local function OffMapDirection(mapID, d, dest, w, h)
    local c1, sx, sy = core.WorldPos(mapID, d.x, d.y)
    local stepX = d.x <= 0.9 and STEP or -STEP
    local stepY = d.y <= 0.9 and STEP or -STEP
    local c2, ax, ay = core.WorldPos(mapID, d.x + stepX, d.y)
    local c3, bx, by = core.WorldPos(mapID, d.x, d.y + stepY)
    local c4, ex, ey = core.WorldPos(dest.map, dest.x, dest.y)
    if not (c1 and c2 and c3 and c4) or c1 ~= c2 or c1 ~= c3 or c1 ~= c4 then return nil end
    local dx, dy = H.MapDelta({ sx, sy }, { ax, ay }, { bx, by }, { ex, ey }, stepX, stepY)
    if not dx then return nil end
    dx, dy = dx * w, dy * h
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-9 then return nil end
    return dx / len, dy / len
end

local function DrawLines(pin, d, list)
    local canvas = pin:GetParent()
    local mapID = core.DisplayedMapID()
    local w, h = Num(Method(canvas, "GetWidth")), Num(Method(canvas, "GetHeight"))
    local zoom = Num(Method(canvas, "GetScale"))
    if not canvas or not mapID or not w or not h or not zoom or zoom <= 0 then return end
    Overlay(canvas)
    local onMap = {}
    for _, p in ipairs(places.pure.Positions(mapID).flights) do
        if p.e.node and not onMap[p.e.node] then onMap[p.e.node] = p end
    end
    local x0, y0 = d.x * w, -d.y * h
    local n = 0
    for _, it in ipairs(list) do
        local x1, y1
        local p = onMap[it.node]
        if p then
            x1, y1 = p.x * w, -p.y * h
        else
            local ux, uy = OffMapDirection(mapID, d, it.e, w, h)
            if ux then
                local len = STUB / zoom
                x1, y1 = x0 + ux * len, y0 - uy * len
            end
        end
        if x1 then
            n = n + 1
            local ln = GetLine(n)
            if not ln then break end
            local c = it.learned and GREEN or GREY
            ln:SetThickness(LINE_WIDTH / zoom)
            ln:SetColorTexture(c[1], c[2], c[3], it.learned and 0.9 or 0.6)
            ln:SetStartPoint("TOPLEFT", canvas, x0, y0)
            ln:SetEndPoint("TOPLEFT", canvas, x1, y1)
            ln:Show()
        end
    end
    for i = n + 1, #lines do lines[i]:Hide() end
end

-- Called by Places' pin OnEnter, before the tooltip is shown.
function routes.OnEnter(pin, tip)
    if not db or not db.places_routes or not places then return end
    local d = pin.data
    if not d or d.kind ~= "flight" or type(d.e.node) ~= "number" then return end
    local faction = PlayerFaction()
    local list, nLearned = H.Destinations(d.e.node, faction, StoreFor(faction), places.pure.IsLearned)
    if #list == 0 then return end
    tip:AddLine(" ")
    tip:AddLine(string.format("Direct flights: %d (%d learned)", #list, nLearned), 1, 0.82, 0)
    for _, it in ipairs(list) do
        local c = it.learned and GREEN or GREY
        tip:AddLine(it.name, c[1], c[2], c[3])
    end
    DrawLines(pin, d, list)
end

-- ---------------------------------------------------------------------------
-- Settings, slash, menu, status
-- ---------------------------------------------------------------------------

function routes.Bind(d, c, p)
    db, core, places = d, c, p
    if type(db.places_routes) ~= "boolean" then db.places_routes = true end
    if type(db.placesRoutes) ~= "table" then db.placesRoutes = {} end
end

function routes.SetShow(on)
    if not db then return end
    db.places_routes = on and true or false
    if not on then routes.Hide() end
    if core then core.Print("flight connections on hover " .. OnOff(db.places_routes) .. ".") end
end

function routes.HelpLines()
    return { "/ggps routes on|off (now " .. OnOff(db and db.places_routes) .. ") - hover a flight path on the map"
        .. " to see its direct flight connections: lines on the map and a list in the tooltip" }
end

function routes.Slash(cmd, arg)
    if cmd ~= "routes" and cmd ~= "route" then return false end
    if arg == "on" then routes.SetShow(true) elseif arg == "off" then routes.SetShow(false)
    elseif arg == "" then routes.SetShow(not (db and db.places_routes))
    else for _, l in ipairs(routes.HelpLines()) do core.Print(l) end end
    return true
end

function routes.MenuEntries()
    if not db then return {} end
    return { { text = "Show flight connections on hover", checkbox = true,
        checked = function() return db.places_routes end,
        func = function() routes.SetShow(not db.places_routes) end } }
end

function routes.StatusLines()
    if not db then return {} end
    local function part(faction)
        local c = H.Counts(faction, db.placesRoutes and type(db.placesRoutes[faction]) == "table"
            and db.placesRoutes[faction] or nil)
        return string.format("%s %d static + %d learned = %d (%d learned seen, %d removed)",
            faction, c.static, c.extra, c.merged, c.learned, c.removed)
    end
    local api = {}
    for _, fn in ipairs(TAXI_FUNCS) do api[#api + 1] = fn .. " " .. (type(_G[fn]) == "function" and "yes" or "no") end
    local lines = { string.format("flight routes: hover %s; %s; %s; taxi scans %d (new edges %d, removed %d); taxi API: %s",
        OnOff(db.places_routes), part("Alliance"), part("Horde"), stats.scans, stats.learned, stats.removed,
        table.concat(api, ", ")) }
    if last then
        if last.noApi then lines[#lines + 1] = "  last taxi scan: the old taxi API is not there, nothing learned"
        elseif not last.current then lines[#lines + 1] = "  last taxi scan: " .. last.slots .. " nodes, no current node found"
        else
            lines[#lines + 1] = string.format("  last taxi scan at %s: %d nodes, %d connections seen, %d multi-hop, %d new, %d removed",
                last.current, last.slots, last.edges, last.multi, last.added, last.removed)
        end
    end
    return lines
end
