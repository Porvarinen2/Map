TESLES NPC OVERHAUL 1.0.2
=========================

Pysyva NPC-populaatio SCUM-palvelimelle. NPC-hahmot ja niiden ryhmat ovat
olemassa koko ajan koko kartalla, kulkevat teita pitkin omiin kohteisiinsa ja
muuttuvat oikeiksi SCUM-hahmoiksi vasta kun pelaaja tulee lahelle. Sama yksilo
sailyttaa persoonallisuutensa, ryhmansa ja tilansa yli palvelimen
uudelleenkaynnistyksen.


ASENNUS
-------
1. Sammuta SCUM-palvelin ja vanha LiveMap-ikkuna.
2. Pura tama ZIP omaan kansioon. ALA aja ZIPin sisalta.
3. Aja INSTALL.bat. Asennus kieltaytyy toimimasta palvelimen ollessa paalla.
   - Vanha TeslesWorldDirector otetaan pois kaytosta automaattisesti.
     Molemmat eivat voi ohjata samoja NPC:ita.
   - Aiempi maailman tila (state\world_state.json) sailytetaan paivityksessa.
4. Kaynnista palvelin normaalisti. Mod kaynnistyy 25 s viiveella.
5. Aja START_LIVEMAP.bat -> selain aukeaa osoitteeseen http://127.0.0.1:8777/
6. Tarkista tilanne: CHECK.bat


JOS MITAAN EI TAPAHDU
---------------------
Mod kirjoittaa heti kaynnistyessaan tiedoston

  Mods\TeslesNPCOverhaul\output\boot.log

Se kertoo mihin asti mod paasi. Lue se ensin.

  boot.log on olemassa ja paattyy riviin "startup deferred by 25000 ms"
    -> odota 25 s ja aja CHECK.bat uudestaan. Tama on normaalia.

  boot.log on olemassa ja paattyy riviin "startup complete"
    -> mod toimii. live_state.json ilmestyy parin sekunnin sisalla.

  boot.log on olemassa ja siina lukee REQUIRE FAILED tai STARTUP FAILED
    -> rivilla on syy. Laheta DIAGNOSE.bat:n tuottama zip.

  boot.log PUUTTUU kokonaan
    -> UE4SS ei ole ajanut modia lainkaan. CHECK.bat tutkii silloin
       automaattisesti UE4SS:n tilan ja kertoo syyn. Ks. seuraava osio.

DIAGNOSE.bat kerää boot.log:n, director.log:n, mods.txt:n, UE4SS.log:n ja
UE4SS-asennuksen tilan yhteen zip-tiedostoon.


UE4SS EI KAYNNISTA MODEJA
-------------------------
Tama modi on UE4SS-Lua-modi. Jos UE4SS ei paase kayttamaan Lua-modeja,
mikaan tassa paketissa ei voi toimia - eivatka muutkaan Lua-modit.

CHECK.bat ja DIAGNOSE.bat kertovat UE4SS:n tilan yhdella sanalla:

  MOD_STARTED     UE4SS kaynnisti modin. Vika on modissa, katso boot.log.
  SCAN_LOOP       UE4SS juuttui AOB-skannaukseen eika paase modeihin.
  STALE_LOG       UE4SS.log on vanhemmalta ajolta kuin nykyinen palvelin.
                  UE4SS ei siis lataudu lainkaan tassa ajossa.
  NO_LOG          UE4SS ei ole kirjoittanut lokia koskaan.
  NO_MODS_STARTED UE4SS latautui mutta ei kaynnistanyt yhtaan Lua-modia.

SCAN_LOOP nayttaa UE4SS.log:ssa tallaiselta:

  [PS] Failed to find FText::FText(FString&&): iter returned multiple unique values
  [PS] Scan failed
  PS Scan attempt 2
  PS Scan attempt 3
  ... satoja yrityksia, loki paattyy kesken

UE4SS yrittaa loytaa pelin binaarista tarvitsemansa osoitteet ja jaa
luuppiin kun yksi niista on moniselitteinen. Se ei paase modien lataukseen.
Tama on UE4SS:n ja pelin version valinen yhteensopivuusongelma.

Mita tehda:
  1. Paivita UE4SS uudempaan versioon. v3.0.1 Beta on vanha eika tunne
     SCUMin nykyista buildia.
  2. Jos palvelin on juuri paivittynyt, SCUM-paivitys on voinut ylikirjoittaa
     UE4SS:n proxy-DLL:n (dwmapi.dll / xinput1_3.dll) Win64-kansiossa.
     CHECK.bat kertoo onko se paikallaan.
  3. Tarkista etta palvelin kaynnistetaan samasta Win64-kansiosta johon
     UE4SS on asennettu.

Kun UE4SS alkaa kayttaa Lua-modeja, tama modi kirjoittaa boot.log:n
sekunneissa. Aja CHECK.bat uudestaan - sen pitaisi nayttaa MOD_STARTED.


TARKKA KARTTA (valinnainen)
---------------------------
Mukana tulee 2048 x 2048 kartta. Jos haluat tarkemman:
1. Lataa 14k x 14k SCUM-kartta selaimella.
2. Tallenna se nimella scum_map_hires.png kansioon livemap\map\
3. Aja SETUP_HIRES_MAP.bat. Se pilkkoo kartan zoom-tasoiksi.
Kuvan on katettava koko saari samalla rajauksella kuin mukana tuleva kartta,
muuten merkit osuvat vaaraan kohtaan.

Jos ikkuna sulkeutuu heti, aja tiler suoraan nahdaksesi virheen:
  powershell -ExecutionPolicy Bypass -File livemap\tile_map.ps1

Jos muisti loppuu isolla kuvalla, kayta pienempaa tarkkuutta:
  powershell -ExecutionPolicy Bypass -File livemap\tile_map.ps1 -MaxSize 4096

Jos livemap nayttaa pelkan ruudukon, karttakuva puuttuu kansiosta
livemap\map\. Tiler luo puuttuvan scum_map.png:n lahdekuvasta.


ASETUKSET
---------
Mods\TeslesNPCOverhaul\config.lua

  TargetNPCs              populaation koko (oletus 100, kova katto 250)
  EnableReplenish         false = kuolleita ei korvata automaattisesti
  MaterializeDistanceUU   milloin ryhma muuttuu fyysiseksi (60000 = 600 m)
  VirtualizeDistanceUU    milloin fyysiset hahmot vapautetaan (88000 = 880 m)
  ReissueSec              kuinka harvoin liikekasky uusitaan (22 s)
  RetargetEpsUU           kuinka paljon kohteen on siirryttava (450 UU)
  EnableBuildingSearch    false, kunnes ovi- ja sisatilavaiheet on todennettu
  TakeOwnership           true = director ottaa NPC:n SCUMin omalta AI:lta

ReissueSec ja RetargetEpsUU ovat ne kaksi arvoa jotka pitavat liikkeen
suorana. Niiden pienentaminen tuo nykimisen takaisin.


MITA MODI EI LUPAA
------------------
Ei taattua pelaajaystavallista ryhmaa, keskusteluja, kaupankayntia, tehtavia,
pidatyksia, rakentelua, todistettua laakintaa, automaattista taitojen oppimista
tai taydellista tavarankeruuta. Rakennusten sisatilahaku on oletuksena pois
paalta, koska sen fyysisia vaiheita ei ole todennettu.

Live mapin osajarjestelmapaneeli kertoo mika on oikeasti todennettu talla
palvelimella. OK spawn-katalogissa tarkoittaa loytynytta luokkaa, ei
onnistunutta spawnia, liiketta tai taistelua.


VARMISTUKSEN RAJA
-----------------
Koodi on testattu Lua 5.4:lla mock-moottorilla: reititys, liike, populaatio,
tallennus, uudelleenkaynnistys ja oppaan numerot. Windows-palvelimella UE4SS:n
kanssa tata ei voitu ajaa taman paketin rakennusymparistossa.


POISTO
------
UNINSTALL.bat. Varmuuskopio jaa palvelimen kansioon
TeslesNPCOverhaul_Backups.
