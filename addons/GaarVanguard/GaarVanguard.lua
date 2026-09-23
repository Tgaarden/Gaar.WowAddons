--[[
  Gaar Vanguard — captures the account's characters and their loot and hands them to the
  Vanguard website as a copy-paste string. First draft.

  What it does
    * Records every character you log in on into an account-wide database keyed by
      "Name-Realm": name, realm, race, cls, lvl, faction, spec (from talent tabs / the
      retail specialization API), guild + rank, professions (the real primary + secondary trade
      skills with skill and max) and equipment (inventory slots 1-19, stored by canonical slot
      NAME). The
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

  The import (stub)
    The website hands back its own VGD1:<base64 JSON> with { k = "sync", ... } - vanguards,
    goals, instances and a mapping. For this first draft the Import box only proves the round
    trip: it base64-decodes and JSON-decodes the string, stores the result under
    GaarVanguardDB.sync and prints a short readable summary (goal titles, instance names). The
    full in-game UI comes later.

  Everything that reads the game API is wrapped in pcall so a call that is missing or shaped
  differently on one client degrades to "not captured" instead of erroring. The base64 and JSON
  codecs are self-contained here - no external libraries.

  /gaarvanguard prints usage and opens the export. Settings under Gaar -> Vanguard.
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

-- Modern path (retail and the retail-shaped Forever client): C_TradeSkillUI.GetProfessions gives
-- the profession skill-line INDICES directly (prof1, prof2, archaeology, fishing, cooking,
-- firstAid), so there is no header/enumeration problem and no filtering to do. GetProfessionInfo
-- turns each index into name, icon, skillLevel, maxSkillLevel, ...  Returns a list, or nil when
-- this API is not present on the client.
local function ScanProfessionsModern()
    local TSU = _G.C_TradeSkillUI
    if not TSU or type(TSU.GetProfessions) ~= "function" then return nil end
    if type(GetProfessionInfo) ~= "function" then return nil end
    local p1, p2, arch, fish, cook, firstaid = safe(TSU.GetProfessions)
    local indices = {}
    local function push(idx) if type(idx) == "number" and idx > 0 then indices[#indices + 1] = idx end end
    -- Pushed one at a time (not via a table literal) so a nil in the middle - e.g. a character
    -- with cooking but no primary profession - does not truncate the list.
    push(p1); push(p2); push(arch); push(fish); push(cook); push(firstaid)
    local out = {}
    for _, idx in ipairs(indices) do
        -- name, icon, skillLevel, maxSkillLevel, numAbilities, spellOffset, skillLine, ...
        local name, _, skillLevel, maxSkillLevel = safe(GetProfessionInfo, idx)
        if name and name ~= "" then
            out[#out + 1] = { name = name, skill = tonumber(skillLevel) or 0, max = tonumber(maxSkillLevel) or 0 }
        end
    end
    return out
end

-- Re-collapse one header found by name, re-scanning fresh each call so a shifting index (every
-- collapse renumbers the rows after it) never collapses the wrong row.
local function CollapseSkillHeaderByName(name)
    if type(CollapseSkillHeader) ~= "function" or type(GetNumSkillLines) ~= "function" then return end
    local n = safe(GetNumSkillLines) or 0
    for i = 1, n do
        local hname, isHeader = safe(GetSkillLineInfo, i)
        if isHeader and hname == name then safe(CollapseSkillHeader, i); return end
    end
end

-- Classic fallback (Era, and any client without C_TradeSkillUI): GetNumSkillLines +
-- GetSkillLineInfo. The trap this addon originally hit: a COLLAPSED skill header hides its child
-- skill lines from enumeration entirely, so a profession under a collapsed header reads as
-- absent - which is why the list came back empty. Expand every header first (ExpandSkillHeader(0)),
-- read, then restore the headers that were collapsed so the player's Skills window is left as it
-- was. Returns a list, or nil when the API is not present.
local function ScanProfessionsClassic()
    if type(GetNumSkillLines) ~= "function" or type(GetSkillLineInfo) ~= "function" then return nil end
    -- Remember which headers were collapsed, then expand all so their children enumerate.
    local collapsed = {}
    if type(ExpandSkillHeader) == "function" then
        local n0 = safe(GetNumSkillLines) or 0
        for i = 1, n0 do
            local name, isHeader, isExpanded = safe(GetSkillLineInfo, i)
            if isHeader and isExpanded == false then collapsed[#collapsed + 1] = name end
        end
        safe(ExpandSkillHeader, 0) -- 0 == all headers
    end
    local count = safe(GetNumSkillLines) or 0
    local out = {}
    for i = 1, count do
        -- name, isHeader, isExpanded, rank, numTempPoints, modifier, maxRank, ...
        local name, isHeader, _, rank, _, _, maxRank = safe(GetSkillLineInfo, i)
        if name and not isHeader and PROFESSION_NAMES[name] then
            -- Canonical: `skill` (was `rank`) plus `max`.
            out[#out + 1] = { name = name, skill = tonumber(rank) or 0, max = tonumber(maxRank) or 0 }
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
        pcall(function() CaptureSpec(CurrentChar()) end)
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
        equipment = {},
        loot = {},
    }
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
        end)
    end
    importFrame.box:SetText("")
    importFrame.status:SetText("|cff777777Paste the website's sync string, then Import.|r")
    importFrame:Show()
    importFrame.box:SetFocus()
end
_G.GaarVanguard_ShowImport = ShowImport

-- ---------------------------------------------------------------------------
-- Options panel (Gaar -> Vanguard)
-- ---------------------------------------------------------------------------
function GaarVanguard_BuildOptions(container)
    local y = -8
    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("Vanguard — character & loot export")
    y = y - 30

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
    hint:SetText("Every character you log in on is added to one account-wide database and refreshed automatically. Export drops the whole account into a VGD1 string to paste into the Vanguard website; import parses the website's sync string back. This is a first draft: the import box proves the round trip and stores the result, the full in-game view comes later.")
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
    print("  |cffffd100/gaarvanguard|r or |cffffd100/gaarvg|r — this help, and opens the export box")
    print("  |cffffd100/gaarvanguard export|r — the VGD1 string to paste into the website")
    print("  |cffffd100/gaarvanguard import|r — paste the website's sync string back")
    print("  |cffffd100/gaarvanguard capture|r — recapture this character now")
    print("  |cffffd100/gaarvanguard config|r — settings under Gaar -> Vanguard")
    print("  |cffffd100/gaarvanguard wipe|r — clear the whole database")
end

SLASH_GAARVANGUARD1 = "/gaarvanguard"
SLASH_GAARVANGUARD2 = "/gaarvg"
SlashCmdList["GAARVANGUARD"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "export" then
        ShowExport()
    elseif msg == "import" then
        ShowImport()
    elseif msg == "capture" or msg == "refresh" then
        pcall(CaptureAll)
        local c = CurrentChar()
        print("|cff5599ff" .. ADDON .. ":|r captured " .. (c and (c.name or "?") or "?") ..
            " (" .. (c and c.equipment and #c.equipment or 0) .. " equipped, " ..
            (c and c.loot and #c.loot or 0) .. " loot rows).")
    elseif msg == "config" or msg == "options" then
        OpenOptions()
    elseif msg == "wipe" then
        GaarVanguardDB = nil; DB()
        print("|cff5599ff" .. ADDON .. ":|r database cleared.")
    else
        Usage()
        ShowExport()
    end
end
