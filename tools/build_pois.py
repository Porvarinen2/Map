#!/usr/bin/env python3
"""Builds world/poi_data.lua from the hand-marked SCUM map.

tools/poi_source.json holds every marker found on the 25 sector screenshots of
the community SCUM map (one screenshot per sector, D4 top-left to Z0
bottom-right): villages, hunting towers, bunkers, abandoned bunkers, research
facilities, outposts and named points of interest. Each screenshot was
registered against livemap/map/scum_map.png and sits on its sector to within
one base-map pixel, so a marker's pixel position maps straight to world
coordinates through the same calibration the mod and the live map use.

Pins are anchored at their tip; rings at their centre.
"""
import json
import math, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MOD = os.path.join(ROOT, "package", "mod", "TeslesNPCOverhaul")
NAV = os.path.join(MOD, "world", "navgrid_data.lua")
OUT = os.path.join(MOD, "world", "poi_data.lua")
MAP_OUT = os.path.join(ROOT, "package", "livemap", "pois.js")
SWEEP_OUT = os.path.join(MOD, "world", "c0_sweep.lua")
# Krsko's five sweep areas, traced from the pink areas on the C0 sector
# screenshots (tools/c0_areas.json, polygon corners as fractions of the sector).
SWEEP_SECTOR = "C0"
SWEEP_SPACING = 12000     # 120 m between sweep lanes and between stops

ROWS, COLS = "DCBAZ", "43210"

# kind -> (radius UU, selection weight, label)
KIND = {
    "CITY":             (28000, 1.35, "City"),
    "VILLAGE":          (9000,  1.00, "Village"),
    "HUNTING":          (2500,  0.90, "Hunting Tower"),
    "MILITARY":         (16000, 1.25, "Military"),
    "BUNKER":           (5000,  1.30, "Bunker"),
    "ABANDONED_BUNKER": (5000,  1.30, "Abandoned Bunker"),
    "RESEARCH":         (6000,  1.30, "Research Facility"),
    "INDUSTRIAL":       (10000, 1.00, "Industrial"),
    "MEDICAL":          (9000,  1.10, "Medical"),
    "LANDMARK":         (5000,  0.70, "Landmark"),
    "OUTPOST":          (30000, 0.00, "Outpost"),
}


def calibration():
    text = open(NAV).read()
    vals = {}
    for key in ("xWest", "xEast", "yNorth", "ySouth"):
        vals[key] = float(re.search(key + r"=([-0-9.]+)", text).group(1))
    return vals


def to_world(cal, sector, fu, fv):
    ri, ci = ROWS.index(sector[0]), COLS.index(sector[1])
    u = (ci + fu) / 5.0
    v = (ri + fv) / 5.0
    return (cal["xWest"] - u * (cal["xWest"] - cal["xEast"]),
            cal["yNorth"] - v * (cal["yNorth"] - cal["ySouth"]))


def inside(poly, x, y):
    c = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            c = not c
        j = i
    return c


def sweep_points(poly):
    """Lawn-mower stops across a polygon: lanes along its long axis, walked
    alternately, so a squad covers the area block by block."""
    xs = [p[0] for p in poly]
    ys = [p[1] for p in poly]
    cx, cy = sum(xs) / len(xs), sum(ys) / len(ys)
    sxx = sum((x - cx) ** 2 for x in xs)
    syy = sum((y - cy) ** 2 for y in ys)
    sxy = sum((x - cx) * (y - cy) for x, y in poly)
    ang = 0.5 * math.atan2(2 * sxy, sxx - syy)
    ax, ay = math.cos(ang), math.sin(ang)      # long axis
    bx, by = -ay, ax                           # lane spacing axis
    along = [(x - cx) * ax + (y - cy) * ay for x, y in poly]
    across = [(x - cx) * bx + (y - cy) * by for x, y in poly]
    lanes = []
    b = min(across) + SWEEP_SPACING / 2
    while b < max(across):
        lane = []
        a = min(along) + SWEEP_SPACING / 2
        while a < max(along):
            x, y = cx + a * ax + b * bx, cy + a * ay + b * by
            if inside(poly, x, y):
                lane.append((x, y))
            a += SWEEP_SPACING
        if lane:
            lanes.append(lane)
        b += SWEEP_SPACING
    pts = []
    for i, lane in enumerate(lanes):
        pts.extend(lane if i % 2 == 0 else list(reversed(lane)))
    if not pts:
        pts = [(cx, cy)]
    return pts


def build_sweep(cal):
    src = json.load(open(os.path.join(HERE, "c0_areas.json")))
    areas = []
    for a in src:
        poly = [to_world(cal, SWEEP_SECTOR, u, v) for u, v in a["poly"]]
        areas.append({"id": a["area"], "poly": poly, "points": sweep_points(poly)})
    with open(SWEEP_OUT, "w") as f:
        f.write("-- TESLES NPC OVERHAUL - Krsko sweep areas (generated)\n")
        f.write("-- Built by tools/build_pois.py from tools/c0_areas.json. Radiation\n")
        f.write("-- squads sweep these areas in order, 1-5 or 5-1. Do not hand edit.\n")
        f.write("return {\n  city = \"CIT_C0_01\",\n  areas = {\n")
        for a in areas:
            f.write("    { id = %d,\n      poly = { %s },\n      points = { %s } },\n" % (
                a["id"],
                ", ".join("{%d,%d}" % (round(x), round(y)) for x, y in a["poly"]),
                ", ".join("{%d,%d}" % (round(x), round(y)) for x, y in a["points"])))
        f.write("  },\n}\n")
    print("wrote %d sweep areas (%s stops) to %s" % (
        len(areas), "+".join(str(len(a["points"])) for a in areas), SWEEP_OUT))
    return areas


def main():
    cal = calibration()
    span_x = cal["xWest"] - cal["xEast"]
    span_y = cal["yNorth"] - cal["ySouth"]
    src = json.load(open(os.path.join(HERE, "poi_source.json")))
    counters = {}
    points = []
    for o in src:
        ri, ci = ROWS.index(o["sector"][0]), COLS.index(o["sector"][1])
        u = (ci + o["px"] / o["W"]) / 5.0
        v = (ri + o["py"] / o["H"]) / 5.0
        x = cal["xWest"] - u * span_x
        y = cal["yNorth"] - v * span_y
        kind = o["kind"]
        radius, weight, label = KIND[kind]
        key = (o["sector"], kind)
        counters[key] = counters.get(key, 0) + 1
        n = counters[key]
        name = o.get("name") or ("%s %s %d" % (o["sector"], label, n) if kind in ("VILLAGE", "HUNTING")
                                 else "%s %s" % (o["sector"], label) if n == 1
                                 else "%s %s %d" % (o["sector"], label, n))
        pid = "%s_%s_%02d" % (kind[:3], o["sector"], n)
        points.append((pid, name, o["sector"], kind, x, y, weight, radius))

    with open(OUT, "w") as f:
        f.write("-- TESLES NPC OVERHAUL - points of interest (generated)\n")
        f.write("-- Built by tools/build_pois.py from tools/poi_source.json: the\n")
        f.write("-- hand-marked community SCUM map, one screenshot per sector.\n")
        f.write("-- Do not hand edit; regenerate instead.\n")
        f.write("return {\n  points={\n")
        for pid, name, sec, kind, x, y, w, r in points:
            f.write('    {id="%s",label="%s",sector="%s",kind="%s",x=%d,y=%d,weight=%.2f,radius=%d},\n'
                    % (pid, name.replace('"', "'"), sec, kind, round(x), round(y), w, r))
        f.write("  },\n}\n")
    areas = build_sweep(cal)
    # The live map draws the same places as its POI layer.
    rows = [{"id": pid, "n": name, "k": kind, "x": round(x), "y": round(y)}
            for pid, name, sec, kind, x, y, w, r in points]
    with open(MAP_OUT, "w") as f:
        f.write("// Generated by tools/build_pois.py - do not hand edit.\n")
        f.write("window.TESLES_POIS=" + json.dumps(rows, separators=(",", ":")) + ";\n")
        zones = {"radiation": {"sector": SWEEP_SECTOR},
                 "sweep": [{"id": a["id"], "poly": [[round(x), round(y)] for x, y in a["poly"]]}
                           for a in areas]}
        f.write("window.TESLES_ZONES=" + json.dumps(zones, separators=(",", ":")) + ";\n")
    print("wrote %d points to %s" % (len(points), OUT))


if __name__ == "__main__":
    main()
