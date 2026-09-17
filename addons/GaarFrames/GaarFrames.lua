--[[
  Gaar Frames — X-Perl-style tweaks to the default unit frames, ported from DeepwardUI's
  FrameStyle (WotLK 3.3.5a) to WoW Classic Era.

    * Class-coloured health bars for player units; NPCs keep Blizzard's reaction colour.
    * Bigger outlined text with a percent on every health and power bar ("cur/max  NN%"),
      sized to the bar it sits in and falling back to the percent alone where that will not fit.
    * Low-health colouring (orange under 35%, red under 20%) overriding the class colour.
    * A black see-through backing panel hugging each frame's bars and name, plus a dark disc
      behind the portrait.
    * Blizzard's ornate border art hidden; combat/aggro flashes left alone.
    * Party frames given taller, readable bars and an always-on row of buff icons.

  /gaarframes for options (also under Gaar -> Frames).

  Classic Era port notes vs the WotLK original:
   * There is no focus unit on this client, so the focus frame entry is only used if one
     actually exists - detected rather than assumed.
   * PARTY_MEMBERS_CHANGED became GROUP_ROSTER_UPDATE; both are registered defensively.
   * Aura returns lost the old rank value, so the buff icon moved from the third return to the
     second. Reading it the old way would have shown the wrong texture, so buffs go through
     C_UnitAuras where available and the modern UnitBuff layout otherwise.
   * SetBackdrop needs the "BackdropTemplate" mixin, and there is no EasyMenu.
   * Dropped from the original: StyleBigPortrait and PortraitBorder, which the WotLK version
     defined but never called, and the frame scale/lock/reset menu entries, which belonged to
     FrameMover (not ported).
]]

local _G = _G

local function DB()
    if type(GaarFramesDB) ~= "table" then GaarFramesDB = {} end
    local d = GaarFramesDB
    if d.classColor == nil then d.classColor = true end
    if d.barText == nil then d.barText = true end
    if d.fontSize == nil then d.fontSize = 12 end
    if d.threshold == nil then d.threshold = true end
    if d.stripBorders == nil then d.stripBorders = true end
    if d.backdrop == nil then d.backdrop = true end
    if d.partyBars == nil then d.partyBars = true end
    if d.partyBuffs == nil then d.partyBuffs = true end
    return d
end

local HAS_FOCUS = (_G.FocusFrame ~= nil)

-- health bar, power bar, unit token, portrait
local FRAMES = {
    { h = "PlayerFrameHealthBar",       m = "PlayerFrameManaBar",       u = "player", p = "PlayerPortrait" },
    { h = "TargetFrameHealthBar",       m = "TargetFrameManaBar",       u = "target", p = "TargetFramePortrait" },
    { h = "PetFrameHealthBar",          m = "PetFrameManaBar",          u = "pet",    p = "PetPortrait" },
    { h = "PartyMemberFrame1HealthBar", m = "PartyMemberFrame1ManaBar", u = "party1", p = "PartyMemberFrame1Portrait" },
    { h = "PartyMemberFrame2HealthBar", m = "PartyMemberFrame2ManaBar", u = "party2", p = "PartyMemberFrame2Portrait" },
    { h = "PartyMemberFrame3HealthBar", m = "PartyMemberFrame3ManaBar", u = "party3", p = "PartyMemberFrame3Portrait" },
    { h = "PartyMemberFrame4HealthBar", m = "PartyMemberFrame4ManaBar", u = "party4", p = "PartyMemberFrame4Portrait" },
}
if HAS_FOCUS then
    table.insert(FRAMES, 3, { h = "FocusFrameHealthBar", m = "FocusFrameManaBar",
                              u = "focus", p = "FocusFramePortrait" })
end

-- Retail keeps these frames but stopped publishing them as globals: PlayerFrameHealthBar is
-- PlayerFrame.healthbar there, and the party frames moved under PartyFrame entirely. The names
-- below stay this file's own keys and Frame() resolves each to whichever the client has.
--
-- The Era globals are verified - the suite runs on them. The retail paths are the documented
-- replacements and are proven only by whether they resolve at runtime, which is why nothing
-- here asserts: a name that resolves to nothing leaves that frame unstyled, exactly as before.
local RETAIL_PATH = {
    PlayerFrameHealthBar = "PlayerFrame.healthbar", PlayerFrameManaBar = "PlayerFrame.manabar",
    TargetFrameHealthBar = "TargetFrame.healthbar", TargetFrameManaBar = "TargetFrame.manabar",
    FocusFrameHealthBar  = "FocusFrame.healthbar",  FocusFrameManaBar  = "FocusFrame.manabar",
    PetFrameHealthBar    = "PetFrame.healthbar",    PetFrameManaBar    = "PetFrame.manabar",
}
-- The party frames moved under PartyFrame, but the probe could only confirm the member frame
-- itself; what its bars are called under there is untested. Several spellings are offered and
-- the first that resolves wins, which is honest about not knowing rather than picking one.
for i = 1, 4 do
    local old, new = "PartyMemberFrame" .. i, "PartyFrame.MemberFrame" .. i
    RETAIL_PATH[old] = new
    RETAIL_PATH[old .. "HealthBar"] = { new .. ".HealthBar", new .. ".healthbar", new .. ".HealthBarContainer.HealthBar" }
    RETAIL_PATH[old .. "ManaBar"]   = { new .. ".ManaBar", new .. ".manabar", new .. ".PowerBar" }
    RETAIL_PATH[old .. "Name"]      = { new .. ".Name", new .. ".name" }
end

-- Only hits are remembered. A miss must stay a miss that is retried, because the party frames
-- do not exist until there is a party, and caching "absent" at load would keep them unstyled
-- for the rest of the session.
local resolvedFrame = {}

local function Frame(name)
    if not name or name == "" then return nil end
    local direct = _G[name]
    if direct then return direct end
    local hit = resolvedFrame[name]
    if hit then return hit end
    local paths = RETAIL_PATH[name]
    if not paths then return nil end
    if type(paths) == "string" then paths = { paths } end
    for _, path in ipairs(paths) do
        local node = _G
        for part in string.gmatch(path, "[^.]+") do
            if type(node) ~= "table" then node = nil; break end
            node = node[part]
            if node == nil then break end
        end
        if node then resolvedFrame[name] = node; return node end
    end
    return nil
end

local FRAME_OF = {
    player = "PlayerFrame", target = "TargetFrame", focus = "FocusFrame", pet = "PetFrame",
    party1 = "PartyMemberFrame1", party2 = "PartyMemberFrame2",
    party3 = "PartyMemberFrame3", party4 = "PartyMemberFrame4",
}
local NAME_OF = {
    player = "PlayerName", target = "TargetFrameTextureFrameName",
    focus = "FocusFrameTextureFrameName", pet = "PetName",
    party1 = "PartyMemberFrame1Name", party2 = "PartyMemberFrame2Name",
    party3 = "PartyMemberFrame3Name", party4 = "PartyMemberFrame4Name",
}

-- ---------------------------------------------------------------------------
-- Backing panel: black, semi-transparent, hugging the bars and the name. Built from absolute
-- screen bounds so it also fits the mirrored target frame.
-- ---------------------------------------------------------------------------
local function StyleBackdrop(f)
    local uf, pt, hb, mb = Frame(FRAME_OF[f.u]), Frame(f.p), Frame(f.h), Frame(f.m)
    if not (uf and pt and hb and mb) then return end
    if not (hb:GetLeft() and mb:GetLeft() and pt:GetLeft()) then return end   -- not laid out yet
    if not f._bd then
        local bd = CreateFrame("Frame", nil, uf, "BackdropTemplate")
        bd:SetFrameLevel(math.max(0, uf:GetFrameLevel() - 1))
        bd:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 } })
        bd:SetBackdropColor(0, 0, 0, 0.5)
        bd:SetBackdropBorderColor(0, 0, 0, 0.9)
        f._bd = bd
        -- Dark disc behind the round portrait: the circular portrait alpha mask is centred and
        -- symmetric, unlike the minimap background, which sat visibly off-centre.
        local c = uf:CreateTexture(nil, "BACKGROUND")
        c:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        c:SetVertexColor(0, 0, 0, 0.55)
        f._circle = c
    end
    local bd = f._bd
    if not DB().backdrop then
        bd:Hide()
        if f._circle then f._circle:Hide() end
        return
    end
    local l = math.min(hb:GetLeft(), mb:GetLeft())
    local r = math.max(hb:GetRight(), mb:GetRight())
    local t = hb:GetTop()
    local b = mb:GetBottom()
    local nameFS = Frame(NAME_OF[f.u])
    if nameFS and nameFS:IsShown() and nameFS:GetTop() then
        t = math.max(t, nameFS:GetTop())
        l = math.min(l, nameFS:GetLeft())
        r = math.max(r, nameFS:GetRight())
    end
    bd:ClearAllPoints()
    bd:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l - 4, t + 3)
    bd:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", r + 4, b - 4)
    bd:Show()
    local c = f._circle
    c:ClearAllPoints()
    c:SetPoint("CENTER", pt, "CENTER", 0, 0)
    c:SetSize(pt:GetWidth() * 1.12, pt:GetHeight() * 1.12)
    c:Show()
end

local BLIZZ_BORDERS = {
    "PlayerFrameTexture", "TargetFrameTextureFrameTexture", "FocusFrameTextureFrameTexture", "PetFrameTexture",
    "PartyMemberFrame1Texture", "PartyMemberFrame2Texture", "PartyMemberFrame3Texture", "PartyMemberFrame4Texture",
}
local function StripBlizzardBorders()
    if not DB().stripBorders then return end
    for _, n in ipairs(BLIZZ_BORDERS) do
        local t = _G[n]
        if t and t:IsShown() then t:Hide() end
    end
end

local function ResetPortraits()
    for _, f in ipairs(FRAMES) do
        local pt = Frame(f.p)
        if pt and pt.SetTexCoord then pt:SetTexCoord(0, 1, 0, 1) end
    end
end

local function ApplyHealthColor(bar, unit)
    if not bar or not bar.SetStatusBarColor then return end
    if not DB().classColor or not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end
    local hp, hpm = UnitHealth(unit), UnitHealthMax(unit)
    local pct = (hpm and hpm > 0) and (hp / hpm) or 1
    if DB().threshold and pct <= 0.20 then bar:SetStatusBarColor(0.95, 0.12, 0.12)
    elseif DB().threshold and pct <= 0.35 then bar:SetStatusBarColor(1.0, 0.55, 0.0)
    else
        local _, cls = UnitClass(unit)
        local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        if c then bar:SetStatusBarColor(c.r, c.g, c.b) end
    end
end

-- Buff name + icon for a unit's Nth buff. The old rank return is gone on this client, so the
-- icon is the second value, not the third.
local function BuffInfo(unit, i)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local a = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
        if not a then return nil end
        return a.name, a.icon
    end
    if UnitBuff then
        local name, icon = UnitBuff(unit, i)
        return name, icon
    end
end

local function StylePartyBuffs(idx)
    local pf = Frame("PartyMemberFrame" .. idx)
    local mb = Frame("PartyMemberFrame" .. idx .. "ManaBar")
    if not (pf and mb) then return end
    pf._gaarBuffs = pf._gaarBuffs or {}
    local on = DB().partyBuffs
    local unit = "party" .. idx
    for i = 1, 8 do
        local b = pf._gaarBuffs[i]
        local name, icon
        if on and UnitExists(unit) then name, icon = BuffInfo(unit, i) end
        if name and icon then
            if not b then
                b = pf:CreateTexture(nil, "OVERLAY")
                b:SetSize(15, 15)
                b:SetPoint("TOPLEFT", mb, "BOTTOMLEFT", (i - 1) * 17, -2)
                b:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                pf._gaarBuffs[i] = b
            end
            b:SetTexture(icon); b:Show()
        elseif b then
            b:Hide()
        end
    end
end

local PARTY_HB_W, PARTY_HB_H, PARTY_MB_H = 112, 16, 11
local function StylePartyBars(idx)
    if not DB().partyBars then return end
    local hb = Frame("PartyMemberFrame" .. idx .. "HealthBar")
    local mb = Frame("PartyMemberFrame" .. idx .. "ManaBar")
    local nm = Frame("PartyMemberFrame" .. idx .. "Name")
    if not hb or not mb then return end
    if nm then
        hb:ClearAllPoints()
        hb:SetPoint("TOPLEFT", nm, "BOTTOMLEFT", 0, -2)
    end
    hb:SetWidth(PARTY_HB_W); hb:SetHeight(PARTY_HB_H)
    mb:ClearAllPoints()
    mb:SetPoint("TOPLEFT", hb, "BOTTOMLEFT", 0, -2)
    mb:SetWidth(PARTY_HB_W); mb:SetHeight(PARTY_MB_H)
end

local function Short(n)
    n = n or 0
    if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
    return tostring(n)
end

-- One size cannot suit every bar. The pet and party bars are a fraction of the height of the
-- player's, and the power bar is thinner again than the health bar above it, so the configured
-- size is treated as a ceiling and each bar takes the largest that actually fits inside it.
-- That is why the pet's mana text ends up the smallest on screen.
local function FitSize(bar)
    local want = DB().fontSize
    local h = bar:GetHeight() or 0
    if h > 0 then
        local fit = math.floor(h) - 2   -- the OUTLINE costs a pixel on each side
        if fit < want then want = fit end
    end
    return math.max(7, want)
end

local function BarText(bar)
    if not bar then return nil end
    if not bar._gaarText then
        local fs = bar:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("CENTER", bar, "CENTER", 0, 0)
        fs:SetTextColor(1, 1, 1)
        bar._gaarText = fs
        if bar.TextString then bar.TextString:SetAlpha(0) end   -- don't double up with Blizzard's
    end
    -- Heights are not final when a frame is first built, so the size is checked on every pass
    -- rather than once. Re-applying only on a change keeps that off the 0.2s driver's back.
    local want = FitSize(bar)
    if bar._gaarSize ~= want then
        bar._gaarSize = want
        bar._gaarText:SetFont(STANDARD_TEXT_FONT, want, "OUTLINE")
    end
    return bar._gaarText
end

local function UpdateBarText(barName, unit, powerBar)
    local bar = Frame(barName)
    if not bar then return end
    local fs = BarText(bar)
    if not fs then return end
    if not DB().barText or not UnitExists(unit) then fs:SetText(""); return end
    if UnitIsDeadOrGhost(unit) then fs:SetText(""); return end   -- keep Blizzard's "Dead" readable
    local cur, max
    if powerBar then cur, max = UnitPower(unit), UnitPowerMax(unit)
    else cur, max = UnitHealth(unit), UnitHealthMax(unit) end
    if not max or max <= 0 then fs:SetText(""); return end
    local pct = math.floor(cur / max * 100 + 0.5)
    fs:SetText(string.format("%s/%s  %d%%", Short(cur), Short(max), pct))
    -- A short bar with long numbers spills over both ends and reads worse than no numbers at
    -- all. Where the full string does not fit, the percent alone does.
    local room = (bar:GetWidth() or 0) - 4
    if room > 0 and fs:GetStringWidth() > room then
        fs:SetText(string.format("%d%%", pct))
    end
end

-- Blizzard repaints the health bar its default green on every health change. Re-applying only
-- from UnitFrameHealthBar_Update and the 0.2s driver left the green on screen for up to a fifth
-- of a second - the flash. HealthBar_OnValueChanged fires on the change itself, so hooking that
-- puts our colour back in the same frame. The other two are hooked as well, since each repaints
-- through a different path (target swap, vehicle art, and so on).
if type(UnitFrameHealthBar_Update) == "function" then
    hooksecurefunc("UnitFrameHealthBar_Update", function(bar, unit)
        ApplyHealthColor(bar, unit)
    end)
end
if type(HealthBar_OnValueChanged) == "function" then
    hooksecurefunc("HealthBar_OnValueChanged", function(bar)
        if bar then ApplyHealthColor(bar, bar.unit) end
    end)
end
if type(UnitFrame_Update) == "function" then
    hooksecurefunc("UnitFrame_Update", function(frame)
        if frame and frame.healthbar then ApplyHealthColor(frame.healthbar, frame.unit) end
    end)
end

local driver = CreateFrame("Frame")
local acc = 0
driver:SetScript("OnUpdate", function(_, e)
    acc = acc + e
    if acc < 0.2 then return end
    acc = 0
    for _, f in ipairs(FRAMES) do
        UpdateBarText(f.h, f.u, false)
        UpdateBarText(f.m, f.u, true)
        ApplyHealthColor(Frame(f.h), f.u)
        StyleBackdrop(f)
    end
    for i = 1, 4 do StylePartyBars(i); StylePartyBuffs(i) end
    ResetPortraits()
    StripBlizzardBorders()
end)

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "GROUP_ROSTER_UPDATE", "PARTY_MEMBERS_CHANGED", "UNIT_PET" }) do
    pcall(ev.RegisterEvent, ev, e)
end
if HAS_FOCUS then pcall(ev.RegisterEvent, ev, "PLAYER_FOCUS_CHANGED") end
ev:SetScript("OnEvent", function()
    if type(UnitFrameHealthBar_Update) ~= "function" then return end
    for _, f in ipairs(FRAMES) do
        local bar = Frame(f.h)
        if bar and UnitExists(f.u) then UnitFrameHealthBar_Update(bar, f.u) end
    end
end)

local function SetFontSize(s)
    DB().fontSize = s
    for _, f in ipairs(FRAMES) do
        for _, bn in ipairs({ f.h, f.m }) do
            local bar = Frame(bn)
            -- clearing the cached size is enough: the next pass refits it against the bar
            if bar then bar._gaarSize = nil end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------
local uid = 0
local function MakeCheck(parent, label, y, get, set)
    uid = uid + 1
    local name = "GaarFramesCheck" .. uid
    local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24); c:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    c:SetChecked(get() and true or false)
    local fs = _G[name .. "Text"]
    fs:SetText(label); fs:SetFontObject(GameFontHighlight)
    c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    c.gaarRefresh = function() c:SetChecked(get() and true or false) end
    return c
end

function GaarFrames_BuildOptions(container)
    local refreshers = {}
    local y = -8

    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("Unit frames")
    y = y - 26

    local function check(lbl, get, set)
        local c = MakeCheck(container, lbl, y, get, set)
        refreshers[#refreshers + 1] = c.gaarRefresh
        y = y - 26
    end

    check("Class-coloured bars", function() return DB().classColor end, function(v) DB().classColor = v end)
    check("Bar text with percent", function() return DB().barText end, function(v) DB().barText = v end)
    check("Low-health colouring", function() return DB().threshold end, function(v) DB().threshold = v end)
    check("Black backing panel", function() return DB().backdrop end, function(v) DB().backdrop = v end)
    check("Hide Blizzard's border art", function() return DB().stripBorders end, function(v) DB().stripBorders = v end)
    check("Taller party bars", function() return DB().partyBars end, function(v) DB().partyBars = v end)
    check("Show party buffs", function() return DB().partyBuffs end, function(v) DB().partyBuffs = v end)
    y = y - 12

    local fontLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fontLabel:SetPoint("TOPLEFT", 18, y); fontLabel:SetText("Bar text size:")
    local x = 130
    for _, s in ipairs({ 11, 12, 14, 16 }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(46, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(tostring(s))
        b:SetScript("OnClick", function() SetFontSize(s) end)
        x = x + 48
    end
    y = y - 34

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(340); hint:SetJustifyH("LEFT")
    hint:SetText("Turning the border art back on takes a reload, since Blizzard only draws it once. Hiding it does not touch the combat or aggro flash.")
    y = y - 46

    container.gaarRefresh = function() for _, fn in ipairs(refreshers) do fn() end end
    return -y
end

local panel
local function BuildPanel()
    if panel then return panel end
    panel = CreateFrame("Frame", "GaarFramesPanel", UIParent, "BackdropTemplate")
    panel:SetSize(392, 380); panel:SetPoint("CENTER")
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
    table.insert(UISpecialFrames, "GaarFramesPanel")

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16); title:SetText("Gaar Frames")
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -8, -8)

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", 8, -40); body:SetPoint("BOTTOMRIGHT", -8, 12)
    local used = GaarFrames_BuildOptions(body)
    panel:SetHeight(used + 60)
    panel:SetScript("OnShow", function() if body.gaarRefresh then body.gaarRefresh() end end)

    panel:Hide()
    return panel
end

local function OpenOptions()
    if _G.GaarOptions_Open and _G.GaarOptions_Open("frames") then return end
    local p = BuildPanel()
    if p:IsShown() then p:Hide() else p:Show() end
end
_G.GaarFrames_Config = OpenOptions

SLASH_GAARFRAMES1 = "/gaarframes"
SLASH_GAARFRAMES2 = "/gframes"
SlashCmdList["GAARFRAMES"] = function() OpenOptions() end
