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
local materialized_events, virtualized_events = 0, 0
local states_seen = {}

for _, g in ipairs(world.groups) do trails[g.gid] = {}; travel_trails[g.gid] = {} end

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
    if ms > max_tick_ms then max_tick_ms = ms end

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
            end
            states_seen[g.act.state] = (states_seen[g.act.state] or 0) + 1
            if g.physical then materialized_events = materialized_events + 1
            else virtualized_events = virtualized_events + 1 end
        end
    end
end
local wall = os.clock() - t0

print(string.format("\nsimulated %.1f h in %.1f s wall  (%.2f ms/tick avg, %.1f ms peak)",
    SIM_SECONDS / 3600, wall, total_tick_ms / (SIM_SECONDS / TICK), max_tick_ms))

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
            rev_sum = rev_sum + Movement.trail_reversals(tr, 2500, 55)
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
check(n > 0 and jit_sum / n < 11.0,
      string.format("all-movement turn per 250 m = %.1f deg < 11 (working a POI turns more)",
                    n > 0 and jit_sum / n or 99))
check(n > 0 and 100 * rev_sum / n < 6.0,
      string.format("all-movement reversals = %.1f%% < 6%%", n > 0 and 100 * rev_sum / n or 99))
check(c.spawns > 0, string.format("actors materialized near the player (%d)", c.spawns))
check(Bridge.owned > 0,
      string.format("the director took ownership of the actors it spawned (%d)", Bridge.owned))
check(c.virtualized > 0, string.format("actors released when the player left (%d)", c.virtualized))
check(c.route_fail < c.routes * 0.25,
      string.format("route failures %d stayed under 25%% of %d solves", c.route_fail, c.routes))
check(max_tick_ms < 60, string.format("peak tick %.1f ms < 60", max_tick_ms))
check(total_tick_ms / (SIM_SECONDS / TICK) < 6,
      string.format("average tick %.2f ms < 6", total_tick_ms / (SIM_SECONDS / TICK)))

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
