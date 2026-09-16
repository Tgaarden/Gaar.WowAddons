--[[
  Gaar UI — the suite in one switch.

  This addon carries no features of its own. Its whole job is the Dependencies line in the
  TOC: tick this one in the AddOns list and the client pulls in every module with it. Each
  module remains a standalone addon that runs perfectly well without this one, which is why
  they are separate folders rather than files inside a single addon.

  What it does add is an answer to "what is actually loaded": /gaarui lists every module, its
  version, and whether it came up - which beats scrolling the AddOns list when something is
  quietly missing.
]]

local _G = _G
local ADDON = "Gaar UI"

-- The suite, in the order it makes sense to read them.
local MODULES = {
    { folder = "GaarOptions",   label = "Options",        slash = "/gaar" },
    { folder = "GaarBags",      label = "Bags",           slash = "/gaarbags" },
    { folder = "GaarCast",      label = "Cast",           slash = "/gaarcast" },
    { folder = "GaarCC",        label = "Cooldown Count", slash = "/gaarcc" },
    { folder = "GaarPlates",    label = "Plates",         slash = "/gaarplates" },
    { folder = "GaarThreat",    label = "Threat",         slash = "/gaarthreat" },
    { folder = "GaarMeter",     label = "Meter",          slash = "/gaarmeter" },
    { folder = "GaarFrames",    label = "Frames",         slash = "/gaarframes" },
    { folder = "GaarSpellBook", label = "Spell Book",     slash = "/spellbook" },
    { folder = "GaarLooter",    label = "Looter",         slash = "/gaarlooter" },
    { folder = "GaarMap",       label = "Map",            slash = "/gaarmap" },
}

-- Both the C_AddOns namespace and the old globals answer on this client; prefer the namespace
-- and fall back, so the same file works on a version that has dropped one or the other.
local function IsLoaded(name)
    if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) end
    if IsAddOnLoaded then return IsAddOnLoaded(name) end
    return false
end

local function Version(name)
    if C_AddOns and C_AddOns.GetAddOnMetadata then return C_AddOns.GetAddOnMetadata(name, "Version") end
    if GetAddOnMetadata then return GetAddOnMetadata(name, "Version") end
end

local function Report()
    print("|cff33ff99" .. ADDON .. "|r")
    local up, total = 0, #MODULES
    for _, m in ipairs(MODULES) do
        local loaded = IsLoaded(m.folder)
        if loaded then up = up + 1 end
        print(string.format("  %s %-14s |cff777777%s  %s|r",
            loaded and "|cff40ff40+|r" or "|cffff6666-|r",
            m.label, Version(m.folder) or "?", m.slash))
    end
    print(string.format("  |cff777777%d of %d loaded|r", up, total))
end
_G.GaarUI_Report = Report

SLASH_GAARUI1 = "/gaarui"
SlashCmdList["GAARUI"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "settings" or msg == "options" then
        if _G.GaarOptions_Open then _G.GaarOptions_Open("main") else Report() end
    else
        Report()
    end
end
