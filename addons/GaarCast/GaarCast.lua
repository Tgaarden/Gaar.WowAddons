--[[
  Gaar Cast — movable cast bars, ported from Deepward Cast (WotLK 3.3.5a) to WoW Classic Era.

  Bars for player / target / pet (and focus if this client has a focus unit). Each bar takes
  over from Blizzard's own cast bar for that unit: Blizzard's is hidden, and ours is anchored
  to it, so it lands wherever that bar has been placed (Edit Mode, or the default layout) and
  follows it when it moves. Shift-drag a bar to place it yourself; the corner grip resizes it;
  "Reset position" hands it back to the Blizzard anchor.

  /gaarcast (or /gcast) opens the options.

  Classic Era port notes vs the WotLK original:
   * SetBackdrop needs the "BackdropTemplate" mixin - plain frames no longer have it.
   * UnitCastingInfo/UnitChannelInfo lost the old nameSubtext return, so the texture and the
     timestamps moved one slot forward; CastInfo() detects the shape instead of assuming it.
   * Texture:SetTexture(r,g,b,a) is gone - solid colours go through SetColorTexture.
   * SetMinResize/SetMaxResize gave way to SetResizeBounds.
   * EasyMenu/UIDropDownMenu is not relied on at all - options are a plain checkbox panel
     built from templates this client is known to still have.
]]

local _G = _G
local ADDON = "Gaar Cast"

local function DB()
    if type(GaarCastDB) ~= "table" then GaarCastDB = {} end
    local d = GaarCastDB
    if d.show == nil then d.show = { player = true, target = true, focus = true, pet = false } end
    if d.locked == nil then d.locked = false end
    if d.showLatency == nil then d.showLatency = true end
    if d.spark == nil then d.spark = true end
    if d.showTotal == nil then d.showTotal = true end   -- "remain / total" instead of just remain
    if d.showTarget == nil then d.showTarget = true end -- name of who the cast is on
    if d.shield == nil then d.shield = true end         -- shield overlay on uninterruptible casts
    if d.fade == nil then d.fade = true end             -- fade-out when a cast finishes
    if d.fontSize == nil then d.fontSize = 11 end
    if d.texture == nil then d.texture = "Interface\\TargetingFrame\\UI-StatusBar" end
    if d.pos == nil then d.pos = {} end    -- [unit] = {point, x, y} — set only once you move a bar
    if d.size == nil then d.size = {} end  -- [unit] = {w, h} — set only once you resize a bar
    return d
end

local TEXTURES = {
    { label = "Blizzard", tex = "Interface\\TargetingFrame\\UI-StatusBar" },
    { label = "Smooth",   tex = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
    { label = "Flat",     tex = "Interface\\Buttons\\WHITE8x8" },
}

-- Blizzard's own cast bar per unit: hidden, and used as our default anchor + size.
local BLIZZ_CAST = {
    player = { "PlayerCastingBarFrame", "CastingBarFrame" },
    target = { "TargetFrameSpellBar" },
    focus  = { "FocusFrameSpellBar" },
    pet    = { "PetCastingBarFrame" },
}
local function BlizzBar(unit)
    for _, name in ipairs(BLIZZ_CAST[unit] or {}) do
        local f = _G[name]
        if f then return f end
    end
end

-- Fallback anchor + size, used only when this client has no Blizzard bar for that unit.
local FALLBACK = {
    player = { "CENTER", 0, -170, 200, 16 },
    target = { "CENTER", 0, -200, 180, 14 },
    focus  = { "CENTER", 260, -140, 170, 14 },
    pet    = { "CENTER", -260, -140, 150, 12 },
}

-- Focus only exists on TBC and later; detect it instead of assuming.
local HAS_FOCUS = (function()
    local probe = CreateFrame("Frame")
    local ok = pcall(probe.RegisterEvent, probe, "PLAYER_FOCUS_CHANGED")
    if ok then probe:UnregisterAllEvents() end
    return ok and _G.FocusFrame ~= nil
end)()

local UNITS = { "player", "target", "pet" }
if HAS_FOCUS then table.insert(UNITS, 3, "focus") end
local bars = {}

-- Returns: name, icon, startMs, endMs, notInterruptible, isChannel.
-- Classic Era dropped the old nameSubtext return, so texture/start/end sit one slot earlier
-- than they did on 3.3.5a. Detect which shape came back rather than hardcoding either.
-- Cast timings can come back secret on retail, and this file does arithmetic on them every
-- frame to place the spark and the latency zone. A secret one cannot be compared or divided,
-- so it is treated as no cast at all: the bar stays hidden rather than erroring twelve times a
-- second over a unit whose numbers the client will not show.
local issecretvalue = _G.issecretvalue
local function Secret(a, b)
    if not issecretvalue then return false end
    if issecretvalue(a) then return true end
    return b ~= nil and issecretvalue(b) or false
end

local function ReadCast(unit, channel)
    local r
    if channel then r = { UnitChannelInfo(unit) } else r = { UnitCastingInfo(unit) } end
    local name = r[1]
    if not name then return nil end
    if type(r[4]) == "number" and type(r[5]) == "number" then
        -- modern: name, text, texture, startMs, endMs, isTradeSkill, [castID,] notInterruptible
        if Secret(r[4], r[5]) then return nil end
        return name, r[3], r[4], r[5], (channel and r[7] or r[8])
    end
    -- pre-Cata: name, nameSubtext, text, texture, startMs, endMs, isTradeSkill, [castID,] notInterruptible
    if Secret(r[5], r[6]) then return nil end
    return name, r[4], r[5], r[6], (channel and r[8] or r[9])
end

local function CastInfo(unit)
    local name, icon, startMs, endMs, notInt = ReadCast(unit, false)
    if name then return name, icon, startMs, endMs, notInt, false end
    name, icon, startMs, endMs, notInt = ReadCast(unit, true)
    if name then return name, icon, startMs, endMs, notInt, true end
    return nil
end

-- ---------------------------------------------------------------------------
-- Cast bar factory
-- ---------------------------------------------------------------------------
local function SetSolidTexture(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
end

local function SetSizeBounds(f, minW, minH, maxW, maxH)
    if f.SetResizeBounds then f:SetResizeBounds(minW, minH, maxW, maxH)
    elseif f.SetMinResize then f:SetMinResize(minW, minH); f:SetMaxResize(maxW, maxH) end
end

-- Steel for a cast nothing can interrupt, the suite's usual grey otherwise. Colour carries
-- what the shield art used to, without adding a second frame around the icon.
local function SetIconBorder(f, uninterruptible)
    if not f.iconBorder then return end
    if uninterruptible then f.iconBorder:SetBackdropBorderColor(0.85, 0.87, 0.95, 1)
    else f.iconBorder:SetBackdropBorderColor(0.35, 0.37, 0.42, 1) end
end

local function ApplyCastSize(f)
    local h = f:GetHeight()
    local isz = math.max(6, h - 4)
    f.icon:SetSize(isz, isz)
    if f.spark then f.spark:SetHeight(h * 2) end
end

local function ApplyFonts(f)
    local s = DB().fontSize
    if f.name then f.name:SetFont(STANDARD_TEXT_FONT, s, "OUTLINE") end
    if f.time then f.time:SetFont(STANDARD_TEXT_FONT, s, "OUTLINE") end
    if f.target then f.target:SetFont(STANDARD_TEXT_FONT, math.max(8, s - 1), "OUTLINE") end
end

-- Place + size the bar: a position you dragged wins, otherwise sit exactly on Blizzard's bar
-- so the bar honours wherever that one has been placed.
local function ApplyAnchor(f)
    local unit = f.unit
    local pos, size = DB().pos[unit], DB().size[unit]
    local blizz = BlizzBar(unit)
    local fb = FALLBACK[unit]

    -- Blizzard's own geometry is borrowed, but only when it is plausibly a cast bar. The
    -- frame can report the size of a wide container, or a size it has not been laid out to
    -- yet, and copying that gave a bar stretched across most of the screen.
    local w, h = nil, nil
    if blizz then w, h = blizz:GetWidth(), blizz:GetHeight() end
    local sane = w and h and w >= 80 and w <= 400 and h >= 6 and h <= 40

    if size then
        f:SetSize(size.w, size.h)
    elseif sane then
        f:SetSize(w, h)
    else
        f:SetSize(fb[4], fb[5])
    end

    f:ClearAllPoints()
    if pos then
        f:SetPoint(pos.point or "CENTER", UIParent, pos.point or "CENTER", pos.x or 0, pos.y or 0)
    elseif blizz then
        f:SetPoint("CENTER", blizz, "CENTER", 0, 0)
    else
        f:SetPoint(fb[1], UIParent, fb[1], fb[2], fb[3])
    end
    ApplyCastSize(f)
end

local function MakeBar(unit)
    local f = CreateFrame("Frame", "GaarCast_" .. unit, UIParent, "BackdropTemplate")
    f.unit = unit
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if IsShiftKeyDown() and not DB().locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, _, x, y = self:GetPoint()
        DB().pos[unit] = { point = p, x = x, y = y }
    end)
    -- 1px, like the icon and the rest of the suite. The tooltip border this used to wear is
    -- 10px of ornament and made a small bar look like a picture frame.
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
                    insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    f:SetBackdropColor(0, 0, 0, 0.6); f:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("RIGHT", f, "LEFT", -2, 0)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- The icon had no edge of its own, so the only thing framing it was Blizzard's shield art
    -- on uninterruptible casts - an ornate gold plate half again the icon's size, which is not
    -- what the rest of this suite looks like. A 1px edge instead, recoloured to carry the same
    -- meaning.
    f.iconBorder = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.iconBorder:SetPoint("TOPLEFT", f.icon, "TOPLEFT", -1, 1)
    f.iconBorder:SetPoint("BOTTOMRIGHT", f.icon, "BOTTOMRIGHT", 1, -1)
    f.iconBorder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })

    f.bar = CreateFrame("StatusBar", nil, f)
    f.bar:SetPoint("TOPLEFT", 2, -2); f.bar:SetPoint("BOTTOMRIGHT", -2, 2)
    f.bar:SetStatusBarTexture(DB().texture)
    f.bar:SetMinMaxValues(0, 1); f.bar:SetValue(0)

    -- latency safe-zone (overlaid at the right end)
    f.lag = f.bar:CreateTexture(nil, "OVERLAY")
    SetSolidTexture(f.lag, 1, 0.1, 0.1, 0.35)
    f.lag:SetPoint("TOPRIGHT"); f.lag:SetPoint("BOTTOMRIGHT")
    f.lag:SetWidth(0); f.lag:Hide()

    f.spark = f.bar:CreateTexture(nil, "OVERLAY")
    f.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    f.spark:SetBlendMode("ADD")
    f.spark:SetWidth(18)
    f.spark:Hide()


    f.name = f.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.name:SetPoint("LEFT", 4, 0); f.name:SetJustifyH("LEFT")
    f.time = f.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.time:SetPoint("RIGHT", -4, 0); f.time:SetJustifyH("RIGHT")
    -- Under the bar rather than inside it, the same way a nameplate puts the unit's target
    -- under its health bar. Sharing the bar with the spell name and the timer left three
    -- things competing for one row, and a long target name ran into both.
    f.target = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.target:SetPoint("TOP", f, "BOTTOM", 0, -2); f.target:SetJustifyH("CENTER")
    f.target:SetTextColor(1, 0.9, 0.6)
    ApplyFonts(f)

    f:SetResizable(true)
    SetSizeBounds(f, 80, 12, 500, 60)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(12, 12); grip:SetPoint("BOTTOMRIGHT", 0, 0)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() if not DB().locked then f:StartSizing("BOTTOMRIGHT") end end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing(); ApplyCastSize(f)
        DB().size[unit] = { w = f:GetWidth(), h = f:GetHeight() }
    end)
    if DB().locked then grip:Hide() end
    f.grip = grip
    f:SetScript("OnSizeChanged", function(self) ApplyCastSize(self) end)

    ApplyAnchor(f)
    f:Hide()
    return f
end

-- No API for a cast's target on this client either: best effort is the unit's own target.
local function CastTargetName(unit)
    local tu = (unit == "player") and "target" or (unit .. "target")
    if UnitExists(tu) then return UnitName(tu) end
end

local function StartCast(f)
    local name, icon, startMs, endMs, notInt, channel = CastInfo(f.unit)
    if not name then f:Hide(); return end
    f.startMs, f.endMs, f.channel, f._test = startMs, endMs, channel, nil
    f:SetAlpha(1); f.fading = nil
    f.bar:SetStatusBarTexture(DB().texture)
    f.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.name:SetText(name)
    if notInt then f.bar:SetStatusBarColor(0.6, 0.6, 0.6)
    elseif channel then f.bar:SetStatusBarColor(0.2, 0.75, 0.3)
    else f.bar:SetStatusBarColor(1.0, 0.75, 0.1) end
    SetIconBorder(f, DB().shield and notInt)
    local tn = DB().showTarget and CastTargetName(f.unit)
    f.target:SetText(tn and ("-> " .. tn) or "")
    -- Latency safe-zone: the last <lag> ms of the cast. The fraction is worked out here but the
    -- width is applied in OnUpdate — the bar has no real width until it is shown.
    f.lag:Hide(); f.lagFrac = nil
    if DB().showLatency and f.unit == "player" and not channel then
        local _, _, _, lagMs = GetNetStats()
        local dur = endMs - startMs
        if lagMs and lagMs > 0 and dur > 0 then f.lagFrac = math.min(lagMs / dur, 1) end
    end
    f:Show()
end

local function StopCast(f, failed)
    if failed then
        f.bar:SetStatusBarColor(0.8, 0.1, 0.1)
        f.fadeAt = GetTime() + 0.5   -- brief red flash then hide
    elseif DB().fade then
        f.bar:SetValue(f.channel and 0 or 1); f.spark:Hide()
        f.fading = true; f.fadeStart = GetTime()
    else
        f:Hide()
    end
    f.startMs, f.endMs = nil, nil
end

local function OnUpdate(f)
    if not f.startMs then
        if f.fading then
            local a = 1 - (GetTime() - f.fadeStart) / 0.3
            if a <= 0 then f.fading = nil; f:SetAlpha(1); f:Hide() else f:SetAlpha(a) end
            return
        end
        if f.fadeAt and GetTime() > f.fadeAt then f.fadeAt = nil; f:Hide() end
        return
    end
    local now = GetTime() * 1000
    local dur = f.endMs - f.startMs
    if dur <= 0 then return end
    local elapsed = now - f.startMs
    local frac = elapsed / dur
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    if f.channel then frac = 1 - frac end   -- channels drain
    f.bar:SetValue(frac)
    if f.lagFrac then f.lag:SetWidth(f.bar:GetWidth() * f.lagFrac); f.lag:Show() end
    if DB().spark then
        f.spark:ClearAllPoints()
        f.spark:SetPoint("CENTER", f.bar, "LEFT", f.bar:GetWidth() * frac, 0)
        f.spark:Show()
    else f.spark:Hide() end
    local remain = (f.endMs - now) / 1000
    if remain < 0 then remain = 0 end
    local total = (f.endMs - f.startMs) / 1000
    if DB().showTotal then f.time:SetText(string.format("%.1f / %.1f", remain, total))
    else f.time:SetText(string.format("%.1f", remain)) end
    if now >= f.endMs then
        if f._test then f.startMs = nil            -- test mode loops but stays shown, so dragging never breaks
        else f:Hide(); f.startMs = nil end
    end
end

for _, u in ipairs(UNITS) do bars[u] = MakeBar(u) end

-- Take over from Blizzard's bars. Hooked OnShow so toggling ours off hands the unit back.
for _, unit in ipairs(UNITS) do
    local bf = BlizzBar(unit)
    if bf and not bf._gaarHooked then
        bf._gaarHooked = true
        local u = unit
        bf:HookScript("OnShow", function(self) if DB().show[u] then self:Hide() end end)
        if DB().show[unit] and bf:IsShown() then bf:Hide() end
    end
end

-- ---------------------------------------------------------------------------
-- Test mode
-- ---------------------------------------------------------------------------
local testing = false
local TEST_LABEL = { player = "Player", target = "Target", focus = "Focus", pet = "Pet" }
local function StartTestCast(f)
    f.startMs = GetTime() * 1000; f.endMs = f.startMs + 10000; f.channel = false; f.lagFrac = nil; f._test = true
    f:SetAlpha(1); f.fading = nil
    f.bar:SetStatusBarTexture(DB().texture)
    f.icon:SetTexture("Interface\\Icons\\Spell_Fire_FlameBolt")
    f.name:SetText("Test: " .. (TEST_LABEL[f.unit] or f.unit)); f.bar:SetStatusBarColor(1, 0.75, 0.1)
    SetIconBorder(f, false)
    f.target:SetText(DB().showTarget and "-> Target" or "")
    f:Show()
end
-- SetTesting lives further down, next to the options that switch it on and off.

-- Guarding each value before using it was not enough. The failure lands inside SetPoint with
-- "arithmetic on a secret number value", which means a secret got as far as a widget call
-- without issecretvalue having flagged it on the way in - secrecy travels through arithmetic
-- further than the predicate reports. Since what is secret cannot be predicted reliably here,
-- the refusal is treated as the signal, exactly as it is for nameplate auras: catch it once
-- for that unit, stop drawing that bar, and say so. Ninety-one errors becomes one.
local castBlocked = {}

local function SafeUpdate(u, f)
    if castBlocked[u] then return end
    local ok, err = pcall(OnUpdate, f)
    if ok then return end
    castBlocked[u] = true
    f.startMs = nil
    f:Hide()
    print(string.format("|cff5599ffGaar Cast:|r this client will not let an addon time the %s cast bar - disabled. (%s)",
        u, tostring(err)))
end

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function()
    for _, u in ipairs(UNITS) do
        local f = bars[u]
        if testing then
            if not f.startMs then StartTestCast(f) end
            SafeUpdate(u, f)
        elseif f:IsShown() or f.fadeAt then
            SafeUpdate(u, f)
        end
    end
end)

local function Refresh(u)
    local f = bars[u]
    if not f then return end
    if not DB().show[u] then f:Hide(); return end
    if CastInfo(u) then StartCast(f) else f:Hide() end
end

local ev = CreateFrame("Frame")
local EVENTS = {
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "PLAYER_TARGET_CHANGED", "UNIT_PET", "PLAYER_ENTERING_WORLD",
}
for _, e in ipairs(EVENTS) do pcall(ev.RegisterEvent, ev, e) end
if HAS_FOCUS then pcall(ev.RegisterEvent, ev, "PLAYER_FOCUS_CHANGED") end
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_ENTERING_WORLD" then
        for _, u in ipairs(UNITS) do ApplyAnchor(bars[u]) end
        return
    end
    if event == "PLAYER_TARGET_CHANGED" then Refresh("target"); return end
    if event == "PLAYER_FOCUS_CHANGED" then Refresh("focus"); return end
    if event == "UNIT_PET" then Refresh("pet"); return end
    local f = bars[arg1]
    if not f or not DB().show[arg1] then return end
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        StartCast(f)
    elseif event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
        if f:IsShown() then StartCast(f) end   -- re-read new start/end (pushback / haste)
    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        StopCast(f, true)
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        StopCast(f, false)
    end
end)

-- ---------------------------------------------------------------------------
-- Options
--
-- The controls are built into whatever frame they are handed, so the same code
-- serves both the "Gaar" entry in Blizzard's AddOns options and the standalone
-- window used when GaarOptions isn't installed. No dropdown/EasyMenu API is used.
-- ---------------------------------------------------------------------------
local uid = 0
local function MakeCheck(parent, label, y, get, set)
    uid = uid + 1
    local name = "GaarCastCheck" .. uid
    local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    c:SetChecked(get() and true or false)
    local fs = _G[name .. "Text"]
    fs:SetText(label); fs:SetFontObject(GameFontHighlight)
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    c.gaarRefresh = function() c:SetChecked(get() and true or false) end
    return c
end

local function SetTesting(on)
    testing = on
    if not testing then
        for _, u in ipairs(UNITS) do
            local f = bars[u]
            f.startMs = nil; f.fadeAt = nil; f._test = nil; f:Hide()
        end
    end
end
_G.GaarCast_SetTesting = SetTesting
_G.GaarCast_IsTesting = function() return testing end

local function ResetPositions()
    GaarCastDB.pos, GaarCastDB.size = {}, {}
    for _, u in ipairs(UNITS) do ApplyAnchor(bars[u]) end
    print("|cff5599ff" .. ADDON .. ":|r bars back on Blizzard's cast bar positions.")
end
_G.GaarCast_ResetPositions = ResetPositions

-- Fills `container` with every Gaar Cast control. Returns the height it used.
function GaarCast_BuildOptions(container)
    local refreshers = {}
    local y = -8

    local function check(label, get, set)
        local c = MakeCheck(container, label, y, get, set)
        refreshers[#refreshers + 1] = c.gaarRefresh
        y = y - 26
    end

    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("Cast bars")
    y = y - 24

    for _, u in ipairs(UNITS) do
        local unit = u
        check("Show " .. unit .. " cast bar",
            function() return DB().show[unit] end,
            function(v)
                DB().show[unit] = v
                if not v then
                    bars[unit]:Hide()
                else
                    local bf = BlizzBar(unit); if bf and bf:IsShown() then bf:Hide() end
                end
            end)
    end

    y = y - 10
    local head2 = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head2:SetPoint("TOPLEFT", 16, y); head2:SetText("Bar contents")
    y = y - 24

    local opts = {
        { "Latency safe-zone", "showLatency" },
        { "Spark at cast edge", "spark" },
        { "Show total cast time", "showTotal" },
        { "Show cast target name", "showTarget" },
        { "Mark uninterruptible casts", "shield" },
        { "Fade out on finish", "fade" },
    }
    for _, o in ipairs(opts) do
        local key = o[2]
        check(o[1], function() return DB()[key] end, function(v) DB()[key] = v end)
    end

    check("Lock position and size",
        function() return DB().locked end,
        function(v)
            DB().locked = v
            for _, u in ipairs(UNITS) do
                local g = bars[u].grip
                if g then if v then g:Hide() else g:Show() end end
            end
        end)

    y = y - 12
    local texLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    texLabel:SetPoint("TOPLEFT", 18, y); texLabel:SetText("Bar texture:")
    local x = 120
    for _, tx in ipairs(TEXTURES) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(64, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(tx.label)
        b:SetScript("OnClick", function()
            DB().texture = tx.tex
            for _, u in ipairs(UNITS) do bars[u].bar:SetStatusBarTexture(tx.tex) end
        end)
        x = x + 66
    end
    y = y - 30

    local fontLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", 18, y); fontLabel:SetText("Font size:")
    x = 120
    for _, s in ipairs({ 9, 11, 13 }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(44, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(tostring(s))
        b:SetScript("OnClick", function()
            DB().fontSize = s
            for _, u in ipairs(UNITS) do ApplyFonts(bars[u]) end
        end)
        x = x + 46
    end
    y = y - 36

    -- Test mode: a real toggle, so the bars can be positioned without waiting for a cast.
    local testBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    testBtn:SetSize(170, 24); testBtn:SetPoint("TOPLEFT", 16, y)
    local function testLabel() return testing and "Test bars: ON (click to stop)" or "Test bars: off" end
    testBtn:SetText(testLabel())
    testBtn:SetScript("OnClick", function(self)
        SetTesting(not testing)
        self:SetText(testLabel())
    end)
    refreshers[#refreshers + 1] = function() testBtn:SetText(testLabel()) end

    local reset = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    reset:SetSize(170, 24); reset:SetPoint("TOPLEFT", 196, y)
    reset:SetText("Reset to Blizzard spot")
    reset:SetScript("OnClick", ResetPositions)
    y = y - 32

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(340); hint:SetJustifyH("LEFT")
    hint:SetText("Shift-drag a bar to move it, drag its corner grip to resize. Untouched bars sit on Blizzard's own cast bar position. Test bars stay up until you switch them off.")
    y = y - 46

    container.gaarRefresh = function() for _, fn in ipairs(refreshers) do fn() end end
    return -y
end

-- Standalone window, used when the Blizzard options entry isn't available.
local panel
local function BuildPanel()
    if panel then return panel end
    panel = CreateFrame("Frame", "GaarCastPanel", UIParent, "BackdropTemplate")
    panel:SetSize(392, 560)
    panel:SetPoint("CENTER")
    panel:SetBackdrop({
        bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true); panel:EnableMouse(true)
    panel:SetScript("OnMouseDown", function(self) self:StartMoving() end)
    panel:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)
    table.insert(UISpecialFrames, "GaarCastPanel")

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16); title:SetText(ADDON)
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -8, -8)

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", 8, -40); body:SetPoint("BOTTOMRIGHT", -8, 12)
    local used = GaarCast_BuildOptions(body)
    panel:SetHeight(used + 60)
    panel:SetScript("OnShow", function() if body.gaarRefresh then body.gaarRefresh() end end)

    panel:Hide()
    return panel
end

local function OpenOptions()
    if _G.GaarOptions_Open and _G.GaarOptions_Open("cast") then return end
    local p = BuildPanel()
    if p:IsShown() then p:Hide() else p:Show() end
end
_G.GaarCast_Config = OpenOptions

SLASH_GAARCAST1 = "/gaarcast"
SLASH_GAARCAST2 = "/gcast"
SlashCmdList["GAARCAST"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "unlock" then DB().locked = false
        for _, u in ipairs(UNITS) do if bars[u].grip then bars[u].grip:Show() end end
        print("|cff5599ff" .. ADDON .. ":|r unlocked — shift-drag the bars.")
    elseif msg == "lock" then DB().locked = true
        for _, u in ipairs(UNITS) do if bars[u].grip then bars[u].grip:Hide() end end
        print("|cff5599ff" .. ADDON .. ":|r locked.")
    elseif msg == "test" then
        SetTesting(not testing)
        print("|cff5599ff" .. ADDON .. ":|r test bars " .. (testing and "on." or "off."))
    elseif msg == "reset" then ResetPositions()
    else OpenOptions() end
end
