--[[
  BetterBuffsForever - a druid's buff check on WoW Forever: who lacks Mark of the Wild, and
  whether you or your tank lack Thorns. Click a name to buff it.

  It does this and nothing else:

    * Only for a Druid. Any other class leaves the addon idle: no scans, no box; /bbuff status
      says so.
    * Mark of the Wild: warns when you lack it and, in a party or raid, lists every member who
      lacks it. Gift of the Wild counts as having it.
    * Thorns: warns when you lack it, and when the group's tank lacks it. The tank is, in order:
      every member UnitGroupRolesAssigned() calls "TANK"; else, in a raid, every main tank
      (GetPartyAssignment("MAINTANK", unit)); else the tank you set by hand (/bbuff tank, your
      current target, per character); else there is no tank check.
    * Only spells the character knows are checked: no Thorns warning before Thorns is learned.
    * A box at the top centre of the screen, shown only while something is missing: a "Missing
      Mark of the Wild:" section and a "Missing Thorns:" section, one row per member with a
      class-coloured name. Dead or ghost, offline and not-visible members (UnitIsVisible) are
      never warned about; out-of-range members are shown dimmed (still clickable, the cast just
      fails). A member whose auras cannot be read (secret) counts as unknown, never as missing.
    * Click to buff: every row is a SecureActionButtonTemplate button, type "spell", spell = the
      localized name (the highest rank you know), unit = that member's unit token. Left-click
      casts on the member. Right-click on a Mark of the Wild row casts Gift of the Wild when you
      know it and are in a group (it needs its reagent); otherwise right-click does what
      left-click does.
    * Combat: the box is hidden in combat. Aura data is secret then, secure attributes cannot
      change, and buffing mid-fight is not the point. A state driver ("[combat] hide; show")
      hides it the moment combat starts, PLAYER_REGEN_DISABLED as a fallback; nothing is scanned
      in combat, and the box is rebuilt at PLAYER_REGEN_ENABLED.
    * The box can be moved: drag it while unlocked (/bbuff unlock), or Alt + drag at any time.
      The position is saved account-wide. /bbuff reset puts it back at the top centre.
    * Updates are throttled to 4 a second (UNIT_AURA, GROUP_ROSTER_UPDATE, ...), plus a refresh
      every 1.5 s while in a group, for range, death and visibility, which have no cheap event.
    * Low reagents (on by default): a "Low reagents:" line in the same box when the bags hold
      fewer than the threshold of the reagent for the highest rank you know of Gift of the Wild
      (rank 1 Wild Berries 17021, rank 2 Wild Thornroot 17026; default 10) and of Rebirth (rank 1
      Maple Seed 17034, 2 Stranglethorn Seed 17035, 3 Ashwood Seed 17036, 4 Hornbeam Seed 17037,
      5 Ironwood Seed 17038; default 2). A spell you do not know is skipped. Bags only
      (C_Item.GetItemCount / GetItemCount), updated on BAG_UPDATE_DELAYED. Not clickable.
    * An optional short sound when something new goes missing (off by default).
    * /bbuff for help, on, off, motw, thorns, tank, group, sound, reagents, unlock, lock, reset,
      test and status.
    * BetterBuffsForeverAPI, a small global table for BetterGaarForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The addon runs exactly the same
      without the hub; the API only exposes the settings the slash command already changes.

  Spells (classic ranks, checked in game data):
    Mark of the Wild  1126, 5232, 6756, 5234, 8907, 9884, 9885 (ranks 1-7)
    Gift of the Wild  21849, 21850 (ranks 1-2)
    Thorns            467, 782, 1075, 8914, 9756, 9910 (ranks 1-6)
    Rebirth           20484, 20739, 20742, 20747, 20748 (ranks 1-5, reagents only)
  The buttons cast the localized name of the highest rank known, or the spell ID when the client
  gives no name. A buff is recognised by its spell ID, else by the localized name of any rank.

  Aura reads: C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL") (UnitBuff / UnitAura on an older
  client), one pcall per read, asking C_Secrets.ShouldUnitAuraIndexBeSecret first, like
  BetterFramesForever. A refused read, a secret aura or a secret spell ID with a secret name
  makes that member unknown for the check, and unknown is never warned about.

  Taint: Blizzard code is only followed, never replaced; no Blizzard function or table is
  written. Attributes are only ever set out of combat, on the addon's own buttons. Every client
  API is checked with type(...) == "function" first, every handler runs in pcall (the last error
  is kept for /bbuff status), and a secret value is never compared or tested: it is treated as no
  value.
]]

local _G = _G
local ADDON_NAME = ... or "BetterBuffsForever"
local PREFIX = "|cff33ff99BetterBuffsForever|r: "
local DOT = " \194\183 "

local VERSION = "1.0"

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
local MIN_GOTW, MIN_REBIRTH, MAX_THRESHOLD = 10, 2, 200

local MAX_AURAS = 40
local THROTTLE = 0.25         -- at most 4 updates a second
local GROUP_REFRESH = 1.5     -- seconds between refreshes while in a group (range, death, ...)
local OUT_OF_RANGE = 0.45     -- alpha of a row whose member is out of range
local ROW_H, HEADER_H, PAD, MIN_W = 18, 16, 6, 190
local DEFAULT_Y = -120        -- below the top centre
local FLAT = "Interface\\Buttons\\WHITE8x8"

local SAVED_KEYS = { enabled = true, motw = true, thorns = true, thornsTank = true, group = true,
    sound = true, locked = true, pos = true, reagents = true, gotwMin = true, rebirthMin = true }
local DEFAULTS = { enabled = true, motw = true, thorns = true, thornsTank = true, group = true,
    sound = false, locked = true, reagents = true }

local db                  -- BetterBuffsForeverDB, bound at ADDON_LOADED (never at file scope)
local charDb              -- BetterBuffsForeverCharDB: the tank set by hand, { guid, name }
local isDruid             -- nil until known, then true or false
local holder              -- shown out of combat only (state driver); holds the box
local box                 -- the visible box, shown only while something is missing
local rows = {}           -- the secure row buttons, created out of combat only
local headers = {}        -- the two section header font strings
local reagentLines = {}   -- plain font strings for the low-reagent lines (not clickable)
local hint                -- "drag to move" line while unlocked
local driverOn            -- the visibility state driver is registered

local spells = {}         -- motw/gotw/thorns/rebirth = { value, knownID, text, label, icon, names, ids }
local spellsPending       -- the spells changed in combat; resolve at PLAYER_REGEN_ENABLED
local dirty = true        -- something changed since the last update
local lastUpdate = 0
local testMode            -- /bbuff test: fake rows
local lastError
local lastScan = { units = 0, motw = 0, thorns = 0, unknown = 0, tanks = "none", tankSource = "none" }
local prevMissing = {}    -- keys missing at the last update, for the sound
local missingCount = 0

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end

local function Fail(where, err)
    lastError = where .. ": " .. tostring(err)
end

local function InCombat()
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() and true or false
end

-- Where the client hides a value it hands back a secret, which can be neither compared nor
-- tested. Those are treated as no value at all, and checked before anything else.
local issecretvalue = _G.issecretvalue
local function Secret(v)
    return issecretvalue and issecretvalue(v) and true or false
end

local function Num(v)
    if Secret(v) or type(v) ~= "number" or v ~= v then return nil end
    return v
end

local function Str(v)
    if Secret(v) or type(v) ~= "string" or v == "" then return nil end
    return v
end

-- true / false, or nil when the value is secret.
local function Bool(v)
    if Secret(v) then return nil end
    return v and true or false
end

local function Now()
    return type(_G.GetTime) == "function" and (Num(_G.GetTime()) or 0) or 0
end

-- Calls a global API by name in pcall; nil when it is missing or errors.
local function Call(name, ...)
    local f = _G[name]
    if type(f) ~= "function" then return nil end
    local ok, a, b, c = pcall(f, ...)
    if not ok then return nil end
    return a, b, c
end

local function On(key)
    if not db then return DEFAULTS[key] end
    return db[key] ~= false
end

local function Active()
    return db ~= nil and isDruid == true and On("enabled")
end

local function UseKeyDown()
    local c = _G.C_CVar
    local get = (type(c) == "table" and type(c.GetCVarBool) == "function" and c.GetCVarBool)
        or (type(_G.GetCVarBool) == "function" and _G.GetCVarBool)
    if not get then return false end
    local ok, v = pcall(get, "ActionButtonUseKeyDown")
    if not ok or Secret(v) then return false end
    return v and true or false
end

-- ---------------------------------------------------------------------------
-- Class and spells
-- ---------------------------------------------------------------------------

local function CheckClass()
    local _, classFile, classID = Call("UnitClass", "player")
    classFile, classID = Str(classFile), Num(classID)
    if classFile then
        isDruid = classFile == "DRUID"
    elseif classID then
        isDruid = classID == 11
    end
end

local function SpellName(spell)
    local c = _G.C_Spell
    if type(c) == "table" and type(c.GetSpellInfo) == "function" then
        local ok, info = pcall(c.GetSpellInfo, spell)
        if ok and type(info) == "table" then
            local name = Str(info.name)
            if name then return name, Num(info.spellID), info.iconID end
        end
    end
    if type(_G.GetSpellInfo) == "function" then
        local ok, name, _, icon, _, _, _, id = pcall(_G.GetSpellInfo, spell)
        if ok and Str(name) then return name, Num(id), icon end
    end
    return nil
end

local function Known(id)
    local checks = {}
    local sb = _G.C_SpellBook
    if type(sb) == "table" and type(sb.IsSpellKnown) == "function" then checks[#checks + 1] = sb.IsSpellKnown end
    if type(_G.IsPlayerSpell) == "function" then checks[#checks + 1] = _G.IsPlayerSpell end
    if type(_G.IsSpellKnown) == "function" then checks[#checks + 1] = _G.IsSpellKnown end
    for _, f in ipairs(checks) do
        local ok, known = pcall(f, id)
        if ok and not Secret(known) and known then return true end
    end
    return false
end

-- { value = name or ID or nil, text, label, icon, names = {localized names}, ids = {set} }
local function ResolveSpell(ids, fallbackLabel)
    local s = { names = {}, ids = {} }
    for _, id in ipairs(ids) do
        s.ids[id] = true
        local name, _, icon = SpellName(id)
        if name then
            s.names[name] = true
            s.label = s.label or name
            s.icon = s.icon or icon
        end
    end
    s.label = s.label or fallbackLabel
    for _, id in ipairs(ids) do
        if Known(id) then
            s.knownID = id
            local name = SpellName(id)
            if name then
                s.value, s.text = name, string.format("%s (known: spell %d, cast by name)", name, id)
            else
                s.value, s.text = id, string.format("spell %d (known, cast by ID: no name on this client)", id)
            end
            return s
        end
    end
    -- No rank reported as known: the localized name finds it only when it is in the spellbook.
    local name, id = SpellName(s.label)
    if name and id and s.ids[id] then
        s.knownID = id
        s.value, s.text = name, string.format("%s (spellbook by name: spell %d)", name, id)
        return s
    end
    s.text = s.label .. " - not known by this character"
    return s
end

local function ResolveSpells()
    if InCombat() then
        spellsPending = true
        return
    end
    spellsPending = false
    spells.motw = ResolveSpell(MOTW_IDS, "Mark of the Wild")
    spells.gotw = ResolveSpell(GOTW_IDS, "Gift of the Wild")
    spells.thorns = ResolveSpell(THORNS_IDS, "Thorns")
    spells.rebirth = ResolveSpell(REBIRTH_IDS, "Rebirth")
    dirty = true
end

-- ---------------------------------------------------------------------------
-- Aura scan
-- ---------------------------------------------------------------------------

local function IndexIsSecret(unit, i)
    local S = _G.C_Secrets
    if type(S) ~= "table" or type(S.ShouldUnitAuraIndexBeSecret) ~= "function" then return false end
    local ok, secret = pcall(S.ShouldUnitAuraIndexBeSecret, unit, i, "HELPFUL")
    return ok and not Secret(secret) and secret == true
end

-- One buff: its spell ID and name, nil at the end of the list, or false when it cannot be read.
local function ReadBuff(unit, i)
    if IndexIsSecret(unit, i) then return false end
    local C = _G.C_UnitAuras
    if type(C) == "table" and type(C.GetAuraDataByIndex) == "function" then
        local ok, a = pcall(C.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok or Secret(a) then return false end
        if type(a) ~= "table" then return nil end
        local ok2, id, name = pcall(function() return a.spellId, a.name end)
        if not ok2 then return false end
        return { id = Num(id), name = Str(name), hidden = Secret(id) }
    end
    local f = (type(_G.UnitBuff) == "function" and _G.UnitBuff)
    if f then
        local ok, name, _, _, _, _, _, _, _, _, id = pcall(f, unit, i)
        if not ok then return false end
        if Secret(name) then return { id = Num(id), hidden = true } end
        if not Str(name) then return nil end
        return { id = Num(id), name = Str(name), hidden = Secret(id) }
    end
    if type(_G.UnitAura) == "function" then
        local ok, name, _, _, _, _, _, _, _, _, id = pcall(_G.UnitAura, unit, i, "HELPFUL")
        if not ok then return false end
        if Secret(name) then return { id = Num(id), hidden = true } end
        if not Str(name) then return nil end
        return { id = Num(id), name = Str(name), hidden = Secret(id) }
    end
    return false
end

local function Matches(b, s)
    if not s then return false end
    if b.id and s.ids[b.id] then return true end
    return b.name ~= nil and s.names[b.name] == true
end

-- hasMotw (MotW or GotW), hasThorns: true / false, or nil when unknown (secret, refused).
local function ScanUnit(unit)
    local motw, thorns, unknown = false, false, false
    for i = 1, MAX_AURAS do
        local b = ReadBuff(unit, i)
        if b == false then unknown = true break end
        if b == nil then break end
        if Matches(b, spells.motw) or Matches(b, spells.gotw) then motw = true end
        if Matches(b, spells.thorns) then thorns = true end
        -- A buff we cannot identify could be the one we look for.
        if not b.id and not b.name then unknown = true end
    end
    if unknown then
        return motw or nil, thorns or nil
    end
    return motw, thorns
end

-- ---------------------------------------------------------------------------
-- Group and tank
-- ---------------------------------------------------------------------------

local function InRaid() return Bool(Call("IsInRaid")) == true end
local function InGroup() return Bool(Call("IsInGroup")) == true end

local function SameUnit(a, b)
    return Bool(Call("UnitIsUnit", a, b)) == true
end

-- Every group unit token (the player first), each member once.
local function GroupUnits()
    local list = { "player" }
    if not InGroup() then return list end
    if InRaid() then
        local n = Num(Call("GetNumGroupMembers")) or 40
        for i = 1, math.min(n, 40) do
            local u = "raid" .. i
            if Bool(Call("UnitExists", u)) and not SameUnit(u, "player") then list[#list + 1] = u end
        end
    else
        for i = 1, 4 do
            local u = "party" .. i
            if Bool(Call("UnitExists", u)) then list[#list + 1] = u end
        end
    end
    return list
end

-- Worth warning about: alive, online and visible. nil when the client hides an answer.
local function Eligible(unit)
    if unit == "player" then
        return Bool(Call("UnitIsDeadOrGhost", "player")) == false
    end
    local dead = Bool(Call("UnitIsDeadOrGhost", unit))
    local online = Bool(Call("UnitIsConnected", unit))
    local visible = Bool(Call("UnitIsVisible", unit))
    return dead == false and online == true and visible == true
end

-- true in range, false out of range, nil when unknown. A secret answer comes back as
-- nil, true, <the secret>, for SetAlphaFromBoolean; it is never tested here.
local function InSpellRange(spell, unit)
    if unit == "player" then return true end
    local c = _G.C_Spell
    if spell and type(c) == "table" and type(c.IsSpellInRange) == "function" then
        local ok, v = pcall(c.IsSpellInRange, spell, unit)
        if ok and Secret(v) then return nil, true, v end
        if ok and v ~= nil then return v and true or false end
    end
    if type(spell) == "string" and type(_G.IsSpellInRange) == "function" then
        local ok, v = pcall(_G.IsSpellInRange, spell, unit)
        if ok and Secret(v) then return nil, true, v end
        if ok and Num(v) then return v == 1 end
    end
    if type(_G.UnitInRange) == "function" then
        local ok, v, checked = pcall(_G.UnitInRange, unit)
        if ok and Secret(v) then return nil, true, v end
        if ok and Bool(checked) == true then return Bool(v) end
    end
    return nil
end

local function UnitGUIDPlain(unit) return Str(Call("UnitGUID", unit)) end

-- The tank units and where they came from: "role", "main tank", "set by hand" or "none".
local function Tanks(units)
    local list = {}
    if type(_G.UnitGroupRolesAssigned) == "function" then
        for _, u in ipairs(units) do
            if Str(Call("UnitGroupRolesAssigned", u)) == "TANK" then list[#list + 1] = u end
        end
        if #list > 0 then return list, "role" end
    end
    if InRaid() and type(_G.GetPartyAssignment) == "function" then
        for _, u in ipairs(units) do
            if Bool(Call("GetPartyAssignment", "MAINTANK", u)) then list[#list + 1] = u end
        end
        if #list > 0 then return list, "main tank" end
    end
    local t = charDb and charDb.tank
    if type(t) == "table" and t.guid and InGroup() then
        for _, u in ipairs(units) do
            if UnitGUIDPlain(u) == t.guid then return { u }, "set by hand" end
        end
        return list, "set by hand, not in your group"
    end
    return list, "none"
end

local function UnitLabel(unit)
    local name = Str(Call("UnitName", unit)) or unit
    local _, classFile = Call("UnitClass", unit)
    classFile = Str(classFile)
    local color
    local cc = _G.C_ClassColor
    if classFile and type(cc) == "table" and type(cc.GetClassColor) == "function" then
        local ok, c = pcall(cc.GetClassColor, classFile)
        if ok and type(c) == "table" and type(c.GenerateHexColor) == "function" then
            local ok2, hex = pcall(c.GenerateHexColor, c)
            if ok2 and Str(hex) then color = hex end
        end
    end
    if not color and classFile and type(_G.RAID_CLASS_COLORS) == "table" then
        local c = _G.RAID_CLASS_COLORS[classFile]
        if type(c) == "table" and Num(c.r) and Num(c.g) and Num(c.b) then
            color = string.format("ff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
        end
    end
    return color and ("|c" .. color .. name .. "|r") or name, name
end

-- ---------------------------------------------------------------------------
-- Reagents
-- ---------------------------------------------------------------------------

local function Threshold(key, default)
    local v = db and Num(db[key])
    return v or default
end

local function ItemName(itemID)
    local c = _G.C_Item
    if type(c) == "table" and type(c.GetItemNameByID) == "function" then
        local ok, name = pcall(c.GetItemNameByID, itemID)
        if ok and Str(name) then return name end
    end
    local name = Str(Call("GetItemInfo", itemID))
    return name or ITEM_NAMES[itemID] or ("item " .. itemID)
end

-- In the bags (bank not counted); nil when the client gives no count.
local function BagCount(itemID)
    local c = _G.C_Item
    if type(c) == "table" and type(c.GetItemCount) == "function" then
        local ok, n = pcall(c.GetItemCount, itemID, false)
        if ok and Num(n) then return n end
    end
    return Num(Call("GetItemCount", itemID, false))
end

-- One entry per reagent below its threshold: { item, name, count, min, spell }. Also returns
-- every reagent checked, for /bbuff status.
local function LowReagents()
    local low, checked = {}, {}
    for _, r in ipairs({ { "gotw", "gotwMin", MIN_GOTW }, { "rebirth", "rebirthMin", MIN_REBIRTH } }) do
        local s = spells[r[1]]
        local item = s and s.knownID and REAGENT_OF[s.knownID]
        if item then
            local count, min = BagCount(item), Threshold(r[2], r[3])
            local e = { item = item, name = ItemName(item), count = count, min = min, spell = s.label }
            checked[#checked + 1] = e
            if count and count < min then low[#low + 1] = e end
        end
    end
    return low, checked
end

-- ---------------------------------------------------------------------------
-- The box
-- ---------------------------------------------------------------------------

local function SavePosition()
    if not holder or not db then return end
    local ui = _G.UIParent
    local left, right, top = holder:GetLeft(), holder:GetRight(), holder:GetTop()
    local uw, uh = ui:GetWidth(), ui:GetHeight()
    if not Num(left) or not Num(right) or not Num(top) or not Num(uw) or not Num(uh) then return end
    db.pos = { x = math.floor((left + right) / 2 - uw / 2 + 0.5), y = math.floor(top - uh + 0.5) }
end

local function ApplyPosition()
    if not holder or InCombat() then return end
    local p = db and db.pos
    local x = type(p) == "table" and Num(p.x) or 0
    local y = type(p) == "table" and Num(p.y) or DEFAULT_Y
    holder:ClearAllPoints()
    holder:SetPoint("TOP", _G.UIParent, "TOP", x, y)
end

local function AltDown()
    return Bool(Call("IsAltKeyDown")) == true
end

local function CreateBox()
    if holder then return end
    holder = CreateFrame("Frame", "BetterBuffsForeverHolder", _G.UIParent)
    holder:SetSize(MIN_W, 40)
    holder:SetFrameStrata("MEDIUM")
    holder:SetMovable(true)
    holder:SetClampedToScreen(true)

    box = CreateFrame("Frame", "BetterBuffsForeverBox", holder, "BackdropTemplate")
    box:SetAllPoints(holder)
    if type(box.SetBackdrop) == "function" then
        box:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        box:SetBackdropColor(0.07, 0.08, 0.10, 0.90)
        box:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    end
    box:EnableMouse(true)
    box:RegisterForDrag("LeftButton")
    box:SetScript("OnDragStart", function()
        if InCombat() then return end
        if db and db.locked ~= false and not AltDown() then return end
        holder:StartMoving()
    end)
    box:SetScript("OnDragStop", function()
        holder:StopMovingOrSizing()
        if type(holder.SetUserPlaced) == "function" then pcall(holder.SetUserPlaced, holder, false) end
        local ok, err = pcall(function()
            SavePosition()
            ApplyPosition()
        end)
        if not ok then Fail("saving the position", err) end
    end)
    box:Hide()

    for i = 1, 2 do
        local fs = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetJustifyH("LEFT")
        headers[i] = fs
    end
    hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetJustifyH("LEFT")

    -- Hidden the moment combat starts, by secure code, and shown again after it.
    if type(_G.RegisterStateDriver) == "function" then
        driverOn = pcall(_G.RegisterStateDriver, holder, "visibility", "[combat] hide; show")
    end
    ApplyPosition()
end

local function RowTooltip(self)
    local tip = _G.GameTooltip
    if not tip or not self.entry then return end
    local e = self.entry
    tip:SetOwner(self, "ANCHOR_RIGHT")
    tip:AddLine(e.plainName or "?")
    if e.fake then
        tip:AddLine("Test row: clicking does nothing.", 0.7, 0.7, 0.7)
    else
        tip:AddLine("Left-click: " .. tostring(e.spellLabel) .. " on " .. tostring(e.plainName), 1, 1, 1)
        if e.spell2Label then
            tip:AddLine("Right-click: " .. e.spell2Label, 1, 1, 1)
        end
        if e.far then tip:AddLine("Out of range", 1, 0.3, 0.3) end
    end
    tip:Show()
end

local function NewRow(i)
    local r = CreateFrame("Button", "BetterBuffsForeverRow" .. i, box, "SecureActionButtonTemplate")
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
    r:HookScript("OnEnter", function(self) pcall(RowTooltip, self) end)
    r:HookScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    r:Hide()
    rows[i] = r
    return r
end

-- Out of combat only: sets every row's attributes and lays the box out.
local function Layout(entries, reagents)
    if not box or InCombat() then return end
    reagents = reagents or {}
    local direction = UseKeyDown() and "AnyDown" or "AnyUp"
    local sections = {
        { key = "motw", title = "Missing " .. ((spells.motw and spells.motw.label) or "Mark of the Wild") .. ":" },
        { key = "thorns", title = "Missing " .. ((spells.thorns and spells.thorns.label) or "Thorns") .. ":" },
    }
    local y, n, w = -PAD, 0, MIN_W
    for si, sec in ipairs(sections) do
        local header = headers[si]
        local any = false
        for _, e in ipairs(entries) do
            if e.section == sec.key then any = true break end
        end
        if any then
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", box, "TOPLEFT", PAD + 2, y)
            header:SetText(sec.title)
            header:Show()
            w = math.max(w, (Num(header:GetStringWidth()) or 0) + 2 * PAD + 4)
            y = y - HEADER_H
            for _, e in ipairs(entries) do
                if e.section == sec.key then
                    n = n + 1
                    local r = rows[n] or NewRow(n)
                    r.entry = e
                    r:RegisterForClicks(direction)
                    if e.fake then
                        r:SetAttribute("type", nil)
                        r:SetAttribute("spell", nil)
                        r:SetAttribute("unit", nil)
                    else
                        r:SetAttribute("type", "spell")
                        r:SetAttribute("spell", e.spell)
                        r:SetAttribute("unit", e.unit)
                    end
                    if e.spell2 and not e.fake then
                        r:SetAttribute("type2", "spell")
                        r:SetAttribute("spell2", e.spell2)
                    else
                        r:SetAttribute("type2", nil)
                        r:SetAttribute("spell2", nil)
                    end
                    r.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                    r.text:SetText(e.text)
                    r:ClearAllPoints()
                    r:SetPoint("TOPLEFT", box, "TOPLEFT", PAD, y)
                    r:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PAD, y)
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
            end
            y = y - 4
        else
            header:Hide()
        end
    end
    for i = n + 1, #rows do
        rows[i].entry = nil
        rows[i]:Hide()
    end

    for i, r in ipairs(reagents) do
        local fs = reagentLines[i]
        if not fs then
            fs = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetJustifyH("LEFT")
            reagentLines[i] = fs
        end
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", box, "TOPLEFT", PAD + 2, y - 1)
        fs:SetText("Low reagents: |cffffffff" .. r.name .. "|r |cffff5555" .. tostring(r.count) .. "|r/" .. r.min)
        fs:Show()
        w = math.max(w, (Num(fs:GetStringWidth()) or 0) + 2 * PAD + 4)
        y = y - ROW_H
    end
    for i = #reagents + 1, #reagentLines do reagentLines[i]:Hide() end
    if #reagents > 0 then y = y - 4 end

    local unlocked = db and db.locked == false
    if unlocked or testMode then
        local parts = {}
        if n == 0 and #reagents == 0 then parts[#parts + 1] = "BetterBuffsForever: nothing missing." end
        if testMode then parts[#parts + 1] = "Test rows (/bbuff test hides them)." end
        if unlocked then parts[#parts + 1] = "Unlocked: drag to move, /bbuff lock." end
        hint:ClearAllPoints()
        hint:SetPoint("TOPLEFT", box, "TOPLEFT", PAD + 2, y - 2)
        hint:SetText(table.concat(parts, "\n"))
        hint:Show()
        w = math.max(w, (Num(hint:GetStringWidth()) or 0) + 2 * PAD + 4)
        y = y - (Num(hint:GetStringHeight()) or 12) - 4
    else
        hint:Hide()
    end

    holder:SetSize(math.ceil(w), math.ceil(-y + PAD - 4))
    if n > 0 or #reagents > 0 or unlocked or testMode then box:Show() else box:Hide() end
end

-- ---------------------------------------------------------------------------
-- The check
-- ---------------------------------------------------------------------------

local function MakeEntry(section, unit, spell, extra)
    local text, plain = UnitLabel(unit)
    local e = { section = section, unit = unit, spell = spell.value, spellLabel = spell.label,
        icon = spell.icon, plainName = plain }
    local suffix = {}
    if unit == "player" then suffix[#suffix + 1] = "you" end
    if extra then suffix[#suffix + 1] = extra end
    local inRange, isSecret, secretRange = InSpellRange(spell.value, unit)
    if inRange == false then
        e.far = true
        suffix[#suffix + 1] = "out of range"
    elseif isSecret then
        e.hasRangeSecret, e.rangeSecret = true, secretRange
    end
    e.text = text .. (#suffix > 0 and ("|cffaaaaaa (" .. table.concat(suffix, ", ") .. ")|r") or "")
    return e
end

local function FakeEntries()
    local list = {}
    local motw, thorns = spells.motw or { label = "Mark of the Wild" }, spells.thorns or { label = "Thorns" }
    local fakes = {
        { "motw", "|cffc79c6eTankyboy|r", motw }, { "motw", "|cfff58cbaHealbot|r|cffaaaaaa (out of range)|r", motw, true },
        { "motw", "|cff69ccf0Frostmage|r", motw }, { "thorns", "|cffc79c6eTankyboy|r|cffaaaaaa (tank)|r", thorns },
    }
    for _, f in ipairs(fakes) do
        list[#list + 1] = { section = f[1], text = f[2], icon = f[3].icon, spellLabel = f[3].label,
            plainName = (f[2]:match("|c%x%x%x%x%x%x%x%x(.-)|r")), far = f[4], fake = true }
    end
    return list
end

local function FakeReagents()
    return { { name = ITEM_NAMES[17026], count = 3, min = Threshold("gotwMin", MIN_GOTW) } }
end

local function PlayMissingSound()
    local kit = type(_G.SOUNDKIT) == "table" and Num(_G.SOUNDKIT.TELL_MESSAGE) or 3081
    if type(_G.PlaySound) == "function" then pcall(_G.PlaySound, kit, "Master") end
end

local function Update()
    lastUpdate = Now()
    dirty = false
    if not holder or InCombat() then return end
    if not Active() then
        missingCount = 0
        prevMissing = {}
        Layout(testMode and FakeEntries() or {}, testMode and FakeReagents() or {})
        return
    end
    if not spells.motw then ResolveSpells() end

    local entries, missing = {}, {}
    local units = (On("group") or On("thornsTank")) and GroupUnits() or { "player" }
    local stats = { units = 0, motw = 0, thorns = 0, unknown = 0 }
    local motw, thorns = spells.motw, spells.thorns
    local checkMotw = On("motw") and motw and motw.value ~= nil
    local checkThorns = (On("thorns") or On("thornsTank")) and thorns and thorns.value ~= nil

    -- The tanks, for the Thorns check and the "(tank)" mark.
    local tankSet, tankList, tankSource = {}, {}, "none"
    if InGroup() then
        tankList, tankSource = Tanks(units)
        for _, u in ipairs(tankList) do tankSet[u] = true end
    end
    local names = {}
    for _, u in ipairs(tankList) do names[#names + 1] = select(2, UnitLabel(u)) end
    stats.tanks = #names > 0 and table.concat(names, ", ") or "none"
    stats.tankSource = tankSource

    local scanned = {}
    for _, u in ipairs(units) do
        local listMotw = u == "player" or On("group")
        local wantThorns = (u == "player" and On("thorns")) or (tankSet[u] and On("thornsTank"))
        if (checkMotw and listMotw) or (checkThorns and wantThorns) then
            local ok, eligible = pcall(Eligible, u)
            if ok and eligible then
                stats.units = stats.units + 1
                local ok2, hasM, hasT = pcall(ScanUnit, u)
                if not ok2 then hasM, hasT = nil, nil end
                if hasM == nil or hasT == nil then stats.unknown = stats.unknown + 1 end
                scanned[u] = { hasM, hasT }
                local guid = UnitGUIDPlain(u) or u
                if checkMotw and listMotw and hasM == false then
                    local spell2 = InGroup() and spells.gotw and spells.gotw.value or nil
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
    local reagents = {}
    if On("reagents") then
        local ok, low = pcall(LowReagents)
        if ok then reagents = low else Fail("reagents", low) end
    end
    for _, r in ipairs(reagents) do missing["reagent:" .. r.item] = true end
    stats.reagents = #reagents
    lastScan = stats

    local new = false
    for k in pairs(missing) do
        if not prevMissing[k] then new = true break end
    end
    prevMissing = missing
    missingCount = #entries + #reagents
    if new and On("sound") then PlayMissingSound() end

    if testMode then
        for _, e in ipairs(FakeEntries()) do entries[#entries + 1] = e end
        if #reagents == 0 then reagents = FakeReagents() end
    end
    Layout(entries, reagents)
end

local function SafeUpdate()
    local ok, err = pcall(Update)
    if not ok then Fail("update", err) end
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local LABELS = {
    enabled = "BetterBuffsForever",
    motw = "Mark of the Wild check",
    thorns = "Thorns on you",
    thornsTank = "Thorns on the tank",
    group = "List group members",
    sound = "Sound when something goes missing",
    reagents = "Low reagent warning",
}

local function SetThreshold(key, v, what)
    db[key] = math.max(0, math.min(MAX_THRESHOLD, math.floor(v + 0.5)))
    dirty = true
    SafeUpdate()
    Print(what .. " reagent warning below " .. db[key] .. ".")
end

local function Set(key, on, quiet)
    db[key] = on and true or false
    dirty = true
    SafeUpdate()
    if not quiet then Print(LABELS[key] .. ": " .. (on and "on" or "off") .. ".") end
end

local function SetLocked(locked, quiet)
    db.locked = locked and true or false
    SafeUpdate()
    if not quiet then
        Print(locked and "box locked (Alt + drag still moves it)." or "box unlocked: drag it to move, /bbuff lock when done.")
    end
end

local function ResetPosition()
    db.pos = nil
    if InCombat() then
        Print("the box moves back after combat.")
        dirty = true
        return
    end
    ApplyPosition()
    Print("box back at the top centre.")
end

local function TankText()
    local t = charDb and charDb.tank
    if type(t) == "table" and t.name then return t.name end
    return nil
end

local function SetTank()
    if not InGroup() then
        Print("you are not in a group.")
        return
    end
    if not Bool(Call("UnitExists", "target")) then
        Print("target a group member first, then /bbuff tank.")
        return
    end
    local member
    for _, u in ipairs(GroupUnits()) do
        if SameUnit(u, "target") then member = u break end
    end
    if not member then
        Print("your target is not in your group.")
        return
    end
    local guid = UnitGUIDPlain("target")
    if not guid then
        Print("the client hides your target's identity; try again out of combat.")
        return
    end
    local _, name = UnitLabel("target")
    charDb.tank = { guid = guid, name = name }
    dirty = true
    SafeUpdate()
    Print("tank set by hand: " .. name .. ". It is used only when no member has the tank role or is a raid main tank.")
end

local function ClearTank(quiet)
    charDb.tank = nil
    dirty = true
    SafeUpdate()
    if not quiet then Print("tank set by hand cleared.") end
end

local function SetTest(on)
    testMode = on and true or false
    if InCombat() then
        Print("the box is hidden in combat; the test rows show after it.")
        dirty = true
        return
    end
    SafeUpdate()
    Print(testMode and "test rows shown (they cast nothing). /bbuff test again hides them." or "test rows hidden.")
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function YesNo(v) return v and "yes" or "no" end
local function OnOff(v) return v and "on" or "off" end

local function PrintHelp()
    Print("a druid's buff check: who lacks Mark of the Wild, and whether you or your tank lack Thorns. Click a name to buff it.")
    Print("/bbuff on | off - switch it on or off")
    Print("/bbuff motw [on|off] - the Mark of the Wild check (Gift of the Wild counts)")
    Print("/bbuff thorns [on|off] - warn when you lack Thorns")
    Print("/bbuff tank [on|off] - warn when the tank lacks Thorns; /bbuff tank set - your target is the tank; /bbuff tank clear")
    Print("/bbuff group [on|off] - list group members (off: only you)")
    Print("/bbuff sound [on|off] - a short sound when something goes missing")
    Print(string.format("/bbuff reagents [on|off] - warn on low reagents; /bbuff reagents gotw <n> (now %d), /bbuff reagents rebirth <n> (now %d)",
        Threshold("gotwMin", MIN_GOTW), Threshold("rebirthMin", MIN_REBIRTH)))
    Print("/bbuff unlock | lock | reset - move the box (Alt + drag works when locked), or put it back at the top centre")
    Print("/bbuff test - show the box with test rows; /bbuff status - the current state")
end

local function SpellLine(key)
    local s = spells[key]
    return s and s.text or "not resolved yet"
end

local function PrintStatus()
    Print("version " .. VERSION)
    if isDruid == false then
        Print("not a druid: the addon is idle on this character.")
    elseif isDruid == nil then
        Print("class not known yet.")
    end
    Print("enabled: " .. YesNo(On("enabled")) .. "   motw: " .. OnOff(On("motw")) .. "   thorns: " .. OnOff(On("thorns"))
        .. "   tank: " .. OnOff(On("thornsTank")) .. "   group: " .. OnOff(On("group")) .. "   sound: " .. OnOff(On("sound"))
        .. "   reagents: " .. OnOff(On("reagents")))
    Print("Mark of the Wild: " .. SpellLine("motw") .. (spellsPending and " (update waits for combat to end)" or ""))
    Print("Gift of the Wild: " .. SpellLine("gotw"))
    Print("Thorns: " .. SpellLine("thorns"))
    Print("Rebirth: " .. SpellLine("rebirth"))
    local okR, _, checked = pcall(LowReagents)
    local parts = {}
    if okR and type(checked) == "table" then
        for _, r in ipairs(checked) do
            parts[#parts + 1] = string.format("%s %s/%d (%s)", r.name, r.count and tostring(r.count) or "?", r.min, tostring(r.spell))
        end
    end
    Print("reagents: " .. OnOff(On("reagents")) .. "   " .. (#parts > 0 and table.concat(parts, ", ")
        or "nothing to check (Gift of the Wild and Rebirth not known)"))
    Print("group: " .. (InRaid() and "raid" or InGroup() and "party" or "solo")
        .. "   tank: " .. tostring(lastScan.tanks) .. " (" .. tostring(lastScan.tankSource) .. ")"
        .. "   set by hand: " .. (TankText() or "none"))
    Print(string.format("last check: %d members checked, %d lack Mark of the Wild, %d lack Thorns, %d unknown (auras secret or refused)",
        lastScan.units or 0, lastScan.motw or 0, lastScan.thorns or 0, lastScan.unknown or 0))
    local p = db and db.pos
    Print("box: " .. (InCombat() and "hidden (combat)" or (box and box:IsShown()) and "shown" or "hidden")
        .. "   " .. ((db and db.locked == false) and "unlocked" or "locked")
        .. "   position: " .. (type(p) == "table" and string.format("%d, %d", p.x or 0, p.y or 0) or "default")
        .. "   combat hide: " .. (driverOn and "state driver" or "PLAYER_REGEN_DISABLED")
        .. (testMode and "   test rows on" or ""))
    local C, S = _G.C_UnitAuras, _G.C_Secrets
    Print("aura API: GetAuraDataByIndex " .. YesNo(type(C) == "table" and type(C.GetAuraDataByIndex) == "function")
        .. "   ShouldUnitAuraIndexBeSecret " .. YesNo(type(S) == "table" and type(S.ShouldUnitAuraIndexBeSecret) == "function")
        .. "   UnitBuff " .. YesNo(type(_G.UnitBuff) == "function")
        .. "   roles " .. YesNo(type(_G.UnitGroupRolesAssigned) == "function")
        .. "   main tank " .. YesNo(type(_G.GetPartyAssignment) == "function"))
    Print("last error: " .. (lastError or "none"))
end

-- "on" / "off" / "" (toggle) to a boolean; nil for anything else.
local function Toggle(arg, current)
    if arg == "on" then return true end
    if arg == "off" then return false end
    if arg == "" then return not current end
    return nil
end

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd, arg = cmd or "", arg or ""
    local key = (cmd == "motw" and "motw") or (cmd == "thorns" and "thorns") or (cmd == "group" and "group")
        or (cmd == "sound" and "sound") or nil
    if cmd == "on" or cmd == "off" then
        Set("enabled", cmd == "on")
        if cmd == "on" and isDruid == false then Print("not a druid: it stays idle on this character.") end
    elseif key then
        local v = Toggle(arg, On(key))
        if v == nil then Print("/bbuff " .. cmd .. " [on|off]") else Set(key, v) end
    elseif cmd == "reagents" then
        local which, n = arg:match("^(%a+)%s*(.*)$")
        local v = tonumber(n or "")
        if (which == "gotw" or which == "rebirth") and v and v == v then
            SetThreshold(which == "gotw" and "gotwMin" or "rebirthMin", v,
                which == "gotw" and "Gift of the Wild" or "Rebirth")
        else
            local t = Toggle(arg, On("reagents"))
            if t == nil then
                Print("/bbuff reagents [on|off], /bbuff reagents gotw <n>, /bbuff reagents rebirth <n>")
            else
                Set("reagents", t)
            end
        end
    elseif cmd == "tank" then
        if arg == "" or arg == "set" then
            SetTank()
        elseif arg == "clear" then
            ClearTank()
        elseif arg == "on" or arg == "off" then
            Set("thornsTank", arg == "on")
        else
            Print("/bbuff tank (your target is the tank), /bbuff tank clear, /bbuff tank on|off")
        end
    elseif cmd == "unlock" then
        SetLocked(false)
    elseif cmd == "lock" then
        SetLocked(true)
    elseif cmd == "reset" then
        ResetPosition()
    elseif cmd == "test" then
        SetTest(not testMode)
    elseif cmd == "status" then
        PrintStatus()
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterBuffsForeverAPI
--
-- For BetterGaarForever, the optional hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterBuffsForeverDB (the tank in
-- BetterBuffsForeverCharDB) and change only through the same functions /bbuff uses, so the addon
-- behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "on · 2 missing" or "idle (not a druid)"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func },
--                        { text, radio = true, checked, func }, { text, submenu } and
--                        { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    if isDruid == false then return "idle (not a druid)" end
    if not On("enabled") then return "off" end
    if InCombat() then return "on" .. DOT .. "hidden in combat" end
    return "on" .. DOT .. (missingCount > 0 and (missingCount .. " missing") or "all buffed")
        .. ((lastScan.unknown or 0) > 0 and (DOT .. lastScan.unknown .. " unknown") or "")
end

local function MenuEntries()
    if not db then return {} end
    local function check(key)
        return { text = LABELS[key], checkbox = true,
            checked = function() return On(key) end,
            func = function() Set(key, not On(key)) end }
    end
    local tank = TankText()
    local function choices(key, default, values, what)
        local sub = {}
        for _, v in ipairs(values) do
            sub[#sub + 1] = { text = tostring(v) .. (v == default and " (default)" or ""), radio = true,
                checked = function() return Threshold(key, default) == v end,
                func = function() SetThreshold(key, v, what) end }
        end
        return sub
    end
    local list = {
        { text = "Enabled", checkbox = true,
          checked = function() return On("enabled") end,
          func = function() Set("enabled", not On("enabled")) end },
        check("motw"),
        check("thorns"),
        check("thornsTank"),
        check("group"),
        check("sound"),
        check("reagents"),
        { text = "Gift of the Wild reagent warning below",
          submenu = choices("gotwMin", MIN_GOTW, { 0, 5, 10, 20, 40 }, "Gift of the Wild") },
        { text = "Rebirth reagent warning below",
          submenu = choices("rebirthMin", MIN_REBIRTH, { 0, 1, 2, 3, 5 }, "Rebirth") },
        { divider = true },
        { text = "Set tank: current target", func = SetTank },
    }
    if tank then
        list[#list + 1] = { text = "Clear tank (" .. tank .. ")", func = function() ClearTank() end }
    end
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Lock box", checkbox = true,
        checked = function() return db.locked ~= false end,
        func = function() SetLocked(db.locked == false) end }
    list[#list + 1] = { text = "Test box", checkbox = true,
        checked = function() return testMode and true or false end,
        func = function() SetTest(not testMode) end }
    list[#list + 1] = { text = "Reset position", func = ResetPosition }
    return list
end

-- Draws the entries into a MenuUtil description (root or submenu); every method is checked first.
local function RenderMenu(root, entries)
    if type(root) ~= "table" then return end
    for _, e in ipairs(entries) do
        if e.divider then
            if type(root.CreateDivider) == "function" then root:CreateDivider() end
        elseif e.submenu then
            if type(root.CreateButton) == "function" then
                local sub = root:CreateButton(e.text)
                RenderMenu(sub, e.submenu)
            end
        elseif e.radio and type(root.CreateRadio) == "function" then
            root:CreateRadio(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox and type(root.CreateCheckbox) == "function" then
            root:CreateCheckbox(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox or e.radio then
            -- A menu without checkboxes or radios: show the state in the label instead.
            local mark = e.radio and (e.checked() and "(o) " or "( ) ") or (e.checked() and "[x] " or "[ ] ")
            if type(root.CreateButton) == "function" then root:CreateButton(mark .. e.text, function() e.func() end) end
        elseif type(root.CreateButton) == "function" then
            root:CreateButton(e.text, function() e.func() end)
        end
    end
end

_G.BetterBuffsForeverAPI = {
    version = VERSION,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) RenderMenu(root, MenuEntries()) end,
    SetMinimapHidden = function() end,
}

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterBuffsForeverDB) ~= "table" then BetterBuffsForeverDB = {} end
    db = BetterBuffsForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if type(db[k]) ~= "boolean" then db[k] = v end
    end
    for _, k in ipairs({ "gotwMin", "rebirthMin" }) do
        local v = Num(tonumber(db[k]))
        db[k] = v and math.max(0, math.min(MAX_THRESHOLD, math.floor(v))) or nil
    end
    local p = db.pos
    if type(p) == "table" and Num(p.x) and Num(p.y) then
        db.pos = { x = p.x, y = p.y }
    else
        db.pos = nil
    end

    -- Per character: only the tank set by hand, { guid, name }.
    if type(BetterBuffsForeverCharDB) ~= "table" then BetterBuffsForeverCharDB = {} end
    charDb = BetterBuffsForeverCharDB
    for k in pairs(charDb) do
        if k ~= "tank" then charDb[k] = nil end
    end
    local t = charDb.tank
    if type(t) == "table" and Str(t.guid) then
        charDb.tank = { guid = t.guid, name = Str(t.name) or "?" }
    else
        charDb.tank = nil
    end
end

local GROUP_UNIT = { player = true }
for i = 1, 4 do GROUP_UNIT["party" .. i] = true end
for i = 1, 40 do GROUP_UNIT["raid" .. i] = true end

local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function()
    local ok, err = pcall(function()
        if InCombat() then return end
        local now = Now()
        if now - lastUpdate < THROTTLE then return end
        if dirty or (Active() and InGroup() and now - lastUpdate >= GROUP_REFRESH) then
            Update()
        end
    end)
    if not ok then Fail("OnUpdate", err) end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("UNIT_AURA")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
-- Not on every client; registering an event the client does not know raises an error.
pcall(events.RegisterEvent, events, "PLAYER_ROLES_ASSIGNED")
pcall(events.RegisterEvent, events, "UNIT_CONNECTION")
pcall(events.RegisterEvent, events, "LEARNED_SPELL_IN_TAB")
events:SetScript("OnEvent", function(_, event, arg1)
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then BindSavedVariables() end
            return
        end
        if event == "PLAYER_LOGIN" then
            CheckClass()
            CreateBox()
            ResolveSpells()
            ticker:Show()
        elseif event == "PLAYER_ENTERING_WORLD" then
            if isDruid == nil then CheckClass() end
            if not spells.motw then ResolveSpells() end
            ApplyPosition()
        elseif event == "PLAYER_REGEN_DISABLED" then
            -- Fallback for a client without state drivers: still allowed in this event.
            if holder and not driverOn then pcall(holder.Hide, holder) end
            return
        elseif event == "PLAYER_REGEN_ENABLED" then
            if holder and not driverOn then holder:Show() end
            if spellsPending then ResolveSpells() end
            ApplyPosition()
        elseif event == "UNIT_AURA" then
            if not Active() or Secret(arg1) or not GROUP_UNIT[arg1] then return end
        elseif event == "GROUP_ROSTER_UPDATE" or event == "UNIT_CONNECTION" or event == "PLAYER_ROLES_ASSIGNED"
            or event == "BAG_UPDATE_DELAYED" then
            if not Active() then return end
        elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
            if isDruid then ResolveSpells() end
        end
        dirty = true
    end)
    if not ok then Fail(event, err) end
end)

SLASH_BETTERBUFFSFOREVER1 = "/bbuff"
SLASH_BETTERBUFFSFOREVER2 = "/betterbuffsforever"
SlashCmdList.BETTERBUFFSFOREVER = OnSlash
