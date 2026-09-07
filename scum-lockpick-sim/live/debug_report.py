"""Tekee debug-paketista tai pelaajanauhoituksesta visuaalisen raportin.

    python debug_report.py                        (uusin paketti automaattisesti)
    python debug_report.py traces/debug_20260907_015126
    python debug_report.py manual_records/player_20260907_0130
    python debug_report.py botti_kansio pelaaja_kansio      (vertailu)
    python debug_report.py --avaa                 (avaa raportti selaimeen)

Windowsissa helpoin tapa on Tee_Raportti.bat: se ottaa uusimman paketin ja
avaa raportin suoraan selaimeen.

Tuloksena on yksi HTML-tiedosto, jonka voi avata selaimessa. Se ei tarvitse
verkkoa eika kirjastoja: kuvaajat piirretaan SVG:na suoraan.

Raportti nayttaa jokaisesta yrityksesta:

    * lukkopesan kaanto ajan funktiona
    * milloin F oli pohjassa (varjostus)
    * hiiren paikka (bottikaynnissa hiiriyksikkoina, pelaajalla kursorina)
    * mihin yritys paattyi ja mika oli suurin kaanto

Nain nakee yhdella silmayksella, mihin aika meni ja missa kohtaa loppupeli
epaonnistui - se on tarkein asia, jota pelkat numerot eivat kerro.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))

# Vari- ja mittavakiot ------------------------------------------------------

W, H = 1180, 230           # yhden kuvaajan koko
PAD_L, PAD_R, PAD_T, PAD_B = 62, 18, 16, 34
INK = "#0d0f0e"
PANEL = "#161a18"
LINE = "#2b322d"
STEEL = "#c3cabe"
DIM = "#828b7f"
BRASS = "#c8a24a"
GOOD = "#6fbf7a"
BAD = "#c4553f"
PICK = "#b8434a"
SUCCESS_ANGLE = 90.0


@dataclass
class Sample:
    t: float
    turn: float | None
    ok: bool
    running: bool
    f_down: bool
    position: float | None = None
    cursor_x: float | None = None
    phase: str = ""
    note: str = ""


@dataclass
class Attempt:
    index: int
    samples: list = field(default_factory=list)
    outcome: str = "?"

    @property
    def duration(self) -> float:
        return self.samples[-1].t - self.samples[0].t if len(self.samples) > 1 else 0.0

    @property
    def max_turn(self) -> float:
        vals = [s.turn for s in self.samples if s.turn is not None]
        return max(vals) if vals else 0.0

    @property
    def f_seconds(self) -> float:
        total = 0.0
        for a, b in zip(self.samples, self.samples[1:]):
            if a.f_down:
                total += b.t - a.t
        return total

    def first_response_at(self, threshold: float = 5.0) -> float | None:
        base = self.samples[0].turn or 0.0
        for s in self.samples:
            if s.turn is not None and s.turn - base >= threshold:
                return s.t - self.samples[0].t
        return None


# --------------------------------------------------------------------------
# Lukeminen
# --------------------------------------------------------------------------


def read_bot_trace(folder: str) -> list[Sample]:
    path = os.path.join(folder, "trace.jsonl")
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        obs = row.get("obs") or {}
        action = row.get("action") or {}
        ctrl = row.get("controller") or {}
        out.append(Sample(
            t=float(row.get("t_perf", 0.0)),
            turn=obs.get("turn") if obs.get("ok") else None,
            ok=bool(obs.get("ok")),
            running=bool(obs.get("running")),
            f_down=bool(action.get("f_down") or (row.get("keys") or {}).get("F")),
            position=ctrl.get("position_u"),
            phase=action.get("phase", "") or row.get("state", ""),
            note=action.get("note", ""),
        ))
    return out


def read_player_telemetry(folder: str) -> list[Sample]:
    path = os.path.join(folder, "telemetry.jsonl")
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        obs = row.get("observation") or {}
        cur = row.get("cursor") or {}
        out.append(Sample(
            t=float(row.get("t", 0.0)),
            turn=obs.get("turn") if obs.get("ok") else None,
            ok=bool(obs.get("ok")),
            running=bool(obs.get("running")),
            f_down=bool((row.get("keys") or {}).get("F")),
            cursor_x=cur.get("x"),
            phase=row.get("app_state", ""),
        ))
    return out


def load(folder: str):
    """Palauttaa (nimi, naytteet). Tunnistaa lahteen automaattisesti."""
    samples = read_bot_trace(folder)
    if samples:
        return "botti", samples
    samples = read_player_telemetry(folder)
    if samples:
        return "pelaaja", samples
    return "tuntematon", []


def split_attempts(samples: list[Sample]) -> list[Attempt]:
    """Jakaa naytteet yrityksiin: yritys kay niin kauan kuin ajastin kay."""
    attempts: list[Attempt] = []
    current: Attempt | None = None
    for s in samples:
        if s.running and s.ok:
            if current is None:
                current = Attempt(index=len(attempts) + 1)
                attempts.append(current)
            current.samples.append(s)
        else:
            if current is not None and len(current.samples) > 4:
                current.outcome = ("AUKI" if current.max_turn >= SUCCESS_ANGLE - 6
                                   else "aika loppui")
            current = None
    if current is not None and len(current.samples) > 4:
        current.outcome = ("AUKI" if current.max_turn >= SUCCESS_ANGLE - 6
                           else "kesken")
    return [a for a in attempts if len(a.samples) > 4]


# --------------------------------------------------------------------------
# Piirto
# --------------------------------------------------------------------------


def esc(text) -> str:
    return (str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def chart(attempt: Attempt) -> str:
    """Yhden yrityksen kuvaaja: kaanto, F-varjostus ja hiiren paikka."""
    s0 = attempt.samples[0].t
    dur = max(0.001, attempt.duration)
    pw, ph = W - PAD_L - PAD_R, H - PAD_T - PAD_B

    def X(t):
        return PAD_L + (t - s0) / dur * pw

    def Y(a):
        return PAD_T + ph - min(1.0, max(0.0, a / 100.0)) * ph

    parts = [f'<svg viewBox="0 0 {W} {H}" width="100%" role="img">']
    parts.append(f'<rect width="{W}" height="{H}" fill="{INK}"/>')

    # F pohjassa -varjostus
    run_start = None
    for a, b in zip(attempt.samples, attempt.samples[1:]):
        if a.f_down and run_start is None:
            run_start = a.t
        if run_start is not None and not b.f_down:
            parts.append(f'<rect x="{X(run_start):.1f}" y="{PAD_T}" '
                         f'width="{max(1.0, X(b.t) - X(run_start)):.1f}" height="{ph}" '
                         f'fill="{BRASS}" opacity="0.13"/>')
            run_start = None
    if run_start is not None:
        parts.append(f'<rect x="{X(run_start):.1f}" y="{PAD_T}" '
                     f'width="{max(1.0, X(attempt.samples[-1].t) - X(run_start)):.1f}" '
                     f'height="{ph}" fill="{BRASS}" opacity="0.13"/>')

    # ruudukko
    for v in (0, 30, 60, 90):
        y = Y(v)
        parts.append(f'<line x1="{PAD_L}" y1="{y:.1f}" x2="{PAD_L + pw}" y2="{y:.1f}" '
                     f'stroke="{LINE}" stroke-width="1"/>')
        parts.append(f'<text x="{PAD_L - 8}" y="{y + 4:.1f}" fill="{DIM}" '
                     f'font-size="12" text-anchor="end" font-family="monospace">{v}°</text>')
    parts.append(f'<line x1="{PAD_L}" y1="{Y(SUCCESS_ANGLE):.1f}" x2="{PAD_L + pw}" '
                 f'y2="{Y(SUCCESS_ANGLE):.1f}" stroke="{GOOD}" stroke-width="1.5" '
                 f'stroke-dasharray="6 5"/>')

    # hiiren paikka taustalle
    positions = [(s.t, s.position if s.position is not None else s.cursor_x)
                 for s in attempt.samples]
    positions = [(t, p) for t, p in positions if p is not None]
    if len(positions) > 2:
        lo = min(p for _, p in positions)
        hi = max(p for _, p in positions)
        if hi - lo > 1:
            pts = " ".join(f"{X(t):.1f},{PAD_T + ph - (p - lo) / (hi - lo) * ph:.1f}"
                           for t, p in positions)
            parts.append(f'<polyline points="{pts}" fill="none" stroke="{PICK}" '
                         f'stroke-width="1.2" opacity="0.55"/>')

    # kaanto
    pts, run = [], []
    for s in attempt.samples:
        if s.turn is None:
            if len(run) > 1:
                pts.append(run)
            run = []
        else:
            run.append(f"{X(s.t):.1f},{Y(s.turn):.1f}")
    if len(run) > 1:
        pts.append(run)
    for run in pts:
        parts.append(f'<polyline points="{" ".join(run)}" fill="none" '
                     f'stroke="{STEEL}" stroke-width="2"/>')

    # aika-akseli
    for k in range(5):
        t = s0 + dur * k / 4
        parts.append(f'<text x="{X(t):.1f}" y="{H - 10}" fill="{DIM}" font-size="12" '
                     f'text-anchor="middle" font-family="monospace">{(t - s0):.1f}s</text>')

    parts.append('</svg>')
    return "".join(parts)


def stats_row(attempt: Attempt) -> str:
    found = attempt.first_response_at()
    colour = GOOD if attempt.outcome == "AUKI" else BAD
    return (f'<tr><td>{attempt.index}</td>'
            f'<td style="color:{colour}">{esc(attempt.outcome)}</td>'
            f'<td>{attempt.duration:.2f} s</td>'
            f'<td>{attempt.max_turn:.1f}°</td>'
            f'<td>{"-" if found is None else f"{found:.2f} s"}</td>'
            f'<td>{attempt.f_seconds:.2f} s</td>'
            f'<td>{attempt.f_seconds / max(0.001, attempt.duration) * 100:.0f} %</td>'
            f'<td>{len(attempt.samples)}</td></tr>')


def section(title: str, kind: str, attempts: list[Attempt]) -> str:
    opened = sum(1 for a in attempts if a.outcome == "AUKI")
    best = max((a.max_turn for a in attempts), default=0.0)
    near = sum(1 for a in attempts if 60 <= a.max_turn < SUCCESS_ANGLE - 6)
    html = [f'<section><h2>{esc(title)} <span class="tag">{esc(kind)}</span></h2>']
    html.append('<div class="kpis">'
                f'<div><dt>Yrityksia</dt><dd>{len(attempts)}</dd></div>'
                f'<div><dt>Avautui</dt><dd>{opened}</dd></div>'
                f'<div><dt>Onnistumis-%</dt><dd>'
                f'{opened / max(1, len(attempts)) * 100:.0f} %</dd></div>'
                f'<div><dt>Suurin kaanto</dt><dd>{best:.1f}°</dd></div>'
                f'<div><dt>Jai loppupeliin</dt><dd>{near}</dd></div>'
                '</div>')
    html.append('<table class="data"><thead><tr><th>#</th><th>lopputulos</th>'
                '<th>kesto</th><th>suurin kaanto</th><th>ikkuna loytyi</th>'
                '<th>F pohjassa</th><th>osuus</th><th>naytteita</th></tr></thead><tbody>')
    html += [stats_row(a) for a in attempts]
    html.append('</tbody></table>')
    for a in attempts:
        html.append(f'<h3>Yritys {a.index} &mdash; {esc(a.outcome)}, '
                    f'suurin kaanto {a.max_turn:.1f}°</h3>')
        html.append(f'<div class="chart">{chart(a)}</div>')
    html.append('</section>')
    return "".join(html)


PAGE = """<!doctype html><html lang="fi"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Autolockpick debug</title><style>
body{{margin:0;background:{ink};color:{steel};font:14px/1.5 system-ui,sans-serif}}
.wrap{{max-width:1240px;margin:0 auto;padding:24px 16px 48px}}
h1{{font-size:26px;letter-spacing:.04em;margin:0 0 4px}}
h2{{font-size:17px;margin:32px 0 10px;border-bottom:1px solid {line};padding-bottom:6px}}
h3{{font-size:13px;color:{dim};font-weight:600;margin:18px 0 4px}}
.tag{{font-size:11px;color:{brass};border:1px solid {line};padding:2px 7px;margin-left:8px}}
.lead{{color:{dim};max-width:70ch}}
.kpis{{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:1px;
 background:{line};border:1px solid {line};margin:12px 0}}
.kpis div{{background:{panel};padding:10px}}
.kpis dt{{font-size:10px;letter-spacing:.12em;text-transform:uppercase;color:{dim};margin:0}}
.kpis dd{{margin:2px 0 0;font-size:19px;font-variant-numeric:tabular-nums}}
table.data{{border-collapse:collapse;width:100%;font:12px monospace;margin:8px 0}}
table.data th{{text-align:right;color:{dim};font-weight:600;padding:5px 8px;
 border-bottom:1px solid {line};font-size:10px;letter-spacing:.1em;text-transform:uppercase}}
table.data td{{text-align:right;padding:4px 8px;border-bottom:1px solid #1a1e1b}}
table.data td:first-child,table.data th:first-child{{text-align:left}}
.chart{{background:{panel};border:1px solid {line};padding:6px}}
.legend{{display:flex;gap:20px;font:11px monospace;color:{dim};margin:10px 0}}
.legend i{{display:inline-block;width:14px;height:3px;vertical-align:middle;margin-right:5px}}
</style></head><body><div class="wrap">
<h1>Autolockpick &mdash; debug</h1>
<p class="lead">Jokainen kuvaaja on yksi lockpick-yritys. Valkoinen viiva on
lukkopesan kaanto, messinkinen varjostus kertoo milloin F oli pohjassa, ja
punainen viiva on hiiren paikka. Vihrea katkoviiva on 90 asteen
onnistumiskulma.</p>
<div class="legend">
<span><i style="background:{steel}"></i>lukkopesan kaanto</span>
<span><i style="background:{brass}"></i>F pohjassa</span>
<span><i style="background:{pick}"></i>hiiren paikka</span>
<span><i style="background:{good}"></i>onnistumiskulma</span>
</div>
{body}
</div></body></html>"""


def build(folders: list[str], output: str) -> str:
    sections = []
    for folder in folders:
        kind, samples = load(folder)
        attempts = split_attempts(samples)
        if not attempts:
            sections.append(f'<section><h2>{esc(os.path.basename(folder))}</h2>'
                            f'<p class="lead">Ei tunnistettuja yrityksia '
                            f'({len(samples)} naytetta, lahde: {esc(kind)}).</p></section>')
            continue
        sections.append(section(os.path.basename(folder), kind, attempts))

    html = PAGE.format(ink=INK, panel=PANEL, line=LINE, steel=STEEL, dim=DIM,
                       brass=BRASS, good=GOOD, pick=PICK, body="".join(sections))
    with open(output, "w", encoding="utf-8") as handle:
        handle.write(html)
    return output


def newest_folders() -> list:
    """Uusin bottipaketti ja uusin pelaajanauhoitus, jos niita loytyy.

    Nain raportin saa ilman polkujen naputtelua: yleisin tarve on katsoa
    juuri aiemmin ajettu yritys, ja jos samassa paketissa on molemmat,
    botti ja pelaaja tulevat automaattisesti vierekkain.
    """
    found = []
    for parent in ("traces", "manual_records"):
        base = os.path.join(HERE, parent)
        if not os.path.isdir(base):
            continue
        subs = [os.path.join(base, name) for name in os.listdir(base)]
        subs = [d for d in subs if os.path.isdir(d)]
        if subs:
            found.append(max(subs, key=os.path.getmtime))
    return found


def open_in_browser(path: str) -> None:
    try:
        import webbrowser
        webbrowser.open("file://" + os.path.abspath(path))
    except Exception as error:                       # ei kaada raportin tekoa
        print(f"  (selainta ei saatu auki: {error})")


def main(argv=None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    show = "--avaa" in args
    args = [a for a in args if a != "--avaa"]
    output = "debug_raportti.html"
    if args and args[-1].endswith(".html"):
        output = args.pop()
    folders = [a for a in args if os.path.isdir(a)]
    if not folders:
        folders = newest_folders()
        if folders:
            print("Kansiota ei annettu, kaytetaan uusimpia:")
            for folder in folders:
                print(f"  {folder}")
    if not folders:
        print(__doc__)
        print("Yhtaan debug-pakettia tai nauhoitusta ei loytynyt.")
        print("Aja ensin Aja_Live.bat ja paina F8 (debug-paketti) tai")
        print("F7 (pelaajanauhoitus).")
        return 2
    path = build(folders, output)
    print(f"Raportti kirjoitettu: {os.path.abspath(path)}")
    if show:
        open_in_browser(path)
    for folder in folders:
        kind, samples = load(folder)
        print(f"  {os.path.basename(folder):40} {kind:9} "
              f"{len(samples):5} naytetta, {len(split_attempts(samples))} yritysta")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
