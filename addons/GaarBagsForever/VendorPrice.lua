-- GaarBagsForever: vendor sell price on every bag item button (since 1.14.0).
--
-- A small coin amount in the bottom-left corner of each item button that has a sell value: the
-- price of ONE item (not the stack), the largest coin only, floored - "1g", "35s", "8c" - in the
-- coin's colour. Items without a sell price (or not cached yet) show nothing.
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
    -- OVERLAY 7: above the icon and the padlock (6), level with the stack count at the other corner.
    if type(fs.SetDrawLayer) == "function" then fs:SetDrawLayer("OVERLAY", 7) end
    fs:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 2, 2)
    fs:SetJustifyH("LEFT")
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
