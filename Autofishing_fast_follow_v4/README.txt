AUTOFISHING FAST-FOLLOW v4
==========================

Tama on sinun FAST-FOLLOW v3:si. Arkkitehtuuri, ohjain, vihrean tunnistus,
SPACE-logiikka ja koko forensic-debug ovat ennallaan. Poistettu 22 rivia.

v3:n idea on hyva: kalaa ei etsita kiintein koordinaatein eika skaalalukitulla
template-haulla, vaan kirkkaasta cyan-siluetista jota verrataan
fish-left/right-referensseihin. Se on oikea ratkaisu. Siina oli vain yksi rivi
joka teki siita tehottoman juuri sinun ruudullasi.


LOKISTASI LOYTYI KAKSI ASIAA
----------------------------

1) bar=(850, 946, 1040, 126)

   Palkkisi on 1040 px levea. minigame_example.png:ssa palkki on 400x40 ja
   kala 26x23, mutta fish-left.png on 64x60. Referenssikuvat ovat siis
   OIKEASSA mittakaavassa ja se esimerkkikuva on noin 2,6x pienennetty
   kuvakaappaus.

   Oikealla ruudullasi kala on siis noin 67x59 px, ja sen kirkkaan
   cyan-siluetin pinta-ala noin 2600 pikselia.

   v3:ssa luki:

       if area < 35 or area > 1400:
           continue

   Kiintea pikseliraja. Kalan pinta-ala kasvaa UI-skaalan NELIOSSA, joten
   1400 riittaa vain siihen pienennettyyn esimerkkikuvaan. Oikealla
   ruudullasi jokainen kala hylattiin liian isona, ja koko nopea muototunnistus
   ohitettiin. Jaljelle jai hidas skaalalukittu template-haku - joka sekin
   etsii vain skaaloja 0,50..0,58 vaikka sinun kalasi on skaalassa ~1,05.

   Kummatkin nopeat polut olivat siis kaytannossa kuolleita, ja ainoa toimiva
   tunnistus oli se raskas vanha koko ruudun skannaus. Siita tulee se
   "menee sekunti kaks".

2) SendInput=0/1

   Tama ei ole satunnaisvirhe. SendInput palauttaa 0 aina.

   Syy: INPUT-rakenteen unionissa oli vain KEYBDINPUT. Silloin rakenne on
   32 tavua, mutta 64-bittinen Windows odottaa 40. SendInput hylkaa kutsun
   virheella ERROR_INVALID_PARAMETER ja palauttaa 0.

   Nappaimet menivat perille vain sen alla olevan vanhan keybd_event-
   varapolun kautta. Se scan-code-polku joka on olemassa juuri raakaa
   inputtia lukevia peleja varten ei ole kertaakaan onnistunut.

   Lisaksi LastError luki lokissa aina 0, koska ctypes.get_last_error()
   toimii vasta kun kirjasto avataan use_last_error=True -lipulla.


MITA v4 MUUTTAA - VIISI ASIAA
-----------------------------

1. Kalan kokoraja suhteessa palkin korkeuteen, ei kiinteina pikseleina.
   Mitattuna esimerkkikuvastasi kala on noin 0,24 x (palkin korkeus)^2, joten
   ikkuna 0,045..1,30 on reilu molempiin suuntiin ja seuraa resoluutiota itse.

2. INPUT-unioniin lisatty MOUSEINPUT ja HARDWAREINPUT.
   sizeof(INPUT) = 40 tavua. SendInput toimii nyt oikeasti.

3. user32 avataan use_last_error=True, jolloin lokin LastError on totta.

4. HSV-muunnos vain palkin sisalta, ei koko framesta.
   ARMED_FAST kutsuu fast_track_minigame:a kerran per palkkiehdokas koko
   ruudun kuvalle, joten koko 1920x1080 kuvan muuntaminen maksettiin uudestaan
   jokaisesta ehdokkaasta.

5. Vanhaa koko ruudun skannausta ei ajeta ARMED_FAST-tilassa.
   ARMED_FAST ei ole FISHING, joten silmukka putosi oman haun jalkeen myos
   vanhaan skannaushaaraan, joka 0,12 s valein ajoi:

       detect_minigame 249 ms + waiting 183 + bite 185 + cast 204 = 821 ms

   E on jo painettu, siella ei ole mitaan mita se tarvitsisi. Turvaverkko:
   jos nappaus ei tule 12 sekuntiin, skannaus palaa itsestaan - se oli ainoa
   ulospaasy ARMED_FASTista jos kala ei koskaan tule.


MITATUT TULOKSET
----------------

Mittaukset ajettiin simuloidulla pelilla, joka rakentaa 1920x1080 ruudun
oikeista pikseleista niin etta palkki on 1040x104 ja kala 67x59 - eli sama
mittakaava kuin lokisi rivilla.

  Kalan tunnistus fast_track_minigame:lla, palkki 1040x104
      v3   valid=False   (ei loyda kalaa lainkaan)
      v4   valid=True    lahde=shape-cyan

  Kalan tunnistus eri UI-mittakaavoilla
      kerroin   v3                    v4
      1.00x     shape-cyan            shape-cyan
      1.50x     shape-cyan            shape-cyan
      2.00x     EI LOYDY              shape-cyan
      2.74x     hidas template        shape-cyan
      3.00x     hidas template        shape-cyan
      3.65x     hidas template        shape-cyan

  Kala pyyhkaistiin koko palkin yli, 19 kohtaa
      v4   19/19

  Yhden ARMED_FAST-kierroksen hinta 1080p:lla
      ehdokkaiden validointi   v3  32,7 ms   ->   v4  5,7 ms
      vanha taysskannaus       v3   821 ms   ->   v4  ei ajeta

  Aika palkin ilmestymisesta siihen kun A/D lahtee, yksi kierros per ajo
      v3   ei ehtinyt 5 sekunnissa, 0/6 kertaa
      v4   21, 23, 19, 22, 20, 23 ms - mediaani 22 ms, 6/6

  Pidempi ajo, useita kierroksia
      v4   6 kalaa napattu, viive joka kierroksella 20-25 ms,
           seuranta toimii, ei yhtaan poikkeusta

  Forensic-debug paalla vs pois: ei mitattavaa eroa. Jatin sen paalle,
  koska sinun tyonkulkusi perustuu siihen.


MITA EN KOSKENUT
----------------

Ohjain, vihrean reunatunnistus, SPACE-viive, palkkiehdokkaiden haku ja
forensic-debug ovat tasan v3:n koodia. Tarkistin vihrean tunnistuksen
erikseen: se osuu 2 pikselin tarkkuudella, ja kun kala peittaa toisen
reunaviivan, vara-tunnistus antaa noin 9 px virheen 78 px levealle
alueelle. Se on kunnossa, joten en muuttanut sita.


JOS JOKIN MENEE PIELEEN
-----------------------

Tiedoston alussa:

  FAST_FISH_MIN_AREA_RATIO / FAST_FISH_MAX_AREA_RATIO
      kalan kokoikkuna suhteessa palkin korkeuteen
  ARMED_SKIP_FULL_SCAN = False
      palauttaa vanhan skannauksen ARMED_FAST-tilaan

Konsolista kannattaa katsoa:

  [INSTANT-AD]   seuranta alkoi - taman pitaa tulla heti palkin jalkeen
  [INPUT] ... SendInput=1/1   nyt taman kuuluu olla 1/1, ei 0/1
