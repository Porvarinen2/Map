"""Autolockpickin paatoslogiikka: hakusaanto ja reaaliaikainen tilakone.

Tama moduuli ei koske ruutuun eika hiireen. Se saa havainnot sisaan ja
palauttaa toiminnot ulos, joten tasmalleen sama koodi ajetaan kahdessa
paikassa:

    autolockpick_live.py   havainnot ruudulta, toiminnot SendInputille
    test_live.py           havainnot simulaatiosta, toiminnot simulaatioon

Nain pelissa ajettava logiikka on se, joka on testattu simulaatiolla.

Kaksi asiaa on tehty toisin kuin helperi 1.8:ssa, koska simulaatio osoitti
ne ratkaiseviksi:

1. F vapautetaan kun pesan kaanto PYSAHTYY, ei kiintean ajastimen taytyttya.
   Kasvavaa kaantoa ei katkaista koskaan. Helperin 320 ms:n katto oli
   lyhyempi kuin taysi kaanto, jolloin lukko ei voinut aueta lainkaan.

2. Hiirta ohjataan takaisinkytkennalla mitatusta tiirikan kulmasta, ei
   avoimena integrointina oletetulla herkkyydella. Vaara herkkyysarvio
   hidastaa hakua muttei enaa riko sita.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

PICK_MIN = -80.0
PICK_MAX = 80.0


# --------------------------------------------------------------------------
# Asetukset
# --------------------------------------------------------------------------


@dataclass
class ControlConfig:
    """Hakuun ja ajoitukseen vaikuttavat arvot."""

    # haku
    scan_step_degrees: float = 8.0
    # Pelin omista kuvista mitattuna tiirikka yltaa noin +-63 asteeseen.
    # Reunat opitaan silti ajossa, koska mitta voi vaihdella naytolla.
    scan_from: float = -62.0             # vasemmalta oikealle
    scan_to: float = 62.0
    edge_stall_units: float = 60.0       # nain iso pulssi ilman liiketta = reuna
    edge_stall_degrees: float = 0.4
    edge_stall_hits: int = 3             # nain monta perakkain ennen kuin uskotaan
    edge_only_beyond_degrees: float = 40.0   # seinia etsitaan vain aarialueilta
    edge_margin_degrees: float = 1.5
    edge_minimum_span_degrees: float = 60.0  # opittu jana ei saa kutistua taman alle
    climb_step_degrees: float = 2.5
    minimum_climb_step_degrees: float = 0.10
    movement_found_degrees: float = 3.0
    near_open_degrees: float = 80.0

    # hiiri
    degrees_per_mouse_unit: float = 0.035
    learn_sensitivity: bool = True
    scan_mouse_max_units_per_pulse: float = 120.0
    ramp_mouse_max_units_per_pulse: float = 40.0
    mouse_pulse_interval_ms: float = 16.0
    arrive_tolerance_degrees: float = 0.6

    # F-ajoitus
    minimum_hold_ms: float = 70.0        # ennen tata mittaukseen ei luoteta
    stall_release_ms: float = 45.0       # nain kauan pysahtynytta kohtaa vasten
    maximum_hold_ms: float = 1200.0      # hatakatko; ei saa alittaa taytta kaantoa
    auto_raise_hold_cap: bool = True     # nostetaan itse, jos mitattu kaanto ei mahdu
    release_settle_ms: float = 40.0
    release_turn_threshold: float = 3.0
    progress_epsilon_degrees: float = 0.9   # pienin muutos joka lasketaan liikkeeksi

    # uusinta
    restart_key_interval_ms: float = 420.0


@dataclass
class Observation:
    """Yksi havainto pelin tilasta.

    stamp on hetki, jolloin ruutu kaapattiin. Sita tarvitaan, koska havainto
    saapuu ohjaimelle vasta kymmenien millisekuntien paasta: ilman sita
    ohjain korjaisi samaa virhetta monta kertaa ja tiirikka varahtelisi.
    """

    stamp: float = -1.0              # ruudunkaappauksen hetki
    ok: bool = False                 # tunnistettiinko lukkoruutu
    pick: float = 0.0                # tiirikan kulma asteina
    turn: float = 0.0                # lukkopesan kaanto asteina
    timer: float = 1.0               # jaljella oleva aika osuutena
    running: bool = False            # kayko ajastin


@dataclass
class Action:
    mouse_units: float = 0.0
    f_down: bool = False
    press_start: bool = False
    phase: str = "idle"
    note: str = ""


@dataclass
class Probe:
    pick: float
    score: float
    ramp: bool
    kind: str


# --------------------------------------------------------------------------
# Hakusaanto
# --------------------------------------------------------------------------


class Planner:
    """Vasemmalta oikealle skannaus, sitten paikallinen kiipeily.

    Global scan on tiukasti yksisuuntainen. Kun ensimmainen jatkuva kaanto
    loytyy, kierros lukitaan rampin lahialueelle: parempi vaste jatkaa samaan
    suuntaan, huonompi vaihtaa suunnan ja puolittaa askelen.
    """

    def __init__(self, cfg: ControlConfig):
        self.cfg = cfg
        self.samples: list[tuple[float, float]] = []
        self.ramp_locked = False
        self.best_x: float | None = None
        self.best_score = 0.0
        self.local_direction = 1
        self.step = cfg.climb_step_degrees

        self.scan_direction = 1 if cfg.scan_to >= cfg.scan_from else -1
        self._points = self._build_points()
        self._index = 0

    def _build_points(self) -> list[float]:
        step = abs(self.cfg.scan_step_degrees) * self.scan_direction
        points, x = [], self.cfg.scan_from
        while (self.scan_direction > 0 and x <= self.cfg.scan_to + 1e-9) or \
              (self.scan_direction < 0 and x >= self.cfg.scan_to - 1e-9):
            points.append(max(PICK_MIN, min(PICK_MAX, x)))
            x += step
        return points

    @property
    def scan_exhausted(self) -> bool:
        return not self.ramp_locked and self._index >= len(self._points)

    def record(self, x: float, score: float) -> str:
        score = max(0.0, score)
        self.samples.append((x, score))

        if not self.ramp_locked:
            if score >= self.cfg.movement_found_degrees:
                self.ramp_locked = True
                self.best_x = x
                self.best_score = score
                self.local_direction = self.scan_direction
                self.step = self.cfg.climb_step_degrees
                return "ramppi"
            return "tyhja"

        if score > self.best_score + 0.15:
            self.best_x = x
            self.best_score = score
            if score >= 84.0:
                self.step = min(self.step, 0.35)
            elif score >= 72.0:
                self.step = min(self.step, 0.75)
            elif score >= 55.0:
                self.step = min(self.step, 1.40)
            return "parempi"

        self.local_direction *= -1
        self.step = max(self.cfg.minimum_climb_step_degrees, self.step * 0.5)
        return "kaanto"

    def next_target(self) -> float | None:
        if not self.ramp_locked:
            if self._index >= len(self._points):
                return None
            x = self._points[self._index]
            self._index += 1
            return x

        if self.best_x is None:
            return None
        return max(PICK_MIN, min(PICK_MAX, self.best_x + self.local_direction * self.step))


# --------------------------------------------------------------------------
# Tilakone
# --------------------------------------------------------------------------


class Controller:
    """Ajaa yhta lockpick-yritysta reaaliajassa.

    Vaiheet:
        travel   F ylhaalla, hiiri kohti seuraavaa testipistetta
        hold     F pohjassa, mitataan kuinka pitkalle pesa kaantyy
        release  F ylhaalla, odotetaan etta pesa palaa nollaan
        finish   lahes taysi kaanto: F jaa pohjaan kunnes lukko aukeaa
        done     skannaus lapi, odotetaan ajan loppumista
    """

    TRAVEL, HOLD, RELEASE, FINISH, DONE = "travel", "hold", "release", "finish", "done"

    def __init__(self, cfg: ControlConfig):
        self.cfg = cfg
        self.reset()

    def reset(self) -> None:
        # Aariasennot ja herkkyys ovat lukon ominaisuuksia, eivat yrityksen,
        # joten ne sailyvat yritysten yli.
        previous_edges = (getattr(self, "edge_low", PICK_MIN),
                          getattr(self, "edge_high", PICK_MAX))
        self.planner = Planner(self.cfg)
        self.phase = self.TRAVEL
        self.target: float | None = None
        self.probes: list[Probe] = []

        self._phase_started = 0.0
        self._last_progress = 0.0
        self._next_pulse = 0.0
        self._peak = 0.0
        self._release_ready: float | None = None
        self._turn_rate_samples: list[float] = []
        self._hold_started_turn = 0.0

        # Lennossa olevat hiiripulssit: (annettu hetki, yksikot). Havainto on
        # aina vanha, joten naiden vaikutus lisataan siihen ennen ohjausta.
        self._pulse_log: list[tuple[float, float]] = []
        self._inflight_units = 0.0
        self._last_stamp = -1.0
        self._last_stamp_pick: float | None = None

        # Tiirikan todelliset aariasennot opitaan: jos iso pulssi ei liikuta
        # tiirikkaa, siella on seina eika sita vasten kannata ajaa uudestaan.
        self.edge_low, self.edge_high = previous_edges
        self._wall_hits = {1: 0, -1: 0}
        self.sensitivity = SensitivityEstimator(self.cfg.degrees_per_mouse_unit)

    # -- apurit ------------------------------------------------------------

    def _ingest(self, obs: Observation) -> float:
        """Paivittaa lennossa olevat pulssit ja palauttaa ennustetun kulman.

        Ilman tata ohjain nakisi saman virheen useassa perakkaisessa
        pulssissa ja ylittaisi tavoitteen reilusti: naytonlukuviive on
        moninkertainen pulssivaliin nahden.
        """
        if obs.stamp > self._last_stamp:
            consumed = sum(u for t, u in self._pulse_log if t <= obs.stamp)
            if consumed and self._last_stamp_pick is not None:
                moved = obs.pick - self._last_stamp_pick
                if self.cfg.learn_sensitivity:
                    self.sensitivity.feed(consumed, moved)
                    self.cfg.degrees_per_mouse_unit = self.sensitivity.value
                self._check_wall(consumed, moved, obs.pick)
            self._pulse_log = [(t, u) for t, u in self._pulse_log if t > obs.stamp]
            self._inflight_units = sum(u for _, u in self._pulse_log)
            self._last_stamp = obs.stamp
            self._last_stamp_pick = obs.pick

        return obs.pick + self._inflight_units * self.cfg.degrees_per_mouse_unit

    def _check_wall(self, consumed: float, moved: float, pick: float) -> None:
        """Oppii tiirikan aariasennot, mutta varovasti.

        Vaarin tunnistettu seina on pahempi kuin tunnistamatta jaanyt: se
        kutistaisi hakualueen yhteen pisteeseen. Siksi seina hyvaksytaan vain
        aarialueella, vain hiiren liikkuessa, vain useasta perakkaisesta
        havainnosta, eika jana saa koskaan kutistua liikaa.
        """
        if self.phase != self.TRAVEL:
            return
        direction = 1 if consumed > 0 else -1
        if abs(consumed) < self.cfg.edge_stall_units:
            return
        if abs(moved) >= self.cfg.edge_stall_degrees:
            self._wall_hits[direction] = 0
            return
        if abs(pick) < self.cfg.edge_only_beyond_degrees:
            self._wall_hits[direction] = 0
            return

        self._wall_hits[direction] += 1
        if self._wall_hits[direction] < self.cfg.edge_stall_hits:
            return

        if direction > 0:
            candidate = min(self.edge_high, pick)
            if candidate - self.edge_low >= self.cfg.edge_minimum_span_degrees:
                self.edge_high = candidate
        else:
            candidate = max(self.edge_low, pick)
            if self.edge_high - candidate >= self.cfg.edge_minimum_span_degrees:
                self.edge_low = candidate

    def _clamp_to_edges(self, target: float) -> float:
        margin = self.cfg.edge_margin_degrees
        low = self.edge_low + margin if self.edge_low > PICK_MIN else PICK_MIN
        high = self.edge_high - margin if self.edge_high < PICK_MAX else PICK_MAX
        if low > high:
            low = high = (low + high) / 2.0
        return max(low, min(high, target))

    def _emit_pulse(self, now: float, units: float) -> None:
        self._pulse_log.append((now, units))
        self._inflight_units += units

    def _note_turn_rate(self, rate: float) -> None:
        if not (20.0 <= rate <= 2000.0):
            return
        self._turn_rate_samples.append(rate)
        if len(self._turn_rate_samples) > 40:
            self._turn_rate_samples.pop(0)

        if not self.cfg.auto_raise_hold_cap:
            return
        needed = full_turn_ms(self.measured_turn_rate)
        if needed and self.cfg.maximum_hold_ms < needed * 1.4:
            # Hatakatko ei saa koskaan katkaista kesken taytta kaantoa.
            self.cfg.maximum_hold_ms = round(needed * 1.6)

    def _pulse_limit_units(self) -> float:
        return (self.cfg.ramp_mouse_max_units_per_pulse if self.planner.ramp_locked
                else self.cfg.scan_mouse_max_units_per_pulse)

    def _take_target(self, now: float) -> bool:
        nxt = self.planner.next_target()
        if nxt is None:
            self.phase = self.DONE
            return False
        self.target = self._clamp_to_edges(nxt)
        self.phase = self.TRAVEL
        self._phase_started = now
        self._next_pulse = now
        return True

    def _commit(self, now: float, kind_hint: str = "") -> str:
        score = max(0.0, self._peak - self._hold_started_turn)
        kind = self.planner.record(self.target if self.target is not None else 0.0, score)
        self.probes.append(Probe(
            pick=self.target if self.target is not None else 0.0,
            score=score,
            ramp=self.planner.ramp_locked,
            kind=kind_hint or kind,
        ))
        return kind

    @property
    def measured_turn_rate(self) -> float | None:
        """Mitattu pesan kaantonopeus asteina sekunnissa, jos sita on nahty."""
        if not self._turn_rate_samples:
            return None
        ordered = sorted(self._turn_rate_samples)
        return ordered[len(ordered) // 2]

    # -- paasilmukka -------------------------------------------------------

    def update(self, now: float, obs: Observation) -> Action:
        if not obs.ok:
            # Tunnistus katkesi. F ylos, mutta mittaukset sailyvat.
            return Action(phase=self.phase, note="ei tunnistusta")

        predicted_pick = self._ingest(obs)

        if self.target is None:
            if not self._take_target(now):
                return Action(phase=self.DONE, note="skannaus lapi")

        if self.phase == self.TRAVEL:
            return self._travel(now, obs, predicted_pick)
        if self.phase == self.HOLD:
            return self._hold(now, obs)
        if self.phase == self.RELEASE:
            return self._release(now, obs)
        if self.phase == self.FINISH:
            return self._finish(now, obs)
        return Action(phase=self.DONE, note="odottaa ajan loppua")

    def _travel(self, now: float, obs: Observation, predicted_pick: float) -> Action:
        error = (self.target or 0.0) - predicted_pick

        if abs(error) <= self.cfg.arrive_tolerance_degrees:
            self.phase = self.HOLD
            self._phase_started = now
            self._last_progress = now
            self._peak = obs.turn
            self._hold_started_turn = obs.turn
            return Action(f_down=True, phase=self.HOLD, note=f"testi {self.target:+.1f}")

        if now < self._next_pulse:
            return Action(phase=self.TRAVEL, note="pulssien valissa")

        self._next_pulse = now + self.cfg.mouse_pulse_interval_ms / 1000.0
        limit = self._pulse_limit_units()
        units = error / max(1e-6, self.cfg.degrees_per_mouse_unit)
        units = max(-limit, min(limit, units))
        self._emit_pulse(now, units)
        return Action(mouse_units=units, phase=self.TRAVEL,
                      note=f"kohti {self.target:+.1f} ({error:+.1f})")

    def _hold(self, now: float, obs: Observation) -> Action:
        elapsed_ms = (now - self._phase_started) * 1000.0

        if obs.turn > self._peak + self.cfg.progress_epsilon_degrees:
            if self._last_progress > self._phase_started:
                delta_turn = obs.turn - self._peak
                delta_t = now - self._last_progress
                if delta_t > 0.004:
                    self._note_turn_rate(delta_turn / delta_t)
            self._peak = obs.turn
            self._last_progress = now
        elif obs.turn > self._peak:
            self._peak = obs.turn

        # Lahes taysi kaanto: pidetaan pohjassa loppuun asti.
        if self._peak >= self.cfg.near_open_degrees:
            self.phase = self.FINISH
            self._phase_started = now
            self._last_progress = now
            return Action(f_down=True, phase=self.FINISH, note="viimeistely")

        stalled_ms = (now - self._last_progress) * 1000.0
        release = (elapsed_ms >= self.cfg.minimum_hold_ms
                   and stalled_ms >= self.cfg.stall_release_ms)
        if not release and elapsed_ms >= self.cfg.maximum_hold_ms:
            release = True

        if release:
            kind = self._commit(now)
            self.phase = self.RELEASE
            self._phase_started = now
            self._release_ready = None
            return Action(phase=self.RELEASE,
                          note=f"{self._peak - self._hold_started_turn:.1f} deg / {kind}")

        return Action(f_down=True, phase=self.HOLD, note=f"{obs.turn:.1f} deg")

    def _release(self, now: float, obs: Observation) -> Action:
        if obs.turn <= self.cfg.release_turn_threshold and self._release_ready is None:
            self._release_ready = now + self.cfg.release_settle_ms / 1000.0

        if self._release_ready is not None and now >= self._release_ready:
            self.target = None
            if not self._take_target(now):
                return Action(phase=self.DONE, note="skannaus lapi")
            return Action(phase=self.TRAVEL, note="seuraava piste")

        return Action(phase=self.RELEASE, note="pesa palautuu")

    def _finish(self, now: float, obs: Observation) -> Action:
        if obs.turn > self._peak + self.cfg.progress_epsilon_degrees:
            self._peak = obs.turn
            self._last_progress = now

        # Jos kaanto pysahtyy, kohta ei ollut ydin. Jatkuva painaminen
        # kuluttaisi vain tiirikkaa, joten palataan hakuun.
        if (now - self._last_progress) * 1000.0 >= self.cfg.stall_release_ms * 4:
            self._commit(now, "lahes")
            self.phase = self.RELEASE
            self._phase_started = now
            self._release_ready = None
            return Action(phase=self.RELEASE, note="ei ollut ydin")

        return Action(f_down=True, phase=self.FINISH, note=f"{obs.turn:.1f} deg")


# --------------------------------------------------------------------------
# Hiiriherkkyyden mittaus
# --------------------------------------------------------------------------


class SensitivityEstimator:
    """Paivittaa asteet/hiiriyksikko -arvion toteutuneesta liikkeesta.

    Ilman tata koko haku riippuu siita, etta kayttajan pelin hiiriherkkyys
    sattuu vastaamaan asetustiedoston oletusta.
    """

    def __init__(self, initial: float, minimum: float = 0.004, maximum: float = 0.5):
        self.value = initial
        self.minimum = minimum
        self.maximum = maximum
        self.samples: list[float] = []

    def feed(self, units: float, degrees_moved: float) -> None:
        if abs(units) < 8.0 or abs(degrees_moved) < 0.4:
            return
        if units * degrees_moved <= 0:      # vastakkainen suunta, hylataan
            return
        ratio = abs(degrees_moved) / abs(units)
        if not (self.minimum <= ratio <= self.maximum):
            return
        self.samples.append(ratio)
        if len(self.samples) > 40:
            self.samples.pop(0)
        ordered = sorted(self.samples)
        self.value = ordered[len(ordered) // 2]

    @property
    def confident(self) -> bool:
        return len(self.samples) >= 5


def wrap_angle(angle: float, near: float) -> float:
    """Palauttaa kulman +-180 asteen haarasta, joka on lahinna arvoa near."""
    while angle - near > 90.0:
        angle -= 180.0
    while near - angle > 90.0:
        angle += 180.0
    return angle


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def full_turn_ms(turn_rate: float | None) -> float | None:
    if not turn_rate or turn_rate <= 1.0:
        return None
    return 90.0 / turn_rate * 1000.0


def degrees(radians: float) -> float:
    return radians * 180.0 / math.pi
