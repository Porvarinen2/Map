"""Tilakoneen ja nakyman integraatiotesti: python test_runner.py

Ajaa LiveRunnerin ilman Windowsia ja ilman ruutukaappausta: syotteet
korvataan valekerroksella ja havainnot annetaan kasin. Nain aloitus,
uusinta, avautuminen ja tauko tulevat testatuiksi taalla, vaikka itse
peliajo vaatii Windowsin.
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import autolockpick_live as live  # noqa: E402
from lockpick_control import Observation  # noqa: E402

FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if condition else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
    if not condition:
        FAILURES.append(name)


class FakeInput:
    """Kirjaa syotteet lahettamatta niita minnekaan."""

    def __init__(self):
        self.mouse_units = 0.0
        self.mouse_calls = 0
        self.taps: list[int] = []
        self.held: set[int] = set()
        self.closed = False
        self.keys_to_report: set[int] = set()
        self.client = {"left": 0, "top": 0, "width": 1920, "height": 1080}

    def move_mouse(self, units):
        self.mouse_units += units
        self.mouse_calls += 1
        return int(units)

    def key_down(self, scan):
        self.held.add(scan)

    def key_up(self, scan):
        self.held.discard(scan)

    def tap(self, scan, hold_ms=60.0):
        self.taps.append(scan)

    def release_all(self):
        self.held.clear()

    def close(self):
        self.closed = True
        self.release_all()

    def pressed(self, vk):
        return vk in self.keys_to_report

    def foreground_client(self):
        return self.client, "SCUM (vale)"


class FakeConsole:
    def __init__(self, *args, **kwargs):
        self.frames: list[list[str]] = []

    def draw(self, lines, force=False):
        self.frames.append(lines)


def make_runner(probe_only=False):
    live.WinInput = FakeInput
    live.Console = FakeConsole
    control, vision, run = live.ControlConfig(), live.VisionConfig(), live.RunConfig()
    runner = live.LiveRunner(None, None, control, vision, run, probe_only=probe_only)
    runner.active = True
    return runner


def obs(t=0.0, ok=True, pick=0.0, turn=0.0, timer=1.0, running=False):
    return Observation(stamp=t, ok=ok, pick=pick, turn=turn, timer=timer, running=running)


# --------------------------------------------------------------------------


def test_presses_space_when_idle() -> None:
    print("Aloitus: SPACE kun ajastin ei kay")
    runner = make_runner()
    t = 0.0
    for _ in range(6):
        runner.step(t, obs(t, running=False))
        t += 0.2
    check("tila on ALOITTAA", runner.state == runner.STARTING, runner.state)
    check("SPACE lahetettiin", live.SCAN_SPACE in runner.input.taps,
          f"{len(runner.input.taps)} painallusta")
    check("SPACEa ei hakata joka ruudulla", len(runner.input.taps) <= 3,
          f"{len(runner.input.taps)} painallusta 1.2 s aikana")
    check("F ei ole pohjassa", live.SCAN_F not in runner.input.held)


def test_probe_sends_nothing() -> None:
    print("Probe-tila ei laheta syotteita")
    runner = make_runner(probe_only=True)
    t = 0.0
    for _ in range(6):
        runner.step(t, obs(t, running=False))
        t += 0.2
    for _ in range(60):
        runner.step(t, obs(t, running=True, pick=10.0))
        t += 0.02
    fake = runner.helper          # probe-tilassa runner.input on None
    check("SPACEa ei lahetetty", not fake.taps)
    check("hiirta ei liikutettu", fake.mouse_calls == 0)
    check("F ei ollut pohjassa", live.SCAN_F not in fake.held)
    check("tila eteni silti RATKAISEE-tilaan", runner.state == runner.SOLVING, runner.state)


def test_solves_and_reports_open() -> None:
    print("Ratkaisu ja avautuminen")
    runner = make_runner()
    t = 0.0
    runner.step(t, obs(t, running=False))
    t += 0.1
    runner.step(t, obs(t, running=True))
    check("yritys alkoi", runner.state == runner.SOLVING, runner.state)
    check("yrityslaskuri kasvoi", runner.attempts == 1, str(runner.attempts))

    pick = 0.0
    for _ in range(400):
        action_before = runner.input.mouse_units
        runner.step(t, obs(t, pick=pick, turn=0.0, running=True))
        pick += (runner.input.mouse_units - action_before) * 0.035
        t += 0.01
    check("hiirta ohjattiin", runner.input.mouse_calls > 0,
          f"{runner.input.mouse_calls} pulssia")
    check("F-testeja tehtiin", len(runner.controller.probes) > 0,
          f"{len(runner.controller.probes)} testia")

    # Lukko aukeaa: pesa on kaantynyt paljon ja minipeli sulkeutuu.
    for _ in range(3):
        runner.step(t, obs(t, pick=pick, turn=88.0, running=True))
        t += 0.01
    for _ in range(runner.run_cfg.lost_frames_for_end + 1):
        runner.step(t, obs(t, ok=False))
        t += 0.01
    check("avaus kirjattiin", runner.opened == 1, f"opened={runner.opened}")
    check("F vapautettiin", live.SCAN_F not in runner.input.held)
    check("tila palasi odottamaan", runner.state == runner.WAITING, runner.state)


def test_timeout_is_not_counted_as_open() -> None:
    print("Aikakatkaisu ei ole avaus")
    runner = make_runner()
    t = 0.0
    runner.step(t, obs(t, running=False)); t += 0.1
    runner.step(t, obs(t, running=True)); t += 0.1
    for _ in range(50):
        runner.step(t, obs(t, turn=4.0, running=True))
        t += 0.02
    for _ in range(runner.run_cfg.lost_frames_for_end + 1):
        runner.step(t, obs(t, ok=False))
        t += 0.01
    check("avauksia ei kirjattu", runner.opened == 0, f"opened={runner.opened}")
    check("epaonnistuminen kirjattiin", runner.timeouts == 1, f"timeouts={runner.timeouts}")


def test_pause_releases_everything() -> None:
    print("Tauko vapauttaa syotteet")
    runner = make_runner()
    t = 0.0
    runner.step(t, obs(t, running=False)); t += 0.1
    runner.step(t, obs(t, running=True)); t += 0.1
    for _ in range(80):
        runner.step(t, obs(t, turn=6.0, running=True))
        t += 0.01
    runner.active = False
    calls_before = runner.input.mouse_calls
    for _ in range(20):
        runner.step(t, obs(t, turn=6.0, running=True))
        t += 0.01
    check("F ei jaanyt pohjaan", live.SCAN_F not in runner.input.held)
    check("hiiri ei liiku tauolla", runner.input.mouse_calls == calls_before)


def test_attempt_limit() -> None:
    print("Yritysraja pysayttaa")
    runner = make_runner()
    runner.run_cfg.max_attempts = 2
    t = 0.0
    for _ in range(4):
        runner.step(t, obs(t, running=False)); t += 0.5
        runner.step(t, obs(t, running=True)); t += 0.1
        for _ in range(runner.run_cfg.lost_frames_for_end + 1):
            runner.step(t, obs(t, ok=False)); t += 0.01
    check("yrityksia enintaan raja", runner.attempts <= 2, str(runner.attempts))
    check("ajo pysahtyi", not runner.active)


def test_draw_survives_every_state() -> None:
    print("Nakyma piirtyy kaikissa tiloissa")
    runner = make_runner()
    try:
        runner.draw(0.0, Observation())                       # tavoite None
        runner.step(0.0, obs(0.0, running=False))
        runner.draw(0.1, obs(0.1))
        runner.step(0.2, obs(0.2, running=True))
        for i in range(60):
            runner.step(0.3 + i * 0.01, obs(0.3 + i * 0.01, turn=3.0, running=True))
        runner.draw(1.0, obs(1.0, pick=-40.0, turn=12.0, timer=0.4, running=True))
        ok, detail = True, f"{len(runner.console.frames)} ruutua"
    except Exception as error:            # nakyman kaatuminen keskeyttaisi ajon
        ok, detail = False, f"{type(error).__name__}: {error}"
    check("piirto ei kaadu", ok, detail)


def test_lost_detection_releases_keys() -> None:
    print("Tunnistuksen katketessa syotteet vapautuvat")
    runner = make_runner()
    t = 0.0
    runner.step(t, obs(t, running=False)); t += 0.1
    runner.step(t, obs(t, running=True)); t += 0.1
    for _ in range(120):
        runner.step(t, obs(t, turn=8.0, running=True))
        t += 0.01
    runner.step(t, obs(t, ok=False))
    check("F vapautui heti", live.SCAN_F not in runner.input.held)


def main() -> int:
    for test in [
        test_presses_space_when_idle,
        test_probe_sends_nothing,
        test_solves_and_reports_open,
        test_timeout_is_not_counted_as_open,
        test_pause_releases_everything,
        test_attempt_limit,
        test_draw_survives_every_state,
        test_lost_detection_releases_keys,
    ]:
        test()
        print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki tilakonetestit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
