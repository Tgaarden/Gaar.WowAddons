-- LuaJIT stub test: GaarBagsForever 1.13.1 - the cross-character gold list survives a changed key
-- (realm spelling, first name vs full name) and never counts one character twice.
-- Run: luajit tools/test/bags_money_test.lua   (from the repo root)
local path = "addons/GaarBagsForever/GaarBagsForever.lua"
local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { Init = InitInventory, Rows = GoldRows, Bind = function() BindSavedVariables() end,"
    .. " Chars = RealmCharacters }\n"

local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local G = setmetatable({}, { __index = function(t, k) return _G[k] end })
G._G = G
local Lib = dofile and nil
G.GaarForever = {
    NewAddon = function() return { Print = noop } end,
    OnOff = function(v) return v and "on" or "off" end,
    InCombat = function() return false end,
    Plain = function(v) return v end,
    Str = function(v) return type(v) == "string" and v ~= "" and v or nil end,
    API = function() return nil end,
    Migrate = noop, Call = noop, RenderMenu = noop,
    PlayerFullName = function() return "Dru Tics" end,
    NamesMatch = function(a, b)
        a, b = a:gsub("%-[^%- ]+$", ""):lower(), b:gsub("%-[^%- ]+$", ""):lower()
        if a == b then return true end
        if #a > #b then a, b = b, a end
        return b:sub(1, #a + 1) == a .. " "
    end,
}
G.CreateFrame = widget
G.SlashCmdList = {}
G.UIParent = widget()
G.GameTooltip = widget()
G.hooksecurefunc = noop
G.UnitName = function() return "Dru" end
G.GetRealmName = function() return "Some Realm" end
G.UnitClass = function() return "Druid", "DRUID" end
G.UnitFactionGroup = function() return "Alliance" end
G.GetMoney = function() return 500000 end
G.GaarBagsForeverDB = {
    inventory = {
        ["SomeRealm"] = { Dru = { gold = 100, class = "DRUID", bags = { [1] = 2 } }, Bob = { gold = 70000 } },
        ["Some Realm"] = { ["Dru Tics"] = { gold = 50, bags = { [1] = 5 } }, Anna = { gold = 30000 } },
    },
}
local f, lerr = loadstring(src, "@GBF"); assert(f, lerr); setfenv(f, G)
local ok, err = pcall(f, "GaarBagsForever")
assert(ok, "load: " .. tostring(err))
local T = G.__T
T.Bind()
T.Init()

local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

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

-- Display dedupe even if an old duplicate key is still around
realm["Dru"] = { gold = 999 }
local rows2, total2 = T.Rows()
eq(#rows2, 3, "duplicate spelling listed once")
eq(total2, 500000 + 70000 + 30000, "duplicate not counted")

if fails == 0 then print("bags_money_test: ok") else os.exit(1) end
