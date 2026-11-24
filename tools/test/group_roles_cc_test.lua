-- GaarGroupForever role modules: CC assignment (Dps.lua) and alert throttling (Roles.lua).
local state = { leader = { player = true }, roles = {}, unitByName = {} }
local G, M, R = dofile("tools/test/group_roles_helper.lua")(state)
local D = M.Dps
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

-- text and wire format
eq(D.CCText("MAGE", 5), "Sheep = Moon", "sheep = moon")
eq(D.CCText("ROGUE", 6), "Sap = Square", "sap")
eq(D.CCText("WARRIOR", 1), "CC = Star", "unknown class")
eq(D.CCText("MAGE", 8), nil, "no skull for CC")
eq(D.BuildCC("Mira", 5), "CC|Mira|5", "wire")
local n, i = D.ParseCC("CC|Mira|5"); eq(n, "Mira", "parse name"); eq(i, 5, "parse idx")
eq(D.ParseCC("CC|Mira|9"), nil, "bad idx")
eq(D.ParseCC("XX|Mira|5"), nil, "bad tag")
eq(D.ParseCC(nil), nil, "nil")

-- assigning: leader only, chat on the click, session store
local sent = {}
G.C_ChatInfo = { SendAddonMessage = function(p, m, c) sent[#sent + 1] = p .. ":" .. m .. ":" .. c end, RegisterAddonMessagePrefix = function() end }
eq(D.Assign("Mira", "MAGE", 5), true, "assign")
eq(D.cc.Mira, 5, "stored")
eq(state.chat[1], "PARTY:Sheep = Moon (Mira)", "announced on click")
eq(sent[1], "GGFcc:CC|Mira|5:PARTY", "addon message")
D.Assign("Mira", "MAGE", 0)
eq(D.cc.Mira, nil, "cleared")
eq(#state.chat, 1, "clearing says nothing")
state.leader = {}
eq(D.Assign("Bob", "ROGUE", 6), false, "non-leader cannot assign")
eq(D.cc.Bob, nil, "not stored")
eq(#state.chat, 1, "no chat from non-leader")

-- receiving: only from the leader
state.unitByName["Lead"] = "party1"; state.unitByName["Rando"] = "party2"
state.leader = { party1 = true }
D.OnAddon("GGFcc", "CC|Me Self|5", "PARTY", "Lead-Realm")
eq(D.cc["Me Self"], 5, "leader's assignment accepted")
eq(D.MyCC(), 5, "I see my marker")
D.OnAddon("GGFcc", "CC|Me Self|0", "PARTY", "Rando")
eq(D.MyCC(), 5, "non-leader ignored")
D.OnAddon("GGFcc", "CC|Me Self|0", "PARTY", "Lead")
eq(D.MyCC(), nil, "cleared by leader")
D.OnAddon("OTHER", "CC|Me Self|3", "PARTY", "Lead")
eq(D.MyCC(), nil, "other prefix ignored")

-- throttling
state.now = 100
R.last = {}; R.alerts = {}
eq(R.Alert("k", "one", { gap = 5 }), true, "first alert")
state.now = 102
eq(R.Alert("k", "two", { gap = 5 }), false, "throttled within gap")
state.now = 106
eq(R.Alert("k", "three", { gap = 5 }), true, "after the gap")
eq(R.Alert("a", "x", { gap = 5, group = "g", groupGap = 3 }), true, "group first")
eq(R.Alert("b", "y", { gap = 5, group = "g", groupGap = 3 }), false, "group throttled")
state.now = 110
eq(R.Alert("b", "y", { gap = 5, group = "g", groupGap = 3 }), true, "group free")
eq(R.Alert("c", "", { gap = 5 }), false, "empty text")
-- alerts expire; capped
state.now = 200
for i = 1, 6 do R.Alert("n" .. i, "t" .. i, { gap = 1, ttl = 4 }) end
eq(#R.alerts, R.MAX_ALERTS, "alert cap")
state.now = 210
eq(#R.Lines(210), 0, "alerts expire")
-- clock going backwards does not lock a key forever
R.last = { z = 500 }; state.now = 100
eq(R.Ready("z", 5, 100), true, "backwards clock allowed")
-- statuses
R.SetStatus("s", "hello"); eq(#R.Lines(), 1, "status shown")
R.SetStatus("s", nil); eq(#R.Lines(), 0, "status cleared")

if fails == 0 then print("group roles cc/alerts: all ok") else os.exit(1) end
