"""Frame-rate visual lock reader for live FREELEARN play.

The FREELEARN policy decides every 25 ms from two measured signals: where its
own pick is, and how far the lock cylinder has visibly turned. The classic
``lockpick_learner.ScreenVision`` measures both, but its per-angle Python loops
cost tens of milliseconds per frame, which is far too slow for a 25 ms control
loop, and its turn value is a raw 1-degree bucket.

This module provides the same measurements with:
  * fully vectorized radial sampling (one gather per frame instead of ~340
    Python-level line scans),
  * sub-degree parabolic refinement of both the keyway angle and the pick angle,
  * a per-lock turn calibration (rest angle + full-turn span) so the screen angle
    maps onto the same 0..1 ``turn`` the simulator trains on,
  * SUCCESS template matching moved onto a background thread so it never blocks
    a control frame.

Nothing here reveals hidden geometry: the reader only measures what is drawn on
the screen.
"""

from __future__ import annotations

import json
import math
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent
LIVE_DIR = ROOT / "data" / "live"
TURN_CAL_PATH = LIVE_DIR / "turn_calibration.json"

LOCK_NAMES = ["Rusted", "Basic", "Medium", "Enforced"]

# Keyway rest orientation in the sampler's angle convention (90 deg = vertical).
DEFAULT_REST_DEG = 90.0
# How many degrees of visible cylinder rotation correspond to a fully turned lock.
DEFAULT_SPAN_DEG = 90.0
MIN_SPAN_DEG = 25.0
MAX_SPAN_DEG = 90.0


def _atomic_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8")
    tmp.replace(path)


def angle_diff_deg(a: float, b: float) -> float:
    """Signed difference of two undirected line angles, folded to (-90, 90]."""
    d = (float(a) - float(b) + 90.0) % 180.0 - 90.0
    return float(d)


@dataclass
class Measurement:
    t: float
    turn: float                 # visible lock turn, 0..1 (simulator scale)
    turn_deg: float             # measured cylinder rotation away from rest
    keyway_deg: float           # raw keyway line angle
    darkness: float             # keyway contrast confidence 0..1
    pick_raw: Optional[float]   # cos(pick angle), the calibration axis
    pick_deg: Optional[float]
    pick_score: float
    x: Optional[float]          # normalized pick position 0..1 (needs calibration)
    x_conf: float
    ui_conf: float


class RadialSampler:
    """Precomputed radial line indices for one capture geometry."""

    def __init__(self, size: int, radius: float):
        self.size = int(size)
        self.radius = float(radius)
        c = self.size / 2.0

        # Keyway/cylinder rotation: dark slot across the lock face.
        self.turn_degs = np.arange(0.0, 180.0, 1.0, dtype=np.float32)
        ts_turn = np.linspace(-0.45 * self.radius, 0.45 * self.radius, 81, dtype=np.float32)
        self.turn_idx = self._indices(self.turn_degs, ts_turn, (-3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0), c)

        # Pick bar: reddish radial bar in the upper half of the lock UI.
        self.pick_degs = np.arange(12.0, 168.5, 1.0, dtype=np.float32)
        ts_pick = np.linspace(0.18 * self.radius, 1.45 * self.radius, 120, dtype=np.float32)
        self.pick_center_off = (-5.0, 0.0, 5.0)
        self.pick_side_off = (-22.0, -18.0, 18.0, 22.0)
        self.pick_ts = ts_pick
        self.pick_center_idx = self._indices(self.pick_degs, ts_pick, self.pick_center_off, c)
        self.pick_side_idx = self._indices(self.pick_degs, ts_pick, self.pick_side_off, c)
        self.n_pick_ts = len(ts_pick)
        self.n_center_off = len(self.pick_center_off)
        self.n_side_off = len(self.pick_side_off)
        self.center = c

    def _indices(self, degs: np.ndarray, ts: np.ndarray, offs: Tuple[float, ...], c: float) -> np.ndarray:
        th = np.radians(degs.astype(np.float64))[:, None, None]
        t = ts.astype(np.float64)[None, None, :]
        o = np.asarray(offs, np.float64)[None, :, None]
        xs = c + t * np.cos(th) + o * (-np.sin(th))
        ys = c - t * np.sin(th) + o * (-np.cos(th))
        xs = np.clip(np.rint(xs), 0, self.size - 1).astype(np.int32)
        ys = np.clip(np.rint(ys), 0, self.size - 1).astype(np.int32)
        return (ys * self.size + xs).reshape(len(degs), -1)

    @staticmethod
    def _refine(values: np.ndarray, i: int, wrap: bool) -> float:
        """Parabolic sub-sample offset around index i (values are 1 deg apart)."""
        n = len(values)
        if wrap:
            im, ip = (i - 1) % n, (i + 1) % n
        else:
            if i <= 0 or i >= n - 1:
                return 0.0
            im, ip = i - 1, i + 1
        a, b, c = float(values[im]), float(values[i]), float(values[ip])
        den = a - 2.0 * b + c
        if abs(den) < 1e-9:
            return 0.0
        return float(np.clip(0.5 * (a - c) / den, -0.5, 0.5))

    def keyway_angle(self, gray: np.ndarray) -> Tuple[float, float]:
        """Darkest line orientation across the lock face -> (angle_deg, darkness)."""
        flat = gray.reshape(-1)
        vals = flat[self.turn_idx].mean(axis=1)
        i = int(np.argmin(vals))
        # A dark slot is a minimum, so refine on the inverted curve.
        off = self._refine(-vals, i, wrap=True)
        angle = float((self.turn_degs[i] + off) % 180.0)
        darkness = float(np.clip((90.0 - float(vals[i])) / 90.0, 0.0, 1.0))
        return angle, darkness

    def _pick_scores(self, flat: np.ndarray, center_idx: np.ndarray, side_idx: np.ndarray, n: int) -> np.ndarray:
        center = flat[center_idx].reshape(n, self.n_center_off, self.n_pick_ts).mean(axis=1)
        sides = flat[side_idx].reshape(n, self.n_side_off, self.n_pick_ts).mean(axis=1)
        contrast = np.clip(center - sides, 0.0, None)
        return contrast.mean(axis=1) + 0.23 * center.mean(axis=1)

    def pick_angle(self, redness: np.ndarray, fine: bool = True) -> Tuple[Optional[float], float]:
        """Reddish radial bar angle -> (angle_deg, score). Same score as the classic detector.

        The X target of the hardest locks is a fraction of a percent of the board,
        so the coarse 1 degree scan is followed by a 0.1 degree rescan around the
        winner. That second pass costs ~20 extra lines instead of 157.
        """
        flat = redness.reshape(-1)
        scores = self._pick_scores(flat, self.pick_center_idx, self.pick_side_idx, len(self.pick_degs))
        i = int(np.argmax(scores))
        angle = float(self.pick_degs[i] + self._refine(scores, i, wrap=False))
        best = float(scores[i])
        if fine:
            degs = np.arange(angle - 1.0, angle + 1.0001, 0.1, dtype=np.float32)
            cidx = self._indices(degs, self.pick_ts, self.pick_center_off, self.center)
            sidx = self._indices(degs, self.pick_ts, self.pick_side_off, self.center)
            fs = self._pick_scores(flat, cidx, sidx, len(degs))
            j = int(np.argmax(fs))
            angle = float(degs[j] + 0.1 * self._refine(fs, j, wrap=False))
            best = float(fs[j])
        return angle, best


def _circular_mean_deg(angles: List[float]) -> float:
    """Mean of undirected line angles (0..180 wraps onto itself)."""
    v = np.exp(2j * np.radians(np.asarray(angles, np.float64)))
    return float((np.degrees(np.angle(v.mean())) / 2.0) % 180.0)


def _measure_reference_angle(path: Path) -> Optional[float]:
    """Keyway angle of a bundled square lock reference image."""
    img = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if img is None or img.size == 0:
        return None
    h, w = img.shape[:2]
    s = min(h, w)
    img = img[(h - s) // 2:(h - s) // 2 + s, (w - s) // 2:(w - s) // 2 + s]
    gray = cv2.GaussianBlur(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), (3, 3), 0).astype(np.float32)
    angles = []
    for rf in (0.42, 0.46, 0.50):
        angles.append(RadialSampler(s, s * rf).keyway_angle(gray)[0])
    return _circular_mean_deg(angles)


class TurnCalibration:
    """Per-lock mapping from screen keyway angle to simulator turn 0..1."""

    def __init__(self, path: Path = TURN_CAL_PATH):
        self.path = Path(path)
        self.data: Dict[str, Dict[str, float]] = {}
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                self.data = {k: dict(v) for k, v in raw.get("locks", {}).items() if isinstance(v, dict)}
        except Exception:
            self.data = {}

    def entry(self, lock: str) -> Dict[str, float]:
        e = self.data.setdefault(lock, {})
        e.setdefault("rest_deg", DEFAULT_REST_DEG)
        e.setdefault("span_deg", DEFAULT_SPAN_DEG)
        e.setdefault("observed_max_deg", 0.0)
        e.setdefault("success_samples", 0.0)
        return e

    def turn(self, lock: str, keyway_deg: float) -> Tuple[float, float]:
        e = self.entry(lock)
        deg = abs(angle_diff_deg(keyway_deg, e["rest_deg"]))
        span = float(np.clip(e["span_deg"], MIN_SPAN_DEG, MAX_SPAN_DEG))
        return float(np.clip(deg / span, 0.0, 1.0)), float(deg)

    def note_rest(self, lock: str, keyway_deg: float, weight: float = 0.05) -> None:
        """Slowly re-zero the resting keyway angle while the lock is untouched."""
        e = self.entry(lock)
        d = angle_diff_deg(keyway_deg, e["rest_deg"])
        if abs(d) <= 12.0:
            e["rest_deg"] = float((e["rest_deg"] + weight * d) % 180.0)

    def note_turn(self, lock: str, deg: float) -> None:
        e = self.entry(lock)
        e["observed_max_deg"] = max(float(e["observed_max_deg"]), float(deg))

    def note_success(self, lock: str, deg: float, weight: float = 0.25) -> None:
        """A confirmed SUCCESS tells us what a full turn looks like on screen."""
        e = self.entry(lock)
        span = float(np.clip(deg, MIN_SPAN_DEG, MAX_SPAN_DEG))
        e["span_deg"] = float(np.clip((1.0 - weight) * e["span_deg"] + weight * span, MIN_SPAN_DEG, MAX_SPAN_DEG))
        e["success_samples"] = float(e["success_samples"]) + 1.0

    def bootstrap_from_refs(self, force: bool = False) -> Dict[str, Dict[str, float]]:
        """Seed rest/span from the bundled lock reference art.

        refs/lock_types/<Lock>.png shows an untouched lock (keyway vertical) and
        refs/lock_success_angles/<Lock>Success.png the same lock at the moment it
        opens (keyway horizontal). The angle between them is exactly the screen
        span of a full turn, so the live turn value lands on the simulator scale
        before the agent has ever opened a lock.
        """
        out: Dict[str, Dict[str, float]] = {}
        for lock in LOCK_NAMES:
            e = self.entry(lock)
            if not force and float(e.get("success_samples", 0.0)) > 0.0:
                continue
            rest = _measure_reference_angle(ROOT / "refs" / "lock_types" / f"{lock}.png")
            done = _measure_reference_angle(ROOT / "refs" / "lock_success_angles" / f"{lock}Success.png")
            if rest is None or done is None:
                continue
            span = abs(angle_diff_deg(done, rest))
            if span < MIN_SPAN_DEG:
                continue
            e["rest_deg"] = float(rest % 180.0)
            e["span_deg"] = float(np.clip(span, MIN_SPAN_DEG, MAX_SPAN_DEG))
            e["bootstrap"] = 1.0
            out[lock] = {"rest_deg": e["rest_deg"], "span_deg": e["span_deg"]}
        return out

    def save(self) -> None:
        _atomic_json(self.path, {
            "version": "0.19.0",
            "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
            "note": "rest_deg = keyway angle of an untouched lock; span_deg = screen degrees of a full turn",
            "locks": self.data,
        })


class SuccessWatcher(threading.Thread):
    """Runs the (expensive) SUCCESS template match off the control loop."""

    def __init__(self, detect: Callable[[np.ndarray], Tuple[float, bool]], min_interval: float = 0.06):
        super().__init__(daemon=True)
        self.detect = detect
        self.min_interval = float(min_interval)
        self._lock = threading.Lock()
        self._pending: Optional[np.ndarray] = None
        self._score = 0.0
        self._detected = False
        self._detected_at = 0.0
        self._last_run = 0.0
        self.stop = False

    def submit(self, frame: np.ndarray) -> None:
        now = time.monotonic()
        if now - self._last_run < self.min_interval:
            return
        with self._lock:
            if self._pending is None:
                self._pending = frame.copy()

    def poll(self) -> Tuple[float, bool, float]:
        with self._lock:
            return self._score, self._detected, self._detected_at

    def clear(self) -> None:
        with self._lock:
            self._score = 0.0
            self._detected = False
            self._detected_at = 0.0

    def run(self) -> None:
        while not self.stop:
            with self._lock:
                frame = self._pending
                self._pending = None
            if frame is None:
                time.sleep(0.004)
                continue
            self._last_run = time.monotonic()
            try:
                score, detected = self.detect(frame)
            except Exception:
                score, detected = 0.0, False
            with self._lock:
                self._score = float(score)
                if detected:
                    self._detected = True
                    self._detected_at = time.monotonic()


class FastLockVision:
    """Fast per-frame lock reading on top of a classic ScreenVision."""

    def __init__(self, vision, lock: str = "Basic", calibration: Optional[TurnCalibration] = None,
                 success_watcher: bool = True):
        self.vision = vision
        self.lock = lock
        self.cal = calibration or TurnCalibration()
        self.sampler = RadialSampler(size=int(vision.half * 2), radius=float(vision.radius))
        self.last_pick_raw: Optional[float] = None
        self.last_pick_score = 0.0
        self.last_x: Optional[float] = None
        self.last_frame: Optional[np.ndarray] = None
        self.watcher: Optional[SuccessWatcher] = None
        if success_watcher:
            self.watcher = SuccessWatcher(lambda f: self.vision.detect_success(f))
            self.watcher.start()

    # -- geometry may drift if ScreenVision re-centres ------------------------
    def refresh_geometry(self) -> None:
        size = int(self.vision.half * 2)
        if size != self.sampler.size or abs(float(self.vision.radius) - self.sampler.radius) > 0.5:
            self.sampler = RadialSampler(size=size, radius=float(self.vision.radius))

    def set_lock(self, lock: str) -> None:
        self.lock = lock

    def _normalize_x(self, raw: Optional[float]) -> Optional[float]:
        if raw is None:
            return None
        cal = getattr(self.vision, "cal", {}) or {}
        left = cal.get("pick_left_raw")
        right = cal.get("pick_right_raw")
        if left is None or right is None or abs(float(right) - float(left)) < 1e-5:
            return None
        return float(np.clip((raw - float(left)) / (float(right) - float(left)), 0.0, 1.0))

    def read(self, need_pick: bool = True, want_success: bool = False) -> Measurement:
        frame = self.vision.grab()
        self.last_frame = frame
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        gray = cv2.GaussianBlur(gray, (3, 3), 0).astype(np.float32)
        keyway_deg, darkness = self.sampler.keyway_angle(gray)
        turn, turn_deg = self.cal.turn(self.lock, keyway_deg)

        pick_raw = self.last_pick_raw
        pick_score = self.last_pick_score * 0.7
        pick_deg = None
        if need_pick:
            f = frame.astype(np.float32)
            b, g, r = f[:, :, 0], f[:, :, 1], f[:, :, 2]
            mx = np.maximum(np.maximum(r, g), b)
            mn = np.minimum(np.minimum(r, g), b)
            redness = (r - 0.5 * (g + b)) + 0.07 * (mx - mn)
            deg, score = self.sampler.pick_angle(redness)
            if deg is not None and score > 2.0:
                pick_deg = deg
                pick_raw = float(math.cos(math.radians(deg)))
                pick_score = float(score)
                self.last_pick_raw = pick_raw
                self.last_pick_score = pick_score

        x = self._normalize_x(pick_raw)
        if x is not None:
            self.last_x = x
        pick_conf = float(np.clip((pick_score - 1.0) / 10.0, 0.0, 1.0))
        ui_conf = 0.55 * darkness + 0.45 * pick_conf

        if self.watcher is not None and want_success:
            self.watcher.submit(frame)

        return Measurement(
            t=time.monotonic(), turn=turn, turn_deg=turn_deg, keyway_deg=keyway_deg,
            darkness=darkness, pick_raw=pick_raw, pick_deg=pick_deg, pick_score=pick_score,
            x=x, x_conf=pick_conf, ui_conf=ui_conf,
        )

    def success(self) -> Tuple[float, bool, float]:
        if self.watcher is None:
            return 0.0, False, 0.0
        return self.watcher.poll()

    def clear_success(self) -> None:
        if self.watcher is not None:
            self.watcher.clear()

    def close(self) -> None:
        if self.watcher is not None:
            self.watcher.stop = True
            self.watcher = None


def synthetic_lock_frame(size: int, radius: float, keyway_deg: float, pick_deg: float) -> np.ndarray:
    """Render a crude lock face. Used by the offline vision self-test."""
    img = np.full((size, size, 3), 38, np.uint8)
    c = size // 2
    cv2.circle(img, (c, c), int(radius), (96, 104, 112), -1)
    cv2.circle(img, (c, c), int(radius * 0.62), (120, 130, 140), -1)
    th = math.radians(keyway_deg)
    dx, dy = math.cos(th), -math.sin(th)
    half = radius * 0.42
    p0 = (int(round(c - dx * half)), int(round(c - dy * half)))
    p1 = (int(round(c + dx * half)), int(round(c + dy * half)))
    cv2.line(img, p0, p1, (8, 8, 8), max(3, int(radius * 0.07)))
    tp = math.radians(pick_deg)
    q0 = (int(round(c + math.cos(tp) * radius * 0.30)), int(round(c - math.sin(tp) * radius * 0.30)))
    q1 = (int(round(c + math.cos(tp) * radius * 1.30)), int(round(c - math.sin(tp) * radius * 1.30)))
    cv2.line(img, q0, q1, (40, 40, 170), max(3, int(radius * 0.05)))
    return img


def vision_selftest(iterations: int = 60) -> int:
    """Offline accuracy/speed check of the vectorized readers (no game needed)."""
    size, radius = 700, 210.0
    sampler = RadialSampler(size, radius)
    rng = np.random.default_rng(7)
    ang_err, pick_err = [], []
    t0 = time.perf_counter()
    for _ in range(iterations):
        key = float(rng.uniform(20.0, 160.0))
        pick = float(rng.uniform(20.0, 160.0))
        frame = synthetic_lock_frame(size, radius, key, pick)
        gray = cv2.GaussianBlur(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY), (3, 3), 0).astype(np.float32)
        got_key, _dark = sampler.keyway_angle(gray)
        f = frame.astype(np.float32)
        b, g, r = f[:, :, 0], f[:, :, 1], f[:, :, 2]
        redness = (r - 0.5 * (g + b)) + 0.07 * (np.maximum(np.maximum(r, g), b) - np.minimum(np.minimum(r, g), b))
        got_pick, _score = sampler.pick_angle(redness)
        ang_err.append(abs(angle_diff_deg(got_key, key)))
        pick_err.append(abs(angle_diff_deg(got_pick, pick)))
    ms = (time.perf_counter() - t0) * 1000.0 / max(1, iterations)
    print(f"vision self-test: {iterations} frames, {ms:.2f} ms/frame (turn + pick, {size}x{size})")
    print(f"  keyway angle error: mean {np.mean(ang_err):.3f} deg  max {np.max(ang_err):.3f} deg")
    print(f"  pick   angle error: mean {np.mean(pick_err):.3f} deg  max {np.max(pick_err):.3f} deg")
    cal = TurnCalibration(path=LIVE_DIR / "turn_calibration_selftest.json")
    boot = cal.bootstrap_from_refs(force=True)
    print("reference art calibration (rest keyway angle -> full-turn span):")
    refs_ok = len(boot) == len(LOCK_NAMES)
    for lock in LOCK_NAMES:
        e = boot.get(lock)
        if e is None:
            print(f"  {lock:<9} MISSING reference art")
            continue
        good = 80.0 <= e["span_deg"] <= 90.0 and 80.0 <= e["rest_deg"] <= 100.0
        refs_ok = refs_ok and good
        print(f"  {lock:<9} rest {e['rest_deg']:6.2f} deg | full turn {e['span_deg']:5.2f} deg"
              + ("" if good else "   <-- unexpected"))
    try:
        (LIVE_DIR / "turn_calibration_selftest.json").unlink()
    except OSError:
        pass
    ok = float(np.max(ang_err)) < 2.0 and float(np.max(pick_err)) < 2.5 and ms < 25.0 and refs_ok
    print("RESULT:", "OK" if ok else "TOO SLOW / INACCURATE / BAD REFERENCE CALIBRATION")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(vision_selftest())
