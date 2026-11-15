--[[
  BetterBuffsForever - the dispel panel of every class that can remove something: a druid
  (curses and poisons), a shaman (poisons and diseases), a priest (magic and diseases), a paladin
  (poisons and diseases, plus magic with Cleanse) and a mage (curses). Loaded after Druid.lua,
  Paladin.lua, Shaman.lua and PriestMage.lua; it hooks into those modules (options, slash
  command, help, status, hub menu) and keeps its own frames and events, so the buff box is
  untouched. What differs per class is
  one table, CLASS_CONFIG: one or two actions, each with its spells (the first one known is
  cast) and the kinds each spell removes. Two actions: left-click casts the first, right-click
  the second. One action: both mouse buttons cast it.

                left-click                      right-click
    Druid       Curse (purple): Remove Curse    Poison (green): Abolish Poison, else Cure Poison
    Shaman      Poison (green): Cure Poison     Disease (ochre): Cure Disease
    Priest      Magic (blue): Dispel Magic      Disease (ochre): Abolish Disease, else Cure Disease
    Paladin     both: Cleanse (poison, disease, magic), else Purify (poison, disease)
    Mage        both: Remove Lesser Curse (curse, purple)
    Warrior, Rogue, Hunter, Warlock: no panel (the warlock's Felhunter Devour Magic is left out
    on purpose: it is the pet's spell).

    * Only for those classes, and only spells you know: Remove Curse (2782), Abolish Poison
      (2893) and the druid's Cure Poison (8946; used for right-click only while Abolish Poison is
      not known); the shaman's Cure Poison (526) and Cure Disease (2870); the priest's Dispel
      Magic (988, 527: the highest rank, cast by name), Abolish Disease (552) and Cure Disease
      (528); the paladin's Cleanse (4987) and Purify (1152); the mage's Remove Lesser Curse (475).
      The IDs are the classic ones (WhatsTraining's Vanilla/Camelot class data have the same);
      they are resolved at login and on SPELLS_CHANGED / LEARNED_SPELL_IN_TAB like the buffs (by
      ID, else by the localized name), and /bbuff status shows what was found. Until the class's
      dispel spell is known (a low-level character) the panel stays hidden.
    * The kinds a member counts for are the ones the known spell removes: a paladin with only
      Purify is never shown a magic debuff; with Cleanse it is.
    * A panel of its own, not part of the buff box: by default just below the box (it follows the
      box), movable (/bbuff dispel unlock, or Alt + drag; /bbuff dispel reset), position saved
      account-wide as an offset from the top centre.
    * Out of combat: one row per member (you too) with something you can remove: the
      class-coloured name and a coloured tag per kind ("Magic" blue, "Curse" purple, "Poison"
      green, "Disease" ochre). Dead, offline and unseen members are skipped; out-of-range members
      are dimmed. Read with plain dispelName ("Magic", "Curse", "Poison", "Disease") from
      C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL").
    * In combat: a fixed strip with one secure button per group member: you alone, you and
      party1-4, or in a raid every raidN by subgroup (one column per subgroup that has members,
      up to 8 columns of 5: at most 40 small buttons). It is built out of combat on every roster
      change, and at PLAYER_REGEN_DISABLED if a rebuild is still due; a roster change in combat
      only relabels the names and the rebuild waits for PLAYER_REGEN_ENABLED (the buttons follow
      unit tokens, so they keep working). A state driver shows the strip for the whole fight
      ("[combat] show; hide") and the out-of-combat list the other way round.
    * The game draws the icons in combat (since 1.6.0): under each strip button a Blizzard aura
      container for that member shows the icon, the debuff's name, the member's name and a bar
      in the dispel type's colour whenever the member has a debuff of a kind you can remove,
      though this addon cannot read it then. The secure button stays on top, invisible, and
      takes the click. See "Client-drawn icons in combat" below; /bbuff status says whether it
      is active. Everything after this point is what the addon itself paints on the button.
    * A strip button is only seen when that member has something to remove: no dispellable
      debuff = the whole button at alpha 0 (SetAlpha is allowed on a secure button in combat;
      when the client answers "has one" with a secret boolean it goes straight to
      SetAlphaFromBoolean(has, 1, 0), never tested). An invisible button still takes clicks in
      combat (EnableMouse cannot change then), and its tooltip is skipped. The strip itself has
      no background, so a fight with nothing to remove shows nothing at all. Unknown counts as
      nothing (since 1.2.4): when no way answers (method "none", a failed detection, a secret
      answer SetAlphaFromBoolean refuses) the button is invisible too; only a real "has one"
      shows it.
    * A visible button shows what to remove, like the buff box's rows: the debuff's icon on the
      left, then "Name:" and the debuff's name (party/solo, 150 px wide, truncated to fit; in a
      raid the buttons are 58 px and show the icon and a short name only). The name and icon
      come from the first dispellable debuff Detect found (aura.name / aura.icon, or
      C_UnitAuras.GetAuraDataByAuraInstanceID on the aura instance ID); they may be secret and go
      straight to SetText / SetTexture in their own font string and texture, never joined to
      anything. Without them: a question mark and the kind ("Magic" / "Curse" / "Poison" /
      "Disease") or "Dispel". The colour is plain child textures (allowed in combat): the kinds
      found, in the class's order (left-click's first), the first on the left half and the second
      on the right half; a member with only one kind is that colour all over (a paladin with
      three kinds shows the first two); dispellable but of an unknown kind = yellow.
    * Clicks, on the rows and the strip alike: left-click (type1/spell1) = the first action's
      spell, right-click (type2/spell2) = the second's, or the same spell for a one-action class
      (paladin, mage); unit = the member's token. A click whose spell you do not know, or whose
      kinds are all switched off, does nothing. Registered for the one direction
      ActionButtonUseKeyDown acts on, like the buff rows.

  Detecting a dispellable debuff in combat. On this client (Forever 1.60.1, retail 12.x rules)
  auras are secret in combat and an index read from addon code is refused with an error (see
  BetterFramesForever). So each member is tried in this order, the first that answers wins, and
  /bbuff status says which one answered in the last fight:
    1. "plain read": GetAuraDataByIndex(unit, i, "HARMFUL") with a plain dispelName (UnitDebuff
       on an older client). Exact; this is what runs out of combat.
    2. "aura instance IDs": C_UnitAuras.GetUnitAuraInstanceIDs(unit, filter, 2) with the
       dispellable filter (the first of "HARMFUL|RAID_PLAYER_DISPELLABLE", "HARMFUL|RAID" that
       AuraUtil.IsValidFilterString accepts). A plain count answers "has one or not"; the colour
       comes from C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, curve) with a step
       colour curve over the dispel type (Magic 1 = blue, Curse 2 = purple, Disease 3 = ochre,
       Poison 4 = green, each only for a kind your known spell removes while it is switched on;
       anything else = transparent),
       passed straight to SetVertexColor, never read here. Without a colour it glows yellow.
    3. "filtered read": GetAuraDataByIndex(unit, 1..2, filter): a non-nil answer means "has
       one"; the kind from a plain dispelName, else the colour API on its auraInstanceID, else
       yellow.
    4. "none": unknown, so the button is invisible (still clickable where it sits); the client's
       own cell under it (above) still shows a dispellable debuff.
  /bbuff status counts, per way, how each paint ended (shown, hidden, secret = left to
  SetAlphaFromBoolean, unknown = hidden) and why the earlier ways gave no answer.
  Throttled: UNIT_AURA marks a member, the strip repaints marked members at most 10 times a
  second in combat (and everyone once a second); the list updates at most 4 times a second, and
  every 1.5 s in a group for range, death and visibility.

  Taint: secure attributes, click registration, size, place and Show/Hide of the panel are only
  changed out of combat, on the addon's own buttons. Every API is checked before use and runs in
  pcall; a secret value is never compared or tested. No globals: the frames have no names.
]]

local _G = _G
local _, ns = ...

-- The kinds: dispelName, SpellDispelType ID, colour, tag, the option that switches it, plural.
local KINDS = {
    magic = { name = "Magic", type = 1, rgb = { 0.2, 0.6, 1.0 }, tag = "|cff3399ffMagic|r",
        key = "dispelMagic", plural = "magic", sample = "Shadow Word: Pain",
        sampleIcon = "Interface\\Icons\\Spell_Shadow_ShadowWordPain", sample2 = "Frost Nova",
        sampleIcon2 = "Interface\\Icons\\Spell_Frost_FrostNova" },
    curse = { name = "Curse", type = 2, rgb = { 0.64, 0.21, 0.93 }, tag = "|cffa335eeCurse|r",
        key = "dispelCurse", plural = "curses", sample = "Curse of Weakness",
        sampleIcon = "Interface\\Icons\\Spell_Shadow_CurseOfMannoroth", sample2 = "Curse of Agony",
        sampleIcon2 = "Interface\\Icons\\Spell_Shadow_CurseOfSargeras" },
    poison = { name = "Poison", type = 4, rgb = { 0.2, 0.8, 0.2 }, tag = "|cff33cc33Poison|r",
        key = "dispelPoison", plural = "poisons", sample = "Deadly Poison",
        sampleIcon = "Interface\\Icons\\Ability_Rogue_DualWeild" },
    disease = { name = "Disease", type = 3, rgb = { 0.6, 0.4, 0.0 }, tag = "|cff996600Disease|r",
        key = "dispelDisease", plural = "diseases", sample = "Infected Bite",
        sampleIcon = "Interface\\Icons\\Spell_Nature_NullifyDisease" },
}

local KIND_BY_NAME = {}             -- dispelName -> kind key
for k, v in pairs(KINDS) do KIND_BY_NAME[v.name] = k end
local KIND_ORDER = { "magic", "curse", "disease", "poison" }

-- Per class: one or two actions. Two: left-click casts the first, right-click the second. One:
-- both mouse buttons cast it. Each action lists its spells (the first one known is cast), each
-- spell with the kinds it removes (ids highest rank first).
local CLASS_CONFIG = {
    DRUID = { class = "DRUID", id = 11, actions = {
        { spells = { { ids = { 2782 }, name = "Remove Curse", kinds = { "curse" } } } },
        { spells = { { ids = { 2893 }, name = "Abolish Poison", kinds = { "poison" } },
                     { ids = { 8946 }, name = "Cure Poison", kinds = { "poison" } } } } } },
    SHAMAN = { class = "SHAMAN", id = 7, actions = {
        { spells = { { ids = { 526 }, name = "Cure Poison", kinds = { "poison" } } } },
        { spells = { { ids = { 2870 }, name = "Cure Disease", kinds = { "disease" } } } } } },
    PRIEST = { class = "PRIEST", id = 5, actions = {
        { spells = { { ids = { 988, 527 }, name = "Dispel Magic", kinds = { "magic" } } } },
        { spells = { { ids = { 552 }, name = "Abolish Disease", kinds = { "disease" } },
                     { ids = { 528 }, name = "Cure Disease", kinds = { "disease" } } } } } },
    PALADIN = { class = "PALADIN", id = 2, actions = {
        { spells = { { ids = { 4987 }, name = "Cleanse", kinds = { "poison", "disease", "magic" } },
                     { ids = { 1152 }, name = "Purify", kinds = { "poison", "disease" } } } } } },
    MAGE = { class = "MAGE", id = 8, actions = {
        { spells = { { ids = { 475 }, name = "Remove Lesser Curse", kinds = { "curse" } } } } } },
}

local PAD, ROW_H, HEADER_H, MIN_W = 6, 18, 16, 170
local LIST_THROTTLE, LIST_REFRESH = 0.25, 1.5
local STRIP_THROTTLE, STRIP_REFRESH = 0.1, 1.0
local OUT_OF_RANGE = 0.45
local GLOW_ALPHA = 0.8
local GAP = 2
local PARTY_W, PARTY_H, RAID_W, RAID_H = 150, 22, 58, 16
local MAX_DEBUFFS = 40
local FLAT = "Interface\\Buttons\\WHITE8x8"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local ANY_RGB = { 1, 0.82, 0 }
local FILTERS = { "HARMFUL|RAID_PLAYER_DISPELLABLE", "HARMFUL|RAID" }
local ORDER = "plain read, aura instance IDs + dispel colour, filtered read, none"

local Secret, Num, Str, Bool, Call, On = ns.Secret, ns.Num, ns.Str, ns.Bool, ns.Call, ns.On
local InCombat, Print = ns.InCombat, ns.Print

local spells = {}                -- action index -> ns.ResolveSpell results (plus .kinds), in order
local spellsPending = true
local cfg                        -- your class's CLASS_CONFIG entry; nil until PLAYER_LOGIN or for another class
local panel, listBox, list, strip, header, stripTitle, hint
local rows, fakes, buttons = {}, {}, {}
local stripByUnit = {}           -- unit token -> strip button
local selfButton                 -- your own button in a raid (raidN), for UNIT_AURA "player"
local stripMode, stripCount = "none", 0
local stripPending, rosterInCombat = true, false
local drivers                    -- the visibility state drivers are on
local listDirty, paintAll = true, true
local dirtyUnits = {}
local lastList, lastPaint, lastFull = 0, 0, 0
local sig
local filter, filterInfo
local curve, curveKey
local fightStats, lastFight      -- method -> members answered, this and the last fight
local shownRows = 0

local function Now() return Num(Call("GetTime")) or 0 end
local function DB() return ns.DB() end

-- Your class's config; the druid's before login or on another class (help, test texts).
local function Cfg() return cfg or CLASS_CONFIG.DRUID end

local function Actions() return Cfg().actions end

-- One action for both mouse buttons (paladin, mage).
local function Single() return #Actions() == 1 end

-- The first spell of an action you know, or nil.
local function ActionSpell(a)
    for _, s in ipairs(spells[a] or {}) do
        if s.value then return s end
    end
    return nil
end

-- The kinds an action removes: its known spell's, else its first spell's (for texts).
local function ActionKinds(a)
    local s = ActionSpell(a)
    if s then return s.kinds end
    return Actions()[a].spells[1].kinds
end

-- Every kind a class's spells can remove, in order, once each (option labels, help).
local function ClassKinds(c)
    local out, seen = {}, {}
    for _, act in ipairs(c.actions) do
        for _, sp in ipairs(act.spells) do
            for _, k in ipairs(sp.kinds) do
                if not seen[k] then
                    seen[k] = true
                    out[#out + 1] = k
                end
            end
        end
    end
    return out
end

-- The kinds of every action as it stands (known spell, else the first), in order, once each,
-- and kind -> action. For the test samples and to name a debuff's kind.
local function ShownKinds()
    local out, of = {}, {}
    for a in ipairs(Actions()) do
        for _, k in ipairs(ActionKinds(a)) do
            if not of[k] then
                of[k] = a
                out[#out + 1] = k
            end
        end
    end
    return out, of
end

-- The kinds you can remove now: a known spell removes it and it is switched on. In order
-- (left-click's first), and kind -> action.
local function Removable()
    local out, of = {}, {}
    for a in ipairs(Actions()) do
        local s = ActionSpell(a)
        for _, k in ipairs(s and s.kinds or {}) do
            if not of[k] and On(KINDS[k].key) then
                of[k] = a
                out[#out + 1] = k
            end
        end
    end
    return out, of
end

-- An action you can and want to use: a known spell with at least one kind switched on.
local function Want(a)
    local s = ActionSpell(a)
    if not s then return false end
    for _, k in ipairs(s.kinds) do
        if On(KINDS[k].key) then return true end
    end
    return false
end

-- The spell a mouse button (1 left, 2 right) casts, or nil.
local function ButtonSpell(button)
    local a = (button == 2 and not Single()) and 2 or 1
    return Want(a) and ActionSpell(a) or nil
end

-- "curse", "poison/disease/magic": a field of each kind, joined.
local function KindsText(list, field, sep)
    local parts = {}
    for _, k in ipairs(list) do parts[#parts + 1] = KINDS[k][field] end
    return table.concat(parts, sep or ", ")
end

-- The spell names of an action: "Abolish Poison, else Cure Poison".
local function SpellNames(act)
    local parts = {}
    for _, sp in ipairs(act.spells) do parts[#parts + 1] = sp.name end
    return table.concat(parts, ", else ")
end

-- The given kinds in the order of the list (a set in, an ordered list out).
local function Ordered(set, order)
    local out = {}
    for _, k in ipairs(order) do
        if set[k] then out[#out + 1] = k end
    end
    return out
end

local function Active()
    return cfg ~= nil and DB() ~= nil and On("enabled") and On("dispel") and #(Removable()) > 0
        and true or false
end

local function Testing()
    return cfg ~= nil and ns.TestMode() and true or false
end

-- ---------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------

-- A value that is there: a secret one counts (it is never compared).
local function Present(v)
    return Secret(v) or v ~= nil
end

-- A short, plain reason from an error (for /bbuff status).
local function Why(err)
    local s = tostring(err):gsub("^.-:%d+: ", "")
    return "error: " .. s:sub(1, 70)
end

local function IndexSecret(unit, i, f)
    local S = _G.C_Secrets
    if type(S) ~= "table" or type(S.ShouldUnitAuraIndexBeSecret) ~= "function" then return false end
    local ok, s = pcall(S.ShouldUnitAuraIndexBeSecret, unit, i, f)
    return ok and not Secret(s) and s == true
end

-- Every debuff with a plain dispelName: { found = { dispelName -> { name, icon } of the first
-- debuff of that kind, as they came } }, or nil and why when one cannot be read.
local function ScanPlain(unit)
    local C = _G.C_UnitAuras
    local byData = type(C) == "table" and type(C.GetAuraDataByIndex) == "function"
    local old = type(_G.UnitDebuff) == "function" and _G.UnitDebuff
    if not byData and not old then return nil, "no API" end
    local out = { found = {} }
    for i = 1, MAX_DEBUFFS do
        if IndexSecret(unit, i, "HARMFUL") then return nil, "index secret" end
        local dn, nm, ic
        if byData then
            local ok, a = pcall(C.GetAuraDataByIndex, unit, i, "HARMFUL")
            if not ok then return nil, Why(a) end
            if Secret(a) then return nil, "secret aura" end
            if type(a) ~= "table" then break end
            local ok2, v, n2, i2 = pcall(function() return a.dispelName, a.name, a.icon end)
            if not ok2 then return nil, Why(v) end
            if Secret(v) then return nil, "secret dispelName" end
            dn, nm, ic = v, n2, i2
        else
            local ok, name, icon, _, kind = pcall(old, unit, i)
            if not ok then return nil, Why(name) end
            if Secret(name) or Secret(kind) then return nil, "secret aura" end
            if not Str(name) then break end
            dn, nm, ic = kind, name, icon
        end
        if type(dn) == "string" and not out.found[dn] then out.found[dn] = { name = nm, icon = ic } end
    end
    return out
end

-- The name and icon of a readable aura table, as they are (either may be secret).
local function NameIcon(a)
    if Secret(a) or type(a) ~= "table" then return nil end
    local ok, name, icon = pcall(function() return a.name, a.icon end)
    if not ok then return nil end
    return name, icon
end

-- The same by aura instance ID (which may be secret; it is only passed on).
local function AuraNameIcon(unit, id)
    local C = _G.C_UnitAuras
    if not Present(id) or type(C) ~= "table" or type(C.GetAuraDataByAuraInstanceID) ~= "function" then return nil end
    local ok, a = pcall(C.GetAuraDataByAuraInstanceID, unit, id)
    if not ok then return nil end
    return NameIcon(a)
end

local function ChooseFilter()
    if filter ~= nil then return filter or nil end
    local U = _G.AuraUtil
    if type(U) == "table" and type(U.IsValidFilterString) == "function" then
        local valid = {}
        for _, f in ipairs(FILTERS) do
            local ok, v = pcall(U.IsValidFilterString, f)
            if ok and not Secret(v) and v == true then valid[#valid + 1] = f end
        end
        filter = valid[1] or false
        filterInfo = #valid > 0 and ("accepted: " .. table.concat(valid, ", "))
            or ("AuraUtil.IsValidFilterString accepts none of " .. table.concat(FILTERS, ", "))
    else
        filter = "HARMFUL|RAID"
        filterInfo = "no AuraUtil.IsValidFilterString on this client; HARMFUL|RAID assumed"
    end
    return filter or nil
end

-- A step colour curve over the dispel type (None 0, Magic 1, Curse 2, Disease 3, Poison 4,
-- anything from 5 on): the kinds you can remove now in their colours, everything else
-- transparent. false where the client has no colour curves.
local function Curve()
    local removable = Removable()
    local key = Cfg().class .. ":" .. table.concat(removable, ",")
    if curve ~= nil and curveKey == key then return curve or nil end
    curveKey, curve = key, false
    local CU, E, CC = _G.C_CurveUtil, _G.Enum, _G.CreateColor
    if type(CU) ~= "table" or type(CU.CreateColorCurve) ~= "function" or type(CC) ~= "function" then return nil end
    local ok, c = pcall(function()
        local c = CU.CreateColorCurve()
        if type(E) == "table" and type(E.LuaCurveType) == "table" and E.LuaCurveType.Step ~= nil then
            c:SetType(E.LuaCurveType.Step)
        end
        -- A point on every type from 0 to 5, so each type gets exactly its own colour.
        local rgbOf = {}
        for _, k in ipairs(removable) do rgbOf[KINDS[k].type] = KINDS[k].rgb end
        for x = 0, 5 do
            local rgb = rgbOf[x]
            c:AddPoint(x, rgb and CC(rgb[1], rgb[2], rgb[3], 1) or CC(0, 0, 0, 0))
        end
        return c
    end)
    if ok and c then curve = c end
    return curve or nil
end

-- Paints tex with the dispel type colour of one aura, without reading it. true when it worked.
local function PaintFromAPI(tex, unit, id)
    local C, crv = _G.C_UnitAuras, Curve()
    if not Present(id) or not crv or type(C) ~= "table" or type(C.GetAuraDispelTypeColor) ~= "function" then return false end
    local ok = pcall(function()
        local color = C.GetAuraDispelTypeColor(unit, id, crv)
        if type(color) ~= "table" then error("no colour") end
        tex:SetVertexColor(color:GetRGBA())
    end)
    return ok
end

-- What one member has: has = true / false / nil (unknown) / a secret boolean (only passed on),
-- how to colour it: found (the kinds found, known, in the class's order) or ids (aura instance
-- IDs for the colour API),
-- and what it is: name and icon of the first dispellable debuff (either may be secret or nil);
-- method = which way answered; why = { way -> why it did not answer } for the ways before it.
local function Detect(unit)
    local why = {}
    local p, whyPlain = ScanPlain(unit)
    if p then
        local found, first = {}, nil
        for _, k in ipairs((Removable())) do
            local f = p.found[KINDS[k].name]
            if f then
                found[#found + 1] = k
                first = first or f
            end
        end
        local r = { has = #found > 0, found = found, method = "plain read" }
        if first then r.name, r.icon = first.name, first.icon end
        return r
    end
    why["plain read"] = whyPlain
    local f = ChooseFilter()
    if not f then
        why["aura instance IDs"] = "no dispel filter"
        return { method = "none", why = why }
    end
    local C = _G.C_UnitAuras
    if type(C) ~= "table" then return { method = "none", why = why } end
    if type(C.GetUnitAuraInstanceIDs) ~= "function" then
        why["aura instance IDs"] = "no API"
    else
        local ok, ids = pcall(C.GetUnitAuraInstanceIDs, unit, f, 2)
        if not ok then
            why["aura instance IDs"] = Why(ids)
        elseif Secret(ids) then
            why["aura instance IDs"] = "secret list"     -- may be empty: not counted as one
        elseif type(ids) ~= "table" then
            why["aura instance IDs"] = "no list (" .. type(ids) .. ")"
        else
            local okN, n = pcall(function() return #ids end)
            n = okN and Num(n)
            if n then
                local r = { has = n > 0, ids = ids, method = "aura instance IDs", why = why }
                if n > 0 then r.name, r.icon = AuraNameIcon(unit, ids[1]) end
                return r
            end
            why["aura instance IDs"] = "count secret or refused"
        end
    end
    if type(C.GetAuraDataByIndex) == "function" then
        local r = { method = "filtered read", ids = {}, why = why }
        local order, of = ShownKinds()
        local set = {}
        for i = 1, 2 do
            local ok, a = pcall(C.GetAuraDataByIndex, unit, i, f)
            if not ok then
                if i == 1 then
                    why["filtered read"] = Why(a)
                    return { method = "none", why = why }
                end
                break
            end
            if Secret(a) then
                r.has, r.unknownKind = true, true
            elseif a == nil then
                break                       -- a plain nil: nothing more
            elseif type(a) ~= "table" then
                r.has, r.unknownKind = true, true
            else
                r.has = true
                if not r.named then
                    r.named = true
                    r.name, r.icon = NameIcon(a)
                end
                local ok2, dn, id = pcall(function() return a.dispelName, a.auraInstanceID end)
                local k = ok2 and not Secret(dn) and type(dn) == "string" and KIND_BY_NAME[dn]
                if k and of[k] then set[k] = true else r.unknownKind = true end
                if ok2 then r.ids[#r.ids + 1] = id end
            end
        end
        if not r.has then r.has = false end
        if r.unknownKind then r.found = nil else r.found, r.ids = Ordered(set, order), nil end
        return r
    end
    why["filtered read"] = "no API"
    return { method = "none", why = why }
end

-- ---------------------------------------------------------------------------
-- The look of a strip button (secure or a test one): plain textures only
-- ---------------------------------------------------------------------------

local function Style(b)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.1, 0.1, 0.12, 0.9)
    b.glowL = b:CreateTexture(nil, "BORDER")
    b.glowL:SetTexture(FLAT)
    b.glowL:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    b.glowL:SetPoint("BOTTOMRIGHT", b, "BOTTOM", 0, 1)
    b.glowR = b:CreateTexture(nil, "BORDER")
    b.glowR:SetTexture(FLAT)
    b.glowR:SetPoint("TOPLEFT", b, "TOP", 0, -1)
    b.glowR:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    for _, g in ipairs({ b.glowL, b.glowR }) do
        g:SetAlpha(GLOW_ALPHA)
        g:SetVertexColor(0, 0, 0, 0)
    end
    -- The debuff's icon, the member's name, and (party/solo) the debuff's name in a font string
    -- of its own, so a secret name is set as it is and never joined to anything.
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon:Hide()
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetJustifyH("LEFT")
    b.debuff = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.debuff:SetJustifyH("LEFT")
    for _, fs in ipairs({ b.text, b.debuff }) do
        if type(fs.SetWordWrap) == "function" then fs:SetWordWrap(false) end
    end
end

-- Size and inner layout of a strip button (out of combat): compact (raid) = icon and name only.
local function Layout(b, w, h, compact)
    b:SetSize(w, h)
    b.icon:SetSize(h - 4, h - 4)
    b.icon:ClearAllPoints()
    b.icon:SetPoint("LEFT", b, "LEFT", 2, 0)
    b.text:ClearAllPoints()
    b.text:SetPoint("LEFT", b.icon, "RIGHT", 3, 0)
    b.debuff:ClearAllPoints()
    if compact then
        b.text:SetPoint("RIGHT", b, "RIGHT", -2, 0)
        b.debuff:SetText("")
        b.debuff:Hide()
    else
        b.debuff:SetPoint("LEFT", b.text, "RIGHT", 3, 0)
        b.debuff:SetPoint("RIGHT", b, "RIGHT", -2, 0)
        b.debuff:Show()
    end
end

local function Glow(tex, rgb)
    if rgb then tex:SetVertexColor(rgb[1], rgb[2], rgb[3], 1) else tex:SetVertexColor(0, 0, 0, 0) end
end

-- A value that is secret (passed on as it is) or a plain one of type t1 / t2.
local function Usable(v, t1, t2)
    if Secret(v) then return true end
    local t = type(v)
    return t == t1 or (t2 ~= nil and t == t2)
end

-- The debuff's icon and name; a question mark and the kind when they are not there.
local function ShowDebuff(b, r)
    if not (Usable(r.icon, "number", "string") and pcall(b.icon.SetTexture, b.icon, r.icon)) then
        b.icon:SetTexture(QUESTION)
    end
    b.icon:Show()
    if not (Usable(r.name, "string") and pcall(b.debuff.SetText, b.debuff, r.name)) then
        local k = r.found and r.found[1]
        b.debuff:SetText(k and KINDS[k].name or "Dispel")
    end
end

-- Invisible, with nothing left on it.
local function Blank(b)
    b:SetAlpha(0)
    b.icon:Hide()
    b.debuff:SetText("")
    Glow(b.glowL) Glow(b.glowR)
end

-- r from Detect (or a test one). Only a real "has one" is seen: nothing to remove and unknown
-- alike = the whole button invisible; else visible with the debuff and the glow. Returns how it
-- ended: "shown", "hidden" (nothing), "secret" (left to SetAlphaFromBoolean) or "unknown" (hidden).
local function Paint(b, r)
    local has, secret = r.has, Secret(r.has)
    local outcome = "shown"
    if not secret and not has then
        Blank(b)
        return has == false and "hidden" or "unknown"
    end
    if secret then
        -- Visible only when the client's secret answer is true; never tested here.
        if not (type(b.SetAlphaFromBoolean) == "function" and pcall(b.SetAlphaFromBoolean, b, has, 1, 0)) then
            Blank(b)
            return "unknown"
        end
        outcome = "secret"
    else
        b:SetAlpha(1)
    end
    ShowDebuff(b, r)
    local found = r.found
    if found and found[1] then
        -- The first kind on the left half, the second (else the first again) on the right.
        Glow(b.glowL, KINDS[found[1]].rgb)
        Glow(b.glowR, KINDS[found[2] or found[1]].rgb)
        return outcome
    end
    local ids = r.ids
    local first, second = ids and ids[1], ids and ids[2]
    if ids and Present(first) and PaintFromAPI(b.glowL, b.unit, first) then
        if not (Present(second) and PaintFromAPI(b.glowR, b.unit, second)) then
            PaintFromAPI(b.glowR, b.unit, first)
        end
        return outcome
    end
    Glow(b.glowL, ANY_RGB) Glow(b.glowR, ANY_RGB)
    return outcome
end

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------

local function SavePosition()
    local db = DB()
    if not panel or not db then return end
    local ui = _G.UIParent
    local left, right, top = panel:GetLeft(), panel:GetRight(), panel:GetTop()
    local uw, uh = ui:GetWidth(), ui:GetHeight()
    if not Num(left) or not Num(right) or not Num(top) or not Num(uw) or not Num(uh) then return end
    db.dispelPos = { x = math.floor((left + right) / 2 - uw / 2 + 0.5), y = math.floor(top - uh + 0.5) }
end

local function ApplyPosition()
    if not panel or InCombat() then return end
    local db = DB()
    local p = db and db.dispelPos
    panel:ClearAllPoints()
    if type(p) == "table" and Num(p.x) and Num(p.y) then
        panel:SetPoint("TOP", _G.UIParent, "TOP", p.x, p.y)
    elseif ns.Holder() then
        panel:SetPoint("TOP", ns.Holder(), "BOTTOM", 0, -6)
    else
        panel:SetPoint("TOP", _G.UIParent, "TOP", 0, -260)
    end
end

local function Locked()
    local db = DB()
    return not (db and db.dispelLocked == false)
end

local function Tooltip(self)
    local tip = _G.GameTooltip
    if not tip then return end
    -- An invisible strip button (nothing to remove) still gets the mouse in combat: no tooltip.
    local okA, alpha = pcall(self.GetAlpha, self)
    alpha = okA and Num(alpha)
    if alpha and alpha < 0.05 then return end
    tip:SetOwner(self, "ANCHOR_RIGHT")
    tip:AddLine(self.plainName or "?")
    if self.fake then
        tip:AddLine("Test button: clicking does nothing.", 0.7, 0.7, 0.7)
    else
        for a in ipairs(Actions()) do
            local s = ButtonSpell(a)
            tip:AddLine((Single() and "Left- or right-click: " or a == 1 and "Left-click: " or "Right-click: ")
                .. (s and s.label or ("nothing (" .. KindsText(ActionKinds(a), "plural") .. " off or not known)")), 1, 1, 1)
        end
        if self.far then tip:AddLine("Out of range", 1, 0.3, 0.3) end
    end
    tip:Show()
end

local function HookTooltip(b)
    b:HookScript("OnEnter", function(self) pcall(Tooltip, self) end)
    b:HookScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
end

-- The click attributes, out of combat only: left = the first action's spell, right = the
-- second's (the same one for a one-action class).
local function Bind(b, unit)
    local c, p = ButtonSpell(1), ButtonSpell(2)
    b:RegisterForClicks(ns.UseKeyDown() and "AnyDown" or "AnyUp")
    b:SetAttribute("type", nil)
    b:SetAttribute("spell", nil)
    b:SetAttribute("type1", (unit and c) and "spell" or nil)
    b:SetAttribute("spell1", (unit and c) and c.value or nil)
    b:SetAttribute("type2", (unit and p) and "spell" or nil)
    b:SetAttribute("spell2", (unit and p) and p.value or nil)
    b:SetAttribute("unit", unit)
end

local function CreatePanel()
    if panel then return end
    local ui = _G.UIParent
    panel = CreateFrame("Frame", nil, ui)
    panel:SetSize(MIN_W, 20)
    panel:SetFrameStrata("MEDIUM")
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)

    list = CreateFrame("Frame", nil, panel)
    list:SetAllPoints(panel)

    listBox = CreateFrame("Frame", nil, list, "BackdropTemplate")
    listBox:SetPoint("TOPLEFT", panel, "TOPLEFT")
    listBox:SetSize(MIN_W, 20)
    if type(listBox.SetBackdrop) == "function" then
        listBox:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        listBox:SetBackdropColor(0.07, 0.08, 0.10, 0.90)
        listBox:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    end
    listBox:EnableMouse(true)
    listBox:RegisterForDrag("LeftButton")
    listBox:SetScript("OnDragStart", function()
        if InCombat() then return end
        if Locked() and not Bool(Call("IsAltKeyDown")) then return end
        panel:StartMoving()
    end)
    listBox:SetScript("OnDragStop", function()
        panel:StopMovingOrSizing()
        if type(panel.SetUserPlaced) == "function" then pcall(panel.SetUserPlaced, panel, false) end
        local ok, err = pcall(function()
            SavePosition()
            ApplyPosition()
        end)
        if not ok then ns.Fail("saving the dispel panel position", err) end
    end)
    listBox:Hide()
    header = listBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetJustifyH("LEFT")
    stripTitle = listBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stripTitle:SetJustifyH("LEFT")
    hint = listBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetJustifyH("LEFT")

    -- No background of its own: only the buttons of members with something to remove are seen.
    strip = CreateFrame("Frame", nil, panel)
    strip:SetPoint("TOPLEFT", panel, "TOPLEFT")
    strip:SetSize(PARTY_W + 2 * GAP, PARTY_H + 2 * GAP)

    -- The strip for the whole fight, the list the rest of the time, by secure code.
    if type(_G.RegisterStateDriver) == "function" then
        local ok1 = pcall(_G.RegisterStateDriver, list, "visibility", "[combat] hide; show")
        local ok2 = pcall(_G.RegisterStateDriver, strip, "visibility", "[combat] show; hide")
        drivers = ok1 and ok2
    end
    if not drivers then strip:Hide() end
    panel:Hide()
    ApplyPosition()
end

-- ---------------------------------------------------------------------------
-- The strip (secure, built out of combat)
-- ---------------------------------------------------------------------------

-- The first n characters of a name (UTF-8).
local function Short(name, n)
    local out = {}
    for ch in name:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #out >= n then break end
        out[#out + 1] = ch
    end
    return table.concat(out)
end

local function Label(b)
    local name = Str(Call("UnitName", b.unit)) or b.unit
    local hex = ns.ClassHex(ns.UnitClassFile(b.unit))
    local raid = stripMode == "raid"
    local short = Short(name, raid and 6 or 8)
    b.plainName = name
    local text = (hex and ("|c" .. hex .. short .. "|r") or short) .. (raid and "" or ":")
    b.text:SetText(text)
    if b.cell then pcall(b.cell.name.SetText, b.cell.name, text) end
end

-- { { unit, group } }, "solo" / "party" / "raid".
local function StripUnits()
    local out = {}
    if ns.InRaid() then
        for i = 1, 40 do
            local u = "raid" .. i
            if Bool(Call("UnitExists", u)) then
                local _, _, sub = Call("GetRaidRosterInfo", i)
                out[#out + 1] = { unit = u, group = Num(sub) or math.ceil(i / 5) }
            end
        end
        if #out > 0 then return out, "raid" end
    end
    out[1] = { unit = "player", group = 1 }
    if not ns.InGroup() then return out, "solo" end
    for i = 1, 4 do
        local u = "party" .. i
        if Bool(Call("UnitExists", u)) then out[#out + 1] = { unit = u, group = 1 } end
    end
    return out, "party"
end

local function StripButton(i)
    local b = buttons[i]
    if b then return b end
    b = CreateFrame("Button", nil, strip, "SecureActionButtonTemplate")
    Style(b)
    b:SetHighlightTexture(FLAT, "ADD")
    local hl = b:GetHighlightTexture()
    if hl then hl:SetVertexColor(1, 1, 1, 0.15) end
    HookTooltip(b)
    b:Hide()
    buttons[i] = b
    return b
end

-- ---------------------------------------------------------------------------
-- Client-drawn icons in combat (Blizzard aura container, since 1.6.0)
--
-- In combat this addon cannot read debuffs on this client (Detect ends as "none", so its own
-- paint leaves the button invisible). The game can: Blizzard_AuraContainer's addon-usable
-- "AuraContainer" frame with CustomAuraContainerTemplate (the same technique
-- BetterFramesForever uses for unit frame auras) reads auras in its own secure code, secret or
-- not, and shows them. Under every strip button sits one container for that button's unit with
-- one aura slot ("dispel"): filter "HARMFUL" and the candidate filter includeDispelTypes = the
-- dispel types you can remove now ("Curse", "Poison", ...: your known spell's kinds that are
-- switched on). That is the out-of-combat list's own rule, and it is independent of what the
-- retail engine thinks a classic class can dispel (HARMFUL|RAID_PLAYER_DISPELLABLE), which
-- may not match a classic spellbook (Purify vs Cleanse, for one).
--
-- The slot frame is shown by the client only while that member has such a debuff, and
-- everything the member's cell shows is a child of it: a dark background the size of the
-- button, a bar coloured by the client from the dispel type (AddDispelTypeTexture,
-- PreserveAsset: the game's debuff colours), the debuff's icon (SetIcon), the member's name
-- (our font string, set out of combat and on a roster change) and the debuff's name (SetSpellName:
-- the client writes it). So a member's cell appears and disappears exactly with the client's
-- own answer; no Lua code ever sees or tests it, and nothing about the secure button changes in
-- combat. Why not show the secure button itself: its alpha can only follow a boolean the
-- client hands Lua (SetAlphaFromBoolean), and in combat there is none. So the button stays
-- invisible (alpha 0, "unknown = hidden" for everything Lua decides) and sits above the cell
-- (a higher frame level), taking the clicks exactly where the icon is; a plain answer Lua can
-- read still paints the button itself, on top of the cell. The containers are children of the
-- strip, so they are only shown (and only listen to UNIT_AURA) in combat.
--
-- Built out of combat with the strip; where the client has no such container (or refuses the
-- setup, said once in chat) the strip works as before. /bbuff status has a line for it.
-- ---------------------------------------------------------------------------

local CELL_SLOT, CELL_FILTER = "dispel", "HARMFUL"
local cellInfo = { built = 0 }      -- built; missing / failed / layoutError / lookError: why not

-- The dispel types the client may draw: dispelName -> true for each kind you can remove now.
local function TypeMap()
    local map = {}
    for _, k in ipairs((Removable())) do map[KINDS[k].name] = true end
    return map
end

local function TypeKey() return table.concat((Removable()), ",") end

local function DispelStyle()
    local E = _G.Enum
    local t = type(E) == "table" and E.CustomAuraButtonDispelTypeTextureStyle
    return type(t) == "table" and Num(t.PreserveAsset) or 3
end

-- The look of a cell, made on the slot frame when the container creates it. It runs inside the
-- client's securecallfunction, which reports an error but does not hand it back, so it is a
-- pcall. Sizes and places are set later, in PlaceCell.
local function CellLook(look, f)
    local ok, err = pcall(function()
        look.frame = f
        look.bg = f:CreateTexture(nil, "BACKGROUND")
        look.bg:SetColorTexture(0.1, 0.1, 0.12, 0.9)
        look.glow = f:CreateTexture(nil, "BORDER")
        look.glow:SetTexture(FLAT)
        look.glow:SetAlpha(GLOW_ALPHA)
        look.glow:SetVertexColor(ANY_RGB[1], ANY_RGB[2], ANY_RGB[3], 1)
        if type(f.AddDispelTypeTexture) == "function" then
            look.colour = pcall(f.AddDispelTypeTexture, f, look.glow, { style = DispelStyle() })
        end
        look.icon = f:CreateTexture(nil, "ARTWORK")
        look.icon:SetAllPoints(f)
        look.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        f:SetIcon(look.icon)
        look.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        look.spell = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        for _, fs in ipairs({ look.name, look.spell }) do
            fs:SetJustifyH("LEFT")
            if type(fs.SetWordWrap) == "function" then fs:SetWordWrap(false) end
        end
        if type(f.SetSpellName) == "function" then look.spellName = pcall(f.SetSpellName, f, look.spell) end
    end)
    if not ok then cellInfo.lookError = tostring(err) end
end

-- A new cell (container + slot frame + look), or false where the client has none or refuses it.
local function NewCell()
    if cellInfo.missing or cellInfo.failed then return false end
    local okMake, c = pcall(CreateFrame, "AuraContainer", nil, strip, "CustomAuraContainerTemplate")
    if not okMake or type(c) ~= "table" or type(c.AddAuraSlot) ~= "function" then
        cellInfo.missing = okMake and "the frame has no AddAuraSlot" or tostring(c)
        if okMake and type(c) == "table" then pcall(c.Hide, c) end
        return false
    end
    local look = {}
    local ok, err = pcall(function()
        if type(c.SetEditModePreviewEnabled) == "function" then c:SetEditModePreviewEnabled(false) end
        c:SetFrameLevel(strip:GetFrameLevel() + 1)
        c:SetSize(PARTY_W, PARTY_H)
        c:SetUnit("player")
        local types = TypeKey()
        local frame = c:AddAuraSlot(CELL_SLOT, CELL_FILTER, {
            candidateFilters = { includeDispelTypes = TypeMap() },
            initializeFrame = function(f) CellLook(look, f) end,
        })
        look.frame = look.frame or frame
        look.types = types
    end)
    if not ok or not look.frame or not look.icon then
        cellInfo.failed = tostring((not ok and err) or cellInfo.lookError or "no slot frame")
        pcall(c.Hide, c)
        Print("the game's aura container refused the dispel strip's setup, so in combat the strip shows only what"
            .. " this addon can read (" .. cellInfo.failed .. ").")
        return false
    end
    look.container = c
    cellInfo.built = cellInfo.built + 1
    cellInfo.colour = look.colour and true or false
    return look
end

-- Out of combat: the cell under a strip button follows its unit, size and your kinds. late =
-- at PLAYER_REGEN_DISABLED: no new cells then (auras may already be secret), and a layout the
-- client refuses waits for the next build.
local function PlaceCell(b, w, h, compact, late)
    local look = b.cell
    if look == nil and not late then
        look = NewCell()
        b.cell = look
    end
    if not look then return end
    local c, f = look.container, look.frame
    local ok, err = pcall(function()
        c:SetFrameLevel(strip:GetFrameLevel() + 1)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
        c:SetSize(w, h)
        local types = TypeKey()
        if look.types ~= types then
            c:SetAuraSlotCandidateFilters(CELL_SLOT, { includeDispelTypes = TypeMap() })
            look.types = types
        end
        c:SetUnit(b.unit)
        if type(c.SetEnabled) == "function" then c:SetEnabled(true) end
        c:Show()
    end)
    if not ok then
        cellInfo.layoutError = tostring(err)
        return
    end
    ok, err = pcall(function()
        local s = h - 4
        f:SetSize(s, s)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", c, "TOPLEFT", 2, -2)
        look.bg:ClearAllPoints()
        look.bg:SetPoint("TOPLEFT", f, "TOPLEFT", -2, 2)
        look.bg:SetSize(w, h)
        look.glow:ClearAllPoints()
        look.glow:SetPoint("TOPLEFT", f, "TOPLEFT", -1, 1)
        look.glow:SetSize(w - 2, h - 2)
        look.name:ClearAllPoints()
        look.name:SetPoint("LEFT", f, "RIGHT", 3, 0)
        look.spell:ClearAllPoints()
        if compact then
            look.name:SetPoint("RIGHT", f, "LEFT", w - 4, 0)
            look.spell:SetPoint("LEFT", f, "RIGHT", 3, 0)
            look.spell:SetAlpha(0)
        else
            look.spell:SetPoint("LEFT", look.name, "RIGHT", 3, 0)
            look.spell:SetPoint("RIGHT", f, "LEFT", w - 4, 0)
            look.spell:SetAlpha(1)
        end
    end)
    if not ok then cellInfo.layoutError = tostring(err) end
end

-- A cell whose button has no member: off and hidden (out of combat).
local function HideCell(b)
    local look = b.cell
    if not look then return end
    local c = look.container
    pcall(function()
        if type(c.SetEnabled) == "function" then c:SetEnabled(false) end
        c:Hide()
    end)
end

-- After a roster change in combat: the container rereads its unit's auras (the token may be
-- someone else now; it gets no event for that).
local function RefreshCell(b)
    local look = b.cell
    if not look then return end
    local c = look.container
    if type(c.UpdateAllAuras) == "function" then pcall(c.UpdateAllAuras, c) end
end

-- How many strip buttons have a cell now.
local function CellCount()
    local n = 0
    for _, b in ipairs(buttons) do
        if b.unit and b.cell then n = n + 1 end
    end
    return n
end

-- For /bbuff status.
local function CellStatus()
    if cellInfo.missing then
        return "not on this client (" .. cellInfo.missing .. "): in combat only what this addon can read is shown"
    end
    if cellInfo.failed then return "refused (" .. cellInfo.failed .. "): in combat only what this addon can read is shown" end
    if cellInfo.built == 0 then return "not built yet (built with the strip, out of combat)" end
    local removable = Removable()
    return "active - the game draws the icon of a member's " .. (#removable > 0 and KindsText(removable, "name", "/") or "(nothing)")
        .. " debuff under " .. CellCount() .. " buttons (filter " .. CELL_FILTER .. " + those dispel types; colour "
        .. (cellInfo.colour and "by dispel type" or "yellow: the client refused the dispel colour") .. ")"
        .. (cellInfo.layoutError and ("; last layout error: " .. cellInfo.layoutError) or "")
end

local function BuildStrip(late)
    if not strip or InCombat() then return end
    stripPending, rosterInCombat = false, false
    stripByUnit, selfButton = {}, nil
    local units, mode = {}, "none"
    if Active() then units, mode = StripUnits() end
    stripMode, stripCount = mode, #units
    local w, h = (mode == "raid") and RAID_W or PARTY_W, (mode == "raid") and RAID_H or PARTY_H
    -- Party: one row. Raid: one column per subgroup that has members, in group order.
    local cols, colOf, perCol = {}, {}, {}
    for _, e in ipairs(units) do
        local g = mode == "raid" and e.group or 1
        if not colOf[g] then
            cols[#cols + 1] = g
            colOf[g] = true
        end
    end
    table.sort(cols)
    local colIndex = {}
    for i, g in ipairs(cols) do colIndex[g] = i end
    local maxW, maxH = 0, 0
    for i, e in ipairs(units) do
        local b = StripButton(i)
        b.unit = e.unit
        Bind(b, e.unit)
        Layout(b, w, h, mode == "raid")
        pcall(b.SetFrameLevel, b, strip:GetFrameLevel() + 10)    -- above its cell, for the clicks
        local x, y
        if mode == "raid" then
            local c = colIndex[e.group]
            perCol[c] = (perCol[c] or 0) + 1
            x, y = GAP + (c - 1) * (w + GAP), -GAP - (perCol[c] - 1) * (h + GAP)
        else
            x, y = GAP + (i - 1) * (w + GAP), -GAP
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", strip, "TOPLEFT", x, y)
        maxW, maxH = math.max(maxW, x + w + GAP), math.max(maxH, -y + h + GAP)
        PlaceCell(b, w, h, mode == "raid", late)
        Label(b)
        Paint(b, { has = false })       -- unseen until the first paint says otherwise
        b:Show()
        stripByUnit[e.unit] = b
        if mode == "raid" and Bool(Call("UnitIsUnit", e.unit, "player")) then selfButton = b end
    end
    for i = #units + 1, #buttons do
        local b = buttons[i]
        b.unit = nil
        Bind(b, nil)
        HideCell(b)
        b:Hide()
    end
    strip:SetSize(math.max(maxW, w + 2 * GAP), math.max(maxH, h + 2 * GAP))
    paintAll = true
end

-- Per fight: per way, how many paints ended shown / hidden / secret / unknown, and the first
-- reason seen why each earlier way gave no answer.
local function NoteMethod(method, outcome, why)
    if not fightStats or not InCombat() then return end
    local m = fightStats[method] or {}
    fightStats[method] = m
    m[outcome] = (m[outcome] or 0) + 1
    fightStats.why = fightStats.why or {}
    for way, text in pairs(why or {}) do
        if fightStats.why[way] == nil then fightStats.why[way] = text end
    end
end

local function PaintButton(b)
    if not b or not b.unit then return end
    local ok, r = pcall(Detect, b.unit)
    if not ok then
        ns.Fail("dispel detection", r)
        r = { method = "none", why = { detection = Why(r) } }
    end
    local okP, outcome = pcall(Paint, b, r)
    if not okP then
        ns.Fail("dispel paint", outcome)
        pcall(b.SetAlpha, b, 0)         -- unknown = hidden
        outcome = "unknown"
    end
    NoteMethod(r.method, outcome or "unknown", r.why)
end

local function PaintStrip(now)
    if paintAll or now - lastFull >= STRIP_REFRESH then
        paintAll, lastFull = false, now
        dirtyUnits = {}
        for _, b in pairs(stripByUnit) do PaintButton(b) end
    else
        local marked = dirtyUnits
        dirtyUnits = {}
        for u in pairs(marked) do
            if u == "player" and selfButton then PaintButton(selfButton) end
            PaintButton(stripByUnit[u])
        end
    end
    lastPaint = now
end

-- ---------------------------------------------------------------------------
-- The out-of-combat list
-- ---------------------------------------------------------------------------

local function Row(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, listBox, "SecureActionButtonTemplate")
    r:SetHeight(ROW_H)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW_H - 4, ROW_H - 4)
    r.icon:SetPoint("LEFT", 2, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.text:SetJustifyH("LEFT")
    r:SetHighlightTexture(FLAT, "ADD")
    local hl = r:GetHighlightTexture()
    if hl then hl:SetVertexColor(1, 1, 1, 0.12) end
    HookTooltip(r)
    r:Hide()
    rows[i] = r
    return r
end

local function Fake(i)
    local f = fakes[i]
    if f then return f end
    f = CreateFrame("Frame", nil, listBox)
    Style(f)
    Layout(f, PARTY_W, PARTY_H, false)
    f:EnableMouse(true)
    f.fake = true
    f:SetScript("OnEnter", function(self) pcall(Tooltip, self) end)
    f:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    f:Hide()
    fakes[i] = f
    return f
end

-- found: the kinds the member has that you can remove, in order; of: kind -> action.
local function Entry(unit, found, of)
    local text, plain = ns.UnitLabel(unit)
    local tags, suffix = {}, {}
    for _, k in ipairs(found) do tags[#tags + 1] = KINDS[k].tag end
    if unit == "player" then suffix[#suffix + 1] = "you" end
    local spell = ActionSpell(of[found[1]])
    local e = { unit = unit, plainName = plain, icon = spell and spell.icon }
    local inRange, isSecret, secretRange = ns.InSpellRange(spell and spell.value, unit)
    if inRange == false then
        e.far = true
        suffix[#suffix + 1] = "out of range"
    elseif isSecret then
        e.hasRangeSecret, e.rangeSecret = true, secretRange
    end
    e.text = text .. " " .. table.concat(tags, " ")
        .. (#suffix > 0 and ("|cffaaaaaa (" .. table.concat(suffix, ", ") .. ")|r") or "")
    return e
end

local function Entries()
    local out = {}
    local removable, of = Removable()
    for _, u in ipairs(ns.GroupUnits()) do
        local ok, eligible = pcall(ns.Eligible, u)
        if ok and eligible then
            local okS, p = pcall(ScanPlain, u)
            if okS and p then
                local found = {}
                for _, k in ipairs(removable) do
                    if p.found[KINDS[k].name] ~= nil then found[#found + 1] = k end
                end
                if #found > 0 then out[#out + 1] = Entry(u, found, of) end
            end
        end
    end
    return out
end

-- The icon of the spell that removes a kind (its action's known spell, else nil).
local function KindIcon(of, k)
    local s = ActionSpell(of[k])
    return s and s.icon
end

-- Test rows for your class: the first kind, the second (else the first) out of range, and the
-- first two together.
local function FakeEntries()
    local kinds, of = ShownKinds()
    local k1, k2 = kinds[1], kinds[2] or kinds[1]
    local both = KINDS[k1].tag .. (kinds[2] and (" " .. KINDS[kinds[2]].tag) or "")
    return {
        { text = "|cffc79c6eTankyboy|r " .. KINDS[k1].tag, icon = KindIcon(of, k1), plainName = "Tankyboy", fake = true },
        { text = "|cfff58cbaHealbot|r " .. KINDS[k2].tag .. "|cffaaaaaa (out of range)|r", icon = KindIcon(of, k2),
          plainName = "Healbot", fake = true, far = true },
        { text = "|cff69ccf0Frostmage|r " .. both, icon = KindIcon(of, k1),
          plainName = "Frostmage", fake = true },
    }
end

-- A sample of the strip for your class: one member per kind, the first two kinds together, and
-- one of an unknown kind. Members with nothing to remove are invisible in combat, so the sample
-- has none of them.
local function FakeStrip()
    local kinds = ShownKinds()
    local names = { "|cffc79c6eTankyboy|r", "|cfff58cbaHealbot|r", "|cffabd473Arrowz|r" }
    local out = {}
    for i, k in ipairs(kinds) do
        local K = KINDS[k]
        out[#out + 1] = { names[i] or "|cffffffffMember|r", { has = true, found = { k }, name = K.sample, icon = K.sampleIcon } }
    end
    local K = KINDS[kinds[1]]
    out[#out + 1] = { "|cff69ccf0Frostmage|r", { has = true, found = { kinds[1], kinds[2] },
        name = K.sample2 or K.sample, icon = K.sampleIcon2 or K.sampleIcon } }
    out[#out + 1] = { "|cfffff569Stabby|r", { has = true } }
    return out
end

-- What each mouse button removes: "left: curse, right: poison" or "left or right: poison/disease".
local function ClickText()
    if Single() then return "left or right: " .. KindsText(ActionKinds(1), "name", "/"):lower() end
    return "left: " .. KindsText(ActionKinds(1), "name", "/"):lower()
        .. ", right: " .. KindsText(ActionKinds(2), "name", "/"):lower()
end

local function UpdateList()
    lastList, listDirty = Now(), false
    if not panel or InCombat() then return end
    local testing = Testing()
    if not Active() and not testing then
        panel:Hide()
        shownRows = 0
        return
    end
    panel:Show()
    local entries = Active() and ns.DropFar(Entries()) or {}
    if testing then
        for _, e in ipairs(FakeEntries()) do entries[#entries + 1] = e end
    end
    shownRows = #entries
    local y, w = -PAD, MIN_W
    if #entries > 0 then
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", listBox, "TOPLEFT", PAD + 2, y)
        header:SetText("Dispel:")
        header:Show()
        y = y - HEADER_H
    else
        header:Hide()
    end
    for i, e in ipairs(entries) do
        local r = Row(i)
        r.plainName, r.far, r.fake = e.plainName, e.far, e.fake
        Bind(r, (not e.fake) and e.unit or nil)
        r.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        r.text:SetText(e.text)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", listBox, "TOPLEFT", PAD, y)
        r:SetPoint("TOPRIGHT", listBox, "TOPRIGHT", -PAD, y)
        r:SetAlpha(1)
        if e.far then
            r:SetAlpha(OUT_OF_RANGE)
        elseif e.hasRangeSecret and type(r.SetAlphaFromBoolean) == "function" then
            pcall(r.SetAlphaFromBoolean, r, e.rangeSecret, 1, OUT_OF_RANGE)
        end
        r:Show()
        w = math.max(w, (Num(r.text:GetStringWidth()) or 0) + ROW_H + 2 * PAD + 14)
        y = y - ROW_H
    end
    for i = #entries + 1, #rows do
        Bind(rows[i], nil)
        rows[i]:Hide()
    end
    if #entries > 0 then y = y - 4 end

    -- Test: a sample of the in-combat strip (plain frames, they cast nothing).
    if testing then
        stripTitle:ClearAllPoints()
        stripTitle:SetPoint("TOPLEFT", listBox, "TOPLEFT", PAD + 2, y)
        stripTitle:SetText("In combat, only members with something to remove (" .. ClickText() .. "):")
        stripTitle:Show()
        w = math.max(w, (Num(stripTitle:GetStringWidth()) or 0) + 2 * PAD + 4)
        y = y - 14
        local sample = FakeStrip()
        for i, s in ipairs(sample) do
            local f = Fake(i)
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", listBox, "TOPLEFT", PAD + (i - 1) * (PARTY_W + GAP), y)
            f.text:SetText(s[1] .. ":")
            f.plainName = s[1]:match("|c%x%x%x%x%x%x%x%x(.-)|r") or s[1]
            Paint(f, s[2])
            f:Show()
        end
        w = math.max(w, 2 * PAD + #sample * (PARTY_W + GAP))
        y = y - PARTY_H - 4
    else
        stripTitle:Hide()
        for _, f in ipairs(fakes) do f:Hide() end
    end

    local unlocked = not Locked()
    if unlocked or testing then
        local parts = {}
        if #entries == 0 then parts[#parts + 1] = "Dispel: nothing to remove." end
        if testing then parts[#parts + 1] = "Test rows (/bbuff test hides them)." end
        if unlocked then parts[#parts + 1] = "Unlocked: drag to move, /bbuff dispel lock." end
        hint:ClearAllPoints()
        hint:SetPoint("TOPLEFT", listBox, "TOPLEFT", PAD + 2, y - 2)
        hint:SetText(table.concat(parts, "\n"))
        hint:Show()
        w = math.max(w, (Num(hint:GetStringWidth()) or 0) + 2 * PAD + 4)
        y = y - (Num(hint:GetStringHeight()) or 12) - 4
    else
        hint:Hide()
    end

    local width, height = math.ceil(w), math.ceil(-y + PAD - 4)
    listBox:SetSize(width, height)
    panel:SetSize(width, height)
    if #entries > 0 or unlocked or testing then listBox:Show() else listBox:Hide() end
end

-- ---------------------------------------------------------------------------
-- Spells and settings
-- ---------------------------------------------------------------------------

local function ResolveSpells()
    if InCombat() then
        spellsPending = true
        return
    end
    spellsPending = false
    spells = {}
    for a, act in ipairs(Actions()) do
        spells[a] = {}
        for _, e in ipairs(act.spells) do
            local s = ns.ResolveSpell(e.ids, e.name)
            s.kinds = e.kinds
            spells[a][#spells[a] + 1] = s
        end
    end
    curve = nil
    stripPending, listDirty = true, true
end

-- Everything a rebuild depends on; a change means rebuild (out of combat).
local function Signature()
    local c, p = ButtonSpell(1), ButtonSpell(2)
    return table.concat({ tostring(Active()), tostring(Testing()), table.concat((Removable()), "/"),
        tostring(Locked()), tostring(ns.UseKeyDown()), tostring(c and c.value), tostring(p and p.value) }, ",")
end

local function SetLocked(locked)
    local db = DB()
    db.dispelLocked = (not locked) and false or nil
    listDirty = true
    Print(locked and "dispel panel locked (Alt + drag still moves it)."
        or "dispel panel unlocked: drag it to move, /bbuff dispel lock when done.")
end

local function ResetPosition()
    DB().dispelPos = nil
    if InCombat() then
        Print("the dispel panel moves back after combat.")
        return
    end
    ApplyPosition()
    Print("dispel panel back below the buff box.")
end

local function Slash(arg)
    local what, rest = arg:match("^(%S*)%s*(.*)$")
    if what == "" or what == "on" or what == "off" then
        local v = ns.Toggle(what, On("dispel"))
        ns.Set("dispel", v)
        if not cfg then
            Print("the dispel panel is for druids, mages, paladins, priests and shamans; it stays hidden on this character.")
        end
    elseif KINDS[what] then
        -- Any kind, whatever the class (the settings are account-wide); only your class's
        -- kinds matter on this character.
        local key = KINDS[what].key
        local v = ns.Toggle(rest, On(key))
        if v == nil then Print("/bbuff dispel " .. what .. " [on|off]") else ns.Set(key, v) end
    elseif what == "unlock" then
        SetLocked(false)
    elseif what == "lock" then
        SetLocked(true)
    elseif what == "reset" then
        ResetPosition()
    else
        Print("/bbuff dispel [on|off], /bbuff dispel " .. table.concat(cfg and ClassKinds(cfg) or KIND_ORDER, "|")
            .. " [on|off], /bbuff dispel unlock|lock|reset")
    end
    listDirty = true
end

-- ---------------------------------------------------------------------------
-- Into the class modules: options, slash, help, status, hub menu
-- ---------------------------------------------------------------------------

local WAYS = { "plain read", "aura instance IDs", "filtered read", "none" }
local OUTCOMES = { "shown", "hidden", "secret", "unknown" }

-- "way N (shown a, hidden b, ...)" per way that answered.
local function Methods(stats)
    if not stats then return nil end
    local parts = {}
    for _, m in ipairs(WAYS) do
        local s = stats[m]
        if s then
            local n, ends = 0, {}
            for _, o in ipairs(OUTCOMES) do
                if s[o] then
                    n = n + s[o]
                    ends[#ends + 1] = o .. " " .. s[o]
                end
            end
            parts[#parts + 1] = m .. " " .. n .. " (" .. table.concat(ends, ", ") .. ")"
        end
    end
    return #parts > 0 and table.concat(parts, "; ") or nil
end

-- Why the earlier ways gave no answer, in order.
local function Reasons(stats)
    local why = stats and stats.why
    if not why then return nil end
    local parts = {}
    for _, w in ipairs({ "plain read", "aura instance IDs", "filtered read", "detection" }) do
        if why[w] then parts[#parts + 1] = w .. ": " .. why[w] end
    end
    return #parts > 0 and table.concat(parts, "; ") or nil
end

-- What an action resolved to: the known spell's text, else every spell's ("... not known").
local function ActionText(a)
    local s = ActionSpell(a)
    if s then return s.text end
    local parts = {}
    for _, r in ipairs(spells[a] or {}) do parts[#parts + 1] = r.text end
    return #parts > 0 and table.concat(parts, "; ") or "not resolved yet"
end

-- "curses (left-click): ...   poisons (right-click): ..." or "poisons, diseases, magic (left-
-- or right-click): ...".
local function SpellsLine()
    local parts = {}
    for a in ipairs(Actions()) do
        parts[#parts + 1] = KindsText(ActionKinds(a), "plural")
            .. (Single() and " (left- or right-click): " or a == 1 and " (left-click): " or " (right-click): ")
            .. ActionText(a)
    end
    return table.concat(parts, "   ")
end

local function StatusExtra()
    local db = DB()
    local p = db and db.dispelPos
    local c, po = ButtonSpell(1), ButtonSpell(2)
    local removable = Removable()
    local C = _G.C_UnitAuras
    local function Has(name) return ns.YesNo(type(C) == "table" and type(C[name]) == "function") end
    local f = ChooseFilter()
    local seen = (InCombat() and fightStats and next(fightStats)) and fightStats or lastFight
    local detection = Methods(seen)
    if not detection then
        detection = "not seen in a fight yet"
    else
        detection = (seen == fightStats and "this fight: " or "last fight: ") .. detection
        if not (seen["plain read"] or seen["aura instance IDs"] or seen["filtered read"]) then
            detection = detection .. " - no answer in combat on this client: unknown = hidden"
                .. (CellCount() > 0 and "; the game's aura container draws the icons instead" or ", so the strip shows nothing")
        end
    end
    local reasons = Reasons(seen)
    return {
        "dispel panel: " .. ns.OnOff(On("dispel")) .. "   " .. (Active() and "active" or "idle")
            .. "   " .. (InCombat() and "strip (combat)" or (panel and panel:IsShown() and listBox:IsShown()) and ("shown, " .. shownRows .. " rows") or "hidden")
            .. "   " .. (Locked() and "locked" or "unlocked")
            .. "   position: " .. (type(p) == "table" and string.format("%d, %d", p.x or 0, p.y or 0) or "default (below the box)"),
        SpellsLine() .. (spellsPending and " (update waits for combat to end)" or ""),
        "removes now: " .. (#removable > 0 and KindsText(removable, "plural") or "nothing (no dispel spell known yet, or every kind off)"),
        "strip: " .. stripMode .. ", " .. stripCount .. " buttons" .. ((stripPending or rosterInCombat) and " (rebuild after combat)" or "")
            .. "   combat show: " .. (drivers and "state driver" or "PLAYER_REGEN_DISABLED")
            .. "   left: " .. (c and c.label or "nothing")
            .. "   right: " .. (po and po.label or "nothing"),
        "dispel filter: " .. (f or "none") .. " (" .. tostring(filterInfo) .. ")   GetUnitAuraInstanceIDs "
            .. Has("GetUnitAuraInstanceIDs") .. "   GetAuraDispelTypeColor " .. Has("GetAuraDispelTypeColor")
            .. "   colour curve " .. ns.YesNo(Curve() ~= nil),
        "combat icons (Blizzard aura container): " .. CellStatus(),
        "in-combat detection (tried in order: " .. ORDER .. "; shown / hidden / secret = SetAlphaFromBoolean / unknown = hidden): " .. detection,
        reasons and ("ways that gave no answer: " .. reasons) or nil,
    }
end

local function Menu()
    return {
        { text = "Lock dispel panel", checkbox = true,
          checked = function() return Locked() end,
          func = function() SetLocked(not Locked()) end },
        { text = "Reset dispel panel position", func = ResetPosition },
    }
end

-- Adds the panel to one class module: its options (labelled for that class, one per kind the
-- class can remove), the dispel slash command, help lines, status lines and hub menu entries
-- (after the module's own).
local function Hook(mod, classFile)
    local c = CLASS_CONFIG[classFile]
    local kinds = ClassKinds(c)
    mod.options = mod.options or {}
    mod.options[#mod.options + 1] = { key = "dispel", short = "dispel",
        label = "Dispel panel (" .. KindsText(kinds, "plural") .. ")" }
    for _, k in ipairs(kinds) do
        mod.options[#mod.options + 1] = { key = KINDS[k].key, short = k, label = "Dispel: " .. KINDS[k].plural }
    end
    mod.savedKeys = mod.savedKeys or {}
    mod.savedKeys.dispelPos, mod.savedKeys.dispelLocked = true, true

    local clicks
    if #c.actions == 1 then
        clicks = "left- or right-click " .. SpellNames(c.actions[1])
    else
        clicks = "left-click " .. SpellNames(c.actions[1]) .. ", right-click " .. SpellNames(c.actions[2])
    end
    local baseSlash, baseHelp, baseMenu = mod.Slash, mod.Help, mod.Menu
    mod.Slash = function(cmd, arg)
        if cmd == "dispel" then
            Slash(arg or "")
            return true
        end
        return baseSlash(cmd, arg)
    end
    mod.Help = function()
        local out = baseHelp()
        -- Only your class's dispel lines (the druid's on a class without a panel), not once per module.
        if cfg ~= c and not (cfg == nil and classFile == "DRUID") then return out end
        out[#out + 1] = "/bbuff dispel [on|off] - the dispel panel: who has something you can remove ("
            .. KindsText(kinds, "plural") .. ") out of combat, in combat a button per member, seen only when there is one to remove: the game draws the debuff's icon and name itself (Blizzard aura container), what this addon cannot read stays hidden; "
            .. clicks
        out[#out + 1] = "/bbuff dispel " .. table.concat(kinds, "|") .. " [on|off] - each kind; /bbuff dispel unlock | lock | reset - move the panel"
        return out
    end
    mod.StatusExtra = StatusExtra
    mod.Menu = function()
        local out = baseMenu and baseMenu() or {}
        for _, e in ipairs(Menu()) do out[#out + 1] = e end
        return out
    end
end

for classFile in pairs(CLASS_CONFIG) do
    if ns.modules[classFile] then Hook(ns.modules[classFile], classFile) end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local GROUP_UNIT = { player = true }
for i = 1, 4 do GROUP_UNIT["party" .. i] = true end
for i = 1, 40 do GROUP_UNIT["raid" .. i] = true end

local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function()
    local ok, err = pcall(function()
        local now = Now()
        if InCombat() then
            if now - lastPaint >= STRIP_THROTTLE then PaintStrip(now) end
            return
        end
        local s = Signature()
        if s ~= sig then
            sig, stripPending, listDirty = s, true, true
            ApplyPosition()
        end
        if spellsPending then ResolveSpells() end
        if stripPending then BuildStrip() end
        if now - lastList >= LIST_THROTTLE
            and (listDirty or (Active() and ns.InGroup() and now - lastList >= LIST_REFRESH)) then
            UpdateList()
        end
    end)
    if not ok then ns.Fail("dispel update", err) end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
    local ok, err = pcall(function()
        if event == "PLAYER_LOGIN" then
            local classFile, classID = ns.PlayerClass()
            if classFile then
                cfg = CLASS_CONFIG[classFile]
            else
                for _, c in pairs(CLASS_CONFIG) do
                    if c.id == classID then cfg = c end
                end
            end
            if not cfg or not ns.modules[cfg.class] then
                cfg = nil
                return
            end
            CreatePanel()
            ResolveSpells()
            for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
                "GROUP_ROSTER_UPDATE", "UNIT_AURA", "SPELLS_CHANGED" }) do
                self:RegisterEvent(e)
            end
            pcall(self.RegisterEvent, self, "LEARNED_SPELL_IN_TAB")
            pcall(self.RegisterEvent, self, "UNIT_CONNECTION")
            ticker:Show()
        elseif event == "PLAYER_ENTERING_WORLD" then
            ApplyPosition()
            listDirty, stripPending = true, true
        elseif event == "PLAYER_REGEN_DISABLED" then
            -- Still allowed here, right before the lockdown: a rebuild that is due, and the
            -- fallback show/hide for a client without state drivers.
            if stripPending and not InCombat() then pcall(BuildStrip, true) end
            if not drivers and panel then
                pcall(list.Hide, list)
                pcall(strip.Show, strip)
            end
            fightStats = {}
            paintAll = true
            PaintStrip(Now())
        elseif event == "PLAYER_REGEN_ENABLED" then
            if not drivers and panel then
                strip:Hide()
                list:Show()
            end
            if fightStats and next(fightStats) then lastFight = fightStats end
            fightStats = nil
            if spellsPending then ResolveSpells() end
            if rosterInCombat then stripPending = true end
            listDirty = true
        elseif event == "GROUP_ROSTER_UPDATE" then
            if InCombat() then
                -- The buttons follow unit tokens, so they still cast on whoever holds the token
                -- now; only the names change until the rebuild after combat.
                rosterInCombat = true
                for _, b in pairs(stripByUnit) do
                    pcall(Label, b)
                    RefreshCell(b)
                end
                paintAll = true
            else
                stripPending = true
            end
            listDirty = true
        elseif event == "UNIT_AURA" then
            if Secret(arg1) or not GROUP_UNIT[arg1] then return end
            if InCombat() then dirtyUnits[arg1] = true else listDirty = true end
        elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
            ResolveSpells()
        else
            listDirty = true
        end
    end)
    if not ok then ns.Fail("dispel " .. event, err) end
end)
