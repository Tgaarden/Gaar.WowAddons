--[[
  BetterBarsForever - clearer action buttons on WoW Forever: a red icon out of range, a blue icon
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
      BetterFramesForever's aura format). Hidden for the global cooldown (1.5 s or less). Drawn by
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
    * A master switch (/bbars on|off) and one switch per feature (/bbars <feature> on|off), all in
      BetterBarsForeverDB (account-wide), and one menu entry each for the hub.
    * /bbars for help, /bbars status for the hooks found, the buttons handled and whether the
      client answered with secrets.
    * BetterBarsForeverAPI, a small global table for BetterGaarForever's hub menu (version,
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
  ActionButton_Update, ActionButton_UpdateHotkeys, PetActionButton_SetHotkeys). /bbars status
  lists which exist. ActionButton_OnUpdate is deliberately not hooked: it runs every frame for
  every button, and the ticker already covers what it would give.

  Secret values (12.x engine). IsUsableAction, IsActionInRange and the cooldown may come back
  secret. A secret is never compared or tested: it goes only into a widget setter that takes it
  as it is, guarded - Texture:SetVertexColorFromBoolean for the icon colour, SetAlphaFromBoolean
  for a red overlay of the addon's own when both answers are secret, the Cooldown's own countdown
  numbers for the time. Without those setters the icon is left to Blizzard. Two secret booleans
  cannot be combined, so with a secret usable flag the icon is white or grey (no blue). Every
  secret answer is counted for /bbars status.

  Taint: Blizzard code is only followed, never replaced. No Blizzard function, script or table is
  written (hooksecurefunc only), no protected function is called, and no button is shown, hidden,
  moved or given an attribute. Only visual properties of non-secure regions change: the icon's
  vertex colour, the hotkey's text and colour, the macro name's alpha, the cooldown's countdown
  numbers, and textures, font strings and one plain frame per button that the addon creates
  itself (out of combat). Every client API is checked with type(...) == "function" first, every
  handler runs in pcall (the last error is kept for /bbars status).
]]

local _G = _G
local ADDON_NAME = ...
ADDON_NAME = ADDON_NAME or "BetterBarsForever"
local PREFIX = "|cff33ff99BetterBarsForever|r: "
local DOT = " \194\183 "

local VERSION = "1.0"

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

-- The features, in menu and help order. key = the saved key; cmd = what /bbars accepts besides
-- the key itself (lower case).
local FEATURES = {
    { key = "rangeColor", cmd = "range", default = true, label = "Red icon out of range" },
    { key = "manaColor", cmd = "mana", default = true, label = "Blue icon without mana" },
    { key = "cooldownText", cmd = "cooldown", default = true, label = "Cooldown numbers" },
    { key = "hotkeyShort", cmd = "hotkey", default = true, label = "Short hotkeys" },
    { key = "macroText", cmd = "macro", default = true, label = "Macro names" },
    { key = "outOfRangeHotkey", cmd = "rangehotkey", default = false,
      label = "Out of range: red hotkey instead of red icon" },
}
local FEATURE_BY_CMD = {}
for _, f in ipairs(FEATURES) do
    FEATURE_BY_CMD[f.key:lower()] = f
    FEATURE_BY_CMD[f.cmd] = f
end

-- Every key BetterBarsForeverDB may hold.
local SAVED_KEYS = { enabled = true }
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

local db                  -- BetterBarsForeverDB, bound at ADDON_LOADED (never at file scope)
local list = {}           -- the button states, in scan order
local byButton = {}       -- Blizzard button -> its state
local counts = { action = 0, stance = 0, pet = 0 }
local hooksFound = {}     -- hook name -> number of buttons (methods) or true (globals)
local globalsHooked = {}
local lastError
local pendingFrames       -- an overlay frame was due in combat; create at PLAYER_REGEN_ENABLED
local ticker
local elapsedSince = 0

-- Secret answers seen, for /bbars status.
local secrets = { usable = 0, range = 0, cooldown = 0, setterMissing = 0, setterFailed = 0 }

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
-- tested. Those are checked before anything else touches the value.
local issecretvalue = _G.issecretvalue
local issecrettable = _G.issecrettable
local function Secret(v)
    if issecretvalue and issecretvalue(v) then return true end
    if type(v) == "table" and issecrettable and issecrettable(v) then return true end
    return false
end

local function Num(v)
    if Secret(v) or type(v) ~= "number" or v ~= v then return nil end
    return v
end

local function Str(v)
    if Secret(v) or type(v) ~= "string" or v == "" then return nil end
    return v
end

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
-- Time text: "56", "2m", "1h", "2d" (BetterFramesForever's aura format, BetterPlatesForever's
-- rule formatter for the client's own countdown when the time is secret)
-- ---------------------------------------------------------------------------

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

-- The formatter, or false; and a line for /bbars status.
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
            local name = "BetterBarsForeverCountdownFont" .. size
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
    fs:SetText(TimeText.Plain(left))
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
        Print(f.label .. ": " .. (on and "on" or "off") .. "." .. (Enabled() and "" or " (the addon is off: /bbars on)"))
    end
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function PrintHelp()
    Print("clearer action buttons: red out of range, blue without mana, cooldown numbers, short hotkeys.")
    Print("/bbars on | /bbars off - switch the addon on or off")
    for _, f in ipairs(FEATURES) do
        Print(string.format("/bbars %s on|off - %s (now %s, default %s)", f.cmd, f.label,
            db[f.key] and "on" or "off", f.default and "on" or "off"))
    end
    Print("/bbars status - the hooks found, the buttons handled and whether the client hid any values")
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
    local sample = list[1] and list[1].icon
    local cd = list[1] and list[1].cd
    Print("issecretvalue: " .. YesNo(issecretvalue ~= nil)
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
            if arg == "on" or arg == "off" then
                SetFeature(f, arg == "on")
            elseif arg == "" then
                SetFeature(f, not db[f.key])
            else
                Print("/bbars " .. f.cmd .. " on|off")
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
-- Public API: BetterBarsForeverAPI
--
-- For BetterGaarForever, the optional hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterBarsForeverDB and change only through the
-- same functions /bbars uses, so the addon behaves the same with or without the hub.
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

_G.BetterBarsForeverAPI = {
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
    if type(BetterBarsForeverDB) ~= "table" then BetterBarsForeverDB = {} end
    db = BetterBarsForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    if type(db.enabled) ~= "boolean" then db.enabled = true end
    for _, f in ipairs(FEATURES) do
        if type(db[f.key]) ~= "boolean" then db[f.key] = f.default end
    end
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
    "UPDATE_BONUS_ACTIONBAR", "UPDATE_SHAPESHIFT_FORMS", "PET_BAR_UPDATE" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1)
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then
                BindSavedVariables()
                if type(_G.IsLoggedIn) == "function" and _G.IsLoggedIn() then Setup() end
            end
        elseif not db then
            return
        elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
            Setup()
        elseif event == "PLAYER_REGEN_ENABLED" then
            if pendingFrames then
                pendingFrames = false
                for _, st in ipairs(list) do EnsureOverlay(st) end
            end
        else
            -- Bindings, pages, forms or the pet bar changed: repaint now rather than at the next
            -- tick (Blizzard's own handler may run after this one; the ticker catches that).
            SafeTick()
        end
    end)
    if not ok then Fail(event, err) end
end)

SLASH_BETTERBARSFOREVER1 = "/bbars"
SLASH_BETTERBARSFOREVER2 = "/betterbarsforever"
SlashCmdList.BETTERBARSFOREVER = OnSlash
