#!/usr/bin/env python3
"""Tarkistaa etta maailmakoordinaatit osuvat kuvan pikseleihin - AJA ENNEN RENDEROINTIA.

Jos UE:n Y-akseli osoittaa kartalla vaaraan suuntaan tai origo on pielessa, virhe ei
nay mistaan ennen kuin koko 256 tiilen renderointi on ajettu hukkaan. Siksi tama
tarkistus tehdaan muutaman tunnetun kohteen avulla heti kun heightmap on koossa.

    python3 pipeline/02_scene/verify_landmarks.py --draw work/heightmap_u16.png
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import CONFIG, OUT, World, ensure_dirs  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--landmarks", default=str(CONFIG / "landmarks.json"))
    ap.add_argument("--draw", default=None, help="piirra merkit talle kuvalle")
    ap.add_argument("--out", default=str(OUT / "landmark_check.png"))
    args = ap.parse_args()

    world = World.load()
    path = Path(args.landmarks)
    if not path.exists():
        raise SystemExit(
            f"{path} puuttuu. Kirjoita sinne tunnetut kohteet muodossa\n"
            '  [{"name": "Lentokentta", "uu": [123456, -98765]}]\n'
            "Koordinaatit saa pelissa komennolla #location.")

    marks = json.loads(path.read_text())
    print(f"{world.output_px}px kartta, {world.meters_per_px:.3f} m/px\n")
    print(f"{'kohde':<24}{'UU':>22}{'px':>16}{'tiili':>10}")

    rows = []
    for m in marks:
        x_uu, y_uu = m["uu"][0], m["uu"][1]
        px, py = world.uu_to_px(x_uu, y_uu)
        tx, ty = world.tile_of_uu(x_uu, y_uu)
        inside = 0 <= px < world.output_px and 0 <= py < world.output_px
        flagtxt = "" if inside else "  <-- KARTAN ULKOPUOLELLA"
        print(f"{m['name']:<24}{x_uu:>11.0f},{y_uu:>10.0f}"
              f"{px:>8.0f},{py:>7.0f}{tx:>5},{ty:<4}{flagtxt}")
        rows.append((m["name"], px, py, inside))

    if not all(r[3] for r in rows):
        print("\nVIRHE: osa kohteista on kartan ulkopuolella -> origo tai akselien "
              "suunta on vaarin. Korjaa ennen kuin renderoit mitaan.")
        return 1

    if args.draw:
        draw(Path(args.draw), rows, world, Path(args.out))
    print("\nKaikki kohteet kartalla. Tarkista viela silmamaaraisesti etta ne osuvat "
          "oikeisiin maastonkohtiin.")
    return 0


def draw(src: Path, rows, world: World, dst: Path) -> None:
    from PIL import Image, ImageDraw

    img = Image.open(src).convert("RGB")
    sx, sy = img.width / world.output_px, img.height / world.output_px
    d = ImageDraw.Draw(img)
    r = max(4, img.width // 200)
    for name, px, py, _ in rows:
        cx, cy = px * sx, py * sy
        d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=(80, 255, 80), width=3)
        d.text((cx + r + 4, cy - r), name, fill=(80, 255, 80))
    ensure_dirs(dst.parent)
    img.save(dst)
    print(f"\nMerkitty kuva -> {dst}")


if __name__ == "__main__":
    raise SystemExit(main())
