AUTOFISHING v11 - RESPONSIIVISUUSKORJAUS
========================================

Tama on sinun v11:si. Ohjain, kalan ja vihrean tunnistus, SPACE-logiikka ja
kaikki asetukset ovat tasmalleen ennallaan. Muutettu on vain se, kuinka usein
skripti ehtii katsoa ruutua sina aikana kun se odottaa kalan ilmestymista.

Alkuperaisesta koodista on poistettu 7 rivia.


MIKSI SE JOSKUS EI LAHTENYT PERAAN
----------------------------------

E:n painamisen jalkeen v11 menee ARMED_FAST-tilaan ja etsii kalaa. Mutta
ARMED_FAST ei ole FISHING, joten silmukka putosi joka kierroksella myos
vanhaan skannaushaaraan, joka 0,12 sekunnin valein kavi koko ruudun lapi
template-haulla. Mitattuna 1080p-ruudulla:

    detect_minigame   250 ms
    detect_waiting    177 ms
    detect_bite       177 ms
    detect_cast       196 ms
    -------------------------
                      800 ms peraperaa

Sen paalle ARMED_FAST teki itse joka kierroksella:

    fast_track_minigame (kala-template, 2 ref x 5 skaalaa)    26 ms
    koko ruudun cyan-palkkihaku                               20 ms
    fast_track_minigame uudestaan loydetylle palkille          26 ms

Eli odotellessaan kalaa skripti ehti oikeasti katsoa palkkia noin kerran
sekunnissa. Jos kala sattui ilmestymaan kesken sen 800 ms skannauksen, mitaan
ei tapahtunut ennen kuin skannaus loppui.

Mitattuna, yksi kierros per ajo, kymmenen ajoa:

    v11 alkuperainen   36, 40, 42, 34, 699, 36, 35, 726, 36, 56 ms
    v11 korjattu       37, 37, 38, 41, 38, 37, 38, 37, 40, 40 ms

Nopeat kierrokset olivat jo nopeita - siksi se "toimi aika hyvin". Korjaus
poistaa ne kierrokset joissa se vain jai istumaan.


MITA MUUTETTIIN - KOLME ASIAA
-----------------------------

1. Vanhaa koko ruudun skannausta ei ajeta ARMED_FAST-tilassa.
   E on jo painettu, joten siella ei ole mitaan mita se tarvitsisi.
   Tama poistaa sen 800 ms.

   Turvaverkko: jos nappaus ei tule 12 sekuntiin, skannaus palaa itsestaan.
   Alkuperaisessa v11:ssa se skannaus oli ainoa ulospaasy ARMED_FASTista jos
   kala ei koskaan tullut, joten sita ei saa poistaa kokonaan.

2. Koko ruudun cyan-palkkihakua ei tehda joka kierroksella.
   Palkki ei liiku kierrosten valilla, joten kun sen paikka on jo tiedossa
   edelliselta kierrokselta, riittaa etsia se uudestaan 0,25 s valein.
   Jos paikkaa ei viela tunneta, haku tehdaan kuten ennenkin joka kierros.

3. Kallis kala-template ajetaan vasta kun kala on oikeasti ruudulla.
   Odotellessa on vain yksi kysymys: onko kala jo tullut. v11 vastasi siihen
   ajamalla koko template-haun (26 ms). Nyt sita edeltaa varitesti, joka
   maksaa 0,33 ms.

   Kala on kirkas cyan-kuvake. Palkin oma taytto on samaa savya mutta tumma -
   mitattuna omasta minigame_example.png:staan kalan pikselit ovat
   kirkkaudeltaan 65..237 (mediaani 237), palkin taytto korkeintaan 74. Testi
   etsii siis kirkkaan cyan-tapla palkin sisalta.

   Tama on PELKKA PORTTI. Kun se sanoo kylla, ajetaan tasan sama v11:n
   template-haku samasta framesta, joten tunnistuksen tarkkuus ei muutu
   millaan tavalla. Ja jos portti sanoo ei yhtajaksoisesti 0,5 sekuntia,
   template-haku ajetaan joka tapauksessa - portti ei voi sokeuttaa skriptia.


ASETUKSET
---------

Kaikki uudet asetukset ovat tiedoston alussa FAST_ARMED-asetusten alla:

  ARMED_SKIP_FULL_SCAN            True    kohta 1
  ARMED_SKIP_FULL_SCAN_SECONDS    12.0    turvaverkko
  ARMED_FULL_REACQUIRE_INTERVAL   0.25    kohta 2
  ARMED_USE_FISH_GATE             True    kohta 3
  ARMED_GATE_SAFETY_INTERVAL      0.50    portin turvaverkko

Jos jokin menee pieleen, laita ARMED_USE_FISH_GATE = False ja
ARMED_SKIP_FULL_SCAN = False, niin kaytos on tasan alkuperaisen v11:n.


KONSOLI
-------

Samat rivit kuin v11:ssa. Katso naita:

  [CAST]                             E painettiin
  [STATE] ... ARMED_FAST             odotus alkoi
  [STATE] ... -> FISHING IMMEDIATELY kala loytyi, seuranta alkoi

Kahden viimeisen valinen aika on se odotus. Sen kuuluu nyt olla luokkaa
kymmenia millisekunteja siita hetkesta kun palkki ilmestyy.
