from __future__ import annotations

import csv
import hashlib
import json
import math
import os
import random
import shutil
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
    from torch.distributions import Categorical
except Exception as exc:  # pragma: no cover - startup guard
    raise SystemExit(
        "PyTorch is required for Neural PPO mode. Run SETUP_NEURAL.bat first.\n"
        f"Import error: {exc}"
    )

import lockpick_learner as classic

APP_NAME = "Lockpick Learner Neural PPO"
ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
NEURAL_DIR = DATA_DIR / "neural"
CHECKPOINT_DIR = NEURAL_DIR / "checkpoints"
AUDIT_DIR = NEURAL_DIR / "audit"
TRAIN_EPISODES = NEURAL_DIR / "train_episodes.csv"
EVAL_EPISODES = NEURAL_DIR / "eval_episodes.csv"
DECISION_LOG = AUDIT_DIR / "decisions.csv"
PPO_LOG = AUDIT_DIR / "ppo_updates.csv"
STATS_PATH = NEURAL_DIR / "stats.json"
LATEST_CKPT = NEURAL_DIR / "ppo_latest.pt"
BEST_CKPT = NEURAL_DIR / "ppo_best.pt"
INITIAL_CKPT = NEURAL_DIR / "ppo_initial.pt"
CONFIG_PATH = ROOT / "config_neural.json"

for p in (DATA_DIR, NEURAL_DIR, CHECKPOINT_DIR, AUDIT_DIR):
    p.mkdir(parents=True, exist_ok=True)


@dataclass
class NeuralConfig:
    hidden_sizes: List[int] = field(default_factory=lambda: [128, 128])
    hold_ms: List[int] = field(default_factory=lambda: [28, 75, 190])
    rollout_steps: int = 64
    min_update_steps_on_exit: int = 20
    ppo_epochs: int = 8
    minibatch_size: int = 64
    learning_rate: float = 3e-4
    gamma: float = 0.97
    gae_lambda: float = 0.95
    clip_ratio: float = 0.20
    value_coef: float = 0.50
    entropy_coef: float = 0.020
    max_grad_norm: float = 0.50
    target_kl: float = 0.035
    max_steps_per_attempt: int = 18
    fail_penalty: float = -12.0
    success_reward: float = 100.0
    speed_bonus_max: float = 45.0
    wobble_bonus: float = 1.25
    progress_gain: float = 30.0
    absolute_progress: float = 2.0
    new_best_bonus: float = 8.0
    regression_penalty: float = 8.0
    probe_cost: float = 0.08
    time_cost_per_second: float = 0.65
    boundary_penalty: float = 0.25
    response_window_ms: int = 165
    success_extra_wait_ms: int = 180
    checkpoint_every_updates: int = 5
    stats_windows: List[int] = field(default_factory=lambda: [25, 50, 100])
    seed: int = 5606
    use_cuda_if_available: bool = True

    @staticmethod
    def load() -> "NeuralConfig":
        if not CONFIG_PATH.exists():
            cfg = NeuralConfig()
            CONFIG_PATH.write_text(json.dumps(asdict(cfg), indent=2), encoding="utf-8")
            return cfg
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        valid = set(NeuralConfig.__dataclass_fields__.keys())
        cfg = NeuralConfig(**{k: v for k, v in raw.items() if k in valid})
        CONFIG_PATH.write_text(json.dumps(asdict(cfg), indent=2), encoding="utf-8")
        return cfg


OBS_DIM = 12


def set_seeds(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def choose_device(cfg: NeuralConfig) -> torch.device:
    if cfg.use_cuda_if_available and torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


class ActorCritic(nn.Module):
    """Small real neural actor-critic used by PPO.

    The policy is factorized into two categorical heads:
      - horizontal movement: the classic 11 normalized mouse deltas
      - F hold duration: short / medium / long

    Joint behavior therefore covers 11 x 3 = 33 possible action combinations,
    but learns the two components more efficiently than a flat 33-way head.
    """

    def __init__(self, obs_dim: int, move_actions: int, hold_actions: int, hidden_sizes: Sequence[int]):
        super().__init__()
        dims = [obs_dim, *hidden_sizes]
        layers: List[nn.Module] = []
        for i in range(len(dims) - 1):
            lin = nn.Linear(dims[i], dims[i + 1])
            nn.init.orthogonal_(lin.weight, gain=math.sqrt(2.0))
            nn.init.zeros_(lin.bias)
            layers += [lin, nn.Tanh()]
        self.body = nn.Sequential(*layers)
        last = dims[-1]
        self.move_head = nn.Linear(last, move_actions)
        self.hold_head = nn.Linear(last, hold_actions)
        self.value_head = nn.Linear(last, 1)
        nn.init.orthogonal_(self.move_head.weight, gain=0.01)
        nn.init.zeros_(self.move_head.bias)
        nn.init.orthogonal_(self.hold_head.weight, gain=0.01)
        nn.init.zeros_(self.hold_head.bias)
        nn.init.orthogonal_(self.value_head.weight, gain=1.0)
        nn.init.zeros_(self.value_head.bias)

    def forward(self, obs: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        h = self.body(obs)
        return self.move_head(h), self.hold_head(h), self.value_head(h).squeeze(-1)

    def act(self, obs: torch.Tensor, deterministic: bool = False):
        move_logits, hold_logits, value = self(obs)
        move_dist = Categorical(logits=move_logits)
        hold_dist = Categorical(logits=hold_logits)
        if deterministic:
            move = torch.argmax(move_logits, dim=-1)
            hold = torch.argmax(hold_logits, dim=-1)
        else:
            move = move_dist.sample()
            hold = hold_dist.sample()
        logp = move_dist.log_prob(move) + hold_dist.log_prob(hold)
        entropy = move_dist.entropy() + hold_dist.entropy()
        return move, hold, logp, value, entropy

    def evaluate_actions(self, obs: torch.Tensor, move: torch.Tensor, hold: torch.Tensor):
        move_logits, hold_logits, value = self(obs)
        move_dist = Categorical(logits=move_logits)
        hold_dist = Categorical(logits=hold_logits)
        logp = move_dist.log_prob(move) + hold_dist.log_prob(hold)
        entropy = move_dist.entropy() + hold_dist.entropy()
        return logp, entropy, value, move_logits, hold_logits


@dataclass
class Transition:
    obs: np.ndarray
    move_action: int
    hold_action: int
    logp: float
    value: float
    reward: float
    done: bool


class RolloutBuffer:
    def __init__(self):
        self.rows: List[Transition] = []

    def extend(self, rows: Sequence[Transition]) -> None:
        self.rows.extend(rows)

    def clear(self) -> None:
        self.rows.clear()

    def __len__(self) -> int:
        return len(self.rows)


class NeuralStats:
    def __init__(self):
        self.data: Dict[str, object] = {
            "created": time.strftime("%Y-%m-%d %H:%M:%S"),
            "train_attempts": 0,
            "train_successes": 0,
            "eval_attempts": 0,
            "eval_successes": 0,
            "ppo_updates": 0,
            "gradient_steps": 0,
            "transitions_trained": 0,
            "best_eval_rate": 0.0,
            "initial_hash": "",
            "last_hash": "",
            "last_device": "",
        }
        self.load()

    def load(self) -> None:
        if STATS_PATH.exists():
            try:
                loaded = json.loads(STATS_PATH.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    self.data.update(loaded)
            except Exception as e:
                print(f"[WARN] Neural stats load failed: {e}")

    def save(self) -> None:
        tmp = STATS_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.data, indent=2), encoding="utf-8")
        tmp.replace(STATS_PATH)

    def inc(self, key: str, amount: int = 1) -> None:
        self.data[key] = int(self.data.get(key, 0) or 0) + amount


class NeuralRuntime:
    def __init__(self, classic_cfg: classic.Config, neural_cfg: NeuralConfig):
        self.classic_cfg = classic_cfg
        self.cfg = neural_cfg
        self.device = choose_device(neural_cfg)
        self.calibration_model = classic.QModel(classic_cfg)
        self.move_steps = list(map(float, classic_cfg.action_steps))
        self.hold_ms = list(map(int, neural_cfg.hold_ms))
        self.net = ActorCritic(OBS_DIM, len(self.move_steps), len(self.hold_ms), neural_cfg.hidden_sizes).to(self.device)
        self.optimizer = torch.optim.Adam(self.net.parameters(), lr=neural_cfg.learning_rate, eps=1e-5)
        self.stats = NeuralStats()
        self.stats.data["last_device"] = str(self.device)
        self.load_or_initialize()
        self.stats.save()

    def model_hash(self) -> str:
        h = hashlib.sha256()
        for name, tensor in sorted(self.net.state_dict().items()):
            h.update(name.encode("utf-8"))
            arr = tensor.detach().cpu().contiguous().numpy()
            h.update(str(arr.dtype).encode("ascii"))
            h.update(str(arr.shape).encode("ascii"))
            h.update(arr.tobytes(order="C"))
        return h.hexdigest()

    def save_checkpoint(self, path: Path = LATEST_CKPT, include_optimizer: bool = True) -> None:
        obj = {
            "version": 6,
            "obs_dim": OBS_DIM,
            "move_steps": self.move_steps,
            "hold_ms": self.hold_ms,
            "hidden_sizes": self.cfg.hidden_sizes,
            "state_dict": self.net.state_dict(),
            "stats": dict(self.stats.data),
            "neural_config": asdict(self.cfg),
        }
        if include_optimizer:
            obj["optimizer"] = self.optimizer.state_dict()
        tmp = path.with_suffix(path.suffix + ".tmp")
        torch.save(obj, tmp)
        tmp.replace(path)
        self.stats.data["last_hash"] = self.model_hash()
        self.stats.save()

    def load_or_initialize(self) -> None:
        stats_preexisting = STATS_PATH.exists()
        if LATEST_CKPT.exists():
            try:
                ckpt = torch.load(LATEST_CKPT, map_location=self.device)
                if int(ckpt.get("obs_dim", -1)) != OBS_DIM:
                    raise ValueError("checkpoint observation size does not match this version")
                if list(map(float, ckpt.get("move_steps", []))) != self.move_steps:
                    raise ValueError("checkpoint movement action space does not match current config")
                if list(map(int, ckpt.get("hold_ms", []))) != self.hold_ms:
                    raise ValueError("checkpoint F-hold action space does not match current config")
                self.net.load_state_dict(ckpt["state_dict"])
                if "optimizer" in ckpt:
                    self.optimizer.load_state_dict(ckpt["optimizer"])
                # stats.json is authoritative when present because evaluation can
                # update counters without rewriting the training checkpoint. Use
                # embedded checkpoint stats only as a recovery fallback.
                if (not stats_preexisting) and isinstance(ckpt.get("stats"), dict):
                    self.stats.data.update(ckpt["stats"])
                print(f"Loaded neural checkpoint: {LATEST_CKPT.name} | hash={self.model_hash()[:12]}")
                return
            except Exception as e:
                bad = NEURAL_DIR / f"ppo_incompatible_{time.strftime('%Y%m%d_%H%M%S')}.pt"
                try:
                    shutil.move(str(LATEST_CKPT), str(bad))
                except Exception:
                    pass
                print(f"[WARN] Existing neural checkpoint was incompatible and was moved aside: {e}")
        self.save_checkpoint(LATEST_CKPT)
        if not INITIAL_CKPT.exists():
            shutil.copy2(LATEST_CKPT, INITIAL_CKPT)
        ph = self.model_hash()
        if not self.stats.data.get("initial_hash"):
            self.stats.data["initial_hash"] = ph
        self.stats.data["last_hash"] = ph
        self.stats.save()
        print(f"Created fresh neural PPO policy | hash={ph[:12]}")


def obs_vector(
    pos: float,
    response: float,
    best: float,
    prev_response: float,
    elapsed: float,
    budget: float,
    last_delta: float,
    last_hold_idx: int,
    hold_count: int,
    last_reward: float,
    probe_no: int,
    wobble_threshold: float,
    max_move: float,
) -> np.ndarray:
    pos = float(np.clip(pos, 0.0, 1.0))
    response = float(np.clip(response, 0.0, 1.0))
    best = float(np.clip(best, 0.0, 1.0))
    improvement = float(np.clip(response - prev_response, -0.25, 0.25) / 0.25)
    trend = 1.0 if response > prev_response + 0.015 else (-1.0 if response + 0.015 < prev_response else 0.0)
    found = 1.0 if best >= wobble_threshold or response >= wobble_threshold else -1.0
    ef = float(np.clip(elapsed / max(0.1, budget), 0.0, 1.25))
    remaining = float(np.clip(1.0 - elapsed / max(0.1, budget), 0.0, 1.0))
    hold_norm = 0.0 if hold_count <= 1 else (2.0 * last_hold_idx / (hold_count - 1) - 1.0)
    return np.asarray([
        2.0 * pos - 1.0,
        2.0 * response - 1.0,
        2.0 * best - 1.0,
        improvement,
        trend,
        found,
        float(np.clip(2.0 * ef - 1.0, -1.0, 1.5)),
        2.0 * remaining - 1.0,
        float(np.clip(last_delta / max(1e-6, max_move), -1.0, 1.0)),
        hold_norm,
        float(np.tanh(last_reward / 10.0)),
        2.0 * float(np.clip(probe_no / 16.0, 0.0, 1.0)) - 1.0,
    ], dtype=np.float32)


def nearest_move_index(steps: Sequence[float], delta: float) -> int:
    return min(range(len(steps)), key=lambda i: abs(float(steps[i]) - float(delta)))


def append_csv(path: Path, fieldnames: Sequence[str], row: Dict[str, object]) -> None:
    exists = path.exists()
    with path.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(fieldnames), extrasaction="ignore")
        if not exists:
            w.writeheader()
        w.writerow(row)


def log_episode(path: Path, mode: str, attempt: int, success: bool, elapsed: float, steps: int, total_reward: float, best: float, rt: NeuralRuntime) -> None:
    append_csv(path,
               ["wall_time", "mode", "attempt", "success", "elapsed", "steps", "total_reward", "best_response", "ppo_updates", "policy_hash"],
               {
                   "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"),
                   "mode": mode,
                   "attempt": attempt,
                   "success": int(success),
                   "elapsed": f"{elapsed:.6f}",
                   "steps": steps,
                   "total_reward": f"{total_reward:.6f}",
                   "best_response": f"{best:.6f}",
                   "ppo_updates": int(rt.stats.data.get("ppo_updates", 0) or 0),
                   "policy_hash": rt.model_hash(),
               })


def log_decision(
    rt: NeuralRuntime,
    mode: str,
    attempt: int,
    step_no: int,
    obs: np.ndarray,
    move_idx: int,
    hold_idx: int,
    move_probs: Sequence[float],
    hold_probs: Sequence[float],
    value: float,
    reward: float,
    response: float,
    best: float,
    success_score: float,
    requested_delta: float,
    executed_delta: float,
) -> None:
    append_csv(
        DECISION_LOG,
        ["wall_time", "mode", "attempt", "step", "obs", "move_action", "move_delta", "executed_delta", "hold_action", "hold_ms", "move_probs", "hold_probs", "value", "reward", "response", "best", "success_score", "policy_hash"],
        {
            "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"),
            "mode": mode,
            "attempt": attempt,
            "step": step_no,
            "obs": json.dumps([round(float(x), 6) for x in obs], separators=(",", ":")),
            "move_action": move_idx,
            "move_delta": requested_delta,
            "executed_delta": executed_delta,
            "hold_action": hold_idx,
            "hold_ms": rt.hold_ms[hold_idx],
            "move_probs": json.dumps([round(float(x), 6) for x in move_probs], separators=(",", ":")),
            "hold_probs": json.dumps([round(float(x), 6) for x in hold_probs], separators=(",", ":")),
            "value": value,
            "reward": reward,
            "response": response,
            "best": best,
            "success_score": success_score,
            "policy_hash": rt.model_hash(),
        },
    )


def neural_step_reward(rt: NeuralRuntime, response: float, prev_response: float, best_before: float, step_seconds: float, requested_delta: float, executed_delta: float) -> float:
    cfg = rt.cfg
    improvement = float(response - prev_response)
    best_gain = max(0.0, float(response - best_before))
    reward = 0.0
    if response >= rt.classic_cfg.wobble_threshold:
        reward += cfg.wobble_bonus
    reward += cfg.progress_gain * max(0.0, improvement)
    reward -= cfg.regression_penalty * max(0.0, -improvement)
    reward += cfg.absolute_progress * max(0.0, response)
    reward += cfg.new_best_bonus * best_gain
    reward -= cfg.probe_cost
    reward -= cfg.time_cost_per_second * max(0.0, step_seconds)
    if abs(requested_delta) > 0.005 and abs(executed_delta) < 0.0025:
        reward -= cfg.boundary_penalty
    return float(reward)


def success_reward(rt: NeuralRuntime, elapsed: float) -> float:
    ratio = max(0.0, 1.0 - elapsed / max(0.1, rt.classic_cfg.attempt_budget_seconds))
    return float(rt.cfg.success_reward + rt.cfg.speed_bonus_max * ratio)


def probe_response_hold(vision: classic.ScreenVision, cfg: classic.Config, neural_cfg: NeuralConfig, hold_ms: int) -> Tuple[float, float, float]:
    before = vision.state()
    base = before.progress
    success_peak = before.success_score
    classic.send_key(cfg.f_key_vk, int(hold_ms))
    response_ms = max(int(neural_cfg.response_window_ms), int(hold_ms * 0.55))
    end = time.monotonic() + response_ms / 1000.0
    peak = base
    ui = before.ui_confidence
    while time.monotonic() < end:
        st = vision.state(keep_frame=cfg.debug_preview)
        peak = max(peak, st.progress)
        ui = st.ui_confidence
        success_peak = max(success_peak, st.success_score)
        if cfg.debug_preview:
            classic.preview(vision, st, "Lockpick Learner - Neural PPO")
        time.sleep(0.004)
    response = float(np.clip(peak - min(base, 0.055), 0.0, 1.0))
    return response, ui, float(success_peak)


def policy_sample(rt: NeuralRuntime, obs: np.ndarray, deterministic: bool):
    x = torch.as_tensor(obs, dtype=torch.float32, device=rt.device).unsqueeze(0)
    with torch.no_grad():
        move_logits, hold_logits, value = rt.net(x)
        move_probs = torch.softmax(move_logits, dim=-1)
        hold_probs = torch.softmax(hold_logits, dim=-1)
        if deterministic:
            move_idx = int(torch.argmax(move_logits, dim=-1).item())
            hold_idx = int(torch.argmax(hold_logits, dim=-1).item())
            move_dist = Categorical(logits=move_logits)
            hold_dist = Categorical(logits=hold_logits)
            logp = float((move_dist.log_prob(torch.tensor([move_idx], device=rt.device)) + hold_dist.log_prob(torch.tensor([hold_idx], device=rt.device))).item())
        else:
            move_dist = Categorical(logits=move_logits)
            hold_dist = Categorical(logits=hold_logits)
            ma = move_dist.sample()
            ha = hold_dist.sample()
            move_idx = int(ma.item())
            hold_idx = int(ha.item())
            logp = float((move_dist.log_prob(ma) + hold_dist.log_prob(ha)).item())
    return move_idx, hold_idx, logp, float(value.item()), move_probs.squeeze(0).cpu().numpy(), hold_probs.squeeze(0).cpu().numpy()


def ppo_update(rt: NeuralRuntime, buffer: RolloutBuffer) -> Dict[str, float]:
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
        delta = rewards[t] + rt.cfg.gamma * next_value * nonterminal - old_values[t]
        gae = delta + rt.cfg.gamma * rt.cfg.gae_lambda * nonterminal * gae
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

    rt.net.train()
    for _epoch in range(int(rt.cfg.ppo_epochs)):
        np.random.shuffle(indices)
        for start in range(0, n, max(1, int(rt.cfg.minibatch_size))):
            mb = indices[start:start + max(1, int(rt.cfg.minibatch_size))]
            mb_t = torch.as_tensor(mb, dtype=torch.long, device=rt.device)
            new_logp, entropy, values, _ml, _hl = rt.net.evaluate_actions(obs[mb_t], move[mb_t], hold[mb_t])
            log_ratio = new_logp - old_logp[mb_t]
            ratio = torch.exp(log_ratio)
            s1 = ratio * advantages[mb_t]
            s2 = torch.clamp(ratio, 1.0 - rt.cfg.clip_ratio, 1.0 + rt.cfg.clip_ratio) * advantages[mb_t]
            policy_loss = -torch.min(s1, s2).mean()
            value_loss = 0.5 * F.mse_loss(values, returns_t[mb_t])
            entropy_mean = entropy.mean()
            loss = policy_loss + rt.cfg.value_coef * value_loss - rt.cfg.entropy_coef * entropy_mean

            rt.optimizer.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(rt.net.parameters(), rt.cfg.max_grad_norm)
            rt.optimizer.step()
            grad_steps += 1

            with torch.no_grad():
                approx_kl = float(((ratio - 1.0) - log_ratio).mean().item())
                clip_frac = float((torch.abs(ratio - 1.0) > rt.cfg.clip_ratio).float().mean().item())
            losses.append(float(loss.item()))
            policy_losses.append(float(policy_loss.item()))
            value_losses.append(float(value_loss.item()))
            entropies.append(float(entropy_mean.item()))
            kls.append(approx_kl)
            clip_fracs.append(clip_frac)
            if approx_kl > rt.cfg.target_kl * 1.5:
                early_stop = True
                break
        if early_stop:
            break

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
        "approx_kl": float(np.mean(kls) if kls else 0.0),
        "clip_frac": float(np.mean(clip_fracs) if clip_fracs else 0.0),
        "grad_steps": float(grad_steps),
        "early_stop": float(1 if early_stop else 0),
    }
    append_csv(PPO_LOG,
               ["wall_time", "ppo_update", "transitions", "loss", "policy_loss", "value_loss", "entropy", "approx_kl", "clip_frac", "grad_steps", "early_stop", "policy_hash"],
               {"wall_time": time.strftime("%Y-%m-%d %H:%M:%S"), "ppo_update": update_no, **metrics, "policy_hash": rt.model_hash()})
    rt.save_checkpoint(LATEST_CKPT)
    if update_no % max(1, int(rt.cfg.checkpoint_every_updates)) == 0:
        cp = CHECKPOINT_DIR / f"ppo_update_{update_no:06d}.pt"
        rt.save_checkpoint(cp)
    print(
        f"\nPPO UPDATE #{update_no}: n={n} loss={metrics['loss']:+.4f} "
        f"pi={metrics['policy_loss']:+.4f} V={metrics['value_loss']:.4f} "
        f"H={metrics['entropy']:.3f} KL={metrics['approx_kl']:.5f} hash={rt.model_hash()[:12]}"
    )
    buffer.clear()
    return metrics


def _prepare_live(rt: NeuralRuntime):
    vision, console_hwnd, _hwnd = classic.prepare_live_vision(rt.classic_cfg, rt.calibration_model, minimize=True)
    if not classic.calibration_valid(rt.calibration_model, vision):
        print("Calibration missing/stale -> calibrating on the detected game monitor.")
        if not classic.auto_calibrate(rt.classic_cfg, rt.calibration_model, vision):
            classic.restore_console(console_hwnd)
            return None, console_hwnd
        # Calibration updates the classic model dict in-place. Rebuild ScreenVision
        # so normalized pick positions immediately use the fresh endpoint values.
        vision, _unused_console, _unused_hwnd = classic.prepare_live_vision(rt.classic_cfg, rt.calibration_model, minimize=False)
    return vision, console_hwnd


def run_neural(rt: NeuralRuntime, learning: bool, max_attempts: Optional[int] = None) -> None:
    if not classic.IS_WINDOWS:
        print("Live neural play needs Windows because mouse/keyboard input uses SendInput.")
        return
    mode = "NEURAL TRAIN" if learning else "NEURAL EVALUATION"
    print(f"\n=== {mode} v0.6 PPO ===")
    print("F12 = emergency stop. Hold F10 = pause.")
    if learning:
        print("The neural policy samples actions, collects completed episodes and PPO-trains itself from reward.")
    else:
        print("Deterministic argmax policy; learning/optimizer updates are disabled.")

    before_hash = rt.model_hash()
    before_updates = int(rt.stats.data.get("ppo_updates", 0) or 0)
    vision, console_hwnd = _prepare_live(rt)
    if vision is None:
        return

    buffer = RolloutBuffer()
    attempt_local = 0
    aborted = False
    rt.net.eval()
    max_move = max(abs(x) for x in rt.move_steps)

    while max_attempts is None or attempt_local < max_attempts:
        if classic.emergency_or_pause(rt.classic_cfg):
            aborted = True
            break
        attempt_local += 1
        global_attempt = int(rt.stats.data.get("train_attempts" if learning else "eval_attempts", 0) or 0) + 1
        print(f"\n--- neural attempt {global_attempt} ---")

        classic.send_key(rt.classic_cfg.space_key_vk, 28)
        time.sleep(max(0.08, rt.classic_cfg.start_wait_seconds))
        classic.move_mouse_relative(-5000, 0)
        time.sleep(0.16)
        st0 = vision.state(keep_frame=rt.classic_cfg.debug_preview)
        if rt.classic_cfg.debug_preview:
            classic.preview(vision, st0, "Lockpick Learner - Neural PPO")
        pos = st0.pick_pos
        if pos is None:
            print("Could not see normalized pick position at attempt start; skipping this attempt.")
            time.sleep(rt.classic_cfg.restart_wait_seconds)
            continue

        start = time.monotonic()
        response = 0.0
        prev_response = 0.0
        best = 0.0
        last_delta = 0.0
        last_hold_idx = 0
        last_reward = 0.0
        episode: List[Transition] = []
        total_reward = 0.0
        success = False
        terminal = False
        step_no = 0
        latest_success_score = 0.0

        while step_no < int(rt.cfg.max_steps_per_attempt):
            if classic.emergency_or_pause(rt.classic_cfg):
                aborted = True
                break
            elapsed = time.monotonic() - start
            if elapsed >= rt.classic_cfg.attempt_budget_seconds + 0.45:
                terminal = True
                break

            obs = obs_vector(
                pos, response, best, prev_response, elapsed, rt.classic_cfg.attempt_budget_seconds,
                last_delta, last_hold_idx, len(rt.hold_ms), last_reward, step_no,
                rt.classic_cfg.wobble_threshold, max_move,
            )
            move_idx, hold_idx, logp, value, move_probs, hold_probs = policy_sample(rt, obs, deterministic=not learning)
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
            response, ui_conf, success_score = probe_response_hold(vision, rt.classic_cfg, rt.cfg, rt.hold_ms[hold_idx])
            latest_success_score = success_score
            step_no += 1
            elapsed = time.monotonic() - start
            step_seconds = time.monotonic() - step_started
            reward = neural_step_reward(rt, response, before_response, best_before, step_seconds, requested_delta, executed_delta)
            best = max(best, response)

            if success_score >= rt.classic_cfg.success_template_threshold:
                success = True
            elif ui_conf < 0.045 and elapsed > 0.40:
                late = classic.wait_success_text(vision, rt.classic_cfg, ms=rt.cfg.success_extra_wait_ms)
                latest_success_score = max(latest_success_score, late)
                success = late >= rt.classic_cfg.success_template_threshold
                terminal = True
            elif elapsed >= rt.classic_cfg.attempt_budget_seconds + 0.40:
                late = classic.wait_success_text(vision, rt.classic_cfg, ms=rt.cfg.success_extra_wait_ms)
                latest_success_score = max(latest_success_score, late)
                success = late >= rt.classic_cfg.success_template_threshold
                terminal = True

            if success:
                reward += success_reward(rt, elapsed)
                terminal = True
            elif terminal or step_no >= int(rt.cfg.max_steps_per_attempt):
                reward += rt.cfg.fail_penalty
                terminal = True

            total_reward += reward
            episode.append(Transition(obs, move_idx, hold_idx, logp, value, reward, terminal))
            log_decision(rt, mode, global_attempt, step_no, obs, move_idx, hold_idx, move_probs, hold_probs, value, reward, response, best, latest_success_score, requested_delta, executed_delta)
            move_conf = float(move_probs[move_idx])
            hold_conf = float(hold_probs[hold_idx])
            print(
                f"p={pos:.3f} resp={response:.3f} best={best:.3f} "
                f"r={reward:+.2f} move={requested_delta:+.3f}({move_conf:.2f}) "
                f"F={rt.hold_ms[hold_idx]}ms({hold_conf:.2f}) V={value:+.2f} success={latest_success_score:.2f}",
                end="\r",
            )

            prev_response = before_response
            last_delta = requested_delta
            last_hold_idx = hold_idx
            last_reward = reward
            if terminal:
                break

        if aborted:
            print("\nCurrent incomplete neural episode discarded (not trained as a fake FAIL).")
            break

        # If the loop ended between actions (for example the time budget was
        # reached at the top of the next iteration), the previous transition
        # still needs an explicit terminal label and terminal reward.
        if episode and not episode[-1].done:
            elapsed = time.monotonic() - start
            late = classic.wait_success_text(vision, rt.classic_cfg, ms=rt.cfg.success_extra_wait_ms)
            success = late >= rt.classic_cfg.success_template_threshold
            latest_success_score = max(latest_success_score, late)
            terminal_bonus = success_reward(rt, elapsed) if success else rt.cfg.fail_penalty
            episode[-1].reward += terminal_bonus
            episode[-1].done = True
            total_reward += terminal_bonus
            terminal = True
        elif not terminal:
            elapsed = time.monotonic() - start
            late = classic.wait_success_text(vision, rt.classic_cfg, ms=rt.cfg.success_extra_wait_ms)
            success = late >= rt.classic_cfg.success_template_threshold
            latest_success_score = max(latest_success_score, late)
            terminal = True

        elapsed = time.monotonic() - start
        if success:
            print(f"\nNEURAL SUCCESS in {elapsed:.2f}s | steps={step_no} | best={best:.3f} | reward={total_reward:.1f}")
        else:
            print(f"\nNEURAL FAIL | t={elapsed:.2f}s | steps={step_no} | best={best:.3f} | reward={total_reward:.1f}")

        if learning:
            rt.stats.inc("train_attempts", 1)
            if success:
                rt.stats.inc("train_successes", 1)
            buffer.extend(episode)
            log_episode(TRAIN_EPISODES, mode, global_attempt, success, elapsed, step_no, total_reward, best, rt)
            if len(buffer) >= int(rt.cfg.rollout_steps):
                ppo_update(rt, buffer)
                rt.net.eval()
        else:
            rt.stats.inc("eval_attempts", 1)
            if success:
                rt.stats.inc("eval_successes", 1)
            log_episode(EVAL_EPISODES, mode, global_attempt, success, elapsed, step_no, total_reward, best, rt)
            rt.stats.save()

        time.sleep(rt.classic_cfg.restart_wait_seconds)

    if learning and len(buffer) >= int(rt.cfg.min_update_steps_on_exit):
        print(f"\nTraining remaining {len(buffer)} completed on-policy transitions before exit...")
        ppo_update(rt, buffer)
    elif learning and len(buffer) > 0:
        print(f"\nKept model unchanged for the final {len(buffer)} transitions because the buffer was below min_update_steps_on_exit={rt.cfg.min_update_steps_on_exit}.")

    if learning:
        rt.save_checkpoint(LATEST_CKPT)
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
        print(f"\nEvaluation mutation check: hash {before_hash[:12]} -> {after_hash[:12]} | PPO updates {before_updates} -> {after_updates}")
        if before_hash == after_hash and before_updates == after_updates:
            print("PASS: deterministic evaluation did not train or mutate the neural policy.")
        else:
            print("FAIL: evaluation mutated neural state unexpectedly.")


def read_episode_rows(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    try:
        with path.open("r", newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))
    except Exception:
        return []


def summarize_rows(rows: List[Dict[str, str]], windows: Sequence[int], title: str) -> None:
    print(f"\n{title}")
    if not rows:
        print("  no episodes")
        return
    for w in windows:
        sub = rows[-int(w):]
        if not sub:
            continue
        successes = sum(int(float(r.get("success", 0) or 0)) for r in sub)
        rate = 100.0 * successes / len(sub)
        rewards = [float(r.get("total_reward", 0) or 0) for r in sub]
        bests = [float(r.get("best_response", 0) or 0) for r in sub]
        steps = [float(r.get("steps", 0) or 0) for r in sub]
        win_times = [float(r.get("elapsed", 0) or 0) for r in sub if int(float(r.get("success", 0) or 0)) == 1]
        print(
            f"  last {len(sub):>3}: success={rate:5.1f}% | avg best={np.mean(bests):.3f} | "
            f"avg reward={np.mean(rewards):+.1f} | avg steps={np.mean(steps):.2f} | "
            f"avg win time={(np.mean(win_times) if win_times else float('nan')):.2f}s"
        )


def neural_stats(rt: NeuralRuntime) -> None:
    d = rt.stats.data
    tr_a = int(d.get("train_attempts", 0) or 0)
    tr_s = int(d.get("train_successes", 0) or 0)
    ev_a = int(d.get("eval_attempts", 0) or 0)
    ev_s = int(d.get("eval_successes", 0) or 0)
    params = sum(p.numel() for p in rt.net.parameters())
    print("\n=== NEURAL PPO STATS ===")
    print(f"Device: {rt.device} | torch={torch.__version__}")
    print(f"Network parameters: {params:,}")
    print(f"Observation features: {OBS_DIM}")
    print(f"Action heads: movement={len(rt.move_steps)}, F-hold={len(rt.hold_ms)} -> {len(rt.move_steps)*len(rt.hold_ms)} joint combinations")
    print(f"Train attempts: {tr_a} | successes: {tr_s} ({(100*tr_s/tr_a if tr_a else 0):.1f}%)")
    print(f"Eval attempts:  {ev_a} | successes: {ev_s} ({(100*ev_s/ev_a if ev_a else 0):.1f}%)")
    print(f"PPO updates: {int(d.get('ppo_updates', 0) or 0)}")
    print(f"Gradient steps: {int(d.get('gradient_steps', 0) or 0)}")
    print(f"Transitions trained: {int(d.get('transitions_trained', 0) or 0)}")
    print(f"Initial policy hash: {str(d.get('initial_hash',''))[:16]}")
    print(f"Current policy hash: {rt.model_hash()[:16]}")
    summarize_rows(read_episode_rows(TRAIN_EPISODES), rt.cfg.stats_windows, "SELF-PLAY TRAINING CURVE")
    summarize_rows(read_episode_rows(EVAL_EPISODES), rt.cfg.stats_windows, "DETERMINISTIC EVALUATION CURVE")


def neural_verify(rt: NeuralRuntime) -> None:
    print("\n=== VERIFY NEURAL LEARNING ===")
    before_hash = rt.model_hash()
    tmp = AUDIT_DIR / "verify_reload.pt"
    rt.save_checkpoint(tmp)
    clone = ActorCritic(OBS_DIM, len(rt.move_steps), len(rt.hold_ms), rt.cfg.hidden_sizes).to(rt.device)
    ckpt = torch.load(tmp, map_location=rt.device)
    clone.load_state_dict(ckpt["state_dict"])
    h = hashlib.sha256()
    for name, tensor in sorted(clone.state_dict().items()):
        h.update(name.encode("utf-8")); arr = tensor.detach().cpu().contiguous().numpy(); h.update(str(arr.dtype).encode()); h.update(str(arr.shape).encode()); h.update(arr.tobytes())
    reload_hash = h.hexdigest()
    print(f"Checkpoint persistence: {'PASS' if reload_hash == before_hash else 'FAIL'} | {before_hash[:12]} -> {reload_hash[:12]}")

    rng = np.random.default_rng(5606)
    deterministic_pass = True
    finite_pass = True
    prob_pass = True
    for _ in range(64):
        obs = rng.uniform(-1, 1, size=(OBS_DIM,)).astype(np.float32)
        x = torch.as_tensor(obs, device=rt.device).unsqueeze(0)
        with torch.no_grad():
            ml, hl, v = rt.net(x)
            mp = torch.softmax(ml, -1); hp = torch.softmax(hl, -1)
            ref_m = int(torch.argmax(ml, -1).item()); ref_h = int(torch.argmax(hl, -1).item())
            for _rep in range(8):
                ml2, hl2, _v2 = rt.net(x)
                if int(torch.argmax(ml2, -1).item()) != ref_m or int(torch.argmax(hl2, -1).item()) != ref_h:
                    deterministic_pass = False
            finite_pass = finite_pass and bool(torch.isfinite(ml).all() and torch.isfinite(hl).all() and torch.isfinite(v).all())
            prob_pass = prob_pass and abs(float(mp.sum().item()) - 1.0) < 1e-5 and abs(float(hp.sum().item()) - 1.0) < 1e-5
    print(f"Deterministic argmax repeatability: {'PASS' if deterministic_pass else 'FAIL'}")
    print(f"Finite network outputs: {'PASS' if finite_pass else 'FAIL'}")
    print(f"Categorical probabilities normalized: {'PASS' if prob_pass else 'FAIL'}")

    initial_hash = str(rt.stats.data.get("initial_hash", ""))
    updates = int(rt.stats.data.get("ppo_updates", 0) or 0)
    changed_from_initial = bool(initial_hash and before_hash != initial_hash)
    print(f"Training evidence: PPO updates={updates} | weights differ from initial={'YES' if changed_from_initial else 'NO'}")

    # Prove backprop/optimizer wiring on a disposable clone. Production weights are untouched.
    test_net = ActorCritic(OBS_DIM, len(rt.move_steps), len(rt.hold_ms), rt.cfg.hidden_sizes).to(rt.device)
    test_net.load_state_dict(rt.net.state_dict())
    test_opt = torch.optim.Adam(test_net.parameters(), lr=rt.cfg.learning_rate)
    x = torch.randn(32, OBS_DIM, device=rt.device)
    ma = torch.randint(0, len(rt.move_steps), (32,), device=rt.device)
    ha = torch.randint(0, len(rt.hold_ms), (32,), device=rt.device)
    old = {k: v.detach().clone() for k, v in test_net.state_dict().items()}
    lp, ent, val, _ml, _hl = test_net.evaluate_actions(x, ma, ha)
    loss = -(lp.mean()) + 0.25 * (val ** 2).mean() - 0.01 * ent.mean()
    test_opt.zero_grad(); loss.backward(); nn.utils.clip_grad_norm_(test_net.parameters(), 0.5); test_opt.step()
    changed = any(not torch.equal(old[k], test_net.state_dict()[k]) for k in old)
    print(f"Backprop + optimizer wiring on disposable clone: {'PASS' if changed else 'FAIL'}")
    try:
        tmp.unlink()
    except Exception:
        pass
    print("VERIFY checks software/model wiring. Real skill must still be proven with deterministic EVALUATION success rate over many attempts.")


def evaluate_prompt(rt: NeuralRuntime) -> None:
    raw = input("How many deterministic neural evaluation attempts? [25]: ").strip()
    try:
        n = int(raw) if raw else 25
    except Exception:
        n = 25
    n = max(1, min(5000, n))
    before_eval_rows = len(read_episode_rows(EVAL_EPISODES))
    run_neural(rt, learning=False, max_attempts=n)
    rows = read_episode_rows(EVAL_EPISODES)
    new = rows[before_eval_rows:]
    if new:
        succ = sum(int(float(r.get("success", 0) or 0)) for r in new)
        rate = succ / len(new)
        print(f"Batch evaluation: {succ}/{len(new)} = {rate*100:.1f}%")
        best = float(rt.stats.data.get("best_eval_rate", 0.0) or 0.0)
        if len(new) >= 10 and rate > best:
            rt.stats.data["best_eval_rate"] = rate
            rt.stats.save()
            rt.save_checkpoint(BEST_CKPT)
            print(f"New best deterministic evaluation rate -> saved {BEST_CKPT.name}")


def calibrate_neural(rt: NeuralRuntime) -> None:
    classic.calibrate_only(rt.classic_cfg, rt.calibration_model)


def reset_neural(rt: NeuralRuntime) -> bool:
    print("This deletes ONLY data\\neural (neural PPO weights/stats/audits). Classic v0.5 data/model/demos remain untouched.")
    ans = input("Type RESET NEURAL to continue: ").strip()
    if ans != "RESET NEURAL":
        print("Cancelled.")
        return False
    if NEURAL_DIR.exists():
        shutil.rmtree(NEURAL_DIR)
    for p in (NEURAL_DIR, CHECKPOINT_DIR, AUDIT_DIR):
        p.mkdir(parents=True, exist_ok=True)
    print("Neural data reset. Restart START_NEURAL.bat to create a fresh random PPO policy.")
    return True


def print_menu(rt: NeuralRuntime) -> None:
    print("\n======================================================")
    print(" LOCKPICK LEARNER v0.6 - REAL NEURAL PPO SELF-LEARNING")
    print("======================================================")
    print("1) SELF-PLAY TRAIN - neural PPO learns from its own attempts")
    print("2) EVALUATE        - deterministic neural policy, learning OFF")
    print("3) VERIFY NEURAL   - hashes / determinism / backprop wiring")
    print("4) NEURAL STATS")
    print("5) CALIBRATE")
    print("6) VISION DEBUG")
    print("7) START CLASSIC v0.5 MENU")
    print("8) RESET NEURAL MODEL")
    print("9) EXIT")
    print(f"Current neural hash: {rt.model_hash()[:12]} | device={rt.device} | PPO updates={int(rt.stats.data.get('ppo_updates',0) or 0)}")


def main() -> None:
    set_seeds(5606)
    classic_cfg = classic.Config.load()
    neural_cfg = NeuralConfig.load()
    set_seeds(neural_cfg.seed)
    rt = NeuralRuntime(classic_cfg, neural_cfg)
    print(f"PyTorch device: {rt.device} | torch={torch.__version__}")
    if rt.device.type == "cuda":
        try:
            print(f"GPU: {torch.cuda.get_device_name(rt.device)}")
        except Exception:
            pass
    else:
        print("CPU mode is fine for this small network. CUDA is optional.")

    while True:
        print_menu(rt)
        choice = input("Select: ").strip()
        try:
            if choice == "1":
                run_neural(rt, learning=True, max_attempts=None)
            elif choice == "2":
                evaluate_prompt(rt)
            elif choice == "3":
                neural_verify(rt)
            elif choice == "4":
                neural_stats(rt)
            elif choice == "5":
                calibrate_neural(rt)
            elif choice == "6":
                classic.vision_debug(rt.classic_cfg, rt.calibration_model)
            elif choice == "7":
                classic.main()
            elif choice == "8":
                if reset_neural(rt):
                    return
            elif choice == "9":
                rt.save_checkpoint(LATEST_CKPT)
                return
        except KeyboardInterrupt:
            print("\nInterrupted. Saving neural checkpoint.")
            rt.save_checkpoint(LATEST_CKPT)
        except Exception as e:
            print(f"\n[ERROR] {type(e).__name__}: {e}")
            try:
                rt.save_checkpoint(LATEST_CKPT)
            except Exception:
                pass


if __name__ == "__main__":
    main()
