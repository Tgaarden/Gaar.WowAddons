-- LuaJIT stub test: GaarMapsForever zone level range falls back to C_Map.GetMapLevels for zones missing from the table.
-- Run: luajit tools/test/maps_levels_fallback_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarMapsForever/GaarMapsForever.lua")); local src = fh:read("*a"); fh:close()
local a = assert(src:find("ZL.apiCache, ZL.gaps = {}, {}", 1, true))
local b = assert(src:find("function ZL.Colored", 1, true))
local code = "local ZL = {}\nlocal ns = ...\nlocal function SafeString(v) return type(v)=='string' and v or nil end\n"
    .. "local function Num(v) return type(v)=='number' and v or nil end\n" .. src:sub(a, b - 1) .. "\nreturn ZL"
local infos = { [2548] = { name = "Riverglades", mapType = 3 }, [9001] = { name = "Zero", mapType = 3 },
    [9002] = { name = "Cont", mapType = 2 }, [1434] = { name = "Stranglethorn Vale", mapType = 3 } }
local levels = { [2548] = { 40, 50 }, [9001] = { 0, 0 }, [9002] = { 1, 60 } }
local calls = 0
local G = setmetatable({}, { __index = _G })
G.C_Map = { GetMapInfo = function(id) return infos[id] end,
    GetMapLevels = function(id) calls = calls + 1; local l = levels[id]; if l then return l[1], l[2] end end }
local ns = { zoneLevels = { byId = { [1434] = { 30, 45 } }, byName = {} } }
local f = assert(loadstring(code, "zl")); setfenv(f, G)
local ZL = f(ns)
local fails = 0
local function eq(n, got, want) if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end end
local lo, hi, s = ZL.Range(1434, "x", 3); eq("table", lo .. "-" .. hi .. s, "30-45id")
lo, hi, s = ZL.Range(2548, nil, 3); eq("api", lo .. "-" .. hi .. s, "40-50api")
ZL.Range(2548, nil, 3); eq("cached", calls, 1)
eq("zero gives none", ZL.Range(9001, "Zero", 3), nil)
eq("continent in world view none", ZL.Range(9002, "Cont", 1), nil)
eq("unknown id none", ZL.Range(5, "?", 3), nil)
eq("gap listed", ZL.gaps[9001] ~= nil, true)
eq("no GetMapLevels ok", (function() G.C_Map.GetMapLevels = nil; return ZL.Range(777, "n", 3) end)(), nil)
if fails == 0 then print("maps_levels_fallback_test: ok") else os.exit(1) end
