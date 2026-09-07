# -*- coding: utf-8 -*-
"""SCUM lukonavaaja.

Katsoo lukkopesaa (pinkki alue referenssikuvassa: keskus 959,536 sade 128.5
kun 1080p) ja paattaa joka napautyksen jalkeen yhden asian:

    TARAHTI   pesa nykaisi ja palasi   -> vaara kohta, eteenpain
    ANTOI     pesa jai kaantyneeksi    -> oikea kohta, feather auki

Feathering: kevyita toistuvia napautyksia. Ei koskaan pitkaa pitoa - se
rikkoo tiirikan.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
import threading
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Optional, Tuple

import numpy as np

JUURI = Path(__file__).resolve().parent
SAADOT_TIEDOSTO = JUURI / "saadot.json"


# --------------------------------------------------------------------------
#  SAADOT
# --------------------------------------------------------------------------

@dataclass
class Saadot:
    # katsottava alue: pinkki pallo referenssikuvassa
    keskus_y: float = -0.0037        # x ruudun korkeus, ruudun keskelta
    alue_sade: float = 0.1190        # 128.5 / 1080
    reika_sade: float = 0.0519       # musta avaimenreika pesan sisalla
    tumma_max: int = 22
    min_pikselit: int = 200
    min_pitkulaisuus: float = 1.8

    # onko yritys kaynnissa / auki
    kaari_kirkas: int = 185
    kaari_min: int = 1500
    palkki_kirkas: int = 200
    palkki_min: int = 2500

    # napautys
    tap_ms: int = 35                 # kevyt napautys
    huippu_ms: int = 110             # katto: nain kauan huippua odotetaan
    palautus_ms: int = 110           # katto: nain kauan palautusta odotetaan
    vakaa_ms: int = 25               # kun lukema ei enaa muutu tassa, jatketaan

    # paatos
    tarahdys_min: float = 0.03       # tama nakyi, mutta palasi
    antoi_min: float = 0.04          # tama JAI -> oikea kohta

    # liike
    jana: float = 6000.0             # hiiriyksikkoa lukon laidasta laitaan
    pala: int = 900
    haku_askel: float = 0.07
    nykaisy: float = 0.035           # feather-saato kun edistys tyrehtyy
    nykaisy_min: float = 0.008

    # yritys
    budjetti_s: float = 3.4
    valissa_s: float = 0.55
    paina_space: bool = True

    f_nappain: int = 0x46
    space_nappain: int = 0x20
    seis_nappain: int = 0x7B         # F12
    tauko_nappain: int = 0x79        # F10

    @staticmethod
    def lataa() -> "Saadot":
        if SAADOT_TIEDOSTO.exists():
            raw = json.loads(SAADOT_TIEDOSTO.read_text(encoding="utf-8"))
            kelpaa = set(Saadot.__dataclass_fields__)
            s = Saadot(**{k: v for k, v in raw.items() if k in kelpaa})
        else:
            s = Saadot()
        SAADOT_TIEDOSTO.write_text(json.dumps(asdict(s), indent=2), encoding="utf-8")
        return s


# --------------------------------------------------------------------------
#  SILMA
# --------------------------------------------------------------------------

@dataclass
class Kuva:
    ok: bool = False
    kaanto: float = 0.0        # 0 = levossa, 1 = auki asti
    kulma: float = 0.0
    kaynnissa: bool = False
    auki: bool = False


class Silma:
    def __init__(self, s: Saadot):
        self.s = s
        self.koko = None
        self.edellinen = 0.0

    def avaa(self):
        import mss
        self.sct = mss.mss()
        m = self.sct.monitors
        i = self._etsi(m)
        n = m[i]
        p = int(0.30 * n["height"])
        cx = n["left"] + n["width"] // 2
        cy = n["top"] + n["height"] // 2 + int(self.s.keskus_y * n["height"])
        self.alue = {"left": cx - p, "top": cy - p, "width": 2 * p, "height": 2 * p}
        self.korkeus = n["height"]
        return i

    def _etsi(self, naytot) -> int:
        paras, eniten = 1, -1
        for i in range(1, len(naytot)):
            n = naytot[i]
            p = int(0.30 * n["height"])
            cx, cy = n["left"] + n["width"] // 2, n["top"] + n["height"] // 2
            self.korkeus = n["height"]
            kuva = np.asarray(self.sct.grab(
                {"left": cx - p, "top": cy - p, "width": 2 * p, "height": 2 * p}))[:, :, :3]
            k = self._kaari(kuva)
            if k > eniten:
                paras, eniten = i, k
        return paras

    def _maskit(self, korkeus, leveys):
        if self.koko != (korkeus, leveys):
            y = np.arange(korkeus, dtype=np.float32) - korkeus / 2.0
            x = np.arange(leveys, dtype=np.float32) - leveys / 2.0
            yy, xx = np.meshgrid(y, x, indexing="ij")
            et = np.sqrt(xx * xx + yy * yy)
            r = self.s.alue_sade * self.korkeus
            self.xx, self.yy = xx, yy
            self.reika_maski = et < self.s.reika_sade * self.korkeus
            self.kaari_maski = (et > r * 1.10) & (et < r * 1.85)
            ph = max(8, int(self.korkeus * 0.051))
            pw = max(8, int(self.korkeus * 0.204))
            self.palkki = (slice(korkeus // 2 - ph, korkeus // 2 + ph),
                           slice(leveys // 2 - pw, leveys // 2 + pw))
            self.koko = (korkeus, leveys)

    @staticmethod
    def _kirkkaus(bgr):
        return (0.114 * bgr[:, :, 0].astype(np.float32)
                + 0.587 * bgr[:, :, 1].astype(np.float32)
                + 0.299 * bgr[:, :, 2].astype(np.float32))

    def _kaari(self, bgr) -> int:
        k = self._kirkkaus(bgr)
        self._maskit(*k.shape)
        return int(((k > self.s.kaari_kirkas) & self.kaari_maski).sum())

    def lue(self) -> Kuva:
        return self.tulkitse(np.asarray(self.sct.grab(self.alue))[:, :, :3])

    def tulkitse(self, bgr) -> Kuva:
        k = self._kirkkaus(bgr)
        self._maskit(*k.shape)
        kaari = int(((k > self.s.kaari_kirkas) & self.kaari_maski).sum())
        palkki = int((k[self.palkki] > self.s.palkki_kirkas).sum())
        auki = palkki >= self.s.palkki_min and kaari <= self.s.kaari_min // 2

        reika = (k < self.s.tumma_max) & self.reika_maski
        if int(reika.sum()) < self.s.min_pikselit:
            return Kuva(False, 0.0, 0.0, kaari >= self.s.kaari_min, auki)
        kulma = self._suunta(self.xx[reika], self.yy[reika])
        if kulma is None:
            return Kuva(False, 0.0, 0.0, kaari >= self.s.kaari_min, auki)
        return Kuva(True, float(np.clip(kulma / 90.0, 0.0, 1.0)), kulma,
                    kaari >= self.s.kaari_min, auki)

    def _suunta(self, x, y) -> Optional[float]:
        x = x.astype(np.float64); y = y.astype(np.float64)
        x -= x.mean(); y -= y.mean()
        xx = float((x * x).mean()); yy = float((y * y).mean()); xy = float((x * y).mean())
        juuri = math.sqrt(max(0.0, (xx - yy) ** 2 + 4 * xy * xy))
        pieni, iso = (xx + yy - juuri) / 2, (xx + yy + juuri) / 2
        if pieni <= 1e-9 or math.sqrt(iso / pieni) < self.s.min_pitkulaisuus:
            return None
        a = math.degrees(0.5 * math.atan2(2 * xy, xx - yy)) + 90.0
        while a - self.edellinen > 90: a -= 180
        while self.edellinen - a > 90: a += 180
        while a < -25: a += 180
        while a > 125: a -= 180
        self.edellinen = a
        return a

    def nollaa(self):
        self.edellinen = 0.0


# --------------------------------------------------------------------------
#  KASI
# --------------------------------------------------------------------------

WIN = os.name == "nt"
if WIN:
    u32 = ctypes.windll.user32
    MOVE, KEYUP, SCAN = 0x0001, 0x0002, 0x0008

    class _M(ctypes.Structure):
        _fields_ = [("dx", ctypes.c_long), ("dy", ctypes.c_long), ("d", ctypes.c_ulong),
                    ("f", ctypes.c_ulong), ("t", ctypes.c_ulong),
                    ("e", ctypes.POINTER(ctypes.c_ulong))]

    class _K(ctypes.Structure):
        _fields_ = [("vk", ctypes.c_ushort), ("sc", ctypes.c_ushort), ("f", ctypes.c_ulong),
                    ("t", ctypes.c_ulong), ("e", ctypes.POINTER(ctypes.c_ulong))]

    class _U(ctypes.Union):
        _fields_ = [("m", _M), ("k", _K)]

    class _I(ctypes.Structure):
        _fields_ = [("tyyppi", ctypes.c_ulong), ("u", _U)]


class Kasi:
    def __init__(self, s: Saadot):
        self.s = s
        if WIN:
            for f in (lambda: ctypes.windll.shcore.SetProcessDpiAwareness(2),
                      u32.SetProcessDPIAware, lambda: ctypes.windll.winmm.timeBeginPeriod(1)):
                try:
                    f()
                except Exception:
                    pass

    def _laheta(self, i):
        if WIN:
            u32.SendInput(1, ctypes.byref(i), ctypes.sizeof(i))

    def siirra(self, yksikkoa: float):
        if not WIN:
            return
        jaljella, merkki = int(round(abs(yksikkoa))), (1 if yksikkoa > 0 else -1)
        e = ctypes.c_ulong(0)
        while jaljella > 0:
            askel = min(self.s.pala, jaljella)
            self._laheta(_I(0, _U(m=_M(merkki * askel, 0, 0, MOVE, 0, ctypes.pointer(e)))))
            jaljella -= askel
            if jaljella:
                time.sleep(0.003)

    def _nappi(self, vk, alas):
        if not WIN:
            return
        e = ctypes.c_ulong(0)
        self._laheta(_I(1, _U(k=_K(0, u32.MapVirtualKeyW(vk, 0),
                                   SCAN | (0 if alas else KEYUP), 0, ctypes.pointer(e)))))

    def napauta(self, vk, ms):
        self._nappi(vk, True)
        time.sleep(ms / 1000.0)
        self._nappi(vk, False)

    def pohjassa(self, vk) -> bool:
        return bool(WIN and (u32.GetAsyncKeyState(vk) & 0x8000))


# --------------------------------------------------------------------------
#  SEIS - F12 pysayttaa heti, kesken napautyksen tai kesken unen
# --------------------------------------------------------------------------

class Seis:
    """Oma saie joka kysyy F12:ta 8 ms valein.

    Paasilmukka ehtii tarkistaa napin vain napautysten valissa, ja yksi
    napautys lukuikkunoineen kestaa jopa 300 ms. Tama irrottaa F:n ja
    lopettaa prosessin siina hetkessa kun nappia painetaan.
    """

    def __init__(self, s: Saadot, kasi: "Kasi"):
        self.s, self.kasi = s, kasi
        self.paalla = False
        self.saie = threading.Thread(target=self._vahdi, daemon=True)
        self.saie.start()

    def _vahdi(self):
        while True:
            if self.kasi.pohjassa(self.s.seis_nappain):
                self.paalla = True
                try:
                    self.kasi._nappi(self.s.f_nappain, False)   # ote irti
                except Exception:
                    pass
                print("\nF12 - seis")
                os._exit(0)
            time.sleep(0.008)


# --------------------------------------------------------------------------
#  AVAAJA
# --------------------------------------------------------------------------

TARAHTI, ANTOI, EI_MITAAN = "tarahti", "ANTOI", "-"


class Avaaja:
    def __init__(self, s: Saadot, silma: Silma, kasi: Kasi, naytto=None):
        self.s, self.silma, self.kasi, self.naytto = s, silma, kasi, naytto
        self.paikka = 0.0

    def kotiin(self):
        self.kasi.siirra(-self.s.jana * 1.4)
        time.sleep(0.05)
        self.paikka = 0.0
        self.silma.nollaa()

    def siirry(self, p: float):
        p = float(np.clip(p, 0.0, 1.0))
        if abs(p - self.paikka) < 1e-4:
            return
        self.kasi.siirra((p - self.paikka) * self.s.jana)
        self.paikka = p
        time.sleep(0.018)

    def napauta(self) -> Tuple[str, float, float, bool]:
        """Yksi kevyt napautys. Palauttaa (tulos, huippu, jai, auki).

        huippu = kuinka paljon pesa nykaisi napautyksen aikana
        jai    = kuinka paljon siita jai jaljelle kun se ehti palata
        """
        ennen = self.silma.lue()
        pohja = ennen.kaanto if ennen.ok else 0.0
        auki = ennen.auki

        self.kasi.napauta(self.s.f_nappain, self.s.tap_ms)

        # Odotetaan huippua vain niin kauan kuin lukema viela nousee, ja
        # palautusta vain niin kauan kuin se viela laskee. Nain nopea peli
        # menee nopeasti eika hitaampi hajoa.
        huippu = pohja
        loppu = time.monotonic() + self.s.huippu_ms / 1000.0
        vika_muutos = time.monotonic()
        while time.monotonic() < loppu:
            k = self.silma.lue()
            if k.auki:
                auki = True
                break
            if k.ok and k.kaanto > huippu + 0.004:
                huippu = k.kaanto
                vika_muutos = time.monotonic()
            elif (time.monotonic() - vika_muutos) * 1000 >= self.s.vakaa_ms:
                break

        jalkeen = pohja
        loppu = time.monotonic() + self.s.palautus_ms / 1000.0
        vika_muutos = time.monotonic()
        while time.monotonic() < loppu:
            k = self.silma.lue()
            if k.auki:
                auki = True
                break
            if k.ok:
                if k.kaanto < jalkeen - 0.004 or jalkeen == pohja:
                    jalkeen = k.kaanto
                    vika_muutos = time.monotonic()
                elif (time.monotonic() - vika_muutos) * 1000 >= self.s.vakaa_ms:
                    break
        jai = jalkeen - pohja

        if jai >= self.s.antoi_min:
            tulos = ANTOI
        elif huippu - pohja >= self.s.tarahdys_min:
            tulos = TARAHTI
        else:
            tulos = EI_MITAAN
        if self.naytto:
            self.naytto.merkitse(self.paikka, jalkeen, tulos)
        return tulos, huippu - pohja, jai, auki

    def yritys(self) -> Tuple[bool, int]:
        self.kotiin()
        alku = time.monotonic()
        n = 0
        lukittu = False          # loytyiko kohta joka antaa periksi
        suunta, nykaisy = 1, self.s.nykaisy
        tyhjia = 0

        while time.monotonic() - alku < self.s.budjetti_s:
            if self.kasi.pohjassa(self.s.seis_nappain):
                return False, n
            while self.kasi.pohjassa(self.s.tauko_nappain):
                time.sleep(0.05)

            tulos, _huippu, _jai, auki = self.napauta()
            n += 1
            if auki:
                return True, n

            if tulos == ANTOI:
                # Oikea kohta. Jaadaan tahan ja featheroidaan.
                lukittu = True
                tyhjia = 0
                nykaisy = self.s.nykaisy
                continue

            if lukittu:
                # Antoi aiemmin, nyt ei. Varmistetaan suunta ja kohta ettei
                # olla rampin reunalla: pieni nykaisy, ja jos sekaan ei tuota,
                # toiseen suuntaan ja puolet lyhyempi.
                tyhjia += 1
                self.siirry(self.paikka + suunta * nykaisy)
                if tyhjia >= 2:
                    suunta = -suunta
                    nykaisy = max(self.s.nykaisy_min, nykaisy * 0.5)
                    tyhjia = 0
                    if nykaisy <= self.s.nykaisy_min:
                        lukittu = False
                        nykaisy = self.s.nykaisy
                continue

            # Ei viela mitaan: eteenpain.
            seuraava = self.paikka + self.s.haku_askel
            self.siirry(0.0 if seuraava > 0.995 else seuraava)

        return False, n


# --------------------------------------------------------------------------
#  NAYTTO - sama kuva kuin simulaatiossa, mutta oikeasta pelista
# --------------------------------------------------------------------------

class Naytto:
    VARI = {ANTOI: "#3ddc84", TARAHTI: "#e8b93a", EI_MITAAN: "#5a5f66"}

    def __init__(self):
        import tkinter as tk
        self.tk = tk
        self.ikkuna = tk.Tk()
        self.ikkuna.title("lukko")
        self.ikkuna.attributes("-topmost", True)
        self.ikkuna.configure(bg="#15181c")
        self.c = tk.Canvas(self.ikkuna, width=420, height=250, bg="#15181c", highlightthickness=0)
        self.c.pack()
        self.merkit = []
        self.kaanto = 0.0
        self.paikka = 0.0
        self.teksti = ""

    def merkitse(self, paikka, kaanto, tulos):
        self.merkit.append((paikka, tulos))
        self.merkit = self.merkit[-60:]
        self.kaanto, self.paikka = kaanto, paikka

    def uusi_yritys(self):
        self.merkit = []

    def piirra(self, teksti=""):
        try:
            self._piirra(teksti)
        except Exception:
            pass

    def _piirra(self, teksti=""):
        c = self.c
        c.delete("all")
        # pesa
        cx, cy, r = 105, 115, 75
        c.create_oval(cx - r, cy - r, cx + r, cy + r, outline="#2c3138", width=2)
        c.create_arc(cx - r, cy - r, cx + r, cy + r, start=90, extent=-90,
                     outline="#2c3138", style="arc", width=6)
        c.create_arc(cx - r, cy - r, cx + r, cy + r, start=90, extent=-90 * self.kaanto,
                     outline="#3ddc84", style="arc", width=6)
        a = math.radians(90 - 90 * self.kaanto)
        c.create_line(cx, cy, cx + r * 0.8 * math.cos(a), cy - r * 0.8 * math.sin(a),
                      fill="#e6edf3", width=4)
        c.create_text(cx, cy + r + 22, text=f"{self.kaanto*90:.0f} astetta",
                      fill="#8b949e", font=("Consolas", 11))
        # jana ja napautykset
        x0, x1, y = 215, 400, 60
        c.create_line(x0, y, x1, y, fill="#2c3138", width=3)
        for p, t in self.merkit:
            x = x0 + (x1 - x0) * p
            c.create_oval(x - 4, y - 4, x + 4, y + 4, fill=self.VARI[t], outline="")
        x = x0 + (x1 - x0) * self.paikka
        c.create_polygon(x, y - 12, x - 5, y - 22, x + 5, y - 22, fill="#e6edf3")
        for nimi, vari, dy in ((ANTOI, self.VARI[ANTOI], 0), ("tarahti", self.VARI[TARAHTI], 20),
                               ("ei mitaan", self.VARI[EI_MITAAN], 40)):
            c.create_oval(x0, 100 + dy, x0 + 8, 108 + dy, fill=vari, outline="")
            c.create_text(x0 + 16, 104 + dy, text=nimi, anchor="w",
                          fill="#8b949e", font=("Consolas", 10))
        c.create_text(215, 215, text=teksti or self.teksti, anchor="w",
                      fill="#e6edf3", font=("Consolas", 11))
        self.ikkuna.update()

    def sulje(self):
        try:
            self.ikkuna.destroy()
        except Exception:
            pass


# --------------------------------------------------------------------------
#  AJO
# --------------------------------------------------------------------------

def aja(s: Saadot, naytolla: bool):
    if not WIN:
        print("Ajaminen vaatii Windowsin. Kokeile --testaa.")
        return
    silma, kasi = Silma(s), Kasi(s)
    Seis(s, kasi)
    print(f"naytto {silma.avaa()}   F12 = seis, F10 = tauko\n")
    naytto = None
    if naytolla:
        try:
            naytto = Naytto()
        except Exception as e:
            print(f"(nayttoa ei saatu auki: {e})")
    avaaja = Avaaja(s, silma, kasi, naytto)

    n = auki = 0
    try:
        while not kasi.pohjassa(s.seis_nappain):
            n += 1
            if naytto:
                naytto.uusi_yritys()
            if s.paina_space:
                kasi.napauta(s.space_nappain, 28)
                time.sleep(0.2)
            ok, napautyksia = avaaja.yritys()
            auki += ok
            rivi = f"{n:4d} {'AUKI' if ok else 'ei  '}  {napautyksia:2d} napautysta   {auki}/{n}"
            print(rivi)
            if naytto:
                naytto.piirra(rivi)
            if not ok:
                time.sleep(s.valissa_s)
    except KeyboardInterrupt:
        pass
    finally:
        if naytto:
            naytto.sulje()
        print(f"\n{auki}/{n}")


def testaa(s: Saadot) -> int:
    from PIL import Image
    silma = Silma(s)
    virheet = 0
    for polku in sorted((JUURI / "kuvat").glob("*.jpg")):
        rgb = np.asarray(Image.open(polku).convert("RGB"))
        bgr = rgb[:, :, ::-1].copy()
        h, w = bgr.shape[:2]
        p = int(0.30 * h)
        cy = h // 2 + int(s.keskus_y * h)
        silma.korkeus = h
        silma.koko = None
        silma.nollaa()
        k = silma.tulkitse(bgr[cy - p:cy + p, w // 2 - p:w // 2 + p])
        nimi = polku.name
        if nimi.startswith("success"):
            odotus, saatu = "auki", ("auki" if k.auki else "EI")
        elif nimi.startswith("levossa"):
            odotus = "levossa"
            saatu = "levossa" if (k.ok and k.kaanto < 0.03) else "EI"
        else:
            odotus = "kaantynyt"
            saatu = "kaantynyt" if (k.ok and k.kaanto > 0.30) else "EI"
        ok = saatu == odotus
        virheet += not ok
        print(f"{nimi:18s} {k.kulma:6.1f} astetta  kaanto {k.kaanto:.3f}  "
              f"{saatu:10s} {'OK' if ok else 'VIRHE, odotettiin ' + odotus}")
    t0 = time.perf_counter()
    for _ in range(50):
        silma.tulkitse(bgr[cy - p:cy + p, w // 2 - p:w // 2 + p])
    ms = (time.perf_counter() - t0) / 50 * 1000
    print(f"\nlukema {ms:.1f} ms")
    print("KAIKKI OK" if not virheet else f"{virheet} VIRHETTA")
    return 1 if virheet else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--testaa", action="store_true")
    ap.add_argument("--ei-nayttoa", action="store_true")
    a = ap.parse_args()
    s = Saadot.lataa()
    if a.testaa:
        return testaa(s)
    aja(s, not a.ei_nayttoa)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
