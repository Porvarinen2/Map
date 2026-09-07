"""AUTOLOCKPICK LIVE - ruudunlukija SCUMin lukkominipeliin.

Ajetaan CMD-ikkunassa pelin rinnalla. Ohjelma kaappaa pelin ruudun, etsii
lukon, mittaa lukkopesan kaannon, ja ohjaa hiirta ja F-nappainta
kunnes lukko aukeaa. Tiirikkaa ei tunnisteta automaatiossa.

    F7    PLAYER RECORDING paalle / pois (pelaa itse, automaatio pois)
    F8    tallenna kattava debug-ZIP viimeisesta ~12 sekunnista
    F11   automaatio aloita / tauota
    F9    lopeta

Paatoslogiikka on tiedostossa lockpick_control.py ja se on testattu
simulaatiolla (live/test_live.py). Tama tiedosto vastaa vain siita, etta
havainnot saadaan ruudulta ja toiminnot menevat peliin.

Tilat:
    ODOTTAA     lukkoruutua ei nay
    ALOITTAA    lukkoruutu nakyy mutta ajastin ei kay -> SPACE
    RATKAISEE   ajastin kay -> skannaus vasemmalta oikealle
    AUKI        lukkoruutu katosi korkealla kaannolla

Kaytto:
    python autolockpick_live.py            normaali ajo
    python autolockpick_live.py --probe    pelkka tunnistuksen tarkistus,
                                           ei laheta yhtaan syotetta
    python autolockpick_live.py --selftest ajaa logiikan simulaatiota vasten
"""

from __future__ import annotations

import argparse
import ctypes
import csv
import json
import math
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import zipfile
from dataclasses import asdict, dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lockpick_control import (  # noqa: E402
    Action,
    ControlConfig,
    Controller,
    Observation,
    SearchMemory,
    full_turn_ms,
    wrap_angle,
)

VERSION = "LIVE 1.6 FAST SCAN + DEEP TARGET"
SETTINGS_FILE = os.path.join(HERE, "live_asetukset.json")


# ==========================================================================
# Riippuvuudet
# ==========================================================================


def ensure_packages():
    missing = []
    try:
        import numpy  # noqa: F401
    except ImportError:
        missing.append("numpy")
    try:
        import mss  # noqa: F401
    except ImportError:
        missing.append("mss")
    try:
        import PIL  # noqa: F401
    except ImportError:
        missing.append("Pillow")

    if missing:
        print(f"Asennetaan puuttuvat paketit: {', '.join(missing)}")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", *missing])

    import mss  # noqa: F811
    import numpy  # noqa: F811
    return numpy, mss


# ==========================================================================
# Asetukset
# ==========================================================================


@dataclass
class VisionConfig:
    """Tunnistuksen mitat lukon sateen R monikertoina.

    Oletukset vastaavat 1920x1080-ruutua, jossa lukko on ruudun keskella ja
    sen sade on noin 150 pikselia. Kaikki suhteutetaan ruudun korkeuteen,
    joten muut resoluutiot toimivat ilman muutoksia.

    Tiirikkaa ei etsita lainkaan. Se on ohut, se voi olla eri tyokalu ja se
    nakyy eri kulmissa, joten sen tunnistus oli epavarmin osa koko ketjua.
    Ohjaus ei sita tarvitse: katso lockpick_control.py.
    """

    lock_radius_fraction: float = 0.139   # lukon sade / ruudun korkeus
    roi_fraction: float = 0.30            # ROI:n puolikas / ruudun korkeus
    center_offset_x: float = 0.0          # hienosaato pikseleina
    center_offset_y: float = 0.0

    metal_min: float = 55.0               # lukon metallin alin kirkkaus
    metal_max: float = 205.0
    dark_max: float = 22.0                # avaimenreian ylin kirkkaus
    bright_min: float = 185.0             # aikakaaren alin kirkkaus
    # Kaynnissa olevassa yrityksessa aikakaari on terava ja kirkas. Sumeassa
    # aloitusruudussa ja SUCCESS-ruudussa sita ei ole lainkaan. Mitattu pelin
    # videosta: kaynnissa 4640-6401 pikselia, aloitusruutu 0, SUCCESS 1.
    running_arc_pixels: int = 1500

    min_keyhole_elongation: float = 4.0   # alle taman maski on saastunut

    keyhole_outer: float = 0.66           # vanha arvo, ei kayteta turn-mittaukseen

    # LIVE 1.4: käyttäjän pinkillä merkitsemä OIKEA pyörivä osa.
    # Kaantoa ei enää päätellä koko lukosta eikä metallin painopisteestä.
    # Nämä arvot ovat 1080p-mittoja ja skaalataan ruudun korkeudella.
    rotation_center_offset_x_1080: float = 0.0
    rotation_center_offset_y_1080: float = -3.0
    rotation_area_radius_1080: float = 128.5
    rotation_keyway_radius_1080: float = 56.0
    rotation_min_keyway_pixels: int = 700
    rotation_min_elongation: float = 5.0

    timer_inner: float = 1.05             # aikakaaren haku, x R
    timer_outer: float = 1.75

    min_metal_pixels: int = 2500
    min_keyhole_pixels: int = 250


@dataclass
class RunConfig:
    capture_fps: float = 90.0
    open_turn_degrees: float = 45.0       # nain paljon pesan on pitanyt kaantya
    lost_frames_for_end: int = 6
    restart_key_interval_ms: float = 420.0
    max_attempts: int = 0                 # 0 = rajaton


def load_settings():
    control, vision, run = ControlConfig(), VisionConfig(), RunConfig()
    if not os.path.exists(SETTINGS_FILE):
        return control, vision, run
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception as error:
        print(f"Asetustiedostoa ei voitu lukea ({error}). Kaytetaan oletuksia.")
        return control, vision, run

    for section, target in (("control", control), ("vision", vision), ("run", run)):
        for key, value in (data.get(section) or {}).items():
            if hasattr(target, key):
                setattr(target, key, value)
    return control, vision, run


def save_settings(control, vision, run):
    payload = {"control": asdict(control), "vision": asdict(vision), "run": asdict(run)}
    try:
        with open(SETTINGS_FILE, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)
    except Exception as error:
        print(f"Asetuksia ei voitu tallentaa: {error}")


# ==========================================================================
# Windows-syote
# ==========================================================================

VK_F7, VK_F8, VK_F9, VK_F11 = 0x76, 0x77, 0x78, 0x7A
VK_F, VK_SPACE, VK_ESCAPE = 0x46, 0x20, 0x1B
VK_W, VK_A, VK_S, VK_D = 0x57, 0x41, 0x53, 0x44
VK_SHIFT, VK_CONTROL = 0x10, 0x11
VK_LBUTTON, VK_RBUTTON = 0x01, 0x02
SCAN_F, SCAN_SPACE = 0x21, 0x39

INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
MOUSEEVENTF_MOVE = 0x0001
KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE = 0x0002, 0x0008


class WinInput:
    """SendInput-kerros. Nappaimet lahetetaan skannauskoodeina, koska
    pelit lukevat DirectInputilla eivatka aina huomaa virtuaalikoodeja."""

    def __init__(self):
        if os.name != "nt":
            raise RuntimeError("Tama osa toimii vain Windowsissa.")
        from ctypes import wintypes as W

        self.W = W
        self.user = ctypes.WinDLL("user32", use_last_error=True)

        try:
            self.user.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]
            self.user.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
        except Exception:
            try:
                ctypes.windll.shcore.SetProcessDpiAwareness(2)
            except Exception:
                self.user.SetProcessDPIAware()

        class MOUSEINPUT(ctypes.Structure):
            _fields_ = [("dx", W.LONG), ("dy", W.LONG), ("mouseData", W.DWORD),
                        ("dwFlags", W.DWORD), ("time", W.DWORD),
                        ("dwExtraInfo", ctypes.c_size_t)]

        class KEYBDINPUT(ctypes.Structure):
            _fields_ = [("wVk", W.WORD), ("wScan", W.WORD), ("dwFlags", W.DWORD),
                        ("time", W.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

        class HARDWAREINPUT(ctypes.Structure):
            _fields_ = [("uMsg", W.DWORD), ("wParamL", W.WORD), ("wParamH", W.WORD)]

        class UNION(ctypes.Union):
            _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]

        class INPUT(ctypes.Structure):
            _anonymous_ = ("u",)
            _fields_ = [("type", W.DWORD), ("u", UNION)]

        expected = 40 if ctypes.sizeof(ctypes.c_void_p) == 8 else 28
        if ctypes.sizeof(INPUT) != expected:
            raise RuntimeError("Windowsin INPUT-rakenteen koko on vaara.")

        self.INPUT, self.MOUSEINPUT, self.KEYBDINPUT = INPUT, MOUSEINPUT, KEYBDINPUT
        self.user.SendInput.argtypes = [W.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
        self.user.SendInput.restype = W.UINT
        self.user.GetAsyncKeyState.argtypes = [ctypes.c_int]
        self.user.GetAsyncKeyState.restype = W.SHORT
        self.user.GetForegroundWindow.restype = W.HWND
        self.user.GetClientRect.argtypes = [W.HWND, ctypes.POINTER(W.RECT)]
        self.user.ClientToScreen.argtypes = [W.HWND, ctypes.POINTER(W.POINT)]
        self.user.IsIconic.argtypes = [W.HWND]
        self.user.GetWindowTextW.argtypes = [W.HWND, W.LPWSTR, ctypes.c_int]
        self.user.GetWindowThreadProcessId.argtypes = [W.HWND, ctypes.POINTER(W.DWORD)]
        self.user.GetCursorPos.argtypes = [ctypes.POINTER(W.POINT)]
        self.user.GetCursorPos.restype = W.BOOL

        self._held_keys: set[int] = set()
        self._mouse_residual = 0.0

        # Ilman tata Windowsin ajastin liikkuu noin 15 ms askelin, mika on
        # samaa luokkaa kuin koko F-testin kesto.
        try:
            self.winmm = ctypes.WinDLL("winmm")
            self.winmm.timeBeginPeriod(1)
        except Exception:
            self.winmm = None

    def close(self) -> None:
        self.release_all()
        if getattr(self, "winmm", None):
            try:
                self.winmm.timeEndPeriod(1)
            except Exception:
                pass

    # -- syotteet ----------------------------------------------------------

    def _send(self, *inputs):
        array = (self.INPUT * len(inputs))(*inputs)
        sent = self.user.SendInput(len(inputs), array, ctypes.sizeof(self.INPUT))
        if sent != len(inputs):
            raise ctypes.WinError(ctypes.get_last_error())

    def move_mouse(self, units: float) -> int:
        """Suhteellinen sivuttaisliike. Murto-osat kerataan talteen, jottei
        pienista pulsseista jaa systemaattista virhetta."""
        total = units + self._mouse_residual
        whole = int(total)
        self._mouse_residual = total - whole
        if whole == 0:
            return 0
        item = self.INPUT(type=INPUT_MOUSE)
        item.mi = self.MOUSEINPUT(dx=whole, dy=0, mouseData=0,
                                  dwFlags=MOUSEEVENTF_MOVE, time=0, dwExtraInfo=0)
        self._send(item)
        return whole

    def key_down(self, scan: int) -> None:
        if scan in self._held_keys:
            return
        item = self.INPUT(type=INPUT_KEYBOARD)
        item.ki = self.KEYBDINPUT(wVk=0, wScan=scan, dwFlags=KEYEVENTF_SCANCODE,
                                  time=0, dwExtraInfo=0)
        self._send(item)
        self._held_keys.add(scan)

    def key_up(self, scan: int) -> None:
        if scan not in self._held_keys:
            return
        item = self.INPUT(type=INPUT_KEYBOARD)
        item.ki = self.KEYBDINPUT(wVk=0, wScan=scan,
                                  dwFlags=KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP,
                                  time=0, dwExtraInfo=0)
        self._send(item)
        self._held_keys.discard(scan)

    def tap(self, scan: int, hold_ms: float = 60.0) -> None:
        self.key_down(scan)
        time.sleep(hold_ms / 1000.0)
        self.key_up(scan)

    def release_all(self) -> None:
        for scan in list(self._held_keys):
            try:
                self.key_up(scan)
            except Exception:
                pass
        self._mouse_residual = 0.0

    # -- ikkuna ------------------------------------------------------------

    def pressed(self, vk: int) -> bool:
        return bool(self.user.GetAsyncKeyState(vk) & 0x8000)

    def cursor_pos(self):
        point = self.W.POINT()
        if not self.user.GetCursorPos(ctypes.byref(point)):
            return None
        return int(point.x), int(point.y)

    def foreground_client(self):
        hwnd = self.user.GetForegroundWindow()
        if not hwnd or self.user.IsIconic(hwnd):
            return None, ""
        pid = self.W.DWORD()
        self.user.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value == os.getpid():
            return None, "oma ikkuna"

        rect, point = self.W.RECT(), self.W.POINT(0, 0)
        if not self.user.GetClientRect(hwnd, ctypes.byref(rect)):
            return None, ""
        if not self.user.ClientToScreen(hwnd, ctypes.byref(point)):
            return None, ""
        width, height = rect.right - rect.left, rect.bottom - rect.top
        if width < 640 or height < 400:
            return None, "ikkuna liian pieni"

        buf = ctypes.create_unicode_buffer(300)
        self.user.GetWindowTextW(hwnd, buf, 300)
        return {"left": point.x, "top": point.y, "width": width, "height": height}, buf.value


# ==========================================================================
# Tunnistus
# ==========================================================================


def timer_running(history, drop: float, window: float = 0.45,
                  minimum_samples: int = 4) -> bool:
    """Kutistuuko aikakaari. Ei enaa kaytossa tunnistuksessa, koska kaari
    kutistuu liian hitaasti: pelin videossa se pieneni 9 sekunnissa vain
    neljanneksen. Jatetty tanne, koska se on hyodyllinen debug-mittari."""
    if len(history) < minimum_samples + 2:
        return False
    latest = history[-1][0]
    values = [value for stamp, value in history if latest - stamp < window]
    if len(values) < minimum_samples:
        return False
    return (values[0] - values[-1]) >= drop


class Detector:
    """Geometrinen tunnistus. Ei mallikuvia eika kiinteita pikselikoordinaatteja,
    joten sama koodi toimii eri resoluutioilla."""

    def __init__(self, np, cfg: VisionConfig):
        self.np = np
        self.cfg = cfg
        self._grid_for = None
        self._radius = None
        self._angle = None
        self.last_turn = 0.0
        self.timer_peak = 1.0
        self.timer_history: list[tuple[float, float]] = []
        self.debug = {}

    def _grids(self, size: int):
        if self._grid_for != size:
            np = self.np
            axis = np.arange(size, dtype=np.float32) - (size - 1) / 2.0
            yy, xx = np.meshgrid(axis, axis, indexing="ij")
            self._radius = np.sqrt(xx * xx + yy * yy)
            self._angle = (xx, yy)
            self._grid_for = size
        return self._radius, self._angle

    def roi_box(self, client):
        half = int(self.cfg.roi_fraction * client["height"])
        cx = client["left"] + client["width"] // 2 + int(self.cfg.center_offset_x)
        cy = client["top"] + client["height"] // 2 + int(self.cfg.center_offset_y)
        return {"left": cx - half, "top": cy - half, "width": half * 2, "height": half * 2}

    def read(self, frame_bgr, client, stamp: float) -> Observation:
        np = self.np
        cfg = self.cfg

        lum = (
            0.114 * frame_bgr[:, :, 0].astype(np.float32)
            + 0.587 * frame_bgr[:, :, 1].astype(np.float32)
            + 0.299 * frame_bgr[:, :, 2].astype(np.float32)
        )

        size = frame_bgr.shape[0]
        radius_map, (xx, yy) = self._grids(size)

        scale = client["height"] / 1080.0
        nominal_r = cfg.lock_radius_fraction * client["height"]

        # Fixed center from the user's 1080p Rotationarea-On-Screen reference.
        # _grids() is already centered at the geometric pixel center, therefore
        # x offset is 0 and only the measured ~-3px Y offset is applied.
        rot_cx = cfg.rotation_center_offset_x_1080 * scale
        rot_cy = cfg.rotation_center_offset_y_1080 * scale

        local_r = np.sqrt(
            (xx - rot_cx) ** 2
            + (yy - rot_cy) ** 2
        )

        rotation_radius = cfg.rotation_area_radius_1080 * scale
        keyway_radius = cfg.rotation_keyway_radius_1080 * scale

        self.debug["turn_source"] = "INNER_CHAMBER_ONLY"
        self.debug["rotation_cx"] = round(float(rot_cx), 3)
        self.debug["rotation_cy"] = round(float(rot_cy), 3)
        self.debug["rotation_radius"] = round(float(rotation_radius), 3)
        self.debug["keyway_radius"] = round(float(keyway_radius), 3)

        # 1) Presence check only. This can use the surrounding metal, but none
        # of these pixels participate in the turn angle.
        metal = (
            (lum > cfg.metal_min)
            & (lum < cfg.metal_max)
            & (local_r < nominal_r * 1.15)
        )
        metal_count = int(metal.sum())
        self.debug["metal"] = metal_count
        if metal_count < cfg.min_metal_pixels:
            return Observation(stamp=stamp, ok=False)

        # 2) TURN MEASUREMENT.
        #
        # Only the central dark keyway inside the user's pink rotating chamber
        # is used. The outer shell, rust outside the chamber, timer ring and
        # lockpick angle cannot influence this measurement.
        #
        # A ~56px radius at 1080p was validated against:
        # - Lockpickstart
        # - Lockpicking
        # - MaxSideLeft / MaxSideRight
        # - the 47-frame real gameplay sequence
        keyhole = (
            (lum < cfg.dark_max)
            & (local_r < keyway_radius)
        )

        keyhole_count = int(keyhole.sum())
        self.debug["keyhole"] = keyhole_count
        self.debug["rotation_pixels"] = int(
            (local_r < rotation_radius).sum()
        )

        if keyhole_count < cfg.rotation_min_keyway_pixels:
            return Observation(stamp=stamp, ok=False)

        turn, elongation = self._principal_angle(
            xx[keyhole] - rot_cx,
            yy[keyhole] - rot_cy,
        )

        self.debug["elong"] = elongation

        if elongation < cfg.rotation_min_elongation:
            # A real active keyway is strongly elongated. SUCCESS screens and
            # contaminated central masks become nearly round and are rejected.
            return Observation(stamp=stamp, ok=False)

        turn = wrap_angle(turn, self.last_turn)
        turn = max(-12.0, min(105.0, turn))
        self.last_turn = turn

        # 3) Timer ring still uses the fixed lock center, but it is completely
        # separate from the turn measurement.
        ring = (
            (lum > cfg.bright_min)
            & (local_r > nominal_r * cfg.timer_inner)
            & (local_r < nominal_r * cfg.timer_outer)
        )

        ring_count = int(ring.sum())
        self.debug["timer"] = ring_count

        self.timer_peak = max(
            self.timer_peak,
            float(ring_count),
        )

        timer = (
            ring_count / self.timer_peak
            if self.timer_peak > 0
            else 1.0
        )
        timer = max(0.0, min(1.0, timer))

        self.timer_history.append((stamp, timer))
        del self.timer_history[:-60]

        running = ring_count >= cfg.running_arc_pixels

        return Observation(
            stamp=stamp,
            ok=True,
            turn=turn,
            timer=timer,
            running=running,
        )

    def _principal_angle(self, xs, ys) -> float:
        """Pisteparven paaakselin suunta asteina pystysuorasta myotapaivaan."""
        np = self.np
        points = np.stack([xs, ys], axis=1).astype(np.float64)
        points = points - points.mean(axis=0)
        cov = np.cov(points.T)
        values, vectors = np.linalg.eigh(cov)
        vector = vectors[:, -1]
        if vector[1] > 0:
            vector = -vector
        angle = math.degrees(math.atan2(float(vector[0]), -float(vector[1])))
        elongation = float(values[-1] / max(values[0], 1e-6))
        return angle, elongation

    def reset_attempt(self) -> None:
        self.timer_peak = 1.0
        self.last_turn = 0.0
        self.timer_history.clear()


# ==========================================================================
# Konsolinakyma
# ==========================================================================


class Console:
    """Piirtaa nakyman paikalleen. Piirtovali on erikseen, koska ruutua
    luetaan kymmenia kertoja sekunnissa mutta silmalle riittaa reilusti
    harvempi paivitys."""

    def __init__(self, fps: float = 12.0):
        self.interval = 1.0 / max(1.0, fps)
        self._last_draw = 0.0
        self.enabled = True
        if os.name == "nt":
            try:
                kernel = ctypes.windll.kernel32
                handle = kernel.GetStdHandle(-11)
                mode = ctypes.c_uint32()
                kernel.GetConsoleMode(handle, ctypes.byref(mode))
                kernel.SetConsoleMode(handle, mode.value | 0x0004)
            except Exception:
                self.enabled = False
        self._lines = 0

    def draw(self, lines: list[str], force: bool = False) -> None:
        now = time.perf_counter()
        if not force and now - self._last_draw < self.interval:
            return
        self._last_draw = now
        if self.enabled:
            sys.stdout.write("\x1b[H\x1b[2J")
        sys.stdout.write("\n".join(lines) + "\n")
        sys.stdout.flush()
        self._lines = len(lines)


def bar(fraction: float, width: int = 24, fill: str = "#", empty: str = ".") -> str:
    fraction = max(0.0, min(1.0, fraction))
    filled = int(round(fraction * width))
    return fill * filled + empty * (width - filled)



# ==========================================================================
# Pelaajan manuaalinen tallennin + laaja debug
# ==========================================================================


PLAYER_KEYS = {
    "F": VK_F,
    "SPACE": VK_SPACE,
    "ESC": VK_ESCAPE,
    "W": VK_W,
    "A": VK_A,
    "S": VK_S,
    "D": VK_D,
    "SHIFT": VK_SHIFT,
    "CTRL": VK_CONTROL,
    "LMB": VK_LBUTTON,
    "RMB": VK_RBUTTON,
}


def _safe_number(value, digits=2):
    if value is None:
        return None
    try:
        value = float(value)
    except Exception:
        return None
    if not math.isfinite(value):
        return None
    return round(value, digits)


def _annotated_png(np, raw_bgr, lines, output_path, panel_width=470):
    from PIL import Image, ImageDraw, ImageFont

    if raw_bgr is None:
        return False

    rgb = raw_bgr[:, :, ::-1]
    image = Image.fromarray(rgb.astype("uint8"), "RGB")
    width, height = image.size

    canvas = Image.new("RGB", (width + panel_width, height), (13, 16, 15))
    canvas.paste(image, (0, 0))

    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    x = width + 16
    y = 14
    line_h = 15

    draw.text((x, y), "AUTOLOCKPICK PLAYER RECORDER", fill=(225, 210, 150), font=font)
    y += line_h * 2

    for line in lines:
        if line == "":
            y += line_h // 2
            continue

        upper = line.upper()
        if "F=DOWN" in upper or "RECORDING" in upper or "OPEN" in upper:
            fill = (120, 225, 145)
        elif "ERROR" in upper or "LOST" in upper or "TIMEOUT" in upper:
            fill = (235, 115, 115)
        elif upper.startswith("VISION"):
            fill = (150, 195, 220)
        else:
            fill = (225, 229, 224)

        draw.text((x, y), line[:72], fill=fill, font=font)
        y += line_h
        if y > height - line_h:
            break

    canvas.save(output_path, format="PNG", optimize=False)
    return True


class PlayerRecorder:
    """F7 manuaalisen pelaamisen tallennus.

    Ei laheta peliin yhtaan syotetta. Tallentaa annotoidut kuvat, kaikki
    capture-framet JSONL:na, nappien reunat, F-pitoajat ja yrityskohtaisen
    pelaajaprofiilin.
    """

    def __init__(self, np, image_fps=25.0):
        self.np = np
        self.image_fps = float(image_fps)
        self.active = False
        self.folder = None
        self.frames_folder = None
        self._telemetry = None
        self._events = None
        self._queue = None
        self._writer = None
        self._writer_error = None

        self.started_perf = 0.0
        self.last_image_at = -1e9
        self.sample_index = 0
        self.image_index = 0
        self.images_written = 0
        self.images_dropped = 0

        self.prev_keys = {}
        self.prev_cursor = None
        self.prev_turn = None
        self.prev_stamp = None

        self.cursor_abs_dx = 0
        self.cursor_abs_dy = 0
        self.cursor_net_dx = 0
        self.cursor_net_dy = 0
        self.cursor_move_frames = 0

        self.key_down_counts = {name: 0 for name in PLAYER_KEYS}
        self.f_holds = []
        self.current_f_hold = None
        self.last_f_down_elapsed = None
        self.f_intervals_ms = []
        self.mouse_since_f_net = 0
        self.mouse_since_f_abs = 0

        self.attempts = []
        self.current_attempt = None
        self.attempt_missing_frames = 0
        self.last_event_lines = []
        self.max_turn_session = 0.0

    def start(self):
        if self.active:
            return self.folder

        stamp = time.strftime("%Y%m%d_%H%M%S")
        self.folder = os.path.join(HERE, "manual_records", f"player_{stamp}")
        self.frames_folder = os.path.join(self.folder, "frames")
        os.makedirs(self.frames_folder, exist_ok=True)

        self._telemetry = open(
            os.path.join(self.folder, "telemetry.jsonl"),
            "w", encoding="utf-8", buffering=1,
        )
        self._events = open(
            os.path.join(self.folder, "events.jsonl"),
            "w", encoding="utf-8", buffering=1,
        )

        self._queue = queue.Queue(maxsize=160)
        self._writer = threading.Thread(
            target=self._writer_loop,
            name="autolockpick-player-recorder",
            daemon=True,
        )
        self._writer.start()

        self.started_perf = time.perf_counter()
        self.last_image_at = -1e9
        self.sample_index = 0
        self.image_index = 0
        self.images_written = 0
        self.images_dropped = 0
        self._writer_error = None

        self.prev_keys = {}
        self.prev_cursor = None
        self.prev_turn = None
        self.prev_stamp = None

        self.cursor_abs_dx = 0
        self.cursor_abs_dy = 0
        self.cursor_net_dx = 0
        self.cursor_net_dy = 0
        self.cursor_move_frames = 0

        self.key_down_counts = {name: 0 for name in PLAYER_KEYS}
        self.f_holds = []
        self.current_f_hold = None
        self.last_f_down_elapsed = None
        self.f_intervals_ms = []
        self.mouse_since_f_net = 0
        self.mouse_since_f_abs = 0

        self.attempts = []
        self.current_attempt = None
        self.attempt_missing_frames = 0
        self.last_event_lines = []
        self.max_turn_session = 0.0

        self.active = True
        self._event(0.0, "recording_start", {})
        return self.folder

    def stop(self, reason="F7"):
        if not self.active:
            return None

        elapsed = max(0.0, time.perf_counter() - self.started_perf)

        if self.current_f_hold is not None:
            self._close_f_hold(elapsed, self.prev_turn)
        if self.current_attempt is not None:
            self._close_attempt(elapsed, "recording_stopped")

        self._event(elapsed, "recording_stop", {"reason": reason})
        self.active = False

        if self._queue is not None:
            try:
                self._queue.put(None, timeout=3.0)
            except Exception:
                pass

        if self._writer is not None:
            self._writer.join(timeout=12.0)

        if self._telemetry:
            self._telemetry.flush()
            self._telemetry.close()
            self._telemetry = None
        if self._events:
            self._events.flush()
            self._events.close()
            self._events = None

        self._write_summary(elapsed)
        return self.folder

    def _event(self, elapsed, kind, data):
        row = {"t": round(float(elapsed), 6), "kind": kind, **data}
        if self._events:
            self._events.write(json.dumps(row, ensure_ascii=False) + "\n")

        compact = f"{elapsed:6.3f}s {kind}"
        if "key" in data:
            compact += f" {data['key']}"
        if "result" in data:
            compact += f" {data['result']}"
        self.last_event_lines.append(compact)
        del self.last_event_lines[:-8]

    def _start_attempt(self, elapsed, obs):
        self.current_attempt = {
            "number": len(self.attempts) + 1,
            "start_s": round(elapsed, 6),
            "end_s": None,
            "duration_s": None,
            "result": None,
            "max_turn": _safe_number(obs.turn, 3),
            "min_timer": _safe_number(obs.timer, 4),
            "f_presses": 0,
            "f_hold_indices": [],
            "mouse_abs_dx": 0,
            "mouse_net_dx": 0,
        }
        self.attempt_missing_frames = 0
        self._event(elapsed, "attempt_start", {"attempt": self.current_attempt["number"]})

    def _close_attempt(self, elapsed, result):
        if self.current_attempt is None:
            return
        attempt = self.current_attempt
        attempt["end_s"] = round(elapsed, 6)
        attempt["duration_s"] = round(elapsed - float(attempt["start_s"]), 6)
        attempt["result"] = result
        self.attempts.append(attempt)
        self._event(elapsed, "attempt_end", {
            "attempt": attempt["number"],
            "result": result,
            "max_turn": attempt["max_turn"],
        })
        self.current_attempt = None
        self.attempt_missing_frames = 0

    def _start_f_hold(self, elapsed, obs):
        # Varsinainen pelaajayritys alkaa datan kannalta ensimmaisesta F:sta,
        # ei pelkasta arc/running-flickerista. Tama poistaa vanhan session
        # 13 haamuyritysta, joissa F-painalluksia oli nolla.
        if self.current_attempt is None and obs is not None and obs.ok and obs.running:
            self._start_attempt(elapsed, obs)

        if self.last_f_down_elapsed is not None:
            self.f_intervals_ms.append((elapsed - self.last_f_down_elapsed) * 1000.0)
        self.last_f_down_elapsed = elapsed

        turn = obs.turn if obs is not None and obs.ok else None
        self.current_f_hold = {
            "index": len(self.f_holds) + 1,
            "start_s": round(elapsed, 6),
            "end_s": None,
            "duration_ms": None,
            "start_turn": _safe_number(turn, 3),
            "peak_turn": _safe_number(turn, 3),
            "end_turn": None,
            "first_response_3deg_ms": None,
            "first_abs_5deg_ms": None,
            "mouse_net_since_previous_f": self.mouse_since_f_net,
            "mouse_abs_since_previous_f": self.mouse_since_f_abs,
        }
        self.mouse_since_f_net = 0
        self.mouse_since_f_abs = 0

        if self.current_attempt is not None:
            self.current_attempt["f_presses"] += 1
            self.current_attempt["f_hold_indices"].append(self.current_f_hold["index"])

    def _close_f_hold(self, elapsed, end_turn):
        if self.current_f_hold is None:
            return
        hold = self.current_f_hold
        hold["end_s"] = round(elapsed, 6)
        hold["duration_ms"] = round(
            (elapsed - float(hold["start_s"])) * 1000.0, 3
        )
        hold["end_turn"] = _safe_number(end_turn, 3)
        self.f_holds.append(hold)
        self.current_f_hold = None

    def observe(self, now, raw_bgr, obs, detector_debug, keys, cursor,
                window_title="", app_state="", auto_active=False,
                controller=None, memory=None, action=None):
        if not self.active:
            return

        elapsed = now - self.started_perf
        self.sample_index += 1

        for name, down in keys.items():
            previous = bool(self.prev_keys.get(name, False))

            if down and not previous:
                self.key_down_counts[name] = self.key_down_counts.get(name, 0) + 1
                self._event(elapsed, "key_down", {"key": name})
                if name == "F":
                    self._start_f_hold(elapsed, obs)

            elif previous and not down:
                self._event(elapsed, "key_up", {"key": name})
                if name == "F":
                    self._close_f_hold(
                        elapsed,
                        obs.turn if obs is not None and obs.ok else self.prev_turn,
                    )

        self.prev_keys = dict(keys)

        dx = dy = 0
        if cursor is not None and self.prev_cursor is not None:
            dx = int(cursor[0] - self.prev_cursor[0])
            dy = int(cursor[1] - self.prev_cursor[1])

            if abs(dx) <= 1500 and abs(dy) <= 1500:
                if dx or dy:
                    self.cursor_move_frames += 1
                self.cursor_abs_dx += abs(dx)
                self.cursor_abs_dy += abs(dy)
                self.cursor_net_dx += dx
                self.cursor_net_dy += dy
                self.mouse_since_f_net += dx
                self.mouse_since_f_abs += abs(dx)

                if self.current_attempt is not None:
                    self.current_attempt["mouse_abs_dx"] += abs(dx)
                    self.current_attempt["mouse_net_dx"] += dx
            else:
                dx = dy = 0

        if cursor is not None:
            self.prev_cursor = cursor

        turn_velocity = None
        if (
            obs is not None
            and obs.ok
            and self.prev_turn is not None
            and self.prev_stamp is not None
            and obs.stamp > self.prev_stamp
        ):
            turn_velocity = (
                float(obs.turn) - float(self.prev_turn)
            ) / (
                float(obs.stamp) - float(self.prev_stamp)
            )

        if obs is not None and obs.ok:
            self.max_turn_session = max(self.max_turn_session, float(obs.turn))
            if self.current_f_hold is not None:
                peak = self.current_f_hold.get("peak_turn")
                if peak is None or obs.turn > peak:
                    self.current_f_hold["peak_turn"] = _safe_number(obs.turn, 3)

                hold_start = float(self.current_f_hold["start_s"])
                hold_ms = max(0.0, (elapsed - hold_start) * 1000.0)
                base = self.current_f_hold.get("start_turn")
                if base is not None:
                    if (self.current_f_hold.get("first_response_3deg_ms") is None
                            and float(obs.turn) - float(base) >= 3.0):
                        self.current_f_hold["first_response_3deg_ms"] = round(hold_ms, 3)
                if (self.current_f_hold.get("first_abs_5deg_ms") is None
                        and float(obs.turn) >= 5.0):
                    self.current_f_hold["first_abs_5deg_ms"] = round(hold_ms, 3)

        # Attempt segmentation. Yritys on olemassa vasta ensimmaisen F:n
        # jalkeen. Running-tilan yksittaiset flickerit eivat luo haamuyrityksia.
        if self.current_attempt is not None:
            if obs is not None and obs.ok and obs.running:
                self.attempt_missing_frames = 0
                self.current_attempt["max_turn"] = max(
                    float(self.current_attempt["max_turn"] or 0.0), float(obs.turn)
                )
                self.current_attempt["min_timer"] = min(
                    float(self.current_attempt["min_timer"] or 1.0), float(obs.timer)
                )
            else:
                self.attempt_missing_frames += 1
                if self.attempt_missing_frames >= 4:
                    result = (
                        "opened"
                        if float(self.current_attempt["max_turn"] or 0.0) >= 88.0
                        else "ended"
                    )
                    self._close_attempt(elapsed, result)

        row = {
            "sample": self.sample_index,
            "t": round(elapsed, 6),
            "wall_time": time.strftime("%Y-%m-%d %H:%M:%S"),
            "window": window_title,
            "app_state": app_state,
            "auto_active": bool(auto_active),
            "observation": {
                "ok": bool(obs.ok) if obs else False,
                "turn": _safe_number(obs.turn, 4) if obs else None,
                "turn_velocity_deg_s": _safe_number(turn_velocity, 3),
                "timer": _safe_number(obs.timer, 5) if obs else None,
                "running": bool(obs.running) if obs else False,
            },
            "keys": dict(keys),
            "cursor": {
                "x": cursor[0] if cursor else None,
                "y": cursor[1] if cursor else None,
                "dx": dx,
                "dy": dy,
                "abs_dx_session": self.cursor_abs_dx,
                "net_dx_session": self.cursor_net_dx,
            },
            "vision": {
                key: _safe_number(value, 4)
                if isinstance(value, (int, float))
                else value
                for key, value in dict(detector_debug or {}).items()
            },
            "attempt": self.current_attempt["number"] if self.current_attempt else None,
            "f_hold": dict(self.current_f_hold) if self.current_f_hold else None,
        }

        if controller is not None:
            row["controller"] = {
                "phase": getattr(controller, "phase", None),
                "position_u": _safe_number(getattr(controller, "position", None), 3),
                "target_u": _safe_number(getattr(controller, "target", None), 3),
                "scan_step_u": _safe_number(getattr(controller, "scan_step", None), 3),
                "measured_turn_rate": _safe_number(
                    getattr(controller, "measured_turn_rate", None), 3
                ),
                "probes": len(getattr(controller, "probes", []) or []),
            }

        if action is not None:
            row["last_action"] = {
                "mouse_units": _safe_number(getattr(action, "mouse_units", 0.0), 3),
                "f_down": bool(getattr(action, "f_down", False)),
                "phase": getattr(action, "phase", ""),
                "note": getattr(action, "note", ""),
            }

        self._telemetry.write(json.dumps(row, ensure_ascii=False, default=str) + "\n")

        interval = 1.0 / max(1.0, self.image_fps)
        if raw_bgr is not None and now - self.last_image_at >= interval:
            self.last_image_at = now
            self.image_index += 1

            f_down = bool(keys.get("F", False))
            hold_ms = 0.0
            if f_down and self.current_f_hold is not None:
                hold_ms = (
                    elapsed - float(self.current_f_hold["start_s"])
                ) * 1000.0

            attempt_no = self.current_attempt["number"] if self.current_attempt else "-"

            lines = [
                f"RECORDING   {elapsed:8.3f} s   frame {self.image_index}",
                f"ATTEMPT     {attempt_no}",
                "",
                f"BARREL      {obs.turn:7.2f} deg" if obs and obs.ok else "BARREL      LOST",
                (
                    f"TURN RATE   {turn_velocity:7.1f} deg/s"
                    if turn_velocity is not None
                    else "TURN RATE   -"
                ),
                (
                    f"TIMER       {obs.timer*100:7.2f}%  running={obs.running}"
                    if obs
                    else "TIMER       -"
                ),
                f"MAX TURN    {self.max_turn_session:7.2f} deg",
                "",
                f"INPUT       F={'DOWN' if f_down else 'UP'}  hold={hold_ms:6.1f} ms",
                f"            SPACE={'DOWN' if keys.get('SPACE') else 'UP'}",
                (
                    f"CURSOR      {cursor[0]:5d},{cursor[1]:5d}  dX={dx:+4d} dY={dy:+4d}"
                    if cursor
                    else "CURSOR      unavailable"
                ),
                f"MOUSE SUM   absX={self.cursor_abs_dx}  netX={self.cursor_net_dx:+d}",
                "",
                (
                    f"VISION      metal={detector_debug.get('metal', 0)} "
                    f"keyhole={detector_debug.get('keyhole', 0)}"
                ),
                (
                    f"            elong={detector_debug.get('elong', 0):.1f} "
                    f"arc={detector_debug.get('timer', 0)} "
                    f"R={detector_debug.get('R', 0):.1f}"
                    if detector_debug
                    else "VISION      -"
                ),
                "",
                f"F PRESSES   {self.key_down_counts.get('F', 0)}",
                f"SPACE       {self.key_down_counts.get('SPACE', 0)}",
                f"IMAGES      {self.images_written} written / {self.images_dropped} dropped",
                "",
                "LAST EVENTS",
            ]
            lines += self.last_event_lines[-6:]

            try:
                self._queue.put_nowait((
                    self.image_index,
                    int(round(elapsed * 1000.0)),
                    raw_bgr.copy(),
                    lines,
                ))
            except queue.Full:
                self.images_dropped += 1

        if obs is not None and obs.ok:
            self.prev_turn = float(obs.turn)
            self.prev_stamp = float(obs.stamp)

    def _writer_loop(self):
        while True:
            item = self._queue.get()

            if item is None:
                self._queue.task_done()
                break

            index, elapsed_ms, frame, lines = item
            try:
                filename = f"frame_{index:06d}_{elapsed_ms:08d}ms.png"
                _annotated_png(
                    self.np,
                    frame,
                    lines,
                    os.path.join(self.frames_folder, filename),
                )
                self.images_written += 1
            except Exception as error:
                self._writer_error = f"{type(error).__name__}: {error}"
            finally:
                self._queue.task_done()

    @staticmethod
    def _median(values):
        values = [float(v) for v in values if v is not None]
        if not values:
            return None
        values.sort()
        middle = len(values) // 2
        if len(values) % 2:
            return values[middle]
        return (values[middle - 1] + values[middle]) / 2.0

    def _write_summary(self, elapsed):
        if not self.folder:
            return

        hold_durations = [
            h["duration_ms"] for h in self.f_holds
            if h.get("duration_ms") is not None
        ]
        movement_abs = [h["mouse_abs_since_previous_f"] for h in self.f_holds]
        movement_net = [h["mouse_net_since_previous_f"] for h in self.f_holds]
        response_onsets = [
            h.get("first_response_3deg_ms") for h in self.f_holds
            if h.get("first_response_3deg_ms") is not None
        ]

        best_hold = None
        if self.f_holds:
            best_hold = max(
                self.f_holds,
                key=lambda h: -1e9 if h.get("peak_turn") is None else float(h["peak_turn"]),
            )

        summary = {
            "version": VERSION,
            "duration_s": round(float(elapsed), 3),
            "samples": self.sample_index,
            "images_written": self.images_written,
            "images_dropped": self.images_dropped,
            "writer_error": self._writer_error,
            "attempts": self.attempts,
            "attempt_count": len(self.attempts),
            "opened_attempts": sum(
                1 for a in self.attempts if a.get("result") == "opened"
            ),
            "max_turn_session": round(self.max_turn_session, 3),
            "key_down_counts": self.key_down_counts,
            "f_holds": self.f_holds,
            "player_profile": {
                "f_press_count": len(self.f_holds),
                "median_f_hold_ms": _safe_number(self._median(hold_durations), 3),
                "mean_f_hold_ms": _safe_number(
                    sum(hold_durations) / len(hold_durations)
                    if hold_durations else None, 3
                ),
                "max_f_hold_ms": _safe_number(
                    max(hold_durations) if hold_durations else None, 3
                ),
                "median_f_interval_ms": _safe_number(self._median(self.f_intervals_ms), 3),
                "median_first_response_3deg_ms": _safe_number(
                    self._median(response_onsets), 3),
                "max_first_response_3deg_ms": _safe_number(
                    max(response_onsets) if response_onsets else None, 3),
                "median_mouse_abs_dx_between_f": _safe_number(self._median(movement_abs), 3),
                "median_mouse_net_dx_between_f": _safe_number(self._median(movement_net), 3),
                "cursor_motion_detected": bool(self.cursor_move_frames >= 3),
                "cursor_abs_dx_total": self.cursor_abs_dx,
                "cursor_net_dx_total": self.cursor_net_dx,
                "best_f_hold": best_hold,
            },
        }

        with open(os.path.join(self.folder, "summary.json"), "w", encoding="utf-8") as handle:
            json.dump(summary, handle, indent=2, ensure_ascii=False)

        profile = summary["player_profile"]
        lines = [
            "AUTOLOCKPICK PLAYER RECORDING - YHTEENVETO",
            "",
            f"Kesto: {summary['duration_s']:.2f} s",
            f"Yrityksia: {summary['attempt_count']}",
            f"Avautuneita: {summary['opened_attempts']}",
            f"Maksimi lukkopesan kaanto: {summary['max_turn_session']:.2f} deg",
            "",
            f"F-painalluksia: {profile['f_press_count']}",
            f"Mediaani F-pito: {profile['median_f_hold_ms']} ms",
            f"Keskiarvo F-pito: {profile['mean_f_hold_ms']} ms",
            f"Pisin F-pito: {profile['max_f_hold_ms']} ms",
            f"Mediaani F-testien vali: {profile['median_f_interval_ms']} ms",
            f"Mediaani +3deg vasteen alku: {profile['median_first_response_3deg_ms']} ms",
            f"Hitain havaittu +3deg vaste: {profile['max_first_response_3deg_ms']} ms",
            f"Mediaani hiiren abs X-liike F-testien valissa: {profile['median_mouse_abs_dx_between_f']}",
            f"Mediaani hiiren net X-liike F-testien valissa: {profile['median_mouse_net_dx_between_f']}",
            f"Windows-kursorin liike havaittu: {profile['cursor_motion_detected']}",
            "",
            f"Kuvia: {summary['images_written']} (pudotettu {summary['images_dropped']})",
            f"Writer error: {summary['writer_error'] or '-'}",
            "",
        ]

        if best_hold:
            lines += [
                "PARAS F-PITO",
                f"  #{best_hold['index']}",
                f"  alku: {best_hold['start_s']} s",
                f"  kesto: {best_hold['duration_ms']} ms",
                f"  start turn: {best_hold['start_turn']}",
                f"  peak turn: {best_hold['peak_turn']}",
                f"  end turn: {best_hold['end_turn']}",
                f"  mouse net edellisesta F:sta: {best_hold['mouse_net_since_previous_f']}",
                "",
            ]

        lines += [
            "TIEDOSTOT",
            "  frames/          annotoitu kuvasarja",
            "  telemetry.jsonl jokaisen capture-framen raakadata",
            "  events.jsonl    nappien/yritysten tapahtumat",
            "  summary.json    koneellisesti luettava yhteenveto",
            "  summary.txt     tama tiedosto",
            "",
            "HUOM:",
            "Jos Windows-kursorin liike on koko session ajan 0, peli kayttaa",
            "todennakoisesti raw/locked mouse -syotetta. F-, timer- ja",
            "lukkopesadata tallentuvat silti normaalisti.",
        ]

        with open(os.path.join(self.folder, "summary.txt"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")

    @property
    def elapsed(self):
        if not self.active:
            return 0.0
        return max(0.0, time.perf_counter() - self.started_perf)



# ==========================================================================
# Ajo
# ==========================================================================


class LiveRunner:
    WAITING, STARTING, SOLVING = "ODOTTAA", "ALOITTAA", "RATKAISEE"

    def __init__(self, np, mss, control, vision, run, probe_only=False):
        self.np = np
        self.mss = mss
        self.control = control
        self.vision_cfg = vision
        self.run_cfg = run
        self.probe_only = probe_only

        self.input = None if probe_only else WinInput()
        self.helper = self.input or WinInput()
        self.detector = Detector(np, vision)
        # Muisti elaa yritysten yli: sama lukko, samat mittaukset.
        self.memory = SearchMemory()
        self.controller = Controller(control, self.memory)
        self.console = Console()

        self.active = False
        self.quit = False
        self.state = self.WAITING
        self.attempts = 0
        self.opened = 0
        self.timeouts = 0
        self.status = "paina F11"
        self.last_action = Action()
        self.lost_frames = 0
        self.max_turn_seen = 0.0
        self.last_start_press = 0.0
        self.attempt_started = 0.0
        self.timer_start_value = 1.0
        self.window_title = ""
        self.last_obs = Observation()
        self.log: list[str] = []

        self.recorder = PlayerRecorder(np, image_fps=25.0)
        self.trace: list[dict] = []
        self.last_raw = None
        self.last_keys = {}
        self.last_cursor = None

    # -- apurit ------------------------------------------------------------

    def note(self, text: str) -> None:
        self.log.append(f"{time.strftime('%H:%M:%S')}  {text}")
        del self.log[:-8]

    def manual_keys(self):
        return {
            name: bool(self.helper.pressed(vk))
            for name, vk in PLAYER_KEYS.items()
        }

    def cursor_pos(self):
        getter = getattr(self.helper, "cursor_pos", None)
        if getter is None:
            return None
        try:
            return getter()
        except Exception:
            return None

    def trace_row(self, now, obs, keys, cursor):
        action = self.last_action
        self.trace.append({
            "t_perf": round(float(now), 6),
            "state": self.state,
            "active": bool(self.active),
            "recording": bool(self.recorder.active),
            "obs": {
                "ok": bool(obs.ok),
                "turn": _safe_number(obs.turn, 4),
                "timer": _safe_number(obs.timer, 5),
                "running": bool(obs.running),
            },
            "keys": dict(keys),
            "cursor": cursor,
            "vision": dict(self.detector.debug),
            "action": {
                "phase": action.phase,
                "note": action.note,
                "mouse_units": _safe_number(action.mouse_units, 3),
                "f_down": bool(action.f_down),
            },
            "controller": {
                "phase": self.controller.phase,
                "position_u": _safe_number(self.controller.position, 3),
                "target_u": _safe_number(self.controller.target, 3),
                "scan_step_u": _safe_number(self.controller.scan_step, 3),
                "probes": len(self.controller.probes),
                "turn_rate": _safe_number(self.controller.measured_turn_rate, 3),
            },
        })
        del self.trace[:-1200]

    def dump_debug(self, shot) -> None:
        folder = os.path.join(HERE, "debug")
        os.makedirs(folder, exist_ok=True)

        stamp = time.strftime("%Y%m%d_%H%M%S")
        bundle_name = f"Autolockpick_debug_{stamp}"
        temp = os.path.join(folder, bundle_name)
        zip_path = os.path.join(folder, bundle_name + ".zip")

        if os.path.exists(temp):
            shutil.rmtree(temp, ignore_errors=True)
        os.makedirs(temp, exist_ok=True)

        try:
            from mss import tools
            tools.to_png(
                shot.rgb,
                shot.size,
                output=os.path.join(temp, "ruutu_raw.png"),
            )
        except Exception as error:
            self.note(f"raw-kuvan tallennus epaonnistui: {error}")

        try:
            lines = [
                f"DEBUG {VERSION}",
                f"STATE       {self.state}",
                f"AUTO        {'ON' if self.active else 'OFF'}",
                f"RECORDER    {'ON' if self.recorder.active else 'OFF'}",
                "",
                f"BARREL      {self.last_obs.turn:.3f} deg",
                f"TIMER       {self.last_obs.timer*100:.2f}%",
                f"RUNNING     {self.last_obs.running}",
                f"MAX TURN    {self.max_turn_seen:.3f} deg",
                "",
                f"ACTION      {self.last_action.phase}",
                f"MOUSE CMD   {self.last_action.mouse_units:.3f}",
                f"F CMD       {self.last_action.f_down}",
                f"NOTE        {self.last_action.note}",
                "",
                f"POSITION    {self.controller.position:.3f} u",
                f"TARGET      {self.controller.target}",
                f"SCAN STEP   {self.controller.scan_step:.3f} u",
                f"PROBES      {len(self.controller.probes)}",
                "",
                f"PHYS F      {self.last_keys.get('F', False)}",
                f"PHYS SPACE  {self.last_keys.get('SPACE', False)}",
                f"CURSOR      {self.last_cursor}",
                "",
                f"VISION metal={self.detector.debug.get('metal', 0)}",
                f"VISION keyhole={self.detector.debug.get('keyhole', 0)}",
                f"VISION elong={self.detector.debug.get('elong', 0)}",
                f"VISION arc={self.detector.debug.get('timer', 0)}",
                f"VISION R={self.detector.debug.get('R', 0)}",
            ]

            _annotated_png(
                self.np, self.last_raw, lines,
                os.path.join(temp, "ruutu_annotated.png"),
                panel_width=500,
            )
        except Exception as error:
            self.note(f"annotated-kuvan tallennus epaonnistui: {error}")

        payload = {
            "version": VERSION,
            "tila": self.state,
            "active": self.active,
            "player_recording": self.recorder.active,
            "havainto": {
                "ok": self.last_obs.ok,
                "turn": self.last_obs.turn,
                "timer": self.last_obs.timer,
                "running": self.last_obs.running,
            },
            "physical_keys": self.last_keys,
            "cursor": self.last_cursor,
            "tunnistus": self.detector.debug,
            "vaihe": self.last_action.phase,
            "last_action": asdict(self.last_action),
            "kaantonopeus": self.controller.measured_turn_rate,
            "paikka_u": self.controller.position,
            "target_u": self.controller.target,
            "skannausvali_u": self.controller.scan_step,
            "muisti": asdict(self.memory),
            "planner": {
                "ramp_locked": self.controller.planner.ramp_locked,
                "best_units": self.controller.planner.best_units,
                "best_score": self.controller.planner.best_score,
                "step": self.controller.planner.step,
                "local_direction": self.controller.planner.local_direction,
                "responding": self.controller.planner.responding,
                "samples": self.controller.planner.samples,
            },
            "controller_private": {
                "phase_started": getattr(self.controller, "_phase_started", None),
                "last_progress": getattr(self.controller, "_last_progress", None),
                "peak": getattr(self.controller, "_peak", None),
                "settled": getattr(self.controller, "_settled", None),
                "last_value": getattr(self.controller, "_last_value", None),
                "hold_baseline": getattr(self.controller, "_hold_baseline", None),
                "hold_values": getattr(self.controller, "_hold_values", None),
                "release_ready": getattr(self.controller, "_release_ready", None),
                "forward_peak": getattr(self.controller, "_forward_peak", None),
                "forward_mark": getattr(self.controller, "_forward_mark", None),
                "last_real_progress": getattr(self.controller, "_last_real_progress", None),
                "shake_peak_response": getattr(self.controller, "_shake_peak_response", None),
                "shake_return_frames": getattr(self.controller, "_shake_return_frames", None),
            },
            "testit": [
                {
                    "paikka_u": p.position,
                    "kaanto": p.score,
                    "response": p.response,
                    "ramp": p.ramp,
                    "laji": p.kind,
                }
                for p in self.controller.probes
            ],
            "control": asdict(self.control),
            "vision": asdict(self.vision_cfg),
            "run": asdict(self.run_cfg),
            "loki": self.log,
            "trace_frames": len(self.trace),
        }

        try:
            with open(os.path.join(temp, "debug.json"), "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2, ensure_ascii=False, default=str)

            with open(os.path.join(temp, "trace.jsonl"), "w", encoding="utf-8") as handle:
                for row in self.trace:
                    handle.write(json.dumps(row, ensure_ascii=False, default=str) + "\n")

            with open(
                os.path.join(temp, "probes.csv"),
                "w", encoding="utf-8", newline=""
            ) as handle:
                writer = csv.writer(handle)
                writer.writerow(["index", "position_u", "turn_deg", "response_deg", "ramp", "kind"])
                for index, probe in enumerate(self.controller.probes, 1):
                    writer.writerow([
                        index, probe.position, probe.score, probe.response, probe.ramp, probe.kind
                    ])

            with open(os.path.join(temp, "README.txt"), "w", encoding="utf-8") as handle:
                handle.write(
                    "AUTOLOCKPICK FULL DEBUG BUNDLE\n\n"
                    "ruutu_raw.png       raakakuva lock-ROI:sta\n"
                    "ruutu_annotated.png sama kuva tarkeimmalla datalla\n"
                    "debug.json          controller/planner/memory/vision\n"
                    "trace.jsonl         noin viimeiset 1200 capture-eventtia\n"
                    "probes.csv          kaikki F-testit\n\n"
                    "Laheta tama ZIP takaisin analyysia varten.\n"
                )

            if os.path.exists(zip_path):
                os.remove(zip_path)

            with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for name in os.listdir(temp):
                    archive.write(os.path.join(temp, name), name)

            shutil.rmtree(temp, ignore_errors=True)
            self.note(f"FULL DEBUG: {os.path.basename(zip_path)}")

        except Exception as error:
            self.note(f"debugin tallennus epaonnistui: {error}")

    def hotkeys(self, now: float) -> None:
        if self.helper.pressed(VK_F9):
            self.quit = True

        if (
            self.helper.pressed(VK_F7)
            and now - getattr(self, "_last_record_toggle", 0) > 0.45
        ):
            self._last_record_toggle = now

            if self.recorder.active:
                folder = self.recorder.stop("F7")
                self.note(
                    "PLAYER RECORDING OFF: "
                    + (os.path.basename(folder) if folder else "-")
                )
                self.status = "player recording tallennettu"
            else:
                self.active = False
                self.release()
                folder = self.recorder.start()
                self.note("PLAYER RECORDING ON: " + os.path.basename(folder))
                self.status = "PLAYER RECORDING - pelaa itse"

        if (
            self.helper.pressed(VK_F8)
            and now - getattr(self, "_last_dump", 0) > 1.0
        ):
            self._last_dump = now
            self._dump_requested = True

        if (
            self.helper.pressed(VK_F11)
            and now - getattr(self, "_last_toggle", 0) > 0.4
        ):
            self._last_toggle = now

            if self.recorder.active:
                self.active = False
                self.release()
                self.note("F11 estetty: F7 PLAYER RECORDING on paalla")
                self.status = "recording paalla - F7 lopettaa"
                return

            self.active = not self.active
            if not self.active:
                self.release()
                self.status = "tauolla"
                self.note("tauko")
            else:
                self.status = "kaynnissa"
                self.note("kaynnistetty")

    def release(self) -> None:
        if self.input:
            self.input.release_all()

    def close(self) -> None:
        if self.recorder.active:
            try:
                self.recorder.stop("program_close")
            except Exception:
                pass

        for handle in {self.input, self.helper}:
            if handle:
                handle.close()

    # -- yksi yritys -------------------------------------------------------

    def begin_attempt(self, now: float) -> None:
        limit = self.run_cfg.max_attempts
        if limit and self.attempts >= limit:
            self.active = False
            self.status = f"yritysraja {limit} tayttyi"
            self.note(self.status)
            return
        self.attempts += 1
        self.controller.reset()
        self.detector.reset_attempt()
        self.max_turn_seen = 0.0
        self.attempt_started = now
        self.state = self.SOLVING
        self.note(f"yritys {self.attempts} alkoi")

    def end_attempt(self, now: float, opened: bool) -> None:
        self.release()
        self.controller.finish_attempt(opened)
        if opened:
            self.opened += 1
            self.note(f"LUKKO AUKI (yritys {self.attempts})")
        else:
            self.timeouts += 1
            self.note(f"yritys {self.attempts} paattyi ilman avausta")
        self.state = self.WAITING
        self.detector.reset_attempt()

    # -- paasilmukka -------------------------------------------------------

    def loop(self) -> None:
        period = 1.0 / max(30.0, self.run_cfg.capture_fps)

        with self.mss.mss() as capture:
            while not self.quit:
                now = time.perf_counter()
                self.hotkeys(now)

                client, title = self.helper.foreground_client()
                self.window_title = title
                if client is None:
                    self.release()
                    self.status = "peli ei ole etualalla"

                    missing_obs = Observation(stamp=now, ok=False, running=False)
                    keys = self.manual_keys()
                    cursor = self.cursor_pos()

                    self.last_keys = dict(keys)
                    self.last_cursor = cursor
                    self.last_obs = missing_obs
                    self.trace_row(now, missing_obs, keys, cursor)

                    if self.recorder.active:
                        self.recorder.observe(
                            now, None, missing_obs, {}, keys, cursor,
                            window_title=self.window_title,
                            app_state=self.state,
                            auto_active=False,
                            controller=self.controller,
                            memory=self.memory,
                            action=self.last_action,
                        )

                    self.draw(now, missing_obs)
                    time.sleep(0.15)
                    continue

                box = self.detector.roi_box(client)
                stamp = time.perf_counter()
                shot = capture.grab(box)
                raw = self.np.asarray(shot)[:, :, :3]
                obs = self.detector.read(raw, client, stamp)

                keys = self.manual_keys()
                cursor = self.cursor_pos()

                self.last_raw = raw.copy()
                self.last_keys = dict(keys)
                self.last_cursor = cursor
                self.last_obs = obs

                self.trace_row(now, obs, keys, cursor)

                if self.recorder.active:
                    self.recorder.observe(
                        now, raw, obs, dict(self.detector.debug), keys, cursor,
                        window_title=self.window_title,
                        app_state=self.state,
                        auto_active=self.active,
                        controller=self.controller,
                        memory=self.memory,
                        action=self.last_action,
                    )

                if getattr(self, "_dump_requested", False):
                    self._dump_requested = False
                    self.dump_debug(shot)

                self.step(now, obs)
                self.draw(now, obs)

                elapsed = time.perf_counter() - now
                if elapsed < period:
                    time.sleep(period - elapsed)

        self.release()

    def step(self, now: float, obs: Observation) -> None:
        if not self.active:
            self.release()
            return

        self.max_turn_seen = max(self.max_turn_seen, obs.turn) if obs.ok else self.max_turn_seen

        if not obs.ok:
            self.lost_frames += 1
            self.release()
            if self.state == self.SOLVING and self.lost_frames >= self.run_cfg.lost_frames_for_end:
                # Minipeli sulkeutui kokonaan. Onnistuessa peli sulkee ruudun;
                # aikakatkaisussa lukko jaa nakyviin ja aloituskehote palaa.
                self.end_attempt(now, self.max_turn_seen >= self.run_cfg.open_turn_degrees)
            elif self.state != self.SOLVING:
                self.state = self.WAITING
                self.status = "lukkoruutua ei nay"
            return

        self.lost_frames = 0

        if self.state in (self.WAITING, self.STARTING):
            if obs.running:
                self.begin_attempt(now)
                return
            self.state = self.STARTING
            self.status = "painetaan SPACE"
            interval = self.run_cfg.restart_key_interval_ms / 1000.0
            if not self.probe_only and now - self.last_start_press > interval:
                self.last_start_press = now
                self.input.tap(SCAN_SPACE, 70.0)
                self.note("SPACE")
            return

        # SOLVING: lukko nakyy mutta aikakaari on kadonnut -> aika loppui.
        # Onnistuminen ei nayta talta, koska silloin koko minipeli sulkeutuu.
        if not obs.running and now - self.attempt_started > 0.6:
            self.end_attempt(now, False)
            return

        action = self.controller.update(now, obs)
        self.last_action = action
        self.status = f"{action.phase}: {action.note}"

        if self.probe_only:
            return

        if action.mouse_units:
            self.input.move_mouse(action.mouse_units)
        if action.f_down:
            self.input.key_down(SCAN_F)
        else:
            self.input.key_up(SCAN_F)

    # -- nakyma ------------------------------------------------------------

    def draw(self, now: float, obs: Observation) -> None:
        cfg = self.control
        rate = self.controller.measured_turn_rate
        turn_ms = full_turn_ms(rate)
        probes = self.controller.probes
        planner = self.controller.planner
        target = self.controller.target
        target_text = "-" if target is None else f"{target:.0f}"
        rate_text = (f"{rate:.0f} deg/s, taysi {turn_ms:.0f} ms"
                     if rate and turn_ms else "ei mitattu viela")

        lines = [
            f"  AUTOLOCKPICK {VERSION}" + ("   [PROBE - ei syotteita]" if self.probe_only else ""),
            f"  {'=' * 62}",
            f"  tila       {self.state:<10} {'AJAA' if self.active else 'TAUOLLA':<8}"
            f" {self.status[:34]}",
            f"  ikkuna     {(self.window_title or '-')[:52]}",
            "",
            f"  kaanto     {obs.turn:6.1f} deg      paikka  {self.controller.position:6.0f} u"
            f"   askel {self.controller.scan_step:.0f} u",
            f"  aika       [{bar(obs.timer)}] {obs.timer * 100:5.1f} %"
            f"   {'kay' if obs.running else 'seis'}",
            "",
            f"  tavoite    {target_text:>7} u     vaihe   {self.last_action.phase}",
            f"  ramppi     {'LUKITTU' if planner.ramp_locked else 'etsinnassa':<10}"
            f"  paras   {planner.best_score:5.1f} deg"
            f"  lahiaskel {planner.step:5.0f} u",
            f"  F-testit   {len(probes):<3}"
            f"  jana kayty {self.memory.resume_units:.0f} u",
            "",
            "  sensorina vain sisemman lukkopesan OIKEA LIIKE - tarina ei kelpaa",
            f"  kaanto     {rate_text}   askel {self.controller.planner.step:.0f} u",
            "",
            f"  yrityksia  {self.attempts}   auki {self.opened}   ilman {self.timeouts}",
            (
                f"  PLAYER REC {'ON' if self.recorder.active else 'OFF':<3}"
                f"  {self.recorder.elapsed:6.1f} s"
                f"  kuvat {self.recorder.images_written}"
                f"  F {self.recorder.key_down_counts.get('F', 0)}"
            ),
            f"  tunnistus  metalli {self.detector.debug.get('metal', 0)}"
            f"  reika {self.detector.debug.get('keyhole', 0)}"
            f"  (venyma {self.detector.debug.get('elong', 0):.0f})"
            f"  kaari {self.detector.debug.get('timer', 0)}"
            f"  R {self.detector.debug.get('R', 0):.0f}",
            f"  {'-' * 62}",
        ]
        lines += ["  " + entry for entry in self.log[-6:]]
        lines += ["", "  F7 PLAYER RECORDING    F8 FULL DEBUG    F11 auto/tauko    F9 lopeta"]
        self.console.draw(lines)


# ==========================================================================
# Kaynnistys
# ==========================================================================


def run_selftest() -> int:
    import test_live
    return test_live.main()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Autolockpick live -ruudunlukija.")
    parser.add_argument("--probe", action="store_true",
                        help="nayta pelkka tunnistus, ala laheta syotteita")
    parser.add_argument("--selftest", action="store_true",
                        help="aja logiikka simulaatiota vasten")
    parser.add_argument("--fps", type=float, help="ruudunkaappauksia sekunnissa")
    parser.add_argument("--scan-step", type=float, help="skannausvali asteina")
    parser.add_argument("--save", action="store_true", help="tallenna asetukset ja lopeta")
    args = parser.parse_args(argv)

    if args.selftest:
        return run_selftest()

    control, vision, run = load_settings()
    if args.fps:
        run.capture_fps = args.fps
    if args.scan_step:
        control.sweep_step_units = args.scan_step
    if args.save:
        save_settings(control, vision, run)
        print(f"Asetukset tallennettu: {SETTINGS_FILE}")
        return 0

    if os.name != "nt":
        print("Live-ajo vaatii Windowsin. Logiikan voi testata: --selftest")
        return 2

    np, mss = ensure_packages()
    runner = LiveRunner(np, mss, control, vision, run, probe_only=args.probe)

    print(f"AUTOLOCKPICK {VERSION} kaynnistyy. Avaa pelin lukkoruutu ja paina F11.")
    time.sleep(1.0)
    try:
        runner.loop()
    except KeyboardInterrupt:
        pass
    finally:
        runner.close()
        save_settings(control, vision, run)
        print("\nLopetettu. Opittu hiiriherkkyys tallennettiin.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
