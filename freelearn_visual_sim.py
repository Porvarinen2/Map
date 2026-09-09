"""Visual FREELEARN simulator: the policy sees rendered lock pixels, not numbers.

The fast simulator feeds the policy an analytic turn value with a hand-set error
model. This module closes that hole: every frame is rendered from the game's own
lock art (refs/lock_types/<Lock>.png with the cylinder rotated by the physical
turn, plus the pick bar at the physical X) and then measured with exactly the
reader the live agent uses. Whatever the reader gets wrong in game, it gets
wrong here too.

Two ways to use it:

  1. CALIBRATE (seconds). Sweep turn/X over the rendered art, compare the
     reader's output against the true state, fit gain/offset/noise/bias, and
     write the result into freelearn_config.json. The fast vectorized trainer
     then trains against a MEASURED sensor instead of a guessed one, at full
     speed.
        python freelearn_visual_sim.py --calibrate

  2. TRAIN/EVAL THROUGH THE PIXELS. Attach a VisualSensor to the batch env and
     the observation comes from rendered frames. Honest but ~3 orders of
     magnitude slower than the analytic sim, so it is a fine-tuning and
     validation tool, not the way to burn the first 17M attempts.
        python freelearn_trainer.py --visual --envs 96 --minutes 60
        python freelearn_visual_sim.py --eval
"""

from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import cv2
import numpy as np

from freelearn_vision import RadialSampler, TurnCalibration, angle_diff_deg

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "freelearn_config.json"
ART_DIR = ROOT / "refs" / "lock_types"
LOCK_NAMES = ["Rusted", "Basic", "Medium", "Enforced"]
LOCK_INDEX = {n: i for i, n in enumerate(LOCK_NAMES)}

# Canvas geometry. The art disc is the lock face; the canvas leaves room for the
# pick bar to stick out past it, the same way the game does.
DEFAULT_ART = 200
DEFAULT_CANVAS = 340
PICK_BGR = (38, 30, 132)
BACKGROUND_BGR = (34, 33, 30)


class LockArt:
    """Pre-rotated lock art plus a pick overlay, ready to compose per frame."""

    def __init__(self, lock: str, art_px: int = DEFAULT_ART, canvas_px: int = DEFAULT_CANVAS,
                 rot_step_deg: float = 1.0, span_deg: float = 90.0):
        self.lock = lock
        self.canvas = int(canvas_px)
        self.art_px = int(art_px)
        self.span_deg = float(span_deg)
        self.rot_step = float(rot_step_deg)

        img = cv2.imread(str(ART_DIR / f"{lock}.png"), cv2.IMREAD_COLOR)
        if img is None:
            raise FileNotFoundError(f"missing lock art: {ART_DIR / (lock + '.png')}")
        h, w = img.shape[:2]
        s = min(h, w)
        img = img[(h - s) // 2:(h - s) // 2 + s, (w - s) // 2:(w - s) // 2 + s]
        art = cv2.resize(img, (self.art_px, self.art_px), interpolation=cv2.INTER_AREA)

        base = np.full((self.canvas, self.canvas, 3), BACKGROUND_BGR, np.uint8)
        off = (self.canvas - self.art_px) // 2
        base[off:off + self.art_px, off:off + self.art_px] = art
        self.radius = 0.46 * self.art_px          # outer lock radius in canvas pixels
        self.center = self.canvas / 2.0

        # Only the cylinder turns; the outer ring and the surroundings stay put.
        yy, xx = np.ogrid[:self.canvas, :self.canvas]
        rr = np.sqrt((xx - self.center) ** 2 + (yy - self.center) ** 2)
        disc = rr <= (self.radius * 0.72)
        self.n_rot = int(round(self.span_deg / self.rot_step)) + 1
        self.frames = np.empty((self.n_rot, self.canvas, self.canvas, 3), np.uint8)
        for i in range(self.n_rot):
            deg = i * self.rot_step
            M = cv2.getRotationMatrix2D((self.center, self.center), -deg, 1.0)
            rot = cv2.warpAffine(base, M, (self.canvas, self.canvas), flags=cv2.INTER_LINEAR,
                                 borderMode=cv2.BORDER_REPLICATE)
            f = base.copy()
            f[disc] = rot[disc]
            self.frames[i] = f

        # Pick bar overlays, indexed by angle, stored as flat pixel indices so a
        # frame is composed with one scatter instead of a draw call.
        self.pick_step = 0.5
        self.pick_degs = np.arange(12.0, 168.0 + 1e-6, self.pick_step, dtype=np.float32)
        thickness = max(3, int(round(self.radius * 0.055)))
        self.pick_idx: List[np.ndarray] = []
        for deg in self.pick_degs:
            mask = np.zeros((self.canvas, self.canvas), np.uint8)
            th = math.radians(float(deg))
            p0 = (int(round(self.center + math.cos(th) * self.radius * 0.30)),
                  int(round(self.center - math.sin(th) * self.radius * 0.30)))
            p1 = (int(round(self.center + math.cos(th) * self.radius * 1.30)),
                  int(round(self.center - math.sin(th) * self.radius * 1.30)))
            cv2.line(mask, p0, p1, 255, thickness)
            self.pick_idx.append(np.flatnonzero(mask.reshape(-1)).astype(np.int32))

    def frame(self, turn: float, x: float, out: Optional[np.ndarray] = None) -> np.ndarray:
        """Render one lock face: cylinder turned by `turn`, pick at normalized `x`."""
        ri = int(round(float(np.clip(turn, 0.0, 1.0)) * self.span_deg / self.rot_step))
        ri = int(np.clip(ri, 0, self.n_rot - 1))
        img = self.frames[ri] if out is None else np.copyto(out, self.frames[ri]) or out
        if out is None:
            img = self.frames[ri].copy()
        deg = 168.0 - float(np.clip(x, 0.0, 1.0)) * (168.0 - 12.0)
        pi = int(np.clip(round((deg - 12.0) / self.pick_step), 0, len(self.pick_degs) - 1))
        img.reshape(-1, 3)[self.pick_idx[pi]] = PICK_BGR
        return img


class VisualSensor:
    """Renders each env's lock face and measures it with the live reader."""

    def __init__(self, art_px: int = DEFAULT_ART, canvas_px: int = DEFAULT_CANVAS,
                 quality: str = "fast", pick_fine: Optional[bool] = None,
                 calibration: Optional[TurnCalibration] = None):
        """quality "live" reproduces the in-game sampling geometry exactly and is
        used for calibration; "fast" keeps the same algorithm on a coarser grid so
        PPO can actually collect episodes through the renderer."""
        self.arts = {name: LockArt(name, art_px, canvas_px) for name in LOCK_NAMES}
        any_art = self.arts[LOCK_NAMES[0]]
        self.canvas = any_art.canvas
        self.quality = quality
        if quality == "live":
            self.sampler = RadialSampler(self.canvas, any_art.radius)
            self.pick_fine = True if pick_fine is None else bool(pick_fine)
        else:
            self.sampler = RadialSampler(
                self.canvas, any_art.radius,
                turn_step_deg=2.0, turn_samples=21, turn_offsets=(-3.0, 0.0, 3.0),
                pick_step_deg=2.0, pick_samples=30)
            self.pick_fine = False if pick_fine is None else bool(pick_fine)
        self.cal = calibration or TurnCalibration(path=ROOT / "data" / "live" / "turn_calibration_visual.json")
        self._self_calibrate()
        self._buf = np.empty((self.canvas, self.canvas, 3), np.uint8)
        self._batch: Optional[np.ndarray] = None
        self.frames_rendered = 0

    def _self_calibrate(self) -> None:
        """Measure this sensor's own rendered rest/full-turn frames.

        The screen angle a reader reports depends on its sampling radius, so the
        rest angle and the full-turn span have to be measured with the same
        sampler that will read the frames. (The live agent does the equivalent by
        re-zeroing the rest angle on every attempt and widening the span when it
        sees a larger rotation.)
        """
        for lock, art in self.arts.items():
            rest = self.sampler.keyway_angle(art.frames[0])[0]
            full = self.sampler.keyway_angle(art.frames[-1])[0]
            span = abs(angle_diff_deg(full, rest))
            e = self.cal.entry(lock)
            e["rest_deg"] = float(rest % 180.0)
            if span >= 25.0:
                e["span_deg"] = float(np.clip(span, 25.0, 90.0))

    def measure_one(self, lock: str, turn: float, x: float) -> Tuple[float, float]:
        art = self.arts[lock]
        img = art.frame(turn, x, out=self._buf)
        keyway, _dark = self.sampler.keyway_angle(img)
        t_meas, _deg = self.cal.turn(lock, keyway)
        pick_deg, _score = self.sampler.pick_angle(img, fine=self.pick_fine)
        x_meas = float(np.clip((168.0 - pick_deg) / (168.0 - 12.0), 0.0, 1.0))
        self.frames_rendered += 1
        return t_meas, x_meas

    # -- batched path used by the trainer ------------------------------------
    @staticmethod
    def _refine_batch(vals: np.ndarray, idx: np.ndarray, wrap: bool) -> np.ndarray:
        """Parabolic sub-index offset around idx for every row of vals."""
        n, m = vals.shape
        rows = np.arange(n)
        im = (idx - 1) % m if wrap else np.clip(idx - 1, 0, m - 1)
        ip = (idx + 1) % m if wrap else np.clip(idx + 1, 0, m - 1)
        a, b, c = vals[rows, im], vals[rows, idx], vals[rows, ip]
        den = a - 2.0 * b + c
        off = np.where(np.abs(den) < 1e-9, 0.0, 0.5 * (a - c) / np.where(np.abs(den) < 1e-9, 1.0, den))
        if not wrap:
            off = np.where((idx <= 0) | (idx >= m - 1), 0.0, off)
        return np.clip(off, -0.5, 0.5)

    def _compose_batch(self, lock_type: np.ndarray, turn: np.ndarray, xn: np.ndarray) -> np.ndarray:
        n = len(turn)
        if self._batch is None or self._batch.shape[0] < n:
            self._batch = np.empty((n, self.canvas, self.canvas, 3), np.uint8)
        for i in range(n):
            art = self.arts[LOCK_NAMES[int(lock_type[i])]]
            ri = int(np.clip(round(float(np.clip(turn[i], 0.0, 1.0)) * art.span_deg / art.rot_step),
                             0, art.n_rot - 1))
            np.copyto(self._batch[i], art.frames[ri])
            deg = 168.0 - float(np.clip(xn[i], 0.0, 1.0)) * (168.0 - 12.0)
            pi = int(np.clip(round((deg - 12.0) / art.pick_step), 0, len(art.pick_degs) - 1))
            self._batch[i].reshape(-1, 3)[art.pick_idx[pi]] = PICK_BGR
        self.frames_rendered += n
        return self._batch[:n]

    def measure(self, lock_type: np.ndarray, turn: np.ndarray, pos: np.ndarray,
                allowed_max: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
        """Render and read every env's lock face in one batched pass."""
        n = len(turn)
        xn = np.clip(pos / np.maximum(allowed_max, 1e-6), 0.0, 1.0)
        frames = self._compose_batch(lock_type, turn, xn)
        flat = frames.reshape(n, -1, 3)
        s = self.sampler

        px = flat[:, s.turn_idx.reshape(-1), :].astype(np.float32)
        gray = 0.114 * px[..., 0] + 0.587 * px[..., 1] + 0.299 * px[..., 2]
        vals = gray.reshape(n, s.turn_idx.shape[0], s.turn_idx.shape[1]).mean(axis=2)
        # Same orientation-tensor estimator as the live reader, batched.
        d = vals.max(axis=1, keepdims=True) - vals
        thr = np.percentile(d, s.KEYWAY_KEEP_PCT, axis=1, keepdims=True)
        w = np.clip(d - thr, 0.0, None)
        keyway = (0.5 * np.degrees(np.arctan2(w @ s.turn_sin2, w @ s.turn_cos2))) % 180.0

        cpx = flat[:, s.pick_center_idx.reshape(-1), :].astype(np.float32)
        spx = flat[:, s.pick_side_idx.reshape(-1), :].astype(np.float32)
        center = self._redness(cpx).reshape(n, len(s.pick_degs), s.n_center_off, s.n_pick_ts).mean(axis=2)
        sides = self._redness(spx).reshape(n, len(s.pick_degs), s.n_side_off, s.n_pick_ts).mean(axis=2)
        scores = np.clip(center - sides, 0.0, None).mean(axis=2) + 0.23 * center.mean(axis=2)
        pi = np.argmax(scores, axis=1)
        poff = self._refine_batch(scores, pi, wrap=False)
        pick_deg = s.pick_degs[pi] + poff

        t_out = np.empty(n, np.float32)
        for i in range(n):
            t_out[i] = self.cal.turn(LOCK_NAMES[int(lock_type[i])], float(keyway[i]))[0]
        x_out = np.clip((168.0 - pick_deg) / (168.0 - 12.0), 0.0, 1.0).astype(np.float32)
        return t_out, (x_out * allowed_max).astype(np.float32)

    @staticmethod
    def _redness(px: np.ndarray) -> np.ndarray:
        b, g, r = px[..., 0], px[..., 1], px[..., 2]
        chroma = np.maximum(np.maximum(r, g), b) - np.minimum(np.minimum(r, g), b)
        return (r - 0.5 * (g + b)) + 0.07 * chroma


# ---------------------------------------------------------------------------
# Calibration: measure the reader, then teach the fast simulator what it does.
# ---------------------------------------------------------------------------

# The live capture is much larger than the training canvas, and angular
# precision scales with pixels, so calibration renders at the real in-game scale
# (ScreenVision radius is about 0.20 of screen height -> ~216 px at 1080p).
LIVE_ART_PX = 470
LIVE_CANVAS_PX = 800


def calibrate(samples: int = 24, write: bool = True, art_px: int = LIVE_ART_PX,
              canvas_px: int = LIVE_CANVAS_PX) -> dict:
    cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    sensor = VisualSensor(quality="live", art_px=art_px, canvas_px=canvas_px)
    rng = np.random.default_rng(11)
    turns = np.linspace(0.0, 1.0, samples)
    xs = np.linspace(0.02, 0.98, samples)

    per_lock: Dict[str, dict] = {}
    t_gain_all, t_off_all, t_res_all, x_bias_all, x_res_all = [], [], [], [], []
    t0 = time.perf_counter()
    for lock in LOCK_NAMES:
        tt, tm, xt, xm = [], [], [], []
        for t in turns:
            for x in xs:
                mt, mx = sensor.measure_one(lock, float(t), float(x))
                tt.append(t); tm.append(mt); xt.append(x); xm.append(mx)
        tt = np.asarray(tt); tm = np.asarray(tm)
        xt = np.asarray(xt); xm = np.asarray(xm)
        # measured_turn ~ gain * true_turn + offset
        A = np.stack([tt, np.ones_like(tt)], axis=1)
        gain, offset = np.linalg.lstsq(A, tm, rcond=None)[0]
        t_res = float(np.std(tm - (gain * tt + offset)))
        x_bias = float(np.mean(xm - xt))
        x_res = float(np.std(xm - xt - x_bias))
        per_lock[lock] = {
            "turn_gain": round(float(gain), 5), "turn_offset": round(float(offset), 5),
            "turn_residual_std": round(t_res, 5), "turn_max_abs_error": round(float(np.max(np.abs(tm - tt))), 5),
            "x_bias": round(x_bias, 5), "x_residual_std": round(x_res, 5),
            "x_max_abs_error": round(float(np.max(np.abs(xm - xt))), 5),
        }
        t_gain_all.append(gain); t_off_all.append(offset); t_res_all.append(t_res)
        x_bias_all.append(abs(x_bias)); x_res_all.append(x_res)
    dur = time.perf_counter() - t0

    gain_err = float(np.max(np.abs(np.asarray(t_gain_all) - 1.0)))
    off_err = float(np.max(np.abs(t_off_all)))
    turn_noise = float(np.max(t_res_all))
    x_bias = float(np.max(x_bias_all))
    x_noise = float(np.max(x_res_all))

    vision = dict(cfg.get("vision", {}) or {})
    # Widen the fitted values a little: the game adds lighting, motion blur and
    # UI overdraw that the still art does not, and the policy must not be
    # trained tighter than the sensor it will actually get.
    vision.update({
        "turn_gain_error": round(float(np.clip(gain_err * 1.5 + 0.01, 0.01, 0.30)), 4),
        "turn_offset_error": round(float(np.clip(off_err * 1.5 + 0.005, 0.005, 0.10)), 4),
        "turn_noise": round(float(np.clip(turn_noise * 1.5 + 0.002, 0.002, 0.05)), 4),
        "turn_quant": round(float(np.clip(turn_noise, 0.001, 0.02)), 4),
        "x_bias": round(float(np.clip(x_bias * 1.5 + 0.002, 0.001, 0.03)), 4),
        "x_noise": round(float(np.clip(x_noise * 1.5 + 0.001, 0.001, 0.02)), 4),
        "x_quant": round(float(np.clip(x_noise, 0.0005, 0.01)), 4),
        "calibrated_from": "rendered lock art measured with freelearn_vision",
        "calibrated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "calibration_locks": per_lock,
    })

    print(f"Vision calibration over {samples * samples * len(LOCK_NAMES):,} rendered frames "
          f"({dur:.1f}s, {samples*samples*len(LOCK_NAMES)/max(dur,1e-6):.0f} frames/s)")
    for lock in LOCK_NAMES:
        e = per_lock[lock]
        print(f"  {lock:<9} turn gain {e['turn_gain']:.3f} offset {e['turn_offset']:+.4f} "
              f"noise {e['turn_residual_std']:.4f} (max err {e['turn_max_abs_error']:.4f}) | "
              f"x bias {e['x_bias']:+.4f} noise {e['x_residual_std']:.4f} (max err {e['x_max_abs_error']:.4f})")
    print(f"  -> vision model: gain +-{100*vision['turn_gain_error']:.1f}%  offset +-{vision['turn_offset_error']:.3f}  "
          f"turn noise {vision['turn_noise']:.4f}  x bias +-{vision['x_bias']:.4f}  x noise {vision['x_noise']:.4f}")

    if write:
        cfg["vision"] = vision
        CONFIG_PATH.write_text(json.dumps(cfg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"  written to {CONFIG_PATH.name} (restart training to apply)")
    return vision


# ---------------------------------------------------------------------------
# Evaluation straight through the pixels.
# ---------------------------------------------------------------------------

def evaluate(episodes: int = 64, envs: int = 32, checkpoint: Optional[str] = None,
             quality: str = "fast") -> Dict[str, float]:
    import torch
    from freelearn_obs import LockContract, PolicyRunner, load_config
    from freelearn_trainer import LockBatchEnv, policy as sim_policy

    cfg = load_config()
    runner = PolicyRunner(LockContract.from_config(cfg, "Basic"),
                          checkpoint=Path(checkpoint) if checkpoint else None,
                          deterministic=False)
    env = LockBatchEnv(cfg, envs, seed=4711)
    env.visual_sensor = VisualSensor(quality=quality)
    env.reset(np.arange(envs, dtype=np.int64), balanced=True)

    total = np.zeros(4, np.int64)
    wins = np.zeros(4, np.int64)
    t0 = time.perf_counter()
    steps = 0
    while total.sum() < episodes:
        obs = env.obs()
        with torch.inference_mode():
            move, mode, _lp, _v = sim_policy(
                runner.model, torch.from_numpy(obs), deterministic=False,
                old_f_down=torch.from_numpy((env.f_down > 0.5).astype(np.float32)))
        _r, done, succ = env.step(move.numpy(), mode.numpy().astype(np.int64))
        steps += 1
        if np.any(done):
            ids = np.flatnonzero(done)
            np.add.at(total, env.lock_type[ids], 1)
            np.add.at(wins, env.lock_type[ids], succ[ids].astype(np.int64))
            env.reset(ids)
    dur = time.perf_counter() - t0
    rates = wins / np.maximum(total, 1)
    print(f"visual evaluation ({checkpoint or 'default checkpoint'}), {int(total.sum())} episodes "
          f"through rendered frames in {dur:.1f}s "
          f"({envs*steps/max(dur,1e-6):.0f} env-steps/s, {total.sum()/max(dur,1e-6):.1f} attempts/s)")
    print("  " + "  ".join(f"{LOCK_NAMES[i]}={100*rates[i]:5.1f}%" for i in range(4)))
    return {LOCK_NAMES[i]: float(rates[i]) for i in range(4)}


def benchmark(n: int = 40) -> None:
    rng = np.random.default_rng(3)
    for quality in ("live", "fast"):
        for envs in (32, 96, 256):
            s = VisualSensor(quality=quality)
            lt = rng.integers(0, 4, envs)
            turn = rng.random(envs).astype(np.float32)
            pos = rng.random(envs).astype(np.float32)
            amax = np.ones(envs, np.float32)
            s.measure(lt, turn, pos, amax)
            t0 = time.perf_counter()
            for _ in range(n):
                s.measure(lt, turn, pos, amax)
            dur = (time.perf_counter() - t0) / n
            print(f"quality={quality:<4} envs={envs:3d}: {1000*dur:7.1f} ms/step  "
                  f"{envs/dur:7.0f} env-steps/s  ~{envs/dur/120:5.1f} attempts/s")


def main() -> int:
    ap = argparse.ArgumentParser(description="Visual FREELEARN simulator (rendered lock art).")
    ap.add_argument("--calibrate", action="store_true", help="fit the fast simulator's sensor model from pixels")
    ap.add_argument("--samples", type=int, default=24, help="grid resolution per axis for --calibrate")
    ap.add_argument("--dry-run", action="store_true", help="calibrate but do not write the config")
    ap.add_argument("--art-px", type=int, default=LIVE_ART_PX, help="render scale for --calibrate")
    ap.add_argument("--canvas-px", type=int, default=LIVE_CANVAS_PX)
    ap.add_argument("--eval", action="store_true", help="evaluate a checkpoint through rendered frames")
    ap.add_argument("--episodes", type=int, default=64)
    ap.add_argument("--envs", type=int, default=32)
    ap.add_argument("--quality", default="fast", choices=["fast", "live"])
    ap.add_argument("--checkpoint", default=None)
    ap.add_argument("--benchmark", action="store_true")
    args = ap.parse_args()

    if args.benchmark:
        benchmark()
        return 0
    if args.eval:
        evaluate(args.episodes, args.envs, args.checkpoint, args.quality)
        return 0
    calibrate(samples=args.samples, write=not args.dry_run, art_px=args.art_px, canvas_px=args.canvas_px)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
