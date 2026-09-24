-- TESLES NPC OVERHAUL - omat varusteet NPC-ryhmille
--
-- Tama tiedosto SAILYY paivityksissa: INSTALL.bat ei kirjoita sen yli.
--
-- Asu = numero NPC-tyypin valmiista asulistasta (0 = ensimmainen), tai
--   lista { 0, 3, 5 }, josta jokaiselle arvotaan yksi. Yksittaisia vaatteita
--   ei voi lisata: jokainen asu on valmis kokonainen malli.
--
-- Runko = NPC-tyyppi, jonka asuihin ryhma puetaan:
--   "Drifter"   - kulkurit (siviiliasuja)
--   "Guard"     - vartijat
--   "Radiation" - sateilypuvut
--   "Bunker"    - bunkkerin asut
--
-- Weapons = aseet #SpawnItem-nimella toivejarjestyksessa: NPC saa ensimmaisen,
-- jonka modi loytaa, esim. { "Weapon_SCAR_DMR", "Weapon_AS_Val" }.
--
--   police_patrol = {
--       Runko = "Guard",
--       Weapons = { "Weapon_M1911" },
--   },
--
-- KAIKKI koskee jokaista ryhmaa (sateilyryhmat pysyvat sateilypuvussa).
-- Ryhmat: lone_wanderer, pair, hunters, scavengers, police_patrol,
--   military_group, radiation_group, bunker_group, bandit_gang,
--   survivor_group, militia_cell, elite_unit, island_residents
--   (+ ryhmat.lua:n omat ryhmat, esim. palomiehet, laakarit)
-- Jokainen yritys kirjataan tiedostoon output\npc_loadout.txt.
return {
    -- KAIKKI: koskee jokaista NPC:ta jokaisessa ryhmassa.
    -- Testi: kaikille sama asu ja sama ase.
    KAIKKI = {
        Asu = 0,
        Weapons = { "Weapon_SCAR_DMR", "Weapon_AS_Val" },
    },
    police_patrol = {
        Runko = "Guard",
        Weapons = {},
    },
}
