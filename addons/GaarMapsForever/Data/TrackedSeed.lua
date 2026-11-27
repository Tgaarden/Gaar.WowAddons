-- GaarMapsForever - built-in seed for the tracked NPC pins (TrackedPins.lua). MIT, our own data only.
--
-- Read-only. Merged with the places each player learns (GaarMapsForeverNPCDB) when the map is drawn; a
-- learned place always wins over a seed row for the same NPC or spot, and nothing here is ever saved.
--
-- Where the rows come from: Thomas visits the NPCs in game (the capitals - Stormwind, Ironforge,
-- Darnassus, Orgrimmar, Undercity, Thunder Bluff - and WoW Forever's own zones), types
-- /gmf pins export (or /gmf pins export <uiMapID> / here), copies the window's text and hands it over;
-- it is pasted below as is. Never enter coordinates by hand, from memory or from another addon's or
-- website's database (pfQuest, Questie, CMaNGOS and the like are GPL or all rights reserved).
--
-- Format (exactly what the export writes):
--   [uiMapID] = { -- zone name
--       { id = <npc id>, x = <0-1>, y = <0-1>, name = "<npc name>", c = "<categories>" },
--       { x = <0-1>, y = <0-1>, c = "mailbox" },     -- an object: no id, no name
--   },
-- Categories (space separated): mailbox flightmaster innkeeper banker auctioneer classtrainer proftrainer
-- stablemaster battlemaster repair food reagent poison ammo vendor.
local _, ns = ...
ns = type(ns) == "table" and ns or {}

ns.trackedPinsBundled = {
}
