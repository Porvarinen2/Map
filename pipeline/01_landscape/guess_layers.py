#!/usr/bin/env python3
"""Kirjoittaa config/layers.json yhdistamalla weightmapien layerit materiaalin tekstuureihin.

Ilman tata kayttajan pitaisi tayttaa layers.json kasin, mika rikkoisi automaattisen ajon.
Arvaus perustuu nimiin: layer 'Grass' ja tekstuuri 'T_Grass_01_D' kuuluvat yhteen.

Tama on nimenomaan arvaus, ei totuus. Tiedosto on tarkoitettu viilattavaksi kasin ja
maanpinnan bake (`ground_albedo.py`) voidaan ajaa uudelleen yksinaan sekunneissa.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import CONFIG, DUMP, WORK  # noqa: E402

# Vain varitekstuurit kelpaavat. Normaalikartat ja maskit pilaisivat albedon taysin.
ALBEDO_HINTS = ("_d", "_bc", "_alb", "albedo", "basecolor", "base_color", "diffuse", "_col")
REJECT_HINTS = ("_n", "_nrm", "normal", "_orm", "_rma", "_mask", "_ao", "_r_", "rough",
                "height", "_disp", "_spec", "_mt", "metal")

DEFAULT_TILING_M = 4.0


def tokens(name: str) -> set[str]:
    """Nimi vertailukelpoisiksi paloiksi: 'T_Grass_01_D' -> {'grass'}."""
    parts = re.split(r"[^a-z0-9]+", name.lower())
    drop = {"t", "tex", "texture", "d", "bc", "n", "alb", "albedo", "basecolor",
            "diffuse", "col", "mi", "m", "landscape", "land", "layer", "mat", ""}
    return {p for p in parts if p not in drop and not p.isdigit()}


def is_albedo(name: str) -> bool:
    low = name.lower()
    if any(h in low for h in REJECT_HINTS) and not any(h in low for h in ALBEDO_HINTS):
        return False
    return True


def score(layer: str, cand: str) -> float:
    """Kuinka hyvin tekstuurin nimi vastaa layerin nimea."""
    a, b = tokens(layer), tokens(cand)
    if not a or not b:
        return 0.0
    shared = a & b
    if not shared:
        # Osittainen osuma: 'rocky' vs 'rock'
        shared = {x for x in a if any(x in y or y in x for y in b)}
    if not shared:
        return 0.0
    return len(shared) / len(a | b)


def guess_tiling(layer: str, scalars: list[dict]) -> tuple[float, str | None]:
    """Etsi layerin tiilitysskalaari materiaalista.

    UE:n landscape-materiaaleissa tiilitys ilmaistaan joko metreina tai kaanteislukuna,
    eika nimesta voi paatella kumpi. Yli yhden arvot tulkitaan metreiksi ja alle yhden
    kaanteisluvuiksi - vaara arvaus nakyy vain tekstuurin karkeudessa, ei sijainnissa.
    """
    best, best_name = None, None
    for s in scalars:
        name = s.get("parameter", "")
        if score(layer, name) <= 0:
            continue
        if not any(k in name.lower() for k in ("tile", "tiling", "scale", "uv", "size")):
            continue
        v = float(s.get("value", 0) or 0)
        if v <= 0:
            continue
        best, best_name = (v if v > 1.0 else 1.0 / v), name
        break
    return (best or DEFAULT_TILING_M), best_name


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--texture-dir", default="assets/landscape",
                    help="minne DumpWorld vei landscape-tekstuurit")
    ap.add_argument("--out", default=str(CONFIG / "layers.json"))
    ap.add_argument("--force", action="store_true",
                    help="ylikirjoita olemassa oleva layers.json")
    args = ap.parse_args()

    out = Path(args.out)
    if out.exists() and not args.force:
        print(f"{out} on jo olemassa - ei ylikirjoiteta (kayta --force).")
        return 0

    layers = list(json.loads((WORK / "weightmaps" / "layers.json").read_text()))
    mat_path = DUMP / "landscape" / "material.json"
    mat = json.loads(mat_path.read_text()) if mat_path.exists() else {}
    tex_entries = [t for t in mat.get("textures", [])
                   if t.get("file") and is_albedo(t.get("parameter", ""))]
    scalars = mat.get("scalars", [])

    tex_dir = Path(args.texture_dir)
    result = {
        "_ohje": ("Arvattu automaattisesti nimien perusteella - viilaa kasin ja aja "
                  "ground_albedo.py uudelleen. 'tiling_m' = matka metreina jonka valein "
                  "tekstuuri toistuu. Ilman 'texture'-avainta kaytetaan 'color'-arvoa tai "
                  "layer-nimesta johdettua varivaria."),
    }

    matched = 0
    for layer in sorted(layers):
        best, best_score = None, 0.0
        for t in tex_entries:
            s = max(score(layer, t["parameter"]), score(layer, Path(t["file"]).stem))
            if s > best_score:
                best, best_score = t, s

        tiling, tiling_src = guess_tiling(layer, scalars)
        spec: dict = {"tiling_m": round(tiling, 3)}

        if best and best_score >= 0.34:
            spec["texture"] = str(tex_dir / best["file"]).replace("\\", "/")
            spec["_guess"] = {"parameter": best["parameter"], "score": round(best_score, 2)}
            matched += 1
            note = f"-> {best['file']} ({best_score:.2f})"
        else:
            note = "-> ei tekstuuriosumaa, kaytetaan varivaria"
        if tiling_src:
            spec["_guess"] = {**spec.get("_guess", {}), "tiling_from": tiling_src}

        result[layer] = spec
        print(f"  {layer:<28} {note}")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(f"\n{matched}/{len(layers)} layeria sai tekstuurin -> {out}")
    if matched < len(layers):
        print("Loput saavat erottuvan varivarin. Tarkista kartta ja korjaa layers.json "
              "tarvittaessa - ground-vaihe ajetaan uudelleen minuutissa.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
