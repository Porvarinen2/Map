"""Autolockpickin paatoslogiikka: SWEEP + DRIVE.

Lukkopesa on ainoa mittari. Tiirikkaa ei tunnisteta lainkaan, ja hiirta
ohjataan hiiriyksikkoina, joten pelin hiiriherkkyytta ei tarvitse tietaa.

=====================================================================
MITTAUKSET, JOIDEN VARAAN TAMA ON RAKENNETTU
=====================================================================

Kaikki alla oleva on luettu kayttajan omista nauhoituksista
(live/traces/debug_20260907_015126) ja pelin referenssikuvista:

  lepokulma            0.8 - 2.9 astetta  (kohinaa, ei liiketta)
  onnistumiskulma      86 - 91 astetta    (success_angles-kuvat)
  pesan kaantonopeus   ~139 astetta/s     (mitattu kaannon aikana)
  taysi kaanto         ~0.65 s
  vasteikkunan leveys  >= 100 hiiriyksikkoa
                       (vihje kohdassa 900 u, taysi kaanto 952 u;
                        vihje 3000 u, kaanto 3052 u)
  koko jana            ~3600 hiiriyksikkoa
  yrityksen kesto      2.5 - 3.9 s

=====================================================================
MIKSI VANHA TAPA EI RIITTANYT
=====================================================================

Vanha haku teki erillisia F-testeja: nappaus, F ylos, katso vaste,
siirry. Yksi testi maksoi noin 220 ms ja siirtyma oli 300 yksikkoa.
Kaksi seurausta, jotka nakyvat suoraan nauhoituksessa:

1. 300 yksikon askel HYPPAA vasteikkunan yli. Kahdestatoista yrityksesta
   viidessa pesa ei kaantynyt kertaakaan yli kuuden asteen: ikkuna jai
   kahden testin valiin.

2. Kun ikkuna loytyi, aikaa oli jaljella liian vahan. Yrityksessa 10
   ikkuna loytyi vasta 2.9 sekunnin kohdalla, pesa ehti kaantya 83
   asteeseen ja aika loppui kesken.

=====================================================================
UUSI TAPA
=====================================================================

    HOME    hiiri vasempaan aariasentoon, F ylhaalla

    SWEEP   F POHJASSA koko ajan. Hiiri matelee oikealle pienin askelin
            ja pysahtyy hetkeksi joka askeleen jalkeen. Pesa alkaa
            kaantya heti kun ikkunaan osutaan, joten haku ja kaannon
            aloitus tapahtuvat samalla kertaa. 60 yksikon askel ei voi
            hypata yli 100 yksikon ikkunasta.

    DRIVE   F PYSYY POHJASSA. Pesa kaantyy. Ohjain ei paasta irti eika
            palaa testaamaan: se vain odottaa. Jos kaanto pysahtyy,
            hiirta siirretaan pieni nykays ja F pidetaan yha pohjassa.
            Lahella 90 astetta nykays on minimaalinen.

Ratkaiseva ero on se, etta DRIVE ei irrota F:aa. Nauhoituksessa juuri
tama oli voittava siirto: kun pesa jumitti 89 asteeseen, viiden yksikon
nykays vei sen 91.8 asteeseen ja lukko aukesi.
"""

from __future__ import annotations

from dataclasses import dataclass, field


# --------------------------------------------------------------------------
# Asetukset
# --------------------------------------------------------------------------


@dataclass
class ControlConfig:
    """Matkat hiiriyksikkoina, kulmat asteina, ajat millisekunteina."""

    # ---- kotiinajo ----
    # Tama tyonnetaan vasemmalle joka yrityksen alussa. Seinaa vasten
    # ylimaarainen liike ei tee mitaan, joten lahtokohta on aina sama.
    home_units: float = 9000.0
    home_pulse_units: float = 1500.0
    home_pulse_interval_ms: float = 12.0
    # Kuinka pitkalle oikealle pyyhkaisya jatketaan ennen kuin palataan
    # alkuun. Tama ei ole arvaus janan pituudesta vaan siita, kuinka
    # pitkalle YHDESSA yrityksessa ehtii: noin 1700 yksikkoa sekunnissa
    # kertaa kolme sekuntia. Pidemmalle suunnitteleminen on turhaa, koska
    # sweetspot arvotaan joka yrityksella uudelleen - mitatussa
    # nauhoituksessa se oli kerran 957 ja kerran 3052 yksikon kohdalla.
    # Mitattu: 5000 antoi 89.6 %, 9000 antoi 84.4 % (live/test_live.py,
    # hiiriherkkyydet 0.010 - 0.090 deg/yksikko).
    span_guess_units: float = 5000.0

    # ---- SWEEP: F pohjassa, hiiri matelee oikealle ----
    # Askel on selvasti alle mitatun vasteikkunan (>= 100 u), joten
    # ikkuna ei voi jaada kahden askeleen valiin.
    sweep_step_units: float = 110.0
    sweep_dwell_ms: float = 45.0             # paikallaan askeleen jalkeen
    sweep_trigger_degrees: float = 3.0       # tama lepokulman ylitse = ikkuna
    sweep_hold_f: bool = True                # F pohjassa myos pyyhkaisyn aikana
    # Havainto on vanha: nousu alkoi runsaan askeleen verran taaempaa.
    # Peruutus on ASKELEINA, joten se skaalautuu itsestaan pyyhkaisyn
    # nopeuden mukana. Mitattu ajovaiheen viive EI kelpaa tahan, koska
    # se sisaltaa myos pesan lahtoviiveen: hitaalla pesalla se veisi
    # peruutuksen kokonaan vasteikkunan ulkopuolelle (mitattu 71 -> 59 %).
    sweep_lag_steps: float = 1.0

    # ---- DRIVE: F pohjassa, pesa kaantyy ----
    drive_nudge_with_f_down: bool = True     # liike F pohjassa (nopein)

    # DRIVE ryomii kohti sweetspottia F pohjassa. Askel skaalataan sen
    # mukaan, kuinka kaukana maalista ollaan: kaanto kertoo etaisyyden.
    # Kaukana (kaanto 20) otetaan 20 yksikon askel, lahella (kaanto 85)
    # kahden yksikon askel. Nain lahestyminen on nopeaa muttei ohita
    # kolmen yksikon levyista ydinta.
    drive_creep_gain: float = 0.28           # yksikkoa per puuttuva aste
    drive_creep_min_units: float = 9.0
    drive_creep_max_units: float = 60.0
    # Asettumisaika ja suuntapaatoksen kynnys skaalataan MITATTUIHIN
    # olosuhteisiin: hidas ruudunluku tarvitsee pidemman odotuksen ja
    # kohinainen kulmalukema suuremman kynnyksen. Ilman tata ohjain
    # romahtaa heti kun kone tai peli kayttaytyy toisin kuin viritettaessa.
    # Askel otetaan vasta kun pesa on PYSAHTYNYT. Se on valttamatonta:
    # kesken nousun kulmalukema aliarvioi laheisyyden, jolloin askel
    # hyppaa sweetspotin yli. Mitattu vertailu: pysahtymista odottava
    # strategia 45.6 %, tasaisin valein astuva 28.6 % (live/test_strategy.py).
    drive_settle_ms: float = 65.0            # vahimmaisaika ilman muutosta
    drive_settle_frames: float = 2.0         # ... ja vahintaan nain monta ruutua
    # Ikkunassa oltava nain monta ERI RUUTUA. Aikavaatimus (yo.) maaraa
    # kaytannossa naytemaaran; tama on vain alaraja, jotta puolikkaiden
    # mediaanit voidaan ylipaataan laskea. Yli kolme kaantaa asetelman:
    # neljalla ruudulla 65 %, viidella 22 % (16 mallimuunnelmaa).
    drive_settle_samples: int = 3
    drive_trend_degrees: float = 0.4         # puolikkaiden ero: alle taman asettunut
    drive_trend_noise_factor: float = 0.8    # ... tai nain monta kertaa kohina
    drive_worse_degrees: float = 0.7         # suuntapaatoksen kynnys
    drive_noise_factor: float = 1.6          # ... tai nain monta kertaa kohina
    drive_final_window_degrees: float = 8.0  # tata lahempana maalia hienoaskel
    drive_final_step_units: float = 3.5
    # Kun hienoaskel ylittaa ytimen (kaanto huononee), ydin on viimeisen
    # kahden kohdan valissa. Silloin askel puolitetaan: puolitushaku.
    # Ilman tata kapea ydin jaa loputtomasti askelten valiin, koska
    # askel ei koskaan mene alle drive_final_step_unitsin.
    drive_min_step_units: float = 1.0
    drive_bisect_factor: float = 0.5

    # Havainto on vanha. Askelen jalkeen ruudulla nakyy viela edellinen
    # tilanne, jota ei saa tulkita asettumiseksi. Vanhuus ei ole arvaus:
    # jokainen havainto kertoo itse kaappaushetkensa (obs.stamp), joten
    # riittaa odottaa ensimmainen havainto joka on kaapattu askelen
    # JALKEEN. Sen paalle lisataan pelin oma piirtoviive, jota ruudulta
    # ei voi mitata.
    # Simulaattorissa aikaleima on tasmallinen, joten viritys aanestaisi
    # tahan nollaa. Oikeassa pelissa aikaleima otetaan vasta kaappauksen
    # alkaessa, joten pelin oma piirtoviive (tyypillisesti 1-3 ruutua) jaa
    # mittaamatta. Siksi tassa on pieni vara, jota simulaatio ei osaa
    # perustella. Mitattu hinta simulaatiossa: alle prosenttiyksikko.
    render_lag_ms: float = 15.0
    drive_dead_max_ms: float = 200.0         # varmistus jos aikaleima pettaa

    # Kun kaanto on maalissa muttei aukea, ote on vaarassa kohdassa
    # muutaman yksikon verran. Nauhoituksessa juuri irrotus + pieni
    # nykays vei 89 asteesta 91.8 asteeseen ja lukko aukesi.
    goal_stall_ms: float = 220.0

    # Loppukiri: kun aika on lopussa ja pesa on jo lahella maalia,
    # asettumisen odottaminen maksaa enemman kuin se hyodyttaa. Silloin
    # otetaan pienia askelia nykyiseen suuntaan niin tiheaan kuin ehtii.
    sprint_after_fraction: float = 0.86      # osuus yrityksen kestosta
    sprint_above_degrees: float = 30.0       # vain jos ollaan jo lahella
    sprint_interval_ms: float = 45.0
    expected_attempt_seconds: float = 3.0    # ennen ensimmaista mittausta

    # Jos nykaykset eivat auta, F paastetaan hetkeksi irti ja otetaan uusi
    # ote. Nauhoituksessa juuri tama vei 89 asteesta 91.8 asteeseen.
    rebite_after_stalls: int = 9
    rebite_release_ms: float = 80.0
    # Kun vaste hukkuu, ikkunaa haetaan ensin nain monta askelta
    # molemmin puolin ennen kuin palataan koko janan pyyhkaisyyn.
    rescan_steps: int = 2

    # ---- yhteiset ----
    max_units_per_pulse: float = 240.0
    pulse_interval_ms: float = 20.0
    success_angle_degrees: float = 90.0      # mitattu success-kuvista (86-91)
    give_up_below_degrees: float = 3.0       # tama on pelkkaa kohinaa
    rest_samples: int = 6                    # lepokulman naytteet yrityksen alussa

    # ---- muisti yritysten valilla ----
    # Jos jana on pidempi kuin yhdessa yrityksessa ehtii pyyhkaista, joka
    # yrityksen aloittaminen vasemmasta reunasta jattaa oikean puoliskon
    # ikuisesti kayvattamatta. Siksi seuraava yritys jatkaa siita mihin
    # edellinen jai. Tama EI oleta sweetspotin pysyvan paikallaan: jos se
    # vaihtuu, mika tahansa yhta pitka patka on yhta hyva paikka etsia.
    resume_search: bool = True
    # Siirtyma aloituskohtaan tehdaan samalla vauhdilla kuin kotiinajo.
    # Pyyhkaisyn 110 yksikon pulsseilla se veisi turhaan aikaa, ja koska
    # kotiinajo jo todistaa etta tallainen pulssi menee pelille perille,
    # ei ole syyta liikkua hitaammin. Mitattuna 240 - 1500 yksikon
    # pulssien ero jai kohinan sisaan (92 % vs 94 %), koska siirtyma on
    # kaytannossa lyhyt: yksi yritys ehtii pyyhkaista koko janan.
    seek_pulse_units: float = 1500.0
    seek_pulse_interval_ms: float = 12.0
    remember_zone: bool = False


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
    resume_units: float = 0.0
    zone_units: float | None = None
    zone_score: float = 0.0
    sweeps: int = 0
    wraps: int = 0

    # Mitatut olosuhteet. Nama EIVAT liity sweetspotin paikkaan vaan
    # koneeseen ja peliin, joten ne kannattaa muistaa yritysten yli
    # vaikka paikkamuisti on pois paalta.
    lag_ms: float | None = None
    attempt_seconds: float | None = None

    def forget_position(self) -> None:
        self.resume_units = 0.0


@dataclass
class Bookkeeping:
    """Nakyvyys kayttoliittymalle ja debug-paketille."""

    ramp_locked: bool = False
    best_units: float | None = None
    best_score: float = 0.0
    step: float = 0.0
    local_direction: int = 1
    responding: list = field(default_factory=list)
    samples: list = field(default_factory=list)


# --------------------------------------------------------------------------
# Ohjain
# --------------------------------------------------------------------------


class Controller:
    """Ajaa yhta lockpick-yritysta.

    Vaiheet:
        home    hiiri vasempaan reunaan, F ylhaalla
        seek    nopea siirto edellisen pyyhkaisyn paattymiskohtaan
        sweep   F pohjassa, hiiri matelee oikealle, odotetaan kaantoa
        drive   F pohjassa, pesa kaantyy, nykaykset vain jos se pysahtyy
        rebite  lyhyt F:n irrotus kun nykaykset eivat auta
        done    jana kayty lapi
    """

    HOME, SEEK, SWEEP, DRIVE, REBITE, DONE = (
        "home", "seek", "sweep", "drive", "rebite", "done")

    def __init__(self, cfg: ControlConfig, memory: SearchMemory | None = None):
        self.cfg = cfg
        self.memory = memory if memory is not None else SearchMemory()
        self.reset()

    # ---------------------------------------------------------------- setup

    def reset(self) -> None:
        self.phase = self.HOME
        self.position = 0.0
        self.target = 0.0
        self.probes: list[Probe] = []
        self.planner = Bookkeeping(step=self.cfg.drive_creep_max_units)

        self._homed = 0.0
        self._next_pulse = 0.0
        self._phase_started = 0.0

        # lepokulma mitataan yrityksen alussa
        self._rest_values: list[float] = []
        self.rest_angle = 0.0

        # kaannon seuranta
        self._peak = 0.0
        self._last_rise = 0.0
        self._last_value = 0.0
        self._turn_rates: list[float] = []

        # DRIVE
        self._nudge_direction = 1
        self._stall_count = 0
        self._entered_drive_at = 0.0
        self._drive_entry_position = 0.0
        self._rebite_until = 0.0
        self._creep_scale = 1.0
        self._settles = 0
        self._settled_value = 0.0
        self._last_change = 0.0
        # Hienoaskel kutistuu puolitushaussa, kun ydin on ohitettu.
        self._fine_step = self.cfg.drive_final_step_units
        # Maalikulmassa vietetty aika: jos lukko ei aukea, ote on vaarassa.
        self._goal_since = -1.0
        self._next_sprint = 0.0
        # Mitatut olosuhteet: ruutuvali ja kulmalukeman kohina.
        self._frame_gaps: list[float] = []
        self._angle_jitter: list[float] = []
        self._last_stamp = -1.0
        self._last_raw = 0.0
        # Havainnon viive mitataan: aika askeleesta ensimmaiseen
        # kulmamuutokseen. Se kertoo kuinka kauan ruudulla nakyy viela
        # vanha tilanne, eli kuinka pitkaan asettumista on odotettava.
        self._lag_samples: list[float] = []
        self._stepped_at = -1.0
        # Yrityksen kesto mitataan, jotta loppukiri osataan ajoittaa.
        self._started_at = -1.0
        self._elapsed = 0.0
        # Asettumisikkuna: (hetki, kulma). Asettuminen paatellaan ikkunan
        # vaihteluvalista eika yksittaisista ruutueroista, jotta kohina ei
        # tulkitse liiketta pysahtymiseksi eika painvastoin.
        self._window: list[tuple[float, float]] = []
        # Ikkunaan otetaan vain UUDET ruudut. Ohjain paivittyy monta kertaa
        # yhden ruudun aikana, joten ilman tata sama lukema tulisi ikkunaan
        # seitsemasti ja mediaani laskettaisiin kopioista - jolloin
        # keskiarvoistus ei vaimenna kohinaa lainkaan.
        self._window_stamp = -1.0
        # Paikallinen uusintahaku, kun vaste hukkuu ikkunan lahella.
        self._rescan_left = 0
        self._rescan_anchor = 0.0
        self._rescan_index = 0

        # SWEEP
        self._dwell_until = 0.0
        self._sweep_started = 0.0
        self._seek_target = 0.0

    # ------------------------------------------------------------ mittarit

    @property
    def measured_turn_rate(self) -> float | None:
        if not self._turn_rates:
            return None
        ordered = sorted(self._turn_rates)
        return ordered[len(ordered) // 2]

    @property
    def scan_step(self) -> float:
        return self.cfg.sweep_step_units

    @property
    def response(self) -> float:
        """Kuinka paljon pesa on kaantynyt lepoasennosta."""
        return max(0.0, self._peak - self.rest_angle)

    @property
    def frame_ms(self) -> float:
        """Mitattu ruutuvali. Kertoo kuinka kauan asettumista on odotettava."""
        if len(self._frame_gaps) < 4:
            return 30.0
        ordered = sorted(self._frame_gaps)
        return ordered[len(ordered) // 2] * 1000.0

    # Perakkaisten lukemien erotusten alaneljannes suhteessa kohinan
    # keskihajontaan. Jos lukemat ovat riippumatonta normaalikohinaa
    # hajonnalla s, erotuksen hajonta on s*sqrt(2) ja itseisarvon
    # alaneljannes on 0.3186 * s * sqrt(2) = 0.4506 * s. Kertoimella
    # 1/0.4506 = 2.22 alaneljanneksesta saadaan takaisin s.
    NOISE_FROM_QUARTILE = 2.22

    @property
    def noise_degrees(self) -> float:
        """Mitattu kulmalukeman kohina keskihajontana.

        Kaytetaan perakkaisten lukemien erotusten ALANELJANNESTA, koska
        kun pesa kaantyy, erot ovat suuria ja mediaani mittaisi kaantoa
        eika kohinaa. Alaneljannes on kuitenkin vain 0.45-kertainen
        hajontaan nahden, joten se on skaalattava takaisin - muuten
        kohina aliarvioidaan yli kaksinkertaisesti ja kaikki siita
        johdetut kynnykset jaavat liian tiukoiksi.
        """
        if len(self._angle_jitter) < 8:
            return 0.5
        ordered = sorted(self._angle_jitter)
        return max(0.25, self.NOISE_FROM_QUARTILE * ordered[len(ordered) // 4])

    @property
    def lag_ms(self) -> float:
        """Mitattu havainnon vanhuus: nyt miinus kaappaushetki.

        Tama mitataan suoraan aikaleimasta eika paattelemalla pesan
        liikkeesta. Se on tarkeaa, koska pesan liikkeesta paatelty viive
        sisaltaisi myos pesan oman lahtoviiveen: hitaalla pesalla se
        kaksinkertaistuisi ja ohjain jaisi odottamaan turhaan.
        """
        if len(self._lag_samples) < 4:
            if self.memory.lag_ms is not None:
                return self.memory.lag_ms
            return self.cfg.render_lag_ms
        ordered = sorted(self._lag_samples)
        return clamp(ordered[len(ordered) // 2] * 1000.0 + self.cfg.render_lag_ms,
                     1.0, self.cfg.drive_dead_max_ms)

    @property
    def expected_seconds(self) -> float:
        """Mitattu yrityksen kesto. Kertoo milloin on loppukirin aika."""
        if self.memory.attempt_seconds is not None:
            return self.memory.attempt_seconds
        return self.cfg.expected_attempt_seconds

    def _settle_limit_ms(self) -> float:
        return max(self.cfg.drive_settle_ms,
                   self.cfg.drive_settle_frames * self.frame_ms)

    def _stale(self, now: float, obs: Observation) -> bool:
        """Onko havainto kaapattu ennen viimeista askelta?

        Aikaleima kertoo sen suoraan. Varmistuksena on aikakatko: jos
        aikaleimaan ei voi luottaa, odottaminen loppuu joka tapauksessa.
        """
        if self._stepped_at < 0.0:
            return False
        if now - self._stepped_at >= self.cfg.drive_dead_max_ms / 1000.0:
            return False
        extra = self.cfg.render_lag_ms / 1000.0
        if obs.stamp <= 0.0:
            return now - self._stepped_at < extra
        return obs.stamp < self._stepped_at + extra

    def _change_threshold(self) -> float:
        return max(1.0, self.cfg.drive_noise_factor * self.noise_degrees)

    def _note_rate(self, rate: float) -> None:
        if 20.0 <= rate <= 3000.0:
            self._turn_rates.append(rate)
            del self._turn_rates[:-40]

    def _pulse(self, now: float, units: float, phase: str, note: str,
               f_down: bool) -> Action:
        self._next_pulse = now + self.cfg.pulse_interval_ms / 1000.0
        self.position += units
        return Action(mouse_units=units, f_down=f_down, phase=phase, note=note)

    def _mark_step(self, now: float) -> None:
        """Merkitsee hetken, jonka jalkeen kaapatut havainnot ovat tuoreita."""
        self._stepped_at = now
        self._window = []
        self._window_stamp = -1.0

    def _record(self, position: float, score: float, kind: str) -> None:
        self.probes.append(Probe(position=position, score=score,
                                 ramp=self.planner.ramp_locked, kind=kind))
        self.planner.samples.append((position, score))
        if score >= self.cfg.sweep_trigger_degrees:
            self.planner.responding.append(position)
        if score > self.planner.best_score:
            self.planner.best_score = score
            self.planner.best_units = position
            self.memory.zone_units = position
            self.memory.zone_score = score

    # -------------------------------------------------------------- runko

    def update(self, now: float, obs: Observation) -> Action:
        if not obs.ok:
            # Lukkoa ei nay. F ylos, mutta paikka ja mittaukset sailyvat.
            return Action(phase=self.phase, note="ei lukkoa nakyvissa")

        if self._started_at < 0.0:
            self._started_at = now
        self._elapsed = now - self._started_at

        # Lepokulma mitataan yrityksen ensimmaisista ruuduista, jotta
        # kynnykset ovat oikeat myos jos pesa lepaa hieman vinossa.
        if len(self._rest_values) < self.cfg.rest_samples:
            self._rest_values.append(obs.turn)
            self.rest_angle = sorted(self._rest_values)[len(self._rest_values) // 2]
            self._peak = obs.turn
            self._last_value = obs.turn
            self._last_rise = now

        if obs.stamp > self._last_stamp:
            if self._last_stamp > 0:
                gap = obs.stamp - self._last_stamp
                if 0.001 < gap < 0.5:
                    self._frame_gaps.append(gap)
                    del self._frame_gaps[:-40]
                self._angle_jitter.append(abs(obs.turn - self._last_raw))
                del self._angle_jitter[:-60]
            self._last_raw = obs.turn
            self._last_stamp = obs.stamp

        self._track(now, obs)

        if self.phase == self.HOME:
            return self._home(now, obs)
        if self.phase == self.SEEK:
            return self._seek(now, obs)
        if self.phase == self.SWEEP:
            return self._sweep(now, obs)
        if self.phase == self.DRIVE:
            return self._drive(now, obs)
        if self.phase == self.REBITE:
            return self._rebite(now, obs)
        return Action(phase=self.DONE, note="jana kayty")

    def _track(self, now: float, obs: Observation) -> None:
        """Seuraa huippua, nousua ja sita milloin kaanto viimeksi muuttui."""
        change = obs.turn - self._last_value
        threshold = self._change_threshold()

        # Havainnon vanhuus mitataan suoraan aikaleimasta.
        if 0.0 < obs.stamp <= now and now - obs.stamp < 0.5:
            self._lag_samples.append(now - obs.stamp)
            del self._lag_samples[:-40]
        if change > threshold:
            delta = now - self._last_rise
            if delta > 0.004:
                self._note_rate(change / delta)
            self._last_rise = now
        if abs(change) > threshold:
            self._last_change = now
        if abs(change) > threshold * 0.6:
            self._last_value = obs.turn
        self._peak = max(self._peak, obs.turn)

    # --------------------------------------------------------------- HOME

    def _home(self, now: float, obs: Observation) -> Action:
        if self._homed >= self.cfg.home_units:
            self.position = 0.0
            self.target = self._first_target()
            self._seek_target = self.target
            self._phase_started = now
            self._sweep_started = now
            self._next_pulse = now
            self._dwell_until = 0.0
            self._peak = obs.turn
            self._last_value = obs.turn
            self._last_rise = now
            if self._seek_target > self.cfg.sweep_step_units:
                self.phase = self.SEEK
                return Action(phase=self.SEEK,
                              note=f"siirtyy {self._seek_target:.0f} u kohtaan")
            self.phase = self.SWEEP
            return Action(phase=self.SWEEP, note="vasen reuna loydetty")

        if now < self._next_pulse:
            return Action(phase=self.HOME, note="kotiinajo")

        step = min(self.cfg.home_pulse_units, self.cfg.home_units - self._homed)
        self._homed += step
        self._next_pulse = now + self.cfg.home_pulse_interval_ms / 1000.0
        done = self._homed / self.cfg.home_units * 100.0
        return Action(mouse_units=-step, f_down=False, phase=self.HOME,
                      note=f"vasempaan reunaan {done:.0f} %")

    def _seek(self, now: float, obs: Observation) -> Action:
        """Nopea siirto aloituskohtaan. F on ylhaalla, jotta pesa lepaa
        ja lepokulma mitataan puhtaasta tilanteesta."""
        if self.position >= self._seek_target - 1e-6:
            self.phase = self.SWEEP
            self._phase_started = now
            self._sweep_started = now
            self._dwell_until = 0.0
            self._peak = obs.turn
            self._last_value = obs.turn
            self._last_rise = now
            return Action(phase=self.SWEEP,
                          note=f"aloitus {self.position:.0f} u")

        if now < self._next_pulse:
            return Action(phase=self.SEEK, note="siirtyy")

        step = min(self.cfg.seek_pulse_units, self._seek_target - self.position)
        self.position += step
        self._next_pulse = now + self.cfg.seek_pulse_interval_ms / 1000.0
        return Action(mouse_units=step, f_down=False, phase=self.SEEK,
                      note=f"siirtyy {self.position:.0f}/{self._seek_target:.0f} u")

    def _first_target(self) -> float:
        if self.cfg.remember_zone and self.memory.zone_units is not None:
            return max(0.0, self.memory.zone_units - 2 * self.cfg.sweep_step_units)
        if self.cfg.resume_search:
            return max(0.0, self.memory.resume_units)
        return 0.0

    # -------------------------------------------------------------- SWEEP

    def _sweep(self, now: float, obs: Observation) -> Action:
        """F pohjassa, hiiri matelee oikealle pienin askelin.

        Pesa alkaa kaantya heti kun ikkunaan osutaan, joten haku ja kaannon
        aloitus tapahtuvat samalla kertaa. Kun nousu havaitaan, liike
        perutaan sen verran kuin ehdittiin edeta havainnon viiveen aikana.
        """
        f_down = self.cfg.sweep_hold_f
        lift = obs.turn - self.rest_angle

        if lift >= self.cfg.sweep_trigger_degrees:
            # Havainto on vanha: nousu alkoi jo aiemmin. Perutaan sen
            # verran kuin hiiri ehti edeta ennen kuin nousu nakyi.
            back = self.cfg.sweep_lag_steps * self.cfg.sweep_step_units
            self._record(self.position, lift, "ikkuna")
            self.planner.ramp_locked = True
            self._enter_drive(now, obs)
            self._rescan_anchor = self.position - back
            self._rescan_left = self.cfg.rescan_steps
            self._rescan_index = 0
            if back > 0:
                return self._pulse(now, -back, self.DRIVE,
                                   f"IKKUNA {lift:.1f} deg -> peruutus {back:.0f} u",
                                   f_down=True)
            return Action(f_down=True, phase=self.DRIVE,
                          note=f"IKKUNA {lift:.1f} deg -> F pysyy pohjassa")

        # Jana loppui: kierretaan alkuun.
        if self.position >= self.cfg.span_guess_units:
            self.memory.wraps += 1
            self.position = 0.0
            self.memory.resume_units = 0.0
            self._record(self.position, 0.0, "kierros")
            return Action(f_down=f_down, phase=self.SWEEP, note="jana kayty, alusta")

        if now < self._dwell_until:
            return Action(f_down=f_down, phase=self.SWEEP,
                          note=f"paikallaan {self.position:.0f} u")

        if now < self._next_pulse:
            return Action(f_down=f_down, phase=self.SWEEP, note="pulssien valissa")

        step = min(self.cfg.sweep_step_units, self.cfg.max_units_per_pulse)
        self._dwell_until = now + self.cfg.sweep_dwell_ms / 1000.0
        self.memory.resume_units = self.position
        return self._pulse(now, step, self.SWEEP,
                           f"matelee {self.position:.0f} u", f_down=f_down)

    # -------------------------------------------------------------- DRIVE

    def _enter_drive(self, now: float, obs: Observation) -> None:
        self.phase = self.DRIVE
        self._phase_started = now
        self._entered_drive_at = now
        self._drive_entry_position = self.position
        self._last_rise = now
        self._stall_count = 0
        self._nudge_direction = 1
        self._creep_scale = 1.0
        self._settles = 0
        self._settled_value = obs.turn
        self._last_change = now
        self._goal_since = -1.0
        self._fine_step = self.cfg.drive_final_step_units
        self._mark_step(now)

    def _drive(self, now: float, obs: Observation) -> Action:
        """F PYSYY POHJASSA. Odota - astu - vertaa.

        Tama on koko ohjaimen tarkein vaihe.

        Perusidea: kun F on pohjassa, pesa kaantyy niin pitkalle kuin
        NYKYINEN kohta sallii, ja pysahtyy sitten. Se pysahtynyt lukema
        kertoo suoraan, kuinka kaukana sweetspotista ollaan - mitatusti
        58 yksikon paassa 4 astetta, 8 yksikon paassa 83 astetta.

        Siksi ohjain ei arvaa askelen pituutta vaan laskee sen puuttuvasta
        kaannosta: mita enemman 90 asteesta puuttuu, sita pidempi askel.
        Kun kaanto on jo 85, askel on vain pari yksikkoa, jottei kolmen
        yksikon levyista ydinta ohiteta.

        Suunta paatellaan vertaamalla kahta perakkaista pysahtynytta
        lukemaa. Nouseva lukema = oikea suunta, laskeva = vaara suunta.
        F ei irtoa valissa kertaakaan.
        """
        target = self.cfg.success_angle_degrees
        lift = obs.turn - self.rest_angle

        # Maalissa: ei enaa mitaan saatoa, anna pesan pyorahtaa loppuun.
        # Jos lukko ei kuitenkaan aukea, ote on muutaman yksikon verran
        # vaarassa kohdassa. Nauhoituksessa juuri irrotus ja pieni nykays
        # vei 89 asteesta 91.8 asteeseen ja lukko aukesi. Siksi maalissa
        # ei jaada odottamaan loputtomiin.
        if obs.turn >= target - 1.0:
            if self._goal_since < 0.0:
                self._goal_since = now
            if now - self._goal_since >= self.cfg.goal_stall_ms / 1000.0:
                self._goal_since = -1.0
                self.phase = self.REBITE
                self._phase_started = now
                self._rebite_until = now + self.cfg.rebite_release_ms / 1000.0
                return Action(f_down=False, phase=self.REBITE,
                              note=f"maalissa {obs.turn:.1f} deg muttei aukea "
                                   f"-> uusi ote")
            return Action(f_down=True, phase=self.DRIVE,
                          note=f"MAALISSA {obs.turn:.1f} deg -> F pohjassa")
        self._goal_since = -1.0

        # Loppukiri. Kun aika on lopussa ja pesa on jo lahella maalia,
        # asettumisen odottaminen maksaa enemman kuin se hyodyttaa: yksi
        # odotus vie sen ajan jolla ehtisi ottaa nelja askelta. Siksi
        # viimeisella hetkella otetaan pienia askelia nykyiseen suuntaan
        # niin tiheaan kuin ehtii ja luotetaan siihen etta ydin osuu.
        if (lift >= self.cfg.sprint_above_degrees
                and self._elapsed >= self.cfg.sprint_after_fraction
                * self.expected_seconds):
            if now < self._next_sprint or now < self._next_pulse:
                return Action(f_down=True, phase=self.DRIVE,
                              note=f"loppukiri {obs.turn:.1f} deg")
            self._next_sprint = now + self.cfg.sprint_interval_ms / 1000.0
            step = self._fine_step * self._nudge_direction
            self.planner.step = abs(step)
            return self._pulse(now, step, self.DRIVE,
                               f"LOPPUKIRI {obs.turn:.1f} deg {step:+.0f} u",
                               f_down=True)

        # Vaste hukkui. Ikkuna on kuitenkin lahella, joten palataan siihen
        # kohtaan jossa vaste oli paras eika jatketa pyyhkaisya eteenpain.
        if lift < self.cfg.give_up_below_degrees and self._settles > 0:
            self._record(self.position, lift, "hukkui")
            # Ikkuna on lahella, joten sita haetaan ensin paikallisesti
            # molemmilta puolilta. Vasta sitten palataan koko janan
            # pyyhkaisyyn. Ilman tata vaarin arvattu peruutus vie haun
            # ikkunan ohi eika sinne enaa palata.
            if self._rescan_left > 0:
                self._rescan_left -= 1
                self._rescan_index += 1
                offset = ((self._rescan_index + 1) // 2) * self.cfg.sweep_step_units
                if self._rescan_index % 2 == 0:
                    offset = -offset
                target_pos = self._rescan_anchor + offset
                jump = target_pos - self.position
                self._enter_drive(now, obs)
                self._nudge_direction = -1 if jump < 0 else 1
                return self._pulse(now, jump, self.DRIVE,
                                   f"paikallinen uusinta {target_pos:.0f} u",
                                   f_down=True)
            self.planner.ramp_locked = False
            self.phase = self.SWEEP
            self._phase_started = now
            self._dwell_until = 0.0
            self._peak = obs.turn
            return Action(f_down=self.cfg.sweep_hold_f, phase=self.SWEEP,
                          note="vaste hukkui -> takaisin pyyhkaisyyn")

        # Kuollut aika: heti askeleen jalkeen ruudulla nakyy viela
        # edellinen tilanne. Jos ne lukemat paastetaan asettumisikkunaan,
        # ohjain toteaa vanhan tasanteen asettumiseksi ja astuu heti
        # uudelleen. Silloin kaksi askelta menee yhden hinnalla ja
        # sweetspot ohitetaan.
        if self._stale(now, obs):
            return Action(f_down=True, phase=self.DRIVE,
                          note=f"vanha kuva {obs.turn:.1f} deg")

        # Kaanto elaa viela: odotetaan. Talla ohjain "uskaltaa" pitaa F:n
        # pohjassa sen sijaan etta hosuisi seuraavaan kohtaan.
        #
        # Asettuminen paatellaan vertaamalla ikkunan alkupuoliskon
        # mediaania loppupuoliskon mediaaniin. Mediaani kestaa kohinaa, ja
        # puolikkaiden ero mittaa nimenomaan TRENDIA - siis kaantyyko pesa
        # viela. Yksittaisten ruutuerojen vertailu petti kohinaisella
        # lukemalla.
        limit = self._settle_limit_ms() / 1000.0
        if obs.stamp <= 0.0 or obs.stamp > self._window_stamp:
            self._window_stamp = obs.stamp
            self._window.append((now, obs.turn))
        self._window = [(t, a) for t, a in self._window if now - t <= limit]
        n = len(self._window)
        span_ok = n and (now - self._window[0][0]) >= limit * 0.85
        if not span_ok or n < self.cfg.drive_settle_samples:
            return Action(f_down=True, phase=self.DRIVE,
                          note=f"kaantyy {obs.turn:.1f} deg")

        half = n // 2
        med = lambda xs: sorted(xs)[len(xs) // 2]
        first = med([a for _, a in self._window[:half]])
        second = med([a for _, a in self._window[half:]])
        trend_limit = max(self.cfg.drive_trend_degrees,
                          self.cfg.drive_trend_noise_factor * self.noise_degrees)
        if abs(second - first) > trend_limit:
            return Action(f_down=True, phase=self.DRIVE,
                          note=f"kaantyy {obs.turn:.1f} deg")

        settled = med([a for _, a in self._window])
        previous = self._settled_value
        self._settled_value = settled
        obs = Observation(stamp=obs.stamp, ok=True, turn=settled,
                          timer=obs.timer, running=obs.running)
        self._settles += 1
        self._record(self.position, lift, f"asettui {obs.turn:.0f}")

        if self._settles >= 2:
            decide = max(self.cfg.drive_worse_degrees,
                         self.cfg.drive_noise_factor * self.noise_degrees)
            gain = obs.turn - previous
            if gain < -decide:
                # Vaara suunta: kaanto huononi. Kaannytaan ja lyhennetaan.
                self._nudge_direction *= -1
                self._creep_scale = max(0.3, self._creep_scale * 0.55)
                self._stall_count += 1
                # Lahella maalia huononeva kaanto tarkoittaa, etta ydin
                # jai juuri taakse: se on viimeisen kahden kohdan valissa.
                # Puolitetaan hienoaskel, jolloin haku kiristyy ytimen
                # ymparille. Ilman tata kapea ydin jaa ikuisesti kahden
                # yhta pitkan askeleen valiin.
                if target - obs.turn <= self.cfg.drive_final_window_degrees:
                    self._fine_step = max(self.cfg.drive_min_step_units,
                                          self._fine_step
                                          * self.cfg.drive_bisect_factor)
            elif gain > decide:
                # Oikea suunta: pidetaan suunta ja luotetaan askeleeseen.
                self._stall_count = 0
                self._creep_scale = min(1.0, self._creep_scale * 1.25)
            else:
                # Tasanne: sama suunta mutta reilumpi askel.
                self._stall_count += 1
                self._creep_scale = min(1.6, self._creep_scale * 1.3)

        # Jos suunta heiluu eika mikaan auta, otetaan uusi ote F:sta.
        if self._stall_count >= self.cfg.rebite_after_stalls:
            self._stall_count = 0
            self.phase = self.REBITE
            self._phase_started = now
            self._rebite_until = now + self.cfg.rebite_release_ms / 1000.0
            return Action(f_down=False, phase=self.REBITE,
                          note=f"jumissa {obs.turn:.1f} deg -> uusi ote")

        step = self._creep_units(obs.turn, target) * self._nudge_direction
        self._mark_step(now)
        self._last_change = now
        self._last_rise = now
        self.planner.step = abs(step)
        self.planner.local_direction = self._nudge_direction

        return self._pulse(now, step, self.DRIVE,
                           f"{obs.turn:.1f} deg -> askel {step:+.0f} u",
                           f_down=self.cfg.drive_nudge_with_f_down)

    def _creep_units(self, angle: float, target: float) -> float:
        """Askelen pituus: puuttuva kaanto kertoo etaisyyden sweetspotista.

        Aivan maalin lahella kaytetaan hienompaa askelta, koska avaava
        ydin on vain muutaman hiiriyksikon levyinen: liian iso askel
        hyppaa sen yli kerta toisensa jalkeen.
        """
        remaining = max(0.0, target - angle)
        if remaining <= self.cfg.drive_final_window_degrees:
            # Hienoalue: askel on tasan puolitushaun mittainen. Se alkaa
            # ytimen levyisena ja puolittuu vasta kun ydin on ohitettu.
            # Askelta EI saa laskea puuttuvasta kaannosta, koska talla
            # alueella se olisi vain pari yksikkoa ja haku kavisi liian
            # hitaaksi ehtiakseen ajoissa perille.
            return self._fine_step
        step = self.cfg.drive_creep_gain * remaining * self._creep_scale
        return min(self.cfg.drive_creep_max_units,
                   max(self.cfg.drive_creep_min_units, step))

    # ------------------------------------------------------------- REBITE

    def _rebite(self, now: float, obs: Observation) -> Action:
        """Lyhyt F:n irrotus ja uusi ote.

        Nauhoituksessa pesa jumitti 89 asteeseen F pohjassa. Irrotus,
        pieni nykays ja uusi painallus vei sen 91.8 asteeseen ja lukko
        aukesi. Tama on siis mitattu siirto, ei arvaus.
        """
        if now < self._rebite_until:
            return Action(f_down=False, phase=self.REBITE, note="uusi ote")

        # Nykays on hienoaskelen mittainen: uusi ote otetaan siita
        # kohdasta johon oltiin jo paasty, ei kauempaa.
        fine = self._fine_step
        units = fine * self._nudge_direction
        self._enter_drive(now, obs)
        self._fine_step = fine
        self._peak = obs.turn
        return self._pulse(now, units, self.DRIVE,
                           f"uusi ote + nykays {units:+.0f} u", f_down=True)

    # ------------------------------------------------------- yrityksen loppu

    def finish_attempt(self, opened: bool) -> None:
        self.memory.sweeps += 1
        # Mitatut olosuhteet sailyvat yritysten yli: ne kertovat
        # koneesta ja pelista, eivat sweetspotin paikasta. Seuraava
        # yritys alkaa siis jo oikeilla kynnyksilla.
        if len(self._lag_samples) >= 4:
            self.memory.lag_ms = self.lag_ms
        if self._elapsed > 0.5:
            previous = self.memory.attempt_seconds
            self.memory.attempt_seconds = (self._elapsed if previous is None
                                           else 0.5 * (previous + self._elapsed))
        if opened:
            self.memory.forget_position()
            self.memory.zone_units = None
            self.memory.zone_score = 0.0


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
