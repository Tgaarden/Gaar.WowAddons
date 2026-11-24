-- GaarGroupForever role modules: healer mana threshold (Tank.lua) and the mana read.
local state = {}
local G, M, R = dofile("tools/test/group_roles_helper.lua")(state)
local T = M.Tank
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

eq(T.ManaState(30, 40), "low", "30 < 40")
eq(T.ManaState(40, 40), "ok", "exactly threshold is ok")
eq(T.ManaState(90, 40), "ok", "90 ok")
eq(T.ManaState(nil, 40), nil, "unknown")
eq(T.ManaState(G.SECRET, 40), nil, "secret")
eq(T.ManaState(10, nil), "low", "default threshold 40")
eq((T.ManaText("Mira", 30, 40)), "Mira 30% mana - wait", "low text")
eq((T.ManaText("Mira", 71.4, 40)), "Mira mana 71%", "ok text")
eq(T.ManaText("Mira", nil, 40), nil, "no text when unknown")

-- the option default and storage
eq(R.Opt("tankManaPct"), 40, "default threshold")
eq(R.Opt("tankMana"), true, "mana option on by default")
eq(R.Opt("tankAnnounce"), false, "announce off by default")
eq(R.Opt("healAutoDrink"), false, "auto drink off by default")
eq(R.Opt("healAutoOom"), false, "auto oom off by default")
R.SetOpt("tankManaPct", 60); eq(R.Opt("tankManaPct"), 60, "threshold set")
R.SetOpt("tankMana", false); eq(R.Opt("tankMana"), false, "option off")
eq(M.db.roles.tankManaPct, 60, "saved in db.roles")

-- mana read: only mana users, plain numbers
G.UnitPowerType = function() return 0 end
G.UnitPower = function() return 300 end
G.UnitPowerMax = function() return 1000 end
eq(R.ManaPct("party1"), 30, "30 percent")
G.UnitPowerType = function() return 1 end
eq(R.ManaPct("party1"), nil, "rage user has no mana")
G.UnitPowerType = function() return 0 end
G.UnitPower = function() return G.SECRET end
eq(R.ManaPct("party1"), nil, "secret power")

-- the tick: out of combat shows the status; in combat clears it
G.UnitPower = function() return 300 end
G.UnitGroupRolesAssigned = function(u) return u == "party1" and "HEALER" or "NONE" end
G.UnitExists = function(u) return u == "party1" end
G.UnitName = function() return "Mira" end
G.UnitAffectingCombat = function() return false end
R.SetOpt("tankMana", true); R.SetOpt("tankManaPct", 40)
T.tick(500)
eq(R.status.tankMana and R.status.tankMana.text, "Mira 30% mana - wait", "status warns")
state.combat = true
T.tick(501)
eq(R.status.tankMana, nil, "no mana status in combat")

if fails == 0 then print("group roles mana: all ok") else os.exit(1) end
