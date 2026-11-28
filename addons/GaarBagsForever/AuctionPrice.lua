-- GaarBagsForever: auction price on every bag item button (since 1.15.0).
--
-- The lowest buyout per ONE item, as the optional third-party addon Auctionator has recorded it,
-- in the top-right corner of each item button: largest coin only, floored, in the coin's colour
-- ("1g", "35s", "8c" - the same format as the vendor price, top-left). A price Auctionator has not
-- seen for more than 3 days is drawn grey. Without Auctionator, or without a price (or for a
-- soulbound item), nothing is shown.
--
-- Only Auctionator's PUBLIC API (Auctionator.API.v1) is used, every call inside pcall: Auctionator
-- may be missing or load later. Own file because GaarBagsForever.lua is close to Lua's limit of
-- 200 locals. The main file calls ns.Auction.Update(button, bag, slot) from its existing button
-- refresh (the same one as the vendor price), and binds ns.Auction.IsOn to the saved setting. No
-- Blizzard function is replaced and nothing is set on a Blizzard frame; we only create a fontstring.
local ADDON_NAME, ns = ...
if type(ns) ~= "table" then ns = {} end

local _G = _G
local Auction = {}
ns.Auction = Auction

local CALLER = "GaarBagsForever"
local STALE_DAYS = 3
local GREY = { 0.55, 0.55, 0.55 }
local COLORS = {
    g = { 1.00, 0.84, 0.00 },
    s = { 0.78, 0.78, 0.81 },
    c = { 0.93, 0.65, 0.37 },
}

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

Auction.IsOn = function() return true end   -- replaced by the main file once the DB is bound
Auction.QueueRefresh = function() end       -- replaced by the main file (Lock.Refresh)

local fontStrings = setmetatable({}, { __mode = "k" })

-- Auctionator.API.v1, or nil when Auctionator is not there (yet).
local function Api()
    local a = _G.Auctionator
    local v1 = type(a) == "table" and type(a.API) == "table" and a.API.v1
    if type(v1) == "table" and type(v1.GetAuctionPriceByItemLink) == "function" then return v1 end
    return nil
end

function Auction.Available() return Api() ~= nil end

-- Per-unit price in copper and the days since it was last seen (nil when unknown).
function Auction.Lookup(id, link)
    local api = Api()
    if not api then return nil end
    local price, age
    if type(link) == "string" then
        local ok, p = pcall(api.GetAuctionPriceByItemLink, CALLER, link)
        if ok then price = PlainNumber(p) end
        if price and type(api.GetAuctionAgeByItemLink) == "function" then
            local ok2, a = pcall(api.GetAuctionAgeByItemLink, CALLER, link)
            if ok2 then age = PlainNumber(a) end
        end
    end
    if price == nil and type(id) == "number" and type(api.GetAuctionPriceByItemID) == "function" then
        local ok, p = pcall(api.GetAuctionPriceByItemID, CALLER, id)
        if ok then price = PlainNumber(p) end
        if price and age == nil and type(api.GetAuctionAgeByItemID) == "function" then
            local ok2, a = pcall(api.GetAuctionAgeByItemID, CALLER, id)
            if ok2 then age = PlainNumber(a) end
        end
    end
    return price, age
end

local function GetFontString(button)
    local fs = fontStrings[button]
    if fs then return fs end
    if type(button.CreateFontString) ~= "function" then return nil end
    local ok, made = pcall(button.CreateFontString, button, nil, "OVERLAY", "NumberFontNormalSmall")
    if not ok or not made then return nil end
    fs = made
    -- Same layer as the vendor text; top-right, right-aligned and narrow so it stays clear of it.
    if type(fs.SetDrawLayer) == "function" then fs:SetDrawLayer("OVERLAY", 7) end
    fs:SetPoint("TOPRIGHT", button, "TOPRIGHT", -2, -2)
    fs:SetJustifyH("RIGHT")
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
function Auction.Update(button, bag, slot)
    if not Auction.IsOn() or bag == nil or slot == nil or not Api() then return HideText(button) end
    local c = type(_G.C_Container) == "table" and _G.C_Container.GetContainerItemInfo
    local info
    if type(c) == "function" then
        local ok, r = pcall(c, bag, slot)
        if ok and type(r) == "table" then info = r end
    end
    if not info then return HideText(button) end
    local id = PlainNumber(info.itemID)
    if not id or Plain(info.isBound) == true then return HideText(button) end
    local price, age = Auction.Lookup(id, Plain(info.hyperlink))
    if not ns.Vendor then return HideText(button) end
    local text, color = ns.Vendor.Compact(price)
    if not text then return HideText(button) end
    local fs = GetFontString(button)
    if not fs then return end
    local rgb = (age and age > STALE_DAYS) and GREY or COLORS[color]
    fs:SetTextColor(rgb[1], rgb[2], rgb[3])
    fs:SetText(text)
    fs:Show()
end

-- Redraw when Auctionator's data changes or the auction house closes (debounced).
local scheduled = false
local function Queue()
    if scheduled then return end
    scheduled = true
    local after = type(_G.C_Timer) == "table" and _G.C_Timer.After
    local function run()
        scheduled = false
        pcall(Auction.QueueRefresh)
    end
    if after then after(0.5, run) else run() end
end
Auction.Queue = Queue

local registered = false
local function TryRegister()
    if registered then return end
    local api = Api()
    if not api or type(api.RegisterForDBUpdate) ~= "function" then return end
    if pcall(api.RegisterForDBUpdate, CALLER, Queue) then registered = true end
end
Auction.TryRegister = TryRegister

local frame = type(_G.CreateFrame) == "function" and _G.CreateFrame("Frame") or nil
if frame then
    for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "AUCTION_HOUSE_CLOSED" }) do
        pcall(frame.RegisterEvent, frame, e)
    end
    frame:SetScript("OnEvent", function(_, event, arg1)
        if event == "AUCTION_HOUSE_CLOSED" then return Queue() end
        if event == "ADDON_LOADED" and arg1 ~= "Auctionator" and arg1 ~= ADDON_NAME then return end
        pcall(TryRegister)
        if event == "ADDON_LOADED" and arg1 == "Auctionator" then Queue() end
    end)
end
