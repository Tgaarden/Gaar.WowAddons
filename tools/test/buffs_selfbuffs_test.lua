-- LuaJIT stub test: GaarBuffsForever 1.11 self buffs (SelfBuffs.lua) - keyword detection of the XP
-- food and campfire auras, the XP food picked from the bags (largest stack), the "no food" and
-- "Basic Campfire not known" states, no secure attribute / Show / Hide on our buttons in combat,
-- the secret-value path (frozen, no error, matched by a learned ID), learned IDs in /gbuff status,
-- the options and the slash command. Runs on a warrior (no class module): the strip is class-free.
-- Run: luajit tools/test/buffs_selfbuffs_test.lua   (from the repo root)
local fails, checks = 0, 0
local function ok(n, cond) checks = checks + 1; if not cond then fails = fails + 1; print("FAIL " .. n) end end
local function eq(n, got, want)
    checks = checks + 1
    if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local noop = function() end

-- A secret: any use other than passing it on (index, concat, compare, length, call) raises.
local SECRET = setmetatable({}, {
    __index = function() error("indexed a secret") end, __concat = function() error("joined a secret") end,
    __lt = function() error("compared a secret") end, __le = function() error("compared a secret") end,
    __len = function() error("length of a secret") end, __call = function() error("called a secret") end,
    __tostring = function() return "<secret>" end,
})
local function IsSecret(v) return rawequal(v, SECRET) end

local S = { combat = false, now = 1000, violations = {}, class = "WARRIOR" }

-- Frames: every method exists; the ones the code reads back are real.
local frames = {}
local function Widget(kind, template)
    local w = { scripts = {}, attrs = {}, events = {}, shown = true, kind = kind,
        secure = template == "SecureActionButtonTemplate", children = {} }
    frames[#frames + 1] = w
    local m = {}
    function m.SetScript(self, s, fn) self.scripts[s] = fn end
    function m.HookScript(self, s, fn) self.scripts["hook:" .. s] = fn end
    function m.RegisterEvent(self, e) self.events[e] = true end
    function m.SetAttribute(self, k, v)
        if S.combat and self.secure then S.violations[#S.violations + 1] = "SetAttribute " .. tostring(k) end
        self.attrs[k] = v
    end
    function m.GetAttribute(self, k) return self.attrs[k] end
    function m.RegisterForClicks(self, d)
        if S.combat and self.secure then S.violations[#S.violations + 1] = "RegisterForClicks" end
        self.clicks = d
    end
    local function Protected(self) return self.secure or self.hasSecure end
    function m.Show(self)
        if S.combat and Protected(self) then S.violations[#S.violations + 1] = "Show" end
        self.shown = true
    end
    function m.Hide(self)
        if S.combat and Protected(self) then S.violations[#S.violations + 1] = "Hide" end
        self.shown = false
    end
    function m.SetPoint(self, ...)
        if S.combat and Protected(self) then S.violations[#S.violations + 1] = "SetPoint" end
        self.point = { ... }
    end
    function m.ClearAllPoints(self)
        if S.combat and Protected(self) then S.violations[#S.violations + 1] = "ClearAllPoints" end
    end
    function m.SetHeight(self, h)
        if S.combat and Protected(self) then S.violations[#S.violations + 1] = "SetHeight" end
        self.h = h
    end
    function m.IsShown(self) return self.shown end
    function m.CreateTexture(self) local t = Widget("Texture"); return t end
    function m.CreateFontString(self) local t = Widget("FontString"); return t end
    function m.SetText(self, t) self.text = t end
    function m.GetText(self) return self.text end
    function m.SetTexture(self, t) self.tex = t end
    function m.SetDesaturated(self, d) self.desat = d end
    function m.SetVertexColor(self, r, g, b) self.rgb = { r, g, b } end
    function m.GetStringWidth() return 100 end
    function m.GetStringHeight() return 12 end
    function m.GetHighlightTexture() return Widget("Texture") end
    function m.GetWidth() return 1920 end
    function m.GetHeight() return 1080 end
    function m.GetLeft() return 800 end
    function m.GetRight() return 1000 end
    function m.GetTop() return 900 end
    function m.NumLines() return 0 end
    return setmetatable(w, { __index = function(_, k) return m[k] or function() return nil end end })
end

-- The tooltip lines of a C_TooltipInfo result.
local function Lines(...)
    local lines = {}
    for _, t in ipairs({ ... }) do lines[#lines + 1] = { leftText = t } end
    return { lines = lines }
end

-- Auras and bags the stub client holds.
S.auras = {}          -- { spellId, name, icon, expirationTime, auraInstanceID, tip = {lines} }
S.bags = {}           -- [bag] = { [slot] = { itemID, stackCount, name, tip = {lines} } }
S.known = {}          -- spell ID -> true
S.indexSecret = false

local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
local printed = {}
G.GaarForever = {
    NewAddon = function() return { Print = function(_, m) printed[#printed + 1] = m end, title = "GaarBuffsForever" } end,
    OnOff = function(v) return v and "on" or "off" end,
    IsSecret = IsSecret,
    Num = function(v) if IsSecret(v) or type(v) ~= "number" or v ~= v or v == math.huge then return nil end return v end,
    Str = function(v) if IsSecret(v) or type(v) ~= "string" or v == "" then return nil end return v end,
    Bool = function(v) if IsSecret(v) then return nil end return v and true or false end,
    InCombat = function() return S.combat end,
    API = function(ns, name)
        if name == nil then local f = G[ns]; return type(f) == "function" and f or nil end
        local t = G[ns]; if type(t) ~= "table" then return nil end
        local f = t[name]; return type(f) == "function" and f or nil
    end,
    Call = function(fn, ...)
        if type(fn) ~= "function" then return end
        local r = { pcall(fn, ...) }
        if r[1] then return unpack(r, 2) end
    end,
    Migrate = noop, RenderMenu = noop,
}
G.CreateFrame = function(kind, _, parent, template)
    local w = Widget(kind, template)
    if template == "SecureActionButtonTemplate" and parent then parent.hasSecure = true end
    return w
end
G.UIParent = Widget("Frame"); G.GameTooltip = Widget("GameTooltip")
G.SlashCmdList = {}
G.RegisterStateDriver = noop
G.GetTime = function() return S.now end
G.InCombatLockdown = function() return S.combat end
G.UnitClass = function() return "Warrior", S.class, 1 end
G.IsInRaid = function() return false end
G.IsInGroup = function() return false end
G.IsAltKeyDown = function() return false end
G.C_CVar = { GetCVarBool = function(name) return name == "ActionButtonUseKeyDown" and S.keyDown == true end }
G.C_Secrets = { ShouldUnitAuraIndexBeSecret = function() return S.indexSecret end }
G.C_UnitAuras = {
    GetAuraDataByIndex = function(unit, i, filter)
        if S.auraError then error("refused") end
        local a = S.auras[i]
        if not a then return nil end
        return { spellId = a.spellId, name = a.name, icon = a.icon, expirationTime = a.expirationTime,
            duration = 0, auraInstanceID = a.auraInstanceID }
    end,
}
G.C_TooltipInfo = {
    GetUnitBuffByAuraInstanceID = function(unit, iid)
        S.tipCalls = (S.tipCalls or 0) + 1
        if S.combat then return SECRET end
        for _, a in ipairs(S.auras) do
            if a.auraInstanceID == iid then return Lines(a.name, unpack(a.tip or {})) end
        end
    end,
    GetBagItem = function(bag, slot)
        if S.combat then return SECRET end
        local it = S.bags[bag] and S.bags[bag][slot]
        return it and Lines(it.name, unpack(it.tip or {})) or nil
    end,
}
G.C_Container = {
    GetContainerNumSlots = function(bag) return bag <= 4 and 16 or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local it = S.bags[bag] and S.bags[bag][slot]
        if not it then return nil end
        return { itemID = it.itemID, stackCount = it.stackCount, iconFileID = 133000 + it.itemID,
            hyperlink = "|cffffffff|Hitem:" .. it.itemID .. "|h[" .. it.name .. "]|h|r" }
    end,
}
local ITEM_NAMES = {}
G.C_Item = {
    GetItemNameByID = function(id) return ITEM_NAMES[id] end,
    GetItemCount = function() return 0 end,
    RequestLoadItemDataByID = noop,
}
G.C_Spell = {
    GetSpellInfo = function(s)
        if s == 818 or s == "Basic Campfire" then return { name = "Basic Campfire", spellID = 818, iconID = 135805 } end
        return nil
    end,
}
G.C_SpellBook = { IsSpellKnown = function(id) return S.known[id] == true end }

local function Chunk(path, name)
    local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
    local f = assert(loadstring(src, "@" .. name)); setfenv(f, G); return f
end
local ns = {}
local dir = "addons/GaarBuffsForever/"
Chunk(dir .. "GaarBuffsForever.lua", "main")("GaarBuffsForever", ns)
Chunk(dir .. "SelfBuffs.lua", "SelfBuffs.lua")("GaarBuffsForever", ns)
local SB = assert(ns.SelfBuffs, "ns.SelfBuffs")

local function Fire(event, ...)
    for _, f in ipairs(frames) do
        local fn = f.scripts.OnEvent
        if fn and (f.events[event] or event == "ADDON_LOADED" or event == "PLAYER_LOGIN") then fn(f, event, ...) end
    end
end
local function Tick(dt) S.now = S.now + (dt or 1.1); SB.Tick() end
local function Slash(msg) G.SlashCmdList.GAARBUFFSFOREVER(msg) end

Fire("ADDON_LOADED", "GaarBuffsForever")
Fire("PLAYER_LOGIN")
Fire("PLAYER_ENTERING_WORLD")
local rows, panel = SB.Rows()
local xpRow, fireRow = rows[1], rows[2]

-- 1. Keywords --------------------------------------------------------------------------------
local C = SB.Classify
eq("well fed xp", C("Well Fed", "well fed\nexperience gained increased by 10%.", nil), "xp")
eq("xp by icon", C("Hearty Meal", "you gain experience faster.", 136000), "xp")
eq("bonus xp, any name", C("Forever Feast", "+5% bonus xp from kills.", nil), "xp")
eq("cozy fire", C("Cozy Fire", "spirit increased by 4.", nil), "fire")
eq("campfire with xp text is the campfire", C("Campfire Warmth", "experience gained increased by 5%.", nil), "fire")
eq("campfire in tooltip", C("Warmth", "you are resting near a fire.", nil), "fire")
eq("fire word in name", C("Fire Glow", "resting.", nil), "fire")
eq("inner fire is not a campfire", C("Inner Fire", "increased armor.", nil), nil)
eq("fire shield is not a campfire", C("Fire Shield", "deals fire damage.", nil), nil)
local CAMP_TIP = "Gained the following camp benefits: Mana Well: Restores 20 Mana every 5 seconds."
eq("camp benefits is the campfire", C("Camp Benefits", CAMP_TIP, nil), "fire")
eq("camp benefits, upper case", C("CAMP BENEFITS", CAMP_TIP, nil), "fire")
ok("camp benefits is not xp food", not SB.IsXpFoodText(CAMP_TIP))
eq("mark of the wild", C("Mark of the Wild", "increases armor by 105.", nil), nil)
eq("well fed without xp", C("Well Fed", "well fed\nstamina increased by 6.", nil), nil)
ok("food tooltip", SB.IsXpFoodText("forever feast\nuse: restores 1000 health over 30 sec. if you spend at least 10 seconds eating you will become well fed and gain 10% bonus experience for 15 min."))
ok("xp elixir with use:", SB.IsXpFoodText("tonic\nuse: increases experience gained by 5% for 1 hour."))
ok("plain bread is not xp food", not SB.IsXpFoodText("bread\nuse: restores 61 health over 18 sec. must remain seated while eating."))
ok("xp book without a use line", not SB.IsXpFoodText("the experience of war\na story."))
local K = SB.KEYWORDS
ok("keywords in one table", type(K.xp) == "table" and type(K.fire) == "table" and type(K.foodCue) == "table")

-- 2. Nothing in the bags, Basic Campfire not known -------------------------------------------------
Tick()
local state, food, fireSpell = SB.State()
eq("no xp buff", state.xp, nil)
eq("no food", food, nil)
eq("fire spell unknown", fireSpell, nil)
ok("strip shown on a warrior", panel.shown)
eq("xp row: no click", xpRow.attrs.type, nil)
ok("xp row greyed", xpRow.icon.desat == true)
ok("xp row text", xpRow.text.text:find("no food") ~= nil)
eq("xp tooltip", xpRow.view.tip[1][1], "No XP food in bags")
eq("fire row: no click", fireRow.attrs.type, nil)
ok("fire row greyed", fireRow.icon.desat == true)
eq("fire tooltip", fireRow.view.tip[1][1], "Requires Cooking (Basic Campfire)")

-- 3. Bag food selection: the largest stack (summed per item ID) -----------------------------------
ITEM_NAMES[100], ITEM_NAMES[200], ITEM_NAMES[300] = "Bread", "Small Feast", "Forever Feast"
local XP_TIP = { "Use: Restores 500 health over 20 sec. If you spend at least 10 seconds eating you will become well fed and gain 5% bonus experience for 15 min." }
S.bags[0] = {
    [1] = { itemID = 100, stackCount = 20, name = "Bread", tip = { "Use: Restores 61 health over 18 sec. Must remain seated while eating." } },
    [2] = { itemID = 200, stackCount = 5, name = "Small Feast", tip = XP_TIP },
    [3] = { itemID = 300, stackCount = 12, name = "Forever Feast", tip = XP_TIP },
}
S.bags[1] = { [4] = { itemID = 200, stackCount = 3, name = "Small Feast", tip = XP_TIP } }
S.known[818] = true
Fire("BAG_UPDATE_DELAYED")
Fire("SPELLS_CHANGED")
Tick()
state, food, fireSpell = SB.State()
eq("picked item", food and food.id, 300)
eq("picked count", food and food.count, 12)
eq("xp row type item", xpRow.attrs.type, "item")
eq("xp row item by name", xpRow.attrs.item, "Forever Feast")
ok("xp row missing look", xpRow.text.text:find("missing") ~= nil and xpRow.icon.desat == false)
eq("fire spell known", fireSpell and fireSpell.id, 818)
eq("fire row type spell", fireRow.attrs.type, "spell")
eq("fire row spell", fireRow.attrs.spell, "Basic Campfire")
ok("fire row missing look", fireRow.text.text:find("missing") ~= nil)
-- A larger stack of the other food wins after a bag change (throttled to once a second).
S.bags[2] = { [1] = { itemID = 200, stackCount = 10, name = "Small Feast", tip = XP_TIP } }
Fire("BAG_UPDATE_DELAYED")
Tick(0.2)
state, food = SB.State()
eq("bag rescan throttled", food and food.id, 300)
Tick(1.0)
state, food = SB.State()
eq("bag rescan picks larger total", food and food.id, 200)
eq("larger total count", food and food.count, 18)
eq("xp row item follows", xpRow.attrs.item, "Small Feast")

-- 4. Aura detection ---------------------------------------------------------------------------
S.auras = {
    { spellId = 1126, name = "Mark of the Wild", icon = 1, expirationTime = S.now + 1800, auraInstanceID = 11, tip = { "Increases armor by 105." } },
    { spellId = 90001, name = "Well Fed", icon = 136000, expirationTime = S.now + 900, auraInstanceID = 12, tip = { "Experience gained increased by 10%." } },
    { spellId = 90002, name = "Campfire", icon = 135805, expirationTime = S.now + 60, auraInstanceID = 13, tip = { "Spirit increased." } },
}
Fire("UNIT_AURA", "player")
Tick()
local learned
state, food, fireSpell, learned = SB.State()
eq("xp aura found", state.xp and state.xp.id, 90001)
eq("fire aura found", state.fire and state.fire.id, 90002)
ok("xp learned", learned.xpAuras[90001] == "Well Fed")
ok("fire learned", learned.fireAuras[90002] == "Campfire")
ok("food learned", learned.foods[300] == "Forever Feast" and learned.foods[200] == "Small Feast")
ok("xp row shows time", xpRow.view.look == "active" and xpRow.view.text:match("^%d+:%d%d$") ~= nil)
ok("fire row active", fireRow.view.look == "active")
ok("food still clickable while buffed", xpRow.attrs.type == "item")
local announced = 0
for _, p in ipairs(printed) do if p:find("learned XP food buff spell ID: 90001") then announced = announced + 1 end end
eq("learned once in chat", announced, 1)

-- 5. Combat: no attribute changes, secrets never break anything ---------------------------------
local before = { type = xpRow.attrs.type, item = xpRow.attrs.item }
S.combat = true
S.violations = {}
S.bags = {}                       -- ate the last food in combat (say)
local secretAuras = {
    { spellId = SECRET, name = SECRET, icon = SECRET, expirationTime = SECRET, auraInstanceID = SECRET },
    { spellId = SECRET, name = SECRET, icon = SECRET, expirationTime = SECRET, auraInstanceID = SECRET },
}
S.auras = secretAuras
Fire("BAG_UPDATE_DELAYED")
Fire("UNIT_AURA", "player")
Fire("SPELLS_CHANGED")
Fire("UNIT_AURA", SECRET)          -- a secret unit token: ignored, no error
local okTick, err = pcall(Tick)
ok("secret auras do not error: " .. tostring(err), okTick)
eq("no protected calls in combat", #S.violations, 0)
eq("xp attr untouched in combat", xpRow.attrs.type, before.type)
eq("xp item untouched in combat", xpRow.attrs.item, before.item)
state = SB.State()
ok("frozen in combat", state.frozen == true)
eq("xp buff kept (frozen)", state.xp and state.xp.id, 90001)
ok("xp row still active", xpRow.view.look == "active")
ok("frozen note in tooltip", xpRow.view.tip[#xpRow.view.tip][1]:find("In combat") ~= nil)
-- A learned ID that is readable in combat still matches (name secret).
S.auras = { { spellId = 90001, name = SECRET, icon = SECRET, expirationTime = S.now + 300, auraInstanceID = SECRET } }
Fire("UNIT_AURA", "player")
local calls = S.tipCalls or 0
okTick, err = pcall(Tick)
ok("learned id in combat: " .. tostring(err), okTick)
state = SB.State()
ok("xp time updated by learned ID", state.xp and math.abs(state.xp.exp - (S.now + 300)) < 2)
eq("no tooltip read in combat", S.tipCalls or 0, calls)
-- The index itself secret, or the read refused: frozen, no error.
S.indexSecret = true
Fire("UNIT_AURA", "player")
okTick = pcall(Tick)
ok("secret index ok", okTick)
S.indexSecret = false
S.auraError = true
Fire("UNIT_AURA", "player")
okTick = pcall(Tick)
ok("refused read ok", okTick)
S.auraError = false
-- A frozen buff that runs out during the fight shows missing.
S.auras = secretAuras
Fire("UNIT_AURA", "player")
Tick()
S.now = S.now + 400
pcall(Tick, 0)
ok("expired while frozen = missing", fireRow.view.look == "missing")
eq("still no protected calls in combat", #S.violations, 0)
-- A change that needs new click settings in combat (key-down CVar) waits for the end of combat.
S.keyDown = true
pcall(Tick)
eq("cvar change in combat: no protected calls", #S.violations, 0)
eq("click direction unchanged in combat", xpRow.clicks, "AnyUp")
-- Settings changed in combat wait as well.
Slash("self fire off")
pcall(Tick)
eq("toggle in combat: no protected calls", #S.violations, 0)
ok("fire row still shown until combat ends", fireRow.shown)

-- 6. After combat: re-read, rebind, relayout -------------------------------------------------
S.combat = false
S.auras = {}
Fire("PLAYER_REGEN_ENABLED")
Tick()
state, food = SB.State()
ok("unfrozen", state.frozen == false)
eq("xp gone after combat", state.xp, nil)
eq("food gone after combat", food, nil)
eq("xp row unbound after combat", xpRow.attrs.type, nil)
ok("fire row hidden (option off)", fireRow.shown == false)
eq("panel height one row", panel.h, 18 + 12)
eq("click direction after combat", xpRow.clicks, "AnyDown")
Slash("self fire on")
Tick()
ok("fire row back", fireRow.shown == true)
Slash("self off")
Tick()
ok("strip hidden when both off", panel.shown == false)
Slash("self on")
Tick()
ok("strip back", panel.shown == true)

-- 7. Status, help, menu ---------------------------------------------------------------------
printed = {}
local A = G.GaarBuffsForeverAPI
Slash("status")
local all = table.concat(printed, "\n")
ok("status: learned xp aura", all:find("learned XP food buff IDs: 90001 %(Well Fed%)") ~= nil)
ok("status: learned campfire", all:find("learned campfire buff IDs: 90002 %(Campfire%)") ~= nil)
ok("status: campfire spell", all:find("campfire spell: 818") ~= nil)
ok("status: learned foods", all:find("learned XP food item IDs: 200 %(Small Feast%), 300 %(Forever Feast%)") ~= nil)
ok("status: no error", all:find("last error: none") ~= nil)
printed = {}
Slash("help")
ok("help lists /gbuff self", table.concat(printed, "\n"):find("/gbuff self") ~= nil)
local labels = {}
for _, e in ipairs(A.MenuEntries()) do if e.text then labels[e.text] = e end end
ok("menu: xp food option", labels["Self buff: XP food (click eats one)"] ~= nil)
ok("menu: campfire option", labels["Self buff: campfire (click casts Basic Campfire)"] ~= nil)
labels["Self buff: XP food (click eats one)"].func()
eq("menu toggles the saved key", G.GaarBuffsForeverDB.selfFood, false)
ok("saved learned IDs kept", type(G.GaarBuffsForeverDB.selfLearned) == "table")
Slash("self forget")
state, food, fireSpell, learned = SB.State()
ok("forget clears", next(learned.xpAuras) == nil and next(learned.foods) == nil)

-- 8. Saved variables survive a reload (keys not dropped by BindSavedVariables) -------------------
G.GaarBuffsForeverDB.selfLearned.xpAuras[123] = "Test"
G.GaarBuffsForeverDB.selfPos = { x = 5, y = -7 }
Fire("ADDON_LOADED", "GaarBuffsForever")
ok("learned kept on reload", G.GaarBuffsForeverDB.selfLearned and G.GaarBuffsForeverDB.selfLearned.xpAuras[123] == "Test")
ok("position kept on reload", G.GaarBuffsForeverDB.selfPos and G.GaarBuffsForeverDB.selfPos.x == 5)

print(string.format("buffs_selfbuffs_test: %d checks, %d failed", checks, fails))
if fails > 0 then os.exit(1) end
