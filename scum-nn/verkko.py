# -*- coding: utf-8 -*-
"""Neuroverkko ja PPO, numpylla. Ei torchia.

Verkko: jaettu runko (tanh-MLP) + kaksi paata
    politiikka  ->  logitit toiminnoille
    arvo        ->  yksi luku, paljonko tasta tilasta on odotettavissa

PPO: leikattu suhdetavoite, GAE-etu, entropiabonus, Adam.
Gradientit on kirjoitettu kasin ja tarkistettu numeerisesti (testit.py).
"""
from __future__ import annotations

from typing import Dict

import numpy as np


def alusta(rng, sisaan: int, ulos: int, skaala: float = 1.0):
    """Ortogonaalinen alustus - pitaa signaalin varianssin kurissa syvyydessa."""
    a = rng.standard_normal((sisaan, ulos))
    u, _s, vt = np.linalg.svd(a, full_matrices=False)
    q = u if u.shape == (sisaan, ulos) else vt
    return (skaala * q).astype(np.float64)


class Verkko:
    def __init__(self, sisaan: int, piilo: int, toimintoja: int, siemen: int = 0):
        rng = np.random.default_rng(siemen)
        self.p: Dict[str, np.ndarray] = {
            "W1": alusta(rng, sisaan, piilo, np.sqrt(2)),
            "b1": np.zeros(piilo),
            "W2": alusta(rng, piilo, piilo, np.sqrt(2)),
            "b2": np.zeros(piilo),
            "Wp": alusta(rng, piilo, toimintoja, 0.01),   # pieni -> alussa tasainen politiikka
            "bp": np.zeros(toimintoja),
            "Wv": alusta(rng, piilo, 1, 1.0),
            "bv": np.zeros(1),
        }
        self.toimintoja = toimintoja

    # ---- eteenpain ------------------------------------------------------

    def eteen(self, x: np.ndarray):
        p = self.p
        z1 = x @ p["W1"] + p["b1"]
        h1 = np.tanh(z1)
        z2 = h1 @ p["W2"] + p["b2"]
        h2 = np.tanh(z2)
        logit = h2 @ p["Wp"] + p["bp"]
        arvo = (h2 @ p["Wv"] + p["bv"])[:, 0]
        return logit, arvo, (x, h1, h2)

    # ---- taaksepain -----------------------------------------------------

    def taakse(self, valimuisti, dlogit: np.ndarray, darvo: np.ndarray) -> Dict[str, np.ndarray]:
        x, h1, h2 = valimuisti
        p = self.p
        g = {}
        g["Wp"] = h2.T @ dlogit
        g["bp"] = dlogit.sum(0)
        dv = darvo[:, None]
        g["Wv"] = h2.T @ dv
        g["bv"] = dv.sum(0)
        dh2 = dlogit @ p["Wp"].T + dv @ p["Wv"].T
        dz2 = dh2 * (1.0 - h2 * h2)
        g["W2"] = h1.T @ dz2
        g["b2"] = dz2.sum(0)
        dh1 = dz2 @ p["W2"].T
        dz1 = dh1 * (1.0 - h1 * h1)
        g["W1"] = x.T @ dz1
        g["b1"] = dz1.sum(0)
        return g

    # ---- politiikan apurit ----------------------------------------------

    @staticmethod
    def log_softmax(logit: np.ndarray) -> np.ndarray:
        z = logit - logit.max(axis=1, keepdims=True)
        return z - np.log(np.exp(z).sum(axis=1, keepdims=True))

    def valitse(self, x: np.ndarray, rng, ahne: bool = False):
        logit, arvo, _ = self.eteen(x)
        logp = self.log_softmax(logit)
        if ahne:
            a = logp.argmax(axis=1)
        else:
            todnak = np.exp(logp)
            kumul = todnak.cumsum(axis=1)
            r = rng.random((len(x), 1))
            a = (r > kumul).sum(axis=1)
            a = np.clip(a, 0, self.toimintoja - 1)
        return a, logp[np.arange(len(x)), a], arvo

    def tallenna(self, polku):
        np.savez(polku, **self.p)

    def lataa(self, polku):
        d = np.load(polku)
        for k in self.p:
            self.p[k] = d[k]


class Adam:
    def __init__(self, p: Dict[str, np.ndarray], lr: float = 3e-4):
        self.lr = lr
        self.m = {k: np.zeros_like(v) for k, v in p.items()}
        self.v = {k: np.zeros_like(v) for k, v in p.items()}
        self.t = 0

    def askel(self, p: Dict[str, np.ndarray], g: Dict[str, np.ndarray], katko: float = 0.5):
        # gradientin normin katkaisu - estaa yhden huonon eran rikkomasta politiikkaa
        normi = np.sqrt(sum(float((gv ** 2).sum()) for gv in g.values()))
        skaala = min(1.0, katko / (normi + 1e-8))
        self.t += 1
        b1, b2, eps = 0.9, 0.999, 1e-8
        for k in p:
            gk = g[k] * skaala
            self.m[k] = b1 * self.m[k] + (1 - b1) * gk
            self.v[k] = b2 * self.v[k] + (1 - b2) * gk * gk
            mh = self.m[k] / (1 - b1 ** self.t)
            vh = self.v[k] / (1 - b2 ** self.t)
            p[k] -= self.lr * mh / (np.sqrt(vh) + eps)
        return normi


def gae(palkkiot: np.ndarray, arvot: np.ndarray, lopetus: np.ndarray,
        gamma: float = 0.99, lam: float = 0.95):
    """Yleistetty etuestimaatti. arvot on pituudeltaan T+1."""
    T = len(palkkiot)
    etu = np.zeros(T)
    kertyma = 0.0
    for t in range(T - 1, -1, -1):
        jatkuu = 1.0 - lopetus[t]
        delta = palkkiot[t] + gamma * arvot[t + 1] * jatkuu - arvot[t]
        kertyma = delta + gamma * lam * jatkuu * kertyma
        etu[t] = kertyma
    return etu, etu + arvot[:T]


def ppo_paivitys(verkko: Verkko, adam: Adam, x, a, vanha_logp, etu, kohde_arvo,
                 rng, kierroksia=4, era=256, leikkaus=0.2, entropia=0.01, arvo_kerroin=0.5):
    n = len(x)
    etu = (etu - etu.mean()) / (etu.std() + 1e-8)
    for _ in range(kierroksia):
        jarjestys = rng.permutation(n)
        for alku in range(0, n, era):
            idx = jarjestys[alku:alku + era]
            xb, ab = x[idx], a[idx]
            logit, arvo, vali = verkko.eteen(xb)
            logp_kaikki = Verkko.log_softmax(logit)
            logp = logp_kaikki[np.arange(len(idx)), ab]
            suhde = np.exp(logp - vanha_logp[idx])
            eb = etu[idx]

            # --- leikattu politiikkatavoite ---
            leikattu = np.clip(suhde, 1 - leikkaus, 1 + leikkaus)
            kaytossa = suhde * eb <= leikattu * eb          # kumpi on pienempi
            dsuhde = np.where(kaytossa, eb, 0.0) / len(idx)
            dlogp = dsuhde * suhde
            todnak = np.exp(logp_kaikki)
            dlogit = -todnak * dlogp[:, None]
            dlogit[np.arange(len(idx)), ab] += dlogp
            dlogit = -dlogit                                 # maksimointi -> minimointi

            # --- entropiabonus ---
            H = -(todnak * logp_kaikki).sum(1)
            dH = todnak * (-(logp_kaikki + 1.0))
            dH = dH - todnak * (-(todnak * (logp_kaikki + 1.0)).sum(1, keepdims=True))
            dlogit += -entropia * dH / len(idx)

            # --- arvopaa ---
            darvo = arvo_kerroin * 2.0 * (arvo - kohde_arvo[idx]) / len(idx)

            g = verkko.taakse(vali, dlogit, darvo)
            adam.askel(verkko.p, g)
    return float(H.mean())
