#!/usr/bin/env python3
"""Kokoaa kaikki kartalla nakyvat objektit yhteen paikkaindeksoituun SQLite-kantaan.

Renderoija kysyy talta kannalta "anna kaikki mika osuu tiilelle X,Y" ja saa vastauksen
yhdella kyselylla. Ilman tata Blender joutuisi lataamaan koko saaren muistiin, mika ei
8 GB:n naytonohjaimella onnistu missaan tilanteessa.

Suurin yksittainen saasto on kokokarsinta: 0.37 m/px:lla alle metrin kokoinen propsi
jaa alle kolmen pikselin eika sita erota mistaan. Naita on miljoonia.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import DUMP, WORK, World, ensure_dirs  # noqa: E402

KIND_STATIC, KIND_FOLIAGE = 0, 1
IDENTITY_EPS = 1e-4


# ---------------------------------------------------------------- UE-rotaatiot

def rot_matrix(pitch: float, yaw: float, roll: float) -> np.ndarray:
    """UE:n rotaattori -> 3x3 matriisi. Jarjestys on yaw(Z) * pitch(Y) * roll(X)."""
    p, y, r = np.radians([pitch, yaw, roll])
    cp, sp, cy, sy, cr, sr = np.cos(p), np.sin(p), np.cos(y), np.sin(y), np.cos(r), np.sin(r)
    return np.array([
        [cp * cy, sr * sp * cy - cr * sy, cr * sp * cy + sr * sy],
        [cp * sy, sr * sp * sy + cr * cy, cr * sp * sy - sr * cy],
        [-sp,     sr * cp,                cr * cp],
    ], dtype=np.float64)


def matrix_to_rot(m: np.ndarray) -> tuple[float, float, float]:
    """3x3 -> UE-rotaattori (pitch, yaw, roll) asteina."""
    pitch = np.degrees(np.arctan2(-m[2, 0], np.hypot(m[0, 0], m[1, 0])))
    yaw = np.degrees(np.arctan2(m[1, 0], m[0, 0]))
    roll = np.degrees(np.arctan2(m[2, 1], m[2, 2]))
    return float(pitch), float(yaw), float(roll)


# ---------------------------------------------------------------- kanta

SCHEMA = """
CREATE TABLE meshes (
    id     INTEGER PRIMARY KEY,
    path   TEXT UNIQUE NOT NULL,
    radius REAL NOT NULL DEFAULT 0
);
CREATE TABLE actors (
    mesh_id INTEGER NOT NULL,
    kind    INTEGER NOT NULL,
    x REAL, y REAL, z REAL,
    pitch REAL, yaw REAL, roll REAL,
    sx REAL, sy REAL, sz REAL,
    radius REAL NOT NULL          -- maailmansateen arvio, karsintaa ja marginaalia varten
);
"""
INDEXES = """
CREATE INDEX actors_xy ON actors (x, y);
CREATE INDEX actors_kind ON actors (kind);
"""


class MeshTable:
    def __init__(self, con: sqlite3.Connection, bounds: dict):
        self.con, self.bounds, self.ids = con, bounds, {}

    def id_of(self, path: str) -> tuple[int, float]:
        if path not in self.ids:
            radius = float(self.bounds.get(path, {}).get("radius", 0.0))
            cur = self.con.execute(
                "INSERT INTO meshes (path, radius) VALUES (?, ?)", (path, radius))
            self.ids[path] = (cur.lastrowid, radius)
        return self.ids[path]


def load_statics(con, meshes: MeshTable, min_radius_uu: float) -> tuple[int, int]:
    rows, kept, dropped = [], 0, 0
    for path in sorted((DUMP / "actors").glob("*.json")):
        for a in json.loads(path.read_text()):
            mesh_id, base_r = meshes.id_of(a["Mesh"])
            scale = a["Scale"]
            radius = base_r * max(abs(s) for s in scale)
            if radius and radius < min_radius_uu:
                dropped += 1
                continue
            rows.append((mesh_id, KIND_STATIC, *a["Loc"], *a["Rot"], *scale, radius))
            kept += 1
        if len(rows) > 200_000:
            _flush(con, rows)
    _flush(con, rows)
    return kept, dropped


# Yli taman kokoinen "kasvi" on virheellista dataa, ei kasvillisuutta.
MAX_FOLIAGE_RADIUS_M = 50.0


def load_foliage(con, meshes: MeshTable, min_radius_uu: float,
                 max_radius_uu: float) -> tuple[int, int]:
    kept = dropped = 0
    for path in sorted((DUMP / "foliage").glob("*.json")):
        for group in json.loads(path.read_text()):
            mesh_id, base_r = meshes.id_of(group["Mesh"])
            data = np.fromfile(DUMP / "foliage" / group["File"], dtype="<f4")
            if data.size % 9:
                print(f"  VAROITUS: {group['File']} ei ole 9 floatin monikerta, ohitetaan")
                continue
            inst = data.reshape(-1, 9).astype(np.float64)

            loc = np.array(group["ComponentLoc"], dtype=np.float64)
            crot = np.array(group["ComponentRot"], dtype=np.float64)
            cscale = np.array(group["ComponentScale"], dtype=np.float64)

            identity = (np.abs(crot).max() < IDENTITY_EPS
                        and np.abs(cscale - 1.0).max() < IDENTITY_EPS)
            if identity:
                inst[:, 0:3] += loc
            else:
                m = rot_matrix(*crot)
                inst[:, 0:3] = (m @ (inst[:, 0:3] * cscale).T).T + loc
                for i in range(len(inst)):
                    inst[i, 3:6] = matrix_to_rot(m @ rot_matrix(*inst[i, 3:6]))
                inst[:, 6:9] *= cscale

            radii = base_r * np.abs(inst[:, 6:9]).max(axis=1)
            if base_r:
                mask = (radii >= min_radius_uu) & (radii <= max_radius_uu)
                dropped += int((~mask).sum())
                inst, radii = inst[mask], radii[mask]
            kept += len(inst)

            _flush(con, [(mesh_id, KIND_FOLIAGE, *row, r)
                         for row, r in zip(inst.tolist(), radii.tolist())])
    return kept, dropped


def _flush(con, rows: list) -> None:
    if not rows:
        return
    con.executemany(
        "INSERT INTO actors (mesh_id, kind, x, y, z, pitch, yaw, roll, sx, sy, sz, radius) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    con.commit()
    rows.clear()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-px", type=float, default=2.0,
                    help="pudota objektit jotka jaavat tata pienemmiksi lopullisessa kuvassa")
    ap.add_argument("--min-px-foliage", type=float, default=3.0,
                    help="kasvillisuuden oma kynnys. Heinat karsiutuvat, mutta pensaat "
                         "ja pienet puut jaavat - juuri ne tekevat metsasta metsan")
    ap.add_argument("--mesh-bounds", default=str(WORK / "mesh_bounds.json"))
    ap.add_argument("--db", default=str(WORK / "scene.sqlite"))
    args = ap.parse_args()

    world = World.load()
    min_radius_uu = args.min_px * world.uu_per_px / 2.0
    min_foliage_uu = args.min_px_foliage * world.uu_per_px / 2.0
    max_foliage_uu = MAX_FOLIAGE_RADIUS_M * world.uu_per_meter

    bounds_path = Path(args.mesh_bounds)
    bounds = json.loads(bounds_path.read_text()) if bounds_path.exists() else {}
    if not bounds:
        print(f"VAROITUS: {bounds_path} puuttuu - kokokarsinta ei toimi. "
              "Aja pipeline/03_render/build_library.py ensin.")

    ensure_dirs(WORK)
    db = Path(args.db)
    db.unlink(missing_ok=True)
    con = sqlite3.connect(db)
    con.executescript(SCHEMA)

    meshes = MeshTable(con, bounds)
    s_kept, s_drop = load_statics(con, meshes, min_radius_uu)
    print(f"Staattiset meshit: {s_kept} sailytetty, {s_drop} karsittu")
    f_kept, f_drop = load_foliage(con, meshes, min_foliage_uu, max_foliage_uu)
    print(f"Kasvillisuus:      {f_kept} sailytetty, {f_drop} karsittu")

    con.executescript(INDEXES)
    con.execute("ANALYZE")
    con.commit()
    con.close()
    print(f"Karsintaraja: meshit {min_radius_uu / world.uu_per_meter:.2f} m "
          f"({args.min_px} px), kasvillisuus {min_foliage_uu / world.uu_per_meter:.2f} m "
          f"({args.min_px_foliage} px)\nKirjoitettu {db}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
