"""Simulaation tarkistustestit: python test_sim.py"""

from __future__ import annotations

import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lockpick_model import (  # noqa: E402
    LOCK_TIERS,
    OPEN_TURN,
    PICK_MAX,
    PICK_MIN,
    TIER_ORDER,
    TURN_RATE,
    LockAttempt,
    LockConfig,
)
from lockpick_sim import batch, run_attempt  # noqa: E402
from solver import SolverConfig  # noqa: E402

FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  OK    {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


def fast_solver(**overrides) -> SolverConfig:
    base = dict(
        scan_order="from-current",
        scan_step_degrees=6.0,
        scan_mouse_max_units_per_pulse=120.0,
        mouse_settle_ms=16.0,
        vision_latency_ms=35.0,
    )
    base.update(overrides)
    return SolverConfig(**base)


def test_response_curve() -> None:
    print("Palautekayra")
    for key in TIER_ORDER:
        cfg = LockConfig(tier=key, skill=0)
        attempt = LockAttempt(cfg, random.Random(1), sweet_spot=0.0)
        tier = LOCK_TIERS[key]

        check(f"{tier.name}: ydin avaa", attempt.max_turn_at(0.0) == OPEN_TURN)
        check(
            f"{tier.name}: ytimen reuna avaa viela",
            attempt.max_turn_at(cfg.core_half - 0.01) == OPEN_TURN,
        )
        check(
            f"{tier.name}: ytimen ulkopuolella vain osittainen kaanto",
            0 < attempt.max_turn_at(cfg.core_half + 0.05) <= tier.give_max + 1e-6,
        )
        check(
            f"{tier.name}: alueen ulkopuolella ei liiketta",
            attempt.max_turn_at(cfg.zone_half + 0.5) == 0.0,
        )
        check(
            f"{tier.name}: kaanto kasvaa ydinta kohti",
            attempt.max_turn_at(cfg.zone_half - 1.0)
            < attempt.max_turn_at(cfg.core_half + 0.1),
        )


def test_tier_ordering() -> None:
    print("Vaikeusjarjestys")
    cores = [LockConfig(tier=k, skill=0).core_half for k in TIER_ORDER]
    check("ydin kapenee vaikeamman lukon myota", cores == sorted(cores, reverse=True),
          str(cores))
    gives = [LOCK_TIERS[k].give_max for k in TIER_ORDER]
    check("vihje heikkenee vaikeamman lukon myota", gives == sorted(gives, reverse=True),
          str(gives))
    wear = [LOCK_TIERS[k].wear_rate for k in TIER_ORDER]
    check("kuluminen kiihtyy vaikeamman lukon myota", wear == sorted(wear), str(wear))


def test_skill_effects() -> None:
    print("Thievery-taito")
    times = [LockConfig(skill=s).attempt_seconds for s in range(4)]
    check("aika kasvaa taidon myota", times == sorted(times) and times[0] == 2.75, str(times))
    check("advanced antaa 4.25 s", abs(times[3] - 4.25) < 1e-9, str(times[3]))
    widths = [LockConfig(skill=s).core_half for s in range(4)]
    check("sweetspot levenee taidon myota", widths == sorted(widths), str(widths))


def test_manual_open() -> None:
    """Kasin ajettu taydellinen suoritus avaa lukon."""
    print("Suora avaus ytimesta")
    cfg = LockConfig(tier="enforced", skill=0)
    attempt = LockAttempt(cfg, random.Random(2), sweet_spot=12.0)
    t = 0.0
    while not attempt.finished:
        attempt.step(0.002, 12.0, True)
        t += 0.002
    check("aukeaa kun tiirikka on ytimessa", attempt.opened, attempt.snapshot().__str__())
    check("aukeaa taysin kaannon ajassa",
          abs(t - OPEN_TURN / TURN_RATE) < 0.02, f"{t:.3f} s")


def test_wrong_spot_breaks() -> None:
    print("Vaara kohta kuluttaa tiirikan")
    cfg = LockConfig(tier="enforced", skill=0, tool="improvised")
    attempt = LockAttempt(cfg, random.Random(3), sweet_spot=60.0)
    while not attempt.finished:
        attempt.step(0.002, -60.0, True)   # kaukana sweetspotista, F pohjassa
    check("tiirikka menee poikki tai aika loppuu", attempt.broken or attempt.timed_out)
    check("kuluma kertyi", attempt.wear > 0, f"{attempt.wear:.1f}")


def test_hold_cap_cliff() -> None:
    """F:n kattoajan on ylitettava taydan kaannon kesto, muuten lukko ei aukea."""
    print("F:n kattoaika")
    full_turn_ms = OPEN_TURN / TURN_RATE * 1000.0
    lock = LockConfig(tier="basic", skill=1)
    common = dict(sessions=120, max_attempts=5, spare_picks=3, seed=7)

    too_short = batch(lock, fast_solver(maximum_f_hold_ms=full_turn_ms - 40), **common)
    long_enough = batch(lock, fast_solver(maximum_f_hold_ms=full_turn_ms + 60), **common)

    check("liian lyhyt katto ei avaa koskaan", too_short["success_rate"] == 0.0,
          f"{too_short['success_rate']:.3f}")
    check("riittava katto avaa", long_enough["success_rate"] > 0.7,
          f"{long_enough['success_rate']:.3f}")


def test_scan_step_coverage() -> None:
    """Liian harva skannaus hyppaa palautealueen yli."""
    print("Skannausvalin kattavuus")
    lock = LockConfig(tier="enforced", skill=0)
    common = dict(sessions=200, max_attempts=1, spare_picks=3, seed=11)
    safe = 2 * lock.zone_half

    dense = batch(lock, fast_solver(scan_step_degrees=safe * 0.6), **common)
    sparse = batch(lock, fast_solver(scan_step_degrees=safe * 2.2), **common)
    check("tihea skannaus loytaa alueen useammin",
          dense["success_rate"] > sparse["success_rate"],
          f"{dense['success_rate']:.2f} vs {sparse['success_rate']:.2f}")


def test_vision_latency_costs() -> None:
    print("Naytonlukuviive")
    lock = LockConfig(tier="basic", skill=1)
    # Yksi yritys per sessio, jotta mean_probes on testeja per yritys eika
    # koko session summa (nopea ohjain avaa aiemmin ja ehtii vahemman yrityksia).
    common = dict(sessions=200, max_attempts=1, spare_picks=3, seed=13)
    quick = batch(lock, fast_solver(vision_latency_ms=15), **common)
    slow = batch(lock, fast_solver(vision_latency_ms=140), **common)
    check("pieni viive tuottaa enemman F-testeja yritysta kohti",
          quick["mean_probes"] > slow["mean_probes"],
          f"{quick['mean_probes']:.1f} vs {slow['mean_probes']:.1f}")
    check("pieni viive avaa useammin",
          quick["success_rate"] >= slow["success_rate"],
          f"{quick['success_rate']:.2f} vs {slow['success_rate']:.2f}")


def test_pick_range_clamped() -> None:
    print("Tiirikan rajat")
    cfg = LockConfig()
    attempt = LockAttempt(cfg, random.Random(5), sweet_spot=0.0)
    attempt.step(0.002, 500.0, False)
    check("ylaraja pitaa", attempt.pick == PICK_MAX, str(attempt.pick))
    attempt.step(0.002, -500.0, False)
    check("alaraja pitaa", attempt.pick == PICK_MIN, str(attempt.pick))


def test_determinism() -> None:
    print("Toistettavuus")
    lock = LockConfig(tier="medium", skill=1)
    a = batch(lock, fast_solver(), sessions=80, max_attempts=4, spare_picks=3, seed=99)
    b = batch(lock, fast_solver(), sessions=80, max_attempts=4, spare_picks=3, seed=99)
    check("sama siemen antaa saman tuloksen", a == b)


def test_solver_records_probes() -> None:
    print("Ohjaimen loki")
    attempt, bot = run_attempt(
        LockConfig(tier="basic", skill=1), fast_solver(), random.Random(17), 0.0, 0.0, 20.0
    )
    check("F-testeja kirjattiin", len(bot.log.probes) > 0, str(len(bot.log.probes)))
    check("kaikki testit janalla",
          all(PICK_MIN - 0.01 <= p.pick <= PICK_MAX + 0.01 for p in bot.log.probes))


def main() -> int:
    for test in [
        test_response_curve,
        test_tier_ordering,
        test_skill_effects,
        test_manual_open,
        test_wrong_spot_breaks,
        test_hold_cap_cliff,
        test_scan_step_coverage,
        test_vision_latency_costs,
        test_pick_range_clamped,
        test_determinism,
        test_solver_records_probes,
    ]:
        test()
        print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki testit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
