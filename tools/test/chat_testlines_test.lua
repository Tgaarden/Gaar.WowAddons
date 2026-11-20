-- LuaJIT stub test: /gchat test adds sample lines to the main chat frame through AddMessage, runs
-- them through the short-channel, class-colour and URL formatting, and never sends chat.
-- Run: luajit tools/test/chat_testlines_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarChatForever/GaarChatForever.lua")); local src = fh:read("*a"); fh:close()
local noop = function() end
local fails = 0
local function eq(n, got, want) if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end end
local function has(n, s, pat) if not tostring(s):find(pat, 1, true) then fails = fails + 1; print("FAIL " .. n .. ": '" .. tostring(s) .. "' lacks '" .. pat .. "'") end end
local function widget()
    return setmetatable({}, { __index = function(t, k) local f = function() return t end; rawset(t, k, f); return f end })
end
local sent = 0
local function run(opts)
    local lines = {}
    local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
    G._G = G
    G.GaarForever = setmetatable({
        NewAddon = function() return setmetatable({ title = "GaarChatForever" }, { __index = function() return noop end }) end,
        Migrate = noop, IsSecret = function() return false end, OnOff = tostring,
    }, { __index = function() return noop end })
    local onEvent
    G.CreateFrame = function()
        local w = widget()
        w.SetScript = function(self, name, fn) if name == "OnEvent" then onEvent = fn end end
        return w
    end
    G.SlashCmdList = {}; G.hooksecurefunc = noop
    G.SendChatMessage = function() sent = sent + 1 end
    G.C_ChatInfo = { SendChatMessage = function() sent = sent + 1 end }
    G.CHAT_GUILD_GET = "|Hchannel:Guild|h[Guild]|h %s: "
    G.CHAT_OFFICER_GET = "|Hchannel:o|h[Officer]|h %s: "
    G.CHAT_PARTY_GET = "|Hchannel:Party|h[Party]|h %s: "
    G.CHAT_SAY_GET = "%s says: "
    G.CHAT_YELL_GET = "%s yells: "
    G.CHAT_WHISPER_GET = "%s whispers: "
    G.CHAT_WHISPER_INFORM_GET = "To %s: "
    G.RAID_CLASS_COLORS = { MAGE = { r = .25, g = .78, b = .92, colorStr = "ff3fc7eb" } }
    G.ChatTypeInfo = { SAY = { r = 1, g = 1, b = 1 }, CHANNEL1 = { r = 1, g = .75, b = .75 } }
    G.CHAT_TIMESTAMP_FORMAT = "[%H:%M] "
    G.date = function() return "[12:00] " end
    G.GaarChatForeverDB = opts
    local ns = { Feed = setmetatable({}, { __index = function() return function() return {} end end }) }
    G.ChatFrame1 = { AddMessage = function(_, t, r, g, b) lines[#lines + 1] = { t = t, r = r, g = g, b = b } end }
    G.DEFAULT_CHAT_FRAME = G.ChatFrame1
    local f = assert(loadstring(src, "chat")); setfenv(f, G); f("GaarChatForever", ns)
    onEvent(nil, "ADDON_LOADED", "GaarChatForever")
    onEvent(nil, "PLAYER_LOGIN")
    G.SlashCmdList.GAARCHATFOREVER("test")
    return lines
end

local lines = run({ enabled = true, shortChannels = true, classColors = true, timestamps = true, urlCopy = true })
eq("line count", #lines, 12)
eq("header", lines[1].t, "GaarChat test lines:")
has("short general", lines[2].t, "|h[1]|h")
has("class colour", lines[2].t, "|cff3fc7eb")
has("timestamp", lines[2].t, "[12:00] ")
has("short lfg", lines[4].t, "|h[LFG]|h")
has("url link", lines[3].t, "|Hbcurl:www.example.com/guide|h")
has("short guild", lines[5].t, "|h[G]|h")
has("short officer", lines[6].t, "|h[O]|h")
has("short party", lines[7].t, "|h[P]|h")
has("channel colour", tostring(lines[2].g), "0.75")
eq("never sends", sent, 0)

local plain = run({ enabled = true, shortChannels = false, classColors = false, timestamps = false, urlCopy = false })
has("long general", plain[2].t, "[1. General - Stormwind City]")
has("no url link", plain[3].t, "www.example.com/guide")
eq("no bcurl when off", plain[3].t:find("bcurl", 1, true), nil)
eq("no colour when off", plain[2].t:find("|cff3fc7eb", 1, true), nil)
eq("never sends (off)", sent, 0)

if fails == 0 then print("chat_testlines_test: ok") else os.exit(1) end
