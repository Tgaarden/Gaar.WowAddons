-- GaarGroupForever role modules: dispel-by-class matching (Healer.lua), drink names, range/dead steps, PvP flag rule.
local G, M = dofile("tools/test/group_roles_helper.lua")({})
local H = M.Healer
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

-- class kinds, no spell info: the whole class list
eq(H.CanDispel("PRIEST", "Magic"), true, "priest magic")
eq(H.CanDispel("PRIEST", "Disease"), true, "priest disease")
eq(H.CanDispel("PRIEST", "Poison"), false, "priest no poison")
eq(H.CanDispel("PRIEST", "Curse"), false, "priest no curse")
eq(H.CanDispel("PALADIN", "Magic"), true, "paladin magic")
eq(H.CanDispel("PALADIN", "Poison"), true, "paladin poison")
eq(H.CanDispel("PALADIN", "Curse"), false, "paladin no curse")
eq(H.CanDispel("DRUID", "Curse"), true, "druid curse")
eq(H.CanDispel("DRUID", "Poison"), true, "druid poison")
eq(H.CanDispel("DRUID", "Magic"), false, "druid no magic")
eq(H.CanDispel("SHAMAN", "Poison"), true, "shaman poison")
eq(H.CanDispel("SHAMAN", "Disease"), true, "shaman disease")
eq(H.CanDispel("SHAMAN", "Magic"), false, "shaman no magic")
eq(H.CanDispel("WARRIOR", "Magic"), false, "warrior none")

-- spells known: a paladin with only Purify has no Magic
local function knows(set) return function(id) return set[id] == true end end
eq(H.CanDispel("PALADIN", "Magic", knows({ [1152] = true })), false, "purify only: no magic")
eq(H.CanDispel("PALADIN", "Poison", knows({ [1152] = true })), true, "purify: poison")
eq(H.CanDispel("PALADIN", "Magic", knows({ [4987] = true })), true, "cleanse: magic")
eq(H.CanDispel("PRIEST", "Disease", knows({ [528] = true })), true, "cure disease")
eq(H.CanDispel("PRIEST", "Magic", knows({ [528] = true })), false, "no dispel magic yet")

-- removable kinds on a unit, stable order; text
local kinds = H.KindsFor("PRIEST")
local r = H.Removable(kinds, { "Poison", "Disease", "Magic" })
eq(table.concat(r, ","), "Magic,Disease", "removable order")
eq(#H.Removable(kinds, { "Curse" }), 0, "nothing removable")
eq(H.DispelText({}), nil, "empty text")
eq(H.DispelText({ { name = "Mira", kinds = { "Magic" } }, { name = "Bob", kinds = { "Poison", "Disease" } } }),
    "Dispel: Mira (Magic), Bob (Poison, Disease)", "dispel text")

-- drink names
eq(H.IsDrinkName("Drink"), true, "Drink")
eq(H.IsDrinkName("Refreshment"), true, "Refreshment")
eq(H.IsDrinkName("Food"), false, "Food is not drinking")
eq(H.IsDrinkName(nil), false, "nil name")

-- range / dead
eq(H.RangeState(false, true), "out", "out of range")
eq(H.RangeState(true, true), "in", "in range")
eq(H.RangeState(false, false), nil, "range not checked")
eq(H.RangeState(nil, true), nil, "range unknown")
local prev = {}
eq(H.MemberStep(prev, true, nil), "died", "death alert")
eq(H.MemberStep(prev, true, nil), nil, "death once")
eq(H.MemberStep(prev, false, "in"), nil, "alive again")
eq(H.MemberStep(prev, false, "out"), "out", "out alert")
eq(H.MemberStep(prev, false, "out"), nil, "out once")
eq(H.MemberStep(prev, nil, nil), nil, "unknown keeps state")

-- pvp flag rule
eq(H.PvpWarn(true, true, true, false), true, "flagged friend, me not")
eq(H.PvpWarn(true, true, true, true), false, "both flagged")
eq(H.PvpWarn(true, true, nil, false), false, "secret target flag")
eq(H.PvpWarn(true, true, true, nil), false, "unknown me")
eq(H.PvpWarn(false, true, true, false), false, "not a player")
eq(H.PvpWarn(true, false, true, false), false, "enemy")

-- auto-post steps
local st = {}
eq(H.OomStep(st, 50), nil, "oom ok")
eq(H.OomStep(st, 9), "post", "oom post")
eq(H.OomStep(st, 8), nil, "oom once")
eq(H.OomStep(st, 15), nil, "oom hysteresis")
eq(H.OomStep(st, 25), nil, "oom rearm")
eq(H.OomStep(st, 5), "post", "oom again")
eq(H.OomStep(st, nil), nil, "oom unknown")
local ds = {}
eq(H.DrinkStep(ds, false), nil, "not drinking")
eq(H.DrinkStep(ds, true), "post", "starts drinking")
eq(H.DrinkStep(ds, true), nil, "still drinking")
eq(H.DrinkStep(ds, nil), nil, "unknown")

if fails == 0 then print("group roles dispel/healer: all ok") else os.exit(1) end
