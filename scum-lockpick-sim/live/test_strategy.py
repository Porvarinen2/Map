"""Hakustrategian todennus: python test_strategy.py

Ajaa SWEEP+DRIVE-ohjaimen mitattuun dataan kalibroitua lukkomallia vastaan
(lock_sim.py) ja lisaksi joukkoa muunnelmia, joissa pelin tai koneen
kayttaytyminen on toinen kuin viritettaessa. Nain nahdaan onko strategia
oikeasti hyva vai onko se vain sovitettu yhteen malliin.

Ajo kestaa noin minuutin. --nopea puolittaa naytemaaran.
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lock_sim import SimConfig, batch  # noqa: E402
from lockpick_control import ControlConfig, Controller  # noqa: E402

FAILURES: list[str] = []

# Mallin muunnelmat ja se, mita kultakin vaaditaan yhdella yrityksella.
# Rajat on asetettu selvasti mitattujen arvojen alle, jotta testi kertoo
# rikkoutumisesta eika satunnaisvaihtelusta.
# (nimi, mallin muutos, vaadittu osuus yhdella yrityksella, kuudella)
MATRIX = [
    ("perusmalli (kalibroitu nauhoitukseen)", {}, 0.66, 0.85),
    ("naytonluku nopea, viive 30 ms", dict(latency_ms=30.0), 0.77, 0.85),
    ("naytonluku hidas, viive 90 ms", dict(latency_ms=90.0), 0.53, 0.85),
    ("kohinainen kulmalukema 1.5 deg", dict(noise_degrees=1.5), 0.37, 0.81),
    ("kapea ydin 1.5 u", dict(core_half=1.5), 0.60, 0.85),
    ("levea ydin 5 u", dict(core_half=5.0), 0.74, 0.85),
    ("hidas ruudunluku 50 ms", dict(frame_ms=50.0), 0.55, 0.85),
    ("hidas pesa 90 deg/s", dict(climb_rate=90.0, fall_rate=90.0), 0.32, 0.84),
    ("nopea pesa 220 deg/s", dict(climb_rate=220.0, fall_rate=220.0), 0.77, 0.85),
    ("pitka jana 5500 u", dict(span_units=5500.0), 0.57, 0.85),
    ("lyhyt jana 2500 u", dict(span_units=2500.0), 0.77, 0.85),
    ("lyhyt aika 2.5 s", dict(attempt_seconds=2.5), 0.47, 0.84),
    ("pitka aika 4.0 s", dict(attempt_seconds=4.0), 0.74, 0.85),
    ("pesa ei kaanny liikkeessa", dict(require_still_for_turn=True), 0.66, 0.85),
    ("kapea vasteikkuna", dict(ramp_midpoint=25.0, ramp_width=5.0), 0.45, 0.85),
    ("tiirikka ajautuu kaannon mukana", dict(drift_units=4.0), 0.64, 0.85),
]


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if ok else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
    if not ok:
        FAILURES.append(name)


def controller():
    return Controller(ControlConfig())


def main(argv=None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    sessions = 100 if "--nopea" in args else 200

    print("Mallin sovitus kayttajan nauhoitukseen")
    import random

    from lock_sim import LockAttempt

    lock = LockAttempt(SimConfig(), random.Random(1), sweet=958.0)
    check("d=58 u antaa muutaman asteen (nauhoitus 4.0)",
          2.0 <= lock.max_angle_at(900.0) <= 12.0,
          f"{lock.max_angle_at(900.0):.1f} deg")
    check("d=6 u antaa lahes taydet (nauhoitus 88.6)",
          80.0 <= lock.max_angle_at(952.0) <= 90.0,
          f"{lock.max_angle_at(952.0):.1f} deg")
    check("d=1 u avaa (nauhoitus AUKI)", lock.max_angle_at(957.0) >= 89.9)
    print()

    print(f"Strategia mallin muunnelmia vastaan ({sessions} sessiota kukin)")
    single_total = multi_total = 0.0
    measured = []
    for name, kw, floor_one, floor_six in MATRIX:
        cfg = SimConfig(**kw)
        one = batch(controller, cfg=cfg, sessions=sessions, max_attempts=1)["success"]
        six = batch(controller, cfg=cfg, sessions=sessions, max_attempts=6)["success"]
        single_total += one
        multi_total += six
        measured.append((name, one, six))
        check(f"{name}", one >= floor_one and six >= floor_six,
              f"yksi {one * 100:.1f} % (raja {floor_one * 100:.0f} %), "
              f"kuusi {six * 100:.1f} % (raja {floor_six * 100:.0f} %)")
    n = len(MATRIX)
    if "--rajat" in args:
        print()
        print("Ehdotetut rajat (mitattu miinus 15 prosenttiyksikkoa):")
        for name, one, six in measured:
            print(f"    {one - 0.15:.2f}, {six - 0.15:.2f},   # {name}")
    print()

    print("Kokonaistulos")
    single = single_total / n
    multi = multi_total / n
    check("yksi yritys keskimaarin yli 55 %", single >= 0.55, f"{single * 100:.1f} %")
    check("kuusi yritysta keskimaarin yli 95 %", multi >= 0.95, f"{multi * 100:.1f} %")

    # Vertailukohta: nauhoituksessa vanha versio avasi 1 yrityksen 12:sta.
    check("selvasti parempi kuin nauhoituksen 8 %", single >= 0.30,
          f"{single * 100:.1f} % vs 8 %")
    print()

    print("F pysyy pohjassa ajon aikana")
    import random as _r

    from lock_sim import run_attempt

    rng = _r.Random(7)
    f_share = []
    for _ in range(12):
        attempt, _, log = run_attempt(controller, SimConfig(), rng, trace=True)
        if not log:
            continue
        held = sum(1 for row in log if row[4])
        f_share.append(held / len(log))
    mean_share = sum(f_share) / max(1, len(f_share))
    check("F pohjassa yli 80 % ajasta", mean_share >= 0.80,
          f"{mean_share * 100:.0f} % (nauhoituksessa vanha versio 40-65 %)")
    print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki strategiatestit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
