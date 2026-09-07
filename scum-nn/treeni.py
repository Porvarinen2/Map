# -*- coding: utf-8 -*-
"""Opettaa verkon pelaamaan lukkopelia. PPO, 128 lukkoa rinnakkain.

    python treeni.py                 opeta
    python treeni.py --kierroksia 400
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


def arvioi(v: V.Verkko, rng, n=2000, ahne=True) -> tuple:
    """Kuinka usein politiikka avaa lukon, ja monellako napautyksella."""
    ymp = peli.Lukot(n, rng)
    auki = np.zeros(n, dtype=bool)
    napautyksia = np.zeros(n, dtype=int)
    elossa = np.ones(n, dtype=bool)
    o = ymp.havainto()
    for _ in range(25):
        a, _lp, _v = v.valitse(o, rng, ahne=ahne)
        o, _p, loppu, nyt_auki = ymp.askel(a)
        napautyksia += elossa
        auki |= nyt_auki & elossa
        elossa &= ~loppu
        if not elossa.any():
            break
    return float(auki.mean()), float(napautyksia[auki].mean() if auki.any() else 0.0)


def satunnainen_verrokki(rng, n=2000) -> float:
    ymp = peli.Lukot(n, rng)
    auki = np.zeros(n, dtype=bool)
    elossa = np.ones(n, dtype=bool)
    for _ in range(25):
        a = rng.integers(0, peli.TOIMINTOJA, n)
        _o, _p, loppu, nyt_auki = ymp.askel(a)
        auki |= nyt_auki & elossa
        elossa &= ~loppu
        if not elossa.any():
            break
    return float(auki.mean())


def opeta(kierroksia: int, ymparistoja: int = 128, askelia: int = 48,
          lr: float = 4e-4, siemen: int = 0, piilo: int = 128):
    rng = np.random.default_rng(siemen)
    v = V.Verkko(peli.HAVAINTO, piilo, peli.TOIMINTOJA, siemen=siemen)
    adam = V.Adam(v.p, lr=lr)
    ymp = peli.Lukot(ymparistoja, rng)
    o = ymp.havainto()

    print(f"verkko {peli.HAVAINTO} -> {piilo} -> {piilo} -> {peli.TOIMINTOJA} "
          f"({sum(x.size for x in v.p.values()):,} painoa)")
    print(f"satunnainen politiikka avaa {100*satunnainen_verrokki(rng):.1f}%\n")
    print(f"{'kierros':>8}{'askelia':>10}{'palkkio':>9}{'auki':>8}{'napautyksia':>12}"
          f"{'entropia':>10}{'aikaa':>8}")

    alku = time.time()
    paras = -1.0
    for kierros in range(1, kierroksia + 1):
        O = np.zeros((askelia, ymparistoja, peli.HAVAINTO))
        A = np.zeros((askelia, ymparistoja), dtype=int)
        LP = np.zeros((askelia, ymparistoja))
        R = np.zeros((askelia, ymparistoja))
        D = np.zeros((askelia, ymparistoja))
        Arv = np.zeros((askelia + 1, ymparistoja))

        for t in range(askelia):
            a, lp, arvo = v.valitse(o, rng)
            O[t], A[t], LP[t], Arv[t] = o, a, lp, arvo
            o, palkkio, loppu, _auki = ymp.askel(a)
            R[t], D[t] = palkkio, loppu.astype(float)
            if loppu.any():
                ymp.uusi(loppu)
                o = ymp.havainto()
        Arv[askelia] = v.eteen(o)[1]

        etu = np.zeros((askelia, ymparistoja))
        kohde = np.zeros((askelia, ymparistoja))
        for i in range(ymparistoja):
            etu[:, i], kohde[:, i] = V.gae(R[:, i], Arv[:, i], D[:, i])

        # Alussa tutkitaan reilusti, lopussa hiotaan: entropia ja
        # oppimisnopeus laskevat tasaisesti nollaa kohti.
        osuus_jaljella = 1.0 - (kierros - 1) / max(1, kierroksia)
        adam.lr = lr * max(0.1, osuus_jaljella)
        ent = 0.02 * max(0.15, osuus_jaljella)
        H = V.ppo_paivitys(v, adam, O.reshape(-1, peli.HAVAINTO), A.reshape(-1),
                           LP.reshape(-1), etu.reshape(-1), kohde.reshape(-1), rng,
                           entropia=ent)

        if kierros % 50 == 0 or kierros == 1:
            osuus, nap = arvioi(v, rng, 1500)
            if osuus > paras:
                paras = osuus
                v.tallenna(POLITIIKKA)
            print(f"{kierros:8d}{kierros*askelia*ymparistoja:10,}{R.mean():9.2f}"
                  f"{100*osuus:7.1f}%{nap:12.1f}{H:10.3f}{time.time()-alku:7.0f}s")

    osuus, nap = arvioi(v, rng, 4000)
    print(f"\nlopullinen (ahne): {100*osuus:.1f}% auki, {nap:.1f} napautysta")
    osuus_n, _ = arvioi(v, rng, 4000, ahne=False)
    print(f"lopullinen (naytteistaen): {100*osuus_n:.1f}%")
    if osuus > paras:
        v.tallenna(POLITIIKKA)
    print(f"paras tallennettu: {POLITIIKKA.name}")
    return v


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--kierroksia", type=int, default=300)
    ap.add_argument("--siemen", type=int, default=0)
    a = ap.parse_args()
    opeta(a.kierroksia, siemen=a.siemen)
