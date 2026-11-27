--[[
  GaarChatForever - small chat tweaks on WoW Forever, each one switchable.

  Nine features, all on /gchat <feature> on|off, plus a master on|off:

    shortChannels  (on)   [Guild] -> [G], [Party] -> [P], [Raid Leader] -> [RL] ..., numbered
                          channels [2. Trade - City] -> [2], [4. LookingForGroup] -> [LFG].
                          Blizzard's CHAT_*_GET globals are rewritten (originals kept, put back
                          when switched off); the numbered channels are shortened in each chat
                          frame's AddMessage, because rewriting the channel argument in a filter
                          would break the per-frame channel lists.
    classColors    (on)   Blizzard's own "colour names by class" setting, set for the say, guild,
                          party, raid, whisper and channel types (SetChatColorNameByClass).
    timestamps     (off)  Blizzard's showTimestamps cvar, with the stamp drawn as a soft grey [HH:MM].
    urlCopy        (on)   URLs in plain text become |Hbcurl:...|h links; a click opens a small box
                          with the URL selected, ready for Ctrl+C.
    copyChat       (on)   A small button on every chat frame (and /gchat copy [n]) opens a scrollable
                          edit box with the last 200 lines of that frame, as plain text.
    whisperSound   (on)   A short sound on incoming whispers and Battle.net whispers.
    stickyChannels (on)   ChatTypeInfo[x].sticky = 1 for say, party, guild, raid, officer, whisper ...
    arrowKeys      (on)   SetAltArrowKeyMode(false) on the chat edit boxes: arrows move the cursor.
    feed           (on)   A scrolling feed of whispers, group chat and mentions of your name, like
                          scrolling combat text (Feed.lua, /gchat feed ...). It only shows copies:
                          nothing is taken out of the chat frames.

  Secret text. On the 12.x engine a chat message, its sender and the stored history lines can be
  secret values in instances and in combat. A secret value is never compared, tested, matched or
  gsub'ed here: the filter and the AddMessage wrapper hand it on untouched (and the copy window
  skips such lines). The whisper sound never reads the event arguments at all.

  Taint: Blizzard code is followed, not replaced. The only Blizzard things written are strings and
  flags (CHAT_*_GET, ChatTypeInfo[x].sticky, CHAT_TIMESTAMP_FORMAT) and the AddMessage field of
  chat frames, a wrapper that always calls the original. Every client API is checked with
  type(...) == "function" first, every handler runs in pcall (the last error is kept for
  /gchat status).

  Shared helpers come from GaarForever's library (global GaarForever, Lib.lua, loaded first
  through ## Dependencies): the chat prefix, the secret check and the menu drawing.

  GaarChatForeverAPI is the small global table GaarForever's hub menu reads (version,
  StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The addon runs the same without it.
]]

local _G = _G
local ADDON_NAME, ns = ...
ADDON_NAME = ADDON_NAME or "GaarChatForever"
ns = ns or {}               -- shared with Feed.lua
local DOT = " \194\183 "
local VERSION = "1.7.1"

local BF = _G.GaarForever
local A = BF.NewAddon("GaarChatForever", { title = "GaarChatForever", version = VERSION })

local COPY_LINES = 200
local LINK_COLOR = "|cff66b3ff"
local STAMP_COLOR = "|cff8c8c8c"

-- In display order: key, label, default.
local FEATURES = {
    { key = "shortChannels",  label = "Short channel names",         default = true  },
    { key = "classColors",    label = "Class-coloured names",        default = true  },
    { key = "timestamps",     label = "Timestamps",                  default = false },
    { key = "urlCopy",        label = "Clickable links (copy URL)",  default = true  },
    { key = "copyChat",       label = "Copy chat button",            default = true  },
    { key = "whisperSound",   label = "Whisper sound",               default = true  },
    { key = "stickyChannels", label = "Remember last chat type",     default = true  },
    { key = "arrowKeys",      label = "Arrow keys in the edit box",  default = true  },
    { key = "autoGroupChannel", label = "Auto party/raid chat channel", default = true },
    { key = "feed",           label = "Scrolling chat feed",         default = true  },
}
local SAVED_KEYS = { enabled = true, owned = true, feedOpts = true }
for _, f in ipairs(FEATURES) do SAVED_KEYS[f.key] = true end

local db                    -- GaarChatForeverDB, bound at ADDON_LOADED
local lastError
local applied = false       -- PLAYER_LOGIN ran: features may be applied

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg) A:Print(msg) end

local Secret = BF.IsSecret

local function Fail(where, err)
    lastError = where .. ": " .. tostring(err)
end

local function Enabled() return db and db.enabled and true or false end

-- A feature is active when the master switch and its own switch are on.
local function Effective(key)
    return db and db.enabled and db[key] and true or false
end

local function Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Fail(where, err) end
    return ok
end

local function NumWindows()
    local n = _G.NUM_CHAT_WINDOWS
    return type(n) == "number" and n or 10
end

local function EachChatFrame(fn)
    for i = 1, NumWindows() do
        local f = _G["ChatFrame" .. i]
        if type(f) == "table" then Safe("frame" .. i, fn, f, i) end
    end
end

-- ---------------------------------------------------------------------------
-- shortChannels
-- ---------------------------------------------------------------------------

local GET_SHORT = {
    CHAT_GUILD_GET = "G", CHAT_OFFICER_GET = "O",
    CHAT_PARTY_GET = "P", CHAT_PARTY_LEADER_GET = "PL", CHAT_PARTY_GUIDE_GET = "PL",
    CHAT_RAID_GET = "R", CHAT_RAID_LEADER_GET = "RL", CHAT_RAID_WARNING_GET = "RW",
    CHAT_INSTANCE_CHAT_GET = "I", CHAT_INSTANCE_CHAT_LEADER_GET = "IL",
}
local origGet = {}          -- name -> Blizzard's original string

local function ApplyShortChannels(on)
    for name, short in pairs(GET_SHORT) do
        local cur = _G[name]
        if on then
            if origGet[name] == nil and type(cur) == "string" then origGet[name] = cur end
            local orig = origGet[name]
            if orig then
                -- Only the bracketed label inside the channel link changes: |h[Guild]|h -> |h[G]|h.
                _G[name] = orig:gsub("(|h)%[[^%]]*%](|h)", "%1[" .. short .. "]%2", 1)
            end
        elseif origGet[name] then
            _G[name] = origGet[name]
        end
    end
end

local function IsLfgName(name)
    local l = name:lower()
    if l:find("lookingforgroup", 1, true) or l:find("looking for group", 1, true) then return true end
    local g = _G.LOOK_FOR_GROUP
    return type(g) == "string" and g ~= "" and l:find(g:lower(), 1, true) and true or false
end

-- |Hchannel:channel:2|h[2. Trade - City]|h -> |Hchannel:channel:2|h[2]|h (LookingForGroup: [LFG]).
local function ShortenChannelText(text)
    if not text:find("|Hchannel:channel:", 1, true) then return text end
    return (text:gsub("(|Hchannel:channel:)(%d+)(|h)%[([^%]]*)%](|h)", function(a, num, b, name, c)
        return a .. num .. b .. "[" .. (IsLfgName(name) and "LFG" or num) .. "]" .. c
    end))
end

local wrapped = {}
local function WrapAddMessage(f)
    if wrapped[f] or type(f.AddMessage) ~= "function" then return end
    wrapped[f] = true
    local orig = f.AddMessage
    f.AddMessage = function(self, text, ...)
        if db and db.enabled and db.shortChannels and type(text) == "string" and not Secret(text) then
            local ok, new = pcall(ShortenChannelText, text)
            if ok and type(new) == "string" then text = new end
        end
        return orig(self, text, ...)
    end
end

-- ---------------------------------------------------------------------------
-- classColors
-- ---------------------------------------------------------------------------

local CLASS_TYPES = { "SAY", "EMOTE", "YELL", "GUILD", "OFFICER", "GUILD_ACHIEVEMENT", "ACHIEVEMENT",
    "WHISPER", "PARTY", "PARTY_LEADER", "RAID", "RAID_LEADER", "RAID_WARNING",
    "INSTANCE_CHAT", "INSTANCE_CHAT_LEADER" }
for i = 1, 10 do CLASS_TYPES[#CLASS_TYPES + 1] = "CHANNEL" .. i end

local function SetClassColor(t, v)
    local set = _G.SetChatColorNameByClass
    if type(set) == "function" then
        set(t, v)
    elseif type(_G.ChatTypeInfo) == "table" and type(_G.ChatTypeInfo[t]) == "table" then
        _G.ChatTypeInfo[t].colorNameByClass = v
    end
end

local function ApplyClassColors(on)
    local info = _G.ChatTypeInfo
    if type(info) ~= "table" then return end
    db.owned = type(db.owned) == "table" and db.owned or {}
    local mine = type(db.owned.class) == "table" and db.owned.class or {}
    db.owned.class = mine
    for _, t in ipairs(CLASS_TYPES) do
        local entry = info[t]
        if type(entry) == "table" then
            if on then
                if not entry.colorNameByClass then
                    mine[t] = true          -- we flipped it, so we put it back
                    SetClassColor(t, true)
                end
            elseif mine[t] then
                SetClassColor(t, false)
                mine[t] = nil
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- timestamps
-- ---------------------------------------------------------------------------

local function ApplyTimestamps(on)
    db.owned = type(db.owned) == "table" and db.owned or {}
    local function setCvar(v)
        if _G.C_CVar and type(_G.C_CVar.SetCVar) == "function" then
            _G.C_CVar.SetCVar("showTimestamps", v)
        elseif type(_G.SetCVar) == "function" then
            _G.SetCVar("showTimestamps", v)
        end
    end
    if on then
        setCvar("%H:%M ")
        db.owned.ts = true
        -- The cvar owns the format; ours only adds the soft grey and the brackets.
        _G.CHAT_TIMESTAMP_FORMAT = STAMP_COLOR .. "[%H:%M]|r "
    elseif db.owned.ts then
        db.owned.ts = nil
        setCvar("none")
        _G.CHAT_TIMESTAMP_FORMAT = nil
    end
end

-- ---------------------------------------------------------------------------
-- urlCopy
-- ---------------------------------------------------------------------------

local TLD = {}
for t in ("com net org info io gg tv me dev app co uk de se dk no fi eu fr nl es it pl ru us ca au nz xyz gov edu"):gmatch("%S+") do TLD[t] = true end
local BARE_TLD = { com = true, net = true, org = true, io = true, gg = true, tv = true, dev = true, app = true, info = true }

local function DetectUrl(core)
    local lower = core:lower()
    if lower:find("^https?://") and #core > 8 then return true end
    if lower:find("^www%.[%w%-]+%.%a+") then return true end
    local host = core:match("^[^/:?#]+")
    if not host or not host:find("^[%w][%w%-%.]*$") or host:find("..", 1, true) then return false end
    local tld = host:match("^[%w%-%.]+%.(%a+)$")
    if not tld then return false end
    tld = tld:lower()
    if not TLD[tld] then return false end
    local rest = core:sub(#host + 1)
    if rest:sub(1, 1) == "/" then return true end
    return rest == "" and BARE_TLD[tld] and true or false
end

local function LinkifySegment(seg)
    return (seg:gsub("%S+", function(tok)
        local lead, core, trail = tok:match("^([%(<\"']*)(.-)([%.,;:!%?%)>\"']*)$")
        if not core or core == "" or core:find("|", 1, true) then return tok end
        if not DetectUrl(core) then return tok end
        return lead .. LINK_COLOR .. "|Hbcurl:" .. core .. "|h[" .. core .. "]|h|r" .. trail
    end))
end

-- Linkify everything outside existing hyperlinks.
local function Linkify(text)
    if not (text:find(".", 1, true)) then return text end
    local out, pos, len = {}, 1, #text
    while pos <= len do
        local s, e = text:find("|H[^|]*|h.-|h", pos)
        out[#out + 1] = LinkifySegment(text:sub(pos, s and (s - 1) or len))
        if not s then break end
        out[#out + 1] = text:sub(s, e)
        pos = e + 1
    end
    return table.concat(out)
end

local function ChatFilter(_, _, msg, ...)
    if not Effective("urlCopy") or type(msg) ~= "string" or Secret(msg) then return false end
    local ok, new = pcall(Linkify, msg)
    if ok and type(new) == "string" and new ~= msg then return false, new, ... end
    return false
end

local FILTER_EVENTS = { "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM", "CHAT_MSG_CHANNEL" }

local function AddFilters()
    local add = _G.ChatFrame_AddMessageEventFilter
    if type(add) ~= "function" and type(_G.ChatFrameUtil) == "table" then add = _G.ChatFrameUtil.AddMessageEventFilter end
    if type(add) ~= "function" then Fail("filters", "no AddMessageEventFilter on this client"); return end
    for _, ev in ipairs(FILTER_EVENTS) do Safe("filter " .. ev, add, ev, ChatFilter) end
end

-- The small box a link click opens: the URL, selected, for Ctrl+C.
local urlBox
local function ShowUrl(url)
    if not urlBox then
        local f = CreateFrame("Frame", "GaarChatForeverUrlBox", UIParent, "BackdropTemplate")
        f:SetSize(520, 76)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
        f:SetFrameStrata("DIALOG")
        f:SetClampedToScreen(true)
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 24,
                insets = { left = 6, right = 6, top = 6, bottom = 6 } })
        end
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOPLEFT", 16, -14)
        label:SetText("Ctrl+C to copy, Esc to close")
        local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        eb:SetAutoFocus(false)
        eb:SetSize(470, 24)
        eb:SetPoint("BOTTOMLEFT", 20, 14)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        eb:SetScript("OnEnterPressed", function() f:Hide() end)
        eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        eb:SetScript("OnTextChanged", function(self, user)
            if user and f.url then self:SetText(f.url); self:HighlightText() end
        end)
        f.edit = eb
        if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "GaarChatForeverUrlBox") end
        urlBox = f
    end
    urlBox.url = url
    urlBox.edit:SetText(url)
    urlBox:Show()
    urlBox.edit:SetFocus()
    urlBox.edit:HighlightText()
end

local linkHooked = {}
local function HookLinks(f)
    if linkHooked[f] or type(f.HookScript) ~= "function" then return end
    linkHooked[f] = true
    f:HookScript("OnHyperlinkClick", function(_, link)
        Safe("link", function()
            if type(link) == "string" and not Secret(link) then
                local url = link:match("^bcurl:(.+)$")
                if url then ShowUrl(url) end
            end
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- copyChat
-- ---------------------------------------------------------------------------

local function Plain(text)
    text = text:gsub("|T.-|t", ""):gsub("|A.-|a", "")
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("|H.-|h(.-)|h", "%1")
    return (text:gsub("||", "|"))
end

local function CollectLines(frame)
    local getN, getInfo = frame.GetNumMessages, frame.GetMessageInfo
    if type(getN) ~= "function" or type(getInfo) ~= "function" then return nil end
    local n = getN(frame)
    if type(n) ~= "number" or Secret(n) then return {} end
    local lines, skipped = {}, 0
    for i = math.max(1, n - COPY_LINES + 1), n do
        local text = getInfo(frame, i)
        if type(text) == "string" and not Secret(text) then
            lines[#lines + 1] = Plain(text)
        else
            skipped = skipped + 1
        end
    end
    return lines, skipped
end

local copyBox
local function ShowCopy(frame)
    frame = frame or _G.SELECTED_CHAT_FRAME or _G.DEFAULT_CHAT_FRAME
    if type(frame) ~= "table" then return end
    local lines, skipped = CollectLines(frame)
    if not lines then Print("this chat frame offers no message history."); return end
    if not copyBox then
        local f = CreateFrame("Frame", "GaarChatForeverCopyBox", UIParent, "BackdropTemplate")
        f:SetSize(620, 420)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetClampedToScreen(true)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 24,
                insets = { left = 6, right = 6, top = 6, bottom = 6 } })
        end
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.title:SetPoint("TOPLEFT", 18, -14)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -2, -2)
        local scroll = CreateFrame("ScrollFrame", "GaarChatForeverCopyScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 16, -38)
        scroll:SetPoint("BOTTOMRIGHT", -36, 16)
        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject(_G.ChatFontNormal or _G.GameFontHighlight)
        eb:SetWidth(560)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(eb)
        f.edit, f.scroll = eb, scroll
        if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "GaarChatForeverCopyBox") end
        copyBox = f
    end
    local name = type(frame.GetName) == "function" and frame:GetName() or "chat"
    copyBox.title:SetText("Copy chat: " .. tostring(name) .. " (last " .. #lines .. " lines"
        .. ((skipped or 0) > 0 and (", " .. skipped .. " hidden lines skipped") or "") .. ")")
    copyBox.edit:SetText(table.concat(lines, "\n"))
    copyBox:Show()
    local function toEnd()
        if copyBox.scroll.GetVerticalScrollRange then
            copyBox.scroll:SetVerticalScroll(copyBox.scroll:GetVerticalScrollRange())
        end
    end
    if _G.C_Timer and type(_G.C_Timer.After) == "function" then _G.C_Timer.After(0.05, toEnd) else toEnd() end
end

local copyButtons = {}
local function EnsureCopyButton(f, i)
    local b = copyButtons[f]
    if not b then
        b = CreateFrame("Button", "GaarChatForeverCopyButton" .. i, f)
        b:SetSize(16, 16)
        b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
        b:SetFrameLevel((f:GetFrameLevel() or 1) + 5)
        local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetAllPoints()
        t:SetText("C")
        b:SetAlpha(0.3)
        b:SetScript("OnEnter", function(self)
            self:SetAlpha(1)
            if _G.GameTooltip then
                _G.GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                _G.GameTooltip:SetText("Copy chat")
                _G.GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function(self)
            self:SetAlpha(0.3)
            if _G.GameTooltip then _G.GameTooltip:Hide() end
        end)
        b:SetScript("OnClick", function() Safe("copy", ShowCopy, f) end)
        copyButtons[f] = b
    end
    b:SetShown(Effective("copyChat"))
end

-- ---------------------------------------------------------------------------
-- stickyChannels, arrowKeys
-- ---------------------------------------------------------------------------

local STICKY_TYPES = { "SAY", "EMOTE", "YELL", "PARTY", "RAID", "GUILD", "OFFICER", "WHISPER", "BN_WHISPER",
    "INSTANCE_CHAT", "CHANNEL" }
local origSticky = {}

local function ApplySticky(on)
    local info = _G.ChatTypeInfo
    if type(info) ~= "table" then return end
    for _, t in ipairs(STICKY_TYPES) do
        local e = info[t]
        if type(e) == "table" then
            if on then
                if origSticky[t] == nil then origSticky[t] = e.sticky or 0 end
                e.sticky = 1
            elseif origSticky[t] ~= nil then
                e.sticky = origSticky[t]
            end
        end
    end
end

local function ApplyEditBox(eb)
    if type(eb) == "table" and type(eb.SetAltArrowKeyMode) == "function" then
        eb:SetAltArrowKeyMode(not Effective("arrowKeys"))
    end
end

local function ApplyArrowKeys()
    for i = 1, NumWindows() do
        local eb = _G["ChatFrame" .. i .. "EditBox"]
        if eb then Safe("arrow" .. i, ApplyEditBox, eb) end
    end
end

-- ---------------------------------------------------------------------------
-- autoGroupChannel
--
-- The edit box's sticky chat type becomes PARTY (RAID in a raid, INSTANCE_CHAT in an instance
-- group) when a group transition happens: joined a group, party <-> raid, or already grouped at
-- login. Between transitions the player's own choice is left alone. When the group is left the
-- type that was sticky before our first switch comes back, but only if the box still has the type
-- we set. Written: the "chatType" / "stickyType" (and tellTarget / channelTarget) attributes of
-- the ChatFrameNEditBox frames, which Blizzard's ChatEdit_* code reads, then ChatEdit_UpdateHeader.
-- A box that is being typed in, or any box in combat, is done later (OnHide / focus lost /
-- PLAYER_REGEN_ENABLED).
-- ---------------------------------------------------------------------------

local AG = { state = "none", saved = nil, setType = nil, pending = {}, hooked = {} }

function AG.Boxes()
    local list = {}
    for i = 1, NumWindows() do
        local eb = _G["ChatFrame" .. i .. "EditBox"]
        if type(eb) == "table" and type(eb.GetAttribute) == "function" then list[#list + 1] = eb end
    end
    return list
end

function AG.Group()
    if type(_G.IsInGroup) ~= "function" then return "none" end
    local home = _G.LE_PARTY_CATEGORY_HOME
    local inst = _G.LE_PARTY_CATEGORY_INSTANCE
    local info = _G.ChatTypeInfo
    if inst and type(info) == "table" and info.INSTANCE_CHAT and _G.IsInGroup(inst) then return "INSTANCE_CHAT" end
    if type(_G.IsInRaid) == "function" and _G.IsInRaid(home) then return "RAID" end
    if _G.IsInGroup(home) then return "PARTY" end
    return "none"
end

function AG.Snapshot(eb)
    local t = eb:GetAttribute("stickyType") or eb:GetAttribute("chatType") or "SAY"
    local s = { chatType = t }
    if t == "WHISPER" or t == "BN_WHISPER" then
        s.tellTarget = eb:GetAttribute("tellTarget")
        if not s.tellTarget then s.chatType = "SAY" end
    elseif t == "CHANNEL" then
        s.channelTarget = eb:GetAttribute("channelTarget")
        if not s.channelTarget then s.chatType = "SAY" end
    end
    return s
end

-- Sets one edit box: want = { chatType, tellTarget, channelTarget, onlyIfSticky }.
function AG.Write(eb, want)
    if want.onlyIfSticky and eb:GetAttribute("stickyType") ~= want.onlyIfSticky then return end
    eb:SetAttribute("chatType", want.chatType)
    eb:SetAttribute("stickyType", want.chatType)
    if want.tellTarget then eb:SetAttribute("tellTarget", want.tellTarget) end
    if want.channelTarget then eb:SetAttribute("channelTarget", want.channelTarget) end
    if type(_G.ChatEdit_UpdateHeader) == "function" then _G.ChatEdit_UpdateHeader(eb) end
end

function AG.Busy(eb)
    if type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() then return true end
    return type(eb.HasFocus) == "function" and eb:HasFocus() and true or false
end

function AG.Hook(eb)
    if AG.hooked[eb] or type(eb.HookScript) ~= "function" then return end
    AG.hooked[eb] = true
    local function retry() if AG.pending[eb] then Safe("autoGroup retry", AG.Flush) end end
    pcall(eb.HookScript, eb, "OnHide", retry)
    pcall(eb.HookScript, eb, "OnEditFocusLost", retry)
end

function AG.Flush()
    for eb, want in pairs(AG.pending) do
        if not AG.Busy(eb) then
            AG.pending[eb] = nil
            Safe("autoGroup write", AG.Write, eb, want)
        end
    end
end

function AG.Push(want)
    for _, eb in ipairs(AG.Boxes()) do
        AG.Hook(eb)
        AG.pending[eb] = want
    end
    AG.Flush()
end

-- Called on GROUP_ROSTER_UPDATE / PLAYER_ENTERING_WORLD (force = feature just switched on or off).
function AG.Check()
    if not applied or not db then return end
    local new = Effective("autoGroupChannel") and AG.Group() or "none"
    if new == AG.state then return end
    AG.state = new
    local main = _G.ChatEdit_ChooseBoxForSend and _G.ChatEdit_ChooseBoxForSend() or _G.ChatFrame1EditBox
    if type(main) ~= "table" or type(main.GetAttribute) ~= "function" then main = _G.ChatFrame1EditBox end
    if type(main) ~= "table" or type(main.GetAttribute) ~= "function" then return end
    if new ~= "none" then
        if not AG.saved then AG.saved = AG.Snapshot(main) end
        AG.setType = new
        AG.Push({ chatType = new })
    elseif AG.saved then
        local s = AG.saved
        local was = AG.setType
        AG.saved, AG.setType = nil, nil
        AG.Push({ chatType = s.chatType, tellTarget = s.tellTarget, channelTarget = s.channelTarget, onlyIfSticky = was })
    end
end

function AG.Text()
    local s = AG.saved
    local prev = s and (s.chatType .. ((s.tellTarget or s.channelTarget) and (" " .. tostring(s.tellTarget or s.channelTarget)) or "")) or "none"
    return string.format("autoGroupChannel: group state %s, set channel %s, remembered previous channel %s",
        AG.state, AG.setType or "none", prev)
end

-- ---------------------------------------------------------------------------
-- Applying features
-- ---------------------------------------------------------------------------

local function EnsureFrames()
    EachChatFrame(function(f, i)
        WrapAddMessage(f)
        HookLinks(f)
        EnsureCopyButton(f, i)
    end)
end

local APPLY = {
    shortChannels  = function(on) ApplyShortChannels(on) end,
    classColors    = function(on) ApplyClassColors(on) end,
    timestamps     = function(on) ApplyTimestamps(on) end,
    urlCopy        = function() end,   -- the filter and the link hook check Effective() themselves
    copyChat       = function() EnsureFrames() end,
    whisperSound   = function() end,   -- the event handler checks Effective() itself
    stickyChannels = function(on) ApplySticky(on) end,
    arrowKeys      = function() ApplyArrowKeys() end,
    autoGroupChannel = function(on)
        if not on then   -- switched off: put the old channel back, then forget
            local s = AG.state
            AG.state = s ~= "none" and "none" or s
            if AG.saved then
                local sv, was = AG.saved, AG.setType
                AG.saved, AG.setType = nil, nil
                AG.Push({ chatType = sv.chatType, tellTarget = sv.tellTarget, channelTarget = sv.channelTarget, onlyIfSticky = was })
            end
            AG.state = "none"
        else
            AG.state = "none"
            AG.Check()
        end
    end,
    feed           = function(on) ns.Feed.Apply(on) end,
}

local function ApplyFeature(key)
    if not applied or not db then return end
    Safe("apply " .. key, function() APPLY[key](Effective(key)) end)
end

local function ApplyAll()
    for _, f in ipairs(FEATURES) do ApplyFeature(f.key) end
end

local function SetFeature(key, v)
    db[key] = v and true or false
    ApplyFeature(key)
    Print(key .. ": " .. (db[key] and "on" or "off") .. ((db[key] and not db.enabled) and " (master switch is off)" or ""))
end

local function SetEnabled(v)
    db.enabled = v and true or false
    ApplyAll()
    Print("addon " .. (db.enabled and "on" or "off"))
end

-- For Feed.lua.
ns.Print, ns.Safe, ns.SetFeature, ns.Effective = Print, Safe, SetFeature, Effective
ns.GetDB = function() return db end

-- ---------------------------------------------------------------------------
-- Whisper sound
-- ---------------------------------------------------------------------------

local lastSound = 0
local function PlayWhisperSound()
    local now = type(_G.GetTime) == "function" and _G.GetTime() or 0
    if type(now) ~= "number" or now - lastSound < 0.5 then return end
    lastSound = now
    local kit = _G.SOUNDKIT
    local id = type(kit) == "table" and (kit.UI_BNET_TOAST or kit.TELL_MESSAGE) or 3081
    if type(_G.PlaySound) == "function" then _G.PlaySound(id, "Master") end
end

-- ---------------------------------------------------------------------------
-- /gchat test: sample lines in the main chat frame, for a screenshot
--
-- Each line is built the way Blizzard builds a real one (channel link, player link, the
-- CHAT_*_GET text) and then goes through our own functions: ShortenChannelText (also run by the
-- AddMessage wrapper), the class colour, Linkify (the same as ChatFilter) and the timestamp
-- format. It is printed with AddMessage only: no chat event is fired and nothing is sent.
-- ---------------------------------------------------------------------------

local TEST_SAMPLES = {
    { kind = "CHANNEL", chan = 1, name = "General - Stormwind City", sender = "Jaina", class = "MAGE",
      msg = "Anyone for Scholomance after this?" },
    { kind = "CHANNEL", chan = 2, name = "Trade - Stormwind City", sender = "Thrall", class = "SHAMAN",
      msg = "WTS [Thunderfury, Blessed Blade of the Windseeker] www.example.com/guide - whisper me" },
    { kind = "CHANNEL", chan = 4, name = "LookingForGroup", sender = "Sylvanas", class = "HUNTER",
      msg = "LF healer for Stratholme, 2 DPS ready" },
    { kind = "GUILD",         sender = "Uther",    class = "PALADIN", msg = "Guild run tonight at 20:00." },
    { kind = "OFFICER",       sender = "Bolvar",   class = "WARRIOR", msg = "Remember to check the bank." },
    { kind = "PARTY",         sender = "Anduin",   class = "PRIEST",  msg = "Need mana, drinking." },
    { kind = "SAY",           sender = "Varian",   class = "WARRIOR", msg = "Nice gear!" },
    { kind = "YELL",          sender = "Valeera",  class = "ROGUE",   msg = "Behind you!" },
    { kind = "WHISPER",       sender = "Malfurion", class = "DRUID",  msg = "Thanks for the help! Guide: https://example.com/druid" },
    { kind = "WHISPER_INFORM", sender = "Gul'dan", class = "WARLOCK", msg = "Sure, summoning now." },
    { kind = "SYSTEM", msg = "Jaina has come online." },
}

local TEST_FALLBACK_COLOR = { SYSTEM = { r = 1, g = 1, b = 0 } }

local function TestColorName(name, class)
    if not Effective("classColors") or not class then return name end
    local rc = type(_G.RAID_CLASS_COLORS) == "table" and _G.RAID_CLASS_COLORS[class] or nil
    if type(rc) ~= "table" then return name end
    local hex = type(rc.colorStr) == "string" and rc.colorStr
        or string.format("ff%02x%02x%02x", (rc.r or 1) * 255, (rc.g or 1) * 255, (rc.b or 1) * 255)
    return "|c" .. hex .. name .. "|r"
end

-- One sample -> text, r, g, b (nil when it cannot be built).
local function BuildTestLine(d, frame)
    local info = type(_G.ChatTypeInfo) == "table" and (_G.ChatTypeInfo[d.kind == "CHANNEL" and ("CHANNEL" .. d.chan) or d.kind]
        or (d.kind == "CHANNEL" and _G.ChatTypeInfo.CHANNEL)) or nil
    local c = type(info) == "table" and info or TEST_FALLBACK_COLOR[d.kind] or { r = 1, g = 1, b = 1 }
    local msg = d.msg
    if Effective("urlCopy") then msg = Linkify(msg) end
    local text
    if d.kind == "SYSTEM" then
        text = msg
    else
        local link = "|Hplayer:" .. d.sender .. "|h[" .. TestColorName(d.sender, d.class) .. "]|h"
        if d.kind == "CHANNEL" then
            text = "|Hchannel:channel:" .. d.chan .. "|h[" .. d.chan .. ". " .. d.name .. "]|h " .. link .. ": " .. msg
            -- A wrapped frame shortens it in AddMessage (as for a real line); shortening twice would turn [LFG] into [4].
            if Effective("shortChannels") and not wrapped[frame] then text = ShortenChannelText(text) end
        else
            local get = _G["CHAT_" .. d.kind .. "_GET"]
            if type(get) ~= "string" then get = "%s: " end
            text = get:gsub("%%s", function() return link end, 1) .. msg
        end
    end
    local stamp = _G.CHAT_TIMESTAMP_FORMAT
    if Effective("timestamps") and type(stamp) == "string" and stamp ~= "" then
        text = date(stamp) .. text
    end
    return text, c.r or 1, c.g or 1, c.b or 1
end

local function ShowTestLines()
    local f = _G.DEFAULT_CHAT_FRAME or _G.ChatFrame1
    if type(f) ~= "table" or type(f.AddMessage) ~= "function" then Print("no main chat frame."); return end
    f:AddMessage("GaarChat test lines:", 1, 1, 0)
    Safe("test group", function()
        local g = AG.Group()
        f:AddMessage("autoGroupChannel would set the chat channel to " .. (g == "none" and "(nothing: not in a group)" or g)
            .. " on joining a group (nothing is changed)", 1, 1, 0)
    end)
    for _, d in ipairs(TEST_SAMPLES) do
        Safe("test line", function()
            local text, r, g, b = BuildTestLine(d, f)
            if text then f:AddMessage(text, r, g, b) end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

-- The intro GaarForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "Chat tweaks, each with its own switch: short channel names, class-coloured names, timestamps, clickable URLs, a copy button, a whisper sound, sticky channels, arrow keys without Alt and a scrolling feed of whispers, group chat and mentions of your name. Nice to know: click a URL to get it selected for Ctrl+C; /gchat copy [n] copies the last 200 lines of a chat frame; /gchat feed unlock lets you drag the feed, and a click on a feed line replies; /gchat off turns every tweak off at once."

local function PrintHelp()
    Print("Right-click the chat feed window while it is unlocked (/gchat feed unlock): this addon's menu (the same options as the hub menu).")
    Print(INTRO)
    Print("/gchat on | off - the master switch")
    for _, f in ipairs(FEATURES) do
        Print(string.format("/gchat %s on|off - %s (default %s)", f.key, f.label, f.default and "on" or "off"))
    end
    ns.Feed.PrintHelp()
    Print("/gchat copy [n] - copy the last " .. COPY_LINES .. " lines of chat frame n (default: the selected one)")
    Print("/gchat test - sample chat lines in the main chat frame, to show the tweaks (nothing is sent)")
    Print("/gchat status - the current state")
    Print("Right-click a chat tab: a GaarChat submenu at the bottom of Blizzard's tab menu holds the same options.")
end

local function PrintStatus()
    Print("version " .. VERSION .. "   addon: " .. (Enabled() and "on" or "off"))
    for _, f in ipairs(FEATURES) do
        Print(string.format("%s: %s", f.key, db[f.key] and "on" or "off"))
    end
    Print(AG.Text())
    Print(ns.Feed.StatusText())
    Print("last error: " .. (lastError or "none"))
end

local function FindFeature(name)
    for _, f in ipairs(FEATURES) do
        if f.key:lower() == name then return f end
    end
end

local function OnSlash(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then Print("not loaded yet."); return end
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = (cmd or ""):lower()
    arg = arg:lower()
    local feature = FindFeature(cmd)
    if cmd == "on" or cmd == "off" then
        SetEnabled(cmd == "on")
    elseif cmd == "feed" then
        ns.Feed.Slash(arg)
    elseif feature then
        if arg == "on" or arg == "off" then
            SetFeature(feature.key, arg == "on")
        else
            Print(string.format("%s is %s. /gchat %s on|off", feature.key, db[feature.key] and "on" or "off", feature.key))
        end
    elseif cmd == "copy" then
        local n = tonumber(arg)
        local f = n and _G["ChatFrame" .. math.floor(n)] or nil
        if n and not f then Print("no chat frame " .. arg .. "."); return end
        ShowCopy(f)
    elseif cmd == "test" then
        ShowTestLines()
    elseif cmd == "status" then
        PrintStatus()
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: GaarChatForeverAPI
--
-- For GaarForever's hub menu. Settings live in GaarChatForeverDB and change only through
-- the same functions /gchat uses.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "on . 8/9 features"
--   MenuEntries()        the options as plain data: { text, func }, { text, checkbox = true,
--                        checked, func }, { text, radio = true, checked, func }, { text, submenu }
--                        and { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    local n = 0
    for _, f in ipairs(FEATURES) do if db[f.key] then n = n + 1 end end
    return (Enabled() and "on" or "off") .. DOT .. n .. "/" .. #FEATURES .. " features"
end

local function MenuEntries()
    if not db then return {} end
    local list = { { text = "Chat tweaks", checkbox = true,
        checked = function() return Enabled() end,
        func = function() SetEnabled(not Enabled()) end }, { divider = true } }
    for _, f in ipairs(FEATURES) do
        list[#list + 1] = { text = f.label, checkbox = true,
            checked = function() return db and db[f.key] and true or false end,
            func = function() SetFeature(f.key, not db[f.key]) end }
    end
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Chat feed", submenu = ns.Feed.MenuEntries() }
    list[#list + 1] = { text = "Test: print sample chat lines", func = function() ShowTestLines() end }
    return list
end


-- ---------------------------------------------------------------------------
-- "GaarChat" submenu in the chat tab's right-click menu
--
-- Blizzard builds that menu in FloatingChatFrame (FCF_Tab_OnClick) with the tag MENU_FCF_TAB.
-- Menu.ModifyMenu is Blizzard's public way to add to a tagged menu: our callback runs after
-- Blizzard's generator and only appends a divider and a submenu of our own, the same options as
-- the hub menu (MenuEntries). Nothing of Blizzard's is replaced. A tag that does not exist, or a
-- client without Menu.ModifyMenu, just means no entry.
-- ---------------------------------------------------------------------------

local TAB_MENU_TAG = "MENU_FCF_TAB"
local tabMenuBroken

local function AddTabMenu(root)
    if tabMenuBroken or type(root) ~= "table" then return end
    local ok, err = pcall(function()
        if type(root.CreateDivider) == "function" then root:CreateDivider() end
        if type(root.CreateButton) ~= "function" then return end
        local sub = root:CreateButton("GaarChat")
        if type(sub) == "table" then BF.RenderMenu(sub, MenuEntries(), A.title) end
    end)
    if not ok then tabMenuBroken = true; Fail("tab menu", err) end
end

local function RegisterTabMenu()
    local menu = _G.Menu
    if type(menu) ~= "table" or type(menu.ModifyMenu) ~= "function" then return false end
    return (pcall(menu.ModifyMenu, TAB_MENU_TAG, function(_, root) AddTabMenu(root) end))
end
RegisterTabMenu()

_G.GaarChatForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries(), A.title) end,
    SetMinimapHidden = function() end,
}
_G.BetterChatForeverAPI = _G.GaarChatForeverAPI -- the name before the folder rename

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    BF.Migrate("GaarChatForeverDB", "BetterChatForeverDB") -- the old folder's settings, once (see Lib.lua)
    if type(GaarChatForeverDB) ~= "table" then GaarChatForeverDB = {} end
    db = GaarChatForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    if type(db.enabled) ~= "boolean" then db.enabled = true end
    for _, f in ipairs(FEATURES) do
        if type(db[f.key]) ~= "boolean" then db[f.key] = f.default end
    end
    if type(db.owned) ~= "table" then db.owned = {} end
    ns.Feed.Bind(db)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
for _, ev in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_ENABLED", "UPDATE_CHAT_WINDOWS", "CHAT_MSG_WHISPER", "CHAT_MSG_BN_WHISPER", "CVAR_UPDATE" }) do
    pcall(events.RegisterEvent, events, ev)
end
events:SetScript("OnEvent", function(_, event, arg1)
    -- Chat event arguments can be secret: the whisper branch below never reads them.
    if event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER" then
        if Effective("whisperSound") then Safe(event, PlayWhisperSound) end
        return
    end
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then BindSavedVariables() end
        elseif event == "PLAYER_LOGIN" then
            if not db then return end
            applied = true
            AddFilters()
            if type(_G.hooksecurefunc) == "function" and type(_G.ChatEdit_ActivateChat) == "function" then
                _G.hooksecurefunc("ChatEdit_ActivateChat", function(eb) Safe("activate", ApplyEditBox, eb) end)
            end
            if type(_G.hooksecurefunc) == "function" and type(_G.FCF_OpenTemporaryWindow) == "function" then
                _G.hooksecurefunc("FCF_OpenTemporaryWindow", function() Safe("temp", EnsureFrames) end)
            end
            EnsureFrames()
            ApplyAll()
        elseif event == "PLAYER_ENTERING_WORLD" or event == "UPDATE_CHAT_WINDOWS" then
            if applied then
                EnsureFrames()
                ApplyArrowKeys()
                if event == "PLAYER_ENTERING_WORLD" then
                    AG.Check()
                    ApplyFeature("classColors")     -- Blizzard loads its chat settings after login
                    ApplyFeature("timestamps")
                end
            end
        elseif event == "GROUP_ROSTER_UPDATE" then
            AG.Check()
        elseif event == "PLAYER_REGEN_ENABLED" then
            AG.Flush()
        elseif event == "CVAR_UPDATE" then
            -- Blizzard re-reads the cvar into CHAT_TIMESTAMP_FORMAT; put our grey back.
            if applied and arg1 == "showTimestamps" and Effective("timestamps") then
                _G.CHAT_TIMESTAMP_FORMAT = STAMP_COLOR .. "[%H:%M]|r "
            end
        end
    end)
    if not ok then Fail(event, err) end
end)

SLASH_GAARCHATFOREVER1 = "/gchat"
SLASH_GAARCHATFOREVER2 = "/gaarchatforever"
SLASH_GAARCHATFOREVER3 = "/bchat" -- the command before the Gaar rename
SLASH_GAARCHATFOREVER4 = "/betterchatforever"
SlashCmdList.GAARCHATFOREVER = function(msg)
    local ok, err = pcall(OnSlash, msg)
    if not ok then Fail("slash", err); Print("error: " .. tostring(err)) end
end
