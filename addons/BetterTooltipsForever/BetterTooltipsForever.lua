--[[
  BetterTooltipsForever - better item and unit tooltips on WoW Forever.

  Item tooltips:
    vendorPrice (on)   vendor sell price, per item and for the stack, or "No sell price".
    itemId      (off)  item ID (spell ID on spell tooltips).
    itemLevel   (on)   item level of equippable items.
    compare     (on)   "vs equipped" diff of the top stats against the item in the slot.
  Unit tooltips:
    target      (on)   "Target: <name>", class coloured, YOU in red when it targets you.
    guildRank   (on)   guild rank next to the guild name of players.
    health      (on)   health value and percent.
    classColor  (on)   class coloured player names and tooltip border.
    anchor      (off)  tooltip follows the cursor instead of the default corner.

  Every feature has its own saved setting, /btip <feature> on|off and an entry in
  BetterTooltipsForeverAPI.MenuEntries(); /btip on|off is the master switch.

  Hooking: TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item / Unit / Spell) where
  the client has it, else GameTooltip:HookScript("OnTooltipSetItem" / "OnTooltipSetUnit") (also on
  ItemRefTooltip for items). Only GameTooltip and ItemRefTooltip are touched; the shopping
  (compare) tooltips stay as Blizzard does them. Blizzard code is only followed, never replaced.

  Shared helpers come from BetterForever's library (global BetterForever, Lib.lua, loaded first
  through ## Dependencies): the chat prefix, Plain / Num / Str and the menu drawing.

  Secret values (12.x engine): every value read from the client goes through Plain(), which
  returns nil for a secret value; a secret is never compared, tested, formatted or concatenated.
  A line whose value is secret is simply skipped. Every handler runs in pcall (the last error is
  kept for /btip status) and every client API is checked with type(...) == "function".

  BetterTooltipsForeverAPI: version, StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden,
  in the shape BetterForever's hub expects.
]]

local _G = _G
local ADDON_NAME = ...
ADDON_NAME = ADDON_NAME or "BetterTooltipsForever"
local DOT = " \194\183 "
local VERSION = "1.0.2"

local BF = _G.BetterForever
local A = BF.NewAddon(ADDON_NAME, { version = VERSION })

-- key, default, menu label, help text. Order = menu and status order.
local FEATURES = {
    { key = "vendorPrice", default = true,  label = "Vendor price",          help = "vendor sell price, per item and stack" },
    { key = "itemId",      default = false, label = "Item / spell ID",       help = "item ID (and spell ID)" },
    { key = "itemLevel",   default = true,  label = "Item level",            help = "item level of equippable items" },
    { key = "compare",     default = true,  label = "Compare with equipped", help = "stat diff versus the equipped item" },
    { key = "target",      default = true,  label = "Unit target",           help = "who the unit is targeting" },
    { key = "guildRank",   default = true,  label = "Guild rank",            help = "guild rank of players" },
    { key = "health",      default = true,  label = "Unit health",           help = "health value and percent" },
    { key = "classColor",  default = true,  label = "Class colours",         help = "class coloured name and border" },
    { key = "anchor",      default = false, label = "Anchor at cursor",      help = "tooltip follows the cursor" },
}
local FEATURE = {}
for _, f in ipairs(FEATURES) do FEATURE[f.key] = f end

local db            -- BetterTooltipsForeverDB, bound at ADDON_LOADED
local lastError

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Print(msg) A:Print(msg) end

-- Plain: nil for a secret value, else the value. The only place a client value is first touched.
local Plain, Num, Str = BF.Plain, BF.Num, BF.Str

-- The first return value only, and plain: nil on an error, when fn is missing or when secret
-- (the library's Call hands back every result as it is).
local function Call(fn, ...) return Plain((BF.Call(fn, ...))) end

local function Fail(where, err)
    lastError = tostring(where) .. ": " .. tostring(err)
end

local function Enabled(key)
    if not db or not db.enabled then return false end
    if key then return db[key] == true end
    return true
end

local function Commas(n)
    if type(_G.BreakUpLargeNumbers) == "function" then
        local ok, s = pcall(_G.BreakUpLargeNumbers, n)
        if ok and type(s) == "string" then return s end
    end
    return tostring(n)
end

local function Coin(copper)
    local C = _G.C_CurrencyInfo
    local fn = type(C) == "table" and C.GetCoinTextureString or _G.GetCoinTextureString
    if type(fn) == "function" then
        local ok, s = pcall(fn, copper)
        if ok and type(s) == "string" then return s end
    end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    return string.format("%dg %ds %dc", g, s, c)
end

local function IsAllowedTooltip(tt)
    return tt ~= nil and (tt == _G.GameTooltip or tt == _G.ItemRefTooltip)
end

local function AddLine(tt, text, r, g, b)
    if type(tt.AddLine) == "function" then tt:AddLine(text, r or 1, g or 1, b or 1) end
end

local function AddDouble(tt, left, right, lr, lg, lb, rr, rg, rb)
    if type(tt.AddDoubleLine) == "function" then
        tt:AddDoubleLine(left, right, lr or 1, lg or 1, lb or 1, rr or 1, rg or 1, rb or 1)
    end
end

local function LineText(tt, i, side)
    local name = tt.GetName and tt:GetName()
    local fs = name and _G[name .. (side or "TextLeft") .. i]
    if fs and type(fs.GetText) == "function" then return Str(fs:GetText()), fs end
end

-- Whether some left line of the tooltip matches plain text `needle` (never touches a secret).
local function HasLineWith(tt, needle)
    local n = Num(type(tt.NumLines) == "function" and tt:NumLines())
    if not n then return false end
    for i = 1, n do
        local t = LineText(tt, i)
        if t and t:find(needle, 1, true) then return true end
    end
    return false
end

local function ClassRGB(file)
    file = Str(file)
    if not file then return nil end
    local C = _G.C_ClassColor
    if type(C) == "table" and type(C.GetClassColor) == "function" then
        local ok, c = pcall(C.GetClassColor, file)
        if ok and type(c) == "table" and Num(c.r) then return c.r, c.g, c.b end
    end
    local t = _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[file]
    if t and Num(t.r) then return t.r, t.g, t.b end
end

local function Hex(r, g, b)
    return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- ---------------------------------------------------------------------------
-- Item tooltips
-- ---------------------------------------------------------------------------

local SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16, 17 },
    INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_SHIELD = { 17 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 },
    INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}

local function ItemInfo(link)
    local C = _G.C_Item
    local fn = type(C) == "table" and C.GetItemInfo or _G.GetItemInfo
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g, h, i, j, k = pcall(fn, link)
    if not ok then return nil end
    return { name = Str(a), quality = Num(c), ilvl = Num(d), equipLoc = Str(i), sell = Num(k) }
end

local function EquipLoc(link)
    local C = _G.C_Item
    local fn = type(C) == "table" and C.GetItemInfoInstant or _G.GetItemInfoInstant
    if type(fn) ~= "function" then return nil end
    local ok, _, _, _, loc = pcall(fn, link)
    if ok then return Str(loc) end
end

local function ItemStats(link)
    local C = _G.C_Item
    local fn = type(C) == "table" and C.GetItemStats or _G.GetItemStats
    if type(fn) ~= "function" then return nil end
    local ok, t = pcall(fn, link)
    if ok and type(t) == "table" then return t end
end

local function ItemLinkOf(tt, data)
    local link
    if type(tt.GetItem) == "function" then
        local ok, _, l = pcall(tt.GetItem, tt)
        if ok then link = Str(l) end
    end
    if not link and type(data) == "table" then link = Str(data.hyperlink) end
    return link
end

-- Item ID from the link (never from a secret).
local function ItemIdOf(link, data)
    local id = type(data) == "table" and Num(data.id) or nil
    if id then return id end
    return Num(tonumber(link:match("item:(%d+)")))
end

-- Stack size of the bag slot under the cursor, when it holds this item.
local function HoveredCount(itemId)
    local focus
    if type(_G.GetMouseFoci) == "function" then
        local ok, t = pcall(_G.GetMouseFoci)
        if ok and type(t) == "table" then focus = t[1] end
    elseif type(_G.GetMouseFocus) == "function" then
        local ok, f = pcall(_G.GetMouseFocus)
        if ok then focus = f end
    end
    if type(focus) ~= "table" or type(focus.GetID) ~= "function" then return nil end
    local bag
    if type(focus.GetBagID) == "function" then
        bag = Num(Call(focus.GetBagID, focus))
    else
        local p = type(focus.GetParent) == "function" and Call(focus.GetParent, focus)
        if type(p) == "table" and type(p.GetID) == "function" then bag = Num(Call(p.GetID, p)) end
    end
    local slot = Num(Call(focus.GetID, focus))
    if not bag or not slot then return nil end
    local C = _G.C_Container
    if type(C) == "table" and type(C.GetContainerItemInfo) == "function" then
        local ok, info = pcall(C.GetContainerItemInfo, bag, slot)
        if ok and type(info) == "table" and Num(info.itemID) == itemId then return Num(info.stackCount) end
    end
end

local function ShowsSellPrice(tt, data)
    if Num(tt.shownMoneyFrames) and tt.shownMoneyFrames > 0 then return true end
    local sp = _G.Enum and _G.Enum.TooltipDataLineType and _G.Enum.TooltipDataLineType.SellPrice
    if sp and type(data) == "table" and type(data.lines) == "table" then
        for _, l in ipairs(data.lines) do
            if type(l) == "table" and Num(l.type) == sp then return true end
        end
    end
    local label = _G.SELL_PRICE
    if type(label) == "string" and HasLineWith(tt, label) then return true end
    return false
end

local function DoVendorPrice(tt, data, link, itemId, info)
    if not Enabled("vendorPrice") or not info or ShowsSellPrice(tt, data) then return end
    local sell = info.sell
    if sell == nil then return end
    if sell <= 0 then
        AddLine(tt, "No sell price", 0.6, 0.6, 0.6)
        return
    end
    local count = tt == _G.GameTooltip and itemId and HoveredCount(itemId) or nil
    if count and count > 1 then
        AddDouble(tt, "Sell price (" .. count .. "):", Coin(sell * count), 1, 1, 1)
        AddDouble(tt, "Each:", Coin(sell), 0.7, 0.7, 0.7)
    else
        AddDouble(tt, "Sell price:", Coin(sell), 1, 1, 1)
    end
end

local function DoItemId(tt, itemId)
    if Enabled("itemId") and itemId then AddLine(tt, "Item ID: " .. itemId, 0.5, 0.5, 0.9) end
end

local function DoItemLevel(tt, link, info)
    if not Enabled("itemLevel") or not info or not info.ilvl or info.ilvl <= 0 then return end
    local loc = info.equipLoc or EquipLoc(link)
    if not loc or loc == "" or loc == "INVTYPE_BAG" or loc == "INVTYPE_NON_EQUIP_IGNORE" then return end
    local label = type(_G.ITEM_LEVEL) == "string" and _G.ITEM_LEVEL:match("^(.-)%%d") or "Item Level "
    if label ~= "" and HasLineWith(tt, label) then return end
    AddLine(tt, "Item level: " .. info.ilvl, 1, 0.82, 0)
end

local function StatLabel(key)
    local g = Str(_G[key])
    if g then return g end
    return (key:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):gsub("_", " "):lower())
end

local function DoCompare(tt, link, info)
    if not Enabled("compare") then return end
    if type(_G.IsEquippedItem) == "function" and Call(_G.IsEquippedItem, link) then return end
    local loc = (info and info.equipLoc) or EquipLoc(link)
    local slots = loc and SLOTS[loc]
    if not slots or type(_G.GetInventoryItemLink) ~= "function" then return end
    local equipped
    for _, slot in ipairs(slots) do
        local l = Str(Call(_G.GetInventoryItemLink, "player", slot))
        if l then equipped = l break end
    end
    if not equipped then return end
    local new, old = ItemStats(link), ItemStats(equipped)
    if not new or not old then return end
    local diffs, seen = {}, {}
    local function consider(key)
        if seen[key] then return end
        seen[key] = true
        local a, b = Num(new[key]) or 0, Num(old[key]) or 0
        local d = a - b
        if math.abs(d) > 0.0001 then diffs[#diffs + 1] = { key = key, d = d } end
    end
    for k in pairs(new) do consider(k) end
    for k in pairs(old) do consider(k) end
    if #diffs == 0 then return end
    table.sort(diffs, function(x, y)
        local ax, ay = math.abs(x.d), math.abs(y.d)
        if ax ~= ay then return ax > ay end
        return x.key < y.key
    end)
    AddLine(tt, "vs equipped:", 0.7, 0.7, 0.7)
    for i = 1, math.min(5, #diffs) do
        local e = diffs[i]
        local n = e.d
        local text = (math.abs(n - math.floor(n)) < 0.0001) and string.format("%+d", n) or string.format("%+.1f", n)
        if e.d > 0 then
            AddLine(tt, text .. " " .. StatLabel(e.key), 0.1, 1, 0.1)
        else
            AddLine(tt, text .. " " .. StatLabel(e.key), 1, 0.2, 0.2)
        end
    end
end

local function OnItem(tt, data)
    if not Enabled() or not IsAllowedTooltip(tt) then return end
    if tt.btipItem then return end
    local link = ItemLinkOf(tt, data)
    if not link then return end
    tt.btipItem = true
    local info = ItemInfo(link)
    local itemId = ItemIdOf(link, data)
    local function step(name, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then Fail(name, err) end
    end
    step("itemLevel", DoItemLevel, tt, link, info)
    step("compare", DoCompare, tt, link, info)
    step("vendorPrice", DoVendorPrice, tt, data, link, itemId, info)
    step("itemId", DoItemId, tt, itemId)
    if type(tt.Show) == "function" then tt:Show() end  -- resize for the new lines
end

local function OnSpell(tt, data)
    if not Enabled("itemId") or not IsAllowedTooltip(tt) or tt.btipSpell then return end
    local id = type(data) == "table" and Num(data.id) or nil
    if not id and type(tt.GetSpell) == "function" then
        local ok, _, sid = pcall(tt.GetSpell, tt)
        if ok then id = Num(sid) end
    end
    if not id then return end
    tt.btipSpell = true
    AddLine(tt, "Spell ID: " .. id, 0.5, 0.5, 0.9)
    if type(tt.Show) == "function" then tt:Show() end
end

-- ---------------------------------------------------------------------------
-- Unit tooltips
-- ---------------------------------------------------------------------------

local DEFAULT_BORDER = { 1, 1, 1 }

local function SetBorder(tt, r, g, b)
    local ns = tt.NineSlice
    if type(ns) == "table" and type(ns.SetBorderColor) == "function" then
        ns:SetBorderColor(r, g, b, 1)
    elseif type(tt.SetBackdropBorderColor) == "function" then
        tt:SetBackdropBorderColor(r, g, b, 1)
    end
end

local function UnitOf(tt, data)
    local unit
    if type(tt.GetUnit) == "function" then
        local ok, _, u = pcall(tt.GetUnit, tt)
        if ok then unit = Str(u) end
    end
    if not unit and Call(_G.UnitExists, "mouseover") then unit = "mouseover" end
    return unit
end

local function ClassFileOf(unit)
    if type(_G.UnitClass) ~= "function" then return nil end
    local ok, _, file = pcall(_G.UnitClass, unit)
    if ok then return Str(file) end
end

local function DoClassColor(tt, unit)
    if not Enabled("classColor") then return end
    if Call(_G.UnitIsPlayer, unit) ~= true then return end
    local r, g, b = ClassRGB(ClassFileOf(unit))
    if not r then return end
    local _, fs = LineText(tt, 1)
    if fs and type(fs.SetTextColor) == "function" then fs:SetTextColor(r, g, b) end
    SetBorder(tt, r, g, b)
    tt.btipBorder = true
end

local function DoGuildRank(tt, unit)
    if not Enabled("guildRank") then return end
    if Call(_G.UnitIsPlayer, unit) ~= true or type(_G.GetGuildInfo) ~= "function" then return end
    local ok, guild, rank = pcall(_G.GetGuildInfo, unit)
    guild, rank = ok and Str(guild) or nil, ok and Str(rank) or nil
    if not guild or not rank then return end
    local n = Num(type(tt.NumLines) == "function" and tt:NumLines()) or 0
    for i = 2, math.min(n, 4) do
        local t, fs = LineText(tt, i)
        if t and t:sub(1, 1) == "<" and t:find(guild, 1, true) and fs and type(fs.SetText) == "function" then
            fs:SetText(t .. " - |cffaaaaaa" .. rank .. "|r")
            return
        end
    end
    AddLine(tt, "<" .. guild .. "> - " .. rank, 0, 0.9, 0.5)
end

local function DoHealth(tt, unit)
    if not Enabled("health") then return end
    local hp, mx = Num(Call(_G.UnitHealth, unit)), Num(Call(_G.UnitHealthMax, unit))
    if hp and mx and mx > 0 then
        AddLine(tt, string.format("Health: %s / %s (%d%%)", Commas(hp), Commas(mx), math.floor(hp / mx * 100 + 0.5)), 0.4, 1, 0.4)
        return
    end
    if type(_G.UnitHealthPercent) == "function" then
        local scale = _G.CurveConstants and _G.CurveConstants.ScaleTo100
        local pct = scale and Num(Call(_G.UnitHealthPercent, unit, true, scale))
        if pct then AddLine(tt, string.format("Health: %d%%", math.floor(pct + 0.5)), 0.4, 1, 0.4) end
    end
end

local function DoTarget(tt, unit)
    if not Enabled("target") then return end
    local t = unit .. "target"
    if Call(_G.UnitExists, t) ~= true then return end
    local name = Str(Call(_G.UnitName, t))
    if not name then return end
    if Call(_G.UnitIsUnit, t, "player") == true then
        AddLine(tt, "Target: |cffff2020YOU|r", 1, 1, 1)
        return
    end
    local text = name
    if Call(_G.UnitIsPlayer, t) == true then
        local r, g, b = ClassRGB(ClassFileOf(t))
        if r then text = Hex(r, g, b) .. name .. "|r" end
    end
    AddLine(tt, "Target: " .. text, 1, 1, 1)
end

local function OnUnit(tt, data)
    if not Enabled() or not IsAllowedTooltip(tt) or tt.btipUnit then return end
    local unit = UnitOf(tt, data)
    if not unit then return end
    tt.btipUnit = true
    for _, s in ipairs({
        { "classColor", DoClassColor }, { "guildRank", DoGuildRank },
        { "health", DoHealth }, { "target", DoTarget },
    }) do
        local ok, err = pcall(s[2], tt, unit)
        if not ok then Fail(s[1], err) end
    end
    if type(tt.Show) == "function" then tt:Show() end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

local function Safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then Fail(name, err) end
    end
end

local function ResetTooltip(tt)
    tt.btipItem, tt.btipUnit, tt.btipSpell = nil, nil, nil
    if tt.btipBorder then
        tt.btipBorder = nil
        SetBorder(tt, DEFAULT_BORDER[1], DEFAULT_BORDER[2], DEFAULT_BORDER[3])
    end
end

local hookMethod = "none"

local function InstallHooks()
    for _, name in ipairs({ "GameTooltip", "ItemRefTooltip" }) do
        local tt = _G[name]
        if tt and type(tt.HookScript) == "function" then
            pcall(tt.HookScript, tt, "OnTooltipCleared", Safe("clear", ResetTooltip))
        end
    end

    local TDP, E = _G.TooltipDataProcessor, _G.Enum and _G.Enum.TooltipDataType
    if type(TDP) == "table" and type(TDP.AddTooltipPostCall) == "function" and type(E) == "table" and E.Item and E.Unit then
        TDP.AddTooltipPostCall(E.Item, Safe("item", OnItem))
        TDP.AddTooltipPostCall(E.Unit, Safe("unit", OnUnit))
        if E.Spell then TDP.AddTooltipPostCall(E.Spell, Safe("spell", OnSpell)) end
        hookMethod = "TooltipDataProcessor"
    else
        local gt = _G.GameTooltip
        if gt and type(gt.HookScript) == "function" then
            gt:HookScript("OnTooltipSetItem", Safe("item", OnItem))
            gt:HookScript("OnTooltipSetUnit", Safe("unit", OnUnit))
            gt:HookScript("OnTooltipSetSpell", Safe("spell", OnSpell))
        end
        local ref = _G.ItemRefTooltip
        if ref and type(ref.HookScript) == "function" then
            ref:HookScript("OnTooltipSetItem", Safe("item", OnItem))
        end
        hookMethod = "HookScript"
    end

    if type(_G.hooksecurefunc) == "function" and type(_G.GameTooltip_SetDefaultAnchor) == "function" then
        hooksecurefunc("GameTooltip_SetDefaultAnchor", Safe("anchor", function(tt, parent)
            if tt ~= _G.GameTooltip or not Enabled("anchor") then return end
            if type(tt.SetOwner) == "function" and parent then tt:SetOwner(parent, "ANCHOR_CURSOR") end
        end))
    end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function OnOff(v) return v and "|cff00ff00on|r" or "|cffff5555off|r" end

local function SetFeature(key, on)
    if not db then return end
    db[key] = on and true or false
end

local function SetMaster(on)
    if db then db.enabled = on and true or false end
end

local function PrintStatus()
    Print("v" .. VERSION .. DOT .. "master " .. OnOff(db.enabled) .. DOT .. "hook: " .. hookMethod)
    for _, f in ipairs(FEATURES) do
        Print("  " .. f.key .. ": " .. OnOff(db[f.key]) .. " (" .. f.help .. ")")
    end
    if lastError then Print("last error: " .. lastError) end
end

-- The intro BetterForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "Adds useful lines to item and unit tooltips: vendor price, item level, a comparison with what you wear, the unit's target, guild rank and health. Every line has its own switch. Nice to know: /btip <feature> on|off (/btip status lists them); item and spell IDs are off by default."

local function PrintHelp()
    Print(INTRO)
    Print("v" .. VERSION)
    Print("  /btip on | off              master switch")
    Print("  /btip <feature> on | off    switch one feature (no argument toggles it)")
    Print("  /btip status                settings, hook method, last error")
    Print("  features: " .. (function()
        local t = {}
        for _, f in ipairs(FEATURES) do t[#t + 1] = f.key end
        return table.concat(t, ", ")
    end)())
end

local function OnSlash(msg)
    local ok, err = pcall(function()
        if not db then Print("not loaded yet.") return end
        local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
        if cmd == "on" or cmd == "off" then
            SetMaster(cmd == "on")
            Print("master " .. OnOff(db.enabled))
        elseif cmd == "status" then
            PrintStatus()
        else
            -- keys are camelCase and the message is lowercased: match case-insensitively.
            for _, f in ipairs(FEATURES) do
                if f.key:lower() == cmd then
                    local on
                    if arg == "on" then on = true elseif arg == "off" then on = false else on = not db[f.key] end
                    SetFeature(f.key, on)
                    Print(f.key .. " " .. OnOff(db[f.key]))
                    return
                end
            end
            PrintHelp()
        end
    end)
    if not ok then Fail("slash", err) Print("error: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterTooltipsForeverAPI (for BetterForever's hub)
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    local n = 0
    for _, f in ipairs(FEATURES) do if db[f.key] then n = n + 1 end end
    return (db.enabled and "on" or "off") .. DOT .. n .. "/" .. #FEATURES .. " features"
end

local function MenuEntries()
    if not db then return {} end
    local entries = {
        { text = "Better tooltips", checkbox = true,
          checked = function() return db.enabled end,
          func = function() SetMaster(not db.enabled) end },
        { divider = true },
    }
    for _, f in ipairs(FEATURES) do
        entries[#entries + 1] = { text = f.label, checkbox = true,
            checked = function() return db[f.key] == true end,
            func = function() SetFeature(f.key, not db[f.key]) end }
    end
    return entries
end


_G.BetterTooltipsForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries()) end,
    SetMinimapHidden = function() end,
}

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterTooltipsForeverDB) ~= "table" then BetterTooltipsForeverDB = {} end
    db = BetterTooltipsForeverDB
    for k in pairs(db) do
        if k ~= "enabled" and not FEATURE[k] then db[k] = nil end
    end
    if type(db.enabled) ~= "boolean" then db.enabled = true end
    for _, f in ipairs(FEATURES) do
        if type(db[f.key]) ~= "boolean" then db[f.key] = f.default end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, arg1)
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then BindSavedVariables() end
        elseif event == "PLAYER_LOGIN" then
            InstallHooks()
        end
    end)
    if not ok then Fail(event, err) end
end)

SLASH_BETTERTOOLTIPSFOREVER1 = "/btip"
SLASH_BETTERTOOLTIPSFOREVER2 = "/bettertooltipsforever"
SlashCmdList.BETTERTOOLTIPSFOREVER = OnSlash
