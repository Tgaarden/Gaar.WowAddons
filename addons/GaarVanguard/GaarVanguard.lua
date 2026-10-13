--[[
  Gaar Vanguard — captures the account's characters and their loot and hands them to the
  Vanguard website as a copy-paste string. First draft.

  What it does
    * Records every character you log in on into an account-wide database keyed by
      "Name-Realm": name, realm, race, cls, lvl, faction, spec (from talent tabs / the
      retail specialization API), the FULL talent build (every tab, its points spent and every
      talent's rank/max/tier/column - so the website can draw the whole tree), guild + rank,
      professions (the real primary + secondary trade skills with skill and max) and equipment
      (inventory slots 1-19, stored by canonical slot NAME). The
      entry is refreshed whenever the thing it holds can change - login, an equipment swap, a
      level up, a skill/talent change, a guild change - and, crucially, re-scanned live at
      export so the string is correct even when the stored record is empty or stale (early
      Forever beta builds did not load SavedVariables back; from build 70291 they do).
      Field names match the Vanguard website's VGD1 `chars` contract exactly (see
      docs/gaarvanguard.md).
    * Records loot the way GaarLooter does, but per character: every completed need/greed roll
      (item, who won, which choice won) and everything you pick up yourself. Capped at the last
      100 rows per character so the export stays small. This is captured independently - the
      GaarLooter addon does not need to be installed.

  The exports (two, both emit VGD1:<base64 of a JSON document> with k = "chars")
    * /gaarvanguard export (the Export button) - the PRIMARY, reliable flow. A box holding
          VGD1:<base64 JSON> where JSON is { k = "chars", chars = [ <ONE char: the current
          character, fully scanned live - name, realm, race, class, faction, level, spec,
          professions, equipment, loot and the full talent trees> ] }. One character makes a
          short string that survives the copy out of the in-game EditBox.
    * /gaarvanguard exportall (the "Sync all" button) - a LIGHTWEIGHT skeleton. The same
          { k = "chars", chars = [...] } but with EVERY stored character and IDENTITY FIELDS ONLY
          (name, realm, race, class, classFile, faction, level, spec) - no professions/equipment/
          loot/talents - so the whole account fits in one short string that populates the pool.
    Select all (ctrl-A), copy (ctrl-C) and paste into the website. The website is the counterpart
    to this addon.

  Export-only
    This addon only EXPORTS. It never imports: everything you do with the data - your Vanguards,
    goals, readiness and character->goal mapping - happens on the Vanguard website. The in-game
    Vanguard view (/gaarvanguard, or the "Open Vanguard view" button) remains as a movable,
    closable, scrollable window that renders GaarVanguardDB.sync when present, but the addon no
    longer writes it, so it shows an export-only prompt pointing you at the website.

  Everything that reads the game API is wrapped in pcall so a call that is missing or shaped
  differently on one client degrades to "not captured" instead of erroring. The base64 and JSON
  encoders are self-contained here - no external libraries.

  /gaarvanguard opens the Vanguard view (subcommands: export, exportall, capture, sync, probe,
  minimap, minimap reset, config, wipe). Settings under Gaar -> Vanguard.

  Desktop app ("Vanguard Sync")
    Each character's ready-made export string is also kept in GaarVanguardDB.exports so a desktop
    companion app can read it from the SavedVariables file on disk and upload it. It is refreshed on
    logout / reload / exit, when the export is copied, after a recapture, and a few seconds after
    login, a level-up or a change of talents, equipment or professions - so it is already right
    before logout, and the logout scan only tops up what was read while playing (it never drops
    equipment it cannot read, nor goes back to a level or talents the client remembers from login).
    /gaarvanguard sync shows when this character's entry was last stored and what it holds
    (equipped items, loot rows, level, talent points) next to the in-play values and a live
    equipment read, plus what the last logout could read (lastLogoutDiag); auto-sync can be turned
    off (GaarVanguardDB.autoSync) from the minimap menu, the options panel or /gaarvanguard sync off.

  Minimap button: left-click opens a small box with this character's export already selected
  (press Ctrl+C / Cmd+C and it closes itself), right-click opens a menu, drag moves it. Self-
  contained here because GaarVanguard ships on its own; it does not need GaarOptions.
]]

local _G = _G
local ADDON = "Gaar Vanguard"
local PREFIX = "VGD1:"
local FLAT = "Interface\\Buttons\\WHITE8x8"

-- Inventory slot id -> canonical slot NAME string. The website's VGD1 `chars` schema keys
-- equipment by this name, never the numeric INVSLOT id.
local SLOT_NAMES = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest",
    [6] = "Waist", [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands",
    [11] = "Finger1", [12] = "Finger2", [13] = "Trinket1", [14] = "Trinket2",
    [15] = "Back", [16] = "MainHand", [17] = "OffHand", [18] = "Ranged", [19] = "Tabard",
}
local SLOT_IDS = {}   -- the reverse: canonical slot name -> inventory slot id
for id, name in pairs(SLOT_NAMES) do SLOT_IDS[name] = id end

-- The item lookups live in C_Item on newer clients and as globals on Era; one local each keeps
-- the call sites below unchanged, the same move GaarLooter and GaarBags make.
local C_Item = _G.C_Item
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------
local function DB()
    if type(GaarVanguardDB) ~= "table" then GaarVanguardDB = {} end
    local d = GaarVanguardDB
    if d.chars == nil then d.chars = {} end       -- ["Name-Realm"] = character record
    if d.maxLoot == nil then d.maxLoot = 100 end  -- per-character loot rows kept
    -- d.sync is legacy (was set by the removed import box); the addon no longer writes it.
    -- d.autoSync (stored exports for the desktop app on/off) is defaulted by AutoSyncEnabled().
    return d
end

-- Who we are this session. The database is account-wide, so every write is attributed to the
-- character currently logged in via this key.
local ME, REALM, CHARKEY = nil, nil, nil

-- Full character name. WoW Forever names are "Firstname Lastname", but UnitName("player") has been
-- seen to hand back only the first name ("Mag" instead of "Mag Tics"). So we ask every name API the
-- client exposes and keep the most COMPLETE answer - the value that actually carries a surname (a
-- space) - never inventing one: every candidate is a verbatim API return. The realm is captured
-- separately (GetRealmName), so any "-Realm" suffix an API appends is stripped here. The name is the
-- character's identity key on the website, so both exports depend on getting it right.
-- `/gaarvanguard probe` dumps each raw API return so we can confirm which one carries the full name.
local function pcall1(fn, ...)   -- first return value of fn, or nil if it errors or is missing
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

local function StripRealm(n)
    if type(n) ~= "string" then return nil end
    n = n:match("^%s*(.-)%s*$")   -- trim surrounding whitespace
    n = n:gsub("%-.*$", "")       -- drop a "-Realm" suffix (names never contain a hyphen)
    if n == "" or n == "Unknown" then return nil end
    return n
end

local function FullPlayerName()
    local realm = pcall1(GetRealmName) or ""
    local list, seen = {}, {}
    local function add(v)
        v = StripRealm(v)
        if v and not seen[v] then seen[v] = true; list[#list + 1] = v end
    end

    -- UnitName("player") -> name, realm (for the player the 2nd return is normally the realm or "").
    local ok, n1, n2 = pcall(function() return UnitName("player") end)
    if ok then
        add(n1)
        -- Forever's surname system may return the surname as UnitName's 2nd value instead of the
        -- realm; combine only when that value is a plain word that is not the realm, so a normal
        -- client (2nd return = realm or empty) is left untouched.
        if type(n1) == "string" and type(n2) == "string" and n2 ~= "" and n2 ~= realm
           and not n2:find("-") and not n2:find(" ") then
            add(n1 .. " " .. n2)
        end
    end
    -- GetUnitName(unit, true) -> "Name" on the player's own realm, "Name-Realm" cross-realm.
    add(pcall1(function() return GetUnitName and GetUnitName("player", true) end))
    -- UnitFullName("player") -> name, realm (name only).
    add(pcall1(function() return UnitFullName and UnitFullName("player") end))

    -- Pick the most complete: prefer a candidate that carries a surname (a space); among equals the
    -- longest string wins. Falls back to the first (UnitName) candidate when none carry a surname.
    local best
    for _, v in ipairs(list) do
        local vSpace = v:find(" ") ~= nil
        if not best then
            best = v
        else
            local bSpace = best:find(" ") ~= nil
            if vSpace and not bSpace then best = v
            elseif vSpace == bSpace and #v > #best then best = v end
        end
    end
    return best
end

local function Identify()
    ME = FullPlayerName() or ME
    REALM = (GetRealmName and GetRealmName()) or REALM or "?"
    if ME then CHARKEY = ME .. "-" .. REALM end
end

-- The current character's record, created on first use so loot captured before the first full
-- capture still lands somewhere sensible.
local function CurrentChar()
    if not CHARKEY then Identify() end
    if not CHARKEY then return nil end
    local d = DB()
    local c = d.chars[CHARKEY]
    if not c then
        c = { name = ME, realm = REALM, loot = {} }
        d.chars[CHARKEY] = c
    end
    if c.loot == nil then c.loot = {} end
    return c
end

-- ---------------------------------------------------------------------------
-- base64 (self-contained, standard alphabet)
-- ---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Base64Encode(data)
    if type(data) ~= "string" then return "" end
    local pad = ({ "", "==", "=" })[#data % 3 + 1]
    return (data:gsub(".", function(x)
        local r, byte = "", x:byte()
        for i = 8, 1, -1 do r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return B64:sub(c + 1, c + 1)
    end) .. pad
end

-- The reverse, only used to read a stored export back for /gaarvanguard sync. Characters outside the
-- alphabet (padding included) are skipped.
local function Base64Decode(data)
    if type(data) ~= "string" then return "" end
    local out, acc, bits = {}, 0, 0
    for i = 1, #data do
        local v = B64:find(data:sub(i, i), 1, true)
        if v then
            acc = acc * 64 + (v - 1)
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local p = 2 ^ bits
                out[#out + 1] = string.char(math.floor(acc / p))
                acc = acc % p
            end
        end
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- JSON encode (self-contained)
-- ---------------------------------------------------------------------------
local JsonEncode
local JsonQuote

local JSON_ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

JsonQuote = function(s)
    s = string.gsub(s, '[%z\1-\31\\"]', function(c)
        return JSON_ESCAPES[c] or string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. s .. '"'
end

-- A table is treated as an array when its keys are exactly 1..n, otherwise as an object. Empty
-- tables encode as [] - every empty table this addon produces is a list (loot, professions...).
local function IsArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

JsonEncode = function(v)
    local tp = type(v)
    if v == nil then
        return "null"
    elseif tp == "boolean" then
        return v and "true" or "false"
    elseif tp == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.14g", v)
    elseif tp == "string" then
        return JsonQuote(v)
    elseif tp == "table" then
        local arr, n = IsArray(v)
        if arr then
            local parts = {}
            for i = 1, n do parts[i] = JsonEncode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = JsonQuote(tostring(k)) .. ":" .. JsonEncode(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

-- ---------------------------------------------------------------------------
-- Character capture. Every reader is guarded so a missing or reshaped API on one client is a
-- blank field rather than an error.
-- ---------------------------------------------------------------------------
local function safe(fn, ...)
    local ok, a, b, c, d, e, f, g = pcall(fn, ...)
    if ok then return a, b, c, d, e, f, g end
    return nil
end

-- Newer clients can hand back a "secret" value that may not be compared, indexed or used as a key.
-- Anything that might be one is checked here before it is used at all.
local issecretvalue = _G.issecretvalue
local function IsSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    return issecretvalue(v) and true or false
end

-- C_Timer.After where the client has it; returns false (and does nothing) where it does not.
local function After(seconds, fn)
    local CT = _G.C_Timer
    if type(CT) == "table" and type(CT.After) == "function" then
        CT.After(seconds, fn)
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- In-play state versus the logout scan.
--
-- On build 1.60.1.70338 quitting the game stored an export with the level and talents the character
-- had at LOGIN (level 24, 20 points) although it had levelled to 25 and spent a point during play,
-- while a /reload a few minutes later stored the right values. When the client exits, UnitLevel and
-- the trait graph at PLAYER_LOGOUT can hand back the state from login, or nothing at all, just as the
-- inventory can be gone already (see Equipment below). A stale reading looks perfectly valid, so it
-- cannot be caught by checking the value alone.
--
-- So the source of truth is the most recent capture made while PLAYING (`inPlay`); the logout scan
-- only adds what it can read that is plausibly newer:
--   * level: the highest level seen this session (a level never goes down within one), counting
--     the level PLAYER_LEVEL_UP announces even before UnitLevel catches up;
--   * talents: the in-play build, unless the logout read has MORE points spent (a point spent in the
--     last seconds before logout) and no more than the level allows;
--   * professions: the in-play list, each skill raised to the logout value where that is higher;
--   * equipment: merged slot by slot (CaptureEquipment).
-- `liveRead` keeps what the most recent capture could read live, for GaarVanguardDB.lastLogoutDiag.
-- ---------------------------------------------------------------------------
local loggingOut = false   -- set by the PLAYER_LOGOUT handler before the final export is built
local inPlay = {}          -- lvl, talents, talentPts, spec, professions from in-play captures
local liveRead = {}        -- lvl, talentPts, profs, equip, equipUnknown from the latest live read

-- UnitLevel("player") as a plain positive number, or nil when it is missing, errors, is secret or 0.
local function ReadLiveLevel()
    local fn = _G.UnitLevel
    if type(fn) ~= "function" then return nil end
    local ok, lvl = pcall(fn, "player")
    if not ok or IsSecret(lvl) then return nil end
    lvl = tonumber(lvl)
    if lvl and lvl > 0 then return lvl end
    return nil
end

-- UnitXP / UnitXPMax ("player"): the XP earned within the current level and the XP that level needs,
-- as whole numbers. nil when either API is missing, errors, is secret or not a number, when the level
-- needs no XP (xpMax 0, e.g. at the level cap), or when the pair does not fit (xp below 0 or above
-- xpMax). The third value is the rested XP pool, GetXPExhaustion(): a whole number >= 0, and 0 when
-- the client says "not rested" (nil or 0) or the pool cannot be read (missing, error, secret, not a
-- number), so it is always there whenever xp/xpMax are.
local function ReadLiveXP()
    local fx, fm = _G.UnitXP, _G.UnitXPMax
    if type(fx) ~= "function" or type(fm) ~= "function" then return nil end
    local okX, xp = pcall(fx, "player")
    local okM, xpMax = pcall(fm, "player")
    if not okX or not okM or IsSecret(xp) or IsSecret(xpMax) then return nil end
    xp, xpMax = tonumber(xp), tonumber(xpMax)
    if not xp or not xpMax then return nil end
    if not (xpMax > 0 and xp >= 0 and xp <= xpMax) then return nil end   -- also rejects NaN
    local rested = 0
    local fr = _G.GetXPExhaustion
    if type(fr) == "function" then
        local okR, r = pcall(fr)
        if okR and not IsSecret(r) then
            r = tonumber(r)
            if r and r > 0 then rested = math.floor(r) end   -- `r > 0` also rejects NaN
        end
    end
    return math.floor(xp), math.floor(xpMax), rested
end

-- Read the XP live and, while playing, keep it in `inPlay` together with the level UnitLevel reported
-- in the same moment (`xpLvl`), so the export only ever pairs XP with the level it belongs to: XP
-- resets at a level-up, and UnitLevel can lag behind PLAYER_LEVEL_UP. At logout the read is kept for
-- the diagnostics only, as with the level: the client can answer there with the state from login.
local function UpdateInPlayXP()
    local lvl = ReadLiveLevel()
    local xp, xpMax, rested = ReadLiveXP()
    liveRead.xp, liveRead.xpRested = xp, rested
    if loggingOut then return end
    if lvl and xp then
        inPlay.xp, inPlay.xpMax, inPlay.xpRested, inPlay.xpLvl = xp, xpMax, rested, lvl
    end
end

-- Total points spent in a talent build (the sum of its trees' points), or nil for no build.
local function TalentPoints(build)
    if type(build) ~= "table" or #build == 0 then return nil end
    local n = 0
    for _, t in ipairs(build) do
        if type(t) == "table" then n = n + (tonumber(t.points) or 0) end
    end
    return n
end

local function CaptureIdentity(c)
    Identify()
    -- Always store the FULL "First Last" name (same helper the per-character export uses), so the
    -- stored record - and therefore the lightweight exportall/syncall roster - never holds a bare
    -- first name.
    c.name = FullPlayerName() or ME or c.name
    c.realm = REALM or c.realm
    local raceName = safe(UnitRace, "player")
    c.race = raceName or c.race
    -- Canonical field names the website expects: `cls` (localized class) and `lvl` (number).
    -- `classFile` (the locale-independent token) is kept alongside `cls` as a harmless extra.
    local className, classFile = safe(UnitClass, "player")
    c.cls = className or c.cls
    c.classFile = classFile or c.classFile
    -- Level: the live read, but never below the highest level seen while playing this session.
    local prevLvl = c.lvl
    local lvl = ReadLiveLevel()
    liveRead.lvl = lvl
    if lvl and not loggingOut and lvl > (inPlay.lvl or 0) then inPlay.lvl = lvl end
    local use = math.max(lvl or 0, inPlay.lvl or 0)
    if use > 0 then c.lvl = use end
    -- XP within the level (`xp` / `xpMax`, with the rested pool `xpRested`): the latest in-play read, and only while it was read at
    -- the level stored above; a read from another level is dropped rather than exported against the
    -- wrong level. With no in-play read this session the stored pair stands while the level is
    -- unchanged.
    UpdateInPlayXP()
    if inPlay.xpLvl and inPlay.xpLvl == c.lvl then
        c.xp, c.xpMax, c.xpRested = inPlay.xp, inPlay.xpMax, inPlay.xpRested or 0
    elseif inPlay.xpLvl or c.lvl ~= prevLvl then
        c.xp, c.xpMax, c.xpRested = nil, nil, nil
    end
    local faction = safe(UnitFactionGroup, "player")
    if faction and faction ~= "Neutral" then c.faction = faction end
end

-- Guild + rank name from GetGuildInfo("player"): guildName, guildRankName, guildRankIndex.
-- Cleared when not in a guild so a stale name never lingers on the record.
local function CaptureGuild(c)
    if type(GetGuildInfo) ~= "function" then return end
    local guildName, rankName = safe(GetGuildInfo, "player")
    if guildName and guildName ~= "" then
        c.guild = guildName
        c.guildRank = (rankName ~= "" and rankName) or nil
    else
        c.guild = nil
        c.guildRank = nil
    end
end

-- ---------------------------------------------------------------------------
-- C_SpecializationInfo access. The binary made this look like Forever's replacement for the removed
-- classic tab talent API (see docs/forever-client-findings.md), but the in-game probe (2026-09-23)
-- showed it is CLASS-LEVEL on Forever: GetSpecializationInfo(1) -> name = the class ("Mage"),
-- pointsSpent always 0. So it does NOT carry the Vanilla per-tree points and is NOT used for the
-- spec/talent wiring any more - the wiring reads the trait graph (ScanTalentsTraits) instead. These
-- helpers survive only to feed the talent probe, which still dumps C_SpecializationInfo for the
-- record and to catch any client where it behaves differently.
--
-- GetSpecializationInfo answers with a value tuple per the binary's Usage line, but - exactly like
-- C_SkillInfo.GetSkillLineInfo returning a table - a client could hand back a table, so the accessor
-- normalises both.
-- ---------------------------------------------------------------------------
local C_SpecInfo = _G.C_SpecializationInfo

-- Number of specializations for the current character (class-level on Forever). Namespaced getter
-- first, then the bare global, then derived from the class id.
local function Spec_GetNum()
    local fn = (C_SpecInfo and C_SpecInfo.GetNumSpecializations) or _G.GetNumSpecializations
    if type(fn) == "function" then
        local n = tonumber(safe(fn))
        if n and n > 0 then return n end
    end
    local byClass = (C_SpecInfo and C_SpecInfo.GetNumSpecializationsForClassID)
        or _G.GetNumSpecializationsForClassID
    if type(byClass) == "function" then
        local _, _, classID = safe(UnitClass, "player")
        if classID then
            local n = tonumber(safe(byClass, classID))
            if n and n > 0 then return n end
        end
    end
    return 0
end

-- Returns name, pointsSpent, specId for specialization `query` (an index 1..N). Normalises the
-- tuple form (specId, name, ..., pointsSpent is the 7th value) and a defensive table form.
-- Namespaced getter first, bare global as the alias.
local function Spec_GetInfo(query)
    local fn = (C_SpecInfo and C_SpecInfo.GetSpecializationInfo) or _G.GetSpecializationInfo
    if type(fn) ~= "function" then return nil end
    local a, b, _, _, _, _, g = safe(fn, query)
    if type(a) == "table" then
        return a.name or a.specName,
               tonumber(a.pointsSpent) or 0,
               tonumber(a.id or a.specId) or nil
    end
    -- tuple: specId(1), name(2), description(3), icon(4), role(5), primaryStat(6), pointsSpent(7)
    return b, tonumber(g) or 0, tonumber(a) or nil
end

-- Classic Era: the Vanilla talent tab with the most points spent -> name, points.
local function BestTabByPoints()
    if type(_G.GetNumTalentTabs) ~= "function" or type(_G.GetTalentTabInfo) ~= "function" then
        return nil, 0
    end
    local tabs = tonumber(safe(_G.GetNumTalentTabs)) or 0
    local best, bestPts = nil, 0
    for i = 1, tabs do
        -- Classic: name, iconTexture, pointsSpent, ...
        local name, _, pts = safe(_G.GetTalentTabInfo, i)
        pts = tonumber(pts) or 0
        if name and pts > bestPts then best, bestPts = name, pts end
    end
    return best, bestPts
end

-- Resolve a spell id to its name via the modern C_Spell API (present on Forever), falling back to
-- the classic global. C_Spell.GetSpellName returns the name directly; C_Spell.GetSpellInfo returns a
-- table with .name; the bare global returns the name as its first value.
local function ResolveSpellName(spellID)
    if type(spellID) ~= "number" or spellID <= 0 then return nil end
    local CS = _G.C_Spell
    if type(CS) == "table" then
        if type(CS.GetSpellName) == "function" then
            local n = safe(CS.GetSpellName, spellID)
            if type(n) == "string" and n ~= "" then return n end
        end
        if type(CS.GetSpellInfo) == "function" then
            local info = safe(CS.GetSpellInfo, spellID)
            if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
                return info.name
            end
        end
    end
    if type(_G.GetSpellInfo) == "function" then
        local n = safe(_G.GetSpellInfo, spellID)
        if type(n) == "string" and n ~= "" then return n end
    end
    return nil
end

-- A spell texture's Wowhead-style icon basename, or nil. On a Vanilla-content client GetSpellTexture
-- returns a path STRING ("Interface\\Icons\\Spell_Fire_FlameBolt"); we take the lowercased basename
-- after the last slash/backslash and strip any extension ("spell_fire_flamebolt"). A NUMBER return
-- (fileDataID on a modern-asset client) has no reliable name, so we return nil and the website falls
-- back to a generic icon + Wowhead tooltip. We never invent an icon name.
local function IconBasenameFromTexture(tex)
    if type(tex) ~= "string" or tex == "" then return nil end
    local base = tex:match("[^\\/]+$") or tex
    base = base:gsub("%.%w+$", "")   -- drop a file extension if the path carries one
    if base == "" then return nil end
    return base:lower()
end

-- Resolve a spellID to its icon basename via GetSpellTexture (classic global first, then the modern
-- C_Spell namespace). Returns the lowercased basename, or nil when the client hands back a numeric
-- fileDataID or nothing.
local function ResolveSpellIcon(spellID)
    if type(spellID) ~= "number" or spellID <= 0 then return nil end
    local tex
    if type(_G.GetSpellTexture) == "function" then
        tex = safe(_G.GetSpellTexture, spellID)
    end
    if tex == nil then
        local CS = _G.C_Spell
        if type(CS) == "table" and type(CS.GetSpellTexture) == "function" then
            tex = safe(CS.GetSpellTexture, spellID)
        end
    end
    return IconBasenameFromTexture(tex)
end

-- Resolve a purchased trait node to a talent name: its committed entry -> definition -> overrideName,
-- or the definition's spell name. Prefers the entries that actually carry ranks.
local function ResolveNodeTalentName(CT, configID, ni)
    if type(ni) ~= "table" or type(CT.GetEntryInfo) ~= "function" then return nil end
    local entryIDs = ni.entryIDsWithCommittedRanks
    if type(entryIDs) ~= "table" or not entryIDs[1] then entryIDs = ni.entryIDs end
    if type(entryIDs) ~= "table" then return nil end
    for _, entryID in ipairs(entryIDs) do
        local ei = safe(CT.GetEntryInfo, configID, entryID)
        if type(ei) == "table" and ei.definitionID and type(CT.GetDefinitionInfo) == "function" then
            local di = safe(CT.GetDefinitionInfo, ei.definitionID)
            if type(di) == "table" then
                if type(di.overrideName) == "string" and di.overrideName ~= "" then return di.overrideName end
                local nm = ResolveSpellName(di.spellID or di.overriddenSpellID)
                if nm then return nm end
            end
        end
    end
    return nil
end

-- Like ResolveNodeTalentName, but also returns the node's spellID so the full-tree export can carry
-- an icon + Wowhead link for EVERY node (purchased or not). Committed entries first, else all entries.
-- Returns (name, spellID); either may be nil when the definition does not resolve. Used only by the
-- calculator export; ResolveNodeTalentName is left untouched so the confirmed spec/probe paths cannot
-- regress.
local function ResolveNodeEntry(CT, configID, ni)
    if type(ni) ~= "table" or type(CT.GetEntryInfo) ~= "function" then return nil, nil end
    local entryIDs = ni.entryIDsWithCommittedRanks
    if type(entryIDs) ~= "table" or not entryIDs[1] then entryIDs = ni.entryIDs end
    if type(entryIDs) ~= "table" then return nil, nil end
    for _, entryID in ipairs(entryIDs) do
        local ei = safe(CT.GetEntryInfo, configID, entryID)
        if type(ei) == "table" and ei.definitionID and type(CT.GetDefinitionInfo) == "function" then
            local di = safe(CT.GetDefinitionInfo, ei.definitionID)
            if type(di) == "table" then
                local spellID = tonumber(di.spellID) or tonumber(di.overriddenSpellID)
                local name
                if type(di.overrideName) == "string" and di.overrideName ~= "" then
                    name = di.overrideName
                else
                    name = ResolveSpellName(di.spellID or di.overriddenSpellID)
                end
                if name or spellID then return name, spellID end
            end
        end
    end
    return nil, nil
end

-- Classic Vanilla talent-tab names, in ascending posX order (left -> right = classic tab order).
-- Forever (probe 2026-09-24) exposes NO C_Traits subtrees at all - `GetTraitTreeForSpec` is nil, and
-- neither the config, the tree, nor any node carries a subTreeID. Instead the three Vanilla trees are
-- three horizontal posX BANDS of the one class trait tree (Mage treeID 1112: low band = Arcane, mid =
-- Fire, high = Frost), confirmed because the single purchased node (105795, posX 6220 = MID) resolves
-- to spellID 11069 "Improved Fireball", a Fire talent. So a purchased node's posX band -> its tab.
local CLASS_TREE_NAMES = {
    WARRIOR = { "Arms", "Fury", "Protection" },
    PALADIN = { "Holy", "Protection", "Retribution" },
    HUNTER  = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE   = { "Assassination", "Combat", "Subtlety" },
    PRIEST  = { "Discipline", "Holy", "Shadow" },
    SHAMAN  = { "Elemental", "Enhancement", "Restoration" },
    MAGE    = { "Arcane", "Fire", "Frost" },
    WARLOCK = { "Affliction", "Demonology", "Destruction" },
    DRUID   = { "Balance", "Feral Combat", "Restoration" },
}

-- Cluster numbers into k contiguous bands by splitting the sorted unique values at their (k-1) largest
-- gaps. Returns a list of { min, max } ranges in ascending order, or nil if there are fewer than k
-- unique values or the split does not yield exactly k bands.
local function ClusterBands(values, k)
    local uniq, seen = {}, {}
    for _, v in ipairs(values) do
        v = tonumber(v)
        if v and not seen[v] then seen[v] = true; uniq[#uniq + 1] = v end
    end
    if #uniq < k then return nil end
    table.sort(uniq)
    local gaps = {}
    for i = 2, #uniq do gaps[#gaps + 1] = { gap = uniq[i] - uniq[i - 1], at = i } end
    table.sort(gaps, function(a, b)
        if a.gap ~= b.gap then return a.gap > b.gap end
        return a.at < b.at
    end)
    local splits = {}
    for i = 1, k - 1 do splits[gaps[i].at] = true end
    local bands, cur = {}, { min = uniq[1], max = uniq[1] }
    for i = 2, #uniq do
        if splits[i] then bands[#bands + 1] = cur; cur = { min = uniq[i], max = uniq[i] }
        else cur.max = uniq[i] end
    end
    bands[#bands + 1] = cur
    if #bands ~= k then return nil end
    return bands
end

-- The 1-based index of the band whose [min,max] contains x, or nil.
local function BandOf(bands, x)
    x = tonumber(x)
    if not x then return nil end
    for i, b in ipairs(bands) do
        if x >= b.min and x <= b.max then return i end
    end
    return nil
end

-- Best-effort talent read via the retail trait system (C_ClassTalents + C_Traits). The Forever probes
-- settled the model (see docs/forever-client-findings.md): there is ONE class trait tree (Mage ->
-- treeID 1112), C_SpecializationInfo is class-level, the C_SkillInfo Arcane/Fire/Frost lines all read
-- rank 1/1, and Forever exposes NO subtrees - so the spent point lives only on a purchased trait node,
-- and the Vanilla tree is that node's posX BAND. Primary route: cluster every node's posX into 3 bands,
-- assign each purchased node to a band, and map the band (left->right) to the classic tab name via
-- CLASS_TREE_NAMES[class]. Spec = the band with the most purchased ranks. Fallback (unchanged from the
-- subtree work, so nothing regresses): group by subTreeID / dominant purchased talent name.
--
-- Returns a build { { tab, points, talents = { {name,rank,max,tier,col} }, named } }, or nil when the
-- trait config cannot be read or nothing is purchased. `named` is true only when a real name resolved
-- - a numeric id is never emitted as a spec, and a spec is never invented.
local function ScanTalentsTraits()
    local CCT, CT = _G.C_ClassTalents, _G.C_Traits
    if type(CCT) ~= "table" or type(CT) ~= "table" then return nil end
    if type(CCT.GetActiveConfigID) ~= "function" or type(CT.GetConfigInfo) ~= "function" then return nil end
    if type(CT.GetTreeNodes) ~= "function" or type(CT.GetNodeInfo) ~= "function" then return nil end
    local configID = safe(CCT.GetActiveConfigID)
    if type(configID) ~= "number" then return nil end
    local cfg = safe(CT.GetConfigInfo, configID)
    if type(cfg) ~= "table" or type(cfg.treeIDs) ~= "table" then return nil end

    -- One pass: collect every node's posX (for banding) and every purchased node (posX, ranks, subID,
    -- resolved talent name).
    local allPosX, purchased, anyPurchased = {}, {}, false
    for _, treeID in ipairs(cfg.treeIDs) do
        local nodes = safe(CT.GetTreeNodes, treeID)
        if type(nodes) == "table" then
            for _, nodeID in ipairs(nodes) do
                local ni = safe(CT.GetNodeInfo, configID, nodeID)
                if type(ni) == "table" then
                    local px = tonumber(ni.posX)
                    if px then allPosX[#allPosX + 1] = px end
                    local r = tonumber(ni.ranksPurchased) or tonumber(ni.activeRank) or 0
                    if r > 0 then
                        anyPurchased = true
                        purchased[#purchased + 1] = {
                            posX = px, ranks = r,
                            subID = tonumber(ni.subTreeID) or 0,
                            name = ResolveNodeTalentName(CT, configID, ni),
                        }
                    end
                end
            end
        end
    end
    if not anyPurchased then return nil end

    -- Primary route: posX bands -> classic tab names.
    local _, classToken = safe(UnitClass, "player")
    local treeNames = (type(classToken) == "string") and CLASS_TREE_NAMES[string.upper(classToken)] or nil
    local bands = ClusterBands(allPosX, 3)
    if treeNames and bands and #bands == 3 then
        local bandPoints = { 0, 0, 0 }
        local bandTalents = { {}, {}, {} }
        local ok = true
        for _, p in ipairs(purchased) do
            local bi = BandOf(bands, p.posX)
            if not bi then ok = false; break end
            bandPoints[bi] = bandPoints[bi] + p.ranks
            if p.name then
                local bt = bandTalents[bi]
                bt[#bt + 1] = { name = p.name, rank = p.ranks, max = p.ranks, tier = 0, col = 0 }
            end
        end
        if ok then
            local build = {}
            for bi = 1, 3 do
                if bandPoints[bi] > 0 and treeNames[bi] then
                    build[#build + 1] = {
                        tab = treeNames[bi], points = bandPoints[bi],
                        talents = bandTalents[bi], named = true,
                    }
                end
            end
            if #build > 0 then return build end
        end
    end

    -- Fallback (subtree / dominant-talent-name): group purchased ranks by subTreeID (key 0 = no
    -- subtree), resolve a subtree name, else the dominant purchased talent's own name.
    local groups, order = {}, {}
    local function group(key)
        local g = groups[key]
        if not g then g = { key = key, points = 0, talents = {} }; groups[key] = g; order[#order + 1] = key end
        return g
    end
    for _, p in ipairs(purchased) do
        local g = group(p.subID)
        g.points = g.points + p.ranks
        if p.name then g.talents[#g.talents + 1] = { name = p.name, rank = p.ranks, max = p.ranks, tier = 0, col = 0 } end
    end
    local build = {}
    for _, key in ipairs(order) do
        local g = groups[key]
        local name
        if key > 0 and type(CT.GetSubTreeInfo) == "function" then
            local si = safe(CT.GetSubTreeInfo, configID, key)
            if type(si) == "table" and type(si.name) == "string" and si.name ~= "" then name = si.name end
        end
        if not name then
            local bestRank = 0
            for _, t in ipairs(g.talents) do
                if (t.rank or 0) > bestRank then bestRank, name = t.rank, t.name end
            end
        end
        build[#build + 1] = {
            tab = name or ("Subtree " .. tostring(key)),
            points = g.points, talents = g.talents, named = (name ~= nil and name ~= ""),
        }
    end
    if #build == 0 then return nil end
    return build
end

-- FULL talent-calculator export for Forever. Where ScanTalentsTraits emits only PURCHASED nodes (enough
-- to name the spec), this walks EVERY node of the class trait tree so the website can draw the whole
-- calculator grid (3 trees, all talents, purchased ones highlighted). The model is identical to
-- ScanTalentsTraits' primary route (one class tree split into 3 horizontal posX bands = the Vanilla
-- trees, left->right = CLASS_TREE_NAMES order), so the same config/tree/band logic is reused.
--
-- Returns, in ascending-band order, one object per tree:
--   { tab = <CLASS_TREE_NAMES[band]>, points = <sum ranksPurchased in tree>,
--     talents = { { name, rank, max, tier, col, icon?, spellId? }, ... },
--     edges   = { { ft, fc, tt, tc }, ... } }
-- where:
--   rank = ranksPurchased (0 if not purchased), max = maxRanks,
--   tier = 0-based row from sorted-unique posY across the WHOLE tree (top = 0),
--   col  = 0-based column from sorted-unique posX WITHIN the band (left = 0),
--   icon = lowercase icon basename (omitted when the client returns a numeric fileDataID),
--   spellId = the talent's spellID (omitted when unresolved).
--   edges = the prerequisite connector arrows the website draws, one per resolved visibleEdges
--     target, in grid coords: ft/fc = from (tier,col), tt/tc = to (tier,col). Deduplicated;
--     unresolvable endpoints skipped; empty {} when the client exposes no edges.
-- Returns nil (so the caller falls back to ScanTalentsTraits) when the trait config cannot be read,
-- the class is not in CLASS_TREE_NAMES, or the posX values do not cluster into exactly 3 bands.
local function ScanTalentsCalculator()
    local CCT, CT = _G.C_ClassTalents, _G.C_Traits
    if type(CCT) ~= "table" or type(CT) ~= "table" then return nil end
    if type(CCT.GetActiveConfigID) ~= "function" or type(CT.GetConfigInfo) ~= "function" then return nil end
    if type(CT.GetTreeNodes) ~= "function" or type(CT.GetNodeInfo) ~= "function" then return nil end

    -- Only classes with a known 3-tree layout use this route.
    local _, classToken = safe(UnitClass, "player")
    local treeNames = (type(classToken) == "string") and CLASS_TREE_NAMES[string.upper(classToken)] or nil
    if not treeNames then return nil end

    local configID = safe(CCT.GetActiveConfigID)
    if type(configID) ~= "number" then return nil end
    local cfg = safe(CT.GetConfigInfo, configID)
    if type(cfg) ~= "table" or type(cfg.treeIDs) ~= "table" then return nil end

    -- One pass: collect every node with its position, ranks, resolved name/spell/icon.
    local allPosX, allPosY, nodes = {}, {}, {}
    for _, treeID in ipairs(cfg.treeIDs) do
        local ids = safe(CT.GetTreeNodes, treeID)
        if type(ids) == "table" then
            for _, nodeID in ipairs(ids) do
                local ni = safe(CT.GetNodeInfo, configID, nodeID)
                if type(ni) == "table" then
                    local px, py = tonumber(ni.posX), tonumber(ni.posY)
                    if px and py then
                        allPosX[#allPosX + 1] = px
                        allPosY[#allPosY + 1] = py
                        local name, spellID = ResolveNodeEntry(CT, configID, ni)
                        nodes[#nodes + 1] = {
                            id = nodeID,
                            posX = px, posY = py,
                            rank = tonumber(ni.ranksPurchased) or tonumber(ni.activeRank) or 0,
                            max = tonumber(ni.maxRanks) or 0,
                            name = name, spellID = spellID,
                            icon = ResolveSpellIcon(spellID),
                            -- Prerequisite connector arrows. C_Traits exposes them on the node as an
                            -- array of TraitVisibleEdge {visualStyle, targetNode=<nodeID>}. Kept raw so
                            -- the edge pass below can resolve each target to grid (tier,col).
                            visibleEdges = (type(ni.visibleEdges) == "table") and ni.visibleEdges or nil,
                        }
                    end
                end
            end
        end
    end
    if #nodes == 0 then return nil end

    -- Bands split the tree into the 3 Vanilla trees (left->right). Bail if the split is not clean.
    local bands = ClusterBands(allPosX, 3)
    if not bands or #bands ~= 3 then return nil end

    -- tier: 0-based index of a node's posY within the sorted-unique posY of the WHOLE tree (top = 0).
    local function IndexMap(values)
        local uniq, seen = {}, {}
        for _, v in ipairs(values) do
            if not seen[v] then seen[v] = true; uniq[#uniq + 1] = v end
        end
        table.sort(uniq)
        local idx = {}
        for i, v in ipairs(uniq) do idx[v] = i - 1 end
        return idx
    end
    local tierOf = IndexMap(allPosY)

    -- col: 0-based index of a node's posX within the sorted-unique posX of ITS band (left = 0).
    local colOf = {}
    for bi = 1, 3 do
        local xs = {}
        for _, n in ipairs(nodes) do
            if BandOf(bands, n.posX) == bi then xs[#xs + 1] = n.posX end
        end
        colOf[bi] = IndexMap(xs)
    end

    -- Every node's grid coordinates (tier, col) and owning band, keyed by nodeID, so a visibleEdges
    -- target can be resolved to the SAME (tier,col) the talents array uses. col is band-relative.
    local posByID = {}
    for _, n in ipairs(nodes) do
        local bi = BandOf(bands, n.posX)
        if bi then
            posByID[n.id] = { tier = tierOf[n.posY] or 0, col = colOf[bi][n.posX] or 0, band = bi }
        end
    end

    local trees = {}
    for bi = 1, 3 do trees[bi] = { tab = treeNames[bi], points = 0, talents = {}, edges = {} } end
    local edgeSeen = { {}, {}, {} }   -- per-tree "ft,fc,tt,tc" set for dedup
    for _, n in ipairs(nodes) do
        local bi = BandOf(bands, n.posX)
        if not bi then return nil end   -- every collected posX is inside some band, but guard anyway
        local tree = trees[bi]
        tree.points = tree.points + n.rank
        local t = {
            rank = n.rank, max = n.max,
            tier = tierOf[n.posY] or 0,
            col = colOf[bi][n.posX] or 0,
        }
        if n.name then t.name = n.name end
        if n.spellID then t.spellId = n.spellID end
        if n.icon then t.icon = n.icon end
        tree.talents[#tree.talents + 1] = t

        -- Prerequisite edges: from this node to each visibleEdges target, expressed in grid
        -- coordinates. The edge is filed on the SOURCE node's tree; endpoints that cannot be
        -- resolved (target missing from the graph) are skipped; identical edges are deduplicated.
        if type(n.visibleEdges) == "table" then
            local from = posByID[n.id]
            if from then
                for _, e in ipairs(n.visibleEdges) do
                    local targetID
                    if type(e) == "table" then
                        targetID = e.targetNode or e.targetNodeID or e.targetNodeInfo
                    elseif type(e) == "number" then
                        targetID = e
                    end
                    local to = targetID and posByID[targetID] or nil
                    if to then
                        local key = from.tier .. "," .. from.col .. "," .. to.tier .. "," .. to.col
                        if not edgeSeen[bi][key] then
                            edgeSeen[bi][key] = true
                            tree.edges[#tree.edges + 1] =
                                { ft = from.tier, fc = from.col, tt = to.tier, tc = to.col }
                        end
                    end
                end
            end
        end
    end

    -- Walk each tree top-to-bottom, left-to-right so the array is grid-ordered; edges get a stable
    -- (ft,fc,tt,tc) order so the export is deterministic.
    for _, tree in ipairs(trees) do
        table.sort(tree.talents, function(a, b)
            if a.tier ~= b.tier then return a.tier < b.tier end
            return a.col < b.col
        end)
        table.sort(tree.edges, function(a, b)
            if a.ft ~= b.ft then return a.ft < b.ft end
            if a.fc ~= b.fc then return a.fc < b.fc end
            if a.tt ~= b.tt then return a.tt < b.tt end
            return a.tc < b.tc
        end)
    end
    return trees
end

-- Spec name = the talent tree with the most points spent. Tried in turn, all pcall-guarded:
--   1. Classic Era tabs (GetNumTalentTabs/GetTalentTabInfo) - the tab with the most points.
--   2. Forever trait graph (ScanTalentsTraits) - the posX band (left->right = Vanilla tab order,
--      mapped to CLASS_TREE_NAMES) with the most purchased ranks; the subtree / dominant-talent-name
--      route is kept as a fallback. Only a REAL resolved name is used, never a numeric id.
-- A character with nothing spent, or one whose purchased node cannot be resolved to any name,
-- legitimately reports no spec - we never invent one.
local function CaptureSpec(c)
    local tname, tpts = BestTabByPoints()
    if tname and tpts > 0 then c.spec = tname; return end

    local build = ScanTalentsTraits()
    if build then
        local best, bestPts, bestNamed = nil, 0, false
        for _, t in ipairs(build) do
            if (t.points or 0) > bestPts then best, bestPts, bestNamed = t.tab, t.points, t.named end
        end
        if best and bestPts > 0 and bestNamed then c.spec = best; return end
    end
    -- Nothing conclusive -> leave c.spec as it was (empty). Never invent a spec.
end

-- The FULL talent build, so the website can draw the whole tree, not just the spec name.
-- Captured live at capture/export exactly like professions/equipment, so the export never depends
-- on a cached build (written when early Forever builds did not load SavedVariables back; they do
-- from build 70291, but the live read is still the safer source). Tried in order, all pcall-guarded,
-- using whichever API the client actually exposes:
--
--   1. Classic talent API (Era). GetNumTalentTabs() + GetTalentTabInfo(tab) -> name, icon,
--      pointsSpent; then GetNumTalents(tab) + GetTalentInfo(tab, i) -> name, icon, tier, column,
--      rank, maxRank, ... (the classic signature). ALL talents are kept, including rank-0 ones, so
--      the tree is complete; ranks are always included so a 0-rank talent shows as 0. Tabs are
--      ordered by tab index; talents within a tab by tier then column.
--   2. Forever best-effort (ScanTalentsTraits): a per-tree points summary from the trait graph, in
--      the same shape with an empty per-talent list, exported only when the trees carry real names.
--      The classic tab globals are gone on Forever and C_SpecializationInfo is class-level there, so
--      the per-talent Vanilla tree cannot be reconstructed; the extended talent probe gathers the
--      raw C_ClassTalents/C_Traits/C_SkillInfo data so the exact per-point field can be pinned.
--
-- Shape written to c.talents (mirrored in the export and docs/gaarvanguard.md):
--   talents = { { tab = <tabName>, points = <pointsSpent>,
--                 talents = { { name, rank, max, tier, col, icon?, spellId? }, ... } }, ... }
-- The Forever calculator route (ScanTalentsCalculator) fills icon/spellId and includes rank-0 nodes so
-- the whole grid is present; the classic and purchased-only routes omit icon/spellId. An empty scan
-- leaves any previously captured build in place rather than wiping it.
local function ScanTalentsClassic()
    if type(GetNumTalentTabs) ~= "function" or type(GetTalentTabInfo) ~= "function" then return nil end
    if type(GetNumTalents) ~= "function" or type(GetTalentInfo) ~= "function" then return nil end
    local numTabs = tonumber(safe(GetNumTalentTabs)) or 0
    if numTabs < 1 then return nil end
    local build = {}
    for tab = 1, numTabs do
        -- Classic: name, iconTexture, pointsSpent, background, ...
        local tabName, _, pointsSpent = safe(GetTalentTabInfo, tab)
        local talents = {}
        local numTalents = tonumber(safe(GetNumTalents, tab)) or 0
        for i = 1, numTalents do
            -- Classic: name, iconTexture, tier, column, rank, maxRank, isExceptional, meetsPrereq
            local name, _, tier, column, rank, maxRank = safe(GetTalentInfo, tab, i)
            if name and name ~= "" then
                talents[#talents + 1] = {
                    name = name,
                    rank = tonumber(rank) or 0,
                    max = tonumber(maxRank) or 0,
                    tier = tonumber(tier) or 0,
                    col = tonumber(column) or 0,
                }
            end
        end
        -- Order by tier, then column, so the array walks the tree top-to-bottom, left-to-right.
        table.sort(talents, function(a, b)
            if a.tier ~= b.tier then return a.tier < b.tier end
            return a.col < b.col
        end)
        build[#build + 1] = {
            tab = tabName or ("Tab " .. tab),
            points = tonumber(pointsSpent) or 0,
            talents = talents,
        }
    end
    return build
end

local function CaptureTalents(c)
    -- 1. Classic per-talent tree (Era: GetTalentInfo tabs) - the true full grid when it exists.
    local build = ScanTalentsClassic()
    -- 2. Forever full calculator grid (3 posX-band trees, EVERY node) so the website can draw the
    --    whole calculator, not just purchased talents. nil when bands != 3 / class unknown.
    if not build or #build == 0 then
        build = ScanTalentsCalculator()
    end
    -- 3. Forever purchased-only fallback (ScanTalentsTraits): keeps the old behaviour for edge cases
    --    the calculator route rejects. Only exported when every tree carries a real name; a build of
    --    "Tree 12345" rows would only mislead the website, so otherwise talents stay empty this round.
    if not build or #build == 0 then
        local traits = ScanTalentsTraits()
        if traits then
            local allNamed = true
            for _, t in ipairs(traits) do if not t.named then allNamed = false; break end end
            if allNamed then build = traits end
        end
    end
    local livePts = TalentPoints(build)
    liveRead.talentPts = livePts
    -- At logout the in-play build wins (the live read may be the build from login), unless the live
    -- read has more points spent and no more than the level allows: a point spent in the seconds
    -- before logout, which no in-play capture has seen yet.
    if loggingOut and inPlay.talents then
        local newer = livePts and livePts > (inPlay.talentPts or 0)
            and (type(c.lvl) ~= "number" or livePts <= c.lvl)
        if not newer then
            c.talents = inPlay.talents
            c.spec = inPlay.spec
            return
        end
    end
    if build and #build > 0 then
        c.talents = build
        -- Backstop the spec from the build if CaptureSpec did not already resolve one: the tab/tree
        -- with the most points spent. Never invent a spec when nothing is spent.
        if not c.spec or c.spec == "" then
            local best, bestPts = nil, 0
            for _, t in ipairs(build) do
                if (t.points or 0) > bestPts then best, bestPts = t.tab, t.points end
            end
            if best and bestPts > 0 then c.spec = best end
        end
        if not loggingOut then
            inPlay.talents, inPlay.talentPts, inPlay.spec = build, livePts, c.spec
        end
    else
        -- Neither shape produced a build. Leave any previously captured build untouched; the probe
        -- reports which namespace exists so this can be extended when we have live data.
        c.talents = c.talents or {}
    end
end

-- The real primary + secondary professions, by English name. Only the classic skill-line
-- fallback below needs this filter: that reader enumerates *every* skill line - weapon skills,
-- Defense, Unarmed, languages, riding - so we keep only the trade skills. The C_TradeSkillUI
-- path returns profession indices directly and needs no filtering. Jewelcrafting/Inscription are
-- listed too so the same reader is correct on later content, harmless on Vanilla.
local PROFESSION_NAMES = {
    ["Alchemy"] = true, ["Blacksmithing"] = true, ["Enchanting"] = true, ["Engineering"] = true,
    ["Herbalism"] = true, ["Leatherworking"] = true, ["Mining"] = true, ["Skinning"] = true,
    ["Tailoring"] = true, ["Jewelcrafting"] = true, ["Inscription"] = true,
    ["Cooking"] = true, ["First Aid"] = true, ["Fishing"] = true,
}

-- Modern path (retail and the retail-shaped Forever client). The trap the first version hit:
-- GetProfessions and GetProfessionInfo are *globals* on these clients, NOT members of
-- C_TradeSkillUI - the Forever binary carries `Usage: GetProfessionInfo(index)` and both names as
-- plain globals, and C_TradeSkillUI has no GetProfessions at all. The old code looked for
-- C_TradeSkillUI.GetProfessions, found nil, and bailed before reading anything, so Forever
-- exported `professions:[]`. We read the globals first and only fall back to a C_TradeSkillUI
-- alias for any odd client that namespaces them.
--
-- GetProfessions() returns up to six profession skill-line INDICES (prof1, prof2, archaeology,
-- fishing, cooking, firstAid), so there is no header/enumeration problem and no filtering to do.
-- GetProfessionInfo(index) turns each into name, icon, skillLevel, maxSkillLevel, ...  Returns a
-- list, or nil when neither reader is present on the client.
local function ScanProfessionsModern()
    local TSU = _G.C_TradeSkillUI
    local getList = _G.GetProfessions or (TSU and TSU.GetProfessions)
    local getInfo = _G.GetProfessionInfo or (TSU and TSU.GetProfessionInfo)
    if type(getList) ~= "function" or type(getInfo) ~= "function" then return nil end
    local p1, p2, arch, fish, cook, firstaid = safe(getList)
    local indices = {}
    local function push(idx) if type(idx) == "number" and idx > 0 then indices[#indices + 1] = idx end end
    -- Pushed one at a time (not via a table literal) so a nil in the middle - e.g. a character
    -- with cooking but no primary profession - does not truncate the list.
    push(p1); push(p2); push(arch); push(fish); push(cook); push(firstaid)
    local out = {}
    for _, idx in ipairs(indices) do
        -- name, icon, skillLevel, maxSkillLevel, numAbilities, spellOffset, skillLine, ...
        local name, _, skillLevel, maxSkillLevel = safe(getInfo, idx)
        if name and name ~= "" then
            out[#out + 1] = { name = name, skill = tonumber(skillLevel) or 0, max = tonumber(maxSkillLevel) or 0 }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Skill-line access, abstracted over the two shapes a client offers, because the "classic"
-- reader itself moved namespaces on Forever:
--   * Classic Era: the bare globals GetNumSkillLines / GetSkillLineInfo / ExpandSkillHeader /
--     CollapseSkillHeader, where GetSkillLineInfo(i) returns MULTIPLE values
--     (name, isHeader, isExpanded, rank, numTempPoints, modifier, maxRank, ...).
--   * Forever (retail-shaped): those globals are gone; the same calls live under the beta-only
--     namespace C_SkillInfo, and C_SkillInfo.GetSkillLineInfo(i) returns a single TABLE
--     (skillLineAttributes: name, isHeader, isHeaderExpanded, rank, maxRank, ...) - a silent
--     shape change, not just a rename. Confirmed by strings in the Forever client binary; see
--     docs/forever-client-findings.md. The count getter GetNumSkillLines had no namespaced Usage
--     string, so we try C_SkillInfo.GetNumSkillLines then the global.
-- Every accessor below normalises to the Era-style tuple so the scanner reads one shape.
-- ---------------------------------------------------------------------------
local function SkillLine_GetNum()
    local CSI = _G.C_SkillInfo
    local fn = (CSI and CSI.GetNumSkillLines) or _G.GetNumSkillLines
    if type(fn) ~= "function" then return 0 end
    return tonumber(safe(fn)) or 0
end

-- Returns name, isHeader, isExpanded, rank, maxRank for skill line `i`, whichever shape the
-- client uses. nil when no reader exists at all.
local function SkillLine_GetInfo(i)
    local CSI = _G.C_SkillInfo
    if CSI and type(CSI.GetSkillLineInfo) == "function" then
        local t = safe(CSI.GetSkillLineInfo, i)
        if type(t) ~= "table" then return nil end
        local expanded = t.isHeaderExpanded
        if expanded == nil then expanded = t.isExpanded end
        return t.name or t.skillLineName,
               t.isHeader,
               expanded,
               tonumber(t.rank or t.skillRank) or 0,
               tonumber(t.maxRank or t.skillMaxRank) or 0
    end
    if type(_G.GetSkillLineInfo) == "function" then
        -- name, isHeader, isExpanded, rank, numTempPoints, modifier, maxRank, ...
        local name, isHeader, isExpanded, rank, _, _, maxRank = safe(_G.GetSkillLineInfo, i)
        return name, isHeader, isExpanded, tonumber(rank) or 0, tonumber(maxRank) or 0
    end
    return nil
end

local function SkillLine_HasReader()
    local CSI = _G.C_SkillInfo
    return (CSI and type(CSI.GetSkillLineInfo) == "function")
        or type(_G.GetSkillLineInfo) == "function"
end

local function SkillLine_Expand(i)
    local CSI = _G.C_SkillInfo
    local fn = (CSI and CSI.ExpandSkillHeader) or _G.ExpandSkillHeader
    if type(fn) == "function" then safe(fn, i) end
end

local function SkillLine_Collapse(i)
    local CSI = _G.C_SkillInfo
    local fn = (CSI and CSI.CollapseSkillHeader) or _G.CollapseSkillHeader
    if type(fn) == "function" then safe(fn, i) end
end

-- Expand every header so its children enumerate. Era's global takes 0 = "all"; the C_SkillInfo
-- per-index form may not honour 0, so after that we also walk the list and expand any header still
-- reported collapsed, re-scanning each time (expanding renumbers the rows below it). Bounded so a
-- client that never reports "expanded" cannot loop forever.
local function SkillLine_ExpandAll()
    SkillLine_Expand(0)
    for _ = 1, 60 do
        local n = SkillLine_GetNum()
        local didOne = false
        for i = 1, n do
            local _, isHeader, isExpanded = SkillLine_GetInfo(i)
            if isHeader and isExpanded == false then
                SkillLine_Expand(i)
                didOne = true
                break
            end
        end
        if not didOne then break end
    end
end

-- Re-collapse one header found by name, re-scanning fresh each call so a shifting index (every
-- collapse renumbers the rows after it) never collapses the wrong row.
local function CollapseSkillHeaderByName(name)
    if not SkillLine_HasReader() then return end
    local n = SkillLine_GetNum()
    for i = 1, n do
        local hname, isHeader = SkillLine_GetInfo(i)
        if isHeader and hname == name then SkillLine_Collapse(i); return end
    end
end

-- Skill-line fallback (Era via globals, Forever via C_SkillInfo). The original trap: a COLLAPSED
-- skill header hides its child skill lines from enumeration entirely, so a profession under a
-- collapsed header reads as absent - which is why the list came back empty. Expand every header
-- first, read, then restore the headers that were collapsed so the player's Skills window is left
-- as it was. Returns a list, or nil when no skill-line reader is present.
local function ScanProfessionsClassic()
    if not SkillLine_HasReader() then return nil end
    -- Remember which headers were collapsed, then expand all so their children enumerate.
    local collapsed = {}
    local n0 = SkillLine_GetNum()
    for i = 1, n0 do
        local name, isHeader, isExpanded = SkillLine_GetInfo(i)
        if isHeader and isExpanded == false then collapsed[#collapsed + 1] = name end
    end
    SkillLine_ExpandAll()
    local count = SkillLine_GetNum()
    local out = {}
    -- De-duplicate by name: on Forever the C_SkillInfo list reports several professions TWICE
    -- (the live probe saw Skinning / Tailoring / Cooking listed twice), so without this the export
    -- would carry duplicate rows. Keep one row per profession, preferring the higher skill/max if
    -- the two copies ever disagree.
    local seen = {}
    for i = 1, count do
        local name, isHeader, _, rank, maxRank = SkillLine_GetInfo(i)
        if name and not isHeader and PROFESSION_NAMES[name] then
            -- Canonical: `skill` (was `rank`) plus `max`.
            local skill, max = tonumber(rank) or 0, tonumber(maxRank) or 0
            local prev = seen[name]
            if prev then
                if skill > prev.skill then prev.skill = skill end
                if max > prev.max then prev.max = max end
            else
                local row = { name = name, skill = skill, max = max }
                seen[name] = row
                out[#out + 1] = row
            end
        end
    end
    -- Best-effort restore of the player's collapsed headers.
    for _, name in ipairs(collapsed) do CollapseSkillHeaderByName(name) end
    return out
end

-- Professions: the primary + secondary trade skills as { name, skill, max }. Scanned LIVE at
-- capture/export like equipment, so it is correct even when the stored record is empty or stale.
-- Prefer the modern C_TradeSkillUI reader (works on retail, Forever and Era), fall back to the
-- classic skill-line reader (with header expansion) where C_TradeSkillUI is absent. An empty
-- result leaves any previously captured list in place rather than wiping it.
local function CaptureProfessions(c)
    local out = ScanProfessionsModern()
    if not out or #out == 0 then
        local classic = ScanProfessionsClassic()
        if classic and #classic > 0 then out = classic end
    end
    liveRead.profs = out and #out or nil
    -- At logout the in-play list wins; a profession it holds only takes a higher skill/max from the
    -- live read. A profession only the live read has is left out: one learned during play was already
    -- stored by SKILL_LINES_CHANGED, so it is more likely one unlearned since login.
    if loggingOut and inPlay.professions then
        local live = {}
        if out then
            for _, p in ipairs(out) do live[p.name] = p end
        end
        local merged = {}
        for _, p in ipairs(inPlay.professions) do
            local l = live[p.name]
            merged[#merged + 1] = {
                name = p.name,
                skill = math.max(p.skill or 0, l and l.skill or 0),
                max = math.max(p.max or 0, l and l.max or 0),
            }
        end
        c.professions = merged
        return
    end
    if out and #out > 0 then
        if not loggingOut then inPlay.professions = out end
        c.professions = out
    else
        c.professions = c.professions or {}
    end
end

-- ---------------------------------------------------------------------------
-- Equipment: inventory slots 1-19. `slot` is stored as the canonical slot NAME string
-- (SLOT_NAMES), never the numeric id.
--
-- A single live scan is not something to trust on its own. On build 1.60.1.70338 the exports
-- stored at PLAYER_LOGOUT came out with an empty equipment list for every character while loot,
-- talents, professions and level were all there, and the website's gear was wiped on the next
-- upload. Either the client has already torn the inventory down by the time PLAYER_LOGOUT fires, or
-- a reader came back empty on that build; the code below copes with both:
--   * every slot is read through several APIs, feature-detected (GetInventoryItemLink /
--     GetInventoryItemID, then C_Item with an ItemLocation, then the tooltip data), and secret
--     values are treated as "could not read", never compared or indexed;
--   * GetInventoryItemTexture tells an empty slot from one that holds something we could not read;
--   * a reading is only taken at face value in-session, once the inventory has had a few seconds to
--     load after PLAYER_ENTERING_WORLD, and only when every slot was accounted for. Anything else -
--     including every scan at logout - is merged slot by slot over the best earlier reading (this
--     session's, else the stored record's), so gear is never dropped because a read failed;
--   * a reading that suddenly has no items at all where there were several before is not trusted
--     either: going naked happens one piece at a time, and each step is a reading of its own.
-- ---------------------------------------------------------------------------
local equipReady = false   -- set a few seconds after PLAYER_ENTERING_WORLD, once items have loaded
local sessionEquip         -- this session's last trusted (or merged) equipment list, nil until one

-- One reading from fn(...): nil when the API is missing, errors or hands back a secret. `bad` is
-- true when the API exists but could not be read.
local function ReadValue(fn, ...)
    if type(fn) ~= "function" then return nil, false end
    local ok, v = pcall(fn, ...)
    if not ok or IsSecret(v) then return nil, true end
    return v, false
end

local function EquipLocation(slot)
    local IL = _G.ItemLocation
    if type(IL) ~= "table" or type(IL.CreateFromEquipmentSlot) ~= "function" then return nil end
    local ok, loc = pcall(IL.CreateFromEquipmentSlot, IL, slot)
    if ok and type(loc) == "table" then return loc end
    return nil
end

-- One equipment slot. Returns item, state: item is { slot, itemId, quality, name } or nil; state is
-- "item", "empty" (verifiably nothing there) or "unknown" (could not tell).
local function ReadEquipSlot(slot)
    local unreadable, readers = false, 0
    local function read(fn, ...)
        if type(fn) == "function" then readers = readers + 1 end
        local v, bad = ReadValue(fn, ...)
        if bad then unreadable = true end
        return v
    end
    local function str(v) if type(v) == "string" and v ~= "" then return v end return nil end
    local function num(v) v = tonumber(v); if v and v > 0 then return v end return nil end

    local link = str(read(_G.GetInventoryItemLink, "player", slot))
    local itemId = num(read(_G.GetInventoryItemID, "player", slot))

    local CI = _G.C_Item
    if (not link or not itemId) and type(CI) == "table" then
        local loc = EquipLocation(slot)
        if loc then
            local exists = true
            if type(CI.DoesItemExist) == "function" then exists = read(CI.DoesItemExist, loc) end
            if exists then
                link = link or str(read(CI.GetItemLink, loc))
                itemId = itemId or num(read(CI.GetItemID, loc))
            end
        end
    end

    local itemReaders = readers   -- how many item APIs this client actually has

    -- Is anything in the slot at all? nil texture = empty; no texture API = cannot tell.
    local texFn = _G.GetInventoryItemTexture
    local tex = read(texFn, "player", slot)

    -- Something is there but the direct readers did not say what: ask the tooltip data.
    if not link and not itemId and tex ~= nil then
        local TI = _G.C_TooltipInfo
        if type(TI) == "table" then
            local data = read(TI.GetInventoryItem, "player", slot)
            if type(data) == "table" then
                local h, id = data.hyperlink, data.id
                if not IsSecret(h) then link = str(h) end
                if not IsSecret(id) then itemId = num(id) end
            end
        end
    end

    if not link and not itemId then
        if tex == nil and type(texFn) == "function" and itemReaders > 0 and not unreadable then
            return nil, "empty"
        end
        return nil, "unknown"
    end

    if not itemId and link and GetItemInfoInstant then itemId = num(ReadValue(GetItemInfoInstant, link)) end
    -- GetItemInfo is asynchronous: name and quality are nil for an item the client has not cached
    -- yet. Quality then comes from the inventory itself, and the name falls back to the raw link.
    local name, quality
    if GetItemInfo then
        local ok, n, _, q = pcall(GetItemInfo, link or itemId)
        if ok then
            if not IsSecret(n) then name = str(n) end
            if not IsSecret(q) then quality = tonumber(q) end
        end
    end
    if quality == nil then quality = tonumber((ReadValue(_G.GetInventoryItemQuality, "player", slot))) end
    if not name and itemId and type(CI) == "table" and type(CI.RequestLoadItemDataByID) == "function" then
        pcall(CI.RequestLoadItemDataByID, itemId)   -- so a later scan has the name
    end
    return {
        slot = SLOT_NAMES[slot] or tostring(slot),
        itemId = itemId,
        quality = quality,
        name = name or link,
    }, "item"
end

-- A live scan of all 19 slots: the items found, and how many slots could not be accounted for.
local function ScanEquipment()
    local items, unknown = {}, 0
    for slot = 1, 19 do
        local ok, item, state = pcall(ReadEquipSlot, slot)
        if ok and item then
            items[#items + 1] = item
        elseif not ok or state ~= "empty" then
            unknown = unknown + 1
        end
    end
    return items, unknown
end

-- `base` with `over` laid on top, slot by slot (`over` wins), in slot order. Older records that
-- stored a numeric slot are normalised to the slot name on the way through.
local function MergeEquipment(base, over)
    local bySlot = {}
    local function put(list)
        if type(list) ~= "table" then return end
        for _, e in ipairs(list) do
            if type(e) == "table" then
                local id = e.slot
                if type(id) == "string" then id = SLOT_IDS[id] end
                if type(id) == "number" and SLOT_NAMES[id] then
                    bySlot[id] = { slot = SLOT_NAMES[id], itemId = e.itemId, quality = e.quality, name = e.name }
                end
            end
        end
    end
    put(base)
    put(over)
    local out = {}
    for id = 1, 19 do
        if bySlot[id] then out[#out + 1] = bySlot[id] end
    end
    return out
end

local function CaptureEquipment(c)
    if not c then return end
    local items, unknown = ScanEquipment()
    liveRead.equip, liveRead.equipUnknown = #items, unknown
    local earlier = sessionEquip or c.equipment
    local earlierCount = type(earlier) == "table" and #earlier or 0
    local trusted = equipReady and not loggingOut and unknown == 0
        and (#items > 0 or earlierCount <= 1)
    if trusted then
        c.equipment = items
    else
        c.equipment = MergeEquipment(earlier, items)
    end
    if not loggingOut then sessionEquip = c.equipment end
end

-- Compact fingerprint of an equipment list, to tell whether it changed since the last stored export.
local function EquipmentSignature(list)
    if type(list) ~= "table" then return "" end
    local parts = {}
    for _, e in ipairs(list) do
        if type(e) == "table" then
            parts[#parts + 1] = tostring(e.slot) .. "=" .. tostring(e.itemId or e.name)
        end
    end
    return table.concat(parts, ";")
end

-- A full live scan of one character record from the current game state. Called both on the
-- capture events and, crucially, at export time - so the export reflects the LIVE current
-- character even when the DB is empty or stale (early Forever builds did not load SavedVariables
-- back - they do from build 70291 - and equipment events may never have fired this session).
local function CaptureInto(c)
    if not c then return end
    safe(CaptureIdentity, c)
    safe(CaptureGuild, c)
    safe(CaptureSpec, c)
    safe(CaptureTalents, c)
    safe(CaptureProfessions, c)
    safe(CaptureEquipment, c)
end

local function CaptureAll()
    CaptureInto(CurrentChar())
end

-- ---------------------------------------------------------------------------
-- Loot capture. The roll machinery is the same shape as GaarLooter's: no event reports other
-- players' choices, roll numbers or the winner, so those are parsed from the LOOT_ROLL_* chat
-- lines, matched to the open roll by item link. Captured independently of GaarLooter.
-- ---------------------------------------------------------------------------
local function Pattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = string.gsub(fmt, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = string.gsub(p, "%%%%s", "(.-)")
    p = string.gsub(p, "%%%%d", "(%%d+)")
    return "^" .. p .. "$"
end

local function Rule(globalName, kind, fields)
    local p = Pattern(_G[globalName])
    if not p then return nil end
    return { pattern = p, kind = kind, fields = fields }
end

local ROLL_RULES = {}
local function AddRollRule(globalName, kind, fields)
    local r = Rule(globalName, kind, fields)
    if r then ROLL_RULES[#ROLL_RULES + 1] = r end
end
AddRollRule("LOOT_ROLL_NEED", "choice", { "player", "item", choice = "need" })
AddRollRule("LOOT_ROLL_GREED", "choice", { "player", "item", choice = "greed" })
AddRollRule("LOOT_ROLL_DISENCHANT", "choice", { "player", "item", choice = "disenchant" })
AddRollRule("LOOT_ROLL_PASSED", "choice", { "player", "item", choice = "pass" })
AddRollRule("LOOT_ROLL_ROLLED_NEED", "rolled", { "player", "roll", "item", choice = "need" })
AddRollRule("LOOT_ROLL_ROLLED_GREED", "rolled", { "player", "roll", "item", choice = "greed" })
AddRollRule("LOOT_ROLL_ROLLED_DE", "rolled", { "player", "roll", "item", choice = "disenchant" })
AddRollRule("LOOT_ROLL_WON", "won", { "player", "item" })
AddRollRule("LOOT_ROLL_YOU_WON", "wonself", { "item" })
AddRollRule("LOOT_ROLL_ALL_PASSED", "allpassed", { "item" })

local LOOT_RULES = {}
local function AddLootRule(globalName, fields)
    local r = Rule(globalName, "loot", fields)
    if r then LOOT_RULES[#LOOT_RULES + 1] = r end
end
-- Longest first: the "multiple" forms also match the single pattern otherwise.
AddLootRule("LOOT_ITEM_SELF_MULTIPLE", { "item", "count", self = true })
AddLootRule("LOOT_ITEM_PUSHED_SELF_MULTIPLE", { "item", "count", self = true })
AddLootRule("LOOT_ITEM_SELF", { "item", self = true })
AddLootRule("LOOT_ITEM_PUSHED_SELF", { "item", self = true })

local function MatchRules(rules, msg)
    for _, r in ipairs(rules) do
        local a, b, c = string.match(msg, r.pattern)
        if a then
            local out = { kind = r.kind, choice = r.fields.choice, selfLoot = r.fields.self }
            local caps = { a, b, c }
            for i, field in ipairs(r.fields) do out[field] = caps[i] end
            return out
        end
    end
end

-- One loot row onto the current character, newest last, capped at DB().maxLoot.
local function AppendLoot(entry)
    local c = CurrentChar()
    if not c then return end
    c.loot[#c.loot + 1] = entry
    local cap = DB().maxLoot or 100
    while #c.loot > cap do table.remove(c.loot, 1) end
end

local pending = {}   -- [itemLink] = roll being filled in
local byRollID = {}  -- [rollID] = itemLink

local function NewRoll(itemLink, rollID)
    return {
        when = time(), itemLink = itemLink, rollID = rollID,
        players = {}, order = {}, started = GetTime and GetTime() or 0,
    }
end

local function Participant(roll, name)
    local p = roll.players[name]
    if not p then
        p = { name = name }
        roll.players[name] = p
        roll.order[#roll.order + 1] = name
    end
    return p
end

-- A completed roll becomes one loot row: the item, who won, and which choice won (need/greed).
local function CommitRoll(roll)
    if roll.committed then return end
    roll.committed = true
    if roll.winner then
        local wp = roll.players[roll.winner]
        local kind = (wp and wp.choice) or "need"
        if kind ~= "need" and kind ~= "greed" then kind = "greed" end
        AppendLoot({
            item = roll.itemLink,
            itemId = tonumber(roll.itemID) or nil,
            quality = tonumber(roll.quality) or nil,
            kind = kind,
            winner = roll.winner,
            when = roll.when,
        })
    end
    pending[roll.itemLink] = nil
    if roll.rollID then byRollID[roll.rollID] = nil end
end

local function HandleRollMessage(msg)
    local m = MatchRules(ROLL_RULES, msg)
    if not m then return end
    local itemLink = m.item
    if not itemLink then return end
    local roll = pending[itemLink]
    if not roll then
        roll = NewRoll(itemLink, nil)
        pending[itemLink] = roll
    end

    if m.kind == "choice" or m.kind == "rolled" then
        local p = Participant(roll, m.player)
        if m.choice then p.choice = m.choice end
        if m.roll then p.roll = tonumber(m.roll) end
    elseif m.kind == "won" then
        roll.winner = m.player
        CommitRoll(roll)
    elseif m.kind == "wonself" then
        roll.winner = (UnitName and UnitName("player")) or ME
        CommitRoll(roll)
    elseif m.kind == "allpassed" then
        roll.winner = nil
        CommitRoll(roll)
    end
end

local function RecordPickup(itemLink)
    if not itemLink then return end
    local itemId, quality
    if GetItemInfoInstant then itemId = safe(GetItemInfoInstant, itemLink) end
    if GetItemInfo then local _, _, q = safe(GetItemInfo, itemLink); quality = q end
    AppendLoot({
        item = itemLink,
        itemId = tonumber(itemId) or nil,
        quality = tonumber(quality) or nil,
        kind = "pickup",
        winner = ME,
        when = time(),
    })
end

-- ---------------------------------------------------------------------------
-- Events. Capture is refreshed on the events that can change each captured field; every
-- handler body is guarded so one bad call cannot break the frame.
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
local EVENTS = {
    "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD",
    "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP",
    "SKILL_LINES_CHANGED", "CHARACTER_POINTS_CHANGED",
    "PLAYER_GUILD_UPDATE",
    "START_LOOT_ROLL", "CANCEL_LOOT_ROLL",
    "CHAT_MSG_LOOT", "CHAT_MSG_SYSTEM",
}
for _, e in ipairs(EVENTS) do pcall(ev.RegisterEvent, ev, e) end

ev:SetScript("OnEvent", function(_, event, a1)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        pcall(CaptureAll)
        return
    end
    if event == "PLAYER_EQUIPMENT_CHANGED" then
        pcall(function() CaptureEquipment(CurrentChar()) end)
        return
    end
    if event == "PLAYER_LEVEL_UP" then
        pcall(CaptureAll)
        return
    end
    if event == "SKILL_LINES_CHANGED" then
        pcall(function() CaptureProfessions(CurrentChar()) end)
        return
    end
    if event == "CHARACTER_POINTS_CHANGED" then
        pcall(function()
            local c = CurrentChar()
            CaptureSpec(c)
            CaptureTalents(c)
        end)
        return
    end
    if event == "PLAYER_GUILD_UPDATE" then
        pcall(function() CaptureGuild(CurrentChar()) end)
        return
    end
    if event == "START_LOOT_ROLL" then
        local rollID = a1
        local link = GetLootRollItemLink and safe(GetLootRollItemLink, rollID)
        if not link then return end
        local roll = pending[link] or NewRoll(link, rollID)
        roll.rollID = rollID
        if GetLootRollItemInfo then
            local _, _, _, quality = safe(GetLootRollItemInfo, rollID)
            roll.quality = quality
        end
        if GetItemInfoInstant then roll.itemID = safe(GetItemInfoInstant, link) end
        pending[link] = roll
        byRollID[rollID] = link
        return
    end
    if event == "CANCEL_LOOT_ROLL" then
        return -- left pending; the sweeper commits it if no result line arrives
    end
    if event == "CHAT_MSG_LOOT" or event == "CHAT_MSG_SYSTEM" then
        local msg = a1
        pcall(HandleRollMessage, msg)
        if event == "CHAT_MSG_LOOT" then
            local m = MatchRules(LOOT_RULES, msg)
            if m and m.selfLoot and m.item then pcall(RecordPickup, m.item) end
        end
        return
    end
end)

-- A roll whose result line never arrived would sit in `pending` forever, so anything older than
-- two minutes is written out with whatever was captured. Same guard GaarLooter uses.
local sweeper = CreateFrame("Frame")
local sweepAcc = 0
sweeper:SetScript("OnUpdate", function(_, elapsed)
    sweepAcc = sweepAcc + elapsed
    if sweepAcc < 5 then return end
    sweepAcc = 0
    local now = GetTime and GetTime() or 0
    for _, roll in pairs(pending) do
        if now - (roll.started or now) > 120 then pcall(CommitRoll, roll) end
    end
end)

-- ---------------------------------------------------------------------------
-- The export string
-- ---------------------------------------------------------------------------
-- Project a stored record onto the exact `chars` object the website expects. Only canonical
-- field names are emitted; older records written by a previous version (numeric slot, `class`,
-- `level`, profession `rank`) are migrated on the way out so a mixed DB still exports cleanly.
local function CanonicalChar(c)
    local out = {
        name = c.name,
        realm = c.realm,
        race = c.race,
        cls = c.cls or c.class,          -- canonical class (localized)
        lvl = c.lvl or c.level,          -- canonical level (number)
        xp = c.xp,                       -- XP within the level (optional; absent when unknown)
        xpMax = c.xpMax,                 -- XP the level needs (optional; absent when unknown)
        xpRested = c.xp and (c.xpRested or 0) or nil,   -- rested pool; only ever with xp/xpMax
        spec = c.spec,
        guild = c.guild,
        guildRank = c.guildRank,
        faction = c.faction,             -- harmless extra; website derives faction from race too
        classFile = c.classFile,         -- kept alongside `cls`
        professions = {},
        talents = {},                    -- the full talent build (tabs -> talents); see docs
        equipment = {},
        loot = {},
    }
    -- Full talent build, re-projected so the website always sees the canonical shape even for a
    -- record captured by an older version (which had no `talents`).
    if type(c.talents) == "table" then
        for _, tabRec in ipairs(c.talents) do
            if type(tabRec) == "table" then
                local tabOut = {
                    tab = tabRec.tab,
                    points = tonumber(tabRec.points) or 0,
                    talents = {},
                    edges = {},               -- prerequisite connector arrows in grid coords
                }
                if type(tabRec.talents) == "table" then
                    for _, t in ipairs(tabRec.talents) do
                        local nodeOut = {
                            name = t.name,
                            rank = tonumber(t.rank) or 0,
                            max = tonumber(t.max) or 0,
                            tier = tonumber(t.tier) or 0,
                            col = tonumber(t.col) or 0,
                        }
                        -- icon/spellId are additive: the Forever calculator scan resolves them, the
                        -- Era classic route does not. Carried through only when present so the website
                        -- gets the full node (icon + Wowhead-keyable spellId) and an older/Era record
                        -- still exports cleanly.
                        if t.icon ~= nil then nodeOut.icon = t.icon end
                        if t.spellId ~= nil then nodeOut.spellId = t.spellId end
                        tabOut.talents[#tabOut.talents + 1] = nodeOut
                    end
                end
                -- Edges are additive: carried through only when present, projected to the canonical
                -- {ft,fc,tt,tc} shape so an older record without edges still exports cleanly.
                if type(tabRec.edges) == "table" then
                    for _, e in ipairs(tabRec.edges) do
                        tabOut.edges[#tabOut.edges + 1] = {
                            ft = tonumber(e.ft) or 0,
                            fc = tonumber(e.fc) or 0,
                            tt = tonumber(e.tt) or 0,
                            tc = tonumber(e.tc) or 0,
                        }
                    end
                end
                out.talents[#out.talents + 1] = tabOut
            end
        end
    end
    if type(c.professions) == "table" then
        for _, p in ipairs(c.professions) do
            out.professions[#out.professions + 1] = {
                name = p.name,
                skill = tonumber(p.skill or p.rank) or 0,
                max = tonumber(p.max) or 0,
            }
        end
    end
    if type(c.equipment) == "table" then
        for _, e in ipairs(c.equipment) do
            local slot = e.slot
            if type(slot) == "number" then slot = SLOT_NAMES[slot] or tostring(slot) end
            out.equipment[#out.equipment + 1] = {
                slot = slot,
                name = e.name,
                itemId = e.itemId,
                quality = e.quality,
            }
        end
    end
    if type(c.loot) == "table" then
        for _, l in ipairs(c.loot) do out.loot[#out.loot + 1] = l end
    end
    return out
end

-- Identity-only projection for the lightweight "sync all" export. Just the fields that identify a
-- character in the account pool - no professions/equipment/loot/talents - so a whole account fits in
-- one short, copy-safe string. Realm is kept because the website keys characters by Name-Realm.
local function MinimalChar(c)
    return {
        name = c.name,
        realm = c.realm,
        race = c.race,
        cls = c.cls or c.class,          -- canonical class (localized)
        classFile = c.classFile,         -- locale-independent class token
        faction = c.faction,
        lvl = c.lvl or c.level,          -- canonical level (number)
        xp = c.xp,                       -- XP within the level (optional)
        xpMax = c.xpMax,                 -- XP the level needs (optional)
        xpRested = c.xp and (c.xpRested or 0) or nil,   -- rested pool; only ever with xp/xpMax
        spec = c.spec,
    }
end

-- PRIMARY export: ONLY the current/logged-in character, fully scanned. This is the reliable flow -
-- one character makes a short string that survives the copy out of the in-game EditBox, unlike the
-- whole-account dump which truncated and lost talents/tail characters.
--
-- Fresh full scan right now, before building the string. The stored record may be stale and
-- equipment events may not have fired, so we never trust cached data for the live character - we
-- re-read name/level/class/guild/spec/professions and loop the equip slots live here. (This began on
-- early Forever builds, which did not load SavedVariables back; from build 70291 they persist, but
-- the live scan is still the right source for the character being exported.)
local function BuildExportStringCurrent()
    safe(CaptureAll)
    local chars = {}
    local c = CurrentChar()
    if c then chars[1] = CanonicalChar(c) end
    local payload = { k = "chars", chars = chars }
    return PREFIX .. Base64Encode(JsonEncode(payload))
end

-- LIGHTWEIGHT bulk export: every character the addon has stored across logins, IDENTITY FIELDS ONLY.
-- A skeleton that populates the account pool on the website; the per-character full export fills in
-- the heavy data one character at a time. Same VGD1 "chars" contract, just minimal elements.
local function BuildExportStringAll()
    safe(CaptureAll)   -- refresh the current character so its identity row is up to date in the pool
    local liveName = FullPlayerName()   -- live full "First Last" for the logged-in character
    local chars = {}
    for key, c in pairs(DB().chars) do
        local m = MinimalChar(c)
        -- The logged-in character always exports under its live full name, even if an older stored
        -- record still holds a short first-name-only value.
        if key == CHARKEY and liveName then m.name = liveName end
        chars[#chars + 1] = m
    end
    local payload = { k = "chars", chars = chars }
    return PREFIX .. Base64Encode(JsonEncode(payload))
end

-- ---------------------------------------------------------------------------
-- Stored exports for the desktop companion app ("Vanguard Sync")
--
-- The desktop app cannot talk to the game; all it can do is read our SavedVariables file from disk
-- (WTF/Account/<ACCOUNT>/SavedVariables/GaarVanguard.lua) and upload what it finds. So the addon keeps
-- each character's ready-made export string in GaarVanguardDB.exports, keyed exactly like
-- GaarVanguardDB.chars ("Full Name-Realm"):
--
--   exports["Full Name-Realm"] = {
--       v = 1,                    -- version of THIS record's shape (not of the VGD1 payload)
--       export = "VGD1:...",      -- byte-identical to /gaarvanguard export at that moment
--       updatedAt = <time()>,     -- Unix seconds when the string was built
--       build = "1.60.1.70291",   -- GetBuildInfo() version .. "." .. build, when available
--       project = 18,             -- WOW_PROJECT_ID, when the client defines it
--   }
--
-- The string always comes from BuildExportStringCurrent(), the same function behind the Export box
-- and the minimap copy box, so the app uploads exactly what a player would otherwise paste. Entries
-- are written on PLAYER_LOGOUT (which fires before SavedVariables are saved on logout, /reload and
-- client exit), whenever the player copies the export, after a manual recapture, and a few seconds
-- after login, a level-up or a change of talents, equipment or professions (ScheduleStore, below). One entry
-- per character, overwritten each time; entries for characters no longer in
-- `chars` are dropped, so the table never grows past the characters the addon knows about. The legacy
-- `sync` key is unrelated and left alone. Contract: docs/gaarvanguard.md.
--
-- GaarVanguardDB.autoSync (account-wide boolean, default true) switches all of this off: while it is
-- false nothing is written or refreshed, existing entries are kept as they are, and the desktop app
-- reads the same flag and skips uploading. Toggled from the minimap menu, the options panel and
-- /gaarvanguard sync on|off.
-- ---------------------------------------------------------------------------
local EXPORT_RECORD_VERSION = 1

-- Whether stored exports are kept up to date. Only called from events and user actions, i.e. after
-- SavedVariables have loaded; a missing or non-boolean value means on (and is written back as true
-- so the desktop app sees an explicit flag).
local function AutoSyncEnabled()
    local d = DB()
    if type(d.autoSync) ~= "boolean" then d.autoSync = true end
    return d.autoSync
end

-- "version.build" from GetBuildInfo(), e.g. "1.60.1.70291"; nil when the client does not answer.
local function ClientBuild()
    if type(GetBuildInfo) ~= "function" then return nil end
    local ok, version, build = pcall(GetBuildInfo)
    if not ok or version == nil then return nil end
    if build ~= nil and tostring(build) ~= "" then return tostring(version) .. "." .. tostring(build) end
    return tostring(version)
end

-- Store `str` as the current character's export. Returns the entry, or nil when there is nothing to
-- store or no character to attribute it to. Callers wrap this in pcall.
local function StoreExport(str)
    if type(str) ~= "string" or str == "" then return nil end
    -- Auto-sync off: leave exports exactly as they are (no write, no pruning).
    if not AutoSyncEnabled() then return nil end
    if not CHARKEY then Identify() end
    if not CHARKEY then return nil end
    local d = DB()
    if type(d.exports) ~= "table" then d.exports = {} end
    -- Keep only characters the addon knows about: drop entries whose character record is gone (or
    -- that are not entries at all). The current character always has a record by now, because the
    -- export string was built from CurrentChar().
    for key, entry in pairs(d.exports) do
        if type(entry) ~= "table" or (key ~= CHARKEY and d.chars[key] == nil) then
            d.exports[key] = nil
        end
    end
    local entry = {
        v = EXPORT_RECORD_VERSION,
        export = str,
        updatedAt = type(time) == "function" and time() or nil,
        build = ClientBuild(),
        project = tonumber(_G.WOW_PROJECT_ID),
    }
    d.exports[CHARKEY] = entry
    return entry
end

-- Compact fingerprint of a talent build: every tree's name and points, and every talent's rank.
local function TalentSignature(build)
    if type(build) ~= "table" then return "" end
    local parts = {}
    for _, t in ipairs(build) do
        if type(t) == "table" then
            local ranks = {}
            if type(t.talents) == "table" then
                for _, n in ipairs(t.talents) do
                    if type(n) == "table" then ranks[#ranks + 1] = tostring(n.rank or 0) end
                end
            end
            parts[#parts + 1] = tostring(t.tab) .. ":" .. tostring(t.points) .. ":" .. table.concat(ranks, ",")
        end
    end
    return table.concat(parts, ";")
end

-- What the stored export's content hinges on besides loot: level and XP (with rested XP), talents (and the spec they
-- give), equipment and professions. Compared against the value at the last store so an event that
-- changed none of them does not rebuild the export.
local function StoredSignature()
    local c = CurrentChar()
    if not c then return nil end
    local profs = {}
    if type(c.professions) == "table" then
        for _, p in ipairs(c.professions) do
            if type(p) == "table" then
                profs[#profs + 1] = tostring(p.name) .. ":" .. tostring(p.skill) .. "/" .. tostring(p.max)
            end
        end
    end
    return tostring(c.lvl) .. "|" .. tostring(c.xp) .. "/" .. tostring(c.xpMax) .. "+" ..
        tostring(c.xpRested) .. "|" ..
        tostring(c.spec) .. "|" .. TalentSignature(c.talents) .. "|" ..
        EquipmentSignature(c.equipment) .. "|" .. table.concat(profs, ";")
end
local lastStoredSig   -- StoredSignature() right after the last successful store this session

-- Build the current character's export (a fresh live scan, as /gaarvanguard export does) and store
-- it. The string is returned even when storing fails, so a caller that shows it is never affected.
local function ExportAndStore()
    local str = BuildExportStringCurrent()
    local ok, entry = pcall(StoreExport, str)
    if ok and entry then lastStoredSig = StoredSignature() end
    return str
end

-- Debounced refresh of the stored export while playing, so `exports` is already right before logout
-- rather than depending on the logout-time scan alone. Every call restarts the countdown (C_Timer
-- cannot cancel, so a generation number retires the older timers); when it runs out level, talents
-- and equipment are re-read and the export is rebuilt and stored - unless nothing it depends on
-- changed since the last store (`force` skips that check). Never in combat: it waits and tries again.
-- Off while auto-sync is off.
local STORE_DEBOUNCE = 3       -- seconds after the last change
local EQUIP_SETTLE = 3         -- seconds after PLAYER_ENTERING_WORLD before equipment is trusted
local POLL_INTERVAL = 30       -- seconds between the in-play level/talent checks (see StartPoll)
local storeGen, storeForced = 0, false
-- Set by a level-up until UnitLevel has caught up: { from = the level before it, retried = bool }.
local levelCheck
local ScheduleStore
ScheduleStore = function(force)
    if not AutoSyncEnabled() then return end
    if force then storeForced = true end
    storeGen = storeGen + 1
    local gen = storeGen
    local function fire()
        if gen ~= storeGen then return end   -- a later change restarted the countdown
        pcall(function()
            if not AutoSyncEnabled() then return end   -- may have been turned off meanwhile
            if loggingOut then return end              -- PLAYER_LOGOUT has stored the final entry
            if pcall1(_G.InCombatLockdown) then ScheduleStore() return end
            if not storeForced then
                -- Professions and guild have their own capture events; these can change silently.
                local c = CurrentChar()
                safe(CaptureIdentity, c)
                safe(CaptureSpec, c)
                safe(CaptureTalents, c)
                safe(CaptureEquipment, c)
                if StoredSignature() == lastStoredSig then return end
            end
            storeForced = false
            ExportAndStore()
            -- UnitLevel can still report the old level a few seconds after PLAYER_LEVEL_UP. The level
            -- the event announced is already in the export; read once more later so everything that
            -- comes with the new level (talent points, max skill) is stored as well.
            if levelCheck then
                local live = ReadLiveLevel()
                if levelCheck.retried or not levelCheck.from or (live and live > levelCheck.from) then
                    levelCheck = nil
                else
                    levelCheck.retried = true
                    ScheduleStore(true)
                end
            end
        end)
    end
    if not After(STORE_DEBOUNCE, fire) then fire() end
end

-- Points spent in the talent trees, read as cheaply as the client allows (no names or icons): the
-- classic tab totals on Era, the purchased ranks of the trait graph on Forever / retail. nil when
-- neither can be read.
local function QuickTalentPoints()
    if type(_G.GetNumTalentTabs) == "function" and type(_G.GetTalentTabInfo) == "function" then
        local tabs = tonumber(safe(_G.GetNumTalentTabs)) or 0
        if tabs > 0 then
            local n = 0
            for i = 1, tabs do
                local _, _, pts = safe(_G.GetTalentTabInfo, i)
                n = n + (tonumber(pts) or 0)
            end
            return n
        end
    end
    local CCT, CT = _G.C_ClassTalents, _G.C_Traits
    if type(CCT) ~= "table" or type(CT) ~= "table" or type(CCT.GetActiveConfigID) ~= "function"
       or type(CT.GetConfigInfo) ~= "function" or type(CT.GetTreeNodes) ~= "function"
       or type(CT.GetNodeInfo) ~= "function" then
        return nil
    end
    local configID = safe(CCT.GetActiveConfigID)
    if type(configID) ~= "number" then return nil end
    local cfg = safe(CT.GetConfigInfo, configID)
    if type(cfg) ~= "table" or type(cfg.treeIDs) ~= "table" then return nil end
    local n = 0
    for _, treeID in ipairs(cfg.treeIDs) do
        local nodes = safe(CT.GetTreeNodes, treeID)
        if type(nodes) == "table" then
            for _, nodeID in ipairs(nodes) do
                local ni = safe(CT.GetNodeInfo, configID, nodeID)
                if type(ni) == "table" then
                    n = n + (tonumber(ni.ranksPurchased) or tonumber(ni.activeRank) or 0)
                end
            end
        end
    end
    return n
end

-- A safety net under the events: which talent events a client fires is not known for every build
-- (Forever has the retail trait system but Vanilla talents), so every POLL_INTERVAL seconds the level
-- and the points spent are read cheaply, and a change schedules the debounced store. Started once,
-- after the first loading screen; skipped while auto-sync is off or the client is logging out.
local pollStarted, pollLast = false, nil
local function PollTick()
    if loggingOut or not AutoSyncEnabled() then return end
    local now = tostring(ReadLiveLevel()) .. "/" .. tostring(QuickTalentPoints())
    if pollLast and now ~= pollLast then ScheduleStore() end
    pollLast = now
end
local function StartPoll()
    if pollStarted then return end
    pollStarted = true
    pcall(PollTick)
    local CT = _G.C_Timer
    if type(CT) == "table" and type(CT.NewTicker) == "function" then
        pcall(CT.NewTicker, POLL_INTERVAL, function() pcall(PollTick) end)
    else
        local function again()
            pcall(PollTick)
            After(POLL_INTERVAL, again)
        end
        After(POLL_INTERVAL, again)
    end
end

-- PLAYER_LOGOUT is the last event before the client writes SavedVariables to disk, on logout,
-- /reload and exit alike, so the entry stored here is what the desktop app reads. `loggingOut` makes
-- the capture treat its live reads as a top-up of what was read while playing (see `inPlay` above;
-- on exit the client may already hand back the state from login, or nothing). What the client could
-- still read and what was used is kept in GaarVanguardDB.lastLogoutDiag. Everything is inside pcall:
-- a failure here must never get in the way of logging out. With auto-sync off it returns before any
-- scan, so it costs nothing.
-- The other events keep the stored entry current during the session (see ScheduleStore):
--   PLAYER_ENTERING_WORLD    after EQUIP_SETTLE seconds the inventory counts as loaded: equipment is
--                            re-read and the export stored if anything differs from the last store
--   PLAYER_EQUIPMENT_CHANGED, UNIT_INVENTORY_CHANGED ("player"), SKILL_LINES_CHANGED, UNIT_LEVEL
--   ("player"), PLAYER_XP_UPDATE ("player"), UPDATE_EXHAUSTION, PLAYER_UPDATE_RESTING, and the talent
--   events TRAIT_CONFIG_UPDATED,
--   TRAIT_TREE_CHANGED, PLAYER_TALENT_UPDATE, CHARACTER_POINTS_CHANGED, ACTIVE_COMBAT_CONFIG_CHANGED
--                            re-checked a few seconds after the last one, stored only on a change.
--                            PLAYER_XP_UPDATE fires on every kill or quest turn-in; it and the two
--                            rested events only read the XP (and rested pool) into `inPlay` at once, and the debounce folds a run of them into one
--                            store a few seconds after the last (never in combat)
--   PLAYER_LEVEL_UP, PLAYER_LEVEL_CHANGED
--                            always stored a few seconds later, with the level the event announces
--                            (UnitLevel can still report the old one), and re-read once more if
--                            UnitLevel had not caught up yet
-- Events a client does not know are skipped (RegisterEvent errors on them, inside pcall).
local syncEv = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "PLAYER_LEVEL_CHANGED",
                     "UNIT_LEVEL", "PLAYER_EQUIPMENT_CHANGED", "UNIT_INVENTORY_CHANGED",
                     "SKILL_LINES_CHANGED", "TRAIT_CONFIG_UPDATED", "TRAIT_TREE_CHANGED",
                     "PLAYER_TALENT_UPDATE", "CHARACTER_POINTS_CHANGED",
                     "ACTIVE_COMBAT_CONFIG_CHANGED", "PLAYER_XP_UPDATE",
                     "UPDATE_EXHAUSTION", "PLAYER_UPDATE_RESTING" }) do
    pcall(syncEv.RegisterEvent, syncEv, e)
end
syncEv:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "PLAYER_LOGOUT" then
        pcall(function()
            if not AutoSyncEnabled() then return end
            loggingOut = true
            ExportAndStore()
            local c = CurrentChar()
            DB().lastLogoutDiag = {
                when = type(time) == "function" and time() or nil,
                build = ClientBuild(),
                levelLive = liveRead.lvl,
                levelInPlay = inPlay.lvl,
                levelUsed = c and c.lvl,
                xpLive = liveRead.xp,
                xpInPlay = inPlay.xp,
                xpUsed = c and c.xp,
                xpRestedLive = liveRead.xpRested,
                xpRestedInPlay = inPlay.xpRested,
                xpRestedUsed = c and c.xpRested,
                talentsLive = liveRead.talentPts,
                talentsInPlay = inPlay.talentPts,
                talentsUsed = c and TalentPoints(c.talents),
                equipLive = liveRead.equip,
                equipUnknown = liveRead.equipUnknown,
                equipUsed = c and type(c.equipment) == "table" and #c.equipment or nil,
                profsLive = liveRead.profs,
                profsUsed = c and type(c.professions) == "table" and #c.professions or nil,
            }
        end)
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        pcall(function()
            local function settle()
                equipReady = true
                pcall(CaptureEquipment, CurrentChar())
                ScheduleStore()
                StartPoll()
            end
            if not After(EQUIP_SETTLE, settle) then settle() end
        end)
        return
    end
    if (event == "UNIT_INVENTORY_CHANGED" or event == "UNIT_LEVEL") and a1 ~= "player" then return end
    if event == "PLAYER_XP_UPDATE" then
        -- PLAYER_XP_UPDATE(unitTarget); a client that sends no unit is taken to mean the player.
        if a1 ~= nil and a1 ~= "player" then return end
        pcall(UpdateInPlayXP)
    end
    -- The rested pool changes without an XP change (resting in an inn or city, logging in rested).
    if event == "UPDATE_EXHAUSTION" or event == "PLAYER_UPDATE_RESTING" then pcall(UpdateInPlayXP) end
    if event == "PLAYER_LEVEL_UP" or event == "PLAYER_LEVEL_CHANGED" then
        pcall(function()
            -- PLAYER_LEVEL_UP(newLevel, ...); PLAYER_LEVEL_CHANGED(oldLevel, newLevel, ...).
            local announced = event == "PLAYER_LEVEL_UP" and a1 or a2
            if IsSecret(announced) then announced = nil end
            announced = tonumber(announced)
            local before = inPlay.lvl or ReadLiveLevel()
            -- A level-up is one level (two at most if events bunch up); anything else is not trusted.
            if announced and announced > (inPlay.lvl or 0) and (not before or announced <= before + 2) then
                inPlay.lvl = announced
            end
            -- PLAYER_LEVEL_UP and PLAYER_LEVEL_CHANGED both fire on retail; the first one sets this.
            if not levelCheck then levelCheck = { from = before, retried = false } end
            ScheduleStore(true)
        end)
        return
    end
    pcall(ScheduleStore)
end)

-- ---------------------------------------------------------------------------
-- A reusable read-out box for copying an export string out, modelled on GaarLooter's export frame.
-- ---------------------------------------------------------------------------
local function MakeBox(name, title)
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(560, 380); f:SetPoint("CENTER")
    f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
    f:SetBackdropColor(0.05, 0.06, 0.08, 0.97)
    f:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    table.insert(UISpecialFrames, name)

    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOPLEFT", 12, -12); t:SetText(title)

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(60, 20); close:SetPoint("TOPRIGHT", -12, -10); close:SetText("Close")
    close:SetScript("OnClick", function() f:Hide() end)

    local scroll = CreateFrame("ScrollFrame", name .. "Scroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -38); scroll:SetPoint("BOTTOMRIGHT", -32, 12)

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true); box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetWidth(500)
    box:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(box)
    f.box = box

    f:Hide()
    return f
end

-- ---------------------------------------------------------------------------
-- Export box
-- ---------------------------------------------------------------------------
local exportFrame
local function ShowExport()
    if not exportFrame then
        exportFrame = MakeBox("GaarVanguardExport",
            "Export this character — ctrl-A, ctrl-C, paste into the website")
    end
    -- The same string the box shows is stored for the desktop app (GaarVanguardDB.exports).
    exportFrame.box:SetText(ExportAndStore())
    exportFrame.box:HighlightText()
    exportFrame:Show()
    exportFrame.box:SetFocus()
end
_G.GaarVanguard_ShowExport = ShowExport

-- The lightweight "sync all" box: every stored character, identity fields only.
local exportAllFrame
local function ShowExportAll()
    if not exportAllFrame then
        exportAllFrame = MakeBox("GaarVanguardExportAll",
            "Sync all characters (identity only) — ctrl-A, ctrl-C, paste into the website")
    end
    exportAllFrame.box:SetText(BuildExportStringAll())
    exportAllFrame.box:HighlightText()
    exportAllFrame:Show()
    exportAllFrame.box:SetFocus()
end
_G.GaarVanguard_ShowExportAll = ShowExportAll

-- ---------------------------------------------------------------------------
-- The in-game sync view (read-only). Renders GaarVanguardDB.sync (legacy data from
-- the removed import box) when present - as a proper movable,
-- closable, scrollable window so a player sees, in game, what their Vanguard is
-- aiming for: their Vanguard(s), the goals + status + linked instance, an
-- instance / readiness summary, and which of their characters each goal applies
-- to. Everything is guarded so a missing or reshaped field renders blank rather
-- than erroring; nothing here writes game or addon state.
--
-- The sync shape is the website's encodeSync() (Vanguard/src/lib/protocol.ts,
-- mirrored in docs/gaarvanguard.md). Field names are the short ones the site
-- emits, not the longhand of the first-draft stub:
--   { k = "sync",
--     vanguards = { { name, tag, faction, type }, ... },
--     goals     = { { vg, t, i, s }, ... },   -- vg=Vanguard tag, t=title, i=instance code, s=Waiting/Ready/Done
--     members   = { { vg, name, ready, total }, ... },   -- per-member readiness summary
--     mapping   = { { char, vanguard, goals = { title, ... } }, ... } }  -- the player's own chars
-- Older/looser producers may use { title, status, instanceCode } - those are
-- accepted as fallbacks so a hand-made string still renders.
-- ---------------------------------------------------------------------------
local STATUS_COLORS = {
    Waiting = { 1.00, 0.82, 0.00 },
    Ready   = { 0.30, 1.00, 0.40 },
    Done    = { 0.55, 0.70, 1.00 },
}
local MUTE = { 0.62, 0.62, 0.66 }
local HEADCOL = { 0.55, 0.85, 1.00 }
local WHITECOL = { 1.00, 1.00, 1.00 }
local GOCOL = { 0.30, 1.00, 0.40 }

local function StatusColor(s)
    return STATUS_COLORS[tostring(s)] or MUTE
end

-- table.concat but tolerant: every element is stringified first, so a stray
-- non-string in a decoded list can never raise.
local function JoinTostring(list, sep)
    local out = {}
    if type(list) == "table" then
        for _, v in ipairs(list) do out[#out + 1] = tostring(v) end
    end
    return table.concat(out, sep)
end

local viewFrame
local viewPool = {}

-- Acquire (or reuse) the next pooled fontstring on the scroll child, set its
-- text / colour / font, place it at the running y offset, and advance y past it.
-- `big` picks the section-head font; otherwise a small body font. Wrapping is on,
-- so long text grows the line height and the layout stays correct.
local function ViewLine(content, state, text, color, indent, big)
    state.i = state.i + 1
    local fs = viewPool[state.i]
    if not fs then
        fs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        viewPool[state.i] = fs
    end
    fs:SetFontObject(big and "GameFontNormal" or "GameFontHighlightSmall")
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", indent or 8, state.y)
    fs:SetWidth(math.max(40, (state.width or 480) - (indent or 8) - 8))
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    local c = color or MUTE
    fs:SetTextColor(c[1], c[2], c[3])
    fs:Show()
    local h = fs:GetStringHeight()
    if not h or h < 1 then h = 12 end
    state.y = state.y - h - (big and 8 or 4)
end

-- Rebuild the whole view from GaarVanguardDB.sync. Cheap enough (a handful of
-- Vanguards/goals) to redo wholesale on every show / resize.
local function RenderView()
    if not viewFrame then return end
    local content = viewFrame.content
    local w = viewFrame.scroll and viewFrame.scroll:GetWidth() or 0
    if not w or w < 50 then w = 500 end
    local state = { i = 0, y = -8, width = w }
    content:SetWidth(w)

    local sync = DB().sync

    -- Empty state: no usable sync yet.
    if type(sync) ~= "table" or sync.k ~= "sync" then
        ViewLine(content, state, "Vanguard is on the website.", HEADCOL, 8, true)
        ViewLine(content, state,
            "This addon is export-only. Use \"Export this char\" or \"Sync all (identity)\" " ..
            "(/gaarvanguard export or exportall), copy the VGD1 code, and paste it into the " ..
            "Vanguard website. View and manage your Vanguards, goals and readiness there.", MUTE, 8, false)
        for j = state.i + 1, #viewPool do if viewPool[j] then viewPool[j]:Hide() end end
        content:SetHeight(math.max(1, -state.y + 8))
        return
    end

    local vanguards = type(sync.vanguards) == "table" and sync.vanguards or {}
    local goals     = type(sync.goals) == "table" and sync.goals or {}
    local members   = type(sync.members) == "table" and sync.members or {}
    local mapping   = type(sync.mapping) == "table" and sync.mapping or {}

    -- 1. Your Vanguards.
    ViewLine(content, state, "Your Vanguards", HEADCOL, 8, true)
    if #vanguards == 0 then
        ViewLine(content, state, "None in this sync.", MUTE, 16, false)
    else
        for _, v in ipairs(vanguards) do
            if type(v) == "table" then
                local tag = (v.tag and v.tag ~= "") and (" [" .. tostring(v.tag) .. "]") or ""
                ViewLine(content, state, tostring(v.name or "?") .. tag, WHITECOL, 16, false)
                local bits = {}
                if v.faction and v.faction ~= "" then bits[#bits + 1] = tostring(v.faction) end
                if v.type and v.type ~= "" then bits[#bits + 1] = tostring(v.type) end
                if #bits > 0 then ViewLine(content, state, JoinTostring(bits, " \194\183 "), MUTE, 26, false) end
            end
        end
    end
    state.y = state.y - 6

    -- 2. Goals: title, status (coloured), linked instance, owning Vanguard, and
    -- which of my characters the goal applies to (from the mapping).
    ViewLine(content, state, "Goals", HEADCOL, 8, true)
    if #goals == 0 then
        ViewLine(content, state, "None in this sync.", MUTE, 16, false)
    else
        for _, g in ipairs(goals) do
            if type(g) == "table" then
                local title = tostring(g.t or g.title or "?")
                ViewLine(content, state, title, WHITECOL, 16, false)
                ViewLine(content, state, "Status: " .. tostring(g.s or g.status or "?"), StatusColor(g.s or g.status), 26, false)
                local inst = g.i or g.instanceCode
                if inst and inst ~= "" then
                    ViewLine(content, state, "Instance: " .. tostring(inst), MUTE, 26, false)
                end
                if g.vg and g.vg ~= "" then
                    ViewLine(content, state, "Vanguard: " .. tostring(g.vg), MUTE, 26, false)
                end
                local who = {}
                for _, m in ipairs(mapping) do
                    if type(m) == "table" and type(m.goals) == "table" then
                        for _, gt in ipairs(m.goals) do
                            if tostring(gt) == title then who[#who + 1] = tostring(m.char or "?"); break end
                        end
                    end
                end
                if #who > 0 then
                    ViewLine(content, state, "Your characters: " .. JoinTostring(who, ", "), { 0.70, 0.88, 0.70 }, 26, false)
                end
            end
        end
    end
    state.y = state.y - 6

    -- 3. Instances / readiness. The sync carries no per-instance GO flag, only a
    -- per-member ready/total summary, so we list the instances the goals track and
    -- then each member's readiness, highlighting a member who is GO (fully ready).
    ViewLine(content, state, "Instances / readiness", HEADCOL, 8, true)
    local seen, insts = {}, {}
    for _, g in ipairs(goals) do
        if type(g) == "table" then
            local inst = g.i or g.instanceCode
            if inst and inst ~= "" and not seen[inst] then seen[inst] = true; insts[#insts + 1] = tostring(inst) end
        end
    end
    if #insts > 0 then
        ViewLine(content, state, "Tracked instances: " .. JoinTostring(insts, ", "), MUTE, 16, false)
    end
    if #members == 0 then
        ViewLine(content, state, "No readiness summary in this sync.", MUTE, 16, false)
    else
        for _, m in ipairs(members) do
            if type(m) == "table" then
                local ready = tonumber(m.ready) or 0
                local total = tonumber(m.total) or 0
                local go = total > 0 and ready >= total
                ViewLine(content, state,
                    string.format("%s \226\128\148 %d/%d ready%s", tostring(m.name or "?"), ready, total, go and "   GO" or ""),
                    go and GOCOL or { 0.85, 0.85, 0.85 }, 16, false)
            end
        end
    end
    state.y = state.y - 6

    -- 4. Mapping: each of my characters, its Vanguard and the goals that apply.
    ViewLine(content, state, "My characters", HEADCOL, 8, true)
    if #mapping == 0 then
        ViewLine(content, state, "No character mapping in this sync.", MUTE, 16, false)
    else
        for _, m in ipairs(mapping) do
            if type(m) == "table" then
                ViewLine(content, state, tostring(m.char or "?"), WHITECOL, 16, false)
                ViewLine(content, state, "Vanguard: " .. tostring(m.vanguard or "\226\128\148"), MUTE, 26, false)
                local gl = (type(m.goals) == "table" and #m.goals > 0) and JoinTostring(m.goals, ", ") or "\226\128\148"
                ViewLine(content, state, "Goals: " .. gl, MUTE, 26, false)
            end
        end
    end

    for j = state.i + 1, #viewPool do if viewPool[j] then viewPool[j]:Hide() end end
    content:SetHeight(math.max(1, -state.y + 8))
end

local function BuildView()
    if viewFrame then return viewFrame end
    local f = CreateFrame("Frame", "GaarVanguardView", UIParent, "BackdropTemplate")
    f:SetSize(560, 460); f:SetPoint("CENTER")
    f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    f:SetBackdropColor(0.05, 0.06, 0.08, 0.96)
    f:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    table.insert(UISpecialFrames, "GaarVanguardView")

    local titleBar = f:CreateTexture(nil, "BACKGROUND")
    titleBar:SetPoint("TOPLEFT", 1, -1); titleBar:SetPoint("TOPRIGHT", -1, -1); titleBar:SetHeight(26)
    if titleBar.SetColorTexture then titleBar:SetColorTexture(1, 1, 1, 1) else titleBar:SetTexture(1, 1, 1, 1) end
    titleBar:SetVertexColor(0.11, 0.12, 0.15, 1)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -8); title:SetText("Gaar Vanguard")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetSize(26, 26); closeBtn:SetPoint("TOPRIGHT", -4, -4)

    -- Toolbar: quick access to the export box without leaving the view.
    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(70, 20); exportBtn:SetPoint("TOPRIGHT", -34, -33); exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function() if _G.GaarVanguard_ShowExport then _G.GaarVanguard_ShowExport() end end)

    local scroll = CreateFrame("ScrollFrame", "GaarVanguardViewScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -60); scroll:SetPoint("BOTTOMRIGHT", -32, 12)
    f.scroll = scroll

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(500, 10)
    scroll:SetScrollChild(content)
    f.content = content

    -- Mouse wheel scrolling, clamped to the scrollable range.
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange() or 0
        local v = (self:GetVerticalScroll() or 0) - delta * 30
        if v < 0 then v = 0 elseif v > range then v = range end
        self:SetVerticalScroll(v)
    end)
    -- Re-flow once the frame has its real width (first layout / any resize).
    scroll:SetScript("OnSizeChanged", function()
        if viewFrame and viewFrame:IsShown() then RenderView() end
    end)

    viewFrame = f
    return f
end

local function ShowView()
    BuildView()
    RenderView()
    viewFrame:Show()
    if viewFrame.scroll and viewFrame.scroll.SetVerticalScroll then viewFrame.scroll:SetVerticalScroll(0) end
    RenderView()
end
_G.GaarVanguard_ShowView = ShowView

-- ---------------------------------------------------------------------------
-- Profession probe: /gaarvanguard probe
--
-- The one call that has to survive an API we cannot run here. It reports, for the current
-- character, exactly which profession-related readers exist and what each returns - so if the
-- binary strings were ambiguous the user can run it on Forever and paste the output back. It never
-- changes game state: every call is read-only and pcall-guarded. Mirrors GaarProbe's habit of
-- asking the client rather than trusting memory.
-- ---------------------------------------------------------------------------
local function TypeOf(v)
    local t = type(v)
    if t == "function" then return "function" end
    if t == "table" then return "table" end
    if v == nil then return "MISSING" end
    return t
end

local function ProbeProfessionsLines()
    local L = {}
    local function add(s) L[#L + 1] = s end

    add("== GaarVanguard profession probe ==")
    add("project WOW_PROJECT_ID=" .. tostring(_G.WOW_PROJECT_ID) ..
        "  interface=" .. tostring(select(4, safe(GetBuildInfo))) ..
        "  build=" .. tostring((safe(GetBuildInfo)) or "?"))

    -- 1. The modern global path (the fix): GetProfessions / GetProfessionInfo as globals.
    add("")
    add("-- modern globals --")
    add("GetProfessions (global)      = " .. TypeOf(_G.GetProfessions))
    add("GetProfessionInfo (global)   = " .. TypeOf(_G.GetProfessionInfo))
    if type(_G.GetProfessions) == "function" then
        local a, b, c, d, e, f = safe(_G.GetProfessions)
        add("GetProfessions() returns: " .. table.concat({
            tostring(a), tostring(b), tostring(c), tostring(d), tostring(e), tostring(f) }, ", "))
        for _, idx in ipairs({ a, b, c, d, e, f }) do
            if type(idx) == "number" and idx > 0 and type(_G.GetProfessionInfo) == "function" then
                local name, _, skill, maxSkill = safe(_G.GetProfessionInfo, idx)
                add(string.format("  GetProfessionInfo(%d) -> name=%s skill=%s max=%s",
                    idx, tostring(name), tostring(skill), tostring(maxSkill)))
            end
        end
    end

    -- 2. C_TradeSkillUI alias check (the name the old code wrongly used).
    add("")
    add("-- C_TradeSkillUI --")
    local TSU = _G.C_TradeSkillUI
    add("C_TradeSkillUI               = " .. TypeOf(TSU))
    if type(TSU) == "table" then
        add("  .GetProfessions            = " .. TypeOf(TSU.GetProfessions) .. "  (was assumed present - it is not on Forever)")
        add("  .GetProfessionInfo         = " .. TypeOf(TSU.GetProfessionInfo))
        add("  .GetProfessionInfoBySkillLineID = " .. TypeOf(TSU.GetProfessionInfoBySkillLineID))
    end

    -- 3. Skill-line readers: classic globals vs the Forever C_SkillInfo namespace.
    add("")
    add("-- skill-line readers --")
    add("GetNumSkillLines (global)    = " .. TypeOf(_G.GetNumSkillLines))
    add("GetSkillLineInfo (global)    = " .. TypeOf(_G.GetSkillLineInfo))
    add("ExpandSkillHeader (global)   = " .. TypeOf(_G.ExpandSkillHeader))
    local CSI = _G.C_SkillInfo
    add("C_SkillInfo                  = " .. TypeOf(CSI))
    if type(CSI) == "table" then
        for _, fn in ipairs({ "GetNumSkillLines", "GetSkillLineInfo", "GetSkillLineInfoByID",
                              "ExpandSkillHeader", "CollapseSkillHeader" }) do
            add("  C_SkillInfo." .. fn .. string.rep(" ", 22 - #fn) .. "= " .. TypeOf(CSI[fn]))
        end
        if type(CSI.GetSkillLineInfo) == "function" then
            local t = safe(CSI.GetSkillLineInfo, 1)
            if type(t) == "table" then
                local keys = {}
                for k in pairs(t) do keys[#keys + 1] = tostring(k) end
                table.sort(keys)
                add("  C_SkillInfo.GetSkillLineInfo(1) is a TABLE with keys: " .. table.concat(keys, ", "))
            else
                add("  C_SkillInfo.GetSkillLineInfo(1) returned: " .. TypeOf(t))
            end
        end
    end

    -- 4. Full dump of every skill line, via the normalised accessor, after expanding all headers.
    add("")
    add("-- all skill lines (via SkillLine_GetInfo, headers expanded) --")
    if SkillLine_HasReader() then
        local collapsed = {}
        local n0 = SkillLine_GetNum()
        for i = 1, n0 do
            local name, isHeader, isExpanded = SkillLine_GetInfo(i)
            if isHeader and isExpanded == false then collapsed[#collapsed + 1] = name end
        end
        SkillLine_ExpandAll()
        local n = SkillLine_GetNum()
        add("GetNumSkillLines -> " .. n)
        for i = 1, n do
            local name, isHeader, isExpanded, rank, maxRank = SkillLine_GetInfo(i)
            add(string.format("  [%2d] %-28s header=%s expanded=%s skill=%s/%s%s",
                i, tostring(name), tostring(isHeader), tostring(isExpanded),
                tostring(rank), tostring(maxRank),
                (name and not isHeader and PROFESSION_NAMES[name]) and "  <- PROFESSION" or ""))
        end
        for _, name in ipairs(collapsed) do CollapseSkillHeaderByName(name) end
    else
        add("no skill-line reader present (neither global GetSkillLineInfo nor C_SkillInfo)")
    end

    -- 5. Forever-specific profession namespaces found in the binary (informational).
    add("")
    add("-- other profession namespaces (from binary) --")
    for _, ns in ipairs({ "C_ProfSpecs", "C_CraftingOrders", "C_Traits" }) do
        add(ns .. string.rep(" ", 20 - #ns) .. " = " .. TypeOf(_G[ns]))
    end

    -- 6. What the addon would actually export for this character right now.
    add("")
    add("-- resolved export --")
    local modern = ScanProfessionsModern()
    local classic = ScanProfessionsClassic()
    local function summarise(label, list)
        if not list then add(label .. ": nil (path not available)"); return end
        if #list == 0 then add(label .. ": 0 professions"); return end
        local parts = {}
        for _, p in ipairs(list) do parts[#parts + 1] = string.format("%s %s/%s", p.name, p.skill, p.max) end
        add(label .. ": " .. table.concat(parts, ", "))
    end
    summarise("ScanProfessionsModern",  modern)
    summarise("ScanProfessionsClassic", classic)
    local probeChar = { professions = {} }
    safe(CaptureProfessions, probeChar)
    summarise("CaptureProfessions (what exports)", probeChar.professions)

    return L
end

-- Append the icon-route probe for one spellID: the raw GetSpellTexture return AND its Lua type, from
-- both the classic global and the C_Spell namespace, plus the derived basename. Confirms in-game
-- whether this client returns a path STRING (basename usable) or a NUMBER fileDataID (icon omitted).
-- `add` is the probe's line sink, passed in so this stays a plain top-level helper.
local function AppendIconProbe(add, label, spellID)
    add(string.format("  %s spellID=%s", tostring(label), tostring(spellID)))
    if type(spellID) ~= "number" then
        add("    (no spellID resolved -> icon omitted)")
        return
    end
    if type(_G.GetSpellTexture) == "function" then
        local t = safe(_G.GetSpellTexture, spellID)
        add(string.format("    GetSpellTexture -> %s  (type=%s)  basename=%s",
            tostring(t), type(t), tostring(IconBasenameFromTexture(t))))
    else
        add("    GetSpellTexture: not a function on this client")
    end
    local CS = _G.C_Spell
    if type(CS) == "table" and type(CS.GetSpellTexture) == "function" then
        local t = safe(CS.GetSpellTexture, spellID)
        add(string.format("    C_Spell.GetSpellTexture -> %s  (type=%s)  basename=%s",
            tostring(t), type(t), tostring(IconBasenameFromTexture(t))))
    else
        add("    C_Spell.GetSpellTexture: not a function on this client")
    end
end

-- Talent probe. Same idea as the profession probe: report, for the current character, exactly
-- which talent readers exist and what they return live, so if talents do not resolve on Forever we
-- have the data to adjust. Read-only and fully pcall-guarded; changes no game state.
local function ProbeTalentsLines()
    local L = {}
    local function add(s) L[#L + 1] = s end

    add("== GaarVanguard talent probe ==")

    -- 1. Classic talent API (the expected path on Vanilla-content Forever).
    add("")
    add("-- classic talent globals --")
    add("GetNumTalentTabs   = " .. TypeOf(_G.GetNumTalentTabs))
    add("GetTalentTabInfo   = " .. TypeOf(_G.GetTalentTabInfo))
    add("GetNumTalents      = " .. TypeOf(_G.GetNumTalents))
    add("GetTalentInfo      = " .. TypeOf(_G.GetTalentInfo))

    local classicOK = type(_G.GetNumTalentTabs) == "function"
        and type(_G.GetTalentTabInfo) == "function"
    if classicOK then
        local numTabs = tonumber(safe(_G.GetNumTalentTabs)) or 0
        add("GetNumTalentTabs() -> " .. numTabs)
        for tab = 1, numTabs do
            local name, _, pts = safe(_G.GetTalentTabInfo, tab)
            local numT = (type(_G.GetNumTalents) == "function") and (tonumber(safe(_G.GetNumTalents, tab)) or 0) or "?"
            add(string.format("  tab %d: name=%s points=%s numTalents=%s",
                tab, tostring(name), tostring(pts), tostring(numT)))
            -- Show the first talent of each tab so the GetTalentInfo shape is visible live.
            if type(_G.GetTalentInfo) == "function" and type(numT) == "number" and numT > 0 then
                local tname, _, tier, column, rank, maxRank = safe(_G.GetTalentInfo, tab, 1)
                add(string.format("    GetTalentInfo(%d,1) -> name=%s tier=%s col=%s rank=%s max=%s",
                    tab, tostring(tname), tostring(tier), tostring(column), tostring(rank), tostring(maxRank)))
            end
        end
    else
        add("classic talent API not present on this client")
    end

    -- 2. Forever/retail spec namespace. NOTE (live probe 2026-09-23): C_SpecializationInfo turned
    --    out to be CLASS-LEVEL on Forever - GetSpecializationInfo(1) -> name = the class ("Mage"),
    --    pointsSpent always 0 - so it does NOT carry the Vanilla per-tree points. Kept here for the
    --    record; the per-point data is chased in sections 4-6 (C_ClassTalents / C_Traits / raw
    --    C_SkillInfo) instead.
    add("")
    add("-- retail talent/spec namespaces --")
    add("GetSpecialization (global)      = " .. TypeOf(_G.GetSpecialization))
    add("GetSpecializationInfo (global)  = " .. TypeOf(_G.GetSpecializationInfo))
    add("GetNumSpecializations (global)  = " .. TypeOf(_G.GetNumSpecializations))
    for _, ns in ipairs({ "C_Traits", "C_ClassTalents", "C_SpecializationInfo" }) do
        add(ns .. string.rep(" ", 30 - #ns) .. "= " .. TypeOf(_G[ns]))
    end
    if type(C_SpecInfo) == "table" then
        for _, fn in ipairs({ "GetSpecialization", "GetSpecializationInfo", "GetNumSpecializations",
                              "GetNumSpecializationsForClassID", "GetActiveSpecGroup" }) do
            add("  C_SpecializationInfo." .. fn .. string.rep(" ", 32 - #fn) .. "= " .. TypeOf(C_SpecInfo[fn]))
        end
    end
    -- Live: how many specs/trees, active index, and pointsSpent per tree (the read the spec name
    -- and the compact talent summary both come from on Forever).
    local numSpecs = Spec_GetNum()
    add("Spec_GetNum() -> " .. tostring(numSpecs))
    local getActive = (C_SpecInfo and C_SpecInfo.GetSpecialization) or _G.GetSpecialization
    if type(getActive) == "function" then
        add("active GetSpecialization() -> " .. tostring(safe(getActive)))
    end
    for i = 1, numSpecs do
        local sname, spts, sid = Spec_GetInfo(i)
        add(string.format("  GetSpecializationInfo(%d) -> name=%s points=%s specId=%s",
            i, tostring(sname), tostring(spts), tostring(sid)))
    end
    -- Show the raw return of GetSpecializationInfo(1) so a table-vs-tuple shape is visible live.
    local rawFn = (C_SpecInfo and C_SpecInfo.GetSpecializationInfo) or _G.GetSpecializationInfo
    if type(rawFn) == "function" then
        local r1 = safe(rawFn, 1)
        if type(r1) == "table" then
            local keys = {}
            for k in pairs(r1) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            add("  GetSpecializationInfo(1) is a TABLE with keys: " .. table.concat(keys, ", "))
        else
            add("  GetSpecializationInfo(1) first return is: " .. TypeOf(r1) .. " (value tuple)")
        end
    end
    add("GetNumSpecializations() (global) -> " ..
        (type(_G.GetNumSpecializations) == "function" and tostring(safe(_G.GetNumSpecializations)) or "n/a"))
    if type(C_SpecInfo) == "table" and type(C_SpecInfo.GetActiveSpecGroup) == "function" then
        add("C_SpecializationInfo.GetActiveSpecGroup() -> " .. tostring(safe(C_SpecInfo.GetActiveSpecGroup)))
    end

    -- A sorted "field=value" line for a returned table, so a live struct's real fields are visible.
    local function KV(t)
        if type(t) ~= "table" then return TypeOf(t) end
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            local v = t[k]
            if type(v) == "table" then
                parts[#parts + 1] = tostring(k) .. "={#" .. tostring(#v) .. "}"
            else
                parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
            end
        end
        return table.concat(parts, " ")
    end
    -- Sorted member=type listing of a namespace table.
    local function Members(ns)
        if type(ns) ~= "table" then return end
        local keys = {}
        for k, v in pairs(ns) do if type(v) == "function" then keys[#keys + 1] = tostring(k) end end
        table.sort(keys)
        for _, k in ipairs(keys) do add("  ." .. k) end
    end

    -- 4. C_ClassTalents: locate the active trait config the Vanilla points may live under.
    add("")
    add("-- C_ClassTalents --")
    local CCT = _G.C_ClassTalents
    add("C_ClassTalents = " .. TypeOf(CCT))
    local configID
    if type(CCT) == "table" then
        add("members:")
        Members(CCT)
        if type(CCT.GetActiveConfigID) == "function" then
            configID = safe(CCT.GetActiveConfigID)
            add("GetActiveConfigID() -> " .. tostring(configID))
        end
        if type(CCT.GetConfigIDsBySpecID) == "function" then
            local a, b, c2 = safe(CCT.GetConfigIDsBySpecID)
            add("GetConfigIDsBySpecID() -> " .. table.concat({ tostring(a), tostring(b), tostring(c2) }, ", "))
        end
        for _, fn in ipairs({ "GetHasStarterBuild", "GetStarterBuildActive" }) do
            if type(CCT[fn]) == "function" then add(fn .. "() -> " .. tostring(safe(CCT[fn]))) end
        end
        if type(CCT.GetTraitTreeForSpec) == "function" and type(getActive) == "function" then
            local specIdx = safe(getActive)
            if specIdx then add("GetTraitTreeForSpec(" .. tostring(specIdx) .. ") -> " ..
                tostring(safe(CCT.GetTraitTreeForSpec, specIdx))) end
        end
    end

    -- 5. C_Traits: walk the active config's trees and nodes to see if talent points live here.
    add("")
    add("-- C_Traits --")
    local CT = _G.C_Traits
    add("C_Traits = " .. TypeOf(CT))
    if type(CT) == "table" then
        add("members:")
        Members(CT)
        -- Fall back to the config id chased above, or a couple of standard lookups.
        if not configID and type(CT.GetConfigIDByTreeID) == "function" then
            -- nothing to seed a treeID with yet; leave configID nil.
        end
        if type(configID) == "number" and type(CT.GetConfigInfo) == "function" then
            local cfg = safe(CT.GetConfigInfo, configID)
            add("GetConfigInfo(" .. configID .. ") -> " .. KV(cfg))
            local treeIDs = (type(cfg) == "table") and cfg.treeIDs or nil
            if type(treeIDs) == "table" then
                for _, treeID in ipairs(treeIDs) do
                    local ti = (type(CT.GetTreeInfo) == "function") and safe(CT.GetTreeInfo, configID, treeID) or nil
                    add(string.format("  tree %s: GetTreeInfo -> %s", tostring(treeID), KV(ti)))
                    -- The tree's subtrees (the Vanilla Arcane/Fire/Frost trees live here). Dump each.
                    if type(ti) == "table" and type(ti.subTreeIDs) == "table" and type(CT.GetSubTreeInfo) == "function" then
                        for _, subID in ipairs(ti.subTreeIDs) do
                            add(string.format("    subtree %s: GetSubTreeInfo -> %s",
                                tostring(subID), KV(safe(CT.GetSubTreeInfo, configID, subID))))
                        end
                    end
                    local nodes = (type(CT.GetTreeNodes) == "function") and safe(CT.GetTreeNodes, treeID) or nil
                    local nodeCount = (type(nodes) == "table") and #nodes or 0
                    add(string.format("    GetTreeNodes -> %d node(s)", nodeCount))
                    -- Fully resolve every PURCHASED node (ranks>0): the complete node table, its
                    -- subtree name, and each entry -> definition -> spell name. This is where the
                    -- spent point lives, so this is what pins "Fire".
                    local summed, shown = 0, 0
                    if type(nodes) == "table" and type(CT.GetNodeInfo) == "function" then
                        for _, nodeID in ipairs(nodes) do
                            local ni = safe(CT.GetNodeInfo, configID, nodeID)
                            if type(ni) == "table" then
                                local r = tonumber(ni.ranksPurchased) or tonumber(ni.activeRank) or 0
                                summed = summed + r
                                if r > 0 and shown < 20 then
                                    shown = shown + 1
                                    add(string.format("    PURCHASED node %s (ranks=%d activeRank=%s):",
                                        tostring(nodeID), r, tostring(ni.activeRank)))
                                    add("      GetNodeInfo -> " .. KV(ni))
                                    -- Subtree of this node (should be the Vanilla tree name).
                                    local subID = tonumber(ni.subTreeID)
                                    if subID and subID > 0 and type(CT.GetSubTreeInfo) == "function" then
                                        local si = safe(CT.GetSubTreeInfo, configID, subID)
                                        add(string.format("      subTreeID=%s GetSubTreeInfo.name=%s | %s",
                                            tostring(subID),
                                            tostring(type(si) == "table" and si.name or nil), KV(si)))
                                    else
                                        add("      subTreeID = " .. tostring(ni.subTreeID) .. " (no subtree on node)")
                                    end
                                    -- Every entry -> definition -> spell name.
                                    local entryIDs = ni.entryIDsWithCommittedRanks
                                    if type(entryIDs) ~= "table" or not entryIDs[1] then entryIDs = ni.entryIDs end
                                    if type(entryIDs) == "table" and type(CT.GetEntryInfo) == "function" then
                                        for _, entryID in ipairs(entryIDs) do
                                            local ei = safe(CT.GetEntryInfo, configID, entryID)
                                            local defID = type(ei) == "table" and ei.definitionID or nil
                                            local di = (defID and type(CT.GetDefinitionInfo) == "function")
                                                and safe(CT.GetDefinitionInfo, defID) or nil
                                            local spellID = type(di) == "table" and (di.spellID or di.overriddenSpellID) or nil
                                            add(string.format("      entry %s: defID=%s overrideName=%s spellID=%s spell=%s",
                                                tostring(entryID), tostring(defID),
                                                tostring(type(di) == "table" and di.overrideName or nil),
                                                tostring(spellID), tostring(ResolveSpellName(spellID))))
                                        end
                                    end
                                    add("      -> ResolveNodeTalentName = " .. tostring(ResolveNodeTalentName(CT, configID, ni)))
                                end
                            end
                        end
                    end
                    add(string.format("    tree %s total ranks purchased = %d", tostring(treeID), summed))
                end
            end
        else
            add("(no active configID resolved - cannot walk trees/nodes)")
        end
    end

    -- 5b. SUBTREE enumeration at the CONFIG / TREE level (not the node level). The live probe
    --     (2026-09-23) found the per-node subtree route is dead on Forever - GetNodeInfo returns no
    --     subTreeID - so the Vanilla Arcane/Fire/Frost subtrees, if exposed at all, must be asked for
    --     at the config, tree, node-position and GetConfigsByType levels. This block dumps every key
    --     the API returns (arrays expanded to their real values, which the KV helper above collapses
    --     to {#N}), resolves every subTreeID it can find, and prints one compact line per node so we
    --     can see whether ANY node carries subtree tagging and whether posX bands separate the trees.
    --     Every call is pcall-guarded; nothing is invented - only what the API returns is printed.
    add("")
    add("-- subtree enumeration (config/tree level) --")
    -- Expand an array field to its actual values (KV above only prints {#N}).
    local function ArrStr(v)
        if type(v) ~= "table" then return tostring(v) end
        local parts = {}
        for i = 1, #v do parts[i] = tostring(v[i]) end
        return "[" .. table.concat(parts, ", ") .. "]"
    end
    -- Dump EVERY key of a returned table, expanding array-valued fields to their contents.
    local function FullKV(prefix, t)
        if type(t) ~= "table" then add(prefix .. "-> " .. TypeOf(t)); return end
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        if #keys == 0 then add(prefix .. "(empty table)"); return end
        for _, k in ipairs(keys) do
            local val = t[k]
            if type(val) == "table" then
                add(string.format("%s%s = %s", prefix, tostring(k), ArrStr(val)))
            else
                add(string.format("%s%s = %s", prefix, tostring(k), tostring(val)))
            end
        end
    end
    -- Collect every distinct subTreeID discovered anywhere, in discovery order, to resolve once.
    local subTreeSeen, subTreeOrder = {}, {}
    local function noteSubTrees(v)
        if type(v) ~= "table" then return end
        for _, id in ipairs(v) do
            if id ~= nil and not subTreeSeen[id] then
                subTreeSeen[id] = true
                subTreeOrder[#subTreeOrder + 1] = id
            end
        end
    end
    local function noteSubTree(id)
        if type(id) == "number" and id > 0 and not subTreeSeen[id] then
            subTreeSeen[id] = true
            subTreeOrder[#subTreeOrder + 1] = id
        end
    end

    if type(CT) == "table" and type(configID) == "number" then
        local cfg = (type(CT.GetConfigInfo) == "function") and safe(CT.GetConfigInfo, configID) or nil
        -- Task item 1: full GetConfigInfo dump, every key/value, subTreeIDs expanded.
        add(string.format("GetConfigInfo(%s) full:", tostring(configID)))
        FullKV("  ", cfg)
        if type(cfg) == "table" then noteSubTrees(cfg.subTreeIDs) end

        local treeIDs = (type(cfg) == "table") and cfg.treeIDs or nil
        -- Task item 2: for each treeID, full GetTreeInfo dump, subTreeIDs expanded.
        if type(treeIDs) == "table" and type(CT.GetTreeInfo) == "function" then
            for _, treeID in ipairs(treeIDs) do
                local ti = safe(CT.GetTreeInfo, configID, treeID)
                add(string.format("GetTreeInfo(%s, %s) full:", tostring(configID), tostring(treeID)))
                FullKV("  ", ti)
                if type(ti) == "table" then noteSubTrees(ti.subTreeIDs) end
            end
        end

        -- Task item 4: compact one-line-per-node dump of ALL nodes (not just purchased): nodeID,
        -- ranksPurchased, posX, posY, subTreeID (whatever GetNodeInfo returns, even nil) and any
        -- subTreeIDs array field on the node.
        if type(treeIDs) == "table" and type(CT.GetTreeNodes) == "function"
            and type(CT.GetNodeInfo) == "function" then
            for _, treeID in ipairs(treeIDs) do
                local nodes = safe(CT.GetTreeNodes, treeID)
                local count = (type(nodes) == "table") and #nodes or 0
                add(string.format("tree %s: %d node(s) - compact dump (ALL nodes):", tostring(treeID), count))
                if type(nodes) == "table" then
                    for _, nodeID in ipairs(nodes) do
                        local ni = safe(CT.GetNodeInfo, configID, nodeID)
                        if type(ni) == "table" then
                            add(string.format(
                                "  node %s ranks=%s posX=%s posY=%s subTreeID=%s subTreeIDs=%s",
                                tostring(nodeID), tostring(ni.ranksPurchased),
                                tostring(ni.posX), tostring(ni.posY), tostring(ni.subTreeID),
                                (type(ni.subTreeIDs) == "table") and ArrStr(ni.subTreeIDs) or tostring(ni.subTreeIDs)))
                            noteSubTrees(ni.subTreeIDs)
                            noteSubTree(tonumber(ni.subTreeID))
                        else
                            add(string.format("  node %s -> GetNodeInfo %s", tostring(nodeID), TypeOf(ni)))
                        end
                    end
                end
            end
        end
    else
        add("(no C_Traits config resolved - skipping config/tree subtree enumeration)")
    end

    -- Task item 5: the subtree info may live on a config of a different TYPE, so probe
    -- GetTraitTreeForSpec for the active spec and dump GetConfigInfo for every config
    -- GetConfigsByType returns. Feeds any subTreeIDs found into the resolver below.
    add("")
    add("-- other trait configs (GetTraitTreeForSpec / GetConfigsByType) --")
    if type(CCT) == "table" and type(CCT.GetTraitTreeForSpec) == "function" then
        local specID = (type(getActive) == "function") and safe(getActive) or nil
        add(string.format("GetTraitTreeForSpec(%s) -> %s", tostring(specID),
            tostring(safe(CCT.GetTraitTreeForSpec, specID))))
    else
        add("C_ClassTalents.GetTraitTreeForSpec not present")
    end
    if type(CT) == "table" and type(CT.GetConfigsByType) == "function" then
        local EnumT = _G.Enum
        local types = {}
        if type(EnumT) == "table" and type(EnumT.TraitConfigType) == "table" then
            for name, val in pairs(EnumT.TraitConfigType) do
                types[#types + 1] = { name = tostring(name), val = val }
            end
            table.sort(types, function(a, b) return (tonumber(a.val) or 0) < (tonumber(b.val) or 0) end)
        else
            -- No Enum table: probe a small range of type ids so nothing is assumed about names.
            for v = 0, 5 do types[#types + 1] = { name = "type" .. v, val = v } end
        end
        for _, ty in ipairs(types) do
            local list = safe(CT.GetConfigsByType, ty.val)
            add(string.format("GetConfigsByType(%s=%s) -> %s", tostring(ty.name), tostring(ty.val),
                (type(list) == "table") and ArrStr(list) or TypeOf(list)))
            if type(list) == "table" and type(CT.GetConfigInfo) == "function" then
                for _, cid in ipairs(list) do
                    local ci = safe(CT.GetConfigInfo, cid)
                    add(string.format("  config %s GetConfigInfo full:", tostring(cid)))
                    FullKV("    ", ci)
                    if type(ci) == "table" then noteSubTrees(ci.subTreeIDs) end
                end
            end
        end
    else
        add("C_Traits.GetConfigsByType not present")
    end

    -- Task item 3: resolve every subTreeID discovered above (config + trees + nodes + other configs)
    -- via GetSubTreeInfo, dumping the full struct (id, name, traitCurrencyID, ...).
    add("")
    add(string.format("discovered subTreeIDs: %s",
        (#subTreeOrder > 0) and ArrStr(subTreeOrder) or "(none)"))
    if #subTreeOrder > 0 and type(CT) == "table" and type(CT.GetSubTreeInfo) == "function"
        and type(configID) == "number" then
        for _, subID in ipairs(subTreeOrder) do
            local si = safe(CT.GetSubTreeInfo, configID, subID)
            add(string.format("GetSubTreeInfo(%s, %s) full:", tostring(configID), tostring(subID)))
            FullKV("  ", si)
        end
    elseif #subTreeOrder > 0 then
        add("(GetSubTreeInfo unavailable or no configID - cannot resolve the ids above)")
    end

    -- 6. Raw C_SkillInfo skill-line tables. The live probe showed the Vanilla trees show up here as
    --    child skill lines (Arcane/Fire/Frost under "Class Skills") all reading rank 1/1; dumping the
    --    FULL table for every non-header row exposes any field (tempPoints, modifier, stepCost,
    --    skillID, parentSkillLineID, ...) that distinguishes the spent tree from the others.
    add("")
    add("-- raw C_SkillInfo skill-line tables (non-header rows, full fields) --")
    local CSI = _G.C_SkillInfo
    if type(CSI) == "table" and type(CSI.GetSkillLineInfo) == "function" then
        -- Remember which headers were collapsed so the player's Skills window is left as it was.
        local collapsed = {}
        local n0 = SkillLine_GetNum()
        for i = 1, n0 do
            local name, isHeader, isExpanded = SkillLine_GetInfo(i)
            if isHeader and isExpanded == false then collapsed[#collapsed + 1] = name end
        end
        SkillLine_ExpandAll()
        local n = SkillLine_GetNum()
        local dumped = 0
        for i = 1, n do
            local t = safe(CSI.GetSkillLineInfo, i)
            if type(t) == "table" and not t.isHeader and dumped < 30 then
                dumped = dumped + 1
                add(string.format("  [%2d] %s", i, KV(t)))
            end
        end
        if dumped == 0 then add("  (no non-header skill lines dumped)") end
        for _, name in ipairs(collapsed) do CollapseSkillHeaderByName(name) end
    else
        add("  C_SkillInfo.GetSkillLineInfo not present")
    end

    -- 6b. posX band mapping - the deterministic route (no subtrees on Forever). Recompute the bands
    --     and the per-purchased-node assignment exactly as ScanTalentsTraits does, and print them so
    --     the next in-game run confirms the tab without guesswork.
    add("")
    add("-- posX band mapping --")
    do
        local _, classToken = safe(UnitClass, "player")
        add("classToken: " .. tostring(classToken))
        local treeNames = (type(classToken) == "string") and CLASS_TREE_NAMES[string.upper(classToken)] or nil
        add("CLASS_TREE_NAMES: " .. (treeNames and table.concat(treeNames, " / ") or "(class not in table)"))
        if type(configID) == "number" and type(CT) == "table" and type(CT.GetConfigInfo) == "function" then
            local cfg = safe(CT.GetConfigInfo, configID)
            local treeIDs = (type(cfg) == "table") and cfg.treeIDs or nil
            local allPosX, purchased = {}, {}
            if type(treeIDs) == "table" and type(CT.GetTreeNodes) == "function" and type(CT.GetNodeInfo) == "function" then
                for _, treeID in ipairs(treeIDs) do
                    local nodes = safe(CT.GetTreeNodes, treeID)
                    if type(nodes) == "table" then
                        for _, nodeID in ipairs(nodes) do
                            local ni = safe(CT.GetNodeInfo, configID, nodeID)
                            if type(ni) == "table" then
                                local px = tonumber(ni.posX)
                                if px then allPosX[#allPosX + 1] = px end
                                local r = tonumber(ni.ranksPurchased) or tonumber(ni.activeRank) or 0
                                if r > 0 then
                                    purchased[#purchased + 1] = {
                                        nodeID = nodeID, posX = px, ranks = r,
                                        name = ResolveNodeTalentName(CT, configID, ni),
                                    }
                                end
                            end
                        end
                    end
                end
            end
            local bands = ClusterBands(allPosX, 3)
            if bands then
                for i, b in ipairs(bands) do
                    add(string.format("  band %d: posX %s..%s%s", i, tostring(b.min), tostring(b.max),
                        treeNames and treeNames[i] and ("  = " .. treeNames[i]) or ""))
                end
            else
                add("  clustering did NOT yield 3 bands (" .. #allPosX .. " posX values) -> fallback path")
            end
            local bandPoints = { 0, 0, 0 }
            for _, p in ipairs(purchased) do
                local bi = bands and BandOf(bands, p.posX) or nil
                if bi then bandPoints[bi] = bandPoints[bi] + p.ranks end
                add(string.format("  purchased node %s: posX=%s ranks=%d band=%s name=%s",
                    tostring(p.nodeID), tostring(p.posX), p.ranks,
                    tostring(bi), tostring(p.name)))
            end
            add(string.format("  per-band ranks: [1]=%d [2]=%d [3]=%d", bandPoints[1], bandPoints[2], bandPoints[3]))
            local domBand, domPts = nil, 0
            for i = 1, 3 do if bandPoints[i] > domPts then domBand, domPts = i, bandPoints[i] end end
            add("  dominant band: " .. tostring(domBand) ..
                " -> tab " .. tostring(treeNames and domBand and treeNames[domBand] or nil))
        else
            add("  (no active configID / C_Traits - cannot band)")
        end
    end

    -- 6c. Full talent CALCULATOR grid (ScanTalentsCalculator): per-tree name, node count, rows
    --     (tier-count across the whole tree), that tree's col-count, and points. Plus the icon-route
    --     probe: for the first PURCHASED node and a few sample nodes, the raw GetSpellTexture return
    --     and its Lua type, so the string-path vs numeric-fileID route is confirmed in-game.
    add("")
    add("-- talent calculator (full tree) --")
    do
        local calc = ScanTalentsCalculator()
        if type(calc) ~= "table" then
            add("ScanTalentsCalculator -> nil (not 3 bands / class unknown / no config) -> traits fallback")
        else
            local rows = 0
            for _, tree in ipairs(calc) do
                for _, t in ipairs(tree.talents or {}) do
                    if (tonumber(t.tier) or 0) + 1 > rows then rows = (tonumber(t.tier) or 0) + 1 end
                end
            end
            add(string.format("rows (tier-count across whole tree): %d", rows))
            for _, tree in ipairs(calc) do
                local cols, withIcon, withSpell = 0, 0, 0
                for _, t in ipairs(tree.talents or {}) do
                    if (tonumber(t.col) or 0) + 1 > cols then cols = (tonumber(t.col) or 0) + 1 end
                    if t.icon then withIcon = withIcon + 1 end
                    if t.spellId then withSpell = withSpell + 1 end
                end
                local edges = tree.edges or {}
                add(string.format("  tree=%-14s nodes=%d rows=%d cols=%d points=%d  (icon=%d spellId=%d edges=%d)",
                    tostring(tree.tab), #(tree.talents or {}), rows, cols,
                    tonumber(tree.points) or 0, withIcon, withSpell, #edges))
                for i = 1, math.min(5, #edges) do
                    local e = edges[i]
                    add(string.format("      edge %d/%d: %s,%s -> %s,%s",
                        i, #edges, tostring(e.ft), tostring(e.fc), tostring(e.tt), tostring(e.tc)))
                end
            end
        end

        -- One-time raw shape of a node's visibleEdges entry, so the exact field names (targetNode vs
        -- other) are confirmed in-game. Walks the graph until it finds the first node with a non-empty
        -- visibleEdges array, then dumps the keys of its first entry via KV.
        add("  -- visibleEdges raw shape --")
        if type(configID) == "number" and type(CT) == "table"
            and type(CT.GetConfigInfo) == "function" and type(CT.GetTreeNodes) == "function"
            and type(CT.GetNodeInfo) == "function" then
            local cfg = safe(CT.GetConfigInfo, configID)
            local treeIDs = (type(cfg) == "table") and cfg.treeIDs or nil
            local shown = false
            if type(treeIDs) == "table" then
                for _, treeID in ipairs(treeIDs) do
                    if shown then break end
                    local nodeIDs = safe(CT.GetTreeNodes, treeID)
                    if type(nodeIDs) == "table" then
                        for _, nodeID in ipairs(nodeIDs) do
                            local ni = safe(CT.GetNodeInfo, configID, nodeID)
                            if type(ni) == "table" and type(ni.visibleEdges) == "table"
                                and #ni.visibleEdges > 0 then
                                add(string.format("  node %s visibleEdges: {#%d}",
                                    tostring(nodeID), #ni.visibleEdges))
                                add("    entry[1] keys: " .. KV(ni.visibleEdges[1]))
                                shown = true
                                break
                            end
                        end
                    end
                end
            end
            if not shown then add("  (no node with a non-empty visibleEdges array found)") end
        else
            add("  (no active configID / C_Traits - cannot sample visibleEdges)")
        end

        -- Icon-route probe. Gather the first purchased node + up to 3 sample nodes straight from the
        -- trait graph so the spellID/texture is shown even when the calculator route returned nil.
        add("  -- icon route (GetSpellTexture) --")
        if type(configID) == "number" and type(CT) == "table"
            and type(CT.GetConfigInfo) == "function" and type(CT.GetTreeNodes) == "function"
            and type(CT.GetNodeInfo) == "function" then
            local cfg = safe(CT.GetConfigInfo, configID)
            local treeIDs = (type(cfg) == "table") and cfg.treeIDs or nil
            local purchasedSpell, samples, seen = nil, {}, 0
            if type(treeIDs) == "table" then
                for _, treeID in ipairs(treeIDs) do
                    local nodeIDs = safe(CT.GetTreeNodes, treeID)
                    if type(nodeIDs) == "table" then
                        for _, nodeID in ipairs(nodeIDs) do
                            local ni = safe(CT.GetNodeInfo, configID, nodeID)
                            if type(ni) == "table" then
                                local name, spellID = ResolveNodeEntry(CT, configID, ni)
                                local r = tonumber(ni.ranksPurchased) or tonumber(ni.activeRank) or 0
                                if r > 0 and not purchasedSpell and spellID then
                                    purchasedSpell = { spellID = spellID, name = name }
                                end
                                if seen < 3 and spellID then
                                    seen = seen + 1
                                    samples[#samples + 1] = { spellID = spellID, name = name }
                                end
                            end
                        end
                    end
                end
            end
            if purchasedSpell then
                AppendIconProbe(add, "[purchased " .. tostring(purchasedSpell.name) .. "]", purchasedSpell.spellID)
            else
                add("  (no purchased node with a resolved spellID)")
            end
            for i, s in ipairs(samples) do
                AppendIconProbe(add, "[sample " .. i .. " " .. tostring(s.name) .. "]", s.spellID)
            end
        else
            add("  (no active configID / C_Traits - cannot sample icons)")
        end
    end

    -- 7. What the addon would actually export for this character right now.
    add("")
    add("-- resolved talent export --")
    local probeChar = {}
    safe(CaptureSpec, probeChar)
    safe(CaptureTalents, probeChar)
    local traitsProbe = ScanTalentsTraits()
    local calcProbe = ScanTalentsCalculator()
    local pathUsed = classicOK and "classic (GetTalentInfo tabs)"
        or (calcProbe and "Forever calculator grid (ScanTalentsCalculator - full tree)")
        or (traitsProbe and "Forever trait graph purchased-only (ScanTalentsTraits)")
        or "none (per-tree points not located yet - see sections 4-6)"
    add("path used: " .. pathUsed)
    -- Raw ScanTalentsTraits result (before CaptureTalents' all-named export gate), so the grouping and
    -- name resolution are visible even when the export build is withheld.
    if type(traitsProbe) == "table" then
        add("ScanTalentsTraits ->")
        for _, t in ipairs(traitsProbe) do
            local names = {}
            for _, tal in ipairs(t.talents or {}) do names[#names + 1] = tostring(tal.name) end
            add(string.format("  tab=%s points=%s named=%s talents=[%s]",
                tostring(t.tab), tostring(t.points), tostring(t.named), table.concat(names, ", ")))
        end
    else
        add("ScanTalentsTraits -> nil")
    end
    add("spec: " .. tostring(probeChar.spec))
    local build = probeChar.talents
    if type(build) ~= "table" or #build == 0 then
        add("talents: (empty - build not resolved on this client)")
    else
        for _, t in ipairs(build) do
            add(string.format("  %s: %d point(s), %d talent(s)",
                tostring(t.tab), tonumber(t.points) or 0, (type(t.talents) == "table") and #t.talents or 0))
            if type(t.talents) == "table" then
                for _, tal in ipairs(t.talents) do
                    add(string.format("    [t%s c%s] %-28s %s/%s",
                        tostring(tal.tier), tostring(tal.col), tostring(tal.name),
                        tostring(tal.rank), tostring(tal.max)))
                end
            end
        end
    end

    return L
end

-- Name probe: dump each name API's raw return so we can confirm which one carries the full
-- "First Last" on Forever, and show what FullPlayerName() actually picked.
local function ProbeNameLines()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    local function show(v) if v == nil then return "nil" else return "'" .. tostring(v) .. "'" end end
    add("== GaarVanguard name probe ==")
    local ok, n1, n2 = pcall(function() return UnitName("player") end)
    if ok then
        add("UnitName('player')            -> " .. show(n1) .. " , 2nd: " .. show(n2))
    else
        add("UnitName('player')            -> error")
    end
    add("GetUnitName('player', true)   -> " ..
        show(pcall1(function() return GetUnitName and GetUnitName("player", true) end)))
    local okf, f1, f2 = pcall(function() return UnitFullName("player") end)
    if okf then
        add("UnitFullName('player')        -> " .. show(f1) .. " , 2nd: " .. show(f2))
    else
        add("UnitFullName('player')        -> nil/error (API missing)")
    end
    add("GetRealmName()                -> " .. show(pcall1(GetRealmName)))
    add("=> FullPlayerName() picked    -> " .. show(FullPlayerName()))
    return lines
end

-- Equipment probe: which inventory readers this client has and what each returns for a few slots,
-- so a build where one of them comes back empty can be spotted in game.
local function ProbeEquipmentLines()
    local lines = {}
    local function add(x) lines[#lines + 1] = x end
    local function show(fn, ...)
        if type(fn) ~= "function" then return "MISSING" end
        local ok, v = pcall(fn, ...)
        if not ok then return "error" end
        if IsSecret(v) then return "SECRET" end
        if v == nil then return "nil" end
        return "'" .. tostring(v) .. "'"
    end
    local CI = _G.C_Item
    add("== GaarVanguard equipment probe ==")
    add("GetInventoryItemLink " .. type(_G.GetInventoryItemLink) .. ", GetInventoryItemID " ..
        type(_G.GetInventoryItemID) .. ", GetInventoryItemTexture " .. type(_G.GetInventoryItemTexture) ..
        ", GetInventoryItemQuality " .. type(_G.GetInventoryItemQuality))
    add("C_Item " .. type(CI) .. ", ItemLocation " .. type(_G.ItemLocation) .. ", C_TooltipInfo " ..
        type(_G.C_TooltipInfo) .. ", issecretvalue " .. type(issecretvalue))
    for _, slot in ipairs({ 1, 5, 16 }) do
        add(string.format("slot %d %s: link %s | id %s | texture %s", slot, SLOT_NAMES[slot],
            show(_G.GetInventoryItemLink, "player", slot), show(_G.GetInventoryItemID, "player", slot),
            show(_G.GetInventoryItemTexture, "player", slot)))
        local loc = EquipLocation(slot)
        if loc and type(CI) == "table" then
            add(string.format("    C_Item: exists %s | link %s | id %s", show(CI.DoesItemExist, loc),
                show(CI.GetItemLink, loc), show(CI.GetItemID, loc)))
        end
    end
    local ok, items, unknown = pcall(ScanEquipment)
    if ok then
        add(string.format("=> ScanEquipment: %d items, %d slots unreadable; record holds %d; ready %s",
            #items, unknown, (function() local c = CurrentChar(); return c and type(c.equipment) == "table"
                and #c.equipment or 0 end)(), tostring(equipReady)))
    else
        add("=> ScanEquipment: error")
    end
    return lines
end

local probeFrame
local function ShowProbe()
    -- Name probe first so the identity check is at the top of the dump.
    local lines = ProbeNameLines()
    local plines = ProbeProfessionsLines()
    lines[#lines + 1] = ""
    for _, l in ipairs(plines) do lines[#lines + 1] = l end
    -- Append the talent probe so one command dumps all three, non-spammy.
    local tlines = ProbeTalentsLines()
    lines[#lines + 1] = ""
    for _, l in ipairs(tlines) do lines[#lines + 1] = l end
    local elines = ProbeEquipmentLines()
    lines[#lines + 1] = ""
    for _, l in ipairs(elines) do lines[#lines + 1] = l end
    -- Chat: the summary lines, so a glance is enough.
    print("|cff5599ff" .. ADDON .. ":|r name + profession + talent + equipment probe -")
    for _, l in ipairs(lines) do print(l) end
    -- Copyable box: the whole thing, to paste back to us.
    if not probeFrame then
        probeFrame = MakeBox("GaarVanguardProbe", "Name, profession, talent + equipment probe — ctrl-A, ctrl-C, paste this back", false)
    end
    probeFrame.box:SetText(table.concat(lines, "\n"))
    probeFrame.box:HighlightText()
    probeFrame:Show()
    probeFrame.box:SetFocus()
end
_G.GaarVanguard_ShowProbe = ShowProbe

local function Say(msg)
    print("|cff5599ff" .. ADDON .. ":|r " .. msg)
end

-- Recapture the current character and report what was captured. Shared by the slash command
-- and the minimap menu.
local function CaptureAndReport()
    -- ExportAndStore does the full live recapture (BuildExportStringCurrent rescans first) and also
    -- refreshes the stored export, so the desktop app picks the recapture up after the next logout
    -- or /reload.
    pcall(ExportAndStore)
    local c = CurrentChar()
    Say("captured " .. (c and (c.name or "?") or "?") ..
        " (" .. (c and c.equipment and #c.equipment or 0) .. " equipped, " ..
        (c and c.loot and #c.loot or 0) .. " loot rows).")
end

-- Turn auto-sync (the stored exports for the Vanguard Sync desktop app) on or off. Shared by the
-- minimap menu, the options panel checkbox and /gaarvanguard sync on|off.
local autoSyncCheck   -- the options panel checkbox, once that panel has been built
local function SetAutoSync(on)
    DB().autoSync = on and true or false
    if on then
        Say("Auto-sync on — the Vanguard Sync desktop app will pick up this character after logout/reload.")
    else
        Say("Auto-sync off — the Vanguard Sync desktop app will not pick up this character after logout/reload.")
    end
    if autoSyncCheck then pcall(autoSyncCheck.SetChecked, autoSyncCheck, on and true or false) end
end

local function ToggleAutoSync()
    SetAutoSync(not AutoSyncEnabled())
end

-- ---------------------------------------------------------------------------
-- Quick copy popup
--
-- An addon cannot write to the system clipboard: CopyToClipboard is reserved for Blizzard code.
-- The closest we can get is a small box whose text is already selected and focused, so the
-- player only has to press Ctrl+C (Cmd+C on a Mac). The box watches for that keystroke and closes
-- itself with a short confirmation once it has been pressed. The text is read-only: any edit is
-- undone straight away, and clicking into the box selects everything again.
-- ---------------------------------------------------------------------------
local WEBSITE_URL = "https://vanguard.gaaruniverse.no"

local function CopyKeyLabel()
    if pcall1(_G.IsMacClient) then return "Cmd+C" end
    return "Ctrl+C"
end

-- Ctrl+C everywhere, plus Cmd+C on a Mac (IsMetaKeyDown reports Cmd where the client has it).
local function IsCopyKeystroke(key)
    if key ~= "C" and key ~= "c" then return false end
    return (pcall1(_G.IsControlKeyDown) or pcall1(_G.IsMetaKeyDown)) and true or false
end

local quickCopy

-- Close the popup after the copy keystroke. Called from a short timer after the key goes down
-- (so the edit box has done the copy before it loses focus) and again on key up; whichever comes
-- first does the work, the other finds nothing pending.
local function FinishQuickCopy()
    local f = quickCopy
    if not f or not f.copyPending then return end
    f.copyPending = nil
    local msg = f.doneMessage or "Copied!"
    if f:IsShown() then f:Hide() end
    Say(msg)
    local errs = _G.UIErrorsFrame
    if errs and type(errs.AddMessage) == "function" then
        pcall(errs.AddMessage, errs, "Copied!", 0.3, 1.0, 0.4)
    end
end

local function QuickCopyFrame()
    if quickCopy then return quickCopy end
    local name = "GaarVanguardQuickCopy"
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(460, 136); f:SetPoint("CENTER", 0, 140)
    f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
    f:SetBackdropColor(0.05, 0.06, 0.08, 0.97)
    f:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetScript("OnHide", function(self)
        self.copyPending = nil
        if self.box then self.box:ClearFocus() end   -- hand the keyboard back to the game
    end)
    table.insert(UISpecialFrames, name)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -12)

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(60, 20); close:SetPoint("TOPRIGHT", -12, -10); close:SetText("Close")
    close:SetScript("OnClick", function() f:Hide() end)

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.hint:SetPoint("BOTTOMLEFT", 12, 10)

    local scroll = CreateFrame("ScrollFrame", name .. "Scroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -38); scroll:SetPoint("BOTTOMRIGHT", -32, 32)

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true); box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetWidth(410)
    box:SetScript("OnEscapePressed", function() f:Hide() end)
    -- Read-only: put the text back if anything changes it. Comparing against the stored text
    -- (rather than trusting the userInput flag) also stops the restore from re-triggering itself.
    box:SetScript("OnTextChanged", function(self)
        if self.lockedText and self:GetText() ~= self.lockedText then
            self:SetText(self.lockedText)
            self:HighlightText()
        end
    end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnMouseUp", function(self) self:HighlightText() end)
    box:SetScript("OnKeyDown", function(_, key)
        if IsCopyKeystroke(key) then
            f.copyPending = true
            After(0.1, FinishQuickCopy)
        end
    end)
    box:SetScript("OnKeyUp", function(_, key)
        if f.copyPending and (key == "C" or key == "c") then FinishQuickCopy() end
    end)
    scroll:SetScrollChild(box)
    f.box = box

    f:Hide()
    quickCopy = f
    return f
end

-- Show `text` in the popup, selected and focused, ready for one copy keystroke.
local function ShowQuickCopy(title, text, doneMessage)
    local f = QuickCopyFrame()
    text = text or ""
    f.copyPending = nil
    f.doneMessage = doneMessage
    f.title:SetText(title)
    f.hint:SetText("Press " .. CopyKeyLabel() .. " to copy  -  Esc to close")
    f.box.lockedText = nil
    f.box:SetText(text)
    f.box.lockedText = text
    f:Show()
    f.box:SetFocus()
    f.box:HighlightText()
    -- Some clients drop the selection when focus lands; select again on the next frame.
    After(0, function() if f:IsShown() then f.box:HighlightText() end end)
    return f
end

-- The character export is the same BuildExportStringCurrent() the Export box uses, so the string
-- is identical to /gaarvanguard export for the same character state. It is also stored for the
-- desktop app, exactly as shown.
local function QuickCopyCurrent()
    ShowQuickCopy("Vanguard export — this character", ExportAndStore(),
        "Copied! Paste it into the Vanguard website.")
end

local function QuickCopyAll()
    ShowQuickCopy("Vanguard export — all characters (identity only)", BuildExportStringAll(),
        "Copied! Paste it into the Vanguard website.")
end

-- Addons cannot open a browser either, so the URL goes into the same copy box.
local function ShowWebsite()
    ShowQuickCopy("Vanguard website", WEBSITE_URL, "Copied! Paste it into your browser.")
end

-- ---------------------------------------------------------------------------
-- Minimap button
--
-- For players who would rather click than type: left-click copies this character's export,
-- right-click opens a small menu, dragging moves the button around the minimap's edge. The
-- placement logic mirrors GaarOptions' button, copied rather than shared: GaarVanguard ships on its
-- own as a ZIP, so it cannot depend on GaarOptions or on a library such as LibDBIcon.
--
-- Settings live in GaarVanguardDB.minimap = { hide = <bool>, angle = <degrees> } and are only read
-- once SavedVariables have loaded (ADDON_LOADED / PLAYER_LOGIN below), never at file scope.
-- ---------------------------------------------------------------------------
local ADDON_FOLDER = "GaarVanguard"
-- GaarOptions' button defaults to 205 degrees; 245 keeps the two about 55 px apart on the round
-- minimap, so both can be shown without overlapping.
local MINIMAP_DEFAULT_ANGLE = 245
-- Built-in icons, best first. INV_Misc_Note_03 (a written note, i.e. the export) is referenced by
-- installed addons on Era, Forever and retail alike; the others are fallbacks in case a client
-- does not resolve it.
local MINIMAP_ICONS = {
    "Interface\\Icons\\INV_Misc_Note_03",
    "Interface\\Icons\\INV_Misc_Map_01",
    "Interface\\Icons\\INV_Misc_QuestionMark",
}

local function MinimapDB()
    local d = DB()
    local m = d.minimap
    if type(m) ~= "table" then
        m = { hide = (m == false) }   -- a bare on/off flag is honoured, not thrown away
        d.minimap = m
    end
    if type(m.hide) ~= "boolean" then m.hide = false end
    local a = tonumber(m.angle)
    if not a or a ~= a or a == math.huge or a == -math.huge then a = MINIMAP_DEFAULT_ANGLE end
    m.angle = a % 360
    return m
end

-- Geometry read off a Blizzard frame can be a secret value on newer clients, and a secret cannot be
-- compared or divided, so it is checked with IsSecret (defined with the other helpers near the top)
-- before it is used at all (same guard as GaarOptions).
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function PickMinimapIcon()
    local getID = _G.GetFileIDFromPath
    if type(getID) ~= "function" then return MINIMAP_ICONS[1] end
    for _, path in ipairs(MINIMAP_ICONS) do
        if pcall1(getID, path) then return path end
    end
    return MINIMAP_ICONS[1]
end

local minimapButton

local function PlaceMinimapButton()
    local b, mm = minimapButton, _G.Minimap
    if not b or not mm then return end
    local angle = math.rad(MinimapDB().angle)
    local cos, sin = math.cos(angle), math.sin(angle)
    local x, y
    -- GetMinimapShape is the convention every minimap-button addon reads, and GaarMap defines it
    -- when it squares the minimap. On a square minimap the direction vector is stretched until its
    -- longest component reaches the edge, so the button follows the corners and flat sides.
    local shape = pcall1(_G.GetMinimapShape) or "ROUND"
    local mw = mm.GetWidth and mm:GetWidth()
    if IsSecret(mw) or type(mw) ~= "number" or mw <= 0 then mw = 140 end
    if shape == "SQUARE" then
        local half = mw / 2 + 8
        local reach = math.max(math.abs(cos), math.abs(sin))
        if reach < 0.0001 then reach = 1 end
        x, y = half * cos / reach, half * sin / reach
    else
        -- On the minimap's rim: half its width plus 5, the same ring LibDBIcon buttons sit on.
        -- Scaling with the width keeps it on the edge of both the 140px Classic minimap and the
        -- larger retail-style one on Forever (a fixed radius sat inside the art there).
        local r = mw / 2 + 5
        x, y = r * cos, r * sin
    end
    b:ClearAllPoints()
    b:SetPoint("CENTER", mm, "CENTER", x, y)
end
-- GaarMap calls this (when present) after it squares the minimap, so the button moves at once.
_G.GaarVanguard_PlaceMinimapButton = PlaceMinimapButton

-- The minimap angle, in degrees, of the cursor relative to the minimap's centre; nil when the
-- geometry cannot be read.
local function CursorAngle()
    local mm = _G.Minimap
    if not mm or type(GetCursorPosition) ~= "function" then return nil end
    local mx, my = mm:GetCenter()
    local scale = mm:GetEffectiveScale()
    if IsSecret(mx) or IsSecret(my) or IsSecret(scale) then return nil end
    local cx, cy = GetCursorPosition()
    if type(mx) ~= "number" or type(my) ~= "number" or type(cx) ~= "number" or type(cy) ~= "number"
       or type(scale) ~= "number" or scale == 0 then
        return nil
    end
    cx, cy = cx / scale, cy / scale
    return math.deg(atan2(cy - my, cx - mx)) % 360
end

-- ---------------------------------------------------------------------------
-- Right-click menu. Blizzard's own menu (MenuUtil) where the client has it - retail and Forever -
-- and otherwise (Classic Era) a small menu drawn here, the way GaarBags does it, rather than
-- UIDropDownMenu, whose shared state is prone to taint.
-- ---------------------------------------------------------------------------
local SetMinimapHidden   -- defined below; the menu's "Hide" entry calls it

local function MinimapMenuEntries()
    local list = {
        { text = "Copy export (this character)", func = QuickCopyCurrent },
        { text = "Copy export (all characters)", func = QuickCopyAll },
        { text = "Open website", func = ShowWebsite },
        { divider = true },
        { text = "Open Vanguard view", func = ShowView },
        { text = "Recapture this character", func = CaptureAndReport },
        { text = "Auto-sync (Vanguard Sync app)", checkbox = true, checked = AutoSyncEnabled,
          func = ToggleAutoSync },
    }
    if type(_G.GaarOptions_Open) == "function" then
        list[#list + 1] = { text = "Settings", func = function() _G.GaarOptions_Open("vanguard") end }
    end
    list[#list + 1] = { divider = true }
    list[#list + 1] = { text = "Hide minimap button", func = function() SetMinimapHidden(true) end }
    return list
end

local customMenu
local function ShowCustomMenu(owner, entries)
    local m = customMenu
    if not m then
        m = CreateFrame("Frame", "GaarVanguardMinimapMenu", UIParent, "BackdropTemplate")
        m:SetFrameStrata("DIALOG")
        m:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        m:SetBackdropColor(0.07, 0.08, 0.10, 0.97)
        m:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
        m:EnableMouse(true)
        m:SetClampedToScreen(true)
        m.rows = {}
        m:Hide()
        table.insert(UISpecialFrames, "GaarVanguardMinimapMenu")
        -- Close once the mouse has been away from both the menu and the button for a moment.
        m:SetScript("OnUpdate", function(self, elapsed)
            local over = self:IsMouseOver() or (self.owner and self.owner:IsMouseOver())
            if over then
                self.idle = 0
            else
                self.idle = (self.idle or 0) + (elapsed or 0)
                if self.idle > 2 then self:Hide() end
            end
        end)
        customMenu = m
    end
    if m:IsShown() and m.owner == owner then m:Hide(); return m end

    local rows = { { title = ADDON } }
    for _, e in ipairs(entries) do rows[#rows + 1] = e end
    local w, y = 160, -6
    for i, it in ipairs(rows) do
        local r = m.rows[i]
        if not r then
            r = CreateFrame("Button", nil, m)
            r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.text:SetPoint("LEFT", 8, 0); r.text:SetJustifyH("LEFT")
            r:SetHighlightTexture(FLAT, "ADD")
            local hl = r:GetHighlightTexture()
            if hl then hl:SetVertexColor(1, 1, 1, 0.10) end
            m.rows[i] = r
        end
        local h = it.divider and 8 or 18
        r:SetHeight(h)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 4, y); r:SetPoint("TOPRIGHT", -4, y)
        if it.title or it.divider then
            r.text:SetText(it.title and ("|cffffd100" .. it.title .. "|r") or "")
            r:EnableMouse(false); r:SetScript("OnClick", nil)
        else
            local label = it.text
            if it.checkbox then
                -- A toggle row: check mark when on, an empty box when off.
                local on = it.checked and it.checked()
                label = (on and "|TInterface\\Buttons\\UI-CheckBox-Check:14:14|t "
                    or "|TInterface\\Buttons\\UI-CheckBox-Up:14:14|t ") .. label
            end
            r.text:SetText(label)
            r:EnableMouse(true)
            r:SetScript("OnClick", function() m:Hide(); it.func() end)
        end
        w = math.max(w, (r.text:GetStringWidth() or 0) + 24)
        r:Show()
        y = y - h
    end
    for i = #rows + 1, #m.rows do m.rows[i]:Hide() end
    m:SetSize(w, -y + 6)
    m:ClearAllPoints()
    m:SetPoint("TOPRIGHT", owner, "BOTTOMLEFT", 0, 0)
    m.owner = owner
    m.idle = 0
    m:Show()
    return m
end

-- Returns which menu was used ("MenuUtil" or "custom"); the harness checks it.
local function ShowMinimapMenu(owner)
    local entries = MinimapMenuEntries()
    local MU = _G.MenuUtil
    if type(MU) == "table" and type(MU.CreateContextMenu) == "function" then
        local ok = pcall(MU.CreateContextMenu, owner, function(_, root)
            if type(root.CreateTitle) == "function" then root:CreateTitle(ADDON) end
            for _, e in ipairs(entries) do
                if e.divider then
                    if type(root.CreateDivider) == "function" then root:CreateDivider() end
                elseif e.checkbox and type(root.CreateCheckbox) == "function" then
                    root:CreateCheckbox(e.text, function() return e.checked() and true or false end,
                        function() e.func() end)
                elseif e.checkbox then
                    -- A client whose menu has no checkbox: show the state in the label instead.
                    root:CreateButton((e.checked() and "[x] " or "[ ] ") .. e.text, function() e.func() end)
                else
                    root:CreateButton(e.text, function() e.func() end)
                end
            end
        end)
        if ok then return "MenuUtil" end
    end
    ShowCustomMenu(owner, entries)
    return "custom"
end

local function BuildMinimapButton()
    if minimapButton then return minimapButton end
    local mm = _G.Minimap
    if not mm then return nil end

    local b = CreateFrame("Button", "GaarVanguardMinimapButton", mm)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel((mm:GetFrameLevel() or 0) + 8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    -- The standard minimap-button look: dark disc, the icon, the gold tracking ring on top.
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(PickMinimapIcon())
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    b.icon = icon

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)

    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", function()
            local a = CursorAngle()
            if a then
                MinimapDB().angle = a
                PlaceMinimapButton()
            end
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(ADDON)
        GameTooltip:AddLine("Left-click: copy export string for this character", 1, 1, 1)
        GameTooltip:AddLine("Right-click: menu", 1, 1, 1)
        GameTooltip:AddLine("Drag: move", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    b:SetScript("OnClick", function(self, button)
        GameTooltip:Hide()
        if button == "RightButton" then
            ShowMinimapMenu(self)
        else
            QuickCopyCurrent()
        end
    end)

    minimapButton = b
    return b
end

local function ApplyMinimap()
    if MinimapDB().hide then
        if minimapButton then minimapButton:Hide() end
        if customMenu then customMenu:Hide() end
        return
    end
    if BuildMinimapButton() then
        PlaceMinimapButton()
        minimapButton:Show()
    end
end

SetMinimapHidden = function(hide)
    MinimapDB().hide = hide and true or false
    ApplyMinimap()
    if hide then
        Say("minimap button hidden. Type |cffffd100/gaarvg minimap|r to show it again.")
    else
        Say("minimap button shown.")
    end
end

local function ResetMinimapButton()
    local m = MinimapDB()
    m.angle = MINIMAP_DEFAULT_ANGLE
    m.hide = false
    ApplyMinimap()
    Say("minimap button reset to its default position.")
end

-- Build the button once our SavedVariables are in (ADDON_LOADED for this addon), and place it
-- again at PLAYER_LOGIN in case another addon changed the minimap's shape in between.
local minimapEv = CreateFrame("Frame")
pcall(minimapEv.RegisterEvent, minimapEv, "ADDON_LOADED")
pcall(minimapEv.RegisterEvent, minimapEv, "PLAYER_LOGIN")
minimapEv:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= ADDON_FOLDER then return end
        pcall(self.UnregisterEvent, self, "ADDON_LOADED")
    end
    pcall(ApplyMinimap)
end)

-- ---------------------------------------------------------------------------
-- Options panel (Gaar -> Vanguard)
-- ---------------------------------------------------------------------------
function GaarVanguard_BuildOptions(container)
    local y = -8
    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("Vanguard — character & loot export, and the in-game sync view")
    y = y - 30

    local viewBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    viewBtn:SetSize(160, 24); viewBtn:SetPoint("TOPLEFT", 16, y)
    viewBtn:SetText("Open Vanguard view")
    viewBtn:SetScript("OnClick", ShowView)
    y = y - 34

    local exportBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    exportBtn:SetSize(160, 24); exportBtn:SetPoint("TOPLEFT", 16, y)
    exportBtn:SetText("Export this char")
    exportBtn:SetScript("OnClick", ShowExport)

    local exportAllBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    exportAllBtn:SetSize(160, 24); exportAllBtn:SetPoint("TOPLEFT", 184, y)
    exportAllBtn:SetText("Sync all (identity)")
    exportAllBtn:SetScript("OnClick", ShowExportAll)
    y = y - 34

    local recapBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    recapBtn:SetSize(160, 24); recapBtn:SetPoint("TOPLEFT", 16, y)
    recapBtn:SetText("Recapture now")

    local probeBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    probeBtn:SetSize(160, 24); probeBtn:SetPoint("TOPLEFT", 184, y)
    probeBtn:SetText("Probe prof + talents")
    probeBtn:SetScript("OnClick", ShowProbe)
    y = y - 34

    local mmName = "GaarVanguardMinimapCheck"
    local mmCheck = CreateFrame("CheckButton", mmName, container, "UICheckButtonTemplate")
    mmCheck:SetSize(24, 24); mmCheck:SetPoint("TOPLEFT", 14, y)
    local mmText = _G[mmName .. "Text"] or mmCheck.Text
    if mmText then
        mmText:SetText("Minimap button")
        mmText:SetFontObject(GameFontHighlight)
    end
    mmCheck:SetScript("OnClick", function(self)
        SetMinimapHidden(not self:GetChecked())
    end)
    y = y - 30

    local asName = "GaarVanguardAutoSyncCheck"
    local asCheck = CreateFrame("CheckButton", asName, container, "UICheckButtonTemplate")
    asCheck:SetSize(24, 24); asCheck:SetPoint("TOPLEFT", 14, y)
    local asText = _G[asName .. "Text"] or asCheck.Text
    if asText then
        asText:SetText("Auto-sync (Vanguard Sync app)")
        asText:SetFontObject(GameFontHighlight)
    end
    asCheck:SetScript("OnClick", function(self)
        SetAutoSync(self:GetChecked() and true or false)
    end)
    autoSyncCheck = asCheck
    y = y - 30

    local count = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    count:SetPoint("TOPLEFT", 18, y); count:SetWidth(360); count:SetJustifyH("LEFT")
    local function refreshCount()
        local nChars, nLoot = 0, 0
        for _, c in pairs(DB().chars) do
            nChars = nChars + 1
            nLoot = nLoot + (c.loot and #c.loot or 0)
        end
        count:SetText(string.format("|cff777777%d character(s) captured, %d loot row(s).|r", nChars, nLoot))
    end
    local function refreshAll()
        refreshCount()
        mmCheck:SetChecked(not MinimapDB().hide)
        asCheck:SetChecked(AutoSyncEnabled())
    end
    refreshAll()
    recapBtn:SetScript("OnClick", function() pcall(ExportAndStore); refreshCount() end)
    y = y - 30

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(360); hint:SetJustifyH("LEFT")
    hint:SetText("Every character you log in on is added to one account-wide database and refreshed automatically. \"Export this char\" makes a full, reliable VGD1 string for the current character (all its data) - this is the primary export. \"Sync all (identity)\" makes a short VGD1 string listing every stored character with identity fields only, to populate the account pool. Both paste into the Vanguard website. This addon is export-only: view and manage your Vanguards, goals and readiness on the website.")
    y = y - 90

    container.gaarRefresh = refreshAll
    return -y
end

local function OpenOptions()
    if _G.GaarOptions_Open and _G.GaarOptions_Open("vanguard") then return end
    ShowExport()
end
_G.GaarVanguard_Config = OpenOptions

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
-- "/gaarvanguard sync": when this character's export was last stored for the desktop app. Read-only,
-- so it shows whether the logout / reload path has actually written something.
local function SyncStatus()
    if not CHARKEY then Identify() end
    local d = DB()
    local exports = type(d.exports) == "table" and d.exports or {}
    local n = 0
    for _, e in pairs(exports) do if type(e) == "table" then n = n + 1 end end
    local e = CHARKEY and exports[CHARKEY]
    if type(e) ~= "table" or type(e.export) ~= "string" then
        Say("Vanguard Sync: no export stored for this character yet. It is stored when you log out or " ..
            "/reload (or copy the export), and the desktop app reads it from disk after that.")
    else
        local at = tonumber(e.updatedAt)
        local when = "at an unknown time"
        if at then
            local stamp = pcall1(_G.date, "%Y-%m-%d %H:%M:%S", at)
            local now = type(time) == "function" and time() or nil
            local ago = now and math.max(0, now - at) or nil
            when = (stamp or tostring(at)) ..
                (ago and string.format(" (%d min %d s ago)", math.floor(ago / 60), ago % 60) or "")
        end
        Say(string.format("Vanguard Sync: this character's export was last stored %s, %d characters long" ..
            "%s.", when, #e.export, e.build and (", build " .. tostring(e.build)) or ""))
        -- What the desktop app will upload: read the stored string back and count its rows.
        local json = e.export:sub(1, #PREFIX) == PREFIX and Base64Decode(e.export:sub(#PREFIX + 1)) or ""
        local function rows(field, key)
            local list = json:match('"' .. field .. '":(%b[])')
            if not list then return "?" end
            local _, n = list:gsub('"' .. key .. '":', "")
            return tostring(n)
        end
        Say(string.format("Vanguard Sync: stored export holds %s equipped items, %s loot rows, level %s " ..
            "(XP %s / %s, rested %s).", rows("equipment", "slot"), rows("loot", "when"),
            json:match('"lvl":(%d+)') or "?", json:match('"xp":(%d+)') or "-",
            json:match('"xpMax":(%d+)') or "-", json:match('"xpRested":(%d+)') or "-"))
        -- Level and talent points: what the stored export holds next to what was read while playing,
        -- so a stale entry shows up before logout. The first "talents" key is the build's own list;
        -- only its trees carry "points".
        local storedPts = "?"
        local tlist = json:match('"talents":(%b[])')
        if tlist then
            local n = 0
            for p in tlist:gmatch('"points":(%d+)') do n = n + tonumber(p) end
            storedPts = tostring(n)
        end
        Say(string.format("Vanguard Sync: level %s in play / %s stored; talent points %s in play / %s stored.",
            tostring(inPlay.lvl or "?"), json:match('"lvl":(%d+)') or "?",
            tostring(inPlay.talentPts or "?"), storedPts))
    end
    -- What the last logout could still read live, next to what it stored.
    local dg = d.lastLogoutDiag
    if type(dg) == "table" then
        local stamp = tonumber(dg.when) and pcall1(_G.date, "%Y-%m-%d %H:%M:%S", tonumber(dg.when)) or "?"
        Say(string.format("Vanguard Sync: last logout (%s): level live %s / used %s, talent points live %s / " ..
            "used %s, equipped items live %s / used %s.", tostring(stamp),
            tostring(dg.levelLive or "-"), tostring(dg.levelUsed or "-"),
            tostring(dg.talentsLive or "-"), tostring(dg.talentsUsed or "-"),
            tostring(dg.equipLive or "-"), tostring(dg.equipUsed or "-")))
    end
    -- The live read next to the character record, so a reader that comes back empty on some build
    -- shows up here rather than only in the uploaded data.
    local c = CurrentChar()
    if c then
        local ok, items, unknown = pcall(ScanEquipment)
        Say(string.format("Vanguard Sync: equipment read live now: %s items%s; character record: %d items%s.",
            ok and tostring(#items) or "error",
            (ok and unknown > 0) and string.format(" (%d slots could not be read)", unknown) or "",
            type(c.equipment) == "table" and #c.equipment or 0,
            equipReady and "" or " (inventory still settling after the loading screen)"))
    end
    Say(string.format("Vanguard Sync: %d character export(s) stored. SavedVariables are only written to " ..
        "disk on logout, /reload or exit - the desktop app sees changes after that.", n))
    if AutoSyncEnabled() then
        Say("Vanguard Sync: auto-sync is ON (|cffffd100/gaarvg sync off|r to stop).")
    else
        Say("Vanguard Sync: auto-sync is OFF - nothing is stored and the app skips uploading " ..
            "(|cffffd100/gaarvg sync on|r to resume).")
    end
end

local function Usage()
    print("|cff5599ff" .. ADDON .. "|r — commands:")
    print("  |cffffd100/gaarvanguard|r or |cffffd100/gaarvg|r — open the in-game Vanguard view (synced goals/instances)")
    print("  |cffffd100/gaarvanguard export|r — full VGD1 string for THIS character (the reliable, primary export)")
    print("  |cffffd100/gaarvanguard exportall|r — lightweight VGD1 string for ALL stored characters (identity only)")
    print("  |cffffd100/gaarvanguard capture|r — recapture this character now")
    print("  |cffffd100/gaarvanguard sync|r — when this character's export was last stored for the Vanguard Sync desktop app, what it holds (equipped items, loot, level, talent points vs. in play), what the last logout could read, and whether auto-sync is on")
    print("  |cffffd100/gaarvanguard sync on|r / |cffffd100sync off|r — turn auto-sync for the Vanguard Sync desktop app on or off")
    print("  |cffffd100/gaarvanguard probe|r — dump which name, profession, talent and equipment APIs this client exposes")
    print("  |cffffd100/gaarvanguard minimap|r — show or hide the minimap button")
    print("  |cffffd100/gaarvanguard minimap reset|r — put the minimap button back at its default spot")
    print("  |cffffd100/gaarvanguard config|r — settings under Gaar -> Vanguard")
    print("  |cffffd100/gaarvanguard wipe|r — clear the whole database")
end

SLASH_GAARVANGUARD1 = "/gaarvanguard"
SLASH_GAARVANGUARD2 = "/gaarvg"
SlashCmdList["GAARVANGUARD"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "view" then
        ShowView()
    elseif msg == "export" then
        ShowExport()
    elseif msg == "exportall" or msg == "syncall" then
        ShowExportAll()
    elseif msg == "capture" or msg == "refresh" then
        CaptureAndReport()
    elseif msg == "minimap" then
        -- Whitespace is stripped above, so "minimap reset" arrives as "minimapreset".
        SetMinimapHidden(not MinimapDB().hide)
    elseif msg == "minimapreset" then
        ResetMinimapButton()
    elseif msg == "sync" then
        SyncStatus()
    elseif msg == "syncon" then      -- "sync on" (whitespace is stripped above)
        SetAutoSync(true)
    elseif msg == "syncoff" then
        SetAutoSync(false)
    elseif msg == "probe" then
        pcall(ShowProbe)
    elseif msg == "config" or msg == "options" then
        OpenOptions()
    elseif msg == "wipe" then
        GaarVanguardDB = nil; DB()
        pcall(ApplyMinimap)   -- the minimap settings were cleared too; back to the defaults
        print("|cff5599ff" .. ADDON .. ":|r database cleared.")
    else
        Usage()
        ShowView()
    end
end
