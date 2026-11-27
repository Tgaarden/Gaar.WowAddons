--[[
  GaarBuffsForever - self buffs (since 1.11.0): your own XP food buff and campfire buff, in a
  small strip of up to two rows next to the buff box (left of it, Alt + drag to move). Every class:
  it is about you alone, so it runs even where the class buff check is idle (ns.extras in
  GaarBuffsForever.lua).

    XP food   WoW Forever food that gives bonus experience while Well Fed. The row shows the
              buff with its time left ("XP food 14:32"), or "missing" in red. Click eats an XP
              food from your bags (secure button, type "item", item = the food's name, else
              "item:<ID>"), the largest stack when there are several. No XP food in the bags:
              the icon is greyed out, tooltip "No XP food in bags", and the click does nothing.
    Campfire  The buff from standing at a campfire (classic "Cozy Fire", or Forever's own). The
              row shows it with its time left, or "missing" in red. Click casts Basic Campfire
              (type "spell", the spell's name), only when you know it; otherwise the icon is
              greyed out, tooltip "Requires Cooking (Basic Campfire)".

  Each row has its own option (/gbuff self food|fire [on|off]; /gbuff self [on|off] both, also in
  the menu); both are on by default. A row shows only while its buff is missing, greyed out or expiring soon (the class buffs' window,
  /gbuff expire; the time left is in brackets). The strip shows while at least one row is showing and
  the addon is on (/gbuff on|off). Both buffs up: no strip.

  Detection. The exact names and spell / item IDs on WoW Forever are not known, so everything is
  matched by keywords (KEYWORDS below, one table, lower-case Lua patterns) and what is found is
  learned:
    * Auras: C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL") (UnitAura on an older client)
      and, out of combat, the aura's tooltip text (C_TooltipInfo.GetUnitBuffByAuraInstanceID,
      else GetUnitAura). Campfire: the name or text has a campfire word ("campfire", "cozy
      fire", ...) or the name has the word "fire" (but not Inner Fire, Fire Shield, ...).
      XP food (when it is not the campfire): the text mentions experience ("experience", "xp")
      and either looks like food ("well fed", "food", "eat") or a gain ("bonus", "increase",
      "%"), or the icon is the Well Fed icon.
    * Bags: C_Container slots, each item's tooltip (C_TooltipInfo.GetBagItem) once per item ID:
      an XP word in the tooltip and a food cue ("Use:", "eating", "well fed", "seated").
      Rescanned on BAG_UPDATE_DELAYED, at most once a second, out of combat.
    * Basic Campfire: spell 818 (classic), else by name, known when IsSpellKnown / IsPlayerSpell
      / C_SpellBook says so.
    * Learned IDs: a matched aura's spell ID, an XP food's item ID and the campfire spell's ID are
      kept account-wide in GaarBuffsForeverDB.selfLearned and listed in /gbuff status, so they
      can be hard-coded later; a learned aura ID is matched without its tooltip. /gbuff self
      forget clears them (a false match). Each new one is announced once in chat.

  Combat. Auras are secret in combat on this client and tooltips are not read then. A buff is
  still matched by a learned spell ID when that ID is readable; otherwise the rows are frozen:
  the state from before the fight stays, its time still counts down from the expiration time
  read before, and a buff that runs out shows "missing". Secure attributes (type, item, spell),
  click registration, size, place and Show/Hide are only changed out of combat, on the addon's
  own buttons; a change in combat waits for PLAYER_REGEN_ENABLED. Only texts, textures, colours
  and alpha change in combat.

  Taint: no Blizzard function is replaced and nothing is set on a Blizzard frame; only events,
  HookScript and the addon's own frames. Every API is checked before use and runs in pcall; a
  secret value is never compared, tested or matched (BF.IsSecret first). No globals: the frames
  have no names. No combat log.
]]

local _G = _G
local _, ns = ...
ns = ns or {}

local BF = _G.GaarForever
local Secret, Num, Str, InCombat = BF.IsSecret, BF.Num, BF.Str, BF.InCombat
local API, PCall = BF.API, BF.Call

-- ---------------------------------------------------------------------------
-- Keywords: lower-case Lua patterns, easy to extend. Matched only against plain strings.
-- ---------------------------------------------------------------------------

local KEYWORDS = {
    -- An aura or item mentions experience.
    xp = { "experience", "%f[%w]xp%f[%W]", "%f[%w]exp%f[%W]" },
    -- With an XP word, an aura counts as the XP food buff when it also looks like food ...
    xpFood = { "well fed", "food", "%f[%w]eat", "%f[%w]fed%f[%W]" },
    -- ... or speaks of a gain ("bonus experience gained", "increases experience by 10%").
    xpGain = { "bonus", "increase", "gain", "additional", "extra", "more", "%d+%%" },
    -- A bag item counts as XP food when its tooltip has an XP word and one of these.
    foodCue = { "use:", "eating", "well fed", "seated", "%f[%w]eat" },
    -- Campfire: anywhere in the aura's name or tooltip ...
    fire = { "campfire", "camp fire", "cozy fire", "cosy fire", "bonfire", "near a fire",
        "near the fire", "by the fire", "warmth of the fire", "camp benefit", "camp bonus" },
    -- ... or the word "fire" in the aura's name only, unless the name is one of these.
    fireName = { "%f[%w]fire%f[%W]" },
    fireNotName = { "inner fire", "fire shield", "fire resistance", "fire ward", "fire power",
        "fire vulnerability", "fire reflect", "fire nova", "flametongue", "molten", "fire protection" },
}

-- The Well Fed icon (Spell_Misc_Food), as a file ID or a path.
local WELL_FED_ICONS = { [136000] = true, ["interface\\icons\\spell_misc_food"] = true }

-- Classic IDs that are tried first; anything Forever uses instead is found by keyword/name.
local SEEDS = {
    fireSpells = { 818 },             -- Basic Campfire
    fireSpellName = "Basic Campfire",
    fireAuras = { [7353] = "Cozy Fire" },
}

local ICON_FOOD = "Interface\\Icons\\Spell_Misc_Food"
local ICON_FIRE = "Interface\\Icons\\Spell_Fire_Fire"
local MAX_AURAS = 40
local BAGS_LAST = 4               -- backpack 0 and bags 1-4
local SCAN_THROTTLE = 0.25        -- auras at most 4 times a second
local BAG_THROTTLE = 1.0          -- bags at most once a second
local TEXT_TICK = 0.5             -- the time left is redrawn twice a second
local RESCAN = 5                  -- out of combat, the auras are read again at least this often
local ROW_H, PAD, WIDTH = 18, 6, 150
local FLAT = "Interface\\Buttons\\WHITE8x8"
local RED, GREEN, GREY = { 1, 0.33, 0.33 }, { 0.3, 0.85, 0.3 }, { 0.45, 0.45, 0.45 }

-- The two rows, in order: option key, label, slash words.
local ENTRIES = {
    { kind = "xp", key = "selfFood", label = "XP food", words = { food = true, xp = true } },
    { kind = "fire", key = "selfFire", label = "Campfire", words = { fire = true, campfire = true } },
}

local panel, rows = nil, {}
local learned                     -- db.selfLearned: { xpAuras, fireAuras, foods = {[id] = name}, fireSpell }
local state = { xp = nil, fire = nil, frozen = false, scanned = false }   -- the buffs: { id, name, icon, exp }
local food                        -- the picked XP food: { id, name, icon, count, total } or nil
local fireSpell                   -- Basic Campfire: { id, name, icon } when known, else nil
local foodCache = {}              -- item ID -> true / false (this session; the tooltip is static)
local auraSeen = {}               -- spell ID -> false: read and not ours (this session)
local retries = {}                -- item ID -> times its tooltip was read before the item loaded
local MAX_RETRIES = 5
local auraDirty, bagsDirty, spellsDirty, bindPending = true, true, true, true
local lastScan, lastBags, lastText = 0, 0, 0
local lastSig
local stats = { tooltip = "none", unreadable = 0, bagItems = 0, foods = 0 }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Now() return Num(PCall(_G.GetTime)) or 0 end
local function Print(msg) if ns.Print then ns.Print(msg) end end
local function Fail(where, err) if ns.Fail then ns.Fail("self buffs: " .. where, err) end end
local function On(key) return ns.On and ns.On(key) or false end

local function Any(text, list)
    if type(text) ~= "string" then return false end
    for _, p in ipairs(list) do
        if text:find(p) then return true end
    end
    return false
end

-- A plain icon (file ID or path), else nil.
local function Icon(v)
    if Secret(v) then return nil end
    if type(v) == "number" or (type(v) == "string" and v ~= "") then return v end
    return nil
end

local function DB() return ns.DB and ns.DB() end

local function Active()
    local db = DB()
    if not db or not On("enabled") then return false end
    return On("selfFood") or On("selfFire")
end

-- The text of a C_TooltipInfo result, lines joined with "\n", lower case; nil when nothing plain.
local function InfoText(data)
    if Secret(data) or type(data) ~= "table" then return nil end
    local lines = data.lines
    if Secret(lines) or type(lines) ~= "table" then return nil end
    local out = {}
    for _, line in ipairs(lines) do
        if not Secret(line) and type(line) == "table" then
            local l, r = Str(line.leftText), Str(line.rightText)
            if l then out[#out + 1] = l end
            if r then out[#out + 1] = r end
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, "\n"):lower()
end

-- ---------------------------------------------------------------------------
-- Matching (plain strings only)
-- ---------------------------------------------------------------------------

-- "fire", "xp" or nil for one aura: its name, its tooltip text (lower case or nil) and icon.
local function Classify(name, text, icon)
    local lname = type(name) == "string" and name:lower() or ""
    local all = lname .. "\n" .. (text or "")
    if Any(all, KEYWORDS.fire) then return "fire" end
    if Any(lname, KEYWORDS.fireName) and not Any(lname, KEYWORDS.fireNotName) then return "fire" end
    if Any(all, KEYWORDS.xp) then
        local ic = type(icon) == "string" and icon:lower() or icon
        if Any(all, KEYWORDS.xpFood) or Any(all, KEYWORDS.xpGain) or (ic ~= nil and WELL_FED_ICONS[ic]) then
            return "xp"
        end
    end
    return nil
end

-- Whether a bag item's tooltip text (lower case) is an XP food's.
local function IsXpFoodText(text)
    if type(text) ~= "string" then return false end
    return Any(text, KEYWORDS.xp) and Any(text, KEYWORDS.foodCue)
end

-- ---------------------------------------------------------------------------
-- Learned IDs (account-wide)
-- ---------------------------------------------------------------------------

local function Learn(bucket, id, name, what)
    if not learned or type(id) ~= "number" then return end
    local t = learned[bucket]
    if t[id] then return end
    t[id] = Str(name) or "?"
    Print(string.format("learned %s: %d (%s). /gbuff status lists every learned ID.", what, id, t[id]))
end

local function LearnedList(t)
    local ids = {}
    for id in pairs(t or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = id .. " (" .. tostring(t[id]) .. ")" end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

-- ---------------------------------------------------------------------------
-- Auras
-- ---------------------------------------------------------------------------

local function IndexSecret(i)
    local f = API("C_Secrets", "ShouldUnitAuraIndexBeSecret")
    if not f then return false end
    local ok, s = pcall(f, "player", i, "HELPFUL")
    return ok and not Secret(s) and s == true
end

-- An expiration time: plain and above zero, else nil (0 = a buff without a duration).
local function Expires(v)
    v = Num(v)
    return (v and v > 0) and v or nil
end

-- One aura: { id, name, icon, exp, iid, index, secret }, nil at the end, false when unreadable.
local function ReadAura(i)
    if IndexSecret(i) then return false end
    local f = API("C_UnitAuras", "GetAuraDataByIndex")
    if f then
        local ok, a = pcall(f, "player", i, "HELPFUL")
        if not ok or Secret(a) then return false end
        if type(a) ~= "table" then return nil end
        local ok2, id, name, icon, exp, iid = pcall(function()
            return a.spellId, a.name, a.icon, a.expirationTime, a.auraInstanceID
        end)
        if not ok2 then return false end
        return { id = Num(id), name = Str(name), icon = Icon(icon), exp = Expires(exp), iid = Num(iid),
            index = i, secret = Secret(id) or Secret(name) }
    end
    local ua = _G.UnitAura
    if type(ua) == "function" then
        local ok, name, icon, _, _, _, exp, _, _, _, id = pcall(ua, "player", i, "HELPFUL")
        if not ok then return false end
        if not Secret(name) and name == nil then return nil end
        return { id = Num(id), name = Str(name), icon = Icon(icon), exp = Expires(exp), index = i,
            secret = Secret(id) or Secret(name) }
    end
    return false
end

-- The aura's tooltip text (lower case), out of combat only.
local function AuraText(a)
    if InCombat() then return nil end
    local byIID = API("C_TooltipInfo", "GetUnitBuffByAuraInstanceID")
    if byIID and a.iid then
        local text = InfoText(PCall(byIID, "player", a.iid))
        if text then stats.tooltip = "GetUnitBuffByAuraInstanceID" return text end
    end
    local byIndex = API("C_TooltipInfo", "GetUnitAura")
    if byIndex then
        local text = InfoText(PCall(byIndex, "player", a.index, "HELPFUL"))
        if text then stats.tooltip = "GetUnitAura" return text end
    end
    return nil
end

-- Which of ours an aura is: by a learned / seeded spell ID first (also in combat), then (out of
-- combat) by keywords on its name and tooltip; what matches is learned.
local function AuraKind(a)
    local id = a.id
    if id then
        if learned and learned.xpAuras[id] then return "xp" end
        if (learned and learned.fireAuras[id]) or SEEDS.fireAuras[id] then return "fire" end
        if auraSeen[id] == false then return nil end
    end
    if InCombat() or a.secret then return nil end
    local text = AuraText(a)
    local kind = Classify(a.name, text, a.icon)
    if kind == "xp" then
        Learn("xpAuras", id, a.name, "XP food buff spell ID")
    elseif kind == "fire" then
        Learn("fireAuras", id, a.name, "campfire buff spell ID")
    elseif id and text then
        auraSeen[id] = false
    end
    return kind
end

-- Reads your buffs into state. Out of combat a buff not found is gone. In combat (or with an
-- unreadable aura) only what is found by ID updates; the rest stays frozen as it was.
local function ScanAuras()
    lastScan, auraDirty = Now(), false
    local found, unreadable = {}, 0
    for i = 1, MAX_AURAS do
        local a = ReadAura(i)
        if a == false then unreadable = unreadable + 1 break end
        if a == nil then break end
        if a.secret and not a.id then unreadable = unreadable + 1 end
        local kind = AuraKind(a)
        if kind then
            local cur = found[kind]
            if not cur or (a.exp or math.huge) > (cur.exp or math.huge) then
                found[kind] = { id = a.id, name = a.name, icon = a.icon, exp = a.exp }
            end
        end
    end
    stats.unreadable = unreadable
    local sure = not InCombat() and unreadable == 0
    state.frozen = not sure
    for _, kind in ipairs({ "xp", "fire" }) do
        if found[kind] then
            state[kind] = found[kind]
        elseif sure then
            state[kind] = nil
        end
    end
    state.scanned = state.scanned or sure
end

-- ---------------------------------------------------------------------------
-- Bags
-- ---------------------------------------------------------------------------

local function ItemName(id, link)
    local n = Str(PCall(API("C_Item", "GetItemNameByID"), id))
    if n then return n end
    n = Str(PCall(_G.GetItemInfo, id))
    if n then return n end
    return type(link) == "string" and link:match("%[(.-)%]") or nil
end

-- Out of combat: the XP food in the bags with the largest count (ties: the lowest item ID).
local function ScanBags()
    lastBags, bagsDirty = Now(), false
    local slots = API("C_Container", "GetContainerNumSlots")
    local info = API("C_Container", "GetContainerItemInfo")
    local tip = API("C_TooltipInfo", "GetBagItem")
    if not slots or not info then
        food = nil
        return
    end
    local counts, icons, links, items = {}, {}, {}, 0
    for bag = 0, BAGS_LAST do
        local n = Num(PCall(slots, bag)) or 0
        for slot = 1, n do
            local it = PCall(info, bag, slot)
            if type(it) == "table" and not Secret(it) then
                local id = Num(it.itemID)
                if id then
                    items = items + 1
                    local is = foodCache[id]
                    if is == nil and learned and learned.foods[id] then is = true end
                    if is == nil and tip then
                        local text = InfoText(PCall(tip, bag, slot))
                        -- Not loaded yet (no text, or no name yet so the "Use:" line may be
                        -- missing): a "no" is not kept, and the item is asked again next scan.
                        if text then
                            is = IsXpFoodText(text)
                            retries[id] = (retries[id] or 0) + 1
                            if not is and not ItemName(id) and retries[id] < MAX_RETRIES then
                                PCall(API("C_Item", "RequestLoadItemDataByID"), id)
                                is = nil
                                bagsDirty = true
                            end
                        end
                    end
                    if is ~= nil then foodCache[id] = is end
                    if is then
                        counts[id] = (counts[id] or 0) + (Num(it.stackCount) or 1)
                        icons[id] = icons[id] or Icon(it.iconFileID)
                        links[id] = links[id] or Str(it.hyperlink)
                    end
                end
            end
        end
    end
    local best, kinds = nil, 0
    for id, c in pairs(counts) do
        kinds = kinds + 1
        if not best or c > counts[best] or (c == counts[best] and id < best) then best = id end
    end
    stats.bagItems, stats.foods = items, kinds
    if not best then
        food = nil
        return
    end
    local name = ItemName(best, links[best])
    Learn("foods", best, name, "XP food item ID")
    food = { id = best, name = name, icon = icons[best], count = counts[best], kinds = kinds }
end

-- ---------------------------------------------------------------------------
-- Basic Campfire
-- ---------------------------------------------------------------------------

local function SpellKnown(id)
    if ns.Known and ns.Known(id) then return true end
    local slot = PCall(API("C_SpellBook", "FindSpellBookSlotForSpell"), id)
    return Num(slot) ~= nil
end

-- Out of combat: Basic Campfire when you know it (classic ID, the learned ID, else by name).
local function ResolveFire()
    spellsDirty = false
    local ids = {}
    for _, id in ipairs(SEEDS.fireSpells) do ids[#ids + 1] = id end
    if learned and Num(learned.fireSpell) then ids[#ids + 1] = learned.fireSpell end
    if ns.SpellName then
        local _, byName = ns.SpellName(SEEDS.fireSpellName)
        if byName then ids[#ids + 1] = byName end
    end
    fireSpell = nil
    for _, id in ipairs(ids) do
        if SpellKnown(id) then
            local name, _, icon = nil, nil, nil
            if ns.SpellName then name, _, icon = ns.SpellName(id) end
            fireSpell = { id = id, name = name, icon = Icon(icon) }
            if learned and learned.fireSpell ~= id then
                learned.fireSpell = id
                learned.fireSpellName = name
            end
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- The strip
-- ---------------------------------------------------------------------------

local function SavePosition()
    local db = DB()
    if not panel or not db then return end
    local ui = _G.UIParent
    local left, top = Num(panel:GetLeft()), Num(panel:GetTop())
    local uw, uh = Num(ui:GetWidth()), Num(ui:GetHeight())
    if not left or not top or not uw or not uh then return end
    db.selfPos = { x = math.floor(left - uw / 2 + 0.5), y = math.floor(top - uh + 0.5) }
end

local function ApplyPosition()
    if not panel or InCombat() then return end
    local db = DB()
    local p = db and db.selfPos
    panel:ClearAllPoints()
    local holder = ns.Holder and ns.Holder()
    if type(p) == "table" and Num(p.x) and Num(p.y) then
        panel:SetPoint("TOPLEFT", _G.UIParent, "TOP", p.x, p.y)
    elseif holder then
        panel:SetPoint("TOPRIGHT", holder, "TOPLEFT", -6, 0)
    else
        panel:SetPoint("TOPRIGHT", _G.UIParent, "TOP", -101, -120)
    end
end

-- What a row shows and does: { look = "active" | "missing" | "off", text, icon, attr = { type,
-- key, value } or nil, tip = lines }.
local function View(kind, now)
    local b = state[kind]
    if b and b.exp and b.exp <= now then b = nil end   -- ran out while frozen
    local v = { tip = {} }
    if kind == "xp" then
        if food then
            v.attr = { type = "item", key = "item", value = food.name or ("item:" .. food.id) }
            v.tip[#v.tip + 1] = { "Click: eat " .. (food.name or ("item " .. food.id)) .. " (" .. food.count .. " in bags)", 1, 1, 1 }
        else
            v.tip[#v.tip + 1] = { "No XP food in bags", 1, 0.33, 0.33 }
        end
        v.icon = (b and b.icon) or (food and food.icon) or ICON_FOOD
    else
        if fireSpell then
            v.attr = { type = "spell", key = "spell", value = fireSpell.name or fireSpell.id }
            v.tip[#v.tip + 1] = { "Click: cast " .. (fireSpell.name or SEEDS.fireSpellName), 1, 1, 1 }
        else
            v.tip[#v.tip + 1] = { "Requires Cooking (Basic Campfire)", 1, 0.33, 0.33 }
        end
        v.icon = (b and b.icon) or (fireSpell and fireSpell.icon) or ICON_FIRE
    end
    if b then
        -- Expiring soon: the same window as the class buffs (/gbuff expire), read from ns.Expiring.
        local left = b.exp and (b.exp - now) or nil
        local clock = left and ns.Clock and ns.Clock(left) or nil
        local expiring = left ~= nil and ns.Expiring ~= nil and ns.Expiring(left) == true
        v.look = expiring and "expiring" or "active"
        v.text = clock or "on"
        table.insert(v.tip, 1, { (b.name or "?") .. (clock and (": " .. clock .. " left") or ""), 0.3, 0.85, 0.3 })
        if expiring then table.insert(v.tip, 2, { "Expires in " .. clock .. ".", 1, 0.82, 0 }) end
    elseif v.attr then
        v.look, v.text = "missing", "missing"
    else
        v.look = "off"
        v.text = kind == "xp" and "no food" or "no Cooking"
    end
    if state.frozen then
        v.tip[#v.tip + 1] = { InCombat() and "In combat: the game hides your buffs, so this is the state from before the fight."
            or "Some buffs could not be read; shown as last seen.", 0.8, 0.8, 0.8 }
    end
    return v
end

local function RowTooltip(self)
    local tip = _G.GameTooltip
    if not tip or not self.view then return end
    tip:SetOwner(self, "ANCHOR_RIGHT")
    tip:AddLine(self.label)
    for _, l in ipairs(self.view.tip) do tip:AddLine(l[1], l[2], l[3], l[4], true) end
    tip:Show()
end

local function NewRow(i)
    local r = CreateFrame("Button", nil, panel, "SecureActionButtonTemplate")
    r:SetHeight(ROW_H)
    r.border = r:CreateTexture(nil, "BACKGROUND")
    r.border:SetSize(ROW_H - 2, ROW_H - 2)
    r.border:SetPoint("LEFT", 1, 0)
    r.border:SetTexture(FLAT)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW_H - 4, ROW_H - 4)
    r.icon:SetPoint("CENTER", r.border, "CENTER")
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.text:SetPoint("LEFT", r.border, "RIGHT", 6, 0)
    r.text:SetJustifyH("LEFT")
    r:SetHighlightTexture(FLAT, "ADD")
    local hl = r:GetHighlightTexture()
    if hl then hl:SetVertexColor(1, 1, 1, 0.12) end
    r:HookScript("OnEnter", function(self) pcall(RowTooltip, self) end)
    r:HookScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    rows[i] = r
    return r
end

local function CreatePanel()
    if panel then return end
    panel = CreateFrame("Frame", nil, _G.UIParent, "BackdropTemplate")
    panel:SetSize(WIDTH, 2 * ROW_H + 2 * PAD)
    panel:SetFrameStrata("MEDIUM")
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    if type(panel.SetBackdrop) == "function" then
        panel:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        panel:SetBackdropColor(0.07, 0.08, 0.10, 0.90)
        panel:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    end
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function()
        if InCombat() or not (ns.Bool and ns.Bool(PCall(_G.IsAltKeyDown))) then return end
        panel:StartMoving()
    end)
    panel:SetScript("OnDragStop", function()
        panel:StopMovingOrSizing()
        local ok, err = pcall(function()
            SavePosition()
            ApplyPosition()
        end)
        if not ok then Fail("saving the position", err) end
    end)
    for i = 1, #ENTRIES do NewRow(i) end
    panel:Hide()
    ApplyPosition()
end

-- Out of combat only: the secure attributes of one row, written only when they changed.
local function Bind(r, attr)
    if InCombat() then
        bindPending = true
        return
    end
    local keyDown = ns.UseKeyDown and ns.UseKeyDown() or false
    local key = attr and (attr.type .. "\031" .. tostring(attr.value)) or "none"
    key = key .. "\031" .. tostring(keyDown)
    if r.bindKey == key then return end
    r.bindKey = key
    r:RegisterForClicks(keyDown and "AnyDown" or "AnyUp")
    r:SetAttribute("type", nil)
    r:SetAttribute("item", nil)
    r:SetAttribute("spell", nil)
    if attr then
        r:SetAttribute(attr.key, attr.value)
        r:SetAttribute("type", attr.type)
    end
end

local function Paint(r, v)
    local c = (v.look == "active" or v.look == "expiring") and GREEN or v.look == "missing" and RED or GREY
    r.border:SetVertexColor(c[1], c[2], c[3], 1)
    r.icon:SetTexture(v.icon)
    if type(r.icon.SetDesaturated) == "function" then r.icon:SetDesaturated(v.look == "off") end
    -- Expiring: the time left in grey brackets, as the class buff rows show it ("(1:45)").
    if v.look == "expiring" then
        r.text:SetText(r.label .. "  |cffaaaaaa(" .. v.text .. ")|r")
        return
    end
    local hex = v.look == "active" and "ffffff" or v.look == "missing" and "ff5555" or "888888"
    r.text:SetText(r.label .. "  |cff" .. hex .. v.text .. "|r")
end

-- Which rows are on, as a string: a change re-lays the strip out (out of combat).
local function Signature()
    return tostring(Active()) .. tostring(On("selfFood")) .. tostring(On("selfFire"))
end

-- Draws the rows. Out of combat also lays the strip out, binds the buttons and shows / hides it.
local function Render()
    if not panel then return end
    local now = Now()
    lastText = now
    local combat = InCombat()
    local active = Active()
    if not combat then
        lastSig = Signature()
        if not active then
            panel:Hide()
            return
        end
    elseif not active then
        return
    end
    local y, n = -PAD, 0
    for i, e in ipairs(ENTRIES) do
        local r = rows[i]
        r.label = e.label
        local v = On(e.key) and View(e.kind, now) or nil
        r.view = v
        if v then Paint(r, v) end
        -- A row shows only while its buff is missing or cannot be used (greyed out); a row whose
        -- buff is active is hidden, so the strip shrinks to the rows that need attention.
        local show = v ~= nil and v.look ~= "active"
        if show then
            n = n + 1
            if not combat then
                Bind(r, v.attr)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
                r:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, y)
                r:Show()
            end
            y = y - ROW_H
        elseif not combat then
            Bind(r, nil)
            r:Hide()
        end
    end
    if not combat then
        bindPending = false
        panel:SetHeight(n * ROW_H + 2 * PAD)
        -- No row to show (both buffs active): the strip and its backdrop are hidden too.
        if n > 0 then panel:Show() else panel:Hide() end
    end
end

-- ---------------------------------------------------------------------------
-- Settings, slash, help, status, menu
-- ---------------------------------------------------------------------------

local function SetBoth(v)
    if ns.Set then
        ns.Set("selfFood", v, true)
        ns.Set("selfFire", v, true)
    end
    Print("self buffs (XP food and campfire): " .. (v and "on" or "off") .. "."
        .. (InCombat() and " The strip changes after combat." or ""))
end

local function Forget()
    if not learned then return end
    learned.xpAuras, learned.fireAuras, learned.foods = {}, {}, {}
    learned.fireSpell, learned.fireSpellName = nil, nil
    foodCache, auraSeen, retries = {}, {}, {}
    auraDirty, bagsDirty, spellsDirty = true, true, true
    Print("self buffs: learned IDs cleared; they are found again by keyword.")
end

local function Slash(cmd, arg)
    if cmd ~= "self" and cmd ~= "selfbuffs" then return false end
    local what, rest = (arg or ""):match("^(%S*)%s*(.*)$")
    if what == "" or what == "on" or what == "off" then
        SetBoth(ns.Toggle(what, On("selfFood") or On("selfFire")))
    elseif what == "reset" then
        local db = DB()
        if db then db.selfPos = nil end
        if InCombat() then
            Print("the self-buff strip moves back after combat.")
        else
            ApplyPosition()
            Print("self-buff strip back next to the buff box.")
        end
    elseif what == "forget" then
        Forget()
    else
        local done = false
        for _, e in ipairs(ENTRIES) do
            if e.words[what] then
                local v = ns.Toggle(rest, On(e.key))
                if v == nil then Print("/gbuff self " .. what .. " [on|off]") else ns.Set(e.key, v) end
                done = true
            end
        end
        if not done then
            Print("/gbuff self [on|off], /gbuff self food [on|off], /gbuff self fire [on|off], /gbuff self reset, /gbuff self forget")
        end
    end
    return true
end

local function Help()
    return {
        "/gbuff self [on|off] - your XP food and campfire buffs with time left, in a strip next to the box (every class); click eats an XP food from your bags or casts Basic Campfire",
        "/gbuff self food | fire [on|off] - each row; /gbuff self reset - put the strip back (Alt + drag moves it); /gbuff self forget - clear the learned IDs",
    }
end

local function BuffText(b, now)
    if not b then return "none" end
    return string.format("%s (spell %s)%s", b.name or "?", b.id and tostring(b.id) or "?",
        b.exp and (" " .. (ns.Clock and ns.Clock(b.exp - now) or "") .. " left") or "")
end

local function Status()
    local now = Now()
    local out = {
        "self buffs: XP food " .. ns.OnOff(On("selfFood")) .. "   campfire " .. ns.OnOff(On("selfFire"))
            .. "   strip: " .. (Active() and ((panel and panel:IsShown()) and "shown" or "hidden") or "off")
            .. (state.frozen and "   (frozen: " .. (InCombat() and "combat" or (stats.unreadable .. " unreadable aura(s)")) .. ")" or "")
            .. ((bindPending and InCombat()) and "   (buttons change after combat)" or ""),
        "  XP food buff: " .. BuffText(state.xp, now) .. "   campfire buff: " .. BuffText(state.fire, now)
            .. "   aura tooltip: " .. stats.tooltip,
        "  XP food in bags: " .. (food and string.format("%s (item %d) x%d, %d kind(s)", food.name or "?", food.id, food.count, food.kinds)
            or ("none (" .. stats.bagItems .. " items scanned)"))
            .. "   Basic Campfire: " .. (fireSpell and string.format("known (spell %d)", fireSpell.id) or "not known"),
        "  learned XP food buff IDs: " .. LearnedList(learned and learned.xpAuras),
        "  learned campfire buff IDs: " .. LearnedList(learned and learned.fireAuras)
            .. "   campfire spell: " .. ((learned and Num(learned.fireSpell)) and (learned.fireSpell .. " (" .. tostring(learned.fireSpellName) .. ")") or "none"),
        "  learned XP food item IDs: " .. LearnedList(learned and learned.foods),
    }
    return out
end

local function Menu()
    return {
        { text = "Reset self-buff strip position", func = function() Slash("self", "reset") end },
    }
end

-- Sanitises the learned IDs (account-wide) at ADDON_LOADED.
local function BindDB(db)
    local t = type(db.selfLearned) == "table" and db.selfLearned or {}
    local function Ids(v)
        local out = {}
        if type(v) == "table" then
            for id, name in pairs(v) do
                if type(id) == "number" then out[id] = type(name) == "string" and name or "?" end
            end
        end
        return out
    end
    learned = { xpAuras = Ids(t.xpAuras), fireAuras = Ids(t.fireAuras), foods = Ids(t.foods),
        fireSpell = type(t.fireSpell) == "number" and t.fireSpell or nil,
        fireSpellName = type(t.fireSpellName) == "string" and t.fireSpellName or nil }
    db.selfLearned = learned
    local p = db.selfPos
    db.selfPos = (type(p) == "table" and Num(p.x) and Num(p.y)) and { x = p.x, y = p.y } or nil
end

ns.extras = ns.extras or {}
ns.extras[#ns.extras + 1] = {
    options = {
        { key = "selfFood", short = "xp food", label = "Self buff: XP food (click eats one)" },
        { key = "selfFire", short = "campfire", label = "Self buff: campfire (click casts Basic Campfire)" },
    },
    savedKeys = { selfPos = true, selfLearned = true },
    Bind = BindDB, Slash = Slash, Help = Help, Status = Status, Menu = Menu,
}

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function Tick()
    local now = Now()
    if InCombat() then
        if auraDirty and now - lastScan >= SCAN_THROTTLE then ScanAuras() lastText = 0 end
        if now - lastText >= TEXT_TICK then Render() end
        return
    end
    if not Active() then
        if lastSig ~= Signature() then Render() end
        return
    end
    -- A buff whose tooltip had not loaded yet is read again every few seconds.
    if now - lastScan >= RESCAN then auraDirty = true end
    local changed = lastSig ~= Signature() or bindPending
    if spellsDirty then ResolveFire() changed = true end
    if bagsDirty and now - lastBags >= BAG_THROTTLE then ScanBags() changed = true end
    if auraDirty and now - lastScan >= SCAN_THROTTLE then ScanAuras() changed = true end
    if changed or now - lastText >= TEXT_TICK then Render() end
end

local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function()
    local ok, err = pcall(Tick)
    if not ok then Fail("update", err) end
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
    local ok, err = pcall(function()
        if event == "PLAYER_LOGIN" then
            CreatePanel()
            for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "UNIT_AURA",
                "BAG_UPDATE_DELAYED", "SPELLS_CHANGED" }) do
                self:RegisterEvent(e)
            end
            pcall(self.RegisterEvent, self, "LEARNED_SPELL_IN_TAB")
            ticker:Show()
        elseif event == "PLAYER_ENTERING_WORLD" then
            ApplyPosition()
            auraDirty, bagsDirty, spellsDirty = true, true, true
        elseif event == "PLAYER_REGEN_ENABLED" then
            -- Everything frozen in combat is read again, and the buttons bound.
            ApplyPosition()
            auraDirty, bagsDirty, bindPending = true, true, true
        elseif event == "UNIT_AURA" then
            if Secret(arg1) or arg1 ~= "player" then return end
            auraDirty = true
        elseif event == "BAG_UPDATE_DELAYED" then
            bagsDirty = true
        elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
            spellsDirty = true
        end
    end)
    if not ok then Fail(event, err) end
end)

-- For the headless test (tools/test/buffs_selfbuffs_test.lua); nothing in the game uses it.
ns.SelfBuffs = {
    KEYWORDS = KEYWORDS, Classify = Classify, IsXpFoodText = IsXpFoodText,
    ScanAuras = ScanAuras, ScanBags = ScanBags, ResolveFire = ResolveFire, Render = Render, Tick = Tick,
    State = function() return state, food, fireSpell, learned end,
    Rows = function() return rows, panel end,
    Events = events,
}
