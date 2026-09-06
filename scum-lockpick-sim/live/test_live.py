"""Ajaa live-ohjaimen simuloitua lukkoa vasten: python test_live.py

Taman paketin tarkein testi. Se todistaa, etta se sama lockpick_control.py,
joka ajaa pelia, avaa simuloidun lukon - ja etta se tekee sen NAKEMATTA
TIIRIKKAA. Ohjain saa tietaa vain lukkopesan kaannon.

Simulaatio muuntaa hiiriyksikot asteiksi omalla kertoimellaan, jota ohjain
ei tieda. Juuri se on koko pointti: pelin hiiriherkkyys saa olla mika tahansa.
"""

from __future__ import annotations

import os
import random
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "sim"))

from lockpick_control import (  # noqa: E402
    ControlConfig,
    Controller,
    Observation,
    SearchMemory,
)
from lockpick_model import PICK_MAX, PICK_MIN, LockAttempt, LockConfig  # noqa: E402

DT = 0.002
FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if condition else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
    if not condition:
        FAILURES.append(name)


class SimulatedScreen:
    """Vastaa live-skriptin Detectoria: viive, ruutuvali ja lukutarkkuus.

    Palauttaa VAIN lukkopesan kaannon. Tiirikan asentoa ei anneta, koska
    ohjain ei sita nae pelissakaan.
    """

    def __init__(self, attempt, rng, latency_ms=45.0, frame_ms=8.0,
                 noise_deg=0.8, quantum_deg=0.5):
        self.attempt = attempt
        self.rng = rng
        self.latency = latency_ms / 1000.0
        self.frame = frame_ms / 1000.0
        self.noise = noise_deg
        self.quantum = quantum_deg
        self.buffer: list[tuple[float, float]] = []
        self.latest = Observation(ok=False)
        self.next_sample = 0.0

    def read(self, now: float) -> Observation:
        self.buffer.append((now, self.attempt.turn))
        if now < self.next_sample:
            return self.latest
        self.next_sample = now + self.frame

        cutoff = now - self.latency
        chosen, keep = None, 0
        for i, (stamp, turn) in enumerate(self.buffer):
            if stamp <= cutoff:
                chosen, keep = (stamp, turn), i
            else:
                break
        if chosen is None:
            return self.latest
        self.buffer = self.buffer[keep:]

        stamp, turn = chosen
        noisy = turn + self.rng.gauss(0.0, self.noise)
        noisy = max(0.0, round(noisy / self.quantum) * self.quantum)
        self.latest = Observation(
            stamp=stamp, ok=True, turn=noisy,
            timer=self.attempt.time_left / self.attempt.time_limit, running=True)
        return self.latest


def run_attempt(lock_cfg, ctrl_cfg, rng, deg_per_unit, memory,
                start_pick=0.0, carried_wear=0.0, sweet_spot=None, **screen_kwargs):
    """Yksi yritys. deg_per_unit on pelin herkkyys, jota ohjain ei tieda."""
    attempt = LockAttempt(lock_cfg, rng, sweet_spot=sweet_spot)
    attempt.wear = carried_wear
    attempt.pick = start_pick

    controller = Controller(ctrl_cfg, memory)
    screen = SimulatedScreen(attempt, rng, **screen_kwargs)

    pick = start_pick
    now = 0.0
    guard = int(attempt.time_limit / DT) + 80
    for _ in range(guard):
        if attempt.finished:
            break
        action = controller.update(now, screen.read(now))
        if action.mouse_units:
            # Seina: ylimaarainen liike reunaa vasten ei siirra mitaan.
            pick = max(PICK_MIN, min(PICK_MAX, pick + action.mouse_units * deg_per_unit))
        attempt.step(DT, pick, action.f_down)
        now += DT

    controller.finish_attempt(attempt.opened)
    return attempt, controller, pick


def run_session(lock_cfg, ctrl_cfg, rng, deg_per_unit, max_attempts=6,
                stable_sweet_spot=False, **kw):
    memory = SearchMemory()
    pick, wear = 0.0, 0.0
    controller = None
    spot = None
    if stable_sweet_spot:
        margin = lock_cfg.zone_half * 0.25
        spot = rng.uniform(PICK_MIN + margin, PICK_MAX - margin)
    for n in range(1, max_attempts + 1):
        attempt, controller, pick = run_attempt(
            lock_cfg, ctrl_cfg, rng, deg_per_unit, memory,
            start_pick=pick, carried_wear=wear, sweet_spot=spot, **kw)
        if attempt.opened:
            return True, n, controller
        wear = 0.0 if attempt.broken else attempt.wear
    return False, max_attempts, controller


def batch(lock_cfg, sessions=120, seed=4242, deg_per_unit=0.035,
          max_attempts=6, stable_sweet_spot=False, **cfg_kwargs):
    rng = random.Random(seed)
    opened, first = 0, 0
    attempts = []
    for _ in range(sessions):
        cfg = ControlConfig(**cfg_kwargs)      # tuore konfiguraatio per sessio
        ok, n, _ = run_session(lock_cfg, cfg, rng, deg_per_unit, max_attempts,
                               stable_sweet_spot=stable_sweet_spot)
        if ok:
            opened += 1
            attempts.append(n)
            if n == 1:
                first += 1
    return {
        "success": opened / sessions,
        "first": first / sessions,
        "attempts": statistics.fmean(attempts) if attempts else float("nan"),
    }


# --------------------------------------------------------------------------


def test_opens_without_seeing_the_pick() -> None:
    print("Lukko aukeaa ilman tiirikan tunnistusta")
    for tier in ["rusted", "basic", "medium", "enforced"]:
        stats = batch(LockConfig(tier=tier, skill=1), sessions=120)
        check(f"{tier}: avautuu yli 85 % sessioista", stats["success"] > 0.85,
              f"{stats['success'] * 100:.1f} %, keskim. {stats['attempts']:.2f} yritysta")


def test_unknown_mouse_sensitivity() -> None:
    """Ohjain ei tieda pelin herkkyytta. Sen ei kuulukaan tietaa."""
    print("Hiiriherkkyys saa olla mika tahansa")
    lock = LockConfig(tier="basic", skill=1)
    for deg_per_unit in [0.015, 0.035, 0.060, 0.090]:
        stats = batch(lock, sessions=100, deg_per_unit=deg_per_unit, max_attempts=8)
        check(f"{deg_per_unit:.3f} deg/yksikko", stats["success"] > 0.80,
              f"{stats['success'] * 100:.1f} %, keskim. {stats['attempts']:.2f} yritysta")


def test_homing_finds_the_wall() -> None:
    """Vasen reuna loydetaan tyontamalla, ei mittaamalla."""
    print("Kotiinajo loytaa vasemman reunan mista tahansa")
    rng = random.Random(5)
    for start in [PICK_MIN, -20.0, 0.0, 30.0, PICK_MAX]:
        cfg = ControlConfig()
        attempt, controller, _ = run_attempt(
            LockConfig(tier="rusted", skill=3), cfg, rng, 0.035, SearchMemory(),
            start_pick=start, sweet_spot=PICK_MIN + 6.0)
        first = controller.probes[0].position if controller.probes else None
        check(f"aloitus {start:+.0f} deg -> ensimmainen testi vasemmalla",
              attempt.opened or (first is not None and first < 200),
              "aukesi" if attempt.opened else f"{first:.0f} u")


def test_scan_runs_left_to_right() -> None:
    print("Skannaus kulkee vasemmalta oikealle")
    rng = random.Random(7)
    cfg = ControlConfig()
    _, controller, _ = run_attempt(LockConfig(tier="enforced", skill=3), cfg, rng,
                                   0.035, SearchMemory(), sweet_spot=55.0)
    scans = [p.position for p in controller.probes if not p.ramp]
    check("ensimmainen testi on vasemmassa reunassa",
          bool(scans) and scans[0] < 1.0, f"{scans[0]:.0f} u" if scans else "ei testeja")
    check("testit etenevat vain oikealle",
          all(b >= a - 1e-6 for a, b in zip(scans, scans[1:])), f"{len(scans)} testia")
    check("askel on tasainen",
          len(scans) < 3 or len(set(round(b - a) for a, b in zip(scans, scans[1:]))) == 1,
          f"{[round(b - a) for a, b in zip(scans, scans[1:])][:6]}")


def test_rising_turn_is_never_cut() -> None:
    """Helperi 1.8:n paavika: F vapautettiin kesken kasvavan kaannon."""
    print("Kasvavaa kaantoa ei katkaista")
    rng = random.Random(11)
    attempt, controller, _ = run_attempt(
        LockConfig(tier="basic", skill=2), ControlConfig(), rng, 0.035,
        SearchMemory(), sweet_spot=PICK_MIN + 4.0)
    check("reunan lahella oleva sweetspot aukeaa", attempt.opened,
          f"kaanto {attempt.turn:.1f} deg")
    rate = controller.measured_turn_rate
    check("kaantonopeus mitattiin ajon aikana", rate is not None and rate > 50,
          f"{rate:.0f} deg/s" if rate else "ei mittausta")


def test_hold_cap_repairs_itself() -> None:
    print("Liian lyhyt F-katto korjautuu itse")
    lock = LockConfig(tier="basic", skill=1)
    tight = batch(lock, sessions=80, maximum_hold_ms=320)
    frozen = batch(lock, sessions=80, maximum_hold_ms=320, auto_raise_hold_cap=False)
    check("itsekorjaus paalla: avautuu", tight["success"] > 0.80,
          f"{tight['success'] * 100:.1f} %")
    # Liian lyhyt katto ei enaa yksin esta avaamista, koska perakkaiset
    # painallukset kerryttavat kaantoa - juuri sita pelaajat kutsuvat
    # featheringiksi. Se kuitenkin hidastaa, joten itsekorjaus kannattaa.
    check("itsekorjaus pois: hitaampi", frozen["attempts"] >= tight["attempts"],
          f"{frozen['attempts']:.2f} vs {tight['attempts']:.2f} yritysta")


def test_memory_is_off_by_default() -> None:
    """Muisti auttaa vain jos sweetspot pysyy paikallaan yritysten yli.

    Pelaajien mukaan se voi vaihtua, joten oletuksena jokainen yritys alkaa
    vasemmasta reunasta puhtaalta polydalta.
    """
    print("Muisti on oletuksena pois")
    cfg = ControlConfig()
    check("jatkaminen pois paalta", cfg.resume_search is False)
    check("rampin muisti pois paalta", cfg.remember_ramp is False)
    check("askelen oppiminen jaa paalle", cfg.learn_step_from_ramp is True)

    lock = LockConfig(tier="medium", skill=0)     # lyhin aika, 2.75 s
    stable_on = batch(lock, sessions=140, max_attempts=6, stable_sweet_spot=True,
                      resume_search=True, remember_ramp=True)
    stable_off = batch(lock, sessions=140, max_attempts=6, stable_sweet_spot=True)
    check("pysyvalla sweetspotilla muisti nopeuttaa",
          stable_on["attempts"] <= stable_off["attempts"] + 0.02,
          f"{stable_on['attempts']:.2f} vs {stable_off['attempts']:.2f} yritysta")

    rolling_on = batch(lock, sessions=140, max_attempts=6,
                       resume_search=True, remember_ramp=True)
    rolling_off = batch(lock, sessions=140, max_attempts=6)
    check("vaihtuvalla sweetspotilla muisti ei auta, siksi oletus on pois",
          rolling_off["success"] >= rolling_on["success"],
          f"pois {rolling_off['success'] * 100:.1f} % vs paalla "
          f"{rolling_on['success'] * 100:.1f} %")


def test_step_halves_after_empty_sweep() -> None:
    """Jos koko jana kaydaan lapi loytamatta mitaan, askel oli liian harva."""
    print("Askel tihenee jos jana kaytiin turhaan")
    cfg = ControlConfig(scan_step_units=800.0)
    memory = SearchMemory()
    rng = random.Random(13)
    steps = [memory.scan_step_units or cfg.scan_step_units]
    for _ in range(4):
        run_attempt(LockConfig(tier="enforced", skill=0), cfg, rng, 0.09, memory,
                    sweet_spot=0.0)
        steps.append(memory.scan_step_units or cfg.scan_step_units)
    check("skannausvali pieneni", steps[-1] < steps[0],
          " -> ".join(f"{s:.0f}" for s in steps))
    check("vali ei mene minimin alle", steps[-1] >= cfg.minimum_scan_step_units,
          f"{steps[-1]:.0f} u")


def test_no_input_without_detection() -> None:
    print("Ilman lukkoa ei laheteta syotteita")
    controller = Controller(ControlConfig())
    action = controller.update(0.0, Observation(ok=False))
    check("hiiri ei liiku", action.mouse_units == 0.0)
    check("F ei mene pohjaan", action.f_down is False)


def test_only_turn_is_used() -> None:
    """Varmistaa ettei havainnossa ole tiirikkaa eika ohjain sita kaipaa."""
    print("Havainto sisaltaa vain lukon tiedot")
    fields = set(Observation.__dataclass_fields__)
    check("Observationissa ei ole pick-kentta", "pick" not in fields,
          ", ".join(sorted(fields)))
    rng = random.Random(17)
    attempt, controller, _ = run_attempt(
        LockConfig(tier="basic", skill=2), ControlConfig(), rng, 0.035,
        SearchMemory(), sweet_spot=10.0)
    check("ohjain teki paatoksia pelkalla kaannolla",
          attempt.opened or len(controller.probes) > 0,
          f"{len(controller.probes)} testia")


def main() -> int:
    for test in [
        test_opens_without_seeing_the_pick,
        test_unknown_mouse_sensitivity,
        test_homing_finds_the_wall,
        test_scan_runs_left_to_right,
        test_rising_turn_is_never_cut,
        test_hold_cap_repairs_itself,
        test_memory_is_off_by_default,
        test_step_halves_after_empty_sweep,
        test_no_input_without_detection,
        test_only_turn_is_used,
    ]:
        test()
        print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki live-logiikan testit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
