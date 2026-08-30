# Ilmavirtalaboratorio

Selaimessa pyörivä **3D-ilmavirtaussimulaatio 24 m²:n yksiöstä**. Pohjapiirros,
mitat ja aukot on johdettu asunnon pohjakuvasta: olohuone + keittotila (OH/KT),
kylpyhuone (PSH), eteinen (ET) ja sisäänvedetty parveke. Punaisilla palloilla
merkityt poistoilmakanavat ovat mallissa OH:n ja PSH:n välisessä seinässä
50 mm katosta alaspäin.

Sovellus ratkaisee joka ruudulla puristumattoman ilman virtauksen, lämpötilan ja
kosteuden kolmiulotteisessa hilassa ja piirtää tuloksen huoneen 3D-mallin päälle.

## Käynnistys

```bash
# mikä tahansa staattinen palvelin, esim.
python3 -m http.server 8000
# avaa http://localhost:8000/index.html
```

`index.html` on generoitu tiedosto. Lähde on `src/app.html`; `node build.js`
kääräisee sen itsenäiseksi sivuksi. Ainoa ulkoinen riippuvuus on three.js r128
(cdnjs) ja IBM Plex ‑kirjasimet (Google Fonts) — kaikki muu on tiedostossa.

## Mitä voi säätää

| Ryhmä | Säädöt |
|---|---|
| Ulkoilma ja parveke | ulkolämpötila, ulkoilman kosteus, tuulen nopeus ja suunta, auringonsäteily, parvekelasitus 0–100 % |
| Ovi ja ikkunat | parvekkeen oven aukeama, yläikkunan kallistus sisäänpäin, korvausilmaventtiili, kylpyhuoneen ovi |
| Sisäilma | tavoitelämpötila ja ‑kosteus, patterin maksimiteho, termostaatti, kosteussäätö, henkilö, ruoanlaitto |
| Kylpyhuone | oma tavoitelämpötila ja ‑kosteus, lattialämmitys, suihku ja sen kosteustuotto |
| Poistoilmakanavat | kanavat A ja B erikseen 0–40 l/s, tehostus, vaipan tiiviys n₅₀ |
| Tornituuletin | puhallusnopeus 0–5, suunta, puhallusaukon korkeus, oskillointi; **raahattavissa 3D-näkymässä ja pohjapiirroksessa** |
| Visualisointi | hiukkasmäärä, leikkaustason korkeus ja suure, nuolet, kalusteet, seinäleikkaus, varjot, laskentaverkon tiheys |

Valmiit skenaariot: **Talvi**, **Tuuletus**, **Suihkun jälkeen**, **Lasitettu**, **Helle**.

Hiiri: vasen veto = kierrä, oikea/​shift = panoroi, rulla = zoom,
kaksoisklikkaus = vapauta savupilvi virtausta seurattavaksi,
tuulettimen raahaus = siirrä puhallinta.

## Laskentamalli

**Virtaus.** Puristumaton Navier–Stokes MAC‑hilassa: semi‑Lagrangen advektio,
Boussinesq‑noste `a = g(T−T_ref)/T_ref`, pyörteiden vahvistus ja SOR‑painekorjaus
muuttuvalla liikkuvuudella. Jokaisella hilakasvolla on kerroin `fr ∈ [0,1]`, joka
vastaa kasvon vapaata aukkopinta‑alaa — sama mekanismi hoitaa umpiseinän
(`fr = 0`), puoliksi auki olevan oven, kallistetun yläikkunan,
korvausilmaventtiilin, parvekelasituksen raot ja vaipan vuotoilman.

**Lähes suljetut tilat.** Kun kaikki aukot ovat kiinni, painekentän keskiarvomoodi
ei suppene SOR:lla. Sisätila ja parveke ratkaistaan siksi lisäksi kahden solmun
verkkona (ulko → parveke → sisätila), jolloin massatase toteutuu tarkasti ja
paine‑ero on fysikaalisesti oikea eikä iteraatiomäärästä riippuva.

**Reunaehdot.** Ulkoilman paine on `½ρU²C_p` plus hydrostaattinen poikkeama
suhteessa vertailulämpötilaan, joten sekä tuulen suunta että savupiippuvaikutus
vaikuttavat. `C_p` vaihtelee +0,70:stä (suoraan julkisivua vasten) −0,30:een
(julkisivun suuntainen tuuli).

**Vaipan vuotoilma** noudattaa potenssilakia `q = C·Δp^0,65`, jossa `C`
kalibroidaan n₅₀‑arvosta ja linearisoidaan 10 Pa:n käyttöpisteessä.

**Lämpö ja kosteus** kulkevat skalaareina virtauksen mukana. Pintojen läpi
johtuu lämpöä U‑arvojen mukaan (julkisivu 0,17, ikkuna 1,00, ovi 1,10,
välipohja 0,42, väliseinä 0,55, parvekerakenteet 2,60, parvekelasitus 4,00 W/m²K).
Suhteellinen kosteus lasketaan Magnuksen kaavalla, ja kosteus tiivistyy
ikkunapinnalle, kun pinnan lämpötila alittaa kastepisteen. Patteri ja
lattialämmitys ovat PI‑säädettyjä; oleskeluvyöhykkeen mittaus on 1,1 m:n
korkeudella vähintään 0,6 m irti seinistä. Vedon tunne on ISO 7730:n
`DR`‑indeksi. Lisäksi kuljetetaan **ilman ikää**, joka kertoo paikallisen
ilmanvaihdon tehokkuuden.

## Tarkistettuja arvoja

Verkolla 0,15 m (68 × 31 × 22, ~23 300 ilmasolua), sisätilat 24,2 m²:

| Tilanne | Tulos | Vertailu |
|---|---|---|
| Kaikki kiinni, poisto 22 l/s, n₅₀ = 2 | Δp −22 Pa, korvausilma 22 l/s | potenssilaki antaa −19…−23 Pa |
| Parvekkeen ovi auki, ΔT 11 K | 299 l/s kaksisuuntaista vaihtoa | `⅓C_d·W·√(gΔT·H³/T)` ≈ 310 l/s |
| Ovi 25 % / 50 % / 100 % | ACH 1,3 / 1,9 / 17,8 | aukkopinta‑ala skaalaa lineaarisesti |
| Lasitettu parveke, ulkona +2 °C | parveke +10 °C, auringolla +12,5 °C | tyypillinen suomalainen lasitettu parveke |
| Ilman nopeus oleskeluvyöhykkeellä, ei puhallinta | 0,03–0,09 m/s | tyyni huone |

## Tiedostot

```
src/app.html   koko sovellus (tyylit, käyttöliittymä, ratkaisin, 3D-näkymä)
build.js       kääräisee src/app.html itsenäiseksi index.html-sivuksi
index.html     generoitu, avattavissa suoraan selaimessa
```

Ratkaisimen voi ajaa myös ilman selainta: `src/app.html`:n kolme ensimmäistä
`<script>`-lohkoa ovat puhdasta JavaScriptiä ilman DOM- tai three.js-riippuvuutta.
