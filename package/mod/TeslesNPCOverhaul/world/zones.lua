-- Sector grid and reserved areas.
--
-- The map is a 5x5 lettered grid. Two areas get their own reserved population:
-- the C0 radiation sector (five radiation squads) and the island town in the
-- south-west of Z4 (two resident squads, the whole island). Both are
-- exclusive: their squads never leave and nobody else goes in.
local Grid = require("world.navgrid")
local POI = require("world.pois")

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
    -- The island is the landmass of its town (VIL_Z4_01); up to 1.9.4 the zone
    -- was "the biggest landmass in Z4", which is a piece of the mainland, so
    -- the residents lived there and never on the island. Water keeps both
    -- sides apart: no route crosses from one landmass to another.
    { sector = "Z4", class = "island_residents", groups = 2, exclusive = true,
      town = "VIL_Z4_01", fi = "Saarikaupunki", key = "ISLAND" },
}

Z.reserved_by_sector = {}
Z.reserved_by_class = {}
for _, r in ipairs(Z.RESERVED) do
    Z.reserved_by_class[r.class] = r
    if r.town then
        local t = POI.by_id[r.town]
        r.anchor = t and t.pos
        r.landmass = t and t.landmass
    else
        Z.reserved_by_sector[r.sector] = r
    end
end

-- The reserved zone a point belongs to: a whole sector (C0) or an island.
function Z.reserved_at(pos)
    if not pos then return nil end
    local r = Z.reserved_by_sector[Z.sector(pos)]
    if r then return r end
    for _, z in ipairs(Z.RESERVED) do
        if z.landmass and z.sector == Z.sector(pos) and Grid.landmass_at(pos) == z.landmass then return z end
    end
    return nil
end
function Z.reserved_for_poi(poi)
    if not poi then return nil end
    local r = Z.reserved_by_sector[poi.sector]
    if r then return r end
    for _, z in ipairs(Z.RESERVED) do
        if z.landmass and poi.landmass == z.landmass then return z end
    end
    return nil
end
function Z.in_zone(r, pos)
    return pos ~= nil and Z.reserved_at(pos) == r
end

-- A random point for a zone's squad: anywhere in a sector zone, around the
-- town of an island zone.
function Z.zone_point(r, rng)
    if r.anchor then
        for _ = 1, 200 do
            local a = (rng and rng:range(0, 2 * math.pi)) or math.random() * 2 * math.pi
            local d = (rng and rng:range(0, 14000)) or math.random() * 14000
            local p = { X = r.anchor.X + math.cos(a) * d, Y = r.anchor.Y + math.sin(a) * d, Z = 0 }
            if Grid.is_passable(p) and Grid.landmass_at(p) == r.landmass then return p end
        end
        return { X = r.anchor.X, Y = r.anchor.Y, Z = 0 }
    end
    return Z.random_point_in(r.sector, rng)
end

-- Route fences for the sector zones: one to keep the zone's own groups in,
-- one to keep everybody else out (islands need none: water does it).
for _, r in ipairs(Z.RESERVED) do
    if r.exclusive and not r.town then
        local bx = Z.sector_bounds(r.sector)
        r.fence_in = { xMin = bx.xMin, xMax = bx.xMax, yMin = bx.yMin, yMax = bx.yMax,
                       inside = true, sector = r.sector }
        r.fence_out = { xMin = bx.xMin, xMax = bx.xMax, yMin = bx.yMin, yMax = bx.yMax,
                        inside = false, sector = r.sector }
    end
end

function Z.fence_for(group)
    local own = Z.reserved_by_class[group.class]
    if own and own.fence_in then return own.fence_in end
    for _, r in ipairs(Z.RESERVED) do
        if r.fence_out then return r.fence_out end
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
