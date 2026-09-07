"""Pyyhkaisyn ja ajovaiheen perussaannot: python test_fast_scan_deep_target.py

Tama testi lukitsee ne kolme asiaa, joissa aiempi versio kaatui pelissa:

  1. Pyyhkaisyn aikana F EI irtoa. Vanha versio naputti F:aa lyhyilla
     tokeilla ja paasti irti juuri kun pesa alkoi kaantya. Kayttajan
     sanoin: "se jaa vammailee siihe sweetspotin kohalle ettei se
     oikee uskalla painaa F pohjas".
  2. Askel on selvasti vasteikkunaa lyhyempi, joten ikkuna ei voi jaada
     kahden askeleen valiin. Vanha 300 yksikon askel hyppasi mitatun
     noin 120 yksikon ikkunan yli.
  3. Ydin loytyy puolitushaulla. Kun hienoaskel ylittaa ytimen, askel
     puolittuu - muuten kapea ydin jaa ikuisesti askelten valiin.

Ei vaadi numpya.
"""

from __future__ import annotations

import os
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


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if condition else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
    if not condition:
        FAILURES.append(name)


def obs(t, turn):
    return Observation(stamp=t, ok=True, turn=turn, timer=0.8, running=True)


def sweeping(cfg=None):
    """Ohjain valmiiksi pyyhkaisyvaiheeseen, kotiinajo ohitettuna."""
    c = Controller(cfg or ControlConfig(), SearchMemory())
    c.phase = c.SWEEP
    c._phase_started = 0.0
    c._sweep_started = 0.0
    return c


def main() -> int:
    cfg = ControlConfig()

    # ------------------------------------------------------------------
    print("Pyyhkaisy pitaa F:n pohjassa ja matelee oikealle")
    c = sweeping()
    t = 0.0
    released = 0
    moves = []
    for _ in range(400):
        action = c.update(t, obs(t, 0.4))
        if not action.f_down:
            released += 1
        if action.mouse_units:
            moves.append(action.mouse_units)
        t += 0.005
        if c.phase != c.SWEEP:
            break

    check("F ei irtoa kertaakaan pyyhkaisyn aikana", released == 0,
          f"{released} irrotusta 400 ruudusta")
    check("liike kulkee vain oikealle", all(m > 0 for m in moves),
          f"{len(moves)} askelta")
    check("askel on vasteikkunaa lyhyempi", cfg.sweep_step_units <= 120.0,
          f"{cfg.sweep_step_units:.0f} u vs mitattu ikkuna ~120 u")
    check("askel on tasainen", len(set(round(m) for m in moves)) == 1,
          f"{sorted(set(round(m) for m in moves))} u")
    print()

    # ------------------------------------------------------------------
    print("Vaste vie suoraan ajovaiheeseen, F pysyy pohjassa")
    c = sweeping()
    t = 0.0
    for _ in range(60):
        c.update(t, obs(t, 0.4))
        t += 0.005
    reached = c.position

    action = c.update(t, obs(t, 12.0))
    check("vaste siirtaa ajovaiheeseen", c.phase == c.DRIVE, c.phase)
    check("F pysyy pohjassa siirtymassa", action.f_down, action.note)
    check("ikkuna merkittiin loydetyksi", c.planner.ramp_locked)
    check("liike perutaan taaksepain havainnon viiveen verran",
          action.mouse_units < 0, f"{action.mouse_units:+.0f} u")
    check("peruutus ei vie janan alkua taemmas",
          abs(action.mouse_units) <= reached + cfg.sweep_step_units * 2,
          f"{abs(action.mouse_units):.0f} u")
    print()

    # ------------------------------------------------------------------
    print("Ajovaihe ei katkaise nousevaa kaantoa")
    c = sweeping()
    t = 0.0
    for _ in range(60):
        c.update(t, obs(t, 0.4))
        t += 0.005
    c.update(t, obs(t, 12.0))

    released = 0
    turn = 12.0
    for _ in range(120):
        t += 0.005
        turn = min(80.0, turn + 0.7)          # pesa kaantyy koko ajan
        action = c.update(t, obs(t, turn))
        if not action.f_down:
            released += 1
    check("F ei irtoa kertaakaan nousun aikana", released == 0,
          f"{released} irrotusta 120 ruudusta")
    print()

    # ------------------------------------------------------------------
    print("Ydin haetaan puolittamalla, ei samalla askeleella")
    c = sweeping()
    t = 0.0
    for _ in range(60):
        c.update(t, obs(t, 0.4))
        t += 0.005
    c.update(t, obs(t, 12.0))

    # Pysaytetaan pesa hienoalueelle ja annetaan kaannon huonontua,
    # eli askel ylitti ytimen. Silloin askelen on puolituttava.
    c._settles = 2
    c._settled_value = 86.0
    steps = []
    turn = 86.0
    for round_index in range(60):
        t += 0.005
        action = c.update(t, obs(t, turn))
        if action.mouse_units:
            steps.append(abs(action.mouse_units))
            turn = 86.0 if turn < 86.0 else 83.0   # joka askel ylittaa ytimen
    check("hienoaskel puolittui ylityksen jalkeen",
          len(steps) >= 2 and min(steps) < cfg.drive_final_step_units,
          " -> ".join(f"{v:.2f}" for v in steps[:6]))
    check("askel ei mene minimin alle",
          all(v >= cfg.drive_min_step_units - 1e-6 for v in steps),
          f"pienin {min(steps):.2f} u, minimi {cfg.drive_min_step_units:.2f} u")
    print()

    # ------------------------------------------------------------------
    print("Vasteen kadotessa haetaan ensin lahelta")
    c = sweeping()
    t = 0.0
    for _ in range(60):
        c.update(t, obs(t, 0.4))
        t += 0.005
    c.update(t, obs(t, 12.0))
    c._settles = 1                              # asettuminen on jo nahty

    action = c.update(t + 0.005, obs(t + 0.005, 0.3))
    check("ei palata heti koko janan pyyhkaisyyn", c.phase == c.DRIVE,
          f"{c.phase}: {action.note}")
    check("uusinta tehdaan F pohjassa", action.f_down, action.note)

    # Kun paikalliset uusinnat on kaytetty, palataan pyyhkaisyyn.
    for _ in range(cfg.rescan_steps + 2):
        t += 0.05
        c._settles = 1
        c.update(t, obs(t, 0.3))
    check("lopulta palataan pyyhkaisyyn", c.phase == c.SWEEP, c.phase)
    print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki pyyhkaisy- ja ajovaihetestit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
