--[[
  BetterBuffsForever - the shaman module. Loaded after BetterBuffsForever.lua, which owns the
  box, the rows, the aura scan and the settings; this file only says what a shaman checks. A
  shaman has no group buff, so only you are checked (the dispel panel in Dispel.lua still looks
  at the whole group).

    * Weapon imbue: a "No weapon imbue:" row per hand that holds a weapon without a temporary
      enchant (GetWeaponEnchantInfo): the main hand, and the off hand only when it holds a weapon
      (not a shield, an off-hand item or nothing). Any temporary enchant counts (an imbue, a
      poison, a sharpening stone, ...); a fishing pole is never warned about. The row casts the
      imbue you chose (/bbuff imbue <name>, per character, also in the hub menu): Rockbiter,
      Flametongue, Frostbrand or Windfury Weapon, the highest rank you know, by name. "auto"
      (the default) is Windfury Weapon when known, else Flametongue, else Rockbiter; a chosen
      imbue you do not know falls back to auto. Since 1.6.0 a temporary enchant with less than
      the "expiring" minutes left (GetWeaponEnchantInfo's time left, plain only) gets a row
      under "Weapon imbue expiring:" with the time, "(1:45)"; a click recasts the imbue. The
      weapon state has no cheap event of its own on every client, so while the check is on the
      box is also refreshed every 1.5 s (out of combat only, like everything else).
    * Lightning Shield: a row when you lack it, once you know it, and under "Expiring Lightning
      Shield:" when it runs out within the "expiring" minutes. The row casts it.
    * Low reagents, each only once you know the spell that needs it:
        Ankh (17030)               Reincarnation, below 2 by default (/bbuff reagents ankh <n>)
        Earth/Fire/Water/Air Totem (5175/5176/5177/5178)
                                   once you know any totem of that element; the item is not
                                   used up, so the default threshold is 1: warns only when it is
                                   not in your bags (/bbuff reagents totems 0|1)
        Shiny Fish Scales (17057)  Water Breathing, below 5 by default
        Fish Oil (17058)           Water Walking, below 5 by default (/bbuff reagents water <n>)
      Counted by item ID, and by the item's name when the ID finds none.

  Spells (classic ranks, highest first; the same IDs as WhatsTraining's Vanilla shaman data):
    Rockbiter Weapon     16316, 16315, 16314, 10399, 8019, 8018, 8017
    Flametongue Weapon   16342, 16341, 16339, 8030, 8027, 8024
    Frostbrand Weapon    16356, 16355, 10456, 8038, 8033
    Windfury Weapon      16362, 10486, 8235, 8232
    Lightning Shield     10432, 10431, 8134, 945, 905, 325, 324
    Reincarnation 20608; Water Breathing 131; Water Walking 546
    Totems (rank 1 of each, for "an element is known"):
      Earth  Stoneskin 8071, Earthbind 2484, Stoneclaw 5730, Strength of Earth 8075, Tremor 8143
      Fire   Searing 3599, Fire Nova 1535, Frost Resistance 8181, Magma 8190, Flametongue 8227
      Water  Healing Stream 5394, Poison Cleansing 8166, Mana Spring 5675, Fire Resistance 8184,
             Disease Cleansing 8170
      Air    Grounding 8177, Nature Resistance 10595, Windfury 8512, Sentry 6495, Windwall 15107,
             Grace of Air 8835, Tranquil Air 25908
  A buff is recognised by its spell ID, else by the localized name of any rank.
]]

local _G = _G
local _, ns = ...

local IMBUES = { "rockbiter", "flametongue", "frostbrand", "windfury" }
local IMBUE_IDS = {
    rockbiter = { 16316, 16315, 16314, 10399, 8019, 8018, 8017 },
    flametongue = { 16342, 16341, 16339, 8030, 8027, 8024 },
    frostbrand = { 16356, 16355, 10456, 8038, 8033 },
    windfury = { 16362, 10486, 8235, 8232 },
}
local IMBUE_NAMES = { rockbiter = "Rockbiter Weapon", flametongue = "Flametongue Weapon",
    frostbrand = "Frostbrand Weapon", windfury = "Windfury Weapon" }
local AUTO_ORDER = { "windfury", "flametongue", "rockbiter" }

local LSHIELD_IDS = { 10432, 10431, 8134, 945, 905, 325, 324 }
local REINCARNATION_IDS = { 20608 }
local BREATHING_IDS, WALKING_IDS = { 131 }, { 546 }

local ELEMENTS = { "earth", "fire", "water", "air" }
local ELEMENT_NAMES = { earth = "Earth", fire = "Fire", water = "Water", air = "Air" }
local TOTEM_IDS = {
    earth = { 8071, 2484, 5730, 8075, 8143 },
    fire = { 3599, 1535, 8181, 8190, 8227 },
    water = { 5394, 8166, 5675, 8184, 8170 },
    air = { 8177, 10595, 8512, 6495, 15107, 8835, 25908 },
}
local TOTEM_ITEM = { earth = 5175, fire = 5176, water = 5177, air = 5178 }
local ANKH, FISH_SCALES, FISH_OIL = 17030, 17057, 17058
local ITEM_NAMES = {
    [5175] = "Earth Totem", [5176] = "Fire Totem", [5177] = "Water Totem", [5178] = "Air Totem",
    [ANKH] = "Ankh", [FISH_SCALES] = "Shiny Fish Scales", [FISH_OIL] = "Fish Oil",
}
local MIN_ANKH, MIN_TOTEM, MIN_WATER = 2, 1, 5

local MAIN_HAND, OFF_HAND = 16, 17
local HANDS = { { slot = MAIN_HAND, key = "main", label = "Main hand" }, { slot = OFF_HAND, key = "off", label = "Off hand" } }
local WEAPON_CLASS, FISHING_POLE = 2, 20     -- Enum.ItemClass.Weapon, its fishing pole subclass
local WEAPON_LOC = { INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true, INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true }

local On, Matches, MakeEntry = ns.On, ns.Matches, ns.MakeEntry
local Secret, Num, Str = ns.Secret, ns.Num, ns.Str

local imbue = {}          -- imbue key -> resolved spell
local totem = {}          -- element -> resolved (any totem of it)
local spells = {}         -- lshield, reincarnation, breathing, walking

local M = {
    class = "SHAMAN",
    name = "Shaman",
    blurb = "a shaman's buff check: a weapon without an imbue, Lightning Shield, and low Ankhs, totems, Fish Oil and Shiny Fish Scales. Click a row to cast it.",
    reagentSpells = "Reincarnation, totems, Water Breathing and Water Walking",
    options = {
        { key = "imbue", short = "imbue", label = "Weapon imbue check" },
        { key = "shield", short = "shield", label = "Lightning Shield on you" },
    },
    thresholds = {
        { word = "ankh", key = "ankhMin", default = MIN_ANKH, label = "Ankh", choices = { 0, 1, 2, 3, 5 } },
        { word = "totems", key = "totemMin", default = MIN_TOTEM, label = "Totem items", choices = { 0, 1 } },
        { word = "water", key = "waterMin", default = MIN_WATER, label = "Fish Oil / Shiny Fish Scales", choices = { 0, 1, 5, 10, 20 } },
    },
    charKeys = { imbueChoice = true },     -- per character: the imbue a click casts (nil = auto)
}

local function Known(s) return s ~= nil and s.value ~= nil end

function M.ResolveSpells()
    for _, k in ipairs(IMBUES) do imbue[k] = ns.ResolveSpell(IMBUE_IDS[k], IMBUE_NAMES[k]) end
    for _, el in ipairs(ELEMENTS) do totem[el] = ns.ResolveSpell(TOTEM_IDS[el], ELEMENT_NAMES[el] .. " totems") end
    spells.lshield = ns.ResolveSpell(LSHIELD_IDS, "Lightning Shield")
    spells.reincarnation = ns.ResolveSpell(REINCARNATION_IDS, "Reincarnation")
    spells.breathing = ns.ResolveSpell(BREATHING_IDS, "Water Breathing")
    spells.walking = ns.ResolveSpell(WALKING_IDS, "Water Walking")
end

-- ---------------------------------------------------------------------------
-- The imbue to cast
-- ---------------------------------------------------------------------------

local function Choice()
    local c = ns.CharDB()
    local v = c and c.imbueChoice
    return (type(v) == "string" and IMBUE_IDS[v]) and v or "auto"
end

local function ChoiceLabel(choice)
    return choice == "auto" and "auto" or IMBUE_NAMES[choice]
end

-- The spell a click casts and why: "chosen", "auto", or "auto: <chosen> not known".
local function ImbueToCast()
    local choice = Choice()
    if choice ~= "auto" and Known(imbue[choice]) then return imbue[choice], "chosen" end
    for _, k in ipairs(AUTO_ORDER) do
        if Known(imbue[k]) then
            return imbue[k], choice == "auto" and "auto" or ("auto: " .. IMBUE_NAMES[choice] .. " not known")
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Weapons
-- ---------------------------------------------------------------------------

-- true: the slot holds a weapon an imbue can go on; false: empty, a shield, an off-hand item or a
-- fishing pole; nil: the client does not say.
local function HoldsWeapon(slot)
    local raw = ns.Call("GetInventoryItemID", "player", slot)
    if Secret(raw) then return nil end
    local id = Num(raw)
    if not id then return false end
    local C = _G.C_Item
    local f = (type(C) == "table" and type(C.GetItemInfoInstant) == "function" and C.GetItemInfoInstant)
        or (type(_G.GetItemInfoInstant) == "function" and _G.GetItemInfoInstant)
    if f then
        local ok, _, _, _, loc, _, classID, subID = pcall(f, id)
        if ok then
            classID, subID = Num(classID), Num(subID)
            if classID then return classID == WEAPON_CLASS and subID ~= FISHING_POLE end
            loc = Str(loc)
            if loc then return WEAPON_LOC[loc] == true end
        end
    end
    if slot == MAIN_HAND then return true end      -- the main hand holds only weapons
    return nil
end

-- Whether a "has enchant" value says yes: true / false, nil when secret.
local function Yes(v)
    if Secret(v) then return nil end
    return (v == true or v == 1) and true or false
end

-- hasMain, hasOff: true / false, nil when unknown; then the seconds left on each (nil when
-- not plain). GetWeaponEnchantInfo gives 8 values on a newer client (with the enchant IDs) and
-- 6 on an older one; the off hand's flag is the 5th or the 4th, its time (ms) the one after it.
local function Packed(...) return select("#", ...), { ... } end

local function Enchants()
    if type(_G.GetWeaponEnchantInfo) ~= "function" then return nil, nil end
    local n, r = Packed(pcall(_G.GetWeaponEnchantInfo))
    if not r[1] then return nil, nil end
    n = n - 1                                      -- without pcall's own "ok"
    if n == 0 then return false, false end
    local offIndex = n >= 7 and 5 or 4
    local mainMs, offMs = Num(r[3]), Num(r[offIndex + 2])
    return Yes(r[2]), Yes(r[offIndex + 1]), mainMs and mainMs / 1000 or nil, offMs and offMs / 1000 or nil
end

-- ---------------------------------------------------------------------------
-- The check
-- ---------------------------------------------------------------------------

function M.WantsGroup() return false end

-- The box is refreshed every 1.5 s while this is true (weapon enchants run out without an event
-- on some clients).
function M.Tick() return On("imbue") end

function M.Sections()
    return {
        { key = "imbue", title = "No weapon imbue:" },
        { key = "shield", title = "Missing " .. ((spells.lshield and spells.lshield.label) or "Lightning Shield") .. ":" },
        { key = "imbue_exp", title = "Weapon imbue expiring:" },
        { key = "shield_exp", title = "Expiring " .. ((spells.lshield and spells.lshield.label) or "Lightning Shield") .. ":" },
    }
end

function M.Check(units, tankSet, entries, missing, stats)
    stats.imbue, stats.shield = "not checked", "not checked"
    local ok, eligible = pcall(ns.Eligible, "player")
    if not (ok and eligible) then return end
    stats.units = stats.units + 1
    local unknownHere = false

    local spell, why = ImbueToCast()
    if On("imbue") and spell then
        stats.imbue = "ok"
        local okE, hasMain, hasOff, leftMain, leftOff = pcall(Enchants)
        if not okE then hasMain, hasOff, leftMain, leftOff = nil, nil, nil, nil end
        for _, h in ipairs(HANDS) do
            local okW, holds = pcall(HoldsWeapon, h.slot)
            -- Not "a and b or c": a main hand without an enchant (false) must not read the off hand's.
            local has, left = hasOff, leftOff
            if h.slot == MAIN_HAND then has, left = hasMain, leftMain end
            if okW and holds then
                if has == nil then
                    unknownHere = true
                    if stats.imbue ~= "missing" then stats.imbue = "unknown" end
                elseif has == false then
                    local e = MakeEntry("imbue", "player", spell)
                    e.text = "|cffffffff" .. h.label .. "|r|cffaaaaaa (" .. spell.label .. ", " .. why .. ")|r"
                    e.leftText = "Left-click: cast " .. spell.label
                    e.plainName = h.label .. ": no imbue"
                    if h.slot == OFF_HAND then
                        e.note = "The game picks the weapon an imbue lands on; with the main hand imbued it goes to the off hand."
                    end
                    ns.AddMissing(entries, missing, e, "imbue:" .. h.key)
                    stats.imbue = "missing"
                elseif has == true and ns.Expiring(left) then
                    local e = ns.ExpiringEntry("imbue_exp", "player", spell, left)
                    e.text = "|cffffffff" .. h.label .. "|r|cffaaaaaa (" .. spell.label .. ", " .. ns.Clock(left) .. ")|r"
                    e.leftText = "Left-click: cast " .. spell.label
                    e.plainName = h.label .. ": imbue expiring"
                    entries[#entries + 1] = e
                end
            elseif not okW or holds == nil then
                unknownHere = true
            end
        end
    end

    local ls = spells.lshield
    if On("shield") and Known(ls) then
        local okR, buffs, scanUnknown = pcall(ns.ReadBuffs, "player")
        if not okR then buffs, scanUnknown = {}, true end
        local has = false
        for _, b in ipairs(buffs) do
            if Matches(b, ls) then has = true break end
        end
        local left = has and ns.LeftOf(buffs, ls) or nil
        if has and ns.Expiring(left) then
            stats.shield = "expiring"
            entries[#entries + 1] = ns.ExpiringEntry("shield_exp", "player", ls, left)
        elseif has then
            stats.shield = "ok"
        elseif scanUnknown then
            unknownHere = true
            stats.shield = "unknown"
        else
            ns.AddMissing(entries, missing, MakeEntry("shield", "player", ls), "shield")
            stats.shield = "missing"
        end
    end
    if unknownHere then stats.unknown = stats.unknown + 1 end
end

-- One entry per reagent below its threshold, and every reagent checked (for /bbuff status).
function M.LowReagents()
    local low, checked = {}, {}
    local function Check(item, key, default, label)
        ns.CheckReagent(low, checked, item, ITEM_NAMES[item], key, default, label, true)
    end
    if Known(spells.reincarnation) then Check(ANKH, "ankhMin", MIN_ANKH, spells.reincarnation.label) end
    for _, el in ipairs(ELEMENTS) do
        if totem[el] and totem[el].knownID then Check(TOTEM_ITEM[el], "totemMin", MIN_TOTEM, ELEMENT_NAMES[el] .. " totems") end
    end
    if Known(spells.breathing) then Check(FISH_SCALES, "waterMin", MIN_WATER, spells.breathing.label) end
    if Known(spells.walking) then Check(FISH_OIL, "waterMin", MIN_WATER, spells.walking.label) end
    return low, checked
end

function M.Fake()
    local wf = imbue.windfury or { label = IMBUE_NAMES.windfury }
    local list = {
        ns.FakeEntry("imbue", "|cffffffffMain hand|r|cffaaaaaa (" .. wf.label .. ", auto)|r", wf),
        ns.FakeEntry("shield", "|cff0070deYou|r", spells.lshield or { label = "Lightning Shield" }),
        ns.FakeEntry("imbue_exp", "|cffffffffOff hand|r|cffaaaaaa (" .. wf.label .. ", 1:45)|r", wf),
    }
    return list, { { name = ITEM_NAMES[ANKH], count = 1, min = ns.Threshold("ankhMin", MIN_ANKH) } }
end

-- ---------------------------------------------------------------------------
-- Commands, status and menu
-- ---------------------------------------------------------------------------

local function SetChoice(choice)
    local c = ns.CharDB()
    if not c then return end
    c.imbueChoice = choice ~= "auto" and choice or nil
    ns.Refresh()
    local spell, why = ImbueToCast()
    ns.Print("weapon imbue (this character): " .. ChoiceLabel(choice)
        .. (spell and (" - a click casts " .. spell.label .. " (" .. why .. ")") or " - no imbue known yet") .. ".")
end

local IMBUE_WORDS = "auto|rockbiter|flametongue|frostbrand|windfury"

function M.Help()
    return {
        "/bbuff imbue [on|off] - warn when a weapon has no imbue (any temporary enchant counts); /bbuff imbue " .. IMBUE_WORDS
            .. " - what a click casts (this character; auto = Windfury, else Flametongue, else Rockbiter)",
        "/bbuff shield [on|off] - warn when you lack Lightning Shield",
    }
end

function M.Slash(cmd, arg)
    if cmd == "imbue" then
        local v = ns.Toggle(arg, On("imbue"))
        if v ~= nil then
            ns.Set("imbue", v)
        elseif arg == "auto" or IMBUE_IDS[arg] then
            SetChoice(arg)
        else
            ns.Print("/bbuff imbue [on|off], /bbuff imbue " .. IMBUE_WORDS .. "   now: " .. ChoiceLabel(Choice()))
        end
        return true
    elseif cmd == "shield" or cmd == "lshield" then
        local v = ns.Toggle(arg, On("shield"))
        if v == nil then ns.Print("/bbuff shield [on|off]") else ns.Set("shield", v) end
        return true
    end
    return false
end

local function Line(s, fallback)
    return s and s.text or (fallback .. ": not resolved yet")
end

local function HandText(slot, has)
    local okW, holds = pcall(HoldsWeapon, slot)
    if not okW or holds == nil then return "unknown" end
    if not holds then return "no weapon" end
    return has == nil and "weapon, imbue unknown" or (has and "imbued" or "no imbue")
end

function M.StatusSpells(pending)
    local lines = {}
    local known = {}
    for _, k in ipairs(IMBUES) do
        if Known(imbue[k]) then known[#known + 1] = imbue[k].label end
    end
    local spell, why = ImbueToCast()
    lines[#lines + 1] = "imbues known: " .. (#known > 0 and table.concat(known, ", ") or "none")
        .. "   choice (this character): " .. ChoiceLabel(Choice())
        .. "   a click casts: " .. (spell and (spell.text .. " (" .. why .. ")") or "nothing")
        .. (pending and " (update waits for combat to end)" or "")
    local okE, hasMain, hasOff = pcall(Enchants)
    if not okE then hasMain, hasOff = nil, nil end
    lines[#lines + 1] = "weapons: main hand " .. HandText(MAIN_HAND, hasMain) .. ", off hand " .. HandText(OFF_HAND, hasOff)
        .. "   GetWeaponEnchantInfo " .. ns.YesNo(type(_G.GetWeaponEnchantInfo) == "function")
    lines[#lines + 1] = "Lightning Shield: " .. Line(spells.lshield, "Lightning Shield")
    local elements = {}
    for _, el in ipairs(ELEMENTS) do
        if totem[el] and totem[el].knownID then elements[#elements + 1] = ELEMENT_NAMES[el] end
    end
    lines[#lines + 1] = "Reincarnation: " .. Line(spells.reincarnation, "Reincarnation")
        .. "   totem elements known: " .. (#elements > 0 and table.concat(elements, ", ") or "none")
    lines[#lines + 1] = "Water Breathing: " .. Line(spells.breathing, "Water Breathing")
        .. "   Water Walking: " .. Line(spells.walking, "Water Walking")
    return lines
end

function M.StatusLast(s)
    return string.format("last check: weapon imbue %s, Lightning Shield %s, %d unknown (secret or refused)",
        tostring(s.imbue or "-"), tostring(s.shield or "-"), s.unknown or 0)
end

function M.Menu()
    local sub = {}
    for _, k in ipairs({ "auto", "rockbiter", "flametongue", "frostbrand", "windfury" }) do
        sub[#sub + 1] = { text = (k == "auto" and "Auto (Windfury, Flametongue, Rockbiter)" or IMBUE_NAMES[k])
            .. (k == "auto" and " (default)" or ""),
            radio = true,
            checked = function() return Choice() == k end,
            func = function() SetChoice(k) end }
    end
    return {
        { text = "Weapon imbue (this character): " .. ChoiceLabel(Choice()), submenu = sub },
    }
end

-- Keeps only a valid imbue choice.
function M.Bind(_, charDb)
    local v = charDb.imbueChoice
    if not (type(v) == "string" and IMBUE_IDS[v]) then charDb.imbueChoice = nil end
end

ns.modules.SHAMAN = M
