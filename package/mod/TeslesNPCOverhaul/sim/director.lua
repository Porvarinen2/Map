-- The world director: one tick over the whole persistent population.
--
-- Order of work per group:
--   1. read back reality (actor positions, deaths)
--   2. decide level of detail, materialise or release actors
--   3. build a threat context and let personalities choose an action
--   4. run the activity state machine (may pick a new destination)
--   5. move - physical groups get gated move orders, virtual groups step
--      along the exact same route
--   6. upkeep: stress, morale, relations, fatigue
--
-- Route solving is budgeted per tick so a busy world cannot stall the server.
local U = require("core.util")
local RNG = require("core.rng")
local Log = require("core.log")
local Router = require("world.router")
local Grid = require("world.navgrid")
local POI = require("world.pois")
local Zones = require("world.zones")
local Movement = require("sim.movement")
local Activity = require("sim.activity")
local Population = require("sim.population")
local Physical = require("sim.physical")
local Combat = require("sim.combat")
local Buildings = require("sim.buildings")
local Leadership = require("npc.leadership")
local Diplomacy = require("npc.diplomacy")
local Stress = require("npc.stress")

local D = {}
D.__index = D

local S = Activity.STATES

function D.new(opts)
    local self = setmetatable({}, D)
    self.world = opts.world
    self.bridge = opts.bridge
    self.cfg = opts.config or {}
    self.rng = RNG.new(opts.seed or os.time())
    self.now = opts.now or os.time()
    self.last_tick = self.now
    self.route_budget = self.cfg.RouteSolvesPerTick or 3
    self.virtual_speed = self.cfg.VirtualTravelSpeedUU or 340
    self.virtual_road_bonus = self.cfg.VirtualRoadSpeedMultiplier or 1.25
    self.max_delta = self.cfg.MaxDeltaSec or 12
    self.ticks = 0
    self.counters = {
        routes = 0, route_fail = 0, commands = 0, arrivals = 0,
        spawns = 0, spawn_fail = 0, virtualized = 0, contacts = 0,
        deaths = 0, replans = 0,
    }
    self.contacts = {}
    return self
end

-- ------------------------------------------------------------- routing -----

function D:solve_route(group, dest, opts)
    if self.route_budget <= 0 then return false, "BUDGET" end
    self.route_budget = self.route_budget - 1
    local from = group.position
    -- Every route honours the group's zone fence (C0: radiation in, others out).
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    if o.fence == nil then o.fence = Zones.fence_for(group) end
    local route, why = Router.route(from, dest, o)
    if not route then
        self.counters.route_fail = self.counters.route_fail + 1
        Log.event("ROUTE_FAIL", group.gid, tostring(why))
        return false, why
    end
    self.counters.routes = self.counters.routes + 1
    Movement.set_route(group.mv, route, dest)
    return true, route.kind
end

-- ------------------------------------------------------ activity machine ---

function D:start_travel(group, poi, opts)
    local act = group.act
    local dest = poi and U.copy_vec(poi.pos) or opts and opts.dest
    if not dest then return false end
    local ok, kind = self:solve_route(group, dest, opts)
    if not ok then
        -- A budget miss is a busy frame, not an unreachable place: keep the
        -- target and try again shortly. Anything else means give up on it.
        if kind == "BUDGET" and (act.route_tries or 0) < 4 then
            act.route_tries = (act.route_tries or 0) + 1
            act.pending_goal = poi
            act.state = S.IDLE
            act.until_t = self.now + 2
            return false
        end
        act.route_tries = 0
        act.pending_goal = nil
        if poi then Activity.mark_visited(act, poi, self.now, group) end
        act.goal_poi = nil
        act.state = S.IDLE
        act.until_t = self.now + self.rng:range(8, 25)
        return false
    end
    act.route_tries = 0
    act.pending_goal = nil
    act.goal_poi = poi
    act.state = S.TRAVEL
    act.travel_kind = kind
    act.journeys = act.journeys + 1
    Activity.note(act, "matkalla: " .. (poi and poi.label or "kohde"))
    Log.event("TRAVEL", group.gid,
        string.format("%s via %s %.1f km", poi and poi.id or "?", kind,
            (group.mv.route and group.mv.route.length or 0) / 100000))
    return true
end

-- A nearby hunting tower is walked to across country. A far one is reached
-- the way a person would: by road, then the last stretch through the forest.
-- A terrain search across half the island is also the one route search that
-- can eat a whole tick's budget and still come back empty.
local CROSS_COUNTRY_MAX = 150000
function D:prefer_roads(group, poi)
    if poi.kind ~= "HUNTING" then return true end
    return not (group.position and U.dist2d(group.position, poi.pos) <= CROSS_COUNTRY_MAX)
end

function D:pick_new_goal(group)
    local act = group.act
    -- A goal that was only deferred by a busy frame gets another go first.
    if act.pending_goal then
        local poi = act.pending_goal
        if self:start_travel(group, poi, { prefer_roads = self:prefer_roads(group, poi) }) then return end
        if act.pending_goal then return end
    end
    if Activity.needs_rest(act) then
        act.state = S.REST
        act.until_t = self.now + Activity.duration_for(S.REST, act)
        Movement.clear(group.mv)
        Activity.note(act, "lepotauko")
        return
    end
    local poi = Activity.choose_destination(group, act, self.now)
    if not poi then
        act.state = S.IDLE
        act.until_t = self.now + 20
        return
    end
    self:start_travel(group, poi, { prefer_roads = self:prefer_roads(group, poi) })
end

function D:on_arrival(group)
    local act = group.act
    local poi = act.goal_poi
    act.tour = nil
    act.tour_index = 0
    act.stop_until = nil
    act.sweep_dir, act.sweep_done = nil, nil
    self.counters.arrivals = self.counters.arrivals + 1
    Activity.mark_visited(act, poi, self.now, group)
    local next_state = Activity.activity_for(poi, group, act)
    act.state = next_state
    act.until_t = self.now + Activity.duration_for(next_state, act, poi)
    if Activity.sweeps(poi, group) then
        -- Krsko is done when the sweep is, not on a timer.
        act.state = S.SEARCH
        next_state = S.SEARCH
        act.sweep_dir = act.rng:chance(0.5) and 1 or -1
        act.until_t = self.now + Activity.SWEEP_MAX_SEC
    end
    act.local_target = nil
    Movement.clear(group.mv, Movement.ARRIVED)
    if next_state == S.SEARCH then
        group.search = group.search or Buildings.new_state()
    end
    Activity.note(act, (Activity.fi[next_state] or next_state) ..
        (poi and (": " .. poi.label) or ""))
    Log.event("ARRIVE", group.gid, (poi and poi.id or "?") .. " -> " .. next_state)
end

-- Working a POI: walk the next stop on the ordered tour. The tour is built
-- once per visit, so a group crosses a village instead of bouncing inside it.
function D:local_move(group, spread)
    local act = group.act
    if not act.goal_poi then return end
    if Movement.has_route(group.mv) and group.mv.state == Movement.MOVING then return end
    if act.stop_until and self.now < act.stop_until then return end
    local p = Activity.next_stop(act.goal_poi, act, spread)
    if not p then
        if act.sweep_done then
            act.until_t = self.now
            Activity.note(act, "kaupunki kayty lapi: " .. act.goal_poi.label)
            Log.event("SWEEP_DONE", group.gid, act.goal_poi.id)
        end
        return
    end
    local ok = self:solve_route(group, p, { prefer_roads = false, direct_max = 400000 })
    if ok then
        act.local_target = p
        -- Pause at each stop: a squad that never stands still reads as a bot.
        act.stop_until = nil
    end
end

function D:run_activity(group)
    local act = group.act
    local st = act.state

    if st == S.TRAVEL then
        if group.mv.state == Movement.ARRIVED then
            self:on_arrival(group)
        elseif not Movement.has_route(group.mv) then
            -- Travelling with no route means a solve failed somewhere. Only
            -- count it as an arrival if the group really is at the goal;
            -- otherwise try again, and give the target up after a few goes
            -- rather than pretending to have got there.
            local goal = act.goal_poi and act.goal_poi.pos or group.mv.goal
            if goal and U.dist2d(group.position, goal)
                <= (act.goal_poi and act.goal_poi.radius or 9000) then
                self:on_arrival(group)
            elseif goal and (act.route_tries or 0) < 4 then
                act.route_tries = (act.route_tries or 0) + 1
                if not self:solve_route(group, goal, {}) then
                    act.state = S.IDLE
                    act.until_t = self.now + 3
                end
            else
                Log.event("TRAVEL_ABORT", group.gid,
                    "route could not be rebuilt for " ..
                    tostring(act.goal_poi and act.goal_poi.id or "?"))
                act.route_tries = 0
                if act.goal_poi then Activity.mark_visited(act, act.goal_poi, self.now, group) end
                act.goal_poi = nil
                act.state = S.IDLE
                act.until_t = self.now + self.rng:range(5, 15)
            end
        end
        return
    end

    -- Finished a leg inside a POI: linger before moving on to the next stop.
    if group.mv.state == Movement.ARRIVED and not act.stop_until then
        act.stop_until = self.now + act.rng:range(Activity.tuning.stop_min_sec or 20,
                                                  Activity.tuning.stop_max_sec or 70)
        Movement.clear(group.mv)
    end

    if self.now < (act.until_t or 0) then
        -- Still working here. Keep drifting between local points.
        if st == S.SEARCH then
            self:run_search(group)
        elseif st == S.PATROL then
            self:local_move(group, (act.goal_poi and act.goal_poi.radius or 9000) * 1.1)
        elseif st == S.HUNT then
            self:local_move(group, (act.goal_poi and act.goal_poi.radius or 20000) * 0.85)
        elseif st == S.HOLD then
            self:local_move(group, 6000)
        end
        return
    end

    if st == S.REST or st == S.IDLE or st == S.CAMP or st == S.SEARCH
        or st == S.PATROL or st == S.HUNT or st == S.HOLD then
        self:pick_new_goal(group)
    end
end

function D:run_search(group)
    group.search = group.search or Buildings.new_state()
    local step, target, note = Buildings.step(group.search, group, self.bridge, self.now)
    if target then
        self:solve_route(group, target, { prefer_roads = false, direct_max = 200000 })
    elseif not step then
        -- Nothing searchable reachable here: wander the POI instead.
        self:local_move(group, (group.act.goal_poi and group.act.goal_poi.radius or 9000) * 0.9)
    end
    group.search_note = note
end

-- --------------------------------------------------------------- movement --

-- The actor that drives a physical squad: the leader if it has a body,
-- otherwise the first member who does.
function D:driver(group)
    local leader = Leadership.leader(group)
    if leader and leader.alive and leader.runtime_id then return leader end
    for _, m in ipairs(group.members) do
        if m.alive and m.runtime_id then return m end
    end
    return nil
end

-- Steering for a squad that has real bodies.
--
-- What the 1.2.1 server log showed: the leader was sent to route waypoints
-- up to 570 m away, at Z 0, with pathfinding. The server had no navmesh there,
-- so every order was refused and re-sent every second; meanwhile each
-- follower got a fresh formation slot whenever the heading wobbled, and the
-- squad's position was the average of all members, so the leader was steered
-- from a point behind itself. Together that is the zig-zag.
--
-- Now: the leader walks short hops (a carrot 30 m ahead on the route, at its
-- own height) and gets a new hop only when it is nearly at the last one, the
-- route bent away, or the order went stale. If the engine refuses a
-- pathfinding request the hop is walked straight - it is short and on a
-- terrain-checked route. Followers do not get slots at all: each walks the
-- leader's own footprints, a fixed distance behind, so the squad moves as a
-- column along the path the leader actually took.
local STEER = {
    look = 3000,          -- carrot distance ahead of the leader
    reached = 1100,       -- close enough to the carrot to hand out the next
    retarget = 1600,      -- carrot moved this far from the order: re-send
    retarget_sec = 2,
    stale_sec = 8,
    crumb_step = 250,     -- leader footprint spacing
    crumbs = 80,
    spacing = 420,        -- distance between members in the column
    follow_slack = 450,   -- a follower this close to its spot is left alone
    follow_resend = 650,
    follow_sec = 5,
}
D.STEER = STEER

local function footprint_back(trail, from, dist)
    -- Walk the leader's footprints backwards from its current position.
    local cur, rem = from, dist
    for i = #trail, 1, -1 do
        local p = trail[i]
        local d = U.dist2d(cur, p)
        if d >= rem and d > 0 then
            local f = rem / d
            return { X = cur.X + (p.X - cur.X) * f, Y = cur.Y + (p.Y - cur.Y) * f, Z = p.Z }
        end
        rem = rem - d
        cur = p
    end
    return trail[1] and U.copy_vec(trail[1]) or nil
end

function D:move_physical(group, dt)
    local mv = group.mv
    local lead = self:driver(group)
    if not lead then return end
    local pos = lead.position or group.position
    if not pos then return end
    local now = self.now
    local st = group.steer
    if not st or st.lead ~= lead.npcId then
        st = { lead = lead.npcId, trail = {}, follow = {} }
        group.steer = st
    end

    -- Leader footprints, for the column behind it.
    local last = st.trail[#st.trail]
    if not last or U.dist2d(last, pos) >= STEER.crumb_step then
        st.trail[#st.trail + 1] = U.copy_vec(pos)
        if #st.trail > STEER.crumbs then table.remove(st.trail, 1) end
    end

    -- Pace: travelling squads walk briskly, a squad working a place strolls.
    -- Followers get a little more so the column closes up instead of
    -- stretching.
    local want = (group.act.state == S.TRAVEL)
        and (self.cfg.PhysicalTravelSpeedUU or 420)
        or (self.cfg.PhysicalWalkSpeedUU or 300)
    if group.speed_set ~= want and self.bridge.set_speed then
        for _, m in ipairs(group.members) do
            if m.alive and m.runtime_id then
                self.bridge.set_speed(m.runtime_id, m == lead and want or want * 1.12)
            end
        end
        group.speed_set = want
    end

    -- ---- leader
    if Movement.has_route(mv) then
        if Movement.update_index(mv, pos, Movement.tuning.arrive_physical) then
            st.target = nil
        else
            -- A physical leader that is walking is not stalled, however slow
            -- SCUM lets it walk: skipping waypoints and replanning under a
            -- slow walker is what made the squad zig-zag. Only a leader that
            -- has stood still counts.
            st.still = st.still or { at = now, pos = U.copy_vec(pos) }
            if U.dist2d(st.still.pos, pos) > 150 then
                st.still = { at = now, pos = U.copy_vec(pos) }
                mv.stalls = 0
            end
            local status = "OK"
            if now - st.still.at >= Movement.tuning.stall_sec then
                st.still.at = now
                mv.stalls = mv.stalls + 1
                status = "STALL"
            end
            if status ~= "OK" then
                local action = Movement.handle_stall(mv, pos)
                Log.event("STALL", group.gid, action .. " stalls=" .. tostring(mv.stalls))
                if action == "REPLAN" then
                    self.counters.replans = self.counters.replans + 1
                    local goal = mv.goal
                    Movement.clear(mv)
                    st.target = nil
                    if goal then self:solve_route(group, goal, {}) end
                    return
                elseif action == "ABANDON" then
                    Movement.clear(mv)
                    st.target = nil
                    group.act.state = S.IDLE
                    group.act.until_t = now + 15
                    return
                end
                st.force = true
            end

            local carrot = Movement.carrot(mv, pos, STEER.look)
            local need = carrot and (
                not st.target or st.force
                or U.dist2d(pos, st.target) < STEER.reached
                or (U.dist2d(carrot, st.target) > STEER.retarget
                    and now - (st.at or 0) >= STEER.retarget_sec)
                or now - (st.at or 0) >= STEER.stale_sec
                or (now - (st.still and st.still.at or now) >= 5 and now - (st.at or 0) >= 5))
            if need and now >= (st.backoff_until or 0) then
                -- Straight at the carrot by default: the route is already
                -- checked against the terrain, and a navmesh request out here
                -- only reaches the edge of the small patch SCUM builds around
                -- its AI - the 1.4.2 log has the leader accepted and standing
                -- still for 40 s. Pathfinding is the way round an obstacle
                -- when a straight walk has stopped making ground.
                local stuck = now - (st.still and st.still.at or now) >= 5
                local pathfind = false
                if stuck then
                    -- Alternate: pathfinding round the obstacle, then straight
                    -- again, so neither can leave the leader standing for good.
                    st.unstick = (st.unstick or 0) + 1
                    pathfind = st.unstick % 2 == 1
                else
                    st.unstick = 0
                end
                local ok = self.bridge.move_to(lead.runtime_id, carrot,
                    { direct = not pathfind, radius = 120 })
                if not ok and pathfind then
                    ok = self.bridge.move_to(lead.runtime_id, carrot, { direct = true, radius = 120 })
                end
                if ok then
                    st.target, st.at, st.force, st.fails = carrot, now, false, 0
                    self.counters.commands = self.counters.commands + 1
                    mv.issued_target, mv.issued_at = carrot, now
                else
                    st.fails = (st.fails or 0) + 1
                    st.backoff_until = now + math.min(2 * st.fails, 8)
                    if now - (st.reject_logged or 0) >= 20 then
                        st.reject_logged = now
                        Log.event("MOVE_REJECTED", group.gid, "fails=" .. st.fails)
                    end
                end
            end
        end
    end

    -- ---- followers: a column, each member following the one ahead of it.
    -- The engine tracks a moving goal actor itself, so a follower walks one
    -- continuous curve instead of stopping at footprint points and being
    -- sent on again (the stop-go of 1.4.1). Where the engine refuses to
    -- follow, the footprint hop is the fallback.
    local ahead = lead
    local k = 0
    for _, m in ipairs(group.members) do
        if m.alive and m.runtime_id and m ~= lead then
            k = k + 1
            local f = st.follow[m.npcId]
            local gap = (ahead.position and m.position) and U.dist2d(ahead.position, m.position) or 0
            local target_changed = not f or f.ahead ~= ahead.npcId
            -- A follow request ends when the follower arrives; renew it as
            -- soon as the one ahead has walked away again.
            local renew = target_changed
                or (gap > STEER.spacing + 180 and now - f.at >= 1)
                or now - f.at >= 12
            if renew and self.bridge.follow
                and self.bridge.follow(m.runtime_id, ahead.runtime_id, STEER.spacing) then
                st.follow[m.npcId] = { ahead = ahead.npcId, at = now }
                self.counters.commands = self.counters.commands + 1
            elseif renew and gap > STEER.follow_slack then
                local spot = footprint_back(st.trail, pos, k * STEER.spacing)
                if spot and m.position then
                    spot.Z = m.position.Z
                    if self.bridge.move_to(m.runtime_id, spot, { direct = true, radius = 150 }) then
                        st.follow[m.npcId] = { ahead = "trail", at = now }
                        self.counters.commands = self.counters.commands + 1
                    end
                end
            end
            ahead = m
        end
    end

    -- SCUM's own AI must stay stopped outside a fight, or it steers too.
    if group.act.state ~= S.COMBAT and self.bridge.keep_ownership
        and now - (st.owned_at or 0) >= 4 then
        st.owned_at = now
        for _, m in ipairs(group.members) do
            if m.alive and m.runtime_id then self.bridge.keep_ownership(m.runtime_id) end
        end
    end

    -- Pace actually walked by the leader, logged now and then: the only way
    -- to see from a log whether the speed the director asks for is the speed
    -- SCUM uses.
    st.pace = st.pace or { at = now, pos = U.copy_vec(pos) }
    if now - st.pace.at >= 10 then
        local v = U.dist2d(st.pace.pos, pos) / (now - st.pace.at)
        st.pace = { at = now, pos = U.copy_vec(pos) }
        D.pace_logs = D.pace_logs or 0
        if D.pace_logs < 12 and self.bridge.on_debug and group.act.state == S.TRAVEL then
            D.pace_logs = D.pace_logs + 1
            local ws = self.bridge.walk_speed and self.bridge.walk_speed(lead.runtime_id)
            pcall(self.bridge.on_debug, string.format(
                "pace %s: %.0f UU/s walked, MaxWalkSpeed %s, asked %s",
                group.gid, v, tostring(ws and math.floor(ws) or "?"), tostring(group.speed_set)))
        end
    end
end

function D:move_virtual(group, dt)
    local mv = group.mv
    if not Movement.has_route(mv) then return end
    local speed = self.virtual_speed
    if Grid.is_road(group.position) then speed = speed * self.virtual_road_bonus end
    -- Tired groups walk slower; it shows on the map as a natural slowdown.
    speed = speed * U.clamp(1.05 - (group.act.fatigue or 0) / 260, 0.55, 1.1)

    local newpos, arrived = Movement.virtual_step(mv, group.position, dt, speed)
    -- Safety net. The router checks every segment, but the nav grid is coarse,
    -- so a step can still land a marker on a water cell. Snapping to the
    -- nearest land could jump the marker across a bay, which would look like a
    -- teleport; holding position and replanning is the honest response.
    if newpos and not Grid.is_passable(newpos) then
        -- The step is discarded, not committed. A group parked exactly on a
        -- land/water cell boundary would otherwise replan into the same
        -- blocked step forever, so it is first pulled to the middle of the
        -- cell it is standing in and only then given a new route.
        local goal = mv.goal
        Movement.clear(mv)
        group.blocked_steps = (group.blocked_steps or 0) + 1
        local gx, gy = Grid.world_to_grid(group.position)
        local safe = nil
        if gx and Grid.at(gx, gy) ~= Grid.WATER then
            safe = Grid.grid_to_world(gx, gy, group.position.Z)
        else
            safe = Grid.snap_to_land(group.position)
            if safe then safe.Z = group.position.Z end
        end
        if safe then
            group.position = safe
            for _, m in ipairs(group.members) do
                if m.alive then m.position = U.copy_vec(safe) end
            end
        end
        Log.event("VIRTUAL_BLOCKED", group.gid,
            "step off passable terrain; recentred (" .. group.blocked_steps .. ")")
        -- Repeatedly blocked means this destination is not workable from here.
        if group.blocked_steps >= 3 then
            group.blocked_steps = 0
            group.act.goal_poi = nil
            group.act.state = S.IDLE
            group.act.until_t = self.now + 5
        elseif goal then
            self:solve_route(group, goal, {})
        end
        return
    end
    group.blocked_steps = 0
    if newpos then
        local moved = U.dist2d(group.position, newpos)
        group.act.distance = (group.act.distance or 0) + moved
        group.position = newpos
        for _, m in ipairs(group.members) do
            if m.alive then
                m.position = U.copy_vec(newpos)
                m.xp.distance = (m.xp.distance or 0) + moved
            end
        end
    end
    if arrived then mv.state = Movement.ARRIVED end
end

-- ---------------------------------------------------------------- combat ---

function D:run_combat(group, contact, zpressure)
    local ctx = Combat.build_context(group, contact, zpressure)
    Combat.apply_contact_stress(group, ctx, self.rng)
    local tally = Combat.decide_group(group, ctx)
    group.combat_ctx = ctx
    group.action_tally = tally

    if not contact then return false end
    self.counters.contacts = self.counters.contacts + 1
    Combat.register_contact(self.world.diplomacy, group, contact.group, 1,
        1 + (ctx.power_ratio or 1) * 0.2)
    group.act.state = S.COMBAT
    group.act.until_t = self.now + 20
    Movement.clear(group.mv)

    local enemy_pos = contact.group.position
    for _, m in ipairs(group.members) do
        if m.alive and m.materialized and m.runtime_id then
            local point = Combat.tactical_point(m, group, enemy_pos, m.action)
            if point then
                self.bridge.move_to(m.runtime_id, point)
                self.counters.commands = self.counters.commands + 1
            end
            if (m.action == "ATTACK" or m.action == "FLANK") and self.bridge.aim_at then
                if self.bridge.aim_at(m.runtime_id, enemy_pos) and self.bridge.start_fire then
                    self.bridge.start_fire(m.runtime_id)
                end
            elseif self.bridge.stop_fire then
                self.bridge.stop_fire(m.runtime_id)
            end
        end
    end
    return true
end

-- ------------------------------------------------------------------ tick ---

function D:tick(now)
    self.ticks = self.ticks + 1
    now = now or os.time()
    local dt = U.clamp(now - self.last_tick, 0, self.max_delta)
    self.last_tick = now
    self.now = now
    self.route_budget = self.cfg.RouteSolvesPerTick or 3
    Router.begin_tick(self.cfg.RouteExpansionsPerTick or Router.TICK_BUDGET,
        self.cfg.RouteMillisecondsPerTick or Router.MS_BUDGET)

    -- SCUM's NPC classes finish loading after the server is already up, so a
    -- catalog that was empty at boot is rescanned on a backoff until it fills.
    if self.bridge and self.bridge.maybe_refresh_catalog then
        if self.bridge.maybe_refresh_catalog(now) then
            Log.event("CATALOG", "SYSTEM",
                tostring(self.bridge.catalog_found) .. " NPC classes resolved")
        end
    end

    local players = (self.bridge and self.bridge.player_positions
        and self.bridge.player_positions()) or {}
    local world = self.world

    -- Contacts are evaluated once for the whole world.
    local physical_groups = {}
    for _, g in ipairs(world.groups) do
        if g.physical then physical_groups[#physical_groups + 1] = g end
    end

    for _, group in ipairs(world.groups) do
        self:tick_group(group, players, physical_groups, dt)
    end

    -- Group relations and leadership recovery are cheap; run them every tick.
    for _, group in ipairs(world.groups) do
        Diplomacy.tick_relations(group, dt)
        Leadership.recover(group, dt)
        if Leadership.succession_due(group, now) then
            local pick = Leadership.select(group)
            if pick then
                Leadership.assign(group, pick)
                Log.event("NEW_LEADER", group.gid, pick.name)
            end
        end
    end

    -- The radiation zone keeps its fixed squads, inside, and nobody else.
    if self.now >= (self.reserve_check_at or 0) then
        self.reserve_check_at = self.now + 60
        Population.ensure_reserved(world, function(m) Log.event("RESERVED", "", m) end)
    end

    -- Survivors band together before the empty group is pruned away.
    if self.ticks % 20 == 0 then
        Population.merge_stragglers(world, function(m) Log.event("JOINED", "", m) end)
    end
    local removed = Population.prune(world, function(m) Log.event("WIPED", m, "") end)
    if removed > 0 and self.cfg.EnableReplenish then
        Population.replenish(world, function(m) Log.event("REPLENISH", m, "") end)
    end
    return self.counters
end

function D:tick_group(group, players, physical_groups, dt)
    if not group.position then return end
    local now = self.now

    -- A virtual marker must always stand on passable terrain. It can end up
    -- off it after a physical squad is released from a position the engine
    -- reported inside water, and without this a group would be stranded there
    -- for the rest of the session. Physical groups are left alone: their
    -- position is whatever the engine actually says it is.
    if not group.physical and not Grid.is_passable(group.position) then
        local snapped = Grid.snap_to_land(group.position)
        if snapped then
            snapped.Z = group.position.Z
            Log.event("MARKER_RESCUED", group.gid,
                string.format("%.0f UU back to land", U.dist2d(group.position, snapped)))
            group.position = snapped
            for _, m in ipairs(group.members) do
                if m.alive then m.position = U.copy_vec(snapped) end
            end
            Movement.clear(group.mv)
            group.act.state = S.IDLE
            group.act.until_t = now + 2
        end
    end

    -- 1. Reality check.
    local lod, distance = Physical.group_lod(group, players)
    group.lod = lod
    group.player_distance = distance

    if group.physical then
        local before_leader_hp = nil
        local lead0 = Leadership.leader(group)
        if lead0 then before_leader_hp = lead0.health end

        local _, lost = Physical.sync_positions(group, self.bridge)
        -- The squad is where its driver is. The average of all members sat
        -- behind the leader, and steering the leader from there sent it back
        -- and forth along its own path.
        local drv = self:driver(group)
        if drv and drv.position then group.position = U.copy_vec(drv.position) end

        -- A wounded leader shakes the group even when they survive.
        if lead0 and before_leader_hp and lead0.alive
            and (lead0.health or 100) < before_leader_hp - 12 then
            Leadership.on_leader_wounded(group)
            Stress.apply(lead0, "INJURY")
            for _, m in ipairs(group.members) do
                if m.alive and m ~= lead0 then Stress.apply(m, "LEADER_WOUNDED") end
            end
            Log.event("LEADER_WOUNDED", group.gid, lead0.name)
        end

        if lost then
            for _, victim in ipairs(lost) do
                Combat.on_member_lost(group, victim, self.rng,
                    function(kind, gid, name) Log.event(kind, gid, name) end,
                    self.world.diplomacy, group.last_contact)
                self.counters.deaths = self.counters.deaths + 1
                if victim.is_leader then
                    Leadership.on_leader_lost(group, now, function(m)
                        Stress.apply(m, "LEADER_DOWN")
                    end)
                end
            end
        end
    end

    -- 2. Level of detail handover.
    local want = Physical.wants_physical(group, distance)
    if want and not group.physical then
        local spawned, failed, why = Physical.materialize(group, self.bridge, {
            now = now,
            take_ownership = self.cfg.TakeOwnership ~= false,
            yaw = math.floor(U.deg((group.mv and group.mv.smooth_heading) or 0)) % 360,
            on_spawn = function(g, m, pos)
                Log.event("MATERIALIZE", g.gid, m.npcId)
            end,
        })
        self.counters.spawns = self.counters.spawns + spawned
        self.counters.spawn_fail = self.counters.spawn_fail + failed
        if failed > 0 and spawned == 0 then
            -- Every refusal is on record, so "no NPCs appeared" always has a
            -- reason in events.tsv and, once per change, in boot.log.
            if group.spawn_note ~= why then
                Log.event("SPAWN_FAIL", group.gid, tostring(why))
                if self.bridge.on_debug then
                    pcall(self.bridge.on_debug, "spawn refused for " .. group.gid .. ": " .. tostring(why))
                end
            end
            group.spawn_note = why
        else
            group.spawn_note = nil
            -- A group that just became physical must re-issue its orders.
            group.mv.issued_target = nil
        end
    elseif not want and group.physical then
        local released = Physical.virtualize(group, self.bridge, {})
        group.steer = nil
        self.counters.virtualized = self.counters.virtualized + released
        Log.event("VIRTUALIZE", group.gid, tostring(released))
        group.mv.issued_target = nil
    end
    group.physical_count = Physical.physical_count(group)
    group.physical = group.physical_count > 0

    -- 3. Threat context.
    local contact = nil
    if group.physical then
        local list = Combat.find_contacts(group, physical_groups, self.world.diplomacy)
        contact = list[1]
    end
    local zpressure = 0
    if group.physical then
        zpressure = Combat.zombie_pressure(group, self.bridge)
    end
    group.last_contact = contact and contact.group or nil
    local fighting = self:run_combat(group, contact, zpressure)

    -- 4/5. Activity and movement.
    if not fighting then
        if group.act.state == S.COMBAT and now >= (group.act.until_t or 0) then
            group.act.state = S.IDLE
            group.act.until_t = now + self.rng:range(4, 12)
        end
        self:run_activity(group)
        if group.physical then
            self:move_physical(group, dt)
        else
            self:move_virtual(group, dt)
        end
    end

    -- 6. Upkeep. Anything but resting costs effort, so a group that keeps
    -- working eventually has to stop, which is what produces the day/night
    -- rhythm of camps and quiet villages.
    local st = group.act.state
    local resting = (st == S.REST or st == S.CAMP or st == S.HOLD)
    Activity.tick_upkeep(group.act, dt, not resting)
    local in_danger = fighting or zpressure > 0.2
    for _, m in ipairs(group.members) do
        if m.alive then
            Stress.recover(m, dt, in_danger)
            Stress.privation(m, group.act.supply or 100, dt)
        end
    end
end

return D
