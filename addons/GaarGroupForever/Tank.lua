--[[
  GaarGroupForever - Tank.lua: the Tank role module (active only while your mode is Tank).

    Pull marker     A "Mark" button under the bar (and /ggf tank mark [x], so it can sit in a macro or on a key):
                    skull on your target; if a skull is already out on another mob, X instead. Shift-click or
                    /ggf tank mark x forces X. Optional (default off): "Pulling <mob>" to PARTY on that click.
    Lost aggro      A hostile mob in combat that targets another party member (not you): a short red warning
                    "<mob> is on <member>", throttled. Reads UnitIsUnit(mob.."target", unit); a secret answer
                    is skipped.
    Healer mana     Out of combat only: the healer's mana % in a line above the bar; below the threshold
                    (default 40 %) it turns red: "Healer 30% mana - wait".
    Loose mobs      In combat: the hostile mobs that are not on you (nameplates, target, focus, party targets).

  No protected function is used: SetRaidTarget and SendChatMessage are plain calls on your own click.
]]

local _, NS = ...
local R = type(NS) == "table" and NS.R or nil
if not R then return end
local M = NS.M
local _G = _G
local BF = _G.GaarForever
local Num = BF.Num

local T = { name = "Tank" }
M.Tank = T

R.AddOption("tank", "tankMark", "Pull marker button", true, "mark")
R.AddOption("tank", "tankAnnounce", "Pull marker: say \"Pulling ...\" to party on click", false, "announce")
R.AddOption("tank", "tankLostAggro", "Lost-aggro warning", true, "aggro")
R.AddOption("tank", "tankMana", "Healer mana before the pull", true, "mana")
R.AddOption("tank", "tankManaPct", "Healer mana warning below", 40, "manapct",
    { kind = "number", values = { 20, 30, 40, 50, 60, 70 } })
R.AddOption("tank", "tankLoose", "Loose mobs list", true, "loose")

local SKULL, CROSS = 8, 7
local MAX_NAMES = 3

-- ---------------------------------------------------------------------------
-- Pure logic
-- ---------------------------------------------------------------------------

-- Which marker the click sets. targetIdx: the marker the target already has (0/nil = none). Returns the
-- index to set, or nil to leave the target as it is. force: "x" asks for the cross.
function T.NextMarker(targetIdx, skullTaken, force)
    targetIdx = targetIdx or 0
    if targetIdx == SKULL or (targetIdx == CROSS and force == "x") then return nil end
    if force == "x" then return CROSS end
    if targetIdx == CROSS then return skullTaken and nil or SKULL end
    if skullTaken then return CROSS end
    return SKULL
end

-- Mobs that are in combat, not on you, and on a party member: { name, victim } (victim = unit token).
function T.LostAggro(items)
    local out = {}
    for _, it in ipairs(items or {}) do
        if it.onMe == false and it.victim then out[#out + 1] = it end
    end
    return out
end

-- Mobs known not to be on you (onMe == false); unknown (nil) ones are skipped.
function T.Loose(items)
    local out = {}
    for _, it in ipairs(items or {}) do
        if it.onMe == false then out[#out + 1] = it end
    end
    return out
end

-- "low" below the threshold, "ok" otherwise, nil when the mana is unknown.
function T.ManaState(pct, threshold)
    pct = Num(pct)
    if not pct then return nil end
    return pct < (Num(threshold) or 40) and "low" or "ok"
end

function T.ManaText(name, pct, threshold)
    local state = T.ManaState(pct, threshold)
    if not state then return nil end
    local p = math.floor(pct + 0.5)
    if state == "low" then return (name or "Healer") .. " " .. p .. "% mana - wait", "low" end
    return (name or "Healer") .. " mana " .. p .. "%", "ok"
end

function T.LooseText(list)
    if #list == 0 then return nil end
    local names, n = {}, 0
    for _, it in ipairs(list) do
        n = n + 1
        if #names < MAX_NAMES then names[#names + 1] = it.name or "?" end
    end
    local s = "Loose (" .. n .. "): " .. table.concat(names, ", ")
    if n > #names then s = s .. ", ..." end
    return s
end

-- ---------------------------------------------------------------------------
-- Pull marker
-- ---------------------------------------------------------------------------

-- Is any living unit around us carrying marker idx?
function T.MarkerTaken(idx, exceptUnit)
    for _, u in ipairs(R.ScanUnits()) do
        if u ~= exceptUnit and R.Exists(u) and R.Q(_G.GetRaidTargetIndex, u) == idx
            and R.B(_G.UnitIsDeadOrGhost, u) ~= true then
            return true
        end
    end
    return false
end

-- force: "x" for the cross. Returns the marker set, or nil + a reason.
function T.MarkTarget(force)
    if type(_G.SetRaidTarget) ~= "function" then return nil, "This client cannot set raid markers." end
    if not R.Exists("target") then return nil, "Target a mob first." end
    if R.B(_G.UnitCanAttack, "player", "target") ~= true then return nil, "Target a hostile mob." end
    local mine = Num(R.Q(_G.GetRaidTargetIndex, "target"))
    local idx = T.NextMarker(mine, T.MarkerTaken(SKULL, "target"), force)
    if not idx then return nil, "Already marked." end
    local ok = pcall(_G.SetRaidTarget, "target", idx)
    if not ok then return nil, "The game refused the marker (leader or assistant in a group)." end
    if R.Opt("tankAnnounce") and idx == SKULL then
        local n = R.Name("target")
        if n then R.Say("Pulling " .. n) end
    end
    return idx
end

function T.ClickMark(force)
    local idx, why = T.MarkTarget(force)
    if not idx then M.Print(why) end
end

-- ---------------------------------------------------------------------------
-- Row, tick
-- ---------------------------------------------------------------------------

function T.build(row)
    local b = R.Button(row, "GaarGroupForeverTankMark", "Mark", 46, function()
        local force
        if type(_G.IsShiftKeyDown) == "function" and _G.IsShiftKeyDown() then force = "x" end
        T.ClickMark(force)
    end, function()
        return { "Pull marker", "Click: skull on your target (X if a skull is already out).",
            "Shift-click: X.", "Macro: /ggf tank mark [x]",
            R.Opt("tankAnnounce") and "Announces the pull to party." or "Does not post to chat (option)." }
    end)
    b:SetPoint("LEFT", row, "LEFT", 5, 0)
    T.markButton = b
    return 56, 26
end

function T.refresh()
    if T.markButton then T.markButton:SetShown(R.Opt("tankMark")) end
end

function T.tick(now)
    local inCombat = R.InCombat() or R.B(_G.UnitAffectingCombat, "player") == true
    -- Healer mana: out of combat only.
    if R.Opt("tankMana") and not inCombat then
        local u = R.UnitByRole("HEALER")
        local text, state
        if u then text, state = T.ManaText(R.Name(u), R.ManaPct(u), R.Opt("tankManaPct")) end
        R.SetStatus("tankMana", text, state == "low" and R.RED or R.GREEN)
    else
        R.SetStatus("tankMana", nil)
    end
    if not inCombat then R.SetStatus("tankLoose", nil); return end
    if not R.Opt("tankLostAggro") and not R.Opt("tankLoose") then R.SetStatus("tankLoose", nil); return end
    local items = R.Scan(now)
    if R.Opt("tankLostAggro") then
        for _, it in ipairs(T.LostAggro(items)) do
            local victim = R.Name(it.victim) or "a party member"
            local mob = it.name or "A mob"
            R.Alert("lost:" .. mob .. ":" .. victim, mob .. " is on " .. victim,
                { gap = 6, group = "lostAggro", groupGap = 2, ttl = 4, color = R.RED })
        end
    end
    R.SetStatus("tankLoose", R.Opt("tankLoose") and T.LooseText(T.Loose(items)) or nil, R.YELLOW)
end

function T.deactivate() end

function T.demo()
    R.Alert("demo:lost", "Wolf is on Mira", { gap = 0, ttl = 6, color = R.RED })
    R.Alert("demo:mana", "Healer 30% mana - wait", { gap = 0, ttl = 6, color = R.RED })
    R.Alert("demo:loose", "Loose (2): Wolf, Boar", { gap = 0, ttl = 6, color = R.YELLOW })
end

function T.help()
    return { "/ggf tank mark [x] - skull on the target (X when a skull is out; x forces X)",
        "/ggf tank test - show sample warnings" }
end

function T.slash(sub, rest)
    if sub == "mark" then
        T.ClickMark((rest or ""):lower() == "x" and "x" or nil)
        return true
    end
end

R.Register("tank", T)
