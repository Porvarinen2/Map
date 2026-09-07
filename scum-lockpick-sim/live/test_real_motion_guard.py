"""Vartijat: mika on oikeaa liiketta ja mika pelkkaa tarinaa.

Kayttajan saannot, jotka taman on pidettava voimassa:

  "jos lukko tarahtaa eika kierra sillon ei oo oikee kohta"
  "se jaa vammailee siihe sweetspotin kohalle ettei se oikee uskalla
   painaa F pohjas et paasis pidemmalle"

Uudessa rakenteessa nama tarkoittavat kolmea asiaa:

  1. Paikallaan tarisevaa lukemaa ei saa tulkita kaantymiseksi.
  2. Aitoa jatkuvaa kaantoa ei saa tulkita tarinaksi: F pysyy pohjassa
     eika askelia oteta kesken nousun.
  3. Kun kaanto pysahtyy maalin lahelle eika lukko aukea, ohjaimen on
     tehtava jotain. Nauhoituksessa juuri uusi ote vei 89 asteesta
     91.8 asteeseen ja lukko aukesi.

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


def driving(rest=1.0, cfg=None):
    """Ohjain ajovaiheeseen, vasteikkuna jo loydettyna."""
    c = Controller(cfg or ControlConfig(), SearchMemory())
    c.phase = c.SWEEP
    c._phase_started = 0.0
    c._sweep_started = 0.0
    t = 0.0
    for _ in range(10):                 # lepokulman mittaus
        c.update(t, obs(t, rest))
        t += 0.005
    return c, t


def main() -> int:
    cfg = ControlConfig()

    # ------------------------------------------------------------------
    print("Paikallaan tariseva lukema ei ole kaantymista")
    c, t = driving(rest=1.0)
    entered = False
    for wobble in [1.6, 0.5, 1.7, 0.6, 1.5, 0.4, 1.6, 0.5] * 10:
        t += 0.005
        c.update(t, obs(t, wobble))
        if c.phase != c.SWEEP:
            entered = True
            break
    check("tarina ei vie ajovaiheeseen", not entered, c.phase)
    check("ikkunaa ei merkitty loydetyksi", not c.planner.ramp_locked)
    print()

    # ------------------------------------------------------------------
    print("Aito jatkuva kaanto pitaa F:n pohjassa")
    c, t = driving(rest=1.0)
    t += 0.005
    c.update(t, obs(t, 14.0))                       # vaste loytyi
    check("siirryttiin ajovaiheeseen", c.phase == c.DRIVE, c.phase)

    released = steps = 0
    turn = 14.0
    for _ in range(140):
        t += 0.005
        turn = min(88.0, turn + 0.55)               # pesa kaantyy koko ajan
        action = c.update(t, obs(t, turn))
        if not action.f_down:
            released += 1
        if action.mouse_units:
            steps += 1
    check("F ei irtoa kertaakaan", released == 0, f"{released} irrotusta")
    check("kesken nousun ei nykita", steps == 0, f"{steps} askelta")
    print()

    # ------------------------------------------------------------------
    print("Pysahtynyt kaanto johtaa askeleeseen, ei odotteluun")
    c, t = driving(rest=1.0)
    t += 0.005
    c.update(t, obs(t, 40.0))

    stepped = None
    for _ in range(300):
        t += 0.005
        action = c.update(t, obs(t, 40.0))          # kaanto ei liiku enaa
        if action.mouse_units:
            stepped = action
            break
    check("pysahtyminen havaittiin ja otettiin askel", stepped is not None,
          stepped.note if stepped else "ei askelta 1.5 s aikana")
    check("askel otettiin F pohjassa", bool(stepped) and stepped.f_down,
          stepped.note if stepped else "")
    check("askel meni eteenpain", bool(stepped) and stepped.mouse_units > 0,
          f"{stepped.mouse_units:+.1f} u" if stepped else "")
    print()

    # ------------------------------------------------------------------
    print("Maalissa mutta ei aukea -> uusi ote")
    c, t = driving(rest=1.0)
    t += 0.005
    c.update(t, obs(t, 89.4))                       # suoraan maalikulmaan

    rebite = None
    held = 0
    for _ in range(200):
        t += 0.005
        action = c.update(t, obs(t, 89.4))
        if action.f_down:
            held += 1
        if action.phase == c.REBITE:
            rebite = action
            break
    check("ohjain ei jaa odottamaan loputtomiin", rebite is not None,
          f"{held} ruutua F pohjassa" if rebite is None else rebite.note)
    check("ennen uutta otetta F pidettiin pohjassa",
          held >= 0.8 * cfg.goal_stall_ms / 1000.0 / 0.005,
          f"{held} ruutua")
    check("uusi ote paastaa F:n hetkeksi irti",
          bool(rebite) and not rebite.f_down, rebite.note if rebite else "")

    # Uuden otteen jalkeen palataan ajoon ja otetaan pieni nykays.
    nudge = None
    for _ in range(80):
        t += 0.005
        action = c.update(t, obs(t, 82.0))
        if action.mouse_units:
            nudge = action
            break
    check("uuden otteen jalkeen nykaistaan", nudge is not None,
          nudge.note if nudge else "ei nykaysta")
    check("nykays on pieni", bool(nudge) and abs(nudge.mouse_units) <= cfg.drive_final_step_units,
          f"{nudge.mouse_units:+.1f} u" if nudge else "")
    check("nykays tehdaan F pohjassa", bool(nudge) and nudge.f_down,
          nudge.note if nudge else "")
    print()

    # ------------------------------------------------------------------
    print("Ilman lukkoa ei laheteta mitaan")
    c = Controller(ControlConfig())
    action = c.update(0.0, Observation(ok=False))
    check("hiiri ei liiku", action.mouse_units == 0.0)
    check("F ei mene pohjaan", action.f_down is False)
    print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki vartijatestit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
