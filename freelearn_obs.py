"""Shared FREELEARN observation/action contract (simulator <-> live SCUM).

The simulator trainer and the live in-game agent must build EXACTLY the same
observation vector and interpret the policy output EXACTLY the same way. If the
two drift apart, a policy that solves the simulation cannot solve the real lock,
no matter how good the simulated success rate looks.

This module owns that contract:

  raw history frame (5 channels, newest last, history_frames long)
    0  own X                     -> clip(x_phys / physical_max, 0, 1) * 2 - 1
    1  visible lock turn         -> clip(turn, 0, 1) * 2 - 1
    2  visible lock turn delta   -> clip((turn - prev_turn) * 8, -1, 1)
    3  F active this frame       -> f_active * 2 - 1     (TAP and HOLD both count)
    4  own executed X delta      -> clip(policy_delta / mouse_step_max, -1, 1)

  tail
    remaining time   (1)  -> clip(1 - elapsed / time_limit, 0, 1) * 2 - 1
    lock type onehot (4)
    board bounds     (5)  -> left, right, dist_left, dist_right, range_width
                             in the stable policy coordinate span

Nothing else. The hidden target center, ramp bounds and ramp depth are physics
only; the live agent cannot see them either, which is exactly the point: the
only in-game cue is the visible rotation of the lock cylinder.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple

import numpy as np

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "freelearn_config.json"
CKPT_DIR = ROOT / "checkpoints"
BEST_PATH = CKPT_DIR / "freelearn_best.pt"
LATEST_PATH = CKPT_DIR / "freelearn_latest.pt"

LOCK_NAMES = ["Rusted", "Basic", "Medium", "Enforced"]
LOCK_INDEX = {n: i for i, n in enumerate(LOCK_NAMES)}

# Checkpoint contract of the current MOVE / F TAP / F HOLD policy.
PHYSICS_CONTRACT = "static-f-tap-hold-bounds-v3"

MODE_MOVE = 0
MODE_TAP = 1
MODE_HOLD = 2
MODE_NAMES = {MODE_MOVE: "MOVE/RELEASE", MODE_TAP: "F TAP", MODE_HOLD: "F HOLD"}


def load_config(path: Path = CONFIG_PATH) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


@dataclass
class LockContract:
    """Everything the observation/action mapping needs for one lock type."""

    name: str
    index: int
    physical_max: float
    policy_span: float
    time_limit_sec: float
    frame_ms: int
    history_frames: int
    mouse_step_max: float
    success_turn: float
    turn_tau_ms: float
    return_tau_ms: float

    @property
    def dt(self) -> float:
        return self.frame_ms / 1000.0

    @property
    def coord_scale(self) -> float:
        """Physical board units per policy coordinate unit."""
        return self.physical_max / max(self.policy_span, 1e-6)

    @property
    def obs_dim(self) -> int:
        return self.history_frames * 5 + 1 + 4 + 5

    @staticmethod
    def from_config(cfg: dict, lock_name: str) -> "LockContract":
        if lock_name not in LOCK_INDEX:
            raise ValueError(f"unknown lock type {lock_name!r}")
        i = LOCK_INDEX[lock_name]
        spec = cfg["locks"][lock_name]
        tc = cfg["training"]
        tmpl = (spec.get("templates") or [{}])[0]
        return LockContract(
            name=lock_name,
            index=i,
            physical_max=float(spec.get("physical_max", 1.0)),
            policy_span=max(1e-4, float(spec.get("policy_span", 1.0 if i == 0 else 0.5))),
            time_limit_sec=float(spec.get("time_limit_sec", 3.0)),
            frame_ms=int(tc["frame_ms"]),
            history_frames=int(tc["history_frames"]),
            mouse_step_max=float(tc["mouse_step_max"]),
            success_turn=float(cfg.get("physics", {}).get("success_turn", 0.965)),
            turn_tau_ms=float(tmpl.get("turn_tau_ms", 280.0)),
            return_tau_ms=float(tmpl.get("return_tau_ms", 120.0)),
        )


class ObsBuilder:
    """Frame history -> policy observation, identical to LockBatchEnv.obs()."""

    def __init__(self, contract: LockContract):
        self.c = contract
        self.hist = np.zeros((contract.history_frames, 5), np.float32)
        self.prev_turn = 0.0
        self.pos = 0.0
        self.frames = 0
        self.reset()

    def reset(self, x_phys: float = 0.0, turn: float = 0.0) -> None:
        self.hist[:] = 0.0
        # Same initial raw frame the simulator writes on reset.
        self.hist[-1, 0] = -1.0
        self.hist[-1, 1] = -1.0
        self.hist[-1, 2] = 0.0
        self.hist[-1, 3] = -1.0
        self.hist[-1, 4] = 0.0
        self.pos = float(np.clip(x_phys, 0.0, self.c.physical_max))
        self.prev_turn = float(np.clip(turn, 0.0, 1.0))
        self.frames = 0

    def push(self, x_phys: float, turn: float, f_active: bool, move_phys: float,
             turn_delta: Optional[float] = None) -> None:
        """Append one executed 25 ms frame.

        x_phys      measured own position on the physical board (0..physical_max)
        turn        measured visible lock turn (0..1)
        f_active    F was physically down during this frame (TAP or HOLD)
        move_phys   X movement that actually happened this frame, physical units
        """
        turn = float(np.clip(turn, 0.0, 1.0))
        if turn_delta is None:
            turn_delta = turn - self.prev_turn
        self.pos = float(np.clip(x_phys, 0.0, self.c.physical_max))
        policy_move = float(move_phys) / max(self.c.coord_scale, 1e-6)

        self.hist[:-1] = self.hist[1:]
        self.hist[-1, 0] = np.clip(self.pos / max(self.c.physical_max, 1e-6), 0.0, 1.0) * 2.0 - 1.0
        self.hist[-1, 1] = turn * 2.0 - 1.0
        self.hist[-1, 2] = float(np.clip(turn_delta * 8.0, -1.0, 1.0))
        self.hist[-1, 3] = (1.0 if f_active else 0.0) * 2.0 - 1.0
        self.hist[-1, 4] = float(np.clip(policy_move / max(self.c.mouse_step_max, 1e-6), -1.0, 1.0))
        self.prev_turn = turn
        self.frames += 1

    def vector(self, elapsed_sec: float) -> np.ndarray:
        c = self.c
        remaining = float(np.clip(1.0 - elapsed_sec / max(c.time_limit_sec, 1e-6), 0.0, 1.0)) * 2.0 - 1.0
        onehot = np.zeros(4, np.float32)
        onehot[c.index] = 1.0
        policy_pos = (self.pos / max(c.physical_max, 1e-6)) * c.policy_span
        bounds = np.array([
            0.0,
            c.policy_span,
            float(np.clip(policy_pos, 0.0, 1.0)),
            float(np.clip(c.policy_span - policy_pos, 0.0, 1.0)),
            float(np.clip(c.policy_span, 0.0, 1.0)),
        ], np.float32)
        return np.concatenate([
            self.hist.reshape(-1),
            np.array([remaining], np.float32),
            onehot,
            bounds,
        ]).astype(np.float32)


def move_unit_to_physical(move_unit: float, contract: LockContract) -> float:
    """Beta action (0..1) -> signed physical X delta, exactly as in the simulator."""
    policy_delta = (float(move_unit) * 2.0 - 1.0) * contract.mouse_step_max
    return float(policy_delta * contract.coord_scale)


def checkpoint_info(path: Path) -> dict:
    """Read a checkpoint's metadata without building the network."""
    import torch
    ck = torch.load(path, map_location="cpu", weights_only=False)
    return {k: v for k, v in ck.items() if k not in ("model", "optimizer")}


def pick_checkpoint() -> Path:
    """Prefer the checkpoint that was actually trained against the live-vision model.

    BEST is scored on simulated success rate. A policy trained on a perfect
    sensor can hold a higher BEST score while being useless in game, so the
    live runner picks whichever file has trained longer under the live-vision
    observation model and only falls back to BEST on a tie.
    """
    candidates = [p for p in (BEST_PATH, LATEST_PATH) if p.exists()]
    if not candidates:
        return BEST_PATH
    if len(candidates) == 1:
        return candidates[0]
    scored = []
    for p in candidates:
        try:
            scored.append((int(checkpoint_info(p).get("vision_attempts", 0)), p))
        except Exception:
            scored.append((-1, p))
    scored.sort(key=lambda kv: kv[0], reverse=True)
    if scored[0][0] == scored[1][0]:
        return BEST_PATH
    return scored[0][1]


class PolicyRunner:
    """Loads a FREELEARN checkpoint and runs it one frame at a time."""

    def __init__(self, contract: LockContract, checkpoint: Optional[Path] = None,
                 device: str = "cpu", deterministic: bool = True):
        import torch  # local import so the vision/self-test paths stay light
        from freelearn_trainer import ActorCritic, policy as _policy

        # A 90-input MLP is fastest single-threaded, and the live loop must not
        # fight the OS scheduler for a 25 ms budget.
        try:
            torch.set_num_threads(1)
        except Exception:
            pass
        self._torch = torch
        self._policy = _policy
        self.c = contract
        self.deterministic = bool(deterministic)
        self.device = torch.device(device)

        path = Path(checkpoint) if checkpoint else pick_checkpoint()
        if not path.exists():
            raise FileNotFoundError(f"no FREELEARN checkpoint at {path}")
        ck = torch.load(path, map_location="cpu", weights_only=False)
        contract_id = str(ck.get("physics_contract", ""))
        ck_dim = int(ck.get("obs_dim", -1))
        if contract_id != PHYSICS_CONTRACT:
            raise RuntimeError(
                f"checkpoint {path.name} uses physics contract {contract_id!r}; "
                f"live play requires {PHYSICS_CONTRACT!r}. Train with the current trainer first."
            )
        if ck_dim != contract.obs_dim:
            raise RuntimeError(
                f"checkpoint obs_dim {ck_dim} != contract obs_dim {contract.obs_dim}. "
                "freelearn_config.json history_frames does not match the checkpoint."
            )
        ck_frame = int(ck.get("frame_ms", contract.frame_ms))
        if ck_frame != contract.frame_ms:
            raise RuntimeError(
                f"checkpoint frame_ms {ck_frame} != config frame_ms {contract.frame_ms}; "
                "the live control loop would run at a different rate than training."
            )
        self.model = ActorCritic(contract.obs_dim).to(self.device)
        self.model.load_state_dict(ck["model"])
        self.model.eval()
        self.path = path
        self.attempts = int(ck.get("attempts", 0))
        self.best_score = float(ck.get("best_score", 0.0))
        self.vision_attempts = int(ck.get("vision_attempts", 0))

    def act(self, obs: np.ndarray, f_down: bool) -> Tuple[float, int, float]:
        torch = self._torch
        with torch.inference_mode():
            t_obs = torch.from_numpy(np.asarray(obs, np.float32).reshape(1, -1)).to(self.device)
            t_f = torch.tensor([1.0 if f_down else 0.0], dtype=torch.float32, device=self.device)
            move, mode, _logp, value = self._policy(
                self.model, t_obs, deterministic=self.deterministic, old_f_down=t_f
            )
        return float(move.item()), int(mode.item()), float(value.item())

    def physical_delta(self, move_unit: float) -> float:
        return move_unit_to_physical(move_unit, self.c)
