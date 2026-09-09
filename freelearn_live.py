"""Live SCUM player for the FREELEARN policy.

This is the missing half of the FREELEARN loop: the simulator trains a 25 ms
MOVE / F TAP / F HOLD policy on the visible lock turn, and this runner executes
that exact policy in the real game, driven by nothing but what can be measured
on screen:

  * the pick position (red bar angle -> normalized X),
  * the visible rotation of the lock cylinder (keyway angle -> turn 0..1),
  * its own F history and its own executed mouse movement,
  * the remaining attempt time and the classified lock type.

The hidden target position, the ramp bounds and the ramp depth are never read
and never guessed: the agent finds the target the same way the simulator taught
it to, by pressing F and watching how far the cylinder rotates.

The frame contract is identical to freelearn_trainer.LockBatchEnv:
  * one decision every frame_ms (25 ms),
  * STATIC-F: X may change only on a MOVE frame while F was already UP,
  * F TAP is exactly one frame of F, F HOLD keeps F down until the policy
    chooses MOVE/RELEASE.

Usage
  python freelearn_live.py --lock Auto --attempts 20
  python freelearn_live.py --selftest        (no game needed: contract + transfer check)
  python freelearn_live.py --calibrate       (mouse/X calibration only)
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Deque, Dict, List, Optional

import numpy as np

from freelearn_obs import (
    LOCK_INDEX, LOCK_NAMES, LockContract, ObsBuilder, PolicyRunner,
    MODE_HOLD, MODE_MOVE, MODE_NAMES, MODE_TAP, load_config,
)
from freelearn_vision import FastLockVision, TurnCalibration

ROOT = Path(__file__).resolve().parent
LIVE_DIR = ROOT / "data" / "live"
STATUS_PATH = LIVE_DIR / "live_status.json"
EPISODES_CSV = LIVE_DIR / "episodes.csv"
TRACE_PATH = LIVE_DIR / "last_episode_trace.json"
BRIDGE_DIR = ROOT / "data" / "real_bridge"
BRIDGE_SAMPLES = BRIDGE_DIR / "samples.jsonl"

EPISODE_FIELDS = [
    "time", "attempt", "lock", "result", "elapsed_sec", "frames", "presses",
    "best_turn", "final_turn", "x_min", "x_max", "success_turn_deg", "mean_frame_ms",
    "mean_read_ms", "overrun_frames",
]


def atomic_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def append_csv(path: Path, fields: List[str], row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    with path.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        if new:
            w.writeheader()
        w.writerow({k: row.get(k, "") for k in fields})


def append_bridge_row(row: dict) -> None:
    BRIDGE_DIR.mkdir(parents=True, exist_ok=True)
    with BRIDGE_SAMPLES.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")


@dataclass
class Probe:
    """One F action, recorded exactly like the passive REAL<->SIM recorder does."""
    episode_id: str
    lock: str
    t_down: float
    x: Optional[float]
    x_conf: float
    turn_before: float
    ui_conf: float
    peak_turn: float
    t_up: Optional[float] = None
    f_ms: float = 0.0
    mode: str = "TAP"


class ProbeLog:
    """Collects F probes and writes them into the REAL<->SIM bridge dataset."""

    def __init__(self, enabled: bool = True):
        self.enabled = bool(enabled)
        self.pending: Deque[Probe] = deque()
        self.active: Optional[Probe] = None
        self.rows: List[dict] = []
        self.episode_id = ""
        self.episode_start = 0.0

    def new_episode(self, episode_id: str, start: float) -> None:
        self.flush(force=True, turn=None)
        self.episode_id = episode_id
        self.episode_start = start
        self.rows = []

    def press(self, lock: str, now: float, x: Optional[float], x_conf: float,
              turn: float, ui_conf: float) -> None:
        self.active = Probe(self.episode_id, lock, now, x, x_conf, turn, ui_conf, turn)
        self.active.mode = "TAP"

    def observe(self, turn: float) -> None:
        if self.active is not None:
            self.active.peak_turn = max(self.active.peak_turn, float(turn))

    def release(self, now: float, hold_frames: int) -> None:
        if self.active is None:
            return
        p = self.active
        p.t_up = now
        p.f_ms = max(0.0, (now - p.t_down) * 1000.0)
        p.mode = "TAP" if p.f_ms <= 80.0 else "HOLD"
        self.pending.append(p)
        self.active = None

    def tick(self, now: float, turn: float) -> None:
        """Finalize probes whose 180 ms return window has elapsed."""
        while self.pending and self.pending[0].t_up is not None and now - self.pending[0].t_up >= 0.180:
            self._write(self.pending.popleft(), now, turn)

    def flush(self, force: bool, turn: Optional[float], now: Optional[float] = None) -> None:
        if not force:
            return
        now = now if now is not None else time.monotonic()
        while self.pending:
            self._write(self.pending.popleft(), now, turn if turn is not None else 0.0)
        self.active = None

    def _write(self, p: Probe, now: float, turn_after: float) -> None:
        if not self.enabled or p.t_up is None or p.x is None:
            return
        row = {
            "version": "0.19.0",
            "source": "screen_passive",
            "actor": "freelearn_live",
            "episode_id": p.episode_id,
            "episode_elapsed": round(p.t_down - self.episode_start, 6),
            "lock_type": p.lock,
            "lock_type_conf": 1.0,
            "x": round(float(p.x), 7),
            "x_raw": None,
            "x_conf": round(float(p.x_conf), 5),
            "f_mode": p.mode,
            "f_ms": round(float(p.f_ms), 3),
            "turn_before": round(float(p.turn_before), 7),
            "turn_peak": round(float(p.peak_turn), 7),
            "turn_delta": round(float(max(0.0, p.peak_turn - min(p.turn_before, 0.055))), 7),
            "turn_after": round(float(turn_after), 7),
            "return_sample_ms": round(float((now - p.t_up) * 1000.0), 3),
            "ui_conf": round(float(p.ui_conf), 5),
            "success_score": 0.0,
            "episode_success": False,
            "captured_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        self.rows.append(row)
        append_bridge_row(row)

    def mark_success(self, lock: str, x: Optional[float], turn: float, f_ms: float) -> None:
        if not self.enabled or not self.episode_id:
            return
        append_bridge_row({
            "version": "0.19.0", "source": "episode_terminal", "actor": "freelearn_live",
            "episode_id": self.episode_id, "lock_type": lock, "lock_type_conf": 1.0,
            "terminal": True, "episode_success": True,
            "success_x": None if x is None else round(float(x), 7),
            "success_turn": round(float(turn), 7), "success_f_ms": round(float(f_ms), 3),
            "captured_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        })


class LiveAgent:
    def __init__(self, args):
        import lockpick_learner as classic  # Windows-only screen/input layer

        self.classic = classic
        self.args = args
        self.fl_cfg = load_config()
        self.cfg = classic.Config.load()
        self.qmodel = classic.QModel(self.cfg)
        self.turn_cal = TurnCalibration()
        self.probe_log = ProbeLog(enabled=not args.no_bridge_log)
        self.vision = None
        self.fast: Optional[FastLockVision] = None
        self.console = None
        self.runner: Optional[PolicyRunner] = None
        self.contracts: Dict[str, LockContract] = {}
        self.classifier = None
        self.attempt = 0
        self.success_count = 0
        self.frame_read_ms = 8.0

    # -- setup ---------------------------------------------------------------
    def contract(self, lock: str) -> LockContract:
        if lock not in self.contracts:
            self.contracts[lock] = LockContract.from_config(self.fl_cfg, lock)
        return self.contracts[lock]

    def prepare(self) -> bool:
        classic = self.classic
        self.vision, self.console, _hwnd = classic.prepare_live_vision(
            self.cfg, self.qmodel, minimize=not self.args.keep_console
        )
        if self.vision is None:
            print("Could not lock onto the SCUM window / lock UI.")
            return False
        self.vision.cal.update(self.qmodel.calibration)
        if not classic.calibration_valid(self.qmodel, self.vision):
            print("X calibration missing or stale for this monitor; running auto-calibration.")
            if not classic.auto_calibrate(self.cfg, self.qmodel, self.vision):
                print("Auto-calibration failed. Open the lock minigame and retry.")
                return False
            self.vision.cal.update(self.qmodel.calibration)
        boot = self.turn_cal.bootstrap_from_refs()
        if boot:
            self.turn_cal.save()
            for lk, e in boot.items():
                print(f"Turn calibration from reference art: {lk:<9} rest {e['rest_deg']:.1f} deg, "
                      f"full turn {e['span_deg']:.1f} deg")
        self.fast = FastLockVision(self.vision, lock=self._initial_lock(), calibration=self.turn_cal)
        if self.args.lock == "Auto":
            try:
                from real_sim_bridge import LockClassifier
                self.classifier = LockClassifier()
            except Exception as e:
                print(f"Lock auto-classification unavailable ({e}); defaulting to {self._initial_lock()}.")
        contract = self.contract(self._initial_lock())
        self.runner = PolicyRunner(
            contract,
            checkpoint=Path(self.args.checkpoint) if self.args.checkpoint else None,
            deterministic=not self.args.stochastic,
        )
        print(f"Policy: {self.runner.path.name} | trained attempts={self.runner.attempts:,} "
              f"| best sim mean={100*self.runner.best_score:.1f}% | obs_dim={contract.obs_dim}")
        if self.runner.vision_attempts <= 0:
            print("WARNING: this checkpoint was trained on a perfect sensor (vision_attempts=0). "
                  "Run the trainer with the live-vision model on before expecting in-game results.")
        else:
            print(f"Live-vision training: {self.runner.vision_attempts:,} attempts")
        print(f"Frame contract: {contract.frame_ms} ms | STATIC-F | "
              f"{'deterministic' if not self.args.stochastic else 'stochastic'} policy")
        return True

    def _initial_lock(self) -> str:
        return self.args.lock if self.args.lock in LOCK_INDEX else "Basic"

    def classify_lock(self) -> str:
        if self.args.lock in LOCK_INDEX:
            return self.args.lock
        if self.classifier is None or self.fast is None:
            return self._initial_lock()
        frame = self.fast.last_frame
        if frame is None:
            frame = self.vision.grab()
        try:
            lk, conf, _ = self.classifier.classify(frame, self.vision.half, self.vision.radius)
            if lk in LOCK_INDEX and conf >= 0.20:
                return lk
        except Exception:
            pass
        return self._initial_lock()

    # -- one attempt ---------------------------------------------------------
    def run_attempt(self) -> Optional[bool]:
        """Returns True/False for success/fail, or None if the run was aborted."""
        classic = self.classic
        cfg = self.cfg
        fast = self.fast
        assert fast is not None and self.runner is not None

        lock = self.classify_lock()
        c = self.contract(lock)
        fast.set_lock(lock)
        self.runner.c = c

        # Fresh attempt: Space starts the timer, then park the pick at the left
        # edge so the live start state matches the simulator reset (x = 0).
        classic.send_key(cfg.space_key_vk, 28)
        time.sleep(max(0.08, cfg.start_wait_seconds))
        classic.move_mouse_relative(-5000, 0)
        time.sleep(0.16)
        fast.clear_success()

        m = fast.read(need_pick=True, want_success=False)
        if m.x is None:
            print("Pick not visible; skipping attempt.")
            time.sleep(cfg.restart_wait_seconds)
            return False
        # Re-zero the resting keyway angle while the lock is untouched.
        self.turn_cal.note_rest(lock, m.keyway_deg, weight=0.20)
        m = fast.read(need_pick=True, want_success=False)

        obs = ObsBuilder(c)
        obs.reset(x_phys=float(m.x) * c.physical_max, turn=m.turn)

        episode_id = f"{time.strftime('%Y%m%d_%H%M%S')}_{os.getpid()}_{self.attempt:05d}"
        start = time.monotonic()
        self.probe_log.new_episode(episode_id, start)

        f_down = False
        hold_frames = 0
        x_meas = float(m.x) * c.physical_max
        turn = float(m.turn)
        best_turn = turn
        best_turn_deg = m.turn_deg
        x_min = x_meas
        x_max = x_meas
        frames = 0
        presses = 0
        overruns = 0
        frame_times: List[float] = []
        trace: List[dict] = []
        success = False
        aborted = False
        low_ui_since: Optional[float] = None
        deadline = c.time_limit_sec + float(self.args.grace_sec)

        while True:
            # The frame clock starts before the decision: policy inference is part
            # of the 25 ms budget, exactly like a simulator step.
            frame_start = time.monotonic()
            if classic.emergency_or_pause(cfg):
                aborted = True
                break
            elapsed = frame_start - start
            if elapsed >= deadline:
                break

            vec = obs.vector(elapsed)
            move_unit, mode, _value = self.runner.act(vec, f_down)
            if f_down and mode == MODE_TAP:      # physically impossible, mirrors the sim guard
                mode = MODE_HOLD

            t0 = time.monotonic()
            requested = self.runner.physical_delta(move_unit)
            issued_move = False
            f_active = False
            tap_pending = False

            if mode == MODE_MOVE:
                if f_down:
                    classic.key_up(cfg.f_key_vk)          # release frame: X stays locked
                    f_down = False
                    self.probe_log.release(t0, hold_frames)
                    hold_frames = 0
                else:
                    gain = float(self.qmodel.calibration.get("mouse_counts_per_norm", 900.0))
                    dx = int(round(requested * gain))
                    if dx != 0:
                        classic.move_mouse_relative(dx, 0)
                        issued_move = True
            else:
                f_active = True
                if not f_down:
                    classic.press_key_down(cfg.f_key_vk)
                    presses += 1
                    self.probe_log.press(lock, t0, x_meas / max(c.physical_max, 1e-6),
                                         m.x_conf, turn, m.ui_conf)
                if mode == MODE_TAP:
                    tap_pending = True                     # exactly one frame of F
                    f_down = False
                else:
                    f_down = True
                    hold_frames += 1

            # Sleep so that the measurement lands on the frame boundary.
            read_budget = min(0.6 * c.dt, self.frame_read_ms / 1000.0)
            wait = c.dt - read_budget - (time.monotonic() - frame_start)
            if wait > 0:
                time.sleep(wait)

            read_t0 = time.monotonic()
            need_pick = not f_active            # X cannot move while F is down
            m = fast.read(need_pick=need_pick, want_success=turn > 0.60)
            self.frame_read_ms = 0.8 * self.frame_read_ms + 0.2 * (time.monotonic() - read_t0) * 1000.0

            if tap_pending:
                classic.key_up(cfg.f_key_vk)
                self.probe_log.release(time.monotonic(), 1)

            prev_x = x_meas
            if need_pick and m.x is not None:
                x_meas = float(m.x) * c.physical_max
            # Channel 4 is "what my own X actually did this frame". Frames that
            # issue no mouse movement (TAP, HOLD, the release frame) are exactly
            # zero in the simulator, so they must be zero here too.
            executed = (x_meas - prev_x) if issued_move else 0.0
            x_min = min(x_min, x_meas)
            x_max = max(x_max, x_meas)
            turn = float(m.turn)
            best_turn = max(best_turn, turn)
            best_turn_deg = max(best_turn_deg, m.turn_deg)
            self.turn_cal.note_turn(lock, m.turn_deg)
            self.probe_log.observe(turn)
            self.probe_log.tick(time.monotonic(), turn)

            obs.push(x_meas, turn, f_active, executed)
            frames += 1
            frame_ms = (time.monotonic() - frame_start) * 1000.0
            frame_times.append(frame_ms)
            if frame_ms > c.frame_ms * 1.25:
                overruns += 1
            if self.args.trace:
                trace.append({
                    "t_ms": int(round((time.monotonic() - start) * 1000.0)),
                    "mode": MODE_NAMES[mode], "x": round(x_meas, 5), "turn": round(turn, 5),
                    "turn_deg": round(m.turn_deg, 2), "requested": round(requested, 5),
                    "executed": round(executed, 5), "ui": round(m.ui_conf, 3),
                    "frame_ms": round(frame_ms, 2),
                })

            # Hold the exact 25 ms cadence the policy was trained on: the read
            # lands just before the boundary, the remainder is slept off here.
            rest = c.dt - (time.monotonic() - frame_start)
            if rest > 0:
                time.sleep(rest)

            score, detected, _at = fast.success()
            if detected:
                success = True
                break

            # Lock UI disappearing means the attempt ended (opened or pick broke).
            if m.ui_conf < 0.05:
                low_ui_since = low_ui_since or time.monotonic()
                if time.monotonic() - low_ui_since > 0.25 and elapsed > 0.5:
                    break
            else:
                low_ui_since = None

        # Release F no matter how the attempt ended.
        if f_down:
            classic.key_up(cfg.f_key_vk)
            self.probe_log.release(time.monotonic(), hold_frames)
        f_down = False

        if not success and not aborted:
            late = classic.wait_success_text(self.vision, cfg, ms=self.cfg.success_confirm_wait_ms)
            success = late >= cfg.success_template_threshold
        self.probe_log.flush(force=True, turn=turn)

        elapsed = time.monotonic() - start
        mean_frame = float(np.mean(frame_times)) if frame_times else 0.0
        if success:
            self.success_count += 1
            self.turn_cal.note_success(lock, best_turn_deg)
            self.probe_log.mark_success(lock, x_meas / max(c.physical_max, 1e-6), best_turn, 0.0)
        self.turn_cal.save()

        append_csv(EPISODES_CSV, EPISODE_FIELDS, {
            "time": time.strftime("%Y-%m-%d %H:%M:%S"), "attempt": self.attempt, "lock": lock,
            "result": "SUCCESS" if success else ("ABORTED" if aborted else "FAIL"),
            "elapsed_sec": round(elapsed, 3), "frames": frames, "presses": presses,
            "best_turn": round(best_turn, 4), "final_turn": round(turn, 4),
            "x_min": round(x_min, 4), "x_max": round(x_max, 4),
            "success_turn_deg": round(best_turn_deg, 2), "mean_frame_ms": round(mean_frame, 2),
            "mean_read_ms": round(self.frame_read_ms, 2), "overrun_frames": overruns,
        })
        if self.args.trace and trace:
            atomic_json(TRACE_PATH, {
                "attempt": self.attempt, "lock": lock, "success": bool(success),
                "frame_ms": c.frame_ms, "frames": trace,
            })

        if mean_frame > c.frame_ms * 1.35:
            print(f"  WARNING: the control loop ran at {mean_frame:.0f} ms per frame instead of {c.frame_ms} ms, "
                  f"so the attempt only got {frames} decisions instead of ~{int(c.time_limit_sec*1000/c.frame_ms)}.")
        if x_max - x_min < 0.15:
            print(f"  WARNING: the pick only covered X {x_min:.2f}..{x_max:.2f}. Either the mouse gain is wrong "
                  "(rerun FREELEARN_LIVE_CALIBRATE.bat) or the pick is not being detected.")
        if presses > 0 and best_turn_deg < 1.5:
            print("  WARNING: the lock never visibly turned during this attempt. That is a vision problem, "
                  "not a policy problem - check `freelearn_live.py --observe` before training more.")
        print(f"[{self.attempt:>4}] {lock:<8} {'SUCCESS' if success else ('ABORT' if aborted else 'fail   ')} "
              f"| {elapsed:4.2f}s | frames={frames:3d} presses={presses:2d} "
              f"| x {x_min:.2f}-{x_max:.2f} | best turn={best_turn:.3f} ({best_turn_deg:.1f} deg) "
              f"| frame {mean_frame:4.1f} ms (read {self.frame_read_ms:4.1f}, over {overruns})")
        self.write_status(lock, success, elapsed, mean_frame, overruns)
        if aborted:
            return None
        return success

    def observe_loop(self) -> int:
        """Passive check: print what the agent sees, inject nothing."""
        if not self.prepare():
            return 2
        assert self.fast is not None
        print("\nOBSERVE mode: no mouse or F input is sent. F12 stops.")
        print("  turn = visible lock turn on the simulator scale, deg = measured cylinder rotation\n")
        last = 0.0
        try:
            while not self.classic.emergency_or_pause(self.cfg):
                lock = self.classify_lock()
                self.fast.set_lock(lock)
                m = self.fast.read(need_pick=True, want_success=True)
                score, detected, _at = self.fast.success()
                now = time.monotonic()
                if now - last >= 0.10:
                    last = now
                    x = "  n/a" if m.x is None else f"{m.x:5.3f}"
                    print(f"{lock:<9} x={x} turn={m.turn:5.3f} deg={m.turn_deg:5.1f} "
                          f"keyway={m.keyway_deg:6.2f} ui={m.ui_conf:4.2f} "
                          f"success={score:4.2f}{' HIT' if detected else ''}")
                time.sleep(0.01)
        finally:
            self.fast.close()
            if self.console:
                self.classic.restore_console(self.console)
        return 0

    def write_status(self, lock: str, success: bool, elapsed: float, mean_frame: float, overruns: int) -> None:
        atomic_json(STATUS_PATH, {
            "version": "0.19.0",
            "mode": "freelearn-live",
            "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
            "attempts": self.attempt,
            "successes": self.success_count,
            "success_rate": round(self.success_count / max(1, self.attempt), 4),
            "last_lock": lock,
            "last_result": "SUCCESS" if success else "FAIL",
            "last_elapsed_sec": round(elapsed, 3),
            "mean_frame_ms": round(mean_frame, 2),
            "mean_read_ms": round(self.frame_read_ms, 2),
            "overrun_frames": overruns,
            "turn_calibration": self.turn_cal.data,
        })

    def run(self) -> int:
        if not self.prepare():
            return 2
        print("F12 = stop, hold F10 = pause.\n")
        try:
            while self.args.attempts <= 0 or self.attempt < self.args.attempts:
                self.attempt += 1
                res = self.run_attempt()
                if res is None:
                    print("Stopped.")
                    break
                time.sleep(max(0.05, self.cfg.restart_wait_seconds))
        finally:
            try:
                self.classic.key_up(self.cfg.f_key_vk)
            except Exception:
                pass
            if self.fast is not None:
                self.fast.close()
            self.turn_cal.save()
            if self.console:
                self.classic.restore_console(self.console)
        rate = self.success_count / max(1, self.attempt)
        print(f"\nLive session: {self.success_count}/{self.attempt} opened ({100*rate:.1f}%)")
        return 0


# ---------------------------------------------------------------------------
# Offline self-test: proves the live observation contract equals the trainer's
# and measures how much the live-vision model costs the current policy.
# ---------------------------------------------------------------------------

def selftest(episodes: int = 256, perception_rounds: int = 6) -> int:
    import torch
    from freelearn_trainer import LockBatchEnv, policy as sim_policy

    cfg = load_config()
    print("=== FREELEARN live contract self-test ===")

    # 1) observation equality: ObsBuilder must reproduce LockBatchEnv.obs() exactly.
    env = LockBatchEnv(cfg, 4, seed=4242)
    env.vision_enabled = False          # clean sensor so observed == true state
    env.vision_scale = 0.0
    env.reset(np.arange(4, dtype=np.int64), balanced=True)
    builders = []
    for i in range(4):
        c = LockContract.from_config(cfg, LOCK_NAMES[int(env.lock_type[i])])
        b = ObsBuilder(c)
        b.reset(x_phys=float(env.pos[i]), turn=float(env.turn[i]))
        builders.append((c, b))
    rng = np.random.default_rng(0)
    worst = 0.0
    for _ in range(120):
        move = rng.random(4).astype(np.float32)
        mode = rng.integers(0, 3, size=4)
        mode = np.where((env.f_down > 0.5) & (mode == 1), 2, mode)
        env.step(move, mode)
        for i, (c, b) in enumerate(builders):
            f_active = int(env.last_action_mode[i]) in (1, 2)
            b.push(float(env.pos[i]), float(env.turn[i]), f_active, float(env.prev_mouse[i]))
            mine = b.vector(float(env.elapsed[i]))
            theirs = env.obs()[i]
            worst = max(worst, float(np.max(np.abs(mine - theirs))))
        done = env.elapsed >= env.time_limit
        if np.any(done):
            ids = np.flatnonzero(done)
            env.reset(ids)
            for i in ids:
                c = LockContract.from_config(cfg, LOCK_NAMES[int(env.lock_type[i])])
                b = ObsBuilder(c)
                b.reset(x_phys=float(env.pos[i]), turn=float(env.turn[i]))
                builders[int(i)] = (c, b)
    print(f"observation contract   : max |live - trainer| = {worst:.2e}")
    contract_ok = worst < 1e-5

    # 2) policy transfer: same checkpoint, clean sensor vs. full live-vision model.
    runner = PolicyRunner(LockContract.from_config(cfg, "Basic"))
    device = torch.device("cpu")
    results = {}
    for label, scale in (("clean sensor", 0.0), ("live vision", 1.0)):
        env = LockBatchEnv(cfg, episodes, seed=99)
        env.vision_enabled = scale > 0.0
        env.vision_scale = scale
        env.reset(np.arange(episodes, dtype=np.int64), balanced=True)
        total = np.zeros(4, np.int64)
        wins = np.zeros(4, np.int64)
        steps = int(round(max(float(cfg["locks"][n]["time_limit_sec"]) for n in LOCK_NAMES)
                          / (int(cfg["training"]["frame_ms"]) / 1000.0))) * 3
        for _ in range(steps):
            obs = env.obs()
            with torch.inference_mode():
                t_obs = torch.from_numpy(obs).to(device)
                t_f = torch.from_numpy((env.f_down > 0.5).astype(np.float32)).to(device)
                move, mode, _lp, _v = sim_policy(runner.model, t_obs, deterministic=False, old_f_down=t_f)
            _r, done, succ = env.step(move.cpu().numpy(), mode.cpu().numpy().astype(np.int64))
            if np.any(done):
                ids = np.flatnonzero(done)
                np.add.at(total, env.lock_type[ids], 1)
                np.add.at(wins, env.lock_type[ids], succ[ids].astype(np.int64))
                env.reset(ids)
        rates = wins / np.maximum(total, 1)
        results[label] = rates
        print(f"{label:<22}: " + "  ".join(f"{LOCK_NAMES[i]}={100*rates[i]:5.1f}%" for i in range(4))
              + f"  (n={int(total.sum())})")
    drop = float(np.mean(results["clean sensor"] - results["live vision"]))
    print(f"transfer gap (clean - live vision): {100*drop:+.1f} pp mean")

    # 3) perception in the loop: rendered frames -> live vision -> policy.
    if perception_rounds > 0:
        perception_selftest(rounds=perception_rounds)
    print("RESULT:", "OK" if contract_ok else "CONTRACT MISMATCH")
    return 0 if contract_ok else 1


def perception_selftest(rounds: int = 6, size: int = 520) -> Dict[str, float]:
    """Play the simulator through the real image pipeline.

    Every frame is rendered as a lock face, read back with the same vectorized
    keyway/pick detectors the live agent uses, and only that measurement reaches
    the policy. It is the closest offline proxy for in-game play: if the policy
    cannot open these, it cannot open SCUM locks either.
    """
    import math
    from freelearn_trainer import LockBatchEnv
    from freelearn_vision import RadialSampler, TurnCalibration, synthetic_lock_frame

    cfg = load_config()
    cal = TurnCalibration(path=LIVE_DIR / "turn_calibration_perception.json")
    cal.bootstrap_from_refs(force=True)
    radius = size * 0.30
    sampler = RadialSampler(size, radius)
    left_raw, right_raw = math.cos(math.radians(168.0)), math.cos(math.radians(12.0))

    runner = PolicyRunner(LockContract.from_config(cfg, "Basic"))
    env = LockBatchEnv(cfg, 4, seed=20260909)
    env.vision_enabled = False           # the rendering/measurement chain is the noise
    env.vision_scale = 0.0

    total = np.zeros(4, np.int64)
    wins = np.zeros(4, np.int64)
    turn_err: List[float] = []
    x_err: List[float] = []

    for _ in range(rounds):
        env.reset(np.arange(4, dtype=np.int64), balanced=True)
        env.lock_type[:] = np.arange(4)
        contracts = [LockContract.from_config(cfg, n) for n in LOCK_NAMES]
        builders = [ObsBuilder(c) for c in contracts]
        for i, b in enumerate(builders):
            b.reset(x_phys=float(env.pos[i]), turn=0.0)
        f_down = np.zeros(4, np.bool_)
        done_mask = np.zeros(4, np.bool_)
        prev_x = np.array([float(env.pos[i]) for i in range(4)], np.float64)
        steps = int(round(max(c.time_limit_sec for c in contracts) / contracts[0].dt))
        for _step in range(steps):
            moves = np.zeros(4, np.float32)
            modes = np.zeros(4, np.int64)
            for i in range(4):
                if done_mask[i]:
                    continue
                c = contracts[i]
                mv, md, _v = runner_act(runner, c, builders[i].vector(float(env.elapsed[i])), bool(f_down[i]))
                moves[i], modes[i] = mv, md
            modes = np.where(f_down & (modes == 1), 2, modes)
            _r, done, _s = env.step(moves, modes)
            for i in range(4):
                if done_mask[i]:
                    continue
                c = contracts[i]
                lock = LOCK_NAMES[i]
                true_turn = float(env.turn[i])
                true_x = float(env.pos[i]) / max(c.physical_max, 1e-6)
                e = cal.entry(lock)
                keyway = (e["rest_deg"] - true_turn * e["span_deg"]) % 180.0
                pick_raw = left_raw + true_x * (right_raw - left_raw)
                pick_deg = math.degrees(math.acos(float(np.clip(pick_raw, -1.0, 1.0))))
                frame = synthetic_lock_frame(size, radius, keyway, pick_deg)

                m_turn, _dark = sampler.keyway_angle(frame)
                meas_turn, _deg = cal.turn(lock, m_turn)
                m_pick, _score = sampler.pick_angle(frame)
                meas_raw = math.cos(math.radians(m_pick))
                meas_x = float(np.clip((meas_raw - left_raw) / (right_raw - left_raw), 0.0, 1.0))

                turn_err.append(abs(meas_turn - true_turn))
                x_err.append(abs(meas_x - true_x))

                f_active = int(env.last_action_mode[i]) in (1, 2)
                x_phys = meas_x * c.physical_max
                executed = (x_phys - prev_x[i]) if (int(env.last_action_mode[i]) == 0 and not f_active) else 0.0
                prev_x[i] = x_phys
                builders[i].push(x_phys, meas_turn, f_active, executed)
                f_down[i] = bool(env.f_down[i] > 0.5)
                if done[i]:
                    done_mask[i] = True
                    total[i] += 1
                    wins[i] += int(env.episode_success[i])
            if done_mask.all():
                break
        for i in range(4):
            if not done_mask[i]:
                total[i] += 1
                wins[i] += int(env.episode_success[i])
    try:
        (LIVE_DIR / "turn_calibration_perception.json").unlink()
    except OSError:
        pass
    rates = wins / np.maximum(total, 1)
    print("perception-in-the-loop (rendered lock -> vision -> policy):")
    print("  " + "  ".join(f"{LOCK_NAMES[i]}={100*rates[i]:5.1f}%" for i in range(4))
          + f"  (n={int(total.sum())})")
    print(f"  measured turn error: mean {np.mean(turn_err):.4f} | x error: mean {np.mean(x_err):.4f}")
    return {LOCK_NAMES[i]: float(rates[i]) for i in range(4)}


def runner_act(runner: PolicyRunner, contract: LockContract, vec: np.ndarray, f_down: bool):
    runner.c = contract
    return runner.act(vec, f_down)


def calibrate_only() -> int:
    import lockpick_learner as classic
    cfg = classic.Config.load()
    model = classic.QModel(cfg)
    vision, console, _hwnd = classic.prepare_live_vision(cfg, model, minimize=True)
    if vision is None:
        print("Could not lock onto the SCUM lock UI.")
        return 2
    ok = classic.auto_calibrate(cfg, model, vision)
    if console:
        classic.restore_console(console)
    return 0 if ok else 3


def main() -> int:
    ap = argparse.ArgumentParser(description="Run the FREELEARN policy live in SCUM.")
    ap.add_argument("--lock", default="Auto", choices=["Auto"] + LOCK_NAMES)
    ap.add_argument("--attempts", type=int, default=0, help="0 = until F12")
    ap.add_argument("--checkpoint", default=None, help="default: checkpoints/freelearn_best.pt")
    ap.add_argument("--stochastic", action="store_true", help="sample actions instead of the deterministic policy")
    ap.add_argument("--grace-sec", type=float, default=0.35, help="extra time after the simulated attempt budget")
    ap.add_argument("--trace", action="store_true", help="write data/live/last_episode_trace.json")
    ap.add_argument("--no-bridge-log", action="store_true", help="do not append probes to the REAL<->SIM dataset")
    ap.add_argument("--keep-console", action="store_true")
    ap.add_argument("--selftest", action="store_true", help="offline contract + transfer check (no game)")
    ap.add_argument("--perception-rounds", type=int, default=6,
                    help="rendered-frame episodes per lock in --selftest (0 = skip)")
    ap.add_argument("--calibrate", action="store_true", help="run X/mouse calibration only")
    ap.add_argument("--observe", action="store_true", help="print live screen readings without touching mouse/F")
    args = ap.parse_args()

    if args.selftest:
        return selftest(perception_rounds=args.perception_rounds)
    if os.name != "nt":
        print("Live play needs Windows (SendInput/GetAsyncKeyState + SCUM). Use --selftest here.")
        return 2
    if args.calibrate:
        return calibrate_only()
    if args.observe:
        return LiveAgent(args).observe_loop()
    return LiveAgent(args).run()


if __name__ == "__main__":
    raise SystemExit(main())
