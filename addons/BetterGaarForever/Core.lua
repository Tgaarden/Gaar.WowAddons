--[[
  BetterGaarForever - BetterBagsForever and BetterQuestsForever in one addon, for WoW Forever.

  This file is the shell the two modules plug into. It owns:

    * the saved variables (BetterGaarForeverDB), bound at ADDON_LOADED, never at file scope:
        modules  = { bags = <bool>, quests = <bool> }    per-module on/off, default on
        migrated = { bags = true, quests = true }        settings imported from the standalone addon
        minimap  = { hide = <bool>, angle = <deg> }      the one minimap button
        bags     = { ... }                               the Bags module's settings
        quests   = { ... }                               the Quests module's settings
    * the module registry: Modules/Bags.lua and Modules/Quests.lua register themselves through
      the addon's private namespace (the second value of ...), so no global is shared;
    * conflict handling: a module whose standalone addon is also loaded never starts, so the two
      never run side by side;
    * a one-time import of the standalone addon's settings;
    * /bgf, the /bbf and /bqf aliases, and one minimap button with one menu.

  Modules are started at PLAYER_LOGIN rather than ADDON_LOADED. The client loads addons in
  folder order, so at our own ADDON_LOADED BetterQuestsForever (which sorts after us) has not
  loaded yet; by PLAYER_LOGIN every addon that is going to load at startup has, together with
  its saved variables.

  Each module has the same shape: key, title, standalone (the addon it replaces), standaloneDB
  (that addon's SavedVariables global), standaloneSlash (its SlashCmdList key), alias (its slash
  command), importKeys, Bind(settings), Sanitise(settings), Enable(), Disable(), IsActive(),
  StateLine(), Slash(msg) and MenuEntries(). Enable(true) means "switched on by the player", so
  the module applies itself at once instead of waiting for its next event.
]]

local _G = _G
local ADDON_NAME, ns = ...
ADDON_NAME = ADDON_NAME or "BetterGaarForever"
if type(ns) ~= "table" then ns = {} end

local TITLE = "BetterGaarForever"
local VERSION = "1.0"
local PREFIX = "|cff33ff99BetterGaarForever|r: "
local EM_DASH = "\226\128\148"
local DOT = " \194\183 "

ns.TITLE = TITLE
ns.modules = ns.modules or {}

local db          -- BetterGaarForeverDB, bound at ADDON_LOADED (never at file scope)
local started     -- PLAYER_LOGIN work done: imports, conflict checks, modules started

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end
ns.Print = Print

local function pcall1(fn, ...) -- first return value of fn, or nil if it errors or is missing
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
end

local function IsSecret(v)
    if type(_G.issecretvalue) ~= "function" then return false end
    return _G.issecretvalue(v) and true or false
end

local function DeepCopy(v, depth)
    if type(v) ~= "table" then return v end
    depth = depth or 0
    if depth > 10 then return nil end
    local out = {}
    for k, x in pairs(v) do out[k] = DeepCopy(x, depth + 1) end
    return out
end

-- Called by each module file when it loads.
function ns.RegisterModule(m)
    if type(m) ~= "table" or type(m.key) ~= "string" then return end
    for _, other in ipairs(ns.modules) do
        if other.key == m.key then return end
    end
    ns.modules[#ns.modules + 1] = m
end

-- ---------------------------------------------------------------------------
-- Conflict detection
-- ---------------------------------------------------------------------------

-- Whether an addon is loaded: C_AddOns on newer clients, the old global otherwise.
local function AddOnLoaded(name)
    local c = _G.C_AddOns
    if type(c) == "table" and type(c.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(c.IsAddOnLoaded, name)
        if ok and loaded then return true end
    end
    if type(_G.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(_G.IsAddOnLoaded, name)
        if ok and loaded then return true end
    end
    return false
end

-- The standalone addon is running: the client says so, or its slash command is registered.
local function StandaloneLoaded(m)
    if AddOnLoaded(m.standalone) then return true end
    local list = _G.SlashCmdList
    return type(list) == "table" and m.standaloneSlash ~= nil and list[m.standaloneSlash] ~= nil
end

local function PausedLine(m)
    return m.standalone .. " is also enabled " .. EM_DASH .. " the " .. m.title .. " module is paused. Disable "
        .. m.standalone .. " and /reload to use the module."
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

local function BindSavedVariables()
    if type(_G.BetterGaarForeverDB) ~= "table" then _G.BetterGaarForeverDB = {} end
    db = _G.BetterGaarForeverDB
    local keep = { modules = true, migrated = true, minimap = true }
    for _, m in ipairs(ns.modules) do keep[m.key] = true end
    for k in pairs(db) do
        if not keep[k] then db[k] = nil end
    end
    if type(db.modules) ~= "table" then db.modules = {} end
    if type(db.migrated) ~= "table" then db.migrated = {} end
    local known = {}
    for _, m in ipairs(ns.modules) do
        known[m.key] = true
        if type(db.modules[m.key]) ~= "boolean" then db.modules[m.key] = true end
        if db.migrated[m.key] ~= true then db.migrated[m.key] = nil end
        if type(db[m.key]) ~= "table" then db[m.key] = {} end
        m.Bind(db[m.key])
    end
    for k in pairs(db.modules) do
        if not known[k] then db.modules[k] = nil end
    end
    for k in pairs(db.migrated) do
        if not known[k] then db.migrated[k] = nil end
    end
    MinimapDB()
end

-- First run next to the standalone addon: its settings are copied once, sanitised with the
-- module's own rules, and the flag is set so a later run never overwrites what was set here.
-- The standalone's SavedVariables global only exists while that addon is loaded.
local function Import(m)
    if db.migrated[m.key] then return end
    local src = _G[m.standaloneDB]
    if type(src) ~= "table" then return end
    local dst = db[m.key]
    for _, k in ipairs(m.importKeys or {}) do
        if src[k] ~= nil then dst[k] = DeepCopy(src[k]) end
    end
    m.Sanitise(dst)
    -- The standalone's minimap button position carries over to the combined button.
    if m.importMinimap and type(src.minimap) == "table" then
        local a = tonumber(src.minimap.angle)
        if a and a == a and a ~= math.huge and a ~= -math.huge then MinimapDB().angle = a % 360 end
    end
    db.migrated[m.key] = true
    Print("Imported your " .. m.standalone .. " settings.")
end

-- ---------------------------------------------------------------------------
-- Modules on and off
-- ---------------------------------------------------------------------------

local function StartModule(m, atOnce)
    local ok, err = pcall(m.Enable, atOnce)
    if not ok then Print(m.title .. " module could not start: " .. tostring(err)) end
end

local function StopModule(m)
    local ok, err = pcall(m.Disable)
    if not ok then Print(m.title .. " module could not stop cleanly: " .. tostring(err)) end
end

local function ModuleState(m)
    if m.paused then return "paused (" .. m.standalone .. " is enabled)" end
    if not (db and db.modules[m.key]) then return "Off" end
    local ok, line = pcall(m.StateLine)
    return ok and tostring(line) or "On"
end

local function SetModuleEnabled(m, on)
    if not db then return end
    db.modules[m.key] = on and true or false
    if m.paused then
        Print(PausedLine(m))
        return
    end
    if not started then return end
    if on then
        StartModule(m, true)
        Print(m.title .. " module on.")
    else
        StopModule(m)
        Print(m.title .. " module off " .. EM_DASH .. " Blizzard's own " .. (m.blizzardName or m.title:lower()) .. ".")
    end
end

-- ---------------------------------------------------------------------------
-- Minimap button
--
-- The placement mirrors BetterQuestsForever's and GaarVanguard's button, copied rather than
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
_G.BetterGaarForever_PlaceMinimapButton = PlaceMinimapButton

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

-- The options as data, shared by Blizzard's menu and the fallback menu. Entries are
-- { text, func } buttons, { text, checkbox|radio, checked, func }, { text, submenu },
-- { label } (a title line) and { divider }.
local function MenuEntries()
    local list = {}
    for _, m in ipairs(ns.modules) do
        local items = {}
        if m.paused then items[#items + 1] = { label = "Paused: " .. m.standalone .. " is enabled" } end
        items[#items + 1] = { text = "Enabled", checkbox = true, checked = function() return db.modules[m.key] end,
            func = function() SetModuleEnabled(m, not db.modules[m.key]) end }
        local ok, extra = pcall(m.MenuEntries)
        if ok and type(extra) == "table" then
            for _, e in ipairs(extra) do items[#items + 1] = e end
        end
        list[#list + 1] = { text = m.title, submenu = items }
    end
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Hide minimap button", func = function() SetMinimapHidden(true) end }
    return list
end

local function AddMenuEntries(root, entries)
    for _, e in ipairs(entries) do
        if e.divider then
            if type(root.CreateDivider) == "function" then root:CreateDivider() end
        elseif e.label then
            if type(root.CreateTitle) == "function" then root:CreateTitle(e.label) end
        elseif e.submenu then
            local sub = root:CreateButton(e.text)
            if type(sub) == "table" then AddMenuEntries(sub, e.submenu) end
        elseif e.checkbox and type(root.CreateCheckbox) == "function" then
            root:CreateCheckbox(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.radio and type(root.CreateRadio) == "function" then
            root:CreateRadio(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox or e.radio then
            -- A menu without checkboxes or radios: show the state in the label instead.
            root:CreateButton((e.checked() and "[x] " or "[ ] ") .. e.text, function() e.func() end)
        else
            root:CreateButton(e.text, function() e.func() end)
        end
    end
end

-- Submenus become indented headings in the fallback menu.
local function FlattenEntries(entries, depth, rows)
    for _, e in ipairs(entries) do
        if e.submenu then
            rows[#rows + 1] = { heading = e.text, depth = depth }
            FlattenEntries(e.submenu, depth + 1, rows)
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
        m = CreateFrame("Frame", "BetterGaarForeverMinimapMenu", _G.UIParent, "BackdropTemplate")
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
        if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "BetterGaarForeverMinimapMenu") end
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
                or it.label and (indent .. "|cffff8040" .. it.label .. "|r") or ""
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
    local entries = MenuEntries()
    local MU = _G.MenuUtil
    if type(MU) == "table" and type(MU.CreateContextMenu) == "function" then
        local ok = pcall(MU.CreateContextMenu, owner, function(_, root)
            if type(root.CreateTitle) == "function" then root:CreateTitle(TITLE) end
            AddMenuEntries(root, entries)
        end)
        if ok then return "MenuUtil" end
    end
    ShowCustomMenu(owner, entries)
    return "custom"
end

local function BuildMinimapButton()
    if minimapButton then return minimapButton end
    local mm = _G.Minimap
    if type(mm) ~= "table" then return nil end

    local b = CreateFrame("Button", "BetterGaarForeverMinimapButton", mm)
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
        for _, m in ipairs(ns.modules) do tip:AddLine(m.title .. ": " .. ModuleState(m), 1, 1, 1) end
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
    MinimapDB().hide = hide and true or false
    ApplyMinimap()
    if hide then
        Print("minimap button hidden. Type |cffffd100/bgf minimap|r to show it again.")
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
-- Slash commands
-- ---------------------------------------------------------------------------

local function Normalise(msg)
    return (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
end

local function MinimapSlash(rest)
    if rest == "reset" then
        ResetMinimapButton()
    else
        SetMinimapHidden(not MinimapDB().hide)
    end
end

local function FindModule(key)
    for _, m in ipairs(ns.modules) do
        if m.key == key then return m end
    end
end

-- One module's commands: enable/disable here, minimap for the shell, the rest to the module.
local function ModuleSlash(m, msg, command)
    msg = Normalise(msg)
    if not db then
        Print("not loaded yet.")
        return
    end
    if msg == "enable" or msg == "disable" then
        SetModuleEnabled(m, msg == "enable")
        return
    end
    local mini = msg:match("^minimap ?(.*)$")
    if mini then
        MinimapSlash(mini)
        return
    end
    if m.paused then
        Print(PausedLine(m))
        return
    end
    m.Slash(msg)
    if msg == "" or msg == "help" then
        Print(command .. " enable | disable - switch the whole " .. m.title .. " module on or off (now: "
            .. (db.modules[m.key] and "on" or "off") .. ")")
    end
end

local function PrintHelp()
    Print("version " .. VERSION .. ": the Bags and Quests modules for Forever's own bags and quest tracker.")
    Print("/bgf status - both modules and the minimap button")
    Print("/bgf bags <command> - the Bags module; /bgf bags on its own lists its commands")
    Print("/bgf quests <command> - the Quests module; /bgf quests on its own lists its commands")
    Print("/bgf bags enable | disable, /bgf quests enable | disable - switch a whole module on or off")
    Print("/bgf minimap - show or hide the minimap button; /bgf minimap reset - default place, shown")
    local aliases = {}
    for _, m in ipairs(ns.modules) do
        if m.aliasRegistered then aliases[#aliases + 1] = m.alias .. " = /bgf " .. m.key end
    end
    if #aliases > 0 then Print("shortcuts: " .. table.concat(aliases, ", ")) end
end

local function PrintStatus()
    Print("version " .. VERSION)
    for _, m in ipairs(ns.modules) do
        local state
        if m.paused then
            state = "paused " .. EM_DASH .. " " .. m.standalone .. " is enabled"
        elseif not db.modules[m.key] then
            state = "off " .. EM_DASH .. " Blizzard's own"
        else
            state = (m.IsActive() and "on" or "starting") .. DOT .. ModuleState(m)
        end
        Print(m.title .. ": " .. state .. "   (details: /bgf " .. m.key .. " status)")
    end
    local mm = MinimapDB()
    Print("minimap button: " .. (mm.hide and "hidden (/bgf minimap shows it)" or string.format("shown at %d degrees", mm.angle))
        .. (type(_G.Minimap) ~= "table" and " - no Minimap frame on this client" or "")
        .. "   menu: " .. (type(_G.MenuUtil) == "table" and "MenuUtil" or "own menu (no MenuUtil)"))
end

local function OnSlash(msg)
    msg = Normalise(msg)
    if not db then
        Print("not loaded yet.")
        return
    end
    local word, rest = msg:match("^(%S+) ?(.*)$")
    local m = word and FindModule(word)
    if m then
        ModuleSlash(m, rest, "/bgf " .. m.key)
    elseif word == "minimap" then
        MinimapSlash(rest)
    elseif msg == "status" then
        PrintStatus()
    else
        PrintHelp()
    end
end

-- /bbf and /bqf, only when the standalone addon that owns them is not loaded.
local function RegisterAlias(m)
    if not m.alias or type(_G.SlashCmdList) ~= "table" then return end
    local key = "BETTERGAARFOREVER_" .. m.key:upper()
    _G["SLASH_" .. key .. "1"] = m.alias
    _G.SlashCmdList[key] = function(msg) ModuleSlash(m, msg, m.alias) end
    m.aliasRegistered = true
end

-- ---------------------------------------------------------------------------
-- Start-up
-- ---------------------------------------------------------------------------

local function Start()
    if started or not db then return end
    started = true
    for _, m in ipairs(ns.modules) do
        local ok, err = pcall(Import, m)
        if not ok then Print("could not import the " .. m.standalone .. " settings: " .. tostring(err)) end
        if StandaloneLoaded(m) then
            m.paused = true
            Print(PausedLine(m))
        else
            RegisterAlias(m)
            if db.modules[m.key] then StartModule(m) end
        end
    end
    pcall(ApplyMinimap)
end

-- A standalone addon loading after the modules started: its module steps aside.
local function OnLateAddOn(name)
    for _, m in ipairs(ns.modules) do
        if name == m.standalone and not m.paused then
            m.paused = true
            if m.IsActive() then StopModule(m) end
            Print(PausedLine(m))
        end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            BindSavedVariables()
            -- Loaded after login (LoadAddOn): nothing else is coming, so start now.
            if type(_G.IsLoggedIn) == "function" and _G.IsLoggedIn() then Start() end
        elseif started then
            OnLateAddOn(arg1)
        end
    elseif event == "PLAYER_LOGIN" then
        Start()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Placed again in case another addon changed the minimap's shape since login.
        if started then pcall(ApplyMinimap) end
    end
end)

SLASH_BETTERGAARFOREVER1 = "/bgf"
SLASH_BETTERGAARFOREVER2 = "/bettergaarforever"
SlashCmdList.BETTERGAARFOREVER = OnSlash
