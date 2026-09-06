"""AUTOLOCKPICK LIVE - ruudunlukija SCUMin lukkominipeliin.

Ajetaan CMD-ikkunassa pelin rinnalla. Ohjelma kaappaa pelin ruudun, etsii
lukon, mittaa tiirikan kulman ja lukkopesan kaannon, ja ohjaa hiirta ja
F-nappainta kunnes lukko aukeaa.

    F11   aloita / tauota
    F9    lopeta
    F8    tallenna debug-kuva ja loki

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
import json
import math
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lockpick_control import (  # noqa: E402
    PICK_MAX,
    PICK_MIN,
    Action,
    ControlConfig,
    Controller,
    Observation,
    full_turn_ms,
    wrap_angle,
)

VERSION = "LIVE 1.0"
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
    """

    lock_radius_fraction: float = 0.139   # lukon sade / ruudun korkeus
    roi_fraction: float = 0.30            # ROI:n puolikas / ruudun korkeus
    center_offset_x: float = 0.0          # hienosaato pikseleina
    center_offset_y: float = 0.0

    metal_min: float = 55.0               # lukon metallin alin kirkkaus
    metal_max: float = 205.0
    dark_max: float = 22.0                # avaimenreian ylin kirkkaus
    bright_min: float = 185.0             # aikakaaren alin kirkkaus

    # Tiirikan punainen lakka erottuu ruosteesta ja messingista silla, etta
    # siina vihrea ja sininen ovat yhta alhaalla. Ruoste on oranssia, jolloin
    # vihrea on selvasti sinista korkeammalla. Mitattu pelin omista kuvista.
    red_excess_min: float = 18.0          # R - G
    green_blue_max: float = 10.0          # G - B
    min_keyhole_elongation: float = 4.0   # alle taman maski on saastunut

    keyhole_outer: float = 0.66           # avaimenreian haku, x R
    pick_inner: float = 0.68              # tiirikan haku, x R
    pick_outer: float = 1.95
    timer_inner: float = 1.05             # aikakaaren haku, x R
    timer_outer: float = 1.75

    min_metal_pixels: int = 2500
    min_keyhole_pixels: int = 250
    min_pick_pixels: int = 25


@dataclass
class RunConfig:
    capture_fps: float = 90.0
    open_turn_degrees: float = 55.0       # tata suurempi kaanto ennen katoamista = auki
    lost_frames_for_end: int = 6
    restart_key_interval_ms: float = 420.0
    timer_running_drop: float = 0.04      # nain paljon kaaren on kutistuttava
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

VK_F8, VK_F9, VK_F11 = 0x77, 0x78, 0x7A
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
        self.running_drop = 0.04
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

        blue = frame_bgr[:, :, 0].astype(np.float32)
        green = frame_bgr[:, :, 1].astype(np.float32)
        red = frame_bgr[:, :, 2].astype(np.float32)
        lum = 0.114 * blue + 0.587 * green + 0.299 * red

        size = frame_bgr.shape[0]
        radius_map, (xx, yy) = self._grids(size)

        nominal_r = cfg.lock_radius_fraction * client["height"]

        # 1. Lukon runko: metallinvaalea alue keskella. Ikkuna pidetaan
        # tiukkana, jottei tausta tai HUD vaanna painopistetta.
        metal = (lum > cfg.metal_min) & (lum < cfg.metal_max) & (radius_map < nominal_r * 1.15)
        metal_count = int(metal.sum())
        self.debug["metal"] = metal_count
        if metal_count < cfg.min_metal_pixels:
            return Observation(stamp=stamp, ok=False)

        # Keskipiste metallin painopisteesta, sade pinta-alasta.
        # Vain keskipiste luetaan kuvasta. Lukon koko on pelin kayttoliittymassa
        # kiinni ruudun korkeudessa eika vaihtele, joten sadetta ei arvailla:
        # automaattinen sade paisui varjoissa ja paasti niita avaimenreikaan.
        cx = float(xx[metal].mean())
        cy = float(yy[metal].mean())
        cx = max(-nominal_r * 0.5, min(nominal_r * 0.5, cx))
        cy = max(-nominal_r * 0.5, min(nominal_r * 0.5, cy))
        R = nominal_r
        local_r = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
        self.debug["R"] = R

        # 2. Avaimenreika: tumma pitkulainen alue lukon keskella.
        keyhole = (lum < cfg.dark_max) & (local_r < R * cfg.keyhole_outer)
        keyhole_count = int(keyhole.sum())
        self.debug["keyhole"] = keyhole_count
        if keyhole_count < cfg.min_keyhole_pixels:
            return Observation(stamp=stamp, ok=False)

        turn, elongation = self._principal_angle(xx[keyhole] - cx, yy[keyhole] - cy)
        self.debug["elong"] = elongation
        if elongation < cfg.min_keyhole_elongation:
            # Pyorea tumma alue ei ole avaimenreika vaan varjo tai muu kohde.
            return Observation(stamp=stamp, ok=False)
        turn = wrap_angle(turn, self.last_turn)
        turn = max(-12.0, min(105.0, turn))
        self.last_turn = turn

        # 3. Tiirikka: ainoa kylla punainen kohde lukon ymparilla.
        pick_mask = (((red - green) > cfg.red_excess_min)
                     & ((green - blue) < cfg.green_blue_max)
                     & (local_r > R * cfg.pick_inner)
                     & (local_r < R * cfg.pick_outer))
        pick_count = int(pick_mask.sum())
        self.debug["pick"] = pick_count
        if pick_count < cfg.min_pick_pixels:
            return Observation(stamp=stamp, ok=False)

        px = float(xx[pick_mask].mean() - cx)
        py = float(yy[pick_mask].mean() - cy)
        pick = math.degrees(math.atan2(px, -py))
        if not (PICK_MIN - 25.0 <= pick <= PICK_MAX + 25.0):
            return Observation(stamp=stamp, ok=False)
        pick = max(PICK_MIN, min(PICK_MAX, pick))

        # 4. Aikakaari: kirkkaat pikselit lukon ulkopuolisella renkaalla.
        ring = ((lum > cfg.bright_min)
                & (local_r > R * cfg.timer_inner)
                & (local_r < R * cfg.timer_outer))
        ring_count = int(ring.sum())
        self.debug["timer"] = ring_count
        self.timer_peak = max(self.timer_peak, float(ring_count))
        timer = ring_count / self.timer_peak if self.timer_peak > 0 else 1.0

        timer = max(0.0, min(1.0, timer))
        self.timer_history.append((stamp, timer))
        del self.timer_history[:-60]

        return Observation(stamp=stamp, ok=True, pick=pick, turn=turn,
                           timer=timer, running=self.timer_is_running())

    def timer_is_running(self) -> bool:
        """Ajastin kay, jos valkoinen kaari on kutistunut viime hetkina.

        Tama korvaa "Press Space to Start" -tekstin lukemisen: sumea
        aloitusruutu on vaikea tunnistaa, mutta kutistuva kaari ei ole.
        """
        return timer_running(self.timer_history, self.running_drop)

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
        self.controller = Controller(control)
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

    # -- apurit ------------------------------------------------------------

    def note(self, text: str) -> None:
        self.log.append(f"{time.strftime('%H:%M:%S')}  {text}")
        del self.log[:-8]

    def dump_debug(self, shot) -> None:
        folder = os.path.join(HERE, "debug")
        os.makedirs(folder, exist_ok=True)
        base = os.path.join(folder, time.strftime("live_%Y%m%d_%H%M%S"))
        try:
            from mss import tools
            tools.to_png(shot.rgb, shot.size, output=base + ".png")
        except Exception as error:
            self.note(f"kuvan tallennus epaonnistui: {error}")
        payload = {
            "version": VERSION,
            "tila": self.state,
            "havainto": {"ok": self.last_obs.ok, "pick": self.last_obs.pick,
                         "turn": self.last_obs.turn, "timer": self.last_obs.timer,
                         "running": self.last_obs.running},
            "tunnistus": self.detector.debug,
            "vaihe": self.last_action.phase,
            "kaantonopeus": self.controller.measured_turn_rate,
            "reunat": [self.controller.edge_low, self.controller.edge_high],
            "testit": [{"kulma": p.pick, "kaanto": p.score, "laji": p.kind}
                       for p in self.controller.probes],
            "control": asdict(self.control),
            "vision": asdict(self.vision_cfg),
            "loki": self.log,
        }
        try:
            with open(base + ".json", "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2, ensure_ascii=False, default=str)
            self.note(f"debug tallennettu: {os.path.basename(base)}")
        except Exception as error:
            self.note(f"debugin tallennus epaonnistui: {error}")

    def hotkeys(self, now: float) -> None:
        if self.helper.pressed(VK_F9):
            self.quit = True
        if self.helper.pressed(VK_F8) and now - getattr(self, "_last_dump", 0) > 1.0:
            self._last_dump = now
            self._dump_requested = True
        if self.helper.pressed(VK_F11) and now - getattr(self, "_last_toggle", 0) > 0.4:
            self._last_toggle = now
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
        self.detector.running_drop = self.run_cfg.timer_running_drop

        with self.mss.mss() as capture:
            while not self.quit:
                now = time.perf_counter()
                self.hotkeys(now)

                client, title = self.helper.foreground_client()
                self.window_title = title
                if client is None:
                    self.release()
                    self.status = "peli ei ole etualalla"
                    self.draw(now, Observation())
                    time.sleep(0.15)
                    continue

                box = self.detector.roi_box(client)
                stamp = time.perf_counter()
                shot = capture.grab(box)
                raw = self.np.asarray(shot)[:, :, :3]
                obs = self.detector.read(raw, client, stamp)
                if getattr(self, "_dump_requested", False):
                    self._dump_requested = False
                    self.dump_debug(shot)
                self.last_obs = obs

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

        # SOLVING
        if not obs.running and now - self.attempt_started > 0.6:
            self.end_attempt(now, self.max_turn_seen >= self.run_cfg.open_turn_degrees)
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
        target_text = "-" if target is None else f"{target:+.1f}"
        rate_text = (f"{rate:.0f} deg/s, taysi {turn_ms:.0f} ms"
                     if rate and turn_ms else "ei mitattu viela")

        lines = [
            f"  AUTOLOCKPICK {VERSION}" + ("   [PROBE - ei syotteita]" if self.probe_only else ""),
            f"  {'=' * 62}",
            f"  tila       {self.state:<10} {'AJAA' if self.active else 'TAUOLLA':<8}"
            f" {self.status[:34]}",
            f"  ikkuna     {(self.window_title or '-')[:52]}",
            "",
            f"  tiirikka   {obs.pick:+7.1f} deg    kaanto  {obs.turn:6.1f} deg",
            f"  aika       [{bar(obs.timer)}] {obs.timer * 100:5.1f} %"
            f"   {'kay' if obs.running else 'seis'}",
            "",
            f"  tavoite    {target_text:>7}       vaihe   {self.last_action.phase}",
            f"  ramppi     {'lukittu' if planner.ramp_locked else 'etsinnassa':<10}"
            f"  paras   {planner.best_score:5.1f} deg"
            f"  askel {planner.step:5.2f}",
            f"  F-testit   {len(probes):<3}",
            "",
            f"  herkkyys   {cfg.degrees_per_mouse_unit:.4f} deg/yksikko"
            f"  {'(mitattu)' if self.controller.sensitivity.confident else '(oletus)'}",
            f"  kaanto     {rate_text}   katto {cfg.maximum_hold_ms:.0f} ms",
            "",
            f"  yrityksia  {self.attempts}   auki {self.opened}   ilman {self.timeouts}",
            f"  tunnistus  metal {self.detector.debug.get('metal', 0)}"
            f"  reika {self.detector.debug.get('keyhole', 0)}"
            f"  tiirikka {self.detector.debug.get('pick', 0)}"
            f"  kaari {self.detector.debug.get('timer', 0)}"
            f"  R {self.detector.debug.get('R', 0):.0f}",
            f"  {'-' * 62}",
        ]
        lines += ["  " + entry for entry in self.log[-6:]]
        lines += ["", "  F11 aloita/tauota    F9 lopeta    F8 debug"]
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
        control.scan_step_degrees = args.scan_step
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
