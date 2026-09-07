# -*- coding: utf-8 -*-
"""Opetettu verkko pelaa oikeaa lukkoa.

Havainto rakennetaan samalla peli.Kartta-luokalla kuin opetuksessa, joten
verkko nakee pelin tasmalleen samassa muodossa kuin simulaatiossa.

    python pelaa.py
    python pelaa.py --naytteista     antaa verkon arpoa (ei aina ahne)
"""
from __future__ import annotations

import argparse
import ctypes
import os
import threading
import time
from pathlib import Path

import numpy as np

import peli
import silma as S
import verkko as V

JUURI = Path(__file__).resolve().parent
POLITIIKKA = JUURI / "politiikka.npz"

JANA = 6000.0          # hiiriyksikkoa lukon laidasta laitaan
PALA = 900
TAP_MS = 35
VIIVE_MS = 350         # aloitusarvo; mitataan ajon aikana
VIIVE_MIN = 60
HUIPPU_MS = 130
PALAUTUS_MS = 130
VAKAA_MS = 40
BUDJETTI_S = 3.4
VALISSA_S = 0.55
F, SPACE, SEIS = 0x46, 0x20, 0x7B

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
    def __init__(self):
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
            askel = min(PALA, jaljella)
            self._laheta(_I(0, _U(m=_M(merkki * askel, 0, 0, MOVE, 0, ctypes.pointer(e)))))
            jaljella -= askel
            if jaljella:
                time.sleep(0.003)

    def nappi(self, vk, alas):
        if not WIN:
            return
        e = ctypes.c_ulong(0)
        self._laheta(_I(1, _U(k=_K(0, u32.MapVirtualKeyW(vk, 0),
                                   SCAN | (0 if alas else KEYUP), 0, ctypes.pointer(e)))))

    def napauta(self, vk, ms):
        self.nappi(vk, True)
        time.sleep(ms / 1000.0)
        self.nappi(vk, False)

    def pohjassa(self, vk) -> bool:
        return bool(WIN and (u32.GetAsyncKeyState(vk) & 0x8000))


def vahti(kasi: Kasi):
    """F12 lopettaa heti, kesken napautyksenkin."""
    def silmukka():
        while True:
            if kasi.pohjassa(SEIS):
                try:
                    kasi.nappi(F, False)
                except Exception:
                    pass
                print("\nF12 - seis")
                os._exit(0)
            time.sleep(0.008)
    threading.Thread(target=silmukka, daemon=True).start()


class Pelaaja:
    def __init__(self, v: V.Verkko, silma: S.Silma, kasi: Kasi, ahne: bool = True):
        self.v, self.silma, self.kasi, self.ahne = v, silma, kasi, ahne
        self.rng = np.random.default_rng(0)
        self.viive = float(VIIVE_MS)
        self.kuolleita = 0
        self.paikka = 0.0

    def kotiin(self):
        self.kasi.siirra(-JANA * 1.4)
        time.sleep(0.05)
        self.paikka = 0.0
        self.silma.nollaa()

    def siirry(self, uusi: float):
        uusi = float(np.clip(uusi, 0.0, 1.0))
        if abs(uusi - self.paikka) > 1e-4:
            self.kasi.siirra((uusi - self.paikka) * JANA)
            time.sleep(0.018)
        self.paikka = uusi

    def napauta(self):
        """Yksi kevyt napautys. Palauttaa (nykaisy, jai, kaanto, auki)."""
        ennen = self.silma.lue()
        pohja = ennen.kaanto if ennen.ok else 0.0
        auki = ennen.auki
        self.kasi.napauta(F, TAP_MS)

        huippu = pohja
        alku = time.monotonic()
        loppu = alku + (self.viive + HUIPPU_MS) / 1000.0
        vika_nousu = alku
        ensi = None
        while time.monotonic() < loppu:
            k = self.silma.lue()
            if k.auki:
                auki = True
                break
            if k.ok and k.kaanto > huippu + 0.004:
                huippu = k.kaanto
                vika_nousu = time.monotonic()
                if ensi is None:
                    ensi = (vika_nousu - alku) * 1000.0
            nyt = time.monotonic()
            if (nyt - alku) * 1000.0 >= self.viive and (nyt - vika_nousu) * 1000.0 >= VAKAA_MS:
                break

        # opitaan pelin oma vaste-viive, ei arvata sita
        if ensi is not None:
            self.viive = 0.7 * self.viive + 0.3 * max(VIIVE_MIN, min(float(VIIVE_MS), 1.7 * ensi))
            self.kuolleita = 0
        else:
            self.kuolleita += 1
            if self.kuolleita >= 6:
                self.viive, self.kuolleita = float(VIIVE_MS), 0

        jalkeen = huippu
        alku = time.monotonic()
        loppu = alku + PALAUTUS_MS / 1000.0
        vika = alku
        while time.monotonic() < loppu:
            k = self.silma.lue()
            if k.auki:
                auki = True
                break
            if k.ok:
                if abs(k.kaanto - jalkeen) > 0.004:
                    vika = time.monotonic()
                jalkeen = k.kaanto
                if (time.monotonic() - vika) * 1000.0 >= VAKAA_MS:
                    break
        return max(0.0, huippu - pohja), max(0.0, jalkeen - pohja), jalkeen, auki

    def yritys(self):
        self.kotiin()
        kartta = peli.Kartta(1)
        kaanto = np.zeros(1)
        alku = time.monotonic()
        n = 0
        budjetti = max(6, int(BUDJETTI_S * 1000 / (self.viive + 200)))
        while time.monotonic() - alku < BUDJETTI_S and n < budjetti + 6:
            aika = np.array([1.0 - n / max(1, budjetti)])
            o = kartta.havainto(kaanto, aika, np.array([self.paikka]))
            a, _lp, _v = self.v.valitse(o, self.rng, ahne=self.ahne)
            siirto = peli.SIIRROT[int(a[0])]

            vanha = np.array([self.paikka])
            self.siirry(self.paikka + siirto)
            kartta.siirry(vanha, np.array([self.paikka]))

            nyk, jai, uusi_kaanto, auki = self.napauta()
            n += 1
            kartta.merkitse(np.array([jai]), np.array([nyk]))
            kaanto = np.array([uusi_kaanto])
            print(f"   {self.paikka:5.2f}  siirto {siirto:+.2f}  nykaisy {nyk*90:5.1f}  "
                  f"jai {jai*90:+5.1f}")
            if auki:
                return True, n
        return False, n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--naytteista", action="store_true")
    a = ap.parse_args()
    if not POLITIIKKA.exists():
        print("politiikka.npz puuttuu - aja ensin: python treeni.py")
        return 1
    if not WIN:
        print("Pelaaminen vaatii Windowsin.")
        return 1
    v = V.Verkko(peli.HAVAINTO, 128, peli.TOIMINTOJA)
    v.lataa(POLITIIKKA)
    silma, kasi = S.Silma(), Kasi()
    vahti(kasi)
    print(f"naytto {silma.avaa()}   F12 = seis\n")
    p = Pelaaja(v, silma, kasi, ahne=not a.naytteista)
    n = auki = 0
    while True:
        n += 1
        kasi.napauta(SPACE, 28)
        time.sleep(0.2)
        ok, napautyksia = p.yritys()
        auki += ok
        print(f"{n:4d} {'AUKI' if ok else 'ei  '}  {napautyksia:2d} napautysta   "
              f"{auki}/{n}  ({100*auki/n:.0f}%)   viive-arvio {p.viive:.0f} ms")
        if not ok:
            time.sleep(VALISSA_S)


if __name__ == "__main__":
    raise SystemExit(main())
