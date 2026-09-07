# -*- coding: utf-8 -*-
"""Offline lock simulator + learning-curve measurement.

The learning code under test is the REAL one: Config, QModel, RewardEngine and
nearest_action are imported from lockpick_learner, and the decision loop below
mirrors agent() exactly. Only the game and the mouse are simulated.

The lock model is fitted to 264 real probes from 50 recorded human attempts:

  distance from the opening point   measured mean response
      0.00 - 0.05                        0.727
      0.10 - 0.20                        0.348
      0.20 - 0.35                        0.356
      0.35 - 0.55                        0.167
      0.55 - 1.00                        0.064

  response = exp(-distance / response_falloff), plus the measured 1-degree
  quantisation and noise floor. Rotation accumulates within an attempt, which
  is why a later probe reads high even after the pick has moved away.

The ONE thing the recordings cannot pin down is how close you have to be for
the lock to actually open: the recorded response is only the peak of the first
145 ms of a press, so a win looks the same as a near miss. So it is not
guessed - it is swept, and every result is reported per target width.

    python simulaattori.py                  learning curve, default sweep
    python simulaattori.py --yritykset 4000 longer run
    python simulaattori.py --tallenna       write the trained model to data\
"""
from __future__ import annotations

import argparse
import math
import random
import sys
import types
from pathlib import Path
from typing import List, Optional, Tuple

import numpy as np

for _n in ("cv2", "mss"):
    if _n not in sys.modules:
        sys.modules[_n] = types.ModuleType(_n)

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import lockpick_learner as LL  # noqa: E402


class Lukko:
    """One lock attempt, fitted to the recorded human data."""

    KOHINA = 0.033            # measured: a still lock reads 0.022-0.033
    ASKEL = 1.0 / 90.0        # the rotation detector works in 1-degree steps
    VAIMENNUS = 0.25          # response = exp(-d / 0.25), fitted to the table above

    def __init__(self, target_puolikas: float, rng: random.Random):
        self.rng = rng
        self.target = rng.uniform(0.06, 0.94)
        self.w = target_puolikas
        self.kaanto = 0.0     # accumulated rotation, persists between probes
        self.auki = False

    def probe(self, pos: float, pitka: bool = False) -> float:
        """Press F at pos. Returns what the rotation detector would read."""
        d = abs(pos - self.target)
        tuore = math.exp(-d / self.VAIMENNUS)
        # A press near the target pushes the cylinder further round; the
        # cylinder stays where it was pushed.
        self.kaanto = max(self.kaanto, tuore)
        if d <= self.w and (pitka or self.kaanto >= 0.82):
            self.auki = True
        lukema = max(self.kaanto, self.KOHINA)
        lukema += self.rng.gauss(0.0, 0.012)
        return float(np.clip(round(lukema / self.ASKEL) * self.ASKEL, 0.0, 1.0))


def yritys(cfg, model, rewarder, lukko: Lukko, oppii: bool, rng: random.Random
           ) -> Tuple[bool, float, int]:
    """One attempt. Mirrors agent()'s decision loop exactly."""
    pos = 0.0
    prev_response = 0.0
    best = 0.0
    found_ramp = False
    ramp_hits = 0
    ramp_pos: Optional[float] = None
    offset_used = False
    last_key = last_action = None
    total_reward = 0.0
    probe_aika = 0.55                     # measured: 2.67 s / ~5 probes
    kulunut = 0.0
    rivit: List[dict] = []

    grid = [(i + 0.5) / cfg.search_cells for i in range(cfg.search_cells)]
    grid_i = 0
    refining = False
    best_pos = pos
    refine_step = 1.0 / (2 * cfg.search_cells)

    response = lukko.probe(pos)
    kulunut += probe_aika
    total_reward += rewarder.step(response, prev_response, best, probe_aika)
    best = max(best, response)
    best_pos = pos
    prev_response = response
    if response >= cfg.wobble_threshold:
        ramp_hits += 1
        if ramp_pos is None:
            ramp_pos = pos
    found_ramp = ramp_hits >= cfg.wobble_confirm_probes

    while not lukko.auki and kulunut < cfg.attempt_budget_seconds + 0.45:
        if best >= cfg.success_progress:
            lukko.probe(pos, pitka=True)          # the finishing hold
            if lukko.auki:
                break

        trend = 1 if response > prev_response + 0.018 else (-1 if response + 0.018 < prev_response else 0)
        key = model.state_key(pos, response, best, trend, found_ramp, ramp_pos)
        d = model.decision_details(key, deterministic=not oppii)
        action = int(d["action"])
        delta = cfg.action_steps[action]

        learned = model.learned_offset()
        if learned is not None and not offset_used and found_ramp and ramp_pos is not None:
            target = float(np.clip(ramp_pos + learned, 0.0, 1.0))
            offset_used = True
            refining = True
        elif not refining and grid_i < len(grid):
            target = grid[grid_i]
            grid_i += 1
        else:
            refining = True
            suunta = -1.0 if delta < 0 else 1.0
            target = float(np.clip(best_pos + suunta * refine_step, 0.0, 1.0))
            if abs(target - pos) < 1e-4:
                target = float(np.clip(best_pos - suunta * refine_step, 0.0, 1.0))
        delta = target - pos
        action = LL.nearest_action(cfg, delta)

        pos = target
        edellinen = response
        response = lukko.probe(pos, pitka=refining)
        kulunut += probe_aika
        palkkio = rewarder.step(response, edellinen, best, probe_aika)
        total_reward += palkkio
        if response > best:
            best = response
            best_pos = pos
        elif refining:
            refine_step = max(cfg.ramp_microstep, refine_step * 0.5)

        if response >= cfg.wobble_threshold:
            ramp_hits += 1
            if ramp_pos is None:
                ramp_pos = pos
        next_found = ramp_hits >= cfg.wobble_confirm_probes
        next_trend = 1 if response > edellinen + 0.018 else (-1 if response + 0.018 < edellinen else 0)
        next_key = model.state_key(pos, response, best, next_trend, next_found, ramp_pos)
        if oppii:
            model.update(key, action, palkkio, next_key)
        last_key, last_action = key, action
        rivit.append({"state": key, "action": action, "delta": delta,
                      "reward": palkkio, "next_state": next_key, "terminal": 0})
        prev_response = edellinen
        found_ramp = next_found

    if lukko.auki:
        bonus = rewarder.success(kulunut)
        total_reward += bonus
        if oppii:
            if last_key is not None:
                model.terminal_update(last_key, last_action, bonus)
            model.note_success(ramp_pos, pos)
            model.total_successes += 1
    else:
        total_reward += cfg.reward.fail_penalty
        if oppii and last_key is not None:
            model.terminal_update(last_key, last_action, cfg.reward.fail_penalty)
    if oppii:
        model.total_attempts += 1
        if rivit:
            rivit[-1]["reward"] += (rewarder.success(kulunut) if lukko.auki else cfg.reward.fail_penalty)
            rivit[-1]["terminal"] = 1
            LL.replay_episode_rows(cfg, model, [{k: str(v) for k, v in r.items()} for r in rivit],
                                   cfg.selfplay_success_replay_passes if lukko.auki else cfg.selfplay_fail_replay_passes)
    return lukko.auki, total_reward, len(rivit) + 1


def aja(cfg, target_puolikas: float, yrityksia: int, siemen: int, tyhja: bool = True):
    rng = random.Random(siemen)
    model = LL.QModel.__new__(LL.QModel)
    model.cfg = cfg
    model.q = {}
    model.demo_prior = {}
    model.calibration = {}
    model.epsilon = cfg.epsilon_start
    model.success_offsets = []
    for f in ("total_successes", "total_attempts", "total_updates", "human_episodes",
              "human_successes", "human_failures", "human_incomplete", "selfplay_episodes",
              "selfplay_successes", "selfplay_failures", "selfplay_replay_updates"):
        setattr(model, f, 0)
    if not tyhja:
        oikea = LL.QModel(cfg)
        model.q = dict(oikea.q)
        model.demo_prior = dict(oikea.demo_prior)
    rewarder = LL.RewardEngine(cfg)
    tulokset = []
    for _ in range(yrityksia):
        ok, palkkio, probet = yritys(cfg, model, rewarder, Lukko(target_puolikas, rng), True, rng)
        tulokset.append((ok, palkkio, probet))
    return model, tulokset


def kayra(tulokset, ikkuna: int = 100) -> List[float]:
    ulos = []
    for i in range(0, len(tulokset) - ikkuna + 1, ikkuna):
        osa = tulokset[i:i + ikkuna]
        ulos.append(100.0 * sum(1 for t in osa if t[0]) / len(osa))
    return ulos


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--yritykset", type=int, default=2000)
    ap.add_argument("--siemenia", type=int, default=5)
    ap.add_argument("--tallenna", action="store_true")
    a = ap.parse_args()

    cfg = LL.Config()
    print("=== LUKKOSIMULAATTORI - sovitettu 264 oikeaan probeen ===")
    print(f"wobble_threshold={cfg.wobble_threshold}  search_cells={cfg.search_cells}  "
          f"budjetti={cfg.attempt_budget_seconds}s  ~5.6 probea/yritys\n")
    print("Target-puolileveys on ainoa asia jota nauhoituksista ei voi paatella,")
    print("joten se pyyhkaistaan lapi. Onnistumis-% 100 yrityksen ikkunoissa:\n")
    print(f"{'target':>8} {'1-100':>8} {'2. sata':>8} {'3. sata':>8} {'viim.100':>9} "
          f"{'kaikki':>8} {'probeja':>8}")
    for w in (0.015, 0.025, 0.04, 0.06, 0.10):
        rivit = []
        for s in range(a.siemenia):
            _m, t = aja(cfg, w, a.yritykset, 1000 + s)
            rivit.append(t)
        ks = [kayra(t) for t in rivit]
        n = min(len(k) for k in ks)
        ka = [float(np.mean([k[i] for k in ks])) for i in range(n)]
        kaikki = float(np.mean([100.0 * sum(1 for x in t if x[0]) / len(t) for t in rivit]))
        probet = float(np.mean([np.mean([x[2] for x in t]) for t in rivit]))
        print(f"{w:8.3f} {ka[0]:7.1f}% {ka[1] if n>1 else float('nan'):7.1f}% "
              f"{ka[2] if n>2 else float('nan'):7.1f}% {ka[-1]:8.1f}% {kaikki:7.1f}% {probet:8.1f}")

    print("\nVERTAILU: mita sama koodi teki ENNEN korjausta")
    vanha = LL.Config()
    vanha.wobble_threshold = 0.025
    vanha.wobble_confirm_probes = 1
    vanha.search_cells = 25          # 0.04 kerrallaan = vanha kayttaytyminen
    vanha.action_steps = [-0.12, -0.07, -0.04, -0.022, -0.010, 0.0, 0.010, 0.022, 0.04, 0.07, 0.12]
    for w in (0.025, 0.06):
        yht = []
        for s in range(a.siemenia):
            _m, t = aja(vanha, w, min(600, a.yritykset), 1000 + s)
            yht.append(100.0 * sum(1 for x in t if x[0]) / len(t))
        print(f"  target {w:.3f}: vanha {np.mean(yht):5.1f}%")

    if a.tallenna:
        model, t = aja(cfg, 0.04, a.yritykset, 7, tyhja=False)
        model.save()
        print(f"\nTallennettu data\\model.json  ({100*sum(1 for x in t if x[0])/len(t):.1f}% lopussa)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
