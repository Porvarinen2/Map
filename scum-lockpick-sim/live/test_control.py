"""Ohjaimen kayttaytyminen: python test_control.py

Yksi kysymys: tekeeko ohjain sen mita sen pitaa tehda?

    tap, tap, tap, tap, taap, taaaap, taaaap, AUKI

Tama testi ei mittaa onnistumisprosentteja. Se tarkistaa KUVION:
napautukset ovat lyhyita ja samanmittaisia, hiiri liikkuu tasaisin
pienin askelin oikealle, ja kun lukkopesa kaantyy, painallus pitenee
sen mukaan kuinka kauan pesa jaksaa kaantya.

Ei vaadi numpya.
"""

from __future__ import annotations

import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lockpick_control import (  # noqa: E402
    ControlConfig,
    Controller,
    Observation,
    SearchMemory,
)

FAILURES: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if ok else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
    if not ok:
        FAILURES.append(name)


def obs(t, turn):
    return Observation(stamp=t, ok=True, turn=turn, timer=0.8, running=True)


def scanning(cfg=None):
    """Ohjain valmiiksi skannausvaiheeseen, kotiinajo ohitettuna."""
    c = Controller(cfg or ControlConfig(), SearchMemory())
    c.phase = c.SCAN
    return c


def run(c, turns, dt=0.005, start=0.0):
    """Syottaa kulmasarjan ja palauttaa (painallukset ms, liikkeet, vaiheet)."""
    t = start
    presses, moves, phases = [], [], []
    press_start = None
    for turn in turns:
        a = c.update(t, obs(t, turn))
        phases.append(a.phase)
        if a.mouse_units:
            moves.append((a.mouse_units, a.f_down))
        if a.f_down and press_start is None:
            press_start = t
        elif not a.f_down and press_start is not None:
            presses.append((t - press_start) * 1000.0)
            press_start = None
        t += dt
    if press_start is not None:
        presses.append((t - press_start) * 1000.0)
    return presses, moves, phases


def main() -> int:
    cfg = ControlConfig()

    # ------------------------------------------------------------------
    print("Skannaus: tap, tap, tap - kaikki samanlaisia")
    c = scanning()
    presses, moves, _ = run(c, [0.5] * 400)

    check("napautuksia tuli useita", len(presses) >= 5, f"{len(presses)} kpl")
    check("kaikki napautukset samanmittaisia",
          len(presses) > 1 and max(presses[:-1]) - min(presses[:-1]) <= 10.0,
          f"{min(presses[:-1]):.0f} - {max(presses[:-1]):.0f} ms")
    check("napautus on lyhyt", max(presses[:-1]) <= cfg.tap_ms + 15.0,
          f"{max(presses[:-1]):.0f} ms (asetus {cfg.tap_ms:.0f} ms)")

    sizes = {round(u) for u, _ in moves}
    check("hiiri liikkuu aina yhta paljon", len(sizes) == 1, f"{sizes} yksikkoa")
    check("askel on pieni", max(abs(u) for u, _ in moves) <= 150.0,
          f"{max(abs(u) for u, _ in moves):.0f} u")
    check("liike kulkee vain oikealle", all(u > 0 for u, _ in moves),
          f"{len(moves)} askelta")
    print()

    # ------------------------------------------------------------------
    print("Lukkopesan kaanto vie ramppiin")
    c = scanning()
    run(c, [0.5] * 40)
    a = c.update(1.0, obs(1.0, 0.5 + cfg.ramp_degrees - 1.0))
    check("pieni tarahdys ei riita", c.phase == c.SCAN,
          f"{cfg.ramp_degrees - 1.0:.1f} deg -> {c.phase}")

    c = scanning()
    run(c, [0.5] * 40)
    a = c.update(1.0, obs(1.0, 0.5 + cfg.ramp_degrees + 1.0))
    check("kunnon kaanto lukitsee rampin", c.phase == c.RAMP, c.phase)
    check("F menee pohjaan", a.f_down, a.note)
    check("ramppi merkittiin", c.planner.ramp_locked)
    print()

    # ------------------------------------------------------------------
    print("Rampissa painallus kestaa niin kauan kuin pesa kaantyy")
    # Pesa kaantyy hitaasti ylospain: painalluksen on jatkuttava.
    c = scanning()
    run(c, [0.5] * 40)
    c.update(1.0, obs(1.0, 10.0))
    rising = [min(80.0, 10.0 + i * 0.6) for i in range(120)]
    presses, moves, _ = run(c, rising, start=1.005)
    check("nouseva kaanto ei katkaise painallusta",
          not presses or presses[0] >= 400.0,
          f"{presses[0]:.0f} ms" if presses else "painallus jatkui loppuun")
    check("kesken nousun ei nykita", not moves, f"{len(moves)} nykaysta")

    # Pesa pysahtyy: painalluksen on loputtava ja nykaisyn tultava.
    c = scanning()
    run(c, [0.5] * 40)
    c.update(1.0, obs(1.0, 10.0))
    presses, moves, _ = run(c, [10.0] * 120, start=1.005)
    check("pysahtynyt kaanto katkaisee painalluksen",
          bool(presses) and presses[0] <= cfg.press_min_ms + cfg.press_stall_ms + 40.0,
          f"{presses[0]:.0f} ms" if presses else "ei katkennut")
    check("pysahtymisen jalkeen nykaistaan", bool(moves),
          f"{moves[0][0]:+.0f} u" if moves else "ei nykaysta")
    check("nykays on pieni", not moves or abs(moves[0][0]) <= cfg.nudge_units,
          f"{abs(moves[0][0]):.0f} u" if moves else "")
    print()

    # ------------------------------------------------------------------
    print("Maalissa F pysyy pohjassa")
    c = scanning()
    run(c, [0.5] * 40)
    c.update(1.0, obs(1.0, 10.0))
    presses, moves, _ = run(c, [cfg.open_degrees + 1.0] * 60, start=1.005)
    check("F ei irtoa maalikulmassa", len(presses) <= 1,
          f"{len(presses)} painallusta")
    check("maalissa ei nykita", not moves, f"{len(moves)} nykaysta")
    print()

    # ------------------------------------------------------------------
    print("Ilman lukkoa ei laheteta mitaan")
    c = Controller(ControlConfig())
    a = c.update(0.0, Observation(ok=False))
    check("hiiri ei liiku", a.mouse_units == 0.0)
    check("F ei mene pohjaan", a.f_down is False)
    print()

    # ------------------------------------------------------------------
    # Koko kuvio lapi mallilukolla. Tassa EI vaiteta onnistumisprosenttia
    # - tarkistetaan vain etta kuvio on oikea: monta lyhytta napautusta,
    # sitten selvasti pidempi painallus, ja lukko aukeaa.
    print("Koko kuvio mallilukolla")
    try:
        from lock_sim import LockAttempt, SimConfig, SimulatedScreen
    except ImportError:
        print("  (lock_sim puuttuu, ohitetaan)")
        print()
    else:
        sim = SimConfig()
        rng = random.Random(3)
        attempt = LockAttempt(sim, rng, sweet=900.0)
        controller = Controller(ControlConfig())
        screen = SimulatedScreen(attempt, rng, sim)
        now = 0.0
        runs, last = [], None
        for _ in range(1200):
            if attempt.finished:
                break
            action = controller.update(now, screen.read(now))
            if action.f_down != last:
                runs.append([action.f_down, now, now])
                last = action.f_down
            elif runs:
                runs[-1][2] = now
            attempt.step(0.004, action.mouse_units, action.f_down)
            now += 0.004
        lengths = [(b - a) * 1000.0 for f, a, b in runs if f]
        taps = [v for v in lengths if v <= 150.0]
        longs = [v for v in lengths if v > 150.0]
        check("lukko aukesi", attempt.opened, f"{attempt.angle:.1f} deg")
        check("ensin monta lyhytta napautusta", len(taps) >= 4, f"{len(taps)} kpl")
        check("sitten selvasti pidempi painallus", bool(longs),
              " ".join(f"{v:.0f}" for v in lengths))
    print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki ohjaintestit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
