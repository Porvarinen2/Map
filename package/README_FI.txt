TESLES NPC OVERHAUL 1.9.24
=========================

Pysyva NPC-populaatio SCUM-palvelimelle. NPC-hahmot ja niiden ryhmat ovat
olemassa koko ajan koko kartalla, kulkevat teita pitkin omiin kohteisiinsa ja
muuttuvat oikeiksi SCUM-hahmoiksi vasta kun pelaaja tulee lahelle. Sama yksilo
sailyttaa persoonallisuutensa, ryhmansa ja tilansa yli palvelimen
uudelleenkaynnistyksen.


ASENNUS
-------
1. Sammuta SCUM-palvelin.
2. Pura tama ZIP omaan kansioon. ALA aja ZIPin sisalta.
3. Aja INSTALL.bat.
4. Kaynnista SCUM-palvelin.

Siina kaikki. INSTALL.bat tekee loput itse:

  1/6  etsii SCUM-palvelimen (myos Steam-kirjastoista muilta levyilta)
  2/6  asentaa UE4SS:n paketin mukana tulevasta versiosta (ei verkkoa)
  3/6  ottaa kaikki muut Lua-modit pois kaytosta, jottei mikaan sekoita tata
  4/6  asentaa modin ja rekisteroi sen (mods.txt + enabled.txt)
  5/6  pilkkoo tarkan kartan zoom-tasoiksi jos se on paikallaan
  6/6  kaynnistaa live mapin omaan ikkunaansa ja avaa selaimen

Mikaan ei katoa: kaikki korvattava varmuuskopioidaan kansioon
<SCUM Server>\TeslesNPCOverhaul_Backups\<aikaleima>, ja pois kaytosta
otetut modit listataan sen disabled_mods.txt:aan. Aiempi maailman tila
(state\world_state.json) sailyy paivityksessa.

Valitsimet jos haluat ohjata asennusta:

  INSTALL.bat -SkipUE4SS        ala kosketa UE4SS-asennukseen
  INSTALL.bat -KeepOtherMods    jata muut Lua-modit paalle
  INSTALL.bat -NoMap            ala pilko karttaa ala kaynnista live mapia
  INSTALL.bat -ServerRoot "D:\SCUM Server"    anna palvelimen polku kasin

Palvelimen kaynnistyksen jalkeen mod alkaa toimia 25 sekunnin kuluttua.
Live map paivittyy itsestaan osoitteessa http://127.0.0.1:8777/
Jos suljit live map -ikkunan, avaa se uudestaan: START_LIVEMAP.bat

JOS MITAAN EI TAPAHDU
---------------------
Mod kirjoittaa heti kaynnistyessaan tiedoston

  Mods\TeslesNPCOverhaul\output\boot.log

Se kertoo mihin asti mod paasi. Lue se ensin.

  boot.log on olemassa ja paattyy riviin "startup deferred by 25000 ms"
    -> odota 25 s ja aja lisatyokalut\CHECK.bat uudestaan. Tama on normaalia.

  boot.log on olemassa ja paattyy riviin "startup complete"
    -> mod toimii. live_state.json ilmestyy parin sekunnin sisalla.

  boot.log on olemassa ja siina lukee REQUIRE FAILED tai STARTUP FAILED
    -> rivilla on syy. Laheta DIAGNOSE.bat:n tuottama zip.

  boot.log PUUTTUU kokonaan
    -> UE4SS ei ole ajanut modia lainkaan. lisatyokalut\CHECK.bat tutkii silloin
       automaattisesti UE4SS:n tilan ja kertoo syyn. Ks. seuraava osio.

  palvelin kaatuu virheeseen "EXCEPTION_ACCESS_VIOLATION ... UE4SS.dll"
  ja UE4SS.log toistaa rivia
  "[Lua::Registry::get_function_ref] Ref was not function"
    -> tama oli versioiden 1.0.9 ja vanhempien vika. Tickaus ajettiin
       LoopAsyncilla, joka suorittaa koodin eri Lua-tilassa kuin missa modi
       on ladattu, ja se sekoitti UE4SS:n funktiorekisterin. 1.1.0 ajaa
       tickauksen samassa tilassa. Paivita modi.

  palvelin jumittuu: "Hang detected on GameThread ... UE4SS.dll"
  tai lokissa on mahdottomia virheita ("invalid key to 'next'",
  "function ... in table for 'concat'", "_UBOX*")
    -> versioiden 1.1.2 ja vanhempien vika, kaksi syyta:
       1. live_state.json:n kirjoitus kesti ~8 s pelisaikeella joka
          toinen sekunti (JSON-kirjoittaja oli neliollinen). Nyt ~15 ms.
       2. Modin Lua-koodia ajettiin kahdella saikeella yhta aikaa
          (UE4SS:n ajastinsaie + pelisaie). 1.1.3 kayttaa UE4SS:n
          pelisaieajastimia, joten koodi ajetaan vain pelisaikeella.
       Boot.logissa lukee "tick driver: LoopInGameThreadWithDelay".

DIAGNOSE.bat kerää boot.log:n, director.log:n, mods.txt:n, UE4SS.log:n ja
UE4SS-asennuksen tilan yhteen zip-tiedostoon.


UE4SS:N ASENNUS ERIKSEEN
------------------------
Paketissa on mukana UE4SS (kansio ue4ss\, MIT-lisenssi, alkupera kerrottu
tiedostossa ue4ss\ALKUPERA.txt). INSTALL.bat asentaa sen, joten verkkoyhteytta
ei tarvita eika versio voi olla vaara.

Jos haluat kokeilla jotain muuta versiota:

  lisatyokalut\INSTALL_UE4SS.bat -Force                paketin mukana tuleva
  lisatyokalut\UPDATE_UE4SS.bat                        uusin GitHubista
  lisatyokalut\INSTALL_UE4SS.bat -Force -ZipFile C:\polku\UE4SS.zip
  lisatyokalut\INSTALL_UE4SS.bat -KeepSampleMods       jata UE4SS:n omat modit paalle

Korvattavat tiedostot varmuuskopioidaan kansioon UE4SS_Backups.

Uudemmissa UE4SS-versioissa lataaja on kansiossa ue4ss\ ja modit kansiossa
ue4ss\Mods. Asennin siirtaa vanhan rakenteen (Win64\UE4SS.dll, Win64\Mods)
syrjaan nimille .vanha-rakenne, jottei kaksi asennusta sekoitu keskenaan.

UE4SS EI KAYNNISTA MODEJA
-------------------------
Tama modi on UE4SS-Lua-modi. Jos UE4SS ei paase kayttamaan Lua-modeja,
mikaan tassa paketissa ei voi toimia - eivatka muutkaan Lua-modit.

Jos UE4SS.log paattyy riviin
  Failed to find FText::FText(FString&&): iter returned multiple unique values
  Fatal Error: PS scan timed out
niin UE4SS:n oma tavukuvio osuu tassa pelin buildissa useampaan paikkaan eika
se osaa valita. Silloin:

  lisatyokalut\FIX_UE4SS_SCAN.bat -Auto

Se lukee SCUMServer.exe:n ja kokeilee siihen jokaista tunnettua
FText-kuviota, jotka UE4SS itse toimittaa muille Unreal-peleille. Kuvio
kirjoitetaan tiedostoon UE4SS_Signatures\FText_Constructor.lua vain jos

  - se osuu exe:hen tasan kerran, ja
  - jokainen muukin osuva kuvio osoittaa samaan kohtaan.

Muuten se kieltaytyy: vaara osoite kaataisi palvelimen, eika arvaus ole
parempi kuin ei mitaan. Peruminen: lisatyokalut\FIX_UE4SS_SCAN.bat -Revert

lisatyokalut\CHECK.bat ja DIAGNOSE.bat kertovat UE4SS:n tilan yhdella sanalla:

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

  1. lisatyokalut\UPDATE_UE4SS.bat
     Hakee uusimman UE4SS-esijulkaisun ja asentaa sen. Uusien pelibuildien
     tuki tulee yleensa ensin sinne. Asennin kertoo julkaisupaivan ja sen
     jos lataaja ei tosiasiassa vaihtunut.

     Jos lataus ei onnistu (verkko tai GitHubin tuntiraja), asennin nayttaa
     suoran osoitteen. Lataa zip kasin ja aja:
       lisatyokalut\INSTALL_UE4SS.bat -Force -ZipFile C:\polku\UE4SS.zip

  2. lisatyokalut\FIX_UE4SS_SCAN.bat
     UE4SS skannaa pelin binaaria oletuksena kahdeksalla saikeella. Jokainen
     saie skannaa oman lohkonsa, ja lohkon rajalla oleva kuvio voi tulla
     raportoiduksi useaan kertaan hieman eri kohdasta - juuri sita
     "multiple unique values" tarkoittaa. Tama komento vaihtaa skannerin
     yhteen saikeeseen, antaa sille lisaa aikaa ja tyhjentaa vanhan
     AOB-valimuistin.

     Pelkka asetusmuutos. Alkuperainen tiedosto varmuuskopioidaan,
     AOB-valimuisti siirretaan syrjaan eika poisteta, ja
     lisatyokalut\FIX_UE4SS_SCAN.bat -Revert palauttaa kaiken.

     HUOM: yksi saie skannaa hitaammin. Odota koko aikaraja (120 s)
     palvelimen kaynnistyksesta ennen lisatyokalut\CHECK.bat:ia. Sita ennen tila on
     SCANNING, mika on normaalia.

     Tama on kokeiltava hypoteesi, ei varmuus. Jos kuvio osuu binaarissa
     aidosti useaan paikkaan, saikeiden maara ei auta.

     Lisaksi -ServerTuning kytkee UE4SS:n debug-GUIn pois, jota
     headless-palvelin ei tarvitse.

  3. Signature-ohitus, jos saat oikean tavukuvion UE4SS:n tai SCUM-
     modausyhteison puolelta:

       lisatyokalut\FIX_UE4SS_SCAN.bat -Signature FText_Constructor -Aob "48 89 5C 24 ??"

     Se kirjoittaa UE4SS_Signatures\FText_Constructor.lua:n oikeassa
     muodossa. Tama paketti ei arvaa tavukuviota: vaara osoite voi kaataa
     palvelimen.

Tarkista myos:
  - Onko proxy-DLL (dwmapi.dll / xinput1_3.dll) yha Win64-kansiossa.
    SCUM-paivitys voi ylikirjoittaa sen. lisatyokalut\CHECK.bat kertoo.
  - Kaynnistetaanko palvelin samasta Win64-kansiosta johon UE4SS on
    asennettu.

Kun UE4SS alkaa kayttaa Lua-modeja, tama modi kirjoittaa boot.log:n
sekunneissa. Aja lisatyokalut\CHECK.bat uudestaan - sen pitaisi nayttaa MOD_STARTED.


TARKKA KARTTA (valinnainen)
---------------------------
Mukana tulee 2048 x 2048 kartta. Jos haluat tarkemman:
1. Lataa 14k x 14k SCUM-kartta selaimella.
2. Tallenna se nimella scum_map_hires.png kansioon livemap\map\
3. Aja lisatyokalut\SETUP_HIRES_MAP.bat. Se pilkkoo kartan zoom-tasoiksi.
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
  RenderRadiusUU          ryhma on fyysinen taman sateen sisalla pelaajasta (100000 = 1 km, kartalla, korkeus ei vaikuta)
  StressRecoveryPer5Min   kuinka paljon stressi laskee 5 minuutissa rauhassa (0.01 = yksi piste)

OMAT RYHMATYYPIT: mod-kansion ryhmat.lua (esim. palomiehet, laakarit).
OMAT VARUSTEET: mod-kansion varusteet.lua (sailyy paivityksissa). Ohjeet
tiedoston alussa; tulokset output\npc_loadout.txt.
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
lisatyokalut\UNINSTALL.bat. Varmuuskopio jaa palvelimen kansioon
TeslesNPCOverhaul_Backups.
