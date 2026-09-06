"""Tunnistuksen regressiotestit oikeilla pelikuvilla: python test_vision.py

Kuvat references/-kansiossa ovat SCUMin omia ruutukaappauksia 1920x1080.
Ne ovat ainoa tapa varmistaa taalla, etta Detector lukee oikeita arvoja
oikeasta pelikuvasta eika vain synteettisesta testikuviosta.

Vaatii numpyn ja Pillowin. Live-ajossa Pillowia ei tarvita.
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

REFERENCES = os.path.join(HERE, "references")
FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if condition else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
    if not condition:
        FAILURES.append(name)


def load_bgr(np, path, size=None):
    from PIL import Image

    image = Image.open(path).convert("RGB")
    if size:
        image = image.resize(size, Image.LANCZOS)
    return np.asarray(image)[:, :, ::-1].copy()      # RGB -> BGR kuten mss


def observe(np, Detector, VisionConfig, frame, width, height):
    client = {"left": 0, "top": 0, "width": width, "height": height}
    detector = Detector(np, VisionConfig())
    box = detector.roi_box(client)
    roi = frame[box["top"]:box["top"] + box["height"],
                box["left"]:box["left"] + box["width"]]
    return detector.read(roi, client, 0.0), detector


def main() -> int:
    try:
        import numpy as np
    except ImportError:
        print("numpy puuttuu: pip install numpy pillow")
        return 2
    try:
        import PIL  # noqa: F401
    except ImportError:
        print("Pillow puuttuu: pip install pillow")
        return 2

    from autolockpick_live import Detector, VisionConfig

    if not os.path.isdir(REFERENCES):
        print(f"Kuvakansiota ei loydy: {REFERENCES}")
        return 2

    # Mitattava suure on lukkopesan kaanto. Tiirikkaa ei tunnisteta lainkaan,
    # joten sen asennolle ei ole odotusarvoja - vain vaatimus, ettei se saa
    # vaikuttaa kaannon lukemaan.
    print("Oikeat pelikuvat 1920x1080")
    expectations = [
        ("Lockpickstart.png", "aloitusruutu, pesa suorassa", lambda o: abs(o.turn) < 8),
        ("MaxSideLeft.png", "pesa suorassa", lambda o: abs(o.turn) < 8),
        ("MaxSideRight.png", "pesa suorassa", lambda o: abs(o.turn) < 8),
        ("Lockpicking.png", "pesa kaantyneena", lambda o: o.turn > 10),
    ]
    readings = {}
    for name, label, rule in expectations:
        path = os.path.join(REFERENCES, name)
        if not os.path.exists(path):
            check(f"{name} loytyy", False)
            continue
        frame = load_bgr(np, path)
        obs, detector = observe(np, Detector, VisionConfig, frame, 1920, 1080)
        readings[name] = obs
        check(f"{name}: tunnistus onnistuu", obs.ok,
              f"metal={detector.debug.get('metal')} reika={detector.debug.get('keyhole')}")
        check(f"{name}: {label}", obs.ok and rule(obs),
              f"kaanto {obs.turn:+.1f} deg")
    print()

    # Tama on koko uuden rakenteen ehto: MaxSideLeft ja MaxSideRight ovat
    # samasta lukosta, tiirikka aarilaidoissa mutta pesa molemmissa suorassa.
    # Jos tiirikan asento vuotaisi kaannon lukemaan, luvut eroaisivat.
    print("Tiirikan asento ei saa vaikuttaa kaannon lukemaan")
    left = readings.get("MaxSideLeft.png")
    right = readings.get("MaxSideRight.png")
    if left and right:
        check("vasen ja oikea aariasento antavat saman kaannon",
              abs(left.turn - right.turn) < 4.0,
              f"{left.turn:+.1f} vs {right.turn:+.1f} deg")
        check("molemmat lukevat pesan suoraksi",
              abs(left.turn) < 8 and abs(right.turn) < 8,
              f"{left.turn:+.1f} / {right.turn:+.1f} deg")
    print()

    print("Sama tulos muilla resoluutioilla")
    base = readings.get("Lockpicking.png")
    for width, height in [(1280, 720), (2560, 1440), (1600, 900)]:
        frame = load_bgr(np, os.path.join(REFERENCES, "Lockpicking.png"), (width, height))
        obs, _ = observe(np, Detector, VisionConfig, frame, width, height)
        ok = obs.ok and base and abs(obs.turn - base.turn) < 5
        check(f"{width}x{height}", bool(ok),
              f"kaanto {obs.turn:+.1f} deg (1080p: {base.turn:+.1f})" if obs.ok
              else "ei tunnistusta")
    print()

    print("Vaarat ruudut hylataan")
    blank = np.zeros((648, 648, 3), dtype=np.uint8)
    client = {"left": 0, "top": 0, "width": 1920, "height": 1080}
    obs = Detector(np, VisionConfig()).read(blank, client, 0.0)
    check("musta ruutu", not obs.ok)

    grey = np.full((648, 648, 3), 130, dtype=np.uint8)
    obs = Detector(np, VisionConfig()).read(grey, client, 0.0)
    check("tasainen harmaa ruutu", not obs.ok)

    rng = np.random.default_rng(7)
    noise = rng.integers(0, 255, (648, 648, 3), dtype=np.uint8)
    obs = Detector(np, VisionConfig()).read(noise, client, 0.0)
    check("satunnaiskohina", not obs.ok)

    # Pelikuva ilman lukkoa: otetaan ruudun kulmasta.
    frame = load_bgr(np, os.path.join(REFERENCES, "Lockpicking.png"))
    corner = frame[0:648, 0:648]
    obs = Detector(np, VisionConfig()).read(corner, client, 0.0)
    check("pelikuvan kulma ilman lukkoa", not obs.ok)
    print()

    print("Ajastimen kaynnissaolo kaaresta")
    from autolockpick_live import timer_running

    full = [(t * 0.05, 1.0) for t in range(12)]
    check("taysi liikkumaton kaari = ei kay", not timer_running(full, 0.04))

    shrinking = [(t * 0.05, 1.0 - t * 0.03) for t in range(12)]
    check("kutistuva kaari = kay", timer_running(shrinking, 0.04))

    check("liian lyhyt historia ei riita", not timer_running(shrinking[:3], 0.04))

    jitter = [(t * 0.05, 1.0 + (0.01 if t % 2 else -0.01)) for t in range(12)]
    check("pieni varina ei tulkita kaynniksi", not timer_running(jitter, 0.04))
    print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki tunnistustestit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
