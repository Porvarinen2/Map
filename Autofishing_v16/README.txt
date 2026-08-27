AUTOFISHING v16
===============

F8 = tauko / jatka
F9 = lopeta


MIKA v15:SSA OLI VIKANA
-----------------------

Ongelma ei ollut siina etta palkin etsinta olisi ollut hidasta. Se loysi
palkin ~16 ms:ssa. Ongelma oli se mika ajettiin heti sen perassa SAMALLA
silmukan kierroksella:

    if state == "ARMED_FAST":   -> palkin haku          (~16 ms)
    if state == "FISHING":      -> seuranta
    else:                       -> VANHA TAYSSKANNAUS   (~1340 ms)

ARMED_FAST ei ole FISHING, joten else-haara ajettiin joka kierroksella
ennen kuin palkki oli loytynyt. Se teki koko ruudun kuvasta:

    detect_minigame   412 ms   (18 kalaskaalaa x 2 referenssia per ehdokas)
    detect_waiting    293 ms   (19 skaalaa, koko ruutu)
    detect_bite       304 ms   (19 skaalaa, koko ruutu)
    detect_cast       328 ms   (19 skaalaa, koko ruutu)
    -------------------------
    1337 ms per skannaus, peraperaa - SCAN_INTERVAL (0.12 s) oli jo aikaa
    sitten umpeutunut kun edellinen skannaus valmistui.

Eli "uncapped, zero-wait" palkinhaku ehti oikeasti katsoa ruutua noin
0.7 kertaa sekunnissa. Kun palkki ilmestyi, skripti oli keskella ~1.3
sekunnin template-matchausta. Se on se viive.

Samaa tautia oli seurannassa:

    fast_track_minigame     2.6 ms   (varsinainen A/D-ohjaus)
    detect_ready           83   ms   (26 skaalaa, kaytannossa joka kierros)
    find_fish_in_bar      133   ms   (36 skaalaa, 0.3 s valein, VAIN kuvia varten)

-> FISHING pyori ~11 Hz:lla, eli vihrea alue seurasi kalaa ~90 ms jaljessa.

Lisaksi kaksi asiaa jotka estivat reagoinnin kokonaan:

  * WAIT_CAST-tila teki `continue` ennen kuin edes katsoi minipelia.
    Jos cast.png jai huomaamatta, skripti oli sokea koko kierroksen ajan
    vaikka palkki oli naytolla.

  * Kalan kokorajat olivat absoluuttisia pikseleita (55..2600 px). Ne oli
    kalibroitu minigame_example.png:sta, joka on 701x473. 1080p:lla oikea
    kala on ~71x62 px eli 3000+ px alaltaan -> hylattiin, ja tilalle
    valikoitui joku muu pieni cyan-tapla. 1440p:lla sama.


MITA v16 TEKEE TOISIN
---------------------

1. PALKKI ON LAUKAISIN JOKA TILASSA
   Haku ajetaan joka kierroksella IDLE-, ARMED_FAST- ja WAIT_CAST-tilassa.
   cast.png -> E aloittaa yha kierroksen, mutta se ei ole enaa portti:
   huomaamatta jaanyt cast.png ei voi enaa sokeuttaa seurantaa.

2. HAKU EI JAA SAMALLE KIERROKSELLE TEMPLATE-MATCHAUKSEN KANSSA
   Vanha tayssskannaus on poistettu. cast.png-haku ei aja lainkaan
   ARMED_FAST-tilassa - E on jo painettu, joten valettavaa ei ole, ja juuri
   siina ikkunassa palkki ilmestyy. Se ikkuna on nyt pelkkaa varityota.

3. TEMPLATE-MATCHAUS AJETAAN TYOSAIKEESSA
   Ohjaussilmukka ei odota template-hakua koskaan. OpenCV vapauttaa GIL:n
   matchTemplaten ajaksi, joten tyosaie oikeasti ajaa rinnalla.

4. HAKU KARKEASTA TARKKAAN, SKAALALUKITUKSELLA
   Skaalapyyhkaisy ajetaan pienennetylla kuvalla ja voittaja tarkennetaan
   taydella resoluutiolla pienessa ikkunassa. Kun referenssi kerran osuu,
   sen skaala muistetaan - myos calibration.json-tiedostoon, joten laaja
   pyyhkaisy tehdaan kerran konetta kohti eika kerran kaynnistysta kohti.
     detect_cast  328 ms -> ~2 ms
     detect_ready  83 ms -> ~3 ms

5. PALKIN HAKU PUOLELLA RESOLUUTIOLLA
   Palkki on satoja pikseleita leveä, joten puolikas resoluutio loytaa
   tasan saman komponentin neljasosahinnalla. Kala ja vihrea mitataan
   taydella resoluutiolla, mutta vain palkin sisalta.

6. EI TEMPLATE-MATCHAUSTA HAKUPOLULLA LAINKAAN
   v15 maksoi 2 referenssia x 5 skaalaa JOKAISESTA hylatysta
   palkkiehdokkaasta. Palkin alla oleva edistymispalkki on aina sellainen
   ehdokas.

7. KALAN TUNNISTUS KIRKKAUDEN PERUSTEELLA
   Kalastuspalkissa on oma tumma cyan-gradientti, joka osuu samaan
   savy/kylläisyys-ikkunaan kuin kala. Mitattuna omasta kuvastasi:

       kalan pikselit         V 65..237, mediaani 237
       palkin gradientti      V 65.. 74, mediaani  70

   Kala saa siis oman kirkkaamman maskinsa. Laajalla maskilla kala
   sulautuu gradienttiin aina kun se osuu sen paalle, ja sulautunut
   moykky hylataan liian leveana - juuri niin selvasti nakyva palkki jaa
   "loytymatta" moneksi frameksi peräkkäin.

8. KOKORAJAT SUHTEESSA PALKIN KORKEUTEEN
   Ei enaa absoluuttisia pikselirajoja. Toimii 720p:sta 4K:hon.

9. PALKIN REUNA RAJATAAN POIS SUHTEELLISESTI
   v15 rajasi 3 px, mika on ohuempi kuin palkin oma reunus 1080p:sta
   ylospain. Siksi palkin paihin ajautunut kala sulautui reunukseen.

9b. PALKIN KOKORAJAT SUHTEESSA RUUDUN KOKOON
   v15 hyvaksyi vain 14..160 px korkean palkin. 4K:lla palkki on ~219 px
   -> koko minipeli oli sille nakymaton.

9c. VIHREAN VARA-TUNNISTUS EI ENAA OSU PALKIN OMAAN CYANIIN
   Kun kala peittaa toisen vihrean reunaviivan, kaytetaan laajempaa
   vihreamaskia. v15:n maski ulottui savyyn 105 asti, mika yltaa palkin
   omaan cyan-gradienttiin (savy 103 asti). Silloin "vihrea alue"
   loytyi palkin taytosta. Mitattuna omasta kuvastasi vihrea target on
   savyalueella 60..78, ja katto 85 sailyttaa siita 100 % ja poistaa
   92 % palkin taytosta.

9d. AIKARAJAT, EI FRAME-LASKUREITA
   v15 vapautti A/D:n kolmen epaonnistuneen framen jalkeen ja haki palkin
   uudelleen kahdeksan jalkeen. 11 Hz:lla ne olivat 270 ms ja 730 ms. Kun
   silmukka pyorii 300 Hz:lla, samat luvut ovat 10 ms ja 27 ms - yksi
   epaonninen frame vapauttaa napit ja lyhyt sarja pudottaa palkkilukon ja
   pakottaa taysimittaisen uudelleenhaun. Silloin vihrea nykii sen sijaan
   etta seuraisi. Nyt: 120 ms armonaika, 350 ms ennen uudelleenhakua.

9e. UUSI OHJAIN (tama on se "vihrea ei seuraa kalaa oikein")
   Vanha ohjain oli: "paina sita nappia, kummalla puolella kala on, ja
   vapauta kun keskipisteet ovat 0,8 pikselin sisalla". Kolme ongelmaa:

     - 0,8 px kuollut alue tarkoittaa etta napit heiluvat jatkuvasti.
     - Nappi vapautetaan vasta kun virhe on nolla, mutta vyohyke jatkaa
       liikettaan yhden viiveen verran -> se ylittaa aina maalin.
     - Ohjain tahtaa siihen missa kala ON, joten vyohyke on pysyvasti
       yhden reaktion verran perassa. Juuri sita "ei seuraa oikein"
       tarkoittaa.

   v16:n ohjain mittaa ajon aikana kuinka nopeasti vyohyke oikeasti
   liikkuu kun nappi on pohjassa, ja kayttaa sita jarrutusmatkaan. Se
   tahtaa kalan mitatun nopeuden verran eteenpain, kayttaa vyohykkeen
   leveyteen suhteutettua kuollutta aluetta hystereesilla, eika koskaan
   vaihda suuntaa nopeammin kuin peli ehtii lukea nappaimiston.

   Mitattuna: kala vihrean sisalla 95 % -> 97 % ajasta 300 silmukalla,
   ja kolmasosa nappaintapahtumia. Kun vyohyke on hyvin hidas tai hyvin
   nopea ero on selvasti isompi: 2200 px/s ja 60 silmukkaa/s -> 63 %
   vanhalla, 86 % uudella.

10. LEVYKIRJOITUS POIS OHJAUSPOLULTA
    Todiste- ja debug-kuvat ovat oletuksena POIS PAALTA ja kirjoitetaan
    taustasaikeessa kun ne laitetaan paalle. v15 kutsui cv2.imwrite ja
    hakemistolistausta suoraan ohjaussilmukasta.

11. NAPPAINPOLKU KEVENNETTY
    v15 kutsui SetForegroundWindow ja GetWindowText jokaisella
    nappaintapahtumalla ja tulosti rivin konsoliin. Nyt ikkuna nostetaan
    esiin korkeintaan 0.5 s valein ja vain jos se ei jo ole edessa.

12. WINDOWSIN AJASTINTARKKUUS 1 ms
    Muuten time.sleep() ja nappainten pitoajat kvantittuisivat ~15.6 ms:iin.


MITATUT TULOKSET
----------------

Mittaukset ajettiin simuloidulla pelilla, joka piirtaa oikeat pikselit
minigame_example.png:sta ja liikuttaa kalaa. Sama kone, sama kuorma.

  Viive palkin ilmestymisesta ensimmaiseen A/D-painallukseen
      v15   ei reagoinut lainkaan 13 sekunnissa
      v16   24-25 ms, mediaani 25 ms  (= yksi silmukan kierros)

  Kalan tunnistus kun kala pyyhkaistaan koko palkin yli (98 kohtaa)
      v16   98/98, keskivirhe 2.0 px

  Vihrean alueen mittaus (4 kalan kohtaa x 29 targetin kohtaa)
      v16   116/116 oikein, suurin virhe 2 px

  Kalan tunnistus eri resoluutioilla (mitattu kalan keskipiste vs. totuus)
      v15   1280x720 OK, 1600x900 OK,
            1920x1080 VAARA KOHDE (348 px vinossa),
            2560x1440 VAARA KOHDE (465 px vinossa),
            3840x2160 ei loytynyt lainkaan
      v16   kaikki viisi oikein

  cast.png viidella eri UI-skaalalla
      v16   5/5

  Kokonaiset kierrokset (heitto -> seuranta -> SPACE -> uusi kierros)
      v16   4-5 kierrosta 20 sekunnissa, reaktio joka kierroksella 20-25 ms,
            kala vihrean sisalla 93 % ajasta, ei yhtaan poikkeusta ajossa

  SEURANNAN LAATU vs. SILMUKAN NOPEUS
  Tama on tarkein yksittainen luku. Kala vihrean alueen sisalla, keskiarvo
  neljasta vyohykenopeudesta ja kahdesta kalatyypista:

      silmukkaa/s      vanha ohjain     uusi ohjain
             11              21 %            24 %     <- tassa v15 pyori
             25              48 %            61 %
             60              82 %            91 %
            150              95 %            97 %
            300              95 %            97 %     <- tassa v16 pyorii

  Eli: silmukan nopeus oli ylivoimaisesti tarkein tekija. v15:n 11 Hz:lla
  mikaan ohjain ei olisi pysynyt kalan alla. Uusi ohjain tuo paalle
  muutaman prosentin ja selvasti paremman kayttaytymisen aariarvoilla.

Huom: mittauskoneen suoritusteho on selvasti pelikonetta heikompi ja
simulaattorin oma ruudunkaappaus on hitaampi kuin oikea mss. Omalla
koneellasi luvut ovat parempia - katso [PERF]-rivi.


KONSOLI
-------

  [PERF]       silmukan todellinen nopeus. TAMA kertoo onko nopea.
  [ZERO-WAIT]  palkki + kala loytyi -> A/D ensimmaisella kelvollisella framella
  [FISH]       kalan ja vihrean sijainti, virhe, painettava nappain
  [READY]      SPACE-turvaviive kaynnissa, seuranta jatkuu
  [CATCH]      SPACE painettu
  [SCAN]       cast.png-pistemaara odotustilassa
  [CALIB]      levylta ladatut skaalalukitukset

Odotettavat [PERF]-luvut pelikoneella:
  ARMED_FAST   yli 150 silmukkaa/s
  FISHING      yli 200 silmukkaa/s

Jos luvut ovat selvasti pienempia, tarkista etta SAVE_PROOF_IMAGES ja
SAVE_DEBUG_IMAGES ovat False.


[FISH]-RIVIN LUKEMINEN
----------------------

  [FISH] round=5 fishX=990 greenX=991 error=+15px key=D lead=+16px
         stopBand=12px zoneSpeed=810px/s fishSpeed=+177px/s
         keyChanges=36/s greenMode=dynamic-borders inside=YES ready=0.412/0.68

  error       kuinka kaukana vihrean keskipiste on tahtayspisteesta
  key         mika nappi on nyt pohjassa
  lead        kuinka paljon kalan eteen tahdataan juuri nyt
  stopBand    kuinka lahella maalia nappi vapautetaan (jarrutusmatka)
  zoneSpeed   AJON AIKANA MITATTU vihrean alueen nopeus. Jos tama on 0,
              vihrea ei liiku - silloin nappaimet eivat mene peliin asti.
  fishSpeed   kalan mitattu nopeus
  keyChanges  suunnanvaihtoja sekunnissa. Yli ~25 = ohjain heiluu;
              nosta MIN_KEY_HOLD_SECONDS tai CONTROL_ENTER_RATIO.
  greenMode   dynamic-borders = molemmat vihreat reunaviivat nakyvat, paras.
              dynamic-fallback = kala peittaa reunan, arvio on karkeampi.
              startup-bar-center = vihreaa ei viela loydetty, oletetaan
              keskelle. Jos tama nakyy jatkuvasti, vihrean tunnistus ei
              toimi ja se pitaa korjata ennen kuin ohjaimesta kannattaa
              puhua.
  inside      onko kala vihrean sisalla juuri nyt


ASETUKSET JOITA KANNATTAA SAATAA
--------------------------------

  SPACE_READY_DELAY_SECONDS   0.220   turvaviive ennen SPACE:a
  CONTROL_LEAD_SECONDS        0.090   kuinka paljon kalan eteen tahdataan
  CONTROL_ENTER_RATIO         0.050   milloin nappi painetaan (osuus vyoh.)
  CONTROL_BRAKE_SECONDS       0.015   kuinka pitkalle vyohyke liukuu
  MIN_KEY_HOLD_SECONDS        0.026   lyhin sallittu aika suunnanvaihtojen valilla
  CAST_SCAN_INTERVAL          0.10    kuinka usein cast.png etsitaan
  SAVE_PROOF_IMAGES           False   tarkista tunnistus -> True
  SAVE_DEBUG_IMAGES           False   piirretty kokoruudun kuva -> True
  LOG_KEY_EVENTS              False   rivi jokaisesta nappaimesta
  LOG_NOTIFICATION_SCORES     False   waiting.png / bite.png pisteet
                                      (v16 ei odota naita mihinkaan)

calibration.json syntyy automaattisesti. Jos vaihdat resoluutiota tai
UI-skaalaa, poista se - tai odota 5 s, jolloin lukitus tarkistetaan
uudelleen itsestaan.


REFERENSSIKUVAT
---------------

Kaikki toimittamasi referenssit ovat mukana ja ladataan edelleen.
cast.png ja ready_space*.png ohjaavat kierroksen aloitusta ja SPACE:a.
fish-left/right.png ja green-target.png ovat todistekuvia varten.
waiting.png ja bite.png eivat ohjaa mitaan - v16 ei odota niita.
