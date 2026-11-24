-- LuaJIT stub test: GaarFishingForever 1.7 test mode - the session panel with made-up numbers shows without a
-- pole or a cast, never touches the real session, and is not saved.
-- Run: luajit tools/test/fishing_stats_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarFishingForever/Stats.lua")); local src = fh:read("*a"); fh:close()
local fails = 0
local function eq(n, got, want) if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end end
local function has(n, s, pat) if not tostring(s):find(pat, 1, true) then fails = fails + 1; print("FAIL " .. n .. ": '" .. tostring(s) .. "' lacks '" .. pat .. "'") end end
local noop = function() end
local all = {}
local function widget()
    local w
    w = setmetatable({ shown = false, txt = "" }, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
    w.Show = function(self) self.shown = true end
    w.Hide = function(self) self.shown = false end
    w.SetText = function(self, t) self.txt = t end
    w.GetStringHeight = function() return 36 end
    w.GetStringWidth = function() return 100 end
    w.CreateFontString = function() return widget() end
    w.CreateTexture = function() return widget() end
    all[#all + 1] = w
    return w
end
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
local prints = {}
G.GaarForever = {
    NewAddon = function() return { Print = function(_, m) prints[#prints + 1] = m end } end,
    IsSecret = function() return false end,
    Num = function(v) return type(v) == "number" and v or nil end,
    Str = function(v) return type(v) == "string" and v or nil end,
    Call = function(f, ...) if type(f) == "function" then return f(...) end end,
    Clock = function(s) return string.format("%d:%02d", s / 60, s % 60) end,
}
local panels = {}
G.CreateFrame = function() local w = widget(); panels[#panels + 1] = w; return w end
G.UIParent = widget(); G.GameTooltip = widget()
G.time = function() return 1000000 end
G.GetTime = function() return 5000 end
local ns = { core = { PoleEquipped = function() return false end } }
local chunk = assert(loadstring(src, "stats")); setfenv(chunk, G); chunk("GaarFishingForever", ns)
local stats = ns.stats
local db, charDb = { stats = true }, {}
stats.Bind(db, charDb)

stats.Refresh()
eq("only the event frame before anything shows", #panels, 1)
stats.SetTest(true, true)
eq("test on", stats.IsTest(), true)
local panel = panels[2]
eq("panel shown without a pole", panel and panel.shown, true)
local text = ""
for _, w in ipairs(all) do if w.txt:find("Casts", 1, true) then text = w.txt end end
has("made-up casts and catches", text, "Casts 32")
has("made-up session clock", text, "Session 25:00")
has("status marks test", stats.StatusLines()[1], "(test mode)")
eq("real session untouched", charDb.session == nil or (charDb.session.casts == 0 and charDb.session.start == nil), true)
eq("setting untouched", db.stats, true)
eq("db intact", next(db, nil) ~= nil, true)
stats.SetTest(false, true)
eq("panel hidden again without a pole", panel.shown, false)
eq("still no real session", charDb.session == nil or charDb.session.casts == 0, true)
stats.SetOn(false, true); stats.SetTest(true, true)
eq("test shows even with the panel setting off", panel.shown, true)
stats.SetTest(false, true)
has("help line", stats.HelpLines()[1], "/gfish test")

if fails == 0 then print("fishing_stats_test: ok") else os.exit(1) end
