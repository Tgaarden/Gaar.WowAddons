-- LuaJIT stub test: GaarFramesForever 1.7.0 - PvP flag timer text and flag state.
-- Run: luajit tools/test/frames_pvp_test.lua   (from the repo root)
local path = "addons/GaarFramesForever/GaarFramesForever.lua"
local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { Pvp = Look.Pvp, UpdatePvp = Look.Pvp.Update, SetDb = function(d) db = d end }\n"
local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end,
    __lt = function() error("compared a secret") end, __le = function() error("compared a secret") end,
    __eq = nil })
local function IsSecret(v) return v == SECRET end
G.GaarForever = {
    NewAddon = function() return setmetatable({}, { __index = function() return noop end }) end,
    OnOff = tostring, ShortNumber = tostring, InCombat = function() return false end, IsSecret = IsSecret,
    Plain = function(v) if IsSecret(v) then return nil end return v end,
    Num = function(v) if IsSecret(v) or type(v) ~= "number" then return nil end return v end,
}
G.CreateFrame = widget
G.SlashCmdList = {}
G.GaarFramesForeverDB = {}
G.GameTooltip = widget(); G.UIParent = widget()
local f = loadstring(src, "@GFF"); setfenv(f, G)
assert(pcall(f, "GaarFramesForever", {}))
local P, T = G.__T.Pvp, G.__T

local fails = 0
local function eq(name, got, want)
    local ok = got == want
    print(string.format("%-34s got %s want %s  %s", name, tostring(got), tostring(want), ok and "ok" or "FAIL"))
    if not ok then fails = fails + 1 end
end
eq("300000 -> 5:00", P.Format(300000), "5:00")
eq("299500 -> 5:00 (ceil)", P.Format(299500), "5:00")
eq("65000 -> 1:05", P.Format(65000), "1:05")
eq("9000 -> 0:09", P.Format(9000), "0:09")
eq("1 -> 0:01", P.Format(1), "0:01")
eq("0 -> nil", P.Format(0), nil)
eq("-5 -> nil", P.Format(-5), nil)
eq("301000 -> nil", P.Format(301000), nil)
eq("huge -> nil", P.Format(4e9), nil)
eq("nil -> nil", P.Format(nil), nil)
eq("secret -> nil", P.Format(SECRET), nil)

-- timer read, with IsPVPTimerRunning
G.GetPVPTimer = function() return 120000 end
G.IsPVPTimerRunning = function() return true end
eq("running -> 2:00", P.TimerText(), "2:00")
G.IsPVPTimerRunning = function() return false end
eq("not running -> nil", P.TimerText(), nil)
G.IsPVPTimerRunning = nil
eq("no IsPVPTimerRunning -> 2:00", P.TimerText(), "2:00")
G.GetPVPTimer = function() return 301000 end
eq("301000 sentinel -> nil", P.TimerText(), nil)
G.GetPVPTimer = function() return SECRET end
eq("secret timer -> nil", P.TimerText(), nil)

-- flag state
local pvp, ffa, fac = true, false, "Horde"
G.UnitIsPVP = function() return pvp end
G.UnitIsPVPFreeForAll = function() return ffa end
G.UnitFactionGroup = function() return fac end
eq("flagged Horde", P.Kind("target"), "Horde")
fac = "Alliance"; eq("flagged Alliance", P.Kind("target"), "Alliance")
ffa = true; eq("ffa", P.Kind("target"), "ffa"); ffa = false
pvp = false; eq("not flagged", P.Kind("target"), false)
pvp = SECRET; eq("secret flag -> unknown", P.Kind("target"), nil)
pvp = true; fac = SECRET; eq("secret faction -> unknown", P.Kind("target"), nil)

-- frame behaviour: secret keeps the last state; option off hides
local function fr(player)
    local fobj = { unit = "player", pvpIcon = widget() }
    fobj.pvpIcon.shown = false
    fobj.pvpIcon.Show = function(s) s.shown = true end
    fobj.pvpIcon.Hide = function(s) s.shown = false end
    if player then
        fobj.pvpTimer = widget()
        fobj.pvpTimer.SetText = function(s, v) s.text = v end
        fobj.pvpTimer.Show = function(s) s.shown = true end
        fobj.pvpTimer.Hide = function(s) s.shown = false end
    end
    return fobj
end
T.SetDb({ pvpFlag = true })
fac = "Horde"; pvp = true; G.GetPVPTimer = function() return 61000 end
local p = fr(true)
T.UpdatePvp(p)
eq("icon shown", p.pvpIcon.shown, true); eq("timer text", p.pvpTimer.text, "1:01"); eq("ticking", p.pvpTicking, true)
pvp = SECRET; T.UpdatePvp(p)
eq("secret: icon kept", p.pvpIcon.shown, true)
pvp = false; G.GetPVPTimer = function() return 301000 end; T.UpdatePvp(p)
eq("unflagged: icon hidden", p.pvpIcon.shown, false); eq("unflagged: not ticking", p.pvpTicking, nil)
pvp = true; T.UpdatePvp(p)
eq("flagged, no timer: not ticking", p.pvpTicking, nil); eq("no timer: hidden", p.pvpTimer.shown, false)
T.SetDb({ pvpFlag = false }); T.UpdatePvp(p)
eq("option off: icon hidden", p.pvpIcon.shown, false)
print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
