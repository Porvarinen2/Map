-- TESLES NPC OVERHAUL - omat NPC-ryhmatyypit
--
-- Tama tiedosto SAILYY paivityksissa: INSTALL.bat ei kirjoita sen yli.
-- Uusi ryhmatyyppi = uusi { ... } -lohko alla olevaan listaan. Palvelimen
-- uudelleenkaynnistyksen jalkeen ryhmat ilmestyvat kartalle, niita voi
-- spawnata live-kartan oikean klikkauksen valikosta, ja niille voi antaa
-- omat varusteet varusteet.lua:ssa samalla avaimella.
--
-- Kentat (vain avain on pakollinen):
--   avain        tunniste, pienet kirjaimet ja _ (esim. "palomiehet")
--   nimi         nimi kartalla
--   koko         { pienin, suurin } jasenmaara, 1-5
--   tausta       kenesta ryhma koostuu: civilian, scavenger, survivor, hunter,
--                bandit, police, security, militia, ex_military, veteran,
--                radiation_specialist, bunker_specialist, elite
--   kohteet      minne ryhma menee ja kuinka mielellaan (isompi = useammin):
--                CITY, VILLAGE, HUNTING, MILITARY, BUNKER, ABANDONED_BUNKER,
--                RESEARCH, INDUSTRIAL, MEDICAL, LANDMARK
--   maara        montako tallaista ryhmaa kartalla on aina (oletus 1)
--   runko        "Guard" tai "Drifter" (SCUMin hahmomalli)
--   vihamieliset lista ryhmatyypeista, joiden kanssa ollaan vihollisia
--   viranomainen true = rosvot vihaavat erityisesti
--   vari         vari kartalla, esim. "#ff8040"
return {
    {
        avain = "palomiehet",
        nimi = "Palomiehet",
        koko = { 2, 4 },
        tausta = { "security", "survivor" },
        kohteet = { CITY = 4, INDUSTRIAL = 3, VILLAGE = 3 },
        maara = 2,
        runko = "Guard",
        viranomainen = true,
        vari = "#ff7a3c",
    },
    {
        avain = "laakarit",
        nimi = "Laakarit",
        koko = { 2, 3 },
        tausta = { "civilian", "survivor" },
        kohteet = { MEDICAL = 6, CITY = 2, VILLAGE = 2 },
        maara = 2,
        runko = "Drifter",
        vari = "#ffffff",
    },
}
