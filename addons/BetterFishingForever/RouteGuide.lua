--[[
  BetterFishingForever - the Fishing 1-300 route (1.2): current step, pins and GPS arrow.

  Off by default; /bfish route on switches it on (per character). The data is in Route.lua
  (ns.route); this file reads it and exports ns.guide for BetterFishingForever.lua, which owns the
  slash command, the saved variables and the hub menu. No global is created here.

  Skill. Classic first: GetNumSkillLines / GetSkillLineInfo, scanned for the line whose name is
  the localized name of spell 7620 (or "Fishing"), giving the rank and the max rank (the cap).
  Where that finds nothing, the retail profession API: GetProfessions() (4th value = fishing)
  and GetProfessionInfo(index). Both are guarded; no Fishing at all reads as skill 0, cap 0. A
  collapsed "Secondary Skills" header in the skill window hides the line from GetSkillLineInfo;
  /bfish status says so.

  Steps. Only the player's faction (UnitFactionGroup) and "Both", in route order. A step is done:
    * with grants (trainers, the Expert book, the Artisan quest and its fish): once the cap is at
      least grants. Such a step can only be current while the skill sits at the cap (75/75 ->
      Journeyman trainer, 150/150 -> Expert book, 225/225 -> Nat Pagle), or with no Fishing yet.
    * a fish step: once the skill reaches its "to".
    * an optional vendor or quest step: once /bfish route next has skipped it (saved).
  The current step is the first step that is not done and whose range holds the skill (from <=
  skill < to), unless /bfish route next|prev picked another one: that choice holds until the
  automatic step changes (a skill-up past it, a new rank), then it is dropped.

  Pins: the current step's spots (or its NPC) on the world map, when that map or a map that holds
  it (the continent) is shown, and on the minimap within its radius, with a tooltip. Drawn the
  way BetterGpsForever draws its pins: our own frames, children of the map canvas and of the
  minimap, placed by normalised coordinates (C_Map world positions for the conversion and the
  minimap offset). No library.

  GPS: with BetterGpsForever loaded, BetterGpsForeverAPI.SetWaypoint(mapID, x, y, title) points
  its arrow at the nearest spot of the current step (same continent; else the first one). Only
  when the step changes (and at /bfish route on): a waypoint the user sets is kept until then.
  Switching the route off clears the waypoint only while it is still ours.

  Taint: no Blizzard function or table is written. hooksecurefunc on WorldMapFrame.OnMapChanged
  and plain frames of our own; every API is checked with type(...) == "function" and called in
  pcall; a secret value is treated as no value, never compared or tested.
]]

local _, ns = ...
if type(ns) ~= "table" then return end
local _G = _G
local DOT = " \194\183 "

local TICK = 0.1                  -- seconds between minimap pin updates while the route is on
local MAP_TICK = 0.1              -- seconds between world map pin updates while the map is open
local PIN_SIZE = 18               -- world map pin, screen units at any zoom
local MINIMAP_PIN_SIZE = 14
local ICON_SPOT = "Interface\\Icons\\Trade_Fishing"
local ICON_KIND = {
    trainer = "Interface\\Icons\\INV_Misc_Book_11",
    quest = "Interface\\GossipFrame\\AvailableQuestIcon",
    vendor = "Interface\\Icons\\INV_Misc_Coin_01",
}
local KIND_TEXT = { trainer = "Trainer", quest = "Quest", vendor = "Vendor" }
local MINIMAP_RADIUS = {
    outdoor = { [0] = 233.33, [1] = 200, [2] = 166.67, [3] = 133.33, [4] = 100, [5] = 66.67 },
    indoor = { [0] = 150, [1] = 120, [2] = 90, [3] = 60, [4] = 40, [5] = 25 },
}

local guide = {}
ns.guide = guide

local cdb                 -- BetterFishingForeverCharDB.route, bound by Bind() at ADDON_LOADED
local started             -- PLAYER_LOGIN seen
local steps = {}          -- the faction's steps, in route order
local faction             -- "Alliance", "Horde" or nil (unknown: every step)
local skill, cap, skillFrom -- the last read, and where it came from
local currentIndex        -- index into steps of the current step, nil when the route is done
local shownId             -- the step last announced, so a change prints once
local lastError
local worldPins, minimapPins = {}, {}
local ticker, mapDriver, mapHooked
local spotCache           -- world positions of the current step's pins

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The shared library (BetterForever's Lib.lua, loaded first through ## Dependencies). This file
-- loads before BetterFishingForever.lua, so it makes the addon object both share (ns.addon).
local BF = _G.BetterForever
local A = ns.addon or BF.NewAddon("BetterFishingForever")
ns.addon = A
local Secret, Num, Str, Bool = BF.IsSecret, BF.Num, BF.Str, BF.Bool
local Call, Method, API = BF.Call, BF.Method, BF.API

local function Print(msg) A:Print(msg) end

local function Fail(where, err)
    lastError = where .. ": " .. tostring(err)
end

local function Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Fail(where, err) end
end

local function Vec(x, y)
    local v = Call(_G.CreateVector2D, x, y)
    if type(v) == "table" then return v end
    return { x = x, y = y }
end

local function XY(v)
    if Secret(v) or type(v) ~= "table" then return nil end
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

local function On()
    return cdb ~= nil and cdb.on == true
end

local function Gps()
    local api = _G.BetterGpsForeverAPI
    if type(api) == "table" and type(api.SetWaypoint) == "function" then return api end
end

-- ---------------------------------------------------------------------------
-- Fishing skill and cap
-- ---------------------------------------------------------------------------

local function SpellName(spell)
    local c = _G.C_Spell
    if type(c) == "table" and type(c.GetSpellInfo) == "function" then
        local ok, info = pcall(c.GetSpellInfo, spell)
        if ok and type(info) == "table" and Str(info.name) then return info.name end
    end
    return Str(Call(_G.GetSpellInfo, spell))
end

-- skill, cap, source; nil when Fishing cannot be read on this client.
local function ReadSkill()
    local name = SpellName(7620) or "Fishing"
    local numLines, lineInfo = _G.GetNumSkillLines, _G.GetSkillLineInfo
    if type(numLines) == "function" and type(lineInfo) == "function" then
        local n = Num(Call(numLines)) or 0
        local collapsed = false
        for i = 1, n do
            local sName, isHeader, isExpanded, rank, _, _, maxRank = Call(lineInfo, i)
            sName = Str(sName)
            if Bool(isHeader) then
                if Bool(isExpanded) == false then collapsed = true end
            elseif sName and (sName == name or sName == "Fishing") then
                rank, maxRank = Num(rank), Num(maxRank)
                if rank then return rank, maxRank or rank, "skill lines" end
            end
        end
        -- Skill lines but no Fishing: not learned, unless a collapsed header may hide it.
        if n > 0 and not collapsed and type(_G.GetProfessions) ~= "function" then
            return 0, 0, "skill lines (no Fishing)"
        end
    end
    if type(_G.GetProfessions) == "function" and type(_G.GetProfessionInfo) == "function" then
        local _, _, _, fishing = Call(_G.GetProfessions)
        fishing = Num(fishing)
        if fishing then
            local _, _, level, maxLevel = Call(_G.GetProfessionInfo, fishing)
            level, maxLevel = Num(level), Num(maxLevel)
            if level then return level, maxLevel or level, "GetProfessionInfo" end
        else
            return 0, 0, "GetProfessions (no Fishing)"
        end
    end
    return nil, nil, nil
end

-- ---------------------------------------------------------------------------
-- Steps
-- ---------------------------------------------------------------------------

local function BuildSteps()
    steps = {}
    local f = Str(Call(_G.UnitFactionGroup, "player"))
    faction = (f == "Alliance" or f == "Horde") and f or nil
    local data = ns.route and ns.route.steps
    if type(data) ~= "table" then return end
    for _, s in ipairs(data) do
        if s.faction == "Both" or not faction or s.faction == faction then steps[#steps + 1] = s end
    end
end

local function IndexOf(id)
    if not id then return nil end
    for i, s in ipairs(steps) do
        if s.id == id then return i end
    end
end

local function Skipped(step)
    return cdb and type(cdb.skipped) == "table" and cdb.skipped[step.id] == true
end

local function Done(step, sk, cp)
    if step.grants then return cp >= step.grants end
    if step.kind == "fish" then return sk >= step.to end
    return Skipped(step) or sk >= step.to
end

local function Eligible(step, sk, cp)
    if Done(step, sk, cp) then return false end
    if step.grants then return sk >= cp end
    return sk >= step.from and sk < step.to
end

local function AutoIndex()
    if not skill then return nil end
    for i, s in ipairs(steps) do
        if Eligible(s, skill, cap) then return i end
    end
end

-- Works out the current step. Returns it (or nil when the route is done / unknown).
local function Compute()
    skill, cap, skillFrom = ReadSkill()
    if skill then cap = math.max(cap or 0, skill) end
    local auto = AutoIndex()
    local autoId = auto and steps[auto].id or "done"
    if cdb and cdb.manual then
        local m = IndexOf(cdb.manual)
        if not m or (skill and cdb.manualAuto ~= autoId) then
            cdb.manual, cdb.manualAuto = nil, nil
        else
            currentIndex = m
            return steps[m], autoId
        end
    end
    -- An unreadable skill (loading, a collapsed header) keeps the step shown before.
    if skill then currentIndex = auto else currentIndex = IndexOf(shownId) end
    return currentIndex and steps[currentIndex], autoId
end

local function Current()
    return currentIndex and steps[currentIndex]
end

local function Pins(step)
    local list = {}
    if not step or not MapID(step.mapID) then return list end
    if type(step.spots) == "table" and #step.spots > 0 then
        for _, sp in ipairs(step.spots) do
            list[#list + 1] = { x = sp.x / 100, y = sp.y / 100, src = sp.src, icon = ICON_SPOT }
        end
    elseif Num(step.x) and Num(step.y) then
        list[1] = { x = step.x / 100, y = step.y / 100,
            icon = step.kind == "fish" and ICON_SPOT or (ICON_KIND[step.kind] or ICON_SPOT) }
    end
    return list
end

local function SkillText()
    if not skill then return "unknown" end
    return string.format("%d/%d", skill, cap or skill)
end

-- ---------------------------------------------------------------------------
-- Positions (as BetterGpsForever works them out)
-- ---------------------------------------------------------------------------

local function WorldPos(mapID, x, y)
    local cont, pos = Call(API("C_Map", "GetWorldPosFromMapPos"), mapID, Vec(x, y))
    cont = Num(cont)
    local wx, wy = XY(pos)
    if cont and wx then return cont, wx, wy end
end

local function PlayerWorld()
    if Bool(Call(_G.IsInInstance)) then return nil end
    local m = MapID(Call(API("C_Map", "GetBestMapForUnit"), "player"))
    if not m then return nil end
    local px, py = XY(Call(API("C_Map", "GetPlayerMapPosition"), m, "player"))
    if not px or (px == 0 and py == 0) then return nil end
    return WorldPos(m, px, py)
end

-- World positions of the current step's pins, worked out once per step.
local function SpotWorld(step, pins)
    if spotCache and spotCache.id == step.id then return spotCache end
    local c = { id = step.id }
    for i, p in ipairs(pins) do
        local cont, wx, wy = WorldPos(step.mapID, p.x, p.y)
        if cont then c[i] = { cont = cont, x = wx, y = wy } end
    end
    spotCache = c
    return c
end

-- ---------------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------------

local function ShowTooltip(frame)
    local tip = _G.GameTooltip
    local step = Current()
    if type(tip) ~= "table" or not step or not frame.pin then return end
    Method(tip, "SetOwner", frame, "ANCHOR_RIGHT")
    Method(tip, "AddLine", step.title, 1, 0.82, 0)
    if step.npc then
        Method(tip, "AddLine", (KIND_TEXT[step.kind] or "NPC") .. ": " .. step.npc, 1, 1, 1)
    end
    if step.note then Method(tip, "AddLine", step.note, 0.9, 0.9, 0.9, true) end
    local p = frame.pin
    Method(tip, "AddLine", string.format("%s %.1f, %.1f%s", step.zone or "", p.x * 100, p.y * 100,
        p.src and ("  (" .. p.src .. ")") or ""), 0.6, 0.6, 0.6)
    Method(tip, "Show")
end

local function HideTooltip()
    Method(_G.GameTooltip, "Hide")
end

local function NewPin(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:EnableMouse(true)
    local tex = f:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(f)
    f.tex = tex
    f:SetScript("OnEnter", function(self) Safe("tooltip", ShowTooltip, self) end)
    f:SetScript("OnLeave", HideTooltip)
    -- Hover only: clicks go on to the map or minimap underneath where the client allows it.
    if type(f.SetPropagateMouseClicks) == "function" then pcall(f.SetPropagateMouseClicks, f, true) end
    f:Hide()
    return f
end

local function SetPinIcon(f, icon)
    if f.icon == icon then return end
    f.icon = icon
    f.tex:SetTexture(icon)
    if icon:find("Interface\\Icons\\", 1, true) then
        f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        f.tex:SetTexCoord(0, 1, 0, 1)
    end
end

local function HideAll(list)
    for _, f in ipairs(list) do f:Hide() end
end

-- ---------------------------------------------------------------------------
-- World map pins
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

local mapPosCache = {}     -- "<stepId>:<mapID>:<i>" -> { x, y } or false
local function PinOnMap(step, i, pin, world, mapID)
    if mapID == step.mapID then return pin.x, pin.y end
    local key = step.id .. ":" .. mapID .. ":" .. i
    local c = mapPosCache[key]
    if c == nil then
        c = false
        local w = world[i]
        if w then
            local id, pos = Call(API("C_Map", "GetMapPosFromWorldPos"), w.cont, Vec(w.x, w.y), mapID)
            local x, y = XY(pos)
            if MapID(id) == mapID and x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                c = { x = x, y = y }
            end
            mapPosCache[key] = c
        end
    end
    if c then return c.x, c.y end
end

local function DrawWorldPins()
    local map, canvas = GetMap(), Canvas()
    local step = On() and Current()
    if not step or not map or not canvas or not Bool(Method(map, "IsVisible")) then
        HideAll(worldPins)
        return
    end
    local mapID = MapID(Method(map, "GetMapID"))
    local w, h = Num(Method(canvas, "GetWidth")), Num(Method(canvas, "GetHeight"))
    local zoom = Num(Method(canvas, "GetScale"))
    local pins = Pins(step)
    if not mapID or not w or not h or not zoom or zoom <= 0 or #pins == 0 then
        HideAll(worldPins)
        return
    end
    local world = SpotWorld(step, pins)
    local size = PIN_SIZE / zoom
    local level = (Num(Method(canvas, "GetFrameLevel")) or 0) + 510
    local used = 0
    for i, pin in ipairs(pins) do
        local x, y = PinOnMap(step, i, pin, world, mapID)
        if x then
            used = used + 1
            local f = worldPins[used]
            if not f then
                f = NewPin(canvas)
                worldPins[used] = f
            end
            if f:GetParent() ~= canvas then f:SetParent(canvas) end
            SetPinIcon(f, pin.icon)
            f.pin = pin
            f:SetSize(size, size)
            f:SetFrameLevel(level)
            f:ClearAllPoints()
            f:SetPoint("CENTER", canvas, "TOPLEFT", x * w, -y * h)
            f:Show()
        end
    end
    for i = used + 1, #worldPins do worldPins[i]:Hide() end
end

local mapAcc = 0
local function MapTick(_, elapsed)
    mapAcc = mapAcc + (Num(elapsed) or 0)
    if mapAcc < MAP_TICK then return end
    mapAcc = 0
    Safe("world map pins", DrawWorldPins)
end

local function HookMap()
    if mapHooked then return end
    local map = GetMap()
    if not map then return end
    mapHooked = true
    if type(map.OnMapChanged) == "function" and type(_G.hooksecurefunc) == "function" then
        _G.hooksecurefunc(map, "OnMapChanged", function() Safe("world map pins", DrawWorldPins) end)
    end
    -- Our own frame inside the map: it only runs while the map is open.
    mapDriver = CreateFrame("Frame", nil, map)
    mapDriver:SetScript("OnUpdate", MapTick)
    mapDriver:SetScript("OnShow", function() mapAcc = MAP_TICK end)
end

-- ---------------------------------------------------------------------------
-- Minimap pins
-- ---------------------------------------------------------------------------

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

local function DrawMinimapPins()
    local mm = _G.Minimap
    local step = On() and Current()
    if type(mm) ~= "table" or not step or not Bool(Method(mm, "IsVisible")) then
        HideAll(minimapPins)
        return
    end
    local pins = Pins(step)
    local pc, px, py = PlayerWorld()
    local half = (Num(Method(mm, "GetWidth")) or 0) / 2
    if #pins == 0 or not pc or half <= 0 then
        HideAll(minimapPins)
        return
    end
    local world = SpotWorld(step, pins)
    local radius = MinimapRadius(mm)
    local rotating = RotatingMinimap()
    local facing = rotating and Num(Call(_G.GetPlayerFacing)) or nil
    local square = Str(Call(_G.GetMinimapShape)) == "SQUARE"
    local limit = half - MINIMAP_PIN_SIZE / 2
    local used = 0
    for i, pin in ipairs(pins) do
        local wp = world[i]
        if wp and wp.cont == pc and (facing or not rotating) then
            local north, east = wp.x - px, -(wp.y - py)
            local sx, sy = east, north
            if rotating then
                local c, s = math.cos(facing), math.sin(facing)
                sx, sy = east * c + north * s, -east * s + north * c
            end
            local ox, oy = sx / radius * half, sy / radius * half
            local reach = square and math.max(math.abs(ox), math.abs(oy)) or math.sqrt(ox * ox + oy * oy)
            if reach <= limit then
                used = used + 1
                local f = minimapPins[used]
                if not f then
                    f = NewPin(mm)
                    f:SetSize(MINIMAP_PIN_SIZE, MINIMAP_PIN_SIZE)
                    f:SetFrameLevel((Num(Method(mm, "GetFrameLevel")) or 0) + 7)
                    minimapPins[used] = f
                end
                SetPinIcon(f, pin.icon)
                f.pin = pin
                f:ClearAllPoints()
                f:SetPoint("CENTER", mm, "CENTER", ox, oy)
                f:Show()
            end
        end
    end
    for i = used + 1, #minimapPins do minimapPins[i]:Hide() end
end

local acc = 0
local function Tick(_, elapsed)
    acc = acc + (Num(elapsed) or 0)
    if acc < TICK then return end
    acc = 0
    Safe("minimap pins", DrawMinimapPins)
end

local function RefreshPins()
    mapPosCache = {}
    spotCache = nil
    if not ticker then ticker = CreateFrame("Frame") end
    if On() and #Pins(Current()) > 0 then
        ticker:SetScript("OnUpdate", Tick)
        acc = TICK
    else
        ticker:SetScript("OnUpdate", nil)
        HideAll(minimapPins)
    end
    if On() then HookMap() end
    Safe("world map pins", DrawWorldPins)
end

-- ---------------------------------------------------------------------------
-- GPS (BetterGpsForever)
-- ---------------------------------------------------------------------------

local function OurWaypoint(api)
    local w = cdb and cdb.wp
    if type(w) ~= "table" or type(api.GetWaypoint) ~= "function" then return false end
    local mapID, x, y = Call(api.GetWaypoint)
    mapID, x, y = Num(mapID), Num(x), Num(y)
    return mapID ~= nil and mapID == w.mapID and x ~= nil and y ~= nil
        and math.abs(x - w.x) < 1e-6 and math.abs(y - w.y) < 1e-6
end

local function ClearOurWaypoint()
    local api = Gps()
    if api and OurWaypoint(api) and type(api.ClearWaypoint) == "function" then Call(api.ClearWaypoint) end
    if cdb then cdb.wp = nil end
end

-- Points the arrow at the nearest pin of the step (same continent), else its first pin.
local function PointAt(step)
    local api = Gps()
    if not api or not step then return end
    local pins = Pins(step)
    if #pins == 0 then
        ClearOurWaypoint()
        return
    end
    local best = pins[1]
    local pc, px, py = PlayerWorld()
    if pc then
        local world = SpotWorld(step, pins)
        local bestD
        for i, pin in ipairs(pins) do
            local w = world[i]
            if w and w.cont == pc then
                local d = (w.x - px) ^ 2 + (w.y - py) ^ 2
                if not bestD or d < bestD then best, bestD = pin, d end
            end
        end
    end
    if Call(api.SetWaypoint, step.mapID, best.x, best.y, step.title) then
        cdb.wp = { mapID = step.mapID, x = best.x, y = best.y }
    end
end

-- ---------------------------------------------------------------------------
-- Recompute
-- ---------------------------------------------------------------------------

-- force: re-point the arrow even if this step was pointed at before (route on, next, prev).
local function Update(force, announce)
    if not cdb or not started then return end
    local step = Compute()
    -- An unreadable skill changes nothing: no line, no new waypoint (unless asked for by hand).
    if skill or force then
        local id = step and step.id or "done"
        local changed = id ~= shownId
        if On() then
            if changed and (shownId ~= nil or announce) then
                Print("Fishing route: " .. (step and step.title
                    or (skill and "done, Fishing is at 300. /bfish route off to switch it off."
                        or "no step: the Fishing skill could not be read.")))
            end
            if force or cdb.pointed ~= id then
                cdb.pointed = id
                if step then PointAt(step) else ClearOurWaypoint() end
            end
        end
        shownId = id
    end
    RefreshPins()
end

-- ---------------------------------------------------------------------------
-- Commands (called by /bfish route ...)
-- ---------------------------------------------------------------------------

local function StepLine(i, s, mark)
    return string.format("%s%d. %s", mark or "", i, s.title)
end

local function PrintRoute()
    local step = Current()
    Print("Fishing skill " .. SkillText() .. (On() and "" or "   (the route is off: /bfish route on)"))
    if not step then
        Print(skill and "route done: nothing left below 300." or "no step: the Fishing skill could not be read.")
        return
    end
    Print(string.format("step %d of %d: %s", currentIndex, #steps, step.title))
    if step.npc then Print((KIND_TEXT[step.kind] or "NPC") .. ": " .. step.npc
        .. (Num(step.x) and string.format(" (%.1f, %.1f)", step.x, step.y) or "")) end
    if step.note then Print(step.note) end
    local nxt = steps[currentIndex + 1]
    if nxt then Print("next: " .. nxt.title) end
end

local function PrintList()
    Print(string.format("route for %s (%d steps), skill %s:", faction or "both factions", #steps, SkillText()))
    for i, s in ipairs(steps) do
        local mark = (i == currentIndex) and "|cff33ff99> " or "  "
        local done = skill and Done(s, skill, cap) and " (done)" or ""
        Print(StepLine(i, s, mark) .. done .. (i == currentIndex and "|r" or ""))
    end
end

local function PrintGear()
    local gear = ns.route and ns.route.gear
    if type(gear) ~= "table" then return end
    for _, g in ipairs(gear) do Print(g.name .. " - " .. g.how) end
end

local function Move(delta)
    Compute()
    local step = Current()
    if delta > 0 then
        if not step then
            Print("the route is done.")
            return
        end
        if step.optional and currentIndex == AutoIndex() then
            -- Skipping an optional vendor or quest step for good.
            cdb.skipped[step.id] = true
            cdb.manual, cdb.manualAuto = nil, nil
            Update(true, true)
            return
        end
        local target = steps[(currentIndex or 0) + 1]
        if not target then
            Print("this is the last step.")
            return
        end
        local _, autoId = Compute()
        cdb.manual, cdb.manualAuto = target.id, autoId
    else
        local target = steps[(currentIndex or (#steps + 1)) - 1]
        if not target then
            Print("this is the first step.")
            return
        end
        cdb.skipped[target.id] = nil
        cdb.manual = nil
        local _, autoId = Compute()
        cdb.manual, cdb.manualAuto = target.id, autoId
    end
    Update(true, true)
    if not On() then PrintRoute() end
end

function guide.SetOn(on, quiet)
    if not cdb then return end
    cdb.on = on and true or false
    if on then
        shownId = nil
        if not quiet then Print("fishing route on.") end
        Update(true, true)
        if not Gps() and not quiet then
            Print("BetterGpsForever is not loaded: pins on the map and minimap only, no arrow.")
        end
    else
        ClearOurWaypoint()
        cdb.pointed = nil
        RefreshPins()
        if not quiet then Print("fishing route off.") end
    end
end

function guide.IsOn() return On() end

function guide.Slash(arg)
    if not cdb then
        Print("not loaded yet.")
        return
    end
    local cmd = (arg or ""):lower():match("^(%S*)")
    if cmd == "on" or cmd == "off" then
        guide.SetOn(cmd == "on")
    elseif cmd == "next" then
        Move(1)
    elseif cmd == "prev" or cmd == "back" then
        Move(-1)
    elseif cmd == "list" then
        Compute()
        PrintList()
    elseif cmd == "gear" then
        PrintGear()
    elseif cmd == "" then
        Compute()
        PrintRoute()
    else
        Print("/bfish route [on | off | next | prev | list | gear]")
    end
end

function guide.HelpLines()
    return {
        "/bfish route on | off - the Fishing 1-300 route: pins on the map and minimap, the GPS arrow (BetterGpsForever)",
        "/bfish route - the current step and the next one; /bfish route next | prev - move by hand (next skips an optional vendor or quest step)",
        "/bfish route list - all steps for your faction; /bfish route gear - poles and lures worth having",
    }
end

function guide.StatusLines()
    if not cdb then return { "route: not loaded yet" } end
    if started then Compute() end
    local step = Current()
    local where = skillFrom or "not readable"
    local lines = {
        "route: " .. (On() and "on" or "off") .. "   skill: " .. SkillText() .. " (" .. where .. ")"
            .. "   faction: " .. (faction or "unknown, all steps"),
        "route step: " .. (step and string.format("%d/%d %s", currentIndex, #steps, step.title) or (skill and "done" or "none"))
            .. (cdb.manual and " (picked by hand)" or "")
            .. "   GPS: " .. (Gps() and "BetterGpsForever" or "BetterGpsForever not loaded (pins only)"),
    }
    if not skill then
        lines[#lines + 1] = "route: Fishing not found in the skill list; is the Secondary Skills header collapsed in the skill window?"
    end
    if lastError then lines[#lines + 1] = "route last error: " .. lastError end
    return lines
end

-- A short piece for the hub's status line.
function guide.StatusText()
    if not On() then return nil end
    local step = Current()
    return "route " .. SkillText() .. (step and "" or " done")
end

-- Bound from BetterFishingForever.lua at ADDON_LOADED with BetterFishingForeverCharDB.
function guide.Bind(charDb)
    local r = type(charDb.route) == "table" and charDb.route or {}
    local skipped = {}
    if type(r.skipped) == "table" then
        for k, v in pairs(r.skipped) do
            if type(k) == "string" and v == true then skipped[k] = true end
        end
    end
    local wp = r.wp
    if type(wp) == "table" and Num(wp.mapID) and Num(wp.x) and Num(wp.y) then
        wp = { mapID = wp.mapID, x = wp.x, y = wp.y }
    else
        wp = nil
    end
    cdb = {
        on = r.on == true,
        skipped = skipped,
        manual = Str(r.manual),
        manualAuto = Str(r.manualAuto),
        pointed = Str(r.pointed),
        wp = wp,
    }
    charDb.route = cdb
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
for _, e in ipairs({ "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL", "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB" }) do
    pcall(events.RegisterEvent, events, e)  -- an event this client does not know raises an error
end
events:SetScript("OnEvent", function(_, event)
    local ok, err = pcall(function()
        if event == "PLAYER_LOGIN" then
            started = true
            BuildSteps()
            Update(false, false)
        elseif started then
            if event == "PLAYER_ENTERING_WORLD" then spotCache = nil end
            Update(false, false)
        end
    end)
    if not ok then Fail(event, err) end
end)
