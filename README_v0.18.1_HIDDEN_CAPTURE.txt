LOCKPICK AI v0.18.1 - HIDDEN REAL CAPTURE LAUNCHERS
=====================================================

Tämän patchin idea: Command Center EXE:n EI tarvitse olla auki kun pelaat SCUMia.

Käyttö:
1) Tuplaklikkaa START_REAL_CAPTURE_HIDDEN.bat ennen pelaamista.
   - käynnistää real_sim_bridge.py recorderin taustalle
   - ei jätä Command Centeriä eikä konsoli-ikkunaa auki
   - recorder on passiivinen: se EI liikuta hiirtä eikä paina F:ää
2) Pelaa normaalisti.
3) Lopeta joko painamalla F12 tai tuplaklikkaamalla STOP_REAL_CAPTURE.bat.
4) Kun haluat analysoida datan, avaa Command Center myöhemmin ja paina FIT SIMULATOR TO REAL DATA,
   TAI käytä STOP_REAL_CAPTURE_AND_FIT.bat.

Taustalla näkyy Task Managerissa Python/py-prosessi, koska jonkin prosessin täytyy luonnollisesti lukea ruutua.
LockpickCommandCenter.exe ei kuitenkaan ole tarpeen eikä sen tarvitse olla auki.

Data tallentuu edelleen:
  data\real_bridge\samples.jsonl
  data\real_bridge\status.json
  data\real_bridge\fit_profile.json

Tämä patch ei muuta ramp/target-geometriaa, neuralia tai rewardeja.
