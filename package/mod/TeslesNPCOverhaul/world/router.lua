-- Hybrid world router.
--
-- The single biggest cause of the old "zig-zag across the map" behaviour was
-- that a fresh destination was solved on every tick, so the actor turned
-- towards a slightly different point each time. This module solves a route
-- ONCE and hands back an immutable waypoint list. Nothing downstream is
-- allowed to mutate it; a new route means an explicit replan.
--
-- Three strategies, in order of preference:
--   DIRECT  short trip with a clear straight line
--   ROAD    long trip: off-road leg -> road graph -> off-road leg
--   GRID    A* over the terrain grid when no usable road path exists
local U = require("core.util")
local Grid = require("world.navgrid")
local Road = require("world.roadnet")

local Router = {}

Router.DIRECT_MAX = 60000          -- 600 m: below this a clear line wins
Router.ROAD_SNAP = 110000          -- 1.1 km max walk to reach the road network
Router.ROAD_DETOUR_LIMIT = 2.80    -- refuse a road route this much longer
Router.GRID_BUDGET = 6500          -- A* expansion cap per call
Router.TICK_BUDGET = 7000          -- shared expansion cap per director tick
Router.SIMPLIFY_EPS = 2200         -- polyline simplification tolerance (UU)

Router.stats = { direct = 0, road = 0, grid = 0, failed = 0, grid_expansions = 0 }

-- Expansions still available this tick. The director resets it so one busy
-- frame cannot spend the whole server budget on a single hard search.
Router.budget_left = Router.TICK_BUDGET

function Router.begin_tick(budget)
    Router.budget_left = budget or Router.TICK_BUDGET
end

-- ------------------------------------------------------------- simplify ----

-- Ramer-Douglas-Peucker. Keeps route shape while removing the cell-by-cell
-- staircase that a raw grid path produces.
local function rdp(pts, eps, first, last, keep)
    if last <= first + 1 then return end
    local a, b = pts[first], pts[last]
    local dx, dy = b.X - a.X, b.Y - a.Y
    local den = math.sqrt(dx * dx + dy * dy)
    local worst, wi = -1, first
    for i = first + 1, last - 1 do
        local p = pts[i]
        local d
        if den < 1e-6 then
            d = U.dist2d(p, a)
        else
            d = math.abs(dy * p.X - dx * p.Y + b.X * a.Y - b.Y * a.X) / den
        end
        if d > worst then worst, wi = d, i end
    end
    if worst > eps then
        keep[wi] = true
        rdp(pts, eps, first, wi, keep)
        rdp(pts, eps, wi, last, keep)
    end
end

-- Simplification alone will happily cut a corner across a river, because RDP
-- only looks at geometry. Every kept span is therefore re-checked against the
-- terrain, and the dropped points are put back wherever the shortcut would
-- have crossed water.
function Router.simplify(pts, eps)
    if not pts or #pts < 3 then return pts end
    eps = eps or Router.SIMPLIFY_EPS
    local keep = { [1] = true, [#pts] = true }
    rdp(pts, eps, 1, #pts, keep)

    local out = { pts[1] }
    local anchor = 1
    for i = 2, #pts do
        if keep[i] then
            if Grid.segment_passable(pts[anchor], pts[i]) then
                out[#out + 1] = pts[i]
            else
                -- Put the original shape back for this span.
                for j = anchor + 1, i do out[#out + 1] = pts[j] end
            end
            anchor = i
        end
    end
    return out
end

-- String pulling: repeatedly skip ahead to the furthest waypoint still in
-- clear line of sight. Turns a staircase into long straight legs, which is
-- exactly what removes the visible zig-zag on screen.
function Router.string_pull(pts, max_skip)
    if not pts or #pts < 3 then return pts end
    max_skip = max_skip or 24
    local out = { pts[1] }
    local i = 1
    while i < #pts do
        local best = i + 1
        local limit = math.min(#pts, i + max_skip)
        for j = limit, i + 2, -1 do
            if Grid.segment_passable(pts[i], pts[j]) then
                best = j
                break
            end
        end
        out[#out + 1] = pts[best]
        i = best
    end
    return out
end

-- ---------------------------------------------------------- grid A* -------

local DIRS = {
    { 1, 0, 1.0 }, { -1, 0, 1.0 }, { 0, 1, 1.0 }, { 0, -1, 1.0 },
    { 1, 1, 1.41421 }, { 1, -1, 1.41421 }, { -1, 1, 1.41421 }, { -1, -1, 1.41421 },
}

local function cell_cost(v)
    if v == Grid.ROAD then return 0.62 end       -- roads are the fast lane
    return 1.0
end

function Router.grid_path(from, to, budget)
    local n = Grid.size
    local sx, sy = Grid.world_to_grid(from)
    local gx, gy = Grid.world_to_grid(to)
    if not (sx and gx) then return nil, "OUT_OF_BOUNDS" end
    sx, sy = Grid.nearest_passable(sx, sy)
    gx, gy = Grid.nearest_passable(gx, gy)
    if not (sx and gx) then return nil, "NO_LAND" end
    if Grid.landmass_of_cell(sx, sy) ~= Grid.landmass_of_cell(gx, gy) then
        return nil, "DIFFERENT_LANDMASS"
    end

    local start_id, goal_id = sy * n + sx, gy * n + gx
    if start_id == goal_id then
        return { Grid.grid_to_world(gx, gy, to.Z) }, "SAME_CELL"
    end

    budget = math.min(budget or Router.GRID_BUDGET,
        math.max(600, Router.budget_left or Router.GRID_BUDGET))
    local g = { [start_id] = 0 }
    local came = {}
    local closed = {}
    local open = Road._heap_new()
    local function h(cx, cy)
        local dx, dy = math.abs(cx - gx), math.abs(cy - gy)
        local mn = math.min(dx, dy)
        return (dx + dy) + (1.41421 - 2) * mn
    end
    Road._heap_push(open, start_id, h(sx, sy))

    local expanded = 0
    local cells = Grid.cells
    while true do
        local cur = Road._heap_pop(open)
        if not cur then return nil, "NO_PATH" end
        if not closed[cur] then
            closed[cur] = true
            if cur == goal_id then break end
            expanded = expanded + 1
            if expanded > budget then
                Router.stats.grid_expansions = Router.stats.grid_expansions + expanded
                Router.budget_left = (Router.budget_left or 0) - expanded
                return nil, "BUDGET"
            end
            local cy = math.floor(cur / n)
            local cx = cur - cy * n
            local base = g[cur]
            for _, d in ipairs(DIRS) do
                local nx, ny = cx + d[1], cy + d[2]
                if nx >= 0 and ny >= 0 and nx < n and ny < n then
                    local ni = ny * n + nx
                    local v = cells[ni]
                    if v and v ~= Grid.WATER and not closed[ni] then
                        -- Diagonal moves may not cut a water corner.
                        local ok = true
                        if d[1] ~= 0 and d[2] ~= 0 then
                            if (cells[cy * n + nx] or 0) == Grid.WATER
                                or (cells[ny * n + cx] or 0) == Grid.WATER then
                                ok = false
                            end
                        end
                        if ok then
                            local ng = base + d[3] * cell_cost(v)
                            if g[ni] == nil or ng < g[ni] then
                                g[ni] = ng
                                came[ni] = cur
                                Road._heap_push(open, ni, ng + h(nx, ny))
                            end
                        end
                    end
                end
            end
        end
    end
    Router.stats.grid_expansions = Router.stats.grid_expansions + expanded
    Router.budget_left = (Router.budget_left or 0) - expanded

    local out, node = {}, goal_id
    while node do
        local cy = math.floor(node / n)
        table.insert(out, 1, Grid.grid_to_world(node - cy * n, cy, to.Z))
        node = came[node]
    end
    return out, "OK"
end

-- --------------------------------------------------------------- routing ---

local function polyline_length(pts)
    local len = 0
    for i = 1, #pts - 1 do len = len + U.dist2d(pts[i], pts[i + 1]) end
    return len
end

local function apply_z(pts, z)
    for _, p in ipairs(pts) do p.Z = z end
    return pts
end

-- Last line of defence: no finished route may contain a segment that crosses
-- water. If one slipped through, the offending leg is repaired on the grid.
local function repair(pts)
    local out = { pts[1] }
    for i = 2, #pts do
        local a, b = out[#out], pts[i]
        if Grid.segment_passable(a, b) then
            out[#out + 1] = b
        else
            local leg = Router.grid_path(a, b, 3000)
            if leg and #leg > 1 then
                for j = 2, #leg do out[#out + 1] = leg[j] end
                out[#out] = b
            else
                out[#out + 1] = b
            end
        end
    end
    return out
end

local function finish(pts, kind, from, to)
    if not pts or #pts == 0 then return nil end
    if #pts > 1 then pts = repair(pts) end
    -- The final waypoint must be the real destination, not a cell centre.
    pts[#pts] = U.copy_vec(to)
    apply_z(pts, to.Z or from.Z or 0)
    local route = {
        points = pts,
        kind = kind,
        length = polyline_length(pts),
        straight = U.dist2d(from, to),
        built_at = os.time(),
        goal = U.copy_vec(to),
        origin = U.copy_vec(from),
    }
    route.detour = route.straight > 1 and (route.length / route.straight) or 1
    Router.stats[string.lower(kind)] = (Router.stats[string.lower(kind)] or 0) + 1
    return route
end

-- Builds a route from `from` to `to`.
--   opts.prefer_roads  false for cross-country activities (hunting, camping)
--   opts.allow_grid    false to skip the expensive A* fallback
function Router.route(from, to, opts)
    opts = opts or {}
    if not (U.finite_vec(from) and U.finite_vec(to)) then
        Router.stats.failed = Router.stats.failed + 1
        return nil, "BAD_INPUT"
    end

    to = Grid.snap_to_land(to) or to
    local straight = U.dist2d(from, to)
    if straight < 1 then return nil, "ALREADY_THERE" end

    -- 1. Short and clear: one straight leg.
    if Grid.segment_passable(from, to) then
        if straight <= (opts.direct_max or Router.DIRECT_MAX) or opts.prefer_roads == false then
            return finish({ U.copy_vec(from), U.copy_vec(to) }, "DIRECT", from, to)
        end
    end

    -- 2. Road network for long hauls.
    if opts.prefer_roads ~= false then
        local ca = Road.snap_candidates(from, Router.ROAD_SNAP)
        local cb = Road.snap_candidates(to, Router.ROAD_SNAP)
        local by_comp = {}
        for _, c in ipairs(cb) do
            if not by_comp[c.comp] or c.dist < by_comp[c.comp].dist then
                by_comp[c.comp] = c
            end
        end
        local a, b, best_cost = nil, nil, nil
        for _, c in ipairs(ca) do
            local m = by_comp[c.comp]
            if m then
                local cost = c.dist + m.dist
                if not best_cost or cost < best_cost then
                    a, b, best_cost = c.node, m.node, cost
                end
            end
        end
        if a and b and a ~= b then
            local node_path = Road.find_path(a, b)
            if node_path then
                local poly = Road.expand_path(node_path)
                if poly and #poly > 0 then
                    local pts = { U.copy_vec(from) }
                    -- Leg onto the network. If it is not a clear walk, route
                    -- it on the grid so the group does not cut through water.
                    if not Grid.segment_passable(from, poly[1]) then
                        local leg = Router.grid_path(from, poly[1])
                        if leg then
                            for i = 2, #leg - 1 do pts[#pts + 1] = leg[i] end
                        end
                    end
                    for _, p in ipairs(poly) do pts[#pts + 1] = U.copy_vec(p) end
                    if not Grid.segment_passable(poly[#poly], to) then
                        local leg = Router.grid_path(poly[#poly], to)
                        if leg then
                            for i = 2, #leg - 1 do pts[#pts + 1] = leg[i] end
                        end
                    end
                    pts[#pts + 1] = U.copy_vec(to)
                    pts = Router.simplify(pts, Router.SIMPLIFY_EPS)
                    local len = polyline_length(pts)
                    -- A road that loops the long way round is worse than
                    -- walking: fall through to the grid search instead.
                    if len <= straight * Router.ROAD_DETOUR_LIMIT
                        or not Grid.same_landmass(from, to) then
                        return finish(pts, "ROAD", from, to)
                    end
                end
            end
        end
    end

    -- 3. Terrain A*.
    if opts.allow_grid ~= false then
        local path, why = Router.grid_path(from, to, opts.budget)
        if path and #path > 0 then
            table.insert(path, 1, U.copy_vec(from))
            path = Router.string_pull(path)
            path = Router.simplify(path, Router.SIMPLIFY_EPS * 0.6)
            return finish(path, "GRID", from, to)
        end
        Router.stats.failed = Router.stats.failed + 1
        return nil, why or "NO_PATH"
    end

    Router.stats.failed = Router.stats.failed + 1
    return nil, "NO_ROUTE"
end

-- Distance still to travel from `index` along the route.
function Router.remaining(route, index, pos)
    if not route then return 0 end
    local pts = route.points
    local i = math.max(1, math.min(index or 1, #pts))
    local total = pos and U.dist2d(pos, pts[i]) or 0
    for j = i, #pts - 1 do total = total + U.dist2d(pts[j], pts[j + 1]) end
    return total
end

return Router
