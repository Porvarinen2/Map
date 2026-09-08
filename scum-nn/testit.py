# -*- coding: utf-8 -*-
"""Tarkistaa etta verkko, gradientit, GAE ja ymparisto tekevat mita lupaavat."""
from __future__ import annotations

import numpy as np

import verkko as V

virheet = []


def vaita(ehto, teksti):
    print(f"  {'OK  ' if ehto else 'FAIL'}  {teksti}")
    if not ehto:
        virheet.append(teksti)


def testi_gradientit():
    print("\n1) Gradientit numeerista erotusta vasten")
    rng = np.random.default_rng(0)
    n, sis, piilo, toim = 7, 9, 11, 10
    v = V.Verkko(sis, piilo, [6, 4], siemen=1)
    x = rng.standard_normal((n, sis))
    # mielivaltainen skalaaritappio jonka derivaatat tiedetaan tarkasti
    A = rng.standard_normal((n, toim))
    B = rng.standard_normal(n)

    def tappio(p):
        vanha = {k: v.p[k] for k in v.p}
        for k in p:
            v.p[k] = p[k]
        logit, arvo, _ = v.eteen(x)
        L = float((A * logit).sum() + 0.5 * ((arvo - B) ** 2).sum())
        v.p.update(vanha)
        return L

    logit, arvo, vali = v.eteen(x)
    g = v.taakse(vali, A.copy(), (arvo - B).copy())

    pahin = 0.0
    for k in v.p:
        alku = v.p[k].copy()
        it = np.nditer(alku, flags=["multi_index"])
        tarkistettu = 0
        while not it.finished and tarkistettu < 12:
            i = it.multi_index
            h = 1e-6
            plus = {k: alku.copy()}; plus[k][i] += h
            miinus = {k: alku.copy()}; miinus[k][i] -= h
            num = (tappio(plus) - tappio(miinus)) / (2 * h)
            ana = g[k][i]
            suht = abs(num - ana) / max(1e-8, abs(num) + abs(ana))
            pahin = max(pahin, suht)
            tarkistettu += 1
            it.iternext()
    print(f"        pahin suhteellinen ero {pahin:.2e}")
    vaita(pahin < 1e-6, "kaikki gradientit vastaavat numeerista erotusta")


def testi_softmax():
    print("\n2) Politiikan perusasiat, kaksi paata")
    v = V.Verkko(4, 16, [13, 5], siemen=2)
    x = np.random.default_rng(0).standard_normal((200, 4))
    logp = v.log_softmax_paittain(v.eteen(x)[0])
    vaita(np.allclose(np.exp(logp[:, :13]).sum(1), 1.0), "siirtopaa summautuu ykkoseen")
    vaita(np.allclose(np.exp(logp[:, 13:]).sum(1), 1.0), "pitopaa summautuu ykkoseen")
    rng = np.random.default_rng(3)
    a, lp, _ = v.valitse(x, rng)
    vaita(a.shape == (200, 2), "molemmille paille tulee oma toiminto")
    oma = logp[np.arange(200), a[:, 0]] + logp[np.arange(200), 13 + a[:, 1]]
    vaita(np.allclose(oma, lp), "yhteis-logp on paiden summa")
    H = -(np.exp(logp[:, :13]) * logp[:, :13]).sum(1).mean()
    vaita(H > 0.99 * np.log(13), f"alussa siirtopaa on lahes tasainen ({H:.3f}/{np.log(13):.3f})")


def testi_gae():
    print("\n3) GAE")
    palkkiot = np.array([0.0, 0.0, 1.0])
    arvot = np.array([0.0, 0.0, 0.0, 0.0])
    lopetus = np.array([0.0, 0.0, 1.0])
    etu, kohde = V.gae(palkkiot, arvot, lopetus, gamma=0.9, lam=1.0)
    vaita(np.allclose(etu, [0.81, 0.9, 1.0]), f"diskontattu palkkio kulkeutuu taaksepain {etu}")
    vaita(np.allclose(kohde, etu), "arvokohde = etu + arvo")
    # sama vektoroituna kaikille ymparistoille
    R = np.random.default_rng(0).standard_normal((20, 6))
    A = np.random.default_rng(1).standard_normal((21, 6))
    D = (np.random.default_rng(2).random((20, 6)) < 0.2).astype(float)
    e, k = V.gae(R, A, D)
    ok = all(np.allclose(e[:, i], V.gae(R[:, i], A[:, i], D[:, i])[0]) for i in range(6))
    vaita(ok, "vektoroitu GAE vastaa yhta jonoa kerrallaan")


def testi_oppii_leluongelman():
    print("\n4) Oppiiko se oikeasti? (lelutehtava jonka oikea vastaus tiedetaan)")
    # Kaksi syotetta, kaksi paata: paa 1 katsoo ensimmaista, paa 2 toista.
    # Molemmat on opittava yhtaikaa jaetusta palkkiosta, kuten lukkopelissa
    # siirto ja pito.
    rng = np.random.default_rng(7)
    v = V.Verkko(2, 48, [2, 3], siemen=5)
    adam = V.Adam(v.p, lr=4e-3)
    def oikeat(x):
        return (x[:, 0] > 0).astype(int), np.digitize(x[:, 1], [-0.33, 0.33])
    for _ in range(120):
        x = rng.uniform(-1, 1, (768, 2))
        a, logp, _arvo = v.valitse(x, rng)
        o1, o2 = oikeat(x)
        palkkio = ((a[:, 0] == o1).astype(float) + (a[:, 1] == o2).astype(float)) / 2.0
        V.ppo_paivitys(v, adam, x, a, logp, palkkio - palkkio.mean(), palkkio, rng,
                       kierroksia=2, era=768)
    x = rng.uniform(-1, 1, (3000, 2))
    a, _, _ = v.valitse(x, rng, ahne=True)
    o1, o2 = oikeat(x)
    t1, t2 = (a[:, 0] == o1).mean(), (a[:, 1] == o2).mean()
    print(f"        paa 1 {t1:.2f} (arvaus 0.50)   paa 2 {t2:.2f} (arvaus 0.33)")
    vaita(t1 > 0.95 and t2 > 0.90, f"molemmat paat oppivat ({t1:.2f}, {t2:.2f})")


def testi_siirto():
    """Rakentaako pelaa.py havainnon samoin kuin opetus?

    Ajetaan OIKEA Pelaaja.yritys() valesilman ja valekaden lapi, ja ne
    puhuvat OIKEALLE peli.Lukot-fysiikalle. Jos havainto rakentuisi eri
    tavalla kuin opetuksessa, tulos romahtaisi tassa.
    """
    print("\n5) Siirtyyko opittu politiikka live-koodipolulle?")
    from pathlib import Path
    import peli
    import pelaa as P
    import silma as SIL
    import treeni
    polku = Path(__file__).resolve().parent / "politiikka.npz"
    if not polku.exists():
        vaita(False, "politiikka.npz puuttuu - aja ensin treeni.py")
        return

    kello = [0.0]

    class ValeSilma:
        def __init__(self, lukko):
            self.lukko, self.auki, self.nyt = lukko, False, 0.0
        def lue(self):
            kello[0] += 0.002
            return SIL.Kuva(True, float(self.nyt), self.nyt * 90, True, bool(self.auki))
        def nollaa(self):
            pass

    class ValeKasi:
        def __init__(self, lukko):
            self.lukko = lukko
            self.pito_alkoi = None
        def siirra(self, yksikkoa):
            kello[0] += 0.02
            self.lukko.paikka = np.clip(self.lukko.paikka + yksikkoa / P.JANA, 0.0, 1.0)
        def nappi(self, vk, alas):
            if vk != P.F:
                return
            if alas:
                self.pito_alkoi = kello[0]
            elif self.pito_alkoi is not None:
                pito = (kello[0] - self.pito_alkoi) * 1000.0
                d = np.abs(self.lukko.paikka - self.lukko.aukko)
                katto = np.clip((self.lukko.ramppi - d)
                                / np.maximum(1e-6, self.lukko.ramppi - self.lukko.target), 0, 1)
                katto = np.where(d <= self.lukko.target, 1.0, katto)
                k = katto * peli.pito_osuus(pito, self.lukko.tau)
                self.silma.nyt = float(k[0])
                self.silma.auki = bool((d <= self.lukko.target)[0] and k[0] >= peli.Lukot.AVAUS)
                self.pito_alkoi = None
        def napauta(self, vk, ms):
            kello[0] += ms / 1000.0
        def pohjassa(self, vk):
            return False

    d = np.load(polku)
    v = V.Verkko(peli.HAVAINTO, d["W1"].shape[1], [peli.SIIRTOJA, peli.PITOJA])
    v.lataa(polku)
    rng = np.random.default_rng(4)
    import time as _t
    oikea_m, oikea_s = _t.monotonic, _t.sleep
    _t.monotonic = lambda: kello[0]
    _t.sleep = lambda x: kello.__setitem__(0, kello[0] + x)
    auki = 0
    N = 250
    try:
        import builtins
        vanha_print = builtins.print
        for _ in range(N):
            lukko = peli.Lukot(1, rng)
            silma, kasi = ValeSilma(lukko), ValeKasi(lukko)
            kasi.silma = silma
            p = P.Pelaaja(v, silma, kasi, budjetti_s=float(lukko.budjetti[0]) / 1000.0)
            kello[0] += 10.0
            builtins.print = lambda *a, **k: None
            try:
                ok, _n = p.yritys()
            finally:
                builtins.print = vanha_print
            auki += ok
    finally:
        _t.monotonic, _t.sleep = oikea_m, oikea_s
    osuus = auki / N
    oma = float(np.mean(treeni.arvioi_tasoittain(v, np.random.default_rng(4), 800)))
    print(f"        opetusymparistossa {100*oma:.1f}%, live-koodipolulla {100*osuus:.1f}%")
    vaita(osuus >= max(0.03, 0.6 * oma),
          f"live-polku yltaa opetustulokseen ({100*osuus:.1f}% vs {100*oma:.1f}%)")


def testi_nako():
    """Osuuko nako oikeisiin pelikuviin? Ilman tata kaikki muu on turhaa."""
    print("\n6) Nako referenssikuvia vasten")
    from pathlib import Path
    from PIL import Image
    import silma as SIL
    juuri = Path(__file__).resolve().parent
    kuvat = sorted((juuri / "kuvat").glob("*.jpg"))
    if not kuvat:
        vaita(False, "kuvat/ on tyhja")
        return
    s = SIL.Silma()
    oikein = 0
    for polku in kuvat:
        rgb = np.asarray(Image.open(polku).convert("RGB"))
        bgr = rgb[:, :, ::-1].copy()
        h, w = bgr.shape[:2]
        p = int(0.30 * h)
        cy = h // 2 + int(s.s.keskus_y * h)
        s.korkeus, s.koko = h, None
        s.nollaa()
        k = s.tulkitse(bgr[cy - p:cy + p, w // 2 - p:w // 2 + p])
        nimi = polku.name
        if nimi.startswith("success"):
            ok = k.auki
        elif nimi.startswith("levossa"):
            ok = k.ok and k.kaanto < 0.03
        else:
            ok = k.ok and k.kaanto > 0.30
        oikein += ok
        print(f"        {nimi:18s} {k.kulma:6.1f} astetta  kaanto {k.kaanto:.3f}  "
              f"{'OK' if ok else 'VIRHE'}")
    vaita(oikein == len(kuvat), f"kaikki {len(kuvat)} kuvaa oikein ({oikein}/{len(kuvat)})")


if __name__ == "__main__":
    print("=== VERKKO ===")
    testi_gradientit()
    testi_softmax()
    testi_gae()
    testi_oppii_leluongelman()
    testi_siirto()
    testi_nako()
    print("\n" + ("KAIKKI OK" if not virheet else f"{len(virheet)} VIRHETTA"))
    raise SystemExit(1 if virheet else 0)
