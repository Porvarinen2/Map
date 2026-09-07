# -*- coding: utf-8 -*-
"""Lukkopeli verkon opetusta varten, N kappaletta rinnakkain.

Fysiikkaa ei tiedeta tarkasti, joten sita ei lukita: joka episodissa
arvotaan uusi lukko LAAJASTA jakaumasta - aukon paikka ja leveys, kuinka
paljon yksi napautys vie, tarahtaako pesa lahialueella, palautuuko kierto
otteen irrotessa, kuinka myohassa vaste nakyy ruudulla. Verkko joutuu
oppimaan politiikan joka toimii KAIKILLA naista, ei yhdella.

Sita kutsutaan domain randomisationiksi, ja se on ainoa rehellinen tapa
opettaa simulaatiossa kun oikeaa fysiikkaa ei tunneta.

Havainto on egosentrinen: kartta siita mita on nahty, aina suhteessa
siihen missa tiirikka NYT on. Silloin sama tilanne nayttaa samalta lukon
joka kohdassa, eika verkon tarvitse opetella samaa asiaa 20 kertaa.
"""
from __future__ import annotations

import numpy as np

RUUTUJA = 21                 # egosentrisen kartan ruudut
KANTAMA = 0.50               # kartta ulottuu +- tama verran nykyisesta
SKALAARIT = 6
HAVAINTO = RUUTUJA * 3 + SKALAARIT

SIIRROT = np.array([-0.30, -0.15, -0.08, -0.04, -0.02, 0.0,
                    0.02, 0.04, 0.08, 0.15, 0.30])
TOIMINTOJA = len(SIIRROT)



class Kartta:
    """Egosentrinen muisti siita mita lukossa on nahty.

    TASMALLEEN sama koodi opetuksessa ja oikeassa pelissa. Jos havainto
    rakennettaisiin kahdessa paikassa, ne eroaisivat ennemmin tai
    myohemmin ja opittu politiikka lakkaisi toimimasta ilman etta kukaan
    huomaisi miksi.
    """

    def __init__(self, n: int):
        self.n = n
        self.jai = np.zeros((n, RUUTUJA))
        self.nyk = np.zeros((n, RUUTUJA))
        self.kayty = np.zeros((n, RUUTUJA))
        self.viime_jai = np.zeros(n)
        self.viime_nyk = np.zeros(n)

    def nollaa(self, maski: np.ndarray) -> None:
        self.jai[maski] = 0.0
        self.nyk[maski] = 0.0
        self.kayty[maski] = 0.0
        self.viime_jai[maski] = 0.0
        self.viime_nyk[maski] = 0.0

    def siirry(self, vanha: np.ndarray, uusi: np.ndarray) -> None:
        """Kartta on suhteessa nykyiseen paikkaan, joten se rullaa mukana."""
        siirto = np.rint((uusi - vanha) / (2 * KANTAMA) * RUUTUJA).astype(int)
        for i in range(self.n):
            s = int(siirto[i])
            if s == 0:
                continue
            for k in (self.jai, self.nyk, self.kayty):
                rivi = np.zeros(RUUTUJA)
                if abs(s) < RUUTUJA:
                    if s > 0:
                        rivi[:RUUTUJA - s] = k[i, s:]
                    else:
                        rivi[-s:] = k[i, :RUUTUJA + s]
                k[i] = rivi

    def merkitse(self, jai: np.ndarray, nyk: np.ndarray) -> None:
        keskus = RUUTUJA // 2
        self.jai[:, keskus] = np.maximum(self.jai[:, keskus], jai)
        self.nyk[:, keskus] = np.maximum(self.nyk[:, keskus], nyk)
        self.kayty[:, keskus] = 1.0
        self.viime_jai, self.viime_nyk = jai, nyk

    def havainto(self, kaanto: np.ndarray, aika: np.ndarray, paikka: np.ndarray) -> np.ndarray:
        skalaarit = np.stack([
            kaanto,
            self.viime_jai,
            self.viime_nyk,
            aika,
            paikka,                      # jotta se tietaa missa seinat ovat
            1.0 - paikka,
        ], axis=1)
        return np.concatenate([self.jai, self.nyk, self.kayty, skalaarit], axis=1)


class Lukot:
    """N lukkoa rinnakkain. Yksi askel = siirry ja napauta kerran."""

    def __init__(self, n: int, rng: np.random.Generator, arvonta: bool = True):
        self.n = n
        self.rng = rng
        self.arvonta = arvonta
        self.uusi(np.ones(n, dtype=bool))

    def uusi(self, maski: np.ndarray) -> None:
        n = int(maski.sum())
        if n == 0:
            return
        r = self.rng
        def a(lo, hi):
            return r.uniform(lo, hi, n)

        for nimi, arvo in (
            ("aukko", a(0.03, 0.97)),
            ("ramppi", a(0.02, 0.10)),          # tassa lukko antaa periksi
            ("tarina", a(0.03, 0.14)),          # taman verran ramppia leveampi tarahdysvyo
            ("vie", a(0.15, 0.45)),             # paljonko yksi napautys vie
            ("raikka", (r.random(n) < 0.5).astype(float)),   # jaako kierto vai palautuuko
            ("palautus", a(0.3, 1.0)),          # jos palautuu, kuinka nopeasti
            ("avaus", a(0.85, 1.00)),           # kuinka pitkalle pitaa saada
            ("kohina", a(0.005, 0.030)),
        ):
            if not hasattr(self, nimi):
                setattr(self, nimi, np.zeros(self.n))
            getattr(self, nimi)[maski] = arvo

        # Napautysbudjetti: hitaampi peli -> vahemman napautyksia samaan aikaan
        viive_ms = r.uniform(40, 220, n)
        budjetti = np.floor(3400.0 / (viive_ms + 150.0)).astype(int)
        if not hasattr(self, "budjetti"):
            self.budjetti = np.zeros(self.n, dtype=int)
            self.kaanto = np.zeros(self.n)
            self.paikka = np.zeros(self.n)
            self.askelia = np.zeros(self.n, dtype=int)
            self.kartta = Kartta(self.n)
        self.budjetti[maski] = np.clip(budjetti, 8, 20)
        self.kaanto[maski] = 0.0
        self.paikka[maski] = r.random(n) if self.arvonta else 0.0
        self.askelia[maski] = 0
        self.kartta.nollaa(maski)

    # ---- havainto --------------------------------------------------------

    def havainto(self) -> np.ndarray:
        aika = 1.0 - self.askelia / np.maximum(1, self.budjetti)
        return self.kartta.havainto(self.kaanto, aika, self.paikka)

    # ---- askel -----------------------------------------------------------

    def askel(self, toiminto: np.ndarray):
        """Yksi askel: siirry ja napauta."""
        self.siirra(np.clip(self.paikka + SIIRROT[toiminto], 0.0, 1.0))
        return self.napauta()

    def siirra(self, uusi_paikka: np.ndarray) -> None:
        vanha = self.paikka.copy()
        self.paikka = np.clip(uusi_paikka, 0.0, 1.0)
        self.kartta.siirry(vanha, self.paikka)

    def napauta(self):
        """Yksi kevyt napautys nykyisessa paikassa. Tama on koko fysiikka."""
        d = np.abs(self.paikka - self.aukko)
        rampissa = d <= self.ramppi
        tarinassa = (~rampissa) & (d <= self.ramppi + self.tarina)

        # kuinka paljon pesa nykaisee ja kuinka paljon siita jaa
        vie = self.vie * rampissa * (1.0 - 0.5 * d / np.maximum(1e-6, self.ramppi))
        nykaisy = np.where(rampissa, vie * 1.4,
                           np.where(tarinassa, 0.10 * (1.0 - (d - self.ramppi) / np.maximum(1e-6, self.tarina)), 0.0))
        jai = np.where(self.raikka > 0.5, vie, vie * (1.0 - self.palautus))

        edellinen_kaanto = self.kaanto.copy()
        self.kaanto = np.clip(self.kaanto + jai, 0.0, 1.0)
        # jos kierto ei jaa, se valuu pois myos aiemmasta
        valuu = (self.raikka <= 0.5) * self.palautus * 0.35
        self.kaanto = np.clip(self.kaanto - valuu * (jai <= 1e-9), 0.0, 1.0)

        auki = self.kaanto >= self.avaus

        # havainnot ovat kohinaisia, kuten ruudulta luettuna
        koh = self.rng.normal(0.0, 1.0, self.n)
        mit_jai = np.maximum(0.0, self.kaanto - edellinen_kaanto + koh * self.kohina)
        mit_nyk = np.maximum(0.0, nykaisy + koh * self.kohina)
        self.kartta.merkitse(mit_jai, mit_nyk)

        self.askelia += 1
        loppu = auki | (self.askelia >= self.budjetti)

        palkkio = 12.0 * (self.kaanto - edellinen_kaanto) - 0.3
        palkkio = palkkio + 60.0 * auki
        return self.havainto(), palkkio, loppu, auki
