--[[
  Spell book compatibility.

  Retail moved the spell book's skill-line half into C_SpellBook and changed the shape of the
  answer with it: GetSpellTabInfo returned four values, GetSpellBookSkillLineInfo returns one
  table. Three calls this addon used are gone from the retail and Forever clients entirely -
  GetNumSpellTabs, GetSpellTabInfo and IsPassiveSpell - and they are the only removals in the
  whole suite. Verified by diffing the strings of each client binary against Classic Era's.

  Everything the two clients disagree about is resolved here rather than at each call site, so
  the rest of the addon reads the same on both. Shared through the addon table, not a global:
  two files of one addon do not need to publish anything to reach each other.
]]

local _, ns = ...

-- The spell bank argument replaced the "spell" / "pet" strings. Enum is absent on Era, where
-- nothing reads this anyway; 0 is the player bank where it is present.
local PLAYER_BANK = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0

local C = _G.C_SpellBook

function ns.NumSpellTabs()
    if C and C.GetNumSpellBookSkillLines then return C.GetNumSpellBookSkillLines() or 0 end
    if GetNumSpellTabs then return GetNumSpellTabs() or 0 end
    return 0
end

-- Returns name, offset, numSpells - the three fields this addon actually uses, in the order
-- the old call gave them, so the call sites did not have to change shape twice.
function ns.SpellTabInfo(index)
    if C and C.GetSpellBookSkillLineInfo then
        local info = C.GetSpellBookSkillLineInfo(index)
        if not info then return nil end
        return info.name, info.itemIndexOffset, info.numSpellBookItems
    end
    if GetSpellTabInfo then
        local name, _, offset, numSpells = GetSpellTabInfo(index)
        return name, offset, numSpells
    end
end

function ns.IsPassive(slot)
    if C and C.IsSpellBookItemPassive then
        local ok, res = pcall(C.IsSpellBookItemPassive, slot, PLAYER_BANK)
        if ok then return res and true or false end
    end
    if IsPassiveSpell then return IsPassiveSpell(slot, "spell") and true or false end
    return false
end

-- The name, texture and info getters kept their old global names on both clients, but the
-- namespaced versions take the bank enum instead of "spell". Prefer the namespace where it is
-- there: the global is the one that will be retired next.
function ns.SpellName(slot)
    if C and C.GetSpellBookItemName then
        local name, rank = C.GetSpellBookItemName(slot, PLAYER_BANK)
        if name then return name, rank end
    end
    if GetSpellBookItemName then return GetSpellBookItemName(slot, "spell") end
end

function ns.SpellTexture(slot)
    if C and C.GetSpellBookItemTexture then
        local tex = C.GetSpellBookItemTexture(slot, PLAYER_BANK)
        if tex then return tex end
    end
    if GetSpellBookItemTexture then return GetSpellBookItemTexture(slot, "spell") end
    if GetSpellTexture then return GetSpellTexture(slot, "spell") end
end

-- Returns type, spellID. Retail answers with a table; Era with two values.
function ns.SpellInfo(slot)
    if C and C.GetSpellBookItemInfo then
        local info = C.GetSpellBookItemInfo(slot, PLAYER_BANK)
        if type(info) == "table" then return info.itemType, info.spellID end
        if info ~= nil then return info end
    end
    if GetSpellBookItemInfo then return GetSpellBookItemInfo(slot, "spell") end
end

function ns.PickupSpell(slot)
    if C and C.PickupSpellBookItem then
        if pcall(C.PickupSpellBookItem, slot, PLAYER_BANK) then return true end
    end
    if PickupSpellBookItem then PickupSpellBookItem(slot, "spell"); return true end
    if PickupSpell then PickupSpell(slot, "spell"); return true end
    return false
end
