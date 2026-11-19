-- LuaJIT stub test: GaarBagsForever 1.12 - locked items kept from destroy (the delete popup),
-- the auction house sell slot (classic AuctionFrame and the retail-engine AuctionHouseFrame)
-- and the trade window, with one shared popup.
-- Run: luajit tools/test/bags_lock_everywhere_test.lua   (from the repo root)
local path = "addons/GaarBagsForever/GaarBagsForever.lua"
local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { Block = Block, Lock = Lock, Bind = function() BindSavedVariables(); BindCharacterVariables() end }\n"

local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local G = setmetatable({}, { __index = function(t, k)
    if _G[k] ~= nil then return _G[k] end
    return nil end })
G._G = G
local combat = false
G.GaarForever = {
    NewAddon = function() return { Print = function(_, msg) G.__printed[#G.__printed + 1] = msg end } end,
    OnOff = function(v) return v and "on" or "off" end,
    InCombat = function() return combat end,
    Plain = function(v) return v end,
    Str = function(v) return type(v) == "string" and v or nil end,
    API = function() return nil end,   -- no C_Timer: the queued checks run at once
    Migrate = noop, Call = noop, RenderMenu = noop,
}
G.__printed = {}
G.CreateFrame = widget
G.SlashCmdList = {}
G.UIParent = widget()
G.GameTooltip = widget()
local clock = 100
G.GetTime = function() return clock end

-- A real post-hook, so the StaticPopup_Show and SetItem hooks run.
G.hooksecurefunc = function(a, b, c)
    if type(a) == "string" then
        local orig = G[a]
        rawset(G, a, function(...) local r = { orig(...) }; b(...); return unpack(r) end)
    else
        local orig = a[b]
        a[b] = function(...) local r = { orig(...) }; c(...); return unpack(r) end
    end
end

local function link(id, name) return "|cffffffff|Hitem:" .. id .. "::::::::|h[" .. (name or ("Item " .. id)) .. "]|h|r" end

-- The cursor: an item id or nil. ClearCursor puts the item back in the bags.
local cursor
local returned = {}
G.GetCursorInfo = function() if cursor then return "item", cursor, link(cursor) end end
G.ClearCursor = function()
    if cursor then returned[#returned + 1] = cursor end
    cursor = nil
end
local deleted = {}
G.DeleteCursorItem = function()
    if cursor then deleted[#deleted + 1] = cursor end
    cursor = nil
end

-- StaticPopups: which -> shown.
local shown, popups, hidden = {}, {}, {}
G.StaticPopupDialogs = {}
G.StaticPopup_Show = function(which, text)
    shown[which] = true
    if which == "GAARBAGSFOREVER_LOCKED" then popups[#popups + 1] = text end
end
G.StaticPopup_Hide = function(which)
    hidden[#hidden + 1] = which
    shown[which] = nil
end

-- Trade: slot -> item id.
local trade = {}
local tradeClicks = 0
local tradeClickWorks = true
G.MAX_TRADE_ITEMS = 7
G.TRADE_ENCHANT_SLOT = 7
G.GetTradePlayerItemLink = function(i) return trade[i] and link(trade[i]) or nil end
G.ClickTradeButton = function(i)
    tradeClicks = tradeClicks + 1
    if not tradeClickWorks then return end
    if cursor == nil and trade[i] then cursor, trade[i] = trade[i], nil end
end

-- Classic auction sell slot: { id, name } or nil.
local sell
local sellClicks = 0
G.GetAuctionSellItemInfo = function()
    if not sell then return nil end
    return sell.name, 134400, 1, 1, true, 100, 100, 1, 1, sell.id
end
G.ClickAuctionSellItemButton = function()
    sellClicks = sellClicks + 1
    if cursor == nil and sell then
        cursor = sell.id or sell.realID
        sell = nil
    end
end

-- Retail-engine auction house: item locations are { id = n }.
G.C_Item = {
    DoesItemExist = function(loc) return loc ~= nil and loc.id ~= nil end,
    GetItemID = function(loc) return loc.id end,
    GetItemLink = function(loc) return link(loc.id) end,
}

local f = loadstring(src, "@GBF"); setfenv(f, G)
local ok, err = pcall(f, "GaarBagsForever", {})
assert(ok, "load: " .. tostring(err))
local T = G.__T
local Block, Lock = T.Block, T.Lock

local fails = 0
local function check(name, cond)
    print(string.format("%-62s %s", name, cond and "ok" or "FAIL"))
    if not cond then fails = fails + 1 end
end
local function printed(text)
    local n = 0
    for _, m in ipairs(G.__printed) do if m:find(text, 1, true) then n = n + 1 end end
    return n
end
local function reset()
    clock = clock + 10
    popups, hidden, returned, deleted, G.__printed = {}, {}, {}, {}, {}
end

-- ---- pure parts ----
local locked = { [100] = true }
local function isLocked(id) return locked[id] == true end
local hits = Block.LockedTradeSlots({ [1] = 5, [3] = 100, [7] = 100 }, 7, 7, isLocked)
check("trade slots: slot 3 only, slot 7 (not traded) skipped", #hits == 1 and hits[1] == 3)
check("delete popups recognised", Block.IsDeletePopup("DELETE_ITEM") and Block.IsDeletePopup("DELETE_GOOD_ITEM")
    and Block.IsDeletePopup("DELETE_QUEST_ITEM") and Block.IsDeletePopup("DELETE_GOOD_QUEST_ITEM"))
check("other popups ignored", not Block.IsDeletePopup("CONFIRM_BINDER") and not Block.IsDeletePopup(nil))
check("link name", Block.LinkName(link(1, "Hearthstone")) == "Hearthstone")

G.GaarBagsForeverCharDB = { lockedItems = { [100] = link(100, "Hearthstone") } }
G.GaarBagsForeverDB = {}
T.Bind()
Block.OnEvent("PLAYER_LOGIN")

-- ---- destroy: the popup hook ----
reset()
cursor = 100
G.StaticPopup_Show("DELETE_ITEM", "Hearthstone")
check("destroy: locked item back in the bags", cursor == nil and returned[1] == 100)
check("destroy: Blizzard's delete popup hidden", shown.DELETE_ITEM == nil and hidden[1] == "DELETE_ITEM")
G.DeleteCursorItem()   -- the popup's OK button, had it stayed up
check("destroy: OK can no longer delete anything", #deleted == 0)
check("destroy: one popup, 'cannot be destroyed'", #popups == 1 and popups[1]:find("cannot be destroyed", 1, true) ~= nil
    and popups[1]:find("[Item 100]", 1, true) ~= nil)
check("destroy: chat line", printed("cannot be destroyed") == 1)
Block.OnEvent("DELETE_ITEM_CONFIRM")   -- the same attempt, seen by the event too
check("destroy: event after hook says nothing more", #popups == 1 and printed("cannot be destroyed") == 1)

-- ---- destroy: the event first, the popup after ----
reset()
cursor = 100
Block.OnEvent("DELETE_ITEM_CONFIRM")
check("destroy (event first): cursor cleared", cursor == nil and returned[1] == 100)
G.StaticPopup_Show("DELETE_GOOD_ITEM", "Hearthstone")
check("destroy (event first): late popup hidden", shown.DELETE_GOOD_ITEM == nil)
check("destroy (event first): one popup only", #popups == 1)

-- ---- destroy: an unlocked item is left alone ----
reset()
cursor = 5
G.StaticPopup_Show("DELETE_ITEM", "Item 5")
check("destroy: unlocked item stays deletable", shown.DELETE_ITEM == true and cursor == 5 and #popups == 0)
G.DeleteCursorItem()
check("destroy: unlocked item deleted as normal", deleted[1] == 5)
G.StaticPopup_Hide("DELETE_ITEM")

-- ---- destroy in combat: chat yes, popup no ----
reset()
combat = true
cursor = 100
G.StaticPopup_Show("DELETE_QUEST_ITEM", "Hearthstone")
check("combat: item still put back, popup skipped, chat printed", cursor == nil and #popups == 0
    and printed("cannot be destroyed") == 1)
combat = false

-- ---- trade ----
reset()
trade = { [1] = 5, [3] = 100, [7] = 100 }
Block.OnEvent("TRADE_SHOW")
check("trade: locked slot 3 taken back to the bags", trade[3] == nil and returned[1] == 100 and cursor == nil)
check("trade: other slot and slot 7 left alone", trade[1] == 5 and trade[7] == 100)
check("trade: one popup, 'cannot be traded'", #popups == 1 and popups[1]:find("cannot be traded", 1, true) ~= nil)
local clicksBefore = tradeClicks
Block.OnEvent("TRADE_PLAYER_ITEM_CHANGED")
check("trade: no loop, nothing more clicked or shown", tradeClicks == clicksBefore and #popups == 1)

-- A busy cursor: nothing is clicked until it is empty.
reset()
cursor = 8
trade[2] = 100
Block.OnEvent("TRADE_PLAYER_ITEM_CHANGED")
check("trade: busy cursor, no click", tradeClicks == clicksBefore and trade[2] == 100)
cursor = nil
Block.OnEvent("CURSOR_CHANGED")
check("trade: cursor empty, taken off", trade[2] == nil and returned[1] == 100)
check("trade: still one popup for the attempt", #popups == 1)

-- A client where the click does nothing: gives up after 3 tries with one line.
reset()
tradeClickWorks = false
trade[4] = 100
for _ = 1, 6 do Block.OnEvent("TRADE_PLAYER_ITEM_CHANGED") end
check("trade: gives up after 3 tries, one line", printed("could not take") == 1 and #popups == 1)
tradeClickWorks = true
Block.OnEvent("TRADE_CLOSED")
trade = {}

-- ---- classic auction sell slot ----
reset()
Block.OnEvent("AUCTION_HOUSE_SHOW")
sell = { id = 100, name = "Hearthstone" }
Block.OnEvent("NEW_AUCTION_UPDATE")
check("auction (classic): slot emptied, item back in the bags", sell == nil and returned[1] == 100 and cursor == nil)
check("auction (classic): popup 'cannot be auctioned'", #popups == 1 and popups[1]:find("cannot be auctioned", 1, true) ~= nil)
local sellBefore = sellClicks
Block.OnEvent("NEW_AUCTION_UPDATE")
check("auction (classic): no loop", sellClicks == sellBefore and #popups == 1)

-- No itemID from the client: matched by name.
reset()
sell = { name = "Hearthstone", realID = 100 }
Block.OnEvent("NEW_AUCTION_UPDATE")
check("auction (classic): name fallback finds the locked item", sell == nil and #popups == 1)

-- An unlocked item stays.
reset()
sell = { id = 5, name = "Item 5" }
Block.OnEvent("NEW_AUCTION_UPDATE")
check("auction (classic): unlocked item stays", sell ~= nil and #popups == 0)
sell = nil
Block.OnEvent("AUCTION_HOUSE_CLOSED")

-- ---- retail-engine auction house ----
reset()
local itemFrame = { SetItem = function(self, loc) self.item = loc end, GetItem = function(self) return self.item end }
local cleared = 0
local commFrame = { SetItem = function(self, loc) self.item = loc end, GetItem = function(self) return self.item end,
                    ClearItem = function(self) cleared = cleared + 1; self.item = nil end }
G.AuctionHouseFrame = { ItemSellFrame = itemFrame, CommoditiesSellFrame = commFrame }
Block.OnEvent("ADDON_LOADED", "Blizzard_AuctionHouseUI")
Block.OnEvent("AUCTION_HOUSE_SHOW")
itemFrame:SetItem({ id = 100 })
check("auction (retail): SetItem followed, item cleared with SetItem(nil)", itemFrame.item == nil)
check("auction (retail): popup 'cannot be auctioned'", #popups == 1 and popups[1]:find("cannot be auctioned", 1, true) ~= nil)
reset()
commFrame:SetItem({ id = 100 })
check("auction (retail): ClearItem used when the frame has one", commFrame.item == nil and cleared == 1 and #popups == 1)
reset()
itemFrame:SetItem({ id = 5 })
check("auction (retail): unlocked item stays", itemFrame.item ~= nil and itemFrame.item.id == 5 and #popups == 0)

-- ---- mail still goes through the shared popup ----
reset()
check("shared popup key", Lock.PopupKey == "GAARBAGSFOREVER_LOCKED"
    and G.StaticPopupDialogs.GAARBAGSFOREVER_LOCKED ~= nil and G.StaticPopupDialogs.GAARBAGSFOREVER_LOCKED.button2 == nil)
Lock.Block({ link(100, "Hearthstone"), link(7, "Rope") }, "mailed")
check("mail via shared block: plural text", #popups == 1 and popups[1]:find("are locked (do-not-sell) and cannot be mailed", 1, true) ~= nil)

-- ---- status ----
local status = Block.Status()
check("status line", status:find("StaticPopup_Show hooked: yes", 1, true) ~= nil
    and status:find("classic + retail", 1, true) ~= nil)

print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
