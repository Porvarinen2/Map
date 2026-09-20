#!/usr/bin/env python3
"""Ajaa kaikki tiilet lapi erillisina Blender-prosesseina.

Erillinen prosessi per tiili ei ole tehottomuutta vaan tarkoituksellista: se palauttaa
VRAMin kayttojarjestelmalle joka tiilen jalkeen. Samassa prosessissa ajettuna Blenderin
muistinkulutus kasvaa tiili tiilelta kunnes metsaisin osuus saaresta kaataa ajon.

    python3 pipeline/03_render/render_all.py --engine cycles --samples 256
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import OUT, World  # noqa: E402

SCRIPT = Path(__file__).with_name("render_tile.py")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--blender", default=shutil.which("blender") or "blender")
    ap.add_argument("--engine", default="cycles")
    ap.add_argument("--samples", type=int, default=256)
    ap.add_argument("--out", default=str(OUT / "tiles"))
    ap.add_argument("--redo", action="store_true", help="renderoi myos valmiit tiilet")
    ap.add_argument("--only", default=None, help="'x,y x,y' - vain nama tiilet")
    ap.add_argument("--retry-samples", type=int, default=96,
                    help="uusintayritys pienemmalla naytemaaralla jos tiili kaatuu")
    args, extra = ap.parse_known_args()

    world = World.load()
    out_dir = Path(args.out)
    todo = (list(world.tiles()) if not args.only else
            [tuple(int(v) for v in t.split(",")) for t in args.only.split()])

    pending = [(tx, ty) for tx, ty in todo
               if args.redo or not (out_dir / f"tile_{tx:02d}_{ty:02d}.png").exists()]
    print(f"{len(pending)}/{len(todo)} tiilta renderoitavana")

    failed, t_start = [], time.time()
    for i, (tx, ty) in enumerate(pending, 1):
        for samples in (args.samples, args.retry_samples):
            cmd = [args.blender, "-b", "-P", str(SCRIPT), "--",
                   "--tile", str(tx), str(ty),
                   "--engine", args.engine, "--samples", str(samples),
                   "--out", str(out_dir), *extra]
            t0 = time.time()
            rc = subprocess.run(cmd, capture_output=True, text=True)
            if rc.returncode == 0:
                dt = time.time() - t0
                eta = (time.time() - t_start) / i * (len(pending) - i)
                print(f"[{i}/{len(pending)}] {tx},{ty} {dt:6.1f}s  "
                      f"arvio jaljella {eta / 60:.0f} min")
                break
            if samples == args.retry_samples:
                print(f"[{i}/{len(pending)}] {tx},{ty} EPAONNISTUI")
                print("\n".join(rc.stderr.strip().splitlines()[-12:]))
                failed.append((tx, ty))
            else:
                print(f"  {tx},{ty} kaatui, uusi yritys {samples} -> {args.retry_samples} naytetta")

    print(f"\nValmis {time.time() - t_start:.0f}s, {len(failed)} epaonnistui")
    if failed:
        print("Uusi yritys: --only \"" + " ".join(f"{x},{y}" for x, y in failed) + '"')
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
