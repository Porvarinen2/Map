"""SCUM autolockpick - hakusaanto ja tilakone.

    tap, tap, tap, tap, taap, taaaap, taaaap, AUKI

Nain se toimii. Kaksi vaihetta, ei muuta:

  SKANNAUS   Hiiri askeleen oikealle, lyhyt F-napautus, katsotaan
             liikkuiko lukkopesa. Ei liikkunut -> askel oikealle ja
             uusi napautus. Napautukset ovat kaikki samanmittaisia.

  RAMPPI     Lukkopesa (ja sen musta avaimenreika) kaantyi -> oikea
             kohta loytyi. Nyt F:aa painetaan pohjassa niin kauan kuin
             pesa kaantyy. Kun se pysahtyy, nykaistaan hieman ja
             painetaan uudelleen. Mita lahempana ollaan, sita pidemman
             aikaa pesa kaantyy - siita tulee "taap, taaaap, taaaap".

Painallusten pituutta EI ole kasketty mihinkaan: se seuraa siita, kuinka
kauan pesa jaksaa kaantya. Kaukana se pysahtyy heti (tap), lahella se
kaantyy pitkaan (taaaap).

Kaikki saadettavat luvut ovat heti alla yhdessa paikassa. Niita voi
muuttaa myos pelia sammuttamatta tiedostosta live_asetukset.json,
osiosta "control".
"""

from __future__ import annotations

from dataclasses import dataclass, field


# ==========================================================================
#  SAADOT - kaikki taalla, yksi rivi kukin
# ==========================================================================


@dataclass
class ControlConfig:
    # ---- kotiinajo: hiiri vasempaan reunaan yrityksen alussa ----
    home_units: float = 9000.0          # kuinka pitkalle vasemmalle tyonnetaan
    home_pulse_units: float = 900.0     # yhden tyonnon koko (isompi = nykivampi)
    home_pulse_ms: float = 12.0         # tyontojen valinen tauko

    # ---- SKANNAUS: tap, tap, tap ----
    scan_step_units: float = 90.0       # hiiren siirto joka napautuksen valissa
    tap_ms: float = 90.0                # kuinka kauan F on pohjassa napautuksessa
    gap_ms: float = 120.0               # tauko napautuksen jalkeen, F ylhaalla
    ramp_degrees: float = 3.0           # nain monta astetta kaantoa = ramppi

    # ---- RAMPPI: taap, taaaap, taaaap ----
    press_min_ms: float = 120.0         # lyhin pitka painallus
    press_max_ms: float = 1600.0        # pisin painallus
    press_stall_ms: float = 130.0       # nain kauan ilman kaantoa = pesa pysahtyi
    release_ms: float = 70.0            # F ylhaalla painallusten valissa
    nudge_units: float = 14.0           # nykays kun pesa pysahtyi
    nudge_fine_units: float = 4.0       # ... kun ollaan jo lahella maalia
    fine_below_degrees: float = 12.0    # nain lahella maalia kaytetaan hienonykaysta
    open_degrees: float = 88.0          # tasta ylospain F pysyy pohjassa loppuun
    lost_degrees: float = 2.0           # kaanto putosi tanne = ramppi hukattiin
    lost_presses: int = 3               # nain monta hukkaa perakkain -> takaisin skannaukseen

    # ---- yhteiset ----
    max_units_per_pulse: float = 240.0  # yhden hiiripulssin katto
    pulse_ms: float = 16.0              # pulssien valinen tauko
    span_units: float = 6000.0          # nain pitkalle skannataan, sitten alusta
    rest_frames: int = 6                # lepokulma mitataan naista ruuduista


# ==========================================================================
#  Tietorakenteet
# ==========================================================================


@dataclass
class Observation:
    """Havainto pelista. Tiirikasta ei ole tietoa eika sita tarvita."""

    stamp: float = -1.0
    ok: bool = False
    turn: float = 0.0
    timer: float = 1.0
    running: bool = False


@dataclass
class Action:
    mouse_units: float = 0.0
    f_down: bool = False
    phase: str = "idle"
    note: str = ""


@dataclass
class Probe:
    position: float
    score: float
    ramp: bool
    kind: str


@dataclass
class SearchMemory:
    """Yritysten valilla sailyva tieto. Sweetspotin paikkaa ei muisteta."""

    resume_units: float = 0.0
    zone_units: float | None = None
    zone_score: float = 0.0
    sweeps: int = 0
    wraps: int = 0

    def forget_position(self) -> None:
        self.resume_units = 0.0


@dataclass
class Bookkeeping:
    """Pelkkaa nakyvyytta CMD-ikkunalle ja debug-paketille."""

    ramp_locked: bool = False
    best_units: float | None = None
    best_score: float = 0.0
    step: float = 0.0
    local_direction: int = 1
    responding: list = field(default_factory=list)
    samples: list = field(default_factory=list)


# ==========================================================================
#  Ohjain
# ==========================================================================


class Controller:
    """Yksi lockpick-yritys.

    Vaiheet: home -> scan -> ramp -> (auki tai aika loppui)
    """

    HOME, SCAN, RAMP, DONE = "home", "scan", "ramp", "done"

    def __init__(self, cfg: ControlConfig, memory: SearchMemory | None = None):
        self.cfg = cfg
        self.memory = memory if memory is not None else SearchMemory()
        self.reset()

    # ------------------------------------------------------------------

    def reset(self) -> None:
        self.phase = self.HOME
        self.position = 0.0
        self.target = 0.0
        self.probes: list[Probe] = []
        self.planner = Bookkeeping(step=self.cfg.nudge_units)

        self._homed = 0.0
        self._next_pulse = 0.0

        # lepokulma mitataan yrityksen ensimmaisista ruuduista
        self._rest: list[float] = []
        self.rest_angle = 0.0

        # kaantonopeuden mittaus (vain nakymaa varten)
        self._rates: list[float] = []
        self._last_turn = 0.0
        self._last_rise = 0.0

        # SKANNAUS
        self._tapping = False
        self._tap_until = 0.0
        self._gap_until = 0.0
        self._tap_peak = 0.0

        # RAMPPI
        self._pressing = False
        self._press_until = 0.0
        self._press_started = 0.0
        self._press_peak = 0.0
        self._rise_at = 0.0
        self._release_until = 0.0
        self._best_peak = 0.0
        self._direction = 1
        self._misses = 0

    # ------------------------------------------------------------ mittarit

    @property
    def measured_turn_rate(self) -> float | None:
        if not self._rates:
            return None
        return sorted(self._rates)[len(self._rates) // 2]

    @property
    def scan_step(self) -> float:
        return self.cfg.scan_step_units

    def _lift(self, obs: Observation) -> float:
        """Kuinka paljon pesa on kaantynyt lepoasennostaan."""
        return obs.turn - self.rest_angle

    def _note(self, position: float, score: float, kind: str) -> None:
        self.probes.append(Probe(position, score, self.planner.ramp_locked, kind))
        self.planner.samples.append((position, score))
        if score >= self.cfg.ramp_degrees:
            self.planner.responding.append(position)
        if score > self.planner.best_score:
            self.planner.best_score = score
            self.planner.best_units = position

    def _move(self, now: float, units: float, phase: str, note: str,
              f_down: bool) -> Action:
        units = max(-self.cfg.max_units_per_pulse,
                    min(self.cfg.max_units_per_pulse, units))
        self._next_pulse = now + self.cfg.pulse_ms / 1000.0
        self.position += units
        return Action(units, f_down, phase, note)

    # --------------------------------------------------------------- runko

    def update(self, now: float, obs: Observation) -> Action:
        if not obs.ok:
            return Action(phase=self.phase, note="ei lukkoa nakyvissa")

        # Lepokulma: pesa voi levata hieman vinossa, joten nollataso
        # mitataan eika oleteta.
        if len(self._rest) < self.cfg.rest_frames:
            self._rest.append(obs.turn)
            self.rest_angle = sorted(self._rest)[len(self._rest) // 2]
            self._last_turn = obs.turn

        # Kaantonopeus vain nakymaa varten.
        if obs.turn > self._last_turn + 1.0:
            gap = now - self._last_rise
            if 0.004 < gap < 1.0:
                self._rates.append((obs.turn - self._last_turn) / gap)
                del self._rates[:-30]
            self._last_rise = now
        if abs(obs.turn - self._last_turn) > 1.0:
            self._last_turn = obs.turn

        if self.phase == self.HOME:
            return self._home(now, obs)
        if self.phase == self.SCAN:
            return self._scan(now, obs)
        if self.phase == self.RAMP:
            return self._ramp(now, obs)
        return Action(phase=self.DONE, note="valmis")

    # ---------------------------------------------------------------- HOME

    def _home(self, now: float, obs: Observation) -> Action:
        """Hiiri vasempaan reunaan. Seinaa vasten ylimaarainen liike ei
        tee mitaan, joten jokainen yritys alkaa samasta kohdasta."""
        if self._homed >= self.cfg.home_units:
            self.position = 0.0
            self.target = 0.0
            self.phase = self.SCAN
            self._tapping = False
            self._gap_until = 0.0
            return Action(phase=self.SCAN, note="vasen reuna, aloitetaan")

        if now < self._next_pulse:
            return Action(phase=self.HOME, note="kotiinajo")

        step = min(self.cfg.home_pulse_units, self.cfg.home_units - self._homed)
        self._homed += step
        self._next_pulse = now + self.cfg.home_pulse_ms / 1000.0
        return Action(-step, False, self.HOME,
                      f"vasempaan reunaan {self._homed / self.cfg.home_units * 100:.0f} %")

    # ---------------------------------------------------------------- SCAN

    def _scan(self, now: float, obs: Observation) -> Action:
        """tap, tap, tap - askel oikealle, lyhyt napautus, katso liikkuiko.

        Napautukset ovat kaikki samanmittaisia. Tulos luetaan napautuksen
        jalkeisella tauolla, koska ruudulla nakyva kuva on hieman vanhaa.
        """
        lift = self._lift(obs)
        self._tap_peak = max(self._tap_peak, lift)

        # Pesa kaantyi -> ramppi.
        if self._tap_peak >= self.cfg.ramp_degrees:
            return self._found_ramp(now, obs)

        # 1) Napautus kaynnissa: F pohjassa, hiiri paikallaan.
        if self._tapping:
            if now < self._tap_until:
                return Action(f_down=True, phase=self.SCAN,
                              note=f"tap {self.position:.0f} u")
            self._tapping = False
            self._gap_until = now + self.cfg.gap_ms / 1000.0
            self._note(self.position, self._tap_peak, "tap")
            return Action(phase=self.SCAN, note=f"luetaan {self._tap_peak:.1f} deg")

        # 2) Tauko: F ylhaalla, luetaan napautuksen tulos.
        if now < self._gap_until:
            return Action(phase=self.SCAN, note=f"luetaan {self._tap_peak:.1f} deg")

        # 3) Askel oikealle ja uusi napautus.
        if self.position >= self.cfg.span_units:
            self.position = 0.0
            self.memory.wraps += 1
            self.memory.resume_units = 0.0
            return Action(phase=self.SCAN, note="jana kayty, alusta")

        if now < self._next_pulse:
            return Action(phase=self.SCAN, note="...")

        self._tapping = True
        self._tap_until = now + self.cfg.tap_ms / 1000.0
        self._tap_peak = 0.0
        self.memory.resume_units = self.position
        self.target = self.position + self.cfg.scan_step_units
        return self._move(now, self.cfg.scan_step_units, self.SCAN,
                          f"askel -> {self.target:.0f} u", f_down=True)

    def _found_ramp(self, now: float, obs: Observation) -> Action:
        """Lukkopesa kaantyi: siirrytaan painamaan pidempaan."""
        self._note(self.position, self._tap_peak, "RAMPPI")
        self.planner.ramp_locked = True
        self.phase = self.RAMP
        # Nollasta, jotta ensimmainen pitka painallus lasketaan aina
        # parannukseksi: silloin ensimmainen nykays menee OIKEALLE.
        # Skannaus tulee vasemmalta, joten oikea kohta on edessapain.
        self._best_peak = 0.0
        self._direction = 1
        self._misses = 0
        self._start_press(now, obs)
        return Action(f_down=True, phase=self.RAMP,
                      note=f"RAMPPI {self._tap_peak:.1f} deg -> painetaan")

    # ---------------------------------------------------------------- RAMP

    def _start_press(self, now: float, obs: Observation) -> None:
        self._pressing = True
        self._press_started = now
        self._press_until = now + self.cfg.press_max_ms / 1000.0
        self._press_peak = self._lift(obs)
        self._rise_at = now

    def _ramp(self, now: float, obs: Observation) -> Action:
        """taap, taaaap, taaaap - paina niin kauan kuin pesa kaantyy.

        Painallus loppuu vasta kun pesa on lakannut kaantymasta. Siksi
        painallus pitenee itsestaan sita mukaa kun lahestytaan oikeaa
        kohtaa: kaukana pesa pysahtyy heti, lahella se kaantyy pitkaan.
        """
        lift = self._lift(obs)

        # Maalissa: ei enaa mitaan saatoa, pidetaan F pohjassa.
        if lift >= self.cfg.open_degrees:
            return Action(f_down=True, phase=self.RAMP,
                          note=f"AUKEAA {lift:.1f} deg -> F pohjassa")

        # --- painallus kaynnissa ---
        if self._pressing:
            if lift > self._press_peak + 1.0:
                self._press_peak = lift
                self._rise_at = now              # pesa kaantyy yha
            still_turning = (now - self._rise_at) < self.cfg.press_stall_ms / 1000.0
            long_enough = (now - self._press_started) >= self.cfg.press_min_ms / 1000.0
            if now < self._press_until and (still_turning or not long_enough):
                return Action(f_down=True, phase=self.RAMP,
                              note=f"paina {lift:.1f} deg")

            # Painallus ohi: F ylos hetkeksi.
            self._pressing = False
            self._release_until = now + self.cfg.release_ms / 1000.0
            self._note(self.position, self._press_peak,
                       f"paino {(now - self._press_started) * 1000:.0f} ms")
            return Action(phase=self.RAMP, note=f"huippu {self._press_peak:.1f} deg")

        # --- lyhyt tauko painallusten valissa ---
        if now < self._release_until:
            return Action(phase=self.RAMP, note="hetki irti")

        # --- verrataan ja nykaistaan ---
        if self._press_peak < self.cfg.lost_degrees:
            self._misses += 1
            if self._misses >= self.cfg.lost_presses:
                self.phase = self.SCAN                # ramppi hukattiin
                self.planner.ramp_locked = False
                self._tapping = False
                self._gap_until = 0.0
                self._tap_peak = 0.0
                return Action(phase=self.SCAN, note="ramppi hukkui, skannataan")
        else:
            self._misses = 0

        if self._press_peak > self._best_peak + 1.0:
            self._best_peak = self._press_peak        # parani: sama suunta
        else:
            self._direction *= -1                     # huononi: toiseen suuntaan

        near = (self.cfg.open_degrees - self._press_peak) <= self.cfg.fine_below_degrees
        step = (self.cfg.nudge_fine_units if near else self.cfg.nudge_units)
        self.planner.step = step
        self.planner.local_direction = self._direction

        self._start_press(now, obs)
        return self._move(now, step * self._direction, self.RAMP,
                          f"nykays {step * self._direction:+.0f} u", f_down=True)

    # ------------------------------------------------------- yrityksen loppu

    def finish_attempt(self, opened: bool) -> None:
        self.memory.sweeps += 1
        if opened:
            self.memory.forget_position()


# ==========================================================================
#  Apufunktiot (nakyman kayttoon)
# ==========================================================================


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
