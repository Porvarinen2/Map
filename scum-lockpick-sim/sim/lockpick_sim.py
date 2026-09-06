"""SCUM-lukkosimulaattori: ajaa autolockpick-ohjainta ilman peliä.

Kayttoesimerkkeja:

    python lockpick_sim.py --tier basic --skill 1 --sessions 400
    python lockpick_sim.py --tier enforced --skill 3 --scan-order center-out
    python lockpick_sim.py --compare-orders --tier medium
    python lockpick_sim.py --sweep-step 4 6 8 10 12 14 --tier basic
    python lockpick_sim.py --settings ../../asetukset.json --tier basic

Simulaatio ei ole pelin onnistumisprosentti. Se on tyokalu, jolla naet miten
skannausvali, hiiren nopeus ja naytonlukuviive vaikuttavat siihen, montako
F-testia 2.75-4.25 sekuntiin ehtii.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lockpick_model import (  # noqa: E402
    LOCK_TIERS,
    PICK_MAX,
    PICK_MIN,
    SKILL_NAMES,
    TIER_ORDER,
    LockAttempt,
    LockConfig,
    SessionResult,
    guaranteed_scan_step,
)
from solver import AutoLockpick, SolverConfig  # noqa: E402

DT = 0.002  # simulaation aika-askel sekunteina


def run_attempt(lock_cfg: LockConfig, solver_cfg: SolverConfig, rng: random.Random,
                start_pick: float, carried_wear: float, sweet_spot: float | None):
    attempt = LockAttempt(lock_cfg, rng, sweet_spot=sweet_spot)
    attempt.wear = carried_wear
    attempt.pick = start_pick

    bot = AutoLockpick(solver_cfg, rng, start_pick=start_pick)
    bot.log.sweet_spot = attempt.sweet_spot

    t = 0.0
    guard = int(attempt.time_limit / DT) + 50
    for _ in range(guard):
        if attempt.finished:
            break
        pick_target, f_down = bot.step(t, DT, attempt.snapshot())
        attempt.step(DT, pick_target, f_down)
        t += DT

    if attempt.opened:
        bot.log.result = "opened"
    elif attempt.broken:
        bot.log.result = "broken"
    else:
        bot.log.result = "timeout"
    bot.log.seconds = attempt.time

    return attempt, bot


def run_session(lock_cfg: LockConfig, solver_cfg: SolverConfig, rng: random.Random,
                max_attempts: int, spare_picks: int, keep_trace: bool = False) -> SessionResult:
    result = SessionResult()
    pick_angle = 0.0
    wear = 0.0
    picks_left = spare_picks
    fixed_spot = None

    if not lock_cfg.reroll_sweet_spot:
        margin = lock_cfg.zone_half * 0.25
        fixed_spot = rng.uniform(PICK_MIN + margin, PICK_MAX - margin)

    for attempt_no in range(1, max_attempts + 1):
        attempt, bot = run_attempt(
            lock_cfg, solver_cfg, rng, pick_angle, wear, fixed_spot
        )
        result.attempts = attempt_no
        result.total_seconds += attempt.time
        result.probes += len(bot.log.probes)
        if keep_trace:
            result.trace.append(bot.log)

        if attempt.opened:
            result.opened = True
            result.opening_attempt = attempt_no
            result.reason = "opened"
            return result

        if attempt.broken:
            result.broken_picks += 1
            picks_left -= 1
            wear = 0.0
            pick_angle = 0.0
            if picks_left <= 0:
                result.reason = "out of lockpicks"
                return result
        else:
            result.timeouts += 1
            wear = attempt.wear
            pick_angle = attempt.pick

    result.reason = "attempt limit"
    return result


def batch(lock_cfg: LockConfig, solver_cfg: SolverConfig, sessions: int,
          max_attempts: int, spare_picks: int, seed: int) -> dict:
    rng = random.Random(seed)
    opened = 0
    attempts_to_open: list[int] = []
    seconds_to_open: list[float] = []
    broken = 0
    probes: list[int] = []
    first_attempt_open = 0

    for _ in range(sessions):
        res = run_session(lock_cfg, solver_cfg, rng, max_attempts, spare_picks)
        broken += res.broken_picks
        probes.append(res.probes)
        if res.opened:
            opened += 1
            attempts_to_open.append(res.opening_attempt or 0)
            seconds_to_open.append(res.total_seconds)
            if res.opening_attempt == 1:
                first_attempt_open += 1

    return {
        "sessions": sessions,
        "success_rate": opened / sessions,
        "first_attempt_rate": first_attempt_open / sessions,
        "mean_attempts": statistics.fmean(attempts_to_open) if attempts_to_open else float("nan"),
        "mean_seconds": statistics.fmean(seconds_to_open) if seconds_to_open else float("nan"),
        "broken_per_session": broken / sessions,
        "mean_probes": statistics.fmean(probes) if probes else 0.0,
    }


# --------------------------------------------------------------------------
# Tulostus
# --------------------------------------------------------------------------


def print_conditions(lock_cfg: LockConfig, solver_cfg: SolverConfig) -> None:
    tier = lock_cfg.tier_data()
    probe_ms = estimate_probe_ms(lock_cfg, solver_cfg)
    budget = lock_cfg.attempt_seconds * 1000.0 / probe_ms
    span = PICK_MAX - PICK_MIN
    needed = span / solver_cfg.scan_step_degrees + 1

    print(f"Lukko           {tier.name}  (palautealue +-{lock_cfg.zone_half:.1f} deg, "
          f"ydin +-{lock_cfg.core_half:.2f} deg)")
    print(f"Thievery        {SKILL_NAMES[lock_cfg.skill]}  ->  aikaa {lock_cfg.attempt_seconds:.2f} s")
    print(f"Tiirikka        {lock_cfg.tool_data().name}")
    print(f"Hakutapa        {solver_cfg.scan_order}, skannausvali {solver_cfg.scan_step_degrees:.1f} deg")
    print(f"Hiiri           {solver_cfg.scan_speed():.0f} deg/s skannauksessa, "
          f"{solver_cfg.ramp_speed():.0f} deg/s rampilla")
    print(f"Nako            viive {solver_cfg.vision_latency_ms:.0f} ms, "
          f"ruutuvali {solver_cfg.vision_frame_ms:.1f} ms  ->  "
          f"lyhyin hyodyllinen F-pito {solver_cfg.effective_min_hold_ms():.0f} ms")
    print(f"Yksi F-testi    ~{probe_ms:.0f} ms  ->  ~{budget:.1f} testia per yritys")
    print(f"Koko jana       {span:.0f} deg vaatii {needed:.0f} testia; "
          f"varma skannausvali on enintaan {guaranteed_scan_step(lock_cfg):.1f} deg")
    if budget < needed:
        print(f"  HUOM: yksi yritys ei riita koko janaan ({budget:.1f} < {needed:.0f}).")
    print()


def estimate_probe_ms(lock_cfg: LockConfig, solver_cfg: SolverConfig) -> float:
    """Karkea arvio yhden F-testin kestosta: matka + pito + palautuminen."""
    travel = solver_cfg.scan_step_degrees / max(1e-6, solver_cfg.scan_speed()) * 1000.0
    hold = solver_cfg.effective_min_hold_ms()
    # pesa palautuu nollaan ja se on viela nahtava
    from lockpick_model import RETURN_RATE, TURN_RATE

    turned = min(TURN_RATE * hold / 1000.0, 90.0)
    release = turned / RETURN_RATE * 1000.0 + solver_cfg.vision_latency_ms + solver_cfg.release_settle_ms
    return travel + hold + release


def print_row(label: str, stats: dict, width: int = 22) -> None:
    print(
        f"{label:<{width}} {stats['success_rate'] * 100:6.1f} %"
        f"{stats['first_attempt_rate'] * 100:9.1f} %"
        f"{stats['mean_attempts']:9.2f}"
        f"{stats['mean_seconds']:10.2f} s"
        f"{stats['mean_probes']:9.1f}"
        f"{stats['broken_per_session']:10.2f}"
    )


def print_header(first_col: str, width: int = 22) -> None:
    print(f"{first_col:<{width}} {'avautui':>8}{'1. yrit.':>11}{'yrityksia':>9}{'aikaa':>12}{'testeja':>9}{'rikki':>10}")
    print("-" * (width + 60))


# --------------------------------------------------------------------------


def load_settings_into(solver_cfg: SolverConfig, path: str) -> None:
    """Lukee helperin asetukset.jsonin ne avaimet jotka simulaatio tuntee."""
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)

    mapping = {
        "scan_step_degrees": "scan_step_degrees",
        "climb_step_degrees": "climb_step_degrees",
        "minimum_climb_step_degrees": "minimum_climb_step_degrees",
        "movement_found_degrees": "movement_found_degrees",
        "near_open_degrees": "near_open_degrees",
        "initial_degrees_per_mouse_unit": "degrees_per_mouse_unit",
        "scan_mouse_max_units_per_pulse": "scan_mouse_max_units_per_pulse",
        "ramp_mouse_max_units_per_pulse": "ramp_mouse_max_units_per_pulse",
        "mouse_settle_ms": "mouse_settle_ms",
        "no_motion_release_ms": "scan_hold_ms",
        "maximum_F_hold_ms": "maximum_f_hold_ms",
    }
    used = []
    for json_key, attr in mapping.items():
        if json_key in data:
            setattr(solver_cfg, attr, float(data[json_key]))
            used.append(json_key)
    print(f"Luettu {path}: {len(used)} avainta ({', '.join(used)})\n")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="SCUM-tyyppisen lukkominipelin ja autolockpickin simulaattori.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--tier", choices=TIER_ORDER, default="basic")
    p.add_argument("--skill", type=int, choices=[0, 1, 2, 3], default=1,
                   help="thievery: 0 ei taitoa, 3 advanced")
    p.add_argument("--tool", choices=["improvised", "lockpick", "advanced"], default="lockpick")
    p.add_argument("--sessions", type=int, default=400)
    p.add_argument("--max-attempts", type=int, default=6)
    p.add_argument("--spare-picks", type=int, default=3)
    p.add_argument("--seed", type=int, default=20260906)
    p.add_argument("--fixed-sweet-spot", action="store_true",
                   help="sweetspot pysyy samana yritysten valilla")

    p.add_argument("--scan-order", choices=["left-to-right", "center-out", "from-current", "random"],
                   default="left-to-right")
    p.add_argument("--scan-step", type=float, default=6.0)
    p.add_argument("--climb-step", type=float, default=2.5)
    p.add_argument("--deg-per-unit", type=float, default=0.035)
    p.add_argument("--scan-units", type=float, default=28.0)
    p.add_argument("--ramp-units", type=float, default=12.0)
    p.add_argument("--settle-ms", type=float, default=30.0)
    p.add_argument("--hold-ms", type=float, default=55.0)
    p.add_argument("--ramp-hold-ms", type=float, default=260.0)
    p.add_argument("--latency-ms", type=float, default=50.0)
    p.add_argument("--frame-ms", type=float, default=8.3)

    p.add_argument("--settings", help="lue arvot helperin asetukset.json-tiedostosta")

    p.add_argument("--compare-orders", action="store_true", help="vertaa nelja hakutapaa")
    p.add_argument("--compare-tiers", action="store_true", help="vertaa nelja lukkotyyppia")
    p.add_argument("--sweep-step", type=float, nargs="+", help="vertaa skannausvaleja")
    p.add_argument("--sweep-latency", type=float, nargs="+", help="vertaa naytonlukuviiveita")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    lock_cfg = LockConfig(
        tier=args.tier,
        skill=args.skill,
        tool=args.tool,
        reroll_sweet_spot=not args.fixed_sweet_spot,
    )
    solver_cfg = SolverConfig(
        scan_order=args.scan_order,
        scan_step_degrees=args.scan_step,
        climb_step_degrees=args.climb_step,
        degrees_per_mouse_unit=args.deg_per_unit,
        scan_mouse_max_units_per_pulse=args.scan_units,
        ramp_mouse_max_units_per_pulse=args.ramp_units,
        mouse_settle_ms=args.settle_ms,
        scan_hold_ms=args.hold_ms,
        ramp_hold_ms=args.ramp_hold_ms,
        vision_latency_ms=args.latency_ms,
        vision_frame_ms=args.frame_ms,
    )
    if args.settings:
        load_settings_into(solver_cfg, args.settings)

    print("=" * 82)
    print("SCUM LOCKPICK -SIMULAATIO")
    print("=" * 82)
    print_conditions(lock_cfg, solver_cfg)

    common = dict(
        sessions=args.sessions,
        max_attempts=args.max_attempts,
        spare_picks=args.spare_picks,
        seed=args.seed,
    )

    if args.compare_orders:
        print_header("hakutapa")
        for order in ["left-to-right", "center-out", "from-current", "random"]:
            cfg = SolverConfig(**{**solver_cfg.__dict__, "scan_order": order})
            print_row(order, batch(lock_cfg, cfg, **common))
        print()

    if args.compare_tiers:
        print_header("lukkotyyppi")
        for tier in TIER_ORDER:
            lc = LockConfig(tier=tier, skill=args.skill, tool=args.tool,
                            reroll_sweet_spot=not args.fixed_sweet_spot)
            print_row(f"{LOCK_TIERS[tier].name}", batch(lc, solver_cfg, **common))
        print()

    if args.sweep_step:
        print_header("skannausvali")
        for step in args.sweep_step:
            cfg = SolverConfig(**{**solver_cfg.__dict__, "scan_step_degrees": step})
            label = f"{step:.1f} deg"
            if step > guaranteed_scan_step(lock_cfg):
                label += "  (yli alueen!)"
            print_row(label, batch(lock_cfg, cfg, **common))
        print()

    if args.sweep_latency:
        print_header("naytonlukuviive")
        for latency in args.sweep_latency:
            cfg = SolverConfig(**{**solver_cfg.__dict__, "vision_latency_ms": latency})
            print_row(f"{latency:.0f} ms", batch(lock_cfg, cfg, **common))
        print()

    if not (args.compare_orders or args.compare_tiers or args.sweep_step or args.sweep_latency):
        print_header("nykyasetukset")
        print_row(f"{args.scan_order} {args.scan_step:.0f} deg", batch(lock_cfg, solver_cfg, **common))
        print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
