--[[
  Gaar Looter — a personal loot library for WoW Classic Era. Phase 1.

  What it records
    * Every group-loot roll: the item, who took part, what each of them chose, the numbers
      they rolled, who won, and when/where.
    * Everything else you acquire: items looted and money gained. Stored one row per event;
      grouping happens when it is displayed, never at collection. Every row keeps Blizzard's
      own classID/subclassID, so categories like Trade Goods, Consumable and Recipe come for
      free at display time rather than from a hand-kept list.
    * A neutral note when someone needs an item their class cannot use the armour or weapon
      type of. Logged as an observation, not a verdict - off-spec need is legitimate and spec
      relevance is not something the client can determine.

  A correction to the brief this was built from: START_LOOT_ROLL does hand over the item
  directly, but no event reports OTHER players' need/greed/pass, their roll numbers or the
  winner. That only reaches the client as chat lines built from the LOOT_ROLL_* global format
  strings, so those are parsed here. The part that would have been fragile - correlating by
  time - is still avoided: every one of those lines names the item, so rolls are matched by
  item link against the roll that START_LOOT_ROLL opened.

  The patterns are derived from the global strings at load rather than hardcoded in English,
  so this follows the client's locale. (Locales that reorder arguments with "%1$s" are not
  handled yet.)

  The log window has five views: Rolls (chronological), Players (each person's history across
  every roll), Sessions (rolls bundled into runs by zone and time gaps), Items (grouped under
  Blizzard's own categories) and Money. All of them take the search box, and Export drops the
  current view into a box you can copy out.

  /gaarlooter opens the log. Settings under Gaar -> Looter.
]]

local _G = _G

-- Same move as in GaarBags: the item lookups live in C_Item now, and Forever has dropped the
-- old global names entirely. One local here keeps every call site below unchanged.
local C_Item = _G.C_Item
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
local ADDON = "Gaar Looter"
local FLAT = "Interface\\Buttons\\WHITE8x8"

local function DB()
    if type(GaarLooterDB) ~= "table" then GaarLooterDB = {} end
    local d = GaarLooterDB
    if d.rolls == nil then d.rolls = {} end       -- one row per completed roll
    if d.items == nil then d.items = {} end       -- one row per item acquired
    if d.money == nil then d.money = {} end       -- one row per money change
    if d.trackLoot == nil then d.trackLoot = true end
    if d.trackMoney == nil then d.trackMoney = true end
    if d.maxRows == nil then d.maxRows = 5000 end
    if d.chars == nil then d.chars = {} end          -- [character] = realm, for "is this me"
    if d.onlyThisChar == nil then d.onlyThisChar = false end
    return d
end

-- Who wrote a row. The log is account-wide on purpose - a library is worth more across
-- characters than split per character - but that only works if each row says where it came
-- from, otherwise the items and money views merge into something unattributable.
local ME, REALM = nil, nil
local function Identify()
    ME = UnitName("player")
    REALM = (GetRealmName and GetRealmName()) or "?"
    if ME then
        local d = DB()
        d.chars = d.chars or {}
        d.chars[ME] = REALM
    end
end

local function Trim(list, maxRows)
    while #list > maxRows do table.remove(list, 1) end
end

-- ---------------------------------------------------------------------------
-- Turning Blizzard's format strings into patterns
-- ---------------------------------------------------------------------------
local function Pattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = string.gsub(fmt, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = string.gsub(p, "%%%%s", "(.-)")
    p = string.gsub(p, "%%%%d", "(%%d+)")
    return "^" .. p .. "$"
end

-- Each entry: the pattern, and what its captures mean, in order.
local function Rule(globalName, kind, fields)
    local fmt = _G[globalName]
    local p = Pattern(fmt)
    if not p then return nil end
    return { pattern = p, kind = kind, fields = fields }
end

local ROLL_RULES = {}
local function AddRollRule(globalName, kind, fields)
    local r = Rule(globalName, kind, fields)
    if r then ROLL_RULES[#ROLL_RULES + 1] = r end
end

-- "%s has selected Need for: %s" and friends
AddRollRule("LOOT_ROLL_NEED", "choice", { "player", "item", choice = "need" })
AddRollRule("LOOT_ROLL_GREED", "choice", { "player", "item", choice = "greed" })
AddRollRule("LOOT_ROLL_DISENCHANT", "choice", { "player", "item", choice = "disenchant" })
AddRollRule("LOOT_ROLL_PASSED", "choice", { "player", "item", choice = "pass" })
-- "%s has rolled %d for: %s"
AddRollRule("LOOT_ROLL_ROLLED_NEED", "rolled", { "player", "roll", "item", choice = "need" })
AddRollRule("LOOT_ROLL_ROLLED_GREED", "rolled", { "player", "roll", "item", choice = "greed" })
AddRollRule("LOOT_ROLL_ROLLED_DE", "rolled", { "player", "roll", "item", choice = "disenchant" })
-- outcome
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

-- ---------------------------------------------------------------------------
-- Who is in the group, and what can their class actually use
-- ---------------------------------------------------------------------------
local classByName = {}
local function RefreshRoster()
    local me = UnitName("player")
    local _, myClass = UnitClass("player")
    if me then classByName[me] = myClass end
    if IsInRaid and IsInRaid() then
        local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
        for i = 1, n do
            local nm = UnitName("raid" .. i); local _, cl = UnitClass("raid" .. i)
            if nm then classByName[nm] = cl end
        end
    else
        local n = (GetNumSubgroupMembers and GetNumSubgroupMembers()) or 0
        for i = 1, n do
            local nm = UnitName("party" .. i); local _, cl = UnitClass("party" .. i)
            if nm then classByName[nm] = cl end
        end
    end
end

-- Highest armour subclass each class can ever wear (1 cloth, 2 leather, 3 mail, 4 plate).
-- Level gating is deliberately ignored: this answers "could this class ever use it".
local ARMOR_CAP = {
    WARRIOR = 4, PALADIN = 4,
    HUNTER = 3, SHAMAN = 3,
    ROGUE = 2, DRUID = 2,
    MAGE = 1, PRIEST = 1, WARLOCK = 1,
}

-- Weapon subclasses each class can learn, by the item subclass id.
-- 0 axe1h, 1 axe2h, 2 bow, 3 gun, 4 mace1h, 5 mace2h, 6 polearm, 7 sword1h, 8 sword2h,
-- 10 staff, 13 fist, 15 dagger, 16 thrown, 18 crossbow, 19 wand, 20 fishing pole
local WEAPONS = {
    WARRIOR = { [0]=1,[1]=1,[2]=1,[3]=1,[4]=1,[5]=1,[6]=1,[7]=1,[8]=1,[10]=1,[13]=1,[15]=1,[16]=1,[18]=1 },
    PALADIN = { [0]=1,[1]=1,[4]=1,[5]=1,[6]=1,[7]=1,[8]=1 },
    HUNTER  = { [0]=1,[1]=1,[2]=1,[3]=1,[6]=1,[7]=1,[8]=1,[10]=1,[13]=1,[15]=1,[16]=1,[18]=1 },
    ROGUE   = { [0]=1,[2]=1,[3]=1,[4]=1,[7]=1,[13]=1,[15]=1,[16]=1,[18]=1 },
    PRIEST  = { [4]=1,[10]=1,[15]=1,[19]=1 },
    SHAMAN  = { [0]=1,[1]=1,[4]=1,[5]=1,[10]=1,[13]=1,[15]=1 },
    MAGE    = { [7]=1,[10]=1,[15]=1,[19]=1 },
    WARLOCK = { [7]=1,[10]=1,[15]=1,[19]=1 },
    DRUID   = { [4]=1,[5]=1,[6]=1,[10]=1,[13]=1,[15]=1 },
}

-- Returns a neutral note when the class cannot use this item's armour or weapon type,
-- or nil. Deliberately no boolean verdict: a name like "ninja" invites being shared as one.
local function ProficiencyNote(itemLink, class)
    if not itemLink or not class then return nil end
    if not GetItemInfoInstant then return nil end
    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(itemLink)
    if not classID then return nil end
    if classID == 4 then                      -- Armor
        local cap = ARMOR_CAP[class]
        -- subclass 0 is misc (rings, trinkets, necks): no proficiency involved
        if cap and subclassID and subclassID >= 1 and subclassID <= 4 and subclassID > cap then
            local names = { "cloth", "leather", "mail", "plate" }
            return "needed on " .. (names[subclassID] or "?") ..
                ", outside this class's armour proficiency"
        end
    elseif classID == 2 then                  -- Weapon
        local allowed = WEAPONS[class]
        if allowed and subclassID and subclassID ~= 20 and not allowed[subclassID] then
            return "needed on a weapon type this class cannot equip"
        end
    end
    return nil
end

local function GroupType()
    if IsInRaid and IsInRaid() then return "raid" end
    if IsInGroup and IsInGroup() then return "party" end
    return "solo"
end

local function Zone()
    return (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or "?"
end

-- ---------------------------------------------------------------------------
-- Roll tracking
-- ---------------------------------------------------------------------------
local pending = {}      -- [itemLink] = roll record being filled in
local byRollID = {}     -- [rollID] = itemLink, so our own choice can be attached

local function NewRoll(itemLink, rollID)
    return {
        time = time(), itemLink = itemLink, rollID = rollID,
        zone = Zone(), group = GroupType(),
        players = {},      -- [name] = { choice, roll, class, note }
        order = {},        -- names, in the order they appeared
        started = GetTime(),
    }
end

local function Participant(roll, name)
    local p = roll.players[name]
    if not p then
        p = { name = name, class = classByName[name] }
        roll.players[name] = p
        roll.order[#roll.order + 1] = name
    end
    return p
end

local function CommitRoll(roll)
    if roll.committed then return end
    roll.committed = true
    local d = DB()
    local row = {
        time = roll.time, itemLink = roll.itemLink, itemID = roll.itemID,
        quality = roll.quality, zone = roll.zone, group = roll.group,
        char = ME, realm = REALM,
        winner = roll.winner, winnerRoll = roll.winnerRoll, myChoice = roll.myChoice,
        players = {},
    }
    -- Your own roll number arrives in the same chat lines as everyone else's, so it is simply
    -- read back off your participant entry.
    local me = UnitName("player")
    local mine = me and roll.players[me]
    if mine then
        row.myRoll = mine.roll
        row.myChoice = row.myChoice or mine.choice
    end
    for _, name in ipairs(roll.order) do
        local p = roll.players[name]
        row.players[#row.players + 1] = {
            name = name, choice = p.choice, roll = p.roll, class = p.class, note = p.note,
        }
    end
    d.rolls[#d.rolls + 1] = row
    Trim(d.rolls, d.maxRows)
    pending[roll.itemLink] = nil
    if roll.rollID then byRollID[roll.rollID] = nil end
end

local function HandleRollMessage(msg)
    local m = MatchRules(ROLL_RULES, msg)
    if not m then return end

    -- "You won: %s" carries no name, so fill in ours.
    local itemLink = m.item
    if not itemLink then return end
    local roll = pending[itemLink]
    if not roll then
        -- A roll we never saw start (joined late, or the window was already open).
        roll = NewRoll(itemLink, nil)
        pending[itemLink] = roll
    end

    if m.kind == "choice" or m.kind == "rolled" then
        local p = Participant(roll, m.player)
        p.class = p.class or classByName[m.player]
        if m.choice then p.choice = m.choice end
        if m.roll then p.roll = tonumber(m.roll) end
        if p.choice == "need" and not p.note then
            p.note = ProficiencyNote(itemLink, p.class)
        end
    elseif m.kind == "won" then
        roll.winner = m.player
        local p = roll.players[m.player]
        roll.winnerRoll = p and p.roll
        CommitRoll(roll)
    elseif m.kind == "wonself" then
        roll.winner = UnitName("player")
        local p = roll.players[roll.winner]
        roll.winnerRoll = p and p.roll
        CommitRoll(roll)
    elseif m.kind == "allpassed" then
        roll.winner = nil
        CommitRoll(roll)
    end
end

-- Our own choice comes from the API rather than from chat, so the self-worded strings
-- never need special handling.
if type(RollOnLoot) == "function" then
    hooksecurefunc("RollOnLoot", function(rollID, rollType)
        local link = byRollID[rollID]
        local roll = link and pending[link]
        if not roll then return end
        roll.myChoice = (rollType == 1 and "need") or (rollType == 2 and "greed")
            or (rollType == 3 and "disenchant") or "pass"
    end)
end

-- ---------------------------------------------------------------------------
-- Acquisitions
-- ---------------------------------------------------------------------------
local lastMoney = nil
local moneyFromChat = nil     -- set briefly by CHAT_MSG_MONEY so the diff can be attributed

local function RecordItem(itemLink, count, source)
    if not DB().trackLoot or not itemLink then return end
    local d = DB()
    local itemID, _, _, _, _, classID, subclassID = nil, nil, nil, nil, nil, nil, nil
    if GetItemInfoInstant then
        itemID, _, _, _, _, classID, subclassID = GetItemInfoInstant(itemLink)
    end
    -- Quality deliberately not stored: GetItemInfo is asynchronous and returns nil for an
    -- item the client hasn't cached yet, which would have frozen a nil into the log. The link
    -- is enough to resolve it at display time, by which point it is always cached.
    d.items[#d.items + 1] = {
        time = time(), itemLink = itemLink, itemID = itemID, count = tonumber(count) or 1,
        source = source, zone = Zone(), group = GroupType(),
        classID = classID, subclassID = subclassID, char = ME, realm = REALM,
    }
    Trim(d.items, d.maxRows)
end

local function RecordMoney(delta, source)
    if not DB().trackMoney or not delta or delta == 0 then return end
    local d = DB()
    d.money[#d.money + 1] = {
        time = time(), delta = delta, source = source, zone = Zone(), group = GroupType(),
        char = ME, realm = REALM,
    }
    Trim(d.money, d.maxRows)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
local EVENTS = {
    "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD",
    "START_LOOT_ROLL", "CANCEL_LOOT_ROLL",
    "CHAT_MSG_LOOT", "CHAT_MSG_SYSTEM", "CHAT_MSG_MONEY", "PLAYER_MONEY",
    "GROUP_ROSTER_UPDATE",
}
for _, e in ipairs(EVENTS) do pcall(ev.RegisterEvent, ev, e) end

ev:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        Identify()
        RefreshRoster()
        lastMoney = GetMoney()
        return
    end

    if event == "GROUP_ROSTER_UPDATE" then
        RefreshRoster()
        return
    end

    if event == "START_LOOT_ROLL" then
        local rollID = a1
        local link = GetLootRollItemLink and GetLootRollItemLink(rollID)
        if not link then return end
        local roll = pending[link] or NewRoll(link, rollID)
        roll.rollID = rollID
        if GetLootRollItemInfo then
            local _, _, _, quality = GetLootRollItemInfo(rollID)
            roll.quality = quality
        end
        if GetItemInfoInstant then roll.itemID = GetItemInfoInstant(link) end
        pending[link] = roll
        byRollID[rollID] = link
        RefreshRoster()
        return
    end

    if event == "CANCEL_LOOT_ROLL" then
        -- The window closed for us; the result lines may still be coming, so the roll is left
        -- pending and the sweeper below commits it if nothing more arrives.
        return
    end

    if event == "CHAT_MSG_LOOT" or event == "CHAT_MSG_SYSTEM" then
        -- Which channel carries the roll lines varies by client version, so both are read.
        local msg = a1
        HandleRollMessage(msg)
        if event == "CHAT_MSG_LOOT" then
            local m = MatchRules(LOOT_RULES, msg)
            if m and m.selfLoot and m.item then RecordItem(m.item, m.count, "loot") end
        end
        return
    end

    if event == "CHAT_MSG_MONEY" then
        -- Arrives just before PLAYER_MONEY and marks the gain as a group split or a loot share.
        moneyFromChat = "loot"
        return
    end

    if event == "PLAYER_MONEY" then
        local now = GetMoney()
        if lastMoney then
            local delta = now - lastMoney
            RecordMoney(delta, moneyFromChat or (delta > 0 and "gain" or "spend"))
        end
        lastMoney = now
        moneyFromChat = nil
        return
    end

end)

-- A roll whose result line never arrived (out of range, left the group) would sit in `pending`
-- forever, so anything older than two minutes is written out with whatever was captured.
local sweeper = CreateFrame("Frame")
local sweepAcc = 0
sweeper:SetScript("OnUpdate", function(_, elapsed)
    sweepAcc = sweepAcc + elapsed
    if sweepAcc < 5 then return end
    sweepAcc = 0
    local now = GetTime()
    for link, roll in pairs(pending) do
        if now - (roll.started or now) > 120 then CommitRoll(roll) end
    end
end)

-- ---------------------------------------------------------------------------
-- Display: rows are stored per item, so every grouping happens here
-- ---------------------------------------------------------------------------
local CHOICE_COLOR = {
    need = "|cff40ff40", greed = "|cffffd100", pass = "|cff888888", disenchant = "|cff66ccff",
}

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
    return "|cffcccccc"
end

local function Money(copper)
    copper = math.abs(copper or 0)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, c) end
    if s > 0 then return string.format("%ds %dc", s, c) end
    return string.format("%dc", c)
end

local function Stamp(t)
    return date("%d.%m %H:%M", t or 0)
end

-- GetItemInfoInstant is synchronous, so an icon is always available straight from the link -
-- unlike GetItemInfo, which returns nil until the client has cached the item.
local function ItemIcon(link)
    if not link or not GetItemInfoInstant then return nil end
    local _, _, _, _, icon = GetItemInfoInstant(link)
    return icon
end

-- The account-wide log can be narrowed to the character you are on. Rows written before
-- this stamping existed have no character, so they are kept rather than silently hidden.
local charFilter = nil      -- nil shows every character; otherwise just this one

local function MineRow(row)
    if not charFilter then return true end
    -- Rows written before characters were stamped have no owner. They stay visible under
    -- "All", but naming a character shouldn't claim them.
    return row.char == charFilter
end

-- Every character that has written to the log, plus the one you are on even if it hasn't yet.
local function KnownChars()
    local seen, out = {}, {}
    for name in pairs(DB().chars or {}) do seen[name] = true end
    for _, list in ipairs({ DB().rolls, DB().items, DB().money }) do
        for _, row in ipairs(list) do
            if row.char then seen[row.char] = true end
        end
    end
    if ME then seen[ME] = true end
    for name in pairs(seen) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- Account-wide, a row that doesn't say who acquired it is unattributable. Narrowed to one
-- character the tag would be the same name on every line, so it is left off there.
local function CharTag(names)
    if DB().onlyThisChar or #names == 0 then return "" end
    table.sort(names)
    return "  |cff888888" .. table.concat(names, ", ") .. "|r"
end

-- Aggregate the per-item rows into one line per item, grouped under Blizzard's own category
-- names. The categories are read back from the link at display time rather than stored, so a
-- row keeps working even if what it is called changes.
local function AggregateItems()
    local byItem, order = {}, {}
    for _, row in ipairs(DB().items) do
      if MineRow(row) then
        local key = row.itemLink or "?"
        local e = byItem[key]
        if not e then
            local itemType, itemSubType
            if GetItemInfoInstant and row.itemLink then
                local _, t, st = GetItemInfoInstant(row.itemLink)
                itemType, itemSubType = t, st
            end
            e = { link = key, count = 0, last = 0, classID = row.classID,
                  subclassID = row.subclassID, category = itemType or "Other",
                  subcategory = itemSubType, sources = {}, chars = {} }
            byItem[key] = e
            order[#order + 1] = e
        end
        e.count = e.count + (row.count or 1)
        if (row.time or 0) > e.last then e.last = row.time end
        e.sources[row.source or "?"] = (e.sources[row.source or "?"] or 0) + 1
        if row.char then e.chars[row.char] = true end
      end
    end
    -- category first, then the most recent inside it
    table.sort(order, function(a, b)
        if a.category ~= b.category then return a.category < b.category end
        return a.last > b.last
    end)
    return order
end

local frame, listing, scrollRow, mode = nil, {}, 0, "rolls"
local filter = ""

-- Plain text for export: colour codes, textures and link markup out, item names kept.
local function Plain(text)
    text = string.gsub(text or "", "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    text = string.gsub(text, "|T.-|t", "")
    text = string.gsub(text, "|H.-|h%[(.-)%]|h", "%1")
    text = string.gsub(text, "|H.-|h(.-)|h", "%1")
    return text
end

local function Hit(...)
    if filter == "" then return true end
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v and string.find(string.lower(Plain(tostring(v))), filter, 1, true) then return true end
    end
    return false
end


-- A roll as display entries, shared by the Rolls and Sessions views. Entries are structured
-- rather than pre-baked strings so the renderer can put a real icon next to each one and hang
-- a tooltip off the item link.
local function RollEntries(r, out, indent)
    indent = indent or 0
    local icon = r.itemLink and ItemIcon(r.itemLink)
    local right
    if r.winner then
        right = string.format("|cff40ff40%s|r%s", r.winner,
            r.winnerRoll and (" |cffffffff" .. r.winnerRoll .. "|r") or "")
    else
        right = "|cff888888nobody|r"
    end
    out[#out + 1] = {
        header = true, indent = indent, icon = icon, link = r.itemLink,
        text = string.format("|cff777777%s|r  %s", Stamp(r.time), r.itemLink or "?"),
        right = right,
    }
    for _, p in ipairs(r.players or {}) do
        local col = CHOICE_COLOR[p.choice or ""] or "|cffcccccc"
        local line = string.format("%s%s|r  %s%s|r", ClassColor(p.class), p.name, col, p.choice or "?")
        if p.note then line = line .. "  |cffff9966" .. p.note .. "|r" end
        out[#out + 1] = {
            indent = indent + 1, classIcon = p.class, text = line,
            right = p.roll and ("|cffffffff" .. p.roll .. "|r") or nil,
        }
    end
end

local function AggregatePlayers()
    local byName, order = {}, {}
    for _, r in ipairs(DB().rolls) do
      if MineRow(r) then
        for _, p in ipairs(r.players or {}) do
            local e = byName[p.name]
            if not e then
                e = { name = p.name, class = p.class, rolls = 0, wins = 0, notes = 0,
                      need = 0, greed = 0, pass = 0, disenchant = 0, last = 0 }
                byName[p.name] = e
                order[#order + 1] = e
            end
            e.class = e.class or p.class
            e.rolls = e.rolls + 1
            if p.choice and e[p.choice] then e[p.choice] = e[p.choice] + 1 end
            if p.note then e.notes = e.notes + 1 end
            if (r.time or 0) > e.last then e.last = r.time end
            if r.winner == p.name then e.wins = e.wins + 1 end
        end
      end
    end
    table.sort(order, function(a, b)
        if a.rolls ~= b.rolls then return a.rolls > b.rolls end
        return a.name < b.name
    end)
    return order
end

-- A session is a run of rolls in the same zone with no long gap between them, which is close
-- enough to "one dungeon run" without needing anything the log doesn't already store.
local SESSION_GAP = 45 * 60

local function AggregateSessions()
    local sessions = {}
    local current = nil
    for _, r in ipairs(DB().rolls) do          -- stored oldest first
      if MineRow(r) then
        if current and r.zone == current.zone and (r.time - current.last) <= SESSION_GAP then
            current.last = r.time
            current.rolls[#current.rolls + 1] = r
        else
            current = { zone = r.zone or "?", first = r.time, last = r.time, rolls = { r } }
            sessions[#sessions + 1] = current
        end
      end
    end
    return sessions
end

local function Lines()
    local out = {}
    if mode == "rolls" then
        local rolls = DB().rolls
        for i = #rolls, 1, -1 do
            local r = rolls[i]
            -- the filter keeps or drops a whole roll, so a hit on one participant still
            -- shows the context it happened in
            local keep = MineRow(r) and Hit(r.itemLink, r.winner, r.zone)
            if MineRow(r) and not keep then
                for _, p in ipairs(r.players or {}) do
                    if Hit(p.name) then keep = true; break end
                end
            end
            if keep then RollEntries(r, out) end
        end

    elseif mode == "players" then
        for _, e in ipairs(AggregatePlayers()) do
            if Hit(e.name) then
                local winPct = e.rolls > 0 and (e.wins / e.rolls * 100) or 0
                local you = DB().chars[e.name] and "  |cff66ccff(you)|r" or ""
                out[#out + 1] = {
                    header = true, classIcon = e.class,
                    text = string.format("%s%s|r%s", ClassColor(e.class), e.name, you),
                    right = string.format("|cffffffff%d|r|cff777777 rolls|r  |cff40ff40%d|r |cff777777(%.0f%%)|r",
                        e.rolls, e.wins, winPct),
                }
                out[#out + 1] = {
                    indent = 1,
                    text = string.format("|cff40ff40need %d|r  |cffffd100greed %d|r  |cff888888pass %d|r%s",
                        e.need, e.greed, e.pass,
                        e.notes > 0 and string.format("  |cffff9966%d outside proficiency|r", e.notes) or ""),
                    right = "|cff777777" .. Stamp(e.last) .. "|r",
                }
            end
        end

    elseif mode == "sessions" then
        local sessions = AggregateSessions()
        for i = #sessions, 1, -1 do
            local sess = sessions[i]
            local keep = Hit(sess.zone)
            if not keep then
                for _, r in ipairs(sess.rolls) do
                    if Hit(r.itemLink, r.winner) then keep = true; break end
                    for _, p in ipairs(r.players or {}) do
                        if Hit(p.name) then keep = true; break end
                    end
                    if keep then break end
                end
            end
            if keep then
                local mins = math.max(1, math.floor((sess.last - sess.first) / 60))
                out[#out + 1] = {
                    header = true, section = true,
                    text = "|cffffd100" .. sess.zone .. "|r",
                    right = string.format("|cff777777%s · %d min · %d rolls|r",
                        Stamp(sess.first), mins, #sess.rolls),
                }
                for j = #sess.rolls, 1, -1 do RollEntries(sess.rolls[j], out, 1) end
            end
        end

    elseif mode == "items" then
        local totals = {}
        for _, e in ipairs(AggregateItems()) do
            totals[e.category] = (totals[e.category] or 0) + e.count
        end
        local lastCategory = nil
        for _, e in ipairs(AggregateItems()) do
            if Hit(e.link, e.category, e.subcategory) then
                if e.category ~= lastCategory then
                    lastCategory = e.category
                    out[#out + 1] = {
                        header = true, section = true,
                        text = "|cffffd100" .. e.category .. "|r",
                        right = "|cff777777" .. (totals[e.category] or 0) .. "|r",
                    }
                end
                local src = {}
                for s, n in pairs(e.sources) do src[#src + 1] = s .. " x" .. n end
                local who = {}
                for nm in pairs(e.chars or {}) do who[#who + 1] = nm end
                out[#out + 1] = {
                    indent = 1, icon = ItemIcon(e.link), link = e.link,
                    text = e.link .. CharTag(who),
                    right = string.format("|cffffffffx%d|r  |cff777777%s|r",
                        e.count, e.subcategory or table.concat(src, ", ")),
                }
            end
        end

    else
        local total = 0
        local rows = {}
        local m = DB().money
        for i = #m, 1, -1 do
            local row = m[i]
            if MineRow(row) and Hit(row.source, row.zone) then
                total = total + (row.delta or 0)
                local pos = (row.delta or 0) >= 0
                rows[#rows + 1] = {
                    indent = 1,
                    text = string.format("|cff777777%s|r  %s%s|r", Stamp(row.time),
                        pos and "|cff40ff40+" or "|cffff6666-", Money(row.delta)),
                    right = string.format("|cff777777%s · %s|r", row.source or "?",
                        CharTag({ row.char }) ~= "" and (row.char or "?") or (row.zone or "?")),
                }
            end
        end
        out[#out + 1] = {
            header = true, section = true, text = "|cffffd100Net|r",
            right = string.format("%s%s|r", total >= 0 and "|cff40ff40+" or "|cffff6666-", Money(total)),
        }
        for _, r in ipairs(rows) do out[#out + 1] = r end
    end

    if #out == 0 or (mode == "money" and #out == 1) then
        local why
        if mode == "rolls" or mode == "players" or mode == "sessions" then
            why = (#DB().rolls == 0)
                and "No rolls recorded yet. These only appear from group loot, when more than one person rolls on the same item."
                or "Nothing matches the search."
        else
            why = "Nothing here yet."
        end
        out[#out + 1] = { indent = 1, text = "|cff777777" .. why .. "|r" }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Renderer
-- ---------------------------------------------------------------------------
local ROW_H = 18
local CLASS_SHEET = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"

local function AcquireRow(i)
    local r = listing[i]
    if r then return r end
    r = CreateFrame("Button", nil, frame)
    r:SetHeight(ROW_H)
    r:SetPoint("LEFT", frame, "LEFT", 10, 0)
    r:SetPoint("RIGHT", frame, "RIGHT", -10, 0)

    r.stripe = r:CreateTexture(nil, "BACKGROUND")
    r.stripe:SetAllPoints()
    if r.stripe.SetColorTexture then r.stripe:SetColorTexture(1, 1, 1, 1)
    else r.stripe:SetTexture(1, 1, 1, 1) end
    r.stripe:SetVertexColor(1, 1, 1, 0)

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW_H - 4, ROW_H - 4)
    r.icon:SetPoint("LEFT", 0, 0)

    r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.left:SetJustifyH("LEFT")
    r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.right:SetPoint("RIGHT", 0, 0)
    r.right:SetJustifyH("RIGHT")

    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    r:RegisterForClicks("LeftButtonUp")
    r:SetScript("OnEnter", function(self)
        if not self.link then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.link)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Shift-clicking an item drops its link into whatever you are typing, the way the bags do.
    r:SetScript("OnClick", function(self)
        if self.link and IsShiftKeyDown() and ChatEdit_InsertLink then
            ChatEdit_InsertLink(self.link)
        end
    end)
    listing[i] = r
    return r
end

local function Refresh()
    if not frame or not frame:IsShown() then return end
    local lines = Lines()
    local visible = math.floor((frame:GetHeight() - 86) / ROW_H)
    if scrollRow > math.max(0, #lines - visible) then scrollRow = math.max(0, #lines - visible) end
    if scrollRow < 0 then scrollRow = 0 end

    for i = 1, visible do
        local row = AcquireRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -78 - (i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -78 - (i - 1) * ROW_H)
        local e = lines[scrollRow + i]
        if e then
            local indent = (e.indent or 0) * 14
            row.link = e.link

            if e.icon then
                row.icon:SetTexture(e.icon)
                row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                row.icon:ClearAllPoints()
                row.icon:SetPoint("LEFT", indent, 0)
                row.icon:Show()
            elseif e.classIcon and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[e.classIcon] then
                local c = CLASS_ICON_TCOORDS[e.classIcon]
                row.icon:SetTexture(CLASS_SHEET)
                row.icon:SetTexCoord(c[1], c[2], c[3], c[4])
                row.icon:ClearAllPoints()
                row.icon:SetPoint("LEFT", indent, 0)
                row.icon:Show()
            else
                row.icon:Hide()
            end

            row.left:ClearAllPoints()
            if row.icon:IsShown() then
                row.left:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
            else
                row.left:SetPoint("LEFT", indent, 0)
            end
            row.left:SetText(e.text or "")
            row.right:SetText(e.right or "")

            -- section headers get a faint band, ordinary rows alternate very subtly so the eye
            -- can track across to the right-hand column
            if e.section then
                row.stripe:SetVertexColor(0.9, 0.75, 0.2, 0.10)
            elseif e.header then
                row.stripe:SetVertexColor(1, 1, 1, 0.05)
            else
                row.stripe:SetVertexColor(1, 1, 1, (i % 2 == 0) and 0.02 or 0)
            end
            row:Show()
        else
            row.link = nil
            row:Hide()
        end
    end
    for i = visible + 1, #listing do listing[i]:Hide() end

    frame.count:SetText(string.format("|cff777777%d rolls · %d items · %d money|r",
        #DB().rolls, #DB().items, #DB().money))
end

-- Export: the current view as plain text in a box you can select and copy out.
local exportFrame
local function ShowExport()
    if not exportFrame then
        exportFrame = CreateFrame("Frame", "GaarLooterExport", UIParent, "BackdropTemplate")
        exportFrame:SetSize(560, 380); exportFrame:SetPoint("CENTER")
        exportFrame:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
        exportFrame:SetBackdropColor(0.05, 0.06, 0.08, 0.97)
        exportFrame:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
        exportFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        exportFrame:SetMovable(true); exportFrame:EnableMouse(true)
        exportFrame:RegisterForDrag("LeftButton")
        exportFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
        exportFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        table.insert(UISpecialFrames, "GaarLooterExport")

        local t = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetPoint("TOPLEFT", 12, -12); t:SetText("Export — ctrl-A, ctrl-C")

        local close = CreateFrame("Button", nil, exportFrame, "UIPanelButtonTemplate")
        close:SetSize(60, 20); close:SetPoint("TOPRIGHT", -12, -10); close:SetText("Close")
        close:SetScript("OnClick", function() exportFrame:Hide() end)

        local scroll = CreateFrame("ScrollFrame", "GaarLooterExportScroll", exportFrame,
            "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -38); scroll:SetPoint("BOTTOMRIGHT", -32, 12)

        local box = CreateFrame("EditBox", nil, scroll)
        box:SetMultiLine(true); box:SetAutoFocus(false)
        box:SetFontObject(ChatFontNormal)
        box:SetWidth(500)
        box:SetScript("OnEscapePressed", function() exportFrame:Hide() end)
        scroll:SetScrollChild(box)
        exportFrame.box = box
    end
    local parts = {}
    for _, e in ipairs(Lines()) do
        local indent = string.rep("  ", e.indent or 0)
        local line = indent .. Plain(e.text or "")
        if e.right and e.right ~= "" then line = line .. "  " .. Plain(e.right) end
        parts[#parts + 1] = line
    end
    exportFrame.box:SetText(table.concat(parts, "\n"))
    exportFrame.box:HighlightText()
    exportFrame:Show()
    exportFrame.box:SetFocus()
end

local function BuildWindow()
    if frame then return frame end
    frame = CreateFrame("Frame", "GaarLooterFrame", UIParent, "BackdropTemplate")
    frame:SetSize(660, 440); frame:SetPoint("CENTER")
    frame:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    frame:SetBackdropColor(0.05, 0.06, 0.08, 0.95)
    frame:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true); frame:EnableMouse(true); frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(460, 240, 1100, 900) end
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); Refresh() end)
    table.insert(UISpecialFrames, "GaarLooterFrame")

    local titleBar = frame:CreateTexture(nil, "BACKGROUND")
    titleBar:SetPoint("TOPLEFT", 1, -1); titleBar:SetPoint("TOPRIGHT", -1, -1)
    titleBar:SetHeight(26)
    if titleBar.SetColorTexture then titleBar:SetColorTexture(1, 1, 1, 1)
    else titleBar:SetTexture(1, 1, 1, 1) end
    titleBar:SetVertexColor(0.11, 0.12, 0.15, 1)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -8); title:SetText("Gaar Looter")

    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetSize(26, 26)
    closeBtn:SetPoint("TOPRIGHT", -4, -4)

    frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.count:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -6, -6)

    -- Tabs: flat tiles that light up for the view you are on, rather than Blizzard buttons.
    local tabs = {}
    local function SelectTab(key)
        mode = key; scrollRow = 0
        for _, t in ipairs(tabs) do
            t.bg:SetVertexColor(t.key == key and 0.9 or 0.35, t.key == key and 0.75 or 0.37,
                t.key == key and 0.2 or 0.42, t.key == key and 0.25 or 0.12)
            t.label:SetTextColor(t.key == key and 1 or 0.65, t.key == key and 0.85 or 0.65,
                t.key == key and 0.35 or 0.7)
        end
        Refresh()
    end

    local x = 10
    for _, tab in ipairs({ { "Rolls", "rolls" }, { "Players", "players" }, { "Sessions", "sessions" },
                           { "Items", "items" }, { "Money", "money" } }) do
        local b = CreateFrame("Button", nil, frame)
        b:SetSize(72, 20); b:SetPoint("TOPLEFT", x, -32)
        b.key = tab[2]
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        if b.bg.SetColorTexture then b.bg:SetColorTexture(1, 1, 1, 1) else b.bg:SetTexture(1, 1, 1, 1) end
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.label:SetPoint("CENTER")
        b.label:SetText(tab[1])
        b:SetScript("OnClick", function(self) SelectTab(self.key) end)
        tabs[#tabs + 1] = b
        x = x + 74
    end

    local exportBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    exportBtn:SetSize(64, 20); exportBtn:SetPoint("TOPRIGHT", -10, -32)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", ShowExport)

    local search = CreateFrame("EditBox", "GaarLooterSearch", frame, "BackdropTemplate")
    search:SetSize(180, 18); search:SetPoint("TOPRIGHT", exportBtn, "TOPLEFT", -8, -1)
    search:SetAutoFocus(false)
    search:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
    search:SetBackdropColor(0.10, 0.11, 0.13, 1)
    search:SetBackdropBorderColor(0.30, 0.32, 0.37, 1)
    search:SetFont(STANDARD_TEXT_FONT, 11, "")
    search:SetTextInsets(6, 6, 0, 0)
    search:SetTextColor(0.9, 0.9, 0.9)
    search:SetScript("OnTextChanged", function(self)
        filter = string.lower(self:GetText() or "")
        scrollRow = 0
        Refresh()
    end)
    search:SetScript("OnEscapePressed", function(self)
        self:SetText(""); self:ClearFocus(); filter = ""; Refresh()
    end)

    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, dir) scrollRow = scrollRow - dir * 3; Refresh() end)
    frame:SetScript("OnSizeChanged", function() Refresh() end)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing(); Refresh() end)

    -- Character picker. Rebuilt on show rather than once, so a character that starts writing
    -- to the log later turns up without a reload.
    local charButtons = {}
    local function MakeCharButton(label, value, x)
        local b = charButtons[#charButtons + 1]
        if not b then
            b = CreateFrame("Button", nil, frame)
            b:SetSize(74, 16)
            b.bg = b:CreateTexture(nil, "BACKGROUND")
            b.bg:SetAllPoints()
            if b.bg.SetColorTexture then b.bg:SetColorTexture(1, 1, 1, 1) else b.bg:SetTexture(1, 1, 1, 1) end
            b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.label:SetPoint("CENTER")
            charButtons[#charButtons] = b
        end
        b:SetPoint("TOPLEFT", x, -58)
        b.value = value
        b.label:SetText(label)
        b:SetScript("OnClick", function(self)
            charFilter = self.value
            DB().onlyThisChar = (self.value ~= nil)
            scrollRow = 0
            frame.RefreshChars()
            Refresh()
        end)
        b:Show()
        return b
    end

    function frame.RefreshChars()
        local names = KnownChars()
        local i, x = 0, 10
        local function paint(b)
            local on = (b.value == charFilter)
            b.bg:SetVertexColor(on and 0.9 or 0.3, on and 0.75 or 0.32, on and 0.2 or 0.37,
                on and 0.22 or 0.10)
            b.label:SetTextColor(on and 1 or 0.6, on and 0.85 or 0.6, on and 0.35 or 0.65)
        end
        i = i + 1
        paint(MakeCharButton("All", nil, x))
        x = x + 76
        for _, name in ipairs(names) do
            i = i + 1
            paint(MakeCharButton(name, name, x))
            x = x + 76
        end
        for j = i + 1, #charButtons do charButtons[j]:Hide() end
    end

    -- The saved "only this character" preference decides where the picker starts.
    if DB().onlyThisChar and ME then charFilter = ME end

    SelectTab(mode)
    frame.RefreshChars()
    frame:Hide()
    frame:SetScript("OnShow", function(self) self.RefreshChars(); Refresh() end)
    return frame
end

local function Toggle()
    local w = BuildWindow()
    if w:IsShown() then w:Hide() else w:Show(); Refresh() end
end
_G.GaarLooter_Toggle = Toggle

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------
local uid = 0
function GaarLooter_BuildOptions(container)
    local refreshers = {}
    local y = -8

    local head = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", 16, y); head:SetText("Loot library")
    y = y - 28

    local openBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    openBtn:SetSize(140, 24); openBtn:SetPoint("TOPLEFT", 16, y)
    openBtn:SetText("Open the log")
    openBtn:SetScript("OnClick", Toggle)
    y = y - 34

    local function check(label, get, set)
        uid = uid + 1
        local nm = "GaarLooterCheck" .. uid
        local c = CreateFrame("CheckButton", nm, container, "UICheckButtonTemplate")
        c:SetSize(24, 24); c:SetPoint("TOPLEFT", 16, y)
        c:SetChecked(get() and true or false)
        local fs = _G[nm .. "Text"]
        fs:SetText(label); fs:SetFontObject(GameFontHighlight)
        c:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
        refreshers[#refreshers + 1] = function() c:SetChecked(get() and true or false) end
        y = y - 26
    end

    check("Log items you loot", function() return DB().trackLoot end, function(v) DB().trackLoot = v end)
    check("Log money", function() return DB().trackMoney end, function(v) DB().trackMoney = v end)
    check("Show only this character's rows", function() return DB().onlyThisChar end,
        function(v) DB().onlyThisChar = v end)
    y = y - 14

    local hint = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 18, y); hint:SetWidth(340); hint:SetJustifyH("LEFT")
    hint:SetText("The log is shared by every character on the account, and each row records which one wrote it, so the view can be narrowed to this character without losing the rest. Rolls are always logged. Rows are stored one per event and grouped only when shown, so the detail stays recoverable if the grouping changes later. Proficiency notes are observations, not judgements: needing off-spec is legitimate.")
    y = y - 62

    container.gaarRefresh = function() for _, fn in ipairs(refreshers) do fn() end end
    return -y
end

local function OpenOptions()
    if _G.GaarOptions_Open and _G.GaarOptions_Open("loot") then return end
    Toggle()
end
_G.GaarLooter_Config = OpenOptions

SLASH_GAARLOOTER1 = "/gaarlooter"
SLASH_GAARLOOTER2 = "/gloot"
SlashCmdList["GAARLOOTER"] = function(msg)
    msg = string.gsub(string.lower(msg or ""), "%s+", "")
    if msg == "config" or msg == "options" then OpenOptions()
    elseif msg == "debug" then
        -- The roll views depend on Blizzard's LOOT_ROLL_* strings existing under the names
        -- this addon expects. If they don't, rolls are never parsed and the views stay empty
        -- with nothing to show for it, so list what the client actually has.
        print("|cff5599ff" .. ADDON .. ":|r loot roll strings on this client:")
        local names = { "LOOT_ROLL_NEED", "LOOT_ROLL_GREED", "LOOT_ROLL_DISENCHANT",
            "LOOT_ROLL_PASSED", "LOOT_ROLL_ROLLED_NEED", "LOOT_ROLL_ROLLED_GREED",
            "LOOT_ROLL_ROLLED_DE", "LOOT_ROLL_WON", "LOOT_ROLL_YOU_WON", "LOOT_ROLL_ALL_PASSED" }
        local missing = 0
        for _, n in ipairs(names) do
            local v = _G[n]
            if v then
                print("  |cff40ff40" .. n .. "|r = " .. tostring(v))
            else
                missing = missing + 1
                print("  |cffff6666" .. n .. "|r missing")
            end
        end
        print(string.format("  %d of %d present; %d roll rows stored.",
            #names - missing, #names, #DB().rolls))
    elseif msg == "wipe" then
        GaarLooterDB = nil; DB()
        print("|cff5599ff" .. ADDON .. ":|r log cleared.")
        Refresh()
    else Toggle() end
end
