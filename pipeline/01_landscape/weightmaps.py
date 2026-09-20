#!/usr/bin/env python3
"""Kokoaa landscape-materiaalin layer-painokartat yhdeksi maskiksi per layer.

Painot kertovat mika maa-aines (ruoho, hiekka, kallio, tie, ...) nakyy missakin.
Nama ovat ground_albedo.py:n raaka-aine, eli ne maaraavat koko kartan varin.

Kanavakartoitus: UE tallettaa painot FColor-tekstuurin kanaviin ja
WeightmapTextureChannel on 0=R, 1=G, 2=B, 3=A. Purku on jo normalisoinut
tekstuurit RGBA8:ksi, joten kanavaindeksi kay sellaisenaan.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import DUMP, WORK, ensure_dirs  # noqa: E402
import heightmap as _hm  # noqa: E402  (jaetaan atlas-kokoamislogiikka)


# Kaikki landscapen layerit eivat ole maa-ainesta. Nama ohjaavat pelilogiikkaa
# (kasvillisuuden poisto, datakerrokset) eivatka nay maastossa mitenkaan - mukaan
# otettuna ne sekoittuisivat albedoon omalla keksityilla varillaan.
NON_VISUAL = ("erasefoliage", "datalayer", "nofoliage", "blockvolume",
              "spawn", "navmesh", "collision")


def is_visual(layer: str) -> bool:
    low = layer.lower()
    return not any(word in low for word in NON_VISUAL)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-coverage", type=float, default=0.0005,
                    help="hylkaa layerit jotka peittavat tata pienemman osan kartasta")
    ap.add_argument("--keep-non-visual", action="store_true",
                    help="ota mukaan myos pelilogiikan layerit")
    args = ap.parse_args()

    comps = json.loads((DUMP / "landscape" / "components.json").read_text())
    min_x, min_y, max_x, max_y = _hm.component_grid(comps)
    w, h = max_x - min_x + 1, max_y - min_y + 1

    # layer -> lista (komponentti, tekstuurinimi, kanava)
    by_layer: dict[str, list[dict]] = defaultdict(list)
    for c in comps:
        textures = c.get("WeightmapTextures") or []
        for alloc in c.get("Layers") or []:
            ti = alloc["TextureIndex"]
            if ti >= len(textures) or not textures[ti]:
                continue
            by_layer[alloc["Name"]].append(
                dict(c, _tex=textures[ti], _scale_bias=c["WeightmapScaleBias"],
                     _channel=alloc["Channel"])
            )

    out_dir = WORK / "weightmaps"
    ensure_dirs(out_dir)
    manifest = {}

    for layer, entries in sorted(by_layer.items()):
        if not args.keep_non_visual and not is_visual(layer):
            print(f"  ohitetaan {layer}: ei maa-ainesta")
            continue

        mask = np.zeros((h, w), dtype=np.uint8)
        placed = _hm.blit_components(
            entries, mask, min_x, min_y,
            lambda tex, c: tex[:, :, c["_channel"]],
        )
        coverage = float((mask > 8).mean())
        if coverage < args.min_coverage:
            print(f"  ohitetaan {layer}: peitto {coverage:.5%}")
            continue

        np.save(out_dir / f"{layer}.npy", mask)
        manifest[layer] = {"coverage": coverage, "components": len(entries), "blocks": placed}
        print(f"  {layer:<28} peitto {coverage:7.3%}  ({len(entries)} komponenttia)")

    (out_dir / "layers.json").write_text(json.dumps(manifest, indent=2))
    print(f"\n{len(manifest)} layeria kirjoitettu kansioon {out_dir}")
    print("Seuraavaksi: taydenna config/layers.json (tekstuuri + tiilitys per layer).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
