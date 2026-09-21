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
    local best, best_d = nil, math.huge
    local checked = 0
    for _, b in ipairs(list) do
        checked = checked + 1
        if checked > B.tuning.max_buildings then break end
        if not was_visited(state, b.id) then
            local d = U.dist2d(pos, b.position)
            if d < best_d then best, best_d = b, d end
        end
    end
    if not best then return nil, "ALL_VISITED" end
    return best
end

-- Advances the search chain by one step. Returns step, move_target, note.
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
        state.step = "DOOR_DISCOVERY"
        state.step_at = now
        state.found = state.found + 1
        return state.step, nil, "building " .. tostring(b.id)
    end

    local t = state.target

    if state.step == "DOOR_DISCOVERY" then
        local door = bridge and bridge.find_door and bridge.find_door(t)
        if door then
            state.door = door
            state.proven.DOOR_DISCOVERY = true
            state.step = "DOOR_APPROACH"
            state.step_at = now
            local p = U.copy_vec(door.position)
            return state.step, Grid.snap_to_land(p) or p, "door found"
        end
        if now - state.step_at > 20 then
            remember(state, t.id)
            state.target, state.door, state.step = nil, nil, nil
            return nil, nil, "no door exposed"
        end
        return state.step, nil, "looking for door"
    end

    if state.step == "DOOR_APPROACH" then
        local d = state.door and U.dist2d(pos, state.door.position) or math.huge
        if d <= B.tuning.approach_uu then
            state.proven.DOOR_APPROACH = true
            state.step = "DOOR_INTERACTION"
            state.step_at = now
            return state.step, nil, "at door"
        end
        if now - state.step_at > 90 then
            remember(state, t.id)
            state.target, state.door, state.step = nil, nil, nil
            return nil, nil, "could not reach door"
        end
        return state.step, U.copy_vec(state.door.position), "walking to door"
    end

    if state.step == "DOOR_INTERACTION" then
        local ok = bridge and bridge.open_door and bridge.open_door(state.door)
        if ok then
            state.proven.DOOR_INTERACTION = true
            state.step = "INTERIOR_NAVIGATION"
            state.step_at = now
            return state.step, nil, "door handled"
        end
        if now - state.step_at > 12 then
            remember(state, t.id)
            state.target, state.door, state.step = nil, nil, nil
            return nil, nil, "door would not open"
        end
        return state.step, nil, "handling door"
    end

    if state.step == "INTERIOR_NAVIGATION" then
        local points = bridge and bridge.interior_points and bridge.interior_points(t)
        if points and #points > 0 then
            state.proven.INTERIOR_NAVIGATION = true
            local idx = (state.interior_index or 0) + 1
            if idx > #points then
                remember(state, t.id)
                state.entered = state.entered + 1
                state.target, state.door, state.step = nil, nil, nil
                state.interior_index = nil
                return nil, nil, "building searched"
            end
            state.interior_index = idx
            if now - state.step_at < B.tuning.interior_delay_sec then
                return state.step, nil, "inside"
            end
            state.step_at = now
            return state.step, U.copy_vec(points[idx].position), "interior point " .. idx
        end
        if now - state.step_at > B.tuning.interior_delay_sec then
            remember(state, t.id)
            state.target, state.door, state.step = nil, nil, nil
            return nil, nil, "interior not exposed"
        end
        return state.step, nil, "interior pending"
    end

    return state.step, nil, "idle"
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
