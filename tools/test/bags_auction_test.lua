-- LuaJIT test: GaarBagsForever auction price (Auctionator public API, stubbed).
-- Run: luajit tools/test/bags_auction_test.lua   (from the repo root)
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

local registeredCb
_G.CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end
local ns = {}
assert(loadfile("addons/GaarBagsForever/VendorPrice.lua"))("GaarBagsForever", ns)
assert(loadfile("addons/GaarBagsForever/AuctionPrice.lua"))("GaarBagsForever", ns)
local A = ns.Auction

local function FS() local f = { shown = false }
    function f:SetDrawLayer() end function f:SetPoint(...) self.point = { ... } end function f:SetJustifyH(j) self.just = j end
    function f:Hide() self.shown = false end function f:Show() self.shown = true end
    function f:SetTextColor(r, g, b) self.rgb = { r, g, b } end function f:SetText(t) self.text = t end
    return f end
local function Button() local b = {}; function b:CreateFontString() b.fs = FS(); return b.fs end; return b end
local slots = { [1] = { itemID = 10, hyperlink = "item:10" }, [2] = { itemID = 11, hyperlink = "item:11" },
                [3] = { itemID = 12, hyperlink = "item:12" }, [4] = { itemID = 13, hyperlink = "item:13", isBound = true },
                [5] = { itemID = 14, hyperlink = "item:14" } }
_G.C_Container = { GetContainerItemInfo = function(_, slot) return slots[slot] end }

-- Auctionator missing
local b = Button()
A.Update(b, 0, 1); eq(b.fs, nil, "no Auctionator: nothing")
eq(A.Available(), false, "not available")

_G.Auctionator = { API = { v1 = {
    GetAuctionPriceByItemLink = function(caller, link)
        eq(caller, "GaarBagsForever", "caller id")
        return ({ ["item:10"] = 135040, ["item:12"] = 250, ["item:13"] = 999 })[link]
    end,
    GetAuctionAgeByItemLink = function(_, link) return link == "item:12" and 7 or 1 end,
    GetAuctionPriceByItemID = function(_, id) if id == 14 then error("boom") end end,
    RegisterForDBUpdate = function(caller, cb) registeredCb = cb end,
} } }
eq(A.Available(), true, "available")
A.TryRegister(); eq(type(registeredCb), "function", "registered for DB update")

local b1, b2, b3, b4, b5 = Button(), Button(), Button(), Button(), Button()
A.Update(b1, 0, 1); eq(b1.fs.text, "13g", "priced"); eq(b1.fs.shown, true, "shown")
eq(b1.fs.rgb[1], 1.00, "gold colour"); eq(b1.fs.point[1], "TOPRIGHT", "top-right"); eq(b1.fs.just, "RIGHT", "right aligned")
A.Update(b2, 0, 2); eq(b2.fs, nil, "nil price: nothing")
A.Update(b3, 0, 3); eq(b3.fs.text, "2s", "old price text"); eq(b3.fs.rgb[1], 0.55, "old -> grey")
A.Update(b4, 0, 4); eq(b4.fs, nil, "soulbound: nothing")
A.Update(b5, 0, 5); eq(b5.fs, nil, "erroring API is contained")

A.IsOn = function() return false end
A.Update(b1, 0, 1); eq(b1.fs.shown, false, "off hides")
A.IsOn = function() return true end
A.Update(b1, nil, nil); eq(b1.fs.shown, false, "off-screen hides")
A.Update(b1, 0, 1); eq(b1.fs.shown, true, "back on")
_G.Auctionator = nil
A.Update(b1, 0, 1); eq(b1.fs.shown, false, "Auctionator gone hides")

if fails == 0 then print("bags_auction_test: ok") else os.exit(1) end
