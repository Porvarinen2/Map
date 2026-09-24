-- TESLES NPC OVERHAUL - omat varusteet NPC-ryhmille
--
-- Tama tiedosto SAILYY paivityksissa: INSTALL.bat ei kirjoita sen yli.
--
-- Runko = NPC-tyyppi, jonka asuihin ryhma puetaan:
--   "Drifter"   - kulkurit (siviiliasuja)
--   "Guard"     - vartijat
--   "Radiation" - sateilypuvut
--   "Bunker"    - bunkkerin asut
-- SCUM arpoo asun tyypin omasta listasta pelaajan koneella, joten
-- yksittaista vaatetta tai asua palvelin ei voi valita (kokeiltu 1.7.x).
--
-- Weapons = ase #SpawnItem-nimella, esim. { "Weapon_M1911" }.
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
    -- Testi: kaikille sama ase, jotta nahdaan toimiiko aseen vaihto.
    KAIKKI = {
        Weapons = { "Weapon_SCAR_DMR" },
    },
    police_patrol = {
        Runko = "Guard",
        Weapons = {},
    },
}
