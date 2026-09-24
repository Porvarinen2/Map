-- TESLES NPC OVERHAUL - NPC-ryhmien aseet
--
-- Tama tiedosto SAILYY paivityksissa: INSTALL.bat ei kirjoita sen yli.
--
-- Oletuksena NPC:t kayttavat kaikkia SCUMin aseita (ei DLC-aseita, ei
-- rajahteita tai sinkoja). Jokaisella ryhmalla on sille sopivat asetyypit
-- (metsastajilla jouset, varsijouset ja metsastyskivaarit, poliiseilla
-- pistoolit ja konepistoolit, sotilailla rynnakkokivaarit jne.) ja NPC saa
-- niista oman taitotasonsa (1-5) mukaisen aseen. Tarkka lista:
-- TeslesNPC_aseet.pdf.
-- Lippaalliseen aseeseen tulee lipas ja vahan panoksia; tarkkuus- ja
-- pulttilukkokivaareissa on joskus tahtain.
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
