-- LuaJIT stub test: GaarBagsForever 1.11 (popup shared since 1.12) - locked items kept off outgoing mail, and the
-- attachment -> bag slot matching behind the cyan mail ring.
-- Run: luajit tools/test/bags_mail_lock_test.lua   (from the repo root)
local path = "addons/GaarBagsForever/GaarBagsForever.lua"
local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__T = { Mail = Mail, Bind = function() BindSavedVariables(); BindCharacterVariables() end }\n"

local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local G = setmetatable({}, { __index = function(t, k)
    if _G[k] ~= nil then return _G[k] end
    return nil end })
G._G = G
G.GaarForever = {
    NewAddon = function() return { Print = function(_, msg) G.__printed[#G.__printed + 1] = msg end } end,
    OnOff = function(v) return v and "on" or "off" end,
    InCombat = function() return false end,
    Plain = function(v) return v end,
    Str = function(v) return type(v) == "string" and v or nil end,
    API = function() return nil end,   -- no C_Timer: the queued scans run at once
    Migrate = noop, Call = noop, RenderMenu = noop,
}
G.__printed = {}
G.CreateFrame = widget
G.SlashCmdList = {}
G.UIParent = widget()
G.GameTooltip = widget()
G.hooksecurefunc = noop
G.ATTACHMENTS_MAX_SEND = 12
local clock = 100
G.GetTime = function() return clock end   -- the shared block message dedupes within 1.5 s

-- The Send Mail attachments: index -> { id, count }
local attached = {}
local cursor = nil
G.GetSendMailItemLink = function(i)
    local a = attached[i]
    return a and ("|cffffffff|Hitem:" .. a.id .. "::::::::|h[Item " .. a.id .. "]|h|r") or nil
end
G.GetSendMailItem = function(i)
    local a = attached[i]
    if not a then return nil end
    return "Item " .. a.id, a.id, 134400, a.count, 1, true
end
local clicks = {}
G.ClickSendMailItemButton = function(i, clear)
    clicks[#clicks + 1] = { i = i, clear = clear }
    if clear then attached[i] = nil end
end
G.GetCursorInfo = function() if cursor then return "item", cursor end end
G.ClearCursor = function() cursor = nil end
local popups = {}
G.StaticPopupDialogs = {}
G.StaticPopup_Show = function(which, text) popups[#popups + 1] = { which = which, text = text } end

local f = loadstring(src, "@GBF"); setfenv(f, G)
local ok, err = pcall(f, "GaarBagsForever", {})
assert(ok, "load: " .. tostring(err))
local T = G.__T
local Mail = T.Mail

local fails = 0
local function check(name, cond)
    print(string.format("%-60s %s", name, cond and "ok" or "FAIL"))
    if not cond then fails = fails + 1 end
end
local function keys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, ",")
end

-- ---- LockedAttachments ----
local locked = { [100] = true }
local function isLocked(id) return locked[id] == true end
local hits = Mail.LockedAttachments({ [1] = { id = 5 }, [3] = { id = 100 }, [12] = { id = 100 } }, 12, isLocked)
check("locked attachments: indexes 3 and 12, holes skipped", #hits == 2 and hits[1] == 3 and hits[2] == 12)
check("locked attachments: none locked", #Mail.LockedAttachments({ { id = 5 }, { id = 6 } }, 12, isLocked) == 0)

-- ---- MatchAttachedSlots ----
local function slot(bag, s, id, count, lockedFlag)
    return { bag = bag, slot = s, id = id, count = count, locked = lockedFlag ~= false }
end
check("one attachment, one locked slot",
    keys(Mail.MatchAttachedSlots({ { id = 7, count = 20 } }, { slot(0, 1, 7, 20) })) == "0:1")
check("unlocked slots never glow",
    keys(Mail.MatchAttachedSlots({ { id = 7, count = 20 } }, { slot(0, 1, 7, 20, false) })) == "")
check("2 locked stacks, 1 attached: only one glows, the same size wins",
    keys(Mail.MatchAttachedSlots({ { id = 7, count = 5 } }, { slot(0, 1, 7, 20), slot(1, 4, 7, 5) })) == "1:4")
check("2 attached of the same item: both slots",
    keys(Mail.MatchAttachedSlots({ { id = 7, count = 20 }, { id = 7, count = 5 } },
        { slot(0, 1, 7, 20), slot(1, 4, 7, 5) })) == "0:1,1:4")
check("cursor slot known: it is left out",
    keys(Mail.MatchAttachedSlots({ { id = 7, count = 20 } }, { slot(0, 1, 7, 20), slot(0, 2, 7, 20) },
        { id = 7, bag = 0, slot = 1 })) == "0:2")
check("cursor slot unknown, sizes differ: one held back in pass 2",
    keys(Mail.MatchAttachedSlots({ { id = 7, count = 3 } }, { slot(0, 1, 7, 20) }, { id = 7 })) == "")
check("cursor holds another item: nothing held back",
    keys(Mail.MatchAttachedSlots({ { id = 7, count = 3 } }, { slot(0, 1, 7, 20) }, { id = 8 })) == "0:1")
check("different item ids never match",
    keys(Mail.MatchAttachedSlots({ { id = 7, count = 1 } }, { slot(0, 1, 8, 1) })) == "")

-- ---- the scan, end to end with the stubs ----
G.GaarBagsForeverCharDB = { lockedItems = { [100] = "|cffffffff|Hitem:100::::::::|h[Hearthstone]|h|r" } }
G.GaarBagsForeverDB = {}
T.Bind()
check("mailGlow defaults on", G.GaarBagsForeverDB.mailGlow == true)

attached = { [2] = { id = 100, count = 1 }, [4] = { id = 5, count = 3 } }
Mail.OnEvent("MAIL_SHOW")
check("locked attachment taken off with clearItem", attached[2] == nil and clicks[1] and clicks[1].i == 2 and clicks[1].clear == true)
check("other attachment left alone", attached[4] ~= nil and #clicks == 1)
check("one popup, with the item link", #popups == 1 and popups[1].which == "GAARBAGSFOREVER_LOCKED"
    and popups[1].text:find("[Item 100]", 1, true) ~= nil)
check("shared popup defined with OK only", G.StaticPopupDialogs.GAARBAGSFOREVER_LOCKED ~= nil
    and G.StaticPopupDialogs.GAARBAGSFOREVER_LOCKED.button2 == nil)
check("popup text names the action", popups[1].text:find("cannot be mailed", 1, true) ~= nil)
local said = false
for _, m in ipairs(G.__printed) do if m:find("cannot be mailed", 1, true) then said = true end end
check("chat line printed", said)

-- An update with nothing locked: no new click, no new popup.
Mail.OnEvent("MAIL_SEND_INFO_UPDATE")
check("no loop: nothing more clicked or shown", #clicks == 1 and #popups == 1)

-- A client whose clearItem does nothing: the fallback picks it up and ClearCursor puts it back,
-- and after 3 scans it gives up with one line.
G.ClickSendMailItemButton = function(i, clear)
    clicks[#clicks + 1] = { i = i, clear = clear }
    if not clear and attached[i] then cursor = attached[i].id end
end
clicks, popups = {}, {}
clock = clock + 5
attached = { [1] = { id = 100, count = 1 } }
Mail.OnEvent("MAIL_SEND_INFO_UPDATE")
check("fallback: second click without clearItem", #clicks == 2 and clicks[2].clear == nil)
check("fallback: the item never stays on the cursor", cursor == nil)
for _ = 1, 5 do Mail.OnEvent("MAIL_SEND_INFO_UPDATE") end
check("gives up after 3 tries, one popup only", #clicks == 6 and #popups == 1)

-- /gbf mailglow toggles the saved setting.
Mail.SetGlow(false)
check("/gbf mailglow off saves false", G.GaarBagsForeverDB.mailGlow == false)
Mail.SetGlow(nil)
check("/gbf mailglow toggles back on", G.GaarBagsForeverDB.mailGlow == true)
check("status line mentions mail glow", Mail.Status():find("mail glow on", 1, true) ~= nil)

print(fails == 0 and "ALL OK" or (fails .. " FAILED")); os.exit(fails == 0 and 0 or 1)
