-- A materialised squad on the move, with SCUM's real limits: it walks at the
-- pace SCUM lets it (about 1.25 m/s, whatever MaxWalkSpeed is set to), move
-- orders are sometimes refused, and a player kills two of its members.
--
-- What must hold:
--   * the squad keeps heading for its goal - no waypoint skipping or
--     replanning just because it walks slowly
--   * leader and followers walk smooth lines: no back-and-forth
--   * followers move continuously instead of stop-go
--   * the dead stay dead when the squad is released and materialised again
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path

local U = require("core.util")
local RNG = require("core.rng")
local Log = require("core.log")
local Population = require("sim.population")
local Director = require("sim.director")
local Movement = require("sim.movement")
local Bridge = require("mock_bridge")

Log.configure(nil, "error", false)

local fails = 0
local function check(cond, msg)
    if cond then print("  ok  " .. msg)
    else print("FAIL: " .. msg); fails = fails + 1 end
end

local events = {}
local orig_event = Log.event
Log.event = function(kind, subject, detail)
    events[#events + 1] = { kind = kind, subject = subject, detail = detail }
    return orig_event(kind, subject, detail)
end

local rng = RNG.new(77)
Bridge.reset()
Bridge.configure(rng, { spawn_fail_rate = 0, move_reject_rate = 0.05 })
-- SCUM ignores the requested speed: every actor walks at 125 UU/s.
local SCUM_PACE = 125
Bridge.pathfinding_goes_nowhere = true
Bridge.set_speed = function(h, v)
    local a = Bridge.actors[h]
    if a then a.speed = SCUM_PACE end
    return true
end
local orig_spawn = Bridge.spawn_npc
Bridge.spawn_npc = function(req)
    local h, why = orig_spawn(req)
    if h then Bridge.actors[h].speed = SCUM_PACE end
    return h, why
end

local world = Population.new_world({ seed = 99, target_npcs = 60 })
Population.generate(world)
local director = Director.new({
    world = world, bridge = Bridge, seed = 5,
    config = { RouteSolvesPerTick = 3, RouteExpansionsPerTick = 7000 },
})

-- A three-man radiation squad walking between Krsko's places.
local squad = nil
for _, g in ipairs(world.groups) do
    if g.class == "radiation_group" and #g.members >= 3 then squad = g; break end
end
assert(squad, "no radiation squad with three members")

local sim_now = os.time()
local function run(seconds, player_offset)
    for _ = 1, seconds do
        sim_now = sim_now + 1
        -- The player shadows the squad at a fixed distance, so it stays real.
        if player_offset then
            local p = squad.position
            Bridge.players = { { X = p.X + player_offset, Y = p.Y, Z = p.Z or 0 } }
        else
            Bridge.players = {}
        end
        Bridge.step(1)
        director:tick(sim_now)
    end
end

-- Get the squad travelling, then let the player arrive.
run(40, nil)
for _ = 1, 600 do
    if squad.act.state == "TRAVEL" and Movement.has_route(squad.mv)
        and squad.mv.route.length > 60000 then break end
    run(1, nil)
end
local first = #events
run(20, 4000)
check(squad.physical, "the squad materialised next to the player")
do
    local alive, bodies = 0, 0
    for _, m in ipairs(squad.members) do
        if m.alive then alive = alive + 1 end
        if m.materialized then bodies = bodies + 1 end
    end
    check(bodies == alive, string.format("every living member got a body, not just the first (%d of %d)", bodies, alive))
end

-- Walk for twenty minutes of game time.
local start_events = #events
local start_pos = U.copy_vec(squad.position)
local actors = {}
for _, m in ipairs(squad.members) do
    if m.runtime_id then actors[#actors + 1] = Bridge.actors[m.runtime_id] end
end
local trail_mark = {}
for i, a in ipairs(actors) do trail_mark[i] = #a.trail end
run(1200, 4000)

local skips, replans, stalls = 0, 0, 0
for i = start_events + 1, #events do
    local e = events[i]
    if e.subject == squad.gid and e.kind == "STALL" then
        stalls = stalls + 1
        if e.detail:find("SKIP") then skips = skips + 1 end
        if e.detail:find("REPLAN") then replans = replans + 1 end
    end
end
print(string.format("stall events %d (skip %d, replan %d)", stalls, skips, replans))
check(skips == 0 and replans == 0, "a slow walker is never skipped ahead or replanned")

-- Smoothness per actor, over what it actually walked.
local worst_rev, worst_turn, stopgo = 0, 0, 0
for i, a in ipairs(actors) do
    local tr = {}
    for j = trail_mark[i], #a.trail do tr[#tr + 1] = a.trail[j] end
    local rev = Movement.trail_reversals(tr, 1000, 150)
    local turn = Movement.trail_jitter_spatial(tr, 1000)
    worst_rev = math.max(worst_rev, rev)
    worst_turn = math.max(worst_turn, turn)
    -- Stop-go: stretches of standing still between walking.
    local still, stops = 0, 0
    for j = 2, #tr do
        local d = U.dist2d(tr[j - 1], tr[j])
        if d < 1 then still = still + 1 else
            if still >= 8 then stops = stops + 1 end
            still = 0
        end
    end
    if i > 1 then stopgo = stopgo + stops end
    print(string.format("  actor %d: %d samples, turn/10m %.1f deg, U-turns %.1f%%, stops %d",
        i, #tr, turn, 100 * rev, stops))
end
check(worst_rev < 0.02, string.format("no back-and-forth walking (worst %.1f%% U-turns)", 100 * worst_rev))
check(worst_turn < 12, string.format("smooth lines (worst %.1f deg per 10 m)", worst_turn))
check(stopgo <= 6, string.format("followers walk on without stop-go (%d stops in 20 min)", stopgo))
local moved = U.dist2d(start_pos, squad.position)
check(moved > 50000, string.format("the squad covered real ground (%.0f m straight-line)", moved / 100))

-- Two of them are killed.
local killed = 0
for _, m in ipairs(squad.members) do
    if killed < 2 and m.runtime_id and not m.is_leader then
        Bridge.actors[m.runtime_id].alive = false
        killed = killed + 1
    end
end
run(3, 4000)
local alive = 0
for _, m in ipairs(squad.members) do if m.alive then alive = alive + 1 end end
check(alive == #squad.members - 2, string.format("two killed members are dead (%d of %d alive)", alive, #squad.members))

-- The player leaves and comes back: only the living come back.
run(30, 200000)
check(not squad.physical, "the squad was released when the player left")
run(30, 4000)
local bodies = 0
for _, m in ipairs(squad.members) do if m.materialized then bodies = bodies + 1 end end
check(squad.physical and bodies == alive,
      string.format("only the survivors materialise again (%d bodies, %d alive)", bodies, alive))

-- ------------------------------------------------------------ gunfight ---
-- Two hostile squads meet in front of the player: they shoot, people die,
-- the dead drop in the world too, and the fight ends.
do
    local Diplomacy = require("npc.diplomacy")
    local a_grp, b_grp = nil, nil
    for _, g in ipairs(world.groups) do
        local intact = true
        for _, m in ipairs(g.members) do if not m.alive then intact = false end end
        if g.class ~= "radiation_group" and intact and #g.members >= 2 then
            if not a_grp then a_grp = g
            elseif not b_grp and g ~= a_grp then b_grp = g end
        end
    end
    -- Two hardened squads (a frightened pair would rather run - that is
    -- tested in test_behaviour.lua).
    for _, g in ipairs({ a_grp, b_grp }) do
        for _, m in ipairs(g.members) do
            m.archetype = "ex_military"; m.stress = 0.05; m.level = 4
            m.traits.courage = 0.8; m.traits.stressResistance = 0.8; m.traits.fearfulness = 0.2
        end
    end
    -- Blood enemies, standing 60 m apart.
    Diplomacy.adjust(world.diplomacy, a_grp, b_grp, -2, "test")
    local here = { X = a_grp.position.X, Y = a_grp.position.Y, Z = 0 }
    b_grp.position = { X = here.X + 6000, Y = here.Y, Z = 0 }
    for _, m in ipairs(b_grp.members) do m.position = U.copy_vec(b_grp.position) end
    for _, m in ipairs(a_grp.members) do m.position = U.copy_vec(here) end
    local before = Population.alive_npc_count(world)
    local damage_before = Bridge.damage_calls
    local deaths_before = director.counters.deaths
    squad = a_grp
    for i = 1, 24 do run(5, 3000); local function st(g) local s = {} for _, m in ipairs(g.members) do s[#s+1] = string.format("%.2f%s", m.stress or 0, m.alive and "" or "x") end return table.concat(s, ",") end; if os.getenv("DBG") then print(i*5, a_grp.mood, a_grp.act.state, st(a_grp), "|", b_grp.mood, b_grp.act.state, st(b_grp), U.dist2d(a_grp.position, b_grp.position)) end end
    local lost = before - Population.alive_npc_count(world)
    print(string.format("gunfight: %d killed, %d damage calls, kill result: %s",
        lost, Bridge.damage_calls - damage_before, tostring(Bridge.kill_result)))
    check(lost >= 1, "hostile squads kill each other")
    check(director.counters.deaths - deaths_before >= lost, "every kill is a recorded death")
    check(Bridge.damage_calls > damage_before, "hits are applied to the real bodies")
    local walking_dead = 0
    for _, g in ipairs({ a_grp, b_grp }) do
        for _, m in ipairs(g.members) do
            if not m.alive and m.materialized then walking_dead = walking_dead + 1 end
        end
    end
    check(walking_dead == 0, "no dead NPC is still driven as a body")
end

-- ----------------------------------------------------------- loadouts ---
do
    local g = nil
    for _, x in ipairs(world.groups) do
        if Population.group_alive(x) and not x.physical and x.class ~= "radiation_group" then g = x; break end
    end
    director.cfg.Loadouts = { [g.class] = { Clothes = { "Police_Shirt_01" }, Weapons = { "Weapon_M9" } } }
    local before = #Bridge.loadouts_applied
    squad = g
    run(20, 3000)
    local n = #Bridge.loadouts_applied - before
    local bodies = 0
    for _, m in ipairs(g.members) do if m.materialized then bodies = bodies + 1 end end
    check(g.physical and n == bodies, string.format("each materialised member gets the squad's gear (%d of %d)", n, bodies))
    local lo = Bridge.loadouts_applied[#Bridge.loadouts_applied]
    check(lo and lo.loadout.Weapons[1] == "Weapon_M9", "the configured items are the ones handed over")
end

print("")
os.exit(fails == 0 and 0 or 1)
