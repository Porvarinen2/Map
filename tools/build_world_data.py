#!/usr/bin/env python3
"""Builds the TESLES NPC Overhaul world navigation data from the SCUM map image.

Outputs (Lua source files consumed by the mod at runtime):
  world/navgrid_data.lua  - 512x512 terrain grid: 0=water 1=land 2=road
  world/roadnet_data.lua  - road network graph: nodes + edges (polylines)
  world/poi_data.lua      - points of interest derived from settlements + hand data

Coordinates use the SCUM world calibration shared with the live map:
  u = (xWest - x) / (xWest - xEast)      -> image column fraction
  v = (yNorth - y) / (yNorth - ySouth)   -> image row fraction
"""

import json
import math
import os
import sys
from collections import defaultdict, deque

import numpy as np
from PIL import Image
from skimage.morphology import skeletonize, remove_small_objects

Image.MAX_IMAGE_PIXELS = None

CAL = dict(xWest=619646.8573, xEast=-905369.0266,
           yNorth=619659.7258, ySouth=-904357.5270)

GRID = 512          # nav grid resolution
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
BUILD = os.path.join(ROOT, "build")
PKG = os.path.join(ROOT, "package")
# The live map ships the same image the nav data is derived from, so the
# generator reads it straight out of the package instead of a build folder.
SOURCE = os.path.join(PKG, "livemap", "map", "scum_map.png")
OUT = os.path.join(PKG, "mod", "TeslesNPCOverhaul", "world")


def uv_to_world(u, v):
    x = CAL["xWest"] - u * (CAL["xWest"] - CAL["xEast"])
    y = CAL["yNorth"] - v * (CAL["yNorth"] - CAL["ySouth"])
    return x, y


def world_to_uv(x, y):
    u = (CAL["xWest"] - x) / (CAL["xWest"] - CAL["xEast"])
    v = (CAL["yNorth"] - y) / (CAL["yNorth"] - CAL["ySouth"])
    return u, v


# ---------------------------------------------------------------- classify ---

def classify(path):
    im = Image.open(path).convert("RGB")
    a = np.asarray(im).astype(np.int16)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx = a.max(axis=2)

    water = (b >= r) & (b >= g - 2) & (mx < 58) & ((b - r) >= 4)
    yellow = (r > 150) & (g > 120) & (b < 110) & ((r - b) > 60)
    white = (r > 195) & (g > 195) & (b > 190)
    road = yellow | white
    # Map attribution text in the bottom-left corner is bright; drop that patch.
    h, w = road.shape
    road[int(h * 0.975):, :int(w * 0.14)] = False
    white[int(h * 0.975):, :int(w * 0.14)] = False
    return water, road, yellow, white, a.shape[1], a.shape[0]


# --------------------------------------------------------------- nav grid ---

def build_navgrid(water, road, w, h):
    """Downsample the pixel masks to a GRID x GRID terrain classification."""
    bs_x, bs_y = w // GRID, h // GRID
    wat = water.reshape(GRID, bs_y, GRID, bs_x).mean(axis=(1, 3))
    rd = road.reshape(GRID, bs_y, GRID, bs_x).mean(axis=(1, 3))

    grid = np.ones((GRID, GRID), dtype=np.uint8)          # default land
    grid[wat > 0.55] = 0                                   # water
    # A road tile beats water: bridges and causeways must stay traversable.
    grid[rd > 0.02] = 2
    return grid


def flood_keep_main_landmasses(grid, min_cells=40):
    """Drop land specks that no NPC could ever reach and cannot be routed on."""
    passable = grid > 0
    labels = np.zeros_like(grid, dtype=np.int32)
    cur = 0
    sizes = {}
    for sy in range(GRID):
        for sx in range(GRID):
            if not passable[sy, sx] or labels[sy, sx]:
                continue
            cur += 1
            q = deque([(sy, sx)])
            labels[sy, sx] = cur
            n = 0
            while q:
                y, x = q.popleft()
                n += 1
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < GRID and 0 <= nx < GRID and passable[ny, nx] \
                            and not labels[ny, nx]:
                        labels[ny, nx] = cur
                        q.append((ny, nx))
            sizes[cur] = n
    for lab, n in sizes.items():
        if n < min_cells:
            grid[labels == lab] = 0
    return grid, labels, sizes


# ------------------------------------------------------------- road graph ---

def trace_road_graph(road_mask, w, h, scale):
    """Skeletonise the road mask and trace it into a node/edge graph."""
    small = np.asarray(Image.fromarray((road_mask * 255).astype(np.uint8))
                       .resize((w // scale, h // scale), Image.BILINEAR)) > 60
    small = remove_small_objects(small, 24)
    skel = skeletonize(small)

    H, W = skel.shape
    nb = np.zeros_like(skel, dtype=np.uint8)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            nb[max(0, -dy):H - max(0, dy), max(0, -dx):W - max(0, dx)] += \
                skel[max(0, dy):H + min(0, dy), max(0, dx):W + min(0, dx)]
    nb = nb * skel

    is_node = skel & ((nb != 2) | (nb == 0))     # endpoints and junctions
    nodes = {}
    for y, x in zip(*np.nonzero(is_node)):
        nodes[(int(y), int(x))] = len(nodes)

    visited_edge = set()
    edges = []

    def neighbours(y, x):
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == 0 and dx == 0:
                    continue
                ny, nx = y + dy, x + dx
                if 0 <= ny < H and 0 <= nx < W and skel[ny, nx]:
                    yield ny, nx

    for (ny, nx) in list(nodes.keys()):
        for sy, sx in neighbours(ny, nx):
            if ((ny, nx), (sy, sx)) in visited_edge:
                continue
            path = [(ny, nx)]
            py, px = ny, nx
            cy, cx = sy, sx
            guard = 0
            while True:
                guard += 1
                path.append((cy, cx))
                visited_edge.add(((py, px), (cy, cx)))
                visited_edge.add(((cy, cx), (py, px)))
                if (cy, cx) in nodes or guard > 20000:
                    break
                nxt = [p for p in neighbours(cy, cx) if p != (py, px)]
                if not nxt:
                    break
                py, px = cy, cx
                cy, cx = nxt[0]
            if (cy, cx) in nodes and (cy, cx) != (ny, nx) and len(path) > 1:
                edges.append((nodes[(ny, nx)], nodes[(cy, cx)], path))

    return nodes, edges, skel, W, H


def rdp(points, eps):
    """Ramer-Douglas-Peucker polyline simplification."""
    if len(points) < 3:
        return list(points)
    a, b = points[0], points[-1]
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    den = math.hypot(dx, dy)
    worst, wi = -1.0, 0
    for i in range(1, len(points) - 1):
        px, py = points[i]
        if den < 1e-9:
            d = math.hypot(px - ax, py - ay)
        else:
            d = abs(dy * px - dx * py + bx * ay - by * ax) / den
        if d > worst:
            worst, wi = d, i
    if worst > eps:
        left = rdp(points[:wi + 1], eps)
        right = rdp(points[wi:], eps)
        return left[:-1] + right
    return [a, b]



def stitch_components(nodes_xy, edges_out, grid, max_gap=26000.0):
    """Skeletonisation breaks roads at junctions and map seams. Reconnect
    component pairs whose endpoints are close and separated only by land."""
    n = len(nodes_xy)
    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb
            return True
        return False

    for a, b, _, _ in edges_out:
        union(a, b)

    # Bucket nodes into coarse spatial cells for a cheap neighbour search.
    cell = max_gap
    buckets = defaultdict(list)
    for i, (x, y) in enumerate(nodes_xy):
        buckets[(int(x // cell), int(y // cell))].append(i)

    added = 0
    # Several passes: merging two fragments often puts a third within reach.
    for _ in range(6):
        pass_added = 0
        order = sorted(range(n), key=lambda i: nodes_xy[i])
        for i in order:
            x, y = nodes_xy[i]
            bx, by = int(x // cell), int(y // cell)
            cands = []
            for ox in (-1, 0, 1):
                for oy in (-1, 0, 1):
                    for j in buckets.get((bx + ox, by + oy), ()):
                        if j == i or find(i) == find(j):
                            continue
                        d = math.dist(nodes_xy[i], nodes_xy[j])
                        if d <= max_gap:
                            cands.append((d, j))
            cands.sort()
            for d, j in cands[:4]:
                if find(i) == find(j):
                    continue
                if segment_is_dry(nodes_xy[i], nodes_xy[j], grid):
                    union(i, j)
                    edges_out.append((i, j, d, []))
                    pass_added += 1
                    break
        added += pass_added
        if pass_added == 0:
            break
    return edges_out, added


def segment_is_dry(a, b, grid):
    """True when every nav cell along the straight segment is passable."""
    steps = max(2, int(math.dist(a, b) / 1200))
    for s in range(steps + 1):
        t = s / steps
        x = a[0] + (b[0] - a[0]) * t
        y = a[1] + (b[1] - a[1]) * t
        u, v = world_to_uv(x, y)
        gx, gy = int(u * GRID), int(v * GRID)
        if not (0 <= gx < GRID and 0 <= gy < GRID) or grid[gy, gx] == 0:
            return False
    return True


# -------------------------------------------------------------------- POIs ---

def settlement_clusters(white_mask, w, h, grid):
    """Towns show up as dense clusters of white street pixels."""
    cell = 32
    gw, gh = w // cell, h // cell
    dens = white_mask.reshape(gh, cell, gw, cell).mean(axis=(1, 3))
    hot = dens > 0.018
    hot = remove_small_objects(hot, 1)

    labels = np.zeros_like(hot, dtype=np.int32)
    cur = 0
    clusters = []
    for sy in range(gh):
        for sx in range(gw):
            if not hot[sy, sx] or labels[sy, sx]:
                continue
            cur += 1
            q = deque([(sy, sx)])
            labels[sy, sx] = cur
            cells = []
            while q:
                y, x = q.popleft()
                cells.append((y, x))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < gh and 0 <= nx < gw and hot[ny, nx] \
                                and not labels[ny, nx]:
                            labels[ny, nx] = cur
                            q.append((ny, nx))
            if len(cells) < 1:
                continue
            cy = sum(c[0] for c in cells) / len(cells)
            cx = sum(c[1] for c in cells) / len(cells)
            u = (cx + 0.5) * cell / w
            v = (cy + 0.5) * cell / h
            gx, gy = int(u * GRID), int(v * GRID)
            if 0 <= gx < GRID and 0 <= gy < GRID and grid[gy, gx] == 0:
                continue
            x_w, y_w = uv_to_world(u, v)
            clusters.append(dict(u=u, v=v, x=x_w, y=y_w, cells=len(cells)))
    clusters.sort(key=lambda c: -c["cells"])
    return clusters



def wilderness_points(grid, want=60):
    """Land far from every road: hunting grounds and off-grid camps."""
    road = (grid == 2)
    INF = 10 ** 6
    dist = np.full(grid.shape, INF, dtype=np.int32)
    q = deque()
    for y, x in zip(*np.nonzero(road)):
        dist[y, x] = 0
        q.append((int(y), int(x)))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < GRID and 0 <= nx < GRID and dist[ny, nx] == INF \
                    and grid[ny, nx] != 0:
                dist[ny, nx] = dist[y, x] + 1
                q.append((ny, nx))
    cand = [(int(dist[y, x]), int(y), int(x))
            for y, x in zip(*np.nonzero((grid == 1) & (dist >= 6) & (dist < INF)))]
    cand.sort(reverse=True)
    picked = []
    for d, y, x in cand:
        if len(picked) >= want:
            break
        if all(abs(y - py) + abs(x - px) > 22 for _, py, px in picked):
            picked.append((d, y, x))
    return [(uv_to_world((x + 0.5) / GRID, (y + 0.5) / GRID), d) for d, y, x in picked]


def coastal_points(grid, want=40):
    """Land cells touching water but reachable from a road: shore camps."""
    out = []
    for y in range(1, GRID - 1):
        for x in range(1, GRID - 1):
            if grid[y, x] != 1:
                continue
            touches_water = any(grid[y + dy, x + dx] == 0
                                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)))
            if not touches_water:
                continue
            near_road = False
            for dy in range(-5, 6):
                for dx in range(-5, 6):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < GRID and 0 <= xx < GRID and grid[yy, xx] == 2:
                        near_road = True
                        break
                if near_road:
                    break
            if near_road:
                out.append((y, x))
    picked = []
    for y, x in out:
        if len(picked) >= want:
            break
        if all(abs(y - py) + abs(x - px) > 26 for py, px in picked):
            picked.append((y, x))
    return [uv_to_world((x + 0.5) / GRID, (y + 0.5) / GRID) for y, x in picked]


def junction_points(nodes_xy, degrees, want=45):
    """Major road junctions make natural patrol and ambush waypoints."""
    cand = sorted(((d, i) for i, d in degrees.items() if d >= 3), reverse=True)
    picked = []
    for d, i in cand:
        if len(picked) >= want:
            break
        x, y = nodes_xy[i]
        if all(math.dist((x, y), p) > 42000 for p in picked):
            picked.append((x, y))
    return picked


ROWS = ["D", "C", "B", "A", "Z"]
COLS = ["4", "3", "2", "1", "0"]


def sector_of(x, y):
    u, v = world_to_uv(x, y)
    if not (0 <= u < 1 and 0 <= v < 1):
        return "OUT"
    return ROWS[int(v * 5)] + COLS[int(u * 5)]


# ------------------------------------------------------------------ output ---

def lua_header(name):
    return ("-- TESLES NPC OVERHAUL - generated world data (%s)\n"
            "-- Built by tools/build_world_data.py from the SCUM map image.\n"
            "-- Do not hand edit; regenerate instead.\n" % name)


def write_navgrid(grid):
    rows = ["".join(str(int(v)) for v in grid[y]) for y in range(GRID)]
    with open(os.path.join(OUT, "navgrid_data.lua"), "w") as f:
        f.write(lua_header("navgrid"))
        f.write("return {\n")
        f.write("  size=%d,\n" % GRID)
        f.write("  xWest=%.4f, xEast=%.4f, yNorth=%.4f, ySouth=%.4f,\n" %
                (CAL["xWest"], CAL["xEast"], CAL["yNorth"], CAL["ySouth"]))
        f.write("  WATER=0, LAND=1, ROAD=2,\n")
        f.write("  rows={\n")
        for r in rows:
            f.write('    "%s",\n' % r)
        f.write("  },\n}\n")


def write_roadnet(nodes_xy, edges_out):
    with open(os.path.join(OUT, "roadnet_data.lua"), "w") as f:
        f.write(lua_header("roadnet"))
        f.write("return {\n  nodes={\n")
        for i, (x, y) in enumerate(nodes_xy):
            f.write("    {%d,%d},\n" % (round(x), round(y)))
        f.write("  },\n  edges={\n")
        for a, b, length, pts in edges_out:
            flat = ",".join("%d,%d" % (round(px), round(py)) for px, py in pts)
            f.write("    {%d,%d,%d,{%s}},\n" % (a + 1, b + 1, round(length), flat))
        f.write("  },\n}\n")


def write_pois(pois):
    with open(os.path.join(OUT, "poi_data.lua"), "w") as f:
        f.write(lua_header("pois"))
        f.write("return {\n  points={\n")
        for p in pois:
            f.write('    {id="%s",label="%s",sector="%s",kind="%s",'
                    'x=%d,y=%d,weight=%.2f,radius=%d},\n'
                    % (p["id"], p["label"], p["sector"], p["kind"],
                       round(p["x"]), round(p["y"]), p["weight"],
                       int(p.get("radius", 9000))))
        f.write("  },\n}\n")


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(BUILD, exist_ok=True)
    src = SOURCE
    water, road, yellow, white, w, h = classify(src)
    print("map %dx%d  water=%.1f%%  road=%.2f%%"
          % (w, h, 100 * water.mean(), 100 * road.mean()))

    grid = build_navgrid(water, road, w, h)
    grid, labels, sizes = flood_keep_main_landmasses(grid)
    counts = {int(v): int((grid == v).sum()) for v in (0, 1, 2)}
    print("navgrid %dx%d  water=%d land=%d road=%d"
          % (GRID, GRID, counts[0], counts[1], counts[2]))
    write_navgrid(grid)

    nodes, edges, skel, SW, SH = trace_road_graph(road, w, h, scale=2)
    print("skeleton %dx%d  raw nodes=%d raw edges=%d" % (SW, SH, len(nodes), len(edges)))

    # Convert to world coordinates and simplify each polyline.
    idx_xy = [None] * len(nodes)
    for (ny, nx), i in nodes.items():
        idx_xy[i] = uv_to_world((nx + 0.5) / SW, (ny + 0.5) / SH)

    edges_out = []
    seen = set()
    for a, b, path in edges:
        key = (min(a, b), max(a, b), len(path))
        if key in seen:
            continue
        seen.add(key)
        pts = [uv_to_world((px + 0.5) / SW, (py + 0.5) / SH) for py, px in path]
        simp = rdp(pts, eps=1400.0)
        length = sum(math.dist(simp[i], simp[i + 1]) for i in range(len(simp) - 1))
        if length < 500:
            continue
        edges_out.append((a, b, length, simp[1:-1]))

    edges_out, stitched = stitch_components(idx_xy, edges_out, grid)
    print("stitched %d component gaps" % stitched)

    # Drop nodes that no surviving edge references, renumber compactly.
    used = sorted({a for a, _, _, _ in edges_out} | {b for _, b, _, _ in edges_out})
    remap = {old: i for i, old in enumerate(used)}
    nodes_xy = [idx_xy[o] for o in used]
    edges_out = [(remap[a], remap[b], ln, pts) for a, b, ln, pts in edges_out]
    print("roadnet nodes=%d edges=%d" % (len(nodes_xy), len(edges_out)))
    write_roadnet(nodes_xy, edges_out)

    # ---- POIs ----
    clusters = settlement_clusters(white, w, h, grid)
    print("settlement clusters=%d" % len(clusters))

    pois = []
    seen_ids = set()

    def add(pid, label, kind, x, y, weight, radius):
        if pid in seen_ids:
            return
        seen_ids.add(pid)
        pois.append(dict(id=pid, label=label, kind=kind, x=x, y=y,
                         sector=sector_of(x, y), weight=weight, radius=radius))

    for i, c in enumerate(clusters[:200]):
        sec = sector_of(c["x"], c["y"])
        size = c["cells"]
        if size >= 24:
            kind, weight, radius, tag = "CITY", 3.4, 26000, "City"
        elif size >= 8:
            kind, weight, radius, tag = "TOWN", 2.4, 17000, "Town"
        else:
            kind, weight, radius, tag = "VILLAGE", 1.7, 11000, "Village"
        add("%s_%s_%02d" % (kind[:3], sec, i), "%s %s" % (sec, tag), kind,
            c["x"], c["y"], weight, radius)

    for i, ((x, y), d) in enumerate(wilderness_points(grid)):
        add("WLD_%s_%02d" % (sector_of(x, y), i), "%s wilderness" % sector_of(x, y),
            "WILDERNESS", x, y, 1.15, 24000)

    for i, (x, y) in enumerate(coastal_points(grid)):
        add("SHR_%s_%02d" % (sector_of(x, y), i), "%s shoreline" % sector_of(x, y),
            "SHORE", x, y, 1.0, 13000)

    degrees = defaultdict(int)
    for a, b, _, _ in edges_out:
        degrees[a] += 1
        degrees[b] += 1
    for i, (x, y) in enumerate(junction_points(nodes_xy, degrees)):
        add("JCT_%s_%02d" % (sector_of(x, y), i), "%s junction" % sector_of(x, y),
            "JUNCTION", x, y, 1.25, 9000)

    # Hand-verified landmark coordinates carried over from the previous package.
    extra = json.load(open(os.path.join(TOOLS, "landmark_pois.json")))
    for p in extra:
        add(p["id"], p["label"], p["kind"], p["x"], p["y"],
            p.get("weight", 2.0), p.get("radius", 9000))

    pois.sort(key=lambda p: (p["kind"], p["id"]))
    print("pois=%d" % len(pois))
    write_pois(pois)

    # Debug overlay so the generated data can be eyeballed against the map.
    dbg = Image.open(src).convert("RGB").resize((1024, 1024))
    d = dbg.load()
    for gy in range(GRID):
        for gx in range(GRID):
            if grid[gy, gx] == 0:
                for oy in range(2):
                    for ox in range(2):
                        d[gx * 2 + ox, gy * 2 + oy] = (10, 20, 80)
    for a, b, ln, pts in edges_out:
        chain = [nodes_xy[a]] + list(pts) + [nodes_xy[b]]
        for i in range(len(chain) - 1):
            (x1, y1), (x2, y2) = chain[i], chain[i + 1]
            u1, v1 = world_to_uv(x1, y1)
            u2, v2 = world_to_uv(x2, y2)
            steps = max(2, int(math.hypot((u2 - u1) * 1024, (v2 - v1) * 1024)))
            for s in range(steps + 1):
                t = s / steps
                px = int((u1 + (u2 - u1) * t) * 1024)
                py = int((v1 + (v2 - v1) * t) * 1024)
                if 0 <= px < 1024 and 0 <= py < 1024:
                    d[px, py] = (255, 90, 60)
    for p in pois:
        u, v = world_to_uv(p["x"], p["y"])
        px, py = int(u * 1024), int(v * 1024)
        col = {"CITY": (120, 220, 255), "TOWN": (90, 255, 140),
               "VILLAGE": (240, 240, 120)}.get(p["kind"], (255, 140, 255))
        for oy in range(-3, 4):
            for ox in range(-3, 4):
                if abs(ox) + abs(oy) <= 3 and 0 <= px + ox < 1024 and 0 <= py + oy < 1024:
                    d[px + ox, py + oy] = col
    dbg.save(os.path.join(BUILD, "debug_worlddata.png"))
    print("wrote debug overlay")


if __name__ == "__main__":
    sys.exit(main())
