# -*- coding: utf-8 -*-
"""Opetettu verkko pelaa oikeaa lukkoa, pelkan ruudun perusteella.

Havainto rakennetaan samalla peli.Usko-luokalla kuin opetuksessa: sama
Bayes-paivitys, samat hypoteesit, samat skalaarit. Verkko nakee pelin siis
tasmalleen samassa muodossa kuin simulaatiossa.

    py pelaa.py
    py pelaa.py --naytteista     verkko saa arpoa (ei aina ahne)
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
LUKU_MS = 150          # kauanko painalluksen jalkeen huippua viela katsotaan
VAKAA_MS = 45
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
    """F12 lopettaa heti, kesken painalluksenkin."""
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
    def __init__(self, v, silma, kasi, ahne=True, budjetti_s=3.4):
        self.v, self.silma, self.kasi, self.ahne = v, silma, kasi, ahne
        self.budjetti_s = budjetti_s
        self.rng = np.random.default_rng(0)
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
            time.sleep(0.02)
        self.paikka = uusi

    def paina(self, pito_ms: float):
        """Paina F annetun ajan ja lue kuinka pitkalle pesa kaantyi.

        Palauttaa (havaittu kaanto 0..1, aukesiko). Sama suure kuin
        simulaatiossa: 1.0 = 90 astetta.
        """
        pohja = self.silma.lue()
        alku_kaanto = pohja.kaanto if pohja.ok else 0.0
        auki = pohja.auki
        huippu = alku_kaanto

        self.kasi.nappi(F, True)
        loppu = time.monotonic() + pito_ms / 1000.0
        while time.monotonic() < loppu:
            k = self.silma.lue()
            if k.auki:
                auki = True
                break
            if k.ok and k.kaanto > huippu:
                huippu = k.kaanto
        self.kasi.nappi(F, False)

        # Huippu voi nakya vasta hetki painalluksen jalkeen.
        alku = time.monotonic()
        vika = alku
        while (time.monotonic() - alku) * 1000.0 < LUKU_MS:
            k = self.silma.lue()
            if k.auki:
                auki = True
                break
            if k.ok and k.kaanto > huippu + 0.004:
                huippu = k.kaanto
                vika = time.monotonic()
            elif (time.monotonic() - vika) * 1000.0 >= VAKAA_MS:
                break
        return max(0.0, huippu - alku_kaanto), auki

    def yritys(self):
        self.kotiin()
        usko = peli.Usko(1)
        alku = time.monotonic()
        viime_hav = viime_pito = paras_kaanto = 0.0
        n = 0
        while True:
            kulunut = time.monotonic() - alku
            if kulunut >= self.budjetti_s:
                return False, n
            jaljella = np.array([np.clip(1.0 - kulunut / self.budjetti_s, 0.0, 1.0)])
            paras = usko.paras()
            o = np.concatenate([
                usko.nakyma(np.array([self.paikka])) * peli.USKO_NAKYY,
                np.stack([
                    np.array([self.paikka]), np.array([1.0 - self.paikka]),
                    np.array([viime_hav]), np.array([viime_pito / 1500.0]),
                    usko.entropia(),
                    np.clip(paras - self.paikka, -1.0, 1.0),
                    np.abs(paras - self.paikka),
                    jaljella, np.array([paras_kaanto]),
                    np.array([min(1.5, n / 20.0)]),
                ], axis=1)], axis=1)

            teot, _lp, _arv = self.v.valitse(o, self.rng, ahne=self.ahne)
            siirto_i, pito_i = int(teot[0, 0]), int(teot[0, 1])
            pito = float(peli.PIDOT_MS[pito_i])
            kohde = (float(paras[0]) if siirto_i >= peli.USKOON
                     else self.paikka + float(peli.SIIRROT[min(siirto_i, peli.USKOON - 1)]))
            self.siirry(kohde)

            hav, auki = self.paina(pito)
            n += 1
            viime_hav, viime_pito = hav, pito
            paras_kaanto = max(paras_kaanto, hav)
            usko.paivita(np.array([self.paikka]), np.array([hav]), np.array([pito]))
            print(f"   {self.paikka:5.3f}  pito {pito:5.0f} ms  kaanto {hav*90:5.1f}  "
                  f"usko {usko.paras()[0]:5.3f} (ent {usko.entropia()[0]:.2f})")
            if auki:
                return True, n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--naytteista", action="store_true")
    ap.add_argument("--budjetti", type=float, default=3.4)
    a = ap.parse_args()
    if not POLITIIKKA.exists():
        print("politiikka.npz puuttuu - aja ensin: py treeni.py")
        return 1
    if not WIN:
        print("Pelaaminen vaatii Windowsin.")
        return 1
    d = np.load(POLITIIKKA)
    piilo = d["W1"].shape[1]
    v = V.Verkko(peli.HAVAINTO, piilo, [peli.SIIRTOJA, peli.PITOJA])
    v.lataa(POLITIIKKA)
    silma, kasi = S.Silma(), Kasi()
    vahti(kasi)
    print(f"naytto {silma.avaa()}   verkko {piilo} piilossa   F12 = seis\n")
    p = Pelaaja(v, silma, kasi, ahne=not a.naytteista, budjetti_s=a.budjetti)
    n = auki = 0
    while True:
        n += 1
        kasi.napauta(SPACE, 28)
        time.sleep(0.2)
        ok, askelia = p.yritys()
        auki += ok
        print(f"{n:4d} {'AUKI' if ok else 'ei  '}  {askelia:2d} painallusta   "
              f"{auki}/{n}  ({100*auki/n:.0f}%)")
        if not ok:
            time.sleep(VALISSA_S)


if __name__ == "__main__":
    raise SystemExit(main())
