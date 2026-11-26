-- LuaJIT stub test: GaarBarsForever 1.6.0 "Flyouts v2" - a flyout is its own object carried on the
-- bars by its own macro ("GF <name>"). Covers: macro identity and re-resolve after a macro reorder,
-- the macro slots (character, then account, then a chat line), the same key casting entry 1
-- (setting on and off, in combat), right-click, the one-time v1 -> v2 conversion (a paged main-bar
-- slot included, deferred while in combat), the "+" create and add paths, removal down to one
-- entry (kept), the editor API and the Missing-from-bars entries.
-- Run: luajit tools/test/bars_flyouts_v2_test.lua   (from the repo root)
local H = dofile("tools/test/bars_flyout_helper.lua")

local function find(list, s) for _, x in ipairs(list) do if x:find(s, 1, true) then return x end end end

-- ---------------------------------------------------------------------------------------------
-- 1. Identity: a flyout's macro, created by the addon; a plain spell elsewhere is not a flyout
-- ---------------------------------------------------------------------------------------------
do
    local T = H({ editor = true, charDB = { flyoutsV1Done = true, flyouts2 = {
        [1] = { name = "Travel", entries = { { t = "spell", id = 783 }, { t = "spell", id = 1066 } } },
    } } })
    local check, G, FL = T.check, T.G, T.FL
    T.spellNames[783] = "Travel Form"
    T.AddMacro("Other", "/dance", true)
    T.actions = { [2] = { "spell", 783 } }
    T.Login()
    local f = FL.Get(1)
    check(f.macro == "GF Travel", "macro made: " .. tostring(f.macro))
    local m = T.MacroByIndex("GF Travel")
    check(m and T.MacroIndexOf(m) > 120, "a character macro")
    check(m.body == "#showtooltip\n/cast Travel Form", "body casts entry 1: " .. tostring(m and m.body))
    check(m.icon == 1783, "icon = entry 1's icon")
    -- Put it on the bar with the editor's drag handle (PickupMacro) and drop it on slot 61.
    check(FL.Pickup(1) and T.cursor and T.cursor[2] == m, "Pickup puts the macro on the cursor")
    G.PlaceAction(61); G.ClearCursor()
    T.Event("ACTIONBAR_SLOT_CHANGED"); T.Tick()
    local o61 = T.OverlayOf(G.MultiBarBottomLeftButton1)
    check(o61 and o61.shown and o61.attrs.curslot == 61, "slot 61 (the macro) has the flyout")
    check(T.OverlayOf(G.ActionButton2) == nil, "slot 2 (a plain Travel Form) has no flyout")
    check(FL.SlotCount(f) == 1, "on 1 button")
    -- Macros re-index when one is created: "AAA" sorts before ours in the character section.
    local before = T.MacroIndexOf(m)
    T.AddMacro("AAA", "", true)
    local after = T.MacroIndexOf(m)
    check(after == before + 1, "our macro moved down one index")
    T.Event("UPDATE_MACROS"); T.Tick()
    local map = G.GaarBarsForeverCharDB.flyoutMacros
    check(map[after] == 1 and map[before] == nil, "macro index -> flyout id map re-resolved")
    check(f.macroIndex == after, "flyout.macroIndex follows")
    -- Without the slot's macro name, the saved map (checked against the name) still finds it.
    T.noActionText = true
    FL.Refresh()
    check(o61.shown and o61.attrs.type2 == "spell" and o61.attrs.spell2 == 783, "found by macro index after a reorder")
    T.noActionText = false
    -- Rename: the macro follows (16 bytes at most), the slot keeps it.
    FL.Rename(1, "Travelling forms")
    check(f.name == "Travelling forms" and f.macro == "GF Travelling fo", "renamed: " .. tostring(f.macro))
    check(m.name == "GF Travelling fo" and T.actions[61][2] == m, "macro renamed in place, still on slot 61")
    FL.Refresh()
    check(o61.shown, "still a flyout after the rename")
    -- A name taken by another macro gets a number.
    T.AddMacro("GF Mount", "", false)
    local nf = FL.New()
    FL.Rename(nf.id, "Mount")
    check(nf.macro == "GF Mount2", "taken name gets a number: " .. tostring(nf.macro))
    -- Character macros full: an account macro. Both full: a chat line, no flyout.
    while #T.char < 18 do T.AddMacro("Z" .. #T.char, "", true) end
    local na = FL.New()
    check(na and T.MacroIndexOf(T.MacroByIndex(na.macro)) <= 120, "character macros full: account macro")
    while #T.acc < 120 do T.AddMacro("Y" .. #T.acc, "", false) end
    T.printed = {}
    local none = FL.New()
    check(none == nil and find(T.printed, "no free macro slot"), "both full: no flyout, a chat line")
    -- Editor: opens, shows the flyouts, refreshes without errors; Delete removes flyout and macro.
    T.NS.Bars.OpenFlyoutEditor()
    check(T.frames.GaarBarsForeverFlyoutEditor and T.frames.GaarBarsForeverFlyoutEditor.shown, "editor opens")
    check(FL.Delete(nf.id) and FL.Get(nf.id) == nil and T.MacroByIndex("GF Mount2") == nil, "Delete removes flyout and macro")
    T.combat = true
    T.printed = {}
    check(FL.Rename(1, "X") == false and find(T.printed, "out of combat"), "edits refused in combat")
    T.NS.Bars.FlyoutEditorRefresh()
    T.combat = false
    check(not T.failed, "identity: no error caught")
end

-- ---------------------------------------------------------------------------------------------
-- 2. Same key casts entry 1 (setting on / off, in combat), right-click, items you have none of
-- ---------------------------------------------------------------------------------------------
local T = H({ charDB = { flyoutsV1Done = true, flyouts2 = {
    [1] = { name = "Cat", macro = "GF Cat", entries = { { t = "spell", id = 768 }, { t = "spell", id = 5487 } } },
    [2] = { name = "Pot", macro = "GF Pot", entries = { { t = "item", id = 900 }, { t = "spell", id = 1 } } },
} } })
local check, G, FL, Click = T.check, T.G, T.FL, T.Click
local mCat, mPot = T.AddMacro("GF Cat", "", true), T.AddMacro("GF Pot", "", true)
T.actions = { [61] = { "macro", mCat }, [1] = { "macro", mPot } }
T.itemCount[900] = 0
T.Login()
local h = T.Header()
local o = T.OverlayOf(G.MultiBarBottomLeftButton1)  -- key F1
local o1 = T.OverlayOf(G.ActionButton1)             -- key 1
check(h.attrs.samekey == true, "samekey on by default")
check(FL.StatusLine():find("same key: casts entry 1", 1, true), "status: same key casts entry 1")
check(T.Key(o, "F1") == "cancelled" and h.attrs.open == 61, "key opens the flyout")
check(T.Key(o, "F1") == "cast spell=768" and h.attrs.open == 0, "same key again: entry 1 cast, closed")
check(T.Key(o, "F1") == "cancelled" and h.attrs.open == 61, "key opens again")
check(Click(o, "LeftButton") == "cancelled" and h.attrs.open == 0, "mouse left-click on the open flyout's button closes it")
check(Click(o, "RightButton") == "cast spell=768", "right-click casts entry 1")
-- Another flyout open: the key opens this one instead (no cast).
check(Click(o1, "LeftButton") == "cancelled" and h.attrs.open == 1, "slot 1's flyout open")
check(T.Key(o, "F1") == "cancelled" and h.attrs.open == 61, "key of another flyout's button opens its own flyout")
Click(o, "LeftButton")
-- Entry 1 an item you have none of: the same key closes and does nothing.
check(T.Key(o1, "1") == "cancelled" and h.attrs.open == 1, "item flyout opens")
check(T.Key(o1, "1") == "no action" and h.attrs.open == 0, "item entry 1 with none: closed, nothing cast")
-- In combat.
T.SetCombat(true)
check(T.Key(o, "F1") == "cancelled" and h.attrs.open == 61, "combat: key opens")
check(T.Key(o, "F1") == "cast spell=768" and h.attrs.open == 0, "combat: same key casts entry 1")
-- Setting off (in combat it waits for the fight to end).
FL.SlashSameKey("samekey off")
check(T.db.flyoutSameKeyCast == false and h.attrs.samekey == true, "combat: setting saved, header waits")
T.SetCombat(false)
check(h.attrs.samekey == false, "after combat: header samekey off")
check(FL.StatusLine():find("same key: closes", 1, true), "status: same key closes")
check(T.Key(o, "F1") == "cancelled" and h.attrs.open == 61, "off: key opens")
check(T.Key(o, "F1") == "cancelled" and h.attrs.open == 0, "off: same key closes, nothing cast")
T.SetCombat(true)
check(T.Key(o, "F1") == "cancelled" and T.Key(o, "F1") == "cancelled" and h.attrs.open == 0, "off, combat: open, close")
T.SetCombat(false)
FL.SlashSameKey("samekey on")
check(h.attrs.samekey == true, "on again")

-- Removing down to one entry keeps the flyout (right-click in the open flyout).
Click(o, "LeftButton")
local e2 = T.frames.GaarBarsForeverFlyout61Entry2
e2.scripts.hookOnClick(e2, "RightButton", false)
check(#FL.Get(1).entries == 1 and FL.Get(1).macro == "GF Cat" and T.MacroByIndex("GF Cat"), "one entry left: flyout and macro kept")
check(T.actions[61][2] == mCat and o.shown, "still on the bar with an overlay")
local e1 = T.frames.GaarBarsForeverFlyout61Entry1
Click(o, "LeftButton")
e1.scripts.OnDragStart(e1)
check(#FL.Get(1).entries == 0 and FL.Get(1) ~= nil, "zero entries: still kept (deleted only in the editor)")
check(T.cursor and T.cursor[1] == "spell" and T.cursor[2] == 768, "dragged out onto the cursor")
G.ClearCursor()
check(not o.shown, "no entries: no overlay")
check(mCat.body == "#showtooltip", "macro body with no entry 1: " .. mCat.body)
check(not T.failed, "same key: no error caught")

-- ---------------------------------------------------------------------------------------------
-- 3. "+" quick-create and add
-- ---------------------------------------------------------------------------------------------
T.actions[2] = { "spell", 33 }
T.spellNames[33] = "Moonfire"
local function Plus(btn)
    T.Event("CURSOR_CHANGED")
    for _, f in ipairs(T.frames) do
        if f.parent == btn and f.scripts.OnReceiveDrag and f.btn == btn then return f end
    end
end
T.cursor = { "spell", 44 }
local p2 = Plus(G.ActionButton2)
check(p2 and p2.shown, "+ shows on a normal button while the cursor holds a spell")
p2.scripts.OnReceiveDrag(p2)
local nf
for _, f in ipairs(FL.List()) do if f.name == "Moonfire" then nf = f end end
check(nf and #nf.entries == 2 and nf.entries[1].id == 33 and nf.entries[2].id == 44, "new flyout: entry 1 = button, entry 2 = dropped")
check(nf and nf.icon == nil and FL.Icon(nf) == 1033, "icon = entry 1's icon")
check(nf and T.actions[2][1] == "macro" and T.actions[2][2].name == "GF Moonfire", "its macro replaced the button's action")
check(T.cursor == nil, "cursor cleared")
local o2 = T.OverlayOf(G.ActionButton2)
check(o2 and o2.shown and o2.attrs.spell2 == 33, "the button opens the new flyout; right-click casts entry 1")
T.cursor = { "item", 55 }
p2 = Plus(G.ActionButton2)
p2.scripts.OnReceiveDrag(p2)
check(#nf.entries == 3 and nf.entries[3].t == "item" and nf.entries[3].id == 55 and T.cursor == nil, "+ on a flyout button adds to it")
T.cursor = { "spell", 44 }
p2 = Plus(G.ActionButton2)
p2.scripts.OnReceiveDrag(p2)
check(#nf.entries == 3 and T.cursor == nil, "duplicate ignored, cursor cleared")
-- Holding a flyout's own macro: no "+" (it is being placed, not added).
FL.Pickup(nf.id)
T.Event("CURSOR_CHANGED")
check(not p2.shown, "no + while the cursor holds a flyout macro")
G.ClearCursor()
-- The editor's drop zone adds the same way.
T.cursor = { "spell", 66 }
FL.AddCursor(nf.id)
check(#nf.entries == 4 and T.cursor == nil, "editor drop zone adds")
FL.Move(nf.id, 4, -1)
check(nf.entries[3].id == 66, "move up")
FL.RemoveAt(nf.id, 3)
check(#nf.entries == 3, "remove")
-- Missing from bars: entries of flyouts whose macro is on a bar.
local got = {}
for _, e in ipairs(T.NS.Bars.FlyoutBarEntries()) do got[e.t .. (e.id or e.name)] = true end
check(got.spell33 and got.spell44 and not got.item55, "FlyoutBarEntries: spells of flyouts on bars")
check(not T.failed, "+: no error caught")

-- ---------------------------------------------------------------------------------------------
-- 4. v1 -> v2 conversion: Thomas's druid, two flyouts (5 entries), one on a page-7 slot
-- ---------------------------------------------------------------------------------------------
local v1 = {
    ["spell:768"] = { { t = "spell", id = 768 }, { t = "spell", id = 783 }, { t = "spell", id = 5487 } },
    ["spell:1082"] = { { t = "spell", id = 1082 }, { t = "spell", id = 1079 } },
}
local C = H({ charDB = { flyouts = v1 } })
C.spellNames[768], C.spellNames[1082] = "Cat Form", "Claw"
-- 61 and 5 hold Cat Form (both showed its flyout), 75 = Claw on the cat bar (page 7), 6 = Travel
-- Form (no flyout of its own), 7 = a companion keyed by its slot in v1.
C.actions = { [61] = { "spell", 768 }, [5] = { "spell", 768 }, [75] = { "spell", 1082 }, [6] = { "spell", 783 },
    [7] = { "companion", 3 } }
v1["slot:7"] = { { t = "action", id = 7 }, { t = "spell", id = 99 } }
for i = 1, 12 do C.G["ActionButton" .. i].action = 72 + i end
C.page = "7"
C.combat = true
C.Login()
C.check(C.G.GaarBarsForeverCharDB.flyoutsV1Done == nil and C.actions[75][1] == "spell", "in combat: not converted yet")
C.check(C.FL.StatusLine():find("v1: not yet", 1, true), "status: v1 not yet")
C.SetCombat(false)
local cdb = C.G.GaarBarsForeverCharDB
C.check(cdb.flyoutsV1Done == true and cdb.flyouts == nil, "converted once, v1 data moved")
C.check(cdb.flyoutsV1Backup and cdb.flyoutsV1Backup["spell:768"][3].id == 5487 and cdb.flyoutsV1Backup["slot:7"], "v1 backup kept")
local byName = {}
for _, f in ipairs(C.FL.List()) do byName[f.name] = f end
C.check(byName["Cat Form"] and #byName["Cat Form"].entries == 3 and byName["Cat Form"].macro == "GF Cat Form", "Cat Form flyout")
C.check(byName.Claw and #byName.Claw.entries == 2 and byName.Claw.macro == "GF Claw", "Claw flyout")
C.check(byName["Action 7"] and byName["Action 7"].macro, "slot-keyed flyout converted too")
C.check(C.actions[61][1] == "macro" and C.actions[61][2].name == "GF Cat Form", "slot 61 holds the Cat Form macro")
C.check(C.actions[5][1] == "macro" and C.actions[5][2].name == "GF Cat Form", "slot 5 holds the Cat Form macro")
C.check(C.actions[75][1] == "macro" and C.actions[75][2].name == "GF Claw", "paged slot 75 (cat bar) holds the Claw macro")
C.check(C.actions[6][1] == "spell" and C.actions[6][2] == 783, "Travel Form (slot 6) untouched")
C.check(C.actions[7][1] == "companion", "slot-keyed action untouched")
C.check(C.cursor == nil, "cursor clear")
C.check(find(C.printed, "converted 3 flyouts (3 bar buttons now hold their macro)"), "chat: " .. tostring(C.printed[#C.printed]))
local o3 = C.OverlayOf(C.G.ActionButton3)
C.check(o3 and o3.shown and o3.attrs.curslot == 75 and o3.attrs.spell2 == 1082, "page 7: ActionButton3 opens Claw, right-click casts it")
C.check(C.Click(o3, "LeftButton") == "cancelled" and C.Header().attrs.open == 75, "page 7: opens")
C.check(C.FL.StatusLine():find("v1: converted 3 flyouts", 1, true), "status: " .. C.FL.StatusLine())
local creates = C.macroCalls.create
C.Event("PLAYER_ENTERING_WORLD"); C.Tick(); C.FL.Refresh()
C.check(C.macroCalls.create == creates and #C.FL.List() == 3, "not converted twice")
local edits = C.macroCalls.edit
C.FL.Refresh(); C.FL.Refresh()
C.check(C.macroCalls.edit == edits, "no macro edits when nothing changed")
C.check(not C.failed, "conversion: no error caught")

-- Nothing to convert: no chat line, marked done.
local N = H({ charDB = {} })
N.Login()
N.check(N.G.GaarBarsForeverCharDB.flyoutsV1Done and N.G.GaarBarsForeverCharDB.flyoutsV1Result == "nothing to convert"
    and #N.printed == 0, "no v1 data: done quietly")

T.done()
