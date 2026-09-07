# -*- coding: utf-8 -*-
"""SCUM-lukonavaaja.

Yksi ajatus, joka on mitattu kayttajan omasta pelidatasta:

    KAANTO ON RAIKKA. Painallus lahella aukkoa vie pesaa eteenpain, ja se
    JAA sinne. Etaisyys ei ennusta kaannon TASOA vaan sen MUUTOSTA:

        painallus alle 0.05 paassa aukosta   ->  +0.38 kaantoa
        painallus yli  0.50 paassa aukosta   ->  +0.04 kaantoa

Siksi lukkoa ei tarvitse ratkaista yhdella kertaa. Riittaa loytaa mika
tahansa kohta joka vie sita eteenpain, ja painaa siina niin kauan kuin se
liikkuu. Kun se pysahtyy, nykaistaan hiukan ja jatketaan. Edistys sailyy
koko yrityksen yli.

Tap, tap, tap, taap, taaaap, auki.

Ei cv2:ta, ei koneoppimista, ei injektointia. Numpy + mss + ctypes.

    python lukko.py            avaa lukkoja
    python lukko.py --mittaa   mittausajo: kiinteä ruudukko, lokittaa kaiken
    python lukko.py --sovita   sovittaa vastemallin mittausdatasta
    python lukko.py --testaa   nakotesti referenssikuvia vasten
"""
from __future__ import annotations

import argparse
import csv
import ctypes
import json
import math
import os

import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import List, Optional, Tuple

import numpy as np

JUURI = Path(__file__).resolve().parent
LOKI = JUURI / "loki"
SAADOT_TIEDOSTO = JUURI / "saadot.json"
VASTE_TIEDOSTO = JUURI / "vaste.json"
LOKI.mkdir(exist_ok=True)


# ==========================================================================
#  SAADOT - kaikki saadettava on tassa, ei missaan muualla
# ==========================================================================

@dataclass
class Saadot:
    # --- naytto ------------------------------------------------------------
    naytto: int = 0                  # 0 = etsi automaattisesti
    rajaus_sade: float = 0.30        # kaapattava nelio, x ruudun korkeus

    # --- lukon mitat, x ruudun korkeus -------------------------------------
    # Nama on varmennettu pelin omista kuvakaappauksista: pesa levossa 1.0
    # astetta, auki 89.2, ja tiirikka kummassakaan aariasennossa ei vuoda
    # mittaukseen.
    reika_sade: float = 0.0519       # musta avaimenreika pesan sisalla
    reika_keskus_y: float = -0.0028
    reika_tumma_max: int = 22        # mika lasketaan mustaksi
    reika_min_pikselit: int = 200
    reika_min_pitkulaisuus: float = 1.8
    lukon_sade: float = 0.139        # pesan ulkoreuna

    # --- onko yritys kaynnissa / auki ---------------------------------------
    kaari_kirkas: int = 185          # ajastinkaari lukon ymparilla
    kaari_min: int = 1500            # nain monta pikselia = yritys kaynnissa
    palkki_kirkas: int = 200         # SUCCESS-teksti keskella
    palkki_min: int = 2500
    palkki_korkeus: float = 0.051
    palkki_leveys: float = 0.204

    # --- hiiri --------------------------------------------------------------
    jana_yksikkoa: float = 6000.0    # hiiriyksikkoa lukon laidasta laitaan
    pala_yksikkoa: int = 900         # isoin yksittainen SendInput-askel
    koti_ylitys: float = 1.4         # nain monta janaa vasemmalle = seina
    liike_lepo_ms: int = 18          # anna pelin ehtia siirron jalkeen

    # --- napautys ja lukeminen ----------------------------------------------
    tap_ms: int = 45                 # kevyt koputus haussa
    lue_ms: int = 90                 # kauanko koputuksen jalkeen katsotaan
    lue_min_ms: int = 40

    # --- raikka: milloin painetaan pitkaan ----------------------------------
    edistys_min: float = 0.05        # nain paljon kaantoa = "lukko liikkui"
    aloitus_ms: int = 70             # jos lukko ei ala liikkua tassa, irti heti
    # Otetta pidetaan vain niin kauan kuin se TUOTTAA. Mitattu kayttajan
    # datasta: aukon vieressa pesa kaantyy noin 2.6 yksikkoa sekunnissa,
    # kaukana 0.28. Kynnys naiden valissa erottaa tuottavan otteen turhasta.
    vauhti_min: float = 0.8          # kaantoa/s jotta otetta kannattaa pitaa
    pito_ikkuna_ms: int = 120        # nain pitkalta palalta vauhti mitataan
    # Kun pesa on jo yli puolivalissa, otetta ei irroteta vauhdin hiipuessa:
    # siina kohtaa hidaskin eteneminen on menossa maaliin, ja irrottaminen
    # heittaisi koko yrityksen hukkaan.
    pito_loppuun_asti: float = 0.55
    pito_max_ms: int = 900           # eika koskaan pidempaan kuin tama
    kohina_max: float = 0.025        # levossa oleva lukko lukee alle taman

    # --- haku ---------------------------------------------------------------
    haku_askel: float = 0.12         # koputusvali kun mikaan ei viela vastaa
    saato_askel: float = 0.05        # nykaisy kun edistys pysahtyy
    saato_min: float = 0.012         # pienin nykaisy ennen luovuttamista
    jatka_hakua: bool = True         # seuraava yritys jatkaa mihin jai

    # --- yritys -------------------------------------------------------------
    budjetti_s: float = 3.4          # kauanko yhta yritysta jatketaan
    valissa_s: float = 0.55
    paina_space: bool = True

    # --- nappaimet ----------------------------------------------------------
    f_nappain: int = 0x46
    space_nappain: int = 0x20
    seis_nappain: int = 0x7B         # F12
    tauko_nappain: int = 0x79        # F10

    # --- loki ---------------------------------------------------------------
    lokita: bool = True

    @staticmethod
    def lataa() -> "Saadot":
        if not SAADOT_TIEDOSTO.exists():
            s = Saadot()
            SAADOT_TIEDOSTO.write_text(json.dumps(asdict(s), indent=2), encoding="utf-8")
            return s
        raw = json.loads(SAADOT_TIEDOSTO.read_text(encoding="utf-8"))
        kelpaa = set(Saadot.__dataclass_fields__.keys())
        s = Saadot(**{k: v for k, v in raw.items() if k in kelpaa})
        SAADOT_TIEDOSTO.write_text(json.dumps(asdict(s), indent=2), encoding="utf-8")
        return s


# ==========================================================================
#  SILMA - ruudulta kolme lukua: kaanto, kaynnissa, auki
# ==========================================================================

@dataclass
class Havainto:
    ok: bool = False            # naittiinko lukko ollenkaan
    kaanto: float = 0.0         # 0 = levossa, 1 = tayysin kaantynyt
    kulma: float = 0.0          # sama asteina
    kaynnissa: bool = False     # ajastinkaari nakyy
    auki: bool = False          # SUCCESS-ruutu
    kaari: int = 0
    palkki: int = 0
    aika: float = 0.0


class Silma:
    """Kaikki mittaus tehdaan maskeilla ja toisella momentilla.

    Kaannon lukeminen maksaa 3.4 ms. Vanha rivihakumenetelma maksoi 24 ms
    JA antoi paikallaan olevalle lukolle 0.089 - se kohina oli tunnistimessa,
    ei pelissa.
    """

    def __init__(self, s: Saadot):
        self.s = s
        self.sct = None
        self.alue_muisti = None
        self._koko = None
        self._edellinen_kulma = 0.0

    # ---- kaappaus ---------------------------------------------------------

    def avaa(self):
        import mss
        self.sct = mss.mss()
        naytot = self.sct.monitors
        i = self.s.naytto if self.s.naytto else self._etsi_naytto(naytot)
        i = min(max(1, i), len(naytot) - 1)
        self.naytto = naytot[i]
        p = int(self.s.rajaus_sade * self.naytto["height"])
        cx = self.naytto["left"] + self.naytto["width"] // 2
        cy = self.naytto["top"] + self.naytto["height"] // 2
        self.alue = {"left": cx - p, "top": cy - p, "width": p * 2, "height": p * 2}
        self.korkeus = self.naytto["height"]
        return i

    def _etsi_naytto(self, naytot) -> int:
        """Etsii nayton jolla lukko on: siella missa ajastinkaari nakyy."""
        paras, pisteet = 1, -1
        for i in range(1, len(naytot)):
            m = naytot[i]
            p = int(self.s.rajaus_sade * m["height"])
            cx, cy = m["left"] + m["width"] // 2, m["top"] + m["height"] // 2
            kuva = np.asarray(self.sct.grab(
                {"left": cx - p, "top": cy - p, "width": p * 2, "height": p * 2}))[:, :, :3]
            self.korkeus = m["height"]
            h = self._lue_kuva(kuva)
            if h.kaari > pisteet:
                paras, pisteet = i, h.kaari
        return paras

    def lue(self) -> Havainto:
        kuva = np.asarray(self.sct.grab(self.alue))[:, :, :3]
        return self._lue_kuva(kuva)

    # ---- mittaus ----------------------------------------------------------

    def _ruudukko(self, korkeus: int, leveys: int):
        if self._koko != (korkeus, leveys):
            y = np.arange(korkeus, dtype=np.float32) - korkeus / 2.0
            x = np.arange(leveys, dtype=np.float32) - leveys / 2.0
            yy, xx = np.meshgrid(y, x, indexing="ij")
            cy = self.s.reika_keskus_y * self.korkeus
            et = np.sqrt(xx ** 2 + (yy - cy) ** 2)
            r = self.s.lukon_sade * self.korkeus
            self._xx, self._yy = xx, yy - cy
            self._reika_maski = et < self.s.reika_sade * self.korkeus
            self._kaari_maski = (et > r * 1.05) & (et < r * 1.75)
            ph = max(8, int(self.korkeus * self.s.palkki_korkeus))
            pw = max(8, int(self.korkeus * self.s.palkki_leveys))
            cy0, cx0 = korkeus // 2, leveys // 2
            self._palkki = (slice(max(0, cy0 - ph), cy0 + ph),
                            slice(max(0, cx0 - pw), cx0 + pw))
            self._koko = (korkeus, leveys)
        return self._reika_maski

    def _lue_kuva(self, kuva_bgr) -> Havainto:
        b = kuva_bgr[:, :, 0].astype(np.float32)
        g = kuva_bgr[:, :, 1].astype(np.float32)
        r = kuva_bgr[:, :, 2].astype(np.float32)
        kirkkaus = 0.114 * b + 0.587 * g + 0.299 * r
        korkeus, leveys = kirkkaus.shape
        reika_maski = self._ruudukko(korkeus, leveys)

        kaari = int(((kirkkaus > self.s.kaari_kirkas) & self._kaari_maski).sum())
        palkki = int((kirkkaus[self._palkki] > self.s.palkki_kirkas).sum())
        auki = palkki >= self.s.palkki_min and kaari <= self.s.kaari_min * 0.5

        reika = (kirkkaus < self.s.reika_tumma_max) & reika_maski
        n = int(reika.sum())
        if n < self.s.reika_min_pikselit:
            return Havainto(ok=False, kaynnissa=kaari >= self.s.kaari_min,
                            auki=auki, kaari=kaari, palkki=palkki, aika=time.monotonic())

        kulma = self._paasuunta(self._xx[reika], self._yy[reika])
        if kulma is None:
            return Havainto(ok=False, kaynnissa=kaari >= self.s.kaari_min,
                            auki=auki, kaari=kaari, palkki=palkki, aika=time.monotonic())
        return Havainto(ok=True, kaanto=float(np.clip(kulma / 90.0, 0.0, 1.0)), kulma=kulma,
                        kaynnissa=kaari >= self.s.kaari_min, auki=auki,
                        kaari=kaari, palkki=palkki, aika=time.monotonic())

    def _paasuunta(self, x, y) -> Optional[float]:
        """Mustien pikselien paasuunta asteina, lepo ~0 ja auki ~90."""
        x = x.astype(np.float64); y = y.astype(np.float64)
        x = x - x.mean(); y = y - y.mean()
        xx = float((x * x).mean()); yy = float((y * y).mean()); xy = float((x * y).mean())
        juuri = math.sqrt(max(0.0, (xx - yy) ** 2 + 4.0 * xy * xy))
        pieni = (xx + yy - juuri) / 2.0
        iso = (xx + yy + juuri) / 2.0
        if pieni <= 1e-9 or math.sqrt(iso / pieni) < self.s.reika_min_pitkulaisuus:
            return None
        kulma = math.degrees(0.5 * math.atan2(2.0 * xy, xx - yy)) + 90.0
        # Paasuunta toistuu 180 asteen valein: valitaan lahin edelliseen ja
        # pakotetaan siihen valiin jonka pesa voi fyysisesti ottaa.
        while kulma - self._edellinen_kulma > 90.0:
            kulma -= 180.0
        while self._edellinen_kulma - kulma > 90.0:
            kulma += 180.0
        while kulma < -25.0:
            kulma += 180.0
        while kulma > 125.0:
            kulma -= 180.0
        self._edellinen_kulma = kulma
        return kulma

    def nollaa_kulma(self):
        self._edellinen_kulma = 0.0


# ==========================================================================
#  KASI - hiiri ja nappaimet
# ==========================================================================

WINDOWS = os.name == "nt"

if WINDOWS:
    user32 = ctypes.windll.user32
    INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
    KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE = 0x0002, 0x0008
    MOUSEEVENTF_MOVE = 0x0001

    class _HIIRI(ctypes.Structure):
        _fields_ = [("dx", ctypes.c_long), ("dy", ctypes.c_long), ("data", ctypes.c_ulong),
                    ("liput", ctypes.c_ulong), ("aika", ctypes.c_ulong),
                    ("lisa", ctypes.POINTER(ctypes.c_ulong))]

    class _NAPPI(ctypes.Structure):
        _fields_ = [("vk", ctypes.c_ushort), ("scan", ctypes.c_ushort), ("liput", ctypes.c_ulong),
                    ("aika", ctypes.c_ulong), ("lisa", ctypes.POINTER(ctypes.c_ulong))]

    class _RAUTA(ctypes.Structure):
        _fields_ = [("viesti", ctypes.c_ulong), ("l", ctypes.c_short), ("h", ctypes.c_ushort)]

    class _UNIONI(ctypes.Union):
        _fields_ = [("hiiri", _HIIRI), ("nappi", _NAPPI), ("rauta", _RAUTA)]

    class _SYOTE(ctypes.Structure):
        _fields_ = [("tyyppi", ctypes.c_ulong), ("u", _UNIONI)]


class Kasi:
    """Hiiri liikkuu paloina, ilman leikkausta.

    Vanha versio leikkasi jokaisen askeleen 140 yksikkoon ja salli 8 kierrosta,
    eli tiirikka ei voinut liikkua enempaa kuin 0.187 lukosta - koskaan.
    """

    def __init__(self, s: Saadot):
        self.s = s
        self.f_alhaalla = False
        if WINDOWS:
            try:
                ctypes.windll.shcore.SetProcessDpiAwareness(2)
            except Exception:
                try:
                    user32.SetProcessDPIAware()
                except Exception:
                    pass
            try:
                ctypes.windll.winmm.timeBeginPeriod(1)
            except Exception:
                pass

    def _laheta(self, syote) -> None:
        if WINDOWS:
            user32.SendInput(1, ctypes.byref(syote), ctypes.sizeof(syote))

    def siirra(self, yksikkoa: float) -> None:
        """Siirra tiirikkaa nain monta hiiriyksikkoa. Iso siirto menee paloina
        perakkain, ilman ruudunlukuja valissa."""
        if not WINDOWS:
            return
        jaljella = int(round(abs(yksikkoa)))
        merkki = 1 if yksikkoa > 0 else -1
        lisa = ctypes.c_ulong(0)
        while jaljella > 0:
            askel = min(self.s.pala_yksikkoa, jaljella)
            self._laheta(_SYOTE(tyyppi=INPUT_MOUSE, u=_UNIONI(
                hiiri=_HIIRI(merkki * askel, 0, 0, MOUSEEVENTF_MOVE, 0, ctypes.pointer(lisa)))))
            jaljella -= askel
            if jaljella > 0:
                time.sleep(0.003)

    def _nappi(self, vk: int, alas: bool) -> None:
        if not WINDOWS:
            return
        scan = user32.MapVirtualKeyW(vk, 0)
        liput = KEYEVENTF_SCANCODE | (0 if alas else KEYEVENTF_KEYUP)
        lisa = ctypes.c_ulong(0)
        self._laheta(_SYOTE(tyyppi=INPUT_KEYBOARD, u=_UNIONI(
            nappi=_NAPPI(0, scan, liput, 0, ctypes.pointer(lisa)))))

    def f_alas(self) -> None:
        if not self.f_alhaalla:
            self._nappi(self.s.f_nappain, True)
            self.f_alhaalla = True

    def f_ylos(self) -> None:
        if self.f_alhaalla:
            self._nappi(self.s.f_nappain, False)
            self.f_alhaalla = False

    def nappaise(self, vk: int, ms: int = 30) -> None:
        self._nappi(vk, True)
        time.sleep(ms / 1000.0)
        self._nappi(vk, False)

    def pohjassa(self, vk: int) -> bool:
        return bool(WINDOWS and (user32.GetAsyncKeyState(vk) & 0x8000))


# ==========================================================================
#  VASTE - paljonko lukko liikahtaa etaisyyden funktiona
# ==========================================================================

class Vaste:
    """delta_kaanto = A * exp(-d / L), sovitettuna oikeasta pelidatasta.

    Tata EI kayteta ratkaisemiseen ennen kuin sovitus on tarpeeksi hyva.
    Nykyinen sovitus kayttajan 9 voitosta (n=23) selittaa vain 18%
    varianssista, mika ei riita mihinkaan. Raikka-strategia alla ei tarvitse
    tata ollenkaan; malli on siella vain jotta mittausajo voi parantaa sita
    ja jotta sen laatu on nakyvissa.
    """

    def __init__(self):
        self.A = 0.38
        self.L = 0.49
        self.n = 23
        self.selitysaste = 0.18
        self.lataa()

    def lataa(self) -> None:
        if VASTE_TIEDOSTO.exists():
            try:
                d = json.loads(VASTE_TIEDOSTO.read_text(encoding="utf-8"))
                self.A = float(d.get("A", self.A))
                self.L = float(d.get("L", self.L))
                self.n = int(d.get("n", self.n))
                self.selitysaste = float(d.get("selitysaste", self.selitysaste))
            except Exception:
                pass

    def tallenna(self) -> None:
        VASTE_TIEDOSTO.write_text(json.dumps(
            {"A": self.A, "L": self.L, "n": self.n, "selitysaste": self.selitysaste},
            indent=2), encoding="utf-8")

    def __call__(self, d: float) -> float:
        return float(self.A * math.exp(-abs(d) / max(1e-6, self.L)))

    def luotettava(self) -> bool:
        """Riittaako malli siihen etta paikka lasketaan sen avulla?"""
        return self.n >= 150 and self.selitysaste >= 0.55

    def sovita(self, etaisyydet: List[float], muutokset: List[float]) -> None:
        d = np.asarray(etaisyydet, dtype=np.float64)
        m = np.clip(np.asarray(muutokset, dtype=np.float64), 0.0, None)
        if len(d) < 10:
            return
        paras = None
        for A in np.arange(0.10, 1.01, 0.01):
            for L in np.arange(0.03, 0.90, 0.01):
                e = float(np.mean((A * np.exp(-d / L) - m) ** 2))
                if paras is None or e < paras[0]:
                    paras = (e, float(A), float(L))
        mse, self.A, self.L = paras
        self.n = len(d)
        var = float(np.var(m))
        self.selitysaste = float(1.0 - mse / var) if var > 1e-9 else 0.0


# ==========================================================================
#  AVAAJA - raikka
# ==========================================================================

@dataclass
class Painallus:
    """Yksi F-painallus ja mita siita seurasi."""
    paikka: float
    kaanto_ennen: float
    kaanto_jalkeen: float
    kesto_ms: float
    auki: bool = False

    @property
    def edistys(self) -> float:
        return self.kaanto_jalkeen - self.kaanto_ennen


class Avaaja:
    """Painaa siella missa lukko liikkuu, ja vain niin kauan kuin se liikkuu.

    Tasta syntyy itsestaan "tap, tap, tap, taap, taaaap, auki": lyhyet
    koputukset tulevat sinne missa mitaan ei tapahdu, pitkat painallukset
    sinne missa pesa kaantyy. Kestoa ei ole kirjoitettu mihinkaan - se on
    seuraus siita etta otetta pidetaan tasan niin kauan kuin se tuottaa.
    """

    KOTI, HAKU, SAATO, VALMIS = "koti", "haku", "saato", "valmis"

    def __init__(self, s: Saadot, silma: Silma, kasi: Kasi):
        self.s = s
        self.silma = silma
        self.kasi = kasi
        self.jatka_paikasta = 0.0

    # ---- perusliikkeet ----------------------------------------------------

    def kotiin(self) -> None:
        """Vasempaan seinaan asti, jolloin paikka tiedetaan ilman etta
        tiirikkaa tarvitsee nahda ruudulla ollenkaan."""
        self.kasi.f_ylos()
        self.kasi.siirra(-self.s.jana_yksikkoa * self.s.koti_ylitys)
        time.sleep(0.05)
        self.paikka = 0.0
        self.silma.nollaa_kulma()

    def siirry(self, paikkaan: float) -> None:
        paikkaan = float(np.clip(paikkaan, 0.0, 1.0))
        ero = paikkaan - self.paikka
        if abs(ero) < 1e-4:
            return
        self.kasi.f_ylos()
        self.kasi.siirra(ero * self.s.jana_yksikkoa)
        self.paikka = paikkaan
        time.sleep(self.s.liike_lepo_ms / 1000.0)

    def paina(self) -> Painallus:
        """Paina F ja pida vain niin kauan kuin ote TUOTTAA.

        Kaksi ehtoa, molemmat mitattuja:
          - jos pesa ei ala liikkua aloitus_ms:ssa, ote irtoaa heti. Se on se
            kevyt koputus, ja se on suurin osa painalluksista.
          - jos se liikkuu, vauhtia mitataan pito_ikkuna_ms:n paloissa ja ote
            irtoaa heti kun vauhti putoaa alle vauhti_min:n.

        Nain F ei ole koskaan pohjassa lukkoa vastaan joka ei pyori, ja
        rytmi "tap, tap, tap, taap, taaaap" syntyy itsestaan - kestoa ei ole
        kirjoitettu mihinkaan.
        """
        ennen = self.silma.lue()
        pohja = ennen.kaanto if ennen.ok else 0.0
        paras = pohja
        alku = time.monotonic()
        self.kasi.f_alas()
        ikkuna_alku = alku
        ikkuna_kaanto = pohja
        liikkeella = False
        auki = False
        while True:
            h = self.silma.lue()
            nyt = time.monotonic()
            if h.auki:
                auki = True
                break
            if h.ok and h.kaanto > paras:
                paras = h.kaanto
            kulunut_ms = (nyt - alku) * 1000.0
            if not liikkeella:
                if paras > pohja + self.s.edistys_min:
                    liikkeella = True
                    ikkuna_alku, ikkuna_kaanto = nyt, paras
                elif kulunut_ms >= self.s.aloitus_ms:
                    break
            else:
                ikkuna_s = nyt - ikkuna_alku
                if ikkuna_s * 1000.0 >= self.s.pito_ikkuna_ms:
                    vauhti = (paras - ikkuna_kaanto) / max(1e-6, ikkuna_s)
                    # Maali on jo nakyvissa: pidetaan kiinni vaikka hidastuu.
                    if vauhti < self.s.vauhti_min and paras < self.s.pito_loppuun_asti:
                        break
                    ikkuna_alku, ikkuna_kaanto = nyt, paras
            if kulunut_ms >= self.s.pito_max_ms:
                break
        self.kasi.f_ylos()
        return Painallus(self.paikka, pohja, paras, (time.monotonic() - alku) * 1000.0, auki)

    # ---- yksi yritys ------------------------------------------------------

    def yritys(self, lokitin=None) -> Tuple[bool, List[Painallus]]:
        self.kotiin()
        paikka = self.jatka_paikasta if self.s.jatka_hakua else 0.0
        self.siirry(paikka)

        painallukset: List[Painallus] = []
        alku = time.monotonic()
        vaihe = self.HAKU
        paras_paikka = paikka
        paras_edistys = 0.0
        suunta = 1
        askel = self.s.saato_askel

        while time.monotonic() - alku < self.s.budjetti_s:
            if self.kasi.pohjassa(self.s.seis_nappain):
                self.kasi.f_ylos()
                return False, painallukset
            while self.kasi.pohjassa(self.s.tauko_nappain):
                self.kasi.f_ylos()
                time.sleep(0.05)

            p = self.paina()
            painallukset.append(p)
            if lokitin:
                lokitin(p, vaihe)
            if p.auki:
                self.jatka_paikasta = 0.0
                return True, painallukset

            if vaihe == self.HAKU:
                if p.edistys >= self.s.edistys_min:
                    # Lukko vastasi tassa. Siirrytaan kiipeamaan huipulle.
                    vaihe = self.SAATO
                    paras_edistys, paras_paikka = p.edistys, self.paikka
                    suunta, askel = 1, self.s.saato_askel
                    self.siirry(paras_paikka + suunta * askel)
                else:
                    # Seuraava koputuskohta. Oikeaan reunaan osuessa
                    # kierretaan alkuun eika painauduta seinaa vasten.
                    seuraava = self.paikka + self.s.haku_askel
                    self.siirry(0.0 if seuraava > 0.995 else seuraava)
            else:
                # Maenkiipeily: parempaan suuntaan samalla askeleella, ja
                # huonon jalkeen takaisin parhaaseen, suunta vaihtoon ja
                # askel puoliksi. Nain paadytaan huipulle eika vaellella.
                if p.edistys > paras_edistys:
                    paras_edistys, paras_paikka = p.edistys, self.paikka
                    self.siirry(paras_paikka + suunta * askel)
                else:
                    suunta = -suunta
                    askel *= 0.55
                    if askel < self.s.saato_min:
                        # Huippu on loydetty eika lukko auennut siella.
                        # Aukko on muualla: jatketaan hakua.
                        vaihe = self.HAKU
                        paras_edistys, askel = 0.0, self.s.saato_askel
                        seuraava = paras_paikka + self.s.haku_askel
                        self.siirry(0.0 if seuraava > 0.995 else seuraava)
                    else:
                        self.siirry(paras_paikka + suunta * askel)

        self.kasi.f_ylos()
        self.jatka_paikasta = self.paikka if self.s.jatka_hakua else 0.0
        return False, painallukset


# ==========================================================================
#  LOKI
# ==========================================================================

class Loki:
    """Joka painallus talteen. Onnistuneessa yrityksessa viimeinen paikka
    on aukko, joten koko yritys saa etaisyysleiman jalkikateen - juuri se
    data jolla vastemalli sovitetaan."""

    KENTAT = ["yritys", "n", "vaihe", "paikka", "kaanto_ennen", "kaanto_jalkeen",
              "edistys", "kesto_ms", "auki", "onnistui", "aukko", "etaisyys"]

    def __init__(self, s: Saadot, nimi: str = "ajo"):
        self.s = s
        self.polku = LOKI / f"{nimi}_{time.strftime('%Y%m%d_%H%M%S')}.csv"
        self.rivit: List[dict] = []
        self.yritys = 0

    def uusi_yritys(self) -> None:
        self.yritys += 1
        self.alku_i = len(self.rivit)

    def lisaa(self, p: Painallus, vaihe: str) -> None:
        self.rivit.append({
            "yritys": self.yritys, "n": len(self.rivit) - self.alku_i + 1, "vaihe": vaihe,
            "paikka": round(p.paikka, 4), "kaanto_ennen": round(p.kaanto_ennen, 4),
            "kaanto_jalkeen": round(p.kaanto_jalkeen, 4), "edistys": round(p.edistys, 4),
            "kesto_ms": round(p.kesto_ms, 1), "auki": int(p.auki),
            "onnistui": "", "aukko": "", "etaisyys": "",
        })

    def paata_yritys(self, onnistui: bool) -> None:
        osa = self.rivit[self.alku_i:]
        if not osa:
            return
        aukko = osa[-1]["paikka"] if onnistui else None
        for r in osa:
            r["onnistui"] = int(onnistui)
            if aukko is not None:
                r["aukko"] = aukko
                r["etaisyys"] = round(abs(r["paikka"] - aukko), 4)

    def tallenna(self) -> Optional[Path]:
        if not self.s.lokita or not self.rivit:
            return None
        with self.polku.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=self.KENTAT)
            w.writeheader()
            w.writerows(self.rivit)
        return self.polku


def kerää_opetusdata() -> Tuple[List[float], List[float], int, int]:
    """Kaikista lokeista ne painallukset joissa aukon paikka on tiedossa."""
    et, mu = [], []
    yrityksia, onnistui = set(), set()
    for polku in sorted(LOKI.glob("*.csv")):
        try:
            with polku.open(newline="", encoding="utf-8") as f:
                for r in csv.DictReader(f):
                    avain = (polku.name, r.get("yritys"))
                    yrityksia.add(avain)
                    if r.get("onnistui") == "1":
                        onnistui.add(avain)
                    if r.get("etaisyys") not in (None, "",):
                        et.append(float(r["etaisyys"]))
                        mu.append(float(r["edistys"]))
        except Exception:
            continue
    return et, mu, len(yrityksia), len(onnistui)


# ==========================================================================
#  TILAT
# ==========================================================================

def tulosta_painallukset(painallukset: List[Painallus]) -> str:
    """Nayttaa yrityksen muodossa jonka voi lukea yhdella silmayksella."""
    palat = []
    for p in painallukset:
        if p.kesto_ms < 120:
            palat.append("tap")
        elif p.kesto_ms < 300:
            palat.append("taap")
        elif p.kesto_ms < 600:
            palat.append("taaap")
        else:
            palat.append("taaaaap")
    return ", ".join(palat)


def aja(s: Saadot, yrityksia: Optional[int] = None) -> None:
    if not WINDOWS:
        print("Ajaminen vaatii Windowsin (SendInput). Kokeile --testaa.")
        return
    silma = Silma(s)
    kasi = Kasi(s)
    i = silma.avaa()
    print(f"naytto {i}, alue {silma.alue['width']}x{silma.alue['height']}")
    print("F12 = seis, F10 = tauko\n")
    avaaja = Avaaja(s, silma, kasi)
    loki = Loki(s, "ajo")
    vaste = Vaste()
    if vaste.luotettava():
        print(f"vastemalli: A={vaste.A:.2f} L={vaste.L:.2f} ({vaste.n} painallusta, "
              f"selitysaste {vaste.selitysaste:.2f})")
    else:
        print(f"vastemalli ei viela luotettava ({vaste.n} painallusta, selitysaste "
              f"{vaste.selitysaste:.2f}) - ajetaan pelkalla raikalla, mika ei sita tarvitse")

    n = 0
    onnistui = 0
    try:
        while yrityksia is None or n < yrityksia:
            if kasi.pohjassa(s.seis_nappain):
                break
            n += 1
            loki.uusi_yritys()
            if s.paina_space:
                kasi.nappaise(s.space_nappain, 28)
                time.sleep(0.2)
            ok, painallukset = avaaja.yritys(lokitin=loki.lisaa)
            loki.paata_yritys(ok)
            onnistui += ok
            kesto = sum(p.kesto_ms for p in painallukset)
            print(f"{n:4d} {'AUKI ' if ok else 'ei   '} {len(painallukset):2d} painallusta, "
                  f"F pohjassa {kesto/1000:.2f}s  |  {tulosta_painallukset(painallukset)}")
            if not ok:
                time.sleep(s.valissa_s)
    except KeyboardInterrupt:
        pass
    finally:
        kasi.f_ylos()
        polku = loki.tallenna()
        print(f"\n{onnistui}/{n} auki ({100*onnistui/max(1,n):.0f}%)")
        if polku:
            print(f"loki: {polku.name}   aja 'python lukko.py --sovita' kun yrityksia on kertynyt")


def mittaa(s: Saadot, yrityksia: int = 20) -> None:
    """Mittausajo: kiintea ruudukko, ei paatoksentekoa, kaikki talteen.

    Tama on se ajo joka kertoo mika vastemalli oikeasti on. Se ei yrita
    avata lukkoja tehokkaasti - se kayttaa jokaisen yrityksen tasavaliseen
    naytteenottoon jotta etaisyys-edistys -parit kattavat koko lukon.
    """
    if not WINDOWS:
        print("Mittaus vaatii Windowsin.")
        return
    silma = Silma(s)
    kasi = Kasi(s)
    silma.avaa()
    avaaja = Avaaja(s, silma, kasi)
    loki = Loki(s, "mittaus")
    ruudut = [i / 11.0 for i in range(1, 11)]
    print(f"mittausajo: {yrityksia} yritysta x {len(ruudut)} kiinteaa kohtaa")
    print("F12 = seis\n")
    onnistui = 0
    try:
        for y in range(1, yrityksia + 1):
            if kasi.pohjassa(s.seis_nappain):
                break
            loki.uusi_yritys()
            if s.paina_space:
                kasi.nappaise(s.space_nappain, 28)
                time.sleep(0.2)
            avaaja.kotiin()
            ok = False
            alku = time.monotonic()
            for r in ruudut:
                if time.monotonic() - alku > s.budjetti_s or kasi.pohjassa(s.seis_nappain):
                    break
                avaaja.siirry(r)
                p = avaaja.paina()
                loki.lisaa(p, "mittaus")
                if p.auki:
                    ok = True
                    break
            loki.paata_yritys(ok)
            onnistui += ok
            print(f"{y:4d} {'AUKI' if ok else 'ei  '}")
            time.sleep(s.valissa_s)
    except KeyboardInterrupt:
        pass
    finally:
        kasi.f_ylos()
        polku = loki.tallenna()
        print(f"\n{onnistui}/{yrityksia} auki. loki: {polku.name if polku else '-'}")
        print("aja nyt: python lukko.py --sovita")


def sovita(_s: Saadot) -> None:
    et, mu, yrityksia, onnistuneet = kerää_opetusdata()
    print(f"lokeissa {yrityksia} yritysta, joista {onnistuneet} onnistui")
    print(f"kayttokelpoisia (etaisyys tiedossa) painalluksia: {len(et)}")
    if len(et) < 10:
        print("liian vahan. Aja 'python lukko.py --mittaa' ja avaa lukkoja.")
        return
    v = Vaste()
    v.sovita(et, mu)
    v.tallenna()
    print(f"\nvastemalli  edistys = {v.A:.3f} * exp(-d / {v.L:.3f})")
    print(f"  n={v.n}  selitysaste={v.selitysaste:.2f}")
    for d in (0.0, 0.05, 0.1, 0.2, 0.35, 0.5, 0.8):
        print(f"    d={d:.2f} -> {v(d):.3f}")
    if v.luotettava():
        print("\nMalli on nyt luotettava (n>=150 ja selitysaste>=0.55).")
    else:
        print("\nEi viela luotettava: tarvitaan n>=150 ja selitysaste>=0.55.")
        print("Raikka toimii ilman sita, mutta paikan laskeminen ei ala ennen tata.")


def testaa(s: Saadot) -> int:
    """Nakotesti referenssikuvia vasten, ilman pelia ja ilman Windowsia."""
    from PIL import Image
    kansio = JUURI / "kuvat"
    kuvat = sorted(kansio.glob("*.jpg"))
    if not kuvat:
        print("kuvat/ on tyhja")
        return 1
    silma = Silma(s)
    virheet = 0
    print(f"{'kuva':18s} {'kulma':>7s} {'kaanto':>7s} {'kaari':>7s} {'palkki':>7s}  {'tulos':10s} odotus")
    for polku in kuvat:
        rgb = np.asarray(Image.open(polku).convert("RGB"))
        bgr = rgb[:, :, ::-1].copy()
        korkeus, leveys = bgr.shape[:2]
        p = int(s.rajaus_sade * korkeus)
        rajattu = bgr[korkeus // 2 - p:korkeus // 2 + p, leveys // 2 - p:leveys // 2 + p]
        silma.korkeus = korkeus
        silma._koko = None
        silma.nollaa_kulma()
        h = silma._lue_kuva(rajattu)
        nimi = polku.name
        if nimi.startswith("success"):
            odotus, tulos = "auki", ("auki" if h.auki else "EI")
        elif nimi.startswith("levossa"):
            odotus = "levossa"
            tulos = "levossa" if (h.ok and h.kaanto <= s.kohina_max) else "EI"
        else:
            odotus = "kaantynyt"
            tulos = "kaantynyt" if (h.ok and h.kaanto > 0.30) else "EI"
        ok = tulos == odotus
        virheet += not ok
        print(f"{nimi:18s} {h.kulma:7.1f} {h.kaanto:7.3f} {h.kaari:7d} {h.palkki:7d}  "
              f"{tulos:10s} {odotus:10s} {'OK' if ok else 'VIRHE'}")

    # nopeus, kuten ajossa: maskit rakennetaan kerran
    rgb = np.asarray(Image.open(kuvat[0]).convert("RGB"))
    bgr = rgb[:, :, ::-1].copy()
    korkeus, leveys = bgr.shape[:2]
    p = int(s.rajaus_sade * korkeus)
    rajattu = bgr[korkeus // 2 - p:korkeus // 2 + p, leveys // 2 - p:leveys // 2 + p]
    silma.korkeus = korkeus
    silma._lue_kuva(rajattu)
    t0 = time.perf_counter()
    for _ in range(50):
        silma._lue_kuva(rajattu)
    ms = (time.perf_counter() - t0) / 50 * 1000.0
    print(f"\nyksi lukema {ms:.1f} ms  ->  noin {1000/ms:.0f} lukemaa sekunnissa")
    if ms > 15.0:
        print("VIRHE: lukema on liian hidas, budjetti menee nakemiseen")
        virheet += 1

    print(f"\n{'KAIKKI OK' if not virheet else str(virheet) + ' VIRHETTA'}")
    return 1 if virheet else 0


def main() -> int:
    ap = argparse.ArgumentParser(description="SCUM-lukonavaaja")
    ap.add_argument("--mittaa", action="store_true", help="mittausajo, kiintea ruudukko")
    ap.add_argument("--sovita", action="store_true", help="sovita vastemalli lokeista")
    ap.add_argument("--testaa", action="store_true", help="nakotesti referenssikuvista")
    ap.add_argument("--yrityksia", type=int, default=None)
    a = ap.parse_args()
    s = Saadot.lataa()
    if a.testaa:
        return testaa(s)
    if a.sovita:
        sovita(s)
        return 0
    if a.mittaa:
        mittaa(s, a.yrityksia or 20)
        return 0
    aja(s, a.yrityksia)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
