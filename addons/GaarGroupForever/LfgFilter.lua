--[[
  GaarGroupForever - LfgFilter.lua: a role filter for the players under your group finder listing.

  The frames (WoW Forever runs Blizzard_GroupFinder_VanillaStyle, a load-on-demand Blizzard addon):
    LFGParentFrame tab 1 = LFGBrowseFrame. With a listing of your own it searches your activities and
    shows, in LFGBrowseFrame.ScrollBox (a WowScrollBoxList with a tree DataProvider rebuilt by
    LFGBrowseFrame:UpdateResults()):
      * your own row ("Your Listing", searchResultInfo.hasSelf),
      * a "Players" header (LFGBrowseSearchEntryGroupingTemplate, dividerType CategorySolo; its "-" is
        the CollapseIcon texture) over one LFGBrowseNestedSearchEntryTemplate card per solo player
        (numMembers <= 1): name, level, class icon, zone, playstyle and "Roles:" with the player's
        roles from C_LFGList.GetSearchResultPlayerInfo(resultID, 1).lfgRoles = { tank, healer, dps },
      * a "Groups" header over listed groups (never filtered here).
    Send Message / Group Invite act on the selected card (LFGBrowseFrame.selectionBehavior):
    ChatFrameUtil.SendTell / C_PartyInfo.InviteUnit(leaderName).

  What this file does: three role toggles (Tank, Healer, DPS) at the right end of the Players header,
  left of the "-", and a "3 hidden" label. A card is hidden when the player lists roles and none of
  them is switched on. Players listing no role are always shown (they cannot be judged). All three on
  = nothing is touched. The last role that is on cannot be switched off (so the list is never empty
  by mistake); /ggf lfg all switches all three back on. Only while you have a listing of your own.

  Taint: purely visual. A hidden card gets SetAlpha(0) + EnableMouse(false) (so it cannot be clicked or
  selected); a shown one gets them back. The DataProvider, the layout, the selection and every Blizzard
  function are left alone: hooksecurefunc("LFGBrowseSearchEntry_Update") (after Blizzard's own update),
  LFGBrowseFrame:HookScript("OnShow"/"OnHide"), our own events and a light poll on our own frame. No
  field or attribute is written on a Blizzard frame (our state is in weak tables keyed by frame). The
  card that is selected is never hidden, so Group Invite always targets a player you can see. Hidden
  cards leave an empty slot where they were (closing the gap would mean changing Blizzard's list).
  A secret value is never compared: such a player is treated as unknown and shown.
]]

local _G = _G
local API = _G.GaarGroupForeverAPI
local M = API and API._M
if not M then return end

M.Defaults.lfgTank = true
M.Defaults.lfgHealer = true
M.Defaults.lfgDps = true

local L = {
    ROLES = {
        { key = "tank", db = "lfgTank", label = "Tank", plural = "tanks", atlas = "groupfinder-icon-role-large-tank",
          coords = { 0, 19 / 64, 22 / 64, 41 / 64 } },
        { key = "healer", db = "lfgHealer", label = "Healer", plural = "healers", atlas = "groupfinder-icon-role-large-heal",
          coords = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 } },
        { key = "dps", db = "lfgDps", label = "DPS", plural = "DPS", atlas = "groupfinder-icon-role-large-dps",
          coords = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 } },
    },
    ALIASES = { tank = "tank", tanks = "tank", healer = "healer", healers = "healer", heal = "healer", heals = "healer",
        dps = "dps", damage = "dps", damager = "dps" },
    BLIZZ_ADDON = "Blizzard_GroupFinder_VanillaStyle",
    POLL = 0.2,
    installed = false,
    hooked = false,
    hidden = setmetatable({}, { __mode = "k" }), -- cards we hid (frame -> true)
    cache = {},          -- resultID -> { filterable, tank, healer, dps }
    hiddenCount = 0,     -- results of the current list the filter hides
    cardsHidden = 0,     -- cards (frames) hidden right now
    keptSelected = {},   -- resultID -> true: the selected card, kept visible
    elapsed = 0,
}
M.LfgFilter = L

local IsSecret = _G.GaarForever.IsSecret

-- ---------------------------------------------------------------------------
-- Settings and matching (pure, tested headless)
-- ---------------------------------------------------------------------------

function L.RoleByKey(key)
    for _, r in ipairs(L.ROLES) do if r.key == key then return r end end
end

function L.IsOn(key)
    local r = L.RoleByKey(key)
    if not r or not M.db then return true end
    return M.db[r.db] ~= false
end

-- { tank = bool, healer = bool, dps = bool }
function L.Enabled()
    return { tank = L.IsOn("tank"), healer = L.IsOn("healer"), dps = L.IsOn("dps") }
end

function L.AllOn()
    local e = L.Enabled()
    return e.tank and e.healer and e.dps
end

function L.NumOn()
    local n = 0
    for _, r in ipairs(L.ROLES) do if L.IsOn(r.key) then n = n + 1 end end
    return n
end

-- Shown? roles = { tank, healer, dps } (plain booleans), enabled = L.Enabled().
-- Any listed role switched on -> shown. No role listed -> shown (cannot be judged).
function L.Matches(roles, enabled)
    if type(roles) ~= "table" then return true end
    if enabled.tank and enabled.healer and enabled.dps then return true end
    local any = roles.tank or roles.healer or roles.dps
    if not any then return true end
    return (roles.tank and enabled.tank) or (roles.healer and enabled.healer) or (roles.dps and enabled.dps) or false
end

-- Sets one role. Returns ok, message. The last role that is on stays on.
function L.Set(key, on)
    local r = L.RoleByKey(key)
    if not r or not M.db then return false, "unknown role" end
    on = on and true or false
    if not on and L.IsOn(key) and L.NumOn() <= 1 then
        return false, "at least one role stays on (/ggf lfg all switches all three on)"
    end
    M.db[r.db] = on
    L.Changed()
    return true, r.label .. " " .. (on and "shown" or "hidden")
end

function L.Toggle(key) return L.Set(key, not L.IsOn(key)) end

function L.SetAll()
    if not M.db then return end
    for _, r in ipairs(L.ROLES) do M.db[r.db] = true end
    L.Changed()
end

-- ---------------------------------------------------------------------------
-- Reading a search result (never compares a secret value)
-- ---------------------------------------------------------------------------

local function plainBool(v)
    if IsSecret(v) then return nil end
    if v == nil then return false end
    return v and true or false
end

-- Reads the player's roles: { filterable = bool, tank, healer, dps }. filterable = a solo player
-- (not your own row, not a group) whose roles could be read; otherwise the card is never hidden.
function L.ReadResult(resultID)
    local out = { filterable = false }
    if resultID == nil or IsSecret(resultID) then return out end
    local lfg = _G.C_LFGList
    if type(lfg) ~= "table" or type(lfg.GetSearchResultInfo) ~= "function"
        or type(lfg.GetSearchResultPlayerInfo) ~= "function" then return out end
    local ok, info = pcall(lfg.GetSearchResultInfo, resultID)
    if not ok or type(info) ~= "table" then return out end
    local hasSelf, num = plainBool(info.hasSelf), info.numMembers
    if hasSelf == nil or hasSelf or IsSecret(num) or type(num) ~= "number" or num > 1 then return out end
    local ok2, p = pcall(lfg.GetSearchResultPlayerInfo, resultID, 1)
    if not ok2 or type(p) ~= "table" or type(p.lfgRoles) ~= "table" then return out end
    local t, h, d = plainBool(p.lfgRoles.tank), plainBool(p.lfgRoles.healer), plainBool(p.lfgRoles.dps)
    if t == nil or h == nil or d == nil then return out end
    out.filterable, out.tank, out.healer, out.dps = true, t, h, d
    return out
end

function L.Result(resultID)
    if resultID == nil or IsSecret(resultID) then return { filterable = false } end
    local c = L.cache[resultID]
    if not c then c = L.ReadResult(resultID); L.cache[resultID] = c end
    return c
end

-- Filter active: you have a listing and at least one role is off.
function L.HasListing()
    local lfg = _G.C_LFGList
    if type(lfg) ~= "table" then return false end
    return M.Q(lfg.HasActiveEntryInfo) and true or false
end

function L.Active()
    return not L.AllOn() and L.HasListing()
end

function L.ShouldHide(resultID)
    if not L.Active() then return false end
    local r = L.Result(resultID)
    if not r.filterable then return false end
    return not L.Matches(r, L.Enabled())
end

-- ---------------------------------------------------------------------------
-- Cards (visual only)
-- ---------------------------------------------------------------------------

local function isSelected(card)
    local sel = card.Selected
    if type(sel) ~= "table" or type(sel.IsShown) ~= "function" then return false end
    local ok, v = pcall(sel.IsShown, sel)
    return ok and v == true
end

function L.ApplyCard(card)
    if type(card) ~= "table" then return end
    local hide = L.ShouldHide(card.resultID) and not isSelected(card)
    if hide then
        if not L.hidden[card] then
            L.hidden[card] = true
            pcall(card.SetAlpha, card, 0)
            pcall(card.EnableMouse, card, false)
        end
    elseif L.hidden[card] then
        L.hidden[card] = nil
        pcall(card.SetAlpha, card, 1)
        pcall(card.EnableMouse, card, true)
    end
end

-- hooksecurefunc("LFGBrowseSearchEntry_Update", ...): runs after Blizzard filled the card.
function L.OnCardUpdate(card)
    M.Safe("lfg card", L.ApplyCard, card)
end

-- The active frames of the list: calls fn(frame, elementData) for each.
function L.ForEachFrame(fn)
    local f = _G.LFGBrowseFrame
    local box = type(f) == "table" and f.ScrollBox
    if type(box) ~= "table" or type(box.ForEachFrame) ~= "function" then return end
    pcall(box.ForEachFrame, box, function(frame, node)
        fn(frame, node)
        return nil
    end)
end

local function isPlayersHeader(frame, node)
    local data = type(node) == "table" and node.data
    if type(data) == "table" and data.dividerType ~= nil then
        local t = _G.LFGVanillaBrowseDividerType
        local solo = type(t) == "table" and t.CategorySolo or 1
        return data.dividerType == solo
    end
    return false
end

-- Re-applies every card and finds the Players header. Returns the header frame or nil.
function L.Sweep()
    local header, hiddenNow, kept = nil, 0, {}
    L.ForEachFrame(function(frame, node)
        if isPlayersHeader(frame, node) then
            header = frame
        elseif type(frame) == "table" and frame.resultID ~= nil then
            L.ApplyCard(frame)
            if L.hidden[frame] then
                hiddenNow = hiddenNow + 1
            elseif isSelected(frame) and not IsSecret(frame.resultID) then
                kept[frame.resultID] = true -- selected: stays visible, not counted as hidden
            end
        end
    end)
    L.keptSelected = kept
    for card in pairs(L.hidden) do -- a card released back to the pool keeps no stale state
        if type(card) == "table" and type(card.IsShown) == "function" then
            local ok, shown = pcall(card.IsShown, card)
            if ok and not shown then
                L.hidden[card] = nil
                pcall(card.SetAlpha, card, 1)
                pcall(card.EnableMouse, card, true)
            end
        end
    end
    L.cardsHidden = hiddenNow
    return header
end

-- How many results of the current list the filter hides (also those scrolled out of view).
function L.CountHidden()
    local f = _G.LFGBrowseFrame
    local results = type(f) == "table" and f.results
    if type(results) ~= "table" or not L.Active() then return 0 end
    local n, enabled, kept = 0, L.Enabled(), L.keptSelected or {}
    for _, id in ipairs(results) do
        if not IsSecret(id) and not kept[id] then
            local r = L.Result(id)
            if r.filterable and not L.Matches(r, enabled) then n = n + 1 end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Toggles on the Players header (our own frames, parented to LFGBrowseFrame.ScrollBox)
-- ---------------------------------------------------------------------------

function L.TipLines(r)
    local on = L.IsOn(r.key)
    local lines = {
        r.label .. " players: " .. (on and "shown" or "hidden"),
        on and ("Click to hide " .. r.plural .. ". A player stays visible while any of their roles is on.")
            or ("Click to show " .. r.plural .. " again."),
    }
    if on and L.NumOn() <= 1 then lines[#lines + 1] = "The last role that is on cannot be switched off." end
    lines[#lines + 1] = "Only the players under your own listing are filtered. /ggf lfg"
    return lines
end

function L.CreateToggles(parent)
    if L.bar then return L.bar end
    local bar = _G.CreateFrame("Frame", nil, parent)
    bar:SetSize(3 * 20, 18)
    bar:Hide()
    bar.buttons = {}
    local prev
    for i = #L.ROLES, 1, -1 do -- right to left: DPS, Healer, Tank
        local r = L.ROLES[i]
        local b = _G.CreateFrame("Button", nil, bar)
        b:SetSize(18, 18)
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(b)
        local okAtlas = type(icon.SetAtlas) == "function" and pcall(icon.SetAtlas, icon, r.atlas, false)
        if not okAtlas then
            icon:SetTexture(M.ROLE_ICONS)
            icon:SetTexCoord(r.coords[1], r.coords[2], r.coords[3], r.coords[4])
        end
        b.icon = icon
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -2, 0) else b:SetPoint("RIGHT", bar, "RIGHT", 0, 0) end
        b:SetScript("OnClick", function()
            local ok, msg = L.Toggle(r.key)
            if not ok then M.Print(msg) end
            if _G.GameTooltip and _G.GameTooltip.IsOwned and _G.GameTooltip:IsOwned(b) then
                local enter = b:GetScript("OnEnter")
                if enter then enter(b) end
            end
        end)
        M.Tip(b, function() return L.TipLines(r) end)
        bar.buttons[r.key] = b
        prev = b
    end
    local label = bar:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    label:SetPoint("RIGHT", prev, "LEFT", -6, 0)
    bar.label = label
    L.bar = bar
    L.PaintToggles()
    return bar
end

function L.PaintToggles()
    local bar = L.bar
    if not bar then return end
    for key, b in pairs(bar.buttons) do
        local on = L.IsOn(key)
        if b.icon then
            pcall(b.icon.SetDesaturated, b.icon, not on)
            pcall(b.icon.SetAlpha, b.icon, on and 1 or 0.35)
        end
    end
    if bar.label then
        bar.label:SetText(L.hiddenCount > 0 and (L.hiddenCount .. " hidden") or "")
    end
end

-- Puts the toggles on the Players header, or hides them.
function L.PlaceToggles(header)
    local bar = L.bar
    if not bar then return end
    if not header or not L.HasListing() then
        if bar:IsShown() then bar:Hide() end
        L.header = nil
        return
    end
    if L.header ~= header then
        L.header = header
        bar:ClearAllPoints()
        local anchor = header.CollapseIcon or header
        bar:SetPoint("RIGHT", anchor, anchor == header and "RIGHT" or "LEFT", anchor == header and -36 or -8, 0)
        local ok, lvl = pcall(header.GetFrameLevel, header)
        if ok and type(lvl) == "number" then bar:SetFrameLevel(lvl + 10) end
    end
    if not bar:IsShown() then bar:Show() end
end

-- One pass: cards, count, toggles.
function L.Sync()
    if not L.installed then return end
    local header = L.Sweep()
    L.hiddenCount = L.CountHidden() -- cheap: roles are cached per result until the list changes
    L.PlaceToggles(header)
    L.PaintToggles()
end

function L.Changed()
    M.Safe("lfg sync", L.Sync)
end

-- ---------------------------------------------------------------------------
-- Install (Blizzard_GroupFinder_VanillaStyle is load-on-demand)
-- ---------------------------------------------------------------------------

function L.Install()
    if L.installed then return true end
    local f = _G.LFGBrowseFrame
    if type(f) ~= "table" then return false end
    L.installed = true
    if type(_G.hooksecurefunc) == "function" and type(_G.LFGBrowseSearchEntry_Update) == "function" then
        L.hooked = pcall(_G.hooksecurefunc, "LFGBrowseSearchEntry_Update", L.OnCardUpdate)
    end
    -- Parented to the ScrollBox so the list's clipping applies when the header scrolls off the top.
    L.CreateToggles(type(f.ScrollBox) == "table" and f.ScrollBox or f)
    if type(f.HookScript) == "function" then
        pcall(f.HookScript, f, "OnShow", function() L.driver:Show(); M.Safe("lfg sync", L.Sync) end)
        pcall(f.HookScript, f, "OnHide", function() L.driver:Hide() end)
    end
    local ok, shown = pcall(f.IsVisible, f)
    if ok and shown then L.driver:Show() end
    return true
end

function L.OnUpdate(_, dt)
    L.elapsed = L.elapsed + (tonumber(dt) or 0)
    if L.elapsed < L.POLL then return end
    L.elapsed = 0
    M.Safe("lfg sync", L.Sync)
end

function L.OnEvent(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == L.BLIZZ_ADDON then M.Safe("lfg install", L.Install) end
    elseif event == "PLAYER_LOGIN" then
        M.Safe("lfg install", L.Install)
    elseif event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
        if arg1 ~= nil and not IsSecret(arg1) then L.cache[arg1] = nil else L.cache = {} end
    else -- LFG_LIST_SEARCH_RESULTS_RECEIVED, LFG_LIST_ACTIVE_ENTRY_UPDATE
        L.cache = {}
    end
end

L.driver = _G.CreateFrame("Frame")
L.driver:Hide()
L.driver:SetScript("OnUpdate", function(...) local ok, err = pcall(L.OnUpdate, ...); if not ok then M.Fail("lfg", err) end end)
L.driver:SetScript("OnEvent", function(...) local ok, err = pcall(L.OnEvent, ...); if not ok then M.Fail("lfg", err) end end)
for _, ev in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "LFG_LIST_SEARCH_RESULTS_RECEIVED",
    "LFG_LIST_SEARCH_RESULT_UPDATED", "LFG_LIST_ACTIVE_ENTRY_UPDATE" }) do
    M.RegisterEvent(L.driver, ev)
end
M.Safe("lfg install", L.Install) -- the Blizzard addon may already be loaded

-- ---------------------------------------------------------------------------
-- Slash, help, status
-- ---------------------------------------------------------------------------

function L.StatusText()
    local parts = {}
    for _, r in ipairs(L.ROLES) do parts[#parts + 1] = r.label .. " " .. (L.IsOn(r.key) and "on" or "off") end
    local viewer
    if L.installed then
        viewer = "LFGBrowseFrame found" .. (L.hooked and "" or " (card hook missing)")
    elseif type(_G.LFGBrowseFrame) == "table" then
        viewer = "LFGBrowseFrame found, not hooked yet"
    else
        viewer = "group finder not opened yet (" .. L.BLIZZ_ADDON .. " not loaded)"
    end
    return "LFG role filter: " .. table.concat(parts, ", ") .. " \194\183 viewer: " .. viewer
        .. " \194\183 your listing: " .. (L.HasListing() and "yes" or "no")
        .. " \194\183 filtered: " .. L.hiddenCount .. " players (" .. L.cardsHidden .. " cards hidden now)"
end

function L.Slash(arg)
    local what, onoff = (arg or ""):match("^(%S*)%s*(%S*)")
    what, onoff = (what or ""):lower(), (onoff or ""):lower()
    if what == "all" or what == "reset" then
        L.SetAll(); M.Print("LFG role filter: all roles shown.")
        return
    end
    local key = L.ALIASES[what]
    if not key then
        M.Print(L.StatusText())
        M.Print("/ggf lfg tank | healer | dps [on | off] - show or hide those players under your listing")
        M.Print("/ggf lfg all - show every role again")
        return
    end
    local ok, msg
    if onoff == "on" then ok, msg = L.Set(key, true)
    elseif onoff == "off" then ok, msg = L.Set(key, false)
    else ok, msg = L.Toggle(key) end
    M.Print("LFG role filter: " .. msg .. ".")
end

M.Slash.lfg = function(arg) L.Slash(arg) end
M.HelpParts[#M.HelpParts + 1] = function()
    return { "/ggf lfg tank | healer | dps [on | off] | all - role filter for the players under your group finder listing" }
end
M.StatusParts[#M.StatusParts + 1] = function() return { L.StatusText() } end
