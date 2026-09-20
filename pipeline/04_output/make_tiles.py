#!/usr/bin/env python3
"""Pilkkoo kartan zoomattavaksi tiilipyramidiksi ja kirjoittaa katselimen metadatan.

Tama on se vaihe jossa "tarkempi zoomattuna" oikeasti toteutuu: 32K-kuva ei aukea
selaimessa lainkaan, tiilipyramidi aukeaa valittomasti milla tahansa zoomilla.

Kaksi reittia samaan lopputulokseen:
  pyvips  - nopea, kayttaa valmista 32K-masteria
  PIL     - hitaampi mutta ei vaadi libvipsia, ja rakentaa pyramidin suoraan
            renderoiduista tiilista ilman valissa olevaa 3 GB:n masteria

PIL-reitti on tassa nimenomaan siksi, etta yhden klikkauksen ajo ei saa kaatua
puuttuvaan natiivikirjastoon aivan viimeisessa vaiheessa - tuntien renderointi on
silloin jo takana.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import OUT, World, ensure_dirs  # noqa: E402


def max_zoom_for(size_px: int, tile_size: int) -> int:
    return max(0, math.ceil(math.log2(max(1, size_px / tile_size))))


# ---------------------------------------------------------------- pyvips-reitti

def build_with_pyvips(src: Path, out: Path, tile_size: int, fmt: str, quality: int):
    import pyvips

    img = pyvips.Image.new_from_file(str(src), access="sequential")
    suffix = {"jpg": f".jpg[Q={quality}]", "webp": f".webp[Q={quality}]",
              "png": ".png"}[fmt]
    # google-layout = tavallinen {z}/{x}/{y} jota Leaflet lukee sellaisenaan.
    img.dzsave(str(out / "tiles"), layout="google", suffix=suffix,
               tile_size=tile_size, overlap=0, depth="onetile")
    return img.width, img.height


# ---------------------------------------------------------------- PIL-reitti

def build_with_pil(world: World, tile_dir: Path, out: Path, tile_size: int,
                   fmt: str, quality: int, pattern: str):
    from PIL import Image

    root = out / "tiles"
    size_px = world.output_px
    maxz = max_zoom_for(size_px, tile_size)
    save_kw = {"quality": quality} if fmt in ("jpg", "webp") else {}
    ext = "jpg" if fmt == "jpg" else fmt

    def dst(z: int, x: int, y: int) -> Path:
        p = root / str(z) / str(x) / f"{y}.{ext}"
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    # --- ylin taso: paloittele jokainen renderoitu tiili suoraan ---
    per_tile = world.tile_px // tile_size
    if world.tile_px % tile_size:
        raise SystemExit(f"tile_px {world.tile_px} ei jaudu tile-size {tile_size}:lla")

    for tx, ty in world.tiles():
        src = tile_dir / pattern.format(tx=tx, ty=ty)
        if not src.exists():
            raise SystemExit(f"{src} puuttuu")
        with Image.open(src) as im:
            im = im.convert("RGB")
            for sy in range(per_tile):
                for sx in range(per_tile):
                    box = (sx * tile_size, sy * tile_size,
                           (sx + 1) * tile_size, (sy + 1) * tile_size)
                    im.crop(box).save(
                        dst(maxz, tx * per_tile + sx, ty * per_tile + sy), **save_kw)
        print(f"  z{maxz} {tx},{ty}")

    # --- alemmat tasot: nelja tiilta yhdeksi, puolitettuna ---
    count = world.tile_grid * per_tile
    for z in range(maxz - 1, -1, -1):
        count = math.ceil(count / 2)
        for y in range(count):
            for x in range(count):
                merged = Image.new("RGB", (tile_size * 2, tile_size * 2), (0, 0, 0))
                found = False
                for dy in (0, 1):
                    for dx in (0, 1):
                        p = root / str(z + 1) / str(x * 2 + dx) / f"{y * 2 + dy}.{ext}"
                        if not p.exists():
                            continue
                        with Image.open(p) as sub:
                            merged.paste(sub, (dx * tile_size, dy * tile_size))
                        found = True
                if found:
                    merged.resize((tile_size, tile_size), Image.LANCZOS).save(
                        dst(z, x, y), **save_kw)
        print(f"  z{z} ({count}x{count})")

    return size_px, size_px


# ---------------------------------------------------------------- paaohjelma

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(OUT / "scum_map_32k.tif"),
                    help="32K master (pyvips-reitti)")
    ap.add_argument("--tiles-dir", default=str(OUT / "tiles"),
                    help="renderoidut tiilet (PIL-reitti)")
    ap.add_argument("--pattern", default="tile_{tx:02d}_{ty:02d}.png")
    ap.add_argument("--out", default=str(OUT / "web"))
    ap.add_argument("--tile-size", type=int, default=256)
    ap.add_argument("--quality", type=int, default=88)
    ap.add_argument("--format", default="jpg", choices=["jpg", "png", "webp"])
    ap.add_argument("--backend", default="auto", choices=["auto", "pyvips", "pil"])
    args = ap.parse_args()

    world = World.load()
    out = Path(args.out)
    ensure_dirs(out)

    backend = args.backend
    if backend == "auto":
        try:
            import pyvips  # noqa: F401
            backend = "pyvips" if Path(args.src).exists() else "pil"
        except ImportError:
            backend = "pil"

    print(f"Tiilitys: {backend}")
    if backend == "pyvips":
        w, h = build_with_pyvips(Path(args.src), out, args.tile_size,
                                 args.format, args.quality)
    else:
        w, h = build_with_pil(world, Path(args.tiles_dir), out, args.tile_size,
                              args.format, args.quality, args.pattern)

    meta = {
        "width": w, "height": h,
        "tileSize": args.tile_size,
        "maxZoom": max_zoom_for(max(w, h), args.tile_size),
        "format": "jpg" if args.format == "jpg" else args.format,
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

    print(f"Tiilet -> {out / 'tiles'} (maxZoom {meta['maxZoom']})")
    print(f"Avaa: python3 -m http.server -d {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
