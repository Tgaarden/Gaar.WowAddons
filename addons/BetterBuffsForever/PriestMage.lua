--[[
  BetterBuffsForever - the priest and mage modules. Loaded after BetterBuffsForever.lua, which
  owns the box, the rows, the aura scan and the settings, and before Dispel.lua, which adds each
  class's dispel panel to these modules. Both classes check one group buff, the way the druid
  checks Mark of the Wild, so one factory builds both modules from a small table.

    * Priest: Power Word: Fortitude. Warns when you lack it and, in a party or raid, lists every
      member who lacks it. Prayer of Fortitude counts as having it.
    * Mage: Arcane Intellect, the same way, but only for members whose class uses mana: a
      warrior or a rogue is never listed (hunter, paladin, priest, shaman, druid, mage and
      warlock are). A member whose class the client does not tell is listed.
      Arcane Brilliance counts as having it.
    * Only spells the character knows are checked: nothing before the buff is learned.
    * Left-click casts the highest rank you know on the member. Right-click casts the group
      version (Prayer of Fortitude, Arcane Brilliance) when you know it and are in a group (it
      needs its reagent); otherwise right-click does what left-click does.
    * Low reagents, only once the group version is known: Sacred Candle (17029) for Prayer of
      Fortitude, Arcane Powder (17020) for Arcane Brilliance (default 10 each).

  Spells (classic ranks; checked against WhatsTraining's class data):
    Power Word: Fortitude  1243, 1244, 1245, 2791, 10937, 10938 (ranks 1-6)
    Prayer of Fortitude    21562, 21564 (ranks 1-2, learned from a book)
    Arcane Intellect       1459, 1460, 1461, 10156, 10157 (ranks 1-5)
    Arcane Brilliance      23028 (rank 1, learned from a book)
  The buttons cast the localized name of the highest rank known, or the spell ID when the client
  gives no name. A buff is recognised by its spell ID, else by the localized name of any rank.
]]

local _, ns = ...

local On, Matches, MakeEntry = ns.On, ns.Matches, ns.MakeEntry

-- Classes without mana: Arcane Intellect is wasted on them.
local NO_MANA = { WARRIOR = true, ROGUE = true }

local CONFIGS = {
    PRIEST = {
        name = "Priest",
        key = "fort",                        -- option key, /bbuff word and section key
        label = "Power Word: Fortitude",
        groupLabel = "Prayer of Fortitude",
        ids = { 10938, 10937, 2791, 1245, 1244, 1243 },     -- highest rank first
        groupIds = { 21564, 21562 },
        reagent = 17029, reagentName = "Sacred Candle",
        threshold = { word = "prayer", key = "prayerMin", default = 10, label = "Prayer of Fortitude", choices = { 0, 5, 10, 20, 40 } },
        fakes = { "|cffc79c6eTankyboy|r", "|cff69ccf0Frostmage|r", "|cfffff569Stabsy|r" },
    },
    MAGE = {
        name = "Mage",
        key = "ai",
        label = "Arcane Intellect",
        groupLabel = "Arcane Brilliance",
        ids = { 10157, 10156, 1461, 1460, 1459 },
        groupIds = { 23028 },
        reagent = 17020, reagentName = "Arcane Powder",
        threshold = { word = "brilliance", key = "brillianceMin", default = 10, label = "Arcane Brilliance", choices = { 0, 5, 10, 20, 40 } },
        manaOnly = true,
        fakes = { "|cfff58cbaHealbot|r", "|cffffffffPriesty|r", "|cff9482c9Lockster|r" },
    },
}

local function NewModule(classFile, c)
    local spells = {}     -- buff / group = { value, knownID, text, label, icon, names, ids }
    local key, lower = c.key, c.name:lower()
    local M = {
        class = classFile,
        name = c.name,
        blurb = "a " .. lower .. "'s buff check: who lacks " .. c.label .. " (" .. c.groupLabel .. " counts"
            .. (c.manaOnly and "; only classes with mana" or "") .. "). Click a name to buff it.",
        reagentSpells = c.groupLabel,
        options = {
            { key = key, short = key, label = c.label .. " check" },
        },
        thresholds = { c.threshold },
    }

    function M.ResolveSpells()
        spells.buff = ns.ResolveSpell(c.ids, c.label)
        spells.group = ns.ResolveSpell(c.groupIds, c.groupLabel)
    end

    function M.WantsGroup()
        return On("group")
    end

    function M.Sections()
        return { { key = key, title = "Missing " .. ((spells.buff and spells.buff.label) or c.label) .. ":" } }
    end

    -- true / false, or nil when unknown (secret, refused).
    local function ScanUnit(unit)
        local buffs, unknown = ns.ReadBuffs(unit)
        for _, b in ipairs(buffs) do
            if Matches(b, spells.buff) or Matches(b, spells.group) then return true end
        end
        if unknown then return nil end
        return false
    end

    local function Wanted(unit)
        if unit == "player" then return true end
        if not On("group") then return false end
        if c.manaOnly then
            local cls = ns.UnitClassFile(unit)
            if cls and NO_MANA[cls] then return false end
        end
        return true
    end

    function M.Check(units, tankSet, entries, missing, stats)
        stats[key] = 0
        local buff = spells.buff
        if not (On(key) and buff and buff.value ~= nil) then return end
        local spell2 = ns.InGroup() and spells.group and spells.group.value or nil
        for _, u in ipairs(units) do
            if Wanted(u) then
                local ok, eligible = pcall(ns.Eligible, u)
                if ok and eligible then
                    stats.units = stats.units + 1
                    local ok2, has = pcall(ScanUnit, u)
                    if not ok2 then has = nil end
                    if has == nil then stats.unknown = stats.unknown + 1 end
                    if has == false then
                        local e = MakeEntry(key, u, buff, tankSet[u] and "tank" or nil)
                        if spell2 then e.spell2, e.spell2Label = spell2, spells.group.label end
                        entries[#entries + 1] = e
                        missing[key .. ":" .. (ns.UnitGUIDPlain(u) or u)] = true
                        stats[key] = stats[key] + 1
                    end
                end
            end
        end
    end

    -- The reagent of the group version, once it is known.
    function M.LowReagents()
        local low, checked = {}, {}
        local g = spells.group
        if g and g.knownID then
            local t = c.threshold
            ns.CheckReagent(low, checked, c.reagent, c.reagentName, t.key, t.default, g.label)
        end
        return low, checked
    end

    function M.Fake()
        local list = {}
        local buff = spells.buff or { label = c.label }
        for i, text in ipairs(c.fakes) do
            local far = i == 2
            list[#list + 1] = ns.FakeEntry(key, text .. (far and "|cffaaaaaa (out of range)|r" or ""), buff, far)
        end
        return list, { { name = c.reagentName, count = 3, min = ns.Threshold(c.threshold.key, c.threshold.default) } }
    end

    function M.Help()
        return {
            "/bbuff " .. key .. " [on|off] - the " .. c.label .. " check (" .. c.groupLabel .. " counts"
                .. (c.manaOnly and "; warriors and rogues are skipped" or "") .. ")",
        }
    end

    function M.Slash(cmd, arg)
        if cmd ~= key then return false end
        local v = ns.Toggle(arg, On(key))
        if v == nil then ns.Print("/bbuff " .. key .. " [on|off]") else ns.Set(key, v) end
        return true
    end

    local function SpellLine(k)
        local s = spells[k]
        return s and s.text or "not resolved yet"
    end

    function M.StatusSpells(pending)
        return {
            c.label .. ": " .. SpellLine("buff") .. (pending and " (update waits for combat to end)" or ""),
            c.groupLabel .. ": " .. SpellLine("group"),
        }
    end

    function M.StatusLast(s)
        return string.format("last check: %d members checked, %d lack %s, %d unknown (auras secret or refused)",
            s.units or 0, s[key] or 0, c.label, s.unknown or 0)
    end

    return M
end

for classFile, c in pairs(CONFIGS) do
    ns.modules[classFile] = NewModule(classFile, c)
end
