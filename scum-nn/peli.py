# -*- coding: utf-8 -*-
"""SCUM-lukkopeli simuloituna. N lukkoa rinnakkain, opetusta varten.

FYSIIKKA (HOLD-TO-90)
    Tiirikan paikka maaraa kuinka pitkalle pesa VOI kaantya:

        etaisyys aukosta <= target      ->  katto 1.0  (90 astetta, aukeaa)
        target < etaisyys < ramppi      ->  katto putoaa portaattomasti
        etaisyys >= ramppi              ->  katto 0    (ei liiku)

    F:n pitaminen maaraa kuinka pitkalle sita kattoa kohti ehditaan:

        kaanto -> katto * (1 - exp(-pito / tau))

    Lyhyt napautys siis PALJASTAA rampin muttei avaa lukkoa edes oikeassa
    kohdassa. Avaaminen vaatii etta ollaan targetissa JA pidetaan tarpeeksi.

AIKA on oikeaa aikaa, ei askelia: jokainen siirto, painallus ja ruudunluku
syo budjettia. Siksi verkko joutuu oppimaan milloin lopettaa etsiminen ja
sitoutua - se on koko pelin ydin.

MITAAN NAISTA EI LUKITA. Joka episodissa arvotaan uusi lukko laajasta
jakaumasta, joten opittu politiikka ei voi nojata yhteen fysiikkaan.
"""
from __future__ import annotations

import numpy as np

# --- toiminnot -------------------------------------------------------------

# Siirtoja tarvitaan kahdessa mittakaavassa: karkeita etsimiseen ja niin
# hienoja etta kapeimpaan aukkoon (+-0.004) voi ylipaataan osua.
SIIRROT = np.array([-0.35, -0.20, -0.12, -0.07, -0.035, -0.015, -0.006, 0.0,
                    0.006, 0.015, 0.035, 0.07, 0.12, 0.20, 0.35])
# Viimeinen toiminto ei ole siirto vaan "mene sinne missa aukko uskomuksen
# mukaan todennakoisimmin on". Ilman sita verkko ei paase uskomuksensa
# huipulle tarkemmin kuin lahin askel sattuu osumaan.
USKOON = len(SIIRROT)
PIDOT_MS = np.array([70.0, 160.0, 360.0, 700.0, 1200.0, 1900.0])
SIIRTOJA, PITOJA = len(SIIRROT) + 1, len(PIDOT_MS)

# --- uskomus ---------------------------------------------------------------

USKO_RUUTUJA = 96          # mihin aukon paikka jaetaan
USKO_NAKYY = 24            # kuinka monta ruutua verkolle nayteta (egosentrisesti)
USKO_KANTAMA = 0.45

SKALAAREJA = 10
HAVAINTO = USKO_NAKYY + SKALAAREJA


def pito_osuus(pito_ms, tau_ms):
    return 1.0 - np.exp(-np.asarray(pito_ms, dtype=np.float64) / np.maximum(20.0, tau_ms))


class Usko:
    """Missa aukko voi olla, kaikkien tahan asti tehtyjen painallusten jalkeen.

    Tama on se mika tekee tehtavasta opittavan. Ilman sita verkon pitaisi
    paatella fysiikka uudestaan joka episodissa pelkasta historiasta.
    Sama koodi ajetaan simulaatiossa ja oikeassa pelissa, joten se mita
    verkko oppii kayttamaan on olemassa myos ruudun aaressa.
    """

    KESKUS = (np.arange(USKO_RUUTUJA) + 0.5) / USKO_RUUTUJA

    def __init__(self, n: int):
        self.n = n
        self.p = np.full((n, USKO_RUUTUJA), 1.0 / USKO_RUUTUJA)

    def nollaa(self, maski) -> None:
        self.p[maski] = 1.0 / USKO_RUUTUJA

    # Lukon mittoja ei tiedeta, joten niita ei oleteta. Uskottavuus lasketaan
    # usealla mahdollisella lukolla ja keskiarvoistetaan - muuten kapea lukko
    # tulkittaisiin leveana ja uskomus sulkisi pois alueita joissa aukko oikeasti
    # on. Juuri se tappoi vaikeimmat tasot.
    HYPOTEESIT = (
        (0.160, 0.037, 300.0),
        (0.110, 0.024, 300.0),
        (0.080, 0.014, 300.0),
        (0.062, 0.008, 300.0),
        (0.050, 0.005, 300.0),
    )

    def paivita(self, paikka, havaittu, pito_ms, kohina=0.06) -> None:
        """Bayes-paivitys yhdesta painalluksesta.

        Jokaiselle mahdolliselle aukon paikalle lasketaan mita SIINA
        tapauksessa olisi pitanyt nakya - jokaisella lukkohypoteesilla -
        ja verrataan siihen mita nakyi.
        """
        d = np.abs(self.KESKUS[None, :] - np.asarray(paikka)[:, None])
        h = np.asarray(pito_ms)[:, None]
        hav = np.asarray(havaittu)[:, None]
        usk = np.zeros_like(self.p)
        for ramp, targ, tau in self.HYPOTEESIT:
            katto = np.clip((ramp - d) / max(1e-6, ramp - targ), 0.0, 1.0)
            katto = np.where(d <= targ, 1.0, katto)
            odotus = katto * pito_osuus(h, tau)
            usk += np.exp(-0.5 * ((odotus - hav) / kohina) ** 2)
        self.p *= usk / len(self.HYPOTEESIT) + 1e-9
        self.p /= np.maximum(1e-300, self.p.sum(axis=1, keepdims=True))

    def paras(self):
        return self.KESKUS[np.argmax(self.p, axis=1)]

    def entropia(self):
        p = np.maximum(self.p, 1e-300)
        return -(p * np.log(p)).sum(axis=1) / np.log(USKO_RUUTUJA)

    def nakyma(self, paikka):
        """Egosentrinen pala uskomuksesta: mita on nykyisen paikan ymparilla."""
        reunat = np.linspace(-USKO_KANTAMA, USKO_KANTAMA, USKO_NAKYY + 1)
        ulos = np.zeros((self.n, USKO_NAKYY))
        suht = self.KESKUS[None, :] - np.asarray(paikka)[:, None]
        idx = np.clip(np.searchsorted(reunat, suht.ravel()) - 1, 0, USKO_NAKYY - 1)
        idx = idx.reshape(suht.shape)
        kelpaa = (suht >= -USKO_KANTAMA) & (suht <= USKO_KANTAMA)
        rivit = np.repeat(np.arange(self.n), USKO_RUUTUJA).reshape(suht.shape)
        np.add.at(ulos, (rivit[kelpaa], idx[kelpaa]), self.p[kelpaa])
        return ulos


# --- lukkotasot ------------------------------------------------------------
# Raportointia varten, samaan tapaan kuin L0-L4. Kapein target on 0.4% koko
# janasta: siina aukko on kirjaimellisesti yhden pikselin levyinen palkissa.
TASOT = [
    ("L0 helppo",       0.130, 0.180, 0.030, 0.045),
    ("L1 keski",        0.090, 0.130, 0.018, 0.030),
    ("L2 vaikea",       0.070, 0.090, 0.010, 0.018),
    ("L3 vaikeampi",    0.055, 0.070, 0.006, 0.010),
    ("L4 vaikein",      0.045, 0.055, 0.004, 0.006),
]


class Lukot:
    """N lukkoa rinnakkain. Yksi askel = siirry ja paina F valitun ajan."""

    # aikakustannukset, mitattu tassa projektissa oikeasta pelista
    AVAUS = 0.92               # nain pitkalle kattoa kohti = 90 astetta = auki
    SIIRTO_MS = 25.0

    def __init__(self, n: int, rng: np.random.Generator, taso: int = None,
                 vaikeus: float = 1.0):
        self.n = n
        self.rng = rng
        self.taso = taso
        self.vaikeus = vaikeus
        self.usko = Usko(n)
        for nimi in ("aukko", "ramppi", "target", "tau", "kohina", "budjetti",
                     "paikka", "kaanto", "aika", "paras_kaanto", "askelia",
                     "viime_havainto", "viime_pito", "luku_ms"):
            setattr(self, nimi, np.zeros(n))
        self.uusi(np.ones(n, dtype=bool))

    def uusi(self, maski) -> None:
        m = int(maski.sum())
        if m == 0:
            return
        r = self.rng
        if self.taso is not None:
            _nimi, rlo, rhi, tlo, thi = TASOT[self.taso]
        else:
            # Vaikeus liu'uttaa alarajaa: aluksi vain leveita aukkoja, sitten
            # kapeimmat mukaan. Suoraan kapeimmilla ei opi mitaan, koska
            # osumia tulee liian harvoin nakeakseen mika toimi.
            v = float(np.clip(self.vaikeus, 0.0, 1.0))
            rlo = 0.130 * (1 - v) + 0.045 * v
            rhi = 0.180
            tlo = 0.030 * (1 - v) + 0.004 * v
            thi = 0.045
        ramppi = np.exp(r.uniform(np.log(rlo), np.log(rhi), m))
        target = np.exp(r.uniform(np.log(tlo), np.log(thi), m))
        target = np.minimum(target, ramppi * 0.55)

        self.aukko[maski] = r.uniform(0.02, 0.98, m)
        self.ramppi[maski] = ramppi
        self.target[maski] = target
        # Kuinka nopeasti pesa kaantyy kohti kattoaan. Pisimman painalluksen
        # (1900 ms) on yletettava avautumiseen kaikilla tau:n arvoilla, muuten
        # osa lukoista olisi mahdottomia eika sita huomaisi mistaan.
        self.tau[maski] = r.uniform(180.0, 430.0, m)
        self.kohina[maski] = r.uniform(0.010, 0.045, m)
        # Kauanko painalluksen jalkeen kestaa etta lukema on luettavissa.
        # Tata ei tiedeta tarkasti, joten se arvotaan sekin.
        self.luku_ms[maski] = r.uniform(60.0, 180.0, m)
        self.budjetti[maski] = r.uniform(2.6, 4.2, m) * 1000.0
        self.paikka[maski] = r.uniform(0.0, 1.0, m)
        self.kaanto[maski] = 0.0
        self.aika[maski] = 0.0
        self.paras_kaanto[maski] = 0.0
        self.askelia[maski] = 0
        self.viime_havainto[maski] = 0.0
        self.viime_pito[maski] = 0.0
        self.usko.nollaa(maski)

    # ---- havainto ---------------------------------------------------------

    def havainto(self) -> np.ndarray:
        u = self.usko.nakyma(self.paikka)
        ent = self.usko.entropia()
        paras = self.usko.paras()
        jaljella = np.clip(1.0 - self.aika / self.budjetti, 0.0, 1.0)
        skalaarit = np.stack([
            self.paikka,
            1.0 - self.paikka,
            self.viime_havainto,
            self.viime_pito / 1500.0,
            ent,
            np.clip(paras - self.paikka, -1.0, 1.0),
            np.abs(paras - self.paikka),
            jaljella,
            self.paras_kaanto,
            np.clip(self.askelia / 20.0, 0.0, 1.5),
        ], axis=1)
        return np.concatenate([u * USKO_NAKYY, skalaarit], axis=1)

    # ---- askel ------------------------------------------------------------

    def askel(self, siirto_i: np.ndarray, pito_i: np.ndarray):
        pito = PIDOT_MS[pito_i]
        vanha_ent = self.usko.entropia()

        uskoon = siirto_i >= USKOON
        siirto = np.where(uskoon, self.usko.paras() - self.paikka,
                          SIIRROT[np.minimum(siirto_i, USKOON - 1)])
        self.paikka = np.clip(self.paikka + siirto, 0.0, 1.0)
        matka_ms = np.abs(siirto) * 120.0
        askel_ms = self.SIIRTO_MS + matka_ms + pito + self.luku_ms
        self.aika += askel_ms

        d = np.abs(self.paikka - self.aukko)
        katto = np.clip((self.ramppi - d) / np.maximum(1e-6, self.ramppi - self.target), 0.0, 1.0)
        katto = np.where(d <= self.target, 1.0, katto)
        kaanto = katto * pito_osuus(pito, self.tau)
        auki = (d <= self.target) & (kaanto >= self.AVAUS)

        havaittu = np.clip(kaanto + self.rng.normal(0.0, 1.0, self.n) * self.kohina, 0.0, 1.0)
        self.kaanto = kaanto
        self.paras_kaanto = np.maximum(self.paras_kaanto, havaittu)
        self.viime_havainto = havaittu
        self.viime_pito = pito
        self.askelia += 1

        # Uskomus paivitetaan sillä mita lukosta VOI tietaa, ei sen todellisilla
        # arvoilla: rampin ja targetin leveys ovat arvioita, kuten pelissakin.
        self.usko.paivita(self.paikka, havaittu, pito, kohina=0.06)

        loppu = auki | (self.aika >= self.budjetti)

        # Palkkio: avaaminen ratkaisee, aika maksaa, ja tiedon lisays
        # palkitaan jotta oppiminen ei nojaa pelkkaan sattumaan.
        tieto = np.clip(vanha_ent - self.usko.entropia(), 0.0, None)
        palkkio = (60.0 * auki
                   - 1.2 * askel_ms / 1000.0
                   + 6.0 * tieto
                   + 1.5 * np.maximum(0.0, havaittu - 0.5))
        return self.havainto(), palkkio, loppu, auki
