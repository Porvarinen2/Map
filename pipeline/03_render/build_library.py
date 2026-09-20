#!/usr/bin/env python3
"""Rakentaa jaetun Blender-meshkirjaston ja mittaa jokaisen meshin koon.

Aja kerran ennen renderointia:
    blender -b -P pipeline/03_render/build_library.py -- --meshes assets/meshes

Kaksi tarkoitusta:
  1) assets/library.blend josta render_tile.py linkittaa meshit. Sama mesh-data
     jaetaan kaikkien tuhansien instanssien kesken, mika on ainoa tapa mahduttaa
     metsatiili 8 GB:n VRAMiin.
  2) work/mesh_bounds.json jota actor_db.py tarvitsee kokokarsintaan - ilman
     mittoja se ei tieda mika propsi jaa alle pikselin.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import bpy  # type: ignore

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "pipeline"))


def argv() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def opt(name: str, default=None):
    a = argv()
    return a[a.index(name) + 1] if name in a else default


def ue_path_to_key(ue_path: str) -> str:
    """'/Game/Foo/SM_Bar.SM_Bar' -> 'Game/Foo/SM_Bar' (vientipolku ilman luokkaosaa)."""
    p = ue_path.split(".")[0].lstrip("/")
    return p


def build_file_index(root: Path) -> dict[str, Path]:
    """Indeksoi viedyt meshit seka tayspolulla etta pelkalla nimella.

    FModel vie hakemistorakenteen sellaisenaan, mutta kayttaja voi myos litistaa sen,
    joten nimihaku on varajarjestelma."""
    index: dict[str, Path] = {}
    for ext in ("*.gltf", "*.glb", "*.fbx"):
        for f in root.rglob(ext):
            rel = f.relative_to(root).with_suffix("").as_posix()
            index.setdefault(rel, f)
            index.setdefault(f.stem, f)
    return index


def import_one(path: Path):
    before = set(bpy.data.objects)
    if path.suffix.lower() == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path))
    else:
        bpy.ops.import_scene.gltf(filepath=str(path))
    return [o for o in bpy.data.objects if o not in before and o.type == "MESH"]


def merge(objs, name: str):
    """Yhdistaa monimateriaaliset osat yhdeksi objektiksi - yksi objekti per mesh
    pitaa myohemman instansoinnin yksinkertaisena."""
    for o in bpy.data.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name
    return obj


def main() -> int:
    mesh_root = Path(opt("--meshes", str(REPO / "assets" / "meshes")))
    out_blend = Path(opt("--out", str(REPO / "assets" / "library.blend")))
    bounds_out = Path(opt("--bounds", str(REPO / "work" / "mesh_bounds.json")))
    needed_list = Path(opt("--needed", str(REPO / "dump" / "meshes_needed.txt")))

    if not mesh_root.exists():
        raise SystemExit(f"{mesh_root} puuttuu - vie dump/meshes_needed.txt:n meshit FModelista.")

    index = build_file_index(mesh_root)
    needed = (needed_list.read_text().split()
              if needed_list.exists() else sorted(index))
    print(f"{len(needed)} meshia listalla, {len(index)} tiedostoa loydetty")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    lib = bpy.data.collections.new("SCUM_Meshes")
    bpy.context.scene.collection.children.link(lib)

    bounds, missing = {}, []
    for i, ue_path in enumerate(needed):
        key = ue_path_to_key(ue_path)
        src = index.get(key) or index.get(key.split("/")[-1])
        if src is None:
            missing.append(ue_path)
            continue
        try:
            objs = import_one(src)
        except Exception as e:                                   # noqa: BLE001
            print(f"  {key}: tuonti epaonnistui ({e})")
            missing.append(ue_path)
            continue
        if not objs:
            missing.append(ue_path)
            continue

        obj = merge(objs, key.replace("/", "__"))
        for c in list(obj.users_collection):
            c.objects.unlink(obj)
        lib.objects.link(obj)

        # Paikalliset rajat metreina; glTF-vienti on jo metrimittakaavassa.
        xs = [v[0] for v in obj.bound_box]
        ys = [v[1] for v in obj.bound_box]
        zs = [v[2] for v in obj.bound_box]
        size = [max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)]
        bounds[ue_path] = {
            "object": obj.name,
            "size_m": size,
            # Sade UU:na, koska actor_db ja renderoijan marginaalit toimivat UU:ssa.
            "radius": 0.5 * max(size) * 100.0,
        }
        if (i + 1) % 200 == 0:
            print(f"  {i + 1}/{len(needed)}")

    bounds_out.parent.mkdir(parents=True, exist_ok=True)
    bounds_out.write_text(json.dumps(bounds, indent=1))
    out_blend.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(out_blend))

    print(f"\n{len(bounds)} meshia kirjastossa -> {out_blend}")
    print(f"Mitat -> {bounds_out}")
    if missing:
        print(f"{len(missing)} meshia puuttuu viennista, esim: {missing[:5]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
