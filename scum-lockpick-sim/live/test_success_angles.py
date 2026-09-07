"""User supplied Lock Success Angles: successful keyway must be horizontal."""

from __future__ import annotations

import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lockpick_control import wrap_angle


def raw_axis(path):
    image = np.asarray(Image.open(path).convert("RGB"))[:, :, ::-1].astype(float)
    h, w = image.shape[:2]
    cx = (w - 1) / 2.0
    cy = (h - 1) / 2.0

    yy, xx = np.indices((h, w))
    rr = np.sqrt((xx-cx)**2 + (yy-cy)**2)

    lum = (
        0.114 * image[:, :, 0]
        + 0.587 * image[:, :, 1]
        + 0.299 * image[:, :, 2]
    )

    mask = (
        (lum < 22.0)
        & (rr < 55.0)
    )

    ys, xs = np.where(mask)
    assert len(xs) > 1500

    pts = np.column_stack((xs-cx, ys-cy)).astype(float)
    cov = np.cov(pts, rowvar=False)
    values, vectors = np.linalg.eigh(cov)
    vx, vy = vectors[:, np.argmax(values)]

    angle = math.degrees(
        math.atan2(vx, -vy)
    )

    while angle <= -90.0:
        angle += 180.0
    while angle > 90.0:
        angle -= 180.0

    return angle


def main():
    folder = os.path.join(HERE, "references", "success_angles")

    results = {}

    for name in (
        "BasicSuccess.png",
        "EnforcedSuccess.png",
        "MediumSuccess.png",
        "RustedSuccess.png",
    ):
        angle = raw_axis(
            os.path.join(folder, name)
        )

        # At success the keyway is visually horizontal.
        horizontal = abs(angle)

        assert 85.0 <= horizontal <= 90.0, (
            name,
            angle,
        )

        # Runtime continuity approaches this from ~80 degrees clockwise.
        wrapped = wrap_angle(angle, 80.0)

        if wrapped < 0:
            wrapped += 180.0

        assert wrapped >= 90.0, (
            name,
            angle,
            wrapped,
        )

        results[name] = (angle, wrapped)

    for name, (raw, wrapped) in results.items():
        print(
            f"{name}: raw={raw:+.2f} deg, "
            f"clockwise branch={wrapped:.2f} deg"
        )

    print("success-angle calibration: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
