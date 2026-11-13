--[[
  BetterForever - the hub of the Better...Forever family for WoW Forever (renamed from
  BetterGaarForever in 3.0). Every Better...Forever addon lists it under ## Dependencies.

  It carries no bag, quest, map, waypoint, unit-frame or other feature code of its own. The addons
  keep their logic, their settings (BetterBagsForeverDB, BetterQuestsForeverDB, ...) and their slash
  commands (/bbf, /bqf, /bmf, ...). What the hub adds:

    * Lib.lua      the shared library, global BetterForever (see README, "For addon authors")
    * Settings.lua the pages under Esc > Options > AddOns > Better Forever, one per addon,
                   generated from each addon's MenuEntries()
    * this file    one minimap button whose menu has a submenu per addon, and /bf

  Each addon fills its submenu and its Options page through the small API table it exports
  (BetterBagsForeverAPI, BetterQuestsForeverAPI, ...):

    version               the addon's version, a string
    StatusLine()          one short line of state, shown in the tooltip and /bf status
    MenuEntries()         the options as plain data, for the menu drawn without MenuUtil and the
                          Options page
    AddMenuEntries(root)  adds the same options to a MenuUtil description
    SetMinimapHidden(b)   hides the addon's own minimap button for this session only
    Intro()               (3.0) a short intro: what it does, key features, nice to know

  While the hub is loaded, the addons' own minimap buttons are hidden, so there is one button: the
  addons load after the hub (they depend on it), so their API is there at our PLAYER_LOGIN, where
  SetMinimapHidden(true) is called on each. An addon loaded later (LoadAddOn) is handled at its
  ADDON_LOADED. Their saved minimap settings are never changed.

  Saved variables: BetterForeverDB, bound at ADDON_LOADED (never at file scope), holds only
    minimap = { hide = <bool>, angle = <deg> }
  The old BetterGaarForeverDB cannot be read: the client loads saved variables by addon name
  (SavedVariables/BetterGaarForever.lua), so the renamed hub starts with the default button
  position. The addons' own settings live in their own saved variables and are unaffected.

  Taint: the hub creates its own button, menu and Options pages and calls only the addons' API; it
  hooks no Blizzard function.
]]

local _G = _G
local ADDON_NAME = ... or "BetterForever"
local Lib = _G.BetterForever

local TITLE = "BetterForever"
local VERSION = "3.0.1"
local PREFIX = "|cff33ff99BetterForever|r: "
local EN_DASH = "\226\128\147"

-- The addons the hub has a submenu for, in menu order.
local ADDONS = {
    { key = "bags", label = "Bags", name = "BetterBagsForever", api = "BetterBagsForeverAPI", slash = "/bbf" },
    { key = "quests", label = "Quests", name = "BetterQuestsForever", api = "BetterQuestsForeverAPI", slash = "/bqf" },
    { key = "maps", label = "Maps", name = "BetterMapsForever", api = "BetterMapsForeverAPI", slash = "/bmf" },
    { key = "castbars", label = "Castbars", name = "BetterCastbarsForever", api = "BetterCastbarsForeverAPI", slash = "/bcf" },
    { key = "plates", label = "Plates", name = "BetterPlatesForever", api = "BetterPlatesForeverAPI", slash = "/bpf" },
    { key = "gps", label = "GPS", name = "BetterGpsForever", api = "BetterGpsForeverAPI", slash = "/bgps" },
    { key = "frames", label = "Frames", name = "BetterFramesForever", api = "BetterFramesForeverAPI", slash = "/bff" },
    { key = "windows", label = "Windows", name = "BetterWindowsForever", api = "BetterWindowsForeverAPI", slash = "/bwf" },
    { key = "fishing", label = "Fishing", name = "BetterFishingForever", api = "BetterFishingForeverAPI", slash = "/bfish" },
    { key = "buffs", label = "Buffs", name = "BetterBuffsForever", api = "BetterBuffsForeverAPI", slash = "/bbuff" },
    { key = "merchant", label = "Merchant", name = "BetterMerchantForever", api = "BetterMerchantForeverAPI", slash = "/bmerch" },
    { key = "tooltips", label = "Tooltips", name = "BetterTooltipsForever", api = "BetterTooltipsForeverAPI", slash = "/btip" },
    { key = "mail", label = "Mail", name = "BetterMailForever", api = "BetterMailForeverAPI", slash = "/bmail" },
    { key = "xp", label = "XP", name = "BetterXPForever", api = "BetterXPForeverAPI", slash = "/bxp" },
    { key = "chat", label = "Chat", name = "BetterChatForever", api = "BetterChatForeverAPI", slash = "/bchat" },
    { key = "bars", label = "Bars", name = "BetterBarsForever", api = "BetterBarsForeverAPI", slash = "/bbars" },
}

local db          -- BetterForeverDB, bound at ADDON_LOADED (never at file scope)
local started     -- PLAYER_LOGIN work done

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
    if AddOnLoaded(a.name) then return a.name .. " " .. EN_DASH .. " update it for this menu" end
    return a.name .. " " .. EN_DASH .. " not installed"
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

local function BindSavedVariables()
    if type(_G.BetterForeverDB) ~= "table" then _G.BetterForeverDB = {} end
    db = _G.BetterForeverDB
    -- Only the minimap button is kept; 1.0's bags, quests, modules and migrated go.
    for k in pairs(db) do
        if k ~= "minimap" then db[k] = nil end
    end
    MinimapDB()
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
_G.BetterForever_PlaceMinimapButton = PlaceMinimapButton
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

-- Blizzard's menu: each addon fills its own submenu through its API.
local function BuildMenuUtil(root)
    if type(root.CreateTitle) == "function" then root:CreateTitle(TITLE) end
    for _, a in ipairs(ADDONS) do
        local api = API(a)
        if api and type(api.AddMenuEntries) == "function" then
            local sub = root:CreateButton(a.label)
            if type(sub) == "table" then
                local ok, err = pcall(api.AddMenuEntries, sub)
                if not ok then Print(a.name .. "'s menu entries failed: " .. tostring(err)) end
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
    for _, a in ipairs(ADDONS) do
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
        m = CreateFrame("Frame", "BetterForeverMinimapMenu", _G.UIParent, "BackdropTemplate")
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
        if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "BetterForeverMinimapMenu") end
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

    local b = CreateFrame("Button", "BetterForeverMinimapButton", mm)
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
                tip:AddLine(a.label .. ": " .. a.name .. " not installed", 0.6, 0.6, 0.6)
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
        Print("minimap button hidden. Type |cffffd100/bf minimap|r to show it again.")
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

-- The hub's API, for other addons. BetterGaarForeverAPI is the same table, under the old name.
_G.BetterForeverAPI = {
    version = VERSION,
    ADDONS = ADDONS,
    PlaceMinimapButton = PlaceMinimapButton,
    OpenOptions = OpenOptions,
    SetMinimapHidden = function(hide) SetMinimapHidden(hide) end,
}
_G.BetterGaarForeverAPI = _G.BetterForeverAPI

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function PrintHelp()
    Print("version " .. VERSION .. ": the hub of the Better...Forever family - one minimap button, the shared library"
        .. " and the pages under Esc > Options > AddOns > Better Forever.")
    Print("/bf status - this version and each addon's state")
    Print("/bf options [name] - open the Options pages (name: bags, quests, maps, ... - one addon's page)")
    Print("/bf minimap - show or hide the minimap button; /bf minimap reset - default place, shown")
    local cmds = {}
    for _, a in ipairs(ADDONS) do cmds[#cmds + 1] = a.slash .. " (" .. a.name .. ")" end
    Print("Each addon keeps its own commands: " .. table.concat(cmds, ", ") .. ".")
end

local function PrintStatus()
    Print("version " .. VERSION .. ", library " .. tostring(Lib.version))
    for _, a in ipairs(ADDONS) do
        local api = API(a)
        if api then
            Print(a.name .. " " .. tostring(api.version or "?") .. ": " .. (StatusOf(a) or "?")
                .. "   (details: " .. a.slash .. " status)")
        elseif AddOnLoaded(a.name) then
            Print(a.name .. ": loaded, but too old for the hub (no " .. a.api .. ")")
        else
            Print(a.name .. ": not installed")
        end
    end
    local mm = MinimapDB()
    Print("minimap button: " .. (mm.hide and "hidden (/bf minimap shows it)" or string.format("shown at %d degrees", mm.angle))
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
    elseif msg == "options" or msg == "config" then
        OpenOptions()
    elseif msg:match("^options ") or msg:match("^config ") then
        local word = msg:match("^%S+ (%S+)")
        local key
        for _, a in ipairs(ADDONS) do
            if a.key == word or a.label:lower() == word or a.name:lower() == word or a.slash == "/" .. word then key = a.key end
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

local function Start()
    if started or not db then return end
    started = true
    HideStandaloneButtons()
    pcall(ApplyMinimap)
    InitOptions()
    if AddOnLoaded("BetterGaarForever") then
        Print("BetterGaarForever is the old name of this hub: disable it or delete its folder, BetterForever replaces it.")
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
            -- Loaded after login (LoadAddOn): no PLAYER_LOGIN is coming, so start now.
            if type(_G.IsLoggedIn) == "function" and _G.IsLoggedIn() then Start() end
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
        Start()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Placed again in case another addon changed the minimap's shape since login.
        if started then pcall(ApplyMinimap) end
    end
end)

SLASH_BETTERFOREVER1 = "/bf"
SLASH_BETTERFOREVER2 = "/betterforever"
SLASH_BETTERFOREVER3 = "/bgf" -- the command before 3.0
SlashCmdList.BETTERFOREVER = OnSlash
