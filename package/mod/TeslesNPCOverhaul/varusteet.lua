-- TESLES NPC OVERHAUL - NPC-ryhmien aseet
--
-- Tama tiedosto SAILYY paivityksissa: INSTALL.bat ei kirjoita sen yli.
--
-- Modissa on valmiit aseet naille ryhmille (tyhja tiedosto = ne kaytossa):
--   police_patrol  - Weapon_MP5, Weapon_M1911, Weapon_Block21
--   military_group - AK47, AK15, M16A4, AS Val, SVD, UMP45 (+ joskus tahtain)
--   elite_unit     - samat, useammin tahtain
--   hunters        - Weapon_Hunter85, Weapon_Hunter85_V2 (+ joskus tahtain)
-- Muut ryhmat pitavat SCUMin omat aseet.
--
-- Oma lista korvaa valmiin, esim.:
--   police_patrol = {
--       Weapons = { "Weapon_MP5", "Weapon_M1911" },  -- arvotaan yksi
--   },
--   hunters = {
--       Weapons = { "Weapon_Hunter85" },
--       Tahtaimet = { "WeaponScope_Hunter85" },
--       TahtainOsuus = 0.5,        -- puolella kivaareista tahtain
--   },
--   bandit_gang = {
--       Lipas = false,             -- ei lipasta aseeseen
--   },
--
-- Nimet ovat samat kuin #SpawnItem-komennossa. Aseeseen laitetaan aina lipas
-- ja vahan panoksia (Magazine_<aseen nimi>), ellei Lipas = false.
-- Tahtain tulee vain pulttilukko- ja tarkkuuskivaareihin.
-- Jokainen yritys kirjataan tiedostoon output\npc_loadout.txt.
return {
    KAIKKI = {
    },
}
