--[[
  GaarBarsForever - clearer action buttons on WoW Forever: a red icon out of range, a blue icon
  without mana, readable cooldown numbers, short hotkeys and optional macro names.

  It does this and nothing else, on Blizzard's own action buttons (the main bar, the multi bars,
  the bonus/override bar where the client has one, the stance bar and the pet bar):

    * rangeColor (on): the icon is tinted red (0.8, 0.1, 0.1) while the action is out of range of
      your target. Action buttons only.
    * manaColor (on): the icon is tinted blue (0.3, 0.3, 1.0) while you lack the mana, energy or
      rage for it (IsUsableAction: usable false, notEnoughMana true). Unusable for any other
      reason stays Blizzard's grey. Out of range wins over no mana; neither gives the normal
      colour back. Action buttons only.
    * cooldownText (on): a big centred cooldown number, "56", "2m", "1h" (no space, rounded up,
      GaarFramesForever's aura format). Hidden for the global cooldown (1.5 s or less). Drawn by
      the addon from GetActionCooldown (GetShapeshiftFormCooldown, GetPetActionCooldown) while the
      values are plain; where the client hides them (secret), the cooldown's own countdown numbers
      are switched on instead and styled (bigger font, the same format where the client has
      C_StringUtil's rule formatter), because only the client can draw a secret.
    * hotkeyShort (on): "Mouse Button 4" -> "M4", "Middle Mouse" -> "M3", "Num Pad 1" -> "N1",
      "Mouse Wheel Up/Down" -> "WU"/"WD", "Shift-" -> "s", "Ctrl-" -> "c", "Alt-" -> "a"
      ("Ctrl-Shift-4" -> "cs4"). Blizzard's own short forms ("s-", "MwU", ...) are shortened too.
    * macroText (on): macro names on the buttons; off hides them (alpha 0, never Hide).
    * outOfRangeHotkey (off): out of range tints only the hotkey text red instead of the icon.
      When on, it overrides rangeColor for the icon.
    * bookMissingTab (on): a square icon tab of our own in the spellbook's bottom-left corner
      ("Missing from bars", Forever's tab look, a count badge) with one list of the known, castable, non-passive spells that are on no action bar,
      or whose bar copy is a lower rank than the one you know. Same look as Blizzard's pages;
      drag an entry to a bar, click it to cast. BookTab.lua, see there.
    * flyouts (on): flyouts of up to 12 spells, items or macros, each carried on the bars by a
      macro of its own ("GF <name>"); drop on the "+" a button shows while the cursor holds one to
      make or grow one, or edit them in the editor (/gbars flyouts, FlyoutEditor.lua). Click or
      the button's key opens it, 1-9, 0, -, = cast, the same key again casts entry 1; works in
      combat through secure handlers of our own, never Blizzard's. /gbars flyout dir
      up|down|left|right, /gbars flyout samekey on|off. Off while FallensFlyouts is loaded.
      Flyouts.lua, see there.
    * A master switch (/gbars on|off) and one switch per feature (/gbars <feature> on|off), all in
      GaarBarsForeverDB (account-wide), and one menu entry each for the hub.
    * /gbars for help, /gbars status for the hooks found, the buttons handled and whether the
      client answered with secrets.
    * GaarBarsForeverAPI, a small global table for GaarForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The addon runs exactly the same
      without the hub; the API only exposes the settings the slash command already changes.

  How it finds the buttons. By name (ActionButton1-12, MultiBarBottomLeftButton1-12, ...,
  MultiBar5-7Button1-12, BonusActionButton1-12, OverrideActionBarButton1-6, StanceButton1-10,
  PetActionButton1-10), plus whatever Blizzard's ActionBarButtonEventsFrame.frames lists, read
  only. Rescanned at PLAYER_ENTERING_WORLD.

  How it paints. A ticker of its own (5 times a second, visible buttons only) reads
  IsUsableAction, IsActionInRange and the cooldown and sets the colours and text. So that
  Blizzard's own update does not show its colour for a moment in between, the addon also runs
  right after it: hooksecurefunc on every Blizzard update function it finds - the 12.x mixin
  methods on each button (UpdateUsable, UpdateRangeIndicator, Update, UpdateHotkeys, SetHotkeys)
  and the older globals (ActionButton_UpdateUsable, ActionButton_UpdateRangeIndicator,
  ActionButton_Update, ActionButton_UpdateHotkeys, PetActionButton_SetHotkeys). /gbars status
  lists which exist. ActionButton_OnUpdate is deliberately not hooked: it runs every frame for
  every button, and the ticker already covers what it would give.

  Secret values (12.x engine). IsUsableAction, IsActionInRange and the cooldown may come back
  secret. A secret is never compared or tested: it goes only into a widget setter that takes it
  as it is, guarded - Texture:SetVertexColorFromBoolean for the icon colour, SetAlphaFromBoolean
  for a red overlay of the addon's own when both answers are secret, the Cooldown's own countdown
  numbers for the time. Without those setters the icon is left to Blizzard. Two secret booleans
  cannot be combined, so with a secret usable flag the icon is white or grey (no blue). Every
  secret answer is counted for /gbars status.

  Taint: Blizzard code is only followed, never replaced. No Blizzard function, script or table is
  written (hooksecurefunc only), no protected function is called, and no button is shown, hidden,
  moved or given an attribute. Only visual properties of non-secure regions change: the icon's
  vertex colour, the hotkey's text and colour, the macro name's alpha, the cooldown's countdown
  numbers, and textures, font strings and one plain frame per button that the addon creates
  itself (out of combat). Every client API is checked with type(...) == "function" first, every
  handler runs in pcall (the last error is kept for /gbars status).

  Shared helpers come from GaarForever's library (global GaarForever, Lib.lua, loaded first
  through ## Dependencies): the chat prefix, the secret checks, Num / Str, InCombat, the "56" /
  "2m" / "1h" cooldown text (TimeShort) and the menu drawing.
]]

local _G = _G
local ADDON_NAME, NS = ...
ADDON_NAME = ADDON_NAME or "GaarBarsForever"
NS = type(NS) == "table" and NS or {} -- shared with BookTab.lua (the spellbook tab)
local DOT = " \194\183 "

local VERSION = "1.6.0"

local BF = _G.GaarForever
local A = BF.NewAddon("GaarBarsForever", { title = "GaarBarsForever", version = VERSION })

local TICK = 0.2              -- seconds between ticker passes
local GCD_MAX = 1.5           -- a cooldown this short or shorter is the global cooldown
local RANGE_OVERLAY_ALPHA = 0.55

local RANGE_RGB = { 0.8, 0.1, 0.1 }
local MANA_RGB = { 0.3, 0.3, 1.0 }
local BLIZZ_MANA_RGB = { 0.5, 0.5, 1.0 }   -- Blizzard's own no-mana colour (manaColor off)
local GREY_RGB = { 0.4, 0.4, 0.4 }         -- Blizzard's unusable colour
local WHITE_RGB = { 1.0, 1.0, 1.0 }
local HOTKEY_RED_RGB = { 1.0, 0.1, 0.1 }
local HOTKEY_NORMAL_RGB = { 0.6, 0.6, 0.6 } -- fallback when the hotkey's own colour is unreadable

-- The features, in menu and help order. key = the saved key; cmd = what /gbars accepts besides
-- the key itself (lower case).
local FEATURES = {
    { key = "rangeColor", cmd = "range", default = true, label = "Red icon out of range" },
    { key = "manaColor", cmd = "mana", default = true, label = "Blue icon without mana" },
    { key = "cooldownText", cmd = "cooldown", default = true, label = "Cooldown numbers" },
    { key = "hotkeyShort", cmd = "hotkey", default = true, label = "Short hotkeys" },
    { key = "macroText", cmd = "macro", default = true, label = "Macro names" },
    { key = "outOfRangeHotkey", cmd = "rangehotkey", default = false,
      label = "Out of range: red hotkey instead of red icon" },
    { key = "lowRankWarn", cmd = "rank", default = true,
      label = "Orange ring on low-rank spells (spellbook open)" },
    { key = "bookMissingTab", cmd = "missing", default = true,
      label = "Spellbook tab: spells missing from your bars" },
    { key = "flyouts", cmd = "flyout", default = true,
      label = "Flyouts on action buttons (drop on the +)" },
}
local FEATURE_BY_CMD = {}
for _, f in ipairs(FEATURES) do
    FEATURE_BY_CMD[f.key:lower()] = f
    FEATURE_BY_CMD[f.cmd] = f
end

-- Every key GaarBarsForeverDB may hold.
local SAVED_KEYS = { enabled = true, flyoutDir = true, flyoutSameKeyCast = true }
for _, f in ipairs(FEATURES) do SAVED_KEYS[f.key] = true end

local ACTION_PREFIXES = {
    { "ActionButton", 12 }, { "MultiBarBottomLeftButton", 12 }, { "MultiBarBottomRightButton", 12 },
    { "MultiBarRightButton", 12 }, { "MultiBarLeftButton", 12 }, { "MultiBar5Button", 12 },
    { "MultiBar6Button", 12 }, { "MultiBar7Button", 12 }, { "BonusActionButton", 12 },
    { "OverrideActionBarButton", 6 },
}
local STANCE_PREFIX, STANCE_COUNT = "StanceButton", 10
local PET_PREFIX, PET_COUNT = "PetActionButton", 10

-- The Blizzard update functions the addon follows: a method on each button, or a global taking
-- the button first. What runs after each: "paint" (icon colours), "hotkey", or "all".
local METHOD_HOOKS = {
    { "UpdateUsable", "paint" }, { "UpdateRangeIndicator", "paint" }, { "Update", "all" },
    { "UpdateHotkeys", "hotkey" }, { "SetHotkeys", "hotkey" },
}
local GLOBAL_HOOKS = {
    { "ActionButton_UpdateUsable", "paint" }, { "ActionButton_UpdateRangeIndicator", "paint" },
    { "ActionButton_Update", "all" }, { "ActionButton_UpdateHotkeys", "hotkey" },
    { "PetActionButton_SetHotkeys", "hotkey" },
}

local db                  -- GaarBarsForeverDB, bound at ADDON_LOADED (never at file scope)
local list = {}           -- the button states, in scan order
local byButton = {}       -- Blizzard button -> its state
local counts = { action = 0, stance = 0, pet = 0 }
local hooksFound = {}     -- hook name -> number of buttons (methods) or true (globals)
local globalsHooked = {}
local lastError
local pendingFrames       -- an overlay frame was due in combat; create at PLAYER_REGEN_ENABLED
local ticker
local elapsedSince = 0

-- Secret answers seen, for /gbars status.
local secrets = { usable = 0, range = 0, cooldown = 0, setterMissing = 0, setterFailed = 0 }

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg) A:Print(msg) end

local function Fail(where, err)
    lastError = where .. ": " .. tostring(err)
end

local InCombat = BF.InCombat

-- Where the client hides a value it hands back a secret, which can be neither compared nor
-- tested. Those are checked before anything else touches the value. A table can be secret as a
-- whole too (issecrettable), which the library's IsSecret does not check.
local IsSecret = BF.IsSecret
local issecrettable = _G.issecrettable
local function Secret(v)
    if IsSecret(v) then return true end
    if type(v) == "table" and issecrettable and issecrettable(v) then return true end
    return false
end

local Num, Str = BF.Num, BF.Str

local function Now()
    return type(_G.GetTime) == "function" and (Num(_G.GetTime()) or 0) or 0
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function Enabled()
    return db ~= nil and db.enabled ~= false
end

local function On(key)
    return Enabled() and db[key] == true
end

local function YesNo(v) return v and "yes" or "no" end

local colorCache = {}
local function ColorObj(rgb)
    local c = colorCache[rgb]
    if c == nil then
        c = type(_G.CreateColor) == "function" and _G.CreateColor(rgb[1], rgb[2], rgb[3], 1) or false
        colorCache[rgb] = c
    end
    return c or nil
end

-- ---------------------------------------------------------------------------
-- Time text: "56", "2m", "1h", "2d" (GaarFramesForever's aura format, GaarPlatesForever's
-- rule formatter for the client's own countdown when the time is secret)
-- ---------------------------------------------------------------------------

-- The plain text is the library's GaarForever.TimeShort (the same format).
local TimeText = {}   -- Formatter
do
local UNITS = { { 60, "m" }, { 3600, "h" }, { 86400, "d" } }

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

-- The formatter, or false; and a line for /gbars status.
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

-- ---------------------------------------------------------------------------
-- Hotkey text
-- ---------------------------------------------------------------------------

-- "Ctrl-Shift-Mouse Button 4" -> "csM4". nil when there is nothing to shorten (no text, a secret,
-- or Blizzard's range dot).
local function ShortHotkey(text)
    text = Str(text)
    if not text then return nil end
    local dot = Str(_G.RANGE_INDICATOR)
    if dot and text == dot then return nil end
    local t = text
    t = t:gsub("[Mm]ouse [Bb]utton ?(%d+)", "M%1")
    t = t:gsub("^BUTTON(%d+)", "M%1"):gsub("%-BUTTON(%d+)", "-M%1")
    t = t:gsub("[Mm]iddle [Mm]ouse", "M3")
    t = t:gsub("[Mm]ouse [Ww]heel [Uu]p", "WU"):gsub("[Mm]ouse [Ww]heel [Dd]own", "WD")
    t = t:gsub("MOUSEWHEELUP", "WU"):gsub("MOUSEWHEELDOWN", "WD")
    t = t:gsub("Mw[Uu]", "WU"):gsub("Mw[Dd]", "WD")
    t = t:gsub("[Nn]um [Pp]ad ?", "N"):gsub("NUMPAD", "N")
    t = t:gsub("[Ss][Hh][Ii][Ff][Tt]%-", "s-"):gsub("[Cc][Tt][Rr][Ll]%-", "c-"):gsub("[Aa][Ll][Tt]%-", "a-")
    -- The modifiers in front lose their dash: "c-s-4" -> "cs4".
    local pre = ""
    while true do
        local m, rest = t:match("^([SCAsca])%-(.+)$")
        if not m then break end
        pre = pre .. m:lower()
        t = rest
    end
    return pre .. t
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

local function Region(b, key, suffix)
    local v = b[key]
    if type(v) == "table" then return v end
    if type(b.GetName) ~= "function" then return nil end
    local ok, name = pcall(b.GetName, b)
    name = ok and Str(name) or nil
    v = name and _G[name .. suffix]
    return type(v) == "table" and v or nil
end

local function ButtonID(st)
    local b = st.b
    if type(b.GetID) ~= "function" then return nil end
    local ok, id = pcall(b.GetID, b)
    return ok and Num(id) or nil
end

local function ActionSlot(st)
    local a = Num(st.b.action)
    if a and a > 0 then return a end
    return nil
end

local function Visible(st)
    local b = st.b
    if type(b.IsVisible) ~= "function" then return true end
    local ok, v = pcall(b.IsVisible, b)
    if not ok or Secret(v) then return true end
    return v and true or false
end

local function SetRGB(tex, rgb)
    if tex and type(tex.SetVertexColor) == "function" then tex:SetVertexColor(rgb[1], rgb[2], rgb[3]) end
end

-- The client picks the colour from a boolean it may hide from us: rgbTrue when true, rgbFalse
-- when false. Returns true when it took it.
local function ColorFromBoolean(region, flag, rgbTrue, rgbFalse)
    if not region or type(region.SetVertexColorFromBoolean) ~= "function" then
        secrets.setterMissing = secrets.setterMissing + 1
        return false
    end
    local cT, cF = ColorObj(rgbTrue), ColorObj(rgbFalse)
    if not cT or not cF then
        secrets.setterMissing = secrets.setterMissing + 1
        return false
    end
    local ok, err = pcall(region.SetVertexColorFromBoolean, region, flag, cT, cF)
    if not ok then
        secrets.setterFailed = secrets.setterFailed + 1
        Fail("SetVertexColorFromBoolean", err)
    end
    return ok
end

-- The plain frame of our own over a button: it holds the cooldown text above the swipe. Created
-- out of combat only.
local function EnsureOverlay(st)
    if st.overlay then return st.overlay end
    if InCombat() then
        pendingFrames = true
        return nil
    end
    local b = st.b
    local f = CreateFrame("Frame", nil, b)
    f:SetAllPoints(b)
    local lvl = type(b.GetFrameLevel) == "function" and Num(b:GetFrameLevel()) or nil
    local cd = st.cd
    local cdl = cd and type(cd.GetFrameLevel) == "function" and Num(cd:GetFrameLevel()) or nil
    local top = math.max(lvl or 0, cdl or 0)
    f:SetFrameLevel(top + 2)
    local w = type(b.GetWidth) == "function" and Num(b:GetWidth()) or nil
    local size = w and Clamp(math.floor(w * 0.42 + 0.5), 10, 18) or 16
    local fs = f:CreateFontString(nil, "OVERLAY")
    fs:SetFont(_G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, "OUTLINE")
    fs:SetPoint("CENTER", f, "CENTER", 0, 0)
    fs:SetTextColor(1, 1, 1)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    fs:Hide()
    st.overlay, st.cdText, st.cdSize = f, fs, size
    return f
end

-- A red texture of our own over the icon, for when both answers are secret.
local function RangeOverlay(st)
    if st.rangeTex then return st.rangeTex end
    local icon = st.icon
    if not icon or type(st.b.CreateTexture) ~= "function" then return nil end
    local layer, sub = "ARTWORK", 0
    if type(icon.GetDrawLayer) == "function" then
        local ok, l, s = pcall(icon.GetDrawLayer, icon)
        if ok and Str(l) then layer, sub = l, Num(s) or 0 end
    end
    local t = st.b:CreateTexture(nil, layer, nil, Clamp(sub + 1, -8, 7))
    t:SetAllPoints(icon)
    if type(t.SetColorTexture) == "function" then
        t:SetColorTexture(RANGE_RGB[1], RANGE_RGB[2], RANGE_RGB[3], 1)
    else
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        t:SetVertexColor(RANGE_RGB[1], RANGE_RGB[2], RANGE_RGB[3])
    end
    t:SetAlpha(0)
    st.rangeTex = t
    return t
end

local function HideRangeOverlay(st)
    if st.rangeTex then st.rangeTex:SetAlpha(0) end
end

-- ---------------------------------------------------------------------------
-- Painting: icon colour and hotkey colour
-- ---------------------------------------------------------------------------

local function ReadUsable(a)
    if type(_G.IsUsableAction) ~= "function" then return nil end
    local ok, usable, noMana = pcall(_G.IsUsableAction, a)
    if not ok then return nil end
    return true, usable, noMana
end

local function ReadRange(a)
    if type(_G.IsActionInRange) ~= "function" then return nil end
    local ok, inRange = pcall(_G.IsActionInRange, a)
    if not ok then return nil end
    return true, inRange
end

local function HasAction(a)
    if type(_G.HasAction) ~= "function" then return true end
    local ok, v = pcall(_G.HasAction, a)
    if not ok or Secret(v) then return true end
    return v and true or false
end

-- The hotkey back to the colour it had before the addon tinted it.
local function RestoreHotkeyColor(st)
    if not st.hkRed then return end
    st.hkRed = false
    local hk, c = st.hotkey, st.hkColor or HOTKEY_NORMAL_RGB
    if hk and type(hk.SetTextColor) == "function" then hk:SetTextColor(c[1], c[2], c[3]) end
end

local function PaintHotkeyRange(st, readOk, inRange, rSecret, out)
    local hk = st.hotkey
    if not hk then return end
    if not On("outOfRangeHotkey") or not readOk then
        RestoreHotkeyColor(st)
        return
    end
    if rSecret then
        -- Blizzard's own range indicator already reds the hotkey from the secret; only take it
        -- over where the client lets us pass the secret on.
        if type(hk.SetVertexColorFromBoolean) == "function" then
            if ColorFromBoolean(hk, inRange, st.hkColor or HOTKEY_NORMAL_RGB, HOTKEY_RED_RGB) then st.hkRed = true end
        end
        return
    end
    if out then
        if type(hk.SetTextColor) == "function" then
            hk:SetTextColor(HOTKEY_RED_RGB[1], HOTKEY_RED_RGB[2], HOTKEY_RED_RGB[3])
            st.hkRed = true
        end
    else
        RestoreHotkeyColor(st)
    end
end

local function Paint(st)
    if st.kind ~= "action" then return end
    local icon = st.icon
    local a = ActionSlot(st)
    if not icon or not a or not HasAction(a) then
        HideRangeOverlay(st)
        RestoreHotkeyColor(st)
        return
    end

    local iconRange = On("rangeColor") and not On("outOfRangeHotkey")
    local mana = On("manaColor")
    local wantIcon = iconRange or mana

    local okR, inRange = ReadRange(a)
    local rSecret = okR and Secret(inRange) or false
    local out = false
    if okR and not rSecret then out = (inRange == false or inRange == 0) end
    if rSecret then secrets.range = secrets.range + 1 end

    PaintHotkeyRange(st, okR, inRange, rSecret, out)

    if not wantIcon and not st.touched then
        HideRangeOverlay(st)
        return
    end

    local okU, usable, noMana = ReadUsable(a)
    local uSecret = okU and (Secret(usable) or Secret(noMana)) or false
    if uSecret then secrets.usable = secrets.usable + 1 end
    local manaRGB = mana and MANA_RGB or BLIZZ_MANA_RGB

    if not okU then
        -- No answer at all: leave the icon to Blizzard.
        HideRangeOverlay(st)
        st.touched = false
        return
    end

    if not uSecret then
        local base = usable and WHITE_RGB or (noMana and manaRGB or GREY_RGB)
        if iconRange and not rSecret and out then
            SetRGB(icon, RANGE_RGB)
            HideRangeOverlay(st)
        elseif iconRange and rSecret then
            if ColorFromBoolean(icon, inRange, base, RANGE_RGB) then
                HideRangeOverlay(st)
            else
                SetRGB(icon, base)
                local t = RangeOverlay(st)
                if t and type(t.SetAlphaFromBoolean) == "function" then
                    pcall(t.SetAlphaFromBoolean, t, inRange, 0, RANGE_OVERLAY_ALPHA)
                end
            end
        else
            SetRGB(icon, base)
            HideRangeOverlay(st)
        end
    else
        if iconRange and not rSecret and out then
            SetRGB(icon, RANGE_RGB)
            HideRangeOverlay(st)
        else
            -- Usable is secret: white or grey (blue too when the mana flag is plain).
            local other = (not Secret(noMana)) and (noMana and manaRGB or GREY_RGB) or GREY_RGB
            ColorFromBoolean(icon, usable, WHITE_RGB, other)
            if iconRange and rSecret then
                local t = RangeOverlay(st)
                if t and type(t.SetAlphaFromBoolean) == "function" then
                    pcall(t.SetAlphaFromBoolean, t, inRange, 0, RANGE_OVERLAY_ALPHA)
                end
            else
                HideRangeOverlay(st)
            end
        end
    end
    st.touched = wantIcon
end

-- ---------------------------------------------------------------------------
-- Hotkey text and macro names
-- ---------------------------------------------------------------------------

local function ApplyHotkey(st)
    local hk = st.hotkey
    if not hk or type(hk.GetText) ~= "function" then return end
    local ok, text = pcall(hk.GetText, hk)
    text = ok and Str(text) or nil
    if On("hotkeyShort") then
        -- Our own short text, or a text already found to need no shortening: nothing to do.
        if not text or text == st.hkShort or text == st.hkSeen then return end
        local short = ShortHotkey(text)
        if short and short ~= text then
            st.hkLong, st.hkShort, st.hkSeen = text, short, nil
            hk:SetText(short)
        else
            st.hkLong, st.hkShort, st.hkSeen = nil, nil, text
        end
    elseif st.hkShort then
        -- Put Blizzard's long text back, unless Blizzard has written a new one since.
        if text == st.hkShort and st.hkLong then hk:SetText(st.hkLong) end
        st.hkLong, st.hkShort, st.hkSeen = nil, nil, nil
    else
        st.hkSeen = nil
    end
end

local function ApplyMacro(st)
    local n = st.name
    if not n or type(n.SetAlpha) ~= "function" then return end
    local hide = Enabled() and db.macroText == false
    if hide then
        n:SetAlpha(0)
        st.nameHidden = true
    elseif st.nameHidden then
        n:SetAlpha(1)
        st.nameHidden = false
    end
end

-- ---------------------------------------------------------------------------
-- Cooldown numbers
-- ---------------------------------------------------------------------------

-- start, duration, enabled, onGCD (true/nil), secret (true when the client hid the timing).
local function ReadCooldown(st)
    if st.kind == "action" then
        local a = ActionSlot(st)
        if not a then return nil end
        local C = _G.C_ActionBar
        if type(C) == "table" and type(C.GetActionCooldown) == "function" then
            local ok, r1, r2, r3 = pcall(C.GetActionCooldown, a)
            if ok and type(r1) == "table" and not Secret(r1) then
                local s, d, e, g = r1.startTime, r1.duration, r1.isEnabled, r1.isOnGCD
                local gcd = (not Secret(g)) and g == true or nil
                if Secret(s) or Secret(d) or Secret(e) then return nil, nil, nil, gcd, true end
                return s, d, e, gcd, false
            elseif ok and r1 ~= nil and type(r1) ~= "table" then
                if Secret(r1) or Secret(r2) or Secret(r3) then return nil, nil, nil, nil, true end
                return r1, r2, r3, nil, false
            elseif ok and Secret(r1) then
                return nil, nil, nil, nil, true
            end
        end
        if type(_G.GetActionCooldown) ~= "function" then return nil end
        local ok, s, d, e = pcall(_G.GetActionCooldown, a)
        if not ok then return nil end
        if Secret(s) or Secret(d) or Secret(e) then return nil, nil, nil, nil, true end
        return s, d, e, nil, false
    end
    local id = ButtonID(st)
    if not id then return nil end
    local fn = st.kind == "stance" and _G.GetShapeshiftFormCooldown or _G.GetPetActionCooldown
    if type(fn) ~= "function" then return nil end
    local ok, s, d, e = pcall(fn, id)
    if not ok then return nil end
    if Secret(s) or Secret(d) or Secret(e) then return nil, nil, nil, nil, true end
    return s, d, e, nil, false
end

-- The cooldown's own countdown numbers, styled: for a secret timing only the client can draw.
local function ClientNumbers(st, show)
    local cd = st.cd
    if not cd or type(cd.SetHideCountdownNumbers) ~= "function" then return false end
    if not st.cdTouched then
        st.cdTouched = true
        st.cdOrigHide = false   -- Blizzard's action-button cooldowns leave the numbers to the CVar
        if type(cd.GetHideCountdownNumbers) == "function" then
            local ok, v = pcall(cd.GetHideCountdownNumbers, cd)
            if ok and not Secret(v) then st.cdOrigHide = v and true or false end
        end
    end
    pcall(cd.SetHideCountdownNumbers, cd, not show)
    if show and not st.cdStyled then
        st.cdStyled = true
        local size = st.cdSize or 16
        if type(cd.GetCountdownFontString) == "function" then
            local ok, fs = pcall(cd.GetCountdownFontString, cd)
            if ok and type(fs) == "table" and type(fs.GetFont) == "function" then
                local f, sz, fl = fs:GetFont()
                if Str(f) and Num(sz) then st.cdOrigFont = { f, sz, fl } end
                pcall(fs.SetFont, fs, _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, "OUTLINE")
                st.cdFontString = fs
            end
        elseif type(cd.SetCountdownFont) == "function" and type(_G.CreateFont) == "function" then
            local name = "GaarBarsForeverCountdownFont" .. size
            local font = _G[name]
            if not font then
                font = _G.CreateFont(name)
                font:SetFont(_G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, "OUTLINE")
            end
            pcall(cd.SetCountdownFont, cd, name)
        end
        if type(cd.SetCountdownFormatter) == "function" then
            local fmt = TimeText.Formatter()
            if fmt then pcall(cd.SetCountdownFormatter, cd, fmt) end
        end
    end
    return true
end

-- Hand the cooldown's numbers back exactly as Blizzard had them.
local function RestoreClientNumbers(st)
    local cd = st.cd
    if not cd or not st.cdTouched then return end
    st.cdTouched = false
    pcall(cd.SetHideCountdownNumbers, cd, st.cdOrigHide and true or false)
    if st.cdStyled then
        st.cdStyled = false
        if st.cdFontString and st.cdOrigFont then
            local o = st.cdOrigFont
            pcall(st.cdFontString.SetFont, st.cdFontString, o[1], o[2], o[3])
        end
        if type(cd.SetCountdownFormatter) == "function" then pcall(cd.SetCountdownFormatter, cd, nil) end
    end
end

local function UpdateCooldown(st, now)
    if not On("cooldownText") then
        if st.cdText then st.cdText:Hide() end
        RestoreClientNumbers(st)
        return
    end
    local fs = st.cdText or (EnsureOverlay(st) and st.cdText)
    local s, d, e, gcd, secret = ReadCooldown(st)
    if secret then
        secrets.cooldown = secrets.cooldown + 1
        if fs then fs:Hide() end
        ClientNumbers(st, not gcd)
        return
    end
    -- Plain: our own text; the client's numbers stay off so they never show twice.
    if st.cd and (st.cdTouched or type(st.cd.SetHideCountdownNumbers) == "function") then ClientNumbers(st, false) end
    if not fs then return end
    s, d = Num(s), Num(d)
    local enabled = not (e == false or e == 0)
    if gcd or not s or not d or not enabled or s <= 0 or d <= GCD_MAX then
        fs:Hide()
        return
    end
    local left = s + d - now
    if left <= 0 then
        fs:Hide()
        return
    end
    fs:SetText(BF.TimeShort(left))
    fs:Show()
end

-- ---------------------------------------------------------------------------
-- Scan, hooks, ticker
-- ---------------------------------------------------------------------------

local function Run(st, what)
    if not Enabled() then return end
    if what == "paint" or what == "all" then Paint(st) end
    if what == "hotkey" or what == "all" then ApplyHotkey(st) end
    if what == "all" then ApplyMacro(st) end
end

local function Register(b, kind)
    if type(b) ~= "table" or byButton[b] then return end
    local st = { b = b, kind = kind }
    st.icon = Region(b, "icon", "Icon")
    st.hotkey = Region(b, "HotKey", "HotKey")
    st.name = Region(b, "Name", "Name")
    st.cd = Region(b, "cooldown", "Cooldown")
    if st.hotkey and type(st.hotkey.GetTextColor) == "function" then
        local ok, r, g, bl = pcall(st.hotkey.GetTextColor, st.hotkey)
        if ok and Num(r) and Num(g) and Num(bl) then st.hkColor = { r, g, bl } end
    end
    byButton[b] = st
    list[#list + 1] = st
    counts[kind] = counts[kind] + 1

    if type(_G.hooksecurefunc) == "function" then
        for _, h in ipairs(METHOD_HOOKS) do
            local m, what = h[1], h[2]
            if type(b[m]) == "function" then
                local ok = pcall(_G.hooksecurefunc, b, m, function()
                    local okRun, err = pcall(Run, st, what)
                    if not okRun then Fail(m, err) end
                end)
                if ok then hooksFound[m] = (hooksFound[m] or 0) + 1 end
            end
        end
    end
    EnsureOverlay(st)
    if Enabled() then
        ApplyHotkey(st)
        ApplyMacro(st)
    end
end

local function HookGlobals()
    if type(_G.hooksecurefunc) ~= "function" then return end
    for _, h in ipairs(GLOBAL_HOOKS) do
        local name, what = h[1], h[2]
        if not globalsHooked[name] and type(_G[name]) == "function" then
            local ok = pcall(_G.hooksecurefunc, name, function(self)
                local st = byButton[self]
                if not st then return end
                local okRun, err = pcall(Run, st, what)
                if not okRun then Fail(name, err) end
            end)
            if ok then
                globalsHooked[name] = true
                hooksFound[name] = true
            end
        end
    end
end

local function Scan()
    for _, p in ipairs(ACTION_PREFIXES) do
        for i = 1, p[2] do Register(_G[p[1] .. i], "action") end
    end
    for i = 1, STANCE_COUNT do Register(_G[STANCE_PREFIX .. i], "stance") end
    for i = 1, PET_COUNT do Register(_G[PET_PREFIX .. i], "pet") end
    -- Whatever else Blizzard registers as an action button (read only).
    local ev = _G.ActionBarButtonEventsFrame
    if type(ev) == "table" and type(ev.frames) == "table" then
        for _, b in pairs(ev.frames) do
            if type(b) == "table" and not byButton[b] then Register(b, "action") end
        end
    end
    HookGlobals()
end

-- ---------------------------------------------------------------------------
-- Low-rank ring (lowRankWarn)
--
-- While the spellbook is open, an action button whose spell is not the highest known rank of
-- that spell gets a pulsing orange ring. The ring is a frame of our own, a child of the button
-- (created and shown out of combat only; hiding it works in combat through a stopped animation
-- and alpha 0). Nothing is compared in combat: the state then stays as it was.
-- ---------------------------------------------------------------------------

local RING_RGB = { 1.0, 0.5, 0.0 }
local RING_TEXTURE = "Interface\\Buttons\\UI-ActionButton-Border"
local RING_SCALE = 1.8
local RING_PULSE = 0.8        -- seconds from bright to dim; it bounces back
local RING_LOW_ALPHA = 0.35

-- Frames that count as "the spellbook": Classic's SpellBookFrame and the retail-style
-- PlayerSpellsFrame (Blizzard_PlayerSpells, load on demand). Whichever exists gets hooked.
local SPELLBOOK_FRAMES = { "SpellBookFrame", "PlayerSpellsFrame" }
local SPELLBOOK_ADDONS = { Blizzard_PlayerSpells = true, Blizzard_SpellBookUI = true,
    Blizzard_SpellBook = true, Blizzard_PlayerSpellsFrame = true }
local spellbookHooked = {}
local spellbookOpen = false

local function SpellName(id)
    local C = _G.C_Spell
    if type(C) == "table" and type(C.GetSpellName) == "function" then
        local ok, n = pcall(C.GetSpellName, id)
        if ok and not Secret(n) then return Str(n) end
    end
    if type(_G.GetSpellInfo) == "function" then
        local ok, n = pcall(_G.GetSpellInfo, id)
        if ok and not Secret(n) and type(n) == "string" then return n end
    end
    return nil
end

-- "Rank 3" -> 3; nil when the spell has no rank.
local function SpellRank(id)
    local sub
    local C = _G.C_Spell
    if type(C) == "table" and type(C.GetSpellSubtext) == "function" then
        local ok, s = pcall(C.GetSpellSubtext, id)
        if ok and not Secret(s) then sub = Str(s) end
    end
    if not sub and type(_G.GetSpellSubtext) == "function" then
        local ok, s = pcall(_G.GetSpellSubtext, id)
        if ok and not Secret(s) then sub = Str(s) end
    end
    local n = sub and sub:match("(%d+)")
    return n and tonumber(n) or nil
end

-- name -> highest rank number the player knows, from the spellbook. Nil when no spellbook API
-- answered.
local function KnownMaxRanks()
    local max = {}
    local seen = false
    local function Add(id)
        id = Num(id)
        if not id or id <= 0 then return end
        local name, rank = SpellName(id), SpellRank(id)
        seen = true
        if name and rank and (not max[name] or rank > max[name]) then max[name] = rank end
    end
    local SB = _G.C_SpellBook
    if type(SB) == "table" and type(SB.GetNumSpellBookSkillLines) == "function"
        and type(SB.GetSpellBookSkillLineInfo) == "function" and type(SB.GetSpellBookItemInfo) == "function" then
        local bank = _G.Enum and _G.Enum.SpellBookSpellBank and _G.Enum.SpellBookSpellBank.Player or 0
        local spellType = _G.Enum and _G.Enum.SpellBookItemType and _G.Enum.SpellBookItemType.Spell
        local okN, lines = pcall(SB.GetNumSpellBookSkillLines)
        lines = okN and Num(lines) or 0
        for i = 1, lines do
            local okL, li = pcall(SB.GetSpellBookSkillLineInfo, i)
            if okL and type(li) == "table" and not Secret(li) then
                local off, count = Num(li.itemIndexOffset) or 0, Num(li.numSpellBookItems) or 0
                for j = off + 1, off + count do
                    local okI, info = pcall(SB.GetSpellBookItemInfo, j, bank)
                    if okI and type(info) == "table" and not Secret(info)
                        and (spellType == nil or info.itemType == spellType) and not info.isOffSpec then
                        Add(info.spellID or info.actionID)
                    end
                end
            end
        end
    elseif type(_G.GetNumSpellTabs) == "function" and type(_G.GetSpellTabInfo) == "function"
        and type(_G.GetSpellBookItemInfo) == "function" then
        local okN, tabs = pcall(_G.GetNumSpellTabs)
        tabs = okN and Num(tabs) or 0
        for t = 1, tabs do
            local okT, _, _, off, count = pcall(_G.GetSpellTabInfo, t)
            off, count = okT and Num(off) or 0, okT and Num(count) or 0
            for j = off + 1, off + count do
                local okI, kind, id = pcall(_G.GetSpellBookItemInfo, j, "spell")
                if okI and kind == "SPELL" then Add(id) end
            end
        end
    end
    return seen and max or nil
end

-- The spell name when the button holds a lower rank than a rank the player knows, else nil.
local function BarLowName(st, maxRanks)
    if st.kind ~= "action" or type(_G.GetActionInfo) ~= "function" then return nil end
    local slot = ActionSlot(st)
    if not slot then return nil end
    local ok, kind, id = pcall(_G.GetActionInfo, slot)
    if not ok or Secret(kind) or Secret(id) or kind ~= "spell" then return nil end
    id = Num(id)
    if not id then return nil end
    local name, rank = SpellName(id), SpellRank(id)
    local best = name and maxRanks[name]
    if rank ~= nil and best ~= nil and rank < best then return name end
    return nil
end

-- Builds our pulsing ring as a child of `parent`, centred on `anchor`, sized from `w`.
-- `x`/`y` offset the centre from `anchor` (default 0); `anchorPoint` defaults to CENTER.
local function BuildRing(parent, anchor, w, anchorPoint, x, y)
    w = (w and w > 0) and w or 36
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w * RING_SCALE, w * RING_SCALE)
    f:SetPoint("CENTER", anchor, anchorPoint or "CENTER", x or 0, y or 0)
    local lvl = type(parent.GetFrameLevel) == "function" and Num(parent:GetFrameLevel()) or 0
    f:SetFrameLevel((lvl or 0) + 3)
    local tex = f:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(f)
    tex:SetTexture(RING_TEXTURE)
    tex:SetBlendMode("ADD")
    tex:SetVertexColor(RING_RGB[1], RING_RGB[2], RING_RGB[3])
    local ag = f:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(RING_LOW_ALPHA)
    a:SetDuration(RING_PULSE)
    f.pulse = ag
    f:SetAlpha(0)
    f:Hide()
    return f
end

local function EnsureRing(st)
    if st.rankRing then return st.rankRing end
    if InCombat() then return nil end
    local b = st.b
    local w = type(b.GetWidth) == "function" and Num(b:GetWidth()) or nil
    st.rankRing = BuildRing(b, b, w)
    return st.rankRing
end

local function SetRing(st, on)
    if on then
        local f = EnsureRing(st)
        if f and not st.rankOn then
            f:SetAlpha(1)
            f:Show()
            f.pulse:Play()
            st.rankOn = true
        end
    elseif st.rankOn and st.rankRing then
        local f = st.rankRing
        f.pulse:Stop()
        f:SetAlpha(0)
        if not InCombat() then f:Hide() end
        st.rankOn = false
    end
end

-- ---- Spellbook entries -------------------------------------------------------------------
-- An entry gets the ring when its spell is the highest known rank of a name and an action bar
-- holds a lower rank of the same name. Classic's SpellButton1..12 and the retail-style
-- PlayerSpellsFrame.SpellBookFrame (paged item frames) are both read; whichever answers wins.

local BOOK_POLL = 0.25
local bookState = setmetatable({}, { __mode = "k" }) -- entry button -> { ring =, on = }
local bookInfo = { variant = "none", entries = 0, rings = 0, err = nil }
local bookMax, bookLow, bookDirty = nil, nil, true
local bookSig = nil
local bookElapsed = 0

local function FieldOf(t, key)
    local ok, v = pcall(function() return t[key] end)
    if ok and not Secret(v) then return v end
    return nil
end

local function CallOf(t, method, ...)
    local f = FieldOf(t, method)
    if type(f) ~= "function" then return nil end
    local ok, a = pcall(f, t, ...)
    if ok and not Secret(a) then return a end
    return nil
end

-- Spell id at a spellbook slot, only for plain spells.
local function SlotSpellID(slot, pet)
    slot = Num(slot)
    if not slot then return nil end
    local SB = _G.C_SpellBook
    if type(SB) == "table" and type(SB.GetSpellBookItemInfo) == "function" then
        local E = _G.Enum
        local bank = E and E.SpellBookSpellBank and (pet and E.SpellBookSpellBank.Pet or E.SpellBookSpellBank.Player)
            or (pet and 1 or 0)
        local ok, info = pcall(SB.GetSpellBookItemInfo, slot, bank)
        if ok and type(info) == "table" and not Secret(info) then
            local spellType = E and E.SpellBookItemType and E.SpellBookItemType.Spell
            if spellType == nil or info.itemType == spellType then
                return Num(info.spellID or info.actionID)
            end
        end
    elseif type(_G.GetSpellBookItemInfo) == "function" then
        local ok, kind, id = pcall(_G.GetSpellBookItemInfo, slot, pet and "pet" or "spell")
        if ok and not Secret(kind) and kind == "SPELL" then return Num(id) end
    end
    return nil
end

local function IsRegion(v)
    return type(v) == "table" and type(v.GetWidth) == "function"
end

-- Icon region of a spellbook entry, or nil. Classic's SpellButtonN is itself the icon holder
-- (IconTexture child); paged entries are wide frames whose icon lives on entry.Button.
local function EntryIcon(btn)
    for _, k in ipairs({ "IconTexture", "Icon", "icon" }) do
        local v = FieldOf(btn, k)
        if IsRegion(v) then return v end
    end
    local n = CallOf(btn, "GetName")
    local g = type(n) == "string" and _G[n .. "IconTexture"] or nil
    if IsRegion(g) then return g end
    for _, k in ipairs({ "Button", "button", "SpellButton", "ItemButton" }) do
        local b = FieldOf(btn, k)
        if type(b) == "table" then
            for _, ik in ipairs({ "Icon", "IconTexture", "icon" }) do
                local v = FieldOf(b, ik)
                if IsRegion(v) then return v end
            end
            if IsRegion(b) then return b end
        end
    end
    return nil
end

-- Visible spellbook entries as { btn =, id = } and the variant name.
local function BookEntries()
    local out = {}
    -- Classic: SpellButton1..12, slot from SpellBook_GetSpellBookSlot.
    if type(_G.SpellButton1) == "table" and type(_G.SpellBook_GetSpellBookSlot) == "function" then
        local sbf = _G.SpellBookFrame
        local pet = type(sbf) == "table" and FieldOf(sbf, "bookType") == "pet"
        for i = 1, 12 do
            local btn = _G["SpellButton" .. i]
            if type(btn) == "table" and CallOf(btn, "IsShown") then
                local ok, slot = pcall(_G.SpellBook_GetSpellBookSlot, btn)
                local id = ok and SlotSpellID(slot, pet) or nil
                if id then out[#out + 1] = { btn = btn, id = id } end
            end
        end
        if #out > 0 or CallOf(_G.SpellBookFrame, "IsShown") then return out, "SpellButton" end
    end
    -- Retail-style: paged item frames under PlayerSpellsFrame.SpellBookFrame.
    local psf = _G.PlayerSpellsFrame
    local sb = type(psf) == "table" and FieldOf(psf, "SpellBookFrame") or nil
    local paged = type(sb) == "table" and FieldOf(sb, "PagedSpellsFrame") or nil
    if type(paged) == "table" and type(FieldOf(paged, "EnumerateFrames")) == "function" then
        local ok = pcall(function()
            for _, el in paged:EnumerateFrames() do
                if type(el) == "table" and CallOf(el, "IsShown") and CallOf(el, "IsVisible") ~= false then
                    -- Entries are pooled: read what is bound NOW, live getter first, cached
                    -- fields last, so a recycled frame never keeps its previous spell.
                    local id = Num(CallOf(el, "GetSpellID"))
                    if not id then
                        local slot = FieldOf(el, "slotIndex")
                        if slot then id = SlotSpellID(slot, FieldOf(el, "spellBank") == 1) end
                    end
                    if not id then
                        local info = FieldOf(el, "spellBookItemInfo")
                        if type(info) == "table" and not Secret(info) then
                            id = Num(FieldOf(info, "spellID") or FieldOf(info, "actionID"))
                        end
                    end
                    if id then out[#out + 1] = { btn = el, id = id } end
                end
            end
        end)
        if ok then return out, "PagedSpellsFrame" end
    end
    return out, "none"
end

local function SetBookRing(btn, on)
    local st = bookState[btn]
    if on then
        if not st then
            if InCombat() then return end
            st = {}
            bookState[btn] = st
        end
        if not st.ring then
            if InCombat() then return end
            local icon = EntryIcon(btn)
            if icon then
                -- Square from the icon's smaller side, centred on the icon.
                local iw, ih = Num(icon:GetWidth()), Num(icon:GetHeight())
                local side = (iw and ih) and math.min(iw, ih) or iw or ih
                st.ring = BuildRing(btn, icon, side)
            else
                -- No icon child: never use the entry width. Square of entry height, centred
                -- half a height in from the entry's left edge.
                local h = Num(CallOf(btn, "GetHeight"))
                if not (h and h > 0) then h = 36 end
                st.ring = BuildRing(btn, btn, h, "LEFT", h / 2, 0)
            end
        end
        if not st.on then
            st.ring:SetAlpha(1)
            st.ring:Show()
            st.ring.pulse:Play()
            st.on = true
        end
    elseif st and st.on and st.ring then
        st.ring.pulse:Stop()
        st.ring:SetAlpha(0)
        if not InCombat() then st.ring:Hide() end
        st.on = false
    end
end

local function HideBookRings()
    for btn in pairs(bookState) do SetBookRing(btn, false) end
    bookInfo.rings = 0
    bookSig = nil
end

-- Recomputes the book's rings. `force` rescans the bars and spellbook ranks too.
local function RefreshBook(force)
    if not (spellbookOpen and On("lowRankWarn")) then
        HideBookRings()
        return
    end
    if InCombat() then return end
    if force or bookDirty or not bookMax then
        bookMax = KnownMaxRanks()
        bookLow = {}
        if bookMax then
            for _, st in ipairs(list) do
                local ok, n = pcall(BarLowName, st, bookMax)
                if ok and n then bookLow[n] = true end
            end
        end
        bookDirty = false
        bookSig = nil
    end
    local entries, variant = BookEntries()
    bookInfo.variant = variant
    bookInfo.entries = #entries
    local seen, rings = {}, 0
    for _, e in ipairs(entries) do
        local want = false
        if bookMax and bookLow then
            local name, rank = SpellName(e.id), SpellRank(e.id)
            want = name ~= nil and rank ~= nil and bookLow[name] == true and bookMax[name] == rank
        end
        SetBookRing(e.btn, want)
        seen[e.btn] = true
        if bookState[e.btn] then bookState[e.btn].id = want and e.id or nil end
        if want then rings = rings + 1 end
    end
    for btn, st in pairs(bookState) do
        if st.on and not seen[btn] then SetBookRing(btn, false) end
    end
    bookInfo.rings = rings
end

local function SafeRefreshBook(force)
    local ok, err = pcall(RefreshBook, force)
    if not ok then bookInfo.err = tostring(err); Fail("book", err) end
end

-- Page and tab changes have no event we can rely on: poll lightly while the book is open.
local bookDriver = CreateFrame("Frame")
bookDriver:Hide()
bookDriver:SetScript("OnUpdate", function(_, elapsed)
    bookElapsed = bookElapsed + (elapsed or 0)
    if bookElapsed < BOOK_POLL then return end
    bookElapsed = 0
    SafeRefreshBook(false)
end)

-- Paged book: hook the Blizzard refresh path (hooksecurefunc only) so recycled entry frames are
-- re-evaluated on page / tab / search changes. Poll stays as a backstop.
local pagedHooked = {}
local function HookPagedBook()
    if type(_G.hooksecurefunc) ~= "function" then return end
    local psf = _G.PlayerSpellsFrame
    local sb = type(psf) == "table" and FieldOf(psf, "SpellBookFrame") or nil
    local paged = type(sb) == "table" and FieldOf(sb, "PagedSpellsFrame") or nil
    for _, obj in ipairs({ paged, sb }) do
        if type(obj) == "table" and not pagedHooked[obj] then
            pagedHooked[obj] = true
            for _, m in ipairs({ "DisplayViewsForCurrentPage", "SetCurrentPage", "SetDataProvider",
                    "UpdateDisplayedSpells", "UpdateAllSpellData", "OnShow", "Update" }) do
                if type(obj[m]) == "function" then
                    pcall(_G.hooksecurefunc, obj, m, function() bookElapsed = BOOK_POLL end)
                end
            end
        end
    end
end

local function RefreshRank()
    HookPagedBook()
    if not db then return end
    local show = spellbookOpen and On("lowRankWarn")
    bookDirty = true
    if show then bookDriver:Show() else bookDriver:Hide() end
    if show and InCombat() then return end -- keep the state as it is
    local maxRanks = show and KnownMaxRanks() or nil
    for _, st in ipairs(list) do
        local want = false
        if maxRanks then
            local ok, r = pcall(BarLowName, st, maxRanks)
            want = ok and r ~= nil or false
        end
        SetRing(st, want)
    end
    SafeRefreshBook(true)
end

local function SafeRefreshRank()
    local ok, err = pcall(RefreshRank)
    if not ok then Fail("rank", err) end
end

local function AnySpellbookShown()
    for _, name in ipairs(SPELLBOOK_FRAMES) do
        local f = _G[name]
        if type(f) == "table" and type(f.IsShown) == "function" then
            local ok, v = pcall(f.IsShown, f)
            if ok and not Secret(v) and v then return true end
        end
    end
    return false
end

local function HookSpellbook()
    for _, name in ipairs(SPELLBOOK_FRAMES) do
        local f = _G[name]
        if type(f) == "table" and not spellbookHooked[name] and type(f.HookScript) == "function" then
            local ok = pcall(function()
                f:HookScript("OnShow", function() spellbookOpen = true; SafeRefreshRank() end)
                f:HookScript("OnHide", function() spellbookOpen = AnySpellbookShown(); SafeRefreshRank() end)
            end)
            if ok then spellbookHooked[name] = true end
        end
    end
    spellbookOpen = AnySpellbookShown()
end

local function Tick()
    if not Enabled() then return end
    local now = Now()
    for _, st in ipairs(list) do
        if Visible(st) then
            Paint(st)
            ApplyHotkey(st)
            UpdateCooldown(st, now)
        elseif st.cdText then
            st.cdText:Hide()
        end
    end
end

local function SafeTick()
    local ok, err = pcall(Tick)
    if not ok then Fail("tick", err) end
end

-- Everything back to Blizzard's look (the master switch off), or re-applied (on).
local function ApplyAll()
    for _, st in ipairs(list) do
        if not Enabled() then
            -- Restore: the colours Blizzard would use, then stop touching the button.
            if st.touched then
                local a = ActionSlot(st)
                local okU, usable, noMana = false, nil, nil
                if a then okU, usable, noMana = ReadUsable(a) end
                if okU and not Secret(usable) and not Secret(noMana) then
                    SetRGB(st.icon, usable and WHITE_RGB or (noMana and BLIZZ_MANA_RGB or GREY_RGB))
                elseif okU then
                    ColorFromBoolean(st.icon, usable, WHITE_RGB, GREY_RGB)
                else
                    SetRGB(st.icon, WHITE_RGB)
                end
                st.touched = false
            end
            HideRangeOverlay(st)
            RestoreHotkeyColor(st)
            if st.hkShort and st.hotkey then
                local ok, text = pcall(st.hotkey.GetText, st.hotkey)
                if ok and Str(text) == st.hkShort and st.hkLong then st.hotkey:SetText(st.hkLong) end
                st.hkLong, st.hkShort = nil, nil
            end
            if st.nameHidden and st.name then
                st.name:SetAlpha(1)
                st.nameHidden = false
            end
            if st.cdText then st.cdText:Hide() end
            RestoreClientNumbers(st)
        else
            ApplyHotkey(st)
            ApplyMacro(st)
        end
    end
    if Enabled() then SafeTick() end
    SafeRefreshRank()
    local BT = NS.BookTab
    if BT and type(BT.Apply) == "function" then
        local ok, err = pcall(BT.Apply)
        if not ok then Fail("booktab", err) end
    end
    local FO = NS.Flyouts
    if FO and type(FO.Apply) == "function" then
        local ok, err = pcall(FO.Apply)
        if not ok then Fail("flyouts", err) end
    end
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function SetEnabled(on, quiet)
    db.enabled = on and true or false
    local ok, err = pcall(ApplyAll)
    if not ok then Fail("apply", err) end
    if not quiet then Print(on and "on." or "off: the action buttons look as Blizzard draws them.") end
end

local function SetFeature(f, on, quiet)
    db[f.key] = on and true or false
    local ok, err = pcall(function()
        -- A feature switched off hands its part back first, then everything is re-applied.
        if not on then
            for _, st in ipairs(list) do
                if f.key == "hotkeyShort" then ApplyHotkey(st)
                elseif f.key == "macroText" then ApplyMacro(st)
                elseif f.key == "cooldownText" then
                    if st.cdText then st.cdText:Hide() end
                    RestoreClientNumbers(st)
                elseif f.key == "outOfRangeHotkey" then RestoreHotkeyColor(st)
                end
            end
        end
        ApplyAll()
    end)
    if not ok then Fail("apply", err) end
    if not quiet then
        Print(f.label .. ": " .. (on and "on" or "off") .. "." .. (Enabled() and "" or " (the addon is off: /gbars on)"))
    end
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

-- The intro GaarForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "Clearer action buttons: a red icon when out of range, a blue icon when you lack mana, energy or rage, big cooldown numbers (56, 2m, 1h) and short hotkey labels (Mouse Button 4 becomes M4). Every part has its own switch. Nice to know: /gbars <feature> on|off; /gbars off gives every button back exactly as Blizzard draws it; the global cooldown gets no number."

local function PrintHelp()
    Print(INTRO)
    Print("/gbars on | /gbars off - switch the addon on or off")
    for _, f in ipairs(FEATURES) do
        Print(string.format("/gbars %s on|off - %s (now %s, default %s)", f.cmd, f.label,
            db[f.key] and "on" or "off", f.default and "on" or "off"))
    end
    Print("/gbars flyouts - the flyout editor")
    Print("/gbars flyout dir up|down|left|right - which way flyouts open (now " .. tostring(db.flyoutDir or "up") .. ")")
    Print("/gbars flyout samekey on|off - a flyout button's key again while it is open casts entry 1 (now "
        .. (db.flyoutSameKeyCast == false and "off" or "on") .. ")")
    Print("/gbars status - the hooks found, the buttons handled and whether the client hid any values")
end

local function PrintStatus()
    Print("version " .. VERSION .. "   enabled: " .. YesNo(Enabled()))
    local parts = {}
    for _, f in ipairs(FEATURES) do parts[#parts + 1] = f.key .. " " .. (db[f.key] and "on" or "off") end
    Print("features: " .. table.concat(parts, ", "))
    Print(string.format("buttons handled: %d action, %d stance, %d pet (%d in all)",
        counts.action, counts.stance, counts.pet, #list))
    local found, missing = {}, {}
    for _, h in ipairs(METHOD_HOOKS) do
        local n = hooksFound[h[1]]
        if n then found[#found + 1] = h[1] .. " (" .. n .. ")" else missing[#missing + 1] = h[1] end
    end
    for _, h in ipairs(GLOBAL_HOOKS) do
        if hooksFound[h[1]] then found[#found + 1] = h[1] else missing[#missing + 1] = h[1] end
    end
    Print("hooks found: " .. (#found > 0 and table.concat(found, ", ") or "none (the ticker still runs)"))
    Print("hooks not on this client: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
    Print(string.format("secret answers: usable %d, range %d, cooldown %d   setter missing %d, refused %d",
        secrets.usable, secrets.range, secrets.cooldown, secrets.setterMissing, secrets.setterFailed))
    Print(string.format("book rings: %d on, %d entries seen (%s)   last error: %s",
        bookInfo.rings, bookInfo.entries, bookInfo.variant, bookInfo.err or "none"))
    local BT = NS.BookTab
    if BT and type(BT.StatusLine) == "function" then
        local ok, line = pcall(BT.StatusLine)
        Print(ok and tostring(line) or ("missing tab: status failed: " .. tostring(line)))
    else
        Print("missing tab: BookTab.lua not loaded")
    end
    local FO = NS.Flyouts
    if FO and type(FO.StatusLine) == "function" then
        local ok, line = pcall(FO.StatusLine)
        Print(ok and tostring(line) or ("flyouts: status failed: " .. tostring(line)))
        if type(FO.RightClickLine) == "function" then
            local okR, lineR = pcall(FO.RightClickLine)
            Print(okR and tostring(lineR) or ("right-click: status failed: " .. tostring(lineR)))
        end
    else
        Print("flyouts: Flyouts.lua not loaded")
    end
    local sample = list[1] and list[1].icon
    local cd = list[1] and list[1].cd
    Print("issecretvalue: " .. YesNo(_G.issecretvalue ~= nil)
        .. "   SetVertexColorFromBoolean: " .. YesNo(sample and type(sample.SetVertexColorFromBoolean) == "function")
        .. "   SetAlphaFromBoolean: " .. YesNo(sample and type(sample.SetAlphaFromBoolean) == "function")
        .. "   CreateColor: " .. YesNo(type(_G.CreateColor) == "function"))
    local cvar
    local C = _G.C_CVar
    local get = (type(C) == "table" and type(C.GetCVar) == "function" and C.GetCVar)
        or (type(_G.GetCVar) == "function" and _G.GetCVar) or nil
    if get then
        local ok, v = pcall(get, "countdownForCooldowns")
        cvar = ok and Str(v) or nil
    end
    local _, fmtWhy = TimeText.Formatter()
    Print("cooldown numbers: C_ActionBar.GetActionCooldown "
        .. YesNo(type(_G.C_ActionBar) == "table" and type(_G.C_ActionBar.GetActionCooldown) == "function")
        .. ", GetActionCooldown " .. YesNo(type(_G.GetActionCooldown) == "function")
        .. ", SetHideCountdownNumbers " .. YesNo(cd and type(cd.SetHideCountdownNumbers) == "function")
        .. ", GetCountdownFontString " .. YesNo(cd and type(cd.GetCountdownFontString) == "function")
        .. ", SetCountdownFont " .. YesNo(cd and type(cd.SetCountdownFont) == "function")
        .. ", SetCountdownFormatter " .. YesNo(cd and type(cd.SetCountdownFormatter) == "function")
        .. ", countdownForCooldowns " .. (cvar or "?"))
    Print("client countdown format: " .. tostring(fmtWhy))
    Print("in combat: " .. YesNo(InCombat()) .. (pendingFrames and "   (overlays wait for combat to end)" or ""))
    Print("last error: " .. (lastError or "none"))
end

local function OnSlash(msg)
    local ok, err = pcall(function()
        msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
        if not db then
            Print("not loaded yet.")
            return
        end
        local cmd, arg = msg:match("^(%S+)%s*(.*)$")
        cmd = (cmd or ""):lower()
        arg = (arg or ""):lower()
        if cmd == "on" or cmd == "off" then
            SetEnabled(cmd == "on")
        elseif cmd == "status" then
            PrintStatus()
        elseif FEATURE_BY_CMD[cmd] then
            local f = FEATURE_BY_CMD[cmd]
            if f.key == "flyouts" and cmd == "flyouts" and arg == "" then
                -- "/gbars flyouts" opens the editor ("/gbars flyout" still toggles the feature).
                if type(NS.Bars.OpenFlyoutEditor) == "function" then
                    NS.Bars.OpenFlyoutEditor()
                else
                    Print("flyouts: FlyoutEditor.lua not loaded")
                end
            elseif f.key == "flyouts" and arg:match("^dir") then
                if NS.Flyouts and type(NS.Flyouts.SlashDir) == "function" then
                    NS.Flyouts.SlashDir(arg)
                else
                    Print("flyouts: Flyouts.lua not loaded")
                end
            elseif f.key == "flyouts" and arg:match("^samekey") then
                if NS.Flyouts and type(NS.Flyouts.SlashSameKey) == "function" then
                    NS.Flyouts.SlashSameKey(arg)
                else
                    Print("flyouts: Flyouts.lua not loaded")
                end
            elseif arg == "on" or arg == "off" then
                SetFeature(f, arg == "on")
            elseif arg == "" then
                SetFeature(f, not db[f.key])
            else
                Print("/gbars " .. f.cmd .. " on|off")
            end
        else
            PrintHelp()
        end
    end)
    if not ok then
        Fail("slash", err)
        Print("error: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Shared with BookTab.lua and Flyouts.lua (loaded after this file, same addon namespace). Plain references to
-- this file's helpers, so the spellbook tab reads spells and ranks exactly like the rings do.
-- ---------------------------------------------------------------------------

NS.Bars = {
    A = A, BF = BF, Print = Print, Fail = Fail, On = On, InCombat = InCombat,
    Secret = Secret, Num = Num, Str = Str, FieldOf = FieldOf, CallOf = CallOf,
    SpellName = SpellName, SpellRank = SpellRank, SlotSpellID = SlotSpellID,
    DB = function() return db end,
}

-- ---------------------------------------------------------------------------
-- Public API: GaarBarsForeverAPI
--
-- For GaarForever, the family hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in GaarBarsForeverDB and change only through the
-- same functions /gbars uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "on · 120 buttons"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func },
--                        { text, radio = true, checked, func }, { text, submenu } and
--                        { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    if not Enabled() then return "off" end
    local n = 0
    for _, f in ipairs(FEATURES) do if db[f.key] then n = n + 1 end end
    return "on" .. DOT .. #list .. " buttons" .. DOT .. n .. "/" .. #FEATURES .. " features"
end

local function MenuEntries()
    if not db then return {} end
    local entries = {
        { text = "Enabled", checkbox = true,
          checked = function() return Enabled() end,
          func = function() SetEnabled(not Enabled()) end },
        { divider = true },
    }
    for _, f in ipairs(FEATURES) do
        entries[#entries + 1] = { text = f.label, checkbox = true,
            checked = function() return db[f.key] and true or false end,
            func = function() SetFeature(f, not db[f.key]) end }
    end
    return entries
end


_G.GaarBarsForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries(), A.title) end,
    SetMinimapHidden = function() end,
}
_G.BetterBarsForeverAPI = _G.GaarBarsForeverAPI -- the name before the folder rename

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    BF.Migrate("GaarBarsForeverDB", "BetterBarsForeverDB") -- the old folder's settings, once (see Lib.lua)
    if type(GaarBarsForeverDB) ~= "table" then GaarBarsForeverDB = {} end
    db = GaarBarsForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    if type(db.enabled) ~= "boolean" then db.enabled = true end
    for _, f in ipairs(FEATURES) do
        if type(db[f.key]) ~= "boolean" then db[f.key] = f.default end
    end
    local dirs = { up = true, down = true, left = true, right = true }
    if not dirs[db.flyoutDir] then db.flyoutDir = "up" end
    if type(db.flyoutSameKeyCast) ~= "boolean" then db.flyoutSameKeyCast = true end
end

local function Setup()
    Scan()
    if not ticker then
        ticker = CreateFrame("Frame")
        ticker:SetScript("OnUpdate", function(_, elapsed)
            elapsedSince = elapsedSince + (Num(elapsed) or 0)
            if elapsedSince < TICK then return end
            elapsedSince = 0
            SafeTick()
        end)
    end
    SafeTick()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Not every client knows every event; registering an unknown one raises an error.
for _, e in ipairs({ "UPDATE_BINDINGS", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED",
    "UPDATE_BONUS_ACTIONBAR", "UPDATE_SHAPESHIFT_FORMS", "PET_BAR_UPDATE",
    "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1)
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if SPELLBOOK_ADDONS[arg1] and db then HookSpellbook(); SafeRefreshRank() end
            if arg1 == ADDON_NAME then
                BindSavedVariables()
                HookSpellbook()
                if type(_G.IsLoggedIn) == "function" and _G.IsLoggedIn() then Setup() end
            end
        elseif not db then
            return
        elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
            Setup()
            HookSpellbook()
        elseif event == "PLAYER_REGEN_ENABLED" then
            if pendingFrames then
                pendingFrames = false
                for _, st in ipairs(list) do EnsureOverlay(st) end
            end
        else
            -- Bindings, pages, forms or the pet bar changed: repaint now rather than at the next
            -- tick (Blizzard's own handler may run after this one; the ticker catches that).
            SafeTick()
            SafeRefreshRank()
        end
    end)
    if not ok then Fail(event, err) end
end)

SLASH_GAARBARSFOREVER1 = "/gbars"
SLASH_GAARBARSFOREVER2 = "/gaarbarsforever"
SLASH_GAARBARSFOREVER3 = "/bbars" -- the command before the Gaar rename
SLASH_GAARBARSFOREVER4 = "/betterbarsforever"
SlashCmdList.GAARBARSFOREVER = OnSlash
