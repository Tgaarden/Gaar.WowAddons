-- GaarGroupForever role modules: lost-aggro / loose / aggro / wrong-target / interrupt / marker logic, and the scan
-- with secret values.
local state = { roles = {} }
local G, M, R = dofile("tools/test/group_roles_helper.lua")(state)
local T, D = M.Tank, M.Dps
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

local items = {
    { name = "Wolf", onMe = true },
    { name = "Boar", onMe = false, victim = "party2" },
    { name = "Bat", onMe = false },
    { name = "Rat", onMe = nil },
}
eq(#T.LostAggro(items), 1, "lost aggro: only on a party member")
eq(T.LostAggro(items)[1].name, "Boar", "lost aggro mob")
eq(#T.Loose(items), 2, "loose: not on me, unknown skipped")
eq(#D.AggroOnMe(items), 1, "aggro on me")
eq(T.LooseText({}), nil, "no loose text")
eq(T.LooseText({ { name = "A" }, { name = "B" }, { name = "C" }, { name = "D" } }), "Loose (4): A, B, C, ...", "loose text")

-- markers
eq(T.NextMarker(0, false), 8, "skull first")
eq(T.NextMarker(nil, true), 7, "cross when skull out")
eq(T.NextMarker(8, false), nil, "already skull")
eq(T.NextMarker(0, true, "x"), 7, "forced cross")
eq(T.NextMarker(0, false, "x"), 7, "forced cross, no skull")
eq(T.NextMarker(7, false), 8, "cross target takes free skull")
eq(T.NextMarker(7, true), nil, "cross target, skull taken")
eq(T.NextMarker(7, false, "x"), nil, "already cross")

-- wrong target
eq(D.WrongTarget(true, 0, true, true), true, "wrong target")
eq(D.WrongTarget(true, 8, true, true), false, "on skull")
eq(D.WrongTarget(false, 0, true, true), false, "no skull out")
eq(D.WrongTarget(true, 0, false, true), false, "out of combat")
eq(D.WrongTarget(true, nil, true, true), false, "unreadable marker")
eq(D.WrongTarget(true, 0, true, false), false, "friendly target")

-- interrupt: parse both client generations
local newerCast = { "Fireball", "", 1, 1000, 2000, false, 77, false, 133 }
local olderCast = { "Fireball", "", "", 1, 1000, 2000, false, 77, false }
local n, f = D.ParseCast("cast", newerCast); eq(n, "Fireball", "newer name"); eq(f, false, "newer flag")
n, f = D.ParseCast("cast", olderCast); eq(f, false, "older flag")
eq(select(2, D.ParseCast("cast", { "X", "", 1, 1, 2, false, 7, true })), true, "newer not interruptible")
eq(select(2, D.ParseCast("channel", { "Drain", "", 1, 1000, 2000, false, false, 5 })), false, "newer channel")
eq(select(2, D.ParseCast("channel", { "Drain", "", "", 1, 1000, 2000, false, true })), true, "older channel")
eq(select(2, D.ParseCast("cast", { "X", "", 1, 1, 2, false, 7, G.SECRET })), nil, "secret flag")
eq(D.InterruptDue(false), true, "interruptible: alert")
eq(D.InterruptDue(true), false, "not interruptible: none")
eq(D.InterruptDue(nil), false, "unknown: none")

-- the scan: secret answers are unknown, never compared
G.UnitExists = function(u) return u == "nameplate1" or u == "nameplate2" or u == "party1" end
G.UnitCanAttack = function() return true end
G.UnitIsDeadOrGhost = function() return false end
G.UnitAffectingCombat = function() return true end
G.UnitGUID = function(u) return "G-" .. u end
G.UnitName = function(u) if u == "nameplate2" then return G.SECRET end return "Mob-" .. u end
G.UnitIsUnit = function(a, b)
    if a == "nameplate1target" then return b == "party1" end
    if a == "nameplate2target" then return G.SECRET end
    return false
end
R.scan = nil
local scan = R.Scan(1000)
eq(#scan, 2, "scan finds two mobs")
eq(scan[1].onMe, false, "mob 1 not on me")
eq(scan[1].victim, "party1", "mob 1 victim")
eq(scan[2].onMe, nil, "secret target = unknown")
eq(scan[2].name, nil, "secret name = nil")
eq(#T.LostAggro(scan), 1, "lost aggro with secret")
eq(#T.Loose(scan), 1, "loose skips the unknown")

if fails == 0 then print("group roles aggro/target logic: all ok") else os.exit(1) end
