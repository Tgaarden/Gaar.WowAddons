--[[
  BetterForever - the family's pages under Esc > Options > AddOns > Better Forever.

  One top category, "Better Forever" (an overview: what the family is, each installed addon's
  state line, the hub's own minimap switch and a pointer to /bf), and one subcategory per
  installed Better...Forever addon. Each subpage is generated from that addon's MenuEntries(),
  the same data the minimap menu draws, so the two can never drift apart:

    checkbox                 -> a checkbox (getter: checked(), setter: func() when it differs)
    radio group (a submenu of radios, or radios in a row) -> a dropdown
    button { text, func }    -> a button row ("Reset" etc.)
    divider                  -> a small gap between groups
    submenu of other entries -> a section header, then its entries
    label (cannot be clicked)-> a grey line of text
    slider                   -> a slider
  At the top of each page: the addon's intro (API Intro() or intro), its command and its state.

  How the pages are built, and why. Every page is a canvas category (RegisterCanvasLayoutCategory
  / RegisterCanvasLayoutSubcategory) that holds its own copy of Blizzard's settings list
  (SettingsListTemplate) filled with Blizzard's own row initializers, so the rows look and work
  like the game's. A canvas rather than a vertical-layout category because the settings search
  walks every vertical-layout category's rows outside securecallfunction: rows an addon made
  there taint the search, and after a search the keybinding rows run tainted. Canvas categories
  are not searched. The proxy settings are not registered either (made from ProxySettingMixin
  where it exists), so the panel's "Defaults" never flips these addons' options.

  The page is rebuilt from MenuEntries() each time it is shown and after a change that alters its
  shape (an entry that appears, disappears or is renamed), so it always shows the live state.

  If any of that is missing on a client, or fails, the page falls back to a plain panel drawn
  here (check buttons, buttons, one line per choice). Without a Settings API at all, the old
  InterfaceOptions_AddCategory is tried; without either, there are no pages and the minimap menu
  and slash commands are unchanged.
]]

local _G = _G
local Lib = _G.BetterForever

local Pages = {}
Lib.Options = Pages

local PAGE_PREFIX = "BetterForever_"

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Checked(e)
    if type(e.checked) ~= "function" then return false end
    local ok, v = pcall(e.checked)
    return ok and v and true or false
end

local function Click(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, err = pcall(fn, ...)
    if not ok then Lib.Report(err) end
end

local function After0(fn)
    local t = _G.C_Timer
    if type(t) == "table" and type(t.After) == "function" then
        t.After(0, fn)
    else
        fn()
    end
end

-- "Warrior: Might" -> "Warrior": a submenu named after its current choice keeps a stable label.
local function ChoiceLabel(text)
    local s = tostring(text or "")
    local before = s:match("^(.*): ")
    if before and before ~= "" then return before end
    return s
end

local function FirstWord(text)
    local plain = tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return plain:match("^(%S+)") or "Run"
end

-- ---------------------------------------------------------------------------
-- MenuEntries -> rows
--
-- A row is { kind = "text" | "header" | "spacer" | "checkbox" | "dropdown" | "slider" | "button" }
-- plus what that kind needs. Both renderers below draw the same rows.
-- ---------------------------------------------------------------------------

local function AllRadios(list)
    local radios, any = {}, false
    for _, e in ipairs(list) do
        if type(e) == "table" then
            if e.radio then
                radios[#radios + 1] = e
                any = true
            elseif not e.divider then
                return nil
            end
        end
    end
    return any and radios or nil
end

-- "Timer: Total", "Timer: Remain" -> "Timer: ", shared by every radio of a run; nil otherwise.
local function SharedPrefix(run)
    local first = tostring(run[1].text or "")
    local prefix = first:match("^(.-: )")
    if not prefix then return nil end
    for _, r in ipairs(run) do
        if tostring(r.text or ""):sub(1, #prefix) ~= prefix then return nil end
    end
    return prefix
end

local function DropdownRow(label, radios, strip)
    local options = {}
    for i, r in ipairs(radios) do
        local t = tostring(r.text or "?")
        if strip and t:sub(1, #strip) == strip then t = t:sub(#strip + 1) end
        options[i] = t
    end
    return { kind = "dropdown", text = label, options = options,
        get = function()
            for i, r in ipairs(radios) do
                if Checked(r) then return i end
            end
            return 0
        end,
        set = function(i)
            local r = radios[tonumber(i) or 0]
            if r and not Checked(r) then Click(r.func) end
        end }
end

local function AddEntries(rows, entries)
    if type(entries) ~= "table" then return end
    local i = 1
    while entries[i] ~= nil do
        local e = entries[i]
        if type(e) == "table" and e.radio then
            local run = {}
            while type(entries[i]) == "table" and entries[i].radio do
                run[#run + 1] = entries[i]
                i = i + 1
            end
            local prefix = SharedPrefix(run)
            local label = prefix and (prefix:gsub(": $", "")) or "Choose"
            rows[#rows + 1] = DropdownRow(label, run, prefix)
        else
            if type(e) ~= "table" then
                -- skipped
            elseif e.divider then
                rows[#rows + 1] = { kind = "spacer" }
            elseif e.label then
                rows[#rows + 1] = { kind = "text", text = tostring(e.label), grey = true }
            elseif e.submenu then
                local radios = AllRadios(e.submenu)
                if radios then
                    rows[#rows + 1] = DropdownRow(ChoiceLabel(e.text), radios)
                else
                    rows[#rows + 1] = { kind = "header", text = tostring(e.text or "") }
                    AddEntries(rows, e.submenu)
                end
            elseif e.slider then
                rows[#rows + 1] = { kind = "slider", text = tostring(e.text or ""),
                    min = Lib.Num(e.min) or 0, max = Lib.Num(e.max) or 1, step = Lib.Num(e.step) or 1,
                    get = function()
                        local ok, v = pcall(e.value)
                        return ok and Lib.Num(v) or (Lib.Num(e.min) or 0)
                    end,
                    set = function(v) Click(e.set, v) end,
                    format = function(v) return Lib.SliderText(e, v) end }
            elseif e.checkbox then
                rows[#rows + 1] = { kind = "checkbox", text = tostring(e.text or ""),
                    get = function() return Checked(e) end,
                    set = function(v)
                        if (v and true or false) ~= Checked(e) then Click(e.func) end
                    end }
            elseif type(e.func) == "function" then
                rows[#rows + 1] = { kind = "button", text = tostring(e.text or ""),
                    buttonText = FirstWord(e.text), func = e.func }
            end
            i = i + 1
        end
    end
end

-- No gap first or last, none twice in a row, none right under a header.
local function Tidy(rows)
    local out = {}
    for _, r in ipairs(rows) do
        local prev = out[#out]
        if r.kind == "spacer" then
            if prev and prev.kind ~= "spacer" and prev.kind ~= "header" then out[#out + 1] = r end
        else
            out[#out + 1] = r
        end
    end
    while out[#out] and out[#out].kind == "spacer" do out[#out] = nil end
    return out
end

-- The rows a list of MenuEntries() becomes (also for debugging: /dump BetterForever.Options.Rows(...)).
function Pages.Rows(entries)
    local rows = {}
    AddEntries(rows, entries)
    return Tidy(rows)
end

local function Signature(rows)
    local parts = {}
    for i, r in ipairs(rows) do
        parts[i] = r.kind .. "=" .. tostring(r.text) .. (r.options and ("[" .. table.concat(r.options, "|") .. "]") or "")
    end
    return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Native renderer: Blizzard's settings list and row initializers inside our canvas
-- ---------------------------------------------------------------------------

local function NativeReady()
    local S = _G.Settings
    return type(S) == "table"
        and type(_G.CreateFromMixins) == "function"
        and type(_G.SettingsListElementInitializer) == "table"
        and type(S.CreateCheckboxInitializer) == "function"
        and type(S.CreateDropdownInitializer) == "function"
        and type(S.CreateControlTextContainer) == "function"
        and type(_G.CreateSettingsButtonInitializer) == "function"
        and type(_G.CreateSettingsListSectionHeaderInitializer) == "function"
        and ((type(_G.ProxySettingMixin) == "table" and type(_G.CreateAndInitFromMixin) == "function")
            or type(S.RegisterProxySetting) == "function")
end

local function VarType(kind)
    local V = _G.Settings and _G.Settings.VarType
    if kind == "boolean" then return type(V) == "table" and V.Boolean or "boolean" end
    return type(V) == "table" and V.Number or "number"
end

-- Text rows measure themselves before their frame exists, with a shown, off-screen font string.
local measure
local function MeasureText(text, width)
    if not measure then
        local f = CreateFrame("Frame", nil, _G.UIParent)
        f:SetSize(1, 1)
        f:SetPoint("TOPRIGHT", _G.UIParent, "BOTTOMLEFT", -200, -200)
        measure = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        measure:SetJustifyH("LEFT")
    end
    measure:SetWidth(width)
    measure:SetText(text or "")
    local h = Lib.Num(measure:GetStringHeight()) or 14
    return math.ceil(h + 12)
end

-- The row template's mixin (BetterForever.xml): wrapped text, white or grey.
_G.BetterForeverSettingsTextRowMixin = {}
local TextRow = _G.BetterForeverSettingsTextRowMixin

function TextRow:Init(initializer)
    local d = type(initializer) == "table" and type(initializer.GetData) == "function" and initializer:GetData() or {}
    local fs = self.Text
    if not fs then return end
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", 37, -6)
    fs:SetPoint("RIGHT", -20, 0)
    fs:SetText(d.text or "")
    if d.grey then fs:SetTextColor(0.62, 0.62, 0.62) else fs:SetTextColor(1, 1, 1) end
end

function TextRow:Release()
    if self.Text then self.Text:SetText("") end
end

local function NoParent() return false end

local function TextInitializer(page, row)
    local init = _G.CreateFromMixins(_G.SettingsListElementInitializer)
    init:Init("BetterForeverSettingsTextRowTemplate", { text = row.text or "", grey = row.grey,
        spacer = row.kind == "spacer" })
    init.GetExtent = function(self)
        local d = self:GetData()
        if d.spacer then return 10 end
        return MeasureText(d.text, page:RowWidth() - 57)
    end
    init.IsParentInitializerInLayout = NoParent
    return init
end

local settingCache = {} -- variable -> setting object, reused across rebuilds
local binding = {}      -- variable -> the row it reads and writes now

local function ProxySetting(page, variable, kind, name, default)
    local s = settingCache[variable]
    if s then return s end
    local function get()
        local r = binding[variable]
        if not r then return default end
        local ok, v = pcall(r.get)
        if not ok then return default end
        if kind == "boolean" then return v and true or false end
        return tonumber(v) or default
    end
    local function set(v)
        local r = binding[variable]
        if not r then return end
        local ok, err = pcall(r.set, v)
        if not ok then Lib.Report(err) end
        page:AfterChange(false)
    end
    local vt = VarType(kind)
    if type(_G.ProxySettingMixin) == "table" and type(_G.CreateAndInitFromMixin) == "function" then
        s = _G.CreateAndInitFromMixin(_G.ProxySettingMixin, name, variable, vt, default, get, set)
    else
        s = _G.Settings.RegisterProxySetting(page.category, variable, vt, name, default, get, set)
    end
    settingCache[variable] = s
    return s
end

local function RenderNative(page, rows)
    local S = _G.Settings
    if not page.list then
        local list = CreateFrame("Frame", nil, page, "SettingsListTemplate")
        list:SetAllPoints(page)
        local header = list.Header
        if header then
            if header.Title then header.Title:SetText(page.title) end
            if header.DefaultsButton then header.DefaultsButton:Hide() end
        end
        page.list = list
    end
    page.list:Show()

    local inits = {}
    for idx, r in ipairs(rows) do
        local init
        -- The label is part of the name: a setting keeps the name it was made with.
        local variable = PAGE_PREFIX .. page.key .. "_" .. r.kind .. "_" .. idx .. "_"
            .. (tostring(r.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("[^%w]", ""))
        if r.kind == "header" then
            init = _G.CreateSettingsListSectionHeaderInitializer(r.text)
        elseif r.kind == "text" or r.kind == "spacer" then
            init = TextInitializer(page, r)
        elseif r.kind == "checkbox" then
            binding[variable] = r
            init = S.CreateCheckboxInitializer(ProxySetting(page, variable, "boolean", r.text, false), nil, r.tooltip)
        elseif r.kind == "dropdown" then
            binding[variable] = r
            local options = r.options
            init = S.CreateDropdownInitializer(ProxySetting(page, variable, "number", r.text, 1), function()
                local c = S.CreateControlTextContainer()
                for i, t in ipairs(options) do c:Add(i, t) end
                return c:GetData()
            end, r.tooltip)
        elseif r.kind == "slider" and type(S.CreateSliderOptions) == "function"
            and type(S.CreateSliderInitializer) == "function" then
            binding[variable] = r
            local o = S.CreateSliderOptions(r.min, r.max, r.step)
            local M = _G.MinimalSliderWithSteppersMixin
            if type(o.SetLabelFormatter) == "function" and type(M) == "table" and type(M.Label) == "table" then
                o:SetLabelFormatter(M.Label.Right, function(v) return r.format(v) end)
            end
            init = S.CreateSliderInitializer(ProxySetting(page, variable, "number", r.text, r.min), o, r.tooltip)
        elseif r.kind == "button" then
            local fn = r.func
            init = _G.CreateSettingsButtonInitializer(r.text, r.buttonText, function()
                Click(fn)
                page:AfterChange(true)
            end, r.tooltip, false)
        end
        if init then
            if type(init) == "table" and init.IsParentInitializerInLayout then init.IsParentInitializerInLayout = NoParent end
            inits[#inits + 1] = init
        end
    end

    local layout = type(_G.CreateVerticalLayout) == "function" and _G.CreateVerticalLayout()
    if layout and type(layout.AddInitializer) == "function" and type(layout.GetInitializers) == "function" then
        for _, init in ipairs(inits) do layout:AddInitializer(init) end
        inits = layout:GetInitializers()
    end
    page.list:Display(inits)
end

-- ---------------------------------------------------------------------------
-- Fallback renderer: a plain panel, drawn here
-- ---------------------------------------------------------------------------

local function TryFrame(kind, parent, template)
    local ok, f = pcall(CreateFrame, kind, nil, parent, template)
    if ok then return f end
end

local function FallbackFrame(page)
    local fb = page.fb
    if fb then return fb end
    fb = { pools = {}, used = {} }
    local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(page.title)
    local scroll = TryFrame("ScrollFrame", page, "ScrollFrameTemplate")
        or TryFrame("ScrollFrame", page, "UIPanelScrollFrameTemplate")
    local content
    if scroll then
        scroll:SetPoint("TOPLEFT", 8, -44)
        scroll:SetPoint("BOTTOMRIGHT", -30, 8)
        content = CreateFrame("Frame", nil, scroll)
        content:SetSize(560, 400)
        scroll:SetScrollChild(content)
    else
        content = CreateFrame("Frame", nil, page)
        content:SetPoint("TOPLEFT", 8, -44)
        content:SetSize(560, 400)
    end
    fb.title, fb.scroll, fb.content = title, scroll, content
    page.fb = fb
    return fb
end

local function Acquire(fb, kind, make)
    local pool = fb.pools[kind]
    if not pool then
        pool = {}
        fb.pools[kind] = pool
    end
    local n = (fb.used[kind] or 0) + 1
    fb.used[kind] = n
    local w = pool[n]
    if not w then
        w = make()
        pool[n] = w
    end
    if w then w:Show() end
    return w
end

local function MakeCheck(parent)
    local cb = TryFrame("CheckButton", parent, "UICheckButtonTemplate")
    if not cb then return nil end
    cb:SetSize(24, 24)
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cb.label:SetJustifyH("LEFT")
    if cb.Text then cb.Text:SetText("") end
    return cb
end

local function RenderFallback(page, rows)
    if page.list then page.list:Hide() end
    local fb = FallbackFrame(page)
    for kind, pool in pairs(fb.pools) do
        for _, w in ipairs(pool) do w:Hide() end
        fb.used[kind] = 0
    end
    local content = fb.content
    local width = page:RowWidth()
    content:SetWidth(width)
    local y = -4
    local function Text(font, text, indent, r, g, b)
        local fs = Acquire(fb, font, function() return content:CreateFontString(nil, "OVERLAY", font) end)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", indent, y)
        fs:SetWidth(width - indent - 16)
        fs:SetJustifyH("LEFT")
        fs:SetText(text or "")
        if r then fs:SetTextColor(r, g, b) end
        local h = Lib.Num(fs:GetStringHeight()) or 14
        y = y - h - 6
        return fs
    end
    local function Check(text, checked, onClick, indent)
        local cb = Acquire(fb, "check", function() return MakeCheck(content) end)
        if not cb then return end
        cb:ClearAllPoints()
        cb:SetPoint("TOPLEFT", indent, y)
        cb.label:SetText(text)
        cb:SetChecked(checked and true or false)
        cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
        y = y - 26
    end
    local function Button(text, onClick, indent)
        local b = Acquire(fb, "button", function() return TryFrame("Button", content, "UIPanelButtonTemplate") end)
        if not b then return end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", indent, y)
        b:SetText(text)
        local fs = b.GetFontString and b:GetFontString()
        local tw = fs and Lib.Num(fs:GetStringWidth()) or 80
        b:SetSize(math.max(60, tw + 24), 22)
        b:SetScript("OnClick", onClick)
        return b
    end
    for _, r in ipairs(rows) do
        if r.kind == "text" then
            Text("GameFontHighlight", r.text, 12, r.grey and 0.62 or 1, r.grey and 0.62 or 1, r.grey and 0.62 or 1)
        elseif r.kind == "header" then
            y = y - 6
            Text("GameFontNormal", r.text, 8)
        elseif r.kind == "spacer" then
            y = y - 8
        elseif r.kind == "checkbox" then
            Check(r.text, r.get(), function(v) Click(r.set, v); page:AfterChange(true) end, 10)
        elseif r.kind == "dropdown" then
            Text("GameFontNormalSmall", r.text, 12)
            local cur = r.get()
            for i, t in ipairs(r.options) do
                Check(t, cur == i, function() Click(r.set, i); page:AfterChange(true) end, 26)
            end
        elseif r.kind == "slider" then
            local v = r.get()
            Text("GameFontHighlight", r.text .. ": " .. tostring(r.format(v)), 12)
            Button("-", function() Click(r.set, math.max(r.min, v - r.step)); page:AfterChange(true) end, 26)
            Button("+", function() Click(r.set, math.min(r.max, v + r.step)); page:AfterChange(true) end, 92)
            y = y - 26
        elseif r.kind == "button" then
            if Button(r.text, function() Click(r.func); page:AfterChange(true) end, 12) then y = y - 28 end
        end
    end
    content:SetHeight(math.max(1, -y + 12))
end

-- ---------------------------------------------------------------------------
-- Pages
-- ---------------------------------------------------------------------------

local PageMixin = {}

function PageMixin:RowWidth()
    local list = self.list
    local w = list and list:IsShown() and list.ScrollBox and Lib.Num(list.ScrollBox:GetWidth())
    if w and w > 100 then return w - 25 end
    w = Lib.Num(self:GetWidth())
    if w and w > 100 then return w - 40 end
    return 600
end

function PageMixin:Refresh(force)
    local ok, rows = pcall(self.Build)
    if not ok then
        Lib.Report(rows)
        rows = {}
    end
    rows = Tidy(rows)
    local sig = Signature(rows)
    if self.native ~= false and NativeReady() then
        if force or sig ~= self.sig then
            local okN, err = pcall(RenderNative, self, rows)
            if okN then
                self.sig = sig
                return
            end
            self.native = false
            self.nativeError = tostring(err)
        else
            return
        end
    else
        self.native = false
    end
    self.sig = sig
    local okF, err = pcall(RenderFallback, self, rows)
    if not okF then Lib.Report(err) end
end

-- After a change: rebuilt on the next frame, once, and only while shown. force: also when the
-- page keeps its shape (a button may have changed every value on it).
function PageMixin:AfterChange(force)
    self.pendingForce = self.pendingForce or force
    if self.pending then return end
    self.pending = true
    After0(function()
        local f = self.pendingForce
        self.pending, self.pendingForce = false, false
        if self:IsShown() then self:Refresh(f or self.native == false) end
    end)
end

-- SettingsPanel calls these on a canvas frame where they exist.
function PageMixin:OnRefresh()
    if self:IsShown() then self:Refresh(true) end
end
function PageMixin:OnCommit() end
function PageMixin:OnDefault() end
function PageMixin:OnCancel() end

local function NewPage(key, title, build)
    local page = CreateFrame("Frame")
    for k, v in pairs(PageMixin) do page[k] = v end
    page:Hide()
    page.key, page.title, page.Build = key, title, build
    page:SetScript("OnShow", function(self) self:Refresh(true) end)
    return page
end

-- ---------------------------------------------------------------------------
-- Overview page (hand-built: it is mostly text)
-- ---------------------------------------------------------------------------

local OVERVIEW_TEXT = "Better Forever is a family of small, independent addons for the WoW Forever client. "
    .. "This hub carries their shared code, one minimap button and these pages. Each installed addon "
    .. "has its own page below this one, built from the same options as the minimap menu, with a short "
    .. "intro at the top. Every addon also keeps its own slash command."

local function BuildOverview(page, hub)
    local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    local intro = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    intro:SetPoint("RIGHT", page, "RIGHT", -24, 0)
    intro:SetJustifyH("LEFT")
    intro:SetText(OVERVIEW_TEXT)
    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hint:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -10)
    hint:SetText("Type |cffffffff/bf|r for the hub's commands, |cffffffff/bf status|r for every addon's version and state.")
    local cb = MakeCheck(page)
    if cb then
        cb:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -4, -10)
        cb.label:SetText("Show the Better Forever minimap button")
        cb:SetScript("OnClick", function(self) Click(hub.SetMinimapShown, self:GetChecked() and true or false) end)
    end
    local head = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -46)
    head:SetText("Addons")
    local list = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -8)
    list:SetPoint("RIGHT", page, "RIGHT", -24, 0)
    list:SetJustifyH("LEFT")
    list:SetSpacing(4)

    page.Refresh = function()
        title:SetText("Better Forever " .. tostring(hub.version))
        if cb then cb:SetChecked(hub.MinimapShown() and true or false) end
        local lines = {}
        for _, a in ipairs(hub.ADDONS) do
            local api = hub.API(a)
            if api then
                lines[#lines + 1] = "|cffffd100" .. a.label .. "|r  " .. a.name .. " " .. tostring(api.version or "?")
                    .. "  |cff9d9d9d" .. a.slash .. "|r  " .. tostring(hub.StatusOf(a) or "?")
            else
                lines[#lines + 1] = "|cff808080" .. a.label .. "  " .. a.name .. " - not installed|r"
            end
        end
        list:SetText(table.concat(lines, "\n"))
    end
    page.OnRefresh = function(self) self.Refresh() end
    page:SetScript("OnShow", function(self) self.Refresh() end)
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

local hubRef
local pagesByKey = {}

local function AddonRows(a)
    local api = hubRef.API(a)
    local rows = {}
    if not api then
        rows[1] = { kind = "text", text = a.name .. " is not loaded.", grey = true }
        return rows
    end
    local intro = Lib.IntroOf(api)
    if intro then rows[#rows + 1] = { kind = "text", text = intro } end
    rows[#rows + 1] = { kind = "text", grey = true,
        text = "Command: " .. a.slash .. " (type it for the full list)   Now: " .. tostring(hubRef.StatusOf(a) or "?") }
    local ok, entries = pcall(api.MenuEntries)
    if ok and type(entries) == "table" then
        rows[#rows + 1] = { kind = "header", text = "Options" }
        AddEntries(rows, entries)
    else
        rows[#rows + 1] = { kind = "text", grey = true, text = "This version of " .. a.name .. " has no options to show here." }
    end
    return rows
end

local function Register(frame, name, parent)
    local S = _G.Settings
    if type(S) == "table" and type(S.RegisterCanvasLayoutCategory) == "function" then
        if parent then
            if type(S.RegisterCanvasLayoutSubcategory) ~= "function" then return nil end
            return S.RegisterCanvasLayoutSubcategory(parent, frame, name)
        end
        return S.RegisterCanvasLayoutCategory(frame, name)
    end
    if type(_G.InterfaceOptions_AddCategory) == "function" then
        frame.name = name
        if parent then frame.parent = parent.name or "Better Forever" end
        _G.InterfaceOptions_AddCategory(frame)
        return frame
    end
    return nil
end

-- One subcategory for an installed addon (called again for one that loads later).
function Pages.AddAddon(a)
    if not Pages.category or pagesByKey[a.key] or not hubRef.API(a) then return end
    local api = hubRef.API(a)
    local page = NewPage(a.key, a.name .. " " .. tostring(api.version or ""), function() return AddonRows(a) end)
    local ok, cat = pcall(Register, page, a.label, Pages.category)
    if ok and cat then
        page.category = cat
        pagesByKey[a.key] = page
    end
end

-- hub: { version, ADDONS, API(a), StatusOf(a), MinimapShown(), SetMinimapShown(b) }
function Pages.Init(hub)
    if Pages.category then return true end
    hubRef = hub
    local overview = CreateFrame("Frame")
    overview:Hide()
    BuildOverview(overview, hub)
    local ok, cat = pcall(Register, overview, "Better Forever")
    if not ok or not cat then
        Pages.why = ok and "this client has no Settings API" or tostring(cat)
        return false
    end
    Pages.category, Pages.overview = cat, overview
    for _, a in ipairs(hub.ADDONS) do Pages.AddAddon(a) end
    local S = _G.Settings
    if type(S) == "table" and type(S.RegisterAddOnCategory) == "function" and cat ~= overview then
        pcall(S.RegisterAddOnCategory, cat)
    end
    return true
end

local function CategoryID(cat)
    if type(cat) == "table" and type(cat.GetID) == "function" then
        local ok, id = pcall(cat.GetID, cat)
        if ok then return id end
    end
    return cat and cat.ID
end

-- Opens the overview, or one addon's page by hub key ("bags", "quests", ...).
function Pages.Open(key)
    local cat = Pages.category
    if key and pagesByKey[key] then cat = pagesByKey[key].category end
    if not cat then return false end
    local S = _G.Settings
    if type(S) == "table" and type(S.OpenToCategory) == "function" then
        return (pcall(S.OpenToCategory, CategoryID(cat)))
    end
    if type(_G.InterfaceOptionsFrame_OpenToCategory) == "function" then
        return (pcall(_G.InterfaceOptionsFrame_OpenToCategory, cat))
    end
    return false
end

function Pages.State()
    if not Pages.category then return "not registered" .. (Pages.why and (" (" .. Pages.why .. ")") or "") end
    local n, fallback = 0, 0
    for _, p in pairs(pagesByKey) do
        n = n + 1
        if p.native == false then fallback = fallback + 1 end
    end
    return string.format("%d addon page%s%s", n, n == 1 and "" or "s",
        fallback > 0 and string.format(" (%d drawn by hand)", fallback) or "")
end
