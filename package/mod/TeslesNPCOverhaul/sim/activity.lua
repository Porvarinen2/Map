-- What a group is doing, and where it is going.
--
-- A group runs a small state machine: pick a goal, travel to it, do something
-- there for a while, rest, pick again. The point of the design is that the
-- goal is chosen ONCE and held. Nothing re-rolls the destination while the
-- group is on the way, which is what makes travel read as purposeful.
local U = require("core.util")
local RNG = require("core.rng")
local POI = require("world.pois")
local Grid = require("world.navgrid")
local Zones = require("world.zones")
local GroupClasses = require("npc.groups")
local Tr = require("npc.trauma")

local A = {}

A.STATES = {
    IDLE = "IDLE", TRAVEL = "TRAVEL", SEARCH = "SEARCH", HUNT = "HUNT",
    CAMP = "CAMP", PATROL = "PATROL", REST = "REST", HOLD = "HOLD",
    COMBAT = "COMBAT", RETREAT = "RETREAT",
}

A.fi = {
    IDLE = "Odottaa", TRAVEL = "Matkalla", SEARCH = "Tutkii rakennuksia",
    HUNT = "Metsastaa", CAMP = "Leiriytyy", PATROL = "Partioi",
    REST = "Lepaa", HOLD = "Vartioi aluetta", COMBAT = "Taistelee",
    RETREAT = "Vetaytyy",
}

A.tuning = {
    travel_min = 120000,          -- shortest worthwhile journey (1.2 km)
    travel_max = 1200000,
    search_min_sec = 420,
    search_max_sec = 1500,
    hunt_min_sec = 240,
    hunt_max_sec = 720,
    camp_min_sec = 300,
    camp_max_sec = 1200,
    patrol_min_sec = 300,
    patrol_max_sec = 900,
    rest_min_sec = 120,
    rest_max_sec = 480,
    hold_min_sec = 300,
    hold_max_sec = 1200,
    stop_min_sec = 25,
    stop_max_sec = 75,
    visit_memory_sec = 10800,     -- 3 h before a place is interesting again
    max_visits = 40,
    fatigue_travel_per_min = 0.62,
    fatigue_rest_per_min = 4.2,
    rest_threshold = 72,
    supply_use_per_min = 0.22,
    supply_recovery_per_min = 1.6,
}

-- Kinds that a group actually searches buildings in.
local SEARCHABLE = {
    VILLAGE = true, TOWN = true, CITY = true, SETTLEMENT = true,
    MILITARY = true, BUNKER = true, INDUSTRIAL = true,
}
local HUNTABLE = { HUNTING = true, WILDERNESS = true }
local CAMPABLE = { SHORE = true, WILDERNESS = true, HUNTING = true }

function A.new_state(seed)
    return {
        state = A.STATES.IDLE,
        goal_poi = nil,
        until_t = 0,
        fatigue = 0,
        supply = 100,
        visited = {},
        history = {},
        rng = RNG.new(seed or os.time()),
        journeys = 0,
        distance = 0,
        searched = 0,
    }
end

local function note(act, text)
    act.history[#act.history + 1] = { t = os.time(), text = text }
    if #act.history > 12 then table.remove(act.history, 1) end
end
A.note = note

-- Exploration drive across a group's living members biases how far it ranges.
local function wanderlust(group)
    local sum, n = 0, 0
    for _, m in ipairs(group.members) do
        if m.alive then
            sum = sum + Tr.trait(m, "explorationDrive") * 0.6
                + Tr.trait(m, "curiosity") * 0.4
            n = n + 1
        end
    end
    if n == 0 then return 0.5 end
    return sum / n
end

local function homesickness(group)
    local sum, n = 0, 0
    for _, m in ipairs(group.members) do
        if m.alive then
            sum = sum + Tr.trait(m, "homeAttachment") * 0.5
                + Tr.trait(m, "territoriality") * 0.5
            n = n + 1
        end
    end
    if n == 0 then return 0.5 end
    return sum / n
end

-- Picks the next destination for a group.
function A.choose_destination(group, act, now)
    local cls = GroupClasses.get(group.class)
    if not cls then return nil end
    local pos = group.position
    if not pos then return nil end

    local wander = wanderlust(group)
    local home = homesickness(group)
    local t = A.tuning

    local max_d = t.travel_min + (t.travel_max - t.travel_min) * (0.25 + wander * 0.75)
    if group.home_bound then max_d = math.min(max_d, 420000) end

    -- Reserved sectors: their own groups stay inside, everyone else stays out.
    local res = Zones.reserved_by_sector
    local allow = function(poi)
        local r = res[poi.sector]
        if r then return r.class == group.class end
        if group.home_bound and group.home then
            return U.dist2d(group.home, poi.pos) <= 520000
        end
        return true
    end

    local bias = function(poi)
        local b = 1.0
        if group.home and home > 0.55 then
            -- Homebodies weight destinations near their anchor.
            local d = U.dist2d(group.home, poi.pos)
            b = b * (1.0 + (home - 0.5) * 1.6 / (1 + d / 300000))
        end
        return b
    end

    local poi = POI.choose({
        from = pos,
        weights = cls.poi_weights,
        visited = act.visited,
        now = now,
        rng = act.rng,
        min_distance = t.travel_min * 0.35,
        max_distance = max_d,
        avoid_id = act.goal_poi and act.goal_poi.id or nil,
        allow = allow,
        bias = bias,
        visit_memory = t.visit_memory_sec,
    })
    if not poi then
        -- Nothing weighted matched: fall back to anything reachable nearby.
        poi = POI.choose({
            from = pos, weights = { VILLAGE = 1, TOWN = 1, WILDERNESS = 1,
                                     SHORE = 1, JUNCTION = 1, SETTLEMENT = 1 },
            visited = act.visited, now = now, rng = act.rng,
            min_distance = 40000, max_distance = 500000, allow = allow,
        })
    end
    return poi
end

-- Activity to run once the group arrives at a POI.
function A.activity_for(poi, group, act)
    if not poi then return A.STATES.CAMP end
    local r = act.rng
    if group.home_bound and group.home
        and U.dist2d(group.home, poi.pos) < 120000 and r:chance(0.35) then
        return A.STATES.HOLD
    end
    if SEARCHABLE[poi.kind] then
        if poi.kind == "MILITARY" or poi.kind == "BUNKER" then
            return r:chance(0.75) and A.STATES.SEARCH or A.STATES.PATROL
        end
        return r:chance(0.78) and A.STATES.SEARCH or A.STATES.PATROL
    end
    if HUNTABLE[poi.kind] then
        return r:chance(0.68) and A.STATES.HUNT or A.STATES.CAMP
    end
    if poi.kind == "JUNCTION" then
        return r:chance(0.6) and A.STATES.PATROL or A.STATES.CAMP
    end
    if CAMPABLE[poi.kind] then return A.STATES.CAMP end
    return A.STATES.PATROL
end

function A.duration_for(state, act)
    local t, r = A.tuning, act.rng
    if state == A.STATES.REST then
        -- Rest long enough to actually be rested. A fixed-length nap left
        -- groups permanently exhausted and never able to travel far.
        local need = math.max(0, (act.fatigue or 0) - 18) / t.fatigue_rest_per_min * 60
        return U.clamp(need, t.rest_min_sec, 2400)
    end
    if state == A.STATES.SEARCH then return r:range(t.search_min_sec, t.search_max_sec) end
    if state == A.STATES.HUNT then return r:range(t.hunt_min_sec, t.hunt_max_sec) end
    if state == A.STATES.CAMP then return r:range(t.camp_min_sec, t.camp_max_sec) end
    if state == A.STATES.PATROL then return r:range(t.patrol_min_sec, t.patrol_max_sec) end
    if state == A.STATES.HOLD then return r:range(t.hold_min_sec, t.hold_max_sec) end
    return 300
end

function A.mark_visited(act, poi, now)
    if not poi then return end
    act.visited[poi.id] = now
    local n = 0
    for _ in pairs(act.visited) do n = n + 1 end
    if n > A.tuning.max_visits then
        local oldest, oldest_t = nil, math.huge
        for id, t in pairs(act.visited) do
            if t < oldest_t then oldest, oldest_t = id, t end
        end
        if oldest then act.visited[oldest] = nil end
    end
end

-- Fatigue and abstract supply. Neither is an inventory claim; they are
-- planning values that decide when a group stops to rest.
function A.tick_upkeep(act, dt, moving)
    local t = A.tuning
    local minutes = dt / 60
    if moving then
        act.fatigue = U.clamp(act.fatigue + t.fatigue_travel_per_min * minutes, 0, 100)
        act.supply = U.clamp(act.supply - t.supply_use_per_min * minutes, 0, 100)
    else
        act.fatigue = U.clamp(act.fatigue - t.fatigue_rest_per_min * minutes, 0, 100)
        act.supply = U.clamp(act.supply + t.supply_recovery_per_min * minutes, 0, 100)
    end
end

function A.needs_rest(act)
    return act.fatigue >= A.tuning.rest_threshold
end

-- Builds an ordered tour of stops around a POI.
--
-- Picking a fresh random point every time a group finishes one produced
-- exactly the back-and-forth the overhaul is meant to remove. Instead the
-- stops are laid out once as a loop around the centre and walked in order, so
-- a squad working a village crosses it systematically and then leaves.
function A.build_tour(poi, act, spread, count)
    local r = act.rng
    local radius = spread or poi.radius or 9000
    count = count or r:int(4, 8)
    local start = r:float() * math.pi * 2
    local dir = r:chance(0.5) and 1 or -1
    local stops = {}
    for i = 1, count do
        local ang = start + dir * (i - 1) * (2 * math.pi / count)
            + (r:float() - 0.5) * 0.45
        local dist = radius * (0.35 + 0.6 * r:float())
        local p = {
            X = poi.pos.X + math.cos(ang) * dist,
            Y = poi.pos.Y + math.sin(ang) * dist,
            Z = poi.pos.Z,
        }
        if not Grid.is_passable(p) then p = Grid.snap_to_land(p) end
        if p then
            p.Z = poi.pos.Z
            stops[#stops + 1] = p
        end
    end
    if #stops == 0 then stops[1] = U.copy_vec(poi.pos) end
    act.tour = stops
    act.tour_index = 0
    act.tour_poi = poi.id
    return stops
end

-- Next stop on the tour, rebuilding it when the POI changed or the loop is
-- finished. Always on land.
function A.next_stop(poi, act, spread)
    if not poi then return nil end
    if not act.tour or act.tour_poi ~= poi.id or (act.tour_index or 0) >= #act.tour then
        A.build_tour(poi, act, spread)
    end
    act.tour_index = (act.tour_index or 0) + 1
    return U.copy_vec(act.tour[act.tour_index])
end

function A.describe(group, act)
    local s = act.state
    local label = A.fi[s] or s
    if act.goal_poi then
        if s == A.STATES.TRAVEL then
            return label .. ": " .. act.goal_poi.label
        end
        return label .. " (" .. act.goal_poi.label .. ")"
    end
    return label
end

return A
