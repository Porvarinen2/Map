# Lukkomalli: mika on pelista ja mika on arviota

Tarkistettu 6.9.2026. Tama tiedosto erottelee lahteista varmistetut asiat
simulaation omista kalibrointipaatoksista, jotta simulaation lukuja ei
luulla pelin lukemiksi.

## Varmistettu lahteista

| Asia | Arvo | Lahde |
|---|---|---|
| Yhden yrityksen aika | 2,75 s | Scum Wiki, Lockpicking |
| Thievery-bonus aikaan | enintaan +1,5 s (advanced) | Scum Wiki, Lockpicking |
| Thievery kasvattaa sweetspotin kokoa | kylla, maara ei julkinen | BisectHosting-opas |
| Tiirikan kuluminen | riippuu lukosta, tiirikan tyypista ja taidosta | Scum Wiki, Lockpicking |
| Improvised-tiirikka hajoaa nopeammin kuin tehdastekoinen | kylla | Scum Wiki, Lockpicking |
| Ohjaus | hiiri siirtaa tiirikkaa, F tyontaa ruuvimeisselia | pelin oma ohjeteksti |
| Tavoite | loytaa sweetspot ja kaantaa pesa loppuun asti | Dexerto, TheGamer |
| Feathering | lyhyet F-napautukset, ei pohjassa pitamista | BisectHosting, r/SCUMgame |
| Lukkotasot | Rusted / Basic / Medium / Enforced, vaikeus kasvaa | pelin lukkokuvat, Scum Wiki |
| Osa lukoista vahingoittaa epaonnistujaa | Zapper, kasineet suojaavat | BisectHosting |

Lahteet:

- <https://scum.wiki.gg/wiki/Lockpicking>
- <https://scum.fandom.com/wiki/Lockpicking>
- <https://www.bisecthosting.com/blog/scum-lockpicking-guide-how-to-lockpick-tips-tricks>
- <https://www.dexerto.com/gaming/how-to-lockpick-in-scum-3216677/>
- <https://www.reddit.com/r/SCUMgame/comments/1fc7pb7/lockpicking_and_feathering/>
- <https://scum.wiki.gg/wiki/Padlock>

## Taman simulaation omat arviot

Naita **ei** ole varmistettu pelin lahdekoodista. Ne on valittu niin, etta
malli kayttaytyy pelaajien kuvausten mukaisesti.

### Palautekayra

Tiirikan kulma on valilla -80 ... +80 astetta. Piilotettu sweetspot arvotaan
talta valilta. Kun F on pohjassa, lukkopesa kaantyy kohti arvoa

```
d = |tiirikan kulma - sweetspot|

d <= ydin          ->  90 astetta   (lukko aukeaa)
ydin < d < alue    ->  vihje * (alue - d) / (alue - ydin)
d >= alue          ->  0 astetta
```

Tarkein rakenteellinen valinta on **epajatkuvuus ytimen reunalla**: alueella
pesa antaa vain hieman periksi (enintaan `vihje` astetta), ja taysi 90 asteen
kaanto tulee vasta ytimesta. Tama vastaa pelaajien kuvausta "the lock moves a
bit more than normal": ramppi kertoo suunnan, mutta ei avaa lukkoa.

Jos ramppi sen sijaan nousisi jatkuvasti 90 asteeseen asti, ytimen leveydella
ei olisi juuri merkitysta ja vaikea lukko olisi mallissa helppo. Nain kavi
ensimmaisessa kalibroinnissa, ja se korjattiin tahan muotoon.

### Lukkotasojen luvut

| Lukko | alue (+-) | ydin (+-) | vihje | kuluma/s |
|---|---|---|---|---|
| Rusted | 9,20° | 3,20° | 34° | 20 |
| Basic | 7,70° | 2,20° | 30° | 27 |
| Medium | 6,40° | 1,40° | 24° | 37 |
| Enforced | 4,85° | 0,85° | 18° | 50 |

Vaikeampi lukko on kolmella tavalla tiukempi: ydin on kapeampi, vihjetta antava
reuna on kapeampi ja itse vihje on heikompi. Taito kertoo seka alueen etta
ytimen: 1,0 / 1,15 / 1,32 / 1,50.

### Muut vakiot

| Suure | Arvo | Perustelu |
|---|---|---|
| Pesan kaantonopeus | 260 °/s | taysi kaanto 346 ms, murto-osa 2,75 s ikkunasta |
| Palautumisnopeus | 520 °/s | pesa napsahtaa takaisin nopeammin kuin kaantyy |
| Tiirikan kesto | 100 yksikkoa | kuluu vain jumittunutta kohtaa vasten painettaessa |
| Hiiren liikuttaminen F pohjassa | 0,5 x kuluma | "ala jiggeloi tiirikkaa" -ohje |
| Tiirikkakertoimet | improvised 1,70 / lockpick 1,00 / advanced 0,62 | wikin jarjestys |

### Ohjaimen nakomalli

Oikea helperi lukee pelin tilan ruutukaappauksesta, joten se nakee kaiken
myohassa. Simulaatiossa on kolme parametria, jotka yhdessa maaraavat montako
F-testia ikkunaan mahtuu:

- **kuvan viive** (oletus 50 ms): kuinka vanhaa tietoa ohjain nakee
- **ruutuvali** (8,3 ms): kuinka usein tila paivittyy
- **kulmatarkkuus** (0,5°, kohina 0,8°): kuinka tarkasti kaanto luetaan kuvasta

Naista seuraa, etta lyhin hyodyllinen F-pito on `viive + 2 x ruutuvali`.
Sita lyhyempi napautus vapautetaan ennen kuin liike ehtii nakya.

## Mita simulaatio ei todista

- Pelin todellista sweetspotin leveytta tai kayran muotoa.
- Onnistumisprosenttia oikeassa pelissa. Luvut kertovat vain asetusten
  keskinaisesta paremmuudesta taman mallin sisalla.
- Tiirikan todellista kestavyytta eri lukoilla ja hahmotaidoilla.
- Windowsin SendInput-syotteen vastaanottoa kayttajan koneella.
