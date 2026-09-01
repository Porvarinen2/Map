# Ilmavirtalaboratorio

Selaimessa pyörivä **3D-ilmavirtaussimulaatio kalustetusta 24 m²:n yksiöstä**.
Pohjapiirros, mitat ja aukot on johdettu asunnon pohjakuvasta: olohuone +
keittotila (OH/KT), kylpyhuone (PSH), eteinen (ET) ja sisäänvedetty parveke
3. kerroksessa. Punaisilla palloilla merkityt poistoilmakanavat ovat OH:n ja
PSH:n välisessä seinässä 50 mm katosta alaspäin; kylpyhuoneen poisto on katossa
suihkun yläpuolella.

Sovellus ratkaisee joka ruudulla puristumattoman ilman virtauksen, lämpötilan ja
kosteuden kolmiulotteisessa hilassa. **Kalusteita voi siirrellä ja pyörittää
Sims-tyyliin, ja ne estävät ilman kulkua oikeasti** — jokainen huonekalu
rasteroidaan laskentahilaan.

## Käynnistys

```bash
python3 -m http.server 8000     # tai mikä tahansa staattinen palvelin
# avaa http://localhost:8000/index.html
```

`index.html` on generoitu. Lähde on `src/app.html`; `node build.js` kääräisee sen
itsenäiseksi sivuksi. Ainoa ulkoinen riippuvuus on three.js r128 (cdnjs) ja
IBM Plex ‑kirjasimet.

## Kalusteet

Kaikki alla olevat ovat siirrettäviä ja pyöritettäviä, ja ne voi laittaa
varastoon (pois asunnosta). Kiinteitä ovat vain keittiö, eteisen kaapit,
kylpyhuoneen kalusteet ja patteri.

| Kaluste | Mitat | Huom |
|---|---|---|
| Parvisänky | 207 × 152 × 214 cm | patja tukkii ilmavirran 1,7 m korkeudella |
| Setup: pöytä, kone, näytöt | 192 × 82 cm | IKEA TROTTEN 160 × 80 × 75 + Corsair 5000D + 2 näyttöä, mikki, kuulokkeet — **liikkuu yhtenä pakettina** |
| Pelituoli (sähkörecliner) | 85 × 95 × 105 cm | |
| Sohva | 171 × 98 × 83 cm | istuinkorkeus 48 cm |
| TV-taso + televisio | 180 × 50 × 60 cm | TV 55" seuraa tasoa automaattisesti |
| Sohvapöytä | 90 × 55 × 45 cm | |
| Minijääkaappi | 54 × 54,8 × 84,5 cm | |
| TV-tietokone | 21 × 45 × 45 cm | |
| Pyykinpesukone | 60 × 60 × 85 cm | vain kylpyhuoneessa, oven vieressä |

**Muokkaustila** (yläpalkin *Muokkaa* tai Kalusteet-välilehti): klikkaa
valitaksesi, raahaa siirtääksesi, **R** / **Shift+R** pyörittää 15°, **Del**
siirtää varastoon, **Esc** poistaa valinnan. Kalusteita voi raahata myös
pohjapiirroksesta, ja ne saa sijoittaa myös eteiseen ja parvekkeelle.

Sijoitus tarkistetaan solu solulta: seinän tai toisen kalusteen päälle ei voi
pudottaa, mutta työpöytä mahtuu parvisängyn alle koska törmäystarkistus on
kolmiulotteinen. *Vapaa sijoittelu* ‑valinta sallii kalusteiden mennä toistensa
läpi, ja yksittäisen kalusteen voi **lukita** paikalleen niin ettei se liiku
vahingossa.

**Asettelut tallentuvat** selaimeen: viimeisin järjestys palautuu automaattisesti
kun avaat simulaation uudelleen, ja asettelun voi tallentaa nimellä ja ladata
myöhemmin Kalusteet-välilehdeltä.

## Laitteiden teho ja lämmöntuotto

Kaikki laitteiden ottama sähköteho muuttuu lämmöksi huoneeseen. Lämpö syötetään
laitetta ympäröiviin ilmasoluihin, joten esimerkiksi koneen lämpö nousee pöydän
takaa kohti kattoa ja päätyy poistokanaviin.

**Setup-tietokone** — i9-14900K, RTX 3070 8GB, 192GB DDR5, 3 levyä, H150i + 13 tuuletinta, 1000 W:

| Kuormitustaso | CPU | GPU | Verkosta | Näyttöjen kanssa |
|---|---|---|---|---|
| Työpöytä | ~35 W | ~18 W | 120 W | **190 W** |
| Keskikova | ~95 W | ~165 W | 355 W | **425 W** |
| Maksimi (raskaat pelit) | ~165 W | ~225 W | 505 W | **575 W** |

**TV-tietokone** — i5-8400, GTX 1060 6GB, 32GB DDR4:
lepotila **55 W**, YouTube ja elokuvat **85 W**, pelit **230 W**.

Lisäksi televisio 110 W, minijääkaappi 20 W (keskiteho), pyykinpesukone 200 W ja
tuuletin 0–60 W. Mittaripaneeli näyttää yhteenlasketun lämpökuorman reaaliajassa
— sillä on selvä vaikutus siihen, tarvitseeko patteri lämmittää lainkaan.

## Laskentamalli

**Virtaus.** Puristumaton Navier–Stokes MAC‑hilassa: semi‑Lagrangen advektio,
Boussinesq‑noste, pyörteiden vahvistus ja SOR‑painekorjaus muuttuvalla
liikkuvuudella. Jokaisella hilakasvolla on kerroin `fr ∈ [0,1]`, joka vastaa
kasvon vapaata aukkopinta‑alaa — sama mekanismi hoitaa umpiseinän, puoliksi auki
olevan oven, kallistetun yläikkunan, korvausilmaventtiilin, parvekelasituksen
raot, vaipan vuotoilman **ja kalusteet**.

**Aukot.** Isot aukot (ovi, yläikkuna, lasitus) avataan geometrisena nauhana:
puoliksi auki oleva ovi jättää vapaaksi `sin(kulma)` osuuden aukosta, joten
ilmanvaihtuvuus skaalautuu vapaan pinta‑alan mukaan. Pienet kuristetut reitit
(korvausilmaventtiili, vaipan vuotoilma) mallinnetaan kalibroituna lineaarisena
virtausvastuksena.

**Lähes suljetut tilat.** Kun kaikki aukot ovat kiinni, painekentän keskiarvomoodi
ei suppene SOR:lla. Sisätila ja parveke ratkaistaan siksi lisäksi kahden solmun
verkkona (ulko → parveke → sisätila), jolloin massatase toteutuu tarkasti ja
paine‑ero on fysikaalinen eikä iteraatiomäärästä riippuva.

**Reunaehdot.** Parvekkeen edessä on 4,6 m ulkoilmaa ja 2,2 m taivasta: uloin osa
on säiliö, jossa tuulen nopeus noudattaa rajakerrosprofiilia (3. kerros), ja
julkisivun edessä oleva 1,25 m lasketaan täysin. Ulkoilman paine on `½ρU²C_p`
plus hydrostaattinen poikkeama, joten sekä tuulen suunta että savupiippuvaikutus
vaikuttavat. Merkkihiukkasilla on oma budjetti ulkoilmalle, koska tuuli pyyhkäisee
ne alueen läpi sekunnin murto-osassa.

**Lämpö ja kosteus** kulkevat skalaareina virtauksen mukana. Pintojen läpi johtuu
lämpöä U‑arvojen mukaan (julkisivu 0,17, ikkuna 1,00, ovi 1,10, välipohja 0,42,
väliseinä 0,55, parvekerakenteet 2,60, parvekelasitus 4,00 W/m²K). Suhteellinen
kosteus lasketaan Magnuksen kaavalla ja kosteus tiivistyy ikkunapinnalle
kastepisteen alittuessa. Lisäksi kuljetetaan **ilman ikää** ilmanvaihdon
tehokkuuden mittarina, ja vedon tunne raportoidaan ISO 7730:n DR‑indeksinä.

## Tarkistettuja arvoja

Verkolla 0,15 m (84 × 31 × 28, ~27 000 ilmasolua), sisätilat 24,2 m²:

| Tilanne | Tulos | Vertailu |
|---|---|---|
| Kaikki kiinni, poisto 28 l/s, n₅₀ = 2 | Δp −17 Pa, korvausilma 28 l/s | potenssilaki −16…−19 Pa |
| Parvekkeen ovi auki, ΔT 11 K | 276 l/s kaksisuuntaista vaihtoa | `⅓C_d·W·√(gΔT·H³/T)` ≈ 310 l/s |
| Ovi 25 % / 50 % / 100 % | 112 / 193 / 276 l/s | skaalautuu vapaan aukon `sin(kulma)` mukaan |
| Korvausilmaventtiili kiinni | Δp −42 Pa | tiiviin asunnon tyypillinen ongelma |
| Lasitettu parveke, ulkona +2 °C | +10 °C, auringolla +12,5 °C | tyypillinen suomalainen lasitettu parveke |
| Talvi −12 °C, ovi 60 % auki | oleskeluvyöhyke 19,9 °C, lattialla 17,8 °C | kylmä ilma valuu lattiaa pitkin |

## Käyttöliittymä

Vasemmassa reunassa kahdeksan välilehteä: **Sää**, **Aukot**, **Ilmanvaihto**,
**Ilmasto**, **Laitteet**, **Kalusteet**, **Näkymä** ja **Tiedot**. Yläpalkissa
toisto, nopeus, skenaariot ja kamerakulmat. Näyttämöllä värikartta, mittarit,
pohjapiirros ja aikasarjat — kortit voi taittaa kokoon otsikosta.

### Kameratilat

| Tila | Ohjaus |
|---|---|
| **Kierto** (oletus) | vasen veto kiertää, oikea/shift panoroi, rulla zoomaa |
| **Vapaa** | **WASD** lentää, **Space**/**C** ylös ja alas, **Shift** nopeasti, rulla säätää nopeutta, hiiri katsoo |
| **Kävely** | **WASD** kävelee 1,65 m katsekorkeudella, **Shift** juoksee, **C** menee kyykkyyn, hiiri katsoo |

Kävelytilassa on pystysylinterimäinen törmäystarkistus (säde 19 cm) seiniin,
kalusteisiin ja kiinteisiin kalusteisiin — hilakerros kerrallaan, joten myös
pöytätaso ja parvisängyn pohja tuntuvat. Kyykyssä mahtuu matalampiin paikkoihin.
Parvekkeelle pääsee vain jos ovi on auki. Kierto- ja kävelytilassa seiniä ei
leikata pois, ja katossa on valaisimet.

Pikanäppäimet **1** / **2** / **3** vaihtavat tilaa, **L** lukitsee hiiren
(vapaa katselu ilman painallusta), **Esc** vapauttaa lukituksen, **P**
pysäyttää simulaation. Kosketuslaitteilla vapaassa ja kävelytilassa on
peukalo-ohjain vasemmassa alakulmassa.

Kaksoisklikkaus vapauttaa savupilven virtausta seurattavaksi.

## Tiedostot

```
src/app.html   koko sovellus (tyylit, käyttöliittymä, ratkaisin, kalusteet, 3D)
build.js       kääräisee src/app.html itsenäiseksi index.html-sivuksi
index.html     generoitu, avattavissa suoraan selaimessa
```

Ratkaisimen voi ajaa ilman selainta: `src/app.html`:n kolme ensimmäistä
`<script>`-lohkoa ovat puhdasta JavaScriptiä ilman DOM- tai three.js-riippuvuutta.
