--[[
  BetterPlatesForever - cleaner enemy nameplates on WoW Forever.

  A port of GaarPlates to the Better...Forever conventions: standalone, no options panel, no
  minimap button, a slash command and a small API for BetterGaarForever's hub. It draws its own
  overlay on top of each enemy nameplate and hides Blizzard's art underneath:

    * Flat health bar (120x12 by default) on a dark backdrop with a 1px border. Colour by
      reaction (default), class, health or one solid colour, pulled slightly toward its own
      luminance so nothing reads as harsh pure red. Mobs tagged by someone else are grey.
      Execute tint at 20% health or less (option).
    * Threat on every plate: purple when you hold aggro (with a purple ring), amber when your
      threat is high (status 2 or more), threat percent on the bar (option).
    * Name above the bar, level right of it, health text (off, percent or current) in it, the
      unit's target under it (option).
    * Cast bar with spell icon, spell name and the time left; uninterruptible casts get the grey
      "shield" look (grey bar, light steel edge round the icon).
    * Your own debuffs (HARMFUL|PLAYER): up to 8 icons of 16px with stacks and a countdown that
      turns yellow at 8 s and red at 3 s.
    * Your target: scaled up to 115% with a faint ring; other plates dimmed to 55% while you have
      a target (each an option).
    * Friendly plates are left to Blizzard unless "friendly" is turned on (off by default).
    * /bpf (or /betterplatesforever) for help, status, on|off, color, health, size, friendly,
      threat, threattext, execute, debuffs, tot, dim, targetscale and reset.
    * BetterPlatesForeverAPI, a small global table for BetterGaarForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The addon runs exactly the same
      without the hub; the API only exposes the settings the slash command already changes.

  It changes no CVars at all: stacking, overlap, plate size, distance and which plates are shown
  stay whatever the game (or you) set them to.

  Names: C_NamePlate.GetNamePlateForUnit / GetNamePlates, NAME_PLATE_UNIT_ADDED / _REMOVED, the
  plate's namePlateUnitToken and UnitFrame (Blizzard_NamePlates in retail FrameXML, which
  Forever's UI follows), C_UnitAuras.GetAuraDataByIndex (UnitAura on a client that still has it),
  UnitCastingInfo / UnitChannelInfo, UnitDetailedThreatSituation, UnitIsTapDenied.

  Taint and secret values: Blizzard's plate art (plate.UnitFrame) is only hidden, through
  HookScript("OnShow") on it and Hide(); it is shown again when a plate stops being styled or the
  addon is turned off. No Blizzard function or table is replaced or written. Where this client
  hides a number (issecretvalue), the health bar still gets the raw values - handing a secret
  straight back to a widget is allowed - but nothing is worked out from them: no percent, no
  execute tint, no health text, no colour by health. Threat and level secrets are dropped to nil
  at the read. And because secrecy travels further than issecretvalue reports, every part of a
  plate's update runs inside pcall: the first refusal switches that one part off for the session
  with one message, instead of an error twelve times a second per plate.
]]

local _G = _G
local ADDON_NAME = ... or "BetterPlatesForever"
local PREFIX = "|cff33ff99BetterPlatesForever|r: "
local DOT = " \194\183 "

local VERSION = "1.0"

local BAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"
local WHITE = "Interface\\Buttons\\WHITE8x8"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local AURA_N, AURA_SZ = 8, 16     -- debuff icons per plate, and their size
local CAST_H = 9                  -- cast bar height
local NAME_SIZE = 11              -- name font size
local EXECUTE_PCT = 20            -- execute tint at or below this health percent
local DIM_ALPHA = 0.55            -- non-target plates while you have a target
local TARGET_SCALE = 1.15         -- your target's plate
local TICK = 0.08                 -- seconds between plate updates (12.5 Hz)
local MIN_W, MAX_W = 60, 250      -- health bar width bounds for /bpf size
local MIN_H, MAX_H = 6, 30        -- health bar height bounds
local SOLID = { 0.2, 0.6, 1.0 }   -- colour mode "solid"

local COLOR_MODES = { "reaction", "class", "health", "solid" }
local COLOR_LABELS = { reaction = "Reaction", class = "Class", health = "Health", solid = "Solid" }
local HEALTH_MODES = { "off", "percent", "current" }
local HEALTH_LABELS = { off = "Off", percent = "Percent", current = "Current" }
local SIZE_PRESETS = {
    { label = "Small", w = 100, h = 10 },
    { label = "Medium", w = 120, h = 12 },
    { label = "Large", w = 140, h = 16 },
}

-- The on/off settings, shared by the slash command, the status and the menu.
local TOGGLES = {
    { key = "friendly", cmd = "friendly", label = "Style friendly plates too" },
    { key = "threat", cmd = "threat", label = "Threat colouring" },
    { key = "threatText", cmd = "threattext", label = "Threat percent text" },
    { key = "execute", cmd = "execute", label = "Execute tint (20% or less)" },
    { key = "debuffs", cmd = "debuffs", label = "My debuffs" },
    { key = "tot", cmd = "tot", label = "Target of target" },
    { key = "dim", cmd = "dim", label = "Dim non-target plates" },
    { key = "targetScale", cmd = "targetscale", label = "Enlarge my target" },
}

local DEFAULTS = {
    enabled = true,
    colorMode = "reaction",
    healthText = "percent",
    width = 120,
    height = 12,
    friendly = false,
    threat = true,
    threatText = true,
    execute = true,
    debuffs = true,
    tot = true,
    dim = true,
    targetScale = true,
}

-- Every key BetterPlatesForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = {}
for k in pairs(DEFAULTS) do SAVED_KEYS[k] = true end

local db                 -- BetterPlatesForeverDB, bound at ADDON_LOADED (never at file scope)
local overlays = {}      -- [nameplate frame] = our overlay
local active = {}        -- [unit token] = overlay currently styling that unit
local hookedUF = setmetatable({}, { __mode = "k" })   -- Blizzard UnitFrames we hooked
local blocked = {}       -- [feature] = true once this client refused it
local warnedGaarPlates

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end

local function OnOff(v) return v and "on" or "off" end

-- Where the client hides a value it hands back a secret: it may be passed to a widget, but
-- arithmetic, comparison, a boolean test and even "or" on it are refused. issecretvalue does not
-- exist on a client where nothing is secret, so the guard costs nothing there.
local issecretvalue = _G.issecretvalue
local function Secret(a, b)
    if not issecretvalue then return false end
    if issecretvalue(a) then return true end
    return b ~= nil and issecretvalue(b) or false
end

-- The value, or nil when it is secret: every later test on it is then an ordinary one.
local function Plain(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function Num(v)
    v = Plain(v)
    if type(v) ~= "number" or v ~= v then return nil end
    return v
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- A secret string is passed on as it is; anything else gets "" for nil.
local function SetTextSafe(fs, v)
    if Secret(v) then fs:SetText(v) else fs:SetText(v or "") end
end

local function SetSolid(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
end

-- Whether an addon is loaded: C_AddOns on newer clients, the old global otherwise.
local function AddOnLoaded(name)
    local c = _G.C_AddOns
    if type(c) == "table" and type(c.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(c.IsAddOnLoaded, name)
        if ok and loaded then return true end
    end
    if type(_G.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(_G.IsAddOnLoaded, name)
        if ok and loaded then return true end
    end
    return false
end

local function HasPlateAPI()
    local c = _G.C_NamePlate
    return type(c) == "table" and type(c.GetNamePlateForUnit) == "function"
end

-- ---------------------------------------------------------------------------
-- Overlay frames
-- ---------------------------------------------------------------------------

local function BorderFrame(parent, level)
    local bd = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bd:SetFrameLevel(level)
    bd:SetPoint("TOPLEFT", -1, 1); bd:SetPoint("BOTTOMRIGHT", 1, -1)
    bd:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })
    bd:SetBackdropBorderColor(0, 0, 0, 1)
    return bd
end

local function ApplySize(o)
    o.health:SetSize(db.width, db.height)
    o.cast:SetSize(db.width, CAST_H)
    o.cast.icon:SetSize(CAST_H + 8, CAST_H + 8)
    o.auraRow:SetSize(db.width, AURA_SZ)
end

local function SetFonts(o)
    local font = _G.STANDARD_TEXT_FONT
    local hs = math.max(8, db.height - 2)
    o.name:SetFont(font, NAME_SIZE, "OUTLINE")
    o.level:SetFont(font, NAME_SIZE - 2, "OUTLINE")
    o.htext:SetFont(font, hs, "OUTLINE")
    o.ttext:SetFont(font, hs, "OUTLINE")
    local ts = math.max(7, NAME_SIZE - 3)
    o.tot:SetFont(font, ts, "OUTLINE")
    -- The debuff row hangs off this line, so it gets a fixed height. Left to size itself it would
    -- collapse whenever the unit has no target, and the icons would jump.
    o.tot:SetHeight(ts + 2)
    o.cast.text:SetFont(font, math.max(8, CAST_H), "OUTLINE")
    o.cast.time:SetFont(font, math.max(8, CAST_H), "OUTLINE")
end

local function BuildOverlay(plate)
    if overlays[plate] then return overlays[plate] end
    local o = { plate = plate }

    local f = CreateFrame("Frame", nil, plate)
    f:SetAllPoints(plate)
    f:SetFrameLevel((plate:GetFrameLevel() or 0) + 2)
    o.frame = f

    local h = CreateFrame("StatusBar", nil, f)
    h:SetStatusBarTexture(BAR_TEX)
    h:SetPoint("CENTER", f, "CENTER", 0, 0)
    h:SetMinMaxValues(0, 1); h:SetValue(1)
    o.health = h
    local bg = h:CreateTexture(nil, "BACKGROUND"); SetSolid(bg, 0, 0, 0, 0.85)
    bg:SetPoint("TOPLEFT", -1, 1); bg:SetPoint("BOTTOMRIGHT", 1, -1)
    BorderFrame(h, h:GetFrameLevel())

    -- The ring: purple for aggro, a faint grey for your target.
    local ring = CreateFrame("Frame", nil, h, "BackdropTemplate")
    ring:SetFrameLevel(h:GetFrameLevel() + 2)
    ring:SetPoint("TOPLEFT", -1, 1); ring:SetPoint("BOTTOMRIGHT", 1, -1)
    ring:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 }); ring:Hide()
    o.ring = ring

    o.name = h:CreateFontString(nil, "OVERLAY"); o.name:SetPoint("BOTTOM", h, "TOP", 0, 2)
    -- Level outside the bar's right edge: on the name row a long mob name runs into it.
    o.level = h:CreateFontString(nil, "OVERLAY"); o.level:SetPoint("LEFT", h, "RIGHT", 3, 0)
    o.htext = h:CreateFontString(nil, "OVERLAY"); o.htext:SetPoint("CENTER", h, "CENTER", 0, 0)
    o.ttext = h:CreateFontString(nil, "OVERLAY"); o.ttext:SetPoint("RIGHT", h, "RIGHT", -2, 0)

    -- Cast bar over the name row, as in GaarPlates: icon left of it, spell name left inside,
    -- time left right inside.
    local c = CreateFrame("StatusBar", nil, f); c:SetStatusBarTexture(BAR_TEX)
    c:SetPoint("CENTER", o.name, "CENTER", 0, 0)
    c:SetFrameLevel(h:GetFrameLevel() + 4)
    c:SetMinMaxValues(0, 1); c:SetValue(0)
    local cbg = c:CreateTexture(nil, "BACKGROUND"); SetSolid(cbg, 0, 0, 0, 0.85)
    cbg:SetPoint("TOPLEFT", -1, 1); cbg:SetPoint("BOTTOMRIGHT", 1, -1)
    BorderFrame(c, c:GetFrameLevel())
    local ci = c:CreateTexture(nil, "OVERLAY"); ci:SetPoint("RIGHT", c, "LEFT", -2, 0)
    ci:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    c.icon = ci
    -- A 1px edge round the icon, recoloured for uninterruptible casts (GaarCast's shield look).
    local ib = CreateFrame("Frame", nil, c, "BackdropTemplate")
    ib:SetPoint("TOPLEFT", ci, "TOPLEFT", -1, 1); ib:SetPoint("BOTTOMRIGHT", ci, "BOTTOMRIGHT", 1, -1)
    ib:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })
    ib:SetBackdropBorderColor(0, 0, 0, 1)
    c.iconBorder = ib
    c.time = c:CreateFontString(nil, "OVERLAY")
    c.time:SetPoint("RIGHT", c, "RIGHT", -2, 0); c.time:SetJustifyH("RIGHT")
    c.text = c:CreateFontString(nil, "OVERLAY")
    c.text:SetPoint("LEFT", c, "LEFT", 3, 0); c.text:SetPoint("RIGHT", c.time, "LEFT", -2, 0)
    c.text:SetJustifyH("LEFT")
    c:Hide()
    o.cast = c

    o.auraRow = CreateFrame("Frame", nil, f)
    o.auraIcons = {}
    for i = 1, AURA_N do
        local ic = CreateFrame("Frame", nil, o.auraRow)
        ic:SetSize(AURA_SZ, AURA_SZ)
        local t = ic:CreateTexture(nil, "ARTWORK"); t:SetAllPoints(); t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic.tex = t
        local cnt = ic:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        cnt:SetPoint("BOTTOMRIGHT", 1, 0); ic.cnt = cnt
        local tm = ic:CreateFontString(nil, "OVERLAY")
        tm:SetPoint("CENTER", ic, "CENTER", 0, 0)
        tm:SetFont(_G.STANDARD_TEXT_FONT, 10, "OUTLINE"); ic.timer = tm
        BorderFrame(ic, ic:GetFrameLevel())
        ic:Hide()
        o.auraIcons[i] = ic
    end

    -- The unit's target first, then the debuffs under it.
    o.tot = h:CreateFontString(nil, "OVERLAY"); o.tot:SetPoint("TOP", h, "BOTTOM", 0, -1)
    o.auraRow:SetPoint("TOP", o.tot, "BOTTOM", 0, -2)

    ApplySize(o); SetFonts(o)
    overlays[plate] = o
    return o
end

-- ---------------------------------------------------------------------------
-- Per-feature updates. Each one runs inside pcall (see Run below); none of them may assume a
-- value is plain unless it has been checked.
-- ---------------------------------------------------------------------------

-- Threat: returns whether you hold aggro and whether your threat is high.
local function UpdateThreat(o, unit)
    o.ttext:SetText("")
    if not db.threat or not Plain(UnitCanAttack("player", unit)) then return false, false end
    local tanking, status, pct = UnitDetailedThreatSituation("player", unit)
    -- Threat comes back secret where the client hides it, and a secret boolean cannot even be
    -- tested for truth. Dropped to nil here, every test below is an ordinary one.
    tanking, status, pct = Plain(tanking), Num(status), Num(pct)
    if db.threatText and pct and pct > 0 then
        o.ttext:SetText(string.format("%d%%", pct + 0.5))
    end
    return tanking and true or false, (status ~= nil and status >= 2) or false
end

local function ReactionColor(unit)
    if Plain(UnitIsPlayer(unit)) then
        if Plain(UnitIsFriend("player", unit)) then return 0.25, 0.5, 0.9 end
        return 0.85, 0.2, 0.2
    end
    local r = Num(UnitReaction(unit, "player")) or 4
    if r <= 3 then return 0.8, 0.2, 0.2
    elseif r == 4 then return 0.9, 0.8, 0.2 end
    return 0.2, 0.7, 0.25
end

local function ClassColor(unit)
    if not Plain(UnitIsPlayer(unit)) then return nil end
    local _, cls = UnitClass(unit)
    cls = Plain(cls)
    local c = type(cls) == "string" and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[cls]
    if c then return c.r, c.g, c.b end
end

-- pct is nil when the health is secret: then there is no colour by health.
local function BaseColor(unit, pct)
    -- A mob someone else tagged is grey before anything else is considered.
    if _G.UnitIsTapDenied and Plain(UnitIsTapDenied(unit)) then return 0.45, 0.45, 0.48 end
    local mode = db.colorMode
    if mode == "solid" then return SOLID[1], SOLID[2], SOLID[3] end
    if mode == "class" then
        local r, g, b = ClassColor(unit)
        if r then return r, g, b end
    end
    if mode == "health" and pct then return (1 - pct), pct, 0 end
    return ReactionColor(unit)
end

local function UpdateHealth(o, unit, tanking, high)
    local mx, cur = UnitHealthMax(unit), UnitHealth(unit)
    local pct
    if Secret(cur, mx) then
        -- The widget takes the raw values; only this file may not do sums on them. A secret
        -- cannot even be tested with "or", so this case is written out on its own.
        o.health:SetMinMaxValues(0, mx)
        o.health:SetValue(cur)
    else
        mx = (type(mx) == "number" and mx > 0) and mx or 1
        cur = type(cur) == "number" and cur or 0
        pct = cur / mx
        o.health:SetMinMaxValues(0, mx)
        o.health:SetValue(cur)
    end

    local r, g, b = BaseColor(unit, pct)
    if pct and db.execute and pct * 100 <= EXECUTE_PCT then r, g, b = 0.5, 0.22, 0.22 end
    if tanking then r, g, b = 0.55, 0.38, 0.68          -- you hold aggro
    elseif high then r, g, b = 0.8, 0.6, 0.35 end      -- high threat
    -- Pull the colour toward its own luminance so nothing reads as harsh pure red or purple.
    local lum = 0.3 * r + 0.59 * g + 0.11 * b
    local m = 0.28
    o.health:SetStatusBarColor(r + (lum - r) * m, g + (lum - g) * m, b + (lum - b) * m)

    local mode = db.healthText
    if mode == "off" or not pct or cur <= 0 then
        o.htext:SetText("")
    elseif mode == "current" then
        o.htext:SetText(_G.AbbreviateLargeNumbers and _G.AbbreviateLargeNumbers(cur) or tostring(cur))
    else
        o.htext:SetText(math.floor(pct * 100 + 0.5) .. "%")
    end
    if pct and cur <= 0 then o.ttext:SetText("") end
end

local function UpdateText(o, unit)
    SetTextSafe(o.name, (UnitName(unit)))
    local r, g, b
    if db.colorMode == "class" then r, g, b = ClassColor(unit) end
    if r then o.name:SetTextColor(r, g, b) else o.name:SetTextColor(1, 1, 1) end

    -- The level of a unit whose numbers the client hides comes back secret: "??" then.
    local lvl = Num(UnitLevel(unit))
    o.level:SetText((lvl and lvl > 0) and tostring(lvl) or "??")

    local tu = unit .. "target"
    if db.tot and Plain(UnitExists(tu)) then
        local n = UnitName(tu)
        if Secret(n) then o.tot:SetText(n) else o.tot:SetText("-> " .. (n or "")) end
    else
        o.tot:SetText("")
    end
end

-- Returns name, icon, startMs, endMs, notInterruptible for a cast (or channel), or nil.
-- The client dropped the old nameSubtext return, so texture and the timestamps sit one slot
-- earlier than they did on 3.3.5a. The shape is detected rather than assumed.
local function ReadCast(unit, channel)
    local r
    if channel then r = { UnitChannelInfo(unit) } else r = { UnitCastingInfo(unit) } end
    if #r == 0 then return nil end
    local icon, startMs, endMs, notInt
    if type(r[4]) == "number" and type(r[5]) == "number" then
        -- name, text, texture, startMs, endMs, isTradeSkill, [castID,] notInterruptible
        icon, startMs, endMs = r[3], r[4], r[5]
        if channel then notInt = r[7] else notInt = r[8] end
    else
        -- name, nameSubtext, text, texture, startMs, endMs, isTradeSkill, [castID,] notInterruptible
        icon, startMs, endMs = r[4], r[5], r[6]
        if channel then notInt = r[8] else notInt = r[9] end
    end
    -- Everything after this is arithmetic on the timings: no bar is better than an error.
    if Secret(startMs, endMs) or type(startMs) ~= "number" or type(endMs) ~= "number" then return nil end
    return r[1], icon, startMs, endMs, Plain(notInt) == true
end

local function UpdateCast(o, unit)
    local c = o.cast
    local name, icon, startMs, endMs, notInt = ReadCast(unit, false)
    local channel = false
    if not startMs then
        name, icon, startMs, endMs, notInt = ReadCast(unit, true)
        channel = true
    end
    if not startMs then c:Hide(); return end
    local now = GetTime() * 1000
    local dur = endMs - startMs
    if dur <= 0 or now >= endMs then c:Hide(); return end
    local frac = (now - startMs) / dur
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    if channel then frac = 1 - frac end      -- channels drain
    c:SetValue(frac)
    if Secret(icon) then c.icon:SetTexture(icon) else c.icon:SetTexture(icon or QUESTION) end
    SetTextSafe(c.text, name)
    c.time:SetText(string.format("%.1f", (endMs - now) / 1000))
    if notInt then
        c:SetStatusBarColor(0.6, 0.6, 0.6)
        c.iconBorder:SetBackdropBorderColor(0.85, 0.87, 0.95, 1)
    else
        if channel then c:SetStatusBarColor(0.2, 0.75, 0.3) else c:SetStatusBarColor(1.0, 0.7, 0.0) end
        c.iconBorder:SetBackdropBorderColor(0, 0, 0, 1)
    end
    if not c:IsShown() then c:Show() end
end

-- The player's own harmful auras on the unit. Returns found, icon, count, duration, expiration.
-- On a client that refuses the read ("auras cannot be accessed when secret while tainted") the
-- error goes up to Run, which switches debuffs off for the session with one message.
local function ReadAura(unit, i)
    local C = _G.C_UnitAuras
    if type(C) == "table" and type(C.GetAuraDataByIndex) == "function" then
        local a = C.GetAuraDataByIndex(unit, i, "HARMFUL|PLAYER")
        if type(a) ~= "table" then return false end
        return true, a.icon, a.applications, a.duration, a.expirationTime
    end
    if type(_G.UnitAura) == "function" then
        local name, icon, count, _, duration, expiration = _G.UnitAura(unit, i, "HARMFUL|PLAYER")
        if Plain(name) == nil then return false end
        return true, icon, count, duration, expiration
    end
    return false
end

local function UpdateAuras(o, unit)
    local shown = 0
    if db.debuffs then
        local now = GetTime()
        for i = 1, 40 do
            local found, icon, count, duration, expiration = ReadAura(unit, i)
            if not found or shown >= AURA_N then break end
            shown = shown + 1
            local ic = o.auraIcons[shown]
            if Secret(icon) then
                ic.tex:SetTexture(icon); ic._icon = nil
            elseif ic._icon ~= icon then
                ic.tex:SetTexture(icon or QUESTION); ic._icon = icon
            end
            count = Num(count)
            local cn = (count and count > 1) and count or 0
            if ic._cnt ~= cn then ic.cnt:SetText(cn > 0 and cn or ""); ic._cnt = cn end
            duration, expiration = Num(duration), Num(expiration)
            local rem = (duration and duration > 0 and expiration) and (expiration - now) or 0
            if rem > 0 then
                if rem >= 60 then ic.timer:SetText(math.floor(rem / 60 + 0.5) .. "m")
                else ic.timer:SetText(string.format("%d", rem + 0.5)) end
                if rem <= 3 then ic.timer:SetTextColor(1, 0.2, 0.2)
                elseif rem <= 8 then ic.timer:SetTextColor(1, 0.9, 0.2)
                else ic.timer:SetTextColor(1, 1, 1) end
            else
                ic.timer:SetText("")
            end
            if not ic:IsShown() then ic:Show() end
        end
    end
    for i = shown + 1, AURA_N do
        if o.auraIcons[i]:IsShown() then o.auraIcons[i]:Hide() end
    end
    if shown ~= o._lastShown then
        o._lastShown = shown
        local step = AURA_SZ + 2
        local startX = -((shown * step - 2) / 2) + AURA_SZ / 2
        for i = 1, shown do
            o.auraIcons[i]:ClearAllPoints()
            o.auraIcons[i]:SetPoint("CENTER", o.auraRow, "CENTER", startX + (i - 1) * step, 0)
        end
    end
end

-- Target scale, rings and dimming.
local function UpdateEmphasis(o, unit, tanking)
    local isTarget = Plain(UnitIsUnit(unit, "target")) and true or false
    -- The aggro ring stays bold, since that one is a warning; the target ring is only a hint.
    if tanking then
        o.ring:SetBackdropBorderColor(0.55, 0.38, 0.68, 1); o.ring:Show()
    elseif db.targetScale and isTarget then
        o.ring:SetBackdropBorderColor(0.7, 0.7, 0.75, 0.35); o.ring:Show()
    else
        o.ring:Hide()
    end
    o.frame:SetScale((db.targetScale and isTarget) and TARGET_SCALE or 1)
    if db.dim and not isTarget and Plain(UnitExists("target")) then
        o.frame:SetAlpha(DIM_ALPHA)
    else
        o.frame:SetAlpha(1)
    end
end

-- ---------------------------------------------------------------------------
-- The pcall latch: one refusal switches that feature off for the session, with one message.
-- ---------------------------------------------------------------------------

local FEATURE_LABELS = {
    plates = "draw on nameplates",
    threat = "read threat on nameplates",
    health = "read health on nameplates",
    text = "read names and levels on nameplates",
    cast = "time cast bars on nameplates",
    debuffs = "read your debuffs on nameplates",
    emphasis = "scale or dim nameplates",
}
local FEATURE_ORDER = { "plates", "threat", "health", "text", "cast", "debuffs", "emphasis" }

-- What each feature leaves behind once it is switched off.
local CLEAR = {
    threat = function(o) o.ttext:SetText("") end,
    health = function(o) o.htext:SetText("") end,
    text = function(o) o.name:SetText(""); o.level:SetText(""); o.tot:SetText("") end,
    cast = function(o) o.cast:Hide() end,
    debuffs = function(o) for i = 1, AURA_N do o.auraIcons[i]:Hide() end end,
    emphasis = function(o) o.ring:Hide(); o.frame:SetScale(1); o.frame:SetAlpha(1) end,
}

local function Latch(feature, err)
    if blocked[feature] then return end
    blocked[feature] = true
    local clear = CLEAR[feature]
    if clear then
        for _, o in pairs(overlays) do pcall(clear, o) end
    end
    Print("this client will not let an addon " .. (FEATURE_LABELS[feature] or feature)
        .. " - that part is off for this session. (" .. tostring(err) .. ")")
end

local function Run(feature, fn, o, unit, a, b)
    if blocked[feature] then return end
    local ok, r1, r2 = pcall(fn, o, unit, a, b)
    if ok then return r1, r2 end
    Latch(feature, r1)
end

local function UpdatePlate(o, unit)
    local tanking, high = Run("threat", UpdateThreat, o, unit)
    Run("health", UpdateHealth, o, unit, tanking, high)
    Run("text", UpdateText, o, unit)
    Run("cast", UpdateCast, o, unit)
    Run("debuffs", UpdateAuras, o, unit)
    Run("emphasis", UpdateEmphasis, o, unit, tanking)
end

-- ---------------------------------------------------------------------------
-- Blizzard's plate art: hidden while we style the plate, shown again when we stop.
-- ---------------------------------------------------------------------------

local function UnitFrameOf(plate)
    local uf = plate and plate.UnitFrame
    if type(uf) == "table" and uf.Hide and uf.Show and uf.HookScript then return uf end
end

-- Hidden rather than restyled, and hidden again on show: the nameplate driver shows it when a
-- plate is recycled onto a new unit. The hook only acts while this plate is ours.
local function HideBlizzard(o)
    local uf = UnitFrameOf(o.plate)
    if not uf then return end
    if not hookedUF[uf] then
        hookedUF[uf] = true
        local plate = o.plate
        uf:HookScript("OnShow", function(self)
            local ov = overlays[plate]
            if db and db.enabled and not blocked.plates and ov and ov.unit then self:Hide() end
        end)
    end
    o.hidBlizzard = true
    uf:Hide()
end

local function ShowBlizzard(o)
    if not o.hidBlizzard then return end
    o.hidBlizzard = nil
    local uf = UnitFrameOf(o.plate)
    if uf then uf:Show() end
end

-- Stops styling a plate and hands it back to Blizzard.
local function Release(o)
    if o.unit and active[o.unit] == o then active[o.unit] = nil end
    o.unit = nil
    o.frame:Hide()
    ShowBlizzard(o)
end

-- ---------------------------------------------------------------------------
-- Plate lifecycle
-- ---------------------------------------------------------------------------

local function AddPlate(unit)
    if not db or not db.enabled or blocked.plates then return end
    if type(unit) ~= "string" or unit == "player" or not HasPlateAPI() then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return end
    if Plain(UnitIsUnit(unit, "player")) then return end
    local o = overlays[plate]
    if not db.friendly and not Plain(UnitCanAttack("player", unit)) then
        -- Friendly plates are Blizzard's.
        if o then Release(o) end
        if active[unit] then Release(active[unit]) end
        return
    end
    o = o or BuildOverlay(plate)
    if o.unit and o.unit ~= unit and active[o.unit] == o then active[o.unit] = nil end
    if active[unit] and active[unit] ~= o then Release(active[unit]) end
    o.unit = unit
    active[unit] = o
    HideBlizzard(o)
    o.frame:Show()
    UpdatePlate(o, unit)
end

local function RemovePlate(unit)
    local o = active[unit]
    if not o then return end
    active[unit] = nil
    o.unit = nil
    o.frame:Hide()
    -- Blizzard's art stays hidden on a plate going back to the pool; the next NAME_PLATE_UNIT_ADDED
    -- either styles it again or (for a friendly unit) shows it.
end

-- Drawing the overlay itself failed: give every plate back to Blizzard for the session.
local function SafeAdd(unit)
    if blocked.plates then return end
    local ok, err = pcall(AddPlate, unit)
    if ok then return end
    Latch("plates", err)
    for _, o in pairs(overlays) do pcall(Release, o) end
    wipe(active)
end

-- Every plate on screen, checked again (after login, on/off, the friendly setting or a reset).
local function RefreshPlates()
    for unit in pairs(active) do
        if not Plain(UnitExists(unit)) then RemovePlate(unit) end
    end
    if not HasPlateAPI() or type(C_NamePlate.GetNamePlates) ~= "function" then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local u = plate.namePlateUnitToken
        if type(u) == "string" then SafeAdd(u) end
    end
end

local function UpdateAll()
    if not db or not db.enabled then return end
    for unit, o in pairs(active) do
        if Plain(UnitExists(unit)) then UpdatePlate(o, unit) else RemovePlate(unit) end
    end
end

local function ApplySizeAll()
    for _, o in pairs(overlays) do ApplySize(o); SetFonts(o) end
end

local function CountActive()
    local n = 0
    for _ in pairs(active) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- Settings, shared by the slash command and the menu entries of the API
-- ---------------------------------------------------------------------------

local function SetEnabled(on)
    db.enabled = on and true or false
    if db.enabled then
        RefreshPlates()
        Print("on.")
    else
        for _, o in pairs(overlays) do Release(o) end
        wipe(active)
        Print("off - Blizzard's nameplates are back.")
    end
end

local function SetColorMode(mode)
    db.colorMode = mode
    UpdateAll()
    Print("colour by " .. mode .. ".")
end

local function SetHealthText(mode)
    db.healthText = mode
    UpdateAll()
    Print("health text " .. mode .. ".")
end

local function SetSize(w, h)
    db.width = math.floor(Clamp(w, MIN_W, MAX_W) + 0.5)
    db.height = math.floor(Clamp(h, MIN_H, MAX_H) + 0.5)
    ApplySizeAll()
    UpdateAll()
    Print(string.format("health bar %dx%d.", db.width, db.height))
end

local function SetToggle(t, on)
    db[t.key] = on and true or false
    if t.key == "friendly" then RefreshPlates() else UpdateAll() end
    Print(t.label .. ": " .. OnOff(db[t.key]) .. ".")
end

local function ResetSettings()
    for k in pairs(db) do db[k] = nil end
    for k, v in pairs(DEFAULTS) do db[k] = v end
    ApplySizeAll()
    RefreshPlates()
    UpdateAll()
    Print("settings back to defaults.")
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function IsIn(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

local function PrintHelp()
    Print("cleaner enemy nameplates. Commands:")
    Print("/bpf on | off - the whole addon; off gives every plate back to Blizzard (now: " .. OnOff(db and db.enabled) .. ")")
    Print("/bpf color reaction | class | health | solid - bar colour (now: " .. (db and db.colorMode or "?") .. ")")
    Print("/bpf health off | percent | current - health text (now: " .. (db and db.healthText or "?") .. ")")
    Print(string.format("/bpf size <width> <height> - health bar, %d-%d by %d-%d (now: %sx%s)",
        MIN_W, MAX_W, MIN_H, MAX_H, tostring(db and db.width), tostring(db and db.height)))
    local names = {}
    for _, t in ipairs(TOGGLES) do names[#names + 1] = t.cmd end
    Print("/bpf " .. table.concat(names, " | ") .. " on | off - switch a feature")
    Print("/bpf reset - every setting back to its default")
    Print("/bpf status - the current settings and what this client allows")
end

local function Yes(v) return v and "yes" or "MISSING" end

local function PrintStatus()
    Print("version " .. VERSION .. DOT .. (db.enabled and "on" or "off (Blizzard's plates)"))
    Print("colour: " .. db.colorMode .. DOT .. "health text: " .. db.healthText
        .. DOT .. string.format("size: %dx%d", db.width, db.height))
    local parts = {}
    for _, t in ipairs(TOGGLES) do parts[#parts + 1] = t.cmd .. " " .. OnOff(db[t.key]) end
    Print(table.concat(parts, DOT))
    local C = _G.C_UnitAuras
    Print("C_NamePlate: " .. Yes(HasPlateAPI())
        .. "   auras: " .. ((type(C) == "table" and type(C.GetAuraDataByIndex) == "function") and "C_UnitAuras"
            or (type(_G.UnitAura) == "function" and "UnitAura" or "MISSING"))
        .. "   threat: " .. Yes(type(_G.UnitDetailedThreatSituation) == "function")
        .. "   hidden values: " .. (issecretvalue and "possible" or "no"))
    Print("plates styled now: " .. CountActive())
    local off = {}
    for _, f in ipairs(FEATURE_ORDER) do if blocked[f] then off[#off + 1] = f end end
    if #off > 0 then Print("switched off by this client this session: " .. table.concat(off, ", ")) end
    Print("CVars: none are changed by this addon.")
    if AddOnLoaded("GaarPlates") then
        Print("GaarPlates is loaded too: both draw over the same nameplates. Use one of the two.")
    end
end

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    if cmd == "status" then
        PrintStatus()
    elseif cmd == "on" or cmd == "off" then
        SetEnabled(cmd == "on")
    elseif cmd == "color" or cmd == "colour" then
        if IsIn(COLOR_MODES, rest) then SetColorMode(rest)
        else Print("/bpf color reaction | class | health | solid (now: " .. db.colorMode .. ")") end
    elseif cmd == "health" then
        if IsIn(HEALTH_MODES, rest) then SetHealthText(rest)
        else Print("/bpf health off | percent | current (now: " .. db.healthText .. ")") end
    elseif cmd == "size" then
        local w, h = rest:match("^(%d+)%s*[x ]%s*(%d+)$")
        w, h = tonumber(w), tonumber(h)
        if w and h then SetSize(w, h)
        else Print(string.format("/bpf size <width> <height>, %d-%d by %d-%d (now: %dx%d)",
            MIN_W, MAX_W, MIN_H, MAX_H, db.width, db.height)) end
    elseif cmd == "reset" then
        ResetSettings()
    else
        for _, t in ipairs(TOGGLES) do
            if cmd == t.cmd then
                if rest == "on" or rest == "off" then SetToggle(t, rest == "on")
                elseif rest == "" then SetToggle(t, not db[t.key])
                else Print("/bpf " .. t.cmd .. " on | off (now: " .. OnOff(db[t.key]) .. ")") end
                return
            end
        end
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterPlatesForeverAPI
--
-- For BetterGaarForever, the optional hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterPlatesForeverDB and change only through the
-- same functions /bpf uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "on · reaction · 120x12 · threat on"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func },
--                        { text, radio = true, checked, func }, { text, submenu } and { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    return OnOff(db.enabled) .. DOT .. db.colorMode .. DOT .. db.width .. "x" .. db.height
        .. DOT .. "threat " .. OnOff(db.threat)
end

local function MenuEntries()
    if not db then return {} end
    local colors, healths, sizes = {}, {}, {}
    for _, m in ipairs(COLOR_MODES) do
        colors[#colors + 1] = { text = COLOR_LABELS[m], radio = true,
            checked = function() return db.colorMode == m end,
            func = function() SetColorMode(m) end }
    end
    for _, m in ipairs(HEALTH_MODES) do
        healths[#healths + 1] = { text = HEALTH_LABELS[m], radio = true,
            checked = function() return db.healthText == m end,
            func = function() SetHealthText(m) end }
    end
    for _, p in ipairs(SIZE_PRESETS) do
        sizes[#sizes + 1] = { text = string.format("%s (%dx%d)", p.label, p.w, p.h), radio = true,
            checked = function() return db.width == p.w and db.height == p.h end,
            func = function() SetSize(p.w, p.h) end }
    end
    local entries = {
        { text = "Enabled", checkbox = true, checked = function() return db.enabled end,
          func = function() SetEnabled(not db.enabled) end },
        { text = "Colour mode", submenu = colors },
        { text = "Health text", submenu = healths },
        { text = "Size", submenu = sizes },
        { divider = true },
    }
    for _, t in ipairs(TOGGLES) do
        entries[#entries + 1] = { text = t.label, checkbox = true,
            checked = function() return db[t.key] end,
            func = function() SetToggle(t, not db[t.key]) end }
    end
    entries[#entries + 1] = { divider = true }
    entries[#entries + 1] = { text = "Reset to defaults", func = ResetSettings }
    return entries
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

_G.BetterPlatesForeverAPI = {
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
    if type(BetterPlatesForeverDB) ~= "table" then BetterPlatesForeverDB = {} end
    db = BetterPlatesForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if type(db[k]) ~= type(v) then db[k] = v end
    end
    if not IsIn(COLOR_MODES, db.colorMode) then db.colorMode = DEFAULTS.colorMode end
    if not IsIn(HEALTH_MODES, db.healthText) then db.healthText = DEFAULTS.healthText end
    db.width = math.floor(Clamp(Num(db.width) or DEFAULTS.width, MIN_W, MAX_W) + 0.5)
    db.height = math.floor(Clamp(Num(db.height) or DEFAULTS.height, MIN_H, MAX_H) + 0.5)
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED",
                     "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then BindSavedVariables() end
        return
    end
    if not db then return end
    if event == "PLAYER_LOGIN" then
        if AddOnLoaded("GaarPlates") and not warnedGaarPlates then
            warnedGaarPlates = true
            Print("GaarPlates is loaded too and draws over the same nameplates; use one of the two.")
        end
        return
    end
    if not db.enabled then return end
    if event == "NAME_PLATE_UNIT_ADDED" then
        SafeAdd(arg1)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        RemovePlate(arg1)
    elseif event == "PLAYER_ENTERING_WORLD" then
        RefreshPlates()
    elseif event == "PLAYER_TARGET_CHANGED" then
        UpdateAll()
    end
end)

-- 12.5 updates a second over the plates being styled, as in GaarPlates.
local driver = CreateFrame("Frame")
local acc = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    if not db or not db.enabled then return end
    acc = acc + elapsed
    if acc < TICK then return end
    acc = 0
    UpdateAll()
end)

SLASH_BETTERPLATESFOREVER1 = "/bpf"
SLASH_BETTERPLATESFOREVER2 = "/betterplatesforever"
SlashCmdList.BETTERPLATESFOREVER = OnSlash
