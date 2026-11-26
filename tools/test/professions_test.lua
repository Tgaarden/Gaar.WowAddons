-- LuaJIT stub test: GaarProfessionsForever 1.0 - collapse-all (retail tree + classic headers), the
-- "Have Part of Materials" filter (prune, empty categories, divider, carry-over), the Filter menu entry
-- and the hooks (only hooksecurefunc / HookScript / Menu.ModifyMenu; nothing of Blizzard's replaced).
-- Run: luajit tools/test/professions_test.lua   (from the repo root)
local fails = 0
local function eq(n, got, want) if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end end
local function noop() end

-- A frame stub: every method exists; scripts and points are recorded.
local function Frame()
    local f = { scripts = {}, shown = false, level = 1 }
    return setmetatable(f, { __index = function(t, k)
        if k == "SetScript" then return function(self, s, fn) self.scripts[s] = fn end end
        if k == "HookScript" then return function(self, s, fn) self.scripts["hook:" .. s] = fn end end
        if k == "Show" then return function(self) self.shown = true end end
        if k == "Hide" then return function(self) self.shown = false end end
        if k == "IsShown" then return function(self) return self.shown end end
        if k == "GetFrameLevel" then return function(self) return self.level end end
        if k == "SetNormalTexture" then return function(self, tex) self.tex = tex end end
        if k == "SetPoint" then return function(self, ...) self.point = { ... } end end
        if k == "GetObjectType" then return function() return "Frame" end end
        return noop
    end })
end

-- Blizzard's tree data provider, reduced to what the addon uses (same names and semantics).
local Node = {}
Node.__index = Node
local function NewNode(dp, parent, data) return setmetatable({ nodes = {}, dataProvider = dp, parent = parent, data = data }, Node) end
function Node:GetNodes() return self.nodes end
function Node:GetData() return self.data end
function Node:Insert(data) local n = NewNode(self.dataProvider, self, data); table.insert(self.nodes, n); return n end
function Node:Remove(node, skip)
    for i, n in ipairs(self.nodes) do
        if n == node then table.remove(self.nodes, i); if not skip then self.dataProvider:Invalidate() end; return n end
    end
end
function Node:SetCollapsed(c, affect, skip)
    self.collapsed = c
    if affect then for _, n in ipairs(self.nodes) do n:SetCollapsed(c, true, true) end end
    if not skip then self.dataProvider:Invalidate() end
end
function Node:IsCollapsed() return self.collapsed end
local function NewProvider()
    local dp = { invalidations = 0 }
    dp.node = NewNode(dp, nil, nil)
    function dp:GetRootNode() return self.node end
    function dp:Invalidate() self.invalidations = self.invalidations + 1 end
    function dp:SetAllCollapsed(c) for _, n in ipairs(self.node.nodes) do n:SetCollapsed(c, true, true) end self:Invalidate() end
    return dp
end

-- Recipes: id -> reagent item ids. Bags: item id -> count.
local REAGENTS = { [1] = { 101 }, [2] = { 102, 103 }, [3] = { 104 }, [4] = { 105 }, [5] = { 106 } }
local bags = { [101] = 3, [103] = 1 }

local function BuildProvider()
    local dp = NewProvider()
    local root = dp:GetRootNode()
    local armor = root:Insert({ categoryInfo = { categoryID = 10, name = "Armor" } })
    armor:Insert({ topPadding = true })
    armor:Insert({ recipeInfo = { recipeID = 1 } })
    armor:Insert({ recipeInfo = { recipeID = 2 } })
    armor:Insert({ bottomPadding = true })
    local weapons = root:Insert({ categoryInfo = { categoryID = 20, name = "Weapons" } })
    local sub = weapons:Insert({ categoryInfo = { categoryID = 21, name = "Swords" } })
    sub:Insert({ recipeInfo = { recipeID = 3 } })
    root:Insert({ isDivider = true })
    local un = root:Insert({ categoryInfo = { categoryID = 10, name = "Armor", unlearned = true } })
    un:Insert({ recipeInfo = { recipeID = 4 } })
    return dp
end

-- Globals the addon and the library read.
local hooks, menuCallbacks = {}, {}
_G.issecretvalue = function() return false end
_G.CreateFrame = function() return Frame() end
_G.SlashCmdList = {}
_G.hooksecurefunc = function(t, name, fn)
    if type(t) == "string" then t, name, fn = _G, t, name end
    local orig = t[name]
    hooks[#hooks + 1] = name
    t[name] = function(...) local r = { orig(...) }; fn(...); return unpack(r) end
end
_G.Menu = { ModifyMenu = function(tag, cb) menuCallbacks[tag] = cb end }
_G.MenuUtil = {
    GetElementText = function(d) return d.text end,
    CreateCheckbox = function(text, isSel, setSel) return { text = text, isSel = isSel, setSel = setSel } end,
}
_G.CRAFT_IS_MAKEABLE = "Have Materials"
local filterFlips = 0
local skillUp = false
_G.C_TradeSkillUI = {
    GetRecipeSchematic = function(id)
        local slots = {}
        for _, item in ipairs(REAGENTS[id] or {}) do
            slots[#slots + 1] = { required = true, reagentType = 1, reagents = { { itemID = item } } }
        end
        slots[#slots + 1] = { required = false, reagentType = 0, reagents = { { itemID = 999 } } } -- optional: ignored
        return { reagentSlotSchematics = slots }
    end,
    GetOnlyShowSkillUpRecipes = function() return skillUp end,
    SetOnlyShowSkillUpRecipes = function(v) skillUp = v; filterFlips = filterFlips + 1 end,
}
bags[999] = 5 -- an optional reagent in the bags must not make a recipe match
_G.C_Item = { GetItemCount = function(id) return bags[id] or 0 end }
_G.C_Timer = { After = function(_, fn) fn() end }

-- The retail window.
local dp = BuildProvider()
local filter = Frame()
local scrollBox = Frame()
scrollBox.GetDataProvider = function() return dp end
scrollBox.ForEachFrame = function(_, fn)
    for _, n in ipairs(dp:GetRootNode():GetNodes()) do
        local fr = { SetCollapseState = function(self, c) self.state = c end }
        fn(fr, n)
    end
end
local recipeList = Frame(); recipeList.ScrollBox = scrollBox; recipeList.FilterDropdown = filter
local craftingPage = { RecipeList = recipeList, professionInfo = { professionID = 164 }, SchematicForm = {} }
local initCalls = 0
function craftingPage.Init(self) initCalls = initCalls + 1 end
local origInit = craftingPage.Init
local pf = Frame(); pf.CraftingPage = craftingPage; pf.shown = true
_G.ProfessionsFrame = pf

dofile("addons/GaarForever/Lib.lua")
local chunk = assert(loadfile("addons/GaarProfessionsForever/GaarProfessionsForever.lua"))
chunk("GaarProfessionsForever")
local M = _G.GaarProfessionsForeverAPI._M
local A = M.A
local ev = A.eventFrame.scripts.OnEvent
local function fire(e, ...) ev(nil, e, ...) end

fire("ADDON_LOADED", "GaarProfessionsForever")
eq("path", M.path, "retail")
eq("button built", M.button ~= nil, true)
eq("anchored to filter", M.button.point and M.button.point[2], filter)
eq("init hooked, not replaced by hand", craftingPage.Init ~= origInit and hooks[1] == "Init", true)
eq("menu hooked", type(menuCallbacks["MENU_PROFESSIONS_FILTER"]), "function")

-- Collapse all: three top-level categories visible and open.
local total, open = M.RetailScan()
eq("scan total", total, 4) -- Armor, Weapons, Swords (inside open Weapons), unlearned Armor
eq("scan open", open, 4)
eq("button shows minus", M.button.plus, false)
M.ToggleAll(false)
total, open = M.RetailScan()
eq("collapsed: visible", total, 3)
eq("collapsed: open", open, 0)
eq("button shows plus", M.button.plus, true)
M.ToggleAll(false)
total, open = M.RetailScan()
eq("expanded again", open, 4)

-- Blizzard rebuilds after a craft: our collapse state is carried over (same profession).
M.ToggleAll(false) -- collapse
dp = BuildProvider()
craftingPage:Init()
total, open = M.RetailScan()
eq("carry-over keeps collapsed", open, 0)
M.ToggleAll(false) -- expand

-- Filter menu: our checkbox lands right under Have Materials.
local root = { list = { { text = "Has skill up" }, { text = "Have Materials" }, { text = "Slots" } } }
function root:EnumerateElementDescriptions() return ipairs(self.list) end
function root:Insert(d, i) table.insert(self.list, i, d) end
function root:CreateCheckbox(t) self.list[#self.list + 1] = { text = t } end
menuCallbacks["MENU_PROFESSIONS_FILTER"](filter, root)
eq("menu entry placed", root.list[3].text, "Have Part of Materials")
eq("other page's menu untouched", (function() local r = { list = {} }; function r:EnumerateElementDescriptions() return ipairs(self.list) end
    function r:CreateCheckbox(t) self.list[#self.list + 1] = t end; menuCallbacks["MENU_PROFESSIONS_FILTER"](Frame(), r); return #r.list end)(), 0)

-- Tick it: recipe 1 (101 x3) and 2 (has 103, not 102) stay; 3 and 4 go; Weapons/Swords and the
-- unlearned Armor become empty and go, and so does the divider.
root.list[3].setSel()
eq("partial saved", A.db.partial, true)
local kids = dp:GetRootNode():GetNodes()
eq("only Armor left", #kids, 1)
eq("Armor kept", kids[1].data.categoryInfo.categoryID, 10)
local recipes = 0
for _, n in ipairs(kids[1].nodes) do if n.data.recipeInfo then recipes = recipes + 1 end end
eq("two recipes kept", recipes, 2)
eq("invalidated", dp.invalidations > 0, true)

-- A rebuild by Blizzard is filtered again.
dp = BuildProvider()
craftingPage:Init()
eq("rebuild filtered", #dp:GetRootNode():GetNodes(), 1)

-- New item in the bags: a rebuild is requested (the C filter flips and comes back).
pf.shown = true
bags[104] = 1
local flips0 = filterFlips
fire("BAG_UPDATE_DELAYED")
eq("bag change asks for a rebuild", filterFlips, flips0 + 2)
eq("filter restored", skillUp, false)

-- Untick: rebuild requested, nothing pruned on the next provider.
root.list[3].setSel()
eq("partial off", A.db.partial, false)
dp = BuildProvider()
craftingPage:Init()
eq("off: all categories back", #dp:GetRootNode():GetNodes(), 4)

-- Status line and slash.
eq("status line", M.StatusLine(), "on \194\183 ProfessionsFrame (retail) \194\183 button attached \194\183 partial filter off")
local okSlash = pcall(_G.SlashCmdList.GAARPROFESSIONSFOREVER, "status")
eq("status slash runs", okSlash, true)
eq("no error", A.lastError, nil)

-- Classic path, in a fresh load: header rows and the bulk call.
_G.ProfessionsFrame = nil
local rows = { { "Armor", "header", 0, true }, { "Helm", "optimal" }, { "Weapons", "header", 0, true }, { "Sword", "easy" } }
_G.TradeSkillFrame = Frame(); _G.TradeSkillFrame.shown = true
_G.TradeSkillFrame.FilterButton = Frame()
_G.GetNumTradeSkills = function() return #rows end
_G.GetTradeSkillInfo = function(i) local r = rows[i]; return r[1], r[2], r[3], r[4] end
_G.CollapseTradeSkillSubClass = function(i) for _, r in ipairs(rows) do if r[2] == "header" and (i == 0) then r[4] = false end end end
_G.ExpandTradeSkillSubClass = function(i) for _, r in ipairs(rows) do if r[2] == "header" and (i == 0) then r[4] = true end end end
_G.TradeSkillFrame_Update = noop
_G.GaarProfessionsForeverDB = nil
chunk("GaarProfessionsForever")
M = _G.GaarProfessionsForeverAPI._M
ev = M.A.eventFrame.scripts.OnEvent
ev(nil, "ADDON_LOADED", "GaarProfessionsForever")
eq("classic path", M.path, "classic")
eq("classic anchor", M.anchorState, "attached right of TradeSkillFrame.FilterButton")
M.ToggleAll(false)
eq("classic collapsed", rows[1][4] == false and rows[3][4] == false, true)
eq("classic state", M.collapseState, "bulk call (CollapseTradeSkillSubClass(0))")
M.ToggleAll(false)
eq("classic expanded", rows[1][4] == true and rows[3][4] == true, true)

if fails == 0 then print("professions_test: ok") else os.exit(1) end
