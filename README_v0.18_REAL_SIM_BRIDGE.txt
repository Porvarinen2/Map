LOCKPICK AI v0.18.0 – REAL ↔ SIM BRIDGE
=========================================

MITÄ TÄMÄ PÄIVITYS TEKEE
-------------------------
Tämä päivitys lisää Command Centeriin REAL ↔ SIM BRIDGE -kerroksen, jolla oikeasta SCUM-lockpickauksesta kerätään ruutudataa ja sovitetaan simulaattorin havaittavaa fysiikkaa lähemmäksi peliä.

Neural EI saa targetin paikkaa, rampin rajoja, ramp depth -arvoa eikä fitissä pääteltyä centeriä syötteenä. Fixed per-lock geometry pysyy ennallaan. Bridge kalibroi vain sellaisia asioita, jotka oikeasti voidaan havaita ruudulta:
- oma X-sijainti (vision confidence -portilla)
- näkyvä lock turn
- näkyvä turn delta / peak
- F TAP / F HOLD ja todellinen F-pohjassaoloaika
- lock-turnin palautuminen F:n jälkeen
- SUCCESS
- lukkotyyppi (Auto classifier tai käsin valittu)

STATIC-F-SÄÄNTÖ SÄILYY:
F:n aikana X ei liiku. Recorder ei injektoi F:ää eikä hiirtä; se seuraa passiivisesti mitä SCUMissa tapahtuu.

COMMAND CENTER – UUSI REAL ↔ SIM BRIDGE -PANEELI
------------------------------------------------
1. Valitse Capture lock type: Auto tai suoraan Rusted / Basic / Medium / Enforced.
2. Avaa SCUMin lockpick-minigame.
3. Paina START REAL CAPTURE.
4. Pelaa itse tai anna live-agentin pelata. Bridge tallentaa jokaisen F-toiminnon ruudun perusteella.
5. STOP lopettaa tallennuksen. F12 toimii myös recorderin stop-hotkeynä.
6. Paina FIT SIMULATOR TO REAL DATA.
7. Command Center näyttää lock-kohtaisesti:
   - REAL probes
   - episode count
   - REAL↔SIM match
   - Turn tau scale
   - Return tau scale
   - Ramp response gain
   - REAL-vs-SIM response-käyrän

FIT-PROFIILI
------------
data\real_bridge\fit_profile.json

FREELEARN-trainer lukee tämän automaattisesti. Fit voidaan tehdä myös kesken simutreenin: uudet simulator-episodit alkavat käyttää viimeisintä aktiivista fit-profiilia ilman PPO-checkpointin wipeä.

Bridge EI automaattisesti muuta:
- Target half-width
- Ramp left / Ramp right
- Curve exponentia geometriamuutoksena
- Targetin sijaintijakaumaa

Eli sun Geometry Editorissa määrittelemät fixed per-lock ramp/target-koot pysyvät fixedinä. Jos oikea data ei sovi niihin hyvin, match jää heikommaksi – se on tarkoituksella näkyvä varoitussignaali eikä automaattinen geometry-muutos.

FITIN TURVARAJAT
----------------
Lock-kohtainen reality profile aktivoituu vasta kun dataa on riittävästi ja se läpäisee confidence/match-portit. Muutama satunnainen tai huonosti tunnistettu probe ei siis saa suoraan muuttaa simulaattoria.

Recorder käyttää lockpick_learner.py:n olemassa olevaa SCUM ScreenVisionia ja kalibraatiota. Jos X-kalibraatio tai lock UI detection on huono, samplet saavat matalan confidence-arvon eikä niitä käytetä fitissä.

DATA
----
data\real_bridge\samples.jsonl       = append-only oikean pelin probe-data
data\real_bridge\status.json         = recorder/live status
data\real_bridge\fit_profile.json    = simulaattoriin käytettävä reality-fit
data\real_bridge\latest_replay.json  = viimeisin REAL vs SIM action replay
data\real_bridge\recorder.log        = recorderin logi

WIPE SIMULATION DATA ei poista REAL bridge -dataa.
WIPE ALL DATA poistaa myös REAL bridge -datan.
Wipe on nyt blokattu myös REAL capture -prosessin aikana.

ASENNUS
-------
1. Paina STOP treenille.
2. Paina STOP REAL CAPTURE jos se on käynnissä.
3. SULJE LockpickCommandCenter.exe kokonaan ennen replacea. Muuten Windows voi ilmoittaa "Kansio käytössä".
4. Pura tämän ZIPin sisältö suoraan C:\Lockpick\-kansion juureen ja korvaa samannimiset tiedostot.
5. freelearn_config.json EI ole tässä update ZIPissä, joten sun nykyiset ramp/target/F-economy-asetukset eivät nollaannu.
6. Käynnistä START_COMMAND_CENTER.bat.

MANUAALISET VARAKOMENNOT
------------------------
REAL_BRIDGE_CAPTURE_AUTO.bat = sama recorder ilman Command Center -nappia
REAL_BRIDGE_FIT.bat          = ajaa fitin ilman Command Center -nappia

HUOMIO
------
REAL↔SIM match ei ole SCUM-success-prosentti. Se kertoo kuinka hyvin current simulatorin observable response vastaa tähän mennessä kerättyä oikean pelin screen-dataa.
