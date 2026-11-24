--[[
  GaarFramesForever - X-Perl-style unit frames of its own on WoW Forever.

  Standalone, no options panel, no minimap button: a slash command and a small API for
  GaarForever's hub. It builds its own frames, the way X-Perl and oUF do, and hides
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
    * Heal prediction on every health bar: incoming heals (green), what active HoTs will still
      heal (yellow), absorbs (white). 1.5.0: heals past the maximum show as a red / orange
      overheal segment hanging past the bar's right edge (/gff overheal, capped at 30% of the
      bar), and the HoT of a HoT spell you are casting (Regrowth) is shown in yellow from the
      start of the cast on its target's frames (/gff hotcast).
    * Spell cost on your power bar (1.6.0): while you cast a spell with a cast time, the part of
      the bar the cost will take is drawn bright and pulsing with a small "-340", red when you
      do not have enough; gone the moment the cast ends (/gff cost).
    * PvP flag (1.7.0): a faction / free-for-all icon on the left edge of a flagged player, target
      or party frame; the player's also shows m:ss under it while the flag times out
      (option /gff pvp, on by default).
    * Icons: raid target (own frame above the bars, centred on the top edge; secret-safe; option
      /gff marks, 1.2.9), group leader, combat and resting (player); a threat border.
    * Move: drag a frame while unlocked (out of combat), scale per frame (0.6-1.5), lock,
      reset, and a test mode that shows every enabled frame with made-up data (party without a
      group) so they can be placed.
    * Follow Blizzard Edit Mode (option, off by default): player, target, focus and party sit
      where Blizzard's own frames are placed in Edit Mode; pet and target of target keep their
      offset from player and target. While Edit Mode is open Blizzard's frames are given back
      so they can be dragged, and ours go see-through. Own positions are kept for when it is off.
    * /gff (or /betterframesforever) for help, status, lock, unlock, test, reset, scale, frame,
      editmode, portrait, pvp, text, classcolor, playerbuffs, healpred, hotpred, hotcast, cost, overheal and
      hotdebug.
    * GaarFramesForeverAPI, a small global table for GaarForever's hub menu (version,
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
local ADDON_NAME = ... or "GaarFramesForever"
local DOT = " \194\183 "

local VERSION = "1.8.0"

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
local OVER_CAP = { 0.1, 1 }   -- /gff overheal cap, lowest and highest: a share of the health bar's width (1.5.0)

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

-- The palette (1.2.11): Blizzard's own colours, read at runtime from FACTION_BAR_COLORS, PowerBarColor
-- and RAID_CLASS_COLORS where the client has them; these are the classic defaults used as fallback.
-- The gradient, border and shadow of 1.2.8 stay and shade these colours.
local Look = {   -- the palette, and SetBarColor and Edge below
    HEALTH = { 0, 1, 0 },              -- Blizzard's default health green; players without class colour
    HOSTILE = { 0.8, 0.3, 0.22 },      -- FACTION_BAR_COLORS[2]
    NEUTRAL = { 0.9, 0.7, 0 },         -- FACTION_BAR_COLORS[4]
    FRIENDLY = { 0, 0.6, 0.1 },        -- FACTION_BAR_COLORS[5]: friendly NPCs
    TAPPED = { 0.5, 0.5, 0.5 },        -- tagged by someone else; offline too
    DEAD = { 0.5, 0.5, 0.5 },
}
local POWER_COLORS = {   -- fallback only: PowerBarColor first
    MANA = { 0, 0, 1 }, RAGE = { 1, 0, 0 }, FOCUS = { 1, 0.5, 0.25 },
    ENERGY = { 1, 1, 0 }, RUNIC_POWER = { 0, 0.82, 1 },
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
    classColor = true,
    followEditMode = false,
    playerBuffs = true,
    healPrediction = true,
    hotPred = true,
    hotCastPreview = true,   -- 1.5.0: the HoT of a HoT spell you are casting, from the cast's start
    powerCost = true,        -- 1.6.0: the cost of the spell you are casting, marked on the player's power bar
    overheal = true,         -- 1.5.0: heals past the maximum drawn past the bar's right edge
    overhealCap = 0.3,       -- 1.5.0: the overheal segment's longest length, a share of the bar's width
    raidMark = true,
    petHappiness = true,
    pvpFlag = true,          -- 1.7.0: a faction / FFA icon beside the portrait of a PvP-flagged unit
}
local DEFAULT_FRAMES = { player = true, target = true, tot = true, focus = true, pet = true, party = true }

-- Every key GaarFramesForeverDB may hold; anything else is cleared on load.
local SAVED_KEYS = {
    locked = true, portrait = true, text = true, classColor = true, followEditMode = true,
    playerBuffs = true, healPrediction = true, hotPred = true, hotCastPreview = true, overheal = true, powerCost = true,
    overhealCap = true, raidMark = true, petHappiness = true, pvpFlag = true, frames = true, scales = true, positions = true,
}

local db                    -- GaarFramesForeverDB, bound at ADDON_LOADED (never at file scope)
local real = {}             -- [unit] = our secure frame
local previews = {}         -- [unit] = non-secure preview frame for test mode
local enabledNow = {}       -- [key] = true while that key's frames are switched on
local blocked = {}          -- [feature] = error text, once this client refused it
local hiddenBlizz = {}      -- [Blizzard frame] = true when it is not re-parented (party members)
local hiddenNames = {}      -- names of Blizzard frames switched off, for /gff status
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
local editHooked            -- how the Edit Mode callbacks were hooked, for /gff status
local editOwner = {}        -- owner handle for EventRegistry

-- Forward declarations: used by the frame scripts before they are defined.
local UpdateFrame, StartDrag, StopDrag, ApplyBorder
-- Happy lives in the file-scope table below (assigned in the Look block): declared here because it is
-- also used after that block's end (UpdateHealth, status, poll). Declared inside the block it was a
-- nil global out there (1.4.1 bug: UpdateHealth threw and the health feature latched off).
local Happy

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- Print, OnOff, IsSecret, Plain and Num come from the shared library (GaarForever, loaded
-- first as a dependency). Where the client hides a value it hands back a secret: it may be
-- passed to a widget, but arithmetic, comparison, a boolean test and even "or" on it are refused.
-- IsSecret is false on a client where nothing is secret; Plain is the value, or nil when it is
-- secret, so every later test on it is an ordinary one; Num is a plain, finite number or nil.
local BF = _G.GaarForever
local A = BF.NewAddon("GaarFramesForever", { title = "GaarFramesForever", version = VERSION })
local function Print(msg) A:Print(msg) end
local OnOff, IsSecret, Plain, Num = BF.OnOff, BF.IsSecret, BF.Plain, BF.Num

-- Either of two values is secret (the library's IsSecret takes one).
local function Secret(a, b)
    -- No comparison on the raw values (b may itself be secret): IsSecret(nil) is false.
    return IsSecret(a) or IsSecret(b)
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

-- Raid target mark (1.2.9): one icon on its own frame, high above the bars, centred on the top
-- edge of every unit frame so half of it sticks out above. Built once per frame.
function Look.BuildMark(f)
    local m = CreateFrame("Frame", nil, f)
    m:SetFrameLevel(f:GetFrameLevel() + 10)
    m:SetSize(18, 18)
    m:SetPoint("CENTER", f, "TOP", 0, 0)
    local t = m:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints(m)
    t:SetTexture(RAID_ICONS)
    t:Hide()
    f.raidIcon = t
end

-- Hunter pet happiness (1.4.0; 1.4.1 hardened): Blizzard's happy / content / unhappy face on its
-- own non-secure frame, just right of the pet frame, with a tooltip, and the pet's health bar
-- coloured by happiness. Shown while the player is a hunter and has a pet out.
-- 1.4.1: the face did not show on WoW: Forever. The level is now read from GetPetHappiness()
-- and, where that is missing or gives nothing, from the pet's happiness power (UnitPower);
-- HasPetUI() no longer gates it; UnitExists may answer 1 as well as true; when the client has
-- no face texture, coloured dots are drawn instead. /gff status prints the raw reads.
local HAPPY_TEX = "Interface\\PetPaperDollFrame\\UI-PetHappiness"
local HAPPY_COORDS = {
    [1] = { 0.375, 0.5625, 0, 0.359375 },
    [2] = { 0.1875, 0.375, 0, 0.359375 },
    [3] = { 0, 0.1875, 0, 0.359375 },
}
-- Fallback when the face texture is not in the client's files: red, yellow and green dots.
local HAPPY_DOTS = {
    "Interface\\COMMON\\Indicator-Red", "Interface\\COMMON\\Indicator-Yellow", "Interface\\COMMON\\Indicator-Green",
}
local HAPPY_DEFAULT_TEXT = { "Pet is Unhappy", "Pet is Content", "Pet is Happy" }
-- Health bar colour by happiness: unhappy red, content yellow, happy green.
local HAPPY_BAR = { { 0.9, 0.15, 0.1 }, { 1, 0.85, 0.1 }, { 0.1, 0.8, 0.1 } }
-- Damage done at each level in Classic, for the tooltip when only the power value is known.
local HAPPY_DMG = { 75, 100, 125 }
-- Classic's happiness power runs to 1050000: unhappy below 350000, content below 700000.
local HAPPY_MAX = 1050000

Happy = { diag = {} }   -- diag: the last raw reads, for /gff status

-- A raw value as text for /gff status; a secret is never looked into.
local function Raw(v)
    if IsSecret(v) then return "secret" end
    return tostring(v)
end

local function HappinessPowerType()
    local E = _G.Enum
    local v = type(E) == "table" and type(E.PowerType) == "table" and Num(E.PowerType.Happiness)
    return v or 4
end

-- happiness (1-3), damage percentage (e.g. 125) and loyalty rate, or nil. GetPetHappiness()
-- first; else the pet's happiness power against its maximum (thirds of it). Plain numbers only:
-- Num turns a secret into nil before anything is compared.
function Happy.Read()
    local d = Happy.diag
    d.gph, d.power, d.source, d.secret = "missing", "n/a", "none", false
    if type(_G.GetPetHappiness) == "function" then
        local ok, h, dmg, loy = pcall(_G.GetPetHappiness)
        if not ok then
            d.gph = "error"; d.err = "GetPetHappiness: " .. tostring(h)
        else
            d.gph = Raw(h) .. ", " .. Raw(dmg) .. ", " .. Raw(loy)
            if IsSecret(h) then d.secret = true end
            h = Num(h)
            if h then h = math.floor(h + 0.5) end
            if h and h >= 1 and h <= 3 then
                d.source = "GetPetHappiness"
                return h, Num(dmg), Num(loy)
            end
        end
    end
    if type(_G.UnitPower) == "function" then
        local pt = HappinessPowerType()
        local ok, cur, mx = pcall(function()
            return _G.UnitPower("pet", pt), type(_G.UnitPowerMax) == "function" and _G.UnitPowerMax("pet", pt) or nil
        end)
        if not ok then
            d.power = "error"; d.err = "UnitPower: " .. tostring(cur)
        else
            d.power = Raw(cur) .. "/" .. Raw(mx) .. " (type " .. pt .. ")"
            if IsSecret(cur) or IsSecret(mx) then d.secret = true end
            cur, mx = Num(cur), Num(mx)
            local top = (mx and mx > 0) and mx or ((cur and cur > 0) and HAPPY_MAX or nil)
            if cur and top and cur >= 0 then
                local h
                if top == 3 then
                    -- A client that gives the level itself (1-3) as the power value.
                    h = math.min(3, math.max(1, math.floor(cur + 0.5)))
                else
                    local t = cur / top
                    h = (t < 1 / 3 and 1) or (t < 2 / 3 and 2) or 3
                end
                d.source = "UnitPower"
                return h, HAPPY_DMG[h], nil
            end
        end
    end
    return nil
end

-- The player is a hunter with a pet out and the setting is on. Never HasPetUI(): on some
-- clients it is false or missing while the pet is out (it is only read for /gff status).
function Happy.Gate()
    local d = Happy.diag
    local _, cls = UnitClass("player")
    d.hunter = Plain(cls) == "HUNTER"
    d.exists = Plain(UnitExists("pet")) and true or false
    if type(_G.HasPetUI) == "function" then
        local ok, a, b = pcall(_G.HasPetUI)
        d.petui = ok and (Raw(a) .. ", " .. Raw(b)) or "error"
    else
        d.petui = "missing"
    end
    return (db.petHappiness and d.hunter and d.exists) and true or false
end

-- happiness (1-3), damage and loyalty while the gate is open, else nil. Where the client hides
-- the values (in combat), the last level read stays, so the face and colour do not flicker.
function Happy.Level()
    local d = Happy.diag
    if blocked.happiness or not Happy.Gate() then d.level, Happy.last = nil, nil; return nil end
    local h, dmg, loy = Happy.Read()
    if h then
        Happy.last = h
    elseif d.secret and Happy.last then
        h, d.source = Happy.last, "last known (values hidden)"
    end
    d.level = h
    return h, dmg, loy
end

-- The health bar colour for f, or nil to keep the normal one: the real pet frame only.
function Happy.BarRGB(f)
    if f.key ~= "pet" or f.unit ~= "pet" or f.preview then return nil end
    local h = Happy.Level()
    if not h then return nil end
    local c = HAPPY_BAR[h]
    return c[1], c[2], c[3]
end

local function HappinessTooltip(self)
    local h, dmg, loy = Happy.Level()
    if not h then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local fmt = _G["PET_HAPPINESS" .. h]
    GameTooltip:SetText(type(fmt) == "string" and fmt ~= "" and fmt or HAPPY_DEFAULT_TEXT[h])
    if dmg then
        local pct = math.floor(dmg - 100 + 0.5)
        local dfmt = _G.PET_DAMAGE_PERCENTAGE
        if type(dfmt) == "string" and dfmt:find("%%") and pcall(string.format, dfmt, pct) then
            GameTooltip:AddLine(string.format(dfmt, pct), 1, 1, 1)
        else
            GameTooltip:AddLine(string.format("Damage: %s%d%%", pct > 0 and "+" or "", pct), 1, 1, 1)
        end
    end
    if loy and loy > 0 then
        GameTooltip:AddLine("Pet is gaining loyalty", 0.2, 1, 0.2)
    elseif loy and loy < 0 then
        GameTooltip:AddLine("Pet is losing loyalty", 1, 0.2, 0.2)
    end
    GameTooltip:Show()
end

function Look.BuildHappiness(f)
    local m = CreateFrame("Frame", nil, f)
    m:SetFrameStrata(f:GetFrameStrata())
    m:SetFrameLevel(f:GetFrameLevel() + 10)
    m:SetSize(20, 20)
    m:SetPoint("LEFT", f, "RIGHT", 2, 0)
    m:EnableMouse(true)
    local t = m:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints(m)
    -- SetTexture answers false for a file the client does not have: use the dots then.
    if t:SetTexture(HAPPY_TEX) == false then
        m.dots = true
        t:SetTexture(HAPPY_DOTS[3])
        t:SetTexCoord(0, 1, 0, 1)
    else
        t:SetTexCoord(unpack(HAPPY_COORDS[3]))
    end
    m.tex = t
    m:SetScript("OnEnter", function(self) pcall(HappinessTooltip, self) end)
    m:SetScript("OnLeave", function() GameTooltip:Hide() end)
    m:Hide()
    f.happyFrame = m
end

function Look.UpdateHappiness(f)
    local m = f.happyFrame
    if not m then return end
    local h = Happy.Level()
    if not h then m:Hide(); m.level = nil; return end
    if m.dots then m.tex:SetTexture(HAPPY_DOTS[h]) else m.tex:SetTexCoord(unpack(HAPPY_COORDS[h])) end
    m.level = h
    m:Show()
end

-- The /gff status line: fresh raw reads, the source used and whether the face is up.
function Happy.Status(pf)
    local d = Happy.diag
    local ok, err = pcall(Happy.Gate)
    if not ok then d.err = "gate: " .. tostring(err) end
    local h
    ok, h = pcall(Happy.Read)
    if not ok then d.err = "read: " .. tostring(h); h = nil end
    d.level = h or (d.secret and Happy.last) or nil
    local m = pf and pf.happyFrame
    local icon = not m and "not built" or (m:IsVisible() and "shown") or (m:IsShown() and "shown, pet frame hidden")
        or "hidden"
    return "pet happiness: " .. OnOff(db.petHappiness)
        .. DOT .. "hunter " .. tostring(d.hunter) .. DOT .. "pet out " .. tostring(d.exists)
        .. DOT .. "GetPetHappiness " .. tostring(d.gph) .. DOT .. "HasPetUI " .. tostring(d.petui)
        .. DOT .. "UnitPower happiness " .. tostring(d.power)
        .. DOT .. "source " .. tostring(d.source) .. DOT .. "level " .. tostring(d.level or "-")
        .. DOT .. "icon " .. icon .. (m and m.dots and " (dots: no face texture)" or "")
        .. DOT .. "last error " .. tostring(blocked.happiness or d.err or "none")
end

-- Show or hide the mark. idx is the unit's raid target index and may be secret: it is never
-- tested, only handed to the client's own setter inside a pcall; if that refuses it, the mark
-- is hidden. Texcoords by hand when the client has no SetRaidTargetIconTexture.
function Look.UpdateMark(f, idx)
    local t = f.raidIcon
    if not t then return end
    if not db.raidMark or type(idx) == "nil" then t:Hide(); return end
    local setter = _G.SetRaidTargetIconTexture
    local plain = Plain(idx)
    if plain ~= nil then
        if type(plain) ~= "number" or plain ~= plain or plain < 1 or plain > 8 then t:Hide(); return end
        t:SetTexture(RAID_ICONS)
        if type(setter) == "function" then
            setter(t, plain)
        else
            local i = math.floor(plain) - 1
            local col, row = i % 4, math.floor(i / 4)
            t:SetTexCoord(col * 0.25, (col + 1) * 0.25, row * 0.25, (row + 1) * 0.25)
        end
        t:Show()
        return
    end
    if type(setter) == "function" then
        t:SetTexture(RAID_ICONS)
        if pcall(setter, t, idx) then t:Show(); return end
    end
    t:Hide()
end
end

local InCombat = BF.InCombat

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

local AddOnLoaded = BF.AddOnLoaded

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

-- "950", "12.3k", "1.2M" (the library's ShortNumber, the same text for the plain numbers used here).
local Short = BF.ShortNumber

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
    pvp = "read the PvP flag and its timer",
    threat = "read threat for unit frames",
    auras = "read auras for unit frames",
    range = "read party range",
    combo = "read combo points",
    secrettext = "write hidden health and power values as text",
    powerhide = "hide an empty power line from hidden values",
    healpred = "draw heal prediction and absorbs",
    powercost = "mark a spell's cost on the player's power bar",
    mana = "show the player's mana under a form's power",
    happiness = "read the hunter pet's happiness",
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
    powercost = function(f) if f.costFrame then f.costFrame:Hide() end end,
    mana = function(f)
        if not f.mana then return end
        f.mana:Hide()
        f.manaShown = false
        f.health:SetHeight(f.powerShown == false and (f.layout.hp + 1 + f.layout.mp) or f.layout.hp)
    end,
    pvp = function(f)
        if f.pvpIcon then f.pvpIcon:Hide() end
        if f.pvpTimer then f.pvpTimer:SetText(""); f.pvpTimer:Hide() end
        f.pvpKind, f.pvpTicking = nil, nil
    end,
    happiness = function(f) if f.happyFrame then f.happyFrame:Hide(); f.happyFrame.level = nil end end,
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

-- Blizzard's FACTION_BAR_COLORS by reaction (1.2.11; 1.2.8-1.2.10 used our own palette).
local function ReactionRGB(unit)
    local r = Num(UnitReaction(unit, "player"))
    local t = type(_G.FACTION_BAR_COLORS) == "table" and _G.FACTION_BAR_COLORS[r or 4]
    if type(t) == "table" and type(t.r) == "number" then return t.r, t.g, t.b end
    local c = (not r or r == 4) and Look.NEUTRAL or (r < 4 and Look.HOSTILE) or Look.FRIENDLY
    return c[1], c[2], c[3]
end

local function HealthRGB(unit)
    if Plain(UnitIsConnected(unit)) == false then return Look.TAPPED[1], Look.TAPPED[2], Look.TAPPED[3] end
    if Plain(UnitIsDeadOrGhost(unit)) == true then return Look.DEAD[1], Look.DEAD[2], Look.DEAD[3] end
    local isPlayer = Plain(UnitIsPlayer(unit)) == true
    if not isPlayer and type(_G.UnitIsTapDenied) == "function" and Plain(UnitIsTapDenied(unit)) == true then
        return Look.TAPPED[1], Look.TAPPED[2], Look.TAPPED[3]
    end
    if isPlayer then
        if db.classColor then
            local r, g, b = ClassRGB(ClassToken(unit))
            if r then return r, g, b end
        end
        return Look.HEALTH[1], Look.HEALTH[2], Look.HEALTH[3]
    end
    return ReactionRGB(unit)
end

local function PowerRGB(token)
    local pc = token and type(_G.PowerBarColor) == "table" and _G.PowerBarColor[token]
    if type(pc) == "table" and type(pc.r) == "number" then return pc.r, pc.g, pc.b end
    local c = token and POWER_COLORS[token]
    if c then return c[1], c[2], c[3] end
    return 0.6, 0.6, 0.6
end

-- Level colour against the player's own level, as the default frames do it.
local function LevelRGB(lvl)
    return BF.LevelDifficultyColor(lvl, Num(UnitLevel("player")))
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
-- the aura is still on. The library's TimeShort.
AuraTime.Text = BF.TimeShort

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
local HealPred = { dbg = {} }   -- Build, Update, Hide, Fake, Method, HotLines, HotDebug, OnCast, CastPreview; TicksLeft, StableAmount, ClampHot, HealLayout (pure)
do
-- 1.2.11: Blizzard's colours (CompactUnitFrame / unit frame heal prediction); no global holds them.
local MY = { 0.0, 0.827, 0.765, 0.85 }   -- your heals: Blizzard's teal-green
local ALL = { 0.0, 0.631, 0.557, 0.55 }  -- everyone's heals: Blizzard's darker teal
local HOT = { 0.95, 0.85, 0.30, 0.55 }   -- what active HoTs will still heal (1.2.7): Blizzard has none, so our yellow
-- 1.5.0: overheal, past the bar's right edge. One reddish segment in two tints: the part of the
-- incoming (cast) heals that overflows in red, the HoT part after it in orange-red.
local OVER_INC = { 1.0, 0.25, 0.25, 0.5 }
local OVER_HOT = { 1.0, 0.55, 0.20, 0.5 }
local ABSORB = { 1.0, 1.0, 1.0, 0.55 }   -- totalAbsorb: white, with Blizzard's stripes where found
local HEAL_ABSORB = { 1.0, 0.0, 0.0, 0.75 }   -- healAbsorb: red
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

-- HoT prediction (1.2.7, reworked 1.2.10): a yellow segment after the green incoming heals, the
-- healing every active HoT on the unit (from any healer) will still do before it runs out.
--
-- Where the number comes from, best source first:
--   1. The client's own heal prediction. Retail's calculator (12.x) and UnitGetIncomingHeals
--      only predict cast heals - the green - and have no HoT split: no HoT clamp mode, no HoT
--      getter, no HoT flag on UnitGetIncomingHeals (classic HealComm's DIRECT / HOT flags are a
--      library of its own, not in the client). /gff status lists any calculator method whose
--      name says HoT or periodic, so a client that grows one shows it.
--   2. So it is summed from the unit's buffs: C_UnitAuras.GetAuraDataByIndex(unit, i,
--      "HELPFUL"). A buff is a known HoT by spell ID (HOTS below: the tick interval and which
--      effect is the periodic one) or, since 1.2.10, by its localized name (the names of those
--      IDs, plus the English ones), so a client with other rank IDs still matches. The per-tick
--      amount is aura.points where that holds a number; otherwise (1.2.10) the aura's own
--      tooltip is read - C_TooltipInfo by aura instance ID or index, else a hidden GameTooltip -
--      and its text parsed: "Heals 32 damage every 3 seconds." is per tick, "Heals 66 damage
--      over 6 sec." a total spread over the ticks. 1.4.4: an amount once read is kept with the
--      HoT (one entry per aura instance, per unit GUID) and preferred over a new tooltip read,
--      so the total no longer flips between two sources; when neither points nor the aura
--      tooltip give one, the amount last read for that spell rank, the spell's own description
--      (C_Spell.GetSpellDescription) or the rank's base value (no +healing) stand in, and the
--      aura tooltip is tried again every HOT_RETRY s (up to 1.4.3 a failed read was not
--      retried for 10 s, so a Rejuvenation applied a moment before its tooltip was ready had no
--      segment for most of its 12 s). The ticks left are counted from the tick schedule,
--      start = expirationTime - duration (TicksLeft).
--   3. On this client auras are secret while you are in combat (see Auras below), and reading
--      them by index is then refused. Up to 1.4.3 the yellow segment was hidden then. Since
--      1.4.4 each secret aura is skipped, not the whole scan, the HoTs read before stay in the
--      memory until they run out (or the client says the instance is gone), and a HoT you cast
--      yourself in combat is added from UNIT_SPELLCAST_SENT / _SUCCEEDED (its target by name,
--      the amount as above), so your own Rejuvenation or Renew shows in combat too. A light
--      ticker redraws the segment as each tick is due (f.hotNext), not only on events.
--      /gff hotdebug [unit] says, per HoT, where each number came from and why it adds nothing.
-- Clamped as the green: when health, maximum and incoming heals are plain the sum is cut to the
-- missing health left after the incoming heals; otherwise the health bar clips its children,
-- so nothing is drawn past its end either way. 1.2.10: the yellow bar is anchored to the green
-- bar's edge only while the green bar is shown, else to the health fill itself (a hidden bar's
-- fill is no reliable anchor), and the absorb bar likewise to the last shown segment.
-- ---------------------------------------------------------------------------

-- [spellId] = { tick interval in seconds, index of the periodic effect in aura.points,
--   duration in seconds, the rank's base heal per tick (no +healing) } - the last two where known
local HOTS = {}
local function AddHots(interval, effect, ids, dur, base)
    for k, id in ipairs(ids) do HOTS[id] = { interval, effect, dur, base and base[k] } end
end
-- Renew, ranks 1-10 (15 s, 5 ticks)
AddHots(3, 1, { 139, 6074, 6075, 6076, 6077, 6078, 10927, 10928, 10929, 25315 }, 15,
    { 9, 20, 35, 49, 63, 80, 102, 130, 162, 194 })
-- Rejuvenation, ranks 1-11 (12 s, 4 ticks)
AddHots(3, 1, { 774, 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841, 25299 }, 12,
    { 8, 14, 29, 45, 61, 76, 97, 122, 152, 189, 222 })
-- Regrowth, ranks 1-9: effect 1 is the direct heal, the HoT is effect 2 (21 s, 7 ticks)
AddHots(3, 2, { 8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858 }, 21,
    { 14, 25, 37, 49, 61, 78, 98, 123, 152 })
-- Lifebloom, where the client has it
AddHots(1, 1, { 33763 })
-- First Aid bandages (a channelled HoT on the target), Linen to Heavy Runecloth
AddHots(1, 1, { 746, 1159, 3267, 3268, 7926, 7927, 10838, 10839, 18608, 18610 })
-- English aura names, matched too: [name] = a spell ID of that HoT in HOTS
local HOT_ENGLISH = { Renew = 139, Rejuvenation = 774, Regrowth = 8936, Lifebloom = 33763, ["First Aid"] = 746 }

local MAX_AURAS = 40
local hotWhy = {}       -- [unit] = what its yellow segment did at the last update, for /gff status
local overWhy = {}      -- [unit] = what its overheal segment did at the last update (1.5.0)
local hotNames          -- [localized name] = HOTS entry, built on first use
local HOT_SLACK = 0.1   -- s: a tick due this soon counts as landed (server tick vs our clock)
local HOT_RETRY = 2     -- s before an aura tooltip that gave no amount is read again
local MAX_GUIDS = 40    -- units whose HoTs are remembered before that memory is cleared
local hotMem = {}       -- [unit GUID] = { [aura key] = HoT entry }: the last good reading (1.4.4)
local hotMemCount = 0
local spellMem = {}     -- [spellId] = { per, interval }: the amount last read for that rank
local lastSent          -- { id, guid, at, cast, how }: your last UNIT_SPELLCAST_SENT of a known HoT
local castPv            -- the HoT spell you are casting now (1.5.0, HealPred.OnCast): its target and amounts
local PREVIEW_MAX = 10  -- s: a cast preview older than this is dropped (a missed STOP event)
local scanTip           -- our hidden GameTooltip, the last way to read an aura's tooltip
local SCAN_TIP = "GaarFramesForeverHotTip"

local function PlainString(v)
    v = Plain(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

-- A spell's localized name, or nil.
local function SpellNameOf(id)
    local C = _G.C_Spell
    if type(C) == "table" and type(C.GetSpellName) == "function" then
        local ok, n = pcall(C.GetSpellName, id)
        if ok and PlainString(n) then return n end
    end
    if type(C) == "table" and type(C.GetSpellInfo) == "function" then
        local ok, info = pcall(C.GetSpellInfo, id)
        if ok and type(info) == "table" and PlainString(info.name) then return info.name end
    end
    if type(_G.GetSpellInfo) == "function" then
        local ok, n = pcall(_G.GetSpellInfo, id)
        if ok and PlainString(n) then return n end
    end
    return nil
end

local function HotNames()
    if hotNames then return hotNames end
    local names, found = {}, 0
    for id, hot in pairs(HOTS) do
        local n = SpellNameOf(id)
        if n then
            found = found + 1
            names[n] = names[n] or hot
        end
    end
    for n, id in pairs(HOT_ENGLISH) do names[n] = names[n] or HOTS[id] end
    -- No name resolved yet (spell data still loading): use the English ones, ask again later.
    if found > 0 then hotNames = names end
    return names
end

-- The HOTS entry of an aura and how it matched ("id" or "name"), or nil.
local function HotOf(a)
    local id = Num(a.spellId)
    if id and HOTS[id] then return HOTS[id], "id" end
    local n = PlainString(a.name)
    if n and HotNames()[n] then return HotNames()[n], "name" end
    return nil
end

-- The plain per-tick amount of one HoT aura from aura.points, or nil.
local function TickAmount(points, effect)
    points = Plain(points)
    if type(points) ~= "table" then return nil end
    -- A list of only the aura's own effects has the HoT first, even for Regrowth.
    local v = Plain(points[effect])
    if v == nil then v = Plain(points[1]) end
    v = Num(v)
    if v and v > 0 then return v end
    return nil
end

-- The text of a C_TooltipInfo tooltip, its lines joined, or nil.
local function InfoText(data)
    data = Plain(data)
    if type(data) ~= "table" then return nil end
    local lines = Plain(data.lines)
    if type(lines) ~= "table" then return nil end
    local out = {}
    for _, line in ipairs(lines) do
        line = Plain(line)
        if type(line) == "table" then
            local t = PlainString(line.leftText)
            if not t and type(Plain(line.args)) == "table" then   -- 10.0's args form
                for _, arg in ipairs(line.args) do
                    if type(arg) == "table" and Plain(arg.field) == "leftText" then t = PlainString(arg.stringVal) end
                end
            end
            if t then out[#out + 1] = t end
        end
    end
    return #out > 0 and table.concat(out, " | ") or nil
end

-- The aura's tooltip text out of combat, and how it was read; nil when nothing could be read.
local function AuraTooltip(unit, a, index)
    local T = _G.C_TooltipInfo
    local iid = Num(a.auraInstanceID)
    if type(T) == "table" then
        local tries = {
            iid and T.GetUnitBuffByAuraInstanceID and { T.GetUnitBuffByAuraInstanceID, unit, iid, "GetUnitBuffByAuraInstanceID" },
            T.GetUnitAura and { T.GetUnitAura, unit, index, "HELPFUL", "GetUnitAura" },
            T.GetUnitBuff and { T.GetUnitBuff, unit, index, "GetUnitBuff" },
        }
        for k = 1, 3 do
            local t = tries[k]
            if t and type(t[1]) == "function" then
                local ok, data
                if #t == 5 then ok, data = pcall(t[1], t[2], t[3], t[4]) else ok, data = pcall(t[1], t[2], t[3]) end
                local text = ok and InfoText(data)
                if text then return text, "C_TooltipInfo." .. t[#t] end
            end
        end
    end
    if not scanTip then
        local ok, tip = pcall(CreateFrame, "GameTooltip", SCAN_TIP, _G.UIParent, "GameTooltipTemplate")
        scanTip = ok and tip or false
    end
    if not scanTip then return nil end
    local tip = scanTip
    local ok = pcall(function()
        tip:SetOwner(_G.UIParent, "ANCHOR_NONE")
        tip:ClearLines()
        if iid and type(tip.SetUnitBuffByAuraInstanceID) == "function" then
            tip:SetUnitBuffByAuraInstanceID(unit, iid)
        elseif type(tip.SetUnitAura) == "function" then
            tip:SetUnitAura(unit, index, "HELPFUL")
        else
            tip:SetUnitBuff(unit, index)
        end
    end)
    if not ok then return nil end
    local out = {}
    local n = Num(tip:NumLines()) or 0
    for i = 1, n do
        local fs = _G[SCAN_TIP .. "TextLeft" .. i]
        local t = fs and PlainString(fs:GetText())
        if t then out[#out + 1] = t end
    end
    tip:Hide()
    return #out > 0 and table.concat(out, " | ") or nil, "GameTooltip"
end

-- From tooltip text: per tick and interval ("Heals 32 damage every 3 seconds."), or total and
-- seconds ("Heals 66 damage over 6 sec."). English text; nil when neither form is found.
local function ParseHeal(text)
    local s = text:lower():gsub("(%d),(%d)", "%1%2")
    local amt, every = s:match("(%d+)%D-every (%d+%.?%d*) sec")
    if amt then return tonumber(amt), tonumber(every) end
    amt = s:match("(%d+)%D-every sec")   -- "every second"
    if amt then return tonumber(amt), 1 end
    local total, over = s:match("(%d+)%D-over (%d+%.?%d*) sec")
    if total then return nil, nil, tonumber(total), tonumber(over) end
    return nil
end

-- Ticks of one HoT still to land at now, and the time that count next drops (nil at 0). Pure
-- (1.4.4). With the duration known, ticks land at start + k * interval, start = exp - dur,
-- k = 1 .. floor(dur / interval): counted from that schedule the count only ever goes down, and
-- a duration that is not a whole number of ticks no longer counts a tick that never comes.
-- Without it (or with a timeMod other than 1) ticks are counted back from the expiration. A
-- tick due within HOT_SLACK counts as landed either way.
function HealPred.TicksLeft(now, exp, dur, interval, tm)
    if type(now) ~= "number" or type(exp) ~= "number" or type(interval) ~= "number" or interval <= 0
        or exp <= now then
        return 0
    end
    tm = (type(tm) == "number" and tm > 0) and tm or 1
    if type(dur) == "number" and dur > 0 and tm == 1 then
        local n = math.floor(dur / interval + 0.01)
        local start = exp - dur
        local done = math.floor((now + HOT_SLACK - start) / interval + 1e-6)
        if done < 0 then done = 0 end
        if done >= n then return 0 end
        return n - done, start + (done + 1) * interval - HOT_SLACK
    end
    local r = math.ceil(((exp - now) / tm - HOT_SLACK) / interval - 1e-6)
    if r <= 0 then return 0 end
    return r, exp - ((r - 1) * interval + HOT_SLACK) * tm
end

-- The per-tick amount of HoT entry e, kept stable (1.4.4). Plain points win and are kept; when
-- they are not readable the kept amount stands ("cached ..."), so the total no longer flips
-- between the points and a tooltip reading from one update to the next. Nil when e has no
-- amount yet. Pure.
function HealPred.StableAmount(e, fromPoints, interval)
    if type(fromPoints) == "number" and fromPoints > 0 then
        e.per, e.interval, e.source, e.weak = fromPoints, interval, "points", nil
        return fromPoints, interval, "points"
    end
    if e.per then return e.per, e.interval, "cached " .. tostring(e.source) end
    return nil
end

-- The HoT sum cut to the missing health left after the incoming heals (1.4.4: one place, one
-- order), and whether it could be cut. With max, health or incoming heals not plain the sum is
-- only cut to the maximum, and the clipping health bar does the rest. Pure.
function HealPred.ClampHot(total, mx, cur, inc)
    if type(total) ~= "number" or total <= 0 then return 0, true end
    local m, c, i = Num(mx), Num(cur), Num(inc)
    if m and c and i then return Clamp(m - c - i, 0, total), true end
    if m and total > m then return m, false end
    return total, false
end

-- The whole heal layout of a health bar as shares of its width (1.5.0): health, then the
-- incoming heals (green) and the HoTs (yellow), each cut at the bar's end in that order, and
-- whatever does not fit past the end (overFrac, at most overCap), split into the part that is
-- incoming heals (overIncFrac, drawn first) and the HoT part (overHotFrac). The yellow inside the
-- bar is the same cut as ClampHot. Nil when health, maximum, incoming heals or HoTs are not plain
-- (secret); an absent incoming heal or HoT counts as 0. Pure.
function HealPred.HealLayout(cur, mx, incoming, hot, overCap)
    local m, c = Num(mx), Num(cur)
    local i = incoming == nil and 0 or Num(incoming)
    local h = hot == nil and 0 or Num(hot)
    if not m or m <= 0 or not c or not i or not h then return nil end
    if i < 0 then i = 0 end
    if h < 0 then h = 0 end
    local cap = Num(overCap) or 0
    if cap < 0 then cap = 0 end
    local missing = m - Clamp(c, 0, m)
    local incIn = math.min(i, missing)
    local hotIn = math.min(h, missing - incIn)
    local incOver, hotOver = (i - incIn) / m, (h - hotIn) / m
    local over = math.min(incOver + hotOver, cap)
    local overInc = math.min(incOver, over)
    return { incomingWidthFrac = incIn / m, hotWidthFrac = hotIn / m, overFrac = over,
        overIncFrac = overInc, overHotFrac = over - overInc }
end

-- A stand-in amount for a HoT spell rank when its aura gives none (1.4.4): what was last read
-- for that rank, else the spell's own description, else the rank's base value. Per tick,
-- interval, duration (or nil) and the source; nil when there is none.
local function SpellAmount(id, hot)
    if not id then return nil end
    local m = spellMem[id]
    if m then return m.per, m.interval, hot[3], "last read for this rank" end
    local desc
    local C = _G.C_Spell
    if type(C) == "table" and type(C.GetSpellDescription) == "function" then
        local ok, d = pcall(C.GetSpellDescription, id)
        desc = ok and PlainString(d) or nil
    end
    if not desc and type(_G.GetSpellDescription) == "function" then
        local ok, d = pcall(_G.GetSpellDescription, id)
        desc = ok and PlainString(d) or nil
    end
    if desc then
        local p, every, total, over = ParseHeal(desc)
        if p and every and every > 0 then return p, every, hot[3], "spell description" end
        if total and over and over > 0 and total > 0 then
            return total * hot[1] / over, hot[1], over, "spell description"
        end
    end
    if hot[4] then return hot[4], hot[1], hot[3], "rank base (no +healing)" end
    return nil
end

-- The direct heal of a spell that heals and then leaves a HoT (Regrowth: effect 1 is the direct
-- heal), per rank: low and high, base values (no +healing). Pure HoTs have none.
local DIRECT = {}
do
    local ids = { 8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858 }
    local lo = { 93, 176, 255, 336, 425, 534, 672, 839, 1003 }
    local hi = { 107, 201, 290, 378, 479, 600, 750, 935, 1119 }
    for k, id in ipairs(ids) do DIRECT[id] = (lo[k] + hi[k]) / 2 end
end

-- The direct part of a heal + HoT cast (1.5.0), for the green when the client's own heal
-- prediction leaves your cast out: the spell's description ("Heals a friendly target for 93 to
-- 107 and another 98 over 21 sec.", the middle of the range), else the rank's base value. The
-- amount and its source, or nil for a pure HoT.
local function DirectAmount(id, hot)
    if not id or not hot or hot[2] == 1 then return nil end
    local desc
    local C = _G.C_Spell
    if type(C) == "table" and type(C.GetSpellDescription) == "function" then
        local ok, d = pcall(C.GetSpellDescription, id)
        desc = ok and PlainString(d) or nil
    end
    if desc then
        local lo, hi = desc:lower():gsub("(%d),(%d)", "%1%2"):match("for (%d+) to (%d+)")
        lo, hi = tonumber(lo), tonumber(hi)
        if lo and hi and hi >= lo and lo > 0 then return (lo + hi) / 2, "spell description" end
    end
    if DIRECT[id] then return DIRECT[id], "rank base (no +healing)" end
    return nil
end

-- The aura is yours: its sourceUnit is plain and is the player.
local function IsMine(a)
    local src = PlainString(a.sourceUnit)
    if not src then return false end
    if src == "player" then return true end
    local ok, same = pcall(UnitIsUnit, src, "player")
    return ok and Plain(same) == true
end

local SECRET_FIELDS = { "spellId", "name", "points", "duration", "expirationTime", "auraInstanceID", "sourceUnit" }

-- The aura fields that are secret now, as "points, duration", or nil.
local function SecretFields(a)
    local out
    for _, k in ipairs(SECRET_FIELDS) do
        if IsSecret(a[k]) then out = out and (out .. ", " .. k) or k end
    end
    return out
end

-- Key of a HoT aura in its unit's memory: the aura instance, else spell and caster.
local function AuraKey(a)
    local iid = Num(a.auraInstanceID)
    if iid then return "i" .. iid end
    local src = PlainString(a.sourceUnit)
    local caster = src and type(_G.UnitGUID) == "function" and PlainString(_G.UnitGUID(src)) or "?"
    return tostring(Num(a.spellId) or PlainString(a.name) or "?") .. ":" .. caster
end

-- Your own reading of a rank is remembered for the next cast of it (SpellAmount).
local function Remember(e)
    if e.mine and e.id and e.per and not e.weak then spellMem[e.id] = { per = e.per, interval = e.interval } end
end

-- Fills HoT entry e from aura a (1.4.4). Each field that is plain now replaces the kept one; a
-- secret one leaves the kept value, so a value turning secret for an update no longer hides or
-- changes the segment. The amount (StableAmount): plain points, else the kept amount; with
-- none, or only a stand-in, the aura tooltip (again after HOT_RETRY s when it gave nothing),
-- and with still none a stand-in (SpellAmount).
local function ReadAura(unit, a, index, hot, how, e, now)
    local id = Num(a.spellId)
    if id and e.id and e.id ~= id then   -- another rank under the same key: start over
        for k in pairs(e) do e[k] = nil end
    end
    e.id, e.name, e.how = id or e.id, PlainString(a.name) or e.name, how
    e.iid = Num(a.auraInstanceID) or e.iid
    e.exp = Num(a.expirationTime) or e.exp
    e.dur = Num(a.duration) or e.dur
    e.tm = Num(a.timeMod) or e.tm
    e.mine = IsMine(a) or e.mine
    e.srcKnown = PlainString(a.sourceUnit) ~= nil
    e.secret, e.seen = SecretFields(a), now
    local points = TickAmount(a.points, hot[2])
    e.pointsWhy = not points and (IsSecret(a.points) and "points secret" or "points empty") or nil
    local per, _, source = HealPred.StableAmount(e, points, hot[1])
    e.src = source
    if per and not e.weak then Remember(e); return end
    if e.failAt and now - e.failAt < HOT_RETRY then return end
    local text, by = AuraTooltip(unit, a, index)
    local p, every, total, over
    if text then p, every, total, over = ParseHeal(text) end
    local interval = hot[1]
    if p and every and every > 0 then
        interval = every
    elseif total and over and over > 0 and total > 0 then
        p = total * interval / over
    end
    if p and p > 0 then
        e.per, e.interval, e.source, e.weak, e.failAt, e.tipWhy = p, interval, "tooltip", nil, nil, nil
        e.src = "tooltip (" .. tostring(by) .. ")"
        Remember(e)
        return
    end
    e.failAt, e.tipWhy = now, text and "aura tooltip has no heal amount" or "no aura tooltip"
    if per then return end   -- the stand-in already kept
    local sp, si, _, ss = SpellAmount(e.id, hot)
    if sp then e.per, e.interval, e.source, e.weak, e.src = sp, si, ss, true, ss end
end

-- A HoT in memory that a partial scan did not see: false when the client says its aura
-- instance is gone; its plain fields are refreshed when the client gives them.
local function StillThere(unit, e)
    local C = _G.C_UnitAuras
    if not e.iid or type(C) ~= "table" or type(C.GetAuraDataByAuraInstanceID) ~= "function" then return true end
    local ok, a = pcall(C.GetAuraDataByAuraInstanceID, unit, e.iid)
    if not ok then return true end
    if type(a) == "nil" then return false end
    a = Plain(a)
    if type(a) == "table" then
        e.exp = Num(a.expirationTime) or e.exp
        e.dur = Num(a.duration) or e.dur
    end
    return true
end

local function SetMem(guid, mem)
    if not hotMem[guid] then
        hotMemCount = hotMemCount + 1
        if hotMemCount > MAX_GUIDS then hotMem, hotMemCount = {}, 1 end
    end
    hotMem[guid] = mem
end

-- The healing every known HoT on unit will still do: total (nil when none can be counted), why
-- nothing is drawn (or nil), with detail a list of the HoTs (and .unmatched, .info), and the
-- time the total next drops (or nil). 1.4.4: each HoT read is kept in the unit's memory
-- (hotMem, by GUID); a secret aura is skipped, not the whole scan, and when the scan could not
-- read every aura the HoTs remembered (and your own casts, OnCast) stay until they run out.
local function HotScan(unit, detail)
    local list = detail and { unmatched = {} } or nil
    local C = _G.C_UnitAuras
    if type(C) ~= "table" or type(C.GetAuraDataByIndex) ~= "function" then return nil, "no aura API", list end
    local now = Num(type(_G.GetTime) == "function" and _G.GetTime() or nil)
    if not now then return nil, "no clock", list end
    local guid = type(_G.UnitGUID) == "function" and PlainString(_G.UnitGUID(unit)) or nil
    if Plain(UnitIsDeadOrGhost(unit)) == true then
        if guid then hotMem[guid] = nil end
        return 0, "unit dead", list
    end
    local old = guid and hotMem[guid] or {}
    local cur = {}
    local S = _G.C_Secrets
    local ask = type(S) == "table" and type(S.ShouldUnitAuraIndexBeSecret) == "function"
        and S.ShouldUnitAuraIndexBeSecret or nil
    local complete, unread, refused = true, 0, false
    for i = 1, MAX_AURAS do
        local secret = false
        if ask then
            local ok, s = pcall(ask, unit, i, "HELPFUL")
            secret = ok and Plain(s) == true
        end
        if secret then
            complete, unread = false, unread + 1
        else
            local ok, raw = pcall(C.GetAuraDataByIndex, unit, i, "HELPFUL")
            if not ok then complete, refused = false, true; break end
            if type(raw) == "nil" then break end   -- type() is allowed on a secret
            local a = Plain(raw)
            if type(a) ~= "table" then
                complete, unread = false, unread + 1
            else
                local hot, how = HotOf(a)
                if hot then
                    local key = AuraKey(a)
                    local e = cur[key] or old[key] or {}
                    ReadAura(unit, a, i, hot, how, e, now)
                    cur[key] = e
                else
                    if IsSecret(a.spellId) and IsSecret(a.name) then   -- could be a HoT
                        complete, unread = false, unread + 1
                    end
                    if list then
                        list.unmatched[#list.unmatched + 1] = (PlainString(a.name) or "?") .. " "
                            .. tostring(Num(a.spellId) or "?")
                    end
                end
            end
        end
    end
    -- HoTs remembered and not seen now: kept while the scan was partial; your casts also for a
    -- second after a full scan, as the aura may not be on the unit yet.
    local dropped = 0
    for key, e in pairs(old) do
        if not cur[key] then
            local keep
            if e.cast then
                keep = e.exp and e.exp > now and (not complete or now - e.at < 1)
            else
                keep = not complete and e.exp and e.exp > now and StillThere(unit, e)
                -- Your HoT read now under another key (its instance ID turned secret): that one counts.
                if keep and e.mine then
                    for _, o in pairs(cur) do
                        if o.mine and o.id == e.id and o.seen == now then keep = false; break end
                    end
                end
            end
            if keep then cur[key] = e elseif not complete then dropped = dropped + 1 end
        end
    end
    -- A cast stands in only until its aura is read: then the aura counts, not both.
    for key, e in pairs(cur) do
        if e.cast then
            for _, o in pairs(cur) do
                if not o.cast and o.seen == now and o.name == e.name and (o.mine or not o.srcKnown)
                    and o.per and o.exp then
                    cur[key] = nil
                    break
                end
            end
        end
    end
    if guid then SetMem(guid, cur) end
    -- 1.5.0: the HoT spell you are casting on this unit counts from the cast's start, and your
    -- own HoT of that name already on it does not (the cast replaces it).
    local pv = HealPred.CastPreview(now)
    if pv and (not guid or pv.guid ~= guid) then pv = nil end
    local total, hots, missing, nextAt = 0, 0, false, nil
    if pv then
        total, hots = pv.total, 1
        if list then list.preview = pv end
    end
    for _, e in pairs(cur) do
        if pv and e.mine and e.name == pv.name then
            if list then list.replaced = (list.replaced or 0) + 1 end
        else
            hots = hots + 1
            local ticks, at = 0, nil
            if e.per and e.exp and e.exp > 0 then
                ticks, at = HealPred.TicksLeft(now, e.exp, e.dur, e.interval, e.tm)
                total = total + e.per * ticks
            else
                missing = true
            end
            if (e.weak or not e.per) and e.seen == now and e.failAt then   -- the aura tooltip is read again
                local retry = e.failAt + HOT_RETRY
                if not at or retry < at then at = retry end
            end
            if at and (not nextAt or at < nextAt) then nextAt = at end
            if list then list[#list + 1] = { e = e, ticks = ticks, left = e.exp and e.exp - now, kept = e.seen ~= now } end
        end
    end
    if list then
        table.sort(list, function(x, y) return tostring(x.e.name) < tostring(y.e.name) end)
        list.info = { complete = complete, unread = unread, refused = refused, dropped = dropped, guid = guid }
    end
    if hots == 0 then
        if not complete then
            return nil, (refused and "auras secret (read refused)" or "auras secret") .. ", no HoT remembered", list
        end
        return 0, "no known HoT on the unit", list
    end
    if missing and total == 0 then return nil, "no HoT amount readable", list, nextAt end
    return total, nil, list, nextAt
end

-- Units a cast target's name is looked up on.
local CAST_UNITS = { "player", "target", "focus", "mouseover", "pet", "targettarget" }
for i = 1, 4 do CAST_UNITS[#CAST_UNITS + 1] = "party" .. i end
for i = 1, 40 do CAST_UNITS[#CAST_UNITS + 1] = "raid" .. i end

-- Every plain spelling of unit u's name (1.5.3): WoW Forever characters have surnames, and
-- UNIT_SPELLCAST_SENT gives "First Surname" where UnitName may give only the first name.
local function NameVariants(u)
    local out, seen = {}, {}
    local function add(n)
        n = PlainString(n)
        if n and not seen[n] then seen[n] = true; out[#out + 1] = n end
    end
    local function try(fn, ...)
        if type(fn) ~= "function" then return end
        local r = { pcall(fn, ...) }
        if not r[1] then return end
        local n, realm = PlainString(r[2]), PlainString(r[3])
        add(n)
        if n and realm then add(n .. "-" .. realm) end
    end
    try(_G.UnitName, u)
    try(_G.UnitFullName, u)
    try(_G.GetUnitName, u, false)
    try(_G.GetUnitName, u, true)
    -- "Name-Realm" without its realm.
    for i = 1, #out do add((out[i]:gsub("%-[^%- ]+$", ""))) end
    return out
end

-- The GUID (and unit token) a cast's target name belongs to. Exact name first, then
-- "variant Surname" (the name starts with the unit's name and a space), only when that is one
-- unit; if several share the prefix, you win when you are one of them.
local function GuidByName(name)
    local cands, byGuid = {}, {}
    for _, u in ipairs(CAST_UNITS) do
        local ok, ex = pcall(UnitExists, u)
        if ok and Plain(ex) == true then
            local guid = type(_G.UnitGUID) == "function" and PlainString(_G.UnitGUID(u)) or nil
            local key = guid or u
            if not byGuid[key] then
                byGuid[key] = true
                cands[#cands + 1] = { u = u, guid = guid, v = NameVariants(u) }
            end
        end
    end
    for _, c in ipairs(cands) do
        for _, n in ipairs(c.v) do
            if n == name then return c.guid, c.u end
        end
    end
    local hits = {}
    for _, c in ipairs(cands) do
        for _, n in ipairs(c.v) do
            if name:sub(1, #n + 1) == n .. " " then hits[#hits + 1] = c; break end
        end
    end
    if #hits == 1 then return hits[1].guid, hits[1].u end
    for _, c in ipairs(hits) do
        if c.u == "player" then return c.guid, c.u end
    end
    return nil
end

-- 1.5.1: the self-cast modifier is held, so the spell lands on you whatever the name says.
local function SelfCastHeld()
    if type(_G.IsModifiedClick) ~= "function" then return false end
    local ok, v = pcall(_G.IsModifiedClick, "SELFCAST")
    return ok and Plain(v) == true
end

-- The GUID a cast of yours lands on, and how that was decided (1.5.0). The name
-- UNIT_SPELLCAST_SENT gives is looked up on the units above; without a name, your target when
-- you can help it, else you (classic self-cast: an enemy or no target means the spell lands on
-- you). Nil GUID when the named unit is on none of those units.
-- 1.5.1: a self-cast landed on the wrong unit: with an enemy targeted (or the self-cast
-- modifier held) the name can be the enemy's, which was looked up on "target" and the preview
-- drawn on the enemy. A named unit you cannot help is now you, as the game does the cast.
local function CastTarget(name, sent)
    name = PlainString(name)
    local self = PlainString(_G.UnitGUID("player"))
    if sent and SelfCastHeld() then return self, "you (self-cast modifier)" end
    if name then
        local guid, unit = GuidByName(name)
        if guid and unit ~= "player" then
            local okA, help = pcall(_G.UnitCanAssist, "player", unit)
            if okA and Plain(help) == false then return self, "you (self-cast, " .. name .. " cannot be helped)" end
        end
        return guid, guid and (name .. ", by the cast's target name") or (name .. ", on no frame")
    end
    local okE, ex = pcall(UnitExists, "target")
    local okA, help = pcall(_G.UnitCanAssist, "player", "target")
    if okE and Plain(ex) == true and okA and Plain(help) == true then
        return PlainString(_G.UnitGUID("target")), "your friendly target"
    end
    return self, "you (self-cast)"
end

-- Same cast: by castGUID where both are plain, else by spell ID.
local function SameCast(pv, cast, id)
    if pv.cast and cast then return pv.cast == cast end
    return pv.id == id
end

-- The HoT spell you are casting now (1.5.0), or nil: dropped once it is older than PREVIEW_MAX
-- (a STOP that never came) and not shown with /gff hotcast off.
function HealPred.CastPreview(now)
    local pv = castPv
    if not pv then return nil end
    if type(now) == "number" and now - pv.at > PREVIEW_MAX then castPv = nil; return nil end
    if not db.hotCastPreview then return nil end
    return pv
end

-- UNIT_SPELLCAST_START of a HoT spell with a cast time (Regrowth): the preview of its HoT, on
-- the target UNIT_SPELLCAST_SENT named (else CastTarget), with the full HoT (per tick x ticks)
-- from SpellAmount and, for a heal + HoT spell, the direct part from DirectAmount. Returns the
-- target's GUID for the redraw.
local function StartPreview(id, cast, now)
    castPv = nil
    if not id then HealPred.dbg.startWhy = "spell ID hidden or missing"; return nil end
    local name = SpellNameOf(id)
    local hot = HotOf({ spellId = id, name = name })
    if not hot then HealPred.dbg.startWhy = "spell " .. id .. " " .. tostring(name) .. ": not a known HoT spell"; return nil end
    local s, guid, how = lastSent, nil, nil
    if s and s.id == id and now - s.at <= 5 and (not s.cast or not cast or s.cast == cast) then
        guid, how = s.guid, s.how
    else
        guid, how = CastTarget(nil)
    end
    if not guid then HealPred.dbg.startWhy = "no target GUID (" .. tostring(how) .. ")"; return nil end
    local per, interval, dur, source = SpellAmount(id, hot)
    dur = dur or hot[3]
    if not per or not interval or interval <= 0 or not dur then HealPred.dbg.startWhy = "no HoT amount for spell " .. id; return nil end
    local ticks = math.floor(dur / interval + 0.01)
    if ticks <= 0 then HealPred.dbg.startWhy = "no ticks"; return nil end
    local direct, directSrc = DirectAmount(id, hot)
    castPv = { id = id, name = name or tostring(id), guid = guid, how = how, cast = cast, at = now,
        per = per, interval = interval, ticks = ticks, total = per * ticks, source = source,
        direct = direct, directSrc = directSrc }
    HealPred.dbg.startWhy = "preview set on " .. tostring(how)
    return guid
end

-- Your own HoT casts (1.4.4), for combat, where auras are secret on this client:
-- UNIT_SPELLCAST_SENT names the target, _SUCCEEDED confirms the spell. The HoT is put in the
-- target's memory as if read (key "cast:<name>", so a recast replaces it), amount and duration
-- from SpellAmount, and stands in until its aura is read. Returns the target's GUID, so the
-- caller can redraw the frames showing it.
-- 1.5.0: a HoT spell with a cast time is shown from UNIT_SPELLCAST_START (StartPreview) and
-- cleared on _STOP, _FAILED and _INTERRUPTED of that cast; on _SUCCEEDED the preview hands over
-- to the memory entry above (and that, in turn, to the aura once it is readable), never both.
function HealPred.OnCast(event, unit, a2, a3, a4)
    if unit ~= "player" then return nil end
    if not db.hotPred or not db.healPrediction then castPv, lastSent = nil, nil; return nil end
    local now = Num(type(_G.GetTime) == "function" and _G.GetTime() or nil)
    if not now then return nil end
    if event == "UNIT_SPELLCAST_SENT" then   -- unit, target name, castGUID, spellID
        local id = Num(a4)
        lastSent = nil
        if not id or not HotOf({ spellId = id, name = SpellNameOf(id) }) then return nil end
        local guid, how = CastTarget(a2, true)
        lastSent = { id = id, guid = guid, how = how, at = now, cast = PlainString(a3) }
        return nil
    end
    -- _START, _STOP, _FAILED, _INTERRUPTED and _SUCCEEDED: unit, castGUID, spellID
    local cast, id = PlainString(a2), Num(a3)
    if event == "UNIT_SPELLCAST_START" then return StartPreview(id, cast, now) end
    local pv = castPv
    if pv and not SameCast(pv, cast, id) then pv = nil end
    if event ~= "UNIT_SPELLCAST_SUCCEEDED" then
        if pv then castPv = nil; return pv.guid end
        return nil
    end
    if pv then castPv = nil end
    -- The cast's own target (from its START) wins over a later SENT of another spell.
    local s = lastSent
    if pv then s = { id = pv.id, guid = pv.guid, at = pv.at }
    elseif not s or s.id ~= id or now - s.at > 5 or (s.cast and cast and s.cast ~= cast) then s = nil end
    lastSent = nil
    if not id or not s or not s.guid then return pv and pv.guid or nil end
    local name = SpellNameOf(id)
    local hot = HotOf({ spellId = id, name = name })
    if not hot then return s.guid end
    local per, interval, dur, source = SpellAmount(id, hot)
    dur = dur or hot[3]
    if not per or not dur then return s.guid end
    name = name or tostring(id)
    local mem = hotMem[s.guid] or {}
    -- A recast replaces your earlier one of that kind, also one only remembered from its aura.
    for k, o in pairs(mem) do
        if not o.cast and o.mine and o.name == name then mem[k] = nil end
    end
    mem["cast:" .. name] = { id = id, name = name, how = "your cast", per = per, interval = interval,
        source = source, src = "your cast, " .. source, weak = true, exp = now + dur, dur = dur,
        mine = true, cast = true, at = now, seen = now }
    SetMem(s.guid, mem)
    return s.guid
end

-- The direct part of your cast to add to the green on unit u (1.5.0), or 0. Only while a heal +
-- HoT spell of yours is being cast on u, and only when the client's own prediction of your
-- heals on u (UnitGetIncomingHeals(u, "player"), unclamped) is a plain 0: once it has shown
-- your cast (pv.client "yes") it is never added, so it is not counted twice. Secret or no API:
-- not added (the client is trusted).
local function OwnDirect(u)
    local pv = HealPred.CastPreview(Num(type(_G.GetTime) == "function" and _G.GetTime() or nil))
    if not pv or not pv.direct then return 0 end
    local guid = type(_G.UnitGUID) == "function" and PlainString(_G.UnitGUID(u)) or nil
    if not guid or guid ~= pv.guid then return 0 end
    if pv.client == "yes" then return 0 end
    local fn = _G.UnitGetIncomingHeals
    if type(fn) ~= "function" then pv.client = "unknown (no UnitGetIncomingHeals)"; return 0 end
    local ok, v = pcall(fn, u, "player")
    if not ok or IsSecret(v) then pv.client = "unknown (secret)"; return 0 end
    v = Num(v)
    if v and v > 0 then pv.client = "yes"; return 0 end
    pv.client = "no (0): direct part added from " .. tostring(pv.directSrc)
    return pv.direct
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

-- A value for /gff hotdebug: "secret" for a hidden one, tables flattened one level.
local function Raw(v)
    if IsSecret(v) then return "secret" end
    if type(v) == "table" then
        local out = {}
        for k = 1, 8 do
            if v[k] == nil then break end
            out[#out + 1] = Raw(v[k])
        end
        return "{" .. table.concat(out, ", ") .. "}"
    end
    if type(v) == "number" then return (v == math.floor(v)) and tostring(v) or string.format("%.2f", v) end
    return tostring(v)
end

-- The unit /gff status and /gff hotdebug look at: the target, else the player.
local function HotUnit()
    if Plain(UnitExists("target")) == true then return "target" end
    return "player"
end

-- One HoT of HotScan's list as a line: where each number came from, what is secret now, and,
-- when it adds nothing to the segment, why.
local function HotLine(x)
    local e = x.e
    local s = "  " .. tostring(e.name or "?") .. " (spell " .. tostring(e.id or "?") .. ", matched by "
        .. tostring(e.how) .. (e.mine and ", yours" or "") .. "): "
    local why
    if e.per then
        local src = x.kept and not e.cast and ("cached " .. tostring(e.source) .. ", aura not readable now")
            or tostring(e.src or e.source)
        s = s .. string.format("%d per tick every %ss from %s", math.floor(e.per + 0.5), Raw(e.interval), src)
    else
        s = s .. "no amount"
        why = "no amount: " .. tostring(e.pointsWhy or "points not read") .. ", "
            .. tostring(e.tipWhy or "aura tooltip not read yet") .. ", no last reading, spell description or rank base"
    end
    if x.left then
        s = s .. string.format(", %.1fs left, %d ticks = %d", x.left, x.ticks, math.floor((e.per or 0) * x.ticks + 0.5))
    elseif not why then
        why = "no expiration time read"
    end
    if not why and x.ticks == 0 then why = "no ticks left" end
    if e.weak and e.tipWhy then s = s .. " (stand-in: " .. e.tipWhy .. ")" end
    if e.secret then s = s .. DOT .. "secret now: " .. e.secret end
    if why then s = s .. DOT .. "ADDS NOTHING: " .. why end
    return s
end

-- A cast preview as text: spell, target, HoT amount and its source, the direct part and whether
-- the client's own prediction has your cast.
function HealPred.PreviewText(pv)
    local s = string.format("cast preview: %s (spell %s) on %s: HoT %d (%d x %d ticks every %ss) from %s",
        tostring(pv.name), tostring(pv.id), tostring(pv.how), math.floor(pv.total + 0.5),
        math.floor(pv.per + 0.5), pv.ticks, Raw(pv.interval), tostring(pv.source))
    if pv.direct then
        s = s .. string.format("; direct heal %d from %s, in the client's prediction of your heals: %s",
            math.floor(pv.direct + 0.5), tostring(pv.directSrc), tostring(pv.client or "not checked yet"))
    end
    return s
end

-- For /gff status and /gff hotdebug: lines on the yellow segment for unit (default the target,
-- else the player) right now, each HoT found with where its numbers came from, and why nothing
-- is drawn when it is not.
function HealPred.HotLines(unit)
    local u = unit or HotUnit()
    local lines = {}
    local state
    if not db.hotPred then
        state = "off (/gff hotpred on)"
    elseif not db.healPrediction then
        state = "not drawn: heal prediction is off (/gff healpred on)"
    elseif blocked.healpred then
        state = "not drawn: heal prediction refused (" .. blocked.healpred .. ")"
    end
    local total, why, list = HotScan(u, true)
    if not state then
        if not total or why then
            state = "not drawn: " .. tostring(why)
        else
            local m, cur = Num(UnitHealthMax(u)), Num(UnitHealth(u))
            if m and cur and cur >= m then
                state = string.format(db.overheal and "full health: all of it overheal, past the bar (HoTs would heal %d)"
                    or "not drawn: full health (HoTs would heal %d)", math.floor(total + 0.5))
            else
                state = string.format("HoTs will heal %d", math.floor(total + 0.5))
            end
        end
    end
    lines[1] = "hot prediction " .. OnOff(db.hotPred) .. DOT .. u .. ": " .. state
        .. DOT .. "last drawn: " .. (hotWhy[u] or "not drawn yet")
    local info = list and list.info
    if info and not info.complete then
        lines[#lines + 1] = string.format("  auras not all readable (in combat: %s): %d skipped%s, %d remembered HoT(s) gone"
            .. "; remembered HoTs and your casts are counted", tostring(InCombat()), info.unread,
            info.refused and ", read refused" or "", info.dropped)
    end
    if info and not info.guid then lines[#lines + 1] = "  unit GUID not readable: nothing is remembered for this unit" end
    if list and list.preview then lines[#lines + 1] = "  " .. HealPred.PreviewText(list.preview) end
    if list and list.replaced then
        lines[#lines + 1] = "  " .. list.replaced .. " HoT(s) of yours with that name not counted: the cast replaces them"
    end
    for _, x in ipairs(list or {}) do lines[#lines + 1] = HotLine(x) end
    lines[#lines + 1] = "  overheal " .. OnOff(db.overheal) .. string.format(" (cap %d%% of the bar)",
        math.floor((Num(db.overhealCap) or 0) * 100 + 0.5)) .. DOT .. "last drawn: " .. (overWhy[u] or "not drawn yet")
    if list and #list.unmatched > 0 then
        lines[#lines + 1] = "  other buffs (not a known HoT): " .. table.concat(list.unmatched, ", ")
    end
    lines[#lines + 1] = "  amount: aura points, else the aura tooltip, else the last reading of that rank, the spell"
        .. " description or the rank base" .. DOT .. "calculator HoT methods: " .. CalculatorHotMethods()
    return lines
end

-- /gff hotdebug cast (1.5.2): prints what your next cast does, on SENT, START and its end.
function HealPred.Trace(event, a2, a3, a4, ok, guid)
    local now = type(_G.GetTime) == "function" and Num(_G.GetTime()) or nil
    if not HealPred.dbg.traceUntil or not now or now > HealPred.dbg.traceUntil then HealPred.dbg.traceUntil = nil; return end
    local id = (event == "UNIT_SPELLCAST_SENT") and Num(a4) or Num(a3)
    if event == "UNIT_SPELLCAST_SENT" then
        if HealPred.dbg.traceId then return end
        HealPred.dbg.traceId = id
        Print("trace SENT: spell " .. tostring(id) .. " " .. tostring(SpellNameOf(id)) .. DOT .. "target name arg: "
            .. (PlainString(a2) or "(none/hidden)") .. DOT .. (ok and "" or "ERROR ") .. "known HoT: "
            .. tostring(id and HotOf({ spellId = id, name = SpellNameOf(id) }) ~= nil))
        if lastSent then Print("  resolved: " .. tostring(lastSent.how) .. DOT .. "GUID " .. tostring(lastSent.guid)) end
        return
    end
    if HealPred.dbg.traceId and id ~= HealPred.dbg.traceId then return end
    if event == "UNIT_SPELLCAST_START" then
        Print("trace START: " .. tostring(HealPred.dbg.startWhy) .. (ok and "" or (DOT .. "ERROR " .. tostring(guid))))
        for _, line in ipairs(HealPred.CastSummary()) do Print(line) end
    else
        Print("trace " .. event:gsub("UNIT_SPELLCAST_", "") .. ": cast ended")
        for _, line in ipairs(HealPred.CastSummary()) do Print(line) end
        HealPred.dbg.traceUntil, HealPred.dbg.traceId = nil, nil
    end
end

-- 1.5.2: the compact cast summary for /gff hotdebug and /gff hotdebug cast: spell, HoT amount,
-- the target and how it was decided, the frames drawing it, and each frame's yellow / overheal.
function HealPred.CastSummary()
    local now = Num(type(_G.GetTime) == "function" and _G.GetTime() or nil)
    local pv = HealPred.CastPreview(now)
    if not pv then
        return { "CAST: none pending" .. DOT .. "hotcast " .. OnOff(db.hotCastPreview) .. DOT .. "last START: " .. tostring(HealPred.dbg.startWhy or "none yet") }
    end
    local sub
    local C = _G.C_Spell
    if type(C) == "table" and type(C.GetSpellSubtext) == "function" then
        local ok, t = pcall(C.GetSpellSubtext, pv.id)
        sub = ok and PlainString(t) or nil
    end
    local out = { string.format("CAST: %s %s (id %s)%sHoT %d (%d x %d, %s)%sdirect %s%starget: %s", tostring(pv.name),
        sub or "", tostring(pv.id), DOT, math.floor(pv.total + 0.5), math.floor(pv.per + 0.5), pv.ticks, tostring(pv.source), DOT,
        pv.direct and math.floor(pv.direct + 0.5) or "?", DOT, tostring(pv.how)) }
    local any = false
    for u, f in pairs(real) do
        if f and not f.preview and f:IsVisible() and type(_G.UnitGUID) == "function" and PlainString(_G.UnitGUID(u)) == pv.guid then
            any = true
            out[#out + 1] = "  frame " .. u .. ": yellow " .. tostring(hotWhy[u] or "not drawn yet")
                .. DOT .. "over " .. tostring(overWhy[u] or "not drawn yet")
        end
    end
    if not any then out[#out + 1] = "  NO visible frame shows the target's GUID (" .. tostring(pv.how) .. ")" end
    return out
end

-- /gff hotdebug [unit]: what the HoT code makes of every HoT on the unit (default the target,
-- else the player), then one short line per helpful aura, and last the cast summary (1.5.2:
-- readable on one screenshot). /gff hotdebug cast arms a trace of the next cast.
function HealPred.HotDebug(arg)
    if type(arg) == "string" and arg:lower() == "cast" then
        HealPred.dbg.traceUntil = (type(_G.GetTime) == "function" and Num(_G.GetTime()) or 0) + 60
        HealPred.dbg.traceId = nil
        Print("hotdebug cast: armed for 60 s - cast your heal now, I print what happens; then screenshot")
        return
    end
    local u = HotUnit()
    if type(arg) == "string" and arg ~= "" then
        local ok, ex = pcall(UnitExists, arg)
        if not ok or Plain(ex) ~= true then
            Print("hotdebug: no unit \"" .. arg .. "\" (player, target, focus, pet, party1-4 ..., or cast)")
            return
        end
        u = arg
    end
    local C = _G.C_UnitAuras
    Print("hotdebug " .. u .. DOT .. "in combat " .. tostring(InCombat()) .. DOT .. "health "
        .. Raw(UnitHealth(u)) .. "/" .. Raw(UnitHealthMax(u)))
    for _, line in ipairs(HealPred.HotLines(u)) do
        if not line:find("other buffs (not a known HoT)", 1, true) and not line:find("amount: aura points", 1, true) then Print(line) end
    end
    if type(C) ~= "table" or type(C.GetAuraDataByIndex) ~= "function" then
        Print("no C_UnitAuras.GetAuraDataByIndex on this client")
    else
        local count = 0
        for i = 1, MAX_AURAS do
            local ok, a = pcall(C.GetAuraDataByIndex, u, i, "HELPFUL")
            if not ok then Print(i .. ": read refused"); break end
            if type(a) == "nil" then break end
            if IsSecret(a) or type(a) ~= "table" then
                Print(i .. ": secret")
            else
                count = count + 1
                local hot, how = HotOf(a)
                if hot then
                    local text, by = AuraTooltip(u, a, i)
                    local p, every, total, over
                    if text then p, every, total, over = ParseHeal(text) end
                    Print(i .. ": " .. Raw(a.spellId) .. " " .. Raw(a.name) .. " - HoT by " .. how .. ", points " .. Raw(a.points)
                        .. ", exp " .. Raw(a.expirationTime) .. ", src " .. Raw(a.sourceUnit) .. ", tip " .. tostring(by) .. ": "
                        .. (p and (p .. " every " .. Raw(every) .. "s") or (total and (total .. " over " .. Raw(over) .. "s")) or "nothing"))
                else
                    Print(i .. ": " .. Raw(a.spellId) .. " " .. Raw(a.name) .. " - not HoT")
                end
            end
        end
        if count == 0 then Print("no helpful auras read on " .. u) end
    end
    for _, line in ipairs(HealPred.CastSummary()) do Print(line) end
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
    f.hotAt, f.absorbAt = hp.all:GetStatusBarTexture(), hp.hot:GetStatusBarTexture()
    Place(hp.hot, f.hotAt, f.healthW)
    Place(hp.absorb, f.absorbAt, f.healthW)
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
    -- 1.5.0: overheal, on a frame of its own hung on the health bar's right edge, at its height
    -- and frame level (the health bar clips its children, so it cannot sit in there). It clips
    -- its own children at the cap; two bars in it: the incoming-heal part, then the HoT part.
    local o = CreateFrame("Frame", nil, f)
    o:SetPoint("TOPLEFT", h, "TOPRIGHT", 0, 0)
    o:SetPoint("BOTTOMLEFT", h, "BOTTOMRIGHT", 0, 0)
    o:SetWidth(f.healthW * DEFAULTS.overhealCap)
    o:SetFrameLevel(h:GetFrameLevel())
    if o.SetClipsChildren then pcall(o.SetClipsChildren, o, true) end
    f.overFrame = o
    hp.overInc = Overlay(o, 1, OVER_INC)
    hp.overHot = Overlay(o, 1, OVER_HOT)
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

-- ---------------------------------------------------------------------------
-- Spell cost on the player's power bar (1.6.0). While you cast a spell with a cast time
-- (UNIT_SPELLCAST_START, until _STOP, _FAILED, _INTERRUPTED or _SUCCEEDED) the part of the power
-- bar the cost will take - from the current power back by the cost, the right end of the filled
-- part - is drawn bright and pulsing with a small "-340"; red when there is not enough power.
-- The segment is a reversed-fill StatusBar as wide as the power bar, hung on the right edge of
-- the power bar's fill, with SetMinMaxValues(0, max) and SetValue(cost): the client does the
-- width, so a secret current power, maximum or cost needs no arithmetic here. Only the red
-- "not enough" test and the number need plain values and are left out when one is secret.
-- Channels are not marked: their cost is paid at the start.
-- ---------------------------------------------------------------------------

HealPred.Cost = { MAX = 60, LIGHT = { 1, 1, 1, 0.55 }, RED = { 1, 0.15, 0.15, 0.8 } }
-- .cast is { id, cast, pType, cost, at } of the spell being cast now, or nil; MAX: seconds after
-- which a cast is dropped (a STOP that never came). (A field, not a local: 200-locals limit.)

-- The cost of spell id in the power type pType, or nil (no such cost, none known, type is
-- another). The cost may be secret: it is only passed on. C_Spell.GetSpellPowerCost first, the
-- older global as a fallback. Pure apart from those calls.
function HealPred.Cost.CostOf(id, pType)
    if type(id) ~= "number" then return nil end
    local list
    local C = _G.C_Spell
    if type(C) == "table" and type(C.GetSpellPowerCost) == "function" then
        local ok, r = pcall(C.GetSpellPowerCost, id)
        if ok then list = r end
    end
    if type(list) ~= "table" and type(_G.GetSpellPowerCost) == "function" then
        local ok, r = pcall(_G.GetSpellPowerCost, id)
        if ok then list = r end
    end
    if type(list) ~= "table" then return nil end
    for _, e in ipairs(list) do
        if type(e) == "table" and not IsSecret(e.type) and e.type == pType then
            local c = e.cost
            if IsSecret(c) then return c end
            if type(c) == "number" and c > 0 then return c end
            return nil
        end
    end
    return nil
end

-- Whether the cost is more than the power there is: true or false, or nil when either is secret
-- or missing. Pure.
function HealPred.Cost.Short(cur, cost)
    local c, k = Num(cur), Num(cost)
    if not c or not k then return nil end
    return k > c
end

function HealPred.Cost.Build(f)
    local cf = CreateFrame("Frame", nil, f.power)
    cf:SetAllPoints(f.power)
    cf:SetFrameLevel(f.power:GetFrameLevel() + 3)
    if cf.SetClipsChildren then pcall(cf.SetClipsChildren, cf, true) end
    local bar = CreateFrame("StatusBar", nil, cf)
    bar:SetStatusBarTexture(FLAT)
    Look.SetBarColor(bar, HealPred.Cost.LIGHT[1], HealPred.Cost.LIGHT[2], HealPred.Cost.LIGHT[3], HealPred.Cost.LIGHT[4])
    if bar.SetReverseFill then bar:SetReverseFill(true) end
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetWidth(f.healthW)
    bar:SetPoint("TOPRIGHT", f.power:GetStatusBarTexture(), "TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", f.power:GetStatusBarTexture(), "BOTTOMRIGHT", 0, 0)
    local tf = CreateFrame("Frame", nil, cf)
    tf:SetAllPoints(cf)
    tf:SetFrameLevel(cf:GetFrameLevel() + 2)
    local fs = NewFont(tf, math.max(7, f.layout.mp - 3))
    fs:SetPoint("RIGHT", bar:GetStatusBarTexture(), "LEFT", 0, 0)
    fs:SetPoint("RIGHT", f.power:GetStatusBarTexture(), "RIGHT", -2, 0)
    cf:Hide()
    cf:SetScript("OnUpdate", function(self)
        local t = type(_G.GetTime) == "function" and Num(_G.GetTime()) or 0
        bar:SetAlpha(0.65 + 0.35 * math.sin(t * 5))
    end)
    f.costFrame, f.costBar, f.costText, f.costColor = cf, bar, fs, "light"
end

-- Draws (or hides) the segment on the player frame f from the cast being made.
function HealPred.Cost.Update(f)
    local cf = f.costFrame
    if not cf then return end
    local c = HealPred.Cost.cast
    if c and type(_G.GetTime) == "function" then
        local now = Num(_G.GetTime())
        if now and now - c.at > HealPred.Cost.MAX then HealPred.Cost.cast, c = nil, nil end
    end
    if not c or not db.powerCost or f.powerShown == false then cf:Hide(); return end
    local pType = UnitPowerType("player")
    if IsSecret(pType) or pType ~= c.pType then cf:Hide(); return end
    local mx, cur = UnitPowerMax("player"), UnitPower("player")
    f.costBar:SetMinMaxValues(0, mx)
    f.costBar:SetValue(c.cost)
    local short = HealPred.Cost.Short(cur, c.cost) == true
    local want = short and "red" or "light"
    if f.costColor ~= want then
        local k = short and HealPred.Cost.RED or HealPred.Cost.LIGHT
        f.costColor = want
        Look.SetBarColor(f.costBar, k[1], k[2], k[3], k[4])
    end
    local n = Num(c.cost)
    if n then f.costText:SetText("-" .. math.floor(n + 0.5)); f.costText:Show() else f.costText:SetText(""); f.costText:Hide() end
    cf:Show()
end

-- _START, _STOP, _FAILED, _INTERRUPTED and _SUCCEEDED of your own casts: unit, castGUID, spellID.
-- Returns true when the segment changed.
function HealPred.Cost.OnCast(event, unit, castGUID, spellID)
    if unit ~= "player" then return false end
    if event == "UNIT_SPELLCAST_START" then
        HealPred.Cost.cast = nil
        if not db.powerCost then return true end
        local id = Num(spellID)
        local pType = UnitPowerType("player")
        if not id or IsSecret(pType) then return true end
        local cost = HealPred.Cost.CostOf(id, pType)
        if cost == nil then return true end
        local now = type(_G.GetTime) == "function" and Num(_G.GetTime()) or 0
        HealPred.Cost.cast = { id = id, cast = PlainString(castGUID), pType = pType, cost = cost, at = now }
        return true
    end
    local c = HealPred.Cost.cast
    if not c then return false end
    local cast, id = PlainString(castGUID), Num(spellID)
    if (c.cast and cast and c.cast ~= cast) or (not (c.cast and cast) and id and c.id ~= id) then return false end
    HealPred.Cost.cast = nil
    return true
end

local function Set(bar, mx, v)
    if type(v) ~= "number" then bar:Hide(); return end   -- type() is allowed on a secret
    bar:SetMinMaxValues(0, mx)
    bar:SetValue(v)
    bar:Show()
end

-- The yellow HoT segment: hidden at 0.
local function SetHot(hp, mx, v)
    if type(v) ~= "number" or v <= 0 then   -- v is ours: plain, never secret
        hp.hot:SetMinMaxValues(0, 1)
        hp.hot:SetValue(0)
        hp.hot:Hide()
        return
    end
    Set(hp.hot, mx, v)
end

-- 1.2.10: health | green | yellow | white, each anchored to the last segment that is shown. A
-- hidden StatusBar's fill is no reliable anchor (up to 1.2.9 the yellow hung on the green bar's
-- fill even with the green bar hidden). Re-anchored only when the anchor changes.
local function Chain(f)
    local hp = f.healPred
    local hotAt = hp.all:IsShown() and hp.all:GetStatusBarTexture() or f.health:GetStatusBarTexture()
    if f.hotAt ~= hotAt then f.hotAt = hotAt; Place(hp.hot, hotAt, f.healthW) end
    local absorbAt = hp.hot:IsShown() and hp.hot:GetStatusBarTexture() or hotAt
    if f.absorbAt ~= absorbAt then f.absorbAt = absorbAt; Place(hp.absorb, absorbAt, f.healthW) end
end

-- Hangs bar on the right (or left) edge of region at width, re-anchored only when that changes.
local function Hang(bar, region, side, width)
    if bar.hangAt ~= region or bar.hangSide ~= side then
        bar.hangAt, bar.hangSide = region, side
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", region, "TOP" .. side, 0, 0)
        bar:SetPoint("BOTTOMLEFT", region, "BOTTOM" .. side, 0, 0)
    end
    if bar.hangW ~= width then bar.hangW = width; bar:SetWidth(width) end
end

local function OverCap()
    local c = Num(db.overhealCap) or DEFAULTS.overhealCap
    return Clamp(c, OVER_CAP[1], OVER_CAP[2])
end

-- Overheal from plain values (1.5.0): HealLayout gives the two parts past the bar's end as
-- shares of its width; each is a full bar of that width, the HoT part after the incoming part.
-- Nil when a value is not plain.
local function OverPlain(f, cur, mx, inc, hot)
    local hp, o = f.healPred, f.overFrame
    local L = HealPred.HealLayout(cur, mx, inc, hot, OverCap())
    if not L then return nil end
    local W = f.healthW
    local incW, hotW = L.overIncFrac * W, L.overHotFrac * W
    local at, side = o, "LEFT"
    if incW >= 0.5 then
        Hang(hp.overInc, o, "LEFT", incW)
        hp.overInc:SetMinMaxValues(0, 1)
        hp.overInc:SetValue(1)
        hp.overInc:Show()
        at, side = hp.overInc, "RIGHT"
    else
        hp.overInc:Hide()
    end
    if hotW >= 0.5 then
        Hang(hp.overHot, at, side, hotW)
        hp.overHot:SetMinMaxValues(0, 1)
        hp.overHot:SetValue(1)
        hp.overHot:Show()
    else
        hp.overHot:Hide()
    end
    return L
end

-- Overheal with a hidden (secret) value (1.5.0): nothing can be added or compared, so the two
-- bars are laid out as the green and yellow are, full width and on the bar's scale - the
-- incoming heals (unclamped, straight from the client) from the health fill's edge, the HoTs
-- after them - and the overheal frame shows only what reaches past the bar's end, up to the cap.
-- The incoming part can reach past the end by at most the current health's share of the bar.
local function OverSecret(f, mx, inc, hot)
    local hp = f.healPred
    local fill, W = f.health:GetStatusBarTexture(), f.healthW
    local at = fill
    if type(inc) == "number" and Num(inc) ~= 0 then   -- type() is allowed on a secret; Num is nil for one
        Hang(hp.overInc, fill, "RIGHT", W)
        hp.overInc:SetMinMaxValues(0, mx)
        hp.overInc:SetValue(inc)
        hp.overInc:Show()
        at = hp.overInc:GetStatusBarTexture()
    else
        hp.overInc:Hide()
    end
    if type(hot) == "number" and hot > 0 then   -- hot is ours: plain
        Hang(hp.overHot, at, "RIGHT", W)
        hp.overHot:SetMinMaxValues(0, mx)
        hp.overHot:SetValue(hot)
        hp.overHot:Show()
    else
        hp.overHot:Hide()
    end
end

local function HideOver(f, u, why)
    local hp = f.healPred
    hp.overInc:Hide()
    hp.overHot:Hide()
    if u then overWhy[u] = why end
end

-- The overheal segment of frame f (1.5.0): health + incoming heals (unclamped, plus extra, the
-- direct part of your cast where the client leaves it out) + HoTs past the maximum.
local function DrawOver(f, u, mx, extra)
    local o = f.overFrame
    if not o then return end
    if not db.overheal then HideOver(f, u, "off"); return end
    local w = OverCap() * f.healthW
    if o.capW ~= w then o.capW = w; o:SetWidth(w) end
    local inc
    local fn = _G.UnitGetIncomingHeals
    if type(fn) == "function" then
        local ok, v = pcall(fn, u)
        if ok then inc = v end
    end
    local hot = f.hotTotal or 0
    local cur = UnitHealth(u)
    local incPlain = (inc == nil) and 0 or Num(inc)
    if incPlain then incPlain = incPlain + (extra or 0) end
    local L = incPlain and OverPlain(f, cur, mx, incPlain, hot)
    if L then
        overWhy[u] = L.overFrac > 0 and string.format("shown (%d%% of the bar: %d%% heals, %d%% HoTs)",
            math.floor(L.overFrac * 100 + 0.5), math.floor(L.overIncFrac * 100 + 0.5), math.floor(L.overHotFrac * 100 + 0.5))
            or "nothing past the maximum"
        return
    end
    OverSecret(f, mx, inc, hot)
    overWhy[u] = "values hidden: drawn by the bars themselves, clipped at the bar's end"
end

-- The HoT sum for frame f's unit, cut by ClampHot (1.4.4: the one clamp). Notes the time the
-- sum next drops on f (f.hotNext, for the ticker) and the outcome for /gff status.
local function HotValue(f, u, mx, all)
    f.hotTotal = nil
    if not db.hotPred then hotWhy[u] = "off"; return nil end
    local total, why, _, nextAt = HotScan(u)
    f.hotNext = nextAt
    if total and not why then f.hotTotal = total end   -- uncut, for the overheal (1.5.0)
    if not total then hotWhy[u] = "unavailable (" .. why .. ")"; return nil end
    if why then hotWhy[u] = "nothing to show (" .. why .. ")"; return nil end
    -- No "all or 0": a boolean test on a secret is refused. Absent incoming heals count as 0.
    local inc = all
    if type(all) == "nil" then inc = 0 end
    local shown, cut = HealPred.ClampHot(total, mx, UnitHealth(u), inc)
    if shown > 0 then
        hotWhy[u] = string.format("shown (%d of %d on %s%s)", math.floor(shown + 0.5), math.floor(total + 0.5), u,
            cut and "" or "; health secret, the bar clips it")
    else
        hotWhy[u] = total > 0 and "nothing to show (no missing health left after the incoming heals)"
            or "nothing to show (no ticks left)"
    end
    return shown
end
-- One frame's overlays from the client. Values go from one client call to the next.
function HealPred.Update(f)
    local hp = f.healPred
    if not hp then return end
    f.hotNext = nil
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
    -- 1.5.0: the direct part of your heal + HoT cast where the client's prediction leaves it out.
    local extra = OwnDirect(u)
    if extra > 0 then
        local a, m = (all == nil) and 0 or Num(all), (mine == nil) and 0 or Num(mine)
        if a and m then
            local c, mn = Num(UnitHealth(u)), Num(mx)
            local add = extra
            if c and mn then add = math.min(extra, math.max(0, mn - c - a)) end
            all, mine = a + add, m + add
        else
            extra = 0   -- hidden values: nothing to add to
        end
    end
    Set(hp.all, mx, all)
    Set(hp.mine, mx, mine)
    SetHot(hp, mx, HotValue(f, u, mx, all))
    Set(hp.absorb, mx, absorb)
    Set(hp.healAbsorb, mx, healAbsorb)
    Chain(f)
    DrawOver(f, u, mx, extra)
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
    Chain(f)
    if db.overheal and f.overFrame then
        local w = OverCap() * f.healthW
        if f.overFrame.capW ~= w then f.overFrame.capW = w; f.overFrame:SetWidth(w) end
        OverPlain(f, d.hp[1], mx, h[1] + h[2], db.hotPred and h[4] or 0)
    else
        HideOver(f)
    end
end
end

local function FrameHeight(L)
    return PAD + L.name + 2 + L.hp + 1 + L.mp + PAD
end

-- One unit frame. A secure button for the real thing; a plain one for the test-mode preview.
-- Secure attributes are set here, once, and this is only ever called out of combat.
local function Build(key, unit, preview)
    local L = LAYOUT[key]
    local name = (preview and "GaarFramesForeverPreview_" or "GaarFramesForever_") .. unit
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
    if unit == "player" and not preview then HealPred.Cost.Build(f) end

    -- The player's mana while a form shows another power (druid in bear or cat form): a thin
    -- blue bar under the power bar, as Blizzard's alternate mana bar. Hidden until needed; it
    -- takes its room from the health bar, since the secure frame cannot grow in combat.
    if key == "player" then
        f.mana = NewBar(f, Mana.H, 7)
        f.mana:SetPoint("TOPLEFT", f.power, "BOTTOMLEFT", 0, -1)
        f.mana:SetPoint("TOPRIGHT", f.power, "BOTTOMRIGHT", 0, -1)
        Look.SetBarColor(f.mana, PowerRGB("MANA"))
        f.mana:Hide()
    end

    -- Icons.
    Look.BuildMark(f)
    if key == "pet" then Look.BuildHappiness(f) end
    if key == "player" or key == "party" then
        local li = f:CreateTexture(nil, "OVERLAY")
        li:SetSize(14, 14)
        li:SetPoint("CENTER", f, "TOPLEFT", 4, 0)
        li:SetTexture(LEADER_ICON)
        li:Hide()
        f.leaderIcon = li
    end
    if f.portraitFrame then
        -- 1.7.0: PvP flag, on the frame's left edge (Blizzard's own icon is switched off with its frame).
        local sz = (key == "party") and 20 or 26
        local pi = f:CreateTexture(nil, "OVERLAY")
        pi:SetSize(sz, sz)
        pi:SetPoint("RIGHT", f, "LEFT", -1, key == "player" and 4 or 0)
        pi:Hide()
        f.pvpIcon = pi
        if key == "player" then
            local pt = NewFont(f, 10)
            pt:SetPoint("TOP", pi, "BOTTOM", 0, 0)
            pt:Hide()
            f.pvpTimer = pt
        end
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

-- Current health, as Blizzard's own unit frames read it: with the client's prediction.
-- UnitHealth's second argument, usePredicted, defaults to true. 1.2.5 read the number with it and
-- the percent without it (UnitHealthPercent(unit, false, ...)), so a mob near death showed
-- "1/473  4%". 1.2.6 made all three read usePredicted = false, the last value the server sent:
-- that one only moves when the server's next health update arrives, so after a heal landed the
-- bar and text kept the old health for a few seconds while the green prediction was already
-- gone. Since 1.2.10 bar, number and percent all read the predicted value (PREDICTED), which
-- moves on the UNIT_HEALTH the client fires as the heal lands - and still one reading for all.
local ValueText = { PREDICTED = true }   -- Read, Abbrev, Secret, Status: the numbers in the bar text

function ValueText.Read(unit)
    return UnitHealth(unit, ValueText.PREDICTED)
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
            pct, havePct = _G.UnitHealthPercent(unit, ValueText.PREDICTED, curve), true
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
    local r, g, b = HealthRGB(u)
    -- The hunter's pet: its happiness colour wins over the normal one (1.4.1), every update.
    if f.happyFrame and not blocked.happiness then
        local ok, hr, hg, hb = pcall(Happy.BarRGB, f)
        if not ok then Happy.diag.err = "bar colour: " .. tostring(hr)
        elseif hr then r, g, b = hr, hg, hb end
    end
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
-- and why, for /gff status. A plain maximum decides where there is one. On this client
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

-- An NPC whose maximum is a hidden 0 (GaarFramesForever 1.2.1). In game a low beast in the
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
-- "fallback", for UpdatePower and /gff status.
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

local UpdatePower   -- (a do block: the main chunk is at its limit of 200 locals)
do
local function Bar(f)
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

-- 1.6.0: the power bar, then the spell-cost segment on it (it turns red as your power falls short).
UpdatePower = function(f)
    Bar(f)
    if f.costFrame then Run("powercost", HealPred.Cost.Update, f) end
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
    Look.UpdateMark(f, type(_G.GetRaidTargetIndex) == "function" and _G.GetRaidTargetIndex(u) or nil)
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

-- ---------------------------------------------------------------------------
-- PvP flag (1.7.0). A faction (or free-for-all) icon beside the portrait of a flagged unit; on the
-- player frame also the m:ss left of the flag's timeout. Everything read here may be secret: a
-- secret answer keeps the last known state, and no secret is ever compared.
-- ---------------------------------------------------------------------------
Look.Pvp = {}
Look.Pvp.ICONS = {
    Alliance = "Interface\\TargetingFrame\\UI-PVP-Alliance",
    Horde = "Interface\\TargetingFrame\\UI-PVP-Horde",
    ffa = "Interface\\TargetingFrame\\UI-PVP-FFA",
}
Look.Pvp.NO_TIMER_MS = 301000   -- GetPVPTimer() reports about this when no timer is running

-- "m:ss" for the milliseconds left, or nil when there is no timer (nothing, secret, <= 0, or the
-- "no timer" value and anything larger).
function Look.Pvp.Format(ms)
    ms = Num(ms)
    if not ms or ms <= 0 or ms >= Look.Pvp.NO_TIMER_MS then return nil end
    local sec = math.ceil(ms / 1000)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Raw timer read: nil when none runs or the client will not say.
function Look.Pvp.TimerText()
    if type(_G.GetPVPTimer) ~= "function" then return nil end
    if type(_G.IsPVPTimerRunning) == "function" then
        local ok, running = pcall(_G.IsPVPTimerRunning)
        if ok and Plain(running) == false then return nil end
    end
    local ok, ms = pcall(_G.GetPVPTimer)
    if not ok then return nil end
    return Look.Pvp.Format(ms)
end

-- "ffa", "Alliance", "Horde", false (not flagged) or nil (unknown: keep what was shown).
function Look.Pvp.Kind(unit)
    if type(_G.UnitIsPVPFreeForAll) == "function" and Plain(_G.UnitIsPVPFreeForAll(unit)) == true then return "ffa" end
    if type(_G.UnitIsPVP) ~= "function" then return nil end
    local flagged = Plain(_G.UnitIsPVP(unit))   -- nil = secret (a plain false must stay false)
    if flagged == nil then return nil end
    if flagged ~= true then return false end
    local fg = type(_G.UnitFactionGroup) == "function" and Plain((_G.UnitFactionGroup(unit))) or nil
    if fg == "Alliance" or fg == "Horde" then return fg end
    return nil
end

function Look.Pvp.Update(f)
    local icon = f.pvpIcon
    if not icon then return end
    if not db.pvpFlag then
        icon:Hide()
        if f.pvpTimer then f.pvpTimer:Hide() end
        f.pvpKind, f.pvpTicking = nil, nil
        return
    end
    local kind = Look.Pvp.Kind(f.unit)
    if kind ~= nil then f.pvpKind = kind end   -- unknown: keep the last known state
    local show = f.pvpKind
    if show then
        icon:SetTexture(Look.Pvp.ICONS[show])
        icon:SetTexCoord(0, 0.609375, 0, 0.640625)
        icon:Show()
    else
        icon:Hide()
    end
    if f.pvpTimer then
        local txt = show and Look.Pvp.TimerText() or nil
        if txt then f.pvpTimer:SetText(txt); f.pvpTimer:Show() else f.pvpTimer:SetText(""); f.pvpTimer:Hide() end
        f.pvpTicking = txt and true or nil
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
-- DoTs on an enemy in combat (seen with GaarPlatesForever 1.1).
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
--      ShouldUnitAuraIndexBeSecret asked first. A refused read is counted for /gff status and
--      tried again at the next update - never a latch - so out of combat the auras are back.
-- Only an error outside the reads switches auras off for the session, with one line in chat.
-- ---------------------------------------------------------------------------

local auraStats              -- aura reads refused this session, for /gff status
local containerInfo = {}     -- how the Blizzard aura container fared, for /gff status
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
    -- on this client is quiet (it shows in /gff status); a client that has the template but
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
            f.auraPath = testing and "test mode" or "off (/gff playerbuffs on)"
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
    Run("pvp", Look.Pvp.Update, f)
    if f.happyFrame then Run("happiness", Look.UpdateHappiness, f) end
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
        hiddenParent = CreateFrame("Frame", "GaarFramesForeverHiddenParent", _G.UIParent)
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
    party4 = { name = "Tyrande", level = 60, class = "PRIEST", hp = { 3500, 3500 }, power = { 4700, 5000, "MANA" },
        heal = { 400, 0, 0, 300 } },   -- full health: all of it overheal, past the bar (1.5.0)
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
    local r, g, b
    if d.class then
        if db.classColor then r, g, b = ClassRGB(d.class) end
        if not r then r, g, b = Look.HEALTH[1], Look.HEALTH[2], Look.HEALTH[3] end
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
    Look.UpdateMark(f, 8)   -- test mode: a sample skull on every frame
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
                .. (db.locked and " - /gff unlock to drag them." or " - drag them into place.")
                .. " /gff test again to stop.")
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
                .. " positions are kept for /gff editmode off."
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
        or "frames unlocked: drag a frame to move it (out of combat). /gff test shows every frame.")
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
    { key = "classColor", cmd = "classcolor", label = "Class colour" },
    { key = "playerBuffs", cmd = "playerbuffs", label = "Player buffs" },
    { key = "healPrediction", cmd = "healpred", label = "Heal prediction" },
    { key = "hotPred", cmd = "hotpred", label = "HoT prediction" },
    { key = "hotCastPreview", cmd = "hotcast", label = "HoT preview while casting" },
    { key = "powerCost", cmd = "cost", label = "Spell cost on the power bar" },
    { key = "overheal", cmd = "overheal", label = "Overheal past the bar" },
    { key = "raidMark", cmd = "marks", label = "Raid target marks" },
    { key = "pvpFlag", cmd = "pvp", label = "Show PvP flag" },
    { key = "petHappiness", cmd = "pethappiness", label = "Hunter pet happiness icon and health colour" },
}

function HealPred.SetCap(c)
    db.overhealCap = Clamp(c, OVER_CAP[1], OVER_CAP[2])
    RefreshLooks()
    Print(string.format("overheal cap: %d%% of the health bar's width.", math.floor(db.overhealCap * 100 + 0.5)))
end

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

-- The intro GaarForever shows at the top of this addon's Options page, and the first line of
-- the help.
local INTRO = "X-Perl-style unit frames for player, target, target of target, focus, pet and party, in place of Blizzard's: portraits, health and power text, heal prediction, auras, raid marks and a threat border. Nice to know: /gff unlock, then drag a frame to move it, or let the frames follow Edit Mode; /gff test shows every frame with made-up data; frames are switched on or off out of combat only."

local function PrintHelp()
    Print(INTRO)
    Print("version " .. VERSION .. ". Commands:")
    Print("/gff status - settings, frames and what this client allows")
    Print("/gff lock | unlock - stop or allow dragging the frames (now: " .. (db and db.locked and "locked" or "unlocked") .. ")")
    Print("/gff editmode on | off - player, target, focus and party follow Blizzard's frames placed in Edit Mode;"
        .. " pet and target of target move with them, and those frames are not dragged (now: "
        .. OnOff(db and db.followEditMode) .. ")")
    Print("/gff test - show every enabled frame with made-up data, to place them (out of combat)")
    Print("/gff reset - positions and scales back to the defaults")
    Print(string.format("/gff scale <%s> <%.1f-%.1f> - one frame's scale", KeyList(), MIN_SCALE, MAX_SCALE))
    Print("/gff frame <" .. KeyList() .. "> on | off - which frames are drawn (off: Blizzard's comes back after /reload)")
    Print("/gff portrait 2d | 3d (now: " .. (db and db.portrait or "?") .. ")")
    Print("/gff text | classcolor on | off - bar text, class colour")
    Print("/gff playerbuffs on | off - your buffs in rows under the player frame (now: "
        .. OnOff(db and db.playerBuffs) .. ")")
    Print("/gff healpred on | off - incoming heals and absorbs on the health bars (now: "
        .. OnOff(db and db.healPrediction) .. ")")
    Print("/gff hotpred on | off - what active HoTs will still heal, in yellow after the incoming heals (now: "
        .. OnOff(db and db.hotPred) .. ")")
    Print("/gff hotcast on | off - while you cast a HoT spell (Regrowth), its HoT in yellow on the target's frames from the cast's start (now: "
        .. OnOff(db and db.hotCastPreview) .. ")")
    Print("/gff cost on | off - while you cast a spell with a cast time, its cost marked on your power bar: the part that will go, bright and pulsing with a -number, red when you do not have enough (now: "
        .. OnOff(db and db.powerCost) .. ")")
    Print("/gff overheal on | off - heals past the maximum as a red segment past the bar's right edge (now: "
        .. OnOff(db and db.overheal) .. ")")
    Print(string.format("/gff overheal cap <%.1f-%.0f> - its longest length, a share of the bar's width (now: %s)",
        OVER_CAP[1], OVER_CAP[2], db and tostring(db.overhealCap) or "?"))
    Print("/gff hotdebug [unit] - each HoT on the unit (default your target, else you), one line per buff, the cast summary last; /gff hotdebug cast - traces your next cast (cast, then screenshot)")
    Print("/gff pvp on | off - a faction (or free-for-all) icon beside the portrait of a PvP-flagged unit; the player's also shows the minutes left while the flag times out (now: "
        .. OnOff(db and db.pvpFlag) .. ")")
    Print("/gff marks on | off - raid target marks (skull, cross ...) on the frames (now: "
        .. OnOff(db and db.raidMark) .. ")")
    Print("/gff pethappiness on | off - hunter pet happiness icon next to the pet frame (tooltip on hover) and pet health bar coloured by happiness (now: "
        .. OnOff(db and db.petHappiness) .. ")")
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

-- The target's health readings and the number formatters, for /gff status. Hidden values are
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
        .. DOT .. "text and bar use UnitHealth(unit) (predicted, 1.2.10)")
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
    Print("bar text " .. OnOff(db.text) .. DOT .. "class colour " .. OnOff(db.classColor) .. DOT .. "player buffs " .. OnOff(db.playerBuffs))
    Print("heal prediction " .. OnOff(db.healPrediction) .. DOT .. HealPred.Method()
        .. (blocked.healpred and (" (off: " .. blocked.healpred .. ")") or ""))
    Print("overheal " .. OnOff(db.overheal) .. string.format(" (cap %d%% of the bar)", math.floor(db.overhealCap * 100 + 0.5))
        .. DOT .. "hot cast preview " .. OnOff(db.hotCastPreview)
        .. DOT .. "spell cost on the power bar " .. OnOff(db.powerCost)
        .. DOT .. "UnitGetIncomingHeals " .. Yes(type(_G.UnitGetIncomingHeals) == "function"))
    Print("raid marks " .. OnOff(db.raidMark))
    local okH, happyLine = pcall(Happy.Status, real.pet)
    Print(okH and happyLine or ("pet happiness: status failed (" .. tostring(happyLine) .. ")"))
    for _, line in ipairs(HealPred.HotLines()) do Print(line) end
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
    Print("hidden values: " .. (type(_G.issecretvalue) == "function" and "possible" or "no")
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
            Print(string.format("/gff scale <%s> <%.1f-%.1f>", KeyList(), MIN_SCALE, MAX_SCALE))
        end
    elseif cmd == "frame" then
        local word, state = rest:match("^(%S+)%s*(%S*)$")
        local key = ParseKey(word or "")
        if key and (state == "on" or state == "off") then
            SetFrameEnabled(key, state == "on")
        elseif key and state == "" then
            SetFrameEnabled(key, not db.frames[key])
        else
            Print("/gff frame <" .. KeyList() .. "> on | off")
        end
    elseif cmd == "editmode" or cmd == "follow" then
        if rest == "on" or rest == "off" then SetFollow(rest == "on")
        elseif rest == "" then SetFollow(not db.followEditMode)
        else Print("/gff editmode on | off (now: " .. OnOff(db.followEditMode) .. ")") end
    elseif cmd == "hotdebug" then
        HealPred.HotDebug(rest)
    elseif cmd == "overheal" and rest:match("^cap") then
        local c = tonumber(rest:match("^cap%s*(%S*)$") or "")
        if c and c > 1 then c = c / 100 end   -- "30" for 30%
        if c and c >= OVER_CAP[1] and c <= OVER_CAP[2] then
            HealPred.SetCap(c)
        else
            Print(string.format("/gff overheal cap <%.1f-%.0f> (now: %s)", OVER_CAP[1], OVER_CAP[2], tostring(db.overhealCap)))
        end
    elseif cmd == "portrait" then
        if rest == "2d" or rest == "3d" then SetPortraitMode(rest)
        else Print("/gff portrait 2d | 3d (now: " .. db.portrait .. ")") end
    else
        for _, t in ipairs(SETTING_TOGGLES) do
            if cmd == t.cmd then
                if rest == "on" or rest == "off" then SetToggle(t, rest == "on")
                elseif rest == "" then SetToggle(t, not db[t.key])
                else Print("/gff " .. t.cmd .. " on | off (now: " .. OnOff(db[t.key]) .. ")") end
                return
            end
        end
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Public API: GaarFramesForeverAPI
--
-- For GaarForever, the family hub that puts this addon's options in its own minimap menu.
-- Everything stays here: the settings live in GaarFramesForeverDB and change only through the
-- same functions /gff uses, so the addon behaves the same with or without the hub.
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
    local caps = {}
    for _, c in ipairs({ 0.1, 0.2, 0.3, 0.5, 1 }) do
        caps[#caps + 1] = { text = string.format("%d%% of the bar", c * 100), radio = true,
            checked = function() return math.abs((Num(db.overhealCap) or 0) - c) < 0.001 end,
            func = function() HealPred.SetCap(c) end }
    end
    list[#list + 1] = { text = "Overheal cap", submenu = caps }
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Test mode", checkbox = true, checked = function() return testing and true or false end,
        func = function() SetTesting(not testing) end }
    list[#list + 1] = { text = "Reset positions & scales", func = ResetLayout }
    return list
end

_G.GaarFramesForeverAPI = {
    version = VERSION,
    Intro = function() return INTRO end,
    StatusLine = StatusLine,
    MenuEntries = MenuEntries,
    AddMenuEntries = function(root) BF.RenderMenu(root, MenuEntries(), A.title) end,
    SetMinimapHidden = function() end,
}
_G.BetterFramesForeverAPI = _G.GaarFramesForeverAPI -- the name before the folder rename

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------

local function BindSavedVariables()
    BF.Migrate("GaarFramesForeverDB", "BetterFramesForeverDB") -- the old folder's settings, once (see Lib.lua)
    if type(GaarFramesForeverDB) ~= "table" then GaarFramesForeverDB = {} end
    db = GaarFramesForeverDB
    for k in pairs(db) do
        if not SAVED_KEYS[k] then db[k] = nil end
    end
    for k, v in pairs(DEFAULTS) do
        if type(db[k]) ~= type(v) then db[k] = v end
    end
    if db.portrait ~= "2d" and db.portrait ~= "3d" then db.portrait = DEFAULTS.portrait end
    db.overhealCap = Clamp(Num(db.overhealCap) or DEFAULTS.overhealCap, OVER_CAP[1], OVER_CAP[2])

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
    if unit == "pet" and (event == "UNIT_HAPPINESS" or ((event == "UNIT_POWER_UPDATE"
        or event == "UNIT_POWER_FREQUENT" or event == "UNIT_MAXPOWER") and arg2 == "HAPPINESS")) then
        local pf = real.pet
        if Visible(pf) then
            Run("health", UpdateHealth, pf)
            Run("happiness", Look.UpdateHappiness, pf)
        end
        return
    end
    if event == "UNIT_FACTION" then
        local f = real[unit]
        if Visible(f) then
            Run("health", UpdateHealth, f); Run("name", UpdateName, f); Run("pvp", Look.Pvp.Update, f)
        end
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
    -- HoTs coming and going move the yellow HoT segment - on every frame showing that unit
    -- (1.4.4): you as player and as target, a party member as party1 and as target.
    if fn == UpdateAuras and db.hotPred then
        Run("healpred", HealPred.Update, f)
        for u, o in pairs(real) do
            if o ~= f and Visible(o) then
                local ok, same = pcall(UnitIsUnit, u, unit)
                if ok and Plain(same) == true then Run("healpred", HealPred.Update, o) end
            end
        end
    end
    if fn == UpdatePower and f.mana then Run("mana", Mana.Update, f) end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_TARGET_CHANGED", "PLAYER_UPDATE_RESTING", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED",
    "RAID_TARGET_UPDATE", "UNIT_FACTION", "UNIT_THREAT_SITUATION_UPDATE", "UNIT_THREAT_LIST_UPDATE",
    "UNIT_TARGET", "UNIT_PET", "UNIT_COMBO_POINTS", "EDIT_MODE_LAYOUTS_UPDATED", "DISPLAY_SIZE_CHANGED",
    "UI_SCALE_CHANGED", "PLAYER_FLAGS_CHANGED", "ZONE_CHANGED_NEW_AREA", "UPDATE_SHAPESHIFT_FORM", "PET_UI_UPDATE", "UNIT_HAPPINESS" }) do
    pcall(events.RegisterEvent, events, e)
end
if HAS_FOCUS then pcall(events.RegisterEvent, events, "PLAYER_FOCUS_CHANGED") end
for e in pairs(UNIT_EVENTS) do pcall(events.RegisterEvent, events, e) end
-- Your own HoT casts, for the yellow segment in combat (1.4.4, HealPred.OnCast), and from the
-- start of a cast to its end (1.5.0).
HealPred.CAST_EVENTS = { UNIT_SPELLCAST_SENT = true, UNIT_SPELLCAST_SUCCEEDED = true, UNIT_SPELLCAST_START = true,
    UNIT_SPELLCAST_STOP = true, UNIT_SPELLCAST_FAILED = true, UNIT_SPELLCAST_INTERRUPTED = true }
for e in pairs(HealPred.CAST_EVENTS) do
    if not (events.RegisterUnitEvent and pcall(events.RegisterUnitEvent, events, e, "player")) then
        pcall(events.RegisterEvent, events, e)
    end
end

-- A HoT you cast: redraw the yellow segment on every frame showing its target.
local function OnHotCast(event, unit, a2, a3, a4)
    if unit == "player" and event ~= "UNIT_SPELLCAST_SENT" then
        local okC, changed = pcall(HealPred.Cost.OnCast, event, unit, a2, a3)
        local p = real.player
        if okC and changed and p and Visible(p) then Run("powercost", HealPred.Cost.Update, p) end
    end
    local ok, guid = pcall(HealPred.OnCast, event, unit, a2, a3, a4)
    if ok and guid then
        for u, f in pairs(real) do
            if Visible(f) and type(_G.UnitGUID) == "function" and Plain(_G.UnitGUID(u)) == guid then
                Run("healpred", HealPred.Update, f)
            end
        end
    end
    if HealPred.dbg.traceUntil then pcall(HealPred.Trace, event, a2, a3, a4, ok, guid) end
end

events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
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
        -- Auras are plain again: the yellow HoT segment can be drawn.
        if db.hotPred and db.healPrediction then UpdateEach("healpred", HealPred.Update) end
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
    elseif event == "PET_UI_UPDATE" then
        local pf = real.pet
        if Visible(pf) then
            Run("health", UpdateHealth, pf)
            Run("happiness", Look.UpdateHappiness, pf)
        end
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
    elseif event == "PLAYER_FLAGS_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" then
        UpdateEach("pvp", Look.Pvp.Update)
    elseif event == "PARTY_LEADER_CHANGED" or event == "RAID_TARGET_UPDATE" then
        UpdateEach("icons", UpdateIcons)
    elseif HealPred.CAST_EVENTS[event] then
        OnHotCast(event, arg1, arg2, arg3, arg4)
    else
        OnUnitEvent(event, arg1, arg2)
    end
end)

-- The light ticker: target of target (it has no events of its own) and party range.
local driver = CreateFrame("Frame")
local acc = 0
Look.Pvp.acc = 0
local happyAcc, HAPPY_POLL = 0, 2   -- seconds between pet happiness checks
driver:SetScript("OnUpdate", function(_, elapsed)
    if not db or not started then return end
    acc = acc + (elapsed or 0)
    if acc < TICK then return end
    acc = 0
    local tot = real.targettarget
    if Visible(tot) then UpdateFrame(tot) end
    -- 1.7.0: the player's PvP timer, once a second and only while one runs.
    local pp = real.player
    if pp and pp.pvpTicking then
        Look.Pvp.acc = Look.Pvp.acc + TICK
        if Look.Pvp.acc >= 1 then
            Look.Pvp.acc = 0
            if Visible(pp) then Run("pvp", Look.Pvp.Update, pp) end
        end
    end
    -- Pet happiness, in case this client sends no happiness event: repaint on a change only.
    happyAcc = happyAcc + TICK
    local pf = real.pet
    if happyAcc >= HAPPY_POLL and pf and pf.happyFrame and db.petHappiness and Visible(pf)
        and not blocked.happiness then
        happyAcc = 0
        local ok, h = pcall(Happy.Level)
        if ok and h ~= pf.happyFrame.level then
            Run("health", UpdateHealth, pf)
            Run("happiness", Look.UpdateHappiness, pf)
        end
    end
    if not testing then
        for _, u in ipairs(UNITS_OF.party) do
            local f = real[u]
            if Visible(f) then Run("range", UpdateRange, f) end
        end
    end
    -- 1.4.4: the yellow HoT segment drops as each tick is due, not only on the next event.
    local now = type(_G.GetTime) == "function" and Num(_G.GetTime()) or nil
    if now and db.hotPred and db.healPrediction then
        for _, f in pairs(real) do
            if f.hotNext and now >= f.hotNext and Visible(f) then Run("healpred", HealPred.Update, f) end
        end
    end
end)

SLASH_GAARFRAMESFOREVER1 = "/gff"
SLASH_GAARFRAMESFOREVER2 = "/gaarframesforever"
SLASH_GAARFRAMESFOREVER3 = "/bff" -- the command before the Gaar rename
SLASH_GAARFRAMESFOREVER4 = "/betterframesforever"
SlashCmdList.GAARFRAMESFOREVER = OnSlash
