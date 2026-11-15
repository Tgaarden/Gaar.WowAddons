--[[
  BetterForever - the hub's tools (3.1): what's new, per-character profiles, settings export /
  import and the API self-test. Loaded before Core.lua, which calls these through the addon's
  private namespace (ns.Tools) and hands in its saved variables at ADDON_LOADED (Tools.Bind).

  What's new
    BetterForeverDB.seen = { [addon name] = "last version seen" }. At login every installed
    family addon's version (its API table's version, else the TOC's ## Version) is compared with
    the one seen last; a newer one gives one chat line,
      BetterForever: updated - BetterBuffsForever 1.5.1 -> 1.6.0: <note>
    with the note from CHANGES below (only when it is written for that exact version; otherwise
    just the versions). The first login with this feature only records the versions. An addon
    installed later is announced as new. /bf news reprints the last block; /bf news on|off
    switches the lines (versions are still recorded while it is off).

  Profiles, export, import
    For addons built on the library's A:InitDB (see Lib.lua, "Per-character settings"):
    /bf profile, /bf profile char|shared <addon|all>, /bf export <addon>, /bf import.

  Self-test
    /bf selftest probes, each call in pcall, the client APIs the family relies on, on player,
    target and party1, and records ok / nil / secret / error per call. It runs now and once more
    on the other side of the next combat change (entering combat after an out-of-combat run),
    then shows both side by side in a copyable text window. /bf selftest show reopens the window.
]]

local _G = _G
local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Lib = _G.BetterForever

local Tools = {}
ns.Tools = Tools

local IsSecret, Str, Num = Lib.IsSecret, Lib.Str, Lib.Num
local ARROW = " \226\134\146 "  -- " → "
local EM_DASH = "\226\128\148"   -- "—"

local hub        -- { db, ADDONS, VERSION, Print, API } from Core.lua
local function Print(msg) if hub then hub.Print(msg) end end

-- ---------------------------------------------------------------------------
-- Change notes, written by hand from the git history: the newest note per addon, keyed by the
-- version it belongs to. A version not listed here is announced without a note.
-- ---------------------------------------------------------------------------

local CHANGES = {
    BetterForever = {
        ["3.1.1"] = "notes for every addon's current version",
        ["3.1.0"] = "what's new on login, per-character settings, export / import, /bf selftest",
        ["3.0.2"] = "a Loot row for BetterLootForever",
    },
    BetterBagsForever = {
        ["1.9.3"] = "the addon's own name in its menu errors",
        ["1.9.2"] = "shared helpers from the BetterForever library",
    },
    BetterQuestsForever = {
        ["1.10.3"] = "the addon's own name in its menu errors",
        ["1.10.2"] = "uses the BetterForever shared library",
    },
    BetterMapsForever = {
        ["1.1.3"] = "the addon's own name in its chat lines and menu errors",
        ["1.1.2"] = "uses the BetterForever shared library",
    },
    BetterCastbarsForever = {
        ["1.1.6"] = "the addon's own name in its menu errors",
        ["1.1.5"] = "uses the BetterForever shared library",
    },
    BetterPlatesForever = {
        ["1.2.12"] = "the addon's own name in its menu errors",
        ["1.2.11"] = "secret-safe value checks",
    },
    BetterGpsForever = {
        ["1.2.3"] = "the addon's own name in its menu errors",
        ["1.2.2"] = "shared helpers from the BetterForever library",
    },
    BetterFramesForever = {
        ["1.2.16"] = "the addon's own name in its menu errors",
        ["1.2.15"] = "the addon's own name in its chat lines and menu errors",
        ["1.2.14"] = "secret-safe value checks",
    },
    BetterWindowsForever = {
        ["1.0.3"] = "the addon's own name in its menu errors",
        ["1.0.2"] = "uses the BetterForever shared library",
    },
    BetterFishingForever = {
        ["1.4.1"] = "the addon's own name in its menu errors",
        ["1.4.0"] = "session stats panel, loud splash mode",
        ["1.3.0"] = "reel in with double right-click, Cast / Reel key",
        ["1.2.2"] = "uses the BetterForever shared library",
    },
    BetterBuffsForever = {
        ["1.6.0"] = "combat dispel icons, lower rank for low-level members, expiring-soon warning /bbuff expire, out-of-range sound fix",
        ["1.5.1"] = "out-of-range members left out unless /bbuff range on",
        ["1.5.0"] = "Fortitude for priests, Arcane Intellect for mages",
        ["1.4.0"] = "dispel panel for priests, paladins and mages",
        ["1.3.0"] = "Shaman support (imbue, Lightning Shield, reagents, dispel)",
    },
    BetterMerchantForever = {
        ["1.0.3"] = "the addon's own name in its menu errors",
        ["1.0.2"] = "shared helpers from the BetterForever library",
    },
    BetterTooltipsForever = {
        ["1.0.4"] = "the addon's own name in its menu errors",
        ["1.0.3"] = "the addon's own name in its chat lines",
    },
    BetterMailForever = {
        ["1.0.3"] = "the addon's own name in its chat lines and menu errors",
        ["1.0.2"] = "uses the BetterForever shared library",
    },
    BetterXPForever = {
        ["1.0.4"] = "the addon's own name in its menu errors",
        ["1.0.3"] = "the addon's own name in its chat lines",
    },
    BetterChatForever = {
        ["1.0.4"] = "the addon's own name in its menu errors",
        ["1.0.3"] = "the addon's own name in its chat lines",
    },
    BetterBarsForever = {
        ["1.0.4"] = "the addon's own name in its menu errors",
        ["1.0.3"] = "the addon's own name in its chat lines",
    },
    BetterLootForever = {
        ["1.1.0"] = "roll result summary panel",
        ["1.0.0"] = "Need / Greed / Pass counts on group loot rolls",
    },
}
Tools.CHANGES = CHANGES

-- ---------------------------------------------------------------------------
-- Saved variables (Core.lua's BindSavedVariables calls Bind with its table)
-- ---------------------------------------------------------------------------

local MAX_SAVED_TEXT = 30000

function Tools.Bind(h)
    hub = h
    local db = h.db
    if type(db.news) ~= "boolean" then db.news = true end
    if type(db.seen) ~= "table" then db.seen = {} end
    for k, v in pairs(db.seen) do
        if type(k) ~= "string" or type(v) ~= "string" then db.seen[k] = nil end
    end
    if type(db.lastNews) ~= "table" then db.lastNews = {} end
    for i = #db.lastNews, 1, -1 do
        if type(db.lastNews[i]) ~= "string" then table.remove(db.lastNews, i) end
    end
    if db.selftest ~= nil and (type(db.selftest) ~= "string" or #db.selftest > MAX_SAVED_TEXT) then db.selftest = nil end
end

-- The keys Tools keeps in BetterForeverDB (Core.lua drops every other key except minimap).
Tools.DB_KEYS = { news = true, seen = true, lastNews = true, selftest = true }

-- ---------------------------------------------------------------------------
-- Text window: a movable frame with a multi-line edit box, for copy (export, self-test) and
-- paste (import).
-- ---------------------------------------------------------------------------

local popup

local function TryFrame(kind, name, parent, template)
    local ok, f = pcall(_G.CreateFrame, kind, name, parent, template)
    if ok and f then return f end
    ok, f = pcall(_G.CreateFrame, kind, name, parent)
    if ok then return f end
end

local function BuildPopup()
    if popup then return popup end
    local f = TryFrame("Frame", "BetterForeverTextWindow", _G.UIParent, "BackdropTemplate")
    if not f then return nil end
    f:SetSize(580, 380)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if type(f.SetBackdrop) == "function" then
        local FLAT = "Interface\\Buttons\\WHITE8x8"
        f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        f:SetBackdropColor(0.07, 0.08, 0.10, 0.97)
        f:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    end
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -10)
    f.title:SetPoint("RIGHT", f, "RIGHT", -36, 0)
    f.title:SetJustifyH("LEFT")
    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hint:SetPoint("BOTTOMLEFT", 12, 14)
    f.hint:SetPoint("RIGHT", f, "RIGHT", -130, 0)
    f.hint:SetJustifyH("LEFT")

    local close = TryFrame("Button", nil, f, "UIPanelCloseButton")
    if close then
        close:SetPoint("TOPRIGHT", -2, -2)
        close:SetScript("OnClick", function() f:Hide() end)
    end

    local scroll = TryFrame("ScrollFrame", "BetterForeverTextWindowScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -32)
    scroll:SetPoint("BOTTOMRIGHT", -32, 40)
    local edit = TryFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(_G.ChatFontNormal or _G.GameFontHighlightSmall)
    edit:SetWidth(530)
    if type(edit.SetMaxLetters) == "function" then edit:SetMaxLetters(0) end
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    -- Read-only while it shows something to copy: typing puts the text back.
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput and f.readOnly and self:GetText() ~= f.text then
            self:SetText(f.text)
            self:HighlightText()
        end
    end)
    scroll:SetScrollChild(edit)
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
    f.edit = edit

    local action = TryFrame("Button", nil, f, "UIPanelButtonTemplate")
    if action then
        action:SetSize(110, 22)
        action:SetPoint("BOTTOMRIGHT", -12, 10)
        action:SetScript("OnClick", function()
            if type(f.onAction) == "function" then
                local ok, err = pcall(f.onAction, edit:GetText())
                if not ok then Print("error: " .. tostring(err)) end
            else
                f:Hide()
            end
        end)
        f.action = action
    end
    f:Hide()
    if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "BetterForeverTextWindow") end
    popup = f
    return f
end

-- Shows text to copy (onAction nil: the button closes) or an empty box to paste into (text nil,
-- onAction(text) runs on the button). Returns false where no window could be made.
function Tools.ShowText(title, text, hint, actionLabel, onAction)
    local ok, f = pcall(BuildPopup)
    if not ok or not f then return false end
    f.title:SetText(title or "BetterForever")
    f.hint:SetText(hint or "")
    f.readOnly = text ~= nil
    f.text = text or ""
    f.onAction = onAction
    if f.action then f.action:SetText(actionLabel or "Close") end
    f.edit:SetText(f.text)
    f:Show()
    f.edit:SetFocus()
    if f.readOnly then f.edit:HighlightText() end
    return true
end

function Tools.HideText()
    if popup then popup:Hide() end
end

-- ---------------------------------------------------------------------------
-- What's new
-- ---------------------------------------------------------------------------

-- The parts of "1.10.2" as numbers; a part that is not a number compares as text.
local function Parts(v)
    local list = {}
    for p in tostring(v):gmatch("[^%.%-]+") do list[#list + 1] = tonumber(p) or p end
    return list
end

-- true when version a is newer than b.
local function Newer(a, b)
    local pa, pb = Parts(a), Parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
        if x ~= y then return x > y end
    end
    return false
end
Tools.Newer = Newer

local function Metadata(name)
    local f = Lib.API("C_AddOns", "GetAddOnMetadata") or Lib.API("GetAddOnMetadata")
    return Str(Lib.Call(f, name, "Version"))
end

-- An installed addon's version: its API table's, else its TOC's (an addon that is loaded but
-- has no API yet). nil when it is not loaded.
local function VersionOf(a)
    local api = hub.API(a)
    if api then
        local v = Str(api.version)
        if v then return v end
    end
    if Lib.AddOnLoaded(a.name) then return Metadata(a.name) end
    return nil
end

local function Note(name, version)
    local list = CHANGES[name]
    return list and list[version] or nil
end

local function NewsLine(name, old, new)
    local note = Note(name, new)
    local text
    if old then
        text = "updated " .. EM_DASH .. " " .. name .. " " .. old .. ARROW .. new
    else
        text = "new " .. EM_DASH .. " " .. name .. " " .. new
    end
    if note then text = text .. ": " .. note end
    return text
end

-- Compares every installed addon (and the hub) with the versions seen last, records the new
-- ones and returns the lines (an empty list when nothing changed). Printing is left to the caller.
function Tools.CheckNews()
    local db = hub.db
    local seen = db.seen
    local firstRun = next(seen) == nil
    local lines = {}
    local list = { { name = "BetterForever", version = hub.VERSION } }
    for _, a in ipairs(hub.ADDONS) do
        local v = VersionOf(a)
        if v then list[#list + 1] = { name = a.name, version = v } end
    end
    for _, it in ipairs(list) do
        local old = seen[it.name]
        if not firstRun then
            if old == nil then
                lines[#lines + 1] = NewsLine(it.name, nil, it.version)
            elseif Newer(it.version, old) then
                lines[#lines + 1] = NewsLine(it.name, old, it.version)
            end
        end
        seen[it.name] = it.version
    end
    if #lines > 0 then db.lastNews = lines end
    return lines
end

-- At login: the check, and the lines in chat while the switch is on.
function Tools.LoginNews()
    local lines = Tools.CheckNews()
    if hub.db.news then
        for _, l in ipairs(lines) do Print(l) end
    end
end

function Tools.NewsCommand(rest)
    local db = hub.db
    if rest == "on" or rest == "off" then
        db.news = rest == "on"
        Print("what's new at login: " .. Lib.OnOff(db.news))
        return
    end
    if #db.lastNews == 0 then
        Print("nothing new recorded yet. What's new at login is " .. Lib.OnOff(db.news) .. " (/bf news on|off).")
        return
    end
    for _, l in ipairs(db.lastNews) do Print(l) end
end

-- ---------------------------------------------------------------------------
-- Profiles, export and import (addons built on the library's A:InitDB)
-- ---------------------------------------------------------------------------

-- The library addon objects with settings bound, in the hub's menu order.
local function ProfileAddons()
    local out = {}
    for _, a in ipairs(hub.ADDONS) do
        local obj = Lib.addons and Lib.addons[a.name]
        if type(obj) == "table" and obj.dbShared then out[#out + 1] = obj end
    end
    return out
end
Tools.ProfileAddons = ProfileAddons

-- The hub row for a word: key, label, name or slash command.
local function FindRow(word)
    word = tostring(word or ""):lower()
    for _, a in ipairs(hub.ADDONS) do
        if a.key == word or a.label:lower() == word or a.name:lower() == word or a.slash == "/" .. word then return a end
    end
end

-- The library addon for a word, or nil, why.
local function FindLibAddon(word)
    local a = FindRow(word)
    if not a then return nil, "unknown addon: " .. tostring(word) end
    local obj = Lib.addons and Lib.addons[a.name]
    if type(obj) ~= "table" or not obj.dbShared then
        if Lib.AddOnLoaded(a.name) then
            return nil, a.name .. " keeps its own settings table, not the library's - profiles and export cover only: "
                .. Tools.CoveredText()
        end
        return nil, a.name .. " is not loaded"
    end
    return obj
end

function Tools.CoveredText()
    local names = {}
    for _, obj in ipairs(ProfileAddons()) do names[#names + 1] = obj.name end
    return #names > 0 and table.concat(names, ", ") or "none loaded"
end

local function ModeText(obj)
    return obj:ProfileMode() == "character" and "this character's own settings" or "shared (account-wide)"
end

function Tools.ProfileCommand(rest)
    local mode, word = rest:match("^(%S+)%s*(.-)$")
    if not mode or mode == "" then
        local list = ProfileAddons()
        if #list == 0 then
            Print("no loaded addon keeps its settings through the library, so there is nothing to switch.")
        end
        for _, obj in ipairs(list) do Print(obj.name .. ": " .. ModeText(obj)) end
        Print("/bf profile char <addon|all> - this character gets its own copy (from the shared settings);"
            .. " /bf profile shared <addon|all> - back to the shared settings (the copy is dropped).")
        return
    end
    local target
    if mode == "char" or mode == "character" then target = "character"
    elseif mode == "shared" or mode == "account" then target = "shared"
    else
        Print("/bf profile [char|shared] <addon|all>")
        return
    end
    local list
    if word == "" or word == "all" then
        list = ProfileAddons()
        if #list == 0 then
            Print("no loaded addon keeps its settings through the library.")
            return
        end
    else
        local obj, why = FindLibAddon(word)
        if not obj then
            Print(why)
            return
        end
        list = { obj }
    end
    for _, obj in ipairs(list) do
        local ok, msg = obj:SetProfileMode(target)
        if ok then
            Print(obj.name .. ": " .. ModeText(obj))
        else
            Print(obj.name .. ": " .. tostring(msg))
        end
    end
end

function Tools.ExportCommand(word)
    if word == "" then
        Print("/bf export <addon> - one of: " .. Tools.CoveredText())
        return
    end
    local obj, why = FindLibAddon(word)
    if not obj then
        Print(why)
        return
    end
    local s, err = obj:ExportSettings()
    if not s then
        Print("export failed: " .. tostring(err))
        return
    end
    local shown = Tools.ShowText(obj.name .. " settings (" .. ModeText(obj) .. ")", s,
        "Ctrl+C to copy. Paste it with /bf import.")
    if not shown then Print(s) end
end

local function DoImport(text)
    local name, t = Lib.DecodeSettings(text)
    if not name then
        Print("import failed: " .. tostring(t))
        return
    end
    local obj, why = FindLibAddon(name)
    if not obj then
        Print("import failed: " .. tostring(why))
        return
    end
    local applied, ignored = obj:ImportSettings(t)
    Print(string.format("imported %d setting(s) into %s (%s)%s.", applied, obj.name, ModeText(obj),
        ignored > 0 and (", " .. ignored .. " unknown or invalid left out") or ""))
    Tools.HideText()
end
Tools.DoImport = DoImport

function Tools.ImportCommand()
    local shown = Tools.ShowText("Import settings", nil,
        "Paste a /bf export string (Ctrl+V), then Import. Only known settings are taken.", "Import", DoImport)
    if not shown then Print("no text window on this client.") end
end

-- ---------------------------------------------------------------------------
-- Self-test
-- ---------------------------------------------------------------------------

local UNITS = { "player", "target", "party1" }

-- A spell the player's class has from early on, for the range calls (Auto Attack otherwise).
local RANGE_SPELL = {
    DRUID = 1126, PALADIN = 19740, PRIEST = 1243, MAGE = 1459, SHAMAN = 331, WARLOCK = 5697,
    HUNTER = 75, ROGUE = 1752, WARRIOR = 772,
}

local function RangeSpell()
    local class = Str(select(2, Lib.Call(_G.UnitClass, "player")))
    return RANGE_SPELL[class or ""] or 6603
end

local function ColorCurve()
    local CU, E, CC = _G.C_CurveUtil, _G.Enum, _G.CreateColor
    if type(CU) ~= "table" or type(CU.CreateColorCurve) ~= "function" or type(CC) ~= "function" then return nil end
    local c = CU.CreateColorCurve()
    if type(E) == "table" and type(E.LuaCurveType) == "table" and E.LuaCurveType.Step ~= nil then
        c:SetType(E.LuaCurveType.Step)
    end
    for x = 0, 5 do c:AddPoint(x, CC(1, 1, 1, 1)) end
    return c
end

-- The first aura's instance ID on a unit (plain number), or nil.
local function FirstAuraID(unit)
    local f = Lib.API("C_UnitAuras", "GetAuraDataByIndex")
    for _, filter in ipairs({ "HARMFUL", "HELPFUL" }) do
        local d = Lib.Call(f, unit, 1, filter)
        if type(d) == "table" and not IsSecret(d) then
            local id = Num(d.auraInstanceID)
            if id then return id end
        end
    end
end

local SKIP = {} -- a probe returns SKIP, why when it could not be asked

local function Need(space, name)
    local f = Lib.API(space, name)
    if not f then error("missing", 0) end
    return f
end

-- { id, unit = true when it is asked per unit, call(unit) }
local PROBES = {
    { id = "issecretvalue", call = function() return Need("issecretvalue") and "function" end },
    { id = "C_UnitAuras.GetAuraDataByIndex", unit = true,
        call = function(u) return Need("C_UnitAuras", "GetAuraDataByIndex")(u, 1, "HELPFUL") end },
    { id = "C_UnitAuras.GetUnitAuraInstanceIDs", unit = true,
        call = function(u) return Need("C_UnitAuras", "GetUnitAuraInstanceIDs")(u, "HARMFUL", 2) end },
    { id = "C_UnitAuras.GetAuraDispelTypeColor", unit = true,
        call = function(u)
            local f = Need("C_UnitAuras", "GetAuraDispelTypeColor")
            local id = FirstAuraID(u)
            if not id then return SKIP, "no aura" end
            local crv = ColorCurve()
            if not crv then return SKIP, "no colour curve" end
            return f(u, id, crv)
        end },
    { id = "UnitAura", unit = true, call = function(u) return Need("UnitAura")(u, 1, "HELPFUL") end },
    { id = "UnitHealth", unit = true, call = function(u) return Need("UnitHealth")(u) end },
    { id = "UnitHealth predicted", unit = true, call = function(u) return Need("UnitHealth")(u, true) end },
    { id = "UnitHealthMax", unit = true, call = function(u) return Need("UnitHealthMax")(u) end },
    { id = "UnitGetIncomingHeals", unit = true, call = function(u) return Need("UnitGetIncomingHeals")(u) end },
    { id = "UnitThreatSituation", unit = true,
        call = function(u) return Need("UnitThreatSituation")("player", u) end },
    { id = "UnitDetailedThreatSituation", unit = true,
        call = function(u) return Need("UnitDetailedThreatSituation")("player", u) end },
    { id = "GetRaidTargetIndex", unit = true, call = function(u) return Need("GetRaidTargetIndex")(u) end },
    { id = "C_Spell.IsSpellInRange", unit = true,
        call = function(u) return Need("C_Spell", "IsSpellInRange")(RangeSpell(), u) end },
    { id = "IsSpellInRange", unit = true,
        call = function(u)
            local f = Need("IsSpellInRange")
            local info = Lib.API("C_Spell", "GetSpellName") or Lib.API("GetSpellInfo")
            local name = Str(Lib.Call(info, RangeSpell()))
            if not name then return SKIP, "no spell name" end
            return f(name, u)
        end },
    { id = "UnitInRange", unit = true, call = function(u) return Need("UnitInRange")(u) end },
    { id = "UnitIsConnected", unit = true, call = function(u) return Need("UnitIsConnected")(u) end },
    { id = "GetWeaponEnchantInfo", call = function() return Need("GetWeaponEnchantInfo")() end },
    { id = "C_LootHistory", call = function()
        local t = _G.C_LootHistory
        if type(t) ~= "table" then error("missing", 0) end
        local have = {}
        for _, n in ipairs({ "GetSortedInfoForDrop", "GetSortedDropsForEncounter", "GetInfoForEncounter",
            "GetNumItems", "GetItem", "GetPlayerInfo" }) do
            if type(t[n]) == "function" then have[#have + 1] = n end
        end
        return #have > 0 and table.concat(have, ",") or "no functions"
    end },
    { id = "GetBindingKey INTERACTTARGET", call = function() return Need("GetBindingKey")("INTERACTTARGET") end },
    { id = "CVar SoftTargetInteract", call = function()
        local f = Lib.API("C_CVar", "GetCVar") or Need("GetCVar")
        return f("SoftTargetInteract")
    end },
    { id = "CustomAuraContainerTemplate", call = function()
        local info = Lib.API("C_XMLUtil", "GetTemplateInfo")
        if info then
            local t = info("CustomAuraContainerTemplate")
            if t == nil then return nil end
            return "template"
        end
        local f = Need("CreateFrame")("AuraContainer", nil, _G.UIParent, "CustomAuraContainerTemplate")
        if f and type(f.Hide) == "function" then f:Hide() end
        return f and "frame made"
    end },
    { id = "CustomAuraContainerGroupDefaultOptions",
        call = function() return type(_G.CustomAuraContainerGroupDefaultOptions) == "table" and "table" or nil end },
}
Tools.PROBES = PROBES

local function Short(v)
    local s = tostring(v)
    if #s > 24 then s = s:sub(1, 22) .. ".." end
    return s
end

-- One result word from a pcall: "error: ...", "secret", "nil", "skip (why)" or "ok (...)".
local function Classify(ok, ...)
    local n = select("#", ...)
    local first = ...
    if not ok then
        if IsSecret(first) then return "error (secret message)" end
        -- Without the "file.lua:12: " prefixes, so the reason fits on the line.
        local msg = tostring(first)
        for _ = 1, 3 do msg = msg:gsub("^[^%s]-%.lua:%d+: ", "") end
        if msg == "missing" then return "missing" end
        if #msg > 50 then msg = msg:sub(1, 48) .. ".." end
        return "error: " .. msg
    end
    -- A secret is checked before anything compares it.
    if IsSecret(first) then return "secret" end
    if first == SKIP then return "skip (" .. tostring(select(2, ...)) .. ")" end
    local otherSecret = 0
    for i = 2, n do
        if IsSecret((select(i, ...))) then otherSecret = otherSecret + 1 end
    end
    local extra = otherSecret > 0 and (", " .. otherSecret .. " more secret") or ""
    if first == nil then
        return (otherSecret > 0 and "nil" .. extra) or "nil"
    end
    if type(first) == "table" then
        local secret, count = 0, 0
        for _, v in pairs(first) do
            count = count + 1
            if IsSecret(v) then secret = secret + 1 end
        end
        if secret > 0 then return "secret fields (" .. secret .. "/" .. count .. ")" .. extra end
        return "ok (table " .. count .. ")" .. extra
    end
    return "ok (" .. Short(first) .. ")" .. extra
end
Tools.Classify = Classify

-- The kind of a result for the summary: ok, nil, secret, error, skip.
local function Kind(r)
    if r:match("^secret") then return "secret" end
    return r:match("^(%a+)") or "?"
end

-- One run: { label, at, rows = { { id, unit, result } } }
local function RunProbes(label)
    local run = { label = label, at = Lib.Call(_G.date, "%H:%M:%S") or "?", rows = {} }
    for _, p in ipairs(PROBES) do
        local units = p.unit and UNITS or { "" }
        for _, u in ipairs(units) do
            run.rows[#run.rows + 1] = { id = p.id, unit = u, result = Classify(pcall(p.call, u)) }
        end
    end
    return run
end
Tools.RunProbes = RunProbes

local function Summary(run)
    local counts, order = {}, { "ok", "nil", "secret", "skip", "missing", "error" }
    for _, r in ipairs(run.rows) do
        local k = Kind(r.result)
        counts[k] = (counts[k] or 0) + 1
    end
    local parts = {}
    for _, k in ipairs(order) do
        if counts[k] then parts[#parts + 1] = counts[k] .. " " .. k end
    end
    return table.concat(parts, ", ")
end

local runs = { out = nil, ["in"] = nil }
local selftestFrame

local function Header()
    local build = { Lib.Call(_G.GetBuildInfo) }
    local class = Str(select(2, Lib.Call(_G.UnitClass, "player"))) or "?"
    local level = Num(Lib.Call(_G.UnitLevel, "player"))
    return string.format("BetterForever %s self-test (library %s) - client %s (%s, interface %s) - %s %s - %s",
        tostring(hub.VERSION), tostring(Lib.version), tostring(build[1] or "?"), tostring(build[2] or "?"),
        tostring(build[4] or "?"), class, tostring(level or "?"), tostring(Lib.Call(_G.date, "%Y-%m-%d") or "?"))
end

-- The full text: one line per probe and unit, out of combat | in combat.
function Tools.SelfTestText()
    local out, inn = runs.out, runs["in"]
    local lines = { Header(), "range spell: " .. tostring(RangeSpell()) }
    lines[#lines + 1] = "out of combat: " .. (out and (out.at .. " - " .. Summary(out)) or "not run yet")
    lines[#lines + 1] = "in combat:     " .. (inn and (inn.at .. " - " .. Summary(inn)) or "not run yet (runs at the next pull)")
    lines[#lines + 1] = ""
    local base = out or inn
    if not base then return table.concat(lines, "\n") end
    for i, r in ipairs(base.rows) do
        local o = out and out.rows[i] and out.rows[i].result or "-"
        local n = inn and inn.rows[i] and inn.rows[i].result or "-"
        local mark = (out and inn and o ~= n) and "  <<" or ""
        lines[#lines + 1] = string.format("%s%s: out %s | in %s%s", r.id, r.unit ~= "" and (" " .. r.unit) or "", o, n, mark)
    end
    return table.concat(lines, "\n")
end

local SELFTEST_HINT = "Ctrl+C to copy and send it. /bf selftest show reopens it."

-- quiet: only refresh the window when it is open, never open it or take the keyboard (the second
-- run happens as combat starts).
local function SaveAndShow(quiet)
    local text = Tools.SelfTestText()
    if #text <= MAX_SAVED_TEXT then hub.db.selftest = text end
    if not quiet then
        Tools.ShowText("BetterForever self-test", text, SELFTEST_HINT)
    elseif popup and popup:IsShown() and popup.readOnly then
        popup.text = text
        popup.edit:SetText(text)
    end
end

-- The differences between the two runs, compact: "UnitHealth target ok -> secret".
local function PrintDiff()
    local out, inn = runs.out, runs["in"]
    if not out or not inn then return end
    local diffs = {}
    for i, r in ipairs(out.rows) do
        local n = inn.rows[i] and inn.rows[i].result
        if n and Kind(n) ~= Kind(r.result) then
            diffs[#diffs + 1] = r.id .. (r.unit ~= "" and (" " .. r.unit) or "") .. " " .. Kind(r.result) .. ARROW .. Kind(n)
        end
    end
    if #diffs == 0 then
        Print("self-test: in and out of combat answer alike.")
        return
    end
    Print("self-test: " .. #diffs .. " call(s) answer differently in combat:")
    for i = 1, math.min(#diffs, 8) do Print("  " .. diffs[i]) end
    if #diffs > 8 then Print("  ... and " .. (#diffs - 8) .. " more in the window") end
end

local function Arm(event)
    if not selftestFrame then
        local ok, f = pcall(_G.CreateFrame, "Frame")
        if not ok or not f then return end
        selftestFrame = f
        f:SetScript("OnEvent", function(self, ev)
            self:UnregisterAllEvents()
            local function Second()
                local label = ev == "PLAYER_REGEN_DISABLED" and "in" or "out"
                runs[label] = RunProbes(label)
                Print("self-test " .. (label == "in" and "in combat" or "out of combat") .. ": " .. Summary(runs[label]))
                PrintDiff()
                SaveAndShow(true)
                Print("self-test done: /bf selftest show for the text to copy.")
            end
            -- A moment later, so the client is fully in (or out of) combat.
            local after = _G.C_Timer and _G.C_Timer.After
            if type(after) == "function" then after(1, function() pcall(Second) end) else pcall(Second) end
        end)
    end
    selftestFrame:UnregisterAllEvents()
    pcall(selftestFrame.RegisterEvent, selftestFrame, event)
end

function Tools.SelfTestCommand(rest)
    if rest == "show" then
        if runs.out or runs["in"] then
            SaveAndShow()
        elseif hub.db.selftest then
            Tools.ShowText("BetterForever self-test (saved)", hub.db.selftest, "Ctrl+C to copy. /bf selftest runs it again.")
        else
            Print("no self-test yet: /bf selftest")
        end
        return
    end
    local inCombat = Lib.InCombat() or Lib.Bool(Lib.Call(_G.UnitAffectingCombat, "player")) == true
    local label = inCombat and "in" or "out"
    runs = { out = nil, ["in"] = nil }
    runs[label] = RunProbes(label)
    Print("self-test " .. (inCombat and "in combat" or "out of combat") .. ": " .. Summary(runs[label])
        .. ". It runs again " .. (inCombat and "when combat ends" or "at your next pull") .. " and compares.")
    Arm(inCombat and "PLAYER_REGEN_ENABLED" or "PLAYER_REGEN_DISABLED")
    SaveAndShow()
end
