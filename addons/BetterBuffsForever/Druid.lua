--[[
  BetterBuffsForever - the druid module. Loaded after BetterBuffsForever.lua, which owns the box,
  the rows, the aura scan, the tank and the settings; this file only says what a druid checks.

    * Mark of the Wild: warns when you lack it and, in a party or raid, lists every member who
      lacks it. Gift of the Wild counts as having it.
    * Thorns: warns when you lack it, and when the group's tank lacks it.
    * Only spells the character knows are checked: no Thorns warning before Thorns is learned.
    * Left-click casts on the member. Right-click on a Mark of the Wild row casts Gift of the
      Wild when you know it and are in a group (it needs its reagent); otherwise right-click
      does what left-click does.
    * Low reagents: the reagent for the highest rank you know of Gift of the Wild (rank 1 Wild
      Berries 17021, rank 2 Wild Thornroot 17026; default 10) and of Rebirth (rank 1 Maple Seed
      17034, 2 Stranglethorn Seed 17035, 3 Ashwood Seed 17036, 4 Hornbeam Seed 17037, 5 Ironwood
      Seed 17038; default 2). A spell you do not know is skipped.

  Spells (classic ranks, checked in game data):
    Mark of the Wild  1126, 5232, 6756, 5234, 8907, 9884, 9885 (ranks 1-7)
    Gift of the Wild  21849, 21850 (ranks 1-2)
    Thorns            467, 782, 1075, 8914, 9756, 9910 (ranks 1-6)
    Rebirth           20484, 20739, 20742, 20747, 20748 (ranks 1-5, reagents only)
  The buttons cast the localized name of the highest rank known, or the spell ID when the client
  gives no name. A buff is recognised by its spell ID, else by the localized name of any rank.
]]

local _, ns = ...

local MOTW_IDS = { 9885, 9884, 8907, 5234, 6756, 5232, 1126 }     -- highest rank first
local GOTW_IDS = { 21850, 21849 }
local THORNS_IDS = { 9910, 9756, 8914, 1075, 782, 467 }
local REBIRTH_IDS = { 20748, 20747, 20742, 20739, 20484 }

-- The reagent each rank uses: spell ID -> item ID, with an English fallback name for an item the
-- client has not cached yet.
local REAGENT_OF = {
    [21849] = 17021, [21850] = 17026,                                   -- Gift of the Wild
    [20484] = 17034, [20739] = 17035, [20742] = 17036, [20747] = 17037, [20748] = 17038, -- Rebirth
}
local ITEM_NAMES = {
    [17021] = "Wild Berries", [17026] = "Wild Thornroot", [17034] = "Maple Seed",
    [17035] = "Stranglethorn Seed", [17036] = "Ashwood Seed", [17037] = "Hornbeam Seed",
    [17038] = "Ironwood Seed",
}
local MIN_GOTW, MIN_REBIRTH = 10, 2

local On, Matches, MakeEntry = ns.On, ns.Matches, ns.MakeEntry

local spells = {}         -- motw/gotw/thorns/rebirth = { value, knownID, text, label, icon, names, ids }

local M = {
    class = "DRUID",
    name = "Druid",
    blurb = "a druid's buff check: who lacks Mark of the Wild, and whether you or your tank lack Thorns. Click a name to buff it.",
    reagentSpells = "Gift of the Wild and Rebirth",
    -- Boolean options (account-wide, on by default), in menu order; short = the /bbuff status name.
    options = {
        { key = "motw", short = "motw", label = "Mark of the Wild check" },
        { key = "thorns", short = "thorns", label = "Thorns on you" },
        { key = "thornsTank", short = "tank", label = "Thorns on the tank" },
    },
    thresholds = {
        { word = "gotw", key = "gotwMin", default = MIN_GOTW, label = "Gift of the Wild", choices = { 0, 5, 10, 20, 40 } },
        { word = "rebirth", key = "rebirthMin", default = MIN_REBIRTH, label = "Rebirth", choices = { 0, 1, 2, 3, 5 } },
    },
}

function M.ResolveSpells()
    spells.motw = ns.ResolveSpell(MOTW_IDS, "Mark of the Wild")
    spells.gotw = ns.ResolveSpell(GOTW_IDS, "Gift of the Wild")
    spells.thorns = ns.ResolveSpell(THORNS_IDS, "Thorns")
    spells.rebirth = ns.ResolveSpell(REBIRTH_IDS, "Rebirth")
end

function M.WantsGroup()
    return On("group") or On("thornsTank")
end

function M.Sections()
    return {
        { key = "motw", title = "Missing " .. ((spells.motw and spells.motw.label) or "Mark of the Wild") .. ":" },
        { key = "thorns", title = "Missing " .. ((spells.thorns and spells.thorns.label) or "Thorns") .. ":" },
    }
end

-- hasMotw (MotW or GotW), hasThorns: true / false, or nil when unknown (secret, refused).
local function ScanUnit(unit)
    local buffs, unknown = ns.ReadBuffs(unit)
    local motw, thorns = false, false
    for _, b in ipairs(buffs) do
        if Matches(b, spells.motw) or Matches(b, spells.gotw) then motw = true end
        if Matches(b, spells.thorns) then thorns = true end
    end
    if unknown then
        return motw or nil, thorns or nil
    end
    return motw, thorns
end

function M.Check(units, tankSet, entries, missing, stats)
    stats.motw, stats.thorns = 0, 0
    local motw, thorns = spells.motw, spells.thorns
    local checkMotw = On("motw") and motw and motw.value ~= nil
    local checkThorns = (On("thorns") or On("thornsTank")) and thorns and thorns.value ~= nil
    local inGroup = ns.InGroup()
    for _, u in ipairs(units) do
        local listMotw = u == "player" or On("group")
        local wantThorns = (u == "player" and On("thorns")) or (tankSet[u] and On("thornsTank"))
        if (checkMotw and listMotw) or (checkThorns and wantThorns) then
            local ok, eligible = pcall(ns.Eligible, u)
            if ok and eligible then
                stats.units = stats.units + 1
                local ok2, hasM, hasT = pcall(ScanUnit, u)
                if not ok2 then hasM, hasT = nil, nil end
                if hasM == nil or hasT == nil then stats.unknown = stats.unknown + 1 end
                local guid = ns.UnitGUIDPlain(u) or u
                if checkMotw and listMotw and hasM == false then
                    local spell2 = inGroup and spells.gotw and spells.gotw.value or nil
                    local e = MakeEntry("motw", u, motw, tankSet[u] and "tank" or nil)
                    if spell2 then e.spell2, e.spell2Label = spell2, spells.gotw.label end
                    entries[#entries + 1] = e
                    missing["motw:" .. guid] = true
                    stats.motw = stats.motw + 1
                end
                if checkThorns and wantThorns and hasT == false then
                    entries[#entries + 1] = MakeEntry("thorns", u, thorns, tankSet[u] and "tank" or nil)
                    missing["thorns:" .. guid] = true
                    stats.thorns = stats.thorns + 1
                end
            end
        end
    end
end

-- One entry per reagent below its threshold: { item, name, count, min, spell }. Also returns
-- every reagent checked, for /bbuff status.
function M.LowReagents()
    local low, checked = {}, {}
    for _, r in ipairs({ { "gotw", "gotwMin", MIN_GOTW }, { "rebirth", "rebirthMin", MIN_REBIRTH } }) do
        local s = spells[r[1]]
        local item = s and s.knownID and REAGENT_OF[s.knownID]
        if item then ns.CheckReagent(low, checked, item, ITEM_NAMES[item], r[2], r[3], s.label) end
    end
    return low, checked
end

function M.Fake()
    local list = {}
    local motw, thorns = spells.motw or { label = "Mark of the Wild" }, spells.thorns or { label = "Thorns" }
    local fakes = {
        { "motw", "|cffc79c6eTankyboy|r", motw }, { "motw", "|cfff58cbaHealbot|r|cffaaaaaa (out of range)|r", motw, true },
        { "motw", "|cff69ccf0Frostmage|r", motw }, { "thorns", "|cffc79c6eTankyboy|r|cffaaaaaa (tank)|r", thorns },
    }
    for _, f in ipairs(fakes) do list[#list + 1] = ns.FakeEntry(f[1], f[2], f[3], f[4]) end
    return list, { { name = ITEM_NAMES[17026], count = 3, min = ns.Threshold("gotwMin", MIN_GOTW) } }
end

function M.Help()
    return {
        "/bbuff motw [on|off] - the Mark of the Wild check (Gift of the Wild counts)",
        "/bbuff thorns [on|off] - warn when you lack Thorns",
        "/bbuff tank [on|off] - warn when the tank lacks Thorns; /bbuff tank set - your target is the tank; /bbuff tank clear",
    }
end

-- motw, thorns and tank on|off. Anything else is not a druid command.
function M.Slash(cmd, arg)
    if cmd == "motw" or cmd == "thorns" then
        local v = ns.Toggle(arg, On(cmd))
        if v == nil then ns.Print("/bbuff " .. cmd .. " [on|off]") else ns.Set(cmd, v) end
        return true
    elseif cmd == "tank" then
        if arg == "on" or arg == "off" then
            ns.Set("thornsTank", arg == "on")
        else
            ns.Print("/bbuff tank (your target is the tank), /bbuff tank clear, /bbuff tank on|off")
        end
        return true
    end
    return false
end

local function SpellLine(key)
    local s = spells[key]
    return s and s.text or "not resolved yet"
end

function M.StatusSpells(pending)
    return {
        "Mark of the Wild: " .. SpellLine("motw") .. (pending and " (update waits for combat to end)" or ""),
        "Gift of the Wild: " .. SpellLine("gotw"),
        "Thorns: " .. SpellLine("thorns"),
        "Rebirth: " .. SpellLine("rebirth"),
    }
end

function M.StatusLast(s)
    return string.format("last check: %d members checked, %d lack Mark of the Wild, %d lack Thorns, %d unknown (auras secret or refused)",
        s.units or 0, s.motw or 0, s.thorns or 0, s.unknown or 0)
end

ns.modules.DRUID = M
