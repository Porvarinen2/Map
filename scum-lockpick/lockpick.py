"""SCUM autolockpick.

    tap, tap, tap, tap, taap, taaaap, taaaap, AUKI

Hiirta liikutetaan vasemmalta oikealle. Joka kohdassa napautetaan F ja
katsotaan, kaantyiko lukkopesa.

    ei liiketta      -> vaara kohta, askel oikealle
    osittainen kaanto -> RAMPPI, ollaan oikealla alueella
    enemman kaantoa   -> lahempana
    lukko aukeaa      -> TARGET

Rampissa F pidetaan pohjassa niin kauan kuin pesa kaantyy. Kun se
pysahtyy, nykaistaan hieman ja painetaan uudelleen. Painallusten pituutta
ei ole kasketty mihinkaan - se seuraa siita, kuinka kauan pesa jaksaa
kaantya.

Ajo:
    python lockpick.py            avaa lukkoja
    python lockpick.py --testaa   lukee ruutua lahettamatta syotteita

Nappaimet ajon aikana: F11 kaynnistaa/tauottaa, F9 lopettaa.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
import sys
import time
from dataclasses import asdict, dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
ASETUKSET = os.path.join(HERE, "asetukset.json")
LOKI = os.path.join(HERE, "loki.jsonl")
KARTTA = os.path.join(HERE, "kartta.html")


# ==========================================================================
#  SAADOT - kaikki taalla. Muuta joko tasta tai asetukset.json-tiedostosta.
# ==========================================================================


@dataclass
class Saadot:
    # ---- ALOITUS: hiiri aina taysin vasemmalle ----
    alkuun_yksikkoa: float = 9000.0     # kuinka pitkalle vasemmalle tyonnetaan
    alkuun_pulssi: float = 600.0        # yhden tyonnon koko

    # ---- SKANNAUS: tap, tap, tap ----
    askel_yksikkoa: float = 90.0        # hiiren siirto napautusten valissa
    tap_ms: float = 90.0                # kuinka kauan F on pohjassa
    tauko_ms: float = 130.0             # tauko napautuksen jalkeen, F ylhaalla
    ramppi_astetta: float = 3.0         # nain paljon kaantoa = ramppi loytyi
    jana_yksikkoa: float = 6000.0       # nain pitkalle skannataan, sitten alusta

    # ---- RAMPPI: taap, taaaap, taaaap ----
    paino_min_ms: float = 120.0         # lyhin pitka painallus
    paino_max_ms: float = 1600.0        # pisin painallus
    pysahtyi_ms: float = 140.0          # nain kauan ilman kaantoa = pesa pysahtyi
    irti_ms: float = 70.0               # F ylhaalla painallusten valissa
    nykays_yksikkoa: float = 14.0       # nykays kun pesa pysahtyi
    nykays_hieno: float = 4.0           # nykays kun ollaan jo lahella
    hieno_alle_astetta: float = 12.0    # nain lahella maalia hienonykays kayttoon
    auki_astetta: float = 88.0          # tasta ylospain F pysyy pohjassa
    hukassa_astetta: float = 2.0        # kaanto putosi tanne = ramppi hukattiin
    hukat_ennen_paluuta: int = 3        # nain monta hukkaa -> takaisin skannaukseen

    # ---- HIIRI ----
    pulssi_max: float = 240.0           # yhden hiiripulssin katto
    pulssi_ms: float = 16.0             # pulssien valinen tauko

    # ---- RUUDUNLUKU ----
    # Mitat suhteessa ruudun korkeuteen, joten sama koodi toimii kaikilla
    # resoluutioilla. Arvot on mitattu pelin omista kuvakaappauksista.
    lukon_sade: float = 0.139           # lukon sade / ruudun korkeus
    alue_sade_1080: float = 128.5       # pyoriva lukkopesa, 1080p-pikselia
    reika_sade_1080: float = 56.0       # musta avaimenreika sen sisalla
    keskipiste_y_1080: float = -3.0     # lukon keskipisteen hienosaato
    tumma_max: float = 22.0             # avaimenreian ylin kirkkaus
    metalli_min: float = 55.0           # lukon metallin kirkkausvali
    metalli_max: float = 205.0
    kirkas_min: float = 185.0           # aikakaaren alin kirkkaus
    kaari_pikselit: int = 1500          # nain monta = yritys on kaynnissa
    reika_pikselit: int = 700           # nain monta = avaimenreika loytyi
    metalli_pikselit: int = 2500        # nain monta = lukko on ruudulla
    # Avaimenreian on oltava pitkulainen. Pyorea maski tarkoittaa, ettei
    # sita loytynyt. Mitattu pelin kuvista: aidot reiat 2.0 - 4.3.
    pitkulaisuus_min: float = 1.8

    # ---- KARTOITUS: rampin ja targetin leveyden mittaus ----
    # Targetin PAIKKAA ei voi kartoittaa: se arvotaan joka yrityksella
    # uudelleen. Rampin ja targetin LEVEYS sen sijaan on lukkotyypin
    # ominaisuus ja pysyy samana - ja juuri se kertoo, kuinka pitkin
    # askelin lukkoa voi skannata.
    loki: bool = True                   # kirjoitetaanko loki.jsonl
    kartoitus_askel: float = 25.0       # askel rampin yli mitattaessa
    kartoitus_matka: float = 600.0      # kuinka pitkalle ramppia seurataan
    kartoitus_hukat: int = 4            # nain monta tyhjaa nappia = ramppi loppui

    # ---- AJO ----
    fps: float = 60.0                   # ruudunkaappauksia sekunnissa
    yrityksia: int = 0                  # 0 = rajattomasti


def lataa_saadot() -> Saadot:
    s = Saadot()
    if os.path.exists(ASETUKSET):
        try:
            with open(ASETUKSET, encoding="utf-8") as fh:
                for k, v in json.load(fh).items():
                    if hasattr(s, k):
                        setattr(s, k, v)
        except Exception as virhe:
            print(f"asetukset.json ei kelpaa ({virhe}), kaytetaan oletuksia.")
    return s


def tallenna_saadot(s: Saadot) -> None:
    with open(ASETUKSET, "w", encoding="utf-8") as fh:
        json.dump(asdict(s), fh, indent=2, ensure_ascii=False)


# ==========================================================================
#  RUUDUNLUKU - kaannon mittaus
# ==========================================================================


@dataclass
class Havainto:
    ok: bool = False            # nakyyko lukko
    kaanto: float = 0.0         # lukkopesan kaanto asteina
    kaynnissa: bool = False     # onko yritys kaynnissa (aikakaari nakyy)
    kaari: int = 0              # aikakaaren pikselit (vain nakymaa varten)
    reika: int = 0              # avaimenreian pikselit
    # Lukkotyypin sormenjalki: ruosteen savy ja kirkkaiden pikselien osuus
    # lukkopesan alueella. Naiden avulla mittaukset osataan lajitella eri
    # lukkotyypeille.
    savy: float = 0.0
    kirkkaat: float = 0.0


class Silma:
    """Lukee lukkopesan kaannon ruudulta.

    Tiirikkaa ei etsita lainkaan: se on ohut, se voi olla eri tyokalu ja se
    kaantyy pesan mukana. Ainoa mittaus on mustan avaimenreian suunta.
    """

    def __init__(self, np, s: Saadot):
        self.np = np
        self.s = s
        self._koko = None
        self._xx = self._yy = self._r = None
        self.edellinen = 0.0

    def _ruudukko(self, korkeus: int, leveys: int):
        """Koordinaatit kuvan keskipisteesta. Sailytetaan, koska sama
        ruudukko kelpaa joka kehykselle."""
        if self._koko != (korkeus, leveys):
            np = self.np
            y = np.arange(korkeus, dtype=np.float32) - (korkeus - 1) / 2.0
            x = np.arange(leveys, dtype=np.float32) - (leveys - 1) / 2.0
            self._yy, self._xx = np.meshgrid(y, x, indexing="ij")
            self._koko = (korkeus, leveys)
        return self._xx, self._yy

    def alue(self, ikkuna):
        """Kaapattava nelio: lukon ymparilta, ruudun keskelta."""
        puoli = int(0.30 * ikkuna["height"])
        cx = ikkuna["left"] + ikkuna["width"] // 2
        cy = ikkuna["top"] + ikkuna["height"] // 2
        return {"left": cx - puoli, "top": cy - puoli,
                "width": puoli * 2, "height": puoli * 2}

    def lue(self, kuva_bgr, ikkuna) -> Havainto:
        np = self.np
        s = self.s

        kirkkaus = (0.114 * kuva_bgr[:, :, 0].astype(np.float32)
                    + 0.587 * kuva_bgr[:, :, 1].astype(np.float32)
                    + 0.299 * kuva_bgr[:, :, 2].astype(np.float32))

        xx, yy = self._ruudukko(kuva_bgr.shape[0], kuva_bgr.shape[1])
        skaala = ikkuna["height"] / 1080.0
        cy = s.keskipiste_y_1080 * skaala
        etaisyys = np.sqrt(xx ** 2 + (yy - cy) ** 2)
        lukon_r = s.lukon_sade * ikkuna["height"]

        # 1) Onko lukko ruudulla?
        metalli = ((kirkkaus > s.metalli_min) & (kirkkaus < s.metalli_max)
                   & (etaisyys < lukon_r * 1.15))
        if int(metalli.sum()) < s.metalli_pikselit:
            return Havainto()

        # 2) Kaanto: musta avaimenreika pyorivan pesan sisalla.
        reika = (kirkkaus < s.tumma_max) & (etaisyys < s.reika_sade_1080 * skaala)
        reika_n = int(reika.sum())
        if reika_n < s.reika_pikselit:
            return Havainto()

        suunta, pitkulaisuus = self._suunta(xx[reika], yy[reika] - cy)
        if pitkulaisuus < s.pitkulaisuus_min:
            return Havainto()

        # Lepaava lukko lukeutuu -89 asteeksi ja auennut +1 asteeksi, eli
        # kaanto on aina se 90 astetta. Lisataan 90, jotta luku on
        # ymmarrettava: lepo noin 0, auki noin 90.
        kaanto = self._lahin_haara(suunta + 90.0)
        self.edellinen = kaanto

        # 3) Aikakaari: onko yritys kaynnissa.
        kaari = ((kirkkaus > s.kirkas_min)
                 & (etaisyys > lukon_r * 1.05) & (etaisyys < lukon_r * 1.75))
        kaari_n = int(kaari.sum())

        # 4) Lukkotyypin sormenjalki lukkopesan alueelta.
        pesa = etaisyys < s.alue_sade_1080 * skaala
        savy = float((kuva_bgr[:, :, 2].astype(np.float32)
                      - kuva_bgr[:, :, 0].astype(np.float32))[pesa].mean())
        kirkkaat = float((kirkkaus[pesa] > 120.0).mean())

        return Havainto(ok=True, kaanto=kaanto, kaynnissa=kaari_n >= s.kaari_pikselit,
                        kaari=kaari_n, reika=reika_n, savy=savy, kirkkaat=kirkkaat)

    def _suunta(self, x, y):
        """Pistejoukon paasuunta asteina ja sen pitkulaisuus."""
        np = self.np
        x = x - x.mean()
        y = y - y.mean()
        xx = float((x * x).mean())
        yy = float((y * y).mean())
        xy = float((x * y).mean())
        kulma = 0.5 * math.atan2(2.0 * xy, xx - yy)
        juuri = math.sqrt(max(0.0, (xx - yy) ** 2 + 4.0 * xy * xy))
        iso = (xx + yy + juuri) / 2.0
        pieni = (xx + yy - juuri) / 2.0
        pitkulaisuus = math.sqrt(iso / pieni) if pieni > 1e-9 else 999.0
        return math.degrees(kulma), pitkulaisuus

    def _lahin_haara(self, kulma: float) -> float:
        """Paasuunta on sama +-180 asteen valein, joten oikea haara on
        valittava. Ensin lahin edelliseen lukemaan, ja lopuksi se
        fyysinen tosiasia, etta pesa kaantyy vain nollasta noin 90
        asteeseen: sen ulkopuolelle jaava haara on vaara."""
        while kulma - self.edellinen > 90.0:
            kulma -= 180.0
        while self.edellinen - kulma > 90.0:
            kulma += 180.0
        while kulma < -25.0:
            kulma += 180.0
        while kulma > 125.0:
            kulma -= 180.0
        return kulma


# ==========================================================================
#  OHJAIN - mita tehdaan milloinkin
# ==========================================================================


@dataclass
class Kasky:
    hiiri: float = 0.0          # hiiriyksikkoa oikealle (miinus = vasemmalle)
    f: bool = False             # onko F pohjassa
    vaihe: str = "alkuun"
    teksti: str = ""


class Ohjain:
    ALKUUN, SKANNAUS, RAMPPI, KARTOITUS = ("alkuun", "skannaus", "ramppi",
                                           "kartoitus")

    def __init__(self, s: Saadot, kartoita: bool = False):
        self.s = s
        self.kartoita = kartoita     # True = mittaa ramppi, ala avaa lukkoa
        self.mittaukset: list[tuple[float, float]] = []   # (paikka, kulma)
        self.alusta()

    def alusta(self) -> None:
        """Uusi yritys alkaa aina samalla tavalla."""
        self.vaihe = self.ALKUUN
        self.paikka = 0.0
        self.ajettu = 0.0
        self.seuraava_pulssi = 0.0

        self.lepo = 0.0
        self._lepo_naytteet: list[float] = []

        # skannaus
        self.tap_paalla = False
        self.tap_loppuu = 0.0
        self.tauko_loppuu = 0.0
        self.tap_huippu = 0.0

        # ramppi
        self.paino_paalla = False
        self.paino_alkoi = 0.0
        self.paino_loppuu = 0.0
        self.paino_huippu = 0.0
        self.nousi = 0.0
        self.irti_asti = 0.0
        self.paras = 0.0
        self.suunta = 1
        self.hukat = 0

        # kartoitus
        self.rampin_alku = 0.0
        self.tyhjat = 0
        self.mittaukset = []

    def kaanto(self, h: Havainto) -> float:
        """Kuinka paljon pesa on kaantynyt lepoasennostaan."""
        return h.kaanto - self.lepo

    def paivita(self, nyt: float, h: Havainto) -> Kasky:
        if not h.ok:
            return Kasky(vaihe=self.vaihe, teksti="lukkoa ei nay")

        # Lepokulma mitataan yrityksen alussa: pesa voi levata vinossa.
        if len(self._lepo_naytteet) < 6:
            self._lepo_naytteet.append(h.kaanto)
            self.lepo = sorted(self._lepo_naytteet)[len(self._lepo_naytteet) // 2]

        if self.vaihe == self.ALKUUN:
            return self._alkuun(nyt)
        if self.vaihe == self.SKANNAUS:
            return self._skannaus(nyt, h)
        if self.vaihe == self.KARTOITUS:
            return self._kartoitus(nyt, h)
        return self._ramppi(nyt, h)

    def _siirra(self, nyt: float, yksikkoa: float, vaihe: str, teksti: str,
               f: bool) -> Kasky:
        yksikkoa = max(-self.s.pulssi_max, min(self.s.pulssi_max, yksikkoa))
        self.seuraava_pulssi = nyt + self.s.pulssi_ms / 1000.0
        self.paikka += yksikkoa
        return Kasky(yksikkoa, f, vaihe, teksti)

    # ---------------------------------------------------------- ALKUUN

    def _alkuun(self, nyt: float) -> Kasky:
        """Hiiri taysin vasemmalle. Seinaa vasten ylimaarainen liike ei tee
        mitaan, joten jokainen yritys alkaa samasta kohdasta."""
        if self.ajettu >= self.s.alkuun_yksikkoa:
            self.paikka = 0.0
            self.vaihe = self.SKANNAUS
            return Kasky(vaihe=self.SKANNAUS, teksti="vasen reuna")
        if nyt < self.seuraava_pulssi:
            return Kasky(vaihe=self.ALKUUN, teksti="siirrytaan vasemmalle")
        askel = min(self.s.alkuun_pulssi, self.s.alkuun_yksikkoa - self.ajettu)
        self.ajettu += askel
        self.seuraava_pulssi = nyt + self.s.pulssi_ms / 1000.0
        osuus = self.ajettu / self.s.alkuun_yksikkoa * 100.0
        return Kasky(-askel, False, self.ALKUUN, f"vasemmalle {osuus:.0f} %")

    # -------------------------------------------------------- SKANNAUS

    def _skannaus(self, nyt: float, h: Havainto) -> Kasky:
        """tap, tap, tap - askel oikealle, napautus, katso liikkuiko."""
        self.tap_huippu = max(self.tap_huippu, self.kaanto(h))

        # Pesa kaantyi -> ramppi.
        if self.tap_huippu >= self.s.ramppi_astetta:
            if self.kartoita:
                # Kartoitustilassa ramppia ei avata vaan mitataan: siita
                # kavellaan yli lyhyin napautuksin ja kirjataan profiili.
                self.vaihe = self.KARTOITUS
                self.rampin_alku = self.paikka
                self.tyhjat = 0
                self.mittaukset = [(0.0, self.tap_huippu)]
                self.tap_paalla = False
                self.tauko_loppuu = 0.0
                self.tap_huippu = 0.0
                return Kasky(vaihe=self.KARTOITUS,
                             teksti=f"ramppi loytyi {self.paikka:.0f} u, mitataan")
            self.vaihe = self.RAMPPI
            self.rampin_alku = self.paikka
            self.paras = 0.0
            self.suunta = 1
            self.hukat = 0
            self._aloita_paino(nyt, h)
            return Kasky(f=True, vaihe=self.RAMPPI,
                         teksti=f"RAMPPI {self.tap_huippu:.1f} deg")

        # 1) Napautus kaynnissa: F pohjassa, hiiri paikallaan.
        if self.tap_paalla:
            if nyt < self.tap_loppuu:
                return Kasky(f=True, vaihe=self.SKANNAUS,
                             teksti=f"tap {self.paikka:.0f} u")
            self.tap_paalla = False
            self.tauko_loppuu = nyt + self.s.tauko_ms / 1000.0
            return Kasky(vaihe=self.SKANNAUS,
                         teksti=f"luetaan {self.tap_huippu:.1f} deg")

        # 2) Tauko: F ylhaalla. Tulos nakyy vasta nyt, koska kuva on
        #    hieman vanhaa.
        if nyt < self.tauko_loppuu:
            return Kasky(vaihe=self.SKANNAUS,
                         teksti=f"luetaan {self.tap_huippu:.1f} deg")

        # 3) Askel oikealle ja uusi napautus.
        if self.paikka >= self.s.jana_yksikkoa:
            self.paikka = 0.0
            return Kasky(vaihe=self.SKANNAUS, teksti="jana kayty, alusta")
        if nyt < self.seuraava_pulssi:
            return Kasky(vaihe=self.SKANNAUS, teksti="...")

        self.tap_paalla = True
        self.tap_loppuu = nyt + self.s.tap_ms / 1000.0
        self.tap_huippu = 0.0
        return self._siirra(nyt, self.s.askel_yksikkoa, self.SKANNAUS,
                            f"askel {self.paikka + self.s.askel_yksikkoa:.0f} u",
                            f=True)

    # ------------------------------------------------------- KARTOITUS

    def _kartoitus(self, nyt: float, h: Havainto) -> Kasky:
        """Kavelee rampin yli lyhyin napautuksin ja kirjaa profiilin.

        Lukkoa EI yriteta avata: napautukset ovat niin lyhyita, etta pesa
        ehtii kaantya vain sen verran kuin kohta sallii. Juuri se on
        mittaus - paikka ja siita seuraava kaanto. Kun vaste on kuollut
        muutaman napautuksen ajan, ramppi on kayty lapi.
        """
        self.tap_huippu = max(self.tap_huippu, self.kaanto(h))

        if self.tap_paalla:
            if nyt < self.tap_loppuu:
                return Kasky(f=True, vaihe=self.KARTOITUS,
                             teksti=f"mittaa {self.paikka - self.rampin_alku:+.0f} u")
            self.tap_paalla = False
            self.tauko_loppuu = nyt + self.s.tauko_ms / 1000.0
            return Kasky(vaihe=self.KARTOITUS, teksti="luetaan")

        if nyt < self.tauko_loppuu:
            return Kasky(vaihe=self.KARTOITUS, teksti="luetaan")

        # Edellinen napautus on nyt luettu: kirjataan tulos.
        if self.mittaukset and self.mittaukset[-1][0] != self.paikka - self.rampin_alku:
            self.mittaukset.append((self.paikka - self.rampin_alku, self.tap_huippu))
            self.tyhjat = (self.tyhjat + 1
                           if self.tap_huippu < self.s.ramppi_astetta else 0)

        matka = self.paikka - self.rampin_alku
        if self.tyhjat >= self.s.kartoitus_hukat or matka >= self.s.kartoitus_matka:
            self.vaihe = self.SKANNAUS          # ramppi mitattu, jatketaan
            self.tap_paalla = False
            self.tauko_loppuu = 0.0
            self.tap_huippu = 0.0
            return Kasky(vaihe=self.SKANNAUS,
                         teksti=f"ramppi mitattu ({len(self.mittaukset)} pistetta)")

        if nyt < self.seuraava_pulssi:
            return Kasky(vaihe=self.KARTOITUS, teksti="...")

        self.tap_paalla = True
        self.tap_loppuu = nyt + self.s.tap_ms / 1000.0
        self.tap_huippu = 0.0
        return self._siirra(nyt, self.s.kartoitus_askel, self.KARTOITUS,
                            f"mittaa {matka + self.s.kartoitus_askel:+.0f} u", f=True)

    # ---------------------------------------------------------- RAMPPI

    def _aloita_paino(self, nyt: float, h: Havainto) -> None:
        self.paino_paalla = True
        self.paino_alkoi = nyt
        self.paino_loppuu = nyt + self.s.paino_max_ms / 1000.0
        self.paino_huippu = self.kaanto(h)
        self.nousi = nyt

    def _ramppi(self, nyt: float, h: Havainto) -> Kasky:
        """taap, taaaap, taaaap - paina niin kauan kuin pesa kaantyy."""
        kaanto = self.kaanto(h)

        # Maalissa: ei enaa saatoa, pidetaan F pohjassa.
        if kaanto >= self.s.auki_astetta:
            return Kasky(f=True, vaihe=self.RAMPPI,
                         teksti=f"AUKEAA {kaanto:.1f} deg")

        # --- painallus kaynnissa ---
        if self.paino_paalla:
            if kaanto > self.paino_huippu + 1.0:
                self.paino_huippu = kaanto
                self.nousi = nyt                     # pesa kaantyy yha
            kaantyy = (nyt - self.nousi) < self.s.pysahtyi_ms / 1000.0
            riittava = (nyt - self.paino_alkoi) >= self.s.paino_min_ms / 1000.0
            if nyt < self.paino_loppuu and (kaantyy or not riittava):
                return Kasky(f=True, vaihe=self.RAMPPI,
                             teksti=f"paina {kaanto:.1f} deg")
            self.paino_paalla = False
            self.irti_asti = nyt + self.s.irti_ms / 1000.0
            kesto = (nyt - self.paino_alkoi) * 1000.0
            return Kasky(vaihe=self.RAMPPI,
                         teksti=f"huippu {self.paino_huippu:.1f} deg ({kesto:.0f} ms)")

        # --- lyhyt tauko painallusten valissa ---
        if nyt < self.irti_asti:
            return Kasky(vaihe=self.RAMPPI, teksti="hetki irti")

        # --- verrataan ja nykaistaan ---
        if self.paino_huippu < self.s.hukassa_astetta:
            self.hukat += 1
            if self.hukat >= self.s.hukat_ennen_paluuta:
                self.vaihe = self.SKANNAUS
                self.tap_paalla = False
                self.tauko_loppuu = 0.0
                self.tap_huippu = 0.0
                return Kasky(vaihe=self.SKANNAUS, teksti="ramppi hukkui")
        else:
            self.hukat = 0

        if self.paino_huippu > self.paras + 1.0:
            self.paras = self.paino_huippu          # parani: sama suunta
        else:
            self.suunta *= -1                       # huononi: toiseen suuntaan

        lahella = (self.s.auki_astetta - self.paino_huippu) <= self.s.hieno_alle_astetta
        askel = self.s.nykays_hieno if lahella else self.s.nykays_yksikkoa

        self._aloita_paino(nyt, h)
        return self._siirra(nyt, askel * self.suunta, self.RAMPPI,
                            f"nykays {askel * self.suunta:+.0f} u", f=True)


# ==========================================================================
#  LOKI - mittaukset talteen
# ==========================================================================


class Loki:
    """Kirjoittaa mittaukset riveittain tiedostoon loki.jsonl.

    Kolme rivilajia:
        profiili  rampin yli kavelty mittaussarja (--kartoita)
        auki      lukko aukesi: mista rampin alusta ja kuinka kauan kesti
        ramppi    ramppi loytyi mutta ei auennut
    """

    def __init__(self, polku: str, paalla: bool = True):
        self.polku = polku
        self.paalla = paalla

    def kirjaa(self, laji: str, h: Havainto, **kentat) -> None:
        if not self.paalla:
            return
        rivi = {"laji": laji, "aika": time.strftime("%Y-%m-%d %H:%M:%S"),
                "savy": round(h.savy, 2), "kirkkaat": round(h.kirkkaat, 4)}
        rivi.update(kentat)
        try:
            with open(self.polku, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rivi, ensure_ascii=False) + "\n")
        except Exception:
            self.paalla = False        # loki ei saa kaataa ajoa


# ==========================================================================
#  WINDOWS-SYOTTEET
# ==========================================================================

SCAN_F, SCAN_SPACE = 0x21, 0x39
VK_F9, VK_F11 = 0x78, 0x7A


class Kasi:
    """Hiiri ja nappaimet. Skannauskoodeina, koska pelit lukevat
    DirectInputilla eivatka aina huomaa virtuaalikoodeja."""

    def __init__(self):
        if os.name != "nt":
            raise RuntimeError("Toimii vain Windowsissa.")
        from ctypes import wintypes as W

        self.W = W
        self.user = ctypes.WinDLL("user32", use_last_error=True)
        try:
            self.user.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]
            self.user.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
        except Exception:
            self.user.SetProcessDPIAware()

        class MOUSE(ctypes.Structure):
            _fields_ = [("dx", W.LONG), ("dy", W.LONG), ("data", W.DWORD),
                        ("flags", W.DWORD), ("time", W.DWORD),
                        ("extra", ctypes.c_size_t)]

        class KEY(ctypes.Structure):
            _fields_ = [("vk", W.WORD), ("scan", W.WORD), ("flags", W.DWORD),
                        ("time", W.DWORD), ("extra", ctypes.c_size_t)]

        class HW(ctypes.Structure):
            _fields_ = [("msg", W.DWORD), ("l", W.WORD), ("h", W.WORD)]

        class U(ctypes.Union):
            _fields_ = [("mi", MOUSE), ("ki", KEY), ("hi", HW)]

        class INPUT(ctypes.Structure):
            _anonymous_ = ("u",)
            _fields_ = [("type", W.DWORD), ("u", U)]

        self.INPUT, self.MOUSE, self.KEY = INPUT, MOUSE, KEY
        self.user.SendInput.argtypes = [W.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
        self.user.GetAsyncKeyState.argtypes = [ctypes.c_int]
        self.user.GetAsyncKeyState.restype = W.SHORT
        self.user.GetForegroundWindow.restype = W.HWND
        self.user.GetClientRect.argtypes = [W.HWND, ctypes.POINTER(W.RECT)]
        self.user.ClientToScreen.argtypes = [W.HWND, ctypes.POINTER(W.POINT)]
        self.user.GetWindowTextW.argtypes = [W.HWND, W.LPWSTR, ctypes.c_int]

        self._pohjassa: set[int] = set()
        self._jaannos = 0.0
        # Ilman tata Windowsin ajastin liikkuu 15 ms askelin, mika on samaa
        # luokkaa kuin koko napautus.
        try:
            self.winmm = ctypes.WinDLL("winmm")
            self.winmm.timeBeginPeriod(1)
        except Exception:
            self.winmm = None

    def _laheta(self, *osat):
        taulu = (self.INPUT * len(osat))(*osat)
        if self.user.SendInput(len(osat), taulu, ctypes.sizeof(self.INPUT)) != len(osat):
            raise ctypes.WinError(ctypes.get_last_error())

    def liikuta(self, yksikkoa: float) -> None:
        """Suhteellinen sivuttaisliike. Murto-osat kerataan talteen."""
        summa = yksikkoa + self._jaannos
        kokonaiset = int(summa)
        self._jaannos = summa - kokonaiset
        if kokonaiset == 0:
            return
        osa = self.INPUT(type=0)
        osa.mi = self.MOUSE(dx=kokonaiset, dy=0, data=0, flags=0x0001,
                            time=0, extra=0)
        self._laheta(osa)

    def alas(self, scan: int) -> None:
        if scan in self._pohjassa:
            return
        osa = self.INPUT(type=1)
        osa.ki = self.KEY(vk=0, scan=scan, flags=0x0008, time=0, extra=0)
        self._laheta(osa)
        self._pohjassa.add(scan)

    def ylos(self, scan: int) -> None:
        if scan not in self._pohjassa:
            return
        osa = self.INPUT(type=1)
        osa.ki = self.KEY(vk=0, scan=scan, flags=0x0008 | 0x0002, time=0, extra=0)
        self._laheta(osa)
        self._pohjassa.discard(scan)

    def nappi(self, scan: int, ms: float = 60.0) -> None:
        self.alas(scan)
        time.sleep(ms / 1000.0)
        self.ylos(scan)

    def vapauta(self) -> None:
        for scan in list(self._pohjassa):
            try:
                self.ylos(scan)
            except Exception:
                pass
        self._jaannos = 0.0

    def painettu(self, vk: int) -> bool:
        return bool(self.user.GetAsyncKeyState(vk) & 0x8000)

    def ikkuna(self):
        """Etualalla olevan ikkunan asiakasalue ja otsikko."""
        W = self.W
        hwnd = self.user.GetForegroundWindow()
        if not hwnd:
            return None, ""
        nimi = ctypes.create_unicode_buffer(256)
        self.user.GetWindowTextW(hwnd, nimi, 256)
        laatikko = W.RECT()
        if not self.user.GetClientRect(hwnd, ctypes.byref(laatikko)):
            return None, nimi.value
        piste = W.POINT(0, 0)
        self.user.ClientToScreen(hwnd, ctypes.byref(piste))
        leveys = laatikko.right - laatikko.left
        korkeus = laatikko.bottom - laatikko.top
        if leveys < 640 or korkeus < 480:
            return None, nimi.value
        return {"left": piste.x, "top": piste.y,
                "width": leveys, "height": korkeus}, nimi.value

    def sulje(self) -> None:
        self.vapauta()
        if self.winmm:
            try:
                self.winmm.timeEndPeriod(1)
            except Exception:
                pass


# ==========================================================================
#  AJO
# ==========================================================================


def tyhjenna():
    sys.stdout.write("\033[H\033[J")


def aja(s: Saadot, testaa: bool, kartoita: bool = False) -> int:
    try:
        import numpy as np
        import mss
    except ImportError:
        print("Puuttuu kirjasto. Asenna:  pip install numpy mss")
        return 2

    silma = Silma(np, s)
    ohjain = Ohjain(s, kartoita=kartoita)
    loki = Loki(LOKI, s.loki and not testaa)
    kasi = None
    if not testaa:
        try:
            kasi = Kasi()
        except Exception as virhe:
            print(f"Syotteita ei voi lahettaa: {virhe}")
            return 2

    paalla = testaa            # testitilassa vain luetaan, ei kaynnisteta
    yrityksia = 0
    kasky = Kasky()
    havainto = Havainto()
    edellinen_f = False
    viesti = "F11 = kaynnista, F9 = lopeta" if not testaa else "vain luku, ei syotteita"
    piirretty = 0.0
    edellinen_vaihe = ohjain.vaihe
    ramppi_alkoi = 0.0
    ramppi_nahty = False

    print("Kaynnistetaan..." if not testaa else "Testitila: ei syotteita.")
    time.sleep(0.5)

    with mss.mss() as kaappaus:
        while True:
            nyt = time.perf_counter()

            if kasi is not None:
                if kasi.painettu(VK_F9):
                    kasi.vapauta()
                    print("\nLopetettu (F9).")
                    kasi.sulje()
                    return 0
                if kasi.painettu(VK_F11):
                    paalla = not paalla
                    viesti = "kaynnissa" if paalla else "tauolla"
                    if not paalla:
                        kasi.vapauta()
                    time.sleep(0.30)

            ikkuna, otsikko = (kasi.ikkuna() if kasi
                               else (_koko_ruutu(kaappaus), "testitila"))
            if ikkuna is None:
                havainto = Havainto()
                viesti = "peli ei ole etualalla"
            else:
                laatikko = silma.alue(ikkuna)
                kuva = np.asarray(kaappaus.grab(laatikko))[:, :, :3]
                havainto = silma.lue(kuva, ikkuna)

            if paalla and havainto.ok:
                if not havainto.kaynnissa:
                    # Yritys paattyi. Jos ramppi oli loytynyt, kirjataan
                    # miten sille kavi: aukesiko ja kuinka kauan kesti.
                    if ramppi_nahty:
                        loki.kirjaa("auki" if ohjain.paras >= s.auki_astetta * 0.9
                                    else "ramppi", havainto,
                                    paras=round(ohjain.paras, 2),
                                    matka=round(ohjain.paikka - ohjain.rampin_alku, 1),
                                    kesto_ms=round((nyt - ramppi_alkoi) * 1000.0))
                        ramppi_nahty = False
                    # Yritys ei ole kaynnissa: painetaan SPACE ja aloitetaan alusta.
                    if kasi is not None:
                        kasi.vapauta()
                        kasi.nappi(SCAN_SPACE)
                    ohjain.alusta()
                    edellinen_vaihe = ohjain.vaihe
                    yrityksia += 1
                    viesti = f"aloitetaan yritys {yrityksia}"
                    kasky = Kasky(teksti=viesti)
                    if s.yrityksia and yrityksia > s.yrityksia:
                        print("\nYritysraja tayttyi.")
                        break
                    time.sleep(0.35)
                else:
                    kasky = ohjain.paivita(nyt, havainto)

                    # Ramppi loytyi: merkitaan mista ja milloin.
                    if (edellinen_vaihe == ohjain.SKANNAUS
                            and kasky.vaihe in (ohjain.RAMPPI, ohjain.KARTOITUS)):
                        ramppi_alkoi = nyt
                        ramppi_nahty = True
                    # Kartoitus valmis: profiili talteen.
                    if (edellinen_vaihe == ohjain.KARTOITUS
                            and kasky.vaihe == ohjain.SKANNAUS
                            and len(ohjain.mittaukset) >= 3):
                        loki.kirjaa("profiili", havainto,
                                    pisteet=[[round(d, 1), round(a, 2)]
                                             for d, a in ohjain.mittaukset])
                    edellinen_vaihe = kasky.vaihe

                    if kasi is not None:
                        if kasky.f != edellinen_f:
                            (kasi.alas if kasky.f else kasi.ylos)(SCAN_F)
                            edellinen_f = kasky.f
                        if kasky.hiiri:
                            kasi.liikuta(kasky.hiiri)
            elif kasi is not None and edellinen_f:
                kasi.vapauta()
                edellinen_f = False

            if nyt - piirretty > 0.10:
                piirretty = nyt
                _piirra(s, ohjain, havainto, kasky, viesti, yrityksia, otsikko)

            jaljella = (1.0 / s.fps) - (time.perf_counter() - nyt)
            if jaljella > 0:
                time.sleep(jaljella)


def _koko_ruutu(kaappaus):
    monitori = kaappaus.monitors[1]
    return {"left": monitori["left"], "top": monitori["top"],
            "width": monitori["width"], "height": monitori["height"]}


def _piirra(s, ohjain, h, kasky, viesti, yrityksia, otsikko):
    tyhjenna()
    palkki = ""
    if h.ok:
        taydet = int(max(0.0, min(1.0, ohjain.kaanto(h) / 90.0)) * 30)
        palkki = "#" * taydet + "-" * (30 - taydet)
    rivit = [
        "  SCUM AUTOLOCKPICK",
        "",
        f"  ikkuna     {otsikko[:48]}",
        f"  tila       {viesti}",
        "",
        f"  lukko      {'nakyy' if h.ok else 'EI NAY'}"
        f"   yritys {'kaynnissa' if h.kaynnissa else 'ei kay'}",
        f"  kaanto     [{palkki}] {ohjain.kaanto(h):6.1f} deg" if h.ok
        else "  kaanto     -",
        f"  lepokulma  {ohjain.lepo:6.1f} deg",
        "",
        f"  vaihe      {kasky.vaihe}",
        f"  toiminto   {kasky.teksti}",
        f"  F          {'POHJASSA' if kasky.f else 'ylhaalla'}"
        f"   hiiri {kasky.hiiri:+7.1f} u",
        f"  paikka     {ohjain.paikka:7.0f} u   yrityksia {yrityksia}",
        "",
        f"  pikselit   avaimenreika {h.reika}   aikakaari {h.kaari}",
        "",
        "  F11 kaynnista/tauko    F9 lopeta",
    ]
    sys.stdout.write("\n".join(rivit) + "\n")
    sys.stdout.flush()


# ==========================================================================
#  KARTTA - rampin ja targetin leveys per lukkotyyppi
# ==========================================================================

# Lukkotyyppien tunnusluvut, mitattu kansion kuvat/Locktypes kuvista.
# Ruostesavy on punaisen ja sinisen erotus lukkopesan alueella.
LUKKOTYYPIT = [
    ("Basic", -1.0, 0.025),
    ("Medium", 1.8, 0.140),
    ("Rusted", 13.8, 0.078),
    ("Enforced", 29.4, 0.062),
]


def tunnista_lukko(savy: float, kirkkaat: float) -> str:
    """Arvaa lukkotyypin varisavyn perusteella.

    HUOM: tunnusluvut on mitattu yhdesta kuvasta per tyyppi. Pelin
    valaistus siirtaa niita, joten tama on suuntaa-antava. Jos lajittelu
    menee vaarin, luvut voi paivittaa yllaolevaan taulukkoon oman
    lokisi arvoista - ne nakyvat kartta.html:n taulukossa.
    """
    paras, ero = "tuntematon", 1e9
    for nimi, s_viite, k_viite in LUKKOTYYPIT:
        d = abs(savy - s_viite) / 10.0 + abs(kirkkaat - k_viite) * 5.0
        if d < ero:
            paras, ero = nimi, d
    return paras


def _leveydet(pisteet, kynnys: float):
    """Rampin ja targetin leveys yhdesta profiilista.

    Ramppi = matka, jolla pesa kaantyy kynnysta enemman.
    Target = matka, jolla kaanto on vahintaan 90 % profiilin huipusta,
             eli kaavion littea pohja.
    Kumpikaan ei voi olla tarkempi kuin kartoitusaskel: jos target on
    askelta kapeampi, se osuu korkeintaan yhteen mittauspisteeseen eika
    sen leveytta voi paatella. Silloin palautetaan 0, ja kartta kertoo
    vain etta se on askelta kapeampi.
    """
    yli = [d for d, a in pisteet if a >= kynnys]
    if len(yli) < 2:
        return None, None, 0.0
    huippu = max(a for _, a in pisteet)
    tasanne = [d for d, a in pisteet if a >= huippu * 0.9]
    ramppi = max(yli) - min(yli)
    target = (max(tasanne) - min(tasanne)) if len(tasanne) >= 2 else 0.0
    return ramppi, target, huippu


def lue_loki(polku: str):
    rivit = []
    if not os.path.exists(polku):
        return rivit
    with open(polku, encoding="utf-8") as fh:
        for rivi in fh:
            rivi = rivi.strip()
            if rivi:
                try:
                    rivit.append(json.loads(rivi))
                except Exception:
                    pass
    return rivit


def piirra_kartta(s: Saadot) -> int:
    """Lukee lokin, laskee leveydet ja kirjoittaa kartta.html."""
    rivit = lue_loki(LOKI)
    if not rivit:
        print(f"Lokia ei ole viela: {LOKI}")
        print("Aja ensin:  python lockpick.py --kartoita")
        return 2

    lukot: dict[str, dict] = {}
    for r in rivit:
        nimi = tunnista_lukko(r.get("savy", 0.0), r.get("kirkkaat", 0.0))
        tiedot = lukot.setdefault(nimi, {"profiilit": [], "auki": 0, "rampit": 0,
                                         "savyt": [], "kestot": []})
        tiedot["savyt"].append(r.get("savy", 0.0))
        if r["laji"] == "profiili":
            tiedot["profiilit"].append(r["pisteet"])
        elif r["laji"] == "auki":
            tiedot["auki"] += 1
            tiedot["kestot"].append(r.get("kesto_ms", 0))
        elif r["laji"] == "ramppi":
            tiedot["rampit"] += 1

    yhteenveto = []
    for nimi, t in sorted(lukot.items()):
        rampit, targetit = [], []
        for pisteet in t["profiilit"]:
            r, g, _ = _leveydet(pisteet, s.ramppi_astetta)
            if r:
                rampit.append(r)
                targetit.append(g)
        mediaani = lambda xs: sorted(xs)[len(xs) // 2] if xs else None
        yhteenveto.append({
            "nimi": nimi,
            "profiileja": len(t["profiilit"]),
            "auki": t["auki"],
            "rampit": t["rampit"],
            "ramppi": mediaani(rampit),
            "target": mediaani(targetit),
            "savy": sum(t["savyt"]) / len(t["savyt"]) if t["savyt"] else 0.0,
            "kesto": mediaani(t["kestot"]),
            "pisteet": t["profiilit"],
        })

    with open(KARTTA, "w", encoding="utf-8") as fh:
        fh.write(_kartta_html(yhteenveto, s))
    print(f"Kartta kirjoitettu: {KARTTA}")
    for y in yhteenveto:
        ramppi = f"{y['ramppi']:.0f} u" if y["ramppi"] else "-"
        target = (f"{y['target']:.0f} u" if y["target"]
                  else (f"<{s.kartoitus_askel:.0f} u" if y["profiileja"] else "-"))
        print(f"  {y['nimi']:12} profiileja {y['profiileja']:3}   "
              f"ramppi {ramppi:>8}   target {target:>8}   auennut {y['auki']}")
    kapein = [y["ramppi"] for y in yhteenveto if y["ramppi"]]
    if kapein:
        askel = min(kapein) * 0.8
        print(f"\nKapein mitattu ramppi {min(kapein):.0f} u "
              f"-> turvallinen askel_yksikkoa {askel:.0f}")
    try:
        import webbrowser
        webbrowser.open("file://" + os.path.abspath(KARTTA))
    except Exception:
        pass
    return 0


def _kaari(pisteet, x0, y0, leveys, korkeus, xmin, xmax, vari, paksuus=2.0):
    """Yksi murtoviiva SVG:hen."""
    if not pisteet:
        return ""
    kohdat = []
    for d, a in pisteet:
        x = x0 + (d - xmin) / max(1e-6, xmax - xmin) * leveys
        y = y0 + korkeus - max(0.0, min(90.0, a)) / 90.0 * korkeus
        kohdat.append(f"{x:.1f},{y:.1f}")
    return (f'<polyline fill="none" stroke="{vari}" stroke-width="{paksuus}" '
            f'stroke-linejoin="round" points="{" ".join(kohdat)}"/>')


def _kuvaaja(y: dict, s: Saadot) -> str:
    """Yhden lukkotyypin mitattu profiili piirrettyna."""
    L, K = 900, 260                      # kuvaajan koko
    vasen, ylos = 58, 18
    profiilit = y["pisteet"]
    if not profiilit:
        return '<p class="tyhja">Ei viela mittauksia.</p>'

    kaikki = [d for p in profiilit for d, _ in p]
    xmin, xmax = min(kaikki), max(kaikki)
    if xmax - xmin < 1:
        xmax = xmin + 1

    osat = []
    # ruudukko ja asteikko
    for aste in (0, 30, 60, 90):
        yy = ylos + K - aste / 90.0 * K
        osat.append(f'<line x1="{vasen}" y1="{yy:.1f}" x2="{vasen + L}" y2="{yy:.1f}" '
                    f'stroke="#20262b" stroke-width="1"/>')
        osat.append(f'<text x="{vasen - 10}" y="{yy + 4:.1f}" class="akseli" '
                    f'text-anchor="end">{aste}&#176;</text>')
    # rampin kynnys
    kyy = ylos + K - s.ramppi_astetta / 90.0 * K
    osat.append(f'<line x1="{vasen}" y1="{kyy:.1f}" x2="{vasen + L}" y2="{kyy:.1f}" '
                f'stroke="#00e5ff" stroke-width="1" stroke-dasharray="4 4" opacity="0.5"/>')

    # mitatut profiilit
    for p in profiilit[-25:]:
        osat.append(_kaari(p, vasen, ylos, L, K, xmin, xmax, "#00e5ff", 1.4))

    # mediaaniprofiili: kaikkien mittausten keskiarvo samassa kohdassa
    kori: dict[int, list] = {}
    for p in profiilit:
        for d, a in p:
            kori.setdefault(int(round(d / 25.0)), []).append(a)
    mediaani = sorted((k * 25.0, sorted(v)[len(v) // 2]) for k, v in kori.items())
    osat.append(_kaari(mediaani, vasen, ylos, L, K, xmin, xmax, "#ffffff", 3.0))

    # target-alue: se osuus jolla kaanto on yli 90 % huipusta
    if mediaani:
        huippu = max(a for _, a in mediaani)
        tasanne = [d for d, a in mediaani if a >= huippu * 0.9]
        if len(tasanne) >= 2:
            x1 = vasen + (min(tasanne) - xmin) / (xmax - xmin) * L
            x2 = vasen + (max(tasanne) - xmin) / (xmax - xmin) * L
            osat.append(f'<rect x="{x1:.1f}" y="{ylos}" width="{max(3, x2 - x1):.1f}" '
                        f'height="{K}" fill="#39ff6a" opacity="0.13"/>')
            osat.append(f'<text x="{(x1 + x2) / 2:.1f}" y="{ylos + K + 30}" '
                        f'class="target" text-anchor="middle">TARGET</text>')

    # x-asteikko
    for osuus in (0.0, 0.25, 0.5, 0.75, 1.0):
        x = vasen + osuus * L
        arvo = xmin + osuus * (xmax - xmin)
        osat.append(f'<text x="{x:.1f}" y="{ylos + K + 16}" class="akseli" '
                    f'text-anchor="middle">{arvo:+.0f} u</text>')

    return (f'<svg viewBox="0 0 {vasen + L + 20} {ylos + K + 46}" '
            f'role="img" aria-label="Mitattu ramppiprofiili">{"".join(osat)}</svg>')


def _kartta_html(yhteenveto: list, s: Saadot) -> str:
    rivit, kuvaajat = [], []
    for y in yhteenveto:
        ramppi = f"{y['ramppi']:.0f} u" if y["ramppi"] else "&#8211;"
        # Nollan levyinen target ei tarkoita ettei sita ole, vaan etta se
        # on kapeampi kuin mittausaskel.
        target = (f"{y['target']:.0f} u" if y["target"]
                  else (f"&lt; {s.kartoitus_askel:.0f} u" if y["profiileja"]
                        else "&#8211;"))
        askel = f"{y['ramppi'] * 0.8:.0f} u" if y["ramppi"] else "&#8211;"
        kesto = f"{y['kesto']:.0f} ms" if y["kesto"] else "&#8211;"
        rivit.append(
            f"<tr><td class='nimi'>{y['nimi']}</td>"
            f"<td>{y['profiileja']}</td><td>{y['auki']}</td>"
            f"<td class='cyan'>{ramppi}</td><td class='vihrea'>{target}</td>"
            f"<td>{askel}</td><td>{kesto}</td>"
            f"<td class='hailea'>{y['savy']:+.1f}</td></tr>")
        kuvaajat.append(
            f"<section><h2>{y['nimi']}</h2>"
            f"<p class='alaotsikko'>{y['profiileja']} mitattua ramppia"
            + (f" &middot; ramppi <b class='cyan'>{ramppi}</b>" if y["ramppi"] else "")
            + (f" &middot; target <b class='vihrea'>{target}</b>" if y["target"] else "")
            + "</p>" + _kuvaaja(y, s) + "</section>")

    kapein = [y["ramppi"] for y in yhteenveto if y["ramppi"]]
    suositus = (f"Kapein mitattu ramppi on <b>{min(kapein):.0f} u</b>, joten "
                f"turvallinen <code>askel_yksikkoa</code> on "
                f"<b>{min(kapein) * 0.8:.0f}</b>. Nyt kaytossa on "
                f"<b>{s.askel_yksikkoa:.0f}</b>."
                if kapein else
                "Ramppeja ei ole viela mitattu tarpeeksi askelsuosituksen antamiseen.")

    return f"""<!doctype html>
<html lang="fi"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lukkokartta</title>
<style>
  :root {{ color-scheme: dark; }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; padding: 32px 24px 64px; background: #0b0e10; color: #d7dee4;
         font: 15px/1.6 "Segoe UI", system-ui, sans-serif; }}
  .kehys {{ max-width: 1040px; margin: 0 auto; }}
  h1 {{ font-size: 26px; letter-spacing: .06em; margin: 0 0 4px; color: #fff; }}
  .johdanto {{ color: #8c98a3; margin: 0 0 28px; max-width: 70ch; }}
  h2 {{ font-size: 18px; margin: 0; color: #fff; letter-spacing: .04em; }}
  section {{ background: #11161a; border: 1px solid #1e252b; border-radius: 10px;
             padding: 18px 20px 8px; margin-bottom: 20px; }}
  .alaotsikko {{ color: #8c98a3; margin: 2px 0 12px; font-size: 13px; }}
  svg {{ width: 100%; height: auto; display: block; }}
  .akseli {{ fill: #66707a; font-size: 11px; font-family: inherit; }}
  .target {{ fill: #39ff6a; font-size: 11px; letter-spacing: .12em; font-weight: 600; }}
  table {{ width: 100%; border-collapse: collapse; margin-bottom: 28px;
           background: #11161a; border: 1px solid #1e252b; border-radius: 10px;
           overflow: hidden; }}
  th, td {{ padding: 9px 12px; text-align: right; border-bottom: 1px solid #1a2126; }}
  th {{ color: #8c98a3; font-weight: 600; font-size: 12px; letter-spacing: .06em;
        text-transform: uppercase; text-align: right; }}
  th:first-child, td:first-child {{ text-align: left; }}
  tbody tr:last-child td {{ border-bottom: none; }}
  .nimi {{ color: #fff; font-weight: 600; }}
  .cyan {{ color: #00e5ff; }} .vihrea {{ color: #39ff6a; }} .hailea {{ color: #66707a; }}
  .huomio {{ background: #11161a; border-left: 3px solid #00e5ff; padding: 14px 18px;
             border-radius: 0 8px 8px 0; margin-bottom: 28px; }}
  .selite {{ display: flex; gap: 22px; flex-wrap: wrap; color: #8c98a3;
             font-size: 13px; margin: 0 0 24px; }}
  .merkki {{ display: inline-block; width: 22px; height: 3px; vertical-align: middle;
             margin-right: 7px; border-radius: 2px; }}
  code {{ background: #1a2126; padding: 1px 6px; border-radius: 4px;
          font-size: 13px; color: #d7dee4; }}
  footer {{ color: #66707a; font-size: 13px; margin-top: 36px; max-width: 70ch; }}
</style></head><body><div class="kehys">

<h1>LUKKOKARTTA</h1>
<p class="johdanto">Mitatut rampit ja targetit lukkotyypeittain. Pystyakseli on
lukkopesan kaanto, vaaka-akseli hiiriyksikkoa siita kohdasta jossa ramppi
havaittiin. Targetin PAIKKAA ei voi kartoittaa &#8211; se arvotaan joka
yrityksella uudelleen. Leveydet sen sijaan ovat lukkotyypin ominaisuus.</p>

<div class="huomio">{suositus}</div>

<table><thead><tr>
  <th>Lukko</th><th>Profiileja</th><th>Auennut</th><th>Ramppi</th>
  <th>Target</th><th>Suositeltu askel</th><th>Aika ramppiin</th><th>Ruostesavy</th>
</tr></thead><tbody>{"".join(rivit)}</tbody></table>

<p class="selite">
  <span><i class="merkki" style="background:#00e5ff"></i>yksittainen mitattu ramppi</span>
  <span><i class="merkki" style="background:#fff"></i>mediaani</span>
  <span><i class="merkki" style="background:#39ff6a"></i>target: yli 90 % huipusta</span>
</p>

{"".join(kuvaajat)}

<footer>Kartta syntyy tiedostosta <code>loki.jsonl</code> komennolla
<code>python lockpick.py --kartta</code>. Lisaa mittauksia:
<code>python lockpick.py --kartoita</code>. Lukkotyyppi tunnistetaan varisavysta,
joka on mitattu yhdesta kuvasta per tyyppi &#8211; pelin valaistus voi siirtaa
sita, ja silloin lajittelu menee vaarin. Sarake &#8220;ruostesavy&#8221; kertoo
oman lokisi arvot, joilla taulukon <code>LUKKOTYYPIT</code> voi paivittaa.
<br><br>Kumpaakaan leveytta ei voi mitata tarkemmin kuin mittausaskel, joka on
nyt <code>kartoitus_askel = {s.kartoitus_askel:.0f}</code>. Jos target nakyy
muodossa &#8220;&lt; {s.kartoitus_askel:.0f} u&#8221;, pienenna askelta ja
kartoita uudelleen &#8211; mittaus hidastuu mutta tarkentuu.</footer>

</div></body></html>
"""


def main(argv=None) -> int:
    jasennin = argparse.ArgumentParser(description="SCUM autolockpick")
    jasennin.add_argument("--testaa", action="store_true",
                          help="lue ruutua lahettamatta yhtaan syotetta")
    jasennin.add_argument("--kartoita", action="store_true",
                          help="mittaa rampin leveys sen sijaan etta avaa lukon")
    jasennin.add_argument("--kartta", action="store_true",
                          help="piirra kartta.html lokista ja lopeta")
    jasennin.add_argument("--tallenna", action="store_true",
                          help="kirjoita asetukset.json ja lopeta")
    args = jasennin.parse_args(argv)

    s = lataa_saadot()
    if args.tallenna:
        tallenna_saadot(s)
        print(f"Asetukset kirjoitettu: {ASETUKSET}")
        return 0
    if args.kartta:
        return piirra_kartta(s)
    try:
        return aja(s, args.testaa, args.kartoita)
    except KeyboardInterrupt:
        print("\nKeskeytetty.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
