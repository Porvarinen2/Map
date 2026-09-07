"""Testit: python testit.py

Kaksi asiaa tarkistetaan:

  1. RUUDUNLUKU pelin omista kuvakaappauksista (kuvat/). Ainoa asia, joka
     tunnistuksen on saatava oikein, on lukkopesan kaanto.

  2. OHJAIMEN KUVIO: tap, tap, tap, taap, taaaap. Ei onnistumisprosentteja
     vaan se, tekeeko ohjain sen mita sen pitaa tehda.

Vaatii numpyn ja Pillowin:  pip install numpy pillow
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lockpick import Havainto, Ohjain, Saadot, Silma  # noqa: E402

KUVAT = os.path.join(HERE, "kuvat")
VIRHEET: list[str] = []


def tark(nimi: str, ok: bool, lisa: str = "") -> None:
    print(f"  {'OK  ' if ok else 'EI  '}  {nimi}" + (f"   {lisa}" if lisa else ""))
    if not ok:
        VIRHEET.append(nimi)


def lue_kuva(np, polku: str):
    from PIL import Image
    return np.asarray(Image.open(polku).convert("RGB"))[:, :, ::-1].copy()


def katso(np, polku: str, s: Saadot):
    """Lukee kuvan samoin kuin pelissa.

    Kuvat ovat kahta lajia: koko ruudun kaappauksia (1920x1080) ja pienia
    rajauksia lukon ymparilta. Molemmat luetaan samalla koodilla, koska
    rajaus on jo valmiiksi lukon keskella.
    """
    ikkuna = {"left": 0, "top": 0, "width": 1920, "height": 1080}
    silma = Silma(np, s)
    kuva = lue_kuva(np, polku)
    if kuva.shape[1] > 700:
        b = silma.alue(ikkuna)
        kuva = kuva[b["top"]:b["top"] + b["height"], b["left"]:b["left"] + b["width"]]
    return silma.lue(kuva, ikkuna)


# --------------------------------------------------------------------------
#  1. RUUDUNLUKU
# --------------------------------------------------------------------------


def testaa_ruudunluku(np) -> None:
    s = Saadot()
    print("Ruudunluku pelin omista kuvista")

    lepo = {}
    for nimi in ("Lockpickstart.png", "MaxSideLeft.png", "MaxSideRight.png"):
        h = katso(np, os.path.join(KUVAT, nimi), s)
        lepo[nimi] = h
        tark(f"{nimi}: lukko tunnistuu", h.ok)
        tark(f"{nimi}: pesa on lepoasennossa", h.ok and abs(h.kaanto) < 8.0,
             f"{h.kaanto:.2f} deg")

    # Tiirikka on naissa kahdessa aarilaidoissa. Jos sen asento vuotaisi
    # kaannon lukemaan, nama eroaisivat selvasti.
    vasen = lepo["MaxSideLeft.png"]
    oikea = lepo["MaxSideRight.png"]
    tark("tiirikan asento ei vuoda kaannon lukemaan",
         vasen.ok and oikea.ok and abs(vasen.kaanto - oikea.kaanto) < 2.0,
         f"vasen {vasen.kaanto:.2f} vs oikea {oikea.kaanto:.2f} deg")

    kesken = katso(np, os.path.join(KUVAT, "Lockpicking.png"), s)
    tark("kesken olevassa yrityksessa pesa on kaantynyt",
         kesken.ok and kesken.kaanto > 8.0, f"{kesken.kaanto:.2f} deg")

    tark("aloitusruudussa yritys ei ole kaynnissa",
         not lepo["Lockpickstart.png"].kaynnissa,
         f"aikakaari {lepo['Lockpickstart.png'].kaari} pikselia")
    tark("kesken olevassa yritys on kaynnissa", kesken.kaynnissa,
         f"aikakaari {kesken.kaari} pikselia")
    print()

    print("Auennut lukko luetaan noin 90 asteeksi")
    kansio = os.path.join(KUVAT, "success_angles")
    for nimi in sorted(os.listdir(kansio)):
        h = katso(np, os.path.join(kansio, nimi), s)
        tark(f"{nimi}: noin 90 deg", h.ok and 85.0 <= h.kaanto <= 95.0,
             f"{h.kaanto:.2f} deg")
    print()

    print("Kaikki lukkotyypit tunnistuvat lepoasennossa")
    kansio = os.path.join(KUVAT, "Locktypes")
    for nimi in sorted(os.listdir(kansio)):
        h = katso(np, os.path.join(kansio, nimi), s)
        tark(f"{nimi}: lepokulma lahella nollaa", h.ok and abs(h.kaanto) < 8.0,
             f"{h.kaanto:.2f} deg")
    print()


# --------------------------------------------------------------------------
#  2. OHJAIN
# --------------------------------------------------------------------------


def havainto(kaanto: float) -> Havainto:
    return Havainto(ok=True, kaanto=kaanto, kaynnissa=True, kaari=5000, reika=1200)


def aja_sarja(o: Ohjain, kaannot, dt=0.005, alku=0.0):
    """Syottaa kulmasarjan. Palauttaa (painallukset ms, liikkeet)."""
    t = alku
    painallukset, liikkeet = [], []
    alkoi = None
    for kaanto in kaannot:
        k = o.paivita(t, havainto(kaanto))
        if k.hiiri:
            liikkeet.append(k.hiiri)
        if k.f and alkoi is None:
            alkoi = t
        elif not k.f and alkoi is not None:
            painallukset.append((t - alkoi) * 1000.0)
            alkoi = None
        t += dt
    if alkoi is not None:
        painallukset.append((t - alkoi) * 1000.0)
    return painallukset, liikkeet


def skannaava(s: Saadot) -> Ohjain:
    o = Ohjain(s)
    o.vaihe = o.SKANNAUS          # ohitetaan alkuun-ajo
    return o


def testaa_ohjain() -> None:
    s = Saadot()

    print("Skannaus: tap, tap, tap - kaikki samanlaisia")
    o = skannaava(s)
    painallukset, liikkeet = aja_sarja(o, [0.5] * 400)
    kesket = painallukset[:-1]
    tark("napautuksia tuli useita", len(kesket) >= 5, f"{len(kesket)} kpl")
    tark("kaikki napautukset samanmittaisia",
         bool(kesket) and max(kesket) - min(kesket) <= 10.0,
         f"{min(kesket):.0f} - {max(kesket):.0f} ms")
    tark("napautus on lyhyt", bool(kesket) and max(kesket) <= s.tap_ms + 15.0,
         f"{max(kesket):.0f} ms (asetus {s.tap_ms:.0f} ms)")
    koot = {round(u) for u in liikkeet}
    tark("hiiri liikkuu aina yhta paljon", len(koot) == 1, f"{koot} yksikkoa")
    tark("askel on pieni", max(abs(u) for u in liikkeet) <= 150.0,
         f"{max(abs(u) for u in liikkeet):.0f} u")
    tark("liike kulkee vain oikealle", all(u > 0 for u in liikkeet),
         f"{len(liikkeet)} askelta")
    print()

    print("Lukkopesan kaanto vie ramppiin")
    o = skannaava(s)
    aja_sarja(o, [0.5] * 40)
    o.paivita(1.0, havainto(0.5 + s.ramppi_astetta - 1.0))
    tark("pieni tarahdys ei riita", o.vaihe == o.SKANNAUS, o.vaihe)

    o = skannaava(s)
    aja_sarja(o, [0.5] * 40)
    k = o.paivita(1.0, havainto(0.5 + s.ramppi_astetta + 1.0))
    tark("kunnon kaanto vie ramppiin", o.vaihe == o.RAMPPI, o.vaihe)
    tark("F menee pohjaan", k.f, k.teksti)
    print()

    print("Rampissa painallus kestaa niin kauan kuin pesa kaantyy")
    o = skannaava(s)
    aja_sarja(o, [0.5] * 40)
    o.paivita(1.0, havainto(10.0))
    nouseva = [min(80.0, 10.0 + i * 0.6) for i in range(120)]
    painallukset, liikkeet = aja_sarja(o, nouseva, alku=1.005)
    tark("nouseva kaanto ei katkaise painallusta",
         not painallukset or painallukset[0] >= 400.0,
         f"{painallukset[0]:.0f} ms" if painallukset else "jatkui loppuun")
    tark("kesken nousun ei nykita", not liikkeet, f"{len(liikkeet)} nykaysta")

    o = skannaava(s)
    aja_sarja(o, [0.5] * 40)
    o.paivita(1.0, havainto(10.0))
    painallukset, liikkeet = aja_sarja(o, [10.0] * 120, alku=1.005)
    raja = s.paino_min_ms + s.pysahtyi_ms + 40.0
    tark("pysahtynyt kaanto katkaisee painalluksen",
         bool(painallukset) and painallukset[0] <= raja,
         f"{painallukset[0]:.0f} ms" if painallukset else "ei katkennut")
    tark("pysahtymisen jalkeen nykaistaan oikealle",
         bool(liikkeet) and liikkeet[0] > 0,
         f"{liikkeet[0]:+.0f} u" if liikkeet else "ei nykaysta")
    tark("nykays on pieni",
         not liikkeet or abs(liikkeet[0]) <= s.nykays_yksikkoa,
         f"{abs(liikkeet[0]):.0f} u" if liikkeet else "")
    print()

    print("Maalissa F pysyy pohjassa")
    o = skannaava(s)
    aja_sarja(o, [0.5] * 40)
    o.paivita(1.0, havainto(10.0))
    painallukset, liikkeet = aja_sarja(o, [s.auki_astetta + 2.0] * 60, alku=1.005)
    tark("F ei irtoa maalikulmassa", len(painallukset) <= 1,
         f"{len(painallukset)} painallusta")
    tark("maalissa ei nykita", not liikkeet, f"{len(liikkeet)} nykaysta")
    print()

    print("Ilman lukkoa ei laheteta mitaan")
    o = Ohjain(s)
    k = o.paivita(0.0, Havainto())
    tark("hiiri ei liiku", k.hiiri == 0.0)
    tark("F ei mene pohjaan", k.f is False)
    print()


# --------------------------------------------------------------------------
#  3. KARTOITUS JA KARTTA
# --------------------------------------------------------------------------


def testaa_kartoitus() -> None:
    """Kartoitustila kavelee rampin yli ja mittaa sen leveyden."""
    import json
    import tempfile

    import lockpick as L

    s = Saadot()
    print("Kartoitus mittaa rampin leveyden")

    # Tekoramppi: kolmio jonka leveys tiedetaan. Katsotaan loytaako
    # mittaus sen takaisin.
    TODELLINEN = 400.0
    KESKUS = 800.0

    def kulma(paikka):
        etaisyys = abs(paikka - KESKUS)
        if etaisyys > TODELLINEN / 2.0:
            return 0.5
        return 4.0 + 70.0 * (1.0 - etaisyys / (TODELLINEN / 2.0))

    o = Ohjain(s, kartoita=True)
    o.vaihe = o.SKANNAUS
    t = 0.0
    for _ in range(6000):
        o.paivita(t, Havainto(ok=True, kaanto=kulma(o.paikka), kaynnissa=True,
                              reika=1200))
        t += 0.005
        if o.vaihe == o.SKANNAUS and o.mittaukset:
            break

    tark("ramppi mitattiin", len(o.mittaukset) >= 5,
         f"{len(o.mittaukset)} pistetta")
    leveys, target, huippu = L._leveydet(o.mittaukset, s.ramppi_astetta)
    tark("mitattu leveys osuu todelliseen",
         leveys is not None and abs(leveys - TODELLINEN) <= 2 * s.kartoitus_askel,
         f"mitattu {leveys:.0f} u, todellinen {TODELLINEN:.0f} u"
         if leveys else "ei mittausta")
    tark("huippu loytyi rampin keskelta", huippu >= 60.0, f"{huippu:.0f} deg")
    tark("kartoitus ei jaa pyorimaan", o.vaihe == o.SKANNAUS, o.vaihe)
    print()

    print("Kartta syntyy lokista")
    kansio = tempfile.mkdtemp()
    loki = os.path.join(kansio, "loki.jsonl")
    kartta = os.path.join(kansio, "kartta.html")
    with open(loki, "w", encoding="utf-8") as fh:
        for _ in range(6):
            fh.write(json.dumps({
                "laji": "profiili", "aika": "testi", "savy": -1.0,
                "kirkkaat": 0.025,
                "pisteet": [[d, kulma(KESKUS - TODELLINEN / 2.0 + d)]
                            for d in range(0, 500, 25)],
            }) + "\n")

    vanha_loki, vanha_kartta = L.LOKI, L.KARTTA
    try:
        L.LOKI, L.KARTTA = loki, kartta
        koodi = L.piirra_kartta(s)
    finally:
        L.LOKI, L.KARTTA = vanha_loki, vanha_kartta

    tark("kartta valmistui", koodi == 0)
    sivu = open(kartta, encoding="utf-8").read() if os.path.exists(kartta) else ""
    tark("sivu sisaltaa kuvaajan", "<svg" in sivu and "polyline" in sivu,
         f"{len(sivu)} merkkia")
    tark("sivu on itsenainen (ei verkkohakuja)",
         "http://" not in sivu and "https://" not in sivu)
    tark("lukkotyyppi tunnistettiin", "Basic" in sivu)
    print()


def testaa_lukkotyypit() -> None:
    """Varisavy erottaa lukkotyypit pelin omissa kuvissa."""
    import lockpick as L

    print("Lukkotyyppi tunnistuu varisavysta")
    for nimi, savy, kirkkaat in L.LUKKOTYYPIT:
        arvaus = L.tunnista_lukko(savy, kirkkaat)
        tark(f"{nimi}: omat tunnusluvut tunnistuvat", arvaus == nimi,
             f"savy {savy:+.1f} -> {arvaus}")
    print()


# --------------------------------------------------------------------------


def main() -> int:
    try:
        import numpy as np
        import PIL  # noqa: F401
    except ImportError:
        print("Puuttuu numpy tai Pillow:  pip install numpy pillow")
        return 2

    testaa_ruudunluku(np)
    testaa_ohjain()
    testaa_lukkotyypit()
    testaa_kartoitus()

    if VIRHEET:
        print(f"{len(VIRHEET)} testia epaonnistui: {', '.join(VIRHEET)}")
        return 1
    print("Kaikki testit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
