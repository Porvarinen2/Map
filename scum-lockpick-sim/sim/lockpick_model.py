"""SCUM-tyyppisen lukkominipelin fysiikkamalli.

Malli on tarkoituksella pieni ja deterministinen, jotta samaa logiikkaa voi
ajaa seka taalla Pythonissa etta selainsimulaatiossa (web/scum_lockpick_sim.html).

Mittayksikot:
    kulmat  asteina, 0 = tiirikka suoraan ylos
    ajat    sekunteina
    kuluma  0..100 (100 = tiirikka poikki)

Mika on lahteista ja mika on omaa arviota, on kuvattu docs/MEKANIIKKA.md:ssa.
Lyhyesti: 2.75 s perusaika ja enintaan +1.5 s thievery-bonus tulevat pelin
patch noteista. Sweetspotin leveys, ramppikayran muoto, pesan kaantonopeus ja
kulumisnopeudet ovat taman simulaation kalibrointia, eivat pelin lahdekoodia.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

# --------------------------------------------------------------------------
# Vakiot
# --------------------------------------------------------------------------

# Tiirikan aariasennot. Mitattu pelin omista ruutukaappauksista
# (live/references, live/test_vision.py): vasen -62, oikea +65 astetta.
PICK_MIN = -63.0
PICK_MAX = 63.0
OPEN_TURN = 90.0          # lukkopesan kaanto joka avaa lukon
OPEN_EPSILON = 0.5        # kuinka lahella 90:aa riittaa

TURN_RATE = 260.0         # pesan kaantonopeus F pohjassa, astetta/s
RETURN_RATE = 520.0       # pesan palautumisnopeus F ylhaalla, astetta/s

BASE_SECONDS = 2.75       # pelin perusaika yhdelle yritykselle
SKILL_BONUS_SECONDS = [0.0, 0.5, 1.0, 1.5]     # thievery 0..3
SKILL_WIDTH_MULT = [1.0, 1.15, 1.32, 1.5]      # sweetspotin leveyskerroin
SKILL_WEAR_MULT = [1.0, 0.90, 0.82, 0.72]      # kulumisen kerroin

SKILL_NAMES = ["ei taitoa", "basic", "medium", "advanced"]


@dataclass(frozen=True)
class LockTier:
    """Yhden lukkotyypin vaikeusparametrit."""

    key: str
    name: str
    zone_half: float      # koko palautealueen puolikas leveys asteina
    core_half: float      # avaavan ytimen puolikas leveys asteina
    give_max: float       # suurin osittainen kaanto alueella ytimen ulkopuolella
    wear_rate: float      # kuluma/s kun F on pohjassa jumittunutta kohtaa vasten


# Palautealueella pesa antaa vain hieman periksi ("the lock moves a bit more
# than normal"). Taysi 90 asteen kaanto tulee vasta ytimesta. Vaikeampi lukko
# antaa seka kapeamman ytimen etta heikomman vihjeen.
# Vaikeampi lukko on kolmella tavalla tiukempi: ydin on kapeampi, vihjeen
# antava reuna on kapeampi ja itse vihje on heikompi.
LOCK_TIERS = {
    "rusted": LockTier("rusted", "Rusted", 9.20, 3.20, 34.0, 20.0),
    "basic": LockTier("basic", "Basic", 7.70, 2.20, 30.0, 27.0),
    "medium": LockTier("medium", "Medium", 6.40, 1.40, 24.0, 37.0),
    "enforced": LockTier("enforced", "Enforced", 4.85, 0.85, 18.0, 50.0),
}

TIER_ORDER = ["rusted", "basic", "medium", "enforced"]


@dataclass(frozen=True)
class PickTool:
    key: str
    name: str
    wear_mult: float


PICK_TOOLS = {
    "improvised": PickTool("improvised", "Improvised lockpick", 1.70),
    "lockpick": PickTool("lockpick", "Lockpick", 1.00),
    "advanced": PickTool("advanced", "Advanced lockpick", 0.62),
}


@dataclass
class LockConfig:
    tier: str = "basic"
    skill: int = 1
    tool: str = "lockpick"
    reroll_sweet_spot: bool = True    # arvotaanko sweetspot uudelleen joka yritykselle
    jiggle_wear_mult: float = 0.5     # lisakuluma kun hiiri liikkuu F pohjassa

    def tier_data(self) -> LockTier:
        return LOCK_TIERS[self.tier]

    def tool_data(self) -> PickTool:
        return PICK_TOOLS[self.tool]

    @property
    def zone_half(self) -> float:
        return self.tier_data().zone_half * SKILL_WIDTH_MULT[self.skill]

    @property
    def core_half(self) -> float:
        return self.tier_data().core_half * SKILL_WIDTH_MULT[self.skill]

    @property
    def attempt_seconds(self) -> float:
        return BASE_SECONDS + SKILL_BONUS_SECONDS[self.skill]

    @property
    def wear_rate(self) -> float:
        return (
            self.tier_data().wear_rate
            * self.tool_data().wear_mult
            * SKILL_WEAR_MULT[self.skill]
        )


class LockAttempt:
    """Yksi yritys: ajastin kay, pesa kaantyy, tiirikka kuluu.

    Ohjain (solver.py tai ihminen) kutsuu step():a ja kertoo joka askeleella
    haluamansa tiirikan kulman ja onko F pohjassa.
    """

    def __init__(self, cfg: LockConfig, rng: random.Random, sweet_spot: float | None = None):
        self.cfg = cfg
        self.rng = rng

        if sweet_spot is None:
            margin = cfg.zone_half * 0.25
            sweet_spot = rng.uniform(PICK_MIN + margin, PICK_MAX - margin)
        self.sweet_spot = float(sweet_spot)

        self.time = 0.0
        self.time_limit = cfg.attempt_seconds
        self.turn = 0.0            # lukkopesan todellinen kaanto
        self.pick = 0.0            # tiirikan todellinen kulma
        self.wear = 0.0            # 0..100
        self.opened = False
        self.broken = False
        self.timed_out = False
        self.f_seconds = 0.0       # kokonaisaika F pohjassa
        self.stall_seconds = 0.0   # aika jumissa olevaa kohtaa vasten

    # -- palautekayra ------------------------------------------------------

    def max_turn_at(self, pick: float) -> float:
        """Suurin kaanto jonka pesa antaa tassa tiirikan asennossa."""
        d = abs(pick - self.sweet_spot)
        core = self.cfg.core_half
        zone = self.cfg.zone_half

        if d <= core:
            return OPEN_TURN
        if d >= zone:
            return 0.0
        give = self.cfg.tier_data().give_max
        return give * (zone - d) / (zone - core)

    # -- eteneminen --------------------------------------------------------

    @property
    def finished(self) -> bool:
        return self.opened or self.broken or self.timed_out

    @property
    def time_left(self) -> float:
        return max(0.0, self.time_limit - self.time)

    def step(self, dt: float, pick_target: float, f_down: bool) -> None:
        if self.finished:
            return

        previous_pick = self.pick
        self.pick = min(PICK_MAX, max(PICK_MIN, float(pick_target)))
        moved = abs(self.pick - previous_pick) > 1e-6

        self.time += dt

        if f_down:
            self.f_seconds += dt
            target = self.max_turn_at(self.pick)

            if self.turn < target:
                self.turn = min(target, self.turn + TURN_RATE * dt)
            elif self.turn > target:
                # tiirikkaa siirrettiin pois: pesa valahtaa takaisin
                self.turn = max(target, self.turn - RETURN_RATE * dt)

            stalled = abs(self.turn - target) < 0.5
            if stalled and target < OPEN_TURN - OPEN_EPSILON:
                self.stall_seconds += dt
                self.wear += self.cfg.wear_rate * dt
            if moved:
                self.wear += self.cfg.wear_rate * self.cfg.jiggle_wear_mult * dt

            if self.turn >= OPEN_TURN - OPEN_EPSILON:
                self.opened = True
                return
        else:
            self.turn = max(0.0, self.turn - RETURN_RATE * dt)

        if self.wear >= 100.0:
            self.wear = 100.0
            self.broken = True
            return

        if self.time >= self.time_limit:
            self.timed_out = True

    # -- havainto ----------------------------------------------------------

    def snapshot(self) -> dict:
        return {
            "t": self.time,
            "turn": self.turn,
            "pick": self.pick,
            "time_left": self.time_left,
            "wear": self.wear,
            "opened": self.opened,
            "broken": self.broken,
        }


@dataclass
class SessionResult:
    opened: bool = False
    attempts: int = 0
    broken_picks: int = 0
    timeouts: int = 0
    total_seconds: float = 0.0
    probes: int = 0
    opening_attempt: int | None = None
    reason: str = ""
    trace: list = field(default_factory=list)


def response_curve(cfg: LockConfig, sweet_spot: float, samples: int = 321) -> list[tuple[float, float]]:
    """Palautekayra piirtamista varten."""
    tmp = LockAttempt.__new__(LockAttempt)
    tmp.cfg = cfg
    tmp.sweet_spot = sweet_spot
    out = []
    for i in range(samples):
        p = PICK_MIN + (PICK_MAX - PICK_MIN) * i / (samples - 1)
        out.append((p, LockAttempt.max_turn_at(tmp, p)))
    return out


def guaranteed_scan_step(cfg: LockConfig) -> float:
    """Suurin skannausvali joka ei voi hypata palautealueen yli."""
    return 2.0 * cfg.zone_half


def probe_budget(cfg: LockConfig, seconds_per_probe: float) -> float:
    """Kuinka monta F-testia yhteen yritykseen mahtuu."""
    if seconds_per_probe <= 0:
        return math.inf
    return cfg.attempt_seconds / seconds_per_probe
