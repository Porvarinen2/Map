# LIVE 1.1 BASELINE STICKY

Tama versio perustuu suoraan kayttajan **Autolockpick.zip**-pakettiin.
Tunnistus, barrel-only rakenne, SPACE/arc-startti, SendInput ja vasemmalta
oikealle skannaus on sailytetty. Muutokset kohdistuvat kolmeen oikeasta
debugista nakyneeseen ongelmaan.

## 1. Residuaalikulma ei ole ramppi

`live/debug/live_20260906_225407.json` sisalsi tilanteen, jossa uuden yrityksen
ensimmainen probe oli paikassa 0 u ja lukkopesa oli jo noin **13.9 astetta**
kaantyneena. Vanha Planner katsoi vain absoluuttista scorea, joten `13.9 > 5`
riitti lukitsemaan rampin heti vasempaan reunaan.

LIVE 1.1 tallentaa jokaisen F-testin alussa sen hetkisen barrel-kulman
`baselineksi`. Rampin ensihavainto vaatii nyt **F:n aikana syntyvan lisakaannon**:

- `score` = absoluuttinen asettunut kulma; sita kaytetaan edelleen rampin
  syvyyden vertailuun.
- `response` = kestava 3-frame kulma miinus testin baseline; sita kaytetaan
  rampin ensihavaintoon.

Yksi/kaksi framea ei riita responseksi. Oletuskynnys on 3 astetta, koska
pelivideon levossa oleva kohina pysyi alle noin 2.6 asteen.

## 2. Sweetspotilla F:aa pidetaan rauhallisemmin

Vanha 45 ms stall-raja oli hyva tyhjilla scan-pisteilla, mutta liian aggressiivinen
kun lukko oli jo syvalla rampissa. LIVE 1.1 kayttaa score-riippuvaa stall-rajaa:

- tavallinen piste: 45 ms
- yli 55 astetta: vahvempi 95 ms ikkuna
- yli 72 astetta: 165 ms ikkuna
- yli 80 astetta: FINISH, jossa samaa kohtaa pidetaan vahintaan 360 ms ja
  stall-raja on 560 ms

Tavoite on poistaa juuri se `F ylos -> hiiri -> F -> hiiri` -nykiminen
strong/sweetspot-alueella ilman etta tyhjia pisteita jauhetaan pitkaan.

## 3. Skannausvalin oppiminen ei saa karata 900 unitiksi

Debugissa opittu `scan_step_units` oli 900. Vanha `width * 1.5` voi tehda
seuraavan yrityksen skannauksesta leveamman kuin itse havaittu rampin alue.
Nyt oppiminen saa **vain tihentaa** oletusaskelta:

`learned = width * 0.55`, rajattuna minimiin ja enintaan alkuperaiseen
`scan_step_units`-arvoon.

## Sailytetty ennallaan

- tiirikkaa ei tunnisteta
- lukkopesa on ainoa sensori
- jokainen normaali yritys kotiutuu vasempaan reunaan
- global scan kulkee vasemmalta oikealle
- kasvavaa kaantoa ei katkaista
- F-hold-katto osaa edelleen nostaa itseaan mitatun kaantonopeuden perusteella
- `resume_search` ja `remember_ramp` ovat oletuksena pois
