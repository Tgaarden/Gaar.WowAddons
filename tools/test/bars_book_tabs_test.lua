-- GaarBarsForever BookTab.lua (1.6.1) in a stub client: the flyout editor's button is a tab exactly
-- like ours, our stand-in covers Blizzard's selected category tab only while our panel is open,
-- and Blizzard's own marks on its spellbook items (the not-on-bars glow, the rotation helper
-- frame) are hidden only where they should be. Blizzard's frames are watched: any method call on
-- them other than a read (Get* / Is* / HookScript) or a field write other than hooksecurefunc's
-- fails the test, except the two item textures this release hides and shows on purpose.
-- Run from the repo root: luajit tools/test/bars_book_tabs_test.lua
local passes, fails = 0, 0
local function check(cond, msg)
    if cond then passes = passes + 1 else fails = fails + 1; print("FAIL " .. msg) end
end

-- Frames --------------------------------------------------------------------------------------
local writes = {}       -- violations on Blizzard objects
local allowWrite = {}   -- Blizzard regions we may Hide/Show (the two item marks)
local hooking = false   -- inside our hooksecurefunc stub

local Obj = {}
local function isRead(k) return k:match("^Get") or k:match("^Is") or k:match("^Has") or k == "HookScript" end

local function new(kind, parent, blizz, template)
    local o = { kind = kind, parent = parent, blizz = blizz, template = template, shown = true,
        points = {}, scripts = {}, attrs = {}, level = 1, w = 36, h = 36 }
    return setmetatable(o, Obj)
end

Obj.__index = function(t, k)
    local m = rawget(Obj, k)
    if m then
        if rawget(t, "blizz") and not isRead(k) and not (allowWrite[t] and (k == "Hide" or k == "Show")) then
            writes[#writes + 1] = tostring(rawget(t, "name") or "blizz") .. ":" .. k
        end
        return m
    end
    if type(k) == "string" and k:match("^%u") then
        if rawget(t, "blizz") and not isRead(k) then
            return function() writes[#writes + 1] = tostring(rawget(t, "name") or "blizz") .. ":" .. k end
        end
        return function() return nil end
    end
    return nil
end
Obj.__newindex = function(t, k, v)
    if rawget(t, "blizz") and not hooking then writes[#writes + 1] = "field " .. tostring(k) end
    rawset(t, k, v)
end

function Obj:Show() rawset(self, "shown", true) end
function Obj:Hide() rawset(self, "shown", false) end
function Obj:SetShown(v) if v then self:Show() else self:Hide() end end
function Obj:IsShown() return rawget(self, "shown") end
function Obj:IsVisible() return rawget(self, "shown") end
function Obj:SetSize(w, h) rawset(self, "w", w); rawset(self, "h", h) end
function Obj:GetWidth() return rawget(self, "w") end
function Obj:GetHeight() return rawget(self, "h") end
function Obj:GetSize() return rawget(self, "w"), rawget(self, "h") end
function Obj:SetPoint(...) table.insert(rawget(self, "points"), { ... }) end
function Obj:ClearAllPoints() rawset(self, "points", {}) end
function Obj:SetAllPoints(rel) rawset(self, "points", { { "ALL", rel } }) end
function Obj:GetPoint(i) local p = rawget(self, "points")[i or 1]; if p then return unpack(p) end end
function Obj:SetFrameLevel(l) rawset(self, "level", l) end
function Obj:GetFrameLevel() return rawget(self, "level") end
function Obj:SetScript(k, fn) rawget(self, "scripts")[k] = fn end
function Obj:GetScript(k) return rawget(self, "scripts")[k] end
function Obj:HookScript(k, fn) rawget(self, "scripts")["hook" .. k] = fn end
function Obj:SetAtlas(a) rawset(self, "atlas", a); return true end
function Obj:GetAtlas() return rawget(self, "atlas") end
function Obj:SetTexture(t) rawset(self, "texture", t) end
function Obj:GetTexture() return rawget(self, "texture") end
function Obj:GetTexCoord() return 0, 0, 0, 1, 1, 0, 1, 1 end
function Obj:SetVertexColor() end
function Obj:CreateTexture(_, layer)
    local t = new("Texture", self, false); rawset(t, "layer", layer); return t
end
function Obj:CreateFontString() return new("FontString", self, false) end
function Obj:CreateMaskTexture() return new("MaskTexture", self, false) end
function Obj:CreateAnimationGroup() return new("AnimationGroup", self, false) end
function Obj:CreateAnimation() return new("Animation", self, false) end
function Obj:SetHighlightTexture(tex) rawset(self, "hl", new("Texture", self, false)); rawget(self, "hl").file = tex end
function Obj:GetHighlightTexture() return rawget(self, "hl") end
function Obj:SetAttribute(k, v) rawget(self, "attrs")[k] = v end
function Obj:GetAttribute(k) return rawget(self, "attrs")[k] end
function Obj:IsProtected() return rawget(self, "template") ~= nil end
function Obj:GetText() return rawget(self, "text") end
function Obj:GetFrameStrata() return "MEDIUM" end
function Obj:GetTop() return 600 end
function Obj:GetBottom() return 560 end
function Obj:GetLeft() return 0 end
function Obj:GetRight() return 800 end
function Obj:Click() local f = rawget(self, "scripts").OnClick; if f then f(self, "LeftButton") end end
function Obj:IsPlaying() return rawget(self, "playing") == true end

local created = {}
function CreateFrame(kind, _, parent, template)
    local f = new(kind, parent, false, template)
    created[#created + 1] = f
    return f
end

local function blizzFrame(name, extra)
    local f = new("Frame", nil, true)
    rawset(f, "name", name)
    for k, v in pairs(extra or {}) do rawset(f, k, v) end
    return f
end

function hooksecurefunc(t, k, fn)
    local orig = t[k]
    hooking = true
    t[k] = function(...) local r = { orig(...) }; fn(...); return unpack(r) end
    hooking = false
end

-- Client -------------------------------------------------------------------------------------
UIParent = new("Frame", nil, false)
GameTooltip = new("Frame", nil, false)
Enum = { SpellBookItemType = { Spell = 1, Flyout = 2 }, SpellBookSpellBank = { Player = 0 } }
local IDS = { CurePoison = 8946, Wrath = 5177, Thorns = 782 }
local NAMES = { [8946] = "Cure Poison", [5177] = "Wrath", [782] = "Thorns" }
C_Spell = {
    GetSpellName = function(id) return NAMES[id] end,
    GetSpellSubtext = function() return "" end,
    GetSpellTexture = function() return 134400 end,
    IsSpellPassive = function() return false end,
}
C_Texture = { GetAtlasInfo = function(a) return a and { file = 1 } or nil end }
C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 0 end,
    GetSpellBookSkillLineInfo = function() return nil end,
    GetSpellBookItemInfo = function() return nil end,
}
local slots = {}
C_ActionBar = {
    HasAction = function(s) return slots[s] ~= nil end,
    FindSpellActionButtons = function() return {} end,
}
function GetActionInfo(s) local a = slots[s]; if a then return a[1], a[2] end end
function GetMacroSpell() return nil end
function issecretvalue() return false end

-- Blizzard's spellbook: two category tabs (the second selected), page backgrounds, one page of
-- items (Cure Poison in a flyout, Wrath nowhere, Thorns a rotation helper spell).
local function tab(i, icon)
    local t = blizzFrame("Tab" .. i, { w = 44, h = 32, level = 10 })
    local ic = new("Texture", t, true); rawset(ic, "name", "TabIcon" .. i); rawset(ic, "texture", icon); rawset(ic, "w", 34); rawset(ic, "h", 33)
    local fr = new("Texture", t, true); rawset(fr, "atlas", "spellbook-Tab-Frame-C60")
    local gl = new("Texture", t, true); rawset(gl, "atlas", "spellbook-Tab-Frame-Glow-C60")
    rawset(t, "Icon", ic)
    rawset(t, "GetRegions", function() return ic, fr, gl end)
    rawset(t, "text", "Tab " .. i)
    return t
end
local tabs = { tab(1, 111), tab(2, 222) }
local tabSystem = blizzFrame("TabSystem", { tabs = tabs, selectedTabID = 2 })
rawset(tabSystem, "SetTab", function(self, id) rawset(self, "selectedTabID", id) end)
rawset(tabSystem, "SetTabShown", function() end)

local function item(id, glowPlaying, coverShown)
    local el = blizzFrame("Item" .. id)
    local btn = blizzFrame("Button" .. id)
    local hl = blizzFrame("Glow" .. id, { shown = glowPlaying })
    rawset(hl, "Anim", blizzFrame("Anim" .. id, { playing = glowPlaying }))
    local cv = blizzFrame("Cover" .. id, { shown = coverShown })
    allowWrite[hl], allowWrite[cv] = true, true
    rawset(btn, "ActionBarHighlight", hl)
    rawset(btn, "AssistedCombatIconCover", cv)
    rawset(el, "Button", btn)
    rawset(el, "spellBookItemInfo", { itemType = 1, actionID = id, spellID = id })
    -- Blizzard's own update ends, as in Blizzard_SpellBookItem.lua (the anim shows / hides it).
    rawset(el, "UpdateActionBarAnim", function(self, playing)
        local a = rawget(rawget(rawget(self, "Button"), "ActionBarHighlight"), "Anim")
        if playing ~= nil then
            if playing and not rawget(a, "playing") then rawset(a, "playing", true); rawset(hl, "shown", true) end
            if not playing and rawget(a, "playing") then rawset(a, "playing", false); rawset(hl, "shown", false) end
        end
    end)
    rawset(el, "UpdateAssistedCombatState", function(self, show) rawset(cv, "shown", show and true or false) end)
    return el
end
local items = { item(IDS.CurePoison, true, false), item(IDS.Wrath, true, false), item(IDS.Thorns, false, true) }
local paged = blizzFrame("PagedSpellsFrame", { frames = items, ViewFrames = {} })
rawset(paged, "DisplayViewsForCurrentPage", function() end)
local bgL = blizzFrame("BookBGLeft", { atlas = "spellbook-Page-Left-C60" })
local book = blizzFrame("SpellBookFrame", {
    CategoryTabSystem = tabSystem, PagedSpellsFrame = paged, BookBGLeft = bgL,
    SearchBox = blizzFrame("SearchBox"),
})
rawset(book, "SetTab", function() end)
rawset(book, "SetMinimized", function() end)
PlayerSpellsFrame = blizzFrame("PlayerSpellsFrame", { SpellBookFrame = book, NineSlice = blizzFrame("NineSlice", { level = 5 }) })

-- The addon: the main file's shared table, with flyouts holding Cure Poison on a bar.
local db = { enabled = true, bookMissingTab = true, flyouts = true }
local flyout = { { t = "spell", id = IDS.CurePoison } }
local function num(v) return type(v) == "number" and v or tonumber(v) end
local B = {
    On = function(k) return db.enabled ~= false and db[k] == true end,
    InCombat = function() return false end,
    Secret = function() return false end,
    Num = num,
    FieldOf = function(t, k) local ok, v = pcall(function() return t[k] end); return ok and v or nil end,
    SpellName = function(id) return NAMES[id] end,
    SpellRank = function() return nil end,
    DB = function() return db end,
    Fail = function(w, e) print("ADDON FAIL " .. tostring(w) .. ": " .. tostring(e)) end,
    FlyoutBarEntries = function() return flyout end,
}
B.OpenFlyoutEditor = function() B.editorOpened = true end
B.CallOf = function(t, m, ...)
    local f = B.FieldOf(t, m)
    if type(f) ~= "function" then return nil end
    local ok, a = pcall(f, t, ...)
    return ok and a or nil
end
local NS = { Bars = B }
local chunk = assert(loadfile("addons/GaarBarsForever/BookTab.lua"))
chunk("GaarBarsForever", NS)
local BT = NS.BookTab

-- The events frame is the last frame the file made at load: fire Blizzard_PlayerSpells' load.
local events
for i = #created, 1, -1 do
    if created[i].scripts.OnEvent then events = created[i] break end
end
events.scripts.OnEvent(events, "ADDON_LOADED", "Blizzard_PlayerSpells")
local driver
for _, f in ipairs(created) do if f.scripts.OnUpdate then driver = f break end end

-- 1. The flyout editor's button is a tab like ours ---------------------------------------------
local function findTab()
    for _, f in ipairs(created) do
        if f.kind == "Button" and f.parent == book and f.Count then return f end
    end
end
local our = findTab()
check(our ~= nil, "our tab is built")
local fb
for _, f in ipairs(created) do if f.kind == "Button" and f.parent == our then fb = f end end
check(fb ~= nil, "flyout editor button is a child of our tab")
check(fb and fb.w == our.w and fb.h == our.h, "flyout button has our tab's size")
check(fb and fb.Icon.w == our.Icon.w and fb.Icon.h == our.Icon.h, "flyout button icon has our tab's icon size")
check(fb and fb.style == our.style and fb.style == "forever", "flyout button wears Forever's tab art")
check(fb and fb.Normal and fb.Normal.atlas == our.Normal.atlas, "flyout button has the same frame atlas")
check(fb and fb:GetHighlightTexture() and fb:GetHighlightTexture().file == our:GetHighlightTexture().file,
    "flyout button has the same highlight")
check(fb and fb.Normal.shown and not (fb.Active and fb.Active.shown), "flyout button never looks selected")
local p = fb and fb.points[1]
check(p and p[1] == "LEFT" and p[2] == our and p[3] == "RIGHT", "flyout button sits right of our tab")
fb.scripts.OnClick(fb)
check(B.editorOpened == true, "flyout button opens the editor")

-- 2. Stand-in over Blizzard's selected tab -------------------------------------------------------
book.scripts.hookOnShow(book)
local function standIn()
    for _, f in ipairs(created) do if f.parent == book and f.face then return f end end
end
local h = standIn()
check(h ~= nil and not h.shown, "stand-in built, hidden while our panel is closed")
our.scripts.OnClick(our)
check(our.selected == true, "our tab looks selected when open")
check(h.shown, "stand-in shown while our panel is open")
check(h.points[1] and h.points[1][2] == tabs[2], "stand-in covers the selected Blizzard tab")
check(h.face.selected == false and h.face.Normal.shown and not h.face.Active.shown,
    "stand-in face is in the plain (deselected) look")
check(h.face.Icon.texture == 222 and h.face.Icon.points[1][2] == tabs[2].Icon, "stand-in wears that tab's icon on its rect")
check(h.level > tabs[2].level and h.face.level > h.cover.level, "stand-in drawn above Blizzard's tab, face above cover")
local mirrored = false
for _, tex in pairs(h.bg.mirrors) do if tex.atlas == "spellbook-Page-Left-C60" and tex.shown then mirrored = true end end
check(mirrored, "stand-in cover mirrors the book's page background")
check(tabSystem.selectedTabID == 2, "Blizzard's selected tab is not changed")
-- A click on the stand-in closes our panel; Blizzard's tab stays as it was.
h.face.scripts.OnClick(h.face)
check(not h.shown and our.selected == false, "click on the stand-in closes our panel and the stand-in")
-- Reopen, then a Blizzard tab click (its SetTab, hooked) puts everything back.
our.scripts.OnClick(our)
check(h.shown, "stand-in back when reopened")
tabSystem:SetTab(1)
check(not h.shown and our.selected == false, "a Blizzard tab click hides the stand-in and closes ours")

-- 3. Blizzard's item marks ------------------------------------------------------------------------
local function glow(i) return items[i].Button.ActionBarHighlight end
local function cover(i) return items[i].Button.AssistedCombatIconCover end
paged:DisplayViewsForCurrentPage()
check(not glow(1).shown, "Cure Poison (in a flyout on a bar): Blizzard's not-on-bars glow hidden")
check(glow(2).shown, "Wrath (on no bar): Blizzard's glow stays")
check(not cover(3).shown, "rotation helper frame hidden by default")
-- Blizzard re-runs its own update: our hook follows.
items[1]:UpdateActionBarAnim(true)
check(not glow(1).shown, "glow stays hidden after Blizzard's own update")
items[3]:UpdateAssistedCombatState(true)
check(not cover(3).shown, "rotation frame stays hidden after Blizzard's own update")
-- Flyout changed: Cure Poison taken out. MissingDirty + the driver's next tick bring the glow back.
flyout = {}
B.MissingDirty()
driver.scripts.OnUpdate(driver, 1)
check(glow(1).shown, "glow back once the spell is no longer in a flyout")
flyout = { { t = "spell", id = IDS.CurePoison } }
B.MissingDirty()
driver.scripts.OnUpdate(driver, 1)
check(not glow(1).shown, "glow hidden again once it is back in a flyout")
-- Wrath put on a bar slot directly.
slots[5] = { "spell", IDS.Wrath }
B.MissingDirty()
driver.scripts.OnUpdate(driver, 1)
check(not glow(2).shown, "glow hidden for a spell put on a bar (our scan)")
-- /gbars bookframe on shows Blizzard's rotation frame again; off hides it.
db.bookFrame = true
BT.Apply()
check(cover(3).shown, "bookframe on: rotation helper frame shown")
items[3]:UpdateAssistedCombatState(false)
check(not cover(3).shown, "Blizzard's own hide still wins")
items[3]:UpdateAssistedCombatState(true)
db.bookFrame = false
BT.Apply()
check(not cover(3).shown, "bookframe off: hidden again")
-- Master switch off: Blizzard's look everywhere.
db.enabled = false
BT.Apply()
check(cover(3).shown, "addon off: rotation frame as Blizzard set it")
check(glow(1).shown, "addon off: Blizzard's glow as Blizzard set it")
db.enabled = true
check(type(BT.MarksLine) == "function" and BT.MarksLine():find("rotation helper") ~= nil, "status line for the marks")

-- 4. Nothing of Blizzard's written ------------------------------------------------------------------
check(#writes == 0, "no writes to Blizzard's frames: " .. table.concat(writes, ", "))

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
