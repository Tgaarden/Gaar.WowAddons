--[[
  BetterBuffsForever - the paladin module. Loaded after BetterBuffsForever.lua, which owns the
  box, the rows, the aura scan, the tank and the settings; this file only says what a paladin
  checks.

    * Blessings, by class. Every member (you too) gets the blessing assigned to their class:
      Warrior, Rogue, Hunter -> Might; Mage, Priest, Warlock, Druid, Paladin, Shaman -> Wisdom.
      Change a class with /bbuff bless <class> <might|wisdom|kings|salvation|light|sanctuary|none>
      or the hub's "Blessings by class" submenu (account-wide; /bbuff bless reset for the
      defaults). Kings is never a default; it is the first fallback when you know it.
        - Covered: the member has the assigned type from anyone (any rank, normal or Greater).
        - Fallback: the assigned type is there from another paladin and the member has nothing
          from you (one blessing per paladin per target). Then the row asks for the first of
          Kings (if known) -> Might or Wisdom (the other one; for any other assigned type, the
          class's default of the two) -> Light that you know and the member does not already
          have; none left means nothing to do. The row says "(fallback)".
        - The tank never gets Salvation: a class assigned Salvation gives its tank the fallback
          (Kings -> Might/Wisdom -> Light) instead.
        - An assigned blessing you do not know is never warned about; "none" switches the class
          off. A member whose class is hidden is skipped.
        - Left-click casts the blessing on the member (the highest rank you know, by name).
          Right-click casts the Greater Blessing of that type on the member (all of that class
          in the group) when you know it (level 52+, Symbol of Kings); otherwise it does what
          left-click does.
    * No aura: when none of your paladin auras is on. The aura is read from the shapeshift bar
      (classic paladin auras are "forms" there): GetNumShapeshiftForms / GetShapeshiftFormInfo,
      a form whose spell ID is a paladin aura and whose isActive is true. Only when the bar
      lists no paladin aura at all (another client) are your own buffs read instead
      (isFromPlayerOrPlayerPet / sourceUnit = you). The row casts the aura you used last
      (remembered per character whenever the active form changes; Devotion Aura before that).
    * Righteous Fury: when you are the tank (role TANK, raid main tank, or the tank set by hand
      is you: the same tank rule as the druid's Thorns) or you said you are tanking
      (/bbuff tanking on, per character), and you lack Righteous Fury. The row casts it.
    * Low reagents: Symbol of Kings (21177), for the Greater Blessings, below 20 by default,
      only when you know a Greater Blessing.

  Spells (classic ranks, highest first):
    Blessing of Might       25291, 19838, 19837, 19836, 19835, 19834, 19740 (ranks 7-1)
    Blessing of Wisdom      25290, 19854, 19853, 19852, 19850, 19742 (ranks 6-1)
    Blessing of Kings       20217
    Blessing of Salvation   1038
    Blessing of Light       19979, 19978, 19977 (ranks 3-1)
    Blessing of Sanctuary   20914, 20913, 20912, 20911 (ranks 4-1)
    Greater Blessing of Might 25916, 25782; of Wisdom 25918, 25894; of Kings 25898; of
    Salvation 25895; of Light 25890; of Sanctuary 25899
    Righteous Fury          25780
    Devotion Aura           10293, 10292, 10291, 1032, 10290, 643, 465
    Retribution Aura        10301, 10300, 10299, 10298, 7294
    Concentration Aura      19746
    Shadow Resistance Aura  19896, 19895, 19876
    Frost Resistance Aura   19898, 19897, 19888
    Fire Resistance Aura    19900, 19899, 19891
    Sanctity Aura           20218
  A buff is recognised by its spell ID, else by the localized name of any rank.
]]

local _, ns = ...

local TYPES = { "might", "wisdom", "kings", "salvation", "light", "sanctuary" }
local BLESSING_IDS = {
    might = { 25291, 19838, 19837, 19836, 19835, 19834, 19740 },
    wisdom = { 25290, 19854, 19853, 19852, 19850, 19742 },
    kings = { 20217 },
    salvation = { 1038 },
    light = { 19979, 19978, 19977 },
    sanctuary = { 20914, 20913, 20912, 20911 },
}
local GREATER_IDS = {
    might = { 25916, 25782 }, wisdom = { 25918, 25894 }, kings = { 25898 },
    salvation = { 25895 }, light = { 25890 }, sanctuary = { 25899 },
}
local TYPE_NAMES = {
    might = "Blessing of Might", wisdom = "Blessing of Wisdom", kings = "Blessing of Kings",
    salvation = "Blessing of Salvation", light = "Blessing of Light", sanctuary = "Blessing of Sanctuary",
}
local SHORT = { might = "Might", wisdom = "Wisdom", kings = "Kings", salvation = "Salvation",
    light = "Light", sanctuary = "Sanctuary", none = "none" }

local AURAS = { "devotion", "retribution", "concentration", "shadow", "frost", "fire", "sanctity" }
local AURA_IDS = {
    devotion = { 10293, 10292, 10291, 1032, 10290, 643, 465 },
    retribution = { 10301, 10300, 10299, 10298, 7294 },
    concentration = { 19746 },
    shadow = { 19896, 19895, 19876 },
    frost = { 19898, 19897, 19888 },
    fire = { 19900, 19899, 19891 },
    sanctity = { 20218 },
}
local AURA_NAMES = {
    devotion = "Devotion Aura", retribution = "Retribution Aura", concentration = "Concentration Aura",
    shadow = "Shadow Resistance Aura", frost = "Frost Resistance Aura", fire = "Fire Resistance Aura",
    sanctity = "Sanctity Aura",
}
local AURA_OF_ID = {}
for key, ids in pairs(AURA_IDS) do
    for _, id in ipairs(ids) do AURA_OF_ID[id] = key end
end

local RF_IDS = { 25780 }
local SYMBOL_OF_KINGS, MIN_KINGS = 21177, 20

local CLASSES = { "WARRIOR", "ROGUE", "HUNTER", "MAGE", "PRIEST", "WARLOCK", "DRUID", "PALADIN", "SHAMAN" }
local CLASS_NAMES = { WARRIOR = "Warrior", ROGUE = "Rogue", HUNTER = "Hunter", MAGE = "Mage", PRIEST = "Priest",
    WARLOCK = "Warlock", DRUID = "Druid", PALADIN = "Paladin", SHAMAN = "Shaman" }
local DEFAULT_ASSIGN = { WARRIOR = "might", ROGUE = "might", HUNTER = "might", MAGE = "wisdom", PRIEST = "wisdom",
    WARLOCK = "wisdom", DRUID = "wisdom", PALADIN = "wisdom", SHAMAN = "wisdom" }
local VALID = { none = true }
for _, t in ipairs(TYPES) do VALID[t] = true end

local On, Matches, MakeEntry, Num, Bool = ns.On, ns.Matches, ns.MakeEntry, ns.Num, ns.Bool

local blessing, greater, aura = {}, {}, {}   -- type -> resolved spell
local rf                                     -- Righteous Fury, resolved

local M = {
    class = "PALADIN",
    name = "Paladin",
    blurb = "a paladin's buff check: blessings by class, no aura, and Righteous Fury when you tank. Click a name to buff it.",
    reagentSpells = "Greater Blessings",
    options = {
        { key = "bless", short = "bless", label = "Blessing check (by class)" },
        { key = "aura", short = "aura", label = "Warn when no aura is on" },
        { key = "fury", short = "fury", label = "Righteous Fury when tanking" },
    },
    thresholds = {
        { word = "kings", key = "kingsMin", default = MIN_KINGS, label = "Symbol of Kings", choices = { 0, 10, 20, 40, 60 } },
    },
    savedKeys = { blessings = true },             -- account-wide: class -> type, only the changed ones
    charKeys = { lastAura = true, tanking = true },
}

-- ---------------------------------------------------------------------------
-- Spells and assignments
-- ---------------------------------------------------------------------------

function M.ResolveSpells()
    for _, t in ipairs(TYPES) do
        blessing[t] = ns.ResolveSpell(BLESSING_IDS[t], TYPE_NAMES[t])
        greater[t] = ns.ResolveSpell(GREATER_IDS[t], "Greater " .. TYPE_NAMES[t])
    end
    for _, a in ipairs(AURAS) do aura[a] = ns.ResolveSpell(AURA_IDS[a], AURA_NAMES[a]) end
    rf = ns.ResolveSpell(RF_IDS, "Righteous Fury")
end

local function KnowsType(t)
    return t ~= nil and blessing[t] ~= nil and blessing[t].value ~= nil
end

local function AnyKnown(set, keys)
    for _, k in ipairs(keys) do
        if set[k] and set[k].value ~= nil then return true end
    end
    return false
end

local function Assigned(classFile)
    local db = ns.DB()
    local saved = db and type(db.blessings) == "table" and db.blessings[classFile]
    return saved or DEFAULT_ASSIGN[classFile] or "none"
end

-- The first of Kings -> Might/Wisdom (the other one) -> Light that is known, is not t, and the
-- member does not already have (has may be nil: then only "known" and "not t" count).
local function Fallback(t, classFile, has)
    local other = (t == "might" and "wisdom") or (t == "wisdom" and "might")
        or (DEFAULT_ASSIGN[classFile] == "might" and "might") or "wisdom"
    for _, c in ipairs({ "kings", other, "light" }) do
        if c ~= t and KnowsType(c) and not (has and has[c]) then return c end
    end
    return nil
end

-- The blessing type a member should get from you, ignoring their buffs.
local function Wanted(classFile, isTank)
    local t = Assigned(classFile)
    if t == "salvation" and isTank then t = Fallback("salvation", classFile, nil) end
    return t
end

local function TypeOf(b)
    for _, t in ipairs(TYPES) do
        if Matches(b, blessing[t]) or Matches(b, greater[t]) then return t end
    end
    return nil
end

-- What to cast on a member: type, note ("fallback"), unknown. nil type = nothing to do.
local function BlessingFor(unit, isTank, buffs, scanUnknown)
    local classFile = ns.UnitClassFile(unit)
    if not classFile then return nil end
    local t = Wanted(classFile, isTank)
    if not t or t == "none" or not KnowsType(t) then return nil end
    local has, anyMine, mineUnknown = {}, false, false
    for _, b in ipairs(buffs) do
        local bt = TypeOf(b)
        if bt then
            has[bt] = true
            if b.mine == true then anyMine = true elseif b.mine == nil then mineUnknown = true end
        end
    end
    if has[t] then
        if anyMine then return nil end                           -- covered, something of yours is on
        if mineUnknown or scanUnknown then return nil, nil, true end
        local fb = Fallback(t, classFile, has)
        if fb then return fb, "fallback", nil, t end
        return nil
    end
    if scanUnknown then return nil, nil, true end
    return t
end

-- ---------------------------------------------------------------------------
-- Aura and Righteous Fury
-- ---------------------------------------------------------------------------

-- The active paladin aura from the shapeshift bar: its key, false when the bar lists paladin
-- auras but none is active, nil when the bar says nothing about paladin auras (or hides it).
local function FormAura()
    if type(_G.GetShapeshiftFormInfo) ~= "function" then return nil end
    local n = Num(ns.Call("GetNumShapeshiftForms"))
    if not n then return nil end
    local saw, hidden = false, false
    for i = 1, math.min(n, 10) do
        local ok, _, active, _, spellID = pcall(_G.GetShapeshiftFormInfo, i)
        local key = ok and AURA_OF_ID[Num(spellID) or 0]
        if key then
            saw = true
            local on = Bool(active)
            if on == nil then hidden = true elseif on then return key end
        end
    end
    if not saw or hidden then return nil end
    return false
end

-- The same from your own buffs: key, false, or nil when unknown.
local function BuffAura(buffs, scanUnknown)
    local unsure = scanUnknown
    for _, b in ipairs(buffs) do
        for _, a in ipairs(AURAS) do
            if Matches(b, aura[a]) then
                if b.mine == true then return a end
                if b.mine == nil then unsure = true end
            end
        end
    end
    if unsure then return nil end
    return false
end

local function CurrentAura(buffs, scanUnknown)
    local f = FormAura()
    if f then return f, "shapeshift bar" end
    if f == false then return false, "shapeshift bar" end
    return BuffAura(buffs, scanUnknown), "your buffs"
end

local function RememberAura(key)
    local c = ns.CharDB()
    if key and c then c.lastAura = key end
end

-- The aura the "No aura" row casts: the one used last, else the first you know.
local function AuraToCast()
    local c = ns.CharDB()
    local last = c and c.lastAura
    if last and aura[last] and aura[last].value then return aura[last], "last used" end
    for _, a in ipairs(AURAS) do
        if aura[a] and aura[a].value then return aura[a], "default" end
    end
    return nil
end

function M.OnEvent()
    local ok, key = pcall(FormAura)
    if ok and key then RememberAura(key) end
end

local function Tanking()
    local c = ns.CharDB()
    return c and c.tanking == true
end

-- ---------------------------------------------------------------------------
-- The check
-- ---------------------------------------------------------------------------

function M.WantsGroup()
    return On("group") or On("fury")
end

function M.Sections()
    local list = {}
    for _, t in ipairs(TYPES) do
        list[#list + 1] = { key = "bless_" .. t,
            title = "Missing " .. ((blessing[t] and blessing[t].label) or TYPE_NAMES[t]) .. ":" }
    end
    list[#list + 1] = { key = "aura", title = "No aura:" }
    list[#list + 1] = { key = "fury", title = "Missing " .. ((rf and rf.label) or "Righteous Fury") .. ":" }
    return list
end

function M.Check(units, tankSet, entries, missing, stats)
    stats.bless, stats.aura, stats.fury = 0, "ok", "ok"
    local blessOn = On("bless") and AnyKnown(blessing, TYPES)
    local auraOn = On("aura") and AnyKnown(aura, AURAS)
    local furyOn = On("fury") and rf and rf.value ~= nil and (tankSet.player or Tanking())
    if not furyOn then stats.fury = "not checked" end
    if not auraOn then stats.aura = "not checked" end
    for _, u in ipairs(units) do
        local isPlayer = u == "player"
        local wantBless = blessOn and (isPlayer or On("group"))
        if wantBless or (isPlayer and (auraOn or furyOn)) then
            local ok, eligible = pcall(ns.Eligible, u)
            if ok and eligible then
                stats.units = stats.units + 1
                local unknownHere = false
                local okR, buffs, scanUnknown = pcall(ns.ReadBuffs, u)
                if not okR then buffs, scanUnknown = {}, true end
                local guid = ns.UnitGUIDPlain(u) or u

                if wantBless then
                    local okB, t, note, unk, assigned = pcall(BlessingFor, u, tankSet[u], buffs, scanUnknown)
                    if not okB then t, unk = nil, true end
                    if unk then unknownHere = true end
                    if t then
                        local extra = {}
                        if tankSet[u] then extra[#extra + 1] = "tank" end
                        if note then extra[#extra + 1] = note end
                        local e = MakeEntry("bless_" .. t, u, blessing[t], #extra > 0 and table.concat(extra, ", ") or nil)
                        local g = greater[t]
                        if g and g.value then e.spell2, e.spell2Label = g.value, g.label .. " (whole class)" end
                        if note == "fallback" and assigned then
                            e.note = "Fallback: " .. TYPE_NAMES[assigned] .. " is already on from another paladin."
                        end
                        entries[#entries + 1] = e
                        missing["bless:" .. guid .. ":" .. t] = true
                        stats.bless = stats.bless + 1
                    end
                end

                if isPlayer and auraOn then
                    local key = CurrentAura(buffs, scanUnknown)
                    if key then
                        RememberAura(key)
                    elseif key == false then
                        local spell, why = AuraToCast()
                        if spell then
                            local e = MakeEntry("aura", "player", spell)
                            e.text = "|cffffffff" .. spell.label .. "|r|cffaaaaaa (" .. why .. ")|r"
                            e.leftText = "Left-click: cast " .. spell.label
                            e.plainName = "No aura"
                            entries[#entries + 1] = e
                            missing["aura"] = true
                            stats.aura = "missing"
                        end
                    else
                        unknownHere = true
                        stats.aura = "unknown"
                    end
                end

                if isPlayer and furyOn then
                    local has = false
                    for _, b in ipairs(buffs) do
                        if Matches(b, rf) then has = true break end
                    end
                    if not has and scanUnknown then
                        unknownHere = true
                        stats.fury = "unknown"
                    elseif not has then
                        entries[#entries + 1] = MakeEntry("fury", "player", rf, tankSet.player and "tank" or "tanking")
                        missing["fury"] = true
                        stats.fury = "missing"
                    end
                end
                if unknownHere then stats.unknown = stats.unknown + 1 end
            end
        end
    end
end

-- Symbol of Kings, only while a Greater Blessing is known.
function M.LowReagents()
    local low, checked = {}, {}
    if AnyKnown(greater, TYPES) then
        ns.CheckReagent(low, checked, SYMBOL_OF_KINGS, "Symbol of Kings", "kingsMin", MIN_KINGS, "Greater Blessings")
    end
    return low, checked
end

function M.Fake()
    local function s(set, key, label)
        return set[key] or { label = label }
    end
    local might, wisdom = s(blessing, "might", TYPE_NAMES.might), s(blessing, "wisdom", TYPE_NAMES.wisdom)
    local list = {
        ns.FakeEntry("bless_might", "|cffc79c6eTankyboy|r|cffaaaaaa (tank)|r", might),
        ns.FakeEntry("bless_might", "|cfffff569Stabsy|r|cffaaaaaa (out of range)|r", might, true),
        ns.FakeEntry("bless_wisdom", "|cff69ccf0Frostmage|r", wisdom),
        ns.FakeEntry("bless_kings", "|cffffffffHealbot|r|cffaaaaaa (fallback)|r", s(blessing, "kings", TYPE_NAMES.kings)),
        ns.FakeEntry("aura", "|cffffffffDevotion Aura|r|cffaaaaaa (last used)|r", s(aura, "devotion", AURA_NAMES.devotion)),
        ns.FakeEntry("fury", "|cfff58cbaYou|r|cffaaaaaa (tanking)|r", rf or { label = "Righteous Fury" }),
    }
    return list, { { name = "Symbol of Kings", count = 12, min = ns.Threshold("kingsMin", MIN_KINGS) } }
end

-- ---------------------------------------------------------------------------
-- Commands, status and menu
-- ---------------------------------------------------------------------------

local function SetAssignment(classFile, t, quiet)
    local db = ns.DB()
    if type(db.blessings) ~= "table" then db.blessings = {} end
    db.blessings[classFile] = (t ~= DEFAULT_ASSIGN[classFile]) and t or nil
    if next(db.blessings) == nil then db.blessings = nil end
    ns.Refresh()
    if not quiet then
        ns.Print(CLASS_NAMES[classFile] .. ": " .. (t == "none" and "no blessing" or TYPE_NAMES[t])
            .. (t == "salvation" and " (a tank of that class gets the fallback)" or "") .. ".")
    end
end

local function AssignmentText()
    local parts = {}
    for _, c in ipairs(CLASSES) do
        local t = Assigned(c)
        parts[#parts + 1] = CLASS_NAMES[c] .. " " .. SHORT[t] .. (t ~= DEFAULT_ASSIGN[c] and "*" or "")
    end
    return table.concat(parts, ", ")
end

function M.Help()
    return {
        "/bbuff bless [on|off] - the blessing check by class; /bbuff bless <class> <might|wisdom|kings|salvation|light|sanctuary|none>; /bbuff bless reset",
        "/bbuff aura [on|off] - warn when none of your auras is on (click: the aura you used last)",
        "/bbuff fury [on|off] - warn when you tank without Righteous Fury; /bbuff tanking [on|off] - say you are tanking (this character)",
        "/bbuff tank - your target is the tank (Righteous Fury when it is you, no Salvation for the tank); /bbuff tank clear",
    }
end

function M.Slash(cmd, arg)
    if cmd == "aura" or cmd == "fury" then
        local v = ns.Toggle(arg, On(cmd))
        if v == nil then ns.Print("/bbuff " .. cmd .. " [on|off]") else ns.Set(cmd, v) end
        return true
    elseif cmd == "tanking" then
        local v = ns.Toggle(arg, Tanking())
        if v == nil then
            ns.Print("/bbuff tanking [on|off]")
        else
            ns.CharDB().tanking = v or nil
            ns.Refresh()
            ns.Print("tanking (this character): " .. ns.OnOff(v) .. ".")
        end
        return true
    elseif cmd == "bless" then
        local v = ns.Toggle(arg, On("bless"))
        if v ~= nil then
            ns.Set("bless", v)
            return true
        end
        if arg == "reset" then
            ns.DB().blessings = nil
            ns.Refresh()
            ns.Print("blessings back to the defaults: " .. AssignmentText())
            return true
        end
        local c, t = arg:match("^(%a+)%s+(%a+)$")
        local classFile = c and c:upper()
        if classFile and DEFAULT_ASSIGN[classFile] and VALID[t] then
            SetAssignment(classFile, t)
        else
            ns.Print("/bbuff bless [on|off], /bbuff bless <class> <might|wisdom|kings|salvation|light|sanctuary|none>, /bbuff bless reset")
            ns.Print("now: " .. AssignmentText())
        end
        return true
    end
    return false
end

local function Line(s, fallback)
    return s and s.text or (fallback .. ": not resolved yet")
end

function M.StatusSpells(pending)
    local lines = {}
    local known, greaterKnown = {}, {}
    for _, t in ipairs(TYPES) do
        if KnowsType(t) then known[#known + 1] = SHORT[t] end
        if greater[t] and greater[t].value then greaterKnown[#greaterKnown + 1] = SHORT[t] end
    end
    lines[#lines + 1] = "blessings known: " .. (#known > 0 and table.concat(known, ", ") or "none")
        .. "   Greater: " .. (#greaterKnown > 0 and table.concat(greaterKnown, ", ") or "none")
        .. (pending and " (update waits for combat to end)" or "")
    for _, t in ipairs(TYPES) do
        if KnowsType(t) then lines[#lines + 1] = "  " .. Line(blessing[t], TYPE_NAMES[t]) end
    end
    lines[#lines + 1] = "assignments: " .. AssignmentText() .. " (* changed; the tank never gets Salvation)"
    local auras = {}
    for _, a in ipairs(AURAS) do
        if aura[a] and aura[a].value then auras[#auras + 1] = aura[a].label end
    end
    local okA, cur, source = pcall(function()
        local buffs, unknown = ns.ReadBuffs("player")
        return CurrentAura(buffs, unknown)
    end)
    local c = ns.CharDB()
    lines[#lines + 1] = "auras known: " .. (#auras > 0 and table.concat(auras, ", ") or "none")
        .. "   active: " .. ((okA and cur and AURA_NAMES[cur]) or (okA and cur == false and "none") or "unknown")
        .. " (" .. tostring(okA and source or "?") .. ")"
        .. "   last used: " .. ((c and c.lastAura and AURA_NAMES[c.lastAura]) or "none (Devotion Aura)")
    lines[#lines + 1] = "Righteous Fury: " .. Line(rf, "Righteous Fury")
        .. "   tanking (this character): " .. ns.OnOff(Tanking())
    return lines
end

function M.StatusLast(s)
    return string.format("last check: %d members checked, %d need a blessing, aura %s, Righteous Fury %s, %d unknown (auras secret or refused)",
        s.units or 0, s.bless or 0, tostring(s.aura or "-"), tostring(s.fury or "-"), s.unknown or 0)
end

function M.Menu()
    local perClass = {}
    for _, c in ipairs(CLASSES) do
        local sub = {}
        for _, t in ipairs({ "might", "wisdom", "kings", "salvation", "light", "sanctuary", "none" }) do
            sub[#sub + 1] = { text = (t == "none" and "None" or TYPE_NAMES[t]) .. (t == DEFAULT_ASSIGN[c] and " (default)" or ""),
                radio = true,
                checked = function() return Assigned(c) == t end,
                func = function() SetAssignment(c, t) end }
        end
        local hex = ns.ClassHex(c)
        local name = hex and ("|c" .. hex .. CLASS_NAMES[c] .. "|r") or CLASS_NAMES[c]
        perClass[#perClass + 1] = { text = name .. ": " .. SHORT[Assigned(c)], submenu = sub }
    end
    perClass[#perClass + 1] = { divider = true }
    perClass[#perClass + 1] = { text = "Reset to defaults", func = function()
        ns.DB().blessings = nil
        ns.Refresh()
        ns.Print("blessings back to the defaults: " .. AssignmentText())
    end }
    return {
        { text = "Blessings by class", submenu = perClass },
        { text = "I'm tanking (this character)", checkbox = true,
          checked = function() return Tanking() end,
          func = function() M.Slash("tanking", Tanking() and "off" or "on") end },
    }
end

-- Keeps only valid assignments and per-character keys.
function M.Bind(db, charDb)
    local b = db.blessings
    if type(b) == "table" then
        local clean = {}
        for _, c in ipairs(CLASSES) do
            local t = b[c]
            if type(t) == "string" and VALID[t] and t ~= DEFAULT_ASSIGN[c] then clean[c] = t end
        end
        db.blessings = next(clean) and clean or nil
    else
        db.blessings = nil
    end
    if not (type(charDb.lastAura) == "string" and AURA_IDS[charDb.lastAura]) then charDb.lastAura = nil end
    if charDb.tanking ~= true then charDb.tanking = nil end
end

ns.modules.PALADIN = M
