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
      threat is higher than the tank's (status 1), threat percent on the bar (option). Aggro is
      read from the first source that answers plainly (1.2.5): UnitDetailedThreatSituation,
      UnitThreatSituation, then "the mob is in combat and targeting you". Where all of them are
      secret, the client colours the bar itself from its secret boolean
      (Texture:SetVertexColorFromBoolean), where it has that.
    * Name above the bar, level right of it, health text (off, percent, current or both) in it,
      the unit's target under it (option).
    * Cast bar with spell icon, spell name and the time left; uninterruptible casts get the grey
      "shield" look (grey bar, light steel edge round the icon).
    * Your own debuffs (HARMFUL|PLAYER), up to 8 icons of 20px above the name. By default they are
      drawn by the client itself: an AuraContainer from CustomAuraContainerTemplate (Blizzard's
      12.1 aura API for addons), which reads auras in its secure code and so keeps working in
      combat, where this client refuses every aura read from addon code. BPF only supplies the
      icon, cooldown, count and time widgets. Where that API is missing or "native" is off, the
      addon reads the auras itself as in 1.1 (by index, then by spell ID) - which in practice
      only works out of combat - with a countdown that turns yellow at 8 s and red at 3 s.
    * Other players' debuffs (1.2.4, option "others", on by default): on enemy plates, after
      yours on the same row, up to 6 smaller grey icons - a second group of the same container
      with HARMFUL|!PLAYER, so no debuff is shown twice. Not where the client lacks "!".
    * Your target: scaled up to 115% with a faint ring; other plates dimmed to 55% while you have
      a target (each an option).
    * Friendly plates are left to Blizzard unless "friendly" is turned on (off by default).
    * /bpf (or /betterplatesforever) for help, status, on|off, color, health, size, friendly,
      threat, threattext, execute, debuffs, others, native, tot, dim, targetscale, reset and debug.
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
  straight back to a widget is allowed - but nothing is worked out from them: no execute tint, no
  colour by health. The health text then comes from the client's own secret-safe helpers
  (UnitHealthPercent with CurveConstants.ScaleTo100, AbbreviateNumbers, SetFormattedText) where
  it has them. Level secrets are dropped to nil at the read; threat secrets too, except the one
  "you hold aggro" boolean, which goes straight to SetVertexColorFromBoolean (see ReadThreat).
  And because secrecy travels further than issecretvalue reports, every part of a plate's update
  runs inside pcall: the first refusal switches that one part off for the session with one
  message, instead of an error twelve times a second per plate. An aura read the client refuses
  is not such a refusal: it is expected in combat, is counted (/bpf debug) and tried again on the
  next pass.
]]

local _G = _G
local ADDON_NAME = ... or "BetterPlatesForever"
local PREFIX = "|cff33ff99BetterPlatesForever|r: "
local DOT = " \194\183 "

local VERSION = "1.2.5"

local BAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"
local WHITE = "Interface\\Buttons\\WHITE8x8"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local AURA_N, AURA_SZ = 8, 20     -- debuff icons per plate, and their size
local OTHERS_N, OTHERS_SZ = 6, 15 -- other players' (and the mob's own) debuffs, after yours
local OTHERS_TIME_SIZE = 9        -- their time text
local AURA_GAP = 6                -- space between debuff icons
local AURA_ABOVE_GAP = 3        -- gap between the name text and the debuff row above it
local CAST_H = 9                  -- cast bar height
local NAME_SIZE = 11              -- name font size
local EXECUTE_PCT = 20            -- execute tint at or below this health percent
local DIM_ALPHA = 0.55            -- non-target plates while you have a target
local TARGET_SCALE = 1.15         -- your target's plate
local TICK = 0.08                 -- seconds between plate updates (12.5 Hz)
local AURA_TICK = 0.25            -- seconds between debuff scans of one plate
local MAX_SPELLS = 24             -- spell IDs remembered for the by-spell-ID debuff lookup
local MIN_W, MAX_W = 60, 250      -- health bar width bounds for /bpf size
local MIN_H, MAX_H = 6, 30        -- health bar height bounds
local SOLID = { 0.2, 0.6, 1.0 }   -- colour mode "solid"
local TIME_SIZE = 11              -- debuff time text, centred on the icon

local COLOR_MODES = { "reaction", "class", "health", "solid" }
local COLOR_LABELS = { reaction = "Reaction", class = "Class", health = "Health", solid = "Solid" }
local HEALTH_MODES = { "off", "percent", "current", "both" }
local HEALTH_LABELS = { off = "Off", percent = "Percent", current = "Current", both = "Both" }
local SIZE_PRESETS = {
    { label = "Small", w = 100, h = 10 },
    { label = "Medium", w = 120, h = 12 },
    { label = "Large", w = 140, h = 16 },
}

-- Debuff time text (1.2.3): the action-bar cooldown look - a white outlined number centred on the
-- icon, never with a seconds unit: "56", "2m", "1h", "2d" (rounded up, so 0 never shows while the
-- debuff is still on). Plain times are formatted here. Hidden (secret) times are formatted by the
-- client: a NumericRuleFormatter (C_StringUtil.CreateNumericRuleFormatter) with one breakpoint per
-- unit, handed to the AuraContainer button's duration text (SetDurationText's textFormatter) and,
-- on the fallback icons, to the Cooldown's own countdown (SetCountdownFormatter). No Lua arithmetic
-- or comparison touches a hidden duration. Where the formatter cannot be made, or does not give
-- the text expected for a few plain numbers, the client's default ("56s", "2m") is used.
local TimeText = {}   -- Plain, Formatter
do
local UNITS = { { 60, "m" }, { 3600, "h" }, { 86400, "d" } }

function TimeText.Plain(left)
    if type(left) ~= "number" or left ~= left or left <= 0 then return "" end
    local s = math.ceil(left)
    if s < 60 then return tostring(s) end
    if s < 3600 then return math.ceil(s / 60) .. "m" end
    if s < 86400 then return math.ceil(s / 3600) .. "h" end
    return math.ceil(s / 86400) .. "d"
end

local function Build(spec)
    local SU, E = _G.C_StringUtil, _G.Enum
    local up = type(E) == "table" and type(E.NumericRuleFormatRounding) == "table"
        and E.NumericRuleFormatRounding.Up or 1
    local fmt = SU.CreateNumericRuleFormatter()
    local rules = { { threshold = 0, step = 1, rounding = up, format = spec } }
    for _, u in ipairs(UNITS) do
        rules[#rules + 1] = { threshold = u[1], format = spec .. u[2],
            components = { { div = u[1], step = 1, rounding = up } } }
    end
    if type(fmt.SetBreakpoints) == "function" then
        fmt:SetBreakpoints(rules)
    else
        for _, r in ipairs(rules) do fmt:AddBreakpoint(r) end
    end
    return fmt
end

local EXPECT = { { 55.3, "56" }, { 61, "2m" }, { 3540, "59m" }, { 3600, "1h" } }
local formatter, why

-- The formatter, or false; and a line for /bpf status.
function TimeText.Formatter()
    if formatter ~= nil then return formatter, why end
    formatter, why = false, "C_StringUtil.CreateNumericRuleFormatter missing"
    local SU = _G.C_StringUtil
    if type(SU) ~= "table" or type(SU.CreateNumericRuleFormatter) ~= "function" then return false, why end
    for _, spec in ipairs({ "%d", "%.0f" }) do
        local ok, fmt = pcall(Build, spec)
        if ok and fmt then
            if type(fmt.FormatNumber) ~= "function" then
                formatter, why = fmt, "rule formatter " .. spec .. " (not checked: no FormatNumber)"
                return formatter, why
            end
            local good = true
            for _, e in ipairs(EXPECT) do
                local okF, txt = pcall(fmt.FormatNumber, fmt, e[1])
                if not okF or txt ~= e[2] then
                    good = false
                    why = "rule formatter " .. spec .. " gave " .. tostring(txt) .. " for " .. e[1]
                    break
                end
            end
            if good then
                formatter, why = fmt, "rule formatter " .. spec .. " (56 / 2m / 1h)"
                return formatter, why
            end
        else
            why = tostring(fmt)
        end
    end
    return false, why
end
end

-- The on/off settings, shared by the slash command, the status and the menu.
local TOGGLES = {
    { key = "friendly", cmd = "friendly", label = "Style friendly plates too" },
    { key = "threat", cmd = "threat", label = "Threat colouring" },
    { key = "threatText", cmd = "threattext", label = "Threat percent text" },
    { key = "execute", cmd = "execute", label = "Execute tint (20% or less)" },
    { key = "debuffs", cmd = "debuffs", label = "My debuffs" },
    { key = "others", cmd = "others", label = "Other players' debuffs (smaller, grey)" },
    { key = "native", cmd = "native", label = "Debuffs drawn by the client (in combat too)" },
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
    others = true,
    native = true,
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
local blockedWhy = {}    -- [feature] = the error that switched it off, for /bpf status
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
        tm:SetFont(_G.STANDARD_TEXT_FONT, TIME_SIZE, "OUTLINE"); tm:SetTextColor(1, 1, 1); ic.timer = tm
        -- For hidden timings only: the client draws the swipe and countdown from its own duration
        -- object. Optional, so a client without the template still gets icons.
        local okc, cd = pcall(CreateFrame, "Cooldown", nil, ic, "CooldownFrameTemplate")
        if okc and cd then
            cd:SetAllPoints()
            if cd.SetReverse then cd:SetReverse(true) end
            if cd.SetDrawEdge then cd:SetDrawEdge(false) end
            if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(false) end
            -- Its countdown numbers in the same "56 / 2m / 1h" form, where the client allows.
            if cd.SetCountdownFormatter then
                local fmt = TimeText.Formatter()
                if fmt then pcall(cd.SetCountdownFormatter, cd, fmt) end
            end
            cd:Hide()
            ic.cd = cd
        end
        BorderFrame(ic, ic:GetFrameLevel())
        ic:Hide()
        o.auraIcons[i] = ic
    end

    -- The unit's target under the bar; the debuffs sit above the name, on a frame level over the
    -- plate's bars so nothing covers them.
    o.tot = h:CreateFontString(nil, "OVERLAY"); o.tot:SetPoint("TOP", h, "BOTTOM", 0, -1)
    o.auraRow:SetPoint("BOTTOM", o.name, "TOP", 0, AURA_ABOVE_GAP)
    o.auraRow:SetFrameLevel(h:GetFrameLevel() + 6)

    ApplySize(o); SetFonts(o)
    overlays[plate] = o
    return o
end

-- ---------------------------------------------------------------------------
-- Per-feature updates. Each one runs inside pcall (see Run below); none of them may assume a
-- value is plain unless it has been checked.
-- ---------------------------------------------------------------------------

-- Threat status (UnitThreatSituation, and the second return of UnitDetailedThreatSituation):
--   nil  you are not on the mob's threat list
--   0    on the list, not tanking, your threat is below the tank's
--   1    not tanking, but your threat is higher than the tank's (you are about to pull it)
--   2    tanking insecurely: the mob is on you, but someone else has more threat
--   3    tanking securely: the mob is on you and nobody has more threat
-- So 2 and 3 are aggro (purple) and 1 is high threat (amber). Up to 1.2.4 "high" was status 2 or
-- more, which is the same as aggro, so amber never showed on its own.

-- "secret", "nil" or the plain value as text, for /bpf status. Never compares a secret.
local function Kind(v)
    if issecretvalue and issecretvalue(v) then return "secret" end
    if v == nil then return "nil" end
    return tostring(v)
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return false, "MISSING" end
    return pcall(fn, ...)
end

-- Whether you hold aggro on unit, from the first source that answers plainly:
--   a. UnitDetailedThreatSituation("player", unit): isTanking, or its status
--   b. UnitThreatSituation("player", unit): the status alone
--   c. the mob is in combat (UnitAffectingCombat) and targeting you (UnitIsUnit(unit.."target"))
-- Returns tanking, high (both true / false), pct (a plain number or nil), source (text), and,
-- only when none of them answered plainly, flag + hasFlag: the client's own secret "you hold
-- aggro" boolean (from a, else c). hasFlag says whether there is one, because a secret may not
-- even be compared with nil.
local function ReadThreat(unit)
    local flag, hasFlag, pct
    local ok, isTanking, status, p = Call(_G.UnitDetailedThreatSituation, "player", unit)
    if ok then
        pct = Num(p)
        local s = Num(status)
        if not Secret(isTanking) and isTanking ~= nil then
            local t = isTanking and true or false
            return t, (not t and s == 1) or false, pct, "UnitDetailedThreatSituation"
        end
        if s then return s >= 2, s == 1, pct, "UnitDetailedThreatSituation (status)" end
        if Secret(isTanking) then flag, hasFlag = isTanking, true end
    end

    local ok2, st = Call(_G.UnitThreatSituation, "player", unit)
    if ok2 then
        local s = Num(st)
        if s then return s >= 2, s == 1, pct, "UnitThreatSituation" end
    end

    local okC, combat = Call(_G.UnitAffectingCombat, unit)
    local okT, onMe = Call(_G.UnitIsUnit, unit .. "target", "player")
    if okC and not Secret(combat) then
        if not combat then return false, false, pct, "mob's target (mob not in combat)" end
        if okT and not Secret(onMe) then
            return onMe and true or false, false, pct, "mob's target"
        end
        if okT and not hasFlag then flag, hasFlag = onMe, true end
    end

    if hasFlag then return false, false, pct, "secret: the client colours the bar", flag, true end
    return false, false, pct, "none (no source answered)"
end

-- What each source returns for unit right now - "secret", "nil" or the value - for /bpf status.
local function ThreatDiag(unit)
    local function Show(ok, ...)
        if not ok then return "error: " .. tostring((...)) end
        local out = {}
        for i = 1, select("#", ...) do out[i] = Kind((select(i, ...))) end
        return #out > 0 and table.concat(out, "/") or "nil"
    end
    return Show(Call(_G.UnitDetailedThreatSituation, "player", unit)),
        Show(Call(_G.UnitThreatSituation, "player", unit)),
        Show(Call(_G.UnitAffectingCombat, unit)),
        Show(Call(_G.UnitIsUnit, unit .. "target", "player"))
end

-- Threat: whether you hold aggro and whether your threat is high, plus the secret flag (above).
local function UpdateThreat(o, unit)
    o.ttext:SetText("")
    if not db.threat then o.threatSource = "off (setting)"; return false, false end
    local canAttack = UnitCanAttack("player", unit)
    if not Secret(canAttack) and not canAttack then o.threatSource = "not attackable"; return false, false end
    local tanking, high, pct, source, flag, hasFlag = ReadThreat(unit)
    o.threatSource = source
    if db.threatText and pct and pct > 0 then
        o.ttext:SetText(string.format("%d%%", pct + 0.5))
    end
    return tanking, high, flag, hasFlag
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

-- Pull a colour toward its own luminance so nothing reads as harsh pure red or purple.
local function Soften(r, g, b)
    local lum = 0.3 * r + 0.59 * g + 0.11 * b
    local m = 0.28
    return r + (lum - r) * m, g + (lum - g) * m, b + (lum - b) * m
end

local AGGRO_R, AGGRO_G, AGGRO_B = 0.55, 0.38, 0.68

-- The bar coloured by the client from a secret "you hold aggro" boolean: purple when true, the
-- plate's own colour when false. Texture:SetVertexColorFromBoolean (12.x) takes the secret as it
-- is, so nothing here tests it. Counted for /bpf status; a refusal is retried next pass.
local tintStats = { used = 0, failed = 0, lastError = nil }
local aggroColor

local function SecretTint(o, flag, r, g, b)
    local h = o.health
    local tex = type(h.GetStatusBarTexture) == "function" and h:GetStatusBarTexture()
    if not tex or type(tex.SetVertexColorFromBoolean) ~= "function" or type(_G.CreateColor) ~= "function" then
        return false
    end
    if not aggroColor then aggroColor = _G.CreateColor(Soften(AGGRO_R, AGGRO_G, AGGRO_B)) end
    local c = o._tintColor
    if c and type(c.SetRGBA) == "function" then c:SetRGBA(r, g, b, 1)
    else c = _G.CreateColor(r, g, b, 1); o._tintColor = c end
    local ok, err = pcall(tex.SetVertexColorFromBoolean, tex, flag, aggroColor, c)
    if ok then
        tintStats.used = tintStats.used + 1
        o._secretTint = tex
        return true
    end
    tintStats.failed = tintStats.failed + 1
    tintStats.lastError = tostring(err)
    return false
end

local function UpdateHealth(o, unit, tanking, high, flag, hasFlag)
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
    if tanking then r, g, b = AGGRO_R, AGGRO_G, AGGRO_B -- you hold aggro
    elseif high then r, g, b = 0.8, 0.6, 0.35 end      -- high threat
    r, g, b = Soften(r, g, b)
    o.health:SetStatusBarColor(r, g, b)
    -- No plain answer on aggro: the client picks purple or this colour from its secret flag.
    local tinted = hasFlag and not tanking and SecretTint(o, flag, r, g, b)
    if not tinted and o._secretTint then
        -- Back from the secret tint: set the texture itself too, in case the bar keeps its colour.
        o._secretTint:SetVertexColor(r, g, b); o._secretTint = nil
    end
    if pct and cur <= 0 then o.ttext:SetText("") end
end

-- How the health text was last written, for /bpf status: "plain", "secret" or "none".
local healthTextPath = "none"

local function Abbrev(n)
    if _G.AbbreviateLargeNumbers then return _G.AbbreviateLargeNumbers(n) end
    return tostring(n)
end

-- Hidden health written through the client's own secret-safe helpers, as BetterFramesForever
-- does. Nothing here compares, adds or tests the values (not even "~= nil"): they go straight
-- to the client, and flags say which parts were read.
local function SecretHealthText(fs, unit, mode)
    local wantPct = mode == "percent" or mode == "both"
    local wantCur = mode == "current" or mode == "both"
    local C = _G.CurveConstants
    local curve = type(C) == "table" and C.ScaleTo100 or nil
    local pct, havePct
    if wantPct and curve ~= nil and type(_G.UnitHealthPercent) == "function" then
        pct, havePct = _G.UnitHealthPercent(unit, false, curve), true
    end
    local cur, haveCur
    if wantCur and type(_G.AbbreviateNumbers) == "function" then
        cur, haveCur = _G.AbbreviateNumbers(UnitHealth(unit)), true
    end
    local fmt, a1, a2
    if haveCur and havePct then fmt, a1, a2 = "%s  %.0f%%", cur, pct
    elseif haveCur then fmt, a1 = "%s", cur
    elseif havePct then fmt, a1 = "%.0f%%", pct end
    if not fmt then fs:SetText(""); healthTextPath = "none"; return end
    if type(fs.SetFormattedText) == "function" then
        fs:SetFormattedText(fmt, a1, a2)
    else
        fs:SetText(string.format(fmt, a1, a2))
    end
    healthTextPath = "secret"
end

-- off / percent / current / both. Plain numbers are formatted here; hidden ones go to the client.
local function UpdateHealthText(o, unit)
    local fs, mode = o.htext, db.healthText
    if mode == "off" then fs:SetText(""); return end
    if Plain(UnitIsDeadOrGhost(unit)) == true then fs:SetText(""); return end
    local mx, cur = UnitHealthMax(unit), UnitHealth(unit)
    if Secret(cur, mx) then
        fs:SetText("")
        SecretHealthText(fs, unit, mode)
        return
    end
    healthTextPath = "plain"
    cur = type(cur) == "number" and cur or 0
    mx = (type(mx) == "number" and mx > 0) and mx or 1
    if cur <= 0 then fs:SetText(""); return end
    local pct = math.floor(cur / mx * 100 + 0.5)
    if mode == "current" then fs:SetText(Abbrev(cur))
    elseif mode == "both" then fs:SetText(string.format("%s  %d%%", Abbrev(cur), pct))
    else fs:SetText(pct .. "%") end
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

-- ---------------------------------------------------------------------------
-- Your debuffs.
--
-- On this client auras are secret while you are in combat, and every aura read by index, slot or
-- instance ID from addon code is then refused with a Lua error ("auras cannot be accessed when
-- secret while tainted"). Casting a DoT puts you in combat, so a reader that only uses
-- GetAuraDataByIndex sees your DoTs never - and 1.0 even switched the whole feature off for the
-- session on that first refusal. Now:
--   1. HARMFUL|PLAYER by index, one pcall per read. C_Secrets.ShouldUnitAuraIndexBeSecret is
--      asked first where it exists, so the refusal is usually not even provoked.
--   2. When the index read is refused, every spell you cast this session (UNIT_SPELLCAST_SUCCEEDED)
--      is looked up by spell ID, which the client still allows for spells it does not keep
--      secret. isFromPlayerOrPlayerPet is never secret and keeps the lookup to yours.
--   3. Fields that come back secret go straight to widgets: the icon to SetTexture, the timing
--      to a Cooldown frame through C_UnitAuras.GetAuraDuration, the stacks through
--      C_UnitAuras.GetAuraApplicationDisplayCount. Nothing is compared or added.
-- A refused read is counted for /bpf debug and tried again next pass; it never latches.
-- ---------------------------------------------------------------------------

local auraStats = { indexRefused = 0, spellRefused = 0, paintFailed = 0, lastError = nil }
local mySpells, mySpellOrder = {}, {}   -- spell IDs you cast this session (at most MAX_SPELLS)

local function RememberSpell(id)
    id = Num(id)
    if not id or id <= 0 or mySpells[id] then return end
    mySpells[id] = true
    mySpellOrder[#mySpellOrder + 1] = id
    if #mySpellOrder > MAX_SPELLS then mySpells[table.remove(mySpellOrder, 1)] = nil end
end

local function NoteRefusal(kind, err)
    auraStats[kind] = auraStats[kind] + 1
    auraStats.lastError = tostring(err)
end

-- True only when the client says plainly that this index would be secret.
local function IndexIsSecret(unit, i)
    local S = _G.C_Secrets
    if type(S) ~= "table" or type(S.ShouldUnitAuraIndexBeSecret) ~= "function" then return false end
    local ok, secret = pcall(S.ShouldUnitAuraIndexBeSecret, unit, i, "HARMFUL|PLAYER")
    return ok and Plain(secret) == true
end

-- An aura table, nil at the end of the list, or false when the client refused the read.
local function IndexAura(unit, i)
    local C = _G.C_UnitAuras
    if type(C) == "table" and type(C.GetAuraDataByIndex) == "function" then
        local ok, a = pcall(C.GetAuraDataByIndex, unit, i, "HARMFUL|PLAYER")
        if not ok then NoteRefusal("indexRefused", a); return false end
        if type(a) ~= "table" then return nil end
        return a
    end
    if type(_G.UnitAura) == "function" then
        local ok, name, icon, count, _, duration, expiration = pcall(_G.UnitAura, unit, i, "HARMFUL|PLAYER")
        if not ok then NoteRefusal("indexRefused", name); return false end
        if Plain(name) == nil then return nil end
        return { icon = icon, applications = count, duration = duration, expirationTime = expiration }
    end
    return nil
end

-- Your aura of this spell on the unit, or nil.
local function SpellAura(unit, id)
    local C = _G.C_UnitAuras
    if type(C) ~= "table" or type(C.GetUnitAuraBySpellID) ~= "function" then return nil end
    local ok, a = pcall(C.GetUnitAuraBySpellID, unit, id)
    if not ok then NoteRefusal("spellRefused", a); return nil end
    if type(a) ~= "table" then return nil end
    -- isFromPlayerOrPlayerPet is true for any player's aura, not only yours, so the caster
    -- decides where it is known; the flag can only rule an aura out.
    local ok2, fromPlayer, src = pcall(function() return Plain(a.isFromPlayerOrPlayerPet), Plain(a.sourceUnit) end)
    if not ok2 then return a end
    if type(src) == "string" then
        if src ~= "player" and src ~= "pet" and src ~= "vehicle" then return nil end
        return a
    end
    if fromPlayer == false then return nil end
    return a
end

local function PaintCount(ic, unit, a)
    local count = a.applications
    if Secret(count) then
        ic._cnt = nil
        local C = _G.C_UnitAuras
        local id = Plain(a.auraInstanceID)
        if id and type(C) == "table" and type(C.GetAuraApplicationDisplayCount) == "function" then
            local ok, txt = pcall(C.GetAuraApplicationDisplayCount, unit, id, 2, 99)
            if ok then SetTextSafe(ic.cnt, txt); return end
        end
        ic.cnt:SetText("")
        return
    end
    count = Num(count)
    local cn = (count and count > 1) and count or 0
    if ic._cnt ~= cn then ic.cnt:SetText(cn > 0 and cn or ""); ic._cnt = cn end
end

local function PaintTime(ic, unit, a, now)
    local duration, expiration = a.duration, a.expirationTime
    if Secret(duration, expiration) then
        ic.timer:SetText("")
        local cd, C = ic.cd, _G.C_UnitAuras
        local id = Plain(a.auraInstanceID)
        if cd and id and type(C) == "table" and type(C.GetAuraDuration) == "function"
            and type(cd.SetCooldownFromDurationObject) == "function" then
            local ok, obj = pcall(C.GetAuraDuration, unit, id)
            if ok and obj ~= nil then
                cd:SetCooldownFromDurationObject(obj)
                if not cd:IsShown() then cd:Show() end
                return
            end
        end
        if cd then cd:Hide() end
        return
    end
    if ic.cd and ic.cd:IsShown() then ic.cd:Hide() end
    duration, expiration = Num(duration), Num(expiration)
    local rem = (duration and duration > 0 and expiration) and (expiration - now) or 0
    ic.timer:SetText(rem > 0 and TimeText.Plain(rem) or "")
end

local function PaintIcon(ic, unit, a, now)
    local icon = a.icon
    if Secret(icon) then
        ic.tex:SetTexture(icon); ic._icon = nil
    elseif ic._icon ~= icon then
        ic.tex:SetTexture(icon or QUESTION); ic._icon = icon
    end
    PaintCount(ic, unit, a)
    PaintTime(ic, unit, a, now)
    if not ic:IsShown() then ic:Show() end
end

-- ---------------------------------------------------------------------------
-- Native debuff icons: the client's own AuraContainer.
--
-- Blizzard's nameplate AurasFrame lives inside plate.UnitFrame, which this addon hides, and it
-- only lists auras flagged nameplateShowPersonal (unless a CVar says otherwise). Rather than
-- un-hide or re-anchor Blizzard's frames, each overlay gets its own container made from
-- CustomAuraContainerTemplate (Blizzard_AuraContainer, "allowUntaintedCreation"): the client
-- reads the unit's HARMFUL|PLAYER auras in secure code and fills buttons that this file only
-- dresses once, at creation (icon texture, Cooldown, count and time font strings). Nothing
-- here reads an aura, so secrecy does not apply. No Blizzard frame is touched.
-- ---------------------------------------------------------------------------

local NATIVE_GROUP = "bpfMine"
local OTHERS_GROUP = "bpfOthers"
local nativeStats = { created = 0, failed = 0, buttonFailed = 0, othersFailed = 0, lastError = nil }

-- Other people's debuffs: "HARMFUL|!PLAYER", every debuff not cast by you, your pet or vehicle
-- (other players' DoTs and the mob's own), where this client has filter negation (retail 12.1,
-- AuraUtil.AuraFilterNegationPrefix). Next to HARMFUL|PLAYER each debuff is in exactly one
-- group. Without it there is no way to tell yours from theirs in the container - its caster
-- flag isFromPlayerOrPlayerPet is true for every player - so plain HARMFUL would show yours
-- twice; the group is then left out and only yours are shown, as before.
local NOT_MINE = "HARMFUL|!PLAYER"
local notMineOK   -- nil until asked, then true / false
local function NotMineSupported()
    if notMineOK == nil then
        local U = _G.AuraUtil
        local ok, valid = false, nil
        if type(U) == "table" and type(U.IsValidFilterString) == "function" then
            ok, valid = pcall(U.IsValidFilterString, NOT_MINE)
        end
        notMineOK = (ok and valid == true) and true or false
    end
    return notMineOK
end

local function NativeError(kind, err)
    nativeStats[kind] = nativeStats[kind] + 1
    nativeStats.lastError = tostring(err)
end

-- Called by the container for each button it creates. Every part is optional: a button with only
-- an icon is still worth having, so each step is guarded on its own and none may throw.
-- size and timeSize per group; grey draws the icon desaturated (other people's debuffs).
local function NativeButtonInit(size, timeSize, grey)
    return function(btn)
        local ok, err = pcall(function()
            btn:SetSize(size, size)
            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            if grey then tex:SetDesaturated(true) end
            btn:SetIcon(tex)
        end)
        if not ok then NativeError("buttonFailed", err); return end
        local cd
        pcall(function()
            cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
            cd:SetAllPoints()
            if cd.SetReverse then cd:SetReverse(true) end
            if cd.SetDrawEdge then cd:SetDrawEdge(false) end
            btn:SetDurationCooldown(cd)
        end)
        -- The time left as our own text, centred and white like an action button's cooldown count,
        -- formatted by the client through TimeText's rule formatter ("56", "2m", "1h"); the
        -- container's default formatter ("56s") if the client refuses that, and the cooldown's own
        -- numbers only if the text fails altogether.
        local timed = pcall(function()
            local tm = btn:CreateFontString(nil, "OVERLAY")
            tm:SetFont(_G.STANDARD_TEXT_FONT, timeSize, "OUTLINE")
            tm:SetTextColor(1, 1, 1)
            tm:SetPoint("CENTER", btn, "CENTER", 0, 0)
            local fmt = TimeText.Formatter()
            local ok, err = false, nil
            if fmt then ok, err = pcall(btn.SetDurationText, btn, tm, { textFormatter = fmt }) end
            if ok then
                nativeStats.timeFormat = "56 / 2m / 1h"
            else
                if err then nativeStats.timeFormatError = tostring(err) end
                btn:SetDurationText(tm)
                nativeStats.timeFormat = "client default (56s, 2m)"
            end
        end)
        if cd and cd.SetHideCountdownNumbers then pcall(cd.SetHideCountdownNumbers, cd, timed and true or false) end
        pcall(function()
            local cnt = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
            cnt:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, 0)
            btn:SetApplicationCount(cnt)
        end)
        pcall(BorderFrame, btn, btn:GetFrameLevel())
    end
end

-- The overlay's container, built on first use; false once building it failed on this plate.
local function NativeContainer(o)
    if o.native ~= nil then return o.native end
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, o.frame, "CustomAuraContainerTemplate")
    if not ok or not c then
        NativeError("failed", ok and "CreateFrame returned nothing" or c)
        o.native = false
        return false
    end
    local ok2, err = pcall(function()
        -- Anchored by its bottom centre just above the name text, where the addon's own icons
        -- sit; the container sizes itself to its icons, so the row stays centred over the name.
        c:SetPoint("BOTTOM", o.name, "TOP", 0, AURA_ABOVE_GAP)
        c:SetFrameLevel(o.health:GetFrameLevel() + 6)
        c:AddAuraGroup(NATIVE_GROUP, "HARMFUL|PLAYER", {
            maxFrameCount = AURA_N,
            initializeFrame = NativeButtonInit(AURA_SZ, TIME_SIZE, false),
            layout = { elementSpacing = AURA_GAP, elementWidth = AURA_SZ, elementHeight = AURA_SZ,
                groupSpacing = AURA_GAP, layoutIndex = 1 },
        })
    end)
    if not ok2 then
        NativeError("failed", err)
        pcall(c.Hide, c)
        o.native = false
        return false
    end
    -- Other people's debuffs: on the same row, after yours, smaller and grey. Its own pcall, so a
    -- client that refuses it still shows yours. Switched on per plate in SyncNative.
    if NotMineSupported() then
        local ok3, err3 = pcall(function()
            c:AddAuraGroup(OTHERS_GROUP, NOT_MINE, {
                maxFrameCount = OTHERS_N,
                initializeFrame = NativeButtonInit(OTHERS_SZ, OTHERS_TIME_SIZE, true),
                layout = { elementSpacing = AURA_GAP - 2, elementWidth = OTHERS_SZ, elementHeight = OTHERS_SZ,
                    groupSpacing = AURA_GAP, layoutIndex = 2 },
            })
        end)
        if ok3 then
            o.nativeOthers = true
        else
            NativeError("othersFailed", err3)
        end
    end
    nativeStats.created = nativeStats.created + 1
    o.native = c
    return c
end

-- Points the container at the plate's unit (or at nothing) and switches it on or off.
local function SyncNative(o, unit, on)
    local c = o.native
    if not c then return end
    local want = (on and unit) or "none"
    if o._nativeUnit ~= want then
        local ok, err = pcall(c.SetUnit, c, want)
        if not ok then NativeError("failed", err) end
        o._nativeUnit = want
    end
    if o._nativeOn ~= on then
        pcall(c.SetEnabled, c, on and true or false)
        if on then pcall(c.Show, c) else pcall(c.Hide, c) end
        o._nativeOn = on
    end
    -- Other people's debuffs only on enemy plates, and only with the "others" option on.
    if o.nativeOthers then
        local others = (on and unit and db.others and Plain(UnitCanAttack("player", unit))) and true or false
        if o._othersOn ~= others then
            local ok, err = pcall(c.SetAuraGroupEnabled, c, OTHERS_GROUP, others)
            if not ok then NativeError("othersFailed", err) end
            o._othersOn = others
        end
    end
end

-- How many icons the container shows on this plate in a group (yours by default): a number,
-- "hidden" while the client keeps the count secret, or nil without a container.
local function NativeCount(o, group)
    local c = o and o.native
    if not c then return nil end
    local ok, n = pcall(c.GetAuraGroupFrameCount, c, group or NATIVE_GROUP)
    if not ok then return "hidden" end
    n = Num(n)
    return n or "hidden"
end

local function HideOwnIcons(o)
    for i = 1, AURA_N do
        if o.auraIcons[i]:IsShown() then o.auraIcons[i]:Hide() end
    end
    o._lastShown = 0
end

local function UpdateAuras(o, unit)
    -- The client draws them where it can; the addon's own reading is the fallback.
    local useNative = db.debuffs and db.native and NativeContainer(o)
    if o.native then SyncNative(o, unit, useNative and true or false) end
    if useNative then
        HideOwnIcons(o)
        o.auraPath, o.auraShown = "client AuraContainer", nil
        return
    end
    local now = GetTime()
    if o._auraAt and now < o._auraAt then
        -- Between scans only the plain countdowns move.
        for i = 1, (o._lastShown or 0) do
            local ic, a = o.auraIcons[i], o.auraData and o.auraData[i]
            if a and ic:IsShown() then pcall(PaintTime, ic, unit, a, now) end
        end
        return
    end
    o._auraAt = now + AURA_TICK
    o.auraData = o.auraData or {}
    wipe(o.auraData)
    local shown, seen, path = 0, {}, "none"
    local function Add(a)
        if shown >= AURA_N then return end
        local id = Plain(a.auraInstanceID)
        if id then
            if seen[id] then return end
            seen[id] = true
        end
        local ic = o.auraIcons[shown + 1]
        local ok, err = pcall(PaintIcon, ic, unit, a, now)
        if not ok then
            auraStats.paintFailed = auraStats.paintFailed + 1
            auraStats.lastError = tostring(err)
            ic:Hide()
            return
        end
        shown = shown + 1
        o.auraData[shown] = a
    end
    if db.debuffs then
        local refused = false
        for i = 1, 40 do
            if shown >= AURA_N then break end
            if IndexIsSecret(unit, i) then refused = true; break end
            local a = IndexAura(unit, i)
            if a == false then refused = true; break end
            if not a then break end
            path = "index"
            pcall(function() RememberSpell(a.spellId) end)
            Add(a)
        end
        if refused then
            path = "spell ID (auras secret)"
            for _, id in ipairs(mySpellOrder) do
                if shown >= AURA_N then break end
                local a = SpellAura(unit, id)
                if a then Add(a) end
            end
        end
    end
    o.auraPath, o.auraShown = path, shown
    for i = shown + 1, AURA_N do
        if o.auraIcons[i]:IsShown() then o.auraIcons[i]:Hide() end
    end
    if shown ~= o._lastShown then
        o._lastShown = shown
        local step = AURA_SZ + AURA_GAP
        local startX = -((shown * step - AURA_GAP) / 2) + AURA_SZ / 2
        for i = 1, shown do
            o.auraIcons[i]:ClearAllPoints()
            o.auraIcons[i]:SetPoint("CENTER", o.auraRow, "CENTER", startX + (i - 1) * step, 0)
        end
    end
end

-- Target scale, rings and dimming.
local function UpdateEmphasis(o, unit, tanking, flag, hasFlag)
    local isTarget = Plain(UnitIsUnit(unit, "target")) and true or false
    local ring, fromFlag = o.ring, false
    -- The aggro ring stays bold, since that one is a warning; the target ring is only a hint.
    if tanking then
        ring:SetBackdropBorderColor(AGGRO_R, AGGRO_G, AGGRO_B, 1); ring:Show()
    elseif db.targetScale and isTarget then
        ring:SetBackdropBorderColor(0.7, 0.7, 0.75, 0.35); ring:Show()
    elseif hasFlag and type(ring.SetAlphaFromBoolean) == "function"
        and pcall(ring.SetAlphaFromBoolean, ring, flag, 1, 0) then
        -- Aggro known only as a secret: the client shows the purple ring or hides it (alpha 0).
        ring:SetBackdropBorderColor(AGGRO_R, AGGRO_G, AGGRO_B, 1); ring:Show()
        fromFlag = true
    else
        ring:Hide()
    end
    if o._ringFromFlag and not fromFlag then ring:SetAlpha(1) end
    o._ringFromFlag = fromFlag
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
    healthtext = "write health text on nameplates",
    text = "read names and levels on nameplates",
    cast = "time cast bars on nameplates",
    debuffs = "read your debuffs on nameplates",
    emphasis = "scale or dim nameplates",
}
local FEATURE_ORDER = { "plates", "threat", "health", "healthtext", "text", "cast", "debuffs", "emphasis" }

-- What each feature leaves behind once it is switched off.
local CLEAR = {
    threat = function(o) o.ttext:SetText("") end,
    health = function(o) o.htext:SetText("") end,
    healthtext = function(o) o.htext:SetText("") end,
    text = function(o) o.name:SetText(""); o.level:SetText(""); o.tot:SetText("") end,
    cast = function(o) o.cast:Hide() end,
    debuffs = function(o)
        for i = 1, AURA_N do o.auraIcons[i]:Hide() end
        if o.native then o.native:Hide() end
    end,
    emphasis = function(o) o.ring:Hide(); o.ring:SetAlpha(1); o.frame:SetScale(1); o.frame:SetAlpha(1) end,
}

local function Latch(feature, err)
    if blocked[feature] then return end
    blocked[feature] = true
    blockedWhy[feature] = tostring(err)
    local clear = CLEAR[feature]
    if clear then
        for _, o in pairs(overlays) do pcall(clear, o) end
    end
    Print("this client will not let an addon " .. (FEATURE_LABELS[feature] or feature)
        .. " - that part is off for this session. (" .. tostring(err) .. ")")
end

local function Finish(feature, ok, ...)
    if ok then return ... end
    Latch(feature, (...))
end

local function Run(feature, fn, ...)
    if blocked[feature] then return end
    return Finish(feature, pcall(fn, ...))
end

local function UpdatePlate(o, unit)
    -- flag is a secret boolean when hasFlag is true; it is only ever handed to the client.
    local tanking, high, flag, hasFlag = Run("threat", UpdateThreat, o, unit)
    Run("health", UpdateHealth, o, unit, tanking, high, flag, hasFlag)
    Run("healthtext", UpdateHealthText, o, unit)
    Run("text", UpdateText, o, unit)
    Run("cast", UpdateCast, o, unit)
    Run("debuffs", UpdateAuras, o, unit)
    Run("emphasis", UpdateEmphasis, o, unit, tanking, flag, hasFlag)
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
    if o.native then pcall(SyncNative, o, nil, false) end
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
    o._auraAt = nil          -- a recycled plate scans its new unit at once
    HideBlizzard(o)
    o.frame:Show()
    UpdatePlate(o, unit)
end

local function RemovePlate(unit)
    local o = active[unit]
    if not o then return end
    active[unit] = nil
    o.unit = nil
    o._auraAt = nil
    if o.native then pcall(SyncNative, o, nil, false) end
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
    Print("/bpf health off | percent | current | both - health text (now: " .. (db and db.healthText or "?") .. ")")
    Print(string.format("/bpf size <width> <height> - health bar, %d-%d by %d-%d (now: %sx%s)",
        MIN_W, MAX_W, MIN_H, MAX_H, tostring(db and db.width), tostring(db and db.height)))
    local names = {}
    for _, t in ipairs(TOGGLES) do names[#names + 1] = t.cmd end
    Print("/bpf " .. table.concat(names, " | ") .. " on | off - switch a feature")
    Print("/bpf reset - every setting back to its default")
    Print("/bpf status - the current settings and what this client allows")
    Print("/bpf debug - debuff and health text state, and your target's plate")
end

local function Yes(v) return v and "yes" or "MISSING" end

local function Has(ns, fn)
    local t = _G[ns]
    return type(t) == "table" and type(t[fn]) == "function"
end

-- The overlay on your target's plate, or nil.
local function TargetOverlay()
    if not HasPlateAPI() then return nil end
    local plate = C_NamePlate.GetNamePlateForUnit("target")
    local o = plate and overlays[plate]
    if o and o.unit then return o end
end

local function FeatureState(f, on)
    if blocked[f] then return "OFF (switched off: " .. (blockedWhy[f] or "?") .. ")" end
    return on and "on" or "off (setting)"
end

-- Threat on your target's plate: which source the plate used, and what each source returns now
-- (secret, nil or the plain value). Worth running in combat, with the mob targeted.
local function PrintThreatState(o)
    local line
    if not o then
        line = "no target plate (target an enemy, in combat)"
    else
        local ok, detailed, situation, combat, onMe = pcall(ThreatDiag, o.unit)
        line = "plate uses " .. tostring(o.threatSource or "?") .. DOT .. (ok and (
            "UnitDetailedThreatSituation " .. detailed .. " (tanking/status/pct/raw/value)"
            .. DOT .. "UnitThreatSituation " .. situation
            .. DOT .. "mob in combat " .. combat .. ", targeting you " .. onMe)
            or ("read failed: " .. tostring(detailed)))
    end
    Print("threat: " .. FeatureState("threat", db.threat) .. DOT .. line)
    local tex = o and type(o.health.GetStatusBarTexture) == "function" and o.health:GetStatusBarTexture()
    Print("threat from a secret: SetVertexColorFromBoolean "
        .. (o and Yes(tex and type(tex.SetVertexColorFromBoolean) == "function") or "?")
        .. ", SetAlphaFromBoolean " .. (o and Yes(type(o.ring.SetAlphaFromBoolean) == "function") or "?")
        .. DOT .. string.format("bar tinted %d, refused %d", tintStats.used, tintStats.failed)
        .. (tintStats.lastError and (" (" .. tintStats.lastError .. ")") or ""))
end

-- One line each for the debuff icons and the health text, and two for threat.
local function PrintFeatureState()
    local o = TargetOverlay()
    local onPlate = "no target plate"
    if o then
        local n = o.auraShown
        if o.auraPath == "client AuraContainer" then n = NativeCount(o) end
        if n == "hidden" then n = "? (count kept secret by the client)" end
        onPlate = tostring(n or 0) .. " icon(s) via " .. (o.auraPath or "none")
    end
    Print("debuffs: " .. FeatureState("debuffs", db.debuffs) .. DOT .. "native " .. OnOff(db.native)
        .. DOT .. "target plate: " .. onPlate)
    local others
    if not NotMineSupported() then
        others = "not on this client (no \"!PLAYER\" filter; plain HARMFUL would show yours twice)"
    elseif not db.others then
        others = "off (setting)"
    elseif not (db.debuffs and db.native) then
        others = "on, but only drawn by the client's container (debuffs and native on)"
    else
        local n = "no target plate"
        if o and o.nativeOthers then
            n = NativeCount(o, OTHERS_GROUP)
            if n == "hidden" then n = "?" end
            n = tostring(n or 0) .. " icon(s) on the target plate"
            if not o._othersOn then n = n .. " (not an enemy)" end
        elseif o then
            n = "group refused on this plate"
        end
        others = "on (" .. NOT_MINE .. ")" .. DOT .. n
    end
    Print("other players' debuffs: " .. others)
    Print("health text: " .. db.healthText .. DOT .. FeatureState("healthtext", db.healthText ~= "off")
        .. DOT .. "last written from " .. healthTextPath .. " values")
    PrintThreatState(o)
end

local function CVarValue(name)
    local C = _G.C_CVar
    if type(C) ~= "table" or type(C.GetCVar) ~= "function" then return "?" end
    local ok, v = pcall(C.GetCVar, name)
    v = ok and Plain(v) or nil
    return v == nil and "?" or tostring(v)
end

local function PrintDebug()
    PrintFeatureState()
    Print(string.format("client AuraContainer: template %s, AuraContainerSortMethod %s, C_AuraContainerUtil %s;"
        .. " containers built %d, failed %d, buttons failed %d",
        Yes(type(_G.CustomAuraContainerGroupDefaultOptions) == "table"),
        Yes(type(_G.AuraContainerSortMethod) == "table"),
        Yes(type(_G.C_AuraContainerUtil) == "table"),
        nativeStats.created, nativeStats.failed, nativeStats.buttonFailed))
    if nativeStats.othersFailed > 0 then Print("other-debuff group refused: " .. nativeStats.othersFailed .. " time(s)") end
    if nativeStats.lastError then Print("last AuraContainer error: " .. nativeStats.lastError) end
    local _, fmtWhy = TimeText.Formatter()
    Print("debuff time text: " .. tostring(fmtWhy)
        .. (nativeStats.timeFormat and (DOT .. "on the client's icons: " .. nativeStats.timeFormat) or "")
        .. (nativeStats.timeFormatError and (" (formatter refused: " .. nativeStats.timeFormatError .. ")") or ""))
    local o = TargetOverlay()
    local uf = o and o.plate and o.plate.UnitFrame
    local af = type(uf) == "table" and uf.AurasFrame
    Print("Blizzard plate AurasFrame: " .. (af and "present, hidden with plate.UnitFrame (BPF does not touch it)"
            or (o and "MISSING" or "no target plate"))
        .. DOT .. "CVars (read only): nameplateEnemyNpcAuraDisplay " .. CVarValue("nameplateEnemyNpcAuraDisplay")
        .. ", nameplateShowAllPersonalAuras " .. CVarValue("nameplateShowAllPersonalAuras")
        .. ", nameplateAuraScale " .. CVarValue("nameplateAuraScale"))
    Print(string.format("aura reads refused this session: by index %d, by spell ID %d; icons failed to draw: %d",
        auraStats.indexRefused, auraStats.spellRefused, auraStats.paintFailed))
    if auraStats.lastError then Print("last aura refusal: " .. auraStats.lastError) end
    Print("spells remembered for the spell-ID lookup: " .. #mySpellOrder
        .. (#mySpellOrder > 0 and (" (" .. table.concat(mySpellOrder, ", ") .. ")") or " - cast your DoT once"))
    Print("aura API: GetAuraDataByIndex " .. Yes(Has("C_UnitAuras", "GetAuraDataByIndex"))
        .. "   GetUnitAuraBySpellID " .. Yes(Has("C_UnitAuras", "GetUnitAuraBySpellID"))
        .. "   GetAuraDuration " .. Yes(Has("C_UnitAuras", "GetAuraDuration"))
        .. "   ShouldUnitAuraIndexBeSecret " .. Yes(Has("C_Secrets", "ShouldUnitAuraIndexBeSecret")))
    local C = _G.CurveConstants
    Print("health text API: UnitHealthPercent " .. Yes(type(_G.UnitHealthPercent) == "function")
        .. "   ScaleTo100 " .. Yes(type(C) == "table" and C.ScaleTo100 ~= nil)
        .. "   AbbreviateNumbers " .. Yes(type(_G.AbbreviateNumbers) == "function"))
    local o = TargetOverlay()
    if o then
        local u = o.unit
        local ok, mx, cur = pcall(function() return UnitHealthMax(u), UnitHealth(u) end)
        Print("target health values: " .. ((ok and Secret(cur, mx)) and "hidden (secret)" or "plain"))
    end
end

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
        .. "/" .. Yes(type(_G.UnitThreatSituation) == "function")
        .. "   hidden values: " .. (issecretvalue and "possible" or "no"))
    Print("plates styled now: " .. CountActive())
    local off = {}
    for _, f in ipairs(FEATURE_ORDER) do if blocked[f] then off[#off + 1] = f end end
    if #off > 0 then
        Print("switched off by this client this session: " .. table.concat(off, ", "))
        for _, f in ipairs(off) do Print("  " .. f .. ": " .. (blockedWhy[f] or "?")) end
    end
    PrintFeatureState()
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
    elseif cmd == "debug" then
        PrintDebug()
    elseif cmd == "on" or cmd == "off" then
        SetEnabled(cmd == "on")
    elseif cmd == "color" or cmd == "colour" then
        if IsIn(COLOR_MODES, rest) then SetColorMode(rest)
        else Print("/bpf color reaction | class | health | solid (now: " .. db.colorMode .. ")") end
    elseif cmd == "health" then
        if IsIn(HEALTH_MODES, rest) then SetHealthText(rest)
        else Print("/bpf health off | percent | current | both (now: " .. db.healthText .. ")") end
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
                     "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
                     "UNIT_THREAT_SITUATION_UPDATE", "UNIT_THREAT_LIST_UPDATE" }) do
    pcall(events.RegisterEvent, events, e)
end
-- Your own casts, remembered for the by-spell-ID debuff lookup (only "player" is wanted).
if not (events.RegisterUnitEvent and pcall(events.RegisterUnitEvent, events, "UNIT_SPELLCAST_SUCCEEDED", "player")) then
    pcall(events.RegisterEvent, events, "UNIT_SPELLCAST_SUCCEEDED")
end
events:SetScript("OnEvent", function(_, event, arg1, _, arg3)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" then pcall(RememberSpell, arg3) end
        return
    end
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
    elseif event == "UNIT_THREAT_SITUATION_UPDATE" or event == "UNIT_THREAT_LIST_UPDATE" then
        -- At once rather than on the next tick: that plate, or every plate for "player" / no unit.
        if Secret(arg1) then UpdateAll(); return end
        local o = type(arg1) == "string" and active[arg1]
        if o then
            UpdatePlate(o, arg1)
        elseif arg1 == nil or arg1 == "player" then
            UpdateAll()
        end
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
