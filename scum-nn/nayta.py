# -*- coding: utf-8 -*-
"""Nayttaa mita verkko oikeasti tekee simuloidussa lukossa.

    py nayta.py                 5 yritysta
    py nayta.py --taso 4 --n 8  vaikeimmalla lukolla
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

import peli
import verkko as V

LEVEYS = 72


def jana(paikka, aukko, ramppi, target, usko=None):
    rivi = []
    for i in range(LEVEYS):
        p = (i + 0.5) / LEVEYS
        d = abs(p - aukko)
        if abs(p - paikka) < 0.5 / LEVEYS:
            rivi.append("T")
        elif d <= target:
            rivi.append("#")
        elif d <= ramppi:
            rivi.append("-")
        else:
            rivi.append(".")
    ulos = "".join(rivi)
    if usko is not None:
        u = np.zeros(LEVEYS)
        idx = np.clip((peli.Usko.KESKUS * LEVEYS).astype(int), 0, LEVEYS - 1)
        np.add.at(u, idx, usko)
        u = u / max(1e-9, u.max())
        merkit = " .:-=+*#@"
        ulos += "\n     " + "".join(merkit[min(8, int(x * 8.99))] for x in u)
    return ulos


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=5)
    ap.add_argument("--taso", type=int, default=None, help="0-4, oletus sekalaisia")
    ap.add_argument("--satunnainen", action="store_true")
    a = ap.parse_args()

    polku = Path(__file__).resolve().parent / "politiikka.npz"
    if polku.exists() and not a.satunnainen:
        d = np.load(polku)
        v = V.Verkko(peli.HAVAINTO, d["W1"].shape[1], [peli.SIIRTOJA, peli.PITOJA])
        v.lataa(polku)
        print("opetettu verkko\n")
    else:
        v = V.Verkko(peli.HAVAINTO, 192, [peli.SIIRTOJA, peli.PITOJA])
        print("OPETTAMATON verkko\n")

    rng = np.random.default_rng(1)
    auki_yht = 0
    for yritys in range(1, a.n + 1):
        taso = a.taso if a.taso is not None else (yritys - 1) % len(peli.TASOT)
        L = peli.Lukot(1, rng, taso=taso)
        L.paikka[:] = 0.0
        print(f"--- yritys {yritys}  [{peli.TASOT[taso][0]}]  aukko {L.aukko[0]:.3f}  "
              f"ramppi +-{L.ramppi[0]:.3f}  target +-{L.target[0]:.3f}  "
              f"budjetti {L.budjetti[0]/1000:.1f}s")
        print("     " + jana(L.paikka[0], L.aukko[0], L.ramppi[0], L.target[0]))
        o = L.havainto()
        auki = False
        n = 0
        while True:
            teot, _lp, _arv = v.valitse(o, rng, ahne=not a.satunnainen)
            si, pi = int(teot[0, 0]), int(teot[0, 1])
            mihin = "uskoon" if si >= peli.USKOON else f"{peli.SIIRROT[si]:+.3f}"
            o, _p, loppu, nyt = L.askel(teot[:, 0], teot[:, 1])
            n += 1
            print(f"  {n:2d} " + jana(L.paikka[0], L.aukko[0], L.ramppi[0], L.target[0],
                                      L.usko.p[0]))
            print(f"     siirto {mihin:>7}  pito {peli.PIDOT_MS[pi]:5.0f} ms  "
                  f"kaanto {L.viime_havainto[0]*90:5.1f} astetta  "
                  f"aika {L.aika[0]/1000:.2f}s" + ("   AUKI" if nyt[0] else ""))
            auki = bool(nyt[0])
            if loppu[0]:
                break
        auki_yht += auki
        print(f"     => {'AUKI' if auki else 'aika loppui'}\n")
    print(f"{auki_yht}/{a.n} auki\n")
    print("T = tiirikka   # = aukeaa tasta   - = tassa pesa liikkuu muttei aukea")
    print("Alempi rivi on verkon USKOMUS siita missa aukko on. Verkko ei nae")
    print("ylempaa rivia lainkaan - vain sen mita sen omat painallukset kertoivat.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
