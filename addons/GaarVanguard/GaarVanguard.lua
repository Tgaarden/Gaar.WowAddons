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
      export so the string is correct even when the DB never persisted (the Forever beta).
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

  The import + view (Phase 2)
    The website hands back its own VGD1:<base64 JSON> with { k = "sync", ... } - the player's
    Vanguards, their goals, a members/readiness summary and the player's character->goal
    mapping. The Import box base64-decodes and JSON-decodes the string, stores the result under
    GaarVanguardDB.sync, prints a short summary, and opens the read-only Vanguard view. That
    view (/gaarvanguard, or the "Open Vanguard view" button) renders the stored sync in a
    movable, closable, scrollable window: your Vanguards, each goal's title/status/instance and
    which of your characters it applies to, an instance/readiness summary, and the per-character
    mapping. It writes nothing and shows an empty-state prompt until a sync has been imported.

  Everything that reads the game API is wrapped in pcall so a call that is missing or shaped
  differently on one client degrades to "not captured" instead of erroring. The base64 and JSON
  codecs are self-contained here - no external libraries.

  /gaarvanguard opens the Vanguard view (subcommands: export, exportall, import, capture, probe,
  config, wipe). Settings under Gaar -> Vanguard.
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
    -- d.sync is set by the import box; left nil until then.
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
-- character's identity key for the website import, so both exports depend on getting it right.
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

local function Base64Decode(data)
    if type(data) ~= "string" then return "" end
    data = data:gsub("[^" .. "A-Za-z0-9+/=" .. "]", "")
    return (data:gsub("=", ""):gsub(".", function(x)
        local f = (string.find(B64, x, 1, true) or 1) - 1
        local r = ""
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
        return string.char(c)
    end))
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
-- JSON decode (self-contained, recursive descent). Returns value, or nil + message.
-- ---------------------------------------------------------------------------
local function JsonDecode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local i, n = 1, #s
    local DecodeValue

    local function Err(msg) error(msg, 0) end

    local function Skip()
        while i <= n do
            local c = string.sub(s, i, i)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end
        end
    end

    local function DecodeString()
        i = i + 1 -- past opening quote
        local buf = {}
        while i <= n do
            local c = string.sub(s, i, i)
            if c == '"' then i = i + 1; return table.concat(buf) end
            if c == "\\" then
                local e = string.sub(s, i + 1, i + 1)
                if e == "n" then buf[#buf + 1] = "\n"
                elseif e == "t" then buf[#buf + 1] = "\t"
                elseif e == "r" then buf[#buf + 1] = "\r"
                elseif e == "b" then buf[#buf + 1] = "\b"
                elseif e == "f" then buf[#buf + 1] = "\f"
                elseif e == "/" then buf[#buf + 1] = "/"
                elseif e == "\\" then buf[#buf + 1] = "\\"
                elseif e == '"' then buf[#buf + 1] = '"'
                elseif e == "u" then
                    local code = tonumber(string.sub(s, i + 2, i + 5), 16) or 0
                    if code < 0x80 then
                        buf[#buf + 1] = string.char(code)
                    elseif code < 0x800 then
                        buf[#buf + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
                    else
                        buf[#buf + 1] = string.char(0xE0 + math.floor(code / 0x1000),
                            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
                    end
                    i = i + 4
                else
                    buf[#buf + 1] = e
                end
                i = i + 2
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
        Err("unterminated string")
    end

    local function DecodeNumber()
        local start = i
        while i <= n do
            local c = string.sub(s, i, i)
            if string.find(c, "[%d%+%-%.eE]") then i = i + 1 else break end
        end
        local num = tonumber(string.sub(s, start, i - 1))
        if not num then Err("bad number") end
        return num
    end

    DecodeValue = function()
        Skip()
        local c = string.sub(s, i, i)
        if c == '"' then
            return DecodeString()
        elseif c == "{" then
            i = i + 1
            local obj = {}
            Skip()
            if string.sub(s, i, i) == "}" then i = i + 1; return obj end
            while true do
                Skip()
                if string.sub(s, i, i) ~= '"' then Err("expected key") end
                local k = DecodeString()
                Skip()
                if string.sub(s, i, i) ~= ":" then Err("expected colon") end
                i = i + 1
                obj[k] = DecodeValue()
                Skip()
                local d = string.sub(s, i, i)
                if d == "," then i = i + 1
                elseif d == "}" then i = i + 1; return obj
                else Err("expected , or }") end
            end
        elseif c == "[" then
            i = i + 1
            local arr = {}
            Skip()
            if string.sub(s, i, i) == "]" then i = i + 1; return arr end
            while true do
                arr[#arr + 1] = DecodeValue()
                Skip()
                local d = string.sub(s, i, i)
                if d == "," then i = i + 1
                elseif d == "]" then i = i + 1; return arr
                else Err("expected , or ]") end
            end
        elseif c == "t" then
            if string.sub(s, i, i + 3) == "true" then i = i + 4; return true end
            Err("bad literal")
        elseif c == "f" then
            if string.sub(s, i, i + 4) == "false" then i = i + 5; return false end
            Err("bad literal")
        elseif c == "n" then
            if string.sub(s, i, i + 3) == "null" then i = i + 4; return nil end
            Err("bad literal")
        else
            return DecodeNumber()
        end
    end

    local ok, res = pcall(DecodeValue)
    if not ok then return nil, res end
    return res
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

local function CaptureIdentity(c)
    Identify()
    c.name = ME or c.name
    c.realm = REALM or c.realm
    local raceName = safe(UnitRace, "player")
    c.race = raceName or c.race
    -- Canonical field names the website expects: `cls` (localized class) and `lvl` (number).
    -- `classFile` (the locale-independent token) is kept alongside `cls` as a harmless extra.
    local className, classFile = safe(UnitClass, "player")
    c.cls = className or c.cls
    c.classFile = classFile or c.classFile
    local lvl = safe(UnitLevel, "player")
    if type(lvl) == "number" and lvl > 0 then c.lvl = lvl end
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
-- Captured live at capture/export exactly like professions/equipment (the Forever beta does not
-- persist SavedVariables, so a cached build cannot be trusted). Tried in order, all pcall-guarded,
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
-- capture/export like equipment, so it is correct even when the DB never persisted (Forever).
-- Prefer the modern C_TradeSkillUI reader (works on retail, Forever and Era), fall back to the
-- classic skill-line reader (with header expansion) where C_TradeSkillUI is absent. An empty
-- result leaves any previously captured list in place rather than wiping it.
local function CaptureProfessions(c)
    local out = ScanProfessionsModern()
    if not out or #out == 0 then
        local classic = ScanProfessionsClassic()
        if classic and #classic > 0 then out = classic end
    end
    if out and #out > 0 then
        c.professions = out
    else
        c.professions = c.professions or {}
    end
end

-- Equipment: inventory slots 1-19, scanned live via GetInventoryItemLink. `slot` is stored as
-- the canonical slot NAME string (SLOT_NAMES), never the numeric id. Quality comes from
-- GetItemInfo, which is asynchronous and may be nil for an item not yet cached - stored when
-- present, skipped when not.
local function CaptureEquipment(c)
    if type(GetInventoryItemLink) ~= "function" then return end
    local out = {}
    for slot = 1, 19 do
        local link = safe(GetInventoryItemLink, "player", slot)
        if link then
            local itemId
            if GetItemInfoInstant then itemId = safe(GetItemInfoInstant, link) end
            local name, _, quality
            if GetItemInfo then name, _, quality = safe(GetItemInfo, link) end
            out[#out + 1] = {
                slot = SLOT_NAMES[slot] or tostring(slot),
                itemId = tonumber(itemId) or nil,
                quality = tonumber(quality) or nil,
                name = name or link,
            }
        end
    end
    c.equipment = out
end

-- A full live scan of one character record from the current game state. Called both on the
-- capture events and, crucially, at export time - so the export reflects the LIVE current
-- character even when the DB is empty (the Forever beta does not persist SavedVariables, and
-- equipment events may never have fired / persisted).
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
        spec = c.spec,
    }
end

-- PRIMARY export: ONLY the current/logged-in character, fully scanned. This is the reliable flow -
-- one character makes a short string that survives the copy out of the in-game EditBox, unlike the
-- whole-account dump which truncated and lost talents/tail characters.
--
-- Fresh full scan right now, before building the string. The beta does not persist SavedVariables
-- and equipment events may not have fired, so we never trust cached data for the live character - we
-- re-read name/level/class/guild/spec/professions and loop the equip slots live here.
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
    local chars = {}
    for _, c in pairs(DB().chars) do chars[#chars + 1] = MinimalChar(c) end
    local payload = { k = "chars", chars = chars }
    return PREFIX .. Base64Encode(JsonEncode(payload))
end

-- ---------------------------------------------------------------------------
-- A reusable copy/paste box, modelled on GaarLooter's export frame. `editable` decides whether
-- it is a read-out (export) or a paste target (import).
-- ---------------------------------------------------------------------------
local function MakeBox(name, title, editable)
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
    scroll:SetPoint("TOPLEFT", 12, -38); scroll:SetPoint("BOTTOMRIGHT", -32, editable and 62 or 12)

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true); box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetWidth(500)
    box:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(box)
    f.box = box

    if editable then
        local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        status:SetPoint("BOTTOMLEFT", 14, 14); status:SetPoint("BOTTOMRIGHT", -14, 14)
        status:SetJustifyH("LEFT"); status:SetHeight(40)
        status:SetText("|cff777777Paste the website's sync string, then Import.|r")
        f.status = status
    end

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
            "Export this character — ctrl-A, ctrl-C, paste into the website", false)
    end
    exportFrame.box:SetText(BuildExportStringCurrent())
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
            "Sync all characters (identity only) — ctrl-A, ctrl-C, paste into the website", false)
    end
    exportAllFrame.box:SetText(BuildExportStringAll())
    exportAllFrame.box:HighlightText()
    exportAllFrame:Show()
    exportAllFrame.box:SetFocus()
end
_G.GaarVanguard_ShowExportAll = ShowExportAll

-- ---------------------------------------------------------------------------
-- Phase 2: the in-game sync view (read-only). Renders GaarVanguardDB.sync - the
-- website -> addon document the Import box decoded - as a proper movable,
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
        ViewLine(content, state, "No Vanguard data yet.", HEADCOL, 8, true)
        ViewLine(content, state,
            "Open the Vanguard website's Addon sync page, click Export, and copy the VGD1 code. " ..
            "Then open GaarVanguard's Import box (/gaarvanguard import), paste it, and click Import. " ..
            "This view fills in the moment you do.", MUTE, 8, false)
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

    -- Toolbar: quick access to the two copy/paste boxes without leaving the view.
    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetSize(70, 20); importBtn:SetPoint("TOPRIGHT", -34, -33); importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function() if _G.GaarVanguard_ShowImport then _G.GaarVanguard_ShowImport() end end)

    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(70, 20); exportBtn:SetPoint("TOPRIGHT", importBtn, "TOPLEFT", -6, 0); exportBtn:SetText("Export")
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
-- Import box (stub): parse a VGD1 sync string, store it, summarise it.
-- ---------------------------------------------------------------------------
local function ParseSync(str)
    str = tostring(str or "")
    str = string.gsub(str, "%s+", "")
    if str == "" then return nil, "nothing pasted" end
    if string.sub(str, 1, #PREFIX) == PREFIX then str = string.sub(str, #PREFIX + 1) end
    local json = Base64Decode(str)
    if not json or json == "" then return nil, "could not base64-decode" end
    local data, derr = JsonDecode(json)
    if not data then return nil, "could not parse JSON: " .. tostring(derr) end
    return data
end

-- A short human summary of a decoded sync document, used by the import box and chat.
local function SummariseSync(data)
    local lines = {}
    if type(data) ~= "table" then return "Decoded, but not an object." end
    lines[#lines + 1] = "Kind: " .. tostring(data.k or "?")
    local function listNames(label, list)
        if type(list) ~= "table" then return end
        local names = {}
        for _, item in ipairs(list) do
            if type(item) == "table" then
                names[#names + 1] = tostring(item.title or item.name or item.id or "?")
            else
                names[#names + 1] = tostring(item)
            end
        end
        lines[#lines + 1] = string.format("%s (%d): %s", label, #names,
            #names > 0 and table.concat(names, ", ") or "-")
    end
    listNames("Vanguards", data.vanguards)
    listNames("Goals", data.goals)
    listNames("Instances", data.instances)
    if data.mapping ~= nil then
        local n = 0
        if type(data.mapping) == "table" then for _ in pairs(data.mapping) do n = n + 1 end end
        lines[#lines + 1] = "Mapping entries: " .. n
    end
    return table.concat(lines, "\n")
end

local importFrame
local function ShowImport()
    if not importFrame then
        importFrame = MakeBox("GaarVanguardImport", "Import — paste the website's sync string", true)
        local btn = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
        btn:SetSize(80, 22); btn:SetPoint("BOTTOMRIGHT", -14, 12); btn:SetText("Import")
        btn:SetScript("OnClick", function()
            local data, err = ParseSync(importFrame.box:GetText())
            if not data then
                importFrame.status:SetText("|cffff6666Failed: " .. tostring(err) .. "|r")
                return
            end
            DB().sync = data
            local summary = SummariseSync(data)
            importFrame.status:SetText("|cff40ff40Stored under GaarVanguardDB.sync|r\n" .. summary)
            print("|cff5599ff" .. ADDON .. ":|r imported sync string.")
            for line in string.gmatch(summary, "[^\n]+") do print("  " .. line) end
            -- Phase 2: open/refresh the read-only view so the pasted data is
            -- visible immediately.
            if _G.GaarVanguard_ShowView then pcall(_G.GaarVanguard_ShowView) end
        end)
    end
    importFrame.box:SetText("")
    importFrame.status:SetText("|cff777777Paste the website's sync string, then Import.|r")
    importFrame:Show()
    importFrame.box:SetFocus()
end
_G.GaarVanguard_ShowImport = ShowImport

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
    -- Chat: the summary lines, so a glance is enough.
    print("|cff5599ff" .. ADDON .. ":|r profession + talent probe -")
    for _, l in ipairs(lines) do print(l) end
    -- Copyable box: the whole thing, to paste back to us.
    if not probeFrame then
        probeFrame = MakeBox("GaarVanguardProbe", "Profession + talent probe — ctrl-A, ctrl-C, paste this back", false)
    end
    probeFrame.box:SetText(table.concat(lines, "\n"))
    probeFrame.box:HighlightText()
    probeFrame:Show()
    probeFrame.box:SetFocus()
end
_G.GaarVanguard_ShowProbe = ShowProbe

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

    local importBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    importBtn:SetSize(160, 24); importBtn:SetPoint("TOPLEFT", 16, y)
    importBtn:SetText("Open import")
    importBtn:SetScript("OnClick", ShowImport)
    y = y - 34

    local recapBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    recapBtn:SetSize(160, 24); recapBtn:SetPoint("TOPLEFT", 16, y)
    recapBtn:SetText("Recapture now")

    local probeBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    probeBtn:SetSize(160, 24); probeBtn:SetPoint("TOPLEFT", 184, y)
    probeBtn:SetText("Probe prof + talents")
    probeBtn:SetScript("OnClick", ShowProbe)
    y = y - 34

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
    refreshCount()
    recapBtn:SetScript("OnClick", function() pcall(CaptureAll); refreshCount() end)
    y = y - 30

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(360); hint:SetJustifyH("LEFT")
    hint:SetText("Every character you log in on is added to one account-wide database and refreshed automatically. \"Export this char\" makes a full, reliable VGD1 string for the current character (all its data) - this is the primary export. \"Sync all (identity)\" makes a short VGD1 string listing every stored character with identity fields only, to populate the account pool. Both paste into the Vanguard website; Import parses the website's sync string back. The Vanguard view (also /gaarvanguard) shows that synced data in game: your Vanguards, their goals and status, the instance/readiness summary, and which of your characters each goal applies to.")
    y = y - 90

    container.gaarRefresh = refreshCount
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
local function Usage()
    print("|cff5599ff" .. ADDON .. "|r — commands:")
    print("  |cffffd100/gaarvanguard|r or |cffffd100/gaarvg|r — open the in-game Vanguard view (synced goals/instances)")
    print("  |cffffd100/gaarvanguard export|r — full VGD1 string for THIS character (the reliable, primary export)")
    print("  |cffffd100/gaarvanguard exportall|r — lightweight VGD1 string for ALL stored characters (identity only)")
    print("  |cffffd100/gaarvanguard import|r — paste the website's sync string back")
    print("  |cffffd100/gaarvanguard capture|r — recapture this character now")
    print("  |cffffd100/gaarvanguard probe|r — dump which profession + talent APIs this client exposes")
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
    elseif msg == "import" then
        ShowImport()
    elseif msg == "capture" or msg == "refresh" then
        pcall(CaptureAll)
        local c = CurrentChar()
        print("|cff5599ff" .. ADDON .. ":|r captured " .. (c and (c.name or "?") or "?") ..
            " (" .. (c and c.equipment and #c.equipment or 0) .. " equipped, " ..
            (c and c.loot and #c.loot or 0) .. " loot rows).")
    elseif msg == "probe" then
        pcall(ShowProbe)
    elseif msg == "config" or msg == "options" then
        OpenOptions()
    elseif msg == "wipe" then
        GaarVanguardDB = nil; DB()
        print("|cff5599ff" .. ADDON .. ":|r database cleared.")
    else
        Usage()
        ShowView()
    end
end
