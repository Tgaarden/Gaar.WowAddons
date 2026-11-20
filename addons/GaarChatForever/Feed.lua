--[[
  GaarChatForever - the chat feed (feature key "feed", /gchat feed ...).

  Whispers (in and out, Battle.net too), party / raid / instance chat (leaders and raid warnings
  included) and lines where someone says your name in say, yell, emote or a public channel show
  up in a small area of the screen, like scrolling combat text: each new line comes in at the
  bottom, the older ones slide up, and every line fades out after a few seconds (10 by default).
  At most MAX_LINES are shown; the oldest is pushed out. The mouse over the feed pauses it.
  A click on a line opens a reply: a whisper (or Battle.net whisper) to that person, or the
  edit box on that group chat type. The regular chat frames are not touched: this only shows
  copies.

  Secret text. On the 12.x engine a message, its sender, the GUID and the channel index can be
  secret values in instances and in combat. None of them is compared, concatenated, searched or
  lowered here before IsSecret says it is plain:
    - A plain message from a plain sender is drawn as one word-wrapped line,
      "[P] Name: text", in a single FontString.
    - Anything secret is drawn in four single-line FontStrings (tag, name, ":", text), each
      given its value with SetText, which accepts secret values; the text is cut to the width
      of the feed with "..." because its wrapped height cannot be read.
    - A secret message is never checked for your name, so mentions need plain text.
    - A click replies by name only when the name is plain; a secret whisper falls back to
      Blizzard's reply-to-last-whisper.

  Taint: nothing Blizzard owns is written. The feed has its own frames and events; the chat
  frames, their filters and the edit box are only used through Blizzard's own open-chat calls,
  each in pcall.

  Performance: the event handler only looks up the event in a table and returns unless the
  category is on (mention matching runs only for say / yell / emote / channel, with mentions on).
  Events are registered only for the categories that are on. The animation is one OnUpdate on
  the feed frame, set while a line is shown and cleared with the last one.

  Loaded after GaarChatForever.lua (see the .toc), which hands over its helpers in the addon's
  namespace table (ns.Print, ns.Safe, ns.SetFeature, ns.Effective, ns.GetDB).
]]

local _G = _G
local _, ns = ...
ns = ns or {}

local BF = _G.GaarForever
local Secret = BF.IsSecret

local Feed = {}
ns.Feed = Feed

local MAX_LINES = 8
local SPACING = 2           -- between lines
local PAD = 4               -- inside the feed area
local FADE_IN = 0.25        -- seconds
local SLIDE_MAX = 300       -- pixels a burst of lines may queue up

local DEFAULTS = {
    whispers = true, group = true, mentions = true, locked = true,
    point = "LEFT", relPoint = "LEFT", x = 40, y = 0,
    scale = 100, font = 14, width = 400, time = 10,
}
local RANGES = { scale = { 50, 200 }, font = { 8, 32 }, width = { 200, 800 }, time = { 3, 60 } }
local LAYOUT_KEYS = { "point", "relPoint", "x", "y", "scale", "font", "width", "time" }
local POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

local CATEGORIES = {
    { key = "whispers", label = "Whispers (in and out)" },
    { key = "group",    label = "Party, raid and instance chat" },
    { key = "mentions", label = "Mentions of your name" },
}

-- Chat type -> tag, category, how a click replies (reply = "tell" / "bn", or slash = an open-chat
-- command), out = your own outgoing whisper, mention = shown only when the text says your name.
local TYPES = {
    WHISPER              = { tag = "W",  cat = "whispers", reply = "tell" },
    WHISPER_INFORM       = { tag = "To", cat = "whispers", reply = "tell", out = true },
    BN_WHISPER           = { tag = "BN", cat = "whispers", reply = "bn" },
    BN_WHISPER_INFORM    = { tag = "To", cat = "whispers", reply = "bn", out = true },
    PARTY                = { tag = "P",  cat = "group", slash = "/p " },
    PARTY_LEADER         = { tag = "P",  cat = "group", slash = "/p " },
    RAID                 = { tag = "R",  cat = "group", slash = "/raid " },
    RAID_LEADER          = { tag = "R",  cat = "group", slash = "/raid " },
    RAID_WARNING         = { tag = "RW", cat = "group", slash = "/rw " },
    INSTANCE_CHAT        = { tag = "I",  cat = "group", slash = "/i " },
    INSTANCE_CHAT_LEADER = { tag = "I",  cat = "group", slash = "/i " },
    SAY                  = { tag = "@",  cat = "mentions", reply = "tell", mention = true },
    YELL                 = { tag = "@",  cat = "mentions", reply = "tell", mention = true },
    EMOTE                = { tag = "@",  cat = "mentions", reply = "tell", mention = true },
    CHANNEL              = { tag = "@",  cat = "mentions", reply = "tell", mention = true },
}
local EVENT_TYPE = {}       -- "CHAT_MSG_PARTY" -> "PARTY"
for chatType in pairs(TYPES) do EVENT_TYPE["CHAT_MSG_" .. chatType] = chatType end

local opts                  -- GaarChatForeverDB.feedOpts, bound in Feed.Bind
local active = false        -- the feed is on (master switch and its own switch)
local frame                 -- the feed area, built on first use
local lines = {}            -- shown lines, oldest first
local pool = {}             -- hidden lines for reuse
local slide = 0             -- pixels the newest line is still below its place
local lineH = 16            -- the height of one text line at the current font size
local playerName, playerNameLower, playerGUID, playerFull

local function Print(msg) if ns.Print then ns.Print(msg) end end
local function Safe(where, fn, ...)
    if ns.Safe then return ns.Safe(where, fn, ...) end
    return pcall(fn, ...)
end

local function Clamp(v, range)
    v = tonumber(v)
    if not v then return nil end
    return math.max(range[1], math.min(range[2], math.floor(v + 0.5)))
end

-- ---------------------------------------------------------------------------
-- Reading the event arguments (every one checked with Secret first)
-- ---------------------------------------------------------------------------

local function LoadPlayer()
    if playerName then return end
    local n = type(_G.UnitName) == "function" and _G.UnitName("player") or nil
    if not Secret(n) and type(n) == "string" and n ~= "" then
        playerName, playerNameLower = n, n:lower()
    end
    playerFull = BF.PlayerFullName and BF.PlayerFullName() or playerFull
    local g = type(_G.UnitGUID) == "function" and _G.UnitGUID("player") or nil
    if not Secret(g) and type(g) == "string" then playerGUID = g end
end

-- A letter, digit or underscore, or any byte of a multi-byte (UTF-8) character.
local function IsWordByte(b)
    return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
        or b == 95 or b >= 128)
end

-- Your name as a whole word, any case. A secret message is never searched.
local function Mentions(msg)
    if Secret(msg) or type(msg) ~= "string" or not playerNameLower then return false end
    local text, name, start = msg:lower(), playerNameLower, 1
    while true do
        local s, e = text:find(name, start, true)
        if not s then return false end
        if not IsWordByte(s > 1 and text:byte(s - 1) or nil) and not IsWordByte(text:byte(e + 1)) then
            return true
        end
        start = s + 1
    end
end

-- Your own message. Unknown (both secret) counts as someone else's.
local function IsOwn(guid, sender)
    if not Secret(guid) and type(guid) == "string" and guid ~= "" then
        return playerGUID ~= nil and guid == playerGUID
    end
    -- 1.2.2: a sender is "First Surname" where UnitName may give only the first name.
    if not Secret(sender) and type(sender) == "string" and (playerFull or playerName) then
        if BF.NamesMatch then return BF.NamesMatch(sender, playerFull or playerName) end
        return (sender:match("^([^%-]+)") or sender) == playerName
    end
    return false
end

-- The name to show: secret names as they are, plain ones without the realm.
local function ShowName(sender, t)
    if Secret(sender) then return sender end
    if type(sender) ~= "string" or sender == "" then return "?" end
    if t.reply == "bn" then return sender end        -- a Battle.net name token, drawn by the client
    local amb = _G.Ambiguate
    if type(amb) == "function" then
        local ok, s = pcall(amb, sender, "short")
        if ok and not Secret(s) and type(s) == "string" and s ~= "" then return s end
    end
    return sender:match("^([^%-]+)") or sender
end

local function ClassColor(guid, class)
    if not class then
        local get = _G.GetPlayerInfoByGUID
        if Secret(guid) or type(guid) ~= "string" or guid == "" or type(get) ~= "function" then return nil end
        local ok, _, c = pcall(get, guid)
        if not ok or Secret(c) or type(c) ~= "string" then return nil end
        class = c
    end
    local colors = _G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS
    local c = type(colors) == "table" and colors[class] or nil
    if type(c) ~= "table" or type(c.r) ~= "number" then return nil end
    return c.r, c.g, c.b
end

local function TypeColor(chatType, chanIndex)
    local info = _G.ChatTypeInfo
    if type(info) ~= "table" then return 1, 1, 1 end
    local e
    if chatType == "CHANNEL" and not Secret(chanIndex) and type(chanIndex) == "number" and chanIndex > 0 then
        e = info["CHANNEL" .. chanIndex]
    end
    e = type(e) == "table" and e or info[chatType]
    if type(e) == "table" and type(e.r) == "number" then return e.r, e.g or 1, e.b or 1 end
    return 1, 1, 1
end

local function Hex(r, g, b)
    return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5))
end

-- ---------------------------------------------------------------------------
-- Replying on a click
-- ---------------------------------------------------------------------------

local function ChatAPI(globalName, utilName)
    local f = _G[globalName]
    if type(f) == "function" then return f end
    local u = _G.ChatFrameUtil
    if type(u) == "table" and type(u[utilName]) == "function" then return u[utilName] end
end

local function ChatFrame() return _G.SELECTED_CHAT_FRAME or _G.DEFAULT_CHAT_FRAME end

local function Reply(d)
    local t = TYPES[d.chatType]
    if not t then return end
    if t.slash then
        local open = ChatAPI("ChatFrame_OpenChat", "OpenChat")
        if open then open(t.slash, ChatFrame()) end
        return
    end
    if d.target then
        local send = t.reply == "bn" and ChatAPI("ChatFrame_SendBNetTell", "SendBNetTell")
            or ChatAPI("ChatFrame_SendTell", "SendTell")
        if send then send(d.target, ChatFrame()) end
    elseif t.cat == "whispers" then
        -- The name is secret: Blizzard's reply to the last whisper (the R key) instead.
        local reply = ChatAPI("ChatFrame_ReplyTell", "ReplyTell")
        if reply then reply(ChatFrame()) end
    end
end

local function OnLineClick(self)
    local d = self.data
    if not d or d.test then return end
    Safe("feed click", Reply, d)
end

-- ---------------------------------------------------------------------------
-- Lines
-- ---------------------------------------------------------------------------

local function FontPath()
    local cf = _G.ChatFontNormal
    if type(cf) == "table" and type(cf.GetFont) == "function" then
        local ok, path = pcall(cf.GetFont, cf)
        if ok and type(path) == "string" and path ~= "" then return path end
    end
    return _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function SetFont(fs)
    -- SetFont says false when the file cannot be used (older clients say nothing).
    if fs:SetFont(FontPath(), opts.font, "OUTLINE") == false then
        fs:SetFont(_G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", opts.font, "OUTLINE")
    end
end

local function LineFonts(b)
    for _, fs in ipairs(b.strings) do SetFont(fs) end
end

local function NewLine()
    local b = CreateFrame("Button", nil, frame)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", OnLineClick)
    local function fs()
        local s = b:CreateFontString(nil, "OVERLAY")
        s:SetJustifyH("LEFT")
        s:SetShadowOffset(1, -1)
        return s
    end
    -- Plain lines: one word-wrapped string.
    b.full = fs()
    b.full:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b.full:SetJustifyV("TOP")
    b.full:SetWordWrap(true)
    -- Lines with a secret part: tag, name, ":" and text side by side, one line.
    b.tag, b.name, b.sep, b.body = fs(), fs(), fs(), fs()
    b.tag:SetPoint("LEFT", b, "LEFT", 0, 0)
    b.name:SetPoint("LEFT", b.tag, "RIGHT", 4, 0)
    b.sep:SetPoint("LEFT", b.name, "RIGHT", 0, 0)
    b.body:SetPoint("LEFT", b.sep, "RIGHT", 4, 0)
    b.body:SetPoint("RIGHT", b, "RIGHT", 0, 0)
    b.body:SetWordWrap(false)
    if b.body.SetMaxLines then b.body:SetMaxLines(1) end
    b.strings = { b.full, b.tag, b.name, b.sep, b.body }
    LineFonts(b)
    return b
end

local function LineWidth() return opts.width - 2 * PAD end

-- Width and height of one line for the current font and width.
local function Measure(b)
    local w = LineWidth()
    b:SetWidth(w)
    if b.plain then
        b.full:SetWidth(w)
        if b.full.SetMaxLines then b.full:SetMaxLines(0) end
        local h = b.full:GetStringHeight()
        if Secret(h) or type(h) ~= "number" or h <= 0 then
            -- Not readable: keep it to one line so the stack stays right.
            if b.full.SetMaxLines then b.full:SetMaxLines(1) end
            h = lineH
        end
        b:SetHeight(math.ceil(h))
    else
        b:SetHeight(lineH)
    end
end

local function MeasureLineHeight()
    local p = frame.probe
    SetFont(p)
    p:SetText("Ag")
    local h = p:GetStringHeight()
    if Secret(h) or type(h) ~= "number" or h <= 0 then h = opts.font * 1.2 end
    lineH = math.ceil(h)
end

-- Lines are chained bottom-up: the newest sits on the bottom of the feed (minus the slide still
-- to go), each older one on top of the one after it.
local function AnchorNewest()
    local b = lines[#lines]
    if not b then return end
    b:ClearAllPoints()
    b:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD - slide)
end

local function Chain()
    for k = 1, #lines - 1 do
        local b = lines[k]
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", lines[k + 1], "TOPLEFT", 0, SPACING)
    end
    AnchorNewest()
end

local function RemoveOldest()
    local b = table.remove(lines, 1)
    if not b then return end
    b:Hide()
    b:ClearAllPoints()
    b.data = nil
    pool[#pool + 1] = b
end

local function ClearLines()
    while #lines > 0 do RemoveOldest() end
    slide = 0
    if frame then frame:SetScript("OnUpdate", nil) end
end

local function IsHovered()
    if frame:IsMouseOver() then return true end
    for k = 1, #lines do
        if lines[k]:IsMouseOver() then return true end
    end
    return false
end

local function OnUpdate(_, elapsed)
    local hover = IsHovered()
    local T = opts.time
    if not hover then
        for k = 1, #lines do lines[k].age = lines[k].age + elapsed end
        while lines[1] and lines[1].age >= T do RemoveOldest() end
        if slide > 0 and #lines > 0 then
            slide = math.max(0, slide - math.max(slide * 8, 40) * elapsed)
            AnchorNewest()
        end
    end
    if #lines == 0 then
        slide = 0
        frame:SetScript("OnUpdate", nil)
        return
    end
    local fadeOut = math.min(2, T * 0.3)
    for k = 1, #lines do
        local b, a = lines[k], 1
        if not hover then
            if b.age < FADE_IN then a = b.age / FADE_IN end
            if b.age > T - fadeOut then a = math.min(a, (T - b.age) / fadeOut) end
        end
        b:SetAlpha(math.max(0, math.min(1, a)))
    end
end

-- d: chatType, msg, sender, guid, chanIndex, and for test lines test = true and class.
local function AddLine(d)
    if not frame or not active then return end
    local t = TYPES[d.chatType]
    if not t then return end
    if #lines >= MAX_LINES then RemoveOldest() end
    local b = table.remove(pool) or NewLine()
    local r, g, bl = TypeColor(d.chatType, d.chanIndex)
    local cr, cg, cb = ClassColor(d.guid, d.class)
    local name = ShowName(d.sender, t)
    -- Plain sender: kept for a click's reply (with the realm). A secret one is never kept.
    d.target = (not Secret(d.sender) and type(d.sender) == "string" and d.sender ~= "") and d.sender or nil
    b.plain = not Secret(d.msg) and not Secret(name)
    if b.plain then
        local name2 = cr and (Hex(cr, cg, cb) .. name .. "|r") or name
        local msg = type(d.msg) == "string" and d.msg or ""
        b.full:SetTextColor(r, g, bl)
        b.full:SetText("[" .. t.tag .. "] " .. name2 .. ": " .. msg)
        b.full:Show()
        b.tag:Hide(); b.name:Hide(); b.sep:Hide(); b.body:Hide()
    else
        b.tag:SetText("[" .. t.tag .. "]")
        b.tag:SetTextColor(r, g, bl)
        b.name:SetText(name)                       -- may be secret: SetText takes it as it is
        if cr then b.name:SetTextColor(cr, cg, cb) else b.name:SetTextColor(r, g, bl) end
        b.sep:SetText(":")
        b.sep:SetTextColor(r, g, bl)
        b.body:SetText(d.msg)                      -- may be secret
        b.body:SetTextColor(r, g, bl)
        b.full:Hide()
        b.tag:Show(); b.name:Show(); b.sep:Show(); b.body:Show()
    end
    b.data = d
    b.age = 0
    b:EnableMouse(opts.locked and true or false)
    Measure(b)
    b:SetAlpha(0)
    b:Show()
    lines[#lines + 1] = b
    slide = math.min(SLIDE_MAX, slide + b:GetHeight() + SPACING)
    Chain()
    frame:SetScript("OnUpdate", OnUpdate)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- CHAT_MSG_* arguments: 1 text, 2 sender, 8 channel index, 12 sender GUID.
local function OnEvent(_, event, msg, sender, _, _, _, _, _, chanIndex, _, _, _, guid)
    local chatType = EVENT_TYPE[event]
    if not chatType or not active then return end
    local t = TYPES[chatType]
    if not opts[t.cat] then return end
    if t.mention then
        if not Mentions(msg) then return end       -- false for secret text
        if IsOwn(guid, sender) then return end
    elseif not t.out and IsOwn(guid, sender) then
        return
    end
    Safe("feed " .. chatType, AddLine,
        { chatType = chatType, msg = msg, sender = sender, guid = guid, chanIndex = chanIndex })
end

local function RegisterEvents()
    frame:UnregisterAllEvents()
    if not active then return end
    for chatType, t in pairs(TYPES) do
        if opts[t.cat] then pcall(frame.RegisterEvent, frame, "CHAT_MSG_" .. chatType) end
    end
end

-- ---------------------------------------------------------------------------
-- The feed area: position, size, lock
-- ---------------------------------------------------------------------------

local function SavePosition()
    local p, _, rp, x, y = frame:GetPoint(1)
    if POINTS[p] and POINTS[rp] and type(x) == "number" and type(y) == "number" then
        opts.point, opts.relPoint = p, rp
        opts.x, opts.y = math.floor(x + 0.5), math.floor(y + 0.5)
    end
end

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "GaarChatForeverFeed", UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    if type(BF.AttachMenu) == "function" then
        BF.AttachMenu(frame, { title = "GaarChatForever", api = "GaarChatForeverAPI", hook = true }) -- right-click: the addon's menu
    end
    frame:SetScript("OnDragStart", function(self) if not opts.locked then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        Safe("feed move", SavePosition)
    end)
    frame:SetScript("OnEvent", OnEvent)
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(0, 0, 0, 0.45)
    frame.label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.label:SetPoint("TOP", frame, "TOP", 0, -PAD)
    frame.label:SetText("GaarChatForever feed: drag to move, /gchat feed lock")
    frame.probe = frame:CreateFontString(nil, "OVERLAY")
    frame.probe:Hide()
end

local function ApplyLock()
    local unlocked = not opts.locked
    frame.bg:SetShown(unlocked)
    frame.label:SetShown(unlocked)
    frame:EnableMouse(unlocked)
    -- Locked: the lines take clicks. Unlocked: the whole area drags.
    for k = 1, #lines do lines[k]:EnableMouse(not unlocked) end
end

local function ApplyLayout()
    frame:SetScale(opts.scale / 100)
    frame:ClearAllPoints()
    frame:SetPoint(opts.point, UIParent, opts.relPoint, opts.x, opts.y)
    MeasureLineHeight()
    frame:SetSize(opts.width, MAX_LINES * (lineH + SPACING) + 2 * PAD)
    for k = 1, #lines do
        LineFonts(lines[k])
        Measure(lines[k])
    end
    for _, b in ipairs(pool) do LineFonts(b) end
    Chain()
    ApplyLock()
end

-- ---------------------------------------------------------------------------
-- Settings (GaarChatForeverDB.feedOpts)
-- ---------------------------------------------------------------------------

function Feed.Bind(db)
    local o = type(db.feedOpts) == "table" and db.feedOpts or {}
    for k in pairs(o) do
        if DEFAULTS[k] == nil then o[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if type(o[k]) ~= type(v) then o[k] = v end
    end
    for k, range in pairs(RANGES) do o[k] = Clamp(o[k], range) or DEFAULTS[k] end
    if not POINTS[o.point] or not POINTS[o.relPoint] then
        o.point, o.relPoint, o.x, o.y = DEFAULTS.point, DEFAULTS.relPoint, DEFAULTS.x, DEFAULTS.y
    end
    db.feedOpts = o
    opts = o
end

-- on: the feed feature is in effect (master switch and its own switch).
function Feed.Apply(on)
    if not opts then return end
    active = on and true or false
    if active then
        LoadPlayer()
        Build()
        ApplyLayout()
        frame:Show()
        RegisterEvents()
    elseif frame then
        frame:UnregisterAllEvents()
        ClearLines()
        frame:Hide()
    end
end

local function Say(quiet, msg) if not quiet then Print(msg) end end

local function SetCategory(key, v, quiet)
    opts[key] = v and true or false
    if frame then RegisterEvents() end
    Say(quiet, "feed " .. key .. ": " .. BF.OnOff(opts[key]))
end

local function SetLocked(v, quiet)
    opts.locked = v and true or false
    if frame then ApplyLock() end
    local hint = ""
    if not opts.locked and not active then hint = " (the feed is off: /gchat feed on)" end
    Say(quiet, "feed " .. (opts.locked and "locked" or "unlocked: drag it, then /gchat feed lock") .. hint)
end

local UNITS = { scale = "%", font = "", width = " px", time = " s" }

local function SetNumber(key, v, quiet)
    local n = Clamp(v, RANGES[key])
    if not n then Print("feed " .. key .. ": give a number from " .. RANGES[key][1] .. " to " .. RANGES[key][2] .. "."); return end
    opts[key] = n
    if frame and active then ApplyLayout() end
    Say(quiet, "feed " .. key .. ": " .. n .. UNITS[key])
end

local function Reset(quiet)
    for _, k in ipairs(LAYOUT_KEYS) do opts[k] = DEFAULTS[k] end
    if frame and active then ApplyLayout() end
    Say(quiet, "feed position, scale, font size, width and fade time reset.")
end

local function Test()
    if not active then
        Print("the feed is off" .. ((ns.GetDB and ns.GetDB() and not ns.GetDB().enabled) and " (master switch is off)" or "")
            .. ": /gchat feed on")
        return
    end
    LoadPlayer()
    local me = playerName or "you"
    local samples = {
        { chatType = "WHISPER",        sender = "Jaina",     class = "MAGE",    msg = "Up for Scholomance after this?" },
        { chatType = "WHISPER_INFORM", sender = "Thrall",    class = "SHAMAN",  msg = "Sure, give me five minutes." },
        { chatType = "PARTY_LEADER",   sender = "Uther",     class = "PALADIN", msg = "Pull after the next patrol." },
        { chatType = "RAID",           sender = "Sylvanas",  class = "HUNTER",  msg = "Tranq shot is on me." },
        { chatType = "RAID_WARNING",   sender = "Bolvar",    class = "WARRIOR", msg = "Stack on the tank!" },
        { chatType = "INSTANCE_CHAT",  sender = "Anduin",    class = "PRIEST",  msg = "Need mana, drinking." },
        { chatType = "BN_WHISPER",     sender = "Friend",                       msg = "Are you online tonight?" },
        { chatType = "SAY",            sender = "Varian",    class = "WARRIOR", msg = "Hey " .. me .. ", nice gear!" },
    }
    for _, d in ipairs(samples) do
        d.test = true
        Safe("feed test", AddLine, d)
    end
end

function Feed.StatusText()
    if not opts then return "feed: not loaded yet" end
    local cats = {}
    for _, c in ipairs(CATEGORIES) do cats[#cats + 1] = c.key .. " " .. BF.OnOff(opts[c.key]) end
    return string.format("feed: %s, %s, %s, scale %d%%, font %d, width %d, fade %d s, at %s %d,%d",
        BF.OnOff(active), table.concat(cats, ", "), opts.locked and "locked" or "unlocked",
        opts.scale, opts.font, opts.width, opts.time, opts.point, opts.x, opts.y)
end

function Feed.PrintHelp()
    Print("/gchat feed - the feed's state and these commands")
    Print("/gchat feed whispers|group|mentions on|off - what it shows (all on by default)")
    Print("/gchat feed lock | unlock - unlock to drag it")
    Print("/gchat feed scale <50-200> | font <8-32> | width <200-800> | time <3-60> - size, text, width, seconds a line stays")
    Print("/gchat feed test - sample lines; /gchat feed reset - position and size back to default")
end

-- arg: the rest of "/gchat feed ...", lower case.
function Feed.Slash(arg)
    if not opts then Print("not loaded yet."); return end
    local sub, val = (arg or ""):match("^(%S*)%s*(.-)$")
    sub = sub or ""
    if sub == "" or sub == "status" then
        Print(Feed.StatusText())
        Feed.PrintHelp()
    elseif sub == "on" or sub == "off" then
        if ns.SetFeature then ns.SetFeature("feed", sub == "on") end
    elseif sub == "lock" or sub == "unlock" then
        SetLocked(sub == "lock")
    elseif RANGES[sub] then
        if val == "" then
            Print("feed " .. sub .. " is " .. opts[sub] .. UNITS[sub] .. ". /gchat feed " .. sub
                .. " <" .. RANGES[sub][1] .. "-" .. RANGES[sub][2] .. ">")
        else
            SetNumber(sub, val)
        end
    elseif sub == "reset" then
        Reset()
    elseif sub == "test" then
        Test()
    elseif opts[sub] ~= nil and (sub == "whispers" or sub == "group" or sub == "mentions") then
        if val == "on" or val == "off" then
            SetCategory(sub, val == "on")
        else
            Print("feed " .. sub .. " is " .. BF.OnOff(opts[sub]) .. ". /gchat feed " .. sub .. " on|off")
        end
    else
        Feed.PrintHelp()
    end
end

-- The feed's part of the hub menu and the Options page (a submenu; the on/off switch is the
-- "feed" checkbox among the features).
function Feed.MenuEntries()
    if not opts then return {} end
    local list = {}
    for _, c in ipairs(CATEGORIES) do
        list[#list + 1] = { text = c.label, checkbox = true,
            checked = function() return opts[c.key] and true or false end,
            func = function() SetCategory(c.key, not opts[c.key]) end }
    end
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Locked (untick to drag it)", checkbox = true,
        checked = function() return opts.locked and true or false end,
        func = function() SetLocked(not opts.locked) end }
    list[#list + 1] = { text = "Font size", slider = true, min = 8, max = 32, step = 1,
        value = function() return opts.font end, set = function(v) SetNumber("font", v, true) end }
    list[#list + 1] = { text = "Scale", slider = true, min = 50, max = 200, step = 10,
        value = function() return opts.scale end, set = function(v) SetNumber("scale", v, true) end,
        format = function(v) return v .. "%" end }
    list[#list + 1] = { text = "Width", slider = true, min = 200, max = 800, step = 25,
        value = function() return opts.width end, set = function(v) SetNumber("width", v, true) end }
    list[#list + 1] = { text = "Seconds on screen", slider = true, min = 3, max = 60, step = 1,
        value = function() return opts.time end, set = function(v) SetNumber("time", v, true) end,
        format = function(v) return v .. " s" end }
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Show test lines", func = function() Test() end }
    list[#list + 1] = { text = "Reset position and size", func = function() Reset() end }
    return list
end
