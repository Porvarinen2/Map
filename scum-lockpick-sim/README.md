# SCUM Tiirikkapenkki

Simulaatio SCUMin lukkominipelista ja autolockpickista. Sama 2,75 sekunnin
ikkuna kuin pelissa, mutta piilotettu sweetspot on nakyvissa ja naet mita
tiirikka oikeasti tekee sen aikana.

Kaksi tapaa ajaa:

- **Selain** &mdash; `web/scum_lockpick_sim.html`. Avaa tiedosto selaimessa.
  Animoitu lukko, paljastettava sweetspot, koetinkuvaaja ja eraajopenkki.
- **Python** &mdash; `sim/lockpick_sim.py`. Ei kuvaa, mutta ajaa satoja
  sessioita sekunneissa ja vertailee asetuksia.

Molemmat ajavat samaa mallia ja samaa hakualgoritmia.

## Selainsimulaatio

Avaa `web/scum_lockpick_sim.html`. Mitaan ei tarvitse asentaa.

Vasemmalla on lukkonakyma:

- **punainen tiirikka** seuraa hiirta, **musta avaimenreika** kertoo pesan kaannon
- **valkoinen kaari** on jaljella oleva aika
- **messinkinen vyo** lukon ymparilla on palautealue: mita pidempi piikki,
  sita enemman pesa antaa periksi siina kohdassa
- **vihrea kiila** on avaava ydin. Sen loytaminen on koko tehtava.

Oikealla on penkki. Jokaisen saatimen alla lukee vastaava `asetukset.json`-avain,
joten mita taalla loytyy, sen voi siirtaa suoraan helperiin.

Kolme valmista pinoa:

| Pino | Mita se on |
|---|---|
| Helperi 1.8 | nykyisen `asetukset.json`-tiedoston arvot |
| Pidempi F | sama, mutta `maximum_F_hold_ms` nostettuna |
| Simulaation paras | naista kolmesta paras yhdistelma |

Ohjaus-valikosta voi vaihtaa **kasiohjaukseen**: liikuta hiirta lukon paalla ja
pida `F` pohjassa. Silloin naet itse, miten vaikea ydin on osua sokkona.

## Python-simulaattori

```bash
cd sim
python lockpick_sim.py --tier basic --skill 1 --sessions 400
python lockpick_sim.py --compare-orders --tier medium
python lockpick_sim.py --compare-tiers --skill 2
python lockpick_sim.py --sweep-step 4 6 8 10 12 --tier enforced
python lockpick_sim.py --sweep-latency 20 50 90 140
python lockpick_sim.py --settings ../../asetukset.json --tier basic
```

`--settings` lukee helperin oman asetustiedoston ne avaimet, jotka simulaatio
tuntee, joten nykyiset arvot voi ajaa lapi sellaisenaan.

Testit:

```bash
python test_sim.py
```

Windowsissa `Aja_Simulaatio.bat` kaynnistaa perusajon.

## Mita simulaatio kertoi Helperi 1.8:sta

Ajettuna `asetukset.json`-tiedoston arvoilla (Basic-lukko, thievery basic,
400 sessiota, enintaan 6 yritysta) tulos oli **0,0 % avattu**. Syyt loytyivat
kolme:

**1. `maximum_F_hold_ms: 320` on lyhyempi kuin taysi kaanto.**
Tassa mallissa pesa kaantyy 260 astetta sekunnissa, joten 90 asteen kaanto
kestaa 346 ms. Ohjain vapauttaa F:n 320 ms:n kohdalla eli 26 ms ennen maalia.
Lukko ei voi aueta millaan muulla asetuksella niin kauan kuin tama katto on
alle taydan kaannon keston. Kynnys on jyrkka:

| `maximum_F_hold_ms` | avattu |
|---|---|
| 300 ms | 0,0 % |
| 350 ms | 93,0 % |

**2. Hiiri liikkuu 33 astetta sekunnissa.**
`scan_mouse_max_units_per_pulse: 28` kertaa `0.035` astetta per yksikko jaettuna
`mouse_settle_ms: 30`:lla on 33 °/s. Siirtyminen keskelta vasempaan reunaan
kestaa 2,4 sekuntia &mdash; suurin osa koko 3,25 sekunnin ikkunasta menee
pelkkaan ajamiseen ennen ensimmaista F-testia.

**3. Hakutapa "vasemmalta oikealle" maksaa taman matkan joka kierroksella.**
Kun sama haku aloitetaan nykykohdasta, matka jaa pois:

| Hakutapa | avattu | 1. yrityksella |
|---|---|---|
| vasemmalta oikealle | 58,0 % | 0,0 % |
| keskelta ulos | 75,0 % | 20,7 % |
| nykykohdasta | 93,3 % | 32,3 % |

(Basic-lukko, `maximum_F_hold_ms` korjattuna, muuten helperin arvot.)

Korjausehdotus `asetukset.json`-tiedostoon:

```json
"maximum_F_hold_ms": 700,
"scan_mouse_max_units_per_pulse": 120,
"mouse_settle_ms": 16,
"scan_step_degrees": 8.0
```

Nailla arvoilla simulaatio avaa Basic-lukon 100 % sessioista ja 82 %
ensimmaisella yrityksella. **Nama ovat simulaation lukuja, eivat pelin.**
Pelitesti tarvitaan edelleen &mdash; erityisesti pesan todellinen kaantonopeus
pitaa mitata, koska juuri se maaraa kohdan 1 kynnysarvon.

## Rakenne

```
sim/lockpick_model.py   lukon fysiikka: palautekayra, kaanto, kuluminen, aika
sim/solver.py           autolockpick: nakomalli, hakusaanto, tilakone
sim/lockpick_sim.py     komentorivi, eraajot ja vertailut
sim/test_sim.py         tarkistustestit
web/scum_lockpick_sim.html   selainsimulaatio (yksi tiedosto)
docs/MEKANIIKKA.md      mika on lahteista ja mika on taman mallin arviota
```

## Rajaukset

Simulaation prosentit kertovat asetusten keskinaisesta paremmuudesta taman
mallin sisalla. Ne eivat ole pelin onnistumisprosentti. Palautealueen leveys,
kayran muoto, pesan kaantonopeus ja kulumisnopeudet ovat kalibrointia, eivat
pelin lahdekoodista luettuja arvoja. Erittely on tiedostossa
[docs/MEKANIIKKA.md](docs/MEKANIIKKA.md).
