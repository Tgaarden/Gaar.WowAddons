--[[
  GaarBarsForever - Flyouts.lua: flyouts on action buttons (the `flyouts` feature), "Flyouts v2".

  What it does:
    * A flyout is an object of its own: an id, a name, an icon (nil = entry 1's icon) and an
      ordered list of up to 12 entries (spells, items, macros). Saved per character in
      GaarBarsForeverCharDB.flyouts2 (id -> flyout).
    * Each flyout is carried on the bars by its own macro ("GF <name>", at most 16 characters),
      created and kept up to date out of combat with CreateMacro / EditMacro: a character macro,
      an account macro when those are full, a chat line when both are full. Its body is
      "#showtooltip" plus a line that casts or uses entry 1, so the button still does something
      sensible with the addon off; its icon is the flyout's icon.
    * An action slot "has a flyout" when it holds one of those macros: by the macro's name
      (GetActionText), else by the macro index -> flyout id map in GaarBarsForeverCharDB
      (flyoutMacros), which is re-resolved by name whenever the macros change (UPDATE_MACROS;
      macros are re-indexed when one is created, renamed or deleted). A plain Travel Form on
      another button is a normal button. Moving the macro moves the flyout.
    * While the cursor holds a spell, an item or a macro (out of combat), a small "+" sits on
      every bar button that has an action. Dropped on the "+" of a flyout's button, the thing is
      added to that flyout. Dropped on the "+" of any other button, a NEW flyout is made: entry 1
      = the button's action, entry 2 = the dropped thing, named after entry 1, with entry 1's
      icon; its macro replaces the button's action (PickupMacro + PlaceAction, cursor cleared).
    * A button with a flyout gets a small arrow. Clicking it, or pressing its key, opens the
      flyout and casts nothing. While it is open, 1-9, 0, - and = cast entry 1-12; clicking an
      entry casts it too. Casting, Escape, clicking the button again or clicking elsewhere closes
      it. Pressing the button's own key again while its flyout is open casts entry 1 and closes it
      (flyoutSameKeyCast, default on; off: the key closes it). All of this works in combat.
    * Right-clicking a button with a flyout casts the flyout's first entry without opening it
      (works in combat; nothing happens when that entry is an item you have none of, as decided
      out of combat). /gbars status says on how many overlays the right-click action is set.
    * The entries look like the game's own flyout buttons: icon frame, cooldown swipe, red when
      out of range, blue without mana, grey when unusable, the item count, the key that casts it.
    * Out of combat: right-click an entry, or drag it out, to remove it (dragging puts it on the
      cursor). A flyout is kept however few entries it has; it is deleted only in the editor
      (FlyoutEditor.lua, /gbars flyouts). In combat a short chat line says it has to wait.
    * Flyouts of 1.5.x ("v1", keyed by the button's action) are converted once, out of combat:
      each becomes a v2 flyout with its own macro, and every bar slot (1-180, paged main bar
      slots included) that holds that action and showed that flyout gets the macro instead. The
      old data is kept in GaarBarsForeverCharDB.flyoutsV1Backup; the result is said once in chat
      and in /gbars status.
    * /gbars flyout on|off (the `flyouts` switch, default on), /gbars flyout dir up|down|left|right
      (account-wide, default up), /gbars flyout samekey on|off, a line in /gbars status. Off
      while FallensFlyouts is loaded.

  The secure part (it must work in combat, where addon code may not show, hide, bind or set
  attributes on secure frames):
    * A header of ours (SecureHandlerStateTemplate) holds the shared state and three restricted
      snippets: "toggle" (anchor the slot's flyout to the clicked overlay, show it, bind 1-12 and
      Escape with SetBindingClick on the header), "close" (hide it, ClearBindings) and "sync"
      (which overlays are live, and their key bindings).
    * One flyout frame per action slot that holds a flyout's macro (protected, parked on
      UIParent), with SecureActionButtonTemplate entries (type1 = spell / item / macro / action).
      Each entry's OnClick is wrapped (SecureHandlerWrapScript) so a left release closes the
      flyout after the cast. The entries cast on release (useOnKeyDown = false), so a drag never
      casts.
    * One overlay (SecureActionButtonTemplate) over each Blizzard button that may show a flyout,
      a child of that button. Only a live overlay is shown and bound; the button's own keys
      (GetBindingKey of its ACTIONBUTTONn / MULTIACTIONBARmBUTTONn binding) are override-click
      bindings to it with the button name "Keybind", so its wrap can tell a key from the mouse
      (a wrap's preBody gets the click's button; GetMouseButtonClicked cannot tell a binding
      click apart). Its OnClick is wrapped (SecureHandlerWrapScript): a left click or a key runs
      "toggle" and returns false, so the secure action never runs; the key while this slot's
      flyout is open (and flyoutSameKeyCast on) closes it and returns "RightButton", so the
      overlay's right-click action runs; a right click closes any open flyout and lets the
      secure action run: type2 / spell2 / item2 / macro2 / action2, the slot's entry 1. Those
      come from the header's first<slot>type / first<slot>value (filled out of combat) and are
      put on the overlay by "setfirst", run from "sync" (so they follow the main bar's page in
      combat) and again right before the action. A restricted handle has no :Click(), so the
      action must sit on the overlay itself. useOnKeyDown = false: the action runs on the
      release, whatever ActionButtonUseKeyDown says. The Blizzard button's attributes, scripts
      and bindings are never touched; with no live overlay, the button is exactly Blizzard's.
    * The main bar pages (stances, forms, stealth, shift-page): a state driver on the header
      ("[bar:2]2 ... [bonusbar:1]7 ... 1") runs "sync" on every page change, so in combat the
      overlay over ActionButtonN follows the slot the bar shows. /gbars status says whether that
      mapping matches the bar out of combat; if it does not, the main bar overlays stay on the
      slot the bar showed out of combat.
    * A full-screen catcher button (BACKGROUND strata, only while a flyout is open) closes it on
      a click in the world; out of combat, GLOBAL_MOUSE_DOWN elsewhere closes it too.
    * Frames, attributes, frame refs, wraps, bindings, macros and bar slots are changed only out
      of combat; anything that changes in combat waits for PLAYER_REGEN_ENABLED. No COMBAT_LOG
      event is used. GetTime is not used in restricted code (it is not there).
    * Secret values are never compared: reads go through the main file's Secret / Num / FieldOf /
      CallOf helpers, and a secret answer only goes into a widget setter that takes it.
]]

local _G = _G
local ADDON_NAME, NS = ...
if type(NS) ~= "table" or type(NS.Bars) ~= "table" then return end

local B = NS.Bars
local Secret, Num, Str, FieldOf, CallOf, InCombat = B.Secret, B.Num, B.Str, B.FieldOf, B.CallOf, B.InCombat

local FEATURE = "flyouts"
local BLOCKER = "FallensFlyouts"
local MAX_ENTRIES = 12
local MAX_SLOT = 180
local GAP = 4
local TICK = 0.2
local COMBAT_MSG = "flyouts can only be changed out of combat."
local KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=" }
local DIRS = { up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT" }
local MACRO = { prefix = "GF ", nameMax = 16, bodyMax = 255, qmark = 134400, nameMaxFlyout = 40 }

-- The main bar's page as macro conditions: the same order Blizzard pages it (a page picked with
-- shift-N or the arrows wins over a stance / form bar; override, vehicle and possess bars hide
-- our overlays: page 0).
local PAGE_COND = "[overridebar][vehicleui][possessbar]0;[bar:2]2;[bar:3]3;[bar:4]4;[bar:5]5;[bar:6]6;"
    .. "[bonusbar:1]7;[bonusbar:2]8;[bonusbar:3]9;[bonusbar:4]10;[bonusbar:5]11;1"
local PAGE_COND_SHORT = "[bar:2]2;[bar:3]3;[bar:4]4;[bar:5]5;[bar:6]6;"
    .. "[bonusbar:1]7;[bonusbar:2]8;[bonusbar:3]9;[bonusbar:4]10;[bonusbar:5]11;1"

-- The bars whose buttons can carry a flyout, with the binding each button's keys come from.
local BARS = {
    { "ActionButton", "ACTIONBUTTON", main = true },
    { "MultiBarBottomLeftButton", "MULTIACTIONBAR1BUTTON" },
    { "MultiBarBottomRightButton", "MULTIACTIONBAR2BUTTON" },
    { "MultiBarRightButton", "MULTIACTIONBAR3BUTTON" },
    { "MultiBarLeftButton", "MULTIACTIONBAR4BUTTON" },
    { "MultiBar5Button", "MULTIACTIONBAR5BUTTON" },
    { "MultiBar6Button", "MULTIACTIONBAR6BUTTON" },
    { "MultiBar7Button", "MULTIACTIONBAR7BUTTON" },
}

local RGB = {
    white = { 1, 1, 1 }, red = { 0.8, 0.1, 0.1 }, blue = { 0.5, 0.5, 1.0 }, grey = { 0.4, 0.4, 0.4 },
}

-- ---------------------------------------------------------------------------
-- Restricted snippets (run by the client's secure code, also in combat)
-- ---------------------------------------------------------------------------

local SNIP = {}

-- Header: hide the open flyout, drop the 1-12 / Escape bindings and the catcher.
SNIP.close = [[
    local open = self:GetAttribute("open") or 0
    if open ~= 0 then
        local f = self:GetFrameRef("fly" .. open)
        if f then f:Hide() end
    end
    self:SetAttribute("open", 0)
    self:ClearBindings()
    local c = self:GetFrameRef("catcher")
    if c then c:Hide() end
]]

-- Header: bind 1-12 to the open flyout's shown entries and Escape to the catcher.
SNIP.bindopen = [[
    self:ClearBindings()
    local open = self:GetAttribute("open") or 0
    if open == 0 then return end
    local f = self:GetFrameRef("fly" .. open)
    if not f then return end
    local n = f:GetAttribute("n") or 0
    for i = 1, n do
        local key, target = self:GetAttribute("k" .. i), f:GetAttribute("e" .. i)
        if key and target then self:SetBindingClick(true, key, target, "LeftButton") end
    end
    local closer = self:GetAttribute("closer")
    if closer then self:SetBindingClick(true, "ESCAPE", closer, "LeftButton") end
]]

-- Header: ... = slot, overlay index. Open that slot's flyout at that overlay, or close it.
SNIP.toggle = [[
    local slot, ov = ...
    local open = self:GetAttribute("open") or 0
    self:RunAttribute("close")
    if not slot or slot == open or not self:GetAttribute("has" .. slot) then return end
    local f = self:GetFrameRef("fly" .. slot)
    local o = self:GetFrameRef("ov" .. (ov or 0))
    if not f or not o or (f:GetAttribute("n") or 0) == 0 then return end
    local dir = self:GetAttribute("dir") or "UP"
    f:ClearAllPoints()
    if dir == "DOWN" then
        f:SetPoint("TOP", o, "BOTTOM", 0, -4)
    elseif dir == "LEFT" then
        f:SetPoint("RIGHT", o, "LEFT", -4, 0)
    elseif dir == "RIGHT" then
        f:SetPoint("LEFT", o, "RIGHT", 4, 0)
    else
        f:SetPoint("BOTTOM", o, "TOP", 0, 4)
    end
    f:Show()
    self:SetAttribute("open", slot)
    self:RunAttribute("bindopen")
    local c = self:GetFrameRef("catcher")
    if c then c:Show() end
]]

-- Header: which overlays are live (their slot has a flyout) and their key bindings.
SNIP.sync = [[
    local page = tonumber(self:GetAttribute("page")) or 1
    local n = self:GetAttribute("novs") or 0
    for j = 1, n do
        local o = self:GetFrameRef("ov" .. j)
        if o then
            local slot = o:GetAttribute("fixedslot")
            local mid = o:GetAttribute("mainid")
            if mid then slot = (page - 1) * 12 + mid end
            o:ClearBindings()
            if slot and slot > 0 and self:GetAttribute("has" .. slot) then
                o:SetAttribute("curslot", slot)
                self:RunAttribute("setfirst", j, slot)
                o:Show()
                local me = o:GetAttribute("myname")
                local nk = o:GetAttribute("nkeys") or 0
                for k = 1, nk do
                    local key = o:GetAttribute("key" .. k)
                    if key and me then o:SetBindingClick(false, key, me, "Keybind") end
                end
            else
                o:SetAttribute("curslot", 0)
                self:RunAttribute("setfirst", j, 0)
                o:Hide()
            end
        end
    end
]]

-- Header state driver: the main bar changed page.
SNIP.page = [[
    self:SetAttribute("page", newstate)
    self:RunAttribute("close")
    self:RunAttribute("sync")
]]

-- Run out of combat after the data changed: keep an open flyout open if it still exists.
SNIP.refresh = [[
    local open = self:GetAttribute("open") or 0
    if open ~= 0 and not self:GetAttribute("has" .. open) then self:RunAttribute("close") end
    self:RunAttribute("sync")
    if (self:GetAttribute("open") or 0) ~= 0 then self:RunAttribute("bindopen") end
]]

-- Header: ... = overlay index, slot. Put the slot's entry 1 on that overlay as its right-click
-- action (type2 + spell2 / item2 / macro2 / action2), or clear it (no slot, or entry 1 is an
-- item you have none of: then right click does nothing).
SNIP.setfirst = [[
    local j, slot = ...
    local o = self:GetFrameRef("ov" .. (j or 0))
    if not o then return end
    local t, v
    if slot and slot > 0 then
        t = self:GetAttribute("first" .. slot .. "type")
        v = self:GetAttribute("first" .. slot .. "value")
    end
    if not t or v == nil then t, v = nil, nil end
    o:SetAttribute("spell2", nil)
    o:SetAttribute("item2", nil)
    o:SetAttribute("macro2", nil)
    o:SetAttribute("action2", nil)
    o:SetAttribute("type2", t)
    if t then o:SetAttribute(t .. "2", v) end
]]

-- Overlay OnClick wrap (header environment, self = the overlay). Right click: close any open
-- flyout, make sure the action is the current slot's entry 1, and let the secure action run.
-- The button's key ("Keybind", from the override binding) while this slot's flyout is open and
-- the header's "samekey" is on: close it and run the right-click action instead (a preBody may
-- return the button to use). Anything else (left click, the keys): toggle the flyout and cancel
-- the secure action.
SNIP.overlayPre = [[
    local h = owner or self:GetFrameRef("h")
    local slot = self:GetAttribute("curslot") or 0
    local ovid = self:GetAttribute("ovid")
    if button == "RightButton" then
        if h then
            h:RunAttribute("close")
            h:RunAttribute("setfirst", ovid, slot)
        end
        return
    end
    if h and slot > 0 and not down then
        if button == "Keybind" and h:GetAttribute("samekey") and (h:GetAttribute("open") or 0) == slot then
            h:RunAttribute("close")
            h:RunAttribute("setfirst", ovid, slot)
            return "RightButton"
        end
        h:RunAttribute("toggle", slot, ovid)
    end
    return false
]]

SNIP.catcherClick = [[
    local h = self:GetFrameRef("h")
    if h then h:RunAttribute("close") end
]]

-- Entry OnClick wrap: after a left release (the cast), close the flyout.
SNIP.entryPre = [[
    if button == "LeftButton" and not down then return nil, "close" end
]]
SNIP.entryPost = [[
    local h = owner or self:GetFrameRef("h")
    if h then h:RunAttribute("close") end
]]

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local FL = {}          -- public: Apply, Refresh, StatusLine, SlashDir, SlashSameKey, editor API
NS.Flyouts = FL
B.Flyouts = FL

local H = {}           -- helpers

local S = {
    loaded = false, pending = false, dirty = false, err = nil,
    header = nil, catcher = nil, clock = nil,
    world = false,      -- PLAYER_ENTERING_WORLD seen: macros and bars can be read and changed
    byMacro = {},       -- macro name -> flyout
    slotFly = {},       -- slot -> flyout, as last built
    applied = {},       -- flyout id -> macro name/icon/body last written or found
    fullWarned = {},    -- flyout id -> "no free macro slot" said this session
    flys = {},          -- slot -> flyout frame
    ovs = {},           -- overlay list (index = its "ovid")
    ovByButton = {},    -- Blizzard button -> overlay
    plus = {},          -- Blizzard button -> "+" button
    active = {},        -- slot -> entry list, as last built
    shown = {},         -- flyout frames shown now
    live = 0,           -- overlays in use at the last build
    driverOn = false, cond = PAGE_COND,
    pagingOk = true, pagingNote = "not checked",
    elapsed = 0,
}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

function H.Print(msg) if type(B.Print) == "function" then B.Print(msg) end end

function H.Err(where, err)
    S.err = where .. ": " .. tostring(err)
    if type(B.Fail) == "function" then B.Fail("flyouts " .. where, err) end
end

function H.Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then H.Err(where, err) end
    return ok
end

function H.DB() return type(B.DB) == "function" and B.DB() or nil end

function H.Blocked()
    local C = _G.C_AddOns
    local f = (type(C) == "table" and type(C.IsAddOnLoaded) == "function" and C.IsAddOnLoaded)
        or (type(_G.IsAddOnLoaded) == "function" and _G.IsAddOnLoaded) or nil
    if not f then return false end
    local ok, loaded = pcall(f, BLOCKER)
    return ok and not Secret(loaded) and loaded and true or false
end

function H.Active()
    return S.loaded and type(B.On) == "function" and B.On(FEATURE) == true and not H.Blocked()
end

function H.Dir()
    local db = H.DB()
    local d = db and db.flyoutDir
    return DIRS[d] and d or "up"
end

-- Same key casts entry 1 while the flyout is open (account-wide, default on).
function H.SameKey()
    local db = H.DB()
    return not (db and db.flyoutSameKeyCast == false)
end

function H.CharDB()
    local d = _G.GaarBarsForeverCharDB
    if type(d) ~= "table" then
        d = {}
        _G.GaarBarsForeverCharDB = d
    end
    return d
end

-- The v2 flyouts: id -> { id, name, icon, macro, macroIndex, entries }.
function H.Store()
    local d = H.CharDB()
    if type(d.flyouts2) ~= "table" then d.flyouts2 = {} end
    return d.flyouts2
end

-- The flyouts in id order.
function H.Sorted()
    local out = {}
    for _, f in pairs(H.Store()) do out[#out + 1] = f end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function H.Atlas(tex, name)
    local CT = _G.C_Texture
    if type(CT) ~= "table" or type(CT.GetAtlasInfo) ~= "function" then return false end
    local ok, info = pcall(CT.GetAtlasInfo, name)
    if not ok or type(info) ~= "table" then return false end
    return (pcall(tex.SetAtlas, tex, name))
end

function H.Exec(frame, body)
    if type(_G.SecureHandlerExecute) == "function" then
        _G.SecureHandlerExecute(frame, body)
    elseif type(frame.Execute) == "function" then
        frame:Execute(body)
    end
end

function H.ClearCursor()
    if type(_G.ClearCursor) == "function" then pcall(_G.ClearCursor) end
end

function H.Plain(v)
    if Secret(v) then return nil end
    return v
end

-- ---------------------------------------------------------------------------
-- Actions, entries, cursor
-- ---------------------------------------------------------------------------

function H.HasAction(slot)
    if type(_G.HasAction) ~= "function" then return false end
    local ok, v = pcall(_G.HasAction, slot)
    if not ok then return false end
    if Secret(v) then return true end
    return v and true or false
end

-- The action slot a Blizzard button shows now (read only).
function H.ButtonSlot(btn)
    local a = Num(FieldOf(btn, "action"))
    if not a or a <= 0 then a = Num(CallOf(btn, "GetAttribute", "action")) end
    return (a and a > 0) and a or nil
end

function H.MacroName(index)
    if type(_G.GetMacroInfo) ~= "function" then return nil end
    local ok, name = pcall(_G.GetMacroInfo, index)
    return ok and Str(name) or nil
end

function H.SameEntry(a, b)
    return a.t == b.t and a.id == b.id and a.name == b.name
end

function H.Key(e)
    if e.t == "macro" then return "macro:" .. e.name end
    if e.t == "action" then return "slot:" .. e.id end
    return e.t .. ":" .. e.id
end

-- What a slot holds, as an entry: spell / item / macro, else the slot itself (type "action").
function H.SlotEntry(slot)
    if type(_G.GetActionInfo) == "function" then
        local ok, kind, id = pcall(_G.GetActionInfo, slot)
        if ok and not Secret(kind) and not Secret(id) then
            local n = Num(id)
            if kind == "spell" and n and n > 0 then return { t = "spell", id = n } end
            if kind == "item" and n and n > 0 then return { t = "item", id = n } end
            if kind == "macro" then
                local name
                if type(_G.GetActionText) == "function" then
                    local okT, txt = pcall(_G.GetActionText, slot)
                    name = okT and Str(txt) or nil
                end
                name = name or (n and H.MacroName(n))
                if name then return { t = "macro", name = name } end
            end
        end
    end
    return { t = "action", id = slot }
end

-- 1.5.x (v1) data: the flyout list a slot showed (by its action, else by the slot), and the
-- slot's own entry. Only the conversion to v2 uses it.
function H.V1ListForSlot(slot, data)
    local own = H.SlotEntry(slot)
    local list = data[H.Key(own)]
    if not list and own.t ~= "action" then list = data["slot:" .. slot] end
    return list, own
end

-- The cursor's spell, item or macro as an entry, else nil.
function H.CursorEntry()
    if type(_G.GetCursorInfo) ~= "function" then return nil end
    local ok, kind, a, b, c = pcall(_G.GetCursorInfo)
    if not ok or Secret(kind) then return nil end
    if kind == "spell" then
        local id = Num(H.Plain(c))
        if not id and type(B.SlotSpellID) == "function" then
            local plainB = H.Plain(b)
            id = B.SlotSpellID(H.Plain(a), plainB == "pet" or plainB == 1)
        end
        if id and id > 0 then return { t = "spell", id = id } end
    elseif kind == "item" then
        local id = Num(H.Plain(a))
        if id and id > 0 then return { t = "item", id = id } end
    elseif kind == "macro" then
        local idx = Num(H.Plain(a))
        local name = idx and H.MacroName(idx)
        -- A flyout's own macro is not an entry (it is what a flyout is carried by).
        if name and not S.byMacro[name] then return { t = "macro", name = name } end
    end
    return nil
end

function H.ItemCount(id)
    local C = _G.C_Item
    local f = (type(C) == "table" and type(C.GetItemCount) == "function" and C.GetItemCount)
        or (type(_G.GetItemCount) == "function" and _G.GetItemCount) or nil
    if not f then return nil end
    local ok, n = pcall(f, id)
    if not ok then return nil end
    return n
end

-- Out of combat: is the entry shown in the open flyout? (Items you have none of are not.)
function H.EntryShown(e)
    if e.t ~= "item" then return true end
    local n = H.ItemCount(e.id)
    if n == nil or Secret(n) then return true end
    return (Num(n) or 0) > 0
end

function H.ItemIDFromLink(link)
    link = Str(link)
    local id = link and link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

-- What to read state from: spell id, item id or action slot.
function H.Resolve(e)
    if e.t == "spell" then return e.id, nil, nil end
    if e.t == "item" then return nil, e.id, nil end
    if e.t == "action" then return nil, nil, e.id end
    if e.t == "macro" then
        if type(_G.GetMacroSpell) == "function" then
            local ok, id = pcall(_G.GetMacroSpell, e.name)
            id = ok and Num(H.Plain(id)) or nil
            if id and id > 0 then return id, nil, nil end
        end
        if type(_G.GetMacroItem) == "function" then
            local ok, _, link = pcall(_G.GetMacroItem, e.name)
            local id = ok and H.ItemIDFromLink(H.Plain(link)) or nil
            if id then return nil, id, nil end
        end
    end
    return nil, nil, nil
end

function H.EntryIcon(e)
    local tex
    if e.t == "spell" then
        local C = _G.C_Spell
        local f = (type(C) == "table" and type(C.GetSpellTexture) == "function" and C.GetSpellTexture)
            or (type(_G.GetSpellTexture) == "function" and _G.GetSpellTexture) or nil
        if f then
            local ok, t = pcall(f, e.id)
            if ok then tex = t end
        end
    elseif e.t == "item" then
        local C = _G.C_Item
        local f = (type(C) == "table" and type(C.GetItemIconByID) == "function" and C.GetItemIconByID)
            or (type(_G.GetItemIcon) == "function" and _G.GetItemIcon) or nil
        if f then
            local ok, t = pcall(f, e.id)
            if ok then tex = t end
        end
    elseif e.t == "macro" then
        if type(_G.GetMacroInfo) == "function" then
            local ok, _, t = pcall(_G.GetMacroInfo, e.name)
            if ok then tex = t end
        end
    elseif e.t == "action" then
        if type(_G.GetActionTexture) == "function" then
            local ok, t = pcall(_G.GetActionTexture, e.id)
            if ok then tex = t end
        end
    end
    if tex == nil then return MACRO.qmark end
    return tex
end

-- Pick an entry up onto the cursor (drag out of the flyout). Out of combat only.
function H.Pickup(e)
    if e.t == "spell" then
        local C = _G.C_Spell
        local f = (type(C) == "table" and type(C.PickupSpell) == "function" and C.PickupSpell)
            or (type(_G.PickupSpell) == "function" and _G.PickupSpell) or nil
        if f then pcall(f, e.id) end
    elseif e.t == "item" then
        local C = _G.C_Item
        local f = (type(C) == "table" and type(C.PickupItem) == "function" and C.PickupItem)
            or (type(_G.PickupItem) == "function" and _G.PickupItem) or nil
        if f then pcall(f, e.id) end
    elseif e.t == "macro" then
        if type(_G.PickupMacro) == "function" then pcall(_G.PickupMacro, e.name) end
    end
end

-- ---------------------------------------------------------------------------
-- Editing (out of combat only)
-- ---------------------------------------------------------------------------

function FL.CombatMsg() H.Print(COMBAT_MSG) end

-- Cut a string to at most n bytes without splitting a UTF-8 character.
function H.Cut(s, n)
    if #s <= n then return s end
    s = s:sub(1, n)
    local last = s:find("[\192-\255][\128-\191]*$")
    if last then
        local lead = s:byte(last)
        local need = (lead >= 240 and 4) or (lead >= 224 and 3) or 2
        if #s - last + 1 < need then s = s:sub(1, last - 1) end
    end
    return s
end

function H.Copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = H.Copy(x) end
    return out
end

-- Valid entries only, at most 12, no duplicates.
function H.CleanEntries(list)
    local clean = {}
    if type(list) ~= "table" then return clean end
    for _, e in ipairs(list) do
        if type(e) == "table" and #clean < MAX_ENTRIES then
            local x
            if (e.t == "spell" or e.t == "item" or e.t == "action") and type(e.id) == "number" then
                x = { t = e.t, id = e.id }
            elseif e.t == "macro" and type(e.name) == "string" and e.name ~= "" then
                x = { t = "macro", name = e.name }
            end
            if x then
                local dup = false
                for _, y in ipairs(clean) do
                    if H.SameEntry(x, y) then dup = true break end
                end
                if not dup then clean[#clean + 1] = x end
            end
        end
    end
    return clean
end

-- Saved data from an older or hand-edited file.
function H.Sanitize()
    local store, top = H.Store(), 0
    for k, f in pairs(store) do
        if type(k) ~= "number" or type(f) ~= "table" then
            store[k] = nil
        else
            f.id = k
            f.name = (type(f.name) == "string" and f.name ~= "") and f.name or ("Flyout " .. k)
            if type(f.macro) ~= "string" or f.macro == "" then f.macro = nil end
            if type(f.icon) ~= "number" and type(f.icon) ~= "string" then f.icon = nil end
            if type(f.macroIndex) ~= "number" then f.macroIndex = nil end
            f.entries = H.CleanEntries(f.entries)
            if k > top then top = k end
        end
    end
    local d = H.CharDB()
    if type(d.flyoutNextId) ~= "number" or d.flyoutNextId <= top then d.flyoutNextId = top + 1 end
end

function H.NewFlyout(name, entries)
    local d, store = H.CharDB(), H.Store()
    local id = math.max(Num(d.flyoutNextId) or 1, 1)
    while store[id] do id = id + 1 end
    d.flyoutNextId = id + 1
    name = (type(name) == "string" and name ~= "") and name or ("Flyout " .. id)
    local f = { id = id, name = H.Cut(name, MACRO.nameMaxFlyout), entries = entries or {} }
    store[id] = f
    return f
end

-- An entry's name, icon and rank text (for the editor, names and macros).
function H.EntryName(e)
    if type(e) ~= "table" then return nil end
    if e.t == "spell" then
        return (type(B.SpellName) == "function" and B.SpellName(e.id)) or ("Spell " .. e.id)
    elseif e.t == "item" then
        local n
        local C = _G.C_Item
        if type(C) == "table" and type(C.GetItemNameByID) == "function" then
            local ok, v = pcall(C.GetItemNameByID, e.id)
            n = ok and Str(v) or nil
        end
        if not n and type(_G.GetItemInfo) == "function" then
            local ok, v = pcall(_G.GetItemInfo, e.id)
            n = ok and Str(v) or nil
        end
        return n or ("Item " .. e.id)
    elseif e.t == "macro" then
        return e.name
    end
    return "Action " .. tostring(e.id)
end

function H.EntryRank(e)
    if type(e) == "table" and e.t == "spell" and type(B.SpellRank) == "function" then
        local r = B.SpellRank(e.id)
        if r then return "Rank " .. r end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The flyout macros (created and changed out of combat only)
-- ---------------------------------------------------------------------------

function H.MacroIndex(name)
    if type(name) ~= "string" or type(_G.GetMacroIndexByName) ~= "function" then return nil end
    local ok, i = pcall(_G.GetMacroIndexByName, name)
    i = ok and Num(H.Plain(i)) or nil
    return (i and i > 0) and i or nil
end

function H.MacroLimits()
    local C = type(_G.Constants) == "table" and _G.Constants.MacroConsts or nil
    local acc = (type(C) == "table" and Num(C.MAX_ACCOUNT_MACROS)) or Num(_G.MAX_ACCOUNT_MACROS) or 120
    local chr = (type(C) == "table" and Num(C.MAX_CHARACTER_MACROS)) or Num(_G.MAX_CHARACTER_MACROS) or 18
    return acc, chr
end

-- Macro name -> flyout, and the macro index -> flyout id map in the saved data; read only, so
-- it may run in combat. Macros are re-indexed when one is created, renamed or deleted.
function H.Reresolve()
    local byMacro, map = {}, {}
    for id, f in pairs(H.Store()) do
        if f.macro then
            byMacro[f.macro] = f
            local i = H.MacroIndex(f.macro)
            f.macroIndex = i
            if i then map[i] = id end
        end
    end
    S.byMacro = byMacro
    H.CharDB().flyoutMacros = map
end

-- The flyout whose macro a slot holds, else nil.
function H.SlotFlyout(slot)
    if type(_G.GetActionInfo) ~= "function" then return nil end
    local ok, kind, id = pcall(_G.GetActionInfo, slot)
    if not ok or Secret(kind) or kind ~= "macro" then return nil end
    if type(_G.GetActionText) == "function" then
        local okT, txt = pcall(_G.GetActionText, slot)
        local name = okT and Str(txt) or nil
        if name then return S.byMacro[name] end
    end
    -- No name: the slot's macro index through the saved map (checked against the macro's name).
    local n = not Secret(id) and Num(id) or nil
    local map = H.CharDB().flyoutMacros
    local fid = n and type(map) == "table" and map[n] or nil
    local f = fid and H.Store()[fid] or nil
    if f and f.macro and H.MacroName(n) == f.macro then return f end
    return nil
end

-- What the macro should hold: the flyout's icon (entry 1's when none is chosen) and a body that
-- casts or uses entry 1.
function H.MacroIcon(f)
    if f.icon ~= nil then return f.icon end
    if f.entries[1] then return H.EntryIcon(f.entries[1]) end
    return MACRO.qmark
end

function H.MacroBodyOf(name)
    if type(_G.GetMacroBody) == "function" then
        local ok, body = pcall(_G.GetMacroBody, name)
        if ok and type(body) == "string" then return body end
    end
    if type(_G.GetMacroInfo) == "function" then
        local ok, _, _, body = pcall(_G.GetMacroInfo, name)
        if ok and type(body) == "string" then return body end
    end
    return nil
end

function H.MacroBody(f)
    local e, line = f.entries[1], nil
    if e and e.t == "spell" then
        local n = type(B.SpellName) == "function" and B.SpellName(e.id) or nil
        if n then line = "/cast " .. n end
    elseif e and e.t == "item" then
        line = "/use item:" .. e.id
    elseif e and e.t == "macro" then
        local body = H.MacroBodyOf(e.name)
        if body then
            body = body:gsub("^#show[^\n]*\n?", "")
            body = body:gsub("%s+$", "")
            if body ~= "" then line = body end
        end
    end
    local text = "#showtooltip"
    if line and #text + 1 + #line <= MACRO.bodyMax then text = text .. "\n" .. line end
    return text
end

-- "GF <name>", at most 16 bytes, not the name of another flyout's macro or any other macro.
function H.UniqueMacroName(base, self)
    base = tostring(base or "Flyout"):gsub("[\r\n]", " ")
    local function Taken(n)
        for _, g in pairs(H.Store()) do
            if g ~= self and g.macro == n then return true end
        end
        if self and self.macro == n then return false end
        return H.MacroIndex(n) ~= nil
    end
    local stem = MACRO.prefix .. base
    local cand = H.Cut(stem, MACRO.nameMax)
    local k = 2
    while Taken(cand) and k < 100 do
        local suf = tostring(k)
        cand = H.Cut(stem, MACRO.nameMax - #suf) .. suf
        k = k + 1
    end
    return cand
end

-- A new macro: a character macro, else an account macro; nil (and one chat line per flyout and
-- session) when both are full.
function H.CreateMacro(f, name, icon, body)
    if type(_G.CreateMacro) ~= "function" then return nil end
    local nAcc, nChar = 0, 0
    if type(_G.GetNumMacros) == "function" then
        local ok, a, c = pcall(_G.GetNumMacros)
        if ok then nAcc, nChar = Num(H.Plain(a)) or 0, Num(H.Plain(c)) or 0 end
    end
    local maxAcc, maxChar = H.MacroLimits()
    local tries = {}
    if nChar < maxChar then tries[#tries + 1] = true end
    if nAcc < maxAcc then tries[#tries + 1] = false end
    for _, perChar in ipairs(tries) do
        local ok, idx = pcall(_G.CreateMacro, name, icon, body, perChar)
        idx = ok and Num(H.Plain(idx)) or nil
        if idx and idx > 0 then return idx end
    end
    if not S.fullWarned[f.id] then
        S.fullWarned[f.id] = true
        H.Print("no free macro slot: your character and account macros are both full, so flyout \""
            .. f.name .. "\" has no macro and cannot sit on a bar. Delete a macro (/macro) to make room.")
    end
    return nil
end

-- Make sure the flyout's macro exists and holds the right name, icon and body. Returns its
-- index, or nil. Out of combat only (and only once the game has loaded the macros).
function H.EnsureMacro(f)
    if InCombat() or not S.world then return nil end
    local icon, body = H.MacroIcon(f), H.MacroBody(f)
    local idx = f.macro and H.MacroIndex(f.macro) or nil
    if not idx then
        local name = H.UniqueMacroName(f.name, f)
        idx = H.CreateMacro(f, name, icon, body)
        if not idx then return nil end
        f.macro = name
        S.applied[f.id] = name .. "\n" .. tostring(icon) .. "\n" .. body
        H.Reresolve()
        return H.MacroIndex(name) or idx
    end
    local sig = f.macro .. "\n" .. tostring(icon) .. "\n" .. body
    if S.applied[f.id] == sig then return idx end
    local curIcon, curBody
    if type(_G.GetMacroInfo) == "function" then
        local ok, _, ic, bd = pcall(_G.GetMacroInfo, idx)
        if ok then curIcon, curBody = H.Plain(ic), H.Plain(bd) end
    end
    local same = type(curBody) == "string" and curBody:gsub("%s+$", "") == body and curIcon == icon
    if not same and type(_G.EditMacro) == "function" then pcall(_G.EditMacro, idx, f.macro, icon, body) end
    S.applied[f.id] = sig
    return H.MacroIndex(f.macro) or idx
end

function H.EnsureMacros()
    if not S.world then return end
    for _, f in ipairs(H.Sorted()) do H.EnsureMacro(f) end
    H.Reresolve()
end

-- Put the flyout's macro into an action slot (the slot's old action is dropped from the cursor).
function H.PlaceMacro(f, slot)
    if InCombat() or type(_G.PickupMacro) ~= "function" or type(_G.PlaceAction) ~= "function" then return false end
    local i = H.MacroIndex(f.macro)
    if not i then return false end
    H.ClearCursor()
    local ok = pcall(_G.PickupMacro, i)
    if ok then ok = pcall(_G.PlaceAction, slot) end
    H.ClearCursor()
    return ok and true or false
end

-- Add an entry: "added", "dup" or "full" (with a chat line).
function H.AddEntry(f, e)
    for _, x in ipairs(f.entries) do
        if H.SameEntry(x, e) then return "dup" end
    end
    if #f.entries >= MAX_ENTRIES then
        H.Print("flyout \"" .. f.name .. "\" is full (" .. MAX_ENTRIES .. " entries).")
        return "full"
    end
    f.entries[#f.entries + 1] = e
    return "added"
end

-- The "+" on a bar button: add the cursor's thing to that button's flyout, or make a new flyout
-- of the button's action and the cursor's thing whose macro then takes the button's place.
function H.AddToButton(btn)
    if InCombat() then FL.CombatMsg() return end
    if not H.Active() then return end
    local e = H.CursorEntry()
    if not e then return end
    local slot = H.ButtonSlot(btn)
    if not slot or not H.HasAction(slot) then return end
    H.Reresolve()
    local f = H.SlotFlyout(slot)
    if f then
        if H.AddEntry(f, e) ~= "full" then H.ClearCursor() end
        FL.Refresh()
        return
    end
    local own = H.SlotEntry(slot)
    if own.t == "action" then
        H.Print("this button's action cannot go into a flyout (only spells, items and macros can).")
        return
    end
    if H.SameEntry(own, e) then H.ClearCursor() return end
    local nf = H.NewFlyout(H.EntryName(own), { own, e })
    if not H.EnsureMacro(nf) then
        H.Store()[nf.id] = nil -- no macro, no flyout; the cursor keeps its thing
        return
    end
    H.ClearCursor()
    H.PlaceMacro(nf, slot)
    H.Print("new flyout \"" .. nf.name .. "\" (2 entries), macro " .. nf.macro .. ". /gbars flyouts edits it.")
    FL.Refresh()
end

-- Remove entry `index` of the list shown at `slot`. The flyout stays, whatever is left.
function H.RemoveEntry(slot, index)
    if InCombat() then FL.CombatMsg() return false end
    local list = S.active[slot]
    if not list or not list[index] then return false end
    table.remove(list, index)
    FL.Refresh()
    return true
end

-- ---------------------------------------------------------------------------
-- 1.5.x flyouts (v1, keyed by the button's action) -> v2, once, out of combat
-- ---------------------------------------------------------------------------

function H.MigrateV1()
    local d = H.CharDB()
    if d.flyoutsV1Done or InCombat() or not S.world then return end
    local v1 = d.flyouts
    if type(v1) ~= "table" or next(v1) == nil then
        d.flyouts = nil
        d.flyoutsV1Done = true
        d.flyoutsV1Result = "nothing to convert"
        return
    end
    d.flyoutsV1Backup = H.Copy(v1)
    -- The lists v1 showed (two or more entries), and the slots that showed each, by the slot's
    -- own action: every slot 1-180, the main bar's paged slots (73-120 ...) included.
    local lists, keys = {}, {}
    for k, list in pairs(v1) do
        local clean = type(k) == "string" and H.CleanEntries(list) or {}
        if #clean >= 2 then
            lists[k] = clean
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    local slotsOf = {}
    for slot = 1, MAX_SLOT do
        if H.HasAction(slot) then
            local list, own = H.V1ListForSlot(slot, v1)
            local key = H.Key(own)
            -- Only a slot that holds the flyout's own action (not one keyed by its slot: that
            -- action cannot be cast from a macro, so it stays).
            if list and own.t ~= "action" and v1[key] == list and lists[key] then
                slotsOf[key] = slotsOf[key] or {}
                table.insert(slotsOf[key], slot)
            end
        end
    end
    local n, placed, noMacro = 0, 0, 0
    for _, k in ipairs(keys) do
        local list = lists[k]
        local f = H.NewFlyout(H.EntryName(list[1]), list)
        n = n + 1
        if H.EnsureMacro(f) then
            for _, slot in ipairs(slotsOf[k] or {}) do
                if H.PlaceMacro(f, slot) then placed = placed + 1 end
            end
        else
            noMacro = noMacro + 1
        end
    end
    d.flyouts = nil
    d.flyoutsV1Done = true
    local msg = string.format("converted %d flyout%s (%d bar button%s now hold their macro)",
        n, n == 1 and "" or "s", placed, placed == 1 and "" or "s")
    if noMacro > 0 then msg = msg .. string.format("; %d without a macro (macro slots full)", noMacro) end
    d.flyoutsV1Result = msg
    H.Reresolve()
    H.Print("flyouts v2: " .. msg .. ". /gbars flyouts opens the editor.")
end

-- ---------------------------------------------------------------------------
-- For the editor (FlyoutEditor.lua). Every change is out of combat only.
-- ---------------------------------------------------------------------------

function FL.CanEdit() return not InCombat() end
function FL.List() return H.Sorted() end
function FL.Get(id) return id and H.Store()[id] or nil end
function FL.EntryIcon(e) return H.EntryIcon(e) end
function FL.EntryName(e) return H.EntryName(e) end
function FL.EntryRank(e) return H.EntryRank(e) end
function FL.Icon(f) return H.MacroIcon(f) end
function FL.EntryTooltip(owner, e) H.Safe("tooltip", H.ShowEntryTooltip, owner, e, nil) end

-- How many bar slots hold the flyout's macro now.
function FL.SlotCount(f)
    local n = 0
    if not f or not f.macro then return 0 end
    for slot = 1, MAX_SLOT do
        if H.HasAction(slot) and H.SlotFlyout(slot) == f then n = n + 1 end
    end
    return n
end

function H.Editable()
    if InCombat() then FL.CombatMsg() return false end
    return true
end

function FL.New()
    if not H.Editable() then return nil end
    local f = H.NewFlyout(nil, {})
    if S.world and not H.EnsureMacro(f) then
        H.Store()[f.id] = nil
        return nil
    end
    FL.Refresh()
    return f
end

function FL.Delete(id)
    if not H.Editable() then return false end
    local f = FL.Get(id)
    if not f then return false end
    local i = f.macro and H.MacroIndex(f.macro)
    if i and type(_G.DeleteMacro) == "function" then pcall(_G.DeleteMacro, i) end
    H.Store()[id] = nil
    S.applied[id], S.fullWarned[id] = nil, nil
    H.Reresolve()
    FL.Refresh()
    return true
end

function FL.Rename(id, name)
    if not H.Editable() then return false end
    local f = FL.Get(id)
    name = type(name) == "string" and name:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if not f or name == "" or name == f.name then return false end
    f.name = H.Cut(name, MACRO.nameMaxFlyout)
    local i = f.macro and H.MacroIndex(f.macro)
    if i and type(_G.EditMacro) == "function" then
        local newName = H.UniqueMacroName(f.name, f)
        if pcall(_G.EditMacro, i, newName, H.MacroIcon(f), H.MacroBody(f)) then f.macro = newName end
        S.applied[id] = nil
    end
    H.Reresolve()
    FL.Refresh()
    return true
end

-- icon nil: use entry 1's icon.
function FL.SetIcon(id, icon)
    if not H.Editable() then return false end
    local f = FL.Get(id)
    if not f then return false end
    f.icon = icon
    FL.Refresh()
    return true
end

function FL.RemoveAt(id, index)
    if not H.Editable() then return false end
    local f = FL.Get(id)
    if not f or not f.entries[index] then return false end
    table.remove(f.entries, index)
    FL.Refresh()
    return true
end

function FL.Move(id, index, delta)
    if not H.Editable() then return false end
    local f = FL.Get(id)
    local j = index + (delta or 0)
    if not f or not f.entries[index] or not f.entries[j] then return false end
    f.entries[index], f.entries[j] = f.entries[j], f.entries[index]
    FL.Refresh()
    return true
end

-- Add what the cursor holds (a spell, an item or a macro) to the flyout.
function FL.AddCursor(id)
    if not H.Editable() then return false end
    local f = FL.Get(id)
    local e = H.CursorEntry()
    if not f or not e then return false end
    if H.AddEntry(f, e) ~= "full" then H.ClearCursor() end
    FL.Refresh()
    return true
end

-- Put the flyout's macro on the cursor, to drop on any bar button.
function FL.Pickup(id)
    if not H.Editable() then return false end
    local f = FL.Get(id)
    if not f then return false end
    local i = f.macro and H.MacroIndex(f.macro) or H.EnsureMacro(f)
    if not i or type(_G.PickupMacro) ~= "function" then return false end
    return (pcall(_G.PickupMacro, i))
end

function H.NotifyEditor()
    if type(B.FlyoutEditorRefresh) == "function" then pcall(B.FlyoutEditorRefresh) end
end

-- ---------------------------------------------------------------------------
-- Entry display (insecure: textures, cooldowns, colours, counts)
-- ---------------------------------------------------------------------------

function H.ColorObj(rgb)
    if rgb.obj == nil then
        rgb.obj = type(_G.CreateColor) == "function" and _G.CreateColor(rgb[1], rgb[2], rgb[3], 1) or false
    end
    return rgb.obj or nil
end

function H.RGB(tex, rgb) tex:SetVertexColor(rgb[1], rgb[2], rgb[3]) end

-- The client picks the colour from a boolean it may hide from us.
function H.FromBool(tex, flag, rgbTrue, rgbFalse)
    if type(tex.SetVertexColorFromBoolean) ~= "function" then return false end
    local cT, cF = H.ColorObj(rgbTrue), H.ColorObj(rgbFalse)
    if not cT or not cF then return false end
    return (pcall(tex.SetVertexColorFromBoolean, tex, flag, cT, cF))
end

function H.Paint(icon, okU, usable, noMana, inRange)
    if Secret(inRange) then
        local base = RGB.white
        if okU and not Secret(usable) and not Secret(noMana) then
            base = usable and RGB.white or (noMana and RGB.blue or RGB.grey)
        end
        if not H.FromBool(icon, inRange, base, RGB.red) then H.RGB(icon, base) end
    elseif inRange == false or inRange == 0 then
        H.RGB(icon, RGB.red)
    elseif not okU then
        H.RGB(icon, RGB.white)
    elseif Secret(usable) or Secret(noMana) then
        if not H.FromBool(icon, usable, RGB.white, RGB.grey) then H.RGB(icon, RGB.white) end
    elseif usable then
        H.RGB(icon, RGB.white)
    else
        H.RGB(icon, noMana and RGB.blue or RGB.grey)
    end
end

function H.TargetExists()
    if type(_G.UnitExists) ~= "function" then return false end
    local ok, v = pcall(_G.UnitExists, "target")
    if not ok then return false end
    if Secret(v) then return true end
    return v and true or false
end

-- usable-read ok, usable, noMana, inRange (nil: no target or no answer).
function H.ReadState(spell, item, slot)
    local okU, usable, noMana, inRange = false, nil, nil, nil
    local target = H.TargetExists()
    if spell then
        local C = _G.C_Spell
        local fu = (type(C) == "table" and type(C.IsSpellUsable) == "function" and C.IsSpellUsable)
            or (type(_G.IsUsableSpell) == "function" and _G.IsUsableSpell) or nil
        if fu then
            local ok, u, m = pcall(fu, spell)
            if ok then okU, usable, noMana = true, u, m end
        end
        if target then
            if type(C) == "table" and type(C.IsSpellInRange) == "function" then
                local ok, r = pcall(C.IsSpellInRange, spell, "target")
                if ok then inRange = r end
            elseif type(_G.IsSpellInRange) == "function" and type(B.SpellName) == "function" then
                local name = B.SpellName(spell)
                if name then
                    local ok, r = pcall(_G.IsSpellInRange, name, "target")
                    if ok then inRange = r end
                end
            end
        end
    elseif item then
        local C = _G.C_Item
        local fu = (type(C) == "table" and type(C.IsUsableItem) == "function" and C.IsUsableItem)
            or (type(_G.IsUsableItem) == "function" and _G.IsUsableItem) or nil
        if fu then
            local ok, u, m = pcall(fu, item)
            if ok then okU, usable, noMana = true, u, m end
        end
        if target then
            local fr = (type(C) == "table" and type(C.IsItemInRange) == "function" and C.IsItemInRange)
                or (type(_G.IsItemInRange) == "function" and _G.IsItemInRange) or nil
            if fr then
                local ok, r = pcall(fr, item, "target")
                if ok then inRange = r end
            end
        end
    elseif slot then
        if type(_G.IsUsableAction) == "function" then
            local ok, u, m = pcall(_G.IsUsableAction, slot)
            if ok then okU, usable, noMana = true, u, m end
        end
        if type(_G.IsActionInRange) == "function" then
            local ok, r = pcall(_G.IsActionInRange, slot)
            if ok then inRange = r end
        end
    end
    return okU, usable, noMana, inRange
end

-- start, duration, enabled (any may be secret), or nil.
function H.ReadCooldown(spell, item, slot)
    if spell then
        local C = _G.C_Spell
        if type(C) == "table" and type(C.GetSpellCooldown) == "function" then
            local ok, info = pcall(C.GetSpellCooldown, spell)
            if ok and type(info) == "table" and not Secret(info) then
                return info.startTime, info.duration, info.isEnabled
            elseif ok and Secret(info) then
                return nil
            end
        end
        if type(_G.GetSpellCooldown) == "function" then
            local ok, s, d, en = pcall(_G.GetSpellCooldown, spell)
            if ok then return s, d, en end
        end
    elseif item then
        local C = _G.C_Container
        local f = (type(C) == "table" and type(C.GetItemCooldown) == "function" and C.GetItemCooldown)
            or (type(_G.GetItemCooldown) == "function" and _G.GetItemCooldown) or nil
        if f then
            local ok, s, d, en = pcall(f, item)
            if ok then return s, d, en end
        end
    elseif slot then
        local C = _G.C_ActionBar
        if type(C) == "table" and type(C.GetActionCooldown) == "function" then
            local ok, info = pcall(C.GetActionCooldown, slot)
            if ok and type(info) == "table" and not Secret(info) then
                return info.startTime, info.duration, info.isEnabled
            end
        end
        if type(_G.GetActionCooldown) == "function" then
            local ok, s, d, en = pcall(_G.GetActionCooldown, slot)
            if ok then return s, d, en end
        end
    end
    return nil
end

function H.SetCooldown(cd, s, d, en)
    if Secret(s) or Secret(d) then
        -- Only the client can draw a secret timing; the setter takes it as it is.
        cd.gbS, cd.gbD = nil, nil
        pcall(cd.SetCooldown, cd, s, d)
        return
    end
    s, d = Num(s), Num(d)
    local enabled = Secret(en) or not (en == false or en == 0)
    if s and d and s > 0 and d > 0 and enabled then
        if cd.gbS ~= s or cd.gbD ~= d then
            cd.gbS, cd.gbD = s, d
            pcall(cd.SetCooldown, cd, s, d)
        end
    elseif cd.gbS ~= false then
        cd.gbS, cd.gbD = false, nil
        if type(cd.Clear) == "function" then pcall(cd.Clear, cd) else pcall(cd.SetCooldown, cd, 0, 0) end
    end
end

function H.UpdateEntry(b)
    local e = b.entry
    if not e then return end
    b.icon:SetTexture(H.EntryIcon(e))
    local spell, item, slot = H.Resolve(e)
    local okU, usable, noMana, inRange = H.ReadState(spell, item, slot)
    H.Paint(b.icon, okU, usable, noMana, inRange)
    H.SetCooldown(b.cd, H.ReadCooldown(spell, item, slot))
    local count
    if item then
        count = H.ItemCount(item)
    elseif slot and type(_G.IsConsumableAction) == "function" and type(_G.GetActionCount) == "function" then
        local ok, cons = pcall(_G.IsConsumableAction, slot)
        if ok and (Secret(cons) or cons) then
            local okC, n = pcall(_G.GetActionCount, slot)
            if okC then count = n end
        end
    end
    if count == nil then
        b.count:SetText("")
    elseif Secret(count) then
        pcall(b.count.SetText, b.count, count)
    else
        b.count:SetText(tostring(Num(count) or ""))
    end
end

function H.UpdateFly(f)
    for _, b in ipairs(f.e) do
        if b.entry and b:IsShown() then H.Safe("entry", H.UpdateEntry, b) end
    end
end

-- ---------------------------------------------------------------------------
-- Frames (created out of combat only)
-- ---------------------------------------------------------------------------

function H.EnsureHeader()
    if S.header then return S.header end
    local h = CreateFrame("Frame", "GaarBarsForeverFlyoutHeader", _G.UIParent, "SecureHandlerStateTemplate")
    for i, k in ipairs(KEYS) do h:SetAttribute("k" .. i, k) end
    h:SetAttribute("open", 0)
    h:SetAttribute("page", 1)
    h:SetAttribute("novs", 0)
    h:SetAttribute("close", SNIP.close)
    h:SetAttribute("bindopen", SNIP.bindopen)
    h:SetAttribute("toggle", SNIP.toggle)
    h:SetAttribute("sync", SNIP.sync)
    h:SetAttribute("setfirst", SNIP.setfirst)
    h:SetAttribute("_onstate-page", SNIP.page)

    local c = CreateFrame("Button", "GaarBarsForeverFlyoutCatcher", _G.UIParent, "SecureHandlerClickTemplate")
    c:SetAllPoints(_G.UIParent)
    c:SetFrameStrata("BACKGROUND")
    c:EnableMouse(true)
    c:RegisterForClicks("AnyDown")
    c:SetAttribute("_onclick", SNIP.catcherClick)
    c:Hide()
    _G.SecureHandlerSetFrameRef(c, "h", h)
    _G.SecureHandlerSetFrameRef(h, "catcher", c)
    h:SetAttribute("closer", c:GetName())

    S.header, S.catcher = h, c
    return h
end

function H.EnsureEntry(f, i)
    local b = f.e[i]
    if b then return b end
    b = CreateFrame("Button", f:GetName() .. "Entry" .. i, f, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:RegisterForDrag("LeftButton")
    b:SetAttribute("useOnKeyDown", false)

    b.icon = b:CreateTexture(nil, "BACKGROUND")
    b.icon:SetAllPoints(b)
    if type(b.CreateMaskTexture) == "function" then
        local m = b:CreateMaskTexture()
        if H.Atlas(m, "UI-HUD-ActionBar-IconFrame-Mask") then
            m:SetAllPoints(b.icon)
            b.icon:AddMaskTexture(m)
        else
            b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        end
    else
        b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end
    b.border = b:CreateTexture(nil, "ARTWORK", nil, 1)
    if H.Atlas(b.border, "UI-HUD-ActionBar-IconFrame") then
        b.border:SetAllPoints(b)
    else
        b.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        b.border:SetPoint("TOPLEFT", b, "TOPLEFT", -12, 12)
        b.border:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 12, -12)
    end
    local pushed = b:CreateTexture()
    if not H.Atlas(pushed, "UI-HUD-ActionBar-IconFrame-Down") then
        pushed:SetTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    end
    pushed:SetAllPoints(b)
    b:SetPushedTexture(pushed)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints(b)
    local top = CreateFrame("Frame", nil, b)
    top:SetAllPoints(b)
    top:SetFrameLevel(b.cd:GetFrameLevel() + 2)
    b.count = top:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    b.count:SetJustifyH("RIGHT")
    b.key = top:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
    b.key:SetPoint("TOPRIGHT", b, "TOPRIGHT", -2, -3)
    b.key:SetJustifyH("RIGHT")
    b.key:SetText(KEYS[i] or "")

    _G.SecureHandlerSetFrameRef(b, "h", S.header)
    _G.SecureHandlerWrapScript(b, "OnClick", S.header, SNIP.entryPre, SNIP.entryPost)
    b:HookScript("OnClick", function(self, button, down)
        if button == "RightButton" and not down then H.Safe("remove", H.EntryRemove, self, false) end
    end)
    b:SetScript("OnDragStart", function(self) H.Safe("drag", H.EntryRemove, self, true) end)
    b:SetScript("OnEnter", function(self) H.Safe("tooltip", H.EntryTooltip, self) end)
    b:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    b:Hide()
    f.e[i] = b
    return b
end

function H.EntryRemove(b, pickup)
    if InCombat() then FL.CombatMsg() return end
    local e = b.entry
    if not e then return end
    if pickup then H.Pickup(e) end
    if _G.GameTooltip then _G.GameTooltip:Hide() end
    H.RemoveEntry(b.slot, b.listIndex)
end

function H.EntryTooltip(b)
    if not b.entry then return end
    H.ShowEntryTooltip(b, b.entry, not InCombat() and "Right-click or drag out to remove." or nil)
end

function H.ShowEntryTooltip(owner, e, hint)
    local tt = _G.GameTooltip
    if not e or not tt then return end
    tt:SetOwner(owner, "ANCHOR_RIGHT")
    local ok = false
    if e.t == "spell" and type(tt.SetSpellByID) == "function" then
        ok = pcall(tt.SetSpellByID, tt, e.id)
    elseif e.t == "item" and type(tt.SetItemByID) == "function" then
        ok = pcall(tt.SetItemByID, tt, e.id)
    elseif e.t == "action" and type(tt.SetAction) == "function" then
        ok = pcall(tt.SetAction, tt, e.id)
    end
    if not ok then
        if e.t == "macro" then
            tt:SetText(e.name, 1, 1, 1)
        else
            local spell = H.Resolve(e)
            if not (spell and type(tt.SetSpellByID) == "function" and pcall(tt.SetSpellByID, tt, spell)) then
                tt:SetText("?", 1, 1, 1)
            end
        end
    end
    if hint then tt:AddLine(hint, 0.6, 0.6, 0.6) end
    tt:Show()
end

function H.EnsureFly(slot)
    local f = S.flys[slot]
    if f then return f end
    f = CreateFrame("Frame", "GaarBarsForeverFlyout" .. slot, _G.UIParent, "SecureHandlerBaseTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetSize(1, 1)
    f:Hide()
    f.slot, f.e = slot, {}
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetPoint("TOPLEFT", f, "TOPLEFT", -3, 3)
    f.bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 3, -3)
    f.bg:SetColorTexture(0, 0, 0, 0.5)
    f:HookScript("OnShow", function(self)
        S.shown[self] = true
        H.UpdateFly(self)
        if S.clock then S.clock:Show() end
    end)
    f:HookScript("OnHide", function(self) S.shown[self] = nil end)
    _G.SecureHandlerSetFrameRef(S.header, "fly" .. slot, f)
    S.flys[slot] = f
    return f
end

-- The value of an entry's action attribute (spell / item / macro / action).
function H.ActionValue(e)
    if e.t == "item" then return "item:" .. e.id end
    if e.t == "macro" then return e.name end
    return e.id
end

function H.SetEntryAction(b, e)
    for _, k in ipairs({ "spell", "item", "macro", "action" }) do b:SetAttribute(k, nil) end
    b:SetAttribute("type1", e.t)
    b:SetAttribute(e.t, H.ActionValue(e))
end

-- The right-click action of `slot` for the overlays (SNIP.setfirst reads it): entry 1, or nil.
function H.SetFirst(slot, e)
    S.header:SetAttribute("first" .. slot .. "type", e and e.t or nil)
    S.header:SetAttribute("first" .. slot .. "value", e and H.ActionValue(e) or nil)
end

-- Fill a slot's flyout from its list, sized and scaled from `btn` (the button that shows it).
function H.FillFly(slot, list, btn)
    local f = H.EnsureFly(slot)
    local w = btn and Num(CallOf(btn, "GetWidth")) or nil
    w = (w and w > 10) and w or 36
    local size = math.floor(w * 0.8 + 0.5)
    local es = btn and Num(CallOf(btn, "GetEffectiveScale")) or nil
    local us = Num(CallOf(_G.UIParent, "GetEffectiveScale"))
    if es and us and es > 0 and us > 0 then f:SetScale(es / us) end
    local dir = DIRS[H.Dir()]
    local n = 0
    for li, e in ipairs(list) do
        if n < MAX_ENTRIES and H.EntryShown(e) then
            n = n + 1
            local b = H.EnsureEntry(f, n)
            b.entry, b.listIndex, b.slot = e, li, slot
            H.SetEntryAction(b, e)
            b:SetSize(size, size)
            b:ClearAllPoints()
            local off = (n - 1) * (size + GAP)
            if dir == "DOWN" then
                b:SetPoint("TOP", f, "TOP", 0, -off)
            elseif dir == "LEFT" then
                b:SetPoint("RIGHT", f, "RIGHT", -off, 0)
            elseif dir == "RIGHT" then
                b:SetPoint("LEFT", f, "LEFT", off, 0)
            else
                b:SetPoint("BOTTOM", f, "BOTTOM", 0, off)
            end
            b:Show()
        end
    end
    -- Right click on the button casts list entry 1: only when it is the first one shown (an item
    -- you have none of leaves the flyout, and then right click does nothing).
    local first = n > 0 and f.e[1] and f.e[1].listIndex == 1 and f.e[1].entry or nil
    H.SetFirst(slot, first)
    for i = n + 1, #f.e do
        local b = f.e[i]
        b.entry, b.listIndex = nil, nil
        b:SetAttribute("type1", nil)
        b:Hide()
        f:SetAttribute("e" .. i, nil)
    end
    for i = 1, n do f:SetAttribute("e" .. i, f.e[i]:GetName()) end
    f:SetAttribute("n", n)
    local long = n > 0 and (n * size + (n - 1) * GAP) or 1
    if dir == "LEFT" or dir == "RIGHT" then f:SetSize(long, size) else f:SetSize(size, long) end
    if f:IsShown() then H.UpdateFly(f) end
end

-- The arrow that marks a button with a flyout: Blizzard's flyout arrow, pointing the way it opens.
function H.ArrowArt(o)
    local a = o.arrow
    local file, l, r, t, b
    local CT = _G.C_Texture
    if type(CT) == "table" and type(CT.GetAtlasInfo) == "function" then
        local ok, info = pcall(CT.GetAtlasInfo, "UI-HUD-ActionBar-Flyout")
        if ok and type(info) == "table" and (info.file or info.filename) then
            file = info.file or info.filename
            l, r, t, b = info.leftTexCoord, info.rightTexCoord, info.topTexCoord, info.bottomTexCoord
        end
    end
    if not (file and l and r and t and b) then
        file, l, r, t, b = "Interface\\Buttons\\ActionBarFlyoutButton", 0.625, 0.984375, 0.7421875, 0.828125
    end
    a:SetTexture(file)
    local dir = DIRS[H.Dir()]
    local w = Num(CallOf(o.btn, "GetWidth"))
    w = (w and w > 10) and w or 36
    local aw, ah = math.floor(w * 0.5 + 0.5), math.floor(w * 0.24 + 0.5)
    a:ClearAllPoints()
    -- The art points up; the eight texcoords turn it.
    if dir == "DOWN" then
        a:SetSize(aw, ah)
        a:SetTexCoord(r, b, r, t, l, b, l, t)
        a:SetPoint("CENTER", o, "BOTTOM", 0, 1)
    elseif dir == "LEFT" then
        a:SetSize(ah, aw)
        a:SetTexCoord(r, t, l, t, r, b, l, b)
        a:SetPoint("CENTER", o, "LEFT", 1, 0)
    elseif dir == "RIGHT" then
        a:SetSize(ah, aw)
        a:SetTexCoord(l, b, r, b, l, t, r, t)
        a:SetPoint("CENTER", o, "RIGHT", -1, 0)
    else
        a:SetSize(aw, ah)
        a:SetTexCoord(l, t, l, b, r, t, r, b)
        a:SetPoint("CENTER", o, "TOP", 0, -1)
    end
end

function H.OverlayTooltip(o)
    local tt = _G.GameTooltip
    if not tt then return end
    if type(_G.GameTooltip_SetDefaultAnchor) == "function" then
        _G.GameTooltip_SetDefaultAnchor(tt, o)
    else
        tt:SetOwner(o, "ANCHOR_RIGHT")
    end
    local slot = Num(o:GetAttribute("curslot"))
    if slot and slot > 0 and type(tt.SetAction) == "function" then pcall(tt.SetAction, tt, slot) end
    local f = slot and S.slotFly[slot]
    if f then tt:AddLine("Flyout: " .. f.name, 1, 0.82, 0) end
    tt:AddLine("Click or press its key to open, then 1-" .. #KEYS .. ".", 0.6, 0.6, 0.6)
    if H.SameKey() then tt:AddLine("Its key again casts the first entry.", 0.6, 0.6, 0.6) end
    tt:AddLine("Right-click casts the first entry. /gbars flyouts edits it.", 0.6, 0.6, 0.6)
    tt:Show()
end

-- Drag the button's own action off (out of combat, as Blizzard allows it) and drop onto it.
function H.OverlayDrag(o)
    if InCombat() then return end
    local slot = H.ButtonSlot(o.btn)
    if not slot or type(_G.PickupAction) ~= "function" then return end
    local locked = false
    local get = (type(_G.C_CVar) == "table" and _G.C_CVar.GetCVar) or _G.GetCVar
    if type(get) == "function" then
        local ok, v = pcall(get, "lockActionBars")
        locked = ok and v == "1"
    end
    if locked and type(_G.IsModifiedClick) == "function" then
        local ok, v = pcall(_G.IsModifiedClick, "PICKUPACTION")
        if ok and v and not Secret(v) then locked = false end
    end
    if not locked then pcall(_G.PickupAction, slot) end
end

function H.OverlayDrop(o)
    if InCombat() then return end
    local slot = H.ButtonSlot(o.btn)
    if slot and type(_G.PlaceAction) == "function" then pcall(_G.PlaceAction, slot) end
end

function H.EnsureOverlay(btn)
    local o = S.ovByButton[btn]
    if o then return o end
    local j = #S.ovs + 1
    local name = "GaarBarsForeverFlyoutOverlay" .. j
    o = CreateFrame("Button", name, btn, "SecureActionButtonTemplate")
    o:SetAllPoints(btn)
    o:SetFrameLevel((Num(CallOf(btn, "GetFrameLevel")) or 0) + 6)
    -- Release only, for both buttons (and the keys, which click LeftButton); useOnKeyDown = false
    -- makes the secure action run on that release whatever ActionButtonUseKeyDown says.
    o:RegisterForClicks("AnyUp")
    o:RegisterForDrag("LeftButton")
    o:SetAttribute("useOnKeyDown", false)
    o:SetAttribute("ovid", j)
    o:SetAttribute("myname", name)
    o:SetAttribute("curslot", 0)
    o:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    o.arrow = o:CreateTexture(nil, "OVERLAY", nil, 2)
    o.btn = btn
    o:SetScript("OnEnter", function(self) H.Safe("tooltip", H.OverlayTooltip, self) end)
    o:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    o:SetScript("OnDragStart", function(self) H.Safe("pickup", H.OverlayDrag, self) end)
    o:SetScript("OnReceiveDrag", function(self) H.Safe("place", H.OverlayDrop, self) end)
    _G.SecureHandlerSetFrameRef(o, "h", S.header)
    _G.SecureHandlerSetFrameRef(S.header, "ov" .. j, o)
    _G.SecureHandlerWrapScript(o, "OnClick", S.header, SNIP.overlayPre)
    o:Hide()
    S.ovs[j] = o
    S.ovByButton[btn] = o
    return o
end

-- The button's keys (its ACTIONBUTTONn / MULTIACTIONBARmBUTTONn binding) onto the overlay's
-- attributes. True when they changed.
function H.SetKeys(o, cmd)
    local keys = {}
    if cmd and type(_G.GetBindingKey) == "function" then
        local res = { pcall(_G.GetBindingKey, cmd) }
        if res[1] then
            for i = 2, #res do
                local k = Str(res[i])
                if k then keys[#keys + 1] = k end
            end
        end
    end
    local sig = table.concat(keys, " ")
    if o.keySig == sig then return false end
    for i = 1, math.max(#keys, o.nkeys or 0) do o:SetAttribute("key" .. i, keys[i]) end
    o:SetAttribute("nkeys", #keys)
    o.nkeys, o.keySig = #keys, sig
    return true
end

function H.Command(btn, bar, i)
    local c = Str(FieldOf(btn, "commandName")) or Str(FieldOf(btn, "bindingAction"))
    return c or (bar[2] .. i)
end

-- ---------------------------------------------------------------------------
-- The "+" drop targets
-- ---------------------------------------------------------------------------

function H.PlusTooltip(p)
    local tt = _G.GameTooltip
    if not tt then return end
    tt:SetOwner(p, "ANCHOR_RIGHT")
    local slot = p.btn and H.ButtonSlot(p.btn)
    local f = slot and H.SlotFlyout(slot)
    if f then
        tt:SetText("Add to flyout \"" .. f.name .. "\"", 1, 1, 1)
        tt:AddLine("Drop here to add it to this flyout (up to " .. MAX_ENTRIES .. ").", 0.8, 0.8, 0.8, true)
    else
        tt:SetText("New flyout", 1, 1, 1)
        tt:AddLine("Drop here to make a flyout of this button's action and the dropped one. Its macro takes"
            .. " the button's place.", 0.8, 0.8, 0.8, true)
    end
    tt:Show()
end

function H.EnsurePlus(btn)
    local p = S.plus[btn]
    if p then return p end
    if InCombat() then return nil end
    p = CreateFrame("Button", nil, btn)
    p.btn = btn
    local w = Num(CallOf(btn, "GetWidth"))
    w = (w and w > 10) and w or 36
    local s = math.max(12, math.min(20, math.floor(w * 0.42 + 0.5)))
    p:SetSize(s, s)
    p:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 3, 3)
    p:SetFrameLevel((Num(CallOf(btn, "GetFrameLevel")) or 0) + 12)
    p:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
    p:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
    p:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    p:RegisterForClicks("LeftButtonUp")
    p:SetScript("OnReceiveDrag", function() H.Safe("add", H.AddToButton, btn) end)
    p:SetScript("OnClick", function() H.Safe("add", H.AddToButton, btn) end)
    p:SetScript("OnEnter", function(self) H.Safe("tooltip", H.PlusTooltip, self) end)
    p:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    p:Hide()
    S.plus[btn] = p
    return p
end

function H.HidePlus()
    for _, p in pairs(S.plus) do p:Hide() end
end

-- Show the "+" on every visible bar button with an action while the cursor holds a spell, an
-- item or a macro, out of combat.
function H.UpdatePlus()
    local want = H.Active() and not InCombat() and H.CursorEntry() ~= nil
    if not want then
        H.HidePlus()
        return
    end
    for _, bar in ipairs(BARS) do
        for i = 1, 12 do
            local btn = _G[bar[1] .. i]
            if type(btn) == "table" then
                local slot = H.ButtonSlot(btn)
                local show = slot and CallOf(btn, "IsVisible") == true and H.HasAction(slot)
                if show then
                    local p = H.EnsurePlus(btn)
                    if p then p:Show() end
                elseif S.plus[btn] then
                    S.plus[btn]:Hide()
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

-- The main bar's page by our conditions (string), and whether ActionButton1 agrees.
function H.CheckPaging()
    local parse = _G.SecureCmdOptionParse
    if type(parse) ~= "function" then
        S.pagingOk, S.pagingNote = false, "no SecureCmdOptionParse"
        return "1"
    end
    local ok, page = pcall(parse, S.cond)
    if not ok and S.cond ~= PAGE_COND_SHORT then
        S.cond = PAGE_COND_SHORT
        ok, page = pcall(parse, S.cond)
    end
    page = ok and Str(page) or nil
    local p = page and tonumber(page)
    if not p then
        S.pagingOk, S.pagingNote = false, "conditions not understood"
        return "1"
    end
    local b1 = _G.ActionButton1
    local actual = type(b1) == "table" and H.ButtonSlot(b1) or nil
    if p == 0 or not actual then
        S.pagingOk, S.pagingNote = true, "ok (not checkable now)"
    elseif actual == p * 12 - 11 then
        S.pagingOk, S.pagingNote = true, "ok (page " .. p .. ")"
    else
        S.pagingOk = false
        S.pagingNote = "differs (page " .. p .. " gives slot " .. (p * 12 - 11) .. ", ActionButton1 shows "
            .. actual .. "; the main bar keeps its out-of-combat slot)"
    end
    return page
end

function H.Teardown()
    H.HidePlus()
    S.slotFly = {}
    if not S.header then return end
    if InCombat() then S.pending = true return end
    H.Exec(S.header, [[ self:RunAttribute("close") ]])
    if S.driverOn and type(_G.UnregisterStateDriver) == "function" then
        pcall(_G.UnregisterStateDriver, S.header, "page")
    end
    S.driverOn = false
    for slot in pairs(S.active) do
        S.header:SetAttribute("has" .. slot, nil)
        H.SetFirst(slot, nil)
    end
    S.active, S.live, S.slotFly = {}, 0, {}
    for _, o in ipairs(S.ovs) do
        o:SetAttribute("mainid", nil)
        o:SetAttribute("fixedslot", nil)
        o:SetAttribute("curslot", 0)
        for _, k in ipairs({ "type2", "spell2", "item2", "macro2", "action2" }) do o:SetAttribute(k, nil) end
        o:Hide()
        if type(_G.ClearOverrideBindings) == "function" then _G.ClearOverrideBindings(o) end
    end
    for _, f in pairs(S.flys) do f:Hide() end
    if type(_G.ClearOverrideBindings) == "function" then _G.ClearOverrideBindings(S.header) end
end

function H.Build()
    H.Reresolve()
    local slots, slotFly, any = {}, {}, false
    for slot = 1, MAX_SLOT do
        if H.HasAction(slot) then
            local f = H.SlotFlyout(slot)
            if f and #f.entries >= 1 then
                slots[slot] = f.entries
                slotFly[slot] = f
                any = true
            end
        end
    end
    S.slotFly = slotFly
    -- Nothing was ever built and nothing is needed: the bars stay exactly Blizzard's.
    if not any and not S.header then return end
    local h = H.EnsureHeader()
    local page = H.CheckPaging()

    -- Which Blizzard buttons need an overlay, and the button that shows each slot.
    local need, owner = {}, {}
    for _, bar in ipairs(BARS) do
        for i = 1, 12 do
            local btn = _G[bar[1] .. i]
            if type(btn) == "table" then
                local cur = H.ButtonSlot(btn)
                if bar.main and S.pagingOk then
                    for p = 1, 11 do
                        local s = (p - 1) * 12 + i
                        if slots[s] then
                            need[btn] = { main = i, cmd = H.Command(btn, bar, i) }
                            if s == cur or not owner[s] then owner[s] = btn end
                        end
                    end
                elseif cur and slots[cur] then
                    need[btn] = { fixed = cur, cmd = H.Command(btn, bar, i) }
                    if not bar.main or not owner[cur] then owner[cur] = btn end
                end
            end
        end
    end

    for slot, list in pairs(slots) do
        H.FillFly(slot, list, owner[slot] or _G["ActionButton" .. (((slot - 1) % 12) + 1)])
        h:SetAttribute("has" .. slot, true)
    end
    for slot in pairs(S.active) do
        if not slots[slot] then
            h:SetAttribute("has" .. slot, nil)
            H.SetFirst(slot, nil)
            if S.flys[slot] then S.flys[slot]:Hide() end
        end
    end
    S.active = slots

    local live = 0
    for btn, cfg in pairs(need) do
        local o = H.EnsureOverlay(btn)
        o:SetAttribute("mainid", cfg.main)
        o:SetAttribute("fixedslot", cfg.fixed)
        H.SetKeys(o, cfg.cmd)
        H.ArrowArt(o)
        o.cmd = cfg.cmd
        live = live + 1
    end
    for btn, o in pairs(S.ovByButton) do
        if not need[btn] then
            o:SetAttribute("mainid", nil)
            o:SetAttribute("fixedslot", nil)
            o.cmd = nil
        end
    end
    S.live = live
    h:SetAttribute("novs", #S.ovs)
    h:SetAttribute("dir", DIRS[H.Dir()])
    h:SetAttribute("samekey", H.SameKey())
    h:SetAttribute("page", page)
    if not S.driverOn and type(_G.RegisterStateDriver) == "function" then
        S.driverOn = pcall(_G.RegisterStateDriver, h, "page", S.cond) and true or false
    end
    H.Exec(h, SNIP.refresh)
end

-- What BookTab needs: the spell and macro entries of every flyout whose macro is on a bar now
-- (nothing while flyouts are off or blocked). Items and plain slots are left out.
function FL.BarEntries()
    local out = {}
    if not H.Active() or next(H.Store()) == nil then return out end
    if next(S.byMacro) == nil then H.Reresolve() end
    local seen = {}
    for slot = 1, MAX_SLOT do
        if H.HasAction(slot) then
            local f = H.SlotFlyout(slot)
            if f and not seen[f] then
                seen[f] = true
                for _, e in ipairs(f.entries) do
                    if e.t == "spell" then
                        out[#out + 1] = { t = "spell", id = e.id }
                    elseif e.t == "macro" then
                        out[#out + 1] = { t = "macro", name = e.name }
                    end
                end
            end
        end
    end
    return out
end
B.FlyoutBarEntries = FL.BarEntries

-- Rebuild from the saved data (out of combat; in combat it waits for the fight to end): the v1
-- conversion (once), the macros, then the secure frames.
function FL.Refresh()
    if type(B.MissingDirty) == "function" then pcall(B.MissingDirty) end
    S.dirty = false
    if not S.loaded then return end
    if InCombat() then
        S.pending = true
        H.NotifyEditor()
        return
    end
    S.pending = false
    if H.Active() then
        H.Safe("convert", H.MigrateV1)
        H.Safe("macros", H.EnsureMacros)
        H.Safe("build", H.Build)
    else
        H.Safe("teardown", H.Teardown)
    end
    H.Safe("plus", H.UpdatePlus)
    H.NotifyEditor()
end

function FL.Apply() FL.Refresh() end

-- Bindings changed: only the overlays' keys are ours to follow.
function H.OnBindings()
    if not S.header or not H.Active() then return end
    if InCombat() then
        S.pending = true
        return
    end
    local changed = false
    for _, o in ipairs(S.ovs) do
        if o.cmd and H.SetKeys(o, o.cmd) then changed = true end
    end
    if changed then H.Exec(S.header, SNIP.refresh) end
end

-- Out of combat, a click anywhere but the open flyout or a flyout button closes it.
function H.OnGlobalMouseDown()
    if InCombat() or not S.header then return end
    local open = Num(S.header:GetAttribute("open")) or 0
    if open == 0 then return end
    local f = S.flys[open]
    if f and f:IsMouseOver() then return end
    for _, o in ipairs(S.ovs) do
        if o:IsShown() and o:IsMouseOver() then return end
    end
    H.Exec(S.header, [[ self:RunAttribute("close") ]])
end

-- ---------------------------------------------------------------------------
-- Slash and status
-- ---------------------------------------------------------------------------

-- "/gbars flyout dir up|down|left|right"; `arg` is what follows "flyout".
function FL.SlashDir(arg)
    local d = (arg or ""):match("^dir%s*(%a*)$")
    if not d or d == "" then
        H.Print("flyouts open " .. H.Dir() .. ". /gbars flyout dir up|down|left|right")
        return
    end
    if not DIRS[d] then
        H.Print("/gbars flyout dir up|down|left|right")
        return
    end
    if InCombat() then FL.CombatMsg() return end
    local db = H.DB()
    if not db then return end
    db.flyoutDir = d
    FL.Refresh()
    H.Print("flyouts open " .. d .. ".")
end

function H.SameKeyText()
    return H.SameKey() and "casts entry 1" or "closes"
end

-- "/gbars flyout samekey on|off"; `arg` is what follows "flyout".
function FL.SlashSameKey(arg)
    local v = (arg or ""):match("^samekey%s*(%a*)$")
    local usage = "/gbars flyout samekey on|off - the button's key again while its flyout is open casts entry 1 (on) or closes it (off)"
    if not v or v == "" then
        H.Print("same key while open: " .. H.SameKeyText() .. ". " .. usage)
        return
    end
    if v ~= "on" and v ~= "off" then H.Print(usage) return end
    local db = H.DB()
    if not db then return end
    db.flyoutSameKeyCast = (v == "on")
    FL.Refresh()
    H.Print("same key while open: " .. H.SameKeyText() .. "." .. (InCombat() and " (after combat)" or ""))
end

function FL.StatusLine()
    local D = " \194\183 "
    if H.Blocked() then return "flyouts: off" .. D .. BLOCKER .. " is loaded, so ours stays off" end
    local on = type(B.On) == "function" and B.On(FEATURE) == true
    local saved, entries = 0, 0
    if S.loaded then
        for _, f in pairs(H.Store()) do
            saved = saved + 1
            entries = entries + #f.entries
        end
    end
    -- Flyouts whose macro is on a bar, and the bar slots that hold one.
    local onBars, slotsOn, seen = 0, 0, {}
    for _, f in pairs(S.slotFly) do
        slotsOn = slotsOn + 1
        if not seen[f] then
            seen[f] = true
            onBars = onBars + 1
        end
    end
    local d = S.loaded and H.CharDB() or {}
    local v1 = d.flyoutsV1Done and (d.flyoutsV1Result or "done") or "not yet (runs out of combat)"
    -- A main bar button gets an overlay for every page that has a flyout at its position (slots
    -- 13-72 are also the side bars' slots), so overlays can outnumber flyouts; only the ones
    -- whose slot the bar shows now are shown.
    local shownOvs = 0
    for _, o in ipairs(S.ovs) do if o:IsShown() then shownOvs = shownOvs + 1 end end
    return string.format("flyouts: %s" .. D .. "%d saved (%d entries)" .. D .. "%d on bars (%d slots)" .. D
        .. "%d buttons with an overlay (%d shown now)" .. D .. "opens %s" .. D .. "same key: %s" .. D
        .. "v1: %s" .. D .. "paging %s%s" .. D .. "last error: %s",
        on and "on" or "off", saved, entries, onBars, slotsOn, S.live, shownOvs, H.Dir(), H.SameKeyText(),
        v1, S.pagingNote, S.pending and D .. "waits for combat to end" or "", S.err or "none")
end

-- "right-click: entry 1 set on N of M shown overlays" (the overlays' type2, as they are now).
function FL.RightClickLine()
    local shown, set, kinds = 0, 0, {}
    for _, o in ipairs(S.ovs) do
        if o:IsShown() then
            shown = shown + 1
            local t = Str(o:GetAttribute("type2"))
            if t then
                set = set + 1
                kinds[t] = (kinds[t] or 0) + 1
            end
        end
    end
    local parts = {}
    for _, k in ipairs({ "spell", "item", "macro", "action" }) do
        if kinds[k] then parts[#parts + 1] = kinds[k] .. " " .. k end
    end
    return string.format("right-click: entry 1 set on %d of %d shown overlays%s", set, shown,
        #parts > 0 and " (" .. table.concat(parts, ", ") .. ")" or "")
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

S.clock = CreateFrame("Frame")
S.clock:Hide()
S.clock:SetScript("OnUpdate", function(self, elapsed)
    S.elapsed = S.elapsed + (Num(elapsed) or 0)
    if S.elapsed < TICK then return end
    S.elapsed = 0
    if S.dirty and not InCombat() then FL.Refresh() end
    local any = false
    for f in pairs(S.shown) do
        any = true
        H.UpdateFly(f)
    end
    if not any and not S.dirty then self:Hide() end
end)

function H.MarkDirty()
    if type(B.MissingDirty) == "function" then pcall(B.MissingDirty) end
    S.dirty = true
    S.clock:Show()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
-- Not every client knows every event; registering an unknown one raises an error.
for _, e in ipairs({ "ACTIONBAR_SLOT_CHANGED", "UPDATE_BINDINGS", "CURSOR_CHANGED", "CURSOR_UPDATE",
    "ACTIONBAR_SHOWGRID", "ACTIONBAR_HIDEGRID", "SPELLS_CHANGED", "UPDATE_MACROS",
    "BAG_UPDATE_DELAYED", "GLOBAL_MOUSE_DOWN", "UPDATE_MULTI_ACTIONBAR" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1)
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if arg1 == (ADDON_NAME or "GaarBarsForever") then
                S.loaded = true
                H.Sanitize()
                H.Reresolve()
            elseif arg1 == BLOCKER and S.loaded then
                H.MarkDirty()
            end
        elseif not S.loaded then
            return
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- From here the macros and the bars can be read and changed (conversion, macros).
            S.world = true
            H.Reresolve()
            if InCombat() then S.pending = true else H.MarkDirty() end
        elseif event == "UPDATE_MACROS" then
            -- Macros were created, renamed, deleted or re-indexed: find ours again by name.
            H.Reresolve()
            if InCombat() then S.pending = true else H.MarkDirty() end
        elseif event == "PLAYER_REGEN_DISABLED" then
            H.HidePlus()
        elseif event == "PLAYER_REGEN_ENABLED" then
            if S.pending or S.dirty then FL.Refresh() end
        elseif event == "UPDATE_BINDINGS" then
            H.OnBindings()
        elseif event == "GLOBAL_MOUSE_DOWN" then
            H.OnGlobalMouseDown()
        elseif event == "CURSOR_CHANGED" or event == "CURSOR_UPDATE"
            or event == "ACTIONBAR_SHOWGRID" or event == "ACTIONBAR_HIDEGRID" then
            H.UpdatePlus()
        elseif event == "BAG_UPDATE_DELAYED" then
            -- Only flyouts with items care (an item running out leaves the flyout).
            for _, list in pairs(S.active) do
                for _, e in ipairs(list) do
                    if e.t == "item" then H.MarkDirty() return end
                end
            end
        else
            if InCombat() then S.pending = true else H.MarkDirty() end
        end
    end)
    if not ok then H.Err(event, err) end
end)
