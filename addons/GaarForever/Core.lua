--[[
  GaarForever - the hub of the Gaar...Forever family for WoW Forever (renamed from
  BetterGaarForever in 3.0). Every Gaar...Forever addon lists it under ## Dependencies.

  It carries no bag, quest, map, waypoint, unit-frame or other feature code of its own. The addons
  keep their logic, their settings (GaarBagsForeverDB, GaarQuestsForeverDB, ...) and their slash
  commands (/gbf, /gqf, /gmf, ...). What the hub adds:

    * Lib.lua      the shared library, global GaarForever (see README, "For addon authors")
    * Settings.lua the pages under Esc > Options > AddOns > Gaar Forever, one per addon,
                   generated from each addon's MenuEntries()
    * this file    one minimap button whose menu has a submenu per addon, and /gf

  Each addon fills its submenu and its Options page through the small API table it exports
  (GaarBagsForeverAPI, GaarQuestsForeverAPI, ...):

    version               the addon's version, a string
    StatusLine()          one short line of state, shown in the tooltip and /gf status
    MenuEntries()         the options as plain data, for the menu drawn without MenuUtil and the
                          Options page
    AddMenuEntries(root)  adds the same options to a MenuUtil description
    SetMinimapHidden(b)   hides the addon's own minimap button for this session only
    Intro()               (3.0) a short intro: what it does, key features, nice to know

  While the hub is loaded, the addons' own minimap buttons are hidden, so there is one button: the
  addons load after the hub (they depend on it), so their API is there at our PLAYER_LOGIN, where
  SetMinimapHidden(true) is called on each. An addon loaded later (LoadAddOn) is handled at its
  ADDON_LOADED. Their saved minimap settings are never changed.

  Saved variables: GaarForeverDB, bound at ADDON_LOADED (never at file scope), holds only
    minimap = { hide = <bool>, angle = <deg> }
    news, seen, lastNews, selftest   (3.1, Tools.lua: what's new and the last self-test)
  Until 3.2 the folder (and so the saved variable) was BetterForever: the BetterForever folder is
  now a settings bridge that loads BetterForeverDB, and the first login copies it into
  GaarForeverDB (Lib.Migrate; seen versions are re-keyed to the new folder names).
  Since 3.2.2 the hub's bridge is the one that loads the other way round: it lists GaarForever under
  ## Dependencies (and the hub no longer lists it under ## OptionalDeps), so the hub always loads
  first. An old full BetterXForever addon that is still installed lists ## Dependencies:
  BetterForever, so it now loads after the hub too and finds the BetterForever library alias
  (with the old order it loaded right after the bridge, before the hub, without a library). The
  hub's own copy therefore waits for the bridge: at the bridge's ADDON_LOADED, or at PLAYER_LOGIN
  when the bridge is missing or loaded first (an older bridge without the dependency), before
  anything of the hub's DB is used (minimap place, what's-new versions; MigrateOldHubDB).
  The old BetterGaarForeverDB cannot be read: the client loads saved variables by addon name
  (SavedVariables/BetterGaarForever.lua), so the renamed hub starts with the default button
  position. The addons' own settings live in their own saved variables and are unaffected.

  Taint: the hub creates its own button, menu and Options pages and calls only the addons' API; it
  hooks no Blizzard function.
]]

local _G = _G
local ADDON_NAME = ... or "GaarForever"
local _, ns = ...
local Lib = _G.GaarForever
local Tools = type(ns) == "table" and ns.Tools or nil -- Tools.lua (3.1); nil if it failed to load

local TITLE = "GaarForever"
local VERSION = "3.2.71"
local PREFIX = "|cff33ff99GaarForever|r: "
local EN_DASH = "\226\128\147"

-- The addons the hub has a submenu for, in menu order. name: the folder (and the key everywhere);
-- title: the name users see (Gaar...Forever, set below); oldName: the folder before the rename,
-- now its settings bridge (set below); slash: the command, oldSlash: the one before the Gaar
-- rename, still registered by each addon; db / charDb: its saved variables, account-wide and per
-- character, as in its TOC (db set below; /gf export and /gf import, 3.2.1); keep: keys of them
-- that are local data rather than settings, left out of exports and alone on import.
local ADDONS = {
    { key = "bags", label = "Bags", name = "GaarBagsForever", api = "GaarBagsForeverAPI", slash = "/gbf", oldSlash = "/bbf", charDb = "GaarBagsForeverCharDB", keep = { account = { inventory = true } } },
    { key = "quests", label = "Quests", name = "GaarQuestsForever", api = "GaarQuestsForeverAPI", slash = "/gqf", oldSlash = "/bqf" },
    { key = "maps", label = "Maps", name = "GaarMapsForever", api = "GaarMapsForeverAPI", slash = "/gmf", oldSlash = "/bmf" },
    { key = "castbars", label = "Castbars", name = "GaarCastbarsForever", api = "GaarCastbarsForeverAPI", slash = "/gcf", oldSlash = "/bcf" },
    { key = "plates", label = "Plates", name = "GaarPlatesForever", api = "GaarPlatesForeverAPI", slash = "/gpf", oldSlash = "/bpf" },
    { key = "gps", label = "GPS", name = "GaarGpsForever", api = "GaarGpsForeverAPI", slash = "/ggps", oldSlash = "/bgps" },
    { key = "frames", label = "Frames", name = "GaarFramesForever", api = "GaarFramesForeverAPI", slash = "/gff", oldSlash = "/bff" },
    { key = "windows", label = "Windows", name = "GaarWindowsForever", api = "GaarWindowsForeverAPI", slash = "/gwf", oldSlash = "/bwf" },
    { key = "fishing", label = "Fishing", name = "GaarFishingForever", api = "GaarFishingForeverAPI", slash = "/gfish", oldSlash = "/bfish", charDb = "GaarFishingForeverCharDB",
        keep = { account = { held = true, splashHeld = true }, char = { swap = true, session = true } } },
    { key = "buffs", label = "Buffs", name = "GaarBuffsForever", api = "GaarBuffsForeverAPI", slash = "/gbuff", oldSlash = "/bbuff", charDb = "GaarBuffsForeverCharDB" },
    { key = "merchant", label = "Merchant", name = "GaarMerchantForever", api = "GaarMerchantForeverAPI", slash = "/gmerch", oldSlash = "/bmerch" },
    { key = "tooltips", label = "Tooltips", name = "GaarTooltipsForever", api = "GaarTooltipsForeverAPI", slash = "/gtip", oldSlash = "/btip" },
    { key = "mail", label = "Mail", name = "GaarMailForever", api = "GaarMailForeverAPI", slash = "/gmail", oldSlash = "/bmail" },
    { key = "xp", label = "XP", name = "GaarXPForever", api = "GaarXPForeverAPI", slash = "/gxp", oldSlash = "/bxp" },
    { key = "chat", label = "Chat", name = "GaarChatForever", api = "GaarChatForeverAPI", slash = "/gchat", oldSlash = "/bchat" },
    { key = "bars", label = "Bars", name = "GaarBarsForever", api = "GaarBarsForeverAPI", slash = "/gbars", oldSlash = "/bbars" },
    { key = "loot", label = "Loot", name = "GaarLootForever", api = "GaarLootForeverAPI", slash = "/glf", oldSlash = "/bloot" },
    { key = "group", label = "Group", name = "GaarGroupForever", api = "GaarGroupForeverAPI", slash = "/ggf", charDb = "GaarGroupForeverCharDB", keep = { char = { mode = true } } },
}
for _, a in ipairs(ADDONS) do
    a.title = Lib.DisplayName(a.name)
    a.oldName = Lib.OldName(a.name)
    a.db = a.name .. "DB"
end

local db          -- GaarForeverDB, bound at ADDON_LOADED (never at file scope)
local started     -- PLAYER_LOGIN work done
local hubDBFresh  -- GaarForeverDB was nil or empty when the hub loaded: BetterForeverDB may still be copied in
local migrateOpen = true -- until PLAYER_LOGIN: the window for that copy (nothing has used the DB yet)

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end

local function pcall1(fn, ...) -- first return value of fn, or nil if it errors or is missing
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
end

-- Shared with the whole family (Lib.lua).
local IsSecret = Lib.IsSecret
local AddOnLoaded = Lib.AddOnLoaded

-- The addon's API table, or nil when the addon is not loaded (or too old to have one).
local function API(a)
    local t = _G[a.api]
    if type(t) == "table" then return t end
end

-- Why an addon has no submenu: not loaded at all, or loaded but older than its API.
local function MissingText(a)
    if AddOnLoaded(a.name) then return a.title .. " " .. EN_DASH .. " update it for this menu" end
    return a.title .. " " .. EN_DASH .. " not installed"
end

local function StatusOf(a)
    local api = API(a)
    if not api then return nil end
    local line = pcall1(api.StatusLine)
    return line ~= nil and tostring(line) or "?"
end

-- Each addon's own minimap button is hidden for this session; their saved setting is untouched.
local function HideStandaloneButtons()
    for _, a in ipairs(ADDONS) do
        local api = API(a)
        if api and type(api.SetMinimapHidden) == "function" then pcall(api.SetMinimapHidden, true) end
    end
end

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------

-- GaarOptions sits at 205 degrees and GaarVanguard at 245; 285 keeps clear of both.
local MINIMAP_DEFAULT_ANGLE = 285

local function MinimapDB()
    local m = db.minimap
    if type(m) ~= "table" then
        m = {}
        db.minimap = m
    end
    if type(m.hide) ~= "boolean" then m.hide = false end
    local a = tonumber(m.angle)
    if not a or a ~= a or a == math.huge or a == -math.huge then a = MINIMAP_DEFAULT_ANGLE end
    m.angle = a % 360
    for k in pairs(m) do
        if k ~= "hide" and k ~= "angle" then m[k] = nil end
    end
    return m
end

-- Defaults and clean-up of the bound db; run again after MigrateOldHubDB fills it.
local function PrepareDB()
    -- Only the minimap button and Tools.lua's keys are kept; 1.0's bags, quests, modules and
    -- migrated go.
    local keep = Tools and Tools.DB_KEYS or {}
    for k in pairs(db) do
        if k ~= "minimap" and not keep[k] then db[k] = nil end
    end
    MinimapDB()
    if Tools then
        local ok, err = pcall(Tools.Bind, { db = db, ADDONS = ADDONS, VERSION = VERSION, Print = Print, API = API })
        if not ok then
            Print("the hub's tools could not start: " .. tostring(err))
            Tools = nil
        end
    end
end

local function BindSavedVariables()
    local cur = _G.GaarForeverDB
    hubDBFresh = cur == nil or (type(cur) == "table" and next(cur) == nil)
    -- An older bridge (no ## Dependencies) may have loaded first: its settings are here already.
    if hubDBFresh and Lib.Migrate("GaarForeverDB", "BetterForeverDB", TITLE) then hubDBFresh = false end
    if type(_G.GaarForeverDB) ~= "table" then _G.GaarForeverDB = {} end
    db = _G.GaarForeverDB
    PrepareDB()
end

-- The old folder's settings, once (3.2.2). The bridge (BetterForever) loads after the hub, so
-- BetterForeverDB exists only from its ADDON_LOADED on; called there and at PLAYER_LOGIN (the
-- fallback; a no-op without the bridge). Only while GaarForeverDB still holds nothing but this
-- session's defaults (it was empty when the hub loaded, and it is before login, so nothing was
-- changed or shown yet): those are cleared in place (db stays the same table), the old settings
-- copied in by Lib.Migrate (which marks the old copy __migratedTo) and the defaults applied again,
-- which also re-keys the old what's-new versions (Tools.Bind). Idempotent.
local function MigrateOldHubDB()
    if not (migrateOpen and hubDBFresh and db) then return end
    local old = _G.BetterForeverDB
    if type(old) ~= "table" or old.__migratedTo ~= nil then return end
    hubDBFresh = false
    for k in pairs(db) do db[k] = nil end
    Lib.Migrate("GaarForeverDB", "BetterForeverDB", TITLE)
    PrepareDB() -- the minimap button is placed only at Start, after this
end

-- ---------------------------------------------------------------------------
-- Minimap button
--
-- The placement mirrors GaarQuestsForever's and GaarVanguard's button, copied rather than
-- shared: this addon has no dependencies.
-- ---------------------------------------------------------------------------

local FLAT = "Interface\\Buttons\\WHITE8x8"
-- Built-in icons, best first; the first one the client resolves is used.
local MINIMAP_ICONS = {
    "Interface\\Icons\\INV_Misc_Bag_10",
    "Interface\\Icons\\INV_Misc_Bag_08",
    "Interface\\Icons\\INV_Scroll_03",
    "Interface\\Icons\\INV_Misc_QuestionMark",
}

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function PickMinimapIcon()
    local getID = _G.GetFileIDFromPath
    if type(getID) ~= "function" then return MINIMAP_ICONS[1] end
    for _, path in ipairs(MINIMAP_ICONS) do
        if pcall1(getID, path) then return path end
    end
    return MINIMAP_ICONS[1]
end

local minimapButton, customMenu

local function PlaceMinimapButton()
    local b, mm = minimapButton, _G.Minimap
    if not b or not mm or not db then return end
    local angle = math.rad(MinimapDB().angle)
    local cos, sin = math.cos(angle), math.sin(angle)
    local x, y
    -- GetMinimapShape is the convention minimap-button addons read (GaarMap defines it when it
    -- squares the minimap). On a square minimap the direction is stretched to the edge.
    local shape = pcall1(_G.GetMinimapShape) or "ROUND"
    local mw = type(mm.GetWidth) == "function" and pcall1(mm.GetWidth, mm)
    if IsSecret(mw) or type(mw) ~= "number" or mw <= 0 then mw = 140 end
    if shape == "SQUARE" then
        local half = mw / 2 + 8
        local reach = math.max(math.abs(cos), math.abs(sin))
        if reach < 0.0001 then reach = 1 end
        x, y = half * cos / reach, half * sin / reach
    else
        -- On the rim: half the minimap's width plus 5, the ring LibDBIcon buttons sit on.
        local r = mw / 2 + 5
        x, y = r * cos, r * sin
    end
    b:ClearAllPoints()
    b:SetPoint("CENTER", mm, "CENTER", x, y)
end
-- For an addon that changes the minimap's shape and wants the button re-placed at once.
_G.GaarForever_PlaceMinimapButton = PlaceMinimapButton
_G.BetterForever_PlaceMinimapButton = PlaceMinimapButton -- the name before the folder rename
_G.BetterGaarForever_PlaceMinimapButton = PlaceMinimapButton -- the name before 3.0

-- The cursor's angle around the minimap's centre, in degrees; nil when it cannot be read.
local function CursorAngle()
    local mm = _G.Minimap
    if not mm or type(_G.GetCursorPosition) ~= "function" then return nil end
    local mx, my = mm:GetCenter()
    local scale = mm:GetEffectiveScale()
    if IsSecret(mx) or IsSecret(my) or IsSecret(scale) then return nil end
    local cx, cy = _G.GetCursorPosition()
    if type(mx) ~= "number" or type(my) ~= "number" or type(cx) ~= "number" or type(cy) ~= "number"
        or type(scale) ~= "number" or scale == 0 then
        return nil
    end
    cx, cy = cx / scale, cy / scale
    return math.deg(atan2(cy - my, cx - mx)) % 360
end

local SetMinimapHidden -- defined below; the menu's "Hide" entry calls it

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

-- A MenuUtil entry that cannot be clicked: a button switched off where the client allows that,
-- otherwise a button without a callback.
local function AddDisabled(root, text)
    if type(root.CreateButton) ~= "function" then return end
    local d = root:CreateButton("|cff808080" .. text .. "|r")
    if type(d) == "table" and type(d.SetEnabled) == "function" then pcall(d.SetEnabled, d, false) end
end

-- The addons as the menu lists them: a copy of ADDONS sorted by displayed label, case-insensitive
-- (ADDONS keeps its registration order for everything else).
local function SortedAddons()
    local list = {}
    for i, a in ipairs(ADDONS) do list[i] = a end
    table.sort(list, function(x, y)
        local lx, ly = tostring(x.label):lower(), tostring(y.label):lower()
        if lx ~= ly then return lx < ly end
        return tostring(x.label) < tostring(y.label)
    end)
    return list
end

-- Blizzard's menu: each addon fills its own submenu through its API.
local function BuildMenuUtil(root)
    if type(root.CreateTitle) == "function" then root:CreateTitle(TITLE) end
    for _, a in ipairs(SortedAddons()) do
        local api = API(a)
        if api and type(api.AddMenuEntries) == "function" then
            local sub = root:CreateButton(a.label)
            if type(sub) == "table" then
                local ok, err = pcall(api.AddMenuEntries, sub)
                if not ok then Print(a.title .. "'s menu entries failed: " .. tostring(err)) end
            end
        else
            AddDisabled(root, MissingText(a))
        end
    end
    if type(root.CreateDivider) == "function" then root:CreateDivider() end
    root:CreateButton("Hide minimap button", function() SetMinimapHidden(true) end)
end

-- The same menu as data, for the fallback menu: { text, func }, { text, checkbox|radio, checked,
-- func }, { text, submenu }, { label } (a line that cannot be clicked) and { divider }.
local function MenuEntries()
    local list = {}
    for _, a in ipairs(SortedAddons()) do
        local api = API(a)
        local items = api and pcall1(api.MenuEntries)
        if type(items) == "table" then
            list[#list + 1] = { text = a.label, submenu = items }
        else
            list[#list + 1] = { label = MissingText(a) }
        end
    end
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Hide minimap button", func = function() SetMinimapHidden(true) end }
    return list
end

-- Submenus become indented headings in the fallback menu.
local function FlattenEntries(entries, depth, rows)
    for _, e in ipairs(entries) do
        if type(e) ~= "table" then
            -- skipped
        elseif e.submenu then
            rows[#rows + 1] = { heading = e.text, depth = depth }
            FlattenEntries(e.submenu, depth + 1, rows)
        elseif e.slider then
            -- No slider in this small menu: its value, as a line (the Options page can change it).
            local ok, v = pcall(e.value)
            rows[#rows + 1] = { label = tostring(e.text) .. ": " .. Lib.SliderText(e, ok and v or "?"), depth = depth }
        else
            local row = { depth = depth }
            for k, v in pairs(e) do row[k] = v end
            rows[#rows + 1] = row
        end
    end
    return rows
end

-- A small menu drawn here for clients without MenuUtil (not UIDropDownMenu, whose shared state
-- is prone to taint).
local function ShowCustomMenu(owner, entries)
    local m = customMenu
    if not m then
        m = CreateFrame("Frame", "GaarForeverMinimapMenu", _G.UIParent, "BackdropTemplate")
        m:SetFrameStrata("DIALOG")
        if type(m.SetBackdrop) == "function" then
            m:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 } })
            m:SetBackdropColor(0.07, 0.08, 0.10, 0.97)
            m:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
        end
        m:EnableMouse(true)
        m:SetClampedToScreen(true)
        m.rows = {}
        m:Hide()
        if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "GaarForeverMinimapMenu") end
        -- Close once the mouse has been away from both the menu and the button for a moment.
        m:SetScript("OnUpdate", function(self, elapsed)
            local over = self:IsMouseOver() or (self.owner and self.owner:IsMouseOver())
            if over then
                self.idle = 0
            else
                self.idle = (self.idle or 0) + (elapsed or 0)
                if self.idle > 2 then self:Hide() end
            end
        end)
        customMenu = m
    end
    if m:IsShown() and m.owner == owner then
        m:Hide()
        return m
    end

    local rows = FlattenEntries(entries, 0, { { title = TITLE, depth = 0 } })
    local w, y = 200, -6
    for i, it in ipairs(rows) do
        local r = m.rows[i]
        if not r then
            r = CreateFrame("Button", nil, m)
            r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.text:SetPoint("LEFT", 8, 0)
            r.text:SetJustifyH("LEFT")
            r:SetHighlightTexture(FLAT, "ADD")
            local hl = r:GetHighlightTexture()
            if hl then hl:SetVertexColor(1, 1, 1, 0.10) end
            m.rows[i] = r
        end
        local indent = string.rep("   ", it.depth or 0)
        local h = it.divider and 8 or 18
        r:SetHeight(h)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 4, y)
        r:SetPoint("TOPRIGHT", -4, y)
        if it.title or it.heading or it.label or it.divider then
            local label = it.title and ("|cffffd100" .. it.title .. "|r")
                or it.heading and (indent .. "|cffaaaaaa" .. it.heading .. "|r")
                or it.label and (indent .. "|cff808080" .. it.label .. "|r") or ""
            r.text:SetText(label)
            r:EnableMouse(false)
            r:SetScript("OnClick", nil)
        else
            local label = it.text
            if it.checkbox then
                label = indent .. (it.checked() and "|TInterface\\Buttons\\UI-CheckBox-Check:14:14|t "
                    or "|TInterface\\Buttons\\UI-CheckBox-Up:14:14|t ") .. label
            elseif it.radio then
                label = indent .. (it.checked() and "|cff33ff99(o)|r " or "( ) ") .. label
            else
                label = indent .. label
            end
            r.text:SetText(label)
            r:EnableMouse(true)
            r:SetScript("OnClick", function()
                m:Hide()
                it.func()
            end)
        end
        w = math.max(w, (pcall1(r.text.GetStringWidth, r.text) or 0) + 24)
        r:Show()
        y = y - h
    end
    for i = #rows + 1, #m.rows do m.rows[i]:Hide() end
    m:SetSize(w, -y + 6)
    m:ClearAllPoints()
    m:SetPoint("TOPRIGHT", owner, "BOTTOMLEFT", 0, 0)
    m.owner = owner
    m.idle = 0
    m:Show()
    return m
end

-- Returns which menu was used ("MenuUtil" or "custom").
local function ShowMinimapMenu(owner)
    local MU = _G.MenuUtil
    if type(MU) == "table" and type(MU.CreateContextMenu) == "function" then
        local ok = pcall(MU.CreateContextMenu, owner, function(_, root) BuildMenuUtil(root) end)
        if ok then return "MenuUtil" end
    end
    ShowCustomMenu(owner, MenuEntries())
    return "custom"
end

local function BuildMinimapButton()
    if minimapButton then return minimapButton end
    local mm = _G.Minimap
    if type(mm) ~= "table" then return nil end

    local b = CreateFrame("Button", "GaarForeverMinimapButton", mm)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel((pcall1(mm.GetFrameLevel, mm) or 0) + 8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    -- The standard minimap-button look: dark disc, the icon, the gold tracking ring on top.
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(PickMinimapIcon())
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    b.icon = icon

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)

    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    local tip = _G.GameTooltip
    b:SetScript("OnDragStart", function(self)
        if tip then tip:Hide() end
        self:SetScript("OnUpdate", function()
            local a = CursorAngle()
            if a then
                MinimapDB().angle = a
                PlaceMinimapButton()
            end
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    b:SetScript("OnEnter", function(self)
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_LEFT")
        tip:AddLine(TITLE)
        for _, a in ipairs(ADDONS) do
            local line = StatusOf(a)
            if line then
                tip:AddLine(a.label .. ": " .. line, 1, 1, 1)
            else
                tip:AddLine(a.label .. ": " .. a.title .. " not installed", 0.6, 0.6, 0.6)
            end
        end
        tip:AddLine("Click: options", 1, 1, 1)
        tip:AddLine("Drag: move", 0.6, 0.6, 0.6)
        tip:Show()
    end)
    b:SetScript("OnLeave", function()
        if tip then tip:Hide() end
    end)
    b:SetScript("OnClick", function(self)
        if tip then tip:Hide() end
        ShowMinimapMenu(self)
    end)

    minimapButton = b
    return b
end

local function ApplyMinimap()
    if not db then return end
    if MinimapDB().hide then
        if minimapButton then minimapButton:Hide() end
        if customMenu then customMenu:Hide() end
        return
    end
    if BuildMinimapButton() then
        PlaceMinimapButton()
        minimapButton:Show()
    end
end

SetMinimapHidden = function(hide)
    if not db then return end -- before ADDON_LOADED (another addon calling the API early)
    MinimapDB().hide = hide and true or false
    ApplyMinimap()
    if hide then
        Print("minimap button hidden. Type |cffffd100/gf minimap|r to show it again.")
    else
        Print("minimap button shown.")
    end
end

local function ResetMinimapButton()
    local m = MinimapDB()
    m.angle = MINIMAP_DEFAULT_ANGLE
    m.hide = false
    ApplyMinimap()
    Print("minimap button reset to its default position.")
end


-- ---------------------------------------------------------------------------
-- Options pages (Settings.lua) and the hub's own API
-- ---------------------------------------------------------------------------

local optionsReady
local optionsFailed -- Init failed or errored: not tried again this session (the reason stays in State())

local hub = {
    version = VERSION,
    ADDONS = ADDONS,
    API = API,
    StatusOf = StatusOf,
    MinimapShown = function() return db ~= nil and not MinimapDB().hide end,
    SetMinimapShown = function(shown) SetMinimapHidden(not shown) end,
    NewsShown = function() return db ~= nil and db.news ~= false end,
    SetNewsShown = function(shown) if db then db.news = shown and true or false end end,
    -- 3.2.1: the overview page's export / import buttons.
    ExportAll = function() if Tools and db then Tools.ExportCommand("all") end end,
    Import = function() if Tools and db then Tools.ImportCommand() end end,
}

local function InitOptions()
    if optionsReady or optionsFailed or not Lib.Options then return end
    local ok, done = pcall(Lib.Options.Init, hub)
    optionsReady = ok and done and true or false
    if not optionsReady then optionsFailed = true end
    if not ok then
        Lib.Options.why = Lib.Options.why or tostring(done)
        Print("the Options pages could not be built: " .. tostring(done))
    end
end

local function OpenOptions(key)
    InitOptions()
    local okOpen, opened = false, false
    if Lib.Options then okOpen, opened = pcall(Lib.Options.Open, key) end
    if not (okOpen and opened) then
        Print("no Options page here (" .. (Lib.Options and Lib.Options.State() or "no Settings API") .. ").")
    end
end

-- The hub's API, for other addons. BetterForeverAPI (before the folder rename) and
-- BetterGaarForeverAPI (before 3.0) are the same table, under the old names.
_G.GaarForeverAPI = {
    version = VERSION,
    ADDONS = ADDONS,
    PlaceMinimapButton = PlaceMinimapButton,
    OpenOptions = OpenOptions,
    SetMinimapHidden = function(hide) SetMinimapHidden(hide) end,
}
_G.BetterForeverAPI = _G.GaarForeverAPI
_G.BetterGaarForeverAPI = _G.GaarForeverAPI

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function PrintHelp()
    Print("version " .. VERSION .. ": the hub of the Gaar...Forever family (formerly Better...Forever) - one minimap"
        .. " button, the shared library and the pages under Esc > Options > AddOns > Gaar Forever.")
    Print("/gf status - this version and each addon's state")
    Print("/gf options [name] - open the Options pages (name: bags, quests, maps, ... - one addon's page)")
    Print("/gf minimap - show or hide the minimap button; /gf minimap reset - default place, shown")
    Print("/gf news [on|off] - what changed in the last update (the lines at login: on or off)")
    Print("/gf export all - every installed addon's settings (and the hub's) as one copyable string;"
        .. " /gf export <addon> - one addon's; /gf import - paste one in, check what it holds, apply, reload")
    Print("/gf profile [char|shared] <addon|all> - per-character or shared settings (addons on the library's"
        .. " settings: " .. (Tools and Tools.CoveredText() or "none") .. ")")
    Print("/gf selftest [show] - probe the client APIs the family uses, in and out of combat, as copyable text")
    local cmds = {}
    for _, a in ipairs(ADDONS) do cmds[#cmds + 1] = a.slash .. " (" .. a.title .. ")" end
    Print("Each addon keeps its own commands: " .. table.concat(cmds, ", ") .. ".")
    Print("The commands from before the Gaar rename (/bf, /bbf, /bqf, ...) still work.")
end

local function PrintStatus()
    Print("version " .. VERSION .. ", library " .. tostring(Lib.version))
    for _, a in ipairs(ADDONS) do
        local api = API(a)
        if api then
            Print(a.title .. " " .. tostring(api.version or "?") .. ": " .. (StatusOf(a) or "?")
                .. "   (details: " .. a.slash .. " status)")
        elseif AddOnLoaded(a.name) then
            Print(a.title .. ": loaded, but too old for the hub (no " .. a.api .. ")")
        else
            Print(a.title .. ": not installed")
        end
    end
    local mm = MinimapDB()
    Print("minimap button: " .. (mm.hide and "hidden (/gf minimap shows it)" or string.format("shown at %d degrees", mm.angle))
        .. (type(_G.Minimap) ~= "table" and " - no Minimap frame on this client" or "")
        .. "   menu: " .. (type(_G.MenuUtil) == "table" and "MenuUtil" or "own menu (no MenuUtil)"))
    Print("Options pages: " .. (Lib.Options and Lib.Options.State() or "not loaded"))
end

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    if msg == "status" then
        PrintStatus()
    elseif msg == "minimap" then
        SetMinimapHidden(not MinimapDB().hide)
    elseif msg == "minimap reset" then
        ResetMinimapButton()
    elseif msg == "news" or msg:match("^news ") then
        if not Tools then return Print("the hub's tools are not loaded.") end
        Tools.NewsCommand(msg:match("^news%s*(.-)$"))
    elseif msg == "profile" or msg:match("^profile ") then
        if not Tools then return Print("the hub's tools are not loaded.") end
        Tools.ProfileCommand(msg:match("^profile%s*(.-)$"))
    elseif msg == "export" or msg:match("^export ") then
        if not Tools then return Print("the hub's tools are not loaded.") end
        Tools.ExportCommand(msg:match("^export%s*(.-)$"))
    elseif msg == "import" then
        if not Tools then return Print("the hub's tools are not loaded.") end
        Tools.ImportCommand()
    elseif msg == "selftest" or msg:match("^selftest ") then
        if not Tools then return Print("the hub's tools are not loaded.") end
        Tools.SelfTestCommand(msg:match("^selftest%s*(.-)$"))
    elseif msg == "options" or msg == "config" then
        OpenOptions()
    elseif msg:match("^options ") or msg:match("^config ") then
        local word = msg:match("^%S+ (%S+)")
        local key
        for _, a in ipairs(ADDONS) do
            if a.key == word or a.label:lower() == word or a.name:lower() == word or a.title:lower() == word
                or a.slash == "/" .. word or a.oldSlash == "/" .. word
                or (a.oldName and a.oldName:lower() == word) then key = a.key end
        end
        if not key then
            local names = {}
            for _, a in ipairs(ADDONS) do names[#names + 1] = a.key end
            Print("unknown addon: " .. tostring(word) .. ". One of: " .. table.concat(names, ", ") .. ".")
            return
        end
        OpenOptions(key)
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Start-up
-- ---------------------------------------------------------------------------

-- An old BetterXForever folder that is still the full addon (not yet updated to its settings
-- bridge): it would run beside the new one. The bridges say ## X-Bridge-For in their TOC.
local function WarnOldFolders()
    local meta = Lib.API("C_AddOns", "GetAddOnMetadata") or Lib.API("GetAddOnMetadata")
    if not meta then return end
    local list = { { name = TITLE, oldName = "BetterForever" } }
    for _, a in ipairs(ADDONS) do list[#list + 1] = a end
    local stale = {}
    for _, a in ipairs(list) do
        if a.oldName and AddOnLoaded(a.oldName) and not Lib.Str(Lib.Call(meta, a.oldName, "X-Bridge-For")) then
            stale[#stale + 1] = a.oldName
        end
    end
    if #stale > 0 then
        Print("old folders still hold the full addon: " .. table.concat(stale, ", ") .. ". Update all"
            .. " Gaar...Forever addons (the CurseForge app's Update all): the old folders then become small"
            .. " settings bridges. Or delete those folders; the Gaar...Forever addons replace them.")
    end
end

local function Start()
    if started or not db then return end
    started = true
    HideStandaloneButtons()
    pcall(ApplyMinimap)
    InitOptions()
    if Tools then
        -- A few seconds in, so the lines land after the login spam, not inside it.
        local after = _G.C_Timer and _G.C_Timer.After
        local function News()
            local ok, err = pcall(Tools.LoginNews)
            if not ok then Print("what's new failed: " .. tostring(err)) end
        end
        if type(after) == "function" then after(4, News) else News() end
    end
    if AddOnLoaded("BetterGaarForever") then
        Print("BetterGaarForever is the old folder of this hub: disable it or delete its folder, GaarForever"
            .. " replaces it.")
    end
    WarnOldFolders()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            BindSavedVariables()
            -- Loaded after login (LoadAddOn): no PLAYER_LOGIN is coming, so start now.
            if type(_G.IsLoggedIn) == "function" and _G.IsLoggedIn() then
                MigrateOldHubDB()
                migrateOpen = false
                Start()
            end
        elseif arg1 == "BetterForever" then
            MigrateOldHubDB() -- the bridge, loaded after us (## Dependencies: GaarForever)
        elseif started then
            -- One of them loaded after us (LoadAddOn): its button goes too, and it gets a page.
            for _, a in ipairs(ADDONS) do
                if arg1 == a.name then
                    HideStandaloneButtons()
                    if optionsReady then pcall(Lib.Options.AddAddon, a) end
                end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        MigrateOldHubDB() -- the bridge missing or loaded before us: a no-op, or the copy now
        migrateOpen = false
        Start()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Placed again in case another addon changed the minimap's shape since login.
        if started then pcall(ApplyMinimap) end
    end
end)

SLASH_GAARFOREVER1 = "/gf"
SLASH_GAARFOREVER2 = "/gaarforever"
SLASH_GAARFOREVER3 = "/bf" -- the command before the Gaar rename
SLASH_GAARFOREVER4 = "/betterforever"
SLASH_GAARFOREVER5 = "/bgf" -- the command before 3.0
SlashCmdList.GAARFOREVER = OnSlash
