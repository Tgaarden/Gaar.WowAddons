--[[
  BetterBuffsForever - the dispel panel of a druid (curses and poisons) and a shaman (poisons and
  diseases). Loaded after Druid.lua and Shaman.lua; it hooks into both modules (options, slash
  command, help, status, hub menu) and keeps its own frames and events, so the buff box and the
  paladin module are untouched. What differs per class is one table, CLASS_CONFIG: the kind
  removed by left-click, the kind removed by right-click, and their spells.

                left-click                      right-click
    Druid       Curse (purple): Remove Curse    Poison (green): Abolish Poison, else Cure Poison
    Shaman      Poison (green): Cure Poison     Disease (ochre): Cure Disease

    * Only for those two classes, and only spells you know: Remove Curse (2782), Abolish Poison
      (2893) and the druid's Cure Poison (8946; used for right-click only while Abolish Poison is
      not known); the shaman's Cure Poison (526) and Cure Disease (2870). The IDs are the classic
      ones (WhatsTraining's Vanilla/Camelot druid and shaman data have the same); they are
      resolved at login and on SPELLS_CHANGED like the buffs (by ID, else by the localized name),
      and /bbuff status shows what was found.
    * A panel of its own, not part of the buff box: by default just below the box (it follows the
      box), movable (/bbuff dispel unlock, or Alt + drag; /bbuff dispel reset), position saved
      account-wide as an offset from the top centre.
    * Out of combat: one row per member (you too) with something you can remove: the
      class-coloured name and a coloured tag per kind ("Curse" purple, "Poison" green, "Disease"
      ochre). Dead, offline and unseen members are skipped; out-of-range members are dimmed. Read
      with plain dispelName ("Curse", "Poison", "Disease") from
      C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL").
    * In combat: a fixed strip with one secure button per group member: you alone, you and
      party1-4, or in a raid every raidN by subgroup (one column per subgroup that has members,
      up to 8 columns of 5: at most 40 small buttons). It is built out of combat on every roster
      change, and at PLAYER_REGEN_DISABLED if a rebuild is still due; a roster change in combat
      only relabels the names and the rebuild waits for PLAYER_REGEN_ENABLED (the buttons follow
      unit tokens, so they keep working). A state driver shows the strip for the whole fight
      ("[combat] show; hide") and the out-of-combat list the other way round.
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
      anything. Without them: a question mark and the kind ("Curse" / "Poison" / "Disease") or
      "Dispel". The colour is plain child textures (allowed in combat): the left half shows the
      left-click kind, the right half the right-click kind; a member with only one of them is
      that colour all over; dispellable but of an unknown kind = yellow.
    * Clicks, on the rows and the strip alike: left-click (type1/spell1) = the left kind's spell,
      right-click (type2/spell2) = the right kind's; unit = the member's token. A click whose
      spell you do not know, or whose kind is switched off, does nothing. Registered for the one
      direction ActionButtonUseKeyDown acts on, like the buff rows.

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
       colour curve over the dispel type (Curse 2 = purple, Disease 3 = ochre, Poison 4 = green,
       each only for the class's two kinds while switched on; anything else = transparent),
       passed straight to SetVertexColor, never read here. Without a colour it glows yellow.
    3. "filtered read": GetAuraDataByIndex(unit, 1..2, filter): a non-nil answer means "has
       one"; the kind from a plain dispelName, else the colour API on its auraInstanceID, else
       yellow.
    4. "none": unknown, so the button is invisible (still clickable where it sits).
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

-- Per class: the kind left-click removes and the kind right-click removes, each with its spells
-- (the first one known is cast).
local CLASS_CONFIG = {
    DRUID = { class = "DRUID", id = 11,
        left = { kind = "curse", spells = { { ids = { 2782 }, name = "Remove Curse" } } },
        right = { kind = "poison", spells = { { ids = { 2893 }, name = "Abolish Poison" },
                                              { ids = { 8946 }, name = "Cure Poison" } } } },
    SHAMAN = { class = "SHAMAN", id = 7,
        left = { kind = "poison", spells = { { ids = { 526 }, name = "Cure Poison" } } },
        right = { kind = "disease", spells = { { ids = { 2870 }, name = "Cure Disease" } } } },
}
local SIDES = { "left", "right" }

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

local spells = { left = {}, right = {} }   -- side -> ns.ResolveSpell results, in order
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

-- The kind a side removes: { name, type, rgb, tag, key, plural, ... }.
local function Kind(side) return KINDS[Cfg()[side].kind] end

-- The first spell of a side you know, or nil.
local function SideSpell(side)
    for _, s in ipairs(spells[side]) do
        if s.value then return s end
    end
    return nil
end

-- A side you can and want to remove.
local function Want(side) return On(Kind(side).key) and SideSpell(side) ~= nil end

local function Active()
    return cfg ~= nil and DB() ~= nil and On("enabled") and On("dispel") and (Want("left") or Want("right"))
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

-- A step colour curve over the dispel type: the class's two kinds in their colours (each only
-- while that kind is wanted), everything else transparent. false where the client has no
-- colour curves.
local function Curve()
    local key = Cfg()[SIDES[1]].kind .. tostring(Want("left")) .. tostring(Want("right"))
    if curve ~= nil and curveKey == key then return curve or nil end
    curveKey, curve = key, false
    local CU, E, CC = _G.C_CurveUtil, _G.Enum, _G.CreateColor
    if type(CU) ~= "table" or type(CU.CreateColorCurve) ~= "function" or type(CC) ~= "function" then return nil end
    local ok, c = pcall(function()
        local c = CU.CreateColorCurve()
        if type(E) == "table" and type(E.LuaCurveType) == "table" and E.LuaCurveType.Step ~= nil then
            c:SetType(E.LuaCurveType.Step)
        end
        -- x -> colour (false = transparent): each kind's type, and the type after it back to
        -- transparent unless that is the other kind (Disease 3 and Poison 4 are neighbours).
        local points = { [0] = false }
        for _, side in ipairs(SIDES) do
            local k = Kind(side)
            points[k.type] = Want(side) and k.rgb or false
            if points[k.type + 1] == nil then points[k.type + 1] = false end
        end
        local xs = {}
        for x in pairs(points) do xs[#xs + 1] = x end
        table.sort(xs)
        for _, x in ipairs(xs) do
            local rgb = points[x]
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
-- how to colour it: left/right (the class's two kinds, known) or ids (aura instance IDs for the
-- colour API),
-- and what it is: name and icon of the first dispellable debuff (either may be secret or nil);
-- method = which way answered; why = { way -> why it did not answer } for the ways before it.
local function Detect(unit)
    local why = {}
    local p, whyPlain = ScanPlain(unit)
    if p then
        local fl, fr = p.found[Kind("left").name], p.found[Kind("right").name]
        local l, rt = fl ~= nil and Want("left"), fr ~= nil and Want("right")
        local r = { has = l or rt, left = l, right = rt, method = "plain read" }
        local first = (l and fl) or (rt and fr)
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
                if ok2 and not Secret(dn) and dn == Kind("left").name then r.left = true
                elseif ok2 and not Secret(dn) and dn == Kind("right").name then r.right = true
                else r.unknownKind = true end
                if ok2 then r.ids[#r.ids + 1] = id end
            end
        end
        if not r.has then r.has = false end
        if r.unknownKind then r.left, r.right = nil, nil else r.ids = nil end
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
        b.debuff:SetText(r.left and Kind("left").name or r.right and Kind("right").name or "Dispel")
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
    if r.left or r.right then
        local L, R = Kind("left").rgb, Kind("right").rgb
        Glow(b.glowL, r.left and L or R)
        Glow(b.glowR, r.right and R or L)
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
        for _, side in ipairs(SIDES) do
            local s = SideSpell(side)
            tip:AddLine((side == "left" and "Left-click: " or "Right-click: ")
                .. ((Want(side) and s) and s.label or ("nothing (" .. Kind(side).plural .. " off or not known)")), 1, 1, 1)
        end
        if self.far then tip:AddLine("Out of range", 1, 0.3, 0.3) end
    end
    tip:Show()
end

local function HookTooltip(b)
    b:HookScript("OnEnter", function(self) pcall(Tooltip, self) end)
    b:HookScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
end

-- The click attributes, out of combat only: left = the left kind's spell, right = the right's.
local function Bind(b, unit)
    local c, p = Want("left") and SideSpell("left"), Want("right") and SideSpell("right")
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
    b.text:SetText((hex and ("|c" .. hex .. short .. "|r") or short) .. (raid and "" or ":"))
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

local function BuildStrip()
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

local function Entry(unit, has)
    local text, plain = ns.UnitLabel(unit)
    local tags, suffix = {}, {}
    if has.left then tags[#tags + 1] = Kind("left").tag end
    if has.right then tags[#tags + 1] = Kind("right").tag end
    if unit == "player" then suffix[#suffix + 1] = "you" end
    local spell = has.left and SideSpell("left") or SideSpell("right")
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
    for _, u in ipairs(ns.GroupUnits()) do
        local ok, eligible = pcall(ns.Eligible, u)
        if ok and eligible then
            local okS, p = pcall(ScanPlain, u)
            if okS and p then
                local has = { left = p.found[Kind("left").name] ~= nil and Want("left"),
                    right = p.found[Kind("right").name] ~= nil and Want("right") }
                if has.left or has.right then out[#out + 1] = Entry(u, has) end
            end
        end
    end
    return out
end

local function FakeEntries()
    local L, R = Kind("left"), Kind("right")
    local c = SideSpell("left") or { label = Cfg().left.spells[1].name }
    local p = SideSpell("right") or { label = Cfg().right.spells[1].name }
    return {
        { text = "|cffc79c6eTankyboy|r " .. L.tag, icon = c.icon, plainName = "Tankyboy", fake = true },
        { text = "|cfff58cbaHealbot|r " .. R.tag .. "|cffaaaaaa (out of range)|r", icon = p.icon,
          plainName = "Healbot", fake = true, far = true },
        { text = "|cff69ccf0Frostmage|r " .. L.tag .. " " .. R.tag, icon = c.icon,
          plainName = "Frostmage", fake = true },
    }
end

-- A sample of the strip for your class. Members with nothing to remove are invisible in combat,
-- so the sample has none of them.
local function FakeStrip()
    local L, R = Kind("left"), Kind("right")
    return {
        { "|cffc79c6eTankyboy|r", { has = true, left = true, name = L.sample, icon = L.sampleIcon } },
        { "|cfff58cbaHealbot|r", { has = true, right = true, name = R.sample, icon = R.sampleIcon } },
        { "|cff69ccf0Frostmage|r", { has = true, left = true, right = true, name = L.sample2 or L.sample,
            icon = L.sampleIcon2 or L.sampleIcon } },
        { "|cfffff569Stabby|r", { has = true } },
    }
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
    local entries = Active() and Entries() or {}
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
        stripTitle:SetText("In combat, only members with something to remove (left: " .. Kind("left").name:lower()
            .. ", right: " .. Kind("right").name:lower() .. "):")
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
    for _, side in ipairs(SIDES) do
        spells[side] = {}
        for _, e in ipairs(Cfg()[side].spells) do spells[side][#spells[side] + 1] = ns.ResolveSpell(e.ids, e.name) end
    end
    curve = nil
    stripPending, listDirty = true, true
end

-- Everything a rebuild depends on; a change means rebuild (out of combat).
local function Signature()
    local c, p = SideSpell("left"), SideSpell("right")
    return table.concat({ tostring(Active()), tostring(Testing()), tostring(Want("left")), tostring(Want("right")),
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
        if not cfg then Print("the dispel panel is for druids and shamans; it stays hidden on this character.") end
    elseif KINDS[what] then
        -- Any kind, whatever the class (the settings are account-wide); only your class's two
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
        Print("/bbuff dispel [on|off], /bbuff dispel " .. Cfg().left.kind .. "|" .. Cfg().right.kind
            .. " [on|off], /bbuff dispel unlock|lock|reset")
    end
    listDirty = true
end

-- ---------------------------------------------------------------------------
-- Into the druid and shaman modules: options, slash, help, status, hub menu
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

-- What a side resolved to: the known spell's text, else every spell's ("... not known").
local function SideText(side)
    local s = SideSpell(side)
    if s then return s.text end
    local parts = {}
    for _, r in ipairs(spells[side]) do parts[#parts + 1] = r.text end
    return #parts > 0 and table.concat(parts, "; ") or "not resolved yet"
end

local function StatusExtra()
    local db = DB()
    local p = db and db.dispelPos
    local c, po = SideSpell("left"), SideSpell("right")
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
            detection = detection .. " - no answer in combat on this client: unknown = hidden, so the strip shows nothing"
        end
    end
    local reasons = Reasons(seen)
    return {
        "dispel panel: " .. ns.OnOff(On("dispel")) .. "   " .. (Active() and "active" or "idle")
            .. "   " .. (InCombat() and "strip (combat)" or (panel and panel:IsShown() and listBox:IsShown()) and ("shown, " .. shownRows .. " rows") or "hidden")
            .. "   " .. (Locked() and "locked" or "unlocked")
            .. "   position: " .. (type(p) == "table" and string.format("%d, %d", p.x or 0, p.y or 0) or "default (below the box)"),
        Kind("left").plural .. " (left-click): " .. SideText("left")
            .. "   " .. Kind("right").plural .. " (right-click): " .. SideText("right")
            .. (spellsPending and " (update waits for combat to end)" or ""),
        "strip: " .. stripMode .. ", " .. stripCount .. " buttons" .. ((stripPending or rosterInCombat) and " (rebuild after combat)" or "")
            .. "   combat show: " .. (drivers and "state driver" or "PLAYER_REGEN_DISABLED")
            .. "   left: " .. ((Want("left") and c) and c.label or "nothing")
            .. "   right: " .. ((Want("right") and po) and po.label or "nothing"),
        "dispel filter: " .. (f or "none") .. " (" .. tostring(filterInfo) .. ")   GetUnitAuraInstanceIDs "
            .. Has("GetUnitAuraInstanceIDs") .. "   GetAuraDispelTypeColor " .. Has("GetAuraDispelTypeColor")
            .. "   colour curve " .. ns.YesNo(Curve() ~= nil),
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

-- Adds the panel to one class module: its options (labelled for that class), the dispel slash
-- command, help lines, status lines and hub menu entries (after the module's own).
local function Hook(mod, classFile)
    local c = CLASS_CONFIG[classFile]
    local L, R = KINDS[c.left.kind], KINDS[c.right.kind]
    local Lspell, Rspell = c.left.spells[1].name, c.right.spells[1].name
    mod.options = mod.options or {}
    mod.options[#mod.options + 1] = { key = "dispel", short = "dispel",
        label = "Dispel panel (" .. L.plural .. ", " .. R.plural .. ")" }
    mod.options[#mod.options + 1] = { key = L.key, short = c.left.kind, label = "Dispel: " .. L.plural }
    mod.options[#mod.options + 1] = { key = R.key, short = c.right.kind, label = "Dispel: " .. R.plural }
    mod.savedKeys = mod.savedKeys or {}
    mod.savedKeys.dispelPos, mod.savedKeys.dispelLocked = true, true

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
        out[#out + 1] = "/bbuff dispel [on|off] - the dispel panel: who has a " .. L.name:lower() .. " or "
            .. R.name:lower() .. " (out of combat), in combat a button per member, seen only when there is one to remove (unknown = hidden), with the debuff's icon and name; left-click "
            .. Lspell .. ", right-click " .. Rspell
        out[#out + 1] = "/bbuff dispel " .. c.left.kind .. "|" .. c.right.kind .. " [on|off] - each kind; /bbuff dispel unlock | lock | reset - move the panel"
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
            if stripPending and not InCombat() then pcall(BuildStrip) end
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
                for _, b in pairs(stripByUnit) do pcall(Label, b) end
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
