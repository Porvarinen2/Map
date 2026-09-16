-- SmartNPC :: world.lua
-- Land grid, connected components, A* router, path smoothing, route objects,
-- sector naming and the POI index.
--
-- The router is the single source of truth for "where a squad walks".  Both the
-- virtual simulation and the physical body driver consume the same route, so a
-- squad's path never changes shape when it materialises.

local S = SMARTNPC
local U = S.util
local C = S.config

local W = {}

local floor, ceil, abs, sqrt, max, min = math.floor, math.ceil, math.abs, math.sqrt, math.max, math.min

--------------------------------------------------------------------------
-- grid
--------------------------------------------------------------------------

local G           -- raw grid table from data/navgrid.lua
local CELLS       -- flat array of cell values, 1-based, idx = (row-1)*W + col
local GW, GH
local CELL_W, CELL_H   -- world units per cell
local COMP            -- connected component id per cell (0 = impassable)
local COMP_SIZE = {}
local MAIN_COMP = 0

local WATER, LAND, ROAD = 0, 1, 2

function W.load()
    G = dofile(S.DIR_DATA .. S.SEP .. "navgrid.lua")
    assert(type(G) == "table" and G.rows, "navgrid.lua invalid")
    GW, GH = G.width, G.height
    CELLS = {}
    for r = 1, GH do
        local row = G.rows[r]
        local base = (r - 1) * GW
        for c = 1, GW do
            local ch = row:sub(c, c)
            CELLS[base + c] = tonumber(ch) or WATER
        end
    end
    CELL_W = (G.xWest - G.xEast) / GW
    CELL_H = (G.yNorth - G.ySouth) / GH
    W.build_components()
    W.load_pois()
    U.log(string.format("world: grid %dx%d  cell %.0fx%.0f uu  components=%d main=%d (%d cells)",
        GW, GH, abs(CELL_W), abs(CELL_H), #COMP_SIZE, MAIN_COMP, COMP_SIZE[MAIN_COMP] or 0))
end

local function idx(c, r) return (r - 1) * GW + c end

function W.cell_value(c, r)
    if c < 1 or r < 1 or c > GW or r > GH then return WATER end
    return CELLS[idx(c, r)] or WATER
end

function W.passable(c, r)
    return W.cell_value(c, r) ~= WATER
end

-- world -> grid.  u runs west->east across the map image, v north->south.
function W.to_cell(p)
    if not p then return nil end
    local u = (G.xWest - (p.x or p.X)) / (G.xWest - G.xEast)
    local v = (G.yNorth - (p.y or p.Y)) / (G.yNorth - G.ySouth)
    local c = floor(u * GW) + 1
    local r = floor(v * GH) + 1
    return U.clamp(c, 1, GW), U.clamp(r, 1, GH)
end

function W.cell_center(c, r)
    local u = (c - 0.5) / GW
    local v = (r - 0.5) / GH
    return {
        x = G.xWest - u * (G.xWest - G.xEast),
        y = G.yNorth - v * (G.yNorth - G.ySouth),
        z = 0,
    }
end

function W.norm(p)
    local u = (G.xWest - (p.x or p.X)) / (G.xWest - G.xEast)
    local v = (G.yNorth - (p.y or p.Y)) / (G.yNorth - G.ySouth)
    return u, v
end

function W.bounds()
    return { xWest = G.xWest, xEast = G.xEast, yNorth = G.yNorth, ySouth = G.ySouth, w = GW, h = GH }
end

function W.is_water(p)
    local c, r = W.to_cell(p)
    if not c then return true end
    return W.cell_value(c, r) == WATER
end

function W.is_road(p)
    local c, r = W.to_cell(p)
    if not c then return false end
    return W.cell_value(c, r) == ROAD
end

--------------------------------------------------------------------------
-- sectors (SCUM map grid: rows D,C,B,A,Z north->south; columns 4..0 west->east)
--------------------------------------------------------------------------

local ROW_LETTERS = { "D", "C", "B", "A", "Z" }

function W.sector(p)
    if not p then return "??" end
    local u, v = W.norm(p)
    local ci = U.clamp(floor(u * 5), 0, 4)
    local ri = U.clamp(floor(v * 5), 0, 4)
    return ROW_LETTERS[ri + 1] .. tostring(4 - ci)
end

--------------------------------------------------------------------------
-- connected components
--------------------------------------------------------------------------
-- Islands are land but unreachable on foot.  Squads may only pick destinations
-- inside their own component, which removes every "walk into the sea" bug at
-- the source instead of patching it during path following.

function W.build_components()
    COMP = {}
    COMP_SIZE = {}
    local next_id = 0
    local stack = {}
    for r = 1, GH do
        for c = 1, GW do
            local i = idx(c, r)
            if COMP[i] == nil then
                if not W.passable(c, r) then
                    COMP[i] = 0
                else
                    next_id = next_id + 1
                    local n = 0
                    local sp = 1
                    stack[1] = i
                    COMP[i] = next_id
                    while sp > 0 do
                        local cur = stack[sp]; sp = sp - 1
                        n = n + 1
                        local cr = floor((cur - 1) / GW) + 1
                        local cc = cur - (cr - 1) * GW
                        for dc = -1, 1 do
                            for dr = -1, 1 do
                                if dc ~= 0 or dr ~= 0 then
                                    local nc, nr = cc + dc, cr + dr
                                    if nc >= 1 and nr >= 1 and nc <= GW and nr <= GH then
                                        local ni = idx(nc, nr)
                                        if COMP[ni] == nil and W.passable(nc, nr) then
                                            -- Diagonal steps may not cut a water corner.
                                            local okdiag = (dc == 0 or dr == 0)
                                                or (W.passable(cc + dc, cr) and W.passable(cc, cr + dr))
                                            if okdiag then
                                                COMP[ni] = next_id
                                                sp = sp + 1
                                                stack[sp] = ni
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    COMP_SIZE[next_id] = n
                end
            end
        end
    end
    local best, bestn = 0, -1
    for id, n in pairs(COMP_SIZE) do
        if n > bestn then best, bestn = id, n end
    end
    MAIN_COMP = best
end

function W.component(p)
    local c, r = W.to_cell(p)
    if not c then return 0 end
    return COMP[idx(c, r)] or 0
end

function W.main_component() return MAIN_COMP end

--------------------------------------------------------------------------
-- nearest passable cell
--------------------------------------------------------------------------

function W.snap_to_land(p, want_comp, max_rings)
    local c, r = W.to_cell(p)
    if not c then return nil end
    local i = idx(c, r)
    if W.passable(c, r) and (not want_comp or COMP[i] == want_comp) then
        return { x = p.x or p.X, y = p.y or p.Y, z = p.z or p.Z or 0 }, c, r
    end
    max_rings = max_rings or 12
    for ring = 1, max_rings do
        for dc = -ring, ring do
            for dr = -ring, ring do
                if abs(dc) == ring or abs(dr) == ring then
                    local nc, nr = c + dc, r + dr
                    if nc >= 1 and nr >= 1 and nc <= GW and nr <= GH and W.passable(nc, nr) then
                        local ni = idx(nc, nr)
                        if not want_comp or COMP[ni] == want_comp then
                            return W.cell_center(nc, nr), nc, nr
                        end
                    end
                end
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- A* router
--------------------------------------------------------------------------

local NEI = {
    { 1, 0, 1.0 }, { -1, 0, 1.0 }, { 0, 1, 1.0 }, { 0, -1, 1.0 },
    { 1, 1, 1.41421 }, { 1, -1, 1.41421 }, { -1, 1, 1.41421 }, { -1, -1, 1.41421 },
}

local function cell_cost(v)
    if v == ROAD then return C.RouteRoadCost end
    return C.RouteLandCost
end

-- Binary min-heap keyed on f.
local function heap_new() return { n = 0 } end
local function heap_push(h, node, f)
    local n = h.n + 1
    h.n = n
    h[n] = node
    node.f = f
    while n > 1 do
        local p = floor(n / 2)
        if h[p].f <= h[n].f then break end
        h[p], h[n] = h[n], h[p]
        n = p
    end
end
local function heap_pop(h)
    local n = h.n
    if n == 0 then return nil end
    local top = h[1]
    h[1] = h[n]
    h[n] = nil
    h.n = n - 1
    n = n - 1
    local i = 1
    while true do
        local l, r2, s = i * 2, i * 2 + 1, i
        if l <= n and h[l].f < h[s].f then s = l end
        if r2 <= n and h[r2].f < h[s].f then s = r2 end
        if s == i then break end
        h[i], h[s] = h[s], h[i]
        i = s
    end
    return top
end

-- Returns an array of {c,r} cells, or nil.
function W.astar(from, to, budget)
    local sc, sr = W.to_cell(from)
    local gc, gr = W.to_cell(to)
    if not sc or not gc then return nil, "offmap" end
    if not W.passable(sc, sr) then
        local snapped = W.snap_to_land(from)
        if not snapped then return nil, "start-water" end
        sc, sr = W.to_cell(snapped)
    end
    if not W.passable(gc, gr) then
        local snapped = W.snap_to_land(to, COMP[idx(sc, sr)])
        if not snapped then return nil, "goal-water" end
        gc, gr = W.to_cell(snapped)
    end
    local comp = COMP[idx(sc, sr)]
    if comp == 0 or COMP[idx(gc, gr)] ~= comp then return nil, "disconnected" end
    if sc == gc and sr == gr then return { { c = sc, r = sr } } end

    budget = budget or C.RouteNodeBudget
    local open = heap_new()
    local gscore, came, closed = {}, {}, {}
    local sidx = idx(sc, sr)
    gscore[sidx] = 0
    heap_push(open, { c = sc, r = sr, i = sidx }, 0)

    local expanded = 0
    local best_node, best_h = nil, math.huge

    while open.n > 0 do
        local cur = heap_pop(open)
        if closed[cur.i] then goto continue end
        closed[cur.i] = true
        expanded = expanded + 1

        local hx, hy = gc - cur.c, gr - cur.r
        local h = sqrt(hx * hx + hy * hy)
        if h < best_h then best_h, best_node = h, cur end

        if cur.c == gc and cur.r == gr then
            local path, node = {}, cur
            while node do
                path[#path + 1] = { c = node.c, r = node.r }
                node = came[node.i]
            end
            for i = 1, floor(#path / 2) do
                path[i], path[#path - i + 1] = path[#path - i + 1], path[i]
            end
            return path
        end

        if expanded > budget then break end

        local gcur = gscore[cur.i]
        for k = 1, 8 do
            local d = NEI[k]
            local nc, nr = cur.c + d[1], cur.r + d[2]
            if nc >= 1 and nr >= 1 and nc <= GW and nr <= GH then
                local v = W.cell_value(nc, nr)
                if v ~= WATER then
                    local ok = true
                    if d[1] ~= 0 and d[2] ~= 0 then
                        -- never squeeze diagonally between two water cells
                        ok = W.passable(cur.c + d[1], cur.r) and W.passable(cur.c, cur.r + d[2])
                    end
                    if ok then
                        local ni = idx(nc, nr)
                        if not closed[ni] then
                            local step = d[3] * cell_cost(v)
                            local ng = gcur + step
                            if gscore[ni] == nil or ng < gscore[ni] - 1e-6 then
                                gscore[ni] = ng
                                local node = { c = nc, r = nr, i = ni }
                                came[ni] = cur
                                local ex, ey = gc - nc, gr - nr
                                heap_push(open, node, ng + sqrt(ex * ex + ey * ey) * C.RouteHeuristicWeight)
                            end
                        end
                    end
                end
            end
        end
        ::continue::
    end

    -- Budget exhausted: return the best partial path found so far.  A squad
    -- walking most of the way and re-planning beats a squad standing still.
    if best_node then
        local path, node = {}, best_node
        while node do
            path[#path + 1] = { c = node.c, r = node.r }
            node = came[node.i]
        end
        for i = 1, floor(#path / 2) do
            path[i], path[#path - i + 1] = path[#path - i + 1], path[i]
        end
        if #path > 1 then return path, "partial" end
    end
    return nil, "nopath"
end

--------------------------------------------------------------------------
-- path post-processing
--------------------------------------------------------------------------

-- Grid line of sight: true when every cell the segment passes through is
-- walkable.  Used for string pulling, so it errs on the strict side - a
-- shortcut is only taken when the straight line is unambiguously clear.
local function cells_clear(c0, r0, c1, r1)
    local dc, dr = c1 - c0, r1 - r0
    local steps = max(abs(dc), abs(dr))
    if steps == 0 then return W.passable(c0, r0) end
    for i = 0, steps do
        local t = i / steps
        local c = floor(c0 + dc * t + 0.5)
        local r = floor(r0 + dr * t + 0.5)
        if not W.passable(c, r) then return false end
        -- also reject squeezing past a corner
        if not W.passable(floor(c0 + dc * t), floor(r0 + dr * t)) then return false end
    end
    return true
end

-- Remove grid staircase artefacts, but never trade a road corridor for open
-- ground: roads are why squads read as players moving between places.
local function string_pull(cells, max_skip)
    if #cells <= 2 then return cells end
    local out = { cells[1] }
    local i = 1
    while i < #cells do
        local best = i + 1
        local limit = min(#cells, i + max_skip)
        for j = limit, i + 2, -1 do
            local a, b = cells[i], cells[j]
            if cells_clear(a.c, a.r, b.c, b.r) then
                local road = 0
                for k = i, j do
                    if W.cell_value(cells[k].c, cells[k].r) == ROAD then road = road + 1 end
                end
                if road <= (j - i) * 0.5 then best = j end
                break
            end
        end
        out[#out + 1] = cells[best]
        i = best
    end
    return out
end

-- Chaikin corner cutting: turns 90-degree grid corners into gentle arcs.
local function chaikin(pts, iterations)
    for _ = 1, iterations do
        if #pts < 3 then return pts end
        local out = { pts[1] }
        for i = 1, #pts - 1 do
            local a, b = pts[i], pts[i + 1]
            out[#out + 1] = { x = a.x * 0.75 + b.x * 0.25, y = a.y * 0.75 + b.y * 0.25 }
            out[#out + 1] = { x = a.x * 0.25 + b.x * 0.75, y = a.y * 0.25 + b.y * 0.75 }
        end
        out[#out + 1] = pts[#pts]
        pts = out
    end
    return pts
end

-- Resample to roughly even spacing so every leg the body driver issues is a
-- comfortable walking distance instead of a 9 m grid hop.
local function resample(pts, spacing)
    if #pts < 2 then return pts end
    local out = { { x = pts[1].x, y = pts[1].y } }
    local carry = 0
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local seg = sqrt(dx * dx + dy * dy)
        if seg > 1e-3 then
            local t = spacing - carry
            while t <= seg do
                out[#out + 1] = { x = a.x + dx * (t / seg), y = a.y + dy * (t / seg) }
                t = t + spacing
            end
            carry = (carry + seg) % spacing
        end
    end
    local last = pts[#pts]
    local lo = out[#out]
    if U.dist2(lo, last) > spacing * 0.35 then
        out[#out + 1] = { x = last.x, y = last.y }
    else
        out[#out] = { x = last.x, y = last.y }
    end
    return out
end

-- Drop nodes that sit on water after smoothing (Chaikin can cut a corner into
-- a bay).  Each offender is pushed back onto the nearest land cell.
local function repair_water(pts)
    for i = 1, #pts do
        local p = pts[i]
        if W.is_water(p) then
            local fixed = W.snap_to_land(p, nil, 3)
            if fixed then p.x, p.y = fixed.x, fixed.y end
        end
    end
    return pts
end

--------------------------------------------------------------------------
-- Route object
--------------------------------------------------------------------------

local Route = {}
Route.__index = Route
W.Route = Route

local function build_route(nodes, meta)
    local r = setmetatable({}, Route)
    r.nodes = nodes
    r.cum = { 0 }
    local total = 0
    for i = 2, #nodes do
        total = total + U.dist2(nodes[i - 1], nodes[i])
        r.cum[i] = total
    end
    r.total = total
    r.meta = meta or {}
    -- Turn angle at each node, used by the body driver to decide whether it may
    -- chain into the next leg or must let the NPC arrive and turn first.
    r.turn = {}
    for i = 2, #nodes - 1 do
        local a, b, c = nodes[i - 1], nodes[i], nodes[i + 1]
        local h1 = U.heading(b.x - a.x, b.y - a.y)
        local h2 = U.heading(c.x - b.x, c.y - b.y)
        r.turn[i] = abs(U.angle_delta(h1, h2))
    end
    return r
end
W.build_route = build_route

function Route:point_at(s)
    local n = #self.nodes
    if n == 0 then return nil end
    if s <= 0 then return { x = self.nodes[1].x, y = self.nodes[1].y } end
    if s >= self.total then return { x = self.nodes[n].x, y = self.nodes[n].y } end
    local lo, hi = 1, n
    while lo < hi do
        local mid = floor((lo + hi) / 2)
        if self.cum[mid] < s then lo = mid + 1 else hi = mid end
    end
    local i = max(2, lo)
    local a, b = self.nodes[i - 1], self.nodes[i]
    local seg = self.cum[i] - self.cum[i - 1]
    local t = seg > 1e-6 and (s - self.cum[i - 1]) / seg or 0
    return { x = U.lerp(a.x, b.x, t), y = U.lerp(a.y, b.y, t) }, i
end

function Route:tangent_at(s)
    local n = #self.nodes
    if n < 2 then return 1, 0 end
    local _, i = self:point_at(min(max(s, 0), self.total))
    i = U.clamp(i or 2, 2, n)
    local a, b = self.nodes[i - 1], self.nodes[i]
    local dx, dy = U.norm2(b.x - a.x, b.y - a.y)
    return dx, dy
end

-- Project a world position onto the route, searching near the last known
-- progress so a squad that doubles back cannot snap to the far end.
function Route:project(p, hint_s)
    local n = #self.nodes
    if n < 2 then return 0 end
    local lo_i, hi_i = 2, n
    if hint_s then
        local _, hi = self:point_at(U.clamp(hint_s, 0, self.total))
        hi = hi or 2
        lo_i = max(2, hi - 6)
        hi_i = min(n, hi + 10)
    end
    local best_s, best_d = hint_s or 0, math.huge
    for i = lo_i, hi_i do
        local a, b = self.nodes[i - 1], self.nodes[i]
        local dx, dy = b.x - a.x, b.y - a.y
        local seg2 = dx * dx + dy * dy
        local t = 0
        if seg2 > 1e-6 then
            t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / seg2
            t = U.clamp(t, 0, 1)
        end
        local px, py = a.x + dx * t, a.y + dy * t
        local ddx, ddy = p.x - px, p.y - py
        local d = ddx * ddx + ddy * ddy
        if d < best_d then
            best_d = d
            best_s = self.cum[i - 1] + sqrt(seg2) * t
        end
    end
    return best_s, sqrt(best_d)
end

-- Build a parallel node list offset sideways and lagged backwards.  Formation
-- members walk their own private route, so no follower ever chases a moving
-- actor and no follower target oscillates.
function Route:offset_nodes(lateral, lag)
    local out = {}
    local n = #self.nodes
    for i = 1, n do
        local s = U.clamp(self.cum[i] - (lag or 0), 0, self.total)
        local p = self:point_at(s)
        local dx, dy = self:tangent_at(s)
        -- perpendicular (right-hand)
        local px, py = dy, -dx
        local q = { x = p.x + px * lateral, y = p.y + py * lateral }
        if W.is_water(q) then q = { x = p.x, y = p.y } end
        out[i] = q
    end
    return out
end

--------------------------------------------------------------------------
-- public routing entry point
--------------------------------------------------------------------------

local route_cache = {}
local route_cache_n = 0

function W.plan(from, to, opts)
    opts = opts or {}
    local cells, why = W.astar(from, to, opts.budget)
    if not cells or #cells < 1 then return nil, why or "nopath" end

    local pulled = string_pull(cells, C.RouteStringPullMaxSkip)
    local pts = {}
    pts[1] = { x = from.x, y = from.y }
    for i = 2, #pulled - 1 do
        local cc = W.cell_center(pulled[i].c, pulled[i].r)
        pts[#pts + 1] = { x = cc.x, y = cc.y }
    end
    pts[#pts + 1] = { x = to.x, y = to.y }

    if #pts >= 3 then pts = chaikin(pts, C.RouteSmoothIterations) end
    pts = repair_water(pts)
    pts = resample(pts, C.RouteNodeSpacingUU)
    pts = repair_water(pts)

    if #pts < 2 then
        pts = { { x = from.x, y = from.y }, { x = to.x, y = to.y } }
    end

    local road_cells = 0
    for i = 1, #cells do
        if W.cell_value(cells[i].c, cells[i].r) == ROAD then road_cells = road_cells + 1 end
    end

    return build_route(pts, {
        partial = (why == "partial"),
        road_ratio = #cells > 0 and (road_cells / #cells) or 0,
        cells = #cells,
    })
end

-- Straight-line fallback route used only when A* has nothing (very short hops
-- inside a settlement, or a squad standing on an unmapped cell).
function W.direct_route(from, to)
    local d = U.dist2(from, to)
    local steps = max(1, ceil(d / C.RouteNodeSpacingUU))
    local pts = {}
    for i = 0, steps do
        local t = i / steps
        pts[#pts + 1] = { x = U.lerp(from.x, to.x, t), y = U.lerp(from.y, to.y, t) }
    end
    return build_route(pts, { direct = true })
end

function W.route_between(from, to, opts)
    local d = U.dist2(from, to)
    if d < C.RouteDirectMaxUU and not W.segment_crosses_water(from, to) then
        return W.direct_route(from, to)
    end
    local r, why = W.plan(from, to, opts)
    if r then return r, why end
    if not W.segment_crosses_water(from, to) then
        return W.direct_route(from, to), "direct-fallback"
    end
    return nil, why
end

function W.segment_crosses_water(a, b)
    local c0, r0 = W.to_cell(a)
    local c1, r1 = W.to_cell(b)
    if not c0 or not c1 then return true end
    return not cells_clear(c0, r0, c1, r1)
end

--------------------------------------------------------------------------
-- POIs
--------------------------------------------------------------------------

W.pois = { highloot = {}, settlements = {}, hunting = {}, anchors = {} }

function W.load_pois()
    local ok, P = pcall(dofile, S.DIR_DATA .. S.SEP .. "pois.lua")
    if not ok or type(P) ~= "table" then
        U.log("world: pois.lua failed to load: " .. tostring(P))
        return
    end
    local function prep(list, kind)
        local out = {}
        for _, p in ipairs(list or {}) do
            local q = {
                id = p.id, label = p.label or p.id, kind = kind,
                x = p.x, y = p.y, z = 0,
                weight = p.weight or 1,
                stops = p.stops,
                sector = p.sector or W.sector({ x = p.x, y = p.y }),
            }
            q.comp = W.component(q)
            if q.comp ~= 0 then out[#out + 1] = q end
        end
        return out
    end
    W.pois.highloot    = prep(P.highloot and P.highloot.points, "HIGHLOOT")
    W.pois.settlements = prep(P.activity and P.activity.settlements, "SETTLEMENT")
    W.pois.hunting     = prep(P.activity and P.activity.hunting, "HUNTING")
    W.pois.anchors     = prep(P.anchors and P.anchors.points, "ANCHOR")
    W.pois.all = {}
    for _, group in ipairs({ W.pois.highloot, W.pois.settlements, W.pois.hunting }) do
        for _, p in ipairs(group) do W.pois.all[#W.pois.all + 1] = p end
    end
    U.log(string.format("world: pois highloot=%d settlements=%d hunting=%d anchors=%d",
        #W.pois.highloot, #W.pois.settlements, #W.pois.hunting, #W.pois.anchors))
end

-- Pick a POI weighted by base weight, distance preference and recent use.
function W.pick_poi(group, from, opts)
    opts = opts or {}
    local comp = W.component(from)
    local best = {}
    local now = U.now()
    for _, p in ipairs(group) do
        if p.comp == comp then
            local d = U.dist2(from, p)
            if d >= (opts.min_dist or 0) and d <= (opts.max_dist or math.huge) then
                local cool = (p.cooldown_until or 0) > now
                if not cool then
                    -- Mild preference for closer targets; squads should not run
                    -- the full map diagonal every single time.
                    local dscore = 1.0 / (1.0 + d / (opts.scale or 250000))
                    best[#best + 1] = { poi = p, w = p.weight * dscore }
                end
            end
        end
    end
    local sel = U.pick_weighted(best)
    return sel and sel.poi or nil
end

function W.mark_poi_used(poi, seconds)
    if poi then poi.cooldown_until = U.now() + (seconds or 900) end
end

-- A random reachable wander point, biased toward roads so squads look like
-- players moving between places rather than walking through forests.
function W.random_point(from, min_d, max_d, comp)
    comp = comp or W.component(from)
    for _ = 1, 40 do
        local ang = math.random() * math.pi * 2
        local dist = U.rand_range(min_d, max_d)
        local p = { x = from.x + math.cos(ang) * dist, y = from.y + math.sin(ang) * dist, z = 0 }
        local c, r = W.to_cell(p)
        if c and W.passable(c, r) and COMP[idx(c, r)] == comp then
            if W.cell_value(c, r) == ROAD or math.random() < 0.45 then
                return p
            end
        end
    end
    local snapped = W.snap_to_land(from, comp, 6)
    return snapped
end

return W
