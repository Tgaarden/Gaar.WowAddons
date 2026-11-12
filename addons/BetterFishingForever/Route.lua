--[[
  BetterFishingForever - the Fishing 1-300 route (1.2), data only.

  Read by RouteGuide.lua through the addon namespace (ns.route); this file creates no global and
  no frame. Classic-era content: uiMapIDs are the Classic Era ones (verified against WoW-Pro's
  WoWPro_ZoneData_Vanilla.lua), coordinates are percent (0-100) on that map.

  Each step:
    id        stable key, used for the per-character state (current step, skipped steps)
    faction   "Alliance", "Horde" or "Both"
    from, to  the skill range the step is for
    kind      "fish", "trainer", "quest" or "vendor"
    grants    the skill cap the step unlocks (75 Apprentice, 150 Journeyman, 225 Expert,
              300 Artisan). A step with grants is done once the cap reaches it, and becomes the
              current step only while the skill sits at the cap.
    optional  a vendor or quest step that unlocks nothing; /bfish route next skips it for good
    title     the line shown in chat, on the pins and as the GPS waypoint's name
    zone, mapID, x, y   the NPC (or, for the first fish steps, the anchor: fish any water nearby)
    spots     fishing coordinates { x, y, src }, src = where the coordinate comes from
    npc, note shown in the tooltip and by /bfish route

  Sources (see the README's Credits): pool coordinates are facts read from the GatherMate2 data
  dumps (Thurdi/GatherMate2_Data_Classic for Classic Era maps, "GM2 Classic"; Nevcairiel/
  GatherMate2_Data for retail maps, "GM2 retail", used only where the Classic data has nothing).
  NPC, quest and quest-fish positions come from warcraft.wiki.gg and method.gg, cross-checked
  with Warcraft Tavern, wow-professions.com and noobtoboss.
]]

local _, ns = ...
if type(ns) ~= "table" then return end

ns.route = {
  steps = {
    -- ===== 1-75: Apprentice =====
    { id = "a_train_app", faction = "Alliance", from = 1, to = 75, kind = "trainer", grants = 75,
      title = "Fishing 1: Apprentice trainer, Elwynn Forest",
      zone = "Elwynn Forest", mapID = 1429, x = 47.6, y = 62.2, npc = "Lee Brown",
      note = "Learn Apprentice Fishing (character level 5). Goldshire. Or Arnold Leland in Stormwind (55.0, 69.6)." },
    { id = "h_train_app", faction = "Horde", from = 1, to = 75, kind = "trainer", grants = 75,
      title = "Fishing 1: Apprentice trainer, Durotar",
      zone = "Durotar", mapID = 1411, x = 53.2, y = 81.6, npc = "Lau'Tiki",
      note = "Learn Apprentice Fishing (character level 5). South of Sen'jin Village. Undead: Clyde Kellen, Tirisfal Glades (67.2, 51.0)." },
    { id = "vendor_pole", faction = "Both", from = 1, to = 75, kind = "vendor", optional = true,
      title = "Fishing 1-75: buy a pole and lures",
      zone = "Any starting zone", npc = "Fishing Supply or Trade Supplies vendor",
      note = "Buy a Fishing Pole and Shiny Baubles (+25 for 10 min); a Strong Fishing Pole (+5) if you can. /bfish route next when done." },
    { id = "a_fish_elwynn", faction = "Alliance", from = 1, to = 75, kind = "fish",
      title = "Fishing 1-75: Elwynn Forest",
      zone = "Elwynn Forest", mapID = 1429, x = 47.6, y = 62.2,
      note = "Fish any water nearby: any pond or the coast; the Stormwind canals work too. The pin is the trainer, not a pool." },
    { id = "h_fish_durotar", faction = "Horde", from = 1, to = 75, kind = "fish",
      title = "Fishing 1-75: Durotar",
      zone = "Durotar", mapID = 1411, x = 53.2, y = 81.6,
      note = "Fish any water nearby: the coast by Sen'jin. Mulgore or Tirisfal Glades work as well. The pin is the trainer, not a pool." },

    -- ===== 75-150: Journeyman =====
    { id = "a_train_jour", faction = "Alliance", from = 50, to = 150, kind = "trainer", grants = 150,
      title = "Fishing 75: Journeyman trainer, Stormwind",
      zone = "Stormwind City", mapID = 1453, x = 55.0, y = 69.6, npc = "Arnold Leland",
      note = "Learn Journeyman Fishing (skill 50, character level 10). Trade District, by the canal." },
    { id = "h_train_jour", faction = "Horde", from = 50, to = 150, kind = "trainer", grants = 150,
      title = "Fishing 75: Journeyman trainer, Orgrimmar",
      zone = "Orgrimmar", mapID = 1454, x = 69.8, y = 29.6, npc = "Lumak",
      note = "Learn Journeyman Fishing (skill 50, character level 10). Valley of Honor." },
    { id = "vendor_crawlers", faction = "Both", from = 50, to = 150, kind = "vendor", optional = true,
      title = "Fishing 75-150: buy Nightcrawlers",
      zone = "Any Fishing Supply vendor", npc = "Fishing Supply vendor",
      note = "Nightcrawlers (+50, needs skill 50) keep fish from escaping. /bfish route next when done." },
    { id = "a_fish_westfall", faction = "Alliance", from = 75, to = 150, kind = "fish",
      title = "Fishing 75-150: Westfall",
      zone = "Westfall", mapID = 1436,
      spots = {
        { x = 46.4, y = 7.4, src = "GM2 Classic" },
        { x = 54.8, y = 8.6, src = "GM2 Classic" },
        { x = 42.0, y = 8.1, src = "GM2 retail" },
        { x = 37.5, y = 12.8, src = "GM2 retail" },
      },
      note = "North coast. Also fine: the Stormwind canals, Loch Modan, Darkshore, Redridge." },
    { id = "h_fish_barrens", faction = "Horde", from = 75, to = 150, kind = "fish",
      title = "Fishing 75-150: The Barrens",
      zone = "The Barrens", mapID = 1413,
      spots = {
        { x = 46.4, y = 37.4, src = "GM2 Classic" },
        { x = 45.9, y = 37.9, src = "GM2 Classic" },
        { x = 48.0, y = 40.1, src = "GM2 Classic" },
        { x = 62.9, y = 38.9, src = "GM2 Classic" },
      },
      note = "The pools by the Wailing Caverns, or the coast at Ratchet. Also fine: Orgrimmar, Silverpine Forest." },

    -- ===== 150: Expert (a book) =====
    { id = "expert_book", faction = "Both", from = 125, to = 225, kind = "vendor", grants = 225,
      title = "Fishing 150: Expert book, Booty Bay",
      zone = "Stranglethorn Vale", mapID = 1434, x = 27.4, y = 77.0, npc = "Old Man Heming",
      note = "Buy and read 'Expert Fishing - The Bass and You' (about 1g, also on the AH; skill 125, character level 20). The Happy Bobber, lowest platform. Also sells Bright Baubles (+75) and Nightcrawlers. There is no Expert trainer; Myizz Luckycatch next to him (27.6, 77.0) trains only Apprentice and Journeyman." },

    -- ===== 150-225 =====
    { id = "h_quest_snapjaws", faction = "Horde", from = 100, to = 225, kind = "quest", optional = true,
      title = "Fishing 100-225: pole quest, The Hinterlands",
      zone = "The Hinterlands", mapID = 1425, x = 80.2, y = 81.4, npc = "Katoom the Angler",
      note = "Optional: 'Snapjaws, Mon!' gives Nat Pagle's Extreme Angler FC-5000 (needs skill 100). Revantusk Village. /bfish route next to skip." },
    { id = "a_quest_snapjaws", faction = "Alliance", from = 100, to = 225, kind = "quest", optional = true,
      title = "Fishing 100-225: pole quest, The Hinterlands",
      zone = "The Hinterlands", mapID = 1425, npc = "Dron Blastbrew",
      note = "Optional and unconfirmed: 'Snapjaws, Lad!' (Stormfeather Outpost) is listed by warcraft.wiki.gg only; other guides say the pole quest is Horde-only. No position known. /bfish route next to skip." },
    { id = "fish_dustwallow", faction = "Both", from = 150, to = 225, kind = "fish",
      title = "Fishing 150-225: Dustwallow Marsh",
      zone = "Dustwallow Marsh", mapID = 1445,
      spots = {
        { x = 54.6, y = 11.8, src = "GM2 Classic" },
        { x = 58.8, y = 16.7, src = "GM2 Classic" },
        { x = 61.9, y = 20.2, src = "GM2 Classic" },
        { x = 63.7, y = 36.8, src = "GM2 Classic" },
      },
      note = "Inland waters and the coast north of Theramore; use Bright Baubles. The Artisan quest giver is here too. Also fine: the Stranglethorn coast, Desolace, Swamp of Sorrows, Arathi Highlands, Thousand Needles." },
    { id = "fish_desolace", faction = "Both", from = 150, to = 225, kind = "fish",
      title = "Fishing 150-225: Desolace (alternative)",
      zone = "Desolace", mapID = 1443,
      spots = {
        { x = 25.2, y = 78.2, src = "GM2 Classic" },
        { x = 25.5, y = 78.1, src = "GM2 Classic" },
        { x = 25.8, y = 75.7, src = "GM2 Classic" },
      },
      note = "Alternative to Dustwallow, by Shadowprey Village (Horde trainer Lui'Mala 22.6, 72.6). The Shellfish Traps here can drop the Big Iron Fishing Pole." },

    -- ===== 225: Artisan (a quest) =====
    { id = "artisan_quest", faction = "Both", from = 225, to = 225, kind = "quest", grants = 300,
      title = "Fishing 225: Artisan quest, Nat Pagle",
      zone = "Dustwallow Marsh", mapID = 1445, x = 58.6, y = 60.0, npc = "Nat Pagle",
      note = "Take 'Nat Pagle, Angler Extreme' (skill 225; guides say character level 35). Nat's Landing, the island south-west of Theramore. Do not be in a raid group while you fish the four fish. /bfish route next for each fish." },
    { id = "artisan_feralas", faction = "Both", from = 225, to = 225, kind = "fish", grants = 300,
      title = "Fishing 225: Feralas Ahi",
      zone = "Feralas", mapID = 1444,
      spots = { { x = 62.0, y = 51.0, src = "warcraft.wiki.gg" } },
      note = "Feralas Ahi, in the Verdantis River south-east of Dire Maul. The quest must be active. /bfish route next once you have it." },
    { id = "artisan_swamp", faction = "Both", from = 225, to = 225, kind = "fish", grants = 300,
      title = "Fishing 225: Misty Reed Mahi Mahi",
      zone = "Swamp of Sorrows", mapID = 1435,
      spots = {
        { x = 93.0, y = 40.0, src = "warcraft.wiki.gg" },
        { x = 90.4, y = 37.2, src = "GM2 retail" },
        { x = 90.0, y = 43.4, src = "GM2 retail" },
      },
      note = "Misty Reed Mahi Mahi, at the Misty Reed Strand on the south-east shore. /bfish route next once you have it." },
    { id = "artisan_desolace", faction = "Both", from = 225, to = 225, kind = "fish", grants = 300,
      title = "Fishing 225: Sar'theris Striker",
      zone = "Desolace", mapID = 1443,
      spots = {
        { x = 25.0, y = 77.0, src = "warcraft.wiki.gg" },
        { x = 25.2, y = 78.2, src = "GM2 Classic" },
      },
      note = "Sar'theris Striker, at the Sar'theris Strand south of Shadowprey Village. /bfish route next once you have it." },
    { id = "artisan_stv", faction = "Both", from = 225, to = 225, kind = "fish", grants = 300,
      title = "Fishing 225: Savage Coast Blue Sailfin",
      zone = "Stranglethorn Vale", mapID = 1434,
      spots = {
        { x = 33.0, y = 32.0, src = "warcraft.wiki.gg" },
        { x = 34.1, y = 32.9, src = "GM2 Classic" },
      },
      note = "Savage Coast Blue Sailfin, on the Savage Coast south of Grom'gol. /bfish route next once you have it." },
    { id = "artisan_turnin", faction = "Both", from = 225, to = 225, kind = "quest", grants = 300,
      title = "Fishing 225: hand in to Nat Pagle",
      zone = "Dustwallow Marsh", mapID = 1445, x = 58.6, y = 60.0, npc = "Nat Pagle",
      note = "Hand in all four fish: Artisan Fishing, up to 300." },

    -- ===== 225-300 =====
    { id = "fish_dustwallow_nat", faction = "Both", from = 225, to = 260, kind = "fish",
      title = "Fishing 225-260: Dustwallow Marsh",
      zone = "Dustwallow Marsh", mapID = 1445,
      spots = { { x = 63.7, y = 36.8, src = "GM2 Classic" } },
      note = "Keep fishing near Nat with Bright Baubles; any water works. Move on early: catches here stop giving skill quickly. The pin is the nearest known pool." },
    { id = "a_fish_feralas", faction = "Alliance", from = 225, to = 300, kind = "fish",
      title = "Fishing 225-300: Feralas",
      zone = "Feralas", mapID = 1444,
      spots = {
        { x = 34.3, y = 34.3, src = "GM2 Classic" },
        { x = 36.8, y = 36.4, src = "GM2 Classic" },
        { x = 39.5, y = 37.2, src = "GM2 Classic" },
        { x = 44.0, y = 51.0, src = "GM2 Classic" },
      },
      npc = "Brannock",
      note = "The coast and the Verdantis River around Feathermoon Stronghold (32.2, 41.6, trainer Brannock). Bright Baubles. Tanaris is the alternative (/bfish route next)." },
    { id = "h_fish_hinterlands", faction = "Horde", from = 225, to = 300, kind = "fish",
      title = "Fishing 225-300: The Hinterlands",
      zone = "The Hinterlands", mapID = 1425,
      spots = {
        { x = 79.4, y = 67.3, src = "GM2 retail" },
        { x = 79.4, y = 61.9, src = "GM2 retail" },
      },
      npc = "Katoom the Angler",
      note = "Revantusk Village and the east coast (trainer Katoom 80.2, 81.4). Bright Baubles. Tanaris is the alternative (/bfish route next)." },
    { id = "fish_tanaris", faction = "Both", from = 225, to = 300, kind = "fish",
      title = "Fishing 225-300: Tanaris",
      zone = "Tanaris", mapID = 1446,
      spots = {
        { x = 67.9, y = 23.6, src = "GM2 Classic" },
        { x = 68.7, y = 23.0, src = "GM2 Classic" },
        { x = 67.9, y = 22.7, src = "GM2 Classic" },
        { x = 67.4, y = 19.4, src = "GM2 Classic" },
      },
      note = "The coast at Steamwheedle Port, often named the best spot to 300. Also fine: Un'Goro Crater, Felwood, Western Plaguelands." },
  },

  -- Gear worth having on the way; shown by /bfish route gear.
  gear = {
    { name = "Fishing Pole", how = "Any Fishing Supply or Trade Supplies vendor." },
    { name = "Strong Fishing Pole (+5, skill 10)", how = "Fishing vendors, about 10s." },
    { name = "Big Iron Fishing Pole (+20, skill 100)", how = "Shellfish Traps in Desolace (rare) or the AH." },
    { name = "Nat Pagle's Extreme Angler FC-5000 (+25, skill 100)", how = "Quest 'Snapjaws, Mon!', Katoom the Angler, Revantusk Village (Horde)." },
    { name = "Shiny Bauble (+25, 10 min)", how = "Fishing vendors." },
    { name = "Nightcrawlers (+50, 10 min, skill 50)", how = "Fishing vendors, Old Man Heming." },
    { name = "Bright Baubles (+75, 10 min)", how = "Old Man Heming, Booty Bay." },
    { name = "Aquadynamic Fish Attractor (+100, 5 min)", how = "Old Man Heming, or Engineering." },
  },
}
