"""Ajaa live-ohjaimen simuloitua lukkoa vasten: python test_live.py

Taman paketin tarkein testi. Se todistaa, etta se sama lockpick_control.py,
joka ajaa pelia, avaa simuloidun lukon - ja etta se tekee sen NAKEMATTA
TIIRIKKAA. Ohjain saa tietaa vain lukkopesan kaannon.

Simulaatio muuntaa hiiriyksikot asteiksi omalla kertoimellaan, jota ohjain
ei tieda. Juuri se on koko pointti: pelin hiiriherkkyys saa olla mika tahansa.
"""

from __future__ import annotations

import os
import random
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "sim"))

from lockpick_control import (  # noqa: E402
    ControlConfig,
    Controller,
    Observation,
    SearchMemory,
)
from lockpick_model import PICK_MAX, PICK_MIN, LockAttempt, LockConfig  # noqa: E402

DT = 0.002
FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"  {'OK  ' if condition else 'FAIL'}  {name}" + (f"   {detail}" if detail else ""))
    if not condition:
        FAILURES.append(name)


class SimulatedScreen:
    """Vastaa live-skriptin Detectoria: viive, ruutuvali ja lukutarkkuus.

    Palauttaa VAIN lukkopesan kaannon. Tiirikan asentoa ei anneta, koska
    ohjain ei sita nae pelissakaan.
    """

    def __init__(self, attempt, rng, latency_ms=45.0, frame_ms=8.0,
                 noise_deg=0.8, quantum_deg=0.5):
        self.attempt = attempt
        self.rng = rng
        self.latency = latency_ms / 1000.0
        self.frame = frame_ms / 1000.0
        self.noise = noise_deg
        self.quantum = quantum_deg
        self.buffer: list[tuple[float, float]] = []
        self.latest = Observation(ok=False)
        self.next_sample = 0.0

    def read(self, now: float) -> Observation:
        self.buffer.append((now, self.attempt.turn))
        if now < self.next_sample:
            return self.latest
        self.next_sample = now + self.frame

        cutoff = now - self.latency
        chosen, keep = None, 0
        for i, (stamp, turn) in enumerate(self.buffer):
            if stamp <= cutoff:
                chosen, keep = (stamp, turn), i
            else:
                break
        if chosen is None:
            return self.latest
        self.buffer = self.buffer[keep:]

        stamp, turn = chosen
        noisy = turn + self.rng.gauss(0.0, self.noise)
        noisy = max(0.0, round(noisy / self.quantum) * self.quantum)
        self.latest = Observation(
            stamp=stamp, ok=True, turn=noisy,
            timer=self.attempt.time_left / self.attempt.time_limit, running=True)
        return self.latest


def run_attempt(lock_cfg, ctrl_cfg, rng, deg_per_unit, memory,
                start_pick=0.0, carried_wear=0.0, sweet_spot=None, **screen_kwargs):
    """Yksi yritys. deg_per_unit on pelin herkkyys, jota ohjain ei tieda."""
    attempt = LockAttempt(lock_cfg, rng, sweet_spot=sweet_spot)
    attempt.wear = carried_wear
    attempt.pick = start_pick

    controller = Controller(ctrl_cfg, memory)
    screen = SimulatedScreen(attempt, rng, **screen_kwargs)

    pick = start_pick
    now = 0.0
    guard = int(attempt.time_limit / DT) + 80
    for _ in range(guard):
        if attempt.finished:
            break
        action = controller.update(now, screen.read(now))
        if action.mouse_units:
            # Seina: ylimaarainen liike reunaa vasten ei siirra mitaan.
            pick = max(PICK_MIN, min(PICK_MAX, pick + action.mouse_units * deg_per_unit))
        attempt.step(DT, pick, action.f_down)
        now += DT

    controller.finish_attempt(attempt.opened)
    return attempt, controller, pick


def run_session(lock_cfg, ctrl_cfg, rng, deg_per_unit, max_attempts=6,
                stable_sweet_spot=False, **kw):
    memory = SearchMemory()
    pick, wear = 0.0, 0.0
    controller = None
    spot = None
    if stable_sweet_spot:
        margin = lock_cfg.zone_half * 0.25
        spot = rng.uniform(PICK_MIN + margin, PICK_MAX - margin)
    for n in range(1, max_attempts + 1):
        attempt, controller, pick = run_attempt(
            lock_cfg, ctrl_cfg, rng, deg_per_unit, memory,
            start_pick=pick, carried_wear=wear, sweet_spot=spot, **kw)
        if attempt.opened:
            return True, n, controller
        wear = 0.0 if attempt.broken else attempt.wear
    return False, max_attempts, controller


def batch(lock_cfg, sessions=120, seed=4242, deg_per_unit=0.035,
          max_attempts=6, stable_sweet_spot=False, **cfg_kwargs):
    rng = random.Random(seed)
    opened, first = 0, 0
    attempts = []
    for _ in range(sessions):
        cfg = ControlConfig(**cfg_kwargs)      # tuore konfiguraatio per sessio
        ok, n, _ = run_session(lock_cfg, cfg, rng, deg_per_unit, max_attempts,
                               stable_sweet_spot=stable_sweet_spot)
        if ok:
            opened += 1
            attempts.append(n)
            if n == 1:
                first += 1
    return {
        "success": opened / sessions,
        "first": first / sessions,
        "attempts": statistics.fmean(attempts) if attempts else float("nan"),
    }


# --------------------------------------------------------------------------


def test_opens_without_seeing_the_pick() -> None:
    print("Lukko aukeaa ilman tiirikan tunnistusta")
    for tier in ["rusted", "basic", "medium", "enforced"]:
        stats = batch(LockConfig(tier=tier, skill=1), sessions=120)
        check(f"{tier}: avautuu yli 85 % sessioista", stats["success"] > 0.85,
              f"{stats['success'] * 100:.1f} %, keskim. {stats['attempts']:.2f} yritysta")


def test_unknown_mouse_sensitivity() -> None:
    """Ohjain ei tieda pelin herkkyytta. Sen ei kuulukaan tietaa."""
    print("Hiiriherkkyys saa olla mika tahansa")
    lock = LockConfig(tier="basic", skill=1)
    for deg_per_unit in [0.015, 0.035, 0.060, 0.090]:
        stats = batch(lock, sessions=100, deg_per_unit=deg_per_unit, max_attempts=8)
        check(f"{deg_per_unit:.3f} deg/yksikko", stats["success"] > 0.80,
              f"{stats['success'] * 100:.1f} %, keskim. {stats['attempts']:.2f} yritysta")


def test_homing_finds_the_wall() -> None:
    """Vasen reuna loydetaan tyontamalla, ei mittaamalla."""
    print("Kotiinajo loytaa vasemman reunan mista tahansa")
    rng = random.Random(5)
    for start in [PICK_MIN, -20.0, 0.0, 30.0, PICK_MAX]:
        cfg = ControlConfig()
        attempt, controller, _ = run_attempt(
            LockConfig(tier="rusted", skill=3), cfg, rng, 0.035, SearchMemory(),
            start_pick=start, sweet_spot=PICK_MIN + 6.0)
        first = controller.probes[0].position if controller.probes else None
        check(f"aloitus {start:+.0f} deg -> ensimmainen testi vasemmalla",
              attempt.opened or (first is not None and first < 200),
              "aukesi" if attempt.opened else f"{first:.0f} u")


def test_search_runs_left_to_right() -> None:
    print("Haku alkaa vasemmalta ja etenee oikealle")
    rng = random.Random(7)
    cfg = ControlConfig()
    _, controller, _ = run_attempt(LockConfig(tier="enforced", skill=3), cfg, rng,
                                   0.035, SearchMemory(), sweet_spot=55.0)
    # Sweetspot on oikeassa reunassa, joten se on loydettava pitkalta
    # matkalta vasemmalta lahtien.
    sweet_units = (55.0 - PICK_MIN) / 0.035
    windows = [p.position for p in controller.probes if p.kind == "ikkuna"]
    check("vasteikkuna loytyi", bool(windows), f"{len(controller.probes)} merkintaa")
    check("ikkuna loydettiin sweetspotin vasemmalta puolelta",
          bool(windows) and windows[0] <= sweet_units,
          f"{windows[0]:.0f} u vs sweetspot {sweet_units:.0f} u" if windows else "")
    check("pyyhkaisyn merkinnat etenevat oikealle",
          all(b >= a - 1e-6 for a, b in zip(windows, windows[1:])),
          f"{len(windows)} ikkunaa")


def test_rising_turn_is_never_cut() -> None:
    """Helperi 1.8:n paavika: F vapautettiin kesken kasvavan kaannon."""
    print("Kasvavaa kaantoa ei katkaista")
    rng = random.Random(11)
    attempt, controller, _ = run_attempt(
        LockConfig(tier="basic", skill=2), ControlConfig(), rng, 0.035,
        SearchMemory(), sweet_spot=PICK_MIN + 4.0)
    check("reunan lahella oleva sweetspot aukeaa", attempt.opened,
          f"kaanto {attempt.turn:.1f} deg")
    rate = controller.measured_turn_rate
    check("kaantonopeus mitattiin ajon aikana", rate is not None and rate > 50,
          f"{rate:.0f} deg/s" if rate else "ei mittausta")


def test_holding_f_is_what_makes_it_work() -> None:
    """Vanhan version paavika oli, etta F irtosi kesken kaannon.

    Uudessa rakenteessa F on pohjassa jo pyyhkaisyn aikana. Se ei ole
    makuasia vaan koko haun perusta: pesa kaantyy vain kun F on pohjassa,
    joten ilman sita ikkunaa ei voi havaita lainkaan.
    """
    print("F pohjassa pyyhkaisyn aikana on koko haun perusta")
    lock = LockConfig(tier="basic", skill=1)
    held = batch(lock, sessions=60)
    tapped = batch(lock, sessions=60, sweep_hold_f=False)
    check("F pohjassa: lukko aukeaa", held["success"] > 0.80,
          f"{held['success'] * 100:.1f} %")
    # F ylhaalla haku ei loyda ikkunaa lainkaan: se paatyy painamaan F:aa
    # vain silloin kun kohina sattuu ylittamaan kynnyksen, eli umpimahkaan.
    # Talla mallilla vasteikkuna on leveimmillaan noin 500 yksikkoa, joten
    # umpimahkainenkin painelu osuu joskus - mutta selvasti harvemmin.
    check("F ylhaalla pyyhkaisyssa: haku muuttuu umpimahkaiseksi",
          tapped["success"] < held["success"] - 0.10,
          f"{tapped['success'] * 100:.1f} % vs {held['success'] * 100:.1f} %")


def test_search_memory_defaults() -> None:
    """Mita muistetaan yritysten valilla ja miksi.

    Sweetspotin PAIKKAA ei muisteta: pelaajien mukaan se vaihtuu, ja niin
    se vaihtui myos kayttajan omassa nauhoituksessa (kerran 957, kerran
    3052 yksikon kohdalla).

    Pyyhkaisyn jatkaminen edellisen yrityksen paattymiskohdasta oli
    RIKKI: kytkin oli olemassa, mutta se ei siirtanyt hiirta minnekaan.
    Nyt siirtyma tehdaan oikeasti, mutta kun sen sai vihdoin mitattua,
    kavi ilmi ettei siita ole hyotya - joten oletus on yha pois.

    Muistiin jaa vain se, mika kertoo KONEESTA eika lukosta: havainnon
    viive ja yrityksen kesto.
    """
    print("Muistin oletukset")
    cfg = ControlConfig()
    check("sweetspotin paikkaa ei muisteta", cfg.remember_zone is False)
    check("pyyhkaisya ei jatketa edellisesta kohdasta",
          cfg.resume_search is False)

    lock = LockConfig(tier="basic", skill=1)

    # SEEK-vaihe toimii, vaikka se ei ole oletuksena kaytossa: kytkimen
    # paalle laittaminen ei saa rikkoa mitaan. Tasmallinen vertailu
    # tehdaan lock_sim-mallilla (live/test_strategy.py), jossa on varaa
    # ajaa tarpeeksi sessioita eron erottamiseen kohinasta.
    for deg_per_unit in (0.012, 0.035):
        on = batch(lock, sessions=60, deg_per_unit=deg_per_unit,
                   max_attempts=6, resume_search=True)
        check(f"jana {126 / deg_per_unit:.0f} u: SEEK-vaihe toimii",
              on["success"] > 0.50, f"{on['success'] * 100:.1f} %")

    # Ikkunan paikan muistaminen ei auta, koska sweetspot vaihtuu.
    zone_on = batch(lock, sessions=100, max_attempts=6, remember_zone=True)
    zone_off = batch(lock, sessions=100, max_attempts=6)
    check("vaihtuvalla sweetspotilla ikkunan muisti ei auta",
          zone_off["success"] >= zone_on["success"] - 0.02,
          f"pois {zone_off['success'] * 100:.1f} % vs "
          f"paalla {zone_on['success'] * 100:.1f} %")

    # Mitatut olosuhteet sen sijaan sailyvat.
    memory = SearchMemory()
    rng = random.Random(23)
    run_attempt(lock, ControlConfig(), rng, 0.035, memory, sweet_spot=20.0)
    check("havainnon viive jai muistiin", memory.lag_ms is not None,
          f"{memory.lag_ms:.0f} ms" if memory.lag_ms else "ei mittausta")


def test_sweep_step_must_fit_the_window() -> None:
    """Vanha 300 yksikon askel hyppasi mitatun ~120 yksikon ikkunan yli.

    Tama on nauhoituksen selkein yksittainen loydos: 12 yrityksesta
    viidessa pesa ei kaantynyt kertaakaan yli kuuden asteen, koska haku
    ei kertaakaan pysahtynyt ikkunan kohdalle.
    """
    print("Pyyhkaisyaskel mahtuu vasteikkunaan")
    lock = LockConfig(tier="basic", skill=1)
    # Talla mallilla vasteikkuna on noin 500 yksikkoa leveimmillaan, joten
    # askelen on selvasti ylitettava se ennen kuin ikkuna alkaa jaada
    # askelten valiin.
    fine = batch(lock, sessions=60)
    coarse = batch(lock, sessions=60, sweep_step_units=1200.0)
    check("mitattu askel avaa lukon", fine["success"] > 0.80,
          f"{fine['success'] * 100:.1f} %")
    check("ikkunaa leveampi askel hyppaa sen yli",
          coarse["success"] < fine["success"],
          f"1200 u: {coarse['success'] * 100:.1f} % vs "
          f"{ControlConfig().sweep_step_units:.0f} u: {fine['success'] * 100:.1f} %")


def test_no_input_without_detection() -> None:
    print("Ilman lukkoa ei laheteta syotteita")
    controller = Controller(ControlConfig())
    action = controller.update(0.0, Observation(ok=False))
    check("hiiri ei liiku", action.mouse_units == 0.0)
    check("F ei mene pohjaan", action.f_down is False)


def test_only_turn_is_used() -> None:
    """Varmistaa ettei havainnossa ole tiirikkaa eika ohjain sita kaipaa."""
    print("Havainto sisaltaa vain lukon tiedot")
    fields = set(Observation.__dataclass_fields__)
    check("Observationissa ei ole pick-kentta", "pick" not in fields,
          ", ".join(sorted(fields)))
    rng = random.Random(17)
    attempt, controller, _ = run_attempt(
        LockConfig(tier="basic", skill=2), ControlConfig(), rng, 0.035,
        SearchMemory(), sweet_spot=10.0)
    check("ohjain teki paatoksia pelkalla kaannolla",
          attempt.opened or len(controller.probes) > 0,
          f"{len(controller.probes)} testia")



def test_residual_turn_does_not_fake_a_window() -> None:
    """Debug 22:54:07: yritys alkoi noin 13.9 asteen residuaalikulmasta.

    Jos kynnys laskettaisiin nollasta, tama olisi heti "ikkuna". Siksi
    lepokulma MITATAAN yrityksen ensimmaisista ruuduista ja kynnys
    lasketaan siita.
    """
    print("Residuaalikulma ei saa muuttua vaaraksi ikkunaksi")
    controller = Controller(ControlConfig(), SearchMemory())
    controller.phase = controller.SWEEP
    controller._sweep_started = 0.0

    now = 0.0
    for _ in range(200):
        controller.update(now, Observation(stamp=now, ok=True, turn=13.9,
                                           running=True))
        now += 0.005

    check("lepokulma mitattiin oikein", abs(controller.rest_angle - 13.9) < 0.2,
          f"{controller.rest_angle:.1f} deg")
    check("ikkunaa ei lukittu", not controller.planner.ramp_locked)
    check("pyyhkaisy jatkuu", controller.phase == controller.SWEEP,
          controller.phase)


def test_drive_never_lets_go_of_a_rising_turn() -> None:
    """Kun pesa kaantyy, F ei saa irrota. Vanha versio irrotti 260 ms:ssa."""
    print("Nouseva kaanto pitaa F:n pohjassa")
    controller = Controller(ControlConfig(), SearchMemory())
    controller.phase = controller.SWEEP
    controller._sweep_started = 0.0

    now = 0.0
    for _ in range(10):                      # lepokulman mittaus
        controller.update(now, Observation(stamp=now, ok=True, turn=1.0,
                                           running=True))
        now += 0.005
    controller.update(now, Observation(stamp=now, ok=True, turn=60.0, running=True))
    check("vaste vei ajovaiheeseen", controller.phase == controller.DRIVE,
          controller.phase)

    released = 0
    turn = 60.0
    for _ in range(120):                     # 600 ms nousevaa kaantoa
        now += 0.005
        turn = min(88.0, turn + 0.25)
        action = controller.update(now, Observation(stamp=now, ok=True,
                                                    turn=turn, running=True))
        if not action.f_down:
            released += 1
    check("600 ms nousua ilman yhtaan irrotusta", released == 0,
          f"{released} irrotusta, kaanto {turn:.1f} deg")


def main() -> int:
    for test in [
        test_opens_without_seeing_the_pick,
        test_unknown_mouse_sensitivity,
        test_homing_finds_the_wall,
        test_search_runs_left_to_right,
        test_rising_turn_is_never_cut,
        test_holding_f_is_what_makes_it_work,
        test_search_memory_defaults,
        test_sweep_step_must_fit_the_window,
        test_residual_turn_does_not_fake_a_window,
        test_drive_never_lets_go_of_a_rising_turn,
        test_no_input_without_detection,
        test_only_turn_is_used,
    ]:
        test()
        print()

    if FAILURES:
        print(f"{len(FAILURES)} testia epaonnistui: {', '.join(FAILURES)}")
        return 1
    print("Kaikki live-logiikan testit lapi.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
