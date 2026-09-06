# SCUM Tiirikkapenkki

Kolme osaa, jotka ajavat samaa lukkomallia ja samaa hakulogiikkaa:

| Kansio | Mika | Ajetaan |
|---|---|---|
| `live/` | **ruudunlukija, joka avaa oikean lukon pelissa** | Windows + CMD |
| `web/` | selainsimulaatio, jossa piilotettu sweetspot nakyy | mika tahansa selain |
| `sim/` | eraajosimulaattori asetusten viritykseen | mika tahansa Python |

Ideana on, etta pelissa ajettava logiikka on se, joka on ensin todistettu
simulaatiolla toimivaksi. `live/test_live.py` ajaa oikean ohjaimen simuloitua
lukkoa vasten, ja `live/test_vision.py` ajaa oikean tunnistuksen pelin omia
ruutukaappauksia vasten.

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
    F8    tallenna debug

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
ALOITUS (vasen reuna)
  |
  +--F--+--F--+--F--+--F--+--F--+--F--+   vasemmalta oikealle
                                |
                                +-- lukko antoi periksi = RAMPPI
                                    pienempi askel, hae pohja
                                    TARGET -> F pohjaan
```

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

Ohjelma ei yrita lukea "Press Space to Start" -teksti&auml; &mdash; sumea
aloitusruutu oli juuri se, mihin helperi 1.8 kompastui. Sen sijaan se painaa
SPACEa ja **tarkistaa itse**, alkoiko aikakaari kutistua. Jos ei alkanut, se
painaa uudelleen. Sama silmukka hoitaa seka ensimmaisen aloituksen etta
epaonnistumisen jalkeiset uusinnat.

### Mita ohjelma oppii ajon aikana

| Suure | Miksi |
|---|---|
| Lukkopesan kaantonopeus | maaraa kuinka kauan F:aa pitaa pitaa; ilman tata F:n kattoaika on arvaus. Jos katko on liian lyhyt, ohjelma nostaa sita itse. |
| Skannausvali (hiiriyksikkoa) | jos koko jana kaydaan lapi loytamatta mitaan, vali oli liian harva ja se puolittuu. Kun ramppi loytyy, sen leveys kertoo sopivan valin. |
| Jo kayty jana | seuraava yritys jatkaa siita mihin edellinen jai, eika kayda samaa aluetta uudestaan. |

Asetuksissa on lisaksi `remember_ramp`, joka palaisi uusinnassa suoraan
edellisella kerralla loydettyyn ramppiin. **Oletuksena se on pois paalta**,
koska pelaajien mukaan sweetspot voi vaihtua yritysten valilla. Jos huomaat
etta kohta pysyy pelissasi samana, laita se paalle - simulaatiossa se
vahentaa tarvittavia yrityksia, mutta vaihtuvalla kohdalla se haittaa.

---

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

```bash
cd sim  && python test_sim.py       # lukkomalli ja hakusaanto
cd live && python test_live.py      # live-ohjain simuloitua lukkoa vasten
cd live && python test_vision.py    # tunnistus pelin omia kuvia vasten
cd live && python test_runner.py    # tilakone: aloitus, uusinta, avaus, tauko
```

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
live/test_live.py           ohjain simuloitua lukkoa vasten
live/test_vision.py         tunnistus pelin omia kuvia vasten
live/test_runner.py         tilakone valesyotteella
live/references/            SCUMin ruutukaappaukset testeja varten

sim/lockpick_model.py       lukon fysiikka: palautekayra, kaanto, kuluminen
sim/solver.py               simulaation autolockpick
sim/lockpick_sim.py         komentorivi, eraajot ja vertailut
sim/test_sim.py             mallin tarkistustestit

web/scum_lockpick_sim.html  selainsimulaatio (yksi tiedosto)
docs/MEKANIIKKA.md          mika on lahteista ja mika on taman mallin arviota
```

---

## Rajaukset

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
