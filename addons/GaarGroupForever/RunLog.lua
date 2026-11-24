--[[
  GaarGroupForever - RunLog.lua: the dungeon run log, per character.

  A run starts when you enter a dungeon (instance type "party") and ends when you leave it for good:
  leaving and coming back to the SAME instance within 10 minutes (releasing at the graveyard
  outside, then running back) is the same run. Per run it records: instance name, how long it
  took, deaths in the party (polled once a second from UnitIsDeadOrGhost - the combat log is not
  used, 12.x restricts it), wipes (everyone in the group dead at once), XP gained (UnitXP deltas)
  and the loot you received (CHAT_MSG_LOOT, your own lines only).

  /ggf log shows the last 20 runs; /ggf log clear (or the window's Clear button, which asks twice)
  empties the log. Saved per character in GaarGroupForeverCharDB.runs (newest first, 50 kept); the
  run in progress in .runcur, so a /reload does not lose it.

  Secret values (in combat) are never compared: an unreadable event line or value is skipped.
]]

local _G = _G
local API = _G.GaarGroupForeverAPI
local M = API and API._M
if not M then return end

local BF = _G.GaarForever
local IsSecret = BF.IsSecret

M.Defaults.runlog = true

local R = { dead = {}, wiped = false, lastXP = nil, lastXPMax = nil }
M.RunLog = R

R.GRACE = 600    -- seconds you may be outside before the run counts as ended
R.KEEP = 50      -- runs stored
R.SHOW = 20      -- runs shown
R.MAXLOOT = 60   -- loot entries kept per run

function R.Now()
    local f = _G.GetServerTime
    if type(f) == "function" then
        local ok, t = pcall(f)
        if ok and type(t) == "number" then return t end
    end
    return os.time()
end

function R.Cur() return M.cdb and M.cdb.runcur end
function R.Runs()
    if not M.cdb then return {} end
    if type(M.cdb.runs) ~= "table" then M.cdb.runs = {} end
    return M.cdb.runs
end

function R.Enabled() return M.db and M.db.runlog ~= false end

-- Ends the current run at time `when` and files it.
function R.Finish(cur, when)
    local runs = R.Runs()
    local rec = { name = cur.name, id = cur.id, start = cur.start, duration = math.max(0, (when or R.Now()) - cur.start),
        deaths = cur.deaths or 0, selfDeaths = cur.selfDeaths or 0, wipes = cur.wipes or 0, xp = cur.xp or 0,
        loot = cur.loot or {} }
    table.insert(runs, 1, rec)
    while #runs > R.KEEP do table.remove(runs) end
    M.cdb.runcur = nil
    R.dead, R.wiped = {}, false
    return rec
end

function R.Start(name, id, now)
    M.cdb.runcur = { name = name, id = id, start = now, deaths = 0, selfDeaths = 0, wipes = 0, xp = 0, loot = {} }
    R.dead, R.wiped = {}, false
    return M.cdb.runcur
end

-- info: { type = instance type, name, id }. Call on every zone change / login. Returns
-- "started" / "resumed" / "left" / "finished" / nil, for tests and /ggf status.
function R.Sync(info, now)
    if not M.cdb then return nil end
    now = now or R.Now()
    local result
    local cur = R.Cur()
    if cur and cur.leftAt and now - cur.leftAt > R.GRACE then
        R.Finish(cur, cur.leftAt)
        cur, result = nil, "finished"
    end
    if info and info.type == "party" and info.name then
        if cur and cur.id == info.id and cur.name == info.name then
            if cur.leftAt then cur.leftAt = nil; result = "resumed" end
        else
            if cur then R.Finish(cur, cur.leftAt or now) end
            R.Start(info.name, info.id, now)
            result = "started"
        end
    elseif cur and not cur.leftAt then
        cur.leftAt = now
        result = "left"
    end
    return result
end

-- Poll deaths. states: { [unit] = true (dead) / false (alive) } for the units in the group.
-- A unit going from alive to dead is a death; every unit dead at once is a wipe (counted once
-- until someone is up again). Returns deaths added, wiped now.
function R.Poll(states)
    local cur = R.Cur()
    if not cur or cur.leftAt then return 0, false end
    local added, total, deadN = 0, 0, 0
    for unit, isDead in pairs(states) do
        total = total + 1
        if isDead then
            deadN = deadN + 1
            if not R.dead[unit] then
                added = added + 1
                cur.deaths = (cur.deaths or 0) + 1
                if unit == "player" then cur.selfDeaths = (cur.selfDeaths or 0) + 1 end
            end
        end
        R.dead[unit] = isDead and true or nil
    end
    local wiped = false
    if total > 0 and deadN == total then
        if not R.wiped then R.wiped = true; cur.wipes = (cur.wipes or 0) + 1; wiped = true end
    elseif deadN < total then
        R.wiped = false
    end
    return added, wiped
end

-- XP delta handling: a lower value means a level-up (the rest of the old bar plus the new xp).
function R.OnXP(xp, xpMax)
    if type(xp) ~= "number" or type(xpMax) ~= "number" then return 0 end
    local gain = 0
    if R.lastXP then
        if xp >= R.lastXP then gain = xp - R.lastXP
        else gain = math.max(0, (R.lastXPMax or xpMax) - R.lastXP) + xp end
    end
    R.lastXP, R.lastXPMax = xp, xpMax
    local cur = R.Cur()
    if gain > 0 and cur and not cur.leftAt then cur.xp = (cur.xp or 0) + gain end
    return gain
end

-- A game format string ("You receive loot: %s.") as a Lua pattern.
function R.FormatToPattern(fmt)
    local p = fmt:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
    p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
    return "^" .. p .. "$"
end

function R.LootPatterns()
    local list = {}
    local function add(global, hasCount)
        local fmt = _G[global]
        if type(fmt) == "string" then list[#list + 1] = { pattern = R.FormatToPattern(fmt), count = hasCount } end
    end
    add("LOOT_ITEM_SELF_MULTIPLE", true)
    add("LOOT_ITEM_PUSHED_SELF_MULTIPLE", true)
    add("LOOT_ITEM_SELF", false)
    add("LOOT_ITEM_PUSHED_SELF", false)
    return list
end

-- The item link and count in one of your own loot lines, or nil.
function R.ParseLoot(msg)
    if type(msg) ~= "string" or IsSecret(msg) then return nil end
    for _, e in ipairs(R.patterns or {}) do
        local a, b = msg:match(e.pattern)
        if a then return a, e.count and tonumber(b) or 1 end
    end
    return nil
end

function R.OnLoot(msg)
    local cur = R.Cur()
    if not cur or cur.leftAt then return end
    local link, count = R.ParseLoot(msg)
    if link and #cur.loot < R.MAXLOOT then cur.loot[#cur.loot + 1] = { link = link, count = count } end
end

function R.InstanceInfo()
    local inInst, itype = false, nil
    local ok, a, b = pcall(_G.IsInInstance or function() end)
    if ok and not IsSecret(a) and not IsSecret(b) then inInst, itype = a, b end
    if not inInst then return { type = "none" } end
    local ok2, name, _, _, _, _, _, _, id = pcall(_G.GetInstanceInfo)
    if not ok2 or IsSecret(name) or type(name) ~= "string" then return { type = itype } end
    if IsSecret(id) or type(id) ~= "number" then id = nil end
    return { type = itype, name = name, id = id }
end

function R.Check()
    if not R.Enabled() or not M.cdb then return end
    if not R.patterns then R.patterns = R.LootPatterns() end
    return R.Sync(R.InstanceInfo())
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------

function R.Duration(sec)
    sec = math.floor(sec or 0)
    local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function Line(r, live)
    local s = string.format("|cffffd100%s|r  %s  deaths %d  wipes %d  xp %d  loot %d",
        r.name or "?", R.Duration(r.duration), r.deaths or 0, r.wipes or 0, r.xp or 0, #(r.loot or {}))
    if live then s = s .. "  |cff40ff40(in progress)|r" end
    return s
end

local function LootLine(r)
    local shown, extra = {}, 0
    for _, e in ipairs(r.loot or {}) do
        local grey = type(e.link) == "string" and e.link:find("|cff9d9d9d", 1, true)
        if not grey then
            if #shown < 4 then shown[#shown + 1] = e.link .. (e.count > 1 and ("x" .. e.count) or "") else extra = extra + 1 end
        end
    end
    if #shown == 0 then return nil end
    return "    " .. table.concat(shown, " ") .. (extra > 0 and (" +" .. extra) or "")
end

function R.Lines()
    R.Check() -- close a stale run first
    local lines = {}
    local cur = R.Cur()
    if cur then
        local live = { name = cur.name, duration = R.Now() - cur.start, deaths = cur.deaths, wipes = cur.wipes,
            xp = cur.xp, loot = cur.loot }
        lines[#lines + 1] = Line(live, not cur.leftAt)
        local l = LootLine(live)
        if l then lines[#lines + 1] = l end
    end
    for i, r in ipairs(R.Runs()) do
        if i > R.SHOW then break end
        lines[#lines + 1] = Line(r)
        local l = LootLine(r)
        if l then lines[#lines + 1] = l end
    end
    if #lines == 0 then lines[1] = "No dungeon runs recorded yet." end
    return lines
end

function R.Clear()
    if M.cdb then M.cdb.runs = {} end
end

function R.Open()
    if not R.win then
        local w = M.UI.Window("GaarGroupForeverRunLog", "Dungeon run log", 440)
        w.AddButton("Refresh", function() R.Refresh() end)
        local clear
        local armed = false
        clear = w.AddButton("Clear", function()
            if not armed then
                armed = true
                clear:SetText("Sure?")
                if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(4, function() armed = false; clear:SetText("Clear") end) end
            else
                armed = false
                clear:SetText("Clear")
                R.Clear(); R.Refresh()
            end
        end)
        R.win = w
    end
    R.Refresh()
    R.win.Show()
end

function R.Refresh()
    if R.win then R.win.SetLines(R.Lines()) end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function R.OnEvent(_, event, arg1)
    if not M.cdb or not R.Enabled() then return end
    local ok, err = pcall(function()
        if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
            R.Check()
            local xp, mx = M.Q(_G.UnitXP, "player"), M.Q(_G.UnitXPMax, "player")
            if type(xp) == "number" and type(mx) == "number" then R.lastXP, R.lastXPMax = xp, mx end
        elseif event == "PLAYER_XP_UPDATE" then
            R.OnXP(M.Q(_G.UnitXP, "player"), M.Q(_G.UnitXPMax, "player"))
        elseif event == "CHAT_MSG_LOOT" then
            R.OnLoot(arg1)
        end
    end)
    if not ok then M.Fail("runlog " .. tostring(event), err) end
end

function R.Tick()
    local cur = R.Cur()
    if not cur or cur.leftAt or not R.Enabled() then return end
    local states = {}
    for _, unit in ipairs({ "player", "party1", "party2", "party3", "party4" }) do
        if unit == "player" or M.Q(_G.UnitExists, unit) then
            local d = M.Q(_G.UnitIsDeadOrGhost, unit)
            if d ~= nil then states[unit] = d and true or false end
        end
    end
    R.Poll(states)
end

do
    local f = _G.CreateFrame("Frame")
    for _, ev in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_XP_UPDATE", "CHAT_MSG_LOOT" }) do
        pcall(f.RegisterEvent, f, ev)
    end
    f:SetScript("OnEvent", R.OnEvent)
    local acc = 0
    f:SetScript("OnUpdate", function(_, dt)
        acc = acc + (type(dt) == "number" and dt or 0)
        if acc < 1 then return end
        acc = 0
        if M.cdb then M.Safe("runlog tick", R.Tick) end
    end)
end

-- ---------------------------------------------------------------------------
-- Dock button, menu, slash
-- ---------------------------------------------------------------------------

M.Dock.AddButton({ key = "Log", text = "Log", opt = "runlog", click = R.Open,
    tip = { "Dungeon run log", "Your last 20 dungeon runs: time, deaths, wipes, XP and loot." } })

M.MenuParts[#M.MenuParts + 1] = function()
    return {
        { text = "Record dungeon runs", checkbox = true,
          checked = function() return M.db.runlog ~= false end,
          func = function() M.db.runlog = M.db.runlog == false; M.Refresh() end },
        { text = "Show the run log", func = R.Open },
        { text = "Clear the run log", func = function() R.Clear(); R.Refresh(); M.Print("run log cleared.") end },
    }
end

M.Slash.log = function(arg)
    if arg == "clear" then
        R.Clear(); R.Refresh(); M.Print("run log cleared.")
    else
        R.Open()
    end
end

M.HelpParts[#M.HelpParts + 1] = function()
    return { "/ggf log - the last 20 dungeon runs; /ggf log clear - empty the log (recording now "
        .. (M.db and M.db.runlog ~= false and "on" or "off") .. ")" }
end
