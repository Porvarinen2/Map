#!/usr/bin/env python3
"""Ajaa koko kartanteon alusta loppuun ja jatkaa keskeytyneesta kohdasta.

    python tools/run_pipeline.py            # aja kaikki
    python tools/run_pipeline.py --from render
    python tools/run_pipeline.py --only ground --redo
    python tools/run_pipeline.py --check    # kuiva-ajo, ei tee mitaan

Tila kirjataan work/state.json. Renderointi kestaa tunteja, joten yksi katkos ei saa
tarkoittaa alusta aloittamista - jokainen valmis vaihe ohitetaan seuraavalla ajolla,
ja renderointi osaa lisaksi ohittaa jo valmiit tiilet yksitellen.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import webbrowser
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))
sys.path.insert(0, str(REPO / "pipeline"))

import bootstrap  # noqa: E402

STATE = REPO / "work" / "state.json"
STAGES = ["extract", "landscape", "sanity", "layers", "ground",
          "library", "scene", "render", "stitch", "web"]


# ---------------------------------------------------------------- tila

def load_state() -> dict:
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def mark(stage: str) -> None:
    st = load_state()
    st[stage] = {"done": True, "ts": time.strftime("%Y-%m-%d %H:%M:%S")}
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(st, indent=2))


# ---------------------------------------------------------------- ajo

class Runner:
    def __init__(self, args, settings: bootstrap.Settings):
        self.args = args
        self.s = settings
        self.py = sys.executable

    def run(self, *cmd: str, cwd: Path | None = None) -> None:
        printable = " ".join(str(c) for c in cmd)
        if self.args.check:
            print(f"    [check] {printable}")
            exe = Path(str(cmd[0]))
            if not (shutil.which(str(cmd[0])) or exe.exists()):
                raise SystemExit(f"    komentoa ei loydy: {cmd[0]}")
            if str(cmd[0]) == self.py and cmd[1:]:
                script = Path(str(cmd[1]))
                if not script.exists():
                    raise SystemExit(f"    skriptia ei loydy: {script}")
            return
        print(f"    $ {printable}")
        r = subprocess.run([str(c) for c in cmd], cwd=cwd)
        if r.returncode:
            raise SystemExit(f"Vaihe kaatui (paluukoodi {r.returncode}): {printable}")

    def script(self, rel: str, *a: str) -> None:
        self.run(self.py, str(REPO / rel), *a)

    # ------------------------------------------------------------ vaiheet

    def missing(self, what: str) -> bool:
        """check-tilassa puuttuva ulkoinen tyokalu on huomautus, ei pysautys:
        kuiva-ajon tarkoitus on tarkistaa putken rakenne, ei koneen varustelu."""
        if self.args.check:
            print(f"    [check] ohitetaan - {what} puuttuu")
            return True
        raise SystemExit(f"{what} puuttuu - aja bootstrap uudelleen.")

    def extract(self) -> None:
        exe = self.s.get("paths", "dumpworld")
        paks = self.s.get("paths", "paks")
        if not exe or not paks:
            if self.missing("DumpWorld tai SCUMin polku"):
                return
        cmd = [exe, "--paks", paks, "--out", str(REPO / "dump"),
               "--meshes", str(REPO / "assets" / "meshes"),
               "--landscape-textures", str(REPO / "assets" / "landscape")]
        aes = self.s.get("paths", "aes")
        if aes:
            cmd += ["--aes", aes]
        self.run(*cmd)

    def landscape(self) -> None:
        self.script("pipeline/01_landscape/heightmap.py",
                    "--output-px", self.s.get("render", "output_px", "32768"),
                    "--tile-grid", self.s.get("render", "tile_grid", "16"))
        self.script("pipeline/01_landscape/weightmaps.py")

    def sanity(self) -> None:
        """Automaattinen jarkevyystarkistus ennen kuin tunteja poltetaan renderointiin."""
        if self.args.check:
            print("    [check] sanity")
            return
        import numpy as np
        from common import WORK, World

        world = World.load()
        h = np.load(WORK / "heightmap.npy")
        z_m = world.landscape_height_uu(h.astype(np.float64)) / world.uu_per_meter

        aspect = world.size_uu[0] / max(world.size_uu[1], 1e-6)
        relief = float(z_m.max() - z_m.min())
        km = [s / world.uu_per_meter / 1000.0 for s in world.size_uu]
        print(f"    kartta {km[0]:.1f} x {km[1]:.1f} km, {world.meters_per_px:.3f} m/px")
        print(f"    korkeus {z_m.min():.0f} .. {z_m.max():.0f} m (vaihtelu {relief:.0f} m)")
        print(f"    merenpinnan alla {float((z_m < 0).mean()):.1%}")

        problems = []
        if not 0.3 < aspect < 3.0:
            problems.append(f"kartan muotosuhde {aspect:.2f} on absurdi")
        if relief < 10:
            problems.append(f"korkeusvaihtelu vain {relief:.1f} m - heightmap on tasainen")
        if h.std() < 1:
            problems.append("heightmap on lahes vakio - atlaksen kokoaminen epaonnistui")
        if problems:
            for p in problems:
                print(f"    VIRHE: {p}")
            raise SystemExit(
                "Maasto ei ole jarkeva. Ala jatka - virhe kertautuisi kaikkiin "
                "myohempiin vaiheisiin. Tarkista purku ja HeightmapScaleBias-tulkinta.")
        print("    maasto on jarkeva")

    def layers(self) -> None:
        self.script("pipeline/01_landscape/guess_layers.py",
                    "--texture-dir", str(REPO / "assets" / "landscape"))

    def ground(self) -> None:
        # Blenderin syote ilman varjostusta: valo tulee renderissa auringosta.
        self.script("pipeline/01_landscape/ground_albedo.py",
                    "--hillshade", "0", "--out", str(REPO / "work" / "ground_flat"))
        # Katsottava versio reliefivarjostuksella - tama on jo kaytettava kartta.
        self.script("pipeline/01_landscape/ground_albedo.py", "--hillshade", "0.35")

    def library(self) -> None:
        blender = self.s.get("paths", "blender")
        if not blender:
            if self.missing("Blenderin polku"):
                return
        self.run(blender, "-b", "-P", str(REPO / "pipeline/03_render/build_library.py"),
                 "--", "--meshes", str(REPO / "assets" / "meshes"))

    def scene(self) -> None:
        self.script("pipeline/02_scene/actor_db.py", "--min-px", "2")

    def render(self) -> None:
        blender = self.s.get("paths", "blender")
        if not blender and self.missing("Blenderin polku"):
            return
        self.script("pipeline/03_render/render_all.py",
                    "--blender", blender,
                    "--engine", self.s.get("render", "engine", "cycles"),
                    "--samples", self.s.get("render", "samples", "256"))

    def stitch(self) -> None:
        try:
            import pyvips  # noqa: F401
        except ImportError:
            print("    pyvips puuttuu - ohitetaan 32K-master, tiilet tehdaan silti")
            return
        self.script("pipeline/04_output/stitch.py")

    def web(self) -> None:
        self.script("pipeline/04_output/make_tiles.py")


# ---------------------------------------------------------------- arviot

def estimate(settings: bootstrap.Settings) -> None:
    grid = int(settings.get("render", "tile_grid", "16"))
    px = int(settings.get("render", "output_px", "32768"))
    tiles = grid * grid
    print(f"\n  {px}x{px} px, {tiles} tiilta a {px // grid} px")
    print(f"  arvioitu levytila: purku 20-60 GB, tiilet ~{tiles * 8 // 1000 + 1} GB, "
          "master ~3 GB")
    print("  arvioitu kesto: purku 30-90 min, renderointi 3-12 h "
          "(RTX 3070, 256 naytetta)\n")


def serve(settings: bootstrap.Settings) -> None:
    web = REPO / "out" / "web"
    if not (web / "map.json").exists():
        print("Karttaa ei ole viela - aja putki loppuun.")
        return
    port = 8765
    print(f"\nKartta: http://localhost:{port}/  (lopeta Ctrl+C)")
    webbrowser.open(f"http://localhost:{port}/")
    subprocess.run([sys.executable, "-m", "http.server", str(port), "-d", str(web)])


# ---------------------------------------------------------------- paaohjelma

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="start", choices=STAGES, default=None)
    ap.add_argument("--only", choices=STAGES, default=None)
    ap.add_argument("--redo", action="store_true", help="aja myos valmiit vaiheet")
    ap.add_argument("--check", action="store_true", help="kuiva-ajo")
    ap.add_argument("--yes", action="store_true", help="ala kysele mitaan")
    ap.add_argument("--skip-bootstrap", action="store_true")
    ap.add_argument("--serve", action="store_true", help="avaa valmis kartta selaimeen")
    args = ap.parse_args()

    if args.serve:
        serve(bootstrap.Settings())
        return 0

    print("=" * 64)
    print(" SCUM 32K kartta")
    print("=" * 64)

    if args.skip_bootstrap or args.check:
        settings = bootstrap.Settings()
    else:
        settings = bootstrap.ensure(interactive=not args.yes)

    # Vaiheet ajetaan venvin Pythonilla; jos siella ei olla, kaynnistetaan uudelleen.
    venv_py = bootstrap.venv_python()
    if venv_py.exists() and not bootstrap.in_venv() and not args.check:
        print(f"\nSiirrytaan virtuaaliymparistoon {venv_py}")
        os.execv(str(venv_py), [str(venv_py), str(Path(__file__).resolve()),
                                *sys.argv[1:], "--skip-bootstrap"])

    estimate(settings)

    stages = [args.only] if args.only else STAGES
    if args.start and not args.only:
        stages = STAGES[STAGES.index(args.start):]

    state = load_state()
    runner = Runner(args, settings)
    t0 = time.time()

    for stage in stages:
        if state.get(stage, {}).get("done") and not (args.redo or args.only):
            print(f"[{stage}] valmis jo {state[stage]['ts']} - ohitetaan")
            continue

        if stage == "render" and not args.yes and not args.check:
            print("[render] tama on ajon pisin vaihe (tunteja).")
            if not bootstrap.confirm("  jatketaanko?", True, default=True):
                print("  keskeytetty. Jatka myohemmin: --from render")
                return 0

        print(f"\n[{stage}]")
        ts = time.time()
        getattr(runner, stage)()
        if not args.check:
            mark(stage)
            print(f"[{stage}] valmis {time.time() - ts:.0f}s")

    if args.check:
        print("\nKuiva-ajo lapi: kaikki komennot ja skriptit loytyvat.")
        return 0

    print(f"\nKaikki valmista {(time.time() - t0) / 60:.0f} min")
    print(f"Kartta: {REPO / 'out' / 'web'}")
    if not args.yes and bootstrap.confirm("Avataanko kartta selaimeen?", True, default=True):
        serve(settings)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
