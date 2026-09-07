# Pelaajadata 2026-09-06 — kalibrointi

Lahde: F7 PLAYER RECORDING, 97.50 s.

## Puhdistettu aineisto

Recorderin vanha attempt-segmentointi loi 27 yritysta, mutta 13 niista sisalsi
0 F-painallusta ja oli timer/running-flickeria. Varsinaisia manuaalisia
avausyrityksia oli **14**, ja kaikki 14 paatyivat noin 97–105 asteen
lukkopesakaantoon.

- oikeita avausyrityksia: 14
- onnistuneita: 14 / 14
- F-testeja oikeissa yrityksissa: 66
- F-testeja per avaus: mediaani 4.5
- avausyrityksen kesto: mediaani noin 2.63 s
- F-pidon kesto: mediaani noin 423 ms
- final F-pito: mediaani noin 452 ms

## Tärkein ajoituslöydös

Selvissa ensimmaisissa ramppiosumissa, joissa F alkoi lahelta neutraalia:

- +3 deg vaste: 67–173 ms, mediaani noin 109 ms
- +5 deg vaste: 68–173 ms, mediaani noin 109 ms
- +10 deg vaste: 117–201 ms, mediaani noin 141 ms
- +20 deg vaste: 166–270 ms, mediaani noin 228 ms

Vaarissa kohdissa (peak <5 deg) pelaaja piti F:aa 229–385 ms, mediaani
noin 307 ms.

Vertailu automaattiin: F8-debugissa vanha automaatti piti F:aa keskimaarin
noin 58 ms, jolloin yksikaan viimeisen debug-ikkunan 132 F-testista ei ehtinyt
nayttaa yli ~3.4 deg vastetta. Tama selittaa miksi ramppi ei lukittunut.

## 1.3-saannot

- search minimum F hold: max(120 ms, 60 ms + 4 x toteutunut framevali)
- stall: vahintaan konfiguroitu raja TAI noin 3.2 toteutunutta framevalia
- scan-step learning: pois oletuksena
- paikallishaun improvement margin: 1.5 deg
- near-equal band: +/-2.5 deg ennen jyrkkaa suunnanvaihtoa
- 80+ deg FINISH vaatii saman F:n +3 deg vastetta; 90+ deg aina FINISH
- auto F hard cap enintaan 1600 ms

Tavoite on kopioida pelaajan olennaista käyttäytymistä: anna F:lle riittavasti
aikaa nayttaa vaste, ja kun rampilla ollaan syvalla, lopeta turha sahaaminen.
