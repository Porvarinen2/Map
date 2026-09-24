-- TESLES NPC OVERHAUL - omat varusteet NPC-ryhmille
--
-- Tama tiedosto SAILYY paivityksissa: INSTALL.bat ei kirjoita sen yli.
--
-- Asu = numero: SCUMin NPC:illa on valmis lista asuja, ja numero valitsee
-- asun. Asu = { 1, 4, 7 } arpoo jokaiselle jasenelle yhden naista.
-- Asulista (numerot ja mita ne ovat) kirjataan tiedostoon
-- output\npc_loadout.txt ("NPC COMMON DATA").
--
-- Weapons = ase #SpawnItem-nimella, esim. { "Weapon_M9" }.
-- Clothes = yksittaiset vaatteet: SCUMin NPC:t eivat nayta niita (kokeiltu).
--
--   police_patrol = {
--       Asu = 2,
--       Weapons = { "Weapon_M9" },
--   },
--
-- KAIKKI koskee jokaista ryhmaa; ryhman oma Asu voittaa KAIKKI-asun.
-- Ryhmat: lone_wanderer, pair, hunters, scavengers, police_patrol,
--   military_group, radiation_group, bunker_group, bandit_gang,
--   survivor_group, militia_cell, elite_unit, island_residents
--   (+ ryhmat.lua:n omat ryhmat, esim. palomiehet, laakarit)
return {
    -- KAIKKI: koskee jokaista NPC:ta jokaisessa ryhmassa.
    -- Testi: kaikille sama asu 0, jotta nahdaan toimiiko asun valinta.
    KAIKKI = {
        Asu = 0,
    },
    police_patrol = {
        Weapons = {},
    },
}
