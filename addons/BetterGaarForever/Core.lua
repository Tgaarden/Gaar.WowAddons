--[[
  BetterGaarForever - an optional hub for BetterBagsForever and BetterQuestsForever, for WoW Forever.

  It carries no bag or quest code of its own. Both addons stay fully independent: their logic, their
  settings (BetterBagsForeverDB, BetterQuestsForeverDB) and their slash commands (/bbf, /bqf) stay
  in their own addon, and without this hub they behave exactly as they do on their own. What the
  hub adds is one minimap button whose menu has a "Bags" and a "Quests" submenu, filled by each
  addon through the small API table it exports:

    BetterBagsForeverAPI, BetterQuestsForeverAPI = {
        version,              the addon's version, a string
        StatusLine(),         one short line of state, shown in the tooltip and /bgf status
        MenuEntries(),        the options as plain data, for the menu drawn without MenuUtil
        AddMenuEntries(root), adds the same options to a MenuUtil description
        SetMinimapHidden(b),  hides the addon's own minimap button for this session only
    }

  While the hub is loaded, the addons' own minimap buttons are hidden, so there is one button: the
  TOC lists both as OptionalDeps, so they load first and their API is there at our PLAYER_LOGIN,
  where SetMinimapHidden(true) is called on each. BetterQuestsForever also checks for this addon
  itself before it shows its button, so the order does not matter. Their saved minimap settings
  are never changed.

  Saved variables: BetterGaarForeverDB, bound at ADDON_LOADED (never at file scope), holds only
    minimap = { hide = <bool>, angle = <deg> }
  Anything else (1.0's bags, quests, modules and migrated keys) is dropped on load.

  Taint: the hub creates its own button and menu and calls only the two addons' API; it hooks no
  Blizzard function and touches no Blizzard frame.
]]

local _G = _G
local ADDON_NAME = ... or "BetterGaarForever"

local TITLE = "BetterGaarForever"
local VERSION = "2.0"
local PREFIX = "|cff33ff99BetterGaarForever|r: "
local EN_DASH = "\226\128\147"

-- The addons the hub has a submenu for, in menu order.
local ADDONS = {
    { key = "bags", label = "Bags", name = "BetterBagsForever", api = "BetterBagsForeverAPI", slash = "/bbf" },
    { key = "quests", label = "Quests", name = "BetterQuestsForever", api = "BetterQuestsForeverAPI", slash = "/bqf" },
}

local db          -- BetterGaarForeverDB, bound at ADDON_LOADED (never at file scope)
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

local function IsSecret(v)
    if type(_G.issecretvalue) ~= "function" then return false end
    return _G.issecretvalue(v) and true or false
end

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
    if type(_G.BetterGaarForeverDB) ~= "table" then _G.BetterGaarForeverDB = {} end
    db = _G.BetterGaarForeverDB
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
-- Slash command
-- ---------------------------------------------------------------------------

local function PrintHelp()
    Print("version " .. VERSION .. ": one minimap button for BetterBagsForever and BetterQuestsForever.")
    Print("/bgf status - this version and each addon's state")
    Print("/bgf minimap - show or hide the minimap button; /bgf minimap reset - default place, shown")
    Print("Each addon keeps its own commands: /bbf (BetterBagsForever) and /bqf (BetterQuestsForever).")
end

local function PrintStatus()
    Print("version " .. VERSION)
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
    Print("minimap button: " .. (mm.hide and "hidden (/bgf minimap shows it)" or string.format("shown at %d degrees", mm.angle))
        .. (type(_G.Minimap) ~= "table" and " - no Minimap frame on this client" or "")
        .. "   menu: " .. (type(_G.MenuUtil) == "table" and "MenuUtil" or "own menu (no MenuUtil)"))
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
            -- One of the two loaded after us (LoadAddOn): its button goes too.
            for _, a in ipairs(ADDONS) do
                if arg1 == a.name then HideStandaloneButtons() end
            end
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
