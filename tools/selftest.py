#!/usr/bin/env python3
"""Ajaa koko Python-putken synteettisella maailmalla ilman pelidataa.

Tarkoitus ei ole testata Blenderia vaan varmistaa se osa joka menee hiljaa rikki:
landscape-atlaksen kokoaminen. Jos alilohkojen monistetut reunavertexit kasitellaan
vaarin, korkeuskartta nayttaa silti jarkevalta mutta on muutaman metrin sivussa -
eika sita huomaa ennen kuin koko kartta on renderoity.

Tassa tiedetaan tarkalleen mika korkeuden pitaa olla, joten virhe nakyy heti.

    python3 tools/selftest.py
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "pipeline"))

SSQ = 31          # SubsectionSizeQuads
NSUB = 2          # NumSubsections
CSQ = SSQ * NSUB  # ComponentSizeQuads
TEX = (SSQ + 1) * NSUB
GRID = 4          # komponenttia per akseli
SCALE = 100.0


def truth(vx: np.ndarray, vy: np.ndarray) -> np.ndarray:
    """Tunnettu korkeusfunktio 16-bittisena. Talle kaikkea verrataan."""
    n = GRID * CSQ
    a = np.sin(vx / n * 6.0) * np.cos(vy / n * 4.0)
    b = (vx + vy) / (2.0 * n)
    return (32768 + (a * 9000 + b * 6000)).astype(np.uint16)


ORDERS = {"PF_R8G8B8A8": [0, 1, 2, 3], "PF_B8G8R8A8": [2, 1, 0, 3]}


def write_tex(dst: Path, name: str, rgba: np.ndarray, pixfmt: str) -> None:
    """Kirjoita tekstuuri purun omassa muodossa: raakana + formaatti metadataan."""
    rgba[:, :, ORDERS[pixfmt]].astype(np.uint8).tofile(dst / f"{name}.raw")
    (dst / f"{name}.json").write_text(json.dumps(
        {"Width": rgba.shape[1], "Height": rgba.shape[0],
         "PixelFormat": pixfmt, "Source": name}))


def build_dump(root: Path, pixfmt: str = "PF_B8G8R8A8") -> np.ndarray:
    for sub in ("textures", "actors", "foliage", "landscape"):
        (root / sub).mkdir(parents=True, exist_ok=True)

    verts = GRID * CSQ + 1
    gy, gx = np.mgrid[0:verts, 0:verts]
    expected = truth(gx, gy)

    comps = []
    for cy in range(GRID):
        for cx in range(GRID):
            name = f"HM_{cx}_{cy}"
            tex = np.zeros((TEX, TEX, 4), dtype=np.uint8)
            wt = np.zeros((TEX, TEX, 4), dtype=np.uint8)

            # Alilohkot monistavat jaetun reunarivin - juuri kuten UE tekee.
            for sy in range(NSUB):
                for sx in range(NSUB):
                    vy0 = cy * CSQ + sy * SSQ
                    vx0 = cx * CSQ + sx * SSQ
                    iy, ix = np.mgrid[vy0:vy0 + SSQ + 1, vx0:vx0 + SSQ + 1]
                    iy = np.clip(iy, 0, verts - 1)
                    ix = np.clip(ix, 0, verts - 1)
                    h = truth(ix, iy)

                    ty0, tx0 = sy * (SSQ + 1), sx * (SSQ + 1)
                    sl = (slice(ty0, ty0 + SSQ + 1), slice(tx0, tx0 + SSQ + 1))
                    tex[sl][..., 0] = (h >> 8).astype(np.uint8)
                    tex[sl][..., 1] = (h & 0xFF).astype(np.uint8)
                    # Kaksi layeria: R = matalat alueet, G = korkeat.
                    wt[sl][..., 0] = np.clip(255 - (h.astype(np.int32) - 24000) // 40, 0, 255)
                    wt[sl][..., 1] = 255 - wt[sl][..., 0]

            write_tex(root / "textures", name, tex, pixfmt)
            write_tex(root / "textures", name + "_W", wt, pixfmt)
            comps.append({
                "Level": "Test", "SectionBaseX": cx * CSQ, "SectionBaseY": cy * CSQ,
                "ComponentSizeQuads": CSQ, "SubsectionSizeQuads": SSQ, "NumSubsections": NSUB,
                "Heightmap": name, "HeightmapScaleBias": [1 / TEX, 1 / TEX, 0.0, 0.0],
                "WeightmapTextures": [name + "_W"],
                "WeightmapScaleBias": [1 / TEX, 1 / TEX, 0.0, 0.0],
                "Layers": [{"Name": "Lowland", "TextureIndex": 0, "Channel": 0},
                           {"Name": "Highland", "TextureIndex": 0, "Channel": 1}],
            })

    (root / "landscape" / "components.json").write_text(json.dumps(comps))
    (root / "landscape" / "actors.json").write_text(json.dumps([
        {"Level": "Test", "Name": "Landscape", "Loc": [0.0, 0.0, 0.0],
         "Scale": [SCALE, SCALE, SCALE]}]))

    # Objekteja: yksi staattinen mesh ja yksi kasvillisuusryhma.
    extent = GRID * CSQ * SCALE
    (root / "actors" / "Test.json").write_text(json.dumps([
        {"Mesh": "/Game/Test/SM_House.SM_House",
         "Loc": [extent * 0.5, extent * 0.5, 0.0], "Rot": [0, 45, 0],
         "Scale": [1, 1, 1]}]))

    rng = np.random.default_rng(7)
    n = 5000
    inst = np.zeros((n, 9), dtype="<f4")
    inst[:, 0] = rng.uniform(0, extent, n)
    inst[:, 1] = rng.uniform(0, extent, n)
    inst[:, 4] = rng.uniform(0, 360, n)
    inst[:, 6:9] = rng.uniform(0.8, 1.3, (n, 1))
    inst.tofile(root / "foliage" / "Test_0.f32")
    (root / "foliage" / "Test.json").write_text(json.dumps([
        {"Mesh": "/Game/Test/SM_Tree.SM_Tree", "Count": n, "File": "Test_0.f32",
         "ComponentLoc": [0, 0, 0], "ComponentRot": [0, 0, 0],
         "ComponentScale": [1, 1, 1]}]))

    # Landscape-materiaali ja sen varitekstuurit, jotta guess_layers.py:n
    # nimiperusteinen yhdistaminen ja raaka->PNG-muunnos tulevat testatuiksi.
    land = root.parent / "assets" / "landscape"
    land.mkdir(parents=True, exist_ok=True)
    for tex_name, tint in (("T_Lowland_D", 60), ("T_Highland_D", 180)):
        px = np.full((8, 8, 4), tint, dtype=np.uint8)
        px[..., 3] = 255
        write_tex(land, tex_name, px, pixfmt)
    (root / "landscape" / "material.json").write_text(json.dumps({
        "Material": "/Game/Test/M_Landscape.M_Landscape",
        "Textures": [
            {"Parameter": "Lowland Diffuse", "Texture": "/Game/T_Lowland_D", "File": "T_Lowland_D"},
            {"Parameter": "Highland Diffuse", "Texture": "/Game/T_Highland_D", "File": "T_Highland_D"},
            {"Parameter": "Lowland Normal", "Texture": "/Game/T_Lowland_N", "File": "T_Lowland_N"},
        ],
        "Scalars": [{"Parameter": "Lowland Tiling", "Value": 6.0}],
    }))

    return expected


def run(script: str, *args, env: dict) -> None:
    cmd = [sys.executable, str(REPO / script), *args]
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode:
        print(r.stdout, r.stderr)
        raise SystemExit(f"{script} epaonnistui")
    print(f"  {script}\n" + "".join(f"    {l}\n" for l in r.stdout.strip().splitlines()))


def main() -> int:
    import os

    tmp = Path(tempfile.mkdtemp(prefix="scum_selftest_"))
    dump, work, out = tmp / "dump", tmp / "work", tmp / "out"
    conf = tmp / "config"
    conf.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "SCUM_DUMP": str(dump), "SCUM_WORK": str(work),
           "SCUM_OUT": str(out), "SCUM_CONFIG": str(conf)}
    cfg = conf / "world.json"

    try:
        print(f"Synteettinen maailma {tmp}")
        expected = build_dump(dump)

        run("pipeline/01_landscape/heightmap.py", "--output-px", "1024",
            "--tile-grid", "4", env=env)

        got = np.load(work / "heightmap.npy")
        assert got.shape == expected.shape, f"{got.shape} != {expected.shape}"
        diff = np.abs(got.astype(np.int64) - expected.astype(np.int64))
        print(f"  korkeusero: max {diff.max()}, keskiarvo {diff.mean():.4f}")
        assert diff.max() == 0, "atlaksen kokoaminen on pielessa"

        # Sama toisella kanavajarjestyksella. Jos purku antaa RGBA:ta eika BGRA:ta,
        # korkeuden on tultava silti bittitarkasti samaksi - muuten koko maasto
        # olisi hiljaa vaarin.
        alt = tmp / "alt"
        alt_expected = build_dump(alt / "dump", "PF_R8G8B8A8")
        alt_env = {**env, "SCUM_DUMP": str(alt / "dump"),
                   "SCUM_WORK": str(alt / "work"), "SCUM_CONFIG": str(alt / "config")}
        (alt / "config").mkdir(parents=True, exist_ok=True)
        run("pipeline/01_landscape/heightmap.py", "--output-px", "1024",
            "--tile-grid", "4", env=alt_env)
        alt_got = np.load(alt / "work" / "heightmap.npy")
        assert np.array_equal(alt_got, alt_expected), "RGBA-jarjestys tulkitaan vaarin"
        print("  molemmat kanavajarjestykset (BGRA/RGBA) rekonstruoituvat bittitarkasti")

        run("pipeline/01_landscape/weightmaps.py", env=env)

        land_dir = dump.parent / "assets" / "landscape"
        run("pipeline/01_landscape/guess_layers.py", "--texture-dir", str(land_dir),
            "--out", str(conf / "layers.json"), "--force", env=env)
        layers_cfg = json.loads((conf / "layers.json").read_text())
        assert "Lowland" in layers_cfg and "Highland" in layers_cfg, layers_cfg
        assert layers_cfg["Lowland"]["texture"].endswith("T_Lowland_D.png"), layers_cfg["Lowland"]
        assert layers_cfg["Lowland"]["tiling_m"] == 6.0, layers_cfg["Lowland"]
        assert (land_dir / "T_Lowland_D.png").exists(), "raaka -> PNG muunnos puuttuu"
        print("  layer-tekstuurit yhdistetty nimien perusteella, tiilitys materiaalista")

        run("pipeline/01_landscape/ground_albedo.py", "--hillshade", "0.4", env=env)

        tiles = sorted((work / "ground").glob("*.png"))
        assert len(tiles) == 16, f"odotettiin 16 tiilta, saatiin {len(tiles)}"
        from PIL import Image
        px = np.asarray(Image.open(tiles[0]))
        assert px.shape == (256, 256, 3), px.shape
        assert px.std() > 3, "albedotiili on tasavarinen - blendaus ei toimi"
        print(f"  {len(tiles)} albedotiilta, {px.shape[0]}px, hajonta {px.std():.1f}")

        bounds = {"/Game/Test/SM_House.SM_House": {"object": "House", "radius": 800.0},
                  "/Game/Test/SM_Tree.SM_Tree": {"object": "Tree", "radius": 400.0}}
        (work / "mesh_bounds.json").write_text(json.dumps(bounds))
        run("pipeline/02_scene/actor_db.py", env=env)

        import sqlite3
        con = sqlite3.connect(work / "scene.sqlite")
        n_static, n_foliage = (con.execute(
            "SELECT COUNT(*) FROM actors WHERE kind=?", (k,)).fetchone()[0]
            for k in (0, 1))
        con.close()
        assert (n_static, n_foliage) == (1, 5000), (n_static, n_foliage)
        print(f"  kanta: {n_static} staattinen, {n_foliage} kasvi-instanssia")

        # Regressio: absurdi tiilitys kaatoi ajon 57 GB:n muistinvaraukseen.
        sys.path.insert(0, str(REPO / "pipeline" / "01_landscape"))
        import ground_albedo as ga
        huge = ga.load_layer_texture({"tiling_m": 33327.0, "_name": "Absurd"}, 0.465)
        assert huge.nbytes < 1_000_000, f"absurdi tiilitys varaa {huge.nbytes} tavua"
        assert ga.clamp_tiling(-5, "x") == 4.0 and ga.clamp_tiling("roska", "x") == 4.0
        assert ga.clamp_tiling(6.0, "x") == 6.0
        print("  absurdi tiilitys rajataan, ei muistiraketti")

        # Tiilipyramidi PIL-reitilla (ilman libvipsia) suoraan "renderoiduista" tiilista.
        render_dir = out / "tiles"
        render_dir.mkdir(parents=True, exist_ok=True)
        for t in tiles:
            shutil.copy(t, render_dir / t.name.replace("ground_", "tile_"))
        run("pipeline/04_output/make_tiles.py", "--backend", "pil", env=env)

        web = out / "web"
        meta = json.loads((web / "map.json").read_text())
        assert meta["maxZoom"] == 2, meta["maxZoom"]
        for z, n in ((2, 4), (1, 2), (0, 1)):
            got = len(list((web / "tiles" / str(z)).glob("*/*.jpg")))
            assert got == n * n, f"z{z}: {got} != {n * n}"
        top = np.asarray(Image.open(web / "tiles" / "0" / "0" / "0.jpg"))
        assert top.shape == (256, 256, 3), top.shape
        assert (web / "index.html").exists(), "katselin ei kopioitunut"
        print(f"  tiilipyramidi: maxZoom {meta['maxZoom']}, tasot 0-2 taydet")

        # Orkestroijan kuiva-ajo: kaikki vaiheet ja skriptit ovat olemassa.
        r = subprocess.run(
            [sys.executable, str(REPO / "tools" / "run_pipeline.py"), "--check", "--yes"],
            capture_output=True, text=True, env=env)
        assert r.returncode == 0, r.stdout + r.stderr
        for stage in ("extract", "landscape", "ground", "render", "web"):
            assert f"[{stage}]" in r.stdout, f"vaihe {stage} puuttuu kuiva-ajosta"
        print("  orkestroijan kuiva-ajo lapi")

        # Koordinaattimuunnoksen edestakaisuus.
        from common import World
        w = World.load(cfg)
        for uu in [(0, 0), (12345, -6789), (w.size_uu[0], w.size_uu[1])]:
            back = w.px_to_uu(*w.uu_to_px(*uu))
            assert max(abs(a - b) for a, b in zip(uu, back)) < 1e-6, (uu, back)
        print("  UU<->px muunnos edestakaisin tarkka")

        print("\nKAIKKI LAPI")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
