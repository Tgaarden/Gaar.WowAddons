--[[
  GaarForever - the hub's tools (3.1): what's new, per-character profiles, settings export /
  import and the API self-test. Loaded before Core.lua, which calls these through the addon's
  private namespace (ns.Tools) and hands in its saved variables at ADDON_LOADED (Tools.Bind).

  What's new
    GaarForeverDB.seen = { [addon name] = "last version seen" }. At login every installed
    family addon's version (its API table's version, else the TOC's ## Version) is compared with
    the one seen last; a newer one gives one chat line,
      GaarForever: updated - GaarBuffsForever 1.5.1 -> 1.6.0: <note>
    with the note from CHANGES below (only when it is written for that exact version; otherwise
    just the versions). The first login with this feature only records the versions. An addon
    installed later is announced as new. /gf news reprints the last block; /gf news on|off
    switches the lines (versions are still recorded while it is off).

  Profiles, export, import
    For addons built on the library's A:InitDB (see Lib.lua, "Per-character settings"):
    /gf profile, /gf profile char|shared <addon|all>, /gf export <addon>, /gf import.

  Self-test
    /gf selftest probes, each call in pcall, the client APIs the family relies on, on player,
    target and party1, and records ok / nil / secret / error per call. It runs now and once more
    on the other side of the next combat change (entering combat after an out-of-combat run),
    then shows both side by side in a copyable text window. /gf selftest show reopens the window.
]]

local _G = _G
local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Lib = _G.GaarForever

local Tools = {}
ns.Tools = Tools

local IsSecret, Str, Num = Lib.IsSecret, Lib.Str, Lib.Num
local ARROW = " \226\134\146 "  -- " → "
local EM_DASH = "\226\128\148"   -- "—"

local hub        -- { db, ADDONS, VERSION, Print, API } from Core.lua
local function Print(msg) if hub then hub.Print(msg) end end

-- ---------------------------------------------------------------------------
-- Change notes, written by hand from the git history: the newest note per addon, keyed by the
-- version it belongs to. Keyed by folder name (GaarBagsForever ...), the name the hub and the
-- saved "seen" versions use (seen versions from before the folder rename are re-keyed in Bind). A version not listed here is announced
-- without a note.
-- ---------------------------------------------------------------------------

local CHANGES = {
    GaarForever = {
        ["3.2.96"] = "notes for GaarBuffsForever 1.11.2: self-buff rows show only while missing or expiring soon (same window as the class buffs, /gbuff expire); both buffs up hides the strip",
        ["3.2.95"] = "notes for GaarBuffsForever 1.11.1: detects WoW Forever's 'Camp Benefits' campfire buff.",
        ["3.2.94"] = "notes for GaarBuffsForever 1.11.0: self buffs on every class - a small strip with your XP food buff and campfire buff and their time left, red when missing; click eats an XP food from your bags or casts Basic Campfire (/gbuff self); detected by keyword, learned IDs in /gbuff status",
        ["3.2.93"] = "notes for GaarGroupForever 1.6.0: threat bars at the bottom of the group bar - one bar per party member with their threat % on your target (or your target's target), highest first, in class colour, aggro marked (/ggf threat on|off)",
        ["3.2.92"] = "notes for GaarQuestsForever 1.16.0: the quest filter's dungeon & raid checkbox is now a 3-way choice - all quests, only dungeon & raid quests, or no dungeon & raid quests (/gqf filter dungeons all|only|none); your old setting carries over",
        ["3.2.91"] = "Removed the old Better...Forever settings-bridge folders from the download (rename migration period over).",
        ["3.2.90"] = "Release with CurseForge required-dependency on GaarForever and suite links in every description.",
        ["3.2.89"] = "notes for GaarQuestsForever 1.15.2: more space between the +/− button and the quest count.",
        ["3.2.88"] = "notes for GaarQuestsForever 1.15.1: the collapse/expand-all +/- button now sits inside the quest log search box at its right end (left of the clear X while typing), no longer overlapping the quest count",
        ["3.2.87"] = "notes for GaarQuestsForever 1.15.0: quest filter in the quest log's gear menu and the tracker menu - only completed or only uncompleted quests, hide dungeon & raid quests; applies to the quest log and the tracker (/gqf filter)",
        ["3.2.86"] = "notes for GaarMapsForever 1.8.0: a yellow ? on the continent and world maps for every quest ready to turn in, at its turn-in point (/gmf turnins on|off); level ranges for Riverglades, Shen'dralas and Mount Hyjal",
        ["3.2.85"] = "notes for GaarMapsForever 1.7.0: a built-in seed of NPC places for the tracked pins (empty for now, filled from our own exports) and /gmf pins export, a copyable window with your learned places",
        ["3.2.84"] = "notes for GaarMapsForever 1.6.0: NPC icons on a zone map for the types checked in the minimap tracking menu (banker, mailbox, flight master, trainers, repair and more), learned as you visit them and shared by all your characters; /gmf pins on|off|clear",
        ["3.2.83"] = "notes for GaarBarsForever 1.6.1: the flyout editor's button in the spellbook is a full-size tab like Missing from bars; while Missing from bars is open only its tab looks selected; spells on your bars through a flyout or a macro no longer get Blizzard's not-on-your-bars glow in the spellbook; the orange frames on spellbook icons (low-rank ring, rotation helper) are hidden by default (/gbars bookframe on|off)",
        ["3.2.82"] = "notes for GaarMapsForever 1.5.3: zones missing from the level table (WoW Forever's new ones) now get their level range from the client when it has one; /gmf status lists the maps that still have none",
        ["3.2.81"] = "notes for GaarBarsForever 1.6.0: Flyouts v2 - each flyout is its own object with a name, an icon and its own macro (GF <name>) that carries it on your bars; a flyout editor (/gbars flyouts, or the button next to Missing from bars in the spellbook); the button's key again while its flyout is open casts entry 1 (/gbars flyout samekey on|off); 1.5 flyouts are converted once",
        ["3.2.80"] = "notes for GaarBarsForever 1.5.2: right-clicking a button with a flyout now really casts the flyout's first entry without opening it (in and out of combat, also after the main bar pages); a /gbars status line says on how many buttons it is set",
        ["3.2.79"] = "notes for GaarBarsForever 1.5.1: spells and macros inside a flyout count as on your bars in the Missing from bars tab (same rank rules); right-click a button with a flyout casts its first entry without opening it (works in combat)",
        ["3.2.78"] = "notes for the new GaarProfessionsForever 1.0.0: a Professions row in the menu and on the Options page (/gprof)",
        ["3.2.77"] = "notes for GaarBarsForever 1.5.0: flyouts on action buttons: drop a spell, item or macro on the + a button shows and it opens a flyout of up to 12 (click or its key, then 1-9, 0, -, = cast; works in combat); right-click or drag out to remove; /gbars flyout on|off and dir up|down|left|right",
        ["3.2.76"] = "notes for GaarBarsForever 1.4.1: the Missing from bars tab moves to the spellbook's bottom-left corner as a square icon tab in Forever's tab look, with a count; the category tabs no longer vanish while its list is open; What's Training?'s tab and ours close each other",
        ["3.2.75"] = "notes for GaarBarsForever 1.4.0: a Missing from bars tab in the spellbook, left of General: one list of the spells that are on no bar or only at a lower rank, in Blizzard's look; drag to a bar, click to cast; /gbars missing on|off",
        ["3.2.74"] = "notes for GaarMapsForever 1.5.2: the zone level is one line in the same spot under Blizzard's hover name in zone view too: the hovered neighbour's range, else this map's; no zone name from us",
        ["3.2.73"] = "notes for GaarMapsForever 1.5.1: the zone level title in zone view sits lower, so Blizzard's hover label for a neighbouring zone no longer covers it",
        ["3.2.72"] = "notes for GaarMapsForever 1.5.0: the zone's level range (Level 35-45, coloured like mob difficulty) on the world map: a title in zone view, under the hover name on the continent map; /gmf levels on|off",
        ["3.2.71"] = "notes for GaarQuestsForever 1.14.0: a +/- button in the quest log header row collapses or expands every zone header at once (/gqf collapse); the tracker's Quests header shows the quest count, Quests 38/40 (/gqf questcount)",
        ["3.2.70"] = "notes for GaarChatForever 1.7.0: autoGroupChannel - the chat box switches to Party/Raid when you join a group and back to your old channel when you leave; /gchat autogroupchannel on|off",
        ["3.2.69"] = "notes for GaarXPForever 1.5.3: rested cap follows Well Rested (180%), auto-detected; /gxp restcap auto|150|180",
        ["3.2.68"] = "notes for GaarXPForever 1.5.2: the Rested line shows % of max rested and the time until rested XP is full",
        ["3.2.67"] = "notes for GaarXPForever 1.5.1: the ready-quest XP segment on the XP bar shows again (the map / quest log is no longer seen as open when it is closed)",
        ["3.2.66"] = "notes for GaarGroupForever 1.5.4: the addon has its CurseForge project id (GaarGroupForever is on CurseForge) and its README shows screenshots of the Tank, DPS and Healer modes, the right-click menu and the options",
        ["3.2.65"] = "notes for GaarGroupForever 1.5.3: the role row is one compact strip (28 px) in every mode; the Healer tank frame moved up beside Drink / OOM (\"No tank\" shows while there is none), so there is no empty space below the buttons",
        ["3.2.64"] = "notes for GaarGroupForever 1.5.2: the panel keeps the same height in Tank, DPS and Healer mode (the role row has a fixed height) and always grows and shrinks downward - the title never moves; an old centre-anchored position is converted once",
        ["3.2.63"] = "notes for GaarBagsForever 1.13.4: the do-not-sell padlock is half the size of its item slot (a quarter of the slot) and sits under the stack count, which stays readable",
        ["3.2.62"] = "notes for GaarGroupForever 1.5.1: role icons stay visible after you pick a role (the active state is now a glow overlay instead of an opaque checked texture)",
        ["3.2.61"] = "notes for GaarGroupForever 1.5.0: Blizzard-style panel - one dialog frame with a title plate, red Blizzard buttons for Ready/Roles/Pull and the tabs, square action-style role and raid-marker buttons, tidy member rows",
        ["3.2.60"] = "notes for GaarBagsForever 1.13.3: WoW Forever has no realms, so gold and item counts are one account-wide list (the bag gold tooltip showed nothing when the client gave no realm name); old realm entries, including ones saved under no realm, are merged in without losing or double counting anything",
        ["3.2.59"] = "notes for GaarGroupForever 1.4.1: fixes the \"blocked from an action only available to the Blizzard UI\" popup at login (the instance panel no longer listens to the combat log, which WoW Forever keeps from addons; bosses are ticked from the kill chat line instead); the Healer tank frame and DPS Assist button no longer sit inside the bar, so the bar can hide, move and scale in combat; /ggf status lists any action the game blocked",
        ["3.2.58"] = "notes for GaarGroupForever 1.4.0: instance info panel (/ggf info, Info button) with levels, bosses and loot for your class",
        ["3.2.57"] = "notes for GaarGroupForever 1.3.0: role modules - Tank (pull marker, lost-aggro warning, healer mana before the pull, loose mobs), Healer (Drink/OOM, dispel alert, tank frame, dead/out-of-range, PvP flag) and DPS (assist tank, wrong target, aggro, CC markers, interrupt); /ggf tank|healer|dps",
        ["3.2.56"] = "notes for GaarBagsForever 1.13.2: the gold hover in the bag window works on more layouts (coin buttons a level deeper, or no frame taking the mouse) and /gbf gold and /gbf status say what it found; a login that knows only your first name no longer folds other characters into you; characters saved before the rename come back once the BetterBagsForever bridge folder is installed",
        ["3.2.55"] = "notes for GaarGroupForever 1.2.0: a dock under the bar with a group overview list, a pre-pull check (/ggf check, local report, Announce on click), a raid marker row and a per-character dungeon run log (/ggf log); each has its own option, all on by default",
        ["3.2.54"] = "notes for GaarGpsForever 1.6.0: hover a flight path on the map to see its direct flight connections (/ggps routes)",
        ["3.2.53"] = "notes for GaarBuffsForever 1.10.0, GaarCastbarsForever 1.4.0, GaarChatForever 1.6.0, GaarFramesForever 1.8.0, GaarGroupForever 1.1.0, GaarLootForever 1.4.0, GaarFishingForever 1.7.0 and GaarXPForever 1.5.0: every addon with a test mode has a Test entry in its menu (kept just before Reset); new test modes for the fishing session panel (/gfish test) and the XP panel (/gxp test); /ggf test is also a menu entry",
        ["3.2.52"] = "notes for the new GaarGroupForever 1.0.0: a Group row in the menu and on the Options page (/ggf)",
        ["3.2.51"] = "notes for GaarBagsForever 1.13.1: the gold of your other characters (hover the bag gold, /gbf gold) is found again: records kept under another spelling of the realm or of your name (\"Dru\" vs \"Dru Tics\") are merged into one and never counted twice",
        ["3.2.50"] = "notes for GaarPlatesForever 1.4.1 and GaarFramesForever 1.7.1: both colour a mob level with the same shared classic difficulty bands, so a plate and the target frame agree",
        ["3.2.48"] = "notes for GaarFramesForever 1.7.0: PvP flag icon beside the portrait, with the flag timer on the player frame",
        ["3.2.47"] = "notes for GaarXPForever 1.4.1: the kills estimate is now (XP left to level) / (average XP per kill); ready or done quest XP no longer lowers it",
        ["3.2.46"] = "notes for GaarPlatesForever 1.4.0: the level number on a plate is coloured by difficulty against your level (option: /gpf levelcolor on|off)",
        ["3.2.45"] = "notes for GaarMailForever 1.5.0: our Open All Mail button takes the place of Blizzard's Open All button in the Inbox (option: /gmail blizzopenall on|off)",
        ["3.2.44"] = "notes for GaarMailForever 1.4.0: an option hides Blizzard's own Open All button in the Inbox (on by default; /gmail blizzopenall on|off)",
        ["3.2.43"] = "notes for GaarMailForever 1.3.1: the Open All button sits a little higher in the Inbox frame",
        ["3.2.42"] = "notes for GaarChatForever 1.5.0: /gchat test and a Show test lines (chat) button put sample chat lines in the main chat frame, to show the tweaks",
        ["3.2.41"] = "notes for GaarLootForever 1.3.1: the Options page text about the Need/Greed/Pass counts and the right-click menu reads correctly again",
        ["3.2.40"] = "notes for GaarFramesForever 1.6.0: spell cost on the player power bar while casting",
        ["3.2.39"] = "the Options > AddOns subpages are now listed A-Z (Bags, Bars, Buffs, Castbars, ...) instead of in load order",
        ["3.2.37"] = "notes for the right-click menus: GaarForever.AttachMenu(target, opts) and FindPortrait; right-click the bag, mailbox and merchant portraits, and the XP, loot, fishing, chat feed, buff and cast bar windows to open that addon's menu",
        ["3.2.36"] = "notes for GaarChatForever 1.3.0: right-click a chat tab: a GaarChat submenu at the bottom of Blizzard's tab menu with the same options as the hub menu",
        ["3.2.35"] = "notes for GaarMapsForever 1.4.1: the portrait right-click button is placed and raised more robustly (re-placed on every map show, own size, above the border) and shows menu errors; /gmf portrait for its state",
        ["3.2.34"] = "notes for GaarMapsForever 1.4.0: right-click the round portrait in the world map's top-left corner to open the GaarMaps menu",
        ["3.2.33"] = "notes for GaarGpsForever 1.5.3: client flight paths and graveyards named zzOLD..., [DNT], DEPRECATED, UNUSED or TEST (dead or test data) are no longer drawn, learned or listed",
        ["3.2.32"] = "notes for GaarGpsForever 1.5.2: learned flight paths only from real evidence; the learned list is reset once - all flight paths are grey until you next open a flight master's map",
        ["3.2.31"] = "notes for GaarGpsForever 1.5.1: learned flight paths green on the map; flight paths and graveyards from the client's own data (WoW Forever zones too)",
        ["3.2.30"] = "notes for GaarMailForever 1.2.0: once a recipient is chosen, an empty mail subject becomes \"From <your full name>\" (/gmail subject on|off); typed text is never replaced and an attached item's name wins",
        ["3.2.29"] = "notes for GaarGpsForever 1.5.0: all graveyards and flight paths on the world and zone map, grey until learned (/ggps flights, /ggps graves)",
        ["3.2.28"] = "notes for GaarXPForever 1.3.8: XP from mobs and quests are kept apart: the kills estimate uses only mob kills (average base XP of the last 20 kills, quest XP no longer inflates it), and XP/hour shows the split (mobs, quests, other)",
        ["3.2.27"] = "surname fixes: shared name helpers (PlayerFullName, NamesMatch, UnitByName); notes for GaarChatForever 1.2.2 and GaarLootForever 1.2.3",
        ["3.2.26"] = "notes for GaarFramesForever 1.5.3: HoT preview while casting now finds the target for characters with a surname",
        ["3.2.25"] = "notes for GaarFramesForever 1.5.2: /gff hotdebug is short enough for one screenshot and ends with the cast summary; new /gff hotdebug cast traces your next cast",
        ["3.2.24"] = "notes for GaarFramesForever 1.5.1: HoT preview while casting Regrowth on yourself now shows",
        ["3.2.23"] = "notes for GaarXPForever 1.3.7: hovering the XP bar changes nothing now; Blizzard's hover text is hidden and our text stays exactly where it was",
        ["3.2.22"] = "notes for GaarXPForever 1.3.6: our XP text no longer jumps right when the mouse hovers the XP bar; it keeps the position it has when Blizzard shows the short non-hover text",
        ["3.2.21"] = "notes for GaarXPForever 1.3.5: the XP bar is found again when a reputation bar is tracked too: both bar containers are scanned, bars are matched by their key or XP structure (rested fill / tick), and the visible XP bar gets the text, orange quest segment and rested shift; /gxp status shows which container and key matched",
        ["3.2.20"] = "notes for GaarFramesForever 1.5.0: overheal past the health bar, HoT shown while casting",
        ["3.2.19"] = "notes for GaarXPForever 1.3.4: the text on the XP bar is now only on the XP bar, never on the reputation bar above it; Blizzard's own XP text is kept and ours (percent, rested, ready-quest XP) is added to the right of it, dropping rested then quest if it would not fit; the orange quest segment and rested shift are locked to the XP bar too",
        ["3.2.18"] = "notes for GaarBagsForever 1.12.0",
        ["3.2.17"] = "notes for GaarXPForever 1.3.3: the rested tick on the XP bar no longer shows a striped block; it now copies the Blizzard tick atlas or tex coords, else draws a thin light line, centred on the end of the rested segment",
        ["3.2.16"] = "notes for GaarXPForever 1.3.2: with ready quests on the XP bar, the rested bar and its tick now sit after the orange quest segment instead of under it",
        ["3.2.15"] = "notes for GaarFramesForever 1.4.4: steadier yellow HoT segment",
        ["3.2.14"] = "notes for GaarQuestsForever 1.13.0: new sort mode, zone",
        ["3.2.13"] = "notes for GaarXPForever 1.3.1: ready quests, their XP and the orange bar segment now update right when a quest completes, is turned in, abandoned or accepted (more quest events, a trailing scan after the throttle, and a follow-up scan about 1 s later)",
        ["3.2.12"] = "notes for GaarBarsForever 1.3.2: spellbook low-rank ring re-evaluated on every page/tab/search change from the spell actually bound to each pooled entry, hidden on entries that are not visible",
        ["3.2.11"] = "notes for GaarBarsForever 1.3.1: the orange low-rank ring in the paged spellbook is now sized and centred on the spell icon, not the whole entry",
        ["3.2.10"] = "notes for GaarXPForever 1.3.0: the XP of ready quests as a coloured segment on the XP bar (/gxp readybar)",
        ["3.2.9"] = "notes for GaarXPForever 1.2.1",
        ["3.2.8"] = "notes for GaarGpsForever 1.4.0",
        ["3.2.7"] = "notes for GaarXPForever 1.2.0",
        ["3.2.6"] = "notes for GaarBagsForever 1.11.0",
        ["3.2.4"] = "The minimap menu lists the addons alphabetically",
        ["3.2.3"] = "GaarMerchantForever still skips locked items when an old BetterBagsForever is installed",
        ["3.2.2"] = "Renamed to GaarForever (new folders; settings move over automatically on first login; new /gf commands, old ones still work); /gf export all and /gf import move every addon's settings; an old Better...Forever addon not yet updated no longer breaks beside the new hub",
        ["3.2.1"] = "Renamed to GaarForever (new folders; settings move over automatically on first login; new /gf commands, old ones still work); /gf export all and /gf import move every addon's settings",
        ["3.2.0"] = "Renamed to GaarForever (new folders; settings move over automatically on first login; new /gf commands, old ones still work)",
        ["3.1.1"] = "notes for every addon's current version",
        ["3.1.0"] = "what's new on login, per-character settings, export / import, /gf selftest",
        ["3.0.2"] = "a Loot row for GaarLootForever",
    },
    GaarBagsForever = {
        ["1.13.2"] = "Gold hover in the bag window: every frame in the money frame is hooked, plus a mouse-over check that needs no frame to take the mouse; /gbf gold and /gbf status show the characters per realm, the money frames found and the last hover (or its error); a first-name login no longer folds other characters into yours; characters saved before the rename are merged in once the BetterBagsForever bridge folder is installed",
        ["1.13.0"] = "right-click bag portrait: opens the addon's menu",
        ["1.12.0"] = "Locked items cannot be destroyed, auctioned or traded either: put back in the bags with a popup (dropping on the world, the auction sell slot, a trade slot); one shared popup for every block, mail included",
        ["1.11.0"] = "Locked items cannot be mailed (taken off the Send Mail tab, with a popup); cyan ring on bag items attached to the outgoing mail (/gbf mailglow)",
        ["1.10.1"] = "API: IsItemLocked(itemID), so GaarMerchantForever can ask for locks",
        ["1.10.0"] = "Renamed to GaarBagsForever (new folders; settings move over automatically on first login; new /gbf commands, old ones still work)",
        ["1.9.3"] = "the addon's own name in its menu errors",
        ["1.9.2"] = "shared helpers from the GaarForever library",
    },
    GaarQuestsForever = {
        ["1.16.0"] = "Quest filter: the Hide dungeon & raid quests checkbox is now a 3-way choice under a divider - All quests (any type), Only dungeon & raid quests, No dungeon & raid quests - in the gear menu, the tracker menu and the hub. Combines with Only completed / uncompleted. /gqf filter dungeons all|only|none (on = none, off = all). Your old setting carries over.",
        ["1.15.0"] = "Quest filter: the quest log's gear menu (next to Show Quest Objectives) and the tracker header's right-click menu (Quest log filter) get Show all quests / Only completed / Only uncompleted and Hide dungeon & raid quests. It applies to the quest log list (no gaps, empty zone headers hidden, the count reads Quests: 37/40 (12 shown)) and the tracker's Quests section; map pins are untouched. With auto-watch on, filtered quests are not watched; with it off your watch list is never changed. Hide dungeon & raid quests pauses inside an instance while the dungeon filter is on. /gqf filter all|completed|uncompleted, /gqf filter dungeons on|off",
        ["1.14.0"] = "Collapse-all button in the quest log: a +/- button between the search box and the quests count collapses or expands every zone header (/gqf collapse); the tracker's Quests header shows the quest count (/gqf questcount)",
        ["1.13.0"] = "New sort mode: /gqf sort zone groups quests by quest-log zone, your current zone first, the others A-Z, no zone last; level order inside each zone; re-sorts when you change zone",
        ["1.11.0"] = "Renamed to GaarQuestsForever (new folders; settings move over automatically on first login; new /gqf commands, old ones still work)",
        ["1.10.3"] = "the addon's own name in its menu errors",
        ["1.10.2"] = "uses the GaarForever shared library",
    },
    GaarMapsForever = {
        ["1.8.0"] = "Quest turn-ins on the continent and world maps: Blizzard shows the yellow ? of a finished quest only on the zone map; now every quest that is ready to turn in also gets its ? on the continent (Kalimdor, Eastern Kingdoms, WoW Forever's own) and the world map, at its exact turn-in point. Hover it for the quest, the zone and the turn-in NPC (the log's Return to ... line); quests turned in at the same spot share one ?. Zone maps are unchanged (Blizzard draws them there). /gmf turnins on|off, a menu entry, and a status line in /gmf status with how many are shown and how many finished quests have no position yet. Zone levels: Riverglades 36-44, Shen'dralas 40-45 and Mount Hyjal 55-60; zone names now match regardless of case and apostrophe",
        ["1.7.0"] = "Tracked pins: a read-only built-in seed (Data/TrackedSeed.lua, our own data only, empty for now) merged with what you learn - your learned places always win. New /gmf pins export [<mapID> | here]: your learned places as text in a copyable window (Select all, Ctrl+C), in exactly the seed's format, so places walked in the capitals can be added to the seed",
        ["1.6.0"] = "Tracked NPC pins: on a map that shows one zone (never a continent or the world map), icons for the town NPCs whose types are checked in the minimap tracking menu - Auctioneer, Banker, Battlemaster, Class and Profession Trainers, Flight Master, Innkeeper, Mailbox, Repair, Stable Master, Food & Drink, Reagents, Poisons, Ammunition - with the tracking type's own icon; they follow the menu as you tick types on and off. The places are learned when you open an NPC's window (merchant, bank, auction house, flight master, trainer, mailbox, innkeeper, stable master, battlemaster) and saved account-wide, so every character shares them. Hover an icon for the name and categories. /gmf pins on|off, /gmf pins clear (asks first), a menu entry, and a status line in /gmf status",
        ["1.5.3"] = "Zone levels for zones missing from the built-in table (WoW Forever's new zones): the range is read from the client (C_Map.GetMapLevels) when it has one, guarded and cached. /gmf status lists the map ids and names that still show no level, so gaps can be reported",
        ["1.5.2"] = "Zone view: one level line, always in the same spot under Blizzard's hover name, no zone name from us; shows the hovered neighbour's range, else the shown zone's",
        ["1.5.1"] = "Zone view: the zone name and level title moved down so Blizzard's hover label for a neighbouring zone no longer draws on top of it",
        ["1.5.0"] = "Zone level range on the world map, Level 35-45, coloured like mob difficulty: a title in zone view and under the hover name on the continent map; classic zone table; /gmf levels on|off, menu entry, /gmf status shows the matched range",
        ["1.4.1"] = "Portrait right-click button fixed: fixed 60x60 size, re-placed and raised above the border every time the map opens, menu errors are shown; /gmf portrait shows its state",
        ["1.4.0"] = "Right-click the round portrait in the world map's top-left corner to open the GaarMaps menu (lock, reset, scale, fade, zone map)",
        ["1.2.0"] = "Renamed to GaarMapsForever (new folders; settings move over automatically on first login; new /gmf commands, old ones still work)",
        ["1.1.3"] = "the addon's own name in its chat lines and menu errors",
        ["1.1.2"] = "uses the GaarForever shared library",
    },
    GaarCastbarsForever = {
        ["1.4.0"] = "Test mode entry moved next to Reset positions & sizes in the menu",
        ["1.3.0"] = "right-click cast bar: opens the addon's menu",
        ["1.2.0"] = "Renamed to GaarCastbarsForever (new folders; settings move over automatically on first login; new /gcf commands, old ones still work)",
        ["1.1.6"] = "the addon's own name in its menu errors",
        ["1.1.5"] = "uses the GaarForever shared library",
    },
    GaarPlatesForever = {
        ["1.4.0"] = "The level number is coloured by difficulty against your level, like Blizzard (grey, green, yellow, orange, red; skull level red); option /gpf levelcolor on|off (on by default)",
        ["1.3.0"] = "Renamed to GaarPlatesForever (new folders; settings move over automatically on first login; new /gpf commands, old ones still work)",
        ["1.2.12"] = "the addon's own name in its menu errors",
        ["1.2.11"] = "secret-safe value checks",
    },
    GaarGpsForever = {
        ["1.6.0"] = "Flight connections on hover: hover a flight path on the map to see the flight paths it connects to directly - lines on the map and a list in the tooltip, green when learned, grey when not (/ggps routes on|off, also in the menu). The network comes from the client's own flight table and is corrected from the routes the game offers at each flight master",
        ["1.5.2"] = "Fix: flight paths you had not learned could show green. Learned now needs positive evidence (a known node on an open flight master's map, Current or Reachable; the client's isUndiscovered only once it has been seen to tell the two apart), and the Alliance and Horde flight master of a town are learned apart. The learned list is reset once: every flight path is grey until you next open a flight master's map. /ggps status lists each flight path on the map with learned yes/no and where that came from",
        ["1.5.1"] = "Map places: learned flight paths are green (unlearned stay grey); flight paths rebuilt from the WoW Forever client's own data - right positions on Mulgore, Eastern Plaguelands, Redridge and Stormwind, separate Alliance and Horde flight masters where a town has both, capitals' flight paths on their zone map too, and the WoW Forever ones (Mount Hyjal, Riverglades); graveyards cross-checked against the vanilla server list (93, with names in the tooltip); the client's own flight path and graveyard lists are merged in when it has them; /ggps status shows per map what each source gave",
        ["1.5.0"] = "Graveyards and flight paths: every spirit healer and flight master of your faction (and the neutral ones) on the world and zone map, also those you have not found; flight paths you have not learned are grey (learned ones are read when you open a flight master's map); /ggps flights on|off, /ggps graves on|off",
        ["1.4.0"] = "Gathering spots: the herbs, ore and chests you gather are remembered; an alert near a known spot you track; /ggps gather (next, hover) points the arrow at the nearest, and the next one on arrival",
        ["1.3.0"] = "Renamed to GaarGpsForever (new folders; settings move over automatically on first login; new /ggps commands, old ones still work)",
        ["1.2.3"] = "the addon's own name in its menu errors",
        ["1.2.2"] = "shared helpers from the GaarForever library",
    },
    GaarFramesForever = {
        ["1.8.0"] = "Test mode entry moved next to Reset positions & scales in the menu",
        ["1.7.0"] = "PvP flag: a faction (or free-for-all) icon beside the portrait of a flagged player, target or party member, and on your own frame the m:ss left while the flag times out (/gff pvp on|off, also in the menu)",
        ["1.6.0"] = "Spell cost on your power bar: while you cast a spell with a cast time, the part of the player frame's power bar (mana, energy, rage ...) the cost will take is drawn bright and gently pulsing with a small -number, red when you do not have enough; gone the moment the cast ends, fails or is interrupted (/gff cost on|off)",
        ["1.5.3"] = "Fix: the HoT preview while casting (Regrowth) found no target for WoW Forever characters with a surname (the cast gives \"First Surname\", the client unit name only the first name); names now match with surname and realm, for you, party and raid",
        ["1.5.2"] = "/gff hotdebug now prints one short line per buff and ends with a compact summary of the HoT cast being made (spell, HoT amount, target and how it was found, which frames draw it and why the yellow or overheal part is or is not shown). New: /gff hotdebug cast arms a trace of your next cast: type it, cast Regrowth, take a screenshot",
        ["1.5.1"] = "Fix: casting a HoT spell (Regrowth) on yourself now shows its HoT preview on your own frame, also with an enemy targeted or the self-cast key held (the preview could land on the enemy instead)",
        ["1.5.0"] = "Overheal: heals past the maximum (incoming heals in red, HoTs in orange-red after them) now hang past the right edge of the health bar on every frame, up to 30% of its width (/gff overheal on|off, /gff overheal cap 0.1-1). HoT while casting: casting Regrowth (or any HoT spell with a cast time) shows its HoT in yellow on the target's frames from the start of the cast, gone on stop or interrupt, handed over to your cast and then the aura without counting twice (/gff hotcast on|off); /gff hotdebug shows the pending cast",
        ["1.4.4"] = "Steadier yellow HoT segment: each HoT keeps its amount (no more flipping between sources), a fallback amount when none is readable, your own HoTs shown in combat, ticks counted from the HoT's schedule and dropped on time, all frames of the same unit redrawn; /gff hotdebug [unit] says per HoT where each number came from and why it adds nothing",
        ["1.3.0"] = "Renamed to GaarFramesForever (new folders; settings move over automatically on first login; new /gff commands, old ones still work)",
        ["1.2.16"] = "the addon's own name in its menu errors",
        ["1.2.15"] = "the addon's own name in its chat lines and menu errors",
        ["1.2.14"] = "secret-safe value checks",
    },
    GaarWindowsForever = {
        ["1.1.0"] = "Renamed to GaarWindowsForever (new folders; settings move over automatically on first login; new /gwf commands, old ones still work)",
        ["1.0.3"] = "the addon's own name in its menu errors",
        ["1.0.2"] = "uses the GaarForever shared library",
    },
    GaarFishingForever = {
        ["1.7.0"] = "test mode: /gfish test or the Test mode menu entry shows the session stats panel with made-up numbers, to place it without fishing",
        ["1.6.0"] = "right-click session stats panel: opens the addon's menu",
        ["1.5.0"] = "Renamed to GaarFishingForever (new folders; settings move over automatically on first login; new /gfish commands, old ones still work)",
        ["1.4.1"] = "the addon's own name in its menu errors",
        ["1.4.0"] = "session stats panel, loud splash mode",
        ["1.3.0"] = "reel in with double right-click, Cast / Reel key",
        ["1.2.2"] = "uses the GaarForever shared library",
    },
    GaarBuffsForever = {
        ["1.11.2"] = "Self-buff strip: a row shows only while its buff is missing or expiring soon (time left in brackets, same window as /gbuff expire); both buffs up hides the strip.",
        ["1.11.1"] = "Detects WoW Forever's 'Camp Benefits' campfire buff (campfire keywords: camp benefit, camp bonus).",
        ["1.11.0"] = "Self buffs, every class: a strip next to the buff box shows your XP food buff and campfire buff with time left (red when missing); click eats an XP food from your bags (largest stack) or casts Basic Campfire, greyed out with no food / without Cooking. Found by keyword; learned IDs in /gbuff status. /gbuff self [on|off], /gbuff self food|fire [on|off]",
        ["1.10.0"] = "Test mode entry in the menu (was Test box); it sits just before Reset position",
        ["1.9.0"] = "right-click buff box background: opens the addon's menu",
        ["1.7.0"] = "Renamed to GaarBuffsForever (new folders; settings move over automatically on first login; new /gbuff commands, old ones still work)",
        ["1.6.0"] = "combat dispel icons, lower rank for low-level members, expiring-soon warning /gbuff expire, out-of-range sound fix",
        ["1.5.1"] = "out-of-range members left out unless /gbuff range on",
        ["1.5.0"] = "Fortitude for priests, Arcane Intellect for mages",
        ["1.4.0"] = "dispel panel for priests, paladins and mages",
        ["1.3.0"] = "Shaman support (imbue, Lightning Shield, reagents, dispel)",
    },
    GaarGroupForever = {
        ["1.6.0"] = "Threat bars at the bottom of the bar, in a party: one bar per member (you included) with the threat % on your target, or on your target's target when you target a friend (the tank), highest first, in class colour, name and %, the member with aggro marked gold with the tank shield. Hidden (and the bar shrinks) solo or with no attackable mob. When the game hides threat in combat the bars still show, unsorted. Option Threat bars, /ggf threat on|off|toggle",
        ["1.4.0"] = "instance info: all vanilla 5-man dungeons with recommended levels vs yours and the party's, boss list ticked as bosses die, notable loot for your class (hover a boss; /ggf info [name] for any dungeon); Info button and Show instance info option",
        ["1.3.0"] = "role modules: Tank (pull marker, lost aggro, healer mana before pull, loose mobs), Healer (Drink/OOM, dispel alert, tank frame, dead/out of range, PvP flag), DPS (assist tank, wrong target, aggro, CC markers, interrupt alert); options in the menu, /ggf tank|healer|dps",
        ["1.1.0"] = "Test mode entry in the menu (shows the bar solo, this session only)",
        ["1.0.0"] = "new: a small party bar (only in a party) with Tank / DPS / Healer role buttons and leader shortcuts for ready check, role check and pull countdown (/ggf)",
    },
    GaarProfessionsForever = {
        ["1.0.0"] = "new: a +/- button beside the profession window's Filter button collapses or expands every recipe category, and the Filter menu gets \"Have Part of Materials\" (recipes where you have at least one of the reagents); /gprof collapse, /gprof partial on|off, /gprof status",
    },
    GaarMerchantForever = {
        ["1.2.0"] = "right-click merchant portrait: opens the addon's menu",
        ["1.1.1"] = "locked items are still skipped when an old BetterBagsForever is installed (reads its locks too)",
        ["1.1.0"] = "Renamed to GaarMerchantForever (new folders; settings move over automatically on first login; new /gmerch commands, old ones still work)",
        ["1.0.3"] = "the addon's own name in its menu errors",
        ["1.0.2"] = "shared helpers from the GaarForever library",
    },
    GaarTooltipsForever = {
        ["1.1.0"] = "Renamed to GaarTooltipsForever (new folders; settings move over automatically on first login; new /gtip commands, old ones still work)",
        ["1.0.4"] = "the addon's own name in its menu errors",
        ["1.0.3"] = "the addon's own name in its chat lines",
    },
    GaarMailForever = {
        ["1.3.0"] = "right-click mailbox portrait: opens the addon's menu",
        ["1.1.0"] = "Renamed to GaarMailForever (new folders; settings move over automatically on first login; new /gmail commands, old ones still work)",
        ["1.0.3"] = "the addon's own name in its chat lines and menu errors",
        ["1.0.2"] = "uses the GaarForever shared library",
    },
    GaarXPForever = {
        ["1.5.0"] = "test mode: /gxp test or the Test mode menu entry shows the XP panel with made-up numbers (also at max level), to place it",
        ["1.4.0"] = "right-click XP panel: opens the addon's menu",
        ["1.2.1"] = "Ready quests: the XP is now read through several fallbacks (it was always 0 on WoW Forever); /gxp ready debug shows the source per quest",
        ["1.2.0"] = "Ready quests: the XP panel shows complete-but-not-turned-in quests with their XP, and time to level / kills count them (/gxp ready)",
        ["1.1.0"] = "Renamed to GaarXPForever (new folders; settings move over automatically on first login; new /gxp commands, old ones still work)",
        ["1.0.4"] = "the addon's own name in its menu errors",
        ["1.0.3"] = "the addon's own name in its chat lines",
    },
    GaarChatForever = {
        ["1.7.0"] = "autoGroupChannel: the chat box switches to Party/Raid when you join a group and back to your old channel when you leave (/gchat autogroupchannel on|off)",
        ["1.6.0"] = "Test: print sample chat lines is the last menu entry; /gchat test unchanged",
        ["1.5.0"] = "/gchat test and a Show test lines (chat) button: sample chat lines in the main chat frame that show the tweaks, for a screenshot",
        ["1.4.0"] = "right-click chat feed window: opens the addon's menu",
        ["1.2.2"] = "your own messages are recognised for characters with a surname",
        ["1.1.0"] = "Renamed to GaarChatForever (new folders; settings move over automatically on first login; new /gchat commands, old ones still work)",
        ["1.0.4"] = "the addon's own name in its menu errors",
        ["1.0.3"] = "the addon's own name in its chat lines",
    },
    GaarBarsForever = {
        ["1.6.1"] = "Spellbook: the flyout editor's button next to Missing from bars is now a tab exactly like it (same size, frame and highlight). While Missing from bars is open, only its tab looks selected: Blizzard's selected tab is covered by a plain-looking copy of itself (click it to go back), and everything is as before once you pick a Blizzard tab. A spell that is on your bars through a flyout or a macro no longer gets Blizzard's pulsing not-on-your-action-bars glow. New /gbars bookframe on|off (default off): the orange frames on spellbook icons that are not about missing spells - the low-rank ring on the book's own entries (the ring on the bar buttons stays) and Blizzard's rotation helper frame - are hidden unless it is on; a /gbars status line shows it",
        ["1.6.0"] = "Flyouts v2. A flyout is now its own object (a name, an icon, up to 12 entries) carried on the bars by its own character macro, GF <name> (an account macro when those are full; a chat line when both are). Any button holding that macro opens the flyout, wherever you move it; a plain spell on another button is a normal button. New flyout editor (/gbars flyouts, or the small button next to Missing from bars in the spellbook): list, New, Delete (asks first, deletes the macro too), rename, icon picker or entry 1's icon, entries with up/down/remove, a drop zone to add, and a drag handle to put the macro on any bar button (on N buttons). Pressing the button's key again while its flyout is open casts entry 1 and closes it (/gbars flyout samekey on|off, default on). The + still works: on a flyout button it adds, on any other button it makes a new flyout of the button's action and the dropped one and puts its macro there. A flyout is no longer removed when it drops to one entry. Your 1.5 flyouts are converted once, out of combat (bar buttons, paged form bars included, get the new macro; the old data is kept as a backup); /gbars status shows the result",
        ["1.5.2"] = "Right-click on a button with a flyout now casts the flyout's first entry without opening it: it did nothing before. Works in and out of combat and follows the main bar's page (stances, forms, stealth); an item you have none of does nothing. Left click and the button's key still open the flyout. /gbars status has a line: right-click: entry 1 set on N of M shown overlays",
        ["1.5.1"] = "Missing from bars no longer lists spells (or macros that cast them) that sit in a flyout on a bar button; a lower rank in a flyout is listed as lower rank; the list updates when flyouts change. Right-click a button with a flyout to cast its first entry without opening it (works in combat; an item you have none of does nothing)",
        ["1.5.0"] = "Flyouts: while the cursor holds a spell, item or macro, a + sits on every bar button with an action; drop on it to add it to that button's flyout (up to 12, the button's own action first). Click the button or press its key to open, then 1-9, 0, -, = or a click casts; Escape, the button again or a click elsewhere closes. Works in combat. Right-click or drag an entry out to remove it (out of combat). Saved per character, follows its ability to another button; an arrow marks the button; /gbars flyout on|off and /gbars flyout dir up|down|left|right, an options toggle, a /gbars status line; stays off while FallensFlyouts is loaded",
        ["1.4.1"] = "Missing from bars is a square icon tab in the spellbook's bottom-left corner (Forever's tab look, book icon with a green arrow, a count of the entries, glows while open; click again to go back); the category tabs no longer vanish while the list is open; What's Training?'s ? tab closes the list and opening the list closes its page",
        ["1.4.0"] = "Spellbook tab Missing from bars, left of General: one list of your known, castable, non-passive spells that are on no bar (Not on your bars) or only at a lower rank (Bar has Rank 2 · Rank 3 known), in the spellbook's own look with paging; hover for the tooltip, drag to a bar, click to cast; /gbars missing on|off, menu entry, /gbars status line",
        ["1.1.0"] = "Renamed to GaarBarsForever (new folders; settings move over automatically on first login; new /gbars commands, old ones still work)",
        ["1.0.4"] = "the addon's own name in its menu errors",
        ["1.0.3"] = "the addon's own name in its chat lines",
    },
    GaarLootForever = {
        ["1.4.0"] = "the preview button is named Test: show a preview and sits before the reset button; /glf test unchanged",
        ["1.3.0"] = "right-click recent-rolls panel: opens the addon's menu",
        ["1.2.3"] = "your own rolls are counted under your full name, so characters with a surname are no longer split in two",
        ["1.2.0"] = "Renamed to GaarLootForever (new folders; settings move over automatically on first login; new /glf commands, old ones still work)",
        ["1.1.0"] = "roll result summary panel",
        ["1.0.0"] = "Need / Greed / Pass counts on group loot rolls",
    },
}
Tools.CHANGES = CHANGES

-- ---------------------------------------------------------------------------
-- Saved variables (Core.lua's BindSavedVariables calls Bind with its table)
-- ---------------------------------------------------------------------------

local MAX_SAVED_TEXT = 30000

function Tools.Bind(h)
    hub = h
    local db = h.db
    if type(db.news) ~= "boolean" then db.news = true end
    if type(db.seen) ~= "table" then db.seen = {} end
    -- Versions seen before the folder rename are keyed by the old folder names (BetterBagsForever):
    -- moved to the new ones, so the update is announced once rather than every addon as "new".
    local renamed = {}
    for k, v in pairs(db.seen) do
        if type(k) == "string" and k:match("^Better%w*Forever$") then renamed[k] = v end
    end
    for k, v in pairs(renamed) do
        local new = Lib.DisplayName(k)
        if db.seen[new] == nil then db.seen[new] = v end
        db.seen[k] = nil
    end
    for k, v in pairs(db.seen) do
        if type(k) ~= "string" or type(v) ~= "string" then db.seen[k] = nil end
    end
    if type(db.lastNews) ~= "table" then db.lastNews = {} end
    for i = #db.lastNews, 1, -1 do
        if type(db.lastNews[i]) ~= "string" then table.remove(db.lastNews, i) end
    end
    if db.selftest ~= nil and (type(db.selftest) ~= "string" or #db.selftest > MAX_SAVED_TEXT) then db.selftest = nil end
end

-- The keys Tools keeps in GaarForeverDB (Core.lua drops every other key except minimap).
Tools.DB_KEYS = { news = true, seen = true, lastNews = true, selftest = true }

-- ---------------------------------------------------------------------------
-- Text window: a movable frame with a multi-line edit box, for copy (export, self-test) and
-- paste (import).
-- ---------------------------------------------------------------------------

local popup

local function TryFrame(kind, name, parent, template)
    local ok, f = pcall(_G.CreateFrame, kind, name, parent, template)
    if ok and f then return f end
    ok, f = pcall(_G.CreateFrame, kind, name, parent)
    if ok then return f end
end

local function BuildPopup()
    if popup then return popup end
    local f = TryFrame("Frame", "GaarForeverTextWindow", _G.UIParent, "BackdropTemplate")
    if not f then return nil end
    f:SetSize(580, 380)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if type(f.SetBackdrop) == "function" then
        local FLAT = "Interface\\Buttons\\WHITE8x8"
        f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        f:SetBackdropColor(0.07, 0.08, 0.10, 0.97)
        f:SetBackdropBorderColor(0.35, 0.37, 0.42, 1)
    end
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -10)
    f.title:SetPoint("RIGHT", f, "RIGHT", -36, 0)
    f.title:SetJustifyH("LEFT")
    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hint:SetPoint("BOTTOMLEFT", 12, 14)
    f.hint:SetPoint("RIGHT", f, "RIGHT", -130, 0)
    f.hint:SetJustifyH("LEFT")

    local close = TryFrame("Button", nil, f, "UIPanelCloseButton")
    if close then
        close:SetPoint("TOPRIGHT", -2, -2)
        close:SetScript("OnClick", function() f:Hide() end)
    end

    local scroll = TryFrame("ScrollFrame", "GaarForeverTextWindowScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -32)
    scroll:SetPoint("BOTTOMRIGHT", -32, 40)
    local edit = TryFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(_G.ChatFontNormal or _G.GameFontHighlightSmall)
    edit:SetWidth(530)
    if type(edit.SetMaxLetters) == "function" then edit:SetMaxLetters(0) end
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    -- Read-only while it shows something to copy: typing puts the text back.
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput and f.readOnly and self:GetText() ~= f.text then
            self:SetText(f.text)
            self:HighlightText()
        end
    end)
    scroll:SetScrollChild(edit)
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
    f.edit = edit

    local action = TryFrame("Button", nil, f, "UIPanelButtonTemplate")
    if action then
        action:SetSize(110, 22)
        action:SetPoint("BOTTOMRIGHT", -12, 10)
        action:SetScript("OnClick", function()
            if type(f.onAction) == "function" then
                local ok, err = pcall(f.onAction, edit:GetText())
                if not ok then Print("error: " .. tostring(err)) end
            else
                f:Hide()
            end
        end)
        f.action = action
    end
    f:Hide()
    if type(_G.UISpecialFrames) == "table" then table.insert(_G.UISpecialFrames, "GaarForeverTextWindow") end
    popup = f
    return f
end

-- Shows text to copy (onAction nil: the button closes) or an empty box to paste into (text nil,
-- onAction(text) runs on the button). Returns false where no window could be made.
function Tools.ShowText(title, text, hint, actionLabel, onAction)
    local ok, f = pcall(BuildPopup)
    if not ok or not f then return false end
    f.title:SetText(title or "GaarForever")
    f.hint:SetText(hint or "")
    f.readOnly = text ~= nil
    f.text = text or ""
    f.onAction = onAction
    if f.action then f.action:SetText(actionLabel or "Close") end
    f.edit:SetText(f.text)
    f:Show()
    f.edit:SetFocus()
    if f.readOnly then f.edit:HighlightText() end
    return true
end

function Tools.HideText()
    if popup then popup:Hide() end
end

-- ---------------------------------------------------------------------------
-- What's new
-- ---------------------------------------------------------------------------

-- The parts of "1.10.2" as numbers; a part that is not a number compares as text.
local function Parts(v)
    local list = {}
    for p in tostring(v):gmatch("[^%.%-]+") do list[#list + 1] = tonumber(p) or p end
    return list
end

-- true when version a is newer than b.
local function Newer(a, b)
    local pa, pb = Parts(a), Parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
        if x ~= y then return x > y end
    end
    return false
end
Tools.Newer = Newer

local function Metadata(name)
    local f = Lib.API("C_AddOns", "GetAddOnMetadata") or Lib.API("GetAddOnMetadata")
    return Str(Lib.Call(f, name, "Version"))
end

-- An installed addon's version: its API table's, else its TOC's (an addon that is loaded but
-- has no API yet). nil when it is not loaded.
local function VersionOf(a)
    local api = hub.API(a)
    if api then
        local v = Str(api.version)
        if v then return v end
    end
    if Lib.AddOnLoaded(a.name) then return Metadata(a.name) end
    return nil
end

local function Note(name, version)
    local list = CHANGES[name]
    return list and list[version] or nil
end

local function NewsLine(name, old, new)
    local note = Note(name, new)
    local text
    if old then
        text = "updated " .. EM_DASH .. " " .. Lib.DisplayName(name) .. " " .. old .. ARROW .. new
    else
        text = "new " .. EM_DASH .. " " .. Lib.DisplayName(name) .. " " .. new
    end
    if note then text = text .. ": " .. note end
    return text
end

-- Compares every installed addon (and the hub) with the versions seen last, records the new
-- ones and returns the lines (an empty list when nothing changed). Printing is left to the caller.
function Tools.CheckNews()
    local db = hub.db
    local seen = db.seen
    local firstRun = next(seen) == nil
    local lines = {}
    local list = { { name = "GaarForever", version = hub.VERSION } }
    for _, a in ipairs(hub.ADDONS) do
        local v = VersionOf(a)
        if v then list[#list + 1] = { name = a.name, version = v } end
    end
    for _, it in ipairs(list) do
        local old = seen[it.name]
        if not firstRun then
            if old == nil then
                lines[#lines + 1] = NewsLine(it.name, nil, it.version)
            elseif Newer(it.version, old) then
                lines[#lines + 1] = NewsLine(it.name, old, it.version)
            end
        end
        seen[it.name] = it.version
    end
    if #lines > 0 then db.lastNews = lines end
    return lines
end

-- At login: the check, and the lines in chat while the switch is on.
function Tools.LoginNews()
    local lines = Tools.CheckNews()
    if hub.db.news then
        for _, l in ipairs(lines) do Print(l) end
    end
end

function Tools.NewsCommand(rest)
    local db = hub.db
    if rest == "on" or rest == "off" then
        db.news = rest == "on"
        Print("what's new at login: " .. Lib.OnOff(db.news))
        return
    end
    if #db.lastNews == 0 then
        Print("nothing new recorded yet. What's new at login is " .. Lib.OnOff(db.news) .. " (/gf news on|off).")
        return
    end
    for _, l in ipairs(db.lastNews) do Print(l) end
end

-- ---------------------------------------------------------------------------
-- Profiles, export and import (addons built on the library's A:InitDB)
-- ---------------------------------------------------------------------------

-- The library addon objects with settings bound, in the hub's menu order.
local function ProfileAddons()
    local out = {}
    for _, a in ipairs(hub.ADDONS) do
        local obj = Lib.addons and Lib.addons[a.name]
        if type(obj) == "table" and obj.dbShared then out[#out + 1] = obj end
    end
    return out
end
Tools.ProfileAddons = ProfileAddons

-- The hub row for a word: key, label, name or slash command.
local function FindRow(word)
    word = tostring(word or ""):lower()
    for _, a in ipairs(hub.ADDONS) do
        if a.key == word or a.label:lower() == word or a.name:lower() == word or a.title:lower() == word
            or a.slash == "/" .. word or a.oldSlash == "/" .. word
            or (a.oldName and a.oldName:lower() == word) then return a end
    end
end

-- The library addon for a word, or nil, why.
local function FindLibAddon(word)
    local a = FindRow(word)
    if not a then return nil, "unknown addon: " .. tostring(word) end
    local obj = Lib.addons and Lib.addons[a.name]
    if type(obj) ~= "table" or not obj.dbShared then
        if Lib.AddOnLoaded(a.name) then
            return nil, a.title .. " keeps its own settings table, not the library's - profiles and export cover only: "
                .. Tools.CoveredText()
        end
        return nil, a.title .. " is not loaded"
    end
    return obj
end

function Tools.CoveredText()
    local names = {}
    for _, obj in ipairs(ProfileAddons()) do names[#names + 1] = obj.title end
    return #names > 0 and table.concat(names, ", ") or "none loaded"
end

local function ModeText(obj)
    return obj:ProfileMode() == "character" and "this character's own settings" or "shared (account-wide)"
end

function Tools.ProfileCommand(rest)
    local mode, word = rest:match("^(%S+)%s*(.-)$")
    if not mode or mode == "" then
        local list = ProfileAddons()
        if #list == 0 then
            Print("no loaded addon keeps its settings through the library, so there is nothing to switch.")
        end
        for _, obj in ipairs(list) do Print(obj.title .. ": " .. ModeText(obj)) end
        Print("/gf profile char <addon|all> - this character gets its own copy (from the shared settings);"
            .. " /gf profile shared <addon|all> - back to the shared settings (the copy is dropped).")
        return
    end
    local target
    if mode == "char" or mode == "character" then target = "character"
    elseif mode == "shared" or mode == "account" then target = "shared"
    else
        Print("/gf profile [char|shared] <addon|all>")
        return
    end
    local list
    if word == "" or word == "all" then
        list = ProfileAddons()
        if #list == 0 then
            Print("no loaded addon keeps its settings through the library.")
            return
        end
    else
        local obj, why = FindLibAddon(word)
        if not obj then
            Print(why)
            return
        end
        list = { obj }
    end
    for _, obj in ipairs(list) do
        local ok, msg = obj:SetProfileMode(target)
        if ok then
            Print(obj.title .. ": " .. ModeText(obj))
        else
            Print(obj.title .. ": " .. tostring(msg))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Export / import of whole saved variables (3.2.1): /gf export all | <addon>, /gf import.
--
-- Every family addon's saved variables (hub.ADDONS rows: db, and charDb for the per-character
-- one), plus the hub's own, as one string:
--   GaarForever.EncodeBundle({ format = "GaarForever settings", v = 1, hub = <version>,
--       from = "Name - Realm", addons = { [folder] = { version = <v>, account = {...}, char = {...} } } })
-- Import parses it by hand (never as code), shows which addons and parts it holds and from which
-- character, asks, then overwrites the included saved variables in place (wiped, then a deep copy)
-- and offers a reload. The per-character part goes to the character importing it. Keys in
-- keep[...] are local data, not settings: left out of an export and left alone by an import.
-- Old single-addon strings (BF1:..., from 3.1's /gf export) are still taken.
-- ---------------------------------------------------------------------------

local BUNDLE_FORMAT, BUNDLE_V = "GaarForever settings", 1
local MAX_BUNDLE_ADDONS = 64

-- The hub's own saved variable: only the minimap button and the news switch are settings.
local HUB_SET = { name = "GaarForever", title = "GaarForever", db = "GaarForeverDB",
    keep = { account = { seen = true, lastNews = true, selftest = true } } }

-- Every set of saved variables the hub knows, hub first, then the menu order.
local function SavedSets()
    local list = { HUB_SET }
    for _, a in ipairs(hub.ADDONS) do
        if a.db then list[#list + 1] = a end
    end
    return list
end
Tools.SavedSets = SavedSets

local function SetLoaded(set)
    if set == HUB_SET then return true end
    return Lib.AddOnLoaded(set.name)
end

-- A copy of a saved variable without its keep keys; nil when it is not a table.
local function Part(set, which, globalName)
    local t = globalName and _G[globalName]
    if type(t) ~= "table" then return nil end
    local keep = set.keep and set.keep[which] or {}
    local c = {}
    for k, v in pairs(t) do
        if not keep[k] then c[k] = Lib.DeepCopy(v) end
    end
    return c
end

local function SetVersion(set)
    if set == HUB_SET then return hub.VERSION end
    return VersionOf(set)
end

-- The row for a word: "hub" / "gf" / "gaarforever" for the hub itself, else FindRow.
local function FindSet(word)
    word = tostring(word or ""):lower()
    if word == "hub" or word == "gf" or word == "gaarforever" or word == "betterforever" then return HUB_SET end
    local a = FindRow(word)
    if a and a.db then return a end
end

local function ExportText(sets)
    local payload = { format = BUNDLE_FORMAT, v = BUNDLE_V, hub = hub.VERSION, from = Lib.CharKey() or "?", addons = {} }
    local names = {}
    for _, set in ipairs(sets) do
        local entry = { version = SetVersion(set), account = Part(set, "account", set.db),
            char = set.charDb and Part(set, "char", set.charDb) or nil }
        if entry.account or entry.char then
            payload.addons[set.name] = entry
            names[#names + 1] = set.title
        end
    end
    if #names == 0 then return nil, "no settings to export (nothing loaded yet)" end
    local text, err = Lib.EncodeBundle(payload)
    if not text then return nil, err end
    return text, names
end

function Tools.ExportCommand(word)
    if word == "" then
        local names = { "all" }
        for _, set in ipairs(SavedSets()) do
            if SetLoaded(set) then names[#names + 1] = set == HUB_SET and "hub" or set.key end
        end
        Print("/gf export all - every installed Gaar...Forever addon's settings as one string;"
            .. " /gf export <addon> - one of them: " .. table.concat(names, ", ") .. ". Paste it with /gf import.")
        return
    end
    local sets
    if word == "all" then
        sets = {}
        for _, set in ipairs(SavedSets()) do
            if SetLoaded(set) then sets[#sets + 1] = set end
        end
    else
        local set = FindSet(word)
        if not set then return Print("unknown addon: " .. tostring(word) .. " (/gf export lists them)") end
        if not SetLoaded(set) then return Print(set.title .. " is not loaded.") end
        sets = { set }
    end
    local text, names = ExportText(sets)
    if not text then return Print("export failed: " .. tostring(names)) end
    local title = (word == "all" and "All settings" or (sets[1].title .. " settings")) .. " (" .. #names
        .. " addon" .. (#names == 1 and "" or "s") .. ", " .. #text .. " characters)"
    local shown = Tools.ShowText(title, text, "Ctrl+A, Ctrl+C to copy. Paste it with /gf import on any character.")
    if not shown then Print("no text window on this client.") end
end

-- The import as plain data: { from, hub, list = { { set, version, account, char } }, skipped = {...} }
-- or nil, why. Only tables are taken as parts; names are matched against the known sets (an old
-- Better... name too); anything else is listed as skipped.
local function ReadBundle(t)
    if type(t) ~= "table" or t.format ~= BUNDLE_FORMAT then return nil, "not a GaarForever settings export" end
    if type(t.v) ~= "number" or t.v > BUNDLE_V then return nil, "made by a newer GaarForever (format " .. tostring(t.v) .. "); update first" end
    if type(t.addons) ~= "table" then return nil, "no addons in it" end
    local byName = {}
    for _, set in ipairs(SavedSets()) do
        byName[set.name] = set
        if set.oldName then byName[set.oldName] = set end
    end
    byName.BetterForever = HUB_SET
    local out = { from = type(t.from) == "string" and t.from or "?", hub = type(t.hub) == "string" and t.hub or "?",
        list = {}, skipped = {} }
    local n = 0
    for name, entry in pairs(t.addons) do
        n = n + 1
        if n > MAX_BUNDLE_ADDONS then return nil, "too many entries" end
        local set = type(name) == "string" and byName[name]
        if not set or type(entry) ~= "table" then
            out.skipped[#out.skipped + 1] = tostring(name) .. " (unknown here)"
        elseif not SetLoaded(set) then
            out.skipped[#out.skipped + 1] = set.title .. " (not installed or not enabled here)"
        else
            local account = type(entry.account) == "table" and entry.account or nil
            local char = set.charDb and type(entry.char) == "table" and entry.char or nil
            if account or char then
                out.list[#out.list + 1] = { set = set, version = type(entry.version) == "string" and entry.version or "?",
                    account = account, char = char }
            end
        end
    end
    table.sort(out.list, function(a, b) return a.set.title < b.set.title end)
    table.sort(out.skipped)
    if #out.list == 0 then return nil, "nothing in it for the addons installed here" .. (#out.skipped > 0
        and (" (skipped: " .. table.concat(out.skipped, ", ") .. ")") or "") end
    return out
end
Tools.ReadBundle = ReadBundle

local function SummaryText(b)
    local lines = { "From " .. b.from .. " (GaarForever " .. b.hub .. "), to " .. (Lib.CharKey() or "this character") .. ":", "" }
    for _, it in ipairs(b.list) do
        local parts = {}
        if it.account then parts[#parts + 1] = "account-wide settings" end
        if it.char then parts[#parts + 1] = "this character's settings" end
        lines[#lines + 1] = "  " .. it.set.title .. " " .. it.version .. ": " .. table.concat(parts, " + ")
    end
    if #b.skipped > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Left out: " .. table.concat(b.skipped, ", ")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Apply overwrites these settings (the others stay as they are), then offers a reload."
    return table.concat(lines, "\n")
end

-- Overwrites one saved variable in place: wiped (keep keys stay), then filled with a deep copy.
local function Overwrite(set, which, globalName, data)
    local t = _G[globalName]
    if type(t) ~= "table" then
        t = {}
        _G[globalName] = t
    end
    local keep = set.keep and set.keep[which] or {}
    for k in pairs(t) do
        if not keep[k] then t[k] = nil end
    end
    for k, v in pairs(data) do
        if not keep[k] then t[k] = Lib.DeepCopy(v) end
    end
end

local function ApplyBundle(b)
    local done = {}
    for _, it in ipairs(b.list) do
        local ok, err = pcall(function()
            if it.account then Overwrite(it.set, "account", it.set.db, it.account) end
            if it.char then Overwrite(it.set, "char", it.set.charDb, it.char) end
        end)
        if ok then
            done[#done + 1] = it.set.title
        else
            Print(it.set.title .. ": import failed - " .. tostring(err))
        end
    end
    return done
end
Tools.ApplyBundle = ApplyBundle

local function OfferReload(done)
    local text = "Imported: " .. table.concat(done, ", ") .. ".\n\nThe addons pick the settings up after a reload"
        .. " (until then they may still show, and save, what they had)."
    Print("imported the settings of " .. #done .. " addon(s); reload the UI (/reload) to use them.")
    local reload = Lib.API("C_UI", "Reload") or Lib.API("ReloadUI")
    Tools.ShowText("Settings imported", text, "Reload now, or later with /reload.", "Reload UI", function()
        if reload then reload() else Tools.HideText() end
    end)
end

local CONFIRM = "GAARFOREVER_IMPORT_ALL"

local function Confirm(b)
    local function Go()
        local done = ApplyBundle(b)
        if #done > 0 then OfferReload(done) else Tools.HideText() end
    end
    local dialogs, show = _G.StaticPopupDialogs, _G.StaticPopup_Show
    if type(dialogs) ~= "table" or type(show) ~= "function" then return Go() end
    dialogs[CONFIRM] = {
        text = "GaarForever: overwrite the settings of %s addon(s) with the imported ones? This cannot be undone.",
        button1 = _G.ACCEPT or "Accept",
        button2 = _G.CANCEL or "Cancel",
        OnAccept = function()
            local ok, err = pcall(Go)
            if not ok then Print("import failed: " .. tostring(err)) end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    if not pcall(show, CONFIRM, tostring(#b.list)) then Go() end
end

-- From the paste box: an export of whole saved variables (GFA1:), or an old one-addon string (BF1:).
local function DoImport(text)
    text = type(text) == "string" and text or ""
    if text:match("^%s*BF1:") then
        local name, t = Lib.DecodeSettings(text)
        if not name then return Print("import failed: " .. tostring(t)) end
        local obj, why = FindLibAddon(Lib.DisplayName(name))
        if not obj then return Print("import failed: " .. tostring(why)) end
        local applied, ignored = obj:ImportSettings(t)
        Print(string.format("imported %d setting(s) into %s (%s)%s.", applied, obj.title, ModeText(obj),
            ignored > 0 and (", " .. ignored .. " unknown or invalid left out") or ""))
        return Tools.HideText()
    end
    local t, err = Lib.DecodeBundle(text)
    if not t then return Print("import failed: " .. tostring(err)) end
    local b, why = ReadBundle(t)
    if not b then return Print("import failed: " .. tostring(why)) end
    Tools.ShowText("Import " .. #b.list .. " addon(s)' settings?", SummaryText(b),
        "Check the list, then Apply (you are asked once more).", "Apply", function() Confirm(b) end)
end
Tools.DoImport = DoImport

function Tools.ImportCommand()
    local shown = Tools.ShowText("Import settings", nil,
        "Paste a /gf export string (Ctrl+V), then Import. Nothing in it is run as code.", "Import", DoImport)
    if not shown then Print("no text window on this client.") end
end

-- ---------------------------------------------------------------------------
-- Self-test
-- ---------------------------------------------------------------------------

local UNITS = { "player", "target", "party1" }

-- A spell the player's class has from early on, for the range calls (Auto Attack otherwise).
local RANGE_SPELL = {
    DRUID = 1126, PALADIN = 19740, PRIEST = 1243, MAGE = 1459, SHAMAN = 331, WARLOCK = 5697,
    HUNTER = 75, ROGUE = 1752, WARRIOR = 772,
}

local function RangeSpell()
    local class = Str(select(2, Lib.Call(_G.UnitClass, "player")))
    return RANGE_SPELL[class or ""] or 6603
end

local function ColorCurve()
    local CU, E, CC = _G.C_CurveUtil, _G.Enum, _G.CreateColor
    if type(CU) ~= "table" or type(CU.CreateColorCurve) ~= "function" or type(CC) ~= "function" then return nil end
    local c = CU.CreateColorCurve()
    if type(E) == "table" and type(E.LuaCurveType) == "table" and E.LuaCurveType.Step ~= nil then
        c:SetType(E.LuaCurveType.Step)
    end
    for x = 0, 5 do c:AddPoint(x, CC(1, 1, 1, 1)) end
    return c
end

-- The first aura's instance ID on a unit (plain number), or nil.
local function FirstAuraID(unit)
    local f = Lib.API("C_UnitAuras", "GetAuraDataByIndex")
    for _, filter in ipairs({ "HARMFUL", "HELPFUL" }) do
        local d = Lib.Call(f, unit, 1, filter)
        if type(d) == "table" and not IsSecret(d) then
            local id = Num(d.auraInstanceID)
            if id then return id end
        end
    end
end

local SKIP = {} -- a probe returns SKIP, why when it could not be asked

local function Need(space, name)
    local f = Lib.API(space, name)
    if not f then error("missing", 0) end
    return f
end

-- { id, unit = true when it is asked per unit, call(unit) }
local PROBES = {
    { id = "issecretvalue", call = function() return Need("issecretvalue") and "function" end },
    { id = "C_UnitAuras.GetAuraDataByIndex", unit = true,
        call = function(u) return Need("C_UnitAuras", "GetAuraDataByIndex")(u, 1, "HELPFUL") end },
    { id = "C_UnitAuras.GetUnitAuraInstanceIDs", unit = true,
        call = function(u) return Need("C_UnitAuras", "GetUnitAuraInstanceIDs")(u, "HARMFUL", 2) end },
    { id = "C_UnitAuras.GetAuraDispelTypeColor", unit = true,
        call = function(u)
            local f = Need("C_UnitAuras", "GetAuraDispelTypeColor")
            local id = FirstAuraID(u)
            if not id then return SKIP, "no aura" end
            local crv = ColorCurve()
            if not crv then return SKIP, "no colour curve" end
            return f(u, id, crv)
        end },
    { id = "UnitAura", unit = true, call = function(u) return Need("UnitAura")(u, 1, "HELPFUL") end },
    { id = "UnitHealth", unit = true, call = function(u) return Need("UnitHealth")(u) end },
    { id = "UnitHealth predicted", unit = true, call = function(u) return Need("UnitHealth")(u, true) end },
    { id = "UnitHealthMax", unit = true, call = function(u) return Need("UnitHealthMax")(u) end },
    { id = "UnitGetIncomingHeals", unit = true, call = function(u) return Need("UnitGetIncomingHeals")(u) end },
    { id = "UnitThreatSituation", unit = true,
        call = function(u) return Need("UnitThreatSituation")("player", u) end },
    { id = "UnitDetailedThreatSituation", unit = true,
        call = function(u) return Need("UnitDetailedThreatSituation")("player", u) end },
    { id = "GetRaidTargetIndex", unit = true, call = function(u) return Need("GetRaidTargetIndex")(u) end },
    { id = "C_Spell.IsSpellInRange", unit = true,
        call = function(u) return Need("C_Spell", "IsSpellInRange")(RangeSpell(), u) end },
    { id = "IsSpellInRange", unit = true,
        call = function(u)
            local f = Need("IsSpellInRange")
            local info = Lib.API("C_Spell", "GetSpellName") or Lib.API("GetSpellInfo")
            local name = Str(Lib.Call(info, RangeSpell()))
            if not name then return SKIP, "no spell name" end
            return f(name, u)
        end },
    { id = "UnitInRange", unit = true, call = function(u) return Need("UnitInRange")(u) end },
    { id = "UnitIsConnected", unit = true, call = function(u) return Need("UnitIsConnected")(u) end },
    { id = "GetWeaponEnchantInfo", call = function() return Need("GetWeaponEnchantInfo")() end },
    { id = "C_LootHistory", call = function()
        local t = _G.C_LootHistory
        if type(t) ~= "table" then error("missing", 0) end
        local have = {}
        for _, n in ipairs({ "GetSortedInfoForDrop", "GetSortedDropsForEncounter", "GetInfoForEncounter",
            "GetNumItems", "GetItem", "GetPlayerInfo" }) do
            if type(t[n]) == "function" then have[#have + 1] = n end
        end
        return #have > 0 and table.concat(have, ",") or "no functions"
    end },
    { id = "GetBindingKey INTERACTTARGET", call = function() return Need("GetBindingKey")("INTERACTTARGET") end },
    { id = "CVar SoftTargetInteract", call = function()
        local f = Lib.API("C_CVar", "GetCVar") or Need("GetCVar")
        return f("SoftTargetInteract")
    end },
    { id = "CustomAuraContainerTemplate", call = function()
        local info = Lib.API("C_XMLUtil", "GetTemplateInfo")
        if info then
            local t = info("CustomAuraContainerTemplate")
            if t == nil then return nil end
            return "template"
        end
        local f = Need("CreateFrame")("AuraContainer", nil, _G.UIParent, "CustomAuraContainerTemplate")
        if f and type(f.Hide) == "function" then f:Hide() end
        return f and "frame made"
    end },
    { id = "CustomAuraContainerGroupDefaultOptions",
        call = function() return type(_G.CustomAuraContainerGroupDefaultOptions) == "table" and "table" or nil end },
}
Tools.PROBES = PROBES

local function Short(v)
    local s = tostring(v)
    if #s > 24 then s = s:sub(1, 22) .. ".." end
    return s
end

-- One result word from a pcall: "error: ...", "secret", "nil", "skip (why)" or "ok (...)".
local function Classify(ok, ...)
    local n = select("#", ...)
    local first = ...
    if not ok then
        if IsSecret(first) then return "error (secret message)" end
        -- Without the "file.lua:12: " prefixes, so the reason fits on the line.
        local msg = tostring(first)
        for _ = 1, 3 do msg = msg:gsub("^[^%s]-%.lua:%d+: ", "") end
        if msg == "missing" then return "missing" end
        if #msg > 50 then msg = msg:sub(1, 48) .. ".." end
        return "error: " .. msg
    end
    -- A secret is checked before anything compares it.
    if IsSecret(first) then return "secret" end
    if first == SKIP then return "skip (" .. tostring(select(2, ...)) .. ")" end
    local otherSecret = 0
    for i = 2, n do
        if IsSecret((select(i, ...))) then otherSecret = otherSecret + 1 end
    end
    local extra = otherSecret > 0 and (", " .. otherSecret .. " more secret") or ""
    if first == nil then
        return (otherSecret > 0 and "nil" .. extra) or "nil"
    end
    if type(first) == "table" then
        local secret, count = 0, 0
        for _, v in pairs(first) do
            count = count + 1
            if IsSecret(v) then secret = secret + 1 end
        end
        if secret > 0 then return "secret fields (" .. secret .. "/" .. count .. ")" .. extra end
        return "ok (table " .. count .. ")" .. extra
    end
    return "ok (" .. Short(first) .. ")" .. extra
end
Tools.Classify = Classify

-- The kind of a result for the summary: ok, nil, secret, error, skip.
local function Kind(r)
    if r:match("^secret") then return "secret" end
    return r:match("^(%a+)") or "?"
end

-- One run: { label, at, rows = { { id, unit, result } } }
local function RunProbes(label)
    local run = { label = label, at = Lib.Call(_G.date, "%H:%M:%S") or "?", rows = {} }
    for _, p in ipairs(PROBES) do
        local units = p.unit and UNITS or { "" }
        for _, u in ipairs(units) do
            run.rows[#run.rows + 1] = { id = p.id, unit = u, result = Classify(pcall(p.call, u)) }
        end
    end
    return run
end
Tools.RunProbes = RunProbes

local function Summary(run)
    local counts, order = {}, { "ok", "nil", "secret", "skip", "missing", "error" }
    for _, r in ipairs(run.rows) do
        local k = Kind(r.result)
        counts[k] = (counts[k] or 0) + 1
    end
    local parts = {}
    for _, k in ipairs(order) do
        if counts[k] then parts[#parts + 1] = counts[k] .. " " .. k end
    end
    return table.concat(parts, ", ")
end

local runs = { out = nil, ["in"] = nil }
local selftestFrame

local function Header()
    local build = { Lib.Call(_G.GetBuildInfo) }
    local class = Str(select(2, Lib.Call(_G.UnitClass, "player"))) or "?"
    local level = Num(Lib.Call(_G.UnitLevel, "player"))
    return string.format("GaarForever %s self-test (library %s) - client %s (%s, interface %s) - %s %s - %s",
        tostring(hub.VERSION), tostring(Lib.version), tostring(build[1] or "?"), tostring(build[2] or "?"),
        tostring(build[4] or "?"), class, tostring(level or "?"), tostring(Lib.Call(_G.date, "%Y-%m-%d") or "?"))
end

-- The full text: one line per probe and unit, out of combat | in combat.
function Tools.SelfTestText()
    local out, inn = runs.out, runs["in"]
    local lines = { Header(), "range spell: " .. tostring(RangeSpell()) }
    lines[#lines + 1] = "out of combat: " .. (out and (out.at .. " - " .. Summary(out)) or "not run yet")
    lines[#lines + 1] = "in combat:     " .. (inn and (inn.at .. " - " .. Summary(inn)) or "not run yet (runs at the next pull)")
    lines[#lines + 1] = ""
    local base = out or inn
    if not base then return table.concat(lines, "\n") end
    for i, r in ipairs(base.rows) do
        local o = out and out.rows[i] and out.rows[i].result or "-"
        local n = inn and inn.rows[i] and inn.rows[i].result or "-"
        local mark = (out and inn and o ~= n) and "  <<" or ""
        lines[#lines + 1] = string.format("%s%s: out %s | in %s%s", r.id, r.unit ~= "" and (" " .. r.unit) or "", o, n, mark)
    end
    return table.concat(lines, "\n")
end

local SELFTEST_HINT = "Ctrl+C to copy and send it. /gf selftest show reopens it."

-- quiet: only refresh the window when it is open, never open it or take the keyboard (the second
-- run happens as combat starts).
local function SaveAndShow(quiet)
    local text = Tools.SelfTestText()
    if #text <= MAX_SAVED_TEXT then hub.db.selftest = text end
    if not quiet then
        Tools.ShowText("GaarForever self-test", text, SELFTEST_HINT)
    elseif popup and popup:IsShown() and popup.readOnly then
        popup.text = text
        popup.edit:SetText(text)
    end
end

-- The differences between the two runs, compact: "UnitHealth target ok -> secret".
local function PrintDiff()
    local out, inn = runs.out, runs["in"]
    if not out or not inn then return end
    local diffs = {}
    for i, r in ipairs(out.rows) do
        local n = inn.rows[i] and inn.rows[i].result
        if n and Kind(n) ~= Kind(r.result) then
            diffs[#diffs + 1] = r.id .. (r.unit ~= "" and (" " .. r.unit) or "") .. " " .. Kind(r.result) .. ARROW .. Kind(n)
        end
    end
    if #diffs == 0 then
        Print("self-test: in and out of combat answer alike.")
        return
    end
    Print("self-test: " .. #diffs .. " call(s) answer differently in combat:")
    for i = 1, math.min(#diffs, 8) do Print("  " .. diffs[i]) end
    if #diffs > 8 then Print("  ... and " .. (#diffs - 8) .. " more in the window") end
end

local function Arm(event)
    if not selftestFrame then
        local ok, f = pcall(_G.CreateFrame, "Frame")
        if not ok or not f then return end
        selftestFrame = f
        f:SetScript("OnEvent", function(self, ev)
            self:UnregisterAllEvents()
            local function Second()
                local label = ev == "PLAYER_REGEN_DISABLED" and "in" or "out"
                runs[label] = RunProbes(label)
                Print("self-test " .. (label == "in" and "in combat" or "out of combat") .. ": " .. Summary(runs[label]))
                PrintDiff()
                SaveAndShow(true)
                Print("self-test done: /gf selftest show for the text to copy.")
            end
            -- A moment later, so the client is fully in (or out of) combat.
            local after = _G.C_Timer and _G.C_Timer.After
            if type(after) == "function" then after(1, function() pcall(Second) end) else pcall(Second) end
        end)
    end
    selftestFrame:UnregisterAllEvents()
    pcall(selftestFrame.RegisterEvent, selftestFrame, event)
end

function Tools.SelfTestCommand(rest)
    if rest == "show" then
        if runs.out or runs["in"] then
            SaveAndShow()
        elseif hub.db.selftest then
            Tools.ShowText("GaarForever self-test (saved)", hub.db.selftest, "Ctrl+C to copy. /gf selftest runs it again.")
        else
            Print("no self-test yet: /gf selftest")
        end
        return
    end
    local inCombat = Lib.InCombat() or Lib.Bool(Lib.Call(_G.UnitAffectingCombat, "player")) == true
    local label = inCombat and "in" or "out"
    runs = { out = nil, ["in"] = nil }
    runs[label] = RunProbes(label)
    Print("self-test " .. (inCombat and "in combat" or "out of combat") .. ": " .. Summary(runs[label])
        .. ". It runs again " .. (inCombat and "when combat ends" or "at your next pull") .. " and compares.")
    Arm(inCombat and "PLAYER_REGEN_ENABLED" or "PLAYER_REGEN_DISABLED")
    SaveAndShow()
end
