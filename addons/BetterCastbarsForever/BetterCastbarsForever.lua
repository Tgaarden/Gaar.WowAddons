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
    * /bcf for help, status, lock, unlock, test, reset, follow, bar, latency, texture, font and
      timer.
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

local VERSION = "1.0"

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
}
local DEFAULT_BARS = { player = true, target = true, focus = true, pet = false }

-- Every key BetterCastbarsForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = {
    locked = true, follow = true, latency = true, texture = true, fontSize = true, timer = true,
    bars = true, positions = true, sizes = true,
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

local function DriverUpdate()
    if not db then return end
    for _, u in ipairs(UNITS) do
        local f = bars[u]
        if f and not blocked[u] then
            if testing and BarEnabled(u) and not f.state then Guard(u, StartTestCast, f) end
            if f.state then Guard(u, OnUpdateBar, f) end
        end
    end
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
