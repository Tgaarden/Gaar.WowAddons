--[[
  Native spellbook enhancement, ported from Deepward (WotLK 3.3.5a) to WoW Classic Era.

  On Blizzard's built-in spellbook (SpellBookFrame):
   * a small green checkmark on any spell that is already on an action bar;
   * Shift-click a spell to drop it in the first empty action-bar slot.

  It never touches SpellButtonN's own OnClick: a transparent overlay sits on top of each
  spell button and only enables its mouse handling while Shift is held (checked on a
  0.2s tick), so normal clicks and drag-to-action-bar pass straight through unmodified.
  Which spell a button is = matched by ICON TEXTURE against an index of every spellbook
  slot (highest slot = highest rank on ties); "on an action bar" is the same icon-texture
  match across all 120 action slots. Player tabs only (not the pet book).

  Classic Era port notes vs WotLK: identical API (PickupSpell, GetSpellTabInfo,
  GetSpellTexture) - Classic Era predates the Cataclysm PickupSpellBookItem rename, same
  as WotLK. 12 spell buttons per page, same as the WotLK spellbook layout.
]]

local _, ns = ...
local _G = _G
local READY_CHECK_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local NUM_SPELL_BUTTONS = 12   -- Classic Era spellbook: SpellButton1..12 per page

-- This Classic Era build has already dropped the pre-Cata globals (confirmed at runtime:
-- GetSpellName is nil), so prefer the renamed ...BookItem APIs, falling back to the old
-- names only for safety.
local function PickupBookSpell(slot)
  ns.PickupSpell(slot)
end
local function GetBookSpellTexture(slot)
  return ns.SpellTexture(slot)
end
-- Skip unlearned "FUTURESPELL" slots (e.g. the Metamorphosis rune's demon-form ability
-- replacements) so a shared icon doesn't get matched to a slot that isn't a real,
-- pickable spell.
local function IsRealSpell(slot)
  local spellID
  do
    local spellType, id = ns.SpellInfo(slot)
    if spellType and spellType ~= "SPELL" then return false end
    spellID = id
  end
  if not spellID then
    local _, _, id = ns.SpellName(slot)
    spellID = id
  end
  if spellID and IsSpellKnown and not IsSpellKnown(spellID) then
    if not (IsSpellKnownOrOverridesKnown and IsSpellKnownOrOverridesKnown(spellID)) then
      return false
    end
  end
  return true
end

local function BuildSpellTextureIndex()
  local texToSlots = {}
  local numTabs = ns.NumSpellTabs()
  for tab = 1, numTabs do
    local _, offset, numSpells = ns.SpellTabInfo(tab)
    if offset and numSpells then
      for i = offset + 1, offset + numSpells do
        local tex = IsRealSpell(i) and GetBookSpellTexture(i) or nil
        if tex then
          texToSlots[tex] = texToSlots[tex] or {}
          table.insert(texToSlots[tex], i)
        end
      end
    end
  end
  return texToSlots
end

local function BuildActionTextureSet()
  local set = {}
  for slot = 1, 120 do
    local tex = GetActionTexture(slot)
    if tex then set[tex] = true end
  end
  return set
end

-- The icon is reliably the largest texture region of the button; try the standard
-- $parentIcon/$parentIconTexture names first, else pick the biggest texture region.
local function GetButtonTexture(btn, name)
  for _, suffix in ipairs({ "IconTexture", "Icon" }) do
    local namedTex = _G[name .. suffix]
    if namedTex and namedTex.GetTexture then
      local t = namedTex:GetTexture()
      if t then return t end
    end
  end
  local regions = { btn:GetRegions() }
  local bestTex, bestArea = nil, 0
  for _, r in ipairs(regions) do
    if r.GetObjectType and r:GetObjectType() == "Texture" and r.GetTexture then
      local t = r:GetTexture()
      if t then
        local w, h = r:GetWidth() or 0, r:GetHeight() or 0
        local area = w * h
        if area > bestArea then bestTex, bestArea = t, area end
      end
    end
  end
  return bestTex
end

-- The button's icon texture, but ONLY if the icon is actually shown with a texture.
-- Empty spellbook slots hide/clear their icon, so this returns nil for them -> no mark
-- (the fallback-largest-region heuristic below would wrongly return slot art for empties).
local function ButtonSpellTexture(name)
  for _, suffix in ipairs({ "IconTexture", "Icon" }) do
    local icon = _G[name .. suffix]
    if icon and icon.IsShown and icon:IsShown() and icon.GetTexture then
      local t = icon:GetTexture()
      if t then return t end
    end
  end
  return nil
end

local function FindEmptyActionSlot()
  for slot = 1, 120 do
    if not HasAction(slot) then return slot end
  end
  return nil
end

local function PlaceSpellFromButton(btn, name)
  local tex = GetButtonTexture(btn, name)
  if not tex then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff6666SpellBook:|r couldn't identify that spell's icon.")
    return
  end
  local candidates = BuildSpellTextureIndex()[tex]
  if not candidates or table.getn(candidates) == 0 then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff6666SpellBook:|r couldn't match that spell to a spellbook slot.")
    return
  end
  local slot = candidates[1]
  for _, c in ipairs(candidates) do if c > slot then slot = c end end   -- prefer highest rank
  local target = FindEmptyActionSlot()
  if not target then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff6666SpellBook:|r no empty action bar slot found.")
    return
  end
  ClearCursor()
  PickupBookSpell(slot)
  PlaceAction(target)
  ClearCursor()
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SpellBook:|r added to action bar slot " .. target .. ".")
end

local ensured, hooked = {}, {}

local function EnsureHook(i)
  if ensured[i] then return end
  local name = "SpellButton" .. i
  local btn = _G[name]
  if not btn then return end
  ensured[i] = true

  local overlay = CreateFrame("Button", name .. "GaarOverlay", btn)
  overlay:SetAllPoints(btn)
  overlay:EnableMouse(false)   -- only enabled while Shift is held (tick below)
  overlay:SetScript("OnClick", function()
    PlaceSpellFromButton(btn, name)
  end)

  local mark = btn:CreateTexture(nil, "OVERLAY")
  mark:SetTexture(READY_CHECK_TEX)
  mark:SetWidth(14); mark:SetHeight(14)
  mark:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 2, -2)
  mark:Hide()

  hooked[i] = { overlay = overlay, mark = mark, name = name, btn = btn }
end

local ticker = CreateFrame("Frame"); ticker:Hide()
local lastRefresh = 0
ticker:SetScript("OnUpdate", function()
  if not (SpellBookFrame and SpellBookFrame:IsShown()) then return end
  local now = GetTime()
  if now - lastRefresh < 0.2 then return end
  lastRefresh = now

  for i = 1, NUM_SPELL_BUTTONS do EnsureHook(i) end

  local grab = IsShiftKeyDown()
  local actionTex = BuildActionTextureSet()

  for _, h in pairs(hooked) do
    if h.btn:IsShown() then
      h.overlay:EnableMouse(grab)
      -- strict: only the shown spell icon (empty slots -> nil -> no mark),
      -- not GetButtonTexture's largest-region fallback which caught empty slots.
      local tex = ButtonSpellTexture(h.name)
      if tex and actionTex[tex] then h.mark:Show() else h.mark:Hide() end
    else
      h.mark:Hide()
    end
  end
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function() ticker:Show() end)
