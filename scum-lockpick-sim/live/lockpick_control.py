"""Autolockpickin paatoslogiikka. Lukko on ainoa mittari.

Tiirikkaa EI tunnisteta lainkaan. Se on ohut, se voi olla eri tyokalu
(hiuspinni, hakaneula, improvised lockpick) ja se nakyy eri kulmissa, joten
sen tunnistus oli koko ketjun epavarmin kohta. Sita ei tarvita:

    hiirta liikutetaan HIIRIYKSIKKOINA, ei asteina
    ainoa havainto on LUKKOPESAN KAANTO
    kaanto = 0        -> vaara kohta, siirry eteenpain
    kaanto = vahan    -> ramppi loytyi, hae sen pohja
    kaanto = melkein  -> F pohjaan ja lukko aukeaa

Koska liike on hiiriyksikkoina, ohjelman ei tarvitse tietaa pelin
hiiriherkkyytta eika tiirikan asentoa. Vasen aariasento loydetaan
tyontamalla hiirta reilusti yli koko janan: seinaa vasten ylimaarainen
liike ei tee mitaan, joten lahtokohta on aina sama.

    ALOITUS (vasen reuna)
      |
      +--F--+--F--+--F--+--F--+--F--+--F--+   vasemmalta oikealle
                                    |
                                    +-- lukko antoi periksi = RAMPPI
                                        pienempi askel, hae pohja
                                        TARGET -> F pohjaan

Tama moduuli ei koske ruutuun eika hiireen. Se saa havainnot sisaan ja
palauttaa toiminnot ulos, joten sama koodi ajetaan kahdessa paikassa:

    autolockpick_live.py   havainnot ruudulta, toiminnot SendInputille
    test_live.py           havainnot simulaatiosta, toiminnot simulaatioon
"""

from __future__ import annotations

from dataclasses import dataclass


# --------------------------------------------------------------------------
# Asetukset
# --------------------------------------------------------------------------


@dataclass
class ControlConfig:
    """Kaikki matkat hiiriyksikkoina, kaikki kaannot asteina."""

    # Kotiinajo: tama tyonnetaan vasemmalle jokaisen yrityksen alussa.
    # Arvon on ylitettava koko jana reilusti; seinaa vasten ylitys on ilmainen.
    # 9000 yksikkoa kattaa koko janan viela silloin, kun pelin herkkyys on
    # niin matala etta yksi yksikko on vain 0.014 astetta.
    home_units: float = 9000.0
    home_pulse_units: float = 1200.0

    # Skannaus vasemmalta oikealle.
    scan_step_units: float = 300.0
    minimum_scan_step_units: float = 40.0
    maximum_scan_step_units: float = 900.0

    # Rampin lahihaku.
    fine_step_units: float = 110.0
    minimum_step_units: float = 10.0

    # Hiiripulssit.
    max_units_per_pulse: float = 220.0
    pulse_interval_ms: float = 16.0

    # F-ajoitus. Kasvavaa kaantoa ei katkaista koskaan.
    minimum_hold_ms: float = 70.0
    stall_release_ms: float = 45.0
    maximum_hold_ms: float = 1200.0
    auto_raise_hold_cap: bool = True
    finish_stall_ms: float = 260.0
    release_settle_ms: float = 40.0
    release_turn_threshold: float = 3.0

    # Kaannon tulkinta.
    progress_epsilon_degrees: float = 0.9    # pienin muutos joka on liiketta
    movement_found_degrees: float = 4.0      # tata pienempi on pelkka tarahdys
    near_open_degrees: float = 80.0          # tasta eteenpain F jaa pohjaan

    # Muisti yritysten valilla.
    #
    # resume_search on turvallinen kummin pain tahansa: jos sweetspot pysyy
    # paikallaan, jo kayty jana ei kannata kayda uudestaan, ja jos se arvotaan
    # uudelleen, uusi alue on yhta hyva kuin mika tahansa muu.
    #
    # remember_ramp on veto sen puolesta, etta sweetspot EI vaihdu yritysten
    # valilla. Pelaajien kuvausten mukaan se voi vaihtua, ja simulaatiossa se
    # vaihtuu, joten oletus on pois paalta. Jos huomaat pelissa etta kohta
    # pysyy samana, laita tama paalle: silloin uusinta menee suoraan asiaan.
    resume_search: bool = True               # jatka siita mihin jaatiin
    remember_ramp: bool = False              # palaa suoraan loydettyyn ramppiin
    learn_step_from_ramp: bool = True        # saada skannausvali rampin leveydesta


@dataclass
class Observation:
    """Havainto pelin tilasta. Tiirikasta ei ole tietoa eika sita tarvita."""

    stamp: float = -1.0
    ok: bool = False                 # nakyyko lukko
    turn: float = 0.0                # lukkopesan kaanto asteina
    timer: float = 1.0               # jaljella oleva aika osuutena
    running: bool = False            # kayko ajastin


@dataclass
class Action:
    mouse_units: float = 0.0
    f_down: bool = False
    phase: str = "idle"
    note: str = ""


@dataclass
class Probe:
    position: float          # hiiriyksikkoa vasemmasta reunasta
    score: float             # suurin kaanto tassa kohdassa
    ramp: bool
    kind: str


@dataclass
class SearchMemory:
    """Sailyy yritysten yli, koska lukko ei vaihdu yritysten valissa."""

    resume_units: float = 0.0        # mihin asti jana on jo kayty
    ramp_units: float | None = None  # paras loydetty kohta
    ramp_score: float = 0.0
    scan_step_units: float | None = None
    swept_units: float = 0.0         # kuinka pitkalle on yhteensa edetty
    wraps: int = 0

    def forget_position(self) -> None:
        self.resume_units = 0.0
        self.swept_units = 0.0


# --------------------------------------------------------------------------
# Hakusaanto
# --------------------------------------------------------------------------


class Planner:
    """Yksisuuntainen skannaus vasemmalta oikealle, sitten rampin lahihaku.

    Kaikki paikat ovat hiiriyksikkoja vasemmasta aariasennosta. Asteita ei
    kayteta missaan, koska tiirikan asentoa ei tunneta.
    """

    def __init__(self, cfg: ControlConfig, memory: SearchMemory):
        self.cfg = cfg
        self.memory = memory

        self.scan_step = memory.scan_step_units or cfg.scan_step_units
        self.step = cfg.fine_step_units
        self.ramp_locked = False
        self.best_units: float | None = None
        self.best_score = 0.0
        self.local_direction = 1
        self.samples: list[tuple[float, float]] = []
        self.responding: list[float] = []      # kohdat joissa lukko antoi periksi

        self._next_scan: float | None = None

    def first_target(self) -> float:
        """Mista tama yritys aloittaa."""
        if self.cfg.remember_ramp and self.memory.ramp_units is not None:
            # Ramppi on jo loydetty: mennaan hieman sen vasemmalle puolelle
            # ja jatketaan lahihakua sielta.
            return max(0.0, self.memory.ramp_units - self.cfg.fine_step_units)
        if self.cfg.resume_search:
            return max(0.0, self.memory.resume_units)
        return 0.0

    def record(self, position: float, score: float) -> str:
        score = max(0.0, score)
        self.samples.append((position, score))
        if score >= self.cfg.movement_found_degrees:
            self.responding.append(position)

        if not self.ramp_locked:
            if score >= self.cfg.movement_found_degrees:
                self.ramp_locked = True
                self.best_units = position
                self.best_score = score
                self.local_direction = 1          # jatketaan samaan suuntaan
                self.step = self.cfg.fine_step_units
                self.memory.ramp_units = position
                self.memory.ramp_score = score
                return "ramppi"
            self.memory.resume_units = position
            return "tyhja"

        if score > self.best_score + 0.15:
            self.best_units = position
            self.best_score = score
            self.memory.ramp_units = position
            self.memory.ramp_score = score
            if score >= 60.0:
                self.step = min(self.step, self.cfg.fine_step_units * 0.25)
            elif score >= 35.0:
                self.step = min(self.step, self.cfg.fine_step_units * 0.5)
            return "parempi"

        # Huonompi tai sama: mentiin pohjan yli. Suunta vaihtuu, askel puolittuu.
        self.local_direction *= -1
        self.step = max(self.cfg.minimum_step_units, self.step * 0.5)
        return "kaanto"

    def next_target(self, current: float) -> float:
        if self.ramp_locked and self.best_units is not None:
            return max(0.0, self.best_units + self.local_direction * self.step)
        if self._next_scan is None:
            self._next_scan = self.first_target()
        else:
            self._next_scan = current + self.scan_step
        return self._next_scan

    def learn_step(self) -> None:
        """Paattelee sopivan skannausvalin siita, kuinka levea ramppi oli.

        Rampin leveys hiiriyksikkoina on ainoa mittatikku, joka saadaan ilman
        tiirikan tunnistusta. Skannausvalin on jaatava sita kapeammaksi, ettei
        alue voi jaada kahden testin valiin.
        """
        if not self.cfg.learn_step_from_ramp or len(self.responding) < 2:
            return
        width = max(self.responding) - min(self.responding)
        if width <= 0:
            return
        self.memory.scan_step_units = min(
            self.cfg.maximum_scan_step_units,
            max(self.cfg.minimum_scan_step_units, width * 1.5),
        )


# --------------------------------------------------------------------------
# Tilakone
# --------------------------------------------------------------------------


class Controller:
    """Ajaa yhta yritysta. Havainnoista tarvitaan vain lukkopesan kaanto.

    Vaiheet:
        home     hiiri vasempaan aariasentoon (avoin ohjaus, ei mittausta)
        travel   hiiri seuraavaan testikohtaan
        hold     F pohjassa, katsotaan kaantyyko pesa
        release  F ylhaalla, odotetaan etta pesa palaa nollaan
        finish   pesa kaantyy kohti loppua: F jaa pohjaan
    """

    HOME, TRAVEL, HOLD, RELEASE, FINISH, DONE = (
        "home", "travel", "hold", "release", "finish", "done")

    def __init__(self, cfg: ControlConfig, memory: SearchMemory | None = None):
        self.cfg = cfg
        self.memory = memory if memory is not None else SearchMemory()
        self.reset()

    def reset(self) -> None:
        self.planner = Planner(self.cfg, self.memory)
        self.phase = self.HOME
        self.position = 0.0          # hiiriyksikkoa vasemmasta reunasta
        self.target = 0.0
        self.probes: list[Probe] = []

        self._homed_units = 0.0
        self._next_pulse = 0.0
        self._phase_started = 0.0
        self._last_progress = 0.0
        self._peak = 0.0
        self._hold_baseline = 0.0
        self._release_ready: float | None = None
        self._turn_rates: list[float] = []

    # -- apurit ------------------------------------------------------------

    @property
    def measured_turn_rate(self) -> float | None:
        if not self._turn_rates:
            return None
        ordered = sorted(self._turn_rates)
        return ordered[len(ordered) // 2]

    @property
    def scan_step(self) -> float:
        return self.planner.scan_step

    def _note_turn_rate(self, rate: float) -> None:
        if not (20.0 <= rate <= 3000.0):
            return
        self._turn_rates.append(rate)
        del self._turn_rates[:-40]

        if not self.cfg.auto_raise_hold_cap:
            return
        needed = full_turn_ms(self.measured_turn_rate)
        if needed and self.cfg.maximum_hold_ms < needed * 1.4:
            # Hatakatko ei saa koskaan katkaista kesken taytta kaantoa.
            self.cfg.maximum_hold_ms = round(needed * 1.6)

    def _pulse(self, now: float, units: float, phase: str, note: str) -> Action:
        self._next_pulse = now + self.cfg.pulse_interval_ms / 1000.0
        return Action(mouse_units=units, phase=phase, note=note)

    def _commit(self, now: float, kind_hint: str = "") -> str:
        score = max(0.0, self._peak - self._hold_baseline)
        kind = self.planner.record(self.position, score)
        self.probes.append(Probe(position=self.position, score=score,
                                 ramp=self.planner.ramp_locked,
                                 kind=kind_hint or kind))
        return kind_hint or kind

    def _to_release(self, now: float) -> None:
        self.phase = self.RELEASE
        self._phase_started = now
        self._release_ready = None

    # -- paasilmukka -------------------------------------------------------

    def update(self, now: float, obs: Observation) -> Action:
        if not obs.ok:
            # Lukkoa ei nay: F ylos, mutta mittaukset ja paikka sailyvat.
            return Action(phase=self.phase, note="ei lukkoa nakyvissa")

        if self.phase == self.HOME:
            return self._home(now)
        if self.phase == self.TRAVEL:
            return self._travel(now, obs)
        if self.phase == self.HOLD:
            return self._hold(now, obs)
        if self.phase == self.RELEASE:
            return self._release(now, obs)
        if self.phase == self.FINISH:
            return self._finish(now, obs)
        return Action(phase=self.DONE, note="jana kayty")

    def _home(self, now: float) -> Action:
        """Tyontaa hiirta vasemmalle yli koko janan.

        Tama on ainoa kohta, jossa asemasta saadaan varmuus ilman tiirikan
        nakemista: seinaa vasten ylimaarainen liike ei siirra mitaan.
        """
        if self._homed_units >= self.cfg.home_units:
            self.position = 0.0
            self.target = self.planner.next_target(0.0)
            self.phase = self.TRAVEL
            self._phase_started = now
            self._next_pulse = now
            return Action(phase=self.TRAVEL, note="vasen reuna loydetty")

        if now < self._next_pulse:
            return Action(phase=self.HOME, note="kotiinajo")

        step = min(self.cfg.home_pulse_units, self.cfg.home_units - self._homed_units)
        self._homed_units += step
        done = self._homed_units / self.cfg.home_units * 100.0
        return self._pulse(now, -step, self.HOME, f"vasempaan reunaan {done:.0f} %")

    def _travel(self, now: float, obs: Observation) -> Action:
        error = self.target - self.position

        if abs(error) < 1.0:
            self.phase = self.HOLD
            self._phase_started = now
            self._last_progress = now
            self._peak = obs.turn
            self._hold_baseline = obs.turn
            return Action(f_down=True, phase=self.HOLD,
                          note=f"testi {self.position:.0f} u")

        if now < self._next_pulse:
            return Action(phase=self.TRAVEL, note="pulssien valissa")

        limit = self.cfg.max_units_per_pulse
        units = max(-limit, min(limit, error))
        self.position += units
        return self._pulse(now, units, self.TRAVEL, f"kohti {self.target:.0f} u")

    def _hold(self, now: float, obs: Observation) -> Action:
        if obs.turn > self._peak + self.cfg.progress_epsilon_degrees:
            if self._last_progress > self._phase_started:
                delta = now - self._last_progress
                if delta > 0.004:
                    self._note_turn_rate((obs.turn - self._peak) / delta)
            self._peak = obs.turn
            self._last_progress = now
        elif obs.turn > self._peak:
            self._peak = obs.turn

        turned = self._peak - self._hold_baseline
        elapsed_ms = (now - self._phase_started) * 1000.0
        stalled_ms = (now - self._last_progress) * 1000.0

        # Pesa kaantyy kohti loppua: F jaa pohjaan.
        if turned >= self.cfg.near_open_degrees:
            self.phase = self.FINISH
            self._phase_started = now
            self._last_progress = now
            return Action(f_down=True, phase=self.FINISH, note="viimeistely")

        # Kasvavaa kaantoa ei katkaista. Pysahtynyt kohta vapautetaan heti:
        # sita vasten painaminen vain kuluttaa tiirikkaa.
        release = (elapsed_ms >= self.cfg.minimum_hold_ms
                   and stalled_ms >= self.cfg.stall_release_ms)
        if not release and elapsed_ms >= self.cfg.maximum_hold_ms:
            release = True

        if release:
            kind = self._commit(now)
            self._to_release(now)
            return Action(phase=self.RELEASE, note=f"{turned:.1f} deg / {kind}")

        return Action(f_down=True, phase=self.HOLD, note=f"{turned:.1f} deg")

    def _release(self, now: float, obs: Observation) -> Action:
        if obs.turn <= self.cfg.release_turn_threshold and self._release_ready is None:
            self._release_ready = now + self.cfg.release_settle_ms / 1000.0

        if self._release_ready is not None and now >= self._release_ready:
            self.target = self.planner.next_target(self.position)
            self.memory.swept_units = max(self.memory.swept_units, self.target)
            self.phase = self.TRAVEL
            self._next_pulse = now
            return Action(phase=self.TRAVEL, note=f"seuraava {self.target:.0f} u")

        return Action(phase=self.RELEASE, note="pesa palautuu")

    def _finish(self, now: float, obs: Observation) -> Action:
        if obs.turn > self._peak + self.cfg.progress_epsilon_degrees:
            self._peak = obs.turn
            self._last_progress = now

        # Jos kaanto pysahtyy, kohta ei ollut pohja. Painaminen lopetetaan.
        if (now - self._last_progress) * 1000.0 >= self.cfg.finish_stall_ms:
            self._commit(now, "lahes")
            self._to_release(now)
            return Action(phase=self.RELEASE, note="ei ollut pohja")

        return Action(f_down=True, phase=self.FINISH,
                      note=f"{obs.turn - self._hold_baseline:.1f} deg")

    # -- yrityksen paatos --------------------------------------------------

    def finish_attempt(self, opened: bool) -> None:
        """Paivittaa muistin seuraavaa yritysta varten."""
        self.planner.learn_step()

        if opened:
            self.memory.forget_position()
            self.memory.ramp_units = None
            self.memory.ramp_score = 0.0
            return

        if self.planner.ramp_locked:
            # Ramppi loytyi mutta aika loppui: sinne palataan suoraan.
            return

        self.memory.swept_units = max(self.memory.swept_units, self.position)
        if self.memory.swept_units >= self.cfg.home_units:
            # Koko jana on kayty ilman osumaa: askel oli liian harva.
            self.memory.wraps += 1
            self.memory.forget_position()
            step = self.memory.scan_step_units or self.cfg.scan_step_units
            self.memory.scan_step_units = max(
                self.cfg.minimum_scan_step_units, step * 0.5)
        else:
            self.memory.resume_units = self.position


# --------------------------------------------------------------------------
# Apufunktiot
# --------------------------------------------------------------------------


def full_turn_ms(turn_rate: float | None, degrees: float = 90.0) -> float | None:
    if not turn_rate or turn_rate <= 1.0:
        return None
    return degrees / turn_rate * 1000.0


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def wrap_angle(angle: float, near: float) -> float:
    """Palauttaa kulman +-180 asteen haarasta, joka on lahinna arvoa near."""
    while angle - near > 90.0:
        angle -= 180.0
    while near - angle > 90.0:
        angle += 180.0
    return angle
