-- LuaJIT stub test: GaarMapsForever TurnInPins.lua - ready quests from the log, their turn-in points from
-- C_QuestLog.GetQuestsOnMap on the zones of the tree, projection onto continent and world maps (rect, then
-- world position), continent/world only, shared spots, missing positions, refresh, on/off and status.
-- Run: luajit tools/test/maps_turnin_pins_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarMapsForever/TurnInPins.lua")); local src = fh:read("*a"); fh:close()

local fails = 0
local function eq(n, got, want)
    if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local function near(n, got, want)
    if type(got) ~= "number" or math.abs(got - want) > 1e-9 then
        fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want))
    end
end

-- ---- stubs -------------------------------------------------------------------------------------
local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
local function issecret(v) return v == SECRET end
local function Num(v) if issecret(v) or type(v) ~= "number" then return nil end return v end
local function Str(v) if issecret(v) or type(v) ~= "string" or v == "" then return nil end return v end
local function Bool(v) if issecret(v) then return nil end return v and true or false end
local BF = { IsSecret = issecret, Num = Num, Str = Str, Bool = Bool,
    API = function(a, b)
        if b == nil then local f = _G.__env[a]; return type(f) == "function" and f or nil end
        local t = _G.__env[a]; if type(t) ~= "table" then return nil end
        return type(t[b]) == "function" and t[b] or nil
    end,
    Call = function(fn, ...) if type(fn) ~= "function" then return end
        local r = { pcall(fn, ...) }; if r[1] then return unpack(r, 2) end end,
    OnOff = function(v) return v and "on" or "off" end }

local frames, registered, hooks = {}, {}, {}
local function NewFrame(_, _, parent)
    local f = { shown = false, parent = parent, scripts = {} }
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:RegisterEvent(e)
        if e == "QUEST_POI_UPDATE" then error("unknown event") end -- an event this client lacks
        registered[e] = true
    end
    function f:CreateTexture()
        return { SetAllPoints = function() end,
            SetTexture = function(t, v) t.tex = v end,
            SetAtlas = function(t, v) t.atlas = v end }
    end
    function f:EnableMouse() end
    function f:SetMouseClickEnabled(v) self.clicks = v end
    function f:Hide() self.shown = false end
    function f:Show() self.shown = true end
    function f:IsVisible() return true end
    function f:GetParent() return self.parent end
    function f:SetParent(p) self.parent = p end
    function f:SetSize(w) self.size = w end
    function f:SetFrameLevel() end
    function f:ClearAllPoints() end
    function f:SetPoint(_, _, _, x, y) self.x, self.y = x, y end
    frames[#frames + 1] = f
    return f
end

local now = 100
-- Quest log: header, two ready quests turned in at the same NPC, one ready quest with no point
-- anywhere, one in progress, one ready via the legacy flag only (no C_QuestLog.IsComplete for it).
local log = {
    { isHeader = true, title = "Elwynn Forest" },
    { questID = 11, title = "Wolves" },
    { questID = 12, title = "Kobolds" },
    { questID = 13, title = "Lost Letter" },
    { questID = 14, title = "Still Going" },
    { questID = 15, title = "Desert Run" },
    { questID = 16, title = "Over the Sea" },
}
local readyIds = { [11] = true, [12] = true, [13] = true, [15] = true, [16] = true }
local onMap = {
    [1429] = { { questID = 11, x = 0.42, y = 0.65 }, { questID = 12, x = 0.421, y = 0.651 },
               { questID = 14, x = 0.5, y = 0.5 },                               -- not ready: ignored
               { questID = 13, x = 0.9, y = 0.1, isMapIndicatorQuest = true } }, -- an edge arrow: ignored
    [1446] = { { questID = 15, x = 0.5, y = 0.5 } },
    [1453] = { { questID = 16, x = SECRET, y = 0.2 } },                           -- secret: no position
}
local maps = {
    [946] = { mapType = 0, name = "Cosmic" },
    [947] = { mapType = 1, name = "Azeroth", parentMapID = 946 },
    [1415] = { mapType = 2, name = "Eastern Kingdoms", parentMapID = 947 },
    [1414] = { mapType = 2, name = "Kalimdor", parentMapID = 947 },
    [1429] = { mapType = 3, name = "Elwynn Forest", parentMapID = 1415 },
    [1446] = { mapType = 3, name = "Tanaris", parentMapID = 1414 },
    [1453] = { mapType = 3, name = "Stormwind City", parentMapID = 1415 },
}
-- Elwynn's rect on EK and on Azeroth; Tanaris has no rect (world-position fallback on Kalimdor).
local rects = {
    ["1429:1415"] = { 0.4, 0.5, 0.7, 0.8 },
    ["1429:947"] = { 0.8, 0.85, 0.6, 0.65 },
}
local childCalls, onMapCalls = 0, 0
local env = {
    GetTime = function() return now end,
    CreateVector2D = function(x, y) return { x = x, y = y, GetXY = function(s) return s.x, s.y end } end,
    Enum = { UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3 } },
    C_QuestLog = {
        GetNumQuestLogEntries = function() return #log end,
        GetInfo = function(i) return log[i] end,
        ReadyForTurnIn = function(id) return id ~= 15 and readyIds[id] or false end,
        IsComplete = function(id) return readyIds[id] or false end,
        GetQuestsOnMap = function(m) onMapCalls = onMapCalls + 1; return onMap[m] or {} end,
    },
    GetQuestUiMapID = function(id) return id == 15 and 1446 or 1429 end,
    GetQuestLogCompletionText = function(i) return i == 2 and "Return to Marshal Dughan in Goldshire." or nil end,
    C_Texture = { GetAtlasInfo = function(n) if n == "UI-QuestIcon-TurnIn-Normal" then return { width = 32 } end end },
    C_Map = {
        GetMapInfo = function(id) return maps[id] end,
        GetMapChildrenInfo = function(root, mapType, all)
            childCalls = childCalls + 1
            local out = {}
            for id, m in pairs(maps) do
                if m.mapType == mapType and all then
                    local p = m.parentMapID
                    while p and p ~= root do p = maps[p] and maps[p].parentMapID end
                    if p == root then out[#out + 1] = { mapID = id, mapType = m.mapType, name = m.name } end
                end
            end
            table.sort(out, function(a, b) return a.mapID < b.mapID end)
            return out
        end,
        GetMapRectOnMap = function(m, top) local r = rects[m .. ":" .. top]; if r then return r[1], r[2], r[3], r[4] end end,
        GetWorldPosFromMapPos = function(m, v) if m == 1446 then return 1, { x = v.x * 1000, y = v.y * 1000 } end end,
        GetMapPosFromWorldPos = function(cont, v, override)
            if cont == 1 and override == 1414 then return 1414, { x = 0.6 + v.x / 10000, y = 0.8 + v.y / 10000 } end
            return nil
        end,
    },
}
_G.__env = env
local G = setmetatable({ GaarForever = BF, CreateFrame = NewFrame,
    hooksecurefunc = function(t, k, fn) hooks[#hooks + 1] = { t, k, fn } end }, {
    __index = function(_, k) if env[k] ~= nil then return env[k] end return _G[k] end })
G._G = G
local f = assert(loadstring(src, "TurnInPins")); setfenv(f, G)
local ns = {}
f("GaarMapsForever", ns)
local TI = ns.turnInPins
assert(TI, "module registers ns.turnInPins")
local events = frames[1]

-- ---- ready quests -----------------------------------------------------------------------------
local ready, count = TI.ReadyQuests()
eq("ready count", count, 5)
eq("header skipped", ready[0], nil)
eq("in progress skipped", ready[14], nil)
eq("IsComplete when not ReadyForTurnIn", ready[15] and ready[15].title, "Desert Run")
eq("log index kept", ready[11].index, 2)

-- ---- tree, zones, points ----------------------------------------------------------------------
eq("root of a continent", TI.RootOf(1415), 947)
eq("root of the world", TI.RootOf(947), 947)
local zones = TI.ZonesUnder(947)
eq("zones under the world", #zones, 3)
TI.ZonesUnder(947)
eq("zones cached", childCalls, 1)
local found = TI.FindPoints(ready, zones)
eq("wolves found", found[11] and found[11].zone, 1429)
near("wolves x", found[11].x, 0.42)
eq("tanaris found", found[15] and found[15].zone, 1446)
eq("map indicator ignored", found[13], nil)
eq("secret x ignored", found[16], nil)
eq("not ready ignored", found[14], nil)

-- ---- projection -------------------------------------------------------------------------------
local x, y = TI.Project(1429, 0.5, 0.5, 1415)
near("rect x", x, 0.45); near("rect y", y, 0.75)
x, y = TI.Project(1429, 0.5, 0.5, 947)
near("world rect x", x, 0.825)
x, y = TI.Project(1446, 0.5, 0.5, 1414)
near("world-pos fallback x", x, 0.65); near("world-pos fallback y", y, 0.85)
eq("not on that map", TI.Project(1446, 0.5, 0.5, 1415), nil)
eq("same map", TI.Project(1429, 0.3, 0.4, 1429), 0.3)

-- ---- pins for a map: shared spot, only what lands on the map ----------------------------------
local spots = TI.PinsFor(1415, ready, found)
eq("EK: one spot for the two Elwynn quests", #spots, 1)
eq("EK: both quests on it", #spots[1].quests, 2)
eq("EK: first quest", spots[1].quests[1].title, "Wolves")
spots = TI.PinsFor(1414, ready, found)
eq("Kalimdor: Tanaris only", #spots, 1)
eq("Kalimdor quest", spots[1].quests[1].id, 15)
eq("world: Elwynn only (Tanaris has no rect on it)", #TI.PinsFor(947, ready, found), 1)

-- ---- bind and draw ----------------------------------------------------------------------------
local settings = {}
local map = NewFrame(); map.mapID = 1415
function map:GetMapID() return self.mapID end
function map:OnMapChanged() end
local canvas = NewFrame()
function canvas:GetWidth() return 1000 end
function canvas:GetHeight() return 600 end
function canvas:GetScale() return 2 end
function canvas:GetFrameLevel() return 10 end
function map:GetCanvas() return canvas end
local printed = {}
TI.Bind(settings, { Print = function(m) printed[#printed + 1] = m end, GetMap = function() return map end })
eq("default on", settings.turnInPins, true)
eq("quest log event", registered.QUEST_LOG_UPDATE, true)
eq("turned in event", registered.QUEST_TURNED_IN, true)
eq("removed event", registered.QUEST_REMOVED, true)
eq("missing event survives", registered.QUEST_POI_UPDATE, nil)
eq("OnMapChanged hooked with hooksecurefunc", hooks[1] and hooks[1][2], "OnMapChanged")

TI.Draw()
eq("continent drawn", TI.drawn.count, 1)
eq("continent quests", TI.drawn.quests, 2)
local pin
for _, fr in ipairs(frames) do if fr.data and fr.shown then pin = fr end end
near("pin x on canvas", pin.x, (0.4 + 0.42 * 0.1) * 1000)
near("pin y on canvas", pin.y, -(0.7 + 0.65 * 0.1) * 600)
eq("pin size follows zoom", pin.size, 10)
eq("clicks pass through", pin.clicks, false)
eq("atlas used", pin.icon.atlas, "UI-QuestIcon-TurnIn-Normal")

-- zone map: nothing drawn by us
map.mapID = 1429
TI.Draw()
eq("zone map hides", TI.drawn.count, 0)
eq("zone map pin hidden", pin.shown, false)

-- world map
map.mapID = 947
TI.Draw()
eq("world drawn", TI.drawn.count, 1)

-- throttle: a quest event right away does not rescan; after a second it does
local scans = TI.stats.scans
readyIds[11], readyIds[12] = nil, nil -- turned in
events.scripts.OnEvent(events, "QUEST_TURNED_IN")
TI.Draw()
eq("throttled", TI.stats.scans, scans)
now = now + 1.5
TI.Draw()
eq("rescanned", TI.stats.scans, scans + 1)
eq("turned-in quest gone from the world map", TI.drawn.count, 0)

-- missing positions retried every few seconds while the map is open
eq("missing listed", #TI.data.missing, 2)
local calls = onMapCalls
now = now + 1.5
TI.Draw()
eq("no retry before RETRY", onMapCalls, calls)
now = now + 5
onMap[1453][1].x = 0.3 -- the client has the point now
TI.Draw()
eq("retry found it", TI.data.found[16] ~= nil, true)
eq("no position left besides the letter", #TI.data.missing, 1)

-- tooltip: name, zone, completion text
map.mapID = 1415
readyIds[11] = true
events.scripts.OnEvent(events, "QUEST_LOG_UPDATE")
now = now + 2
TI.Draw()
local tipLines = {}
G.GameTooltip = { SetOwner = function() end, SetText = function(_, t) tipLines[#tipLines + 1] = t end,
    AddLine = function(_, t) tipLines[#tipLines + 1] = t end, Show = function() end, Hide = function() end }
for _, fr in ipairs(frames) do if fr.data and fr.shown and fr.scripts.OnEnter then fr.scripts.OnEnter(fr) break end end
local tip = table.concat(tipLines, "|")
eq("tooltip title", tipLines[1], "Wolves")
eq("tooltip zone", tip:find("Elwynn Forest", 1, true) ~= nil, true)
eq("tooltip npc text", tip:find("Marshal Dughan", 1, true) ~= nil, true)

-- off / on, slash, status
TI.Slash("off")
eq("off saved", settings.turnInPins, false)
eq("off hides", TI.drawn.count, 0)
TI.Draw()
eq("off draws nothing", TI.drawn.count, 0)
TI.Slash("on")
eq("on saved", settings.turnInPins, true)
local line = TI.StatusLine()
eq("status has on", line:find("turn-in pins: on", 1, true) ~= nil, true)
eq("status has no position count", line:find("no position: 1 (Lost Letter)", 1, true) ~= nil, true)
eq("status shown", line:find("1 shown", 1, true) ~= nil, true)

-- fallback icon without the atlas
env.C_Texture = nil
local tex = { SetTexture = function(t, v) t.tex = v end, SetAtlas = function(t, v) t.atlas = v end }
TI.SetIcon(tex)
eq("fallback texture", tex.tex, TI.FALLBACK_TEXTURE)

if fails == 0 then print("maps_turnin_pins_test: ok") else os.exit(1) end
