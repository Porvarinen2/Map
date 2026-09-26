-- TESLES NPC OVERHAUL - squad weapons
--
-- This file is KEPT on updates: INSTALL.bat never overwrites it.
--
-- By default NPCs keep the weapon SCUM gives them, with a magazine holding
-- a few rounds and a condition that fits their squad (config.lua:
-- GhostWeaponChance turns on themed weapons per squad class: hunters with
-- bows, crossbows and hunting rifles, police with pistols and SMGs,
-- soldiers with assault rifles ...).
--
-- Your own list replaces the default, e.g.:
--   police_patrol = {
--       Weapons = { "Weapon_MP5", "Weapon_M1911" },  -- one is picked
--   },
--   hunters = {
--       ScopeChance = 0.8,         -- 80 % get a scope
--   },
--   bandit_gang = {
--       Magazine = false,          -- no magazine
--   },
-- ALL = every squad. Names are the same as in the #SpawnItem command.
-- Every attempt is written to output\npc_loadout.txt.
return {
    ALL = {
    },
}
