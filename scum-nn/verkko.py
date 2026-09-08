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
    """Runko + arvopaa + yksi tai useampi politiikkapaa.

    Lukkopelissa paita on kaksi: minne siirrytaan ja kuinka kauan F:aa
    painetaan. Ne ovat eri paatoksia, joten ne saavat omat softmaxinsa -
    yksi yhteinen 13x5 = 65 vaihtoehdon paa oppisi hitaammin eika jakaisi
    mitaan siirtojen ja pitojen valilla.
    """

    def __init__(self, sisaan: int, piilo: int, toimintoja, siemen: int = 0):
        rng = np.random.default_rng(siemen)
        self.p: Dict[str, np.ndarray] = {
            "W1": alusta(rng, sisaan, piilo, np.sqrt(2)),
            "b1": np.zeros(piilo),
            "W2": alusta(rng, piilo, piilo, np.sqrt(2)),
            "b2": np.zeros(piilo),
            "Wp": alusta(rng, piilo, int(np.sum(toimintoja)), 0.01),  # pieni -> alussa tasainen
            "bp": np.zeros(int(np.sum(toimintoja))),
            "Wv": alusta(rng, piilo, 1, 1.0),
            "bv": np.zeros(1),
        }
        self.paat = [int(toimintoja)] if np.isscalar(toimintoja) else [int(x) for x in toimintoja]
        self.toimintoja = int(np.sum(self.paat))
        self.rajat = np.cumsum([0] + self.paat)

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

    def log_softmax_paittain(self, logit: np.ndarray) -> np.ndarray:
        """Sama, mutta jokainen paa normalisoidaan erikseen."""
        ulos = np.empty_like(logit)
        for i in range(len(self.paat)):
            a, b = self.rajat[i], self.rajat[i + 1]
            ulos[:, a:b] = self.log_softmax(logit[:, a:b])
        return ulos

    def valitse(self, x: np.ndarray, rng, ahne: bool = False):
        """Palauttaa (toiminnot (N, paita), yhteis-logp, arvo)."""
        logit, arvo, _ = self.eteen(x)
        logp = self.log_softmax_paittain(logit)
        n = len(x)
        teot = np.zeros((n, len(self.paat)), dtype=np.int64)
        yht = np.zeros(n)
        for i in range(len(self.paat)):
            a, b = self.rajat[i], self.rajat[i + 1]
            osa = logp[:, a:b]
            if ahne:
                v = osa.argmax(axis=1)
            else:
                kumul = np.exp(osa).cumsum(axis=1)
                v = np.clip((rng.random((n, 1)) > kumul).sum(axis=1), 0, self.paat[i] - 1)
            teot[:, i] = v
            yht += osa[np.arange(n), v]
        return teot, yht, arvo

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
    """Yleistetty etuestimaatti.

    Toimii seka yhdelle jonolle (palkkiot muotoa (T,), arvot (T+1,)) etta
    kaikille ymparistoille kerralla ((T, N) ja (T+1, N)). Silmukka kulkee
    vain ajassa, ei ymparistojen yli - se olisi kymmeniatuhansia python-
    kierroksia jokaisella opetuskierroksella.
    """
    T = palkkiot.shape[0]
    etu = np.zeros_like(palkkiot)
    kertyma = np.zeros(palkkiot.shape[1:])
    for t in range(T - 1, -1, -1):
        jatkuu = 1.0 - lopetus[t]
        delta = palkkiot[t] + gamma * arvot[t + 1] * jatkuu - arvot[t]
        kertyma = delta + gamma * lam * jatkuu * kertyma
        etu[t] = kertyma
    return etu, etu + arvot[:T]


def ppo_paivitys(verkko: Verkko, adam: Adam, x, a, vanha_logp, etu, kohde_arvo,
                 rng, kierroksia=4, era=8192, leikkaus=0.2, entropia=0.01, arvo_kerroin=0.5):
    n = len(x)
    etu = (etu - etu.mean()) / (etu.std() + 1e-8)
    for _ in range(kierroksia):
        jarjestys = rng.permutation(n)
        for alku in range(0, n, era):
            idx = jarjestys[alku:alku + era]
            xb, ab = x[idx], a[idx]
            logit, arvo, vali = verkko.eteen(xb)
            logp_kaikki = verkko.log_softmax_paittain(logit)
            rivi = np.arange(len(idx))
            logp = np.zeros(len(idx))
            for i in range(len(verkko.paat)):
                p0, p1 = verkko.rajat[i], verkko.rajat[i + 1]
                logp += logp_kaikki[rivi, p0 + ab[:, i]]
            suhde = np.exp(logp - vanha_logp[idx])
            eb = etu[idx]

            # --- leikattu politiikkatavoite ---
            leikattu = np.clip(suhde, 1 - leikkaus, 1 + leikkaus)
            kaytossa = suhde * eb <= leikattu * eb          # kumpi on pienempi
            dsuhde = np.where(kaytossa, eb, 0.0) / len(idx)
            dlogp = dsuhde * suhde
            todnak = np.exp(logp_kaikki)
            dlogit = np.zeros_like(logit)
            H = np.zeros(len(idx))
            for i in range(len(verkko.paat)):
                p0, p1 = verkko.rajat[i], verkko.rajat[i + 1]
                pk = todnak[:, p0:p1]
                lp = logp_kaikki[:, p0:p1]
                d = -pk * dlogp[:, None]
                d[rivi, ab[:, i]] += dlogp
                dlogit[:, p0:p1] = -d                        # maksimointi -> minimointi
                # --- entropiabonus, paittain ---
                H += -(pk * lp).sum(1)
                dH = pk * (-(lp + 1.0))
                dH = dH - pk * (-(pk * (lp + 1.0)).sum(1, keepdims=True))
                dlogit[:, p0:p1] += -entropia * dH / len(idx)

            # --- arvopaa ---
            darvo = arvo_kerroin * 2.0 * (arvo - kohde_arvo[idx]) / len(idx)

            g = verkko.taakse(vali, dlogit, darvo)
            adam.askel(verkko.p, g)
    return float(H.mean())
