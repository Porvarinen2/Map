from __future__ import annotations

import argparse
import copy
import ctypes
import gc
import json
import math
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

_LOGICAL = os.cpu_count() or 8
os.environ.setdefault("OMP_NUM_THREADS", str(_LOGICAL))
os.environ.setdefault("MKL_NUM_THREADS", str(_LOGICAL))
os.environ.setdefault("NUMEXPR_NUM_THREADS", str(_LOGICAL))
os.environ.setdefault("OMP_WAIT_POLICY", "ACTIVE")
os.environ.setdefault("MKL_DYNAMIC", "FALSE")
os.environ.setdefault("KMP_BLOCKTIME", "0")

import numpy as np
import torch
import torch.nn.functional as F

import neural_lockpick_smart as smart

ROOT = Path(__file__).resolve().parent
MAX_CHAMPION = smart.SMART_DIR / "smart_max_champion.pt"
PREBOOT_CHAMPION = smart.SMART_DIR / "smart_preboot_champion.pt"
SKILL_DIR = smart.SMART_DIR / "skill_champions_v012"
SKILL_STATE = smart.SMART_DIR / "skill_matrix_v012.json"
PERSIST_ELITE = smart.SMART_DIR / "elite_skill_replay_v012.npz"
LEGACY_ELITE = smart.SMART_DIR / "elite_champion_bank.npz"
MAX_LOG = smart.AUDIT_DIR / "max_offline_train_v012.csv"
SKILL_LOG = smart.AUDIT_DIR / "skill_matrix_v012.csv"
NIGHT_STATE = smart.AUDIT_DIR / "night_evolution_v0164.json"
NIGHT_CANDIDATE = smart.SMART_DIR / "_night_candidate_v0164.pt"
SKILL_DIR.mkdir(parents=True, exist_ok=True)

LEVELS = 5
ZONES = 3
SKILLS = LEVELS * ZONES
ZONE_NAMES = ("LEFT", "MID", "RIGHT")
TRAINER_VERSION = "0.16.4"


@dataclass
class ResourcePlan:
    logical_cores: int
    ram_gb: float
    torch_threads: int
    interop_threads: int
    sim_envs: int
    rollout_steps: int
    ppo_minibatch: int
    ppo_epochs: int
    teacher_fresh_transitions: int
    teacher_existing_transitions: int
    eval_episodes_per_skill: int
    replay_ram_gb: float
    estimated_rollout_gb: float


def total_ram_bytes() -> int:
    if os.name == "nt":
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]
        st = MEMORYSTATUSEX(); st.dwLength = ctypes.sizeof(st)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
            return int(st.ullTotalPhys)
    try:
        return int(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE"))
    except Exception:
        return 16 * 1024**3


def set_aggressive_priority_and_affinity(cores: int) -> Tuple[bool, bool]:
    if os.name != "nt":
        try:
            os.nice(-5)
        except Exception:
            pass
        try:
            os.sched_setaffinity(0, set(range(cores)))
            return False, True
        except Exception:
            return False, False
    pri = False; aff = False
    try:
        k32 = ctypes.windll.kernel32
        proc = k32.GetCurrentProcess()
        # HIGH_PRIORITY_CLASS (not REALTIME: we do not want to freeze Windows/input).
        pri = bool(k32.SetPriorityClass(proc, 0x80))
        if cores <= 64:
            mask = (1 << cores) - 1
            aff = bool(k32.SetProcessAffinityMask(proc, ctypes.c_size_t(mask)))
    except Exception:
        pass
    return pri, aff


def base_plan() -> ResourcePlan:
    cores = max(2, os.cpu_count() or 8)
    ram_gb = total_ram_bytes() / 1024**3
    if ram_gb >= 128 and cores >= 24:
        envs = 32768
    elif ram_gb >= 64 and cores >= 16:
        envs = 16384
    elif ram_gb >= 32 and cores >= 12:
        envs = 8192
    elif ram_gb >= 16 and cores >= 8:
        envs = 4096
    else:
        envs = 2048
    # Replay RAM is deliberate continual-learning memory, not pointless padding.
    replay_gb = min(32.0, max(0.75, ram_gb * (0.16 if ram_gb >= 64 else 0.08)))
    rollout = int(np.clip(round(2_200_000 / envs), 32, 96))
    mb = int(min(65536, max(8192, envs)))
    rollout_bytes = rollout * envs * smart.OBS_DIM * 4
    est = rollout_bytes * 3.25 / 1024**3
    return ResourcePlan(
        logical_cores=cores, ram_gb=ram_gb,
        torch_threads=cores, interop_threads=max(1, min(2, cores // 16)),
        sim_envs=envs, rollout_steps=rollout, ppo_minibatch=mb, ppo_epochs=2,
        teacher_fresh_transitions=10_000_000 if ram_gb >= 64 else 4_000_000,
        teacher_existing_transitions=800_000 if ram_gb >= 64 else 300_000,
        eval_episodes_per_skill=512 if cores >= 16 else 256,
        replay_ram_gb=replay_gb, estimated_rollout_gb=est,
    )


def apply_plan(rt: smart.SmartRuntime, plan: ResourcePlan) -> None:
    try: torch.set_num_threads(plan.torch_threads)
    except Exception: pass
    try: torch.set_num_interop_threads(plan.interop_threads)
    except Exception: pass
    try: torch.set_float32_matmul_precision("high")
    except Exception: pass
    try: torch.set_flush_denormal(True)
    except Exception: pass
    try: torch.backends.mkldnn.enabled = True
    except Exception: pass
    c = rt.cfg
    c.sim_envs = int(plan.sim_envs)
    c.sim_rollout_steps = int(plan.rollout_steps)
    c.ppo_minibatch = int(plan.ppo_minibatch)
    c.ppo_epochs = int(plan.ppo_epochs)
    c.ppo_lr = min(max(c.ppo_min_lr, c.ppo_lr), 5.0e-5)
    c.ppo_clip = min(c.ppo_clip, 0.08)
    c.ppo_value_coef = min(c.ppo_value_coef, 0.35)
    c.ppo_entropy_coef = min(c.ppo_entropy_coef, 0.0030)
    c.ppo_entropy_min = min(c.ppo_entropy_min, 0.0006)
    c.ppo_entropy_decay = max(c.ppo_entropy_decay, 0.992)
    c.ppo_max_grad_norm = min(c.ppo_max_grad_norm, 0.45)
    c.ppo_target_kl = min(c.ppo_target_kl, 0.004)
    c.ppo_hard_kl = min(c.ppo_hard_kl, 0.007)
    c.ppo_reward_scale = 0.05
    c.ppo_adv_clip = min(c.ppo_adv_clip, 6.0)
    c.ppo_champion_anchor_coef = max(c.ppo_champion_anchor_coef, 0.20)
    c.ppo_champion_anchor_hard_kl = min(c.ppo_champion_anchor_hard_kl, 0.040)
    # Larger balanced replay minibatch: uses RAM to actively prevent forgetting.
    c.ppo_elite_coef = max(c.ppo_elite_coef, 0.075)
    c.ppo_elite_batch = max(c.ppo_elite_batch, min(8192, plan.ppo_minibatch // 4))
    rt.optimizer = torch.optim.Adam(rt.net.parameters(), lr=c.ppo_lr, eps=1e-5)


def checkpoint_load(rt: smart.SmartRuntime, path: Path) -> bool:
    if not path.exists():
        return False
    try:
        ck = torch.load(path, map_location=rt.device)
        rt.net.load_state_dict(ck["state_dict"])
        rt.optimizer = torch.optim.Adam(rt.net.parameters(), lr=rt.cfg.ppo_lr, eps=1e-5)
        rt.net.eval(); rt.save()
        return True
    except Exception as exc:
        print(f"[WARN] checkpoint restore failed: {exc}")
        return False


def set_champion_anchor(rt: smart.SmartRuntime) -> None:
    anchor = copy.deepcopy(rt.net).to(rt.device)
    anchor.eval()
    for p in anchor.parameters():
        p.requires_grad_(False)
    rt.ppo_anchor_net = anchor


def skill_name(skill_id: int) -> str:
    return f"L{skill_id // 3}-{ZONE_NAMES[skill_id % 3]}"


def score_skill_matrix(rates: np.ndarray) -> Dict[str, object]:
    rates = np.asarray(rates, dtype=np.float64).reshape(SKILLS)
    level_means = rates.reshape(LEVELS, ZONES).mean(axis=1)
    level_weights = np.asarray([1.00, 1.15, 1.40, 1.80, 2.35], dtype=np.float64)
    weighted = float(np.dot(level_means, level_weights / level_weights.sum()))
    hard_mean = float(level_means[-2:].mean())
    p10 = float(np.quantile(rates, 0.10))
    worst = float(rates.min())
    # Robust objective: no single random bucket can veto all learning, but hard
    # levels and the lower tail matter materially.
    score = 0.70 * weighted + 0.20 * hard_mean + 0.10 * p10
    return {"score": score, "weighted": weighted, "hard_mean": hard_mean,
            "p10": p10, "worst": worst, "level_means": level_means}


def eval_one_skill(rt: smart.SmartRuntime, skill_id: int, episodes: int,
                   seed_base: int = 910_000) -> float:
    probs = np.zeros(SKILLS, dtype=np.float64); probs[skill_id] = 1.0
    n = min(max(64, rt.cfg.sim_envs // 8), episodes)
    env = smart.VectorLockSim(rt, n, curriculum_level=skill_id // 3,
                              seed_offset=int(seed_base) + skill_id * 10_007,
                              skill_probs=probs)
    completed = 0; successes = 0; guard = 0
    while completed < episodes:
        obs = env.obs()
        act, hold, _lp, _v = smart.sim_policy_batch(rt, obs, deterministic=True)
        _next, _rew, done, info = env.step(act, hold)
        d = done.astype(bool)
        if d.any():
            take = min(int(d.sum()), episodes - completed)
            idx = np.where(d)[0][:take]
            completed += take
            successes += int(info["success"][idx].sum())
        guard += n
        if guard > episodes * rt.cfg.sim_max_steps * 5:
            break
    return successes / max(1, completed)


def eval_skill_matrix(rt: smart.SmartRuntime, episodes_each: int,
                      seed_base: int = 910_000) -> Tuple[np.ndarray, Dict[str, object]]:
    rates = np.zeros(SKILLS, dtype=np.float64)
    rt.net.eval()
    for sid in range(SKILLS):
        rates[sid] = eval_one_skill(rt, sid, episodes_each, seed_base=seed_base)
    return rates, score_skill_matrix(rates)


def matrix_text(rates: np.ndarray) -> str:
    m = np.asarray(rates).reshape(LEVELS, ZONES)
    return " | ".join(f"L{l}:{100*m[l].mean():4.1f}%[{100*m[l,0]:.0f}/{100*m[l,1]:.0f}/{100*m[l,2]:.0f}]" for l in range(LEVELS))


def load_skill_state(champion_rates: np.ndarray) -> Tuple[np.ndarray, List[str]]:
    best = np.asarray(champion_rates, dtype=np.float64).copy()
    hashes = [""] * SKILLS
    if SKILL_STATE.exists():
        try:
            raw = json.loads(SKILL_STATE.read_text(encoding="utf-8"))
            gv = int(raw.get("geometry_version", -1))
            if gv != int(smart.SIM_GEOMETRY_VERSION):
                print(f"[GEOMETRY GUARD] ignoring legacy per-skill scores from geometry v{gv}; current={smart.SIM_GEOMETRY_VERSION}")
                return best, hashes
            old = np.asarray(raw.get("best_rates", []), dtype=np.float64)
            if old.shape == (SKILLS,):
                best = np.maximum(best, old)
            hh = raw.get("hashes", [])
            if isinstance(hh, list) and len(hh) == SKILLS:
                hashes = [str(x) for x in hh]
        except Exception:
            pass
    return best, hashes


def save_skill_state(best_rates: np.ndarray, hashes: Sequence[str]) -> None:
    obj = {"version": 12, "geometry_version": int(smart.SIM_GEOMETRY_VERSION), "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
           "best_rates": [float(x) for x in best_rates], "hashes": list(hashes)}
    tmp = SKILL_STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8")
    tmp.replace(SKILL_STATE)


def archive_skill_improvements(rt: smart.SmartRuntime, rates: np.ndarray,
                               skill_best: np.ndarray, skill_hashes: List[str],
                               margin: float = 0.005) -> List[int]:
    improved = np.where(rates > skill_best + margin)[0].tolist()
    if not improved:
        return []
    h = rt.model_hash()
    for sid in improved:
        path = SKILL_DIR / f"skill_{sid:02d}_{skill_name(sid)}.pt"
        rt.save(path, optimizer=False)
        skill_best[sid] = float(rates[sid])
        skill_hashes[sid] = h
    save_skill_state(skill_best, skill_hashes)
    return improved


def adaptive_skill_probs(champion_rates: np.ndarray, skill_best: np.ndarray) -> np.ndarray:
    r = np.clip(np.asarray(champion_rates, dtype=np.float64), 0.0, 1.0)
    sb = np.clip(np.asarray(skill_best, dtype=np.float64), 0.0, 1.0)
    deficit = np.power(np.maximum(0.02, 1.0 - r), 1.65)
    forgotten_gap = np.maximum(0.0, sb - r)
    difficulty = np.repeat(np.asarray([1.00, 1.10, 1.25, 1.48, 1.80]), ZONES)
    priority = difficulty * (deficit + 2.5 * forgotten_gap)
    priority /= max(1e-12, priority.sum())
    # 22% uniform rehearsal means a mastered skill is never dropped from training.
    return 0.22 * (np.ones(SKILLS) / SKILLS) + 0.78 * priority


def frontier_skill_probs(champion_rates: np.ndarray, skill_best: np.ndarray,
                         mode: str = "frontier") -> np.ndarray:
    """Plateau curriculum that emphasizes *learnable* weak skills.

    Pure deficit weighting can spend an entire night hammering a near-impossible
    bucket.  The frontier distribution instead favors skills around the current
    learning boundary while still rehearsing every skill.  ``novelty`` is a bit
    more adventurous and gives extra probability to buckets that have a useful
    specialist gap or are currently under-mastered.
    """
    r = np.clip(np.asarray(champion_rates, dtype=np.float64), 0.0, 1.0)
    sb = np.clip(np.asarray(skill_best, dtype=np.float64), 0.0, 1.0)
    gap = np.maximum(0.0, sb - r)
    difficulty = np.repeat(np.asarray([0.95, 1.05, 1.20, 1.42, 1.62]), ZONES)

    # Peak around 35-45% success: hard enough to teach something, but not so
    # impossible that all rollouts are sparse-reward failures.
    frontier = np.exp(-0.5 * ((r - 0.40) / 0.24) ** 2)
    deficit = np.power(np.maximum(0.03, 1.0 - r), 1.15)
    if mode == "novelty":
        priority = difficulty * (0.65 * frontier + 0.55 * deficit + 4.0 * gap)
        uniform_mix = 0.12
    elif mode == "hard":
        priority = difficulty * (0.35 * frontier + 0.90 * deficit + 3.0 * gap)
        uniform_mix = 0.16
    else:
        priority = difficulty * (0.85 * frontier + 0.35 * deficit + 3.0 * gap)
        uniform_mix = 0.16
    priority = np.maximum(priority, 1e-9)
    priority /= priority.sum()
    return uniform_mix * (np.ones(SKILLS) / SKILLS) + (1.0 - uniform_mix) * priority


def set_optimizer_lr(rt: smart.SmartRuntime, lr: float) -> None:
    rt.cfg.ppo_lr = float(np.clip(lr, rt.cfg.ppo_min_lr, rt.cfg.ppo_max_lr))
    for group in rt.optimizer.param_groups:
        group["lr"] = rt.cfg.ppo_lr


def save_ppo_knobs(rt: smart.SmartRuntime) -> Dict[str, float]:
    keys = (
        "ppo_lr", "ppo_clip", "ppo_entropy_coef", "ppo_entropy_min",
        "ppo_champion_anchor_coef", "ppo_target_kl", "ppo_hard_kl",
        "ppo_elite_coef", "ppo_epochs",
    )
    return {k: float(getattr(rt.cfg, k)) for k in keys}


def restore_ppo_knobs(rt: smart.SmartRuntime, knobs: Dict[str, float]) -> None:
    for k, v in knobs.items():
        if k == "ppo_epochs":
            setattr(rt.cfg, k, int(round(v)))
        else:
            setattr(rt.cfg, k, float(v))
    set_optimizer_lr(rt, float(knobs["ppo_lr"]))


def apply_explore_knobs(rt: smart.SmartRuntime, style: str) -> None:
    """Temporarily widen exploration while hard KL rollback remains active."""
    if style == "bold":
        set_optimizer_lr(rt, min(rt.cfg.ppo_max_lr, 5.4e-5))
        rt.cfg.ppo_clip = max(rt.cfg.ppo_clip, 0.105)
        rt.cfg.ppo_entropy_coef = max(rt.cfg.ppo_entropy_coef, 0.010)
        rt.cfg.ppo_entropy_min = max(rt.cfg.ppo_entropy_min, 0.0025)
        rt.cfg.ppo_champion_anchor_coef = min(rt.cfg.ppo_champion_anchor_coef, 0.10)
        rt.cfg.ppo_target_kl = min(max(rt.cfg.ppo_target_kl, 0.0040), rt.cfg.ppo_hard_kl * 0.80)
    elif style == "crossover":
        set_optimizer_lr(rt, min(rt.cfg.ppo_max_lr, 3.8e-5))
        rt.cfg.ppo_clip = max(rt.cfg.ppo_clip, 0.090)
        rt.cfg.ppo_entropy_coef = max(rt.cfg.ppo_entropy_coef, 0.0060)
        rt.cfg.ppo_entropy_min = max(rt.cfg.ppo_entropy_min, 0.0015)
        rt.cfg.ppo_champion_anchor_coef = max(0.14, min(rt.cfg.ppo_champion_anchor_coef, 0.18))
    else:  # frontier
        set_optimizer_lr(rt, min(rt.cfg.ppo_max_lr, 4.6e-5))
        rt.cfg.ppo_clip = max(rt.cfg.ppo_clip, 0.090)
        rt.cfg.ppo_entropy_coef = max(rt.cfg.ppo_entropy_coef, 0.0065)
        rt.cfg.ppo_entropy_min = max(rt.cfg.ppo_entropy_min, 0.0015)
        rt.cfg.ppo_champion_anchor_coef = min(rt.cfg.ppo_champion_anchor_coef, 0.16)


def mutate_actor_heads(rt: smart.SmartRuntime, strength: float, seed: int) -> None:
    """Small evolutionary mutation of action heads only; critic/body stay intact."""
    torch.manual_seed(int(seed) & 0x7FFFFFFF)
    with torch.no_grad():
        for name, p in rt.net.named_parameters():
            if not (name.startswith("beta_head") or name.startswith("hold_head")):
                continue
            rms = float(torch.sqrt(torch.mean(p.detach().float() ** 2)).item()) if p.numel() else 0.0
            sigma = max(8e-5, rms * float(strength))
            p.add_(torch.randn_like(p) * sigma)


def skill_checkpoint_path(skill_id: int) -> Path:
    return SKILL_DIR / f"skill_{skill_id:02d}_{skill_name(skill_id)}.pt"


def blend_specialist_actor(rt: smart.SmartRuntime, skill_id: int, alpha: float = 0.18) -> bool:
    """Cross over a small part of one specialist's actor into the global model."""
    path = skill_checkpoint_path(skill_id)
    if not path.exists():
        return False
    try:
        ck = torch.load(path, map_location=rt.device)
        ss = ck["state_dict"]
        cur = rt.net.state_dict()
        with torch.no_grad():
            for k in list(cur.keys()):
                if k.startswith("beta_head") or k.startswith("hold_head"):
                    cur[k].copy_((1.0 - alpha) * cur[k] + alpha * ss[k].to(cur[k].device))
        rt.net.load_state_dict(cur)
        return True
    except Exception as exc:
        print(f"[NIGHT] specialist crossover skipped: {exc}")
        return False


def holdout_gate(rt: smart.SmartRuntime, candidate_rates: np.ndarray,
                 candidate_meta: Dict[str, object], champ_rates: np.ndarray,
                 champ_meta: Dict[str, object], seed_base: int,
                 episodes_each: int) -> Tuple[bool, str]:
    """Require a fixed-eval improvement to survive a fresh unseen-seed check."""
    ok, why = accept_global(candidate_rates, candidate_meta, champ_rates, champ_meta)
    if not ok:
        return False, why
    rt.save(NIGHT_CANDIDATE, optimizer=False)
    checkpoint_load(rt, MAX_CHAMPION)
    hr_champ, hm_champ = eval_skill_matrix(rt, episodes_each, seed_base=seed_base)
    checkpoint_load(rt, NIGHT_CANDIDATE)
    hr_cand, hm_cand = eval_skill_matrix(rt, episodes_each, seed_base=seed_base)
    d = hr_cand - hr_champ
    hold_gain = float(hm_cand["score"]) - float(hm_champ["score"])
    severe = int((d < -0.12).sum())
    med = float(np.median(d))
    # Small negative noise is tolerated because this is a smaller holdout set,
    # but a candidate that only memorized the fixed gate does not become global.
    hold_ok = hold_gain >= -0.006 and severe == 0 and med >= -0.025
    return hold_ok, (why + f" holdout={100*hold_gain:+.2f}pt severe={severe} median={100*med:+.2f}")


def write_night_state(ch: int, score: float, plateau: int, escapes: int,
                      replay: "SkillReplayBank") -> None:
    try:
        obj = {
            "version": TRAINER_VERSION,
            "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
            "challenger": int(ch), "champion_score": float(score),
            "plateau_challengers": int(plateau), "escape_tournaments": int(escapes),
            "replay_added": int(replay.total_added),
            "geometry_version": int(smart.SIM_GEOMETRY_VERSION),
        }
        tmp = NIGHT_STATE.with_suffix(".tmp")
        tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8")
        tmp.replace(NIGHT_STATE)
    except Exception:
        pass


class SkillReplayBank:
    """Large RAM-resident continual-learning bank.

    All simulator transitions are retained in float16 rings (up to the configured
    RAM budget). Successful terminal tails are separately indexed and sampled in
    a balanced way across 15 skills. PPO remains on-policy; replay is used only
    as a behavior-preservation auxiliary loss, which avoids invalid off-policy PPO.
    """
    def __init__(self, ram_gb: float, seed: int):
        self.rng = np.random.default_rng(seed + 707)
        bytes_per = smart.OBS_DIM * 2 + 2 + 1 + 2 + 1  # obs, action, hold, reward, elite flag
        total_bytes = int(max(128 * 1024**2, ram_gb * 1024**3))
        total_cap = max(SKILLS * 4096, total_bytes // bytes_per)
        self.cap = max(4096, total_cap // SKILLS)
        # Elite index ring is capped independently; 500k/skill = 30 MB total.
        self.elite_cap = min(500_000, max(20_000, self.cap // 8))
        self.obs: List[np.ndarray] = []
        self.action: List[np.ndarray] = []
        self.hold: List[np.ndarray] = []
        self.reward: List[np.ndarray] = []
        self.elite: List[np.ndarray] = []
        self.pos = np.zeros(SKILLS, dtype=np.int64)
        self.size = np.zeros(SKILLS, dtype=np.int64)
        self.elite_pos = [np.empty(self.elite_cap, dtype=np.int32) for _ in range(SKILLS)]
        self.elite_ptr = np.zeros(SKILLS, dtype=np.int64)
        self.elite_size = np.zeros(SKILLS, dtype=np.int64)
        # np.empty reserves the intended RAM capacity. Physical pages are touched
        # as experience arrives, so startup is fast and we do not zero 20+ GiB.
        for _ in range(SKILLS):
            self.obs.append(np.empty((self.cap, smart.OBS_DIM), dtype=np.float16))
            self.action.append(np.empty(self.cap, dtype=np.float16))
            self.hold.append(np.empty(self.cap, dtype=np.uint8))
            self.reward.append(np.empty(self.cap, dtype=np.float16))
            self.elite.append(np.zeros(self.cap, dtype=np.uint8))
        self.bytes_per = bytes_per
        self.total_added = 0
        self.generic_obs = np.zeros((0, smart.OBS_DIM), np.float32)
        self.generic_action = np.zeros(0, np.float32)
        self.generic_hold = np.zeros(0, np.int64)
        # v0.16.3: anonymous legacy replay has no geometry/version metadata, so
        # it is deliberately not rehearsed after the player-domain/width fix.
        # Keeping it would silently re-teach trajectories from the invalid wide-ramp sim.
        if LEGACY_ELITE.exists():
            print("[GEOMETRY GUARD] legacy generic elite replay ignored (no geometry version metadata)")

    @property
    def capacity(self) -> int:
        return int(self.cap * SKILLS)

    def _write_skill(self, sid: int, obs: np.ndarray, action: np.ndarray, hold: np.ndarray,
                     reward: np.ndarray, elite: np.ndarray) -> None:
        count = len(action)
        if count == 0:
            return
        if count > self.cap:
            obs = obs[-self.cap:]; action = action[-self.cap:]; hold = hold[-self.cap:]
            reward = reward[-self.cap:]; elite = elite[-self.cap:]; count = self.cap
        p = int(self.pos[sid])
        first = min(count, self.cap - p)
        chunks = [(p, p + first, 0, first)]
        if first < count:
            chunks.append((0, count - first, first, count))
        for d0, d1, s0, s1 in chunks:
            self.obs[sid][d0:d1] = obs[s0:s1].astype(np.float16, copy=False)
            self.action[sid][d0:d1] = action[s0:s1].astype(np.float16, copy=False)
            self.hold[sid][d0:d1] = hold[s0:s1].astype(np.uint8, copy=False)
            self.reward[sid][d0:d1] = reward[s0:s1].astype(np.float16, copy=False)
            self.elite[sid][d0:d1] = elite[s0:s1].astype(np.uint8, copy=False)
            rel = np.where(elite[s0:s1])[0]
            if len(rel):
                dest = (d0 + rel).astype(np.int32)
                if len(dest) > self.elite_cap:
                    dest = dest[-self.elite_cap:]
                ep = int(self.elite_ptr[sid] % self.elite_cap)
                ef = min(len(dest), self.elite_cap - ep)
                self.elite_pos[sid][ep:ep+ef] = dest[:ef]
                if ef < len(dest):
                    self.elite_pos[sid][0:len(dest)-ef] = dest[ef:]
                self.elite_ptr[sid] += len(dest)
                self.elite_size[sid] = min(self.elite_cap, self.elite_size[sid] + len(dest))
        self.pos[sid] = (p + count) % self.cap
        self.size[sid] = min(self.cap, self.size[sid] + count)
        self.total_added += count

    def add_batch(self, batch: smart.PPOBatch) -> None:
        if not hasattr(batch, "skill") or not hasattr(batch, "success"):
            return
        success = np.asarray(batch.success, dtype=bool)
        elite = success.copy()
        # Mark terminal success plus up to four preceding steps in the same episode.
        frontier = success.copy()
        for _ in range(4):
            prev = np.zeros_like(frontier)
            prev[:-1] = frontier[1:] & (batch.done[:-1] < 0.5)
            elite |= prev
            frontier = prev
        skill = np.asarray(batch.skill, dtype=np.int16).reshape(-1)
        obs = batch.obs.reshape(-1, smart.OBS_DIM)
        action = batch.action.reshape(-1)
        hold = batch.hold.reshape(-1)
        reward = batch.reward.reshape(-1)
        elite_f = elite.reshape(-1)
        for sid in range(SKILLS):
            ix = np.where(skill == sid)[0]
            if len(ix):
                self._write_skill(sid, obs[ix], action[ix], hold[ix], reward[ix], elite_f[ix])

    def _valid_elite_positions(self, sid: int, want: int) -> np.ndarray:
        es = int(self.elite_size[sid])
        if es <= 0:
            return np.zeros(0, dtype=np.int32)
        raw = self.elite_pos[sid][:es] if int(self.elite_ptr[sid]) <= self.elite_cap else self.elite_pos[sid]
        if len(raw) == 0:
            return np.zeros(0, dtype=np.int32)
        take = min(max(want * 3, want), len(raw))
        ix = self.rng.integers(0, len(raw), size=take)
        pos = raw[ix]
        valid = pos[self.elite[sid][pos] > 0]
        if len(valid) > want:
            valid = valid[:want]
        return valid.astype(np.int32, copy=False)

    def sample_elite_balanced(self, n: int) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
        n = max(SKILLS, int(n))
        obs_parts=[]; act_parts=[]; hold_parts=[]
        each = int(math.ceil(n / SKILLS))
        for sid in range(SKILLS):
            pos = self._valid_elite_positions(sid, each)
            if len(pos):
                obs_parts.append(self.obs[sid][pos].astype(np.float32))
                act_parts.append(self.action[sid][pos].astype(np.float32))
                hold_parts.append(self.hold[sid][pos].astype(np.int64))
        if obs_parts:
            o=np.concatenate(obs_parts); a=np.concatenate(act_parts); h=np.concatenate(hold_parts)
        else:
            o=np.zeros((0, smart.OBS_DIM), np.float32); a=np.zeros(0, np.float32); h=np.zeros(0, np.int64)
        # Keep up to 20% of the old v0.11 immutable elite bank in every rehearsal
        # sample. Those successes remain useful even though they predate skill labels.
        if len(self.generic_obs):
            gn=min((n if len(o)==0 else max(1,n//5)),len(self.generic_obs))
            gi=self.rng.choice(len(self.generic_obs),gn,replace=False) if len(self.generic_obs)>gn else np.arange(len(self.generic_obs))
            o=np.concatenate([o,self.generic_obs[gi]],axis=0); a=np.concatenate([a,self.generic_action[gi]]); h=np.concatenate([h,self.generic_hold[gi]])
        if len(o)>n:
            ix=self.rng.choice(len(o),n,replace=False); o,a,h=o[ix],a[ix],h[ix]
        return o,a,h

    def seed_from_persisted(self) -> int:
        if not PERSIST_ELITE.exists():
            return 0
        try:
            z=np.load(PERSIST_ELITE)
            gv = int(np.asarray(z["geometry_version"]).reshape(-1)[0]) if "geometry_version" in z.files else -1
            if gv != int(smart.SIM_GEOMETRY_VERSION):
                print(f"[GEOMETRY GUARD] persisted replay ignored: geometry v{gv} != {smart.SIM_GEOMETRY_VERSION}")
                return 0
            o=z["obs"].astype(np.float32); a=z["action"].astype(np.float32); h=z["hold"].astype(np.int64); s=z["skill"].astype(np.int16)
            e=np.ones(len(a), dtype=bool); r=np.zeros(len(a), dtype=np.float32)
            for sid in range(SKILLS):
                ix=np.where(s==sid)[0]
                if len(ix): self._write_skill(sid,o[ix],a[ix],h[ix],r[ix],e[ix])
            return len(a)
        except Exception as exc:
            print(f"[WARN] persistent replay seed failed: {exc}")
            return 0

    def persist_elites(self, max_total: int = 450_000) -> int:
        o,a,h=self.sample_elite_balanced(max_total)
        if len(o)==0:
            return 0
        # Reconstruct skill labels by taking a fresh balanced sample per skill for persistence.
        obs_parts=[]; act_parts=[]; hold_parts=[]; skill_parts=[]
        each=max(1,max_total//SKILLS)
        for sid in range(SKILLS):
            pos=self._valid_elite_positions(sid,each)
            if len(pos):
                obs_parts.append(self.obs[sid][pos].astype(np.float16))
                act_parts.append(self.action[sid][pos].astype(np.float16))
                hold_parts.append(self.hold[sid][pos].astype(np.uint8))
                skill_parts.append(np.full(len(pos),sid,dtype=np.uint8))
        if not obs_parts: return 0
        oo=np.concatenate(obs_parts); aa=np.concatenate(act_parts); hh=np.concatenate(hold_parts); ss=np.concatenate(skill_parts)
        np.savez_compressed(PERSIST_ELITE,obs=oo,action=aa,hold=hh,skill=ss,
                            geometry_version=np.asarray([smart.SIM_GEOMETRY_VERSION],dtype=np.int32))
        return len(aa)

    def summary(self) -> str:
        used=int(self.size.sum()); elites=int(self.elite_size.sum())
        touched_gb=used*self.bytes_per/1024**3
        capacity_gb=self.capacity*self.bytes_per/1024**3
        return f"RAM replay={used:,}/{self.capacity:,} trans (~{touched_gb:.2f}/{capacity_gb:.1f} GiB data) elite-indexed={elites:,}"


def install_replay_elite(rt: smart.SmartRuntime, replay: SkillReplayBank, n: int = 180_000) -> int:
    o,a,h = replay.sample_elite_balanced(n)
    rt.ppo_elite_obs=o; rt.ppo_elite_action=a; rt.ppo_elite_hold=h
    return len(o)


def make_batch(rt: smart.SmartRuntime, skill_probs: np.ndarray, seed_offset: int) -> smart.PPOBatch:
    T,N=rt.cfg.sim_rollout_steps,rt.cfg.sim_envs
    env=smart.VectorLockSim(rt,N,curriculum_level=rt.cfg.sim_curriculum_max,seed_offset=seed_offset,skill_probs=skill_probs)
    b=smart.PPOBatch(T,N)
    b.skill=np.zeros((T,N),np.uint8)
    b.success=np.zeros((T,N),np.uint8)
    for t in range(T):
        obs=env.obs(); act,hold,logp,value=smart.sim_policy_batch(rt,obs,deterministic=False)
        _next,reward,done,info=env.step(act,hold)
        b.obs[t]=obs; b.action[t]=act; b.hold[t]=hold; b.logp[t]=logp; b.value[t]=value; b.reward[t]=reward; b.done[t]=done
        b.skill[t]=info["skill_id"].astype(np.uint8); b.success[t]=info["success"].astype(np.uint8)
    with torch.inference_mode():
        _a,_be,_h,v=rt.net(torch.as_tensor(env.obs(),dtype=torch.float32,device=rt.device))
        b.next_value=v.detach().cpu().numpy().astype(np.float32)
    return b


def targeted_teacher_distill(rt: smart.SmartRuntime, transitions_target: int, skill_probs: np.ndarray,
                              lr: float, label: str) -> Dict[str,float]:
    target=max(rt.cfg.sim_envs,int(transitions_target))
    opt=torch.optim.Adam(rt.net.parameters(),lr=lr,eps=1e-5)
    env=smart.VectorLockSim(rt,rt.cfg.sim_envs,curriculum_level=rt.cfg.sim_curriculum_max,
                            seed_offset=777_123,skill_probs=skill_probs)
    seen=0; losses=[]; t0=time.perf_counter(); rt.net.train(); report_every=20
    while seen<target:
        obs_np=env.obs(); target_abs,hold_np=smart.planner_targets_from_env(env,q=0.18); low,high,_=env.bounds()
        unit_np=np.clip((target_abs-low)/np.maximum(1e-6,high-low),1e-4,1-1e-4).astype(np.float32)
        weight_np=(1.0+3.5*env.best+1.5*(env.response>=env.threshold()).astype(np.float32)).astype(np.float32)
        obs=torch.as_tensor(obs_np,dtype=torch.float32,device=rt.device); act=torch.as_tensor(unit_np,dtype=torch.float32,device=rt.device)
        hold=torch.as_tensor(hold_np,dtype=torch.long,device=rt.device); w=torch.as_tensor(weight_np,dtype=torch.float32,device=rt.device)
        alpha,beta,hold_logits,_=rt.net(obs); bd=torch.distributions.Beta(alpha,beta)
        move_mse=(bd.mean-act)**2; move_nll=-bd.log_prob(act).clamp(-20.0,20.0); hold_ce=F.cross_entropy(hold_logits,hold,reduction="none")
        loss=((7.0*move_mse+0.06*move_nll+0.25*hold_ce)*w).sum()/torch.clamp(w.sum(),min=1.0)
        opt.zero_grad(set_to_none=True); loss.backward(); torch.nn.utils.clip_grad_norm_(rt.net.parameters(),rt.cfg.ppo_max_grad_norm); opt.step()
        losses.append(float(loss.item())); env.step(unit_np,hold_np); seen+=rt.cfg.sim_envs
        if len(losses)==1 or len(losses)%report_every==0:
            sps=seen/max(1e-6,time.perf_counter()-t0)
            print(f"{label}: {seen:,}/{target:,} | loss={losses[-1]:.4f} | {sps:,.0f}/s",end="\r")
    print(); rt.net.eval(); rt.optimizer=torch.optim.Adam(rt.net.parameters(),lr=rt.cfg.ppo_lr,eps=1e-5); rt.save()
    return {"transitions":float(seen),"loss":float(np.mean(losses)),"seconds":float(time.perf_counter()-t0)}


def replay_consolidate(rt: smart.SmartRuntime, replay: SkillReplayBank, samples: int = 260_000,
                       epochs: int = 2, lr: float = 1.5e-5) -> Dict[str,float]:
    o,a,h=replay.sample_elite_balanced(samples)
    if len(o)==0: return {"samples":0.0,"loss":0.0}
    obs=torch.as_tensor(o,dtype=torch.float32,device=rt.device); act=torch.as_tensor(np.clip(a,1e-4,1-1e-4),dtype=torch.float32,device=rt.device); hold=torch.as_tensor(h,dtype=torch.long,device=rt.device)
    opt=torch.optim.Adam(rt.net.parameters(),lr=lr,eps=1e-5); idx=np.arange(len(o)); losses=[]; bs=max(4096,min(rt.cfg.ppo_minibatch,len(o)))
    rt.net.train()
    for _ in range(max(1,epochs)):
        np.random.shuffle(idx)
        for s0 in range(0,len(idx),bs):
            m=torch.as_tensor(idx[s0:s0+bs],dtype=torch.long,device=rt.device)
            alpha,beta,hl,_=rt.net(obs[m]); bd=torch.distributions.Beta(alpha,beta)
            mse=(bd.mean-act[m]).pow(2).mean(); nll=-bd.log_prob(act[m]).clamp(-20,20).mean(); ce=F.cross_entropy(hl,hold[m])
            loss=6.0*mse+0.04*nll+0.22*ce
            opt.zero_grad(set_to_none=True); loss.backward(); torch.nn.utils.clip_grad_norm_(rt.net.parameters(),0.40); opt.step(); losses.append(float(loss.item()))
    rt.net.eval(); rt.optimizer=torch.optim.Adam(rt.net.parameters(),lr=rt.cfg.ppo_lr,eps=1e-5); rt.save()
    return {"samples":float(len(o)),"loss":float(np.mean(losses) if losses else 0.0)}


def accept_global(candidate_rates: np.ndarray, candidate_meta: Dict[str,object], champ_rates: np.ndarray,
                  champ_meta: Dict[str,object]) -> Tuple[bool,str]:
    delta=np.asarray(candidate_rates)-np.asarray(champ_rates)
    score_gain=float(candidate_meta["score"])-float(champ_meta["score"])
    moderate=int((delta < -0.050).sum())
    severe=int((delta < -0.120).sum())
    median_delta=float(np.median(delta))
    l4_delta=float(np.mean(candidate_rates[12:15])-np.mean(champ_rates[12:15]))
    # One small bucket regression no longer vetoes the whole challenger. A true
    # collapse (>12 points in any skill), however, stays out of the global model
    # and its useful gains live in the specialist/replay bank instead.
    ok=(score_gain>0.0004 and severe==0 and moderate<=2 and median_delta>=-0.012 and l4_delta>=-0.025)
    why=f"gain={100*score_gain:+.2f}pt moderate={moderate} severe={severe} median={100*median_delta:+.2f} L4={100*l4_delta:+.2f}"
    return ok,why


def autotune_envs(rt: smart.SmartRuntime, plan: ResourcePlan) -> ResourcePlan:
    # Throughput, not a vanity env count, decides the parallelism. Choose the
    # largest count that is within 97% of the measured best to keep CPU saturated.
    base=plan.sim_envs
    candidates=sorted(set(int(x) for x in [max(2048,base//2),base,min(65536,base*2)]))
    if plan.ram_gb<32: candidates=[x for x in candidates if x<=8192]
    uniform=np.ones(SKILLS,dtype=np.float64)/SKILLS
    results=[]
    old_envs=rt.cfg.sim_envs
    print("CPU throughput autotune:")
    for n in candidates:
        try:
            env=smart.VectorLockSim(rt,n,curriculum_level=4,seed_offset=661+n,skill_probs=uniform)
            # warmup
            obs=env.obs(); a,h,_lp,_v=smart.sim_policy_batch(rt,obs,deterministic=True); env.step(a,h)
            t0=time.perf_counter(); steps=0
            for _ in range(3):
                obs=env.obs(); a,h,_lp,_v=smart.sim_policy_batch(rt,obs,deterministic=True); env.step(a,h); steps+=n
            sec=time.perf_counter()-t0; sps=steps/max(sec,1e-6); results.append((n,sps))
            print(f"  {n:>6,} envs -> {sps:>10,.0f} sim-policy steps/s")
            del env,obs,a,h; gc.collect()
        except MemoryError:
            print(f"  {n:>6,} envs -> memory limit")
    if not results:
        rt.cfg.sim_envs=old_envs; return plan
    best_sps=max(x[1] for x in results)
    eligible=[x for x in results if x[1]>=0.97*best_sps]
    chosen=max(eligible,key=lambda x:x[0])[0]
    plan.sim_envs=int(chosen)
    plan.rollout_steps=int(np.clip(round(2_200_000/chosen),32,96))
    plan.ppo_minibatch=int(min(65536,max(8192,chosen)))
    rollout_bytes=plan.rollout_steps*plan.sim_envs*smart.OBS_DIM*4
    plan.estimated_rollout_gb=rollout_bytes*3.25/1024**3
    apply_plan(rt,plan)
    print(f"  selected {chosen:,} envs x {plan.rollout_steps} steps = {chosen*plan.rollout_steps:,} transitions/challenger\n")
    return plan


def plateau_escape_tournament(rt: smart.SmartRuntime, plan: ResourcePlan,
                              replay: SkillReplayBank, champ_rates: np.ndarray,
                              champ_meta: Dict[str, object], skill_best: np.ndarray,
                              skill_hashes: List[str], escape_id: int,
                              challenger_id: int, use_holdout: bool) -> Tuple[np.ndarray, Dict[str, object], bool, int, int]:
    """Try several safe-but-diverse branches when ordinary PPO stalls.

    Every branch starts from the immutable global champion. Rejected branches may
    still contribute useful specialist checkpoints/replay, but can never overwrite
    the global model. This gives long overnight runs a mechanism to escape a local
    optimum instead of decaying LR forever.
    """
    print("\n[NIGHT ESCAPE] plateau detected -> evolutionary 3-branch tournament")
    base_knobs = save_ppo_knobs(rt)
    best_rates = np.asarray(champ_rates, dtype=np.float64).copy()
    best_meta = dict(champ_meta)
    best_state: Optional[Dict[str, torch.Tensor]] = None
    specialist_saves = 0
    escape_transitions = 0

    gap = np.maximum(0.0, np.asarray(skill_best) - np.asarray(champ_rates))
    existing = [sid for sid in np.argsort(-gap) if skill_checkpoint_path(int(sid)).exists()]
    crossover_sid = int(existing[0]) if existing else int(np.argmin(champ_rates))

    branches = [
        ("FRONTIER", "frontier", False, None),
        ("BOLD-NOVELTY", "bold", True, None),
        (f"CROSSOVER-{skill_name(crossover_sid)}", "crossover", False, crossover_sid if existing else None),
    ]

    for bi, (label, style, mutate, sid) in enumerate(branches, start=1):
        checkpoint_load(rt, MAX_CHAMPION)
        set_champion_anchor(rt)
        restore_ppo_knobs(rt, base_knobs)
        apply_explore_knobs(rt, style)
        if sid is not None:
            blended = blend_specialist_actor(rt, sid, alpha=0.18)
            if blended:
                print(f"[NIGHT ESCAPE {bi}/3] {label}: blended 18% actor-head specialist signal")
        if mutate:
            mutate_actor_heads(rt, strength=0.10, seed=990_000 + escape_id * 97 + challenger_id)
            print(f"[NIGHT ESCAPE {bi}/3] {label}: actor-head mutation + high entropy")
        else:
            print(f"[NIGHT ESCAPE {bi}/3] {label}: LR={rt.cfg.ppo_lr:.1e} entropy_floor={rt.cfg.ppo_entropy_min:.4f}")

        probs = frontier_skill_probs(champ_rates, skill_best,
                                     mode="novelty" if style == "bold" else "frontier")
        install_replay_elite(rt, replay, n=260_000)
        batch = make_batch(rt, probs, seed_offset=8_000_000 + escape_id * 400_003 + bi * 70_001)
        replay.add_batch(batch)
        escape_transitions += rt.cfg.sim_rollout_steps * rt.cfg.sim_envs
        install_replay_elite(rt, replay, n=280_000)
        metrics = smart.ppo_update(rt, batch, source="sim")
        if metrics.get("reverted", 0.0) > 0.5:
            print(f"[NIGHT ESCAPE {bi}/3] {label}: trust rollback ({metrics.get('stop_reason','')})")
            continue

        cr, cm = eval_skill_matrix(rt, plan.eval_episodes_per_skill)
        improved = archive_skill_improvements(rt, cr, skill_best, skill_hashes, margin=0.004)
        specialist_saves += len(improved)
        if use_holdout:
            ok, why = holdout_gate(rt, cr, cm, champ_rates, champ_meta,
                                   seed_base=5_000_000 + escape_id * 200_003 + bi * 31_337,
                                   episodes_each=max(96, plan.eval_episodes_per_skill // 4))
        else:
            ok, why = accept_global(cr, cm, champ_rates, champ_meta)
        print(f"[NIGHT ESCAPE {bi}/3] {label}: {matrix_text(cr)} | score={100*float(cm['score']):.2f}% | {why}")

        if ok and float(cm["score"]) > float(best_meta["score"]):
            best_state = {k: v.detach().cpu().clone() for k, v in rt.net.state_dict().items()}
            best_rates = cr.copy(); best_meta = dict(cm)

    restore_ppo_knobs(rt, base_knobs)
    if best_state is not None:
        rt.net.load_state_dict(best_state)
        rt.optimizer = torch.optim.Adam(rt.net.parameters(), lr=rt.cfg.ppo_lr, eps=1e-5)
        rt.net.eval(); rt.save()
        rt.save(MAX_CHAMPION)
        set_champion_anchor(rt)
        # Do not immediately collapse back to the tiny plateau LR. Give the new
        # basin a few normal challengers to develop.
        set_optimizer_lr(rt, min(rt.cfg.ppo_max_lr, max(3.8e-5, base_knobs["ppo_lr"])))
        print(f"[NIGHT ESCAPE ACCEPT] global -> {100*float(best_meta['score']):.2f}% | restart LR={rt.cfg.ppo_lr:.1e}\n")
        return best_rates, best_meta, True, specialist_saves, escape_transitions

    checkpoint_load(rt, MAX_CHAMPION)
    restore_ppo_knobs(rt, base_knobs)
    set_champion_anchor(rt)
    # Failed tournament still resets exploration pressure/LR for a new search
    # trajectory, while the immutable champion remains untouched.
    set_optimizer_lr(rt, min(rt.cfg.ppo_max_lr, max(3.6e-5, base_knobs["ppo_lr"])))
    rt.cfg.ppo_entropy_min = max(rt.cfg.ppo_entropy_min, 0.0010)
    print(f"[NIGHT ESCAPE MISS] champion unchanged; fresh search LR={rt.cfg.ppo_lr:.1e}\n")
    return champ_rates, champ_meta, False, specialist_saves, escape_transitions


def run(rt: smart.SmartRuntime, plan: ResourcePlan, minutes: float, skip_human: bool=False,
        no_autotune: bool=False, night_mode: bool=False) -> None:
    if not no_autotune:
        plan=autotune_envs(rt,plan)
    print("\n====================================================================")
    print(" LOCKPICK v0.16.4 NIGHT EVOLUTION - CONTINUAL SKILL BANK MAX")
    print("====================================================================")
    print(f"CPU logical cores : {plan.logical_cores} (Torch intra={plan.torch_threads}, interop={plan.interop_threads})")
    print(f"Detected RAM      : {plan.ram_gb:.1f} GiB")
    print(f"Vector envs       : {plan.sim_envs:,}")
    print(f"Rollout/challenger: {plan.rollout_steps} x {plan.sim_envs:,} = {plan.rollout_steps*plan.sim_envs:,} transitions")
    print(f"PPO               : epochs={rt.cfg.ppo_epochs} minibatch={rt.cfg.ppo_minibatch:,} lr={rt.cfg.ppo_lr:.2e}")
    print(f"RAM replay target : ~{plan.replay_ram_gb:.1f} GiB float16 continual-memory")
    print(f"Estimated rollout : ~{plan.estimated_rollout_gb:.2f} GiB + model/runtime")
    print(f"Evaluation        : 15 fixed skills = 5 difficulty x LEFT/MID/RIGHT")
    print("v0.16.4 rule        : immutable global champion + specialists + replay + plateau escape tournament.")
    print(f"Night evolution    : {'ON' if night_mode else 'OFF'} | fresh-seed holdout={'ON' if night_mode else 'OFF'}")
    print(f"Training target   : {minutes:.1f} minutes\n")

    smart.fit_sim_profile(rt,verbose=True)
    human_samples=[]
    if not skip_human:
        human_samples,cnt=smart.load_human_samples(rt)
        print(f"Human data: files={cnt['files']} success={cnt['success']} fail={cnt['fail']} positive={cnt['positive']} negative={cnt['negative']}")

    replay=SkillReplayBank(plan.replay_ram_gb,rt.cfg.seed)
    seeded=replay.seed_from_persisted()
    print(f"Continual RAM bank capacity: {replay.capacity:,} transitions (~{replay.capacity*replay.bytes_per/1024**3:.1f} GiB); persisted elite seed={seeded:,}; legacy generic elite={len(replay.generic_obs):,}")

    had_champion=MAX_CHAMPION.exists() and checkpoint_load(rt,MAX_CHAMPION)
    if had_champion:
        champ_rates,champ_meta=eval_skill_matrix(rt,plan.eval_episodes_per_skill)
        print(f"Existing champion: {matrix_text(champ_rates)} | score={100*float(champ_meta['score']):.2f}% worst={100*float(champ_meta['worst']):.1f}%")
        rt.save(PREBOOT_CHAMPION)
    else:
        # Fresh/no-global-champion path: preserve the exact pre-simulator model
        # before Human BC/teacher/PPO touches it. This gives a recovery point if
        # a future simulator revision is found to be wrong.
        rt.save(PREBOOT_CHAMPION)
        print(f"[SAFEPOINT] pre-simulator checkpoint saved -> {PREBOOT_CHAMPION.name}")
        # Fresh policy: human BC then a large vectorized feedback-only teacher bootstrap.
        if human_samples:
            m=smart.supervised_update(rt,human_samples,rt.cfg.human_bc_epochs,rt.cfg.human_bc_lr,rt.cfg.human_bc_batch)
            print(f"Human BC: samples={int(m['samples'])} loss={m['loss']:.4f}")
        uniform=np.ones(SKILLS,dtype=np.float64)/SKILLS
        print(f"Fresh Bayesian warm-start: {plan.teacher_fresh_transitions:,} transitions...")
        m=targeted_teacher_distill(rt,plan.teacher_fresh_transitions,uniform,lr=rt.cfg.sim_warmup_lr,label="teacher bootstrap")
        print(f"Teacher complete: {int(m['transitions']):,} | {m['seconds']:.1f}s | loss={m['loss']:.4f}")
        champ_rates,champ_meta=eval_skill_matrix(rt,plan.eval_episodes_per_skill)
        rt.save(MAX_CHAMPION)
        print(f"Bootstrap champion: {matrix_text(champ_rates)} | score={100*float(champ_meta['score']):.2f}%")

    skill_best,skill_hashes=load_skill_state(champ_rates)
    # Current champion itself is a valid per-skill baseline.
    skill_best=np.maximum(skill_best,champ_rates); save_skill_state(skill_best,skill_hashes)
    set_champion_anchor(rt)

    deadline=time.perf_counter()+max(1.0/60.0,minutes)*60.0
    start=time.perf_counter(); total_trans=0; ch=0; accepts=0; rejects=0; specialist_saves=0; consecutive_rejects=0
    plateau_challengers=0; escape_tournaments=0; consolidation_misses=0
    try:
        gc.disable()
        while time.perf_counter()<deadline:
            ch+=1
            checkpoint_load(rt,MAX_CHAMPION); set_champion_anchor(rt)
            probs=adaptive_skill_probs(champ_rates,skill_best)
            install_replay_elite(rt,replay,n=180_000)
            tc=time.perf_counter(); batch=make_batch(rt,probs,seed_offset=100_003*ch); collect_s=time.perf_counter()-tc
            # Every trajectory enters RAM; successful tails from rejected specialists are retained too.
            replay.add_batch(batch)
            install_replay_elite(rt,replay,n=220_000)
            tt=time.perf_counter(); metrics=smart.ppo_update(rt,batch,source="sim"); train_s=time.perf_counter()-tt
            trans=rt.cfg.sim_rollout_steps*rt.cfg.sim_envs; total_trans+=trans

            global_accepted=False
            if metrics.get("reverted",0.0)>0.5:
                rejects+=1; consecutive_rejects+=1; plateau_challengers+=1
                floor_lr=max(rt.cfg.ppo_min_lr,1.2e-5) if night_mode else rt.cfg.ppo_min_lr
                set_optimizer_lr(rt,max(floor_lr,rt.cfg.ppo_lr*0.72))
                checkpoint_load(rt,MAX_CHAMPION); set_champion_anchor(rt)
                decision="TRUST-REJECT"; candidate_rates=champ_rates.copy(); candidate_meta=dict(champ_meta); why=str(metrics.get("stop_reason","")); improved=[]
            else:
                candidate_rates,candidate_meta=eval_skill_matrix(rt,plan.eval_episodes_per_skill)
                improved=archive_skill_improvements(rt,candidate_rates,skill_best,skill_hashes,margin=0.005)
                specialist_saves+=len(improved)
                if night_mode:
                    prelim,_prewhy=accept_global(candidate_rates,candidate_meta,champ_rates,champ_meta)
                    if prelim:
                        accepted,why=holdout_gate(rt,candidate_rates,candidate_meta,champ_rates,champ_meta,
                                                  seed_base=3_000_000+ch*19_999,
                                                  episodes_each=max(96,plan.eval_episodes_per_skill//4))
                    else:
                        accepted,why=False,_prewhy
                else:
                    accepted,why=accept_global(candidate_rates,candidate_meta,champ_rates,champ_meta)
                if accepted:
                    old=float(champ_meta["score"]); champ_rates=candidate_rates; champ_meta=candidate_meta
                    rt.save(MAX_CHAMPION); set_champion_anchor(rt); accepts+=1; consecutive_rejects=0; plateau_challengers=0; global_accepted=True
                    set_optimizer_lr(rt,min(rt.cfg.ppo_max_lr,rt.cfg.ppo_lr*1.035))
                    decision=f"ACCEPT {100*(float(champ_meta['score'])-old):+.2f}pt"
                else:
                    rejects+=1; consecutive_rejects+=1; plateau_challengers+=1
                    if float(candidate_meta["score"]) < float(champ_meta["score"])-0.010 or metrics.get("kl",0)>rt.cfg.ppo_target_kl:
                        floor_lr=max(rt.cfg.ppo_min_lr,1.2e-5) if night_mode else rt.cfg.ppo_min_lr
                        set_optimizer_lr(rt,max(floor_lr,rt.cfg.ppo_lr*0.84))
                    checkpoint_load(rt,MAX_CHAMPION); set_champion_anchor(rt)
                    decision="SPECIALIST" if improved else "REJECT"

            wall=time.perf_counter()-start; sps=total_trans/max(1e-6,wall); eta=max(0.0,deadline-time.perf_counter())/60.0
            imp_txt=(",".join(skill_name(x) for x in improved[:4])+("..." if len(improved)>4 else "")) if improved else "-"
            print(f"CH {ch:4d} | {decision:11s} | {matrix_text(candidate_rates)} | global={100*float(champ_meta['score']):5.2f}% "
                  f"| skill+={imp_txt:24s} | KL={metrics.get('kl',0):.4f} LR={rt.cfg.ppo_lr:.1e} | {sps:,.0f} step/s | RAM={min(replay.total_added,replay.capacity)*replay.bytes_per/1024**3:.1f}GiB | left={eta:.1f}m")
            smart.append_csv(MAX_LOG,
                ["wall_time","challenger","decision","candidate_score","champion_score","candidate_rates","champion_rates","improved_skills","why","ppo_kl","anchor_kl","clipfrac","lr","accepts","rejects","specialist_saves","replay_added","replay_elites","steps_per_second","collect_s","train_s","hash"],
                {"wall_time":time.strftime("%Y-%m-%d %H:%M:%S"),"challenger":ch,"decision":decision,
                 "candidate_score":float(candidate_meta["score"]),"champion_score":float(champ_meta["score"]),
                 "candidate_rates":";".join(f"{x:.6f}" for x in candidate_rates),"champion_rates":";".join(f"{x:.6f}" for x in champ_rates),
                 "improved_skills":";".join(str(x) for x in improved),"why":why,"ppo_kl":metrics.get("kl",0),"anchor_kl":metrics.get("anchor_kl",0),"clipfrac":metrics.get("clipfrac",0),"lr":rt.cfg.ppo_lr,
                 "accepts":accepts,"rejects":rejects,"specialist_saves":specialist_saves,"replay_added":replay.total_added,"replay_elites":int(replay.elite_size.sum()),"steps_per_second":sps,"collect_s":collect_s,"train_s":train_s,"hash":rt.model_hash()})

            write_night_state(ch,float(champ_meta["score"]),plateau_challengers,escape_tournaments,replay)

            # Overnight mode uses a gentler replay-only consolidation. The old
            # replay+teacher merge repeatedly lost ~3 global points on the new
            # narrow geometry, so teacher forcing is reserved for fresh bootstrap.
            consolidate_at=8 if night_mode else 6
            if consecutive_rejects>=consolidate_at and time.perf_counter()<deadline-20:
                checkpoint_load(rt,MAX_CHAMPION); set_champion_anchor(rt)
                print(f"[{'NIGHT REHEARSE' if night_mode else 'CONSOLIDATE'}] {replay.summary()}")
                if night_mode:
                    cm=replay_consolidate(rt,replay,samples=min(220_000,max(60_000,int(replay.elite_size.sum()))),epochs=1,lr=8.0e-6)
                    tm={"transitions":0.0}
                else:
                    cm=replay_consolidate(rt,replay,samples=min(320_000,max(60_000,int(replay.elite_size.sum()))),epochs=2,lr=1.4e-5)
                    focus=adaptive_skill_probs(champ_rates,skill_best)
                    tm=targeted_teacher_distill(rt,plan.teacher_existing_transitions,focus,lr=1.2e-5,label="targeted teacher")
                cr,cmta=eval_skill_matrix(rt,plan.eval_episodes_per_skill)
                improved2=archive_skill_improvements(rt,cr,skill_best,skill_hashes,margin=0.004); specialist_saves+=len(improved2)
                prelim,why2=accept_global(cr,cmta,champ_rates,champ_meta)
                if night_mode and prelim:
                    ok,why2=holdout_gate(rt,cr,cmta,champ_rates,champ_meta,
                                         seed_base=4_000_000+ch*23_111,
                                         episodes_each=max(96,plan.eval_episodes_per_skill//4))
                else:
                    ok=prelim
                if ok:
                    old=float(champ_meta["score"]); champ_rates,champ_meta=cr,cmta; rt.save(MAX_CHAMPION); set_champion_anchor(rt); accepts+=1
                    plateau_challengers=0; consolidation_misses=0
                    set_optimizer_lr(rt,max(rt.cfg.ppo_lr,2.8e-5 if night_mode else rt.cfg.ppo_lr))
                    print(f"[{'NIGHT REHEARSE ACCEPT' if night_mode else 'CONSOLIDATE ACCEPT'}] {100*old:.2f}% -> {100*float(champ_meta['score']):.2f}% | replay={int(cm['samples']):,} teacher={int(tm['transitions']):,}")
                else:
                    checkpoint_load(rt,MAX_CHAMPION); set_champion_anchor(rt)
                    consolidation_misses+=1
                    print(f"[{'NIGHT REHEARSE ARCHIVE' if night_mode else 'CONSOLIDATE ARCHIVE'}] main unchanged | specialist gains={','.join(skill_name(x) for x in improved2) or '-'} | {why2}")
                consecutive_rejects=0

            # A long run must be able to change search strategy when a local
            # optimum persists. Three different branches are tried and only a
            # fixed+unseen validated improvement may replace the champion.
            if night_mode and plateau_challengers>=12 and time.perf_counter()<deadline-90:
                escape_tournaments+=1
                champ_rates,champ_meta,escaped,sp_extra,escape_trans=plateau_escape_tournament(
                    rt,plan,replay,champ_rates,champ_meta,skill_best,skill_hashes,
                    escape_tournaments,ch,use_holdout=True)
                specialist_saves+=sp_extra; total_trans+=escape_trans
                if escaped:
                    accepts+=1; plateau_challengers=0; consecutive_rejects=0; consolidation_misses=0
                else:
                    # Cooldown: ordinary PPO gets eight fresh attempts before
                    # another expensive population tournament.
                    plateau_challengers=4; consecutive_rejects=0
                persisted_now=replay.persist_elites(max_total=450_000)
                print(f"[NIGHT SAVE] post-escape persisted elite replay={persisted_now:,}")

            # Crash-resilient overnight persistence. Global/per-skill models are
            # already checkpointed continuously; this additionally saves the
            # valuable RAM elite set every ~25 ordinary challengers.
            if night_mode and ch%25==0:
                persisted_now=replay.persist_elites(max_total=450_000)
                print(f"[NIGHT SAVE] CH{ch} persisted elite replay={persisted_now:,} | {replay.summary()}")
    except KeyboardInterrupt:
        print("\n[STOP] Ctrl+C received. Global + per-skill champions are already safe.")
    finally:
        try: gc.enable()
        except Exception: pass

    checkpoint_load(rt,MAX_CHAMPION); rt.save()
    persisted=replay.persist_elites(max_total=450_000)
    wall=time.perf_counter()-start
    print("\n====================================================================")
    print(f"v0.16.4 COMPLETE | challengers={ch} accepted={accepts} rejected={rejects} specialist-saves={specialist_saves} escape-tournaments={escape_tournaments}")
    print(f"Transitions={total_trans:,} | wall={wall/60:.1f} min | {replay.summary()}")
    print(f"Champion: {matrix_text(champ_rates)} | score={100*float(champ_meta['score']):.2f}% | worst={100*float(champ_meta['worst']):.1f}%")
    print(f"Persisted balanced elite replay: {persisted:,} transitions")
    print(f"Global checkpoint: {MAX_CHAMPION}")
    print(f"Per-skill archive: {SKILL_DIR}")
    print("Next: START_SMART.bat -> REAL EVALUATE. Simulator score is still not proof of real-game success.")


def main() -> None:
    ap=argparse.ArgumentParser(description="v0.16.4 NIGHT EVOLUTION continual skill-bank trainer")
    ap.add_argument("--minutes",type=float,default=None)
    ap.add_argument("--skip-human",action="store_true")
    ap.add_argument("--no-autotune",action="store_true")
    ap.add_argument("--night",action="store_true",help="enable plateau escape + unseen holdout + periodic replay persistence")
    ap.add_argument("--quick-test",action="store_true")
    args=ap.parse_args()
    plan=base_plan(); set_aggressive_priority_and_affinity(plan.logical_cores)
    cfg=smart.SmartConfig.load(); smart.set_seeds(cfg.seed)
    if args.quick_test:
        # Tiny deterministic smoke profile used by package verification only.
        plan.sim_envs=min(256,plan.sim_envs); plan.rollout_steps=8; plan.ppo_minibatch=256; plan.eval_episodes_per_skill=16; plan.replay_ram_gb=0.08; plan.teacher_fresh_transitions=512; plan.teacher_existing_transitions=512
    rt=smart.SmartRuntime(smart.classic.Config.load(),cfg); apply_plan(rt,plan)
    minutes=args.minutes
    if args.quick_test:
        minutes=1.0/60.0
    elif minutes is None:
        raw=input("How many minutes should v0.16.4 CONTINUAL MAX training run? [30]: ").strip()
        try: minutes=float(raw) if raw else 30.0
        except Exception: minutes=30.0
    minutes=max(1.0/60.0,min(float(minutes),24*60.0))
    night_mode=bool(args.night or minutes>=180.0)
    run(rt,plan,minutes,skip_human=args.skip_human,
        no_autotune=(args.no_autotune or args.quick_test),night_mode=night_mode)


if __name__=="__main__":
    main()
