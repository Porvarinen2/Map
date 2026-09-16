-- SmartNPC :: squad.lua
-- The squad brain: goals, routes, formation slots and the virtual simulation.
--
-- One rule holds this file together: the route is the authority on WHERE a
-- squad goes, and it never changes shape just because the squad materialised.
-- A virtual squad walks the route by integrating distance; a physical squad
-- walks the same route by handing one node at a time to its pawn.  Crossing the
-- boundary therefore changes nothing a player can see.

local S = SMARTNPC
local U = S.util
local C = S.config
local W = S.world
local B = S.body
local T = S.traits

local Q = {}
Q.__index = Q

local abs, max, min, floor = math.abs, math.max, math.min, math.floor

local next_squad_id = 1

--------------------------------------------------------------------------
-- construction
--------------------------------------------------------------------------

function Q.new(opts)
    local s = setmetatable({}, Q)
    s.id = opts.id or string.format("SQ_%04d", next_squad_id)
    next_squad_id = next_squad_id + 1
    s.archetype = opts.archetype or T.pick_archetype()
    s.name = opts.name or T.squad_name(s.id .. s.archetype.id)
    s.members = {}
    s.state = "PLAN"
    s.task = nil
    s.pos = opts.pos and { x = opts.pos.x, y = opts.pos.y, z = opts.pos.z or 0 } or nil
    s.virtual = true
    s.route = nil
    s.route_s = 0
    s.born_at = U.now()
    s.retire_at = U.now() + U.rand_range(C.SquadLifetimeMinSec, C.SquadLifetimeMaxSec)
    s.morale = 100
    s.trail = {}
    s.last_plan_at = 0
    s.stops = nil
    s.log_state_at = 0
    s.native = opts.native or false
    return s
end

function Q:member_count()
    local n = 0
    for _, m in ipairs(self.members) do
        if U.valid(m.actor) then n = n + 1 end
    end
    return n
end

function Q:alive()
    return self:member_count() > 0
end

function Q:add_member(rec)
    rec.squad_id = self.id
    rec.traits = rec.traits or T.roll(rec.key or rec.short or self.id, self.archetype)
    self.members[#self.members + 1] = rec
    self:assign_slots()
end

function Q:remove_dead()
    local out = {}
    local removed = 0
    for _, m in ipairs(self.members) do
        if U.valid(m.actor) then
            out[#out + 1] = m
        else
            removed = removed + 1
            if m.key then S.director.forget(m.key) end
        end
    end
    if removed > 0 then
        self.members = out
        self:assign_slots()
        self.morale = max(0, self.morale - removed * 18)
    end
    return removed
end

-- Formation slots: a wedge behind the leader.  Slots are stable for the life
-- of the squad, so a member never swaps place with another mid-march.
function Q:assign_slots()
    local n = #self.members
    self.leader = nil
    for i, m in ipairs(self.members) do
        m.slot = i - 1
        if i == 1 then
            self.leader = m
            m.lateral, m.lag = 0, 0
        else
            local rank = floor((i - 1 + 1) / 2)
            local side = ((i - 1) % 2 == 1) and 1 or -1
            local spread = (m.traits and m.traits.slot_spread) or 1
            m.lateral = side * C.FormationSpacingUU * rank * spread
            m.lag = C.FormationLagUU * rank
        end
        m.nodes = nil     -- regenerate on the next route
    end
    if not self.leader and n > 0 then self.leader = self.members[1] end
end

--------------------------------------------------------------------------
-- position
--------------------------------------------------------------------------

-- The squad position is the leader's body when physical, the simulated point
-- when virtual.  Nothing else is allowed to write s.pos.
function Q:refresh_pos()
    if not self.virtual then
        local ref = nil
        for _, m in ipairs(self.members) do
            if m.pos and U.pos_sane(m.pos) then ref = m; break end
        end
        if ref then
            self.pos = { x = ref.pos.x, y = ref.pos.y, z = ref.pos.z }
            return
        end
    end
end

--------------------------------------------------------------------------
-- routing
--------------------------------------------------------------------------

function Q:set_route(route, why)
    self.route = route
    self.route_s = 0
    self.route_why = why
    self.route_at = U.now()
    for _, m in ipairs(self.members) do
        m.nodes = nil
        m.node_i = 1
        m.cmd = nil
    end
end

function Q:member_nodes(m)
    if not self.route then return nil end
    if m.nodes and m.nodes_route == self.route then return m.nodes end
    if (m.lateral or 0) == 0 and (m.lag or 0) == 0 then
        m.nodes = self.route.nodes
    else
        local spread = (self.state == "WORK") and C.FormationSpreadSearch or C.FormationSpreadTravel
        m.nodes = self.route:offset_nodes((m.lateral or 0) * spread, m.lag or 0)
    end
    m.nodes_route = self.route
    m.node_i = m.node_i or 1
    return m.nodes
end

-- Advance a member's node cursor and publish its goal.  This is the only place
-- a physical NPC's goal is ever written.
function Q:drive_member(m)
    local nodes = self:member_nodes(m)
    if not nodes or #nodes == 0 then m.goal = nil; return end
    local pos = m.pos or self.pos
    if not pos then m.goal = nil; return end

    local i = U.clamp(m.node_i or 1, 1, #nodes)

    -- Recover a member that drifted far off its lane (dragged by combat, or
    -- freshly materialised): resume at the nearest node ahead instead of
    -- walking backwards to the one it was last assigned.
    if U.dist2(pos, nodes[i]) > 22000 then
        local best, bestd = i, math.huge
        for k = 1, #nodes do
            local d = U.dist2sq(pos, nodes[k])
            if d < bestd then bestd, best = d, k end
        end
        i = min(#nodes, best + 1)
    end

    -- Advance while we are close enough.  Gentle corners let us chain into the
    -- next leg early so the walk never stops; sharp corners make us arrive
    -- first, which is exactly what a person does.
    local guard = 0
    while i < #nodes and guard < 64 do
        guard = guard + 1
        local turn = (self.route and self.route.turn and self.route.turn[i]) or 0
        local radius = (turn > C.ChainTurnLimitDeg) and (C.MoveAcceptanceUU * 1.3) or C.NodeArriveUU
        if U.dist2(pos, nodes[i]) <= radius then i = i + 1 else break end
    end
    m.node_i = i
    local n = nodes[i]
    m.goal = { x = n.x, y = n.y, z = B.ground_at(n, pos.z) }
end

function Q:route_progress()
    if not self.route then return 0, 0 end
    if self.virtual then return self.route_s, self.route.total end
    local ref = self.leader
    if ref and ref.pos then
        local s = self.route:project(ref.pos, self.route_s)
        -- never run backwards on the progress readout
        if s > self.route_s then self.route_s = s end
    end
    return self.route_s, self.route.total
end

function Q:route_done()
    if not self.route then return true end
    local s, total = self:route_progress()
    if total <= 1 then return true end
    if s >= total - C.ArriveStopUU then return true end
    local endp = self.route.nodes[#self.route.nodes]
    return U.dist2(self.pos or endp, endp) < C.ArriveStopUU
end

function Q:plan_route_to(target, why)
    local from = self.pos
    if not from then return false end
    local route, err = W.route_between(from, target, nil)
    if not route then
        self.route_fail = (self.route_fail or 0) + 1
        S.telemetry.event("ROUTE_FAIL", self.id, tostring(err or "?"))
        return false
    end
    self.route_fail = 0
    self:set_route(route, why)
    return true
end

--------------------------------------------------------------------------
-- gait
--------------------------------------------------------------------------

function Q:set_gait(g)
    if self.gait == g then return end
    self.gait = g
    for _, m in ipairs(self.members) do
        m.gait = g
        m.profile_at = 0     -- force a profile refresh on the next body step
    end
end

--------------------------------------------------------------------------
-- activity planning
--------------------------------------------------------------------------

local function weights_for(arch)
    local w = {}
    for k, v in pairs(C.ActivityWeights) do w[k] = v end
    for k, v in pairs(arch.activity or {}) do w[k] = v end
    return w
end

function Q:choose_task()
    local w = weights_for(self.archetype)
    local list = {}
    for k, v in pairs(w) do list[#list + 1] = { id = k, w = v } end
    local sel = U.pick_weighted(list)
    return sel and sel.id or "SCAVENGE"
end

local function stops_around(centre, poi, count, radius)
    local out = {}
    if poi and poi.stops and #poi.stops > 0 then
        local pool = {}
        for _, p in ipairs(poi.stops) do pool[#pool + 1] = p end
        for i = #pool, 2, -1 do
            local j = math.random(i)
            pool[i], pool[j] = pool[j], pool[i]
        end
        for i = 1, min(count, #pool) do
            out[#out + 1] = { x = pool[i].x, y = pool[i].y, z = 0 }
        end
    end
    while #out < count do
        local p = W.random_point(centre, radius * 0.25, radius, W.component(centre))
        if not p then break end
        out[#out + 1] = { x = p.x, y = p.y, z = 0 }
    end
    return out
end

function Q:plan()
    local now = U.now()
    if now - (self.last_plan_at or 0) < 2 then return end
    self.last_plan_at = now
    if not self.pos then return end

    local task = self:choose_task()
    local poi, target

    if task == "LOOT_RUN" then
        poi = W.pick_poi(W.pois.highloot, self.pos, { max_dist = C.TravelMaxUU, scale = 300000 })
    elseif task == "SCAVENGE" then
        poi = W.pick_poi(W.pois.settlements, self.pos, { max_dist = C.TravelMaxUU, scale = 220000 })
    elseif task == "HUNT" then
        poi = W.pick_poi(W.pois.hunting, self.pos, { max_dist = C.TravelMaxUU, scale = 260000 })
    end

    if poi then
        target = { x = poi.x, y = poi.y, z = 0 }
    else
        -- PATROL / CAMP / AMBUSH, or no POI available: pick open ground.
        target = W.random_point(self.pos, C.TravelMinUU, min(C.TravelMaxUU, 260000), W.component(self.pos))
        if task == "LOOT_RUN" or task == "SCAVENGE" or task == "HUNT" then task = "PATROL" end
    end

    if not target then return end

    if not self:plan_route_to(target, task) then
        -- Try somewhere nearer before giving up; a failed long route is usually
        -- a component or budget problem, not a broken squad.
        local near = W.random_point(self.pos, 20000, 90000, W.component(self.pos))
        if not near or not self:plan_route_to(near, "FALLBACK") then return end
        task = "PATROL"
        poi = nil
    end

    self.task = task
    self.target_poi = poi
    self.target = target
    if poi then W.mark_poi_used(poi, C.PoiCooldownSec) end

    -- Gait: haste is a personality trait, not a constant.
    local hurry = (self.archetype.gait == "jog") or (self.route and self.route.total > 200000)
    self:set_gait(hurry and "jog" or "walk")

    self:enter("TRAVEL")
    S.telemetry.event("PLAN", self.id, string.format("%s -> %s (%.1f km)",
        task, poi and poi.label or W.sector(target), (self.route and self.route.total or 0) / 100000))
end

function Q:begin_work()
    local poi = self.target_poi
    local centre = self.target or self.pos
    local n = U.rand_int(C.StopsPerSiteMin, C.StopsPerSiteMax)
    local radius = (self.task == "HUNT") and 34000 or 12000
    self.stops = stops_around(centre, poi, n, radius)
    self.stop_i = 0
    self:set_gait("walk")
    self:enter("WORK")
    self:next_stop()
end

function Q:next_stop()
    self.stop_i = (self.stop_i or 0) + 1
    local st = self.stops and self.stops[self.stop_i]
    if not st then
        self.stops = nil
        self:enter("PLAN")
        return
    end
    self.stop_until = nil
    if not self:plan_route_to(st, "STOP") then
        self:next_stop()
    end
end

function Q:enter(state)
    if self.state == state then return end
    self.prev_state = self.state
    self.state = state
    self.state_at = U.now()
    if state ~= "TRAVEL" and state ~= "WORK" then
        for _, m in ipairs(self.members) do m.nodes = nil end
    end
end

--------------------------------------------------------------------------
-- combat awareness
--------------------------------------------------------------------------

function Q:update_combat(ctx)
    if not C.EnableCombat then return end
    local d = ctx.nearest_player_dist or math.huge

    if self.state ~= "COMBAT" then
        if not self.virtual and d < C.PlayerDetectRadiusUU then
            self.combat_since = U.now()
            self:enter("COMBAT")
            for _, m in ipairs(self.members) do
                m.combat = true
                m.goal = nil
                m.cmd = nil
            end
            S.telemetry.event("CONTACT", self.id, string.format("player at %.0f m", d / 100))
        end
        return
    end

    -- In COMBAT the native AI owns the pawns.  We only decide when it is over.
    if d > C.CombatBreakRadiusUU then
        self.combat_clear = (self.combat_clear or 0) + 1
    else
        self.combat_clear = 0
    end
    if self.combat_clear and self.combat_clear >= 3 then
        self.combat_clear = 0
        for _, m in ipairs(self.members) do
            m.combat = false
            m.cmd = nil
            m.nodes = nil
        end
        local hurt = false
        for _, m in ipairs(self.members) do
            if (m.health or 100) < C.RetreatHealthPct then hurt = true end
        end
        S.telemetry.event("BREAK", self.id, hurt and "withdrawing" or "resuming")
        if hurt then
            local away = W.random_point(self.pos, C.RetreatDistanceUU, C.RetreatDistanceUU * 1.8, W.component(self.pos))
            if away and self:plan_route_to(away, "RETREAT") then
                self:set_gait("jog")
                self:enter("TRAVEL")
                self.task = "RETREAT"
                return
            end
        end
        self:enter("PLAN")
    end
end

--------------------------------------------------------------------------
-- virtual simulation
--------------------------------------------------------------------------

function Q:virtual_step(dt)
    if not self.route or not self.pos then return end
    if self.state ~= "TRAVEL" and self.state ~= "WORK" then return end
    if self.stop_until and U.now() < self.stop_until then return end

    local speed = (self.gait == "jog") and C.SpeedJog or C.SpeedWalk
    speed = speed * C.VirtualSpeedScale
    self.route_s = min(self.route.total, self.route_s + speed * dt)
    local p = self.route:point_at(self.route_s)
    if p then
        local dx, dy = self.route:tangent_at(self.route_s)
        self.heading = U.heading(dx, dy)
        self.pos = { x = p.x, y = p.y, z = B.ground_at(p, self.pos.z or 0) or 0 }
    end
    self.speed = speed
end

--------------------------------------------------------------------------
-- main brain tick
--------------------------------------------------------------------------

function Q:tick(now, dt, ctx)
    self:remove_dead()
    if not self:alive() and not self.virtual then
        self.dead = true
        return
    end

    self:refresh_pos()
    if not self.pos then return end

    self:update_combat(ctx)

    if self.state == "COMBAT" then
        self.speed = 0
        return
    end

    if self.virtual then
        self:virtual_step(min(dt, C.VirtualMaxStepSec))
    else
        -- average member speed, for the map readout
        local sum, n = 0, 0
        for _, m in ipairs(self.members) do
            if m.speed then sum = sum + m.speed; n = n + 1 end
        end
        self.speed = n > 0 and (sum / n) or 0
        if self.leader and self.leader.yaw then self.heading = self.leader.yaw end
    end

    ----------------------------------------------------------------------
    -- state machine
    ----------------------------------------------------------------------
    if self.state == "PLAN" then
        self:plan()

    elseif self.state == "TRAVEL" then
        if self:route_done() then
            if self.task == "CAMP" or self.task == "AMBUSH" or self.task == "RETREAT" then
                self.rest_until = now + ((self.task == "AMBUSH")
                    and U.rand_range(C.AmbushMinSec, C.AmbushMaxSec)
                    or U.rand_range(C.CampMinSec, C.CampMaxSec))
                self:enter("REST")
            elseif self.task == "PATROL" then
                self.rest_until = now + U.rand_range(C.StopMinSec, C.StopMaxSec)
                self:enter("REST")
            else
                self:begin_work()
            end
        elseif self.route_fail and self.route_fail > 2 then
            self:enter("PLAN")
        end

    elseif self.state == "WORK" then
        if self.stop_until then
            if now >= self.stop_until then
                self.stop_until = nil
                self:next_stop()
            end
        elseif self:route_done() then
            local mul = 1
            if self.leader and self.leader.traits then mul = self.leader.traits.stop_mul or 1 end
            self.stop_until = now + U.rand_range(C.StopMinSec, C.StopMaxSec) * mul
            for _, m in ipairs(self.members) do m.goal = nil end
            S.telemetry.event("STOP", self.id, string.format("%s stop %d/%d",
                self.task or "?", self.stop_i or 0, self.stops and #self.stops or 0))
        end

    elseif self.state == "REST" then
        for _, m in ipairs(self.members) do m.goal = nil end
        if now >= (self.rest_until or 0) then
            self:enter("PLAN")
        end
    end

    ----------------------------------------------------------------------
    -- publish member goals (physical squads only)
    ----------------------------------------------------------------------
    if not self.virtual and (self.state == "TRAVEL" or self.state == "WORK") then
        local holding = (self.state == "WORK" and self.stop_until ~= nil)
        if holding then
            for _, m in ipairs(self.members) do m.goal = nil end
        else
            for _, m in ipairs(self.members) do
                if U.valid(m.actor) then self:drive_member(m) end
            end
        end
    end

    if self.route_fail and self.route_fail > 4 then
        self.route_fail = 0
        self:enter("PLAN")
    end

    if now > self.retire_at and self.virtual and self.state == "PLAN" then
        self.retiring = true
    end
end

--------------------------------------------------------------------------
-- materialise / virtualise
--------------------------------------------------------------------------

function Q:on_materialize()
    self.virtual = false
    self.route_s = self.route_s or 0
    for _, m in ipairs(self.members) do
        m.nodes = nil
        m.cmd = nil
        m.node_i = nil
        m.profile_at = 0
        m.brain_off = false
    end
    S.telemetry.event("MATERIALIZE", self.id, W.sector(self.pos))
end

-- Freeze the simulation exactly where the bodies stood so the marker does not
-- jump when the squad goes back to being a dot on the map.  The bodies
-- themselves are removed by the director straight after this call: an
-- off-screen pawn cannot walk (SCUM stops ticking distant AI), so leaving one
-- standing would desynchronise the marker from the world.
function Q:on_virtualize()
    self:refresh_pos()
    if self.route and self.pos then
        self.route_s = self.route:project(self.pos, self.route_s)
    end
    self.virtual = true
    S.telemetry.event("VIRTUALIZE", self.id, W.sector(self.pos))
end

--------------------------------------------------------------------------
-- reporting
--------------------------------------------------------------------------

function Q:summary()
    local s, total = self.route_s or 0, (self.route and self.route.total) or 0
    local phys = 0
    for _, m in ipairs(self.members) do if U.valid(m.actor) then phys = phys + 1 end end
    return {
        id = self.id,
        name = self.name,
        arch = self.archetype.id,
        archLabel = self.archetype.label,
        colour = self.archetype.colour,
        state = self.state,
        task = self.task or "-",
        x = self.pos and self.pos.x or 0,
        y = self.pos and self.pos.y or 0,
        z = self.pos and self.pos.z or 0,
        sector = self.pos and W.sector(self.pos) or "??",
        heading = self.heading or 0,
        speed = self.speed or 0,
        gait = self.gait or "walk",
        virtual = self.virtual,
        members = phys,
        morale = floor(self.morale or 100),
        progress = total > 1 and U.clamp(s / total, 0, 1) or 0,
        distance = total,
        target = self.target_poi and self.target_poi.label
            or (self.target and W.sector(self.target)) or "-",
        age = floor(U.now() - self.born_at),
    }
end

function Q:route_line(maxpts)
    if not self.route then return nil end
    local n = self.route.nodes
    local step = max(1, floor(#n / (maxpts or 60)))
    local out = {}
    for i = 1, #n, step do out[#out + 1] = { n[i].x, n[i].y } end
    local last = n[#n]
    out[#out + 1] = { last.x, last.y }
    return out
end

return Q
