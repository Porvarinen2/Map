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
    n, sis, piilo, toim = 7, 9, 11, 5
    v = V.Verkko(sis, piilo, toim, siemen=1)
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
    print("\n2) Politiikan perusasiat")
    v = V.Verkko(4, 8, 3, siemen=2)
    x = np.random.default_rng(0).standard_normal((100, 4))
    logp = V.Verkko.log_softmax(v.eteen(x)[0])
    vaita(np.allclose(np.exp(logp).sum(1), 1.0), "todennakoisyydet summautuvat ykkoseen")
    rng = np.random.default_rng(3)
    a, lp, _ = v.valitse(x, rng)
    vaita(a.min() >= 0 and a.max() < 3, "valitut toiminnot ovat sallitulla valilla")
    vaita(np.allclose(lp, logp[np.arange(100), a]), "palautettu log-todennakoisyys vastaa valintaa")
    # alussa politiikan pitaa olla lahes tasainen, muuten se lukkiutuu heti
    H = -(np.exp(logp) * logp).sum(1).mean()
    vaita(H > 0.99 * np.log(3), f"alussa politiikka on lahes tasainen (entropia {H:.3f}/{np.log(3):.3f})")


def testi_gae():
    print("\n3) GAE")
    palkkiot = np.array([0.0, 0.0, 1.0])
    arvot = np.array([0.0, 0.0, 0.0, 0.0])
    lopetus = np.array([0.0, 0.0, 1.0])
    etu, kohde = V.gae(palkkiot, arvot, lopetus, gamma=0.9, lam=1.0)
    vaita(np.allclose(etu, [0.81, 0.9, 1.0]), f"diskontattu palkkio kulkeutuu taaksepain {etu}")
    vaita(np.allclose(kohde, etu), "arvokohde = etu + arvo")


def testi_oppii_leluongelman():
    print("\n4) Oppiiko se oikeasti? (lelutehtava jonka oikea vastaus tiedetaan)")
    # Tila = yksi luku. Oikea toiminto: 0 jos luku < 0, muuten 1.
    rng = np.random.default_rng(7)
    v = V.Verkko(1, 32, 2, siemen=5)
    adam = V.Adam(v.p, lr=3e-3)
    osuma_alussa = None
    for kierros in range(60):
        x = rng.uniform(-1, 1, (512, 1))
        a, logp, arvo = v.valitse(x, rng)
        oikein = (x[:, 0] > 0).astype(int)
        palkkio = (a == oikein).astype(float)
        if osuma_alussa is None:
            osuma_alussa = palkkio.mean()
        etu = palkkio - palkkio.mean()
        V.ppo_paivitys(v, adam, x, a, logp, etu, palkkio, rng, kierroksia=2, era=128)
    x = rng.uniform(-1, 1, (2000, 1))
    a, _, _ = v.valitse(x, rng, ahne=True)
    osuma = (a == (x[:, 0] > 0).astype(int)).mean()
    print(f"        osumatarkkuus {osuma_alussa:.2f} -> {osuma:.2f}")
    vaita(osuma > 0.97, f"verkko oppi lelutehtavan ({osuma:.3f})")


def testi_siirto():
    """Rakentaako pelaa.py havainnon samoin kuin opetus?

    Ajetaan OIKEA Pelaaja.yritys() valesilman ja valekaden lapi, ja ne
    puhuvat OIKEALLE peli.Lukot-fysiikalle. Jos havainto rakentuisi eri
    tavalla kuin opetuksessa, tulos romahtaisi tassa.
    """
    print("\n5) Siirtyyko opittu politiikka live-koodipolulle?")
    import peli
    import pelaa as P
    from pathlib import Path
    polku = Path(__file__).resolve().parent / "politiikka.npz"
    if not polku.exists():
        vaita(False, "politiikka.npz puuttuu - aja ensin treeni.py")
        return

    kello = [0.0]

    class ValeSilma:
        def __init__(self, lukko, kello):
            self.lukko, self.kello, self.auki = lukko, kello, False
        def lue(self):
            self.kello[0] += 0.002          # ruudunluku maksaa aikaa, kuten oikeasti
            return S_Kuva(True, float(self.lukko.kaanto[0]), self.lukko.kaanto[0]*90,
                          True, bool(self.auki))
        def nollaa(self): pass

    class ValeKasi:
        def __init__(self, lukko): self.lukko = lukko
        def siirra(self, yksikkoa):
            kello[0] += 0.01
            self.lukko.siirra(self.lukko.paikka + yksikkoa / P.JANA)
        def napauta(self, vk, ms):
            kello[0] += ms / 1000.0
            if vk == P.F:
                _o, _p, _l, auki = self.lukko.napauta()
                self.silma.auki = bool(auki[0])
        def nappi(self, vk, alas): pass
        def pohjassa(self, vk): return False

    import silma as SIL
    global S_Kuva
    S_Kuva = SIL.Kuva

    v = V.Verkko(peli.HAVAINTO, 128, peli.TOIMINTOJA)
    v.lataa(polku)
    rng = np.random.default_rng(4)
    oikea_monot, oikea_sleep = __import__("time").monotonic, __import__("time").sleep
    import time as _t
    _t.monotonic = lambda: kello[0]
    _t.sleep = lambda x: kello.__setitem__(0, kello[0] + x)
    auki = 0
    N = 60
    try:
        for _ in range(N):
            lukko = peli.Lukot(1, rng)
            silma, kasi = ValeSilma(lukko, kello), ValeKasi(lukko)
            kasi.silma = silma
            p = P.Pelaaja(v, silma, kasi)
            p.viive = 80.0
            kello[0] += 10.0
            import builtins
            vanha_print = builtins.print
            builtins.print = lambda *a, **k: None
            try:
                ok, _n = p.yritys()
            finally:
                builtins.print = vanha_print
            auki += ok
    finally:
        _t.monotonic, _t.sleep = oikea_monot, oikea_sleep
    osuus = auki / N
    print(f"        live-koodipolku avaa {100*osuus:.1f}% samasta fysiikasta")
    vaita(osuus > 0.30, f"opittu politiikka siirtyy live-polulle ({100*osuus:.1f}%)")


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
