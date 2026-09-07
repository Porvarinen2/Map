# -*- coding: utf-8 -*-
"""Testaa OIKEAA ohjainta simuloitua raikkalukkoa vasten.

Tassa ei ole kopiota Avaajasta: Silma ja Kasi korvataan valelluilla, ja
lukko.py:n oma Avaaja ajaa niiden lapi. Testattu koodi on siis se koodi
joka lahtee peliin.

Lukkomalli on mitattu kayttajan omasta datasta:
    painallus alle 0.05 paassa aukosta  ->  +0.38 kaantoa ~145 ms:ssa
    painallus yli  0.50 paassa aukosta  ->  +0.04
eli kaanto kertyy nopeudella joka putoaa etaisyyden mukaan. Se KUINKA
jyrkasti se putoaa ei ratkea 23 pisteesta, joten se pyyhkaistaan lapi.

    python simu.py
"""
from __future__ import annotations

import argparse
import random
import time
from typing import List, Optional

import numpy as np

import lukko as L


class ValeLukko:
    """Kaksi mahdollista fysiikkaa, koska 23 mittauspisteesta ei voi paattaa
    kumpi peli on. Ohjaimen pitaa toimia molemmissa.

    "raikka"  kaanto kertyy kun F on pohjassa lahella aukkoa ja JAA sinne.
              Etaisyys maaraa kertymisnopeuden. Yli 'raja':n paassa ei
              tapahdu mitaan.
    "taso"    kaanto hakeutuu kattoon jonka etaisyys maaraa, ja PALAA
              nollaan kun ote irtoaa. Lukko aukeaa vain jos katto yltaa
              avaus-tasolle, eli yhdella painalluksella pitaa olla
              tarpeeksi lahella.

    Mitattu kayttajan datasta: painallus alle 0.05 paassa aukosta vie
    +0.38 kaantoa noin 145 ms:ssa (= 2.6 yksikkoa sekunnissa).
    """

    def __init__(self, L_putoama: float, avaus_kaanto: float, rng: random.Random,
                 malli: str = "raikka", nopeus: float = 2.6, raja: float = 0.5,
                 palautuma: float = 0.25):
        self.rng = rng
        self.aukko = rng.uniform(0.03, 0.97)
        self.L = L_putoama
        self.malli = malli
        self.nopeus = nopeus
        self.raja = raja                # tata kauempana ei tapahdu mitaan
        self.avaus = avaus_kaanto
        self.palautuma = palautuma if malli == "raikka" else 6.0
        self.kaanto = 0.0
        self.auki = False
        self.aika = 0.0
        self.f = False
        self.paikka = 0.0
        self.f_aika = 0.0

    def _teho(self) -> float:
        d = abs(self.paikka - self.aukko)
        if d > self.raja:
            return 0.0
        return float(np.exp(-d / self.L))

    def etene(self, dt: float) -> None:
        if self.auki:
            return
        self.aika += dt
        if self.f:
            self.f_aika += dt
            if self.malli == "raikka":
                self.kaanto += self.nopeus * self._teho() * dt
            else:
                katto = self._teho()
                self.kaanto += (katto - self.kaanto) * min(1.0, self.nopeus * dt)
        else:
            self.kaanto = max(0.0, self.kaanto - self.palautuma * dt)
        self.kaanto = float(np.clip(self.kaanto, 0.0, 1.0))
        if self.kaanto >= self.avaus:
            self.auki = True

    def lukema(self) -> float:
        return float(np.clip(self.kaanto + self.rng.gauss(0.0, 0.008), 0.0, 1.0))


class ValeSilma:
    LUKEMA_S = 0.003     # mitattu: 3.0 ms per lukema

    def __init__(self, lukko: ValeLukko):
        self.lukko = lukko

    def lue(self) -> L.Havainto:
        self.lukko.etene(self.LUKEMA_S)
        return L.Havainto(ok=True, kaanto=self.lukko.lukema(), kulma=self.lukko.kaanto * 90.0,
                          kaynnissa=True, auki=self.lukko.auki, aika=self.lukko.aika)

    def nollaa_kulma(self):
        pass


class ValeKasi:
    """Aika kuluu siirroissa ja unissa, jotta budjetti tarkoittaa jotain."""

    def __init__(self, s: L.Saadot, lukko: ValeLukko):
        self.s = s
        self.lukko = lukko
        self.f_alhaalla = False

    def siirra(self, yksikkoa: float) -> None:
        self.lukko.paikka = float(np.clip(
            self.lukko.paikka + yksikkoa / self.s.jana_yksikkoa, 0.0, 1.0))
        palat = max(1, int(abs(yksikkoa) / self.s.pala_yksikkoa))
        self.lukko.etene(0.003 * palat)

    def f_alas(self) -> None:
        self.lukko.f = True
        self.f_alhaalla = True

    def f_ylos(self) -> None:
        self.lukko.f = False
        self.f_alhaalla = False

    def nappaise(self, vk: int, ms: int = 30) -> None:
        self.lukko.etene(ms / 1000.0)

    def pohjassa(self, vk: int) -> bool:
        return False


def _monotonic_patch(lukko: ValeLukko):
    return lambda: lukko.aika


def yksi_yritys(s: L.Saadot, lukko: ValeLukko) -> bool:
    silma, kasi = ValeSilma(lukko), ValeKasi(s, lukko)
    avaaja = L.Avaaja(s, silma, kasi)
    oikea_monotonic, oikea_sleep = time.monotonic, time.sleep
    time.monotonic = _monotonic_patch(lukko)
    time.sleep = lambda x: lukko.etene(x)
    try:
        ok, _painallukset = avaaja.yritys()
    finally:
        time.monotonic, time.sleep = oikea_monotonic, oikea_sleep
    return ok


def aja(s: L.Saadot, L_putoama: float, avaus: float, n: int, siemen: int,
        malli: str = "raikka") -> float:
    rng = random.Random(siemen)
    ok = 0
    for _ in range(n):
        ok += yksi_yritys(s, ValeLukko(L_putoama, avaus, rng, malli=malli))
    return 100.0 * ok / n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--yritykset", type=int, default=400)
    ap.add_argument("--siemenia", type=int, default=3)
    a = ap.parse_args()
    s = L.Saadot()
    s.lokita = False

    print("=== OIKEA AVAAJA SIMULOITUA LUKKOA VASTEN ===")
    print(f"budjetti {s.budjetti_s}s, haku_askel {s.haku_askel}, "
          f"edistys_min {s.edistys_min}, vauhti_min {s.vauhti_min}\n")
    print("L     = kuinka jyrkasti vaste putoaa etaisyyden mukaan (pieni = kapea aukko)")
    print("avaus = kuinka pitkalle pesa pitaa saada jotta lukko aukeaa")
    print("Molemmat fysiikkamallit ajetaan, koska datasta ei voi paattaa kumpi peli on.\n")
    for malli in ("raikka", "taso"):
        print(f"--- {malli} ---")
        print(f"{'L':>6}" + "".join(f"{('avaus '+str(av)):>12}" for av in (0.60, 0.80, 0.95)))
        for Lp in (0.08, 0.12, 0.20, 0.35):
            rivi = f"{Lp:6.2f}"
            for av in (0.60, 0.80, 0.95):
                tulos = np.mean([aja(s, Lp, av, a.yritykset, 100 + i, malli)
                                 for i in range(a.siemenia)])
                rivi += f"{tulos:11.1f}%"
            print(rivi)
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
