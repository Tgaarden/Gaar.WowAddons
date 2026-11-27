--[[
  GaarMapsForever - TrackedPins.lua (1.6.0): town NPCs on the world map, for the tracking types the
  minimap's tracking menu has checked (setting trackedPins, /gmf pins on|off).

    * Which icons. Exactly the types checked in the minimap tracking menu: C_Minimap.GetNumTrackingTypes
      and GetTrackingInfo (the table the 12.x engine gives, or the old name, texture, active), read again
      on MINIMAP_UPDATE_TRACKING and at most once a second while the map is drawn. Each type is matched
      to a category by C_Minimap.GetTrackingFilter's filterID (Enum.MinimapTrackingFilter, by name), else
      by its name (the client's MINIMAP_TRACKING_* strings, then enUS), else by the file name of its
      texture. The pin uses the tracking type's own texture. Types that match no category are listed in
      /gmf status.
    * When. Only while the world map shows a single zone: map type Zone (3), Dungeon (4) or Micro (5).
      Never on a continent, world or cosmic map, wherever the player stands.
    * Learning (self-learned, account-wide). When the player opens an NPC's window the player's own map
      position is stored (C_Map.GetBestMapForUnit + GetPlayerMapPosition; you stand next to the NPC):
        MERCHANT_SHOW            vendor; repair if CanMerchantRepair(); food, reagent, ammo or poison
                                 when at least 40 % of the goods are of that kind (GetItemInfoInstant)
        BANKFRAME_OPENED         banker
        AUCTION_HOUSE_SHOW       auctioneer
        TAXIMAP_OPENED           flight master
        TRAINER_SHOW             class trainer, or profession trainer (IsTradeskillTrainer; else the
                                 NPC's tooltip naming a class)
        MAIL_SHOW                mailbox (an object: no name or id, the player's position)
        CONFIRM_BINDER, GOSSIP_SHOW with a "make this inn your home" option    innkeeper
        PET_STABLE_SHOW          stable master
        BATTLEFIELDS_SHOW        battlemaster (only while an NPC is being talked to)
        PLAYER_INTERACTION_MANAGER_FRAME_SHOW   the same, by Enum.PlayerInteractionType name, for a
                                 client that only sends that one; the same NPC within 2 s counts once
      Name from UnitName("npc") (else a non-player target), NPC id from UnitGUID("npc") when it is not
      secret. Every client value goes through Num/Str/Bool (secret values count as missing).
    * Storage: GaarMapsForeverNPCDB (its own SavedVariables, account-wide, shared by all characters):
        { version = 1, maps = { [uiMapID] = { { x, y, name, id, c = { repair = true, ... }, n, t }, ... } } }
      x, y are 0-1, rounded to 4 decimals. One entry per NPC id per map; without an id, the same name
      within 3 % of the map, and for objects (mailbox) a shared category within 1.2 %. A repeat visit
      averages the position (weight capped at 10), adds categories and counts n.
    * Bundled data (later, read-only): TP.AddSource(name, data) or ns.trackedPinsBundled before load,
      data = { [uiMapID] = { { id =, x =, y =, name =, c = "repair vendor" | { "repair" } | { repair = true } },
      ... } } (also positional { id, x, y, c, name }; x, y may be 0-1 or 0-100). Merged per map at draw
      time, never written: a bundled row that matches a learned one (same id, same name nearby, or a
      shared category nearby) is dropped and only adds its categories to the learned pin. Learned wins.
    * Pins are plain frames of our own on the map canvas (as GaarGpsForever's places): no Blizzard pin,
      data provider or function is touched; the only hook is hooksecurefunc on the map's OnMapChanged,
      plus our own frame's OnUpdate while the map is open. Hover shows name and categories; clicks go
      through to the map where the client lets a frame take hover without clicks.
    * /gmf pins (status), /gmf pins on|off, /gmf pins clear (then /gmf pins clear yes) forgets the
      learned places.
]]

local _G = _G
local _, ns = ...
ns = type(ns) == "table" and ns or {}

local TP = {}
ns.trackedPins = TP

local BF = _G.GaarForever
local IsSecret, Num, Str, Bool = BF.IsSecret, BF.Num, BF.Str, BF.Bool
local Call, API, OnOff = BF.Call, BF.API, BF.OnOff

local PIN_SIZE = 16          -- screen units at any zoom
local PIN_LEVEL = 470        -- above the canvas; GaarGps places are at 490, its waypoint at 500
local NEAR_OBJECT = 0.012    -- nameless (mailbox) or bundled row: same category this close is the same place
local NEAR_NAME = 0.03       -- same name without a matching id this close is the same NPC
local TICK = 0.2             -- seconds between redraw checks while the map is open
local TRACK_TTL = 1          -- seconds a tracking read is reused
local DEBOUNCE = 2           -- the same NPC and category within this many seconds counts once
local SHARE = 0.4            -- share of a merchant's goods that makes it a food / reagent / ammo / poison vendor
local SHOW_TYPES = { [3] = true, [4] = true, [5] = true } -- Enum.UIMapType Zone, Dungeon, Micro

-- Order is the pin priority: an NPC with several tracked categories shows the first one's icon.
-- names: enUS tracking names; globals: the client's own strings; tex: file name of the tracking texture;
-- filters: Enum.MinimapTrackingFilter keys.
TP.CATEGORIES = {
    { key = "mailbox", label = "Mailbox", names = { "Mailbox" }, tex = "mailbox",
      filters = { "Mailbox" }, globals = { "MINIMAP_TRACKING_MAILBOX" } },
    { key = "flightmaster", label = "Flight Master", names = { "Flight Master", "Flight Masters" }, tex = "flightmaster",
      filters = { "TaxiNode" }, globals = { "MINIMAP_TRACKING_FLIGHTMASTER" } },
    { key = "innkeeper", label = "Innkeeper", names = { "Innkeeper" }, tex = "innkeeper",
      filters = { "Innkeeper" }, globals = { "MINIMAP_TRACKING_INNKEEPER" } },
    { key = "banker", label = "Banker", names = { "Banker" }, tex = "banker",
      filters = { "Banker" }, globals = { "MINIMAP_TRACKING_BANKER" } },
    { key = "auctioneer", label = "Auctioneer", names = { "Auctioneer" }, tex = "auctioneer",
      filters = { "Auctioneer" }, globals = { "MINIMAP_TRACKING_AUCTIONEER" } },
    { key = "classtrainer", label = "Class Trainer", names = { "Class Trainer", "Class Trainers" }, tex = "class",
      filters = { "TrainerClass" }, globals = { "MINIMAP_TRACKING_TRAINER_CLASS" } },
    { key = "proftrainer", label = "Profession Trainer", names = { "Profession Trainers", "Profession Trainer" },
      tex = "profession", filters = { "TrainerProfession" }, globals = { "MINIMAP_TRACKING_TRAINER_PROFESSION" } },
    { key = "stablemaster", label = "Stable Master", names = { "Stable Master" }, tex = "stablemaster",
      filters = { "Stablemaster", "StableMaster" }, globals = { "MINIMAP_TRACKING_STABLEMASTER" } },
    { key = "battlemaster", label = "Battlemaster", names = { "Battlemaster", "Battle Master" }, tex = "battlemaster",
      filters = { "Battlemaster", "BattleMaster" }, globals = { "MINIMAP_TRACKING_BATTLEMASTER" } },
    { key = "repair", label = "Repair", names = { "Repair" }, tex = "repair",
      filters = { "Repair" }, globals = { "MINIMAP_TRACKING_REPAIR" } },
    { key = "food", label = "Food & Drink", names = { "Food & Drink", "Food and Drink" }, tex = "food",
      filters = { "VenderFood", "VendorFood" }, globals = { "MINIMAP_TRACKING_VENDOR_FOOD" } },
    { key = "reagent", label = "Reagents", names = { "Reagents", "Reagent" }, tex = "reagents",
      filters = { "VendorReagent" }, globals = { "MINIMAP_TRACKING_VENDOR_REAGENT" } },
    { key = "poison", label = "Poisons", names = { "Poisons", "Poison" }, tex = "poisons",
      filters = { "VendorPoison" }, globals = { "MINIMAP_TRACKING_VENDOR_POISON" } },
    { key = "ammo", label = "Ammunition", names = { "Ammunition", "Ammo" }, tex = "ammunition",
      filters = { "VendorAmmo", "VendorAmmunition" }, globals = { "MINIMAP_TRACKING_VENDOR_AMMO" } },
    { key = "vendor", label = "Vendor" }, -- learned for the bundled data and the tooltip; no tracking type
}
TP.BY_KEY = {}
for i, c in ipairs(TP.CATEGORIES) do c.order = i; TP.BY_KEY[c.key] = c end

-- Interaction types (12.x engine) that learn a category without the old event, by enum name.
TP.INTERACTIONS = { Banker = "banker", Auctioneer = "auctioneer", TaxiNode = "flightmaster", MailInfo = "mailbox",
    Binder = "innkeeper", StableMaster = "stablemaster", Stablemaster = "stablemaster",
    BattleMaster = "battlemaster", Battlemaster = "battlemaster", Trainer = "trainer", Merchant = "merchant" }

local settings, core, store       -- GaarMapsForeverDB, the main file's helpers, GaarMapsForeverNPCDB
TP.sources = {}                   -- { { name, data } }, read-only bundled data
TP.stats = { learned = 0, noPos = 0, errors = 0, lastError = nil, last = nil }
TP.rev = 0                        -- bumped whenever what is shown could change

local function Print(msg) if core and core.Print then core.Print(msg) end end
local function Now() return Num(Call(_G.GetTime)) or 0 end
local function Round(v) return math.floor(v * 10000 + 0.5) / 10000 end

-- "Flight Master" -> "flightmaster"; nil for anything that is not a plain string.
local function Norm(s)
    s = Str(s)
    if not s then return nil end
    s = s:lower():gsub("[^%w]", "")
    return s ~= "" and s or nil
end
TP.Norm = Norm

-- ---------------------------------------------------------------------------
-- Tracking: which categories the minimap tracking menu has checked
-- ---------------------------------------------------------------------------

local nameIndex, texIndex, filterIndex
local function BuildIndexes()
    nameIndex, texIndex, filterIndex = {}, {}, {}
    local enum = type(_G.Enum) == "table" and type(_G.Enum.MinimapTrackingFilter) == "table" and _G.Enum.MinimapTrackingFilter
    for _, c in ipairs(TP.CATEGORIES) do
        for _, n in ipairs(c.names or {}) do nameIndex[Norm(n)] = c.key end
        for _, g in ipairs(c.globals or {}) do
            local n = Norm(_G[g])
            if n and not nameIndex[n] then nameIndex[n] = c.key end
        end
        if c.tex then texIndex[c.tex] = c.key end
        if enum then
            for _, f in ipairs(c.filters or {}) do
                local v = Num(enum[f])
                if v and v > 0 then filterIndex[v] = c.key end
            end
        end
    end
end
TP.ResetIndexes = function() nameIndex = nil end

-- The category of one tracking type: by filterID, by name, by the texture's file name.
function TP.CategoryOf(name, texture, filterID)
    if not nameIndex then BuildIndexes() end
    filterID = Num(filterID)
    if filterID and filterIndex[filterID] then return filterIndex[filterID] end
    local n = Norm(name)
    if n and nameIndex[n] then return nameIndex[n] end
    local tex = Str(texture)
    if tex then
        local file = tex:lower():gsub("%.%a+$", ""):match("([^\\/]+)$")
        if file and texIndex[file] then return texIndex[file] end
    end
end

local trackCache, trackAt = nil, -100
function TP.InvalidateTracking() trackCache = nil; TP.rev = TP.rev + 1 end

-- { tracked = { [key] = texture }, all = { { name, active, key } }, from = "C_Minimap" | "global" } or nil
function TP.ReadTracking()
    local now = Now()
    if trackCache and now - trackAt < TRACK_TTL then return trackCache end
    local out = { tracked = {}, all = {}, from = nil }
    local function scan(count, get, filterGet, label)
        count = Num(count)
        if not count or count <= 0 or type(get) ~= "function" then return end
        out.from = label
        for i = 1, math.min(count, 100) do
            local a, b, c = Call(get, i)
            local name, tex, active
            if not IsSecret(a) and type(a) == "table" then
                name, tex, active = Str(a.name), a.texture, Bool(a.active)
            else
                name, tex, active = Str(a), b, Bool(c)
            end
            if IsSecret(tex) then tex = nil end
            local filterID
            if filterGet then
                local f = Call(filterGet, i)
                if not IsSecret(f) and type(f) == "table" then filterID = Num(f.filterID) end
            end
            local key = TP.CategoryOf(name, tex, filterID)
            out.all[#out.all + 1] = { name = name or ("#" .. i), active = active, key = key }
            if active and key and tex ~= nil and not out.tracked[key] then out.tracked[key] = tex end
        end
    end
    scan(Call(API("C_Minimap", "GetNumTrackingTypes")), API("C_Minimap", "GetTrackingInfo"),
        API("C_Minimap", "GetTrackingFilter"), "C_Minimap")
    if not out.from then scan(Call(API("GetNumTrackingTypes")), API("GetTrackingInfo"), nil, "global") end
    local sig = {}
    for k in pairs(out.tracked) do sig[#sig + 1] = k end
    table.sort(sig)
    out.sig = table.concat(sig, ",")
    if not trackCache or trackCache.sig ~= out.sig then TP.rev = TP.rev + 1 end
    trackCache, trackAt = out, now
    return out
end

-- ---------------------------------------------------------------------------
-- Data: learned (GaarMapsForeverNPCDB) and bundled (read-only), merged per map
-- ---------------------------------------------------------------------------

local function Near(a, b, r)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy <= r * r
end

local function ShareCat(a, b)
    for k in pairs(a) do if b[k] then return true end end
    return false
end

-- The learned entry in `list` that is this NPC or object, or nil. Pure (tested).
function TP.FindLearned(list, x, y, name, id, cats)
    local p = { x = x, y = y }
    for _, e in ipairs(list) do
        if id and e.id == id then return e end
        if name and e.name == name and (not id or not e.id) and Near(e, p, NEAR_NAME) then return e end
        if not name and not id and not e.name and not e.id and ShareCat(e.c, cats) and Near(e, p, NEAR_OBJECT) then
            return e
        end
    end
end

-- Stores one visit in `st` (a GaarMapsForeverNPCDB table). Returns the entry and whether it is new.
function TP.Record(st, mapID, x, y, name, id, cats, now)
    st.maps = st.maps or {}
    local list = st.maps[mapID]
    if not list then list = {}; st.maps[mapID] = list end
    x, y = Round(x), Round(y)
    local e = TP.FindLearned(list, x, y, name, id, cats)
    if e then
        local n = math.min(e.n or 1, 9)
        e.x, e.y = Round((e.x * n + x) / (n + 1)), Round((e.y * n + y) / (n + 1))
        e.n = (e.n or 1) + 1
        for k in pairs(cats) do e.c[k] = true end
        if name then e.name = name end
        if id then e.id = id end
        e.t = now
        return e, false
    end
    local c = {}
    for k in pairs(cats) do c[k] = true end
    e = { x = x, y = y, name = name, id = id, c = c, n = 1, t = now }
    list[#list + 1] = e
    return e, true
end

-- A bundled row in any of the accepted shapes -> { x, y, name, id, c = set } or nil.
function TP.NormalizeRow(r)
    if type(r) ~= "table" then return nil end
    local id, x, y, c, name = r.id, r.x, r.y, r.c or r.cats, r.name
    if x == nil then id, x, y, c, name = r[1], r[2], r[3], r[4], r[5] end
    x, y = Num(x), Num(y)
    if not x or not y then return nil end
    if x > 1 or y > 1 then x, y = x / 100, y / 100 end
    if x <= 0 or y <= 0 or x > 1 or y > 1 then return nil end
    local set = {}
    if type(c) == "string" then
        for k in c:gmatch("[%w]+") do if TP.BY_KEY[k] then set[k] = true end end
    elseif type(c) == "table" then
        for k, v in pairs(c) do
            if type(k) == "number" and TP.BY_KEY[v] then set[v] = true
            elseif TP.BY_KEY[k] and v then set[k] = true end
        end
    end
    if not next(set) then return nil end
    return { x = x, y = y, name = Str(name), id = Num(id), c = set }
end

-- Adds a read-only data set: { [uiMapID] = { row, ... } }. Never written to.
function TP.AddSource(name, data)
    if type(data) ~= "table" then return false end
    for _, s in ipairs(TP.sources) do if s.name == name then s.data = data; TP.rev = TP.rev + 1 return true end end
    TP.sources[#TP.sources + 1] = { name = tostring(name), data = data }
    TP.rev = TP.rev + 1
    return true
end

-- Learned entries of the map (copies, with bundled categories merged in) followed by the bundled rows
-- no learned entry covers. Pure on its arguments (tested).
function TP.Merge(learnedList, sources, mapID)
    local out = {}
    for _, e in ipairs(learnedList or {}) do
        if type(e) == "table" and Num(e.x) and Num(e.y) and type(e.c) == "table" then
            local c = {}
            for k in pairs(e.c) do c[k] = true end
            out[#out + 1] = { x = e.x, y = e.y, name = e.name, id = e.id, c = c, n = e.n, src = "learned" }
        end
    end
    local nLearned = #out
    for _, s in ipairs(sources or {}) do
        local rows = type(s.data) == "table" and s.data[mapID]
        if type(rows) == "table" then
            for _, raw in ipairs(rows) do
                local b = TP.NormalizeRow(raw)
                if b then
                    local hit
                    for i = 1, nLearned do
                        local e = out[i]
                        if (b.id and e.id == b.id)
                            or (b.name and e.name == b.name and Near(e, b, NEAR_NAME))
                            or (ShareCat(e.c, b.c) and Near(e, b, NEAR_OBJECT)) then
                            hit = e
                            break
                        end
                    end
                    if hit then
                        for k in pairs(b.c) do hit.c[k] = true end
                    else
                        b.src = s.name
                        out[#out + 1] = b
                    end
                end
            end
        end
    end
    return out
end

-- The pins to draw: { x, y, key, texture, entry } for entries with a tracked category, only on maps
-- of a single-zone type. Pure (tested).
function TP.Visible(entries, mapType, tracked)
    local out = {}
    if not SHOW_TYPES[Num(mapType) or -1] or type(tracked) ~= "table" or not next(tracked) then return out end
    for _, e in ipairs(entries) do
        for _, c in ipairs(TP.CATEGORIES) do
            if e.c[c.key] and tracked[c.key] ~= nil then
                out[#out + 1] = { x = e.x, y = e.y, key = c.key, texture = tracked[c.key], entry = e }
                break
            end
        end
    end
    return out
end

-- Counts per category and the number of entries and maps in a store. Pure (tested).
function TP.Counts(st)
    local total, maps, per = 0, 0, {}
    for _, list in pairs(type(st) == "table" and type(st.maps) == "table" and st.maps or {}) do
        if type(list) == "table" and #list > 0 then
            maps = maps + 1
            for _, e in ipairs(list) do
                total = total + 1
                for k in pairs(type(e.c) == "table" and e.c or {}) do per[k] = (per[k] or 0) + 1 end
            end
        end
    end
    return total, maps, per
end

-- Drops anything malformed from a loaded store, keeping the rest.
function TP.Sanitize(st)
    if type(st) ~= "table" then st = {} end
    if type(st.maps) ~= "table" then st.maps = {} end
    st.version = 1
    for mapID, list in pairs(st.maps) do
        if type(mapID) ~= "number" or type(list) ~= "table" then
            st.maps[mapID] = nil
        else
            for i = #list, 1, -1 do
                local e = list[i]
                local ok = type(e) == "table" and type(e.x) == "number" and type(e.y) == "number" and type(e.c) == "table"
                if ok then
                    for k in pairs(e.c) do if not TP.BY_KEY[k] then e.c[k] = nil end end
                    ok = next(e.c) ~= nil
                end
                if not ok then table.remove(list, i) end
            end
            if #list == 0 then st.maps[mapID] = nil end
        end
    end
    return st
end

-- ---------------------------------------------------------------------------
-- Learning
-- ---------------------------------------------------------------------------

-- The player's zone and position on it, or nil (instances, loading, secret values).
function TP.PlayerPos()
    local mapID = Num(Call(API("C_Map", "GetBestMapForUnit"), "player"))
    if not mapID then return nil end
    local pos = Call(API("C_Map", "GetPlayerMapPosition"), mapID, "player")
    if IsSecret(pos) or type(pos) ~= "table" then return nil end
    local x, y
    if type(pos.GetXY) == "function" then x, y = Call(pos.GetXY, pos) end
    if x == nil then x, y = pos.x, pos.y end
    x, y = Num(x), Num(y)
    if not x or not y or x <= 0 or y <= 0 or x > 1 or y > 1 then return nil end
    return mapID, x, y
end

-- "Creature-0-3767-0-14-1234-0000A1B2C3" -> 1234. Objects get a negative id so they never meet an NPC's.
function TP.IdFromGUID(guid)
    guid = Str(guid)
    if not guid then return nil end
    local kind, id = guid:match("^(%a+)%-[^%-]*%-[^%-]*%-[^%-]*%-[^%-]*%-(%d+)%-")
    id = tonumber(id)
    if not id then return nil end
    if kind == "Creature" or kind == "Vehicle" then return id end
    if kind == "GameObject" then return -id end
end

-- The NPC being talked to: name and id, or nil.
function TP.CurrentNPC()
    for _, unit in ipairs({ "npc", "target" }) do
        if Bool(Call(_G.UnitExists, unit)) and not Bool(Call(_G.UnitIsPlayer, unit)) then
            local name = Str(Call(_G.UnitName, unit))
            local id = TP.IdFromGUID(Call(_G.UnitGUID, unit))
            if name or id then return { name = name, id = id } end
        end
    end
end

local recent = {}
function TP.Learn(cats, npc, isObject)
    if not store or not settings or not settings.trackedPins then return end
    if not next(cats) then return end
    if not isObject then npc = npc or TP.CurrentNPC() else npc = nil end
    local now = Now()
    local who = npc and (npc.id or npc.name) or "object"
    local fresh = {}
    for k in pairs(cats) do
        local key = tostring(who) .. ":" .. k
        if not recent[key] or now - recent[key] > DEBOUNCE then fresh[k] = true end
        recent[key] = now
    end
    if not next(fresh) then return end
    local mapID, x, y = TP.PlayerPos()
    if not mapID then
        TP.stats.noPos = TP.stats.noPos + 1
        return
    end
    local e, new = TP.Record(store, mapID, x, y, npc and npc.name, npc and npc.id, fresh, Num(Call(_G.time)) or 0)
    if new then TP.stats.learned = TP.stats.learned + 1 end
    local labels = {}
    for k in pairs(fresh) do labels[#labels + 1] = TP.BY_KEY[k].label end
    table.sort(labels)
    TP.stats.last = string.format("%s (%s) on map %d at %.1f, %.1f", e.name or "object", table.concat(labels, ", "),
        mapID, e.x * 100, e.y * 100)
    TP.rev = TP.rev + 1
end

function TP.TrainerKind()
    local f = API("IsTradeskillTrainer")
    if f then
        local ok, v = pcall(f)
        if ok and v ~= nil and not IsSecret(v) then return v and "proftrainer" or "classtrainer" end
    end
    -- The NPC's tooltip: "<Warrior Trainer>" names a class.
    local data = Call(API("C_TooltipInfo", "GetUnit"), "npc")
    if type(data) == "table" and type(data.lines) == "table" then
        local classes = {}
        for _, t in ipairs({ _G.LOCALIZED_CLASS_NAMES_MALE, _G.LOCALIZED_CLASS_NAMES_FEMALE }) do
            if type(t) == "table" then for _, n in pairs(t) do if Str(n) then classes[#classes + 1] = n:lower() end end end
        end
        for i = 2, #data.lines do
            local text = Str(type(data.lines[i]) == "table" and data.lines[i].leftText)
            if text then
                text = text:lower()
                for _, n in ipairs(classes) do if text:find(n, 1, true) then return "classtrainer" end end
            end
        end
    end
    return "proftrainer"
end

-- Kinds of goods a merchant sells: a set of food / reagent / ammo / poison.
function TP.MerchantKinds()
    local out = {}
    local n = Num(Call(API("GetMerchantNumItems"))) or 0
    local instant = API("C_Item", "GetItemInfoInstant") or API("GetItemInfoInstant")
    if n <= 0 or not instant then return out end
    local E = type(_G.Enum) == "table" and _G.Enum.ItemClass or {}
    local CONSUMABLE, REAGENT, PROJECTILE = Num(E.Consumable) or 0, Num(E.Reagent) or 5, Num(E.Projectile) or 6
    local total, count = 0, { food = 0, reagent = 0, ammo = 0, poison = 0 }
    for i = 1, math.min(n, 200) do
        local link = Str(Call(API("GetMerchantItemLink"), i))
        local q = Num(Call(API("GetMerchantItemID"), i)) or link
        if q then
            local _, _, _, _, _, classID, subID = Call(instant, q)
            classID, subID = Num(classID), Num(subID)
            if classID then
                total = total + 1
                local itemName = link and link:match("%[(.-)%]")
                if classID == CONSUMABLE and subID == 5 then count.food = count.food + 1
                elseif classID == REAGENT then count.reagent = count.reagent + 1
                elseif classID == PROJECTILE then count.ammo = count.ammo + 1 end
                if classID == CONSUMABLE and itemName and itemName:find("Poison") then count.poison = count.poison + 1 end
            end
        end
    end
    if total > 0 then
        for k, v in pairs(count) do if v > 0 and v / total >= SHARE then out[k] = true end end
    end
    return out
end

local function Learn1(key, isObject) TP.Learn({ [key] = true }, nil, isObject) end

local function OnMerchant()
    local cats = TP.MerchantKinds()
    cats.vendor = true
    if Bool(Call(API("CanMerchantRepair"))) then cats.repair = true end
    TP.Learn(cats)
end

local function GossipHasBinder()
    local opts = Call(API("C_GossipInfo", "GetOptions"))
    if type(opts) == "table" then
        for _, o in ipairs(opts) do
            local name = type(o) == "table" and Str(o.name)
            if name then
                local l = name:lower()
                if l:find("inn your home", 1, true) or l:find("make this inn", 1, true) then return true end
            end
            local icon = type(o) == "table" and Str(o.icon)
            if icon and icon:lower():find("binder", 1, true) then return true end
        end
    end
    local legacy = API("GetGossipOptions")
    if legacy then
        local r = { Call(legacy) }
        for i = 2, #r, 2 do if Str(r[i]) == "binder" then return true end end
    end
    return false
end

local function InteractionName(t)
    t = Num(t)
    local enum = type(_G.Enum) == "table" and _G.Enum.PlayerInteractionType
    if not t or type(enum) ~= "table" then return nil end
    for name, v in pairs(enum) do if v == t then return name end end
end

TP.HANDLERS = {
    MERCHANT_SHOW = OnMerchant,
    BANKFRAME_OPENED = function() Learn1("banker") end,
    AUCTION_HOUSE_SHOW = function() Learn1("auctioneer") end,
    TAXIMAP_OPENED = function() Learn1("flightmaster") end,
    TRAINER_SHOW = function() Learn1(TP.TrainerKind()) end,
    MAIL_SHOW = function() Learn1("mailbox", true) end,
    CONFIRM_BINDER = function() Learn1("innkeeper") end,
    GOSSIP_SHOW = function() if GossipHasBinder() then Learn1("innkeeper") end end,
    PET_STABLE_SHOW = function() Learn1("stablemaster") end,
    BATTLEFIELDS_SHOW = function() if Bool(Call(_G.UnitExists, "npc")) then Learn1("battlemaster") end end,
    PLAYER_INTERACTION_MANAGER_FRAME_SHOW = function(t)
        local what = TP.INTERACTIONS[InteractionName(t) or ""]
        if what == "merchant" then OnMerchant()
        elseif what == "trainer" then Learn1(TP.TrainerKind())
        elseif what then Learn1(what, what == "mailbox") end
    end,
}

-- ---------------------------------------------------------------------------
-- Pins on the world map canvas
-- ---------------------------------------------------------------------------

local pins, lastSig, driver, hooked = {}, nil, nil, false
TP.drawn = { map = nil, mapType = nil, count = 0 }

local function OnEnter(self)
    local d, tip = self.data, _G.GameTooltip
    if not d or not tip then return end
    local e = d.entry
    tip:SetOwner(self, "ANCHOR_RIGHT")
    tip:SetText(e.name or TP.BY_KEY[d.key].label, 1, 1, 1)
    local labels = {}
    for _, c in ipairs(TP.CATEGORIES) do if e.c[c.key] then labels[#labels + 1] = c.label end end
    tip:AddLine(table.concat(labels, ", "), 1, 0.82, 0)
    if e.src == "learned" then
        tip:AddLine("Learned (seen " .. (e.n or 1) .. "x)", 0.6, 0.6, 0.6)
    else
        tip:AddLine("From " .. tostring(e.src), 0.6, 0.6, 0.6)
    end
    tip:Show()
end

local function OnLeave() if _G.GameTooltip then _G.GameTooltip:Hide() end end

local function BuildPin(canvas, i)
    local p = CreateFrame("Frame", nil, canvas)
    p.icon = p:CreateTexture(nil, "OVERLAY")
    p.icon:SetAllPoints(p)
    p:EnableMouse(true)
    -- Hover only, where the client can: clicks then still reach the map underneath.
    if p.SetMouseClickEnabled then pcall(p.SetMouseClickEnabled, p, false) end
    p:SetScript("OnEnter", OnEnter)
    p:SetScript("OnLeave", OnLeave)
    p:Hide()
    pins[i] = p
    return p
end

function TP.HideAll()
    for _, p in ipairs(pins) do p:Hide() end
    lastSig = nil
    TP.drawn.count = 0
end

local function Canvas(map)
    local ok, c = pcall(function() return map:GetCanvas() end)
    if ok and type(c) == "table" then return c end
    local sc = map.ScrollContainer
    if type(sc) == "table" and type(sc.Child) == "table" then return sc.Child end
end

local cache = { map = nil, rev = -1, entries = nil }
local function Entries(mapID)
    if cache.map ~= mapID or cache.rev ~= TP.rev then
        cache.map, cache.rev = mapID, TP.rev
        local learned = store and store.maps and store.maps[mapID]
        cache.entries = TP.Merge(learned, TP.sources, mapID)
    end
    return cache.entries
end

function TP.Draw()
    local map = core and core.GetMap and core.GetMap()
    if not settings or not settings.trackedPins or not map or not map:IsVisible() then
        if lastSig then TP.HideAll() end
        return
    end
    local canvas = Canvas(map)
    local mapID = Num(Call(map.GetMapID, map))
    local info = mapID and Call(API("C_Map", "GetMapInfo"), mapID)
    local mapType = type(info) == "table" and Num(info.mapType) or nil
    local w, h = canvas and Num(canvas:GetWidth()), canvas and Num(canvas:GetHeight())
    local zoom = canvas and Num(canvas:GetScale())
    TP.drawn.map, TP.drawn.mapType = mapID, mapType
    if not mapID or not mapType or not w or not h or not zoom or zoom <= 0 or not SHOW_TYPES[mapType] then
        if lastSig then TP.HideAll() end
        return
    end
    local tr = TP.ReadTracking()
    local sig = table.concat({ mapID, w, h, zoom, TP.rev, tr.sig }, ":")
    if sig == lastSig then return end
    lastSig = sig
    local list = TP.Visible(Entries(mapID), mapType, tr.tracked)
    local size = PIN_SIZE / zoom
    local level = (Num(canvas:GetFrameLevel()) or 0) + PIN_LEVEL
    for i, d in ipairs(list) do
        local p = pins[i] or BuildPin(canvas, i)
        if p:GetParent() ~= canvas then p:SetParent(canvas) end
        p.data = d
        p:SetSize(size, size)
        p:SetFrameLevel(level)
        pcall(p.icon.SetTexture, p.icon, d.texture)
        p:ClearAllPoints()
        p:SetPoint("CENTER", canvas, "TOPLEFT", d.x * w, -d.y * h)
        p:Show()
    end
    for i = #list + 1, #pins do pins[i]:Hide() end
    TP.drawn.count = #list
end

local function SafeDraw()
    local ok, err = pcall(TP.Draw)
    if not ok then
        TP.stats.errors = TP.stats.errors + 1
        TP.stats.lastError = tostring(err)
    end
end

-- Our own frame inside the map (runs only while the map is open) and a follow-up on OnMapChanged.
function TP.HookMap()
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
    driver:SetScript("OnHide", function() TP.HideAll() end)
    if type(map.OnMapChanged) == "function" then hooksecurefunc(map, "OnMapChanged", SafeDraw) end
    return true
end

-- ---------------------------------------------------------------------------
-- Events, binding, settings, slash
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
TP.registered = {}
events:SetScript("OnEvent", function(_, event, ...)
    if event == "MINIMAP_UPDATE_TRACKING" then
        TP.InvalidateTracking()
        return
    end
    local h = TP.HANDLERS[event]
    if not h then return end
    local ok, err = pcall(h, ...)
    if not ok then
        TP.stats.errors = TP.stats.errors + 1
        TP.stats.lastError = tostring(err)
    end
end)

-- Called by the main file at ADDON_LOADED, after GaarMapsForeverDB is bound.
function TP.Bind(settingsDb, c)
    settings, core = settingsDb, c
    if type(settings.trackedPins) ~= "boolean" then settings.trackedPins = true end
    _G.GaarMapsForeverNPCDB = TP.Sanitize(_G.GaarMapsForeverNPCDB)
    store = _G.GaarMapsForeverNPCDB
    if type(ns.trackedPinsBundled) == "table" then TP.AddSource("bundled database", ns.trackedPinsBundled) end
    for e in pairs(TP.HANDLERS) do TP.registered[e] = pcall(events.RegisterEvent, events, e) or nil end
    TP.registered.MINIMAP_UPDATE_TRACKING = pcall(events.RegisterEvent, events, "MINIMAP_UPDATE_TRACKING") or nil
    TP.HookMap()
    TP.rev = TP.rev + 1
end

function TP.SetEnabled(on)
    if not settings then return end
    settings.trackedPins = on and true or false
    TP.rev = TP.rev + 1
    if not settings.trackedPins then TP.HideAll() else SafeDraw() end
    Print("tracked NPC pins on the map " .. OnOff(settings.trackedPins) .. ".")
end

function TP.Clear(confirmed)
    if not store then return end
    local n = TP.Counts(store)
    if not confirmed then
        Print("this forgets all " .. n .. " learned NPC place" .. (n == 1 and "" or "s")
            .. " (every character). Type /gmf pins clear yes to confirm.")
        return
    end
    store.maps = {}
    cache.map = nil
    TP.rev = TP.rev + 1
    TP.HideAll()
    Print("forgot " .. n .. " learned NPC place" .. (n == 1 and "" or "s") .. ".")
end

-- "tracked pins: on, 12 learned on 3 maps (Banker 2, Mailbox 3)"
function TP.StatusLine()
    local total, maps, per = TP.Counts(store)
    local parts = {}
    for _, c in ipairs(TP.CATEGORIES) do
        if per[c.key] then parts[#parts + 1] = c.label .. " " .. per[c.key] end
    end
    return "tracked pins: " .. OnOff(settings and settings.trackedPins) .. ", " .. total .. " learned on " .. maps
        .. " map" .. (maps == 1 and "" or "s") .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "")
end

function TP.StatusLines()
    local out = { TP.StatusLine() }
    local tr = TP.ReadTracking()
    local on, unmapped = {}, {}
    for _, t in ipairs(tr.all) do
        if t.active then on[#on + 1] = t.name .. (t.key and "" or " (no category)") end
        if not t.key then unmapped[#unmapped + 1] = t.name end
    end
    out[#out + 1] = "tracked pins, tracking read from " .. tostring(tr.from or "nothing (no tracking API)") .. ": "
        .. #tr.all .. " types, checked: " .. (#on > 0 and table.concat(on, ", ") or "none")
        .. (#unmapped > 0 and (" - without a category: " .. table.concat(unmapped, ", ")) or "")
    local srcs = {}
    for _, s in ipairs(TP.sources) do srcs[#srcs + 1] = s.name end
    out[#out + 1] = string.format("tracked pins, map %s (type %s): %d shown%s; bundled data: %s; last learned: %s; no position: %d%s",
        tostring(TP.drawn.map or "?"), tostring(TP.drawn.mapType or "?"), TP.drawn.count or 0,
        (TP.drawn.mapType and not SHOW_TYPES[TP.drawn.mapType]) and " (not a zone map: none drawn)" or "",
        #srcs > 0 and table.concat(srcs, ", ") or "none", TP.stats.last or "nothing this session", TP.stats.noPos,
        TP.stats.errors > 0 and ("; errors: " .. TP.stats.errors .. " (" .. tostring(TP.stats.lastError) .. ")") or "")
    return out
end

TP.HELP = {
    "/gmf pins on | /gmf pins off - NPC icons on a zone map for the types checked in the minimap tracking menu, learned as you visit them",
    "/gmf pins clear - forget the learned NPC places (asks to confirm)",
}

function TP.Slash(arg)
    arg = arg or ""
    if arg == "on" or arg == "off" then
        TP.SetEnabled(arg == "on")
    elseif arg == "clear" then
        TP.Clear(false)
    elseif arg == "clear yes" then
        TP.Clear(true)
    else
        for _, l in ipairs(TP.StatusLines()) do Print(l) end
        for _, l in ipairs(TP.HELP) do Print(l) end
    end
end
