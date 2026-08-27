AUTOFISHING v11 FAST-FOLLOW v3 DEBUG

Tämä on kattava forensic-debug-versio juuri siihen ongelmaan, jossa:
- uusi kierros näyttää alkavan
- palkki/kala näkyy
- vihreä jää AFK:ksi tai A/D lähtee väärään suuntaan
- tracker hukkaa fish/green muutamassa framessa

TÄRKEÄ HUOMIO SUN LOKISTA
-------------------------
Lokissa näkyi:
    SendInput=0/1

Lisäksi ensimmäisellä kierroksella valittiin:
    bar=(850, 946, 1040, 126)
ja heti perään:
    Lost fish/green for 8 frames -> reacquire

Debug-versio kerää nyt datan, jolla voidaan erottaa onko vika:

A) väärässä cyan-palkissa
B) väärässä fish-template/osumassa
C) green-target tunnistuksessa
D) bar/crop geometriassa uuden kierroksen alussa
E) A/D Windows-inputissa/fokuksessa
F) trackerin suorituskykypiikissä

MITÄ DEBUG TALLENTAA RAM-MUISTIIN
---------------------------------
startup_candidates.csv
  - kaikki uuden kierroksen bar-ehdokkaat
  - bar X/Y/W/H
  - kala score/source/X
  - green mode/X/width
  - hyväksyttiinkö candidate

tracker.csv
  - jokainen aktiivinen tracker-mittaus
  - fishX
  - greenX
  - error
  - A/D/NONE
  - held A/D
  - capture ms
  - detection ms
  - failure count

input.csv
  - jokainen E/A/D/SPACE input
  - SendInput result
  - Windows LastError
  - target HWND
  - foreground HWND + title

failure_* kansiot
  - viimeiset ruutukaappaukset ENNEN ongelmaa ja ongelman aikana
  - manifest.json sisältää saman hetken tracker-metadataa

Debug ei kirjoita näitä levylle kesken kriittisen tracking-loopin.
Data pidetään RAM:ssa ja kirjoitetaan vasta F9/lopetuksessa.

MITEN TESTAAT
-------------
1. Käynnistä Kaynnista_Autofishing.bat
2. Kalasta kunnes tulee juuri se bugi.
3. HETI bugin jälkeen paina F9.
4. Autofishing-kansioon syntyy:
       debug_session_YYYYMMDD_HHMMSS.zip
5. Lähetä se ZIP takaisin ChatGPT:lle.

Sillä pystyn katsomaan frame framelta mitä scripti luuli näkevänsä ja mitä
A/D-inputille oikeasti tapahtui.
