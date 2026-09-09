from __future__ import annotations

import csv
import json
import math
import random
import shutil
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.distributions import Categorical

import lockpick_learner as classic
import neural_lockpick_learner as base

APP_NAME = "Lockpick Learner v0.7 FAST"
ROOT = Path(__file__).resolve().parent
FAST_CONFIG_PATH = ROOT / "config_neural_fast.json"
ELITE_REPLAY = base.NEURAL_DIR / "elite_replay.csv"
BC_LOG = base.AUDIT_DIR / "behavior_cloning.csv"
BEST_TRAIN_CKPT = base.NEURAL_DIR / "ppo_best_training.pt"
RESCUE_CKPT = base.NEURAL_DIR / "ppo_before_bc_rescue.pt"


@dataclass
class FastConfig(base.NeuralConfig):
    # v0.6 logs showed dead-zone visual responses around 0.045-0.056. 0.025 was
    # therefore too permissive as a neural "ramp found" threshold.
    learning_wobble_threshold: float = 0.085

    # Fast exploration -> exploitation schedule. Existing v0.6 entropy_coef can
    # stay in config_neural.json; this module caps the effective coefficient.
    entropy_fast_cap: float = 0.008
    entropy_min: float = 0.0010
    entropy_decay_per_update: float = 0.965

    # Reward shaping for rapid credit assignment.
    success_reward_fast: float = 120.0
    speed_bonus_fast: float = 55.0
    first_wobble_bonus: float = 5.0
    progress_gain_fast: float = 34.0
    new_best_bonus_fast: float = 10.0
    regression_penalty_fast: float = 10.0
    probe_cost_fast: float = 0.06
    time_cost_fast: float = 0.45
    boundary_penalty_fast: float = 0.75
    search_right_bonus: float = 0.18
    search_wrong_way_penalty: float = 1.25
    adaptive_fail_min_scale: float = 0.35

    # Curriculum masks are based only on visible state; they never reveal target.
    curriculum_action_masks: bool = True
    search_min_positive_step: float = 0.010
    ramp_max_abs_step: float = 0.040
    near_threshold: float = 0.22
    near_max_abs_step: float = 0.022
    target_threshold: float = 0.58
    target_max_abs_step: float = 0.010

    # Human demonstration pretraining.
    bc_epochs: int = 28
    bc_batch_size: int = 128
    bc_learning_rate: float = 8e-4
    bc_hold_loss_weight: float = 0.18
    bc_success_weight: float = 6.0
    bc_success_tail_boost: float = 3.0
    bc_fail_helpful_weight: float = 1.0
    bc_fail_bad_weight: float = 0.65
    bc_mixed_weight: float = 0.35
    bc_max_samples: int = 20000
    auto_pretrain_after_teach: bool = True
    reset_actor_if_zero_success: bool = True

    # A tiny rehearsal after every PPO update prevents catastrophic forgetting.
    auxiliary_human_epochs: int = 1
    auxiliary_human_max_samples: int = 1536
    auxiliary_human_lr: float = 1.8e-4

    # PPO itself remains strictly on-policy. Old successes/near-successes are used
    # only by an auxiliary supervised distillation loss.
    elite_replay_capacity: int = 6000
    elite_success_weight: float = 7.0
    elite_near_best_threshold: float = 0.18
    elite_positive_reward_threshold: float = 0.35
    elite_aux_epochs: int = 2
    elite_aux_max_samples: int = 1536
    elite_aux_lr: float = 2.0e-4

    best_training_window: int = 25

    @staticmethod
    def load() -> "FastConfig":
        defaults = asdict(FastConfig())
        raw: Dict[str, object] = {}
        # Import compatible base PPO settings first, then FAST overrides.
        if base.CONFIG_PATH.exists():
            try:
                r = json.loads(base.CONFIG_PATH.read_text(encoding="utf-8"))
                if isinstance(r, dict):
                    raw.update(r)
            except Exception:
                pass
        if FAST_CONFIG_PATH.exists():
            try:
                r = json.loads(FAST_CONFIG_PATH.read_text(encoding="utf-8"))
                if isinstance(r, dict):
                    raw.update(r)
            except Exception:
                pass
        valid = set(FastConfig.__dataclass_fields__.keys())
        merged = dict(defaults)
        for k, v in raw.items():
            if k in valid:
                merged[k] = v
        cfg = FastConfig(**merged)
        FAST_CONFIG_PATH.write_text(json.dumps(asdict(cfg), indent=2), encoding="utf-8")
        return cfg


@dataclass
class FastTransition:
    obs: np.ndarray
    move_action: int
    hold_action: int
    logp: float
    value: float
    reward: float
    done: bool
    response: float = 0.0
    best: float = 0.0


@dataclass
class BCSample:
    obs: np.ndarray
    move_action: int
    hold_action: int
    weight: float
    negative: bool = False
    source: str = "human"


class FastBuffer:
    def __init__(self):
        self.rows: List[FastTransition] = []

    def extend(self, rows: Sequence[FastTransition]) -> None:
        self.rows.extend(rows)

    def clear(self) -> None:
        self.rows.clear()

    def __len__(self) -> int:
        return len(self.rows)


def ensure_fast_stats(rt: base.NeuralRuntime) -> None:
    defaults = {
        "fast_bc_updates": 0,
        "fast_bc_positive_samples": 0,
        "fast_bc_negative_samples": 0,
        "fast_aux_human_updates": 0,
        "fast_elite_updates": 0,
        "fast_elite_samples": 0,
        "fast_human_teach_sessions": 0,
        "fast_best_training_score": -1e9,
    }
    for k, v in defaults.items():
        if k not in rt.stats.data:
            rt.stats.data[k] = v
    rt.stats.save()


def effective_entropy_coef(rt: base.NeuralRuntime) -> float:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    updates = int(rt.stats.data.get("ppo_updates", 0) or 0)
    start = min(float(cfg.entropy_coef), float(cfg.entropy_fast_cap))
    return float(max(cfg.entropy_min, start * (cfg.entropy_decay_per_update ** updates)))


def _masked_logits(
    rt: base.NeuralRuntime,
    obs: torch.Tensor,
    move_logits: torch.Tensor,
    hold_logits: torch.Tensor,
) -> Tuple[torch.Tensor, torch.Tensor]:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    if not cfg.curriculum_action_masks:
        return move_logits, hold_logits
    if obs.ndim == 1:
        obs = obs.unsqueeze(0)

    pos = torch.clamp((obs[:, 0] + 1.0) * 0.5, 0.0, 1.0)
    response = torch.clamp((obs[:, 1] + 1.0) * 0.5, 0.0, 1.0)
    best = torch.clamp((obs[:, 2] + 1.0) * 0.5, 0.0, 1.0)
    signal = torch.maximum(response, best)
    search = signal < float(cfg.learning_wobble_threshold)
    near = signal >= float(cfg.near_threshold)
    target = signal >= float(cfg.target_threshold)

    steps = torch.as_tensor(rt.move_steps, dtype=move_logits.dtype, device=move_logits.device)
    abs_steps = torch.abs(steps)
    b = move_logits.shape[0]
    move_mask = torch.zeros((b, len(rt.move_steps)), dtype=torch.bool, device=move_logits.device)

    # SEARCH: only rightward motion is useful because every attempt is reset to
    # the fully-left endpoint. This prevents the v0.6 left-boundary collapse.
    search_mask = steps >= float(cfg.search_min_positive_step) - 1e-9
    edge_mask = (steps > 0) & (steps <= float(cfg.ramp_max_abs_step) + 1e-9)
    move_mask[search] = search_mask
    edge_rows = search & (pos > 0.88)
    move_mask[edge_rows] = edge_mask

    ramp_rows = ~search & ~near
    near_rows = near & ~target
    target_rows = target
    move_mask[ramp_rows] = abs_steps <= float(cfg.ramp_max_abs_step) + 1e-9
    move_mask[near_rows] = abs_steps <= float(cfg.near_max_abs_step) + 1e-9
    move_mask[target_rows] = abs_steps <= float(cfg.target_max_abs_step) + 1e-9

    zero_idx = base.nearest_move_index(rt.move_steps, 0.0)
    empty = ~move_mask.any(dim=1)
    if empty.any():
        move_mask[empty, zero_idx] = True

    # F duration curriculum: short probes while searching, medium allowed on the
    # ramp, long finish holds only near target.
    hold_mask = torch.zeros((b, len(rt.hold_ms)), dtype=torch.bool, device=hold_logits.device)
    hold_mask[:, 0] = True
    if len(rt.hold_ms) > 1:
        hold_mask[~search, 1] = True
    if len(rt.hold_ms) > 2:
        hold_mask[target, 2:] = True

    neg_m = torch.finfo(move_logits.dtype).min / 4.0
    neg_h = torch.finfo(hold_logits.dtype).min / 4.0
    return move_logits.masked_fill(~move_mask, neg_m), hold_logits.masked_fill(~hold_mask, neg_h)


def fast_policy(
    rt: base.NeuralRuntime,
    obs: np.ndarray,
    deterministic: bool,
) -> Tuple[int, int, float, float, np.ndarray, np.ndarray]:
    x = torch.as_tensor(obs, dtype=torch.float32, device=rt.device).unsqueeze(0)
    with torch.no_grad():
        ml, hl, value = rt.net(x)
        ml, hl = _masked_logits(rt, x, ml, hl)
        md = Categorical(logits=ml)
        hd = Categorical(logits=hl)
        if deterministic:
            ma = torch.argmax(ml, dim=-1)
            ha = torch.argmax(hl, dim=-1)
        else:
            ma = md.sample()
            ha = hd.sample()
        logp = md.log_prob(ma) + hd.log_prob(ha)
        mp = torch.softmax(ml, dim=-1)
        hp = torch.softmax(hl, dim=-1)
    return (
        int(ma.item()),
        int(ha.item()),
        float(logp.item()),
        float(value.item()),
        mp.squeeze(0).cpu().numpy(),
        hp.squeeze(0).cpu().numpy(),
    )


def fast_step_reward(
    rt: base.NeuralRuntime,
    response: float,
    prev_response: float,
    best_before: float,
    step_seconds: float,
    requested_delta: float,
    executed_delta: float,
) -> float:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    improvement = float(response - prev_response)
    best_gain = max(0.0, float(response - best_before))
    thr = float(cfg.learning_wobble_threshold)
    reward = 0.0
    if response >= thr:
        reward += cfg.wobble_bonus
    if best_before < thr <= response:
        reward += cfg.first_wobble_bonus
    reward += cfg.progress_gain_fast * max(0.0, improvement)
    reward -= cfg.regression_penalty_fast * max(0.0, -improvement)
    reward += cfg.absolute_progress * max(0.0, response)
    reward += cfg.new_best_bonus_fast * best_gain
    reward -= cfg.probe_cost_fast
    reward -= cfg.time_cost_fast * max(0.0, step_seconds)

    if best_before < thr:
        if executed_delta > 0.002:
            max_pos = max(max(rt.move_steps), 0.01)
            reward += cfg.search_right_bonus * min(1.0, executed_delta / max_pos)
        elif requested_delta <= 0.0:
            reward -= cfg.search_wrong_way_penalty
    if abs(requested_delta) > 0.005 and abs(executed_delta) < 0.0025:
        reward -= cfg.boundary_penalty_fast
    return float(reward)


def fast_failure_reward(rt: base.NeuralRuntime, best: float) -> float:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    scale = max(cfg.adaptive_fail_min_scale, 1.0 - 0.65 * float(np.clip(best, 0.0, 1.0)))
    return float(cfg.fail_penalty * scale)


def fast_success_reward(rt: base.NeuralRuntime, elapsed: float) -> float:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    ratio = max(0.0, 1.0 - elapsed / max(0.1, rt.classic_cfg.attempt_budget_seconds))
    return float(cfg.success_reward_fast + cfg.speed_bonus_fast * ratio)


def _safe_float(v, default=float("nan")) -> float:
    try:
        return float(v)
    except Exception:
        return default


def _demo_pick_pos(rt: base.NeuralRuntime, row: Dict[str, str]) -> float:
    left = rt.calibration_model.calibration.get("pick_left_raw")
    right = rt.calibration_model.calibration.get("pick_right_raw")
    raw = _safe_float(row.get("pick_raw"))
    if left is not None and right is not None and float(right) - float(left) > 1e-5 and math.isfinite(raw):
        return float(np.clip((raw - float(left)) / (float(right) - float(left)), 0.0, 1.0))
    return float(np.clip(_safe_float(row.get("pick_pos"), 0.0), 0.0, 1.0))


def load_human_samples(rt: base.NeuralRuntime) -> Tuple[List[BCSample], Dict[str, int]]:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    files = sorted(classic.DEMO_DIR.glob("demo_*.csv"))
    samples: List[BCSample] = []
    counts = {
        "files": len(files), "success_eps": 0, "fail_eps": 0,
        "mixed_eps": 0, "unknown_eps": 0, "positive": 0,
        "negative": 0, "skipped": 0,
    }
    max_move = max(abs(x) for x in rt.move_steps)
    thr = float(cfg.learning_wobble_threshold)

    for path in files:
        try:
            with path.open("r", newline="", encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
        except Exception:
            continue
        grouped: Dict[int, List[Dict[str, str]]] = {}
        if rows and "episode_id" in rows[0]:
            for row in rows:
                try:
                    eid = int(float(row.get("episode_id", 0) or 0))
                except Exception:
                    eid = 0
                grouped.setdefault(eid, []).append(row)
        else:
            eid, prev_e = 1, -1.0
            for row in rows:
                e = _safe_float(row.get("elapsed"), 0.0)
                if grouped.get(eid) and e + 0.20 < prev_e:
                    eid += 1
                grouped.setdefault(eid, []).append(row)
                prev_e = e

        for _eid, ep in sorted(grouped.items()):
            if len(ep) < 2:
                counts["skipped"] += len(ep)
                continue
            status = int(_safe_float(ep[-1].get("episode_success"), -1))
            ep_elapsed = _safe_float(
                ep[-1].get("episode_elapsed"),
                _safe_float(ep[-1].get("elapsed"), 0.0),
            )
            mixed = bool(
                status == 1 and (
                    ep_elapsed > rt.classic_cfg.legacy_mixed_max_seconds
                    or len(ep) > rt.classic_cfg.legacy_mixed_max_probes
                )
            )
            if mixed:
                kind = "mixed"; counts["mixed_eps"] += 1
            elif status == 1:
                kind = "success"; counts["success_eps"] += 1
            elif status == 0:
                kind = "fail"; counts["fail_eps"] += 1
            else:
                kind = "unknown"; counts["unknown_eps"] += 1

            prev_delta_for_obs = 0.0
            for i in range(1, len(ep)):
                prev, cur = ep[i - 1], ep[i]
                p0, p1 = _demo_pick_pos(rt, prev), _demo_pick_pos(rt, cur)
                r0, r1 = _safe_float(prev.get("response"), 0.0), _safe_float(cur.get("response"), 0.0)
                prev_r0 = _safe_float(prev.get("prev_response"), 0.0)
                best0 = max(_safe_float(prev.get("best_before"), 0.0), r0)
                elapsed0 = max(0.0, _safe_float(prev.get("elapsed"), 0.0))
                delta = p1 - p0
                vals = (p0, p1, r0, r1, prev_r0, best0, delta)
                if not all(math.isfinite(v) for v in vals) or abs(delta) > 0.38:
                    counts["skipped"] += 1
                    prev_delta_for_obs = 0.0
                    continue

                improvement = r1 - r0
                signal = max(r0, best0)
                # Do not behavior-clone the exact v0.6 failure: left/stay in the
                # dead-zone search unless it produced a clearly meaningful jump.
                if signal < thr and delta <= 0 and improvement < 0.04:
                    counts["skipped"] += 1
                    prev_delta_for_obs = delta
                    continue

                obs = base.obs_vector(
                    p0, r0, best0, prev_r0,
                    elapsed0, rt.classic_cfg.attempt_budget_seconds,
                    prev_delta_for_obs, 0, len(rt.hold_ms), 0.0, i - 1,
                    thr, max_move,
                )
                ma = base.nearest_move_index(rt.move_steps, delta)
                frac = i / max(1, len(ep) - 1)
                terminal = i == len(ep) - 1

                # Human OBSERVE records F probes, not exact hold duration. Train
                # movement strongly and hold duration only weakly via phase labels.
                if len(rt.hold_ms) >= 3 and kind == "success" and terminal and max(r1, signal) >= 0.55:
                    ha = 2
                elif len(rt.hold_ms) >= 2 and signal >= 0.18:
                    ha = 1
                else:
                    ha = 0

                helpful = (
                    improvement > 0.010
                    or (signal < thr and delta > 0.0)
                    or (r1 >= thr and improvement >= -0.015)
                )
                if kind == "success":
                    quality = 1.0 + 2.5 * max(0.0, r1) + 5.0 * max(0.0, improvement)
                    tail = 1.0 + cfg.bc_success_tail_boost * (frac ** 2)
                    w = cfg.bc_success_weight * quality * tail
                    samples.append(BCSample(obs, ma, ha, w, False, "human_success"))
                    counts["positive"] += 1
                elif kind == "fail":
                    if helpful:
                        w = cfg.bc_fail_helpful_weight * (
                            1.0 + 2.0 * max(0.0, r1) + 4.0 * max(0.0, improvement)
                        )
                        samples.append(BCSample(obs, ma, ha, w, False, "human_fail_helpful"))
                        counts["positive"] += 1
                    else:
                        harm = max(0.0, -improvement)
                        w = cfg.bc_fail_bad_weight * (
                            1.0 + 4.0 * harm + (1.5 if terminal else 0.0)
                        )
                        samples.append(BCSample(obs, ma, ha, w, True, "human_fail_bad"))
                        counts["negative"] += 1
                elif kind == "mixed":
                    if helpful and improvement > 0.008:
                        w = cfg.bc_mixed_weight * (
                            1.0 + 3.0 * max(0.0, improvement) + max(0.0, r1)
                        )
                        samples.append(BCSample(obs, ma, ha, w, False, "human_mixed_helpful"))
                        counts["positive"] += 1
                    elif improvement < -0.035:
                        w = 0.20 * (1.0 + 2.0 * (-improvement))
                        samples.append(BCSample(obs, ma, ha, w, True, "human_mixed_bad"))
                        counts["negative"] += 1
                    else:
                        counts["skipped"] += 1
                else:
                    if helpful and improvement > 0.015:
                        samples.append(BCSample(obs, ma, ha, 0.18, False, "human_unknown_helpful"))
                        counts["positive"] += 1
                    else:
                        counts["skipped"] += 1
                prev_delta_for_obs = delta

    if len(samples) > int(cfg.bc_max_samples):
        samples = sorted(samples, key=lambda x: x.weight, reverse=True)[: int(cfg.bc_max_samples)]
    return samples, counts


def _actor_head_reset(rt: base.NeuralRuntime) -> None:
    nn.init.orthogonal_(rt.net.move_head.weight, gain=0.01)
    nn.init.zeros_(rt.net.move_head.bias)
    nn.init.orthogonal_(rt.net.hold_head.weight, gain=0.01)
    nn.init.zeros_(rt.net.hold_head.bias)


def supervised_update(
    rt: base.NeuralRuntime,
    samples: Sequence[BCSample],
    epochs: int,
    lr: float,
    max_samples: Optional[int] = None,
    use_main_optimizer: bool = False,
) -> Dict[str, float]:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    if not samples or epochs <= 0:
        return {"samples": 0.0, "loss": 0.0}
    rows = list(samples)
    if max_samples is not None and len(rows) > max_samples:
        rows.sort(key=lambda x: x.weight, reverse=True)
        strong = rows[: max_samples // 2]
        tail = rows[max_samples // 2 :]
        random.shuffle(tail)
        rows = strong + tail[: max_samples - len(strong)]

    if use_main_optimizer:
        opt = rt.optimizer
        old_lrs = [g["lr"] for g in opt.param_groups]
        for g in opt.param_groups:
            g["lr"] = float(lr)
    else:
        opt = torch.optim.Adam(rt.net.parameters(), lr=float(lr), eps=1e-5)
        old_lrs = []

    losses: List[float] = []
    bs = max(8, int(cfg.bc_batch_size))
    rt.net.train()
    for _ in range(int(epochs)):
        random.shuffle(rows)
        for start in range(0, len(rows), bs):
            batch = rows[start : start + bs]
            obs = torch.as_tensor(
                np.stack([x.obs for x in batch]), dtype=torch.float32, device=rt.device
            )
            ma = torch.as_tensor([x.move_action for x in batch], dtype=torch.long, device=rt.device)
            ha = torch.as_tensor([x.hold_action for x in batch], dtype=torch.long, device=rt.device)
            weights = torch.as_tensor(
                [min(20.0, max(0.05, x.weight)) for x in batch],
                dtype=torch.float32,
                device=rt.device,
            )
            negmask = torch.as_tensor(
                [1.0 if x.negative else 0.0 for x in batch],
                dtype=torch.float32,
                device=rt.device,
            )
            posmask = 1.0 - negmask

            ml, hl, _v = rt.net(obs)
            move_ce = F.cross_entropy(ml, ma, reduction="none")
            hold_ce = F.cross_entropy(hl, ha, reduction="none")
            pos_den = torch.clamp((weights * posmask).sum(), min=1.0)
            pos_loss = (
                (move_ce + cfg.bc_hold_loss_weight * hold_ce) * weights * posmask
            ).sum() / pos_den

            probs = torch.softmax(ml, dim=-1)
            bad_p = probs.gather(1, ma.unsqueeze(1)).squeeze(1).clamp(1e-6, 1.0 - 1e-6)
            neg_den = torch.clamp((weights * negmask).sum(), min=1.0)
            neg_loss = ((-torch.log1p(-bad_p)) * weights * negmask).sum() / neg_den
            if float(negmask.sum().item()) < 0.5:
                neg_loss = neg_loss * 0.0

            loss = pos_loss + neg_loss
            opt.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(rt.net.parameters(), cfg.max_grad_norm)
            opt.step()
            losses.append(float(loss.item()))

    if use_main_optimizer:
        for g, old_lr in zip(opt.param_groups, old_lrs):
            g["lr"] = old_lr
    rt.net.eval()
    return {"samples": float(len(rows)), "loss": float(np.mean(losses) if losses else 0.0)}


def pretrain_from_human(rt: base.NeuralRuntime, automatic: bool = False) -> None:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    samples, counts = load_human_samples(rt)
    pos = sum(1 for x in samples if not x.negative)
    neg = sum(1 for x in samples if x.negative)
    print("\n=== HUMAN -> NEURAL PRETRAIN ===")
    print(
        f"Demo files={counts['files']} | clean success episodes={counts['success_eps']} | "
        f"failed={counts['fail_eps']} | mixed={counts['mixed_eps']} | unknown={counts['unknown_eps']}"
    )
    print(f"Usable examples: positive={pos}, negative={neg}, skipped={counts['skipped']}")
    if not samples:
        print("No usable human demonstrations. Run HUMAN TEACH first.")
        return

    before = rt.model_hash()
    train_successes = int(rt.stats.data.get("train_successes", 0) or 0)
    ppo_updates = int(rt.stats.data.get("ppo_updates", 0) or 0)
    if cfg.reset_actor_if_zero_success and train_successes == 0 and ppo_updates >= 3 and counts["success_eps"] > 0:
        try:
            rt.save_checkpoint(RESCUE_CKPT)
        except Exception:
            pass
        _actor_head_reset(rt)
        print("[RECOVERY] PPO had zero successes; actor heads reset before human BC. Body/value network preserved.")

    metrics = supervised_update(rt, samples, cfg.bc_epochs, cfg.bc_learning_rate)
    # Reset PPO Adam after a large supervised warm-start so stale moments cannot
    # pull the actor back toward the failed v0.6 policy.
    rt.optimizer = torch.optim.Adam(rt.net.parameters(), lr=cfg.learning_rate, eps=1e-5)
    rt.stats.inc("fast_bc_updates", 1)
    rt.stats.inc("fast_bc_positive_samples", pos)
    rt.stats.inc("fast_bc_negative_samples", neg)
    rt.stats.data["last_hash"] = rt.model_hash()
    rt.stats.save()
    rt.save_checkpoint(base.LATEST_CKPT)

    base.append_csv(
        BC_LOG,
        ["wall_time", "kind", "samples", "positive", "negative", "loss", "before_hash", "after_hash"],
        {
            "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"),
            "kind": "auto_after_teach" if automatic else "manual",
            "samples": int(metrics["samples"]),
            "positive": pos,
            "negative": neg,
            "loss": metrics["loss"],
            "before_hash": before,
            "after_hash": rt.model_hash(),
        },
    )
    print(f"Behavior cloning complete: {int(metrics['samples'])} samples | loss={metrics['loss']:.4f}")
    print(f"Neural hash {before[:12]} -> {rt.model_hash()[:12]}")
    print("Wins are strongly weighted. Helpful failed transitions help; harmful/final FAIL actions are trained away.")


def human_teach(rt: base.NeuralRuntime) -> None:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    print("\n=== HUMAN TEACH ===")
    print("Play normally. Wins AND failures are useful; you do not need a perfect success rate.")
    print("F12 stops recording. The neural policy is then behavior-cloned automatically.")
    classic.observe(rt.classic_cfg, rt.calibration_model)
    rt.stats.inc("fast_human_teach_sessions", 1)
    rt.stats.save()
    if cfg.auto_pretrain_after_teach:
        pretrain_from_human(rt, automatic=True)


def _elite_rows() -> List[Dict[str, str]]:
    if not ELITE_REPLAY.exists():
        return []
    try:
        with ELITE_REPLAY.open("r", newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))
    except Exception:
        return []


def archive_elite_episode(
    rt: base.NeuralRuntime,
    episode: Sequence[FastTransition],
    success: bool,
    best: float,
) -> None:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    if not episode:
        return
    selected: List[Dict[str, object]] = []
    n = len(episode)
    for i, tr in enumerate(episode):
        frac = (i + 1) / max(1, n)
        if success:
            if tr.reward < -1.0 and not tr.done:
                continue
            weight = cfg.elite_success_weight * (1.0 + 2.0 * frac * frac) + 2.0 * max(0.0, tr.reward)
            source = "selfplay_success"
        elif best >= cfg.elite_near_best_threshold and tr.reward >= cfg.elite_positive_reward_threshold:
            weight = 0.8 * (1.0 + 2.0 * max(0.0, tr.reward) + 2.0 * tr.best)
            source = "selfplay_near"
        else:
            continue
        selected.append(
            {
                "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"),
                "obs": json.dumps([float(x) for x in tr.obs], separators=(",", ":")),
                "move_action": tr.move_action,
                "hold_action": tr.hold_action,
                "weight": weight,
                "source": source,
                "success": int(success),
                "best": best,
                "reward": tr.reward,
            }
        )

    fields = [
        "wall_time", "obs", "move_action", "hold_action", "weight",
        "source", "success", "best", "reward",
    ]
    for row in selected:
        base.append_csv(ELITE_REPLAY, fields, row)
    if selected:
        rt.stats.inc("fast_elite_samples", len(selected))
        rt.stats.save()

    rows = _elite_rows()
    cap = int(cfg.elite_replay_capacity)
    if len(rows) > cap:
        rows = rows[-cap:]
        with ELITE_REPLAY.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader()
            w.writerows(rows)


def load_elite_samples() -> List[BCSample]:
    out: List[BCSample] = []
    for row in _elite_rows():
        try:
            obs = np.asarray(json.loads(row["obs"]), dtype=np.float32)
            if obs.shape != (base.OBS_DIM,):
                continue
            out.append(
                BCSample(
                    obs,
                    int(row["move_action"]),
                    int(row["hold_action"]),
                    float(row["weight"]),
                    False,
                    str(row.get("source", "elite")),
                )
            )
        except Exception:
            continue
    return out


def auxiliary_rehearsal(rt: base.NeuralRuntime) -> Tuple[int, int]:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    human, _ = load_human_samples(rt)
    hu = 0
    el = 0
    if human and cfg.auxiliary_human_epochs > 0:
        supervised_update(
            rt,
            human,
            cfg.auxiliary_human_epochs,
            cfg.auxiliary_human_lr,
            max_samples=cfg.auxiliary_human_max_samples,
            use_main_optimizer=True,
        )
        rt.stats.inc("fast_aux_human_updates", 1)
        hu = 1

    elite = load_elite_samples()
    if elite and cfg.elite_aux_epochs > 0:
        supervised_update(
            rt,
            elite,
            cfg.elite_aux_epochs,
            cfg.elite_aux_lr,
            max_samples=cfg.elite_aux_max_samples,
            use_main_optimizer=True,
        )
        rt.stats.inc("fast_elite_updates", 1)
        el = 1
    return hu, el


def ppo_update_fast(rt: base.NeuralRuntime, buffer: FastBuffer) -> Dict[str, float]:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    if not buffer.rows:
        return {}
    rows = buffer.rows
    obs = torch.as_tensor(np.stack([r.obs for r in rows]), dtype=torch.float32, device=rt.device)
    move = torch.as_tensor([r.move_action for r in rows], dtype=torch.long, device=rt.device)
    hold = torch.as_tensor([r.hold_action for r in rows], dtype=torch.long, device=rt.device)
    old_logp = torch.as_tensor([r.logp for r in rows], dtype=torch.float32, device=rt.device)
    old_values = np.asarray([r.value for r in rows], dtype=np.float32)
    rewards = np.asarray([r.reward for r in rows], dtype=np.float32)
    dones = np.asarray([1.0 if r.done else 0.0 for r in rows], dtype=np.float32)

    adv = np.zeros_like(rewards, dtype=np.float32)
    gae = 0.0
    next_value = 0.0
    for t in reversed(range(len(rows))):
        nonterminal = 1.0 - dones[t]
        delta = rewards[t] + cfg.gamma * next_value * nonterminal - old_values[t]
        gae = delta + cfg.gamma * cfg.gae_lambda * nonterminal * gae
        adv[t] = gae
        next_value = old_values[t]
    returns = adv + old_values
    if len(adv) > 1:
        adv = (adv - adv.mean()) / (adv.std() + 1e-8)

    advantages = torch.as_tensor(adv, dtype=torch.float32, device=rt.device)
    returns_t = torch.as_tensor(returns, dtype=torch.float32, device=rt.device)
    n = len(rows)
    indices = np.arange(n)
    losses: List[float] = []
    policy_losses: List[float] = []
    value_losses: List[float] = []
    entropies: List[float] = []
    kls: List[float] = []
    clip_fracs: List[float] = []
    grad_steps = 0
    early_stop = False
    ent_coef = effective_entropy_coef(rt)

    rt.net.train()
    for _epoch in range(int(cfg.ppo_epochs)):
        np.random.shuffle(indices)
        for start in range(0, n, max(1, int(cfg.minibatch_size))):
            mb = indices[start : start + max(1, int(cfg.minibatch_size))]
            mb_t = torch.as_tensor(mb, dtype=torch.long, device=rt.device)
            ml, hl, values = rt.net(obs[mb_t])
            ml, hl = _masked_logits(rt, obs[mb_t], ml, hl)
            md = Categorical(logits=ml)
            hd = Categorical(logits=hl)
            new_logp = md.log_prob(move[mb_t]) + hd.log_prob(hold[mb_t])
            entropy = md.entropy() + hd.entropy()

            log_ratio = new_logp - old_logp[mb_t]
            ratio = torch.exp(log_ratio)
            s1 = ratio * advantages[mb_t]
            s2 = torch.clamp(ratio, 1.0 - cfg.clip_ratio, 1.0 + cfg.clip_ratio) * advantages[mb_t]
            policy_loss = -torch.min(s1, s2).mean()
            value_loss = 0.5 * F.mse_loss(values, returns_t[mb_t])
            entropy_mean = entropy.mean()
            loss = policy_loss + cfg.value_coef * value_loss - ent_coef * entropy_mean

            rt.optimizer.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(rt.net.parameters(), cfg.max_grad_norm)
            rt.optimizer.step()
            grad_steps += 1

            with torch.no_grad():
                approx_kl = float(((ratio - 1.0) - log_ratio).mean().item())
                clip_frac = float((torch.abs(ratio - 1.0) > cfg.clip_ratio).float().mean().item())
            losses.append(float(loss.item()))
            policy_losses.append(float(policy_loss.item()))
            value_losses.append(float(value_loss.item()))
            entropies.append(float(entropy_mean.item()))
            kls.append(approx_kl)
            clip_fracs.append(clip_frac)
            if approx_kl > cfg.target_kl * 1.5:
                early_stop = True
                break
        if early_stop:
            break

    # Rehearsal is auxiliary supervised learning, not stale PPO replay.
    hu_aux, elite_aux = auxiliary_rehearsal(rt)

    rt.stats.inc("ppo_updates", 1)
    rt.stats.inc("gradient_steps", grad_steps)
    rt.stats.inc("transitions_trained", n)
    rt.stats.data["last_hash"] = rt.model_hash()
    rt.stats.save()
    update_no = int(rt.stats.data.get("ppo_updates", 0) or 0)
    metrics = {
        "transitions": float(n),
        "loss": float(np.mean(losses) if losses else 0.0),
        "policy_loss": float(np.mean(policy_losses) if policy_losses else 0.0),
        "value_loss": float(np.mean(value_losses) if value_losses else 0.0),
        "entropy": float(np.mean(entropies) if entropies else 0.0),
        "entropy_coef": float(ent_coef),
        "approx_kl": float(np.mean(kls) if kls else 0.0),
        "clip_frac": float(np.mean(clip_fracs) if clip_fracs else 0.0),
        "grad_steps": float(grad_steps),
        "early_stop": float(1 if early_stop else 0),
        "aux_human": float(hu_aux),
        "aux_elite": float(elite_aux),
    }
    base.append_csv(
        base.PPO_LOG,
        [
            "wall_time", "ppo_update", "transitions", "loss", "policy_loss",
            "value_loss", "entropy", "entropy_coef", "approx_kl", "clip_frac",
            "grad_steps", "early_stop", "aux_human", "aux_elite", "policy_hash",
        ],
        {
            "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"),
            "ppo_update": update_no,
            **metrics,
            "policy_hash": rt.model_hash(),
        },
    )
    rt.save_checkpoint(base.LATEST_CKPT)
    if update_no % max(1, int(cfg.checkpoint_every_updates)) == 0:
        cp = base.CHECKPOINT_DIR / f"ppo_fast_update_{update_no:06d}.pt"
        rt.save_checkpoint(cp)

    print(
        f"\nFAST PPO UPDATE #{update_no}: n={n} loss={metrics['loss']:+.4f} "
        f"pi={metrics['policy_loss']:+.4f} V={metrics['value_loss']:.4f} "
        f"H={metrics['entropy']:.3f} entC={metrics['entropy_coef']:.4f} "
        f"KL={metrics['approx_kl']:.5f} aux(H/E)={hu_aux}/{elite_aux} "
        f"hash={rt.model_hash()[:12]}"
    )
    buffer.clear()
    return metrics


def maybe_save_best_training(rt: base.NeuralRuntime) -> None:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    rows = base.read_episode_rows(base.TRAIN_EPISODES)
    w = max(5, int(cfg.best_training_window))
    if len(rows) < w:
        return
    sub = rows[-w:]
    succ = sum(int(float(r.get("success", 0) or 0)) for r in sub) / w
    avg_best = float(np.mean([float(r.get("best_response", 0) or 0) for r in sub]))
    avg_reward = float(np.mean([float(r.get("total_reward", 0) or 0) for r in sub]))
    score = 100.0 * succ + 25.0 * avg_best + 0.15 * avg_reward
    old = float(rt.stats.data.get("fast_best_training_score", -1e9) or -1e9)
    if score > old:
        rt.stats.data["fast_best_training_score"] = score
        rt.stats.save()
        rt.save_checkpoint(BEST_TRAIN_CKPT)
        print(f"[BEST] rolling {w}-attempt score={score:.2f} -> {BEST_TRAIN_CKPT.name}")


def run_fast(rt: base.NeuralRuntime, learning: bool, max_attempts: Optional[int] = None) -> None:
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    if not classic.IS_WINDOWS:
        print("Live neural play needs Windows.")
        return
    mode = "FAST NEURAL TRAIN" if learning else "FAST NEURAL EVALUATION"
    print(f"\n=== {mode} v0.7 ===")
    print("F12 = emergency stop. Hold F10 = pause.")
    if learning:
        print("Curriculum PPO + human rehearsal + elite success/near-success distillation.")
    else:
        print("Deterministic masked policy; learning is OFF.")

    before_hash = rt.model_hash()
    before_updates = int(rt.stats.data.get("ppo_updates", 0) or 0)
    vision, console_hwnd = base._prepare_live(rt)
    if vision is None:
        return

    buffer = FastBuffer()
    attempt_local = 0
    aborted = False
    rt.net.eval()
    max_move = max(abs(x) for x in rt.move_steps)

    while max_attempts is None or attempt_local < max_attempts:
        if classic.emergency_or_pause(rt.classic_cfg):
            aborted = True
            break
        attempt_local += 1
        stat_key = "train_attempts" if learning else "eval_attempts"
        global_attempt = int(rt.stats.data.get(stat_key, 0) or 0) + 1
        print(f"\n--- fast neural attempt {global_attempt} ---")

        classic.send_key(rt.classic_cfg.space_key_vk, 28)
        time.sleep(max(0.08, rt.classic_cfg.start_wait_seconds))
        classic.move_mouse_relative(-5000, 0)
        time.sleep(0.16)
        st0 = vision.state(keep_frame=rt.classic_cfg.debug_preview)
        if rt.classic_cfg.debug_preview:
            classic.preview(vision, st0, "Lockpick Learner - Neural FAST")
        pos = st0.pick_pos
        if pos is None:
            print("Could not see normalized pick position; skipping attempt.")
            time.sleep(rt.classic_cfg.restart_wait_seconds)
            continue

        start = time.monotonic()
        response = 0.0
        prev_response = 0.0
        best = 0.0
        last_delta = 0.0
        last_hold_idx = 0
        last_reward = 0.0
        episode: List[FastTransition] = []
        total_reward = 0.0
        success = False
        terminal = False
        step_no = 0
        latest_success_score = 0.0

        while step_no < int(cfg.max_steps_per_attempt):
            if classic.emergency_or_pause(rt.classic_cfg):
                aborted = True
                break
            elapsed = time.monotonic() - start
            if elapsed >= rt.classic_cfg.attempt_budget_seconds + 0.45:
                terminal = True
                break

            obs = base.obs_vector(
                pos,
                response,
                best,
                prev_response,
                elapsed,
                rt.classic_cfg.attempt_budget_seconds,
                last_delta,
                last_hold_idx,
                len(rt.hold_ms),
                last_reward,
                step_no,
                cfg.learning_wobble_threshold,
                max_move,
            )
            move_idx, hold_idx, logp, value, move_probs, hold_probs = fast_policy(
                rt, obs, deterministic=not learning
            )
            requested_delta = float(rt.move_steps[move_idx])
            target = float(np.clip(pos + requested_delta, 0.0, 1.0))
            step_started = time.monotonic()
            moved = classic.move_to(vision, rt.calibration_model, target, rt.classic_cfg)
            if moved is None:
                aborted = True
                break
            executed_delta = float(moved - pos)
            pos = float(moved)
            before_response = response
            best_before = best
            response, ui_conf, success_score = base.probe_response_hold(
                vision, rt.classic_cfg, cfg, rt.hold_ms[hold_idx]
            )
            latest_success_score = success_score
            step_no += 1
            elapsed = time.monotonic() - start
            step_seconds = time.monotonic() - step_started
            reward = fast_step_reward(
                rt,
                response,
                before_response,
                best_before,
                step_seconds,
                requested_delta,
                executed_delta,
            )
            best = max(best, response)

            if success_score >= rt.classic_cfg.success_template_threshold:
                success = True
            elif ui_conf < 0.045 and elapsed > 0.40:
                late = classic.wait_success_text(vision, rt.classic_cfg, ms=cfg.success_extra_wait_ms)
                latest_success_score = max(latest_success_score, late)
                success = late >= rt.classic_cfg.success_template_threshold
                terminal = True
            elif elapsed >= rt.classic_cfg.attempt_budget_seconds + 0.40:
                late = classic.wait_success_text(vision, rt.classic_cfg, ms=cfg.success_extra_wait_ms)
                latest_success_score = max(latest_success_score, late)
                success = late >= rt.classic_cfg.success_template_threshold
                terminal = True

            if success:
                reward += fast_success_reward(rt, elapsed)
                terminal = True
            elif terminal or step_no >= int(cfg.max_steps_per_attempt):
                reward += fast_failure_reward(rt, best)
                terminal = True

            total_reward += reward
            episode.append(
                FastTransition(
                    obs, move_idx, hold_idx, logp, value, reward, terminal,
                    response=response, best=best,
                )
            )
            base.log_decision(
                rt,
                mode,
                global_attempt,
                step_no,
                obs,
                move_idx,
                hold_idx,
                move_probs,
                hold_probs,
                value,
                reward,
                response,
                best,
                latest_success_score,
                requested_delta,
                executed_delta,
            )
            move_conf = float(move_probs[move_idx])
            hold_conf = float(hold_probs[hold_idx])
            phase = "SEARCH" if best < cfg.learning_wobble_threshold else (
                "TARGET" if best >= cfg.target_threshold else "RAMP"
            )
            print(
                f"p={pos:.3f} resp={response:.3f} best={best:.3f} phase={phase:<6} "
                f"r={reward:+.2f} move={requested_delta:+.3f}({move_conf:.2f}) "
                f"F={rt.hold_ms[hold_idx]}ms({hold_conf:.2f}) V={value:+.2f} "
                f"success={latest_success_score:.2f}",
                end="\r",
            )

            prev_response = before_response
            last_delta = requested_delta
            last_hold_idx = hold_idx
            last_reward = reward
            if terminal:
                break

        if aborted:
            print("\nIncomplete episode discarded; it is not trained as a fake FAIL.")
            break

        if episode and not episode[-1].done:
            elapsed = time.monotonic() - start
            late = classic.wait_success_text(vision, rt.classic_cfg, ms=cfg.success_extra_wait_ms)
            success = late >= rt.classic_cfg.success_template_threshold
            latest_success_score = max(latest_success_score, late)
            terminal_bonus = fast_success_reward(rt, elapsed) if success else fast_failure_reward(rt, best)
            episode[-1].reward += terminal_bonus
            episode[-1].done = True
            total_reward += terminal_bonus
            terminal = True
        elif not terminal:
            elapsed = time.monotonic() - start
            late = classic.wait_success_text(vision, rt.classic_cfg, ms=cfg.success_extra_wait_ms)
            success = late >= rt.classic_cfg.success_template_threshold
            latest_success_score = max(latest_success_score, late)
            terminal = True

        elapsed = time.monotonic() - start
        if success:
            print(
                f"\nFAST NEURAL SUCCESS in {elapsed:.2f}s | steps={step_no} | "
                f"best={best:.3f} | reward={total_reward:.1f}"
            )
        else:
            print(
                f"\nFAST NEURAL FAIL | t={elapsed:.2f}s | steps={step_no} | "
                f"best={best:.3f} | reward={total_reward:.1f}"
            )

        if learning:
            rt.stats.inc("train_attempts", 1)
            if success:
                rt.stats.inc("train_successes", 1)
            buffer.extend(episode)
            base.log_episode(
                base.TRAIN_EPISODES,
                mode,
                global_attempt,
                success,
                elapsed,
                step_no,
                total_reward,
                best,
                rt,
            )
            archive_elite_episode(rt, episode, success, best)
            maybe_save_best_training(rt)
            if len(buffer) >= int(cfg.rollout_steps):
                ppo_update_fast(rt, buffer)
                rt.net.eval()
        else:
            rt.stats.inc("eval_attempts", 1)
            if success:
                rt.stats.inc("eval_successes", 1)
            base.log_episode(
                base.EVAL_EPISODES,
                mode,
                global_attempt,
                success,
                elapsed,
                step_no,
                total_reward,
                best,
                rt,
            )
            rt.stats.save()

        time.sleep(rt.classic_cfg.restart_wait_seconds)

    if learning and len(buffer) >= int(cfg.min_update_steps_on_exit):
        print(f"\nTraining remaining {len(buffer)} on-policy transitions before exit...")
        ppo_update_fast(rt, buffer)
    elif learning and len(buffer) > 0:
        print(
            f"\nFinal {len(buffer)} transitions were below min_update_steps_on_exit="
            f"{cfg.min_update_steps_on_exit}; model unchanged for that tiny tail."
        )

    if learning:
        rt.save_checkpoint(base.LATEST_CKPT)
    rt.stats.save()
    if rt.classic_cfg.debug_preview:
        try:
            classic.cv2.destroyAllWindows()
        except Exception:
            pass
    classic.restore_console(console_hwnd)

    after_hash = rt.model_hash()
    after_updates = int(rt.stats.data.get("ppo_updates", 0) or 0)
    if not learning:
        print(
            f"\nEvaluation mutation check: hash {before_hash[:12]} -> {after_hash[:12]} | "
            f"PPO updates {before_updates} -> {after_updates}"
        )
        if before_hash == after_hash and before_updates == after_updates:
            print("PASS: deterministic evaluation did not train or mutate the neural policy.")
        else:
            print("FAIL: evaluation mutated neural state unexpectedly.")


def evaluate_prompt(rt: base.NeuralRuntime) -> None:
    raw = input("How many deterministic FAST evaluation attempts? [25]: ").strip()
    try:
        n = int(raw) if raw else 25
    except Exception:
        n = 25
    n = max(1, min(5000, n))
    before_n = len(base.read_episode_rows(base.EVAL_EPISODES))
    run_fast(rt, learning=False, max_attempts=n)
    rows = base.read_episode_rows(base.EVAL_EPISODES)
    new = rows[before_n:]
    if not new:
        return
    succ = sum(int(float(r.get("success", 0) or 0)) for r in new)
    rate = succ / len(new)
    print(f"FAST batch evaluation: {succ}/{len(new)} = {rate * 100:.1f}%")
    best = float(rt.stats.data.get("best_eval_rate", 0.0) or 0.0)
    if len(new) >= 10 and rate > best:
        rt.stats.data["best_eval_rate"] = rate
        rt.stats.save()
        rt.save_checkpoint(base.BEST_CKPT)
        print(f"New best deterministic evaluation -> saved {base.BEST_CKPT.name}")


def restore_best(rt: base.NeuralRuntime) -> None:
    candidates: List[Tuple[Path, str]] = []
    if base.BEST_CKPT.exists():
        candidates.append((base.BEST_CKPT, "best deterministic evaluation"))
    if BEST_TRAIN_CKPT.exists():
        candidates.append((BEST_TRAIN_CKPT, "best rolling training"))
    if not candidates:
        print("No best checkpoint exists yet.")
        return
    path, label = candidates[0]
    try:
        ckpt = torch.load(path, map_location=rt.device)
        rt.net.load_state_dict(ckpt["state_dict"])
        rt.optimizer = torch.optim.Adam(rt.net.parameters(), lr=rt.cfg.learning_rate, eps=1e-5)
        rt.save_checkpoint(base.LATEST_CKPT)
        print(f"Restored {label}: {path.name} | hash={rt.model_hash()[:12]}")
    except Exception as exc:
        print(f"Restore failed: {exc}")


def fast_verify(rt: base.NeuralRuntime) -> None:
    # Keep all existing v0.6 software/backprop/persistence checks.
    base.neural_verify(rt)
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    test_obs = base.obs_vector(
        0.0,
        0.045,
        0.056,
        0.045,
        0.4,
        rt.classic_cfg.attempt_budget_seconds,
        0.0,
        0,
        len(rt.hold_ms),
        -1.0,
        2,
        cfg.learning_wobble_threshold,
        max(abs(x) for x in rt.move_steps),
    )
    mi, hi, _lp, _v, _mp, _hp = fast_policy(rt, test_obs, deterministic=True)
    collapse_pass = rt.move_steps[mi] > 0.0 and rt.hold_ms[hi] == rt.hold_ms[0]
    print(
        f"FAST left-boundary dead-zone regression: {'PASS' if collapse_pass else 'FAIL'} | "
        f"move={rt.move_steps[mi]:+.3f}, F={rt.hold_ms[hi]}ms"
    )
    print(
        f"Effective entropy coefficient: {effective_entropy_coef(rt):.5f} | "
        f"learning wobble threshold={cfg.learning_wobble_threshold:.3f}"
    )


def fast_stats(rt: base.NeuralRuntime) -> None:
    base.neural_stats(rt)
    cfg: FastConfig = rt.cfg  # type: ignore[assignment]
    d = rt.stats.data
    print("\n=== v0.7 FAST LEARNING ADDITIONS ===")
    print(f"Effective entropy coefficient: {effective_entropy_coef(rt):.6f}")
    print(
        f"Human BC: updates={int(d.get('fast_bc_updates', 0) or 0)} | "
        f"positive={int(d.get('fast_bc_positive_samples', 0) or 0)} | "
        f"negative={int(d.get('fast_bc_negative_samples', 0) or 0)}"
    )
    print(
        f"Aux rehearsal: human={int(d.get('fast_aux_human_updates', 0) or 0)} | "
        f"elite={int(d.get('fast_elite_updates', 0) or 0)}"
    )
    print(f"Elite replay bank: {len(_elite_rows())}/{cfg.elite_replay_capacity} samples")
    print(
        f"Thresholds: meaningful response={cfg.learning_wobble_threshold:.3f}, "
        f"near={cfg.near_threshold:.2f}, target={cfg.target_threshold:.2f}"
    )
    print(f"Best rolling training score: {float(d.get('fast_best_training_score', -1e9) or -1e9):.2f}")


def reset_neural(rt: base.NeuralRuntime) -> bool:
    return base.reset_neural(rt)


def print_menu(rt: base.NeuralRuntime) -> None:
    print("\n======================================================")
    print(" LOCKPICK LEARNER v0.7 - FAST HUMAN + PPO LEARNING")
    print("======================================================")
    print("1) HUMAN TEACH      - you play; wins + fails recorded; auto neural pretrain")
    print("2) PRETRAIN DEMOS   - train neural policy from all existing human demos")
    print("3) FAST SELF-PLAY   - curriculum PPO + human rehearsal + elite replay")
    print("4) EVALUATE         - deterministic learned policy, learning OFF")
    print("5) VERIFY NEURAL    - persistence/backprop + FAST mask regression")
    print("6) NEURAL STATS")
    print("7) CALIBRATE")
    print("8) VISION DEBUG")
    print("9) RESTORE BEST")
    print("10) START CLASSIC v0.5 MENU")
    print("11) RESET NEURAL MODEL")
    print("12) EXIT")
    print(
        f"Current hash: {rt.model_hash()[:12]} | device={rt.device} | "
        f"PPO={int(rt.stats.data.get('ppo_updates', 0) or 0)} | "
        f"BC={int(rt.stats.data.get('fast_bc_updates', 0) or 0)}"
    )


def main() -> None:
    base.set_seeds(5606)
    classic_cfg = classic.Config.load()
    fast_cfg = FastConfig.load()
    base.set_seeds(fast_cfg.seed)
    rt = base.NeuralRuntime(classic_cfg, fast_cfg)
    ensure_fast_stats(rt)
    print(f"PyTorch device: {rt.device} | torch={torch.__version__}")
    if rt.device.type == "cuda":
        try:
            print(f"GPU: {torch.cuda.get_device_name(rt.device)}")
        except Exception:
            pass
    else:
        print("CPU is sufficient for this small network; live gameplay/vision is the bottleneck, not PPO math.")

    while True:
        print_menu(rt)
        choice = input("Select: ").strip()
        try:
            if choice == "1":
                human_teach(rt)
            elif choice == "2":
                pretrain_from_human(rt, automatic=False)
            elif choice == "3":
                run_fast(rt, learning=True, max_attempts=None)
            elif choice == "4":
                evaluate_prompt(rt)
            elif choice == "5":
                fast_verify(rt)
            elif choice == "6":
                fast_stats(rt)
            elif choice == "7":
                base.calibrate_neural(rt)
            elif choice == "8":
                classic.vision_debug(rt.classic_cfg, rt.calibration_model)
            elif choice == "9":
                restore_best(rt)
            elif choice == "10":
                classic.main()
            elif choice == "11":
                if reset_neural(rt):
                    return
            elif choice == "12":
                rt.save_checkpoint(base.LATEST_CKPT)
                return
        except KeyboardInterrupt:
            print("\nInterrupted. Saving checkpoint.")
            rt.save_checkpoint(base.LATEST_CKPT)
        except Exception as exc:
            print(f"\n[ERROR] {type(exc).__name__}: {exc}")


if __name__ == "__main__":
    main()
