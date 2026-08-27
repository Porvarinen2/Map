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
      v16   4-5 kierrosta 20 sekunnissa, reaktio joka kierroksella 21-26 ms,
            ei yhtaan poikkeusta ajossa

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


ASETUKSET JOITA KANNATTAA SAATAA
--------------------------------

  SPACE_READY_DELAY_SECONDS   0.220   turvaviive ennen SPACE:a
  CONTROL_ENTER_MIN_PX        0.80    kuollut alue keskella (pienempi = tarkempi)
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
