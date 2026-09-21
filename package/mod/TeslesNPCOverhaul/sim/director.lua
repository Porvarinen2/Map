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
    local route, why = Router.route(from, dest, opts)
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
        if poi then Activity.mark_visited(act, poi, self.now) end
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

function D:pick_new_goal(group)
    local act = group.act
    -- A goal that was only deferred by a busy frame gets another go first.
    if act.pending_goal then
        local poi = act.pending_goal
        local prefer = not (poi.kind == "WILDERNESS" or poi.kind == "HUNTING")
        if self:start_travel(group, poi, { prefer_roads = prefer }) then return end
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
    -- Hunting and camping groups cut across country; everyone else uses roads.
    local prefer_roads = not (poi.kind == "WILDERNESS" or poi.kind == "HUNTING")
    self:start_travel(group, poi, { prefer_roads = prefer_roads })
end

function D:on_arrival(group)
    local act = group.act
    local poi = act.goal_poi
    act.tour = nil
    act.tour_index = 0
    act.stop_until = nil
    self.counters.arrivals = self.counters.arrivals + 1
    Activity.mark_visited(act, poi, self.now)
    local next_state = Activity.activity_for(poi, group, act)
    act.state = next_state
    act.until_t = self.now + Activity.duration_for(next_state, act)
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
    if not p then return end
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
                if act.goal_poi then Activity.mark_visited(act, act.goal_poi, self.now) end
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

function D:move_physical(group, dt)
    local mv = group.mv
    if not Movement.has_route(mv) then return end
    local pos = group.position
    if not pos then return end

    if Movement.update_index(mv, pos, Movement.tuning.arrive_physical) then
        return
    end

    local status = Movement.check_progress(mv, pos, self.now)
    if status ~= "OK" then
        local action = Movement.handle_stall(mv, pos)
        Log.event("STALL", group.gid, action .. " stalls=" .. tostring(mv.stalls))
        if action == "REPLAN" then
            self.counters.replans = self.counters.replans + 1
            local goal = mv.goal
            Movement.clear(mv)
            if goal then self:solve_route(group, goal, {}) end
            return
        elseif action == "ABANDON" then
            Movement.clear(mv)
            group.act.state = S.IDLE
            group.act.until_t = self.now + 15
            return
        end
    end

    local heading = Movement.update_heading(mv, pos, self.now)

    -- The leader owns the long path; followers hold slots on it. One actor
    -- solving the route means one line of travel instead of five. If the
    -- actual leader has no actor yet - spawn budget, a failed spawn - the
    -- first materialized member drives instead, so the squad never stands
    -- still waiting for someone who is not there.
    local leader = Leadership.leader(group)
    if not (leader and leader.runtime_id) then
        for _, m in ipairs(group.members) do
            if m.alive and m.runtime_id then leader = m; break end
        end
    end

    -- Pace: a squad crossing the map moves at travel speed, a squad working a
    -- village walks. Set once per change, not every tick.
    local want_speed = (group.act.state == S.TRAVEL)
        and (self.cfg.PhysicalTravelSpeedUU or 420)
        or (self.cfg.PhysicalWalkSpeedUU or 300)
    if group.speed_set ~= want_speed and self.bridge.set_speed then
        for _, m in ipairs(group.members) do
            if m.alive and m.runtime_id then self.bridge.set_speed(m.runtime_id, want_speed) end
        end
        group.speed_set = want_speed
    end

    local target, reason = Movement.next_command(mv, pos, self.now)
    if target and leader and leader.runtime_id then
        local accepted = self.bridge.move_to(leader.runtime_id, target)
        Movement.mark_issued(mv, target, pos, self.now, accepted)
        if accepted then
            self.counters.commands = self.counters.commands + 1
            if self.cfg.EnableMovementDebug then
                Log.move_trace(string.format("%d\t%s\t%s\t%.0f\t%.0f\t%.0f\t%.0f\t%s",
                    self.now, group.gid, reason, pos.X, pos.Y, target.X, target.Y,
                    mv.route and mv.route.kind or "-"))
            end
        else
            Log.event("MOVE_REJECTED", group.gid, reason)
        end
    end

    if leader and Movement.formation_due(mv, heading, self.now) then
        local slot_index = 0
        for _, m in ipairs(group.members) do
            if m.alive and m ~= leader and m.runtime_id then
                slot_index = slot_index + 1
                local leader_pos = leader.position or pos
                local slot = Movement.formation_slot(leader_pos, heading, slot_index + 1,
                    self.cfg.FormationSpreadUU or 900,
                    self.cfg.FormationDepthUU or 1000)
                local cur = m.position
                if not cur or U.dist2d(cur, slot) > Movement.tuning.formation_slot_tolerance then
                    if self.bridge.move_to(m.runtime_id, slot) then
                        self.counters.commands = self.counters.commands + 1
                    end
                end
            end
        end
        Movement.mark_formation(mv, heading, self.now)
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
    Router.begin_tick(self.cfg.RouteExpansionsPerTick or Router.TICK_BUDGET)

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
            group.spawn_note = why
        else
            group.spawn_note = nil
            -- A group that just became physical must re-issue its orders.
            group.mv.issued_target = nil
        end
    elseif not want and group.physical then
        local released = Physical.virtualize(group, self.bridge, {})
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
