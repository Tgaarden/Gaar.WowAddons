--[[
  BetterBuffsForever - a buff check on WoW Forever for druids and paladins: who in your group
  lacks your buff, in a box at the top centre of the screen. Click a name to buff it.

  This file is the shared part; the class-specific parts are modules in their own files, loaded
  after this one (both TOCs list all three):

    Druid.lua    Mark of the Wild / Gift of the Wild, Thorns on you and the tank, and the Gift of
                 the Wild and Rebirth reagents.
    Paladin.lua  Blessings by class (with a fallback when another paladin's blessing is already
                 there), "No aura", Righteous Fury while you tank, and Symbol of Kings.

  A module registers itself in the addon namespace (ns.modules[classFile]) and gets everything
  else from here:

    * Only for a class with a module (Druid, Paladin). Any other class leaves the addon idle: no
      scans, no box; /bbuff status says so.
    * The tank is, in order: every member UnitGroupRolesAssigned() calls "TANK"; else, in a raid,
      every main tank (GetPartyAssignment("MAINTANK", unit)); else the tank you set by hand
      (/bbuff tank, your current target, per character); else there is no tank. You count too.
    * Only spells the character knows are checked.
    * A box at the top centre of the screen, shown only while something is missing: one section
      per thing missing ("Missing Mark of the Wild:", "Missing Blessing of Might:", ...), one row
      per member with a class-coloured name. Dead or ghost, offline and not-visible members
      (UnitIsVisible) are never warned about; out-of-range members are shown dimmed (still
      clickable, the cast just fails). A member whose auras cannot be read (secret) counts as
      unknown, never as missing.
    * Click to buff: every row is a SecureActionButtonTemplate button, type "spell", spell = the
      localized name (the highest rank you know), unit = that member's unit token. Left-click
      casts the row's spell; right-click casts the module's group version (Gift of the Wild, a
      Greater Blessing) when there is one, else what left-click does.
    * Combat: the box is hidden in combat. Aura data is secret then, secure attributes cannot
      change, and buffing mid-fight is not the point. A state driver ("[combat] hide; show")
      hides it the moment combat starts, PLAYER_REGEN_DISABLED as a fallback; nothing is scanned
      in combat, and the box is rebuilt at PLAYER_REGEN_ENABLED.
    * The box can be moved: drag it while unlocked (/bbuff unlock), or Alt + drag at any time.
      The position is saved account-wide. /bbuff reset puts it back at the top centre.
    * Updates are throttled to 4 a second (UNIT_AURA, GROUP_ROSTER_UPDATE, ...), plus a refresh
      every 1.5 s while in a group, for range, death and visibility, which have no cheap event.
    * Low reagents (on by default): a "Low reagents:" line in the same box when the bags hold
      fewer than a threshold of a reagent the module checks. Not clickable.
    * An optional short sound when something new goes missing (off by default).
    * /bbuff for help; the shared commands are on, off, group, sound, reagents, tank, unlock,
      lock, reset, test and status, and each module adds its own.
    * BetterBuffsForeverAPI, a small global table for BetterGaarForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The addon runs exactly the same
      without the hub; the API only exposes the settings the slash command already changes.

  Aura reads: C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL") (UnitBuff / UnitAura on an older
  client), one pcall per read, asking C_Secrets.ShouldUnitAuraIndexBeSecret first, like
  BetterFramesForever. A refused read, a secret aura or a secret spell ID with a secret name
  makes that member unknown for the check, and unknown is never warned about. Who cast a buff
  (isFromPlayerOrPlayerPet, else sourceUnit) is read too, for the paladin's blessings; a secret
  answer there is "not known", never "someone else".

  Taint: Blizzard code is only followed, never replaced; no Blizzard function or table is
  written. Attributes are only ever set out of combat, on the addon's own buttons. Every client
  API is checked with type(...) == "function" first, every handler runs in pcall (the last error
  is kept for /bbuff status), and a secret value is never compared or tested: it is treated as no
  value.
]]

local _G = _G
local ADDON_NAME, ns = ...
ADDON_NAME = ADDON_NAME or "BetterBuffsForever"
ns = ns or {}
local PREFIX = "|cff33ff99BetterBuffsForever|r: "
local DOT = " \194\183 "

local VERSION = "1.1"

local MAX_THRESHOLD = 200
local MAX_AURAS = 40
local THROTTLE = 0.25         -- at most 4 updates a second
local GROUP_REFRESH = 1.5     -- seconds between refreshes while in a group (range, death, ...)
local OUT_OF_RANGE = 0.45     -- alpha of a row whose member is out of range
local ROW_H, HEADER_H, PAD, MIN_W = 18, 16, 6, 190
local DEFAULT_Y = -120        -- below the top centre
local FLAT = "Interface\\Buttons\\WHITE8x8"

-- The shared settings; each module adds its own (module.options, module.thresholds,
-- module.savedKeys) at ADDON_LOADED, whatever the class, so one character never wipes
-- another class's settings from the account-wide table.
local SAVED_KEYS = { enabled = true, group = true, sound = true, locked = true, pos = true, reagents = true }
local DEFAULTS = { enabled = true, group = true, sound = false, locked = true, reagents = true }
local LABELS = {
    enabled = "BetterBuffsForever",
    group = "List group members",
    sound = "Sound when something goes missing",
    reagents = "Low reagent warning",
}

ns.modules = ns.modules or {}  -- classFile -> module, filled by Druid.lua and Paladin.lua
local MODULE_ORDER = { "DRUID", "PALADIN" }

local db                  -- BetterBuffsForeverDB, bound at ADDON_LOADED (never at file scope)
local charDb              -- BetterBuffsForeverCharDB: the tank set by hand, plus module keys
local module              -- nil until the class is known, then the class's module or false
local holder              -- shown out of combat only (state driver); holds the box
local box                 -- the visible box, shown only while something is missing
local rows = {}           -- the secure row buttons, created out of combat only
local headers = {}        -- the section header font strings
local reagentLines = {}   -- plain font strings for the low-reagent lines (not clickable)
local hint                -- "drag to move" line while unlocked
local driverOn            -- the visibility state driver is registered

local spellsPending       -- the spells changed in combat; resolve at PLAYER_REGEN_ENABLED
local dirty = true        -- something changed since the last update
local lastUpdate = 0
local testMode            -- /bbuff test: fake rows
local lastError
local lastScan = { units = 0, unknown = 0, tanks = "none", tankSource = "none" }
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
    local ok, a, b, c, d = pcall(f, ...)
    if not ok then return nil end
    return a, b, c, d
end

local function On(key)
    if not db then return DEFAULTS[key] end
    return db[key] ~= false
end

local function Active()
    return db ~= nil and module and On("enabled") and true or false
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

local function YesNo(v) return v and "yes" or "no" end
local function OnOff(v) return v and "on" or "off" end

-- "on" / "off" / "" (toggle) to a boolean; nil for anything else.
local function Toggle(arg, current)
    if arg == "on" then return true end
    if arg == "off" then return false end
    if arg == "" then return not current end
    return nil
end

-- ---------------------------------------------------------------------------
-- Class and spells
-- ---------------------------------------------------------------------------

local function PlayerClass()
    local _, classFile, classID = Call("UnitClass", "player")
    return Str(classFile), Num(classID)
end

local CLASS_BY_ID = { [11] = "DRUID", [2] = "PALADIN" }

local function CheckClass()
    local classFile, classID = PlayerClass()
    classFile = classFile or (classID and (CLASS_BY_ID[classID] or "OTHER"))
    if classFile then module = ns.modules[classFile] or false end
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

-- { value = name or ID or nil, knownID, text, label, icon, names = {localized names}, ids = {set} }
-- ids is highest rank first.
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
    if not module then return end
    if InCombat() then
        spellsPending = true
        return
    end
    spellsPending = false
    module.ResolveSpells()
    module.resolved = true
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

-- Whether a buff is yours: true / false, nil when the client hides it.
local function MineOf(fromPlayer, source)
    if Secret(fromPlayer) then return nil end
    if type(fromPlayer) == "boolean" then return fromPlayer end
    if Secret(source) then return nil end
    source = Str(source)
    if not source then return false end
    if source == "player" then return true end
    local v = Call("UnitIsUnit", source, "player")
    if Secret(v) then return nil end
    return v and true or false
end

-- One buff: { id, name, hidden, mine }, nil at the end of the list, or false when it cannot be
-- read.
local function ReadBuff(unit, i)
    if IndexIsSecret(unit, i) then return false end
    local C = _G.C_UnitAuras
    if type(C) == "table" and type(C.GetAuraDataByIndex) == "function" then
        local ok, a = pcall(C.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok or Secret(a) then return false end
        if type(a) ~= "table" then return nil end
        local ok2, id, name, source, fromPlayer = pcall(function()
            return a.spellId, a.name, a.sourceUnit, a.isFromPlayerOrPlayerPet
        end)
        if not ok2 then return false end
        return { id = Num(id), name = Str(name), hidden = Secret(id), mine = MineOf(fromPlayer, source) }
    end
    local f = (type(_G.UnitBuff) == "function" and _G.UnitBuff)
    if f then
        local ok, name, _, _, _, _, _, source, _, _, id = pcall(f, unit, i)
        if not ok then return false end
        if Secret(name) then return { id = Num(id), hidden = true, mine = MineOf(nil, source) } end
        if not Str(name) then return nil end
        return { id = Num(id), name = Str(name), hidden = Secret(id), mine = MineOf(nil, source) }
    end
    if type(_G.UnitAura) == "function" then
        local ok, name, _, _, _, _, _, source, _, _, id = pcall(_G.UnitAura, unit, i, "HELPFUL")
        if not ok then return false end
        if Secret(name) then return { id = Num(id), hidden = true, mine = MineOf(nil, source) } end
        if not Str(name) then return nil end
        return { id = Num(id), name = Str(name), hidden = Secret(id), mine = MineOf(nil, source) }
    end
    return false
end

-- Every buff that could be identified (by ID or name), and whether anything could not be read:
-- a refused read, a secret aura, or a buff with neither a readable ID nor name.
local function ReadBuffs(unit)
    local list, unknown = {}, false
    for i = 1, MAX_AURAS do
        local b = ReadBuff(unit, i)
        if b == false then unknown = true break end
        if b == nil then break end
        if b.id or b.name then list[#list + 1] = b else unknown = true end
    end
    return list, unknown
end

local function Matches(b, s)
    if not s then return false end
    if b.id and s.ids[b.id] then return true end
    return b.name ~= nil and s.names[b.name] == true
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

local function UnitClassFile(unit)
    local _, classFile = Call("UnitClass", unit)
    return Str(classFile)
end

local function ClassHex(classFile)
    local cc = _G.C_ClassColor
    if classFile and type(cc) == "table" and type(cc.GetClassColor) == "function" then
        local ok, c = pcall(cc.GetClassColor, classFile)
        if ok and type(c) == "table" and type(c.GenerateHexColor) == "function" then
            local ok2, hex = pcall(c.GenerateHexColor, c)
            if ok2 and Str(hex) then return hex end
        end
    end
    if classFile and type(_G.RAID_CLASS_COLORS) == "table" then
        local c = _G.RAID_CLASS_COLORS[classFile]
        if type(c) == "table" and Num(c.r) and Num(c.g) and Num(c.b) then
            return string.format("ff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
        end
    end
    return nil
end

local function UnitLabel(unit)
    local name = Str(Call("UnitName", unit)) or unit
    local color = ClassHex(UnitClassFile(unit))
    return color and ("|c" .. color .. name .. "|r") or name, name
end

-- ---------------------------------------------------------------------------
-- Reagents
-- ---------------------------------------------------------------------------

local function Threshold(key, default)
    local v = db and Num(db[key])
    return v or default
end

local function ItemName(itemID, fallback)
    local c = _G.C_Item
    if type(c) == "table" and type(c.GetItemNameByID) == "function" then
        local ok, name = pcall(c.GetItemNameByID, itemID)
        if ok and Str(name) then return name end
    end
    local name = Str(Call("GetItemInfo", itemID))
    return name or fallback or ("item " .. itemID)
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

-- One reagent check: an entry { item, name, count, min, spell } added to checked, and to low
-- when the bags hold fewer than the threshold.
local function CheckReagent(low, checked, item, fallbackName, key, default, spellLabel)
    local count, min = BagCount(item), Threshold(key, default)
    local e = { item = item, name = ItemName(item, fallbackName), count = count, min = min, spell = spellLabel }
    checked[#checked + 1] = e
    if count and count < min then low[#low + 1] = e end
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
        tip:AddLine(e.leftText or ("Left-click: " .. tostring(e.spellLabel) .. " on " .. tostring(e.plainName)), 1, 1, 1)
        if e.spell2Label then
            tip:AddLine("Right-click: " .. e.spell2Label, 1, 1, 1)
        end
        if e.note then tip:AddLine(e.note, 0.8, 0.8, 0.8, true) end
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

local function Header(i)
    local fs = headers[i]
    if not fs then
        fs = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetJustifyH("LEFT")
        headers[i] = fs
    end
    return fs
end

-- Out of combat only: sets every row's attributes and lays the box out. The sections, in order,
-- come from the module: { key, title }.
local function Layout(entries, reagents, mod)
    if not box or InCombat() then return end
    reagents = reagents or {}
    local direction = UseKeyDown() and "AnyDown" or "AnyUp"
    local sections = mod and mod.Sections() or {}
    local y, n, w = -PAD, 0, MIN_W
    local usedHeaders = 0
    for _, sec in ipairs(sections) do
        local any = false
        for _, e in ipairs(entries) do
            if e.section == sec.key then any = true break end
        end
        if any then
            usedHeaders = usedHeaders + 1
            local header = Header(usedHeaders)
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
        end
    end
    for i = usedHeaders + 1, #headers do headers[i]:Hide() end
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

-- A row for one member: the section it goes in, the unit, the resolved spell it casts, and an
-- optional note after the name ("tank", "fallback", ...).
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

-- A test row: section, coloured text, the resolved spell for icon and label, out of range.
local function FakeEntry(section, text, spell, far)
    return { section = section, text = text, icon = spell.icon, spellLabel = spell.label,
        plainName = (text:match("|c%x%x%x%x%x%x%x%x(.-)|r")) or text, far = far, fake = true }
end

-- The module the test rows come from: yours, or the druid's on a class without one.
local function TestModule()
    return module or ns.modules.DRUID
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
        local m = TestModule()
        if testMode and m then
            local fe, fr = m.Fake()
            Layout(fe, fr, m)
        else
            Layout({}, {}, m)
        end
        return
    end
    if not module.resolved then ResolveSpells() end

    local entries, missing = {}, {}
    local units = module.WantsGroup() and GroupUnits() or { "player" }
    local stats = { units = 0, unknown = 0 }

    -- The tanks, for the module's tank checks and the "(tank)" mark.
    local tankSet, tankList, tankSource = {}, {}, "none"
    if InGroup() then
        tankList, tankSource = Tanks(units)
        for _, u in ipairs(tankList) do tankSet[u] = true end
    end
    local names = {}
    for _, u in ipairs(tankList) do names[#names + 1] = select(2, UnitLabel(u)) end
    stats.tanks = #names > 0 and table.concat(names, ", ") or "none"
    stats.tankSource = tankSource

    module.Check(units, tankSet, entries, missing, stats)

    local reagents = {}
    if On("reagents") then
        local ok, low = pcall(module.LowReagents)
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
        local fe, fr = module.Fake()
        for _, e in ipairs(fe) do entries[#entries + 1] = e end
        if #reagents == 0 then reagents = fr end
    end
    Layout(entries, reagents, module)
end

local function SafeUpdate()
    local ok, err = pcall(Update)
    if not ok then Fail("update", err) end
end

local function Refresh()
    dirty = true
    SafeUpdate()
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

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
    if not quiet then Print((LABELS[key] or key) .. ": " .. (on and "on" or "off") .. ".") end
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

-- The modules, yours first.
local function Modules()
    local list = {}
    if module then list[1] = module end
    for _, c in ipairs(MODULE_ORDER) do
        local m = ns.modules[c]
        if m and m ~= module then list[#list + 1] = m end
    end
    return list
end

-- The reagent thresholds to show: yours, or every module's on a class without one.
local function ThresholdList()
    local list = {}
    for _, m in ipairs(module and { module } or Modules()) do
        for _, t in ipairs(m.thresholds or {}) do list[#list + 1] = t end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function PrintHelp()
    if module then
        Print(module.blurb)
    else
        Print("a buff check for druids and paladins: who lacks your buffs. Click a name to buff it."
            .. (module == false and " Idle on this character (not a druid or paladin)." or ""))
    end
    Print("/bbuff on | off - switch it on or off")
    for _, m in ipairs(module and { module } or Modules()) do
        for _, line in ipairs(m.Help()) do Print(line) end
    end
    Print("/bbuff group [on|off] - list group members (off: only you)")
    Print("/bbuff sound [on|off] - a short sound when something goes missing")
    local parts = {}
    for _, t in ipairs(ThresholdList()) do
        parts[#parts + 1] = string.format("/bbuff reagents %s <n> (now %d)", t.word, Threshold(t.key, t.default))
    end
    Print("/bbuff reagents [on|off] - warn on low reagents" .. (#parts > 0 and ("; " .. table.concat(parts, ", ")) or ""))
    Print("/bbuff unlock | lock | reset - move the box (Alt + drag works when locked), or put it back at the top centre")
    Print("/bbuff test - show the box with test rows; /bbuff status - the current state")
end

local function PrintStatus()
    Print("version " .. VERSION .. "   class module: " .. (module and module.name or "none"))
    if module == false then
        Print("not a druid or paladin: the addon is idle on this character.")
    elseif module == nil then
        Print("class not known yet.")
    end
    local line = "enabled: " .. YesNo(On("enabled"))
    for _, o in ipairs(module and module.options or {}) do
        line = line .. "   " .. o.short .. ": " .. OnOff(On(o.key))
    end
    Print(line .. "   group: " .. OnOff(On("group")) .. "   sound: " .. OnOff(On("sound"))
        .. "   reagents: " .. OnOff(On("reagents")))
    if module then
        for _, l in ipairs(module.StatusSpells(spellsPending)) do Print(l) end
        local okR, _, checked = pcall(module.LowReagents)
        local parts = {}
        if okR and type(checked) == "table" then
            for _, r in ipairs(checked) do
                parts[#parts + 1] = string.format("%s %s/%d (%s)", r.name, r.count and tostring(r.count) or "?", r.min, tostring(r.spell))
            end
        end
        Print("reagents: " .. OnOff(On("reagents")) .. "   " .. (#parts > 0 and table.concat(parts, ", ")
            or ("nothing to check (" .. module.reagentSpells .. " not known)")))
    end
    Print("group: " .. (InRaid() and "raid" or InGroup() and "party" or "solo")
        .. "   tank: " .. tostring(lastScan.tanks) .. " (" .. tostring(lastScan.tankSource) .. ")"
        .. "   set by hand: " .. (TankText() or "none"))
    if module then Print(module.StatusLast(lastScan)) end
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
    if module and module.StatusExtra then
        for _, l in ipairs(module.StatusExtra()) do Print(l) end
    end
    Print("last error: " .. (lastError or "none"))
end

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd, arg = cmd or "", arg or ""
    if cmd == "on" or cmd == "off" then
        Set("enabled", cmd == "on")
        if cmd == "on" and module == false then Print("not a druid or paladin: it stays idle on this character.") end
    elseif cmd == "group" or cmd == "sound" then
        local v = Toggle(arg, On(cmd))
        if v == nil then Print("/bbuff " .. cmd .. " [on|off]") else Set(cmd, v) end
    elseif cmd == "reagents" then
        local which, n = arg:match("^(%a+)%s*(.*)$")
        local v = tonumber(n or "")
        local found
        for _, m in ipairs(Modules()) do
            for _, t in ipairs(m.thresholds or {}) do
                if t.word == which then found = t end
            end
        end
        if found and v and v == v then
            SetThreshold(found.key, v, found.label)
        else
            local t = Toggle(arg, On("reagents"))
            if t == nil then
                local parts = {}
                for _, th in ipairs(ThresholdList()) do parts[#parts + 1] = "/bbuff reagents " .. th.word .. " <n>" end
                Print("/bbuff reagents [on|off]" .. (#parts > 0 and (", " .. table.concat(parts, ", ")) or ""))
            else
                Set("reagents", t)
            end
        end
    elseif cmd == "tank" and (arg == "" or arg == "set") then
        SetTank()
    elseif cmd == "tank" and arg == "clear" then
        ClearTank()
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
        -- The class commands: yours first, then the other module's (their settings are
        -- account-wide, so a druid can set a paladin's options and the other way round).
        for _, m in ipairs(Modules()) do
            if m.Slash(cmd, arg) then return end
        end
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterBuffsForeverAPI
--
-- For BetterGaarForever, the optional hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterBuffsForeverDB (the tank and the paladin's
-- per-character options in BetterBuffsForeverCharDB) and change only through the same functions
-- /bbuff uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "on · 2 missing" or "idle (not a druid
--                        or paladin)"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func },
--                        { text, radio = true, checked, func }, { text, submenu } and
--                        { divider = true }; the class options are the ones for your class
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    if module == false then return "idle (not a druid or paladin)" end
    if not On("enabled") then return "off" end
    if InCombat() then return "on" .. DOT .. "hidden in combat" end
    return "on" .. DOT .. (missingCount > 0 and (missingCount .. " missing") or "all buffed")
        .. ((lastScan.unknown or 0) > 0 and (DOT .. lastScan.unknown .. " unknown") or "")
end

local function CheckEntry(key)
    return { text = LABELS[key] or key, checkbox = true,
        checked = function() return On(key) end,
        func = function() Set(key, not On(key)) end }
end

local function ThresholdMenu(t)
    local sub = {}
    for _, v in ipairs(t.choices) do
        sub[#sub + 1] = { text = tostring(v) .. (v == t.default and " (default)" or ""), radio = true,
            checked = function() return Threshold(t.key, t.default) == v end,
            func = function() SetThreshold(t.key, v, t.label) end }
    end
    return { text = t.label .. " reagent warning below", submenu = sub }
end

local function MenuEntries()
    if not db then return {} end
    local tank = TankText()
    local list = {
        { text = "Enabled", checkbox = true,
          checked = function() return On("enabled") end,
          func = function() Set("enabled", not On("enabled")) end },
    }
    local m = module or nil
    for _, o in ipairs(m and m.options or {}) do list[#list + 1] = CheckEntry(o.key) end
    list[#list + 1] = CheckEntry("group")
    list[#list + 1] = CheckEntry("sound")
    list[#list + 1] = CheckEntry("reagents")
    for _, t in ipairs(m and m.thresholds or {}) do list[#list + 1] = ThresholdMenu(t) end
    if m and m.Menu then
        for _, e in ipairs(m.Menu()) do list[#list + 1] = e end
    end
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Set tank: current target", func = SetTank }
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
-- What the modules use
-- ---------------------------------------------------------------------------

ns.Print, ns.Fail, ns.InCombat = Print, Fail, InCombat
ns.Secret, ns.Num, ns.Str, ns.Bool, ns.Call = Secret, Num, Str, Bool, Call
ns.On, ns.Set, ns.Toggle, ns.OnOff, ns.YesNo, ns.Refresh = On, Set, Toggle, OnOff, YesNo, Refresh
ns.LABELS = LABELS
ns.SpellName, ns.Known, ns.ResolveSpell = SpellName, Known, ResolveSpell
ns.ReadBuffs, ns.Matches = ReadBuffs, Matches
ns.InGroup, ns.InRaid, ns.Eligible = InGroup, InRaid, Eligible
ns.UnitGUIDPlain, ns.UnitLabel, ns.UnitClassFile, ns.ClassHex = UnitGUIDPlain, UnitLabel, UnitClassFile, ClassHex
ns.Threshold, ns.CheckReagent = Threshold, CheckReagent
ns.MakeEntry, ns.FakeEntry = MakeEntry, FakeEntry
ns.CharDB = function() return charDb end
ns.DB = function() return db end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    -- Every module's keys, whatever this character's class.
    for _, c in ipairs(MODULE_ORDER) do
        local m = ns.modules[c]
        if m then
            for _, o in ipairs(m.options or {}) do
                SAVED_KEYS[o.key], DEFAULTS[o.key], LABELS[o.key] = true, o.default ~= false, o.label
            end
            for _, t in ipairs(m.thresholds or {}) do SAVED_KEYS[t.key] = true end
            for k in pairs(m.savedKeys or {}) do SAVED_KEYS[k] = true end
        end
    end

    if type(BetterBuffsForeverDB) ~= "table" then BetterBuffsForeverDB = {} end
    db = BetterBuffsForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if type(db[k]) ~= "boolean" then db[k] = v end
    end
    for _, c in ipairs(MODULE_ORDER) do
        local m = ns.modules[c]
        for _, t in ipairs(m and m.thresholds or {}) do
            local v = Num(tonumber(db[t.key]))
            db[t.key] = v and math.max(0, math.min(MAX_THRESHOLD, math.floor(v))) or nil
        end
    end
    local p = db.pos
    if type(p) == "table" and Num(p.x) and Num(p.y) then
        db.pos = { x = p.x, y = p.y }
    else
        db.pos = nil
    end

    -- Per character: the tank set by hand, { guid, name }, and the modules' own keys.
    if type(BetterBuffsForeverCharDB) ~= "table" then BetterBuffsForeverCharDB = {} end
    charDb = BetterBuffsForeverCharDB
    local charKeys = { tank = true }
    for _, c in ipairs(MODULE_ORDER) do
        local m = ns.modules[c]
        for k in pairs(m and m.charKeys or {}) do charKeys[k] = true end
    end
    for k in pairs(charDb) do
        if not charKeys[k] then charDb[k] = nil end
    end
    local t = charDb.tank
    if type(t) == "table" and Str(t.guid) then
        charDb.tank = { guid = t.guid, name = Str(t.name) or "?" }
    else
        charDb.tank = nil
    end
    for _, c in ipairs(MODULE_ORDER) do
        local m = ns.modules[c]
        if m and m.Bind then m.Bind(db, charDb) end
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
pcall(events.RegisterEvent, events, "UPDATE_SHAPESHIFT_FORM")    -- a paladin's aura changed
pcall(events.RegisterEvent, events, "UPDATE_SHAPESHIFT_FORMS")
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
            if module == nil then CheckClass() end
            if module and not module.resolved then ResolveSpells() end
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
            if module then ResolveSpells() end
        elseif event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_SHAPESHIFT_FORMS" then
            if module and module.OnEvent then module.OnEvent(event) end
            if not Active() then return end
        end
        dirty = true
    end)
    if not ok then Fail(event, err) end
end)

SLASH_BETTERBUFFSFOREVER1 = "/bbuff"
SLASH_BETTERBUFFSFOREVER2 = "/betterbuffsforever"
SlashCmdList.BETTERBUFFSFOREVER = OnSlash
