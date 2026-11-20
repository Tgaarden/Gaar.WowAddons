-- LuaJIT stub test: GaarMailForever 1.2 default subject "From <full name>".
-- Run: luajit tools/test/mail_subject_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarMailForever/GaarMailForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { Bind = function() BindSavedVariables() end, Apply = ApplyDefaultSubject, Frames = CreateFrames, OnSlash = OnSlash }\n"

local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.GaarForever = {
    NewAddon = function() return { Print = noop } end,
    OnOff = function(v) return v and "on" or "off" end,
    InCombat = function() return false end,
    Plain = function(v) return v end,
    Migrate = noop, RenderMenu = noop,
    PlayerFullName = function() return "Dru Tics" end,
}
G.UIParent = widget(); G.GameTooltip = widget(); G.SlashCmdList = {}
G.hooksecurefunc = noop; G.UnitName = function() return "Dru" end
local function editbox(text)
    local e = { text = text or "", hooks = {} }
    function e:GetText() return self.text end
    function e:SetText(t) self.text = t end
    function e:SetCursorPosition() end
    function e:SetFocus() end
    function e:HookScript(s, fn) self.hooks[s] = fn end
    return e
end
G.SendMailNameEditBox = editbox(); G.SendMailSubjectEditBox = editbox()
G.SendMailFrame = widget()
local attached
G.GetSendMailItem = function(i) if attached and i == 1 then return attached end end
local handlers = {}
G.CreateFrame = function()
    local f = widget(); f.SetScript = function(self, k, fn) if k == "OnEvent" then handlers[#handlers + 1] = fn end end
    return f
end
G.GaarMailForeverDB = nil

local chunk = assert(loadstring(src, "mail")); setfenv(chunk, G); chunk("GaarMailForever")
local T = G.__T
G.GaarMailForeverDB = nil
-- ADDON_LOADED then PLAYER_LOGIN through the event frame
local ev = handlers[#handlers]
ev(nil, "ADDON_LOADED", "GaarMailForever")
ev(nil, "PLAYER_LOGIN")
T.Frames()

local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": got " .. tostring(a) .. ", want " .. tostring(b)) end end
local name, subj = G.SendMailNameEditBox, G.SendMailSubjectEditBox

-- no recipient yet: nothing
T.Apply(); eq(subj.text, "", "no recipient")
-- typed name, leave box
name.text = "Bob"; name.hooks.OnEditFocusLost(name); eq(subj.text, "From Dru Tics", "default set on focus lost")
-- changing recipient keeps our own default (same text)
name.text = "Alice"; name.hooks.OnEnterPressed(name); eq(subj.text, "From Dru Tics", "default kept")
-- user text is never overwritten
subj.text = "Hello"; name.text = "Carl"; name.hooks.OnTabPressed(name); eq(subj.text, "Hello", "user text kept")
-- programmatic SetText (Alt-click / reply) counts, typed (userInput) does not
subj.text = ""; name.hooks.OnTextChanged(name, true); eq(subj.text, "", "typing does not set")
name.hooks.OnTextChanged(name, false); eq(subj.text, "From Dru Tics", "programmatic set counts")
-- item attached: our default is replaced by the item name
attached = "Linen Cloth"; ev(nil, "MAIL_SEND_INFO_UPDATE"); eq(subj.text, "Linen Cloth", "item name wins")
-- default is not set while an item is attached (Blizzard names the subject)
subj.text = ""; T.Apply(); eq(subj.text, "", "no default with item attached")
-- user text survives an attach
attached = nil; subj.text = "My text"; T.Apply(); ev(nil, "MAIL_SEND_INFO_UPDATE"); attached = "Linen Cloth"
ev(nil, "MAIL_SEND_INFO_UPDATE"); eq(subj.text, "My text", "typed text survives attach")
-- toggle off
attached = nil; subj.text = ""; T.OnSlash("subject off"); T.Apply(); eq(subj.text, "", "off sets nothing")
T.OnSlash("subject on"); T.Apply(); eq(subj.text, "From Dru Tics", "on again")

if fails == 0 then print("mail_subject_test: ok") else os.exit(1) end
