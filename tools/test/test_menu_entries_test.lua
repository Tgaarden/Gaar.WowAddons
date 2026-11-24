-- Convention test: every addon with a test mode has a "Test mode" (toggle) or "Test: ..." (one-shot) entry in its
-- MenuEntries, kept just before the Reset entry (or last), and accepts `<slash> test`.
-- Static (reads the sources), so it also covers addons whose menu needs the client to build.
-- Run: luajit tools/test/test_menu_entries_test.lua   (from the repo root)
local fails = 0
local function fail(m) fails = fails + 1; print("FAIL " .. m) end
local function read(p) local fh = assert(io.open(p)); local s = fh:read("*a"); fh:close(); return s end

-- folder, file that holds the menu entry, the test entry, the slash handler
local ADDONS = {
    { "GaarBuffsForever", "GaarBuffsForever.lua", 'text = "Test mode", checkbox', 'cmd == "test"' },
    { "GaarCastbarsForever", "GaarCastbarsForever.lua", 'text = "Test mode", checkbox', 'cmd == "test"' },
    { "GaarFramesForever", "GaarFramesForever.lua", 'text = "Test mode", checkbox', 'cmd == "test"' },
    { "GaarGroupForever", "GaarGroupForever.lua", 'text = "Test mode", checkbox', 'cmd == "test"' },
    { "GaarFishingForever", "GaarFishingForever.lua", 'text = "Test mode", checkbox', 'cmd == "test"' },
    { "GaarXPForever", "GaarXPForever.lua", 'text = "Test mode", checkbox', 'a == "test"' },
    { "GaarChatForever", "GaarChatForever.lua", 'text = "Test: print sample chat lines"', 'cmd == "test"' },
    { "GaarLootForever", "GaarLootForever.lua", 'A:Button("Test: show a preview"', 'cmd = "test"' },
}
for _, a in ipairs(ADDONS) do
    local dir, file, entryPat, slashPat = a[1], a[2], a[3], a[4]
    local src = read("addons/" .. dir .. "/" .. file)
    local at = src:find(entryPat, 1, true)
    if not at then fail(dir .. ": no test entry (" .. entryPat .. ")") end
    if not src:find(slashPat, 1, true) then fail(dir .. ": no `test` slash (" .. slashPat .. ")") end
    if at then
        -- what follows the test entry, up to the end of the list, may only be Reset entries
        local rest = src:sub(at + #entryPat)
        local stop = #rest
        for _, m in ipairs({ "\n    return list", "\n    }\nend", "\nA:Button" }) do
            local i = rest:find(m, 1, true)
            if i and i < stop then stop = i end
        end
        for text in rest:sub(1, stop):gmatch('text = "([^"]+)"') do
            if not text:find("^Reset") then fail(dir .. ": entry '" .. text .. "' comes after the test entry") end
        end
    end
end
if fails == 0 then print("test_menu_entries_test: ok") else os.exit(1) end
