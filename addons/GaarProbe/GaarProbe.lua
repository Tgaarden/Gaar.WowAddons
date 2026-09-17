--[[
  Gaar Probe - what does this client actually have?

  Every port in this suite has cost the same round of "it loads but does nothing", and every
  one was settled the same way: by asking an artefact rather than remembering. This addon is
  that question asked up front. Drop it into an unknown client, type /gaarprobe, log out, and
  the SavedVariables file holds the whole answer.

  It reports four things:

    * Every global the suite touches, per module, with its type or MISSING.
    * The C_* namespaces, listing both the names this suite uses and the retail replacements
      it would have to move to - so the report doubles as a migration target.
    * Named frames and the modern field paths that replaced them (PlayerFrameHealthBar
      against PlayerFrame.healthbar, and so on).
    * Return shapes. These are the ones that fail silently: a function that exists, is called
      the old way, and hands back a table instead of three values. C_Container.GetContainerItemInfo
      and GetTrackingInfo have both done exactly that, and neither raises an error.

  Everything is probed through pcall and nothing is called that could change game state. This
  is the one addon that has to survive an API it knows nothing about, so it never assumes a
  call will return, or even that the name it is reaching for is a function.
]]

local _G = _G
local ADDON = "Gaar Probe"
local VERSION = "1.0"

-- ---------------------------------------------------------------------------
-- What the suite touches, straight out of tools/check.sh
-- ---------------------------------------------------------------------------
local MODULES = {
    GaarBags = { "ClearCursor", "ContainerIDToInventoryID", "CreateFrame",
        "DEFAULT_CHAT_FRAME", "GameFontHighlight", "GameFontHighlightSmall", "GameTooltip",
        "GetCoinTextureString", "GetContainerItemCooldown", "GetContainerItemInfo",
        "GetContainerItemLink", "GetContainerItemQuestInfo", "GetContainerNumFreeSlots",
        "GetContainerNumSlots", "GetCursorInfo", "GetInventoryItemTexture", "GetItemInfo",
        "GetItemQualityColor", "GetMoney", "GetRealmName", "InCombatLockdown",
        "NUM_CONTAINER_FRAMES", "PickupBagFromSlot", "PickupContainerItem", "PutItemInBag",
        "RAID_CLASS_COLORS", "STANDARD_TEXT_FONT", "SetItemButtonCount",
        "SetItemButtonDesaturated", "SetItemButtonTexture", "SlashCmdList", "SortBags",
        "UIParent", "UISpecialFrames", "UnitClass", "UnitName", "hooksecurefunc" },
    GaarCC = { "CreateFrame", "GameFontHighlight", "GetTime", "STANDARD_TEXT_FONT",
        "SlashCmdList", "UIParent", "UISpecialFrames", "hooksecurefunc" },
    GaarCast = { "CreateFrame", "GameFontHighlight", "GetNetStats", "GetTime",
        "IsShiftKeyDown", "STANDARD_TEXT_FONT", "SlashCmdList", "UIParent", "UISpecialFrames",
        "UnitCastingInfo", "UnitChannelInfo", "UnitExists", "UnitName" },
    GaarFrames = { "C_UnitAuras", "CreateFrame", "GameFontHighlight",
        "HealthBar_OnValueChanged", "RAID_CLASS_COLORS", "STANDARD_TEXT_FONT", "SlashCmdList",
        "UIParent", "UISpecialFrames", "UnitBuff", "UnitClass", "UnitExists",
        "UnitFrameHealthBar_Update", "UnitFrame_Update", "UnitHealth", "UnitHealthMax",
        "UnitIsDeadOrGhost", "UnitIsPlayer", "UnitPower", "UnitPowerMax", "hooksecurefunc" },
    GaarLooter = { "CLASS_ICON_TCOORDS", "ChatEdit_InsertLink", "ChatFontNormal",
        "CreateFrame", "GameFontHighlight", "GameTooltip", "GetItemInfoInstant",
        "GetLootRollItemInfo", "GetLootRollItemLink", "GetMoney", "GetNumGroupMembers",
        "GetNumSubgroupMembers", "GetRealZoneText", "GetRealmName", "GetTime", "GetZoneText",
        "IsInGroup", "IsInRaid", "IsShiftKeyDown", "RAID_CLASS_COLORS", "RollOnLoot",
        "STANDARD_TEXT_FONT", "SlashCmdList", "UIParent", "UISpecialFrames", "UnitClass",
        "UnitName", "hooksecurefunc" },
    GaarMap = { "CreateFrame", "GameFontHighlight", "GameTooltip", "GetCursorPosition",
        "GetGameTime", "GetMinimapShape", "GetUnitSpeed", "STANDARD_TEXT_FONT", "SlashCmdList" },
    GaarMeter = { "CLASS_ICON_TCOORDS", "C_Spell", "CombatLogGetCurrentEventInfo",
        "CreateFrame", "GameFontHighlight", "GameTooltip", "GetCursorPosition",
        "GetNumGroupMembers", "GetNumSubgroupMembers", "GetSpellTexture", "GetTime",
        "IsInInstance", "IsInRaid", "RAID_CLASS_COLORS", "SendChatMessage", "SlashCmdList",
        "UIParent", "UISpecialFrames", "UnitClass", "UnitName" },
    GaarOptions = { "CreateFrame", "GameFontHighlight", "GameTooltip", "GetCursorPosition",
        "InterfaceOptionsFrame_OpenToCategory", "InterfaceOptions_AddCategory", "Minimap",
        "Settings", "SlashCmdList", "UIParent", "UISpecialFrames" },
    GaarPlates = { "AbbreviateLargeNumbers", "C_NamePlate", "C_UnitAuras", "CreateFrame",
        "GameFontHighlight", "GetTime", "RAID_CLASS_COLORS", "STANDARD_TEXT_FONT",
        "SlashCmdList", "UIParent", "UISpecialFrames", "UnitAura", "UnitCanAttack",
        "UnitCastingInfo", "UnitChannelInfo", "UnitClass", "UnitDetailedThreatSituation",
        "UnitExists", "UnitHealth", "UnitHealthMax", "UnitIsFriend", "UnitIsPlayer",
        "UnitIsUnit", "UnitLevel", "UnitName", "UnitReaction" },
    GaarSpellBook = { "ClearCursor", "CreateFrame", "DEFAULT_CHAT_FRAME", "GameFontHighlight",
        "GameTooltip", "GetActionTexture", "GetBindingKey", "GetCurrentBindingSet",
        "GetNumShapeshiftForms", "GetNumSpellTabs", "GetShapeshiftFormInfo",
        "GetSpellBookItemInfo", "GetSpellBookItemName", "GetSpellBookItemTexture",
        "GetSpellName", "GetSpellTabInfo", "GetSpellTexture", "GetTime", "HasAction",
        "IsPassiveSpell", "IsShiftKeyDown", "IsSpellKnown", "IsSpellKnownOrOverridesKnown",
        "PickupSpell", "PickupSpellBookItem", "PlaceAction", "STANDARD_TEXT_FONT",
        "SaveBindings", "SetBinding", "SlashCmdList", "SpellBookFrame", "UIParent",
        "UISpecialFrames" },
    GaarThreat = { "CreateFrame", "GameFontHighlight", "GetNumGroupMembers",
        "GetNumSubgroupMembers", "IsInInstance", "IsInRaid", "PlaySound", "RAID_CLASS_COLORS",
        "SOUNDKIT", "SlashCmdList", "UIParent", "UISpecialFrames", "UnitCanAttack",
        "UnitClass", "UnitDetailedThreatSituation", "UnitExists", "UnitIsPlayer", "UnitIsUnit",
        "UnitName" },
    GaarUI = { "C_AddOns", "GetAddOnMetadata", "IsAddOnLoaded", "SlashCmdList" },
}

-- ---------------------------------------------------------------------------
-- C_* namespaces: what this suite uses, plus where retail moved each one
-- ---------------------------------------------------------------------------
local NAMESPACES = {
    C_AddOns      = { "IsAddOnLoaded", "GetAddOnMetadata", "LoadAddOn", "EnableAddOn" },
    C_Container   = { "GetContainerNumSlots", "GetContainerItemInfo", "GetContainerItemLink",
                      "GetContainerNumFreeSlots", "GetContainerItemCooldown",
                      "GetContainerItemQuestInfo", "ContainerIDToInventoryID", "UseContainerItem" },
    C_Item        = { "GetItemInfo", "GetItemInfoInstant", "GetItemQualityColor", "IsItemDataCachedByID",
                      "RequestLoadItemDataByID" },
    C_Spell       = { "GetSpellInfo", "GetSpellTexture", "GetSpellName", "GetSpellCooldown",
                      "IsSpellPassive", "GetSpellCharges" },
    C_SpellBook   = { "GetSpellBookItemInfo", "GetSpellBookItemName", "GetSpellBookItemTexture",
                      "GetNumSpellBookSkillLines", "GetSpellBookSkillLineInfo", "PickupSpellBookItem",
                      "IsSpellBookItemPassive", "HasPetSpells" },
    C_UnitAuras   = { "GetAuraDataByIndex", "GetBuffDataByIndex", "GetDebuffDataByIndex",
                      "GetAuraDataBySlot", "GetPlayerAuraBySpellID" },
    C_NamePlate   = { "GetNamePlateForUnit", "GetNamePlates", "SetNamePlateEnemySize" },
    C_Minimap     = { "GetNumTrackingTypes", "GetTrackingInfo", "SetTracking", "GetViewRadius" },
    C_Map         = { "GetBestMapForUnit", "GetMapInfo", "GetPlayerMapPosition",
                      "GetMapHighlightInfoAtPosition" },
    C_LootHistory = { "GetItem", "GetNumItems", "GetPlayerInfo", "GetSortedInfoForDrop" },
    C_CombatLog   = { "GetCurrentEventInfo", "GetEventInfo" },
    C_CombatLogSecure = { "GetCurrentEventInfo" },
    C_Timer       = { "After", "NewTicker", "NewTimer" },
    C_CVar        = { "GetCVar", "SetCVar", "GetCVarBool" },
    C_TooltipInfo = { "GetBagItem", "GetHyperlink", "GetInventoryItem" },
    C_PartyInfo   = { "IsInGroup", "GetNumGroupMembers" },
    C_UnitFrame   = { "SetNameplateFriendlySize" },
}

-- ---------------------------------------------------------------------------
-- Frames. Each row is one thing the suite needs, with every name it has gone by:
-- the global this suite reads, and the modern field path that replaced it.
-- ---------------------------------------------------------------------------
local FRAMES = {
    { "player health bar",  "PlayerFrameHealthBar",       "PlayerFrame.healthbar" },
    { "player mana bar",    "PlayerFrameManaBar",         "PlayerFrame.manabar" },
    { "target health bar",  "TargetFrameHealthBar",       "TargetFrame.healthbar" },
    { "pet health bar",     "PetFrameHealthBar",          "PetFrame.healthbar" },
    { "party 1 health bar", "PartyMemberFrame1HealthBar", "PartyFrame.MemberFrame1" },
    { "focus frame",        "FocusFrame",                 "FocusFrame.healthbar" },
    { "player cast bar",    "CastingBarFrame",            "PlayerCastingBarFrame" },
    { "target cast bar",    "TargetFrameSpellBar",        "TargetFrame.spellbar" },
    { "spell book",         "SpellBookFrame",             "PlayerSpellsFrame" },
    { "container frame 1",  "ContainerFrame1",            "ContainerFrameCombinedBags" },
    { "minimap",            "Minimap",                    "Minimap.ZoomIn" },
    { "minimap cluster",    "MinimapCluster",             "MinimapCluster.ZoneTextButton" },
    { "minimap zone bar",   "MinimapZoneTextButton",      "MinimapCluster.BorderTop" },
    { "minimap border",     "MinimapBorder",              "MinimapCompassTexture" },
    { "world map",          "WorldMapFrame",              "WorldMapFrame.ScrollContainer" },
    { "clock",              "TimeManagerClockButton",     "TimeManagerClockTicker" },
    { "options panel",      "InterfaceOptionsFrame",      "SettingsPanel" },
    { "buff frame",         "BuffFrame",                  "BuffFrame.AuraContainer" },
}

-- ---------------------------------------------------------------------------
-- Probing helpers
--
-- Nothing here trusts that a name resolves, that a call returns, or that a call is even safe
-- to make. A probe that dies on the first surprise reports nothing, which is the one outcome
-- worth avoiding.
-- ---------------------------------------------------------------------------
local function Kind(v)
    local t = type(v)
    if t == "nil" then return "MISSING" end
    if t == "table" then
        -- distinguish a frame from a plain table: frames answer GetObjectType
        local ok, objType = pcall(function() return v.GetObjectType and v:GetObjectType() end)
        if ok and objType then return "frame:" .. tostring(objType) end
        return "table"
    end
    return t
end

-- Walks a dotted path such as "PlayerFrame.healthbar" without assuming any step exists.
local function Resolve(path)
    local node = _G
    for part in string.gmatch(path, "[^.]+") do
        if type(node) ~= "table" then return nil end
        local ok, nxt = pcall(function() return node[part] end)
        if not ok then return nil end
        node = nxt
        if node == nil then return nil end
    end
    return node
end

-- Calls a read-only function and describes what came back, rather than what it should have.
-- The description is the point: "table" where three values were expected is the whole bug.
local function Shape(label, fn, ...)
    if type(fn) ~= "function" then return label .. " = MISSING" end
    local packed = { pcall(fn, ...) }
    if not packed[1] then
        return label .. " = ERROR " .. tostring(packed[2])
    end
    local n = #packed - 1
    if n == 0 then return label .. " -> no returns" end
    local parts = {}
    for i = 2, #packed do
        local v = packed[i]
        if type(v) == "table" then
            -- name the fields, since that is what tells old shape from new
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            local shown = table.concat(keys, ",")
            if #shown > 120 then shown = string.sub(shown, 1, 120) .. "..." end
            parts[#parts + 1] = "table{" .. shown .. "}"
        else
            parts[#parts + 1] = type(v)
        end
    end
    return string.format("%s -> %d: %s", label, n, table.concat(parts, ", "))
end

-- ---------------------------------------------------------------------------
-- The report
-- ---------------------------------------------------------------------------
local function Build()
    local r = { lines = {}, missing = {}, summary = {} }
    local function add(s) r.lines[#r.lines + 1] = s end

    add("== environment ==")
    local version, build, buildDate, tocVersion = "?", "?", "?", "?"
    pcall(function() version, build, buildDate, tocVersion = GetBuildInfo() end)
    add(string.format("client %s build %s (%s)  interface %s",
        tostring(version), tostring(build), tostring(buildDate), tostring(tocVersion)))
    add("probe " .. VERSION .. "   locale " .. tostring(GetLocale and GetLocale() or "?"))
    -- WOW_PROJECT_ID is how an addon tells the flavours apart. An unknown value here is the
    -- first thing worth knowing about a new branch: it is the number a TOC has to match.
    local proj = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and string.find(k, "^WOW_PROJECT_") and type(v) == "number" then
            proj[#proj + 1] = string.format("%s=%d", k, v)
        end
    end
    table.sort(proj)
    add("project id " .. tostring(_G.WOW_PROJECT_ID) .. "   constants: " ..
        (next(proj) and table.concat(proj, " ") or "none"))

    add("")
    add("== globals, per module ==")
    for _, name in ipairs({ "GaarBags", "GaarCC", "GaarCast", "GaarFrames", "GaarLooter",
                            "GaarMap", "GaarMeter", "GaarOptions", "GaarPlates",
                            "GaarSpellBook", "GaarThreat", "GaarUI" }) do
        local names = MODULES[name]
        if names then
            local gone, total = {}, #names
            for _, n in ipairs(names) do
                local kind = Kind(Resolve(n))
                if kind == "MISSING" then gone[#gone + 1] = n end
            end
            r.summary[#r.summary + 1] = { name, total - #gone, total, gone }
            add(string.format("%s: %d of %d present", name, total - #gone, total))
            if #gone > 0 then
                table.sort(gone)
                add("  missing: " .. table.concat(gone, " "))
                for _, n in ipairs(gone) do r.missing[n] = true end
            end
        end
    end

    add("")
    add("== every global, with type ==")
    local seen, all = {}, {}
    for _, names in pairs(MODULES) do
        for _, n in ipairs(names) do
            if not seen[n] then seen[n] = true; all[#all + 1] = n end
        end
    end
    table.sort(all)
    for _, n in ipairs(all) do
        add(string.format("  %-32s %s", n, Kind(Resolve(n))))
    end

    add("")
    add("== C_* namespaces ==")
    local nsNames = {}
    for ns in pairs(NAMESPACES) do nsNames[#nsNames + 1] = ns end
    table.sort(nsNames)
    for _, ns in ipairs(nsNames) do
        local tbl = _G[ns]
        if type(tbl) ~= "table" then
            add(string.format("%s: MISSING", ns))
        else
            local have, lack = {}, {}
            for _, fn in ipairs(NAMESPACES[ns]) do
                if type(tbl[fn]) == "function" then have[#have + 1] = fn else lack[#lack + 1] = fn end
            end
            add(string.format("%s: %d of %d", ns, #have, #have + #lack))
            if #have > 0 then add("  have: " .. table.concat(have, " ")) end
            if #lack > 0 then add("  lack: " .. table.concat(lack, " ")) end
        end
    end

    add("")
    add("== frames: old global vs modern path ==")
    for _, row in ipairs(FRAMES) do
        local label, old, new = row[1], row[2], row[3]
        add(string.format("  %-20s %-28s %-12s %-30s %s",
            label, old, Kind(Resolve(old)), new, Kind(Resolve(new))))
    end

    add("")
    add("== return shapes ==")
    add("-- a function that exists but hands back a different shape is the silent failure;")
    add("-- read these before assuming any call site still works")

    -- Container item info: three values on 3.3.5a, one table now.
    local cc = _G.C_Container
    add("  " .. Shape("C_Container.GetContainerItemInfo(0,1)", cc and cc.GetContainerItemInfo, 0, 1))
    add("  " .. Shape("GetContainerItemInfo(0,1)", _G.GetContainerItemInfo, 0, 1))
    add("  " .. Shape("C_Container.GetContainerNumSlots(0)", cc and cc.GetContainerNumSlots, 0))

    -- Tracking: the one that just cost a round here.
    local cm = _G.C_Minimap
    add("  " .. Shape("C_Minimap.GetNumTrackingTypes()", cm and cm.GetNumTrackingTypes))
    add("  " .. Shape("C_Minimap.GetTrackingInfo(1)", cm and cm.GetTrackingInfo, 1))
    add("  " .. Shape("GetTrackingInfo(1)", _G.GetTrackingInfo, 1))

    -- Auras: UnitAura went away on retail; the slot the icon sits in moved before that.
    add("  " .. Shape("UnitAura('player',1,'HELPFUL')", _G.UnitAura, "player", 1, "HELPFUL"))
    add("  " .. Shape("UnitBuff('player',1)", _G.UnitBuff, "player", 1))
    local ua = _G.C_UnitAuras
    add("  " .. Shape("C_UnitAuras.GetAuraDataByIndex('player',1)",
        ua and ua.GetAuraDataByIndex, "player", 1))

    -- Casting: the nameSubtext return disappeared, shifting everything after it.
    add("  " .. Shape("UnitCastingInfo('player')", _G.UnitCastingInfo, "player"))
    add("  " .. Shape("UnitChannelInfo('player')", _G.UnitChannelInfo, "player"))
    add("  |cff777777(both read nil unless you are mid-cast - run /gaarprobe while casting)|r")

    -- Items and spells.
    add("  " .. Shape("GetItemQualityColor(4)", _G.GetItemQualityColor, 4))
    add("  " .. Shape("GetItemInfoInstant(6948)", _G.GetItemInfoInstant, 6948))
    add("  " .. Shape("GetSpellBookItemName(1,'spell')", _G.GetSpellBookItemName, 1, "spell"))
    local csb = _G.C_SpellBook
    add("  " .. Shape("C_SpellBook.GetSpellBookItemName(1,0)",
        csb and csb.GetSpellBookItemName, 1, 0))
    add("  " .. Shape("GetNumSpellTabs()", _G.GetNumSpellTabs))

    -- The combat log getter. The old global reads nil on retail while the binary carries
    -- C_CombatLog and GetCurrentEventInfo separately, so the namespace has to be asked
    -- directly. Outside a combat log event it answers with nothing, which is still the useful
    -- answer here: it tells us whether calling it is allowed at all.
    local cl = _G.C_CombatLog
    add("  " .. Shape("C_CombatLog.GetCurrentEventInfo()", cl and cl.GetCurrentEventInfo))
    add("  " .. Shape("CombatLogGetCurrentEventInfo()", _G.CombatLogGetCurrentEventInfo))

    -- Threat and groups.
    add("  " .. Shape("UnitDetailedThreatSituation('player','target')",
        _G.UnitDetailedThreatSituation, "player", "target"))
    add("  " .. Shape("GetNumGroupMembers()", _G.GetNumGroupMembers))

    -- Loot rolls: the whole of GaarLooter rests on these.
    add("  " .. Shape("GetLootRollItemInfo(1)", _G.GetLootRollItemInfo, 1))
    local lh = _G.C_LootHistory
    add("  " .. Shape("C_LootHistory.GetNumItems()", lh and lh.GetNumItems))

    add("")
    add("== widget capability ==")
    -- These are not name lookups but behaviour: whether a frame can be given a backdrop, be
    -- bounded, or take a solid colour. Each one gated a rewrite during the Classic Era port.
    local function widget()
        local out = {}
        local ok, f = pcall(CreateFrame, "Frame", nil, _G.UIParent, "BackdropTemplate")
        if not ok or not f then
            out[#out + 1] = "BackdropTemplate = MISSING"
            ok, f = pcall(CreateFrame, "Frame", nil, _G.UIParent)
        else
            out[#out + 1] = "BackdropTemplate = ok"
        end
        if not ok or not f then return { "CreateFrame failed entirely" } end
        out[#out + 1] = "frame:SetBackdrop = " .. Kind(f.SetBackdrop)
        out[#out + 1] = "frame:SetResizeBounds = " .. Kind(f.SetResizeBounds)
        out[#out + 1] = "frame:SetMinResize = " .. Kind(f.SetMinResize)
        out[#out + 1] = "frame:SetClipsChildren = " .. Kind(f.SetClipsChildren)
        local t = f:CreateTexture(nil, "BACKGROUND")
        out[#out + 1] = "texture:SetColorTexture = " .. Kind(t.SetColorTexture)
        out[#out + 1] = "texture:SetGradient = " .. Kind(t.SetGradient)
        out[#out + 1] = "CreateColor = " .. Kind(_G.CreateColor)
        local fs = f:CreateFontString(nil, "OVERLAY")
        out[#out + 1] = "fontstring:SetFont = " .. Kind(fs.SetFont)
        out[#out + 1] = "STANDARD_TEXT_FONT = " .. Kind(_G.STANDARD_TEXT_FONT)
        local sb = pcall(CreateFrame, "StatusBar", nil, _G.UIParent)
        out[#out + 1] = "StatusBar = " .. (sb and "ok" or "MISSING")
        local cd = pcall(CreateFrame, "Cooldown", nil, _G.UIParent, "CooldownFrameTemplate")
        out[#out + 1] = "CooldownFrameTemplate = " .. (cd and "ok" or "MISSING")
        f:Hide()
        return out
    end
    local okw, widgets = pcall(widget)
    for _, l in ipairs(okw and widgets or { "widget probe failed" }) do add("  " .. l) end

    add("")
    add("== options and menus ==")
    for _, n in ipairs({ "Settings", "SettingsPanel", "InterfaceOptions_AddCategory",
                         "InterfaceOptionsFrame_OpenToCategory", "EasyMenu", "UIDropDownMenu_Initialize",
                         "MenuUtil", "hooksecurefunc", "UISpecialFrames", "UIParent" }) do
        add(string.format("  %-38s %s", n, Kind(Resolve(n))))
    end
    if type(_G.Settings) == "table" then
        local have = {}
        for _, fn in ipairs({ "RegisterCanvasLayoutCategory", "RegisterAddOnCategory",
                              "OpenToCategory", "RegisterVerticalLayoutCategory" }) do
            if type(_G.Settings[fn]) == "function" then have[#have + 1] = fn end
        end
        add("  Settings: " .. (next(have) and table.concat(have, " ") or "none of the expected"))
    end

    return r
end

-- ---------------------------------------------------------------------------
-- Output
--
-- Chat is for a glance; the SavedVariables file is the deliverable. It survives the session,
-- so the whole report can be read off disk afterwards rather than copied out of a scrollback.
-- ---------------------------------------------------------------------------
local function Run(toChat)
    local ok, r = pcall(Build)
    if not ok then
        print("|cffff6666" .. ADDON .. ":|r probe failed: " .. tostring(r))
        return
    end

    if type(GaarProbeDB) ~= "table" then GaarProbeDB = {} end
    GaarProbeDB.version = VERSION
    GaarProbeDB.when = date("%Y-%m-%d %H:%M:%S")
    GaarProbeDB.report = r.lines
    GaarProbeDB.summary = r.summary

    print("|cff33ff99" .. ADDON .. " " .. VERSION .. "|r")
    for _, row in ipairs(r.summary) do
        local name, have, total, gone = row[1], row[2], row[3], row[4]
        local colour = (have == total) and "|cff40ff40" or (have > total * 0.7 and "|cffffcc00" or "|cffff6666")
        print(string.format("  %s%-14s %d/%d|r%s", colour, name, have, total,
            (#gone > 0) and ("  |cff777777" .. table.concat(gone, " ") .. "|r") or ""))
    end
    print("  |cff777777" .. #r.lines .. " lines written to SavedVariables\\GaarProbe.lua|r")
    print("  |cff777777/gaarprobe dump prints it all; /gaarprobe copy opens a copyable box|r")
    print("  |cff777777/gaarprobe errors lists this session's Lua errors by frequency|r")

    if toChat then
        for _, l in ipairs(r.lines) do print(l) end
    end
    return r
end
_G.GaarProbe_Run = Run

-- A copyable box, for when the SavedVariables file is not to hand. Built from plain widgets:
-- this addon cannot rely on a template it has not checked for.
local copyFrame
local function ShowCopy(lines)
    if not copyFrame then
        local f = CreateFrame("Frame", "GaarProbeCopy", UIParent)
        f:SetSize(700, 500)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)

        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if bg.SetColorTexture then bg:SetColorTexture(0.05, 0.05, 0.06, 0.96) end

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -12)
        title:SetText(ADDON)

        local close = CreateFrame("Button", nil, f)
        close:SetSize(20, 20)
        close:SetPoint("TOPRIGHT", -8, -8)
        local x = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        x:SetPoint("CENTER"); x:SetText("x")
        close:SetScript("OnClick", function() f:Hide() end)

        local scroll = CreateFrame("ScrollFrame", "GaarProbeCopyScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -36)
        scroll:SetPoint("BOTTOMRIGHT", -30, 12)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(_G.ChatFontNormal or _G.GameFontHighlightSmall)
        edit:SetWidth(650)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)
        f.edit = edit

        table.insert(UISpecialFrames, "GaarProbeCopy")
        copyFrame = f
    end
    copyFrame.edit:SetText(table.concat(lines, "\n"))
    copyFrame.edit:HighlightText()
    copyFrame:Show()
end

-- ---------------------------------------------------------------------------
-- Error collection
--
-- Retail does not write an Errors/ folder - that is a Classic behaviour - so a session's Lua
-- errors live only in the on-screen frame, one page at a time. This puts them somewhere they
-- can be read afterwards: SavedVariables, which this addon already proved gets written.
--
-- Errors are counted by message rather than listed, because the ones that matter here repeat
-- hundreds of times a minute and the count is half the diagnosis. The previous handler is
-- always called, so the client's own error display behaves exactly as before.
-- ---------------------------------------------------------------------------
local MAX_DISTINCT = 300
local errorCounts, errorOrder, errorTotal = {}, {}, 0

local function RecordError(msg)
    if type(msg) ~= "string" then msg = tostring(msg) end
    errorTotal = errorTotal + 1
    local seen = errorCounts[msg]
    if seen then
        errorCounts[msg] = seen + 1
        return
    end
    if #errorOrder >= MAX_DISTINCT then return end
    errorCounts[msg] = 1
    errorOrder[#errorOrder + 1] = msg
end

local function SaveErrors()
    if type(GaarProbeDB) ~= "table" then GaarProbeDB = {} end
    local out = {}
    for _, msg in ipairs(errorOrder) do
        out[#out + 1] = { count = errorCounts[msg], message = msg }
    end
    table.sort(out, function(a, b) return a.count > b.count end)
    GaarProbeDB.errors = out
    GaarProbeDB.errorTotal = errorTotal
    GaarProbeDB.errorsWhen = date("%Y-%m-%d %H:%M:%S")
end

do
    local previous = geterrorhandler and geterrorhandler()
    if seterrorhandler then
        seterrorhandler(function(msg)
            -- Never let the collector itself become the error. Recording is best effort; the
            -- client's own handler is what must always run.
            pcall(RecordError, msg)
            pcall(SaveErrors)
            if previous then return previous(msg) end
        end)
    end
end

local function ReportErrors()
    SaveErrors()
    print(string.format("|cff33ff99%s|r %d errors, %d distinct", ADDON, errorTotal, #errorOrder))
    local rows = GaarProbeDB.errors or {}
    for i = 1, math.min(#rows, 15) do
        local r = rows[i]
        local m = r.message
        if #m > 150 then m = string.sub(m, 1, 150) .. "..." end
        print(string.format("  |cffffcc00%5d|r  %s", r.count, m))
    end
    if #rows > 15 then print(string.format("  |cff777777%d more in SavedVariables\\GaarProbe.lua|r", #rows - 15)) end
end

SLASH_GAARPROBE1 = "/gaarprobe"
SLASH_GAARPROBE2 = "/gprobe"
SlashCmdList["GAARPROBE"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "errors" then
        ReportErrors()
    elseif msg == "dump" then
        Run(true)
    elseif msg == "copy" then
        local r = Run(false)
        if r then ShowCopy(r.lines) end
    else
        Run(false)
    end
end

-- Runs itself once on login as well as on demand: a report that needs remembering is a report
-- that does not get made.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    Run(false)
end)
