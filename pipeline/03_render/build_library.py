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

Lisaksi se rakentaa materiaalit uudelleen. CUE4Parsen glTF-kirjoitin antaa jokaiselle
materiaalille pelkan valkoisen perusvarin ilman tekstuureja, joten ilman tata kaikki
renderoityy valkoisena - ja alfamaskatuista lehtikorteista tulee umpinaisia valkoisia
suorakaiteita, eli metsasta tulee lunta.
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


# ---------------------------------------------------------------- materiaalit

_mat_cache: dict = {}


def build_material(tex_path, blend: str, name: str):
    """Principled BSDF purun materiaalitiedoista.

    Alfan kytkeminen on tama koko tiedoston tarkein rivi: BLEND_Masked tarkoittaa
    lehtikorttia, jonka muoto tulee tekstuurin alfasta. Ilman sita kortti on umpinainen
    suorakaide.
    """
    key = (str(tex_path) if tex_path else None, blend)
    if key in _mat_cache:
        return _mat_cache[key]

    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.9
    for spec in ("Specular IOR Level", "Specular"):
        if spec in bsdf.inputs:
            bsdf.inputs[spec].default_value = 0.1
            break

    if tex_path and Path(tex_path).exists():
        node = nt.nodes.new("ShaderNodeTexImage")
        node.image = bpy.data.images.load(str(tex_path), check_existing=True)
        node.image.colorspace_settings.name = "sRGB"
        nt.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])

        if blend == "BLEND_Masked":
            nt.links.new(node.outputs["Alpha"], bsdf.inputs["Alpha"])
            # Cycles lukee alfan suoraan Principledista; nama ovat Eevee-esikatselua
            # varten ja niiden nimet ovat vaihdelleet Blender-versioittain.
            for attr, value in (("blend_method", "CLIP"), ("shadow_method", "CLIP"),
                                ("alpha_threshold", 0.33)):
                try:
                    setattr(mat, attr, value)
                except (AttributeError, TypeError):
                    pass
    else:
        # Ei valkoista: nakymaton materiaali on parempi arvata maanvariseksi.
        bsdf.inputs["Base Color"].default_value = (0.32, 0.33, 0.28, 1.0)

    mat.use_backface_culling = False       # lehtikortit nakyvat molemmilta puolilta
    _mat_cache[key] = mat
    return mat


def apply_materials(obj, slots: list, tex_dir: Path) -> int:
    """Korvaa glTF:n valkoiset materiaalit purun tiedoilla.

    Slotit taysmataan ensin nimella ja vasta sitten indeksilla: Blender lisaa
    nimiin .001-paatteita, ja glTF-tuonti voi jarjestaa slotit uudelleen.
    """
    by_name = {s["Slot"]: s for s in slots if s.get("Slot")}
    applied = 0

    for i, slot in enumerate(obj.material_slots):
        current = (slot.material.name if slot.material else "").rsplit(".", 1)[0]
        entry = by_name.get(current)
        if entry is None:
            entry = next((s for s in slots if s.get("Index") == i), None)
        if entry is None:
            continue

        diffuse = entry.get("Diffuse")
        tex = (tex_dir / f"{diffuse}.png") if diffuse else None
        slot.material = build_material(tex, entry.get("Blend", "BLEND_Opaque"),
                                       f"{entry.get('Slot', 'mat')}_{i}")
        applied += 1
    return applied


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

    materials_path = Path(opt("--materials", str(REPO / "dump" / "mesh_materials.json")))
    materials = json.loads(materials_path.read_text()) if materials_path.exists() else {}
    tex_dir = mesh_root / "_textures"
    if materials:
        print(f"{len(materials)} meshin materiaalitiedot, tekstuurit {tex_dir}")
    else:
        print(f"VAROITUS: {materials_path} puuttuu - meshit jaavat varittomiksi. "
              "Aja DumpWorld --mesh-materials-only.")

    index = build_file_index(mesh_root)
    needed = (needed_list.read_text().split()
              if needed_list.exists() else sorted(index))
    print(f"{len(needed)} meshia listalla, {len(index)} tiedostoa loydetty")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    lib = bpy.data.collections.new("SCUM_Meshes")
    bpy.context.scene.collection.children.link(lib)

    bounds, missing = {}, []
    applied = 0
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
        if ue_path in materials:
            applied += apply_materials(obj, materials[ue_path], tex_dir)
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
    print(f"{applied} materiaalislottia sai tekstuurin, {len(_mat_cache)} uniikkia materiaalia")
    print(f"Mitat -> {bounds_out}")
    if missing:
        print(f"{len(missing)} meshia puuttuu viennista, esim: {missing[:5]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
