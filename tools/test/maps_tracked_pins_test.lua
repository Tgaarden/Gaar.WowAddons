-- LuaJIT stub test: GaarMapsForever TrackedPins.lua - tracking types -> categories, learning from NPC
-- windows (dedupe, objects, secrets), the bundled-data merge, zone-only pins, clear with confirm.
-- Run: luajit tools/test/maps_tracked_pins_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarMapsForever/TrackedPins.lua")); local src = fh:read("*a"); fh:close()

local fails = 0
local function eq(n, got, want)
    if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
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

local frames, registered = {}, {}
local function NewFrame(_, _, parent)
    local f = { shown = false, parent = parent, scripts = {}, points = {} }
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:RegisterEvent(e)
        if e == "BATTLEFIELDS_SHOW" then error("unknown event") end -- an event this client lacks
        registered[e] = true
    end
    function f:CreateTexture() return { SetAllPoints = function() end, SetTexture = function(t, v) t.tex = v end } end
    function f:EnableMouse() end
    function f:SetMouseClickEnabled() end
    function f:Hide() self.shown = false end
    function f:Show() self.shown = true end
    function f:IsVisible() return true end
    function f:GetParent() return self.parent end
    function f:SetParent(p) self.parent = p end
    function f:SetSize(w) self.size = w end
    function f:SetFrameLevel() end
    function f:ClearAllPoints() self.points = {} end
    function f:SetPoint(_, _, _, x, y) self.x, self.y = x, y end
    frames[#frames + 1] = f
    return f
end

local now = 100
local tracking = {
    { name = "Find Herbs", texture = 133939, active = true },
    { name = "Banker", texture = "Interface\\Minimap\\Tracking\\Banker", active = true },
    { name = "Mailbox", texture = 136459, active = false },
    { name = "Some Odd Type", texture = 1, active = true },
    { name = "Flight Master", texture = "x", active = true },
}
local playerMap, px, py = 1429, 0.42, 0.65
local npcUnit = { exists = true, name = "Olivia", guid = "Creature-0-3767-0-14-2456-0000A1B2C3" }
local merchant = { repair = true, items = { { id = 1, class = 0, sub = 5 }, { id = 2, class = 0, sub = 5 }, { id = 3, class = 2, sub = 1 } } }
local env = {
    GetTime = function() return now end,
    time = function() return 1700000000 end,
    C_Minimap = { GetNumTrackingTypes = function() return #tracking end,
        GetTrackingInfo = function(i) return tracking[i] end },
    C_Map = { GetBestMapForUnit = function() return playerMap end,
        GetPlayerMapPosition = function(_, _) if not px then return nil end
            return { x = px, y = py, GetXY = function(s) return s.x, s.y end } end,
        GetMapInfo = function(id) return ({ [1429] = { mapType = 3 }, [13] = { mapType = 2 }, [1453] = { mapType = 5 } })[id] end },
    UnitExists = function(u) return u == "npc" and npcUnit.exists end,
    UnitIsPlayer = function() return false end,
    UnitName = function(u) return u == "npc" and npcUnit.name or nil end,
    UnitGUID = function(u) return u == "npc" and npcUnit.guid or nil end,
    CanMerchantRepair = function() return merchant.repair end,
    GetMerchantNumItems = function() return #merchant.items end,
    GetMerchantItemID = function(i) return merchant.items[i].id end,
    GetMerchantItemLink = function(i) return "|Hitem:" .. merchant.items[i].id .. "|h[Item " .. i .. "]|h" end,
    C_Item = { GetItemInfoInstant = function(id)
        for _, it in ipairs(merchant.items) do if it.id == id then return id, "", "", "", 0, it.class, it.sub end end end },
    IsTradeskillTrainer = function() return true end,
    C_GossipInfo = { GetOptions = function() return { { name = "Make this inn your home." } } end },
    Enum = { PlayerInteractionType = { Banker = 8, Merchant = 5 } },
}
_G.__env = env
local G = setmetatable({ GaarForever = BF, CreateFrame = NewFrame, hooksecurefunc = function() end }, {
    __index = function(_, k) if env[k] ~= nil then return env[k] end return _G[k] end })
G._G = G
local f = assert(loadstring(src, "TrackedPins")); setfenv(f, G)
local ns = {}
f("GaarMapsForever", ns)
local TP = ns.trackedPins
assert(TP, "module registers ns.trackedPins")
local events = frames[1]
local function Fire(e, ...) now = now + 5; events.scripts.OnEvent(events, e, ...) end

-- ---- categories ---------------------------------------------------------------------------------
eq("by name", TP.CategoryOf("Flight Master"), "flightmaster")
eq("by name, case and spaces", TP.CategoryOf("stable master"), "stablemaster")
eq("by texture file", TP.CategoryOf(nil, "Interface\\Minimap\\Tracking\\Repair.blp"), "repair")
eq("class texture exact only", TP.CategoryOf(nil, "Interface\\Icons\\ClassIcon"), nil)
eq("secret name", TP.CategoryOf(SECRET, nil), nil)
eq("unknown", TP.CategoryOf("Find Herbs", 133939), nil)

-- ---- bind -------------------------------------------------------------------------------------
local settings = {}
local map = NewFrame(); map.mapID = 1429
function map:GetMapID() return self.mapID end
local canvas = NewFrame()
function canvas:GetWidth() return 1000 end
function canvas:GetHeight() return 600 end
function canvas:GetScale() return 2 end
function canvas:GetFrameLevel() return 10 end
function map:GetCanvas() return canvas end
local printed = {}
TP.Bind(settings, { Print = function(m) printed[#printed + 1] = m end, GetMap = function() return map end })
eq("default on", settings.trackedPins, true)
eq("store created", type(G.GaarMapsForeverNPCDB.maps), "table")
eq("unknown event survives", registered.MERCHANT_SHOW, true)
eq("tracking event", registered.MINIMAP_UPDATE_TRACKING, true)
local store = G.GaarMapsForeverNPCDB

-- ---- tracking read ----------------------------------------------------------------------------
local tr = TP.ReadTracking()
eq("banker tracked", tr.tracked.banker, "Interface\\Minimap\\Tracking\\Banker")
eq("mailbox unchecked", tr.tracked.mailbox, nil)
eq("flight tracked", tr.tracked.flightmaster, "x")
eq("all types listed", #tr.all, 5)

-- ---- learning ---------------------------------------------------------------------------------
Fire("MERCHANT_SHOW")
local list = store.maps[1429]
eq("merchant learned", list and #list, 1)
local e = list[1]
eq("npc id from guid", e.id, 2456)
eq("name", e.name, "Olivia")
eq("repair", e.c.repair, true)
eq("vendor", e.c.vendor, true)
eq("food by goods share", e.c.food, true)
eq("no reagent", e.c.reagent, nil)

-- same NPC, slightly off: one entry, averaged
px = 0.43
Fire("MERCHANT_SHOW")
eq("dedupe by id", #list, 1)
eq("count", e.n, 2)
eq("averaged x", e.x, 0.425)

-- interaction manager + legacy event in the same moment count once
npcUnit.name, npcUnit.guid = "Banker Bob", "Creature-0-1-0-1-3000-00AA"
Fire("BANKFRAME_OPENED"); now = now - 4.9
events.scripts.OnEvent(events, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 8)
eq("banker learned once", list[2] and list[2].n, 1)
eq("banker cat", list[2].c.banker, true)

-- secret guid: learned by name, no id
npcUnit.name, npcUnit.guid = "Thrall Flyer", SECRET
px, py = 0.6, 0.6
Fire("TAXIMAP_OPENED")
eq("secret guid -> no id", list[3].id, nil)
eq("flight by name", list[3].c.flightmaster, true)
Fire("TAXIMAP_OPENED")
eq("same name nearby is the same", #list, 3)

-- mailbox: object, player's position, dedupe by radius
npcUnit.exists = false
px, py = 0.2, 0.2
Fire("MAIL_SHOW")
Fire("MAIL_SHOW")
eq("mailbox once", #list, 4)
eq("mailbox no name", list[4].name, nil)
px, py = 0.3, 0.3
Fire("MAIL_SHOW")
eq("far mailbox is another", #list, 5)

-- trainer and innkeeper
npcUnit.exists, npcUnit.name, npcUnit.guid = true, "Prof", "Creature-0-1-0-1-4000-00AA"
px, py = 0.7, 0.7
Fire("TRAINER_SHOW")
eq("profession trainer", list[6].c.proftrainer, true)
env.IsTradeskillTrainer = function() return false end
npcUnit.name, npcUnit.guid = "Warr", "Creature-0-1-0-1-4001-00AA"
Fire("TRAINER_SHOW")
eq("class trainer", list[7].c.classtrainer, true)
npcUnit.name, npcUnit.guid = "Inn", "Creature-0-1-0-1-4002-00AA"
Fire("GOSSIP_SHOW")
eq("innkeeper via gossip", list[8].c.innkeeper, true)

-- no position (instance): nothing stored
px = nil
Fire("PET_STABLE_SHOW")
eq("no position, nothing stored", #list, 8)
eq("noPos counted", TP.stats.noPos, 1)
px, py = 0.5, 0.5

-- off: no learning
settings.trackedPins = false
Fire("AUCTION_HOUSE_SHOW")
eq("off learns nothing", #list, 8)
settings.trackedPins = true

-- ---- merge with bundled -----------------------------------------------------------------------
local bundled = { [1429] = {
    { id = 2456, x = 0.9, y = 0.9, c = "reagent" },                    -- same id as Olivia: dropped, adds reagent
    { x = 20.3, y = 20.2, c = { "mailbox" } },                          -- 0-100 coords, near the learned mailbox: dropped
    { 3001, 0.1, 0.9, { banker = true }, "Other Banker" },              -- positional, new
    { x = 0.5, y = 0.5, c = "nonsense" },                               -- no known category: ignored
} }
TP.AddSource("bundled database", bundled)
local merged = TP.Merge(store.maps[1429], TP.sources, 1429)
eq("merged count", #merged, 9)
eq("learned keeps position", merged[1].x, 0.425)
eq("bundled category merged in", merged[1].c.reagent, true)
eq("store not written by merge", store.maps[1429][1].c.reagent, nil)
eq("bundled row added", merged[9].name, "Other Banker")
eq("bundled src", merged[9].src, "bundled database")

-- ---- visible: zone only, tracked only ---------------------------------------------------------
local vis = TP.Visible(merged, 3, { banker = "B", flightmaster = "F" })
eq("visible banker + flight + other banker", #vis, 3)
eq("pin texture is the tracking texture", vis[1].texture, "B")
eq("continent none", #TP.Visible(merged, 2, { banker = "B" }), 0)
eq("micro ok", #TP.Visible(merged, 5, { banker = "B" }), 2)
eq("nothing tracked none", #TP.Visible(merged, 3, {}), 0)
local vrep = TP.Visible({ { x = 0.1, y = 0.1, c = { vendor = true, repair = true, food = true } } }, 3, { food = "F", repair = "R" })
eq("priority: repair before food", vrep[1].key, "repair")

-- ---- draw ---------------------------------------------------------------------------------------
TP.InvalidateTracking()
TP.Draw()
eq("drawn on zone", TP.drawn.count, 3)
map.mapID = 13
TP.Draw()
eq("continent hides", TP.drawn.count, 0)
map.mapID = 1429
tracking[3].active = true
Fire("MINIMAP_UPDATE_TRACKING")
TP.Draw()
eq("mailbox appears after tracking change", TP.drawn.count, 5)

-- ---- status and clear -------------------------------------------------------------------------
local line = TP.StatusLine()
eq("status line", line:match("^tracked pins: on, 8 learned on 1 map") ~= nil, true)
eq("status lists unmapped", TP.StatusLines()[2]:find("Some Odd Type", 1, true) ~= nil, true)
TP.Slash("clear")
eq("clear asks first", #store.maps[1429], 8)
eq("clear prompt", printed[#printed]:find("clear yes", 1, true) ~= nil, true)
TP.Slash("clear yes")
eq("cleared", next(store.maps), nil)

-- ---- sanitize -----------------------------------------------------------------------------------
local s = TP.Sanitize({ maps = { [1] = { { x = 0.1, y = 0.1, c = { bogus = true } }, { x = 0.2, y = 0.2, c = { banker = true } }, "junk" },
    bad = 3, [2] = 5 } })
eq("sanitize keeps good", #s.maps[1], 1)
eq("sanitize drops bad key", s.maps.bad, nil)
eq("sanitize version", s.version, 1)

if fails == 0 then print("maps_tracked_pins_test: ok") else os.exit(1) end
