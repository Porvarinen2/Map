-- Sector grid and reserved areas.
--
-- The map is a 5x5 lettered grid. Two areas get their own reserved population
-- per the guide: the C0 radiation area (three radiation groups) and the Z4
-- island town (two resident groups). Ordinary groups are kept out of them.
local Grid = require("world.navgrid")

local Z = {}

Z.ROWS = { "D", "C", "B", "A", "Z" }
Z.COLS = { "4", "3", "2", "1", "0" }

local SPAN_X = Grid.xWest - Grid.xEast
local SPAN_Y = Grid.yNorth - Grid.ySouth

function Z.uv(pos)
    return (Grid.xWest - (pos.X or 0)) / SPAN_X,
           (Grid.yNorth - (pos.Y or 0)) / SPAN_Y
end

function Z.sector(pos)
    local u, v = Z.uv(pos)
    if u < 0 or u >= 1 or v < 0 or v >= 1 then return "OUT" end
    return Z.ROWS[math.floor(v * 5) + 1] .. Z.COLS[math.floor(u * 5) + 1]
end

-- Bounding box of a sector in world coordinates.
function Z.sector_bounds(name)
    local row, col = name:sub(1, 1), name:sub(2, 2)
    local ri, ci
    for i, r in ipairs(Z.ROWS) do if r == row then ri = i - 1 end end
    for i, c in ipairs(Z.COLS) do if c == col then ci = i - 1 end end
    if not (ri and ci) then return nil end
    local u0, u1 = ci / 5, (ci + 1) / 5
    local v0, v1 = ri / 5, (ri + 1) / 5
    return {
        xMax = Grid.xWest - u0 * SPAN_X,
        xMin = Grid.xWest - u1 * SPAN_X,
        yMax = Grid.yNorth - v0 * SPAN_Y,
        yMin = Grid.yNorth - v1 * SPAN_Y,
    }
end

Z.RESERVED = {
    -- Exclusive: the radiation squads never leave C0 and nobody else enters.
    { sector = "C0", class = "radiation_group", groups = 5, exclusive = true,
      fi = "Sateilyalue", key = "RADIATION" },
    { sector = "Z4", class = "island_residents", groups = 2,
      fi = "Saarikaupunki", key = "ISLAND" },
}

Z.reserved_by_sector = {}
for _, r in ipairs(Z.RESERVED) do Z.reserved_by_sector[r.sector] = r end

-- Route fences for the exclusive zones: one to keep the zone's own groups
-- in, one to keep everybody else out.
for _, r in ipairs(Z.RESERVED) do
    if r.exclusive then
        local bx = Z.sector_bounds(r.sector)
        r.fence_in = { xMin = bx.xMin, xMax = bx.xMax, yMin = bx.yMin, yMax = bx.yMax,
                       inside = true, sector = r.sector }
        r.fence_out = { xMin = bx.xMin, xMax = bx.xMax, yMin = bx.yMin, yMax = bx.yMax,
                        inside = false, sector = r.sector }
    end
end

function Z.fence_for(group)
    for _, r in ipairs(Z.RESERVED) do
        if r.exclusive then
            return (group.class == r.class) and r.fence_in or r.fence_out
        end
    end
    return nil
end

-- True when the group stands where its fence allows.
function Z.on_right_side(group, pos)
    local f = Z.fence_for(group)
    pos = pos or group.position
    if not (f and pos) then return true end
    local inside = pos.X >= f.xMin and pos.X <= f.xMax and pos.Y >= f.yMin and pos.Y <= f.yMax
    return inside == f.inside
end

function Z.reserved_at(pos)
    return Z.reserved_by_sector[Z.sector(pos)]
end

-- A random passable point inside a sector, or nil if the sector is all water.
function Z.random_point_in(name, rng, tries)
    local b = Z.sector_bounds(name)
    if not b then return nil end
    tries = tries or 120
    for _ = 1, tries do
        local p = {
            X = (rng and rng:range(b.xMin, b.xMax)) or (b.xMin + math.random() * (b.xMax - b.xMin)),
            Y = (rng and rng:range(b.yMin, b.yMax)) or (b.yMin + math.random() * (b.yMax - b.yMin)),
            Z = 0,
        }
        if Grid.is_passable(p) then return p end
    end
    return nil
end

-- Largest landmass inside a sector, used to keep island residents on their
-- island rather than the nearest mainland shore.
function Z.dominant_landmass(name)
    local b = Z.sector_bounds(name)
    if not b then return nil end
    local counts = {}
    local steps = 40
    for i = 0, steps do
        for j = 0, steps do
            local p = {
                X = b.xMin + (b.xMax - b.xMin) * i / steps,
                Y = b.yMin + (b.yMax - b.yMin) * j / steps,
                Z = 0,
            }
            local m = Grid.landmass_at(p)
            if m then counts[m] = (counts[m] or 0) + 1 end
        end
    end
    local best, best_n = nil, 0
    for m, n in pairs(counts) do
        if n > best_n then best, best_n = m, n end
    end
    return best, best_n
end

return Z
