#!/usr/bin/env python3
"""Kokoaa landscape-komponenttien heightmapit yhdeksi koko saaren korkeuskartaksi
ja kirjoittaa config/world.json:n.

Tama on putken ensimmainen totuuden hetki: jos maailman rajat menevat tassa vaarin,
kaikki myohempi (albedo, objektit, renderointi) menee vaarin huomaamatta.

UE4:n landscape tallettaa korkeuden 16-bittisena BGRA8-tekstuurin kahteen kanavaan:
    h16 = R * 256 + G          (B ja A ovat normaalin XY, ei tarvita)
    Z_uu = (h16 - 32768) / 128 * ActorScaleZ + ActorLocZ

Komponentit voivat jakaa saman tekstuurin (atlas), ja yksi komponentti voi sisaltaa
NumSubsections^2 alilohkoa joilla on MONISTETUT reunavertexit. Alilohkot on siksi
kopioitava yksitellen SubsectionSizeQuads-askeleella, ei yhtena blokkina.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import DUMP, WORK, World, ensure_dirs, load_raw_rgba  # noqa: E402

_tex_cache: dict[str, tuple[np.ndarray, dict]] = {}


def texture(name: str) -> tuple[np.ndarray, dict]:
    """Lataa dumpattu RGBA8-tekstuuri valimuistista."""
    if name not in _tex_cache:
        if len(_tex_cache) > 24:           # atlaksia on satoja, pidetaan muisti kurissa
            _tex_cache.pop(next(iter(_tex_cache)))
        _tex_cache[name] = load_raw_rgba(DUMP / "textures" / name)
    return _tex_cache[name]


def atlas_offset(scale_bias, tex_w: int, tex_h: int) -> tuple[int, int]:
    """HeightmapScaleBias/WeightmapScaleBias -> pikselioffset atlaksessa.

    UE on tallettanut Z/W:n eri versioissa joko normalisoituna (offset/koko) tai
    suoraan pikseleina, joten tunnistetaan kumpi on kyseessa suuruusluokasta.
    """
    _, _, z, w = (list(scale_bias) + [0, 0, 0, 0])[:4]
    ox = int(round(z * tex_w)) if abs(z) <= 1.0 else int(round(z))
    oy = int(round(w * tex_h)) if abs(w) <= 1.0 else int(round(w))
    return ox, oy


def component_grid(comps: list[dict]) -> tuple[int, int, int, int]:
    """Landscapen vertex-ruudukon rajat quadeina."""
    min_x = min(c["SectionBaseX"] for c in comps)
    min_y = min(c["SectionBaseY"] for c in comps)
    max_x = max(c["SectionBaseX"] + c["ComponentSizeQuads"] for c in comps)
    max_y = max(c["SectionBaseY"] + c["ComponentSizeQuads"] for c in comps)
    return min_x, min_y, max_x, max_y


def blit_components(comps, dst, min_x, min_y, sample):
    """Kopioi jokaisen komponentin jokaisen alilohkon kohdalleen.

    `sample(tex) -> 2D-taulukko` poimii halutun arvon tekstuurista (korkeus tai paino),
    jolloin sama kokoamislogiikka palvelee seka heightmappeja etta weightmappeja.
    """
    placed = 0
    for c in comps:
        texname = c.get("_tex")
        if not texname:
            continue
        try:
            tex, meta = texture(texname)
        except FileNotFoundError:
            continue

        values = sample(tex, c)
        if values is None:
            continue

        ox, oy = atlas_offset(c["_scale_bias"], meta["width"], meta["height"])
        nsub = max(1, c["NumSubsections"])
        ssq = c["SubsectionSizeQuads"]
        ss = ssq + 1

        for sy in range(nsub):
            for sx in range(nsub):
                src_y, src_x = oy + sy * ss, ox + sx * ss
                block = values[src_y:src_y + ss, src_x:src_x + ss]
                if block.shape != (ss, ss):
                    continue
                dy = c["SectionBaseY"] - min_y + sy * ssq
                dx = c["SectionBaseX"] - min_x + sx * ssq
                dst[dy:dy + ss, dx:dx + ss] = block
                placed += 1
    return placed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output-px", type=int, default=32768)
    ap.add_argument("--tile-grid", type=int, default=16)
    ap.add_argument("--uu-per-meter", type=float, default=100.0)
    args = ap.parse_args()

    comps_path = DUMP / "landscape" / "components.json"
    if not comps_path.exists():
        raise SystemExit(f"{comps_path} puuttuu - aja vaihe A (DumpWorld) ensin.")

    comps = json.loads(comps_path.read_text())
    comps = [c for c in comps if c.get("Heightmap")]
    if not comps:
        raise SystemExit("Yhdessakaan landscape-komponentissa ei ole heightmapia.")

    min_x, min_y, max_x, max_y = component_grid(comps)
    w, h = max_x - min_x + 1, max_y - min_y + 1
    print(f"Landscape-ruudukko {w} x {h} vertexia ({len(comps)} komponenttia)")

    height = np.zeros((h, w), dtype=np.uint16)
    for c in comps:
        c["_tex"] = c["Heightmap"]
        c["_scale_bias"] = c["HeightmapScaleBias"]

    placed = blit_components(
        comps, height, min_x, min_y,
        # R = ylempi tavu, G = alempi tavu.
        lambda tex, c: tex[:, :, 0].astype(np.uint16) * 256 + tex[:, :, 1].astype(np.uint16),
    )
    print(f"{placed} alilohkoa sijoitettu")
    if placed == 0:
        raise SystemExit("Mitaan ei sijoitettu - tarkista ScaleBias-tulkinta ja tekstuuridumpit.")

    ensure_dirs(WORK)
    np.save(WORK / "heightmap.npy", height)
    _save_png16(height, WORK / "heightmap_u16.png")

    # --- maailman rajat UU:na ---
    loc, scale = landscape_transform()
    origin = (loc[0] + min_x * scale[0], loc[1] + min_y * scale[1])
    size = ((w - 1) * scale[0], (h - 1) * scale[1])

    world = World(
        origin_uu=origin,
        size_uu=size,
        output_px=args.output_px,
        tile_grid=args.tile_grid,
        uu_per_meter=args.uu_per_meter,
        landscape={
            "location": list(loc),
            "scale": list(scale),
            "grid_origin_quads": [min_x, min_y],
            "grid_size_verts": [w, h],
            "heightmap": str((WORK / "heightmap.npy").relative_to(WORK.parent)),
        },
    )
    path = world.save()

    z = world.landscape_height_uu(height.astype(np.float64))
    print(f"Kartta {size[0] / args.uu_per_meter:.0f} x {size[1] / args.uu_per_meter:.0f} m, "
          f"{world.meters_per_px:.3f} m/px, tiili {world.tile_size_uu / args.uu_per_meter:.0f} m")
    print(f"Korkeus {z.min() / args.uu_per_meter:.1f} .. {z.max() / args.uu_per_meter:.1f} m")
    print(f"Kirjoitettu {path}")
    return 0


def landscape_transform() -> tuple[list[float], list[float]]:
    """Landscape-actorin sijainti ja skaala. Proxyt jakavat saman transformin."""
    path = DUMP / "landscape" / "actors.json"
    actors = json.loads(path.read_text()) if path.exists() else []
    if not actors:
        print("VAROITUS: landscape/actors.json puuttuu, oletetaan origo + skaala 100.")
        return [0.0, 0.0, 0.0], [100.0, 100.0, 100.0]
    main_actor = next((a for a in actors if a["Name"] == "Landscape"), actors[0])
    return main_actor["Loc"], main_actor["Scale"]


def _save_png16(arr: np.ndarray, path: Path) -> None:
    """16-bittinen harmaasavy-PNG Blenderin displacementia varten."""
    from PIL import Image
    buf = arr.astype("<u2").tobytes()
    Image.frombuffer("I;16", (arr.shape[1], arr.shape[0]), buf, "raw", "I;16", 0, 1).save(path)


if __name__ == "__main__":
    raise SystemExit(main())
