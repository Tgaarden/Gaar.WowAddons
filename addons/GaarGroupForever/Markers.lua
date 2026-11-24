--[[
  GaarGroupForever - Markers.lua: a row of the 8 raid target markers.

  Click a marker to put it on your target (SetRaidTarget("target", i)); right-click a marker to
  clear the mark of your target; the X button clears every mark it can reach. In a party anyone
  may mark, so there is no rank check: if the game refuses, it simply does nothing. The row hangs
  under the bar (a panel of the dock in Overview.lua), is switched on with the Markers option and
  can be collapsed with the Marks button.

  SetRaidTarget is not a protected function; calls run in pcall.
]]

local _G = _G
local API = _G.GaarGroupForeverAPI
local M = API and API._M
if not M then return end

M.Defaults.markers = true
M.Defaults.markersOpen = true

local K = {}
M.Markers = K

K.TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
K.NAMES = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }

-- Texture coordinates of marker i (1-8) in the 4x4 icon sheet: left, right, top, bottom.
function K.Coords(i)
    local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
    return col * 0.25, col * 0.25 + 0.25, row * 0.25, row * 0.25 + 0.25
end

-- Left click: marker i; right click: clear. Returns true when SetRaidTarget was called.
function K.Mark(i, button)
    if type(_G.SetRaidTarget) ~= "function" then M.Print("This client cannot set raid markers."); return false end
    if not M.Q(_G.UnitExists, "target") then M.Print("Select a target first."); return false end
    local idx = (button == "RightButton") and 0 or i
    if idx < 0 or idx > 8 then return false end
    return M.Safe("SetRaidTarget", _G.SetRaidTarget, "target", idx)
end

-- Units whose mark Clear-all looks at: the group, their pets and targets, and yours.
function K.ClearUnits()
    local u = { "target", "focus", "targettarget", "player", "pet" }
    for i = 1, 4 do
        u[#u + 1] = "party" .. i
        u[#u + 1] = "partypet" .. i
        u[#u + 1] = "party" .. i .. "target"
    end
    return u
end

-- Clears the mark on every unit above that has one. Returns how many were cleared.
function K.ClearAll()
    if type(_G.SetRaidTarget) ~= "function" then return 0 end
    local n = 0
    for _, unit in ipairs(K.ClearUnits()) do
        local idx = M.Q(_G.GetRaidTargetIndex, unit)
        if type(idx) == "number" and idx > 0 then
            if M.Safe("SetRaidTarget", _G.SetRaidTarget, unit, 0) then n = n + 1 end
        end
    end
    return n
end

function K.Enabled() return M.db and M.db.markers ~= false end
function K.Open() return K.Enabled() and M.db.markersOpen ~= false end

local ROW, BTN = 25, 22
local frame
local function EnsureFrame()
    if frame or not M.bar then return frame end
    frame = M.NewInset("GaarGroupForeverMarkers", M.bar)
    local function btn(x, texture, coords, onclick, tip)
        local b = M.IconButton(nil, frame, BTN, texture, coords)
        b:SetPoint("LEFT", frame, "LEFT", 6 + x * ROW, 0)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", function(_, button) M.Safe("mark", onclick, button) end)
        M.Tip(b, function() return tip end)
        return b
    end
    for i = 1, 8 do
        btn(i - 1, K.TEXTURE, { K.Coords(i) }, function(button) K.Mark(i, button) end,
            { K.NAMES[i], "Left-click: mark your target " .. K.NAMES[i] .. ".", "Right-click: clear your target's mark." })
    end
    local x = btn(8, nil, nil, function()
        local n = K.ClearAll()
        M.Print(n > 0 and ("cleared " .. n .. " mark(s).") or "no marks found on the group's units or targets.")
    end, { "Clear all", "Clears the marks on your target and focus, and on the group, their pets and their targets." })
    local fs = x:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("CENTER")
    fs:SetText("|cffff4040X|r")
    return frame
end

M.Dock.AddPanel({ getFrame = EnsureFrame, height = function() return K.Open() and (ROW + 6) or nil end })

function K.SetEnabled(v) M.db.markers = v and true or false; M.Refresh() end
function K.SetOpen(v) M.db.markersOpen = v and true or false; M.Refresh() end

M.Dock.AddButton({ key = "Marks", text = "Marks", opt = "markers",
    click = function() K.SetOpen(not K.Open()) end,
    active = function() return K.Open() end,
    tip = { "Raid markers", "Shows or hides the row of raid target markers." } })

M.MenuParts[#M.MenuParts + 1] = function()
    return {
        { text = "Raid marker row", checkbox = true,
          checked = function() return M.db.markers ~= false end, func = function() K.SetEnabled(M.db.markers == false) end },
        { text = "Marker row expanded", checkbox = true,
          checked = function() return M.db.markersOpen ~= false end, func = function() K.SetOpen(M.db.markersOpen == false) end },
    }
end

M.Slash.marks = function(arg)
    if arg == "on" or arg == "off" then
        K.SetEnabled(arg == "on"); M.Print("raid marker row " .. arg .. ".")
    elseif arg == "collapse" or arg == "expand" then
        K.SetOpen(arg == "expand"); M.Print("marker row " .. (arg == "expand" and "expanded." or "collapsed."))
    elseif arg == "clear" then
        M.Print("cleared " .. K.ClearAll() .. " mark(s).")
    else
        M.Print("/ggf marks on | off | collapse | expand | clear")
    end
end

M.HelpParts[#M.HelpParts + 1] = function()
    return { "/ggf marks on|off|collapse|expand|clear - the raid marker row (now "
        .. (M.db and M.db.markers ~= false and (M.db.markersOpen ~= false and "shown" or "collapsed") or "off") .. ")" }
end
