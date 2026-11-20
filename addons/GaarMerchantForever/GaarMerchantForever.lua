--[[
  GaarMerchantForever - sell junk and repair at a merchant, on WoW Forever.

  What it does, each part with its own switch (saved in GaarMerchantForeverDB, changed with
  /gmerch <feature> on|off or from the GaarForever hub menu):

    * enabled      master switch for everything below except /gmerch sell.
    * sellJunk     (default on) at MERCHANT_SHOW, sells every grey (quality 0) item in the bags, out
                   of combat, 3 items every 0.2 s so the server never throttles it. It stops when
                   the merchant closes or combat starts. Items you locked in GaarBagsForever are
                   skipped (see "BBF locks"). Items with no sell price are skipped too.
    * sellJunkConfirm  (default off) asks with a popup first ("Sell N junk items for X?").
    * autoRepair   (default on) repairs everything when the merchant can repair, the cost is above
                   zero and you can pay it.
    * guildRepair  (default off) tries guild funds first (CanGuildBankRepair, and the guild's
                   withdraw allowance covers the cost), then falls back to your own money.
    * summary      (default on) one chat line for what was sold and repaired. With it off, each
                   part prints its own line.
    * /gmerch sell sells the junk by hand while a merchant is open (no popup, no switch needed).
    * /gmerch status shows the settings and the last result; /gmerch help lists the commands.
    * GaarMerchantForeverAPI, a small global table for GaarForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The small helpers (Print, Num,
      IsSecret, API, Call, InCombat, OnOff, RenderMenu) come from GaarForever's library.

  BBF locks. GaarBagsForeverAPI.IsItemLocked(itemID) is used first, then BetterBagsForeverAPI's
  (an old Bags has none), and always the saved per-character tables of BOTH GaarBagsForeverCharDB
  and BetterBagsForeverCharDB, read-only: lockedItems[itemID] ~= nil means locked; any yes wins. A lock is read each
  time just before an item is sold, so a lock set while the sale runs still counts. The value is
  never written.

  Taint and safety: no Blizzard function or frame is replaced or hooked. Selling is
  C_Container.UseContainerItem, which at a merchant sells; the repair is RepairAllItems. Every
  handler runs in pcall (the last error is kept for /gmerch status), every client API is checked
  with type(...) == "function" first, and a secret value is never compared or tested: it is
  treated as no value.
]]

local _G = _G
local ADDON_NAME = ...
ADDON_NAME = ADDON_NAME or "GaarMerchantForever"
local DOT = " \194\183 "
local VERSION = "1.2.0"

local BATCH = 3               -- items sold per step
local STEP = 0.2              -- seconds between steps
local POPUP = "GAARMERCHANTFOREVER_CONFIRM"

local DEFAULTS = { enabled = true, sellJunk = true, sellJunkConfirm = false,
    autoRepair = true, guildRepair = false, summary = true }

-- The switches /gmerch can flip, in menu order: saved key, what to type, label.
local FEATURES = {
    { key = "sellJunk", names = { "selljunk", "junk" }, label = "Sell junk at merchants" },
    { key = "sellJunkConfirm", names = { "selljunkconfirm", "confirm" }, label = "Ask before selling junk" },
    { key = "autoRepair", names = { "autorepair", "repair" }, label = "Auto repair" },
    { key = "guildRepair", names = { "guildrepair", "guild" }, label = "Repair from guild funds first" },
    { key = "summary", names = { "summary" }, label = "One-line summary" },
}

local db                      -- GaarMerchantForeverDB, bound at ADDON_LOADED
local merchantOpen = false
local queue                   -- items still to sell: { bag, slot, id, count, price }
local sale                    -- the running sale: { n, copper }
local pendingRepair           -- repair text held back until the sale finishes
local lastResult = "nothing yet"
local lastError

-- ---------------------------------------------------------------------------
-- Small helpers (the shared ones come from GaarForever's library, Lib.lua)
-- ---------------------------------------------------------------------------

local BF = _G.GaarForever
local IsSecret, Num, API, Call = BF.IsSecret, BF.Num, BF.API, BF.Call
local InCombat, OnOff = BF.InCombat, BF.OnOff
local A = BF.NewAddon("GaarMerchantForever", { title = "GaarMerchantForever", version = VERSION })

local function Print(msg) A:Print(msg) end

local function Fail(where, err)
    lastError = where .. ": " .. tostring(err)
end

local function Enabled() return db ~= nil and db.enabled ~= false end
local function Flag(key) return db ~= nil and db[key] == true end

-- Coin-icon money string (like Blizzard's "You gained: 46 [silver] 61 [copper]"). Falls back to
-- plain text such as "35g 5s 54c" (zero leading units omitted) when the engine has no coin API.
local function FormatMoney(copper)
    copper = math.floor(Num(copper) or 0)
    local s = Call(API("GetCoinTextureString"), copper) or Call(API("C_CurrencyInfo", "GetCoinTextureString"), copper)
    if type(s) == "string" and s ~= "" then return s end
    local g, sv, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local out = {}
    if g > 0 then out[#out + 1] = g .. "g" end
    if g > 0 or sv > 0 then out[#out + 1] = sv .. "s" end
    out[#out + 1] = c .. "c"
    return table.concat(out, " ")
end

-- ---------------------------------------------------------------------------
-- Bags and BBF locks
-- ---------------------------------------------------------------------------

local function LastBag()
    return Num(_G.NUM_TOTAL_EQUIPPED_BAG_SLOTS) or Num(_G.NUM_BAG_SLOTS) or 4
end

local function SlotCount(bag)
    local f = API("C_Container", "GetContainerNumSlots") or API("GetContainerNumSlots")
    return Num((Call(f, bag))) or 0
end

-- { itemID, quality, count } for a bag slot, or nil when empty or unreadable.
local function SlotItem(bag, slot)
    local c = _G.C_Container
    if type(c) == "table" and type(c.GetContainerItemInfo) == "function" then
        local ok, info = pcall(c.GetContainerItemInfo, bag, slot)
        if not ok or type(info) ~= "table" then return nil end
        local id, q = Num(info.itemID), Num(info.quality)
        if not id or not q then return nil end
        return id, q, Num(info.stackCount) or 1, info.hasNoValue == true
    end
    return nil
end

local function SellPrice(id)
    local f = API("C_Item", "GetItemInfo") or API("GetItemInfo")
    return Num((select(11, Call(f, id)))) or 0
end

-- Lock tables to read. A user can run the new GaarMerchantForever beside an old, not yet updated
-- BetterBagsForever, whose locks live in BetterBagsForeverCharDB; after the rename the old table
-- can also linger (it may carry __migratedTo). Reading both and taking the union is the safe side.
local function LockTables()
    local out = {}
    for _, name in ipairs({ "GaarBagsForeverCharDB", "BetterBagsForeverCharDB" }) do
        local cdb = _G[name]
        local items = type(cdb) == "table" and cdb.lockedItems
        if type(items) == "table" then out[#out + 1] = items end
    end
    return out
end

-- Whether Bags has this item locked. Read-only. Any "yes" wins: the new or old Bags API (an old
-- Bags has none), then both saved lock tables.
local function BBFLocked(id)
    for _, name in ipairs({ "GaarBagsForeverAPI", "BetterBagsForeverAPI" }) do
        local api = _G[name]
        if type(api) == "table" and type(api.IsItemLocked) == "function" then
            local ok, r = pcall(api.IsItemLocked, id)
            if ok and not IsSecret(r) and r then return true end
        end
    end
    for _, items in ipairs(LockTables()) do
        if items[id] ~= nil then return true end
    end
    return false
end

local function ScanJunk()
    local list, hasNoValue = {}, 0
    for bag = 0, LastBag() do
        for slot = 1, SlotCount(bag) do
            local id, q, count, noValue = SlotItem(bag, slot)
            if id and q == 0 and not BBFLocked(id) then
                if noValue then hasNoValue = hasNoValue + 1
                else list[#list + 1] = { bag = bag, slot = slot, id = id, count = count, price = SellPrice(id) } end
            end
        end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

-- parts: lines like "sold 5 junk items for 1g". Summary on: one line, else one per part.
local function Emit(parts)
    if #parts == 0 then return end
    lastResult = table.concat(parts, "; ")
    if Flag("summary") then
        Print(lastResult .. ".")
    else
        for _, p in ipairs(parts) do Print(p .. ".") end
    end
end

-- ---------------------------------------------------------------------------
-- Selling
-- ---------------------------------------------------------------------------

local stepper = CreateFrame("Frame")
local elapsed = 0
stepper:Hide()

local function FinishSale(closed)
    stepper:Hide()
    local s = sale
    queue, sale = nil, nil
    local parts = {}
    if pendingRepair then parts[#parts + 1] = pendingRepair; pendingRepair = nil end
    if s and s.n > 0 then
        parts[#parts + 1] = string.format("sold %d junk item%s for %s%s", s.n, s.n == 1 and "" or "s",
            FormatMoney(s.copper), closed and " (merchant closed early)" or "")
    end
    Emit(parts)
end

local function SellOne(it)
    -- Re-check right before selling: same grey item still there, not locked since the scan.
    local id, q = SlotItem(it.bag, it.slot)
    if id ~= it.id or q ~= 0 or BBFLocked(id) then return false end
    local f = API("C_Container", "UseContainerItem") or API("UseContainerItem")
    if not f then return false end
    return pcall(f, it.bag, it.slot) and true or false
end

stepper:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (Num(dt) or 0)
    if elapsed < STEP then return end
    elapsed = 0
    local ok, err = pcall(function()
        if not queue or not sale then stepper:Hide(); return end
        if not merchantOpen or InCombat() then FinishSale(not merchantOpen); return end
        for _ = 1, BATCH do
            local it = table.remove(queue, 1)
            if not it then break end
            if SellOne(it) then
                sale.n = sale.n + 1
                sale.copper = sale.copper + it.price * it.count
            end
        end
        if #queue == 0 then FinishSale(false) end
    end)
    if not ok then Fail("sell", err); queue, sale = nil, nil; stepper:Hide() end
end)

-- Starts selling `list`. Returns false when there is nothing to do.
local function StartSale(list)
    if sale then return false end
    if not merchantOpen then Print("open a merchant first."); return false end
    if InCombat() then Print("not in combat."); return false end
    if not list or #list == 0 then return false end
    queue, sale = list, { n = 0, copper = 0 }
    elapsed = STEP
    stepper:Show()
    return true
end

local function Estimate(list)
    local total = 0
    for _, it in ipairs(list) do total = total + it.price * it.count end
    return total
end

-- Popup before selling (sellJunkConfirm). The list is rescanned on accept.
local function AskSale(list)
    if type(_G.StaticPopupDialogs) ~= "table" or type(_G.StaticPopup_Show) ~= "function" then
        return StartSale(list)
    end
    _G.StaticPopupDialogs[POPUP] = {
        text = "%s", button1 = _G.YES or "Yes", button2 = _G.NO or "No",
        OnAccept = function()
            local ok, err = pcall(function() StartSale(ScanJunk()) end)
            if not ok then Fail("confirm", err) end
        end,
        timeout = 0, whileDead = false, hideOnEscape = true, preferredIndex = 3,
    }
    _G.StaticPopup_Show(POPUP, string.format("GaarMerchantForever: sell %d junk item%s for about %s?",
        #list, #list == 1 and "" or "s", FormatMoney(Estimate(list))))
    return true
end

-- ---------------------------------------------------------------------------
-- Repair
-- ---------------------------------------------------------------------------

-- Repairs if wanted and possible. Returns a text for the summary, or nil.
local function DoRepair()
    if not Flag("autoRepair") then return nil end
    if type(_G.CanMerchantRepair) ~= "function" or type(_G.GetRepairAllCost) ~= "function"
        or type(_G.RepairAllItems) ~= "function" then return nil end
    if not _G.CanMerchantRepair() then return nil end
    local cost = Num((_G.GetRepairAllCost()))
    if not cost or cost <= 0 then return nil end
    local money = type(_G.GetMoney) == "function" and Num(_G.GetMoney()) or nil

    if Flag("guildRepair") and type(_G.CanGuildBankRepair) == "function" and _G.CanGuildBankRepair() then
        local allow = type(_G.GetGuildBankWithdrawMoney) == "function" and Num(_G.GetGuildBankWithdrawMoney()) or nil
        if allow and (allow < 0 or allow >= cost) then
            _G.RepairAllItems(true)
            -- Verify shortly; if the guild refused, pay ourselves.
            if type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" then
                _G.C_Timer.After(0.6, function()
                    pcall(function()
                        if not merchantOpen then return end
                        local left = Num((_G.GetRepairAllCost()))
                        local m = type(_G.GetMoney) == "function" and Num(_G.GetMoney()) or nil
                        if left and left > 0 and m and m >= left then
                            _G.RepairAllItems()
                            Print("guild funds refused; repaired for " .. FormatMoney(left) .. " from your own money.")
                        end
                    end)
                end)
            end
            return "repaired for " .. FormatMoney(cost) .. " (guild funds)"
        end
    end

    if not money or money < cost then
        return "could not repair: need " .. FormatMoney(cost)
    end
    _G.RepairAllItems()
    return "repaired for " .. FormatMoney(cost)
end

-- ---------------------------------------------------------------------------
-- Merchant events
-- ---------------------------------------------------------------------------

-- Right-click the merchant window's round portrait: the addon's menu (hub helper, once).
local portraitMenu
local function AttachPortraitMenu()
    if portraitMenu or type(BF.AttachMenu) ~= "function" or type(_G.MerchantFrame) ~= "table" then return end
    portraitMenu = BF.AttachMenu(_G.MerchantFrame, { title = "GaarMerchantForever", api = "GaarMerchantForeverAPI",
        portrait = true, propagate = true, names = { "MerchantFramePortrait" }, name = "GaarMerchantForeverPortraitButton" })
end

local function OnMerchantShow()
    merchantOpen = true
    pcall(AttachPortraitMenu)
    if not Enabled() then return end
    pendingRepair = nil
    local repairText = DoRepair()
    local selling = false
    if Flag("sellJunk") and not InCombat() then
        local list = ScanJunk()
        if #list > 0 then
            if Flag("sellJunkConfirm") then
                AskSale(list)
            else
                pendingRepair = repairText
                selling = StartSale(list)
                if not selling then pendingRepair = nil end
            end
        end
    end
    if not selling then Emit(repairText and { repairText } or {}) end
end

local function OnMerchantClosed()
    merchantOpen = false
    if type(_G.StaticPopup_Hide) == "function" then pcall(_G.StaticPopup_Hide, POPUP) end
    if sale then FinishSale(true) end
    pendingRepair = nil
end

local function SellNow()
    if not merchantOpen then Print("open a merchant first."); return end
    if sale then Print("already selling."); return end
    if InCombat() then Print("not in combat."); return end
    local list = ScanJunk()
    if #list == 0 then Print("no junk to sell (locked items are skipped)."); return end
    StartSale(list)
end

-- ---------------------------------------------------------------------------
-- Settings and slash command
-- ---------------------------------------------------------------------------

local function SetFlag(key, v)
    if db then db[key] = v and true or false end
end

local function SetEnabled(v)
    SetFlag("enabled", v)
    if not v and sale then FinishSale(false) end
    Print("addon " .. OnOff(Enabled()) .. ".")
end

local function FindFeature(word)
    word = (word or ""):lower()
    for _, f in ipairs(FEATURES) do
        for _, n in ipairs(f.names) do
            if n == word then return f end
        end
    end
end

-- The intro GaarForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "At a merchant it sells your grey items and repairs your gear, optionally with guild funds, and sums it up in one chat line. Nice to know: items you locked in GaarBagsForever (Alt-click) are never sold; selling stops in combat or when the merchant closes; /gmerch sell sells the junk on demand."

local function PrintHelp()
    Print("Right-click the merchant window's round portrait (top-left): this addon's menu (the same options as the hub menu).")
    Print(INTRO)
    Print("/gmerch on | off - master switch (now " .. OnOff(Enabled()) .. ")")
    Print("/gmerch sell - sell the junk now (merchant must be open)")
    Print("/gmerch junk | confirm | repair | guild | summary on|off - one feature each")
    Print("/gmerch status - settings and last result")
end

local function PrintStatus()
    Print("version " .. VERSION .. DOT .. "addon " .. OnOff(Enabled()))
    for _, f in ipairs(FEATURES) do
        Print(f.label .. ": " .. OnOff(Flag(f.key)) .. "   (/gmerch " .. f.names[#f.names] .. " on|off)")
    end
    local seen, n, any = {}, 0, false
    for _, items in ipairs(LockTables()) do
        any = true
        for id in pairs(items) do
            if not seen[id] then seen[id] = true; n = n + 1 end
        end
    end
    Print("Bags locks: " .. (any and (n .. " locked item(s), skipped when selling") or "none found"))
    Print("merchant open: " .. OnOff(merchantOpen) .. DOT .. "selling: " .. (sale and "yes" or "no"))
    Print("last result: " .. lastResult)
    if lastError then Print("last error: " .. lastError) end
end

local function OnSlash(msg)
    local ok, err = pcall(function()
        if not db then Print("not loaded yet."); return end
        local cmd, arg = (msg or ""):match("^(%S+)%s*(.*)$")
        cmd = (cmd or ""):lower()
        arg = (arg or ""):lower()
        if cmd == "on" or cmd == "off" then
            SetEnabled(cmd == "on")
        elseif cmd == "sell" then
            SellNow()
        elseif cmd == "status" then
            PrintStatus()
        elseif FindFeature(cmd) then
            local f = FindFeature(cmd)
            if arg == "on" or arg == "off" then
                SetFlag(f.key, arg == "on")
                Print(f.label .. ": " .. OnOff(Flag(f.key)) .. ".")
            else
                Print(f.label .. " is " .. OnOff(Flag(f.key)) .. ". /gmerch " .. cmd .. " on|off")
            end
        else
            PrintHelp()
        end
    end)
    if not ok then Fail("slash", err); Print("error: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Public API: GaarMerchantForeverAPI
--
-- For GaarForever, the family hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in GaarMerchantForeverDB and change only through the
-- same functions /gmerch uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "on · junk on · repair on · guild off"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func },
--                        { text, radio = true, checked, func }, { text, submenu } and
--                        { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    return OnOff(Enabled()) .. DOT .. "junk " .. OnOff(Flag("sellJunk")) .. (Flag("sellJunkConfirm") and " (asks)" or "")
        .. DOT .. "repair " .. OnOff(Flag("autoRepair")) .. DOT .. "guild " .. OnOff(Flag("guildRepair"))
        .. DOT .. "summary " .. OnOff(Flag("summary"))
end

local function MenuEntries()
    if not db then return {} end
    local entries = {
        { text = "Merchant helper", checkbox = true, checked = Enabled,
          func = function() SetEnabled(not Enabled()) end },
        { divider = true },
    }
    for _, f in ipairs(FEATURES) do
        entries[#entries + 1] = { text = f.label, checkbox = true,
            checked = function() return Flag(f.key) end,
            func = function() SetFlag(f.key, not Flag(f.key)) end }
    end
    entries[#entries + 1] = { divider = true }
    entries[#entries + 1] = { text = "Sell junk now (at a merchant)", func = SellNow }
    return entries
end

_G.GaarMerchantForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries(), A.title) end,
    SetMinimapHidden = function() end,
}
_G.BetterMerchantForeverAPI = _G.GaarMerchantForeverAPI -- the name before the folder rename

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    BF.Migrate("GaarMerchantForeverDB", "BetterMerchantForeverDB") -- the old folder's settings, once (see Lib.lua)
    if type(GaarMerchantForeverDB) ~= "table" then GaarMerchantForeverDB = {} end
    db = GaarMerchantForeverDB
    for k in pairs(db) do
        if DEFAULTS[k] == nil then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if type(db[k]) ~= "boolean" then db[k] = v end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_CLOSED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:SetScript("OnEvent", function(_, event, arg1)
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then BindSavedVariables() end
        elseif not db then
            return
        elseif event == "MERCHANT_SHOW" then
            OnMerchantShow()
        elseif event == "MERCHANT_CLOSED" then
            OnMerchantClosed()
        elseif event == "PLAYER_REGEN_DISABLED" then
            if sale then FinishSale(false) end
        end
    end)
    if not ok then Fail(event, err) end
end)

SLASH_GAARMERCHANTFOREVER1 = "/gmerch"
SLASH_GAARMERCHANTFOREVER2 = "/gaarmerchantforever"
SLASH_GAARMERCHANTFOREVER3 = "/bmerch" -- the command before the Gaar rename
SLASH_GAARMERCHANTFOREVER4 = "/bettermerchantforever"
SlashCmdList.GAARMERCHANTFOREVER = OnSlash
