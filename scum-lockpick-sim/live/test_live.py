"""Ajaa live-ohjaimen simuloitua lukkoa vastaan: python test_live.py

Tama on koko paketin tarkein testi. Se todistaa, etta se sama
lockpick_control.py, joka ajaa pelia, avaa simuloidun lukon. Windows-osia
(ruutukaappaus, SendInput) ei voi testata taalla, mutta paatoslogiikka voi.
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
    PICK_MAX,
    PICK_MIN,
    ControlConfig,
    Controller,
    Observation,
    SensitivityEstimator,
)
from lockpick_model import LockAttempt, LockConfig  # noqa: E402

DT = 0.002
FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if condition else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
    if not condition:
        FAILURES.append(name)


class SimulatedScreen:
    """Vastaa live-skriptin Detectoria, mutta lukee simulaatiota.

    Mallintaa samat kolme ruudunlukemisen rajoitetta: viive, ruutuvali ja
    kulman lukutarkkuus.
    """

    def __init__(self, attempt, rng, latency_ms=45.0, frame_ms=8.0,
                 noise_deg=0.8, quantum_deg=0.5):
        self.attempt = attempt
        self.rng = rng
        self.latency = latency_ms / 1000.0
        self.frame = frame_ms / 1000.0
        self.noise = noise_deg
        self.quantum = quantum_deg
        self.buffer: list[tuple[float, float, float]] = []
        self.latest = Observation(ok=False)
        self.next_sample = 0.0

    def read(self, now: float) -> Observation:
        self.buffer.append((now, self.attempt.pick, self.attempt.turn))
        if now < self.next_sample:
            return self.latest
        self.next_sample = now + self.frame

        cutoff = now - self.latency
        chosen = None
        keep = 0
        for i, (stamp, pick, turn) in enumerate(self.buffer):
            if stamp <= cutoff:
                chosen = (stamp, pick, turn)
                keep = i
            else:
                break
        if chosen is None:
            return self.latest
        self.buffer = self.buffer[keep:]

        stamp, pick, turn = chosen
        noisy = turn + self.rng.gauss(0.0, self.noise)
        noisy = max(0.0, round(noisy / self.quantum) * self.quantum)
        self.latest = Observation(
            stamp=stamp,
            ok=True,
            pick=pick + self.rng.gauss(0.0, self.noise * 0.4),
            turn=noisy,
            timer=self.attempt.time_left / self.attempt.time_limit,
            running=True,
        )
        return self.latest


def run_attempt(lock_cfg, ctrl_cfg, rng, true_deg_per_unit, start_pick=0.0,
                carried_wear=0.0, **screen_kwargs):
    # Pelissa sweetspot on aina tiirikan ulottuvilla, joten se arvotaan
    # skannausalueelta eika laajemmalta mallin janalta.
    reach_lo = min(ctrl_cfg.scan_from, ctrl_cfg.scan_to)
    reach_hi = max(ctrl_cfg.scan_from, ctrl_cfg.scan_to)
    attempt = LockAttempt(lock_cfg, rng, sweet_spot=rng.uniform(reach_lo, reach_hi))
    attempt.wear = carried_wear
    attempt.pick = start_pick

    controller = Controller(ctrl_cfg)
    screen = SimulatedScreen(attempt, rng, **screen_kwargs)

    pick = start_pick
    now = 0.0

    guard = int(attempt.time_limit / DT) + 60
    for _ in range(guard):
        if attempt.finished:
            break
        obs = screen.read(now)
        action = controller.update(now, obs)

        if action.mouse_units:
            pick = max(PICK_MIN, min(PICK_MAX, pick + action.mouse_units * true_deg_per_unit))

        attempt.step(DT, pick, action.f_down)
        now += DT

    return attempt, controller


def run_session(lock_cfg, ctrl_cfg, rng, true_deg_per_unit, max_attempts=6, **kw):
    pick, wear = 0.0, 0.0
    for n in range(1, max_attempts + 1):
        attempt, controller = run_attempt(
            lock_cfg, ctrl_cfg, rng, true_deg_per_unit,
            start_pick=pick, carried_wear=wear, **kw
        )
        if attempt.opened:
            return True, n, controller
        if attempt.broken:
            wear, pick = 0.0, 0.0
        else:
            wear, pick = attempt.wear, attempt.pick
    return False, max_attempts, controller


def batch(lock_cfg, ctrl_cfg, sessions=150, seed=4242, true_deg_per_unit=0.035, **kw):
    rng = random.Random(seed)
    opened = first = 0
    attempts = []
    for _ in range(sessions):
        # Konfiguraatio on jaettu, joten kopioidaan se joka sessiolle.
        cfg = ControlConfig(**vars(ctrl_cfg))
        ok, n, _ = run_session(lock_cfg, cfg, rng, true_deg_per_unit, **kw)
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


def test_opens_simulated_lock() -> None:
    print("Live-ohjain avaa simuloidun lukon")
    for tier in ["rusted", "basic", "medium", "enforced"]:
        stats = batch(LockConfig(tier=tier, skill=1), ControlConfig(), sessions=120)
        check(f"{tier}: avautuu yli 80 % sessioista",
              stats["success"] > 0.80,
              f"{stats['success'] * 100:.1f} % / 1. yritys {stats['first'] * 100:.1f} %")


def test_left_to_right_order() -> None:
    print("Skannaus kulkee vasemmalta oikealle")
    rng = random.Random(7)
    cfg = ControlConfig()
    _, controller = run_attempt(LockConfig(tier="basic", skill=3), cfg, rng, 0.035)
    scans = [p.pick for p in controller.probes if not p.ramp]
    check("ensimmainen testi on vasemmassa reunassa",
          bool(scans) and abs(scans[0] - cfg.scan_from) < 2.0,
          f"{scans[0]:+.1f} (tavoite {cfg.scan_from:+.1f})" if scans else "ei testeja")
    check("skannauspisteet kasvavat monotonisesti",
          all(b >= a - 1e-6 for a, b in zip(scans, scans[1:])),
          f"{len(scans)} pistetta")


def test_rising_turn_is_never_cut() -> None:
    """Helperi 1.8:n paavika: F vapautettiin kesken kasvavan kaannon."""
    print("Kasvavaa kaantoa ei katkaista")
    rng = random.Random(11)
    cfg = ControlConfig()
    # Sweetspot tiirikan ulottuvuuden reunalla: juuri siella hitaan haun
    # pitaa viela ehtia kaantaa pesa loppuun asti.
    attempt = LockAttempt(LockConfig(tier="basic", skill=1), rng,
                          sweet_spot=cfg.scan_from + 2.0)
    controller = Controller(cfg)
    screen = SimulatedScreen(attempt, rng)

    now, pick, held = 0.0, 0.0, 0.0
    while not attempt.finished:
        action = controller.update(now, screen.read(now))
        if action.mouse_units:
            pick = max(PICK_MIN, min(PICK_MAX, pick + action.mouse_units * 0.035))
        if action.f_down:
            held += DT
        attempt.step(DT, pick, action.f_down)
        now += DT

    check("sweetspot vasemmassa reunassa aukeaa", attempt.opened,
          f"turn={attempt.turn:.1f} deg, F pohjassa {held * 1000:.0f} ms")
    rate = controller.measured_turn_rate
    check("kaantonopeus mitattiin ajon aikana", rate is not None and rate > 50,
          f"{rate:.0f} deg/s" if rate else "ei mittausta")


def test_survives_wrong_sensitivity() -> None:
    """Takaisinkytkennan pointti: vaara herkkyysarvio ei saa rikkoa hakua."""
    print("Vaara hiiriherkkyys ei riko hakua")
    lock = LockConfig(tier="basic", skill=1)
    for factor, floor in [(0.5, 0.60), (2.0, 0.60)]:
        cfg = ControlConfig()
        stats = batch(lock, cfg, sessions=100, true_deg_per_unit=0.035 * factor)
        check(f"todellinen herkkyys {factor:g}x oletuksesta",
              stats["success"] > floor,
              f"{stats['success'] * 100:.1f} %")


def test_sensitivity_estimator_converges() -> None:
    print("Herkkyysarvio hakeutuu oikeaan")
    rng = random.Random(23)
    true_value = 0.082
    cfg = ControlConfig()          # oletus 0.035, eli yli kaksi kertaa vaara
    for _ in range(6):
        run_attempt(LockConfig(tier="rusted", skill=2), cfg, rng, true_value)
    error = abs(cfg.degrees_per_mouse_unit - true_value) / true_value
    check("arvio on 25 % sisalla todellisesta", error < 0.25,
          f"arvio {cfg.degrees_per_mouse_unit:.4f} vs todellinen {true_value:.4f}")

    unit = SensitivityEstimator(initial=0.035)
    for _ in range(8):
        unit.feed(100.0, 100.0 * 0.06)
    check("erillinen arvioija hylkaa vaarat naytteet ja loytaa arvon",
          abs(unit.value - 0.06) < 0.005 and unit.confident, f"{unit.value:.4f}")


def test_short_hold_cap_still_opens() -> None:
    """Simulaation loydos: liian lyhyt kiintea katto esti avaamisen kokonaan."""
    print("Kattoaika ei enaa maaraa lopputulosta")
    lock = LockConfig(tier="basic", skill=1)
    generous = batch(lock, ControlConfig(maximum_hold_ms=1200), sessions=100)
    tight = batch(lock, ControlConfig(maximum_hold_ms=320), sessions=100)
    frozen = batch(lock, ControlConfig(maximum_hold_ms=320,
                                       auto_raise_hold_cap=False), sessions=100)
    check("1200 ms katto avaa", generous["success"] > 0.85,
          f"{generous['success'] * 100:.1f} %")
    check("liian lyhyt katto korjautuu itse mitatusta kaannosta",
          tight["success"] > 0.80, f"{tight['success'] * 100:.1f} %")
    check("ilman itsekorjausta sama katto estaa avaamisen",
          frozen["success"] < 0.05, f"{frozen['success'] * 100:.1f} %")


def test_no_input_without_detection() -> None:
    print("Ilman tunnistusta ei laheteta syotteita")
    controller = Controller(ControlConfig())
    action = controller.update(0.0, Observation(ok=False))
    check("hiiri ei liiku", action.mouse_units == 0.0)
    check("F ei mene pohjaan", action.f_down is False)


def test_no_false_walls() -> None:
    """Vaarin opittu aariasento jumittaisi haun yhteen kohtaan."""
    print("Reunoja ei opita vaarin")
    rng = random.Random(7)
    cfg = ControlConfig()
    _, controller = run_attempt(LockConfig(tier="basic", skill=3), cfg, rng, 0.035)
    check("hakualue ei kutistunut",
          controller.edge_high - controller.edge_low >= 100.0,
          f"{controller.edge_low:+.1f} .. {controller.edge_high:+.1f}")
    scans = [p.pick for p in controller.probes if not p.ramp]
    unique = len(set(round(x, 1) for x in scans))
    check("skannaus ei jaa toistamaan samaa pistetta",
          unique >= max(1, len(scans) - 1), f"{unique} eri pistetta / {len(scans)} testia")


def test_probe_range() -> None:
    print("Testipisteet pysyvat janalla")
    rng = random.Random(31)
    cfg = ControlConfig()
    probes = []
    for _ in range(6):        # kerataan useasta yrityksesta, koska hyva
        _, controller = run_attempt(  # osuma voi avata lukon ennen ensimmaista kirjausta
            LockConfig(tier="medium", skill=2), cfg, rng, 0.035)
        probes += controller.probes
    check("testeja kertyi", len(probes) > 10, f"{len(probes)} testia")
    check("kaikki testit valilla -80..80",
          all(PICK_MIN - 0.01 <= p.pick <= PICK_MAX + 0.01 for p in probes))


def main() -> int:
    for test in [
        test_opens_simulated_lock,
        test_left_to_right_order,
        test_rising_turn_is_never_cut,
        test_survives_wrong_sensitivity,
        test_sensitivity_estimator_converges,
        test_short_hold_cap_still_opens,
        test_no_input_without_detection,
        test_no_false_walls,
        test_probe_range,
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
