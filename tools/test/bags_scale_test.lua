-- LuaJIT test: GaarBagsForever bag window scale helpers.
-- Run: luajit tools/test/bags_scale_test.lua   (from the repo root)
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end
local ns = {}
assert(loadfile("addons/GaarBagsForever/BagScale.lua"))("GaarBagsForever", ns)
local S = ns.BagScale
eq(S.FromPercent("120"), 1.2, "120"); eq(S.FromPercent("120%"), 1.2, "120%"); eq(S.FromPercent(50), 0.5, "min")
eq(S.FromPercent(200), 2, "max"); eq(S.FromPercent(49), nil, "below"); eq(S.FromPercent(201), nil, "above")
eq(S.FromPercent("abc"), nil, "junk"); eq(S.FromPercent(nil), nil, "nil")
eq(S.ToPercent(1.1), 110, "to percent"); eq(S.Sanitize("x"), 1, "sanitize junk"); eq(S.Sanitize(3), 1, "sanitize range"); eq(S.Sanitize(0.8), 0.8, "keep")
local f = { s = 0.9, GetScale = function(self) return self.s end, SetScale = function(self, v) self.s = v end }
eq(S.Needs(f, 1), false, "100% untouched: nothing to do")
eq(S.Needs(f, 1.2), true, "needs change")
S.Apply(f, 1.2); eq(f.s, 1.2, "scaled"); eq(S.Needs(f, 1.2), false, "done")
eq(S.Needs(f, 1), true, "back to 100% needs restore")
S.Apply(f, 1); eq(f.s, 0.9, "restored Blizzard's own scale"); eq(S.scaled, false, "flag cleared")
eq(S.applying, false, "applying flag clear")
if fails == 0 then print("bags_scale_test: ok") else os.exit(1) end
