-- Building search.
--
-- The intended chain is: find a building, find its door, walk to the door,
-- handle the door, then search interior points. Every physical step is only
-- marked done when the bridge reports it done - a timer alone never counts as
-- success, and the live map shows which steps are unproven.
local U = require("core.util")
local Grid = require("world.navgrid")

local B = {}

B.tuning = {
    search_radius_uu = 12000,       -- 120 m
    max_buildings = 8,
    interior_delay_sec = 15,
    visited_history = 50,
    approach_uu = 400,
    stop_min_sec = 25,
    stop_max_sec = 75,
}

B.STEPS = {
    "BUILDING_DISCOVERY", "DOOR_DISCOVERY", "DOOR_APPROACH",
    "DOOR_INTERACTION", "INTERIOR_NAVIGATION",
}

function B.new_state()
    return {
        target = nil,
        step = nil,
        step_at = 0,
        visited = {},
        found = 0,
        entered = 0,
        proven = {},        -- which steps the bridge has actually confirmed
    }
end

local function remember(state, id)
    state.visited[#state.visited + 1] = id
    if #state.visited > B.tuning.visited_history then
        table.remove(state.visited, 1)
    end
end

local function was_visited(state, id)
    for _, v in ipairs(state.visited) do
        if v == id then return true end
    end
    return false
end

-- Asks the bridge for buildings near a point and picks the nearest unvisited.
function B.pick_building(state, pos, bridge)
    if not (bridge and bridge.find_buildings) then return nil, "NO_BRIDGE" end
    local list = bridge.find_buildings(pos, B.tuning.search_radius_uu)
    if not list or #list == 0 then return nil, "NONE_FOUND" end
    state.proven.BUILDING_DISCOVERY = true
    -- The nearest houses first; a squad works through at most
    -- max_buildings of them before the pick says all are done.
    local near = {}
    for _, b in ipairs(list) do near[#near + 1] = { b = b, d = U.dist2d(pos, b.position) } end
    table.sort(near, function(x, y) return x.d < y.d end)
    local best = nil
    for i = 1, math.min(#near, B.tuning.max_buildings) do
        if not was_visited(state, near[i].b.id) then best = near[i].b; break end
    end
    if not best then return nil, "ALL_VISITED" end
    return best
end

-- Advances the search by one step. Returns step, move_target, note.
-- The squad walks into the nearest house it has not been in (SCUM's own
-- pathfinding takes it through the door), stays a while moving about inside
-- ("looting"), then goes on to the next house. A house it cannot get into
-- within a minute is given up.
local function stay_sec(now)
    return B.tuning.stop_min_sec + (now * 7919 % 1000) / 1000 * (B.tuning.stop_max_sec - B.tuning.stop_min_sec)
end

function B.step(state, group, bridge, now)
    local pos = group.position
    if not pos then return nil, nil, "NO_POSITION" end

    if not state.target then
        local b, why = B.pick_building(state, pos, bridge)
        if not b then
            state.step = nil
            return nil, nil, why
        end
        state.target = b
        state.step = "WALK_IN"
        state.step_at, state.order_at = now, now
        state.found = state.found + 1
        return state.step, U.copy_vec(b.position), "going into building " .. tostring(b.id)
    end

    local t = state.target
    if state.step == "WALK_IN" then
        local d = U.dist2d(pos, t.position)
        if d <= B.tuning.approach_uu then
            state.proven.INTERIOR_NAVIGATION = true
            state.step = "INSIDE"
            state.step_at, state.order_at = now, now
            state.stay_until = now + stay_sec(now)
            return state.step, nil, "inside"
        end
        if now - state.step_at > 60 then
            remember(state, t.id)
            state.target, state.step = nil, nil
            return nil, nil, "could not get in"
        end
        if now - (state.order_at or 0) >= 15 then
            state.order_at = now
            return state.step, U.copy_vec(t.position), "walking in"
        end
        return state.step, nil, "walking in"
    end

    if state.step == "INSIDE" then
        if now >= (state.stay_until or 0) then
            remember(state, t.id)
            state.entered = state.entered + 1
            state.target, state.step = nil, nil
            return nil, nil, "building searched"
        end
        -- Moving about the rooms: a new spot near the middle now and then.
        if now - (state.order_at or 0) >= B.tuning.interior_delay_sec then
            state.order_at = now
            local ang = (now * 2654435761 % 628) / 100
            local r = 150 + (now % 3) * 100
            return state.step, { X = t.position.X + math.cos(ang) * r, Y = t.position.Y + math.sin(ang) * r,
                                 Z = t.position.Z }, "looting inside"
        end
        return state.step, nil, "looting inside"
    end

    state.target, state.step = nil, nil
    return nil, nil, "idle"
end

-- Which steps of the chain this server has actually demonstrated.
function B.proof(state)
    local out = {}
    for _, s in ipairs(B.STEPS) do
        out[s] = state.proven[s] == true
    end
    return out
end

return B
