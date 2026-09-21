-- Road network graph traced from the map image. Long journeys follow this
-- instead of cutting across open terrain, which is what makes travelling
-- groups read as "going somewhere" rather than drifting.
local U = require("core.util")
local Grid = require("world.navgrid")

local R = {}
local data = require("world.roadnet_data")

R.nodes = {}            -- [i] = {X=,Y=}
R.adj = {}              -- [i] = { {to=j, len=, edge=k, flip=bool}, ... }
R.edges = {}            -- [k] = { a=, b=, len=, pts={ {X,Y}, ... } }

for i, n in ipairs(data.nodes) do
    R.nodes[i] = { X = n[1], Y = n[2], Z = 0 }
    R.adj[i] = {}
end

for k, e in ipairs(data.edges) do
    local a, b, len, flat = e[1], e[2], e[3], e[4]
    local pts = {}
    for i = 1, #flat, 2 do
        pts[#pts + 1] = { X = flat[i], Y = flat[i + 1], Z = 0 }
    end
    R.edges[k] = { a = a, b = b, len = len, pts = pts }
    local adj_a, adj_b = R.adj[a], R.adj[b]
    if adj_a and adj_b then
        adj_a[#adj_a + 1] = { to = b, len = len, edge = k, flip = false }
        adj_b[#adj_b + 1] = { to = a, len = len, edge = k, flip = true }
    end
end

R.node_count = #R.nodes
R.edge_count = #R.edges

-- ------------------------------------------------------------ spatial hash --

local BUCKET = 30000.0                       -- 300 m buckets
local buckets = {}

local function bkey(x, y)
    return math.floor(x / BUCKET) .. ":" .. math.floor(y / BUCKET)
end

for i, n in ipairs(R.nodes) do
    local k = bkey(n.X, n.Y)
    local b = buckets[k]
    if not b then b = {}; buckets[k] = b end
    b[#b + 1] = i
end

-- Best node per connected component within reach, so the router can pick an
-- entry point that actually leads to the destination instead of the nearest
-- node, which is often a stub on a disconnected fragment.
function R.snap_candidates(p, max_dist)
    if not p then return {} end
    max_dist = max_dist or 120000
    local mass = Grid.landmass_at(p)
    local bx, by = math.floor(p.X / BUCKET), math.floor(p.Y / BUCKET)
    local rings = math.max(1, math.ceil(max_dist / BUCKET))
    local best_by_comp = {}
    for r = 0, rings do
        for dx = -r, r do
            for dy = -r, r do
                if r == 0 or math.abs(dx) == r or math.abs(dy) == r then
                    local b = buckets[(bx + dx) .. ":" .. (by + dy)]
                    if b then
                        for _, i in ipairs(b) do
                            local d = U.dist2d(p, R.nodes[i])
                            if d <= max_dist
                                and (mass == nil or Grid.landmass_at(R.nodes[i]) == mass) then
                                local c = R.component(i)
                                local cur = best_by_comp[c]
                                if not cur or d < cur.dist then
                                    best_by_comp[c] = { node = i, dist = d, comp = c }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local out = {}
    for _, v in pairs(best_by_comp) do out[#out + 1] = v end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

-- ------------------------------------------------- connected components ----

local comp = nil

local function build_components()
    comp = {}
    local id = 0
    for s = 1, R.node_count do
        if not comp[s] then
            id = id + 1
            local stack = { s }
            comp[s] = id
            while #stack > 0 do
                local cur = table.remove(stack)
                for _, link in ipairs(R.adj[cur] or {}) do
                    if not comp[link.to] then
                        comp[link.to] = id
                        stack[#stack + 1] = link.to
                    end
                end
            end
        end
    end
    R.component_count = id
end

function R.component(i)
    if not comp then build_components() end
    return comp[i]
end

function R.connected(a, b)
    if not (a and b) then return false end
    return R.component(a) == R.component(b)
end

-- ----------------------------------------------------------- path search ---

-- Binary min-heap keyed on cost.
local function heap_new() return { n = 0 } end

local function heap_push(h, item, cost)
    local n = h.n + 1
    h.n = n
    h[n] = { item = item, cost = cost }
    while n > 1 do
        local p = math.floor(n / 2)
        if h[p].cost <= h[n].cost then break end
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
        if l <= n and h[l].cost < h[s].cost then s = l end
        if r2 <= n and h[r2].cost < h[s].cost then s = r2 end
        if s == i then break end
        h[i], h[s] = h[s], h[i]
        i = s
    end
    return top.item, top.cost
end

R._heap_new, R._heap_push, R._heap_pop = heap_new, heap_push, heap_pop

-- A* between two graph nodes. Returns an ordered node list, or nil.
function R.find_path(start, goal, budget)
    if not (start and goal) then return nil end
    if start == goal then return { start } end
    if not R.connected(start, goal) then return nil end
    budget = budget or 30000

    local goal_pos = R.nodes[goal]
    local g = { [start] = 0 }
    local came = {}
    local closed = {}
    local open = heap_new()
    heap_push(open, start, U.dist2d(R.nodes[start], goal_pos))

    local expanded = 0
    while true do
        local cur = heap_pop(open)
        if not cur then return nil end
        if not closed[cur] then
            closed[cur] = true
            if cur == goal then
                local out, node = {}, goal
                while node do
                    table.insert(out, 1, node)
                    node = came[node]
                end
                return out
            end
            expanded = expanded + 1
            if expanded > budget then return nil end
            local base = g[cur]
            for _, link in ipairs(R.adj[cur] or {}) do
                local ng = base + link.len
                if g[link.to] == nil or ng < g[link.to] - 1 then
                    g[link.to] = ng
                    came[link.to] = cur
                    heap_push(open, link.to, ng + U.dist2d(R.nodes[link.to], goal_pos))
                end
            end
        end
    end
end

-- Expands a node path into the full world polyline, inserting each edge's
-- intermediate shape points in travel order.
function R.expand_path(node_path)
    if not node_path or #node_path == 0 then return nil end
    local out = { U.copy_vec(R.nodes[node_path[1]]) }
    for i = 1, #node_path - 1 do
        local a, b = node_path[i], node_path[i + 1]
        local best, best_len = nil, nil
        for _, link in ipairs(R.adj[a] or {}) do
            if link.to == b and (best_len == nil or link.len < best_len) then
                best, best_len = link, link.len
            end
        end
        if best then
            local e = R.edges[best.edge]
            if e and #e.pts > 0 then
                if best.flip then
                    for j = #e.pts, 1, -1 do out[#out + 1] = U.copy_vec(e.pts[j]) end
                else
                    for j = 1, #e.pts do out[#out + 1] = U.copy_vec(e.pts[j]) end
                end
            end
        end
        out[#out + 1] = U.copy_vec(R.nodes[b])
    end
    return out
end

return R
