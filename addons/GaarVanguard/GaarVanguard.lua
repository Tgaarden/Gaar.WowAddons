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

  The export
    /gaarvanguard (or the Export button) opens a box holding

        VGD1:<base64 of a JSON document>

    where the JSON is { k = "chars", chars = [ <every account character, with its fields and
    loot> ] }. Select all (ctrl-A), copy (ctrl-C) and paste it into the website's
    "Import everything". The website is the counterpart to this addon.

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

  /gaarvanguard opens the Vanguard view (subcommands: export, import, capture, probe, config,
  wipe). Settings under Gaar -> Vanguard.
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
local function Identify()
    ME = (UnitName and UnitName("player")) or ME
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

-- Spec: retail exposes it through GetSpecialization/GetSpecializationInfo; the Vanilla talent
-- system (Classic Era, and the Vanilla-content Forever client) derives it from the talent tab
-- with the most points spent. Both paths are optional and tried in turn, so a client that has
-- one but not the other still reports a spec. A character with no points spent legitimately has
-- no spec - we never invent one.
local function CaptureSpec(c)
    -- Retail specialization API. On the Vanilla-content Forever client this usually answers with
    -- nothing (no retail specs), so we fall through to the talent-tab reader below.
    if type(GetSpecialization) == "function" and type(GetSpecializationInfo) == "function" then
        local idx = safe(GetSpecialization)
        if type(idx) == "number" and idx > 0 then
            local _, specName = safe(GetSpecializationInfo, idx)
            if specName and specName ~= "" then c.spec = specName; return end
        end
    end
    -- Vanilla talent tabs: the tab with the most points spent is the character's "spec".
    -- GetTalentTabInfo is the classic reader (name, icon, pointsSpent, ...); present on Era and,
    -- because Forever runs Vanilla talent trees, on Forever too.
    if type(GetNumTalentTabs) == "function" and type(GetTalentTabInfo) == "function" then
        local tabs = safe(GetNumTalentTabs) or 0
        local best, bestPts = nil, -1
        for i = 1, tabs do
            -- Classic: name, iconTexture, pointsSpent, ...
            local name, _, pts = safe(GetTalentTabInfo, i)
            pts = tonumber(pts) or 0
            if name and pts > bestPts then best, bestPts = name, pts end
        end
        if best and bestPts > 0 then c.spec = best end
    end
end

-- The FULL talent build, so the website can draw the whole tree, not just the spec name.
-- Captured live at capture/export exactly like professions/equipment (the Forever beta does not
-- persist SavedVariables, so a cached build cannot be trusted). Tried in order, all pcall-guarded,
-- using whichever API the client actually exposes:
--
--   1. Classic talent API (Era, and the Vanilla-content Forever client - by far the likely path).
--      GetNumTalentTabs() + GetTalentTabInfo(tab) -> name, icon, pointsSpent; then
--      GetNumTalents(tab) + GetTalentInfo(tab, i) -> name, icon, tier, column, rank, maxRank, ...
--      (the classic signature). ALL talents are kept, including rank-0 ones, so the tree is
--      complete; ranks are always included so a 0-rank talent shows as 0. Tabs are ordered by tab
--      index; talents within a tab by tier then column.
--   2. Fallbacks, if the classic globals are missing: the retail namespaces. We cannot reconstruct
--      a Vanilla-style tier/column tree from C_Traits/C_ClassTalents, so there we only resolve the
--      spec name (C_SpecializationInfo / GetSpecialization) and leave the build empty; the talent
--      probe reports which namespace exists so we can extend this if Forever ever needs it.
--
-- Shape written to c.talents (mirrored in the export and docs/gaarvanguard.md):
--   talents = { { tab = <tabName>, points = <pointsSpent>,
--                 talents = { { name, rank, max, tier, col }, ... } }, ... }
-- An empty scan leaves any previously captured build in place rather than wiping it.
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
    local build = ScanTalentsClassic()
    if build and #build > 0 then
        c.talents = build
        -- Backstop the spec from the build if CaptureSpec did not already resolve one: the tab
        -- with the most points spent. Never invent a spec when nothing is spent.
        if not c.spec or c.spec == "" then
            local best, bestPts = nil, 0
            for _, t in ipairs(build) do
                if (t.points or 0) > bestPts then best, bestPts = t.tab, t.points end
            end
            if best and bestPts > 0 then c.spec = best end
        end
    else
        -- No classic talent API. Leave any previously captured build untouched; the probe reports
        -- which retail namespace (if any) exists so this can be extended when we have live data.
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
                }
                if type(tabRec.talents) == "table" then
                    for _, t in ipairs(tabRec.talents) do
                        tabOut.talents[#tabOut.talents + 1] = {
                            name = t.name,
                            rank = tonumber(t.rank) or 0,
                            max = tonumber(t.max) or 0,
                            tier = tonumber(t.tier) or 0,
                            col = tonumber(t.col) or 0,
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

local function BuildExportString()
    -- Fresh full scan of the CURRENT character right now, before building the string. The beta
    -- does not persist SavedVariables and equipment events may not have fired, so we never trust
    -- cached data for the live character - we re-read level/class/guild/spec/professions and
    -- loop the equip slots live here.
    safe(CaptureAll)
    local chars = {}
    for _, c in pairs(DB().chars) do chars[#chars + 1] = CanonicalChar(c) end
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
        exportFrame = MakeBox("GaarVanguardExport", "Export — ctrl-A, ctrl-C, paste into the website", false)
    end
    exportFrame.box:SetText(BuildExportString())
    exportFrame.box:HighlightText()
    exportFrame:Show()
    exportFrame.box:SetFocus()
end
_G.GaarVanguard_ShowExport = ShowExport

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

    -- 2. Retail / newer namespaces (fallbacks we detect but cannot yet map to a Vanilla tree).
    add("")
    add("-- retail talent/spec namespaces --")
    add("GetSpecialization       = " .. TypeOf(_G.GetSpecialization))
    add("GetSpecializationInfo   = " .. TypeOf(_G.GetSpecializationInfo))
    for _, ns in ipairs({ "C_Traits", "C_ClassTalents", "C_SpecializationInfo" }) do
        add(ns .. string.rep(" ", 22 - #ns) .. "= " .. TypeOf(_G[ns]))
    end

    -- 3. What the addon would actually export for this character right now.
    add("")
    add("-- resolved talent export --")
    local probeChar = {}
    safe(CaptureSpec, probeChar)
    safe(CaptureTalents, probeChar)
    add("namespace used: " .. (classicOK and "classic (GetTalentInfo)" or "none (classic missing)"))
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

local probeFrame
local function ShowProbe()
    local lines = ProbeProfessionsLines()
    -- Append the talent probe so one command dumps both, non-spammy.
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
    exportBtn:SetText("Open export")
    exportBtn:SetScript("OnClick", ShowExport)

    local importBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    importBtn:SetSize(160, 24); importBtn:SetPoint("TOPLEFT", 184, y)
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
    hint:SetText("Every character you log in on is added to one account-wide database and refreshed automatically. Export drops the whole account into a VGD1 string to paste into the Vanguard website; Import parses the website's sync string back. The Vanguard view (also /gaarvanguard) shows that synced data in game: your Vanguards, their goals and status, the instance/readiness summary, and which of your characters each goal applies to.")
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
    print("  |cffffd100/gaarvanguard export|r — the VGD1 string to paste into the website")
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
