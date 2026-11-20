-- LuaJIT stub test: GaarMailForever 1.5: our Open All Mail button replaces Blizzard's (same spot, only one visible).
-- Run: luajit tools/test/mail_blizz_openall_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarMailForever/GaarMailForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { Btn = function() return openBtn end, Bind = function() BindSavedVariables() end, Frames = CreateFrames, OnSlash = OnSlash }\n"
local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local function mkbutton()
    local b = { shown = true, hooks = {}, scripts = 0, pts = { { "BOTTOMLEFT", "INBOXREL", "BOTTOMLEFT", 12, 34 } }, w = 120, h = 24 }
    function b:GetNumPoints() return #self.pts end
    function b:GetPoint(i) local p = self.pts[i]; return p[1], p[2], p[3], p[4], p[5] end
    function b:GetWidth() return self.w end
    function b:GetHeight() return self.h end
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
    G.CreateFrame = function(_, name) local f = widget(); if name == "GaarMailForeverOpenAll" then G.__ours = f; f.pts = {}; f.shown = true; f.text = nil
        f.SetText = function(_, t) f.text = t end; f.Show = function() f.shown = true end; f.Hide = function() f.shown = false end
        f.ClearAllPoints = function() f.pts = {} end; f.SetPoint = function(_, ...) f.pts[#f.pts + 1] = { ... } end
        f.SetWidth = function(_, v) f.w = v end; f.SetHeight = function(_, v) f.h = v end
        f.GetFontString = function() return { GetStringWidth = function() return 80 end } end; f.SetSize = noop end; f.SetScript = function(_, k, fn) if k == "OnEvent" then handlers[#handlers + 1] = fn end end; return f end
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
local ours = G.__ours
eq(btn.shown, false, "Blizzard hidden on mail show")
eq(ours.shown, true, "ours shown on mail show")
eq(ours.text, "Open All Mail", "button text")
eq(#ours.pts, 1, "one anchor copied")
eq(ours.pts[1][1], "BOTTOMLEFT", "anchor point copied")
eq(ours.pts[1][2], "INBOXREL", "anchor relative copied")
eq(ours.pts[1][4], 12, "anchor x copied")
eq(ours.pts[1][5], 34, "anchor y copied")
eq(ours.w, 120, "width matches Blizzard (wide enough)")
eq(ours.h, 24, "height matches Blizzard")
btn:Show(); eq(btn.shown, false, "re-hidden after Show()")
eq(btn.scripts, 0, "no scripts replaced")
local mx = G.GaarMailForeverAPI.MenuEntries()
local found; for _, e in ipairs(mx) do if e.text == "Use GaarMail's Open All instead of Blizzard's" then found = e end end
eq(found and found.checked(), true, "menu entry checked")
G.SlashCmdList.GAARMAILFOREVER("blizzopenall off")
eq(btn.shown, true, "Blizzard shown when off")
eq(ours.shown, false, "ours hidden when off")
btn:Show(); eq(btn.shown, true, "Blizzard stays shown while off")
G.SlashCmdList.GAARMAILFOREVER("blizzopenall on")
eq(btn.shown, false, "Blizzard hidden again when on")
eq(ours.shown, true, "ours shown again when on")
-- master switch off: Blizzard's shown, ours hidden
G.SlashCmdList.GAARMAILFOREVER("off")
eq(btn.shown, true, "master off: Blizzard shown")
eq(ours.shown, false, "master off: ours hidden")
G.SlashCmdList.GAARMAILFOREVER("on")
eq(btn.shown, false, "master on: Blizzard hidden")
eq(ours.shown, true, "master on: ours shown")
-- mailbox closed: turning off does not show Blizzard's
ev(nil, "MAIL_CLOSED")
G.SlashCmdList.GAARMAILFOREVER("blizzopenall off")
eq(btn.shown, false, "not shown with mailbox closed")
-- no Blizzard button: fallback bottom-centre of the Inbox frame, no error
local G2, ev2 = load(nil)
eq(pcall(ev2, nil, "MAIL_SHOW"), true, "nil button: MAIL_SHOW ok")
local o2 = G2.__ours
eq(#o2.pts, 1, "fallback: one anchor")
eq(o2.pts[1][1], "BOTTOM", "fallback: bottom-centre")
eq(o2.pts[1][4], 0, "fallback: x 0")
eq(o2.pts[1][5], 80, "fallback: default offset")
eq(o2.w, 104, "fallback: width from text")
eq(o2.shown, true, "nil button: ours shown")
eq(pcall(G2.SlashCmdList.GAARMAILFOREVER, "blizzopenall off"), true, "nil button: slash ok")
eq(o2.shown, false, "nil button: ours hidden when off")
if fails == 0 then print("OK mail_blizz_openall_test") else os.exit(1) end
