"""Toistaa oikean pelivideon kehykset: python test_gameplay.py

gameplay/-kansiossa on 47 kehysta SCUMin lockpick-minipelista 5 kuvaa
sekunnissa. Kehykset 1-45 ovat kaynnissa oleva yritys, joka paattyy lukon
avautumiseen; kehykset 46-47 ovat SUCCESS-ruutu.

Tama on paras validointi, joka ilman peliconetta on mahdollinen: tunnistus
ajetaan oikeaa pelikuvaa vasten, ja mitattu kaantosarja syotetaan samalle
ohjaimelle, joka ajaa pelia.

Vaatii numpyn ja Pillowin.
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

FRAMES = os.path.join(HERE, "gameplay")
FPS = 5.0
FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if condition else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
    if not condition:
        FAILURES.append(name)


def read_all(np, Detector, VisionConfig):
    from PIL import Image

    client = {"left": 0, "top": 0, "width": 1920, "height": 1080}
    detector = Detector(np, VisionConfig())
    box = detector.roi_box(client)
    out = []
    for index, name in enumerate(sorted(os.listdir(FRAMES))):
        frame = np.asarray(Image.open(os.path.join(FRAMES, name)).convert("RGB"))[:, :, ::-1]
        roi = frame[box["top"]:box["top"] + box["height"],
                    box["left"]:box["left"] + box["width"]].copy()
        out.append((name, detector.read(roi, client, index / FPS), dict(detector.debug)))
    return out


def main() -> int:
    try:
        import numpy as np
        import PIL  # noqa: F401
    except ImportError:
        print("Puuttuu numpy tai Pillow: pip install numpy pillow")
        return 2

    from autolockpick_live import Detector, VisionConfig
    from lockpick_control import ControlConfig, Controller, Observation

    if not os.path.isdir(FRAMES):
        print(f"Kehyskansiota ei loydy: {FRAMES}")
        return 2

    readings = read_all(np, Detector, VisionConfig)
    running = readings[:45]
    success = readings[45:]

    print(f"Tunnistus {len(readings)} oikeasta pelikehyksesta")
    check("kaikki yrityksen kehykset tunnistuvat",
          all(o.ok for _, o, _ in running),
          f"{sum(1 for _, o, _ in running if o.ok)}/{len(running)}")
    check("kaikki yrityksen kehykset tulkitaan kaynniksi",
          all(o.running for _, o, _ in running),
          f"{sum(1 for _, o, _ in running if o.running)}/{len(running)}")
    check("SUCCESS-ruutu ei ole kaynnissa oleva yritys",
          all(not o.ok or not o.running for _, o, _ in success),
          ", ".join(f"ok={o.ok} running={o.running}" for _, o, _ in success))
    print()

    turns = [o.turn for _, o, _ in running]
    scan, work = turns[:30], turns[30:]

    print("Mitattu kaantosarja")
    check("skannausvaihe pysyy lahella nollaa", max(scan) < 5.0,
          f"suurin {max(scan):.1f} deg 30 kehyksen aikana")
    check("levossa oleva pesa ei ylita rampin kynnysta",
          max(scan) < ControlConfig().ramp_degrees + 1.0,
          f"{max(scan):.1f} vs kynnys {ControlConfig().ramp_degrees:.1f} deg")
    check("tyovaihe nousee lahes taydelle kaannolle", max(work) > 85.0,
          f"suurin {max(work):.1f} deg")
    check("kaanto nousee portaittain eika hyppaa kerralla",
          sum(1 for a, b in zip(work, work[1:]) if b > a + 5) >= 5,
          f"{sum(1 for a, b in zip(work, work[1:]) if b > a + 5)} nousuaskelta")
    check("kaanto myos notkahtaa valilla (pelaaja naputtaa F:aa)",
          sum(1 for a, b in zip(work, work[1:]) if b < a - 5) >= 3,
          f"{sum(1 for a, b in zip(work, work[1:]) if b < a - 5) } notkahdusta")
    print()

    print("Aikakaari erottaa tilat")
    arcs = [d.get("timer", 0) for _, _, d in running]
    check("kaynnissa kaari on selvasti yli kynnyksen",
          min(arcs) > VisionConfig().running_arc_pixels,
          f"pienin {min(arcs)} > {VisionConfig().running_arc_pixels}")
    ref = os.path.join(HERE, "references", "Lockpickstart.png")
    if os.path.exists(ref):
        from PIL import Image
        client = {"left": 0, "top": 0, "width": 1920, "height": 1080}
        detector = Detector(np, VisionConfig())
        box = detector.roi_box(client)
        frame = np.asarray(Image.open(ref).convert("RGB"))[:, :, ::-1]
        roi = frame[box["top"]:box["top"] + box["height"],
                    box["left"]:box["left"] + box["width"]].copy()
        obs = detector.read(roi, client, 0.0)
        check("aloitusruutu ei ole kaynnissa", not obs.running,
              f"kaari {detector.debug.get('timer', 0)} pikselia")
    print()

    # Syotetaan mitattu kaantosarja ohjaimelle. Ohjain ei paase vaikuttamaan
    # lukkoon, mutta sen paatokset naista lukemista voi tarkistaa.
    print("Ohjain lukee saman sarjan oikein")
    cfg = ControlConfig()
    controller = Controller(cfg)
    controller.phase = controller.SCAN          # ohitetaan kotiinajo

    saw_ramp = held = 0
    for index, turn in enumerate(turns):
        action = controller.update(index / FPS, Observation(
            stamp=index / FPS, ok=True, turn=turn, running=True))
        if controller.planner.ramp_locked:
            saw_ramp = 1
        if action.f_down:
            held += 1

    check("ohjain tunnisti rampin", bool(saw_ramp),
          f"{len(controller.probes)} merkintaa")
    check("ohjain paatyi ramppivaiheeseen", controller.phase == controller.RAMP,
          controller.phase)
    check("kaantyvan lukon aikana F on pohjassa", held >= 0.5 * len(turns),
          f"{held}/{len(turns)} kehysta")
    print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki pelivideon testit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
