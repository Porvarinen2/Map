-- Point-of-interest queries. POIs are generated from the map image
-- (settlements, wilderness, shoreline, junctions) plus hand-verified
-- landmarks, and carry a kind that group classes weight differently.
local U = require("core.util")
local Grid = require("world.navgrid")

local P = {}
local data = require("world.poi_data")

P.points = {}
P.by_id = {}
P.by_kind = {}
P.by_sector = {}

for _, p in ipairs(data.points) do
    local poi = {
        id = p.id, label = p.label, sector = p.sector, kind = p.kind,
        pos = { X = p.x, Y = p.y, Z = 0 },
        weight = p.weight or 1.0,
        radius = p.radius or 9000,
    }
    -- A few landmarks (a naval base, coastal bunkers) sit on a nav cell the
    -- coarse grid calls water. Snap them ashore so nothing is ever sent to a
    -- destination it cannot legally stand on.
    if not Grid.is_passable(poi.pos) then
        local snapped = Grid.snap_to_land(poi.pos)
        if snapped then
            poi.pos = snapped
            poi.snapped = true
        end
    end
    poi.landmass = Grid.landmass_at(poi.pos)
    P.points[#P.points + 1] = poi
    P.by_id[poi.id] = poi
    P.by_kind[poi.kind] = P.by_kind[poi.kind] or {}
    table.insert(P.by_kind[poi.kind], poi)
    P.by_sector[poi.sector] = P.by_sector[poi.sector] or {}
    table.insert(P.by_sector[poi.sector], poi)
end

-- The Z4 island town has one marked place: a few streets around it are
-- added so its residents walk the town instead of standing on one spot.
local TOWN_SPOTS = {
    { anchor = "VIL_Z4_01", prefix = "ISL_Z4_", label = "Saarikaupunki", n = 7, radius = 30000, spacing = 9000 },
}
for _, t in ipairs(TOWN_SPOTS) do
    local a = P.by_id[t.anchor]
    if a and a.landmass then
        local seed, made, tries = 12345, 0, 0
        local function rnd()
            seed = (seed * 1103515245 + 12345) % 2147483648
            return seed / 2147483648
        end
        local placed = { a.pos }
        while made < t.n and tries < 600 do
            tries = tries + 1
            local ang, d = rnd() * 2 * math.pi, 2500 + rnd() * (t.radius - 2500)
            local p = { X = a.pos.X + math.cos(ang) * d, Y = a.pos.Y + math.sin(ang) * d, Z = 0 }
            local ok = Grid.is_passable(p) and Grid.landmass_at(p) == a.landmass
            for _, q in ipairs(placed) do
                if ok and U.dist2d(p, q) < t.spacing then ok = false end
            end
            if ok then
                made = made + 1
                placed[#placed + 1] = p
                local poi = { id = t.prefix .. made, label = t.label .. " " .. made, sector = a.sector,
                              kind = a.kind, pos = p, weight = a.weight, radius = 4000,
                              landmass = a.landmass, town_spot = true }
                P.points[#P.points + 1] = poi
                P.by_id[poi.id] = poi
                table.insert(P.by_kind[poi.kind], poi)
                table.insert(P.by_sector[poi.sector], poi)
            end
        end
    end
end

P.count = #P.points

-- Trader outposts are safe zones: nobody armed belongs there. They stay in
-- the data so the live map can show them, but nothing picks them, or anything
-- within OUTPOST_MARGIN of them, as a destination.
P.outposts = P.by_kind.OUTPOST or {}
P.OUTPOST_MARGIN = 45000
function P.near_outpost(pos, margin)
    margin = margin or P.OUTPOST_MARGIN
    for _, o in ipairs(P.outposts) do
        if U.dist2d(pos, o.pos) < (o.radius or 0) + margin then return o end
    end
    return nil
end
for _, poi in ipairs(P.points) do
    poi.blocked = poi.kind == "OUTPOST" or (P.near_outpost(poi.pos) ~= nil)
end

-- Spatial buckets for nearest lookups.
local BUCKET = 60000
local buckets = {}
for _, poi in ipairs(P.points) do
    local k = math.floor(poi.pos.X / BUCKET) .. ":" .. math.floor(poi.pos.Y / BUCKET)
    buckets[k] = buckets[k] or {}
    table.insert(buckets[k], poi)
end

function P.kinds()
    local out = {}
    for k in pairs(P.by_kind) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- Weighted selection for a group: the class's POI weights, scaled down by
-- distance and by how recently this group visited the place, so a squad does
-- not keep circling the same village.
function P.choose(opts)
    local from = opts.from
    local weights = opts.weights or {}
    local visited = opts.visited or {}
    local now = opts.now or os.time()
    local rng = opts.rng
    local min_d = opts.min_distance or 0
    local max_d = opts.max_distance or math.huge
    local mass = from and Grid.landmass_at(from) or nil
    local exclude = opts.exclude
    local allow = opts.allow

    local pool = {}
    for _, poi in ipairs(P.points) do
        local w = weights[poi.kind]
        if w and w > 0 then
            local ok = true
            if exclude and exclude(poi) then ok = false end
            if ok and allow and not allow(poi) then ok = false end
            if ok and mass and poi.landmass and poi.landmass ~= mass then ok = false end
            if ok and opts.avoid_id and poi.id == opts.avoid_id then ok = false end
            if ok then
                local d = from and U.dist2d(from, poi.pos) or 1
                if d >= min_d and d <= max_d then
                    -- Distance falloff: reachable but not always the nearest.
                    local dw = 1.0 / (1.0 + (d / 260000) ^ 1.45)
                    local vis = visited[poi.id]
                    local vw = 1.0
                    if vis then
                        local age = now - vis
                        local memory = opts.visit_memory or 10800
                        if age < memory then
                            vw = 0.12 + 0.88 * (age / memory)
                        end
                    end
                    pool[#pool + 1] = {
                        poi = poi,
                        weight = w * poi.weight * dw * vw
                            * (opts.bias and opts.bias(poi) or 1.0),
                    }
                end
            end
        end
    end
    if #pool == 0 then return nil end
    local pick = U.weighted_pick(pool, rng)
    return pick and pick.poi or nil
end

return P
