-- GaarBagsForever: scale of the bags window (since 1.16.0).
--
-- Pure helpers for the scale setting; the main file (GaarBagsForever.lua) holds the saved value
-- (GaarBagsForeverDB.bagScale, 0.5 - 2.0, default 1) and does the combat check and the position
-- bookkeeping around ns.BagScale.Apply. Own file because the main file is close to Lua's limit of
-- 200 locals. Only the Combined Backpack frame the addon already positions is scaled (the bank
-- window is not handled by this addon). Only SetScale on that frame, never in combat (the main file
-- defers to PLAYER_REGEN_ENABLED); nothing is replaced and no attribute is set.
local ADDON_NAME, ns = ...
if type(ns) ~= "table" then ns = {} end

local S = {}
ns.BagScale = S

S.MIN, S.MAX = 0.5, 2.0
S.scaled = false      -- we have set a scale other than the one Blizzard gave the frame
S.applying = false    -- true inside our own SetScale, so the SetScale hook ignores it
S.orig = nil          -- the scale the frame had before our first change

local function Near(a, b) return math.abs((a or 0) - (b or 0)) < 0.001 end

-- A percentage (50-200, "120" or "120%") -> scale, or nil when it is not a number in range.
function S.FromPercent(p)
    p = tonumber(type(p) == "string" and p:match("^%s*(%d+)%%?%s*$") or p)
    if not p or p < S.MIN * 100 or p > S.MAX * 100 then return nil end
    return math.floor(p + 0.5) / 100
end

function S.ToPercent(scale) return math.floor((tonumber(scale) or 1) * 100 + 0.5) end

-- A saved value that is not a number in range falls back to 100%.
function S.Sanitize(v)
    if type(v) ~= "number" or v ~= v or v < S.MIN or v > S.MAX then return 1 end
    return v
end

-- Does the frame still have to be changed to reach `want`?
function S.Needs(frame, want)
    if not frame or type(frame.GetScale) ~= "function" then return false end
    if Near(want, 1) then return S.scaled end
    return not Near(frame:GetScale(), want)
end

-- Sets the scale (the caller has checked combat). 100% gives back the scale the frame had.
function S.Apply(frame, want)
    if not frame or type(frame.SetScale) ~= "function" then return false end
    S.applying = true
    local ok = pcall(function()
        if Near(want, 1) then
            if S.scaled then frame:SetScale(S.orig or 1) end
            S.scaled = false
        else
            if not S.scaled then S.orig = frame:GetScale() end
            frame:SetScale(want)
            S.scaled = true
        end
    end)
    S.applying = false
    return ok
end
