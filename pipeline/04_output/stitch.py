#!/usr/bin/env python3
"""Liittaa renderoidut tiilet yhdeksi 32K-masteriksi.

pyvips kasittelee kuvan virtana, joten 32768x32768 ei kay kertaakaan kokonaan
muistissa - taysi RGB-puskuri olisi 3 GB ja RGBA 4.3 GB.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import OUT, World, ensure_dirs  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tiles", default=str(OUT / "tiles"))
    ap.add_argument("--out", default=str(OUT / "scum_map_32k.tif"))
    ap.add_argument("--pattern", default="tile_{tx:02d}_{ty:02d}.png")
    ap.add_argument("--preview", type=int, default=4096,
                    help="kirjoita myos talle sivulle skaalattu esikatselu (0 = ei)")
    args = ap.parse_args()

    try:
        import pyvips
    except ImportError:
        raise SystemExit(
            "pyvips puuttuu. Asenna libvips + 'pip install pyvips'.\n"
            "  Debian/Ubuntu: apt install libvips-dev\n"
            "  Windows: lataa vips-dev-w64 ja lisaa bin/ PATHiin"
        )

    world = World.load()
    tile_dir = Path(args.tiles)

    missing = [(tx, ty) for tx, ty in world.tiles()
               if not (tile_dir / args.pattern.format(tx=tx, ty=ty)).exists()]
    if missing:
        raise SystemExit(f"{len(missing)} tiilta puuttuu, esim {missing[:5]}")

    # Rivijarjestys: ty kasvaa alaspain, sama kuin kuvan y.
    images = [pyvips.Image.new_from_file(
        str(tile_dir / args.pattern.format(tx=tx, ty=ty)), access="sequential")
        for ty in range(world.tile_grid) for tx in range(world.tile_grid)]

    joined = pyvips.Image.arrayjoin(images, across=world.tile_grid)
    print(f"Mosaiikki {joined.width}x{joined.height}, {joined.bands} kanavaa")

    out = Path(args.out)
    ensure_dirs(out.parent)
    joined.tiffsave(str(out), tile=True, tile_width=512, tile_height=512,
                    pyramid=True, compression="deflate", bigtiff=True)
    print(f"Master -> {out}")

    if args.preview:
        prev = out.with_name(out.stem + f"_preview_{args.preview}.png")
        pyvips.Image.new_from_file(str(out), access="sequential") \
            .thumbnail_image(args.preview).write_to_file(str(prev))
        print(f"Esikatselu -> {prev}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
