--[[
  BetterCastbarsForever - movable cast bars for player, target, focus and pet on WoW Forever.

  A standalone port of GaarCast to the Better...Forever conventions. It draws its own cast bars
  and does these things and nothing else:

    * Bars for player, target and focus (on by default; focus only where the client has a focus
      unit) and pet (off by default). Each shows the spell icon with a 1px border, the spell name
      on the left, a timer on the right ("remain / total" or "remain"), a spark at the cast edge,
      the name of the cast's target under the bar, and on the player bar a latency safe-zone.
    * Colours: yellow for a cast, green for a channel, grey for a cast nothing can interrupt (its
      icon also gets a steel border and a small shield), a red flash on a failed or interrupted
      cast, and a 0.3 s fade-out when a cast finishes.
    * Own position by default: drag a bar to move it, drag the grip in its bottom-right corner to
      resize it. Positions and sizes are saved per bar, account-wide, in BetterCastbarsForeverDB.
      "Follow Blizzard (Edit Mode)" (off by default) anchors each bar to Blizzard's own cast bar
      for that unit instead; dragging or resizing a bar turns following off again.
    * Lock (no dragging, no grips), test mode (a looping fake cast on every enabled bar, so the
      bars can be placed out of combat) and reset (positions and sizes).
    * Blizzard's own cast bar is hidden, for the bars this addon replaces only, with
      HookScript("OnShow") -> Hide. Turning a bar off lets Blizzard's show again at its next cast.
    * A swing timer (1.1, on by default): thin bars stacked right under the player cast bar -
      main hand, off hand while dual-wielding, ranged while Auto Shot / Shoot repeats - that fill
      over each swing and show the seconds left. Shown in combat or while a swing runs, faded out
      otherwise, and looped in test mode. See the swing timer section below for how swings are
      detected on a client whose combat log addons cannot read.
    * /bcf for help, status, lock, unlock, test, reset, follow, bar, latency, texture, font,
      timer and swing.
    * BetterCastbarsForeverAPI, a small global table for BetterGaarForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The addon runs exactly the same
      without the hub; the API only exposes the settings the slash command already changes.

  Everything GaarCast learnt about secret values on retail-shaped clients carries over:

    * Cast timings, GetNetStats and frame geometry can come back secret. Each is checked with
      issecretvalue before it is compared, added or tested for truth (`w or 140` is a boolean
      test too), and a secret is treated as no value at all.
    * Blizzard's geometry is never copied without that check. Copying a secret size or anchoring
      to a frame whose geometry is secret makes our own frame's geometry secret, and Blizzard's
      Backdrop code then fails inside their file. Where Blizzard's geometry is missing or secret
      the bar falls back to its own default place and size.
    * A position or size that comes back secret is never saved (the client writes a secret as
      nil), and saved entries with missing fields are purged on load.
    * issecretvalue does not flag everything: secrecy travels through arithmetic. So every bar's
      per-frame update and event handling runs under pcall, and the first refusal switches that
      one bar off with a single chat line, instead of an error twelve times a second.
    * Blizzard's cast bars are never restyled, re-anchored or written to. Writing to their frames
      taints them, and their own cast code then cannot read the timings this client hides. The
      only touch is HookScript("OnShow") with a Hide(); which frames are hooked is kept in a
      table of our own, not as a field on theirs.
]]

local _G = _G
local ADDON_NAME = ... or "BetterCastbarsForever"
local PREFIX = "|cff33ff99BetterCastbarsForever|r: "
local DOT = " \194\183 "

local VERSION = "1.1.2"

local FLAT = "Interface\\Buttons\\WHITE8x8"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local SHIELD = "Interface\\Icons\\INV_Shield_06"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local TEST_ICON = "Interface\\Icons\\Spell_Fire_FlameBolt"

local TEXTURES = {
    { key = "blizzard", label = "Blizzard", path = "Interface\\TargetingFrame\\UI-StatusBar" },
    { key = "smooth",   label = "Smooth",   path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
    { key = "flat",     label = "Flat",     path = FLAT },
}
local FONT_SIZES = { 9, 11, 13 }
local TIMERS = {
    { key = "total",  label = "remain / total" },
    { key = "remain", label = "remain only" },
}

local COLOR_CAST    = { 1.0, 0.7, 0.0 }
local COLOR_CHANNEL = { 0.2, 0.8, 0.3 }
local COLOR_LOCKED  = { 0.6, 0.6, 0.6 }    -- not interruptible
local COLOR_FAILED  = { 0.85, 0.1, 0.1 }
local BORDER_NORMAL = { 0.35, 0.37, 0.42 }
local BORDER_STEEL  = { 0.78, 0.82, 0.92 }

local FADE_TIME = 0.3     -- seconds of fade-out when a cast finishes
local FAIL_HOLD = 0.5     -- seconds the red flash holds before it fades
local TEST_CAST = 3.0     -- seconds per looping test cast
local MIN_W, MIN_H, MAX_W, MAX_H = 80, 10, 600, 60

-- Order matters: it is the order of the menu, the status line and the help.
local ALL_UNITS = { "player", "target", "focus", "pet" }
local LABEL = { player = "Player", target = "Target", focus = "Focus", pet = "Pet" }

-- Own default size per bar.
local DEFAULT_SIZE = {
    player = { 240, 20 },
    target = { 180, 16 },
    focus  = { 170, 16 },
    pet    = { 150, 14 },
}

-- Own default place, relative to UIParent, used when nothing is saved and the unit frame's
-- place cannot be read: the player bar bottom-centre above the action bars, the others roughly
-- where their unit frames sit in Blizzard's default layout.
local DEFAULT_POINT = {
    player = { "BOTTOM", 0, 190 },
    target = { "CENTER", 250, -120 },
    focus  = { "CENTER", -250, 120 },
    pet    = { "CENTER", -250, -150 },
}

-- The unit frame each non-player bar is placed under by default, when its place can be read.
local UNIT_FRAME = { target = "TargetFrame", focus = "FocusFrame", pet = "PetFrame" }

local DEFAULTS = {
    locked = false,
    follow = false,
    latency = true,
    texture = "blizzard",
    fontSize = 11,
    timer = "total",
    swingTimer = true,
    swingRanged = true,
    swingOffhand = true,
}
local DEFAULT_BARS = { player = true, target = true, focus = true, pet = false }

-- Every key BetterCastbarsForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = {
    locked = true, follow = true, latency = true, texture = true, fontSize = true, timer = true,
    bars = true, positions = true, sizes = true,
    swingTimer = true, swingRanged = true, swingOffhand = true,
}

local db                 -- BetterCastbarsForeverDB, bound at ADDON_LOADED (never at file scope)
local UNITS = {}         -- the units this client has bars for (focus only where it exists)
local bars = {}          -- [unit] = our bar frame
local blocked = {}       -- [unit] = error text, once the client has refused that bar
local hooked = {}        -- [Blizzard frame] = true, once its OnShow is hooked
local testing = false
local conflictWarned = false
local driver             -- the one OnUpdate frame that runs every bar

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end

local function OnOff(v) return v and "on" or "off" end

-- Where the client hides a value it hands back a secret, which can be neither compared, used in
-- a sum nor tested for truth. issecretvalue exists only where that can happen.
local issecretvalue = _G.issecretvalue
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) and true or false
end

local function Secret(...)
    if not issecretvalue then return false end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return true end
    end
    return false
end

-- A plain number, or nil for a secret, a non-number or NaN.
local function Num(v)
    if IsSecret(v) then return nil end
    if type(v) ~= "number" or v ~= v then return nil end
    return v
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Whether an addon is loaded: C_AddOns on newer clients, the old global otherwise.
local function AddOnLoaded(name)
    local c = _G.C_AddOns
    if type(c) == "table" and type(c.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(c.IsAddOnLoaded, name)
        if ok and not IsSecret(loaded) and loaded then return true end
    end
    if type(_G.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(_G.IsAddOnLoaded, name)
        if ok and not IsSecret(loaded) and loaded then return true end
    end
    return false
end

local function TexturePath(key)
    for _, t in ipairs(TEXTURES) do
        if t.key == key then return t.path end
    end
    return TEXTURES[1].path
end

local function IsTextureKey(key)
    for _, t in ipairs(TEXTURES) do
        if t.key == key then return true end
    end
    return false
end

local function IsFontSize(n)
    for _, s in ipairs(FONT_SIZES) do
        if s == n then return true end
    end
    return false
end

local function IsTimerKey(key)
    for _, t in ipairs(TIMERS) do
        if t.key == key then return true end
    end
    return false
end

local function HasUnit(u)
    for _, x in ipairs(UNITS) do
        if x == u then return true end
    end
    return false
end

local function SetSolid(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
end

local function SetSizeBounds(f, minW, minH, maxW, maxH)
    if f.SetResizeBounds then f:SetResizeBounds(minW, minH, maxW, maxH)
    elseif f.SetMinResize then f:SetMinResize(minW, minH); f:SetMaxResize(maxW, maxH) end
end

-- Focus only exists on some clients; detect it instead of assuming.
local HAS_FOCUS = (function()
    if type(_G.CreateFrame) ~= "function" then return false end
    local probe = CreateFrame("Frame")
    local ok = pcall(probe.RegisterEvent, probe, "PLAYER_FOCUS_CHANGED")
    if ok then pcall(probe.UnregisterAllEvents, probe) end
    return ok and _G.FocusFrame ~= nil
end)()

for _, u in ipairs(ALL_UNITS) do
    if u ~= "focus" or HAS_FOCUS then UNITS[#UNITS + 1] = u end
end

-- ---------------------------------------------------------------------------
-- Blizzard's cast bars: found by name, read only after a secret check, never written to
-- ---------------------------------------------------------------------------

local function Field(parentName, key)
    local p = _G[parentName]
    if type(p) == "table" then
        local ok, v = pcall(function() return p[key] end)
        if ok then return v end
    end
end

local function BlizzBar(unit)
    local candidates
    if unit == "player" then
        candidates = { _G.PlayerCastingBarFrame, _G.CastingBarFrame }
    elseif unit == "target" then
        candidates = { _G.TargetFrameSpellBar, Field("TargetFrame", "spellbar") }
    elseif unit == "focus" then
        candidates = { _G.FocusFrameSpellBar, Field("FocusFrame", "spellbar") }
    elseif unit == "pet" then
        candidates = { _G.PetCastingBarFrame }
    else
        return nil
    end
    for i = 1, 2 do
        local f = candidates[i]
        if type(f) == "table" and type(f.HookScript) == "function" then return f end
    end
end

-- A Blizzard frame's geometry is usable only when none of it is secret.
local function GeometryReadable(frame)
    if type(frame) ~= "table" then return false end
    local ok, w, h = pcall(function() return frame:GetWidth(), frame:GetHeight() end)
    if not ok or Secret(w, h) then return false end
    local ok2, cx, cy = pcall(function() return frame:GetCenter() end)
    if not ok2 or Secret(cx, cy) then return false end
    return Num(w) ~= nil and Num(h) ~= nil
end

-- Edit Mode shows Blizzard's cast bars so they can be placed; they are left alone while it is up.
local function EditModeActive()
    local em = _G.EditModeManagerFrame
    if type(em) ~= "table" or type(em.IsEditModeActive) ~= "function" then return false end
    local ok, active = pcall(em.IsEditModeActive, em)
    return ok and not IsSecret(active) and active and true or false
end

local function BarEnabled(u)
    return db ~= nil and db.bars[u] == true and HasUnit(u)
end

-- Hide Blizzard's bar for a unit we replace. The hook is installed once, the first time the bar
-- is enabled, and asks the setting every time, so turning our bar off lets theirs show again.
local function HookBlizzard(u)
    local bf = BlizzBar(u)
    if not bf then return end
    if not hooked[bf] then
        local ok = pcall(bf.HookScript, bf, "OnShow", function(self)
            if BarEnabled(u) and not EditModeActive() then self:Hide() end
        end)
        if ok then hooked[bf] = true end
    end
    if BarEnabled(u) and not EditModeActive() then
        local ok, shown = pcall(bf.IsShown, bf)
        if ok and not IsSecret(shown) and shown then pcall(bf.Hide, bf) end
    end
end

-- ---------------------------------------------------------------------------
-- Reading a cast
-- ---------------------------------------------------------------------------

-- Returns: name, icon, startMs, endMs, notInterruptible, castID - or nil for no cast, or for a
-- cast whose timings this client will not show (secret timings cannot be timed, so the bar
-- stays hidden rather than erroring). Detects the return shape instead of assuming it:
--   modern:   name, text, texture, startMs, endMs, isTradeSkill, castID, notInterruptible
--             (channel: name, text, texture, startMs, endMs, isTradeSkill, notInterruptible)
--   pre-Cata: name, nameSubtext, text, texture, startMs, endMs, isTradeSkill, castID, notInterruptible
local function ReadCast(unit, channel)
    local fn = channel and _G.UnitChannelInfo or _G.UnitCastingInfo
    if type(fn) ~= "function" then return nil end
    local r = { fn(unit) }
    local name = r[1]
    if not IsSecret(name) and not name then return nil end
    local icon, startMs, endMs, notInt, castID
    if type(r[4]) == "number" and type(r[5]) == "number" then
        icon, startMs, endMs = r[3], r[4], r[5]
        if channel then notInt = r[7] else castID, notInt = r[7], r[8] end
    else
        icon, startMs, endMs = r[4], r[5], r[6]
        if channel then notInt = r[8] else castID, notInt = r[8], r[9] end
    end
    startMs, endMs = Num(startMs), Num(endMs)
    if not startMs or not endMs then return nil end
    -- A secret boolean cannot even be tested; read it as "interruptible".
    if IsSecret(notInt) then notInt = nil end
    if IsSecret(castID) then castID = nil end
    return name, icon, startMs, endMs, notInt and true or false, castID
end

local function CastInfo(unit)
    local name, icon, s, e, notInt, castID = ReadCast(unit, false)
    if s then return name, icon, s, e, notInt, false, castID end
    name, icon, s, e, notInt = ReadCast(unit, true)
    if s then return name, icon, s, e, notInt, true, nil end
    return nil
end

-- No API for a cast's target on this client: best effort is the unit's own target.
local function CastTargetName(unit)
    local tu = (unit == "player") and "target" or (unit .. "target")
    local okE, exists = pcall(_G.UnitExists, tu)
    if not okE or IsSecret(exists) or not exists then return nil end
    local okS, same = pcall(_G.UnitIsUnit, tu, unit)
    if okS and not IsSecret(same) and same then return nil end
    local okN, name = pcall(_G.UnitName, tu)
    if okN then return name end   -- may be secret: only ever handed to SetText
end

-- ---------------------------------------------------------------------------
-- The bars
-- ---------------------------------------------------------------------------

local function ApplyFonts(f)
    local s = db and db.fontSize or DEFAULTS.fontSize
    local font = _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    f.name:SetFont(font, s, "OUTLINE")
    f.time:SetFont(font, s, "OUTLINE")
    f.target:SetFont(font, math.max(8, s - 1), "OUTLINE")
end

local function ApplyTexture(f)
    f.bar:SetStatusBarTexture(TexturePath(db and db.texture))
end

-- Icon and spark follow the bar's height. Our frame's size is always set from our own numbers,
-- but it is read back through Num all the same.
local function ApplyInnerSize(f)
    local h = Num(f:GetHeight()) or DEFAULT_SIZE[f.unit][2]
    f.icon:SetSize(h, h)
    f.shield:SetSize(math.max(8, math.floor(h * 0.55)), math.max(8, math.floor(h * 0.55)))
    f.spark:SetHeight(h * 2)
end

local function ApplyLock(f)
    local locked = db and db.locked
    f:EnableMouse(not locked)
    if locked then f.grip:Hide() else f.grip:Show() end
end

local function SetIconLook(f, notInt)
    local c = notInt and BORDER_STEEL or BORDER_NORMAL
    f.iconBorder:SetBackdropBorderColor(c[1], c[2], c[3], 1)
    if notInt then f.shield:Show() else f.shield:Hide() end
end

local function SetBarColor(f)
    local c
    if f.state == "failed" then c = COLOR_FAILED
    elseif f.notInt then c = COLOR_LOCKED
    elseif f.channel then c = COLOR_CHANNEL
    else c = COLOR_CAST end
    f.bar:SetStatusBarColor(c[1], c[2], c[3])
end

-- Where a non-player bar sits by default: centred under its unit frame, if that frame's place
-- can be read without a secret; otherwise the fixed default. The numbers are read, checked and
-- copied into a UIParent anchor, so nothing of Blizzard's frame is inherited.
local function DefaultAnchor(u)
    local d = DEFAULT_POINT[u]
    local uf = UNIT_FRAME[u] and _G[UNIT_FRAME[u]]
    local parent = _G.UIParent
    if type(uf) == "table" and parent then
        local ok, x, y = pcall(function()
            local cx = uf:GetCenter()
            local bottom = uf:GetBottom()
            local s, ps = uf:GetEffectiveScale(), parent:GetEffectiveScale()
            if Secret(cx, bottom, s, ps) then return nil end
            cx, bottom, s, ps = Num(cx), Num(bottom), Num(s), Num(ps)
            if not (cx and bottom and s and ps) or ps <= 0 then return nil end
            return cx * s / ps, bottom * s / ps - 8
        end)
        if ok and Num(x) and Num(y) then
            return "TOP", parent, "BOTTOMLEFT", x, y
        end
    end
    return d[1], parent, d[1], d[2], d[3]
end

-- Place and size one bar: Blizzard's bar when following and its geometry is readable, else the
-- saved position, else our own default.
local function ApplyAnchor(f)
    local u = f.unit
    local size = db and db.sizes[u]
    local d = DEFAULT_SIZE[u]
    if size then f:SetSize(size.w, size.h) else f:SetSize(d[1], d[2]) end

    f:ClearAllPoints()
    local blizz = db and db.follow and BlizzBar(u)
    local pos = db and db.positions[u]
    if blizz and GeometryReadable(blizz) then
        f.anchoredTo = "blizzard"
        f:SetPoint("CENTER", blizz, "CENTER", 0, 0)
    elseif pos then
        f.anchoredTo = "saved"
        f:SetPoint("CENTER", _G.UIParent, "CENTER", pos.x, pos.y)
    else
        f.anchoredTo = "default"
        f:SetPoint(DefaultAnchor(u))
    end
    ApplyInnerSize(f)
end

local function ApplyAll()
    for _, u in ipairs(UNITS) do
        local f = bars[u]
        if f then
            ApplyAnchor(f)
            ApplyFonts(f)
            ApplyTexture(f)
            ApplyLock(f)
        end
    end
end

-- Save where a bar now is, as an offset of its centre from UIParent's centre. Every number is
-- checked first: a secret written to SavedVariables comes back as nil, which is worse than
-- keeping the last good value. Returns true when it was saved.
local function SaveGeometry(f)
    local parent = _G.UIParent
    local ok, x, y, w, h = pcall(function()
        local cx, cy = f:GetCenter()
        local ux, uy = parent:GetCenter()
        local s, ps = f:GetEffectiveScale(), parent:GetEffectiveScale()
        local fw, fh = f:GetWidth(), f:GetHeight()
        if Secret(cx, cy, ux, uy, s, ps, fw, fh) then return nil end
        cx, cy, ux, uy, s, ps = Num(cx), Num(cy), Num(ux), Num(uy), Num(s), Num(ps)
        fw, fh = Num(fw), Num(fh)
        if not (cx and cy and ux and uy and s and ps and fw and fh) or ps <= 0 then return nil end
        return cx * s / ps - ux, cy * s / ps - uy, fw, fh
    end)
    if not ok or not (Num(x) and Num(y) and Num(w) and Num(h)) then
        Print("this client will not report the " .. f.unit .. " bar's position, so it was not saved.")
        ApplyAnchor(f)
        return false
    end
    db.positions[f.unit] = { x = math.floor(x * 10 + 0.5) / 10, y = math.floor(y * 10 + 0.5) / 10 }
    db.sizes[f.unit] = { w = math.floor(Clamp(w, MIN_W, MAX_W) + 0.5), h = math.floor(Clamp(h, MIN_H, MAX_H) + 0.5) }
    ApplyAnchor(f)
    return true
end

-- Moving or resizing a bar by hand is an unambiguous request to place it there, so it wins
-- over following rather than being refused.
local function AfterHandPlacement(f, what)
    pcall(f.SetUserPlaced, f, false)
    -- Following is switched off before the save, so the bar is re-anchored to its new saved
    -- place rather than back onto Blizzard's; then the other bars leave Blizzard's too.
    local wasFollowing = db.follow
    db.follow = false
    SaveGeometry(f)
    if wasFollowing then
        Print("stopped following Blizzard's cast bars - you " .. what .. " one by hand. /bcf follow on turns it back on.")
        ApplyAll()
    end
end

local function MakeBar(u)
    local f = CreateFrame("Frame", "BetterCastbarsForever_" .. u, _G.UIParent, "BackdropTemplate")
    f.unit = u
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetResizable(true)
    SetSizeBounds(f, MIN_W, MIN_H, MAX_W, MAX_H)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if db and not db.locked then self.moving = true; self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        if not self.moving then return end
        self.moving = nil
        self:StopMovingOrSizing()
        AfterHandPlacement(self, "moved")
    end)
    f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
                    insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    f:SetBackdropColor(0, 0, 0, 0.6)
    f:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("RIGHT", f, "LEFT", -3, 0)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    f.iconBorder = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.iconBorder:SetPoint("TOPLEFT", f.icon, "TOPLEFT", -1, 1)
    f.iconBorder:SetPoint("BOTTOMRIGHT", f.icon, "BOTTOMRIGHT", 1, -1)
    f.iconBorder:SetBackdrop({ edgeFile = FLAT, edgeSize = 1 })

    -- The shield sits on the icon's corner for casts nothing can interrupt.
    f.shield = f.iconBorder:CreateTexture(nil, "OVERLAY")
    f.shield:SetTexture(SHIELD)
    f.shield:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.shield:SetPoint("BOTTOMRIGHT", f.icon, "BOTTOMRIGHT", 3, -3)
    f.shield:Hide()

    f.bar = CreateFrame("StatusBar", nil, f)
    f.bar:SetPoint("TOPLEFT", 1, -1)
    f.bar:SetPoint("BOTTOMRIGHT", -1, 1)
    f.bar:SetMinMaxValues(0, 1)
    f.bar:SetValue(0)

    -- Latency safe-zone: the last <latency> ms of the player's cast, at the right end.
    f.lag = f.bar:CreateTexture(nil, "OVERLAY")
    SetSolid(f.lag, 1, 0.1, 0.1, 0.35)
    f.lag:SetPoint("TOPRIGHT")
    f.lag:SetPoint("BOTTOMRIGHT")
    f.lag:SetWidth(1)
    f.lag:Hide()

    f.spark = f.bar:CreateTexture(nil, "OVERLAY")
    f.spark:SetTexture(SPARK)
    f.spark:SetBlendMode("ADD")
    f.spark:SetWidth(16)
    f.spark:Hide()

    f.time = f.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.time:SetPoint("RIGHT", -4, 0)
    f.time:SetJustifyH("RIGHT")
    f.name = f.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.name:SetPoint("LEFT", 4, 0)
    f.name:SetPoint("RIGHT", f.time, "LEFT", -4, 0)
    f.name:SetJustifyH("LEFT")
    if f.name.SetWordWrap then f.name:SetWordWrap(false) end
    -- Under the bar, the way a nameplate puts the unit's target under its health bar.
    f.target = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.target:SetPoint("TOP", f, "BOTTOM", 0, -2)
    f.target:SetJustifyH("CENTER")
    f.target:SetTextColor(1, 0.9, 0.6)

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(12, 12)
    grip:SetPoint("BOTTOMRIGHT", 0, 0)
    grip:SetFrameLevel(f.bar:GetFrameLevel() + 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        if db and not db.locked then f.sizing = true; f:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
        if not f.sizing then return end
        f.sizing = nil
        f:StopMovingOrSizing()
        AfterHandPlacement(f, "resized")
    end)
    f.grip = grip
    f:SetScript("OnSizeChanged", function(self) pcall(ApplyInnerSize, self) end)

    ApplyFonts(f)
    ApplyTexture(f)
    ApplyAnchor(f)
    ApplyLock(f)
    f:Hide()
    return f
end

-- ---------------------------------------------------------------------------
-- Cast states. f.state is nil (idle), "cast", "failed" or "fade". Test casts are ordinary
-- casts with f.test set.
-- ---------------------------------------------------------------------------

local function ClearBar(f)
    f.state, f.test, f.startMs, f.endMs, f.lagFrac, f.castID = nil, nil, nil, nil, nil, nil
    f.lag:Hide()
    f.spark:Hide()
    f:SetAlpha(1)
    f:Hide()
end

local function LatencyFraction(durMs)
    if not (db and db.latency) or type(_G.GetNetStats) ~= "function" then return nil end
    local ok, _, _, home, world = pcall(_G.GetNetStats)
    if not ok then return nil end
    local lag = Num(world) or Num(home)
    if not lag or lag <= 0 or durMs <= 0 then return nil end
    return math.min(lag / durMs, 1)
end

local function BeginCast(f, name, icon, startMs, endMs, notInt, channel, castID, test)
    f.state, f.test = "cast", test
    f.startMs, f.endMs, f.channel, f.notInt, f.castID = startMs, endMs, channel, notInt, castID
    f:SetAlpha(1)
    ApplyTexture(f)
    if IsSecret(icon) or icon then f.icon:SetTexture(icon) else f.icon:SetTexture(QUESTION) end
    f.name:SetText(name)
    SetBarColor(f)
    SetIconLook(f, notInt)
    f.lagFrac = nil
    if f.unit == "player" and not channel then f.lagFrac = LatencyFraction(endMs - startMs) end
    if not f.lagFrac then f.lag:Hide() end
    f.bar:SetValue(channel and 1 or 0)
    f:Show()
end

local function StartCast(f)
    local name, icon, startMs, endMs, notInt, channel, castID = CastInfo(f.unit)
    if not startMs then
        if f.state == "cast" and not f.test then ClearBar(f) end
        return
    end
    BeginCast(f, name, icon, startMs, endMs, notInt, channel, castID, nil)
    f.target:SetText(CastTargetName(f.unit))
end

local TEST_STYLE = {
    player = { channel = false, notInt = false },
    target = { channel = false, notInt = false },
    focus  = { channel = false, notInt = true },
    pet    = { channel = true,  notInt = false },
}

local function StartTestCast(f)
    local now = GetTime() * 1000
    local style = TEST_STYLE[f.unit]
    BeginCast(f, "Test: " .. LABEL[f.unit], TEST_ICON, now, now + TEST_CAST * 1000,
        style.notInt, style.channel, nil, true)
    f.target:SetText("Target Dummy")
end

local function FinishCast(f)
    f.startMs, f.endMs = nil, nil
    f.bar:SetValue(f.channel and 0 or 1)
    f.spark:Hide()
    f.state, f.fadeStart = "fade", GetTime()
end

local function FailCast(f, text)
    f.startMs, f.endMs = nil, nil
    f.spark:Hide()
    f.lag:Hide()
    f.state = "failed"
    SetBarColor(f)
    f.bar:SetValue(1)
    f.name:SetText(text)
    f.time:SetText("")
    f.failUntil = GetTime() + FAIL_HOLD
    f:SetAlpha(1)
    f:Show()
end

local function OnUpdateBar(f)
    local st = f.state
    if st == "fade" then
        local a = 1 - (GetTime() - f.fadeStart) / FADE_TIME
        if a <= 0 then ClearBar(f) else f:SetAlpha(a) end
        return
    end
    if st == "failed" then
        if GetTime() >= f.failUntil then f.state, f.fadeStart = "fade", GetTime() end
        return
    end
    if st ~= "cast" then return end

    local now = GetTime() * 1000
    local dur = f.endMs - f.startMs
    if dur <= 0 then FinishCast(f); return end
    local frac = (now - f.startMs) / dur
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    if f.channel then frac = 1 - frac end   -- channels drain
    f.bar:SetValue(frac)

    local bw = Num(f.bar:GetWidth())
    if f.lagFrac and bw then
        f.lag:SetWidth(math.max(1, bw * f.lagFrac))
        f.lag:Show()
    end
    if bw and frac > 0 and frac < 1 then
        f.spark:ClearAllPoints()
        f.spark:SetPoint("CENTER", f.bar, "LEFT", bw * frac, 0)
        f.spark:Show()
    else
        f.spark:Hide()
    end

    local remain = (f.endMs - now) / 1000
    if remain < 0 then remain = 0 end
    if db.timer == "remain" then
        f.time:SetText(string.format("%.1f", remain))
    else
        f.time:SetText(string.format("%.1f / %.1f", remain, dur / 1000))
    end

    if now >= f.endMs then
        if f.test and testing then StartTestCast(f) else FinishCast(f) end
    end
end

-- The client's refusal is the answer: the first error a bar raises switches that bar off for
-- the session, with one line in chat, rather than repeating every frame.
local function Guard(u, fn, ...)
    if blocked[u] then return end
    local ok, err = pcall(fn, ...)
    if ok then return end
    blocked[u] = tostring(err)
    local f = bars[u]
    if f then pcall(ClearBar, f) end
    Print(string.format("this client will not let an addon draw the %s cast bar - it is off until /reload. (%s)",
        u, tostring(err)))
end

-- ---------------------------------------------------------------------------
-- Swing timer
--
-- Forever gives addons no combat log reader (C_CombatLog has only IsCombatLogRestricted,
-- ClearEntries and SetMessageLimit, see docs/forever-client-findings.md), so SWING_DAMAGE and
-- SWING_MISSED cannot be read. Two sources instead:
--
--   * PLAYER_SWING, an event of this client's own (retail has none), next to C_SwingTimer and
--     Enum.PlayerSwingType, which drive the client's built-in "Main Hand" swing bar. Each event
--     restarts the bar of the hand it names. Its payload is not documented: the hand is read from
--     (duration, Enum.PlayerSwingType value): arg2 decides the hand, arg1 is the swing duration
--     when sane, else UnitAttackSpeed / UnitRangedDamage. Ranged swings drive the ranged bar. /bcf swing debug prints every payload.
--   * Until PLAYER_SWING has been seen this session (or where it cannot be registered), an
--     estimate: PLAYER_ENTER_COMBAT (auto-attack on) starts a swing at once, the bar loops on
--     its own while auto-attack lasts, and on-next-swing abilities (Heroic Strike, Cleave,
--     Maul, Raptor Strike) restart it on UNIT_SPELLCAST_SUCCEEDED.
--
-- Always, whichever source: Slam restarts the main hand when it succeeds, Auto Shot and Shoot
-- (wand) restart the ranged bar, UNIT_ATTACK_SPEED / UNIT_RANGEDDAMAGE rescale a running swing
-- (the share already done is kept), and parrying an attack (UNIT_COMBAT "PARRY" on the player)
-- takes 40% of the swing off what is left of the main hand, never below 20%.
--
-- The client's built-in swing bar is never touched. Every value read is checked with
-- issecretvalue first and a secret skips that update; all of it runs under pcall and the first
-- error switches the swing timer off for the session with one line in chat.
-- ---------------------------------------------------------------------------

local SWING_H, SWING_GAP, SWING_FONT = 8, 1, 8
local SWING_ORDER = { "mh", "oh", "ranged" }
local MELEE_HANDS = { "mh", "oh" }
local SWING_LABEL = { mh = "MH", oh = "OH", ranged = "Ranged" }
local SWING_COLOR = { mh = { 0.8, 0.8, 0.85 }, oh = { 0.55, 0.65, 0.85 }, ranged = { 0.45, 0.8, 0.45 } }
local SWING_TEST = { mh = 2.6, oh = 1.8, ranged = 3.0 }
local PARRY_CUT, PARRY_FLOOR = 0.4, 0.2

-- Spell IDs (every Classic rank) by what they do to a swing. Names are resolved from these IDs
-- on first use, so a rank or ID this list misses still matches by its localised name.
local SWING_SPELLS = {
    nextswing = { 78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286,   -- Heroic Strike
                  845, 7369, 11608, 11609, 20569,                          -- Cleave
                  6807, 6808, 6809, 8972, 9745, 9880, 9881,                -- Maul
                  2973, 14260, 14261, 14262, 14263, 14264, 14265, 14266 }, -- Raptor Strike
    slam      = { 1464, 8820, 11604, 11605 },
    ranged    = { 75, 5019 },                                              -- Auto Shot, Shoot (wand)
}

local swingReal = { mh = {}, oh = {}, ranged = {} }   -- [hand] = { start, dur } in GetTime() seconds
local swingTest = { mh = {}, oh = {}, ranged = {} }
local swingState = {
    combat = false,      -- PLAYER_REGEN_DISABLED .. _ENABLED
    melee = false,       -- PLAYER_ENTER_COMBAT .. _LEAVE_COMBAT (auto-attack on)
    autoRepeat = false,  -- START_AUTOREPEAT_SPELL .. STOP_ (Auto Shot, Shoot)
    dual = false,        -- an off-hand attack speed is reported
    eventOK = false,     -- PLAYER_SWING could be registered
    rangedEventSeen = false,   -- a ranged PLAYER_SWING arrived this session
    eventSeen = false,   -- a melee PLAYER_SWING arrived this session
    debug = false,       -- /bcf swing debug, not saved
}
local swingBlocked       -- error text, once the client has refused the swing timer
local swingHolder        -- the frame the swing rows stack in, under the player bar
local swingRows = {}     -- [hand] = row frame
local swingLayout        -- the hands laid out now, as one string
local swingFadeStart
local swingWant = {}      -- [hand] = whether its row shows, reused every frame
local swingSpellKind     -- [spellID or name] = "nextswing" | "slam" | "ranged", built on first use
local swingEnumKind      -- [Enum.PlayerSwingType value] = hand, built on first use

local function SwingSpeeds()
    local mh, oh, rs
    if type(_G.UnitAttackSpeed) == "function" then
        local ok, a, b, c = pcall(_G.UnitAttackSpeed, "player")
        if ok then mh, oh, rs = Num(a), Num(b), Num(c) end
    end
    if type(_G.UnitRangedDamage) == "function" then
        local ok, s = pcall(_G.UnitRangedDamage, "player")
        if ok and Num(s) then rs = Num(s) end
    end
    if mh and mh <= 0 then mh = nil end
    if oh and oh <= 0 then oh = nil end
    if rs and rs <= 0 then rs = nil end
    return mh, oh, rs
end

local function SwingDuration(hand)
    local mh, oh, rs = SwingSpeeds()
    if hand == "mh" then return mh elseif hand == "oh" then return oh end
    return rs
end

local function SwingRunning(t, now)
    return t.start ~= nil and now < t.start + t.dur
end

local function SwingStart(hand, dur)
    local d = dur or SwingDuration(hand)
    if not d then return end          -- secret or missing speed: this swing is not drawn
    local t = swingReal[hand]
    t.start, t.dur = GetTime(), d
end

-- A haste change keeps the share of the swing already done and stretches what is left.
local function SwingRescale(hand)
    local t = swingReal[hand]
    local now = GetTime()
    if not SwingRunning(t, now) then return end
    local d = SwingDuration(hand)
    if not d or d == t.dur then return end
    local frac = (now - t.start) / t.dur
    t.start, t.dur = now - frac * d, d
end

local function SwingRefreshDual()
    local _, oh = SwingSpeeds()
    swingState.dual = oh ~= nil
end

local function SwingParry()
    local t = swingReal.mh
    local now = GetTime()
    if not SwingRunning(t, now) then return end
    local left = t.start + t.dur - now
    local floor = t.dur * PARRY_FLOOR
    if left <= floor then return end
    t.start = t.start - math.min(t.dur * PARRY_CUT, left - floor)
end

local function SpellName(id)
    local name
    local cs = _G.C_Spell
    if type(cs) == "table" and type(cs.GetSpellName) == "function" then
        local ok, n = pcall(cs.GetSpellName, id)
        if ok then name = n end
    elseif type(_G.GetSpellInfo) == "function" then
        local ok, n = pcall(_G.GetSpellInfo, id)
        if ok then name = n end
    end
    if IsSecret(name) or type(name) ~= "string" or name == "" then return nil end
    return name
end

local function SwingSpellKind(spellID)
    if not swingSpellKind then
        swingSpellKind = {}
        for kind, ids in pairs(SWING_SPELLS) do
            for _, id in ipairs(ids) do
                swingSpellKind[id] = kind
                local n = SpellName(id)
                if n then swingSpellKind[n] = kind end
            end
        end
    end
    spellID = Num(spellID)
    if not spellID then return nil end
    return swingSpellKind[spellID] or swingSpellKind[SpellName(spellID) or false]
end

local function HandFromName(s)
    local l = s:lower()
    if l:find("off") then return "oh" end
    if l:find("rang") then return "ranged" end
    if l:find("main") or l:find("melee") then return "mh" end
end

local function SwingEnumKinds()
    if swingEnumKind then return swingEnumKind end
    swingEnumKind = {}
    local e = type(_G.Enum) == "table" and _G.Enum.PlayerSwingType
    if type(e) == "table" then
        for k, v in pairs(e) do
            if type(k) == "string" and Num(v) then swingEnumKind[v] = HandFromName(k) or "mh" end
        end
    end
    return swingEnumKind
end

-- PLAYER_SWING payload, seen in game (/bcf swing debug): (duration, swingType), e.g.
-- 2.9000000953674, 0 -> MH, with swingType an Enum.PlayerSwingType value (MainHand=0, OffHand=1,
-- Ranged=2). Returns the hand and the duration (nil unless sane: > 0 and < 10, not secret).
-- Guarded fallbacks: no number in arg2 and an integer 0..2 in arg1 is taken as the type; a
-- string naming a hand also decides; nothing readable is main hand. Secrets are never compared.
local SWING_TYPE_FALLBACK = { [0] = "mh", [1] = "oh", [2] = "ranged" }
local function SwingPayload(a1, a2, ...)
    local dur, hand
    local n1 = (not IsSecret(a1) and type(a1) == "number") and a1 or nil
    local n2 = (not IsSecret(a2) and type(a2) == "number") and a2 or nil
    if n2 ~= nil then
        hand = SwingEnumKinds()[n2] or SWING_TYPE_FALLBACK[n2]
        if n1 and n1 > 0 and n1 < 10 then dur = n1 end
    elseif n1 ~= nil and a2 == nil and n1 >= 0 and n1 <= 2 and n1 == math.floor(n1) then
        hand = SwingEnumKinds()[n1] or SWING_TYPE_FALLBACK[n1]
    end
    if not hand then
        for _, a in ipairs({ a1, a2, ... }) do
            if not IsSecret(a) and type(a) == "string" then
                hand = HandFromName(a)
                if hand then break end
            end
        end
    end
    return hand or "mh", dur
end

local function DescribeArgs(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local a = select(i, ...)
        if IsSecret(a) then parts[#parts + 1] = "<secret>"
        elseif type(a) == "string" then parts[#parts + 1] = "\"" .. a .. "\""
        else parts[#parts + 1] = tostring(a) end
    end
    return #parts > 0 and table.concat(parts, ", ") or "(no payload)"
end

local function OnPlayerSwing(...)
    local hand, dur = SwingPayload(...)
    if swingState.debug then
        Print("PLAYER_SWING: " .. DescribeArgs(...) .. " -> " .. SWING_LABEL[hand]
              .. " (dur=" .. tostring(dur) .. ", type=" .. SWING_LABEL[hand] .. ")")
    end
    if hand == "ranged" then swingState.rangedEventSeen = true else swingState.eventSeen = true end
    SwingStart(hand, dur)
end

local function OnSwingSpell(spellID)
    local kind = SwingSpellKind(spellID)
    if kind == "ranged" then
        if not swingState.rangedEventSeen then SwingStart("ranged") end   -- PLAYER_SWING drives it once seen
    elseif kind == "slam" then SwingStart("mh")
    elseif kind == "nextswing" and not swingState.eventSeen then SwingStart("mh") end
end

-- The player bar's cast-target line moves under the swing rows while they show.
local function AnchorPlayerTargetText(below)
    local f = bars.player
    if not f then return end
    f.target:ClearAllPoints()
    f.target:SetPoint("TOP", below or f, "BOTTOM", 0, -2)
end

local function ApplySwingLook()
    local font = _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    for _, hand in ipairs(SWING_ORDER) do
        local r = swingRows[hand]
        if r then
            r.bar:SetStatusBarTexture(TexturePath(db and db.texture))
            local c = SWING_COLOR[hand]
            r.bar:SetStatusBarColor(c[1], c[2], c[3])
            r.label:SetFont(font, SWING_FONT, "OUTLINE")
            r.time:SetFont(font, SWING_FONT, "OUTLINE")
        end
    end
end

local function MakeSwingRow(hand)
    local r = CreateFrame("Frame", nil, swingHolder, "BackdropTemplate")
    r:SetHeight(SWING_H)
    r:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
                    insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    r:SetBackdropColor(0, 0, 0, 0.6)
    r:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
    r.bar = CreateFrame("StatusBar", nil, r)
    r.bar:SetPoint("TOPLEFT", 1, -1)
    r.bar:SetPoint("BOTTOMRIGHT", -1, 1)
    r.bar:SetMinMaxValues(0, 1)
    r.bar:SetValue(0)
    r.label = r.bar:CreateFontString(nil, "OVERLAY")
    r.label:SetPoint("LEFT", 3, 0)
    r.label:SetAlpha(0.7)
    r.time = r.bar:CreateFontString(nil, "OVERLAY")
    r.time:SetPoint("RIGHT", -3, 0)
    r.time:SetJustifyH("RIGHT")
    r:Hide()
    return r
end

-- The rows hang off the player bar's bottom edge, from the spell icon's left edge to the bar's
-- right edge, so they move, resize and follow Edit Mode with it. Parented to UIParent: they show while the cast bar is idle.
local function MakeSwingHolder()
    swingHolder = CreateFrame("Frame", "BetterCastbarsForever_swing", _G.UIParent)
    swingHolder:SetFrameStrata("MEDIUM")
    swingHolder:EnableMouse(false)
    -- The icon border sits 1 px outside the icon, which is as tall as the bar: its bottom-left
    -- corner is the bar's bottom edge minus 1, the same gap as on the right.
    swingHolder:SetPoint("TOPLEFT", bars.player.iconBorder, "BOTTOMLEFT", 0, 0)
    swingHolder:SetPoint("TOPRIGHT", bars.player, "BOTTOMRIGHT", 0, -1)
    swingHolder:SetHeight(SWING_H)
    for _, hand in ipairs(SWING_ORDER) do swingRows[hand] = MakeSwingRow(hand) end
    ApplySwingLook()
    for _, hand in ipairs(SWING_ORDER) do swingRows[hand].label:SetText(SWING_LABEL[hand]) end
    swingHolder:Hide()
end

local function HideSwing()
    swingFadeStart, swingLayout = nil, nil
    if swingHolder and swingHolder:IsShown() then
        swingHolder:Hide()
        AnchorPlayerTargetText(nil)
    end
end

local function LayoutSwing(want, key)
    local prev, n = nil, 0
    for _, hand in ipairs(SWING_ORDER) do
        local r = swingRows[hand]
        r:ClearAllPoints()
        if want[hand] then
            local anchor = prev or swingHolder
            local rel = prev and "BOTTOM" or "TOP"
            r:SetPoint("TOPLEFT", anchor, rel .. "LEFT", 0, prev and -SWING_GAP or 0)
            r:SetPoint("TOPRIGHT", anchor, rel .. "RIGHT", 0, prev and -SWING_GAP or 0)
            r:Show()
            prev, n = r, n + 1
        else
            r:Hide()
        end
    end
    swingHolder:SetHeight(n * SWING_H + (n - 1) * SWING_GAP)
    AnchorPlayerTargetText(swingHolder)
    swingLayout = key
end

local function SwingTick()
    if not swingHolder then return end
    if not db.swingTimer then HideSwing(); return end
    local now = GetTime()

    -- The estimate: with no PLAYER_SWING seen, a finished swing starts the next while
    -- auto-attack lasts.
    if not swingState.eventSeen and swingState.melee then
        for _, hand in ipairs(MELEE_HANDS) do
            local t = swingReal[hand]
            if t.start and now >= t.start + t.dur and (hand == "mh" or swingState.dual) then
                local d = SwingDuration(hand)
                if d then
                    local s = t.start + t.dur
                    if s + d <= now then s = now end
                    t.start, t.dur = s, d
                else
                    t.start = nil
                end
            end
        end
    end

    local src = swingReal
    if testing then
        src = swingTest
        for _, hand in ipairs(SWING_ORDER) do
            local t = swingTest[hand]
            if not SwingRunning(t, now) then t.start, t.dur = now, SWING_TEST[hand] end
        end
    end

    local fight = swingState.combat or swingState.melee
    local runMH, runOH, runR = SwingRunning(src.mh, now), SwingRunning(src.oh, now), SwingRunning(src.ranged, now)
    local want = swingWant
    want.mh = testing or fight or runMH
    want.oh = db.swingOffhand and (testing or (fight and swingState.dual) or runOH)
    want.ranged = db.swingRanged and (testing or swingState.autoRepeat or runR)
    local key = (want.mh and "m" or "") .. (want.oh and "o" or "") .. (want.ranged and "r" or "")

    if key == "" then
        if not swingHolder:IsShown() then return end
        swingFadeStart = swingFadeStart or now
        local a = 1 - (now - swingFadeStart) / FADE_TIME
        if a <= 0 then HideSwing() else swingHolder:SetAlpha(a) end
        return
    end
    swingFadeStart = nil
    if key ~= swingLayout then LayoutSwing(want, key) end
    swingHolder:SetAlpha(1)
    if not swingHolder:IsShown() then swingHolder:Show() end

    for _, hand in ipairs(SWING_ORDER) do
        if want[hand] then
            local r, t = swingRows[hand], src[hand]
            if SwingRunning(t, now) then
                r.bar:SetValue((now - t.start) / t.dur)
                r.time:SetText(string.format("%.1f", t.start + t.dur - now))
            else
                r.bar:SetValue(0)
                r.time:SetText("")
            end
        end
    end
end

-- The first error the swing timer raises switches it off until /reload, with one chat line.
local function SwingGuard(fn, ...)
    if swingBlocked then return end
    local ok, err = pcall(fn, ...)
    if ok then return end
    swingBlocked = tostring(err)
    pcall(HideSwing)
    Print("this client will not let an addon run the swing timer - it is off until /reload. (" .. swingBlocked .. ")")
end

local function OnSwingEvent(event, ...)
    local arg1 = ...
    if event == "PLAYER_SWING" then
        OnPlayerSwing(...)
    elseif event == "PLAYER_ENTER_COMBAT" then
        swingState.melee = true
        SwingRefreshDual()
        if not swingState.eventSeen then
            local now = GetTime()
            if not SwingRunning(swingReal.mh, now) then SwingStart("mh") end
            if swingState.dual and not SwingRunning(swingReal.oh, now) then SwingStart("oh") end
        end
    elseif event == "PLAYER_LEAVE_COMBAT" then
        swingState.melee = false
    elseif event == "PLAYER_REGEN_DISABLED" then
        swingState.combat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        swingState.combat = false
    elseif event == "START_AUTOREPEAT_SPELL" then
        swingState.autoRepeat = true
    elseif event == "STOP_AUTOREPEAT_SPELL" then
        swingState.autoRepeat = false
    elseif IsSecret(arg1) or arg1 ~= "player" then
        return
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        OnSwingSpell(select(3, ...))
    elseif event == "UNIT_ATTACK_SPEED" then
        SwingRefreshDual()
        SwingRescale("mh")
        SwingRescale("oh")
    elseif event == "UNIT_RANGEDDAMAGE" then
        SwingRescale("ranged")
    elseif event == "UNIT_INVENTORY_CHANGED" then
        SwingRefreshDual()
    elseif event == "UNIT_COMBAT" then
        local action = select(2, ...)
        if not IsSecret(action) and action == "PARRY" then SwingParry() end
    end
end

-- Own frame for the swing events, so a refusal there never reaches the cast bars.
local swingEvents = CreateFrame("Frame")
swingState.eventOK = pcall(swingEvents.RegisterEvent, swingEvents, "PLAYER_SWING") and true or false
for _, e in ipairs({ "PLAYER_ENTER_COMBAT", "PLAYER_LEAVE_COMBAT", "PLAYER_REGEN_DISABLED",
                     "PLAYER_REGEN_ENABLED", "START_AUTOREPEAT_SPELL", "STOP_AUTOREPEAT_SPELL",
                     "UNIT_SPELLCAST_SUCCEEDED" }) do
    pcall(swingEvents.RegisterEvent, swingEvents, e)
end
for _, e in ipairs({ "UNIT_ATTACK_SPEED", "UNIT_RANGEDDAMAGE", "UNIT_INVENTORY_CHANGED", "UNIT_COMBAT" }) do
    local ok = type(swingEvents.RegisterUnitEvent) == "function"
        and pcall(swingEvents.RegisterUnitEvent, swingEvents, e, "player")
    if not ok then pcall(swingEvents.RegisterEvent, swingEvents, e) end
end
swingEvents:SetScript("OnEvent", function(_, event, ...)
    if not db or not swingHolder then return end
    SwingGuard(OnSwingEvent, event, ...)
end)

-- At login and after a loading screen: whether we are in a fight, and whether dual-wielding.
local function SwingSync()
    local ok, c = pcall(_G.UnitAffectingCombat, "player")
    swingState.combat = ok and not IsSecret(c) and c and true or false
    SwingRefreshDual()
end

local function DriverUpdate()
    if not db then return end
    for _, u in ipairs(UNITS) do
        local f = bars[u]
        if f and not blocked[u] then
            if testing and BarEnabled(u) and not f.state then Guard(u, StartTestCast, f) end
            if f.state then Guard(u, OnUpdateBar, f) end
        end
    end
    SwingGuard(SwingTick)
end

-- Re-read a unit after it changed (new target, new focus, pet summoned).
local function Refresh(u)
    local f = bars[u]
    if not f or blocked[u] then return end
    if not BarEnabled(u) then ClearBar(f); return end
    if CastInfo(u) then StartCast(f)
    elseif not f.test then ClearBar(f) end
end

-- ---------------------------------------------------------------------------
-- Settings, shared by the slash command and the menu entries of the API
-- ---------------------------------------------------------------------------

local function SetTesting(on)
    testing = on and true or false
    for _, u in ipairs(UNITS) do
        local f = bars[u]
        if f and f.test then ClearBar(f) end
        if not testing then Guard(u, Refresh, u) end
    end
    Print(testing and "test bars on: every enabled bar loops a fake cast - drag them into place. /bcf test again to stop."
        or "test bars off.")
end

local function SetLocked(on)
    if not db then return end
    db.locked = on and true or false
    for _, u in ipairs(UNITS) do
        local f = bars[u]
        if f then
            if db.locked and (f.moving or f.sizing) then
                f.moving, f.sizing = nil, nil
                f:StopMovingOrSizing()
                AfterHandPlacement(f, "moved")
            end
            ApplyLock(f)
        end
    end
    Print(db.locked and "bars locked: no dragging or resizing, clicks go through them."
        or "bars unlocked: drag a bar to move it, the bottom-right grip to resize it (/bcf test shows them).")
end

local function ResetLayout()
    if not db then return end
    db.positions, db.sizes = {}, {}
    ApplyAll()
    Print("positions and sizes reset" .. (db.follow and " (still following Blizzard's bars)." or " to the defaults."))
end

local function SetFollow(on)
    if not db then return end
    db.follow = on and true or false
    ApplyAll()
    if db.follow then
        local missing = {}
        for _, u in ipairs(UNITS) do
            if bars[u] and bars[u].anchoredTo ~= "blizzard" then missing[#missing + 1] = u end
        end
        Print("following Blizzard's cast bars - place them with Edit Mode."
            .. (#missing > 0 and (" Own position for " .. table.concat(missing, ", ")
                .. ": Blizzard's bar is missing or will not report where it is.") or ""))
    else
        Print("own position - drag the bars to move them.")
    end
end

local function SetBar(u, on)
    if not db or not HasUnit(u) then return end
    db.bars[u] = on and true or false
    local f = bars[u]
    if db.bars[u] then
        HookBlizzard(u)
        Guard(u, Refresh, u)
        Print(LABEL[u] .. " bar on.")
    else
        if f then ClearBar(f) end
        Print(LABEL[u] .. " bar off - Blizzard's own " .. u .. " cast bar shows again from its next cast.")
    end
end

local function SetLatency(on)
    if not db then return end
    db.latency = on and true or false
    Print("latency safe-zone on the player bar " .. OnOff(db.latency) .. ".")
end

local function SetTexture(key)
    if not db then return end
    if not IsTextureKey(key) then
        Print("texture must be blizzard, smooth or flat.")
        return
    end
    db.texture = key
    for _, u in ipairs(UNITS) do if bars[u] then ApplyTexture(bars[u]) end end
    ApplySwingLook()
    Print("texture: " .. key .. ".")
end

local function SetFontSize(n)
    if not db then return end
    n = Num(tonumber(n))
    if not n or not IsFontSize(n) then
        Print("font size must be 9, 11 or 13.")
        return
    end
    db.fontSize = n
    for _, u in ipairs(UNITS) do if bars[u] then ApplyFonts(bars[u]) end end
    Print("font size: " .. n .. ".")
end

local function SetTimer(key)
    if not db then return end
    if not IsTimerKey(key) then
        Print("timer must be total (remain / total) or remain.")
        return
    end
    db.timer = key
    Print("timer: " .. (key == "total" and "remain / total." or "remain only."))
end

local SWING_SETTING_TEXT = {
    swingTimer = "swing timer",
    swingOffhand = "off-hand swing bar",
    swingRanged = "ranged swing bar",
}

local function SetSwing(key, on)
    if not db or not SWING_SETTING_TEXT[key] then return end
    db[key] = on and true or false
    if key == "swingTimer" and not db.swingTimer then pcall(HideSwing) end
    Print(SWING_SETTING_TEXT[key] .. " " .. OnOff(db[key]) .. "."
        .. ((db[key] and swingBlocked) and " (still off until /reload: the client refused it.)" or ""))
end

local function SetSwingDebug(on)
    swingState.debug = on and true or false
    if not swingState.debug then
        Print("swing debug off.")
        return
    end
    local names = {}
    local e = type(_G.Enum) == "table" and _G.Enum.PlayerSwingType
    if type(e) == "table" then
        for k, v in pairs(e) do names[#names + 1] = tostring(k) .. "=" .. (IsSecret(v) and "<secret>" or tostring(v)) end
        table.sort(names)
    end
    Print("swing debug on: every PLAYER_SWING payload is printed. Enum.PlayerSwingType: "
        .. (#names > 0 and table.concat(names, ", ") or "missing")
        .. ". /bcf swing debug again to stop.")
end

-- Where swings come from now, for /bcf status.
local function SwingSourceText()
    if swingState.eventSeen then return "PLAYER_SWING (seen this session)" end
    if swingState.eventOK then return "PLAYER_SWING registered, none seen yet - estimating from auto-attack" end
    return "estimate from auto-attack (this client has no PLAYER_SWING)"
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function EnabledList()
    local on = {}
    for _, u in ipairs(UNITS) do
        if db and db.bars[u] then on[#on + 1] = u end
    end
    return on
end

local function PlaceText(u)
    local f = bars[u]
    local pos = db and db.positions[u]
    local where
    if f and f.anchoredTo == "blizzard" then where = "on Blizzard's bar"
    elseif pos then where = string.format("moved (%.0f, %.0f)", pos.x, pos.y)
    else where = "default position" end
    local size = db and db.sizes[u]
    local d = DEFAULT_SIZE[u]
    return where .. string.format(", %dx%d", size and size.w or d[1], size and size.h or d[2])
end

local function GaarCastLine()
    return "GaarCast is loaded too: both hide and replace the same Blizzard cast bars. Use one of the two."
end

local function PrintHelp()
    Print("drag a bar to move it, drag its bottom-right grip to resize it. /bcf test shows them out of combat.")
    Print("/bcf status - what this client offers and the current settings")
    Print("/bcf lock | /bcf unlock - stop or allow moving and resizing (now: " .. ((db and db.locked) and "locked" or "unlocked") .. ")")
    Print("/bcf test - looping fake casts on every enabled bar (now: " .. OnOff(testing) .. ")")
    Print("/bcf reset - positions and sizes back to the defaults")
    Print("/bcf follow on|off - anchor each bar to Blizzard's own cast bar, placed with Edit Mode (now: " .. OnOff(db and db.follow) .. ")")
    Print("/bcf bar <" .. table.concat(UNITS, "|") .. "> on|off - which bars to draw (now: "
        .. (#EnabledList() > 0 and table.concat(EnabledList(), " ") or "none") .. ")")
    Print("/bcf latency on|off - latency safe-zone on the player bar (now: " .. OnOff(db and db.latency) .. ")")
    Print("/bcf texture blizzard|smooth|flat (now: " .. (db and db.texture or DEFAULTS.texture) .. ")")
    Print("/bcf font 9|11|13 (now: " .. (db and db.fontSize or DEFAULTS.fontSize) .. ")")
    Print("/bcf timer total|remain - \"remain / total\" or just remain (now: " .. (db and db.timer or DEFAULTS.timer) .. ")")
    Print("/bcf swing on|off - swing timer under the player bar (now: " .. OnOff(db and db.swingTimer) .. ")")
    Print("/bcf swing offhand on|off, /bcf swing ranged on|off - its off-hand and ranged bars (now: "
        .. OnOff(db and db.swingOffhand) .. ", " .. OnOff(db and db.swingRanged) .. "); /bcf swing debug prints each swing event")
end

local function Yes(v) return v and "yes" or "MISSING" end

local function PrintStatus()
    Print("version " .. VERSION)
    Print("UnitCastingInfo: " .. Yes(type(_G.UnitCastingInfo) == "function")
        .. "   UnitChannelInfo: " .. Yes(type(_G.UnitChannelInfo) == "function")
        .. "   GetNetStats: " .. Yes(type(_G.GetNetStats) == "function")
        .. "   secret values: " .. (issecretvalue and "possible" or "no")
        .. "   focus: " .. (HAS_FOCUS and "yes" or "no")
        .. "   Edit Mode: " .. (type(_G.EditModeManagerFrame) == "table" and "yes" or "no"))
    Print("locked: " .. ((db and db.locked) and "yes" or "no") .. "   follow Blizzard: " .. OnOff(db and db.follow)
        .. "   test bars: " .. OnOff(testing))
    Print("latency: " .. OnOff(db and db.latency) .. "   texture: " .. (db and db.texture or "?")
        .. "   font: " .. (db and db.fontSize or "?") .. "   timer: " .. (db and db.timer or "?"))
    for _, u in ipairs(UNITS) do
        local bf = BlizzBar(u)
        local line = string.format("%s: %s, %s; Blizzard's bar %s", u, OnOff(db and db.bars[u]), PlaceText(u),
            bf and ((hooked[bf] and BarEnabled(u)) and "found, hidden while ours is on" or "found") or "not found")
        if blocked[u] then line = line .. "; OFF - the client refused it: " .. blocked[u] end
        Print(line)
    end
    local swingLine = "swing timer: " .. OnOff(db and db.swingTimer) .. "   off hand: " .. OnOff(db and db.swingOffhand)
        .. "   ranged: " .. OnOff(db and db.swingRanged) .. "   UnitAttackSpeed: " .. Yes(type(_G.UnitAttackSpeed) == "function")
        .. "   swings from: " .. SwingSourceText()
    if swingBlocked then swingLine = swingLine .. "; OFF - the client refused it: " .. swingBlocked end
    Print(swingLine)
    if AddOnLoaded("GaarCast") then Print(GaarCastLine()) end
end

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    local cmd, rest = msg:match("^(%S+)%s*(.*)$")
    cmd, rest = cmd or "", rest or ""
    if cmd == "" or cmd == "help" then
        PrintHelp()
    elseif cmd == "status" then
        PrintStatus()
    elseif cmd == "lock" then
        SetLocked(true)
    elseif cmd == "unlock" then
        SetLocked(false)
    elseif cmd == "test" then
        if rest == "on" then SetTesting(true)
        elseif rest == "off" then SetTesting(false)
        else SetTesting(not testing) end
    elseif cmd == "reset" then
        ResetLayout()
    elseif cmd == "follow" then
        if rest == "on" then SetFollow(true)
        elseif rest == "off" then SetFollow(false)
        else SetFollow(not db.follow) end
    elseif cmd == "bar" then
        local u, v = rest:match("^(%a+)%s*(%a*)$")
        if not u or not HasUnit(u) then
            Print("/bcf bar <" .. table.concat(UNITS, "|") .. "> on|off")
        elseif v == "on" then SetBar(u, true)
        elseif v == "off" then SetBar(u, false)
        else SetBar(u, not db.bars[u]) end
    elseif cmd == "latency" then
        if rest == "on" then SetLatency(true)
        elseif rest == "off" then SetLatency(false)
        else SetLatency(not db.latency) end
    elseif cmd == "texture" then
        SetTexture(rest)
    elseif cmd == "font" then
        SetFontSize(rest)
    elseif cmd == "timer" then
        SetTimer(rest)
    elseif cmd == "swing" then
        local sub, v = rest:match("^(%a*)%s*(%a*)$")
        sub, v = sub or "", v or ""
        if sub == "" then SetSwing("swingTimer", not db.swingTimer)
        elseif sub == "on" or sub == "off" then SetSwing("swingTimer", sub == "on")
        elseif sub == "offhand" or sub == "ranged" then
            local key = sub == "offhand" and "swingOffhand" or "swingRanged"
            if v == "on" then SetSwing(key, true)
            elseif v == "off" then SetSwing(key, false)
            else SetSwing(key, not db[key]) end
        elseif sub == "debug" then
            SetSwingDebug(not swingState.debug)
        else
            Print("/bcf swing on|off, /bcf swing offhand on|off, /bcf swing ranged on|off, /bcf swing debug")
        end
    else
        Print("unknown command \"" .. msg .. "\".")
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterCastbarsForeverAPI
--
-- For BetterGaarForever, the optional hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterCastbarsForeverDB and change only through
-- the same functions /bcf uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "unlocked · player target focus · own position"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func },
--                        { text, radio = true, checked, func }, { text, submenu } and { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    local on = EnabledList()
    local line = (db.locked and "locked" or "unlocked") .. DOT
        .. (#on > 0 and table.concat(on, " ") or "no bars") .. DOT
        .. (db.follow and "follows Blizzard" or "own position")
    if testing then line = line .. DOT .. "test bars on" end
    return line
end

local function MenuEntries()
    if not db then return {} end
    local barItems, textures, fonts = {}, {}, {}
    for _, u in ipairs(UNITS) do
        barItems[#barItems + 1] = { text = LABEL[u], checkbox = true,
            checked = function() return db.bars[u] end,
            func = function() SetBar(u, not db.bars[u]) end }
    end
    for _, t in ipairs(TEXTURES) do
        textures[#textures + 1] = { text = t.label, radio = true,
            checked = function() return db.texture == t.key end,
            func = function() SetTexture(t.key) end }
    end
    for _, s in ipairs(FONT_SIZES) do
        fonts[#fonts + 1] = { text = tostring(s), radio = true,
            checked = function() return db.fontSize == s end,
            func = function() SetFontSize(s) end }
    end
    local list = {
        { text = "Lock position & size", checkbox = true, checked = function() return db.locked end,
          func = function() SetLocked(not db.locked) end },
        { text = "Test bars", checkbox = true, checked = function() return testing end,
          func = function() SetTesting(not testing) end },
        { text = "Bars", submenu = barItems },
        { text = "Swing timer", submenu = {
            { text = "Show swing timer", checkbox = true, checked = function() return db.swingTimer end,
              func = function() SetSwing("swingTimer", not db.swingTimer) end },
            { text = "Off hand", checkbox = true, checked = function() return db.swingOffhand end,
              func = function() SetSwing("swingOffhand", not db.swingOffhand) end },
            { text = "Ranged", checkbox = true, checked = function() return db.swingRanged end,
              func = function() SetSwing("swingRanged", not db.swingRanged) end },
        } },
        { divider = true },
        { text = "Follow Blizzard (Edit Mode)", checkbox = true, checked = function() return db.follow end,
          func = function() SetFollow(not db.follow) end },
        { text = "Latency safe-zone", checkbox = true, checked = function() return db.latency end,
          func = function() SetLatency(not db.latency) end },
        { text = "Texture", submenu = textures },
        { text = "Font size", submenu = fonts },
        { divider = true },
    }
    for _, t in ipairs(TIMERS) do
        list[#list + 1] = { text = "Timer: " .. t.label, radio = true,
            checked = function() return db.timer == t.key end,
            func = function() SetTimer(t.key) end }
    end
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Reset positions & sizes", func = ResetLayout }
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

_G.BetterCastbarsForeverAPI = {
    version = VERSION,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) RenderMenu(root, MenuEntries()) end,
    SetMinimapHidden = function() end,
}

-- ---------------------------------------------------------------------------
-- Saved variables and events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterCastbarsForeverDB) ~= "table" then BetterCastbarsForeverDB = {} end
    db = BetterCastbarsForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
    if type(db.locked) ~= "boolean" then db.locked = DEFAULTS.locked end
    if type(db.follow) ~= "boolean" then db.follow = DEFAULTS.follow end
    if type(db.latency) ~= "boolean" then db.latency = DEFAULTS.latency end
    if not IsTextureKey(db.texture) then db.texture = DEFAULTS.texture end
    if not IsFontSize(db.fontSize) then db.fontSize = DEFAULTS.fontSize end
    if not IsTimerKey(db.timer) then db.timer = DEFAULTS.timer end
    if type(db.swingTimer) ~= "boolean" then db.swingTimer = DEFAULTS.swingTimer end
    if type(db.swingRanged) ~= "boolean" then db.swingRanged = DEFAULTS.swingRanged end
    if type(db.swingOffhand) ~= "boolean" then db.swingOffhand = DEFAULTS.swingOffhand end

    if type(db.bars) ~= "table" then db.bars = {} end
    for k, v in pairs(db.bars) do
        if DEFAULT_BARS[k] == nil or type(v) ~= "boolean" then db.bars[k] = nil end
    end
    for k, v in pairs(DEFAULT_BARS) do
        if db.bars[k] == nil then db.bars[k] = v end
    end

    -- A saved entry with a field missing is a secret that did not survive the write: present but
    -- empty, so it is rejected by its contents rather than by existing.
    if type(db.positions) ~= "table" then db.positions = {} end
    for k, p in pairs(db.positions) do
        if DEFAULT_BARS[k] == nil or type(p) ~= "table" or not Num(p.x) or not Num(p.y) then
            db.positions[k] = nil
        end
    end
    if type(db.sizes) ~= "table" then db.sizes = {} end
    for k, s in pairs(db.sizes) do
        if DEFAULT_BARS[k] == nil or type(s) ~= "table" or not Num(s.w) or not Num(s.h) then
            db.sizes[k] = nil
        else
            s.w, s.h = Clamp(s.w, MIN_W, MAX_W), Clamp(s.h, MIN_H, MAX_H)
        end
    end
end

local function Init()
    for _, u in ipairs(UNITS) do
        if not bars[u] then bars[u] = MakeBar(u) end
        if db.bars[u] then HookBlizzard(u) end
    end
    ApplyAll()
    SwingGuard(MakeSwingHolder)
    driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", DriverUpdate)
end

local CAST_EVENTS = {
    UNIT_SPELLCAST_START = "start",
    UNIT_SPELLCAST_CHANNEL_START = "start",
    UNIT_SPELLCAST_DELAYED = "update",
    UNIT_SPELLCAST_CHANNEL_UPDATE = "update",
    UNIT_SPELLCAST_STOP = "stop",
    UNIT_SPELLCAST_CHANNEL_STOP = "channelstop",
    UNIT_SPELLCAST_FAILED = "failed",
    UNIT_SPELLCAST_INTERRUPTED = "interrupted",
    UNIT_SPELLCAST_INTERRUPTIBLE = "interruptible",
    UNIT_SPELLCAST_NOT_INTERRUPTIBLE = "notinterruptible",
}

local function OnCastEvent(f, kind, castGUID)
    if kind == "start" then
        StartCast(f)
    elseif kind == "update" then
        if f.state == "cast" and not f.test then StartCast(f) end   -- pushback, haste
    elseif kind == "stop" or kind == "channelstop" then
        if f.state == "cast" and not f.test and f.channel == (kind == "channelstop") then FinishCast(f) end
    elseif kind == "failed" or kind == "interrupted" then
        if f.state ~= "cast" or f.test then return end
        -- A spell that fails to start while another is casting fires FAILED for the new one;
        -- the running cast is untouched, so it is left alone. The cast id settles it where both
        -- are known; otherwise a FAILED while the unit still reports a cast is that case.
        local comparable = not IsSecret(castGUID) and type(castGUID) == "string" and type(f.castID) == "string"
        if comparable and castGUID ~= f.castID then return end
        if not comparable and kind == "failed" and CastInfo(f.unit) then return end
        local text = kind == "interrupted" and _G.INTERRUPTED or _G.FAILED
        if type(text) ~= "string" then text = kind == "interrupted" and "Interrupted" or "Failed" end
        FailCast(f, text)
    elseif kind == "interruptible" or kind == "notinterruptible" then
        if f.state == "cast" and not f.test then
            f.notInt = (kind == "notinterruptible")
            SetBarColor(f)
            SetIconLook(f, f.notInt)
        end
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED", "UNIT_PET", "EDIT_MODE_LAYOUTS_UPDATED" }) do
    pcall(events.RegisterEvent, events, e)
end
if HAS_FOCUS then pcall(events.RegisterEvent, events, "PLAYER_FOCUS_CHANGED") end
for e in pairs(CAST_EVENTS) do pcall(events.RegisterEvent, events, e) end

events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            BindSavedVariables()
            Init()
        end
        return
    end
    if not db then return end
    if event == "PLAYER_LOGIN" then
        if AddOnLoaded("GaarCast") and not conflictWarned then
            conflictWarned = true
            Print(GaarCastLine())
        end
        for _, u in ipairs(UNITS) do if db.bars[u] then HookBlizzard(u) end end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "EDIT_MODE_LAYOUTS_UPDATED" then
        -- Blizzard's bars and unit frames only get their final layout around now.
        ApplyAll()
        for _, u in ipairs(UNITS) do
            if db.bars[u] then HookBlizzard(u) end
            Guard(u, Refresh, u)
        end
        SwingGuard(SwingSync)
    elseif event == "PLAYER_TARGET_CHANGED" then
        Guard("target", Refresh, "target")
    elseif event == "PLAYER_FOCUS_CHANGED" then
        Guard("focus", Refresh, "focus")
    elseif event == "UNIT_PET" then
        if arg1 == "player" then Guard("pet", Refresh, "pet") end
    else
        local kind = CAST_EVENTS[event]
        local f = kind and bars[arg1]
        if f and BarEnabled(arg1) then Guard(arg1, OnCastEvent, f, kind, arg2) end
    end
end)

SLASH_BETTERCASTBARSFOREVER1 = "/bcf"
SLASH_BETTERCASTBARSFOREVER2 = "/bettercastbarsforever"
SlashCmdList.BETTERCASTBARSFOREVER = OnSlash
