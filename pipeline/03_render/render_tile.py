#!/usr/bin/env python3
"""Renderoi yhden kartan tiilen ortokameralla.

    blender -b -P pipeline/03_render/render_tile.py -- --tile 7 9

Koko saarta ei rakenneta kertaakaan yhteen sceneen. Jokainen tiili kysyy kannalta vain
omat objektinsa, renderoi ne ja vapauttaa muistin - tama on ainoa tapa saada 12 km
maailma ulos 8 GB:n naytonohjaimelta.

Saumattomuus on tassa yhta tarkeaa kuin tarkkuus: aurinko, exposure ja varinhallinta
on lukittu identtisiksi joka tiilelle. Yksikin poikkeava asetus nakyy lopullisessa
32K-kuvassa ruudukkona jota ei saa enaa jalkikateen pois.
"""
from __future__ import annotations

import json
import math
import sqlite3
import sys
from pathlib import Path

import bpy  # type: ignore
import numpy as np

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "pipeline"))
from common import WORK, OUT, World, ensure_dirs  # noqa: E402

UU = 0.01  # Unreal-yksikko metreina

# Lukitut valaistusarvot. ALA muuta naita kesken ajon - tiilista tulee eriparisia.
# Tasot on viritetty kohti pelin oman kartan ilmetta: tumma kylla metsa, ei pesty.
SUN_AZIMUTH = 315.0
SUN_ELEVATION = 60.0
SUN_STRENGTH = 3.2
SUN_ANGLE_DEG = 1.5      # pehmea mutta luettava varjonreuna
WORLD_FILL = (0.32, 0.36, 0.42)
WORLD_STRENGTH = 0.5


# ---------------------------------------------------------------- argumentit

def argv() -> list[str]:
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def opt(name: str, default=None, cast=str):
    a = argv()
    return cast(a[a.index(name) + 1]) if name in a else default


def flag(name: str) -> bool:
    return name in argv()


# ---------------------------------------------------------------- koordinaatisto

def ue_to_blender_loc(x, y, z):
    """UE on vasenkatinen ja senttimetreissa, Blender oikeakatinen ja metreissa."""
    return (x * UU, -y * UU, z * UU)


def ue_to_blender_rot(pitch, yaw, roll):
    return (math.radians(roll), math.radians(-pitch), math.radians(-yaw))


# ---------------------------------------------------------------- maasto

def build_terrain(world: World, tx: int, ty: int, heights: np.ndarray,
                  step_m: float, ground_tex: Path):
    """Tiilen oma maastopala, tarkalleen tiilen rajoissa.

    Marginaalia ei tarvita: tiilen ulkopuoliset objektit heittavat varjonsa tahan
    samaan palaan, koska varjosade osuu siihen tiilen sisapuolella.
    """
    x0, y0, x1, y1 = world.tile_bounds_uu(tx, ty)
    span_m = (x1 - x0) * UU
    n = max(2, int(round(span_m / step_m)) + 1)

    loc = world.landscape.get("location", [0.0, 0.0, 0.0])
    scale = world.landscape.get("scale", [100.0, 100.0, 100.0])
    gox, goy = world.landscape.get("grid_origin_quads", [0, 0])

    t = np.linspace(0.0, 1.0, n, dtype=np.float64)
    ux = x0 + t * (x1 - x0)
    uy = y0 + t * (y1 - y0)

    # Korkeuskartan naytteistys (lahin naapuri riittaa: askel >= 1 vertex).
    vx = np.clip(((ux - loc[0]) / scale[0] - gox).round().astype(np.int64),
                 0, heights.shape[1] - 1)
    vy = np.clip(((uy - loc[1]) / scale[1] - goy).round().astype(np.int64),
                 0, heights.shape[0] - 1)
    h_uu = world.landscape_height_uu(heights[np.ix_(vy, vx)].astype(np.float64))

    gx, gy = np.meshgrid(ux, uy)
    co = np.empty((n * n, 3), dtype=np.float32)
    co[:, 0] = (gx * UU).ravel()
    co[:, 1] = (-gy * UU).ravel()
    co[:, 2] = (h_uu * UU).ravel()

    me = bpy.data.meshes.new(f"terrain_{tx}_{ty}")
    me.vertices.add(n * n)
    me.vertices.foreach_set("co", co.ravel())

    idx = np.arange(n * n, dtype=np.int32).reshape(n, n)
    quads = np.stack([idx[:-1, :-1], idx[:-1, 1:], idx[1:, 1:], idx[1:, :-1]], axis=-1)
    quads = quads.reshape(-1, 4)
    nq = len(quads)
    me.loops.add(nq * 4)
    me.loops.foreach_set("vertex_index", quads.ravel())
    me.polygons.add(nq)
    me.polygons.foreach_set("loop_start", (np.arange(nq, dtype=np.int32) * 4))
    try:                                  # loop_total poistui Blender 4.1:ssa
        me.polygons.foreach_set("loop_total", np.full(nq, 4, dtype=np.int32))
    except Exception:                     # noqa: BLE001
        pass
    me.update(calc_edges=True)

    # UV suoraan tiilen albedotekstuuriin. Albedokuvan rivi 0 on pienin UE-Y, mutta
    # UV:n v=0 on kuvan alalaita -> v kaantyy.
    uvv = np.empty((n * n, 2), dtype=np.float32)
    uvv[:, 0] = np.tile(t, n)
    uvv[:, 1] = 1.0 - np.repeat(t, n)
    uv = me.uv_layers.new(name="UVMap")
    uv.data.foreach_set("uv", uvv[quads.ravel()].ravel())

    obj = bpy.data.objects.new(me.name, me)
    obj.data.materials.append(terrain_material(ground_tex))
    bpy.context.scene.collection.objects.link(obj)
    return obj


def terrain_material(tex_path: Path):
    mat = bpy.data.materials.new("Ground")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.92
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.15
    elif "Specular" in bsdf.inputs:
        bsdf.inputs["Specular"].default_value = 0.15

    if tex_path and Path(tex_path).exists():
        img = nt.nodes.new("ShaderNodeTexImage")
        img.image = bpy.data.images.load(str(tex_path))
        img.image.colorspace_settings.name = "sRGB"
        img.extension = "EXTEND"
        img.interpolation = "Closest"     # albedo on jo tasan ulostuloresoluutiossa
        nt.links.new(img.outputs["Color"], bsdf.inputs["Base Color"])
    else:
        bsdf.inputs["Base Color"].default_value = (0.25, 0.28, 0.20, 1.0)
    return mat


# ---------------------------------------------------------------- objektit

def link_library(path: Path) -> dict:
    """Linkittaa kirjaston objektit. Linkitys eika append: mesh-data pysyy yhtena
    kopiona riippumatta siita montako tuhatta instanssia siita tehdaan."""
    if not path.exists():
        print(f"VAROITUS: {path} puuttuu - renderoidaan pelkka maasto.")
        return {}
    with bpy.data.libraries.load(str(path), link=True) as (src, dst):
        dst.objects = list(src.objects)
    return {o.name: o for o in dst.objects if o is not None}


def query_tile(db: Path, world: World, tx: int, ty: int, margin_uu: float):
    x0, y0, x1, y1 = world.tile_bounds_uu(tx, ty)
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute(
        "SELECT m.path, a.kind, a.x, a.y, a.z, a.pitch, a.yaw, a.roll, a.sx, a.sy, a.sz "
        "FROM actors a JOIN meshes m ON m.id = a.mesh_id "
        "WHERE a.x BETWEEN ? AND ? AND a.y BETWEEN ? AND ?",
        (x0 - margin_uu, x1 + margin_uu, y0 - margin_uu, y1 + margin_uu),
    ).fetchall()
    con.close()
    return rows


def mesh_object(lib: dict, bounds: dict, ue_path: str):
    name = bounds.get(ue_path, {}).get("object")
    return lib.get(name) if name else None


def add_statics(rows, lib, bounds) -> int:
    added = 0
    coll = bpy.context.scene.collection
    for path, _kind, x, y, z, pitch, yaw, roll, sx, sy, sz in rows:
        src = mesh_object(lib, bounds, path)
        if src is None:
            continue
        obj = bpy.data.objects.new(src.name + "_i", src.data)   # jaettu mesh-data
        obj.location = ue_to_blender_loc(x, y, z)
        obj.rotation_euler = ue_to_blender_rot(pitch, yaw, roll)
        obj.scale = (sx, sy, sz)
        coll.objects.link(obj)
        added += 1
    return added


def foliage_node_group():
    """Instance on Points -ryhma: pistepilvi + attribuutit -> instanssit.

    Tama on koko renderoinnin muistiratkaisu. Satatuhatta puuta objekteina kaataa
    Blenderin; instansseina ne ovat kevyita, koska mesh on muistissa kerran.
    """
    name = "SCUM_Foliage"
    if name in bpy.data.node_groups:
        return bpy.data.node_groups[name]

    ng = bpy.data.node_groups.new(name, "GeometryNodeTree")
    try:                                   # Blender 4.x
        ng.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
        ng.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    except AttributeError:                 # Blender 3.x
        ng.inputs.new("NodeSocketGeometry", "Geometry")
        ng.outputs.new("NodeSocketGeometry", "Geometry")

    nodes, links = ng.nodes, ng.links
    n_in = nodes.new("NodeGroupInput")
    n_out = nodes.new("NodeGroupOutput")
    info = nodes.new("GeometryNodeObjectInfo")
    info.inputs["As Instance"].default_value = True
    iop = nodes.new("GeometryNodeInstanceOnPoints")

    rot = nodes.new("GeometryNodeInputNamedAttribute")
    rot.data_type = "FLOAT_VECTOR"
    rot.inputs["Name"].default_value = "inst_rot"
    scl = nodes.new("GeometryNodeInputNamedAttribute")
    scl.data_type = "FLOAT_VECTOR"
    scl.inputs["Name"].default_value = "inst_scale"

    links.new(n_in.outputs[0], iop.inputs["Points"])
    links.new(info.outputs["Geometry"], iop.inputs["Instance"])
    links.new(rot.outputs["Attribute"], iop.inputs["Rotation"])
    links.new(scl.outputs["Attribute"], iop.inputs["Scale"])
    links.new(iop.outputs["Instances"], n_out.inputs[0])
    return ng


def add_foliage(rows, lib, bounds) -> int:
    groups: dict[str, list] = {}
    for path, kind, *rest in rows:
        if kind:
            groups.setdefault(path, []).append(rest)

    ng = foliage_node_group()
    coll = bpy.context.scene.collection
    total = 0

    for path, insts in groups.items():
        src = mesh_object(lib, bounds, path)
        if src is None:
            continue
        a = np.asarray(insts, dtype=np.float64)
        n = len(a)

        co = np.empty((n, 3), dtype=np.float32)
        co[:, 0] = a[:, 0] * UU
        co[:, 1] = -a[:, 1] * UU
        co[:, 2] = a[:, 2] * UU

        rot = np.empty((n, 3), dtype=np.float32)
        rot[:, 0] = np.radians(a[:, 5])     # roll  -> X
        rot[:, 1] = np.radians(-a[:, 3])    # pitch -> -Y
        rot[:, 2] = np.radians(-a[:, 4])    # yaw   -> -Z

        me = bpy.data.meshes.new(f"pts_{src.name}")
        me.vertices.add(n)
        me.vertices.foreach_set("co", co.ravel())
        me.update()

        me.attributes.new("inst_rot", "FLOAT_VECTOR", "POINT")
        me.attributes["inst_rot"].data.foreach_set("vector", rot.ravel())
        me.attributes.new("inst_scale", "FLOAT_VECTOR", "POINT")
        me.attributes["inst_scale"].data.foreach_set(
            "vector", a[:, 6:9].astype(np.float32).ravel())

        obj = bpy.data.objects.new(f"foliage_{src.name}", me)
        coll.objects.link(obj)
        mod = obj.modifiers.new("Foliage", "NODES")
        # Oma kopio ryhmasta per laji, jotta Object Info osoittaa oikeaan meshiin.
        group = ng.copy()
        for node in group.nodes:
            if node.bl_idname == "GeometryNodeObjectInfo":
                node.inputs["Object"].default_value = src
        mod.node_group = group
        total += n
    return total


# ---------------------------------------------------------------- kamera & render

def setup_camera(world: World, tx: int, ty: int, overscan: float):
    cx, cy = world.tile_center_uu(tx, ty)
    cam_data = bpy.data.cameras.new("OrthoCam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = world.tile_size_uu * UU * (1.0 + 2.0 * overscan)
    cam_data.clip_start = 1.0
    cam_data.clip_end = 20000.0

    cam = bpy.data.objects.new("OrthoCam", cam_data)
    cam.location = (cx * UU, -cy * UU, 8000.0)
    cam.rotation_euler = (0.0, 0.0, 0.0)          # suoraan alas
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    return cam


def setup_lighting():
    sun_data = bpy.data.lights.new("Sun", "SUN")
    sun_data.energy = SUN_STRENGTH
    sun_data.angle = math.radians(SUN_ANGLE_DEG)
    sun = bpy.data.objects.new("Sun", sun_data)
    # Sun-valo osoittaa oletuksena suoraan alas; X-kierto nostaa sen korkeuskulmaan
    # ja Z-kierto asettaa atsimuutin.
    sun.rotation_euler = (math.radians(90.0 - SUN_ELEVATION), 0.0,
                          math.radians(SUN_AZIMUTH))
    bpy.context.scene.collection.objects.link(sun)

    world = bpy.data.worlds.new("Sky")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (*WORLD_FILL, 1.0)
    bg.inputs["Strength"].default_value = WORLD_STRENGTH
    bpy.context.scene.world = world


def setup_render(engine: str, samples: int, res: int):
    scene = bpy.context.scene
    scene.render.resolution_x = scene.render.resolution_y = res
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.image_settings.color_depth = "8"

    # Standard-nakymamuunnos, ei AgX/Filmic: tiilien on sovittava toisiinsa
    # pikselintarkasti, eika sovitus saa riippua tiilen omasta dynamiikasta.
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.0
    scene.view_settings.gamma = 1.0

    if engine.lower().startswith("eevee"):
        scene.render.engine = ("BLENDER_EEVEE_NEXT"
                               if "BLENDER_EEVEE_NEXT" in _engines() else "BLENDER_EEVEE")
        return

    scene.render.engine = "CYCLES"
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.cycles.use_adaptive_sampling = True
    scene.cycles.device = "GPU"
    # Ei heijastuksia joita ylhaalta ei nay: nopeampi ja tasaisempi.
    scene.cycles.max_bounces = 4
    scene.cycles.glossy_bounces = 1
    scene.cycles.transmission_bounces = 2
    _enable_gpu()


def _engines() -> set[str]:
    return {i.identifier for i in
            bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items}


def _enable_gpu() -> None:
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        for backend in ("OPTIX", "CUDA", "HIP", "ONEAPI"):
            prefs.compute_device_type = backend
            prefs.get_devices()
            if any(d.type == backend for d in prefs.devices):
                for d in prefs.devices:
                    d.use = d.type in (backend, "CPU")
                print(f"  GPU-backend: {backend}")
                return
    except Exception as e:                                        # noqa: BLE001
        print(f"  GPU-asetus epaonnistui ({e}), jatketaan CPU:lla")


def render_and_crop(dst: Path, res: int, overscan: float, tile_px: int) -> None:
    """Renderoi ylisuurena ja leikkaa. Denoiserin reunavirheet jaisivat muuten
    juuri tiilien saumoihin, jossa ne nakyvat kaikkein pahiten."""
    tmp = dst.with_suffix(".over.png")
    bpy.context.scene.render.filepath = str(tmp)
    bpy.ops.render.render(write_still=True)

    if overscan <= 0:
        tmp.replace(dst)
        return

    img = bpy.data.images.load(str(tmp))
    channels = img.channels
    px = np.empty(res * res * channels, dtype=np.float32)
    img.pixels.foreach_get(px)             # foreach_get: listamuunnos olisi minuutteja
    px = px.reshape(res, res, channels)

    off = (res - tile_px) // 2
    crop = np.ascontiguousarray(px[off:off + tile_px, off:off + tile_px, :])

    out = bpy.data.images.new("crop", tile_px, tile_px, alpha=(channels == 4))
    out.pixels.foreach_set(crop.ravel())
    out.file_format = "PNG"
    out.filepath_raw = str(dst)
    out.save()
    bpy.data.images.remove(img)
    tmp.unlink(missing_ok=True)


# ---------------------------------------------------------------- paaohjelma

def main() -> int:
    a = argv()
    if "--tile" not in a:
        raise SystemExit("Kaytto: blender -b -P render_tile.py -- --tile <x> <y>")
    i = a.index("--tile")
    tx, ty = int(a[i + 1]), int(a[i + 2])

    engine = opt("--engine", "cycles")
    samples = opt("--samples", 256, int)
    overscan = opt("--overscan", 0.08, float)
    margin_m = opt("--margin-m", 200.0, float)
    step_m = opt("--terrain-step-m", 1.0, float)
    db = Path(opt("--db", str(WORK / "scene.sqlite")))
    library = Path(opt("--library", str(REPO / "assets" / "library.blend")))
    ground_dir = Path(opt("--ground", str(WORK / "ground_flat")))
    out_dir = Path(opt("--out", str(OUT / "tiles")))

    world = World.load()
    heights = np.load(WORK / "heightmap.npy")
    bounds_path = WORK / "mesh_bounds.json"
    bounds = json.loads(bounds_path.read_text()) if bounds_path.exists() else {}

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 1.0

    ground_tex = ground_dir / f"ground_{tx:02d}_{ty:02d}.png"
    build_terrain(world, tx, ty, heights, step_m, ground_tex)

    lib = link_library(library)
    if lib and db.exists():
        rows = query_tile(db, world, tx, ty, margin_m * 100.0)
        n_static = add_statics([r for r in rows if not r[1]], lib, bounds)
        n_foliage = add_foliage(rows, lib, bounds)
        print(f"  tiili {tx},{ty}: {n_static} meshia, {n_foliage} kasvi-instanssia")

    setup_lighting()
    setup_camera(world, tx, ty, overscan)

    res = int(round(world.tile_px * (1.0 + 2.0 * overscan)))
    res += res % 2
    setup_render(engine, samples, res)

    ensure_dirs(out_dir)
    dst = out_dir / f"tile_{tx:02d}_{ty:02d}.png"
    render_and_crop(dst, res, overscan, world.tile_px)
    print(f"Valmis: {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
