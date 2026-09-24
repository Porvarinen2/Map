-- Full-world integration test.
--
-- Runs the real director over the real world data for several simulated hours
-- with a mock engine underneath, and asserts the properties that matter:
--   * groups actually get somewhere instead of milling around
--   * nothing ends up in water or outside the map
--   * physical squads walk smooth paths, not saw-teeth
--   * virtual and physical handover keeps identity and position
--   * a save/load cycle changes nothing observable
--   * one tick stays cheap enough for a live server
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path

local U = require("core.util")
local RNG = require("core.rng")
local Log = require("core.log")
local Grid = require("world.navgrid")
local POI = require("world.pois")
local Zones = require("world.zones")
local Population = require("sim.population")
local Director = require("sim.director")
local Movement = require("sim.movement")
local Activity = require("sim.activity")
local Persist = require("core.persist")
local Bridge = require("mock_bridge")

Log.configure(nil, "error", false)

local fails = 0
local function check(cond, msg)
    if cond then print("  ok  " .. msg)
    else print("FAIL: " .. msg); fails = fails + 1 end
end

local SIM_SECONDS = tonumber(os.getenv("SIM_SECONDS") or "") or 10800   -- 3 h
local TICK = 1

local rng = RNG.new(31337)
Bridge.configure(rng, { spawn_fail_rate = 0.06, move_reject_rate = 0.06 })

local world = Population.new_world({ seed = 20260921, target_npcs = 100 })
Population.generate(world)
print(string.format("world: %d groups / %d NPCs",
    #world.groups, Population.alive_npc_count(world)))

local director = Director.new({
    world = world, bridge = Bridge, seed = 4242,
    config = { RouteSolvesPerTick = 2, EnableMovementDebug = false,
               RouteExpansionsPerTick = 7000,
               MaxDeltaSec = 12, VirtualTravelSpeedUU = 340 },
})

-- A player wandering between POIs, so groups keep crossing the LOD bands.
local player = { pos = U.copy_vec(POI.points[1].pos), goal = nil }
local function step_player(dt)
    if not player.goal or U.dist2d(player.pos, player.goal) < 3000 then
        player.goal = U.copy_vec(POI.points[rng:int(1, POI.count)].pos)
    end
    local dir = U.direction(player.pos, player.goal)
    if dir then
        local step = 500 * dt
        player.pos.X = player.pos.X + dir.X * step
        player.pos.Y = player.pos.Y + dir.Y * step
    end
    Bridge.players = { player.pos }
end

-- Tracked properties.
local trails = {}
local travel_trails = {}
local water_hits, out_of_bounds = 0, 0
local water_detail = {}
local max_tick_ms, total_tick_ms = 0, 0
local tick_samples = {}
local materialized_events, virtualized_events = 0, 0
local states_seen = {}

for _, g in ipairs(world.groups) do trails[g.gid] = {}; travel_trails[g.gid] = {} end

local zone_breaches = {}
local rad_goals, sweeps_done = {}, 0
local t0 = os.clock()
local sim_now = os.time()
for step = 1, math.floor(SIM_SECONDS / TICK) do
    sim_now = sim_now + TICK
    step_player(TICK)
    Bridge.step(TICK)

    local c0 = os.clock()
    director:tick(sim_now)
    local ms = (os.clock() - c0) * 1000
    total_tick_ms = total_tick_ms + ms
    tick_samples[#tick_samples + 1] = ms
    if ms > max_tick_ms then max_tick_ms = ms end

    for _, g in ipairs(world.groups) do
        if g.class == "radiation_group" and g.act then
            local seq = rad_goals[g.gid] or {}
            rad_goals[g.gid] = seq
            local id = g.act.goal_poi and g.act.goal_poi.id
            if id and seq[#seq] ~= id then seq[#seq + 1] = id end
            if g.act.sweep_done and not g.act._counted then
                g.act._counted = true
                sweeps_done = sweeps_done + 1
            elseif not g.act.sweep_done then
                g.act._counted = nil
            end
        end
    end

    if step % 8 == 0 then
        for _, g in ipairs(world.groups) do
            local p = g.position
            if p then
                local tr = trails[g.gid]
                if tr then tr[#tr + 1] = U.copy_vec(p) end
                if g.act.state == "TRAVEL" then
                    local tt = travel_trails[g.gid]
                    tt[#tt + 1] = U.copy_vec(p)
                elseif #(travel_trails[g.gid] or {}) > 0 then
                    -- close the segment: store it and start a new one
                    local tt = travel_trails[g.gid]
                    if #tt > 6 then
                        travel_trails[#travel_trails + 1] = tt
                    end
                    travel_trails[g.gid] = {}
                end
                if not Grid.is_passable(p) and not g.physical then
                    water_hits = water_hits + 1
                    local key = g.act.state .. "/" .. (g.physical and "PHYS" or "VIRT")
                        .. "/" .. tostring(g.act.goal_poi and g.act.goal_poi.kind or "-")
                    water_detail[key] = (water_detail[key] or 0) + 1
                end
                if Zones.sector(p) == "OUT" then out_of_bounds = out_of_bounds + 1 end
                local in_c0 = Zones.sector(p) == "C0"
                if (g.class == "radiation_group") ~= in_c0 then
                    zone_breaches[g.class] = (zone_breaches[g.class] or 0) + 1
                end
            end
            states_seen[g.act.state] = (states_seen[g.act.state] or 0) + 1
            if g.physical then materialized_events = materialized_events + 1
            else virtualized_events = virtualized_events + 1 end
        end
    end
end
local wall = os.clock() - t0

table.sort(tick_samples)
local function pct(p)
    local i = math.max(1, math.min(#tick_samples,
        math.ceil(#tick_samples * p)))
    return tick_samples[i]
end
local p50, p99 = pct(0.50), pct(0.99)
print(string.format(
    "\nsimulated %.1f h in %.1f s wall  (avg %.2f, p50 %.2f, p99 %.2f, peak %.1f ms/tick)",
    SIM_SECONDS / 3600, wall, total_tick_ms / (SIM_SECONDS / TICK), p50, p99, max_tick_ms))

local c = director.counters
print(string.format("routes=%d fail=%d  arrivals=%d  commands=%d  replans=%d",
    c.routes, c.route_fail, c.arrivals, c.commands, c.replans))
print(string.format("spawns=%d spawn_fail=%d  virtualized=%d  deaths=%d",
    c.spawns, c.spawn_fail, c.virtualized, c.deaths))

local order = {}
for k, v in pairs(states_seen) do order[#order + 1] = { k, v } end
table.sort(order, function(a, b) return a[2] > b[2] end)
local parts = {}
for _, kv in ipairs(order) do parts[#parts + 1] = kv[1] .. "=" .. kv[2] end
print("group states: " .. table.concat(parts, "  "))

-- Movement quality across every group that actually travelled.
local jit_sum, rev_sum, n = 0, 0, 0
local moved_groups = 0
for gid, tr in pairs(trails) do
    if #tr > 12 then
        local dist = 0
        for i = 1, #tr - 1 do dist = dist + U.dist2d(tr[i], tr[i + 1]) end
        if dist > 150000 then
            moved_groups = moved_groups + 1
            jit_sum = jit_sum + Movement.trail_jitter_spatial(tr, 2500)
            rev_sum = rev_sum + Movement.trail_reversals(tr, 2500, 150)
            n = n + 1
        end
    end
end
print(string.format("all movement:    groups=%d  turn/250m=%.1f deg  reversals=%.1f%%",
    moved_groups, n > 0 and jit_sum / n or 0, n > 0 and 100 * rev_sum / n or 0))

-- Travel legs only: this is the behaviour the overhaul exists to fix.
local tj, tr_rev, tn = 0, 0, 0
for _, tt in ipairs(travel_trails) do
    if type(tt) == "table" and #tt > 8 then
        local d = 0
        for i = 1, #tt - 1 do d = d + U.dist2d(tt[i], tt[i + 1]) end
        if d > 60000 then
            tj = tj + Movement.trail_jitter_spatial(tt, 2500)
            tr_rev = tr_rev + Movement.trail_reversals(tt, 2500, 55)
            tn = tn + 1
        end
    end
end
local travel_jitter = tn > 0 and tj / tn or 0
local travel_rev = tn > 0 and tr_rev / tn or 0
print(string.format("travel legs only: legs=%d  turn/250m=%.1f deg  reversals=%.1f%%",
    tn, travel_jitter, 100 * travel_rev))
if next(water_detail) then
    for k, v in pairs(water_detail) do print("  water hit: " .. k .. " x" .. v) end
end

print("")
check(c.arrivals > 0, string.format("groups reached destinations (%d arrivals)", c.arrivals))
check(c.arrivals >= #world.groups * 0.5,
      string.format("at least half the groups completed a journey (%d / %d)",
                    c.arrivals, #world.groups))
-- Physical positions come from the mock actor, which has no collision and
-- will happily walk into the sea; only the director's own virtual positions
-- are the mod's responsibility here.
check(water_hits == 0,
      string.format("no virtual group stood in water (%d hits)", water_hits))
check(out_of_bounds == 0, string.format("no group left the map (%d)", out_of_bounds))
check(moved_groups >= #world.groups * 0.6,
      string.format("%d of %d groups covered real distance", moved_groups, #world.groups))
check(tn > 20, string.format("%d travel legs were long enough to measure", tn))
-- Thresholds are set against the measured legacy behaviour (about 19 deg per
-- 250 m and 4.5% reversals). Road hairpins are real corners, so a travel leg
-- is never expected to score zero.
check(travel_jitter < 5.5,
      string.format("travel turn per 250 m = %.1f deg < 5.5", travel_jitter))
check(100 * travel_rev < 2.5,
      string.format("travel reversals = %.1f%% < 2.5%%", 100 * travel_rev))
-- Working a POI walks house to house, so corners there are by design; the
-- all-movement check only guards against genuine back-and-forth (U-turns).
check(n > 0 and jit_sum / n < 20.0,
      string.format("all-movement turn per 250 m = %.1f deg < 20 (working a POI turns more)",
                    n > 0 and jit_sum / n or 99))
check(n > 0 and 100 * rev_sum / n < 3.0,
      string.format("all-movement U-turns = %.1f%% < 3%%", n > 0 and 100 * rev_sum / n or 99))
check(c.spawns > 0, string.format("actors materialized near the player (%d)", c.spawns))
check(Bridge.owned > 0,
      string.format("the director took ownership of the actors it spawned (%d)", Bridge.owned))
check(c.virtualized > 0, string.format("actors released when the player left (%d)", c.virtualized))
check(c.route_fail < c.routes * 0.25,
      string.format("route failures %d stayed under 25%% of %d solves", c.route_fail, c.routes))
-- The tick budget that matters is the typical one: the director runs once a
-- second, so a rare garbage-collection spike costs nothing. p99 is the honest
-- measure; the peak is only checked for a runaway.
check(p99 < 12, string.format("p99 tick %.2f ms < 12", p99))
check(max_tick_ms < 120, string.format("peak tick %.1f ms < 120", max_tick_ms))
check(total_tick_ms / (SIM_SECONDS / TICK) < 6,
      string.format("average tick %.2f ms < 6", total_tick_ms / (SIM_SECONDS / TICK)))

-- Destination queue and place memory. Queued places obey the memory too:
-- a place may not come back while it is among the last MEMORY places walked
-- before it, counting what is remembered, the goal and the queue itself.
do
    local open_groups, full, dup, early = 0, 0, 0, 0
    for _, g in ipairs(world.groups) do
        local act = g.act or {}
        local mem = Activity.memory_of(g)
        local seen = {}
        for _, id in ipairs(act.recent or {}) do
            if seen[id] then dup = dup + 1 end
            seen[id] = true
        end
        local seq = Activity._planned_walk(act)
        local nq = #(act.queue or {})
        for k = #seq - nq + 1, #seq do
            for j = math.max(1, k - mem), k - 1 do
                if seq[j] == seq[k] then early = early + 1 end
            end
        end
        open_groups = open_groups + 1
        if nq == Activity.QUEUE_LENGTH then full = full + 1 end
        if os.getenv("DEBUG_QUEUE") and nq < Activity.QUEUE_LENGTH then
            print("  queue", g.gid, g.class, act.state, table.concat(act.queue or {}, ","))
        end
    end
    check(full == open_groups,
          string.format("%d of %d groups have %d places queued", full, open_groups, Activity.QUEUE_LENGTH))
    check(dup == 0, string.format("no place repeats inside a group's memory (%d)", dup))
    check(early == 0, string.format("no queued place returns before its memory allows (%d)", early))
end

-- C0 is the radiation squads' alone: five of them, never outside, and no
-- other squad inside. They walk Krsko -> power plant -> camp and sweep the
-- city area by area.
do
    local rad = 0
    for _, g in ipairs(world.groups) do
        if g.class == "radiation_group" and Population.group_alive(g) then rad = rad + 1 end
    end
    check(rad == 5, string.format("five radiation squads hold C0 (%d)", rad))
    local breaches = 0
    for k, v in pairs(zone_breaches) do
        breaches = breaches + v
        print("  zone breach: " .. k .. " x" .. v)
    end
    check(breaches == 0, string.format("no squad crossed the C0 line either way (%d samples)", breaches))
    local circuit = { CIT_C0_01 = "IND_C0_01", IND_C0_01 = "LAN_C0_01", LAN_C0_01 = "CIT_C0_01" }
    local steps, wrong = 0, 0
    for _, seq in pairs(rad_goals) do
        for i = 2, #seq do
            steps = steps + 1
            if circuit[seq[i - 1]] ~= seq[i] then wrong = wrong + 1 end
        end
    end
    check(steps >= 5 and wrong == 0,
          string.format("radiation squads walk city -> plant -> camp in order (%d moves, %d out of order)", steps, wrong))
    local city = POI.by_id["CIT_C0_01"]
    local ordered = true
    for _, dir in ipairs({ 1, -1 }) do
        local act = { rng = RNG.new(1) }
        Activity.build_sweep(city, act, dir)
        local prev = dir > 0 and 0 or 99
        for _, a in ipairs(act.tour_area) do
            if (dir > 0 and a < prev) or (dir < 0 and a > prev) then ordered = false end
            prev = a
        end
        if act.tour_area[1] ~= (dir > 0 and 1 or 5) or #act.tour < 40 then ordered = false end
        for _, p in ipairs(act.tour) do
            if Zones.sector(p) ~= "C0" then ordered = false end
        end
    end
    check(ordered, "a sweep walks areas 1-5 or 5-1, every stop inside C0")
    check(sweeps_done >= 1, string.format("Krsko was swept area by area to the end (%d sweeps)", sweeps_done))
end

-- Save / load fidelity after a live run.
local ser = Population.serialize(world)
local json = U.json(ser)
local world2 = Population.deserialize(Persist.parse(json))
local same = (#world2.groups == #world.groups)
local drift = 0
for i, g in ipairs(world.groups) do
    local h = world2.groups[i]
    if not h or h.gid ~= g.gid then same = false; break end
    drift = math.max(drift, U.dist2d(g.position, h.position))
    for j, m in ipairs(g.members) do
        local k = h.members[j]
        if not k or k.npcId ~= m.npcId or k.alive ~= m.alive then same = false end
        if k and math.abs(k.traits.courage - m.traits.courage) > 1e-9 then same = false end
    end
end
print(string.format("\nsave: %.1f KB, position drift %.0f UU", #json / 1024, drift))
check(same, "save/load preserves every group, member, personality and life state")
check(drift < 1, "positions survive the round trip exactly")

-- A living world needs spread, not a population that all settles on the same
-- numbers. These checks fail if morale, stress or fatigue saturate.
local function spread(vals)
    local lo, hi, sum = math.huge, -math.huge, 0
    for _, v in ipairs(vals) do
        if v < lo then lo = v end
        if v > hi then hi = v end
        sum = sum + v
    end
    return lo, hi, sum / math.max(1, #vals)
end
local morale, stress, fatigue, pinned = {}, {}, {}, 0
for _, g in ipairs(world.groups) do
    morale[#morale + 1] = g.morale
    fatigue[#fatigue + 1] = g.act.fatigue
    if g.morale >= 0.995 then pinned = pinned + 1 end
    for _, m in ipairs(g.members) do
        if m.alive then stress[#stress + 1] = m.stress end
    end
end
local ml, mh, mm = spread(morale)
local sl, sh, sm = spread(stress)
local fl, fh, fm = spread(fatigue)
print(string.format("\nmorale  %.2f..%.2f (avg %.2f)   stress %.2f..%.2f (avg %.2f)   fatigue %.0f..%.0f (avg %.0f)",
    ml, mh, mm, sl, sh, sm, fl, fh, fm))
check(pinned == 0, string.format("no group pinned at maximum morale (%d)", pinned))
check(mh - ml > 0.10, string.format("morale varies across groups (%.2f spread)", mh - ml))
check(sh - sl > 0.05, string.format("stress varies across NPCs (%.2f spread)", sh - sl))
check(fh > 5, string.format("fatigue accumulates (peak %.0f)", fh))

local alive_before = Population.alive_npc_count(world)
check(alive_before >= 80,
      string.format("population held at %d NPCs (no silent attrition)", alive_before))

os.exit(fails == 0 and 0 or 1)
