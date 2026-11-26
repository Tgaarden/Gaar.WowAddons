--[[
  GaarBarsForever - FlyoutEditor.lua: the flyout editor (Flyouts v2), a Gaar window of our own.

  Opened with /gbars flyouts, or the small button right of the "Missing from bars" tab in the
  spellbook (BookTab.lua). The look follows the family's windows (GaarForever's text window and
  minimap menu): a flat dark backdrop with a 1 px grey border, GameFontNormal title, Blizzard's
  close / panel button templates on frames of our own, Escape closes it (UISpecialFrames).

    * Left: the flyouts (icon + name), New and Delete. Delete asks first, then deletes the flyout
      and its macro.
    * Right, for the selected flyout:
        - Name: an edit box (Enter or leaving it renames the flyout and its macro).
        - Icon: a button that opens the icon picker, and "Use entry 1's icon".
        - Bar placement: a big drag handle with the flyout's icon; dragging (or clicking) it puts
          the flyout's macro on the cursor (PickupMacro), to drop on any bar button. "On N
          buttons" says how many bar slots hold it now.
        - Entries: icon, name and rank, with up / down / remove (X). A drop zone below adds what
          the cursor holds (a spell, an item or a macro), like the "+" on the bars.
    * Every change goes through Flyouts.lua (NS.Flyouts) and is out of combat only. In combat the
      window says it is locked and every edit control is disabled; it catches up when the fight
      ends. Changes made elsewhere (the "+", right-click or drag out of an open flyout) show here
      at once (Flyouts.lua calls B.FlyoutEditorRefresh after every rebuild).

  The icon picker is our own: a scrollable grid of the client's macro icons (GetLooseMacroIcons,
  GetLooseMacroItemIcons, GetMacroIcons, GetMacroItemIcons into tables of ours). Blizzard's
  IconSelectorPopupFrameTemplate exists on this client but keeps its icon list in shared state of
  IconDataProvider.lua that the macro and gear-set windows read too; filling it from addon code
  could taint them, so it is not used. The icons are numbers (file ids) without names, so there
  is no search box.

  Nothing of Blizzard's is changed: no hooks, no attributes, no Blizzard frame touched. The window
  holds no secure frames, so it may show and hide in combat.
]]

local _G = _G
local _, NS = ...
if type(NS) ~= "table" or type(NS.Bars) ~= "table" then return end

local B = NS.Bars
local ED = {}   -- public: Open, Close, Toggle, Refresh
local U = {}    -- builders and helpers
NS.FlyoutEditor = ED

local K = {
    W = 620, H = 520, LIST_W = 190, ROW = 24, LIST_ROWS = 15, ENTRY_ROW = 24, MAX_ENTRIES = 12,
    FLAT = "Interface\\Buttons\\WHITE8x8", QMARK = 134400,
    ICON_COLS = 8, ICON_ROWS = 7, ICON_SIZE = 32, ICON_GAP = 4,
    GREY = { 0.6, 0.6, 0.6 },
}

local S = {
    frame = nil, sel = nil, listOffset = 0, rows = {}, entryRows = {},
    picker = nil, icons = nil, iconOffset = 0, err = nil,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function U.FL() return NS.Flyouts end

function U.Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        S.err = where .. ": " .. tostring(err)
        if type(B.Fail) == "function" then B.Fail("flyout editor " .. where, err) end
    end
    return ok
end

function U.InCombat() return type(B.InCombat) == "function" and B.InCombat() or false end

function U.TryFrame(kind, name, parent, template)
    local ok, f = pcall(_G.CreateFrame, kind, name, parent, template)
    if ok and f then return f end
    ok, f = pcall(_G.CreateFrame, kind, name, parent)
    if ok then return f end
end

function U.Backdrop(f, r, g, b, a)
    if type(f.SetBackdrop) ~= "function" then return end
    f:SetBackdrop({ bgFile = K.FLAT, edgeFile = K.FLAT, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    f:SetBackdropColor(r or 0.07, g or 0.08, b or 0.10, a or 0.97)
    f:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
end

function U.Text(parent, font, justify)
    local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    t:SetJustifyH(justify or "LEFT")
    return t
end

function U.PanelButton(parent, text, w, h, onClick)
    local b = U.TryFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    b:SetScript("OnClick", function(self) U.Safe("click", onClick, self) end)
    return b
end

-- A small texture button (up / down / remove).
function U.IconButton(parent, tex, size, tip, onClick)
    local b = U.TryFrame("Button", nil, parent)
    b:SetSize(size, size)
    b:SetNormalTexture(tex)
    b:SetPushedTexture(tex)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnClick", function(self) U.Safe("click", onClick, self) end)
    b:SetScript("OnEnter", function(self)
        local tt = _G.GameTooltip
        if not tt then return end
        tt:SetOwner(self, "ANCHOR_RIGHT")
        tt:SetText(tip, 1, 1, 1)
        tt:Show()
    end)
    b:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    return b
end

function U.SetEnabled(w, on)
    if not w then return end
    if type(w.SetEnabled) == "function" then pcall(w.SetEnabled, w, on and true or false) end
    w:SetAlpha(on and 1 or 0.35)
end

function U.Selected()
    local FL = U.FL()
    return FL and S.sel and FL.Get(S.sel) or nil
end

function U.CanEdit()
    local FL = U.FL()
    return FL ~= nil and FL.CanEdit() and not U.InCombat()
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

function U.BuildListRow(f, i)
    local r = U.TryFrame("Button", nil, f.list)
    r:SetHeight(K.ROW)
    r:SetPoint("TOPLEFT", f.list, "TOPLEFT", 4, -4 - (i - 1) * K.ROW)
    r:SetPoint("RIGHT", f.list, "RIGHT", -4, 0)
    r:RegisterForClicks("LeftButtonUp")
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints(r)
    r.sel:SetColorTexture(0.25, 0.45, 0.75, 0.35)
    r.sel:Hide()
    r:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(K.ROW - 4, K.ROW - 4)
    r.icon:SetPoint("LEFT", 2, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.name = U.Text(r, "GameFontHighlight")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetPoint("RIGHT", r, "RIGHT", -2, 0)
    r.name:SetWordWrap(false)
    r:SetScript("OnClick", function(self)
        if self.id then
            S.sel = self.id
            if S.picker then S.picker:Hide() end
            ED.Refresh()
        end
    end)
    S.rows[i] = r
    return r
end

function U.BuildEntryRow(f, i)
    local r = U.TryFrame("Frame", nil, f.right)
    r:SetHeight(K.ENTRY_ROW)
    r:SetPoint("TOPLEFT", f.entriesTop, "BOTTOMLEFT", 0, -4 - (i - 1) * K.ENTRY_ROW)
    r:SetPoint("RIGHT", f.right, "RIGHT", -8, 0)
    r:EnableMouse(true)
    r.num = U.Text(r, "GameFontDisableSmall", "RIGHT")
    r.num:SetWidth(16)
    r.num:SetPoint("LEFT", 0, 0)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(K.ENTRY_ROW - 4, K.ENTRY_ROW - 4)
    r.icon:SetPoint("LEFT", r.num, "RIGHT", 4, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.remove = U.IconButton(r, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", 18, "Remove", function()
        local FL = U.FL()
        if FL and S.sel and r.index then FL.RemoveAt(S.sel, r.index) end
    end)
    r.remove:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    r.down = U.IconButton(r, "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up", 22, "Move down", function()
        local FL = U.FL()
        if FL and S.sel and r.index then FL.Move(S.sel, r.index, 1) end
    end)
    r.down:SetPoint("RIGHT", r.remove, "LEFT", -4, 0)
    r.up = U.IconButton(r, "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up", 22, "Move up", function()
        local FL = U.FL()
        if FL and S.sel and r.index then FL.Move(S.sel, r.index, -1) end
    end)
    r.up:SetPoint("RIGHT", r.down, "LEFT", -2, 0)
    r.rank = U.Text(r, "GameFontDisableSmall", "RIGHT")
    r.rank:SetPoint("RIGHT", r.up, "LEFT", -8, 0)
    r.rank:SetWidth(60)
    r.name = U.Text(r, "GameFontHighlight")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetPoint("RIGHT", r.rank, "LEFT", -4, 0)
    r.name:SetWordWrap(false)
    r:SetScript("OnEnter", function(self)
        local FL = U.FL()
        if FL and self.entry then FL.EntryTooltip(self, self.entry) end
    end)
    r:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    S.entryRows[i] = r
    return r
end

function U.ApplyName(box)
    local FL = U.FL()
    local f = U.Selected()
    if not (FL and f) then return end
    local text = box:GetText()
    if type(text) == "string" and text ~= f.name and U.CanEdit() then FL.Rename(f.id, text) end
    box:SetText(U.Selected() and U.Selected().name or "")
end

function U.BuildConfirm(f)
    local c = U.TryFrame("Frame", nil, f, "BackdropTemplate")
    c:SetSize(340, 110)
    c:SetPoint("CENTER", f, "CENTER", 0, 20)
    c:SetFrameLevel(f:GetFrameLevel() + 30)
    c:EnableMouse(true)
    U.Backdrop(c, 0.10, 0.11, 0.14, 1)
    c.text = U.Text(c, "GameFontHighlight", "CENTER")
    c.text:SetPoint("TOPLEFT", 14, -14)
    c.text:SetPoint("TOPRIGHT", -14, -14)
    c.yes = U.PanelButton(c, "Delete", 100, 22, function()
        local FL = U.FL()
        local id = c.id
        c:Hide()
        if FL and id and FL.Delete(id) then
            if S.sel == id then S.sel = nil end
            ED.Refresh()
        end
    end)
    c.yes:SetPoint("BOTTOMRIGHT", c, "BOTTOM", -6, 12)
    c.no = U.PanelButton(c, "Cancel", 100, 22, function() c:Hide() end)
    c.no:SetPoint("BOTTOMLEFT", c, "BOTTOM", 6, 12)
    c:Hide()
    f.confirm = c
end

function U.Build()
    if S.frame then return S.frame end
    local f = U.TryFrame("Frame", "GaarBarsForeverFlyoutEditor", _G.UIParent, "BackdropTemplate")
    f:SetSize(K.W, K.H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    U.Backdrop(f)

    f.title = U.Text(f, "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -10)
    f.title:SetText("GaarBarsForever \194\183 Flyouts")
    local close = U.TryFrame("Button", nil, f, "UIPanelCloseButton")
    if close then
        close:SetPoint("TOPRIGHT", -2, -2)
        close:SetScript("OnClick", function() f:Hide() end)
    end

    -- Left: the flyouts.
    f.list = U.TryFrame("Frame", nil, f, "BackdropTemplate")
    f.list:SetPoint("TOPLEFT", 12, -34)
    f.list:SetSize(K.LIST_W, K.ROW * K.LIST_ROWS + 8)
    U.Backdrop(f.list, 0.04, 0.05, 0.06, 0.9)
    f.list:EnableMouseWheel(true)
    f.list:SetScript("OnMouseWheel", function(_, delta)
        local FL = U.FL()
        local n = FL and #FL.List() or 0
        S.listOffset = math.max(0, math.min(math.max(0, n - K.LIST_ROWS), S.listOffset - (delta or 0)))
        ED.Refresh()
    end)
    for i = 1, K.LIST_ROWS do U.BuildListRow(f, i) end
    f.empty = U.Text(f.list, "GameFontDisable", "CENTER")
    f.empty:SetPoint("TOPLEFT", 8, -12)
    f.empty:SetPoint("TOPRIGHT", -8, -12)
    f.empty:SetText("No flyouts yet. Click New, or drop a spell on the + of a bar button.")
    f.new = U.PanelButton(f, "New", 90, 22, function()
        local FL = U.FL()
        local nf = FL and FL.New()
        if nf then
            S.sel = nf.id
            ED.Refresh()
        end
    end)
    f.new:SetPoint("TOPLEFT", f.list, "BOTTOMLEFT", 0, -6)
    f.delete = U.PanelButton(f, "Delete", 90, 22, function()
        local sel = U.Selected()
        if not sel or not U.CanEdit() then return end
        f.confirm.id = sel.id
        f.confirm.text:SetText("Delete flyout \"" .. sel.name .. "\""
            .. (sel.macro and (" and its macro " .. sel.macro) or "") .. "?\nThis cannot be undone.")
        f.confirm:Show()
    end)
    f.delete:SetPoint("TOPRIGHT", f.list, "BOTTOMRIGHT", 0, -6)

    -- Right: the selected flyout.
    f.right = U.TryFrame("Frame", nil, f)
    f.right:SetPoint("TOPLEFT", f.list, "TOPRIGHT", 14, 0)
    f.right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)

    f.nameLabel = U.Text(f.right, "GameFontNormalSmall")
    f.nameLabel:SetPoint("TOPLEFT", 0, -6)
    f.nameLabel:SetText("Name")
    f.name = U.TryFrame("EditBox", nil, f.right, "InputBoxTemplate")
    f.name:SetSize(200, 22)
    f.name:SetPoint("TOPLEFT", f.nameLabel, "BOTTOMLEFT", 6, -2)
    f.name:SetAutoFocus(false)
    if type(f.name.SetMaxLetters) == "function" then f.name:SetMaxLetters(40) end
    f.name:SetScript("OnEnterPressed", function(self) U.Safe("rename", U.ApplyName, self); self:ClearFocus() end)
    f.name:SetScript("OnEscapePressed", function(self)
        local sel = U.Selected()
        self:SetText(sel and sel.name or "")
        self:ClearFocus()
    end)
    f.name:SetScript("OnEditFocusLost", function(self) U.Safe("rename", U.ApplyName, self) end)

    f.iconLabel = U.Text(f.right, "GameFontNormalSmall")
    f.iconLabel:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", -6, -10)
    f.iconLabel:SetText("Icon")
    f.iconBtn = U.TryFrame("Button", nil, f.right)
    f.iconBtn:SetSize(36, 36)
    f.iconBtn:SetPoint("TOPLEFT", f.iconLabel, "BOTTOMLEFT", 0, -4)
    f.iconBtn.tex = f.iconBtn:CreateTexture(nil, "ARTWORK")
    f.iconBtn.tex:SetAllPoints(f.iconBtn)
    f.iconBtn.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.iconBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    f.iconBtn:SetScript("OnClick", function() U.Safe("picker", U.TogglePicker) end)
    f.iconBtn:SetScript("OnEnter", function(self)
        local tt = _G.GameTooltip
        if not tt then return end
        tt:SetOwner(self, "ANCHOR_RIGHT")
        tt:SetText("Choose an icon", 1, 1, 1)
        tt:Show()
    end)
    f.iconBtn:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    f.useFirst = U.TryFrame("CheckButton", nil, f.right, "UICheckButtonTemplate")
    f.useFirst:SetSize(24, 24)
    f.useFirst:SetPoint("LEFT", f.iconBtn, "RIGHT", 8, 0)
    f.useFirst:SetScript("OnClick", function(self)
        local FL, sel = U.FL(), U.Selected()
        if not (FL and sel) then return end
        if self:GetChecked() then
            FL.SetIcon(sel.id, nil)
        else
            FL.SetIcon(sel.id, FL.Icon(sel))
        end
        ED.Refresh()
    end)
    f.useFirstText = U.Text(f.right, "GameFontHighlightSmall")
    f.useFirstText:SetPoint("LEFT", f.useFirst, "RIGHT", 2, 0)
    f.useFirstText:SetText("Use entry 1's icon")

    -- Bar placement: the drag handle.
    f.handle = U.TryFrame("Button", nil, f.right)
    f.handle:SetSize(56, 56)
    f.handle:SetPoint("TOPRIGHT", f.right, "TOPRIGHT", -8, -8)
    f.handle.tex = f.handle:CreateTexture(nil, "ARTWORK")
    f.handle.tex:SetAllPoints(f.handle)
    f.handle.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.handle.border = f.handle:CreateTexture(nil, "ARTWORK", nil, 1)
    f.handle.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    f.handle.border:SetSize(102, 102)
    f.handle.border:SetPoint("CENTER", 0, -1)
    f.handle:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    f.handle:RegisterForDrag("LeftButton")
    f.handle:RegisterForClicks("LeftButtonUp")
    local function PickUp()
        local FL, sel = U.FL(), U.Selected()
        if FL and sel and U.CanEdit() then FL.Pickup(sel.id) end
    end
    f.handle:SetScript("OnDragStart", function() U.Safe("pickup", PickUp) end)
    f.handle:SetScript("OnClick", function() U.Safe("pickup", PickUp) end)
    f.handle:SetScript("OnEnter", function(self)
        local tt = _G.GameTooltip
        if not tt then return end
        tt:SetOwner(self, "ANCHOR_RIGHT")
        tt:SetText("Place on a bar", 1, 1, 1)
        tt:AddLine("Drag this onto any action bar button (or click, then click a button). The button"
            .. " then opens this flyout.", 0.8, 0.8, 0.8, true)
        tt:Show()
    end)
    f.handle:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    f.handleText = U.Text(f.right, "GameFontHighlightSmall", "RIGHT")
    f.handleText:SetPoint("TOPRIGHT", f.handle, "BOTTOMRIGHT", 0, -6)
    f.handleText:SetWidth(170)
    f.macroText = U.Text(f.right, "GameFontDisableSmall", "RIGHT")
    f.macroText:SetPoint("TOPRIGHT", f.handleText, "BOTTOMRIGHT", 0, -2)
    f.macroText:SetWidth(170)
    f.dragLabel = U.Text(f.right, "GameFontNormalSmall", "RIGHT")
    f.dragLabel:SetPoint("RIGHT", f.handle, "LEFT", -10, 0)
    f.dragLabel:SetText("Drag onto a\nbar button")

    -- Entries.
    f.entriesTop = U.Text(f.right, "GameFontNormalSmall")
    f.entriesTop:SetPoint("TOPLEFT", f.iconBtn, "BOTTOMLEFT", 0, -28)
    for i = 1, K.MAX_ENTRIES do U.BuildEntryRow(f, i) end
    f.drop = U.TryFrame("Button", nil, f.right, "BackdropTemplate")
    f.drop:SetHeight(K.ENTRY_ROW + 4)
    f.drop:SetPoint("TOPLEFT", f.entriesTop, "BOTTOMLEFT", 0, -4)
    f.drop:SetPoint("RIGHT", f.right, "RIGHT", -8, 0)
    U.Backdrop(f.drop, 0.10, 0.16, 0.10, 0.8)
    f.drop:RegisterForClicks("LeftButtonUp")
    f.drop.text = U.Text(f.drop, "GameFontHighlightSmall", "CENTER")
    f.drop.text:SetPoint("CENTER")
    f.drop.text:SetText("+ Drop a spell, item or macro here to add it")
    local function AddCursor()
        local FL, sel = U.FL(), U.Selected()
        if FL and sel and U.CanEdit() then FL.AddCursor(sel.id) end
    end
    f.drop:SetScript("OnReceiveDrag", function() U.Safe("add", AddCursor) end)
    f.drop:SetScript("OnClick", function() U.Safe("add", AddCursor) end)

    f.combat = U.Text(f, "GameFontRedSmall", "LEFT")
    f.combat:SetPoint("TOPLEFT", f.new, "BOTTOMLEFT", 0, -10)
    f.combat:SetWidth(K.LIST_W)
    f.combat:SetWordWrap(true)
    f.combat:SetText("Locked in combat: flyouts can be edited when the fight ends.")
    f.hint = U.Text(f.right, "GameFontDisableSmall")
    f.hint:SetPoint("BOTTOMLEFT", f.right, "BOTTOMLEFT", 0, 0)
    f.hint:SetPoint("RIGHT", f.right, "RIGHT", -8, 0)
    f.hint:SetText("On the bars: click or the button's key opens it; the key again or a right-click"
        .. " casts entry 1. In an open flyout, right-click or drag out an entry to remove it.")
    f.hint:SetWordWrap(true)

    U.BuildConfirm(f)
    f:SetScript("OnShow", function() U.Safe("refresh", ED.Refresh) end)
    f:SetScript("OnHide", function()
        if S.picker then S.picker:Hide() end
        f.confirm:Hide()
    end)
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            self.confirm:Hide()
            if S.picker then S.picker:Hide() end
        end
        if self:IsShown() then U.Safe("refresh", ED.Refresh) end
    end)
    f:Hide()
    if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "GaarBarsForeverFlyoutEditor") end
    S.frame = f
    return f
end

-- ---------------------------------------------------------------------------
-- Icon picker (our own grid of the client's macro icons)
-- ---------------------------------------------------------------------------

function U.LoadIcons()
    if S.icons then return S.icons end
    local out, seen = {}, {}
    local function Add(list)
        for _, v in ipairs(list) do
            local tex = tonumber(v) or (type(v) == "string" and ("INTERFACE\\ICONS\\" .. v)) or nil
            if tex and not seen[tex] then
                seen[tex] = true
                out[#out + 1] = tex
            end
        end
    end
    for _, fn in ipairs({ "GetLooseMacroIcons", "GetLooseMacroItemIcons", "GetMacroIcons", "GetMacroItemIcons" }) do
        if type(_G[fn]) == "function" then
            local t = {}
            local ok, ret = pcall(_G[fn], t)
            if ok then
                Add(t)
                if type(ret) == "table" and ret ~= t then Add(ret) end
            end
        end
    end
    S.icons = out
    return out
end

function U.BuildPicker()
    if S.picker then return S.picker end
    local f = S.frame
    local cell = K.ICON_SIZE + K.ICON_GAP
    local p = U.TryFrame("Frame", nil, f, "BackdropTemplate")
    p:SetSize(K.ICON_COLS * cell + 40, K.ICON_ROWS * cell + 74)
    p:SetPoint("TOPLEFT", f, "TOPRIGHT", 4, 0)
    p:SetFrameLevel(f:GetFrameLevel() + 20)
    p:EnableMouse(true)
    U.Backdrop(p)
    p.title = U.Text(p, "GameFontNormal")
    p.title:SetPoint("TOPLEFT", 12, -10)
    p.title:SetText("Choose an icon")
    local close = U.TryFrame("Button", nil, p, "UIPanelCloseButton")
    if close then
        close:SetPoint("TOPRIGHT", -2, -2)
        close:SetScript("OnClick", function() p:Hide() end)
    end
    p.first = U.PanelButton(p, "Use entry 1's icon", 150, 22, function()
        local FL, sel = U.FL(), U.Selected()
        if FL and sel then FL.SetIcon(sel.id, nil) end
        p:Hide()
    end)
    p.first:SetPoint("TOPLEFT", 12, -32)
    p.count = U.Text(p, "GameFontDisableSmall", "RIGHT")
    p.count:SetPoint("LEFT", p.first, "RIGHT", 8, 0)
    p.count:SetPoint("RIGHT", p, "RIGHT", -12, 0)
    p.cells = {}
    for r = 1, K.ICON_ROWS do
        for c = 1, K.ICON_COLS do
            local b = U.TryFrame("Button", nil, p)
            b:SetSize(K.ICON_SIZE, K.ICON_SIZE)
            b:SetPoint("TOPLEFT", p, "TOPLEFT", 12 + (c - 1) * cell, -62 - (r - 1) * cell)
            b.tex = b:CreateTexture(nil, "ARTWORK")
            b.tex:SetAllPoints(b)
            b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            b:SetScript("OnClick", function(self)
                local FL, sel = U.FL(), U.Selected()
                if FL and sel and self.icon then FL.SetIcon(sel.id, self.icon) end
                p:Hide()
            end)
            p.cells[#p.cells + 1] = b
        end
    end
    -- A plain vertical slider of ours, plus the mouse wheel.
    local sl = U.TryFrame("Slider", nil, p, "BackdropTemplate")
    sl:SetOrientation("VERTICAL")
    sl:SetWidth(14)
    sl:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, -62)
    sl:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -10, 12)
    U.Backdrop(sl, 0.04, 0.05, 0.06, 0.9)
    sl:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    sl:SetValueStep(1)
    if type(sl.SetObeyStepOnDrag) == "function" then sl:SetObeyStepOnDrag(true) end
    sl:SetMinMaxValues(0, 0)
    sl:SetValue(0)
    sl:SetScript("OnValueChanged", function(_, v)
        local row = math.floor((tonumber(v) or 0) + 0.5)
        if row ~= S.iconOffset then
            S.iconOffset = row
            U.Safe("icons", U.FillPicker)
        end
    end)
    p.slider = sl
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(_, delta)
        local lo, hi = sl:GetMinMaxValues()
        sl:SetValue(math.max(lo, math.min(hi, S.iconOffset - (delta or 0) * 2)))
    end)
    p:SetScript("OnHide", function() S.icons = nil end) -- the list is rebuilt next time (memory)
    p:Hide()
    S.picker = p
    return p
end

function U.FillPicker()
    local p = S.picker
    if not p then return end
    local icons = U.LoadIcons()
    local rows = math.ceil(#icons / K.ICON_COLS)
    local maxOff = math.max(0, rows - K.ICON_ROWS)
    p.slider:SetMinMaxValues(0, maxOff)
    if S.iconOffset > maxOff then S.iconOffset = maxOff end
    p.count:SetText(#icons .. " icons")
    local base = S.iconOffset * K.ICON_COLS
    for i, b in ipairs(p.cells) do
        local tex = icons[base + i]
        b.icon = tex
        if tex then
            b.tex:SetTexture(tex)
            b:Show()
        else
            b:Hide()
        end
    end
end

function U.TogglePicker()
    if not U.Selected() or not U.CanEdit() then return end
    local p = U.BuildPicker()
    if p:IsShown() then p:Hide() return end
    S.iconOffset = 0
    p:Show()
    p.slider:SetValue(0)
    U.FillPicker()
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

function ED.Refresh()
    local f = S.frame
    if not f or not f:IsShown() then return end
    local FL = U.FL()
    if not FL then return end
    local list = FL.List()
    local edit = U.CanEdit()
    if S.sel and not FL.Get(S.sel) then S.sel = nil end
    if not S.sel and list[1] then S.sel = list[1].id end
    S.listOffset = math.max(0, math.min(S.listOffset, math.max(0, #list - K.LIST_ROWS)))
    for i, r in ipairs(S.rows) do
        local fl = list[S.listOffset + i]
        r.id = fl and fl.id or nil
        if fl then
            r.icon:SetTexture(FL.Icon(fl))
            r.name:SetText(fl.name)
            r.sel:SetShown(fl.id == S.sel)
            r:Show()
        else
            r:Hide()
        end
    end
    f.empty:SetShown(#list == 0)
    U.SetEnabled(f.new, edit)
    local sel = U.Selected()
    U.SetEnabled(f.delete, edit and sel ~= nil)
    f.combat:SetShown(not edit)
    f.right:SetShown(sel ~= nil)
    if not sel then return end

    if not f.name:HasFocus() then f.name:SetText(sel.name) end
    U.SetEnabled(f.name, edit)
    if not edit and f.name:HasFocus() then f.name:ClearFocus() end
    local icon = FL.Icon(sel)
    f.iconBtn.tex:SetTexture(icon)
    U.SetEnabled(f.iconBtn, edit)
    f.useFirst:SetChecked(sel.icon == nil)
    U.SetEnabled(f.useFirst, edit)
    f.handle.tex:SetTexture(icon)
    U.SetEnabled(f.handle, edit and sel.macro ~= nil)
    local n = FL.SlotCount(sel)
    f.handleText:SetText("On " .. n .. " button" .. (n == 1 and "" or "s"))
    f.macroText:SetText(sel.macro and ("Macro: " .. sel.macro) or "No macro yet (macro slots full?)")

    local entries = sel.entries
    f.entriesTop:SetText(string.format("Entries (%d/%d) - entry 1 is what right-click and the macro cast",
        #entries, K.MAX_ENTRIES))
    for i, r in ipairs(S.entryRows) do
        local e = entries[i]
        r.index, r.entry = e and i or nil, e
        if e then
            r.num:SetText(i .. ".")
            r.icon:SetTexture(FL.EntryIcon(e))
            r.name:SetText(FL.EntryName(e) or "?")
            r.rank:SetText(FL.EntryRank(e) or "")
            U.SetEnabled(r.up, edit and i > 1)
            U.SetEnabled(r.down, edit and i < #entries)
            U.SetEnabled(r.remove, edit)
            r:Show()
        else
            r:Hide()
        end
    end
    f.drop:ClearAllPoints()
    local last = #entries > 0 and S.entryRows[math.min(#entries, K.MAX_ENTRIES)] or nil
    if last then
        f.drop:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -4)
    else
        f.drop:SetPoint("TOPLEFT", f.entriesTop, "BOTTOMLEFT", 0, -4)
    end
    f.drop:SetPoint("RIGHT", f.right, "RIGHT", -8, 0)
    f.drop:SetShown(#entries < K.MAX_ENTRIES)
    U.SetEnabled(f.drop, edit)
end

function ED.Open()
    local f = U.Build()
    if not f then return end
    f:Show()
    f:Raise()
    ED.Refresh()
end

function ED.Close()
    if S.frame then S.frame:Hide() end
end

function ED.Toggle()
    if S.frame and S.frame:IsShown() then ED.Close() else ED.Open() end
end

B.OpenFlyoutEditor = function() U.Safe("open", ED.Toggle) end
B.FlyoutEditorRefresh = function() U.Safe("refresh", ED.Refresh) end
