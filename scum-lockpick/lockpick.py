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

        return Havainto(ok=True, kaanto=kaanto, kaynnissa=kaari_n >= s.kaari_pikselit,
                        kaari=kaari_n, reika=reika_n)

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
    ALKUUN, SKANNAUS, RAMPPI = "alkuun", "skannaus", "ramppi"

    def __init__(self, s: Saadot):
        self.s = s
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
            self.vaihe = self.RAMPPI
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


def aja(s: Saadot, testaa: bool) -> int:
    try:
        import numpy as np
        import mss
    except ImportError:
        print("Puuttuu kirjasto. Asenna:  pip install numpy mss")
        return 2

    silma = Silma(np, s)
    ohjain = Ohjain(s)
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
                    # Yritys ei ole kaynnissa: painetaan SPACE ja aloitetaan alusta.
                    if kasi is not None:
                        kasi.vapauta()
                        kasi.nappi(SCAN_SPACE)
                    ohjain.alusta()
                    yrityksia += 1
                    viesti = f"aloitetaan yritys {yrityksia}"
                    kasky = Kasky(teksti=viesti)
                    if s.yrityksia and yrityksia > s.yrityksia:
                        print("\nYritysraja tayttyi.")
                        break
                    time.sleep(0.35)
                else:
                    kasky = ohjain.paivita(nyt, havainto)
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


def main(argv=None) -> int:
    jasennin = argparse.ArgumentParser(description="SCUM autolockpick")
    jasennin.add_argument("--testaa", action="store_true",
                          help="lue ruutua lahettamatta yhtaan syotetta")
    jasennin.add_argument("--tallenna", action="store_true",
                          help="kirjoita asetukset.json ja lopeta")
    args = jasennin.parse_args(argv)

    s = lataa_saadot()
    if args.tallenna:
        tallenna_saadot(s)
        print(f"Asetukset kirjoitettu: {ASETUKSET}")
        return 0
    try:
        return aja(s, args.testaa)
    except KeyboardInterrupt:
        print("\nKeskeytetty.")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
