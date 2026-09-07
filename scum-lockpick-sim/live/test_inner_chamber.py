"""LIVE 1.4: user's pink rotation area + small-twitch guard regression."""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def load_bgr(np, path):
    from PIL import Image
    return np.asarray(Image.open(path).convert("RGB"))[:, :, ::-1].copy()


def observe(np, Detector, VisionConfig, frame):
    client = {"left": 0, "top": 0, "width": 1920, "height": 1080}
    detector = Detector(np, VisionConfig())
    box = detector.roi_box(client)
    roi = frame[
        box["top"]:box["top"] + box["height"],
        box["left"]:box["left"] + box["width"],
    ]
    obs = detector.read(roi, client, 0.0)
    return obs, detector


def main():
    import numpy as np
    from PIL import Image

    from autolockpick_live import Detector, VisionConfig
    from lockpick_control import (
        ControlConfig,
        Controller,
        Observation,
        SearchMemory,
    )

    refs = os.path.join(HERE, "references")
    rot = os.path.join(refs, "rotation_area")

    # Exact user-marked 1080p screen geometry.
    screen = load_bgr(
        np,
        os.path.join(rot, "Rotationarea-On-Screen.png"),
    )

    r = screen[:, :, 2]
    g = screen[:, :, 1]
    b = screen[:, :, 0]
    magenta = (
        (r > 200)
        & (b > 180)
        & (g < 120)
    )

    ys, xs = np.where(magenta)

    assert xs.min() == 831
    assert xs.max() == 1088
    assert ys.min() == 408
    assert ys.max() == 665

    cfg = VisionConfig()

    assert abs(cfg.rotation_area_radius_1080 - 128.5) < 0.1
    assert abs(cfg.rotation_center_offset_y_1080 - (-3.0)) < 0.1

    # Real game references.
    expected = {
        "Lockpickstart.png": (0.0, 8.0),
        "MaxSideLeft.png": (0.0, 8.0),
        "MaxSideRight.png": (0.0, 8.0),
        "Lockpicking.png": (10.0, 40.0),
    }

    readings = {}

    for name, (low, high) in expected.items():
        frame = load_bgr(np, os.path.join(refs, name))
        obs, detector = observe(np, Detector, VisionConfig, frame)

        assert obs.ok, (
            name,
            detector.debug,
        )

        assert low <= obs.turn <= high, (
            name,
            obs.turn,
            detector.debug,
        )

        assert detector.debug.get("turn_source") == "INNER_CHAMBER_ONLY"
        readings[name] = obs.turn

    # Lockpick at both visual extremes must not leak into chamber rotation.
    assert abs(
        readings["MaxSideLeft.png"]
        - readings["MaxSideRight.png"]
    ) < 2.0

    # Ohjain: pieni tarahdys ei ole vasteikkuna. Kayttajan saanto oli
    # "jos lukko tarahtaa eika kierra sillon ei oo oikee kohta". Uudessa
    # rakenteessa saanto on yksi kynnys: pyyhkaisy jatkuu kunnes pesa
    # nousee lepokulmastaan ramp_degrees verran.
    ccfg = ControlConfig()

    def sweeping():
        c = Controller(ccfg, SearchMemory())
        c.phase = c.SCAN
        return c

    def feed(c, values, dt=0.005, start=0.0):
        t = start
        for turn in values:
            c.update(t, Observation(stamp=t, ok=True, turn=turn, running=True))
            t += dt
        return t

    # Lepokulma mitataan ensin, sitten yksi lyhyt tarahdys kynnyksen alle.
    twitch = sweeping()
    t = feed(twitch, [0.4] * 10)
    twitch_size = ccfg.ramp_degrees - 0.6
    t = feed(twitch, [0.4 + twitch_size, 0.4], start=t)
    assert twitch.phase == twitch.SCAN, twitch.phase
    assert not twitch.planner.ramp_locked

    # Sama ohjain, mutta pesa oikeasti kaantyy: nyt ikkuna lukittuu.
    turning = sweeping()
    t = feed(turning, [0.4] * 10)
    turning.update(t, Observation(stamp=t, ok=True, turn=0.4 + 12.0, running=True))
    assert turning.planner.ramp_locked
    assert turning.phase == turning.RAMP, turning.phase

    print("INNER CHAMBER geometry: OK")
    print(
        "reference turns:",
        ", ".join(
            f"{name}={value:.2f}"
            for name, value in readings.items()
        ),
    )
    print(
        "twitch guard: "
        f"{twitch_size:.1f} deg ei riita, "
        f"kynnys {ccfg.ramp_degrees:.1f} deg: OK"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
