# SCUM Tiirikkapenkki

> **LIVE 3.0 - YKSINKERTAINEN:** ohjain on kirjoitettu uusiksi kolmasosaan
> entisesta koosta. Skannaus napauttaa F:aa lyhyesti ja tasaisesti, ja vasta
> kun lukkopesa kaantyy, F painetaan pohjaan. Kaikki saadot ovat yhdessa
> lohkossa tiedoston `live/lockpick_control.py` alussa - ja
> [SAADOT.txt](SAADOT.txt) kertoo yhdella sivulla, mita mikin luku tekee ja
> mita muuttaa jos jokin ei toimi.

```
tap, tap, tap, tap, taap, taaaap, taaaap, AUKI
```

**SKANNAUS** - askel oikealle, lyhyt F-napautus, katsotaan liikkuiko
lukkopesa. Ei liikkunut -> askel oikealle ja uusi napautus. Kaikki
napautukset ovat samanmittaisia ja kaikki askeleet yhta pitkia.

**RAMPPI** - lukkopesa ja sen musta avaimenreika kaantyi, eli oikea kohta
loytyi. Nyt F on pohjassa niin kauan kuin pesa kaantyy. Kun se pysahtyy,
nykaistaan hieman ja painetaan uudelleen.

Painallusten pituutta **ei ole kasketty mihinkaan**. Se seuraa siita, kuinka
kauan pesa jaksaa kaantya: kaukana se pysahtyy heti (tap), lahella se kaantyy
pitkaan (taaaap). Kuvio syntyy siis itsestaan, eika sita tarvitse virittaa.

---

Kolme osaa, jotka ajavat samaa lukkomallia ja samaa hakulogiikkaa:

| Kansio | Mika | Ajetaan |
|---|---|---|
| `live/` | **ruudunlukija, joka avaa oikean lukon pelissa** | Windows + CMD |
| `web/` | selainsimulaatio, jossa piilotettu sweetspot nakyy | mika tahansa selain |
| `sim/` | eraajosimulaattori asetusten viritykseen | mika tahansa Python |

Ideana on, etta pelissa ajettava logiikka on se, joka on ensin todistettu
toimivaksi. `live/test_gameplay.py` ajaa tunnistuksen ja ohjaimen **oikean
pelivideon 47 kehysta** vasten, `live/test_live.py` ajaa ohjaimen simuloitua
lukkoa vasten ja `live/test_vision.py` tunnistuksen pelin ruutukaappauksia
vasten.

> **Huom:** `web/`-selainsimulaatio havainnollistaa lukon mekaniikkaa ja on
> yha ajantasainen siina, mutta sen oma ratkaisija on vanhempaa mallia eika
> ole sama kuin `live/lockpick_control.py`. Pelissa ajettava logiikka on
> `live/`-kansiossa, ja se todennetaan `live/`-testeilla. Selainsimulaatiota
> kannattaa katsoa siksi, mita lukko tekee - ei siksi, miten botti sen ratkaisee.

---

## 1. Live: lukon avaaminen pelissa

```
cd live
python autolockpick_live.py
```

Windowsissa helpompi tapa on `Aja_Live.bat`. `Tarkista_Tunnistus.bat` ajaa
saman `--probe`-tilassa ja `Aja_Testit.bat` ajaa kaikki testit.

    F11   aloita / tauota
    F9    lopeta
    F7    pelaajanauhoitus paalle / pois
    F8    tallenna debug-paketti

`Tee_Raportti.bat` tekee viimeisimmasta debug-paketista tai
pelaajanauhoituksesta HTML-raportin ja avaa sen selaimeen: se piirtaa
jokaisesta yrityksesta lukkopesan kaannon, F:n pidon ja hiiren paikan
samalle aikajanalle. Sita kannattaa katsoa aina kun jokin ei toimi.

Ohjelma piirtaa CMD-ikkunaan tilanteen: tiirikan kulman, lukkopesan kaannon,
jaljella olevan ajan, hakuvaiheen ja tunnistuksen pikselimaarat.

### Aloita aina tasta

```
python autolockpick_live.py --probe
```

`--probe` lukee ruutua **lahettamatta yhtaan hiiren tai nappaimen syotetta**.
Avaa pelin lukkoruutu ja katso, etta rivi `tunnistus` nayttaa jarkevat luvut ja
etta `tiirikka`-kulma seuraa hiirta. Vasta kun se toimii, aja ilman `--probe`.

Jos tunnistus ei loyda lukkoa, saada `live_asetukset.json`-tiedoston
`vision`-osiota: `lock_radius_fraction` (lukon sade jaettuna ruudun
korkeudella) ja `center_offset_x` / `center_offset_y`.

### Tiirikkaa ei tunnisteta lainkaan

Tama on koko ohjelman tarkein rakenteellinen valinta. Tiirikka on ohut, se voi
olla eri tyokalu (hiuspinni, hakaneula, improvised lockpick) ja se nakyy eri
kulmissa. Sen tunnistus oli ketjun epavarmin kohta, ja **sita ei tarvita**:

```
LUKKO ON AINOA MITTARI

  kaanto = 0        -> vaara kohta, siirry eteenpain
  kaanto = vahan    -> ramppi loytyi, hae sen pohja
  kaanto = melkein  -> F pohjaan, lukko aukeaa
```

Hiirta ohjataan **hiiriyksikkoina**, ei asteina. Siksi ohjelman ei tarvitse
tietaa pelin hiiriherkkyytta eika tiirikan asentoa. Vasen aariasento
loydetaan tyontamalla hiirta reilusti yli koko janan: seinaa vasten
ylimaarainen liike ei tee mitaan, joten jokainen yritys alkaa samasta
kohdasta ilman etta sita tarvitsee mitata.

```
ALOITUS (vasen reuna)     HAKU: napautus - lepo - napautus
  |
  +--F--+ . +--F--+ . +--F--+ . +--F--+   matelee oikealle
                                    |
                                    +-- pesa alkoi kaantya = VASTEIKKUNA
                                        peruuta havainnon viiveen verran
                                        |
                                        +== F POHJAAN JA PIDETAAN ==
                                            odota kunnes kaanto PYSAHTYY
                                            pysahtynyt kulma kertoo etaisyyden
                                            astu sen verran -> odota -> astu
                                            ... kunnes lukko aukeaa
```

Pesa kaantyy vain kun F on pohjassa, joten ikkunan voi havaita VAIN F
pohjassa. Siksi haku ei voi vain paastaa F:aa irti - se napauttaa.
Hiiri seisoo paikallaan lepojakson ajan: jos se liikkuisi F ylhaalla,
vasteikkuna voisi mennä ohi kenenkaan huomaamatta.

Ajovaiheessa F pysyy pohjassa. Se ei kuluta tiirikkaa, koska siella lukko
antaa periksi koko ajan - ja juuri se erottaa periksiantavan lukon
jumista.

### Miten se toimii

1. Kaappaa pelin ikkunan keskelta neliomaisen alueen (`mss`).
2. **Lukon runko**: metallinvaaleat pikselit keskella -> keskipiste.
3. **Lukkopesan kaanto**: avaimenreika on lahes musta (`lum < 22`); sen
   paaakselin suunta on pesan kaanto. Maski vaaditaan pitkulaiseksi, muuten
   ruutu hylataan. Tama on ainoa mittaus, jonka varassa haku on.
4. **Aika**: kirkkaat pikselit lukon ulkopuolisella renkaalla.
5. Ohjaus: `lockpick_control.py` paattaa montako hiiriyksikkoa liikutaan ja
   milloin F painetaan. Hiiri liikkuu `SendInput`-pulsseina, nappaimet
   skannauskoodeina (pelit lukevat DirectInputilla eivatka aina huomaa
   virtuaalikoodeja).

Kaikki mitat ovat lukon sateen tai ruudun korkeuden monikertoja, joten sama
koodi toimii eri resoluutioilla. `test_vision.py` varmistaa taman 720p:sta
1440p:hen ja tarkistaa lisaksi, ettei tiirikan asento vuoda kaannon lukemaan:
pelin omissa kuvissa tiirikka on aarilaidoissa, ja pesan kaanto luetaan
molemmissa samaksi (+1,9 vs +1,4 astetta).

### Aloitus ja uusinnat

Ohjelma ei yrita lukea "Press Space to Start" -teksti&auml;. Sen sijaan se
katsoo, **onko valkoista aikakaarta olemassa**. Pelivideosta mitattuna:

| Tilanne | Kaaren pikseleita |
|---|---|
| Yritys kaynnissa (45 kehysta) | 4640-6401 |
| Sumea aloitusruutu | 0 |
| SUCCESS-ruutu | 1 |

Ero on niin suuri, ettei siina ole tulkinnanvaraa. Kun kaarta ei ole, ohjelma
painaa SPACEa; kun se ilmestyy, yritys on kaynnissa.

Sama silmukka hoitaa seka ensimmaisen aloituksen etta epaonnistumisen
jalkeiset uusinnat. Onnistuminen erottuu aikakatkaisusta siita, etta
onnistuessa koko minipeli sulkeutuu, kun taas aikakatkaisussa lukko jaa
nakyviin ja aloituskehote palaa.

### Mita ohjelma EI tee

Aiemmat versiot mittasivat ajon aikana havaintoviivetta, ruutuvalia,
kulmakohinaa ja yrityksen kestoa, ja johtivat niista kynnyksia. Se oli
teoriassa oikein mutta kaytannossa kaikki ne saadot vaikuttivat toisiinsa,
eika mitaan pystynyt virittamaan yksin. Kaikki tuo on poistettu.

Ohjain ei enaa opi mitaan yritysten valilla eika saada itseaan ajon
aikana. Se tekee joka kerta saman asian samoilla luvuilla, ja ne luvut
ovat sinun muutettavissasi. Ainoa asia, joka mitataan, on lukkopesan
**lepokulma** yrityksen ensimmaisista ruuduista - koska pesa voi levata
hieman vinossa, eika nollatasoa siksi voi olettaa.

Sweetspotin paikkaa ei muisteta, koska se vaihtuu yritysten valilla:
omassa nauhoituksessasi se oli kerran 957 ja kerran 3052 yksikon kohdalla.

## 2. Selainsimulaatio

Avaa `web/scum_lockpick_sim.html`. Mitaan ei tarvitse asentaa.

- **messinkinen vyo** lukon ymparilla on palautealue
- **vihrea kiila** on avaava ydin
- oikealla penkki, jonka saatimet vastaavat `asetukset.json`-avaimia
- alhaalla eraajo, joka vertaa hakutapoja

Ohjaus-valikosta voi vaihtaa kasiohjaukseen ja kokeilla itse hiirella ja
F-nappaimella.

---

## 3. Eraajosimulaattori

```bash
cd sim
python lockpick_sim.py --tier basic --skill 1 --sessions 400
python lockpick_sim.py --compare-orders --tier medium
python lockpick_sim.py --compare-tiers --skill 2
python lockpick_sim.py --sweep-step 4 6 8 10 12 --tier enforced
python lockpick_sim.py --settings ../../asetukset.json --tier basic
```

---

## Testit

Windowsissa `Aja_Testit.bat` ajaa kaikki kerralla.

```bash
cd sim  && python test_sim.py            # lukkomalli ja hakusaanto
cd live && python test_vision.py         # tunnistus pelin kuvista
cd live && python test_inner_chamber.py  # pinkilla merkitty pesan alue
cd live && python test_success_angles.py # success-kulmat pelin kuvista
cd live && python test_runner.py         # tilakone valesyotteella
cd live && python test_gameplay.py       # oikean pelivideon 47 kehysta
cd live && python test_control.py        # ohjaimen kayttaytyminen
```

`test_control.py` tarkistaa **kuvion**, ei onnistumisprosenttia:
napautukset ovat lyhyita ja samanmittaisia, hiiri liikkuu tasaisin pienin
askelin, ja rampissa painallus kestaa niin kauan kuin pesa kaantyy.

`test_vision.py` vaatii Pillowin (`pip install pillow`). Live-ajo ei vaadi.

---

## Mita simulaatio kertoi Helperi 1.8:sta

Ajettuna `asetukset.json`-tiedoston arvoilla (Basic-lukko, thievery basic,
400 sessiota, enintaan 6 yritysta) tulos oli **0,0 % avattu**. Kolme syyta:

**1. `maximum_F_hold_ms: 320` on lyhyempi kuin taysi kaanto.**
Tassa mallissa pesa kaantyy 260 astetta sekunnissa, joten 90 asteen kaanto
kestaa 346 ms. Ohjain vapautti F:n 26 ms ennen maalia, joka kerta. Kynnys on
jyrkka: katto 300 ms -> 0,0 %, katto 350 ms -> 96,7 %.

**2. Hiiri liikkui 33 astetta sekunnissa.**
`scan_mouse_max_units_per_pulse: 28` kertaa `0.035` jaettuna `mouse_settle_ms:
30`:lla. Siirtyminen keskelta vasempaan reunaan kesti 1,9 sekuntia eli yli
puolet koko 3,25 sekunnin ikkunasta, ennen ensimmaista F-testia.

**3. Hakutapa "vasemmalta oikealle" maksoi taman matkan joka kierroksella.**
Sama haku, katto korjattuna, muuten helperin arvoilla:

| Hakutapa | avattu | 1. yrityksella |
|---|---|---|
| vasemmalta oikealle | 65,5 % | 3,0 % |
| keskelta ulos | 86,5 % | 28,5 % |
| nykykohdasta | 97,2 % | 48,5 % |

Viritetyilla arvoilla (`from-current`, 8&deg; vali, 120 yksikon pulssi,
16 ms pulssivali) simulaatio avaa Basic-lukon 100 % sessioista ja 97 %
ensimmaisella yrityksella.

### Miten live-skripti korjaa nama

Live-skripti kayttaa **vasemmalta oikealle** -hakua, kuten pyydettiin, ja
molemmat ongelmat on poistettu rakenteellisesti:

- **F vapautetaan kun kaanto pysahtyy**, ei kiintean ajastimen taytyttya.
  Kasvavaa kaantoa ei katkaista koskaan. Hatakatko on olemassa, mutta ohjelma
  nostaa sita itse, jos mitattu kaantonopeus ei mahdu sen alle.
- **Hiirta ohjataan hiiriyksikkoina eika asteina.** Pelin hiiriherkkyytta ei
  tarvitse tietaa lainkaan. Testissa herkkyys vaihdeltiin 0,015:sta
  0,090 asteeseen yksikkoa kohti - kuusinkertainen ero - ilman etta ohjaimen
  asetuksiin koskettiin:

| Pelin herkkyys | avautui | yrityksia |
|---|---|---|
| 0,015 deg/yksikko | 92,0 % | 2,08 |
| 0,035 deg/yksikko | 100,0 % | 1,00 |
| 0,060 deg/yksikko | 100,0 % | 1,16 |
| 0,090 deg/yksikko | 100,0 % | 1,77 |

---

## Rakenne

```
live/autolockpick_live.py   ruudunkaappaus, tunnistus, SendInput, CMD-nakyma
live/lockpick_control.py    hakusaanto ja tilakone (jaettu logiikka)
live/lock_sim.py            nauhoitukseen kalibroitu lukkomalli
live/debug_report.py        HTML-raportti debug-paketista tai nauhoituksesta
live/test_control.py        ohjaimen kayttaytyminen (kuvio, ei prosentit)
live/test_vision.py         tunnistus pelin omia kuvia vasten
live/test_inner_chamber.py  pinkilla merkitty pyoriva pesa
live/test_runner.py         tilakone valesyotteella
live/test_gameplay.py       oikean pelivideon toisto
live/references/            SCUMin ruutukaappaukset testeja varten
live/gameplay/              47 kehysta oikeasta lockpick-yrityksesta
live/traces/                oma debug-nauhoituksesi, johon malli on sovitettu

sim/lockpick_model.py       lukon fysiikka: palautekayra, kaanto, kuluminen
sim/solver.py               simulaation autolockpick
sim/lockpick_sim.py         komentorivi, eraajot ja vertailut
sim/test_sim.py             mallin tarkistustestit

web/scum_lockpick_sim.html  selainsimulaatio (yksi tiedosto)
SAADOT.txt                  kaikki saadettavat luvut yhdella sivulla
docs/MEKANIIKKA.md          mika on lahteista ja mika on taman mallin arviota
```

---

## Mita pelivideo opetti

Kayttajan nauhoitus (47 kehysta, 5 kuvaa sekunnissa) muutti kolme asiaa.

**1. Tiirikka kaantyy lukkopesan mukana.**
Kehyksessa 29 avaimenreika on pystyssa ja tiirikka osoittaa ylos; kehyksessa
45 avaimenreika on vaakatasossa ja tiirikka osoittaa oikealle. Tiirikan kulma
ruudulla on siis hiiren asennon JA pesan kaannon summa. Sita ei voi kayttaa
hiiren asentona juuri silloin kun lukko kaantyy - eli juuri silloin kun sita
tarvittaisiin. Tama vahvistaa, etta tiirikan tunnistuksesta luopuminen oli
oikea ratkaisu eika pelkka yksinkertaistus.

**2. Pesa ei palaa nollaan testien valilla.**
Mitattu sarja oli 19, 22, 6, 33, 38, 26, 41, 50, 49, 32, 62, 75, 75, 63, 91.
Se nousee ja notkahtaa, koska pelaaja naputtaa F:aa. Pisteytys ei siksi voi
mitata *muutosta* lahtotasosta - se lukee nyt arvon, johon pesa **asettuu**
F pohjassa. Se on suoraan se, kuinka pitkalle pesa antaa tassa kohdassa
periksi, riippumatta siita mihin edellinen testi jatti sen.

**3. Aikakaari ei kutistu nakyvasti.**
Yhdeksassa sekunnissa kaari pieneni vain neljanneksen. Aiempi versio paatteli
yrityksen olevan kaynnissa siita, etta kaari kutistuu - **se ei olisi koskaan
lauennut**, joten ohjelma olisi jaanyt painamaan SPACEa loputtomiin. Nyt
kaynnissaolo luetaan kaaren olemassaolosta.

Videossa nakyi lisaksi, etta yhden yrityksen laskuri lahti **kymmenesta** ja
lukko aukesi yhdeksassa sekunnissa. Patch noteissa mainittu 2,75 sekuntia ei
siis pade ainakaan kaikkiin tilanteisiin - kyseessa voi olla harjoituslauta,
jonka aikaa voi saataa. Simulaattorille voi antaa mitatun ajan:
`python lockpick_sim.py --seconds 10`. Erolla on merkitysta: samoilla
asetuksilla Basic-lukko aukeaa ensimmaisella yrityksella 69 %:ssa
2,75 sekunnin ikkunassa ja 97 %:ssa kymmenen sekunnin ikkunassa.

---

## Rajaukset

Tunnistus on ajettu kayttajan omaa pelivideota vasten: kaikki 45 yrityksen
kehysta tunnistuvat, levossa oleva pesa luetaan alle 2,6 asteeksi ja
avautuminen 91,3 asteeksi.

Ainoa asia, joka tunnistuksen on saatava oikein, on **lukkopesan kaanto**.
Jos `--probe` nayttaa sen liikkuvan kun painat F:aa itse, ohjelmalla on kaikki
mita se tarvitsee.

**Live-skriptia ei ole voitu ajaa oikeassa pelissa taalla.** Windowsia eika
SCUMia ei ollut kaytettavissa. Testattu on se, mita voi testata: hakulogiikka
simuloitua lukkoa vasten, tunnistus pelin omia ruutukaappauksia vasten ja
tilakone valesyotteella.
Ruudunkaappaus, `SendInput` ja pelin reagointi syotteisiin on todennettava
pelikoneella, ja `--probe` on sita varten.

Simulaation prosentit kertovat asetusten keskinaisesta paremmuudesta taman
mallin sisalla. Ne eivat ole pelin onnistumisprosentti. Palautealueen leveys,
kayran muoto, pesan kaantonopeus ja kulumisnopeudet ovat kalibrointia, eivat
pelin lahdekoodista luettuja arvoja. Erittely on tiedostossa
[docs/MEKANIIKKA.md](docs/MEKANIIKKA.md).

Tiirikan liikevara **+-63 astetta** on mitattu pelin omista ruutukaappauksista.
Sita kaytetaan enaa vain simulaatiossa; live-skripti ei tarvitse sita, koska
se ei mittaa asteita lainkaan.

Automaattinen syote on pelin saantojen kannalta pelaajan oma vastuu; SCUMissa
on EAC, ja palvelimilla voi olla omat saantonsa automaatiosta.


---

# Versiohistoria

> Alla olevat LIVE 1.2 - 1.6 -osiot kuvaavat **aiempia** versioita. Osa niiden
> ratkaisuista on sittemmin kumottu: erityisesti LIVE 1.6:n lyhyt F-tappays ja
> F ylhaalla tapahtuva seuranta on korvattu silla, etta F on pohjassa koko
> ajan. Ne on jatetty nakyviin, jotta nakee mita kokeiltiin ja miksi siita
> luovuttiin. Voimassa oleva kuvaus on LIVE 2.0 -osiossa yllä.

---

## LIVE 1.2 — PLAYER RECORDING + FULL DEBUG

Automaattisen ratkaisun päätöslogiikkaa ei muutettu. Lisätty vain
diagnostiikka ja manuaalisen pelaajan datankeruu.

### F7 — PLAYER RECORDING

F7 käynnistää täysin passiivisen tallennuksen. Automaattiohjaus menee
välittömästi tauolle ja kaikki synteettiset syötteet vapautetaan.

Tallennus tekee kansion:

`live/manual_records/player_YYYYMMDD_HHMMSS/`

- `frames/` — noin 25 annotoitua PNG-kuvaa sekunnissa
- `telemetry.jsonl` — jokainen capture-frame
- `events.jsonl` — nappien down/up ja yritysten tapahtumat
- `summary.json` — koneellisesti luettava pelaajaprofiili
- `summary.txt` — helposti luettava yhteenveto

PNG-kuvan oikeassa paneelissa näkyy mm. lukkopesän kulma, kääntönopeus,
timer, F DOWN/UP + pidon kesto, SPACE, cursor delta, vision-mittarit,
yritysnumero, max turn ja viimeisimmät tapahtumat.

### F8 — FULL DEBUG ZIP

F8 luo suoraan lähetettävän ZIPin `live/debug/`-kansioon. Se sisältää
raaka- ja annotoidun lock-kuvan, controller/planner/memory/vision-tilan,
kaikki F-probet CSV:nä sekä noin viimeiset 1200 capture-eventtiä.

### Hotkeyt

- `F7` PLAYER RECORDING on/off
- `F8` FULL DEBUG ZIP
- `F11` automaatio päälle/tauolle
- `F9` lopetus

F7-tilassa F11 ei saa käynnistää automaatiota, jotta pelaajan data pysyy
puhtaana.


---

## LIVE 1.3 — PLAYER-LEARNED

Tama versio on kalibroitu 97.5 sekunnin manuaalisesta F7-tallennuksesta:
14 oikeaa avausyritysta / 14 avattua lukkoa, 66 F-painallusta varsinaisten
avausten aikana. Vanha automaatti piti F:aa debugissa tyypillisesti vain
noin 58 ms; pelaajan oikeissa ramppiosumissa +3 deg vaste ilmestyi vasta
67–173 ms kohdalla (mediaani noin 109 ms).

Siksi global F-testi ei enaa voi luovuttaa 70 ms kohdalla. Minimum hold on nyt adaptiivinen: perusraja 120 ms, mutta
30 ms toteutuneella framevalilla noin 180 ms. Stall-raja skaalautuu myos toteutuneeseen capture-FPS:aan.

Lisaksi:
- scan-stepin automaattinen oppiminen on oletuksena pois (debugissa se oli
  kutistunut 40 mouse-unitiin ja teki hausta aivan liian tihean)
- paikallishaussa 1–2 asteen erot eivat vaihda suuntaa joka testilla
- 80+ deg FINISH vaatii taman F-painalluksen omaa vastetta; vanha residuaali
  ei yksin lukitse sweetspottia
- 90+ deg menee aina viimeistelyyn
- automaattisesti nostettava F-katto on rajattu 1600 ms:iin
- F7-recorder raportoi jatkossa myos +3 deg vasteen todellisen onset-ajan
  ja haamuyritykset on poistettu yritystilastosta


---

## LIVE 1.4 — INNER CHAMBER ONLY

Turn-detector on vaihdettu käyttämään vain käyttäjän pinkillä merkitsemää
sisempää pyörivää lukkopesää. Ulomman lukon kuoren pikselit eivät enää
vaikuta kaantokulmaan.

Lisäksi pieni F-tärähdys merkitsee testipisteen hylätyksi: paikallishaku ei
saa palata heti samaan kohtaan eikä korkea residuaalikulma saa muuttua
sweetspotiksi ilman tämän F-painalluksen omaa jatkuvaa kääntöä.

Katso `LIVE_1_4_MITA_MUUTTUI.txt`.


---

## LIVE 1.5 — REAL MOTION GUARD

Lukkopesän absoluuttinen viistokulma ei enää tarkoita, että F:ää kannattaa
pitää pohjassa. Controller seuraa nyt vain uutta oikealle etenevää
high-water-markia.

Paikallaan tapahtuva tärinä -> F ylös -> pieni askel oikealle -> uusi F-testi.
Tätä jatketaan kunnes sisempi lukkopesä saavuttaa noin 90°.

Katso `LIVE_1_5_MITA_MUUTTUI.txt`.


---

## LIVE 1.6 — FAST SCAN + DEEP TARGET

Global-vaihe käyttää nyt vain noin 45 ms F-täppäystä ja seuraa reaktiota
F ylhäällä. Pitkä F-pito alkaa vasta oikean rampin löydyttyä.

Paikallishaku ei enää pidä 50–70 asteen rampin reunaa maksimina:
huonompi piste vaihtaa suunnan ja puolittaa askelen. Hylätyn pisteen guard
pienennettiin 35 -> 4 mouse-unitiin, jotta sweetspot voidaan oikeasti etsiä
kahden rampinreunan välistä.

Katso `LIVE_1_6_MITA_MUUTTUI.txt`.


---

## LIVE 2.0 / 2.1 — poistettu

Naissa versioissa haku piti F:aa pohjassa yhtajaksoisesti ja ajovaihe
kaytti asettumisikkunoita, mitattua havaintoviivetta, puolitushakua,
loppukiria ja kolmea otetasoa. Se toimi mallia vasten mutta pelissa se
napautteli ja painoi pohjaan sekavasti, skannasi isoin loikin ja oli
liian monimutkainen viritettavaksi.

Koko koneisto on poistettu ja korvattu LIVE 3.0:n kahdella vaiheella.
Ohjain on nyt 429 riviä entisen yli tuhannen sijaan ja saatoja on 21,
kaikki yhdessa lohkossa. Ks. [SAADOT.txt](SAADOT.txt).
