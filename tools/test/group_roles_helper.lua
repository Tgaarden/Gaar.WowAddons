-- Shared loader for the group_roles_*_test.lua files: GaarGroupForever main + Roles/Tank/Healer/Dps in a stub
-- client. Used with dofile("tools/test/group_roles_helper.lua")(state); does nothing when run on its own.
local args = { ... }
if not args[1] and not rawget(_G, "__GGF_HELPER") then
    -- run directly (the test loop does): nothing to check
end
return function(state)
    state = state or {}
    local noop = function() end
    local function widget()
        return setmetatable({}, { __index = function(t, k)
            local f = function() return t end; rawset(t, k, f); return f end })
    end
    local G = setmetatable({}, { __index = function(_, k) return _G[k] end })
    G._G = G
    local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end,
        __lt = function() error("compared a secret") end, __le = function() error("compared a secret") end })
    G.SECRET = SECRET
    local function IsSecret(v) return v == SECRET end
    local printed = {}
    G.GaarForever = {
        NewAddon = function() return { Print = function(_, m) printed[#printed + 1] = m end, title = "GaarGroupForever" } end,
        OnOff = function(v) return v and "on" or "off" end,
        IsSecret = IsSecret,
        Num = function(v) if IsSecret(v) or type(v) ~= "number" then return nil end return v end,
        Str = function(v) if IsSecret(v) or type(v) ~= "string" or v == "" then return nil end return v end,
        RenderMenu = noop,
        PlayerFullName = function() return state.fullName or "Me Self" end,
        NamesMatch = function(a, b) return type(a) == "string" and type(b) == "string" and a:lower() == b:lower() end,
        UnitByName = function(n) return state.unitByName and state.unitByName[n] end,
        StripRealm = function(n) return (n:gsub("%-[^%- ]+$", "")) end,
    }
    G.SlashCmdList = {}; G.UIParent = widget(); G.GameTooltip = widget()
    G.CreateFrame = function() return widget() end
    state.group = state.group == nil and true or state.group
    G.IsInGroup = function() return state.group end
    G.IsInRaid = function() return false end
    G.UnitIsGroupLeader = function(u) return state.leader and state.leader[u] or false end
    G.UnitGroupRolesAssigned = function(u) return state.roles and state.roles[u] or "NONE" end
    G.DoReadyCheck = noop; G.InitiateRolePoll = noop
    G.SendChatMessage = function(t, ch) state.chat = state.chat or {}; table.insert(state.chat, ch .. ":" .. t) end
    G.C_Timer = { After = noop }
    G.GetTime = function() return state.now or 100 end
    G.InCombatLockdown = function() return state.combat or false end
    local function chunk(path, name)
        local fh = assert(io.open(path)); local src = fh:read("*a"); fh:close()
        local f = assert(loadstring(src, "@" .. name)); setfenv(f, G); return f
    end
    local dir = "addons/GaarGroupForever/"
    chunk(dir .. "GaarGroupForever.lua", "main")("GaarGroupForever", {})
    local M = G.GaarGroupForeverAPI._M
    G.GaarGroupForeverDB = nil; G.GaarGroupForeverCharDB = nil
    M.BindSavedVariables()
    for _, f in ipairs({ "Roles.lua", "Tank.lua", "Healer.lua", "Dps.lua" }) do chunk(dir .. f, f)("GaarGroupForever", {}) end
    return G, M, M.Roles, printed
end
