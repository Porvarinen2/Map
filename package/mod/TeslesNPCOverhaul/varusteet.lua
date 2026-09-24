-- TESLES NPC OVERHAUL - omat varusteet NPC-ryhmille
--
-- Tama tiedosto SAILYY paivityksissa: INSTALL.bat ei kirjoita sen yli.
--
-- Kirjoita esineet samoilla nimilla kuin #SpawnItem-komennossa,
-- lainausmerkeissa ja pilkulla erotettuina, esimerkiksi:
--
--   police_patrol = {
--       Clothes = { "Police_Shirt_01", "Police_Pants_01", "Police_Cap" },
--       Weapons = { "Weapon_M9" },
--       Items   = { "Emergency_bandage" },
--   },
--
-- Tyhjat listat = SCUMin omat varusteet. Muut ryhmat lisataan samalla
-- tavalla omalla avaimellaan:
--   lone_wanderer, pair, hunters, scavengers, police_patrol, military_group,
--   radiation_group, bunker_group, bandit_gang, survivor_group, militia_cell,
--   elite_unit, island_residents
--
-- Jokainen yritys kirjataan tiedostoon output\npc_loadout.txt: siita nakee,
-- loytyiko esine ja saatiinko se NPC:n paalle.
return {
    police_patrol = {
        Clothes = {},
        Weapons = {},
        Items = {},
    },
}
