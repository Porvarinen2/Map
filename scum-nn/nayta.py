# -*- coding: utf-8 -*-
"""Nayttaa mita verkko oikeasti tekee - simuloitu lukko riveina.

Treenaa.bat ei pela SCUMia. Se pelaa tata: peli.py:n lukkomallia, 128
kappaletta rinnakkain, miljoonia kertoja. Tama tulostaa niita yksi
kerrallaan jotta nakee mita ruudun luvut tarkoittavat.

    python nayta.py            5 yritysta opetetulla verkolla
    python nayta.py --n 20
    python nayta.py --satunnainen   sama, mutta opettamattomalla verkolla
"""
from __future__ import annotations

import argparse

import numpy as np

import peli
import verkko as V

LEVEYS = 60


def palkki(paikka: float, aukko: float, ramppi: float, tarina: float) -> str:
    rivi = []
    for i in range(LEVEYS):
        p = (i + 0.5) / LEVEYS
        d = abs(p - aukko)
        if abs(p - paikka) < 0.5 / LEVEYS:
            rivi.append("T")                      # tiirikka
        elif d <= ramppi:
            rivi.append("#")                      # tassa lukko antaa periksi
        elif d <= ramppi + tarina:
            rivi.append("-")                      # tassa se vain tarahtaa
        else:
            rivi.append(".")
    return "".join(rivi)


def kaanto_palkki(k: float) -> str:
    n = int(round(k * 20))
    return "[" + "=" * n + " " * (20 - n) + f"] {k*90:5.1f} astetta"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=5)
    ap.add_argument("--satunnainen", action="store_true")
    a = ap.parse_args()

    from pathlib import Path
    polku = Path(__file__).resolve().parent / "politiikka.npz"
    v = V.Verkko(peli.HAVAINTO, 128, peli.TOIMINTOJA)
    if a.satunnainen:
        print("OPETTAMATON verkko (vertailun vuoksi)\n")
    elif polku.exists():
        v.lataa(polku)
        print("opetettu verkko\n")
    else:
        print("politiikka.npz puuttuu - aja ensin treeni.py\n")

    rng = np.random.default_rng(1)
    auki_yht = 0
    for yritys in range(1, a.n + 1):
        L = peli.Lukot(1, rng)
        print(f"--- yritys {yritys}  "
              f"(aukko {L.aukko[0]:.2f}, ramppi +-{L.ramppi[0]:.02f}, "
              f"{'kierto jaa' if L.raikka[0] > 0.5 else 'kierto palautuu'}, "
              f"{int(L.budjetti[0])} napautysta)")
        print("     " + palkki(L.paikka[0], L.aukko[0], L.ramppi[0], L.tarina[0]))
        o = L.havainto()
        for n in range(1, int(L.budjetti[0]) + 1):
            act, _lp, _arv = v.valitse(o, rng, ahne=not a.satunnainen)
            siirto = peli.SIIRROT[int(act[0])]
            o, _p, loppu, nyt_auki = L.askel(act)
            merkki = ("AUKI" if nyt_auki[0] else
                      ("ANTOI" if L.kartta.viime_jai[0] > 0.04 else
                       ("tarahti" if L.kartta.viime_nyk[0] > 0.03 else "-")))
            print(f"  {n:2d} " + palkki(L.paikka[0], L.aukko[0], L.ramppi[0], L.tarina[0]))
            print(f"     siirto {siirto:+.2f}  {kaanto_palkki(L.kaanto[0])}  {merkki}")
            if loppu[0]:
                break
        auki_yht += bool(nyt_auki[0])
        print(f"     => {'AUKI' if nyt_auki[0] else 'ei auennut'}\n")
    print(f"{auki_yht}/{a.n} auki")
    print("\nT = tiirikka   # = tassa lukko antaa periksi   - = tassa se vain tarahtaa")
    print("Verkko ei nae # ja - merkkeja. Se nakee vain sen mita napautykset kertoivat.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
