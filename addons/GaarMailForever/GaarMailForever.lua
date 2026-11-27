--[[
  GaarMailForever - mailbox helpers for WoW Forever.

  Every feature is its own saved setting, a /gmail command and a hub menu entry, and there is a
  master switch on top. Nothing here replaces a Blizzard function: the addon adds its own frames
  and follows Blizzard code with hooksecurefunc.

    hideBlizzOpenAll (default on) "Use GaarMail's Open All instead of Blizzard's": our button sits where
                 Blizzard's is (anchors and size copied at MAIL_SHOW) and Blizzard's is hidden (hide + OnShow
                 hook, no script replaced); off, or addon/Open All off: Blizzard's shows, ours is hidden.
    openAll      (default on)   "Open All" button on the inbox. Takes money and then items from
                                one mail at a time and waits for MAIL_INBOX_UPDATE / MAIL_SUCCESS
                                between actions (0.3 s apart at the fastest). Shift-click on the
                                button takes money only. It never touches a COD mail (a mail that
                                asks for payment is never paid automatically), and stops when the
                                bags are full (ERR_INV_FULL), when you click Stop, or when the
                                mailbox closes. Prints a summary: gold taken, item count.
    deleteEmpty  (default off)  Needs openAll. Deletes a mail only when ALL of this is true: it has
                                no money, no item, no COD; it has been read; you cannot reply to
                                it (a system or auction house mail, never a letter from a
                                player); and it is not from a GM. A letter from a player is never
                                deleted, with or without a text.
    recipients   (default on)   A small button right of the "To:" box on the Send Mail tab opens a
                                list of the last 15 recipients (account-wide) and your own
                                characters on this realm and faction (every character that logs
                                in is recorded, with the surname if it has one, e.g. "Lock Tics"; old first-name-only entries
                                are replaced by the full name at login). Click a name to fill in "To:".
    sendMulti    (default on)   On the Send Mail tab, Alt-click an item in your bags attaches it.
                                Ctrl+Alt-click attaches up to 12 stacks of the same item. Out of
                                combat only.
    subject      (default on)   Once a recipient is chosen on the Send Mail tab (list, typed and
                                left, Enter/Tab, name filled in by the client), an empty subject
                                becomes "From <your full name>". Only an empty subject or our own
                                earlier default is ever replaced; text you typed is never touched.
                                When an item is attached, the item name replaces our default (what
                                Blizzard does for an empty subject).
    mailNotice   (default on)   A chat line at login and when new mail arrives, with the senders
                                GetLatestThreeSenders gives (only plain values are printed).

  Safety: every handler runs in pcall (the last error is kept for /gmail status), every client
  API is checked with type(...) == "function", and a secret value is treated as no value, never
  compared or tested. Saved variables are read at ADDON_LOADED, never at file scope.

  GaarMailForeverAPI is the small global table GaarForever's hub reads: version,
  StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden.
]]

local _G = _G
local ADDON_NAME = ...
ADDON_NAME = ADDON_NAME or "GaarMailForever"
local DOT = " \194\183 "
local VERSION = "1.5.1"

-- The shared library (GaarForever's Lib.lua, loaded first through ## Dependencies).
local BF = _G.GaarForever
local A = BF.NewAddon("GaarMailForever", { title = "GaarMailForever", version = VERSION })
local Plain, InCombat, Coins, OnOff = BF.Plain, BF.InCombat, BF.Coins, BF.OnOff

local MAX_RECENT = 15
local STEP_DELAY = 0.3        -- seconds between two mail actions, at the fastest
local WAIT_TIMEOUT = 2.0      -- seconds to wait for the inbox to answer an action
local MAX_FAILS = 3           -- tries on one mail before it is skipped
local MAX_STACKS = 12         -- ATTACHMENTS_MAX_SEND

-- The features: saved key, slash word, label, default.
local FEATURES = {
    { key = "openAll", cmd = "openall", label = "Open All button", def = true },
    { key = "hideBlizzOpenAll", cmd = "blizzopenall", label = "Use GaarMail's Open All instead of Blizzard's", def = true },
    { key = "deleteEmpty", cmd = "deleteempty", label = "Delete empty system mail", def = false },
    { key = "recipients", cmd = "recipients", label = "Recipient list", def = true },
    { key = "sendMulti", cmd = "sendmulti", label = "Alt-click to attach", def = true },
    { key = "mailNotice", cmd = "notice", label = "New mail notice", def = true },
    { key = "subject", cmd = "subject", label = "Default subject (From <your name>)", def = true },
}
local SAVED_KEYS = { enabled = true, recent = true, alts = true }
for _, f in ipairs(FEATURES) do SAVED_KEYS[f.key] = true end

local db                 -- GaarMailForeverDB, bound at ADDON_LOADED
local lastError          -- last error caught, for /gmail status
local mailOpen = false
local announced = false  -- new-mail line printed since the last mailbox visit
local pendingTo          -- recipient of the letter being sent
local openBtn, recipBtn, menu
local ApplyDefaultSubject  -- defined with the default-subject code below

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Print(msg) A:Print(msg) end

-- Kept here: BF.Str drops "" and BF.Num drops infinity, these do not.
local function Str(v)
    v = Plain(v)
    if type(v) == "string" then return v end
end

local function Num(v)
    v = Plain(v)
    if type(v) == "number" then return v end
end

local function Fail(where, err)
    lastError = tostring(where) .. ": " .. tostring(err)
end

local function Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Fail(where, err) end
    return ok
end

local function Enabled() return db and db.enabled and true or false end
local function Feature(key) return Enabled() and db[key] and true or false end

-- ---------------------------------------------------------------------------
-- Recipients: recent names and own characters
-- ---------------------------------------------------------------------------

-- On WoW Forever a character can have a surname with a space ("Lock Tics"). Not every name API
-- returns it, so ask several and keep the longest plain answer (all are the same name, one may
-- just drop the surname). The realm part is never included: UnitName/UnitFullName return it as
-- a second value and GetUnitName is called with showServerName = false.
local function PlayerName()
    local best
    local function try(v)
        v = Str(v)
        if v and v ~= "" and (not best or #v > #best) then best = v end
    end
    if type(_G.UnitName) == "function" then try((_G.UnitName("player"))) end
    if type(_G.UnitFullName) == "function" then try((_G.UnitFullName("player"))) end
    if type(_G.GetUnitName) == "function" then try(_G.GetUnitName("player", false)) end
    return best
end

-- True when short is only the first name of full ("Lock" of "Lock Tics").
local function IsFirstNameOf(short, full)
    short, full = short:lower(), full:lower()
    return #full > #short + 1 and full:sub(1, #short + 1) == short .. " "
end

-- Drop first-name-only entries that a full name in the same list starts with.
local function DedupeAlts(list)
    for i = #list, 1, -1 do
        for j = 1, #list do
            if j ~= i and IsFirstNameOf(list[i], list[j]) then table.remove(list, i); break end
        end
    end
end

local function RealmKey()
    local realm = type(_G.GetRealmName) == "function" and Str(_G.GetRealmName()) or "?"
    local faction = type(_G.UnitFactionGroup) == "function" and Str(_G.UnitFactionGroup("player")) or "?"
    return realm .. "-" .. faction
end

local function AddRecent(name)
    name = Str(name)
    if not db or not name then return end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return end
    local me = PlayerName()
    if me and name:lower() == me:lower() then return end
    local list = db.recent
    for i = #list, 1, -1 do
        if list[i]:lower() == name:lower() then table.remove(list, i) end
    end
    table.insert(list, 1, name)
    while #list > MAX_RECENT do table.remove(list) end
end

local function RecordAlt()
    local me = PlayerName()
    if not db or not me then return end
    local key = RealmKey()
    local list = db.alts[key]
    if type(list) ~= "table" then list = {}; db.alts[key] = list end
    -- Old entries hold only the first name: replace them with the full name.
    for i = #list, 1, -1 do
        if IsFirstNameOf(list[i], me) then table.remove(list, i) end
    end
    for _, n in ipairs(list) do if n == me then return end end
    list[#list + 1] = me
    DedupeAlts(list)
end

local function RecipientRows()
    local rows, seen = {}, {}
    local me = PlayerName()
    local function add(header, names)
        local any = false
        for _, n in ipairs(names) do
            local l = n:lower()
            if not seen[l] and not (me and l == me:lower()) then
                if not any then rows[#rows + 1] = { header = header }; any = true end
                seen[l] = true
                rows[#rows + 1] = { name = n }
            end
        end
    end
    add("Your characters", db.alts[RealmKey()] or {})
    add("Recent", db.recent)
    return rows
end

local function HideMenu() if menu then menu:Hide() end end

local function ShowMenu()
    if not (recipBtn and db) then return end
    if menu and menu:IsShown() then menu:Hide(); return end
    if not menu then
        local ok, f = pcall(CreateFrame, "Frame", "GaarMailForeverMenu", _G.UIParent, "BackdropTemplate")
        if not ok then f = CreateFrame("Frame", "GaarMailForeverMenu", _G.UIParent) end
        f:SetFrameStrata("DIALOG")
        f:SetClampedToScreen(true)
        if type(f.SetBackdrop) == "function" then
            f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            f:SetBackdropColor(0, 0, 0, 0.92)
        end
        f.rows = {}
        menu = f
    end
    local rows = RecipientRows()
    for _, r in ipairs(menu.rows) do r:Hide() end
    if #rows == 0 then rows = { { header = "No recipients yet" } } end
    local y, width = -6, 140
    for i, row in ipairs(rows) do
        local b = menu.rows[i]
        if not b then
            b = CreateFrame("Button", nil, menu)
            b:SetHeight(16)
            b.text = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 4, 0)
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            b:SetScript("OnClick", function(self)
                Safe("menu click", function()
                    local box = _G.SendMailNameEditBox
                    if box and self.name then
                        box:SetText(self.name)
                        box:SetCursorPosition(0)
                        ApplyDefaultSubject()
                        local subject = _G.SendMailSubjectEditBox
                        if subject and type(subject.SetFocus) == "function" then subject:SetFocus() end
                    end
                    menu:Hide()
                end)
            end)
            menu.rows[i] = b
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, y)
        b:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -6, y)
        b.name = row.name
        b.text:SetText(row.name or ("|cffffd100" .. row.header .. "|r"))
        b:EnableMouse(row.name ~= nil)
        b:SetHighlightTexture(row.name and "Interface\\QuestFrame\\UI-QuestTitleHighlight" or "")
        width = math.max(width, b.text:GetStringWidth() + 20)
        b:Show()
        y = y - 16
    end
    menu:SetSize(width, -y + 6)
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", recipBtn, "BOTTOMLEFT", 0, -2)
    menu:Show()
end

-- ---------------------------------------------------------------------------
-- Default subject: "From <full name>" once a recipient is chosen
-- ---------------------------------------------------------------------------

local lastDefault        -- the default subject we put in the field last

local function MyFullName()
    local n
    if type(BF.PlayerFullName) == "function" then n = Str(BF.PlayerFullName()) end
    if not n or n == "" then n = PlayerName() end
    return n
end

local function FirstAttachedName()
    if type(_G.GetSendMailItem) ~= "function" then return nil end
    for i = 1, MAX_STACKS do
        local name = Str((_G.GetSendMailItem(i)))
        if name and name ~= "" then return name end
    end
end

ApplyDefaultSubject = function()
    if not Feature("subject") then return end
    local box, subject = _G.SendMailNameEditBox, _G.SendMailSubjectEditBox
    if not (box and subject and type(subject.GetText) == "function") then return end
    local to = Str(box:GetText())
    if not to or not to:find("%S") then return end
    if FirstAttachedName() then return end -- Blizzard names the subject after the item
    local cur = Str(subject:GetText())
    if cur == nil then return end
    if cur == "" or (lastDefault and cur == lastDefault) then
        local me = MyFullName()
        if not me then return end
        local text = "From " .. me
        if cur ~= text then subject:SetText(text) end
        lastDefault = text
    end
end

-- An item was attached: if our default is still in the field, the item name wins.
local function OnAttachChanged()
    local subject = _G.SendMailSubjectEditBox
    if not (lastDefault and subject and type(subject.GetText) == "function") then return end
    if Str(subject:GetText()) ~= lastDefault then return end
    local item = FirstAttachedName()
    if item then
        subject:SetText(item)
        lastDefault = nil
    end
end

local function HookRecipientBox()
    local box = _G.SendMailNameEditBox
    if not box or box.gaarSubjectHooked or type(box.HookScript) ~= "function" then return end
    box.gaarSubjectHooked = true
    for _, script in ipairs({ "OnEditFocusLost", "OnEnterPressed", "OnTabPressed" }) do
        pcall(box.HookScript, box, script, function() Safe("subject", ApplyDefaultSubject) end)
    end
    -- the name filled in by code (Alt-click on a name, reply, autocomplete), not typed
    pcall(box.HookScript, box, "OnTextChanged", function(_, userInput)
        if not userInput then Safe("subject", ApplyDefaultSubject) end
    end)
end

local function RefreshRecipientButton()
    if not recipBtn then return end
    if Feature("recipients") then recipBtn:Show() else recipBtn:Hide(); HideMenu() end
end

local function CreateRecipientButton()
    if recipBtn then return end
    local box, parent = _G.SendMailNameEditBox, _G.SendMailFrame
    if not (box and parent) then return end
    local b = CreateFrame("Button", "GaarMailForeverRecipients", parent, "UIPanelButtonTemplate")
    b:SetSize(22, 22)
    b:SetText("v")
    b:SetPoint("LEFT", box, "RIGHT", 4, 0)
    b:SetScript("OnClick", function() Safe("recipients", ShowMenu) end)
    b:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_RIGHT")
        tip:SetText("Recent recipients and your characters")
        tip:Show()
    end)
    b:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    parent:HookScript("OnHide", HideMenu)
    recipBtn = b
    RefreshRecipientButton()
end

-- ---------------------------------------------------------------------------
-- Open All
-- ---------------------------------------------------------------------------

local run                -- the running Open All, or nil
local driver = CreateFrame("Frame")

local BTN_TEXT = "Open All Mail"
local BTN_PAD = 24           -- extra width around the text
local BTN_FALLBACK_Y = 80    -- fallback only: bottom-centre of the Inbox frame, above the page buttons

-- Blizzard's own Open All button (OpenAllMail from Blizzard_MailFrame; the other names are
-- fallbacks). Exactly one of the two buttons shows: with the option on (and the addon and Open All
-- enabled) ours replaces Blizzard's, otherwise Blizzard's shows and ours is hidden. Blizzard's is
-- hidden without touching its scripts: Hide() plus an OnShow hook that re-hides it.
local blizzBtn, blizzHooked
local function FindBlizzOpenAll()
    local inbox = _G.InboxFrame
    local b = _G.OpenAllMail or _G.OpenAllMailButton or (type(inbox) == "table" and inbox.OpenAllMail) or nil
    if type(b) == "table" and type(b.Hide) == "function" and type(b.Show) == "function" then return b end
end

local function UseOurs() return Feature("hideBlizzOpenAll") and Feature("openAll") end

-- Puts our button where Blizzard's is: copies its anchors and size (only our own frame is moved;
-- out of combat). Without Blizzard's button: bottom-centre of the Inbox frame, above the page buttons.
local function PositionOpenButton()
    if not openBtn or InCombat() then return end
    local b = blizzBtn or FindBlizzOpenAll()
    local n = b and type(b.GetNumPoints) == "function" and Num(b:GetNumPoints()) or 0
    local placed = false
    if n and n > 0 then
        openBtn:ClearAllPoints()
        for i = 1, n do
            local p, rel, rp, x, y = b:GetPoint(i)
            if p and rel ~= openBtn then
                openBtn:SetPoint(p, rel, rp or p, x or 0, y or 0)
                placed = true
            end
        end
    end
    local w = openBtn.GetFontString and openBtn:GetFontString()
    local need = w and type(w.GetStringWidth) == "function" and Num(w:GetStringWidth())
    need = need and (need + BTN_PAD) or 100
    local bw = b and type(b.GetWidth) == "function" and Num(b:GetWidth()) or nil
    openBtn:SetWidth((bw and bw >= need) and bw or need)
    local bh = b and type(b.GetHeight) == "function" and Num(b:GetHeight()) or nil
    openBtn:SetHeight((bh and bh > 0) and bh or 22)
    if not placed then
        local inbox = _G.InboxFrame
        local y = BTN_FALLBACK_Y
        local prev = _G.InboxPrevPageButton or _G.InboxNextPageButton
        if prev and inbox and type(prev.GetTop) == "function" and type(inbox.GetBottom) == "function" then
            local top, bot = Num(prev:GetTop()), Num(inbox:GetBottom())
            if top and bot and top > bot then y = top - bot + 6 end
        end
        openBtn:ClearAllPoints()
        openBtn:SetPoint("BOTTOM", inbox, "BOTTOM", 0, y)
    end
end

local function UpdateOpenButton()
    if not openBtn then return end
    openBtn:SetText(run and "Stop" or BTN_TEXT)
    if UseOurs() then openBtn:Show() else openBtn:Hide() end
end

local function UpdateBlizzOpenAll()
    local b = blizzBtn or FindBlizzOpenAll()
    if not b then return end
    blizzBtn = b
    if not blizzHooked and type(b.HookScript) == "function" then
        blizzHooked = true
        b:HookScript("OnShow", function(self)
            if UseOurs() then self:Hide() end
        end)
    end
    if UseOurs() then
        b:Hide()
    elseif mailOpen then
        b:Show()
    end
end

local function Finish(reason)
    if not run then return end
    local r = run
    run = nil
    driver:SetScript("OnUpdate", nil)
    local bits = {}
    if r.money > 0 then bits[#bits + 1] = Coins(r.money) end
    if r.items > 0 then bits[#bits + 1] = r.items .. (r.items == 1 and " item" or " items") end
    if r.deleted > 0 then bits[#bits + 1] = r.deleted .. " empty deleted" end
    local line = "Opened mail: " .. (#bits > 0 and table.concat(bits, ", ") or "nothing taken")
    if r.cod > 0 then line = line .. DOT .. r.cod .. " COD skipped" end
    if reason then line = line .. DOT .. reason end
    Print(line)
    UpdateOpenButton()
end

-- The next thing to do: { kind, index, key, money, items } or nil.
local function NextAction()
    local n = Num(select(1, _G.GetInboxNumItems()))
    if not n then return nil end
    for i = 1, n do
        local _, _, sender, subject, money, cod, _, hasItem, wasRead, _, _, canReply, isGM = _G.GetInboxHeaderInfo(i)
        sender, subject = Str(sender) or "", Str(subject) or ""
        money, cod = Num(money), Num(cod)
        local key = i .. "|" .. subject .. "|" .. sender
        if money and cod and not (run.skip[key]) then
            hasItem = Plain(hasItem)
            if cod > 0 then
                if not run.codSeen[key] then run.codSeen[key] = true; run.cod = run.cod + 1 end
            elseif money > 0 then
                return { kind = "money", index = i, key = key, money = money }
            elseif hasItem and hasItem ~= 0 and not run.moneyOnly then
                local count = 0
                for j = 1, (_G.ATTACHMENTS_MAX_RECEIVE or 16) do
                    local name, _, _, c = _G.GetInboxItem(i, j)
                    if Plain(name) then count = count + (Num(c) or 1) end
                end
                return { kind = "items", index = i, key = key, items = count }
            elseif not hasItem and Plain(wasRead) and not Plain(canReply) and not Plain(isGM) and db.deleteEmpty then
                return { kind = "delete", index = i, key = key }
            end
        end
    end
end

local function Step()
    if not run then return end
    if not mailOpen then return Finish("mailbox closed") end
    local a = NextAction()
    if not a then return Finish() end
    local sig = a.key .. "|" .. a.kind .. "|" .. (a.items or a.money or 0) -- changes while mail empties
    if sig == run.lastSig then
        run.fails = run.fails + 1
        if run.fails >= MAX_FAILS then
            run.skip[a.key] = true
            run.fails = 0
            run.nextAt = 0
            return
        end
    else
        run.fails = 0
    end
    run.lastSig = sig
    run.waiting, run.waitSince = true, _G.GetTime()
    if a.kind == "money" then
        _G.TakeInboxMoney(a.index)
        run.money = run.money + a.money
    elseif a.kind == "items" then
        if type(_G.AutoLootMailItem) == "function" then
            _G.AutoLootMailItem(a.index)
        else
            for j = (_G.ATTACHMENTS_MAX_RECEIVE or 16), 1, -1 do
                if Plain(_G.GetInboxItem(a.index, j)) then _G.TakeInboxItem(a.index, j); break end
            end
        end
        run.items = run.items + a.items
    else
        _G.DeleteInboxItem(a.index)
        run.deleted = run.deleted + 1
    end
end

local function OnDriver()
    if not run then return end
    local now = _G.GetTime()
    if run.waiting then
        if now - run.waitSince < WAIT_TIMEOUT then return end
        run.waiting = false -- no answer: try again; Step counts the failure
        run.nextAt = now
    end
    if now < run.nextAt then return end
    local ok, err = pcall(Step)
    if not ok then Fail("open all", err); Finish("error, see /gmail status") end
end

local function Answered()
    if run and run.waiting then
        run.waiting = false
        run.nextAt = _G.GetTime() + STEP_DELAY
    end
end

local function StartOpenAll(moneyOnly)
    if run then return end
    if not mailOpen then Print("open a mailbox first"); return end
    if not Feature("openAll") then Print("Open All is off (/gmail openall on)"); return end
    local n = Num(select(1, _G.GetInboxNumItems()))
    if not n or n == 0 then Print("the inbox is empty"); return end
    run = { money = 0, items = 0, deleted = 0, cod = 0, codSeen = {}, skip = {}, fails = 0,
        moneyOnly = moneyOnly and true or false, nextAt = 0 }
    UpdateOpenButton()
    driver:SetScript("OnUpdate", OnDriver)
end

local function CreateOpenButton()
    if openBtn then return end
    local parent = _G.InboxFrame
    if not parent then return end
    local b = CreateFrame("Button", "GaarMailForeverOpenAll", parent, "UIPanelButtonTemplate")
    b:SetSize(100, 22)
    b:SetText(BTN_TEXT)
    b:SetPoint("BOTTOM", parent, "BOTTOM", 0, BTN_FALLBACK_Y) -- until PositionOpenButton copies Blizzard's spot
    b:SetScript("OnClick", function()
        Safe("open all click", function()
            if run then Finish("stopped") else StartOpenAll(_G.IsShiftKeyDown and _G.IsShiftKeyDown()) end
        end)
    end)
    b:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        tip:SetOwner(self, "ANCHOR_RIGHT")
        tip:SetText(BTN_TEXT)
        tip:AddLine("Takes money and items from every mail. COD mail is skipped.", 1, 1, 1, true)
        tip:AddLine("Shift-click: money only.", 0.7, 0.7, 0.7, true)
        tip:Show()
    end)
    b:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    openBtn = b
    PositionOpenButton()
    UpdateOpenButton()
end

-- ---------------------------------------------------------------------------
-- Send multiple: Alt-click / Ctrl+Alt-click on a bag item
-- ---------------------------------------------------------------------------

local function BagItemID(bag, slot)
    local c = _G.C_Container
    if type(c) == "table" and type(c.GetContainerItemID) == "function" then return Num(c.GetContainerItemID(bag, slot)) end
    if type(_G.GetContainerItemID) == "function" then return Num(_G.GetContainerItemID(bag, slot)) end
end

local function BagSlots(bag)
    local c = _G.C_Container
    if type(c) == "table" and type(c.GetContainerNumSlots) == "function" then return Num(c.GetContainerNumSlots(bag)) or 0 end
    if type(_G.GetContainerNumSlots) == "function" then return Num(_G.GetContainerNumSlots(bag)) or 0 end
    return 0
end

local function IsLocked(bag, slot)
    local c = _G.C_Container
    if type(c) == "table" and type(c.GetContainerItemInfo) == "function" then
        local info = c.GetContainerItemInfo(bag, slot)
        return type(info) == "table" and Plain(info.isLocked) and true or false
    end
    if type(_G.GetContainerItemInfo) == "function" then return select(3, _G.GetContainerItemInfo(bag, slot)) and true or false end
    return false
end

local function Pickup(bag, slot)
    local c = _G.C_Container
    if type(c) == "table" and type(c.PickupContainerItem) == "function" then return c.PickupContainerItem(bag, slot) end
    if type(_G.PickupContainerItem) == "function" then return _G.PickupContainerItem(bag, slot) end
end

local function FreeSendSlot()
    for i = 1, (_G.ATTACHMENTS_MAX_SEND or MAX_STACKS) do
        local name = _G.GetSendMailItem(i)
        if not Plain(name) or Plain(name) == "" then return i end
    end
end

-- Attaches the stack in bag/slot. Returns true when the cursor took it and a free slot existed.
local function Attach(bag, slot)
    if not FreeSendSlot() or Plain(_G.GetCursorInfo()) then return false end
    Pickup(bag, slot)
    if not Plain(_G.GetCursorInfo()) then return false end
    _G.ClickSendMailItemButton()
    if Plain(_G.GetCursorInfo()) then _G.ClearCursor(); return false end -- not sendable (soulbound ...)
    return true
end

local function AttachClick(bag, slot, all)
    if not Feature("sendMulti") or InCombat() then return end
    local frame = _G.SendMailFrame
    if not (frame and frame:IsVisible()) then return end
    if not (_G.IsAltKeyDown and _G.IsAltKeyDown()) then return end
    local id = BagItemID(bag, slot)
    if not id or IsLocked(bag, slot) then return end
    Attach(bag, slot)
    if not all then return end
    local count, done = 1, { [bag .. ":" .. slot] = true }
    local last = Num(_G.NUM_BAG_SLOTS) or 4
    for b = 0, last do
        for s = 1, BagSlots(b) do
            if count >= MAX_STACKS then return end
            if not done[b .. ":" .. s] and BagItemID(b, s) == id and not IsLocked(b, s) then
                done[b .. ":" .. s] = true
                if not Attach(b, s) then return end
                count = count + 1
            end
        end
    end
end

local lastClick = 0
local function OnItemClick(button)
    local t = _G.GetTime()
    if t - lastClick < 0.15 then return end -- two hooks may see the same click
    local f
    if type(_G.GetMouseFoci) == "function" then f = (_G.GetMouseFoci()) elseif type(_G.GetMouseFocus) == "function" then f = _G.GetMouseFocus() end
    if type(f) ~= "table" or type(f.GetID) ~= "function" then return end
    local parent = type(f.GetParent) == "function" and f:GetParent()
    local bag = type(f.GetBagID) == "function" and Num(f:GetBagID()) or (parent and type(parent.GetID) == "function" and Num(parent:GetID()))
    local slot = Num(f:GetID())
    if not bag or not slot or slot < 1 or bag < 0 then return end
    if not (_G.IsAltKeyDown and _G.IsAltKeyDown()) then return end
    lastClick = t
    AttachClick(bag, slot, _G.IsControlKeyDown and _G.IsControlKeyDown())
end

local function InstallItemHooks()
    local hooked = false
    if type(_G.HandleModifiedItemClick) == "function" then
        hooksecurefunc("HandleModifiedItemClick", function() Safe("item click", OnItemClick) end)
        hooked = true
    end
    if type(_G.ContainerFrameItemButton_OnModifiedClick) == "function" then
        hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", function() Safe("item click", OnItemClick) end)
        hooked = true
    end
    return hooked
end

-- ---------------------------------------------------------------------------
-- New mail notice
-- ---------------------------------------------------------------------------

local function AnnounceMail()
    if not Feature("mailNotice") or announced then return end
    if type(_G.HasNewMail) ~= "function" or not Plain(_G.HasNewMail()) then return end
    announced = true
    local senders = {}
    if type(_G.GetLatestThreeSenders) == "function" then
        local a, b, c = _G.GetLatestThreeSenders()
        for _, s in ipairs({ a, b, c }) do
            s = Str(s)
            if s and s ~= "" then senders[#senders + 1] = s end
        end
    end
    Print("You have new mail" .. (#senders > 0 and (" from " .. table.concat(senders, ", ")) or "") .. ".")
end

-- ---------------------------------------------------------------------------
-- Settings and commands
-- ---------------------------------------------------------------------------

local function Refresh()
    UpdateOpenButton()
    Safe("blizzard open all", UpdateBlizzOpenAll)
    RefreshRecipientButton()
    if run and not Feature("openAll") then Finish("stopped") end
end

local function SetEnabled(v) if db then db.enabled = v and true or false; Refresh() end end
local function SetFeature(key, v) if db then db[key] = v and true or false; Refresh() end end

local function FindFeature(word)
    for _, f in ipairs(FEATURES) do
        if word == f.cmd or word == f.key:lower() then return f end
    end
end

local function StatusLine()
    if not db then return "not loaded yet" end
    local on = {}
    for _, f in ipairs(FEATURES) do if db[f.key] then on[#on + 1] = f.cmd end end
    return OnOff(db.enabled) .. DOT .. (#on > 0 and table.concat(on, ", ") or "no features")
end

-- The intro GaarForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "Mailbox helpers: an Open All button, an optional clean-up of empty mail, a recipient list with your own characters and recent names, Alt-click to attach items and a new-mail notice, and a default subject (From <your name>) once a recipient is chosen. Nice to know: Shift-click Open All for money only; COD mail is never paid; Ctrl+Alt-click attaches up to 12 stacks of an item; attaching works out of combat only."

local function PrintHelp()
    Print("Right-click the mailbox window's round portrait (top-left): this addon's menu (the same options as the hub menu).")
    Print(INTRO)
    Print("/gmail on|off - master switch")
    Print("/gmail openall|blizzopenall|deleteempty|recipients|sendmulti|notice|subject on|off - one feature")
    Print("/gmail open - run Open All (mailbox open); /gmail status")
end

local function PrintStatus()
    Print("v" .. VERSION .. DOT .. "master " .. OnOff(db.enabled))
    for _, f in ipairs(FEATURES) do
        Print("  " .. f.cmd .. " " .. OnOff(db[f.key]) .. DOT .. f.label)
    end
    local alts = db.alts[RealmKey()]
    Print("mailbox " .. (mailOpen and "open" or "closed") .. DOT .. (run and "Open All running" or "idle")
        .. DOT .. #db.recent .. " recent" .. DOT .. (alts and #alts or 0) .. " characters on this realm/faction")
    Print("last error: " .. (lastError or "none"))
end

local function OnSlash(msg)
    if not db then Print("not loaded yet"); return end
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local word, arg = msg:match("^(%S+)%s*(%S*)")
    if not word or word == "help" then return PrintHelp() end
    if word == "status" then return PrintStatus() end
    if word == "on" or word == "off" then
        SetEnabled(word == "on")
        return Print("master " .. word)
    end
    if word == "open" then return StartOpenAll(false) end
    local f = FindFeature(word)
    if f and (arg == "on" or arg == "off") then
        SetFeature(f.key, arg == "on")
        return Print(f.label .. " " .. arg)
    elseif f then
        return Print(f.label .. " is " .. OnOff(db[f.key]) .. " - /gmail " .. f.cmd .. " on|off")
    end
    PrintHelp()
end

-- ---------------------------------------------------------------------------
-- Public API: GaarMailForeverAPI (for GaarForever's hub)
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state
--   MenuEntries()        the options as plain data: { text, checkbox = true, checked, func },
--                        { divider = true }, { text, submenu }, { text, func }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  no minimap button here, so it does nothing
-- ---------------------------------------------------------------------------

local function MenuEntries()
    if not db then return {} end
    local list = { { text = "GaarMailForever on", checkbox = true,
        checked = function() return db.enabled end, func = function() SetEnabled(not db.enabled) end },
        { divider = true } }
    for _, f in ipairs(FEATURES) do
        list[#list + 1] = { text = f.label, checkbox = true,
            checked = function() return db[f.key] end, func = function() SetFeature(f.key, not db[f.key]) end }
    end
    return list
end

_G.GaarMailForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries(), A.title) end,
    SetMinimapHidden = function() end,
}
_G.BetterMailForeverAPI = _G.GaarMailForeverAPI -- the name before the folder rename

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    BF.Migrate("GaarMailForeverDB", "BetterMailForeverDB") -- the old folder's settings, once (see Lib.lua)
    if type(GaarMailForeverDB) ~= "table" then GaarMailForeverDB = {} end
    db = GaarMailForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    if type(db.enabled) ~= "boolean" then db.enabled = true end
    for _, f in ipairs(FEATURES) do
        if type(db[f.key]) ~= "boolean" then db[f.key] = f.def end
    end
    local recent = {}
    if type(db.recent) == "table" then
        for _, n in ipairs(db.recent) do
            if type(n) == "string" and n ~= "" and #recent < MAX_RECENT then recent[#recent + 1] = n end
        end
    end
    db.recent = recent
    local alts = {}
    if type(db.alts) == "table" then
        for k, list in pairs(db.alts) do
            if type(k) == "string" and type(list) == "table" then
                local clean = {}
                for _, n in ipairs(list) do if type(n) == "string" and n ~= "" then clean[#clean + 1] = n end end
                DedupeAlts(clean)
                alts[k] = clean
            end
        end
    end
    db.alts = alts
end

-- Right-click the mailbox window's round portrait: the addon's menu (hub helper).
local function AttachPortraitMenu()
    if type(BF.AttachMenu) ~= "function" or type(_G.MailFrame) ~= "table" then return end
    BF.AttachMenu(_G.MailFrame, { title = "GaarMailForever", api = "GaarMailForeverAPI",
        portrait = true, propagate = true, names = { "MailFramePortrait" }, name = "GaarMailForeverPortraitButton" })
end

local function CreateFrames()
    pcall(AttachPortraitMenu)
    CreateOpenButton()
    CreateRecipientButton()
    HookRecipientBox()
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE",
    "MAIL_SUCCESS", "MAIL_SEND_INFO_UPDATE", "MAIL_SEND_SUCCESS", "MAIL_FAILED", "UI_ERROR_MESSAGE", "UPDATE_PENDING_MAIL" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1, arg2)
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then BindSavedVariables() end
        elseif not db then
            return
        elseif event == "PLAYER_LOGIN" then
            RecordAlt()
            CreateFrames()
            InstallItemHooks()
            if type(_G.hooksecurefunc) == "function" and type(_G.SendMailFrame_Update) == "function" then
                hooksecurefunc("SendMailFrame_Update", function() Safe("subject", OnAttachChanged) end)
            end
            if type(_G.hooksecurefunc) == "function" and type(_G.SendMail) == "function" then
                hooksecurefunc("SendMail", function(to)
                    if Feature("recipients") then pendingTo = Str(to) end
                end)
            end
            if type(_G.C_Timer) == "table" and type(_G.C_Timer.After) == "function" then
                _G.C_Timer.After(4, function() Safe("notice", AnnounceMail) end)
            end
        elseif event == "MAIL_SHOW" then
            mailOpen = true
            announced = false
            CreateFrames()
            Safe("position open all", PositionOpenButton)
            Refresh()
        elseif event == "MAIL_CLOSED" then
            mailOpen = false
            Finish("mailbox closed")
            HideMenu()
        elseif event == "MAIL_INBOX_UPDATE" or event == "MAIL_SUCCESS" then
            Answered()
        elseif event == "MAIL_SEND_INFO_UPDATE" then
            OnAttachChanged()
        elseif event == "MAIL_SEND_SUCCESS" then
            lastDefault = nil
            if pendingTo then AddRecent(pendingTo) end
            pendingTo = nil
        elseif event == "MAIL_FAILED" then
            pendingTo = nil
        elseif event == "UI_ERROR_MESSAGE" then
            local msg = Str(arg2)
            if run and msg and msg == _G.ERR_INV_FULL then Finish("bags are full") end
        elseif event == "UPDATE_PENDING_MAIL" then
            AnnounceMail()
        end
    end)
    if not ok then Fail(event, err) end
end)

SLASH_GAARMAILFOREVER1 = "/gmail"
SLASH_GAARMAILFOREVER2 = "/gaarmailforever"
SLASH_GAARMAILFOREVER3 = "/bmail" -- the command before the Gaar rename
SLASH_GAARMAILFOREVER4 = "/bettermailforever"
SlashCmdList.GAARMAILFOREVER = function(msg)
    Safe("slash", OnSlash, msg)
end
