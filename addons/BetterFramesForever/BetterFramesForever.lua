--[[
  BetterFramesForever - X-Perl-style unit frames of its own on WoW Forever.

  Standalone, no options panel, no minimap button: a slash command and a small API for
  BetterGaarForever's hub. It builds its own frames, the way X-Perl and oUF do, and hides
  Blizzard's:

    * Frames for the player, target, target of target, focus (where the client has a focus
      unit), pet and party1-4. No raid frames, no XP bar.
    * X-Perl layout: a name bar on top (name, level, class icon for players, Elite / Rare /
      Boss for NPCs), the portrait on the left (2D by default, 3D model as an option), health
      and power bars on the right with "cur/max  NN%" text, all on a dark see-through backdrop
      with a thin border. The party frames are a compact version of the same.
    * Colours: class colour for players, reaction colour for NPCs, grey when someone else tagged
      the mob; orange under 35% and red under 20% health (option). Power bar by power type.
      Every bar is a soft vertical gradient in its colour, from a richer, softer palette, and the
      health bar has a thin dark border with a faint shadow (1.2.8).
    * Target: combo points (rogues and druids), a row of buffs and one of debuffs (up to 16
      each; your own debuffs larger, the rest smaller and greyed), a gold border for elites and
      bosses, silver for rares.
    * Player: your own buffs in rows under the frame (up to 20, two rows of 10, with the
      remaining-time swipe; option, on by default).
    * Party: small buffs and debuffs, faded to 50% when out of range.
    * Every aura icon: a small time-left number at its top and a swipe that starts bright and
      darkens as the aura runs out (1.2.1).
    * Icons: raid target, group leader, combat and resting (player); a threat border.
    * Move: drag a frame while unlocked (out of combat), scale per frame (0.6-1.5), lock,
      reset, and a test mode that shows every enabled frame with made-up data (party without a
      group) so they can be placed.
    * Follow Blizzard Edit Mode (option, off by default): player, target, focus and party sit
      where Blizzard's own frames are placed in Edit Mode; pet and target of target keep their
      offset from player and target. While Edit Mode is open Blizzard's frames are given back
      so they can be dragged, and ours go see-through. Own positions are kept for when it is off.
    * /bff (or /betterframesforever) for help, status, lock, unlock, test, reset, scale, frame,
      editmode, portrait, text, lowhp, classcolor and playerbuffs.
    * BetterFramesForeverAPI, a small global table for BetterGaarForever's hub menu (version,
      StatusLine, MenuEntries, AddMenuEntries, SetMinimapHidden).

  Why its own frames. GaarFrames restyles Blizzard's unit frames in place and turns itself off on
  Forever, because writing to them taints them, and once the client hands out secret values
  Blizzard's own code inside a tainted frame can no longer compare them. So this addon never
  writes to Blizzard's unit frames: they are switched off the way oUF's DisableBlizzard does it
  (UnregisterAllEvents, Hide, re-parented to a hidden frame of our own), out of combat only, and
  frames of our own take their place.

  The frames are SecureUnitButtonTemplate buttons: unit, type1 = "target" and type2 =
  "togglemenu" (Blizzard's unit menu) are set once, at creation, out of combat, and
  RegisterUnitWatch shows and hides them. Every change to a secure frame (create, show, hide,
  move, scale, unit watch) happens only out of combat; asked for in combat, it is queued until
  PLAYER_REGEN_ENABLED. In combat the addon only paints: bars, text, icons, alpha.

  Secret values: the bars get the raw values (a StatusBar takes a secret), nothing is worked
  out from a secret, and every comparison or boolean test is made on a value checked first.
  The "cur/max  NN%" text is written from plain numbers; where they are secret the client's
  own secret-safe helpers are used if it has them (AbbreviateLargeNumbers, UnitHealthPercent with
  CurveConstants.ScaleTo100, SetFormattedText), otherwise the text is left empty and the bar
  alone shows the value. Every feature of a frame's update runs in pcall: the first refusal
  switches that feature off for the session, with one line in chat.
]]

local _G = _G
local ADDON_NAME = ... or "BetterFramesForever"
local PREFIX = "|cff33ff99BetterFramesForever|r: "
local DOT = " \194\183 "

local VERSION = "1.2.8"

local FLAT = "Interface\\Buttons\\WHITE8x8"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local CLASS_ICONS = "Interface\\TargetingFrame\\UI-Classes-Circles"
local RAID_ICONS = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local LEADER_ICON = "Interface\\GroupFrame\\UI-Group-LeaderIcon"
local STATE_ICON = "Interface\\CharacterFrame\\UI-StateIcon"

local PAD = 3                -- inside the backdrop
local PARTY_GAP = 52         -- room under each party frame for its aura rows and their time text
local OUT_OF_RANGE = 0.5     -- party alpha out of range
local TICK = 0.2             -- seconds between target-of-target and range updates
local MIN_SCALE, MAX_SCALE = 0.6, 1.5
local LOW_HP, CRIT_HP = 0.35, 0.20

-- The frames, in the order of the menu, the status and the help.
local KEYS = { "player", "target", "tot", "focus", "pet", "party" }
local LABEL = { player = "Player", target = "Target", tot = "Target of target", focus = "Focus",
    pet = "Pet", party = "Party" }
local UNITS_OF = {
    player = { "player" }, target = { "target" }, tot = { "targettarget" }, focus = { "focus" },
    pet = { "pet" }, party = { "party1", "party2", "party3", "party4" },
}
local KEY_OF = {}
for k, list in pairs(UNITS_OF) do for _, u in ipairs(list) do KEY_OF[u] = k end end
local KEY_ALIASES = { targettarget = "tot", targetoftarget = "tot", tot = "tot" }

-- Size of each kind of frame. name = name bar height, hp / mp = bar heights.
local LAYOUT = {
    player = { w = 236, name = 16, hp = 24, mp = 12, portrait = true, powerText = true, reserve = 60 },
    target = { w = 236, name = 16, hp = 24, mp = 12, portrait = true, powerText = true, reserve = 72 },
    focus  = { w = 200, name = 14, hp = 18, mp = 8, portrait = true, reserve = 60 },
    tot    = { w = 140, name = 13, hp = 14, mp = 6, portrait = false, compact = true, reserve = 26 },
    pet    = { w = 160, name = 13, hp = 14, mp = 7, portrait = true, compact = true, reserve = 26 },
    party  = { w = 180, name = 14, hp = 18, mp = 8, portrait = true, compact = true, reserve = 30 },
}

-- Auras: which rows a frame has. Target: buffs then debuffs, your own debuffs larger. Player:
-- your own buffs (option playerBuffs), up to 20 in two rows of 10 under the frame.
local AURAS = {
    player = { { filter = "HELPFUL", max = 20, size = 20 } },
    target = { { filter = "HELPFUL", max = 16, size = 18 },
               { filter = "HARMFUL", max = 16, size = 18, own = 24 } },
    party  = { { filter = "HARMFUL", max = 8, size = 14 },
               { filter = "HELPFUL", max = 8, size = 12 } },
}

-- Default place of each frame's top-left corner, in UIParent units from UIParent's top-left.
local DEFAULT_POS = {
    player = { 20, -40 }, target = { 276, -40 }, tot = { 520, -40 }, focus = { 520, -100 },
    -- pet under the player's two buff rows and their time text (1.2.2: was -152 / -210)
    pet = { 20, -176 }, party = { 20, -234 },
}

-- Blizzard's frames each of ours replaces (feature-detected; missing names are skipped).
-- CompactPartyFrame (raid-style party frames) is deliberately left alone.
local BLIZZARD = {
    player = { "PlayerFrame" },
    target = { "TargetFrame", "ComboFrame" },
    tot    = { "TargetFrameToT" },
    focus  = { "FocusFrame", "FocusFrameToT", "TargetofFocusFrame" },
    pet    = { "PetFrame" },
}

-- Follow Blizzard Edit Mode: the Blizzard frame whose place each of ours copies, and the frames
-- with no Edit Mode system of their own, which keep their offset from the frame they hang off.
local FOLLOW_SOURCE = { player = "PlayerFrame", target = "TargetFrame", focus = "FocusFrame", party = "PartyFrame" }
local FOLLOW_PARENT = { pet = "player", tot = "target" }
local FOLLOW_CHILD = { player = "pet", target = "tot" }

local CONFLICTS = { "GaarFrames", "XPerl", "XPerl_Player", "ShadowedUnitFrames", "PitBull4" }

-- The palette (1.2.8): deeper, slightly less saturated tones made for the bar gradient. Class
-- colours are used as the client gives them.
local Look = {   -- the palette, and SetBarColor and Edge below
    HOSTILE = { 0.78, 0.25, 0.22 },
    NEUTRAL = { 0.85, 0.72, 0.25 },
    FRIENDLY = { 0.30, 0.68, 0.32 },   -- friendly NPCs, and players without class colour
    TAPPED = { 0.52, 0.52, 0.55 },     -- tagged by someone else; offline too
    DEAD = { 0.40, 0.40, 0.42 },
    LOW = { 0.92, 0.55, 0.18 },        -- under 35% health
    CRIT = { 0.90, 0.16, 0.14 },       -- under 20% health
}
local POWER_COLORS = {
    MANA = { 0.24, 0.44, 0.88 }, RAGE = { 0.80, 0.22, 0.20 }, FOCUS = { 0.90, 0.52, 0.26 },
    ENERGY = { 0.92, 0.78, 0.22 }, RUNIC_POWER = { 0.18, 0.72, 0.90 },
}
local THREAT_COLORS = { { 1.0, 1.0, 0.47 }, { 1.0, 0.6, 0.0 }, { 1.0, 0.0, 0.0 } }
local BORDER = { 0.3, 0.3, 0.35 }
local BORDER_ELITE = { 1.0, 0.82, 0.2 }
local BORDER_RARE = { 0.8, 0.82, 0.9 }
local BORDER_UNLOCKED = { 0.3, 0.6, 1.0 }
local TAGS = { worldboss = "Boss", rareelite = "Rare Elite", elite = "Elite", rare = "Rare" }
local ELITE_KIND = { worldboss = "elite", rareelite = "elite", elite = "elite", rare = "rare" }

local DEFAULTS = {
    locked = true,
    portrait = "2d",
    text = true,
    lowhp = true,
    classColor = true,
    followEditMode = false,
    playerBuffs = true,
    healPrediction = true,
    hotPred = true,
}
local DEFAULT_FRAMES = { player = true, target = true, tot = true, focus = true, pet = true, party = true }

-- Every key BetterFramesForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = {
    locked = true, portrait = true, text = true, lowhp = true, classColor = true, followEditMode = true,
    playerBuffs = true, healPrediction = true, hotPred = true, frames = true, scales = true, positions = true,
}

local db                    -- BetterFramesForeverDB, bound at ADDON_LOADED (never at file scope)
local real = {}             -- [unit] = our secure frame
local previews = {}         -- [unit] = non-secure preview frame for test mode
local enabledNow = {}       -- [key] = true while that key's frames are switched on
local blocked = {}          -- [feature] = error text, once this client refused it
local hiddenBlizz = {}      -- [Blizzard frame] = true when it is not re-parented (party members)
local hiddenNames = {}      -- names of Blizzard frames switched off, for /bff status
local pending, pendingOrder = {}, {}   -- changes waiting for the end of combat
local testing = false
local started = false
local unsupported           -- why this client cannot have secure frames, or nil
local comboClass            -- the player's class uses combo points
local hiddenParent          -- our own hidden frame Blizzard's frames are parked under
local conflictWarned, queueNoted
local origParent = {}       -- [Blizzard frame] = its parent before we parked it
local followPos = {}        -- [key] = { x, y }: top-left of Blizzard's frame, UIParent units from its bottom-left
local followMiss = {}       -- [key] = why Blizzard's frame gave no position at the last read
local restored = {}         -- [key] = Blizzard frame given back to Blizzard while Edit Mode is open
local editOpen = false      -- Edit Mode is open (from its Enter / Exit callbacks)
local editFaded = false     -- our followed frames are see-through for Edit Mode
local editHooked            -- how the Edit Mode callbacks were hooked, for /bff status
local editOwner = {}        -- owner handle for EventRegistry

-- Forward declarations: used by the frame scripts before they are defined.
local UpdateFrame, StartDrag, StopDrag, ApplyBorder

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function Print(msg)
    local chat = _G.DEFAULT_CHAT_FRAME
    if chat and chat.AddMessage then chat:AddMessage(PREFIX .. msg) end
end

local function OnOff(v) return v and "on" or "off" end

-- Where the client hides a value it hands back a secret: it may be passed to a widget, but
-- arithmetic, comparison, a boolean test and even "or" on it are refused. issecretvalue does not
-- exist on a client where nothing is secret, so the guard costs nothing there.
local issecretvalue = _G.issecretvalue
local function IsSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    return issecretvalue(v) and true or false
end

local function Secret(a, b)
    if IsSecret(a) then return true end
    return b ~= nil and IsSecret(b) or false
end

-- The value, or nil when it is secret: every later test on it is then an ordinary one.
local function Plain(v)
    if IsSecret(v) then return nil end
    return v
end

local function Num(v)
    v = Plain(v)
    if type(v) ~= "number" or v ~= v then return nil end
    return v
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- A secret string is passed on as it is; anything else gets "" for nil.
local function SetTextSafe(fs, v)
    if IsSecret(v) then fs:SetText(v) else fs:SetText(v or "") end
end

local function SetSolid(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
end

-- ---------------------------------------------------------------------------
-- Bar look (1.2.8): every bar colour (health, power, mana, heal prediction) goes through
-- SetBarColor, which paints the bar's white texture with a soft vertical gradient in that colour
-- - lifted toward white at the top, darker at the bottom - with Texture:SetGradient and two Color
-- objects cached on the bar, so an update allocates nothing. SetStatusBarColor would set one flat
-- vertex colour over the gradient, so it is used only where SetGradient or CreateColor is
-- missing. The last colour is cached on the bar and an unchanged colour is skipped; bar textures
-- are set once, when the bar is built, so nothing else repaints them.
-- ---------------------------------------------------------------------------

do
local GRAD_LIFT, GRAD_SHADE = 0.18, 0.22
local gradientOK = true

function Look.SetBarColor(bar, r, g, b, a)
    a = a or 1
    if bar.barR == r and bar.barG == g and bar.barB == b and bar.barA == a then return end
    bar.barR, bar.barG, bar.barB, bar.barA = r, g, b, a
    local tex = gradientOK and type(_G.CreateColor) == "function" and bar:GetStatusBarTexture()
    if tex and type(tex.SetGradient) == "function" then
        local top, bottom = bar.gradTop, bar.gradBottom
        if not top then
            top, bottom = _G.CreateColor(r, g, b, a), _G.CreateColor(r, g, b, a)
            bar.gradTop, bar.gradBottom = top, bottom
        end
        top:SetRGBA(r + (1 - r) * GRAD_LIFT, g + (1 - g) * GRAD_LIFT, b + (1 - b) * GRAD_LIFT, a)
        bottom:SetRGBA(r * (1 - GRAD_SHADE), g * (1 - GRAD_SHADE), b * (1 - GRAD_SHADE), a)
        if pcall(tex.SetGradient, tex, "VERTICAL", bottom, top) then return end
        gradientOK = false
    end
    bar:SetStatusBarColor(r, g, b, a)
end

-- A 1px ring k px outside box, black at alpha a: four textures, top and bottom spanning the
-- corners.
local function RingLines(f, box, k, a)
    local t = f:CreateTexture(nil, "BACKGROUND")
    t:SetPoint("TOPLEFT", box, "TOPLEFT", -k, k); t:SetPoint("TOPRIGHT", box, "TOPRIGHT", k, k)
    t:SetHeight(1); SetSolid(t, 0, 0, 0, a)
    t = f:CreateTexture(nil, "BACKGROUND")
    t:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", -k, -k); t:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", k, -k)
    t:SetHeight(1); SetSolid(t, 0, 0, 0, a)
    t = f:CreateTexture(nil, "BACKGROUND")
    t:SetPoint("TOPLEFT", box, "TOPLEFT", -k, k - 1); t:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", -k, 1 - k)
    t:SetWidth(1); SetSolid(t, 0, 0, 0, a)
    t = f:CreateTexture(nil, "BACKGROUND")
    t:SetPoint("TOPRIGHT", box, "TOPRIGHT", k, k - 1); t:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", k, 1 - k)
    t:SetWidth(1); SetSolid(t, 0, 0, 0, a)
end

-- A 1px near-black border round bar and a faint shadow fading out over 2 px outside it, on a
-- frame of its own at the given level (under the bars, which sit one level higher).
function Look.Edge(parent, bar, level)
    local f = CreateFrame("Frame", nil, parent)
    f:SetFrameLevel(level)
    f:SetAllPoints(bar)
    RingLines(f, bar, 1, 0.8)
    RingLines(f, bar, 2, 0.22)
    RingLines(f, bar, 3, 0.08)
    return f
end
end

local function InCombat()
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() and true or false
end

-- Following Blizzard's Edit Mode is on (and this client has not refused it this session).
local function FollowOn()
    return db ~= nil and db.followEditMode == true and not blocked.editmode
end

-- A key whose place comes from Edit Mode: its own Blizzard frame, or the frame it hangs off.
local function Followed(key)
    return FollowOn() and (FOLLOW_SOURCE[key] ~= nil or FOLLOW_PARENT[key] ~= nil)
end

local function EditModeActive()
    local em = _G.EditModeManagerFrame
    if type(em) ~= "table" or type(em.IsEditModeActive) ~= "function" then return false end
    local ok, active = pcall(em.IsEditModeActive, em)
    return ok and not IsSecret(active) and active and true or false
end

-- Whether an addon is loaded: C_AddOns on newer clients, the old global otherwise.
local function AddOnLoaded(name)
    local c = _G.C_AddOns
    if type(c) == "table" and type(c.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(c.IsAddOnLoaded, name)
        if ok and loaded then return true end
    end
    if type(_G.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(_G.IsAddOnLoaded, name)
        if ok and loaded then return true end
    end
    return false
end

local function LoadedConflicts()
    local list = {}
    for _, name in ipairs(CONFLICTS) do
        if AddOnLoaded(name) then list[#list + 1] = name end
    end
    return list
end

-- Whether the client has a focus unit: the event exists only where it does.
local HAS_FOCUS = (function()
    if type(_G.CreateFrame) ~= "function" then return false end
    local probe = CreateFrame("Frame")
    local ok = pcall(probe.RegisterEvent, probe, "PLAYER_FOCUS_CHANGED")
    if ok then pcall(probe.UnregisterAllEvents, probe) end
    return ok and true or false
end)()

local function HasKey(key)
    if key == "focus" then return HAS_FOCUS end
    return true
end

local function Short(n)
    if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if n >= 1e4 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end

local function ClassToken(unit)
    local _, cls = UnitClass(unit)
    cls = Plain(cls)
    if type(cls) == "string" then return cls end
end

local function ClassRGB(cls)
    local c = cls and type(_G.RAID_CLASS_COLORS) == "table" and _G.RAID_CLASS_COLORS[cls]
    if type(c) == "table" and type(c.r) == "number" then return c.r, c.g, c.b end
end

local function AllFrames()
    local list = {}
    for _, f in pairs(real) do list[#list + 1] = f end
    for _, f in pairs(previews) do list[#list + 1] = f end
    return list
end

-- ---------------------------------------------------------------------------
-- Combat queue: secure frames are only changed out of combat
-- ---------------------------------------------------------------------------

-- Runs fn now, or after combat when it touches a secure frame and combat is on. A later
-- request with the same id replaces the earlier one. Returns true when it ran now.
local function OutOfCombat(id, fn)
    if InCombat() then
        if not pending[id] then pendingOrder[#pendingOrder + 1] = id end
        pending[id] = fn
        if not queueNoted then
            queueNoted = true
            Print("in combat - frame changes are made when combat ends.")
        end
        return false
    end
    fn()
    return true
end

local function FlushQueue()
    local order, jobs = pendingOrder, pending
    pendingOrder, pending = {}, {}
    queueNoted = false
    for _, id in ipairs(order) do
        local fn = jobs[id]
        if fn then
            local ok, err = pcall(fn)
            if not ok then Print("a queued change failed: " .. tostring(err)) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The pcall latch: one refusal switches that feature off for the session, with one message.
-- ---------------------------------------------------------------------------

local FEATURE_LABELS = {
    health = "read health for unit frames",
    power = "read power for unit frames",
    name = "read names and levels for unit frames",
    portrait = "draw unit portraits",
    icons = "read raid, leader, combat and resting icons",
    threat = "read threat for unit frames",
    auras = "read auras for unit frames",
    range = "read party range",
    combo = "read combo points",
    secrettext = "write hidden health and power values as text",
    powerhide = "hide an empty power line from hidden values",
    healpred = "draw heal prediction and absorbs",
    mana = "show the player's mana under a form's power",
    blizzard = "switch Blizzard's unit frames off",
    frames = "build secure unit frames",
    editmode = "follow Blizzard's Edit Mode positions",
}

-- What each feature leaves behind once it is switched off.
local CLEAR = {
    auras = function(f)
        for _, icon in ipairs(f.auraIcons or {}) do icon:Hide() end
    end,
    threat = function(f) f.threatStatus = nil; ApplyBorder(f) end,
    range = function(f) if not f.preview and not testing and not editFaded then f:SetAlpha(1) end end,
    combo = function(f) for _, p in ipairs(f.combo or {}) do p:Hide() end end,
    powerhide = function(f) if f.power then f.power:SetAlpha(1) end end,
    healpred = function(f) for _, b in pairs(f.healPred or {}) do b:Hide() end end,
    mana = function(f)
        if not f.mana then return end
        f.mana:Hide()
        f.manaShown = false
        f.health:SetHeight(f.powerShown == false and (f.layout.hp + 1 + f.layout.mp) or f.layout.hp)
    end,
    icons = function(f)
        if f.raidIcon then f.raidIcon:Hide() end
        if f.leaderIcon then f.leaderIcon:Hide() end
        if f.stateIcon then f.stateIcon:Hide() end
    end,
}

local function Latch(feature, err)
    if blocked[feature] then return end
    blocked[feature] = tostring(err)
    local clear = CLEAR[feature]
    if clear then
        for _, f in ipairs(AllFrames()) do pcall(clear, f) end
    end
    Print("this client will not let an addon " .. (FEATURE_LABELS[feature] or feature)
        .. " - that part is off for this session. (" .. tostring(err) .. ")")
end

local function Run(feature, fn, a, b, c, d)
    if blocked[feature] then return end
    local ok, err = pcall(fn, a, b, c, d)
    if not ok then Latch(feature, err) end
end

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------

-- Our own palette by reaction (1.2.8; up to 1.2.7 Blizzard's FACTION_BAR_COLORS came first).
local function ReactionRGB(unit)
    local r = Num(UnitReaction(unit, "player"))
    local c = (not r or r == 4) and Look.NEUTRAL or (r < 4 and Look.HOSTILE) or Look.FRIENDLY
    return c[1], c[2], c[3]
end

-- pct is nil when the health is secret: then there is no low-health colour.
local function HealthRGB(unit, pct)
    if Plain(UnitIsConnected(unit)) == false then return Look.TAPPED[1], Look.TAPPED[2], Look.TAPPED[3] end
    if Plain(UnitIsDeadOrGhost(unit)) == true then return Look.DEAD[1], Look.DEAD[2], Look.DEAD[3] end
    local isPlayer = Plain(UnitIsPlayer(unit)) == true
    if not isPlayer and type(_G.UnitIsTapDenied) == "function" and Plain(UnitIsTapDenied(unit)) == true then
        return Look.TAPPED[1], Look.TAPPED[2], Look.TAPPED[3]
    end
    if db.lowhp and pct then
        if pct < CRIT_HP then return Look.CRIT[1], Look.CRIT[2], Look.CRIT[3] end
        if pct < LOW_HP then return Look.LOW[1], Look.LOW[2], Look.LOW[3] end
    end
    if isPlayer then
        if db.classColor then
            local r, g, b = ClassRGB(ClassToken(unit))
            if r then return r, g, b end
        end
        return Look.FRIENDLY[1], Look.FRIENDLY[2], Look.FRIENDLY[3]
    end
    return ReactionRGB(unit)
end

local function PowerRGB(token)
    local c = token and POWER_COLORS[token]
    if c then return c[1], c[2], c[3] end
    local pc = token and type(_G.PowerBarColor) == "table" and _G.PowerBarColor[token]
    if type(pc) == "table" and type(pc.r) == "number" then return pc.r, pc.g, pc.b end
    return 0.6, 0.6, 0.6
end

-- Level colour against the player's own level, as the default frames do it.
local function LevelRGB(lvl)
    local mine = Num(UnitLevel("player"))
    if not mine or lvl <= 0 then return 1, 0.1, 0.1 end
    local d = lvl - mine
    if d >= 5 then return 1, 0.1, 0.1 end
    if d >= 3 then return 1, 0.5, 0.25 end
    if d >= -2 then return 1, 0.82, 0 end
    if d >= -8 then return 0.25, 0.75, 0.25 end
    return 0.6, 0.6, 0.6
end

ApplyBorder = function(f)
    local c = BORDER
    if db and not db.locked and not f.followed then
        c = BORDER_UNLOCKED
    elseif f.eliteKind == "elite" then
        c = BORDER_ELITE
    elseif f.eliteKind == "rare" then
        c = BORDER_RARE
    end
    if f.SetBackdropBorderColor then f:SetBackdropBorderColor(c[1], c[2], c[3], 0.95) end
    local glow = f.glow
    if glow then
        local t = f.threatStatus and THREAT_COLORS[f.threatStatus]
        if t then
            if glow.SetBackdropBorderColor then glow:SetBackdropBorderColor(t[1], t[2], t[3], 1) end
            glow:Show()
        else
            glow:Hide()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Building a frame
-- ---------------------------------------------------------------------------

-- A Button with the given templates, trying without BackdropTemplate on a client that lacks it.
local function NewButton(name, secure)
    local templates = secure and { "SecureUnitButtonTemplate,BackdropTemplate", "SecureUnitButtonTemplate" }
        or { "BackdropTemplate", nil }
    local last
    for i = 1, 2 do
        local ok, f = pcall(CreateFrame, "Button", name, _G.UIParent, templates[i])
        if ok and f then
            -- A client without the template may still hand back a plain button: no use here.
            if secure and type(f.IsProtected) == "function" and not f:IsProtected() then
                error("SecureUnitButtonTemplate is missing")
            end
            return f
        end
        last = f
    end
    error(last or "CreateFrame failed")
end

-- A plain frame with BackdropTemplate where the client has it.
local function NewBackdropFrame(parent)
    local ok, f = pcall(CreateFrame, "Frame", nil, parent, "BackdropTemplate")
    if ok and f then return f end
    return CreateFrame("Frame", nil, parent)
end

local function SetBackdropLook(frame, bgAlpha, edge)
    if type(frame.SetBackdrop) ~= "function" then return end
    frame:SetBackdrop({ bgFile = bgAlpha and FLAT or nil, edgeFile = FLAT, edgeSize = edge or 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    if bgAlpha then frame:SetBackdropColor(0, 0, 0, bgAlpha) end
end

local function NewFont(parent, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(_G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, "OUTLINE")
    fs:SetTextColor(1, 1, 1)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    return fs
end

local function NewBar(parent, height, fontSize)
    local bar = CreateFrame("StatusBar", nil, parent)
    -- Plain white, coloured as a vertical gradient (Look.SetBarColor, 1.2.8); up to 1.2.7 this was
    -- Interface\TargetingFrame\UI-StatusBar with one flat colour.
    bar:SetStatusBarTexture(FLAT)
    bar:SetHeight(height)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    SetSolid(bg, 0, 0, 0, 0.5)
    bar.bg = bg
    if fontSize then
        bar.text = NewFont(bar, fontSize)
        bar.text:SetPoint("CENTER", bar, "CENTER", 0, 0)
    end
    return bar
end

local function AuraTooltip(icon)
    local tip = _G.GameTooltip
    if not tip or not icon.unit then return end
    pcall(function()
        tip:SetOwner(icon, "ANCHOR_BOTTOMRIGHT")
        local id = Plain(icon.auraInstanceID)
        if id and type(tip.SetUnitAuraByAuraInstanceID) == "function" then
            tip:SetUnitAuraByAuraInstanceID(icon.unit, id)
        elseif type(tip.SetUnitAura) == "function" then
            tip:SetUnitAura(icon.unit, icon.index, icon.filter)
        end
        tip:Show()
    end)
end

-- Aura timing (1.2.2): Blizzard's buff-frame look. The swipe runs reversed, as on Blizzard's own
-- aura buttons (reverse="true" in TargetFrameAuraButton.xml, PartyFrameTemplates.xml): bright when
-- the aura is fresh, darkening as it runs out. The time left sits UNDER the icon in Blizzard's
-- small gold font, as BuffFrame's AuraButton.Duration (GameFontNormalSmall, anchored TOP to the
-- icon's BOTTOM, white below BUFF_DURATION_WARNING_TIME) - but never with a seconds unit:
-- "45", "9m", "59m", "1h", "2d" (no space between number and unit, rounded up).
-- Icons under 18 px (party) get the same font at 8 px. The rows leave room for the text.
--
-- Where the client draws the icons (AuraContainer) the remaining time is secret in combat, so it is
-- formatted by the client: SetDurationText takes a NumericFormatter, and a NumericRuleFormatter
-- (C_StringUtil.CreateNumericRuleFormatter) with one breakpoint per unit gives exactly the text
-- above with no Lua arithmetic on the duration. The white-to-gold switch at 60 s is a step colour
-- curve on the remaining duration (C_CurveUtil.CreateColorCurve), also evaluated by the client.
local AuraTime = {}   -- FontSize, Below, GAP, NewText, Text, Tick, SetEnd, Size, Formatter, ColorOptions
do
local GOLD = { 1.0, 0.82, 0.0 }      -- NORMAL_FONT_COLOR
local WHITE = { 1.0, 1.0, 1.0 }      -- HIGHLIGHT_FONT_COLOR
local WARN = 60                      -- BUFF_DURATION_WARNING_TIME

AuraTime.GAP = 3   -- between icons in a row: the text under each is wider than a small icon

function AuraTime.FontSize(size)
    return (size or 0) >= 18 and 10 or 8
end

-- Room under a row of icons this size: its text and a pixel either side.
function AuraTime.Below(size)
    return AuraTime.FontSize(size) + 3
end

local function Color(fs, r, g, b) fs:SetTextColor(r, g, b) end

-- The time text under an icon, in GameFontNormalSmall where the client has it.
function AuraTime.NewText(icon, size)
    local fs
    if _G.GameFontNormalSmall then
        fs = icon:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    else
        fs = icon:CreateFontString(nil, "OVERLAY")
        fs:SetFont(_G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "")
        if fs.SetShadowOffset then fs:SetShadowOffset(1, -1) end
    end
    local file, _, flags = fs:GetFont()
    if file then fs:SetFont(file, AuraTime.FontSize(size), flags or "") end
    Color(fs, GOLD[1], GOLD[2], GOLD[3])
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    fs:SetPoint("TOP", icon, "BOTTOM", 0, -1)
    return fs
end

-- "45", "9m", "2h", "3d" from a plain number of seconds - rounded up, so 0 never shows while
-- the aura is still on.
function AuraTime.Text(left)
    if type(left) ~= "number" or left ~= left or left <= 0 then return "" end
    local s = math.ceil(left)
    if s < 60 then return tostring(s) end
    if s < 3600 then return math.ceil(s / 60) .. "m" end
    if s < 86400 then return math.ceil(s / 3600) .. "h" end
    return math.ceil(s / 86400) .. "d"
end

-- Our own icons count down from a plain end time (icon.timeEnd, nil while the timing is hidden).
function AuraTime.Tick(icon, elapsed)
    icon.timeWait = (icon.timeWait or 0) - (elapsed or 0)
    if icon.timeWait > 0 then return end
    icon.timeWait = 0.2
    local fin = icon.timeEnd
    local now = type(_G.GetTime) == "function" and _G.GetTime() or nil
    local left = (fin and now) and (fin - now) or nil
    icon.time:SetText(AuraTime.Text(left))
    local c = (left and left < WARN) and WHITE or GOLD
    Color(icon.time, c[1], c[2], c[3])
end

function AuraTime.SetEnd(icon, fin)
    icon.timeEnd = fin
    icon.timeWait = 0
    AuraTime.Tick(icon, 0)
end

-- Size of one of our own icons, with its time text to match.
function AuraTime.Size(icon, size)
    icon:SetSize(size, size)
    if icon.timeSize ~= size then
        icon.timeSize = size
        local file, _, flags = icon.time:GetFont()
        if file then icon.time:SetFont(file, AuraTime.FontSize(size), flags or "") end
    end
end

-- The client-side formatter: built once, checked on plain numbers, false where it cannot be
-- made or does not give the expected text (the container's own "45s" style is used then).
local formatter, formatterWhy
local UNITS = { { 60, "%dm" }, { 3600, "%dh" }, { 86400, "%dd" } }

local function BuildRules(spec)
    local SU, E = _G.C_StringUtil, _G.Enum
    local up = type(E) == "table" and type(E.NumericRuleFormatRounding) == "table"
        and E.NumericRuleFormatRounding.Up or 1
    local fmt = SU.CreateNumericRuleFormatter()
    local rules = { { threshold = 0, step = 1, rounding = up, format = spec } }
    for _, u in ipairs(UNITS) do
        rules[#rules + 1] = { threshold = u[1], format = (u[2]:gsub("%%d", function() return spec end)),
            components = { { div = u[1], step = 1, rounding = up } } }
    end
    if type(fmt.SetBreakpoints) == "function" then
        fmt:SetBreakpoints(rules)
    else
        for _, r in ipairs(rules) do fmt:AddBreakpoint(r) end
    end
    return fmt
end

local EXPECT = { { 44.2, "45" }, { 540, "9m" }, { 3540, "59m" }, { 3600, "1h" } }

function AuraTime.Formatter()
    if formatter ~= nil then return formatter, formatterWhy end
    formatter, formatterWhy = false, "C_StringUtil.CreateNumericRuleFormatter missing"
    local SU = _G.C_StringUtil
    if type(SU) ~= "table" or type(SU.CreateNumericRuleFormatter) ~= "function" then return false, formatterWhy end
    for _, spec in ipairs({ "%d", "%.0f" }) do
        local ok, fmt = pcall(BuildRules, spec)
        if ok and fmt then
            if type(fmt.FormatNumber) ~= "function" then
                formatter, formatterWhy = fmt, "rule formatter " .. spec .. " (not checked: no FormatNumber)"
                return formatter, formatterWhy
            end
            local good = true
            for _, e in ipairs(EXPECT) do
                local okF, txt = pcall(fmt.FormatNumber, fmt, e[1])
                if not okF or txt ~= e[2] then
                    good = false
                    formatterWhy = "rule formatter " .. spec .. " gave " .. tostring(txt) .. " for " .. e[1]
                    break
                end
            end
            if good then
                formatter, formatterWhy = fmt, "rule formatter " .. spec
                return formatter, formatterWhy
            end
        else
            formatterWhy = tostring(fmt)
        end
    end
    return false, formatterWhy
end

-- White under a minute, gold above, as a step colour curve on the remaining duration; nil where
-- the client has no colour curves.
local colorOptions
function AuraTime.ColorOptions()
    if colorOptions ~= nil then return colorOptions or nil end
    colorOptions = false
    local CU, E = _G.C_CurveUtil, _G.Enum
    if type(CU) ~= "table" or type(CU.CreateColorCurve) ~= "function" or type(_G.CreateColor) ~= "function"
        or type(E) ~= "table" or type(E.DurationTextBindingProperty) ~= "table" then
        return nil
    end
    local ok, c = pcall(function()
        local c = CU.CreateColorCurve()
        if E.LuaCurveType and E.LuaCurveType.Step ~= nil then c:SetType(E.LuaCurveType.Step) end
        c:AddPoint(0, _G.CreateColor(WHITE[1], WHITE[2], WHITE[3], 1))
        c:AddPoint(WARN, _G.CreateColor(GOLD[1], GOLD[2], GOLD[3], 1))
        return c
    end)
    if ok and c then
        colorOptions = { curve = c, property = E.DurationTextBindingProperty.RemainingDuration }
    end
    return colorOptions or nil
end
end

local function NewAuraIcon(f)
    local icon = CreateFrame("Frame", nil, f.auraAnchor)
    icon:SetSize(16, 16)
    local border = icon:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    SetSolid(border, 0, 0, 0, 1)
    icon.border = border
    local tex = icon:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon.tex = tex
    local ok, cd = pcall(CreateFrame, "Cooldown", nil, icon, "CooldownFrameTemplate")
    if ok and cd then
        cd:SetAllPoints()
        if cd.SetHideCountdownNumbers then pcall(cd.SetHideCountdownNumbers, cd, true) end
        if cd.SetDrawEdge then pcall(cd.SetDrawEdge, cd, false) end
        if cd.SetReverse then pcall(cd.SetReverse, cd, true) end
        icon.cd = cd
    end
    icon.count = NewFont(icon, 9)
    icon.count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -1)
    icon.time = AuraTime.NewText(icon, 16)
    icon.timeSize = 16
    icon:SetScript("OnUpdate", AuraTime.Tick)
    icon:EnableMouse(true)
    icon:SetScript("OnEnter", AuraTooltip)
    icon:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    icon:Hide()
    return icon
end

local function UnitTooltip(self)
    if self.hl then self.hl:Show() end
    local tip = _G.GameTooltip
    if not tip or self.preview then return end
    pcall(function()
        if type(_G.GameTooltip_SetDefaultAnchor) == "function" then
            _G.GameTooltip_SetDefaultAnchor(tip, self)
        else
            tip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        end
        tip:SetUnit(self.unit)
        tip:Show()
    end)
end

local function UnitTooltipHide(self)
    if self.hl then self.hl:Hide() end
    if _G.GameTooltip then _G.GameTooltip:Hide() end
end

-- ---------------------------------------------------------------------------
-- Heal prediction (1.2.2), as on Blizzard's unit frames: incoming heals as an overlay from the
-- health bar's fill edge into the missing health - yours in a stronger green over everyone's in a
-- lighter green - then absorb shields in white after them, and heal absorbs (necrotic) in dark red
-- drawn back over the fill from its edge.
--
-- Secret-safe: the values are never added, compared or tested here. Each overlay is a StatusBar the
-- width of the health bar, anchored to the fill texture's right edge, with min/max and value set
-- straight from the client (StatusBar takes secrets). The client's own calculator does the sums
-- (CreateUnitHealPredictionCalculator + UnitGetDetailedHealPrediction, 12.x): incoming heals
-- clamped to the missing health, absorbs to the missing health left after the heals, heal absorbs
-- to the current health - so nothing reaches past the bar's end. "Yours over everyone's" needs no
-- subtraction: both bars start at the fill edge and yours is drawn on top. Without the calculator
-- the raw UnitGetIncomingHeals / UnitGetTotalAbsorbs / UnitGetTotalHealAbsorbs are used unclamped,
-- and the health bar clips its children so nothing is drawn past its end either way.
-- ---------------------------------------------------------------------------

local Mana = { H = 8 }   -- the player's extra mana bar (druid forms): H, Heights, Update
local HealPred = {}   -- Build, Update, Hide, Fake, Method, HotStatus
do
local MY = { 0.18, 0.78, 0.30, 0.85 }    -- your heals (Blizzard's myHealPrediction is a strong green)
local ALL = { 0.55, 0.88, 0.48, 0.55 }   -- everyone's heals, lighter
local HOT = { 0.95, 0.80, 0.30, 0.55 }   -- what active HoTs will still heal (1.2.7), soft yellow
local ABSORB = { 1.0, 1.0, 1.0, 0.55 }   -- totalAbsorb: white, with Blizzard's stripes where found
local HEAL_ABSORB = { 0.45, 0.08, 0.08, 0.75 }
local SHIELD_OVERLAY = "Interface\\RaidFrame\\Shield-Overlay"

local calc   -- the shared calculator; false where the client has none

local function Calculator()
    if calc ~= nil then return calc end
    calc = false
    local make, E = _G.CreateUnitHealPredictionCalculator, _G.Enum
    if type(make) ~= "function" or type(_G.UnitGetDetailedHealPrediction) ~= "function" then return false end
    local ok, c = pcall(make)
    if not ok or not c then return false end
    pcall(function()
        if type(E) ~= "table" then return end
        if E.UnitIncomingHealClampMode then c:SetIncomingHealClampMode(E.UnitIncomingHealClampMode.MissingHealth) end
        if c.SetIncomingHealOverflowPercent then c:SetIncomingHealOverflowPercent(1) end
        if E.UnitDamageAbsorbClampMode then c:SetDamageAbsorbClampMode(E.UnitDamageAbsorbClampMode.MissingHealth) end
        if E.UnitHealAbsorbClampMode then c:SetHealAbsorbClampMode(E.UnitHealAbsorbClampMode.CurrentHealth) end
        if E.UnitHealAbsorbMode then c:SetHealAbsorbMode(E.UnitHealAbsorbMode.ReducedByIncomingHeals) end
    end)
    calc = c
    return calc
end

function HealPred.Method()
    if Calculator() then return "client calculator (clamped)" end
    if type(_G.UnitGetIncomingHeals) == "function" then return "raw values, clipped to the bar" end
    return "none on this client"
end

-- ---------------------------------------------------------------------------
-- HoT prediction (1.2.7): a yellow segment after the green incoming heals, the healing every
-- active HoT on the unit (from any healer) will still do before it runs out.
--
-- Where the number comes from, best source first:
--   1. The client's own heal prediction. Retail's calculator (12.x) and UnitGetIncomingHeals
--      only predict cast heals - the green - and have no HoT split: no HoT clamp mode, no HoT
--      getter, no HoT flag on UnitGetIncomingHeals (classic HealComm's DIRECT / HOT flags are a
--      library of its own, not in the client). /bff status lists any calculator method whose
--      name says HoT or periodic, so a client that grows one shows it.
--   2. So it is summed from the unit's buffs: C_UnitAuras.GetAuraDataByIndex(unit, i,
--      "HELPFUL"), and for each known HoT (HOTS below, by spell ID: the tick interval and which
--      effect is the periodic one) the per-tick amount from aura.points times the ticks left
--      from expirationTime - GetTime(). Only when spell ID, points and expiration are plain.
--   3. On this client auras are secret while you are in combat (see Auras below), and reading
--      them by index is then refused. The yellow segment is simply hidden then - nothing else
--      changes - and /bff status says why ("unavailable (auras secret)"). Out of combat (a
--      healer topping up, resting) it is drawn.
-- Clamped as the green: when health, maximum and incoming heals are plain the sum is cut to the
-- missing health left after the incoming heals; otherwise the health bar clips its children,
-- so nothing is drawn past its end either way.
-- ---------------------------------------------------------------------------

-- [spellId] = { tick interval in seconds, index of the periodic effect in aura.points }
local HOTS = {}
local function AddHots(interval, effect, ids)
    for _, id in ipairs(ids) do HOTS[id] = { interval, effect } end
end
-- Renew, ranks 1-10
AddHots(3, 1, { 139, 6074, 6075, 6076, 6077, 6078, 10927, 10928, 10929, 25315 })
-- Rejuvenation, ranks 1-11
AddHots(3, 1, { 774, 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841, 25299 })
-- Regrowth, ranks 1-9: effect 1 is the direct heal, the HoT is effect 2
AddHots(3, 2, { 8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858 })
-- Lifebloom, where the client has it
AddHots(1, 1, { 33763 })
-- First Aid bandages (a channelled HoT on the target), Linen to Heavy Runecloth
AddHots(1, 1, { 746, 1159, 3267, 3268, 7926, 7927, 10838, 10839, 18608, 18610 })

local MAX_AURAS = 40
local hotWhy = "not read yet"   -- the last outcome, for /bff status

-- The plain per-tick amount of one HoT aura, or nil.
local function TickAmount(points, effect)
    points = Plain(points)
    if type(points) ~= "table" then return nil end
    -- A list of only the aura's own effects has the HoT first, even for Regrowth.
    local v = points[effect]
    if v == nil then v = points[1] end
    v = Num(v)
    if v and v > 0 then return v end
    return nil
end

-- The healing every known HoT on unit will still do, or nil and why not.
local function HotTotal(unit)
    local C = _G.C_UnitAuras
    if type(C) ~= "table" or type(C.GetAuraDataByIndex) ~= "function" then return nil, "no aura API" end
    local now = Num(type(_G.GetTime) == "function" and _G.GetTime() or nil)
    if not now then return nil, "no clock" end
    local S = _G.C_Secrets
    local ask = type(S) == "table" and type(S.ShouldUnitAuraIndexBeSecret) == "function"
        and S.ShouldUnitAuraIndexBeSecret or nil
    local total, hots, hidden = 0, 0, false
    for i = 1, MAX_AURAS do
        if ask then
            local ok, s = pcall(ask, unit, i, "HELPFUL")
            if ok and Plain(s) == true then return nil, "auras secret" end
        end
        local ok, a = pcall(C.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok then return nil, "auras secret" end
        if type(a) ~= "table" then break end
        local id = Num(a.spellId)
        local hot = id and HOTS[id]
        if hot then
            hots = hots + 1
            local per, exp = TickAmount(a.points, hot[2]), Num(a.expirationTime)
            if per and exp then
                local left = exp - now
                -- Ticks land at left = 2*interval, interval, 0: ceil, less a hair so a tick
                -- that has just landed is not counted again.
                local ticks = left > 0 and math.ceil(left / hot[1] - 0.05) or 0
                if ticks > 0 then total = total + per * ticks end
            else
                hidden = true
            end
        elseif IsSecret(a.spellId) then
            hidden = true   -- a secret spell ID: could be a HoT
        end
    end
    if hidden and total == 0 then return nil, "aura amounts secret" end
    if hots == 0 then return 0, "no known HoT on the unit" end
    return total, nil
end

-- Calculator methods whose name says HoT or periodic: none on retail 12.x, so the aura sum.
local function CalculatorHotMethods()
    local c = Calculator()
    if not c then return "no calculator" end
    local names, seen = {}, {}
    local function Scan(t)
        if type(t) ~= "table" then return end
        for k, v in pairs(t) do
            if type(k) == "string" and type(v) == "function" and not seen[k] then
                local l = k:lower()
                if l:find("hot", 1, true) or l:find("periodic", 1, true) or l:find("overtime", 1, true) then
                    seen[k] = true
                    names[#names + 1] = k
                end
            end
        end
    end
    pcall(function()
        local mt = getmetatable(c)
        Scan(type(mt) == "table" and mt.__index or nil)
        Scan(c)
    end)
    table.sort(names)
    return #names > 0 and table.concat(names, ", ") or "none"
end

-- For /bff status: what the yellow segment showed last, and where it comes from.
function HealPred.HotStatus()
    return hotWhy .. DOT .. "source: aura amounts of Renew, Rejuvenation, Regrowth, Lifebloom and"
        .. " bandages (plain only, so out of combat on this client)" .. DOT .. "calculator HoT methods: "
        .. CalculatorHotMethods()
end

local function Overlay(health, level, c, reverse)
    local b = CreateFrame("StatusBar", nil, health)
    b:SetStatusBarTexture(FLAT)
    Look.SetBarColor(b, c[1], c[2], c[3], c[4])
    b:SetFrameLevel(health:GetFrameLevel() + level)
    if reverse and b.SetReverseFill then b:SetReverseFill(true) end
    b:SetMinMaxValues(0, 1)
    b:SetValue(0)
    b:Hide()
    return b
end

-- Anchors bar from the right edge of tex (or, reversed, back from it) at the health bar's width.
local function Place(bar, tex, width, reverse)
    bar:ClearAllPoints()
    if reverse then
        bar:SetPoint("TOPRIGHT", tex, "TOPRIGHT", 0, 0)
        bar:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", 0, 0)
    else
        bar:SetPoint("TOPLEFT", tex, "TOPRIGHT", 0, 0)
        bar:SetPoint("BOTTOMLEFT", tex, "BOTTOMRIGHT", 0, 0)
    end
    bar:SetWidth(width)
end

function HealPred.Build(f)
    local h = f.health
    if h.SetClipsChildren then pcall(h.SetClipsChildren, h, true) end
    local hp = {}
    hp.all = Overlay(h, 1, ALL)
    hp.mine = Overlay(h, 2, MY)
    hp.hot = Overlay(h, 1, HOT)
    hp.absorb = Overlay(h, 1, ABSORB)
    hp.healAbsorb = Overlay(h, 3, HEAL_ABSORB, true)
    local fill = h:GetStatusBarTexture()
    Place(hp.all, fill, f.healthW)
    Place(hp.mine, fill, f.healthW)
    -- health | incoming heals (green) | HoTs (yellow) | absorbs (white)
    Place(hp.hot, hp.all:GetStatusBarTexture(), f.healthW)
    Place(hp.absorb, hp.hot:GetStatusBarTexture(), f.healthW)
    Place(hp.healAbsorb, fill, f.healthW, true)
    local ov = hp.absorb:CreateTexture(nil, "OVERLAY")
    ov:SetAllPoints(hp.absorb:GetStatusBarTexture())
    local okTex = ov:SetTexture(SHIELD_OVERLAY, "REPEAT", "REPEAT")
    if okTex == false then
        ov:Hide()
    else
        if ov.SetHorizTile then ov:SetHorizTile(true) end
        if ov.SetVertTile then ov:SetVertTile(true) end
        ov:SetAlpha(0.6)
    end
    -- The health text above the overlays.
    local tf = CreateFrame("Frame", nil, h)
    tf:SetAllPoints(h)
    tf:SetFrameLevel(h:GetFrameLevel() + 5)
    if h.text then h.text:SetParent(tf) end
    f.healPred = hp
end

function HealPred.Hide(f)
    local hp = f.healPred
    if not hp then return end
    for _, b in pairs(hp) do b:Hide() end
end

local function Set(bar, mx, v)
    if type(v) ~= "number" then bar:Hide(); return end   -- type() is allowed on a secret
    bar:SetMinMaxValues(0, mx)
    bar:SetValue(v)
    bar:Show()
end

-- The yellow HoT segment. Hidden, value 0, it still anchors the absorb bar at the green's edge.
local function SetHot(hp, mx, v)
    if type(v) ~= "number" or v <= 0 then   -- v is ours: plain, never secret
        hp.hot:SetMinMaxValues(0, 1)
        hp.hot:SetValue(0)
        hp.hot:Hide()
        return
    end
    Set(hp.hot, mx, v)
end

-- The HoT sum for unit, cut to the missing health after the incoming heals where all of those
-- are plain (otherwise the clipping health bar does it). Also notes the outcome for /bff status.
local function HotValue(u, mx, all)
    if not db.hotPred then hotWhy = "off"; return nil end
    local total, why = HotTotal(u)
    if not total then hotWhy = "unavailable (" .. why .. ")"; return nil end
    if why then hotWhy = "nothing to show (" .. why .. ")"; return nil end
    local m, cur, inc = Num(mx), Num(UnitHealth(u, false)), Num(all or 0)
    if m and cur and inc then total = Clamp(m - cur - inc, 0, total) end
    hotWhy = string.format("shown (%d on %s)", total, u)
    return total
end
-- One frame's overlays from the client. Values go from one client call to the next.
function HealPred.Update(f)
    local hp = f.healPred
    if not hp then return end
    if f.preview or not db.healPrediction then HealPred.Hide(f); return end
    local u = f.unit
    local mx = UnitHealthMax(u)
    if type(mx) ~= "number" then HealPred.Hide(f); return end
    local all, mine, absorb, healAbsorb
    local c = Calculator()
    if c then
        _G.UnitGetDetailedHealPrediction(u, "player", c)
        all, mine = c:GetIncomingHeals()
        if type(all) == "table" then all, mine = all.amount, all.amountFromHealer end
        absorb = c:GetDamageAbsorbs()
        if type(absorb) == "table" then absorb = absorb.amount end
        healAbsorb = c:GetHealAbsorbs()
        if type(healAbsorb) == "table" then healAbsorb = healAbsorb.amount end
    else
        local inc, tot, habs = _G.UnitGetIncomingHeals, _G.UnitGetTotalAbsorbs, _G.UnitGetTotalHealAbsorbs
        if type(inc) == "function" then all, mine = inc(u), inc(u, "player") end
        if type(tot) == "function" then absorb = tot(u) end
        if type(habs) == "function" then healAbsorb = habs(u) end
    end
    Set(hp.all, mx, all)
    Set(hp.mine, mx, mine)
    SetHot(hp, mx, HotValue(u, mx, all))
    Set(hp.absorb, mx, absorb)
    Set(hp.healAbsorb, mx, healAbsorb)
end

-- Test mode: plain made-up values { mine, others, absorb } against the made-up maximum.
function HealPred.Fake(f, d, mx)
    local hp = f.healPred
    if not hp then return end
    if not db.healPrediction or not d.heal then HealPred.Hide(f); return end
    local h = d.heal
    Set(hp.all, mx, h[1] + h[2])
    Set(hp.mine, mx, h[1])
    SetHot(hp, mx, db.hotPred and h[4] or nil)
    Set(hp.absorb, mx, h[3])
    hp.healAbsorb:Hide()
end
end

local function FrameHeight(L)
    return PAD + L.name + 2 + L.hp + 1 + L.mp + PAD
end

-- One unit frame. A secure button for the real thing; a plain one for the test-mode preview.
-- Secure attributes are set here, once, and this is only ever called out of combat.
local function Build(key, unit, preview)
    local L = LAYOUT[key]
    local name = (preview and "BetterFramesForeverPreview_" or "BetterFramesForever_") .. unit
    local f = NewButton(name, not preview)
    f.key, f.unit, f.preview = key, unit, preview and true or nil
    f.layout = L

    local bodyH = L.hp + 1 + L.mp
    f:SetSize(L.w, FrameHeight(L))
    f:SetFrameStrata("LOW")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    SetBackdropLook(f, 0.55, 1)

    if not preview then
        f:SetAttribute("unit", unit)
        f:SetAttribute("type1", "target")
        f:SetAttribute("type2", "togglemenu")
        f:RegisterForClicks("AnyUp")
    end
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) StartDrag(self) end)
    f:SetScript("OnDragStop", function(self) StopDrag(self) end)
    f:SetScript("OnEnter", UnitTooltip)
    f:SetScript("OnLeave", UnitTooltipHide)
    if not preview then
        f:SetScript("OnShow", function(self) UpdateFrame(self) end)
    end

    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 1, -1)
    hl:SetPoint("BOTTOMRIGHT", -1, 1)
    SetSolid(hl, 1, 1, 1, 0.06)
    hl:Hide()
    f.hl = hl

    -- Threat: a 2px border just outside the frame.
    local glow = NewBackdropFrame(f)
    glow:SetPoint("TOPLEFT", -3, 3)
    glow:SetPoint("BOTTOMRIGHT", 3, -3)
    SetBackdropLook(glow, nil, 2)
    glow:Hide()
    f.glow = glow

    -- Name bar.
    local nb = CreateFrame("Frame", nil, f)
    nb:SetPoint("TOPLEFT", PAD, -PAD)
    nb:SetPoint("TOPRIGHT", -PAD, -PAD)
    nb:SetHeight(L.name)
    local nbg = nb:CreateTexture(nil, "BACKGROUND")
    nbg:SetAllPoints()
    SetSolid(nbg, 0, 0, 0, 0.35)
    f.nameBar = nb
    f.levelText = NewFont(nb, L.name - 4)
    f.levelText:SetPoint("RIGHT", nb, "RIGHT", -3, 0)
    f.classIcon = nb:CreateTexture(nil, "ARTWORK")
    f.classIcon:SetSize(L.name - 3, L.name - 3)
    f.classIcon:SetPoint("RIGHT", f.levelText, "LEFT", -3, 0)
    f.classIcon:SetTexture(CLASS_ICONS)
    f.classIcon:Hide()
    f.tagText = NewFont(nb, L.name - 5)
    f.tagText:SetPoint("RIGHT", f.levelText, "LEFT", -3, 0)
    f.tagText:SetTextColor(1, 0.82, 0.2)
    f.nameText = NewFont(nb, L.name - 3)
    f.nameText:SetPoint("LEFT", nb, "LEFT", 3, 0)
    f.nameText:SetPoint("RIGHT", nb, "RIGHT", -L.reserve, 0)
    f.nameText:SetJustifyH("LEFT")

    -- Portrait left, bars right.
    local top = -(PAD + L.name + 2)
    local barsX = PAD
    if L.portrait then
        local pf = CreateFrame("Frame", nil, f)
        pf:SetSize(bodyH, bodyH)
        pf:SetPoint("TOPLEFT", PAD, top)
        local pbg = pf:CreateTexture(nil, "BACKGROUND")
        pbg:SetAllPoints()
        SetSolid(pbg, 0, 0, 0, 0.6)
        local pt = pf:CreateTexture(nil, "ARTWORK")
        pt:SetPoint("TOPLEFT", 1, -1)
        pt:SetPoint("BOTTOMRIGHT", -1, 1)
        pt:SetTexCoord(0.12, 0.88, 0.12, 0.88)
        f.portraitFrame, f.portraitTex = pf, pt
        barsX = PAD + bodyH + 3
    end

    local fontHP = math.min(12, L.hp - 4)
    f.health = NewBar(f, L.hp, fontHP)
    f.health:SetPoint("TOPLEFT", f, "TOPLEFT", barsX, top)
    f.health:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, top)
    f.power = NewBar(f, L.mp, L.powerText and math.max(7, L.mp - 3) or nil)
    f.power:SetPoint("TOPLEFT", f.health, "BOTTOMLEFT", 0, -1)
    f.power:SetPoint("TOPRIGHT", f.health, "BOTTOMRIGHT", 0, -1)
    -- 1px near-black border and a faint shadow round the health bar (1.2.8), one level under the
    -- bars so the power bar, the portrait gap and the name bar are never covered by more than
    -- the faint shadow.
    local lvl = f:GetFrameLevel()
    f.health:SetFrameLevel(lvl + 2)
    f.power:SetFrameLevel(lvl + 2)
    Look.Edge(f, f.health, lvl + 1)
    f.healthW = L.w - barsX - PAD
    HealPred.Build(f)

    -- The player's mana while a form shows another power (druid in bear or cat form): a thin
    -- blue bar under the power bar, as Blizzard's alternate mana bar. Hidden until needed; it
    -- takes its room from the health bar, since the secure frame cannot grow in combat.
    if key == "player" then
        f.mana = NewBar(f, Mana.H, 7)
        f.mana:SetPoint("TOPLEFT", f.power, "BOTTOMLEFT", 0, -1)
        f.mana:SetPoint("TOPRIGHT", f.power, "BOTTOMRIGHT", 0, -1)
        Look.SetBarColor(f.mana, POWER_COLORS.MANA[1], POWER_COLORS.MANA[2], POWER_COLORS.MANA[3])
        f.mana:Hide()
    end

    -- Icons.
    local ri = f:CreateTexture(nil, "OVERLAY")
    ri:SetSize(18, 18)
    ri:SetPoint("CENTER", f, "TOP", 0, 0)
    ri:SetTexture(RAID_ICONS)
    ri:Hide()
    f.raidIcon = ri
    if key == "player" or key == "party" then
        local li = f:CreateTexture(nil, "OVERLAY")
        li:SetSize(14, 14)
        li:SetPoint("CENTER", f, "TOPLEFT", 4, 0)
        li:SetTexture(LEADER_ICON)
        li:Hide()
        f.leaderIcon = li
    end
    if key == "player" and f.portraitFrame then
        local si = f.portraitFrame:CreateTexture(nil, "OVERLAY")
        si:SetSize(16, 16)
        si:SetPoint("BOTTOMLEFT", f.portraitFrame, "BOTTOMLEFT", -4, -4)
        si:SetTexture(STATE_ICON)
        si:Hide()
        f.stateIcon = si
    end

    -- Combo points above the target frame's top-right corner.
    if key == "target" then
        f.combo = {}
        for i = 1, 5 do
            local p = f:CreateTexture(nil, "OVERLAY")
            p:SetSize(10, 6)
            p:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -(PAD + (5 - i) * 12), 2)
            SetSolid(p, 1, 0.85 - i * 0.12, 0.1, 1)
            p:Hide()
            f.combo[i] = p
        end
    end

    if AURAS[key] then
        local anchor = CreateFrame("Frame", nil, f)
        anchor:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -3)
        anchor:SetSize(L.w, 1)
        f.auraAnchor = anchor
        f.auraIcons = {}
    end

    ApplyBorder(f)
    return f
end

-- ---------------------------------------------------------------------------
-- Painting a frame. Each part runs inside Run (pcall + latch); none of them may assume a value
-- is plain unless it has been checked.
-- ---------------------------------------------------------------------------

-- Current health without the client's prediction. UnitHealth's second argument, usePredicted,
-- defaults to true, while the percent below has always been read with usePredicted = false, so
-- 1.2.5 put two different readings side by side: on a mob near death it showed "1/473  4%",
-- the number far below the percent. Bar, number and percent now all read the same value.
local ValueText = {}   -- Read, Abbrev, Secret, Status: the numbers in the bar text

function ValueText.Read(unit)
    return UnitHealth(unit, false)
end

-- The number formatter for hidden values: AbbreviateLargeNumbers, what Blizzard's own unit
-- frames use (TextStatusBar with capNumericDisplay, set by UnitFrame_Initialize on every
-- health and mana bar), else AbbreviateNumbers. Both take a secret and give a secret string.
function ValueText.Abbrev()
    if type(_G.AbbreviateLargeNumbers) == "function" then return _G.AbbreviateLargeNumbers, "AbbreviateLargeNumbers" end
    if type(_G.AbbreviateNumbers) == "function" then return _G.AbbreviateNumbers, "AbbreviateNumbers" end
end

-- Hidden values written through the client's own secret-safe helpers, where it has them.
-- Nothing here compares, adds or tests the values: they go straight to the client.
function ValueText.Secret(fs, unit, power, compact)
    local C = _G.CurveConstants
    local curve = type(C) == "table" and C.ScaleTo100 or nil
    local pct, havePct
    if curve ~= nil then
        if power and type(_G.UnitPowerPercent) == "function" then
            pct, havePct = _G.UnitPowerPercent(unit, nil, false, curve), true
        elseif not power and type(_G.UnitHealthPercent) == "function" then
            pct, havePct = _G.UnitHealthPercent(unit, false, curve), true
        end
    end
    local abbr = ValueText.Abbrev()
    local fmt, a1, a2, a3
    if abbr and not compact then
        local cur, mx
        if power then cur, mx = UnitPower(unit), UnitPowerMax(unit)
        else cur, mx = ValueText.Read(unit), UnitHealthMax(unit) end
        if havePct then fmt, a1, a2, a3 = "%s/%s  %.0f%%", abbr(cur), abbr(mx), pct
        else fmt, a1, a2 = "%s/%s", abbr(cur), abbr(mx) end
    elseif havePct then
        fmt, a1 = "%.0f%%", pct
    end
    if not fmt then fs:SetText(""); return end
    if type(fs.SetFormattedText) == "function" then
        fs:SetFormattedText(fmt, a1, a2, a3)
    else
        fs:SetText(string.format(fmt, a1, a2, a3))
    end
end

-- "cur/max  NN%" from plain numbers, the percent alone where the full text does not fit.
local function PlainText(f, bar, cur, mx)
    local fs = bar.text
    if mx <= 0 then fs:SetText(""); return end
    local pct = math.floor(cur / mx * 100 + 0.5)
    fs:SetText(string.format("%s/%s  %d%%", Short(cur), Short(mx), pct))
    local room = (Num(bar:GetWidth()) or 0) - 4
    local w = Num(fs:GetStringWidth())
    if room > 0 and w and w > room then fs:SetText(pct .. "%") end
end

local function UpdateHealth(f)
    local u, bar = f.unit, f.health
    local cur, mx = ValueText.Read(u), UnitHealthMax(u)
    local pct
    local secret = Secret(cur, mx)
    if secret then
        -- The widget takes the raw values; only this file may not do sums on them.
        bar:SetMinMaxValues(0, mx)
        bar:SetValue(cur)
    else
        cur = type(cur) == "number" and cur or 0
        mx = (type(mx) == "number" and mx > 0) and mx or 1
        bar:SetMinMaxValues(0, mx)
        bar:SetValue(cur)
        pct = cur / mx
    end
    local r, g, b = HealthRGB(u, pct)
    Look.SetBarColor(bar, r, g, b)

    local fs = bar.text
    if not db.text then fs:SetText(""); return end
    if Plain(UnitIsConnected(u)) == false then fs:SetText("Offline"); return end
    if Plain(UnitIsDeadOrGhost(u)) == true then
        local ghost = type(_G.UnitIsGhost) == "function" and Plain(_G.UnitIsGhost(u)) == true
        fs:SetText(ghost and "Ghost" or "Dead")
        return
    end
    if not secret then PlainText(f, bar, cur, mx); return end
    fs:SetText("")
    Run("secrettext", ValueText.Secret, fs, u, false, f.layout.compact)
end

-- Shows or hides the power bar; without it the health bar takes the power bar's height too.
-- Both are plain child bars of our frame, so this is allowed in combat.
-- The health bar's height from what sits under it: the power bar's room when there is no power,
-- less the player's extra mana bar while that shows.
function Mana.Heights(f)
    local L = f.layout
    local h = L.hp
    if f.powerShown == false then h = h + 1 + L.mp end
    if f.manaShown then h = h - (Mana.H + 1) end
    f.health:SetHeight(h)
end

local function SetPowerShown(f, on)
    on = on and true or false
    if f.powerShown == on then return end
    f.powerShown = on
    if on then f.power:Show() else f.power:Hide() end
    Mana.Heights(f)
end

-- ---------------------------------------------------------------------------
-- The player's mana under a form's power (1.2.2). Shown only while the display power is not mana
-- and the player has mana: a plain maximum above 0, or - where the maximum is hidden - the
-- client's UnitHasPowerType. The text is "cur/max  NN%", from plain numbers or through the same
-- secret-safe helpers as the other bars. Player frame only.
-- ---------------------------------------------------------------------------

do
local function ManaType()
    local E = _G.Enum
    return type(E) == "table" and type(E.PowerType) == "table" and E.PowerType.Mana or 0
end

local function SetManaShown(f, on)
    on = on and true or false
    if f.manaShown == on then return end
    f.manaShown = on
    if on then f.mana:Show() else f.mana:Hide() end
    Mana.Heights(f)
end

-- Hidden mana values as "cur/max  NN%" (or less, where a helper is missing). Nothing is tested.
local function ManaSecretText(fs, u, mt)
    local C = _G.CurveConstants
    local pct
    if type(C) == "table" and C.ScaleTo100 ~= nil and type(_G.UnitPowerPercent) == "function" then
        pct = _G.UnitPowerPercent(u, mt, false, C.ScaleTo100)
    end
    local abbr = ValueText.Abbrev()
    if abbr and pct ~= nil then
        fs:SetFormattedText("%s/%s  %.0f%%", abbr(UnitPower(u, mt)), abbr(UnitPowerMax(u, mt)), pct)
    elseif abbr then
        fs:SetFormattedText("%s/%s", abbr(UnitPower(u, mt)), abbr(UnitPowerMax(u, mt)))
    elseif pct ~= nil then
        fs:SetFormattedText("%.0f%%", pct)
    else
        fs:SetText("")
    end
end

function Mana.Update(f)
    if not f.mana then return end
    local u, mt = f.unit, ManaType()
    local pType = Num(UnitPowerType(u))
    local cur, mx = UnitPower(u, mt), UnitPowerMax(u, mt)
    local has
    local plainMax = Num(mx)
    if plainMax then
        has = plainMax > 0
    elseif type(_G.UnitHasPowerType) == "function" then
        local ok, v = pcall(_G.UnitHasPowerType, u, mt)
        has = ok and Plain(v) == true
    end
    local want = has and pType ~= nil and pType ~= mt
    f.manaWhy = (pType == mt and "display power is mana")
        or (pType == nil and "display power hidden")
        or (has and "shown") or (plainMax and "no mana") or "mana maximum hidden"
    SetManaShown(f, want)
    if not want then return end
    local bar, fs = f.mana, f.mana.text
    if Secret(cur, mx) then
        bar:SetMinMaxValues(0, mx)
        bar:SetValue(cur)
        fs:SetText("")
        if db.text then Run("secrettext", ManaSecretText, fs, u, mt) end
        return
    end
    cur = Num(cur) or 0
    if not plainMax or plainMax <= 0 then
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        fs:SetText("")
        return
    end
    bar:SetMinMaxValues(0, plainMax)
    bar:SetValue(cur)
    if db.text then PlainText(f, bar, cur, plainMax) else fs:SetText("") end
end
end

-- Whether a unit has no power to show: true (none), false (it has power) or nil (cannot tell),
-- and why, for /bff status. A plain maximum decides where there is one. On this client
-- UnitPowerMax is secret for every unit that is not player-controlled (the API documentation's
-- SecretWhenUnitPowerMaxRestricted), so a beast's maximum of 0 cannot be tested - 1.1 fell
-- through to the hidden-value text and wrote "0/0 0%". UnitPowerType and UnitHasPowerType carry
-- no secret flag there, so for NPCs the client's own "has a power of this type" decides. Where
-- UnitHasPowerType is missing: UnitPower is only plain for a power the unit does not have (or a
-- type flagged never secret), so a plain 0 next to a hidden maximum is taken as none.
local function NoPower(u, pType, cur, mx)
    local plainMax = Num(mx)
    if plainMax then return plainMax <= 0, "max " .. plainMax end
    local H = _G.UnitHasPowerType
    if pType and type(H) == "function" then
        local ok, has = pcall(H, u, pType)
        if ok and not IsSecret(has) and type(has) == "boolean" then
            return not has, "UnitHasPowerType " .. tostring(has)
        end
    end
    -- Not for the player or anything player-controlled: a bear at 0 rage has rage (1.2.2).
    local pc = u == "player"
        or (type(_G.UnitPlayerControlled) == "function" and Plain(_G.UnitPlayerControlled(u)) == true)
    if Num(cur) == 0 and not pc then return true, "power 0 plain, max hidden" end
    return nil, "max hidden, nothing to tell"
end

-- An NPC whose maximum is a hidden 0 (BetterFramesForever 1.2.1). In game a low beast in the
-- Barrens answers: power type RAGE, UnitHasPowerType true, UnitPower and UnitPowerMax both secret
-- - so NoPower cannot tell, and 1.2 wrote "0/0 0%" from the hidden values. Nothing an addon may
-- call turns a hidden 0 into a plain answer, and a curve cannot be evaluated on the maximum
-- either (LuaCurveObject:Evaluate takes secret arguments only from untainted code). What the
-- client does let tainted code do (Blizzard_APIDocumentationGenerated, Forever 1.60.1):
--   * C_StringUtil.TruncateWhenZero(number) -> "" when the number is 0, and WrapString(infix,
--     prefix, suffix) -> prefix..infix..suffix, or "" when infix is "". Both take secrets. So the
--     text is "cur/max  NN%" built around TruncateWhenZero(max): empty when the maximum is 0.
--   * UnitPowerPercent(unit, nil, false, curve) evaluates our own curve inside the client, and
--     Region:SetAlpha takes the secret result. A step curve (0 -> 0, anything above -> 1) makes
--     the bar invisible while the power is 0 - always so with a maximum of 0. The bar's room
--     stays (a secret value cannot move a layout); an NPC with real power at 0 (rage out of
--     combat) loses its empty bar until it has some.
-- Where TruncateWhenZero or WrapString is missing: no text for an NPC's hidden RAGE (the type the
-- beasts answer), the client's own hidden-value text for everything else.
local PowerHide = {}   -- Method, Alpha, Text
do
local powerCurve   -- the step curve; false when this client cannot make one

local function PowerAlphaCurve()
    if powerCurve ~= nil then return powerCurve end
    powerCurve = false
    local CU, E = _G.C_CurveUtil, _G.Enum
    if type(CU) ~= "table" or type(CU.CreateCurve) ~= "function" or type(_G.UnitPowerPercent) ~= "function"
        or type(E) ~= "table" or type(E.LuaCurveType) ~= "table" or E.LuaCurveType.Step == nil then
        return false
    end
    local ok, c = pcall(function()
        local c = CU.CreateCurve()
        c:SetType(E.LuaCurveType.Step)
        c:AddPoint(0, 0)
        c:AddPoint(0.000001, 1)
        c:AddPoint(1, 1)
        return c
    end)
    if ok and c then powerCurve = c
    else Latch("powerhide", ok and "C_CurveUtil.CreateCurve returned nothing" or c) end
    return powerCurve
end

local function HasStringGate()
    local SU = _G.C_StringUtil
    return type(SU) == "table" and type(SU.TruncateWhenZero) == "function" and type(SU.WrapString) == "function"
end

-- How a hidden power line is kept from showing 0/0: "curve+truncate", "curve", "truncate" or
-- "fallback", for UpdatePower and /bff status.
function PowerHide.Method()
    if blocked.powerhide then return "fallback" end
    local curve = PowerAlphaCurve() and true or false
    local gate = HasStringGate()
    if curve and gate then return "curve+truncate" end
    if curve then return "curve" end
    if gate then return "truncate" end
    return "fallback"
end

-- The bar's alpha from the hidden percent: 0 while the power is 0, else 1. Nothing here reads it.
function PowerHide.Alpha(bar, u)
    bar:SetAlpha(_G.UnitPowerPercent(u, nil, false, PowerAlphaCurve()))
end

-- "cur/max  NN%" (the percent alone on compact frames), or "" when the hidden maximum is 0.
-- Every piece goes from one client helper to the next; none is tested or joined here.
function PowerHide.Text(fs, u, compact)
    local SU = _G.C_StringUtil
    local trunc, wrap = SU.TruncateWhenZero, SU.WrapString
    local C = _G.CurveConstants
    local pct
    if type(C) == "table" and C.ScaleTo100 ~= nil and type(_G.UnitPowerPercent) == "function" then
        pct = _G.UnitPowerPercent(u, nil, false, C.ScaleTo100)
    end
    if compact then
        -- No room for the maximum, so the percent gates itself: nothing below 1%.
        fs:SetText(pct ~= nil and wrap(trunc(pct), nil, "%") or "")
        return
    end
    local maxS = trunc(UnitPowerMax(u))
    local cur = UnitPower(u)
    local curS
    local abbr = ValueText.Abbrev()
    if type(SU.FloorToNearestString) == "function" then curS = SU.FloorToNearestString(cur)
    elseif abbr then curS = abbr(cur)
    else curS = trunc(cur) end
    local pctS
    if pct ~= nil and type(SU.RoundToNearestString) == "function" then
        pctS = wrap(SU.RoundToNearestString(pct), "  ", "%")
    end
    fs:SetText(wrap(maxS, wrap(curS, nil, "/"), pctS))
end
end

local function UpdatePower(f)
    local u, bar = f.unit, f.power
    local pType, token = UnitPowerType(u)
    local r, g, b = PowerRGB(Plain(token))
    Look.SetBarColor(bar, r, g, b)
    local cur, mx = UnitPower(u), UnitPowerMax(u)
    local fs = bar.text
    -- No power at all (a beast, most warrior-type NPCs): the bar goes and health takes its room.
    local none, why = NoPower(u, Num(pType), cur, mx)
    f.powerWhy = why
    SetPowerShown(f, not none)
    if none then
        f.powerHide = nil
        bar:SetAlpha(1)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        if fs then fs:SetText("") end
        return
    end
    if Secret(cur, mx) then
        bar:SetMinMaxValues(0, mx)
        bar:SetValue(cur)
        local method = PowerHide.Method()
        f.powerHide = method
        -- The alpha curve is only for the hidden 0 maximum of an NPC. A unit whose maximum is
        -- known (plain and above 0) or that is player-controlled (the player, a pet, a party
        -- member: their maximum is never the hidden 0) keeps its bar at 0 rage or energy
        -- (1.2.2: a bear at 0 rage had no rage bar).
        local plainMax = Num(mx)
        local knownMax = (plainMax and plainMax > 0) or u == "player"
            or (type(_G.UnitPlayerControlled) == "function" and Plain(_G.UnitPlayerControlled(u)) == true)
        if knownMax then
            bar:SetAlpha(1)
            f.powerHide = method .. " (alpha kept: max known)"
        elseif method == "curve+truncate" or method == "curve" then Run("powerhide", PowerHide.Alpha, bar, u)
        else bar:SetAlpha(1) end
        if fs then
            fs:SetText("")
            if db.text then
                if method == "curve+truncate" or method == "truncate" then
                    Run("powerhide", PowerHide.Text, fs, u, f.layout.compact)
                elseif Plain(token) == "RAGE" and not (type(_G.UnitPlayerControlled) == "function"
                    and Plain(_G.UnitPlayerControlled(u)) == true) then
                    -- Fallback: an NPC's hidden rage is the beasts' 0/0; no text rather than that.
                    f.powerHide = "fallback (no text for an NPC's hidden rage)"
                else
                    Run("secrettext", ValueText.Secret, fs, u, true, f.layout.compact)
                end
            end
        end
        return
    end
    f.powerHide = nil
    bar:SetAlpha(1)
    cur = type(cur) == "number" and cur or 0
    mx = type(mx) == "number" and mx or 0
    if mx <= 0 then
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
        if fs then fs:SetText("") end
        return
    end
    bar:SetMinMaxValues(0, mx)
    bar:SetValue(cur)
    if fs then
        if db.text and Plain(UnitIsDeadOrGhost(u)) ~= true then PlainText(f, bar, cur, mx)
        else fs:SetText("") end
    end
end

local function UpdateName(f)
    local u = f.unit
    SetTextSafe(f.nameText, (UnitName(u)))
    local isPlayer = Plain(UnitIsPlayer(u)) == true
    local cls = isPlayer and ClassToken(u) or nil
    local r, g, b
    if cls and db.classColor then r, g, b = ClassRGB(cls) end
    if r then f.nameText:SetTextColor(r, g, b) else f.nameText:SetTextColor(1, 1, 1) end

    local lvl = Num(UnitLevel(u))
    if not lvl then
        f.levelText:SetText("")
    elseif lvl <= 0 then
        f.levelText:SetText("??")
        f.levelText:SetTextColor(1, 0.1, 0.1)
    else
        f.levelText:SetText(tostring(lvl))
        f.levelText:SetTextColor(LevelRGB(lvl))
    end

    -- Players: class icon. NPCs: Elite / Rare / Boss tag and border.
    local coords = cls and type(_G.CLASS_ICON_TCOORDS) == "table" and _G.CLASS_ICON_TCOORDS[cls]
    if type(coords) == "table" and type(coords[1]) == "number" then
        f.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        f.classIcon:Show()
    else
        f.classIcon:Hide()
    end
    local kind
    if not isPlayer and type(_G.UnitClassification) == "function" then
        kind = Plain(_G.UnitClassification(u))
    end
    f.tagText:SetText(kind and not f.layout.compact and TAGS[kind] or "")
    local elite = kind and ELITE_KIND[kind] or nil
    if f.eliteKind ~= elite then
        f.eliteKind = elite
        ApplyBorder(f)
    end
end

local function UpdatePortrait(f)
    if not f.portraitTex then return end
    local u = f.unit
    if db.portrait == "3d" then
        if not f.model then
            local m = CreateFrame("PlayerModel", nil, f.portraitFrame)
            m:SetPoint("TOPLEFT", 1, -1)
            m:SetPoint("BOTTOMRIGHT", -1, 1)
            f.model = m
        end
        if Plain(UnitIsVisible(u)) == true then
            f.portraitTex:Hide()
            f.model:Show()
            f.model:ClearModel()
            f.model:SetUnit(u)
            if f.model.SetPortraitZoom then f.model:SetPortraitZoom(1) end
            if f.model.SetCamDistanceScale then f.model:SetCamDistanceScale(1) end
            return
        end
    end
    if f.model then f.model:Hide() end
    f.portraitTex:Show()
    if not pcall(SetPortraitTexture, f.portraitTex, u, true) then
        SetPortraitTexture(f.portraitTex, u)
    end
end

local function UpdateIcons(f)
    local u = f.unit
    local idx = type(_G.GetRaidTargetIndex) == "function" and Num(_G.GetRaidTargetIndex(u)) or nil
    if idx and idx >= 1 and idx <= 8 then
        local col, row = (idx - 1) % 4, math.floor((idx - 1) / 4)
        f.raidIcon:SetTexCoord(col * 0.25, col * 0.25 + 0.25, row * 0.25, row * 0.25 + 0.25)
        f.raidIcon:Show()
    else
        f.raidIcon:Hide()
    end
    if f.leaderIcon then
        local leader = type(_G.UnitIsGroupLeader) == "function" and Plain(_G.UnitIsGroupLeader(u)) == true
        if leader then f.leaderIcon:Show() else f.leaderIcon:Hide() end
    end
    if f.stateIcon then
        if Plain(UnitAffectingCombat("player")) == true then
            f.stateIcon:SetTexCoord(0.5, 1, 0, 0.484375)
            f.stateIcon:Show()
        elseif type(_G.IsResting) == "function" and Plain(_G.IsResting()) == true then
            f.stateIcon:SetTexCoord(0, 0.5, 0, 0.421875)
            f.stateIcon:Show()
        else
            f.stateIcon:Hide()
        end
    end
end

-- Friendly frames: that unit's own threat status. Hostile ones: the player's threat on it.
-- This client's UnitThreatSituation takes a mob GUID as its second argument; older ones take a
-- unit token, so that is tried when the GUID form is refused.
local function UpdateThreat(f)
    local u = f.unit
    local status
    if type(_G.UnitThreatSituation) == "function" then
        if Plain(UnitCanAttack("player", u)) == true then
            local ok, s = pcall(_G.UnitThreatSituation, "player", UnitGUID(u))
            if not ok then s = _G.UnitThreatSituation("player", u) end
            status = s
        else
            status = _G.UnitThreatSituation(u)
        end
    end
    status = Num(status)
    status = (status and status >= 1 and status <= 3) and status or nil
    if f.threatStatus ~= status then
        f.threatStatus = status
        ApplyBorder(f)
    end
end

-- ---------------------------------------------------------------------------
-- Auras.
--
-- On this client (Forever 1.60.1, retail 12.x secret-aura rules) auras are secret while you are
-- in combat, and every aura read by index, slot or instance ID from addon code is then refused
-- with a Lua error ("GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted").
-- Casting a DoT puts you in combat, so 1.0 - one pcall round the whole aura update - switched
-- auras off for the session on the first DoT. Looking an aura up by spell ID
-- (C_UnitAuras.GetUnitAuraBySpellID) is no way round it: in game it answers nil for your own
-- DoTs on an enemy in combat (seen with BetterPlatesForever 1.1).
--
-- What does work in combat is letting the client draw them: Blizzard_AuraContainer (retail 12.x,
-- C_AuraContainerUtil is in Forever's binary) has an addon-usable "AuraContainer" frame with the
-- CustomAuraContainerTemplate. We give it a unit, filter strings and the look of each button
-- (icon, cooldown, count); its own secure code reads the auras, secret or not, and shows them.
-- So, per frame with auras:
--   1. The Blizzard aura container, where this client has it (feature-detected; built the first
--      time the frame's auras are drawn). Target: your debuffs (large), other debuffs (small,
--      grey) and buffs; party: debuffs and buffs.
--   2. Otherwise our own icons from index reads, one pcall per read, C_Secrets.
--      ShouldUnitAuraIndexBeSecret asked first. A refused read is counted for /bff status and
--      tried again at the next update - never a latch - so out of combat the auras are back.
-- Only an error outside the reads switches auras off for the session, with one line in chat.
-- ---------------------------------------------------------------------------

local auraStats              -- aura reads refused this session, for /bff status
local containerInfo = {}     -- how the Blizzard aura container fared, for /bff status
local UpdateAuras

do
    auraStats = { indexRefused = 0, paintFailed = 0, lastError = nil }

    local function NoteRefusal(kind, err)
        auraStats[kind] = auraStats[kind] + 1
        auraStats.lastError = tostring(err)
    end

    -- True only when the client says plainly that this index would be secret.
    local function IndexIsSecret(unit, i, filter)
        local S = _G.C_Secrets
        if type(S) ~= "table" or type(S.ShouldUnitAuraIndexBeSecret) ~= "function" then return false end
        local ok, secret = pcall(S.ShouldUnitAuraIndexBeSecret, unit, i, filter)
        return ok and Plain(secret) == true
    end

    -- An aura table, nil at the end of the list, or false when the client refused the read.
    local function IndexAura(unit, i, filter)
        if IndexIsSecret(unit, i, filter) then return false end
        local C = _G.C_UnitAuras
        if type(C) == "table" and type(C.GetAuraDataByIndex) == "function" then
            local ok, a = pcall(C.GetAuraDataByIndex, unit, i, filter)
            if not ok then NoteRefusal("indexRefused", a); return false end
            if type(a) ~= "table" then return nil end
            return a
        end
        if type(_G.UnitAura) == "function" then
            local ok, name, icon, count, dispel, duration, expiration, source = pcall(_G.UnitAura, unit, i, filter)
            if not ok then NoteRefusal("indexRefused", name); return false end
            if Plain(name) == nil then return nil end
            return { icon = icon, applications = count, dispelName = dispel, duration = duration,
                expirationTime = expiration, sourceUnit = source }
        end
        return nil
    end

    -- true / false when known, nil when the client hides it. isFromPlayerOrPlayerPet means
    -- "cast by a player or a player's pet" - any player, not only you (Blizzard's target frame
    -- tests the caster against "player" for that) - so it can only rule an aura out.
    local function OwnAura(a)
        local src = Plain(a.sourceUnit)
        if type(src) == "string" then return src == "player" or src == "pet" or src == "vehicle" end
        if Plain(a.isFromPlayerOrPlayerPet) == false then return false end
        return nil
    end

    -- -----------------------------------------------------------------------
    -- 1. The Blizzard aura container
    -- -----------------------------------------------------------------------

    -- "HARMFUL|!PLAYER" where this client has filter negation (retail 12.1: AuraUtil.
    -- AuraFilterNegationPrefix): every debuff not cast by you, your pet or vehicle - other
    -- players' DoTs as well as the mob's own. With "HARMFUL|PLAYER" next to it each debuff is in
    -- exactly one group. nil where the client lacks it.
    local NOT_MINE = "HARMFUL|!PLAYER"
    local function NotMineSupported()
        local U = _G.AuraUtil
        if type(U) ~= "table" or type(U.IsValidFilterString) ~= "function" then return false end
        local ok, valid = pcall(U.IsValidFilterString, NOT_MINE)
        return ok and valid == true
    end

    -- The groups each kind of frame gets, in layout order. mine = only your auras ("PLAYER");
    -- others = everyone else's ("!PLAYER"); grey = drawn desaturated. Up to 1.2.4 "others" was
    -- HARMFUL with the candidate filter isFromPlayerOrPlayerPet = false, but that flag is true
    -- for every player's aura, so it kept only the mob's own debuffs: another player's DoTs
    -- never showed. Where "!PLAYER" is missing, the two debuff groups become one plain HARMFUL
    -- group (all debuffs once, yours not set apart) rather than showing yours twice.
    local GROUPS = {
        player = {
            { key = "buffs", filter = "HELPFUL", max = 20, size = 20 },
        },
        target = {
            { key = "buffs", filter = "HELPFUL", max = 16, size = 18 },
            { key = "mine", filter = "HARMFUL|PLAYER", max = 16, size = 24, newLine = true, mine = true,
              border = { 0.9, 0.1, 0.1 } },
            { key = "debuffs", filter = NOT_MINE, max = 16, size = 18, others = true, grey = true,
              border = { 0.35, 0, 0 } },
        },
        party = {
            { key = "debuffs", filter = "HARMFUL", max = 8, size = 14, border = { 0.35, 0, 0 } },
            { key = "buffs", filter = "HELPFUL", max = 8, size = 12, newLine = true },
        },
    }

    -- The look of one button, made when the container creates it. It runs inside the client's
    -- securecallfunction, which would report an error but not hand it back, so it is a pcall.
    local function ButtonLook(g)
        return function(button)
            local ok, err = pcall(function()
                button:SetSize(g.size, g.size)
                local border = button:CreateTexture(nil, "BACKGROUND")
                border:SetPoint("TOPLEFT", -1, 1)
                border:SetPoint("BOTTOMRIGHT", 1, -1)
                local c = g.border or { 0, 0, 0 }
                SetSolid(border, c[1], c[2], c[3], 1)
                local tex = button:CreateTexture(nil, "ARTWORK")
                tex:SetAllPoints()
                tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                if g.grey then tex:SetDesaturated(true) end
                button:SetIcon(tex)
                local okCd, cd = pcall(CreateFrame, "Cooldown", nil, button, "CooldownFrameTemplate")
                if okCd and cd then
                    cd:SetAllPoints()
                    -- Our own time text below replaces the cooldown's big numbers.
                    if cd.SetHideCountdownNumbers then pcall(cd.SetHideCountdownNumbers, cd, true) end
                    if cd.SetDrawEdge then pcall(cd.SetDrawEdge, cd, false) end
                    if cd.SetReverse then pcall(cd.SetReverse, cd, true) end
                    button:SetDurationCooldown(cd)
                end
                local count = NewFont(button, 9)
                count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -1)
                button:SetApplicationCount(count)
            end)
            if not ok then
                containerInfo.buttonError = tostring(err)
                return
            end
            -- The time left under the icon: the client's duration binding writes it (secret or
            -- not) into our font string, through our rule formatter ("45", "9m", "1h") and the
            -- white/gold colour curve. Without them (or if the client refuses the options) the
            -- container's own formatter is used ("45s", "9m"). On its own, so a client without
            -- SetDurationText still gets the rest.
            local okTime, errTime = pcall(function()
                local tm = AuraTime.NewText(button, g.size)
                local fmt = AuraTime.Formatter()
                local opts
                if fmt then opts = { textFormatter = fmt, textColor = AuraTime.ColorOptions() } end
                local okOpts, errOpts = true, nil
                if opts then okOpts, errOpts = pcall(button.SetDurationText, button, tm, opts) end
                if not opts or not okOpts then
                    if errOpts then containerInfo.timeFormatError = tostring(errOpts) end
                    button:SetDurationText(tm)
                    containerInfo.timeFormat = "client default (45s, 9m)"
                else
                    containerInfo.timeFormat = "45 / 9m / 1h"
                end
            end)
            if okTime then
                containerInfo.timeText = true
            else
                containerInfo.timeError = tostring(errTime)
            end
        end
    end

    -- The container for one frame, or false where the client has none (or refuses it). Missing
    -- on this client is quiet (it shows in /bff status); a client that has the template but
    -- refuses our setup says so once in chat.
    -- The frame's groups as this client can draw them (see GROUPS).
    local function EffectiveGroups(key)
        local groups = GROUPS[key]
        if not groups then return nil end
        if containerInfo.notMine == nil then containerInfo.notMine = NotMineSupported() end
        if containerInfo.notMine then return groups end
        local out = {}
        for _, g in ipairs(groups) do
            if g.others then
                out[#out + 1] = { key = g.key, filter = "HARMFUL", max = g.max, size = 20, newLine = true,
                    border = g.border }
            elseif not g.mine then
                out[#out + 1] = g
            end
        end
        return out
    end

    local function BuildContainer(f)
        local groups = EffectiveGroups(f.key)
        if not groups or containerInfo.missing or containerInfo.failed then return false end
        local okMake, c = pcall(CreateFrame, "AuraContainer", nil, f, "CustomAuraContainerTemplate")
        if not okMake or type(c) ~= "table" or type(c.AddAuraGroup) ~= "function" then
            containerInfo.missing = okMake and "the frame has no AddAuraGroup" or tostring(c)
            return false
        end
        local ok, err = pcall(function()
            c:SetPoint("TOPLEFT", f.auraAnchor, "TOPLEFT", 0, 0)
            if type(c.SetFlowLayoutMaximumLineSize) == "function" then c:SetFlowLayoutMaximumLineSize(f.layout.w) end
            -- Room under each line for the time text of the frame's largest icons.
            local below = 0
            for _, g in ipairs(groups) do below = math.max(below, AuraTime.Below(g.size)) end
            for i, g in ipairs(groups) do
                c:AddAuraGroup(g.key, g.filter, {
                    maxFrameCount = g.max,
                    initializeFrame = ButtonLook(g),
                    layout = { elementSpacing = AuraTime.GAP, lineSpacing = below, groupSpacing = 4,
                        groupLineSpacing = below,
                        forceNewLine = g.newLine or nil, elementWidth = g.size, elementHeight = g.size,
                        layoutIndex = i },
                })
            end
            c:SetUnit(f.unit)
        end)
        if not ok then
            containerInfo.failed = tostring(err)
            pcall(c.Hide, c)
            Print("Blizzard's aura container refused this addon's setup, so auras are read by this addon"
                .. " (none while they are secret in combat). (" .. tostring(err) .. ")")
            return false
        end
        containerInfo.built = (containerInfo.built or 0) + 1
        return c
    end

    -- Buttons the container shows in one group: a number, or nil while that is hidden.
    function containerInfo.Shown(f, groupKey)
        local c = f.auraContainer
        if not c or type(c.GetAuraGroupFrame) ~= "function" then return nil end
        local ok, n = pcall(function()
            local count = 0
            for i = 1, 40 do
                local b = c:GetAuraGroupFrame(groupKey, i)
                if not b then break end
                local shown = b:IsShown()
                if IsSecret(shown) then return nil end
                if shown then count = count + 1 end
            end
            return count
        end)
        if ok then return n end
        return nil
    end

    -- -----------------------------------------------------------------------
    -- 2. Our own icons from index reads
    -- -----------------------------------------------------------------------

    local function SetAuraCooldown(icon, unit, a)
        local dur, exp = a.duration, a.expirationTime
        -- The time text only from plain values (out of combat); hidden timings get none.
        local fin
        if not Secret(dur, exp) and (Num(dur) or 0) > 0 and Num(exp) then fin = Num(exp) end
        AuraTime.SetEnd(icon, fin)
        local cd = icon.cd
        if not cd then return end
        if not Secret(dur, exp) then
            dur, exp = Num(dur), Num(exp)
            if dur and exp and dur > 0 then
                cd:SetCooldown(exp - dur, dur)
                cd:Show()
            else
                cd:Hide()
            end
            return
        end
        -- Hidden timings: the client's duration object, where it has one.
        local C = _G.C_UnitAuras
        local id = Plain(a.auraInstanceID)
        if id and type(C) == "table" and type(C.GetAuraDuration) == "function"
            and type(cd.SetCooldownFromDurationObject) == "function" then
            local ok, obj = pcall(C.GetAuraDuration, unit, id)
            if ok and obj ~= nil then
                cd:SetCooldownFromDurationObject(obj)
                cd:Show()
                return
            end
        end
        cd:Hide()
    end

    local function SetAuraCount(icon, unit, a)
        local count = a.applications
        if IsSecret(count) then
            local C = _G.C_UnitAuras
            local id = Plain(a.auraInstanceID)
            if id and type(C) == "table" and type(C.GetAuraApplicationDisplayCount) == "function" then
                local ok, txt = pcall(C.GetAuraApplicationDisplayCount, unit, id, 2, 99)
                if ok then SetTextSafe(icon.count, txt); return end
            end
            icon.count:SetText("")
            return
        end
        local cnt = Num(count)
        icon.count:SetText((cnt and cnt > 1) and tostring(cnt) or "")
    end

    local function PaintAura(f, icon, row, a, index)
        local u = f.unit
        icon.unit, icon.index, icon.filter, icon.auraInstanceID = u, index, row.filter, a.auraInstanceID
        if IsSecret(a.icon) then icon.tex:SetTexture(a.icon) else icon.tex:SetTexture(a.icon or QUESTION) end
        local own
        if row.own then own = OwnAura(a) end
        icon.tex:SetDesaturated(row.own ~= nil and own == false)
        if row.filter == "HARMFUL" then
            local dt = Plain(a.dispelName)
            local c = type(dt) == "string" and type(_G.DebuffTypeColor) == "table" and _G.DebuffTypeColor[dt]
            if own == true and type(c) == "table" then SetSolid(icon.border, c.r, c.g, c.b, 1)
            elseif own == true then SetSolid(icon.border, 0.9, 0.1, 0.1, 1)
            elseif type(c) == "table" then SetSolid(icon.border, c.r * 0.7, c.g * 0.7, c.b * 0.7, 1)
            else SetSolid(icon.border, 0.35, 0, 0, 1) end
        else
            SetSolid(icon.border, 0, 0, 0, 1)
        end
        SetAuraCount(icon, u, a)
        SetAuraCooldown(icon, u, a)
        icon:Show()
        return (own == true) and row.own or row.size
    end

    local function OwnIcons(f)
        local rows = AURAS[f.key]
        local u, icons, width = f.unit, f.auraIcons, f.layout.w
        local n, x, y, rowH = 0, 0, 0, 0
        f.auraShown = f.auraShown or {}
        f.auraPath = "index"
        for _, row in ipairs(rows) do
            if x > 0 then x = 0; y = y - rowH - AuraTime.Below(rowH); rowH = 0 end
            local shown = 0
            for i = 1, 40 do
                if shown >= row.max then break end
                local a = IndexAura(u, i, row.filter)
                if a == false then f.auraPath = "index (refused: auras secret)"; break end
                if not a then break end
                local icon = icons[n + 1]
                if not icon then icon = NewAuraIcon(f); icons[n + 1] = icon end
                local ok, size = pcall(PaintAura, f, icon, row, a, i)
                if ok then
                    if x > 0 and x + size > width then x = 0; y = y - rowH - AuraTime.Below(rowH); rowH = 0 end
                    AuraTime.Size(icon, size)
                    icon:ClearAllPoints()
                    icon:SetPoint("TOPLEFT", f.auraAnchor, "TOPLEFT", x, y)
                    x = x + size + AuraTime.GAP
                    if size > rowH then rowH = size end
                    n = n + 1
                    shown = shown + 1
                else
                    auraStats.paintFailed = auraStats.paintFailed + 1
                    auraStats.lastError = tostring(size)
                    icon:Hide()
                end
            end
            f.auraShown[row.filter] = shown
        end
        for i = n + 1, #icons do icons[i]:Hide() end
    end

    -- Shows or hides a frame's container. It is a plain (not protected) child of our frame, so
    -- this is allowed in combat; SetEnabled also stops its aura events while it is off. The
    -- state is kept on our frame: the container's own table belongs to the client.
    local function SetContainerShown(f, on)
        local c = f.auraContainer
        if f.auraContainerShown == on then return end
        f.auraContainerShown = on
        if type(c.SetEnabled) == "function" then pcall(c.SetEnabled, c, on) end
        pcall(on and c.Show or c.Hide, c)
    end

    -- The player's buffs are drawn only with the playerBuffs option on, and not in test mode:
    -- made-up icons sit in their place then, and test mode owns the player's aura icons.
    local function Wanted(f)
        if f.key ~= "player" then return true end
        return db.playerBuffs and not testing
    end

    -- Has the container rebuild its list from the unit's current auras. It follows the unit's
    -- UNIT_AURA events by itself, but those only add, change and remove single auras: when the
    -- unit token points at someone else (a new target, a party slot after a roster change) it
    -- gets no event and keeps the previous unit's auras, buffs and debuffs both, until it is
    -- hidden. Blizzard's own target frame calls UpdateAllAuras on PLAYER_TARGET_CHANGED for the
    -- same reason. A client without it gets a hide and show, which rebuild it too.
    local function RebuildContainer(f)
        local c = f.auraContainer
        if type(c.UpdateAllAuras) == "function" then
            local ok = pcall(c.UpdateAllAuras, c)
            if ok then return end
        end
        pcall(c.Hide, c)
        pcall(c.Show, c)
    end

    -- full: the frame's unit may be someone else now (UpdateFrame), not just an aura event.
    UpdateAuras = function(f, full)
        if not AURAS[f.key] or not f.auraIcons then return end
        local wanted = Wanted(f)
        if f.auraContainer then SetContainerShown(f, wanted) end
        if not wanted then
            f.auraPath = testing and "test mode" or "off (/bff playerbuffs on)"
            if not testing then for _, icon in ipairs(f.auraIcons) do icon:Hide() end end
            return
        end
        if f.auraContainer == nil then
            f.auraContainer = BuildContainer(f)
            f.auraContainerShown = f.auraContainer and true or nil
        end
        if f.auraContainer then
            -- The client draws them; it follows the unit and its aura events itself.
            f.auraPath = "Blizzard aura container"
            if full then RebuildContainer(f) end
            for _, icon in ipairs(f.auraIcons) do icon:Hide() end
            return
        end
        OwnIcons(f)
    end
end

local function UpdateRange(f)
    if f.preview or testing or editFaded then return end
    local u = f.unit
    if type(_G.UnitInRange) == "function" then
        local inRange, checked = _G.UnitInRange(u)
        if Secret(inRange, checked) then
            -- The client's boolean goes straight to the widget where it can take one.
            if IsSecret(inRange) and type(f.SetAlphaFromBoolean) == "function" then
                f:SetAlphaFromBoolean(inRange, 1, OUT_OF_RANGE)
            else
                f:SetAlpha(1)
            end
            return
        end
        if checked and not inRange then f:SetAlpha(OUT_OF_RANGE) else f:SetAlpha(1) end
        return
    end
    if type(_G.CheckInteractDistance) == "function" then
        -- Retail-shaped clients refuse it in combat: the last answer stands until then.
        if InCombat() then return end
        local ok, near = pcall(_G.CheckInteractDistance, u, 4)
        if not ok then near = _G.CheckInteractDistance(UnitGUID(u), 4) end
        near = Plain(near)
        if near == nil then f:SetAlpha(1) else f:SetAlpha(near and 1 or OUT_OF_RANGE) end
        return
    end
    f:SetAlpha(1)
end

local function UpdateCombo(f)
    if not f.combo then return end
    local n = 0
    if comboClass and Plain(UnitExists("target")) == true then
        local v
        if type(_G.GetComboPoints) == "function" then
            v = _G.GetComboPoints("player", "target")
        elseif type(_G.Enum) == "table" and type(_G.Enum.PowerType) == "table" and _G.Enum.PowerType.ComboPoints then
            v = UnitPower("player", _G.Enum.PowerType.ComboPoints)
        end
        n = Num(v) or 0
    end
    for i = 1, 5 do
        if i <= n then f.combo[i]:Show() else f.combo[i]:Hide() end
    end
end

-- Everything on one frame. Each part is its own latch.
UpdateFrame = function(f)
    if not db or f.preview then return end
    if Plain(UnitExists(f.unit)) ~= true then return end
    Run("health", UpdateHealth, f)
    Run("healpred", HealPred.Update, f)
    Run("power", UpdatePower, f)
    if f.mana then Run("mana", Mana.Update, f) end
    Run("name", UpdateName, f)
    Run("portrait", UpdatePortrait, f)
    Run("icons", UpdateIcons, f)
    Run("threat", UpdateThreat, f)
    if f.auraIcons then Run("auras", UpdateAuras, f, true) end
    if f.key == "party" then Run("range", UpdateRange, f) end
    if f.combo then Run("combo", UpdateCombo, f) end
end

local function Visible(f)
    return f and not f.preview and f:IsVisible() and true or false
end

local function UpdateUnit(unit)
    local f = real[unit]
    if Visible(f) then UpdateFrame(f) end
end

local function UpdateAllFrames()
    for _, f in pairs(real) do
        if Visible(f) then UpdateFrame(f) end
    end
end

-- One feature on every shown frame (raid icons, leader, threat).
local function UpdateEach(feature, fn)
    for _, f in pairs(real) do
        if Visible(f) then Run(feature, fn, f) end
    end
end

-- ---------------------------------------------------------------------------
-- Position and scale
-- ---------------------------------------------------------------------------

local function ScaleOf(key)
    return Num(db.scales[key]) or 1
end

-- The frames of one key in one set (real or previews), in unit order.
local function FramesOf(key, set)
    local list = {}
    for _, u in ipairs(UNITS_OF[key]) do
        if set[u] then list[#list + 1] = set[u] end
    end
    return list
end

local function Head(key, set)
    return set[UNITS_OF[key][1]]
end

-- UIParent's size in its own units, or nil when it will not say.
local function ParentSize()
    local parent = _G.UIParent
    local ok, w, h = pcall(function() return parent:GetWidth(), parent:GetHeight() end)
    if not ok then return nil end
    w, h = Num(w), Num(h)
    if w and h then return w, h end
end

-- Where a key's head frame has its top-left corner by its own saved (or default) position, in
-- UIParent units from UIParent's bottom-left. Used for the offset of pet and target of target.
local function OwnTopLeft(key)
    local L, s = LAYOUT[key], ScaleOf(key)
    local uw, uh = ParentSize()
    if not uh then return nil end
    local p = db.positions[key]
    if p then
        return uw / 2 + p.x - L.w * s / 2, uh / 2 + p.y + FrameHeight(L) * s / 2
    end
    local d = DEFAULT_POS[key]
    return d[1], uh + d[2]
end

-- Where a key's head frame goes while following Edit Mode, or nil for its own position: the
-- top-left of Blizzard's frame as last read, or for pet and target of target their own offset
-- from player and target added to where those follow.
local function FollowTopLeft(key)
    if not Followed(key) then return nil end
    if FOLLOW_SOURCE[key] then
        local r = followPos[key]
        if r then return r.x, r.y end
        return nil
    end
    local pk = FOLLOW_PARENT[key]
    local r = followPos[pk]
    if not r then return nil end
    local ox, oy = OwnTopLeft(key)
    local px, py = OwnTopLeft(pk)
    if not (ox and px) then return nil end
    return r.x + ox - px, r.y + oy - py
end

local function PlaceSet(key, set)
    local s = ScaleOf(key)
    local parent = _G.UIParent
    local prev
    local fx, fy = FollowTopLeft(key)
    for i, u in ipairs(UNITS_OF[key]) do
        local f = set[u]
        if f then
            -- Placed by Edit Mode: not dragged, and no "unlocked" border.
            f.followed = fx ~= nil
            ApplyBorder(f)
            f:SetScale(s)
            f:ClearAllPoints()
            if i == 1 then
                local p = db.positions[key]
                if fx then
                    f:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", fx / s, fy / s)
                elseif p then
                    f:SetPoint("CENTER", parent, "CENTER", p.x / s, p.y / s)
                else
                    local d = DEFAULT_POS[key]
                    f:SetPoint("TOPLEFT", parent, "TOPLEFT", d[1] / s, d[2] / s)
                end
            elseif prev then
                f:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -PARTY_GAP)
            end
            prev = f
        end
    end
end

-- Places and scales a key's frames: the previews at once, the secure ones out of combat.
-- Pet and target of target follow player and target, so they are placed again with them.
local function ApplyLayout(key)
    PlaceSet(key, previews)
    OutOfCombat("layout:" .. key, function() PlaceSet(key, real) end)
    local child = FOLLOW_CHILD[key]
    if child and Followed(child) then ApplyLayout(child) end
end

local function ApplyAllLayouts()
    for _, key in ipairs(KEYS) do ApplyLayout(key) end
end

-- Saves where a key's head frame now is, as an offset of its centre from UIParent's centre in
-- UIParent units. Every number is checked first: a secret written to SavedVariables comes back
-- as nil. Returns true when it was saved.
local function SavePosition(key, f)
    local parent = _G.UIParent
    local ok, x, y = pcall(function()
        local cx, cy = f:GetCenter()
        local ux, uy = parent:GetCenter()
        local s, ps = f:GetEffectiveScale(), parent:GetEffectiveScale()
        if Secret(cx, cy) or Secret(ux, uy) or Secret(s, ps) then return nil end
        cx, cy, ux, uy, s, ps = Num(cx), Num(cy), Num(ux), Num(uy), Num(s), Num(ps)
        if not (cx and cy and ux and uy and s and ps) or ps <= 0 then return nil end
        return cx * s / ps - ux, cy * s / ps - uy
    end)
    if not ok or not (Num(x) and Num(y)) then
        Print("this client will not report where the " .. LABEL[key] .. " frame is, so it was not saved.")
        return false
    end
    db.positions[key] = { x = math.floor(x * 10 + 0.5) / 10, y = math.floor(y * 10 + 0.5) / 10 }
    return true
end

StartDrag = function(self)
    if not db or db.locked or InCombat() then return end
    local set = self.preview and previews or real
    local head = Head(self.key, set) or self
    -- A frame placed by Edit Mode stays there; dragging it would only fight that.
    if head.followed then return end
    self.dragging = head
    head:StartMoving()
end

StopDrag = function(self)
    local head = self.dragging
    if not head then return end
    self.dragging = nil
    head:StopMovingOrSizing()
    pcall(head.SetUserPlaced, head, false)
    SavePosition(self.key, head)
    ApplyLayout(self.key)
end

-- Combat is about to start: a drag in progress is ended and saved while that is still allowed.
local function EndDrags()
    for _, f in ipairs(AllFrames()) do
        if f.dragging then pcall(StopDrag, f) end
    end
end

-- ---------------------------------------------------------------------------
-- Blizzard's unit frames: switched off the oUF way, out of combat only
-- ---------------------------------------------------------------------------

local function HiddenParent()
    if not hiddenParent then
        hiddenParent = CreateFrame("Frame", "BetterFramesForeverHiddenParent", _G.UIParent)
        hiddenParent:SetAllPoints()
        hiddenParent:Hide()
    end
    return hiddenParent
end

-- UnregisterAllEvents, Hide and re-parent to our hidden frame; the bars and sub-frames lose
-- their events too. Party member frames from the pool are not re-parented (as in oUF): their
-- parent PartyFrame is.
local function DisableFrame(frame, label, noReparent)
    if type(frame) ~= "table" or type(frame.UnregisterAllEvents) ~= "function" then return end
    frame:UnregisterAllEvents()
    frame:Hide()
    if not noReparent then
        local p = frame:GetParent()
        if p ~= HiddenParent() then origParent[frame] = p end
        frame:SetParent(HiddenParent())
    end
    for _, k in ipairs({ "healthbar", "healthBar", "HealthBar", "manabar", "ManaBar", "spellbar",
        "castBar", "CastingBarFrame", "powerBarAlt", "PowerBarAlt", "BuffFrame", "DebuffFrame",
        "totFrame", "PetFrame", "classPowerBar", "CcRemoverFrame" }) do
        local sub = frame[k]
        if type(sub) == "table" and type(sub.UnregisterAllEvents) == "function" then
            pcall(sub.UnregisterAllEvents, sub)
        end
    end
    hiddenBlizz[frame] = noReparent and true or false
    hiddenNames[label] = true
end

local function DisableBlizzardParty()
    local pf = _G.PartyFrame
    if type(pf) == "table" then
        DisableFrame(pf, "PartyFrame")
        for i = 1, 4 do
            local m = pf["MemberFrame" .. i]
            if type(m) == "table" then DisableFrame(m, "PartyFrame.MemberFrame" .. i, true) end
        end
        local pool = pf.PartyMemberFramePool
        if type(pool) == "table" and type(pool.EnumerateActive) == "function" then
            for m in pool:EnumerateActive() do DisableFrame(m, "PartyFrame member", true) end
        end
    end
    for i = 1, 4 do
        local m = _G["PartyMemberFrame" .. i]
        if type(m) == "table" then DisableFrame(m, "PartyMemberFrame" .. i) end
    end
end

local function DisableBlizzard(key)
    if blocked.blizzard then return end
    local ok, err = pcall(function()
        if key == "party" then
            DisableBlizzardParty()
        else
            for _, name in ipairs(BLIZZARD[key] or {}) do DisableFrame(_G[name], name) end
        end
    end)
    if not ok then Latch("blizzard", err) end
end

-- After Edit Mode or a loading screen: anything Blizzard put back is parked again. If that
-- itself fails, hiding is switched off for the session with one line, not retried. A frame we
-- gave back to Blizzard for Edit Mode is left out until Edit Mode closes.
local function RecheckBlizzard()
    if blocked.blizzard or InCombat() or not hiddenParent then return end
    local back = {}
    for _, bf in pairs(restored) do back[bf] = true end
    local ok, err = pcall(function()
        for frame, noReparent in pairs(hiddenBlizz) do
            -- Party member frames are not re-parented: they live under PartyFrame.
            local skip = back[frame] or (noReparent and restored.party ~= nil)
            if not skip then
                if not noReparent and frame:GetParent() ~= hiddenParent then
                    frame:SetParent(hiddenParent)
                end
                if frame:IsShown() then frame:Hide() end
            end
        end
    end)
    if not ok then Latch("blizzard", err) end
end

-- ---------------------------------------------------------------------------
-- Switching frames on and off (secure: out of combat only)
-- ---------------------------------------------------------------------------

local function EnableKey(key)
    if unsupported or blocked.frames or not HasKey(key) then return end
    local ok, err = pcall(function()
        for _, u in ipairs(UNITS_OF[key]) do
            if not real[u] then real[u] = Build(key, u, false) end
            local f = real[u]
            if key == "player" then f:Show() else _G.RegisterUnitWatch(f) end
        end
    end)
    if not ok then Latch("frames", err); return end
    enabledNow[key] = true
    PlaceSet(key, real)
    DisableBlizzard(key)
    for _, u in ipairs(UNITS_OF[key]) do UpdateUnit(u) end
end

local function DisableKey(key)
    for _, u in ipairs(UNITS_OF[key]) do
        local f = real[u]
        if f then
            if key ~= "player" and type(_G.UnregisterUnitWatch) == "function" then _G.UnregisterUnitWatch(f) end
            f:Hide()
        end
        if previews[u] then previews[u]:Hide() end
    end
    enabledNow[key] = nil
end

local function CountEnabled()
    local n = 0
    for _, key in ipairs(KEYS) do
        if HasKey(key) and db.frames[key] then n = n + 1 end
    end
    return n
end

local function Start()
    if started or not db then return end
    if type(_G.RegisterUnitWatch) ~= "function" then
        unsupported = "RegisterUnitWatch is missing"
    end
    if unsupported then
        Print("this client cannot have secure unit frames (" .. unsupported .. "); Blizzard's frames are left as they are.")
        return
    end
    OutOfCombat("start", function()
        if started then return end
        started = true
        for _, key in ipairs(KEYS) do
            if db.frames[key] then EnableKey(key) end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Test mode: non-secure preview frames with made-up data, out of combat only
-- ---------------------------------------------------------------------------

local FAKE = {
    -- The player frame is the real one in test mode; only its buffs are made up. { icon, own,
    -- { seconds gone, duration } } - the last for a cooldown swipe.
    player = { buffs = {
        { "Interface\\Icons\\Spell_Nature_Regeneration", nil, { 600, 1800 } },
        { "Interface\\Icons\\Spell_Holy_WordFortitude", nil, { 300, 1800 } },
        { "Interface\\Icons\\Spell_Holy_MagicalSentry", nil, { 1500, 1800 } },
        { "Interface\\Icons\\Spell_Holy_FistOfJustice", nil, { 100, 300 } },
        "Interface\\Icons\\Spell_Holy_DivineSpirit",
        { "Interface\\Icons\\Spell_Nature_Thorns", nil, { 400, 600 } },
        { "Interface\\Icons\\Spell_Nature_Rejuvenation", nil, { 4, 12 } },
        { "Interface\\Icons\\Spell_Holy_PowerWordShield", nil, { 20, 30 } },
        "Interface\\Icons\\Spell_Shadow_AntiShadow",
        "Interface\\Icons\\Spell_Nature_ResistNature",
        { "Interface\\Icons\\Spell_Nature_LightningShield", nil, { 60, 600 } },
        "Interface\\Icons\\Spell_Holy_SealOfWisdom",
    } },
    target = { name = "Defias Pillager", level = 18, kind = "elite", hp = { 2400, 3300 }, heal = { 300, 200, 250, 150 },
        power = { 900, 1200, "MANA" }, reaction = Look.HOSTILE, combo = 3,
        buffs = { { "Interface\\Icons\\Spell_Holy_WordFortitude", nil, { 300, 1800 } },
                  { "Interface\\Icons\\Spell_Nature_Regeneration", nil, { 1500, 1800 } } },
        debuffs = { { "Interface\\Icons\\Spell_Shadow_ShadowWordPain", true, { 6, 18 } },
                    { "Interface\\Icons\\Ability_Rogue_Garrote", true, { 3, 18 } },
                    { "Interface\\Icons\\Spell_Frost_FrostNova", false, { 2, 8 } } } },
    targettarget = { name = "Gaar", level = 60, class = "WARRIOR", hp = { 4100, 5200 }, power = { 30, 100, "RAGE" } },
    focus = { name = "Hogger", level = 11, kind = "rare", hp = { 600, 666 }, power = { 0, 0 },
        reaction = Look.HOSTILE },
    pet = { name = "Wolf", level = 58, hp = { 800, 1000 }, power = { 70, 100, "FOCUS" }, reaction = Look.FRIENDLY },
    party1 = { name = "Thrall", level = 60, class = "SHAMAN", hp = { 3900, 4200 }, power = { 3100, 4000, "MANA" }, leader = true,
        buffs = { { "Interface\\Icons\\Spell_Holy_WordFortitude", nil, { 900, 1800 } } } },
    party2 = { name = "Jaina", level = 60, class = "MAGE", hp = { 1100, 3600 }, power = { 2500, 5200, "MANA" },
        heal = { 500, 400, 600, 700 },   -- your heal, others' heals, absorb shield, HoTs (heal prediction)
        debuffs = { { "Interface\\Icons\\Spell_Shadow_CurseOfTounges", nil, { 10, 120 } } } },
    party3 = { name = "Uther", level = 60, class = "PALADIN", hp = { 600, 4800 }, power = { 1800, 4300, "MANA" }, far = true },
    party4 = { name = "Tyrande", level = 60, class = "PRIEST", hp = { 3500, 3500 }, power = { 4700, 5000, "MANA" } },
}

-- Made-up aura icons from d.buffs and d.debuffs, in the frame's rows, wrapping at its width.
local function FakeAuras(f, d)
    local n, x, y, rowH = 0, 0, 0, 0
    local rows = AURAS[f.key]
    local width = f.layout.w
    local lists = { d.buffs or {}, d.debuffs or {} }
    if rows[1].filter == "HARMFUL" then lists = { d.debuffs or {}, d.buffs or {} } end
    local now = type(_G.GetTime) == "function" and _G.GetTime() or nil
    for ri, row in ipairs(rows) do
        if x > 0 then x = 0; y = y - rowH - AuraTime.Below(rowH); rowH = 0 end
        for k, item in ipairs(lists[ri]) do
            if k > row.max then break end
            n = n + 1
            local icon = f.auraIcons[n]
            if not icon then icon = NewAuraIcon(f); f.auraIcons[n] = icon end
            local path, own, cd = item, nil, nil
            if type(item) == "table" then path, own, cd = item[1], item[2], item[3] end
            local size = (own and row.own) or row.size
            if x > 0 and x + size > width then x = 0; y = y - rowH - AuraTime.Below(rowH); rowH = 0 end
            AuraTime.Size(icon, size)
            icon:ClearAllPoints()
            icon:SetPoint("TOPLEFT", f.auraAnchor, "TOPLEFT", x, y)
            x = x + size + AuraTime.GAP
            if size > rowH then rowH = size end
            icon.tex:SetTexture(path)
            icon.tex:SetDesaturated(row.own ~= nil and own == false)
            SetSolid(icon.border, own and 0.9 or 0, 0.1, 0.1, 1)
            icon.count:SetText("")
            if icon.cd then
                if cd and now then icon.cd:SetCooldown(now - cd[1], cd[2]); icon.cd:Show()
                else icon.cd:Hide() end
            end
            AuraTime.SetEnd(icon, (cd and now) and (now - cd[1] + cd[2]) or nil)
            icon.unit = nil
            icon:Show()
        end
    end
    for i = n + 1, #f.auraIcons do f.auraIcons[i]:Hide() end
end

local function FillFake(f)
    local d = FAKE[f.unit]
    if not d then return end
    local hp, mx = d.hp[1], d.hp[2]
    f.health:SetMinMaxValues(0, mx)
    f.health:SetValue(hp)
    local pct = hp / mx
    local r, g, b
    if db.lowhp and pct < CRIT_HP then r, g, b = Look.CRIT[1], Look.CRIT[2], Look.CRIT[3]
    elseif db.lowhp and pct < LOW_HP then r, g, b = Look.LOW[1], Look.LOW[2], Look.LOW[3]
    elseif d.class then
        if db.classColor then r, g, b = ClassRGB(d.class) end
        if not r then r, g, b = Look.FRIENDLY[1], Look.FRIENDLY[2], Look.FRIENDLY[3] end
    else
        r, g, b = d.reaction[1], d.reaction[2], d.reaction[3]
    end
    Look.SetBarColor(f.health, r, g, b)
    if db.text then PlainText(f, f.health, hp, mx) else f.health.text:SetText("") end
    HealPred.Fake(f, d, mx)
    local pc, pm, token = d.power[1], d.power[2], d.power[3]
    SetPowerShown(f, pm > 0)
    f.power:SetMinMaxValues(0, pm > 0 and pm or 1)
    f.power:SetValue(pc)
    local pr, pg, pb = PowerRGB(token)
    Look.SetBarColor(f.power, pr, pg, pb)
    if f.power.text then
        if db.text and pm > 0 then PlainText(f, f.power, pc, pm) else f.power.text:SetText("") end
    end

    f.nameText:SetText(d.name)
    local cr, cg, cb
    if d.class and db.classColor then cr, cg, cb = ClassRGB(d.class) end
    f.nameText:SetTextColor(cr or 1, cg or 1, cb or 1)
    f.levelText:SetText(tostring(d.level))
    f.levelText:SetTextColor(LevelRGB(d.level))
    local coords = d.class and type(_G.CLASS_ICON_TCOORDS) == "table" and _G.CLASS_ICON_TCOORDS[d.class]
    if type(coords) == "table" then
        f.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        f.classIcon:Show()
    else
        f.classIcon:Hide()
    end
    f.tagText:SetText(d.kind and not f.layout.compact and TAGS[d.kind] or "")
    f.eliteKind = d.kind and ELITE_KIND[d.kind] or nil

    if f.portraitTex then
        if d.class and type(coords) == "table" then
            f.portraitTex:SetTexture(CLASS_ICONS)
            f.portraitTex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        else
            f.portraitTex:SetTexture(QUESTION)
            f.portraitTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end
    if f.leaderIcon then if d.leader then f.leaderIcon:Show() else f.leaderIcon:Hide() end end
    if f.combo then
        for i = 1, 5 do if comboClass and i <= d.combo then f.combo[i]:Show() else f.combo[i]:Hide() end end
    end
    f:SetAlpha(d.far and OUT_OF_RANGE or 1)

    if f.auraIcons then FakeAuras(f, d) end
    ApplyBorder(f)
end

-- The player frame stays the real one in test mode: its own buffs make way (UpdateAuras holds
-- them back while testing) for made-up ones, so the row under it can be placed. None with the
-- option off.
local function FakePlayerBuffs()
    local p = real.player
    if not (p and p.auraIcons and enabledNow.player) then return end
    Run("auras", UpdateAuras, p)
    FakeAuras(p, db.playerBuffs and FAKE.player or {})
end

-- The real frames of every key but the player go see-through (alpha only, which combat allows,
-- and no attribute is touched) while the previews sit on top of them.
local function ShowPreviews()
    for _, key in ipairs(KEYS) do
        if key ~= "player" and enabledNow[key] then
            for _, u in ipairs(UNITS_OF[key]) do
                if not previews[u] then previews[u] = Build(key, u, true) end
                previews[u]:SetFrameStrata("MEDIUM")
                FillFake(previews[u])
                previews[u]:Show()
                if real[u] then real[u]:SetAlpha(0) end
            end
            PlaceSet(key, previews)
        end
    end
    FakePlayerBuffs()
end

local function HidePreviews()
    for _, f in pairs(previews) do f:Hide() end
    for u, f in pairs(real) do
        if KEY_OF[u] ~= "player" then f:SetAlpha(1) end
    end
    -- The player's made-up buffs go; its real ones come back (testing is already off here).
    local p = real.player
    if p and p.auraIcons then
        for _, icon in ipairs(p.auraIcons) do icon:Hide() end
        Run("auras", UpdateAuras, p)
    end
end

local function SetTesting(on, quiet)
    on = on and true or false
    if on and InCombat() then
        Print("test mode only out of combat.")
        return
    end
    if on and not started then
        Print("the frames are not built yet.")
        return
    end
    if on and editFaded then
        Print("test mode is off while Edit Mode is open.")
        return
    end
    testing = on
    if on then
        local ok, err = pcall(ShowPreviews)
        if not ok then
            testing = false
            pcall(HidePreviews)
            Print("test mode failed: " .. tostring(err))
            return
        end
        if not quiet then
            Print("test mode on: every enabled frame shows made-up data"
                .. (db.locked and " - /bff unlock to drag them." or " - drag them into place.")
                .. " /bff test again to stop.")
        end
    else
        HidePreviews()
        UpdateAllFrames()
        if not quiet then Print("test mode off.") end
    end
end

-- ---------------------------------------------------------------------------
-- Follow Blizzard Edit Mode (option, off by default)
--
-- Blizzard's PlayerFrame, TargetFrame, FocusFrame and PartyFrame stay parked the oUF way; ours
-- copy their place. Nothing is anchored to Blizzard's frames: their top-left corner is read
-- (GetLeft / GetTop x their effective scale / UIParent's), checked for secrets, and our frame
-- gets a TOPLEFT point on UIParent at that spot, with our own scale and size.
--
-- While Edit Mode is open, Blizzard's frames are given back (re-parented to where they were and
-- shown, out of combat) so they can be dragged there, and ours go see-through with the mouse off.
-- Their events stay unregistered: Edit Mode drags the frame and its selection box, which needs no
-- events (party member frames are set up again by PartyFrame's own OnShow). When Edit Mode closes
-- the new place is read, Blizzard's frames are parked again exactly as at login, and ours move.
-- ---------------------------------------------------------------------------

local Refollow, HookEditMode, FollowReport, SetFollow

do
    -- Reads the top-left of each Blizzard frame we follow. A missing frame or a secret or missing
    -- number leaves the last good reading in place (or our own position); an error switches following
    -- off for the session with one line.
    local function ReadBlizzardPositions()
        if not FollowOn() then return end
        local ok, err = pcall(function()
            local parent = _G.UIParent
            local ps = parent:GetEffectiveScale()
            ps = Num(ps)
            for key, name in pairs(FOLLOW_SOURCE) do
                local bf = _G[name]
                local x, y
                if type(bf) == "table" and type(bf.GetLeft) == "function" and ps and ps > 0 then
                    local l, t, sc = bf:GetLeft(), bf:GetTop(), bf:GetEffectiveScale()
                    if not Secret(l, t) and not IsSecret(sc) then
                        l, t, sc = Num(l), Num(t), Num(sc)
                        if l and t and sc then x, y = l * sc / ps, t * sc / ps end
                    end
                end
                if x then
                    followPos[key] = { x = x, y = y }
                    followMiss[key] = nil
                else
                    followMiss[key] = type(bf) == "table" and "will not report where it is" or "missing"
                end
            end
        end)
        if not ok then Latch("editmode", err) end
    end

    -- Read and place everything again; once more on the next frame, after Blizzard's own layout.
    Refollow = function()
        ReadBlizzardPositions()
        ApplyAllLayouts()
        local T = _G.C_Timer
        if type(T) == "table" and type(T.After) == "function" then
            T.After(0, function()
                if FollowOn() and not editOpen then
                    ReadBlizzardPositions()
                    ApplyAllLayouts()
                end
            end)
        end
    end

    -- See-through (alpha, allowed in combat) for every frame that follows, mouse off out of combat
    -- so Edit Mode gets the clicks. Back on: every frame, whether it still follows or not.
    local function FadeForEditMode(on)
        editFaded = on and true or false
        for u, f in pairs(real) do
            local key = KEY_OF[u]
            if not on then
                f:SetAlpha(1)
                if key == "party" and Visible(f) then Run("range", UpdateRange, f) end
            elseif f.followed then
                f:SetAlpha(0)
            end
        end
        OutOfCombat("editmouse", function()
            for _, f in pairs(real) do
                f:EnableMouse(not (editFaded and f.followed))
            end
        end)
    end

    -- Out of combat: Blizzard's frames for the keys we draw go back to their own parent and show.
    local function GiveBackForEditMode()
        if blocked.blizzard or blocked.editmode or not hiddenParent then return end
        local ok, err = pcall(function()
            for key, name in pairs(FOLLOW_SOURCE) do
                local bf = enabledNow[key] and _G[name]
                if type(bf) == "table" and hiddenBlizz[bf] ~= nil and not restored[key] then
                    restored[key] = bf
                    if bf:GetParent() == hiddenParent then bf:SetParent(origParent[bf] or _G.UIParent) end
                    bf:Show()
                end
            end
        end)
        if not ok then
            -- Following is off now: ours back to their own place, visible.
            Latch("editmode", err)
            FadeForEditMode(false)
            ApplyAllLayouts()
        end
    end

    local function StartEditModeFollow()
        if not FollowOn() or not started then return end
        if testing then SetTesting(false, true) end
        EndDrags()
        FadeForEditMode(true)
        OutOfCombat("editmode", GiveBackForEditMode)
    end

    -- Edit Mode closed (or following switched off): read where Blizzard's frames now are, park them
    -- the oUF way again, and put ours in place. force: place them even if nothing was given back.
    local function EndEditModeFollow(force)
        if not force and not FollowOn() and not next(restored) and not editFaded then return end
        ReadBlizzardPositions()
        OutOfCombat("editmode", function()
            local keys = restored
            restored = {}
            for key in pairs(keys) do DisableBlizzard(key) end
            ApplyAllLayouts()
        end)
        if editFaded then FadeForEditMode(false) end
    end

    local function OnEditModeEnter()
        editOpen = true
        local ok, err = pcall(StartEditModeFollow)
        if not ok then Latch("editmode", err) end
    end

    local function OnEditModeExit()
        editOpen = false
        local ok, err = pcall(EndEditModeFollow)
        if not ok then Latch("editmode", err) end
    end

    -- Blizzard's own callbacks, never a replaced function: EventRegistry "EditMode.Enter" / "Exit",
    -- or HookScript on EditModeManagerFrame where EventRegistry is missing.
    HookEditMode = function()
        if editHooked then return end
        local reg = _G.EventRegistry
        if type(reg) == "table" and type(reg.RegisterCallback) == "function" then
            local ok1 = pcall(reg.RegisterCallback, reg, "EditMode.Enter", OnEditModeEnter, editOwner)
            local ok2 = pcall(reg.RegisterCallback, reg, "EditMode.Exit", OnEditModeExit, editOwner)
            if ok1 or ok2 then editHooked = "EventRegistry"; return end
        end
        local em = _G.EditModeManagerFrame
        if type(em) == "table" and type(em.HookScript) == "function" then
            local ok1 = pcall(em.HookScript, em, "OnShow", OnEditModeEnter)
            local ok2 = pcall(em.HookScript, em, "OnHide", OnEditModeExit)
            if ok1 or ok2 then editHooked = "EditModeManagerFrame" end
        end
    end

    -- Which followed frames sit at Blizzard's place, and which at their own (and why).
    FollowReport = function()
        local at, own = {}, {}
        for _, key in ipairs(KEYS) do
            if HasKey(key) and Followed(key) then
                local src = FOLLOW_SOURCE[key] and key or FOLLOW_PARENT[key]
                if followPos[src] then at[#at + 1] = key
                else own[#own + 1] = key .. " (" .. FOLLOW_SOURCE[src] .. " " .. (followMiss[src] or "not read yet") .. ")" end
            end
        end
        return at, own
    end

    SetFollow = function(on)
        db.followEditMode = on and true or false
        if db.followEditMode and blocked.editmode then
            Print("this client refused following Edit Mode earlier this session; it stays off until /reload.")
            return
        end
        if not started then
            Print("follow Blizzard Edit Mode: " .. OnOff(db.followEditMode) .. ".")
            return
        end
        if db.followEditMode then
            EndDrags()
            if editOpen or EditModeActive() then
                editOpen = true
                StartEditModeFollow()
            else
                Refollow()
            end
        else
            EndEditModeFollow(true)
        end
        for _, f in ipairs(AllFrames()) do ApplyBorder(f) end
        if db.followEditMode then
            local _, own = FollowReport()
            Print("following Blizzard Edit Mode: player, target, focus and party sit where Blizzard's frames are"
                .. " placed (pet and target of target move with them). Place them with Edit Mode; your own"
                .. " positions are kept for /bff editmode off."
                .. (#own > 0 and (" Own position for now: " .. table.concat(own, ", ") .. ".") or ""))
        else
            Print("own positions again - Edit Mode no longer moves the frames.")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Settings, shared by the slash command and the menu entries of the API
-- ---------------------------------------------------------------------------

local function RefreshLooks()
    for _, f in ipairs(AllFrames()) do ApplyBorder(f) end
    UpdateAllFrames()
    if testing then
        for _, f in pairs(previews) do if f:IsShown() then FillFake(f) end end
        FakePlayerBuffs()
    end
end

local function SetLocked(on)
    db.locked = on and true or false
    if db.locked then EndDrags() end
    for _, f in ipairs(AllFrames()) do ApplyBorder(f) end
    Print(db.locked and "frames locked."
        or "frames unlocked: drag a frame to move it (out of combat). /bff test shows every frame.")
end

local function SetFrameEnabled(key, on)
    if not HasKey(key) then
        Print("this client has no " .. LABEL[key] .. " unit.")
        return
    end
    db.frames[key] = on and true or false
    if not started then
        Print(LABEL[key] .. " frame: " .. OnOff(db.frames[key]) .. ".")
        return
    end
    OutOfCombat("frame:" .. key, function()
        if db.frames[key] then
            EnableKey(key)
            if testing then SetTesting(true, true) end
        else
            DisableKey(key)
        end
    end)
    if db.frames[key] then
        Print(LABEL[key] .. " frame on.")
    else
        Print(LABEL[key] .. " frame off. Blizzard's " .. LABEL[key]:lower() .. " frame comes back after /reload.")
    end
end

local function SetScale(key, s)
    db.scales[key] = math.floor(Clamp(s, MIN_SCALE, MAX_SCALE) * 100 + 0.5) / 100
    if db.scales[key] == 1 then db.scales[key] = nil end
    ApplyLayout(key)
    Print(string.format("%s frame scale %.2f.", LABEL[key], ScaleOf(key)))
end

local function ResetLayout()
    db.positions, db.scales = {}, {}
    for _, key in ipairs(KEYS) do ApplyLayout(key) end
    Print("positions and scales back to the defaults.")
end

local function SetPortraitMode(mode)
    db.portrait = mode
    for _, f in pairs(real) do
        if Visible(f) then Run("portrait", UpdatePortrait, f) end
    end
    Print("portraits " .. (mode == "3d" and "3D" or "2D") .. ".")
end

local SETTING_TOGGLES = {
    { key = "text", cmd = "text", label = "Bar text" },
    { key = "lowhp", cmd = "lowhp", label = "Low-health colour" },
    { key = "classColor", cmd = "classcolor", label = "Class colour" },
    { key = "playerBuffs", cmd = "playerbuffs", label = "Player buffs" },
    { key = "healPrediction", cmd = "healpred", label = "Heal prediction" },
    { key = "hotPred", cmd = "hotpred", label = "HoT prediction" },
}

local function SetToggle(t, on)
    db[t.key] = on and true or false
    RefreshLooks()
    Print(t.label .. ": " .. OnOff(db[t.key]) .. ".")
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

local function ParseKey(word)
    if KEY_ALIASES[word] then return KEY_ALIASES[word] end
    if LABEL[word] then return word end
end

local function KeyList()
    local list = {}
    for _, key in ipairs(KEYS) do
        if HasKey(key) then list[#list + 1] = key end
    end
    return table.concat(list, "|")
end

local function PrintHelp()
    Print("version " .. VERSION .. ": X-Perl-style unit frames of its own. Commands:")
    Print("/bff status - settings, frames and what this client allows")
    Print("/bff lock | unlock - stop or allow dragging the frames (now: " .. (db and db.locked and "locked" or "unlocked") .. ")")
    Print("/bff editmode on | off - player, target, focus and party follow Blizzard's frames placed in Edit Mode;"
        .. " pet and target of target move with them, and those frames are not dragged (now: "
        .. OnOff(db and db.followEditMode) .. ")")
    Print("/bff test - show every enabled frame with made-up data, to place them (out of combat)")
    Print("/bff reset - positions and scales back to the defaults")
    Print(string.format("/bff scale <%s> <%.1f-%.1f> - one frame's scale", KeyList(), MIN_SCALE, MAX_SCALE))
    Print("/bff frame <" .. KeyList() .. "> on | off - which frames are drawn (off: Blizzard's comes back after /reload)")
    Print("/bff portrait 2d | 3d (now: " .. (db and db.portrait or "?") .. ")")
    Print("/bff text | lowhp | classcolor on | off - bar text, low-health colour, class colour")
    Print("/bff playerbuffs on | off - your buffs in rows under the player frame (now: "
        .. OnOff(db and db.playerBuffs) .. ")")
    Print("/bff healpred on | off - incoming heals and absorbs on the health bars (now: "
        .. OnOff(db and db.healPrediction) .. ")")
    Print("/bff hotpred on | off - what active HoTs will still heal, in yellow after the incoming heals (now: "
        .. OnOff(db and db.hotPred) .. ")")
end

local function Yes(v) return v and "yes" or "MISSING" end

local function SecretTextSupport()
    local C = _G.CurveConstants
    local pct = type(C) == "table" and C.ScaleTo100 ~= nil and type(_G.UnitHealthPercent) == "function"
    local _, abbr = ValueText.Abbrev()
    if pct and abbr then return "cur/max and percent (" .. abbr .. ", UnitHealthPercent)" end
    if pct then return "percent only (UnitHealthPercent)" end
    if abbr then return "cur/max only (" .. abbr .. ")" end
    return "none - bars only while values are hidden"
end

local function Has(ns, name)
    local t = _G[ns]
    return type(t) == "table" and type(t[name]) == "function"
end

-- Auras: how they are drawn, what the target shows, and which aura APIs and templates this
-- client has, so the next test in game says where it stands.
local function PrintAuraStatus()
    local t = real.target
    local how
    if blocked.auras then
        how = "OFF this session - " .. blocked.auras
    elseif t and t.auraContainer then
        local b, mine, other = containerInfo.Shown(t, "buffs"), containerInfo.Shown(t, "mine"), containerInfo.Shown(t, "debuffs")
        local function N(v) return v and tostring(v) or "hidden" end
        if containerInfo.notMine == false then
            how = "on, drawn by Blizzard's aura container" .. DOT .. "target shows " .. N(b) .. " buff(s), "
                .. N(other) .. " debuff(s), yours not set apart (no \"!PLAYER\" filter on this client)"
        else
            how = "on, drawn by Blizzard's aura container" .. DOT .. "target shows " .. N(b) .. " buff(s), "
                .. N(mine) .. " of your debuffs (HARMFUL|PLAYER), " .. N(other)
                .. " from others (HARMFUL|!PLAYER)"
        end
    else
        local shown = t and t.auraShown or {}
        how = "on, read by this addon (" .. ((t and t.auraPath) or "not drawn yet") .. ")" .. DOT .. "target shows "
            .. (shown.HELPFUL or 0) .. " buff(s), " .. (shown.HARMFUL or 0) .. " debuff(s)"
    end
    Print("auras: " .. how)
    local p = real.player
    local pb
    if not db.playerBuffs then
        pb = "off"
    elseif not p then
        pb = "no player frame"
    elseif testing then
        pb = "made-up icons (test mode)"
    elseif p.auraContainer then
        local n = containerInfo.Shown(p, "buffs")
        pb = (n and tostring(n) or "hidden") .. " shown by Blizzard's aura container"
    else
        pb = tostring((p.auraShown or {}).HELPFUL or 0) .. " shown, " .. (p.auraPath or "not drawn yet")
    end
    Print("player buffs: " .. pb)
    local secretNow = "?"
    local S = _G.C_Secrets
    if type(S) == "table" and type(S.ShouldUnitAuraIndexBeSecret) == "function" then
        local ok, v = pcall(S.ShouldUnitAuraIndexBeSecret, "target", 1, "HARMFUL")
        secretNow = ok and (IsSecret(v) and "hidden" or tostring(v)) or "error"
    end
    Print("aura container: " .. (containerInfo.built and (containerInfo.built .. " built")
            or (containerInfo.failed and ("refused - " .. containerInfo.failed))
            or (containerInfo.missing and ("not on this client - " .. containerInfo.missing)) or "not tried yet")
        .. (containerInfo.buttonError and (DOT .. "button look failed: " .. containerInfo.buttonError) or "")
        .. ((containerInfo.timeText and not containerInfo.timeError) and (DOT .. "time text on") or "")
        .. (containerInfo.timeError and (DOT .. "time text refused: " .. containerInfo.timeError) or "")
        .. (containerInfo.timeFormat and (DOT .. "time format " .. containerInfo.timeFormat) or "")
        .. (containerInfo.timeFormatError and (" (options refused: " .. containerInfo.timeFormatError .. ")") or "")
        .. "   C_AuraContainerUtil " .. Yes(type(_G.C_AuraContainerUtil) == "table")
        .. "   CustomAuraContainerGroupDefaultOptions " .. Yes(type(_G.CustomAuraContainerGroupDefaultOptions) == "table"))
    local _, fmtWhy = AuraTime.Formatter()
    Print("aura time text: " .. tostring(fmtWhy) .. DOT .. "colour curve "
        .. (AuraTime.ColorOptions() and "yes" or "no (gold only)"))
    Print("aura API: GetAuraDataByIndex " .. Yes(Has("C_UnitAuras", "GetAuraDataByIndex"))
        .. "   GetUnitAuras " .. Yes(Has("C_UnitAuras", "GetUnitAuras"))
        .. "   GetAuraDuration " .. Yes(Has("C_UnitAuras", "GetAuraDuration"))
        .. "   GetAuraApplicationDisplayCount " .. Yes(Has("C_UnitAuras", "GetAuraApplicationDisplayCount"))
        .. "   ShouldUnitAuraIndexBeSecret " .. Yes(Has("C_Secrets", "ShouldUnitAuraIndexBeSecret"))
        .. " (target debuff 1 secret now: " .. secretNow .. ")")
    Print(string.format("aura reads refused this session: %d; icons failed to draw: %d",
        auraStats.indexRefused, auraStats.paintFailed)
        .. (auraStats.lastError and (" - last: " .. auraStats.lastError) or ""))
end

-- The target's health readings and the number formatters, for /bff status. Hidden values are
-- named, never shown; the formatters are tried on plain numbers only.
function ValueText.Status()
    local u = "target"
    local function Show(v)
        if IsSecret(v) then return "hidden" end
        return tostring(v)
    end
    local function Try(name, n)
        local fn = _G[name]
        if type(fn) ~= "function" then return name .. " MISSING" end
        local ok, v = pcall(fn, n)
        return name .. "(" .. n .. ") = " .. (ok and Show(v) or "error")
    end
    local _, abbr = ValueText.Abbrev()
    Print("health text formatter: " .. (abbr or "none") .. DOT .. Try("AbbreviateLargeNumbers", 19)
        .. DOT .. Try("AbbreviateLargeNumbers", 12345) .. DOT .. Try("AbbreviateNumbers", 19)
        .. DOT .. Try("AbbreviateNumbers", 12345))
    if Plain(UnitExists(u)) ~= true then
        Print("target health: no target (target a mob and ask again)")
        return
    end
    local S = _G.C_Secrets
    local maxSecret = "MISSING"
    if type(S) == "table" and type(S.ShouldUnitHealthMaxBeSecret) == "function" then
        local ok, v = pcall(S.ShouldUnitHealthMaxBeSecret, u)
        maxSecret = ok and Show(v) or "error"
    end
    local okP, pred = pcall(UnitHealth, u)
    local okS, server = pcall(UnitHealth, u, false)
    Print("target health: UnitHealth " .. (okP and Show(pred) or "error")
        .. DOT .. "UnitHealth(unit, false) " .. (okS and Show(server) or "error")
        .. DOT .. "UnitHealthMax " .. Show(UnitHealthMax(u))
        .. DOT .. "ShouldUnitHealthMaxBeSecret " .. maxSecret
        .. DOT .. "text and bar use UnitHealth(unit, false)")
end

-- Target power: the values that decide whether the power bar shows, so the next test in game
-- proves which of them this client hands out plainly.
local function PrintPowerStatus()
    local u = "target"
    if Plain(UnitExists(u)) ~= true then
        Print("target power: no target (target something without mana, e.g. a beast, and ask again)")
        return
    end
    local function Show(v)
        if IsSecret(v) then return "hidden" end
        return tostring(v)
    end
    local okT, pType, token = pcall(UnitPowerType, u)
    local cur, mx = UnitPower(u), UnitPowerMax(u)
    local has = "MISSING"
    if type(_G.UnitHasPowerType) == "function" then
        local ok, v = pcall(_G.UnitHasPowerType, u, Num(pType) or 0)
        has = ok and Show(v) or ("error: " .. tostring(v))
    end
    local S = _G.C_Secrets
    local function Pred(name)
        if type(S) ~= "table" or type(S[name]) ~= "function" then return "MISSING" end
        local ok, v = pcall(S[name], u, Num(pType))
        return ok and Show(v) or "error"
    end
    local t = real.target
    Print("target power: type " .. (okT and (Show(pType) .. " " .. Show(token)) or "error")
        .. DOT .. "UnitHasPowerType " .. has
        .. DOT .. "UnitPower " .. Show(cur) .. DOT .. "UnitPowerMax " .. Show(mx)
        .. DOT .. "ShouldUnitPowerBeSecret " .. Pred("ShouldUnitPowerBeSecret")
        .. DOT .. "ShouldUnitPowerMaxBeSecret " .. Pred("ShouldUnitPowerMaxBeSecret")
        .. DOT .. "bar " .. ((t and t.powerShown == false) and "hidden" or "shown")
        .. " (" .. ((t and t.powerWhy) or "not drawn yet") .. ")"
        .. DOT .. "hidden-zero hiding: " .. ((t and t.powerHide) or ("not in use, would be " .. PowerHide.Method()))
        .. (blocked.powerhide and (" (off: " .. blocked.powerhide .. ")") or ""))
    local E = _G.Enum
    Print("target power helpers: C_CurveUtil.CreateCurve " .. Yes(Has("C_CurveUtil", "CreateCurve"))
        .. "   Enum.LuaCurveType.Step " .. Yes(type(E) == "table" and type(E.LuaCurveType) == "table"
            and E.LuaCurveType.Step ~= nil)
        .. "   UnitPowerPercent " .. Yes(type(_G.UnitPowerPercent) == "function")
        .. "   C_StringUtil.TruncateWhenZero " .. Yes(Has("C_StringUtil", "TruncateWhenZero"))
        .. "   C_StringUtil.WrapString " .. Yes(Has("C_StringUtil", "WrapString"))
        .. "   C_StringUtil.RoundToNearestString " .. Yes(Has("C_StringUtil", "RoundToNearestString"))
        .. "   C_StringUtil.FloorToNearestString " .. Yes(Has("C_StringUtil", "FloorToNearestString"))
        .. "   C_CurveUtil.EvaluateColorValueFromBoolean " .. Yes(Has("C_CurveUtil", "EvaluateColorValueFromBoolean"))
        .. "   SetAlphaFromBoolean " .. Yes(real.target and type(real.target.SetAlphaFromBoolean) == "function"))
end

local function PrintStatus()
    Print("version " .. VERSION .. DOT .. (db.locked and "locked" or "unlocked")
        .. DOT .. "portraits " .. (db.portrait == "3d" and "3D" or "2D") .. (testing and (DOT .. "test mode on") or ""))
    local parts = {}
    for _, key in ipairs(KEYS) do
        if HasKey(key) then
            parts[#parts + 1] = key .. " " .. OnOff(db.frames[key])
                .. (ScaleOf(key) ~= 1 and string.format(" (%.2f)", ScaleOf(key)) or "")
        end
    end
    Print("frames: " .. table.concat(parts, DOT))
    if db.followEditMode and blocked.editmode then
        Print("follow Blizzard Edit Mode: on, but switched off by this client this session")
    elseif db.followEditMode then
        local at, own = FollowReport()
        Print("follow Blizzard Edit Mode: on" .. DOT .. "at Blizzard's place: " .. (#at > 0 and table.concat(at, ", ") or "none")
            .. (#own > 0 and (DOT .. "own place: " .. table.concat(own, ", ")) or "")
            .. DOT .. "Edit Mode " .. (editOpen and "open" or "closed")
            .. DOT .. "hooked via " .. (editHooked or "nothing (no Edit Mode on this client)"))
    else
        Print("follow Blizzard Edit Mode: off (own positions)")
    end
    PrintAuraStatus()
    Print("bar text " .. OnOff(db.text) .. DOT .. "low-health colour " .. OnOff(db.lowhp)
        .. DOT .. "class colour " .. OnOff(db.classColor) .. DOT .. "player buffs " .. OnOff(db.playerBuffs))
    Print("heal prediction " .. OnOff(db.healPrediction) .. DOT .. HealPred.Method()
        .. (blocked.healpred and (" (off: " .. blocked.healpred .. ")") or ""))
    Print("hot prediction " .. OnOff(db.hotPred) .. (db.healPrediction and "" or " (needs heal prediction)")
        .. DOT .. "now: " .. HealPred.HotStatus())
    local p = real.player
    Print("player mana bar: " .. ((p and p.manaShown) and "shown" or "hidden")
        .. " (" .. ((p and p.manaWhy) or "not drawn yet") .. ")"
        .. (blocked.mana and (" (off: " .. blocked.mana .. ")") or "")
        .. DOT .. "player power bar " .. ((p and p.powerShown == false) and "hidden" or "shown")
        .. " (" .. ((p and p.powerWhy) or "not drawn yet") .. ")"
        .. ((p and p.powerHide) and (DOT .. p.powerHide) or ""))
    PrintPowerStatus()
    ValueText.Status()
    Print("SecureUnitButtonTemplate frames: " .. (unsupported and ("no - " .. unsupported) or (started and "built" or "not built yet"))
        .. "   RegisterUnitWatch: " .. Yes(type(_G.RegisterUnitWatch) == "function")
        .. "   focus: " .. (HAS_FOCUS and "yes" or "no (no focus unit)"))
    Print("hidden values: " .. (type(issecretvalue) == "function" and "possible" or "no")
        .. "   text for hidden values: " .. SecretTextSupport()
        .. "   range: " .. (type(_G.UnitInRange) == "function" and "UnitInRange"
            or (type(_G.CheckInteractDistance) == "function" and "CheckInteractDistance" or "none")))
    local names = {}
    for n in pairs(hiddenNames) do names[#names + 1] = n end
    table.sort(names)
    Print("Blizzard frames switched off: " .. (#names > 0 and table.concat(names, ", ") or "none")
        .. " (CompactPartyFrame, raid-style party frames, is left alone)")
    local off = {}
    for f in pairs(FEATURE_LABELS) do if blocked[f] then off[#off + 1] = f end end
    table.sort(off)
    if #off > 0 then Print("switched off by this client this session: " .. table.concat(off, ", ")) end
    if #pendingOrder > 0 then Print(#pendingOrder .. " frame change(s) wait for the end of combat.") end
    local c = LoadedConflicts()
    if #c > 0 then
        Print(table.concat(c, ", ") .. " also draw(s) unit frames; use one of them, not both.")
    end
end

local function OnSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if not db then
        Print("not loaded yet.")
        return
    end
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    if cmd == "status" then
        PrintStatus()
    elseif cmd == "lock" then
        SetLocked(true)
    elseif cmd == "unlock" then
        SetLocked(false)
    elseif cmd == "test" then
        if rest == "on" or rest == "off" then SetTesting(rest == "on") else SetTesting(not testing) end
    elseif cmd == "reset" then
        ResetLayout()
    elseif cmd == "scale" then
        local word, num = rest:match("^(%S+)%s+(%S+)$")
        local key, s = ParseKey(word or ""), tonumber(num or "")
        if s and s > 10 then s = s / 100 end   -- "120" for 120%
        if key and HasKey(key) and s and s >= MIN_SCALE and s <= MAX_SCALE then
            SetScale(key, s)
        else
            Print(string.format("/bff scale <%s> <%.1f-%.1f>", KeyList(), MIN_SCALE, MAX_SCALE))
        end
    elseif cmd == "frame" then
        local word, state = rest:match("^(%S+)%s*(%S*)$")
        local key = ParseKey(word or "")
        if key and (state == "on" or state == "off") then
            SetFrameEnabled(key, state == "on")
        elseif key and state == "" then
            SetFrameEnabled(key, not db.frames[key])
        else
            Print("/bff frame <" .. KeyList() .. "> on | off")
        end
    elseif cmd == "editmode" or cmd == "follow" then
        if rest == "on" or rest == "off" then SetFollow(rest == "on")
        elseif rest == "" then SetFollow(not db.followEditMode)
        else Print("/bff editmode on | off (now: " .. OnOff(db.followEditMode) .. ")") end
    elseif cmd == "portrait" then
        if rest == "2d" or rest == "3d" then SetPortraitMode(rest)
        else Print("/bff portrait 2d | 3d (now: " .. db.portrait .. ")") end
    else
        for _, t in ipairs(SETTING_TOGGLES) do
            if cmd == t.cmd then
                if rest == "on" or rest == "off" then SetToggle(t, rest == "on")
                elseif rest == "" then SetToggle(t, not db[t.key])
                else Print("/bff " .. t.cmd .. " on | off (now: " .. OnOff(db[t.key]) .. ")") end
                return
            end
        end
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: BetterFramesForeverAPI
--
-- For BetterGaarForever, the optional hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in BetterFramesForeverDB and change only through the
-- same functions /bff uses, so the addon behaves the same with or without the hub.
--
--   version              this addon's version, a string
--   StatusLine()         one short line of state, e.g. "unlocked · 6 frames · 2D"
--   MenuEntries()        the options as plain data, for a menu drawn without MenuUtil:
--                        { text, func }, { text, checkbox = true, checked, func },
--                        { text, radio = true, checked, func }, { text, submenu } and { divider = true }
--   AddMenuEntries(root) adds the same options to a MenuUtil root or submenu description
--   SetMinimapHidden(b)  runtime only; this addon has no minimap button, so it does nothing
-- ---------------------------------------------------------------------------

local function StatusLine()
    if not db then return "not loaded yet" end
    local line = (db.locked and "locked" or "unlocked") .. DOT .. CountEnabled() .. " frames"
        .. DOT .. (db.portrait == "3d" and "3D" or "2D")
    if FollowOn() then line = line .. DOT .. "Edit Mode" end
    if testing then line = line .. DOT .. "test mode" end
    return line
end

local function MenuEntries()
    if not db then return {} end
    local frameItems = {}
    for _, key in ipairs(KEYS) do
        if HasKey(key) then
            frameItems[#frameItems + 1] = { text = LABEL[key], checkbox = true,
                checked = function() return db.frames[key] end,
                func = function() SetFrameEnabled(key, not db.frames[key]) end }
        end
    end
    local portraits = {
        { text = "2D", radio = true, checked = function() return db.portrait == "2d" end,
          func = function() SetPortraitMode("2d") end },
        { text = "3D", radio = true, checked = function() return db.portrait == "3d" end,
          func = function() SetPortraitMode("3d") end },
    }
    local list = {
        { text = "Lock", checkbox = true, checked = function() return db.locked end,
          func = function() SetLocked(not db.locked) end },
        { text = "Test mode", checkbox = true, checked = function() return testing end,
          func = function() SetTesting(not testing) end },
        { text = "Frames", submenu = frameItems },
        { text = "Portrait", submenu = portraits },
        { text = "Follow Blizzard Edit Mode", checkbox = true, checked = function() return db.followEditMode end,
          func = function() SetFollow(not db.followEditMode) end },
        { divider = true },
    }
    for _, t in ipairs(SETTING_TOGGLES) do
        list[#list + 1] = { text = t.label, checkbox = true,
            checked = function() return db[t.key] end,
            func = function() SetToggle(t, not db[t.key]) end }
    end
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Reset positions & scales", func = ResetLayout }
    return list
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

_G.BetterFramesForeverAPI = {
    version = VERSION,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) RenderMenu(root, MenuEntries()) end,
    SetMinimapHidden = function() end,
}

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    if type(BetterFramesForeverDB) ~= "table" then BetterFramesForeverDB = {} end
    db = BetterFramesForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if type(db[k]) ~= type(v) then db[k] = v end
    end
    if db.portrait ~= "2d" and db.portrait ~= "3d" then db.portrait = DEFAULTS.portrait end

    if type(db.frames) ~= "table" then db.frames = {} end
    for k, v in pairs(db.frames) do
        if DEFAULT_FRAMES[k] == nil or type(v) ~= "boolean" then db.frames[k] = nil end
    end
    for k, v in pairs(DEFAULT_FRAMES) do
        if db.frames[k] == nil then db.frames[k] = v end
    end

    if type(db.scales) ~= "table" then db.scales = {} end
    for k, v in pairs(db.scales) do
        local n = Num(v)
        if DEFAULT_FRAMES[k] == nil or not n then db.scales[k] = nil
        else db.scales[k] = Clamp(n, MIN_SCALE, MAX_SCALE) end
    end

    -- A saved entry with a field missing is a secret that did not survive the write.
    if type(db.positions) ~= "table" then db.positions = {} end
    for k, p in pairs(db.positions) do
        if DEFAULT_FRAMES[k] == nil or type(p) ~= "table" or not Num(p.x) or not Num(p.y) then
            db.positions[k] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- Unit events and the part of the frame each one repaints.
local UNIT_EVENTS = {
    UNIT_HEALTH = UpdateHealth, UNIT_MAXHEALTH = UpdateHealth, UNIT_HEALTH_FREQUENT = UpdateHealth,
    UNIT_CONNECTION = UpdateHealth,
    UNIT_POWER_UPDATE = UpdatePower, UNIT_POWER_FREQUENT = UpdatePower, UNIT_MAXPOWER = UpdatePower,
    UNIT_DISPLAYPOWER = UpdatePower,
    UNIT_AURA = UpdateAuras,
    UNIT_PORTRAIT_UPDATE = UpdatePortrait, UNIT_MODEL_CHANGED = UpdatePortrait,
    UNIT_NAME_UPDATE = UpdateName, UNIT_LEVEL = UpdateName, UNIT_CLASSIFICATION_CHANGED = UpdateName,
    UNIT_HEAL_PREDICTION = HealPred.Update, UNIT_ABSORB_AMOUNT_CHANGED = HealPred.Update,
    UNIT_HEAL_ABSORB_AMOUNT_CHANGED = HealPred.Update,
}
local UNIT_EVENT_FEATURE = {
    [UpdateHealth] = "health", [UpdatePower] = "power", [UpdateAuras] = "auras", [HealPred.Update] = "healpred",
    [UpdatePortrait] = "portrait", [UpdateName] = "name",
}

local function OnUnitEvent(event, unit, arg2)
    if type(unit) ~= "string" then return end
    if unit == "player" and (event == "UNIT_COMBO_POINTS"
        or ((event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT") and arg2 == "COMBO_POINTS")) then
        local t = real.target
        if Visible(t) then Run("combo", UpdateCombo, t) end
        if event == "UNIT_COMBO_POINTS" then return end
    end
    if event == "UNIT_FACTION" then
        local f = real[unit]
        if Visible(f) then Run("health", UpdateHealth, f); Run("name", UpdateName, f) end
        return
    end
    if event == "UNIT_THREAT_SITUATION_UPDATE" or event == "UNIT_THREAT_LIST_UPDATE" then
        UpdateEach("threat", UpdateThreat)
        return
    end
    if event == "UNIT_TARGET" then
        if unit == "target" then UpdateUnit("targettarget") end
        return
    end
    if event == "UNIT_PET" then
        if unit == "player" then UpdateUnit("pet") end
        return
    end
    local fn = UNIT_EVENTS[event]
    local f = fn and real[unit]
    if not Visible(f) then return end
    Run(UNIT_EVENT_FEATURE[fn], fn, f)
    -- Health changes move the clamps of the heal overlays; power changes the player's mana bar.
    if fn == UpdateHealth then Run("healpred", HealPred.Update, f) end
    -- HoTs coming and going move the yellow HoT segment.
    if fn == UpdateAuras and db.hotPred then Run("healpred", HealPred.Update, f) end
    if fn == UpdatePower and f.mana then Run("mana", Mana.Update, f) end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_TARGET_CHANGED", "PLAYER_UPDATE_RESTING", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED",
    "RAID_TARGET_UPDATE", "UNIT_FACTION", "UNIT_THREAT_SITUATION_UPDATE", "UNIT_THREAT_LIST_UPDATE",
    "UNIT_TARGET", "UNIT_PET", "UNIT_COMBO_POINTS", "EDIT_MODE_LAYOUTS_UPDATED", "DISPLAY_SIZE_CHANGED",
    "UI_SCALE_CHANGED", "UPDATE_SHAPESHIFT_FORM" }) do
    pcall(events.RegisterEvent, events, e)
end
if HAS_FOCUS then pcall(events.RegisterEvent, events, "PLAYER_FOCUS_CHANGED") end
for e in pairs(UNIT_EVENTS) do pcall(events.RegisterEvent, events, e) end

events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            BindSavedVariables()
            -- Loaded after login (LoadAddOn): no PLAYER_LOGIN is coming, so start now.
            if type(_G.IsLoggedIn) == "function" and _G.IsLoggedIn() then Start() end
        end
        return
    end
    if not db then return end
    if event == "PLAYER_LOGIN" then
        local cls = ClassToken("player")
        comboClass = (cls == "ROGUE" or cls == "DRUID")
        local c = LoadedConflicts()
        if #c > 0 and not conflictWarned then
            conflictWarned = true
            Print(table.concat(c, ", ") .. " also draw(s) unit frames; use one of them, not both.")
        end
        Start()
        HookEditMode()
        if FollowOn() and started then Refollow() end
    elseif event == "PLAYER_REGEN_DISABLED" then
        EndDrags()
        if testing then SetTesting(false, true); Print("test mode off - combat.") end
        local p = real.player
        if Visible(p) then Run("icons", UpdateIcons, p) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        FlushQueue()
        -- Logged in during combat: the frames were only built now.
        if FollowOn() and started and not editOpen and not next(followPos) then Refollow() end
        local p = real.player
        if Visible(p) then Run("icons", UpdateIcons, p) end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "EDIT_MODE_LAYOUTS_UPDATED" then
        RecheckBlizzard()
        -- A layout switch or a loading screen moves Blizzard's frames; Edit Mode itself is
        -- handled when it closes.
        if FollowOn() and started and not editOpen then Refollow() end
        UpdateAllFrames()
    elseif event == "DISPLAY_SIZE_CHANGED" or event == "UI_SCALE_CHANGED" then
        if FollowOn() and started and not editOpen then Refollow() end
    elseif event == "PLAYER_TARGET_CHANGED" then
        UpdateUnit("target")
        UpdateUnit("targettarget")
    elseif event == "PLAYER_FOCUS_CHANGED" then
        UpdateUnit("focus")
    elseif event == "UPDATE_SHAPESHIFT_FORM" then
        local p = real.player
        if Visible(p) then
            Run("power", UpdatePower, p)
            Run("mana", Mana.Update, p)
        end
    elseif event == "PLAYER_UPDATE_RESTING" then
        local p = real.player
        if Visible(p) then Run("icons", UpdateIcons, p) end
    elseif event == "GROUP_ROSTER_UPDATE" then
        for _, u in ipairs(UNITS_OF.party) do UpdateUnit(u) end
        local p = real.player
        if Visible(p) then Run("icons", UpdateIcons, p) end
    elseif event == "PARTY_LEADER_CHANGED" or event == "RAID_TARGET_UPDATE" then
        UpdateEach("icons", UpdateIcons)
    else
        OnUnitEvent(event, arg1, arg2)
    end
end)

-- The light ticker: target of target (it has no events of its own) and party range.
local driver = CreateFrame("Frame")
local acc = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    if not db or not started then return end
    acc = acc + (elapsed or 0)
    if acc < TICK then return end
    acc = 0
    local tot = real.targettarget
    if Visible(tot) then UpdateFrame(tot) end
    if not testing then
        for _, u in ipairs(UNITS_OF.party) do
            local f = real[u]
            if Visible(f) then Run("range", UpdateRange, f) end
        end
    end
end)

SLASH_BETTERFRAMESFOREVER1 = "/bff"
SLASH_BETTERFRAMESFOREVER2 = "/betterframesforever"
SlashCmdList.BETTERFRAMESFOREVER = OnSlash
