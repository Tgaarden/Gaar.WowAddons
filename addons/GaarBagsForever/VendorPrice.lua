-- GaarBagsForever: vendor sell price on every bag item button (since 1.14.0).
--
-- A small coin amount in the top-left corner of each item button that has a sell value: the
-- price of ONE item (not the stack), the largest coin only, floored - "1g", "35s", "8c" - in the
-- coin's colour (top-right is kept free for a later auction price). Items without a sell price (or not cached yet) show nothing.
--
-- Lives in its own file because GaarBagsForever.lua is close to Lua's limit of 200 locals. The
-- main file calls ns.Vendor.Update(button, bag, slot) from its existing button refresh (the one
-- that draws the padlocks), so it follows every bag, bank and Combined Backpack button, and
-- ns.Vendor.IsOn is bound to the saved setting. No Blizzard function is replaced and nothing is
-- set on a Blizzard frame; we only create a fontstring on the button.
local ADDON_NAME, ns = ...
if type(ns) ~= "table" then ns = {} end

local _G = _G
local Vendor = {}
ns.Vendor = Vendor

local COPPER_PER_SILVER, COPPER_PER_GOLD = 100, 10000
local COLORS = {
    g = { 1.00, 0.84, 0.00 },   -- ffd700
    s = { 0.78, 0.78, 0.81 },   -- c7c7cf
    c = { 0.93, 0.65, 0.37 },   -- eda55f
}

-- Compact format: copper -> "1g" / "35s" / "8c" and the colour key; nil for nothing to show.
function Vendor.Compact(copper)
    if type(copper) ~= "number" or copper ~= copper or copper < 1 then return nil end
    copper = math.floor(copper)
    if copper >= COPPER_PER_GOLD then return math.floor(copper / COPPER_PER_GOLD) .. "g", "g" end
    if copper >= COPPER_PER_SILVER then return math.floor(copper / COPPER_PER_SILVER) .. "s", "s" end
    return copper .. "c", "c"
end

-- A value the client hides comes back secret and can be neither compared nor used.
local function Plain(v)
    local f = _G.issecretvalue
    if type(f) == "function" and f(v) then return nil end
    return v
end

local function PlainNumber(v)
    v = Plain(v)
    if type(v) == "number" then return v end
    return nil
end

Vendor.IsOn = function() return true end   -- replaced by the main file once the DB is bound
Vendor.QueueRefresh = function() end       -- replaced by the main file (Lock.Refresh)

local priceCache = {}                      -- itemID -> sell price in copper (known values only)
local pending = {}                         -- itemID -> true while the item is not cached yet
local fontStrings = setmetatable({}, { __mode = "k" })

-- Sell price of an item in copper, or nil when it is not cached yet.
local function SellPrice(id, link)
    local cached = priceCache[id]
    if cached ~= nil then return cached end
    local getInfo = (type(_G.C_Item) == "table" and _G.C_Item.GetItemInfo) or _G.GetItemInfo
    if type(getInfo) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g, h, i, j, k = pcall(getInfo, link or id)
    if not ok then return nil end
    local price
    if type(a) == "table" then            -- a client that returns a table
        price = PlainNumber(a.sellPrice)
    elseif Plain(a) ~= nil then
        price = PlainNumber(k)
    end
    if price == nil then
        pending[id] = true
        return nil
    end
    pending[id] = nil
    priceCache[id] = price
    return price
end

local function GetFontString(button)
    local fs = fontStrings[button]
    if fs then return fs end
    if type(button.CreateFontString) ~= "function" then return nil end
    local ok, made = pcall(button.CreateFontString, button, nil, "OVERLAY", "NumberFontNormalSmall")
    if not ok or not made then return nil end
    fs = made
    -- OVERLAY 7: above the icon. Top-left, short and left-aligned: the padlock sits bottom-left and
    -- the top-right is reserved for an auction price, so stay left of the button's middle.
    if type(fs.SetDrawLayer) == "function" then fs:SetDrawLayer("OVERLAY", 7) end
    fs:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    fs:SetJustifyH("LEFT")
    if type(fs.SetWidth) == "function" then fs:SetWidth(20) end
    if type(fs.SetWordWrap) == "function" then fs:SetWordWrap(false) end
    fs:Hide()
    fontStrings[button] = fs
    return fs
end

local function HideText(button)
    local fs = fontStrings[button]
    if fs then fs:Hide() end
end

-- Called for every item button on every refresh. bag/slot are nil for a button that is not on screen.
function Vendor.Update(button, bag, slot)
    if not Vendor.IsOn() or bag == nil or slot == nil then return HideText(button) end
    local c = type(_G.C_Container) == "table" and _G.C_Container.GetContainerItemInfo
    local info
    if type(c) == "function" then
        local ok, r = pcall(c, bag, slot)
        if ok and type(r) == "table" then info = r end
    end
    if not info then return HideText(button) end
    local id = PlainNumber(info.itemID)
    if not id or Plain(info.hasNoValue) == true then return HideText(button) end
    local price = SellPrice(id, Plain(info.hyperlink))
    local text, color = Vendor.Compact(price)
    if not text then return HideText(button) end
    local fs = GetFontString(button)
    if not fs then return end
    local rgb = COLORS[color]
    fs:SetTextColor(rgb[1], rgb[2], rgb[3])
    fs:SetText(text)
    fs:Show()
end

-- An item that was not cached arrives: redraw once (debounced), only if we were waiting for one.
local frame = type(_G.CreateFrame) == "function" and _G.CreateFrame("Frame") or nil
if frame then
    local scheduled = false
    pcall(frame.RegisterEvent, frame, "GET_ITEM_INFO_RECEIVED")
    frame:SetScript("OnEvent", function(_, _, itemID)
        itemID = PlainNumber(itemID)
        if not itemID or not pending[itemID] or scheduled then return end
        scheduled = true
        local after = type(_G.C_Timer) == "table" and _G.C_Timer.After
        local function run()
            scheduled = false
            pcall(Vendor.QueueRefresh)
        end
        if after then after(0.2, run) else run() end
    end)
end

-- Stack total line in the item tooltip: "Sell price (N):" <coins>. The game's tooltip only shows the
-- price of one item; GaarTooltipsForever adds this same line when it is loaded with its vendor price
-- option on, so we add it only otherwise, and never when a "Sell price (" line is already there.
local TOTAL_LABEL = "Sell price ("

local function TooltipsForeverCovers()
    local api = type(_G.C_AddOns) == "table" and _G.C_AddOns.IsAddOnLoaded or _G.IsAddOnLoaded
    if type(api) ~= "function" then return false end
    local ok, loaded = pcall(api, "GaarTooltipsForever")
    if not ok or not loaded then return false end
    local db = _G.GaarTooltipsForeverDB
    return type(db) == "table" and db.enabled == true and db.vendorPrice == true
end

local function HasTotalLine(tooltip)
    local name = type(tooltip.GetName) == "function" and tooltip:GetName()
    local n = type(tooltip.NumLines) == "function" and PlainNumber(tooltip:NumLines())
    if not name or not n then return false end
    for i = 1, n do
        local fs = _G[name .. "TextLeft" .. i]
        local t = fs and type(fs.GetText) == "function" and Plain(fs:GetText())
        if type(t) == "string" and t:find(TOTAL_LABEL, 1, true) then return true end
    end
    return false
end

-- Bag/slot of the item button under the cursor.
local function HoveredSlot()
    local focus
    if type(_G.GetMouseFoci) == "function" then
        local ok, t = pcall(_G.GetMouseFoci)
        if ok and type(t) == "table" then focus = t[1] end
    elseif type(_G.GetMouseFocus) == "function" then
        local ok, f = pcall(_G.GetMouseFocus)
        if ok then focus = f end
    end
    if type(focus) ~= "table" or type(focus.GetID) ~= "function" then return nil end
    local ok, slot = pcall(focus.GetID, focus)
    slot = ok and PlainNumber(slot) or nil
    local bag
    if type(focus.GetBagID) == "function" then
        local ok2, b = pcall(focus.GetBagID, focus)
        bag = ok2 and PlainNumber(b) or nil
    elseif type(focus.GetParent) == "function" then
        local ok2, p = pcall(focus.GetParent, focus)
        if ok2 and type(p) == "table" and type(p.GetID) == "function" then
            local ok3, b = pcall(p.GetID, p)
            bag = ok3 and PlainNumber(b) or nil
        end
    end
    if bag == nil or slot == nil then return nil end
    return bag, slot
end

local function Coin(copper)
    local C = _G.C_CurrencyInfo
    local fn = type(C) == "table" and C.GetCoinTextureString or _G.GetCoinTextureString
    if type(fn) == "function" then
        local ok, s = pcall(fn, copper)
        if ok and type(s) == "string" then return s end
    end
    return string.format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

function Vendor.AddTotalLine(tooltip, data)
    if not Vendor.IsOn() or tooltip ~= _G.GameTooltip or type(data) ~= "table" then return end
    local id = PlainNumber(data.id)
    if not id or TooltipsForeverCovers() then return end
    local bag, slot = HoveredSlot()
    local c = type(_G.C_Container) == "table" and _G.C_Container.GetContainerItemInfo
    if not bag or type(c) ~= "function" then return end
    local ok, info = pcall(c, bag, slot)
    if not ok or type(info) ~= "table" or PlainNumber(info.itemID) ~= id then return end
    local count = PlainNumber(info.stackCount)
    if not count or count <= 1 then return end
    local price = SellPrice(id, Plain(info.hyperlink))
    if not price or price <= 0 or HasTotalLine(tooltip) then return end
    if type(tooltip.AddDoubleLine) ~= "function" then return end
    tooltip:AddDoubleLine(TOTAL_LABEL .. count .. "):", Coin(price * count), 1, 1, 1, 1, 1, 1)
    if type(tooltip.IsShown) == "function" and tooltip:IsShown() and type(tooltip.Show) == "function" then
        tooltip:Show()
    end
end

do
    local tdp, enum = _G.TooltipDataProcessor, _G.Enum
    local item = type(enum) == "table" and type(enum.TooltipDataType) == "table" and enum.TooltipDataType.Item
    if type(tdp) == "table" and type(tdp.AddTooltipPostCall) == "function" and item ~= nil then
        tdp.AddTooltipPostCall(item, function(tooltip, data) pcall(Vendor.AddTotalLine, tooltip, data) end)
    end
end
