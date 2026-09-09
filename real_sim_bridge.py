from __future__ import annotations

import argparse
import json
import math
import os
import queue
import statistics
import threading
import time
from collections import defaultdict, deque
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data" / "real_bridge"
SAMPLES = DATA / "samples.jsonl"
STATUS = DATA / "status.json"
FIT = DATA / "fit_profile.json"
LATEST_REPLAY = DATA / "latest_replay.json"
STOP_FLAG = DATA / "stop.flag"
PID_FILE = DATA / "recorder.pid"
CONFIG = ROOT / "freelearn_config.json"

LOCKS = ["Rusted", "Basic", "Medium", "Enforced"]


def atomic_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def load_freelearn_config() -> dict:
    return read_json(CONFIG, {})


def count_samples() -> Tuple[int, int, int, Dict[str, int]]:
    samples = 0
    by_lock = {k: 0 for k in LOCKS}
    seen = set()
    success_eps = set()
    if SAMPLES.exists():
        with SAMPLES.open("r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                ep = str(r.get("episode_id", ""))
                if ep:
                    seen.add(ep)
                if r.get("source") == "episode_terminal" and bool(r.get("episode_success", False)):
                    if ep:
                        success_eps.add(ep)
                    continue
                if r.get("source") != "screen_passive":
                    continue
                samples += 1
                lk = r.get("lock_type")
                if lk in by_lock:
                    by_lock[lk] += 1
    return samples, len(seen), len(success_eps), by_lock


def write_status(**extra: Any) -> None:
    samples, episodes, success_rows, by_lock = count_samples()
    fit = read_json(FIT, {})
    st = {
        "version": "0.18.0",
        "recorder": "offline",
        "samples": samples,
        "episodes": episodes,
        "success_rows": success_rows,
        "samples_by_lock": by_lock,
        "fit_created": fit.get("created"),
        "overall_match": fit.get("overall_match", 0.0),
        "fit_locks": fit.get("locks", {}),
        "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    st.update(extra)
    atomic_json(STATUS, st)


def _annulus_feature(img: np.ndarray) -> np.ndarray:
    if img is None or img.size == 0:
        return np.zeros(32 * 32 + 24 * 24, np.float32)
    h, w = img.shape[:2]
    s = min(h, w)
    y0, x0 = (h - s) // 2, (w - s) // 2
    img = img[y0:y0+s, x0:x0+s]
    img = cv2.resize(img, (192, 192), interpolation=cv2.INTER_AREA)
    yy, xx = np.ogrid[:192, :192]
    rr = np.sqrt((xx - 96.0) ** 2 + (yy - 96.0) ** 2)
    mask = ((rr >= 46) & (rr <= 92)).astype(np.uint8) * 255
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    hist = cv2.calcHist([hsv], [0, 1], mask, [32, 32], [0, 180, 0, 256]).astype(np.float32).ravel()
    hist /= max(float(hist.sum()), 1e-6)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    gh = cv2.calcHist([gray], [0], mask, [24], [0, 256]).astype(np.float32).ravel()
    gh /= max(float(gh.sum()), 1e-6)
    # Add coarse texture descriptor so Basic/Medium/Enforced do not collapse to color alone.
    small = cv2.resize(gray, (24, 24), interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
    small = (small - small.mean()).ravel()
    return np.concatenate([hist, gh, small]).astype(np.float32)


class LockClassifier:
    def __init__(self):
        self.features: Dict[str, np.ndarray] = {}
        for lk in LOCKS:
            candidates = [
                ROOT / "refs" / "lock_types" / f"{lk}.png",
                ROOT / "command_center_source" / "assets" / f"{lk}.png",
            ]
            for p in candidates:
                if p.exists():
                    im = cv2.imread(str(p), cv2.IMREAD_COLOR)
                    if im is not None:
                        self.features[lk] = _annulus_feature(im)
                        break

    def classify(self, frame: np.ndarray, half: int, radius: int) -> Tuple[str, float, Dict[str, float]]:
        if not self.features:
            return "Unknown", 0.0, {}
        c = int(half)
        r = int(max(40, radius * 1.12))
        y0, y1 = max(0, c-r), min(frame.shape[0], c+r)
        x0, x1 = max(0, c-r), min(frame.shape[1], c+r)
        crop = frame[y0:y1, x0:x1]
        f = _annulus_feature(crop)
        scores: Dict[str, float] = {}
        for lk, rf in self.features.items():
            n = min(len(f), len(rf))
            a, b = f[:n], rf[:n]
            den = float(np.linalg.norm(a) * np.linalg.norm(b))
            sim = float(np.dot(a, b) / den) if den > 1e-8 else 0.0
            scores[lk] = sim
        order = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
        best = order[0]
        second = order[1][1] if len(order) > 1 else 0.0
        conf = float(np.clip((best[1] - second) * 4.0 + max(0.0, best[1] - 0.65), 0.0, 1.0))
        return best[0], conf, scores


@dataclass
class Probe:
    episode_id: str
    lock_type: str
    lock_type_conf: float
    t_down: float
    x: Optional[float]
    x_raw: Optional[float]
    x_conf: float
    turn_before: float
    ui_conf: float
    success_score_before: float
    peak_turn: float
    peak_time: float
    success_peak: float
    t_up: Optional[float] = None
    turn_after: Optional[float] = None
    return_sample_time: Optional[float] = None
    f_ms: Optional[float] = None
    f_mode: str = "TAP"
    finalized: bool = False


class KeyWatcher(threading.Thread):
    def __init__(self, ll, out: queue.Queue):
        super().__init__(daemon=True)
        self.ll = ll
        self.out = out
        self.stop = False
        self.prev_f = False
        self.prev_space = False
        self.prev_f12 = False

    def run(self):
        while not self.stop:
            now = time.monotonic()
            f = self.ll.is_key_down(0x46)
            sp = self.ll.is_key_down(0x20)
            f12 = self.ll.is_key_down(0x7B)
            if f != self.prev_f:
                self.out.put(("f_down" if f else "f_up", now))
            if sp and not self.prev_space:
                self.out.put(("space", now))
            if f12 and not self.prev_f12:
                self.out.put(("stop", now))
            self.prev_f, self.prev_space, self.prev_f12 = f, sp, f12
            time.sleep(0.002)


def _append_row(row: dict) -> None:
    DATA.mkdir(parents=True, exist_ok=True)
    with SAMPLES.open("a", encoding="utf-8", buffering=1) as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")


def _episode_tag(counter: int) -> str:
    return f"{time.strftime('%Y%m%d_%H%M%S')}_{os.getpid()}_{counter:05d}"


def record(lock_override: str = "Auto") -> int:
    if os.name != "nt":
        write_status(recorder="error", error="REAL capture requires Windows/SCUM.")
        print("REAL capture requires Windows.")
        return 2
    try:
        import lockpick_learner as ll
    except Exception as e:
        write_status(recorder="error", error=f"lockpick_learner import failed: {e}")
        print(f"Could not import lockpick_learner.py: {e}")
        return 2

    DATA.mkdir(parents=True, exist_ok=True)
    try:
        STOP_FLAG.unlink()
    except FileNotFoundError:
        pass
    PID_FILE.write_text(str(os.getpid()), encoding="utf-8")

    cfg = ll.Config.load()
    model = ll.QModel(cfg)
    vision, _console, _hwnd = ll.prepare_live_vision(cfg, model, minimize=False)
    if vision is None:
        write_status(recorder="error", error="Could not lock onto SCUM window/lock UI.")
        return 3
    vision.cal.update(model.calibration)
    classifier = LockClassifier()

    events: queue.Queue = queue.Queue()
    watcher = KeyWatcher(ll, events)
    watcher.start()

    episode_no = 1
    episode_id = _episode_tag(episode_no)
    episode_sample_rows: List[dict] = []
    episode_success = False
    episode_start = time.monotonic()
    active: Optional[Probe] = None
    pending: deque[Probe] = deque()
    last_state = None
    last_ui_good = time.monotonic()
    success_latched = False
    lock_hist: deque[Tuple[str, float]] = deque(maxlen=12)
    last_classify = 0.0
    latest_lock = lock_override if lock_override in LOCKS else "Unknown"
    latest_lock_conf = 1.0 if lock_override in LOCKS else 0.0
    last_status = 0.0

    def choose_lock() -> Tuple[str, float]:
        if lock_override in LOCKS:
            return lock_override, 1.0
        if not lock_hist:
            return latest_lock, latest_lock_conf
        weights = defaultdict(float)
        for lk, c in lock_hist:
            weights[lk] += max(0.05, c)
        if not weights:
            return latest_lock, latest_lock_conf
        lk, w = max(weights.items(), key=lambda kv: kv[1])
        total = sum(weights.values())
        return lk, float(w / max(total, 1e-6))

    def finalize_probe(p: Probe, st, now: float) -> None:
        if p.finalized:
            return
        if p.t_up is None:
            return
        post_ms = max(1.0, (now - p.t_up) * 1000.0)
        p.turn_after = float(st.progress)
        p.return_sample_time = float(post_ms)
        p.finalized = True
        fms = float(max(0.0, (p.t_up - p.t_down) * 1000.0))
        p.f_ms = fms
        p.f_mode = "TAP" if fms <= 80.0 else "HOLD"
        lk, lkc = choose_lock()
        p.lock_type, p.lock_type_conf = lk, max(p.lock_type_conf, lkc)
        row = {
            "version": "0.18.0",
            "source": "screen_passive",
            "episode_id": p.episode_id,
            "episode_elapsed": round(p.t_down - episode_start, 6),
            "lock_type": p.lock_type,
            "lock_type_conf": round(p.lock_type_conf, 5),
            "x": None if p.x is None else round(float(p.x), 7),
            "x_raw": None if p.x_raw is None else round(float(p.x_raw), 7),
            "x_conf": round(float(p.x_conf), 5),
            "f_mode": p.f_mode,
            "f_ms": round(fms, 3),
            "turn_before": round(float(p.turn_before), 7),
            "turn_peak": round(float(p.peak_turn), 7),
            "turn_delta": round(float(max(0.0, p.peak_turn - min(p.turn_before, 0.055))), 7),
            "turn_after": round(float(p.turn_after), 7),
            "return_sample_ms": round(float(post_ms), 3),
            "ui_conf": round(float(p.ui_conf), 5),
            "success_score": round(float(p.success_peak), 5),
            "episode_success": False,
            "captured_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        _append_row(row)
        episode_sample_rows.append(row)

    def mark_episode_success() -> None:
        # JSONL is append-only. Emit authoritative terminal marker rather than rewriting rows.
        nonlocal episode_success
        if episode_success:
            return
        episode_success = True
        lk, lkc = choose_lock()
        last = episode_sample_rows[-1] if episode_sample_rows else {}
        _append_row({
            "version": "0.18.0", "source": "episode_terminal", "episode_id": episode_id,
            "lock_type": lk, "lock_type_conf": lkc, "terminal": True, "episode_success": True,
            "success_x": last.get("x"), "success_turn": last.get("turn_peak"), "success_f_ms": last.get("f_ms"),
            "captured_at": time.strftime("%Y-%m-%d %H:%M:%S")
        })

    def new_episode(reason: str) -> None:
        nonlocal episode_no, episode_id, episode_sample_rows, episode_success, episode_start, active, pending, success_latched
        # Flush any released probe with the latest state before switching.
        if last_state is not None:
            now = time.monotonic()
            for p in list(pending):
                if p.t_up is not None:
                    finalize_probe(p, last_state, now)
            pending.clear()
        episode_no += 1
        episode_id = _episode_tag(episode_no)
        episode_sample_rows = []
        episode_success = False
        episode_start = time.monotonic()
        active = None
        success_latched = False
        print(f"[REAL] new episode {episode_id} ({reason})")

    print("=== REAL<->SIM BRIDGE CAPTURE v0.18.0 ===")
    print("Passive SCUM screen/action recorder. F12 stops. F is never injected by this process.")
    print(f"Lock type: {lock_override}. Hidden target/ramp geometry is NOT exposed to the neural.\n")
    write_status(recorder="recording", pid=os.getpid(), lock_override=lock_override)

    try:
        while True:
            if STOP_FLAG.exists():
                break
            while True:
                try:
                    typ, ts = events.get_nowait()
                except queue.Empty:
                    break
                if typ == "stop":
                    watcher.stop = True
                    raise KeyboardInterrupt
                if typ == "space":
                    new_episode("Space")
                elif typ == "f_down":
                    if last_state is None or success_latched:
                        continue
                    lk, lkc = choose_lock()
                    x = last_state.pick_pos
                    xraw = last_state.pick_raw
                    xconf = float(np.clip((float(last_state.pick_score) - 1.0) / 10.0, 0.0, 1.0)) if xraw is not None else 0.0
                    active = Probe(
                        episode_id=episode_id, lock_type=lk, lock_type_conf=lkc, t_down=ts,
                        x=float(x) if x is not None else None,
                        x_raw=float(xraw) if xraw is not None else None,
                        x_conf=xconf, turn_before=float(last_state.progress), ui_conf=float(last_state.ui_confidence),
                        success_score_before=float(last_state.success_score), peak_turn=float(last_state.progress),
                        peak_time=ts, success_peak=float(last_state.success_score),
                    )
                elif typ == "f_up":
                    if active is not None:
                        active.t_up = ts
                        pending.append(active)
                        active = None

            st = vision.state(keep_frame=(lock_override == "Auto"))
            now = time.monotonic()
            last_state = st
            if st.ui_confidence > 0.10:
                last_ui_good = now

            if lock_override == "Auto" and st.frame is not None and now - last_classify >= 0.55:
                lk, conf, _scores = classifier.classify(st.frame, vision.half, vision.radius)
                if lk in LOCKS:
                    lock_hist.append((lk, conf))
                    latest_lock, latest_lock_conf = lk, conf
                last_classify = now

            if active is not None:
                if st.progress > active.peak_turn:
                    active.peak_turn = float(st.progress)
                    active.peak_time = now
                active.success_peak = max(active.success_peak, float(st.success_score))

            # Keep sampling turn return after F-up for 180 ms. This gives real return tau.
            while pending and pending[0].t_up is not None and now - pending[0].t_up >= 0.180:
                p = pending.popleft()
                finalize_probe(p, st, now)

            if st.success_detected and not success_latched:
                mark_episode_success()
                success_latched = True
            elif success_latched and st.success_score < cfg.success_template_threshold * 0.55:
                success_latched = False

            # Lock UI gone after a real attempt -> start a clean episode boundary.
            if now - last_ui_good > 0.90 and episode_sample_rows:
                new_episode("lock UI disappeared")
                last_ui_good = now

            if now - last_status >= 0.5:
                lk, lkc = choose_lock()
                write_status(
                    recorder="recording", pid=os.getpid(), lock_override=lock_override,
                    detected_lock=lk, detected_lock_conf=round(lkc, 4),
                    current_episode=episode_id,
                    last_x=None if st.pick_pos is None else round(float(st.pick_pos), 5),
                    last_turn=round(float(st.progress), 5),
                    ui_conf=round(float(st.ui_confidence), 4),
                    success_score=round(float(st.success_score), 4),
                )
                last_status = now
            time.sleep(0.004)
    except KeyboardInterrupt:
        pass
    finally:
        watcher.stop = True
        try:
            STOP_FLAG.unlink()
        except FileNotFoundError:
            pass
        try:
            PID_FILE.unlink()
        except FileNotFoundError:
            pass
        write_status(recorder="offline", last_message="capture stopped")
        print("\nREAL capture stopped.")
    return 0


def _load_records() -> List[dict]:
    rows: List[dict] = []
    if not SAMPLES.exists():
        return rows
    terminals: Dict[str, dict] = {}
    with SAMPLES.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("source") == "episode_terminal" and r.get("episode_success"):
                terminals[str(r.get("episode_id", ""))] = r
            elif r.get("source") == "screen_passive":
                rows.append(r)
    for r in rows:
        ep = str(r.get("episode_id", ""))
        t = terminals.get(ep)
        r["episode_success"] = t is not None
        if t is not None:
            r["_success_x"] = t.get("success_x")
    return rows


def _lock_geometry(cfg: dict, lk: str) -> dict:
    spec = cfg.get("locks", {}).get(lk, {})
    temps = spec.get("templates") or [{}]
    t = temps[0]
    li = LOCKS.index(lk)
    physical = float(spec.get("physical_max", 1.0))
    span = float(spec.get("policy_span", 1.0 if li == 0 else 0.5))
    scale = physical / max(span, 1e-6)
    return {
        "physical": physical,
        "span": span,
        "target_half": float(t.get("target_half", 0.01)) * scale,
        "ramp_left": float(t.get("ramp_left", 0.04)) * scale,
        "ramp_right": float(t.get("ramp_right", 0.04)) * scale,
        "curve_exp": float(t.get("curve_exp", 1.5)),
        "turn_tau_ms": float(t.get("turn_tau_ms", 280.0)),
        "return_tau_ms": float(t.get("return_tau_ms", 120.0)),
    }


def _cap_at(x: np.ndarray, center: float, g: dict) -> np.ndarray:
    d = x - center
    ad = np.abs(d)
    th = g["target_half"]
    cap = np.zeros_like(x, dtype=np.float64)
    cap[ad <= th] = 1.0
    left = d < -th
    if np.any(left):
        q = (-d[left] - th) / max(g["ramp_left"], 1e-6)
        ok = q < 1.0
        vals = np.zeros(q.shape, np.float64)
        vals[ok] = np.power(np.clip(1.0 - q[ok], 0.0, 1.0), g["curve_exp"])
        cap[left] = vals
    right = d > th
    if np.any(right):
        q = (d[right] - th) / max(g["ramp_right"], 1e-6)
        ok = q < 1.0
        vals = np.zeros(q.shape, np.float64)
        vals[ok] = np.power(np.clip(1.0 - q[ok], 0.0, 1.0), g["curve_exp"])
        cap[right] = vals
    return cap


def _infer_centers(rows: List[dict], g: dict) -> Dict[str, float]:
    eps: Dict[str, List[dict]] = defaultdict(list)
    for r in rows:
        eps[str(r.get("episode_id", ""))].append(r)
    centers: Dict[str, float] = {}
    for ep, erows in eps.items():
        valid = [r for r in erows if r.get("x") is not None]
        if not valid:
            continue
        # A verified success gives the strongest center anchor. Otherwise use the
        # strongest visible response and refine against the fixed geometry.
        success_x = next((r.get("_success_x") for r in valid if r.get("_success_x") is not None), None)
        if success_x is not None:
            a = float(success_x)
        else:
            anchor = max(valid, key=lambda r: float(r.get("turn_delta", 0.0)))
            a = float(anchor["x"])
        lo, hi = max(0.0, a - 0.16), min(g["physical"], a + 0.16)
        grid = np.linspace(lo, hi, 161)
        xs = np.asarray([float(r["x"]) for r in valid], np.float64)
        ys = np.asarray([float(r.get("turn_delta", 0.0)) for r in valid], np.float64)
        # Compare normalized shape only so dynamics do not bias center inference.
        ymax = max(float(ys.max()), 0.04)
        yn = ys / ymax
        best_c, best_e = a, 1e9
        for c in grid:
            p = _cap_at(xs, float(c), g)
            if p.max() > 0:
                p = p / max(float(p.max()), 1e-6)
            e = float(np.mean((p - yn) ** 2))
            if e < best_e:
                best_e, best_c = e, float(c)
        centers[ep] = best_c
    return centers


def _predict_peaks(rows: List[dict], g: dict, centers: Dict[str, float], tau_scale: float, ramp_gain: float) -> np.ndarray:
    out = []
    tau = max(5.0, g["turn_tau_ms"] * tau_scale) / 1000.0
    for r in rows:
        x = float(r["x"])
        c = centers.get(str(r.get("episode_id", "")), x)
        cap = float(_cap_at(np.asarray([x]), c, g)[0])
        if cap < 0.999:
            cap = float(np.clip(cap * ramp_gain, 0.0, 0.995))
        before = float(r.get("turn_before", 0.0))
        sec = max(0.001, float(r.get("f_ms", 25.0)) / 1000.0)
        pred = cap - (cap - before) * math.exp(-sec / tau)
        out.append(float(np.clip(pred, 0.0, 1.0)))
    return np.asarray(out, np.float64)


def fit() -> int:
    rows = _load_records()
    cfg = load_freelearn_config()
    if not rows:
        write_status(recorder="offline", fit_error="No real samples yet")
        print("No real samples yet. Record SCUM first.")
        return 2

    result: Dict[str, Any] = {
        "version": "0.18.0",
        "created": time.strftime("%Y-%m-%d %H:%M:%S"),
        "mode": "real-to-sim-physics-fit",
        "contract": "fixed geometry widths stay untouched; fit only observable dynamics/ramp depth/noise",
        "locks": {},
    }
    replay_candidate = None
    match_scores = []

    for lk in LOCKS:
        lr = [r for r in rows if r.get("lock_type") == lk and r.get("x") is not None and float(r.get("x_conf", 0.0)) >= 0.20]
        # Keep bad auto-classification from poisoning a lock-specific profile.
        lr = [r for r in lr if float(r.get("lock_type_conf", 0.0)) >= 0.34 or r.get("lock_type_conf") == 1.0]
        g = _lock_geometry(cfg, lk)
        if len(lr) < 12:
            result["locks"][lk] = {
                "enabled": False, "samples": len(lr), "episodes": len(set(r.get("episode_id") for r in lr)),
                "reason": "need >=12 confident probes", "match": 0.0,
                "turn_tau_scale": 1.0, "return_tau_scale": 1.0, "ramp_gain": 1.0, "sensor_noise": 0.0,
            }
            continue

        # Limit fitting cost but preserve recent diversity.
        if len(lr) > 5000:
            stride = max(1, len(lr) // 5000)
            lr = lr[::stride][-5000:]
        centers = _infer_centers(lr, g)
        actual = np.asarray([float(r.get("turn_peak", r.get("turn_delta", 0.0))) for r in lr], np.float64)

        best = (1e9, 1.0, 1.0, None)
        for ts in np.linspace(0.50, 2.10, 17):
            for rg in np.linspace(0.65, 1.35, 15):
                pred = _predict_peaks(lr, g, centers, float(ts), float(rg))
                # Robust-ish loss: clip giant vision outliers.
                resid = np.clip(pred - actual, -0.45, 0.45)
                loss = float(np.mean(resid * resid))
                if loss < best[0]:
                    best = (loss, float(ts), float(rg), pred)
        loss, tau_scale, ramp_gain, pred = best
        assert pred is not None

        # Return-time fit from visible post-release decay.
        tau_ratios = []
        for r in lr:
            peak = float(r.get("turn_peak", 0.0))
            after = float(r.get("turn_after", 0.0))
            dt = float(r.get("return_sample_ms", 0.0)) / 1000.0
            if peak > 0.06 and 0.005 < after < peak * 0.995 and dt > 0.02:
                tau = -dt / math.log(max(after / peak, 1e-6))
                if 0.02 <= tau <= 1.5:
                    tau_ratios.append(tau / max(g["return_tau_ms"] / 1000.0, 1e-6))
        ret_scale = float(np.median(tau_ratios)) if tau_ratios else 1.0
        ret_scale = float(np.clip(ret_scale, 0.35, 3.0))

        resid = actual - pred
        med = float(np.median(resid))
        mad = float(np.median(np.abs(resid - med)))
        sensor_noise = float(np.clip(1.4826 * mad, 0.0, 0.12))
        rmse = float(math.sqrt(max(loss, 0.0)))
        match = float(np.clip(1.0 - rmse / 0.32, 0.0, 1.0))
        episodes = len(set(str(r.get("episode_id", "")) for r in lr))
        successes = len(set(str(r.get("episode_id", "")) for r in lr if bool(r.get("episode_success"))))
        enabled = len(lr) >= 20 and episodes >= 3 and match >= 0.18

        # Comparison bins around inferred center. This is for the HUMAN UI only.
        bins: Dict[int, List[Tuple[float, float]]] = defaultdict(list)
        for r, pp in zip(lr, pred):
            ep = str(r.get("episode_id", ""))
            c = centers.get(ep)
            if c is None:
                continue
            rel = float(r["x"]) - c
            bi = int(round(rel / 0.01))
            bins[bi].append((float(r.get("turn_peak", 0.0)), float(pp)))
        comparison = []
        for bi in sorted(bins):
            vals = bins[bi]
            comparison.append({
                "x_rel": round(bi * 0.01, 4),
                "real": round(float(np.mean([v[0] for v in vals])), 5),
                "sim": round(float(np.mean([v[1] for v in vals])), 5),
                "n": len(vals),
            })

        result["locks"][lk] = {
            "enabled": enabled,
            "samples": len(lr),
            "episodes": episodes,
            "verified_success_episodes": successes,
            "match": round(match, 5),
            "rmse": round(rmse, 6),
            "turn_tau_scale": round(float(np.clip(tau_scale, 0.50, 2.10)), 5),
            "return_tau_scale": round(ret_scale, 5),
            "ramp_gain": round(float(np.clip(ramp_gain, 0.65, 1.35)), 5),
            "sensor_noise": round(sensor_noise, 6),
            "geometry_changed": False,
            "geometry": {k: round(float(v), 6) for k, v in g.items() if k not in {"physical", "span"}},
            "comparison": comparison,
        }
        if enabled:
            match_scores.append(match)

        # Latest complete-ish episode for real-vs-sim action replay.
        by_ep = defaultdict(list)
        for r, pp in zip(lr, pred):
            by_ep[str(r.get("episode_id", ""))].append((r, float(pp)))
        for ep in sorted(by_ep.keys())[-3:]:
            vals = by_ep[ep]
            if len(vals) >= 2:
                rr = {
                    "lock": lk, "episode_id": ep, "center_inferred": centers.get(ep),
                    "success": any(bool(v[0].get("episode_success")) for v in vals),
                    "steps": [
                        {
                            "x": v[0].get("x"), "f_mode": v[0].get("f_mode"), "f_ms": v[0].get("f_ms"),
                            "real_turn": round(float(v[0].get("turn_peak", 0.0)), 5),
                            "sim_turn": round(v[1], 5),
                        } for v in vals
                    ]
                }
                replay_candidate = rr

    result["overall_match"] = round(float(np.mean(match_scores)) if match_scores else 0.0, 5)
    result["enabled_locks"] = sum(1 for v in result["locks"].values() if v.get("enabled"))
    result["total_samples"] = len(rows)
    atomic_json(FIT, result)
    if replay_candidate:
        atomic_json(LATEST_REPLAY, replay_candidate)
    write_status(recorder="offline", fit_message=f"fit complete; {result['enabled_locks']}/4 locks active")
    print(f"REAL->SIM fit complete. Overall match {100*result['overall_match']:.1f}% | active locks {result['enabled_locks']}/4")
    for lk in LOCKS:
        p = result["locks"].get(lk, {})
        print(f"  {lk:8s} samples={p.get('samples',0):4d} match={100*float(p.get('match',0)):.1f}% tau x{p.get('turn_tau_scale',1)} return x{p.get('return_tau_scale',1)} ramp x{p.get('ramp_gain',1)} {'ACTIVE' if p.get('enabled') else 'hold'}")
    return 0


def status_cmd() -> int:
    write_status(recorder=read_json(STATUS, {}).get("recorder", "offline"))
    print(json.dumps(read_json(STATUS, {}), indent=2))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    rp = sub.add_parser("record")
    rp.add_argument("--lock", default="Auto", choices=["Auto"] + LOCKS)
    sub.add_parser("fit")
    sub.add_parser("status")
    a = ap.parse_args()
    if a.cmd == "record":
        return record(a.lock)
    if a.cmd == "fit":
        return fit()
    return status_cmd()


if __name__ == "__main__":
    raise SystemExit(main())
