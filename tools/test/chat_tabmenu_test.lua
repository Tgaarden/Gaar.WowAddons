-- LuaJIT stub test: GaarChatForever adds a "GaarChat" submenu to the chat tab menu (MENU_FCF_TAB).
-- Run: luajit tools/test/chat_tabmenu_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarChatForever/GaarChatForever.lua")); local src = fh:read("*a"); fh:close()
local noop = function() end
local fails = 0
local function eq(n, got, want) if got ~= want then fails = fails + 1; print("FAIL " .. n .. ": got " .. tostring(got) .. " want " .. tostring(want)) end end
local function widget()
    return setmetatable({}, { __index = function(t, k) local f = function() return t end; rawset(t, k, f); return f end })
end
local rendered, renderedRoot
local function load(menu)
    local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
    G._G = G
    G.GaarForever = setmetatable({
        NewAddon = function() return setmetatable({ title = "GaarChatForever" }, { __index = function() return noop end }) end,
        RenderMenu = function(root, entries) rendered = entries; renderedRoot = root end,
    }, { __index = function() return noop end })
    G.CreateFrame = function() return widget() end
    G.SlashCmdList = {}; G.hooksecurefunc = noop; G.Menu = menu
    local f = assert(loadstring(src, "chat")); setfenv(f, G); f("GaarChatForever", {})
    return G
end
-- Menu is nil: loads without error.
load(nil)
load({})
-- Menu.ModifyMenu present: callback registered for MENU_FCF_TAB.
local tag, cb
load({ ModifyMenu = function(t, fn) tag = t; cb = fn end })
eq("tag", tag, "MENU_FCF_TAB")
eq("callback", type(cb), "function")
local log = {}
local sub = { tag = "sub" }
local root = { CreateDivider = function() log[#log + 1] = "divider" end,
    CreateButton = function(_, text) log[#log + 1] = "button:" .. text; return sub end }
cb({}, root, {})
eq("divider first", log[1], "divider")
eq("submenu", log[2], "button:GaarChat")
eq("shared builder used on submenu", renderedRoot, sub)
eq("entries passed", type(rendered), "table")
-- A broken root never errors out.
cb({}, { CreateDivider = function() error("boom") end }, {})
cb({}, nil, nil)
-- ModifyMenu raising is swallowed.
load({ ModifyMenu = function() error("no such tag") end })
if fails == 0 then print("chat_tabmenu_test: ok") else os.exit(1) end
