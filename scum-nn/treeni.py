# -*- coding: utf-8 -*-
"""Opettaa verkon pelaamaan lukkopelia. PPO, tuhansia lukkoja rinnakkain.

    py treeni.py                                  oletukset
    py treeni.py --ymparistoja 8192 --piilo 384 --kierroksia 6000
"""
from __future__ import annotations

import argparse
import time
from pathlib import Path

import numpy as np

import peli
import verkko as V

JUURI = Path(__file__).resolve().parent
POLITIIKKA = JUURI / "politiikka.npz"


def aja_politiikka(v, rng, ymp, ahne=True, maks_askelia=40):
    """Ajaa ymparistot loppuun ja palauttaa (avattujen osuus, keskiaika)."""
    n = ymp.n
    auki = np.zeros(n, dtype=bool)
    elossa = np.ones(n, dtype=bool)
    ajat = np.zeros(n)
    o = ymp.havainto()
    for _ in range(maks_askelia):
        teot, _lp, _arv = v.valitse(o, rng, ahne=ahne)
        o, _p, loppu, nyt = ymp.askel(teot[:, 0], teot[:, 1])
        auki |= nyt & elossa
        ajat = np.where(elossa & loppu, ymp.aika / 1000.0, ajat)
        elossa &= ~loppu
        if not elossa.any():
            break
    return float(auki.mean()), float(ajat[auki].mean() if auki.any() else 0.0)


def arvioi_tasoittain(v, rng, per_taso=3000, ahne=True):
    """Sama politiikka jokaisella lukkotasolla erikseen."""
    tulokset = []
    for i in range(len(peli.TASOT)):
        osuus, _t = aja_politiikka(v, rng, peli.Lukot(per_taso, rng, taso=i), ahne)
        tulokset.append(osuus)
    return tulokset


def verrokki_satunnainen(rng, n=3000):
    tulokset = []
    for i in range(len(peli.TASOT)):
        ymp = peli.Lukot(n, rng, taso=i)
        auki = np.zeros(n, dtype=bool); elossa = np.ones(n, dtype=bool)
        for _ in range(40):
            s = rng.integers(0, peli.SIIRTOJA, n); h = rng.integers(0, peli.PITOJA, n)
            _o, _p, loppu, nyt = ymp.askel(s, h)
            auki |= nyt & elossa; elossa &= ~loppu
            if not elossa.any():
                break
        tulokset.append(float(auki.mean()))
    return tulokset


def rivi(tulokset):
    return "  ".join(f"L{i}:{100*x:5.1f}%" for i, x in enumerate(tulokset))


def opeta(kierroksia=3000, ymparistoja=4096, askelia=32, lr=4e-4, siemen=0,
          piilo=256, kurssi=0.30, ppo_kierroksia=2):
    rng = np.random.default_rng(siemen)
    v = V.Verkko(peli.HAVAINTO, piilo, [peli.SIIRTOJA, peli.PITOJA], siemen=siemen)
    adam = V.Adam(v.p, lr=lr)
    ymp = peli.Lukot(ymparistoja, rng, vaikeus=0.0)
    o = ymp.havainto()

    painoja = sum(x.size for x in v.p.values())
    puskuri = askelia * ymparistoja * peli.HAVAINTO * 8 / 1e6
    print(f"verkko {peli.HAVAINTO} -> {piilo} -> {piilo} -> "
          f"[{peli.SIIRTOJA} siirtoa, {peli.PITOJA} pitoa]  ({painoja:,} painoa)")
    print(f"{ymparistoja:,} lukkoa rinnakkain x {askelia} askelta = "
          f"{ymparistoja*askelia:,} naytetta/kierros ({puskuri:.0f} MB)")
    for i, (nimi, rlo, rhi, tlo, thi) in enumerate(peli.TASOT):
        print(f"  L{i} {nimi:14s} ramppi {rlo:.3f}-{rhi:.3f}  target {tlo:.3f}-{thi:.3f}")
    print(f"\nsatunnainen politiikka:  {rivi(verrokki_satunnainen(rng, 1500))}\n")
    print(f"{'kierros':>8}{'naytteita':>14}{'vaik':>6}{'palkkio':>9}"
          f"{'  L0     L1     L2     L3     L4':>38}{'ka':>8}{'aikaa':>8}")

    alku = time.time()
    paras = -1.0
    for kierros in range(1, kierroksia + 1):
        vaikeus = min(1.0, (kierros - 1) / max(1, kurssi * kierroksia))
        ymp.vaikeus = vaikeus

        O = np.zeros((askelia, ymparistoja, peli.HAVAINTO))
        A = np.zeros((askelia, ymparistoja, 2), dtype=np.int64)
        LP = np.zeros((askelia, ymparistoja))
        R = np.zeros((askelia, ymparistoja))
        D = np.zeros((askelia, ymparistoja))
        Arv = np.zeros((askelia + 1, ymparistoja))

        for t in range(askelia):
            teot, lp, arvo = v.valitse(o, rng)
            O[t], A[t], LP[t], Arv[t] = o, teot, lp, arvo
            o, palkkio, loppu, _auki = ymp.askel(teot[:, 0], teot[:, 1])
            R[t], D[t] = palkkio, loppu.astype(float)
            if loppu.any():
                ymp.uusi(loppu)
                o = ymp.havainto()
        Arv[askelia] = v.eteen(o)[1]
        etu, kohde = V.gae(R, Arv, D)

        jaljella = 1.0 - (kierros - 1) / max(1, kierroksia)
        adam.lr = lr * max(0.08, jaljella)
        V.ppo_paivitys(v, adam, O.reshape(-1, peli.HAVAINTO), A.reshape(-1, 2),
                       LP.reshape(-1), etu.reshape(-1), kohde.reshape(-1), rng,
                       kierroksia=ppo_kierroksia,
                       entropia=0.015 * max(0.1, jaljella))

        if kierros % 25 == 0 or kierros == 1:
            tul = arvioi_tasoittain(v, rng, 1200)
            ka = float(np.mean(tul))
            if (ka > paras and vaikeus >= 1.0) or not POLITIIKKA.exists():
                if vaikeus >= 1.0:
                    paras = ka
                v.tallenna(POLITIIKKA)
            print(f"{kierros:8d}{kierros*askelia*ymparistoja:14,}{vaikeus:6.2f}"
                  f"{R.mean():9.2f}  {rivi(tul)}{100*ka:7.1f}%{time.time()-alku:7.0f}s")

    tul = arvioi_tasoittain(v, rng, 8000)
    print(f"\nlopullinen:  {rivi(tul)}   keskiarvo {100*np.mean(tul):.1f}%  "
          f"heikoin {100*min(tul):.1f}%")
    if np.mean(tul) > paras:
        v.tallenna(POLITIIKKA)
    return v


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--kierroksia", type=int, default=3000)
    ap.add_argument("--ymparistoja", type=int, default=4096)
    ap.add_argument("--askelia", type=int, default=32)
    ap.add_argument("--piilo", type=int, default=256)
    ap.add_argument("--lr", type=float, default=4e-4)
    ap.add_argument("--siemen", type=int, default=0)
    ap.add_argument("--kurssi", type=float, default=0.30,
                    help="osuus kierroksista jonka aikana vaikeus nousee tayteen")
    ap.add_argument("--ppo", type=int, default=2, help="PPO-kierrosta per era")
    a = ap.parse_args()
    opeta(a.kierroksia, a.ymparistoja, a.askelia, a.lr, a.siemen, a.piilo,
          a.kurssi, a.ppo)
