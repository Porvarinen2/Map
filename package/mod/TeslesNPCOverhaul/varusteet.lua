-- TESLES NPC OVERHAUL - NPC-ryhmien aseet
--
-- Tama tiedosto SAILYY paivityksissa: INSTALL.bat ei kirjoita sen yli.
--
-- Oletuksena NPC:t kayttavat kaikkia SCUMin aseita (ei DLC-aseita, ei
-- rajahteita tai sinkoja) taitotasonsa mukaan:
--   taso 1 - itse tehdyt lyomaaseet, keihaat, heikot jouset
--   taso 2 - kirveet, mailat, miekat, pamppu, itse tehdyt pistoolit ja kivaarit
--   taso 3 - pistoolit, haulikot, Kar98, Mosin, Hunter85, hyvat jouset
--   taso 4 - konepistoolit, rynnakkokivaarit, SKS, parhaat jouset, varsijousi
--   taso 5 - parhaat: AK15, SCAR, AS Val, SVD, M249, M82A1, AWM ...
-- Poliisit: MP5 / M1911 / Block21. Metsastajat: Hunter85 / CarbonHunter.
-- Sotilaat vahintaan taso 4, eliitti aina taso 5.
-- Lippaalliseen aseeseen tulee lipas ja vahan panoksia; tarkkuus- ja
-- pulttilukkokivaareissa on joskus tahtain (metsastajat, sotilaat, eliitti).
--
-- Oma lista korvaa oletuksen, esim.:
--   police_patrol = {
--       Weapons = { "Weapon_MP5", "Weapon_M1911" },  -- arvotaan yksi
--   },
--   hunters = {
--       TahtainOsuus = 0.8,        -- 80 %:lla tahtain
--   },
--   bandit_gang = {
--       Lipas = false,             -- ei lipasta
--   },
-- Nimet ovat samat kuin #SpawnItem-komennossa.
-- Jokainen yritys kirjataan tiedostoon output\npc_loadout.txt.
return {
    KAIKKI = {
    },
}
