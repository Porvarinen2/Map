#!/usr/bin/env python3
"""Pilkkoo masterin zoomattavaksi tiilipyramidiksi ja kirjoittaa katselimen metadatan.

Tama on se vaihe jossa "tarkempi zoomattuna" oikeasti toteutuu: 32K PNG ei aukea
selaimessa lainkaan, tiilipyramidi aukeaa valittomasti millä tahansa zoomilla.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import OUT, World, ensure_dirs  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(OUT / "scum_map_32k.tif"))
    ap.add_argument("--out", default=str(OUT / "web"))
    ap.add_argument("--tile-size", type=int, default=256)
    ap.add_argument("--quality", type=int, default=88)
    ap.add_argument("--format", default="jpg", choices=["jpg", "png", "webp"])
    args = ap.parse_args()

    try:
        import pyvips
    except ImportError:
        raise SystemExit("pyvips puuttuu - katso stitch.py:n ohje.")

    world = World.load()
    out = Path(args.out)
    ensure_dirs(out)

    img = pyvips.Image.new_from_file(args.src, access="sequential")
    suffix = {"jpg": f".jpg[Q={args.quality}]",
              "webp": f".webp[Q={args.quality}]",
              "png": ".png"}[args.format]

    # google-layout = tavallinen {z}/{x}/{y} jota Leaflet lukee sellaisenaan.
    img.dzsave(str(out / "tiles"), layout="google", suffix=suffix,
               tile_size=args.tile_size, overlap=0, depth="onetile")

    max_zoom = 0
    while (args.tile_size << max_zoom) < max(img.width, img.height):
        max_zoom += 1

    meta = {
        "width": img.width,
        "height": img.height,
        "tileSize": args.tile_size,
        "maxZoom": max_zoom,
        "format": args.format,
        # Maailmamuunnos mukaan, jotta POI-overlayt voi piirtaa ilman Pythonia.
        "world": {
            "origin_uu": list(world.origin_uu),
            "size_uu": list(world.size_uu),
            "uu_per_px": world.uu_per_px,
            "uu_per_meter": world.uu_per_meter,
            "meters_per_px": world.meters_per_px,
        },
    }
    (out / "map.json").write_text(json.dumps(meta, indent=2))

    viewer = Path(__file__).resolve().parents[2] / "viewer" / "index.html"
    if viewer.exists():
        (out / "index.html").write_text(viewer.read_text())

    print(f"Tiilet -> {out / 'tiles'} (maxZoom {max_zoom})")
    print(f"Avaa: python3 -m http.server -d {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
