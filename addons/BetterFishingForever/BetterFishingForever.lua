--[[
  BetterFishingForever - double right-click in the world to cast Fishing, on WoW Forever.

  It does this and nothing else:

    * Double right-click in the 3D world casts Fishing, but only while a fishing pole is in the
      main-hand slot (16) and you are not in combat. A single right-click works exactly as
      before: the bobber is looted, an NPC is talked to, the camera turns.
    * The double-click window (the time from the first right press to the second) is 0.4 s by
      default and can be set from 0.2 to 0.8 s.
    * Nothing happens while the cursor holds an item. Clicks on the UI never reach WorldFrame,
      so they are never touched.
    * /bfish for help, on, off, window <0.2-0.8> and status.
    * BetterFishingForeverAPI, a small global table for BetterGaarForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden). The addon runs exactly the same
      without the hub; the API only exposes the settings the slash command already changes.

  How the cast gets through. An addon cannot cast a spell itself: only a secure button clicked by
  a real key or mouse press can. The addon owns one SecureActionButtonTemplate button (type
  "spell", spell = Fishing) and, for a moment, binds the right mouse button to it with
  SetOverrideBindingClick(owner, true, "BUTTON2", button). In the world BUTTON2 is itself a
  binding (TURNORACTION: turn the camera while held, interact on release), so the override takes
  the press instead of TURNORACTION, and the press - a real hardware event - clicks the button.

  The sequence:

    1. First right press, in the world (WorldFrame OnMouseDown, hooked with HookScript, never
       replaced). If the addon is on, you are not in combat, a fishing pole is equipped, Fishing
       is resolved and the cursor is empty, the time of the press is noted and the release is
       watched (IsMouseButtonDown("RightButton"), polled each frame by a small OnUpdate that runs
       only while something is pending). Nothing is bound yet, so this press and its release go
       to TURNORACTION as always: the bobber is looted, an NPC is talked to.
    2. First release. If it came within the window (a click, not a camera drag), the override is
       armed for what is left of the window: SetOverrideBindingClick(..., "BUTTON2", button).
       A release after the window was a camera drag: nothing is armed.
    3. Second right press, inside the window. It goes to the binding, which clicks the secure
       button with down = true, and on release with down = false. The client's
       SecureActionButtonTemplate (retail 10.0 and later, which Forever runs) acts on exactly one
       of the two: on the press when the ActionButtonUseKeyDown CVar is 1, on the release when it
       is 0. So the cast comes from the second click either way. The button is also registered
       for that one direction only (RegisterForClicks "AnyDown" or "AnyUp", read from the CVar
       each time it is armed), so a template that acted on both could still not cast twice.
    4. Disarm. PostClick marks the cast as done; the binding is cleared (ClearOverrideBindings)
       once the right button is up again, so the release of the second click never falls through
       to TURNORACTION. Without a second press the binding is cleared when the window runs out;
       a press that is still held is waited for (at most 2 s). PLAYER_REGEN_DISABLED clears it
       too, before combat locks bindings, and a reload or logout drops it with the session.

  Why not arm on the second press and catch its release (the older fishing-addon way): with
  ActionButtonUseKeyDown = 1, the setting retail ships with, the template acts on the press only,
  so a click that reaches the button on the release casts nothing. Arming after the first release
  works with both settings and never takes the first click away from the bobber. The cost: for
  the rest of the window after a right-click, the next right press casts instead of turning the
  camera - which is what a double-click is.

  Fallback: a client without IsMouseButtonDown gets the older way (arm on the second press within
  the window, catch its release, button registered for "AnyUp"); that only casts with
  ActionButtonUseKeyDown = 0, and /bfish status says so.

  The Fishing spell is resolved out of combat at login and on SPELLS_CHANGED (and
  LEARNED_SPELL_IN_TAB where the client still has it): the highest rank the character knows of
  7620, 7731, 7732, 18248 (and 131474, retail's single Fishing), else whatever the spellbook has
  under the localized name of 7620. The button gets the localized name, which casts the highest
  known rank, or the spell ID when the client gives no name.

  Taint: Blizzard code is only followed, never replaced. WorldFrame gets a HookScript; no Blizzard
  function or table is written. Bindings and attributes are only ever changed out of combat, on
  the addon's own frames. Every client API is checked with type(...) == "function" first, every
  handler runs in pcall (the last error is kept for /bfish status), and a secret value is never
  compared or tested: it is treated as no value.
]]

local _G = _G
local ADDON_NAME = ... or "BetterFishingForever"
local PREFIX = "|cff33ff99BetterFishingForever|r: "
local DOT = " \194\183 "

local VERSION = "1.0"

local MIN_WINDOW, MAX_WINDOW, DEFAULT_WINDOW = 0.2, 0.8, 0.4
local HOLD_CAP = 2.0          -- seconds an armed binding may wait for a held second press
local LEGACY_TIMEOUT = 0.6    -- fallback path: how long the binding waits for the release
local POLE_SLOT = 16          -- INVSLOT_MAINHAND
local BUTTON_NAME = "BetterFishingForeverButton"

-- Fishing, highest rank first: Artisan, Expert, Journeyman, Apprentice, then retail's one spell.
local FISHING_IDS = { 18248, 7732, 7731, 7620, 131474 }

-- Every key BetterFishingForeverDB may hold.
local SAVED_KEYS = { enabled = true, dblClick = true }

local db                  -- BetterFishingForeverDB, bound at ADDON_LOADED (never at file scope)
local button              -- the secure button the binding clicks
local owner               -- the plain frame that owns the override binding
local watcher             -- runs OnUpdate only while a press or an armed binding is pending

local spellValue          -- what the button's "spell" attribute holds (name or ID), or nil
local spellText           -- how it was resolved, for /bfish status
local spellPending        -- the spell changed in combat; set it at PLAYER_REGEN_ENABLED

local lastError           -- the last error caught, for /bfish status
local setupPending        -- logged in during combat; the secure button waits for it to end
local bindingStuck        -- the binding could not be cleared in combat; clear it after

-- The double-click state: "idle", "pending" (first press held), "armed" (binding active).
local state = "idle"
local downAt              -- GetTime() of the first press
local armedAt             -- GetTime() the binding was armed
local held                -- the right button was pressed again while armed
local fired               -- the secure button's PostClick ran while armed
local lastPressAt         -- fallback path only: the previous right press

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end

local function InCombat()
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() and true or false
end

-- Where the client hides a value it hands back a secret, which can be neither compared nor
-- tested. Those are treated as no value at all, and checked before anything else.
local issecretvalue = _G.issecretvalue
local function Secret(v)
    return issecretvalue and issecretvalue(v) and true or false
end

local function Num(v)
    if Secret(v) or type(v) ~= "number" or v ~= v then return nil end
    return v
end

local function Str(v)
    if Secret(v) or type(v) ~= "string" or v == "" then return nil end
    return v
end

local function Now()
    return type(_G.GetTime) == "function" and (Num(_G.GetTime()) or 0) or 0
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function Fail(where, err)
    lastError = where .. ": " .. tostring(err)
end

local function Window()
    return db and Num(db.dblClick) or DEFAULT_WINDOW
end

local function Enabled()
    return db ~= nil and db.enabled ~= false
end

-- ActionButtonUseKeyDown: secure buttons act on the press when 1, on the release when 0.
local function UseKeyDown()
    local c = _G.C_CVar
    local get = (type(c) == "table" and type(c.GetCVarBool) == "function" and c.GetCVarBool)
        or (type(_G.GetCVarBool) == "function" and _G.GetCVarBool)
    if not get then return false end
    local ok, v = pcall(get, "ActionButtonUseKeyDown")
    if not ok or Secret(v) then return false end
    return v and true or false
end

local function RightButtonDown()
    if type(_G.IsMouseButtonDown) ~= "function" then return nil end
    local ok, v = pcall(_G.IsMouseButtonDown, "RightButton")
    if not ok or Secret(v) then return nil end
    return v and true or false
end

local function HasReleaseCheck()
    return type(_G.IsMouseButtonDown) == "function"
end

local function CursorEmpty()
    if type(_G.GetCursorInfo) ~= "function" then return true end
    local ok, what = pcall(_G.GetCursorInfo)
    if not ok then return true end
    if Secret(what) then return false end
    return what == nil
end

-- ---------------------------------------------------------------------------
-- Fishing pole and Fishing spell
-- ---------------------------------------------------------------------------

local WEAPON_CLASS, POLE_SUBCLASS = 2, 20
do
    local enum = _G.Enum
    if type(enum) == "table" then
        if type(enum.ItemClass) == "table" and Num(enum.ItemClass.Weapon) then
            WEAPON_CLASS = enum.ItemClass.Weapon
        end
        if type(enum.ItemWeaponSubclass) == "table" and Num(enum.ItemWeaponSubclass.Fishingpole) then
            POLE_SUBCLASS = enum.ItemWeaponSubclass.Fishingpole
        end
    end
end

local function ItemClass(itemID)
    local c = _G.C_Item
    local info = (type(c) == "table" and type(c.GetItemInfoInstant) == "function" and c.GetItemInfoInstant)
        or (type(_G.GetItemInfoInstant) == "function" and _G.GetItemInfoInstant)
    if not info then return nil end
    local ok, _, _, _, _, _, classID, subClassID = pcall(info, itemID)
    if not ok then return nil end
    return Num(classID), Num(subClassID)
end

local function PoleEquipped()
    if type(_G.GetInventoryItemID) ~= "function" then return false end
    local ok, itemID = pcall(_G.GetInventoryItemID, "player", POLE_SLOT)
    itemID = ok and Num(itemID)
    if not itemID then return false end
    local classID, subClassID = ItemClass(itemID)
    return classID == WEAPON_CLASS and subClassID == POLE_SUBCLASS
end

-- The localized name of a spell, from C_Spell (a table) or the old GetSpellInfo (values).
local function SpellName(spell)
    local c = _G.C_Spell
    if type(c) == "table" and type(c.GetSpellInfo) == "function" then
        local ok, info = pcall(c.GetSpellInfo, spell)
        if ok and type(info) == "table" then
            local name = Str(info.name)
            if name then return name, Num(info.spellID) end
        end
    end
    if type(_G.GetSpellInfo) == "function" then
        local ok, name, _, _, _, _, _, id = pcall(_G.GetSpellInfo, spell)
        if ok and Str(name) then return name, Num(id) end
    end
    return nil
end

local function Known(id)
    local checks = {}
    local sb = _G.C_SpellBook
    if type(sb) == "table" and type(sb.IsSpellKnown) == "function" then checks[#checks + 1] = sb.IsSpellKnown end
    if type(_G.IsPlayerSpell) == "function" then checks[#checks + 1] = _G.IsPlayerSpell end
    if type(_G.IsSpellKnown) == "function" then checks[#checks + 1] = _G.IsSpellKnown end
    for _, f in ipairs(checks) do
        local ok, known = pcall(f, id)
        if ok and not Secret(known) and known then return true end
    end
    return false
end

-- Returns the attribute value (name, or ID when there is no name) and a line for /bfish status.
local function FindFishing()
    for _, id in ipairs(FISHING_IDS) do
        if Known(id) then
            local name = SpellName(id)
            if name then return name, string.format("%s (known: spell %d, cast by name)", name, id) end
            return id, string.format("spell %d (known, cast by ID: no name on this client)", id)
        end
    end
    -- No rank reported as known: look the localized name up; that finds it only in the spellbook.
    local localized = SpellName(7620)
    if localized then
        local name, id = SpellName(localized)
        if name and id then
            return name, string.format("%s (spellbook by name: spell %d)", name, id)
        end
    end
    return nil, (localized or "Fishing") .. " - not known by this character"
end

local function ApplySpell()
    if not button then return end
    if InCombat() then
        spellPending = true
        return
    end
    spellPending = false
    local ok, err = pcall(function()
        spellValue, spellText = FindFishing()
        button:SetAttribute("type", "spell")
        button:SetAttribute("spell", spellValue)
    end)
    if not ok then Fail("resolving Fishing", err) end
end

-- ---------------------------------------------------------------------------
-- The binding
-- ---------------------------------------------------------------------------

local function StopWatching()
    if watcher then watcher:Hide() end
end

local function StartWatching()
    if watcher then watcher:Show() end
end

local function ClearBinding()
    if not owner or type(_G.ClearOverrideBindings) ~= "function" then return end
    if InCombat() then
        bindingStuck = true         -- PLAYER_REGEN_ENABLED clears it
        return
    end
    bindingStuck = false
    local ok, err = pcall(_G.ClearOverrideBindings, owner)
    if not ok then Fail("clearing the binding", err) end
end

local function Disarm()
    if state == "armed" then ClearBinding() end
    state, downAt, armedAt, held, fired = "idle", nil, nil, nil, nil
    StopWatching()
end

-- Binds BUTTON2 to the secure button, registered for the one click direction the CVar acts on.
local function Arm(direction)
    if InCombat() or not button or not owner or type(_G.SetOverrideBindingClick) ~= "function" then
        return false
    end
    local ok, err = pcall(function()
        button:RegisterForClicks(direction)
        _G.SetOverrideBindingClick(owner, true, "BUTTON2", BUTTON_NAME)
    end)
    if not ok then
        Fail("arming the binding", err)
        return false
    end
    state, armedAt, held, fired = "armed", Now(), false, false
    StartWatching()
    return true
end

-- Everything a press must pass before it may lead to a cast.
local function CanFish()
    return Enabled() and not InCombat() and spellValue ~= nil and CursorEmpty() and PoleEquipped()
end

local function OnUpdate()
    local ok, err = pcall(function()
        local now = Now()
        if state == "pending" then
            local down = RightButtonDown()
            if now - (downAt or now) > Window() then
                Disarm()                    -- still held after the window: a camera drag
            elseif down == false then
                -- The first click is over and went to TURNORACTION as always; arm for the rest.
                if CanFish() then
                    Arm(UseKeyDown() and "AnyDown" or "AnyUp")
                else
                    Disarm()
                end
            end
        elseif state == "armed" then
            if InCombat() then
                Disarm()
                return
            end
            local down = RightButtonDown()
            if down then held = true end
            if down == nil then
                -- Fallback path: no release check, so PostClick or the timeout clears it.
                if fired or now - (armedAt or now) > LEGACY_TIMEOUT then Disarm() end
            elseif held then
                if not down or now - (armedAt or now) > HOLD_CAP then Disarm() end
            elseif now - (downAt or now) > Window() then
                Disarm()                    -- no second press in time
            end
        else
            StopWatching()
        end
    end)
    if not ok then
        Fail("OnUpdate", err)
        Disarm()
    end
end

local function OnWorldMouseDown(_, mouseButton)
    if mouseButton ~= "RightButton" then return end
    local ok, err = pcall(function()
        if state == "armed" then return end     -- the binding has this press
        if not CanFish() then
            Disarm()
            lastPressAt = nil
            return
        end
        local now = Now()
        if HasReleaseCheck() then
            state, downAt = "pending", now
            StartWatching()
            return
        end
        -- Fallback: this press is the second one; catch its release.
        if lastPressAt and now - lastPressAt <= Window() then
            lastPressAt = nil
            if type(_G.IsMouselooking) == "function" and _G.IsMouselooking()
                and type(_G.MouselookStop) == "function" then
                _G.MouselookStop()
            end
            Arm("AnyUp")
        else
            lastPressAt = now
        end
    end)
    if not ok then Fail("OnMouseDown", err) end
end

local function CreateFrames()
    if button then return end
    owner = CreateFrame("Frame", nil, _G.UIParent)
    watcher = CreateFrame("Frame")
    watcher:Hide()
    watcher:SetScript("OnUpdate", OnUpdate)

    -- Shown, 1x1 and off screen to the right, so no real click can land on it.
    button = CreateFrame("Button", BUTTON_NAME, _G.UIParent, "SecureActionButtonTemplate")
    button:SetSize(1, 1)
    button:SetPoint("LEFT", _G.UIParent, "RIGHT", 10000, 0)
    button:RegisterForClicks(UseKeyDown() and "AnyDown" or "AnyUp")
    button:SetAttribute("type", "spell")
    button:HookScript("PostClick", function()
        if state == "armed" then fired = true end
    end)
    button:Show()

    local world = _G.WorldFrame
    if type(world) == "table" and type(world.HookScript) == "function" then
        world:HookScript("OnMouseDown", OnWorldMouseDown)
    else
        Fail("setup", "no WorldFrame on this client")
    end
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function SetEnabled(on, quiet)
    db.enabled = on and true or false
    if not on then Disarm() end
    if not quiet then Print(on and "on: double right-click casts Fishing while a pole is equipped." or "off.") end
end

local function SetWindow(v, quiet)
    db.dblClick = Clamp(math.floor(v * 100 + 0.5) / 100, MIN_WINDOW, MAX_WINDOW)
    if not quiet then Print(string.format("double-click window: %.2f s.", db.dblClick)) end
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function YesNo(v) return v and "yes" or "no" end

local function PrintHelp()
    Print("double right-click in the world to cast Fishing while a fishing pole is equipped.")
    Print("/bfish on | /bfish off - switch it on or off")
    Print(string.format("/bfish window <%.1f-%.1f> - seconds between the two right-clicks (now %.2f)",
        MIN_WINDOW, MAX_WINDOW, Window()))
    Print("/bfish status - the current state and what this client offers")
end

local function PrintStatus()
    Print("version " .. VERSION)
    Print("enabled: " .. YesNo(Enabled()) .. string.format("   window: %.2f s", Window())
        .. "   fishing pole equipped: " .. YesNo(PoleEquipped()))
    Print("Fishing: " .. (spellText or "not resolved yet") .. (spellPending and " (update waits for combat to end)" or ""))
    Print("override armed: " .. YesNo(state == "armed") .. "   state: " .. state
        .. "   ActionButtonUseKeyDown: " .. (UseKeyDown() and "1 (casts on the press)" or "0 (casts on the release)"))
    if not HasReleaseCheck() then
        Print("no IsMouseButtonDown on this client: using the fallback, which only casts with ActionButtonUseKeyDown 0.")
    end
    Print("last error: " .. (lastError or "none"))
end

local function OnSlash(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = (cmd or ""):lower()
    if cmd == "on" or cmd == "off" then
        SetEnabled(cmd == "on")
    elseif cmd == "window" then
        local v = tonumber(arg)
        if not v or v ~= v then
            Print(string.format("/bfish window <%.1f-%.1f>, e.g. /bfish window 0.4 (now %.2f).", MIN_WINDOW, MAX_WINDOW, Window()))
        else
            SetWindow(v)
        end
    elseif cmd == "status" then
        PrintStatus()
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterFishingForeverAPI
--
-- For BetterGaarForever, the optional hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterFishingForeverDB and change only through the
-- same functions /bfish uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "on · 0.40 s · pole equipped"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func },
--                        { text, radio = true, checked, func }, { text, submenu } and
--                        { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local WINDOW_CHOICES = { 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 }

local function StatusLine()
    if not db then return "not loaded yet" end
    return (Enabled() and "on" or "off") .. DOT .. string.format("%.2f s", Window())
        .. DOT .. (PoleEquipped() and "pole equipped" or "no pole")
        .. (spellValue == nil and (DOT .. "Fishing not known") or "")
end

local function MenuEntries()
    if not db then return {} end
    local windows = {}
    for _, v in ipairs(WINDOW_CHOICES) do
        windows[#windows + 1] = { text = string.format("%.1f s", v) .. (v == DEFAULT_WINDOW and " (default)" or ""),
            radio = true,
            checked = function() return math.abs(Window() - v) < 0.001 end,
            func = function() SetWindow(v) end }
    end
    return {
        { text = "Double right-click casts Fishing", checkbox = true,
          checked = function() return Enabled() end,
          func = function() SetEnabled(not Enabled()) end },
        { text = "Double-click window", submenu = windows },
    }
end

-- Draws the entries into a MenuUtil description (root or submenu); every method is checked first.
local function RenderMenu(root, entries)
    if type(root) ~= "table" then return end
    for _, e in ipairs(entries) do
        if e.divider then
            if type(root.CreateDivider) == "function" then root:CreateDivider() end
        elseif e.submenu then
            if type(root.CreateButton) == "function" then
                local sub = root:CreateButton(e.text)
                RenderMenu(sub, e.submenu)
            end
        elseif e.radio and type(root.CreateRadio) == "function" then
            root:CreateRadio(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox and type(root.CreateCheckbox) == "function" then
            root:CreateCheckbox(e.text, function() return e.checked() and true or false end, function() e.func() end)
        elseif e.checkbox or e.radio then
            -- A menu without checkboxes or radios: show the state in the label instead.
            local mark = e.radio and (e.checked() and "(o) " or "( ) ") or (e.checked() and "[x] " or "[ ] ")
            if type(root.CreateButton) == "function" then root:CreateButton(mark .. e.text, function() e.func() end) end
        elseif type(root.CreateButton) == "function" then
            root:CreateButton(e.text, function() e.func() end)
        end
    end
end

_G.BetterFishingForeverAPI = {
    version = VERSION,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) RenderMenu(root, MenuEntries()) end,
    SetMinimapHidden = function() end,
}

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterFishingForeverDB) ~= "table" then BetterFishingForeverDB = {} end
    db = BetterFishingForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    if type(db.enabled) ~= "boolean" then db.enabled = true end
    local w = Num(tonumber(db.dblClick))
    db.dblClick = w and Clamp(w, MIN_WINDOW, MAX_WINDOW) or DEFAULT_WINDOW
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("SPELLS_CHANGED")
-- Gone from retail 11.0; registering an event the client does not know raises an error.
pcall(events.RegisterEvent, events, "LEARNED_SPELL_IN_TAB")
events:SetScript("OnEvent", function(_, event, arg1)
    local ok, err = pcall(function()
        if event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then BindSavedVariables() end
        elseif event == "PLAYER_LOGIN" then
            if InCombat() then
                setupPending = true     -- a secure button cannot be set up in combat
            else
                CreateFrames()
                ApplySpell()
            end
        elseif event == "PLAYER_REGEN_DISABLED" then
            -- Fires just before combat locks bindings: clear the override while that still works.
            Disarm()
        elseif event == "PLAYER_REGEN_ENABLED" then
            if setupPending then
                setupPending = false
                CreateFrames()
                ApplySpell()
            elseif spellPending then
                ApplySpell()
            end
            if bindingStuck then ClearBinding() end
        else
            ApplySpell()        -- SPELLS_CHANGED, LEARNED_SPELL_IN_TAB
        end
    end)
    if not ok then Fail(event, err) end
end)

SLASH_BETTERFISHINGFOREVER1 = "/bfish"
SLASH_BETTERFISHINGFOREVER2 = "/betterfishingforever"
SlashCmdList.BETTERFISHINGFOREVER = OnSlash
