-- LuaJIT stub test: GaarGroupForever role/marker icon buttons keep their icon visible in every state.
-- Run: luajit tools/test/group_icons_test.lua   (from the repo root)
local fh = assert(io.open("addons/GaarGroupForever/GaarGroupForever.lua")); local src = fh:read("*a"); fh:close()
src = src .. "\n_G.__M = M\n"
local noop = function() end
local function widget()
    return setmetatable({}, { __index = function(t, k)
        local f = function() return t end; rawset(t, k, f); return f end })
end
local function tex(layer)
    local t = { layer = layer, shown = true, alpha = 1 }
    function t:SetTexture(f) self.file = f end
    function t:SetTexCoord(a, b, c, d) self.coords = { a, b, c, d } end
    function t:Show() self.shown = true end
    function t:Hide() self.shown = false end
    function t:SetAlpha(a) self.alpha = a end
    function t:SetDesaturated(v) self.desat = v end
    function t:SetBlendMode(m) self.blend = m end
    function t:SetColorTexture() end
    return setmetatable(t, { __index = function(_, k) return function() return _ end end })
end
local function button()
    local b = { textures = {}, checked = false }
    function b:CreateTexture(_, layer) local t = tex(layer); self.textures[#self.textures + 1] = t; return t end
    function b:SetChecked(v) self.checked = v end
    function b:SetEnabled() end
    function b:SetAlpha(a) self.alpha = a end
    function b:SetNormalTexture(f) self.normal = tex("ARTWORK"); self.normal.file = f end
    function b:GetNormalTexture() return self.normal end
    function b:SetScript(k, f) self[k] = f end
    return setmetatable(b, { __index = function(_, k) return function() return _ end end })
end
local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
G._G = G
G.GaarForever = { NewAddon = function() return { Print = noop, title = "GaarGroupForever" } end,
    OnOff = function(v) return v and "on" or "off" end, IsSecret = function() return false end,
    Num = function(v) return type(v) == "number" and v or nil end, RenderMenu = noop }
G.SlashCmdList = {}; G.UIParent = widget(); G.GameTooltip = widget()
G.CreateFrame = function() return button() end
local state = { role = "NONE" }
G.IsInGroup = function() return true end; G.IsInRaid = function() return false end
G.UnitIsGroupLeader = function() return true end
G.UnitGroupRolesAssigned = function() return state.role end
G.UnitSetRole = function(_, r) state.role = r end
G.C_Timer = { After = noop }
local chunk = assert(loadstring(src, "group")); setfenv(chunk, G); chunk("GaarGroupForever")
local M = G.__M
G.GaarGroupForeverDB = nil; G.GaarGroupForeverCharDB = nil
M.BindSavedVariables()

local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1; print("FAIL " .. msg .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end end

local function checkIcon(b, file, coords, label)
    local icon = b.icon
    eq(icon.file, file, label .. " texture")
    eq(icon.shown, true, label .. " shown")
    eq(icon.alpha, 1, label .. " alpha")
    eq(icon.layer, "ARTWORK", label .. " layer")
    for i = 1, 4 do eq(icon.coords[i], coords[i], label .. " coord " .. i) end
    -- nothing drawn over the icon may be opaque: the glow must be additive
    if b.glow then eq(b.glow.blend, "ADD", label .. " glow additive") end
end

local b = M.IconButton("X", G.UIParent, 36, M.ROLE_ICONS, M.Modes[1].coords, true)
checkIcon(b, M.ROLE_ICONS, M.Modes[1].coords, "fresh")
M.SetIconChecked(b, true); checkIcon(b, M.ROLE_ICONS, M.Modes[1].coords, "checked")
eq(b.glow.shown, true, "glow on"); eq(b.checked, true, "checked")
M.SetIconChecked(b, false); eq(b.glow.shown, false, "glow off")
M.SetEnabled(b, false); eq(b.icon.shown, true, "disabled icon shown"); M.SetEnabled(b, true)

-- the real panel: pick each mode, then a game roles-assigned refresh
M.preview = true
M.Refresh()
local function checkAll(label)
    for _, m in ipairs(M.Modes) do checkIcon(M.buttons.modes[m.key], M.ROLE_ICONS, m.coords, label .. " " .. m.key) end
end
checkAll("panel")
for _, m in ipairs(M.Modes) do
    M.buttons.modes[m.key].OnClick()
    checkAll("after " .. m.key)
    eq(M.buttons.modes[m.key].glow.shown, true, m.key .. " active glow")
    state.role = m.role; M.Refresh(); checkAll("roles-assigned " .. m.key)
end
state.role = "NONE"; M.preview = false; M.Refresh(); checkAll("after leave")

-- marker buttons are IconButtons too: same icon rules
local mb = M.IconButton(nil, G.UIParent, 22, "Interface\\TargetingFrame\\UI-RaidTargetingIcons", { 0, .25, 0, .25 })
checkIcon(mb, "Interface\\TargetingFrame\\UI-RaidTargetingIcons", { 0, .25, 0, .25 }, "marker")
eq(mb.glow.shown, false, "marker not glowing")

if fails == 0 then print("group_icons_test OK") else os.exit(1) end
