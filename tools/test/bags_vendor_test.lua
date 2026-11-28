-- LuaJIT test: GaarBagsForever vendor price - the compact coin format and the per-button update.
-- Run: luajit tools/test/bags_vendor_test.lua   (from the repo root)
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

local ns = {}
_G.CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end
local chunk = assert(loadfile("addons/GaarBagsForever/VendorPrice.lua"))
chunk("GaarBagsForever", ns)
local V = ns.Vendor

local function c(n) local t = V.Compact(n); return t end
eq(c(0), nil, "0 -> nothing")
eq(c(nil), nil, "nil -> nothing")
eq(c(-5), nil, "negative -> nothing")
eq(c(1), "1c", "1c")
eq(c(8), "8c", "8c")
eq(c(99), "99c", "99c")
eq(c(100), "1s", "1s")
eq(c(3599), "35s", "35s floors")
eq(c(9999), "99s", "99s")
eq(c(10000), "1g", "1g")
eq(c(135040), "13g", "13g floors")
eq(select(2, V.Compact(5)), "c", "copper colour key")
eq(select(2, V.Compact(500)), "s", "silver colour key")
eq(select(2, V.Compact(50000)), "g", "gold colour key")

-- Update: a button with a sell price shows text, an unpriced one hides it, off hides everything.
local function FS() local f = { shown = false }
    function f:SetDrawLayer() end function f:SetPoint() end function f:SetJustifyH() end
    function f:Hide() self.shown = false end function f:Show() self.shown = true end
    function f:SetTextColor(r, g, b) self.rgb = { r, g, b } end function f:SetText(t) self.text = t end
    return f end
local function Button() local b = {}; function b:CreateFontString() b.fs = FS(); return b.fs end; return b end
local slots = { [1] = { itemID = 10, hyperlink = "item:10" }, [2] = { itemID = 11, hasNoValue = true }, [3] = { itemID = 12 } }
_G.C_Container = { GetContainerItemInfo = function(bag, slot) return slots[slot] end }
_G.C_Item = { GetItemInfo = function(id)
    if id == 12 then return nil end
    local nameFor = { [10] = 135040 }
    return "x", "l", 1, 1, 1, "t", "s", 1, nil, 0, nameFor[10] or 5 end }
_G.C_Item.GetItemInfo = function(id)
    if id == "item:10" then return "n", "l", 1, 1, 1, "t", "s", 20, "", 0, 135040 end
    return nil
end
local b1, b2, b3 = Button(), Button(), Button()
V.Update(b1, 0, 1); eq(b1.fs.text, "13g", "priced item text"); eq(b1.fs.shown, true, "priced item shown")
V.Update(b2, 0, 2); eq(b2.fs, nil, "no-value item: nothing created")
V.Update(b3, 0, 3); eq(b3.fs, nil, "uncached item: nothing yet")
V.IsOn = function() return false end
V.Update(b1, 0, 1); eq(b1.fs.shown, false, "off hides")
V.IsOn = function() return true end
V.Update(b1, nil, nil); eq(b1.fs.shown, false, "off-screen button hides")

-- Tooltip stack total: re-load with a TooltipDataProcessor and a hovered stack.
local posted
_G.Enum = { TooltipDataType = { Item = 1 } }
_G.TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) posted = fn end }
local ns2 = {}
assert(loadfile("addons/GaarBagsForever/VendorPrice.lua"))("GaarBagsForever", ns2)
local function Tip() local t = { lines = {} }
    t.GetName = function() return "GameTooltip" end
    t.NumLines = function() return #t.lines end
    t.AddDoubleLine = function(_, l, r) t.lines[#t.lines + 1] = l; _G["GameTooltipTextLeft" .. #t.lines] = { GetText = function() return l end } end
    return t end
local tip = Tip(); _G.GameTooltip = tip
local focus = { GetID = function() return 1 end, GetBagID = function() return 0 end }
_G.GetMouseFoci = function() return { focus } end
slots[1] = { itemID = 10, hyperlink = "item:10", stackCount = 5 }
posted(tip, { id = 10 })
eq(tip.lines[1], "Sell price (5):", "stack total added")
posted(tip, { id = 10 })
eq(#tip.lines, 1, "never twice")
local t2 = Tip(); _G.GameTooltip = t2; slots[1].stackCount = 1
posted(t2, { id = 10 }); eq(#t2.lines, 0, "single item: no line")
slots[1].stackCount = 5
_G.C_AddOns = { IsAddOnLoaded = function() return true end }
_G.GaarTooltipsForeverDB = { enabled = true, vendorPrice = true }
local t3 = Tip(); _G.GameTooltip = t3; posted(t3, { id = 10 }); eq(#t3.lines, 0, "Tooltips covers it")
_G.GaarTooltipsForeverDB.vendorPrice = false
local t4 = Tip(); _G.GameTooltip = t4; posted(t4, { id = 10 }); eq(#t4.lines, 1, "Tooltips option off: Bags adds")

if fails == 0 then print("bags_vendor_test: ok") else os.exit(1) end
