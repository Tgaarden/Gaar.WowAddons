--[[
  GaarFishingForever - session stats (1.4).

  A small movable panel, shown while a fishing pole is equipped or while the line is out, with:

    * session time (from the first cast of the session), casts, catches and catches per hour;
    * your Fishing skill now and what it gained this session (+x);
    * what you looted while fishing: icon + count for the six most looted items, every item in
      the panel's tooltip.

  What counts:

    * A cast is a Fishing channel start (UNIT_SPELLCAST_CHANNEL_START, passed in from
      GaarFishingForever.lua as stats.OnCast).
    * A catch is a loot window that is fishing loot: LOOT_OPENED with IsFishingLoot() true where
      the client has it (Forever's LootFrame uses it), else a loot window opened while the line
      is out or within LOOT_AFTER_STOP seconds after a Fishing channel ended.
    * Items are counted when they actually leave the loot window: the slots are noted at
      LOOT_OPENED (item link, icon, quantity) and counted at LOOT_SLOT_CLEARED, so items left in
      the window are not counted. Coins and slots without an item link are skipped.

  The session is kept per character in GaarFishingForeverCharDB.session (it survives /reload)
  and starts empty: the first cast starts it. After IDLE_RESET seconds without a cast or a catch
  it is reset by itself. /gfish stats reset resets it by hand, /gfish stats toggles the panel
  (GaarFishingForeverDB.stats, on by default). Drag the panel to move it; the position is saved
  in GaarFishingForeverDB.statsPos.

  The skill comes from RouteGuide.lua (ns.guide.ReadSkill: skill lines, else GetProfessionInfo).
  A skill that cannot be read (a collapsed Secondary Skills header) shows the last one read.

  No global is created: the panel is an unnamed frame. Every client API is checked with type()
  first, every handler runs in pcall, and a secret value is treated as no value.
]]

local _G = _G
local ADDON_NAME, ns = ...
ns = type(ns) == "table" and ns or {}

local BF = _G.GaarForever
local A = ns.addon or BF.NewAddon("GaarFishingForever", { title = "GaarFishingForever" })
ns.addon = A
local Secret, Num, Str, Call = BF.IsSecret, BF.Num, BF.Str, BF.Call
local DOT = " \194\183 "

local IDLE_RESET = 30 * 60      -- seconds without a cast or catch before the session resets
local LOOT_AFTER_STOP = 3       -- fallback: seconds after a Fishing channel stop that loot counts
local TOP = 6                   -- item icons on the panel; the rest are in the tooltip
local ICON = 22
local WIDTH = 6 + TOP * (ICON + 4) + 2

local stats = {}
ns.stats = stats

local db                        -- GaarFishingForeverDB (stats, statsPos)
local charDb                    -- GaarFishingForeverCharDB (session)
local lineOut                   -- the Fishing channel runs
local stopAt                    -- GetTime() the last Fishing channel ended
local lootSlots                 -- slot = { id, icon, qty, link } of the open fishing loot window
local lastSkill                 -- the last skill read
local lastError

local panel, text, icons
local accum = 0

local function Fail(where, err)
    lastError = where .. ": " .. tostring(err)
end

local function Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Fail(where, err) end
end

local function Now()
    return Num(Call(_G.GetTime)) or 0
end

-- Wall-clock seconds, so a session kept over /reload or a relog keeps its time.
local function Epoch()
    return Num(Call(_G.time)) or Now()
end

local function On()
    return db ~= nil and db.stats ~= false
end

local function Core()
    return type(ns.core) == "table" and ns.core or {}
end

local function PoleEquipped()
    local f = Core().PoleEquipped
    return type(f) == "function" and f() and true or false
end

local function ReadSkill()
    local g = ns.guide
    if type(g) == "table" and type(g.ReadSkill) == "function" then
        local skill, cap = g.ReadSkill()
        skill, cap = Num(skill), Num(cap)
        if skill and skill > 0 then
            lastSkill = { skill = skill, cap = cap }
        end
    end
    return lastSkill
end

-- ---------------------------------------------------------------------------
-- The session
-- ---------------------------------------------------------------------------

local function Empty()
    return { casts = 0, catches = 0, items = {} }
end

local function Session()
    if not charDb then return Empty() end
    local s = charDb.session
    if type(s) ~= "table" then
        s = Empty()
        charDb.session = s
    end
    if s.last and Epoch() - s.last > IDLE_RESET then
        s = Empty()
        charDb.session = s
    end
    return s
end

-- Something happened: start the session if it has not started, note the time.
local function Touch(s)
    local now = Epoch()
    if not s.start then
        s.start = now
        local sk = ReadSkill()
        s.skill0 = sk and sk.skill or nil
    elseif not s.skill0 then
        local sk = ReadSkill()
        s.skill0 = sk and sk.skill or nil
    end
    s.last = now
end

-- Items sorted by count, most first; ties by item ID.
local function Sorted(s)
    local list = {}
    for id, it in pairs(s.items) do
        list[#list + 1] = { id = id, n = it.n, icon = it.icon, link = it.link }
    end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.id < b.id
    end)
    return list
end

local function Elapsed(s)
    if not s.start then return 0 end
    return math.max(0, Epoch() - s.start)
end

local function PerHour(s)
    local e = Elapsed(s)
    if s.catches == 0 or e < 60 then return nil end
    return s.catches * 3600 / e
end

local function SkillText(s)
    local sk = ReadSkill()
    if not sk then return "Skill ?" end
    local t = "Skill " .. sk.skill .. (sk.cap and sk.cap > 0 and ("/" .. sk.cap) or "")
    if s.skill0 then t = t .. string.format(" (+%d)", math.max(0, sk.skill - s.skill0)) end
    return t
end

local function Lines(s)
    local lines = {}
    lines[1] = s.start and ("Session " .. BF.Clock(Elapsed(s))) or "Session: cast to start"
    local ph = PerHour(s)
    lines[2] = "Casts " .. s.casts .. DOT .. "Catches " .. s.catches
        .. (ph and (DOT .. string.format("%.0f/h", ph)) or "")
    lines[3] = SkillText(s)
    return lines
end

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------

local function SavePos()
    if not panel or not db then return end
    local p, _, rp, x, y = panel:GetPoint(1)
    if Str(p) and Num(x) and Num(y) then db.statsPos = { p = p, rp = Str(rp) or p, x = x, y = y } end
end

local function Place()
    panel:ClearAllPoints()
    local pos = db and db.statsPos
    if type(pos) == "table" and Str(pos.p) and Num(pos.x) and Num(pos.y) then
        panel:SetPoint(pos.p, _G.UIParent, Str(pos.rp) or pos.p, pos.x, pos.y)
    else
        panel:SetPoint("TOPRIGHT", _G.UIParent, "TOPRIGHT", -260, -220)
    end
end

local function ShowTooltip(self)
    local tip = _G.GameTooltip
    if type(tip) ~= "table" or type(tip.SetOwner) ~= "function" then return end
    local s = Session()
    tip:SetOwner(self, "ANCHOR_LEFT")
    tip:AddLine("Fishing session")
    for _, l in ipairs(Lines(s)) do tip:AddLine(l, 1, 1, 1) end
    local list = Sorted(s)
    if #list > 0 then
        tip:AddLine(" ")
        tip:AddLine("Looted while fishing")
        for i, it in ipairs(list) do
            local icon = it.icon and ("|T" .. tostring(it.icon) .. ":14|t ") or ""
            tip:AddDoubleLine(icon .. (it.link or ("item " .. it.id)), "x" .. it.n,
                1, 1, 1, i > TOP and 0.7 or 1, i > TOP and 0.7 or 1, i > TOP and 0.7 or 1)
        end
    end
    tip:AddLine(" ")
    tip:AddLine("Drag to move. /gfish stats reset starts over, /gfish stats hides it.", 0.6, 0.6, 0.6, true)
    tip:Show()
end

local function HideTooltip()
    local tip = _G.GameTooltip
    if type(tip) == "table" and type(tip.Hide) == "function" then tip:Hide() end
end

local function Create()
    if panel then return end
    panel = CreateFrame("Frame", nil, _G.UIParent)
    panel:SetFrameStrata("MEDIUM")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    if type(BF.AttachMenu) == "function" then
        BF.AttachMenu(panel, { title = "GaarFishingForever", api = "GaarFishingForeverAPI", hook = true }) -- right-click: the addon's menu
    end
    panel:SetSize(WIDTH, 60)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.55)
    text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", 6, -5)
    text:SetJustifyH("LEFT")
    icons = {}
    for i = 1, TOP do
        local f = CreateFrame("Frame", nil, panel)
        f:SetSize(ICON, ICON)
        f.tex = f:CreateTexture(nil, "ARTWORK")
        f.tex:SetAllPoints()
        f.count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        f.count:SetPoint("BOTTOMRIGHT", 1, -1)
        f:Hide()
        icons[i] = f
    end
    panel:SetScript("OnDragStart", function(self) Safe("drag", function() self:StartMoving() end) end)
    panel:SetScript("OnDragStop", function(self)
        Safe("drag", function() self:StopMovingOrSizing(); SavePos() end)
    end)
    panel:SetScript("OnEnter", function(self) Safe("tooltip", ShowTooltip, self) end)
    panel:SetScript("OnLeave", function() Safe("tooltip", HideTooltip) end)
    -- Runs only while the panel is shown: the clock, and the idle reset.
    panel:SetScript("OnUpdate", function(_, elapsed)
        accum = accum + (Num(elapsed) or 0)
        if accum < 1 then return end
        accum = 0
        Safe("tick", stats.Refresh)
    end)
    panel:Hide()
    Place()
end

local function Fill()
    local s = Session()
    text:SetText(table.concat(Lines(s), "\n"))
    local list = Sorted(s)
    local textH = Num(text:GetStringHeight()) or 36
    local y = -(5 + textH + 4)
    for i = 1, TOP do
        local f, it = icons[i], list[i]
        if it then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", panel, "TOPLEFT", 6 + (i - 1) * (ICON + 4), y)
            f.tex:SetTexture(it.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            f.count:SetText(it.n > 1 and tostring(it.n) or "")
            f:Show()
        else
            f:Hide()
        end
    end
    local h = 5 + textH + 6 + (#list > 0 and (ICON + 4) or 0)
    local w = math.max(WIDTH, (Num(text:GetStringWidth()) or 0) + 12)
    panel:SetSize(w, h)
end

function stats.Refresh()
    if not db then return end
    local want = On() and (lineOut or PoleEquipped())
    if not want then
        if panel then panel:Hide() end
        return
    end
    Create()
    Fill()
    panel:Show()
end

-- ---------------------------------------------------------------------------
-- Loot
-- ---------------------------------------------------------------------------

local function FishingLoot()
    if type(_G.IsFishingLoot) == "function" then
        local ok, v = pcall(_G.IsFishingLoot)
        if ok and not Secret(v) then return v and true or false end
    end
    return lineOut or (stopAt ~= nil and Now() - stopAt <= LOOT_AFTER_STOP)
end

local function ItemID(link)
    local c = _G.C_Item
    local info = (type(c) == "table" and type(c.GetItemInfoInstant) == "function" and c.GetItemInfoInstant)
        or (type(_G.GetItemInfoInstant) == "function" and _G.GetItemInfoInstant)
    if info then
        local id = Num(Call(info, link))
        if id then return id end
    end
    local m = link:match("item:(%d+)")
    return m and Num(tonumber(m)) or nil
end

local function OnLootOpened()
    lootSlots = nil
    if not charDb or not FishingLoot() then return end
    local s = Session()
    Touch(s)
    s.catches = s.catches + 1
    local slots = {}
    local n = Num(Call(_G.GetNumLootItems)) or 0
    for slot = 1, n do
        local link = Str(Call(_G.GetLootSlotLink, slot))
        local id = link and ItemID(link)
        if id then
            local icon, _, qty = Call(_G.GetLootSlotInfo, slot)
            icon = Num(icon) or Str(icon)
            slots[slot] = { id = id, icon = icon, qty = Num(qty) or 1, link = link }
        end
    end
    lootSlots = slots
    stats.Refresh()
end

local function OnSlotCleared(slot)
    slot = Num(slot)
    local it = slot and lootSlots and lootSlots[slot]
    if not it or not charDb then return end
    lootSlots[slot] = nil
    local s = Session()
    local entry = s.items[it.id]
    if type(entry) ~= "table" then
        entry = { n = 0 }
        s.items[it.id] = entry
    end
    entry.n = entry.n + math.max(1, it.qty)
    entry.icon = it.icon or entry.icon
    entry.link = it.link or entry.link
    s.last = Epoch()
    stats.Refresh()
end

-- ---------------------------------------------------------------------------
-- Called from GaarFishingForever.lua
-- ---------------------------------------------------------------------------

function stats.OnCast()
    lineOut = true
    if not charDb then return end
    local s = Session()
    Touch(s)
    s.casts = s.casts + 1
    stats.Refresh()
end

function stats.OnChannelStop()
    lineOut = false
    stopAt = Now()
    stats.Refresh()
end

function stats.IsOn() return On() end

function stats.SetOn(on, quiet)
    if not db then return end
    db.stats = on and true or false
    stats.Refresh()
    if not quiet then
        A:Print(on and "stats on: the session panel shows while a fishing pole is equipped or the line is out."
            or "stats off.")
    end
end

function stats.Reset(quiet)
    if not charDb then return end
    charDb.session = Empty()
    lootSlots = nil
    stats.Refresh()
    if not quiet then A:Print("session stats reset.") end
end

function stats.Slash(arg)
    local a = (arg or ""):lower()
    if a == "reset" then
        stats.Reset()
    elseif a == "on" or a == "off" then
        stats.SetOn(a == "on")
    else
        stats.SetOn(not On())
    end
end

function stats.HelpLines()
    return {
        "/gfish stats - show or hide the session panel (now " .. (On() and "on" or "off")
            .. "); /gfish stats reset - start a new session (it also resets after 30 min without fishing)",
    }
end

function stats.StatusLines()
    local s = Session()
    local l = Lines(s)
    return {
        "stats: " .. (On() and "on" or "off") .. "   " .. l[1] .. DOT .. l[2] .. DOT .. l[3]
            .. DOT .. "items " .. #Sorted(s)
            .. "   IsFishingLoot: " .. (type(_G.IsFishingLoot) == "function" and "yes" or "no (loot right after the channel)")
            .. (lastError and ("   last error: " .. lastError) or ""),
    }
end

-- Bound from GaarFishingForever.lua at ADDON_LOADED.
function stats.Bind(accountDb, characterDb)
    db, charDb = accountDb, characterDb
    if type(db.stats) ~= "boolean" then db.stats = true end
    local pos = db.statsPos
    if type(pos) == "table" and Str(pos.p) and Num(pos.x) and Num(pos.y) then
        db.statsPos = { p = pos.p, rp = Str(pos.rp) or pos.p, x = pos.x, y = pos.y }
    else
        db.statsPos = nil
    end
    local s = charDb.session
    if type(s) == "table" then
        local clean = { casts = math.max(0, math.floor(Num(s.casts) or 0)),
            catches = math.max(0, math.floor(Num(s.catches) or 0)),
            start = Num(s.start), last = Num(s.last), skill0 = Num(s.skill0), items = {} }
        if type(s.items) == "table" then
            for id, it in pairs(s.items) do
                id = Num(id)
                if id and type(it) == "table" and Num(it.n) and it.n > 0 then
                    clean.items[id] = { n = math.floor(it.n), icon = Num(it.icon) or Str(it.icon),
                        link = Str(it.link) }
                end
            end
        end
        if not clean.start then clean = Empty() end
        charDb.session = clean
    else
        charDb.session = nil
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_EQUIPMENT_CHANGED", "LOOT_OPENED", "LOOT_SLOT_CLEARED",
    "LOOT_CLOSED", "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL" }) do
    pcall(events.RegisterEvent, events, e)  -- an event this client does not know raises an error
end
events:SetScript("OnEvent", function(_, event, arg1)
    local ok, err = pcall(function()
        if event == "LOOT_OPENED" then
            OnLootOpened()
        elseif event == "LOOT_SLOT_CLEARED" then
            OnSlotCleared(arg1)
        elseif event == "LOOT_CLOSED" then
            lootSlots = nil
        else
            stats.Refresh()     -- login, pole on or off, a skill-up
        end
    end)
    if not ok then Fail(event, err) end
end)
