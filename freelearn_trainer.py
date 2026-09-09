from __future__ import annotations

import argparse, csv, json, math, os, random, signal, sys, time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.distributions import Beta, Categorical

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
CKPT = ROOT / "checkpoints"
CONFIG_PATH = ROOT / "freelearn_config.json"
TELEMETRY_PATH = DATA / "freelearn_telemetry.json"
PROGRESS_PATH = DATA / "freelearn_progress.csv"
SHOWCASE_PATH = DATA / "freelearn_showcase.json"
SHOWCASE_REQUEST = DATA / "showcase_request.flag"
MODEL_PATH = CKPT / "freelearn_latest.pt"
BEST_PATH = CKPT / "freelearn_best.pt"
REALITY_PROFILE_PATH = DATA / "real_bridge" / "fit_profile.json"


def load_reality_profile() -> dict:
    try:
        raw = json.loads(REALITY_PROFILE_PATH.read_text(encoding="utf-8"))
        return raw if isinstance(raw, dict) else {}
    except Exception:
        return {}

LOCK_NAMES = ["Rusted", "Basic", "Medium", "Enforced"]
LOCK_INDEX = {n:i for i,n in enumerate(LOCK_NAMES)}


def atomic_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def load_config() -> dict:
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def set_seeds(seed: int) -> None:
    random.seed(seed); np.random.seed(seed); torch.manual_seed(seed)


class ActorCritic(nn.Module):
    def __init__(self, obs_dim: int):
        super().__init__()
        self.trunk = nn.Sequential(
            nn.Linear(obs_dim, 256), nn.Tanh(),
            nn.Linear(256, 256), nn.Tanh(),
            nn.Linear(256, 192), nn.Tanh(),
        )
        self.move_ab = nn.Linear(192, 2)
        # Action mode: 0=MOVE/RELEASE, 1=F TAP, 2=F HOLD.
        # HOLD length is not predefined: the policy chooses HOLD again every frame,
        # so duration is learned freely in frame_ms increments.
        self.mode_logits = nn.Linear(192, 3)
        self.value = nn.Linear(192, 1)
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.orthogonal_(m.weight, gain=math.sqrt(2))
                nn.init.zeros_(m.bias)
        nn.init.orthogonal_(self.move_ab.weight, gain=0.01)
        nn.init.orthogonal_(self.mode_logits.weight, gain=0.01)
        nn.init.orthogonal_(self.value.weight, gain=1.0)

    def forward(self, obs: torch.Tensor):
        h = self.trunk(obs)
        ab = F.softplus(self.move_ab(h)) + 1.05
        alpha, beta = ab[:, 0], ab[:, 1]
        mode_logits = self.mode_logits(h)
        value = self.value(h).squeeze(-1)
        return alpha, beta, mode_logits, value


@dataclass
class Rollout:
    obs: np.ndarray
    move: np.ndarray
    mode_action: np.ndarray
    move_active: np.ndarray
    old_f_down: np.ndarray
    logp: np.ndarray
    value: np.ndarray
    reward: np.ndarray
    done: np.ndarray
    next_value: np.ndarray


class LockBatchEnv:
    """Vectorized simulator with intentionally minimal agent information.

    Agent observation contains only raw sensor/control history:
      - own horizontal position
      - observable lock turn
      - observable frame-to-frame lock response (turn delta)
      - whether a persistent F HOLD is currently down
      - previous mouse delta
      - remaining time
      - visible lock type one-hot
      - known physical X bounds: left/right edge, distance to each edge, range width

    The response delta is not hidden geometry: it is the same visual motion cue
    the agent could infer from consecutive game frames. Hidden ramp/target values
    remain physics-only.

    Hidden target/ramp/template values never enter the observation.
    """
    def __init__(self, cfg: dict, n: int, seed: int):
        self.cfg = cfg
        self.n = int(n)
        self.rng = np.random.default_rng(seed)
        self.frame_ms = int(cfg["training"]["frame_ms"])
        self.dt = self.frame_ms / 1000.0
        self.hist_frames = int(cfg["training"]["history_frames"])
        self.mouse_step_max = float(cfg["training"]["mouse_step_max"])
        self.raw_hist = np.zeros((self.n, self.hist_frames, 5), np.float32)
        self.lock_type = np.zeros(self.n, np.int64)
        self.template_idx = np.zeros(self.n, np.int64)
        # Physical X is always the real full lock board (normally 0..1).
        # policy_span is a stable neural coordinate span used only for checkpoint-compatible
        # observations/action scaling. Rusted uses 1.0; player locks default to legacy 0.5.
        # This decouples real movement bounds from the neural coordinate system.
        self.allowed_max = np.ones(self.n, np.float32)  # physical max, exported to UI
        self.policy_span = np.ones(self.n, np.float32)
        self.time_limit = np.ones(self.n, np.float32) * 3.0
        self.elapsed = np.zeros(self.n, np.float32)
        self.pos = np.zeros(self.n, np.float32)
        self.turn = np.zeros(self.n, np.float32)
        self.f_down = np.zeros(self.n, np.float32)
        self.prev_mouse = np.zeros(self.n, np.float32)
        self.center = np.zeros(self.n, np.float32)
        self.target_half = np.zeros(self.n, np.float32)
        self.ramp_left = np.zeros(self.n, np.float32)
        self.ramp_right = np.zeros(self.n, np.float32)
        self.curve_exp = np.ones(self.n, np.float32)
        self.turn_tau = np.ones(self.n, np.float32) * 0.3
        self.return_tau = np.ones(self.n, np.float32) * 0.12
        self.episode_success = np.zeros(self.n, np.bool_)
        self.non_target_presses = np.zeros(self.n, np.int32)
        self.total_presses = np.zeros(self.n, np.int32)
        self.pick_wear = np.zeros(self.n, np.float32)
        self.pick_break_budget = np.ones(self.n, np.float32) * 9999.0
        self.off_target_f_sec = np.zeros(self.n, np.float32)
        self.hold_run_sec = np.zeros(self.n, np.float32)
        self.last_turn_delta = np.zeros(self.n, np.float32)
        self.last_cap = np.zeros(self.n, np.float32)
        self.last_press_edge = np.zeros(self.n, np.bool_)
        self.last_pick_broken = np.zeros(self.n, np.bool_)
        self.last_time_cap_broken = np.zeros(self.n, np.bool_)
        self.last_action_mode = np.zeros(self.n, np.int8)
        self.last_move_blocked = np.zeros(self.n, np.bool_)
        self.last_requested_mouse = np.zeros(self.n, np.float32)
        # REAL<->SIM bridge. These are observable-physics corrections learned from
        # SCUM screen data. They never contain target centers or expose hidden geometry.
        self.reality_profile = load_reality_profile()
        self.ramp_gain = np.ones(self.n, np.float32)
        self.sensor_noise = np.zeros(self.n, np.float32)
        # LIVE VISION REALISM (sim -> SCUM transfer). The live agent reads the
        # lock turn and its own X off the screen, so it never sees the clean
        # values the simulator knows. These per-attempt distortions model exactly
        # that measurement chain: capture latency, an occasional duplicated
        # frame, turn-span calibration error, angle quantization, sensor noise
        # and imperfect mouse gain. They touch ONLY what the policy observes and
        # how far the mouse actually lands; hidden geometry, the turn physics and
        # the success condition stay exact.
        self.vision_cfg = dict(cfg.get("vision", {}) or {})
        self.vision_enabled = bool(self.vision_cfg.get("enabled", True))
        self.max_latency = int(np.clip(int(self.vision_cfg.get("obs_latency_frames_max", 2)), 0, 6))
        self.vision_scale = 1.0
        self.v_latency = np.zeros(self.n, np.int64)
        self.v_turn_gain = np.ones(self.n, np.float32)
        self.v_turn_offset = np.zeros(self.n, np.float32)
        self.v_turn_quant = np.zeros(self.n, np.float32)
        self.v_turn_noise = np.zeros(self.n, np.float32)
        self.v_stale_p = np.zeros(self.n, np.float32)
        self.v_x_noise = np.zeros(self.n, np.float32)
        self.v_x_bias = np.zeros(self.n, np.float32)
        self.v_x_quant = np.zeros(self.n, np.float32)
        self.v_move_gain = np.ones(self.n, np.float32)
        self.v_move_noise = np.zeros(self.n, np.float32)
        self.turn_buf = np.zeros((self.n, self.max_latency + 2), np.float32)
        self.pos_buf = np.zeros((self.n, self.max_latency + 2), np.float32)
        self.obs_turn_prev = np.zeros(self.n, np.float32)
        self.obs_pos_prev = np.zeros(self.n, np.float32)
        self.total_steps = 0
        self.reset(np.arange(self.n, dtype=np.int64), balanced=True)

    @property
    def obs_dim(self):
        # Existing v0.17.2 inputs + 5 explicit, non-hidden physical board-boundary features.
        return self.hist_frames * 5 + 1 + 4 + 5

    def update_config(self, cfg: dict):
        # Geometry/template edits and showcase cadence are hot-reloadable.
        # Network-shape/time-step edits intentionally require trainer restart.
        self.cfg = cfg

    def update_reality_profile(self, profile: dict | None = None):
        self.reality_profile = profile if isinstance(profile, dict) else load_reality_profile()

    def _assign_specs(self, ids: np.ndarray, balanced: bool=False):
        m = len(ids)
        if balanced:
            lt = np.arange(m, dtype=np.int64) % 4
            self.rng.shuffle(lt)
        else:
            lt = self.rng.integers(0, 4, size=m, endpoint=False)
        self.lock_type[ids] = lt
        for li, name in enumerate(LOCK_NAMES):
            sub = ids[lt == li]
            if len(sub) == 0: continue
            spec = self.cfg["locks"][name]
            temps = spec["templates"]
            # v0.18.0: SCUM-style fixed geometry per lock type.
            # Only the target CENTER moves between attempts; ramp/target size and response curve
            # stay constant for that lock type. Always use template 0 even if an old config
            # accidentally contains legacy B/C/D/E variants.
            ti = np.zeros(len(sub), dtype=np.int64)
            self.template_idx[sub] = 0
            # v0.17.6.1 coordinate bridge:
            # - physical board remains full 0..1 (unless explicitly overridden),
            # - neural player-lock coordinate span remains the legacy 0..0.5.
            # Hidden geometry values in config are legacy-coordinate widths and are
            # converted into physical full-board widths by physical_max/policy_span.
            physical_max = float(spec.get("physical_max", 1.0))
            policy_span = float(spec.get("policy_span", 1.0 if li == 0 else 0.5))
            policy_span = max(1e-4, policy_span)
            self.allowed_max[sub] = physical_max
            self.policy_span[sub] = policy_span
            self.time_limit[sub] = float(spec["time_limit_sec"])
            for j, env_id in enumerate(sub):
                t = temps[int(ti[j])]
                scale = float(self.allowed_max[env_id] / max(self.policy_span[env_id], 1e-6))
                self.target_half[env_id] = float(t["target_half"]) * scale
                self.ramp_left[env_id] = float(t["ramp_left"]) * scale
                self.ramp_right[env_id] = float(t["ramp_right"]) * scale
                self.curve_exp[env_id] = float(t["curve_exp"])
                rp = self.reality_profile.get("locks", {}).get(name, {}) if isinstance(self.reality_profile, dict) else {}
                use_real = bool(rp.get("enabled", False))
                tau_scale = float(rp.get("turn_tau_scale", 1.0)) if use_real else 1.0
                return_scale = float(rp.get("return_tau_scale", 1.0)) if use_real else 1.0
                self.ramp_gain[env_id] = float(np.clip(rp.get("ramp_gain", 1.0), 0.50, 1.50)) if use_real else 1.0
                self.sensor_noise[env_id] = float(np.clip(rp.get("sensor_noise", 0.0), 0.0, 0.12)) if use_real else 0.0
                self.turn_tau[env_id] = max(0.02, float(t["turn_tau_ms"]) * tau_scale / 1000.0)
                self.return_tau[env_id] = max(0.02, float(t["return_tau_ms"]) * return_scale / 1000.0)
                self.center[env_id] = float(self.rng.uniform(0.0, self.allowed_max[env_id]))

    def _sample_vision(self, ids: np.ndarray):
        """Draw one live-vision measurement profile per attempt."""
        m = len(ids)
        if m == 0:
            return
        s = float(np.clip(self.vision_scale, 0.0, 1.0)) if self.vision_enabled else 0.0
        if s <= 0.0:
            self.v_latency[ids] = 0
            self.v_turn_gain[ids] = 1.0
            self.v_turn_offset[ids] = 0.0
            self.v_turn_quant[ids] = 0.0
            self.v_turn_noise[ids] = 0.0
            self.v_stale_p[ids] = 0.0
            self.v_x_noise[ids] = 0.0
            self.v_x_bias[ids] = 0.0
            self.v_x_quant[ids] = 0.0
            self.v_move_gain[ids] = 1.0
            self.v_move_noise[ids] = 0.0
            return
        vc = self.vision_cfg
        rng = self.rng
        if self.max_latency > 0:
            lat = rng.integers(0, self.max_latency + 1, size=m)
            self.v_latency[ids] = np.where(rng.random(m) < s, lat, 0)
        else:
            self.v_latency[ids] = 0
        gain_e = float(vc.get("turn_gain_error", 0.10)) * s
        self.v_turn_gain[ids] = rng.uniform(1.0 - gain_e, 1.0 + gain_e, m).astype(np.float32)
        off_e = float(vc.get("turn_offset_error", 0.03)) * s
        self.v_turn_offset[ids] = rng.uniform(-off_e, off_e, m).astype(np.float32)
        self.v_turn_quant[ids] = rng.uniform(0.0, max(0.0, float(vc.get("turn_quant", 0.012))) * s, m).astype(np.float32)
        self.v_turn_noise[ids] = rng.uniform(0.0, max(0.0, float(vc.get("turn_noise", 0.010))) * s, m).astype(np.float32)
        self.v_stale_p[ids] = rng.uniform(0.0, max(0.0, float(vc.get("stale_frame_prob", 0.06))) * s, m).astype(np.float32)
        self.v_x_noise[ids] = rng.uniform(0.0, max(0.0, float(vc.get("x_noise", 0.004))) * s, m).astype(np.float32)
        xb = float(vc.get("x_bias", 0.006)) * s
        self.v_x_bias[ids] = rng.uniform(-xb, xb, m).astype(np.float32)
        self.v_x_quant[ids] = rng.uniform(0.0, max(0.0, float(vc.get("x_quant", 0.004))) * s, m).astype(np.float32)
        mg = float(vc.get("move_gain_error", 0.10)) * s
        self.v_move_gain[ids] = rng.uniform(1.0 - mg, 1.0 + mg, m).astype(np.float32)
        self.v_move_noise[ids] = rng.uniform(0.0, max(0.0, float(vc.get("move_noise", 0.003))) * s, m).astype(np.float32)

    def _observe(self) -> Tuple[np.ndarray, np.ndarray]:
        """True lock state -> what a live screen reader would report this frame."""
        self.turn_buf[:, 1:] = self.turn_buf[:, :-1]
        self.pos_buf[:, 1:] = self.pos_buf[:, :-1]
        self.turn_buf[:, 0] = self.turn
        self.pos_buf[:, 0] = self.pos
        idx = np.arange(self.n)
        t = self.turn_buf[idx, self.v_latency].copy()
        p = self.pos_buf[idx, self.v_latency].copy()
        if self.vision_enabled:
            t = t * self.v_turn_gain + self.v_turn_offset
            p = p + self.v_x_bias
            if np.any(self.v_turn_noise > 0):
                t = t + self.rng.normal(0.0, 1.0, self.n).astype(np.float32) * self.v_turn_noise
            if np.any(self.v_x_noise > 0):
                p = p + self.rng.normal(0.0, 1.0, self.n).astype(np.float32) * self.v_x_noise
            qt = self.v_turn_quant > 1e-6
            if np.any(qt):
                step = np.maximum(self.v_turn_quant, 1e-6)
                t = np.where(qt, np.round(t / step) * step, t)
            qx = self.v_x_quant > 1e-6
            if np.any(qx):
                step = np.maximum(self.v_x_quant, 1e-6)
                p = np.where(qx, np.round(p / step) * step, p)
            stale = self.rng.random(self.n).astype(np.float32) < self.v_stale_p
            if np.any(stale):
                t = np.where(stale, self.obs_turn_prev, t)
                p = np.where(stale, self.obs_pos_prev, p)
        t = np.clip(t, 0.0, 1.0).astype(np.float32)
        p = np.clip(p, 0.0, self.allowed_max).astype(np.float32)
        return t, p

    def reset(self, ids: np.ndarray, balanced: bool=False):
        if len(ids) == 0: return
        self._assign_specs(ids, balanced=balanced)
        self._sample_vision(ids)
        self.turn_buf[ids] = 0.0
        self.pos_buf[ids] = 0.0
        self.obs_turn_prev[ids] = 0.0
        self.obs_pos_prev[ids] = 0.0
        self.elapsed[ids] = 0.0
        self.pos[ids] = 0.0
        self.turn[ids] = 0.0
        self.f_down[ids] = 0.0
        self.prev_mouse[ids] = 0.0
        self.episode_success[ids] = False
        self.non_target_presses[ids] = 0
        self.total_presses[ids] = 0
        self.pick_wear[ids] = 0.0
        self.off_target_f_sec[ids] = 0.0
        self.hold_run_sec[ids] = 0.0
        self.last_turn_delta[ids] = 0.0
        self.last_cap[ids] = 0.0
        self.last_press_edge[ids] = False
        self.last_pick_broken[ids] = False
        self.last_time_cap_broken[ids] = False
        self.last_action_mode[ids] = 0
        self.last_move_blocked[ids] = False
        self.last_requested_mouse[ids] = 0.0

        pe = self.cfg.get("physics", {}).get("player_efficiency", {})
        bmin = float(pe.get("pick_break_budget_min", 6.0))
        bmax = max(bmin, float(pe.get("pick_break_budget_max", 8.0)))
        player = self.lock_type[ids] > 0
        self.pick_break_budget[ids] = 9999.0
        if np.any(player):
            pids = ids[player]
            self.pick_break_budget[pids] = self.rng.uniform(bmin, bmax, size=len(pids)).astype(np.float32)

        self.raw_hist[ids] = 0.0
        # Initial raw state: X, turn, turn-delta, F, mouse-delta.
        self.raw_hist[ids, -1, 0] = -1.0
        self.raw_hist[ids, -1, 1] = -1.0
        self.raw_hist[ids, -1, 2] = 0.0
        self.raw_hist[ids, -1, 3] = -1.0
        self.raw_hist[ids, -1, 4] = 0.0

    def obs(self) -> np.ndarray:
        hist = self.raw_hist.reshape(self.n, -1)
        remaining = np.clip(1.0 - self.elapsed / np.maximum(self.time_limit, 1e-6), 0.0, 1.0)
        remaining = remaining * 2.0 - 1.0
        onehot = np.zeros((self.n, 4), np.float32)
        onehot[np.arange(self.n), self.lock_type] = 1.0

        # KNOWN BOARD LIMITS in a stable POLICY coordinate system. This is only a
        # coordinate transform, not hidden information. Physical X is full 0..1, but
        # player locks default to the legacy neural span 0..0.5 so existing checkpoints
        # keep the same input distribution they learned before the soft-50% update.
        left_bound = np.zeros(self.n, np.float32)
        right_bound = self.policy_span.astype(np.float32)
        policy_pos = (self.pos / np.maximum(self.allowed_max, 1e-6)) * self.policy_span
        dist_left = np.clip(policy_pos - left_bound, 0.0, 1.0).astype(np.float32)
        dist_right = np.clip(right_bound - policy_pos, 0.0, 1.0).astype(np.float32)
        range_width = np.clip(right_bound - left_bound, 0.0, 1.0).astype(np.float32)
        bounds = np.stack([left_bound, right_bound, dist_left, dist_right, range_width], axis=1)

        return np.concatenate([hist, remaining[:, None].astype(np.float32), onehot, bounds], axis=1).astype(np.float32)

    def spatial_cap(self) -> np.ndarray:
        d = self.pos - self.center
        ad = np.abs(d)
        inside = ad <= self.target_half
        cap = np.zeros(self.n, np.float32)
        cap[inside] = 1.0
        left = d < -self.target_half
        if np.any(left):
            q = (-d[left] - self.target_half[left]) / np.maximum(self.ramp_left[left], 1e-6)
            ok = q < 1.0
            vals = np.zeros(len(q), np.float32)
            vals[ok] = np.power(np.clip(1.0 - q[ok], 0.0, 1.0), self.curve_exp[left][ok]).astype(np.float32)
            cap[left] = vals
        right = d > self.target_half
        if np.any(right):
            q = (d[right] - self.target_half[right]) / np.maximum(self.ramp_right[right], 1e-6)
            ok = q < 1.0
            vals = np.zeros(len(q), np.float32)
            vals[ok] = np.power(np.clip(1.0 - q[ok], 0.0, 1.0), self.curve_exp[right][ok]).astype(np.float32)
            cap[right] = vals
        # Reality bridge may calibrate how deep the visible ramp response is, but
        # target stays exactly 1.0 and fixed geometry widths are never altered here.
        ramp_only = (cap > 1e-6) & (cap < 0.999)
        if np.any(ramp_only):
            cap[ramp_only] = np.clip(cap[ramp_only] * self.ramp_gain[ramp_only], 0.0, 0.995)
        return cap

    def step(self, move_unit: np.ndarray, mode_action: np.ndarray):
        # Explicit free-learn action modes:
        #   0 = MOVE / RELEASE F
        #   1 = F TAP (one static frame, then F is UP again)
        #   2 = F HOLD (keeps F down; duration is chosen by repeating HOLD frames)
        #
        # Physical SCUM rule remains hard: X can move only on a full frame where
        # F was already UP and the policy selected MOVE. TAP, HOLD, and the
        # release frame all lock X completely. There is no move-while-F scan.
        # Policy chooses movement in the stable legacy coordinate span. Convert that
        # delta to physical full-board X so v0.17.5/v0.17.6 checkpoints keep the same
        # relative movement semantics after removing the 50% hard movement limit.
        requested_signed_policy = (move_unit.astype(np.float32) * 2.0 - 1.0) * self.mouse_step_max
        coord_scale = self.allowed_max / np.maximum(self.policy_span, 1e-6)
        requested_signed = (requested_signed_policy * coord_scale).astype(np.float32)
        old_turn = self.turn.copy()
        old_f = self.f_down > 0.5
        mode = np.clip(mode_action.astype(np.int64), 0, 2)

        # TAP is invalid while a persistent HOLD is already active. The policy
        # masks this choice; this fallback makes the simulator safe if a bad
        # checkpoint or external caller still sends it.
        invalid_tap = old_f & (mode == 1)
        mode = np.where(invalid_tap, 2, mode).astype(np.int64)

        move_cmd = mode == 0
        tap_cmd = mode == 1
        hold_cmd = mode == 2
        release_edge = old_f & move_cmd
        movement_allowed = (~old_f) & move_cmd
        signed = np.where(movement_allowed, requested_signed, 0.0).astype(np.float32)
        # Real mouse input does not land exactly where the policy asked: SCUM
        # sensitivity, calibration gain error and per-move jitter all apply.
        if self.vision_enabled:
            signed = signed * self.v_move_gain
            if np.any(self.v_move_noise > 0):
                jitter = self.rng.normal(0.0, 1.0, self.n).astype(np.float32) * self.v_move_noise * coord_scale
                signed = signed + np.where(movement_allowed, jitter, 0.0).astype(np.float32)
            signed = signed.astype(np.float32)
        self.last_move_blocked = (~movement_allowed & (np.abs(requested_signed) > 1e-7)).astype(np.bool_)
        self.last_requested_mouse = requested_signed.astype(np.float32)
        self.pos = np.clip(self.pos + signed, 0.0, self.allowed_max)

        # F is physically active for TAP or HOLD this frame. TAP is atomic: it
        # returns to UP for the next frame. HOLD persists until MOVE/RELEASE.
        active_f = tap_cmd | hold_cmd
        press_edge = active_f & ~old_f
        self.f_down = hold_cmd.astype(np.float32)
        self.last_action_mode = mode.astype(np.int8)

        # Hidden physical lock depth at the current STATIC X. 0=dead, 0..1=ramp,
        # 1=target. The policy never receives this value directly.
        cap = self.spatial_cap()
        self.last_cap = cap.copy()

        if np.any(active_f):
            k = 1.0 - np.exp(-self.dt / np.maximum(self.turn_tau[active_f], 1e-4))
            self.turn[active_f] += (cap[active_f] - self.turn[active_f]) * k.astype(np.float32)
        inactive = ~active_f
        if np.any(inactive):
            self.turn[inactive] *= np.exp(-self.dt / np.maximum(self.return_tau[inactive], 1e-4)).astype(np.float32)
        self.turn = np.clip(self.turn, 0.0, 1.0)
        turn_delta = self.turn - old_turn
        self.last_turn_delta = turn_delta.copy()

        self.elapsed += self.dt
        self.total_steps += self.n

        phys = self.cfg["physics"]
        pe = phys.get("player_efficiency", {})
        player = self.lock_type > 0
        target_zone = cap >= 0.999
        ramp_zone = (cap > 1e-6) & ~target_zone
        dead_zone = cap <= 1e-6
        non_target_edge = press_edge & player & ~target_zone

        self.total_presses += press_edge.astype(np.int32)
        self.non_target_presses += non_target_edge.astype(np.int32)

        # Consecutive HOLD timer is telemetry only; it is not an observation or
        # a scripted duration choice. The neural controls it by HOLD/RELEASE.
        self.hold_run_sec = np.where(hold_cmd, np.where(old_f, self.hold_run_sec + self.dt, self.dt), 0.0).astype(np.float32)

        # Player-lock F economy. Besides the 6..8-ish randomized wear model,
        # cumulative F-active time outside target has a hard cap (default 1.0 s).
        # Five 200 ms off-target holds therefore consume the full budget. Short
        # taps consume only their actual frame time. Rusted is exempt.
        if bool(pe.get("enabled", True)):
            edge_damage = np.zeros(self.n, np.float32)
            edge_damage += (press_edge & player & dead_zone).astype(np.float32) * float(pe.get("dead_press_damage", 1.0))
            edge_damage += (press_edge & player & ramp_zone).astype(np.float32) * float(pe.get("ramp_press_damage", 0.65))
            hold_damage = np.zeros(self.n, np.float32)
            hold_damage += (active_f & player & dead_zone).astype(np.float32) * float(pe.get("hold_damage_per_sec_dead", 0.55)) * self.dt
            hold_damage += (active_f & player & ramp_zone).astype(np.float32) * float(pe.get("hold_damage_per_sec_ramp", 0.32)) * self.dt
            self.pick_wear += edge_damage + hold_damage
            self.off_target_f_sec += (active_f & player & ~target_zone).astype(np.float32) * self.dt

        success = self.turn >= float(phys["success_turn"])
        pick_break_enabled = bool(pe.get("enabled", True)) and bool(pe.get("pick_break_enabled", True))
        if pick_break_enabled:
            wear_broken = player & (self.pick_wear >= self.pick_break_budget) & ~success
            max_off = max(self.dt, float(pe.get("max_off_target_f_sec", 1.0)))
            time_broken = player & (self.off_target_f_sec >= max_off - 1e-4) & ~success
            broken = wear_broken | time_broken
        else:
            time_broken = np.zeros(self.n, np.bool_)
            broken = np.zeros(self.n, np.bool_)
        timeout = self.elapsed >= self.time_limit
        done = success | timeout | broken

        # Potential shaping uses only visible lock turn. Hidden geometry never
        # enters the observation. Short off-target F use is additionally rewarded
        # by charging only actual F-active time and by the success efficiency bonus.
        gamma = float(self.cfg["training"]["gamma"])
        reward = float(phys["turn_reward_scale"]) * (gamma * self.turn - old_turn)
        reward -= float(phys["step_penalty"])

        if bool(pe.get("enabled", True)):
            reward -= (press_edge & player & dead_zone).astype(np.float32) * float(pe.get("press_penalty_dead", 0.035))
            reward -= (press_edge & player & ramp_zone).astype(np.float32) * float(pe.get("press_penalty_ramp", 0.018))
            reward -= (active_f & player & ~target_zone).astype(np.float32) * self.dt * float(pe.get("off_target_time_penalty_per_sec", 0.35))

        reward += success.astype(np.float32) * float(phys["success_reward"])

        if bool(pe.get("enabled", True)):
            goal = max(1, int(pe.get("soft_goal_non_target_presses", 8)))
            eff = np.clip((goal - self.non_target_presses).astype(np.float32) / float(goal), 0.0, 1.0)
            reward += success.astype(np.float32) * eff * float(pe.get("success_efficiency_bonus", 3.0))
            excess = np.maximum(self.non_target_presses - goal, 0).astype(np.float32)
            reward -= success.astype(np.float32) * excess * float(pe.get("success_over_goal_penalty", 0.20))

            # SOFT first-half priority for player locks. This is deliberately NOT
            # a movement limit and it does not reveal hidden target/ramp geometry.
            # A player-lock success inside the preferred left-side fraction earns
            # an extra terminal bonus; a success outside still gets the full normal
            # success + efficiency reward. This makes "search the first 50% well,
            # then continue if needed" the rational learned policy without hard coding it.
            pref_frac = float(np.clip(pe.get("preferred_search_fraction", 0.50), 0.05, 0.95))
            preferred_success = success & player & (self.pos <= self.allowed_max * pref_frac + 1e-7)
            reward += preferred_success.astype(np.float32) * float(pe.get("preferred_region_success_bonus", 2.0))

        reward -= (timeout & ~success).astype(np.float32) * float(phys["timeout_penalty"])
        reward -= broken.astype(np.float32) * float(phys.get("pick_break_penalty", 1.5))
        reward -= time_broken.astype(np.float32) * float(pe.get("off_target_time_break_extra_penalty", 3.0))

        self.raw_hist[:, :-1] = self.raw_hist[:, 1:]
        # Screen-measured X and lock turn, not the exact simulator state.
        obs_turn, obs_pos = self._observe()
        obs_delta = (obs_turn - self.obs_turn_prev).astype(np.float32)
        self.obs_turn_prev = obs_turn.copy()
        self.obs_pos_prev = obs_pos.copy()
        pos_norm = np.clip(obs_pos / np.maximum(self.allowed_max, 1e-6), 0.0, 1.0) * 2.0 - 1.0
        signed_policy = signed / np.maximum(coord_scale, 1e-6)
        mouse_norm = np.clip(signed_policy / max(self.mouse_step_max, 1e-6), -1.0, 1.0)
        # Raw channels: X, visible turn, visible turn delta, F-active-this-frame,
        # own ACTUAL mouse movement. A TAP is visible in history as an F-active
        # frame even though persistent self.f_down is UP on the next decision.
        self.raw_hist[:, -1, 0] = pos_norm
        # Reality-calibrated sensor noise is applied only to what the neural sees,
        # not to hidden physics or the success condition.
        if np.any(self.sensor_noise > 0):
            nturn = self.rng.normal(0.0, self.sensor_noise, size=self.n).astype(np.float32)
            ndelta = self.rng.normal(0.0, self.sensor_noise * 0.30, size=self.n).astype(np.float32)
        else:
            nturn = 0.0
            ndelta = 0.0
        vis_turn = np.clip(obs_turn + nturn, 0.0, 1.0)
        vis_delta = obs_delta + ndelta
        self.raw_hist[:, -1, 1] = vis_turn * 2.0 - 1.0
        self.raw_hist[:, -1, 2] = np.clip(vis_delta * 8.0, -1.0, 1.0)
        self.raw_hist[:, -1, 3] = active_f.astype(np.float32) * 2.0 - 1.0
        self.raw_hist[:, -1, 4] = mouse_norm
        self.prev_mouse = signed
        self.episode_success |= success
        self.last_press_edge = press_edge.copy()
        self.last_pick_broken = broken.copy()
        self.last_time_cap_broken = time_broken.copy()
        return reward.astype(np.float32), done.astype(np.bool_), success.astype(np.bool_)

    def hidden_geometry(self, i: int) -> dict:
        name = LOCK_NAMES[int(self.lock_type[i])]
        temp = self.cfg["locks"][name]["templates"][int(self.template_idx[i])]
        return {
            "lock": name,
            "template": temp["name"],
            "allowed_max": float(self.allowed_max[i]),
            "policy_span": float(self.policy_span[i]),
            "geometry_scale": float(self.allowed_max[i] / max(self.policy_span[i], 1e-6)),
            "time_limit_sec": float(self.time_limit[i]),
            "center": float(self.center[i]),
            "target_half": float(self.target_half[i]),
            "ramp_left": float(self.ramp_left[i]),
            "ramp_right": float(self.ramp_right[i]),
            "curve_exp": float(self.curve_exp[i]),
            "pick_break_budget": float(self.pick_break_budget[i]),
            "non_target_presses": int(self.non_target_presses[i]),
            "total_presses": int(self.total_presses[i]),
            "pick_wear": float(self.pick_wear[i]),
            "off_target_f_sec": float(self.off_target_f_sec[i]),
            "max_off_target_f_sec": float(self.cfg.get("physics", {}).get("player_efficiency", {}).get("max_off_target_f_sec", 1.0)),
            "preferred_search_fraction": float(self.cfg.get("physics", {}).get("player_efficiency", {}).get("preferred_search_fraction", 0.50)),
            "preferred_region_success_bonus": float(self.cfg.get("physics", {}).get("player_efficiency", {}).get("preferred_region_success_bonus", 2.0)),
            "reality_profile_active": bool(self.reality_profile.get("locks", {}).get(name, {}).get("enabled", False)) if isinstance(self.reality_profile, dict) else False,
            "reality_ramp_gain": float(self.ramp_gain[i]),
            "reality_sensor_noise": float(self.sensor_noise[i]),
        }


def _masked_mode_logits(mode_logits: torch.Tensor, old_f_down: torch.Tensor | None):
    if old_f_down is None:
        return mode_logits
    # While HOLD is already down, TAP is physically invalid. The only choices
    # are RELEASE (mode 0) or continue HOLD (mode 2).
    masked = mode_logits.clone()
    mask = old_f_down > 0.5
    if mask.any():
        masked[mask, 1] = -1e9
    return masked


def policy(model: ActorCritic, obs: torch.Tensor, deterministic=False, old_f_down: torch.Tensor | None = None):
    a, b, mode_logits, value = model(obs)
    md = Beta(a, b)
    ml = _masked_mode_logits(mode_logits, old_f_down)
    mode_dist = Categorical(logits=ml)
    if deterministic:
        move = (a / (a + b)).clamp(1e-4, 1.0 - 1e-4)
        mode = torch.argmax(ml, dim=1)
    else:
        move = md.sample().clamp(1e-4, 1.0 - 1e-4)
        mode = mode_dist.sample()
    if old_f_down is None:
        move_active = (mode == 0).float()
    else:
        move_active = ((old_f_down < 0.5) & (mode == 0)).float()
    logp = move_active * md.log_prob(move) + mode_dist.log_prob(mode)
    return move, mode, logp, value

def collect_rollout(model, env: LockBatchEnv, device, steps: int, completed_cb):
    n = env.n; od = env.obs_dim
    obs_buf = np.empty((steps, n, od), np.float32)
    move_buf = np.empty((steps, n), np.float32)
    mode_buf = np.empty((steps, n), np.int64)
    move_active_buf = np.empty((steps, n), np.float32)
    old_f_buf = np.empty((steps, n), np.float32)
    logp_buf = np.empty((steps, n), np.float32)
    val_buf = np.empty((steps, n), np.float32)
    rew_buf = np.empty((steps, n), np.float32)
    done_buf = np.empty((steps, n), np.bool_)
    for t in range(steps):
        obs = env.obs(); obs_buf[t] = obs
        old_f_np = (env.f_down > 0.5).astype(np.float32)
        with torch.inference_mode():
            tobs = torch.from_numpy(obs).to(device)
            old_f_t = torch.from_numpy(old_f_np).to(device)
            move, mode, logp, value = policy(model, tobs, deterministic=False, old_f_down=old_f_t)
        mn = move.cpu().numpy().astype(np.float32)
        moden = mode.cpu().numpy().astype(np.int64)
        move_active = ((old_f_np <= 0.5) & (moden == 0)).astype(np.float32)
        reward, done, success = env.step(mn, moden)
        move_buf[t] = mn; mode_buf[t] = moden; move_active_buf[t] = move_active; old_f_buf[t] = old_f_np
        logp_buf[t] = logp.cpu().numpy(); val_buf[t] = value.cpu().numpy(); rew_buf[t] = reward; done_buf[t] = done
        if np.any(done):
            ids = np.flatnonzero(done)
            completed_cb(env.lock_type[ids].copy(), success[ids].copy())
            env.reset(ids)
    with torch.inference_mode():
        nobs = torch.from_numpy(env.obs()).to(device)
        old_f_t = torch.from_numpy((env.f_down > 0.5).astype(np.float32)).to(device)
        _m,_mode,_lp,nv = policy(model, nobs, deterministic=True, old_f_down=old_f_t)
    return Rollout(obs_buf, move_buf, mode_buf, move_active_buf, old_f_buf, logp_buf, val_buf, rew_buf, done_buf, nv.cpu().numpy().astype(np.float32))

def compute_gae(r: Rollout, gamma: float, lam: float):
    T,N = r.reward.shape
    adv = np.zeros((T,N), np.float32)
    last = np.zeros(N, np.float32)
    for t in range(T-1, -1, -1):
        next_v = r.next_value if t == T-1 else r.value[t+1]
        nonterm = 1.0 - r.done[t].astype(np.float32)
        delta = r.reward[t] + gamma * next_v * nonterm - r.value[t]
        last = delta + gamma * lam * nonterm * last
        adv[t] = last
    ret = adv + r.value
    return adv, ret


def ppo_update(model, opt, r: Rollout, cfg: dict, device):
    adv, ret = compute_gae(r, float(cfg["gamma"]), float(cfg["gae_lambda"]))
    obs = torch.from_numpy(r.obs.reshape(-1, r.obs.shape[-1])).to(device)
    move = torch.from_numpy(r.move.reshape(-1)).to(device)
    mode = torch.from_numpy(r.mode_action.reshape(-1)).long().to(device)
    move_active = torch.from_numpy(r.move_active.reshape(-1)).to(device)
    old_f_down = torch.from_numpy(r.old_f_down.reshape(-1)).to(device)
    old_logp = torch.from_numpy(r.logp.reshape(-1)).to(device)
    returns = torch.from_numpy(ret.reshape(-1)).to(device)
    advantages = torch.from_numpy(adv.reshape(-1)).to(device)
    advantages = (advantages - advantages.mean()) / (advantages.std() + 1e-8)
    total = obs.shape[0]; mb = min(int(cfg["minibatch"]), total)
    losses=[]; kls=[]; ents=[]
    for _ in range(int(cfg["ppo_epochs"])):
        perm = torch.randperm(total, device=device)
        for s0 in range(0, total, mb):
            ix = perm[s0:s0+mb]
            a,b,mode_logits,val = model(obs[ix])
            md = Beta(a,b)
            ml = _masked_mode_logits(mode_logits, old_f_down[ix])
            mode_dist = Categorical(logits=ml)
            lp = move_active[ix] * md.log_prob(move[ix]) + mode_dist.log_prob(mode[ix])
            ratio = torch.exp(lp - old_logp[ix])
            clip = float(cfg["clip_range"])
            pg1 = ratio * advantages[ix]
            pg2 = torch.clamp(ratio, 1.0-clip, 1.0+clip) * advantages[ix]
            pg = -torch.min(pg1, pg2).mean()
            vloss = 0.5 * F.mse_loss(val, returns[ix])
            entropy = (move_active[ix] * md.entropy() + mode_dist.entropy()).mean()
            loss = pg + float(cfg["value_coef"])*vloss - float(cfg["entropy_coef"])*entropy
            opt.zero_grad(set_to_none=True); loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), float(cfg["max_grad_norm"]))
            opt.step()
            with torch.no_grad():
                kl = (old_logp[ix] - lp).mean().abs().item()
            losses.append(loss.item()); kls.append(kl); ents.append(entropy.item())
    return {"loss":float(np.mean(losses)),"kl":float(np.mean(kls)),"entropy":float(np.mean(ents))}

def save_checkpoint(model, opt, attempts: int, steps: int, best_score: float, obs_dim: int, cfg: dict, path: Path, vision_attempts: int = 0):
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.save({
        "version":"0.19.0-freelearn-live-vision",
        "physics_contract":"static-f-tap-hold-bounds-v3",
        "vision_contract":"live-vision-v1",
        "model":model.state_dict(), "optimizer":opt.state_dict(),
        "attempts":int(attempts), "steps":int(steps), "best_score":float(best_score),
        "obs_dim":int(obs_dim), "history_frames":int(cfg["training"]["history_frames"]),
        "frame_ms":int(cfg["training"]["frame_ms"]),
        "vision_attempts":int(vision_attempts),
    }, path)


def _migrate_old_static_policy(model: ActorCritic, ck: dict, old_dim: int, new_dim: int, contract: str):
    old_state = ck["model"]
    new_state = model.state_dict()
    # Copy all shape-compatible trunk/move/value tensors.
    for k, v in old_state.items():
        if k in ("trunk.0.weight", "f_logit.weight", "f_logit.bias"):
            continue
        if k in new_state and tuple(new_state[k].shape) == tuple(v.shape):
            new_state[k] = v

    # v0.17.2 had no explicit bound channels; append them with neutral zero weights.
    if "trunk.0.weight" not in old_state:
        raise RuntimeError("old checkpoint missing trunk.0.weight")
    old_w = old_state["trunk.0.weight"]
    new_w = new_state["trunk.0.weight"]
    if old_w.shape[0] != new_w.shape[0] or old_w.shape[1] != old_dim:
        raise RuntimeError(f"unexpected first-layer shape {tuple(old_w.shape)}")
    new_w.zero_(); new_w[:, :old_dim] = old_w
    new_state["trunk.0.weight"] = new_w

    # Convert old Bernoulli F DOWN tendency into the new 3-way mode head.
    # Old positive F preference is split neutrally between TAP and HOLD; MOVE
    # receives the opposite tendency. No hidden strategy is injected.
    if "f_logit.weight" in old_state:
        fw = old_state["f_logit.weight"].squeeze(0)
        fb = old_state.get("f_logit.bias", torch.zeros(1)).squeeze(0)
        mw = new_state["mode_logits.weight"]
        mb = new_state["mode_logits.bias"]
        mw.zero_(); mb.zero_()
        mw[0] = -0.5 * fw
        mw[1] = 0.25 * fw
        mw[2] = 0.25 * fw
        mb[0] = -0.5 * fb
        mb[1] = 0.25 * fb
        mb[2] = 0.25 * fb
        new_state["mode_logits.weight"] = mw; new_state["mode_logits.bias"] = mb
    model.load_state_dict(new_state)


def load_checkpoint(model, opt, cfg: dict):
    if not MODEL_PATH.exists() or not bool(cfg["training"].get("resume", True)):
        return 0,0,0.0,False,0
    try:
        ck = torch.load(MODEL_PATH, map_location="cpu", weights_only=False)
        contract = str(ck.get("physics_contract", ""))
        vision_attempts = int(ck.get("vision_attempts", 0))
        old_dim = int(ck.get("obs_dim", -1))
        new_dim = model.trunk[0].in_features

        if contract == "static-f-tap-hold-bounds-v3" and old_dim == new_dim:
            model.load_state_dict(ck["model"])
            try:
                opt.load_state_dict(ck["optimizer"])
            except Exception:
                print("[RESUME] v0.17.6.1/v0.17.6/v0.17.5/v0.17.4 compatible model loaded; optimizer state reset")
            return int(ck.get("attempts",0)),int(ck.get("steps",0)),float(ck.get("best_score",0)),True,vision_attempts

        if contract == "static-f-x-bounds-v2" and old_dim == new_dim:
            _migrate_old_static_policy(model, ck, old_dim, new_dim, contract)
            print("[ACTION MIGRATION] v0.17.3 bounds-aware policy -> explicit MOVE/TAP/HOLD; trunk/mouse/value preserved, old F tendency split TAP/HOLD")
            print("[ACTION MIGRATION] optimizer reset for the new 3-way F action head")
            return int(ck.get("attempts",0)),int(ck.get("steps",0)),float(ck.get("best_score",0)),True,vision_attempts

        if contract == "static-f-x-v1" and old_dim > 0 and new_dim == old_dim + 5:
            _migrate_old_static_policy(model, ck, old_dim, new_dim, contract)
            print(f"[BOUNDS+ACTION MIGRATION] v0.17.2 policy {old_dim} -> {new_dim} inputs + explicit MOVE/TAP/HOLD")
            print("[BOUNDS+ACTION MIGRATION] old trunk/mouse/value behavior preserved; 5 bound channels start neutral; old F tendency split TAP/HOLD")
            return int(ck.get("attempts",0)),int(ck.get("steps",0)),float(ck.get("best_score",0)),True,vision_attempts

        if contract not in ("static-f-x-v1", "static-f-x-bounds-v2", "static-f-tap-hold-bounds-v3"):
            print("[PHYSICS RESET] Existing FREELEARN checkpoint predates the supported static-F contracts and will NOT be resumed.")
            stamp = time.strftime("%Y%m%d_%H%M%S")
            for old_path in (MODEL_PATH, BEST_PATH, PROGRESS_PATH, SHOWCASE_PATH):
                if old_path.exists():
                    backup = old_path.with_name(f"{old_path.stem}.pre_v0174_{stamp}{old_path.suffix}")
                    try:
                        os.replace(old_path, backup)
                        print(f"[ARCHIVE] {old_path.name} -> {backup.name}")
                    except Exception as e:
                        print(f"[ARCHIVE] could not archive {old_path.name}: {e}")
            return 0,0,0.0,False,0

        print(f"[RESUME] checkpoint shape/contract {old_dim}/{contract} incompatible with {new_dim}; starting fresh")
        return 0,0,0.0,False,0
    except Exception as e:
        print(f"[RESUME] failed: {e}; starting fresh")
        return 0,0,0.0,False,0

def vision_curriculum_scale(cfg: dict, vision_attempts: int) -> float:
    """Fade the live-vision distortions in for a policy trained on a clean sensor.

    A checkpoint trained without the screen-measurement model would take a hard
    hit if full latency/quantization/calibration error appeared at once. The
    checkpoint stores how many attempts it has already trained under the live
    vision model, so the ramp survives restarts and never restarts itself.
    """
    vc = cfg.get("vision", {}) or {}
    if not bool(vc.get("enabled", True)):
        return 0.0
    warm = float(vc.get("curriculum_attempts", 1_500_000))
    if warm <= 0:
        return 1.0
    return float(np.clip(float(vision_attempts) / warm, 0.0, 1.0))


def run_showcase(model: ActorCritic, cfg: dict, device, counter: int, attempts: int, vision_scale: float = 1.0):
    # Four simultaneous deterministic episodes. Hidden geometry is exported ONLY
    # to the visualizer; it is never part of the policy observation.
    env = LockBatchEnv(cfg, 4, seed=int(cfg["training"]["seed"]) + 900_000 + counter)
    # Show the replay with the same live-vision strength the policy is training at.
    env.vision_scale=float(vision_scale)
    env.reset(np.arange(4,dtype=np.int64))
    ids=np.arange(4,dtype=np.int64)
    env.lock_type[:] = ids
    for i,name in enumerate(LOCK_NAMES):
        spec=cfg["locks"][name]; ti=0
        physical_max=float(spec.get("physical_max",1.0)); policy_span=float(spec.get("policy_span",1.0 if i==0 else 0.5))
        env.template_idx[i]=ti; env.allowed_max[i]=physical_max; env.policy_span[i]=max(1e-4,policy_span); env.time_limit[i]=float(spec["time_limit_sec"])
        t=spec["templates"][ti]; scale=env.allowed_max[i]/max(env.policy_span[i],1e-6)
        env.target_half[i]=float(t["target_half"])*scale; env.ramp_left[i]=float(t["ramp_left"])*scale; env.ramp_right[i]=float(t["ramp_right"])*scale
        env.curve_exp[i]=float(t["curve_exp"]); env.turn_tau[i]=float(t["turn_tau_ms"])/1000.0; env.return_tau[i]=float(t["return_tau_ms"])/1000.0
        # deterministic changing target positions across the REAL full physical X board
        frac=[0.12,0.32,0.52,0.76,0.93][(counter+i-1)%5]
        env.center[i]=float(env.allowed_max[i])*frac
        env.elapsed[i]=0; env.pos[i]=0; env.turn[i]=0; env.f_down[i]=0; env.raw_hist[i]=0
        env.non_target_presses[i]=0; env.total_presses[i]=0; env.pick_wear[i]=0.0; env.off_target_f_sec[i]=0.0; env.hold_run_sec[i]=0.0
        pe=cfg.get("physics",{}).get("player_efficiency",{})
        if i>0:
            env.pick_break_budget[i]=(float(pe.get("pick_break_budget_min",6.0))+float(pe.get("pick_break_budget_max",8.0)))*0.5
        else:
            env.pick_break_budget[i]=9999.0
        env.raw_hist[i,-1,0]=-1; env.raw_hist[i,-1,1]=-1; env.raw_hist[i,-1,2]=0; env.raw_hist[i,-1,3]=-1; env.raw_hist[i,-1,4]=0
    frames=[[] for _ in range(4)]; finished=np.zeros(4,np.bool_); success=np.zeros(4,np.bool_)
    max_steps=int(math.ceil(max(float(cfg["locks"][n]["time_limit_sec"]) for n in LOCK_NAMES)/(int(cfg["training"]["frame_ms"])/1000.0)))+2
    for step in range(max_steps):
        obs=env.obs()
        with torch.inference_mode():
            old_f_t=torch.from_numpy((env.f_down>0.5).astype(np.float32)).to(device)
            m,mode,lp,v=policy(model,torch.from_numpy(obs).to(device),deterministic=True,old_f_down=old_f_t)
        mn=m.cpu().numpy(); moden=mode.cpu().numpy().astype(np.int64)
        signed=(mn*2-1)*float(cfg["training"]["mouse_step_max"])
        rew,done,succ=env.step(mn,moden)
        for i in range(4):
            if not finished[i]:
                frames[i].append({
                    "t_ms":int(round((step+1)*int(cfg["training"]["frame_ms"]))),
                    "pos":round(float(env.pos[i]),6),
                    "turn":round(float(env.turn[i]),5),
                    "turn_delta":round(float(env.last_turn_delta[i]),6),
                    "depth":round(float(env.last_cap[i]),5),
                    "f":int(env.last_action_mode[i] in (1,2)),
                    "f_persistent":int(env.f_down[i]>0.5),
                    "f_mode":["MOVE/RELEASE","TAP","HOLD"][int(env.last_action_mode[i])],
                    "hold_run_ms":int(round(float(env.hold_run_sec[i])*1000.0)),
                    "press_edge":int(env.last_press_edge[i]),
                    "mouse":round(float(env.prev_mouse[i]),6),
                    "mouse_requested":round(float(env.last_requested_mouse[i]),6),
                    "move_blocked":int(env.last_move_blocked[i]),
                    "non_target_presses":int(env.non_target_presses[i]),
                    "total_presses":int(env.total_presses[i]),
                    "pick_wear":round(float(env.pick_wear[i]),4),
                    "pick_budget":round(float(env.pick_break_budget[i]),4),
                    "pick_broken":int(env.last_pick_broken[i]),
                    "time_cap_broken":int(env.last_time_cap_broken[i]),
                    "off_target_f_sec":round(float(env.off_target_f_sec[i]),4)
                })
                if done[i]: finished[i]=True; success[i]=bool(succ[i])
        if finished.all(): break
        if np.any(done):
            # Freeze completed panels instead of resetting them during showcase.
            for i in np.flatnonzero(done):
                env.elapsed[i]=min(env.elapsed[i],env.time_limit[i]); env.f_down[i]=0
    locks=[]
    for i in range(4):
        g=env.hidden_geometry(i); g.update({"success":bool(success[i]),"frames":frames[i]})
        locks.append(g)
    atomic_json(SHOWCASE_PATH,{"version":"0.18.0","showcase":counter,"attempts":int(attempts),"created":time.strftime("%Y-%m-%d %H:%M:%S"),"frame_ms":int(cfg["training"]["frame_ms"]),"locks":locks})


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--minutes",type=float,default=30.0,help="0 = run until stopped")
    ap.add_argument("--envs",type=int,default=None)
    ap.add_argument("--showcase-every",type=int,default=None)
    ap.add_argument("--quick-test",action="store_true")
    args=ap.parse_args()

    DATA.mkdir(exist_ok=True); CKPT.mkdir(exist_ok=True)
    cfg=load_config(); tc=cfg["training"]
    if args.envs: tc["envs"]=int(args.envs)
    if args.showcase_every: tc["showcase_every_attempts"]=max(1,int(args.showcase_every))
    if args.quick_test:
        tc["envs"]=256; tc["rollout_steps"]=16; tc["minibatch"]=4096; tc["ppo_epochs"]=1; args.minutes=0.03
    seed=int(tc["seed"]); set_seeds(seed)
    try:
        torch.set_num_threads(max(1, os.cpu_count() or 1))
        torch.set_num_interop_threads(2)
    except Exception: pass
    device=torch.device("cpu")
    env=LockBatchEnv(cfg,int(tc["envs"]),seed+1)
    model=ActorCritic(env.obs_dim).to(device)
    opt=torch.optim.Adam(model.parameters(),lr=float(tc["learning_rate"]),eps=1e-5)
    attempts,steps,best_score,resumed,vision_attempts=load_checkpoint(model,opt,cfg)
    # Apply the curriculum strength before the first attempts are generated.
    env.vision_scale=vision_curriculum_scale(cfg,vision_attempts)
    if env.vision_enabled and vision_attempts==0 and best_score>0.0:
        # The stored best was scored on a perfect sensor. Under the live-vision
        # model the same policy scores lower, so keep tracking BEST in the new
        # regime instead of freezing a checkpoint the live agent cannot use.
        print(f"[BEST RESET] previous best mean {100*best_score:.1f}% was measured without the live-vision model; "
              "re-baselining BEST for live-vision training")
        best_score=0.0
    env.reset(np.arange(env.n,dtype=np.int64),balanced=True)
    print("="*72)
    print(" LOCKPICK v0.18.0 FREELEARN - FIXED PER-LOCK GEOMETRY + FULL X + SOFT 50%")
    print("="*72)
    print("Agent inputs : raw X + visible lock turn + visible turn-delta + own F history + own actual X delta + time + lock type + physical X bounds/distances")
    print(f"Agent actions: MOVE/RELEASE, F TAP, or F HOLD every {tc['frame_ms']} ms; mouse X amount is learned independently")
    print("F TAP = one static frame. F HOLD = repeated HOLD frames; neural chooses the duration itself in frame increments.")
    print("STATIC-F RULE: X changes only on a full MOVE frame while persistent F was already UP. TAP/HOLD/release lock X completely.")
    print("KNOWN BOARD: full physical X mapped into stable neural coordinates (Rusted 0..1, player locks 0..0.5) | NO hidden target/ramp info")
    print("NO preset hold durations | NO best_pos | NO ramp flag | NO target flag | NO belief | NO scripted search/finish")
    print("Ramp depth is continuous physics. Neural sees only visible turn/turn-delta; hidden geometry remains showcase-only.")
    vcfg=cfg.get("vision",{}) or {}
    if bool(vcfg.get("enabled",True)):
        print(f"LIVE VISION MODEL: obs latency 0..{env.max_latency} frames | turn gain +-{100*float(vcfg.get('turn_gain_error',0.10)):.0f}% | "
              f"turn offset +-{float(vcfg.get('turn_offset_error',0.03)):.3f} | quant<={float(vcfg.get('turn_quant',0.012)):.3f} | "
              f"noise<={float(vcfg.get('turn_noise',0.010)):.3f} | stale frames<={100*float(vcfg.get('stale_frame_prob',0.06)):.0f}% | "
              f"mouse gain +-{100*float(vcfg.get('move_gain_error',0.10)):.0f}%")
        print(f"LIVE VISION MODEL: applies to the OBSERVATION and mouse execution only; hidden physics/success stay exact. "
              f"attempts already trained with live vision={vision_attempts:,} "
              f"(full strength at {int(vcfg.get('curriculum_attempts',1_500_000)):,})")
    else:
        print("LIVE VISION MODEL: disabled; the policy trains on a perfect sensor and will transfer badly to SCUM.")
    rp0 = load_reality_profile()
    active_real = [k for k,v in rp0.get("locks", {}).items() if isinstance(v, dict) and v.get("enabled")] if isinstance(rp0, dict) else []
    if active_real:
        print(f"REAL<->SIM BRIDGE active for: {', '.join(active_real)} | overall match={100*float(rp0.get('overall_match',0.0)):.1f}%")
    else:
        print("REAL<->SIM BRIDGE: no active fitted profile yet; using configured simulator physics.")
    print("FIXED GEOMETRY: each lock type has one constant target width + ramp width/curve; ONLY target center/location changes per attempt.")
    pe=cfg.get("physics",{}).get("player_efficiency",{})
    print(f"Player locks: soft goal <={int(pe.get('soft_goal_non_target_presses',8))} off-target presses + hard cumulative off-target F-active cap {float(pe.get('max_off_target_f_sec',1.0)):.2f}s; cap break gets extra penalty.")
    print(f"SOFT SEARCH PRIOR: first {100*float(pe.get('preferred_search_fraction',0.50)):.0f}% of PHYSICAL full X gets +{float(pe.get('preferred_region_success_bonus',2.0)):.2f} terminal reward. Full X remains legal; coordinate bridge preserves old checkpoint semantics.")
    print(f"Envs={env.n:,} rollout={tc['rollout_steps']} obs_dim={env.obs_dim} resumed={resumed} attempts={attempts:,}")
    print(f"Showcase every {int(tc['showcase_every_attempts']):,} attempts (hot-reloadable from Command Center)")
    print(f"Run time={'until stopped' if args.minutes<=0 else f'{args.minutes:.1f} min'}")

    progress_header=not PROGRESS_PATH.exists()
    progress_f=PROGRESS_PATH.open("a",newline="",encoding="utf-8")
    pw=csv.writer(progress_f)
    if progress_header:
        pw.writerow(["wall_time","attempts","steps","steps_per_sec","Rusted","Basic","Medium","Enforced","loss","kl","entropy","best_mean"]); progress_f.flush()

    window_total=np.zeros(4,np.int64); window_success=np.zeros(4,np.int64)
    lifetime_total=np.zeros(4,np.int64); lifetime_success=np.zeros(4,np.int64)
    start=time.perf_counter(); last_tel=0.0; last_progress=attempts; last_ckpt=attempts; last_show=attempts
    showcase_counter=0
    if SHOWCASE_PATH.exists():
        try: showcase_counter=int(json.loads(SHOWCASE_PATH.read_text(encoding='utf-8')).get('showcase',0))
        except Exception: pass
    config_mtime=CONFIG_PATH.stat().st_mtime
    last_metrics={"loss":0.0,"kl":0.0,"entropy":0.0}
    stop=False
    def sig(_s,_f):
        nonlocal stop; stop=True
    signal.signal(signal.SIGINT,sig); signal.signal(signal.SIGTERM,sig)

    def completed(types, succ):
        nonlocal attempts, vision_attempts
        cnt=np.bincount(types,minlength=4); sc=np.bincount(types,weights=succ.astype(np.int64),minlength=4).astype(np.int64)
        window_total[:] += cnt; window_success[:] += sc; lifetime_total[:] += cnt; lifetime_success[:] += sc
        attempts += int(len(types))
        if env.vision_enabled:
            vision_attempts += int(len(types))

    deadline=None if args.minutes<=0 else start+args.minutes*60.0
    try:
        while not stop and (deadline is None or time.perf_counter()<deadline):
            # Hot reload REAL<->SIM profile independently. New episodes pick up the
            # latest fitted observable physics without restarting PPO.
            env.update_reality_profile(load_reality_profile())

            # Hot reload geometry + showcase cadence. Network-shape fields remain fixed until restart.
            try:
                mt=CONFIG_PATH.stat().st_mtime
                if mt!=config_mtime:
                    new=load_config(); cfg["locks"]=new["locks"]; cfg["physics"]=new.get("physics",cfg["physics"])
                    tc["showcase_every_attempts"]=int(new["training"].get("showcase_every_attempts",tc["showcase_every_attempts"]))
                    tc["checkpoint_every_attempts"]=int(new["training"].get("checkpoint_every_attempts",tc["checkpoint_every_attempts"]))
                    tc["progress_every_attempts"]=int(new["training"].get("progress_every_attempts",tc["progress_every_attempts"]))
                    env.update_config(cfg); config_mtime=mt
                    print(f"[HOT RELOAD] geometry/config applied to new episodes | showcase every {tc['showcase_every_attempts']:,}")
            except Exception as e:
                print(f"[HOT RELOAD] ignored invalid config: {e}")

            # Live-vision realism strength for new attempts (sim -> SCUM transfer).
            env.vision_scale=vision_curriculum_scale(cfg,vision_attempts)

            r=collect_rollout(model,env,device,int(tc["rollout_steps"]),completed)
            steps += int(tc["rollout_steps"])*env.n
            last_metrics=ppo_update(model,opt,r,tc,device)
            elapsed=max(1e-6,time.perf_counter()-start); sps=steps/elapsed
            rates=np.divide(window_success,np.maximum(window_total,1),dtype=np.float64)
            life=np.divide(lifetime_success,np.maximum(lifetime_total,1),dtype=np.float64)
            mean=float(np.mean(life))
            if mean>best_score and lifetime_total.sum()>=1000:
                best_score=mean; save_checkpoint(model,opt,attempts,steps,best_score,env.obs_dim,cfg,BEST_PATH,vision_attempts)

            now=time.perf_counter()
            if attempts-last_progress>=int(tc["progress_every_attempts"]):
                pw.writerow([time.strftime("%Y-%m-%d %H:%M:%S"),attempts,steps,round(sps,1),*[round(float(x),6) for x in rates],round(last_metrics["loss"],6),round(last_metrics["kl"],6),round(last_metrics["entropy"],6),round(best_score,6)])
                progress_f.flush(); last_progress=attempts; window_total[:]=0; window_success[:]=0
                print(f"ATT {attempts:>12,} | R={100*life[0]:5.1f}% B={100*life[1]:5.1f}% M={100*life[2]:5.1f}% E={100*life[3]:5.1f}% | {sps:,.0f} step/s | loss={last_metrics['loss']:.3f} ent={last_metrics['entropy']:.3f}")

            if attempts-last_ckpt>=int(tc["checkpoint_every_attempts"]):
                save_checkpoint(model,opt,attempts,steps,best_score,env.obs_dim,cfg,MODEL_PATH,vision_attempts); last_ckpt=attempts
                print(f"[CHECKPOINT] {attempts:,} attempts -> {MODEL_PATH.name}")

            requested=SHOWCASE_REQUEST.exists()
            if requested or attempts-last_show>=int(tc["showcase_every_attempts"]):
                if requested:
                    try: SHOWCASE_REQUEST.unlink()
                    except Exception: pass
                showcase_counter+=1
                run_showcase(model,cfg,device,showcase_counter,attempts,env.vision_scale); last_show=attempts
                print(f"[LOCK SHOW #{showcase_counter}] visual replay written at {attempts:,} attempts")

            if now-last_tel>=float(tc["telemetry_every_sec"]):
                tel={
                    "version":"0.18.0","status":"training","pid":os.getpid(),"attempts":int(attempts),"steps":int(steps),"elapsed_sec":round(elapsed,1),"steps_per_sec":round(sps,1),
                    "success_rates":{LOCK_NAMES[i]:round(float(life[i]),6) for i in range(4)},
                    "episode_counts":{LOCK_NAMES[i]:int(lifetime_total[i]) for i in range(4)},
                    "loss":round(last_metrics["loss"],6),"kl":round(last_metrics["kl"],6),"entropy":round(last_metrics["entropy"],6),
                    "best_mean":round(best_score,6),"showcase_every_attempts":int(tc["showcase_every_attempts"]),"showcase_count":int(showcase_counter),
                    "ram_note":"FREELEARN rollout is bounded; no 30.7 GiB replay bank is used",
                    "config_hot_reload":True,
                    "vision_scale":round(float(env.vision_scale),4),
                    "vision_enabled":bool(env.vision_enabled),
                    "vision_attempts":int(vision_attempts)
                }
                atomic_json(TELEMETRY_PATH,tel); last_tel=now
    finally:
        save_checkpoint(model,opt,attempts,steps,best_score,env.obs_dim,cfg,MODEL_PATH,vision_attempts)
        elapsed=max(1e-6,time.perf_counter()-start)
        life=np.divide(lifetime_success,np.maximum(lifetime_total,1),dtype=np.float64)
        atomic_json(TELEMETRY_PATH,{"version":"0.18.0","status":"stopped","pid":os.getpid(),"attempts":int(attempts),"steps":int(steps),"elapsed_sec":round(elapsed,1),"steps_per_sec":round(steps/elapsed,1),"success_rates":{LOCK_NAMES[i]:round(float(life[i]),6) for i in range(4)},"best_mean":round(best_score,6),"showcase_count":int(showcase_counter)})
        progress_f.close()
        print(f"[STOP] saved {MODEL_PATH} | attempts={attempts:,} steps={steps:,}")

if __name__ == "__main__":
    main()
