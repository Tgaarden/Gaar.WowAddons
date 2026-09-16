--[[
  Gaar Spell Book — a custom window listing every spell you know, ported from the
  Deepward addon (WotLK 3.3.5a) to WoW Classic Era (1.15.x).

  One tab per real spellbook tab (school / skill line) plus an "All (Highest)" tab that
  combines the best-known rank of every spell, and an "All non-equip (Highest)" tab of
  spells not currently on any action bar. Each tab has a search box and four filters:
  "Highest rank only" (hides lower ranks), "Hide passives", "Hide effects" (drops internal
  "...Effect" proc spells), "Hide stances" (drops stance/form/presence spells) - all four
  default ON except "Highest rank only" is per-tab state. Hover a row for the real tooltip.

  Row actions: click = pick the spell up (like the real spellbook); Shift-click = drop it
  in the first empty action-bar slot.

  Open with the keybind (default Å, rebindable in Key Bindings -> Gaar) or /spellbook.

  Classic Era port notes vs the WotLK original: identical API (GetSpellTabInfo,
  GetSpellName/GetSpellTexture(index,"spell"), PickupSpell, GameTooltip:SetSpell,
  IsPassiveSpell, GetShapeshiftFormInfo, HasAction/GetActionTexture/PlaceAction) - Classic
  Era predates the Cataclysm PickupSpellBookItem/SetSpellBookItem rename, so it uses the
  same pre-Cata names as the WotLK client. No logic changes were needed, only renamed
  frame/global identifiers so this addon doesn't collide with the original Deepward one.
]]

local _G = _G
-- Two-column layout, big rows. Spells flow row-major (left, right, left, right, ...): item 1 top-left,
-- item 2 top-right, item 3 next row left, and so on. ROWS is the total visible across both columns;
-- ROWS/COLS is the number of visible rows (lines).
local COLS = 2
local ROWS_PER_COL = 16                  -- visible lines per column
local ROWS = COLS * ROWS_PER_COL
local ROW_H = 36           -- per-row height/stride (bigger rows)
local FRAME_W = 800        -- wide enough for two columns
local COL_W = 366          -- content width of each column
local COL_X = { 16, 16 + COL_W + 16 }   -- left x of column 1 / column 2

-- This Classic Era build has already dropped the pre-Cata globals (GetSpellName came back
-- nil at runtime), so prefer the renamed ...BookItem/...SpellBookItem APIs and only fall
-- back to the old names for safety.
local function PickupBookSpell(slot)
  if PickupSpellBookItem then PickupSpellBookItem(slot, "spell")
  elseif PickupSpell then PickupSpell(slot, "spell") end
end
local function TooltipBookSpell(slot)
  if GameTooltip.SetSpellBookItem then GameTooltip:SetSpellBookItem(slot, "spell")
  elseif GameTooltip.SetSpell then GameTooltip:SetSpell(slot, "spell") end
end
-- Returns name, rank/subtext, spellID (the id only on builds with the ...BookItem API).
local function GetBookSpellNameRank(slot)
  if GetSpellBookItemName then
    return GetSpellBookItemName(slot, "spell")
  elseif GetSpellName then
    return GetSpellName(slot, "spell")
  end
end
local function GetBookSpellTexture(slot)
  if GetSpellBookItemTexture then return GetSpellBookItemTexture(slot, "spell")
  elseif GetSpellTexture then return GetSpellTexture(slot, "spell") end
end
-- A tab's slot range also covers entries the native spellbook never draws: unlearned
-- "FUTURESPELL" slots, such as the Season of Discovery Metamorphosis rune's demon-form
-- abilities ("Metamorphosis : Demon Charge") on a warlock who hasn't got the rune. Drop
-- anything that either isn't a plain SPELL or that the player hasn't actually learned,
-- using whichever of the two APIs this build still has.
-- Set GaarSpellBookDebug = 1 (/run GaarSpellBookDebug=1, then reopen) to see what each
-- check answered for a given slot.
local function IsRealSpell(slot, name, spellID)
  local spellType
  if GetSpellBookItemInfo then
    local t, id = GetSpellBookItemInfo(slot, "spell")
    spellType = t
    spellID = spellID or id
  end
  local known
  if spellID then
    if IsSpellKnown then known = IsSpellKnown(spellID) and true or false end
    if known == false and IsSpellKnownOrOverridesKnown then
      known = IsSpellKnownOrOverridesKnown(spellID) and true or false
    end
  end
  if GaarSpellBookDebug then
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00SpellBook debug:|r slot " .. slot .. " '" ..
      tostring(name) .. "' id=" .. tostring(spellID) .. " type=" .. tostring(spellType) ..
      " known=" .. tostring(known))
  end
  if spellType and spellType ~= "SPELL" then return false end
  if known == false then return false end
  return true
end

local function Norm(s)
  local r = string.lower(s or "")
  r = string.gsub(r, "[^%w]", "")
  return r
end

local function SpellIsPassive(slot)
  if IsPassiveSpell then return IsPassiveSpell(slot, "spell") end
  return false
end

-- Names of the player's stances/forms, read from the shapeshift bar (class-agnostic: warrior
-- stances, druid forms, rogue Stealth, priest Shadowform, ...). Used to flag "stance" spells.
local function StanceNameSet()
  local s = {}
  local n = (GetNumShapeshiftForms and GetNumShapeshiftForms()) or 0
  for i = 1, n do
    local _, name = GetShapeshiftFormInfo(i)
    if name and name ~= "" then s[name] = true end
  end
  return s
end

local function BuildSpellIndex()
  local tabs = {}
  local stances = StanceNameSet()
  local numTabs = GetNumSpellTabs() or 0
  for t = 1, numTabs do
    local tabName, _, offset, numSpells = GetSpellTabInfo(t)
    local entries = {}
    if offset and numSpells then
      for i = offset + 1, offset + numSpells do
        local name, rank, spellID = GetBookSpellNameRank(i)
        if name and IsRealSpell(i, name, spellID) then
          local tex = GetBookSpellTexture(i)
          local effectlike = string.find(string.lower(name), "effect", 1, true) ~= nil
          table.insert(entries, { slot = i, name = name, rank = rank, texture = tex,
                                  passive = SpellIsPassive(i) and true or false,
                                  effectlike = effectlike,
                                  stance = stances[name] and true or false })
        end
      end
    end
    table.insert(tabs, { name = tabName or ("Tab " .. t), entries = entries })
  end
  return tabs
end

local function HighestRanksOnly(entries)
  local byName, order = {}, {}
  for _, e in ipairs(entries) do
    local key = Norm(e.name)
    if not byName[key] then table.insert(order, key) end
    local cur = byName[key]
    if not cur or e.slot > cur.slot then byName[key] = e end
  end
  local out = {}
  for _, key in ipairs(order) do table.insert(out, byName[key]) end
  return out
end

local function BuildAllHighest(tabs)
  local combined = {}
  for _, t in ipairs(tabs) do
    for _, e in ipairs(t.entries) do table.insert(combined, e) end
  end
  return HighestRanksOnly(combined)
end

local function FindEmptyActionSlot()
  for slot = 1, 120 do
    if not HasAction(slot) then return slot end
  end
  return nil
end

local READY_CHECK_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local function BuildActionTextureSet()
  local set = {}
  for slot = 1, 120 do
    local tex = GetActionTexture(slot)
    if tex then set[tex] = true end
  end
  return set
end

local function PlaceOnBar(slot, label)
  local target = FindEmptyActionSlot()
  if not target then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff6666SpellBook:|r no empty action bar slot found.")
    return
  end
  ClearCursor()
  PickupBookSpell(slot)
  PlaceAction(target)
  ClearCursor()
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SpellBook:|r added '" .. label .. "' to action bar slot " .. target .. ".")
end

-- ---------------- UI ----------------
local BASE_HEIGHT = 748
local f = CreateFrame("Frame", "GaarSpellBookFrame", UIParent, "BackdropTemplate")
f:SetWidth(FRAME_W); f:SetHeight(BASE_HEIGHT)
f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
f:SetBackdrop({
  bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
  edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
f:SetFrameStrata("HIGH")
f:SetMovable(true); f:EnableMouse(true)
f:SetScript("OnMouseDown", function(self) self:StartMoving() end)
f:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)
f:EnableMouseWheel(true)
f:Hide()
table.insert(UISpecialFrames, "GaarSpellBookFrame")

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
title:SetPoint("TOP", f, "TOP", 0, -16)
title:SetText("Spell Book")

local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)

local searchBox = CreateFrame("EditBox", "GaarSpellSearchBox", f, "InputBoxTemplate")
searchBox:SetWidth(260); searchBox:SetHeight(22); searchBox:SetAutoFocus(false)
searchBox:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -44)

local hideLower = CreateFrame("CheckButton", "GaarHideLowerRanks", f, "UICheckButtonTemplate")
hideLower:SetWidth(26); hideLower:SetHeight(26)
hideLower:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -74)
hideLower:SetChecked(true)
_G["GaarHideLowerRanksText"]:SetText("Highest rank only")
_G["GaarHideLowerRanksText"]:SetFontObject(GameFontHighlight)

local hidePassive = CreateFrame("CheckButton", "GaarHidePassives", f, "UICheckButtonTemplate")
hidePassive:SetWidth(26); hidePassive:SetHeight(26)
hidePassive:SetPoint("LEFT", _G["GaarHideLowerRanksText"], "RIGHT", 14, 0)
hidePassive:SetChecked(true)
_G["GaarHidePassivesText"]:SetText("Hide passives")
_G["GaarHidePassivesText"]:SetFontObject(GameFontHighlight)

local hideEffects = CreateFrame("CheckButton", "GaarHideEffects", f, "UICheckButtonTemplate")
hideEffects:SetWidth(26); hideEffects:SetHeight(26)
hideEffects:SetPoint("LEFT", _G["GaarHidePassivesText"], "RIGHT", 14, 0)
hideEffects:SetChecked(true)
_G["GaarHideEffectsText"]:SetText("Hide effects")
_G["GaarHideEffectsText"]:SetFontObject(GameFontHighlight)

local hideStances = CreateFrame("CheckButton", "GaarHideStances", f, "UICheckButtonTemplate")
hideStances:SetWidth(26); hideStances:SetHeight(26)
hideStances:SetPoint("LEFT", _G["GaarHideEffectsText"], "RIGHT", 14, 0)
hideStances:SetChecked(true)   -- default ON: hide stances/forms
_G["GaarHideStancesText"]:SetText("Hide stances")
_G["GaarHideStancesText"]:SetFontObject(GameFontHighlight)

local allTabsData, tabsBuilt = nil, false
local curTabIndex = 1
local offset, rows, tabButtons = 0, {}, {}

local function EnsureData()
  if not allTabsData then allTabsData = BuildSpellIndex() end
end

local RefreshList

local function CurrentEntries()
  EnsureData()
  local n = table.getn(allTabsData)
  if curTabIndex > n then
    local all = BuildAllHighest(allTabsData)
    if curTabIndex == n + 2 then
      -- "All non-equip (Highest)": only spells NOT on any action bar (no checkmark).
      local actionTex = BuildActionTextureSet()
      local out = {}
      for _, e in ipairs(all) do
        if not (e.texture and actionTex[e.texture]) then table.insert(out, e) end
      end
      return out
    end
    return all
  end
  local entries = allTabsData[curTabIndex].entries
  if hideLower:GetChecked() then entries = HighestRanksOnly(entries) end
  return entries
end

local function FilteredEntries()
  local entries = CurrentEntries()
  local dropPassive = hidePassive:GetChecked()
  local dropEffects = hideEffects:GetChecked()
  local dropStances = hideStances:GetChecked()
  local q = searchBox:GetText()
  local ql = (q and q ~= "") and string.lower(q) or nil
  if not dropPassive and not dropEffects and not dropStances and not ql then return entries end
  local out = {}
  for _, e in ipairs(entries) do
    if (not dropPassive or not e.passive)
       and (not dropEffects or not e.effectlike)
       and (not dropStances or not e.stance)
       and (not ql or string.find(string.lower(e.name), ql, 1, true)) then
      table.insert(out, e)
    end
  end
  return out
end

local TAB_ROW_Y, TAB_ROW_H = -112, 26
local TAB_PAD, TAB_MIN_W, TAB_MAX_ROW_W = 18, 44, FRAME_W - 40

local function BuildTabButtons()
  if tabsBuilt then return end
  tabsBuilt = true
  EnsureData()
  local labels = {}
  for _, t in ipairs(allTabsData) do table.insert(labels, t.name) end
  table.insert(labels, "All (Highest)")
  table.insert(labels, "All non-equip (Highest)")

  local x, row = 0, 0
  for idx, label in ipairs(labels) do
    local idx = idx
    local tb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    tb:SetHeight(24); tb:SetText(label)
    local fs = tb:GetFontString()
    local textW = (fs and fs:GetStringWidth()) or TAB_MIN_W
    local w = math.max(TAB_MIN_W, textW + TAB_PAD)
    if x > 0 and x + w > TAB_MAX_ROW_W then
      x = 0
      row = row + 1
    end
    tb:SetWidth(w)
    tb:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + x, TAB_ROW_Y - row * TAB_ROW_H)
    tb:SetScript("OnClick", function() curTabIndex = idx; offset = 0; RefreshList() end)
    table.insert(tabButtons, tb)
    x = x + w + 4
  end

  local tabRowCount = row + 1
  f:SetHeight(BASE_HEIGHT + (tabRowCount - 1) * TAB_ROW_H)
  local listTop = TAB_ROW_Y - (tabRowCount - 1) * TAB_ROW_H - TAB_ROW_H - 10
  for i, r in ipairs(rows) do
    local zi = i - 1
    local col = (zi % COLS) + 1              -- row-major: 1,2,1,2,... (left, right, left, right)
    local line = math.floor(zi / COLS)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X[col], listTop - line * ROW_H)
  end
end

RefreshList = function()
  local list = FilteredEntries()
  local total = table.getn(list)
  if offset > total - ROWS then offset = total - ROWS end
  if offset < 0 then offset = 0 end
  local actionTex = BuildActionTextureSet()
  for i = 1, ROWS do
    local row = rows[i]
    local e = list[offset + i]
    if e then
      local rankText = (e.rank and e.rank ~= "") and ("  |cff888888(" .. e.rank .. ")|r") or ""
      row.label:SetText(e.name .. rankText)
      row.icon:SetTexture(e.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.slot = e.slot
      row.ename = e.name
      if e.texture and actionTex[e.texture] then row.mark:Show() else row.mark:Hide() end
      row:Show()
    else
      row:Hide()
    end
  end
end

for i = 1, ROWS do
  local zi = i - 1
  local col = (zi % COLS) + 1               -- row-major: left, right, left, right
  local line = math.floor(zi / COLS)
  local row = CreateFrame("Button", nil, f)
  row:SetWidth(COL_W); row:SetHeight(ROW_H - 2)
  row:SetPoint("TOPLEFT", f, "TOPLEFT", COL_X[col], -140 - line * ROW_H)
  row:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight")
  row:RegisterForClicks("LeftButtonUp")
  local icon = row:CreateTexture(nil, "ARTWORK")
  icon:SetWidth(32); icon:SetHeight(32); icon:SetPoint("LEFT", 0, 0)
  row.icon = icon
  local mark = row:CreateTexture(nil, "OVERLAY")
  mark:SetTexture(READY_CHECK_TEX)
  mark:SetWidth(18); mark:SetHeight(18)
  mark:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -2)
  mark:Hide()
  row.mark = mark
  local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  label:SetFont(STANDARD_TEXT_FONT, 17)   -- a touch bigger than GameFontNormalLarge
  label:SetPoint("LEFT", icon, "RIGHT", 10, 0); label:SetWidth(COL_W - 46); label:SetJustifyH("LEFT")
  row.label = label
  row:SetScript("OnClick", function(self)
    if not self.slot then return end
    if IsShiftKeyDown() then
      PlaceOnBar(self.slot, self.ename)
    else
      ClearCursor(); PickupBookSpell(self.slot)
    end
  end)
  row:SetScript("OnEnter", function(self)
    if not self.slot then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    TooltipBookSpell(self.slot)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:Hide()
  rows[i] = row
end

searchBox:SetScript("OnTextChanged", function() offset = 0; RefreshList() end)
hideLower:SetScript("OnClick", function() offset = 0; RefreshList() end)
hidePassive:SetScript("OnClick", function() offset = 0; RefreshList() end)
hideEffects:SetScript("OnClick", function() offset = 0; RefreshList() end)
hideStances:SetScript("OnClick", function() offset = 0; RefreshList() end)

f:SetScript("OnMouseWheel", function(self, delta)
  offset = offset - delta
  RefreshList()
end)

local markTicker = CreateFrame("Frame"); markTicker:Hide()
local lastMarkRefresh = 0
markTicker:SetScript("OnUpdate", function()
  if not f:IsShown() then markTicker:Hide(); return end
  local now = GetTime()
  if now - lastMarkRefresh < 0.2 then return end
  lastMarkRefresh = now
  local actionTex = BuildActionTextureSet()
  for i = 1, ROWS do
    local row = rows[i]
    if row:IsShown() then
      local tex = row.icon:GetTexture()
      if tex and actionTex[tex] then row.mark:Show() else row.mark:Hide() end
    end
  end
end)

local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 10)
hint:SetText("|cff33ff99checkmark|r = on your action bar  |  hover = tooltip  |  click = pick up  |  Shift-click = action bar")

local function Toggle()
  if f:IsShown() then
    f:Hide()
  else
    BuildTabButtons()
    RefreshList()
    f:Show()
    markTicker:Show()
  end
end

-- Entry points: slash + a rebindable keybind (default Å).
SLASH_GAARSPELLBOOK1 = "/spellbook"
SLASH_GAARSPELLBOOK2 = "/spells"
SlashCmdList["GAARSPELLBOOK"] = Toggle

_G.GaarSpellBook_Toggle = Toggle
_G.BINDING_HEADER_GAAR = "Gaar"
_G.BINDING_NAME_GAARSPELLBOOK_TOGGLE = "Toggle Spell Book"

-- Open BOTH books from P: mirror the native spellbook (P / the spellbook microbutton) to this
-- browser. Opening the native one opens this too; closing it closes this. The Å keybind still
-- toggles this browser on its own. (Both are draggable if they overlap.)
local function OpenAlongsideNative()
  if not f:IsShown() then
    BuildTabButtons()
    RefreshList()
    f:Show()
    markTicker:Show()
  end
end
local function MirrorNativeSpellbook()
  if SpellBookFrame and SpellBookFrame:IsShown() then
    OpenAlongsideNative()
  elseif f:IsShown() then
    f:Hide()
  end
end
if SpellBookFrame then
  SpellBookFrame:HookScript("OnShow", MirrorNativeSpellbook)
  SpellBookFrame:HookScript("OnHide", MirrorNativeSpellbook)
end

local binder = CreateFrame("Frame")
binder:RegisterEvent("PLAYER_LOGIN")
binder:SetScript("OnEvent", function()
  if not GetBindingKey("GAARSPELLBOOK_TOGGLE") then
    SetBinding("Å", "GAARSPELLBOOK_TOGGLE")
    SaveBindings(GetCurrentBindingSet() or 1)
  end
end)

-- Fills `container` with this addon's controls, for the "Gaar" options entry (GaarOptions).
-- The window's own filters live on the window itself; what belongs here is the way in and
-- the diagnostics.
local optionsUID = 0
function GaarSpellBook_BuildOptions(container)
  local y = -8

  local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  head:SetPoint("TOPLEFT", 16, y); head:SetText("Spell book")
  y = y - 30

  local open = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
  open:SetSize(170, 24); open:SetPoint("TOPLEFT", 16, y)
  open:SetText("Open spell book")
  open:SetScript("OnClick", function() Toggle() end)
  y = y - 36

  optionsUID = optionsUID + 1
  local cbName = "GaarSpellBookDebugCheck" .. optionsUID
  local dbg = CreateFrame("CheckButton", cbName, container, "UICheckButtonTemplate")
  dbg:SetSize(24, 24); dbg:SetPoint("TOPLEFT", 16, y)
  dbg:SetChecked(GaarSpellBookDebug and true or false)
  local cbText = _G[cbName .. "Text"]
  cbText:SetText("Print filter diagnostics to chat"); cbText:SetFontObject(GameFontHighlight)
  dbg:SetScript("OnClick", function(self)
    GaarSpellBookDebug = self:GetChecked() and 1 or nil
    allTabsData = nil   -- rebuild the index on next open so the checks run again
  end)
  y = y - 34

  local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(340); hint:SetJustifyH("LEFT")
  hint:SetText("Filters (rank / passive / effect / stance) sit on the window itself. Opens with /spellbook, /spells or the keybind under Key Bindings -> Gaar (default \195\133).")
  y = y - 52

  container.gaarRefresh = function() dbg:SetChecked(GaarSpellBookDebug and true or false) end
  return -y
end
