-- Terrain grid lookup. Cells are classified from the SCUM map image by
-- tools/build_world_data.py: 0 = water, 1 = land, 2 = road/bridge.
local U = require("core.util")

local G = {}

local data = require("world.navgrid_data")

G.size = data.size
G.WATER, G.LAND, G.ROAD = 0, 1, 2
G.xWest, G.xEast = data.xWest, data.xEast
G.yNorth, G.ySouth = data.yNorth, data.ySouth

local SPAN_X = data.xWest - data.xEast      -- positive; world X falls eastwards
local SPAN_Y = data.yNorth - data.ySouth
G.cellX = SPAN_X / data.size
G.cellY = SPAN_Y / data.size
G.cell = (G.cellX + G.cellY) * 0.5

-- Unpack the row strings once into a flat byte array for fast repeated lookup.
local cells = {}
do
    local n = data.size
    for gy = 0, n - 1 do
        local row = data.rows[gy + 1]
        local base = gy * n
        for gx = 0, n - 1 do
            cells[base + gx] = row:byte(gx + 1) - 48
        end
    end
end
G.cells = cells

function G.in_bounds(gx, gy)
    return gx >= 0 and gy >= 0 and gx < G.size and gy < G.size
end

function G.at(gx, gy)
    if not G.in_bounds(gx, gy) then return G.WATER end
    return cells[gy * G.size + gx] or G.WATER
end

function G.world_to_grid(p)
    if not p then return nil end
    local u = (G.xWest - (p.X or 0)) / SPAN_X
    local v = (G.yNorth - (p.Y or 0)) / SPAN_Y
    local gx = math.floor(u * G.size)
    local gy = math.floor(v * G.size)
    return gx, gy
end

function G.grid_to_world(gx, gy, z)
    local u = (gx + 0.5) / G.size
    local v = (gy + 0.5) / G.size
    return {
        X = G.xWest - u * SPAN_X,
        Y = G.yNorth - v * SPAN_Y,
        Z = z or 0,
    }
end

function G.classify(p)
    local gx, gy = G.world_to_grid(p)
    if not gx then return G.WATER end
    return G.at(gx, gy)
end

function G.is_passable(p)
    return G.classify(p) ~= G.WATER
end

function G.is_road(p)
    return G.classify(p) == G.ROAD
end

-- Walks the straight segment a->b and reports whether every sampled cell is
-- passable. This is the line-of-sight test the route smoother relies on.
function G.segment_passable(a, b, step)
    if not (a and b) then return false end
    local len = U.dist2d(a, b)
    step = step or (G.cell * 0.34)
    local n = math.max(1, math.ceil(len / step))
    if n > 2000 then n = 2000 end
    for i = 0, n do
        local t = i / n
        local x = a.X + (b.X - a.X) * t
        local y = a.Y + (b.Y - a.Y) * t
        local gx = math.floor((G.xWest - x) / SPAN_X * G.size)
        local gy = math.floor((G.yNorth - y) / SPAN_Y * G.size)
        if not G.in_bounds(gx, gy) then return false end
        if (cells[gy * G.size + gx] or 0) == G.WATER then return false end
    end
    return true
end

-- Nearest passable cell in an expanding ring search. Used to repair a
-- destination that landed in water or outside the playable area.
function G.nearest_passable(gx, gy, max_rings)
    max_rings = max_rings or 24
    if G.in_bounds(gx, gy) and G.at(gx, gy) ~= G.WATER then return gx, gy end
    for r = 1, max_rings do
        for dx = -r, r do
            for _, dy in ipairs({ -r, r }) do
                local nx, ny = gx + dx, gy + dy
                if G.in_bounds(nx, ny) and G.at(nx, ny) ~= G.WATER then return nx, ny end
            end
        end
        for dy = -r + 1, r - 1 do
            for _, dx in ipairs({ -r, r }) do
                local nx, ny = gx + dx, gy + dy
                if G.in_bounds(nx, ny) and G.at(nx, ny) ~= G.WATER then return nx, ny end
            end
        end
    end
    return nil
end

-- Snap any world point onto land, preserving Z.
function G.snap_to_land(p)
    if not p then return nil end
    if G.is_passable(p) then return p end
    local gx, gy = G.world_to_grid(p)
    if not gx then return nil end
    local nx, ny = G.nearest_passable(gx, gy)
    if not nx then return nil end
    local w = G.grid_to_world(nx, ny, p.Z)
    return w
end

-- Flood-fill landmass id per cell. Two points in different landmasses cannot
-- be connected on foot, which lets the router refuse impossible destinations
-- instead of grinding through a doomed A* search.
local landmass, landmass_size = nil, nil

local function build_landmass()
    landmass, landmass_size = {}, {}
    local n = G.size
    local id = 0
    local queue = {}
    for sy = 0, n - 1 do
        for sx = 0, n - 1 do
            local idx = sy * n + sx
            if cells[idx] ~= G.WATER and not landmass[idx] then
                id = id + 1
                local count = 0
                local head, tail = 1, 1
                queue[1] = idx
                landmass[idx] = id
                while head <= tail do
                    local cur = queue[head]; head = head + 1
                    count = count + 1
                    local cy = math.floor(cur / n)
                    local cx = cur - cy * n
                    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
                                         { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
                        local nx, ny = cx + d[1], cy + d[2]
                        if nx >= 0 and ny >= 0 and nx < n and ny < n then
                            local ni = ny * n + nx
                            if cells[ni] ~= G.WATER and not landmass[ni] then
                                landmass[ni] = id
                                tail = tail + 1
                                queue[tail] = ni
                            end
                        end
                    end
                end
                landmass_size[id] = count
            end
        end
    end
end

function G.landmass_at(p)
    if not landmass then build_landmass() end
    local gx, gy = G.world_to_grid(p)
    if not gx or not G.in_bounds(gx, gy) then return nil end
    return landmass[gy * G.size + gx]
end

function G.landmass_of_cell(gx, gy)
    if not landmass then build_landmass() end
    if not G.in_bounds(gx, gy) then return nil end
    return landmass[gy * G.size + gx]
end

function G.same_landmass(a, b)
    local la, lb = G.landmass_at(a), G.landmass_at(b)
    if not la or not lb then return false end
    return la == lb
end

return G
