#!/usr/bin/env python3
"""Bakettaa maanpinnan varin 32K-tarkkuuteen suoraan weightmapeista - ilman renderointia.

Tama on kartan laadun tarkein yksittainen vaihe ja se valmistuu minuuteissa, kun
Blender-renderointi vie tunteja. Pelkka tama tuottaa jo scum-mapia tarkemman kartan.

Resoluutiohuomio joka ratkaisee lopputuloksen terävyyden:
  0.37 m/px:lla maa-ainestekstuuri joka toistuu 4 metrin valein on ~11 px levea.
  Jos sellaisesta poimitaan taysresoluutioiset texelit, tulos on pelkkaa aliasoitunutta
  kohinaa. Oikea vastaus on skaalata tekstuuri etukateen siihen kokoon jossa yksi texel
  vastaa yhta ulostulopikselia (laatikkosuodatus). Hienot tekstuurit painuvat silloin
  itsestaan lahelle keskivariaan - juuri niin kuin kuuluukin - ja vasta karkeat
  makrovaihtelut (50-200 m) jaavat nakyviin. Niista kartan ilme oikeasti syntyy.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import CONFIG, WORK, World, ensure_dirs  # noqa: E402


# --------------------------------------------------------------------- naytteistys

def bilinear(src: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """Bilineaarinen naytteistys 2D-taulukosta reunat kiinnittaen."""
    h, w = src.shape
    x = np.clip(x, 0.0, w - 1.001)
    y = np.clip(y, 0.0, h - 1.001)
    x0, y0 = np.floor(x).astype(np.int32), np.floor(y).astype(np.int32)
    x1, y1 = x0 + 1, y0 + 1
    fx, fy = (x - x0).astype(np.float32), (y - y0).astype(np.float32)
    a = src[y0, x0].astype(np.float32)
    b = src[y0, x1].astype(np.float32)
    c = src[y1, x0].astype(np.float32)
    d = src[y1, x1].astype(np.float32)
    top = a + (b - a) * fx
    bot = c + (d - c) * fx
    return top + (bot - top) * fy


def load_layer_texture(spec: dict, meters_per_px: float) -> np.ndarray:
    """Layerin tekstuuri skaalattuna niin etta 1 texel ~ 1 ulostulopikseli."""
    from PIL import Image

    tiling_m = float(spec.get("tiling_m", 4.0))
    target = max(4, int(round(tiling_m / meters_per_px)))

    path = spec.get("texture")
    if not path or not Path(path).exists():
        color = np.array(spec.get("color") or fallback_color(spec.get("_name", "")),
                         dtype=np.float32)
        return np.tile(color, (target, target, 1))

    img = Image.open(path).convert("RGB")
    if max(img.size) > 2048:                       # kevennys ennen laatikkosuodatusta
        img.thumbnail((2048, 2048), Image.LANCZOS)
    img = img.resize((target, target), Image.BOX)  # BOX = oikea keskiarvoistus
    tex = np.asarray(img, dtype=np.float32) / 255.0
    return tex * np.array(spec.get("tint", [1.0, 1.0, 1.0]), dtype=np.float32)


def fallback_color(name: str) -> list[float]:
    """Vakaa, erottuva vari layerille jolle ei ole viela maaritelty tekstuuria.

    Ensimmainen bake on nain heti luettava ja layerit tunnistettavissa toisistaan,
    vaikka config/layers.json olisi tayttamatta. Lopullisiin vareihin tama ei riita.
    """
    # crc32 eika hash(): Pythonin str-hash on prosessikohtaisesti satunnaistettu,
    # jolloin eri ajoissa renderoidut tiilet saisivat eri varit ja saumat nakyisivat.
    import colorsys
    import zlib
    hue = (zlib.crc32(name.encode()) % 360) / 360.0
    return list(colorsys.hsv_to_rgb(hue, 0.35, 0.55))


# --------------------------------------------------------------------- valaistus

def hillshade(height_uu: np.ndarray, px_size_uu: float, strength: float,
              azimuth_deg: float = 315.0, altitude_deg: float = 55.0) -> np.ndarray:
    """Kevyt reliefivarjostus korkeuskartasta. Tekee maastonmuodot luettaviksi
    ilman etta yhtakaan polygonia tarvitsee renderoida."""
    gy, gx = np.gradient(height_uu.astype(np.float32), px_size_uu)
    slope = np.arctan(np.hypot(gx, gy))
    aspect = np.arctan2(-gx, gy)
    az, alt = np.radians(azimuth_deg), np.radians(altitude_deg)
    shade = (np.sin(alt) * np.cos(slope)
             + np.cos(alt) * np.sin(slope) * np.cos(az - aspect))
    return 1.0 + (np.clip(shade, 0.0, 1.0) - 0.5) * 2.0 * strength


# --------------------------------------------------------------------- paaohjelma

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tiles", default="all", help="'all' tai 'x,y x,y ...'")
    ap.add_argument("--hillshade", type=float, default=0.35, help="0 = pois")
    ap.add_argument("--sea-level-m", type=float, default=0.0)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    world = World.load()
    heights = np.load(WORK / "heightmap.npy")
    wm_dir = WORK / "weightmaps"
    manifest = json.loads((wm_dir / "layers.json").read_text())

    cfg_path = CONFIG / "layers.json"
    layer_cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
    if not layer_cfg:
        print(f"VAROITUS: {cfg_path} puuttuu - kaytetaan oletusvareja jokaiselle layerille.")

    layers = []
    for name in manifest:
        spec = layer_cfg.get(name, {})
        if spec.get("skip"):
            continue
        layers.append((name, np.load(wm_dir / f"{name}.npy"),
                       load_layer_texture({**spec, "_name": name}, world.meters_per_px)))
    if not layers:
        raise SystemExit("Ei yhtaan layeria - aja weightmaps.py ensin.")
    print(f"{len(layers)} layeria, {world.tile_grid}x{world.tile_grid} tiilta @ {world.tile_px}px")

    out_dir = Path(args.out) if args.out else WORK / "ground"
    ensure_dirs(out_dir)

    scale_xy = world.landscape.get("scale", [100.0] * 3)[:2]
    grid_origin = world.landscape.get("grid_origin_quads", [0, 0])
    sea_uu = args.sea_level_m * world.uu_per_meter

    todo = list(world.tiles()) if args.tiles == "all" else [
        tuple(int(v) for v in t.split(",")) for t in args.tiles.split()
    ]

    for tx, ty in todo:
        dst = out_dir / f"ground_{tx:02d}_{ty:02d}.png"
        render_tile(world, tx, ty, layers, heights, scale_xy, grid_origin,
                    args.hillshade, sea_uu, dst)
        print(f"  {dst.name}")

    print(f"Valmis: {out_dir}")
    return 0


def render_tile(world: World, tx: int, ty: int, layers, heights, scale_xy,
                grid_origin, hillshade_strength: float, sea_uu: float, dst: Path) -> None:
    n = world.tile_px
    x0_uu, y0_uu, _, _ = world.tile_bounds_uu(tx, ty)

    # Pikselien keskipisteet maailmakoordinaatteina.
    px = (np.arange(n, dtype=np.float32) + 0.5) * world.uu_per_px
    ux = x0_uu + px[None, :]
    uy = y0_uu + px[:, None]
    ux, uy = np.broadcast_arrays(ux, uy)

    # UU -> landscapen vertex-ruudukko (weightmapien ja heightmapin koordinaatisto).
    loc = world.landscape.get("location", [0.0, 0.0, 0.0])
    vx = (ux - loc[0]) / scale_xy[0] - grid_origin[0]
    vy = (uy - loc[1]) / scale_xy[1] - grid_origin[1]

    # UU -> metrit tekstuurien tiilitysta varten.
    mx = ux / world.uu_per_meter
    my = uy / world.uu_per_meter

    rgb = np.zeros((n, n, 3), dtype=np.float32)
    total = np.zeros((n, n), dtype=np.float32)

    for _name, mask, tex in layers:
        w = bilinear(mask, vx, vy) / 255.0
        if w.max() < 1e-3:
            continue
        th, tw = tex.shape[:2]
        # Tekstuuri toistuu tiling_m valein; texelin koko = ulostulopikseli.
        sx = np.mod((mx / world.meters_per_px).astype(np.int64), tw)
        sy = np.mod((my / world.meters_per_px).astype(np.int64), th)
        rgb += tex[sy, sx] * w[..., None]
        total += w

    rgb /= np.maximum(total, 1e-4)[..., None]

    h_uu = world.landscape_height_uu(bilinear(heights, vx, vy))

    if hillshade_strength > 0:
        rgb *= hillshade(h_uu, world.uu_per_px, hillshade_strength)[..., None]

    if sea_uu is not None:
        depth = np.clip((sea_uu - h_uu) / (25.0 * world.uu_per_meter), 0.0, 1.0)
        under = depth > 0
        if under.any():
            shallow = np.array([0.22, 0.42, 0.45], dtype=np.float32)
            deep = np.array([0.03, 0.08, 0.18], dtype=np.float32)
            water = shallow + (deep - shallow) * depth[..., None]
            a = np.clip(depth * 6.0, 0.0, 1.0)[..., None]
            rgb = rgb * (1 - a) + water * a

    from PIL import Image
    Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8)).save(dst)


if __name__ == "__main__":
    raise SystemExit(main())
