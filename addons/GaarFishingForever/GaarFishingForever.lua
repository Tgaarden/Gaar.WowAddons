--[[
  GaarFishingForever - double right-click in the world to cast Fishing, on WoW Forever.

  It does this and nothing else:

    * Double right-click in the 3D world casts Fishing, but only while a fishing pole is in the
      main-hand slot (16) and you are not in combat. A single right-click works exactly as
      before: the bobber is looted, an NPC is talked to, the camera turns.
    * The double-click window (the time from the first right press to the second) is 0.4 s by
      default and can be set from 0.2 to 0.8 s.
    * Nothing happens while the cursor holds an item. Clicks on the UI never reach WorldFrame,
      so they are never touched.
    * Shift + double right-click in the world swaps the fishing pole in and out (1.1): with no pole
      in the main hand, the main and off hand are remembered and the best pole in the bags is
      equipped; with a pole on, the remembered weapons go back. It never casts Fishing. See
      "Pole swap" below.
    * Fishing 1-300 route (1.2, /gfish route on, off by default): the current step from your
      Fishing skill and cap, pins on the world map and minimap, and GaarGpsForever's arrow on
      the nearest spot. The data is in Route.lua, the logic in RouteGuide.lua (ns.guide); this
      file only wires it into /gfish, the saved variables and the hub menu.
    * Reel in (1.3, /gfish reel on|off, on by default): while the Fishing channel runs (the line
      is out), the same double right-click anywhere in the world reels in - it interacts with the
      bobber instead of casting again. See "Reel in" below.
    * A "Cast / Reel" key binding (1.3, Esc > Options > Keybindings > GaarFishingForever): one
      key casts Fishing, and reels in while the line is out.
    * Session stats (1.4, /gfish stats, on by default): a small movable panel while a pole is
      equipped or the line is out - session time, casts, catches, catches/hour, Fishing skill and
      what it gained, and what was looted while fishing. In Stats.lua (ns.stats); this file passes
      it the casts and the channel stop.
    * Loud splash (1.4, /gfish splash on|off, off by default): while the line is out, the sound
      CVars are set so the bobber's splash is easy to hear, and put back after. See "Loud splash"
      below; it is the bite alert, because this engine has no bite signal.
    * /gfish for help, on, off, window <0.2-0.8>, reel, swap, splash, stats, route and status.
    * GaarFishingForeverAPI, a small global table for GaarForever's hub menu (version,
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
  ActionButtonUseKeyDown = 0, and /gfish status says so.

  The Fishing spell is resolved out of combat at login and on SPELLS_CHANGED (and
  LEARNED_SPELL_IN_TAB where the client still has it): the highest rank the character knows of
  7620, 7731, 7732, 18248 (and 131474, retail's single Fishing), else whatever the spellbook has
  under the localized name of 7620. The button gets the localized name, which casts the highest
  known rank, or the spell ID when the client gives no name.

  Pole swap (1.1). Shift + double right-click = a right press on WorldFrame with Shift held, within
  the window after the previous right press (the first press may or may not have Shift). How the
  gesture keeps clear of the Fishing sequence above:

    * A press with Shift held never starts the Fishing sequence, and a first release with Shift
      held never arms the binding. So with Shift held from the start nothing is bound at all:
      both presses go to the client as always (Shift + single right-click is untouched) and the
      second one is seen by the WorldFrame hook, which does the swap.
    * Shift pressed after a plain first click, while the binding is armed: the watcher's OnUpdate
      sees IsShiftKeyDown() and clears the binding at once, before the second press.
    * Shift and the second press in the same frame, while still armed: the secure button carries
      "shift-type*" = an unknown action type, so the Shift click does nothing (SecureTemplates
      resolve "shift-type*" before "type"), and its PreClick hook does the swap instead. Either
      way the binding is cleared; the swap never leaves an override behind.

  Equip path. EquipItemByName (C_Item.EquipItemByName where the client has it) and
  PickupContainerItem + EquipCursorItem are not protected out of combat, on classic or on the
  retail engine; equipment managers call them from events and timers. So the swap calls them
  directly. It still runs inside the second press's own handler (OnMouseDown or PreClick), a
  hardware event, in case a client ever wants one. No secure macro button is needed; should the
  client block the call anyway, ADDON_ACTION_BLOCKED / _FORBIDDEN for this addon is caught,
  printed and shown in /gfish status. Order: C_Item.EquipItemByName, EquipItemByName, then
  pickup + EquipCursorItem. Never in combat ("can't swap weapons in combat"), never while
  casting or channelling ("stop fishing first"), never with an item on the cursor.

  Remembered weapons live per character in GaarFishingForeverCharDB.swap (itemID + link of
  slots 16 and 17), so they survive /reload. Restoring looks in the bags for the exact link first,
  then the itemID. A two-hander puts back only the main hand. The off hand is equipped once the
  main-hand swap has landed (polled, at most 3 s), so the two swaps never race the pole out.

  Reel in (1.3). The retail engine Forever runs has soft targeting: the "Interact With Target"
  binding (INTERACTTARGET, Bindings_Standard/_Camelot.xml: C_PlayerInteractionManager.InteractUnit(
  "anyinteract")) interacts with the soft interact target, and the fishing bobber is one once the
  SoftTargetInteract CVar allows keyboard and mouse (Enum.SoftTargetEnableFlags: 0 None, 1 Gamepad,
  2 Kbm, 3 Any). InteractUnit is restricted, so the addon never calls it: it only points the
  second press at the binding.

    * The line is out from UNIT_SPELLCAST_CHANNEL_START (player, a Fishing spell ID, or a spell
      whose name is the resolved Fishing) to UNIT_SPELLCAST_CHANNEL_STOP. While it is, step 2 of
      the sequence above binds SetOverrideBinding(owner, true, "BUTTON2", "INTERACTTARGET")
      instead of the click on the secure button. The binding runs on the press; the release is
      swallowed and cleared exactly as for a cast (step 4). The first click is untouched.
    * CVars, only while the line is out and only out of combat: SoftTargetInteract 3 (left alone
      at 2 or 3), SoftTargetInteractRange 30 (left alone at 30 or more), SoftTargetInteractArc 2
      (left alone at 2 or more) and SoftTargetInteractRangeIsHard 0, each only when the client
      has it. The previous value of each one changed is kept in GaarFishingForeverDB.held and
      put back at the channel stop, when the pole comes off, at PLAYER_REGEN_DISABLED, at
      /gfish reel off, at PLAYER_LOGOUT, and at the next login for anything a crash or a logout
      in combat left behind. In combat nothing is set or put back; it waits for
      PLAYER_REGEN_ENABLED. /gfish reel follows only its own setting, not /gfish on|off.
    * The channel ends while armed for reeling but before the second press (the bobber was
      looted by the first click): the binding is re-armed as the cast, so the double-click on
      the bobber still loots and casts again, as before 1.3.
    * The "Cast / Reel" key (Bindings.xml: CLICK BetterFishingForeverKeyButton:LeftButton, in
      the "GaarFishingForever" section of the Key Bindings page). A second secure button
      (type "spell", the same Fishing; useOnKeyDown = true and registered for "AnyDown" only, so
      it casts on the press and its release never does anything) casts, pole or not. While the
      line is out and reeling is on, the keys bound to it (GetBindingKey) are overridden to
      INTERACTTARGET on a frame of their own (SetOverrideBinding(keyOwner, true, key,
      "INTERACTTARGET")), and cleared again with the CVars. In combat the override is neither set
      nor kept (it is cleared at PLAYER_REGEN_DISABLED), so there the key casts.
    * Not on a client without the INTERACTTARGET binding or the SoftTargetInteract CVar, and not
      on the fallback path (it catches the release, and the binding acts on the press): there the
      double-click casts again as before, and the first cast says so once per session.

  Loud splash (1.4) - the bite alert. The client gives an addon no "bite" signal: the forever
  branch of Blizzard's UI source (Gethe/wow-ui-source, checked 2026-11) has no bite event; the
  Fishing channel gets no UNIT_SPELLCAST_CHANNEL_UPDATE when a fish bites; PLAYER_SOFT_INTERACT_
  CHANGED fires when the soft interact target changes (the bobber appearing or going away), not
  on the bite, and its GUIDs may be secret; and the bobber's mouseover and tooltip do not change.
  So the addon cannot time a sound or a flash of its own to the bite - it would only be a guess -
  and it plays none and flashes nothing. What it does instead is the classic fishing-addon trick:
  make the game's own splash loud.

    * While the line is out, only out of combat and only when "splash" is on: Sound_EnableAllSound
      1, Sound_EnableSFX 1, Sound_MasterVolume 1 and Sound_SFXVolume 1 (each left alone when it
      already is), Sound_MusicVolume 0 and Sound_AmbienceVolume 0 (left alone at 0). Each only
      when the client has the CVar.
    * The previous value of each one changed is kept in GaarFishingForeverDB.splashHeld and put
      back exactly like the reel CVars: at the channel stop, when the pole comes off, at
      PLAYER_REGEN_DISABLED, at /gfish splash off, at PLAYER_LOGOUT, and at the next login for
      anything a crash or a logout in combat left behind. In combat nothing is set or put back.
    * A volume you change yourself while the line is out is overwritten by the value from before
      the cast when it ends.

  Taint: Blizzard code is only followed, never replaced. WorldFrame gets a HookScript; no Blizzard
  function or table is written. Bindings and attributes are only ever changed out of combat, on
  the addon's own frames. Every client API is checked with type(...) == "function" first, every
  handler runs in pcall (the last error is kept for /gfish status), and a secret value is never
  compared or tested: it is treated as no value.
]]

local _G = _G
local ADDON_NAME, ns = ...
ADDON_NAME = ADDON_NAME or "GaarFishingForever"
ns = type(ns) == "table" and ns or {}
local DOT = " \194\183 "

local VERSION = "1.5.1"

-- The shared library (GaarForever's Lib.lua, loaded first through ## Dependencies); the addon
-- object is made by RouteGuide.lua, which loads first.
local BF = _G.GaarForever
local A = ns.addon or BF.NewAddon("GaarFishingForever", { title = "GaarFishingForever" })
ns.addon = A
A.version = VERSION
local InCombat, Secret, Str = BF.InCombat, BF.IsSecret, BF.Str

local MIN_WINDOW, MAX_WINDOW, DEFAULT_WINDOW = 0.2, 0.8, 0.4
local HOLD_CAP = 2.0          -- seconds an armed binding may wait for a held second press
local LEGACY_TIMEOUT = 0.6    -- fallback path: how long the binding waits for the release
local POLE_SLOT = 16          -- INVSLOT_MAINHAND
local BUTTON_NAME = "GaarFishingForeverButton"
local KEY_BUTTON_NAME = "BetterFishingForeverKeyButton" -- keeps the old name: key bindings are saved by this command string
local KEY_BINDING = "CLICK " .. KEY_BUTTON_NAME .. ":LeftButton"   -- as in Bindings.xml

-- The Key Bindings page (Esc > Options > Keybindings, section "GaarFishingForever") names the
-- binding by this global; Bindings.xml declares it.
_G["BINDING_NAME_" .. KEY_BINDING] = "Cast / Reel"

-- Fishing, highest rank first: Artisan, Expert, Journeyman, Apprentice, then retail's one spell.
local FISHING_IDS = { 18248, 7732, 7731, 7620, 131474 }

-- Every key GaarFishingForeverDB may hold. reel: reel in while the line is out (1.3); held: the
-- CVars changed for reeling, name = the value before; reelHint: the first-time hint was shown.
-- 1.4: splash (loud splash on), splashHeld (the sound CVars it changed, name = the value before),
-- stats (the session panel on) and statsPos (its position; both used by Stats.lua).
local SAVED_KEYS = { enabled = true, dblClick = true, reel = true, held = true, reelHint = true,
    splash = true, splashHeld = true, stats = true, statsPos = true }

-- Reel in (1.3): what soft interact needs to target the bobber by itself. want is set while the
-- line is out, unless enough() already holds for the current value.
local REEL_CVARS = {
    { name = "SoftTargetInteract", want = 3, enough = function(v) return v == 2 or v == 3 end },
    { name = "SoftTargetInteractRange", want = 30, enough = function(v) return v >= 30 end },
    { name = "SoftTargetInteractArc", want = 2, enough = function(v) return v >= 2 end },
    { name = "SoftTargetInteractRangeIsHard", want = 0, enough = function(v) return v == 0 end },
}
local REEL_CVAR_KNOWN = {}
for _, c in ipairs(REEL_CVARS) do REEL_CVAR_KNOWN[c.name] = true end

-- Loud splash (1.4): the sound CVars set while the line is out, the same way.
local SPLASH_CVARS = {
    { name = "Sound_EnableAllSound", want = 1, enough = function(v) return v == 1 end },
    { name = "Sound_EnableSFX", want = 1, enough = function(v) return v == 1 end },
    { name = "Sound_MasterVolume", want = 1, enough = function(v) return v >= 1 end },
    { name = "Sound_SFXVolume", want = 1, enough = function(v) return v >= 1 end },
    { name = "Sound_MusicVolume", want = 0, enough = function(v) return v <= 0 end },
    { name = "Sound_AmbienceVolume", want = 0, enough = function(v) return v <= 0 end },
}
local SPLASH_CVAR_KNOWN = {}
for _, c in ipairs(SPLASH_CVARS) do SPLASH_CVAR_KNOWN[c.name] = true end

local db                  -- GaarFishingForeverDB, bound at ADDON_LOADED (never at file scope)
local charDb              -- GaarFishingForeverCharDB (per character): the pole swap's memory
local button              -- the secure button the binding clicks
local owner               -- the plain frame that owns the override binding
local keyButton           -- the secure button the "Cast / Reel" key binding clicks (1.3)
local keyOwner            -- owns the key's INTERACTTARGET override while the line is out
local watcher             -- runs OnUpdate only while a press or an armed binding is pending

local spellValue          -- what the button's "spell" attribute holds (name or ID), or nil
local spellText           -- how it was resolved, for /gfish status
local spellPending        -- the spell changed in combat; set it at PLAYER_REGEN_ENABLED

local lastError           -- the last error caught, for /gfish status
local setupPending        -- logged in during combat; the secure button waits for it to end
local bindingStuck        -- the binding could not be cleared in combat; clear it after

-- The double-click state: "idle", "pending" (first press held), "armed" (binding active).
local state = "idle"
local downAt              -- GetTime() of the first press
local armedAt             -- GetTime() the binding was armed
local held                -- the right button was pressed again while armed
local fired               -- the secure button's PostClick ran while armed
local lastPressAt         -- fallback path only: the previous right press
local lastRightAt         -- pole swap: GetTime() of the previous right press on WorldFrame

-- Reel in (1.3).
local lineOut             -- the Fishing channel runs
local armedReel           -- the armed binding is INTERACTTARGET, not the click
local reelSupport         -- nil: not checked yet; true / false: the client has what reeling needs
local reelNoticeShown     -- "not supported" was printed this session
local releasePending      -- the held CVars wait for combat to end to go back
local splashPending       -- loud splash (1.4): the sound CVars wait for combat to end to go back

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg) A:Print(msg) end

-- Where the client hides a value it hands back a secret, which can be neither compared nor
-- tested. Those are treated as no value at all, and checked before anything else. Num stays
-- here: unlike BF.Num it lets infinity through.
local function Num(v)
    if Secret(v) or type(v) ~= "number" or v ~= v then return nil end
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

local function ShiftDown()
    if type(_G.IsShiftKeyDown) ~= "function" then return false end
    local ok, v = pcall(_G.IsShiftKeyDown)
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

-- Returns the attribute value (name, or ID when there is no name) and a line for /gfish status.
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
        if keyButton then
            keyButton:SetAttribute("type", "spell")
            keyButton:SetAttribute("spell", spellValue)
        end
    end)
    if not ok then Fail("resolving Fishing", err) end
end


-- ---------------------------------------------------------------------------
-- Pole swap (1.1): Shift + double right-click or /gfish swap.
--
-- Self-contained: the Fishing sequence only calls TrySwapGesture() and checks ShiftDown(); the
-- rest lives here. See the header ("Pole swap") for how it avoids casting.
-- ---------------------------------------------------------------------------

local OFF_SLOT = 17                 -- INVSLOT_OFFHAND
local OFFHAND_WAIT = 3.0            -- seconds the off hand waits for the main-hand swap to land

-- Known poles and their classic fishing bonus, used only to pick the best one in the bags. Any
-- other class 2 / subclass 20 item counts as a pole too, with bonus 0.
local POLE_BONUS = {
    [6256] = 0,     -- Fishing Pole
    [12225] = 3,    -- Blump Family Fishing Pole
    [6365] = 5,     -- Strong Fishing Pole
    [6366] = 15,    -- Darkwood Fishing Pole
    [6367] = 20,    -- Big Iron Fishing Pole
    [19022] = 25,   -- Nat Pagle's Extreme Angler FC-5000
    [19970] = 35,   -- Arcanite Fishing Pole
}

local swapWatcher                   -- runs OnUpdate only while an off hand waits to go back on
local offPending                    -- { id, link, deadline, mainID } while it waits
local gestureAt                     -- the last gesture swap, so two hooks of one press swap once
local lastBlocked                   -- the client blocked an equip call: "function (time)"

local function Container()
    local c = _G.C_Container
    local t = type(c) == "table" and c or {}
    local function pick(name)
        if type(t[name]) == "function" then return t[name] end
        if type(_G[name]) == "function" then return _G[name] end
        return nil
    end
    return pick("GetContainerNumSlots"), pick("GetContainerItemID"),
        pick("GetContainerItemLink"), pick("PickupContainerItem")
end

local function EquipByNameFunc()
    local c = _G.C_Item
    if type(c) == "table" and type(c.EquipItemByName) == "function" then
        return c.EquipItemByName, "C_Item.EquipItemByName"
    end
    if type(_G.EquipItemByName) == "function" then return _G.EquipItemByName, "EquipItemByName" end
    return nil
end

-- The path the swap will use, for /gfish status; nil when the client offers none.
local function EquipPath()
    local _, name = EquipByNameFunc()
    if name then return name end
    local _, _, _, pickup = Container()
    if pickup and type(_G.EquipCursorItem) == "function" then return "PickupContainerItem + EquipCursorItem" end
    return nil
end

local function SlotItem(slot)
    if type(_G.GetInventoryItemID) ~= "function" then return nil end
    local ok, id = pcall(_G.GetInventoryItemID, "player", slot)
    id = ok and Num(id) or nil
    if not id then return nil end
    local link
    if type(_G.GetInventoryItemLink) == "function" then
        local ok2, l = pcall(_G.GetInventoryItemLink, "player", slot)
        link = ok2 and Str(l) or nil
    end
    return id, link
end

-- Every bag item as { bag, slot, id, link }, backpack first.
local function BagItems()
    local numSlots, itemID, itemLink = Container()
    local items = {}
    if not numSlots or not itemID then return items end
    local last = Num(_G.NUM_BAG_SLOTS) or 4
    for bag = 0, last do
        local ok, n = pcall(numSlots, bag)
        n = ok and Num(n) or 0
        for slot = 1, n do
            local ok2, id = pcall(itemID, bag, slot)
            id = ok2 and Num(id) or nil
            if id then
                local link
                if itemLink then
                    local ok3, l = pcall(itemLink, bag, slot)
                    link = ok3 and Str(l) or nil
                end
                items[#items + 1] = { bag = bag, slot = slot, id = id, link = link }
            end
        end
    end
    return items
end

-- The best pole in the bags: the highest known bonus, else the first one found.
local function FindPole()
    local best, bestBonus
    for _, it in ipairs(BagItems()) do
        local classID, subClassID = ItemClass(it.id)
        if POLE_BONUS[it.id] or (classID == WEAPON_CLASS and subClassID == POLE_SUBCLASS) then
            local bonus = POLE_BONUS[it.id] or 0
            if not best or bonus > bestBonus then best, bestBonus = it, bonus end
        end
    end
    return best
end

-- A remembered item in the bags: the exact link first, else the same itemID.
local function FindInBags(id, link)
    local byID
    for _, it in ipairs(BagItems()) do
        if link and it.link == link then return it end
        if not byID and it.id == id then byID = it end
    end
    return byID
end

local function TwoHanded(itemID)
    local c = _G.C_Item
    local info = (type(c) == "table" and type(c.GetItemInfoInstant) == "function" and c.GetItemInfoInstant)
        or (type(_G.GetItemInfoInstant) == "function" and _G.GetItemInfoInstant)
    if not info then return false end
    local ok, _, _, _, equipLoc = pcall(info, itemID)
    return ok and Str(equipLoc) == "INVTYPE_2HWEAPON"
end

local function Casting()
    for _, name in ipairs({ "UnitCastingInfo", "UnitChannelInfo" }) do
        local f = _G[name]
        if type(f) == "function" then
            local ok, spell = pcall(f, "player")
            if ok and Str(spell) then return true end
        end
    end
    return false
end

-- Equips one bag item into an inventory slot; false when the client offers no way to.
local function Equip(it, slot)
    local byName = EquipByNameFunc()
    if byName then
        local ok, err = pcall(byName, it.link or it.id, slot)
        if not ok then Fail("equipping", err) end
        return ok
    end
    local _, _, _, pickup = Container()
    if not pickup or type(_G.EquipCursorItem) ~= "function" then return false end
    local ok, err = pcall(function()
        pickup(it.bag, it.slot)
        if not CursorEmpty() then _G.EquipCursorItem(slot) end
        -- Anything still on the cursor goes back where it came from.
        if not CursorEmpty() and type(_G.ClearCursor) == "function" then _G.ClearCursor() end
    end)
    if not ok then Fail("equipping", err) end
    return ok
end

local function ItemText(id, link)
    return link or ("item " .. tostring(id))
end

local function StopOffPending()
    offPending = nil
    if swapWatcher then swapWatcher:Hide() end
end

-- Waits for the main-hand swap to land, then puts the off hand back.
local function OffPendingUpdate()
    local ok, err = pcall(function()
        if not offPending then StopOffPending() return end
        if InCombat() then
            Print("off hand not put back: combat started (" .. ItemText(offPending.id, offPending.link) .. ").")
            StopOffPending()
            return
        end
        local mainNow = SlotItem(POLE_SLOT)
        local locked = type(_G.IsInventoryItemLocked) == "function" and _G.IsInventoryItemLocked(POLE_SLOT)
        if Secret(locked) then locked = false end
        local landed = not locked and (mainNow == offPending.mainID or not PoleEquipped())
        if landed then
            local it = FindInBags(offPending.id, offPending.link)
            if it then
                Equip(it, OFF_SLOT)
            else
                Print("not in your bags: " .. ItemText(offPending.id, offPending.link))
            end
            StopOffPending()
        elseif Now() > offPending.deadline then
            Print("off hand not put back: the main hand did not change in time ("
                .. ItemText(offPending.id, offPending.link) .. ").")
            StopOffPending()
        end
    end)
    if not ok then
        Fail("off hand", err)
        StopOffPending()
    end
end

local function EquipPole()
    local pole = FindPole()
    if not pole then
        Print("no fishing pole in your bags.")
        return
    end
    local mainID, mainLink = SlotItem(POLE_SLOT)
    local offID, offLink = SlotItem(OFF_SLOT)
    charDb.swap = { mainID = mainID, mainLink = mainLink, offID = offID, offLink = offLink }
    if Equip(pole, POLE_SLOT) then
        Print("equipped " .. ItemText(pole.id, pole.link))
    end
end

local function RestoreWeapons()
    local mem = charDb.swap
    if type(mem) ~= "table" or (not mem.mainID and not mem.offID) then
        Print("no weapons remembered: equip your weapons, then Shift + double right-click to take the pole out.")
        return
    end
    local back, missing = {}, {}
    local mainItem
    if mem.mainID then
        mainItem = FindInBags(mem.mainID, mem.mainLink)
        if mainItem then
            back[#back + 1] = ItemText(mainItem.id, mainItem.link)
        else
            missing[#missing + 1] = ItemText(mem.mainID, mem.mainLink)
        end
    end
    -- A two-hander in the main hand: there is no off hand to put back.
    local wantOff = mem.offID and not (mem.mainID and TwoHanded(mem.mainID))
    local offItem
    if wantOff then
        local onNow = SlotItem(OFF_SLOT)
        if onNow ~= mem.offID then
            offItem = FindInBags(mem.offID, mem.offLink)
            if offItem then
                back[#back + 1] = ItemText(offItem.id, offItem.link)
            else
                missing[#missing + 1] = ItemText(mem.offID, mem.offLink)
            end
        end
    end
    StopOffPending()
    if mainItem then Equip(mainItem, POLE_SLOT) end
    if offItem then
        if mainItem then
            -- Wait for the main hand to replace the pole, so the two swaps never race.
            offPending = { id = offItem.id, link = offItem.link, mainID = mainItem.id,
                deadline = Now() + OFFHAND_WAIT }
            if swapWatcher then swapWatcher:Show() end
        else
            Equip(offItem, OFF_SLOT)    -- no main hand to wait for; the pole comes off by itself
        end
    end
    if #back > 0 then Print("weapons back: " .. table.concat(back, ", ")) end
    if #missing > 0 then Print("not in your bags: " .. table.concat(missing, ", ")) end
end

-- The swap itself, for the gesture and /gfish swap alike.
local function DoSwap()
    if not db or not charDb then
        Print("not loaded yet.")
        return
    end
    if InCombat() then
        Print("can't swap weapons in combat")
        return
    end
    if Casting() then
        Print("stop fishing first")
        return
    end
    if not CursorEmpty() then
        Print("put down the item on the cursor first.")
        return
    end
    if not EquipPath() then
        Print("this client offers no way for an addon to equip items.")
        return
    end
    local ok, err = pcall(function()
        if PoleEquipped() then RestoreWeapons() else EquipPole() end
    end)
    if not ok then
        Fail("swap", err)
        Print("swap failed: " .. tostring(err))
    end
end

-- Called from the second press's hardware event (WorldFrame OnMouseDown or the secure button's
-- PreClick). One press may reach both hooks; it swaps once.
local function TrySwapGesture()
    local now = Now()
    if gestureAt and now - gestureAt <= Window() then return end
    gestureAt = now
    lastRightAt = nil
    DoSwap()
end

-- /gfish status: "remembered <links>" or "none".
local function SwapMemoryText()
    local mem = charDb and charDb.swap
    if type(mem) ~= "table" or (not mem.mainID and not mem.offID) then return "none" end
    local parts = {}
    if mem.mainID then parts[#parts + 1] = ItemText(mem.mainID, mem.mainLink) end
    if mem.offID then parts[#parts + 1] = ItemText(mem.offID, mem.offLink) end
    return "remembered " .. table.concat(parts, ", ")
end

local function OnActionBlocked(addon, func)
    if addon ~= ADDON_NAME then return end
    lastBlocked = tostring(func)
    Print("the client blocked " .. lastBlocked .. "; the swap could not equip. /gfish status has the details.")
end

local function CreateSwapFrames()
    if swapWatcher then return end
    swapWatcher = CreateFrame("Frame")
    swapWatcher:Hide()
    swapWatcher:SetScript("OnUpdate", OffPendingUpdate)
end

-- ---------------------------------------------------------------------------
-- Reel in (1.3): soft interact CVars, the line, and the "Cast / Reel" key.
-- See the header ("Reel in").
-- ---------------------------------------------------------------------------

local function ReelOn()
    return db ~= nil and db.reel ~= false
end

-- A CVar's value as a string, or nil when the client has no such CVar.
local function GetCVarValue(name)
    local c = _G.C_CVar
    local get = (type(c) == "table" and type(c.GetCVar) == "function" and c.GetCVar)
        or (type(_G.GetCVar) == "function" and _G.GetCVar)
    if not get then return nil end
    local ok, v = pcall(get, name)
    if not ok or Secret(v) then return nil end
    if type(v) == "number" then return tostring(v) end
    return Str(v)
end

local function SetCVarValue(name, value)
    local c = _G.C_CVar
    local set = (type(c) == "table" and type(c.SetCVar) == "function" and c.SetCVar)
        or (type(_G.SetCVar) == "function" and _G.SetCVar)
    if not set then return false end
    local ok, err = pcall(set, name, tostring(value))
    if not ok then Fail("setting " .. name, err) end
    return ok
end

-- The client has the INTERACTTARGET binding and the SoftTargetInteract CVar. Checked once.
local function ReelSupported()
    if reelSupport ~= nil then return reelSupport end
    local ok = GetCVarValue("SoftTargetInteract") ~= nil and type(_G.SetOverrideBinding) == "function"
    if ok then
        local kb = _G.C_KeyBindings
        if type(kb) == "table" and type(kb.GetBindingIndex) == "function" then
            local fine, index = pcall(kb.GetBindingIndex, "INTERACTTARGET")
            ok = fine and Num(index) ~= nil
        else
            local pim = _G.C_PlayerInteractionManager
            ok = type(pim) == "table" and type(pim.InteractUnit) == "function"
        end
    end
    reelSupport = ok and true or false
    return reelSupport
end

-- Puts back every CVar kept in db[key]. False when it has to wait for combat to end.
local function ReleaseHeld(key)
    if not db or type(db[key]) ~= "table" then return true end
    if InCombat() then return false end
    for name, value in pairs(db[key]) do SetCVarValue(name, value) end
    db[key] = nil
    return true
end

-- Sets each CVar of list that is not already enough, keeping the value before in db[key].
-- Out of combat only.
local function HoldList(list, key)
    if not db or InCombat() then return end
    local held = type(db[key]) == "table" and db[key] or {}
    for _, c in ipairs(list) do
        if held[c.name] == nil then
            local cur = GetCVarValue(c.name)
            local n = cur and Num(tonumber(cur))
            if n and not c.enough(n) and SetCVarValue(c.name, c.want) then held[c.name] = cur end
        end
    end
    db[key] = next(held) ~= nil and held or nil
end

-- Puts back every CVar changed for reeling; in combat it waits for PLAYER_REGEN_ENABLED.
local function ReleaseCVars()
    releasePending = not ReleaseHeld("held")
end

-- Sets what soft interact needs to target the bobber, keeping the value before. Out of combat.
local function HoldCVars()
    HoldList(REEL_CVARS, "held")
end

-- Loud splash (1.4): the same for the sound CVars. See the header ("Loud splash").
local function SplashOn()
    return db ~= nil and db.splash == true
end

local function ReleaseSplash()
    splashPending = not ReleaseHeld("splashHeld")
end

local function StartSplash()
    if lineOut and SplashOn() and not InCombat() then HoldList(SPLASH_CVARS, "splashHeld") end
end

-- The "Cast / Reel" key: while the line is out, the keys bound to it interact instead.
local function ClearKeyReel()
    if not keyOwner or type(_G.ClearOverrideBindings) ~= "function" then return end
    if InCombat() then
        bindingStuck = true         -- PLAYER_REGEN_ENABLED clears it
        return
    end
    local ok, err = pcall(_G.ClearOverrideBindings, keyOwner)
    if not ok then Fail("clearing the key", err) end
end

local function BindKeyReel()
    if not keyOwner or InCombat() or type(_G.GetBindingKey) ~= "function" then return end
    local ok, err = pcall(function()
        local keys = { _G.GetBindingKey(KEY_BINDING) }
        for i = 1, 2 do
            local key = Str(keys[i])
            if key then _G.SetOverrideBinding(keyOwner, true, key, "INTERACTTARGET") end
        end
    end)
    if not ok then Fail("binding the key to reel", err) end
end

local function KeyText()
    if type(_G.GetBindingKey) ~= "function" then return "not bound" end
    local ok, k1, k2 = pcall(_G.GetBindingKey, KEY_BINDING)
    k1, k2 = ok and Str(k1) or nil, ok and Str(k2) or nil
    if not k1 and not k2 then return "not bound" end
    return (k1 or "") .. ((k1 and k2) and ", " or "") .. (k2 or "")
end

local function IsFishingSpell(spellID)
    local id = Num(spellID)
    if not id then return false end
    for _, f in ipairs(FISHING_IDS) do
        if f == id then return true end
    end
    local name = SpellName(id)
    return name ~= nil and type(spellValue) == "string" and name == spellValue
end

-- Line out: hold the CVars and point the key at INTERACTTARGET. Out of combat only.
local function StartReel()
    if not lineOut or not ReelOn() or InCombat() then return end
    if not ReelSupported() then
        if not reelNoticeShown then
            reelNoticeShown = true
            Print("reeling in with a double right-click or the key is not supported on this client"
                .. " (no Interact With Target / soft interact); a double right-click casts again as before.")
        end
        return
    end
    HoldCVars()
    BindKeyReel()
    if db and not db.reelHint then
        db.reelHint = true
        Print("line out: double right-click anywhere reels in (no need to hit the bobber). /gfish reel off switches it off.")
    end
end

local function StopReel()
    ClearKeyReel()
    ReleaseCVars()
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
    state, downAt, armedAt, held, fired, armedReel = "idle", nil, nil, nil, nil, nil
    StopWatching()
end

-- Reel in: the line is out and the client can (never on the fallback path, which needs the
-- release; INTERACTTARGET acts on the press).
local function ReelReady()
    return lineOut and ReelOn() and HasReleaseCheck() and ReelSupported()
end

-- Binds BUTTON2 to the secure button, registered for the one click direction the CVar acts on;
-- while the line is out, to INTERACTTARGET instead (reel in).
local function Arm(direction)
    if InCombat() or not button or not owner then return false end
    local reel = ReelReady() and true or false
    if not reel and type(_G.SetOverrideBindingClick) ~= "function" then return false end
    local ok, err = pcall(function()
        if reel then
            _G.SetOverrideBinding(owner, true, "BUTTON2", "INTERACTTARGET")
        else
            button:RegisterForClicks(direction)
            _G.SetOverrideBindingClick(owner, true, "BUTTON2", BUTTON_NAME)
        end
    end)
    if not ok then
        Fail("arming the binding", err)
        return false
    end
    state, armedAt, held, fired, armedReel = "armed", Now(), false, false, reel
    StartWatching()
    return true
end

-- The channel ended while armed for reeling, before the second press: arm the cast instead.
local function RearmAsCast()
    if state == "armed" and armedReel and not held and not InCombat() then
        Arm(UseKeyDown() and "AnyDown" or "AnyUp")
    end
end

local function OnChannelStart(unit, spellID)
    if Str(unit) ~= "player" or not IsFishingSpell(spellID) then return end
    lineOut = true
    StartReel()
    StartSplash()
    if ns.stats then ns.stats.OnCast() end
end

local function OnChannelStop(unit)
    if Str(unit) ~= "player" then return end
    local wasOut = lineOut
    lineOut = false
    StopReel()
    ReleaseSplash()
    RearmAsCast()
    if wasOut and ns.stats then ns.stats.OnChannelStop() end
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
                -- Shift held at the release: a pole swap may follow, so never arm (pole swap).
                if CanFish() and not ShiftDown() then
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
            -- Pole swap: Shift pressed before the second press. Clear the binding now, so that
            -- press reaches WorldFrame and swaps instead of casting.
            if not held and ShiftDown() then
                Disarm()
                return
            end
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
        local now = Now()
        -- Pole swap: Shift held and within the window of the previous right press.
        local shift = ShiftDown()
        if shift and Enabled() and lastRightAt and now - lastRightAt <= Window() and CursorEmpty() then
            Disarm()                            -- never leave the Fishing binding behind
            lastPressAt = nil
            TrySwapGesture()
            return
        end
        if state == "armed" then                -- the binding has this press
            lastRightAt = nil                   -- it is the second click of a cast, not a first
            return
        end
        lastRightAt = now
        if shift or not CanFish() then          -- a Shift press never starts the Fishing sequence
            Disarm()
            lastPressAt = nil
            return
        end
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
    -- Pole swap: a Shift click resolves "shift-type*" first, an action type that does not exist,
    -- so it casts nothing; PreClick swaps instead (Shift and the second press in one frame).
    button:SetAttribute("shift-type*", "GaarFishingForeverNone")
    button:HookScript("PreClick", function()
        local ok, err = pcall(function()
            if state == "armed" and ShiftDown() then TrySwapGesture() end
        end)
        if not ok then Fail("PreClick", err) end
    end)
    button:HookScript("PostClick", function()
        if state == "armed" then fired = true end
    end)
    button:Show()

    -- The "Cast / Reel" key (1.3, Bindings.xml: CLICK BetterFishingForeverKeyButton:LeftButton).
    -- It casts Fishing on the press (useOnKeyDown, whatever ActionButtonUseKeyDown says), and the
    -- release does nothing, so a release after the binding moved to INTERACTTARGET and back never
    -- casts. While the line is out its keys are overridden to INTERACTTARGET (StartReel).
    keyOwner = CreateFrame("Frame", nil, _G.UIParent)
    keyButton = CreateFrame("Button", KEY_BUTTON_NAME, _G.UIParent, "SecureActionButtonTemplate")
    keyButton:SetSize(1, 1)
    keyButton:SetPoint("LEFT", _G.UIParent, "RIGHT", 10000, 0)
    keyButton:RegisterForClicks("AnyDown")
    keyButton:SetAttribute("useOnKeyDown", true)
    keyButton:SetAttribute("type", "spell")
    keyButton:Show()

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

local function SetReel(on, quiet)
    db.reel = on and true or false
    if on then StartReel() else StopReel() end
    if not quiet then
        Print(on and "reel on: while the line is out, double right-click anywhere (or the Cast / Reel key) reels in."
            or "reel off: double right-click casts again while the line is out, as before 1.3.")
    end
end

local function SetSplash(on, quiet)
    db.splash = on and true or false
    if on then StartSplash() else ReleaseSplash() end
    if not quiet then
        Print(on and "loud splash on: while the line is out, sound effects go to full volume and music and ambience to 0, so the splash is easy to hear; put back when the line comes in."
            or "loud splash off.")
    end
end

local function SetWindow(v, quiet)
    db.dblClick = Clamp(math.floor(v * 100 + 0.5) / 100, MIN_WINDOW, MAX_WINDOW)
    if not quiet then Print(string.format("double-click window: %.2f s.", db.dblClick)) end
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function YesNo(v) return v and "yes" or "no" end

-- The intro GaarForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "Double right-click in the world casts Fishing while a fishing pole is equipped, and while the line is out the same double right-click anywhere reels in: no need to hit the bobber. A single right-click still loots and interacts as usual. Bind one key to Cast / Reel (Keybindings, GaarFishingForever) to do both from the keyboard. A small session panel counts casts, catches, catches per hour, skill gained and what you fished up. Loud splash (off by default) turns sound effects up and music and ambience down while the line is out, so you hear the bite, and puts them back after. An optional Fishing 1-300 route pins the next spot on the map, with GaarGpsForever's arrow. Nice to know: Shift + double right-click swaps the pole in or out; nothing is armed in combat or while the cursor holds an item."

local function PrintHelp()
    Print(INTRO)
    Print("/gfish on | /gfish off - switch it on or off")
    Print(string.format("/gfish window <%.1f-%.1f> - seconds between the two right-clicks (now %.2f)",
        MIN_WINDOW, MAX_WINDOW, Window()))
    Print("/gfish reel on | off - while the line is out, double right-click anywhere reels in (now "
        .. (ReelOn() and "on" or "off") .. ")")
    Print("Cast / Reel key: Esc > Options > Keybindings > GaarFishingForever. One key casts, and reels in while the line is out (now "
        .. KeyText() .. ").")
    Print("Shift + double right-click in the world, or /gfish swap: swap the fishing pole in or out (out of combat).")
    Print("/gfish splash on | off - loud splash: while the line is out, sound effects up and music and ambience down, put back after (now "
        .. (SplashOn() and "on" or "off") .. ")")
    if ns.stats then
        for _, line in ipairs(ns.stats.HelpLines()) do Print(line) end
    end
    if ns.guide then
        for _, line in ipairs(ns.guide.HelpLines()) do Print(line) end
    end
    Print("/gfish status - the current state and what this client offers")
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
    local cvars = {}
    for _, c in ipairs(REEL_CVARS) do
        local v = GetCVarValue(c.name)
        if v then cvars[#cvars + 1] = c.name .. " " .. v end
    end
    local heldText = {}
    if type(db.held) == "table" then
        for name, v in pairs(db.held) do heldText[#heldText + 1] = name .. " " .. tostring(v) end
    end
    Print("reel: " .. (ReelOn() and "on" or "off") .. "   supported: " .. YesNo(ReelSupported())
        .. "   line out: " .. YesNo(lineOut) .. "   armed to reel: " .. YesNo(state == "armed" and armedReel)
        .. "   Cast / Reel key: " .. KeyText())
    Print("soft interact: " .. (#cvars > 0 and table.concat(cvars, ", ") or "none on this client")
        .. "   held (to put back): " .. (#heldText > 0 and table.concat(heldText, ", ") or "none")
        .. (releasePending and " (after combat)" or ""))
    local splashText = {}
    if type(db.splashHeld) == "table" then
        for name, v in pairs(db.splashHeld) do splashText[#splashText + 1] = name .. " " .. tostring(v) end
    end
    Print("loud splash: " .. (SplashOn() and "on" or "off") .. "   held (to put back): "
        .. (#splashText > 0 and table.concat(splashText, ", ") or "none") .. (splashPending and " (after combat)" or "")
        .. "   bite signal: none on this client (the splash is the alert)")
    if ns.stats then
        for _, line in ipairs(ns.stats.StatusLines()) do Print(line) end
    end
    Print("swap: " .. SwapMemoryText() .. "   equip path: " .. (EquipPath() or "none on this client")
        .. (lastBlocked and ("   blocked: " .. lastBlocked) or ""))
    if ns.guide then
        for _, line in ipairs(ns.guide.StatusLines()) do Print(line) end
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
            Print(string.format("/gfish window <%.1f-%.1f>, e.g. /gfish window 0.4 (now %.2f).", MIN_WINDOW, MAX_WINDOW, Window()))
        else
            SetWindow(v)
        end
    elseif cmd == "reel" then
        local a = (arg or ""):lower()
        if a == "on" or a == "off" then
            SetReel(a == "on")
        else
            Print("/gfish reel on | off - reel in with a double right-click while the line is out (now "
                .. (ReelOn() and "on" or "off") .. ").")
        end
    elseif cmd == "splash" then
        local a = (arg or ""):lower()
        if a == "on" or a == "off" then
            SetSplash(a == "on")
        else
            Print("/gfish splash on | off - loud splash while the line is out (now " .. (SplashOn() and "on" or "off") .. ").")
        end
    elseif cmd == "stats" and ns.stats then
        ns.stats.Slash(arg)
    elseif cmd == "status" then
        PrintStatus()
    elseif cmd == "swap" then
        DoSwap()
    elseif cmd == "route" and ns.guide then
        ns.guide.Slash(arg)
    else
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: GaarFishingForeverAPI
--
-- For GaarForever, the family hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in GaarFishingForeverDB and change only through the
-- same functions /gfish uses, so the addon behaves the same with or without the hub.
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

-- For Stats.lua (loaded before this file, so it asks at run time).
ns.core = { PoleEquipped = PoleEquipped }

local function StatusLine()
    if not db then return "not loaded yet" end
    return (Enabled() and "on" or "off") .. DOT .. string.format("%.2f s", Window())
        .. DOT .. (PoleEquipped() and "pole equipped" or "no pole")
        .. (spellValue == nil and (DOT .. "Fishing not known") or "")
        .. (ns.guide and ns.guide.StatusText() and (DOT .. ns.guide.StatusText()) or "")
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
        { text = "Double right-click reels in", checkbox = true,
          checked = function() return ReelOn() end,
          func = function() SetReel(not ReelOn()) end },
        { text = "Double-click window", submenu = windows },
        { text = "Loud splash while fishing", checkbox = true,
          checked = function() return SplashOn() end,
          func = function() SetSplash(not SplashOn()) end },
        ns.stats and { text = "Session stats panel", checkbox = true,
          checked = function() return ns.stats.IsOn() end,
          func = function() ns.stats.SetOn(not ns.stats.IsOn()) end } or nil,
        ns.stats and { text = "Reset session stats", func = function() ns.stats.Reset() end } or nil,
        ns.guide and { text = "Fishing route", checkbox = true,
          checked = function() return ns.guide.IsOn() end,
          func = function() ns.guide.SetOn(not ns.guide.IsOn()) end } or nil,
    }
end

_G.GaarFishingForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries(), A.title) end,
    SetMinimapHidden = function() end,
}
_G.BetterFishingForeverAPI = _G.GaarFishingForeverAPI -- the name before the folder rename

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    BF.Migrate("GaarFishingForeverDB", "BetterFishingForeverDB") -- the old folder's settings, once (see Lib.lua)
    if type(GaarFishingForeverDB) ~= "table" then GaarFishingForeverDB = {} end
    db = GaarFishingForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    if type(db.enabled) ~= "boolean" then db.enabled = true end
    local w = Num(tonumber(db.dblClick))
    db.dblClick = w and Clamp(w, MIN_WINDOW, MAX_WINDOW) or DEFAULT_WINDOW
    if type(db.reel) ~= "boolean" then db.reel = true end
    if db.reelHint ~= true then db.reelHint = nil end
    -- held: only CVars this addon changes, name = the previous value as a string.
    if type(db.held) == "table" then
        local clean = {}
        for name, v in pairs(db.held) do
            if REEL_CVAR_KNOWN[name] and (type(v) == "string" or type(v) == "number") then
                clean[name] = tostring(v)
            end
        end
        db.held = next(clean) ~= nil and clean or nil
    else
        db.held = nil
    end
    if type(db.splash) ~= "boolean" then db.splash = false end
    if type(db.splashHeld) == "table" then
        local clean = {}
        for name, v in pairs(db.splashHeld) do
            if SPLASH_CVAR_KNOWN[name] and (type(v) == "string" or type(v) == "number") then
                clean[name] = tostring(v)
            end
        end
        db.splashHeld = next(clean) ~= nil and clean or nil
    else
        db.splashHeld = nil
    end

    -- Per character: the pole swap's memory, { mainID, mainLink, offID, offLink }, and the
    -- route's state (route = { on, skipped, manual, manualAuto, pointed, wp }, see RouteGuide.lua).
    BF.Migrate("GaarFishingForeverCharDB", "BetterFishingForeverCharDB") -- the old folder's settings, once (see Lib.lua)
    if type(GaarFishingForeverCharDB) ~= "table" then GaarFishingForeverCharDB = {} end
    charDb = GaarFishingForeverCharDB
    for k in pairs(charDb) do
        if k ~= "swap" and k ~= "route" and k ~= "session" then charDb[k] = nil end
    end
    if ns.guide then ns.guide.Bind(charDb) else charDb.route = nil end
    if ns.stats then ns.stats.Bind(db, charDb) else charDb.session = nil end
    local m = charDb.swap
    if type(m) == "table" then
        charDb.swap = { mainID = Num(m.mainID), mainLink = Str(m.mainLink),
            offID = Num(m.offID), offLink = Str(m.offLink) }
    else
        charDb.swap = nil
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("SPELLS_CHANGED")
-- Gone from retail 11.0; registering an event the client does not know raises an error.
pcall(events.RegisterEvent, events, "LEARNED_SPELL_IN_TAB")
-- Reel in: the Fishing channel, the pole coming off, and the logout.
if type(events.RegisterUnitEvent) == "function" then
    pcall(events.RegisterUnitEvent, events, "UNIT_SPELLCAST_CHANNEL_START", "player")
    pcall(events.RegisterUnitEvent, events, "UNIT_SPELLCAST_CHANNEL_STOP", "player")
else
    pcall(events.RegisterEvent, events, "UNIT_SPELLCAST_CHANNEL_START")
    pcall(events.RegisterEvent, events, "UNIT_SPELLCAST_CHANNEL_STOP")
end
pcall(events.RegisterEvent, events, "PLAYER_EQUIPMENT_CHANGED")
events:RegisterEvent("PLAYER_LOGOUT")
-- Pole swap: tells us if the client ever blocks an equip call from this addon.
pcall(events.RegisterEvent, events, "ADDON_ACTION_BLOCKED")
pcall(events.RegisterEvent, events, "ADDON_ACTION_FORBIDDEN")
events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    local ok, err = pcall(function()
        if event == "UNIT_SPELLCAST_CHANNEL_START" then
            OnChannelStart(arg1, arg3)          -- unit, castGUID, spellID
        elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
            OnChannelStop(arg1)
        elseif event == "PLAYER_EQUIPMENT_CHANGED" then
            if Num(arg1) == POLE_SLOT and not PoleEquipped() then
                StopReel()
                ReleaseSplash()
            end
        elseif event == "PLAYER_LOGOUT" then
            if not InCombat() then              -- else the next login puts them back
                ReleaseCVars()
                ReleaseSplash()
            end
        elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
            OnActionBlocked(arg1, arg2)
        elseif event == "ADDON_LOADED" then
            if arg1 == ADDON_NAME then BindSavedVariables() end
        elseif event == "PLAYER_LOGIN" then
            CreateSwapFrames()          -- a plain frame: fine in combat
            ReleaseCVars()              -- whatever a crash or a disconnect left held
            ReleaseSplash()
            if InCombat() then
                setupPending = true     -- a secure button cannot be set up in combat
            else
                CreateFrames()
                ApplySpell()
            end
        elseif event == "PLAYER_REGEN_DISABLED" then
            -- Fires just before combat locks bindings: clear the override while that still works,
            -- and put the soft interact CVars back (reeling waits for combat to end).
            Disarm()
            StopReel()
            ReleaseSplash()
        elseif event == "PLAYER_REGEN_ENABLED" then
            if setupPending then
                setupPending = false
                CreateFrames()
                ApplySpell()
            elseif spellPending then
                ApplySpell()
            end
            if bindingStuck then
                ClearBinding()
                ClearKeyReel()
            end
            if releasePending then ReleaseCVars() end
            if splashPending then ReleaseSplash() end
            StartReel()                 -- the line is still out: reel again
            StartSplash()
        else
            ApplySpell()        -- SPELLS_CHANGED, LEARNED_SPELL_IN_TAB
        end
    end)
    if not ok then Fail(event, err) end
end)

SLASH_GAARFISHINGFOREVER1 = "/gfish"
SLASH_GAARFISHINGFOREVER2 = "/gaarfishingforever"
SLASH_GAARFISHINGFOREVER3 = "/bfish" -- the command before the Gaar rename
SLASH_GAARFISHINGFOREVER4 = "/betterfishingforever"
SlashCmdList.GAARFISHINGFOREVER = OnSlash
