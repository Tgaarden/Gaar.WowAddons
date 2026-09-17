--[[
  Gaar Bags — one-bag window in the OneBag3 mould, for WoW Classic Era.
  Grown out of the Deepward Bags port (WotLK 3.3.5a).

  Layout and behaviour follow OneBag3's design:
    * Every bag in one frame, as a continuous grid: the carried bags, the keyring, and the
      bank and its bags while the bank frame is open.
    * A bag bar behind a toggle: one button per bag. Hovering highlights that bag's slots,
      clicking locks the highlight, right-clicking hides that bag, and dropping a bag on a
      button swaps it in.
    * Slots colour-coded by bag, by bag type (quiver, soul bag, herb bag, ...) or off, with
      item rarity on the slot border.
    * Search with a small query language: space-separated terms are ANDed, "or" gives
      alternatives, "not"/"!" negates, and q/quality, ilvl, type and sub take =, >, <, >=, <=.
    * Bags can be hidden one slot at a time or by whole type.
    * Footer with the free-slot count and money. Resizes both ways, but never smaller than the
      grid needs - slots are never hidden, the window grows instead.
    * Customisable columns, scale, background colour and alpha.
    * Opens and closes itself at the merchant, bank, mailbox, auction house and on trades.
    * Sort uses the client's own bag sorting when present, with the original stack-and-pack
      cleanup as the fallback.

  /gaarbags (or /gbags). Settings under Gaar -> Bags.

  Classic Era notes: the container API lives in C_Container and GetContainerItemInfo returns a
  TABLE rather than a list of values - reading it the old way yields nil silently - so all
  container access goes through the shims below. Cooldowns use cd:SetCooldown, backdrops need
  the "BackdropTemplate" mixin, and SetMinResize/SetMaxResize became SetResizeBounds.
]]

local _G = _G
local SIZE = 32          -- slot pitch; the button itself is SIZE-2, leaving a 2px gutter
local FLAT = "Interface\\Buttons\\WHITE8x8"

local KEYRING = _G.KEYRING_CONTAINER or -2
local BANK = _G.BANK_CONTAINER or -1
local NUM_BANK_BAGS = _G.NUM_BANKBAGSLOTS or 7

local carried = { 0, 1, 2, 3, 4 }   -- backpack + the four equipped bags
local bankOpen = false

-- Which containers the window is showing right now: the carried bags, the keyring when the
-- character has one, and the bank while its frame is open.
local BAGS = { 0, 1, 2, 3, 4 }
local function RebuildBagList()
    local t = {}
    for _, b in ipairs(carried) do t[#t + 1] = b end
    local cc = _G.C_Container
    local keySlots = (cc and cc.GetContainerNumSlots and cc.GetContainerNumSlots(KEYRING))
        or (_G.GetContainerNumSlots and GetContainerNumSlots(KEYRING)) or 0
    if keySlots > 0 then t[#t + 1] = KEYRING end
    if bankOpen then
        t[#t + 1] = BANK
        for i = 1, NUM_BANK_BAGS do t[#t + 1] = 4 + i end   -- bank bags are 5..11
    end
    BAGS = t
    return t
end

local function DB()
    if type(GaarBagsDB) ~= "table" then GaarBagsDB = {} end
    local d = GaarBagsDB
    if d.sort == nil then d.sort = "quality" end     -- quality | name (fallback cleanup order)
    if d.override == nil then d.override = true end
    if d.scale == nil then d.scale = 1 end
    if d.columns == nil then d.columns = 12 end      -- 0 = follow the window width
    if d.tint == nil then d.tint = "bagtype" end     -- bag | bagtype | off
    if d.bgColor == nil then d.bgColor = { 0, 0, 0 } end
    if d.bgAlpha == nil then d.bgAlpha = 0.85 end
    if d.hidden == nil then d.hidden = {} end        -- [bag] = true when that bag is hidden
    if d.hiddenFam == nil then d.hiddenFam = {} end  -- [bag family] = true to hide every bag of that type
    if d.autoOpen == nil then d.autoOpen = true end
    if d.showBagBar == nil then d.showBagBar = false end   -- the per-bag buttons are tucked away by default
    if d.useBlizzSort == nil then d.useBlizzSort = true end
    if d.footerFont == nil then d.footerFont = 11 end   -- money and free-slot text
    if d.chars == nil then d.chars = {} end          -- ["Name - Realm"] = that character's snapshot
    if d.altTooltips == nil then d.altTooltips = true end
    if d.pawnArrows == nil then d.pawnArrows = true end   -- upgrade arrows, when Pawn is loaded
    return d
end

-- ---------------------------------------------------------------------------
-- Container API shims (C_Container here, plain globals on older clients)
-- ---------------------------------------------------------------------------
local CC = _G.C_Container

local function NumSlots(bag)
    if CC and CC.GetContainerNumSlots then return CC.GetContainerNumSlots(bag) or 0 end
    return (GetContainerNumSlots and GetContainerNumSlots(bag)) or 0
end

-- icon, count, locked, quality, link, itemID
local function ItemInfo(bag, slot)
    if CC and CC.GetContainerItemInfo then
        local i = CC.GetContainerItemInfo(bag, slot)
        if not i then return nil end
        return i.iconFileID, i.stackCount, i.isLocked, i.quality, i.hyperlink, i.itemID
    end
    if GetContainerItemInfo then
        local tex, count, locked, quality, _, _, link = GetContainerItemInfo(bag, slot)
        if not tex then return nil end
        return tex, count, locked, quality, link, nil
    end
end

local function ItemLink(bag, slot)
    if CC and CC.GetContainerItemLink then return CC.GetContainerItemLink(bag, slot) end
    return GetContainerItemLink and GetContainerItemLink(bag, slot)
end

local function ItemCooldown(bag, slot)
    if CC and CC.GetContainerItemCooldown then return CC.GetContainerItemCooldown(bag, slot) end
    if GetContainerItemCooldown then return GetContainerItemCooldown(bag, slot) end
end

local function PickupItem(bag, slot)
    if CC and CC.PickupContainerItem then return CC.PickupContainerItem(bag, slot) end
    if PickupContainerItem then return PickupContainerItem(bag, slot) end
end

-- free slots, bag family
local function FreeSlots(bag)
    if CC and CC.GetContainerNumFreeSlots then return CC.GetContainerNumFreeSlots(bag) end
    if GetContainerNumFreeSlots then return GetContainerNumFreeSlots(bag) end
    return 0, 0
end

local function InventoryIDFor(bag)
    if CC and CC.ContainerIDToInventoryID then return CC.ContainerIDToInventoryID(bag) end
    if ContainerIDToInventoryID then return ContainerIDToInventoryID(bag) end
end

-- The modern call hands back a table; the old one returned plain values.
-- Returns: is this quest-related at all, and does it start a quest you have not picked up.
-- The two are different things, and Blizzard's own bag draws them differently: the "!" means
-- "right-click this to begin a quest", while an item that is merely an objective of a quest
-- gets a border and no bang. Treating every quest-related item as a bang put exclamation
-- marks on ordinary quest meat and made the symbol meaningless.
local function QuestInfo(bag, slot)
    local isQuest, questID, isActive
    if CC and CC.GetContainerItemQuestInfo then
        local q = CC.GetContainerItemQuestInfo(bag, slot)
        if type(q) == "table" then
            isQuest, questID, isActive = q.isQuestItem, q.questID, q.isActive
        else
            isQuest = q
        end
    elseif GetContainerItemQuestInfo then
        isQuest, questID, isActive = GetContainerItemQuestInfo(bag, slot)
    end
    local related = (isQuest or questID) and true or false
    local starts = (questID ~= nil and not isActive) and true or false
    return related, starts
end

-- Declared up here because the Pawn bridge and the snapshot driver below both reach for them
-- before the sections that own them appear. A local used above its declaration silently
-- resolves as a global, which is nil at runtime.
local bagButtons = {}
local snapDirty = false
local function MarkDirty() snapDirty = true end

-- ---------------------------------------------------------------------------
-- Pawn bridge
--
-- Optional: if Pawn is loaded, its own verdict decides which slots get an upgrade arrow,
-- rather than this addon inventing a second opinion about stat weights. Pawn answers per
-- item link with true, false, or nil - nil meaning "I don't have the stats yet, ask again".
-- That third case is why the cache below never stores a nil: caching it would freeze a
-- "not an upgrade" answer that was really just "not loaded yet".
-- ---------------------------------------------------------------------------
local pawnCache = {}
local pawnReady = false

local function PawnSaysUpgrade(link)
    if not DB().pawnArrows or not link or not pawnReady then return false end
    -- PawnIsInitialized is file-local inside Pawn, so _G.PawnIsInitialized is always nil and
    -- gating on it silently disables every arrow. PawnCommon is one of Pawn's saved variables,
    -- so that one really is global and tells us Pawn is loaded.
    if not _G.PawnCommon then return false end
    local fn = _G.PawnShouldItemLinkHaveUpgradeArrowUnbudgeted
    if type(fn) ~= "function" then return false end
    local cached = pawnCache[link]
    if cached ~= nil then return cached end
    -- Pawn answers nil while it still lacks stats for the item. Neither that nor an outright
    -- error is cached, so the arrow appears on a later refresh once Pawn knows.
    local ok, result = pcall(fn, link, true)
    if not ok or result == nil then return false end
    pawnCache[link] = result and true or false
    return pawnCache[link]
end

-- What counts as an upgrade depends on what you are wearing, so the verdicts are thrown away
-- whenever your gear changes.
local pawnEv = CreateFrame("Frame")
pcall(pawnEv.RegisterEvent, pawnEv, "PLAYER_EQUIPMENT_CHANGED")
pcall(pawnEv.RegisterEvent, pawnEv, "PLAYER_ENTERING_WORLD")
pawnEv:SetScript("OnEvent", function(_, event)
    -- Pawn finishes its own setup around this event; asking any earlier trips its internal
    -- "not initialized" guard.
    if event == "PLAYER_ENTERING_WORLD" then pawnReady = true end
    pawnCache = {}
    MarkDirty()   -- also the first point where the bags reliably read back
end)

-- ---------------------------------------------------------------------------
-- Per-character cache
--
-- The client only hands over the bags of whoever is logged in, so each character writes a
-- snapshot of its own while it is played and every character reads the whole account back out
-- of the shared saved variable. The bank is kept apart from the carried bags: its containers
-- are only readable while the bank frame is open, so that half of a snapshot goes stale on its
-- own schedule and carries its own timestamp rather than borrowing the bags' one.
-- ---------------------------------------------------------------------------
local ME, REALM, MY_CLASS, charKey = nil, nil, nil, nil

local function CharDB() return DB().chars end

local function Identify()
    ME = UnitName("player")
    REALM = (GetRealmName and GetRealmName()) or "?"
    local _, class = UnitClass("player")
    MY_CLASS = class
    if ME then charKey = ME .. " - " .. REALM end
end

-- Only the link and the stack size are stored. Everything else about an item - name, quality,
-- type - is resolved from the link when it is displayed, because GetItemInfo returns nil for
-- anything the client hasn't cached yet and a nil frozen into saved data never heals.
local function ScanInto(list, bags)
    for _, bag in ipairs(bags) do
        local n = NumSlots(bag)
        for slot = 1, n do
            local link = ItemLink(bag, slot)
            if link then
                local _, count = ItemInfo(bag, slot)
                list[#list + 1] = { link = link, count = count or 1 }
            end
        end
    end
end

local function Snapshot()
    if not charKey then return end
    local rec = CharDB()[charKey]

    local bags = {}
    for _, b in ipairs(carried) do bags[#bags + 1] = b end
    if NumSlots(KEYRING) > 0 then bags[#bags + 1] = KEYRING end

    local free, total = 0, 0
    for _, b in ipairs(bags) do
        free = free + (FreeSlots(b) or 0)
        total = total + NumSlots(b)
    end

    -- Around login and logout the containers briefly report nothing, which is
    -- indistinguishable from a character with no bags. Bail out before touching a single
    -- field: `rec` is the stored table itself, so anything written above this point would
    -- stick even though the pass is abandoned - which is how a logout pass managed to zero
    -- the money while leaving the bag contents intact.
    if total == 0 and rec and rec.total and rec.total > 0 then return end

    rec = rec or {}
    rec.name, rec.realm, rec.class = ME, REALM, MY_CLASS
    rec.updated = time()
    rec.money = GetMoney()
    rec.free, rec.total = free, total

    local items = {}
    ScanInto(items, bags)
    rec.items = items

    if bankOpen then
        local bankBags = { BANK }
        for i = 1, NUM_BANK_BAGS do bankBags[#bankBags + 1] = 4 + i end
        -- An unreadable bank and a genuinely empty one both scan to nothing, and writing that
        -- would wipe a good snapshot with an empty one. The slot count tells them apart: no
        -- slots means the containers have stopped answering, so the last good bank is kept.
        local slots = 0
        for _, b in ipairs(bankBags) do slots = slots + NumSlots(b) end
        if slots > 0 then
            local bank = {}
            ScanInto(bank, bankBags)
            rec.bank = bank
            rec.bankUpdated = time()
        end
    end

    CharDB()[charKey] = rec
end

-- BAG_UPDATE fires once per bag per loot, so the scan is deferred to a flag the driver below
-- drains about once a second rather than run on every event.
-- Blizzard's own bag bar, so an upgrade sitting in a bag is visible without opening anything.
-- CharacterBag0Slot is bag 1, not bag 0 - the backpack has its own button.
local BAG_BAR_BUTTON = {
    [0] = "MainMenuBarBackpackButton",
    [1] = "CharacterBag0Slot",
    [2] = "CharacterBag1Slot",
    [3] = "CharacterBag2Slot",
    [4] = "CharacterBag3Slot",
}

local function BagArrow(btn)
    if not btn._gaarUpArrow then
        local up = btn:CreateTexture(nil, "OVERLAY")
        up:SetTexture("Interface\\Buttons\\UI-MicroStream-Green")
        up:SetTexCoord(0, 1, 1, 0)          -- the texture points down
        up:SetSize(18, 18)
        up:SetPoint("TOPRIGHT", 2, 2)
        btn._gaarUpArrow = up
    end
    return btn._gaarUpArrow
end

local function BagHasUpgrade(bag)
    for slot = 1, NumSlots(bag) do
        local link = ItemLink(bag, slot)
        if link and PawnSaysUpgrade(link) then return true end
    end
    return false
end

local function UpdateBagBarArrows()
    for bag, name in pairs(BAG_BAR_BUTTON) do
        local btn = _G[name]
        if btn then
            local show = DB().pawnArrows and BagHasUpgrade(bag)
            if show then BagArrow(btn):Show()
            elseif btn._gaarUpArrow then btn._gaarUpArrow:Hide() end
        end
    end
    -- and the matching buttons on our own in-window bar
    for bag, btn in pairs(bagButtons) do
        if bag >= 0 and bag <= 4 then
            local show = DB().pawnArrows and BagHasUpgrade(bag)
            if show then BagArrow(btn):Show()
            elseif btn._gaarUpArrow then btn._gaarUpArrow:Hide() end
        end
    end
end

local snapDriver = CreateFrame("Frame")
local snapAcc = 0
snapDriver:SetScript("OnUpdate", function(_, elapsed)
    if not snapDirty then return end
    snapAcc = snapAcc + elapsed
    if snapAcc < 1 then return end
    snapAcc = 0
    snapDirty = false
    Snapshot()
    UpdateBagBarArrows()
end)

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
    return "|cffcccccc"
end

-- Items are matched by the name in the link, so the same item with different enchants, random
-- suffixes or charges still counts as one thing.
local function ItemName(link)
    return link and string.match(link, "%[(.-)%]") or nil
end

local function CountIn(list, name)
    local n = 0
    for _, e in ipairs(list or {}) do
        if ItemName(e.link) == name then n = n + (e.count or 1) end
    end
    return n
end

-- Every cached character except the one being played, with what they hold of this item.
-- Every character holding the item, the current one included. Leaving yourself out made the
-- common case - an item only you carry - show nothing at all, which reads as broken rather
-- than as "nobody else has this".
local function Holders(name)
    local out = {}
    for key, rec in pairs(CharDB()) do
        local bags, bank = CountIn(rec.items, name), CountIn(rec.bank, name)
        if bags > 0 or bank > 0 then
            out[#out + 1] = { name = rec.name or key, class = rec.class,
                              bags = bags, bank = bank, isMe = (key == charKey) }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- ---------------------------------------------------------------------------
-- Tooltip lines
-- ---------------------------------------------------------------------------
-- GetItem went away on the tooltips that were rebuilt around TooltipUtil, and TooltipUtil does
-- not exist on the ones that kept GetItem, so both are tried and neither is assumed.
local function TooltipLink(tt)
    if tt.GetItem then
        local _, link = tt:GetItem()
        if link then return link end
    end
    local tu = _G.TooltipUtil
    if tu and tu.GetDisplayedItem then
        local _, link = tu.GetDisplayedItem(tt)
        return link
    end
end

local function AddAltLines(tt)
    if not DB().altTooltips then return end
    local link = TooltipLink(tt)
    local name = ItemName(link)
    -- OnTooltipSetItem can fire more than once for a single display; OnTooltipCleared below
    -- releases the guard when the tooltip is actually rebuilt.
    if not name or tt.gaarAltItem == name then return end
    tt.gaarAltItem = name
    local holders = Holders(name)
    if #holders == 0 then return end
    local total = 0
    tt:AddLine(" ")
    for _, h in ipairs(holders) do
        local parts = {}
        if h.bags > 0 then parts[#parts + 1] = string.format("%d carried", h.bags) end
        if h.bank > 0 then parts[#parts + 1] = string.format("%d bank", h.bank) end
        total = total + h.bags + h.bank
        tt:AddDoubleLine(ClassColor(h.class) .. h.name .. (h.isMe and "  |cff666666(here)|r" or "") .. "|r",
            "|cffaaaaaa" .. table.concat(parts, ", ") .. "|r")
    end
    if #holders > 1 then
        tt:AddDoubleLine("|cffffd100Total|r", "|cffffffff" .. total .. "|r")
    end
    tt:Show()   -- the tooltip does not grow to fit lines added after it was sized
end

-- OnTooltipSetItem no longer exists on retail: tooltip content moved behind
-- TooltipDataProcessor, and hooking a script a frame does not have is refused outright rather
-- than ignored. HasScript is the honest test for that, and the processor is the replacement.
local function HookTooltip(script, fn)
    if GameTooltip.HasScript and not GameTooltip:HasScript(script) then return false end
    GameTooltip:HookScript(script, fn)
    return true
end

HookTooltip("OnTooltipCleared", function(tt) tt.gaarAltItem = nil end)

local TDP = _G.TooltipDataProcessor
if TDP and TDP.AddTooltipPostCall and _G.Enum and _G.Enum.TooltipDataType then
    TDP.AddTooltipPostCall(_G.Enum.TooltipDataType.Item, function(tt) pcall(AddAltLines, tt) end)
else
    HookTooltip("OnTooltipSetItem", function(tt) pcall(AddAltLines, tt) end)
end

-- Pull a colour toward its own luminance, so the rarity edges read muted instead of neon.
local function Mute(r, g, b, amount)
    local lum = 0.3 * r + 0.59 * g + 0.11 * b
    local m = amount or 0.45
    return r + (lum - r) * m, g + (lum - g) * m, b + (lum - b) * m
end

-- Quest items get warm gold, the one hue the quality palette leaves free: grey, white, green,
-- blue, purple and orange are all spoken for, and this is pale enough not to read as
-- legendary. The corner marker below carries the real signal, though - colour alone is
-- rarity's job in this UI.
local QUEST_EDGE = { 0.90, 0.80, 0.42 }

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------
-- One tint per bag index, used by the "bag" colouring mode.
local BAG_TINT = {
    [0] = { 0.35, 0.35, 0.40 },
    [1] = { 0.30, 0.45, 0.65 },
    [2] = { 0.30, 0.55, 0.40 },
    [3] = { 0.60, 0.45, 0.25 },
    [4] = { 0.50, 0.35, 0.55 },
}
-- Bag families (quiver, soul bag, profession bags, ...) for the "bag type" mode.
local FAMILY_TINT = {
    [0]    = { 0.35, 0.35, 0.40 },   -- ordinary bag
    [1]    = { 0.60, 0.45, 0.25 },   -- quiver
    [2]    = { 0.60, 0.50, 0.30 },   -- ammo pouch
    [4]    = { 0.50, 0.30, 0.60 },   -- soul bag
    [8]    = { 0.55, 0.35, 0.25 },   -- leatherworking
    [16]   = { 0.40, 0.40, 0.65 },   -- inscription
    [32]   = { 0.25, 0.55, 0.30 },   -- herbs
    [64]   = { 0.30, 0.55, 0.60 },   -- enchanting
    [128]  = { 0.50, 0.50, 0.35 },   -- engineering
    [512]  = { 0.60, 0.30, 0.45 },   -- gems
    [1024] = { 0.45, 0.40, 0.35 },   -- mining
}

local bagFamily = {}
local function RefreshFamilies()
    for _, bag in ipairs(BAGS) do
        local _, fam = FreeSlots(bag)
        bagFamily[bag] = fam or 0
    end
end
local function FamilyOf(bag) return bagFamily[bag] or 0 end

local KEYRING_TINT = { 0.62, 0.55, 0.25 }
local BANK_TINT = { 0.28, 0.42, 0.58 }

local function SlotTint(bag)
    local mode = DB().tint
    if mode == "off" then return nil end
    if bag == KEYRING then return KEYRING_TINT end
    if bag == BANK or bag > 4 then return BANK_TINT end
    if mode == "bag" then return BAG_TINT[bag] or BAG_TINT[0] end
    local fam = bagFamily[bag] or 0
    return FAMILY_TINT[fam] or FAMILY_TINT[0]
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
local f = CreateFrame("Frame", "GaarBagsFrame", UIParent, "BackdropTemplate")
f:SetFrameStrata("HIGH"); f:SetMovable(true); f:EnableMouse(true)
-- Flat dark panel with a thin light edge, rather than Blizzard's ornate dialog frame.
f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 } })
f:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
f:SetPoint("CENTER"); f:Hide()
table.insert(UISpecialFrames, "GaarBagsFrame")

local function ApplyBackdropColor()
    local c = DB().bgColor
    f:SetBackdropColor(c[1], c[2], c[3], DB().bgAlpha)
end

-- A small square icon button in the header's style: flat dark tile, thin edge, hover lift.
local function HeaderButton(parent, size)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(size, size)
    b:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
    b:SetBackdropColor(0.13, 0.14, 0.17, 1)
    b:SetBackdropBorderColor(0.32, 0.34, 0.39, 1)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 2, -2); b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    b:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.9, 0.75, 0.3, 1)
        if self.tip then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(self.tip())
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.32, 0.34, 0.39, 1)
        GameTooltip:Hide()
    end)
    return b
end

-- Left of the title: folds the per-bag buttons in and out.
local barBtn = HeaderButton(f, 20)
barBtn:SetPoint("TOPLEFT", 8, -8)
barBtn.icon:SetTexture("Interface\\Buttons\\UI-MicroStream-Green")
barBtn.tip = function() return DB().showBagBar and "Hide the bag buttons" or "Show the bag buttons" end

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("LEFT", barBtn, "RIGHT", 8, 0)
title:SetText("Gaar Bags")
title:SetTextColor(0.95, 0.95, 0.95)

-- Right of the header: settings, then clean-up.
-- Settings sits bottom-left, out of the way of the things you click constantly.
local cfgBtn = HeaderButton(f, 20)
cfgBtn:SetPoint("BOTTOMLEFT", 10, 8)
cfgBtn.icon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
cfgBtn.tip = function() return "Settings" end

local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
closeBtn:SetSize(26, 26)
closeBtn:SetPoint("TOPRIGHT", -4, -4)

local sortBtn = HeaderButton(f, 20)
sortBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -2, -3)
sortBtn.tip = function() return "Clean up bags" end
-- The broom icon path this client ships is not INV_Misc_Broom_01 - it came out blank - so the
-- sort glyph is drawn from three stepped bars instead. Nothing to look up, nothing to miss.
sortBtn.icon:Hide()
sortBtn.bars = {}
for i = 1, 3 do
    local bar = sortBtn:CreateTexture(nil, "ARTWORK")
    if bar.SetColorTexture then bar:SetColorTexture(1, 1, 1, 1) else bar:SetTexture(1, 1, 1, 1) end
    bar:SetVertexColor(0.85, 0.85, 0.88, 1)
    bar:SetHeight(2)
    bar:SetWidth(12 - (i - 1) * 3)
    bar:SetPoint("TOPLEFT", sortBtn, "TOPLEFT", 4, -(4 + (i - 1) * 4))
    sortBtn.bars[i] = bar
end

-- Slim flat search field, spanning the width just under the grid and above the money row.
local searchBox = CreateFrame("EditBox", "GaarBagsSearch", f, "BackdropTemplate")
searchBox:SetAutoFocus(false)
searchBox:SetHeight(18)
searchBox:SetPoint("BOTTOMLEFT", 10, 30)
searchBox:SetPoint("BOTTOMRIGHT", -10, 30)
searchBox:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
searchBox:SetBackdropColor(0.10, 0.11, 0.13, 1)
searchBox:SetBackdropBorderColor(0.30, 0.32, 0.37, 1)
searchBox:SetFont(STANDARD_TEXT_FONT, 11, "")
searchBox:SetTextInsets(6, 6, 0, 0)
searchBox:SetTextColor(0.9, 0.9, 0.9)

-- drag bar covers the title row, clear of the buttons and the search field
local dragBar = CreateFrame("Frame", nil, f)
dragBar:SetPoint("TOPLEFT", barBtn, "TOPRIGHT", 2, 0)
dragBar:SetPoint("TOPRIGHT", sortBtn, "TOPLEFT", -4, 0)
dragBar:SetHeight(22)
dragBar:EnableMouse(true); dragBar:RegisterForDrag("LeftButton")
dragBar:SetScript("OnDragStart", function() f:StartMoving() end)
dragBar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

-- Footer: free slots on the left, money on the right.
local slotsText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
slotsText:SetPoint("BOTTOMLEFT", 62, 10)   -- clear of the settings and characters buttons
slotsText:SetJustifyH("LEFT")

local moneyText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
moneyText:SetPoint("BOTTOMRIGHT", -10, 10)
moneyText:SetJustifyH("RIGHT")

-- The coin icons in GetCoinTextureString scale with the font, so this drives both.
-- A FontString can't take mouse events, so an invisible button sits on top of the money text
-- to carry the hover.
local moneyHover = CreateFrame("Button", nil, f)
moneyHover:SetPoint("TOPLEFT", moneyText, "TOPLEFT", -4, 2)
moneyHover:SetPoint("BOTTOMRIGHT", moneyText, "BOTTOMRIGHT", 4, -2)
moneyHover:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
    GameTooltip:AddLine("Gold across the account")
    local rows, total = {}, 0
    for key, rec in pairs(DB().chars or {}) do
        rows[#rows + 1] = { name = rec.name or key, class = rec.class,
                            money = rec.money or 0, updated = rec.updated }
        total = total + (rec.money or 0)
    end
    table.sort(rows, function(a, b) return a.money > b.money end)
    if #rows == 0 then
        GameTooltip:AddLine("Nothing recorded yet.", 0.6, 0.6, 0.6)
    else
        for _, r in ipairs(rows) do
            GameTooltip:AddDoubleLine(ClassColor(r.class) .. r.name .. "|r",
                GetCoinTextureString(r.money))
        end
        if #rows > 1 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("|cffffd100Total|r", GetCoinTextureString(total))
        end
    end
    GameTooltip:Show()
end)
moneyHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function ApplyFooterFont()
    local s = DB().footerFont
    slotsText:SetFont(STANDARD_TEXT_FONT, s, "")
    moneyText:SetFont(STANDARD_TEXT_FONT, s, "")
end
ApplyFooterFont()

-- Per-bag parent frames carry the bag id so the secure item template resolves bag+slot itself.
-- Built on demand, since the keyring and the bank bags only join the list later.
local bagParents = {}
local function BagParent(bag)
    local p = bagParents[bag]
    if not p then
        p = CreateFrame("Frame", "GaarBagsBag" .. (bag < 0 and ("m" .. -bag) or bag), f)
        p:SetID(bag); p:SetAllPoints(f)
        bagParents[bag] = p
    end
    return p
end

-- Bag families, for the "hide this kind of bag" filter and the slot tinting.
local FAMILY_NAME = {
    [0] = "Ordinary", [1] = "Quiver", [2] = "Ammo", [4] = "Soul", [8] = "Leatherworking",
    [16] = "Inscription", [32] = "Herbs", [64] = "Enchanting", [128] = "Engineering",
    [512] = "Gems", [1024] = "Mining",
}

-- A bag is out of the grid if you hid that slot, or hid its whole type.
local function Hidden(bag)
    if DB().hidden[bag] then return true end
    if bag == KEYRING or bag == BANK then return false end
    local fam = FamilyOf(bag)
    return DB().hiddenFam[fam] and true or false
end

local RefreshList

-- ---------------------------------------------------------------------------
-- Bag bar
-- ---------------------------------------------------------------------------
local highlightBag = nil      -- bag whose slots are highlighted right now
local lockedBag = nil         -- highlight pinned by a click

local function SetHighlight(bag)
    highlightBag = bag
    RefreshList()
end

local function BagLabel(bag)
    if bag == 0 then return "Backpack" end
    if bag == KEYRING then return "Keyring" end
    if bag == BANK then return "Bank" end
    if bag > 4 then return "Bank bag " .. (bag - 4) end
    local fam = FamilyOf(bag)
    local name = FAMILY_NAME[fam]
    return "Bag " .. bag .. ((name and fam ~= 0) and (" (" .. name .. ")") or "")
end

-- Dropping a bag on one of these swaps it into that slot, the way the default bag bar works.
local function PutBagHere(bag)
    if bag == 0 or bag == KEYRING or bag == BANK then return end
    local inv = InventoryIDFor(bag)
    if inv and PutItemInBag then PutItemInBag(inv) end
end

local function MakeBagButton(bag)
    local b = CreateFrame("Button", "GaarBagsBar" .. (bag < 0 and ("m" .. -bag) or bag), f)
    b:SetSize(26, 26)
    b.bag = bag
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(); b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.border = CreateFrame("Frame", nil, b, "BackdropTemplate")
    b.border:SetPoint("TOPLEFT", -1, 1); b.border:SetPoint("BOTTOMRIGHT", 1, -1)
    b.border:SetBackdrop({ edgeFile = FLAT, edgeSize = 1 })
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnEnter", function(self)
        if not lockedBag then SetHighlight(self.bag) end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local free, total = FreeSlots(self.bag), NumSlots(self.bag)
        GameTooltip:AddLine(BagLabel(self.bag))
        GameTooltip:AddLine(string.format("%d/%d free", free or 0, total or 0), 1, 1, 1)
        GameTooltip:AddLine("Click keeps the highlight, right-click hides this bag.", 0.6, 0.6, 0.6)
        if self.bag > 0 and self.bag <= 4 then
            GameTooltip:AddLine("Drop a bag here to swap it in.", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        if not lockedBag then SetHighlight(nil) end
        GameTooltip:Hide()
    end)
    b:SetScript("OnReceiveDrag", function(self) PutBagHere(self.bag); RefreshList() end)
    b:SetScript("OnDragStart", function(self)
        local inv = InventoryIDFor(self.bag)
        if self.bag > 0 and self.bag <= 4 and inv and PickupBagFromSlot then PickupBagFromSlot(inv) end
    end)
    b:SetScript("OnClick", function(self, button)
        -- carrying an item? then this is a bag swap, not a highlight toggle
        if GetCursorInfo() and self.bag > 0 and self.bag <= 4 then
            PutBagHere(self.bag); RefreshList(); return
        end
        if button == "RightButton" then
            DB().hidden[self.bag] = (not DB().hidden[self.bag]) or nil
        else
            lockedBag = (lockedBag == self.bag) and nil or self.bag
            SetHighlight(lockedBag)
        end
        RefreshList()
    end)
    bagButtons[bag] = b
    return b
end

-- Rebuilt on demand: the keyring and the bank bags come and go.
local function BuildBagBar()
    local x = 10
    for _, bag in ipairs(BAGS) do
        local b = bagButtons[bag] or MakeBagButton(bag)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -32)
        x = x + 30
    end
end

local function UpdateBagBar()
    local show = DB().showBagBar
    for _, bag in ipairs(BAGS) do
        local b = bagButtons[bag]
        if b then
            if show then b:Show() else b:Hide() end
            local tex
            if bag == 0 then
                tex = "Interface\\Buttons\\Button-Backpack-Up"
            elseif bag == KEYRING then
                tex = "Interface\\ContainerFrame\\KeyRing-Bag-Icon"
            elseif bag == BANK then
                tex = "Interface\\Icons\\INV_Misc_Coin_01"
            else
                local inv = InventoryIDFor(bag)
                tex = inv and GetInventoryItemTexture("player", inv)
            end
            b.icon:SetTexture(tex or "Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag")
            local hidden = Hidden(bag)
            b.icon:SetDesaturated(hidden and true or false)
            b:SetAlpha(hidden and 0.4 or 1)
            local t = SlotTint(bag)
            if lockedBag == bag then
                b.border:SetBackdropBorderColor(1, 0.85, 0.2, 1)
            elseif t then
                b.border:SetBackdropBorderColor(t[1], t[2], t[3], 1)
            else
                b.border:SetBackdropBorderColor(0, 0, 0, 1)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Slots
-- ---------------------------------------------------------------------------
local buttons = {}
local function GetButton(bag, slot)
    local key = bag .. ":" .. slot
    local b = buttons[key]
    if not b then
        b = CreateFrame("Button", "GaarBagsBtn" .. (bag < 0 and ("m" .. -bag) or bag) .. "_" .. slot,
            BagParent(bag), "ContainerFrameItemButtonTemplate")
        b:SetID(slot)
        b:SetSize(SIZE - 2, SIZE - 2)

        -- Which field holds the template's icon differs by client - icon on Era, Icon on
        -- retail, and neither where the template has changed again. Getting this wrong is not
        -- cosmetic: the sweep below wipes every texture that is not the icon, so failing to
        -- find it means stripping it, and every slot comes out blank.
        local ic = b.icon or b.Icon or _G[b:GetName() .. "IconTexture"]
        if not ic then
            ic = b:CreateTexture(nil, "ARTWORK")
            ic:SetAllPoints()
        end
        b._icon = ic

        -- Strip every decorative texture the template ships with. Hiding them by field name
        -- (b.IconBorder and friends) missed the blue outline entirely - this client's template
        -- creates those regions without Lua fields, so the field was simply nil. Sweeping the
        -- regions catches them whatever they are called. The icon is spared; the stack count is
        -- a FontString and the cooldown is a child frame, so neither is touched.
        for _, r in ipairs({ b:GetRegions() }) do
            if r ~= ic and r.GetObjectType and r:GetObjectType() == "Texture" then
                r:SetTexture(nil)
                r:SetAlpha(0)
            end
        end
        local nt = b:GetNormalTexture()
        if nt then nt:SetTexture(nil); nt:SetAlpha(0) end

        -- The stack count is drawn here rather than through SetItemButtonCount. That helper
        -- reaches for a field on the button whose name differs between clients - on retail it
        -- found nothing and indexed nil - and this addon already draws its own fill, tint and
        -- rarity edge, so one more region of its own is cheaper than a template dependency
        -- that has to be right on every flavour.
        local templateCount = b.Count or _G[b:GetName() .. "Count"]
        if templateCount and templateCount.Hide then templateCount:Hide() end
        -- NumberFontNormal is what SetItemButtonCount used, so taking the same font object
        -- keeps Era looking exactly as it did before this stopped going through Blizzard.
        local cnt = b:CreateFontString(nil, "OVERLAY", _G.NumberFontNormal and "NumberFontNormal" or nil)
        if not _G.NumberFontNormal then cnt:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE") end
        cnt:SetPoint("BOTTOMRIGHT", -2, 2)
        cnt:SetJustifyH("RIGHT")
        b._count = cnt

        local fill = b:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        if fill.SetColorTexture then fill:SetColorTexture(1, 1, 1, 1) else fill:SetTexture(1, 1, 1, 1) end
        fill:SetVertexColor(0.11, 0.12, 0.15, 1)
        b._fill = fill
        b._tint = fill        -- the bag tint just recolours the tile

        local edge = CreateFrame("Frame", nil, b, "BackdropTemplate")
        edge:SetAllPoints()
        edge:SetFrameLevel(b:GetFrameLevel())
        edge:SetBackdrop({ edgeFile = FLAT, edgeSize = 1 })
        edge:SetBackdropBorderColor(0.28, 0.30, 0.35, 1)
        b._edge = edge

        -- crop the icon's own dark border so it sits flush inside the tile
        local ic = b._icon
        if ic then
            ic:ClearAllPoints()
            ic:SetPoint("TOPLEFT", 1, -1); ic:SetPoint("BOTTOMRIGHT", -1, 1)
            ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end

        b:SetHighlightTexture(FLAT, "ADD")
        local hl = b:GetHighlightTexture()
        if hl then hl:SetVertexColor(1, 1, 1, 0.12) end

        buttons[key] = b
    end
    return b
end

-- ---------------------------------------------------------------------------
-- Search
--
-- A small query language in the spirit of OneBag3's LibItemSearch, written here rather than
-- pulled in: terms separated by spaces are ANDed, "or" splits alternatives, "not"/"!" negates,
-- and the fields q/quality, ilvl, type and sub take =, >, <, >= and <= comparisons. Anything
-- else is plain text matched against the item's name, type and subtype.
--   cloth or leather        herb not grey        q>=3 sub:sword        ilvl>20 potion
-- ---------------------------------------------------------------------------
local search = ""
local query = nil        -- { orGroups = { { {field, op, value}, ... }, ... } }

local QUALITY_WORDS = {
    poor = 0, grey = 0, gray = 0, common = 1, white = 1, uncommon = 2, green = 2,
    rare = 3, blue = 3, epic = 4, purple = 4, legendary = 5, orange = 5,
}

local function ParseTerm(word)
    local neg = false
    if string.sub(word, 1, 1) == "!" then neg = true; word = string.sub(word, 2) end
    if word == "" then return nil end
    local field, op, value = string.match(word, "^(%a+)(>=)(.+)$")
    if not field then field, op, value = string.match(word, "^(%a+)(<=)(.+)$") end
    if not field then field, op, value = string.match(word, "^(%a+)([><=:])(.+)$") end
    if field then
        field = string.lower(field)
        if field == "quality" then field = "q" end
        if field == "q" or field == "ilvl" then
            value = tonumber(value) or QUALITY_WORDS[string.lower(value)]
            if not value then return nil end
        else
            value = string.lower(value)
        end
        return { field = field, op = (op == ":" and "=" or op), value = value, neg = neg }
    end
    local q = QUALITY_WORDS[word]
    if q then return { field = "q", op = "=", value = q, neg = neg } end
    return { field = "text", op = "=", value = word, neg = neg }
end

local function ParseQuery(text)
    text = string.lower(text or "")
    if text == "" then return nil end
    local groups, current, pendingNot = {}, {}, false
    for word in string.gmatch(text, "%S+") do
        if word == "or" then
            if #current > 0 then groups[#groups + 1] = current end
            current, pendingNot = {}, false
        elseif word == "not" then
            pendingNot = true
        else
            local t = ParseTerm(word)
            if t then
                if pendingNot then t.neg = not t.neg; pendingNot = false end
                current[#current + 1] = t
            end
        end
    end
    if #current > 0 then groups[#groups + 1] = current end
    if #groups == 0 then return nil end
    return groups
end

local function Compare(actual, op, want)
    if actual == nil then return false end
    if op == ">" then return actual > want end
    if op == "<" then return actual < want end
    if op == ">=" then return actual >= want end
    if op == "<=" then return actual <= want end
    return actual == want
end

local function TermMatches(t, it)
    local ok
    if t.field == "q" then
        ok = Compare(it.quality, t.op, t.value)
    elseif t.field == "ilvl" then
        ok = Compare(it.ilvl, t.op, t.value)
    elseif t.field == "type" then
        ok = it.type ~= nil and string.find(it.type, t.value, 1, true) ~= nil
    elseif t.field == "sub" then
        ok = it.sub ~= nil and string.find(it.sub, t.value, 1, true) ~= nil
    else
        ok = (it.name and string.find(it.name, t.value, 1, true) ~= nil)
            or (it.type and string.find(it.type, t.value, 1, true) ~= nil)
            or (it.sub and string.find(it.sub, t.value, 1, true) ~= nil)
    end
    if t.neg then return not ok end
    return ok
end

local function Matches(link, quality)
    if not query then return true end
    if not link then return false end
    local name, _, _, ilvl, _, itype, sub = GetItemInfo(link)
    local it = {
        name = name and string.lower(name) or string.lower(string.match(link, "%[(.-)%]") or ""),
        type = itype and string.lower(itype) or nil,
        sub = sub and string.lower(sub) or nil,
        ilvl = ilvl, quality = quality,
    }
    for _, group in ipairs(query) do
        local all = true
        for _, t in ipairs(group) do
            if not TermMatches(t, it) then all = false; break end
        end
        if all then return true end
    end
    return false
end

local function UpdateButton(bag, slot)
    local b = GetButton(bag, slot)
    local tex, count, locked, quality, link = ItemInfo(bag, slot)
    -- Set directly, for the same reason the count is: SetItemButtonTexture and
    -- SetItemButtonDesaturated both reach for template fields whose names differ by client.
    if b._icon then
        b._icon:SetTexture(tex)
        b._icon:SetDesaturated(locked and true or false)
        b._icon:SetAlpha(tex and 1 or 0)
    end
    if b._count then
        b._count:SetText((count and count > 1) and tostring(count) or "")
    end

    -- Rarity edge, drawn ourselves. SetItemButtonQuality would light the template's IconBorder,
    -- which is the blue outline that showed up on every slot, empty ones included.
    if not b._qf then
        local qf = CreateFrame("Frame", nil, b, "BackdropTemplate")
        qf:SetFrameLevel(b:GetFrameLevel() + 2)
        qf:SetAllPoints()
        qf:SetBackdrop({ edgeFile = FLAT, edgeSize = 2 })
        b._qf = qf
    end
    -- Blizzard's own quest marker, which the region sweep took off with everything else.
    -- Redrawn here so quest items are flagged by a symbol, not only by an edge colour.
    -- Pawn's upgrade arrow. UI-MicroStream-Green points down, so it is flipped vertically
    -- rather than depending on an icon path that may not exist on this client.
    if tex and PawnSaysUpgrade(link) then
        if not b._upArrow then
            local up = b:CreateTexture(nil, "OVERLAY")
            up:SetTexture("Interface\\Buttons\\UI-MicroStream-Green")
            up:SetTexCoord(0, 1, 1, 0)
            up:SetSize(18, 18)
            up:SetPoint("TOPRIGHT", -1, -1)
            b._upArrow = up
        end
        b._upArrow:Show()
    elseif b._upArrow then
        b._upArrow:Hide()
    end

    local isQuest, startsQuest = false, false
    if tex then isQuest, startsQuest = QuestInfo(bag, slot) end
    if startsQuest then
        if not b._questMark then
            local q = b:CreateTexture(nil, "OVERLAY")
            q:SetTexture("Interface\\ContainerFrame\\UI-Icon-QuestBang")
            q:SetSize(12, 14)
            q:SetPoint("TOPLEFT", 1, -1)
            b._questMark = q
        end
        b._questMark:Show()
    elseif b._questMark then
        b._questMark:Hide()
    end

    if isQuest then
        b._qf:SetBackdropBorderColor(QUEST_EDGE[1], QUEST_EDGE[2], QUEST_EDGE[3], 0.9)
        b._qf:Show()
    elseif tex and quality and quality >= 2 then
        -- GetItemQualityColor returns r, g, b AND a hex string; expanding it straight into
        -- Mute() put that string in the blend argument.
        local qr, qg, qb = GetItemQualityColor(quality)
        local r, g, bl = Mute(qr, qg, qb)
        b._qf:SetBackdropBorderColor(r, g, bl, 0.85)
        b._qf:Show()
    else
        b._qf:Hide()
    end

    -- The tile itself carries the bag tint: a dark base, nudged toward the bag's colour.
    local tint = SlotTint(bag)
    if tint then
        b._fill:SetVertexColor(0.11 + tint[1] * 0.22, 0.12 + tint[2] * 0.22, 0.15 + tint[3] * 0.22, 1)
    else
        b._fill:SetVertexColor(0.11, 0.12, 0.15, 1)
    end

    -- highlight the hovered/locked bag, dim anything the search filters out
    local a = 1
    if highlightBag and bag ~= highlightBag then a = 0.35 end
    if not Matches(link, quality) then a = 0.2 end
    b:SetAlpha(a)

    local start, dur, en = ItemCooldown(bag, slot)
    local cd = _G[b:GetName() .. "Cooldown"]
    if cd and start then
        if en == nil or en ~= 0 then cd:SetCooldown(start, dur) else cd:SetCooldown(0, 0) end
    end
end

-- How much of the window the header and footer take, so the grid knows its own box.
local function ChromeTop() return DB().showBagBar and 62 or 34 end
local BOTTOM_CHROME = 56   -- money row plus the search field above it

local function Layout()
    local slots = {}
    for _, bag in ipairs(BAGS) do
        if not Hidden(bag) then
            local n = NumSlots(bag)
            for slot = 1, n do slots[#slots + 1] = { bag = bag, slot = slot } end
        end
    end

    local cols = DB().columns
    if cols == 0 then cols = math.max(4, math.floor((f:GetWidth() - 20) / SIZE)) end

    for _, b in pairs(buttons) do b:Hide() end

    local top = -ChromeTop()
    local totalRows = math.max(1, math.ceil(#slots / cols))

    -- Every slot is always drawn. The window is free to be taller than it needs, but never
    -- shorter: a bag window that hides slots is worse than one that takes up more screen.
    for i, s in ipairs(slots) do
        local b = GetButton(s.bag, s.slot)
        local idx = i - 1
        local col = idx % cols
        local row = math.floor(idx / cols)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 10 + col * SIZE, top - row * SIZE)
        b:Show()
    end

    if DB().columns > 0 then f:SetWidth(DB().columns * SIZE + 20) end

    -- Grow to fit whenever the contents need more room than the frame has. Skipped mid-drag,
    -- where fighting the cursor over the height would make the grip feel stuck.
    local needed = ChromeTop() + totalRows * SIZE + BOTTOM_CHROME
    if not f.gaarResizing and f:GetHeight() < needed then
        f:SetHeight(needed)
    end
    f.gaarNeededHeight = needed
end

-- Grow the window so every slot is on screen at once.
local function FitHeight()
    local count = 0
    for _, bag in ipairs(BAGS) do
        if not Hidden(bag) then count = count + NumSlots(bag) end
    end
    local cols = DB().columns
    if cols == 0 then cols = math.max(4, math.floor((f:GetWidth() - 20) / SIZE)) end
    local rows = math.max(1, math.ceil(count / cols))
    f:SetHeight(ChromeTop() + rows * SIZE + BOTTOM_CHROME)
end

RefreshList = function()
    if not f:IsShown() then return end
    RebuildBagList()      -- the keyring and the bank bags come and go
    RefreshFamilies()
    BuildBagBar()
    for _, bag in ipairs(BAGS) do
        if not Hidden(bag) then
            local n = NumSlots(bag)
            for slot = 1, n do UpdateButton(bag, slot) end
        end
    end
    Layout()
    UpdateBagBar()

    local free, total = 0, 0
    for _, bag in ipairs(BAGS) do
        free = free + (FreeSlots(bag) or 0)
        total = total + NumSlots(bag)
    end
    slotsText:SetText(string.format("|cffaaaaaa%d/%d free|r", free, total))
    moneyText:SetText(GetCoinTextureString(GetMoney()))
end
_G.GaarBags_Refresh = RefreshList

-- ---------------------------------------------------------------------------
-- All characters
--
-- The reading half of the per-character cache: every character on the account, with what it was
-- carrying when it last wrote a snapshot. Runs off the same search box as the grid, so narrowing
-- one narrows the other.
-- ---------------------------------------------------------------------------
local altFrame, altFS, altScroll = nil, {}, 0

local function Stamp(t) return date("%d.%m %H:%M", t or 0) end

local function AltLines()
    local out = {}
    local keys = {}
    for key in pairs(CharDB()) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local rec = CharDB()[key]
        local byName, order = {}, {}
        local function collect(list, field)
            for _, e in ipairs(list or {}) do
                local nm = ItemName(e.link)
                -- quality is not stored, so quality terms in the query simply never match here
                if nm and Matches(e.link, nil) then
                    local it = byName[nm]
                    if not it then
                        it = { name = nm, link = e.link, bags = 0, bank = 0 }
                        byName[nm] = it
                        order[#order + 1] = it
                    end
                    it[field] = it[field] + (e.count or 1)
                end
            end
        end
        collect(rec.items, "bags")
        collect(rec.bank, "bank")
        table.sort(order, function(a, b) return a.name < b.name end)

        out[#out + 1] = { text = string.format("%s%s|r  |cffaaaaaa%d/%d free|r  %s  |cff888888%s|r",
            ClassColor(rec.class), rec.name or key, rec.free or 0, rec.total or 0,
            GetCoinTextureString(rec.money or 0), Stamp(rec.updated)), header = true }
        -- The bank is only readable with its frame open, so it is almost always older than the
        -- bags around it and says so rather than passing for current.
        if rec.bankUpdated then
            out[#out + 1] = { text = string.format("    |cff888888bank as of %s|r", Stamp(rec.bankUpdated)) }
        end
        for _, it in ipairs(order) do
            local counts = {}
            if it.bags > 0 then counts[#counts + 1] = "|cffffd100x" .. it.bags .. "|r" end
            if it.bank > 0 then counts[#counts + 1] = "|cff888888" .. it.bank .. " bank|r" end
            out[#out + 1] = { text = "    " .. it.link .. "  " .. table.concat(counts, "  ") }
        end
    end
    if #out == 0 then
        out[1] = { text = "|cff888888No characters cached yet - log in on one and its bags land here.|r" }
    end
    return out
end

local function AltRefresh()
    if not altFrame or not altFrame:IsShown() then return end
    local lines = AltLines()
    local visible = math.max(1, math.floor((altFrame:GetHeight() - 48) / 14))
    if altScroll > math.max(0, #lines - visible) then altScroll = math.max(0, #lines - visible) end
    if altScroll < 0 then altScroll = 0 end
    for i = 1, visible do
        local fs = altFS[i]
        if not fs then
            fs = altFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("TOPLEFT", 12, -36 - (i - 1) * 14)
            fs:SetPoint("RIGHT", altFrame, "RIGHT", -12, 0)
            fs:SetJustifyH("LEFT")
            altFS[i] = fs
        end
        local e = lines[altScroll + i]
        fs:SetText(e and e.text or "")
        fs:Show()
    end
    for i = visible + 1, #altFS do altFS[i]:Hide() end
end

local function BuildAltWindow()
    if altFrame then return altFrame end
    altFrame = CreateFrame("Frame", "GaarBagsCharsFrame", UIParent, "BackdropTemplate")
    altFrame:SetSize(520, 400); altFrame:SetPoint("CENTER")
    altFrame:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    altFrame:SetBackdropColor(0.05, 0.06, 0.08, 0.94)
    altFrame:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    altFrame:SetFrameStrata("DIALOG")
    altFrame:SetMovable(true); altFrame:EnableMouse(true); altFrame:SetResizable(true)
    if altFrame.SetResizeBounds then altFrame:SetResizeBounds(360, 200, 900, 800)
    elseif altFrame.SetMinResize then
        altFrame:SetMinResize(360, 200); altFrame:SetMaxResize(900, 800)
    end
    altFrame:RegisterForDrag("LeftButton")
    altFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    altFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); AltRefresh() end)
    table.insert(UISpecialFrames, "GaarBagsCharsFrame")

    local head = altFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 12, -12); head:SetText("All characters")

    local close = CreateFrame("Button", nil, altFrame, "UIPanelButtonTemplate")
    close:SetSize(60, 20); close:SetPoint("TOPRIGHT", -12, -10); close:SetText("Close")
    close:SetScript("OnClick", function() altFrame:Hide() end)

    altFrame:EnableMouseWheel(true)
    altFrame:SetScript("OnMouseWheel", function(_, dir) altScroll = altScroll - dir * 3; AltRefresh() end)
    altFrame:SetScript("OnSizeChanged", function() AltRefresh() end)

    local altGrip = CreateFrame("Button", nil, altFrame)
    altGrip:SetSize(16, 16); altGrip:SetPoint("BOTTOMRIGHT", -2, 2)
    altGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    altGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    altGrip:SetScript("OnMouseDown", function() altFrame:StartSizing("BOTTOMRIGHT") end)
    altGrip:SetScript("OnMouseUp", function() altFrame:StopMovingOrSizing(); AltRefresh() end)

    altFrame:Hide()
    return altFrame
end

local function ToggleAlt()
    local w = BuildAltWindow()
    if w:IsShown() then w:Hide() else Snapshot(); w:Show(); AltRefresh() end
end

-- Header button, left of the clean-up button. The glyph is drawn rather than loaded: icon paths
-- have come back blank on this client, and four tiles read as "several characters" well enough.
local altBtn = HeaderButton(f, 20)
altBtn:SetPoint("BOTTOMLEFT", cfgBtn, "BOTTOMRIGHT", 4, 0)
altBtn.tip = function() return "What every character is carrying" end
altBtn.icon:Hide()
altBtn.tiles = {}
for i = 1, 4 do
    local tile = altBtn:CreateTexture(nil, "ARTWORK")
    if tile.SetColorTexture then tile:SetColorTexture(1, 1, 1, 1) else tile:SetTexture(1, 1, 1, 1) end
    tile:SetVertexColor(0.85, 0.85, 0.88, 1)
    tile:SetSize(5, 5)
    tile:SetPoint("TOPLEFT", altBtn, "TOPLEFT", 4 + ((i - 1) % 2) * 7, -(4 + math.floor((i - 1) / 2) * 7))
    altBtn.tiles[i] = tile
end
altBtn:SetScript("OnClick", ToggleAlt)
dragBar:SetPoint("TOPRIGHT", sortBtn, "TOPLEFT", -4, 0)

searchBox:SetScript("OnTextChanged", function(self)
    search = self:GetText() or ""
    query = ParseQuery(search)
    RefreshList()
    AltRefresh()
end)
searchBox:SetScript("OnEscapePressed", function(self)
    self:SetText(""); self:ClearFocus(); query = nil; RefreshList(); AltRefresh()
end)

-- ---------------------------------------------------------------------------
-- Cleanup: merge partial stacks, then pack to the front. One move per frame so the item locks
-- resolve between steps; out of combat only. Used when the client has no bag sorting of its own.
-- ---------------------------------------------------------------------------
local function itemAt(bag, slot)
    local link = ItemLink(bag, slot)
    if not link then return nil end
    local _, count, locked, quality = ItemInfo(bag, slot)
    local id = tonumber(string.match(link, "item:(%d+)"))
    local _, _, _, _, _, _, _, maxStack = GetItemInfo(link)
    return { link = link, id = id, count = count or 1, quality = quality or 1,
             locked = locked, max = maxStack or 1, name = (string.match(link, "%[(.-)%]") or "") }
end

local function orderSlots()
    local t = {}
    for _, bag in ipairs(BAGS) do
        local n = NumSlots(bag)
        for slot = 1, n do t[#t + 1] = { bag = bag, slot = slot } end
    end
    return t
end

local function cmpQuality(a, b)
    if a.quality ~= b.quality then return a.quality > b.quality end
    if a.name ~= b.name then return a.name < b.name end
    return a.count > b.count
end
local function cmpName(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.quality > b.quality
end
local activeCmp = cmpQuality

local function stackStep(order)
    local firstPartial = {}
    for _, p in ipairs(order) do
        local it = itemAt(p.bag, p.slot)
        if it and it.id and it.max > 1 and it.count < it.max and not it.locked then
            local prev = firstPartial[it.id]
            if prev then
                ClearCursor()
                PickupItem(p.bag, p.slot)
                PickupItem(prev.bag, prev.slot)   -- fills prev toward max, remainder back on the cursor
                ClearCursor()                     -- returns any remainder to its source
                return true
            end
            firstPartial[it.id] = p
        end
    end
    return false
end

local function sortStep(order)
    local items = {}
    for _, p in ipairs(order) do
        local it = itemAt(p.bag, p.slot)
        if it then it.bag, it.slot = p.bag, p.slot; items[#items + 1] = it end
    end
    table.sort(items, activeCmp)
    for i, p in ipairs(order) do
        local want = items[i]
        if not want then return false end
        local cur = itemAt(p.bag, p.slot)
        if not (cur and cur.link == want.link and cur.count == want.count) then
            for j = i, #order do
                local q = order[j]
                local it = itemAt(q.bag, q.slot)
                if it and it.link == want.link and it.count == want.count then
                    if q.bag == p.bag and q.slot == p.slot then break end
                    if it.locked or (cur and cur.locked) then return true end   -- wait a frame
                    ClearCursor()
                    PickupItem(q.bag, q.slot)
                    PickupItem(p.bag, p.slot)
                    if GetCursorInfo() then PickupItem(q.bag, q.slot) end
                    ClearCursor()
                    return true
                end
            end
        end
    end
    return false
end

local cleanDriver = CreateFrame("Frame"); cleanDriver:Hide()
local cleanPhase, cleanTicks = nil, 0
-- One step per frame rebuilt the whole slot list every frame, which on a full retail bag is
-- heavy enough to look like the client has locked up. A step every 0.05s is still far faster
-- than the moves themselves complete.
local cleanAcc = 0
local cleanLast, cleanRepeats = nil, 0

cleanDriver:SetScript("OnUpdate", function(self, elapsed)
    if InCombatLockdown() then self:Hide(); cleanPhase = nil; return end
    cleanAcc = cleanAcc + (elapsed or 0)
    if cleanAcc < 0.05 then return end
    cleanAcc = 0
    cleanTicks = cleanTicks + 1
    if cleanTicks > 400 then self:Hide(); cleanPhase = nil; RefreshList(); return end   -- safety stop
    local order = orderSlots()
    if cleanPhase == "stack" then
        -- A move that is refused leaves the bags exactly as they were, so the same pair is
        -- picked again on the next pass and the phase never ends. Watching for the same
        -- decision twice over catches that in a few frames instead of four hundred.
        local before = #order
        if not stackStep(order) then cleanPhase = "sort"; cleanRepeats = 0; cleanLast = nil
        else
            if cleanLast == before then
                cleanRepeats = cleanRepeats + 1
                if cleanRepeats > 20 then cleanPhase = "sort"; cleanRepeats = 0 end
            else
                cleanRepeats = 0
            end
            cleanLast = before
        end
        return
    end
    if not sortStep(order) then
        self:Hide(); cleanPhase = nil; RefreshList()
    end
end)

local function OwnCleanup()
    if cleanDriver:IsShown() then return end
    if InCombatLockdown() then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff6666Gaar Bags:|r can't tidy the bags in combat.")
        return
    end
    activeCmp = (DB().sort == "name") and cmpName or cmpQuality
    cleanTicks = 0; cleanPhase = "stack"; cleanDriver:Show()
end

-- Blizzard's own sort is preferred where it is trustworthy, but not on retail. There it took
-- the client down twice from this button, and the likely reason is this addon itself: it hides
-- Blizzard's container frames and hooks the functions that open them, while the sort moves
-- items through those very frames. Without a crash log there is no proving it, and a feature
-- that can kill the client is not something to keep trying in place.
--
-- Our own cleanup is bounded - it steps on a timer, stops when it stops making progress, and
-- refuses to start in combat - so it is the safe one to reach for while the other is unknown.
-- Classic Era has issecretvalue as well, so that is not the question - the question is whether
-- this is the client whose sort took us down, and the project id answers it directly.
local function IsMainline()
    return _G.WOW_PROJECT_ID ~= nil and _G.WOW_PROJECT_ID == _G.WOW_PROJECT_MAINLINE
end
local warnedSort = false

local function DoSort()
    if IsMainline() then
        if not warnedSort then
            warnedSort = true
            DEFAULT_CHAT_FRAME:AddMessage("|cff5599ffGaar Bags:|r using its own tidy here - Blizzard's sort crashes this client from an addon button.")
        end
        OwnCleanup()
        return
    end
    if DB().useBlizzSort and CC and CC.SortBags then
        CC.SortBags()
    elseif DB().useBlizzSort and _G.SortBags then
        SortBags()
    else
        OwnCleanup()
    end
end

-- HeaderButton already wires OnEnter/OnLeave from each button's own .tip function.
sortBtn:SetScript("OnClick", DoSort)

barBtn:SetScript("OnClick", function()
    DB().showBagBar = not DB().showBagBar
    if not DB().showBagBar then lockedBag = nil; highlightBag = nil end
    RefreshList()
end)

cfgBtn:SetScript("OnClick", function()
    if not (_G.GaarOptions_Open and _G.GaarOptions_Open("bags")) then
        DEFAULT_CHAT_FRAME:AddMessage("|cff5599ffGaar Bags:|r settings live under Gaar -> Bags in the AddOns options.")
    end
end)

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local function Show() f:Show(); RefreshList() end
local function Hide() f:Hide() end
local function Toggle() if f:IsShown() then Hide() else Show() end end
_G.GaarBags_Toggle = Toggle
_G.GaarBags_Show = Show
_G.GaarBags_Hide = Hide

local autoOpened = false
local ev = CreateFrame("Frame")
local EVENTS = {
    "BAG_UPDATE", "ITEM_LOCK_CHANGED", "BAG_UPDATE_COOLDOWN", "PLAYER_MONEY",
    "PLAYER_LOGIN", "PLAYER_LOGOUT",
    "MERCHANT_SHOW", "MERCHANT_CLOSED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
    "MAIL_SHOW", "MAIL_CLOSED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
    "TRADE_SHOW", "TRADE_CLOSED",
    "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED",
}
for _, e in ipairs(EVENTS) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        ApplyBackdropColor(); ApplyFooterFont(); f:SetScale(DB().scale or 1)
        title:SetText((UnitName("player") or "Gaar") .. "'s Bags")
        Identify()
        MarkDirty()
        return
    end
    if event == "PLAYER_LOGOUT" then
        Snapshot()    -- nothing ticks after this, so the deferred scan would never run
        return
    end
    if event == "BANKFRAME_OPENED" then
        -- the bank's own containers are only readable while its frame is open
        bankOpen = true
        RebuildBagList()
        if DB().autoOpen and not f:IsShown() then autoOpened = true; Show() else RefreshList() end
        return
    end
    if event == "BANKFRAME_CLOSED" then
        Snapshot()        -- last chance at the bank containers before they stop reading
        bankOpen = false
        RebuildBagList()
        if DB().autoOpen and autoOpened then autoOpened = false; Hide() else RefreshList() end
        return
    end
    if event == "MERCHANT_SHOW" or event == "MAIL_SHOW"
        or event == "AUCTION_HOUSE_SHOW" or event == "TRADE_SHOW" then
        if DB().autoOpen and not f:IsShown() then autoOpened = true; Show() end
        return
    end
    if event == "MERCHANT_CLOSED" or event == "MAIL_CLOSED"
        or event == "AUCTION_HOUSE_CLOSED" or event == "TRADE_CLOSED" then
        if DB().autoOpen and autoOpened then autoOpened = false; Hide() end
        return
    end
    if event == "BAG_UPDATE" or event == "PLAYER_MONEY" or event == "PLAYERBANKSLOTS_CHANGED" then
        MarkDirty()
    end
    RefreshList()
end)

-- resize (width; the height follows the contents) + mouse-wheel scaling
f:SetResizable(true)
local minW, maxW = 4 * SIZE + 20, 24 * SIZE + 20
local minH, maxH = ChromeTop() + 2 * SIZE + BOTTOM_CHROME, 40 * SIZE
if f.SetResizeBounds then f:SetResizeBounds(minW, minH, maxW, maxH)
elseif f.SetMinResize then f:SetMinResize(minW, minH); f:SetMaxResize(maxW, maxH) end
f:SetWidth(12 * SIZE + 20); f:SetHeight(340)
f:SetScale(DB().scale or 1)
ApplyBackdropColor()

-- Corner grip: drags both axes. Grabbing it switches the column count back to automatic,
-- otherwise the fixed setting would fight the width you are dragging out.
local grip = CreateFrame("Button", nil, f)
grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -2, 2)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetScript("OnMouseDown", function()
    DB().columns = 0
    f.gaarResizing = true
    f:StartSizing("BOTTOMRIGHT")
end)
grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    f.gaarResizing = nil
    RefreshList()
    -- dragged shorter than the grid needs: snap back so nothing is cut off
    if f.gaarNeededHeight and f:GetHeight() < f.gaarNeededHeight then
        f:SetHeight(f.gaarNeededHeight)
    end
end)
f:SetScript("OnSizeChanged", function() RefreshList() end)

-- Wheel scales the window. There is nothing to scroll: the grid always shows every slot.
f:EnableMouseWheel(true)
f:SetScript("OnMouseWheel", function(_, dir)
    local s = math.max(0.6, math.min(2.0, (DB().scale or 1) + (dir > 0 and 0.05 or -0.05)))
    DB().scale = s; f:SetScale(s)
end)

BuildBagBar()

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------
local uid = 0
local function MakeCheck(parent, label, y, get, set)
    uid = uid + 1
    local name = "GaarBagsCheck" .. uid
    local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24); c:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    c:SetChecked(get() and true or false)
    local fs = _G[name .. "Text"]
    fs:SetText(label); fs:SetFontObject(GameFontHighlight)
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    c.gaarRefresh = function() c:SetChecked(get() and true or false) end
    return c
end

function GaarBags_BuildOptions(container)
    local refreshers = {}
    local y = -8

    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("Bags")
    y = y - 28

    local openBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    openBtn:SetSize(140, 24); openBtn:SetPoint("TOPLEFT", 16, y)
    openBtn:SetText("Open the bag window")
    openBtn:SetScript("OnClick", Toggle)

    local sortNow = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    sortNow:SetSize(90, 24); sortNow:SetPoint("TOPLEFT", 162, y)
    sortNow:SetText("Sort now")
    sortNow:SetScript("OnClick", DoSort)

    local fitBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    fitBtn:SetSize(110, 24); fitBtn:SetPoint("TOPLEFT", 258, y)
    fitBtn:SetText("Fit to contents")
    fitBtn:SetScript("OnClick", function() FitHeight(); RefreshList() end)
    y = y - 30

    local charsBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    charsBtn:SetSize(140, 24); charsBtn:SetPoint("TOPLEFT", 16, y)
    charsBtn:SetText("All characters")
    charsBtn:SetScript("OnClick", ToggleAlt)
    y = y - 34

    local function check(lbl, get, set)
        local c = MakeCheck(container, lbl, y, get, set)
        refreshers[#refreshers + 1] = c.gaarRefresh
        y = y - 26
    end

    check("Take over the bag keys (B, bag bar)", function() return DB().override end,
        function(v) DB().override = v end)
    check("Open at merchant, bank, mail, auction, trade", function() return DB().autoOpen end,
        function(v) DB().autoOpen = v end)
    check("Use the client's own bag sorting", function() return DB().useBlizzSort end,
        function(v) DB().useBlizzSort = v end)
    check("Upgrade arrows from Pawn", function() return DB().pawnArrows end,
        function(v) DB().pawnArrows = v; RefreshList() end)
    check("List other characters holding an item on its tooltip", function() return DB().altTooltips end,
        function(v) DB().altTooltips = v end)
    y = y - 10

    local tintLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tintLabel:SetPoint("TOPLEFT", 18, y); tintLabel:SetText("Colour slots by:")
    local x = 140
    for _, t in ipairs({ { "Bag type", "bagtype" }, { "Bag", "bag" }, { "Off", "off" } }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(70, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(t[1])
        b:SetScript("OnClick", function() DB().tint = t[2]; RefreshList() end)
        x = x + 72
    end
    y = y - 30

    local colLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colLabel:SetPoint("TOPLEFT", 18, y); colLabel:SetText("Columns:")
    x = 140
    for _, c in ipairs({ { "Auto", 0 }, { "8", 8 }, { "12", 12 }, { "16", 16 } }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(52, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(c[1])
        b:SetScript("OnClick", function() DB().columns = c[2]; RefreshList() end)
        x = x + 54
    end
    y = y - 30

    local fontLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", 18, y); fontLabel:SetText("Money text size:")
    x = 140
    for _, s in ipairs({ 9, 11, 13, 16 }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(46, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(tostring(s))
        b:SetScript("OnClick", function() DB().footerFont = s; ApplyFooterFont() end)
        x = x + 48
    end
    y = y - 30

    local alphaLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    alphaLabel:SetPoint("TOPLEFT", 18, y); alphaLabel:SetText("Background:")
    x = 140
    for _, a in ipairs({ { "Solid", 1 }, { "Dark", 0.85 }, { "Faint", 0.5 }, { "Clear", 0.15 } }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(52, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(a[1])
        b:SetScript("OnClick", function() DB().bgAlpha = a[2]; ApplyBackdropColor() end)
        x = x + 54
    end
    y = y - 30

    local sortLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sortLabel:SetPoint("TOPLEFT", 18, y); sortLabel:SetText("Fallback order:")
    x = 140
    for _, s in ipairs({ { "Quality", "quality" }, { "Name", "name" } }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(70, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(s[1])
        b:SetScript("OnClick", function() DB().sort = s[2] end)
        x = x + 72
    end
    y = y - 30

    -- Background colour: swatches rather than the colour picker, whose API differs between
    -- client versions in ways this addon can't test for.
    local colLabel2 = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colLabel2:SetPoint("TOPLEFT", 18, y); colLabel2:SetText("Background colour:")
    x = 140
    local SWATCHES = {
        { 0, 0, 0 }, { 0.06, 0.07, 0.09 }, { 0.10, 0.10, 0.13 }, { 0.07, 0.09, 0.14 },
        { 0.09, 0.13, 0.10 }, { 0.14, 0.09, 0.09 }, { 0.12, 0.10, 0.15 }, { 0.18, 0.16, 0.12 },
    }
    for _, c in ipairs(SWATCHES) do
        local sw = CreateFrame("Button", nil, container, "BackdropTemplate")
        sw:SetSize(22, 20); sw:SetPoint("TOPLEFT", x, y + 4)
        sw:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
        sw:SetBackdropColor(c[1], c[2], c[3], 1)
        sw:SetBackdropBorderColor(0.4, 0.42, 0.47, 1)
        sw:SetScript("OnClick", function()
            DB().bgColor = { c[1], c[2], c[3] }
            ApplyBackdropColor()
        end)
        x = x + 24
    end
    y = y - 32

    -- Hide whole kinds of bag, not just single slots.
    local famLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    famLabel:SetPoint("TOPLEFT", 18, y); famLabel:SetText("Hide these bag types:")
    y = y - 24
    local famOrder = { 0, 1, 2, 4, 8, 16, 32, 64, 128, 512, 1024 }
    local col, startY = 0, y
    for _, fam in ipairs(famOrder) do
        local fy = startY - math.floor(col / 3) * 24
        local fx = 16 + (col % 3) * 118
        uid = uid + 1
        local nm = "GaarBagsFam" .. uid
        local c = CreateFrame("CheckButton", nm, container, "UICheckButtonTemplate")
        c:SetSize(22, 22); c:SetPoint("TOPLEFT", fx, fy)
        c:SetChecked(DB().hiddenFam[fam] and true or false)
        local fs = _G[nm .. "Text"]
        fs:SetText(FAMILY_NAME[fam] or ("Type " .. fam)); fs:SetFontObject(GameFontHighlightSmall)
        c:SetScript("OnClick", function(self)
            DB().hiddenFam[fam] = self:GetChecked() and true or nil
            RefreshList()
        end)
        refreshers[#refreshers + 1] = function() c:SetChecked(DB().hiddenFam[fam] and true or false) end
        col = col + 1
    end
    y = startY - math.ceil(#famOrder / 3) * 24 - 10

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(340); hint:SetJustifyH("LEFT")
    hint:SetText("Drag the corner grip to resize; the window never goes smaller than the slots need, so dragging it too short snaps back. Mouse-wheel over the window scales it. On the bag bar: hover a bag to highlight its slots, click to keep the highlight, right-click to hide that bag. The fallback order only applies when the client's own sorting is off. Each character saves what it is carrying while you play it, and every character can read the whole account back; the bank is only recorded while its frame is open, so it is stamped separately.")
    y = y - 62

    container.gaarRefresh = function() for _, fn in ipairs(refreshers) do fn() end end
    return -y
end

local function OpenOptions()
    if _G.GaarOptions_Open and _G.GaarOptions_Open("bags") then return end
    Toggle()
end
_G.GaarBags_Config = OpenOptions

SLASH_GAARBAGS1 = "/gaarbags"
SLASH_GAARBAGS2 = "/gbags"
SlashCmdList["GAARBAGS"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "config" or msg == "options" then OpenOptions()
    elseif msg == "sort" or msg == "clean" then DoSort()
    else Toggle() end
end

-- Take over the bag open/close entry points so B, the bag bar and "open all bags" drive this
-- window instead. Every open/toggle maps to Toggle so one key both opens and closes.
local function Override() return DB().override end
-- These are hooked, never replaced. Replacing a Blizzard global puts this addon's code in the
-- call chain whenever the stock UI uses it, and the taint that carries makes the game refuse
-- protected actions later - which is why using an item out of the bag came back as "blocked
-- from an action only available to the Blizzard UI".
--
-- Hooking runs after Blizzard's own function, so its container frames do open; the OnShow
-- hook below shuts them again, leaving only this window visible.
--
-- Toggle* are the B key and the bag bar, where a second press should close. Open* are
-- explicit opens - Blizzard calls OpenAllBags itself at a merchant, bank or mailbox - so
-- those only ever show.
-- One keypress reaches several of these: ToggleAllBags calls ToggleBackpack and ToggleBag in
-- turn, so acting on each one immediately toggled the window an even number of times and left
-- it exactly where it started. Requests are therefore collapsed into a single action on the
-- next frame, with an explicit show or hide outranking a toggle that arrived alongside it.
local pendingIntent
local intentDriver = CreateFrame("Frame")
intentDriver:Hide()
intentDriver:SetScript("OnUpdate", function(self)
    self:Hide()
    local intent = pendingIntent
    pendingIntent = nil
    if intent == "show" then Show()
    elseif intent == "hide" then Hide()
    elseif intent == "toggle" then Toggle() end
end)

local function Request(intent)
    if not Override() then return end
    if intent == "toggle" and pendingIntent then return end
    pendingIntent = intent
    intentDriver:Show()
end

local function HookBagEntry(name, intent)
    if type(_G[name]) == "function" then
        hooksecurefunc(name, function() Request(intent) end)
    end
end

HookBagEntry("ToggleBackpack", "toggle")
HookBagEntry("ToggleBag", "toggle")
HookBagEntry("ToggleAllBags", "toggle")
HookBagEntry("OpenAllBags", "show")
HookBagEntry("OpenBackpack", "show")
HookBagEntry("CloseAllBags", "hide")
HookBagEntry("CloseBackpack", "hide")

for i = 1, (NUM_CONTAINER_FRAMES or 13) do
    local cf = _G["ContainerFrame" .. i]
    if cf then cf:HookScript("OnShow", function(self) if Override() then self:Hide() end end) end
end
