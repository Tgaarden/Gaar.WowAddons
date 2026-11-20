-- LuaJIT stub test: GaarMailForever 1.4 hides Blizzard's Open All button.
-- Run: luajit tools/test/mail_blizz_openall_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarMailForever/GaarMailForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { Bind = function() BindSavedVariables() end, Frames = CreateFrames, OnSlash = OnSlash }\n"
local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local function mkbutton()
    local b = { shown = true, hooks = {}, scripts = 0 }
    function b:Hide() self.shown = false end
    function b:Show() self.shown = true; for _, fn in ipairs(self.hooks) do fn(self) end end
    function b:HookScript(s, fn) if s == "OnShow" then self.hooks[#self.hooks + 1] = fn end end
    function b:SetScript() self.scripts = self.scripts + 1 end
    return b
end
local function load(btn)
    local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
    G._G = G
    G.GaarForever = { NewAddon = function() return { Print = noop } end, OnOff = function(v) return v and "on" or "off" end,
        InCombat = function() return false end, Plain = function(v) return v end, Migrate = noop, RenderMenu = noop,
        PlayerFullName = function() return "Dru Tics" end }
    G.UIParent = widget(); G.GameTooltip = widget(); G.SlashCmdList = {}; G.hooksecurefunc = noop
    G.UnitName = function() return "Dru" end
    G.SendMailNameEditBox = widget(); G.SendMailSubjectEditBox = widget(); G.SendMailFrame = widget()
    G.InboxFrame = widget(); G.OpenAllMail = btn
    local handlers = {}
    G.CreateFrame = function() local f = widget(); f.SetScript = function(_, k, fn) if k == "OnEvent" then handlers[#handlers + 1] = fn end end; return f end
    G.GaarMailForeverDB = nil
    local chunk = assert(loadstring(src, "mail")); setfenv(chunk, G); chunk("GaarMailForever")
    local ev = handlers[#handlers]
    ev(nil, "ADDON_LOADED", "GaarMailForever"); ev(nil, "PLAYER_LOGIN")
    return G, ev
end
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": got " .. tostring(a) .. ", want " .. tostring(b)) end end

local btn = mkbutton()
local G, ev = load(btn)
eq(G.GaarMailForeverDB.hideBlizzOpenAll, true, "default on")
ev(nil, "MAIL_SHOW")
eq(btn.shown, false, "hidden on mail show")
btn:Show(); eq(btn.shown, false, "re-hidden after Show()")
eq(btn.scripts, 0, "no scripts replaced")
local mx = G.GaarMailForeverAPI.MenuEntries()
local found; for _, e in ipairs(mx) do if e.text == "Hide Blizzard's Open All button" then found = e end end
eq(found and found.checked(), true, "menu entry checked")
G.SlashCmdList.GAARMAILFOREVER("blizzopenall off")
eq(btn.shown, true, "shown again when off")
btn:Show(); eq(btn.shown, true, "stays shown while off")
G.SlashCmdList.GAARMAILFOREVER("blizzopenall on")
eq(btn.shown, false, "hidden again when on")
-- mailbox closed: turning off does not show it
ev(nil, "MAIL_CLOSED")
G.SlashCmdList.GAARMAILFOREVER("blizzopenall off")
eq(btn.shown, false, "not shown with mailbox closed")
-- no Blizzard button: no error
local G2, ev2 = load(nil)
eq(pcall(ev2, nil, "MAIL_SHOW"), true, "nil button: MAIL_SHOW ok")
eq(pcall(G2.SlashCmdList.GAARMAILFOREVER, "blizzopenall off"), true, "nil button: slash ok")
if fails == 0 then print("OK mail_blizz_openall_test") else os.exit(1) end
