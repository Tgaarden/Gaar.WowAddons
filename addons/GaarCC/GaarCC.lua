--[[
  Gaar CC — cooldown-count text, ported from Deepward CC (WotLK 3.3.5a) to WoW Classic Era.

  Draws a shrinking countdown number on top of any cooldown swipe (action buttons, items,
  buffs, ...). Colour and precision ramp up as the cooldown runs out; GCD-length cooldowns
  are ignored.

  /gaarcc — options.

  Classic Era port notes vs the WotLK original:
   * CooldownFrame_SetTimer is gone. Instead the Cooldown widget's own SetCooldown method is
     hooked once on its shared metatable, which catches every cooldown in the UI no matter
     which code path set it (CooldownFrame_Set, addons calling SetCooldown directly, ...).
   * The countdown text lives on a small child frame per cooldown rather than on an OnUpdate
     script on the cooldown itself, so nothing Blizzard puts there gets overwritten.
   * Blizzard's own built-in countdown numbers are switched off per cooldown so the two
     don't stack.
   * SetBackdrop needs the "BackdropTemplate" mixin, and no EasyMenu/dropdown API is used.
]]

local _G = _G

-- Retail hands out "secret values" - here for cooldown start and duration - which may be shown
-- and passed back to Blizzard's widgets, but not compared, tested or computed with. A cooldown
-- whose timings are secret simply gets no count: there is no way to work one out.
local issecretvalue = _G.issecretvalue
local function Secret(a, b)
    if not issecretvalue then return false end
    if issecretvalue(a) then return true end
    return b ~= nil and issecretvalue(b) or false
end
local ADDON = "Gaar CC"
local format = string.format

local function DB()
    if type(GaarCCDB) ~= "table" then GaarCCDB = {} end
    local d = GaarCCDB
    if d.enabled     == nil then d.enabled = true end
    if d.minDuration == nil then d.minDuration = 2 end    -- ignore GCD / very short cooldowns
    if d.minSize     == nil then d.minSize = 16 end       -- don't draw on tiny cooldown frames
    if d.scale       == nil then d.scale = 0.42 end       -- text size as a fraction of the frame size
    if d.tenths      == nil then d.tenths = 3 end         -- show tenths below this many seconds
    return d
end

-- remaining seconds -> text + colour
local function Fmt(t)
    if t >= 3600 then return format("%dh", t / 3600 + 0.5), 0.7, 0.7, 0.7
    elseif t >= 60 then return format("%dm", t / 60 + 0.5), 0.7, 0.7, 0.7
    elseif t >= 10 then return format("%d", t + 0.5), 1, 1, 0             -- yellow
    elseif t >= DB().tenths then return format("%d", t + 0.5), 1, 0.55, 0 -- orange
    else return format("%.1f", t), 1, 0.1, 0.1 end                        -- red tenths
end

local function Stop(timer)
    timer.start = nil
    timer.text:Hide()
    timer:Hide()
end

local function OnUpdate(timer, elapsed)
    timer.acc = (timer.acc or 0) + elapsed
    if timer.acc < 0.1 then return end
    timer.acc = 0
    if not timer.start then Stop(timer); return end
    local remain = timer.start + timer.duration - GetTime()
    if remain <= 0 then Stop(timer); return end
    local txt, r, g, b = Fmt(remain)
    timer.text:SetText(txt); timer.text:SetTextColor(r, g, b); timer.text:Show()
end

-- One child frame per cooldown carries the text and the ticker, so the cooldown's own
-- scripts are left untouched.
local function Timer(cd)
    if cd._gaarTimer then return cd._gaarTimer end
    local timer = CreateFrame("Frame", nil, cd)
    timer:SetAllPoints(cd)
    if cd.GetFrameLevel then timer:SetFrameLevel(cd:GetFrameLevel() + 1) end
    timer.text = timer:CreateFontString(nil, "OVERLAY")
    timer.text:SetPoint("CENTER", timer, "CENTER", 0, 0)
    timer:SetScript("OnUpdate", OnUpdate)
    timer:Hide()
    cd._gaarTimer = timer
    return timer
end

local function StartTimer(cd, start, duration)
    local timer = Timer(cd)
    timer.start, timer.duration, timer.acc = start, duration, 0
    -- The cooldown is Blizzard's frame, so its width can be hidden. No size to scale the text
    -- from means the configured size stands and the text is shown: a count that is there at the
    -- wrong size beats no count at all.
    local sz = cd:GetWidth()
    if Secret(sz) then sz = nil end
    timer.text:SetFont(STANDARD_TEXT_FONT, math.max(9, (sz or 32) * DB().scale), "OUTLINE")
    if sz and sz < DB().minSize then timer.text:Hide() else timer.text:Show() end
    timer:Show()
    -- don't stack with Blizzard's own numbers on the same swipe
    if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
end


local function HandleCooldown(cd, start, duration)
    if not cd or cd.noCooldownCount then return end          -- respect frames that show their own count
    if not DB().enabled then
        if cd._gaarTimer then Stop(cd._gaarTimer) end
        return
    end
    if Secret(start, duration) then
        -- Unreadable is not the same as finished. Blizzard's action buttons re-issue SetCooldown
        -- constantly, and tearing the timer down on every unreadable call made the numbers vanish
        -- a moment after they appeared. Hovering the button re-issued readable values, which is
        -- exactly why they came back on hover and died again straight afterwards.
        --
        -- A cooldown that genuinely ends arrives as start = 0, which is not secret, so the
        -- branch below still stops the timer. Leaving these calls alone strands nothing.
        return
    end
    if start and duration and start > 0 and duration > DB().minDuration then
        StartTimer(cd, start, duration)
    elseif cd._gaarTimer then
        Stop(cd._gaarTimer)
    end
end

-- Hook the Cooldown widget itself: every cooldown swipe in the UI goes through SetCooldown,
-- whichever helper set it.
local cdProto = CreateFrame("Cooldown", nil, UIParent)
local cdIndex = getmetatable(cdProto).__index
hooksecurefunc(cdIndex, "SetCooldown", function(cd, start, duration)
    HandleCooldown(cd, start, duration)
end)
-- Older helper, still hooked if this build happens to have it.
if type(_G.CooldownFrame_SetTimer) == "function" then
    hooksecurefunc("CooldownFrame_SetTimer", function(cd, start, duration, enable)
        if enable ~= nil and enable == 0 then return end
        HandleCooldown(cd, start, duration)
    end)
end

-- ---------------------------------------------------------------------------
-- Options
--
-- Built into whatever frame they are handed, so the same controls serve both the
-- "Gaar" entry in Blizzard's AddOns options and the standalone fallback window.
-- No dropdown/EasyMenu API is used.
-- ---------------------------------------------------------------------------
local uid = 0

-- Fills `container` with every Gaar CC control. Returns the height it used.
function GaarCC_BuildOptions(container)
    local refreshers = {}
    local y = -8

    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("Cooldown numbers")
    y = y - 26

    uid = uid + 1
    local cbName = "GaarCCCheck" .. uid
    local enabled = CreateFrame("CheckButton", cbName, container, "UICheckButtonTemplate")
    enabled:SetSize(24, 24); enabled:SetPoint("TOPLEFT", 16, y)
    enabled:SetChecked(DB().enabled)
    local cbText = _G[cbName .. "Text"]
    cbText:SetText("Enabled"); cbText:SetFontObject(GameFontHighlight)
    enabled:SetScript("OnClick", function(self)
        DB().enabled = self:GetChecked() and true or false
        print("|cff5599ff" .. ADDON .. ":|r " ..
            (DB().enabled and "on — cooldown numbers shown." or "off (existing swipes clear as they finish)."))
    end)
    refreshers[#refreshers + 1] = function() enabled:SetChecked(DB().enabled) end
    y = y - 34

    local sizeLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sizeLabel:SetPoint("TOPLEFT", 18, y); sizeLabel:SetText("Text size:")
    local x = 120
    for _, s in ipairs({ { "Small", 0.34 }, { "Normal", 0.42 }, { "Large", 0.5 } }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(62, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(s[1])
        b:SetScript("OnClick", function() DB().scale = s[2] end)
        x = x + 64
    end
    y = y - 30

    local minLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    minLabel:SetPoint("TOPLEFT", 18, y); minLabel:SetText("Ignore under:")
    x = 120
    for _, s in ipairs({ 0, 2, 5 }) do
        local b = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        b:SetSize(62, 20); b:SetPoint("TOPLEFT", x, y + 4); b:SetText(s .. "s")
        b:SetScript("OnClick", function() DB().minDuration = s end)
        x = x + 64
    end
    y = y - 34

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(340); hint:SetJustifyH("LEFT")
    hint:SetText("Size and threshold apply to cooldowns that start after the change. 2s keeps the global cooldown off your buttons.")
    y = y - 44

    container.gaarRefresh = function() for _, fn in ipairs(refreshers) do fn() end end
    return -y
end

-- Standalone window, used when the Blizzard options entry isn't available.
local panel
local function BuildPanel()
    if panel then return panel end
    panel = CreateFrame("Frame", "GaarCCPanel", UIParent, "BackdropTemplate")
    panel:SetSize(392, 260)
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
    table.insert(UISpecialFrames, "GaarCCPanel")

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16); title:SetText(ADDON)
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -8, -8)

    local body = CreateFrame("Frame", nil, panel)
    body:SetPoint("TOPLEFT", 8, -40); body:SetPoint("BOTTOMRIGHT", -8, 12)
    local used = GaarCC_BuildOptions(body)
    panel:SetHeight(used + 60)
    panel:SetScript("OnShow", function() if body.gaarRefresh then body.gaarRefresh() end end)

    panel:Hide()
    return panel
end

local function OpenOptions()
    if _G.GaarOptions_Open and _G.GaarOptions_Open("cc") then return end
    local p = BuildPanel()
    if p:IsShown() then p:Hide() else p:Show() end
end
_G.GaarCC_Config = OpenOptions

SLASH_GAARCC1 = "/gaarcc"
SLASH_GAARCC2 = "/gcc"
SlashCmdList["GAARCC"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "on" then DB().enabled = true; print("|cff5599ff" .. ADDON .. ":|r on.")
    elseif msg == "off" then DB().enabled = false; print("|cff5599ff" .. ADDON .. ":|r off.")
    else OpenOptions() end
end
