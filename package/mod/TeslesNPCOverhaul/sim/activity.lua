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
local SweepData = require("world.c0_sweep")

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

-- Kinds a group searches buildings in, and how long it stays to loot one.
local SEARCHABLE = {
    VILLAGE = true, CITY = true, MILITARY = true, BUNKER = true,
    ABANDONED_BUNKER = true, RESEARCH = true, INDUSTRIAL = true, MEDICAL = true,
}
local HUNTABLE = { HUNTING = true }
local CAMPABLE = { LANDMARK = true, HUNTING = true }

-- Seconds spent working a place, by kind: a city takes a squad the best part
-- of an hour to go through, a hunting tower a few minutes.
A.DWELL = {
    CITY = { 1500, 2400 }, VILLAGE = { 480, 900 }, MILITARY = { 720, 1320 },
    BUNKER = { 600, 1080 }, ABANDONED_BUNKER = { 600, 1080 }, RESEARCH = { 600, 1080 },
    INDUSTRIAL = { 480, 840 }, MEDICAL = { 480, 840 }, LANDMARK = { 180, 420 },
    HUNTING = { 240, 540 },
}

A.QUEUE_LENGTH = 3      -- destinations planned ahead, shown on the live map
A.MEMORY = 10           -- places a group will not return to until 10 others

function A.new_state(seed)
    return {
        state = A.STATES.IDLE,
        goal_poi = nil,
        until_t = 0,
        fatigue = 0,
        supply = 100,
        visited = {},
        queue = {},
        recent = {},
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

-- Where a group may go at all: its class must care about the kind, the place
-- must not be an outpost, reserved sectors keep their own groups in and
-- everyone else out, and home-bound groups stay near home.
local function eligible(group, cls, poi)
    if poi.blocked then return false end
    local w = cls.poi_weights[poi.kind]
    if not w or w <= 0 then return false end
    local r = Zones.reserved_for_poi(poi)
    if r then return r.class == group.class end
    -- A zone's own squads go nowhere outside it.
    if Zones.reserved_by_class[group.class] then return false end
    if group.home_bound and group.home then
        return U.dist2d(group.home, poi.pos) <= 520000
    end
    return true
end

local function contains(list, id)
    for _, v in ipairs(list or {}) do if v == id then return true end end
    return false
end

-- How many places a group remembers: ten by default, fewer for a class that
-- works a small fixed circuit (the radiation squads remember two).
function A.memory_of(group)
    local cls = group and GroupClasses.get(group.class)
    return (cls and cls.memory) or A.MEMORY
end

-- The places a group has been and will be, oldest first: what it remembers,
-- then its current goal, then what is queued. A place is blocked for the next
-- pick while it is among the last `memory` entries of this walk, so "no
-- return until ten others" also holds across the planned queue.
local function planned_walk(act, extra)
    local seq = {}
    for _, id in ipairs(act.recent or {}) do seq[#seq + 1] = id end
    local goal = act.goal_poi and act.goal_poi.id
    if goal and seq[#seq] ~= goal then seq[#seq + 1] = goal end
    if act.pending_goal and seq[#seq] ~= act.pending_goal.id then
        seq[#seq + 1] = act.pending_goal.id
    end
    if extra and seq[#seq] ~= extra.id then seq[#seq + 1] = extra.id end
    for _, id in ipairs(act.queue or {}) do seq[#seq + 1] = id end
    return seq
end

local function blocked_set(seq, memory)
    local out = {}
    for i = math.max(1, #seq - memory + 1), #seq do out[seq[i]] = true end
    return out
end
A._planned_walk, A._blocked_set = planned_walk, blocked_set

local DANGEROUS = { CITY = true, MILITARY = true, INDUSTRIAL = true, RESEARCH = true,
                    BUNKER = true, ABANDONED_BUNKER = true }

-- 1 for a calm squad, down to 0.25 for a terrified or zombie-scarred one.
function A.fear_factor(group)
    local sum, n, scars = 0, 0, 0
    for _, m in ipairs(group.members or {}) do
        if m.alive then
            sum = sum + (m.stress or 0)
            n = n + 1
            if m.traumas and (m.traumas.ZOMBIE_TRAUMA or m.traumas.COMBAT_AVERSE) then scars = scars + 1 end
        end
    end
    if n == 0 then return 1 end
    local s = sum / n
    local f = 1 - math.max(0, s - 0.3) * 1.2 - (scars / n) * 0.3
    return U.clamp(f, 0.25, 1)
end

-- Next place after `from`: the nearest places the class cares about win.
-- Distance dominates - (1 + d/0.9 km)^2 - so a group works its way across
-- the island neighbourhood by neighbourhood instead of criss-crossing it; the
-- class weight decides between places at similar distance, and a little
-- randomness among the best three keeps two identical groups from marching
-- in lockstep. A class with a fixed circuit walks it in order instead.
function A.pick_next(group, act, from, blocked, last_id)
    local cls = GroupClasses.get(group.class)
    if not (cls and from) then return nil end
    blocked = blocked or {}
    if cls.circuit then
        local n = #cls.circuit
        -- Without a last place the squad joins the circuit anywhere, so five
        -- squads do not all start with the same place.
        local at = act.rng and act.rng:int(0, n - 1) or 0
        for i, id in ipairs(cls.circuit) do if id == last_id then at = i end end
        for k = 1, n do
            local id = cls.circuit[(at + k - 1) % n + 1]
            local poi = POI.by_id[id]
            if poi and not blocked[id] and eligible(group, cls, poi) then return poi end
        end
        return nil
    end
    -- Places are judged by the land the group stands on: a queued place on
    -- an islet must not make every later pick impossible.
    local mass = Grid.landmass_at(group.position or from)
    local fear = A.fear_factor(group)
    local scored = {}
    for _, poi in ipairs(POI.points) do
        if eligible(group, cls, poi)
            and not blocked[poi.id]
            and (not mass or not poi.landmass or poi.landmass == mass) then
            local d = U.dist2d(from, poi.pos)
            if d > 6000 then
                local w = cls.poi_weights[poi.kind] * (poi.weight or 1)
                -- A frightened squad steers clear of the places where the
                -- dead are thickest and the fighting is.
                if DANGEROUS[poi.kind] then w = w * fear end
                scored[#scored + 1] = { poi = poi, score = w / (1 + d / 90000) ^ 2 }
            end
        end
    end
    if #scored == 0 then return nil end
    table.sort(scored, function(x, y) return x.score > y.score end)
    local top = {}
    for i = 1, math.min(3, #scored) do
        top[i] = { poi = scored[i].poi, weight = scored[i].score }
    end
    local pick = U.weighted_pick(top, act.rng)
    return pick and pick.poi or scored[1].poi
end

-- Keeps A.QUEUE_LENGTH places planned ahead. Each is chosen from the one
-- before it, so the queue is a sensible walk, not three unrelated picks.
function A.refill_queue(group, act, heading_to)
    act.queue = act.queue or {}
    act.recent = act.recent or {}
    -- Places that stopped being valid (a changed map, a reserved sector)
    -- are dropped rather than walked to.
    local cls = GroupClasses.get(group.class)
    for i = #act.queue, 1, -1 do
        local poi = POI.by_id[act.queue[i]]
        if not (poi and cls and eligible(group, cls, poi)) then table.remove(act.queue, i) end
    end
    local memory = A.memory_of(group)
    -- A squad drawn off its plan (a player or zombies spotted, gunfire
    -- investigated) skips a planned place, and the places queued behind it
    -- move closer to where they were last: those now inside the memory are
    -- dropped and planned again.
    if not (cls and cls.reserved_zone) then
        local keep = {}
        for _, id in ipairs(act.queue) do
            local seq = planned_walk({ recent = act.recent, goal_poi = act.goal_poi,
                pending_goal = act.pending_goal, queue = keep }, heading_to)
            if not blocked_set(seq, memory)[id] then keep[#keep + 1] = id else break end
        end
        act.queue = keep
    end
    local guard = 0
    while #act.queue < A.QUEUE_LENGTH and guard < 6 do
        guard = guard + 1
        local seq = planned_walk(act, heading_to)
        local last = seq[#seq]
        local from = (last and POI.by_id[last] and POI.by_id[last].pos) or group.position
        local blocked = blocked_set(seq, memory)
        -- The place a leg starts from is never its own next stop.
        if last then blocked[last] = true end
        local poi = A.pick_next(group, act, from, blocked, last)
        if not poi and memory > 1 then
            -- A small territory can run out of places the memory allows.
            -- Then the oldest memories give way first.
            poi = A.pick_next(group, act, from,
                blocked_set(seq, math.max(1, math.floor(memory / 2))), last)
        end
        if not poi then break end
        act.queue[#act.queue + 1] = poi.id
    end
    return act.queue
end

-- The next destination is simply the head of the queue.
function A.choose_destination(group, act, now)
    A.refill_queue(group, act)
    local id = table.remove(act.queue, 1)
    local poi = id and POI.by_id[id] or nil
    -- The place just taken off the queue is not the goal yet, so it is
    -- named explicitly: without that it could be queued again behind itself.
    A.refill_queue(group, act, poi)
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
    -- Places with buildings are looted: the squad goes through them house by
    -- house. Hunting towers are hunted from, landmarks are a short stop.
    if SEARCHABLE[poi.kind] then return A.STATES.SEARCH end
    if HUNTABLE[poi.kind] then return A.STATES.HUNT end
    if CAMPABLE[poi.kind] then return r:chance(0.5) and A.STATES.PATROL or A.STATES.CAMP end
    return A.STATES.PATROL
end

function A.duration_for(state, act, poi)
    local t, r = A.tuning, act.rng
    local dw = poi and A.DWELL[poi.kind]
    if dw and (state == A.STATES.SEARCH or state == A.STATES.HUNT
               or state == A.STATES.PATROL or state == A.STATES.CAMP) then
        return r:range(dw[1], dw[2])
    end
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

function A.mark_visited(act, poi, now, group)
    if not poi then return end
    act.recent = act.recent or {}
    for i = #act.recent, 1, -1 do
        if act.recent[i] == poi.id then table.remove(act.recent, i) end
    end
    act.recent[#act.recent + 1] = poi.id
    while #act.recent > A.memory_of(group) do table.remove(act.recent, 1) end
    -- A place just visited is no longer the next plan.
    if act.queue and act.queue[1] == poi.id then table.remove(act.queue, 1) end
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
    -- A circuit: stops on a ring at nearly constant distance, walked in one
    -- direction. Random in-and-out distances made the squad zig-zag across
    -- the middle of a village on every leg.
    count = count or U.clamp(math.floor(radius / 3200), 4, 9)
    local start = r:float() * math.pi * 2
    local dir = r:chance(0.5) and 1 or -1
    local stops = {}
    for i = 1, count do
        local ang = start + dir * (i - 1) * (2 * math.pi / count)
            + (r:float() - 0.5) * 0.25
        local dist = radius * (0.58 + 0.16 * r:float())
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

-- ------------------------------------------------------------ city sweep --

-- Krsko is swept by the radiation squads area by area, 1 to 5 or 5 to 1,
-- each area lane by lane. When the last stop of the last area is walked the
-- city counts as visited and the squad moves on.
A.SWEEP_MAX_SEC = 4 * 3600
A.sweep = { city = SweepData.city, areas = {} }
for _, a in ipairs(SweepData.areas) do
    local pts = {}
    for _, p in ipairs(a.points) do
        local v = { X = p[1], Y = p[2], Z = 0 }
        if not Grid.is_passable(v) then v = Grid.snap_to_land(v) end
        if v then pts[#pts + 1] = v end
    end
    A.sweep.areas[#A.sweep.areas + 1] = { id = a.id, points = pts }
end

function A.sweeps(poi, group)
    return poi ~= nil and group ~= nil and poi.id == A.sweep.city
        and group.class == "radiation_group" and #A.sweep.areas > 0
end

-- Stops for the whole sweep in walking order. Each area is entered at the
-- end nearer to where the previous one finished, so lanes join up. The
-- order depends only on the direction, so a saved sweep resumes exactly.
function A.build_sweep(poi, act, dir)
    local order = {}
    for i = 1, #A.sweep.areas do order[i] = A.sweep.areas[i] end
    if dir < 0 then
        for i = 1, math.floor(#order / 2) do
            order[i], order[#order - i + 1] = order[#order - i + 1], order[i]
        end
    end
    local stops, areas = {}, {}
    local at = poi.pos
    for _, area in ipairs(order) do
        local pts = area.points
        if #pts > 0 then
            local fwd = U.dist2d(at, pts[1]) <= U.dist2d(at, pts[#pts])
            for k = 1, #pts do
                local p = pts[fwd and k or (#pts - k + 1)]
                stops[#stops + 1] = U.copy_vec(p)
                areas[#areas + 1] = area.id
            end
            at = stops[#stops]
        end
    end
    act.tour = stops
    act.tour_area = areas
    act.tour_poi = poi.id
    act.sweep_dir = dir
    return stops
end

-- Next stop on the tour, rebuilding it when the POI changed or the loop is
-- finished. Always on land. A sweep is not a loop: at its end this returns
-- nil and marks it done.
function A.next_stop(poi, act, spread)
    if not poi then return nil end
    if act.sweep_dir then
        if not act.tour or act.tour_poi ~= poi.id then
            local idx = act.tour_index or 0
            A.build_sweep(poi, act, act.sweep_dir)
            act.tour_index = idx
        end
        if (act.tour_index or 0) >= #act.tour then
            act.sweep_done = true
            return nil
        end
        act.tour_index = (act.tour_index or 0) + 1
        return U.copy_vec(act.tour[act.tour_index])
    end
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
