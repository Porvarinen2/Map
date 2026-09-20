#!/usr/bin/env python3
"""Ajaa OIKEAN Blender-renderoinnin synteettisella maailmalla ja tarkistaa pikselit.

Tama on olemassa siksi, etta putken Blender-osat oli pitkaan kirjoitettu sokkona:
build_library.py ja render_tile.py eivat ajautuneet missaan ennen kuin kayttaja ajoi
ne omalla koneellaan, joten bugit loytyivat vasta siella.

Ratkaiseva ero tavalliseen savutestiin: tama ei tyydy siihen etta ajo ei kaatunut,
vaan **katsoo lopputuloksen pikseleita**. Geometry Nodes -instansointi ei anna
virheilmoitusta jos se tuottaa tyhjaa - se vain tuottaa tyhjaa, ja render onnistuu.
Ainoa tapa todeta etta puut oikeasti syntyvat on etsia ne valmiista kuvasta.

    python3 tools/blender_selftest.py [--blender /polku/blender]
"""
from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "pipeline"))

# Synteettisen maailman mitat: yksi 256 px tiili, 128 m maastoa.
GRID_QUADS = 128
SCALE = 100.0
OUTPUT_PX = 256

HOUSE = "/Game/Test/SM_House.SM_House"
TREE = "/Game/Test/SM_Tree.SM_Tree"

# Rajut perusvarit, jotta ne erottuvat valmiista renderista yksiselitteisesti.
HOUSE_RGB = (40, 60, 210)
LEAF_RGB = (40, 200, 60)
BARK_RGB = (90, 60, 40)


# ---------------------------------------------------------------- Blender-apurit

MAKE_ASSETS = r'''
import bpy, sys, math
from pathlib import Path

out = Path(sys.argv[sys.argv.index("--") + 1])
bpy.ops.wm.read_factory_settings(use_empty=True)


def export(objs, rel):
    for o in bpy.data.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    path = out / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB",
                              use_selection=True, export_yup=True)


def mat(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    return m


# Rakennus: 10 x 10 x 6 m laatikko.
bpy.ops.mesh.primitive_cube_add(size=1)
house = bpy.context.active_object
house.name = "House"
house.scale = (5.0, 5.0, 3.0)
bpy.ops.object.transform_apply(scale=True)
house.data.materials.append(mat("Body"))
export([house], "Game/Test/SM_House.glb")
bpy.data.objects.remove(house)

# Puu: sylinterirunko + ristikkaiset lehtikortit. Kortit ovat se tapaus joka menee
# rikki ilman alfaa - umpinaisena ne ovat valkoisia suorakaiteita.
bpy.ops.mesh.primitive_cylinder_add(radius=0.25, depth=6.0, location=(0, 0, 3))
trunk = bpy.context.active_object
trunk.name = "Trunk"
trunk.data.materials.append(mat("Bark"))

# Latvusto: kaksi pystykorttia ja yksi vaakakortti. Vaakakortti on se joka nakyy
# suoraan ylhaalta - pelkilla pystykorteilla testi ei kertoisi mitaan ortokamerasta.
cards = []
for angle in (0.0, math.pi / 2):
    bpy.ops.mesh.primitive_plane_add(size=6.0, location=(0, 0, 7))
    card = bpy.context.active_object
    card.rotation_euler = (math.pi / 2, 0, angle)
    bpy.ops.object.transform_apply(rotation=True)
    card.data.materials.append(bpy.data.materials["Bark"])
    cards.append(card)

bpy.ops.mesh.primitive_plane_add(size=6.0, location=(0, 0, 8))
top = bpy.context.active_object
top.data.materials.append(bpy.data.materials["Bark"])
cards.append(top)

for o in bpy.data.objects:
    o.select_set(False)
for o in [trunk] + cards:
    o.select_set(True)
bpy.context.view_layer.objects.active = trunk
bpy.ops.object.join()
tree = bpy.context.active_object
tree.name = "Tree"

# Kaksi slottia: runko ja lehdet. Lehtikortit saavat toisen slotin.
tree.data.materials.append(mat("Leaves"))
for poly in tree.data.polygons:
    if all(tree.data.vertices[v].co.z > 4.0 for v in poly.vertices):
        poly.material_index = 1

export([tree], "Game/Test/SM_Tree.glb")
print("ASSETS_OK")
'''


INSPECT_LIBRARY = r'''
import bpy, sys, json
bpy.ops.wm.read_factory_settings(use_empty=True)
path = sys.argv[sys.argv.index("--") + 1]
with bpy.data.libraries.load(path, link=True) as (src, dst):
    dst.objects = list(src.objects)

out = {}
for o in dst.objects:
    if o is None:
        continue
    mats = []
    for slot in o.material_slots:
        m = slot.material
        if m is None or not m.node_tree:
            continue
        mats.append({
            "name": m.name,
            "images": [n.image.name for n in m.node_tree.nodes
                       if n.type == "TEX_IMAGE" and n.image],
            "alpha_linked": any(l.to_socket.name == "Alpha" for l in m.node_tree.links),
        })
    out[o.name] = mats
print("LIBRARY_JSON:" + json.dumps(out))
'''


def run_blender(blender: str, script: str, *args: str, label: str = "") -> str:
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(script)
        tmp = f.name
    try:
        r = subprocess.run([blender, "-b", "--factory-startup", "-noaudio",
                            "-P", tmp, "--", *args],
                           capture_output=True, text=True)
    finally:
        Path(tmp).unlink(missing_ok=True)
    if r.returncode:
        print(r.stdout[-4000:], r.stderr[-4000:])
        raise SystemExit(f"Blender epaonnistui ({label})")
    return r.stdout


def run_blender_file(blender: str, script: Path, *args: str, label: str = "") -> str:
    r = subprocess.run([blender, "-b", "--factory-startup", "-noaudio",
                        "-P", str(script), "--", *args],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-6000:], r.stderr[-4000:])
        raise SystemExit(f"Blender epaonnistui ({label})")
    return r.stdout


# ---------------------------------------------------------------- synteettinen data

def write_texture(path: Path, rgb, size: int = 32, masked: bool = False) -> None:
    from PIL import Image

    px = np.zeros((size, size, 4), dtype=np.uint8)
    px[..., :3] = rgb
    px[..., 3] = 255
    if masked:
        # Reunat lapinakyvia: jos alfa ei toimi, kortti nakyy taytena suorakaiteena.
        px[..., 3] = 0
        r = size // 4
        px[r:size - r, r:size - r, 3] = 255
    Image.fromarray(px).save(path)


def build_world(root: Path):
    from common import World

    (root / "work").mkdir(parents=True, exist_ok=True)
    (root / "config").mkdir(parents=True, exist_ok=True)

    world = World(
        origin_uu=(0.0, 0.0),
        size_uu=(GRID_QUADS * SCALE, GRID_QUADS * SCALE),
        output_px=OUTPUT_PX,
        tile_grid=1,
        uu_per_meter=100.0,
        landscape={"location": [0.0, 0.0, 0.0], "scale": [SCALE, SCALE, SCALE],
                   "grid_origin_quads": [0, 0],
                   "grid_size_verts": [GRID_QUADS + 1, GRID_QUADS + 1]},
    )
    world.save(root / "config" / "world.json")

    # Loiva rinne, jotta maaston varjostus nakyy eika kuva ole tasavarinen.
    n = GRID_QUADS + 1
    ramp = np.linspace(0, 2560, n, dtype=np.float64)
    heights = (32768 + ramp[None, :] + ramp[:, None] * 0.5).astype(np.uint16)
    np.save(root / "work" / "heightmap.npy", heights)

    ground = root / "work" / "ground_flat"
    ground.mkdir(parents=True, exist_ok=True)
    from PIL import Image
    tile = np.zeros((OUTPUT_PX, OUTPUT_PX, 3), dtype=np.uint8)
    tile[..., 0] = np.linspace(90, 150, OUTPUT_PX, dtype=np.uint8)[None, :]
    tile[..., 1] = 110
    tile[..., 2] = 70
    Image.fromarray(tile).save(ground / "ground_00_00.png")
    return world


def terrain_z(root: Path, world, x_uu, y_uu):
    """Maaston korkeus annetuissa kohdissa.

    Objektit on asetettava maanpinnalle: origoon jatettyina ne jaavat rinteen alle
    eivatka nay renderissa lainkaan.
    """
    heights = np.load(root / "work" / "heightmap.npy")
    ix = np.clip((np.asarray(x_uu) / SCALE).astype(int), 0, heights.shape[1] - 1)
    iy = np.clip((np.asarray(y_uu) / SCALE).astype(int), 0, heights.shape[0] - 1)
    return world.landscape_height_uu(heights[iy, ix].astype(np.float64))


def build_scene_db(root: Path, world) -> tuple[int, int]:
    """Talo keskelle, puuklusteri tunnettuun kohtaan - molemmat maanpinnalle."""
    db = root / "work" / "scene.sqlite"
    con = sqlite3.connect(db)
    sys.path.insert(0, str(REPO / "pipeline" / "02_scene"))
    import actor_db

    con.executescript(actor_db.SCHEMA)
    con.execute("INSERT INTO meshes (id, path, radius) VALUES (1, ?, 900)", (HOUSE,))
    con.execute("INSERT INTO meshes (id, path, radius) VALUES (2, ?, 500)", (TREE,))

    cx = cy = GRID_QUADS * SCALE / 2.0
    hz = float(terrain_z(root, world, cx, cy))
    con.execute(
        "INSERT INTO actors (mesh_id, kind, x, y, z, pitch, yaw, roll, sx, sy, sz, radius) "
        "VALUES (1, 0, ?, ?, ?, 0, 0, 0, 1, 1, 1, 900)", (cx, cy, hz + 300.0))

    rng = np.random.default_rng(11)
    n_trees = 120
    # Oma neljannes, jotta puut ja talo eivat mene sekaisin tarkistuksessa.
    tx = rng.uniform(cx * 0.2, cx * 0.8, n_trees)
    ty = rng.uniform(cy * 0.2, cy * 0.8, n_trees)
    tz = terrain_z(root, world, tx, ty)
    con.executemany(
        "INSERT INTO actors (mesh_id, kind, x, y, z, pitch, yaw, roll, sx, sy, sz, radius) "
        "VALUES (2, 1, ?, ?, ?, 0, ?, 0, 1, 1, 1, 500)",
        [(float(x), float(y), float(z), float(rng.uniform(0, 360)))
         for x, y, z in zip(tx, ty, tz)])

    con.executescript(actor_db.INDEXES)
    con.commit()
    con.close()
    return 1, n_trees


# ---------------------------------------------------------------- tarkistukset

def dominant_mask(px: np.ndarray, channel: int, margin: int = 25) -> np.ndarray:
    """Pikselit joissa annettu kanava on selvasti muita suurempi."""
    others = [c for c in range(3) if c != channel]
    a = px[..., channel].astype(np.int16)
    return (a - px[..., others[0]] > margin) & (a - px[..., others[1]] > margin)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--blender", default=shutil.which("blender") or "/opt/blender/blender")
    ap.add_argument("--keep", action="store_true", help="ala poista tyohakemistoa")
    args = ap.parse_args()

    if not (shutil.which(args.blender) or Path(args.blender).exists()):
        raise SystemExit(f"Blenderia ei loydy: {args.blender}")

    tmp = Path(tempfile.mkdtemp(prefix="scum_blender_"))
    print(f"Tyohakemisto {tmp}")
    from PIL import Image

    try:
        meshes = tmp / "assets" / "meshes"
        meshes.mkdir(parents=True, exist_ok=True)

        print("[1/5] synteettiset meshit")
        out = run_blender(args.blender, MAKE_ASSETS, str(meshes), label="assetit")
        assert "ASSETS_OK" in out
        assert (meshes / "Game/Test/SM_House.glb").exists()
        assert (meshes / "Game/Test/SM_Tree.glb").exists()

        tex = meshes / "_textures"
        tex.mkdir(exist_ok=True)
        write_texture(tex / "T_House_D.png", HOUSE_RGB)
        write_texture(tex / "T_Bark_D.png", BARK_RGB)
        write_texture(tex / "T_Leaf_D.png", LEAF_RGB, masked=True)

        (tmp / "dump").mkdir(exist_ok=True)
        (tmp / "dump" / "mesh_materials.json").write_text(json.dumps({
            HOUSE: [{"Index": 0, "Slot": "Body", "Diffuse": "T_House_D",
                     "Blend": "BLEND_Opaque"}],
            TREE: [{"Index": 0, "Slot": "Bark", "Diffuse": "T_Bark_D",
                    "Blend": "BLEND_Opaque"},
                   {"Index": 1, "Slot": "Leaves", "Diffuse": "T_Leaf_D",
                    "Blend": "BLEND_Masked", "TwoSided": True}],
        }))
        (tmp / "dump" / "meshes_needed.txt").write_text(f"{HOUSE}\n{TREE}\n")

        print("[2/5] build_library.py")
        run_blender_file(
            args.blender, REPO / "pipeline" / "03_render" / "build_library.py",
            "--meshes", str(meshes),
            "--out", str(tmp / "assets" / "library.blend"),
            "--bounds", str(tmp / "work" / "mesh_bounds.json"),
            "--needed", str(tmp / "dump" / "meshes_needed.txt"),
            "--materials", str(tmp / "dump" / "mesh_materials.json"),
            label="kirjasto")

        bounds_path = tmp / "work" / "mesh_bounds.json"
        assert bounds_path.exists(), "mesh_bounds.json puuttuu"
        bounds = json.loads(bounds_path.read_text())
        assert HOUSE in bounds and TREE in bounds, list(bounds)
        assert (tmp / "assets" / "library.blend").exists()

        # Materiaalit tarkistetaan kirjastosta, ei renderista: nain virhe kertoo
        # suoraan mika meni rikki eika pelkastaan etta kuva nayttaa vaaralta.
        report = run_blender(args.blender, INSPECT_LIBRARY,
                             str(tmp / "assets" / "library.blend"), label="materiaalit")
        info = json.loads(report.split("LIBRARY_JSON:")[1].splitlines()[0])
        print(f"    kirjasto: {len(info)} objektia")
        tree_mats = next(v for k, v in info.items() if "Tree" in k)
        assert any(m["images"] for m in tree_mats), (
            "kirjaston materiaaleissa ei ole tekstuureja - apply_materials ei ajautunut")
        masked = [m for m in tree_mats if m["alpha_linked"]]
        assert masked, "maskatun materiaalin alfaa ei ole kytketty - lehdet jaavat umpinaisiksi"
        print(f"    materiaalit: {sum(len(m['images']) for m in tree_mats)} tekstuuria, "
              f"{len(masked)} maskattua")

        print("[3/5] maailma ja kohtaus")
        world = build_world(tmp)
        n_house, n_trees = build_scene_db(tmp, world)

        print("[4/5] render_tile.py")
        import os
        env = {**os.environ, "SCUM_WORK": str(tmp / "work"),
               "SCUM_OUT": str(tmp / "out"), "SCUM_CONFIG": str(tmp / "config")}
        r = subprocess.run(
            [args.blender, "-b", "--factory-startup", "-noaudio",
             "-P", str(REPO / "pipeline" / "03_render" / "render_tile.py"), "--",
             "--tile", "0", "0", "--samples", "24", "--overscan", "0",
             "--db", str(tmp / "work" / "scene.sqlite"),
             "--library", str(tmp / "assets" / "library.blend"),
             "--ground", str(tmp / "work" / "ground_flat"),
             "--out", str(tmp / "out" / "tiles")],
            capture_output=True, text=True, env=env)
        if r.returncode:
            print(r.stdout[-6000:], r.stderr[-4000:])
            raise SystemExit("render_tile epaonnistui")
        for line in r.stdout.splitlines():
            if "tiili" in line or "Valmis" in line:
                print(f"    {line.strip()}")

        tile_png = tmp / "out" / "tiles" / "tile_00_00.png"
        assert tile_png.exists(), "tiilta ei syntynyt"

        print("[5/5] pikselitarkistus")
        px = np.asarray(Image.open(tile_png).convert("RGB"))
        assert px.shape == (OUTPUT_PX, OUTPUT_PX, 3), px.shape

        blue = int(dominant_mask(px, 2).sum())
        green = int(dominant_mask(px, 1).sum())
        print(f"    sinisia (rakennus) {blue}, vihreita (lehdet) {green}, "
              f"hajonta {px.std():.1f}")

        assert px.std() > 5, "kuva on tasavarinen - maasto tai valaistus ei toimi"
        assert blue > 30, (
            f"rakennusta ei nay ({blue} px). Staattiset meshit eivat paady kuvaan.")
        assert green > 200, (
            f"lehtia ei nay ({green} px). Geometry Nodes -instansointi tuottaa tyhjaa "
            "- juuri tama virhe ei anna virheilmoitusta vaan pelkan tyhjan metsan.")

        print(f"\nKAIKKI LAPI - {n_house} rakennus ja {n_trees} puuta renderoituivat")
        return 0
    finally:
        if args.keep:
            print(f"Sailytetty: {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
