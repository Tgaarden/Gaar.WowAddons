--[[
  GaarProfessionsForever - profession window helpers, on WoW Forever.

  WoW Forever runs classic content on the retail 12.x engine. Its binary carries the retail
  Blizzard_Professions addon and C_TradeSkillUI, and none of the classic GetNumTradeSkills /
  GetTradeSkillInfo / CollapseTradeSkillSubClass globals, so the window is expected to be the
  retail ProfessionsFrame. The classic TradeSkillFrame is still handled, in case a client has it.
  Which one was found is in /gprof status.

    * Collapse-all button (collapseButton, on by default). One +/- button right of the Filter
      button. Minus (some visible category is open) collapses every category; plus (all are
      collapsed) expands them all. Same art and approach as GaarQuestsForever's collapse-all.
        retail   ProfessionsFrame.CraftingPage.RecipeList: the ScrollBox's tree data provider,
                 Blizzard's own dataProvider:SetAllCollapsed(collapsed). The header icons are
                 synced with the buttons' own SetCollapseState. Blizzard rebuilds the provider on
                 every list update (after a craft, a filter change) and then only restores the
                 top-level collapses it stored at the last hide, so after a click on our button the
                 collapse state of the old provider is carried over to the new one (same
                 profession, until the window is closed).
        classic  TradeSkillFrame: CollapseTradeSkillSubClass(0) / ExpandTradeSkillSubClass(0),
                 verified by a rescan of GetTradeSkillInfo header rows, else one header at a time.
    * "Have Part of Materials" (partial, off by default), retail only: a checkbox in the Filter
      menu under Blizzard's "Have Materials", added with Menu.ModifyMenu("MENU_PROFESSIONS_FILTER").
      While checked, the list shows only recipes where you have at least 1 of at least one
      required reagent in your bags; categories left empty are dropped. It filters Blizzard's data
      provider in a hooksecurefunc post-hook on CraftingPage:Init (Blizzard builds a fresh provider
      there on every list update). Turning it off, or a bag change, asks Blizzard for a rebuild by
      flipping one of its own C filters (C_TradeSkillUI.SetOnlyShowSkillUpRecipes) and back, so the
      list is rebuilt by Blizzard's own TRADE_SKILL_LIST_UPDATE handler. The classic
      TradeSkillFrame has no filter: its rows are engine indices, and a real filter there would
      need TradeSkillFrame_Update replaced, which this addon never does.

  Taint: only hooksecurefunc, HookScript, events and Menu.ModifyMenu. No Blizzard function is
  replaced and no Blizzard layout method is called. Collapsing and filtering change Blizzard's
  tree data provider from addon code, so the recipe rows the ScrollBox lays out right after are
  tainted until Blizzard rebuilds the list. The craft calls (C_TradeSkillUI.CraftRecipe,
  CraftEnchant, CraftSalvage) are not protected functions, so Create and Create All still work;
  /gprof status shows whether the crafting form is tainted and any action the client blocked for
  this addon (ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN). Secret values are never compared:
  they count as no value. No combat-log event is registered.

  Saved variables: GaarProfessionsForeverDB (enabled, collapseButton, partial), bound at
  ADDON_LOADED. Everything else lives in the table M (the chunk keeps few file-scope locals).
]]

local _G = _G
local ADDON_NAME = ...
ADDON_NAME = ADDON_NAME or "GaarProfessionsForever"
local VERSION = "1.0.2"
local DOT = " \194\183 "

local BF = _G.GaarForever
local IsSecret, Num, OnOff = BF.IsSecret, BF.Num, BF.OnOff

local INTRO = "Profession window helpers. A +/- button right of the Filter button collapses or expands every category of the recipe list at once, and the Filter menu gets \"Have Part of Materials\": only recipes where you have at least one of the reagents. Nice to know: /gprof collapse does the same as the button; /gprof status says which profession window this client has."

local A = BF.NewAddon("GaarProfessionsForever", { title = "GaarProfessionsForever", version = VERSION, intro = INTRO })

local M = {
    PARTIAL_LABEL = "Have Part of Materials",
    MENU_TAG = "MENU_PROFESSIONS_FILTER",
    path = nil,                 -- "retail" | "classic" | nil
    button = nil,               -- the +/- button
    anchorState = "not built yet",
    collapseState = "not used yet",
    menuState = "not hooked yet",
    menuPlace = "the Filter menu has not been opened yet",
    filterState = "off",
    hooked = {},                -- what is hooked: retailInit, retailFrame, classicUpdate, classicFrame
    sticky = false,             -- our button was used: carry collapse state into Blizzard's next provider
    lastDp = nil, lastProf = nil,
    initCount = 0,              -- CraftingPage:Init calls seen
    nudges = 0,
    reagentCache = {},          -- recipeID -> { itemID, ... } (nil entry: not read yet)
    blocked = nil,              -- last ADDON_ACTION_BLOCKED / _FORBIDDEN naming this addon
    bagWait = false,
}

function M.Print(msg) A:Print(msg) end
function M.Fail(where, err) A.lastError = where .. ": " .. tostring(err) end
function M.Enabled() return A.db ~= nil and A:Get("enabled") and true or false end
function M.Partial() return M.Enabled() and A:Get("partial") and true or false end

-- ---------------------------------------------------------------------------
-- Which profession window
-- ---------------------------------------------------------------------------

-- ProfessionsFrame, its CraftingPage, RecipeList and ScrollBox, or nil.
function M.Retail()
    local pf = _G.ProfessionsFrame
    local cp = type(pf) == "table" and pf.CraftingPage
    local rl = type(cp) == "table" and cp.RecipeList
    local sb = type(rl) == "table" and rl.ScrollBox
    if type(sb) == "table" and type(sb.GetDataProvider) == "function" then return pf, cp, rl, sb end
end

function M.Classic()
    local f = _G.TradeSkillFrame
    if type(f) == "table" and type(f.GetObjectType) == "function" and type(_G.GetNumTradeSkills) == "function"
        and type(_G.GetTradeSkillInfo) == "function" then
        return f
    end
end

function M.DetectPath()
    if M.Retail() then return "retail" end
    if M.Classic() then return "classic" end
end

function M.PathText()
    if M.path == "retail" then return "ProfessionsFrame (retail, Blizzard_Professions)" end
    if M.path == "classic" then return "TradeSkillFrame (classic, Blizzard_TradeSkillUI)" end
    return "none found yet (open a profession once)"
end

-- The tree data provider of the recipe list, or nil.
function M.DataProvider()
    local _, _, _, sb = M.Retail()
    if not sb then return nil end
    local ok, dp = pcall(sb.GetDataProvider, sb)
    if ok and type(dp) == "table" and type(dp.GetRootNode) == "function" then return dp end
end

-- ---------------------------------------------------------------------------
-- Retail: the tree, read only (never the provider's Enumerate / GetSize(true), which cache)
-- ---------------------------------------------------------------------------

function M.NodeData(node)
    if type(node) ~= "table" or type(node.GetData) ~= "function" then return nil end
    local ok, d = pcall(node.GetData, node)
    if ok and type(d) == "table" then return d end
end

function M.IsCollapsed(node)
    if type(node.IsCollapsed) ~= "function" then return false end
    local ok, c = pcall(node.IsCollapsed, node)
    return ok and not IsSecret(c) and c and true or false
end

-- fn(node, data, visible) for every node below `node`, depth first; visible: no collapsed parent.
function M.Walk(node, fn, visible)
    if type(node) ~= "table" or type(node.GetNodes) ~= "function" then return end
    local ok, kids = pcall(node.GetNodes, node)
    if not ok or type(kids) ~= "table" then return end
    for i = 1, #kids do
        local child = kids[i]
        fn(child, M.NodeData(child), visible)
        M.Walk(child, fn, visible and not M.IsCollapsed(child))
    end
end

function M.CategoryKey(d)
    local c = d.categoryInfo
    return (c.unlearned and "u" or "l") .. ":" .. tostring(c.categoryID)
end

-- Visible categories: total, open (not collapsed). nil when there is no list.
function M.RetailScan()
    local dp = M.DataProvider()
    if not dp then return nil end
    local total, open = 0, 0
    M.Walk(dp:GetRootNode(), function(node, d, visible)
        if visible and d and d.categoryInfo then
            total = total + 1
            if not M.IsCollapsed(node) then open = open + 1 end
        end
    end, true)
    return total, open
end

-- The category buttons show their own +/- icon; keep them in step after a collapse from here.
function M.SyncHeaderIcons()
    local _, _, _, sb = M.Retail()
    if not sb or type(sb.ForEachFrame) ~= "function" then return end
    pcall(sb.ForEachFrame, sb, function(frame, node)
        local d = M.NodeData(node)
        if d and d.categoryInfo and type(frame) == "table" and type(frame.SetCollapseState) == "function" then
            pcall(frame.SetCollapseState, frame, M.IsCollapsed(node))
        end
    end)
end

function M.RetailRun(collapse)
    local dp = M.DataProvider()
    if not dp then return false end
    if type(dp.SetAllCollapsed) == "function" then
        dp:SetAllCollapsed(collapse)
        M.collapseState = "data provider SetAllCollapsed(" .. tostring(collapse) .. ")"
    else
        M.Walk(dp:GetRootNode(), function(node, d)
            if d and d.categoryInfo and type(node.SetCollapsed) == "function" then node:SetCollapsed(collapse, false, true) end
        end, true)
        dp:Invalidate()
        M.collapseState = "per-node SetCollapsed(" .. tostring(collapse) .. ") + Invalidate"
    end
    M.sticky = true
    local _, cp = M.Retail()
    local info = type(cp) == "table" and cp.professionInfo
    M.lastDp, M.lastProf = dp, type(info) == "table" and Num(info.professionID) or nil
    M.SyncHeaderIcons()
    return true
end

-- Collapse state of the old provider onto Blizzard's new one (same profession). True if changed.
function M.CarryCollapse(old, new)
    local state, changed = {}, false
    M.Walk(old:GetRootNode(), function(node, d)
        if d and d.categoryInfo then state[M.CategoryKey(d)] = M.IsCollapsed(node) end
    end, true)
    M.Walk(new:GetRootNode(), function(node, d)
        if d and d.categoryInfo and type(node.SetCollapsed) == "function" then
            local want = state[M.CategoryKey(d)]
            if want ~= nil and want ~= M.IsCollapsed(node) then
                node:SetCollapsed(want, false, true)
                changed = true
            end
        end
    end, true)
    return changed
end

-- ---------------------------------------------------------------------------
-- Retail: "Have Part of Materials"
-- ---------------------------------------------------------------------------

-- Item IDs of a recipe's required reagents (every choice of every required slot), or nil when
-- the schematic cannot be read.
function M.ReagentIDs(recipeID)
    local cached = M.reagentCache[recipeID]
    if cached then return cached end
    local t = _G.C_TradeSkillUI
    if type(t) ~= "table" or type(t.GetRecipeSchematic) ~= "function" then return nil end
    local ok, s = pcall(t.GetRecipeSchematic, recipeID, false)
    if not ok or type(s) ~= "table" or type(s.reagentSlotSchematics) ~= "table" then return nil end
    local ids = {}
    for _, slot in ipairs(s.reagentSlotSchematics) do
        local required = type(slot) == "table" and (slot.required == true or Num(slot.reagentType) == 1)
        if required and type(slot.reagents) == "table" then
            for _, r in ipairs(slot.reagents) do
                local id = type(r) == "table" and (Num(r.itemID) or (type(r.item) == "table" and Num(r.item.itemID)))
                if id and id > 0 then ids[#ids + 1] = id end
            end
        end
    end
    M.reagentCache[recipeID] = ids
    return ids
end

function M.ItemCount(id, cache)
    local n = cache[id]
    if n == nil then
        local f = BF.API("C_Item", "GetItemCount") or BF.API("GetItemCount")
        n = Num((BF.Call(f, id))) or 0
        cache[id] = n
    end
    return n
end

-- At least 1 of at least one required reagent in the bags. Unreadable: kept (the safe side).
function M.HasPart(info, cache)
    local recipeID = Num(info.recipeID)
    if not recipeID then return true end
    local ids = M.ReagentIDs(recipeID)
    if not ids then return true end
    for _, id in ipairs(ids) do
        if M.ItemCount(id, cache) > 0 then return true end
    end
    return false
end

-- Drops non-matching recipes and the categories left without any, from Blizzard's provider,
-- without invalidating (the caller does that once). True when anything was removed.
function M.Prune(dp)
    local cache, shown, hidden = {}, 0, 0
    local function Keep(node)
        local ok, kids = pcall(node.GetNodes, node)
        if not ok or type(kids) ~= "table" then return true end
        local any = false
        for i = #kids, 1, -1 do
            local child = kids[i]
            local d = M.NodeData(child)
            if d and d.recipeInfo then
                if M.HasPart(d.recipeInfo, cache) then
                    any = true
                    shown = shown + 1
                else
                    node:Remove(child, true)
                    hidden = hidden + 1
                end
            elseif d and d.categoryInfo then
                if Keep(child) then any = true else node:Remove(child, true) end
            end
        end
        return any
    end
    local root = dp:GetRootNode()
    Keep(root)
    -- The "Unlearned" divider goes when no unlearned category is left.
    local kids, unlearned = root:GetNodes(), false
    for _, child in ipairs(kids) do
        local d = M.NodeData(child)
        if d and d.categoryInfo and d.categoryInfo.unlearned then unlearned = true end
    end
    if not unlearned then
        for i = #kids, 1, -1 do
            local d = M.NodeData(kids[i])
            if d and d.isDivider then root:Remove(kids[i], true) end
        end
    end
    M.filterState = string.format("on: %d recipe row(s) shown, %d hidden", shown, hidden)
    return hidden > 0
end

-- Asks Blizzard to rebuild the list: flips one of its own C filters and back. The rebuild then
-- runs in Blizzard's TRADE_SKILL_LIST_UPDATE handler, and our Init hook filters the new provider.
function M.Nudge()
    local t = _G.C_TradeSkillUI
    if type(t) ~= "table" then return false end
    for _, p in ipairs({ { "GetOnlyShowSkillUpRecipes", "SetOnlyShowSkillUpRecipes" }, { "GetShowLearned", "SetShowLearned" } }) do
        local get, set = t[p[1]], t[p[2]]
        if type(get) == "function" and type(set) == "function" then
            local ok, cur = pcall(get)
            if ok and not IsSecret(cur) and type(cur) == "boolean" then
                pcall(set, not cur)
                pcall(set, cur)
                M.nudges = M.nudges + 1
                return true
            end
        end
    end
    return false
end

-- Filters the list as it is now (turning the filter on needs no rebuild).
function M.ApplyNow()
    local dp = M.DataProvider()
    if not dp then return end
    if M.Prune(dp) then dp:Invalidate() end
    M.SyncHeaderIcons()
    M.Refresh()
end

function M.After(sec, fn)
    local t = _G.C_Timer
    if type(t) == "table" and type(t.After) == "function" then
        t.After(sec, function()
            local ok, err = pcall(fn)
            if not ok then M.Fail("timer", err) end
        end)
        return true
    end
end

function M.OnPartialChanged(on)
    if M.path == "classic" then
        M.filterState = on and "on, but this window has no filter (classic TradeSkillFrame)" or "off"
        return
    end
    if M.path ~= "retail" then
        M.filterState = on and "on: applies when a profession window opens" or "off"
        return
    end
    if on and M.Enabled() then
        M.ApplyNow()
        return
    end
    M.filterState = "off"
    local seen = M.initCount
    if not M.Nudge() then
        M.filterState = "off - the list fills again at its next update (close and reopen the window)"
        return
    end
    M.After(1, function()
        if M.initCount == seen then
            M.filterState = "off - the list fills again at its next update (close and reopen the window)"
        end
    end)
end

-- Bags changed while the filter is on: a recipe may now match. Wait for crafting to end; skip
-- when Blizzard rebuilt the list by itself meanwhile.
function M.OnBags()
    if M.bagWait or M.path ~= "retail" or not M.Partial() then return end
    local pf = M.Retail()
    if not (pf and type(pf.IsShown) == "function" and pf:IsShown()) then return end
    M.bagWait = true
    local seen, tries = M.initCount, 0
    local function Try()
        tries = tries + 1
        local casting = BF.Call(_G.UnitCastingInfo, "player")
        if (IsSecret(casting) or casting ~= nil) and tries < 15 then
            if not M.After(1, Try) then M.bagWait = false end
            return
        end
        M.bagWait = false
        if M.initCount == seen and M.Partial() then M.Nudge() end
    end
    if not M.After(0.5, Try) then M.bagWait = false end
end

-- hooksecurefunc post-hook on ProfessionsFrame.CraftingPage:Init.
function M.OnCraftingInit()
    M.initCount = M.initCount + 1
    if not M.Enabled() then return end
    local dp = M.DataProvider()
    if not dp then return end
    local _, cp = M.Retail()
    local info = type(cp) == "table" and cp.professionInfo
    local prof = type(info) == "table" and Num(info.professionID) or nil
    local changed = false
    if dp ~= M.lastDp then
        if M.sticky and M.lastDp and prof and prof == M.lastProf then
            changed = M.CarryCollapse(M.lastDp, dp)
        elseif prof ~= M.lastProf then
            M.sticky = false
        end
        M.lastDp, M.lastProf = dp, prof
    end
    if M.Partial() then changed = M.Prune(dp) or changed end
    if changed then
        dp:Invalidate()
        M.SyncHeaderIcons()
    end
    M.Refresh()
end

-- Menu.ModifyMenu callback for the Filter menu.
function M.ModifyFilterMenu(owner, root)
    local _, _, rl = M.Retail()
    if not rl or not M.Enabled() then return end
    if owner ~= rl.FilterDropdown and owner ~= rl.FilterButton then return end -- another page's filter
    local MU = _G.MenuUtil
    local function IsSelected() return M.Partial() end
    local function SetSelected() A:Set("partial", not A:Get("partial")) end
    local idx
    if type(MU) == "table" and type(MU.GetElementText) == "function" and type(root.EnumerateElementDescriptions) == "function" then
        local want = type(_G.CRAFT_IS_MAKEABLE) == "string" and _G.CRAFT_IS_MAKEABLE or "Have Materials"
        pcall(function()
            for i, desc in root:EnumerateElementDescriptions() do
                local text = MU.GetElementText(desc)
                if not IsSecret(text) and text == want then idx = i end
            end
        end)
    end
    if idx and type(MU.CreateCheckbox) == "function" and type(root.Insert) == "function" then
        root:Insert(MU.CreateCheckbox(M.PARTIAL_LABEL, IsSelected, SetSelected), idx + 1)
        M.menuPlace = "under \"Have Materials\""
    else
        root:CreateCheckbox(M.PARTIAL_LABEL, IsSelected, SetSelected)
        M.menuPlace = "at the end (\"Have Materials\" not found)"
    end
end

function M.HookMenu()
    if M.menuHooked then return end
    local menu = _G.Menu
    if type(menu) ~= "table" or type(menu.ModifyMenu) ~= "function" then
        M.menuState = "this client has no Menu.ModifyMenu"
        return
    end
    local ok, err = pcall(menu.ModifyMenu, M.MENU_TAG, function(owner, root)
        local ok2, err2 = pcall(M.ModifyFilterMenu, owner, root)
        if not ok2 then M.Fail("filter menu", err2) end
    end)
    M.menuHooked = ok
    M.menuState = ok and ("hooked (" .. M.MENU_TAG .. ")") or ("failed: " .. tostring(err))
end

-- ---------------------------------------------------------------------------
-- Classic TradeSkillFrame
-- ---------------------------------------------------------------------------

-- Header rows: headers, open. nil when unreadable.
function M.ClassicScan()
    local n = Num((BF.Call(_G.GetNumTradeSkills)))
    if not n then return nil end
    local headers, open = 0, 0
    for i = 1, n do
        local ok, _, kind, _, expanded = pcall(_G.GetTradeSkillInfo, i)
        if ok and not IsSecret(kind) and kind == "header" then
            headers = headers + 1
            if not IsSecret(expanded) and expanded then open = open + 1 end
        end
    end
    return headers, open
end

-- Bulk call (0 = every header) first, verified by a rescan; else one header at a time, from
-- the end when collapsing because the indices shift.
function M.ClassicRun(collapse)
    local bulk = collapse and _G.CollapseTradeSkillSubClass or _G.ExpandTradeSkillSubClass
    if type(bulk) ~= "function" then return false end
    local function Done()
        local headers, open = M.ClassicScan()
        if not headers then return true end
        if collapse then return open == 0 end
        return open == headers
    end
    pcall(bulk, 0)
    if Done() then
        M.collapseState = "bulk call (" .. (collapse and "CollapseTradeSkillSubClass(0)" or "ExpandTradeSkillSubClass(0)") .. ")"
        return true
    end
    local n = Num((BF.Call(_G.GetNumTradeSkills))) or 0
    local first, last, step = 1, n, 1
    if collapse then first, last, step = n, 1, -1 end
    for i = first, last, step do
        local ok, _, kind, _, expanded = pcall(_G.GetTradeSkillInfo, i)
        if ok and not IsSecret(kind) and kind == "header" and not IsSecret(expanded) and (expanded and true or false) == collapse then
            pcall(bulk, i)
        end
    end
    M.collapseState = "per-header loop"
    return true
end

-- The classic Filter control, by the names classic clients have used.
function M.ClassicAnchor(f)
    local list = {
        { f.FilterButton, "TradeSkillFrame.FilterButton" },
        { f.FilterDropdown, "TradeSkillFrame.FilterDropdown" },
        { _G.TradeSkillFilterButton, "TradeSkillFilterButton" },
        { _G.TradeSkillFrameFilterButton, "TradeSkillFrameFilterButton" },
        { _G.TradeSkillFilterDropdown, "TradeSkillFilterDropdown" },
        { _G.TradeSkillSubClassDropDown, "TradeSkillSubClassDropDown" },
        { _G.TradeSkillFrameAvailableFilterCheckButton, "TradeSkillFrameAvailableFilterCheckButton" },
    }
    for _, c in ipairs(list) do
        if type(c[1]) == "table" and type(c[1].GetObjectType) == "function" then return c[1], c[2] end
    end
end

-- ---------------------------------------------------------------------------
-- The +/- button
-- ---------------------------------------------------------------------------

function M.Scan()
    if M.path == "retail" then return M.RetailScan() end
    if M.path == "classic" then return M.ClassicScan() end
end

function M.Run(collapse)
    if M.path == "retail" then return M.RetailRun(collapse) end
    if M.path == "classic" then return M.ClassicRun(collapse) end
    return false
end

-- Collapse when anything visible is open, else expand. fromChat: say what happened.
function M.ToggleAll(fromChat)
    if not M.Enabled() then
        if fromChat then M.Print("the addon is off (/gprof on).") end
        return
    end
    M.Attach()
    local window = M.path == "retail" and M.Retail() or M.path == "classic" and M.Classic() or nil
    local shown = window and type(window.IsShown) == "function" and window:IsShown()
    local total, open = M.Scan()
    if not shown or not total or total == 0 then
        if fromChat then M.Print("open a profession window first (no categories found).") end
        return
    end
    local collapse = open > 0
    M.Run(collapse)
    M.Refresh()
    if fromChat then M.Print((collapse and "collapsed" or "expanded") .. " all categories (" .. M.collapseState .. ").") end
end

function M.Refresh()
    local btn = M.button
    if not btn then return end
    if not (M.Enabled() and A:Get("collapseButton")) then btn:Hide() return end
    local total, open = M.Scan()
    if not total or total == 0 then btn:Hide() return end
    local plus = open == 0
    if btn.plus == plus and btn:IsShown() then return end
    btn.plus = plus
    btn:SetNormalTexture(plus and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    btn:SetPushedTexture(plus and "Interface\\Buttons\\UI-PlusButton-Down" or "Interface\\Buttons\\UI-MinusButton-Down")
    btn:Show()
end

-- Parent and Filter control for the current path: parent, filter, filterName.
function M.AnchorTarget()
    if M.path == "retail" then
        local _, _, rl = M.Retail()
        if rl.FilterDropdown then return rl, rl.FilterDropdown, "RecipeList.FilterDropdown" end
        if rl.FilterButton then return rl, rl.FilterButton, "RecipeList.FilterButton" end
        return rl, nil, nil
    end
    if M.path == "classic" then
        local f = M.Classic()
        local filter, name = M.ClassicAnchor(f)
        return f, filter, name
    end
end

function M.Place()
    local btn = M.button
    if not btn then return end
    local parent, filter, name = M.AnchorTarget()
    if not parent then return end
    btn:ClearAllPoints()
    if filter then
        btn:SetPoint("LEFT", filter, "RIGHT", 2, 0)
        btn:SetFrameLevel((filter.GetFrameLevel and filter:GetFrameLevel() or parent:GetFrameLevel()) + 2)
        M.anchorState = "attached right of " .. name
    else
        btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -30, -40)
        btn:SetFrameLevel(parent:GetFrameLevel() + 5)
        M.anchorState = "attached at the window's top right (no Filter button found)"
    end
end

function M.Build()
    if M.button or not M.path then return end
    local parent = M.AnchorTarget()
    if not parent then return end
    local btn = _G.CreateFrame("Button", nil, parent)
    btn:SetSize(17, 17)
    btn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetScript("OnClick", function()
        local ok, err = pcall(M.ToggleAll, false)
        if not ok then M.Fail("button", err) end
        pcall(M.Refresh)
    end)
    btn:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_RIGHT")
        tip:SetText(self.plus and "Expand all" or "Collapse all")
        tip:Show()
    end)
    btn:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    -- A category header clicked in Blizzard's list fires no event: re-read the state now and then
    -- while the button is shown (our own frame; a walk of the list, reads only).
    local since = 0
    btn:SetScript("OnUpdate", function(_, dt)
        since = since + (Num(dt) or 0)
        if since < 0.3 then return end
        since = 0
        pcall(M.Refresh)
    end)
    btn:Hide()
    M.button = btn
    M.Place()
end

-- ---------------------------------------------------------------------------
-- Attaching (the profession UI is load-on-demand)
-- ---------------------------------------------------------------------------

function M.HookRetail()
    local pf, cp = M.Retail()
    if not M.hooked.retailInit and type(cp.Init) == "function" then
        M.hooked.retailInit = pcall(_G.hooksecurefunc, cp, "Init", function()
            local ok, err = pcall(M.OnCraftingInit)
            if not ok then M.Fail("Init hook", err) end
        end)
    end
    if not M.hooked.retailFrame and type(pf.HookScript) == "function" then
        M.hooked.retailFrame = pcall(pf.HookScript, pf, "OnShow", function() pcall(M.Place) pcall(M.Refresh) end)
        pcall(pf.HookScript, pf, "OnHide", function() M.sticky = false end)
    end
end

function M.HookClassic()
    local f = M.Classic()
    if not M.hooked.classicUpdate and type(_G.TradeSkillFrame_Update) == "function" then
        M.hooked.classicUpdate = pcall(_G.hooksecurefunc, "TradeSkillFrame_Update", function() pcall(M.Refresh) end)
    end
    if not M.hooked.classicFrame and type(f.HookScript) == "function" then
        M.hooked.classicFrame = pcall(f.HookScript, f, "OnShow", function() pcall(M.Place) pcall(M.Refresh) end)
    end
end

function M.Attach()
    if not A.db then return end
    local path = M.DetectPath()
    if not path then return end
    if M.path and M.path ~= path then return end -- keep the first one found
    M.path = path
    if path == "retail" then M.HookRetail() else M.HookClassic() end
    M.Build()
    M.Refresh()
end

-- ---------------------------------------------------------------------------
-- Settings, status and slash command
-- ---------------------------------------------------------------------------

A:Toggle("enabled", "Professions helper", true, function(on)
    pcall(M.Refresh)
    if A:Get("partial") and M.path == "retail" then
        if on then pcall(M.ApplyNow) else M.Nudge() end
    end
end)
A:Toggle("collapseButton", "Collapse-all button beside Filter", true, function() pcall(M.Refresh) end, { cmd = "button" })
A:Toggle("partial", "Filter: " .. M.PARTIAL_LABEL, false, function(on) M.OnPartialChanged(on) end, { cmd = "partial" })
A:Divider()
A:Button("Collapse / expand all now", function() M.ToggleAll(true) end, { cmd = "collapse" })

function M.CraftTaint()
    local _, cp = M.Retail()
    local sf = type(cp) == "table" and cp.SchematicForm
    if type(sf) ~= "table" or type(_G.issecurevariable) ~= "function" then return "unknown (no crafting form yet)" end
    local ok, secure, by = pcall(_G.issecurevariable, sf, "transaction")
    if not ok then return "unknown" end
    if secure then return "secure" end
    return "tainted by " .. tostring(by or "?") .. " (crafting still works: CraftRecipe is not protected)"
end

function M.StatusLine()
    if not A.db then return "not loaded yet" end
    local window = M.path == "retail" and "ProfessionsFrame (retail)" or M.path == "classic" and "TradeSkillFrame (classic)" or "no window yet"
    local button = M.button and "button attached" or "button not attached"
    return OnOff(M.Enabled()) .. DOT .. window .. DOT .. button .. DOT .. "partial filter " .. OnOff(M.Partial())
end
A.statusFn = M.StatusLine

function M.PrintStatus()
    A:PrintStatus()
    M.Print("  window: " .. M.PathText())
    M.Print("  button: " .. (M.button and M.anchorState or "not attached (" .. (M.path and "not built" or "no profession window yet") .. ")"))
    M.Print("  collapse: " .. (M.path == "retail" and "data provider SetAllCollapsed"
        or M.path == "classic" and "CollapseTradeSkillSubClass / ExpandTradeSkillSubClass" or "-") .. "; last: " .. M.collapseState)
    if M.path == "classic" then
        M.Print("  filter: not available on the classic TradeSkillFrame")
    else
        M.Print("  filter menu: " .. M.menuState .. DOT .. M.menuPlace)
        M.Print("  filter: " .. (M.Partial() and M.filterState or "off") .. DOT .. "list rebuilds seen: " .. M.initCount
            .. DOT .. "rebuild requests: " .. M.nudges)
        M.Print("  crafting form: " .. M.CraftTaint())
    end
    M.Print("  blocked actions: " .. (M.blocked or "none"))
    if not A.lastError then M.Print("  last error: none") end
end

A:Slash({ "/gprof", "/gaarprofessionsforever" }, { status = function() M.PrintStatus() end })

A:API({ StatusLine = M.StatusLine })

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

A:On("ADDON_LOADED", function(_, name)
    if name == ADDON_NAME then
        A:InitDB("GaarProfessionsForeverDB", {})
        M.HookMenu()
        M.Attach()
    elseif name == "Blizzard_Professions" or name == "Blizzard_TradeSkillUI" then
        M.HookMenu()
        M.Attach()
    end
end)
A:On("PLAYER_LOGIN", function() M.HookMenu() M.Attach() end)
A:On("TRADE_SKILL_SHOW", function() M.Attach() end)
A:On("TRADE_SKILL_LIST_UPDATE", function() M.Refresh() end)
A:On("TRADE_SKILL_UPDATE", function() M.Refresh() end)
A:On("BAG_UPDATE_DELAYED", function() M.OnBags() end)
local function OnBlocked(event, addon, what)
    if addon == ADDON_NAME then M.blocked = tostring(what) .. " (" .. event .. ")" end
end
A:On("ADDON_ACTION_BLOCKED", OnBlocked)
A:On("ADDON_ACTION_FORBIDDEN", OnBlocked)

M.A = A
_G.GaarProfessionsForeverAPI._M = M -- for tools/test
