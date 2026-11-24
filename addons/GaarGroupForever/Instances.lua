--[[
  GaarGroupForever - Instances.lua: dungeon info panel.

  Data: Data/Instances.lua (M.InstanceData: every vanilla 5-man dungeon with levels, bosses and
  notable loot). When you are inside a known instance (GetInstanceInfo name, checked on
  PLAYER_ENTERING_WORLD / ZONE_CHANGED_NEW_AREA) an "Info" panel hangs under the bar (a dock panel,
  see Overview.lua) with:
    - the instance name, recommended levels against your level and the party's levels
      (coloured like mob difficulty, Lib.LevelDifficultyColor: green = easy, yellow = even, red = hard),
    - the boss list; a boss is ticked when ENCOUNTER_END (success) / BOSS_KILL reports it, else when
      the hostile-death chat line (CHAT_MSG_COMBAT_HOSTILE_DEATH: "X dies." / "You have slain X!") names
      it; click a boss row to tick or untick it by hand,
    - "Loot for you": the notable loot that your class can use (armor type from your level, weapon
      types, shield / relic, and the stats your class wants); click the header to open or close it.
  Hover a boss: tooltip with all of its notable loot, quality coloured, the ones for you first.
  /ggf info [name] shows a text window for any instance (also outside one).

  Everything is event driven (events / HookScript style); no Blizzard frame is touched. Client values
  go through M.Q / pcall and a secret value is never compared: it counts as no value.
  NOT the combat log: WoW Forever (12.x engine) closes COMBAT_LOG_EVENT_* to addons, and merely
  registering for it gets the addon blocked ("blocked from an action only available to the Blizzard
  UI", ADDON_ACTION_FORBIDDEN on Frame:RegisterEvent) at every login. 1.4.0 did that; 1.4.1 does not.
]]

local _G = _G
local API = _G.GaarGroupForeverAPI
local M = API and API._M
if not M then return end

local BF = _G.GaarForever
local IsSecret = BF.IsSecret

M.Defaults.instInfo = true
M.Defaults.instOpen = true
M.Defaults.instCollapsed = false
M.Defaults.instLoot = false
M.Defaults.instRun = {}

local N = {
    cur = nil,  -- the instance you are in (data table) or nil
    view = nil, -- an instance shown by /ggf info <name>
}
M.Inst = N
local ROWH = 14
local MAX_LOOT_ROWS = 14

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------

-- "Zul'Farrak" -> "zulfarrak", "The Deadmines" -> "deadmines": lower case, apostrophes dropped, other
-- punctuation = one space, no leading "the".
function N.Norm(s)
    if type(s) ~= "string" then return "" end
    s = s:lower():gsub("[\039\226\128\153]", ""):gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^the ", "")
    return s
end

function N.Data() return M.InstanceData or {} end

-- Flat index: { norm, inst, wing } for every name, alias and wing name.
function N.Index()
    if N.index then return N.index end
    local idx = {}
    local function add(text, inst, wing)
        local n = N.Norm(text)
        if n ~= "" then idx[#idx + 1] = { n = n, inst = inst, wing = wing } end
    end
    for _, inst in ipairs(N.Data()) do
        add(inst.name, inst)
        add(inst.key, inst)
        for _, a in ipairs(inst.aliases or {}) do add(a, inst) end
        for _, w in ipairs(inst.wings or {}) do
            add(w.name, inst, w.name)
            for _, a in ipairs(w.aliases or {}) do add(a, inst, w.name) end
        end
    end
    N.index = idx
    return idx
end

-- Exact match only (for GetInstanceInfo names). Returns inst, wing.
function N.FindExact(name)
    local n = N.Norm(name)
    if n == "" then return nil end
    for _, e in ipairs(N.Index()) do
        if e.n == n then return e.inst, e.wing end
    end
end

-- Forgiving match for /ggf info: exact, then prefix, then contains. Returns inst, wing.
function N.Find(query)
    local inst, wing = N.FindExact(query)
    if inst then return inst, wing end
    local n = N.Norm(query)
    if #n < 2 then return nil end
    for _, e in ipairs(N.Index()) do
        if e.n:sub(1, #n) == n then return e.inst, e.wing end
    end
    for _, e in ipairs(N.Index()) do
        if e.n:find(n, 1, true) then return e.inst, e.wing end
    end
end

-- ---------------------------------------------------------------------------
-- Loot
-- ---------------------------------------------------------------------------

-- Loot entries are "Name|Slot|Type|stats|q" strings (q: r = rare/blue, e = epic/purple, u = green;
-- Type empty for rings, necks, cloaks, trinkets ...). Parsed once into tables.
function N.Loot(boss)
    if boss._p then return boss._p end
    local out = {}
    for _, s in ipairs(boss.loot or {}) do
        local name, slot, typ, stats, q = s:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|?([^|]*)$")
        if name and name ~= "" then
            out[#out + 1] = { name = name, slot = slot, type = typ ~= "" and typ or nil,
                stats = stats or "", q = q ~= "" and q or "r", boss = boss }
        end
    end
    boss._p = out
    return out
end

local function Set(s)
    local t = {}
    for w in s:gmatch("[^,]+") do t[w] = true end
    return t
end

-- Armor: the best type the class wears at that level; weapons: what it can use; stats: what it wants.
N.CLASSES = {
    WARRIOR = { armor = "Mail", armor40 = "Plate", shield = true,
        weapons = Set("Dagger,1H Sword,2H Sword,1H Axe,2H Axe,1H Mace,2H Mace,Polearm,Staff,Fist,Bow,Crossbow,Gun,Thrown"),
        stats = Set("str,agi,sta,def,ap,crit") },
    PALADIN = { armor = "Mail", armor40 = "Plate", shield = true, relic = "Libram",
        weapons = Set("1H Sword,2H Sword,1H Axe,2H Axe,1H Mace,2H Mace,Polearm"),
        stats = Set("str,sta,int,spi,heal,sp,def,mp5,crit,ap") },
    HUNTER = { armor = "Leather", armor40 = "Mail",
        weapons = Set("Dagger,1H Sword,2H Sword,1H Axe,2H Axe,Polearm,Staff,Fist,Bow,Crossbow,Gun,Thrown"),
        stats = Set("agi,str,sta,int,ap,crit,mp5") },
    ROGUE = { armor = "Leather",
        weapons = Set("Dagger,1H Sword,1H Mace,Fist,Bow,Crossbow,Gun,Thrown"),
        stats = Set("agi,str,sta,ap,crit") },
    SHAMAN = { armor = "Leather", armor40 = "Mail", shield = true, relic = "Totem",
        weapons = Set("Dagger,1H Axe,2H Axe,1H Mace,2H Mace,Staff,Fist"),
        stats = Set("str,agi,sta,int,spi,heal,sp,mp5,crit,ap") },
    DRUID = { armor = "Leather", relic = "Idol",
        weapons = Set("Dagger,1H Mace,2H Mace,Staff,Fist,Polearm"),
        stats = Set("agi,str,sta,int,spi,heal,sp,mp5,crit,ap") },
    MAGE = { armor = "Cloth", weapons = Set("Dagger,1H Sword,Staff,Wand"), stats = Set("int,spi,sta,sp,mp5,crit") },
    WARLOCK = { armor = "Cloth", weapons = Set("Dagger,1H Sword,Staff,Wand"), stats = Set("int,spi,sta,sp,mp5,crit") },
    PRIEST = { armor = "Cloth", weapons = Set("Dagger,1H Mace,Staff,Wand"), stats = Set("int,spi,sta,sp,heal,mp5") },
}

local ARMOR = { Cloth = true, Leather = true, Mail = true, Plate = true }

-- The one armor type worth wearing: Mail until 40 for plate classes, Leather until 40 for mail classes.
function N.TopArmor(class, level)
    local c = N.CLASSES[class]
    if not c then return nil end
    if c.armor40 and type(level) == "number" and level >= 40 then return c.armor40 end
    return c.armor
end

-- Can and would this class use the item (armor / weapon type, shield / relic, stats)?
function N.UsableBy(item, class, level)
    local c = N.CLASSES[class]
    if not c then return true end -- unknown class: show everything
    local t = item.type
    if t then
        if ARMOR[t] then
            if t ~= N.TopArmor(class, level) then return false end
        elseif t == "Shield" then
            if not c.shield then return false end
        elseif t == "Libram" or t == "Idol" or t == "Totem" then
            if c.relic ~= t then return false end
        elseif not c.weapons[t] then
            return false
        end
    end
    local stats = item.stats or ""
    if stats == "" then return true end
    for tok in stats:gmatch("[^/]+") do
        if c.stats[tok] then return true end
    end
    return false
end

function N.LootForYou(inst, class, level)
    local out = {}
    for _, b in ipairs(inst.bosses) do
        for _, it in ipairs(N.Loot(b)) do
            if N.UsableBy(it, class, level) then out[#out + 1] = it end
        end
    end
    return out
end

N.QUALITY = { r = { 0.0, 0.44, 0.87, "0070dd" }, e = { 0.64, 0.21, 0.93, "a335ee" }, u = { 0.12, 1, 0, "1eff00" } }
function N.QColor(q) return N.QUALITY[q] or N.QUALITY.r end

-- ---------------------------------------------------------------------------
-- Levels and colours
-- ---------------------------------------------------------------------------

local function Hex(r, g, b)
    return string.format("%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- Colour (r, g, b) of the instance for a player of that level: the instance's middle level as a "mob".
function N.DiffColor(lo, hi, level)
    local f = BF.LevelDifficultyColor
    if type(f) ~= "function" or type(lo) ~= "number" or type(level) ~= "number" then return 1, 1, 1 end
    return f(math.floor(((lo or hi) + (hi or lo)) / 2 + 0.5), level)
end

function N.LevelText(lo, hi, level)
    local r, g, b = N.DiffColor(lo, hi, level)
    return "|cff" .. Hex(r, g, b) .. tostring(level) .. "|r"
end

-- The wing record for a wing name, or nil.
function N.WingInfo(inst, wing)
    for _, w in ipairs(inst.wings or {}) do
        if w.name == wing then return w end
    end
end

function N.Range(lo, hi)
    if not lo then return "?" end
    if not hi or hi == lo then return tostring(lo) end
    return lo .. "-" .. hi
end

-- ---------------------------------------------------------------------------
-- Kills (this run)
-- ---------------------------------------------------------------------------

function N.Run(inst)
    local db = M.db
    if not db then return { kills = {} } end
    local run = db.instRun
    if type(run) ~= "table" then run = {}; db.instRun = run end
    local now = type(_G.time) == "function" and _G.time() or 0
    if run.key ~= inst.key or type(run.kills) ~= "table" or (run.t and now - run.t > 7200) then
        run.key, run.kills, run.t = inst.key, {}, now
    end
    return run
end

function N.IsKilled(inst, boss)
    local run = N.Run(inst)
    return run.kills[N.Norm(boss.name)] == true
end

function N.SetKilled(inst, boss, v)
    local run = N.Run(inst)
    run.kills[N.Norm(boss.name)] = v and true or nil
    run.t = type(_G.time) == "function" and _G.time() or run.t
end

-- The boss of inst that a game name (ENCOUNTER_END / BOSS_KILL / dying unit) is, or nil.
function N.BossByName(inst, name)
    local n = N.Norm(name)
    if n == "" then return nil end
    for _, b in ipairs(inst.bosses) do
        if N.Norm(b.name) == n then return b end
    end
    if #n >= 5 then
        for _, b in ipairs(inst.bosses) do
            local bn = N.Norm(b.name)
            if bn:find(n, 1, true) or n:find(bn, 1, true) then return b end
        end
    end
end

-- Returns the boss that was ticked, or nil.
function N.MarkKilled(name)
    local inst = N.cur
    if not inst then return nil end
    local b = N.BossByName(inst, name)
    if b and not N.IsKilled(inst, b) then N.SetKilled(inst, b, true) end
    return b
end

function N.KillCount(inst)
    local n = 0
    for _, b in ipairs(inst.bosses) do
        if N.IsKilled(inst, b) then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Context: you and the party
-- ---------------------------------------------------------------------------

function N.PlayerClass()
    if type(_G.UnitClass) ~= "function" then return nil end
    local ok, _, token = pcall(_G.UnitClass, "player")
    if ok and type(token) == "string" and not IsSecret(token) then return token end
end

function N.PartyLevels()
    local list = {}
    if not M.InGroup() then return list end
    for i = 1, 4 do
        local u = "party" .. i
        if M.Q(_G.UnitExists, u) then
            local lvl = M.Q(_G.UnitLevel, u)
            list[#list + 1] = type(lvl) == "number" and lvl or 0
        end
    end
    return list
end

function N.Ctx()
    local lvl = M.Q(_G.UnitLevel, "player")
    return { level = type(lvl) == "number" and lvl or nil, class = N.PlayerClass(), party = N.PartyLevels(),
        collapsed = M.db and M.db.instCollapsed == true, lootOpen = M.db and M.db.instLoot == true }
end

-- ---------------------------------------------------------------------------
-- Rows (the panel's content; pure so it can be tested)
-- ---------------------------------------------------------------------------

local function Plain(r, g, b) return "|cff" .. Hex(r, g, b) end

-- A boss's tooltip: { { text, r, g, b }, ... }.
function N.BossTip(boss, ctx)
    local t = { { boss.name .. (boss.level and ("  (level " .. (boss.level > 0 and boss.level or "??") .. ")") or ""), 1, 1, 1 } }
    if boss.tip then t[#t + 1] = { boss.tip, 0.8, 0.8, 0.8 } end
    local mine, others = {}, {}
    for _, it in ipairs(N.Loot(boss)) do
        if N.UsableBy(it, ctx.class, ctx.level) then mine[#mine + 1] = it else others[#others + 1] = it end
    end
    local function line(it, dim)
        local c = N.QColor(it.q)
        local d = it.slot .. (it.type and (", " .. it.type) or "") .. (it.stats ~= "" and (", " .. it.stats) or "")
        t[#t + 1] = { it.name .. "  |cff9d9d9d" .. d .. "|r", dim and 0.5 or c[1], dim and 0.5 or c[2], dim and 0.5 or c[3] }
    end
    if #mine + #others == 0 then
        t[#t + 1] = { boss.nl and "Loot not listed yet." or "No notable (blue or better) loot.", 0.6, 0.6, 0.6 }
    end
    if #mine > 0 then t[#t + 1] = { "Loot for you", 1, 0.82, 0 }; for _, it in ipairs(mine) do line(it) end end
    if #others > 0 then t[#t + 1] = { "Other loot", 1, 0.82, 0 }; for _, it in ipairs(others) do line(it, true) end end
    return t
end

-- Rows for the panel. Each: { kind = header|party|wing|boss|lootHead|loot|more, text = "...",
-- boss = , item = , tip = lines|nil, checked = bool }.
function N.Rows(inst, ctx)
    local rows = {}
    local lo, hi = inst.lo, inst.hi
    local mine = ctx.level
    local rec = N.Range(lo, hi)
    local head = (ctx.collapsed and "[+] " or "[-] ") .. "|cffffd100" .. inst.name .. "|r  "
    local r, g, b = N.DiffColor(lo, hi, mine)
    head = head .. Plain(r, g, b) .. rec .. "|r"
    if mine then head = head .. "  |cff9d9d9dyou |r" .. N.LevelText(lo, hi, mine) end
    local kills = N.KillCount(inst)
    head = head .. "  |cff9d9d9d" .. kills .. "/" .. #inst.bosses .. "|r"
    rows[#rows + 1] = { kind = "header", text = head, tip = {
        { inst.name, 1, 1, 1 },
        { (inst.zone or "") .. (inst.min and ("  -  enter from level " .. inst.min) or ""), 0.8, 0.8, 0.8 },
        inst.faction and { inst.faction, 0.8, 0.8, 0.8 } or nil,
        inst.note and { inst.note, 0.6, 0.6, 0.6 } or nil,
        { "Click: collapse or expand", 0.6, 0.6, 0.6 } } }
    if ctx.collapsed then return rows end

    if #ctx.party > 0 then
        local parts = {}
        for _, l in ipairs(ctx.party) do parts[#parts + 1] = l > 0 and N.LevelText(lo, hi, l) or "|cff9d9d9d?|r" end
        rows[#rows + 1] = { kind = "party", text = "|cff9d9d9dparty|r " .. table.concat(parts, " ") }
    end

    local lastWing
    for _, boss in ipairs(inst.bosses) do
        if boss.wing and boss.wing ~= lastWing then
            lastWing = boss.wing
            local w = N.WingInfo(inst, boss.wing)
            local txt = "|cffa0a0a0" .. boss.wing .. (w and w.lo and ("  " .. N.Range(w.lo, w.hi)) or "") .. "|r"
            rows[#rows + 1] = { kind = "wing", text = txt }
        end
        local killed = N.IsKilled(inst, boss)
        local lvl = boss.level and (boss.level > 0 and tostring(boss.level) or "??") or ""
        local name = killed and ("|cff808080" .. boss.name .. "|r") or boss.name
        rows[#rows + 1] = { kind = "boss", boss = boss, checked = killed,
            text = name .. (lvl ~= "" and ("  |cff9d9d9d" .. lvl .. "|r") or ""),
            tip = N.BossTip(boss, ctx) }
    end

    local loot = N.LootForYou(inst, ctx.class, ctx.level)
    rows[#rows + 1] = { kind = "lootHead", text = (ctx.lootOpen and "[-] " or "[+] ") .. "|cffffd100Loot for you|r  |cff9d9d9d" .. #loot .. "|r",
        tip = { { "Loot for you", 1, 1, 1 },
            { "Notable loot your class can use (armor type, weapons, stats).", 0.8, 0.8, 0.8 },
            { "Click: open or close the list", 0.6, 0.6, 0.6 } } }
    if ctx.lootOpen then
        for i, it in ipairs(loot) do
            if i > MAX_LOOT_ROWS then
                rows[#rows + 1] = { kind = "more", text = "|cff9d9d9d+" .. (#loot - MAX_LOOT_ROWS) .. " more: /ggf info|r" }
                break
            end
            local c = N.QColor(it.q)
            rows[#rows + 1] = { kind = "loot", item = it,
                text = "|cff" .. c[4] .. it.name .. "|r  |cff9d9d9d" .. it.slot .. "|r",
                tip = { { it.name, c[1], c[2], c[3] },
                    { it.slot .. (it.type and (", " .. it.type) or ""), 0.8, 0.8, 0.8 },
                    it.stats ~= "" and { it.stats, 0.8, 0.8, 0.8 } or nil,
                    { "Drops from " .. it.boss.name, 0.6, 0.6, 0.6 } } }
        end
    end
    return rows
end

-- Plain text lines for the /ggf info window (everything, no row limit).
function N.TextLines(inst, ctx)
    local lines = {}
    local ctx2 = {}
    for k, v in pairs(ctx) do ctx2[k] = v end
    ctx2.collapsed, ctx2.lootOpen = false, false
    lines[#lines + 1] = "|cffffd100" .. inst.name .. "|r  " .. (inst.zone or "")
    local sub = "Levels " .. N.Range(inst.lo, inst.hi) .. (inst.min and ("  -  enter from " .. inst.min) or "")
    if ctx.level then sub = sub .. "  -  you " .. N.LevelText(inst.lo, inst.hi, ctx.level) end
    lines[#lines + 1] = sub
    if inst.faction then lines[#lines + 1] = "|cff9d9d9d" .. inst.faction .. "|r" end
    if inst.note then lines[#lines + 1] = "|cff9d9d9d" .. inst.note .. "|r" end
    if #ctx.party > 0 then
        local parts = {}
        for _, l in ipairs(ctx.party) do parts[#parts + 1] = l > 0 and N.LevelText(inst.lo, inst.hi, l) or "?" end
        lines[#lines + 1] = "Party: " .. table.concat(parts, " ")
    end
    lines[#lines + 1] = " "
    lines[#lines + 1] = "|cffffd100Bosses|r"
    local lastWing
    for _, b in ipairs(inst.bosses) do
        if b.wing and b.wing ~= lastWing then
            lastWing = b.wing
            local w = N.WingInfo(inst, b.wing)
            lines[#lines + 1] = "|cffa0a0a0" .. b.wing .. (w and w.lo and ("  " .. N.Range(w.lo, w.hi)) or "") .. "|r"
        end
        lines[#lines + 1] = "  " .. b.name .. (b.level and ("  |cff9d9d9d" .. (b.level > 0 and b.level or "??") .. "|r") or "")
            .. (b.tip and ("  |cff9d9d9d- " .. b.tip .. "|r") or "")
    end
    local loot = N.LootForYou(inst, ctx.class, ctx.level)
    lines[#lines + 1] = " "
    lines[#lines + 1] = "|cffffd100Loot for you|r  (" .. (ctx.class and ctx.class:lower() or "any class")
        .. (ctx.level and (", level " .. ctx.level) or "") .. ")"
    if #loot == 0 then lines[#lines + 1] = "  none listed" end
    for _, it in ipairs(loot) do
        local c = N.QColor(it.q)
        lines[#lines + 1] = "  |cff" .. c[4] .. it.name .. "|r  |cff9d9d9d" .. it.slot .. (it.type and (", " .. it.type) or "")
            .. (it.stats ~= "" and (", " .. it.stats) or "") .. " - " .. it.boss.name .. "|r"
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- Detecting the instance
-- ---------------------------------------------------------------------------

function N.Detect()
    if type(_G.GetInstanceInfo) ~= "function" then return nil end
    local ok, name, itype = pcall(_G.GetInstanceInfo)
    if not ok or type(name) ~= "string" or IsSecret(name) then return nil end
    if type(itype) == "string" and not IsSecret(itype) and itype ~= "party" then return nil end
    return (N.FindExact(name))
end

function N.Update()
    local inst = N.Detect()
    if inst ~= N.cur then
        N.cur = inst
        if inst and M.db then N.Run(inst) end
    end
    if N.cur then N.view = nil end
    M.Safe("instrefresh", M.Refresh)
end

-- ---------------------------------------------------------------------------
-- The dock panel
-- ---------------------------------------------------------------------------

local frame
local rowFrames = {}

function N.Enabled() return M.db and M.db.instInfo ~= false end

function N.Shown() return N.view or N.cur end

function N.Wanted()
    return N.Enabled() and M.db.instOpen ~= false and N.Shown() ~= nil
end

local function ShowTip(row)
    local d = row.desc
    if not d or not d.tip or not _G.GameTooltip then return end
    local tip = _G.GameTooltip
    tip:SetOwner(row, "ANCHOR_RIGHT")
    local first = true
    for _, l in ipairs(d.tip) do
        if first then tip:SetText(l[1], l[2], l[3], l[4]); first = false
        else tip:AddLine(l[1], l[2], l[3], l[4], true) end
    end
    tip:Show()
end

local function OnRowClick(row)
    local d, inst = row.desc, N.Shown()
    if not d or not inst or not M.db then return end
    if d.kind == "header" then
        M.db.instCollapsed = not M.db.instCollapsed
    elseif d.kind == "lootHead" then
        M.db.instLoot = not M.db.instLoot
    elseif d.kind == "boss" then
        N.SetKilled(inst, d.boss, not N.IsKilled(inst, d.boss))
    else
        return
    end
    M.Refresh()
end

local function EnsureFrame()
    if frame or not M.bar then return frame end
    frame = M.NewInset("GaarGroupForeverInfo", M.bar)
    return frame
end

local function GetRow(i)
    local r = rowFrames[i]
    if r then return r end
    r = _G.CreateFrame("Button", nil, frame)
    r:SetHeight(ROWH)
    r:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -(2 + (i - 1) * ROWH))
    r:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -(2 + (i - 1) * ROWH))
    r:RegisterForClicks("LeftButtonUp")
    local hot = r:CreateTexture(nil, "HIGHLIGHT")
    hot:SetAllPoints()
    hot:SetColorTexture(1, 1, 1, 0.1)
    r.check = r:CreateTexture(nil, "ARTWORK")
    r.check:SetSize(ROWH - 2, ROWH - 2)
    r.check:SetPoint("LEFT", r, "LEFT", 3, 0)
    r.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.text:SetPoint("LEFT", r, "LEFT", 4, 0)
    r.text:SetPoint("RIGHT", r, "RIGHT", -2, 0)
    r.text:SetJustifyH("LEFT")
    pcall(r.text.SetWordWrap, r.text, false)
    r:SetScript("OnClick", function(self) M.Safe("instclick", OnRowClick, self) end)
    r:SetScript("OnEnter", function(self) M.Safe("insttip", ShowTip, self) end)
    r:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    rowFrames[i] = r
    return r
end

local function Render(list)
    for i, d in ipairs(list) do
        local r = GetRow(i)
        r.desc = d
        r.text:SetText(d.text)
        r.text:ClearAllPoints()
        if d.kind == "boss" then
            r.text:SetPoint("LEFT", r, "LEFT", ROWH + 4, 0)
            r.check:Show()
            r.check:SetDesaturated(not d.checked)
            r.check:SetAlpha(d.checked and 1 or 0.25)
        elseif d.kind == "loot" or d.kind == "party" or d.kind == "more" or d.kind == "wing" then
            r.text:SetPoint("LEFT", r, "LEFT", 10, 0)
            r.check:Hide()
        else
            r.text:SetPoint("LEFT", r, "LEFT", 4, 0)
            r.check:Hide()
        end
        r.text:SetPoint("RIGHT", r, "RIGHT", -2, 0)
        r:Show()
    end
    for i = #list + 1, #rowFrames do
        rowFrames[i].desc = nil
        rowFrames[i]:Hide()
    end
end

local function PanelHeight()
    if not N.Wanted() or not EnsureFrame() then return nil end
    local list = N.Rows(N.Shown(), N.Ctx())
    Render(list)
    return #list * ROWH + 4
end

M.Dock.AddPanel({ getFrame = EnsureFrame, height = PanelHeight })

function N.SetEnabled(v)
    M.db.instInfo = v and true or false
    M.Refresh()
end

function N.ToggleOpen()
    if not N.Shown() then
        M.Print("not in a known dungeon. /ggf info <name> shows any instance (try /ggf info list).")
        return
    end
    M.db.instOpen = M.db.instOpen == false
    if M.db.instOpen == false then N.view = nil end
    M.Refresh()
end

M.Dock.AddButton({ key = "Info", text = "Info", opt = "instInfo",
    click = N.ToggleOpen,
    active = function() return N.Wanted() end,
    tip = { "Instance info", "Shows or hides the dungeon panel: recommended levels, bosses (ticked as they die) and loot for your class." } })

-- ---------------------------------------------------------------------------
-- /ggf info
-- ---------------------------------------------------------------------------

local win

function N.ShowWindow(inst)
    if not win then
        win = M.UI.Window("GaarGroupForeverInstInfo", "Instance info", 380)
    end
    win.SetLines(N.TextLines(inst, N.Ctx()))
    win.Show()
end

function N.Names()
    local list = {}
    for _, inst in ipairs(N.Data()) do list[#list + 1] = inst.name end
    return table.concat(list, ", ")
end

function N.Slash(arg)
    arg = arg or ""
    local low = arg:lower()
    if low == "on" or low == "off" then
        N.SetEnabled(low == "on")
        M.Print("instance info " .. (low == "on" and "on." or "off."))
    elseif low == "list" then
        M.Print(N.Names())
    else
        local inst, wing
        if arg == "" then inst = N.cur else inst, wing = N.Find(arg) end
        if not inst then
            M.Print(arg == "" and "not in a known dungeon. /ggf info <name> (e.g. deadmines, brd, strat), /ggf info list"
                or ("no instance matches '" .. arg .. "'. /ggf info list"))
            return
        end
        if inst ~= N.cur then N.view = inst; if M.db then M.db.instOpen = true end end
        N.ShowWindow(inst)
        M.Safe("instrefresh", M.Refresh)
    end
end

M.Slash.info = N.Slash

M.MenuParts[#M.MenuParts + 1] = function()
    return {
        { text = "Show instance info", checkbox = true,
          checked = function() return M.db.instInfo ~= false end, func = function() N.SetEnabled(M.db.instInfo == false) end },
    }
end

M.HelpParts[#M.HelpParts + 1] = function()
    return { "/ggf info [name] - dungeon info (levels, bosses, loot for your class); /ggf info list | on | off" }
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- The boss of inst a chat line names ("Gilnid dies.", "You have slain Gilnid!"), or nil. Whole words of the
-- normalised boss name inside the normalised line; longest name first ("Mr. Smite" before "Smite").
function N.BossInText(inst, text)
    if not inst or type(text) ~= "string" or IsSecret(text) then return nil end
    local line = " " .. N.Norm(text) .. " "
    local best, bestLen = nil, 0
    for _, b in ipairs(inst.bosses) do
        local bn = N.Norm(b.name)
        if #bn > bestLen and line:find(" " .. bn .. " ", 1, true) then best, bestLen = b, #bn end
    end
    return best
end

-- Fallback for bosses without ENCOUNTER_END / BOSS_KILL: the hostile-death chat line.
function N.OnHostileDeath(text)
    local inst = N.cur
    local b = N.BossInText(inst, text)
    if b and not N.IsKilled(inst, b) then N.SetKilled(inst, b, true) end
    return b
end

function N.OnEvent(_, event, a1, a2, a3, a4, a5)
    local ok, err = pcall(function()
        if not M.db then return end
        if event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
            N.OnHostileDeath(a1)
        elseif event == "ENCOUNTER_END" then
            -- encounterID, name, difficultyID, groupSize, success
            if a5 == 1 and type(a2) == "string" and not IsSecret(a2) then N.MarkKilled(a2) end
        elseif event == "BOSS_KILL" then
            if type(a2) == "string" and not IsSecret(a2) then N.MarkKilled(a2) end
        else
            N.Update()
        end
    end)
    if not ok then M.Fail("inst " .. tostring(event), err) end
end

local ev = _G.CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE", "PLAYER_LEVEL_UP",
    "ENCOUNTER_END", "BOSS_KILL", "CHAT_MSG_COMBAT_HOSTILE_DEATH" }) do
    M.RegisterEvent(ev, e)
end
ev:SetScript("OnEvent", N.OnEvent)
