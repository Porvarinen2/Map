"""Pyyhkaisyn ja ajovaiheen perussaannot: python test_fast_scan_deep_target.py

Tama testi lukitsee ne kolme asiaa, joissa aiempi versio kaatui pelissa:

  1. Haussa F naputetaan, ajossa pidetaan. Tiirikkaa kuluttaa se, etta
     F on pohjassa kohtaa vasten joka ei anna periksi, joten haussa
     vaanto katkaistaan saannollisesti. Kun pesa kaantyy, lukko antaa
     periksi - silloin F pysyy pohjassa eika sita katkaista.
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
    print("Haku naputtaa F:aa eika vaanna yhtajaksoisesti")
    c = sweeping()
    t = 0.0
    presses, press_start, held, moved_up = [], None, 0, 0
    moves = []
    for _ in range(600):
        action = c.update(t, obs(t, 0.4))
        if action.f_down:
            held += 1
            if press_start is None:
                press_start = t
        else:
            if press_start is not None:
                presses.append((t - press_start) * 1000.0)
                press_start = None
            if action.mouse_units:
                moved_up += 1
        if action.mouse_units:
            moves.append(action.mouse_units)
        t += 0.005
        if c.phase != c.SWEEP:
            break

    duty = held / 600.0
    check("F ei ole pohjassa koko ajan", 0.30 <= duty <= 0.75,
          f"{duty * 100:.0f} % ruuduista")
    check("painallukset ovat lyhyita", bool(presses) and max(presses) <= 400.0,
          f"pisin {max(presses):.0f} ms, {len(presses)} painallusta")
    check("hiiri ei liiku F ylhaalla", moved_up == 0,
          f"{moved_up} askelta F ylhaalla - ikkuna voisi jaada huomaamatta")
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
        turn = min(80.0, turn + 0.35)         # hidas mutta tasainen nousu
        action = c.update(t, obs(t, turn))
        if not action.f_down:
            released += 1
    # Hidas nousu on yhta lailla periksiantamista kuin nopeakin: vaantoa
    # ei saa katkaista sen aikana. Ruutukohtainen muutos jaa tassa
    # kohinakynnyksen alle, joten vertailu on tehtava huippuun.
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
    for round_index in range(200):
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

    # Kun paikalliset uusinnat on kaytetty, palataan pyyhkaisyyn.
    for _ in range((cfg.rescan_steps + 2) * 40):
        t += 0.005
        c._settles = 1
        c.update(t, obs(t, 0.3))
        if c.phase == c.SWEEP:
            break
    check("lopulta palataan pyyhkaisyyn", c.phase == c.SWEEP, c.phase)
    print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki pyyhkaisy- ja ajovaihetestit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
