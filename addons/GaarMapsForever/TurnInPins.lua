--[[
  GaarMapsForever - TurnInPins.lua (1.8.0): a yellow "?" on the continent and world maps for every quest
  in the log that is ready to turn in (setting turnInPins, /gmf turnins on|off).

    * Which quests. Every quest in the log (C_QuestLog.GetNumQuestLogEntries / GetInfo, else the legacy
      GetQuestLogTitle) for which C_QuestLog.ReadyForTurnIn or IsComplete says true (the legacy
      isComplete flag 1 without them). Nothing else: no objectives, no quests still in progress.
    * Where. Blizzard's own turn-in point: C_QuestLog.GetQuestsOnMap(zone), the same call the zone map's
      quest pins come from, gives each quest with a point on that zone; for a complete quest that point is
      its turn-in. The zones are every Zone-type map (Enum.UIMapType.Zone) under the top of the shown map's
      tree (C_Map.GetMapChildrenInfo(root, Zone, true)); each quest's own map (GetQuestUiMapID) is asked
      first. Map indicator entries (the arrows that point off the map) are skipped. A complete quest whose
      turn-in zone the client has no point for is not drawn and is counted as "no position" in
      /gmf status; while there are such quests the scan is repeated every few seconds with the map open.
    * Projection. Zone point -> the shown continent or world map with C_Map.GetMapRectOnMap(zone, shown);
      else through the world position (C_Map.GetWorldPosFromMapPos, then GetMapPosFromWorldPos with the
      shown map as the override). A point that lands outside the shown map is not drawn.
    * When. Only while the world map shows a continent (type 2) or the world (type 1). Never on a zone,
      dungeon or micro map: Blizzard draws the "?" there itself, and that stays untouched.
    * Refresh. QUEST_LOG_UPDATE, QUEST_TURNED_IN, QUEST_REMOVED, QUEST_ACCEPTED and QUEST_POI_UPDATE mark
      the data stale; it is read again at most once a second, and only while the map is open on a
      continent or the world. A changed map (OnMapChanged) or a new tree root reads it again too.
    * Pins. Plain frames of our own on the map canvas, the same pattern as TrackedPins.lua (whose canvas
      helper is reused): Blizzard's turn-in atlas (UI-QuestIcon-TurnIn-Normal, as POIButton uses for a
      complete quest; else QuestTurnin; else the gossip "?" texture). Quests turned in to the same spot
      share one pin. Hover lists each quest's name, its zone and the log's "Return to ..." text (the
      turn-in NPC) when the client has it. Hover only: clicks go through to the map, so a click on the pin
      opens the zone under it as usual. No Blizzard pin, data provider or function is touched; the only
      hook is hooksecurefunc on the map's OnMapChanged.
]]

local _G = _G
local _, ns = ...
ns = type(ns) == "table" and ns or {}

local TI = {}
ns.turnInPins = TI

local BF = _G.GaarForever
local IsSecret, Num, Str, Bool = BF.IsSecret, BF.Num, BF.Str, BF.Bool
local Call, API, OnOff = BF.Call, BF.API, BF.OnOff

local PIN_SIZE = 20             -- screen units at any zoom
local PIN_LEVEL = 480           -- above the canvas and the tracked pins (470), under GaarGps (490, 500)
local TICK = 0.2                -- seconds between redraw checks while the map is open
local THROTTLE = 1              -- seconds between two reads of the quest data
local RETRY = 5                 -- seconds between reads while complete quests still have no position
local SAME_SPOT = 0.004         -- turn-ins this close on the same zone (0-1) share one pin
local SHOW_TYPES = { [1] = true, [2] = true }   -- Enum.UIMapType World, Continent
TI.ATLASES = { "UI-QuestIcon-TurnIn-Normal", "QuestTurnin" }
TI.FALLBACK_TEXTURE = "Interface\\GossipFrame\\ActiveQuestIcon"
TI.EVENTS = { "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_ACCEPTED", "QUEST_POI_UPDATE" }

local settings, core
TI.stats = { scans = 0, errors = 0, lastError = nil }
TI.data = { ready = {}, found = {}, missing = {}, zones = 0, root = nil, at = -100, rev = 0 }
TI.drawn = { map = nil, mapType = nil, count = 0, quests = 0 }
local dirty = true

local function Now() return Num(Call(_G.GetTime)) or 0 end

local function MapInfo(mapID)
    local info = mapID and Call(API("C_Map", "GetMapInfo"), mapID)
    if not IsSecret(info) and type(info) == "table" then return info end
end

local function MapName(mapID)
    local info = MapInfo(mapID)
    return info and Str(info.name)
end

local function In01(x, y)
    x, y = Num(x), Num(y)
    if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then return x, y end
end

local function Vec(x, y)
    local v = Call(_G.CreateVector2D, x, y)
    if type(v) == "table" then return v end
    return { x = x, y = y }
end

local function XY(v)
    if IsSecret(v) or type(v) ~= "table" then return nil end
    local x, y
    if type(v.GetXY) == "function" then x, y = Call(v.GetXY, v) else x, y = v.x, v.y end
    return Num(x), Num(y)
end

-- ---------------------------------------------------------------------------
-- Data: the ready quests and their turn-in points
-- ---------------------------------------------------------------------------

local function IsReady(qid, legacyComplete)
    local ready = Call(API("C_QuestLog", "ReadyForTurnIn"), qid)
    if Bool(ready) then return true end
    local complete = Call(API("C_QuestLog", "IsComplete"), qid)
    if Bool(complete) then return true end
    return legacyComplete == 1 or legacyComplete == true
end

-- The quests in the log that are ready to turn in: { [questID] = { id, title, index } } and their count.
function TI.ReadyQuests()
    local out, count = {}, 0
    local n = Num(Call(API("C_QuestLog", "GetNumQuestLogEntries")))
    local getInfo = API("C_QuestLog", "GetInfo")
    local legacy = API("GetQuestLogTitle")
    if not n then n = Num(Call(API("GetNumQuestLogEntries"))) end
    for i = 1, math.min(n or 0, 200) do
        local qid, header, title, legacyComplete
        local info = getInfo and Call(getInfo, i)
        if not IsSecret(info) and type(info) == "table" then
            header, qid, title = Bool(info.isHeader), Num(info.questID), Str(info.title)
        elseif legacy then
            -- title, level, tag, isHeader, isCollapsed, isComplete, frequency, questID
            local t, _, _, h, _, c, _, id = Call(legacy, i)
            header, qid, title, legacyComplete = Bool(h), Num(id), Str(t), Num(c)
        end
        if not header and qid and qid > 0 and not out[qid] and IsReady(qid, legacyComplete) then
            title = title or Str(Call(API("C_QuestLog", "GetTitleForQuestID"), qid))
            out[qid] = { id = qid, title = title or ("Quest " .. qid), index = i }
            count = count + 1
        end
    end
    return out, count
end

-- The top of a map's tree: parents are followed up to the last one that is not a cosmic map.
function TI.RootOf(mapID)
    local m, seen = Num(mapID), {}
    for _ = 1, 12 do
        if not m or seen[m] then break end
        seen[m] = true
        local info = MapInfo(m)
        local parent = info and Num(info.parentMapID)
        local pinfo = parent and parent > 0 and MapInfo(parent)
        if not pinfo or Num(pinfo.mapType) == 0 then break end
        m = parent
    end
    return m
end

-- Every Zone-type map under root: { mapID, ... }.
local zoneCache = {}
function TI.ZonesUnder(root)
    if zoneCache[root] then return zoneCache[root] end
    local list, seen = {}, {}
    local E = type(_G.Enum) == "table" and type(_G.Enum.UIMapType) == "table" and _G.Enum.UIMapType
    local zoneType = E and Num(E.Zone) or 3
    local kids = Call(API("C_Map", "GetMapChildrenInfo"), root, zoneType, true)
    if not IsSecret(kids) and type(kids) == "table" then
        for _, info in ipairs(kids) do
            local id = type(info) == "table" and Num(info.mapID)
            if id and not seen[id] and (Num(info.mapType) or zoneType) == zoneType then
                seen[id] = true
                list[#list + 1] = id
            end
        end
    end
    if #list > 0 then zoneCache[root] = list end
    return list
end
TI.ResetZones = function() zoneCache = {} end

-- The turn-in point of each ready quest: { [questID] = { zone, x, y } }, plus the ids without one.
-- ready = TI.ReadyQuests(); zones = TI.ZonesUnder(root). Pure on the client calls (tested).
function TI.FindPoints(ready, zones)
    local found, order, seen = {}, {}, {}
    local getOnMap = API("C_QuestLog", "GetQuestsOnMap")
    if not getOnMap then return found end
    local uiMap = API("GetQuestUiMapID") or API("C_QuestLog", "GetQuestUiMapID")
    local inTree = {}
    for _, z in ipairs(zones) do inTree[z] = true end
    -- Each quest's own map first (it is the turn-in zone most often), then the whole tree.
    for qid in pairs(ready) do
        local m = Num(Call(uiMap, qid))
        if m and inTree[m] and not seen[m] then seen[m] = true; order[#order + 1] = m end
    end
    for _, z in ipairs(zones) do
        if not seen[z] then seen[z] = true; order[#order + 1] = z end
    end
    local left = 0
    for _ in pairs(ready) do left = left + 1 end
    for _, zone in ipairs(order) do
        if left == 0 then break end
        local quests = Call(getOnMap, zone)
        if not IsSecret(quests) and type(quests) == "table" then
            for _, q in ipairs(quests) do
                local qid = type(q) == "table" and Num(q.questID)
                if qid and ready[qid] and not found[qid] and not Bool(q.isMapIndicatorQuest) then
                    local x, y = In01(q.x, q.y)
                    if x and (x > 0 or y > 0) then
                        found[qid] = { zone = zone, x = x, y = y }
                        left = left - 1
                    end
                end
            end
        end
    end
    return found
end

-- A zone point on another map (0-1), or nil when it is not on that map.
function TI.Project(zone, x, y, target)
    if zone == target then return x, y end
    local a, b, c, d = Call(API("C_Map", "GetMapRectOnMap"), zone, target)
    local minX, maxX, minY, maxY = Num(a), Num(b), Num(c), Num(d)
    if minX and maxX and minY and maxY and maxX > minX and maxY > minY then
        return In01(minX + x * (maxX - minX), minY + y * (maxY - minY))
    end
    local cont, pos = Call(API("C_Map", "GetWorldPosFromMapPos"), zone, Vec(x, y))
    cont = Num(cont)
    local wx, wy = XY(pos)
    if not cont or not wx or not wy then return nil end
    local id, mpos = Call(API("C_Map", "GetMapPosFromWorldPos"), cont, Vec(wx, wy), target)
    if Num(id) ~= target then return nil end
    return In01(XY(mpos))
end

-- Reads the ready quests and their points for the tree under root.
function TI.Scan(root)
    local ready, count = TI.ReadyQuests()
    local zones = TI.ZonesUnder(root)
    local found = TI.FindPoints(ready, zones)
    local missing = {}
    for qid, q in pairs(ready) do if not found[qid] then missing[#missing + 1] = q.title end end
    table.sort(missing)
    local d = TI.data
    d.ready, d.count, d.found, d.missing, d.zones, d.root = ready, count, found, missing, #zones, root
    d.at, d.rev = Now(), d.rev + 1
    TI.stats.scans = TI.stats.scans + 1
    dirty = false
end

-- The pins for a shown map: { x, y, quests = { { id, title, zone, index }, ... } }. Pure on its
-- arguments apart from the projection (tested).
function TI.PinsFor(mapID, ready, found)
    local spots = {}
    local ids = {}
    for qid in pairs(found) do if ready[qid] then ids[#ids + 1] = qid end end
    table.sort(ids)
    for _, qid in ipairs(ids) do
        local p = found[qid]
        local x, y = TI.Project(p.zone, p.x, p.y, mapID)
        if x then
            local q = ready[qid]
            local entry = { id = qid, title = q.title, index = q.index, zone = p.zone }
            local spot
            for _, s in ipairs(spots) do
                if s.zone == p.zone and math.abs(s.zx - p.x) <= SAME_SPOT and math.abs(s.zy - p.y) <= SAME_SPOT then
                    spot = s
                    break
                end
            end
            if spot then
                spot.quests[#spot.quests + 1] = entry
            else
                spots[#spots + 1] = { x = x, y = y, zone = p.zone, zx = p.x, zy = p.y, quests = { entry } }
            end
        end
    end
    return spots
end

-- ---------------------------------------------------------------------------
-- Pins on the world map canvas
-- ---------------------------------------------------------------------------

local pins, lastSig, driver, hooked = {}, nil, nil, false

local function OnEnter(self)
    local d, tip = self.data, _G.GameTooltip
    if not d or not tip then return end
    tip:SetOwner(self, "ANCHOR_RIGHT")
    for i, q in ipairs(d.quests) do
        if i == 1 then tip:SetText(q.title, 1, 0.82, 0) else tip:AddLine(" ") tip:AddLine(q.title, 1, 0.82, 0) end
        local zone = MapName(q.zone)
        if zone then tip:AddLine(zone, 1, 1, 1) end
        local text = q.index and Str(Call(API("GetQuestLogCompletionText"), q.index))
        if text then tip:AddLine(text, 0.8, 0.8, 0.8, true) end
    end
    tip:AddLine("Ready to turn in", 0.25, 1, 0.25)
    tip:Show()
end

local function OnLeave() if _G.GameTooltip then _G.GameTooltip:Hide() end end

-- Blizzard's turn-in "?" on a texture: the first atlas the client has, else the gossip texture.
function TI.SetIcon(tex)
    local getAtlas = API("C_Texture", "GetAtlasInfo")
    if getAtlas and type(tex.SetAtlas) == "function" then
        for _, name in ipairs(TI.ATLASES) do
            local info = Call(getAtlas, name)
            if not IsSecret(info) and type(info) == "table" and pcall(tex.SetAtlas, tex, name) then
                TI.icon = name
                return name
            end
        end
    end
    pcall(tex.SetTexture, tex, TI.FALLBACK_TEXTURE)
    TI.icon = TI.FALLBACK_TEXTURE
    return TI.FALLBACK_TEXTURE
end

local function BuildPin(canvas, i)
    local p = CreateFrame("Frame", nil, canvas)
    p.icon = p:CreateTexture(nil, "OVERLAY")
    p.icon:SetAllPoints(p)
    TI.SetIcon(p.icon)
    p:EnableMouse(true)
    -- Hover only, where the client can: clicks then still reach the map underneath.
    if p.SetMouseClickEnabled then pcall(p.SetMouseClickEnabled, p, false) end
    p:SetScript("OnEnter", OnEnter)
    p:SetScript("OnLeave", OnLeave)
    p:Hide()
    pins[i] = p
    return p
end

function TI.HideAll()
    for _, p in ipairs(pins) do p:Hide() end
    lastSig = nil
    TI.drawn.count, TI.drawn.quests = 0, 0
end

local function Canvas(map)
    local tp = ns.trackedPins
    if tp and tp.Canvas then return tp.Canvas(map) end
    local ok, c = pcall(function() return map:GetCanvas() end)
    if ok and type(c) == "table" then return c end
end

function TI.MarkDirty() dirty = true end

function TI.Draw()
    local map = core and core.GetMap and core.GetMap()
    if not settings or not settings.turnInPins or not map or not map:IsVisible() then
        if lastSig then TI.HideAll() end
        return
    end
    local canvas = Canvas(map)
    local mapID = Num(Call(map.GetMapID, map))
    local info = MapInfo(mapID)
    local mapType = info and Num(info.mapType)
    local w, h = canvas and Num(canvas:GetWidth()), canvas and Num(canvas:GetHeight())
    local zoom = canvas and Num(canvas:GetScale())
    TI.drawn.map, TI.drawn.mapType = mapID, mapType
    if not mapID or not mapType or not w or not h or not zoom or zoom <= 0 or not SHOW_TYPES[mapType] then
        if lastSig then TI.HideAll() end
        return
    end
    local d, now = TI.data, Now()
    local root = TI.RootOf(mapID)
    local stale = dirty or d.root ~= root or (#d.missing > 0 and now - d.at >= RETRY)
    if stale and (now - d.at >= THROTTLE or d.root ~= root) then TI.Scan(root) end
    local sig = table.concat({ mapID, w, h, zoom, d.rev }, ":")
    if sig == lastSig then return end
    lastSig = sig
    local list = TI.PinsFor(mapID, d.ready, d.found)
    local size = PIN_SIZE / zoom
    local level = (Num(canvas:GetFrameLevel()) or 0) + PIN_LEVEL
    local quests = 0
    for i, s in ipairs(list) do
        local p = pins[i] or BuildPin(canvas, i)
        if p:GetParent() ~= canvas then p:SetParent(canvas) end
        p.data = s
        p:SetSize(size, size)
        p:SetFrameLevel(level)
        p:ClearAllPoints()
        p:SetPoint("CENTER", canvas, "TOPLEFT", s.x * w, -s.y * h)
        p:Show()
        quests = quests + #s.quests
    end
    for i = #list + 1, #pins do pins[i]:Hide() end
    TI.drawn.count, TI.drawn.quests = #list, quests
end

local function SafeDraw()
    local ok, err = pcall(TI.Draw)
    if not ok then
        TI.stats.errors = TI.stats.errors + 1
        TI.stats.lastError = tostring(err)
    end
end

-- Our own frame inside the map (runs only while the map is open) and a follow-up on OnMapChanged.
function TI.HookMap()
    if hooked or not core or not core.GetMap then return hooked end
    local map = core.GetMap()
    if not map then return false end
    hooked = true
    local acc = 0
    driver = CreateFrame("Frame", nil, map)
    driver:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < TICK then return end
        acc = 0
        SafeDraw()
    end)
    driver:SetScript("OnShow", function() acc = TICK end)
    driver:SetScript("OnHide", function() TI.HideAll() end)
    if type(map.OnMapChanged) == "function" then hooksecurefunc(map, "OnMapChanged", SafeDraw) end
    return true
end

-- ---------------------------------------------------------------------------
-- Events, binding, settings, slash
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
TI.registered = {}
events:SetScript("OnEvent", function() dirty = true end)

-- Called by the main file at ADDON_LOADED, after GaarMapsForeverDB is bound.
function TI.Bind(settingsDb, c)
    settings, core = settingsDb, c
    if type(settings.turnInPins) ~= "boolean" then settings.turnInPins = true end
    for _, e in ipairs(TI.EVENTS) do TI.registered[e] = pcall(events.RegisterEvent, events, e) or nil end
    TI.HookMap()
    dirty = true
end

function TI.SetEnabled(on)
    if not settings then return end
    settings.turnInPins = on and true or false
    dirty = true
    if not settings.turnInPins then TI.HideAll() else SafeDraw() end
    if core and core.Print then
        core.Print("quest turn-in pins on the continent and world maps " .. OnOff(settings.turnInPins) .. ".")
    end
end

-- "turn-in pins: on, map 1414 (type 2): 3 shown (4 quests); ready to turn in: 5, no position: 1 (Title)"
function TI.StatusLine()
    local d, dr = TI.data, TI.drawn
    local missing = d.missing or {}
    local where
    if not dr.mapType then
        where = "map not open yet"
    elseif SHOW_TYPES[dr.mapType] then
        where = string.format("map %s (type %s): %d shown (%d quest%s)", tostring(dr.map), tostring(dr.mapType),
            dr.count or 0, dr.quests or 0, dr.quests == 1 and "" or "s")
    else
        where = string.format("map %s (type %s): none (zone map, Blizzard shows them)", tostring(dr.map), tostring(dr.mapType))
    end
    return string.format("turn-in pins: %s, %s; ready to turn in: %d, no position: %d%s; zones scanned: %d, icon: %s%s",
        OnOff(settings and settings.turnInPins), where, d.count or 0, #missing,
        #missing > 0 and (" (" .. table.concat(missing, ", ") .. ")") or "", d.zones or 0,
        tostring(TI.icon or "not drawn yet"),
        TI.stats.errors > 0 and ("; errors: " .. TI.stats.errors .. " (" .. tostring(TI.stats.lastError) .. ")") or "")
end

TI.HELP = {
    "/gmf turnins on | /gmf turnins off - a ? on the continent and world maps for every quest ready to turn in",
}

function TI.Slash(arg)
    arg = arg or ""
    if arg == "on" or arg == "off" then
        TI.SetEnabled(arg == "on")
    else
        if core and core.Print then
            core.Print(TI.StatusLine())
            for _, l in ipairs(TI.HELP) do core.Print(l) end
        end
    end
end
