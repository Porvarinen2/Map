from __future__ import annotations

import csv
import hashlib
import json
import math
import random
import shutil
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import numpy as np
import cv2
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.distributions import Beta, Categorical, kl_divergence

import lockpick_learner as classic

APP_NAME = "Lockpick Learner v0.16.3 SAFE SIM GEOMETRY + TYPE DOMAIN"
ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
SMART_DIR = DATA_DIR / "neural_smart"
AUDIT_DIR = SMART_DIR / "audit"
CHECKPOINT_DIR = SMART_DIR / "checkpoints"
PROFILE_PATH = SMART_DIR / "sim_profile.json"
STATS_PATH = SMART_DIR / "stats.json"
LATEST_CKPT = SMART_DIR / "smart_latest.pt"
BEST_SIM_CKPT = SMART_DIR / "smart_best_sim.pt"
BEST_REAL_CKPT = SMART_DIR / "smart_best_real.pt"
INITIAL_CKPT = SMART_DIR / "smart_initial.pt"
CONFIG_PATH = ROOT / "config_neural_smart.json"
SIM_LOG = AUDIT_DIR / "sim_updates.csv"
REAL_EPISODES = SMART_DIR / "real_train_episodes.csv"
EVAL_EPISODES = SMART_DIR / "real_eval_episodes.csv"
DECISION_LOG = AUDIT_DIR / "decisions.csv"
LOCK_TYPE_LOG = AUDIT_DIR / "lock_types_v014.csv"
REFS_DIR = ROOT / "refs"
LOCK_TYPE_REF_DIR = REFS_DIR / "lock_types"
BC_LOG = AUDIT_DIR / "human_pretrain.csv"
TRAJECTORY_DIR = DATA_DIR / "demos" / "smart_trajectories"

for p in (DATA_DIR, SMART_DIR, AUDIT_DIR, CHECKPOINT_DIR, TRAJECTORY_DIR):
    p.mkdir(parents=True, exist_ok=True)

HISTORY = 8
BELIEF_BINS = 64
BASE_CORE_DIM = 24
CORE_DIM = BASE_CORE_DIM + 3 * HISTORY
OBS_DIM = CORE_DIM + BELIEF_BINS


@dataclass
class SmartConfig:
    config_version: int = 16
    hidden_sizes: List[int] = field(default_factory=lambda: [512, 512, 256, 128])
    hold_ms: List[int] = field(default_factory=lambda: [60, 120, 220, 400, 650, 950, 1400])
    use_cuda_if_available: bool = True
    seed: int = 8808

    # Human pretraining
    human_bc_epochs: int = 32
    human_bc_batch: int = 1024
    human_bc_lr: float = 7e-4
    human_success_weight: float = 7.0
    human_success_tail_boost: float = 4.0
    human_fail_helpful_weight: float = 0.75
    human_fail_bad_weight: float = 0.75
    human_negative_margin: float = 0.08
    human_hold_weight_old_data: float = 0.08
    human_hold_weight_smart_data: float = 0.45
    human_max_samples: int = 50000

    # Memory / search model
    meaningful_response_default: float = 0.13
    response_noise_floor: float = 0.055
    best_update_epsilon: float = 0.008
    good_update_epsilon: float = 0.015
    recover_drop: float = 0.14
    belief_sigma: float = 0.20
    belief_uniform_mix: float = 0.025
    belief_strength: float = 0.70
    belief_ramp_width: float = 0.10
    belief_target_width: float = 0.015
    search_min_advance: float = 0.004
    recover_span: float = 0.09
    near_span: float = 0.045
    near_response: float = 0.50
    strong_response: float = 0.72

    # Live execution / vision. v0.13 samples lock motion WHILE F is held.
    # The offline simulator threshold is deliberately separate from the live
    # threshold because the real keyway detector expresses small visible turns
    # as ~0.05-0.12 responses.
    live_max_steps: int = 14
    live_move_settle_ms: int = 10
    live_move_corrections: int = 0
    live_move_tolerance: float = 0.006
    live_probe_window_ms: int = 115
    live_probe_post_ms: int = 70
    live_probe_sample_sleep_ms: int = 1
    live_meaningful_response: float = 0.050
    live_motion_jitter_weight: float = 0.70
    live_use_internal_position: bool = True
    live_success_wait_ms: int = 150
    live_start_wait_ms: int = 100

    # v0.14: identify the visible lock body from the supplied reference images
    # BEFORE every attempt and select a live control budget. The classifier only
    # sees the metal lock face; it never receives ramp/target position.
    live_lock_type_detection: bool = True
    live_lock_type_sample_frames: int = 4
    live_lock_type_sample_gap_ms: int = 18
    live_lock_type_min_confidence: float = 0.42
    live_lock_type_softmax_temp: float = 0.65

    # v0.15 live rules measured by the user. There is NO artificial 7/30 probe
    # stop any more. An attempt continues until SUCCESS, the real lock screen
    # disappears/breaks, or the lock-type time budget expires.
    rusted_budget_sec: float = 10.0
    rusted_meaningful_response: float = 0.030
    player_budget_sec: float = 3.0
    player_meaningful_response: float = 0.050

    # v0.16 live scan geometry. Player locks are deliberately edge-focused: only
    # the left half of the physical pick range is searched, with smaller gaps so
    # steep/narrow ramps are harder to skip. Rusted has time for a fast full-range
    # sweep and uses much larger coarse strides. These are LIVE guardrails only;
    # the neural tensor/action space stays checkpoint-compatible.
    live_search_goal: float = 0.75                 # legacy/fallback only
    live_search_goal_deadline_frac: float = 0.62   # legacy/fallback only
    player_scan_limit: float = 0.50
    rusted_scan_limit: float = 1.00
    player_search_goal: float = 0.50
    rusted_search_goal: float = 1.00
    player_search_goal_deadline_frac: float = 0.42
    rusted_search_goal_deadline_frac: float = 0.64
    live_search_stride_rusted: float = 0.105
    live_search_stride_player: float = 0.050
    live_search_max_stride_rusted: float = 0.145
    live_search_max_stride_player: float = 0.060
    live_rescan_stride_scale: float = 0.82

    # Ramp confirmation is also lock-type-specific. Player ramps can be steep, so
    # an ~0.09 response is enough to stop the broad scan and the confirmation
    # nudge is tiny. Rusted tolerates a larger nearby confirmation step.
    live_ramp_confirm_abs: float = 0.120            # legacy/fallback only
    live_ramp_confirm_multiplier: float = 1.65
    live_ramp_confirm_step: float = 0.018           # legacy/fallback only
    player_ramp_confirm_abs: float = 0.085
    rusted_ramp_confirm_abs: float = 0.070
    player_ramp_confirm_step: float = 0.008
    rusted_ramp_confirm_step: float = 0.014
    live_local_no_gain_limit: int = 3
    live_local_escape_stride: float = 0.060
    player_local_span: float = 0.030
    rusted_local_span: float = 0.055

    # v0.16 finish: a confirmed strong basin enters a short micro-bracket first,
    # then COMMITs a long F hold at the best measured position. This specifically
    # fixes the live behaviour where the agent found a sweet area but kept tapping
    # or wandering instead of actually trying to turn the lock through.
    live_finish_latch_response: float = 0.58        # legacy/fallback only
    live_finish_force_response: float = 0.72        # legacy/fallback only
    live_finish_offset: float = 0.006               # legacy/fallback only
    player_finish_latch_response: float = 0.30
    rusted_finish_latch_response: float = 0.24
    player_finish_force_response: float = 0.36
    rusted_finish_force_response: float = 0.32
    player_finish_offset: float = 0.0025
    rusted_finish_offset: float = 0.0035
    player_finish_micro_probes: int = 2
    rusted_finish_micro_probes: int = 4
    live_finish_max_offsets: int = 7

    # Conservative end-of-attempt detector. Pick visibility is NEVER used for
    # position; it is only a fallback signal that the minigame/pick disappeared.
    live_end_ui_score: float = 1.50
    live_end_missing_frames: int = 2
    real_rollout_min_steps: int = 64

    # Reward
    reward_first_signal: float = 6.0
    reward_progress_gain: float = 34.0
    reward_best_gain: float = 12.0
    reward_absolute: float = 2.5
    reward_recover: float = 2.5
    reward_regression: float = 10.0
    reward_probe_cost: float = 0.08
    reward_time_cost: float = 0.60
    reward_success: float = 140.0
    reward_speed_bonus: float = 65.0
    reward_fail: float = -18.0

    # PPO shared by simulator + real adaptation. v0.11 is intentionally
    # conservative: v0.10 logs showed repeated 20-50 point collapses from a
    # strong distilled policy. Huge rollouts need tiny policy updates, not a
    # larger learning rate.
    ppo_lr: float = 5.0e-5
    ppo_gamma: float = 0.985
    ppo_gae_lambda: float = 0.95
    ppo_clip: float = 0.08
    ppo_value_coef: float = 0.35
    ppo_entropy_coef: float = 0.0030
    ppo_entropy_min: float = 0.0006
    ppo_entropy_decay: float = 0.992
    ppo_epochs: int = 2
    ppo_minibatch: int = 8192
    ppo_max_grad_norm: float = 0.45
    ppo_target_kl: float = 0.004
    ppo_hard_kl: float = 0.007
    ppo_reward_scale: float = 0.05
    ppo_adv_clip: float = 6.0
    ppo_champion_anchor_coef: float = 0.22
    ppo_champion_anchor_hard_kl: float = 0.040
    ppo_elite_coef: float = 0.055
    ppo_elite_batch: int = 1024
    ppo_min_lr: float = 4.0e-6
    ppo_max_lr: float = 6.0e-5

    # Ultra-fast vector simulator
    sim_envs: int = 2048
    sim_rollout_steps: int = 32
    sim_default_updates: int = 200
    sim_warmup_episodes: int = 12000
    sim_warmup_epochs: int = 3
    sim_warmup_batch: int = 8192
    sim_warmup_lr: float = 8e-4
    sim_max_steps: int = 160  # safety ceiling only; virtual TIME is the real stop rule
    # v0.15 simulator rules. L0/Rusted receives a 10 s virtual clock; player-lock
    # levels receive 3 s. There is no fake seven-wrong-position termination.
    sim_virtual_time_limit_sec: float = 3.0
    sim_rusted_time_limit_sec: float = 10.0
    sim_use_wrong_hit_limit: bool = False
    sim_max_wrong_hits: int = 9999  # metric/backward compatibility only
    sim_wrong_hit_penalty: float = 0.0
    # HOLD-TO-90 model: position sets the maximum possible lock turn, while
    # F-hold duration determines how deeply the lock actually turns toward it.
    # A short tap can reveal a ramp but cannot reach 90 degrees in TARGET.
    sim_turn_tau_ms_low: float = 180.0
    sim_turn_tau_ms_high: float = 430.0
    sim_success_rotation: float = 0.955
    sim_underhold_penalty: float = 0.10
    sim_false_spike_rate: float = 0.0
    sim_noise_scale: float = 0.55
    live_min_attempt_budget_sec: float = 3.0
    live_max_wrong_hits: int = 7
    sim_curriculum_max: int = 4
    sim_level_up_success: float = 0.72
    sim_eval_episodes: int = 4096
    sim_domain_randomization: float = 1.0
    sim_checkpoint_every: int = 10

    @staticmethod
    def load() -> "SmartConfig":
        defaults = asdict(SmartConfig())
        raw: Dict[str, object] = {}
        if CONFIG_PATH.exists():
            try:
                obj = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
                if isinstance(obj, dict):
                    raw.update(obj)
            except Exception:
                pass
        valid = set(SmartConfig.__dataclass_fields__.keys())
        merged = dict(defaults)
        for k, v in raw.items():
            if k in valid:
                merged[k] = v
        cfg = SmartConfig(**merged)
        # One-time v0.10 -> v0.11 migration. Old configs contained PPO settings
        # that produced repeated catastrophic forgetting with huge MAX rollouts.
        # Preserve all unrelated user/calibration settings, but migrate the
        # stability-critical PPO fields.
        try:
            old_version = int(raw.get("config_version", 10)) if raw else 11
        except Exception:
            old_version = 10
        if old_version < 11:
            stable = SmartConfig()
            for k in (
                "ppo_lr", "ppo_clip", "ppo_value_coef", "ppo_entropy_coef",
                "ppo_entropy_min", "ppo_entropy_decay", "ppo_epochs",
                "ppo_max_grad_norm", "ppo_target_kl", "ppo_hard_kl",
                "ppo_reward_scale", "ppo_adv_clip", "ppo_champion_anchor_coef",
                "ppo_champion_anchor_hard_kl", "ppo_elite_coef",
                "ppo_elite_batch", "ppo_min_lr", "ppo_max_lr",
            ):
                setattr(cfg, k, getattr(stable, k))
        # v0.12/v0.13 keep the same network/action space fully checkpoint compatible.
        # v0.13 only changes live observation capture and mouse-position accounting,
        # so the user's trained v0.12 champion continues unchanged.
        if old_version < 13:
            cfg.config_version = 13
            # Live-only defaults are intentionally migrated even when an older config
            # exists, because v0.12's 0.13 threshold ignored visibly rotating locks.
            fresh = SmartConfig()
            for k in (
                "live_move_settle_ms", "live_move_corrections", "live_move_tolerance",
                "live_probe_window_ms", "live_probe_post_ms", "live_probe_sample_sleep_ms",
                "live_meaningful_response", "live_motion_jitter_weight",
                "live_use_internal_position",
            ):
                setattr(cfg, k, getattr(fresh, k))
        if old_version < 14:
            cfg.config_version = 14
            # v0.14 adds only live controller/classifier settings; network dimensions
            # and checkpoint tensors remain 100% compatible with v0.12/v0.13.
            fresh = SmartConfig()
            for k in (
                "live_lock_type_detection", "live_lock_type_sample_frames",
                "live_lock_type_sample_gap_ms", "live_lock_type_min_confidence",
                "live_lock_type_softmax_temp", "rusted_budget_sec",
                "rusted_meaningful_response", "player_budget_sec",
                "player_meaningful_response",
            ):
                setattr(cfg, k, getattr(fresh, k))
        if old_version < 15:
            cfg.config_version = 15
            # v0.15 removes the artificial probe-count stop and adds a live-only
            # coverage/ramp-confirm/finish safety layer. Observation/action tensor
            # sizes are unchanged, so existing v0.12-v0.14 checkpoints still load.
            fresh = SmartConfig()
            for k in (
                "live_search_goal", "live_search_goal_deadline_frac",
                "live_search_stride_rusted", "live_search_stride_player",
                "live_search_max_stride_rusted", "live_search_max_stride_player",
                "live_ramp_confirm_abs", "live_ramp_confirm_multiplier",
                "live_ramp_confirm_step", "live_local_no_gain_limit",
                "live_local_escape_stride", "live_finish_latch_response",
                "live_finish_force_response", "live_finish_offset",
                "live_finish_max_offsets", "live_end_ui_score",
                "live_end_missing_frames", "sim_rusted_time_limit_sec",
                "sim_use_wrong_hit_limit", "sim_max_wrong_hits",
                "sim_wrong_hit_penalty", "sim_max_steps",
            ):
                setattr(cfg, k, getattr(fresh, k))
        if old_version < 16:
            cfg.config_version = 16
            # v0.16 changes LIVE search geometry and finish commitment only. Existing
            # v0.12-v0.15 neural checkpoints remain tensor/action compatible.
            fresh = SmartConfig()
            for k in (
                "player_scan_limit", "rusted_scan_limit",
                "player_search_goal", "rusted_search_goal",
                "player_search_goal_deadline_frac", "rusted_search_goal_deadline_frac",
                "live_search_stride_rusted", "live_search_stride_player",
                "live_search_max_stride_rusted", "live_search_max_stride_player",
                "live_rescan_stride_scale",
                "player_ramp_confirm_abs", "rusted_ramp_confirm_abs",
                "player_ramp_confirm_step", "rusted_ramp_confirm_step",
                "player_local_span", "rusted_local_span",
                "player_finish_latch_response", "rusted_finish_latch_response",
                "player_finish_force_response", "rusted_finish_force_response",
                "player_finish_offset", "rusted_finish_offset",
                "player_finish_micro_probes", "rusted_finish_micro_probes",
                "live_finish_max_offsets",
            ):
                setattr(cfg, k, getattr(fresh, k))
        CONFIG_PATH.write_text(json.dumps(asdict(cfg), indent=2), encoding="utf-8")
        return cfg


# v0.16.3 SIM GEOMETRY GUARD
# --------------------------
# Human Teach rows are excellent for observable quantities (vision baseline,
# response threshold, F timing and successful action sequences), but they do NOT
# identify the hidden geometric ramp/target edges. Inferring geometric width from
# scattered probe positions can make a narrow player ramp look absurdly wide.
# Therefore human demos are explicitly forbidden from changing simulator geometry.
#
# Half-widths below are conservative priors expressed as fractions of the full
# physical pick travel. L0 is Rusted. L1..L4 are progressively harder player
# locks; L3/L4 both represent the hard/Enforced end of the curriculum.
SIM_GEOMETRY_VERSION = 163
SAFE_SIM_LEVEL_NAMES = ("Rusted", "Basic", "Medium", "Enforced", "Enforced-hard")
SAFE_SIM_RAMP_LOW  = np.asarray([0.060, 0.018, 0.015, 0.012, 0.010], dtype=np.float32)
SAFE_SIM_RAMP_HIGH = np.asarray([0.120, 0.045, 0.036, 0.030, 0.025], dtype=np.float32)
SAFE_SIM_TARGET_LOW  = np.asarray([0.0080, 0.0035, 0.0030, 0.0025, 0.0020], dtype=np.float32)
SAFE_SIM_TARGET_HIGH = np.asarray([0.0200, 0.0090, 0.0075, 0.0060, 0.0050], dtype=np.float32)
SAFE_SIM_CURVE_LOW  = np.asarray([0.80, 1.60, 1.80, 2.00, 2.20], dtype=np.float32)
SAFE_SIM_CURVE_HIGH = np.asarray([1.80, 3.20, 3.60, 4.00, 4.40], dtype=np.float32)
SAFE_SIM_PLAYER_LIMIT = 0.50
SAFE_SIM_RUSTED_LIMIT = 1.00
SAFE_SIM_PLAYER_STRIDE = 0.050
SAFE_SIM_RUSTED_STRIDE = 0.110

# Global belief/profile priors. The actual VectorLockSim geometry is generated
# from the per-level arrays above; these values are intentionally narrow and are
# used only where a single generic belief width is required.
SAFE_PROFILE_RAMP_MEDIAN = 0.032
SAFE_PROFILE_RAMP_LOW = 0.015
SAFE_PROFILE_RAMP_HIGH = 0.050
SAFE_PROFILE_TARGET_MEDIAN = 0.006
SAFE_PROFILE_TARGET_LOW = 0.0025
SAFE_PROFILE_TARGET_HIGH = 0.010


@dataclass
class SimProfile:
    meaningful_response: float = 0.13
    baseline_median: float = 0.078
    baseline_p90: float = 0.11
    ramp_width_median: float = SAFE_PROFILE_RAMP_MEDIAN
    ramp_width_low: float = SAFE_PROFILE_RAMP_LOW
    ramp_width_high: float = SAFE_PROFILE_RAMP_HIGH
    target_width_median: float = SAFE_PROFILE_TARGET_MEDIAN
    target_width_low: float = SAFE_PROFILE_TARGET_LOW
    target_width_high: float = SAFE_PROFILE_TARGET_HIGH
    episode_budget_median: float = 3.00
    probe_interval_median: float = 0.46
    source_files: int = 0
    source_episodes: int = 0
    source_successes: int = 0
    geometry_mode: str = "safe-priors-v0.16.3"
    fitted_at: str = ""

    @staticmethod
    def load() -> "SimProfile":
        prof = SimProfile()
        if PROFILE_PATH.exists():
            try:
                raw = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
                valid = set(SimProfile.__dataclass_fields__.keys())
                prof = SimProfile(**{k: v for k, v in raw.items() if k in valid})
            except Exception:
                prof = SimProfile()
        # HARD SAFETY VETO: old/bad Human Teach fits such as ramp=0.165 or
        # target=0.040 are never allowed back into the simulator, even before
        # FIT SIM PROFILE is run. Human data cannot override hidden geometry.
        prof.ramp_width_median = SAFE_PROFILE_RAMP_MEDIAN
        prof.ramp_width_low = SAFE_PROFILE_RAMP_LOW
        prof.ramp_width_high = SAFE_PROFILE_RAMP_HIGH
        prof.target_width_median = SAFE_PROFILE_TARGET_MEDIAN
        prof.target_width_low = SAFE_PROFILE_TARGET_LOW
        prof.target_width_high = SAFE_PROFILE_TARGET_HIGH
        prof.geometry_mode = "safe-priors-v0.16.3"
        return prof

    def save(self) -> None:
        PROFILE_PATH.write_text(json.dumps(asdict(self), indent=2), encoding="utf-8")


@dataclass
class SmartMemory:
    pos: float = 0.0
    response: float = 0.0
    prev_response: float = 0.0
    best_response: float = 0.0
    best_pos: float = 0.0
    best_known: bool = False
    last_good_pos: float = 0.0
    good_known: bool = False
    furthest_pos: float = 0.0
    last_target: float = 0.0
    last_move: float = 0.0
    last_hold_idx: int = 0
    last_reward: float = 0.0
    elapsed: float = 0.0
    step_no: int = 0
    hist_pos: np.ndarray = field(default_factory=lambda: np.zeros(HISTORY, dtype=np.float32))
    hist_response: np.ndarray = field(default_factory=lambda: np.zeros(HISTORY, dtype=np.float32))
    hist_hold: np.ndarray = field(default_factory=lambda: np.zeros(HISTORY, dtype=np.float32))
    belief: np.ndarray = field(default_factory=lambda: np.ones(BELIEF_BINS, dtype=np.float32) / BELIEF_BINS)

    def clone(self) -> "SmartMemory":
        return SmartMemory(
            pos=self.pos,
            response=self.response,
            prev_response=self.prev_response,
            best_response=self.best_response,
            best_pos=self.best_pos,
            best_known=self.best_known,
            last_good_pos=self.last_good_pos,
            good_known=self.good_known,
            furthest_pos=self.furthest_pos,
            last_target=self.last_target,
            last_move=self.last_move,
            last_hold_idx=self.last_hold_idx,
            last_reward=self.last_reward,
            elapsed=self.elapsed,
            step_no=self.step_no,
            hist_pos=self.hist_pos.copy(),
            hist_response=self.hist_response.copy(),
            hist_hold=self.hist_hold.copy(),
            belief=self.belief.copy(),
        )


BELIEF_GRID = np.linspace(0.0, 1.0, BELIEF_BINS, dtype=np.float32)


def set_seeds(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def choose_device(cfg: SmartConfig) -> torch.device:
    if cfg.use_cuda_if_available and torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def clamp01(x: float) -> float:
    return float(np.clip(x, 0.0, 1.0))


def safe_float(v, default: float = 0.0) -> float:
    try:
        x = float(v)
        return x if math.isfinite(x) else default
    except Exception:
        return default


def append_csv(path: Path, fields: Sequence[str], row: Dict[str, object]) -> None:
    exists = path.exists()
    with path.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(fields), extrasaction="ignore")
        if not exists:
            w.writeheader()
        w.writerow(row)


def hold_transfer_fraction(hold_ms: float, tau_ms: float) -> float:
    """Observable turn-depth fraction caused by holding F.

    Position controls the spatial turn cap; hold time only controls how far the
    lock travels toward that cap. This is the key HOLD-TO-90 mechanic.
    """
    h = max(0.0, float(hold_ms))
    tau = max(20.0, float(tau_ms))
    return float(np.clip(1.0 - math.exp(-h / tau), 0.0, 1.0))


def nominal_hold_fraction(cfg: SmartConfig, hold_idx: int) -> float:
    i = min(max(int(hold_idx), 0), len(cfg.hold_ms)-1)
    tau = 0.5 * (float(cfg.sim_turn_tau_ms_low) + float(cfg.sim_turn_tau_ms_high))
    return hold_transfer_fraction(float(cfg.hold_ms[i]), tau)


def update_belief(mem: SmartMemory, observed: float, profile: SimProfile, cfg: SmartConfig, hold_idx: int = 0) -> None:
    # Bayesian-like likelihood update. It never sees the hidden target; it only
    # asks "if target were at candidate x, how compatible is the observed wobble?"
    ramp = float(np.clip(profile.ramp_width_median, 0.025, 0.25))
    target = float(np.clip(profile.target_width_median, 0.002, ramp * 0.55))
    dist = np.abs(BELIEF_GRID - float(mem.pos))
    pred = np.zeros_like(dist)
    inside_target = dist <= target
    pred[inside_target] = 1.0
    mid = (dist > target) & (dist < ramp)
    if ramp > target + 1e-5:
        z = 1.0 - (dist[mid] - target) / (ramp - target)
        pred[mid] = np.power(np.clip(z, 0.0, 1.0), 1.35)
    # The same spatial location turns less on a short tap than on a long hold.
    # Scale the predicted observable response by the known F-hold duration; this
    # uses no hidden target information.
    pred *= nominal_hold_fraction(cfg, hold_idx)
    # Observed low-level vision has a baseline, so compare a de-biased signal.
    floor = min(profile.baseline_p90, cfg.meaningful_response_default * 0.9)
    obs = clamp01((observed - floor) / max(0.20, 1.0 - floor))
    sigma = max(0.08, float(cfg.belief_sigma))
    like = np.exp(-0.5 * ((pred - obs) / sigma) ** 2) + 0.035
    # Keep low responses informative but conservative so one noisy probe cannot
    # delete a large part of the search space.
    strength = float(np.clip(cfg.belief_strength, 0.1, 1.5))
    post = mem.belief.astype(np.float64) * np.power(like.astype(np.float64), strength)
    if not np.isfinite(post).all() or post.sum() <= 1e-12:
        post = np.ones(BELIEF_BINS, dtype=np.float64)
    post /= post.sum()
    mix = float(np.clip(cfg.belief_uniform_mix, 0.0, 0.25))
    post = (1.0 - mix) * post + mix / BELIEF_BINS
    mem.belief = post.astype(np.float32)


def memory_after_probe(
    mem: SmartMemory,
    pos: float,
    response: float,
    hold_idx: int,
    reward: float,
    elapsed: float,
    threshold: float,
    profile: SimProfile,
    cfg: SmartConfig,
) -> None:
    old_pos = mem.pos
    old_response = mem.response
    response = clamp01(response)
    mem.prev_response = old_response
    mem.pos = clamp01(pos)
    mem.response = response
    mem.last_move = mem.pos - old_pos
    mem.last_target = mem.pos
    mem.last_hold_idx = int(hold_idx)
    mem.last_reward = float(reward)
    mem.elapsed = max(0.0, float(elapsed))
    mem.step_no += 1
    mem.furthest_pos = max(mem.furthest_pos, mem.pos)

    if (not mem.best_known) or response > mem.best_response + cfg.best_update_epsilon:
        mem.best_response = response
        mem.best_pos = mem.pos
        mem.best_known = True
    else:
        mem.best_response = max(mem.best_response, response)

    if response >= threshold or response > old_response + cfg.good_update_epsilon:
        mem.last_good_pos = mem.pos
        mem.good_known = True

    mem.hist_pos[:-1] = mem.hist_pos[1:]
    mem.hist_pos[-1] = mem.pos
    mem.hist_response[:-1] = mem.hist_response[1:]
    mem.hist_response[-1] = response
    mem.hist_hold[:-1] = mem.hist_hold[1:]
    mem.hist_hold[-1] = nominal_hold_fraction(cfg, hold_idx)
    update_belief(mem, response, profile, cfg, hold_idx)


def belief_summary(b: np.ndarray) -> Tuple[float, float, float, float]:
    b = np.asarray(b, dtype=np.float64)
    s = b.sum()
    if s <= 1e-12:
        b = np.ones(BELIEF_BINS, dtype=np.float64) / BELIEF_BINS
    else:
        b = b / s
    mean = float((b * BELIEF_GRID).sum())
    var = float((b * (BELIEF_GRID - mean) ** 2).sum())
    entropy = float(-(b * np.log(np.clip(b, 1e-12, 1.0))).sum() / math.log(BELIEF_BINS))
    peak = float(BELIEF_GRID[int(np.argmax(b))])
    return mean, math.sqrt(max(0.0, var)), entropy, peak


def obs_from_memory(mem: SmartMemory, budget: float, threshold: float, hold_count: int, cfg: SmartConfig) -> np.ndarray:
    improvement = float(np.clip(mem.response - mem.prev_response, -0.30, 0.30) / 0.30)
    found = 1.0 if mem.best_known and mem.best_response >= threshold else -1.0
    recover = 1.0 if (
        mem.best_known and mem.best_response >= threshold and mem.response < mem.best_response - cfg.recover_drop
    ) else -1.0
    best_pos = mem.best_pos if mem.best_known else 0.5
    good_pos = mem.last_good_pos if mem.good_known else 0.5
    hold_norm = 0.0 if hold_count <= 1 else 2.0 * mem.last_hold_idx / (hold_count - 1) - 1.0
    elapsed_frac = float(np.clip(mem.elapsed / max(0.1, budget), 0.0, 1.5))
    remaining = float(np.clip(1.0 - mem.elapsed / max(0.1, budget), 0.0, 1.0))
    bmean, bstd, bent, bpeak = belief_summary(mem.belief)
    ratio = mem.response / max(0.03, mem.best_response) if mem.best_known else 0.0

    core = np.asarray([
        2.0 * mem.pos - 1.0,
        2.0 * mem.response - 1.0,
        2.0 * mem.prev_response - 1.0,
        improvement,
        2.0 * mem.best_response - 1.0,
        2.0 * best_pos - 1.0,
        float(np.clip(mem.pos - best_pos, -1.0, 1.0)),
        2.0 * good_pos - 1.0,
        float(np.clip(mem.pos - good_pos, -1.0, 1.0)),
        2.0 * mem.furthest_pos - 1.0,
        2.0 * mem.last_target - 1.0,
        float(np.clip(mem.last_move, -1.0, 1.0)),
        hold_norm,
        float(np.tanh(mem.last_reward / 20.0)),
        float(np.clip(2.0 * elapsed_frac - 1.0, -1.0, 2.0)),
        2.0 * remaining - 1.0,
        2.0 * float(np.clip(mem.step_no / max(1, cfg.live_max_steps), 0.0, 1.0)) - 1.0,
        found,
        recover,
        float(np.clip(2.0 * ratio - 1.0, -1.0, 1.0)),
        2.0 * bmean - 1.0,
        float(np.clip(2.5 * bstd - 1.0, -1.0, 1.0)),
        2.0 * bent - 1.0,
        2.0 * bpeak - 1.0,
    ], dtype=np.float32)
    history_feat = np.empty(3 * HISTORY, dtype=np.float32)
    history_feat[0::3] = 2.0 * mem.hist_pos.astype(np.float32) - 1.0
    history_feat[1::3] = 2.0 * mem.hist_response.astype(np.float32) - 1.0
    history_feat[2::3] = 2.0 * mem.hist_hold.astype(np.float32) - 1.0
    # Uniform belief -> near zero; concentrated bins become positive/negative features.
    belief_feat = np.tanh(2.0 * (mem.belief.astype(np.float32) * BELIEF_BINS - 1.0))
    out = np.concatenate([core, history_feat, belief_feat]).astype(np.float32)
    assert out.shape == (OBS_DIM,), out.shape
    return out


def action_bounds(mem: SmartMemory, threshold: float, cfg: SmartConfig) -> Tuple[float, float, str]:
    found = mem.best_known and mem.best_response >= threshold
    recover = found and mem.response < mem.best_response - cfg.recover_drop
    if not found:
        # Search always moves right from the last probe, but the policy chooses how
        # aggressively. It may jump a lot; unlike v0.7 there is no ±0.12 ceiling.
        low = min(0.995, max(mem.pos + cfg.search_min_advance, mem.furthest_pos + cfg.search_min_advance))
        return low, 1.0, "SEARCH"
    if recover:
        span = cfg.recover_span
        return max(0.0, mem.best_pos - span), min(1.0, mem.best_pos + span), "RECOVER"
    if mem.response >= cfg.strong_response:
        span = max(0.010, cfg.near_span * 0.55)
        center = mem.pos if mem.response >= mem.best_response - 0.04 else mem.best_pos
        return max(0.0, center - span), min(1.0, center + span), "TARGET"
    if mem.response >= cfg.near_response or mem.best_response >= cfg.strong_response:
        span = cfg.near_span
        return max(0.0, mem.best_pos - span), min(1.0, mem.best_pos + span), "NEAR"
    span = max(cfg.near_span * 1.8, cfg.recover_span)
    return max(0.0, mem.best_pos - span), min(1.0, mem.best_pos + span), "RAMP"


def unit_to_target(unit_action: float, mem: SmartMemory, threshold: float, cfg: SmartConfig) -> Tuple[float, float, float, str]:
    low, high, phase = action_bounds(mem, threshold, cfg)
    if high <= low + 1e-6:
        return low, low, high, phase
    target = low + clamp01(unit_action) * (high - low)
    return clamp01(target), low, high, phase


def target_to_unit(target: float, mem: SmartMemory, threshold: float, cfg: SmartConfig) -> float:
    low, high, _phase = action_bounds(mem, threshold, cfg)
    if high <= low + 1e-6:
        return 0.5
    return clamp01((clamp01(target) - low) / (high - low))


class SmartActorCritic(nn.Module):
    def __init__(self, cfg: SmartConfig):
        super().__init__()
        dims = [OBS_DIM, *cfg.hidden_sizes]
        layers: List[nn.Module] = []
        for i in range(len(dims) - 1):
            lin = nn.Linear(dims[i], dims[i + 1])
            nn.init.orthogonal_(lin.weight, gain=math.sqrt(2.0))
            nn.init.zeros_(lin.bias)
            layers += [lin, nn.SiLU(), nn.LayerNorm(dims[i + 1])]
        self.body = nn.Sequential(*layers)
        last = dims[-1]
        self.beta_head = nn.Linear(last, 2)
        self.hold_head = nn.Linear(last, len(cfg.hold_ms))
        self.value_head = nn.Linear(last, 1)
        nn.init.orthogonal_(self.beta_head.weight, gain=0.01)
        nn.init.zeros_(self.beta_head.bias)
        nn.init.orthogonal_(self.hold_head.weight, gain=0.01)
        nn.init.zeros_(self.hold_head.bias)
        nn.init.orthogonal_(self.value_head.weight, gain=1.0)
        nn.init.zeros_(self.value_head.bias)

    def forward(self, obs: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        h = self.body(obs)
        raw = self.beta_head(h)
        alpha = F.softplus(raw[..., 0]) + 1.05
        beta = F.softplus(raw[..., 1]) + 1.05
        hold = self.hold_head(h)
        value = self.value_head(h).squeeze(-1)
        return alpha, beta, hold, value


@dataclass
class PPOStep:
    obs: np.ndarray
    unit_action: float
    hold_action: int
    logp: float
    value: float
    reward: float
    done: bool


@dataclass
class HumanSample:
    obs: np.ndarray
    unit_action: float
    hold_action: int
    weight: float
    negative: bool
    hold_weight: float
    source: str


class SmartStats:
    def __init__(self):
        self.data: Dict[str, object] = {
            "created": time.strftime("%Y-%m-%d %H:%M:%S"),
            "human_bc_runs": 0,
            "human_samples": 0,
            "sim_ppo_updates": 0,
            "sim_transitions": 0,
            "sim_best_eval_rate": 0.0,
            "sim_curriculum_level": 0,
            "real_train_attempts": 0,
            "real_train_successes": 0,
            "real_eval_attempts": 0,
            "real_eval_successes": 0,
            "real_ppo_updates": 0,
            "last_hash": "",
            "initial_hash": "",
        }
        if STATS_PATH.exists():
            try:
                raw = json.loads(STATS_PATH.read_text(encoding="utf-8"))
                if isinstance(raw, dict):
                    self.data.update(raw)
            except Exception:
                pass

    def save(self) -> None:
        tmp = STATS_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data, indent=2), encoding="utf-8")
        tmp.replace(STATS_PATH)

    def inc(self, key: str, amount: int = 1) -> None:
        self.data[key] = int(self.data.get(key, 0) or 0) + amount


class SmartRuntime:
    def __init__(self, classic_cfg: classic.Config, cfg: SmartConfig):
        self.classic_cfg = classic_cfg
        self.cfg = cfg
        self.profile = SimProfile.load()
        self.device = choose_device(cfg)
        self.net = SmartActorCritic(cfg).to(self.device)
        self.optimizer = torch.optim.Adam(self.net.parameters(), lr=cfg.ppo_lr, eps=1e-5)
        self.stats = SmartStats()
        self.calibration_model = classic.QModel(classic_cfg)
        # Optional immutable anchors supplied by the offline champion trainer.
        # They are deliberately not serialized into normal checkpoints.
        self.ppo_anchor_net: Optional[SmartActorCritic] = None
        self.ppo_elite_obs: Optional[np.ndarray] = None
        self.ppo_elite_action: Optional[np.ndarray] = None
        self.ppo_elite_hold: Optional[np.ndarray] = None
        self.load_or_init()

    def model_hash(self) -> str:
        h = hashlib.sha256()
        for name, t in sorted(self.net.state_dict().items()):
            h.update(name.encode("utf-8"))
            a = t.detach().cpu().contiguous().numpy()
            h.update(str(a.shape).encode("ascii"))
            h.update(a.tobytes())
        return h.hexdigest()

    def save(self, path: Path = LATEST_CKPT, optimizer: bool = True) -> None:
        obj = {
            "version": 12,
            "obs_dim": OBS_DIM,
            "hold_ms": self.cfg.hold_ms,
            "hidden_sizes": self.cfg.hidden_sizes,
            "state_dict": self.net.state_dict(),
            "config": asdict(self.cfg),
            "profile": asdict(self.profile),
            "stats": dict(self.stats.data),
        }
        if optimizer:
            obj["optimizer"] = self.optimizer.state_dict()
        tmp = path.with_suffix(path.suffix + ".tmp")
        torch.save(obj, tmp)
        tmp.replace(path)
        self.stats.data["last_hash"] = self.model_hash()
        self.stats.save()

    def load_or_init(self) -> None:
        if LATEST_CKPT.exists():
            try:
                ck = torch.load(LATEST_CKPT, map_location=self.device)
                if int(ck.get("obs_dim", -1)) != OBS_DIM:
                    raise ValueError("observation shape changed")
                if list(map(int, ck.get("hold_ms", []))) != list(map(int, self.cfg.hold_ms)):
                    raise ValueError("hold action space changed")
                self.net.load_state_dict(ck["state_dict"])
                if "optimizer" in ck:
                    self.optimizer.load_state_dict(ck["optimizer"])
                if isinstance(ck.get("stats"), dict):
                    # stats.json remains authoritative if it exists, but recover missing keys.
                    for k, v in ck["stats"].items():
                        self.stats.data.setdefault(k, v)
                print(f"Loaded SMART checkpoint: {LATEST_CKPT.name} | hash={self.model_hash()[:12]}")
                return
            except Exception as exc:
                bad = SMART_DIR / f"smart_incompatible_{time.strftime('%Y%m%d_%H%M%S')}.pt"
                try:
                    shutil.move(str(LATEST_CKPT), str(bad))
                except Exception:
                    pass
                print(f"[WARN] SMART checkpoint incompatible; moved aside: {exc}")
        self.save(LATEST_CKPT)
        if not INITIAL_CKPT.exists():
            shutil.copy2(LATEST_CKPT, INITIAL_CKPT)
        ph = self.model_hash()
        self.stats.data["initial_hash"] = self.stats.data.get("initial_hash") or ph
        self.stats.data["last_hash"] = ph
        self.stats.save()
        print(f"Created fresh SMART policy | hash={ph[:12]}")


def policy_dist(rt: SmartRuntime, obs: torch.Tensor) -> Tuple[Beta, Categorical, torch.Tensor]:
    alpha, beta, hold_logits, value = rt.net(obs)
    return Beta(alpha, beta), Categorical(logits=hold_logits), value


def policy_action(rt: SmartRuntime, obs: np.ndarray, deterministic: bool) -> Tuple[float, int, float, float, float, np.ndarray]:
    x = torch.as_tensor(obs, dtype=torch.float32, device=rt.device).unsqueeze(0)
    with torch.inference_mode():
        bd, hd, value = policy_dist(rt, x)
        if deterministic:
            unit = bd.mean.clamp(1e-4, 1.0 - 1e-4)
            hold = torch.argmax(hd.logits, dim=-1)
        else:
            unit = bd.sample().clamp(1e-4, 1.0 - 1e-4)
            hold = hd.sample()
        logp = bd.log_prob(unit) + hd.log_prob(hold)
        mean = float(bd.mean.item())
        hprob = torch.softmax(hd.logits, dim=-1).squeeze(0).cpu().numpy()
    return float(unit.item()), int(hold.item()), float(logp.item()), float(value.item()), mean, hprob


def fit_sim_profile(rt: SmartRuntime, verbose: bool = True) -> SimProfile:
    """Fit only OBSERVABLE simulator quantities from Human Teach data.

    v0.16.3 deliberately does *not* infer hidden ramp/target geometry from
    probe positions. A demo tells us what the screen sensor measured at sampled
    positions; it does not reveal the true ramp edges. Treating scattered strong
    probes as geometric edge samples caused the old absurd ramp halfwidth=0.165.

    Safe per-lock geometry is generated in VectorLockSim from fixed conservative
    priors. Human data may fit the vision baseline/meaningful threshold and report
    human probe cadence, but it cannot widen the simulated ramp/target.
    """
    files = sorted((DATA_DIR / "demos").glob("demo_*.csv"))
    responses: List[float] = []
    intervals: List[float] = []
    episodes = 0
    successes = 0
    skipped_untrusted_files = 0

    for path in files:
        try:
            with path.open("r", newline="", encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
        except Exception:
            continue
        grouped: Dict[int, List[Dict[str, str]]] = {}
        for r in rows:
            eid = int(safe_float(r.get("episode_id"), 0))
            grouped.setdefault(eid, []).append(r)
        file_successes = sum(1 for ep in grouped.values() if ep and int(safe_float(ep[-1].get("episode_success"), -1)) == 1)
        if grouped and file_successes == 0 and path.name.startswith("demo_smart_"):
            skipped_untrusted_files += 1
            continue
        for ep in grouped.values():
            if not ep:
                continue
            episodes += 1
            status = int(safe_float(ep[-1].get("episode_success"), -1))
            if status == 1:
                successes += 1
            prev_t = None
            for r in ep:
                resp = safe_float(r.get("response"), float("nan"))
                t = safe_float(r.get("elapsed"), float("nan"))
                if math.isfinite(resp):
                    responses.append(resp)
                if prev_t is not None and math.isfinite(t) and t > prev_t:
                    dt = t - prev_t
                    if 0.05 <= dt <= 2.0:
                        intervals.append(dt)
                prev_t = t if math.isfinite(t) else prev_t

    prof = SimProfile.load()

    # Observable sensor fit only. Use the lower part of the response distribution
    # and clamp aggressively so a few real ramp responses cannot become "noise".
    if responses:
        arr = np.asarray(responses, dtype=np.float64)
        arr = arr[np.isfinite(arr)]
        if arr.size:
            q45 = float(np.quantile(arr, 0.45))
            low = arr[arr <= min(0.14, max(0.04, q45))]
            if low.size >= 10:
                prof.baseline_median = float(np.clip(np.quantile(low, 0.50), 0.0, 0.09))
                prof.baseline_p90 = float(np.clip(np.quantile(low, 0.92), prof.baseline_median, 0.12))
                prof.meaningful_response = float(np.clip(prof.baseline_p90 + 0.020, 0.085, 0.145))

    # HARD GEOMETRY VETO. These values are *not* estimates from Human Teach.
    # VectorLockSim uses even more specific per-difficulty priors below.
    prof.ramp_width_median = SAFE_PROFILE_RAMP_MEDIAN
    prof.ramp_width_low = SAFE_PROFILE_RAMP_LOW
    prof.ramp_width_high = SAFE_PROFILE_RAMP_HIGH
    prof.target_width_median = SAFE_PROFILE_TARGET_MEDIAN
    prof.target_width_low = SAFE_PROFILE_TARGET_LOW
    prof.target_width_high = SAFE_PROFILE_TARGET_HIGH
    prof.geometry_mode = "safe-priors-v0.16.3"

    # The real game budgets are known controller rules, not something to infer
    # from how quickly the human happened to press Space in a demonstration.
    prof.episode_budget_median = 3.00
    if intervals:
        # Kept as human-cadence telemetry only; VectorLockSim virtual time does
        # not use this value as game physics.
        prof.probe_interval_median = float(np.clip(np.median(intervals), 0.10, 1.20))

    prof.source_files = len(files)
    prof.source_episodes = episodes
    prof.source_successes = successes
    prof.fitted_at = time.strftime("%Y-%m-%d %H:%M:%S")
    prof.save()
    rt.profile = prof

    if verbose:
        print("\n=== SIMULATOR PROFILE FIT v0.16.3 SAFE ===")
        print(f"files={len(files)} trusted_episodes={episodes} successes={successes} skipped-all-fail-smart-files={skipped_untrusted_files}")
        print(
            f"vision baseline median/p90={prof.baseline_median:.3f}/{prof.baseline_p90:.3f} -> "
            f"meaningful={prof.meaningful_response:.3f}"
        )
        print(
            f"geometry=LOCKED SAFE PRIORS (Human Teach cannot change hidden widths) | "
            f"belief ramp~{prof.ramp_width_median:.3f} target~{prof.target_width_median:.3f}"
        )
        print(
            "SIM geometry halfwidths: "
            "L0/Rusted ramp=.060..120 target=.008..020 full-range; "
            "L1/Basic ramp=.018..045 target=.0035..009 left-50%; "
            "L2/Medium ramp=.015..036 target=.003..0075 left-50%; "
            "L3/L4 hard ramp=.010..030 target=.002..006 left-50%"
        )
        print(f"player budget=3.00s | Rusted budget={rt.cfg.sim_rusted_time_limit_sec:.2f}s | human probe cadence telemetry={prof.probe_interval_median:.2f}s")
        print("[GEOMETRY GUARD] Demo responses fit sensor statistics only; they can no longer inflate ramp/target size.")
    return prof


def split_demo_episodes(path: Path) -> List[List[Dict[str, str]]]:
    try:
        with path.open("r", newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
    except Exception:
        return []
    grouped: Dict[int, List[Dict[str, str]]] = {}
    if rows and "episode_id" in rows[0]:
        for r in rows:
            grouped.setdefault(int(safe_float(r.get("episode_id"), 0)), []).append(r)
        return [grouped[k] for k in sorted(grouped)]
    out: List[List[Dict[str, str]]] = []
    cur: List[Dict[str, str]] = []
    prev_e = -1.0
    for r in rows:
        e = safe_float(r.get("elapsed"), 0.0)
        if cur and e + 0.20 < prev_e:
            out.append(cur)
            cur = []
        cur.append(r)
        prev_e = e
    if cur:
        out.append(cur)
    return out


def infer_hold_idx(rt: SmartRuntime, row: Dict[str, str], terminal: bool, success: bool, signal: float) -> Tuple[int, float]:
    if "hold_ms" in row and str(row.get("hold_ms", "")).strip():
        ms = safe_float(row.get("hold_ms"), rt.cfg.hold_ms[0])
        idx = min(range(len(rt.cfg.hold_ms)), key=lambda i: abs(rt.cfg.hold_ms[i] - ms))
        return idx, rt.cfg.human_hold_weight_smart_data
    if terminal and success and signal >= 0.50 and len(rt.cfg.hold_ms) >= 2:
        return len(rt.cfg.hold_ms)-2, rt.cfg.human_hold_weight_old_data
    if signal >= 0.55 and len(rt.cfg.hold_ms) >= 4:
        return min(len(rt.cfg.hold_ms)-1, 4), rt.cfg.human_hold_weight_old_data
    if signal >= 0.20 and len(rt.cfg.hold_ms) >= 3:
        return 2, rt.cfg.human_hold_weight_old_data
    return 0, rt.cfg.human_hold_weight_old_data


def load_human_samples(rt: SmartRuntime) -> Tuple[List[HumanSample], Dict[str, int]]:
    files = sorted((DATA_DIR / "demos").glob("demo_*.csv"))
    samples: List[HumanSample] = []
    cnt = {"files": len(files), "success": 0, "fail": 0, "mixed": 0, "unknown": 0, "positive": 0, "negative": 0, "skipped": 0, "first_moves": 0, "untrusted_files": 0}
    threshold = float(rt.profile.meaningful_response or rt.cfg.meaningful_response_default)
    budget_default = float(rt.profile.episode_budget_median or rt.classic_cfg.attempt_budget_seconds)

    for path in files:
        eps = split_demo_episodes(path)
        # Old SMART HUMAN TEACH versions could miss every SUCCESS banner and
        # silently label real wins as FAIL.  Never let an all-fail recorder file
        # dominate behaviour cloning.  Keep the file on disk for audit, but do
        # not train from it until it contains at least one verified success.
        file_has_success = any(ep and int(safe_float(ep[-1].get("episode_success"), -1)) == 1 for ep in eps)
        if eps and not file_has_success and path.name.startswith("demo_smart_"):
            cnt["untrusted_files"] += 1
            continue
        for ep in eps:
            if not ep:
                continue
            status = int(safe_float(ep[-1].get("episode_success"), -1))
            ep_elapsed = safe_float(ep[-1].get("episode_elapsed"), safe_float(ep[-1].get("elapsed"), budget_default))
            mixed = status == 1 and (ep_elapsed > 8.0 or len(ep) > 20)
            if mixed:
                kind = "mixed"; cnt["mixed"] += 1
            elif status == 1:
                kind = "success"; cnt["success"] += 1
            elif status == 0:
                kind = "fail"; cnt["fail"] += 1
            else:
                kind = "unknown"; cnt["unknown"] += 1

            mem = SmartMemory()
            budget = max(1.5, ep_elapsed if 1.0 <= ep_elapsed <= 8.0 else budget_default)
            for i, row in enumerate(ep):
                target = safe_float(row.get("pick_pos"), float("nan"))
                response = safe_float(row.get("response"), float("nan"))
                if not (math.isfinite(target) and math.isfinite(response)):
                    cnt["skipped"] += 1
                    continue
                target = clamp01(target)
                # This includes the previously missing fully-left -> first probe action.
                obs = obs_from_memory(mem, budget, threshold, len(rt.cfg.hold_ms), rt.cfg)
                unit = target_to_unit(target, mem, threshold, rt.cfg)
                terminal = i == len(ep) - 1
                hold_idx, hold_weight = infer_hold_idx(rt, row, terminal, kind == "success", max(mem.response, mem.best_response, response))
                improvement = response - mem.response
                frac = (i + 1) / max(1, len(ep))
                search_right = mem.best_response < threshold and target > mem.pos + 0.002

                positive = False
                negative = False
                weight = 0.0
                source = kind
                if kind == "success":
                    quality = 1.0 + 2.5 * response + 5.0 * max(0.0, improvement)
                    tail = 1.0 + rt.cfg.human_success_tail_boost * frac * frac
                    weight = rt.cfg.human_success_weight * quality * tail
                    positive = True
                    source = "human_success"
                elif kind == "fail":
                    helpful = improvement > 0.015 or search_right or (response >= threshold and improvement >= -0.02)
                    if helpful and not (terminal and improvement < -0.02):
                        weight = rt.cfg.human_fail_helpful_weight * (1.0 + 2.0 * response + 4.0 * max(0.0, improvement))
                        positive = True
                        source = "human_fail_helpful"
                    else:
                        weight = rt.cfg.human_fail_bad_weight * (1.0 + 4.0 * max(0.0, -improvement) + (1.5 if terminal else 0.0))
                        negative = True
                        source = "human_fail_bad"
                elif kind == "mixed":
                    if improvement > 0.02 or (search_right and response >= threshold):
                        weight = 0.35 * (1.0 + 3.0 * max(0.0, improvement) + response)
                        positive = True
                        source = "human_mixed_helpful"
                    elif improvement < -0.05:
                        weight = 0.25 * (1.0 + 3.0 * (-improvement))
                        negative = True
                        source = "human_mixed_bad"
                else:
                    if improvement > 0.03:
                        weight = 0.18 * (1.0 + 3.0 * improvement)
                        positive = True
                        source = "human_unknown_helpful"

                if positive or negative:
                    samples.append(HumanSample(obs, unit, hold_idx, weight, negative, hold_weight, source))
                    cnt["negative" if negative else "positive"] += 1
                    if i == 0:
                        cnt["first_moves"] += 1
                else:
                    cnt["skipped"] += 1

                elapsed = safe_float(row.get("elapsed"), (i + 1) * rt.profile.probe_interval_median)
                memory_after_probe(mem, target, response, hold_idx, 0.0, elapsed, threshold, rt.profile, rt.cfg)

    if len(samples) > rt.cfg.human_max_samples:
        samples.sort(key=lambda x: x.weight, reverse=True)
        samples = samples[: rt.cfg.human_max_samples]
    return samples, cnt


def supervised_update(rt: SmartRuntime, samples: Sequence[HumanSample], epochs: int, lr: float, batch_size: int) -> Dict[str, float]:
    if not samples:
        return {"samples": 0.0, "loss": 0.0}
    rows = list(samples)
    opt = torch.optim.Adam(rt.net.parameters(), lr=lr, eps=1e-5)
    losses: List[float] = []
    rt.net.train()
    for _ in range(max(1, int(epochs))):
        random.shuffle(rows)
        for start in range(0, len(rows), max(8, int(batch_size))):
            b = rows[start : start + max(8, int(batch_size))]
            obs = torch.as_tensor(np.stack([x.obs for x in b]), dtype=torch.float32, device=rt.device)
            act = torch.as_tensor([np.clip(x.unit_action, 1e-4, 1 - 1e-4) for x in b], dtype=torch.float32, device=rt.device)
            hold = torch.as_tensor([x.hold_action for x in b], dtype=torch.long, device=rt.device)
            w = torch.as_tensor([min(30.0, max(0.03, x.weight)) for x in b], dtype=torch.float32, device=rt.device)
            neg = torch.as_tensor([1.0 if x.negative else 0.0 for x in b], dtype=torch.float32, device=rt.device)
            hw = torch.as_tensor([x.hold_weight for x in b], dtype=torch.float32, device=rt.device)
            pos = 1.0 - neg

            alpha, beta, hold_logits, _v = rt.net(obs)
            bd = Beta(alpha, beta)
            mean = bd.mean
            move_nll = -bd.log_prob(act).clamp(-20.0, 20.0)
            move_mse = (mean - act) ** 2
            hold_ce = F.cross_entropy(hold_logits, hold, reduction="none")
            pos_den = torch.clamp((w * pos).sum(), min=1.0)
            # Direct mean regression learns continuous target positions much faster
            # than density-only NLL, while a small NLL term still teaches useful
            # exploration variance for PPO.
            move_loss = 6.0 * move_mse + 0.08 * move_nll
            pos_loss = ((move_loss + hw * hold_ce) * w * pos).sum() / pos_den

            # Negative demos repel the policy mean from the bad target position.
            dist = torch.abs(mean - act)
            repulse = F.relu(rt.cfg.human_negative_margin - dist) / max(1e-4, rt.cfg.human_negative_margin)
            neg_den = torch.clamp((w * neg).sum(), min=1.0)
            neg_loss = (repulse * w * neg).sum() / neg_den
            if float(neg.sum().item()) < 0.5:
                neg_loss = neg_loss * 0.0
            loss = pos_loss + neg_loss
            opt.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(rt.net.parameters(), rt.cfg.ppo_max_grad_norm)
            opt.step()
            losses.append(float(loss.item()))
    rt.net.eval()
    rt.optimizer = torch.optim.Adam(rt.net.parameters(), lr=rt.cfg.ppo_lr, eps=1e-5)
    return {"samples": float(len(rows)), "loss": float(np.mean(losses) if losses else 0.0)}


def human_pretrain(rt: SmartRuntime) -> None:
    fit_sim_profile(rt, verbose=True)
    samples, cnt = load_human_samples(rt)
    print("\n=== SMART HUMAN PRETRAIN ===")
    print(
        f"files={cnt['files']} success={cnt['success']} fail={cnt['fail']} mixed={cnt['mixed']} | "
        f"positive={cnt['positive']} negative={cnt['negative']} first-move samples={cnt['first_moves']} skipped={cnt['skipped']} "
        f"untrusted-all-fail-files={cnt.get('untrusted_files',0)}"
    )
    if cnt['success'] <= 0:
        print("[SAFETY] No VERIFIED human success episodes. Human BC is skipped so an all-fail/misdetected recording cannot overwrite the trained policy.")
        print("Record at least one SUCCESS with v0.16.1, then run pretrain again. Old all-fail SMART files stay on disk but are ignored.")
        return
    if not samples:
        print("No usable human data. Use SMART HUMAN TEACH first.")
        return
    before = rt.model_hash()
    metrics = supervised_update(rt, samples, rt.cfg.human_bc_epochs, rt.cfg.human_bc_lr, rt.cfg.human_bc_batch)
    rt.stats.inc("human_bc_runs", 1)
    rt.stats.inc("human_samples", int(metrics["samples"]))
    rt.stats.data["last_hash"] = rt.model_hash()
    rt.stats.save()
    rt.save()
    append_csv(
        BC_LOG,
        ["wall_time", "samples", "positive", "negative", "first_moves", "loss", "before_hash", "after_hash"],
        {
            "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"),
            "samples": int(metrics["samples"]),
            "positive": cnt["positive"],
            "negative": cnt["negative"],
            "first_moves": cnt["first_moves"],
            "loss": metrics["loss"],
            "before_hash": before,
            "after_hash": rt.model_hash(),
        },
    )
    print(f"SMART BC complete: {int(metrics['samples'])} samples | loss={metrics['loss']:.4f}")
    print(f"hash {before[:12]} -> {rt.model_hash()[:12]}")
    print("Unlike v0.7, the fully-left -> first probe action is included and movement is continuous/absolute.")


# ---------------------------------------------------------------------------
# Vectorized simulator
# ---------------------------------------------------------------------------

class VectorLockSim:
    def __init__(self, rt: SmartRuntime, n: int, curriculum_level: int = 0, seed_offset: int = 0,
                 skill_probs: Optional[np.ndarray] = None):
        self.rt = rt
        self.cfg = rt.cfg
        self.profile = rt.profile
        self.n = int(n)
        self.level = int(curriculum_level)
        self.skill_probs: Optional[np.ndarray] = None
        if skill_probs is not None:
            sp = np.asarray(skill_probs, dtype=np.float64).reshape(-1)
            expected = (int(self.cfg.sim_curriculum_max) + 1) * 3
            if len(sp) != expected:
                raise ValueError(f"skill_probs must contain {expected} entries")
            sp = np.clip(sp, 0.0, None)
            if float(sp.sum()) <= 0.0:
                sp[:] = 1.0
            self.skill_probs = sp / sp.sum()
        self.rng = np.random.default_rng(self.cfg.seed + 171 * self.level + self.n + int(seed_offset))
        self.grid = BELIEF_GRID[None, :]
        self.reset_all()

    def reset_all(self) -> None:
        n = self.n
        self.pos = np.zeros(n, np.float32)
        self.response = np.zeros(n, np.float32)
        self.prev_response = np.zeros(n, np.float32)
        self.best = np.zeros(n, np.float32)
        self.best_pos = np.zeros(n, np.float32)
        self.best_known = np.zeros(n, bool)
        self.good_pos = np.zeros(n, np.float32)
        self.good_known = np.zeros(n, bool)
        self.furthest = np.zeros(n, np.float32)
        self.last_target = np.zeros(n, np.float32)
        self.last_move = np.zeros(n, np.float32)
        self.last_hold = np.zeros(n, np.int64)
        self.last_reward = np.zeros(n, np.float32)
        self.elapsed = np.zeros(n, np.float32)
        self.steps = np.zeros(n, np.int32)
        self.wrong_hits = np.zeros(n, np.int16)
        self.hist_pos = np.zeros((n, HISTORY), np.float32)
        self.hist_resp = np.zeros((n, HISTORY), np.float32)
        self.hist_hold = np.zeros((n, HISTORY), np.float32)
        self.belief = np.ones((n, BELIEF_BINS), np.float32) / BELIEF_BINS
        self.episode_reward = np.zeros(n, np.float32)
        self.episode_best = np.zeros(n, np.float32)
        self.done_count = 0
        self.success_count = 0
        self.ep_times: List[float] = []
        self._reset_params(np.arange(n))

    def _level_ranges(self, level: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
        # Easier -> harder: narrower ramp and target. Domain randomization always overlaps levels.
        ramp_scale = np.choose(np.clip(level, 0, 4), [1.55, 1.25, 1.0, 0.78, 0.62]).astype(np.float32)
        target_scale = np.choose(np.clip(level, 0, 4), [2.2, 1.55, 1.0, 0.70, 0.48]).astype(np.float32)
        return ramp_scale, target_scale

    def _reset_params(self, idx: np.ndarray) -> None:
        if idx.size == 0:
            return
        m = len(idx)
        maxl = max(0, min(self.cfg.sim_curriculum_max, self.level))
        # v0.12 can request an exact joint distribution over (difficulty, target-zone).
        # This label is trainer-only metadata: it is NEVER appended to agent observations.
        if self.skill_probs is not None:
            sid = self.rng.choice(len(self.skill_probs), size=m, p=self.skill_probs).astype(np.int32)
            lev = (sid // 3).astype(np.int32)
            zone = (sid % 3).astype(np.int32)
        else:
            # Legacy curriculum behavior: current level mixed with one easier neighbor.
            lo = max(0, maxl - 1)
            lev = self.rng.integers(lo, maxl + 1, size=m, endpoint=False) if maxl > lo else np.full(m, maxl)
            zone = self.rng.integers(0, 3, size=m, endpoint=False).astype(np.int32)
        self.difficulty = getattr(self, "difficulty", np.zeros(self.n, np.int32))
        self.zone = getattr(self, "zone", np.zeros(self.n, np.int32))
        self.skill_id = getattr(self, "skill_id", np.zeros(self.n, np.int32))
        self.difficulty[idx] = lev
        self.zone[idx] = zone
        self.skill_id[idx] = lev * 3 + zone
        # v0.16.3: geometry is generated from conservative lock-level priors,
        # never from Human Teach inferred widths. This prevents sparse probe data
        # from turning a steep player ramp into a fake 0.165 halfwidth plateau.
        lev_clip = np.clip(lev, 0, 4).astype(np.int32)
        rlo = SAFE_SIM_RAMP_LOW[lev_clip]
        rhi = SAFE_SIM_RAMP_HIGH[lev_clip]
        tlo = SAFE_SIM_TARGET_LOW[lev_clip]
        thi = SAFE_SIM_TARGET_HIGH[lev_clip]
        ramp = self.rng.uniform(rlo, rhi).astype(np.float32)
        target = self.rng.uniform(tlo, thi).astype(np.float32)
        target = np.minimum(target, ramp * 0.45).astype(np.float32)
        p = self.profile
        self.center = getattr(self, "center", np.zeros(self.n, np.float32))
        self.ramp_l = getattr(self, "ramp_l", np.zeros(self.n, np.float32))
        self.ramp_r = getattr(self, "ramp_r", np.zeros(self.n, np.float32))
        self.target_w = getattr(self, "target_w", np.zeros(self.n, np.float32))
        self.curve = getattr(self, "curve", np.ones(self.n, np.float32))
        self.baseline = getattr(self, "baseline", np.zeros(self.n, np.float32))
        self.noise = getattr(self, "noise", np.zeros(self.n, np.float32))
        self.budget = getattr(self, "budget", np.zeros(self.n, np.float32))
        self.turn_tau_ms = getattr(self, "turn_tau_ms", np.zeros(self.n, np.float32))
        # Target location is hidden from the agent. Rusted spans the full physical
        # range. Player locks use only the left 50%; LEFT/MID/RIGHT now mean thirds
        # of that *player search domain*, preserving the 15-skill evaluation matrix
        # without teaching the neural to waste 3 s scanning the far-right half.
        rust_zlo = np.choose(zone, [0.01, 0.335, 0.665]).astype(np.float32)
        rust_zhi = np.choose(zone, [0.335, 0.665, 0.99]).astype(np.float32)
        play_zlo = np.choose(zone, [0.010, 0.170, 0.335]).astype(np.float32)
        play_zhi = np.choose(zone, [0.170, 0.335, 0.495]).astype(np.float32)
        is_player = lev > 0
        zlo = np.where(is_player, play_zlo, rust_zlo).astype(np.float32)
        zhi = np.where(is_player, play_zhi, rust_zhi).astype(np.float32)
        self.center[idx] = self.rng.uniform(zlo, zhi).astype(np.float32)
        asym = self.rng.uniform(0.82, 1.18, m).astype(np.float32)
        self.ramp_l[idx] = np.minimum(np.maximum(ramp * asym, rlo), rhi).astype(np.float32)
        self.ramp_r[idx] = np.minimum(np.maximum(ramp / asym, rlo), rhi).astype(np.float32)
        self.target_w[idx] = target
        clo = SAFE_SIM_CURVE_LOW[lev_clip]
        chi = SAFE_SIM_CURVE_HIGH[lev_clip]
        self.curve[idx] = self.rng.uniform(clo, chi).astype(np.float32)
        self.baseline[idx] = self.rng.uniform(max(0.015, p.baseline_median * 0.60), max(p.baseline_p90 * 1.10, 0.09), m)
        dr = float(np.clip(self.cfg.sim_domain_randomization, 0.0, 2.0))
        self.noise[idx] = self.rng.uniform(0.005, 0.035 + 0.02 * dr, m)
        # IMPORTANT: this is VIRTUAL game time, not wall-clock time. Headless
        # training never sleeps for three real seconds; actions simply consume a
        # fraction of this 3.0 s budget. This preserves the in-game time pressure
        # while allowing extremely fast offline simulation.
        player_budget = float(max(3.0, self.cfg.sim_virtual_time_limit_sec))
        rusted_budget = float(max(player_budget, self.cfg.sim_rusted_time_limit_sec))
        self.budget[idx] = np.where(lev == 0, rusted_budget, player_budget).astype(np.float32)
        # HOLD-TO-90: every lock gets a randomized turn speed. The agent never
        # sees this hidden parameter; it only sees the resulting visible rotation.
        lo_tau = min(float(self.cfg.sim_turn_tau_ms_low), float(self.cfg.sim_turn_tau_ms_high))
        hi_tau = max(float(self.cfg.sim_turn_tau_ms_low), float(self.cfg.sim_turn_tau_ms_high))
        self.turn_tau_ms[idx] = self.rng.uniform(lo_tau, hi_tau, m).astype(np.float32)

        self.pos[idx] = 0.0
        self.response[idx] = 0.0
        self.prev_response[idx] = 0.0
        self.best[idx] = 0.0
        self.best_pos[idx] = 0.0
        self.best_known[idx] = False
        self.good_pos[idx] = 0.0
        self.good_known[idx] = False
        self.furthest[idx] = 0.0
        self.last_target[idx] = 0.0
        self.last_move[idx] = 0.0
        self.last_hold[idx] = 0
        self.last_reward[idx] = 0.0
        self.elapsed[idx] = 0.0
        self.steps[idx] = 0
        self.wrong_hits[idx] = 0
        self.hist_pos[idx] = 0.0
        self.hist_resp[idx] = 0.0
        self.hist_hold[idx] = 0.0
        self.belief[idx] = 1.0 / BELIEF_BINS
        self.episode_reward[idx] = 0.0
        self.episode_best[idx] = 0.0

    def threshold(self) -> float:
        return float(self.profile.meaningful_response or self.cfg.meaningful_response_default)

    def _belief_update(self, response: np.ndarray, hold_frac: np.ndarray) -> None:
        ramp = float(np.clip(self.profile.ramp_width_median, 0.025, 0.25))
        target = float(np.clip(self.profile.target_width_median, 0.002, ramp * 0.55))
        dist = np.abs(self.grid - self.pos[:, None])
        pred = np.zeros_like(dist, dtype=np.float32)
        pred[dist <= target] = 1.0
        mid = (dist > target) & (dist < ramp)
        pred[mid] = np.power(np.clip(1.0 - (dist[mid] - target) / max(1e-5, ramp - target), 0.0, 1.0), 1.35)
        pred *= np.clip(hold_frac[:, None], 0.02, 1.0)
        floor = min(self.profile.baseline_p90, self.threshold() * 0.9)
        obs = np.clip((response - floor) / max(0.20, 1.0 - floor), 0.0, 1.0)[:, None]
        sigma = max(0.08, self.cfg.belief_sigma)
        like = np.exp(-0.5 * ((pred - obs) / sigma) ** 2) + 0.035
        self.belief *= np.power(like, self.cfg.belief_strength).astype(np.float32)
        sums = self.belief.sum(axis=1, keepdims=True)
        bad = (~np.isfinite(sums[:, 0])) | (sums[:, 0] <= 1e-12)
        if bad.any():
            self.belief[bad] = 1.0 / BELIEF_BINS
            sums = self.belief.sum(axis=1, keepdims=True)
        self.belief /= sums
        mix = self.cfg.belief_uniform_mix
        self.belief = (1.0 - mix) * self.belief + mix / BELIEF_BINS

    def obs(self) -> np.ndarray:
        n = self.n
        thr = self.threshold()
        improvement = np.clip((self.response - self.prev_response) / 0.30, -1.0, 1.0)
        found = np.where(self.best_known & (self.best >= thr), 1.0, -1.0)
        recover = np.where(self.best_known & (self.best >= thr) & (self.response < self.best - self.cfg.recover_drop), 1.0, -1.0)
        bp = np.where(self.best_known, self.best_pos, 0.5)
        gp = np.where(self.good_known, self.good_pos, 0.5)
        hold_norm = np.zeros(n, np.float32) if len(self.cfg.hold_ms) <= 1 else 2.0 * self.last_hold / (len(self.cfg.hold_ms) - 1) - 1.0
        efrac = np.clip(self.elapsed / np.maximum(0.1, self.budget), 0.0, 1.5)
        remain = np.clip(1.0 - self.elapsed / np.maximum(0.1, self.budget), 0.0, 1.0)
        ratio = np.where(self.best_known, self.response / np.maximum(0.03, self.best), 0.0)
        bmean = (self.belief * BELIEF_GRID[None, :]).sum(axis=1)
        bvar = (self.belief * (BELIEF_GRID[None, :] - bmean[:, None]) ** 2).sum(axis=1)
        bent = -(self.belief * np.log(np.clip(self.belief, 1e-12, 1.0))).sum(axis=1) / math.log(BELIEF_BINS)
        bpeak = BELIEF_GRID[np.argmax(self.belief, axis=1)]
        core = np.stack([
            2 * self.pos - 1,
            2 * self.response - 1,
            2 * self.prev_response - 1,
            improvement,
            2 * self.best - 1,
            2 * bp - 1,
            np.clip(self.pos - bp, -1, 1),
            2 * gp - 1,
            np.clip(self.pos - gp, -1, 1),
            2 * self.furthest - 1,
            2 * self.last_target - 1,
            np.clip(self.last_move, -1, 1),
            hold_norm,
            np.tanh(self.last_reward / 20.0),
            np.clip(2 * efrac - 1, -1, 2),
            2 * remain - 1,
            2 * np.clip(self.steps / max(1, self.cfg.sim_max_steps), 0, 1) - 1,
            found,
            recover,
            np.clip(2 * ratio - 1, -1, 1),
            2 * bmean - 1,
            np.clip(2.5 * np.sqrt(np.maximum(0, bvar)) - 1, -1, 1),
            2 * bent - 1,
            2 * bpeak - 1,
        ], axis=1).astype(np.float32)
        history_feat = np.empty((n, 3 * HISTORY), dtype=np.float32)
        history_feat[:, 0::3] = 2.0 * self.hist_pos - 1.0
        history_feat[:, 1::3] = 2.0 * self.hist_resp - 1.0
        history_feat[:, 2::3] = 2.0 * self.hist_hold - 1.0
        belief_feat = np.tanh(2.0 * (self.belief * BELIEF_BINS - 1.0)).astype(np.float32)
        return np.concatenate([core, history_feat, belief_feat], axis=1).astype(np.float32)

    def bounds(self) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        thr = self.threshold()
        found = self.best_known & (self.best >= thr)
        recover = found & (self.response < self.best - self.cfg.recover_drop)
        strong = found & (self.response >= self.cfg.strong_response)
        near = found & ~strong & ~recover & ((self.response >= self.cfg.near_response) | (self.best >= self.cfg.strong_response))
        ramp = found & ~recover & ~strong & ~near
        search = ~found
        scan_limit = np.where(self.difficulty == 0, SAFE_SIM_RUSTED_LIMIT, SAFE_SIM_PLAYER_LIMIT).astype(np.float32)
        low = np.zeros(self.n, np.float32)
        high = scan_limit.copy()
        phase = np.zeros(self.n, np.int32)
        low[search] = np.minimum(
            scan_limit[search],
            np.maximum(self.pos[search] + self.cfg.search_min_advance, self.furthest[search] + self.cfg.search_min_advance),
        )
        phase[search] = 0
        low[recover] = np.maximum(0.0, self.best_pos[recover] - self.cfg.recover_span)
        high[recover] = np.minimum(scan_limit[recover], self.best_pos[recover] + self.cfg.recover_span)
        phase[recover] = 2
        center = np.where(self.response >= self.best - 0.04, self.pos, self.best_pos)
        span = max(0.010, self.cfg.near_span * 0.55)
        low[strong] = np.maximum(0.0, center[strong] - span)
        high[strong] = np.minimum(scan_limit[strong], center[strong] + span)
        phase[strong] = 4
        low[near] = np.maximum(0.0, self.best_pos[near] - self.cfg.near_span)
        high[near] = np.minimum(scan_limit[near], self.best_pos[near] + self.cfg.near_span)
        phase[near] = 3
        span_r = max(self.cfg.near_span * 1.8, self.cfg.recover_span)
        low[ramp] = np.maximum(0.0, self.best_pos[ramp] - span_r)
        high[ramp] = np.minimum(scan_limit[ramp], self.best_pos[ramp] + span_r)
        phase[ramp] = 1
        # Numerical safety at the player 0.50 hard edge.
        low = np.minimum(low, high)
        return low, high, phase

    def step(self, unit_action: np.ndarray, hold_idx: np.ndarray, absolute: bool = False, hold_ms_override: Optional[np.ndarray] = None) -> Tuple[np.ndarray, np.ndarray, np.ndarray, Dict[str, np.ndarray]]:
        unit_action = np.clip(unit_action.astype(np.float32), 1e-4, 1 - 1e-4)
        hold_idx = hold_idx.astype(np.int64)
        if absolute:
            low = np.zeros(self.n, np.float32)
            high = np.ones(self.n, np.float32)
            phase = np.full(self.n, -1, np.int32)
            target = unit_action.copy()
        else:
            low, high, phase = self.bounds()
            target = low + unit_action * np.maximum(1e-6, high - low)
        scan_limit = np.where(self.difficulty == 0, SAFE_SIM_RUSTED_LIMIT, SAFE_SIM_PLAYER_LIMIT).astype(np.float32)
        target = np.minimum(np.maximum(target, 0.0), scan_limit).astype(np.float32)
        old_pos = self.pos.copy()
        old_resp = self.response.copy()
        old_best = self.best.copy()
        # Movement noise grows on long jumps.
        jitter = self.rng.normal(0.0, 0.0025 + 0.006 * np.abs(target - old_pos), self.n)
        self.pos = np.minimum(np.maximum(target + jitter, 0.0), scan_limit).astype(np.float32)
        dist_signed = self.pos - self.center
        dist = np.abs(dist_signed)
        side_ramp = np.where(dist_signed < 0, self.ramp_l, self.ramp_r)
        # Spatial cap: dead zone=0, ramp=partial jam angle, target=full 90-degree cap.
        spatial_cap = np.zeros(self.n, np.float32)
        inside = dist <= self.target_w
        spatial_cap[inside] = 1.0
        mid = (~inside) & (dist < side_ramp)
        z = np.zeros(self.n, np.float32)
        z[mid] = 1.0 - (dist[mid] - self.target_w[mid]) / np.maximum(1e-5, side_ramp[mid] - self.target_w[mid])
        spatial_cap[mid] = np.power(np.clip(z[mid], 0.0, 1.0), self.curve[mid])

        # F-HOLD physics. A tap only moves part-way toward the spatial cap. A long
        # enough hold at TARGET can reach ~90 degrees; a ramp can never exceed its
        # lower jam cap no matter how long F is held.
        if hold_ms_override is None:
            hold_table = np.asarray(self.cfg.hold_ms, dtype=np.float32)
            hold_ms_arr = hold_table[np.clip(hold_idx, 0, len(hold_table)-1)]
        else:
            hold_ms_arr = np.clip(np.asarray(hold_ms_override, dtype=np.float32).reshape(self.n), 1.0, 2500.0)
        hold_frac = (1.0 - np.exp(-hold_ms_arr / np.maximum(20.0, self.turn_tau_ms))).astype(np.float32)
        true_turn = np.clip(spatial_cap * hold_frac, 0.0, 1.0).astype(np.float32)

        # Keep the default simulator close to the PDF theory. Measurement noise
        # is allowed because the real vision pipeline is not perfect, but false
        # ramp/target spikes are OFF by default instead of being invented physics.
        noise = self.rng.normal(0.0, self.noise * float(self.cfg.sim_noise_scale), self.n)
        obs_resp = np.clip(self.baseline + (1.0 - self.baseline) * true_turn + noise, 0.0, 1.0)
        spike_rate = max(0.0, float(self.cfg.sim_false_spike_rate))
        if spike_rate > 0.0:
            spikes = self.rng.random(self.n) < spike_rate
            if spikes.any():
                obs_resp[spikes] = np.maximum(obs_resp[spikes], self.rng.uniform(0.12, 0.35, spikes.sum()))
        self.prev_response = old_resp
        self.response = obs_resp.astype(np.float32)

        self.steps += 1
        move_dist = np.abs(self.pos - old_pos)
        hold_sec = hold_ms_arr / 1000.0
        # Simulated wall time approximates the human data rather than slow Python CV implementation.
        step_time = np.clip(
            0.16 + 0.22 * move_dist + hold_sec + self.rng.normal(0.0, 0.025, self.n),
            0.10, 0.70,
        ).astype(np.float32)
        self.elapsed += step_time

        improvement = self.response - old_resp
        best_gain = np.maximum(0.0, self.response - old_best)
        thr = self.threshold()
        first_signal = (old_best < thr) & (self.response >= thr)
        recover_good = (old_best >= thr) & (old_resp < old_best - self.cfg.recover_drop) & (self.response > old_resp + 0.04)
        reward = (
            self.cfg.reward_progress_gain * np.maximum(0.0, improvement)
            + self.cfg.reward_best_gain * best_gain
            + self.cfg.reward_absolute * self.response
            + self.cfg.reward_first_signal * first_signal.astype(np.float32)
            + self.cfg.reward_recover * recover_good.astype(np.float32)
            - self.cfg.reward_regression * np.maximum(0.0, -improvement)
            - self.cfg.reward_probe_cost
            - self.cfg.reward_time_cost * step_time
        ).astype(np.float32)

        better = (~self.best_known) | (self.response > self.best + self.cfg.best_update_epsilon)
        self.best_pos[better] = self.pos[better]
        self.best[better] = self.response[better]
        self.best_known[better] = True
        self.best = np.maximum(self.best, self.response)
        good = (self.response >= thr) | (self.response > old_resp + self.cfg.good_update_epsilon)
        self.good_pos[good] = self.pos[good]
        self.good_known[good] = True
        self.furthest = np.maximum(self.furthest, self.pos)
        self.last_target = self.pos.copy()
        self.last_move = self.pos - old_pos
        self.last_hold = hold_idx.copy()
        self.hist_pos[:, :-1] = self.hist_pos[:, 1:]
        self.hist_pos[:, -1] = self.pos
        self.hist_resp[:, :-1] = self.hist_resp[:, 1:]
        self.hist_resp[:, -1] = self.response
        self.hist_hold[:, :-1] = self.hist_hold[:, 1:]
        self.hist_hold[:, -1] = hold_frac
        self._belief_update(self.response, hold_frac)

        success = inside & (true_turn >= float(self.cfg.sim_success_rotation))
        underhold = inside & ~success
        # Wrong-position count is diagnostic only in v0.15. Real SCUM attempts do
        # not magically stop after seven probes, so simulator termination is driven
        # by virtual time (plus a very high safety step ceiling).
        wrong = ~inside
        self.wrong_hits += wrong.astype(np.int16)
        reward -= float(self.cfg.sim_wrong_hit_penalty) * wrong.astype(np.float32)
        reward -= float(self.cfg.sim_underhold_penalty) * underhold.astype(np.float32)
        timeout = (self.elapsed >= self.budget) | (self.steps >= self.cfg.sim_max_steps)
        hit_limit = (self.wrong_hits >= max(1, int(self.cfg.sim_max_wrong_hits))) if self.cfg.sim_use_wrong_hit_limit else np.zeros_like(success, dtype=bool)
        done = success | timeout | hit_limit
        if success.any():
            speed = np.clip(1.0 - self.elapsed / np.maximum(0.1, self.budget), 0.0, 1.0)
            reward[success] += self.cfg.reward_success + self.cfg.reward_speed_bonus * speed[success]
        fail = done & ~success
        if fail.any():
            scale = np.maximum(0.35, 1.0 - 0.65 * self.best[fail])
            reward[fail] += self.cfg.reward_fail * scale

        self.last_reward = reward.copy()
        self.episode_reward += reward
        self.episode_best = np.maximum(self.episode_best, self.best)
        self.done_count += int(done.sum())
        self.success_count += int(success.sum())
        if done.any():
            self.ep_times.extend(self.elapsed[done].astype(float).tolist())

        info = {
            "success": success.astype(np.float32),
            "response": self.response.copy(),
            "best": self.best.copy(),
            "elapsed": self.elapsed.copy(),
            "phase": phase,
            "target": target.astype(np.float32),
            "low": low,
            "high": high,
            "wrong_hits": self.wrong_hits.copy(),
            "underhold": underhold.astype(np.float32),
            "turn_progress": true_turn.copy(),
            "hold_fraction": hold_frac.copy(),
            "hold_ms": hold_ms_arr.copy(),
            "wrong_remaining": np.maximum(0, int(self.cfg.sim_max_wrong_hits) - self.wrong_hits).astype(np.int16),
            "virtual_budget": self.budget.copy(),
            "virtual_time": self.elapsed.copy(),
            # Trainer-only hidden labels. These are intentionally absent from obs().
            "skill_id": self.skill_id.copy(),
            "difficulty": self.difficulty.copy(),
            "target_zone": self.zone.copy(),
            "hidden_target_center": self.center.copy(),
            "hidden_target_width": self.target_w.copy(),
            "hidden_ramp_left": self.ramp_l.copy(),
            "hidden_ramp_right": self.ramp_r.copy(),
        }
        # Return next obs before resetting is needed for terminal masks only; then reset done envs.
        next_obs = self.obs()
        if done.any():
            self._reset_params(np.where(done)[0])
            next_obs = self.obs()
        return next_obs, reward, done.astype(np.float32), info


class PPOBatch:
    def __init__(self, T: int, N: int):
        self.obs = np.zeros((T, N, OBS_DIM), np.float32)
        self.action = np.zeros((T, N), np.float32)
        self.hold = np.zeros((T, N), np.int64)
        self.logp = np.zeros((T, N), np.float32)
        self.value = np.zeros((T, N), np.float32)
        self.reward = np.zeros((T, N), np.float32)
        self.done = np.zeros((T, N), np.float32)
        self.next_value = np.zeros(N, np.float32)


def current_entropy_coef(rt: SmartRuntime) -> float:
    u = int(rt.stats.data.get("sim_ppo_updates", 0) or 0) + int(rt.stats.data.get("real_ppo_updates", 0) or 0)
    return float(max(rt.cfg.ppo_entropy_min, rt.cfg.ppo_entropy_coef * (rt.cfg.ppo_entropy_decay ** u)))


def ppo_update(rt: SmartRuntime, batch: PPOBatch, source: str) -> Dict[str, float]:
    """Conservative PPO with critic scaling, champion anchoring and hard rollback.

    v0.10 used enormous on-policy batches but allowed KL around 0.02-0.03.  That
    was enough to erase a strong teacher-distilled policy in only a few updates.
    v0.11 treats the current champion as an immutable trust-region reference.
    If a minibatch pushes the old-policy KL or champion KL beyond a hard limit,
    the whole PPO update is reverted atomically.
    """
    cfg = rt.cfg
    T, N = batch.reward.shape

    # Scale only the critic/GAE reward. Advantage normalization preserves the
    # policy ordering while keeping value targets near single-digit magnitude.
    reward = batch.reward.astype(np.float32) * float(cfg.ppo_reward_scale)
    adv = np.zeros((T, N), np.float32)
    gae = np.zeros(N, np.float32)
    next_v = batch.next_value.copy()
    for t in reversed(range(T)):
        nonterminal = 1.0 - batch.done[t]
        delta = reward[t] + cfg.ppo_gamma * next_v * nonterminal - batch.value[t]
        gae = delta + cfg.ppo_gamma * cfg.ppo_gae_lambda * nonterminal * gae
        adv[t] = gae
        next_v = batch.value[t]
    ret = adv + batch.value
    flat_adv = adv.reshape(-1)
    flat_adv = (flat_adv - flat_adv.mean()) / (flat_adv.std() + 1e-8)
    flat_adv = np.clip(flat_adv, -float(cfg.ppo_adv_clip), float(cfg.ppo_adv_clip))

    obs = torch.as_tensor(batch.obs.reshape(-1, OBS_DIM), dtype=torch.float32, device=rt.device)
    act = torch.as_tensor(np.clip(batch.action.reshape(-1), 1e-4, 1-1e-4), dtype=torch.float32, device=rt.device)
    hold = torch.as_tensor(batch.hold.reshape(-1), dtype=torch.long, device=rt.device)
    old_logp = torch.as_tensor(batch.logp.reshape(-1), dtype=torch.float32, device=rt.device)
    advantages = torch.as_tensor(flat_adv, dtype=torch.float32, device=rt.device)
    returns = torch.as_tensor(ret.reshape(-1), dtype=torch.float32, device=rt.device)
    idx = np.arange(len(flat_adv))
    ent_coef = current_entropy_coef(rt)

    # Atomic update snapshot. This is cheap for this network and prevents one
    # pathological PPO pass from mutating the champion-derived challenger.
    pre_state = {k: v.detach().cpu().clone() for k, v in rt.net.state_dict().items()}

    anchor = getattr(rt, "ppo_anchor_net", None)
    if anchor is not None:
        anchor.eval()
    elite_obs_np = getattr(rt, "ppo_elite_obs", None)
    elite_act_np = getattr(rt, "ppo_elite_action", None)
    elite_hold_np = getattr(rt, "ppo_elite_hold", None)

    losses: List[float] = []
    pis: List[float] = []
    vals: List[float] = []
    ents: List[float] = []
    kls: List[float] = []
    anchor_kls: List[float] = []
    clipfracs: List[float] = []
    elite_losses: List[float] = []
    steps = 0
    epochs_used = 0
    reverted = False
    stop_reason = ""
    rt.net.train()

    for epoch in range(max(1, int(cfg.ppo_epochs))):
        np.random.shuffle(idx)
        epoch_steps = 0
        for s0 in range(0, len(idx), max(64, int(cfg.ppo_minibatch))):
            mb = idx[s0:s0+max(64, int(cfg.ppo_minibatch))]
            if len(mb) == 0:
                continue
            m = torch.as_tensor(mb, dtype=torch.long, device=rt.device)
            alpha, beta, hold_logits, value = rt.net(obs[m])
            bd = Beta(alpha, beta)
            hd = Categorical(logits=hold_logits)
            new_logp = bd.log_prob(act[m]) + hd.log_prob(hold[m])
            logratio = new_logp - old_logp[m]
            ratio = torch.exp(torch.clamp(logratio, -8.0, 8.0))

            with torch.no_grad():
                approx_kl_t = ((ratio - 1.0) - logratio).mean()
                approx_kl = float(approx_kl_t.item())
                clipfrac = float(((ratio - 1.0).abs() > float(cfg.ppo_clip)).float().mean().item())

            # Do not apply another gradient if the *current* challenger already
            # left the old-policy trust region.
            if approx_kl > float(cfg.ppo_hard_kl):
                reverted = True
                stop_reason = f"old_kl>{cfg.ppo_hard_kl:.4f}"
                break

            s1 = ratio * advantages[m]
            s2 = torch.clamp(ratio, 1-cfg.ppo_clip, 1+cfg.ppo_clip) * advantages[m]
            pi_loss = -torch.min(s1, s2).mean()

            # Smooth-L1 is far less sensitive than MSE to rare terminal reward
            # outliers; reward scaling keeps the critic numerically well behaved.
            v_loss = F.smooth_l1_loss(value, returns[m], beta=1.0)
            entropy = (bd.entropy() + hd.entropy()).mean()

            anchor_loss = torch.zeros((), device=rt.device)
            anchor_kl_value = 0.0
            if anchor is not None and float(cfg.ppo_champion_anchor_coef) > 0.0:
                with torch.no_grad():
                    aa, ab, ah, _av = anchor(obs[m])
                    abd = Beta(aa, ab)
                    alog = F.log_softmax(ah, dim=-1)
                    aprob = alog.exp()
                beta_kl = kl_divergence(abd, bd)
                cat_kl = (aprob * (alog - F.log_softmax(hold_logits, dim=-1))).sum(dim=-1)
                champion_kl = (beta_kl + cat_kl).mean()
                anchor_kl_value = float(champion_kl.detach().item())
                if anchor_kl_value > float(cfg.ppo_champion_anchor_hard_kl):
                    reverted = True
                    stop_reason = f"champion_kl>{cfg.ppo_champion_anchor_hard_kl:.3f}"
                    break
                anchor_loss = float(cfg.ppo_champion_anchor_coef) * champion_kl

            elite_loss = torch.zeros((), device=rt.device)
            if (elite_obs_np is not None and elite_act_np is not None and elite_hold_np is not None
                    and len(elite_obs_np) > 0 and float(cfg.ppo_elite_coef) > 0.0):
                eb = min(int(cfg.ppo_elite_batch), len(elite_obs_np))
                ei = np.random.randint(0, len(elite_obs_np), size=eb)
                eo = torch.as_tensor(elite_obs_np[ei], dtype=torch.float32, device=rt.device)
                ea = torch.as_tensor(np.clip(elite_act_np[ei], 1e-4, 1-1e-4), dtype=torch.float32, device=rt.device)
                eh = torch.as_tensor(elite_hold_np[ei], dtype=torch.long, device=rt.device)
                ealpha, ebeta, ehlogits, _ev = rt.net(eo)
                ebd = Beta(ealpha, ebeta)
                # Small auxiliary BC term: preserve actions that were part of
                # accepted successful/near-success trajectories.
                emove = 4.0 * (ebd.mean - ea).pow(2).mean()
                ehold = F.cross_entropy(ehlogits, eh)
                elite_loss = float(cfg.ppo_elite_coef) * (emove + 0.20 * ehold)

            loss = pi_loss + cfg.ppo_value_coef * v_loss - ent_coef * entropy + anchor_loss + elite_loss
            rt.optimizer.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(rt.net.parameters(), cfg.ppo_max_grad_norm)
            rt.optimizer.step()

            steps += 1
            epoch_steps += 1
            losses.append(float(loss.item()))
            pis.append(float(pi_loss.item()))
            vals.append(float(v_loss.item()))
            ents.append(float(entropy.item()))
            kls.append(approx_kl)
            anchor_kls.append(anchor_kl_value)
            clipfracs.append(clipfrac)
            elite_losses.append(float(elite_loss.detach().item()))

            # Soft KL early stop: keep this PPO pass small even when no hard
            # rollback is necessary.
            if approx_kl > float(cfg.ppo_target_kl):
                stop_reason = f"target_kl>{cfg.ppo_target_kl:.4f}"
                break
        if reverted:
            break
        epochs_used = epoch + 1
        if stop_reason.startswith("target_kl"):
            break
        if epoch_steps == 0:
            break

    if reverted:
        rt.net.load_state_dict(pre_state)
        # Adam momentum from the rejected step must not survive the rollback.
        rt.optimizer = torch.optim.Adam(rt.net.parameters(), lr=cfg.ppo_lr, eps=1e-5)

    rt.net.eval()
    key = "sim_ppo_updates" if source == "sim" else "real_ppo_updates"
    rt.stats.inc(key, 1)
    if source == "sim":
        rt.stats.inc("sim_transitions", T*N)
    rt.stats.data["last_hash"] = rt.model_hash()
    rt.stats.save()
    rt.save()
    return {
        "loss": float(np.mean(losses) if losses else 0.0),
        "pi": float(np.mean(pis) if pis else 0.0),
        "value": float(np.mean(vals) if vals else 0.0),
        # Beta has differential entropy, so total H can legitimately be negative.
        "entropy": float(np.mean(ents) if ents else 0.0),
        "kl": float(np.mean(kls) if kls else 0.0),
        "anchor_kl": float(np.mean(anchor_kls) if anchor_kls else 0.0),
        "clipfrac": float(np.mean(clipfracs) if clipfracs else 0.0),
        "elite_loss": float(np.mean(elite_losses) if elite_losses else 0.0),
        "grad_steps": float(steps),
        "epochs_used": float(epochs_used),
        "ent_coef": float(ent_coef),
        "reverted": 1.0 if reverted else 0.0,
        "stop_reason": stop_reason,
    }


def planner_targets_from_env(env: VectorLockSim, q: float = 0.18) -> Tuple[np.ndarray, np.ndarray]:
    """Vectorized Bayesian feedback teacher/fallback.

    No hidden target/ramp arrays are read. v0.12 removes the Python per-env loop
    from v0.11, which is a major speedup at 32k-65k parallel environments.
    """
    n = env.n
    thr = env.threshold()
    found = env.best_known & (env.best >= thr)
    recover = found & (env.response < env.best - env.cfg.recover_drop)

    # v0.16.3 search prior mirrors real play: Rusted can sweep the full lock with
    # large steps; player locks stay inside the left 50% and use smaller steps so
    # steep/narrow ramps are not skipped.
    is_rusted = env.difficulty == 0
    stride = np.where(is_rusted, SAFE_SIM_RUSTED_STRIDE, SAFE_SIM_PLAYER_STRIDE).astype(np.float32)
    scan_limit = np.where(is_rusted, SAFE_SIM_RUSTED_LIMIT, SAFE_SIM_PLAYER_LIMIT).astype(np.float32)
    target = np.minimum(scan_limit, np.maximum(env.pos, env.furthest) + stride).astype(np.float32)

    # Found-signal cases: posterior mode inside a local window around remembered best.
    active = found & ~recover
    if active.any():
        rows = np.where(active)[0]
        span = max(env.cfg.recover_span, 0.12)
        local = np.abs(BELIEF_GRID[None, :] - env.best_pos[rows, None]) <= span
        masked = np.where(local, env.belief[rows], -1.0)
        peak = np.argmax(masked, axis=1)
        target[rows] = np.minimum(BELIEF_GRID[peak], scan_limit[rows])
    if recover.any():
        target[recover] = np.minimum(env.best_pos[recover], scan_limit[recover])

    # Hold selection is also fully vectorized.
    hold = np.zeros(n, np.int64)
    r = env.response
    L = len(env.cfg.hold_ms)
    hold[(r >= thr) & (r < 0.28)] = min(L - 1, 2)
    hold[(r >= 0.28) & (r < 0.48)] = min(L - 1, 4)
    hold[(r >= 0.48) & (r < 0.72)] = max(0, L - 2)
    hold[r >= 0.72] = L - 1
    return target.astype(np.float32), hold


def planner_target_from_memory(mem: SmartMemory, threshold: float, cfg: SmartConfig, q: float = 0.18) -> Tuple[float, int]:
    grid = BELIEF_GRID
    found = mem.best_known and mem.best_response >= threshold
    recover = found and mem.response < mem.best_response - cfg.recover_drop
    if not found:
        mask = grid >= min(0.999, mem.pos + cfg.search_min_advance)
        b = mem.belief * mask.astype(np.float32)
        if float(b.sum()) <= 1e-10:
            target = min(1.0, mem.pos + 0.14)
        else:
            b = b / b.sum()
            target = float(grid[min(len(grid)-1, int(np.searchsorted(np.cumsum(b), q)))])
        return target, 0
    if recover:
        target = mem.best_pos
    else:
        local = np.abs(grid - mem.best_pos) <= max(cfg.recover_span, 0.12)
        b = mem.belief * local.astype(np.float32)
        target = float(grid[int(np.argmax(b))]) if float(b.sum()) > 1e-10 else mem.best_pos
    if mem.response >= 0.72:
        hold = len(cfg.hold_ms)-1
    elif mem.response >= 0.48:
        hold = max(0, len(cfg.hold_ms)-2)
    elif mem.response >= 0.28:
        hold = min(len(cfg.hold_ms)-1, 4)
    elif mem.response >= threshold:
        hold = min(len(cfg.hold_ms)-1, 2)
    else:
        hold = 0
    return clamp01(target), hold


def generate_heuristic_warmup(rt: SmartRuntime, episodes: int) -> List[HumanSample]:
    """Vectorized Bayesian teacher warm-start.

    No hidden target information is used; it is a high-quality policy based only
    on visible feedback + belief/history memory. This reached high simulated
    success in internal sanity tests and is distilled into the neural network.
    """
    target_episodes = max(1, int(episodes))
    n = min(max(32, rt.cfg.sim_envs), target_episodes)
    env = VectorLockSim(rt, n, curriculum_level=1)
    samples: List[HumanSample] = []
    completed = 0
    max_transitions = target_episodes * rt.cfg.sim_max_steps * 2
    while completed < target_episodes and len(samples) < max_transitions:
        obs = env.obs()
        target, hold = planner_targets_from_env(env, q=0.18)
        low, high, _phase = env.bounds()
        unit = np.clip((target - low) / np.maximum(1e-6, high - low), 1e-4, 1-1e-4).astype(np.float32)
        weights = 1.2 + 2.5 * env.best
        for i in range(n):
            samples.append(HumanSample(obs[i].copy(), float(unit[i]), int(hold[i]), float(weights[i]), False, 0.35, "bayes_teacher"))
        _next, _rew, done, _info = env.step(unit, hold)
        completed += int(done.sum())
    return samples

def sim_policy_batch(rt: SmartRuntime, obs_np: np.ndarray, deterministic: bool = False) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    x = torch.as_tensor(obs_np, dtype=torch.float32, device=rt.device)
    with torch.no_grad():
        bd, hd, value = policy_dist(rt, x)
        if deterministic:
            action = bd.mean.clamp(1e-4, 1-1e-4)
            hold = torch.argmax(hd.logits, dim=-1)
        else:
            action = bd.sample().clamp(1e-4, 1-1e-4)
            hold = hd.sample()
        logp = bd.log_prob(action) + hd.log_prob(hold)
    return action.cpu().numpy().astype(np.float32), hold.cpu().numpy().astype(np.int64), logp.cpu().numpy().astype(np.float32), value.cpu().numpy().astype(np.float32)


def sim_evaluate(rt: SmartRuntime, level: int, episodes: Optional[int] = None) -> Dict[str, float]:
    episodes = int(episodes or rt.cfg.sim_eval_episodes)
    n = min(max(64, rt.cfg.sim_envs), episodes)
    env = VectorLockSim(rt, n, curriculum_level=level)
    completed = 0
    successes = 0
    steps = 0
    best_acc = 0.0
    time_acc = 0.0
    # Evaluate batches until enough episodes finish. Resets are automatic.
    while completed < episodes:
        obs = env.obs()
        act, hold, _lp, _v = sim_policy_batch(rt, obs, deterministic=True)
        _next, _rew, done, info = env.step(act, hold)
        d = done.astype(bool)
        if d.any():
            take = min(int(d.sum()), episodes - completed)
            idx = np.where(d)[0][:take]
            completed += take
            successes += int(info["success"][idx].sum())
            best_acc += float(info["best"][idx].sum())
            time_acc += float(info["elapsed"][idx].sum())
        steps += n
        if steps > episodes * rt.cfg.sim_max_steps * 4:
            break
    return {
        "episodes": float(completed),
        "success_rate": successes / max(1, completed),
        "avg_best": best_acc / max(1, completed),
        "avg_time": time_acc / max(1, completed),
        "steps": float(steps),
    }


def ultra_sim_train(rt: SmartRuntime) -> None:
    fit_sim_profile(rt, verbose=True)
    raw = input(f"How many ultra-fast simulator PPO updates? [{rt.cfg.sim_default_updates}]: ").strip()
    try:
        updates = int(raw) if raw else rt.cfg.sim_default_updates
    except Exception:
        updates = rt.cfg.sim_default_updates
    updates = max(1, min(5000, updates))

    warm = input(f"Run heuristic simulator warm-start first? [Y/n, {rt.cfg.sim_warmup_episodes} episodes]: ").strip().lower()
    if warm not in ("n", "no"):
        print("\nGenerating simulator teacher data (teacher uses visible feedback only)...")
        t0 = time.perf_counter()
        teacher = generate_heuristic_warmup(rt, rt.cfg.sim_warmup_episodes)
        print(f"Generated {len(teacher)} teacher transitions in {time.perf_counter()-t0:.2f}s")
        before = rt.model_hash()
        m = supervised_update(rt, teacher, rt.cfg.sim_warmup_epochs, rt.cfg.sim_warmup_lr, rt.cfg.sim_warmup_batch)
        rt.save()
        print(f"SIM warm-start: {int(m['samples'])} samples loss={m['loss']:.4f} | hash {before[:12]}->{rt.model_hash()[:12]}")

    level = int(rt.stats.data.get("sim_curriculum_level", 0) or 0)
    level = max(0, min(rt.cfg.sim_curriculum_max, level))
    env = VectorLockSim(rt, rt.cfg.sim_envs, curriculum_level=level)
    best_rate = float(rt.stats.data.get("sim_best_eval_rate", 0.0) or 0.0)
    print(
        f"\n=== ULTRA SIM TRAIN ===\n"
        f"envs={rt.cfg.sim_envs} rollout={rt.cfg.sim_rollout_steps} -> "
        f"{rt.cfg.sim_envs*rt.cfg.sim_rollout_steps:,} transitions/update | device={rt.device}\n"
        f"curriculum level={level}/{rt.cfg.sim_curriculum_max}"
    )
    start_wall = time.perf_counter()
    total_trans = 0
    for u in range(1, updates + 1):
        T, N = rt.cfg.sim_rollout_steps, rt.cfg.sim_envs
        batch = PPOBatch(T, N)
        for t in range(T):
            obs = env.obs()
            act, hold, logp, value = sim_policy_batch(rt, obs, deterministic=False)
            _next, reward, done, _info = env.step(act, hold)
            batch.obs[t] = obs
            batch.action[t] = act
            batch.hold[t] = hold
            batch.logp[t] = logp
            batch.value[t] = value
            batch.reward[t] = reward
            batch.done[t] = done
        with torch.no_grad():
            _a, _b, _h, v = rt.net(torch.as_tensor(env.obs(), dtype=torch.float32, device=rt.device))
            batch.next_value = v.cpu().numpy().astype(np.float32)
        metrics = ppo_update(rt, batch, source="sim")
        total_trans += T*N
        elapsed = time.perf_counter() - start_wall
        sps = total_trans / max(1e-6, elapsed)
        if u == 1 or u % 5 == 0 or u == updates:
            ev = sim_evaluate(rt, level, episodes=min(1024, rt.cfg.sim_eval_episodes))
            rate = ev["success_rate"]
            print(
                f"SIM {u:4d}/{updates} L{level} | eval={rate*100:5.1f}% "
                f"best={ev['avg_best']:.3f} time={ev['avg_time']:.2f}s | "
                f"loss={metrics['loss']:+.3f} H={metrics['entropy']:.3f} KL={metrics['kl']:.4f} | "
                f"{sps:,.0f} steps/s"
            )
            append_csv(
                SIM_LOG,
                ["wall_time", "update", "level", "eval_success", "avg_best", "avg_time", "loss", "entropy", "kl", "steps_per_second", "policy_hash"],
                {
                    "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"),
                    "update": int(rt.stats.data.get("sim_ppo_updates", 0) or 0),
                    "level": level,
                    "eval_success": rate,
                    "avg_best": ev["avg_best"],
                    "avg_time": ev["avg_time"],
                    "loss": metrics["loss"],
                    "entropy": metrics["entropy"],
                    "kl": metrics["kl"],
                    "steps_per_second": sps,
                    "policy_hash": rt.model_hash(),
                },
            )
            if rate > best_rate:
                best_rate = rate
                rt.stats.data["sim_best_eval_rate"] = rate
                rt.stats.save()
                rt.save(BEST_SIM_CKPT)
            if rate >= rt.cfg.sim_level_up_success and level < rt.cfg.sim_curriculum_max:
                level += 1
                rt.stats.data["sim_curriculum_level"] = level
                rt.stats.save()
                env = VectorLockSim(rt, rt.cfg.sim_envs, curriculum_level=level)
                print(f"[CURRICULUM] advanced to level {level}/{rt.cfg.sim_curriculum_max}")
        if u % max(1, rt.cfg.sim_checkpoint_every) == 0:
            rt.save(CHECKPOINT_DIR / f"smart_sim_{int(rt.stats.data.get('sim_ppo_updates',0)):06d}.pt")
    print(f"\nUltra sim complete: {total_trans:,} transitions in {time.perf_counter()-start_wall:.1f}s | best eval={best_rate*100:.1f}%")
    print("Next recommended step: deterministic REAL EVALUATE. If sim is good but real is poor, collect more SMART HUMAN TEACH data and re-fit/pretrain.")


# ---------------------------------------------------------------------------
# SMART HUMAN recorder with exact F hold duration
# ---------------------------------------------------------------------------

def smart_human_teach(rt: SmartRuntime) -> None:
    cfg = rt.classic_cfg
    # Wipe-safe: data/ may have been deleted while the menu was already open.
    # Recreate every directory Human Teach needs right before recording.
    demo_root = DATA_DIR / "demos"
    success_root = demo_root / "successful"
    failed_root = demo_root / "failed"
    incomplete_root = demo_root / "incomplete"
    autosave_root = demo_root / "_autosave"
    for _p in (DATA_DIR, SMART_DIR, AUDIT_DIR, CHECKPOINT_DIR, demo_root, success_root, failed_root, incomplete_root, TRAJECTORY_DIR, autosave_root):
        _p.mkdir(parents=True, exist_ok=True)
    print("\n=== SMART HUMAN TEACH v0.16.3 ===")
    print("Play normally. This recorder captures first move, exact F down/up duration, response, SUCCESS and failures.")
    print("F12 stops. F10 pauses. After recording, SMART neural pretraining runs automatically.\n")
    vision, console_hwnd, _game_hwnd = classic.prepare_live_vision(cfg, rt.calibration_model, minimize=True)
    rows: List[Dict[str, object]] = []
    trajectory_rows: List[Dict[str, object]] = []
    raw_samples: List[float] = []
    trajectory_last = 0.0
    episode_id = 1
    episode_start_idx = 0
    attempt_start = time.monotonic()
    last_response = 0.0
    best_response = 0.0
    last_probe_pos: Optional[float] = None
    last_probe_raw: Optional[float] = None
    prev_space = False
    prev_f = False
    success_latched = False
    episode_success_peak = 0.0
    last_ui_good = time.monotonic()
    session_success = session_fail = session_incomplete = 0
    active: Optional[Dict[str, object]] = None
    post_until = 0.0
    session_tag = time.strftime("%Y%m%d_%H%M%S")
    autosave_path = autosave_root / f"human_session_{session_tag}.csv"
    last_autosave_episode = 0

    def autosave_session(force: bool = False) -> None:
        nonlocal last_autosave_episode
        if not rows:
            return
        finalized = max(0, episode_id - 1)
        if (not force) and finalized < last_autosave_episode + 10:
            return
        # Recreate dirs again in case the user wiped data/ during recording.
        for _p in (DATA_DIR, demo_root, autosave_root, TRAJECTORY_DIR):
            _p.mkdir(parents=True, exist_ok=True)
        fields = list(rows[0].keys())
        tmp = autosave_path.with_suffix(".csv.tmp")
        with tmp.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader(); w.writerows(rows)
        tmp.replace(autosave_path)
        last_autosave_episode = finalized
        if force:
            print(f"[AUTOSAVE] protected {len(rows)} probes / {finalized} finalized episodes -> {autosave_path.name}")

    def finalize_probe(now: float) -> None:
        nonlocal active, post_until, last_response, best_response, last_probe_pos, last_probe_raw, attempt_start
        if active is None:
            return
        if bool(active.get("down", False)):
            return
        if now < post_until:
            return
        # Store *motion caused by this F probe*, not the absolute keyway angle.
        # Older recorder builds saved absolute progress and could report 0.9-1.0
        # on a dead probe simply because the slot detector's baseline was rotated.
        response = float(np.clip(max(
            float(active.get("peak_turn", 0.0)),
            float(active.get("peak_motion", 0.0)),
            rt.cfg.live_motion_jitter_weight * float(active.get("jitter_peak", 0.0)),
        ), 0.0, 1.0))
        pick_raw = float(active.get("pick_raw", float("nan")))
        pick_pos = float(active.get("pick_pos", float("nan")))
        hold_ms = max(1.0, float(active.get("release_t", now)) - float(active.get("press_t", now))) * 1000.0
        # Above line's max is intentionally corrected below; avoid old log corruption if timing fields absent.
        hold_ms = max(1.0, (float(active.get("release_t", now)) - float(active.get("press_t", now))) * 1000.0)
        rows.append({
            "t": float(active.get("press_t", now)),
            "elapsed": float(active.get("press_t", now)) - attempt_start,
            "pick_raw": pick_raw,
            "pick_pos": pick_pos,
            "response": response,
            "prev_response": last_response,
            "best_before": best_response,
            "prev_pick_raw": float(last_probe_raw) if last_probe_raw is not None else float("nan"),
            "prev_pick_pos": float(last_probe_pos) if last_probe_pos is not None else float("nan"),
            "hold_ms": hold_ms,
            "hold_press_t": float(active.get("press_t", now)),
            "hold_release_t": float(active.get("release_t", now)),
            "episode_id": episode_id,
            "episode_success": -1,
            "episode_status": "recording",
            "episode_elapsed": float("nan"),
            "terminal": 0,
            "success_score": float(active.get("success_peak", 0.0)),
        })
        last_response = response
        best_response = max(best_response, response)
        last_probe_pos = pick_pos if math.isfinite(pick_pos) else last_probe_pos
        last_probe_raw = pick_raw if math.isfinite(pick_raw) else last_probe_raw
        print(
            f"probe {len(rows):4d} | ep={episode_id:3d} | pos={pick_pos:.3f} | "
            f"F={hold_ms:5.0f}ms | resp={response:.3f} | best={best_response:.3f}",
            end="\r",
        )
        active = None
        post_until = 0.0

    def force_probe(now: float) -> None:
        nonlocal active, post_until
        if active is not None:
            if bool(active.get("down", False)):
                active["down"] = False
                active["release_t"] = now
            post_until = now
            finalize_probe(now)

    def finalize_episode(status: str, now: float, success_score: float = 0.0, reason: str = "") -> bool:
        nonlocal episode_id, episode_start_idx, attempt_start, last_response, best_response, last_probe_pos, last_probe_raw
        nonlocal session_success, session_fail, session_incomplete, episode_success_peak
        force_probe(now)
        if len(rows) <= episode_start_idx:
            attempt_start = now
            last_response = best_response = 0.0
            last_probe_pos = last_probe_raw = None
            return False
        code = 1 if status == "success" else (0 if status == "fail" else -1)
        elapsed = max(0.0, now - attempt_start)
        for j in range(episode_start_idx, len(rows)):
            rows[j]["episode_id"] = episode_id
            rows[j]["episode_success"] = code
            rows[j]["episode_status"] = status
            rows[j]["episode_elapsed"] = elapsed
            rows[j]["terminal"] = 1 if j == len(rows)-1 else 0
            if status == "success" and j == len(rows)-1:
                rows[j]["success_score"] = max(float(rows[j].get("success_score",0)), success_score)
        n = len(rows) - episode_start_idx
        if status == "success":
            session_success += 1
            print(f"\nHUMAN SUCCESS | ep={episode_id} t={elapsed:.2f}s probes={n} score={success_score:.3f}")
        elif status == "fail":
            session_fail += 1
            print(f"\nHUMAN FAIL | ep={episode_id} t={elapsed:.2f}s probes={n}{(' | '+reason) if reason else ''}")
        else:
            session_incomplete += 1
        episode_id += 1
        episode_start_idx = len(rows)
        attempt_start = now
        last_response = best_response = 0.0
        last_probe_pos = last_probe_raw = None
        episode_success_peak = 0.0
        autosave_session(force=False)
        return True

    target_dt = 1.0 / max(30, min(120, int(cfg.fps)))
    while True:
        loop = time.monotonic()
        if classic.emergency_or_pause(cfg):
            break
        st = vision.state(keep_frame=cfg.debug_preview)
        if st.pick_raw is not None and st.pick_score > 2.0:
            raw_samples.append(float(st.pick_raw))

        # Continue measuring a probe non-blockingly, including a short post-release response window.
        # Use relative lock motion from the F-down baseline, exactly like live_probe().
        episode_success_peak = max(float(episode_success_peak), float(st.success_score))
        if active is not None:
            base_angle = float(active.get("base_angle", st.lock_angle))
            base_progress = float(active.get("base_progress", st.progress))
            last_angle = float(active.get("last_angle", st.lock_angle))
            active["peak_turn"] = max(float(active.get("peak_turn", 0.0)), max(0.0, float(st.progress) - base_progress))
            active["peak_motion"] = max(float(active.get("peak_motion", 0.0)), _line_angle_delta(float(st.lock_angle), base_angle) / 90.0)
            active["jitter_peak"] = max(float(active.get("jitter_peak", 0.0)), _line_angle_delta(float(st.lock_angle), last_angle) / 90.0)
            active["last_angle"] = float(st.lock_angle)
            active["success_peak"] = max(float(active.get("success_peak", 0.0)), float(st.success_score))

        f_now = classic.is_key_down(cfg.f_key_vk)
        space_now_for_traj = classic.is_key_down(cfg.space_key_vk)
        if loop - trajectory_last >= 0.010:
            trajectory_rows.append({
                "t": loop,
                "episode_id": episode_id,
                "episode_elapsed": max(0.0, loop - attempt_start),
                "pick_raw": float(st.pick_raw) if st.pick_raw is not None else float("nan"),
                "pick_pos": float(st.pick_pos) if st.pick_pos is not None else float("nan"),
                "lock_progress": float(st.progress),
                "f_down": 1 if f_now else 0,
                "space_down": 1 if space_now_for_traj else 0,
                "success_score": float(st.success_score),
                "ui_confidence": float(st.ui_confidence),
            })
            trajectory_last = loop
        f_rising = f_now and not prev_f
        f_falling = (not f_now) and prev_f
        if f_rising and active is None and st.pick_raw is not None and not success_latched:
            if len(rows) == episode_start_idx:
                attempt_start = loop
            active = {
                "press_t": loop,
                "release_t": loop,
                "down": True,
                "pick_raw": float(st.pick_raw),
                "pick_pos": float(st.pick_pos) if st.pick_pos is not None else float("nan"),
                "base_angle": float(st.lock_angle),
                "base_progress": float(st.progress),
                "last_angle": float(st.lock_angle),
                "peak_turn": 0.0,
                "peak_motion": 0.0,
                "jitter_peak": 0.0,
                "success_peak": float(st.success_score),
            }
        if f_falling and active is not None and bool(active.get("down", False)):
            active["down"] = False
            active["release_t"] = loop
            post_until = loop + rt.cfg.live_probe_window_ms / 1000.0
        if active is not None and (not bool(active.get("down", False))) and loop >= post_until:
            finalize_probe(loop)
        prev_f = f_now

        space = space_now_for_traj
        rising_space = space and not prev_space
        if rising_space and not success_latched:
            if len(rows) > episode_start_idx or active is not None:
                # A borderline SUCCESS template score immediately before the new
                # attempt is safer to treat as success than blindly writing FAIL.
                # v0.16.1: use the same reference-ROI soft gate as the live
                # SUCCESS detector. Ordinary lock screens score far below this
                # in the bundled negative-reference self-test.
                soft_thr = float(getattr(cfg, "success_template_soft_threshold", 0.34))
                if episode_success_peak >= soft_thr:
                    finalize_episode("success", loop, episode_success_peak, "SUCCESS soft-latch before Space")
                    success_latched = True
                else:
                    finalize_episode("fail", loop, episode_success_peak, "Space -> new attempt")
            else:
                attempt_start = loop
        prev_space = space

        if st.success_detected and not success_latched:
            finalize_episode("success", loop, st.success_score, "SUCCESS")
            success_latched = True
        elif success_latched and st.success_score < cfg.success_template_threshold * 0.55:
            success_latched = False

        if st.ui_confidence > 0.12:
            last_ui_good = loop
        elif loop - last_ui_good > 0.80 and not success_latched:
            if finalize_episode("fail", loop, 0.0, "lock UI disappeared"):
                last_ui_good = loop

        if cfg.debug_preview:
            classic.preview(vision, st, "Lockpick Learner - SMART HUMAN TEACH")
        dt = time.monotonic() - loop
        if dt < target_dt:
            time.sleep(target_dt - dt)

    if len(rows) > episode_start_idx or active is not None:
        finalize_episode("incomplete", time.monotonic(), 0.0, "F12")
    # Persist a recovery copy BEFORE calibration/final archive/pretrain.
    # This means even a later save/pretrain exception does not throw away the session.
    autosave_session(force=True)
    if cfg.debug_preview:
        try: classic.cv2.destroyAllWindows()
        except Exception: pass
    if not rows:
        print("\nNo probes recorded.")
        classic.restore_console(console_hwnd)
        return

    if len(raw_samples) >= 20:
        left_raw = float(np.percentile(raw_samples, 2.0)); right_raw = float(np.percentile(raw_samples, 98.0))
        if right_raw - left_raw > 0.15:
            vision.update_calibration(left_raw, right_raw)
            rt.calibration_model.calibration.update(vision.cal)
            rt.calibration_model.save()
    left = rt.calibration_model.calibration.get("pick_left_raw"); right = rt.calibration_model.calibration.get("pick_right_raw")
    if left is not None and right is not None and right-left > 1e-5:
        for r in rows:
            pr = safe_float(r.get("pick_raw"), float("nan"))
            if math.isfinite(pr): r["pick_pos"] = clamp01((pr-left)/(right-left))
            ppr = safe_float(r.get("prev_pick_raw"), float("nan"))
            if math.isfinite(ppr): r["prev_pick_pos"] = clamp01((ppr-left)/(right-left))

    tag = time.strftime("%Y%m%d_%H%M%S")
    # Wipe-safe final save: never assume startup-created directories still exist.
    for _p in (DATA_DIR, demo_root, success_root, failed_root, incomplete_root, TRAJECTORY_DIR, autosave_root):
        _p.mkdir(parents=True, exist_ok=True)
    path = demo_root / f"demo_smart_{tag}.csv"
    fields = list(rows[0].keys())
    with path.open("w", newline="", encoding="utf-8") as f:
        w=csv.DictWriter(f, fieldnames=fields); w.writeheader(); w.writerows(rows)
    # Archive individual episodes for inspection.
    for eid in sorted({int(r["episode_id"]) for r in rows}):
        er = [r for r in rows if int(r["episode_id"])==eid]
        if not er: continue
        code = int(safe_float(er[-1].get("episode_success"), -1))
        sub = "successful" if code==1 else ("failed" if code==0 else "incomplete")
        dest = success_root if code==1 else (failed_root if code==0 else incomplete_root)
        dest.mkdir(parents=True, exist_ok=True)
        ap = dest / f"smart_{sub}_{tag}_ep{eid:03d}.csv"
        with ap.open("w", newline="", encoding="utf-8") as f:
            w=csv.DictWriter(f, fieldnames=fields); w.writeheader(); w.writerows(er)
    # Save a high-rate visual/input trajectory too. The policy trains at probe
    # decision points, but this stream preserves exact mouse/F timing and is used
    # for future system-identification/debugging without needing to re-record.
    if trajectory_rows:
        tpath = TRAJECTORY_DIR / f"trajectory_{tag}.csv"
        tfields = list(trajectory_rows[0].keys())
        with tpath.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=tfields); w.writeheader(); w.writerows(trajectory_rows)
        print(f"Saved {len(trajectory_rows)} trajectory samples -> {tpath.name} (~100 Hz target)")
    print(f"\nSaved {len(rows)} SMART probes -> {path.name}")
    print(f"episodes: success={session_success} fail={session_fail} incomplete={session_incomplete}")
    # Final master + archives + trajectory are now safely on disk.
    try:
        if autosave_path.exists():
            autosave_path.unlink()
    except Exception:
        pass
    classic.restore_console(console_hwnd)
    human_pretrain(rt)


# ---------------------------------------------------------------------------
# Live SMART agent
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class LockTypeResult:
    name: str
    confidence: float
    margin: float
    distances: Dict[str, float]


@dataclass(frozen=True)
class LiveLockProfile:
    name: str
    budget_sec: float
    threshold: float
    search_stride: float
    search_max_stride: float
    scan_limit: float
    scan_goal: float
    goal_deadline_frac: float
    confirm_abs: float
    confirm_step: float
    local_span: float
    finish_latch: float
    finish_force: float
    finish_offset: float
    finish_micro_probes: int


_LOCK_TYPE_SIGNATURES: Optional[Dict[str, Tuple[np.ndarray, np.ndarray]]] = None
_LOCK_NAMES = ("Rusted", "Basic", "Medium", "Enforced")


def _lock_face_feature(bgr: np.ndarray, alpha: Optional[np.ndarray] = None) -> Optional[Tuple[np.ndarray, np.ndarray]]:
    """Brightness-tolerant colour/texture signature from the metal annulus.

    The central keyway/pick is deliberately excluded.  This means the type
    classifier cannot leak the hidden ramp/target or depend on pick angle.
    """
    if bgr is None or bgr.size == 0 or bgr.ndim != 3:
        return None
    h, w = bgr.shape[:2]
    if min(h, w) < 80:
        return None
    yy, xx = np.mgrid[:h, :w]
    cx, cy = (w - 1) * 0.5, (h - 1) * 0.5
    rr = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / max(1.0, min(h, w) * 0.5)
    bright = bgr.astype(np.float32).mean(axis=2)
    mask = (rr > 0.28) & (rr < 0.90) & (bright > 25.0)
    if alpha is not None and alpha.shape[:2] == (h, w):
        mask &= alpha > 80
    if int(mask.sum()) < 1800:
        return None

    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    vals = lab[mask]
    stats = np.asarray([
        np.median(vals[:, 0]),
        np.percentile(vals[:, 0], 25),
        np.percentile(vals[:, 0], 75),
        np.median(vals[:, 1]),
        np.median(vals[:, 2]),
        np.percentile(vals[:, 1], 75) - np.percentile(vals[:, 1], 25),
        np.percentile(vals[:, 2], 75) - np.percentile(vals[:, 2], 25),
    ], dtype=np.float32)
    hist, _, _ = np.histogram2d(
        vals[:, 1], vals[:, 2], bins=(12, 12), range=((110, 150), (110, 160))
    )
    hist = hist.astype(np.float32).reshape(-1)
    hist /= max(1e-6, float(hist.sum()))
    return stats, hist


def _load_lock_type_signatures(force: bool = False) -> Dict[str, Tuple[np.ndarray, np.ndarray]]:
    global _LOCK_TYPE_SIGNATURES
    if _LOCK_TYPE_SIGNATURES is not None and not force:
        return _LOCK_TYPE_SIGNATURES
    out: Dict[str, Tuple[np.ndarray, np.ndarray]] = {}
    for name in _LOCK_NAMES:
        path = LOCK_TYPE_REF_DIR / f"{name}.png"
        im = cv2.imread(str(path), cv2.IMREAD_UNCHANGED) if path.exists() else None
        if im is None:
            continue
        if im.ndim == 3 and im.shape[2] == 4:
            feat = _lock_face_feature(im[:, :, :3], im[:, :, 3])
        else:
            feat = _lock_face_feature(im[:, :, :3] if im.ndim == 3 else im)
        if feat is not None:
            out[name] = feat
    _LOCK_TYPE_SIGNATURES = out
    return out


def _lock_feature_distance(a: Tuple[np.ndarray, np.ndarray], b: Tuple[np.ndarray, np.ndarray]) -> float:
    sa, ha = a
    sb, hb = b
    scales = np.asarray([36.0, 36.0, 36.0, 4.0, 4.0, 6.0, 7.0], dtype=np.float32)
    d_stats = float(np.linalg.norm((sa - sb) / scales))
    bc = float(np.sum(np.sqrt(np.maximum(0.0, ha) * np.maximum(0.0, hb))))
    d_hist = max(0.0, 1.0 - min(1.0, bc))
    return d_stats + 1.2 * d_hist


def _classify_lock_crop(crop_bgr: np.ndarray, cfg: SmartConfig) -> LockTypeResult:
    refs = _load_lock_type_signatures()
    feat = _lock_face_feature(crop_bgr)
    if feat is None or not refs:
        return LockTypeResult("Unknown", 0.0, 0.0, {})
    distances = {name: _lock_feature_distance(feat, ref) for name, ref in refs.items()}
    ordered = sorted(distances.items(), key=lambda kv: kv[1])
    best_name, best_d = ordered[0]
    second_d = ordered[1][1] if len(ordered) > 1 else best_d + 1.0
    temp = max(0.15, float(cfg.live_lock_type_softmax_temp))
    ds = np.asarray([distances[n] for n in refs.keys()], dtype=np.float64)
    logits = -(ds - ds.min()) / temp
    probs = np.exp(np.clip(logits, -40.0, 0.0))
    probs /= max(1e-12, float(probs.sum()))
    names = list(refs.keys())
    confidence = float(probs[names.index(best_name)])
    return LockTypeResult(best_name, confidence, float(second_d - best_d), distances)


def classify_lock_type_live(rt: SmartRuntime, vision: classic.ScreenVision) -> LockTypeResult:
    """Classify lock body using 3-6 short frame samples and the bundled refs."""
    if not rt.cfg.live_lock_type_detection:
        return LockTypeResult("Unknown", 0.0, 0.0, {})
    refs = _load_lock_type_signatures()
    if len(refs) < 4:
        return LockTypeResult("Unknown", 0.0, 0.0, {})
    per_frame: List[Dict[str, float]] = []
    frames = int(np.clip(rt.cfg.live_lock_type_sample_frames, 1, 8))
    for i in range(frames):
        frame = vision.grab()
        c = int(vision.half)
        hr = max(70, int(round(float(vision.radius) * 1.03)))
        y0, y1 = max(0, c - hr), min(frame.shape[0], c + hr)
        x0, x1 = max(0, c - hr), min(frame.shape[1], c + hr)
        crop = frame[y0:y1, x0:x1]
        res = _classify_lock_crop(crop, rt.cfg)
        if res.distances:
            per_frame.append(res.distances)
        if i + 1 < frames and rt.cfg.live_lock_type_sample_gap_ms > 0:
            time.sleep(rt.cfg.live_lock_type_sample_gap_ms / 1000.0)
    if not per_frame:
        return LockTypeResult("Unknown", 0.0, 0.0, {})
    med = {name: float(np.median([d.get(name, 99.0) for d in per_frame])) for name in refs.keys()}
    ordered = sorted(med.items(), key=lambda kv: kv[1])
    best_name, best_d = ordered[0]
    second_d = ordered[1][1] if len(ordered) > 1 else best_d + 1.0
    temp = max(0.15, float(rt.cfg.live_lock_type_softmax_temp))
    names = list(refs.keys())
    ds = np.asarray([med[n] for n in names], dtype=np.float64)
    logits = -(ds - ds.min()) / temp
    probs = np.exp(np.clip(logits, -40.0, 0.0))
    probs /= max(1e-12, float(probs.sum()))
    confidence = float(probs[names.index(best_name)])
    return LockTypeResult(best_name, confidence, float(second_d - best_d), med)


def live_profile_for_lock(rt: SmartRuntime, lock_name: str) -> LiveLockProfile:
    if lock_name == "Rusted":
        return LiveLockProfile(
            "Rusted",
            max(10.0, float(rt.cfg.rusted_budget_sec)),
            float(np.clip(rt.cfg.rusted_meaningful_response, 0.018, 0.10)),
            float(np.clip(rt.cfg.live_search_stride_rusted, 0.05, 0.18)),
            float(np.clip(rt.cfg.live_search_max_stride_rusted, 0.06, 0.20)),
            float(np.clip(rt.cfg.rusted_scan_limit, 0.75, 1.0)),
            float(np.clip(rt.cfg.rusted_search_goal, 0.75, 1.0)),
            float(np.clip(rt.cfg.rusted_search_goal_deadline_frac, 0.30, 0.90)),
            float(np.clip(rt.cfg.rusted_ramp_confirm_abs, 0.04, 0.20)),
            float(np.clip(rt.cfg.rusted_ramp_confirm_step, 0.004, 0.04)),
            float(np.clip(rt.cfg.rusted_local_span, 0.015, 0.09)),
            float(np.clip(rt.cfg.rusted_finish_latch_response, 0.12, 0.80)),
            float(np.clip(rt.cfg.rusted_finish_force_response, 0.16, 0.90)),
            float(np.clip(rt.cfg.rusted_finish_offset, 0.001, 0.012)),
            max(0, int(rt.cfg.rusted_finish_micro_probes)),
        )
    # Basic / Medium / Enforced deliberately focus the LEFT half. Unknown fails safe
    # to the same short player-lock profile; it must never get a Rusted 10 s policy.
    return LiveLockProfile(
        lock_name if lock_name in ("Basic", "Medium", "Enforced") else "Unknown-player",
        max(float(rt.cfg.live_min_attempt_budget_sec), float(rt.cfg.player_budget_sec), float(rt.classic_cfg.attempt_budget_seconds)),
        float(np.clip(rt.cfg.player_meaningful_response, 0.02, 0.20)),
        float(np.clip(rt.cfg.live_search_stride_player, 0.025, 0.08)),
        float(np.clip(rt.cfg.live_search_max_stride_player, 0.03, 0.09)),
        float(np.clip(rt.cfg.player_scan_limit, 0.25, 0.60)),
        float(np.clip(rt.cfg.player_search_goal, 0.25, 0.60)),
        float(np.clip(rt.cfg.player_search_goal_deadline_frac, 0.20, 0.75)),
        float(np.clip(rt.cfg.player_ramp_confirm_abs, 0.055, 0.18)),
        float(np.clip(rt.cfg.player_ramp_confirm_step, 0.002, 0.02)),
        float(np.clip(rt.cfg.player_local_span, 0.010, 0.05)),
        float(np.clip(rt.cfg.player_finish_latch_response, 0.15, 0.70)),
        float(np.clip(rt.cfg.player_finish_force_response, 0.18, 0.80)),
        float(np.clip(rt.cfg.player_finish_offset, 0.0008, 0.008)),
        max(0, int(rt.cfg.player_finish_micro_probes)),
    )


def lock_type_reference_selftest(rt: SmartRuntime) -> Tuple[int, int]:
    refs = _load_lock_type_signatures(force=True)
    passed = 0
    total = 0
    for name in _LOCK_NAMES:
        path = LOCK_TYPE_REF_DIR / f"{name}.png"
        im = cv2.imread(str(path), cv2.IMREAD_UNCHANGED) if path.exists() else None
        if im is None:
            continue
        total += 1
        bgr = im[:, :, :3] if im.ndim == 3 else im
        res = _classify_lock_crop(bgr, rt.cfg)
        if res.name == name:
            passed += 1
    return passed, total


def lock_type_debug(rt: SmartRuntime) -> None:
    if not classic.IS_WINDOWS:
        print("Lock-type live debug requires Windows.")
        return
    vision, console = prepare_live(rt)
    if vision is None:
        return
    print("\n=== LOCK TYPE REFERENCE DEBUG ===")
    print("Reads only the lock body. No F/Space/mouse input. F12 closes.")
    try:
        while True:
            if classic.is_key_down(rt.classic_cfg.emergency_key_vk):
                break
            res = classify_lock_type_live(rt, vision)
            detail = " ".join(f"{k}:{v:.2f}" for k, v in sorted(res.distances.items(), key=lambda kv: kv[1]))
            print(f"type={res.name:<8} conf={res.confidence:.2f} margin={res.margin:.2f} | {detail:<55}", end="\r")
            time.sleep(0.16)
    finally:
        print()
        classic.restore_console(console)


def prepare_live(rt: SmartRuntime):
    # v0.13 no longer requires visual pick tracking during play. The lock centre/ROI
    # still comes from ScreenVision, while horizontal pick position is dead-reckoned
    # from our own mouse commands after every attempt hard-resets to the left stop.
    vision, console, _hwnd = classic.prepare_live_vision(rt.classic_cfg, rt.calibration_model, minimize=True)
    if vision is None:
        classic.restore_console(console)
        return None, console
    gain = safe_float(rt.calibration_model.calibration.get("mouse_counts_per_norm"), 3600.0)
    if not (100.0 <= gain <= 8000.0):
        gain = 3600.0
        rt.calibration_model.calibration["mouse_counts_per_norm"] = gain
        print("[LIVE] mouse gain missing/invalid -> using conservative 3600 counts/full-range; run CALIBRATE later for exact scaling.")
    return vision, console


def fast_move_to(rt: SmartRuntime, vision: classic.ScreenVision, target: float, current_pos: float) -> Optional[float]:
    gain = safe_float(rt.calibration_model.calibration.get("mouse_counts_per_norm"), 3600.0)
    gain = float(np.clip(gain, 100.0, 8000.0))
    pos = clamp01(float(current_pos))
    target = clamp01(float(target))
    err = target - pos
    if abs(err) <= rt.cfg.live_move_tolerance:
        return pos
    counts = int(np.clip(round(err * gain), -6000, 6000))
    if counts == 0:
        counts = 1 if err > 0 else -1
    classic.move_mouse_relative(counts, 0)
    time.sleep(rt.cfg.live_move_settle_ms / 1000.0)
    # Dead-reckoning is intentional: the attempt always starts against the hard
    # left stop, so cumulative error is reset every attempt. This removes noisy
    # pick-vision corrections that previously produced impossible jumps (e.g.
    # target ~0.33 but measured position ~0.02).
    return clamp01(pos + counts / gain)


def _line_angle_delta(a: float, b: float) -> float:
    d = abs(float(a) - float(b)) % 180.0
    return min(d, 180.0 - d)


def fast_progress_success(vision: classic.ScreenVision) -> Tuple[float, float, float, float]:
    # No pick detection here: only the lock keyway rotation + SUCCESS template.
    frame = vision.grab()
    angle, progress, dark = vision.detect_lock_rotation(frame)
    success_score, _success = vision.detect_success(frame)
    return float(angle), float(progress), float(dark), float(success_score)


def live_probe(rt: SmartRuntime, vision: classic.ScreenVision, hold_idx: int) -> Tuple[float, float, float, float, float]:
    """Measure the lock WHILE F is physically down, then briefly after release.

    v0.12 called blocking send_key() first and only sampled frames after F had
    already been released. SCUM can visibly rotate/jolt during the press and snap
    back immediately, so those ramp signals were systematically missed.
    """
    frame0 = vision.grab()
    base_angle, base_progress, base_dark = vision.detect_lock_rotation(frame0)
    success_peak, _ = vision.detect_success(frame0)
    hold_ms = int(rt.cfg.hold_ms[hold_idx])
    hold_end = time.monotonic() + max(1, hold_ms) / 1000.0
    peak_turn = 0.0
    peak_motion = 0.0
    ui = float(base_dark)
    angles: List[float] = [float(base_angle)]

    classic.press_key_down(rt.classic_cfg.f_key_vk)
    try:
        while time.monotonic() < hold_end:
            ang, prog, dark, ss = fast_progress_success(vision)
            angles.append(ang)
            peak_turn = max(peak_turn, max(0.0, prog - base_progress))
            peak_motion = max(peak_motion, _line_angle_delta(ang, base_angle) / 90.0)
            ui = max(ui, dark)
            success_peak = max(success_peak, ss)
            if rt.cfg.live_probe_sample_sleep_ms > 0:
                time.sleep(rt.cfg.live_probe_sample_sleep_ms / 1000.0)
    finally:
        classic.key_up(rt.classic_cfg.f_key_vk)

    post_end = time.monotonic() + max(0, int(rt.cfg.live_probe_post_ms)) / 1000.0
    while time.monotonic() < post_end:
        ang, prog, dark, ss = fast_progress_success(vision)
        angles.append(ang)
        peak_turn = max(peak_turn, max(0.0, prog - base_progress))
        peak_motion = max(peak_motion, _line_angle_delta(ang, base_angle) / 90.0)
        ui = max(ui, dark)
        success_peak = max(success_peak, ss)
        if rt.cfg.live_probe_sample_sleep_ms > 0:
            time.sleep(rt.cfg.live_probe_sample_sleep_ms / 1000.0)

    # Jitter is based on consecutive orientation changes. A ramp can produce a
    # visible jolt even when the peak orientation is brief. Keep its contribution
    # bounded so detector noise cannot dominate a genuine sustained turn.
    jitter = 0.0
    if len(angles) >= 3:
        diffs = np.asarray([_line_angle_delta(angles[i], angles[i-1]) / 90.0 for i in range(1, len(angles))], dtype=np.float32)
        if diffs.size:
            jitter = float(np.clip(np.percentile(diffs, 90), 0.0, 0.35))
    response = float(np.clip(max(peak_turn, peak_motion, rt.cfg.live_motion_jitter_weight * jitter), 0.0, 1.0))
    return response, float(ui), float(success_peak), float(peak_motion), float(jitter)


def step_reward(rt: SmartRuntime, mem: SmartMemory, new_response: float, step_seconds: float, success: bool, elapsed: float, threshold: Optional[float] = None, budget: Optional[float] = None) -> float:
    old = mem.response
    old_best = mem.best_response
    improvement = new_response - old
    best_gain = max(0.0, new_response - old_best)
    thr = float(threshold if threshold is not None else (rt.profile.meaningful_response or rt.cfg.meaningful_response_default))
    r = (
        rt.cfg.reward_progress_gain * max(0.0, improvement)
        + rt.cfg.reward_best_gain * best_gain
        + rt.cfg.reward_absolute * new_response
        - rt.cfg.reward_regression * max(0.0, -improvement)
        - rt.cfg.reward_probe_cost
        - rt.cfg.reward_time_cost * step_seconds
    )
    if old_best < thr <= new_response:
        r += rt.cfg.reward_first_signal
    if old_best >= thr and old < old_best - rt.cfg.recover_drop and new_response > old + 0.04:
        r += rt.cfg.reward_recover
    if success:
        speed_budget = float(budget if budget is not None else rt.classic_cfg.attempt_budget_seconds)
        speed = max(0.0, 1.0 - elapsed / max(0.1, speed_budget))
        r += rt.cfg.reward_success + rt.cfg.reward_speed_bonus * speed
    return float(r)


def log_real_episode(path: Path, mode: str, success: bool, elapsed: float, steps: int, total_reward: float, best: float, rt: SmartRuntime) -> None:
    append_csv(path, ["wall_time","mode","success","elapsed","steps","reward","best","hash"], {
        "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"), "mode": mode, "success": int(success),
        "elapsed": elapsed, "steps": steps, "reward": total_reward, "best": best, "hash": rt.model_hash(),
    })


def live_run(rt: SmartRuntime, learning: bool, max_attempts: Optional[int]) -> None:
    if not classic.IS_WINDOWS:
        print("Live play requires Windows.")
        return
    fit_sim_profile(rt, verbose=False)
    vision, console = prepare_live(rt)
    if vision is None:
        return
    mode = "SMART REAL TRAIN" if learning else "SMART REAL EVALUATE"
    print(f"\n=== {mode} ===")
    print("Continuous absolute-position policy + explicit best-position/history/belief memory.")
    print("F12 emergency stop. F10 pause.")
    before_hash = rt.model_hash()
    real_buffer: List[PPOStep] = []
    attempt = 0
    aborted = False
    print("[LIVE] lock-type refs ON; motion sampled DURING F; pick vision OFF")
    rt.net.eval()
    last_lock_type: Optional[str] = None
    type_batch: Dict[str, List[int]] = {}

    while max_attempts is None or attempt < max_attempts:
        if classic.emergency_or_pause(rt.classic_cfg):
            aborted = True; break
        attempt += 1

        # Classify BEFORE Space so the lock face is stationary and the full
        # reference body is visible.  A low-confidence frame may reuse the last
        # confident type on retries of the same lock, otherwise it fails safe to
        # the short player-lock profile.
        detected = classify_lock_type_live(rt, vision)
        accepted_type = detected.name if detected.confidence >= rt.cfg.live_lock_type_min_confidence else None
        if accepted_type in _LOCK_NAMES:
            last_lock_type = accepted_type
            lock_name = accepted_type
            type_source = "ref"
        elif last_lock_type in _LOCK_NAMES:
            lock_name = str(last_lock_type)
            type_source = "carry"
        else:
            lock_name = "Unknown"
            type_source = "safe"
        lp = live_profile_for_lock(rt, lock_name)
        threshold = lp.threshold
        detail = ", ".join(f"{k}={v:.2f}" for k, v in sorted(detected.distances.items(), key=lambda kv: kv[1])[:2]) if detected.distances else "no refs"
        print(f"\n--- SMART attempt {attempt} | {lp.name} ({type_source}, conf={detected.confidence:.2f}, {detail}) ---")
        print(f"[LOCK] budget={lp.budget_sec:.1f}s probe-cap=NONE first-motion={threshold:.3f} "
              f"scan-limit={100*lp.scan_limit:.0f}% goal={100*lp.scan_goal:.0f}%")
        append_csv(LOCK_TYPE_LOG, ["wall_time","mode","attempt","detected","selected","source","confidence","margin","budget","probe_cap","threshold","distances"], {
            "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"), "mode": mode, "attempt": attempt,
            "detected": detected.name, "selected": lp.name, "source": type_source, "confidence": detected.confidence,
            "margin": detected.margin, "budget": lp.budget_sec, "probe_cap": "NONE",
            "threshold": threshold, "distances": json.dumps(detected.distances, separators=(",",":")),
        })

        classic.send_key(rt.classic_cfg.space_key_vk, 28)
        time.sleep(rt.cfg.live_start_wait_ms / 1000.0)
        classic.move_mouse_relative(-6000, 0)
        time.sleep(0.06)
        mem = SmartMemory(pos=0.0, furthest_pos=0.0)
        start = time.monotonic()
        live_budget = float(lp.budget_sec)
        dead_probes = 0  # diagnostic only; NEVER terminates a live attempt
        success = False
        total_reward = 0.0
        episode_steps: List[PPOStep] = []
        episode_trainable: List[bool] = []
        latest_success = 0.0

        # v0.16 live controller state. Neural output is still used, but these
        # guardrails prevent a single noisy early response from trapping the
        # policy in a tiny patch of the lock.
        confirmed_ramp = False
        pending_signal_pos: Optional[float] = None
        pending_signal_response = 0.0
        global_frontier = 0.0
        local_no_gain = 0
        finish_latched = False
        finish_attempt = 0
        search_pass = 1
        probe_count = 0
        print(
            f"[SCAN] no probe-count stop | range=0..{100*lp.scan_limit:.0f}% | goal={100*lp.scan_goal:.0f}% | "
            f"stride={lp.search_stride:.3f}..{lp.search_max_stride:.3f} | stop=SUCCESS/time/minigame end"
        )

        while True:
            if classic.emergency_or_pause(rt.classic_cfg):
                aborted = True; break
            elapsed = time.monotonic() - start
            # The real time budget is authoritative. No fake 7/30/36-probe cap.
            if elapsed >= live_budget + 0.20:
                break
            mem.elapsed = elapsed
            obs = obs_from_memory(mem, live_budget, threshold, len(rt.cfg.hold_ms), rt.cfg)
            unit, hold_idx, logp, value, mean_unit, hprob = policy_action(rt, obs, deterministic=not learning)
            target, low, high, phase = unit_to_target(unit, mem, threshold, rt.cfg)
            override_reason = ""
            trainable_action = True

            # -------- v0.16 deterministic live safety layer --------
            # 1) High real rotation -> stop hunting broadly. Return to the best
            # remembered position and try a long hold. If dead-reckoning is off by
            # a hair, bracket it with tiny +/- offsets instead of wandering away.
            if confirmed_ramp and (finish_latched or mem.best_response >= lp.finish_latch):
                finish_latched = True
                eps = float(lp.finish_offset)
                micro_n = max(0, int(lp.finish_micro_probes))
                # First do only a couple of *tiny* short probes around the best
                # position. Player locks get just +/-eps; Rusted can afford more.
                micro_offsets = (+eps, -eps, +2.0*eps, -2.0*eps)
                if finish_attempt < micro_n:
                    off = micro_offsets[min(finish_attempt, len(micro_offsets)-1)]
                    target = float(np.clip(mem.best_pos + off, 0.0, lp.scan_limit))
                    hold_idx = 0
                    phase = "MICRO"
                    override_reason = f"micro#{finish_attempt+1}"
                else:
                    # COMMIT: use the best position found by the micro bracket and
                    # actually hold F. Once the response is strong enough the agent
                    # must stop dithering with taps.
                    target = float(np.clip(mem.best_pos, 0.0, lp.scan_limit))
                    phase = "FINISH"
                    if mem.best_response >= lp.finish_force:
                        hold_idx = len(rt.cfg.hold_ms) - 1
                    else:
                        hold_idx = max(0, len(rt.cfg.hold_ms) - 2)
                    override_reason = f"commit#{max(1, finish_attempt-micro_n+1)}"
                low = high = target
                trainable_action = False

            # 2) A first weak twitch is only a CANDIDATE. Confirm it with one nearby
            # short probe before abandoning the global left->right scan.
            elif not confirmed_ramp and pending_signal_pos is not None:
                step = float(lp.confirm_step)
                target = clamp01(pending_signal_pos + (step if pending_signal_pos < 0.97 else -step))
                low = high = target
                hold_idx = 0
                phase = "CONFIRM"
                override_reason = "confirm weak ramp"
                trainable_action = False

            # 3) Until a ramp is confirmed, FORCE monotonic coverage. Neural may
            # choose the exact point inside the allowed stride, but it cannot sit
            # and polish the same 5% of the lock forever.
            elif not confirmed_ramp:
                # If the full first pass was scanned with no confirmed response and
                # time remains, start another finer pass from the hard-left stop.
                edge = float(lp.scan_limit)
                if global_frontier >= edge - 0.002 and (live_budget - elapsed) > 0.35:
                    target = 0.0
                    low = high = 0.0
                    hold_idx = 0
                    phase = "RESCAN"
                    override_reason = f"rescan#{search_pass+1}"
                    trainable_action = False
                else:
                    frac = float(np.clip(elapsed / max(0.1, live_budget), 0.0, 1.0))
                    deadline = max(0.10, float(lp.goal_deadline_frac))
                    schedule_floor = float(lp.scan_goal) * min(1.0, frac / deadline)
                    # Later passes get a little finer rather than repeatedly
                    # stepping across the exact same gaps.
                    scale = max(0.55, float(rt.cfg.live_rescan_stride_scale) ** max(0, search_pass-1))
                    stride = lp.search_stride * scale
                    max_stride = lp.search_max_stride * scale
                    min_t = min(edge, max(global_frontier + stride, schedule_floor))
                    max_t = min(edge, max(min_t, global_frontier + max_stride))
                    target = float(np.clip(target, min_t, max_t))
                    low, high = min_t, max_t
                    hold_idx = 0
                    phase = "SEARCH"
                    if abs(target - (low + clamp01(unit)*(high-low))) > 1e-4 or min_t > mem.pos + 1e-5:
                        override_reason = "coverage"
                        trainable_action = False

            # 4) Confirmed ramp, but not yet high enough for FINISH: keep local
            # neural control bounded around the remembered best. This preserves
            # the gradient-search skill while preventing wild exits.
            else:
                local_span = float(lp.local_span)
                l2 = max(0.0, mem.best_pos - local_span)
                h2 = min(float(lp.scan_limit), mem.best_pos + local_span)
                if target < l2 or target > h2:
                    target = float(np.clip(target, l2, h2))
                    low, high = l2, h2
                    override_reason = "local-bound"
                    trainable_action = False

            # Absolute final domain cap: player locks never move beyond the chosen
            # left-edge search domain, even if a neural/local branch proposes it.
            target = float(np.clip(target, 0.0, lp.scan_limit))
            low = min(low, lp.scan_limit); high = min(high, lp.scan_limit)

            step_t = time.monotonic()
            moved = fast_move_to(rt, vision, target, mem.pos)
            if moved is None:
                aborted = True; break
            new_response, ui, ss, motion, jitter = live_probe(rt, vision, hold_idx)
            probe_count += 1
            latest_success = max(latest_success, ss)
            elapsed = time.monotonic() - start
            success = ss >= rt.classic_cfg.success_template_threshold
            if (not success) and ui < 0.04 and elapsed > 0.35:
                late = classic.wait_success_text(vision, rt.classic_cfg, ms=rt.cfg.live_success_wait_ms)
                latest_success = max(latest_success, late)
                success = late >= rt.classic_cfg.success_template_threshold

            reward = step_reward(rt, mem, new_response, time.monotonic()-step_t, success, elapsed, threshold=threshold, budget=live_budget)
            total_reward += reward
            if (not success) and new_response < threshold:
                dead_probes += 1

            prev_best = float(mem.best_response)
            prev_pos = float(mem.pos)
            done = success or elapsed >= live_budget + 0.15
            episode_steps.append(PPOStep(obs, unit, hold_idx, logp, value, reward, done))
            episode_trainable.append(trainable_action)
            memory_after_probe(mem, moved, new_response, hold_idx, reward, elapsed, threshold, rt.profile, rt.cfg)

            # -------- update live controller state from REAL feedback --------
            confirm_abs = max(float(lp.confirm_abs), threshold * float(rt.cfg.live_ramp_confirm_multiplier))
            if not confirmed_ramp:
                if phase == "RESCAN":
                    global_frontier = 0.0
                    search_pass += 1
                    pending_signal_pos = None
                    pending_signal_response = 0.0
                else:
                    global_frontier = max(global_frontier, float(moved))

                if pending_signal_pos is not None:
                    # Two nearby above-threshold samples OR one unequivocally strong
                    # sample confirms the ramp. Otherwise discard the twitch and
                    # resume the global scan from the furthest tested point.
                    confirmed_now = (
                        (pending_signal_response >= threshold and new_response >= threshold * 0.80)
                        or max(pending_signal_response, new_response) >= confirm_abs
                    )
                    if confirmed_now:
                        confirmed_ramp = True
                        local_no_gain = 0
                    pending_signal_pos = None
                    pending_signal_response = 0.0
                elif new_response >= confirm_abs:
                    confirmed_ramp = True
                    local_no_gain = 0
                elif new_response >= threshold:
                    pending_signal_pos = float(moved)
                    pending_signal_response = float(new_response)

            else:
                if new_response >= lp.finish_latch or mem.best_response >= lp.finish_latch:
                    finish_latched = True
                if phase == "MICRO":
                    finish_attempt += 1
                elif phase == "FINISH":
                    # A failed long hold should not be repeated forever at the same
                    # coordinate. Re-bracket around the current best, then commit again.
                    finish_attempt = 0 if not success else finish_attempt + 1
                if finish_attempt >= max(1, int(rt.cfg.live_finish_max_offsets)):
                    finish_latched = False
                    finish_attempt = 0

                # If a supposed ramp produces no gain for several local probes and
                # has not reached the finish latch, treat it as a false/weak basin
                # and resume systematic search inside this lock type's scan domain.
                if mem.best_response < lp.finish_latch:
                    if new_response > prev_best + 0.015:
                        local_no_gain = 0
                    elif new_response < max(threshold, prev_best - 0.020):
                        local_no_gain += 1
                    else:
                        local_no_gain = max(0, local_no_gain - 1)
                    if local_no_gain >= max(2, int(rt.cfg.live_local_no_gain_limit)):
                        confirmed_ramp = False
                        finish_latched = False
                        finish_attempt = 0
                        pending_signal_pos = None
                        pending_signal_response = 0.0
                        local_no_gain = 0
                        global_frontier = max(global_frontier, mem.furthest_pos)
                        # Advance the frontier on the next SEARCH instead of camping
                        # around this failed local basin.
                        global_frontier = min(float(lp.scan_limit)-0.001, global_frontier + float(rt.cfg.live_local_escape_stride) * 0.25)

            coverage = max(global_frontier, mem.furthest_pos if not confirmed_ramp else global_frontier)
            ov = f" ov={override_reason}" if override_reason else ""
            print(
                f"phase={phase:<7} p={mem.pos:.3f} target={target:.3f} [{low:.3f},{high:.3f}] "
                f"resp={new_response:.3f} motion={motion:.3f} jit={jitter:.3f} best={mem.best_response:.3f}@{mem.best_pos:.3f} "
                f"r={reward:+.2f} F={rt.cfg.hold_ms[hold_idx]}ms probes={probe_count} dead={dead_probes} "
                f"scan={100*coverage:4.0f}% pass={search_pass} conf={int(confirmed_ramp)} meanU={mean_unit:.2f} success={latest_success:.2f}{ov}",
                end="\r",
            )
            append_csv(DECISION_LOG, ["wall_time","mode","attempt","step","phase","obs","unit","target","low","high","hold","response","motion","jitter","best","best_pos","reward","success_score","override","scan_coverage","confirmed","hash"], {
                "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"), "mode": mode, "attempt": attempt, "step": mem.step_no,
                "phase": phase, "obs": json.dumps([round(float(x),5) for x in obs], separators=(",",":")),
                "unit": unit, "target": target, "low": low, "high": high, "hold": rt.cfg.hold_ms[hold_idx],
                "response": new_response, "motion": motion, "jitter": jitter, "best": mem.best_response, "best_pos": mem.best_pos,
                "reward": reward, "success_score": latest_success, "override": override_reason,
                "scan_coverage": coverage, "confirmed": int(confirmed_ramp), "hash": rt.model_hash(),
            })
            if done:
                break
        if aborted:
            print("\nIncomplete episode discarded.")
            break
        elapsed = time.monotonic() - start
        if not success:
            late = classic.wait_success_text(vision, rt.classic_cfg, ms=rt.cfg.live_success_wait_ms)
            latest_success = max(latest_success, late)
            success = late >= rt.classic_cfg.success_template_threshold
        if episode_steps and not success:
            terminal_penalty = rt.cfg.reward_fail * max(0.35, 1.0 - 0.65*mem.best_response)
            episode_steps[-1].reward += terminal_penalty
            episode_steps[-1].done = True
            total_reward += terminal_penalty
        elif episode_steps and success and not episode_steps[-1].done:
            bonus = rt.cfg.reward_success + rt.cfg.reward_speed_bonus * max(0.0, 1.0-elapsed/max(0.1,live_budget))
            episode_steps[-1].reward += bonus
            episode_steps[-1].done = True
            total_reward += bonus

        print(f"\nSMART {'SUCCESS' if success else 'FAIL'} | type={lp.name} t={elapsed:.2f}/{live_budget:.1f}s steps={len(episode_steps)} best={mem.best_response:.3f}@{mem.best_pos:.3f} reward={total_reward:.1f}")
        type_batch.setdefault(lp.name, [0, 0])
        type_batch[lp.name][0] += 1
        type_batch[lp.name][1] += int(success)
        key = lp.name.lower().replace("-", "_")
        rt.stats.inc(f"real_{'train' if learning else 'eval'}_{key}_attempts", 1)
        if success:
            rt.stats.inc(f"real_{'train' if learning else 'eval'}_{key}_successes", 1)

        if learning:
            rt.stats.inc("real_train_attempts",1)
            if success: rt.stats.inc("real_train_successes",1)
            # Safety-override actions are deliberately excluded from on-policy
            # REAL PPO: their executed target/hold did not come from the sampled
            # policy distribution. This keeps PPO mathematically honest.
            real_buffer.extend([tr for tr, ok in zip(episode_steps, episode_trainable) if ok])
            log_real_episode(REAL_EPISODES, mode + ":" + lp.name, success, elapsed, len(episode_steps), total_reward, mem.best_response, rt)
            if len(real_buffer) >= rt.cfg.real_rollout_min_steps:
                T = len(real_buffer)
                b = PPOBatch(T, 1)
                for i, tr in enumerate(real_buffer):
                    b.obs[i,0]=tr.obs; b.action[i,0]=tr.unit_action; b.hold[i,0]=tr.hold_action; b.logp[i,0]=tr.logp; b.value[i,0]=tr.value; b.reward[i,0]=tr.reward; b.done[i,0]=1.0 if tr.done else 0.0
                b.next_value[0]=0.0
                m=ppo_update(rt,b,"real")
                print(f"REAL PPO update: n={T} loss={m['loss']:+.3f} KL={m['kl']:.4f} hash={rt.model_hash()[:12]}")
                real_buffer=[]
                rt.net.eval()
        else:
            rt.stats.inc("real_eval_attempts",1)
            if success: rt.stats.inc("real_eval_successes",1)
            log_real_episode(EVAL_EPISODES, mode + ":" + lp.name, success, elapsed, len(episode_steps), total_reward, mem.best_response, rt)
            rt.stats.save()
        time.sleep(rt.classic_cfg.restart_wait_seconds)

    if learning and real_buffer:
        print(f"Remaining {len(real_buffer)} real transitions kept untrained to avoid a tiny unstable PPO tail.")
    rt.save()
    classic.restore_console(console)
    if type_batch:
        print("REAL lock-type batch: " + " | ".join(f"{k} {v[1]}/{v[0]}={100*v[1]/max(1,v[0]):.1f}%" for k,v in type_batch.items()))
    if not learning:
        print(f"Evaluation mutation check: {before_hash[:12]} -> {rt.model_hash()[:12]} | {'PASS' if before_hash==rt.model_hash() else 'FAIL'}")

def real_evaluate_prompt(rt: SmartRuntime) -> None:
    raw=input("How many deterministic REAL attempts? [25]: ").strip()
    try: n=int(raw) if raw else 25
    except Exception: n=25
    n=max(1,min(5000,n))
    before_s=int(rt.stats.data.get("real_eval_successes",0) or 0); before_a=int(rt.stats.data.get("real_eval_attempts",0) or 0)
    live_run(rt, learning=False, max_attempts=n)
    da=int(rt.stats.data.get("real_eval_attempts",0) or 0)-before_a; ds=int(rt.stats.data.get("real_eval_successes",0) or 0)-before_s
    if da:
        rate=ds/da
        print(f"REAL deterministic batch: {ds}/{da} = {100*rate:.1f}%")
        best=float(rt.stats.data.get("real_best_eval_rate",0.0) or 0.0)
        if da>=10 and rate>best:
            rt.stats.data["real_best_eval_rate"]=rate; rt.stats.save(); rt.save(BEST_REAL_CKPT)
            print("New best REAL checkpoint saved.")


def restore_best(rt: SmartRuntime) -> None:
    options=[]
    if BEST_REAL_CKPT.exists(): options.append((BEST_REAL_CKPT,"best REAL"))
    if BEST_SIM_CKPT.exists(): options.append((BEST_SIM_CKPT,"best SIM"))
    if not options:
        print("No best SMART checkpoint yet."); return
    for i,(p,l) in enumerate(options,1): print(f"{i}) {l}: {p.name}")
    raw=input("Select [1]: ").strip()
    try: idx=max(1,min(len(options),int(raw) if raw else 1))-1
    except Exception: idx=0
    p,l=options[idx]
    try:
        ck=torch.load(p,map_location=rt.device); rt.net.load_state_dict(ck["state_dict"]); rt.optimizer=torch.optim.Adam(rt.net.parameters(),lr=rt.cfg.ppo_lr,eps=1e-5); rt.save(); print(f"Restored {l} | hash={rt.model_hash()[:12]}")
    except Exception as exc: print(f"Restore failed: {exc}")


def smart_verify(rt: SmartRuntime) -> None:
    print("\n=== SMART VERIFY ===")
    h0=rt.model_hash(); rt.save(); ck=torch.load(LATEST_CKPT,map_location=rt.device)
    clone=SmartActorCritic(rt.cfg).to(rt.device); clone.load_state_dict(ck["state_dict"])
    def hash_net(net):
        h=hashlib.sha256()
        for n,t in sorted(net.state_dict().items()):
            h.update(n.encode("utf-8"))
            a=t.detach().cpu().contiguous().numpy()
            h.update(str(a.shape).encode("ascii"))
            h.update(a.tobytes())
        return h.hexdigest()
    print(f"Checkpoint persistence: {'PASS' if hash_net(clone)==h0 else 'FAIL'}")
    mem=SmartMemory(); obs=obs_from_memory(mem, max(2.5,rt.profile.episode_budget_median), rt.profile.meaningful_response, len(rt.cfg.hold_ms), rt.cfg)
    a1=policy_action(rt,obs,True); a2=policy_action(rt,obs,True)
    print(f"Deterministic repeatability: {'PASS' if (abs(a1[0]-a2[0])<1e-9 and a1[1]==a2[1]) else 'FAIL'} | unit={a1[0]:.3f} hold={rt.cfg.hold_ms[a1[1]]}ms")
    target,low,high,phase=unit_to_target(a1[0],mem,rt.profile.meaningful_response,rt.cfg)
    print(f"Initial search bound: phase={phase} target={target:.3f} range=[{low:.3f},{high:.3f}] (full-range continuous target, no ±0.12 cap)")
    # Memory regression check from the exact v0.7 failure mode.
    mem.pos=0.30; mem.response=0.02; mem.prev_response=0.90; mem.best_response=0.94; mem.best_pos=0.28; mem.best_known=True; mem.furthest_pos=0.30
    _t,_l,_h,ph=unit_to_target(0.5,mem,rt.profile.meaningful_response,rt.cfg)
    print(f"Best-position recovery memory: {'PASS' if ph=='RECOVER' and _l<=mem.best_pos<=_h else 'FAIL'} | best={mem.best_pos:.3f} allowed=[{_l:.3f},{_h:.3f}]")
    print(f"Observation memory: {OBS_DIM} features = core/history/best-position + {BELIEF_BINS}-bin belief map")
    print(f"HOLD-TO-90 simulator guardrails: Rusted/L0={max(10.0,rt.cfg.sim_rusted_time_limit_sec):.2f}s | player={max(3.0,rt.cfg.sim_virtual_time_limit_sec):.2f}s | probe cap=NONE")
    rp, rt_total = lock_type_reference_selftest(rt)
    print(f"Lock-type reference self-test: {'PASS' if rt_total==4 and rp==4 else 'FAIL'} | {rp}/{rt_total} refs classify as themselves")
    print(f"Live profiles: Rusted={rt.cfg.rusted_budget_sec:.1f}s scan=100%, player={max(rt.cfg.player_budget_sec,rt.classic_cfg.attempt_budget_seconds):.1f}s scan<=50% | probe cap=NONE")
    print(f"Human demos currently include {len(sorted((DATA_DIR/'demos').glob('demo_*.csv')))} master file(s).")
    print("VERIFY proves wiring/memory/checkpoint behavior. Real skill is proven only by deterministic REAL EVALUATE.")


def stats(rt: SmartRuntime) -> None:
    d=rt.stats.data
    print("\n=== SMART STATS ===")
    print(f"device={rt.device} | parameters={sum(p.numel() for p in rt.net.parameters()):,} | obs={OBS_DIM} (belief={BELIEF_BINS})")
    print(f"hash={rt.model_hash()[:16]}")
    print(f"human BC runs={int(d.get('human_bc_runs',0) or 0)} samples={int(d.get('human_samples',0) or 0)}")
    print(f"SIM PPO updates={int(d.get('sim_ppo_updates',0) or 0)} transitions={int(d.get('sim_transitions',0) or 0):,} curriculum={int(d.get('sim_curriculum_level',0) or 0)}/{rt.cfg.sim_curriculum_max}")
    print(f"SIM best deterministic={100*float(d.get('sim_best_eval_rate',0.0) or 0.0):.1f}%")
    ta=int(d.get('real_train_attempts',0) or 0); ts=int(d.get('real_train_successes',0) or 0); ea=int(d.get('real_eval_attempts',0) or 0); es=int(d.get('real_eval_successes',0) or 0)
    print(f"REAL train={ts}/{ta} ({100*ts/max(1,ta):.1f}%) | real PPO={int(d.get('real_ppo_updates',0) or 0)}")
    print(f"REAL eval ={es}/{ea} ({100*es/max(1,ea):.1f}%) | best batch={100*float(d.get('real_best_eval_rate',0.0) or 0.0):.1f}%")
    p=rt.profile
    print(f"profile meaningful={p.meaningful_response:.3f} ramp~{p.ramp_width_median:.3f} target~{p.target_width_median:.3f}")
    print(f"HOLD-TO-90 SIM rules: Rusted/L0={max(10.0,rt.cfg.sim_rusted_time_limit_sec):.2f}s | player={max(3.0,rt.cfg.sim_virtual_time_limit_sec):.2f}s | probe cap=NONE | target requires enough F hold to reach {100*rt.cfg.sim_success_rotation:.1f}% (~90 deg)")
    print(f"entropy coef now={current_entropy_coef(rt):.5f}")


def reset_smart(rt: SmartRuntime) -> bool:
    ans=input("Reset ONLY the v0.16.3 SMART neural model/checkpoints? Human demos and classic data stay. Type RESET: ").strip()
    if ans!="RESET": print("Cancelled."); return False
    for p in (LATEST_CKPT,BEST_SIM_CKPT,BEST_REAL_CKPT,INITIAL_CKPT,STATS_PATH):
        try:
            if p.exists(): p.unlink()
        except Exception: pass
    print("SMART model reset. Restart program."); return True


def print_menu(rt: SmartRuntime) -> None:
    print("\n============================================================")
    print(" LOCKPICK LEARNER v0.16.3 - SAFE SIM GEOMETRY + SUCCESS ROI + MICRO FINISH")
    print("============================================================")
    print("1) SMART HUMAN TEACH  - exact F timing + first move + wins/fails -> auto pretrain")
    print("2) PRETRAIN ALL HUMAN - rebuild neural policy from every demo")
    print("3) FIT SIM PROFILE    - learn simulator noise/ramp timing statistics from demos")
    print("4) ULTRA SIM TRAIN    - headless HOLD-TO-90 PPO; Rusted 10s / player 3s; no fake probe cap")
    print("5) REAL TRAIN         - autonomous live play + small on-policy real adaptation")
    print("6) REAL EVALUATE      - deterministic, learning OFF (actual skill benchmark)")
    print("7) VERIFY SMART")
    print("8) SMART STATS")
    print("9) CALIBRATE")
    print("10) VISION DEBUG")
    print("11) RESTORE BEST")
    print("12) START v0.7 FAST MENU")
    print("13) RESET SMART MODEL")
    print("14) EXIT")
    print("15) HOLD 2D SIM      - play hidden ramp/target + F-hold simulator yourself")
    print("16) HOLD AGENT WATCH - watch neural policy learn position + F hold")
    print("17) HOLD DEBUG SIM   - reveal hidden ramp/target for developer inspection only")
    print("18) LOCK TYPE DEBUG  - reference classifier only; no F/Space/mouse input")
    print(
        f"hash={rt.model_hash()[:12]} | device={rt.device} | SIM={int(rt.stats.data.get('sim_ppo_updates',0) or 0)} "
        f"REAL={int(rt.stats.data.get('real_ppo_updates',0) or 0)} | BC={int(rt.stats.data.get('human_bc_runs',0) or 0)}"
    )


def main() -> None:
    cfg=SmartConfig.load(); set_seeds(cfg.seed)
    classic_cfg=classic.Config.load()
    # v0.13 could leave injected F12/F10 logically held in Windows. Clear that
    # stale state once at program startup so REAL EVALUATE can arm normally.
    classic.reset_live_hotkeys(classic_cfg, verbose=True)
    rt=SmartRuntime(classic_cfg,cfg)
    if rt.profile.source_files == 0:
        fit_sim_profile(rt, verbose=False)
    print(f"PyTorch device: {rt.device} | torch={torch.__version__}")
    if rt.device.type=="cuda":
        try: print(f"GPU: {torch.cuda.get_device_name(rt.device)}")
        except Exception: pass
    else:
        print("CPU mode: simulator is vectorized; GPU is optional. Live CV is usually the bottleneck.")
    if "--lock-type-debug" in sys.argv:
        lock_type_debug(rt)
        return
    while True:
        print_menu(rt)
        ch=input("Select: ").strip()
        try:
            if ch=="1": smart_human_teach(rt)
            elif ch=="2": human_pretrain(rt)
            elif ch=="3": fit_sim_profile(rt,verbose=True)
            elif ch=="4": ultra_sim_train(rt)
            elif ch=="5": live_run(rt,learning=True,max_attempts=None)
            elif ch=="6": real_evaluate_prompt(rt)
            elif ch=="7": smart_verify(rt)
            elif ch=="8": stats(rt)
            elif ch=="9":
                # Reuse robust v0.7/classic calibration path.
                vision,console,_h=classic.prepare_live_vision(rt.classic_cfg,rt.calibration_model,minimize=True)
                classic.auto_calibrate(rt.classic_cfg,rt.calibration_model,vision); classic.restore_console(console)
            elif ch=="10": classic.vision_debug(rt.classic_cfg,rt.calibration_model)
            elif ch=="11": restore_best(rt)
            elif ch=="12":
                import neural_lockpick_fast as fast
                fast.main()
            elif ch=="13":
                if reset_smart(rt): return
            elif ch=="14": rt.save(); return
            elif ch=="15":
                import lockpick_pdf_simulator as pdfsim
                pdfsim.PdfSimWindow(rt, "human", False, 999999, 1.0, 2).run()
            elif ch=="16":
                import lockpick_pdf_simulator as pdfsim
                pdfsim.PdfSimWindow(rt, "agent", False, 30, 8.0, 2).run()
            elif ch=="17":
                import lockpick_pdf_simulator as pdfsim
                pdfsim.PdfSimWindow(rt, "human", True, 999999, 1.0, 2).run()
            elif ch=="18": lock_type_debug(rt)
        except KeyboardInterrupt:
            print("\nInterrupted; saving SMART checkpoint."); rt.save()
        except Exception as exc:
            print(f"\n[ERROR] {type(exc).__name__}: {exc}")


if __name__ == "__main__":
    main()
