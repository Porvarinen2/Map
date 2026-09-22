TESLES NPC OVERHAUL 1.0.6
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
   - Jos palvelimella ei ole UE4SS:aa, asennin tarjoutuu hakemaan sen
     GitHubista ja asentamaan sen puolestasi. Se nayttaa version ja
     osoitteen ennen latausta.
   - UE4SS:n omat esimerkkimodit otetaan pois kaytosta, jottei mikaan muu
     Lua-modi sekoita tata. Ne saa takaisin ajamalla
     INSTALL_UE4SS.bat -KeepSampleMods
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


UE4SS:N ASENNUS ERIKSEEN
------------------------
INSTALL_UE4SS.bat asentaa pelkan UE4SS:n. Kaytannollista jos haluat
kokeilla toista versiota:

  INSTALL_UE4SS.bat                  uusin vakaa julkaisu
  INSTALL_UE4SS.bat -Experimental    uusin, myos esijulkaisut
  INSTALL_UE4SS.bat -Force           asenna uudelleen paalle
  INSTALL_UE4SS.bat -ZipFile C:\polku\UE4SS.zip    kasin ladatusta zipista
  INSTALL_UE4SS.bat -KeepSampleMods  jata UE4SS:n omat modit paalle

Korvattavat tiedostot varmuuskopioidaan kansioon UE4SS_Backups.
Jos vakaa versio jaa AOB-skannausluuppiin (ks. alla), kokeile
-Experimental: uusien pelibuildien tuki tulee usein ensin sinne.


UE4SS EI KAYNNISTA MODEJA
-------------------------
Tama modi on UE4SS-Lua-modi. Jos UE4SS ei paase kayttamaan Lua-modeja,
mikaan tassa paketissa ei voi toimia - eivatka muutkaan Lua-modit.

CHECK.bat ja DIAGNOSE.bat kertovat UE4SS:n tilan yhdella sanalla:

  MOD_STARTED     UE4SS kaynnisti modin. Vika on modissa, katso boot.log.
  SCANNING        UE4SS skannaa parhaillaan. Ei viela virhe - odota aikaraja.
  SCAN_ABORTED    UE4SS lopetti omaan virheeseensa ennen modien latausta.
  SCAN_LOOP       Skannaus katkesi eika paassyt maaliin.
  STALE_LOG       UE4SS.log:n viimeinen merkinta on vanhemmalta ajolta kuin
                  nykyinen palvelin. CHECK kertoo silloin myos onko UE4SS:n
                  proxy-DLL ladattu palvelinprosessiin - se erottaa
                  "injektio ei toiminut" tilanteesta "UE4SS kaatui heti".
  NO_LOG          UE4SS ei ole kirjoittanut lokia koskaan.
  NO_MODS_STARTED UE4SS latautui mutta ei kaynnistanyt yhtaan Lua-modia.

SCAN_ABORTED nayttaa UE4SS.log:ssa tallaiselta:

  [PS] Failed to find FText::FText(FString&&): iter returned multiple unique values
  [PS] You can supply your own AOB in 'UE4SS_Signatures/FText_Constructor.lua'
  [PS] Scan failed
  ...
  Fatal Error: PS scan timed out

UE4SS etsii pelin binaarista tarvitsemansa osoitteet. Yksi niista on
moniselitteinen, joten skannaus epaonnistuu, ja asetuksen
SecondsToScanBeforeGivingUp kuluttua UE4SS lopettaa kaynnistyksen kokonaan.
Yhtaan Lua-modia ei ladata - ei tata eika muita.

Tama on UE4SS:n ja pelin buildin valinen yhteensopivuusongelma, ei modin
koodia. Mita tehda, tassa jarjestyksessa:

  1. FIX_UE4SS_SCAN.bat
     UE4SS skannaa pelin binaaria oletuksena kahdeksalla saikeella. Jokainen
     saie skannaa oman lohkonsa, ja lohkon rajalla oleva kuvio voi tulla
     raportoiduksi useaan kertaan hieman eri kohdasta - juuri sita
     "multiple unique values" tarkoittaa. Tama komento vaihtaa skannerin
     yhteen saikeeseen, antaa sille lisaa aikaa ja tyhjentaa vanhan
     AOB-valimuistin.

     Pelkka asetusmuutos. Alkuperainen tiedosto varmuuskopioidaan,
     AOB-valimuisti siirretaan syrjaan eika poisteta, ja
     FIX_UE4SS_SCAN.bat -Revert palauttaa kaiken.

     HUOM: yksi saie skannaa hitaammin. Odota koko aikaraja (120 s)
     palvelimen kaynnistyksesta ennen CHECK.bat:ia. Sita ennen tila on
     SCANNING, mika on normaalia.

     Tama on kokeiltava hypoteesi, ei varmuus. Jos kuvio osuu binaarissa
     aidosti useaan paikkaan, saikeiden maara ei auta.

     Lisaksi -ServerTuning kytkee UE4SS:n debug-GUIn pois, jota
     headless-palvelin ei tarvitse.

  2. INSTALL_UE4SS.bat -Force -Experimental
     Uusien pelibuildien tuki tulee usein ensin esijulkaisuihin. Asennin
     kertoo jos lataaja ei tosiasiassa vaihtunut - silloin sinulla oli jo
     sama versio.

  3. Signature-ohitus, jos saat oikean tavukuvion UE4SS:n tai SCUM-
     modausyhteison puolelta:

       FIX_UE4SS_SCAN.bat -Signature FText_Constructor -Aob "48 89 5C 24 ??"

     Se kirjoittaa UE4SS_Signatures\FText_Constructor.lua:n oikeassa
     muodossa. Tama paketti ei arvaa tavukuviota: vaara osoite voi kaataa
     palvelimen.

Tarkista myos:
  - Onko proxy-DLL (dwmapi.dll / xinput1_3.dll) yha Win64-kansiossa.
    SCUM-paivitys voi ylikirjoittaa sen. CHECK.bat kertoo.
  - Kaynnistetaanko palvelin samasta Win64-kansiosta johon UE4SS on
    asennettu.

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
  MaxSpawnsPerTick        1 kunnes palvelin on todistanut yhden spawnin
  MaxSpawnsPerTickProven  3 sen jalkeen
  RequireGroundProof      true = ei spawnata ilman todennettua maanpintaa
  PlayerScanIntervalSec   pelaajahaun valimuisti (2 s)
  ZombieScanIntervalSec   zombihaun valimuisti (4 s)
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
