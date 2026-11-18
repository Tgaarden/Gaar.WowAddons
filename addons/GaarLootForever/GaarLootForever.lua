--[[
  GaarLootForever - who chose Need, Greed or Pass on a group loot roll, on WoW Forever.

  What it does, each part with its own switch (saved in GaarLootForeverDB, changed with
  /glf <feature> on|off, from the GaarForever hub menu or its Options page):

    * enabled   master switch for everything below.
    * counts    (default on) a small white, outlined number in the bottom-right corner of the
                Need, Greed and Pass buttons (and Transmog, where the client shows it) of each
                open roll: how many group members chose that option for that roll. Hidden at 0.
    * names     (default on) hovering a button adds a line to its own tooltip with who chose it,
                e.g. "Need: Elex, Bob". Blizzard's tooltip (the button name, the reason it is
                disabled) stays as it is; the line is appended.
    * summary   (default on, 1.1.0) the client closes the roll frame once you have chosen, so a
                small movable panel lists the recent rolls instead: the item (icon and coloured
                name; hover for the item tooltip), one line per choice with its count and who
                ("Need 2  Elex 87, Mira 42": the number each player rolled, from the "Need Roll -
                87 for [item] by Elex" lines; Disenchant is counted with Greed and marked (DE)),
                and the result ("» Elex", "all passed"). Long lines are cut; hover them for the
                full list. The newest roll is on top, the last N are kept (rolls, 1..10, default
                5). Shown only in a group; drag it to move it (saved), /glf reset puts it back.
                The close button clears it; it comes back with the next roll.
    * autohide  (default on) the summary clears itself 60 seconds after the last of its rolls has
                finished (result line, or roll time over).
    * /glf test  a preview window with three fake buttons and counts, built from the client's
                own chat strings run through the same parser (the results are printed too), and
                three fake finished rolls in the summary. The real roll frame cannot be opened
                without a real roll, so it is never touched.
    * GaarLootForeverAPI, the small global table the GaarForever hub reads (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden, Intro).

  Where the choices come from. No event hands an addon the other players' choices for a rollID:
    1. CHAT_MSG_LOOT (and CHAT_MSG_SYSTEM) lines built from the client's own LOOT_ROLL_* format
       strings ("%s has selected Need for: %s", "You passed on: %s", ...). The patterns are made
       from those globals at load (magic characters escaped, %s / %d / %1$s turned into captures),
       so the client's locale is followed. Each line names the item; it goes to the oldest open
       roll of that item (GetLootRollItemLink) where that player has not chosen yet, so two rolls
       of the same item are told apart. A player counts once per roll; the latest choice wins.
       Your own choice counts too.
    2. C_LootHistory (LOOT_HISTORY_UPDATE_DROP), where the client fills it: the drop's roll states
       per player, matched to the open roll by item link. It is keyed by boss encounter, so on
       trash it says nothing; the chat lines cover those. Both write the same table.
  A roll is forgotten when its result line arrives (won, everyone passed), at
  CANCEL_ALL_LOOT_ROLLS, or once its roll time is over. CANCEL_LOOT_ROLL (sent when you have
  chosen) only stops the display: the roll stays known, so a late line for it is not given to a
  second roll of the same item. The summary keeps its own list of the same roll tables, so a
  forgotten roll is still shown there, with its winner, until the summary is cleared.

  The roll frame (Blizzard_UIPanels_Game, Mainline GroupLootFrame.xml on this client):
  GroupLootFrame1..4 inside GroupLootContainer, each with .rollID and the buttons
  .LootButtonContainer.NeedButton / GreedButton / PassButton / TransmogButton. Older layouts
  (frame.NeedButton, GroupLootFrame1NeedButton) are tried as fallbacks. Every lookup is guarded.

  Taint and safety: no Blizzard function is replaced. The number lives on a frame of this addon's
  own, a child of the button with the mouse off, so clicks still reach the button; the tooltip
  line comes from HookScript("OnEnter"), which runs after Blizzard's handler. Every handler runs
  in pcall, every client API is checked with type(...) first, and a secret value (chat text and
  names can be secret in some contexts) is never compared or tested: it is skipped.
]]

local _G = _G
local VERSION = "1.2.2"
local DOT = " \194\183 "

local BF = _G.GaarForever
local IsSecret, Num, Str, Bool, API, Call = BF.IsSecret, BF.Num, BF.Str, BF.Bool, BF.API, BF.Call
local OnOff = BF.OnOff

local INTRO = "Puts a small number on the Need, Greed and Pass buttons of a group loot roll: how many in "
    .. "the group chose that option for that roll. Hover a button to see who. Nice to know: the counts "
    .. "come from the loot chat lines (and the loot history where the client has it), so they fill in as "
    .. "people choose. Once you have chosen, a small summary panel lists the last rolls: who chose "
    .. "what, the numbers rolled and who won. Drag it to move it; /glf test shows a preview."

local A = BF.NewAddon("GaarLootForever", { title = "GaarLootForever", version = VERSION, intro = INTRO })

local FRAMES = 4                  -- GroupLootFrame1..4
local GRACE = 10                  -- seconds a roll is kept after its roll time
local DEFAULT_ROLL_TIME = 60      -- seconds, when START_LOOT_ROLL gives none
local AUTOHIDE = 60               -- seconds after the last roll in the summary finished
local SUMMARY_W = 250             -- summary panel width

-- The buttons, in display order: bucket, the key on the frame, the label in the tooltip line.
local BUTTONS = {
    { bucket = "need", key = "NeedButton", label = _G.NEED or "Need" },
    { bucket = "greed", key = "GreedButton", label = _G.GREED or "Greed" },
    { bucket = "transmog", key = "TransmogButton", label = _G.TRANSMOGRIFICATION or "Transmog" },
    { bucket = "pass", key = "PassButton", label = _G.PASS or "Pass" },
}
-- A choice's bucket: disenchant is counted with greed (same tier), marked "(DE)" in the tooltip.
local BUCKET = { need = "need", greed = "greed", disenchant = "greed", transmog = "transmog", pass = "pass" }

local rolls = {}                  -- [rollID] = roll
local drops = {}                  -- ["encounterID:lootListKey"] = rollID (loot history)
local refreshQueued = false

local function Enabled() return A:Get("enabled") ~= false end
local function Flag(key) return Enabled() and A:Get(key) == true end

local function Now()
    return Num(Call(API("GetTime"))) or 0
end

local function After(sec, fn)
    local f = API("C_Timer", "After")
    if f then pcall(f, sec, fn) else pcall(fn) end
end

local function Me()
    return Str((Call(API("UnitName"), "player"))) or "You"
end

-- "Name-Realm" -> "Name": the key a player is counted under (chat and loot history agree on it).
local function ShortName(name)
    name = Str(name)
    if not name then return nil end
    return name:match("^([^%-]+)") or name
end

local function ItemID(link)
    link = Str(link)
    return link and tonumber(link:match("item:(%d+)")) or nil
end

-- ---------------------------------------------------------------------------
-- Chat patterns from the client's own format strings
-- ---------------------------------------------------------------------------

-- Turns a format string into an anchored Lua pattern. Returns the pattern, the argument index of
-- each capture in order (so "%2$s ... %1$s" is put back in argument order) and the length of the
-- literal text (longer = more specific, tried first). nil for anything that is not a string.
local function Compile(fmt)
    fmt = Str(fmt)
    if not fmt then return nil end
    local out, args, literal = { "^" }, {}, 0
    local i, n, seq = 1, #fmt, 0
    while i <= n do
        local p = fmt:find("%", i, true)
        local text = fmt:sub(i, (p or n + 1) - 1)
        if text ~= "" then
            out[#out + 1] = (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
            literal = literal + #text
        end
        if not p then break end
        local pos, kind, nextI = fmt:match("^(%d+)%$([sd])()", p + 1)
        if not pos then
            kind, nextI = fmt:match("^([sd])()", p + 1)
        end
        if kind then
            if pos then pos = tonumber(pos) else seq = seq + 1; pos = seq end
            out[#out + 1] = kind == "d" and "(%d+)" or "(.-)"
            args[#args + 1] = pos
            i = nextI
        elseif fmt:sub(p + 1, p + 1) == "%" then
            out[#out + 1] = "%%"
            literal = literal + 1
            i = p + 2
        else
            out[#out + 1] = "%%"
            literal = literal + 1
            i = p + 1
        end
    end
    out[#out + 1] = "$"
    return table.concat(out), args, literal
end

-- global name, what it means, the fields in argument order.
local RULE_DEFS = {
    { "LOOT_ROLL_NEED", "choice", { "player", "item" }, choice = "need" },
    { "LOOT_ROLL_NEED_SELF", "choice", { "item" }, choice = "need", self = true },
    { "LOOT_ROLL_NEED_OFF_SPEC", "choice", { "player", "item" }, choice = "need" },
    { "LOOT_ROLL_NEED_SELF_OFF_SPEC", "choice", { "item" }, choice = "need", self = true },
    { "LOOT_ROLL_GREED", "choice", { "player", "item" }, choice = "greed" },
    { "LOOT_ROLL_GREED_SELF", "choice", { "item" }, choice = "greed", self = true },
    { "LOOT_ROLL_DISENCHANT", "choice", { "player", "item" }, choice = "disenchant" },
    { "LOOT_ROLL_DISENCHANT_SELF", "choice", { "item" }, choice = "disenchant", self = true },
    { "LOOT_ROLL_TRANSMOG", "choice", { "player", "item" }, choice = "transmog" },
    { "LOOT_ROLL_TRANSMOG_SELF", "choice", { "item" }, choice = "transmog", self = true },
    { "LOOT_ROLL_PASSED", "choice", { "player", "item" }, choice = "pass" },
    { "LOOT_ROLL_PASSED_SELF", "choice", { "item" }, choice = "pass", self = true },
    { "LOOT_ROLL_PASSED_AUTO", "choice", { "player", "item" }, choice = "pass" },
    { "LOOT_ROLL_PASSED_AUTO_FEMALE", "choice", { "player", "item" }, choice = "pass" },
    { "LOOT_ROLL_PASSED_SELF_AUTO", "choice", { "item" }, choice = "pass", self = true },
    { "LOOT_ROLL_ROLLED_NEED", "choice", { "roll", "item", "player" }, choice = "need" },
    { "LOOT_ROLL_ROLLED_GREED", "choice", { "roll", "item", "player" }, choice = "greed" },
    { "LOOT_ROLL_ROLLED_DE", "choice", { "roll", "item", "player" }, choice = "disenchant" },
    { "LOOT_ROLL_ROLLED_TRANSMOG", "choice", { "roll", "item", "player" }, choice = "transmog" },
    { "LOOT_ROLL_WON", "end", { "player", "item" }, result = "won" },
    { "LOOT_ROLL_YOU_WON", "end", { "item" }, result = "won", self = true },
    { "LOOT_ROLL_ALL_PASSED", "end", { "item" }, result = "passed" },
    -- The short result lines some clients print instead of the "Need Roll - 87 ..." lines
    -- ("%1$s won: %3$s (Need - %2$d)"); skipped where the client has no such string.
    { "LOOT_ROLL_WON_NO_SPAM_NEED", "end", { "player", "roll", "item" }, result = "won", choice = "need" },
    { "LOOT_ROLL_WON_NO_SPAM_GREED", "end", { "player", "roll", "item" }, result = "won", choice = "greed" },
    { "LOOT_ROLL_WON_NO_SPAM_DE", "end", { "player", "roll", "item" }, result = "won", choice = "disenchant" },
    { "LOOT_ROLL_WON_NO_SPAM_TRANSMOG", "end", { "player", "roll", "item" }, result = "won", choice = "transmog" },
    { "LOOT_ROLL_YOU_WON_NO_SPAM_NEED", "end", { "roll", "item" }, result = "won", choice = "need", self = true },
    { "LOOT_ROLL_YOU_WON_NO_SPAM_GREED", "end", { "roll", "item" }, result = "won", choice = "greed", self = true },
    { "LOOT_ROLL_YOU_WON_NO_SPAM_DE", "end", { "roll", "item" }, result = "won", choice = "disenchant", self = true },
    { "LOOT_ROLL_YOU_WON_NO_SPAM_TRANSMOG", "end", { "roll", "item" }, result = "won", choice = "transmog",
        self = true },
}

local rules                       -- built on first use: { pattern, args, literal, def }

local function BuildRules()
    rules = {}
    for _, def in ipairs(RULE_DEFS) do
        local pattern, args, literal = Compile(_G[def[1]])
        if pattern and #args == #def[3] then
            rules[#rules + 1] = { pattern = pattern, args = args, literal = literal, def = def }
        end
    end
    -- Most specific first: "%s passed on: %s" would otherwise also read "You passed on: ..." and
    -- "%s automatically passed on: %s because ...".
    table.sort(rules, function(a, b) return a.literal > b.literal end)
    return rules
end

-- A chat line -> { kind = "choice"|"end", choice, player, item, roll, result } or nil. roll: the
-- number in a "Need Roll - 87 for ..." line; result: "won" or "passed" on a result line. Secret
-- text is skipped.
local function Parse(msg)
    msg = Str(msg)
    if not msg or not msg:find("item:", 1, true) then return nil end
    for _, r in ipairs(rules or BuildRules()) do
        local caps = { msg:match(r.pattern) }
        if caps[1] ~= nil then
            local byArg = {}
            for i, argIndex in ipairs(r.args) do byArg[argIndex] = caps[i] end
            local m = { kind = r.def[2], choice = r.def.choice, rule = r.def[1], result = r.def.result }
            for argIndex, field in ipairs(r.def[3]) do m[field] = byArg[argIndex] end
            if r.def.self then m.player = Me() end
            if ItemID(m.item) and (m.kind == "end" or ShortName(m.player)) then return m end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Rolls
-- ---------------------------------------------------------------------------

local function Prune()
    local now = Now()
    for id, r in pairs(rolls) do
        if r.expires and now > r.expires then
            r.finishedAt = r.finishedAt or r.expires
            rolls[id] = nil
        end
    end
    for key, id in pairs(drops) do
        if not rolls[id] then drops[key] = nil end
    end
end

-- Open rolls of this item, oldest first.
local function RollsOf(link, pool)
    local id = ItemID(link)
    local list = {}
    for _, r in pairs(pool or rolls) do
        if not r.ended and (r.link == link or (id and r.itemID == id)) then list[#list + 1] = r end
    end
    table.sort(list, function(a, b)
        if a.started ~= b.started then return a.started < b.started end
        return (a.id or 0) < (b.id or 0)
    end)
    return list
end

local function SetChoice(r, name, choice)
    local key = ShortName(name)
    if not r or not key or not BUCKET[choice] then return false end
    if r.choices[key] == nil then r.order[#r.order + 1] = key end
    r.choices[key] = choice
    return true
end

-- A parsed line onto the oldest open roll of its item where the player has not chosen yet (else
-- the oldest one: the latest choice wins). A rolled number ("Need Roll - 87 ... by Elex") goes to
-- the oldest roll where that player chose the same tier and has no number yet. A result line ends
-- the oldest open roll of its item and records the winner (or that everyone passed) on it.
-- pool: a list of rolls, for the preview.
local function Apply(m, pool)
    if not m then return nil end
    local list = RollsOf(m.item, pool)
    if #list == 0 then return nil end
    if m.kind == "end" then
        local r = list[1]
        r.ended = true
        r.finishedAt = Now()
        r.result = m.result
        if m.result == "won" then
            r.winner = ShortName(m.player)
            local number = tonumber(m.roll)
            if r.winner and m.choice then SetChoice(r, r.winner, m.choice) end
            if r.winner and number then r.rolled[r.winner] = number end
        end
        if not pool and r.id then rolls[r.id] = nil end
        return r
    end
    local key = ShortName(m.player)
    local number = tonumber(m.roll)
    local target
    if number and key then
        for _, r in ipairs(list) do
            if BUCKET[r.choices[key]] == BUCKET[m.choice] and r.rolled[key] == nil then target = r; break end
        end
    end
    if not target then
        target = list[1]
        for _, r in ipairs(list) do
            if key and r.choices[key] == nil then target = r; break end
        end
    end
    SetChoice(target, m.player, m.choice)
    if number and key then target.rolled[key] = number end
    return target
end

local function NewRoll(id, link, seconds)
    local now = Now()
    return { id = id, link = link, itemID = ItemID(link), started = now,
        expires = now + (seconds or DEFAULT_ROLL_TIME) + GRACE, choices = {}, order = {}, rolled = {} }
end

-- Who chose what for one roll, per bucket in the order they chose:
-- { need = { { name = "Elex", de = false, roll = 87 }, ... }, greed = ..., transmog = ..., pass = ... }.
local function Entries(r)
    local out = { need = {}, greed = {}, transmog = {}, pass = {} }
    if not r then return out end
    for _, name in ipairs(r.order) do
        local choice = r.choices[name]
        local b = BUCKET[choice]
        if b then
            local list = out[b]
            list[#list + 1] = { name = name, de = choice == "disenchant", roll = r.rolled and r.rolled[name] }
        end
    end
    return out
end

-- Names per bucket for one roll: { need = { "Elex", "Bob (DE)" }, ... }.
local function Buckets(r)
    local out = Entries(r)
    for _, list in pairs(out) do
        for i, e in ipairs(list) do list[i] = e.de and (e.name .. " (DE)") or e.name end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The numbers on the buttons
-- ---------------------------------------------------------------------------

local badges = {}                 -- [button] = { frame, text, bucket, label, getRoll }
local hookedFrames = {}           -- [GroupLootFrameN] = true

local function TooltipLine(info)
    if not Flag("names") then return end
    local tip = _G.GameTooltip
    if type(tip) ~= "table" or type(tip.AddLine) ~= "function" then return end
    local r = info.getRoll()
    local names = Buckets(r)[info.bucket]
    if #names == 0 then return end
    tip:AddLine(info.label .. ": " .. table.concat(names, ", "), 1, 1, 1, true)
    if type(tip.Show) == "function" then tip:Show() end
end

local function OnButtonEnter(button)
    local ok, err = pcall(function()
        local info = badges[button]
        if not info then return end
        local tip = _G.GameTooltip
        if type(tip) ~= "table" or type(tip.IsOwned) ~= "function" then return end
        if Bool(tip:IsOwned(button)) ~= true then return end
        TooltipLine(info)
    end)
    if not ok then A.lastError = "tooltip: " .. tostring(err) end
end

-- The badge for a button: a frame of this addon's own (mouse off) with the number in it.
local function Badge(button, def, getRoll, hook)
    local info = badges[button]
    if info then return info end
    local f = CreateFrame("Frame", nil, button)
    f:SetAllPoints(button)
    if type(f.SetFrameLevel) == "function" and type(button.GetFrameLevel) == "function" then
        local lvl = Num(button:GetFrameLevel())
        if lvl then f:SetFrameLevel(lvl + 2) end
    end
    if type(f.SetIgnoreParentAlpha) == "function" then pcall(f.SetIgnoreParentAlpha, f, true) end
    if type(f.EnableMouse) == "function" then f:EnableMouse(false) end
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local font, size = fs:GetFont()
    if Str(font) then pcall(fs.SetFont, fs, font, Num(size) or 10, "OUTLINE") end
    fs:SetTextColor(1, 1, 1)
    fs:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -1)
    fs:Hide()
    info = { frame = f, text = fs, bucket = def.bucket, label = def.label, getRoll = getRoll }
    badges[button] = info
    if hook and type(button.HookScript) == "function" then
        pcall(button.HookScript, button, "OnEnter", OnButtonEnter)
    end
    return info
end

local function ShowCount(info, n)
    if Flag("counts") and n > 0 then
        info.text:SetText(tostring(n))
        info.text:Show()
    else
        info.text:Hide()
    end
end

local function FindButton(frame, key)
    local box = frame.LootButtonContainer
    if type(box) == "table" and type(box[key]) == "table" then return box[key] end
    if type(frame[key]) == "table" then return frame[key] end
    local name = type(frame.GetName) == "function" and Str(frame:GetName())
    if name and type(_G[name .. key]) == "table" then return _G[name .. key] end
    return nil
end

local function FrameRoll(frame)
    local id = Num(frame.rollID)
    return id and rolls[id] or nil
end

local function RefreshFrame(frame)
    if type(frame) ~= "table" then return end
    local shown = type(frame.IsShown) == "function" and Bool(frame:IsShown()) == true
    local counts = shown and Buckets(FrameRoll(frame)) or nil
    for _, def in ipairs(BUTTONS) do
        local button = FindButton(frame, def.key)
        if button then
            local info = Badge(button, def, function() return FrameRoll(frame) end, true)
            ShowCount(info, counts and #counts[def.bucket] or 0)
        end
    end
end

local function RollFrames()
    local list, seen = {}, {}
    local function add(f)
        if type(f) == "table" and not seen[f] then seen[f] = true; list[#list + 1] = f end
    end
    for i = 1, FRAMES do add(_G["GroupLootFrame" .. i]) end
    local c = _G.GroupLootContainer
    if type(c) == "table" and type(c.rollFrames) == "table" then
        for _, f in pairs(c.rollFrames) do add(f) end
    end
    return list
end

local Refresh, RefreshSummary

local function HookFrame(frame)
    if hookedFrames[frame] or type(frame.HookScript) ~= "function" then return end
    hookedFrames[frame] = true
    -- Frame reuse: a frame is shown again for the next roll with a new rollID.
    pcall(frame.HookScript, frame, "OnShow", function() Refresh() end)
    pcall(frame.HookScript, frame, "OnHide", function() Refresh() end)
end

local function RefreshNow()
    refreshQueued = false
    local ok, err = pcall(function()
        Prune()
        for _, frame in ipairs(RollFrames()) do
            HookFrame(frame)
            RefreshFrame(frame)
        end
        RefreshSummary()
    end)
    if not ok then A.lastError = "refresh: " .. tostring(err) end
end

-- Coalesced: many lines in one frame are drawn once, on the next frame.
Refresh = function()
    if refreshQueued then return end
    refreshQueued = true
    After(0, RefreshNow)
end


-- ---------------------------------------------------------------------------
-- The summary panel: the last rolls, who chose what, the numbers and the winner
-- ---------------------------------------------------------------------------

local summary = {}                -- roll tables, newest first (the same tables as in rolls)
local panel                       -- the summary frame, made on first use
local rowPool = {}                -- reusable row frames
local tick = 0

-- Text colour per bucket, and the order the lines are shown in.
local COLOR = { need = "ff40c040", greed = "ffffd100", transmog = "ffc080ff", pass = "ff9d9d9d" }
local GREY = "|cff9d9d9d"
local FLAT = "Interface\\Buttons\\WHITE8x8"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local function SummarySize()
    local n = Num(A:Get("summaryRolls")) or 5
    return math.max(1, math.min(10, math.floor(n)))
end

local function InGroup()
    local f = API("IsInGroup")
    if f then return Bool(Call(f)) == true end
    local n = Num(Call(API("GetNumGroupMembers")))
    if n then return n > 0 end
    return true                   -- no way to tell: rolls only come in a group anyway
end

local function Finished(r)
    if r.finishedAt then return true end
    return r.expires ~= nil and Now() > r.expires
end

local function FinishedAt(r)
    return r.finishedAt or r.expires or 0
end

local function ItemIcon(r)
    if r.icon then return r.icon end
    local id = r.itemID
    if not id then return QUESTION end
    local v = Call(API("C_Item", "GetItemIconByID"), id)
    if not (Num(v) or Str(v)) then v = Call(API("GetItemIcon"), id) end
    return Num(v) or Str(v) or QUESTION
end

-- A roll onto the summary (newest first), the oldest dropped past the size.
local function AddToSummary(r)
    for i = #summary, 1, -1 do
        if summary[i] == r then table.remove(summary, i) end
    end
    table.insert(summary, 1, r)
    while #summary > SummarySize() do table.remove(summary) end
end

-- Clears the summary (close button, auto-hide); the next roll shows it again.
local function Dismiss()
    summary = {}
    if panel then panel:Hide() end
end

-- True once every roll in the summary is finished and the last one finished AUTOHIDE seconds ago.
local function AutoHideDue()
    if not Flag("autohide") or #summary == 0 then return false end
    local last = 0
    for _, r in ipairs(summary) do
        if not Finished(r) then return false end
        last = math.max(last, FinishedAt(r))
    end
    return Now() - last >= AUTOHIDE
end

-- One choice as shown: "Elex 87", "Bob (DE)".
local function EntryText(e)
    local t = e.name
    if e.de then t = t .. " (DE)" end
    if e.roll then t = t .. " " .. e.roll end
    return t
end

-- The entries of a bucket, highest roll first; players without a number keep their order, last.
local function Sorted(list)
    local copy = {}
    for i, e in ipairs(list) do copy[i] = { e = e, i = i } end
    table.sort(copy, function(a, b)
        local ra, rb = a.e.roll, b.e.roll
        if ra and rb and ra ~= rb then return ra > rb end
        if (ra ~= nil) ~= (rb ~= nil) then return ra ~= nil end
        return a.i < b.i
    end)
    for i, c in ipairs(copy) do copy[i] = c.e end
    return copy
end

-- The lines of one roll: { { bucket, text } } for each bucket with someone in it.
local function RollLines(r)
    local out, entries = {}, Entries(r)
    for _, def in ipairs(BUTTONS) do
        local list = entries[def.bucket]
        if #list > 0 then
            local names = {}
            for i, e in ipairs(Sorted(list)) do names[i] = EntryText(e) end
            out[#out + 1] = { bucket = def.bucket, label = def.label, count = #list, names = names }
        end
    end
    return out
end

local function ResultText(r)
    if r.result == "won" and r.winner then
        local n = r.rolled and r.rolled[r.winner]
        return "|cffffffff\194\187 " .. r.winner .. (n and (" " .. n) or "") .. "|r"
    end
    if r.result == "passed" then return GREY .. "all passed|r" end
    if Finished(r) then return GREY .. "no result|r" end
    return GREY .. "rolling|r"
end

local function HideTip()
    local tip = _G.GameTooltip
    if type(tip) == "table" and type(tip.Hide) == "function" then tip:Hide() end
end

local function ItemTip(self)
    local ok, err = pcall(function()
        local r, tip = self.roll, _G.GameTooltip
        if not r or not r.link or type(tip) ~= "table" then return end
        tip:SetOwner(self, "ANCHOR_LEFT")
        if not pcall(tip.SetHyperlink, tip, r.link) then tip:SetText(r.link) end
        tip:Show()
    end)
    if not ok then A.lastError = "summary tooltip: " .. tostring(err) end
end

local function NamesTip(self)
    local ok, err = pcall(function()
        local r, tip = self.roll, _G.GameTooltip
        if not r or type(tip) ~= "table" then return end
        tip:SetOwner(self, "ANCHOR_LEFT")
        tip:SetText(r.link or "?")
        for _, l in ipairs(RollLines(r)) do
            tip:AddLine("|c" .. COLOR[l.bucket] .. l.label .. " (" .. l.count .. ")|r", 1, 1, 1)
            tip:AddLine(table.concat(l.names, ", "), 1, 1, 1, true)
        end
        tip:AddLine(ResultText(r), 1, 1, 1)
        tip:Show()
    end)
    if not ok then A.lastError = "summary tooltip: " .. tostring(err) end
end

local function SavePosition()
    if not panel or not A.db then return end
    local p, _, rp, x, y = panel:GetPoint(1)
    if Str(p) and Num(x) and Num(y) then A.db.summaryPos = { p = p, rp = Str(rp) or p, x = x, y = y } end
end

local function PlacePanel()
    if not panel then return end
    panel:ClearAllPoints()
    local pos = A.db and A.db.summaryPos
    if type(pos) == "table" and Str(pos.p) and Num(pos.x) and Num(pos.y) then
        panel:SetPoint(pos.p, _G.UIParent, Str(pos.rp) or pos.p, pos.x, pos.y)
    else
        panel:SetPoint("RIGHT", _G.UIParent, "RIGHT", -220, 120)
    end
end

local function ResetPosition()
    if A.db then A.db.summaryPos = nil end
    PlacePanel()
    A:Print("roll summary back to its default place")
end

local function StartDrag()
    if panel then pcall(panel.StartMoving, panel) end
end

local function StopDrag()
    if not panel then return end
    pcall(panel.StopMovingOrSizing, panel)
    if type(panel.SetUserPlaced) == "function" then pcall(panel.SetUserPlaced, panel, false) end
    local ok, err = pcall(SavePosition)
    if not ok then A.lastError = "summary position: " .. tostring(err) end
end

-- A frame of the panel that takes the mouse (for a tooltip) and still drags the panel.
local function Draggable(f)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", StartDrag)
    f:SetScript("OnDragStop", StopDrag)
end

local function Line(parent, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    if type(fs.SetWordWrap) == "function" then fs:SetWordWrap(false) end
    if type(fs.SetMaxLines) == "function" then pcall(fs.SetMaxLines, fs, 1) end
    return fs
end

local INNER = SUMMARY_W - 16      -- row width inside the panel padding

local function NewRow()
    local row = CreateFrame("Frame", nil, panel)
    row:SetWidth(INNER)
    row.sep = row:CreateTexture(nil, "ARTWORK")
    row.sep:SetColorTexture(1, 1, 1, 0.08)
    row.sep:SetHeight(1)
    row.sep:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 2)
    row.sep:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 2)

    row.result = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.result:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -2)
    row.result:SetJustifyH("RIGHT")

    row.item = CreateFrame("Frame", nil, row)
    row.item:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.item:SetHeight(16)
    Draggable(row.item)
    row.item:SetScript("OnEnter", ItemTip)
    row.item:SetScript("OnLeave", HideTip)
    row.icon = row.item:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", row.item, "LEFT", 0, 0)
    if type(row.icon.SetTexCoord) == "function" then row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
    row.name = Line(row.item, "GameFontNormalSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetPoint("RIGHT", row.item, "RIGHT", 0, 0)

    row.detail = CreateFrame("Frame", nil, row)
    row.detail:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -17)
    row.detail:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    Draggable(row.detail)
    row.detail:SetScript("OnEnter", NamesTip)
    row.detail:SetScript("OnLeave", HideTip)
    row.lines = {}
    for i = 1, #BUTTONS do
        local fs = Line(row.detail)
        fs:SetWidth(INNER - 6)
        fs:SetPoint("TOPLEFT", row.detail, "TOPLEFT", 6, -(i - 1) * 12)
        row.lines[i] = fs
    end
    return row
end

-- Fills one row for roll r; returns its height.
local function FillRow(row, r)
    row.item.roll, row.detail.roll = r, r
    row.icon:SetTexture(ItemIcon(r))
    row.name:SetText(r.link or (GREY .. "unknown item|r"))
    row.result:SetText(ResultText(r))
    local rw = Num(row.result:GetStringWidth()) or 40
    row.item:SetWidth(math.max(40, INNER - rw - 6))
    local lines = RollLines(r)
    if #lines == 0 then lines = { { text = GREY .. "no choices yet|r" } } end
    for i, fs in ipairs(row.lines) do
        local l = lines[i]
        if l then
            fs:SetText(l.text or ("|c" .. COLOR[l.bucket] .. l.label .. " " .. l.count .. "|r  "
                .. table.concat(l.names, ", ")))
            fs:Show()
        else
            fs:Hide()
        end
    end
    return 17 + math.min(#lines, #row.lines) * 12 + 2
end

local function MakePanel()
    if panel then return panel end
    local ok, f = pcall(CreateFrame, "Frame", "GaarLootForeverSummary", _G.UIParent, "BackdropTemplate")
    if not ok or not f then f = CreateFrame("Frame", "GaarLootForeverSummary", _G.UIParent) end
    panel = f
    f:SetWidth(SUMMARY_W)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    Draggable(f)
    if type(f.SetBackdrop) == "function" then
        f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        f:SetBackdropColor(0.07, 0.08, 0.10, 0.90)
        f:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    else
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(f)
        bg:SetColorTexture(0.07, 0.08, 0.10, 0.90)
    end
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -7)
    f.title:SetText(_G.LOOT_ROLLS or "Loot Rolls")
    local okClose, close = pcall(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
    if not okClose or not close then
        close = CreateFrame("Button", nil, f)
        local x = close:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        x:SetPoint("CENTER")
        x:SetText("x")
    end
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function() pcall(Dismiss) end)
    -- Once a second while shown: rolls that ran out of time, and the auto-hide.
    f:SetScript("OnUpdate", function(_, elapsed)
        tick = tick + (Num(elapsed) or 0)
        if tick < 1 then return end
        tick = 0
        local okTick, err = pcall(RefreshSummary)
        if not okTick then A.lastError = "summary: " .. tostring(err) end
    end)
    f:Hide()
    PlacePanel()
    return f
end

local function HasTest()
    for _, r in ipairs(summary) do
        if r.test then return true end
    end
    return false
end

RefreshSummary = function()
    if AutoHideDue() then return Dismiss() end
    while #summary > SummarySize() do table.remove(summary) end
    if not Flag("summary") or #summary == 0 or not (InGroup() or HasTest()) then
        if panel then panel:Hide() end
        return
    end
    MakePanel()
    local y = -24
    for i, r in ipairs(summary) do
        local row = rowPool[i] or NewRow()
        rowPool[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, y)
        local h = FillRow(row, r)
        row:SetHeight(h)
        if i > 1 then row.sep:Show() else row.sep:Hide() end
        row:Show()
        y = y - h - 4
    end
    for i = #summary + 1, #rowPool do rowPool[i]:Hide() end
    panel:SetHeight(-y + 2)
    panel:Show()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function OnStartRoll(_, rollID, rollTime)
    rollID = Num(rollID)
    if not rollID then return end
    local link = Str((Call(API("GetLootRollItemLink"), rollID)))
    local ms = Num(rollTime)
    local r = NewRoll(rollID, link, ms and ms > 0 and ms / 1000 or nil)
    local texture = Call(API("GetLootRollItemInfo"), rollID)
    r.icon = Num(texture) or Str(texture)
    rolls[rollID] = r
    AddToSummary(r)
    Refresh()
end

local function OnCancelRoll(_, rollID)
    rollID = Num(rollID)
    local r = rollID and rolls[rollID]
    if r then r.cancelled = true end
    Refresh()
end

local function OnCancelAll()
    local now = Now()
    for _, r in pairs(rolls) do r.finishedAt = r.finishedAt or now end
    rolls, drops = {}, {}
    Refresh()
end

local function OnChat(_, msg)
    if not Enabled() then return end
    local m = Parse(msg)
    if m and Apply(m) then Refresh() end
end

-- C_LootHistory: EncounterLootDropRollState NeedMainSpec 0, NeedOffSpec 1, Transmog 2, Greed 3,
-- NoRoll 4, Pass 5 (Enum values used where the client has them).
local function HistoryChoice(state)
    state = Num(state)
    if not state then return nil end
    local E = type(_G.Enum) == "table" and _G.Enum.EncounterLootDropRollState
    local function is(name, fallback)
        local v = type(E) == "table" and Num(E[name]) or fallback
        return state == v
    end
    if is("NeedMainSpec", 0) or is("NeedOffSpec", 1) then return "need" end
    if is("Transmog", 2) then return "transmog" end
    if is("Greed", 3) then return "greed" end
    if is("Pass", 5) then return "pass" end
    return nil
end

local function OnHistoryDrop(_, encounterID, lootListKey)
    if not Enabled() then return end
    encounterID, lootListKey = Num(encounterID), Num(lootListKey)
    local get = API("C_LootHistory", "GetSortedInfoForDrop")
    if not encounterID or not lootListKey or not get then return end
    local info = Call(get, encounterID, lootListKey)
    if type(info) ~= "table" then return end
    local key = encounterID .. ":" .. lootListKey
    local r = drops[key] and rolls[drops[key]]
    if not r then
        local link = Str(info.itemHyperlink)
        if not link then return end
        local taken = {}
        for _, id in pairs(drops) do taken[id] = true end
        for _, cand in ipairs(RollsOf(link)) do
            if not taken[cand.id] then r = cand; break end
        end
        if not r then return end
        drops[key] = r.id
    end
    local changed = false
    if type(info.rollInfos) == "table" then
        for _, ri in ipairs(info.rollInfos) do
            if type(ri) == "table" then
                local name = Bool(ri.isSelf) and Me() or Str(ri.playerName)
                local choice = HistoryChoice(ri.state)
                if name and choice and SetChoice(r, name, choice) then changed = true end
            end
        end
    end
    if changed then Refresh() end
end

-- ---------------------------------------------------------------------------
-- /glf test: a preview window and the parser run on the client's own strings
-- ---------------------------------------------------------------------------

local preview, previewRoll

local ATLAS = { need = "lootroll-toast-icon-need-up", greed = "lootroll-toast-icon-greed-up",
    pass = "lootroll-toast-icon-pass-up" }
local TEXTURE = { need = "Interface\\Buttons\\UI-GroupLoot-Dice-Up",
    greed = "Interface\\Buttons\\UI-GroupLoot-Coin-Up", pass = "Interface\\Buttons\\UI-GroupLoot-Pass-Up" }

local function PreviewFrame()
    if preview then return preview end
    local f = CreateFrame("Frame", "GaarLootForeverPreview", _G.UIParent)
    f:SetSize(250, 92)
    f:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 120)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(0, 0, 0, 0.8)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)
    title:SetText("GaarLootForever preview")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
    local x = 20
    for _, def in ipairs(BUTTONS) do
        if def.bucket ~= "transmog" then
            local b = CreateFrame("Button", nil, f)
            b:SetSize(32, 32)
            b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, 14)
            x = x + 48
            local ok = type(b.SetNormalAtlas) == "function" and pcall(b.SetNormalAtlas, b, ATLAS[def.bucket])
            if not ok then b:SetNormalTexture(TEXTURE[def.bucket]) end
            local info = Badge(b, def, function() return previewRoll end, false)
            b:SetScript("OnEnter", function(self)
                local tip = _G.GameTooltip
                if type(tip) ~= "table" then return end
                tip:SetOwner(self, "ANCHOR_RIGHT")
                tip:SetText(def.label)
                pcall(TooltipLine, info)
                tip:Show()
            end)
            b:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
        end
    end
    if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "GaarLootForeverPreview") end
    f:Hide()
    preview = f
    return f
end

-- Three fake finished rolls in the summary, fed line by line through the parser where the client
-- has the string (else the parsed result is built directly, so the summary is filled either way).
local RULE_BY_NAME = {}
for _, def in ipairs(RULE_DEFS) do RULE_BY_NAME[def[1]] = def end

local function Feed(pool, rule, ...)
    local def = RULE_BY_NAME[rule]
    local f = Str(_G[rule])
    local m
    if f then
        local ok, msg = pcall(string.format, f, ...)
        m = ok and Parse(msg) or nil
    end
    if not m and def then
        local args = { ... }
        m = { kind = def[2], choice = def.choice, rule = rule, result = def.result }
        for i, field in ipairs(def[3]) do m[field] = args[i] end
        if def.self then m.player = Me() end
    end
    return Apply(m, pool)
end

local function FillTestSummary()
    local you = Me()
    local staff = "|cff0070dd|Hitem:2042::::::::1:::::::|h[Staff of Westfall]|h|r"
    local silk = "|cff1eff00|Hitem:4306::::::::1:::::::|h[Silk Cloth]|h|r"
    local gem = "|cff1eff00|Hitem:7909::::::::1:::::::|h[Aquamarine]|h|r"
    local now = Now()
    local made = {}
    for i, link in ipairs({ staff, silk, gem }) do
        local r = NewRoll(nil, link, 3600)
        r.started, r.test = now - 3 + i, true
        made[i] = r
    end
    local pool = made
    Feed(pool, "LOOT_ROLL_NEED", "Elex", staff)
    Feed(pool, "LOOT_ROLL_NEED", "Mira", staff)
    Feed(pool, "LOOT_ROLL_GREED", "Bob", staff)
    Feed(pool, "LOOT_ROLL_PASSED_SELF", staff)
    Feed(pool, "LOOT_ROLL_PASSED", "Tarnwhisperingwood", staff)
    Feed(pool, "LOOT_ROLL_PASSED_AUTO", "Wen", staff)
    Feed(pool, "LOOT_ROLL_ROLLED_NEED", 87, staff, "Elex")
    Feed(pool, "LOOT_ROLL_ROLLED_NEED", 42, staff, "Mira")
    Feed(pool, "LOOT_ROLL_WON", "Elex", staff)
    Feed(pool, "LOOT_ROLL_PASSED", "Elex", silk)
    Feed(pool, "LOOT_ROLL_PASSED", "Bob", silk)
    Feed(pool, "LOOT_ROLL_PASSED_SELF", silk)
    Feed(pool, "LOOT_ROLL_ALL_PASSED", silk)
    Feed(pool, "LOOT_ROLL_GREED", "Bob", gem)
    Feed(pool, "LOOT_ROLL_GREED_SELF", gem)
    Feed(pool, "LOOT_ROLL_DISENCHANT", "Wen", gem)
    Feed(pool, "LOOT_ROLL_PASSED", "Elex", gem)
    Feed(pool, "LOOT_ROLL_ROLLED_GREED", 55, gem, "Bob")
    Feed(pool, "LOOT_ROLL_ROLLED_GREED", 71, gem, you)
    Feed(pool, "LOOT_ROLL_ROLLED_DE", 30, gem, "Wen")
    Feed(pool, "LOOT_ROLL_YOU_WON", gem)
    for _, r in ipairs(made) do AddToSummary(r) end
    Refresh()
end

local function RunTest()
    local link = "|cff1eff00|Hitem:4306::::::::1:::::::|h[Silk Cloth]|h|r"
    local you = Me()
    local lines = {
        { "LOOT_ROLL_NEED", "Elex", link },
        { "LOOT_ROLL_GREED", "Bob", link },
        { "LOOT_ROLL_NEED", "Mira", link },
        { "LOOT_ROLL_PASSED", "Tarn", link },
        { "LOOT_ROLL_PASSED_AUTO", "Wen", link },
        { "LOOT_ROLL_GREED_SELF", link },
    }
    previewRoll = NewRoll(nil, link, 3600)
    local pool = { previewRoll }
    A:Print("parsing the client's own loot strings:")
    for _, l in ipairs(lines) do
        local f = Str(_G[l[1]])
        if not f then
            A:Print("  " .. l[1] .. ": not on this client")
        else
            local ok, msg = pcall(string.format, f, select(2, unpack(l)))
            local m = ok and Parse(msg)
            if m then Apply(m, pool) end
            A:Print("  " .. l[1] .. " -> " .. (m and ((m.player or "?") .. " = " .. (m.choice or m.kind)) or "no match"))
        end
    end
    local b = Buckets(previewRoll)
    A:Print(string.format("counts: need %d, greed %d, pass %d (you = %s)", #b.need, #b.greed, #b.pass, you))
    local f = PreviewFrame()
    for button, info in pairs(badges) do
        if button:GetParent() == f then ShowCount(info, #b[info.bucket]) end
    end
    f:Show()
    if not Flag("counts") then A:Print("counts are off (/glf counts on), so the buttons show none.") end
    FillTestSummary()
    if not Flag("summary") then A:Print("the summary is off (/glf summary on), so it shows none.") end
end

-- ---------------------------------------------------------------------------
-- Options, slash command, API
-- ---------------------------------------------------------------------------

local function Changed() Refresh() end

A:Toggle("enabled", "Loot roll counts and summary", true, Changed)
A:Toggle("counts", "Counts on the Need / Greed / Pass buttons", true, Changed)
A:Toggle("names", "Who chose what, in the button tooltips", true, Changed)
A:Toggle("summary", "Summary panel of the last rolls", true, Changed)
A:Toggle("autohide", "Hide the summary 60 s after the last roll", true, Changed)
A:Slider("summaryRolls", "Rolls kept in the summary", 1, 10, 1, 5, Changed, nil, { cmd = "rolls" })
A:Button("Summary back to its default place", function() ResetPosition() end, { cmd = "reset" })
A:Button("Show a preview", function() RunTest() end, { cmd = "test" })

local function ActiveCount()
    local n = 0
    for _, r in pairs(rolls) do
        if not r.cancelled then n = n + 1 end
    end
    return n
end

A.statusFn = function()
    if not A.db then return "not loaded yet" end
    Prune()
    local history = API("C_LootHistory", "GetSortedInfoForDrop") and " + loot history" or ""
    return OnOff(Enabled()) .. DOT .. "counts " .. OnOff(A:Get("counts")) .. DOT .. "names "
        .. OnOff(A:Get("names")) .. DOT .. "chat (" .. #(rules or BuildRules()) .. " patterns)" .. history
        .. DOT .. ActiveCount() .. " open roll(s)" .. DOT .. "summary " .. OnOff(A:Get("summary"))
        .. " (" .. #summary .. "/" .. SummarySize() .. ", auto-hide " .. OnOff(A:Get("autohide")) .. ")"
end

A:Slash({ "/glf", "/gaarlootforever", "/bloot", "/betterlootforever" }) -- /gloot is GaarLooter's; /bloot: the command before the Gaar rename
A:API()

A:On("ADDON_LOADED", function(_, name)
    if name ~= "GaarLootForever" then return end
    BF.Migrate("GaarLootForeverDB", "BetterLootForeverDB") -- the old folder's settings, once (see Lib.lua)
    A:InitDB("GaarLootForeverDB", {})
    BuildRules()
end)
A:On("PLAYER_LOGIN", function() Refresh() end)
A:On("START_LOOT_ROLL", OnStartRoll)
A:On("CANCEL_LOOT_ROLL", OnCancelRoll)
A:On("CANCEL_ALL_LOOT_ROLLS", OnCancelAll)
A:On("CHAT_MSG_LOOT", OnChat)
A:On("CHAT_MSG_SYSTEM", OnChat)
A:On("LOOT_HISTORY_UPDATE_DROP", OnHistoryDrop)
A:On("GROUP_ROSTER_UPDATE", function() Refresh() end)

-- For the scratch tests outside the game; not part of the API.
A._test = { Compile = Compile, Parse = Parse, Apply = Apply, NewRoll = NewRoll, Buckets = Buckets,
    BuildRules = BuildRules, rolls = function() return rolls end, OnStartRoll = OnStartRoll,
    OnChat = OnChat, OnCancelRoll = OnCancelRoll, OnHistoryDrop = OnHistoryDrop, Entries = Entries,
    OnCancelAll = OnCancelAll, RunTest = RunTest, RefreshSummary = function() RefreshSummary() end,
    summary = function() return summary end, panel = function() return panel end,
    rows = function() return rowPool end, ResultText = ResultText }
