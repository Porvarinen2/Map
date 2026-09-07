"""Mitattuun dataan kalibroitu lukkomalli ohjaimen testaamiseen.

Malli on sovitettu kayttajan omaan nauhoitukseen
(live/traces/debug_20260907_015126). Sovituksen tarkistus:

  yritys 12 (onnistui)
    900 u   -> vaste  4.0 deg     mallissa d=58 -> ~5 deg
    952 u   -> kaanto 88.6 deg    mallissa d=6  -> ~86 deg
    957 u   -> AUKI              mallissa d=1  -> ydin, aukeaa

  yritys 10 (epaonnistui)
    3000 u  -> vaste  5.5 deg     mallissa d=60 -> ~4 deg
    3052 u  -> kaanto 83.1 deg    mallissa d=8  -> ~84 deg

Eli sweetspotin ymparilla vaste nousee hyvin jyrkasti: 60 yksikon paassa
pesa liikahtaa vain muutaman asteen, 8 yksikon paassa se kaantyy 84
asteeseen, ja vain muutaman yksikon paassa lukko aukeaa.

Yksikot ovat hiiriyksikkoja, kulmat asteita, ajat sekunteja.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass


# Mitatut vakiot -----------------------------------------------------------

SPAN_UNITS = 3600.0        # koko jana vasemmasta reunasta oikeaan
ZONE_HALF_UNITS = 70.0     # tata kauempana vaste on kaytannossa nolla
CORE_HALF_UNITS = 3.0      # tata lahempana lukko aukeaa
# Vaste on logistinen: se romahtaa jyrkasti noin 35 yksikon etaisyydella.
# Sovitettu pisteisiin d=58 -> 4 deg, d=8 -> 83 deg, d=6 -> 88.6 deg.
RAMP_MIDPOINT_UNITS = 35.0
RAMP_WIDTH_UNITS = 8.0
OPEN_ANGLE = 90.0
CLIMB_RATE = 139.0         # astetta/s, mitattu nauhoituksesta
FALL_RATE = 135.0          # astetta/s, mitattu putoamisesta 83 -> 73.5
REST_ANGLE = 1.8           # levossa oleva lukema
ANGLE_NOISE = 0.6          # kulmanlukukohina


@dataclass
class SimConfig:
    span_units: float = SPAN_UNITS
    zone_half: float = ZONE_HALF_UNITS
    core_half: float = CORE_HALF_UNITS
    ramp_midpoint: float = RAMP_MIDPOINT_UNITS
    ramp_width: float = RAMP_WIDTH_UNITS
    climb_rate: float = CLIMB_RATE
    fall_rate: float = FALL_RATE
    attempt_seconds: float = 3.2       # nauhoituksessa 2.5 - 3.9 s
    latency_ms: float = 50.0
    frame_ms: float = 30.0             # nauhoituksen kaappausvali
    noise_degrees: float = ANGLE_NOISE
    quantum_degrees: float = 0.1
    require_still_for_turn: bool = False   # kaantyyko pesa myos liikkeessa
    # Kun pesa kaantyy, tiirikka kaantyy sen mukana ja osumakohta siirtyy
    # hieman. Nauhoituksessa nakyi juuri tama: pesa jumitti 89 asteeseen,
    # ja vasta F:n irrotus + pieni nykays vei sen 91.8 asteeseen ja lukko
    # aukesi. Nollana ilmiota ei ole; testimatriisissa sita kokeillaan.
    drift_units: float = 0.0


class LockAttempt:
    """Yksi yritys. Ohjain kertoo hiiriyksikot ja F:n tilan."""

    def __init__(self, cfg: SimConfig, rng: random.Random, sweet: float | None = None):
        self.cfg = cfg
        self.rng = rng
        self.sweet = rng.uniform(0.0, cfg.span_units) if sweet is None else sweet

        self.time = 0.0
        self.position = 0.0        # hiiriyksikkoa vasemmasta reunasta
        self.angle = REST_ANGLE
        self.opened = False
        self.timed_out = False
        self.f_seconds = 0.0
        # Tiirikan kuluminen: aika, jonka F on pohjassa kohdassa joka ei
        # anna enempaa periksi. Juuri se kuluttaa tiirikkaa pelissa -
        # kayttaja: "sen lockpickin health laskee" jo rampin etsinnassa.
        # Nouseva kaanto ei kuluta: silloin lukko antaa periksi.
        self.stalled_seconds = 0.0
        # Pisin YHTAJAKSOINEN puristus antamatonta kohtaa vasten. Jos peli
        # rankaisee nimenomaan vaantamisesta eika kokonaisajasta, tama on
        # se mittari joka rikkoo tiirikan. Pelaajan omassa nauhoituksessa
        # pisin painallus oli 732 ms.
        self.stall_run = 0.0
        self.max_stall_run = 0.0
        self.moving = False

    @property
    def finished(self) -> bool:
        return self.opened or self.timed_out

    def max_angle_at(self, position: float, angle: float | None = None) -> float:
        sweet = self.sweet
        if self.cfg.drift_units:
            turned = self.angle if angle is None else angle
            sweet += self.cfg.drift_units * (turned / OPEN_ANGLE)
        d = abs(position - sweet)
        if d <= self.cfg.core_half:
            return OPEN_ANGLE
        if d >= self.cfg.zone_half:
            return REST_ANGLE
        z = (d - self.cfg.ramp_midpoint) / max(1e-6, self.cfg.ramp_width)
        z = max(-30.0, min(30.0, z))
        return REST_ANGLE + (OPEN_ANGLE - 2.0 - REST_ANGLE) / (1.0 + math.exp(z))

    def step(self, dt: float, mouse_units: float, f_down: bool) -> None:
        if self.finished:
            return

        self.moving = abs(mouse_units) > 1e-9
        # Seina: vasemmalle ei paase alle nollan, oikealle ei yli janan.
        self.position = min(self.cfg.span_units, max(0.0, self.position + mouse_units))
        self.time += dt

        turning = f_down and not (self.cfg.require_still_for_turn and self.moving)
        if turning:
            self.f_seconds += dt
            target = self.max_angle_at(self.position)
            if self.angle < target:
                self.angle = min(target, self.angle + self.cfg.climb_rate * dt)
            elif self.angle > target:
                self.angle = max(target, self.angle - self.cfg.fall_rate * dt)
            # Jumissa = pesa on jo antanut kaiken minka tassa kohdassa antaa.
            if abs(self.angle - target) < 0.5 and target < OPEN_ANGLE - 0.5:
                self.stalled_seconds += dt
                self.stall_run += dt
                self.max_stall_run = max(self.max_stall_run, self.stall_run)
            else:
                self.stall_run = 0.0
            if self.angle >= OPEN_ANGLE - 0.5:
                self.opened = True
                return
        else:
            self.stall_run = 0.0           # F ylhaalla = tiirikka lepaa
            self.angle = max(REST_ANGLE, self.angle - self.cfg.fall_rate * dt)

        if self.time >= self.cfg.attempt_seconds:
            self.timed_out = True


class SimulatedScreen:
    """Viivastetty ja kohinainen havainto, kuten oikea ruudunluku."""

    def __init__(self, attempt: LockAttempt, rng: random.Random, cfg: SimConfig):
        self.attempt = attempt
        self.rng = rng
        self.cfg = cfg
        self.buffer: list[tuple[float, float]] = []
        self.latest = None
        self.next_sample = 0.0

    def read(self, now: float):
        from lockpick_control import Observation

        self.buffer.append((now, self.attempt.angle))
        if self.latest is not None and now < self.next_sample:
            return self.latest
        self.next_sample = now + self.cfg.frame_ms / 1000.0

        cutoff = now - self.cfg.latency_ms / 1000.0
        chosen, keep = None, 0
        for i, (stamp, angle) in enumerate(self.buffer):
            if stamp <= cutoff:
                chosen, keep = (stamp, angle), i
            else:
                break
        if chosen is None:
            # Ensimmaisten millisekuntien aikana yhtaan riittavan vanhaa
            # kehysta ei viela ole. Silloin ruudulla ei ole mitaan luettavaa
            # - ei kohinatonta vakiolukemaa, joka vaaristaisi ohjaimen
            # kohinamittausta.
            return self.latest or Observation(stamp=-1.0, ok=False)
        self.buffer = self.buffer[keep:]

        stamp, angle = chosen
        noisy = angle + self.rng.gauss(0.0, self.cfg.noise_degrees)
        q = max(1e-6, self.cfg.quantum_degrees)
        self.latest = Observation(stamp=stamp, ok=True,
                                  turn=max(0.0, round(noisy / q) * q),
                                  timer=1.0 - self.attempt.time / self.cfg.attempt_seconds,
                                  running=True)
        return self.latest


def run_attempt(controller_factory, cfg: SimConfig, rng: random.Random,
                sweet: float | None = None, dt: float = 0.004, trace: bool = False,
                memory=None):
    """Ajaa yhden yrityksen. Palauttaa (attempt, controller, trace).

    memory jaetaan yritysten kesken samoin kuin oikeassa ajossa: ohjain
    muistaa mihin asti jana on pyyhkaisty ja mitka olosuhteet se mittasi.
    Ilman jakamista muisti ei nakyisi mittauksissa lainkaan.
    """
    attempt = LockAttempt(cfg, rng, sweet)
    controller = controller_factory()
    if memory is not None:
        controller.memory = memory
    screen = SimulatedScreen(attempt, rng, cfg)

    now = 0.0
    log = []
    guard = int(cfg.attempt_seconds / dt) + 400
    for _ in range(guard):
        if attempt.finished:
            break
        obs = screen.read(now)
        action = controller.update(now, obs)
        if trace:
            log.append((now, attempt.angle, attempt.position, action.phase,
                        action.f_down, action.mouse_units))
        attempt.step(dt, action.mouse_units, action.f_down)
        now += dt

    controller.finish_attempt(attempt.opened)
    return attempt, controller, log


def run_session(controller_factory, cfg: SimConfig, rng: random.Random,
                max_attempts: int = 6, stable_sweet: bool = False):
    from lockpick_control import SearchMemory

    sweet = rng.uniform(0.0, cfg.span_units) if stable_sweet else None
    memory = SearchMemory()
    wear = f_time = clock = worst = 0.0
    for n in range(1, max_attempts + 1):
        attempt, controller, _ = run_attempt(controller_factory, cfg, rng, sweet,
                                             memory=memory)
        wear += attempt.stalled_seconds
        worst = max(worst, attempt.max_stall_run)
        f_time += attempt.f_seconds
        clock += attempt.time
        if attempt.opened:
            return True, n, attempt.time, wear, f_time / max(1e-9, clock), worst
    return False, max_attempts, 0.0, wear, f_time / max(1e-9, clock), worst


def batch(controller_factory, cfg: SimConfig | None = None, sessions: int = 300,
          seed: int = 20260907, max_attempts: int = 6, stable_sweet: bool = False):
    cfg = cfg or SimConfig()
    rng = random.Random(seed)
    opened = first = 0
    attempts, seconds, stalled, duties, worsts = [], [], [], [], []
    for _ in range(sessions):
        ok, n, t, wear, duty, worst = run_session(controller_factory, cfg, rng,
                                                  max_attempts, stable_sweet)
        stalled.append(wear)
        duties.append(duty)
        worsts.append(worst)
        if ok:
            opened += 1
            attempts.append(n)
            seconds.append(t)
            if n == 1:
                first += 1
    mean = lambda xs: sum(xs) / len(xs) if xs else float("nan")
    return {
        "sessions": sessions,
        "success": opened / sessions,
        "first": first / sessions,
        "attempts": mean(attempts),
        "seconds": mean(seconds),
        # Kulumismittari: kuinka monta sekuntia F oli pohjassa antamatonta
        # kohtaa vasten ennen kuin lukko aukesi. Talla mitataan sita, mika
        # pelissa rikkoo tiirikat.
        "stalled": mean(stalled),
        "duty": mean(duties),
        # Pisin yhtajaksoinen vaanto antamatonta kohtaa vasten.
        "worst_hold": mean(worsts),
    }
