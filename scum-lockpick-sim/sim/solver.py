"""Autolockpick-ohjain simulaatiota varten.

Vastaa Porvarinen Autolockpick 1.8 BAREBONES -helperin logiikkaa:

    global scan  ->  yksisuuntainen pyyhkaisy, F-testi joka pisteessa
    ramp lock    ->  ensimmainen jatkuva kaanto lukitsee paikallisen haun
    local climb  ->  parempi vaste jatkaa samaan suuntaan,
                     huonompi vaste vaihtaa suunnan ja puolittaa askelen

Simulaatiossa on lisaksi mallinnettu ne asiat jotka oikeassa helperissa
ratkaisevat onnistumisen mutta joita ei nay pelikuvassa:

    naytonlukuviive      helperi nakee pelin tilan aina myohassa
    ruudunlukuvali       tilaa ei paivity jatkuvasti vaan ruutu kerrallaan
    hiiripulssin katto   yksi SendInput-pulssi siirtaa tiirikkaa rajallisesti

Nama kolme maaraavat, montako F-testia 2.75-4.25 sekuntiin oikeasti mahtuu.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field

from lockpick_model import PICK_MAX, PICK_MIN

# --------------------------------------------------------------------------
# Ohjaimen asetukset. Nimet vastaavat helperin asetukset.json-avaimia.
# --------------------------------------------------------------------------


@dataclass
class SolverConfig:
    scan_order: str = "left-to-right"     # left-to-right | center-out | from-current | random

    scan_step_degrees: float = 6.0
    climb_step_degrees: float = 2.5
    minimum_climb_step_degrees: float = 0.08
    movement_found_degrees: float = 3.0
    near_open_degrees: float = 88.0

    # hiiri
    degrees_per_mouse_unit: float = 0.035
    scan_mouse_max_units_per_pulse: float = 28.0
    ramp_mouse_max_units_per_pulse: float = 12.0
    mouse_settle_ms: float = 30.0

    # F-ajoitus
    scan_hold_ms: float = 55.0
    ramp_hold_ms: float = 260.0
    stall_release_ms: float = 30.0        # kuinka kauan pysahtynytta pesaa vasten viela painetaan
    maximum_f_hold_ms: float = 700.0      # ehdoton katto, ei katkaise kasvavaa kaantoa
    finish_stall_ms: float = 260.0        # kuinka kauan lahes-auki-kohtaa yritetaan
    release_settle_ms: float = 30.0
    release_turn_threshold: float = 2.0

    # nako
    vision_latency_ms: float = 50.0
    vision_frame_ms: float = 8.3
    vision_noise_degrees: float = 0.8
    vision_quantum_degrees: float = 0.5   # kulmanlukutarkkuus yhdesta ruutukaappauksesta

    def scan_speed(self) -> float:
        """Tiirikan efektiivinen skannausnopeus, astetta/s."""
        return self.scan_mouse_max_units_per_pulse * self.degrees_per_mouse_unit / (
            self.mouse_settle_ms / 1000.0
        )

    def ramp_speed(self) -> float:
        return self.ramp_mouse_max_units_per_pulse * self.degrees_per_mouse_unit / (
            self.mouse_settle_ms / 1000.0
        )

    def effective_min_hold_ms(self) -> float:
        """Lyhyin F-pito josta liike ehtii nakya naytolta luettuna."""
        return max(self.scan_hold_ms, self.vision_latency_ms + 2.0 * self.vision_frame_ms)


class Vision:
    """Viivastetty ja naytteistetty havainto pelin tilasta."""

    def __init__(self, cfg: SolverConfig, rng: random.Random):
        self.cfg = cfg
        self.rng = rng
        self.buffer: list[tuple[float, dict]] = []
        self.latest: dict | None = None
        self.next_sample_at = 0.0

    def push(self, t: float, snapshot: dict) -> None:
        self.buffer.append((t, dict(snapshot)))

    def observe(self, t: float) -> dict | None:
        if t < self.next_sample_at:
            return self.latest

        self.next_sample_at = t + self.cfg.vision_frame_ms / 1000.0
        cutoff = t - self.cfg.vision_latency_ms / 1000.0

        chosen = None
        keep_from = 0
        for i, (stamp, snap) in enumerate(self.buffer):
            if stamp <= cutoff:
                chosen = snap
                keep_from = i
            else:
                break
        self.buffer = self.buffer[keep_from:]

        if chosen is None:
            return self.latest

        noisy = dict(chosen)
        measured = chosen["turn"] + self.rng.gauss(0.0, self.cfg.vision_noise_degrees)
        quantum = max(1e-6, self.cfg.vision_quantum_degrees)
        noisy["turn"] = max(0.0, round(measured / quantum) * quantum)
        self.latest = noisy
        return noisy


class Planner:
    """Barebones-hakusaanto: yksisuuntainen skannaus, sitten paikallinen kiipeily."""

    def __init__(self, cfg: SolverConfig, start_pick: float, rng: random.Random):
        self.cfg = cfg
        self.rng = rng
        self.start_pick = start_pick

        self.samples: list[tuple[float, float]] = []
        self.ramp_locked = False
        self.best_x: float | None = None
        self.best_score = 0.0
        self.local_direction = 1
        self.step = cfg.climb_step_degrees

        self._scan_index = 0
        self._scan_direction = 1
        self._scan_points = self._build_scan_points()

    def _build_scan_points(self) -> list[float]:
        step = self.cfg.scan_step_degrees
        order = self.cfg.scan_order

        if order == "left-to-right":
            pts, x = [], PICK_MIN
            while x <= PICK_MAX + 1e-9:
                pts.append(min(PICK_MAX, x))
                x += step
            return pts

        if order == "center-out":
            pts = [0.0]
            k = 1
            while True:
                offset = k * step
                added = False
                if offset <= PICK_MAX:
                    pts.append(offset)
                    added = True
                if -offset >= PICK_MIN:
                    pts.append(-offset)
                    added = True
                if not added:
                    break
                k += 1
            return pts

        if order == "from-current":
            # Aloita siita missa tiirikka nyt on, jatka lahimpaan reunaan
            # pain ja palaa vasta sitten toiselle puolelle.
            direction = 1 if self.start_pick <= 0 else -1
            pts, x = [], self.start_pick
            while PICK_MIN <= x <= PICK_MAX:
                pts.append(x)
                x += direction * step
            x = self.start_pick - direction * step
            while PICK_MIN <= x <= PICK_MAX:
                pts.append(x)
                x -= direction * step
            return pts

        # random
        pts, x = [], PICK_MIN
        while x <= PICK_MAX + 1e-9:
            pts.append(min(PICK_MAX, x))
            x += step
        self.rng.shuffle(pts)
        return pts

    def record(self, x: float, score: float) -> None:
        score = max(0.0, float(score))
        self.samples.append((float(x), score))

        if not self.ramp_locked:
            if score >= self.cfg.movement_found_degrees:
                self.ramp_locked = True
                self.best_x = x
                self.best_score = score
                self.local_direction = self._scan_direction
                self.step = self.cfg.climb_step_degrees
            return

        if score > self.best_score + 0.15:
            self.best_x = x
            self.best_score = score
            if score >= 84.0:
                self.step = min(self.step, 0.35)
            elif score >= 72.0:
                self.step = min(self.step, 0.75)
            elif score >= 55.0:
                self.step = min(self.step, 1.40)
            return

        self.local_direction *= -1
        self.step = max(self.cfg.minimum_climb_step_degrees, self.step * 0.5)

    def next_target(self) -> float | None:
        if not self.ramp_locked:
            if self._scan_index >= len(self._scan_points):
                return None
            x = self._scan_points[self._scan_index]
            if self._scan_index > 0:
                previous = self._scan_points[self._scan_index - 1]
                self._scan_direction = 1 if x >= previous else -1
            self._scan_index += 1
            return x

        if self.best_x is None:
            return None

        target = self.best_x + self.local_direction * self.step
        return min(PICK_MAX, max(PICK_MIN, target))


@dataclass
class ProbeEvent:
    t_start: float
    t_end: float
    pick: float
    score: float
    ramp: bool


@dataclass
class AttemptLog:
    probes: list[ProbeEvent] = field(default_factory=list)
    sweet_spot: float = 0.0
    result: str = ""
    seconds: float = 0.0
    ramp_found_at: float | None = None


class AutoLockpick:
    """Ohjaimen tilakone. Ajetaan pienella aika-askeleella yhden yrityksen yli."""

    TRAVEL, HOLD, RELEASE, FINISH, IDLE = "travel", "hold", "release", "finish", "idle"

    def __init__(self, cfg: SolverConfig, rng: random.Random, start_pick: float = 0.0):
        self.cfg = cfg
        self.rng = rng
        self.vision = Vision(cfg, rng)
        self.planner = Planner(cfg, start_pick, rng)

        self.pick = start_pick
        self.target = start_pick
        self.f_down = False
        self.phase = self.TRAVEL
        self.log = AttemptLog()

        self._next_pulse_at = 0.0
        self._phase_started = 0.0
        self._peak = 0.0
        self._probe_start = 0.0
        self._have_target = False
        self._release_ready_at: float | None = None
        self._last_progress = 0.0

    # ----------------------------------------------------------------------

    def _pulse_limit(self) -> float:
        units = (
            self.cfg.ramp_mouse_max_units_per_pulse
            if self.planner.ramp_locked
            else self.cfg.scan_mouse_max_units_per_pulse
        )
        return units * self.cfg.degrees_per_mouse_unit

    def _min_hold_ms(self) -> float:
        """Lyhyin pito ennen kuin havaintoon voi luottaa."""
        floor = self.cfg.effective_min_hold_ms()
        if self.planner.ramp_locked:
            return min(self.cfg.maximum_f_hold_ms, max(floor, self.cfg.ramp_hold_ms * 0.35))
        return min(self.cfg.maximum_f_hold_ms, floor)

    def _take_target(self, t: float) -> bool:
        nxt = self.planner.next_target()
        if nxt is None:
            self.phase = self.IDLE
            self.f_down = False
            return False
        self.target = nxt
        self._have_target = True
        self.phase = self.TRAVEL
        self._phase_started = t
        return True

    # ----------------------------------------------------------------------

    def step(self, t: float, dt: float, snapshot: dict) -> tuple[float, bool]:
        """Palauttaa (tiirikan tavoitekulma, F pohjassa)."""
        self.vision.push(t, snapshot)
        obs = self.vision.observe(t)

        if not self._have_target and self.phase == self.TRAVEL:
            if not self._take_target(t):
                return self.pick, False

        if self.phase == self.TRAVEL:
            self.f_down = False
            if t >= self._next_pulse_at:
                limit = self._pulse_limit()
                delta = self.target - self.pick
                if abs(delta) <= max(0.15, limit * 0.02):
                    self.pick = self.target
                    self.phase = self.HOLD
                    self._phase_started = t
                    self._probe_start = t
                    self._peak = 0.0
                    self._last_progress = t
                else:
                    stepped = max(-limit, min(limit, delta))
                    self.pick += stepped
                    self._next_pulse_at = t + self.cfg.mouse_settle_ms / 1000.0

        elif self.phase == self.HOLD:
            self.f_down = True
            if obs is not None and obs["turn"] > self._peak + 0.4:
                self._peak = obs["turn"]
                self._last_progress = t
            elif obs is not None:
                self._peak = max(self._peak, obs["turn"])

            elapsed_ms = (t - self._phase_started) * 1000.0
            stalled_ms = (t - self._last_progress) * 1000.0

            # Kasvavaa kaantoa ei koskaan katkaista. F vapautetaan vasta kun
            # pesa on pysahtynyt: juuri tama on "feathering" pelaajien ohjeissa.
            release = (
                elapsed_ms >= self._min_hold_ms()
                and stalled_ms >= self.cfg.stall_release_ms
            ) or elapsed_ms >= self.cfg.maximum_f_hold_ms

            if self._peak >= self.cfg.near_open_degrees:
                self.phase = self.FINISH
                self._phase_started = t
                self._last_progress = t
            elif release:
                self.phase = self.RELEASE
                self._phase_started = t
                self._release_ready_at = None
                self.f_down = False
                self.log.probes.append(
                    ProbeEvent(
                        t_start=self._probe_start,
                        t_end=t,
                        pick=self.pick,
                        score=self._peak,
                        ramp=self.planner.ramp_locked,
                    )
                )
                was_locked = self.planner.ramp_locked
                self.planner.record(self.pick, self._peak)
                if not was_locked and self.planner.ramp_locked and self.log.ramp_found_at is None:
                    self.log.ramp_found_at = t

        elif self.phase == self.RELEASE:
            self.f_down = False
            settled = obs is not None and obs["turn"] <= self.cfg.release_turn_threshold
            if settled and self._release_ready_at is None:
                self._release_ready_at = t + self.cfg.release_settle_ms / 1000.0
            if self._release_ready_at is not None and t >= self._release_ready_at:
                self._have_target = False
                self.phase = self.TRAVEL
                self._next_pulse_at = t
                self._take_target(t)

        elif self.phase == self.FINISH:
            # Lahes taysi kaanto: F jaa pohjaan. Jos pesa kuitenkin pysahtyy,
            # kohta ei ollut ydin, ja jatkuva painaminen vain rikkoisi tiirikan.
            self.f_down = True
            if obs is not None and obs["turn"] > self._peak + 0.4:
                self._peak = obs["turn"]
                self._last_progress = t
            if (t - self._last_progress) * 1000.0 >= self.cfg.finish_stall_ms:
                self.log.probes.append(
                    ProbeEvent(
                        t_start=self._probe_start,
                        t_end=t,
                        pick=self.pick,
                        score=self._peak,
                        ramp=True,
                    )
                )
                self.planner.record(self.pick, self._peak)
                self.phase = self.RELEASE
                self._phase_started = t
                self._release_ready_at = None
                self.f_down = False

        elif self.phase == self.IDLE:
            self.f_down = False

        return self.pick, self.f_down
