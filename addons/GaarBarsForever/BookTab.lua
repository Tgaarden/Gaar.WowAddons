--[[
  GaarBarsForever - BookTab.lua: the "Missing from bars" tab in the spellbook (bookMissingTab).

  A square icon tab of our own in the BOTTOM-LEFT corner of the spellbook, level with the page
  arrows, so it never touches the category tab row. It wears the art of Forever's category icon
  tabs (read from a live tab at setup, spellbook-Tab-Frame-C60 and its glow as the fallback, an
  action-button frame if the client has neither), a book icon with a green arrow, a count badge,
  and the selected (glow) look while our panel is open; clicking it again closes the panel.
  Clicking it shows a panel of ours over the paged spell area: ONE list of the player's known,
  castable, non-passive spells that either

    a) are on no action bar slot (no rank of the spell anywhere on slots 1-180, and
       C_ActionBar.FindSpellActionButtons finds none of its rank ids), or
    b) sit on a bar only at a lower rank than the highest rank known ("Bar has Rank 2 · Rank 3
       known").

  The entries look like Blizzard's spellbook items (same atlases, fonts, grid and paging). Hover
  shows the spell tooltip, a left-drag picks the spell up (out of combat) so it can be dropped on
  a bar, a left-click casts it.

  The panel clips everything it draws to its own rect, which starts below the lowest category
  tab: 1.4.0 mirrored the book's background over a frame above the tab row, which hid every
  category tab (only What's Training?'s "?" tab, drawn higher, stayed visible).

  What's Training? (a third-party addon) adds its own "?" tab after the category tabs and covers
  the pages with its own frame. Its tab click closes our panel (HookScript on its button), and
  opening ours first closes its page (a click on its tab, which toggles it off).

  Taint and combat:
    * Nothing of Blizzard's is written. Its tab system, data provider, categories and paged
      frame are only read; the hooks are hooksecurefunc (SpellBookFrame:SetTab, the tab system's
      SetTab / SetTabShown, SetMinimized) and HookScript (OnShow / OnHide of the book, the search
      box's focus). No layout method of Blizzard's is called and our tab is not part of its tab
      row. Blizzard's selected tab is never changed: our tab shows itself selected and our panel
      covers the page; any Blizzard tab click (SetTab), a click on the still-selected Blizzard
      tab (a plain, invisible catcher button of ours over it, since that tab is disabled),
      focusing the search box or closing the book closes our panel.
    * Each entry's icon is a SecureActionButtonTemplate button (type1 = "spell", spell = id),
      from a pool sized to one page. The panel holding them is attached to the spellbook only
      while it is open (SetParent out of combat) and parked on UIParent otherwise, so the book
      carries no protected children while our tab is closed. Attributes, show / hide, parent and
      anchors change only out of combat; in combat the panel stays exactly as it is and catches
      up at PLAYER_REGEN_ENABLED. Opening our tab in combat is refused with the usual error.
    * useOnKeyDown = false on the buttons: a click casts on release, so a drag never casts first
      (RegisterForClicks("AnyUp", "AnyDown") as 12.x wants; the secure handler acts once).
    * A secret value is never compared: every read goes through the main file's FieldOf /
      CallOf / Secret helpers.
]]

local _G = _G
local _, NS = ...
if type(NS) ~= "table" or type(NS.Bars) ~= "table" then return end

local B = NS.Bars
local Secret, Num, FieldOf, CallOf = B.Secret, B.Num, B.FieldOf, B.CallOf
local SpellName, SpellRank, InCombat = B.SpellName, B.SpellRank, B.InCombat

local FEATURE = "bookMissingTab"
local TAB_TOOLTIP = "Missing from bars"
local HEADER_TEXT = "Missing from bars"
local EMPTY_TEXT = "All your spells are on your bars at their highest rank."
local TAG_MISSING = "Not on your bars"
local TAG_LOW = "Bar has Rank %d \194\183 Rank %d known"
local TAB_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local MAX_ACTION_SLOT = 180
local THROTTLE = 0.2

-- Auto Attack, Auto Shot and the two Shoot spells: on every character, never worth a reminder.
local SKIP_IDS = { [6603] = true, [75] = true, [5019] = true, [3018] = true }

-- Blizzard_SpellBookFrame.xml / Blizzard_SpellBookItem.xml values, used where the live views
-- cannot be read.
local ITEM_W, ITEM_H = 220, 60
local X_PAD, Y_PAD = 15, 10
local COLS = 3
local HEADER_H = 51
local VIEW_W, VIEW_H = 680, 650

-- Forever's category icon tabs (the same art What's Training? copies). Names read from a live
-- tab win; these are used when a tab carries none, and only if the client knows the atlas.
local TAB_ART = { normal = "spellbook-Tab-Frame-C60", active = "spellbook-Tab-Frame-Glow-C60",
    glow = "spellbook-Tab-Frame-glow-gradient-C60" }
local TAB_W, TAB_H = 44, 32
local TAB_ICON_W, TAB_ICON_H = 34, 33
-- Bottom-left corner of the book, on the row of Blizzard's page arrows (BOTTOMRIGHT -75, 40),
-- left of the first page's grid (x 85).
local TAB_X, TAB_Y = 28, 40

local MISSING_RGB = { 0.55, 0.10, 0.05 }
local LOW_RGB = { 0.70, 0.30, 0.00 }
local GLOW_LOW_RGB = { 1.0, 0.55, 0.1 }
local FALLBACK_FONT_RGB = { 0.25, 0.15, 0.05 }

local BT = {}
NS.BookTab = BT

local S = {
    sb = nil, tab = nil, catcher = nil, panel = nil,
    open = false, anchored = false, anchorTo = "not built",
    pendingClose = false, pendingRender = false,
    dirty = true, list = nil, missing = 0, low = 0,
    page = 1, pages = 1, perPage = 0, pool = {}, slots = {},
    err = nil, hooked = {}, wtHooked = false,
}

local UpdateBadge -- our tab's count badge (defined with the tab)

local function Err(where, err)
    S.err = where .. ": " .. tostring(err)
    if type(B.Fail) == "function" then B.Fail("booktab " .. where, err) end
end

local function Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Err(where, err) end
    return ok
end

local function On() return type(B.On) == "function" and B.On(FEATURE) == true end

local function Sound(key)
    local K = _G.SOUNDKIT
    if type(K) == "table" and K[key] and type(_G.PlaySound) == "function" then pcall(_G.PlaySound, K[key]) end
end

local function FontRGB()
    local c = _G.SPELLBOOK_FONT_COLOR
    if type(c) == "table" and type(c.GetRGB) == "function" then
        local ok, r, g, b = pcall(c.GetRGB, c)
        if ok and Num(r) and Num(g) and Num(b) then return r, g, b end
    end
    return FALLBACK_FONT_RGB[1], FALLBACK_FONT_RGB[2], FALLBACK_FONT_RGB[3]
end

local function Font(fs, ...)
    for i = 1, select("#", ...) do
        local f = _G[(select(i, ...))]
        if type(f) == "table" then fs:SetFontObject(f) return end
    end
end

local function Atlas(tex, atlas, useSize)
    local ok, r = pcall(tex.SetAtlas, tex, atlas, useSize and true or false)
    return ok and r ~= false
end

-- ---------------------------------------------------------------------------
-- The list: spellbook spells grouped by name, checked against the bars
-- ---------------------------------------------------------------------------

local function ParseRank(sub)
    if type(sub) ~= "string" or Secret(sub) then return nil end
    local n = sub:match("(%d+)")
    return n and tonumber(n) or nil
end

local function IsPassive(id)
    local C = _G.C_Spell
    local f = (type(C) == "table" and type(C.IsSpellPassive) == "function" and C.IsSpellPassive)
        or (type(_G.IsPassiveSpell) == "function" and _G.IsPassiveSpell) or nil
    if not f then return false end
    local ok, v = pcall(f, id)
    return ok and not Secret(v) and v == true
end

local function SpellIcon(id)
    local C = _G.C_Spell
    local f = (type(C) == "table" and type(C.GetSpellTexture) == "function" and C.GetSpellTexture)
        or (type(_G.GetSpellTexture) == "function" and _G.GetSpellTexture) or nil
    if not f then return nil end
    local ok, v = pcall(f, id)
    if ok and not Secret(v) then return v end
    return nil
end

-- Groups in spellbook order: { name, id (highest rank), rank, icon, ids = { every rank id } }.
local function CollectBook()
    local order, groups = {}, {}
    local function Add(id, name, sub, icon)
        id = Num(id)
        if not id or id <= 0 or SKIP_IDS[id] or IsPassive(id) then return end
        if type(name) ~= "string" or name == "" then name = SpellName(id) end
        if not name then return end
        local rank = ParseRank(sub) or SpellRank(id)
        local g = groups[name]
        if not g then
            g = { name = name, ids = {} }
            groups[name] = g
            order[#order + 1] = g
        end
        g.ids[#g.ids + 1] = id
        if not g.id or (rank and (not g.rank or rank > g.rank)) then
            g.id, g.rank, g.icon = id, rank, icon
        end
    end
    local SB = _G.C_SpellBook
    if type(SB) == "table" and type(SB.GetNumSpellBookSkillLines) == "function"
        and type(SB.GetSpellBookSkillLineInfo) == "function" and type(SB.GetSpellBookItemInfo) == "function" then
        local E = _G.Enum
        local bank = E and E.SpellBookSpellBank and E.SpellBookSpellBank.Player or 0
        local spellType = E and E.SpellBookItemType and E.SpellBookItemType.Spell
        local okN, n = pcall(SB.GetNumSpellBookSkillLines)
        n = okN and Num(n) or 0
        for i = 1, n do
            local okL, li = pcall(SB.GetSpellBookSkillLineInfo, i)
            if okL and type(li) == "table" and not Secret(li) then
                local offSpec = Num(FieldOf(li, "offSpecID"))
                if FieldOf(li, "shouldHide") ~= true and not (offSpec and offSpec > 0) then
                    local off = Num(FieldOf(li, "itemIndexOffset")) or 0
                    local count = Num(FieldOf(li, "numSpellBookItems")) or 0
                    for slot = off + 1, off + count do
                        local okI, info = pcall(SB.GetSpellBookItemInfo, slot, bank)
                        if okI and type(info) == "table" and not Secret(info)
                            and (spellType == nil or FieldOf(info, "itemType") == spellType)
                            and FieldOf(info, "isPassive") ~= true and FieldOf(info, "isOffSpec") ~= true then
                            Add(FieldOf(info, "spellID") or FieldOf(info, "actionID"), FieldOf(info, "name"),
                                FieldOf(info, "subName"), FieldOf(info, "iconID"))
                        end
                    end
                end
            end
        end
    elseif type(_G.GetNumSpellTabs) == "function" and type(_G.GetSpellTabInfo) == "function"
        and type(_G.GetSpellBookItemInfo) == "function" then
        local okN, tabs = pcall(_G.GetNumSpellTabs)
        tabs = okN and Num(tabs) or 0
        for t = 1, tabs do
            local okT, _, _, off, count, _, offSpec = pcall(_G.GetSpellTabInfo, t)
            off, count, offSpec = okT and Num(off) or 0, okT and Num(count) or 0, okT and Num(offSpec) or 0
            if not (offSpec and offSpec > 0) then
                for j = off + 1, off + count do
                    local okI, kind, id = pcall(_G.GetSpellBookItemInfo, j, "spell")
                    if okI and not Secret(kind) and kind == "SPELL" then
                        local passive = false
                        if type(_G.IsPassiveSpell) == "function" then
                            local okP, p = pcall(_G.IsPassiveSpell, j, "spell")
                            passive = okP and not Secret(p) and p and true or false
                        end
                        if not passive then
                            local name, sub
                            if type(_G.GetSpellBookItemName) == "function" then
                                local okNm, nm, st = pcall(_G.GetSpellBookItemName, j, "spell")
                                if okNm and not Secret(nm) then name, sub = nm, (not Secret(st)) and st or nil end
                            end
                            Add(id, name, sub, nil)
                        end
                    end
                end
            end
        end
    end
    return order
end

-- What the player action slots hold: spell ids (direct or a macro's spell) and, per name, the
-- highest rank on a bar (`max`) or `unranked` when a copy carries no rank.
local function BarScan()
    local ids, byName = {}, {}
    local CAB = _G.C_ActionBar
    local has = (type(CAB) == "table" and type(CAB.HasAction) == "function" and CAB.HasAction)
        or (type(_G.HasAction) == "function" and _G.HasAction) or nil
    local info = (type(_G.GetActionInfo) == "function" and _G.GetActionInfo)
        or (type(CAB) == "table" and type(CAB.GetActionInfo) == "function" and CAB.GetActionInfo) or nil
    if not info then return ids, byName end
    for slot = 1, MAX_ACTION_SLOT do
        local okH, h = true, true
        if has then okH, h = pcall(has, slot) end
        if okH and not Secret(h) and h then
            local ok, kind, id = pcall(info, slot)
            if ok and not Secret(kind) and not Secret(id) then
                local sid
                if kind == "spell" then
                    sid = Num(id)
                elseif kind == "macro" and type(_G.GetMacroSpell) == "function" then
                    local okM, m = pcall(_G.GetMacroSpell, id)
                    if okM and not Secret(m) then sid = Num(m) end
                end
                if sid then
                    ids[sid] = true
                    local name = SpellName(sid)
                    if name then
                        local e = byName[name]
                        if not e then e = {}; byName[name] = e end
                        local r = SpellRank(sid)
                        if r then
                            if not e.max or r > e.max then e.max = r end
                        else
                            e.unranked = true
                        end
                    end
                end
            end
        end
    end
    return ids, byName
end

local function FoundOnBar(id)
    local CAB = _G.C_ActionBar
    if type(CAB) ~= "table" or type(CAB.FindSpellActionButtons) ~= "function" then return false end
    local ok, slots = pcall(CAB.FindSpellActionButtons, id)
    if not ok or type(slots) ~= "table" or Secret(slots) then return false end
    return next(slots) ~= nil
end

local function Compute()
    local groups = CollectBook()
    local barIds, barByName = BarScan()
    local out, missing, low = {}, 0, 0
    for _, g in ipairs(groups) do
        if g.id then
            local onBar = barByName[g.name]
            local any = onBar ~= nil
            if not any then
                for _, id in ipairs(g.ids) do
                    if barIds[id] or FoundOnBar(id) then any = true break end
                end
            end
            local icon = g.icon or SpellIcon(g.id)
            if not any then
                out[#out + 1] = { id = g.id, name = g.name, rank = g.rank, icon = icon, kind = "missing" }
                missing = missing + 1
            elseif g.rank and onBar and onBar.max and not onBar.unranked and onBar.max < g.rank
                and not barIds[g.id] then
                out[#out + 1] = { id = g.id, name = g.name, rank = g.rank, icon = icon, kind = "low",
                    barRank = onBar.max }
                low = low + 1
            end
        end
    end
    S.list, S.missing, S.low, S.dirty = out, missing, low, false
    if UpdateBadge then UpdateBadge() end
    return out
end

-- ---------------------------------------------------------------------------
-- Blizzard's frames (read only)
-- ---------------------------------------------------------------------------

local function BookFrame()
    local psf = _G.PlayerSpellsFrame
    local sb = type(psf) == "table" and FieldOf(psf, "SpellBookFrame") or nil
    return type(sb) == "table" and sb or nil
end

local function TabSystem(sb)
    local ts = FieldOf(sb, "CategoryTabSystem") or FieldOf(sb, "tabSystem")
    return type(ts) == "table" and ts or nil
end

local function TabList(ts)
    local tabs = ts and FieldOf(ts, "tabs")
    return type(tabs) == "table" and not Secret(tabs) and tabs or {}
end

-- The left-most shown Blizzard tab (lowest layoutIndex).
local function FirstShownTab(ts)
    local best, bestIdx
    for i, t in ipairs(TabList(ts)) do
        if type(t) == "table" and CallOf(t, "IsShown") then
            local idx = Num(FieldOf(t, "layoutIndex")) or i
            if not bestIdx or idx < bestIdx then best, bestIdx = t, idx end
        end
    end
    return best
end

local function SelectedTab(ts)
    local id = ts and Num(FieldOf(ts, "selectedTabID"))
    local t = id and TabList(ts)[id]
    if type(t) == "table" and CallOf(t, "IsShown") then return t end
    return nil
end

-- ---------------------------------------------------------------------------
-- Our tab
-- ---------------------------------------------------------------------------

local function AtlasKnown(atlas)
    local CT = _G.C_Texture
    if type(atlas) ~= "string" or type(CT) ~= "table" or type(CT.GetAtlasInfo) ~= "function" then return false end
    local ok, info = pcall(CT.GetAtlasInfo, atlas)
    return ok and type(info) == "table"
end

-- The look of a live category tab: its size, its icon's size and its frame atlases (normal,
-- selected glow, glow gradient), as far as they can be read. Missing names fall back to TAB_ART.
local function NativeTabArt(ts)
    local art = {}
    local tab = ts and FirstShownTab(ts)
    if tab then
        local w, h = Num(CallOf(tab, "GetWidth")), Num(CallOf(tab, "GetHeight"))
        if w and h and w >= 24 and w <= 64 and h >= 24 and h <= 64 then art.w, art.h = w, h end
        local icon = FieldOf(tab, "Icon")
        if type(icon) == "table" then
            local iw, ih = Num(CallOf(icon, "GetWidth")), Num(CallOf(icon, "GetHeight"))
            if iw and ih and iw >= 16 and iw <= 48 and ih >= 16 and ih <= 48 then art.iw, art.ih = iw, ih end
        end
        local regions = FieldOf(tab, "GetRegions")
        if type(regions) == "function" then
            local res = { pcall(regions, tab) }
            for i = 2, #res do
                local a = type(res[i]) == "table" and CallOf(res[i], "GetAtlas") or nil
                if type(a) == "string" then
                    local l = a:lower()
                    if l:find("tab%-frame") then
                        if l:find("gradient") then art.glow = art.glow or a
                        elseif l:find("glow") then art.active = art.active or a
                        else art.normal = art.normal or a end
                    end
                end
            end
        end
    end
    for k, v in pairs(TAB_ART) do
        if not art[k] and AtlasKnown(v) then art[k] = v end
    end
    return art
end

local function SetTabSelected(sel)
    local t = S.tab
    if not t then return end
    t.selected = sel and true or false
    if t.style == "forever" then
        if t.Active then
            t.Normal:SetShown(not sel)
            t.Active:SetShown(sel)
        else
            t.Normal:SetVertexColor(1, sel and 0.82 or 1, sel and 0 or 1)
        end
        if t.ActiveGlow then t.ActiveGlow:SetShown(sel) end
    else
        t.Active:SetShown(sel)
    end
end

UpdateBadge = function()
    local t = S.tab
    if not (t and t.Count) then return end
    local n = S.list and #S.list or 0
    t.Count:SetText(n > 99 and "99+" or tostring(n))
    t.Count:SetShown(n > 0)
end

-- Bottom-left corner of the book. Level: above our panel (PagedSpellsFrame + 40) and above
-- What's Training?'s page cover (PlayerSpellsFrame.NineSlice - 10), below the border itself.
local function AnchorTab()
    local t, sb = S.tab, S.sb
    if not (t and sb) then return end
    t:ClearAllPoints()
    t:SetPoint("BOTTOMLEFT", sb, "BOTTOMLEFT", TAB_X, TAB_Y)
    local pf = FieldOf(sb, "PagedSpellsFrame")
    local lvl = (Num(CallOf(type(pf) == "table" and pf or sb, "GetFrameLevel")) or 0) + 50
    local psf = _G.PlayerSpellsFrame
    local ns = type(psf) == "table" and FieldOf(psf, "NineSlice") or nil
    local nsl = type(ns) == "table" and Num(CallOf(ns, "GetFrameLevel")) or nil
    if nsl and nsl - 3 > lvl then lvl = nsl - 3 end
    t:SetFrameLevel(lvl)
    S.anchored = true
    S.anchorTo = "book bottom-left, " .. (t.style == "forever" and "Forever tab art" or "plain icon frame")
end

local function TabTooltip(self)
    local tt = _G.GameTooltip
    if not tt then return end
    tt:SetOwner(self, "ANCHOR_RIGHT")
    tt:SetText(TAB_TOOLTIP)
    if On() and not InCombat() then pcall(Compute) end
    if S.list then
        tt:AddLine(string.format("%d not on your bars, %d at a lower rank", S.missing, S.low), 1, 1, 1)
    end
    tt:AddLine(S.open and "Click to go back to your spells." or "Drag a spell onto a bar; click to cast.",
        0.7, 0.7, 0.7)
    tt:Show()
end

local function TabClick()
    if S.open then
        if InCombat() and S.panel and S.panel:IsProtected() then
            BT.CombatError()
            return
        end
        Sound("IG_SPELLBOOK_OPEN")
        Safe("close", BT.Close)
    else
        Safe("open", BT.Open)
    end
end

local function BuildTab(sb)
    local art = NativeTabArt(TabSystem(sb))
    local t = CreateFrame("Button", nil, sb)
    t:RegisterForClicks("LeftButtonUp")
    t.Icon = t:CreateTexture(nil, "ARTWORK")
    t.Icon:SetTexture(TAB_ICON)
    if art.normal then
        -- Forever's icon tab, as its own tabs (and What's Training?'s) are built.
        t.style = "forever"
        t:SetSize(art.w or TAB_W, art.h or TAB_H)
        t.Icon:SetSize(art.iw or TAB_ICON_W, art.ih or TAB_ICON_H)
        t.Icon:SetPoint("BOTTOM", t, "BOTTOM", -1, 0)
        local function FrameArt(atlas, y)
            if not atlas then return nil end
            local x = t:CreateTexture(nil, "ARTWORK", nil, 1)
            if not Atlas(x, atlas, true) then x:Hide() return nil end
            x:SetPoint("BOTTOM", t, "BOTTOM", 0, y)
            return x
        end
        t.Normal = FrameArt(art.normal, 1)
        t.Active = FrameArt(art.active, 1)
        t.ActiveGlow = FrameArt(art.glow, 0)
    end
    if not t.Normal then
        -- Fallback: a 36 x 36 icon in the action button frame, a yellow border when selected.
        t.style = "plain"
        t:SetSize(36, 36)
        t.Icon:ClearAllPoints()
        t.Icon:SetPoint("TOPLEFT", 2, -2)
        t.Icon:SetPoint("BOTTOMRIGHT", -2, 2)
        t.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t.Normal = t:CreateTexture(nil, "ARTWORK", nil, 1)
        t.Normal:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        t.Normal:SetSize(66, 66)
        t.Normal:SetPoint("CENTER", 0, -1)
        t.Active = t:CreateTexture(nil, "OVERLAY", nil, 1)
        t.Active:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        t.Active:SetBlendMode("ADD")
        t.Active:SetVertexColor(1, 0.82, 0)
        t.Active:SetAllPoints(t)
    end
    t:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local hl = t:GetHighlightTexture()
    if hl then
        hl:ClearAllPoints()
        hl:SetAllPoints(t.Icon)
    end
    t.Arrow = t:CreateTexture(nil, "OVERLAY", nil, 2)
    t.Arrow:SetSize(14, 14)
    t.Arrow:SetPoint("BOTTOMRIGHT", t.Icon, "BOTTOMRIGHT", 2, -2)
    if not Atlas(t.Arrow, "bags-greenarrow", false) then t.Arrow:Hide() end
    t.Count = t:CreateFontString(nil, "OVERLAY")
    Font(t.Count, "NumberFontNormalSmall", "NumberFontNormal", "GameFontHighlightSmall")
    t.Count:SetPoint("TOPRIGHT", t.Icon, "TOPRIGHT", -1, -2)
    t.Count:SetJustifyH("RIGHT")
    t.Count:Hide()
    t:SetScript("OnClick", TabClick)
    t:SetScript("OnEnter", function(self) Safe("tooltip", TabTooltip, self) end)
    t:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    S.tab = t
    SetTabSelected(false)
    AnchorTab()
    -- A plain button of ours over the Blizzard tab that still looks selected while our panel is
    -- open (that tab is disabled, so its own OnClick would not fire): a click closes our panel.
    -- No textures: it only takes that click.
    local c = CreateFrame("Button", nil, sb)
    c:Hide()
    c:RegisterForClicks("LeftButtonUp")
    c:SetScript("OnClick", TabClick)
    S.catcher = c
end

local function PlaceCatcher()
    local c = S.catcher
    if not c then return end
    local t = S.open and TabSystem(S.sb) and SelectedTab(TabSystem(S.sb)) or nil
    if not t then c:Hide() return end
    c:ClearAllPoints()
    c:SetAllPoints(t)
    local lvl = Num(CallOf(t, "GetFrameLevel")) or 0
    c:SetFrameLevel(lvl + 5)
    c:Show()
end

-- ---------------------------------------------------------------------------
-- Our panel (holds the secure buttons; only changed out of combat)
-- ---------------------------------------------------------------------------

local function CanChange()
    return not InCombat() or not (S.panel and S.panel:IsProtected())
end

local function MirrorTexture(our, blizz)
    our:ClearAllPoints()
    if type(blizz) ~= "table" or type(blizz.GetAtlas) ~= "function" then our:Hide() return end
    local atlas = CallOf(blizz, "GetAtlas")
    if type(atlas) ~= "string" or not Atlas(our, atlas, false) then our:Hide() return end
    our:SetAllPoints(blizz)
    our:SetShown(CallOf(blizz, "IsShown") and true or false)
end

-- The page-corner flipbook: only its first frame (2 rows x 4 columns), as it rests.
local function MirrorCorner(our, blizz)
    our:ClearAllPoints()
    our:Hide()
    local atlas = type(blizz) == "table" and CallOf(blizz, "GetAtlas")
    local CT = _G.C_Texture
    if type(atlas) ~= "string" or type(CT) ~= "table" or type(CT.GetAtlasInfo) ~= "function" then return end
    local ok, info = pcall(CT.GetAtlasInfo, atlas)
    if not ok or type(info) ~= "table" then return end
    local file = info.file or info.filename
    local l, r, t, b = Num(info.leftTexCoord), Num(info.rightTexCoord), Num(info.topTexCoord), Num(info.bottomTexCoord)
    if not (file and l and r and t and b) then return end
    our:SetTexture(file)
    our:SetTexCoord(l, l + (r - l) / 4, t, t + (b - t) / 2)
    our:SetAllPoints(blizz)
    our:SetShown(CallOf(blizz, "IsShown") and true or false)
end

local function EntryEnter(self)
    local e = self.entry
    e.Backplate:SetAlpha(1)
    self.Hover:Show()
    local tt = _G.GameTooltip
    if tt and self.spellID then
        tt:SetOwner(self, "ANCHOR_RIGHT")
        if not pcall(tt.SetSpellByID, tt, self.spellID) then tt:SetText(e.Name:GetText() or "") end
        tt:Show()
    end
end

local function EntryLeave(self)
    self.entry.Backplate:SetAlpha(0.25)
    self.Hover:Hide()
    if _G.GameTooltip then _G.GameTooltip:Hide() end
end

local function EntryDrag(self)
    if InCombat() or not self.spellID then return end
    local C = _G.C_Spell
    local f = (type(C) == "table" and type(C.PickupSpell) == "function" and C.PickupSpell)
        or (type(_G.PickupSpell) == "function" and _G.PickupSpell) or nil
    if f then Safe("pickup", f, self.spellID) end
end

local function BuildEntry(p)
    local fr, fg, fb = FontRGB()
    local e = CreateFrame("Frame", nil, p)
    e:SetSize(ITEM_W, ITEM_H)
    e:Hide()
    e.Backplate = e:CreateTexture(nil, "BACKGROUND")
    Atlas(e.Backplate, "spellbook-item-backplate", true)
    e.Backplate:SetPoint("CENTER", 5, -5)
    e.Backplate:SetAlpha(0.25)

    local b = CreateFrame("Button", nil, e, "SecureActionButtonTemplate")
    b:SetSize(40, 40)
    b:SetPoint("LEFT")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:RegisterForDrag("LeftButton")
    b:SetAttribute("useOnKeyDown", false)
    b.entry = e
    b.Icon = b:CreateTexture(nil, "ARTWORK", nil, -1)
    b.Icon:SetSize(36, 36)
    b.Icon:SetPoint("CENTER")
    if type(b.CreateMaskTexture) == "function" then
        local m = b:CreateMaskTexture()
        if Atlas(m, "spellbook-item-spellicon-mask", false) then
            m:SetAllPoints(b.Icon)
            b.Icon:AddMaskTexture(m)
        end
    end
    local shadow = b:CreateTexture(nil, "ARTWORK", nil, 1)
    Atlas(shadow, "spellbook-item-iconframe-shadow", false)
    shadow:SetPoint("TOPLEFT", -12, 3)
    shadow:SetPoint("BOTTOMRIGHT", 2, -8)
    local border = b:CreateTexture(nil, "OVERLAY", nil, 1)
    if not Atlas(border, "spellbook-item-iconframe", false) then
        border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    end
    border:SetPoint("TOPLEFT", -11, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -7)
    b.Hover = b:CreateTexture(nil, "OVERLAY", nil, 2)
    Atlas(b.Hover, "spellbook-item-iconframe-hover", false)
    b.Hover:SetAllPoints(b)
    b.Hover:SetBlendMode("ADD")
    b.Hover:SetAlpha(0.35)
    b.Hover:Hide()
    b.Glow = b:CreateTexture(nil, "OVERLAY", nil, 5)
    Atlas(b.Glow, "spellbook-item-unassigned-glow", false)
    b.Glow:SetBlendMode("ADD")
    b.Glow:SetPoint("TOPLEFT", -4, 3)
    b.Glow:SetPoint("BOTTOMRIGHT", 3, -3)
    local ag = b.Glow:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0.5)
    a:SetDuration(0.5)
    b.GlowAnim = ag
    b:SetScript("OnEnter", function(self) Safe("enter", EntryEnter, self) end)
    b:SetScript("OnLeave", function(self) Safe("leave", EntryLeave, self) end)
    b:SetScript("OnDragStart", function(self) Safe("drag", EntryDrag, self) end)
    e.Button = b

    local tc = CreateFrame("Frame", nil, e)
    tc:SetPoint("LEFT", 50, -1)
    tc:SetPoint("RIGHT", 0, -1)
    tc:SetHeight(1)
    e.Text = tc
    e.Name = tc:CreateFontString(nil, "ARTWORK")
    Font(e.Name, "SystemFont_Large", "GameFontNormalLarge")
    e.Name:SetJustifyH("LEFT")
    e.Name:SetWordWrap(true)
    if type(e.Name.SetMaxLines) == "function" then e.Name:SetMaxLines(2) end
    e.Name:SetTextColor(fr, fg, fb)
    e.Name:SetPoint("TOPLEFT")
    e.Name:SetPoint("TOPRIGHT")
    e.Sub = tc:CreateFontString(nil, "ARTWORK")
    Font(e.Sub, "SystemFont_Med1", "GameFontNormal")
    e.Sub:SetJustifyH("LEFT")
    e.Sub:SetTextColor(fr, fg, fb)
    e.Tag = tc:CreateFontString(nil, "ARTWORK")
    Font(e.Tag, "SystemFont_Med1", "GameFontNormal")
    e.Tag:SetJustifyH("LEFT")
    return e
end

local function FillEntry(e, item)
    local b = e.Button
    b:SetAttribute("type1", "spell")
    b:SetAttribute("spell", item.id)
    b.spellID = item.id
    b.Icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    e.Name:SetText(item.name)
    local sub = item.rank and ("Rank " .. item.rank) or ""
    e.Sub:SetText(sub)
    local tag, rgb
    if item.kind == "low" then
        tag, rgb = string.format(TAG_LOW, item.barRank or 0, item.rank or 0), LOW_RGB
        b.Glow:SetVertexColor(GLOW_LOW_RGB[1], GLOW_LOW_RGB[2], GLOW_LOW_RGB[3])
    else
        tag, rgb = TAG_MISSING, MISSING_RGB
        b.Glow:SetVertexColor(1, 1, 1)
    end
    e.Tag:SetText(tag)
    e.Tag:SetTextColor(rgb[1], rgb[2], rgb[3])
    e.Sub:ClearAllPoints()
    e.Tag:ClearAllPoints()
    local h = Num(e.Name:GetStringHeight()) or 14
    local above = e.Name
    if sub ~= "" then
        e.Sub:SetPoint("TOPLEFT", e.Name, "BOTTOMLEFT", 0, -2)
        e.Sub:SetPoint("TOPRIGHT", e.Name, "BOTTOMRIGHT", 0, -2)
        e.Sub:Show()
        h = h + 2 + (Num(e.Sub:GetStringHeight()) or 12)
        above = e.Sub
    else
        e.Sub:Hide()
    end
    e.Tag:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -2)
    e.Tag:SetPoint("TOPRIGHT", above, "BOTTOMRIGHT", 0, -2)
    h = h + 2 + (Num(e.Tag:GetStringHeight()) or 12)
    e.Text:SetHeight(h)
    b.Glow:Show()
    b.GlowAnim:Play()
    e:Show()
end

local function ClearEntry(e)
    local b = e.Button
    b:SetAttribute("type1", nil)
    b:SetAttribute("spell", nil)
    b.spellID = nil
    b.GlowAnim:Stop()
    e:Hide()
end

local function BuildPanel(sb)
    local fr, fg, fb = FontRGB()
    local p = CreateFrame("Frame", nil, _G.UIParent)
    p:Hide()
    p:EnableMouse(true)       -- Blizzard's entries below must not get the clicks
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(_, delta) Safe("wheel", BT.Page, (Num(delta) or 0) > 0 and -1 or 1) end)

    -- Nothing we draw may reach outside the panel's rect (which starts below the category tab
    -- row): the mirrored book background sits on a child frame, and the panel clips its children.
    p:SetClipsChildren(true)
    local bg = CreateFrame("Frame", nil, p)
    bg:SetAllPoints(p)
    bg:SetClipsChildren(true)
    p.bg = bg
    p.mirrors = {}
    for _, k in ipairs({ "BookBGHalved", "BookBGLeft", "BookBGRight" }) do
        p.mirrors[k] = bg:CreateTexture(nil, "BACKGROUND", nil, 1)
    end
    p.mirrors.Bookmark = bg:CreateTexture(nil, "BACKGROUND", nil, 2)
    p.corner = bg:CreateTexture(nil, "BACKGROUND", nil, 2)

    -- Header in SpellBookHeaderTemplate's look.
    local hd = CreateFrame("Frame", nil, p)
    hd:SetSize(300, HEADER_H)
    hd.Backplate = hd:CreateTexture(nil, "BACKGROUND")
    Atlas(hd.Backplate, "spellbook-list-backplate", false)
    hd.Backplate:SetSize(416, 106)
    hd.Backplate:SetPoint("LEFT", -85, 10)
    hd.Backplate:SetAlpha(0.65)
    hd.Text = hd:CreateFontString(nil, "ARTWORK")
    Font(hd.Text, "SystemFont_Huge2", "GameFontNormalHuge")
    hd.Text:SetJustifyH("LEFT")
    hd.Text:SetPoint("TOPLEFT", -8, 0)
    hd.Text:SetPoint("BOTTOMRIGHT", -60, 0)
    hd.Text:SetTextColor(fr, fg, fb)
    hd.Text:SetText(HEADER_TEXT)
    hd.Border = hd:CreateTexture(nil, "ARTWORK")
    Atlas(hd.Border, "spellbook-divider", false)
    hd.Border:SetHeight(11)
    hd.Border:SetPoint("BOTTOMLEFT", -32, 0)
    hd.Border:SetPoint("BOTTOMRIGHT", -60, 0)
    p.header = hd

    p.empty = p:CreateFontString(nil, "ARTWORK")
    Font(p.empty, "SystemFont_Large", "GameFontNormalLarge")
    p.empty:SetTextColor(fr, fg, fb)
    p.empty:SetText(EMPTY_TEXT)
    p.empty:SetPoint("CENTER")
    p.empty:Hide()

    -- Paging controls in PagingControlsHorizontalTemplate's order: text, prev, next.
    local function PageButton(dir)
        local btn = CreateFrame("Button", nil, p)
        btn:SetSize(32, 32)
        local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. (dir < 0 and "PrevPage" or "NextPage")
        btn:SetNormalTexture(base .. "-Up")
        btn:SetPushedTexture(base .. "-Down")
        btn:SetDisabledTexture(base .. "-Disabled")
        btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        btn:SetScript("OnClick", function() Safe("page", BT.Page, dir) end)
        return btn
    end
    p.next = PageButton(1)
    p.next:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -75, 40)
    p.prev = PageButton(-1)
    p.prev:SetPoint("RIGHT", p.next, "LEFT", -8, 0)
    p.pageText = p:CreateFontString(nil, "ARTWORK")
    Font(p.pageText, "SystemFont_Med3", "GameFontHighlight")
    p.pageText:SetTextColor(fr, fg, fb)
    p.pageText:SetPoint("RIGHT", p.prev, "LEFT", -8, 0)
    S.panel = p
end

-- The live view rects (Blizzard's two pages), relative to our panel; Blizzard's XML values
-- where they cannot be read.
local function ViewRects()
    local p, sb = S.panel, S.sb
    local pf = FieldOf(sb, "PagedSpellsFrame")
    local pl, pt = Num(p:GetLeft()), Num(p:GetTop())
    local views = {}
    local arr = type(pf) == "table" and FieldOf(pf, "ViewFrames") or nil
    for i = 1, 2 do
        local v = (type(arr) == "table" and arr[i]) or (type(pf) == "table" and FieldOf(pf, "View" .. i)) or nil
        if type(v) == "table" and CallOf(v, "IsShown") then
            local l, t = Num(CallOf(v, "GetLeft")), Num(CallOf(v, "GetTop"))
            local w, h = Num(CallOf(v, "GetWidth")), Num(CallOf(v, "GetHeight"))
            if pl and pt and l and t and w and h and w > 0 and h > 0 then
                views[#views + 1] = { x = l - pl, y = t - pt, w = w, h = h }
            end
        end
    end
    if #views == 0 then
        views[1] = { x = 85, y = -65, w = VIEW_W, h = VIEW_H }
        local pw = Num(p:GetWidth())
        if FieldOf(sb, "isMinimized") ~= true and pw and pw > 2 * VIEW_W then
            views[2] = { x = pw - 50 - VIEW_W, y = -65, w = VIEW_W, h = VIEW_H }
        end
    end
    return views
end

local function Layout()
    local p = S.panel
    local slots = {}
    for vi, v in ipairs(ViewRects()) do
        local top = 0
        if vi == 1 then
            p.header:ClearAllPoints()
            p.header:SetPoint("TOPLEFT", p, "TOPLEFT", v.x, v.y)
            p.header:SetWidth(v.w)
            top = HEADER_H + Y_PAD
        end
        local colW = math.floor((v.w - X_PAD * (COLS - 1)) / COLS)
        local rows = math.floor((v.h - top + Y_PAD) / (ITEM_H + Y_PAD))
        for r = 0, rows - 1 do
            for c = 0, COLS - 1 do
                slots[#slots + 1] = { x = v.x + c * (colW + X_PAD), y = v.y - top - r * (ITEM_H + Y_PAD),
                    w = math.min(colW, ITEM_W) }
            end
        end
    end
    S.slots, S.perPage = slots, #slots
    for i = #S.pool + 1, #slots do S.pool[i] = BuildEntry(p) end
    for i, e in ipairs(S.pool) do
        local s = slots[i]
        e:ClearAllPoints()
        if s then
            e:SetPoint("TOPLEFT", p, "TOPLEFT", s.x, s.y)
            e:SetWidth(s.w)
        else
            ClearEntry(e)
        end
    end
end

-- The panel's top, relative to the book's top: the paged frame's top, but below the lowest
-- category tab (Forever's icon tabs may reach into the page) and never below the first grid's top.
local function PanelTop(sb, pf)
    local dy = -50
    local st = Num(CallOf(sb, "GetTop"))
    if not st then return dy end
    local pt = type(pf) == "table" and Num(CallOf(pf, "GetTop")) or nil
    if pt then dy = pt - st end
    local ts = TabSystem(sb)
    local low = ts and Num(CallOf(ts, "GetBottom")) or nil
    for _, t in ipairs(TabList(ts)) do
        if type(t) == "table" and CallOf(t, "IsShown") then
            local b = Num(CallOf(t, "GetBottom"))
            if b and (not low or b < low) then low = b end
        end
    end
    if low and low - st - 2 < dy then dy = low - st - 2 end
    local arr = type(pf) == "table" and FieldOf(pf, "ViewFrames") or nil
    local v = (type(arr) == "table" and arr[1]) or (type(pf) == "table" and FieldOf(pf, "View1")) or nil
    local vt = type(v) == "table" and Num(CallOf(v, "GetTop")) or nil
    if vt and dy < vt - st then dy = vt - st end
    return dy
end

local function Attach()
    local p, sb = S.panel, S.sb
    p:SetParent(sb)
    p:ClearAllPoints()
    local pf = FieldOf(sb, "PagedSpellsFrame")
    p:SetPoint("TOPLEFT", sb, "TOPLEFT", 0, PanelTop(sb, pf))
    p:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
    local strata = CallOf(sb, "GetFrameStrata")
    if type(strata) == "string" then p:SetFrameStrata(strata) end
    local lvl = (Num(CallOf(type(pf) == "table" and pf or sb, "GetFrameLevel")) or 0) + 40
    p:SetFrameLevel(lvl)
    p.bg:SetFrameLevel(lvl)          -- the background under everything else of ours
    p.header:SetFrameLevel(lvl + 1)
    for k, tex in pairs(p.mirrors) do MirrorTexture(tex, FieldOf(sb, k)) end
    MirrorCorner(p.corner, FieldOf(sb, "BookCornerFlipbook"))
end

local function Detach()
    local p = S.panel
    p:Hide()
    for _, tex in pairs(p.mirrors) do tex:ClearAllPoints() end
    p.corner:ClearAllPoints()
    p:ClearAllPoints()
    p:SetParent(_G.UIParent)
end

local function Render()
    local p = S.panel
    if not (p and S.open) then return end
    if not CanChange() then S.pendingRender = true return end
    S.pendingRender = false
    if S.dirty or not S.list then Compute() end
    local list, per = S.list, S.perPage
    S.pages = math.max(1, math.ceil(#list / math.max(per, 1)))
    if S.page > S.pages then S.page = S.pages end
    if S.page < 1 then S.page = 1 end
    local base = (S.page - 1) * per
    for i, e in ipairs(S.pool) do
        local item = i <= per and list[base + i] or nil
        if item then FillEntry(e, item) else ClearEntry(e) end
    end
    p.empty:SetShown(#list == 0)
    local fmt = type(_G.PAGE_NUMBER_WITH_MAX) == "string" and _G.PAGE_NUMBER_WITH_MAX or "Page %d/%d"
    local ok, txt = pcall(string.format, fmt, S.page, S.pages)
    p.pageText:SetText(ok and txt or (S.page .. "/" .. S.pages))
    p.prev:SetEnabled(S.page > 1)
    p.next:SetEnabled(S.page < S.pages)
end

local function SafeRender() Safe("render", Render) end

-- Throttled refresh while the book is shown; events only mark the list dirty. With our panel
-- open the page is redrawn, otherwise only the list (and our tab's count badge) is recomputed.
local driver = CreateFrame("Frame")
driver:Hide()
local since = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    since = since + (Num(elapsed) or 0)
    if since < THROTTLE then return end
    since = 0
    if not S.dirty or InCombat() or not On() then return end
    if S.open then SafeRender() else Safe("count", Compute) end
end)

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------

function BT.CombatError()
    local msg = type(_G.ERR_NOT_IN_COMBAT) == "string" and _G.ERR_NOT_IN_COMBAT or "Not in combat."
    local ui = _G.UIErrorsFrame
    if type(ui) == "table" and type(ui.AddMessage) == "function" then pcall(ui.AddMessage, ui, msg, 1, 0.1, 0.1) end
end

local function OnBlizzardTab()
    if S.open then Safe("close", BT.Close) end
end

-- What's Training? (third-party): its "?" tab (WhatsTrainingLauncher) toggles its own page
-- (WhatsTrainingOverlay) over the book. A click on its tab closes our panel; opening ours turns
-- its page off with a click on its tab. Created at its PLAYER_ENTERING_WORLD, so hooked lazily.
local function HookWhatsTraining()
    if S.wtHooked then return end
    local l = _G.WhatsTrainingLauncher
    if type(l) == "table" and type(l.HookScript) == "function"
        and pcall(l.HookScript, l, "OnClick", OnBlizzardTab) then
        S.wtHooked = true
    end
end

local function CloseWhatsTraining()
    local o, l = _G.WhatsTrainingOverlay, _G.WhatsTrainingLauncher
    if type(o) == "table" and CallOf(o, "IsShown") == true and type(l) == "table" and type(l.Click) == "function" then
        pcall(l.Click, l)
    end
end

function BT.Open()
    if not (On() and S.sb and S.tab) or S.open then return end
    if InCombat() then BT.CombatError() return end
    HookWhatsTraining()
    CloseWhatsTraining() -- before S.open is set, so its click does not close ours
    if not S.panel then BuildPanel(S.sb) end
    S.open, S.pendingClose, S.page, S.dirty = true, false, 1, true
    Attach()
    S.panel:Show()
    Layout() -- after Show, so the panel's rect is resolved for ViewRects
    SetTabSelected(true)
    PlaceCatcher()
    Render()
    since = 0
    driver:Show()
    Sound("IG_SPELLBOOK_OPEN")
end

function BT.Close()
    if not S.open then return end
    local p = S.panel
    if p and p:IsShown() then
        if not CanChange() then S.pendingClose = true return end -- as it is until combat ends
        Detach()
    end
    S.open, S.pendingClose = false, false
    SetTabSelected(false)
    if S.catcher then S.catcher:Hide() end
end

function BT.Page(dir)
    if not S.open then return end
    if not CanChange() then BT.CombatError() return end
    local target = S.page + (dir or 0)
    if target < 1 or target > S.pages then return end
    S.page = target
    Sound("IG_ABILITY_PAGE_TURN")
    Render()
end

-- Settings changed (from the main file's ApplyAll): show or hide the tab.
function BT.Apply()
    if not S.tab then return end
    if On() then
        S.tab:Show()
        AnchorTab()
        S.dirty = true
    else
        BT.Close()
        S.tab:Hide()
    end
end

function BT.StatusLine()
    if On() and not InCombat() then Safe("status", Compute) end
    local D = " \194\183 "
    return string.format("missing tab: %s" .. D .. "not on bars %d" .. D .. "low rank %d" .. D .. "tab anchored %s"
        .. D .. "panel %s" .. D .. "last error: %s",
        On() and "on" or "off", S.missing, S.low,
        S.anchored and ("yes (" .. S.anchorTo .. ")") or ("no (" .. S.anchorTo .. ")"),
        S.open and ((S.pendingClose and "open, closes after combat") or ("open, page " .. S.page .. "/" .. S.pages)) or "closed",
        S.err or "none")
end

-- ---------------------------------------------------------------------------
-- Hooks and setup
-- ---------------------------------------------------------------------------

local function HookOnce(obj, method, fn)
    if type(obj) ~= "table" or type(_G.hooksecurefunc) ~= "function" then return end
    S.hooked[obj] = S.hooked[obj] or {}
    if S.hooked[obj][method] or type(obj[method]) ~= "function" then return end
    if pcall(_G.hooksecurefunc, obj, method, fn) then S.hooked[obj][method] = true end
end

local function HookBook(sb)
    sb:HookScript("OnShow", function()
        Safe("show", function()
            S.pendingClose = false
            if S.tab then
                S.tab:SetShown(On())
                AnchorTab()
            end
            S.dirty = true
            HookWhatsTraining()
            since = THROTTLE -- count at once
            driver:Show()
        end)
    end)
    sb:HookScript("OnHide", function()
        Safe("hide", BT.Close)
        driver:Hide()
    end)
    HookOnce(sb, "SetTab", OnBlizzardTab)
    HookOnce(sb, "SetMinimized", function()
        Safe("minimize", function()
            if S.open then
                if CanChange() then Attach(); Layout(); Render() else S.pendingRender = true end
            end
        end)
    end)
    local ts = TabSystem(sb)
    if ts then
        HookOnce(ts, "SetTab", OnBlizzardTab)
        -- Only our catcher follows the tab row; our tab no longer sits in or next to it.
        HookOnce(ts, "SetTabShown", function()
            if S.open then Safe("catcher", PlaceCatcher) end
        end)
    end
    local search = FieldOf(sb, "SearchBox")
    if type(search) == "table" and type(search.HookScript) == "function" then
        pcall(search.HookScript, search, "OnEditFocusGained", OnBlizzardTab)
    end
end

local function TrySetup()
    if S.sb then return true end
    local sb = BookFrame()
    if not sb then
        S.anchorTo = "PlayerSpellsFrame.SpellBookFrame not found"
        return false
    end
    S.sb = sb
    BuildTab(sb)
    HookBook(sb)
    BT.Apply()
    return true
end

local function IsLoaded(name)
    local CA = _G.C_AddOns
    local f = (type(CA) == "table" and type(CA.IsAddOnLoaded) == "function" and CA.IsAddOnLoaded)
        or (type(_G.IsAddOnLoaded) == "function" and _G.IsAddOnLoaded) or nil
    if not f then return false end
    local ok, v = pcall(f, name)
    return ok and v and true or false
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
for _, e in ipairs({ "ACTIONBAR_SLOT_CHANGED", "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB",
    "LEARNED_SPELL_IN_SKILL_LINE", "UPDATE_MACROS" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1)
    Safe(event, function()
        if event == "ADDON_LOADED" then
            if arg1 == "Blizzard_PlayerSpells" then TrySetup() end
        elseif event == "PLAYER_LOGIN" then
            if IsLoaded("Blizzard_PlayerSpells") then TrySetup() end
            BT.Apply()
        elseif event == "PLAYER_REGEN_ENABLED" then
            if S.pendingClose then
                BT.Close()
            elseif S.open then
                S.dirty = true
                Render()
            end
        else
            S.dirty = true
        end
    end)
end)
