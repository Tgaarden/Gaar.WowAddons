-- LuaJIT stub test: GaarBagsForever gold across characters.
--   1.13.1: the gold list survives a changed key (realm spelling, first name vs full name) and never
--           counts one character twice.
--   1.13.2: the hover works end to end (ADDON_LOADED, PLAYER_LOGIN, the bag window, a hover on a
--           coin button) also when the money frame has no global name and its coin buttons sit a
--           level deeper (retail-engine layout), and through the IsMouseOver poll when no frame
--           takes the mouse; another tooltip is never replaced; errors are kept for /gbf status;
--           a first-name login never swallows other characters; characters recorded before the
--           rename (BetterBagsForeverDB, bridge folder) are merged into a non-empty DB, once.
-- Run: luajit tools/test/bags_money_test.lua   (from the repo root)
local path = "addons/GaarBagsForever/GaarBagsForever.lua"
local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { Init = InitInventory, Rows = GoldRows, Bind = function() BindSavedVariables() end,"
    .. " Chars = RealmCharacters, Gold = Gold, Keys = Keys, HookMoney = HookMoneyFrames, PrintGold = PrintGold }\n"

local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end
local function ok(v, msg) if not v then fails = fails + 1; print("FAIL " .. msg) end end

local noop = function() end

-- ---- a small frame model: scripts, hooks, children, names, mouse --------------------------------
local Frame = {}
local function NewFrame(name, parent)
    local f = setmetatable({ _scripts = {}, _hooks = {}, _kids = {}, _name = name, _shown = true,
        _mouse = false, _over = false, _parent = parent }, Frame)
    if parent then parent._kids[#parent._kids + 1] = f end
    return f
end
Frame.__index = function(t, k)
    local m = rawget(Frame, k)
    if m then return m end
    if type(k) == "string" and k:match("^Create") then return function(self) return NewFrame(nil, self) end end
    if type(k) == "string" and k:match("^[A-Z]") then return noop end
    return nil
end
function Frame:GetName() return self._name end
function Frame:GetChildren() return unpack(self._kids) end
function Frame:HasScript() return true end
function Frame:SetScript(ev, fn) self._scripts[ev] = fn end
function Frame:GetScript(ev) return self._scripts[ev] end
function Frame:HookScript(ev, fn) self._hooks[ev] = self._hooks[ev] or {}; table.insert(self._hooks[ev], fn) end
function Frame:Fire(ev, ...)
    if self._scripts[ev] then self._scripts[ev](self, ...) end
    for _, fn in ipairs(self._hooks[ev] or {}) do fn(self, ...) end
end
function Frame:IsShown() return self._shown end
function Frame:IsVisible() return self._shown and (not self._parent or self._parent:IsVisible()) end
function Frame:Show() self._shown = true end
function Frame:Hide() self._shown = false; self:Fire("OnHide") end
function Frame:IsMouseOver() return self._over end
function Frame:EnableMouse(on) self._mouse = on and true or false end
function Frame:IsMouseEnabled() return self._mouse end
function Frame:SetPoint() end
function Frame:ClearAllPoints() end
function Frame:GetPoint() return nil end
function Frame:GetNumPoints() return 0 end
function Frame:IsProtected() return false end
function Frame:GetFrameLevel() return 1 end
function Frame:GetFrameStrata() return "MEDIUM" end
function Frame:RegisterEvent(ev) self._events = self._events or {}; self._events[ev] = true end

local function NewTooltip()
    local tip = NewFrame("GameTooltip")
    tip._shown = false
    tip.lines = {}
    function tip:SetOwner(owner) self.owner = owner; self.lines = {}; self._shown = false end
    function tip:GetOwner() return self.owner end
    function tip:AddLine(t) self.lines[#self.lines + 1] = t end
    function tip:AddDoubleLine(l, r) self.lines[#self.lines + 1] = tostring(l) .. "=" .. tostring(r) end
    function tip:Show() self._shown = true end
    function tip:Hide() self._shown = false; self.owner = nil; self:Fire("OnHide") end
    return tip
end

-- ---- one fresh copy of the addon per scenario -------------------------------------------------
local function Load(opts)
    opts = opts or {}
    local G = setmetatable({}, { __index = function(t, k) return _G[k] end })
    G._G = G
    local created = {}
    G.GaarForever = {
        NewAddon = function() return { Print = function(_, m) if opts.printed then opts.printed[#opts.printed + 1] = m end end } end,
        OnOff = function(v) return v and "on" or "off" end,
        InCombat = function() return opts.combat and true or false end,
        Plain = function(v) return v end,
        Str = function(v) return type(v) == "string" and v ~= "" and v or nil end,
        API = function() return nil end,
        Migrate = noop, Call = noop, RenderMenu = noop,
        PlayerFullName = function() return opts.fullName end,
        StripRealm = function(n) return type(n) == "string" and (n:gsub("%-[^%- ]+$", "")) or nil end,
        NamesMatch = function(a, b)
            a, b = a:gsub("%-[^%- ]+$", ""):lower(), b:gsub("%-[^%- ]+$", ""):lower()
            if a == b then return true end
            if #a > #b then a, b = b, a end
            return b:sub(1, #a + 1) == a .. " "
        end,
    }
    G.CreateFrame = function(_, name)
        local f = NewFrame(name, nil)
        created[#created + 1] = f
        return f
    end
    G.SlashCmdList = {}
    G.UIParent = NewFrame("UIParent")
    G.GameTooltip = NewTooltip()
    G.hooksecurefunc = noop
    G.time = os.time
    G.UnitName = function() return opts.unitName or "Dru" end
    G.GetRealmName = function() return "Some Realm" end
    G.UnitClass = function() return "Druid", opts.class or "DRUID" end
    G.UnitFactionGroup = function() return "Alliance" end
    G.GetMoney = function() return 500000 end
    G.GaarBagsForeverDB = opts.db
    G.BetterBagsForeverDB = opts.oldDB
    if opts.bags then opts.bags(G) end
    local f, lerr = loadstring(src, "@GBF"); assert(f, lerr); setfenv(f, G)
    local okLoad, err = pcall(f, "GaarBagsForever")
    assert(okLoad, "load: " .. tostring(err))
    G.__created = created
    return G, G.__T
end

local function Fire(G, event, arg1)
    for _, f in ipairs(G.__created) do
        if f._events and f._events[event] and f._scripts.OnEvent then
            local okE, err = pcall(f._scripts.OnEvent, f, event, arg1)
            if not okE then print("  (event " .. event .. " raised: " .. tostring(err) .. ")") end
        end
    end
end

local function Poll(G)
    for _, f in ipairs(G.__created) do
        if f._scripts.OnUpdate then f._scripts.OnUpdate(f, 0.2) end
    end
end

-- ---- 1. 1.13.1: keys merged, nothing counted twice ---------------------------------------------
do
    local G, T = Load({ fullName = "Dru Tics", db = {
        inventory = {
            ["SomeRealm"] = { Dru = { gold = 100, class = "DRUID", bags = { [1] = 2 } }, Bob = { gold = 70000 } },
            ["Some Realm"] = { ["Dru Tics"] = { gold = 50, bags = { [1] = 5 } }, Anna = { gold = 30000 } },
        },
    } })
    T.Bind()
    T.Init()
    local inv = G.GaarBagsForeverDB.inventory
    eq(inv["SomeRealm"], nil, "realm spelling variant folded in")
    local realm = inv["Some Realm"]
    eq(realm["Dru"], nil, "first-name key merged away")
    eq(realm["Dru Tics"].gold, 500000, "live gold wins")
    eq(realm["Dru Tics"].bags[1], 5, "item counts kept (larger)")
    eq(realm["Bob"].gold, 70000, "other realm-variant character kept")
    eq(realm["Anna"].gold, 30000, "other character kept")
    local rows, total = T.Rows()
    eq(#rows, 3, "three characters listed once each")
    eq(total, 500000 + 70000 + 30000, "no double count")
    eq(rows[1].name, "Dru Tics", "you first")
    realm["Dru"] = { gold = 999 }
    local rows2, total2 = T.Rows()
    eq(#rows2, 3, "duplicate spelling listed once")
    eq(total2, 500000 + 70000 + 30000, "duplicate not counted")
end

-- ---- 2. a first-name login never swallows other characters (1.13.1 data loss) -------------------
do
    local G, T = Load({ fullName = nil, unitName = "Dru", db = {
        inventory = { ["Some Realm"] = {
            ["Dru Tics"] = { gold = 1000, class = "DRUID" },
            ["Dru Other"] = { gold = 2000, class = "DRUID" },
            Anna = { gold = 3000, class = "MAGE" },
        } },
    } })
    T.Bind()
    T.Init()
    local realm = G.GaarBagsForeverDB.inventory["Some Realm"]
    ok(realm["Dru Tics"] and realm["Dru Tics"].gold == 1000, "Dru Tics kept under a first-name login")
    ok(realm["Dru Other"] and realm["Dru Other"].gold == 2000, "Dru Other kept under a first-name login")
    local rows, total = T.Rows()
    eq(#rows, 4, "Dru (me), Dru Tics, Dru Other, Anna all listed")
    eq(total, 500000 + 1000 + 2000 + 3000, "first-name login: all counted")
end

-- ---- 3. a first name of another class is not folded into you -----------------------------------
do
    local G, T = Load({ fullName = "Dru Tics", db = {
        inventory = { ["Some Realm"] = { Dru = { gold = 777, class = "MAGE" } } },
    } })
    T.Bind()
    T.Init()
    local realm = G.GaarBagsForeverDB.inventory["Some Realm"]
    ok(realm["Dru"] and realm["Dru"].gold == 777, "other-class first-name record kept")
    local rows = T.Rows()
    eq(#rows, 2, "other-class Dru listed beside you")
end

-- ---- 4. the hover end to end, retail-engine layout: nameless money frame, coins a level deeper ---
local function RetailBags(G)
    local bag = NewFrame("ContainerFrameCombinedBags")
    G.ContainerFrameCombinedBags = bag
    local money = NewFrame(nil, bag)          -- no global name
    bag.MoneyFrame = money
    local inner = NewFrame(nil, money)
    money.Display = inner
    for _, coin in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
        local b = NewFrame(nil, inner)
        b._mouse = true
        inner[coin] = b
    end
    G.__money = money
    G.__inner = inner
end

do
    local G, T = Load({ fullName = "Dru Tics", bags = RetailBags, db = {
        locked = false,
        inventory = { ["Some Realm"] = { Bob = { gold = 70000, class = "WARRIOR" }, Anna = { gold = 30000 } } },
    } })
    Fire(G, "ADDON_LOADED", "GaarBagsForever")
    Fire(G, "PLAYER_LOGIN")
    local gold = G.__inner.GoldButton
    ok(T.Gold.targets[gold] ~= nil, "nested GoldButton hooked")
    gold:Fire("OnEnter")
    local tip = G.GameTooltip
    eq(tip.owner, gold, "tooltip owned by the coin button")
    ok(tip._shown, "tooltip shown")
    local text = table.concat(tip.lines, "|")
    ok(text:find("Gold on Some Realm", 1, true), "header line")
    ok(text:find("Bob", 1, true) and text:find("Anna", 1, true) and text:find("Dru Tics", 1, true), "all three characters")
    eq(T.Gold.diag.source, "hook", "diag: via hook")
    eq(T.Gold.diag.result, 3, "diag: three rows")
    -- the poll does not add a second copy while the hook's tooltip is up
    G.__money._over = true
    local n = #tip.lines
    Poll(G)
    eq(#tip.lines, n, "poll leaves the hook's tooltip alone")
    gold:Fire("OnLeave")
    ok(not tip._shown, "hidden on leave")
    G.__money._over = false
    Poll(G)

    local status = table.concat(T.Gold.StatusLines(), "\n")
    ok(status:find("ContainerFrameCombinedBags.MoneyFrame", 1, true), "status: money frame path")
    ok(status:find("last gold hover", 1, true) and status:find("via hook", 1, true), "status: last hover")
    ok(status:find("Some Realm (this realm): 3", 1, true), "status: characters per realm")
    ok(status:find("not loaded", 1, true), "status: old DB not loaded")
end

-- ---- 5. the poll: no frame takes the mouse, IsMouseOver still shows the gold ---------------------
do
    local G, T = Load({ fullName = "Dru Tics", bags = function(G)
        local bag = NewFrame("ContainerFrameCombinedBags")
        G.ContainerFrameCombinedBags = bag
        local money = NewFrame("ContainerFrameCombinedBagsMoneyFrame", bag)
        bag.MoneyFrame = money
        G.ContainerFrameCombinedBagsMoneyFrame = money
        G.__money = money
    end, db = { inventory = { ["Some Realm"] = { Bob = { gold = 70000 } } } } })
    Fire(G, "ADDON_LOADED", "GaarBagsForever")
    Fire(G, "PLAYER_LOGIN")
    local tip = G.GameTooltip
    G.__money._over = true
    Poll(G)
    ok(tip._shown and tip.owner == G.__money, "poll shows the gold on the money frame")
    eq(T.Gold.diag.source, "poll", "diag: via poll")
    local n = #tip.lines
    Poll(G)
    eq(#tip.lines, n, "poll adds the lines once")
    G.__money._over = false
    Poll(G)
    ok(not tip._shown, "poll hides it when the mouse leaves")

    -- someone else's tooltip is never replaced
    local item = NewFrame("SomeItemButton")
    tip:SetOwner(item); tip:AddLine("Linen Cloth"); tip:Show()
    G.__money._over = true
    Poll(G)
    eq(tip.owner, item, "another tooltip kept")
    eq(tip.lines[1], "Linen Cloth", "its lines kept")
    G.__money._over = false
    Poll(G)

    -- an error inside the hover is kept for /gbf status, not swallowed
    tip:Hide()
    local orig = tip.AddDoubleLine
    tip.AddDoubleLine = function() error("boom") end
    G.__money._over = true
    Poll(G)
    tip.AddDoubleLine = orig
    ok(T.Gold.diag.err and T.Gold.diag.err:find("boom", 1, true), "error recorded")
    ok(table.concat(T.Gold.StatusLines(), "\n"):find("last gold error", 1, true), "status: last error")
end

-- ---- 6. characters recorded before the rename are merged into a non-empty DB, once ---------------
do
    local old = { inventory = {
        ["Some Realm"] = { Old = { gold = 12345, class = "ROGUE" }, Bob = { gold = 1 }, Dru = { gold = 5, class = "DRUID" } },
        ["Other Realm"] = { Far = { gold = 99 } },
    }, __migratedTo = "GaarBagsForeverDB" }
    local G, T = Load({ fullName = "Dru Tics", oldDB = old, db = {
        reverse = true,
        inventory = { ["Some Realm"] = { Bob = { gold = 70000 }, ["Dru Tics"] = { gold = 10, class = "DRUID" } } },
    } })
    T.Bind()
    T.Init()
    local inv = G.GaarBagsForeverDB.inventory
    eq(inv["Some Realm"].Old and inv["Some Realm"].Old.gold, 12345, "old character merged in")
    eq(inv["Some Realm"].Bob.gold, 70000, "newer gold kept")
    eq(inv["Some Realm"].Dru, nil, "old first-name record of you folded into the full name")
    eq(inv["Other Realm"].Far.gold, 99, "old other realm merged in")
    eq(old.__gbfInventoryMerged, true, "old table marked")
    ok(T.Keys.oldState:find("merged in now", 1, true), "old state says merged")
    inv["Some Realm"].Old.gold = 1
    T.Bind()
    eq(inv["Some Realm"].Old.gold, 1, "merged only once")
    local rows, total = T.Rows()
    eq(#rows, 3, "you, Bob, Old")
    eq(total, 500000 + 70000 + 1, "total over the merged list")
end

-- ---- 7. /gbf gold prints other realms and the diagnosis ---------------------------------------
do
    local printed = {}
    local _, T = Load({ fullName = "Dru Tics", printed = printed, db = {
        inventory = { ["Some Realm"] = { Bob = { gold = 70000 } }, ["Other Realm"] = { Far = { gold = 99 } } },
    } })
    T.Bind()
    T.Init()
    T.PrintGold()
    local all = table.concat(printed, "\n")
    ok(all:find("gold on Some Realm", 1, true), "gold: this realm")
    ok(all:find("other realm Other Realm", 1, true) and all:find("Far", 1, true), "gold: other realm listed")
    ok(all:find("gold data: GaarBagsForeverDB.inventory", 1, true), "gold: SV in use")
    ok(all:find("gold hover:", 1, true), "gold: hover line")
end

if fails == 0 then print("bags_money_test: ok") else os.exit(1) end
