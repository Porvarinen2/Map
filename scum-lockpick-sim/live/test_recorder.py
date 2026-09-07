from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import autolockpick_live as live


class DummyNP:
    pass


def main():
    rec = live.PlayerRecorder(DummyNP(), image_fps=1.0)
    original_here = live.HERE
    tmp = tempfile.mkdtemp(prefix="lp_recorder_test_")

    try:
        live.HERE = tmp
        folder = rec.start()
        t0 = rec.started_perf

        rec.observe(
            t0, None,
            live.Observation(stamp=t0, ok=True, turn=0.0, timer=1.0, running=True),
            {"metal": 3000, "keyhole": 500, "timer": 4000},
            {"F": False, "SPACE": False},
            (100, 100),
        )

        rec.observe(
            t0 + 0.05, None,
            live.Observation(stamp=t0 + 0.05, ok=True, turn=18.0, timer=.95, running=True),
            {"metal": 3000, "keyhole": 500, "timer": 3900},
            {"F": True, "SPACE": False},
            (110, 100),
        )

        rec.observe(
            t0 + 0.15, None,
            live.Observation(stamp=t0 + 0.15, ok=True, turn=42.0, timer=.9, running=True),
            {"metal": 3000, "keyhole": 500, "timer": 3800},
            {"F": False, "SPACE": False},
            (115, 100),
        )

        rec.stop("test")

        with open(os.path.join(folder, "summary.json"), "r", encoding="utf-8") as handle:
            data = json.load(handle)

        assert data["player_profile"]["f_press_count"] == 1
        assert data["f_holds"][0]["peak_turn"] == 18.0
        assert data["attempt_count"] == 1

        print("PlayerRecorder: OK")
        return 0

    finally:
        live.HERE = original_here
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
