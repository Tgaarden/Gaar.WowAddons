--[[
  GaarBarsForever - Flyouts.lua: flyouts on action buttons (the `flyouts` feature).

  What it does:
    * While the cursor holds a spell, an item or a macro (out of combat), a small "+" sits on
      every action bar button that has an action. Dropping on the "+" adds the thing to that
      button's flyout; the first drop creates the flyout with the button's own action as entry 1.
      Up to 12 entries, duplicates ignored.
    * A button with a flyout gets a small arrow. Clicking it, or pressing its key, opens the
      flyout and casts nothing. While it is open, 1-9, 0, - and = cast entry 1-12; clicking an
      entry casts it too. Casting, Escape, clicking the button again or clicking elsewhere closes
      it. All of this works in combat.
    * The entries look like the game's own flyout buttons: icon frame, cooldown swipe, red when
      out of range, blue without mana, grey when unusable, the item count, the key that casts it.
    * Out of combat: right-click an entry, or drag it out, to remove it (dragging puts it on the
      cursor). One entry left removes the flyout and the button is a plain button again. In
      combat a short chat line says it has to wait.
    * Saved per character in GaarBarsForeverCharDB.flyouts, keyed by the button's action
      ("spell:<id>", "item:<id>", "macro:<name>"), so a flyout follows its ability to another
      button; an action of any other kind falls back to its slot ("slot:<n>"). Items you have
      none of are left out of the open flyout (decided out of combat) but stay in the data.
    * /gbars flyout on|off (the `flyouts` switch, default on), /gbars flyout dir up|down|left|right
      (account-wide, default up), a line in /gbars status. Off while FallensFlyouts is loaded.

  The secure part (it must work in combat, where addon code may not show, hide, bind or set
  attributes on secure frames):
    * A header of ours (SecureHandlerStateTemplate) holds the shared state and three restricted
      snippets: "toggle" (anchor the slot's flyout to the clicked overlay, show it, bind 1-12 and
      Escape with SetBindingClick on the header), "close" (hide it, ClearBindings) and "sync"
      (which overlays are live, and their key bindings).
    * One flyout frame per action slot that has a flyout (protected, parked on UIParent), with
      SecureActionButtonTemplate entries (type1 = spell / item / macro / action). Each entry's
      OnClick is wrapped (SecureHandlerWrapScript) so a left release closes the flyout after the
      cast. The entries cast on release (useOnKeyDown = false), so a drag never casts.
    * One overlay (SecureHandlerClickTemplate) over each Blizzard button that may show a flyout,
      a child of that button. Only a live overlay is shown and bound: its click runs "toggle",
      and the button's own keys (GetBindingKey of its ACTIONBUTTONn / MULTIACTIONBARmBUTTONn
      binding) are override-click bindings to it. The Blizzard button's attributes, scripts and
      bindings are never touched; with no live overlay, the button is exactly Blizzard's.
    * The main bar pages (stances, forms, stealth, shift-page): a state driver on the header
      ("[bar:2]2 ... [bonusbar:1]7 ... 1") runs "sync" on every page change, so in combat the
      overlay over ActionButtonN follows the slot the bar shows. /gbars status says whether that
      mapping matches the bar out of combat; if it does not, the main bar overlays stay on the
      slot the bar showed out of combat.
    * A full-screen catcher button (BACKGROUND strata, only while a flyout is open) closes it on
      a click in the world; out of combat, GLOBAL_MOUSE_DOWN elsewhere closes it too.
    * Frames, attributes, frame refs, wraps and bindings are set only out of combat; anything
      that changes in combat waits for PLAYER_REGEN_ENABLED. No COMBAT_LOG event is used.
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
                o:Show()
                local me = o:GetAttribute("myname")
                local nk = o:GetAttribute("nkeys") or 0
                for k = 1, nk do
                    local key = o:GetAttribute("key" .. k)
                    if key and me then o:SetBindingClick(false, key, me, "LeftButton") end
                end
            else
                o:SetAttribute("curslot", 0)
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

SNIP.overlayClick = [[
    local h = self:GetFrameRef("h")
    local slot = self:GetAttribute("curslot") or 0
    if h and slot > 0 then h:RunAttribute("toggle", slot, self:GetAttribute("ovid")) end
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

local FL = {}          -- public: Apply, Refresh, StatusLine, SlashDir
NS.Flyouts = FL

local H = {}           -- helpers

local S = {
    loaded = false, pending = false, dirty = false, err = nil,
    header = nil, catcher = nil, clock = nil,
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

function H.Data()
    local d = _G.GaarBarsForeverCharDB
    if type(d) ~= "table" then
        d = {}
        _G.GaarBarsForeverCharDB = d
    end
    if type(d.flyouts) ~= "table" then d.flyouts = {} end
    return d.flyouts
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

-- The flyout list for a slot (by its action, else by the slot), and the slot's own entry.
function H.ListForSlot(slot, data)
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
        if name then return { t = "macro", name = name } end
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
    if tex == nil then return "Interface\\Icons\\INV_Misc_QuestionMark" end
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

function H.AddToButton(btn)
    if InCombat() then FL.CombatMsg() return end
    if not H.Active() then return end
    local e = H.CursorEntry()
    if not e then return end
    local slot = H.ButtonSlot(btn)
    if not slot or not H.HasAction(slot) then return end
    local data = H.Data()
    local list, own = H.ListForSlot(slot, data)
    if not list then
        if H.SameEntry(own, e) then H.ClearCursor() return end
        list = { own }
        data[H.Key(own)] = list
    end
    for _, x in ipairs(list) do
        if H.SameEntry(x, e) then H.ClearCursor() return end
    end
    if #list >= MAX_ENTRIES then
        H.Print("this flyout is full (" .. MAX_ENTRIES .. " entries).")
        return
    end
    list[#list + 1] = e
    H.ClearCursor()
    FL.Refresh()
end

-- Remove entry `index` of the list shown at `slot`; one entry left removes the flyout.
function H.RemoveEntry(slot, index)
    if InCombat() then FL.CombatMsg() return false end
    local list = S.active[slot]
    if not list or not list[index] then return false end
    table.remove(list, index)
    if #list <= 1 then
        local data = H.Data()
        for k, v in pairs(data) do
            if v == list then data[k] = nil end
        end
    end
    FL.Refresh()
    return true
end

-- Saved data from an older or hand-edited file: keep valid entries, at most 12, no duplicates,
-- and only lists of two or more.
function H.Sanitize()
    local data = H.Data()
    for k, list in pairs(data) do
        local clean = {}
        if type(k) == "string" and type(list) == "table" then
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
        end
        data[k] = #clean >= 2 and clean or nil
    end
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
    local e, tt = b.entry, _G.GameTooltip
    if not e or not tt then return end
    tt:SetOwner(b, "ANCHOR_RIGHT")
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
    if not InCombat() then tt:AddLine("Right-click or drag out to remove.", 0.6, 0.6, 0.6) end
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

function H.SetEntryAction(b, e)
    for _, k in ipairs({ "spell", "item", "macro", "action" }) do b:SetAttribute(k, nil) end
    b:SetAttribute("type1", e.t)
    if e.t == "spell" then
        b:SetAttribute("spell", e.id)
    elseif e.t == "item" then
        b:SetAttribute("item", "item:" .. e.id)
    elseif e.t == "macro" then
        b:SetAttribute("macro", e.name)
    elseif e.t == "action" then
        b:SetAttribute("action", e.id)
    end
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
    tt:AddLine("Flyout: click or press its key to open, then 1-" .. #KEYS .. ".", 0.6, 0.6, 0.6)
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
    o = CreateFrame("Button", name, btn, "SecureHandlerClickTemplate")
    o:SetAllPoints(btn)
    o:SetFrameLevel((Num(CallOf(btn, "GetFrameLevel")) or 0) + 6)
    o:RegisterForClicks("AnyUp")
    o:RegisterForDrag("LeftButton")
    o:SetAttribute("ovid", j)
    o:SetAttribute("myname", name)
    o:SetAttribute("curslot", 0)
    o:SetAttribute("_onclick", SNIP.overlayClick)
    o:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    o.arrow = o:CreateTexture(nil, "OVERLAY", nil, 2)
    o.btn = btn
    o:SetScript("OnEnter", function(self) H.Safe("tooltip", H.OverlayTooltip, self) end)
    o:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    o:SetScript("OnDragStart", function(self) H.Safe("pickup", H.OverlayDrag, self) end)
    o:SetScript("OnReceiveDrag", function(self) H.Safe("place", H.OverlayDrop, self) end)
    _G.SecureHandlerSetFrameRef(o, "h", S.header)
    _G.SecureHandlerSetFrameRef(S.header, "ov" .. j, o)
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
    tt:SetText("Add to flyout", 1, 1, 1)
    tt:AddLine("Drop here to add it to this button's flyout (up to " .. MAX_ENTRIES .. ").", 0.8, 0.8, 0.8, true)
    tt:Show()
end

function H.EnsurePlus(btn)
    local p = S.plus[btn]
    if p then return p end
    if InCombat() then return nil end
    p = CreateFrame("Button", nil, btn)
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
    if not S.header then return end
    if InCombat() then S.pending = true return end
    H.Exec(S.header, [[ self:RunAttribute("close") ]])
    if S.driverOn and type(_G.UnregisterStateDriver) == "function" then
        pcall(_G.UnregisterStateDriver, S.header, "page")
    end
    S.driverOn = false
    for slot in pairs(S.active) do S.header:SetAttribute("has" .. slot, nil) end
    S.active, S.live = {}, 0
    for _, o in ipairs(S.ovs) do
        o:SetAttribute("mainid", nil)
        o:SetAttribute("fixedslot", nil)
        o:SetAttribute("curslot", 0)
        o:Hide()
        if type(_G.ClearOverrideBindings) == "function" then _G.ClearOverrideBindings(o) end
    end
    for _, f in pairs(S.flys) do f:Hide() end
    if type(_G.ClearOverrideBindings) == "function" then _G.ClearOverrideBindings(S.header) end
end

function H.Build()
    local data = H.Data()
    local slots, any = {}, false
    for slot = 1, MAX_SLOT do
        if H.HasAction(slot) then
            local list = H.ListForSlot(slot, data)
            if list and #list >= 2 then
                slots[slot] = list
                any = true
            end
        end
    end
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
    h:SetAttribute("page", page)
    if not S.driverOn and type(_G.RegisterStateDriver) == "function" then
        S.driverOn = pcall(_G.RegisterStateDriver, h, "page", S.cond) and true or false
    end
    H.Exec(h, SNIP.refresh)
end

-- Rebuild from the saved data (out of combat; in combat it waits for the fight to end).
function FL.Refresh()
    S.dirty = false
    if not S.loaded then return end
    if InCombat() then
        S.pending = true
        return
    end
    S.pending = false
    if H.Active() then
        H.Safe("build", H.Build)
    else
        H.Safe("teardown", H.Teardown)
    end
    H.Safe("plus", H.UpdatePlus)
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

function FL.StatusLine()
    local D = " \194\183 "
    if H.Blocked() then return "flyouts: off" .. D .. BLOCKER .. " is loaded, so ours stays off" end
    local on = type(B.On) == "function" and B.On(FEATURE) == true
    local saved, entries = 0, 0
    if S.loaded then
        for _, list in pairs(H.Data()) do
            saved = saved + 1
            entries = entries + #list
        end
    end
    local onBars = 0
    for _ in pairs(S.active) do onBars = onBars + 1 end
    return string.format("flyouts: %s" .. D .. "%d saved (%d entries)" .. D .. "%d on bars" .. D
        .. "%d buttons with an overlay" .. D .. "opens %s" .. D .. "paging %s%s" .. D .. "last error: %s",
        on and "on" or "off", saved, entries, onBars, S.live, H.Dir(), S.pagingNote,
        S.pending and D .. "waits for combat to end" or "", S.err or "none")
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
            elseif arg1 == BLOCKER and S.loaded then
                H.MarkDirty()
            end
        elseif not S.loaded then
            return
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
