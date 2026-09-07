from __future__ import annotations

import argparse
import csv
import ctypes
import hashlib
import json
import math
import os
import random
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import cv2
import mss
import numpy as np

APP_NAME = "Lockpick Learner"
# Bumped whenever the meaning of a state key changes, so old learned values
# that no longer mean the same thing are dropped instead of poisoning the
# new policy. v1 = absolute pick position, v2 = distance from the ramp,
# v3 = ramp threshold raised above the measured noise floor and the action
# list widened so the search phase can actually cross the lock.
STATE_SCHEMA = 3
ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
DEMO_DIR = DATA_DIR / "demos"
MODEL_PATH = DATA_DIR / "model.json"
# Shipped starting policy: trained on 50 recorded real human attempts plus
# simulated self-play. Copied into data/ on first run so a fresh install does
# not have to spend its first few hundred attempts rediscovering the basics.
BUNDLED_MODEL_PATH = ROOT / "esitreenattu_malli.json"
CONFIG_PATH = ROOT / "config.json"
EVENT_LOG = DATA_DIR / "events.csv"
SUCCESS_DEMO_DIR = DEMO_DIR / "successful"
FAILED_DEMO_DIR = DEMO_DIR / "failed"
INCOMPLETE_DEMO_DIR = DEMO_DIR / "incomplete"
SELFPLAY_DIR = DATA_DIR / "selfplay"
SELFPLAY_SUCCESS_DIR = SELFPLAY_DIR / "successful"
SELFPLAY_FAILED_DIR = SELFPLAY_DIR / "failed"
REFS_DIR = ROOT / "refs"
SUCCESS_DIR = DATA_DIR / "successes"
SUCCESS_INDEX = DATA_DIR / "successes.csv"
SUCCESS_TEMPLATE_PATH = REFS_DIR / "success_text_template.png"
AUDIT_DIR = DATA_DIR / "audit"
AUDIT_SNAPSHOT_DIR = AUDIT_DIR / "snapshots"
AUDIT_VERIFY_DIR = AUDIT_DIR / "verify"
DECISION_AUDIT_LOG = AUDIT_DIR / "decisions.csv"
TRAIN_AUDIT_LOG = AUDIT_DIR / "training_runs.csv"
EVAL_DIR = DATA_DIR / "evaluation"
EVAL_SUCCESS_DIR = EVAL_DIR / "successful"
EVAL_FAILED_DIR = EVAL_DIR / "failed"

for p in (DATA_DIR, DEMO_DIR, SUCCESS_DEMO_DIR, FAILED_DEMO_DIR, INCOMPLETE_DEMO_DIR, SELFPLAY_DIR, SELFPLAY_SUCCESS_DIR, SELFPLAY_FAILED_DIR, SUCCESS_DIR, REFS_DIR, AUDIT_DIR, AUDIT_SNAPSHOT_DIR, AUDIT_VERIFY_DIR, EVAL_DIR, EVAL_SUCCESS_DIR, EVAL_FAILED_DIR):
    p.mkdir(parents=True, exist_ok=True)


# ---------------------------
# Configuration
# ---------------------------

@dataclass
class RewardConfig:
    wobble_bonus: float = 1.25
    progress_gain: float = 28.0
    absolute_progress: float = 2.0
    new_best_bonus: float = 7.0
    probe_cost: float = 0.06
    time_cost_per_second: float = 0.65
    fail_penalty: float = -12.0
    success_reward: float = 100.0
    speed_bonus_max: float = 45.0


@dataclass
class Config:
    # monitor=0 means automatic monitor discovery. Old config files that still say
    # monitor=1 are also auto-discovered while auto_detect_monitor=True.
    monitor: int = 0
    auto_detect_monitor: bool = True
    auto_focus_game_window: bool = True
    monitor_scan_seconds: float = 6.0
    monitor_scan_threshold: float = 3.8
    center_x_ratio: float = 0.5
    center_y_ratio: float = 0.5
    # v0.1 used a radius/crop that was much too small for the supplied 1080p
    # reference images.  The visible outer lock UI is about 0.20 * screen height.
    lock_radius_ratio: float = 0.20
    capture_half_size_ratio: float = 0.34
    fps: int = 30
    probe_hold_ms: int = 28
    response_window_ms: int = 145
    # The old move_to clipped every mouse step to +-140 counts and allowed 8
    # of them. With a measured 6000 counts across the lock that capped ANY
    # move at 0.187 of the lock, whatever was asked for, and cost ~440 ms.
    # A move is now sent as a few back-to-back chunks with no screen reads in
    # between, then verified once or twice.
    move_chunk_counts: int = 900     # biggest single SendInput step
    move_tolerance: float = 0.008    # close enough to stop correcting
    move_settle_ms: int = 22         # let the game apply the move
    move_max_corrections: int = 2    # verify reads after the first move
    response_settle_ms: int = 45     # stop the window early once it is steady
    response_min_ms: int = 55        # but never look for less than this
    finish_hold_ms: int = 190
    success_progress: float = 0.82
    # The old line-search rotation detector put a still lock at 0.089, so the
    # old 0.025 threshold sat inside its own noise: 83% of attempts declared a
    # ramp on the first probe and then micro-stepped, covering a median 4% of
    # the lock and opening 0 of 210. The keyway detector reads a still lock at
    # 0.009-0.017 on the same frames, so the floor is 5x lower and a real but
    # distant ramp can be trusted from much further out.
    wobble_threshold: float = 0.05
    wobble_confirm_probes: int = 2   # how many probes must agree before micro-stepping
    attempt_budget_seconds: float = 3.1
    auto_press_space: bool = True
    restart_wait_seconds: float = 0.55
    start_wait_seconds: float = 0.18
    emergency_key_vk: int = 0x7B  # F12
    pause_key_vk: int = 0x79      # F10
    f_key_vk: int = 0x46
    space_key_vk: int = 0x20
    debug_preview: bool = False
    # v0.6: SUCCESS detection measured from real 1080p gameplay frames.
    # The v0.4/v0.5 template matcher scored only 0.199/0.197 on the two real
    # SUCCESS frames against its own 0.62 threshold, so it never fired and no
    # attempt was ever credited. Two independent marks separate cleanly instead:
    #   1) a bright text band across the middle  (running 938-1216 px, SUCCESS 5126-5366 px)
    #   2) the timer arc is gone                 (running 4640-6373 px, SUCCESS 1 px)
    # Verified 15/15 on the reference frames in kuvat\.
    success_threshold: float = 0.62      # combined 0..1 confidence needed
    success_band_pixels: int = 2500      # bright pixels needed in the centre band
    success_arc_max: int = 800           # timer arc must be this gone
    success_band_bright: int = 200       # what counts as "bright text"
    success_arc_bright: int = 185        # what counts as "arc"
    success_band_half_h: float = 0.051   # band size, x screen height
    success_band_half_w: float = 0.204
    success_use_template: bool = True    # also match the bundled SUCCESS word
    # Rotation is read from the black keyway inside the cylinder. Verified
    # against the game's own screenshots: at rest 1.05 deg, mid-attempt 22.1,
    # open 89.5-94.1, and the pick at either extreme reads 1.51 vs 1.45 - so
    # the pick does not leak into the measurement.
    keyway_radius: float = 0.0519       # x screen height
    keyway_center_y: float = -0.0028    # x screen height
    keyway_dark_max: int = 22           # what counts as the black slot
    keyway_min_pixels: int = 200
    keyway_min_elongation: float = 1.8
    success_confirm_wait_ms: int = 420
    demo_success_multiplier: float = 5.0
    demo_failed_helpful_multiplier: float = 0.70
    demo_failed_negative_multiplier: float = 0.55
    # v0.3 could blend several retries into one long SUCCESS episode because it
    # did not watch Space. Such old episodes stay usable, but are demoted from
    # gold-standard SUCCESS data if clearly too long/large.
    legacy_mixed_max_seconds: float = 8.0
    legacy_mixed_max_probes: int = 20
    # Human OBSERVE attempt boundaries: Space starts the next try in this minigame.
    observe_space_boundaries: bool = True
    # Autonomous learning stores every attempt and replays successes more often.
    selfplay_success_replay_passes: int = 4
    selfplay_fail_replay_passes: int = 1
    # v0.5 auditable learning
    audit_enabled: bool = True
    audit_top_actions: int = 5
    verify_repeat: int = 12
    verify_max_states: int = 1500
    evaluation_default_attempts: int = 25
    learning_curve_windows: List[int] = field(default_factory=lambda: [25, 50, 100])
    epsilon_start: float = 0.22
    epsilon_min: float = 0.035
    epsilon_decay: float = 0.995
    q_alpha: float = 0.30
    q_gamma: float = 0.72
    imitation_weight: float = 0.85
    # The search phase has to cross the whole lock inside one attempt, so the
    # step list needs moves big enough to do it. Real human successes moved
    # 0.049 -> 0.195 -> 0.956 in three probes; the old list topped out at 0.12.
    action_steps: List[float] = field(default_factory=lambda: [-0.30, -0.20, -0.12, -0.07, -0.04, -0.022, -0.010, 0.0, 0.010, 0.022, 0.04, 0.07, 0.12, 0.20, 0.30])
    # One attempt is about six probes, so the search may not spend any of them
    # creeping. Cover the lock on a coarse grid first, then halve the step in
    # on the best cell. Measured over 4000 simulated attempts per cell count:
    # 4 cells was best for a six-probe budget, 5-6 for eight.
    search_cells: int = 4
    ramp_microstep: float = 0.04     # smallest refine step worth making
    # v0.6: the state's position is measured FROM THE RAMP, over this window.
    # The target is redrawn every attempt, so an absolute position teaches
    # nothing; the ramp -> opening distance is a property of the lock type.
    state_window_before_ramp: float = 0.05
    state_window_after_ramp: float = 0.30
    # After this many recorded successes the median ramp -> opening distance is
    # used as the first guess once a ramp is found.
    offset_min_samples: int = 3
    reward: RewardConfig = field(default_factory=RewardConfig)

    @staticmethod
    def load() -> "Config":
        if not CONFIG_PATH.exists():
            cfg = Config()
            CONFIG_PATH.write_text(json.dumps(asdict(cfg), indent=2), encoding="utf-8")
            return cfg
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        reward_raw = raw.pop("reward", {})

        # v0.1 migration: its default geometry only covered the small inner keyway,
        # so the red pick was effectively outside the detector. Upgrade only the
        # known old defaults; custom values are preserved.
        if abs(float(raw.get("lock_radius_ratio", 0.20)) - 0.092) < 1e-6:
            raw["lock_radius_ratio"] = 0.20
        if abs(float(raw.get("capture_half_size_ratio", 0.34)) - 0.17) < 1e-6:
            raw["capture_half_size_ratio"] = 0.34
        raw.setdefault("auto_detect_monitor", True)
        raw.setdefault("auto_focus_game_window", True)
        raw.setdefault("monitor_scan_seconds", 6.0)
        raw.setdefault("monitor_scan_threshold", 3.8)

        # Ignore unknown legacy/future keys instead of refusing to start.
        valid = set(Config.__dataclass_fields__.keys()) - {"reward"}
        raw = {k: v for k, v in raw.items() if k in valid}
        cfg = Config(**raw)
        cfg.reward = RewardConfig(**{k: v for k, v in reward_raw.items() if k in RewardConfig.__dataclass_fields__})
        # Persist the migrated values so the next launch is clean.
        CONFIG_PATH.write_text(json.dumps(asdict(cfg), indent=2), encoding="utf-8")
        return cfg


# ---------------------------
# Windows I/O
# ---------------------------

IS_WINDOWS = os.name == "nt"
if IS_WINDOWS:
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    # Explicit pointer-sized return types are required on 64-bit Windows.
    user32.WindowFromPoint.restype = ctypes.c_void_p
    user32.GetAncestor.restype = ctypes.c_void_p
    user32.GetForegroundWindow.restype = ctypes.c_void_p
    kernel32.GetConsoleWindow.restype = ctypes.c_void_p

    INPUT_MOUSE = 0
    INPUT_KEYBOARD = 1
    KEYEVENTF_KEYUP = 0x0002
    MOUSEEVENTF_MOVE = 0x0001

    class MOUSEINPUT(ctypes.Structure):
        _fields_ = [
            ("dx", ctypes.c_long),
            ("dy", ctypes.c_long),
            ("mouseData", ctypes.c_ulong),
            ("dwFlags", ctypes.c_ulong),
            ("time", ctypes.c_ulong),
            ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
        ]

    class KEYBDINPUT(ctypes.Structure):
        _fields_ = [
            ("wVk", ctypes.c_ushort),
            ("wScan", ctypes.c_ushort),
            ("dwFlags", ctypes.c_ulong),
            ("time", ctypes.c_ulong),
            ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
        ]

    class HARDWAREINPUT(ctypes.Structure):
        _fields_ = [("uMsg", ctypes.c_ulong), ("wParamL", ctypes.c_short), ("wParamH", ctypes.c_ushort)]

    class INPUT_UNION(ctypes.Union):
        _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]

    class INPUT(ctypes.Structure):
        _fields_ = [("type", ctypes.c_ulong), ("u", INPUT_UNION)]


def key_down(vk: int) -> bool:
    if not IS_WINDOWS:
        return False
    return bool(user32.GetAsyncKeyState(vk) & 0x8000)


def send_key(vk: int, hold_ms: int = 25) -> None:
    if not IS_WINDOWS:
        return
    extra = ctypes.c_ulong(0)
    inp = INPUT(type=INPUT_KEYBOARD, u=INPUT_UNION(ki=KEYBDINPUT(vk, 0, 0, 0, ctypes.pointer(extra))))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(inp))
    time.sleep(max(0.001, hold_ms / 1000.0))
    inp_up = INPUT(type=INPUT_KEYBOARD, u=INPUT_UNION(ki=KEYBDINPUT(vk, 0, KEYEVENTF_KEYUP, 0, ctypes.pointer(extra))))
    user32.SendInput(1, ctypes.byref(inp_up), ctypes.sizeof(inp_up))


def move_mouse_relative(dx: int, dy: int = 0) -> None:
    if not IS_WINDOWS:
        return
    extra = ctypes.c_ulong(0)
    inp = INPUT(type=INPUT_MOUSE, u=INPUT_UNION(mi=MOUSEINPUT(int(dx), int(dy), 0, MOUSEEVENTF_MOVE, 0, ctypes.pointer(extra))))
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(inp))


def make_mss():
    # mss 10+ exposes MSS directly; older versions use mss().
    cls = getattr(mss, "MSS", None)
    return cls() if cls is not None else mss.mss()


def _console_hwnd() -> int:
    if not IS_WINDOWS:
        return 0
    try:
        return int(kernel32.GetConsoleWindow() or 0)
    except Exception:
        return 0


def _window_rect(hwnd: int) -> Optional[Tuple[int, int, int, int]]:
    if not IS_WINDOWS or not hwnd:
        return None
    class RECT(ctypes.Structure):
        _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long), ("right", ctypes.c_long), ("bottom", ctypes.c_long)]
    rc = RECT()
    if not user32.GetWindowRect(ctypes.c_void_p(hwnd), ctypes.byref(rc)):
        return None
    return int(rc.left), int(rc.top), int(rc.right), int(rc.bottom)


def _window_title(hwnd: int) -> str:
    if not IS_WINDOWS or not hwnd:
        return ""
    try:
        n = int(user32.GetWindowTextLengthW(ctypes.c_void_p(hwnd)))
        buf = ctypes.create_unicode_buffer(max(2, n + 1))
        user32.GetWindowTextW(ctypes.c_void_p(hwnd), buf, len(buf))
        return buf.value
    except Exception:
        return ""


def window_at_point(x: int, y: int) -> int:
    if not IS_WINDOWS:
        return 0
    class POINT(ctypes.Structure):
        _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]
    try:
        hwnd = int(user32.WindowFromPoint(POINT(int(x), int(y))))
        if hwnd:
            GA_ROOT = 2
            root = int(user32.GetAncestor(ctypes.c_void_p(hwnd), GA_ROOT))
            return root or hwnd
    except Exception:
        pass
    return 0


def focus_window(hwnd: int, wait: float = 0.28) -> bool:
    if not IS_WINDOWS or not hwnd:
        return False
    try:
        SW_RESTORE = 9
        user32.ShowWindow(ctypes.c_void_p(hwnd), SW_RESTORE)
        user32.BringWindowToTop(ctypes.c_void_p(hwnd))
        ok = bool(user32.SetForegroundWindow(ctypes.c_void_p(hwnd)))
        time.sleep(0.08)
        fg = int(user32.GetForegroundWindow() or 0)
        if fg != int(hwnd):
            # Windows foreground-lock fallback: a harmless Alt tap lets the
            # foreground process hand focus to the game window it just found.
            VK_MENU = 0x12
            KEYEVENTF_KEYUP_LOCAL = 0x0002
            user32.keybd_event(VK_MENU, 0, 0, 0)
            user32.keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP_LOCAL, 0)
            user32.BringWindowToTop(ctypes.c_void_p(hwnd))
            ok = bool(user32.SetForegroundWindow(ctypes.c_void_p(hwnd))) or ok
        time.sleep(wait)
        return ok or int(user32.GetForegroundWindow() or 0) == int(hwnd)
    except Exception:
        return False


def minimize_console() -> int:
    hwnd = _console_hwnd()
    if IS_WINDOWS and hwnd:
        try:
            user32.ShowWindow(ctypes.c_void_p(hwnd), 6)  # SW_MINIMIZE
            time.sleep(0.22)
        except Exception:
            pass
    return hwnd


def restore_console(hwnd: int) -> None:
    if IS_WINDOWS and hwnd:
        try:
            user32.ShowWindow(ctypes.c_void_p(hwnd), 9)  # SW_RESTORE
            user32.SetForegroundWindow(ctypes.c_void_p(hwnd))
            time.sleep(0.12)
        except Exception:
            pass


def _radial_pick_score(frame: np.ndarray, cx: float, cy: float, radius: float) -> float:
    """Fast pick-presence score used only for monitor discovery."""
    h, w = frame.shape[:2]
    f = frame.astype(np.float32)
    ts = np.linspace(radius * 0.20, radius * 1.42, 135)

    def sample(theta: float, off: float) -> Optional[np.ndarray]:
        xs = (cx + ts * math.cos(theta) + off * (-math.sin(theta))).round().astype(np.int32)
        ys = (cy - ts * math.sin(theta) + off * (-math.cos(theta))).round().astype(np.int32)
        good = (xs >= 0) & (xs < w) & (ys >= 0) & (ys < h)
        if int(good.sum()) < 35:
            return None
        return f[ys[good], xs[good]]

    best = 0.0
    for deg in np.linspace(12.0, 168.0, 105):
        th = math.radians(float(deg))
        center_signals: List[np.ndarray] = []
        side_signals: List[np.ndarray] = []
        for off in (-6.0, 0.0, 6.0):
            pix = sample(th, off)
            if pix is None:
                continue
            b, g, rr = pix[:, 0], pix[:, 1], pix[:, 2]
            chroma = np.maximum.reduce([rr, g, b]) - np.minimum.reduce([rr, g, b])
            center_signals.append(rr - (g + b) * 0.5 + 0.07 * chroma)
        for off in (-25.0, -20.0, 20.0, 25.0):
            pix = sample(th, off)
            if pix is None:
                continue
            b, g, rr = pix[:, 0], pix[:, 1], pix[:, 2]
            chroma = np.maximum.reduce([rr, g, b]) - np.minimum.reduce([rr, g, b])
            side_signals.append(rr - (g + b) * 0.5 + 0.07 * chroma)
        if not center_signals or not side_signals:
            continue
        n = min(min(map(len, center_signals)), min(map(len, side_signals)))
        center = np.mean(np.vstack([a[:n] for a in center_signals]), axis=0)
        sides = np.mean(np.vstack([a[:n] for a in side_signals]), axis=0)
        score = float(np.mean(np.clip(center - sides, 0, None)) + 0.23 * np.mean(center))
        best = max(best, score)
    return best


def lock_ui_score(frame: np.ndarray) -> Tuple[float, Dict[str, float]]:
    """Score whether a monitor-centre crop contains the supplied SCUM-like lock UI.

    Static white circular arcs + the reddish radial pick are much safer than the
    old v0.1 'dark line' confidence, which could report a random desktop edge as
    a fully rotated lock.
    """
    h, w = frame.shape[:2]
    base = float(min(h, w))
    cx, cy = w * 0.5, h * 0.5
    radius = base * 0.20
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
    yy, xx = np.ogrid[:h, :w]
    dist = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)

    annulus = (dist > radius * 0.78) & (dist < radius * 1.10)
    white = (gray > 150) & (hsv[:, :, 1] < 120)
    arc_fraction = float(white[annulus].mean()) if np.any(annulus) else 0.0
    arc_score = float(np.clip(arc_fraction / 0.055, 0.0, 1.8))

    # Hough circle near the exact centre is a second independent signature.
    half = int(min(base * 0.36, min(h, w) * 0.48))
    x0, x1 = max(0, int(cx - half)), min(w, int(cx + half))
    y0, y1 = max(0, int(cy - half)), min(h, int(cy + half))
    crop = frame[y0:y1, x0:x1]
    cg = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    cg = cv2.GaussianBlur(cg, (7, 7), 1.5)
    local_center = np.array([crop.shape[1] * 0.5, crop.shape[0] * 0.5], dtype=np.float32)
    expected_r = radius
    circle_score = 0.0
    circles = cv2.HoughCircles(
        cg, cv2.HOUGH_GRADIENT, dp=1.2, minDist=max(70, int(expected_r * 0.55)),
        param1=120, param2=42, minRadius=max(45, int(expected_r * 0.68)),
        maxRadius=max(70, int(expected_r * 1.25)),
    )
    if circles is not None:
        for c in circles[0]:
            d = float(np.linalg.norm(np.array(c[:2]) - local_center)) / max(1.0, expected_r)
            rd = abs(float(c[2]) - expected_r) / max(1.0, expected_r)
            sc = math.exp(-((d / 0.30) ** 2)) * math.exp(-((rd / 0.30) ** 2))
            circle_score = max(circle_score, sc)

    pick_score = _radial_pick_score(frame, cx, cy, radius)
    pick_norm = float(np.clip(pick_score / 8.0, 0.0, 1.6))
    total = 2.8 * circle_score + 2.7 * arc_score + 1.25 * pick_norm
    return float(total), {
        "arc": arc_fraction,
        "circle": float(circle_score),
        "pick": float(pick_score),
    }


def discover_lock_monitor(cfg: Config) -> Tuple[int, Optional[int], Optional[Tuple[int, int, int, int]], float]:
    """Find the physical monitor that currently shows the lock minigame.

    Returns (mss monitor index, hwnd under monitor centre, window rect, score).
    """
    sct = make_mss()
    monitors = sct.monitors
    if len(monitors) <= 1:
        return 1, None, None, 0.0
    if len(monitors) == 2:
        mon = monitors[1]
        frame = np.asarray(sct.grab(mon))
        frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
        score, parts = lock_ui_score(frame)
        mx = int(mon["left"] + mon["width"] * cfg.center_x_ratio)
        my = int(mon["top"] + mon["height"] * cfg.center_y_ratio)
        hwnd = window_at_point(mx, my)
        if hwnd == _console_hwnd():
            hwnd = 0
        rect = _window_rect(hwnd) if hwnd else None
        print(f"Auto monitor: #1 {mon['width']}x{mon['height']} score={score:.2f} (arc={parts.get('arc', 0):.3f}, circle={parts.get('circle', 0):.2f}, pick={parts.get('pick', 0):.1f})")
        return 1, hwnd or None, rect, score

    deadline = time.monotonic() + max(0.5, cfg.monitor_scan_seconds)
    best_idx = min(max(1, int(cfg.monitor or 1)), len(monitors) - 1)
    best_score = -1.0
    best_parts: Dict[str, float] = {}
    while True:
        for idx in range(1, len(monitors)):
            mon = monitors[idx]
            frame = np.asarray(sct.grab(mon))
            frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
            score, parts = lock_ui_score(frame)
            if score > best_score:
                best_idx, best_score, best_parts = idx, score, parts
        if best_score >= cfg.monitor_scan_threshold or time.monotonic() >= deadline:
            break
        time.sleep(0.18)

    mon = monitors[best_idx]
    mx = int(mon["left"] + mon["width"] * cfg.center_x_ratio)
    my = int(mon["top"] + mon["height"] * cfg.center_y_ratio)
    hwnd = window_at_point(mx, my)
    con = _console_hwnd()
    if hwnd == con:
        hwnd = 0
    rect = _window_rect(hwnd) if hwnd else None
    print(
        f"Auto monitor: #{best_idx} {mon['width']}x{mon['height']} "
        f"score={best_score:.2f} (arc={best_parts.get('arc', 0):.3f}, "
        f"circle={best_parts.get('circle', 0):.2f}, pick={best_parts.get('pick', 0):.1f})"
    )
    return best_idx, hwnd or None, rect, best_score


def prepare_live_vision(cfg: Config, model: "QModel", minimize: bool = True) -> Tuple["ScreenVision", int, Optional[int]]:
    """Hide the menu console, discover the game monitor, focus it and build vision."""
    console = minimize_console() if minimize else _console_hwnd()
    time.sleep(0.18)
    if cfg.auto_detect_monitor:
        idx, hwnd, rect, score = discover_lock_monitor(cfg)
    else:
        sct = make_mss()
        idx = min(max(1, int(cfg.monitor or 1)), len(sct.monitors) - 1)
        mon = sct.monitors[idx]
        x = int(mon["left"] + mon["width"] * cfg.center_x_ratio)
        y = int(mon["top"] + mon["height"] * cfg.center_y_ratio)
        hwnd = window_at_point(x, y)
        rect = _window_rect(hwnd) if hwnd else None
        score = 0.0

    if cfg.auto_focus_game_window and hwnd:
        title = _window_title(hwnd)
        focus_window(hwnd)
        print(f"Focused game window: {title or '[untitled window]'}")
    elif cfg.auto_focus_game_window:
        print("[WARN] Could not identify a game window under the detected monitor centre.")

    vision = ScreenVision(cfg, model.calibration, monitor_index=idx, window_rect=rect)
    return vision, console, hwnd


def calibration_valid(model: "QModel", vision: "ScreenVision") -> bool:
    cal = model.calibration
    try:
        left = float(cal["pick_left_raw"])
        right = float(cal["pick_right_raw"])
        gain = float(cal["mouse_counts_per_norm"])
        version_ok = float(cal.get("vision_version", 0.0)) >= 2.0
        same_mon = int(float(cal.get("monitor_index", -999))) == vision.monitor_index
        same_size = int(float(cal.get("monitor_width", -1))) == vision.width and int(float(cal.get("monitor_height", -1))) == vision.height
        return version_ok and (right - left) > 0.55 and 100.0 <= gain <= 8000.0 and same_mon and same_size
    except Exception:
        return False


# ---------------------------
# Screen + vision
# ---------------------------

@dataclass
class VisionState:
    timestamp: float
    pick_raw: Optional[float]
    pick_pos: Optional[float]
    pick_score: float
    lock_angle: Optional[float]
    progress: float
    ui_confidence: float
    success_score: float = 0.0
    success_detected: bool = False
    frame: Optional[np.ndarray] = None


class ScreenVision:
    def __init__(self, cfg: Config, calibration: Optional[Dict[str, float]] = None, monitor_index: Optional[int] = None, window_rect: Optional[Tuple[int, int, int, int]] = None):
        self.cfg = cfg
        self.sct = make_mss()
        monitors = self.sct.monitors
        requested = monitor_index if monitor_index is not None else cfg.monitor
        idx = min(max(1, int(requested or 1)), len(monitors) - 1)
        self.monitor_index = idx
        self.mon = monitors[idx]
        self.width = int(self.mon["width"])
        self.height = int(self.mon["height"])

        # If the game is windowed, use the visible game-window centre rather than
        # blindly assuming the physical monitor centre. Fullscreen/borderless
        # naturally produces the same centre.
        if window_rect is not None:
            l, t, r, b = window_rect
            ww, wh = max(1, r - l), max(1, b - t)
            self.cx = int(l + ww * cfg.center_x_ratio)
            self.cy = int(t + wh * cfg.center_y_ratio)
            base_w, base_h = ww, wh
        else:
            self.cx = int(self.mon["left"] + self.width * cfg.center_x_ratio)
            self.cy = int(self.mon["top"] + self.height * cfg.center_y_ratio)
            base_w, base_h = self.width, self.height

        base = min(base_w, base_h)
        self.radius = max(95, int(base * cfg.lock_radius_ratio))
        self.half = max(260, int(base * cfg.capture_half_size_ratio))
        # Keep the capture box inside the selected monitor/window dimensions.
        self.half = min(self.half, max(150, int(min(self.width, self.height) * 0.46)))
        self.cal = dict(calibration or {})
        self._last_good_pick = None
        self._last_pick_score = 0.0
        self._arc_mask = None          # built once, on the first frame
        self._keyway_mask = None
        self._kx = self._ky = None
        self._last_angle = 0.0
        self._last_progress = 0.0
        self.last_success_parts = (0, 0, 0.0)  # (band_px, arc_px, template) for VISION DEBUG
        self.success_template = cv2.imread(str(SUCCESS_TEMPLATE_PATH), cv2.IMREAD_GRAYSCALE) if SUCCESS_TEMPLATE_PATH.exists() else None
        if self.success_template is not None:
            _, self.success_template = cv2.threshold(self.success_template, 127, 255, cv2.THRESH_BINARY)
        self.refine_center()

    def region(self) -> Dict[str, int]:
        return {
            "left": int(self.cx - self.half),
            "top": int(self.cy - self.half),
            "width": int(self.half * 2),
            "height": int(self.half * 2),
        }

    def grab(self) -> np.ndarray:
        shot = np.asarray(self.sct.grab(self.region()))
        return cv2.cvtColor(shot, cv2.COLOR_BGRA2BGR)

    def refine_center(self) -> None:
        """Try to lock onto the main circular lock, but safely keep screen-center fallback."""
        try:
            frame = self.grab()
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            gray = cv2.GaussianBlur(gray, (7, 7), 1.5)
            minr = int(self.radius * 0.68)
            maxr = int(self.radius * 1.25)
            circles = cv2.HoughCircles(
                gray, cv2.HOUGH_GRADIENT, dp=1.2, minDist=max(70, int(self.radius * 0.55)),
                param1=120, param2=42, minRadius=minr, maxRadius=maxr,
            )
            if circles is None:
                return
            local_center = np.array([self.half, self.half], dtype=np.float32)
            # Prefer a circle both near the capture centre and near the expected
            # outer UI radius. This rejects random inner circles/keyway details.
            def rank(c):
                d = float(np.linalg.norm(np.array(c[:2]) - local_center)) / max(1.0, self.radius)
                rd = abs(float(c[2]) - self.radius) / max(1.0, self.radius)
                return d * 1.6 + rd
            best = min(circles[0], key=rank)
            bx, by, br = map(float, best)
            if np.linalg.norm(np.array([bx, by]) - local_center) < self.radius * 0.42:
                self.cx += int(round(bx - self.half))
                self.cy += int(round(by - self.half))
                self.radius = int(round(br))
        except Exception:
            pass

    @staticmethod
    def _sample_line(img: np.ndarray, cx: float, cy: float, theta: float, ts: np.ndarray, off: float) -> np.ndarray:
        h, w = img.shape[:2]
        xs = (cx + ts * math.cos(theta) + off * (-math.sin(theta))).round().astype(np.int32)
        ys = (cy - ts * math.sin(theta) + off * (-math.cos(theta))).round().astype(np.int32)
        good = (xs >= 0) & (xs < w) & (ys >= 0) & (ys < h)
        return img[ys[good], xs[good]]

    def detect_pick(self, frame: np.ndarray) -> Tuple[Optional[float], float, Optional[float]]:
        """Find the reddish pick as a radial bar. Returns (raw_angle_deg, score, normalized_pos)."""
        c = float(self.half)
        r = float(self.radius)
        ts = np.linspace(r * 0.18, r * 1.45, 120)
        # SCUM-like range lives in upper half. Dense enough for closed-loop control.
        angles = np.linspace(12.0, 168.0, 157)
        best_angle = None
        best_score = -1e9

        f = frame.astype(np.float32)
        for deg in angles:
            th = math.radians(float(deg))
            center_signals = []
            side_signals = []
            for off in (-5.0, 0.0, 5.0):
                pix = self._sample_line(f, c, c, th, ts, off)
                if len(pix) < 30:
                    continue
                b, g, rr = pix[:, 0], pix[:, 1], pix[:, 2]
                red = rr - (g + b) * 0.5
                chroma = np.maximum.reduce([rr, g, b]) - np.minimum.reduce([rr, g, b])
                center_signals.append(red + 0.07 * chroma)
            for off in (-22.0, -18.0, 18.0, 22.0):
                pix = self._sample_line(f, c, c, th, ts, off)
                if len(pix) < 30:
                    continue
                b, g, rr = pix[:, 0], pix[:, 1], pix[:, 2]
                red = rr - (g + b) * 0.5
                chroma = np.maximum.reduce([rr, g, b]) - np.minimum.reduce([rr, g, b])
                side_signals.append(red + 0.07 * chroma)
            if not center_signals or not side_signals:
                continue
            center = np.mean(np.vstack(center_signals), axis=0)
            sides = np.mean(np.vstack(side_signals), axis=0)
            n = min(len(center), len(sides))
            contrast = center[:n] - sides[:n]
            # Radial bar gives sustained positive local contrast; the base term helps dark-red picks.
            score = float(np.mean(np.clip(contrast, 0, None)) + 0.23 * np.mean(center[:n]))
            if score > best_score:
                best_score = score
                best_angle = float(deg)

        # Convert angle to a monotonic raw axis: left ~= -cos, right ~= +cos.
        raw = None if best_angle is None else float(math.cos(math.radians(best_angle)))
        pos = None
        left = self.cal.get("pick_left_raw")
        right = self.cal.get("pick_right_raw")
        if raw is not None and left is not None and right is not None and abs(right - left) > 1e-5:
            pos = float(np.clip((raw - left) / (right - left), 0.0, 1.0))

        # Temporal guard against a single noisy frame.
        if raw is not None and best_score > 2.0:
            self._last_good_pick = raw
            self._last_pick_score = best_score
        elif self._last_good_pick is not None:
            raw = self._last_good_pick
            best_score = self._last_pick_score * 0.7
            if left is not None and right is not None and abs(right - left) > 1e-5:
                pos = float(np.clip((raw - left) / (right - left), 0.0, 1.0))
        return raw, float(best_score), pos

    def detect_lock_rotation(self, frame: np.ndarray) -> Tuple[float, float, float]:
        """How far the cylinder has turned, 0 = at rest, 1 = fully round.

        Measured from the black keyway alone: take every dark pixel inside the
        cylinder and compute the principal direction of that blob (second
        moments). No line search, no per-angle loop.

        The old version scored 180 candidate lines with a python loop - 24 ms
        per read - and its answer was quantised to whole degrees, which put a
        still lock at 0.089 instead of 0.011. That fake noise floor is what
        made a ramp look found on the first probe of 83% of attempts.
        """
        gray = frame[:, :, 0] * 0.114 + frame[:, :, 1] * 0.587 + frame[:, :, 2] * 0.299
        h, w = gray.shape[:2]
        if self._keyway_mask is None or self._keyway_mask.shape != gray.shape:
            yy, xx = np.mgrid[0:h, 0:w]
            self._kx = (xx - w // 2).astype(np.float32)
            self._ky = (yy - h // 2 - self.cfg.keyway_center_y * self.height).astype(np.float32)
            self._keyway_mask = (self._kx ** 2 + self._ky ** 2) < (self.cfg.keyway_radius * self.height) ** 2

        dark = (gray < self.cfg.keyway_dark_max) & self._keyway_mask
        n = int(dark.sum())
        if n < self.cfg.keyway_min_pixels:
            return self._last_angle, self._last_progress, 0.0

        x = self._kx[dark].astype(np.float64)
        y = self._ky[dark].astype(np.float64)
        x -= x.mean()
        y -= y.mean()
        xx_ = float((x * x).mean())
        yy_ = float((y * y).mean())
        xy_ = float((x * y).mean())
        juuri = math.sqrt(max(0.0, (xx_ - yy_) ** 2 + 4.0 * xy_ * xy_))
        iso = (xx_ + yy_ + juuri) / 2.0
        pieni = (xx_ + yy_ - juuri) / 2.0
        pitkulaisuus = math.sqrt(iso / pieni) if pieni > 1e-9 else 999.0
        if pitkulaisuus < self.cfg.keyway_min_elongation:
            # Too round to have a direction - keep the last good reading.
            return self._last_angle, self._last_progress, 0.0

        angle = math.degrees(0.5 * math.atan2(2.0 * xy_, xx_ - yy_)) + 90.0
        # A principal direction repeats every 180 degrees, so pick the branch
        # nearest the last reading, then force it into the range the cylinder
        # can physically occupy (0 at rest to about 90 when open).
        while angle - self._last_angle > 90.0:
            angle -= 180.0
        while self._last_angle - angle > 90.0:
            angle += 180.0
        while angle < -25.0:
            angle += 180.0
        while angle > 125.0:
            angle -= 180.0

        progress = float(np.clip(angle / 90.0, 0.0, 1.0))
        self._last_angle = angle
        self._last_progress = progress
        darkness = float(np.clip(n / max(1.0, float(self.cfg.keyway_min_pixels) * 4.0), 0.0, 1.0))
        return angle, progress, darkness

    def detect_success(self, frame: np.ndarray) -> Tuple[float, bool]:
        """Is the SUCCESS banner on screen?

        Two independent marks, both measured from real gameplay frames:
        a bright text band across the middle, and the timer arc gone.
        Neither needs a template, OCR or cv2 matching, and both were
        verified 15/15 on the reference frames in kuvat\\.

        Returns (confidence 0..1, detected). The confidence is the weaker
        of the two marks, so one alone can never claim a success.
        """
        gray = frame[:, :, 0] * 0.114 + frame[:, :, 1] * 0.587 + frame[:, :, 2] * 0.299
        h, w = gray.shape[:2]
        cy, cx = h // 2, w // 2

        # 1) bright text band across the middle
        bh = max(8, int(self.height * self.cfg.success_band_half_h))
        bw = max(8, int(self.height * self.cfg.success_band_half_w))
        band = gray[max(0, cy - bh):cy + bh, max(0, cx - bw):cx + bw]
        band_px = int((band > float(self.cfg.success_band_bright)).sum())

        # 2) the countdown arc around the lock has to be gone
        if self._arc_mask is None or self._arc_mask.shape != gray.shape:
            yy, xx = np.mgrid[0:h, 0:w]
            dist = np.sqrt((xx - cx) ** 2.0 + (yy - cy) ** 2.0)
            lock_r = 0.139 * self.height
            self._arc_mask = (dist > lock_r * 1.05) & (dist < lock_r * 1.75)
        arc_px = int(((gray > float(self.cfg.success_arc_bright)) & self._arc_mask).sum())

        band_conf = float(np.clip(band_px / max(1.0, float(self.cfg.success_band_pixels)), 0.0, 1.0))
        arc_conf = float(np.clip((float(self.cfg.success_arc_max) - arc_px) / max(1.0, float(self.cfg.success_arc_max)), 0.0, 1.0))
        score = min(band_conf, arc_conf)

        # Second, independent reading: the bundled SUCCESS word, template
        # matched. Real logs show it separating cleanly on a live machine
        # (9/9 human successes 0.643-0.998, 41/41 failures <= 0.076), so it
        # runs alongside the band/arc test and either one is enough.
        # The template match costs far more than the two measurements above,
        # and during normal play the band sits near 1000 while a SUCCESS screen
        # is above 5000. So only pay for it once something bright shows up.
        templ_score = 0.0
        if self.cfg.success_use_template and band_px >= self.cfg.success_band_pixels * 0.35:
            templ_score = self.detect_success_template(frame)
        self.last_success_parts = (band_px, arc_px, templ_score)
        best = max(score, templ_score)
        return best, bool(best >= self.cfg.success_threshold)

    def detect_success_template(self, frame: np.ndarray) -> float:
        """Match the bundled SUCCESS word near the lock centre."""
        if self.success_template is None or self.success_template.size == 0:
            return 0.0
        try:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            bright = (gray >= int(self.cfg.success_arc_bright)).astype(np.uint8) * 255
            c = int(self.half)
            base_scale = max(0.45, min(2.5, self.height / 1079.0))
            best = 0.0
            for mul in (0.88, 0.94, 1.00, 1.06, 1.12):
                sc = base_scale * mul
                tw = max(60, int(round(self.success_template.shape[1] * sc)))
                th = max(18, int(round(self.success_template.shape[0] * sc)))
                templ = cv2.resize(self.success_template, (tw, th), interpolation=cv2.INTER_NEAREST)
                mx = max(12, int(tw * 0.10))
                my = max(8, int(th * 0.22))
                yoff = int(round(self.height * 0.004))
                x0 = max(0, c - tw // 2 - mx)
                x1 = min(bright.shape[1], c + (tw - tw // 2) + mx)
                y0 = max(0, c + yoff - th // 2 - my)
                y1 = min(bright.shape[0], c + yoff + (th - th // 2) + my)
                roi = bright[y0:y1, x0:x1]
                if roi.shape[0] <= th or roi.shape[1] <= tw:
                    continue
                result = cv2.matchTemplate(roi, templ, cv2.TM_CCOEFF_NORMED)
                if result.size:
                    best = max(best, float(cv2.minMaxLoc(result)[1]))
            return best
        except Exception:
            return 0.0

    def state(self, keep_frame: bool = False) -> VisionState:
        frame = self.grab()
        raw, pick_score, pos = self.detect_pick(frame)
        angle, progress, dark_conf = self.detect_lock_rotation(frame)
        pick_conf = float(np.clip((pick_score - 1.0) / 10.0, 0.0, 1.0))
        ui_conf = 0.55 * dark_conf + 0.45 * pick_conf
        success_score, success_detected = self.detect_success(frame)
        return VisionState(time.monotonic(), raw, pos, pick_score, angle, progress, ui_conf, success_score, success_detected, frame if keep_frame else None)

    def update_calibration(self, left_raw: float, right_raw: float) -> None:
        if right_raw < left_raw:
            left_raw, right_raw = right_raw, left_raw
        self.cal["pick_left_raw"] = float(left_raw)
        self.cal["pick_right_raw"] = float(right_raw)


# ---------------------------
# Model + reward
# ---------------------------

class QModel:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.q: Dict[str, List[float]] = {}
        self.demo_prior: Dict[str, List[float]] = {}
        self.calibration: Dict[str, float] = {}
        self.epsilon = cfg.epsilon_start
        self.total_successes = 0
        self.total_attempts = 0
        self.total_updates = 0
        self.human_episodes = 0
        self.human_successes = 0
        self.human_failures = 0
        self.human_incomplete = 0
        self.selfplay_episodes = 0
        self.selfplay_successes = 0
        self.selfplay_failures = 0
        self.selfplay_replay_updates = 0
        # v0.6: ramp -> opening distance from every confirmed success.
        self.success_offsets: List[float] = []
        self.load()

    def load(self) -> None:
        if not MODEL_PATH.exists():
            if BUNDLED_MODEL_PATH.exists():
                try:
                    MODEL_PATH.write_text(BUNDLED_MODEL_PATH.read_text(encoding="utf-8"), encoding="utf-8")
                    print("[NOTE] No model yet - starting from the bundled pre-trained policy")
                    print("       (50 recorded human attempts + simulated self-play).")
                except Exception as e:
                    print(f"[WARN] Could not use the bundled model: {e}")
                    return
            else:
                return
        try:
            raw = json.loads(MODEL_PATH.read_text(encoding="utf-8"))
            schema = int(raw.get("state_schema", 1))
            if schema != STATE_SCHEMA:
                # The old keys were absolute pick positions, which mean nothing
                # now that the state is measured from the ramp. Keeping them
                # would be worse than starting clean. The recorded demos and
                # self-play episodes survive: run TRAIN to rebuild from them.
                print(f"[NOTE] Model was built with state schema v{schema}, this is v{STATE_SCHEMA}.")
                print("       Learned values dropped; calibration and recorded episodes kept.")
                print("       Run TRAIN (and SELF TRAIN) to rebuild the policy from your data.")
                raw["q"] = {}
                raw["demo_prior"] = {}
            self.q = {k: list(map(float, v)) for k, v in raw.get("q", {}).items()}
            self.demo_prior = {k: list(map(float, v)) for k, v in raw.get("demo_prior", {}).items()}
            self.calibration = {k: float(v) for k, v in raw.get("calibration", {}).items()}
            self.epsilon = float(raw.get("epsilon", self.cfg.epsilon_start))
            self.total_successes = int(raw.get("total_successes", 0))
            self.total_attempts = int(raw.get("total_attempts", 0))
            self.total_updates = int(raw.get("total_updates", 0))
            self.human_episodes = int(raw.get("human_episodes", 0))
            self.human_successes = int(raw.get("human_successes", 0))
            self.human_failures = int(raw.get("human_failures", 0))
            self.human_incomplete = int(raw.get("human_incomplete", 0))
            self.selfplay_episodes = int(raw.get("selfplay_episodes", 0))
            self.selfplay_successes = int(raw.get("selfplay_successes", 0))
            self.selfplay_failures = int(raw.get("selfplay_failures", 0))
            self.selfplay_replay_updates = int(raw.get("selfplay_replay_updates", 0))
            self.success_offsets = [float(x) for x in raw.get("success_offsets", [])]
        except Exception as e:
            print(f"[WARN] Model load failed: {e}")

    def save(self) -> None:
        obj = {
            "state_schema": STATE_SCHEMA,
            "q": self.q,
            "demo_prior": self.demo_prior,
            "calibration": self.calibration,
            "epsilon": self.epsilon,
            "total_successes": self.total_successes,
            "total_attempts": self.total_attempts,
            "total_updates": self.total_updates,
            "human_episodes": self.human_episodes,
            "human_successes": self.human_successes,
            "human_failures": self.human_failures,
            "human_incomplete": self.human_incomplete,
            "selfplay_episodes": self.selfplay_episodes,
            "selfplay_successes": self.selfplay_successes,
            "selfplay_failures": self.selfplay_failures,
            "selfplay_replay_updates": self.selfplay_replay_updates,
            "success_offsets": self.success_offsets,
            "action_steps": self.cfg.action_steps,
        }
        tmp = MODEL_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(obj, indent=2), encoding="utf-8")
        tmp.replace(MODEL_PATH)

    def state_key(self, pos: float, response: float, best: float, trend: int,
                  found_ramp: bool, ramp_pos: Optional[float] = None) -> str:
        """Position is measured FROM THE RAMP, never from the lock's left edge.

        The target is redrawn on every attempt, so "0.62 was good" is worth
        nothing on the next lock. The distance from the ramp to the opening
        point IS a property of the lock type, so that is what gets learned.
        Before a ramp is found there is nothing to measure from, so every
        search state collapses into one: "keep sweeping".
        """
        if found_ramp and ramp_pos is not None:
            span = max(1e-6, self.cfg.state_window_before_ramp + self.cfg.state_window_after_ramp)
            rel = float(np.clip((pos - ramp_pos + self.cfg.state_window_before_ramp) / span, 0.0, 0.999))
            pb = int(rel * 15.999)
        else:
            pb = 0
        rb = int(np.clip(response * 5.999, 0, 5))
        bb = int(np.clip(best * 5.999, 0, 5))
        tr = -1 if trend < 0 else (1 if trend > 0 else 0)
        phase = 1 if found_ramp else 0
        return f"{phase}:{pb}:{rb}:{bb}:{tr}"

    def note_success(self, ramp_pos: Optional[float], open_pos: float) -> None:
        """Remember how far past the ramp this lock actually opened."""
        if ramp_pos is None:
            return
        offset = float(open_pos - ramp_pos)
        if -0.30 <= offset <= 0.60:
            self.success_offsets.append(offset)
            self.success_offsets = self.success_offsets[-200:]

    def learned_offset(self) -> Optional[float]:
        """Median ramp -> opening distance, once there is enough evidence."""
        if len(self.success_offsets) < int(self.cfg.offset_min_samples):
            return None
        return float(np.median(np.asarray(self.success_offsets, dtype=np.float64)))

    def ensure(self, key: str) -> List[float]:
        if key not in self.q:
            self.q[key] = [0.0] * len(self.cfg.action_steps)
        return self.q[key]

    def policy_payload(self) -> Dict[str, object]:
        return {
            "q": {k: [float(x) for x in v] for k, v in sorted(self.q.items())},
            "demo_prior": {k: [float(x) for x in v] for k, v in sorted(self.demo_prior.items())},
            "action_steps": [float(x) for x in self.cfg.action_steps],
            "imitation_weight": float(self.cfg.imitation_weight),
        }

    def policy_hash(self) -> str:
        blob = json.dumps(self.policy_payload(), sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        return hashlib.sha256(blob).hexdigest()

    def decision_details(self, key: str, deterministic: bool = False) -> Dict[str, object]:
        q = np.asarray(self.q.get(key, [0.0] * len(self.cfg.action_steps)), dtype=np.float64)
        prior = np.asarray(self.demo_prior.get(key, [0.0] * len(q)), dtype=np.float64)
        scores = q + self.cfg.imitation_weight * prior
        explored = False
        if (not deterministic) and random.random() < self.epsilon:
            action = random.randrange(len(q))
            explored = True
            reason = "epsilon_exploration"
        else:
            action = int(np.argmax(scores)) if deterministic else int(np.argmax(scores + np.random.uniform(0, 1e-8, size=len(scores))))
            reason = "learned_argmax"
        order = np.argsort(scores)[::-1][:max(1, int(self.cfg.audit_top_actions))]
        top = [{
            "action": int(i), "delta": float(self.cfg.action_steps[int(i)]),
            "q": float(q[int(i)]), "prior": float(prior[int(i)]), "score": float(scores[int(i)])
        } for i in order]
        return {
            "state": key, "action": int(action), "exploration": bool(explored), "reason": reason,
            "q": q.tolist(), "prior": prior.tolist(), "scores": scores.tolist(), "top": top,
            "q_chosen": float(q[action]), "prior_chosen": float(prior[action]), "score_chosen": float(scores[action]),
        }

    def choose(self, key: str, deterministic: bool = False) -> int:
        return int(self.decision_details(key, deterministic=deterministic)["action"])

    def update(self, key: str, action: int, reward: float, next_key: str) -> Tuple[float, float]:
        q = self.ensure(key)
        nq = self.ensure(next_key)
        before = float(q[action])
        target = reward + self.cfg.q_gamma * max(nq)
        q[action] += self.cfg.q_alpha * (target - q[action])
        after = float(q[action])
        self.total_updates += 1
        self.epsilon = max(self.cfg.epsilon_min, self.epsilon * self.cfg.epsilon_decay)
        return before, after

    def terminal_update(self, key: str, action: int, terminal_reward: float) -> Tuple[float, float]:
        q = self.ensure(key)
        before = float(q[action])
        q[action] += self.cfg.q_alpha * (terminal_reward - q[action])
        after = float(q[action])
        self.total_updates += 1
        self.epsilon = max(self.cfg.epsilon_min, self.epsilon * self.cfg.epsilon_decay)
        return before, after

    def replay_update(self, key: str, action: int, reward: float, next_key: str) -> None:
        q = self.ensure(key)
        nq = self.ensure(next_key)
        target = reward + self.cfg.q_gamma * max(nq)
        q[action] += self.cfg.q_alpha * (target - q[action])
        self.total_updates += 1
        self.selfplay_replay_updates += 1

    def replay_terminal_update(self, key: str, action: int, terminal_reward: float) -> None:
        q = self.ensure(key)
        q[action] += self.cfg.q_alpha * (terminal_reward - q[action])
        self.total_updates += 1
        self.selfplay_replay_updates += 1


class RewardEngine:
    def __init__(self, cfg: Config):
        self.cfg = cfg

    def step(self, response: float, prev_response: float, best_before: float, dt: float) -> float:
        """dt is the time THIS probe took, not the whole attempt.

        v0.5 charged every probe the elapsed time of the entire episode, so a
        late probe was punished for every earlier probe as well and the same
        action looked worse purely for happening later. Each probe now pays
        only for its own time.
        """
        rc = self.cfg.reward
        improvement = max(0.0, response - prev_response)
        best_gain = max(0.0, response - best_before)
        reward = 0.0
        if response >= self.cfg.wobble_threshold:
            reward += rc.wobble_bonus
        reward += rc.progress_gain * improvement
        reward += rc.absolute_progress * response
        reward += rc.new_best_bonus * best_gain
        reward -= rc.probe_cost
        reward -= rc.time_cost_per_second * max(0.0, dt)
        return float(reward)

    def success(self, elapsed: float) -> float:
        rc = self.cfg.reward
        speed_ratio = max(0.0, 1.0 - elapsed / max(0.1, self.cfg.attempt_budget_seconds))
        return float(rc.success_reward + rc.speed_bonus_max * speed_ratio)


# ---------------------------
# Helpers
# ---------------------------

def preview(vision: ScreenVision, st: VisionState, title: str = APP_NAME) -> None:
    if st.frame is None:
        return
    im = st.frame.copy()
    c = vision.half
    cv2.circle(im, (c, c), vision.radius, (255, 255, 255), 1)
    txt = f"pick={st.pick_pos if st.pick_pos is not None else -1:.3f} progress={st.progress:.3f} pscore={st.pick_score:.1f} ui={st.ui_confidence:.2f} SUCCESS={st.success_score:.2f}{' YES' if st.success_detected else ''}"
    cv2.putText(im, txt, (8, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.47, (255, 255, 255), 1, cv2.LINE_AA)
    cv2.imshow(title, im)
    cv2.waitKey(1)


def emergency_or_pause(cfg: Config) -> bool:
    if key_down(cfg.emergency_key_vk):
        print("\n[F12] Emergency stop.")
        return True
    while key_down(cfg.pause_key_vk):
        print("[F10] Paused. Release F10 to continue.", end="\r")
        time.sleep(0.05)
    return False


def save_success(trace: List[Dict[str, object]], summary: Dict[str, object]) -> None:
    """Keeps everything from an attempt that actually opened the lock.

    The probe-by-probe trace goes in its own file under data\\successes\\,
    and one summary row is appended to data\\successes.csv so the numbers
    that matter - where the ramp was, how far past it the lock opened, how
    long it took - can be read at a glance or loaded back for learning.
    """
    try:
        stamp = time.strftime("%Y%m%d_%H%M%S")
        path = SUCCESS_DIR / f"success_{stamp}.csv"
        n = 2
        while path.exists():
            path = SUCCESS_DIR / f"success_{stamp}_{n}.csv"
            n += 1
        if trace:
            keys = list(trace[0].keys())
            with path.open("w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=keys)
                w.writeheader()
                for row in trace:
                    w.writerow({k: row.get(k, "") for k in keys})
        head = ["wall_time", "file", "source", "elapsed", "probes", "pick", "ramp_pos", "offset", "best", "reward", "score", "note"]
        new = not SUCCESS_INDEX.exists()
        with SUCCESS_INDEX.open("a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=head)
            if new:
                w.writeheader()
            row = {k: "" for k in head}
            row["wall_time"] = time.strftime("%Y-%m-%d %H:%M:%S")
            row["file"] = path.name if trace else ""
            row.update({k: v for k, v in summary.items() if k in head})
            w.writerow(row)
    except Exception as e:
        print(f"[WARN] Success save failed: {e}")


def append_event(kind: str, fields: Dict[str, object]) -> None:
    exists = EVENT_LOG.exists()
    row = {"wall_time": time.strftime("%Y-%m-%d %H:%M:%S"), "kind": kind, **fields}
    keys = ["wall_time", "kind", "elapsed", "pick", "response", "best", "reward", "success", "note"]
    with EVENT_LOG.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        if not exists:
            w.writeheader()
        w.writerow(row)


def _atomic_json(path: Path, obj: Dict[str, object]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


def snapshot_model(model: QModel, label: str) -> Path:
    stamp = time.strftime("%Y%m%d_%H%M%S") + f"_{int((time.time()%1)*1000):03d}"
    ph = model.policy_hash()
    path = AUDIT_SNAPSHOT_DIR / f"{label}_{stamp}_{ph[:12]}.json"
    _atomic_json(path, {"label": label, "created": time.strftime("%Y-%m-%d %H:%M:%S"), "policy_hash": ph, "policy": model.policy_payload()})
    return path


def _count_policy_changes(before: Dict[str, List[float]], after: Dict[str, List[float]]) -> Tuple[int, int]:
    changed_states = changed_values = 0
    for key in set(before) | set(after):
        a = list(map(float, before.get(key, [])))
        b = list(map(float, after.get(key, [])))
        if len(a) != len(b):
            changed_states += 1; changed_values += max(len(a), len(b)); continue
        diffs = [abs(x-y) > 1e-12 for x,y in zip(a,b)]
        if any(diffs):
            changed_states += 1; changed_values += sum(diffs)
    return changed_states, changed_values


def append_training_audit(kind: str, before_hash: str, after_hash: str, changed_states: int, changed_values: int, note: str = "") -> None:
    exists = TRAIN_AUDIT_LOG.exists()
    fields = ["wall_time", "kind", "before_hash", "after_hash", "hash_changed", "changed_states", "changed_values", "note"]
    row = {"wall_time": time.strftime("%Y-%m-%d %H:%M:%S"), "kind": kind, "before_hash": before_hash, "after_hash": after_hash, "hash_changed": int(before_hash != after_hash), "changed_states": changed_states, "changed_values": changed_values, "note": note}
    with TRAIN_AUDIT_LOG.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        if not exists: w.writeheader()
        w.writerow(row)


def append_decision_audit(cfg: Config, fields: Dict[str, object]) -> None:
    if not cfg.audit_enabled: return
    exists = DECISION_AUDIT_LOG.exists()
    keys = ["wall_time", "mode", "attempt", "probe", "state", "pick", "response", "best", "trend", "found_ramp", "ramp_pos", "epsilon", "exploration", "reason", "recommended_action", "chosen_action", "delta", "q_chosen_before", "prior_chosen", "score_chosen", "top_actions", "reward", "next_state", "q_chosen_after", "success_score", "policy_hash"]
    row = {"wall_time": time.strftime("%Y-%m-%d %H:%M:%S"), **fields}
    with DECISION_AUDIT_LOG.open("a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        if not exists: w.writeheader()
        w.writerow(row)


# ---------------------------
# Demo recorder
# ---------------------------

def observe(cfg: Config, model: QModel) -> None:
    print("\n=== OBSERVE / HUMAN DEMONSTRATION v0.6 ===")
    print("Play normally. F probes are recorded; Space closes the previous failed try and starts the next one.")
    print("SUCCESS closes an attempt as successful. Failed attempts are ALSO kept as training data.")
    print("F12 = stop recording. F10 = hold to pause.\n")

    vision, console_hwnd, _game_hwnd = prepare_live_vision(cfg, model, minimize=True)
    raw_samples: List[float] = []
    rows: List[Dict[str, object]] = []
    prev_f = False
    prev_space = False
    last_probe_pos: Optional[float] = None
    last_probe_raw: Optional[float] = None
    last_response = 0.0
    best_response = 0.0
    attempt_start = time.monotonic()
    last_ui_good = time.monotonic()
    episode_id = 1
    episode_start_idx = 0
    success_latched = False
    session_successes = 0
    session_failures = 0
    session_incomplete = 0

    def finalize_episode(status: str, now: float, success_score: float = 0.0, reason: str = "") -> bool:
        nonlocal episode_id, episode_start_idx, last_probe_pos, last_probe_raw
        nonlocal last_response, best_response, attempt_start
        nonlocal session_successes, session_failures, session_incomplete
        if len(rows) <= episode_start_idx:
            attempt_start = now
            last_probe_pos = None
            last_probe_raw = None
            last_response = 0.0
            best_response = 0.0
            return False
        code = 1 if status == "success" else (0 if status == "fail" else -1)
        elapsed = max(0.0, now - attempt_start)
        for j in range(episode_start_idx, len(rows)):
            rows[j]["episode_id"] = episode_id
            rows[j]["episode_success"] = code
            rows[j]["episode_status"] = status
            rows[j]["episode_elapsed"] = elapsed
            rows[j]["terminal"] = 1 if j == len(rows) - 1 else 0
            if status == "success" and j == len(rows) - 1:
                rows[j]["success_score"] = max(float(rows[j].get("success_score", 0.0)), float(success_score))
        n = len(rows) - episode_start_idx
        model.human_episodes += 1
        if status == "success":
            model.human_successes += 1
            session_successes += 1
            ep_rows = rows[episode_start_idx:]
            human_ramp = None
            for r in ep_rows:
                if float(r.get("response", 0.0)) >= cfg.wobble_threshold:
                    human_ramp = float(r.get("pick_pos", float("nan")))
                    break
            if human_ramp is not None and math.isnan(human_ramp):
                human_ramp = None
            open_pos = float(ep_rows[-1].get("pick_pos", float("nan")))
            if not math.isnan(open_pos):
                model.note_success(human_ramp, open_pos)
            save_success(ep_rows, {
                "source": "HUMAN", "elapsed": elapsed, "probes": n, "pick": open_pos,
                "ramp_pos": "" if human_ramp is None else human_ramp,
                "offset": "" if human_ramp is None or math.isnan(open_pos) else open_pos - human_ramp,
                "best": best_response, "score": success_score, "note": reason,
            })
            off = model.learned_offset()
            off_txt = f" | learned offset {off:+.3f} from {len(model.success_offsets)}" if off is not None else ""
            print(f"\nHUMAN SUCCESS | episode={episode_id} | t={elapsed:.2f}s | probes={n} | score={success_score:.3f}{off_txt}")
        elif status == "fail":
            model.human_failures += 1
            session_failures += 1
            print(f"\nHUMAN FAIL | episode={episode_id} | t={elapsed:.2f}s | probes={n}{(' | '+reason) if reason else ''}")
        else:
            model.human_incomplete += 1
            session_incomplete += 1
        episode_id += 1
        episode_start_idx = len(rows)
        last_probe_pos = None
        last_probe_raw = None
        last_response = 0.0
        best_response = 0.0
        attempt_start = now
        return True

    target_dt = 1.0 / max(5, cfg.fps)
    while True:
        loop = time.monotonic()
        if emergency_or_pause(cfg):
            break
        st = vision.state(keep_frame=cfg.debug_preview)
        if st.pick_raw is not None and st.pick_score > 2.0:
            raw_samples.append(st.pick_raw)

        # Space is the strongest failure/new-attempt boundary in this minigame.
        # Rising edge only: holding Space never creates duplicate episodes.
        space_now = key_down(cfg.space_key_vk)
        space_rising = space_now and not prev_space
        if cfg.observe_space_boundaries and space_rising and not success_latched:
            if len(rows) > episode_start_idx:
                finalize_episode("fail", loop, 0.0, "Space -> next attempt")
            else:
                attempt_start = loop
                last_probe_pos = None
                last_probe_raw = None
                last_response = 0.0
                best_response = 0.0
        prev_space = space_now

        # SUCCESS is authoritative. Latch so the same banner is counted once.
        if st.success_detected and not success_latched:
            finalize_episode("success", loop, st.success_score, "SUCCESS template")
            success_latched = True
        elif success_latched and st.success_score < cfg.success_threshold * 0.55:
            success_latched = False

        if st.ui_confidence > 0.12:
            last_ui_good = loop
        elif loop - last_ui_good > 0.80 and not success_latched:
            # Fallback if a game state change removes the UI without Space.
            if finalize_episode("fail", loop, 0.0, "lock UI disappeared"):
                last_ui_good = loop

        f_now = key_down(cfg.f_key_vk)
        rising = f_now and not prev_f
        if rising and st.pick_raw is not None and not success_latched:
            if len(rows) == episode_start_idx:
                attempt_start = loop
            response = st.progress
            success_peak = st.success_score
            end_window = time.monotonic() + cfg.response_window_ms / 1000.0
            while time.monotonic() < end_window and key_down(cfg.f_key_vk):
                rs = vision.state(keep_frame=False)
                response = max(response, rs.progress)
                success_peak = max(success_peak, rs.success_score)
                time.sleep(0.006)
            rows.append({
                "t": loop,
                "elapsed": loop - attempt_start,
                "pick_raw": float(st.pick_raw),
                "pick_pos": float(st.pick_pos) if st.pick_pos is not None else float("nan"),
                "response": float(response),
                "prev_response": float(last_response),
                "best_before": float(best_response),
                "prev_pick_raw": float(last_probe_raw) if last_probe_raw is not None else float("nan"),
                "prev_pick_pos": float(last_probe_pos) if last_probe_pos is not None else float("nan"),
                "episode_id": episode_id,
                "episode_success": -1,
                "episode_status": "recording",
                "episode_elapsed": float("nan"),
                "terminal": 0,
                "success_score": float(success_peak),
            })
            last_response = response
            best_response = max(best_response, response)
            last_probe_pos = st.pick_pos
            last_probe_raw = st.pick_raw
            print(f"probe {len(rows):4d} | ep={episode_id:3d} | raw={st.pick_raw:+.3f} | response={response:.3f} | best={best_response:.3f} | success={success_peak:.2f}", end="\r")
            if success_peak >= cfg.success_threshold and not success_latched:
                finalize_episode("success", time.monotonic(), success_peak, "SUCCESS during probe")
                success_latched = True
        prev_f = f_now
        if cfg.debug_preview:
            preview(vision, st, "Lockpick Learner - Observe")
        dt = time.monotonic() - loop
        if dt < target_dt:
            time.sleep(target_dt - dt)

    # F12 is not evidence that the current try failed.
    if len(rows) > episode_start_idx:
        finalize_episode("incomplete", time.monotonic(), 0.0, "F12 stop")

    if cfg.debug_preview:
        cv2.destroyAllWindows()
    if not rows:
        print("\nNo F probes recorded.")
        restore_console(console_hwnd)
        return

    if len(raw_samples) >= 20:
        left_raw = float(np.percentile(raw_samples, 2.0))
        right_raw = float(np.percentile(raw_samples, 98.0))
        if right_raw - left_raw > 0.15:
            vision.update_calibration(left_raw, right_raw)
            model.calibration.update(vision.cal)

    left = model.calibration.get("pick_left_raw")
    right = model.calibration.get("pick_right_raw")
    if left is not None and right is not None and right - left > 1e-5:
        for r in rows:
            r["pick_pos"] = float(np.clip((float(r["pick_raw"]) - left) / (right - left), 0, 1))
            try:
                prev_raw = float(r["prev_pick_raw"])
                if not math.isnan(prev_raw):
                    r["prev_pick_pos"] = float(np.clip((prev_raw - left) / (right - left), 0, 1))
            except Exception:
                pass

    tag = time.strftime('%Y%m%d_%H%M%S')
    path = DEMO_DIR / f"demo_{tag}.csv"
    fields = list(rows[0].keys())
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

    # Master demo contains EVERYTHING. Standalone archives make success/failure
    # examples inspectable and let us verify that failures are really retained.
    archive_map = {
        1: (SUCCESS_DEMO_DIR, "success"),
        0: (FAILED_DEMO_DIR, "fail"),
        -1: (INCOMPLETE_DEMO_DIR, "incomplete"),
    }
    archived = {1: 0, 0: 0, -1: 0}
    for ep in sorted({int(r["episode_id"]) for r in rows}):
        ep_rows = [r for r in rows if int(r["episode_id"]) == ep]
        if not ep_rows:
            continue
        code = int(float(ep_rows[-1].get("episode_success", -1)))
        dest, prefix = archive_map.get(code, (INCOMPLETE_DEMO_DIR, "incomplete"))
        ap = dest / f"{prefix}_{tag}_ep{ep:03d}.csv"
        with ap.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader()
            w.writerows(ep_rows)
        archived[code if code in archived else -1] += 1

    model.save()
    print(f"\nSaved {len(rows)} probes -> {path.name}")
    print(f"Episodes this recording: success={session_successes}, fail={session_failures}, incomplete={session_incomplete}")
    print(f"Archived: successful={archived[1]}, failed={archived[0]}, incomplete={archived[-1]}")
    if left is not None and right is not None:
        print(f"Learned visual search range: {left:+.3f} .. {right:+.3f}")
    print("TRAIN uses both wins and losses: wins strongly positive; losses as weaker positive/negative examples.")
    print("Next: run TRAIN, then AGENT. AGENT also keeps learning from its own attempts.")
    restore_console(console_hwnd)


# ---------------------------

def nearest_action(cfg: Config, delta: float) -> int:
    arr = np.asarray(cfg.action_steps)
    return int(np.argmin(np.abs(arr - delta)))


def train_from_demos(cfg: Config, model: QModel) -> None:
    files = sorted(DEMO_DIR.glob("demo_*.csv"))
    if not files:
        print("No demonstrations found. Run OBSERVE first.")
        return

    before_hash = model.policy_hash()
    before_prior = {k: list(v) for k, v in model.demo_prior.items()}
    before_snap = snapshot_model(model, "before_human_train") if cfg.audit_enabled else None
    scores: Dict[str, np.ndarray] = {}
    used_positive = 0
    used_negative = 0
    skipped = 0
    success_eps = 0
    fail_eps = 0
    mixed_eps = 0
    unknown_eps = 0

    def split_episodes(rows: List[Dict[str, str]]) -> List[Tuple[int, List[Dict[str, str]]]]:
        if rows and "episode_id" in rows[0]:
            grouped: Dict[int, List[Dict[str, str]]] = {}
            for r in rows:
                try:
                    eid = int(float(r.get("episode_id", 0) or 0))
                except Exception:
                    eid = 0
                grouped.setdefault(eid, []).append(r)
            return sorted(grouped.items(), key=lambda kv: kv[0])
        out: List[Tuple[int, List[Dict[str, str]]]] = []
        cur: List[Dict[str, str]] = []
        eid = 1
        prev_elapsed = -1.0
        for r in rows:
            try:
                e = float(r.get("elapsed", 0.0))
            except Exception:
                e = 0.0
            if cur and e + 0.20 < prev_elapsed:
                out.append((eid, cur)); eid += 1; cur = []
            cur.append(r); prev_elapsed = e
        if cur:
            out.append((eid, cur))
        return out

    for path in files:
        with path.open("r", newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        for _eid, ep in split_episodes(rows):
            if len(ep) < 2:
                skipped += len(ep)
                continue
            try:
                status = int(float(ep[-1].get("episode_success", -1))) if "episode_success" in ep[-1] else -1
            except Exception:
                status = -1
            try:
                ep_elapsed = float(ep[-1].get("episode_elapsed", ep[-1].get("elapsed", 0.0)) or 0.0)
            except Exception:
                ep_elapsed = 0.0

            # v0.4 did not watch Space. A 40-160 second "success" is clearly a
            # bundle of many retries ending in one win, so it must NOT get the
            # same gold weight as a clean 2-4 second success.
            mixed_legacy = bool(status == 1 and (ep_elapsed > cfg.legacy_mixed_max_seconds or len(ep) > cfg.legacy_mixed_max_probes))
            if mixed_legacy:
                mixed_eps += 1
                effective_status = -2
            elif status == 1:
                success_eps += 1
                effective_status = 1
            elif status == 0:
                fail_eps += 1
                effective_status = 0
            else:
                unknown_eps += 1
                effective_status = -1

            # The state is measured from the ramp, so find this episode's ramp
            # first: the first probe where the human made the lock answer.
            cal_left = model.calibration.get("pick_left_raw")
            cal_right = model.calibration.get("pick_right_raw")

            def demo_pos(row: Dict[str, str]) -> float:
                try:
                    if cal_left is not None and cal_right is not None and cal_right - cal_left > 1e-5:
                        return float(np.clip((float(row["pick_raw"]) - cal_left) / (cal_right - cal_left), 0.0, 1.0))
                    return float(row["pick_pos"])
                except Exception:
                    return float("nan")

            ep_ramp = None
            for row in ep:
                try:
                    if float(row["response"]) >= cfg.wobble_threshold:
                        cand = demo_pos(row)
                        ep_ramp = None if math.isnan(cand) else cand
                        break
                except Exception:
                    continue

            for i in range(1, len(ep)):
                cur = ep[i]
                prev = ep[i - 1]
                try:
                    p0 = demo_pos(prev)
                    p1 = demo_pos(cur)
                    r0 = float(prev["response"])
                    r1 = float(cur["response"])
                    best0 = float(prev["best_before"])
                    prev_r0 = float(prev["prev_response"])
                    if any(math.isnan(v) for v in (p0, p1, r0, r1, best0, prev_r0)):
                        skipped += 1
                        continue
                    delta = p1 - p0
                    if abs(delta) > 0.38:
                        # Usually a reset/new attempt in legacy data, not a real
                        # within-attempt action. v0.4 catches Space explicitly.
                        skipped += 1
                        continue
                    trend = 1 if r0 > prev_r0 + 0.015 else (-1 if r0 + 0.015 < prev_r0 else 0)
                    found = r0 >= cfg.wobble_threshold or best0 >= cfg.wobble_threshold
                    key = model.state_key(p0, r0, max(best0, r0), trend, found, ep_ramp)
                    a = nearest_action(cfg, delta)
                    if key not in scores:
                        scores[key] = np.zeros(len(cfg.action_steps), dtype=np.float64)

                    improvement = r1 - r0
                    frac = i / max(1, len(ep) - 1)
                    terminal = i == len(ep) - 1

                    if effective_status == 1:
                        # Clean success: strongest source. The target-localizing
                        # tail is weighted especially heavily.
                        quality = 1.0 + 3.0 * max(0.0, r1) + 7.0 * max(0.0, improvement)
                        tail = 1.0 + 2.5 * (frac ** 2)
                        weight = cfg.demo_success_multiplier * quality * tail
                        scores[key][a] += weight
                        used_positive += 1
                    elif effective_status == 0:
                        # Failed human attempts are retained as REAL training data.
                        # Helpful local moves get a small positive vote; degrading
                        # moves and the terminal failure action get a negative vote.
                        helpful = improvement > 0.010 or (r0 < cfg.wobble_threshold and delta > 0.0) or (r1 >= cfg.wobble_threshold and improvement >= -0.01)
                        if helpful:
                            weight = cfg.demo_failed_helpful_multiplier * (1.0 + 2.0 * max(0.0, r1) + 4.0 * max(0.0, improvement))
                            scores[key][a] += weight
                            used_positive += 1
                        else:
                            harm = max(0.0, -improvement)
                            penalty = cfg.demo_failed_negative_multiplier * (1.0 + 5.0 * harm + (1.5 if terminal else 0.0))
                            scores[key][a] -= penalty
                            used_negative += 1
                    elif effective_status == -2:
                        # Mixed v0.4 legacy episode: useful local gradients remain,
                        # but the eventual SUCCESS cannot be credited to the whole
                        # 40-160 second chain.
                        if improvement > 0.012:
                            scores[key][a] += 0.45 * (1.0 + 3.0 * improvement + max(0.0, r1))
                            used_positive += 1
                        elif improvement < -0.03:
                            scores[key][a] -= 0.20 * (1.0 + 3.0 * (-improvement))
                            used_negative += 1
                        else:
                            skipped += 1
                    else:
                        # Incomplete/old unknown data contributes only weak local
                        # information and can never dominate labelled episodes.
                        if improvement > 0.015:
                            scores[key][a] += 0.25 * (1.0 + 2.0 * improvement)
                            used_positive += 1
                        elif improvement < -0.05:
                            scores[key][a] -= 0.12 * (1.0 + 2.0 * (-improvement))
                            used_negative += 1
                        else:
                            skipped += 1
                except Exception:
                    skipped += 1

    priors: Dict[str, List[float]] = {}
    for key, sc in scores.items():
        if not np.any(np.abs(sc) > 1e-12):
            continue
        # Convert signed evidence into relative action logits. Best action = 0;
        # bad actions become negative. Clamp keeps one demo from overwhelming Q.
        rel = sc - np.max(sc)
        nonzero = np.abs(rel[np.abs(rel) > 1e-9])
        scale = float(np.median(nonzero)) if nonzero.size else 1.0
        scale = max(0.75, scale)
        prior = np.clip(rel / scale, -7.0, 0.0)
        priors[key] = prior.tolist()

    model.demo_prior = priors
    model.save()
    after_hash = model.policy_hash()
    changed_states, changed_values = _count_policy_changes(before_prior, model.demo_prior)
    after_snap = snapshot_model(model, "after_human_train") if cfg.audit_enabled else None
    if cfg.audit_enabled:
        append_training_audit("human_train", before_hash, after_hash, changed_states, changed_values, f"positive={used_positive}; negative={used_negative}; skipped={skipped}")
    print(f"Training complete: +{used_positive} positive and -{used_negative} negative human examples, {len(priors)} learned states, {skipped} neutral/skipped.")
    print(f"AUDIT: policy hash {before_hash[:12]} -> {after_hash[:12]} | changed states={changed_states}, values={changed_values}")
    if before_snap and after_snap:
        print(f"AUDIT snapshots: {before_snap.name} / {after_snap.name}")
    print(f"Episodes classified by TRAIN: clean success={success_eps}, failed={fail_eps}, v0.3 mixed legacy={mixed_eps}, incomplete/unknown={unknown_eps}.")
    if success_eps:
        print("Clean successes get the strongest imitation weight. Failed attempts still train the model: useful moves vote up, harmful/final-fail moves vote down.")
    if mixed_eps:
        print("[MIGRATION] Long v0.4 SUCCESS episodes were automatically demoted because they likely contain several retries blended together.")
    if not success_eps:
        print("[NOTE] No clean SUCCESS-labelled human episode yet. OBSERVE and open at least one lock.")


# ---------------------------
# Persistent autonomous self-play replay
# ---------------------------

def archive_selfplay_episode(rows: List[Dict[str, object]], success: bool, total_reward: float, elapsed: float) -> Optional[Path]:
    if not rows:
        return None
    stamp = time.strftime('%Y%m%d_%H%M%S') + f"_{int((time.time()%1)*1000):03d}"
    dest = SELFPLAY_SUCCESS_DIR if success else SELFPLAY_FAILED_DIR
    path = dest / f"self_{'success' if success else 'fail'}_{stamp}.csv"
    fields = ["state", "action", "delta", "reward", "next_state", "terminal", "episode_success", "elapsed", "pick", "response", "best", "episode_total_reward"]
    cooked = []
    for i, r in enumerate(rows):
        rr = dict(r)
        rr["terminal"] = 1 if i == len(rows)-1 else int(rr.get("terminal", 0) or 0)
        rr["episode_success"] = 1 if success else 0
        rr["episode_total_reward"] = float(total_reward)
        cooked.append(rr)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader(); w.writerows(cooked)
    return path


def replay_episode_rows(cfg: Config, model: QModel, rows: List[Dict[str, str]], passes: int) -> int:
    updates = 0
    if not rows:
        return 0
    for _ in range(max(0, int(passes))):
        # Reverse replay propagates terminal success/failure back through the
        # short lockpick trajectory faster than forward-only replay.
        for r in reversed(rows):
            try:
                key = str(r["state"])
                # The action list can change between versions, so an index from
                # an old file may now mean a different move. The stored delta
                # always means the same thing, so trust that and re-derive.
                action = int(float(r["action"]))
                try:
                    delta = float(r.get("delta", "nan"))
                    if not math.isnan(delta):
                        action = nearest_action(cfg, delta)
                except Exception:
                    pass
                if not (0 <= action < len(cfg.action_steps)):
                    continue
                reward = float(r["reward"])
                next_key = str(r.get("next_state", key))
                terminal = int(float(r.get("terminal", 0) or 0)) == 1
                if terminal:
                    model.replay_terminal_update(key, action, reward)
                else:
                    model.replay_update(key, action, reward, next_key)
                updates += 1
            except Exception:
                continue
    return updates


def self_train_from_history(cfg: Config, model: QModel) -> None:
    success_files = sorted(SELFPLAY_SUCCESS_DIR.glob("self_success_*.csv"))
    fail_files = sorted(SELFPLAY_FAILED_DIR.glob("self_fail_*.csv"))
    if not success_files and not fail_files:
        print("No autonomous self-play history yet. Run AGENT first.")
        return
    before_hash = model.policy_hash()
    before_q = {k: list(v) for k, v in model.q.items()}
    before_snap = snapshot_model(model, "before_self_train") if cfg.audit_enabled else None
    updates = 0
    transitions = 0
    for success, files, passes in (
        (True, success_files, cfg.selfplay_success_replay_passes),
        (False, fail_files, cfg.selfplay_fail_replay_passes),
    ):
        for path in files:
            with path.open("r", newline="", encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
            transitions += len(rows)
            updates += replay_episode_rows(cfg, model, rows, passes)
    model.save()
    after_hash = model.policy_hash()
    changed_states, changed_values = _count_policy_changes(before_q, model.q)
    after_snap = snapshot_model(model, "after_self_train") if cfg.audit_enabled else None
    if cfg.audit_enabled:
        append_training_audit("self_train", before_hash, after_hash, changed_states, changed_values, f"episodes_success={len(success_files)}; episodes_fail={len(fail_files)}; replay_updates={updates}")
    print(f"SELF TRAIN complete: {len(success_files)} successful + {len(fail_files)} failed autonomous episodes, {transitions} stored transitions, {updates} replay Q-updates.")
    print(f"Successes replay x{cfg.selfplay_success_replay_passes}; failures replay x{cfg.selfplay_fail_replay_passes}. Live AGENT learning remains active too.")
    print(f"AUDIT: policy hash {before_hash[:12]} -> {after_hash[:12]} | changed states={changed_states}, values={changed_values}")
    if before_snap and after_snap:
        print(f"AUDIT snapshots: {before_snap.name} / {after_snap.name}")


# ---------------------------
# Calibration + closed-loop movement
# ---------------------------

def auto_calibrate(cfg: Config, model: QModel, vision: ScreenVision) -> bool:
    print("Auto-calibration: detected game monitor is active. Do not touch the mouse for ~3 seconds.")

    def endpoint_pair() -> Tuple[Optional[float], Optional[float]]:
        move_mouse_relative(-5000, 0)
        time.sleep(0.30)
        s_left = vision.state()
        move_mouse_relative(10000, 0)
        time.sleep(0.38)
        s_right = vision.state()
        return s_left.pick_raw, s_right.pick_raw

    started_for_calibration = False
    left, right = endpoint_pair()
    if left is None or right is None:
        print("Could not see the pick endpoints on the detected monitor.")
        return False
    lo, hi = (left, right) if right >= left else (right, left)

    # Some SCUM-like implementations do not accept mouse movement until the
    # timed attempt has been started. If so, start it ourselves and retry once.
    if hi - lo < 0.55 and cfg.auto_press_space:
        print(f"Endpoint movement was only {hi-lo:.3f}; pressing Space and retrying calibration...")
        send_key(cfg.space_key_vk, 28)
        time.sleep(max(0.18, cfg.start_wait_seconds))
        started_for_calibration = True
        left, right = endpoint_pair()
        if left is None or right is None:
            print("Could not see the pick after starting the attempt.")
            return False
        lo, hi = (left, right) if right >= left else (right, left)

    left, right = lo, hi
    if right - left < 0.55:
        print(f"Calibration range still too small ({right-left:.3f}). The lock UI/pick detector is not locked on yet.")
        return False

    vision.update_calibration(left, right)
    model.calibration.update(vision.cal)

    # Estimate relative mouse counts per normalized position with a small visual movement.
    move_mouse_relative(-5000, 0)
    time.sleep(0.22)
    base = vision.state()
    gain = None
    for trial in (30, 60, 100, 160, 240):
        move_mouse_relative(trial, 0)
        time.sleep(0.11)
        now = vision.state()
        if base.pick_pos is not None and now.pick_pos is not None:
            d = now.pick_pos - base.pick_pos
            if d > 0.025:
                gain = float(trial / d)
                break
        move_mouse_relative(-5000, 0)
        time.sleep(0.12)
        base = vision.state()
    if gain is None:
        gain = 900.0
    model.calibration["mouse_counts_per_norm"] = float(np.clip(gain, 120.0, 6000.0))
    model.calibration["monitor_index"] = float(vision.monitor_index)
    model.calibration["monitor_width"] = float(vision.width)
    model.calibration["monitor_height"] = float(vision.height)
    model.calibration["vision_version"] = 2.0
    model.save()
    move_mouse_relative(-5000, 0)
    time.sleep(0.18)
    print(f"Calibration OK: visual range {left:+.3f}..{right:+.3f}, gain ~{model.calibration['mouse_counts_per_norm']:.0f} counts/full-range.")
    if started_for_calibration:
        # Let the sacrificial calibration attempt expire/reset so AGENT begins
        # with a clean Space press and a fresh timer.
        time.sleep(max(0.2, cfg.attempt_budget_seconds + cfg.restart_wait_seconds))
    return True


def move_to(vision: ScreenVision, model: QModel, target: float, cfg: Config) -> Optional[float]:
    """Put the pick at target.

    One proportional move sent as a few back-to-back chunks, then at most a
    couple of verify-and-correct rounds. The previous version read the screen
    between every 140-count nudge, which made a big move impossible and a
    small one slow.
    """
    target = float(np.clip(target, 0.0, 1.0))
    gain = float(model.calibration.get("mouse_counts_per_norm", 6000.0))
    chunk = max(60, int(cfg.move_chunk_counts))

    st = vision.state(keep_frame=cfg.debug_preview)
    if cfg.debug_preview:
        preview(vision, st, "Lockpick Learner - Agent")
    pos = st.pick_pos
    if pos is None:
        time.sleep(0.02)
        st = vision.state()
        pos = st.pick_pos
        if pos is None:
            return None

    for round_no in range(int(cfg.move_max_corrections) + 1):
        err = target - pos
        if abs(err) <= cfg.move_tolerance:
            return pos
        if emergency_or_pause(cfg):
            return None
        # Slight undershoot on the first move so a calibration that reads a
        # little high cannot slam the pick into the far wall.
        counts = int(round(err * gain * (0.94 if round_no == 0 else 1.0)))
        jaljella = abs(counts)
        merkki = 1 if counts > 0 else -1
        while jaljella > 0:
            askel = min(chunk, jaljella)
            move_mouse_relative(merkki * askel, 0)
            jaljella -= askel
            if jaljella > 0:
                time.sleep(0.004)
        time.sleep(cfg.move_settle_ms / 1000.0)
        st = vision.state(keep_frame=cfg.debug_preview)
        if cfg.debug_preview:
            preview(vision, st, "Lockpick Learner - Agent")
        if st.pick_pos is not None:
            pos = st.pick_pos
    return pos


def probe_response(vision: ScreenVision, cfg: Config, hold_ms: Optional[int] = None) -> Tuple[float, float, float]:
    """Press F once at the current position and read what the lock did.

    hold_ms lets the caller press longer. While searching, the press is a light
    tap: it only has to reveal whether the lock answers here. Once refining, the
    press is the full finishing hold, because that is what actually opens the
    lock - and it is still ONE press per probe, not two.
    """
    before = vision.state()
    base = before.progress
    success_peak = before.success_score
    send_key(cfg.f_key_vk, int(hold_ms if hold_ms is not None else cfg.probe_hold_ms))
    alku = time.monotonic()
    end = alku + cfg.response_window_ms / 1000.0
    peak = base
    ui = before.ui_confidence
    viimeksi_nousi = alku
    while time.monotonic() < end:
        st = vision.state(keep_frame=cfg.debug_preview)
        if st.progress > peak + 0.004:
            viimeksi_nousi = time.monotonic()
        peak = max(peak, st.progress)
        ui = st.ui_confidence
        success_peak = max(success_peak, st.success_score)
        if cfg.debug_preview:
            preview(vision, st, "Lockpick Learner - Agent")
        nyt = time.monotonic()
        # Once the reading has stopped climbing there is nothing more to see,
        # so give the time back to the attempt instead of waiting it out.
        if (nyt - alku) * 1000.0 >= cfg.response_min_ms and (nyt - viimeksi_nousi) * 1000.0 >= cfg.response_settle_ms:
            break
    # Normalize out tiny baseline orientation error.
    response = float(np.clip(peak - min(base, 0.055), 0.0, 1.0))
    return response, ui, float(success_peak)


def wait_success_text(vision: ScreenVision, cfg: Config, ms: Optional[int] = None) -> float:
    """Watch briefly for the SUCCESS banner after an F action."""
    deadline = time.monotonic() + (int(ms or cfg.success_confirm_wait_ms) / 1000.0)
    best = 0.0
    while time.monotonic() < deadline:
        st = vision.state(keep_frame=cfg.debug_preview)
        best = max(best, st.success_score)
        if st.success_detected:
            return max(best, st.success_score)
        if cfg.debug_preview:
            preview(vision, st, "Lockpick Learner - Agent")
        time.sleep(0.012)
    return float(best)


# ---------------------------
# Autonomous agent
# ---------------------------

def agent(cfg: Config, model: QModel, learning: bool = True, deterministic: bool = False, max_attempts: Optional[int] = None, run_mode: str = "AGENT") -> None:
    if not IS_WINDOWS:
        print("AGENT mode needs Windows because it uses SendInput/GetAsyncKeyState.")
        return
    print(f"\n=== {run_mode} v0.6 ===")
    print("F12 = EMERGENCY STOP. Hold F10 = pause.")
    if learning:
        print("LEARNING=ON: online Q updates + self-play replay. Every model decision is auditable.")
        print(f"Automatic replay emphasis: success x{cfg.selfplay_success_replay_passes}, fail x{cfg.selfplay_fail_replay_passes}.\n")
    else:
        print("EVALUATION=ON: deterministic policy, epsilon=0, NO learning/replay/model mutation.\n")

    vision, console_hwnd, game_hwnd = prepare_live_vision(cfg, model, minimize=True)
    if not calibration_valid(model, vision):
        print("Calibration missing/stale -> calibrating on the detected game monitor.")
        if not auto_calibrate(cfg, model, vision):
            restore_console(console_hwnd)
            return
    vision.cal.update(model.calibration)
    if cfg.auto_focus_game_window and game_hwnd:
        focus_window(game_hwnd, wait=0.16)

    rewarder = RewardEngine(cfg)
    attempt_no = 0
    while True:
        if emergency_or_pause(cfg):
            break
        attempt_no += 1
        if max_attempts is not None and attempt_no > max_attempts:
            break
        if learning:
            model.total_attempts += 1
            model.selfplay_episodes += 1
        print(f"\n--- attempt {attempt_no}{' [EVAL]' if not learning else ''} ---")

        if cfg.auto_press_space:
            send_key(cfg.space_key_vk, 28)
            time.sleep(cfg.start_wait_seconds)

        move_mouse_relative(-5000, 0)
        time.sleep(0.16)
        st0 = vision.state(keep_frame=cfg.debug_preview)
        if st0.pick_pos is None:
            print("Pick not detected. Waiting/retrying; F12 stops.")
            time.sleep(0.35)
            continue

        start = time.monotonic()
        pos = st0.pick_pos
        prev_response = 0.0
        best = 0.0
        found_ramp = False
        ramp_hits = 0              # probes that agreed the lock moved
        ramp_pos = None            # where the lock first answered
        offset_used = False        # learned ramp -> opening jump spent?
        last_probe_time = start    # for the per-probe time cost
        grid = [(i + 0.5) / cfg.search_cells for i in range(cfg.search_cells)]
        grid_i = 0                 # next coarse cell to visit
        refining = False
        best_pos = pos             # best position seen this attempt
        refine_step = 1.0 / (2 * cfg.search_cells)
        last_key = None
        last_action = None
        total_reward = 0.0
        success = False
        probe_no = 0
        episode_rows: List[Dict[str, object]] = []

        def finish_episode_record(success_flag: bool) -> None:
            nonlocal episode_rows
            if not episode_rows:
                return
            elapsed_now = time.monotonic() - start
            terminal_extra = rewarder.success(elapsed_now) if success_flag else cfg.reward.fail_penalty
            episode_rows[-1]["reward"] = float(episode_rows[-1].get("reward", 0.0)) + terminal_extra
            episode_rows[-1]["terminal"] = 1
            if learning:
                path = archive_selfplay_episode(episode_rows, success_flag, total_reward, elapsed_now)
                passes = cfg.selfplay_success_replay_passes if success_flag else cfg.selfplay_fail_replay_passes
                replay_rows = [{k: str(v) for k, v in r.items()} for r in episode_rows]
                replay_episode_rows(cfg, model, replay_rows, passes)
                if path:
                    print(f"self-play saved: {path.parent.name}\\{path.name}")
            else:
                path = archive_evaluation_episode(episode_rows, success_flag, total_reward, elapsed_now)
                if path:
                    print(f"evaluation saved: {path.parent.name}\\{path.name}")

        def credit_success(text_score: float, note: str) -> None:
            nonlocal success, total_reward
            if success:
                return
            elapsed_now = time.monotonic() - start
            bonus = rewarder.success(elapsed_now)
            total_reward += bonus
            if learning and last_key is not None and last_action is not None:
                model.terminal_update(last_key, last_action, bonus)
            append_event("success", {"elapsed": elapsed_now, "pick": pos, "response": response, "best": best, "reward": total_reward, "success": 1, "note": f"SUCCESS {text_score:.3f}; {note}"})
            # Everything worth keeping from an attempt that actually opened.
            if learning:
                model.note_success(ramp_pos, pos)
                save_success(episode_rows, {
                    "source": run_mode, "elapsed": elapsed_now, "probes": probe_no, "pick": pos,
                    "ramp_pos": ramp_pos, "offset": (pos - ramp_pos) if ramp_pos is not None else "",
                    "best": best, "reward": total_reward, "score": text_score, "note": note,
                })
            off = model.learned_offset()
            off_txt = f" | learned offset {off:+.3f} from {len(model.success_offsets)}" if off is not None else ""
            print(f"\nSUCCESS CONFIRMED in {elapsed_now:.2f}s | probes={probe_no} | score={text_score:.3f} | reward={total_reward:.1f}{off_txt}")
            if learning:
                model.total_successes += 1
                model.selfplay_successes += 1
            success = True

        response, _ui, success_score = probe_response(vision, cfg)
        probe_no += 1
        elapsed = time.monotonic() - start
        rwd = rewarder.step(response, prev_response, best, elapsed - (last_probe_time - start))
        last_probe_time = time.monotonic()
        total_reward += rwd
        best = max(best, response)
        best_pos = pos
        prev_response = response
        if response >= cfg.wobble_threshold:
            ramp_hits += 1
            if ramp_pos is None:
                ramp_pos = pos
        found_ramp = ramp_hits >= cfg.wobble_confirm_probes
        if success_score >= cfg.success_threshold:
            credit_success(success_score, "first probe")

        while not success and elapsed < cfg.attempt_budget_seconds + 0.45:
            if emergency_or_pause(cfg):
                model.save()
                if cfg.debug_preview:
                    cv2.destroyAllWindows()
                restore_console(console_hwnd)
                return

            if best >= cfg.success_progress:
                send_key(cfg.f_key_vk, cfg.finish_hold_ms)
                text_score = wait_success_text(vision, cfg)
                elapsed = time.monotonic() - start
                if text_score >= cfg.success_threshold:
                    credit_success(text_score, "finish hold")
                    break

            if response > prev_response + 0.018:
                trend = 1
            elif response + 0.018 < prev_response:
                trend = -1
            else:
                trend = 0
            key = model.state_key(pos, response, best, trend, found_ramp, ramp_pos)
            decision = model.decision_details(key, deterministic=(deterministic or not learning))
            recommended_action = int(decision["action"])
            action = recommended_action
            delta = cfg.action_steps[action]
            decision_reason = str(decision["reason"])

            # The model's own preference decides which side to try first while
            # refining; the structure below decides how far. The old version let
            # the model pick freely and then clamped everything to +/-0.04, which
            # covered 4% of the lock per attempt and never found anything.
            learned = model.learned_offset()
            if learned is not None and not offset_used and found_ramp and ramp_pos is not None:
                # Past successes say the lock opens about this far past the ramp.
                target = float(np.clip(ramp_pos + learned, 0.0, 1.0))
                offset_used = True
                refining = True
                decision_reason += "+learned_offset_jump"
            elif not refining and grid_i < len(grid):
                # Coarse pass: cover the whole lock evenly, no creeping.
                target = grid[grid_i]
                grid_i += 1
                decision_reason += f"+coarse{grid_i}/{len(grid)}"
            else:
                # Refine: step out from the best cell, on the side the model
                # prefers, halving the step whenever a side stops paying.
                refining = True
                suunta = -1.0 if delta < 0 else 1.0
                target = float(np.clip(best_pos + suunta * refine_step, 0.0, 1.0))
                if abs(target - pos) < 1e-4:
                    target = float(np.clip(best_pos - suunta * refine_step, 0.0, 1.0))
                decision_reason += "+refine"
            delta = target - pos
            action = nearest_action(cfg, delta)
            moved = move_to(vision, model, target, cfg)
            if moved is None:
                break
            pos = moved
            prev_before_probe = response
            response, ui_conf, success_score = probe_response(
                vision, cfg, cfg.finish_hold_ms if refining else cfg.probe_hold_ms)
            probe_no += 1
            now = time.monotonic()
            elapsed = now - start
            step_reward = rewarder.step(response, prev_before_probe, best, now - last_probe_time)
            last_probe_time = now
            total_reward += step_reward
            if response > best:
                best = response
                best_pos = pos
            elif refining:
                # That side did not pay, so look closer next time.
                refine_step = max(cfg.ramp_microstep, refine_step * 0.5)

            if response >= cfg.wobble_threshold:
                ramp_hits += 1
                if ramp_pos is None:
                    ramp_pos = pos
            next_found = ramp_hits >= cfg.wobble_confirm_probes
            next_trend = 1 if response > prev_before_probe + 0.018 else (-1 if response + 0.018 < prev_before_probe else 0)
            next_key = model.state_key(pos, response, best, next_trend, next_found, ramp_pos)
            if learning:
                q_before = float(model.ensure(key)[action])
                _qbefore, q_after = model.update(key, action, step_reward, next_key)
            else:
                q_before = float(model.q.get(key, [0.0] * len(cfg.action_steps))[action])
                q_after = q_before
            last_key, last_action = key, action
            final_prior = model.demo_prior.get(key, [0.0] * len(cfg.action_steps))
            final_score = q_before + cfg.imitation_weight * float(final_prior[action])
            append_decision_audit(cfg, {
                "mode": run_mode, "attempt": attempt_no, "probe": probe_no, "state": key,
                "pick": pos, "response": prev_before_probe, "best": best, "trend": trend, "found_ramp": int(found_ramp),
                "ramp_pos": "" if ramp_pos is None else round(float(ramp_pos), 4),
                "epsilon": 0.0 if not learning else model.epsilon, "exploration": int(bool(decision["exploration"])),
                "reason": decision_reason, "recommended_action": recommended_action, "chosen_action": action,
                "delta": delta, "q_chosen_before": q_before, "prior_chosen": float(final_prior[action]),
                "score_chosen": final_score, "top_actions": json.dumps(decision["top"], separators=(",", ":")),
                "reward": step_reward, "next_state": next_key, "q_chosen_after": q_after,
                "success_score": success_score, "policy_hash": model.policy_hash(),
            })
            episode_rows.append({
                "state": key,
                "action": action,
                "delta": delta,
                "reward": step_reward,
                "next_state": next_key,
                "terminal": 0,
                "elapsed": elapsed,
                "pick": pos,
                "response": response,
                "best": best,
            })
            append_event("probe", {"elapsed": elapsed, "pick": pos, "response": response, "best": best, "reward": step_reward, "success": 0, "note": f"successScore={success_score:.3f}"})
            src = "EXPLORE" if decision["exploration"] else ("OVERRIDE" if action != recommended_action else "LEARNED")
            shown_eps = 0.0 if not learning else model.epsilon
            print(f"p={pos:.3f} response={response:.3f} best={best:.3f} r={step_reward:+.2f} eps={shown_eps:.3f} src={src:<8} a={action:02d} d={delta:+.3f} success={success_score:.2f}", end="\r")

            if success_score >= cfg.success_threshold:
                credit_success(success_score, "probe response")
                break

            prev_response = prev_before_probe
            found_ramp = next_found

            if ui_conf < 0.045 and elapsed > 0.45 and best < cfg.success_progress:
                late = wait_success_text(vision, cfg, ms=180)
                if late >= cfg.success_threshold:
                    credit_success(late, "late UI transition")
                break

        if not success:
            late = wait_success_text(vision, cfg, ms=180)
            if late >= cfg.success_threshold:
                credit_success(late, "deadline confirmation")

        if not success:
            elapsed = time.monotonic() - start
            total_reward += cfg.reward.fail_penalty
            if learning and last_key is not None and last_action is not None:
                model.terminal_update(last_key, last_action, cfg.reward.fail_penalty)
            append_event("fail", {"elapsed": elapsed, "pick": pos, "response": response, "best": best, "reward": total_reward, "success": 0})
            print(f"\nFAIL/reset | t={elapsed:.2f}s | best={best:.3f} | total reward={total_reward:.1f}")
            if learning:
                model.selfplay_failures += 1

        finish_episode_record(success)
        if learning:
            model.save()
        time.sleep(cfg.restart_wait_seconds)

    if cfg.debug_preview:
        cv2.destroyAllWindows()
    if learning:
        model.save()
    restore_console(console_hwnd)


# ---------------------------
# Evaluation + auditable verification
# ---------------------------

def archive_evaluation_episode(rows: List[Dict[str, object]], success: bool, total_reward: float, elapsed: float) -> Optional[Path]:
    if not rows:
        return None
    stamp = time.strftime('%Y%m%d_%H%M%S') + f"_{int((time.time()%1)*1000):03d}"
    dest = EVAL_SUCCESS_DIR if success else EVAL_FAILED_DIR
    path = dest / f"eval_{'success' if success else 'fail'}_{stamp}.csv"
    fields = ["state", "action", "delta", "reward", "next_state", "terminal", "episode_success", "elapsed", "pick", "response", "best", "episode_total_reward"]
    cooked = []
    for i, r in enumerate(rows):
        rr = dict(r)
        rr["terminal"] = 1 if i == len(rows)-1 else int(rr.get("terminal", 0) or 0)
        rr["episode_success"] = 1 if success else 0
        rr["episode_total_reward"] = float(total_reward)
        cooked.append(rr)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader(); w.writerows(cooked)
    return path


def evaluate_agent(cfg: Config, model: QModel) -> None:
    raw = input(f"How many deterministic evaluation attempts? [{cfg.evaluation_default_attempts}]: ").strip()
    try:
        n = int(raw) if raw else int(cfg.evaluation_default_attempts)
    except Exception:
        n = int(cfg.evaluation_default_attempts)
    n = max(1, min(5000, n))
    before = model.policy_hash(); eps_before = model.epsilon; updates_before = model.total_updates
    agent(cfg, model, learning=False, deterministic=True, max_attempts=n, run_mode="EVALUATION")
    after = model.policy_hash()
    print(f"\nEVALUATION mutation check: policy hash {before[:12]} -> {after[:12]} | Q updates {updates_before} -> {model.total_updates} | epsilon {eps_before:.4f} -> {model.epsilon:.4f}")
    if before == after and updates_before == model.total_updates and abs(eps_before-model.epsilon) < 1e-12:
        print("PASS: evaluation used the learned policy without training or mutating it.")
    else:
        print("FAIL: evaluation unexpectedly changed model state. Do not use this run as a clean benchmark.")


def _demo_transition_records(cfg: Config, model: QModel) -> List[Dict[str, object]]:
    records: List[Dict[str, object]] = []
    for path in sorted(DEMO_DIR.glob("demo_*.csv")):
        try:
            with path.open("r", newline="", encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
            grouped: Dict[int, List[Dict[str, str]]] = {}
            for r in rows:
                try: eid = int(float(r.get("episode_id", 0) or 0))
                except Exception: eid = 0
                grouped.setdefault(eid, []).append(r)
            for _eid, ep in grouped.items():
                if len(ep) < 2: continue
                try: status = int(float(ep[-1].get("episode_success", -1) or -1))
                except Exception: status = -1
                try: ep_elapsed = float(ep[-1].get("episode_elapsed", ep[-1].get("elapsed", 0.0)) or 0.0)
                except Exception: ep_elapsed = 0.0
                clean_success = status == 1 and ep_elapsed <= cfg.legacy_mixed_max_seconds and len(ep) <= cfg.legacy_mixed_max_probes
                ep_ramp = None
                for row in ep:
                    try:
                        if float(row["response"]) >= cfg.wobble_threshold:
                            ep_ramp = float(row["pick_pos"])
                            break
                    except Exception:
                        continue
                if ep_ramp is not None and math.isnan(ep_ramp):
                    ep_ramp = None
                for i in range(1, len(ep)):
                    prev, cur = ep[i-1], ep[i]
                    try:
                        p0,p1 = float(prev["pick_pos"]),float(cur["pick_pos"])
                        r0,r1 = float(prev["response"]),float(cur["response"])
                        b0,pr0 = float(prev["best_before"]),float(prev["prev_response"])
                        if any(math.isnan(v) for v in (p0,p1,r0,r1,b0,pr0)): continue
                        delta=p1-p0
                        if abs(delta)>0.38: continue
                        trend=1 if r0>pr0+0.015 else (-1 if r0+0.015<pr0 else 0)
                        found=r0>=cfg.wobble_threshold or b0>=cfg.wobble_threshold
                        key=model.state_key(p0,r0,max(b0,r0),trend,found,ep_ramp)
                        records.append({"state":key,"action":nearest_action(cfg,delta),"status":status,"clean_success":clean_success,"tail":i/max(1,len(ep)-1),"improvement":r1-r0,"terminal":i==len(ep)-1})
                    except Exception: continue
        except Exception: continue
    return records


def verify_learning(cfg: Config, model: QModel) -> None:
    print("\n=== VERIFY LEARNING v0.6 ===")
    print("Verifies saved-model persistence, deterministic model lookup, ablation sensitivity and demo agreement. It does not promise future lock success.")
    model.save()
    stamp=time.strftime("%Y%m%d_%H%M%S")
    policy_hash=model.policy_hash()
    fresh=QModel(cfg); reload_hash=fresh.policy_hash(); persistence_pass=policy_hash==reload_hash
    states=sorted(set(model.q)|set(model.demo_prior))
    if len(states)>cfg.verify_max_states:
        states=random.Random(5605).sample(states,cfg.verify_max_states)
    deterministic_fail=lookup_fail=ablation_changed=learned_signal_states=0
    margins=[]
    for key in states:
        d=model.decision_details(key,deterministic=True)
        scores=np.asarray(d["scores"],dtype=np.float64); expected=int(np.argmax(scores))
        if int(d["action"])!=expected: lookup_fail+=1
        for _ in range(max(1,cfg.verify_repeat)):
            if int(model.decision_details(key,deterministic=True)["action"])!=expected:
                deterministic_fail+=1; break
        if scores.size:
            o=np.sort(scores); margins.append(float(o[-1]-o[-2]) if len(o)>1 else 0.0)
        nonzero=bool(np.any(np.abs(np.asarray(d["q"]))>1e-12) or np.any(np.abs(np.asarray(d["prior"]))>1e-12))
        if nonzero:
            learned_signal_states+=1
            if expected!=0: ablation_changed+=1
    demos=_demo_transition_records(cfg,model)
    success_trans=[r for r in demos if r["clean_success"]]
    success_tail=[r for r in success_trans if float(r["tail"])>=0.60]
    fail_terminal=[r for r in demos if int(r["status"])==0 and bool(r["terminal"])]
    def agreement(rows):
        exact=near=0
        for r in rows:
            a=int(model.decision_details(str(r["state"]),deterministic=True)["action"]); h=int(r["action"])
            exact+=int(a==h); near+=int(abs(a-h)<=1)
        return exact,near,len(rows)
    sx,sn,st=agreement(success_trans); tx,tn,tt=agreement(success_tail)
    avoided_bad=sum(int(int(model.decision_details(str(r["state"]),deterministic=True)["action"])!=int(r["action"])) for r in fail_terminal)
    train_runs=[]
    if TRAIN_AUDIT_LOG.exists():
        try:
            with TRAIN_AUDIT_LOG.open("r",newline="",encoding="utf-8") as f: train_runs=list(csv.DictReader(f))
        except Exception: train_runs=[]
    mutating_runs=sum(1 for r in train_runs if str(r.get("hash_changed","0"))=="1" and int(float(r.get("changed_values",0) or 0))>0)
    report={"created":time.strftime("%Y-%m-%d %H:%M:%S"),"policy_hash":policy_hash,"reload_hash":reload_hash,"persistence_pass":persistence_pass,"states_tested":len(states),"lookup_failures":lookup_fail,"determinism_failures":deterministic_fail,"states_with_nonzero_learned_signal":learned_signal_states,"ablation_action_changed_states":ablation_changed,"ablation_change_rate":ablation_changed/learned_signal_states if learned_signal_states else 0.0,"mean_top_action_margin":float(np.mean(margins)) if margins else 0.0,"clean_success_demo_transitions":st,"success_demo_exact_agreement":sx,"success_demo_near_agreement":sn,"success_tail_transitions":tt,"success_tail_exact_agreement":tx,"success_tail_near_agreement":tn,"failed_terminal_examples":len(fail_terminal),"failed_terminal_action_avoided":avoided_bad,"training_audit_runs":len(train_runs),"training_runs_that_changed_policy":mutating_runs,"decision_audit_exists":DECISION_AUDIT_LOG.exists()}
    jp=AUDIT_VERIFY_DIR/f"verify_{stamp}.json"; tp=AUDIT_VERIFY_DIR/f"verify_{stamp}.txt"; _atomic_json(jp,report)
    lines=["LOCKPICK LEARNER v0.6 - VERIFY LEARNING","="*48,f"Policy hash: {policy_hash}",f"Reload/persistence: {'PASS' if persistence_pass else 'FAIL'}",f"Policy states tested: {len(states)}",f"Lookup correctness: {'PASS' if lookup_fail==0 else 'FAIL'} ({lookup_fail} failures)",f"Determinism epsilon=0: {'PASS' if deterministic_fail==0 else 'FAIL'} ({deterministic_fail} failures)",f"Non-zero learned states: {learned_signal_states}",f"Ablation changed model-layer action: {ablation_changed}/{learned_signal_states} ({(100*ablation_changed/learned_signal_states) if learned_signal_states else 0:.1f}%)",f"Mean top-action margin: {report['mean_top_action_margin']:.4f}",f"Clean human-success exact agreement: {sx}/{st} ({(100*sx/st) if st else 0:.1f}%)",f"Clean human-success +/-1 action: {sn}/{st} ({(100*sn/st) if st else 0:.1f}%)",f"SUCCESS tail exact: {tx}/{tt} ({(100*tx/tt) if tt else 0:.1f}%)",f"SUCCESS tail +/-1 action: {tn}/{tt} ({(100*tn/tt) if tt else 0:.1f}%)",f"Failed terminal action avoided: {avoided_bad}/{len(fail_terminal)} ({(100*avoided_bad/len(fail_terminal)) if fail_terminal else 0:.1f}%)",f"Audited training runs: {len(train_runs)}; changed-policy runs: {mutating_runs}",f"Live decision audit exists: {'YES' if DECISION_AUDIT_LOG.exists() else 'NO - run AGENT first'}","","PASS on persistence/lookup/determinism proves the saved learned values are actually loaded and used by the policy function.","Ablation sensitivity proves learned values alter choices versus a blank model at the same state.","Use live EVALUATION for actual performance: it runs epsilon=0 with learning disabled."]
    tp.write_text("\n".join(lines)+"\n",encoding="utf-8")
    print("\n".join(lines)); print(f"\nReport saved: {tp}")


# ---------------------------
# Vision diagnostics
# ---------------------------

def vision_debug(cfg: Config, model: QModel) -> None:
    print("VISION DEBUG: auto-detecting the monitor with the lock. F12 closes.")
    vision, console_hwnd, game_hwnd = prepare_live_vision(cfg, model, minimize=True)
    if calibration_valid(model, vision):
        vision.cal.update(model.calibration)
    if cfg.auto_focus_game_window and game_hwnd:
        focus_window(game_hwnd, wait=0.12)
    while True:
        if key_down(cfg.emergency_key_vk):
            break
        st = vision.state(keep_frame=True)
        preview(vision, st, "Lockpick Learner - Vision Debug")
        band_px, arc_px, templ = vision.last_success_parts
        print(f"pos={st.pick_pos!s:>8} lock={st.lock_angle:5.1f} progress={st.progress:.3f} ui={st.ui_confidence:.2f} | band={band_px:5d}/{cfg.success_band_pixels} arc={arc_px:5d}/{cfg.success_arc_max} templ={templ:.2f} success={st.success_score:.3f}{' YES' if st.success_detected else ''}   ", end="\r")
        time.sleep(0.025)
    cv2.destroyAllWindows()
    restore_console(console_hwnd)


def calibrate_only(cfg: Config, model: QModel) -> None:
    vision, console_hwnd, game_hwnd = prepare_live_vision(cfg, model, minimize=True)
    if cfg.auto_focus_game_window and game_hwnd:
        focus_window(game_hwnd, wait=0.15)
    auto_calibrate(cfg, model, vision)
    restore_console(console_hwnd)


def _stored_human_dataset_stats(cfg: Config) -> Tuple[int, int, int, int]:
    clean_success = failed = mixed = unknown = 0
    for path in sorted(DEMO_DIR.glob("demo_*.csv")):
        try:
            with path.open("r", newline="", encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
            grouped: Dict[int, List[Dict[str, str]]] = {}
            for r in rows:
                eid = int(float(r.get("episode_id", 0) or 0))
                grouped.setdefault(eid, []).append(r)
            for ep in grouped.values():
                if not ep:
                    continue
                status = int(float(ep[-1].get("episode_success", -1) or -1))
                elapsed = float(ep[-1].get("episode_elapsed", ep[-1].get("elapsed", 0.0)) or 0.0)
                if status == 1 and (elapsed > cfg.legacy_mixed_max_seconds or len(ep) > cfg.legacy_mixed_max_probes):
                    mixed += 1
                elif status == 1:
                    clean_success += 1
                elif status == 0:
                    failed += 1
                else:
                    unknown += 1
        except Exception:
            continue
    return clean_success, failed, mixed, unknown


def _episode_summaries(folder_success: Path, folder_fail: Path, prefix_success: str, prefix_fail: str) -> List[Dict[str, float]]:
    eps=[]
    for p in folder_success.glob(prefix_success): eps.append((p.name,p,1))
    for p in folder_fail.glob(prefix_fail): eps.append((p.name,p,0))
    eps.sort(key=lambda x:x[0]); out=[]
    for _name,path,success in eps:
        try:
            with path.open("r",newline="",encoding="utf-8") as f: rows=list(csv.DictReader(f))
            if not rows: continue
            elapsed=float(rows[-1].get("elapsed",0.0) or 0.0); reward=float(rows[-1].get("episode_total_reward",0.0) or 0.0)
            best=max(float(r.get("best",0.0) or 0.0) for r in rows)
            out.append({"success":float(success),"elapsed":elapsed,"reward":reward,"best":best,"probes":float(len(rows))})
        except Exception: continue
    return out


def _curve_line(eps: List[Dict[str,float]], n: int) -> str:
    if not eps: return "no episodes"
    subset=eps[-min(n,len(eps)):]; sr=100*sum(x["success"] for x in subset)/len(subset); avg_r=sum(x["reward"] for x in subset)/len(subset); avg_b=sum(x["best"] for x in subset)/len(subset); avg_p=sum(x["probes"] for x in subset)/len(subset); wins=[x for x in subset if x["success"]>0.5]; avg_t=sum(x["elapsed"] for x in wins)/len(wins) if wins else None
    return f"N={len(subset)} success={sr:.1f}% avgBest={avg_b:.3f} avgReward={avg_r:+.1f} avgTransitions={avg_p:.1f} avgWinTime={avg_t:.2f}s" if avg_t is not None else f"N={len(subset)} success={sr:.1f}% avgBest={avg_b:.3f} avgReward={avg_r:+.1f} avgTransitions={avg_p:.1f} avgWinTime=n/a"


def print_stats(cfg: Config, model: QModel) -> None:
    sr = (100 * model.total_successes / model.total_attempts) if model.total_attempts else 0.0
    clean_s, failed_h, mixed_h, unknown_h = _stored_human_dataset_stats(cfg)
    stored_successes = len(list(SUCCESS_DEMO_DIR.glob("success_*.csv")))
    stored_failures = len(list(FAILED_DEMO_DIR.glob("fail_*.csv")))
    sp_s = len(list(SELFPLAY_SUCCESS_DIR.glob("self_success_*.csv")))
    sp_f = len(list(SELFPLAY_FAILED_DIR.glob("self_fail_*.csv")))
    print("\n=== MODEL STATS v0.6 ===")
    off = model.learned_offset()
    if off is not None:
        print(f"Learned ramp -> opening distance: {off:+.3f} (median of {len(model.success_offsets)} successes)")
    elif model.success_offsets:
        print(f"Ramp -> opening distance: {len(model.success_offsets)}/{cfg.offset_min_samples} successes recorded, not used yet")
    else:
        print("Ramp -> opening distance: no confirmed successes yet")
    print(f"Autonomous attempts: {model.total_attempts}")
    print(f"Autonomous SUCCESS-confirmed: {model.total_successes} ({sr:.1f}%)")
    print(f"Stored autonomous self-play: success={sp_s}, fail={sp_f}")
    print(f"Self-play replay Q-updates: {model.selfplay_replay_updates}")
    print(f"Human recorder counters: episodes={model.human_episodes}, success={model.human_successes}, fail={model.human_failures}, incomplete={model.human_incomplete}")
    print(f"Human dataset TRAIN classification: clean success={clean_s}, failed={failed_h}, v0.3 mixed={mixed_h}, incomplete/unknown={unknown_h}")
    print(f"Standalone human archives: success={stored_successes}, failed={stored_failures}")
    print(f"Total Q updates: {model.total_updates}")
    print(f"Demo states: {len(model.demo_prior)}")
    print(f"Q states: {len(model.q)}")
    print(f"Epsilon: {model.epsilon:.4f}")
    print(f"Policy hash: {model.policy_hash()}")
    print(f"Decision audit: {'exists' if DECISION_AUDIT_LOG.exists() else 'not yet'}")
    print(f"Training audit: {'exists' if TRAIN_AUDIT_LOG.exists() else 'not yet'}")
    sp_eps=_episode_summaries(SELFPLAY_SUCCESS_DIR,SELFPLAY_FAILED_DIR,"self_success_*.csv","self_fail_*.csv")
    ev_eps=_episode_summaries(EVAL_SUCCESS_DIR,EVAL_FAILED_DIR,"eval_success_*.csv","eval_fail_*.csv")
    if sp_eps:
        print("\nSELF-PLAY learning curve:")
        for w in cfg.learning_curve_windows: print(f"  last {int(w):3d}: {_curve_line(sp_eps,int(w))}")
    if ev_eps:
        print("\nDETERMINISTIC EVALUATION (learning OFF):")
        for w in cfg.learning_curve_windows: print(f"  last {int(w):3d}: {_curve_line(ev_eps,int(w))}")
    print(f"Calibration: {model.calibration}")


def menu(cfg: Config, model: QModel) -> None:
    while True:
        print("\n" + "=" * 64)
        print(" LOCKPICK LEARNER v0.6 - AUDITABLE LEARNING")
        print("=" * 64)
        print("1) OBSERVE      - record ALL human wins/losses")
        print("2) TRAIN        - human success/failure training + audit snapshots")
        print("3) CALIBRATE    - visual/mouse endpoint calibration")
        print("4) AGENT        - autonomous online Q-learning + replay + decision audit")
        print("5) SELF TRAIN   - replay stored autonomous attempts offline")
        print("6) VERIFY       - prove model persistence/lookup/use + ablation checks")
        print("7) EVALUATE     - deterministic live policy, epsilon=0, learning OFF")
        print("8) VISION DEBUG")
        print("9) STATS        - learning curves + hashes + counters")
        print("10) EXIT")
        choice=input("Select: ").strip().lower()
        if choice in ("1","observe","o"): observe(cfg,model)
        elif choice in ("2","train","t"): train_from_demos(cfg,model)
        elif choice in ("3","calibrate","c"): calibrate_only(cfg,model)
        elif choice in ("4","agent","a"): agent(cfg,model)
        elif choice in ("5","self","selftrain","self train","r"): self_train_from_history(cfg,model)
        elif choice in ("6","verify","v"): verify_learning(cfg,model)
        elif choice in ("7","evaluate","eval","e"): evaluate_agent(cfg,model)
        elif choice in ("8","debug","d"): vision_debug(cfg,model)
        elif choice in ("9","stats","s"): print_stats(cfg,model)
        elif choice in ("10","exit","q","quit"): break


def main() -> None:
    parser = argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("mode", nargs="?", choices=["observe", "train", "calibrate", "agent", "selftrain", "verify", "evaluate", "debug", "stats"])
    args = parser.parse_args()
    cfg = Config.load()
    model = QModel(cfg)
    if not IS_WINDOWS and args.mode in ("agent", "evaluate", "calibrate", "observe"):
        print("This mode needs Windows 10/11.")
        return
    if args.mode == "observe":
        observe(cfg, model)
    elif args.mode == "train":
        train_from_demos(cfg, model)
    elif args.mode == "calibrate":
        calibrate_only(cfg, model)
    elif args.mode == "agent":
        agent(cfg, model)
    elif args.mode == "selftrain":
        self_train_from_history(cfg, model)
    elif args.mode == "verify":
        verify_learning(cfg, model)
    elif args.mode == "evaluate":
        evaluate_agent(cfg, model)
    elif args.mode == "debug":
        vision_debug(cfg, model)
    elif args.mode == "stats":
        print_stats(cfg, model)
    else:
        menu(cfg, model)


if __name__ == "__main__":
    main()
