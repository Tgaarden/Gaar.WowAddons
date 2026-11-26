-- LuaJIT stub test: GaarBarsForever flyouts - right-click on a button with a flyout casts the flyout's
-- entry 1 (type2 / spell2 / item2 / macro2 on the overlay), left click toggles it, the main bar's
-- paging moves the right-click action in combat, an item you have none of clears it, and the
-- /gbars status right-click line. Since 1.6.0 (Flyouts v2) a button has a flyout when it holds
-- the flyout's own macro ("GF <name>"). Restricted code runs through handle proxies that only have
-- the methods the real restricted environment has (no :Click()), and SetAttribute on a protected
-- frame from addon code in combat raises, like the client.
-- Run: luajit tools/test/bars_flyout_rightclick_test.lua   (from the repo root)
local T = dofile("tools/test/bars_flyout_helper.lua")({ charDB = {
    flyoutsV1Done = true,
    flyouts2 = {
        [1] = { name = "A", macro = "GF A", entries = { { t = "spell", id = 100 }, { t = "spell", id = 200 }, { t = "item", id = 300 } } },
        [2] = { name = "B", macro = "GF B", entries = { { t = "spell", id = 500 }, { t = "spell", id = 600 } } },
        [3] = { name = "C", macro = "GF C", entries = { { t = "item", id = 900 }, { t = "spell", id = 901 } } },
        [4] = { name = "D", macro = "GF D", entries = { { t = "macro", name = "Foo" }, { t = "spell", id = 902 } } },
    },
} })
local check, Click, G, FL = T.check, T.Click, T.G, T.FL
local mA, mB, mC, mD = T.AddMacro("GF A", "", true), T.AddMacro("GF B", "", true), T.AddMacro("GF C", "", true), T.AddMacro("GF D", "", true)
T.AddMacro("Foo", "/say foo", false)
-- Slots: 1 = flyout A (ActionButton1, page 1), 13 = flyout B (ActionButton1 on page 2),
-- 61 = flyout C (entry 1 an item you have none of), 62 = flyout D (entry 1 macro "Foo").
T.actions = { [1] = { "macro", mA }, [13] = { "macro", mB }, [61] = { "macro", mC }, [62] = { "macro", mD } }
T.itemCount[900] = 0
T.Login()

local h = T.Header()
local o1, o61, o62 = T.OverlayOf(G.ActionButton1), T.OverlayOf(G.MultiBarBottomLeftButton1), T.OverlayOf(G.MultiBarBottomLeftButton2)

-- Out of combat -----------------------------------------------------------------------------
check(h ~= nil and o1 and o61 and o62, "header and three overlays built")
check(o1.template == "SecureActionButtonTemplate", "overlay is a SecureActionButtonTemplate")
check(o1.attrs._onclick == nil, "no _onclick snippet on the overlay")
check(o1.wrap and o1.wrap.header == h, "overlay OnClick wrapped by the header")
check(o1.attrs.useOnKeyDown == false, "useOnKeyDown = false")
check(o1.shown and o1.attrs.curslot == 1, "ActionButton1 overlay live on slot 1")
check(o1.attrs.type2 == "spell" and o1.attrs.spell2 == 100, "type2/spell2 = entry 1 (spell 100)")
check(o1.attrs.type1 == nil and o1.attrs.type == nil, "no left-click action on the overlay")
check(o61.shown and o61.attrs.type2 == nil and o61.attrs.item2 == nil, "item entry 1 you have none of: type2 cleared")
check(o62.attrs.type2 == "macro" and o62.attrs.macro2 == "Foo", "macro entry 1: type2 macro, macro2 Foo")
check(o1.bindings["1"] and o1.bindings["1"][1] == o1.name and o1.bindings["1"][2] == "Keybind",
    "key 1 bound to the overlay with the button name Keybind")

check(Click(o1, "RightButton") == "cast spell=100", "right-click casts spell 100")
check(h.attrs.open == 0, "right-click leaves the flyout closed")
check(Click(o1, "LeftButton") == "cancelled", "left click cancels the secure action")
check(h.attrs.open == 1 and T.frames.GaarBarsForeverFlyout1.shown, "left click opens slot 1's flyout")
check(h.bindings["1"] ~= nil and h.bindings.ESCAPE ~= nil, "1-12 and Escape bound while open")
check(Click(o1, "RightButton") == "cast spell=100", "right-click with the flyout open casts spell 100")
check(h.attrs.open == 0 and not T.frames.GaarBarsForeverFlyout1.shown, "...and closes the flyout")
check(Click(o1, "LeftButton") == "cancelled" and h.attrs.open == 1, "left click opens again")
check(Click(o1, "LeftButton") == "cancelled" and h.attrs.open == 0, "left click again closes")
check(Click(o61, "RightButton") == "no action", "right-click on the item-with-none overlay does nothing")
check(Click(o62, "RightButton") == "cast macro=Foo", "right-click runs macro Foo")
check(Click(o1, "Keybind", true) == "not registered", "key down not delivered")
check(Click(o1, "Keybind", false) == "cancelled" and h.attrs.open == 1, "key release toggles open")
Click(o1, "LeftButton")

local line = FL.RightClickLine()
check(line == "right-click: entry 1 set on 2 of 3 shown overlays (1 spell, 1 macro)", "status line: " .. line)

-- Combat: the main bar pages to 2 (slot 13, flyout B) -----------------------------------------
T.SetCombat(true)
check(T.driver and T.driver.f == h, "page state driver registered on the header")
T.Page("2")
check(o1.attrs.curslot == 13 and o1.shown, "in combat, page 2: overlay follows slot 13")
check(o1.attrs.type2 == "spell" and o1.attrs.spell2 == 500, "in combat, page 2: spell2 = 500")
check(Click(o1, "RightButton") == "cast spell=500", "in combat, right-click casts spell 500")
check(Click(o1, "LeftButton") == "cancelled" and h.attrs.open == 13, "in combat, left click opens slot 13's flyout")
check(Click(o1, "RightButton") == "cast spell=500" and h.attrs.open == 0, "in combat, right-click closes and casts")
T.Page("3")
check(not o1.shown and o1.attrs.type2 == nil and o1.attrs.spell2 == nil, "page 3 (no flyout): hidden, type2 cleared")
T.Page("1")
check(o1.shown and o1.attrs.spell2 == 100, "back to page 1: spell2 = 100")
FL.Refresh()
T.SetCombat(false)
check(o1.attrs.spell2 == 100 and o1.shown, "after combat: rebuilt, spell2 = 100")

-- Entries change out of combat: entry 1 removed, the flyout's new entry 1 is used -------------
local A = G.GaarBarsForeverCharDB.flyouts2[1]
table.remove(A.entries, 1)
FL.Refresh()
check(o1.attrs.type2 == "spell" and o1.attrs.spell2 == 200, "entry 1 removed: right-click casts spell 200")
check(mA.body == "#showtooltip\n/cast Spell200", "macro body follows the new entry 1: " .. mA.body)
T.itemCount[900] = 3
FL.Refresh()
check(o61.attrs.type2 == "item" and o61.attrs.item2 == "item:900", "item now owned: type2 item, item2 item:900")

-- A druid in cat form (main bar page 7, slots 73-84): flyout E on slot 75 (ActionButton3 on page 7)
-- and flyout C on slot 61 (MultiBarBottomLeftButton1, also ActionButton1 on page 6).
local mE = T.AddMacro("GF E", "", true)
G.GaarBarsForeverCharDB.flyouts2[5] = { id = 5, name = "E", macro = "GF E", entries = { { t = "spell", id = 700 }, { t = "spell", id = 701 } } }
T.actions = { [75] = { "macro", mE }, [61] = { "macro", mC } }
for i = 1, 12 do G["ActionButton" .. i].action = 72 + i end
T.page = "7"
FL.Refresh()
local o3 = T.OverlayOf(G.ActionButton3)
local st = FL.StatusLine()
check(st:find("2 on bars (2 slots)", 1, true) and st:find("3 buttons with an overlay (2 shown now)", 1, true)
    and st:find("paging ok (page 7)", 1, true), "page 7 status: " .. st)
check(o3 and o3.shown and o3.attrs.curslot == 75, "page 7: ActionButton3 overlay live on slot 75")
check(o3.attrs.type2 == "spell" and o3.attrs.spell2 == 700, "page 7: type2/spell2 = 700")
check(not o1.shown and o1.attrs.type2 == nil, "page 7: ActionButton1's overlay (page 6 alias of slot 61) hidden")
check(not o62.shown and o62.attrs.type2 == nil, "flyout D off the bars: its overlay hidden, type2 cleared")
check(Click(o3, "RightButton") == "cast spell=700", "page 7: right-click casts spell 700")
check(Click(o3, "LeftButton") == "cancelled" and h.attrs.open == 75, "page 7: left click opens slot 75's flyout")
check(h.bindings["1"] and h.bindings["1"][1] == "GaarBarsForeverFlyout75Entry1", "page 7: key 1 casts entry 1")
check(Click(o3, "RightButton") == "cast spell=700" and h.attrs.open == 0, "page 7: right-click closes and casts")
check(FL.RightClickLine() == "right-click: entry 1 set on 2 of 2 shown overlays (1 spell, 1 item)",
    "page 7 right-click line: " .. FL.RightClickLine())
T.SetCombat(true)
T.Page("1")
check(not o3.shown and o3.attrs.type2 == nil, "combat, page 1: ActionButton3 overlay hidden, type2 cleared")
check(Click(o3, "RightButton") == "no action", "combat, page 1: nothing cast (overlay hidden anyway)")
T.Page("6")
check(o1.shown and o1.attrs.curslot == 61 and o1.attrs.type2 == "item" and o1.attrs.item2 == "item:900",
    "combat, page 6: ActionButton1 overlay shows slot 61 with its item")
T.Page("7")
check(o3.shown and o3.attrs.spell2 == 700 and not o1.shown, "combat, back to cat (page 7): spell2 = 700 again")
check(Click(o3, "RightButton") == "cast spell=700", "combat, page 7: right-click casts spell 700")
T.combat = false

T.on = false
FL.Refresh()
check(not o1.shown and o1.attrs.type2 == nil, "flyouts off: overlay hidden, type2 cleared")
check(h.attrs.first1type == nil and h.attrs.first1value == nil, "flyouts off: header first<slot> cleared")
check(not T.failed, "no error caught")
T.done()
